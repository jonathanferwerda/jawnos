//! The house patchbay: sources, buses and sinks from the saved plan
//! (`docs/studio-audio-roadmap.md` §8).
//!
//! A plan is data the manager owns; this module is the one place it becomes a
//! graph. Sources are the capture channels, buses are stereo sums, sinks are
//! the playback channels, and a route is an edge with a gain and a pan. The
//! graph is compiled once, before the device loop starts, and every buffer it
//! needs is allocated then: the audio callback only reads and writes memory it
//! already owns. A bus take is the one control that may arrive mid-run: the
//! socket raises an attach or detach request, a block applies it by taking one
//! lock for one move, and every other block reads one atomic and takes none.
//!
//! Three rules keep the compile honest:
//!
//! * **A node the machine cannot bind is silent, not fatal.** A plan may name a
//!   phone, a peer machine or a zone. On this machine an `input` source is a
//!   capture channel, a `device` source is the machine's own system mix (Music,
//!   video, notifications, calls), a `handset` source is the reception mixer's
//!   screened-call monitor (`jawn_call_in.monitor`), a `peer` source is another
//!   machine's input carried over the uplink (`uplink.rs`), a `player` source is
//!   a Studio app's own PCM carried by this machine's local audio input, and an
//!   `interface`/`speakers` sink is the local output; the rest are reported in
//!   [`PatchSummary::silent`] and their routes contribute nothing. A peer or a
//!   player that is on this machine is `pending` until a receiver is attached,
//!   not silent.
//!   A plan is one document for the whole house; applying it on one machine
//!   must not fail because the rest of the house is elsewhere.
//!
//! * **Ordinary audio survives the engine taking the card.** A machine in
//!   managed mode sends its apps to a virtual sink; the engine captures that
//!   sink's monitor as the `device` source and mixes it like any other source.
//!   When the plan does not route a `device` source at all, the system mix is
//!   still added to the output at unity (the `fallback` in
//!   [`PatchSummary::system`]), so a machine whose plan is empty is not silent.
//!   A plan that routes the source owns it: its gain, pan and mute apply.
//! * **A route that cannot be executed is refused, not approximated.** A route
//!   delay is a promise the engine does not keep yet, so `delay_ms > 0` is an
//!   error rather than a silent zero. A gain outside 0..=1 and a pan outside
//!   -1..=1 are mistakes, not louder mixes.
//! * **A cycle is refused before it runs.** A bus that feeds itself is a node
//!   that sums its own output: with a delay it grows without bound, and without
//!   one it never settles. The saved plan refuses it too; this is the engine
//!   not trusting the file.
//!
//! This is a bin module, beside `socket`, because it speaks the same small JSON
//! `Value` the control socket parses and because both callers are the binary.
//! Its unit tests still run in `cargo test`.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use jawn_audio::graph::{mix_mono_into_stereo, Strip};
use jawn_audio::listen::ListenSink;
use jawn_audio::mixer::{ParamName, ParamQueue};
use jawn_audio::monbus::{Consumer, Producer};
use jawn_audio::playback::StandaloneClick;
use jawn_audio::{to_i16, Channel, Device, EffectChain, InsertKind, NullDevice, Param};

use crate::backends::BackendKind;
use crate::socket::{get, Object, Value};
use crate::system_capture::DEFAULT_INPUT;

/// The source kinds a saved plan may name. `input` is a capture channel,
/// `device` is this machine's system mix, `handset` is the reception mixer's
/// screened call, `peer` is another machine's input on the uplink, and
/// `player` is a Studio app's own PCM carried by this machine's local audio
/// input. Each kind asks for a different capture, and none of them borrows an
/// interface channel unless it is an `input`.
const SOURCE_KINDS: &[&str] = &["input", "player", "peer", "handset", "device"];

/// The sink kinds a saved plan may name. `interface` and `speakers` are the
/// local stereo output; `zone` and `peer` are elsewhere.
const SINK_KINDS: &[&str] = &["interface", "speakers", "zone", "peer"];

/// Where one source sends its samples.
#[derive(Debug)]
enum SourceRoute {
    /// Into a stereo bus, with the equal-power pan a Studio strip uses.
    /// `strip` is the route's index into [`Patchbay::strips`], so a live
    /// gain/pan moves it without re-arming.
    Bus { index: usize, strip: usize },
    /// Straight to a sink, bypassing every bus.
    Sink { index: usize, strip: usize },
}

/// One declared source. `channel` is `None` when the machine cannot bind it;
/// `system` marks a `device` source, which reads the machine's own mix from a
/// second capture rather than a channel of the interface; `handset` marks a
/// `handset` source, which reads the reception mixer's screened-call monitor
/// (`jawn_call_in.monitor`) from a capture of its own; `peer` marks another
/// machine's input, which the uplink (`uplink.rs`) carries in a ring of its
/// own and mixes like a `parec` input, without borrowing an interface channel.
/// `input` is the source's own `parec` ring on a PipeWire machine, where the
/// card is never opened for capture: its samples land in the plan's `channel`
/// each block. `player` marks a Studio app's own stereo PCM, which the local
/// audio input (`local.rs`) carries in a ring of its own and the block mixes
/// like a stereo `parec` input.
#[derive(Debug)]
struct Source {
    id: String,
    channel: Option<usize>,
    /// The source's own trim, before its insert chain and every route. It is a
    /// [`Param`], so a live `param` moves it without re-arming the graph. The
    /// default is unity; a source that declares no `gain` is a wire.
    gain: Param,
    /// The source's footswitch, folded into the trim. `1` is audible and `0` is
    /// silent; it is a [`Param`], so a live mute crosses to the audio thread at
    /// the next block without touching the gain the player set.
    mute: Param,
    /// The inserts this source runs before its routes and sends, in plan order.
    /// A stereo source (`device`, `handset`) has one chain per side, exactly as
    /// the master rack runs two independent instances; a mono source has one.
    chains: Vec<EffectChain>,
    /// The insert kinds the source declared, for the status line and for the
    /// socket's check that a knob belongs to an armed insert.
    inserts: Vec<InsertKind>,
    /// The PipeWire/Pulse source this input captures, when the plan names one.
    /// `None` means the machine's default source (`@DEFAULT_SOURCE@`); a named
    /// node is never replaced by that default, because a take that asked for
    /// the UM2 must not quietly record the laptop's microphone.
    node: Option<String>,
    system: bool,
    handset: bool,
    /// Another machine's input on the uplink. It has no interface channel: the
    /// uplink fills a stereo ring of its own, which the block mixes like a
    /// `parec` input, and it asks for no card capture and no `parec`.
    peer: bool,
    /// A Studio app's own PCM on this machine. It has no interface channel:
    /// the local audio input fills a stereo ring of its own, so a plan whose
    /// inputs take every channel can still carry a player. It asks for no card
    /// capture and no `parec`.
    player: bool,
    /// A `player`'s declared lead, in milliseconds: how far ahead of its
    /// arrival the first frame is placed on the master timeline. Zero for
    /// every other kind, whose placement belongs to the uplink or the card.
    lead_ms: f64,
    /// The peer's declared capture/pipeline latency, in milliseconds. A
    /// positive value means its audio is late, so the uplink places it that
    /// much earlier on the master timeline. Zero for every source that is not
    /// a `peer` on this machine: a local input's declaration is the plan's to
    /// keep, but the engine does not compensate it yet.
    latency_ms: f64,
    /// The peer's declared placement buffer, in milliseconds: how far behind
    /// the master clock the uplink reads this source. `None` means the engine's
    /// default, one jitter window. Only a `peer` declares one; the read path
    /// raises anything shorter than the default to it.
    buffer_ms: Option<f64>,
    input: Option<Consumer>,
    routes: Vec<SourceRoute>,
}

/// One routed local input the engine captures through its own stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputStream {
    /// The source's index in the compiled plan, so a ring reaches the source
    /// it was started for.
    pub index: usize,
    /// The plan's id, for the operator message when the capture cannot start.
    pub id: String,
    /// Which channel of the capture feeds this source, read the way the ALSA
    /// duplex loop reads the card's channels.
    pub channel: usize,
    /// The named capture node, or `None` for the machine's default source.
    pub node: Option<String>,
}

/// Which streams a patch asks the device worker to open.
#[cfg_attr(not(feature = "alsa"), allow(dead_code))]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamPlan {
    /// Open the interface for capture as well as playback. ALSA duplex needs
    /// this; a PipeWire engine plays only, and captures each routed input
    /// through `parec`, because one pipewire-alsa process takes one node
    /// target for the whole process.
    pub card_capture: bool,
    /// One `parec` stream per routed local input, on the PipeWire backend.
    pub inputs: Vec<InputStream>,
}

/// One declared sink, and whether this machine's playback can receive it.
struct Sink {
    id: String,
    bound: bool,
}

/// One bus -> bus or bus -> sink send. A stereo send is a balance, not an
/// equal-power pan: a centred send is unity in both speakers, because it is
/// already a stereo signal being turned down. `strip` is the route's index
/// into [`Patchbay::strips`], read every block so a live gain/pan moves it.
#[derive(Debug)]
struct BusSend {
    from: usize,
    strip: usize,
}

/// One source's declared processing, for `status`: its trim and the inserts it
/// runs before its routes. The gain is live, so a page reads back a moved fader
/// here; the insert names are the compiled chain order.
#[derive(Clone, Debug)]
pub struct SourceEffects {
    pub id: String,
    pub gain: f32,
    /// True when the source is muted by a live `patch_source` param.
    pub mute: bool,
    pub inserts: Vec<String>,
}

/// What a plan compiled into, for `status` and a CLI report.
#[derive(Clone, Debug)]
pub struct PatchSummary {
    pub sources: usize,
    pub buses: usize,
    pub sinks: usize,
    pub routes: usize,
    pub bound_sources: usize,
    pub bound_sinks: usize,
    /// Node ids that were declared and routed but cannot be bound here.
    pub silent: Vec<String>,
    /// Every source's trim and insert chain, in plan order. A source that
    /// declares neither still appears, so a page can tell an unprocessed
    /// source from one the plan did not mention.
    pub source_effects: Vec<SourceEffects>,
    /// Every bound local `input`, as (id, capture node): the plan's own `node`,
    /// or `@DEFAULT_SOURCE@` when it names none. The status shows which
    /// microphone a take will actually use.
    pub inputs: Vec<(String, String)>,
    /// `routed` when the plan sends a `device` source somewhere; `fallback`
    /// when the machine's own mix is added to the output at unity because the
    /// plan does not route it. It is serialised as `system_route`, because
    /// `system` on the same line is the capture state (see
    /// [`PatchSummary::json`]).
    pub system: &'static str,
    /// `capturing` when a declared `handset` source is bound to the call
    /// monitor, `pending` before the capture is attached, `unavailable` when
    /// the sink is absent (the source is then also named in `silent`), and
    /// `off` when the plan declares no `handset` source.
    pub handset: &'static str,
    /// `duplex` when the plan needs the card's capture (a routed local
    /// `input` source) and the device loop opens capture and playback;
    /// `playback` when it does not and the loop opens only the output, leaving
    /// the microphone to PipeWire. The system mix, the handset and a peer are
    /// external captures and do not make a plan `duplex`.
    pub mode: &'static str,
    /// `pending` while a routed `peer` source on this machine has no uplink
    /// receiver attached, `capturing` once the uplink attaches its ring, and
    /// `off` when the plan declares no peer source on this machine. A peer on
    /// another machine is `silent` instead (see [`PatchSummary::silent`]).
    pub peer: &'static str,
    /// `pending` while a routed `player` source on this machine has no local
    /// audio input attached, `capturing` once the forwarder's ring is attached,
    /// and `off` when the plan declares no player source on this machine. A
    /// player on another machine is `silent` instead, like a peer.
    pub player: &'static str,
}

impl PatchSummary {
    /// The JSON fragment `status` splices into its line.
    pub fn json(&self) -> String {
        let silent = self
            .silent
            .iter()
            .map(|id| format!("\"{}\"", jawn_audio::loopback::json_escape(id)))
            .collect::<Vec<String>>()
            .join(",");
        let inputs = self
            .inputs
            .iter()
            .map(|(id, node)| {
                format!(
                    "{{\"id\":\"{}\",\"node\":\"{}\"}}",
                    jawn_audio::loopback::json_escape(id),
                    jawn_audio::loopback::json_escape(node)
                )
            })
            .collect::<Vec<String>>()
            .join(",");
        let source_effects = self
            .source_effects
            .iter()
            .map(|source| {
                let inserts = source
                    .inserts
                    .iter()
                    .map(|name| format!("\"{}\"", jawn_audio::loopback::json_escape(name)))
                    .collect::<Vec<String>>()
                    .join(",");
                format!(
                    "{{\"id\":\"{}\",\"gain\":{},\"mute\":{},\"inserts\":[{}]}}",
                    jawn_audio::loopback::json_escape(&source.id),
                    source.gain,
                    source.mute,
                    inserts
                )
            })
            .collect::<Vec<String>>()
            .join(",");
        format!(
            "\"sources\":{},\"buses\":{},\"sinks\":{},\"routes\":{},\"bound_sources\":{},\"bound_sinks\":{},\"silent\":[{}],\"inputs\":[{}],\"source_effects\":[{}],\"system_route\":\"{}\",\"handset\":\"{}\",\"mode\":\"{}\",\"peer\":\"{}\",\"player\":\"{}\"",
            self.sources,
            self.buses,
            self.sinks,
            self.routes,
            self.bound_sources,
            self.bound_sinks,
            silent,
            inputs,
            source_effects,
            self.system,
            self.handset,
            self.mode,
            self.peer,
            self.player
        )
    }
}

/// One compiled routing graph.
#[derive(Debug)]
pub struct Patchbay {
    /// The width the device actually granted, learned in [`Patchbay::prepared`].
    channels: usize,
    period: usize,
    sources: Vec<Source>,
    /// The plan's bus ids, in compile order. A bus take names one of these and
    /// the engine refuses any other name, so a WAV can only ever tap a bus the
    /// running plan actually has.
    bus_ids: Vec<String>,
    /// Incoming sends per destination bus.
    bus_routes: Vec<Vec<BusSend>>,
    /// Incoming sends per sink.
    sink_bus_routes: Vec<Vec<BusSend>>,
    /// The bus evaluation order: every bus after the buses feeding it.
    order: Vec<usize>,
    /// One strip per route, in plan order. `None` for a route that is muted
    /// or cannot be executed on this machine (an unbound endpoint). A live
    /// gain/pan changes this strip's `Param`s; the block reads them every time.
    strips: Vec<Option<Strip>>,
    /// The shared control ring the socket's `param` pushes to and the block
    /// drains at its top.
    params: Arc<ParamQueue>,
    /// Source trims and insert knobs, a ring of their own. A source address is
    /// not a route number, so it cannot share the route queue without a second
    /// namespace; this one carries only source indices.
    source_params: Arc<ParamQueue>,
    summary: PatchSummary,
    /// Whether a bound `device` source is routed by the plan. When it is not,
    /// the system mix is added to the output at unity instead of disappearing.
    system_routed: bool,
    /// Interleaved f32 capture, one block.
    input: Vec<f32>,
    /// One stereo block popped from an input's own `parec` ring, then written
    /// into that source's plan channel before the graph renders.
    capture_block: Vec<f32>,
    /// One stereo block per `peer` source, indexed by its position in
    /// [`Patchbay::sources`]. The uplink's mono voice is popped into its own
    /// block, so a peer never borrows an interface channel; empty for every
    /// source that is not a peer.
    peer_blocks: Vec<Vec<f32>>,
    /// One stereo block per `player` source, indexed like `peer_blocks`. A
    /// Studio app's PCM is already interleaved stereo, so the local audio input
    /// pops it into a block of its own and the block mixes it like a stereo
    /// `parec` input; empty for every source that is not a player.
    player_blocks: Vec<Vec<f32>>,
    /// Interleaved stereo f32 system mix, one block. Empty when the block did
    /// not carry one; the same length as `input`'s frames otherwise.
    system: Vec<f32>,
    /// The reverse side of the reception mixer's `jawn_call_in.monitor` capture.
    /// `None` when the plan declares no `handset` source.
    handset: Option<Consumer>,
    /// Interleaved stereo f32 handset mix, one block, popped once per render.
    handset_block: Vec<f32>,
    /// One mono source, reused for every source.
    mono: Vec<f32>,
    /// The two channels of a stereo source while its inserts run, so a `device`
    /// or `handset` source can use one independent mono chain per side without
    /// interleaving inside an effect. `source_stereo` is the processed pair the
    /// routes read; the shared capture block stays untouched, so two sources on
    /// one capture do not run each other's inserts.
    source_left: Vec<f32>,
    source_right: Vec<f32>,
    source_stereo: Vec<f32>,
    /// One stereo block per bus.
    buses: Vec<Vec<f32>>,
    /// One stereo block per sink.
    sink_buffers: Vec<Vec<f32>>,
    /// The summed stereo block written to the device.
    mix: Vec<f32>,
    /// The control side a bus take attaches a WAV writer through.
    tap: Arc<BusTap>,
    /// The tap this block is feeding, once the control side attached one. The
    /// producer and click are moved here by [`Patchbay::apply_tap`].
    tap_active: Option<ActiveTap>,
}

/// One WAV writer's attachment to one compiled bus.
///
/// The audio path touches this only when the control side raised a request
/// between blocks: attaching or detaching takes the slot's lock once, for one
/// move. In the steady state a block reads one atomic and takes no lock, so the
/// patch's block deadline is unchanged while a take records.
#[derive(Debug)]
pub struct BusTap {
    /// 0: nothing to do, 1: take the slot, 2: detach.
    request: AtomicUsize,
    /// The compile index of the bus the slot's producer was validated against.
    bus: AtomicUsize,
    /// The producer and optional click, written before `request` is raised.
    slot: Mutex<Option<TapRequest>>,
    /// How many buses the compiled plan has, so an out-of-range index is
    /// refused here as well as by name on the socket.
    buses: usize,
}

#[derive(Debug)]
struct TapRequest {
    producer: Producer,
    click: Option<StandaloneClick>,
}

#[derive(Debug)]
struct ActiveTap {
    bus: usize,
    producer: Producer,
    click: Option<StandaloneClick>,
}

impl BusTap {
    fn new(buses: usize) -> Self {
        BusTap {
            request: AtomicUsize::new(0),
            bus: AtomicUsize::new(0),
            slot: Mutex::new(None),
            buses,
        }
    }

    /// Attach `producer` (and an optional click for the patch's output) to the
    /// bus at `index`. False when the index is not in the compiled plan: the
    /// socket has already checked the name, and this is the same rule at the
    /// index it resolved.
    pub fn attach(
        &self,
        index: usize,
        producer: Producer,
        click: Option<StandaloneClick>,
    ) -> bool {
        if index >= self.buses {
            return false;
        }
        let mut slot = self
            .slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *slot = Some(TapRequest { producer, click });
        self.bus.store(index, Ordering::Relaxed);
        // The slot is written first: the block that swaps `1` can take it.
        self.request.store(1, Ordering::Release);
        true
    }

    /// Ask the patchbay to stop feeding the tap. A take that ends detaches, so
    /// a finished file never grows and the patch stops copying its bus.
    pub fn detach(&self) {
        self.request.store(2, Ordering::Release);
    }
}

impl Patchbay {
    /// The control side of a bus take. One patch owns one, whether or not a
    /// take ever attaches; the socket keeps this handle so a take can start
    /// mid-patch.
    pub fn tap(&self) -> Arc<BusTap> {
        Arc::clone(&self.tap)
    }

    /// The plan's bus ids in compile order. A bus take names one of these.
    pub fn bus_ids(&self) -> &[String] {
        &self.bus_ids
    }

    /// The source trims' and inserts' control ring. The socket pushes a
    /// `patch_source` param here; the block drains it at its top.
    pub fn source_params(&self) -> Arc<ParamQueue> {
        Arc::clone(&self.source_params)
    }

    /// Every source's insert chain, in plan order. The socket checks a live
    /// `patch_source` knob against the chain the source actually armed.
    pub fn source_inserts(&self) -> Vec<Vec<InsertKind>> {
        self.sources
            .iter()
            .map(|source| source.inserts.clone())
            .collect()
    }
}

impl Patchbay {
    /// Compile one plan object against a capture width.
    ///
    /// The object is the manager's saved plan: `sources`, `buses`, `sinks`,
    /// `routes`, each an array. A missing field is an empty list, as an older
    /// plan would have. Anything the plan itself could not contain (an unknown
    /// kind, a route to nothing, a cycle, a delay) is refused with one
    /// sentence.
    pub fn from_object(
        object: &Object,
        config_channels: usize,
        machine: &str,
    ) -> Result<Patchbay, String> {
        Self::from_object_with_probe(object, config_channels, machine, &|node| {
            crate::system_capture::source_exists(node)
        })
    }

    /// The same compile, with the question "does this machine offer this
    /// source?" asked through `probe` instead of `pactl`. A test compiles a plan
    /// for a microphone it does not have; a machine that cannot ask (no
    /// `pactl`) answers `None` and the capture is still attempted, because an
    /// unverifiable node is not evidence of a wrong one.
    pub fn from_object_with_probe(
        object: &Object,
        config_channels: usize,
        machine: &str,
        probe: &dyn Fn(&str) -> Option<bool>,
    ) -> Result<Patchbay, String> {
        if config_channels == 0 {
            return Err("a patch needs at least one capture channel".to_string());
        }

        let mut sources: Vec<Source> = Vec::new();
        let mut sinks: Vec<Sink> = Vec::new();
        let mut buses: Vec<String> = Vec::new();
        let mut silent: Vec<String> = Vec::new();

        // Every node id names one thing. The manager's plan already refuses a
        // duplicate; the engine repeats it because a hand-written file can
        // still be applied with --plan.
        let mut seen: Vec<String> = Vec::new();

        for entry in list(object, "sources")? {
            let entry = as_object(entry, "a source")?;
            let id = node_id(entry, "source")?;
            if seen.iter().any(|name| name == &id) {
                return Err(format!("the plan names {id} more than once"));
            }
            seen.push(id.clone());
            let kind = text(entry, "kind").unwrap_or_default();
            if !SOURCE_KINDS.contains(&kind.as_str()) {
                return Err(format!(
                    "{id} has kind \"{kind}\"; a source is input, player, peer, handset or device"
                ));
            }
            let channel = integer(entry, "channel")?.unwrap_or(0);
            // The capture node an `input` names, or `None` for the machine's
            // default source. A `node` on any other kind is a plan this engine
            // does not understand; the manager refuses it on save, and here it
            // is simply not a capture.
            let node = source_node(entry, &kind)?;
            // `machine` is optional; absent or empty means "this machine". A
            // source delegated to another host is declared but silent here.
            let on_this_machine = node_machine(entry).map_or(true, |host| {
                host.eq_ignore_ascii_case(machine)
            });
            // A `device` source is this machine's ordinary audio, captured from
            // the virtual sink's monitor. It has no interface channel, so the
            // channel field is not consulted. A `handset` source is the
            // reception mixer's screened call, captured from `jawn_call_in`'s
            // monitor the same way and bound on this machine unless the plan
            // places it elsewhere. A `peer` source is another machine's input
            // on the uplink: it has no interface channel either, because the
            // uplink fills a ring of its own, so a plan whose inputs take every
            // channel can still carry a peer. It asks for no card capture.
            let system = kind == "device" && on_this_machine;
            let handset = kind == "handset" && on_this_machine;
            let peer = kind == "peer" && on_this_machine;
            // A `player` is a Studio app's own PCM, carried by this machine's
            // local audio input. It is bound here only when the plan places it
            // on this machine, exactly like a peer; elsewhere it is silent.
            let player = kind == "player" && on_this_machine;
            // Only a `peer` source's declaration is placed by this engine. The
            // manager writes `latency_ms` on every source, so a number on a
            // local `input` (or any other kind) is kept for the plan and
            // ignored here rather than refused: a local input's latency is not
            // compensated on this path yet.
            let latency_ms = if kind == "peer" {
                peer_latency_ms(entry, &id)?.unwrap_or(0.0)
            } else {
                0.0
            };
            // A player's lead is the one placement this engine makes for an
            // app's PCM: it tells the local reader how far ahead of arrival to
            // anchor the first frame. Only a `player` carries one; a number on
            // any other kind is kept for the plan and ignored here.
            let lead_ms = if kind == "player" {
                player_lead_ms(entry, &id)?.unwrap_or(0.0)
            } else {
                0.0
            };
            // How far behind the master clock this source is read. Only a
            // `peer` (the uplink's read head) and a `player` (the local audio
            // input's read head) are fed by a ring of their own, so only they
            // declare a buffer.
            let buffer_ms = if kind == "peer" {
                peer_buffer_ms(entry, &id)?
            } else if kind == "player" {
                player_buffer_ms(entry, &id)?
            } else {
                None
            };
            let mut reachable = kind == "input" && on_this_machine && channel < config_channels;
            // A named node this machine does not offer is silent, like a
            // channel the interface does not have. Falling back to the default
            // source would record the wrong microphone and say nothing.
            if reachable && node.as_deref().is_some_and(|name| probe(name) == Some(false)) {
                reachable = false;
            }
            if !reachable && !system && !handset && !peer && !player {
                // A plan saved for a wider interface (or a phone, or a route
                // delegated elsewhere) is a declared node this machine cannot
                // reach, not a broken plan. A `peer` or a `player` on this
                // machine is not in this list: it is pending until its ring is
                // attached.
                silent.push(id.clone());
            }
            // A source runs its own trim and inserts before any route, so the
            // bus a take records is the effected source. The chain is built
            // here, before the routes, and a stereo source gets two independent
            // instances: an effect is a mono processor, exactly as the master
            // rack runs one per side. Declared controls are applied per slot,
            // so two pedals of one kind can start at different settings.
            let planned = source_inserts(entry, &id)?;
            let gain = source_gain(entry, &id)?;
            // A stereo source runs one independent mono chain per side. A
            // player is stereo: its PCM arrives already interleaved.
            let chains_per_source = if system || handset || player { 2 } else { 1 };
            let mut chains = Vec::with_capacity(chains_per_source);
            for _ in 0..chains_per_source {
                let mut chain = EffectChain::new();
                for insert in &planned {
                    chain.push_configured(insert.kind, insert.bypass, &insert.controls);
                }
                chains.push(chain);
            }
            let inserts = planned.iter().map(|insert| insert.kind).collect();
            sources.push(Source {
                id,
                channel: reachable.then_some(channel),
                gain: Param::new(gain),
                mute: Param::new(1.0),
                chains,
                inserts,
                node: reachable.then_some(node).flatten(),
                system,
                handset,
                peer,
                player,
                lead_ms,
                latency_ms,
                buffer_ms,
                input: None,
                routes: Vec::new(),
            });
        }

        for entry in list(object, "buses")? {
            let entry = as_object(entry, "a bus")?;
            let id = node_id(entry, "bus")?;
            if seen.iter().any(|name| name == &id) {
                return Err(format!("the plan names {id} more than once"));
            }
            seen.push(id.clone());
            buses.push(id);
        }

        for entry in list(object, "sinks")? {
            let entry = as_object(entry, "a sink")?;
            let id = node_id(entry, "sink")?;
            if seen.iter().any(|name| name == &id) {
                return Err(format!("the plan names {id} more than once"));
            }
            seen.push(id.clone());
            let kind = text(entry, "kind").unwrap_or_default();
            if !SINK_KINDS.contains(&kind.as_str()) {
                return Err(format!(
                    "{id} has kind \"{kind}\"; a sink is interface, speakers, zone or peer"
                ));
            }
            let channel = integer(entry, "channel")?.unwrap_or(0);
            // The listen/playback seam is a stereo pair at the start of the
            // output. A sink that wants another pair is real on a wider
            // interface, but not through this one; a sink delegated to another
            // host is likewise silent here.
            let on_this_machine = node_machine(entry).map_or(true, |host| {
                host.eq_ignore_ascii_case(machine)
            });
            let bound = matches!(kind.as_str(), "interface" | "speakers")
                && channel == 0
                && on_this_machine;
            if !bound {
                silent.push(id.clone());
            }
            sinks.push(Sink { id, bound });
        }

        let mut bus_routes: Vec<Vec<BusSend>> = (0..buses.len()).map(|_| Vec::new()).collect();
        let mut sink_bus_routes: Vec<Vec<BusSend>> = (0..sinks.len()).map(|_| Vec::new()).collect();
        let mut bus_edges: Vec<(usize, usize)> = Vec::new();
        let mut strips: Vec<Option<Strip>> = Vec::new();
        let mut route_count = 0usize;
        // A muted device route still means the plan owns the system mix; a
        // route to a sink this machine cannot bind does not, or a plan for
        // another machine would silence this one's ordinary audio.
        let mut system_owned = false;

        for entry in list(object, "routes")? {
            let entry = as_object(entry, "a route")?;
            let from = node_ref(entry, "from")?;
            let to = node_ref(entry, "to")?;
            if from == to {
                return Err(format!("a route joins {from} to itself"));
            }
            let from_ref = resolve(&seen, &sources, &buses, &sinks, &from)?;
            let to_ref = resolve(&seen, &sources, &buses, &sinks, &to)?;

            if let NodeRef::Sink(_) = from_ref {
                return Err(format!("{from} is a sink; a sink has no output to route"));
            }
            if let NodeRef::Source(_) = to_ref {
                return Err(format!("{to} is a source; a source has no input to route"));
            }

            let gain = number(entry, "gain")?.unwrap_or(1.0);
            if !(0.0..=1.0).contains(&gain) {
                return Err(format!(
                    "the route {from} -> {to} has gain {gain}; a gain is between 0 and 1"
                ));
            }
            let pan = number(entry, "pan")?.unwrap_or(0.0);
            if !(-1.0..=1.0).contains(&pan) {
                return Err(format!(
                    "the route {from} -> {to} has pan {pan}; a pan is between -1 and 1"
                ));
            }
            let mute = match get(entry, "mute") {
                None | Some(Value::Null) => false,
                Some(Value::Bool(value)) => *value,
                // The Perl plan normalises a mute to 0 or 1, not a JSON
                // boolean; accept both spellings of the same fact.
                Some(Value::Num(value)) if *value == 0.0 => false,
                Some(Value::Num(value)) if *value == 1.0 => true,
                Some(_) => return Err(format!("the route {from} -> {to} has a \"mute\" that is not true or false")),
            };
            let delay = number(entry, "delay_ms")?.unwrap_or(0.0);
            if delay > 0.0 {
                return Err(format!(
                    "the route {from} -> {to} asks for {delay} ms of delay; route delays are not implemented yet, so the plan would be a promise the engine does not keep"
                ));
            }
            route_count += 1;
            let route_index = strips.len();
            let owns_system = match (from_ref, to_ref) {
                (NodeRef::Source(source), NodeRef::Bus(_)) => sources[source].system,
                (NodeRef::Source(source), NodeRef::Sink(sink)) => {
                    sources[source].system && sinks[sink].bound
                }
                _ => false,
            };
            if owns_system {
                system_owned = true;
            }
            if mute {
                // A muted route is a route the plan kept so the UI can unmute
                // it. It contributes nothing, and it is not a compile error. A
                // gain of 0 is different: the fader is at zero, and a live
                // `param` may raise it without re-arming.
                strips.push(None);
                continue;
            }

            let executable = match (from_ref, to_ref) {
                (NodeRef::Source(source), NodeRef::Bus(bus)) => {
                    if source_feeds(&sources[source]) {
                        sources[source].routes.push(SourceRoute::Bus {
                            index: bus,
                            strip: route_index,
                        });
                        true
                    } else {
                        false
                    }
                }
                (NodeRef::Source(source), NodeRef::Sink(sink)) => {
                    if source_feeds(&sources[source]) && sinks[sink].bound {
                        sources[source].routes.push(SourceRoute::Sink {
                            index: sink,
                            strip: route_index,
                        });
                        true
                    } else {
                        false
                    }
                }
                (NodeRef::Bus(from), NodeRef::Bus(to)) => {
                    bus_routes[to].push(BusSend { from, strip: route_index });
                    bus_edges.push((from, to));
                    true
                }
                (NodeRef::Bus(from), NodeRef::Sink(to)) => {
                    if sinks[to].bound {
                        sink_bus_routes[to].push(BusSend { from, strip: route_index });
                        true
                    } else {
                        false
                    }
                }
                // Rejected above, repeated here so the match is total and the
                // compiler proves no edge shape was forgotten.
                (NodeRef::Sink(_), _) | (_, NodeRef::Source(_)) => false,
            };
            strips.push(if executable {
                Some(Strip::new(gain, pan))
            } else {
                None
            });
        }

        let order = bus_order(buses.len(), &bus_edges)?;

        // The plan owns the system mix when it routes a bound `device` source
        // somewhere executable (or mutes such a route). Otherwise the
        // machine's ordinary audio is added at the output; that is what keeps
        // Music, video and a call audible on an empty plan.
        let system_routed = system_owned;

        let mode = if sources_want_input(&sources) {
            "duplex"
        } else {
            "playback"
        };
        let peer_state = if sources.iter().any(|source| source.peer) {
            if sources.iter().any(|source| source.peer && source.input.is_some()) {
                "capturing"
            } else {
                "pending"
            }
        } else {
            "off"
        };
        let player_state = if sources.iter().any(|source| source.player) {
            if sources
                .iter()
                .any(|source| source.player && source.input.is_some())
            {
                "capturing"
            } else {
                "pending"
            }
        } else {
            "off"
        };
        let source_effects = sources
            .iter()
            .map(|source| SourceEffects {
                id: source.id.clone(),
                gain: source.gain.get(),
                mute: source.mute.get() < 0.5,
                inserts: source
                    .inserts
                    .iter()
                    .map(|kind| kind.name().to_string())
                    .collect(),
            })
            .collect();
        let summary = PatchSummary {
            sources: sources.len(),
            buses: buses.len(),
            sinks: sinks.len(),
            routes: route_count,
            bound_sources: sources.iter().filter(|source| source_feeds(source)).count(),
            bound_sinks: sinks.iter().filter(|sink| sink.bound).count(),
            silent,
            source_effects,
            inputs: bound_inputs(&sources),
            system: if system_routed { "routed" } else { "fallback" },
            handset: if sources.iter().any(|source| source.handset) {
                "pending"
            } else {
                "off"
            },
            mode,
            peer: peer_state,
            player: player_state,
        };

        let bus_count = buses.len();
        let sink_count = sinks.len();
        let source_count = sources.len();
        Ok(Patchbay {
            channels: config_channels,
            period: 0,
            sources,
            bus_ids: buses,
            bus_routes,
            sink_bus_routes,
            order,
            strips,
            params: Arc::new(ParamQueue::new()),
            source_params: Arc::new(ParamQueue::new()),
            summary,
            system_routed,
            input: Vec::new(),
            capture_block: Vec::new(),
            peer_blocks: (0..source_count).map(|_| Vec::new()).collect(),
            player_blocks: (0..source_count).map(|_| Vec::new()).collect(),
            system: Vec::new(),
            handset: None,
            handset_block: Vec::new(),
            mono: Vec::new(),
            source_left: Vec::new(),
            source_right: Vec::new(),
            source_stereo: Vec::new(),
            buses: (0..bus_count).map(|_| Vec::new()).collect(),
            sink_buffers: (0..sink_count).map(|_| Vec::new()).collect(),
            mix: Vec::new(),
            tap: Arc::new(BusTap::new(bus_count)),
            tap_active: None,
        })
    }

    pub fn summary(&self) -> &PatchSummary {
        &self.summary
    }

    /// Whether the plan declares a `handset` source on this machine. The
    /// caller starts the second capture only when this is true, so a plan
    /// without a handset never runs an extra `parec`.
    pub fn wants_handset(&self) -> bool {
        self.sources.iter().any(|source| source.handset)
    }

    /// Every routed `peer` source on this machine, as (index, id, declared
    /// latency in ms, declared read buffer in ms). The caller makes one ring per
    /// entry and the uplink feeds it, placing that source earlier by its
    /// latency and reading it that far behind the clock by its buffer; the
    /// block pops it into that source's own stereo block, so a peer that is not
    /// routed costs no thread, no ring and no UDP stream. A buffer of `None`
    /// takes the uplink's default.
    pub fn wants_peer(&self) -> Vec<(usize, String, f64, Option<f64>)> {
        self.sources
            .iter()
            .enumerate()
            .filter(|(_index, source)| source.peer && !source.routes.is_empty())
            .map(|(index, source)| {
                (
                    index,
                    source.id.clone(),
                    source.latency_ms,
                    source.buffer_ms,
                )
            })
            .collect()
    }

    /// Every routed `player` source on this machine, as (index, id, declared
    /// lead in ms, declared read buffer in ms). The caller makes one ring per
    /// entry and the local audio input feeds it, anchoring its first frame that
    /// far ahead of arrival and reading it that far behind the clock; the block
    /// pops it into that source's own stereo block, so a player that is not
    /// routed costs no ring. A buffer of `None` takes the reader's default,
    /// the same one-window slack a peer starts with.
    // The caller is the local audio input, which attaches one ring per entry
    // and feeds it from the manager's forwarder. Until that reader is wired, a
    // compiled player is `pending` on this machine and costs no ring.
    #[allow(dead_code)]
    pub fn wants_player(&self) -> Vec<(usize, String, f64, Option<f64>)> {
        self.sources
            .iter()
            .enumerate()
            .filter(|(_index, source)| source.player && !source.routes.is_empty())
            .map(|(index, source)| {
                (
                    index,
                    source.id.clone(),
                    source.lead_ms,
                    source.buffer_ms,
                )
            })
            .collect()
    }

    /// Whether the compiled plan needs the card's capture.
    ///
    /// True only when at least one local `input` source is bound to a real
    /// channel *and* has an executable route. A source declared for another
    /// machine, a `device` source (the system mix), a `handset` source (the
    /// reception mixer's call monitor), a `peer` source (another machine's
    /// input on the uplink), an unrouted input and a muted route are all
    /// external or silent and need no card capture. A plan without one runs
    /// playback-only, so the microphone stays with PipeWire and its privacy
    /// indicator stays off.
    #[cfg_attr(not(feature = "alsa"), allow(dead_code))]
    pub fn wants_input(&self) -> bool {
        sources_want_input(&self.sources)
    }

    /// What streams this patch asks the device worker to open on `backend`.
    ///
    /// ALSA opens the card once and reads every input channel from it, so a
    /// routed local input asks for `card_capture` and no extra process. A
    /// PipeWire engine plays out the node it replaced and cannot also capture
    /// the card with the same pipewire-alsa process, so each routed input gets
    /// its own `parec` stream and the loop stays playback-only.
    #[cfg_attr(not(feature = "alsa"), allow(dead_code))]
    pub fn stream_plan(&self, backend: BackendKind) -> StreamPlan {
        let pipewire = backend == BackendKind::PipeWire;
        let inputs = if pipewire {
            self.sources
                .iter()
                .enumerate()
                .filter_map(|(index, source)| {
                    if source.peer {
                        return None;
                    }
                    let channel = source.channel?;
                    if source.routes.is_empty() {
                        return None;
                    }
                    Some(InputStream {
                        index,
                        id: source.id.clone(),
                        channel,
                        node: source.node.clone(),
                    })
                })
                .collect()
        } else {
            Vec::new()
        };
        StreamPlan {
            card_capture: backend == BackendKind::Alsa && self.wants_input(),
            inputs,
        }
    }

    /// Attach a capture ring to source `index`. A local `input`'s samples are
    /// written into its plan channel at the top of each block, exactly where the
    /// ALSA duplex loop's card capture would have put them. A `peer` source's
    /// uplink is a ring of its own: it is popped into a stereo block of its own
    /// and mixed like a `parec` input, so attaching it moves the source from
    /// `pending` to `capturing`.
    #[cfg_attr(not(feature = "alsa"), allow(dead_code))]
    pub fn attach_input(&mut self, index: usize, consumer: Consumer) {
        let peer = match self.sources.get_mut(index) {
            Some(source) => {
                source.input = Some(consumer);
                source.peer
            }
            None => return,
        };
        if peer {
            // A caller may attach the uplink after `prepared` (the socket
            // attaches before its worker starts, but the tests and a future
            // caller need not). Size the peer's block the way `set_handset`
            // sizes the handset's.
            let needed = self.period.saturating_mul(2);
            if let Some(block) = self.peer_blocks.get_mut(index) {
                if block.len() < needed {
                    *block = vec![0.0; needed];
                }
            }
            self.summary.peer = "capturing";
        }
    }

    /// Attach the local audio input's ring to a `player` source. A Studio app's
    /// PCM has already been mixed to stereo by the sender, so the block pops it
    /// into a stereo block of its own and mixes it like a `parec` input; the
    /// source moves from `pending` to `capturing`.
    // Attached by the local audio input, the way `attach_input` attaches a
    // peer's uplink ring.
    #[allow(dead_code)]
    pub fn attach_player(&mut self, index: usize, consumer: Consumer) {
        let Some(source) = self.sources.get_mut(index) else {
            return;
        };
        if !source.player {
            return;
        }
        source.input = Some(consumer);
        let needed = self.period.saturating_mul(2);
        if let Some(block) = self.player_blocks.get_mut(index) {
            if block.len() < needed {
                *block = vec![0.0; needed];
            }
        }
        self.summary.player = "capturing";
    }

    /// A `player`'s forwarder is gone (the sender stopped, or the app closed).
    /// The source stays declared and routed, so its fader and inserts still
    /// exist, but a block pops silence until a new ring is attached.
    // Called by the local audio input when its forwarder goes away.
    #[allow(dead_code)]
    pub fn silence_player(&mut self, index: usize) {
        let Some(source) = self.sources.get_mut(index) else {
            return;
        };
        if !source.player {
            return;
        }
        source.input = None;
        self.summary.player = if self
            .sources
            .iter()
            .any(|source| source.player && source.input.is_some())
        {
            "capturing"
        } else {
            "pending"
        };
    }

    /// An input's capture could not start. Only that source is silenced: the
    /// machine's ordinary audio and every other route keep playing, and the
    /// source's id is named in `silent` so the status can say why.
    #[cfg_attr(not(feature = "alsa"), allow(dead_code))]
    pub fn silence_input(&mut self, index: usize) {
        let Some(source) = self.sources.get_mut(index) else {
            return;
        };
        source.channel = None;
        source.input = None;
        source.routes.clear();
        let id = source.id.clone();
        if !self.summary.silent.iter().any(|name| name == &id) {
            self.summary.silent.push(id);
        }
        self.summary.bound_sources = self
            .sources
            .iter()
            .filter(|source| source_feeds(source))
            .count();
        self.summary.inputs = bound_inputs(&self.sources);
    }

    /// Attach the reception mixer's screened-call capture. The ring is popped
    /// once per block and mixed like any other stereo source.
    pub fn set_handset(&mut self, consumer: Consumer) {
        // A caller may attach the capture after `prepared` (the socket attaches
        // before its worker starts, but the tests and a future caller need not).
        if self.handset_block.len() < self.period.saturating_mul(2) {
            self.handset_block = vec![0.0; self.period.saturating_mul(2)];
        }
        self.handset = Some(consumer);
        self.summary.handset = "capturing";
    }

    /// The call sink is absent (or its capture could not start). A declared
    /// handset node becomes `silent` rather than an error, and the rest of the
    /// patch is untouched.
    pub fn silence_handset(&mut self) {
        let mut ids: Vec<String> = Vec::new();
        for source in &mut self.sources {
            if source.handset {
                source.handset = false;
                source.routes.clear();
                ids.push(source.id.clone());
            }
        }
        for id in ids {
            if !self.summary.silent.iter().any(|name| name == &id) {
                self.summary.silent.push(id);
            }
        }
        self.summary.handset = "unavailable";
        self.summary.bound_sources = self
            .sources
            .iter()
            .filter(|source| source_feeds(source))
            .count();
        self.handset = None;
    }

    /// The shared control ring the socket's `param` pushes to. The block
    /// drains it at its top, so a change is heard at the next block's edge.
    pub fn params(&self) -> Arc<ParamQueue> {
        Arc::clone(&self.params)
    }

    /// How many routes the plan named, in plan order.
    pub fn route_count(&self) -> usize {
        self.strips.len()
    }

    /// Whether route `index` has a live strip (it is not muted, not at zero
    /// gain, and every endpoint is bound on this machine).
    pub fn route_live(&self, index: usize) -> bool {
        self.strips.get(index).map(|strip| strip.is_some()).unwrap_or(false)
    }

    /// Apply every waiting control change to the route strips. Called at the
    /// top of a block; no allocation, no lock, and no panic on a full or
    /// stale entry.
    fn apply_pending(&mut self) {
        while let Some((route, name, value)) = self.params.pop() {
            let Some(Some(strip)) = self.strips.get_mut(route) else {
                continue;
            };
            match name {
                ParamName::Gain => strip.gain.set(value.clamp(0.0, 1.0)),
                ParamName::Pan => strip.pan.set(value.clamp(-1.0, 1.0)),
                _ => {}
            }
        }
        // A source's trim and insert knobs arrive in their own ring; the index
        // is a source, not a route. A source that is gone is ignored, exactly
        // as a stale route is.
        while let Some((source, name, value)) = self.source_params.pop() {
            let Some(source) = self.sources.get_mut(source) else {
                continue;
            };
            match name.insert_kind() {
                None => {
                    if name.master() || !value.is_finite() {
                        continue;
                    }
                    match name.control() {
                        "gain" => source.gain.set(value.clamp(0.0, Channel::MAX_GAIN)),
                        // The wire is `1` for muted so a checkbox reads the way
                        // a page expects. It is a separate gain, so unmuting
                        // restores the trim the player set.
                        "mute" => source.mute.set(if value >= 0.5 { 0.0 } else { 1.0 }),
                        _ => {}
                    }
                }
                Some(kind) => {
                    if name.master() {
                        continue;
                    }
                    let control = name.control();
                    let native = kind.native_value(control, value);
                    for chain in &mut source.chains {
                        chain.set_insert(kind.name(), control, native);
                    }
                }
            }
        }
    }

    /// Apply a bus take's attach or detach. A block only reaches the slot's
    /// lock when the control side asked for a change since the last one, so a
    /// recording patch still takes no lock per block in the steady state.
    fn apply_tap(&mut self) {
        match self.tap.request.swap(0, Ordering::AcqRel) {
            1 => {
                let request = self
                    .tap
                    .slot
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .take();
                let bus = self.tap.bus.load(Ordering::Relaxed);
                self.tap_active = request.map(|request| ActiveTap {
                    bus,
                    producer: request.producer,
                    click: request.click,
                });
            }
            2 => self.tap_active = None,
            _ => {}
        }
    }

    /// Size every buffer. This is the only allocation in the patchbay; the
    /// device loop then only reads and writes what this owns.
    pub fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        if period == 0 {
            return Err("a patch block must hold at least one frame".to_string());
        }
        if channels == 0 {
            return Err("a patch needs at least one capture channel".to_string());
        }
        self.period = period;
        self.channels = channels;
        // The device may grant fewer channels than the process was configured
        // for. A source on a channel that is gone is silent, exactly like one
        // the plan named for another machine.
        for source in &mut self.sources {
            if let Some(channel) = source.channel {
                if channel >= channels {
                    source.channel = None;
                    if !self.summary.silent.iter().any(|id| id == &source.id) {
                        self.summary.silent.push(source.id.clone());
                    }
                }
            }
        }
        self.summary.inputs = bound_inputs(&self.sources);
        self.input = vec![0.0; period.saturating_mul(channels)];
        self.capture_block = vec![0.0; period.saturating_mul(2)];
        self.system = vec![0.0; period.saturating_mul(2)];
        // Allocated whether or not a ring is attached yet: the socket can attach
        // the call capture after the graph is prepared, and the callback must
        // never grow a buffer.
        if self.handset.is_some() {
            self.handset_block = vec![0.0; period.saturating_mul(2)];
        }
        // A peer's uplink ring and a player's local ring arrive after
        // `prepared` on the socket's own schedule, so their blocks are
        // allocated now and the attach calls only grow them if they are still
        // too short. Any other source gets no block.
        self.peer_blocks = self
            .sources
            .iter()
            .map(|source| {
                if source.peer {
                    vec![0.0; period.saturating_mul(2)]
                } else {
                    Vec::new()
                }
            })
            .collect();
        self.player_blocks = self
            .sources
            .iter()
            .map(|source| {
                if source.player {
                    vec![0.0; period.saturating_mul(2)]
                } else {
                    Vec::new()
                }
            })
            .collect();
        self.mono = vec![0.0; period];
        self.source_left = vec![0.0; period];
        self.source_right = vec![0.0; period];
        self.source_stereo = vec![0.0; period.saturating_mul(2)];
        for source in &mut self.sources {
            for chain in &mut source.chains {
                chain.prepare(rate, period);
            }
        }
        for bus in &mut self.buses {
            *bus = vec![0.0; period.saturating_mul(2)];
        }
        for sink in &mut self.sink_buffers {
            *sink = vec![0.0; period.saturating_mul(2)];
        }
        self.mix = vec![0.0; period.saturating_mul(2)];
        Ok(())
    }

    /// One interleaved i16 capture block into one interleaved stereo i16 block.
    /// With no system mix this is the old call exactly: the `device` sources,
    /// if any, contribute silence.
    pub fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        self.block_with_system(input, &[], output)
    }

    /// The same block, plus the machine's system mix (`system`, interleaved
    /// stereo i16) captured from the virtual sink's monitor. A short or absent
    /// block is silence for the part it does not carry.
    pub fn block_with_system(
        &mut self,
        input: &[i16],
        system: &[i16],
        output: &mut [i16],
    ) -> Result<(), String> {
        let channels = self.channels;
        if channels == 0 {
            return Err("the patchbay was not prepared".to_string());
        }
        if input.len() % channels != 0 {
            return Err(format!(
                "a capture block of {} samples is not whole {channels}-channel frames",
                input.len()
            ));
        }
        let frames = input.len() / channels;
        self.check_frames(frames)?;
        if output.len() < frames * 2 {
            return Err(format!(
                "the playback block holds {} samples, the mix needs {}",
                output.len(),
                frames * 2
            ));
        }
        for (target, sample) in self.input[..input.len()].iter_mut().zip(input) {
            *target = f32::from(*sample) / 32_768.0;
        }
        let stereo = frames * 2;
        let carried = system.len().min(stereo);
        for (target, sample) in self.system[..stereo].iter_mut().zip(&system[..carried]) {
            *target = f32::from(*sample) / 32_768.0;
        }
        for target in &mut self.system[carried..stereo] {
            *target = 0.0;
        }
        self.render(frames)?;
        for (target, sample) in output[..frames * 2].iter_mut().zip(&self.mix[..frames * 2]) {
            *target = to_i16(*sample);
        }
        Ok(())
    }

    /// The same block, with the system mix as the device loop carries it: an
    /// interleaved stereo f32 ring, already at the capture's frame count.
    pub fn block_with_system_f32(
        &mut self,
        input: &[i16],
        system: &[f32],
        output: &mut [i16],
    ) -> Result<(), String> {
        let channels = self.channels;
        if channels == 0 {
            return Err("the patchbay was not prepared".to_string());
        }
        if input.len() % channels != 0 {
            return Err(format!(
                "a capture block of {} samples is not whole {channels}-channel frames",
                input.len()
            ));
        }
        let frames = input.len() / channels;
        self.check_frames(frames)?;
        if output.len() < frames * 2 {
            return Err(format!(
                "the playback block holds {} samples, the mix needs {}",
                output.len(),
                frames * 2
            ));
        }
        for (target, sample) in self.input[..input.len()].iter_mut().zip(input) {
            *target = f32::from(*sample) / 32_768.0;
        }
        let stereo = frames * 2;
        let carried = system.len().min(stereo);
        self.system[..carried].copy_from_slice(&system[..carried]);
        self.system[carried..stereo].fill(0.0);
        self.render(frames)?;
        for (target, sample) in output[..frames * 2].iter_mut().zip(&self.mix[..frames * 2]) {
            *target = to_i16(*sample);
        }
        Ok(())
    }

    /// The f32 shape, for the null backend and the unit tests.
    pub fn block_f32(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), String> {
        self.block_f32_with_system(input, &[], output)
    }

    /// The f32 shape with a system mix, for the null backend and the tests.
    pub fn block_f32_with_system(
        &mut self,
        input: &[f32],
        system: &[f32],
        output: &mut [f32],
    ) -> Result<(), String> {
        let channels = self.channels;
        if channels == 0 {
            return Err("the patchbay was not prepared".to_string());
        }
        if input.len() % channels != 0 {
            return Err(format!(
                "a capture block of {} samples is not whole {channels}-channel frames",
                input.len()
            ));
        }
        let frames = input.len() / channels;
        self.check_frames(frames)?;
        if output.len() < frames * 2 {
            return Err(format!(
                "the playback block holds {} samples, the mix needs {}",
                output.len(),
                frames * 2
            ));
        }
        self.input[..input.len()].copy_from_slice(input);
        let stereo = frames * 2;
        let carried = system.len().min(stereo);
        self.system[..carried].copy_from_slice(&system[..carried]);
        self.system[carried..stereo].fill(0.0);
        self.render(frames)?;
        output[..frames * 2].copy_from_slice(&self.mix[..frames * 2]);
        Ok(())
    }

    fn check_frames(&self, frames: usize) -> Result<(), String> {
        if frames > self.period {
            return Err(format!(
                "a {frames}-frame block is longer than the prepared {} frames",
                self.period
            ));
        }
        Ok(())
    }

    /// Add the mix's own sums into the stereo block the device plays.
    fn render(&mut self, frames: usize) -> Result<(), String> {
        self.apply_pending();
        self.apply_tap();
        let stereo = frames * 2;
        for bus in &mut self.buses {
            bus[..stereo].fill(0.0);
        }
        for sink in &mut self.sink_buffers {
            sink[..stereo].fill(0.0);
        }
        // The mix is the sink sum for *this* block; it must start at silence or
        // a second block accumulates onto the first.
        self.mix[..stereo].fill(0.0);

        // A PipeWire input has its own stream. Pop it once per block and write
        // it into the plan's channel, so the source loop below reads it exactly
        // as it reads the ALSA duplex loop's capture. A channel two sources
        // share is written twice, the same as one card channel feeding both.
        // A `peer` has no channel: its uplink ring is popped into a stereo
        // block of its own, which the source loop mixes like a `parec` input.
        // A `player`'s local ring is popped the same way, into a block of its
        // own, because a Studio app's PCM is already stereo.
        for (index, source) in self.sources.iter().enumerate() {
            let Some(consumer) = source.input.as_ref() else {
                continue;
            };
            if source.peer {
                if let Some(block) = self.peer_blocks.get_mut(index) {
                    if block.len() >= stereo {
                        consumer.pop(&mut block[..stereo]);
                    }
                }
            } else if source.player {
                if let Some(block) = self.player_blocks.get_mut(index) {
                    if block.len() >= stereo {
                        consumer.pop(&mut block[..stereo]);
                    }
                }
            } else if let Some(channel) = source.channel {
                consumer.pop(&mut self.capture_block[..stereo]);
                for frame in 0..frames {
                    self.input[frame * self.channels + channel] = self.capture_block[frame * 2];
                }
            }
        }

        // The handset ring is read once per block, before the sources, the same
        // way the take's live monitor pops its ring. A short ring is silence.
        if let Some(consumer) = &self.handset {
            consumer.pop(&mut self.handset_block[..stereo]);
        }

        // Sources first: each one is read once, then its own trim and inserts
        // run, then it is summed into every place it was routed to. An `input`
        // source is one capture channel; a `device` source is the machine's
        // stereo system mix.
        for (index, source) in self.sources.iter_mut().enumerate() {
            if source.routes.is_empty() {
                continue;
            }
            if let Some(channel) = source.channel {
                for frame in 0..frames {
                    self.mono[frame] = self.input[frame * self.channels + channel];
                }
                let gain = source.gain.get() * source.mute.get();
                for sample in &mut self.mono[..frames] {
                    *sample *= gain;
                }
                if let Some(chain) = source.chains.get_mut(0) {
                    chain
                        .process(&mut self.mono[..frames])
                        .map_err(|error| format!("source {index} inserts: {error:?}"))?;
                }
                for route in &source.routes {
                    match route {
                        SourceRoute::Bus { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_mono_into_stereo(
                                &mut self.buses[*index][..stereo],
                                &self.mono[..frames],
                                strip,
                            )
                            .map_err(|error| format!("bus {index}: {error:?}"))?;
                        }
                        SourceRoute::Sink { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_mono_into_stereo(
                                &mut self.sink_buffers[*index][..stereo],
                                &self.mono[..frames],
                                strip,
                            )
                            .map_err(|error| format!("sink {index}: {error:?}"))?;
                        }
                    }
                }
            }
            else if source.system {
                // A stereo source runs one independent mono chain per side.
                let gain = source.gain.get() * source.mute.get();
                for frame in 0..frames {
                    self.source_left[frame] = self.system[frame * 2] * gain;
                    self.source_right[frame] = self.system[frame * 2 + 1] * gain;
                }
                if source.chains.len() >= 2 {
                    let (left_chain, right_chain) = source.chains.split_at_mut(1);
                    left_chain[0]
                        .process(&mut self.source_left[..frames])
                        .map_err(|error| format!("source {index} inserts (left): {error:?}"))?;
                    right_chain[0]
                        .process(&mut self.source_right[..frames])
                        .map_err(|error| format!("source {index} inserts (right): {error:?}"))?;
                }
                for frame in 0..frames {
                    self.source_stereo[frame * 2] = self.source_left[frame];
                    self.source_stereo[frame * 2 + 1] = self.source_right[frame];
                }
                for route in &source.routes {
                    match route {
                        SourceRoute::Bus { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.buses[*index][..stereo],
                                &self.source_stereo[..stereo],
                                strip,
                            );
                        }
                        SourceRoute::Sink { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.sink_buffers[*index][..stereo],
                                &self.source_stereo[..stereo],
                                strip,
                            );
                        }
                    }
                }
            } else if source.handset {
                let gain = source.gain.get() * source.mute.get();
                for frame in 0..frames {
                    self.source_left[frame] = self.handset_block[frame * 2] * gain;
                    self.source_right[frame] = self.handset_block[frame * 2 + 1] * gain;
                }
                if source.chains.len() >= 2 {
                    let (left_chain, right_chain) = source.chains.split_at_mut(1);
                    left_chain[0]
                        .process(&mut self.source_left[..frames])
                        .map_err(|error| format!("source {index} inserts (left): {error:?}"))?;
                    right_chain[0]
                        .process(&mut self.source_right[..frames])
                        .map_err(|error| format!("source {index} inserts (right): {error:?}"))?;
                }
                for frame in 0..frames {
                    self.source_stereo[frame * 2] = self.source_left[frame];
                    self.source_stereo[frame * 2 + 1] = self.source_right[frame];
                }
                for route in &source.routes {
                    match route {
                        SourceRoute::Bus { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.buses[*index][..stereo],
                                &self.source_stereo[..stereo],
                                strip,
                            );
                        }
                        SourceRoute::Sink { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.sink_buffers[*index][..stereo],
                                &self.source_stereo[..stereo],
                                strip,
                            );
                        }
                    }
                }
            } else if source.player {
                // A player's PCM is already interleaved stereo, so both sides
                // run an independent mono chain, exactly as a `device` source
                // does, and the routes read the processed pair.
                let Some(block) = self.player_blocks.get(index) else {
                    continue;
                };
                if block.len() < stereo {
                    continue;
                }
                let gain = source.gain.get() * source.mute.get();
                for frame in 0..frames {
                    self.source_left[frame] = block[frame * 2] * gain;
                    self.source_right[frame] = block[frame * 2 + 1] * gain;
                }
                if source.chains.len() >= 2 {
                    let (left_chain, right_chain) = source.chains.split_at_mut(1);
                    left_chain[0]
                        .process(&mut self.source_left[..frames])
                        .map_err(|error| format!("source {index} inserts (left): {error:?}"))?;
                    right_chain[0]
                        .process(&mut self.source_right[..frames])
                        .map_err(|error| format!("source {index} inserts (right): {error:?}"))?;
                }
                for frame in 0..frames {
                    self.source_stereo[frame * 2] = self.source_left[frame];
                    self.source_stereo[frame * 2 + 1] = self.source_right[frame];
                }
                for route in &source.routes {
                    match route {
                        SourceRoute::Bus { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.buses[*index][..stereo],
                                &self.source_stereo[..stereo],
                                strip,
                            );
                        }
                        SourceRoute::Sink { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.sink_buffers[*index][..stereo],
                                &self.source_stereo[..stereo],
                                strip,
                            );
                        }
                    }
                }
            } else if source.peer {
                // The uplink's mono voice is written to both channels of its
                // own stereo block; the left sample takes the same mono path a
                // `parec` input does, through its strip's gain and pan.
                let Some(block) = self.peer_blocks.get(index) else {
                    continue;
                };
                if block.len() < stereo {
                    continue;
                }
                for frame in 0..frames {
                    self.mono[frame] = block[frame * 2];
                }
                let gain = source.gain.get() * source.mute.get();
                for sample in &mut self.mono[..frames] {
                    *sample *= gain;
                }
                if let Some(chain) = source.chains.get_mut(0) {
                    chain
                        .process(&mut self.mono[..frames])
                        .map_err(|error| format!("source {index} inserts: {error:?}"))?;
                }
                for route in &source.routes {
                    match route {
                        SourceRoute::Bus { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_mono_into_stereo(
                                &mut self.buses[*index][..stereo],
                                &self.mono[..frames],
                                strip,
                            )
                            .map_err(|error| format!("bus {index}: {error:?}"))?;
                        }
                        SourceRoute::Sink { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_mono_into_stereo(
                                &mut self.sink_buffers[*index][..stereo],
                                &self.mono[..frames],
                                strip,
                            )
                            .map_err(|error| format!("sink {index}: {error:?}"))?;
                        }
                    }
                }
            }
        }

        // Then the buses in topological order, so an upstream bus is final
        // before it is added to a downstream one. A send reads its strip's
        // gain and pan every block, as a stereo balance (centre = unity).
        for &bus in &self.order {
            for send in &self.bus_routes[bus] {
                let Some(strip) = &self.strips[send.strip] else {
                    continue;
                };
                let (left, right) = balance(strip.gain.get(), strip.pan.get());
                add_bus(&mut self.buses, bus, send.from, left, right)?;
            }
        }

        // A bus take reads the bus here: after its own sends, before it is
        // balanced into a sink. The WAV is the bus's mix, not the machine's
        // output, so the click and the fallback system mix below cannot reach
        // it.
        if let Some(tap) = self.tap_active.as_mut() {
            if let Some(bus) = self.buses.get(tap.bus) {
                tap.producer.push(&bus[..stereo]);
            }
        }

        // Buses into sinks, after every bus is final.
        for (sink, sends) in self.sink_bus_routes.iter().enumerate() {
            for send in sends {
                let Some(strip) = &self.strips[send.strip] else {
                    continue;
                };
                let (left, right) = balance(strip.gain.get(), strip.pan.get());
                let source = &self.buses[send.from];
                let target = &mut self.sink_buffers[sink];
                for (target, sample) in target[..stereo].chunks_mut(2).zip(source[..stereo].chunks(2)) {
                    target[0] += sample[0] * left;
                    target[1] += sample[1] * right;
                }
            }
        }

        // Every sink sums into the one stereo pair the device plays.
        for sink in &self.sink_buffers {
            for (target, sample) in self.mix[..stereo].iter_mut().zip(&sink[..stereo]) {
                *target += sample;
            }
        }

        // The machine's own audio, when the plan did not route it: Music,
        // video, notifications and a call stay audible on an empty plan. A
        // plan that routes a `device` source owns it, including a mute.
        if !self.system_routed {
            for (target, sample) in self.mix[..stereo].iter_mut().zip(&self.system[..stereo]) {
                *target += sample;
            }
        }

        // A bus take's click is monitoring only: it joins the output here,
        // after the tap has read the bus, so the performer hears it and the
        // WAV cannot. `render_into` adds pre-built samples.
        if let Some(tap) = self.tap_active.as_mut() {
            if let Some(click) = tap.click.as_mut() {
                click.render_into(&mut self.mix[..stereo]);
            }
        }
        Ok(())
    }
}

impl ListenSink for Patchbay {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        Patchbay::prepared(self, rate, period, channels)
    }

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        Patchbay::block(self, input, output)
    }

    fn block_with_system(
        &mut self,
        input: &[i16],
        system: &[f32],
        output: &mut [i16],
    ) -> Result<(), String> {
        Patchbay::block_with_system_f32(self, input, system, output)
    }
}

/// Add `from` into `to` with a stereo balance. The two buffers are distinct
/// buses, so `split_at_mut` lends one of them immutably while the other is
/// written; a send from a bus to itself never reaches here (the compile
/// refuses a cycle).
fn add_bus(buses: &mut [Vec<f32>], to: usize, from: usize, left: f32, right: f32) -> Result<(), String> {
    if from == to {
        return Err("a bus cannot send to itself".to_string());
    }
    let (before, after) = buses.split_at_mut(to.max(from));
    let (source, target) = if from < to {
        (&before[from], &mut after[0])
    } else {
        (&after[0], &mut before[to])
    };
    if source.len() != target.len() {
        return Err("a bus send's buffers are not the same length".to_string());
    }
    for (target, sample) in target.chunks_mut(2).zip(source.chunks(2)) {
        target[0] += sample[0] * left;
        target[1] += sample[1] * right;
    }
    Ok(())
}

/// The equal-power balance a stereo send uses: unity in both channels at
/// centre, silence on the far side at the end of the sweep.
fn balance(gain: f32, pan: f32) -> (f32, f32) {
    let pan = pan.clamp(-1.0, 1.0);
    let left = if pan <= 0.0 { 1.0 } else { 1.0 - pan };
    let right = if pan >= 0.0 { 1.0 } else { 1.0 + pan };
    (gain * left, gain * right)
}

/// Whether a source has a stream of its own to route on this machine: a bound
/// interface channel, the system mix, the reception handset, an uplink peer or
/// a local player. A source declared for another machine has none, so its
/// routes contribute nothing and it is named in the summary's `silent`.
fn source_feeds(source: &Source) -> bool {
    source.channel.is_some()
        || source.system
        || source.handset
        || source.peer
        || source.player
}

/// Whether any local `input` source is both bound and routed. The one fact
/// behind [`Patchbay::wants_input`] and the summary's `mode`.
fn sources_want_input(sources: &[Source]) -> bool {
    sources
        .iter()
        .any(|source| source.channel.is_some() && !source.peer && !source.routes.is_empty())
}

/// Every bound local `input` and the node it captures: the plan's own name, or
/// the Pulse alias for the machine's default source. The status line reports
/// this, so a person can see which microphone a take will use. A `peer` source
/// has no capture node of its own, so it is not an input.
fn bound_inputs(sources: &[Source]) -> Vec<(String, String)> {
    sources
        .iter()
        .filter(|source| source.channel.is_some() && !source.peer)
        .map(|source| {
            (
                source.id.clone(),
                source
                    .node
                    .clone()
                    .unwrap_or_else(|| DEFAULT_INPUT.to_string()),
            )
        })
        .collect()
}

/// Add one interleaved stereo block into another. A stereo source already has
/// an image, so a centred strip is unity in both channels and pan is a balance.
fn mix_stereo_into_stereo(out: &mut [f32], input: &[f32], strip: &Strip) {
    let (left, right) = balance(strip.gain.get(), strip.pan.get());
    for (target, sample) in out.chunks_mut(2).zip(input.chunks(2)) {
        target[0] += sample[0] * left;
        target[1] += sample[1] * right;
    }
}

/// The bus evaluation order: Kahn's algorithm over the bus -> bus edges. A
/// plan with a cycle is refused rather than run.
fn bus_order(buses: usize, edges: &[(usize, usize)]) -> Result<Vec<usize>, String> {
    let mut indegree = vec![0usize; buses];
    let mut out: Vec<Vec<usize>> = vec![Vec::new(); buses];
    for &(from, to) in edges {
        out[from].push(to);
        indegree[to] += 1;
    }
    let mut ready: Vec<usize> = (0..buses).filter(|bus| indegree[*bus] == 0).collect();
    let mut order = Vec::with_capacity(buses);
    while let Some(bus) = ready.pop() {
        order.push(bus);
        for &next in &out[bus] {
            indegree[next] -= 1;
            if indegree[next] == 0 {
                ready.push(next);
            }
        }
    }
    if order.len() != buses {
        return Err("the plan's buses form a loop; a node that sums its own output never settles".to_string());
    }
    Ok(order)
}

// ---- the plan's small JSON --------------------------------------------------

#[derive(Clone, Copy)]
enum NodeRef {
    Source(usize),
    Bus(usize),
    Sink(usize),
}

fn resolve(
    seen: &[String],
    sources: &[Source],
    buses: &[String],
    sinks: &[Sink],
    id: &str,
) -> Result<NodeRef, String> {
    if !seen.iter().any(|name| name == id) {
        return Err(format!("the plan routes to or from {id}, which it does not declare"));
    }
    if let Some(index) = sources.iter().position(|source| source.id == id) {
        return Ok(NodeRef::Source(index));
    }
    if let Some(index) = buses.iter().position(|bus| bus == id) {
        return Ok(NodeRef::Bus(index));
    }
    if let Some(index) = sinks.iter().position(|sink| sink.id == id) {
        return Ok(NodeRef::Sink(index));
    }
    Err(format!("the plan routes to or from {id}, which it does not declare"))
}

fn list<'a>(object: &'a Object, key: &str) -> Result<&'a [Value], String> {
    match get(object, key) {
        None | Some(Value::Null) => Ok(&[]),
        Some(Value::Arr(values)) => Ok(values),
        Some(_) => Err(format!("\"{key}\" must be an array")),
    }
}

fn as_object<'a>(value: &'a Value, what: &str) -> Result<&'a Object, String> {
    match value {
        Value::Obj(object) => Ok(object),
        _ => Err(format!("{what} must be an object")),
    }
}

fn text(object: &Object, key: &str) -> Option<String> {
    match get(object, key) {
        Some(Value::Str(value)) if !value.is_empty() => Some(value.clone()),
        _ => None,
    }
}

fn node_id(object: &Object, what: &str) -> Result<String, String> {
    text(object, "id").ok_or_else(|| format!("every {what} needs an \"id\" string"))
}

/// The longest capture node name a plan may carry, and the characters it may
/// use. The manager writes the same rule (`audio_plan_node_valid`); the engine
/// repeats it because `--plan` can be handed a hand-written file, and a name
/// that begins with `-` would be read by `parec` as an option.
const NODE_NAME_MAX: usize = 200;

fn capture_node_name_ok(name: &str) -> bool {
    let mut characters = name.chars();
    match characters.next() {
        Some(first) if first.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    name.len() <= NODE_NAME_MAX
        && characters.all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '@' | '+' | '-')
        })
}

/// A source's optional `"node"`: the capture node an `input` listens to.
/// Absent or empty means the machine's default source. Any other kind has no
/// capture of its own to name, so a `node` there is not a capture.
fn source_node(object: &Object, kind: &str) -> Result<Option<String>, String> {
    let Some(node) = text(object, "node") else {
        return Ok(None);
    };
    if kind != "input" {
        return Ok(None);
    }
    if !capture_node_name_ok(&node) {
        return Err(format!(
            "the source names the capture node \"{node}\"; a PipeWire source name is letters, digits and . _ : @ + -",
        ));
    }
    Ok(Some(node))
}

/// A source's optional insert chain. The contract's names and the engine's
/// [`InsertKind`] are the authority (`docs/studio-effects.md`): a string is an
/// effect name, and an object is the same name with an optional footswitch and
/// an optional control map, so a saved page can keep a bypassed pedal in the
/// rack and an effect can start where the player left it.
///
/// A name the engine cannot build is refused rather than dropped: a source
/// that asked for a pedal it never gets is a plan that lies about its sound.
/// A control the effect does not have is refused for the same reason. The
/// values are in the contract's units, so the delay's time is milliseconds and
/// the socket's own `native_value` conversion applies here too.
struct PlannedInsert {
    kind: InsertKind,
    bypass: bool,
    controls: Vec<(String, f32)>,
}

fn source_inserts(object: &Object, id: &str) -> Result<Vec<PlannedInsert>, String> {
    let list = match get(object, "inserts") {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Arr(list)) => list,
        Some(_) => return Err(format!("{id} has an \"inserts\" that is not an array")),
    };
    let mut planned = Vec::with_capacity(list.len());
    for entry in list {
        let (name, bypass, controls) = match entry {
            Value::Str(name) => (name.clone(), false, Vec::new()),
            Value::Obj(fields) => {
                let name = text(fields, "name")
                    .or_else(|| text(fields, "kind"))
                    .ok_or_else(|| format!("{id} has an insert with no \"name\""))?;
                let bypass = match get(fields, "bypass") {
                    None | Some(Value::Null) => false,
                    Some(Value::Bool(value)) => *value,
                    Some(Value::Num(value)) if *value == 0.0 => false,
                    Some(Value::Num(value)) if *value == 1.0 => true,
                    Some(_) => {
                        return Err(format!(
                            "{id} has an insert \"{name}\" whose \"bypass\" is not true or false"
                        ))
                    }
                };
                let mut controls = Vec::new();
                match get(fields, "controls") {
                    None | Some(Value::Null) => {}
                    Some(Value::Obj(map)) => {
                        for (control, value) in map {
                            let value = match value {
                                Value::Num(value) if value.is_finite() => *value as f32,
                                _ => {
                                    return Err(format!(
                                        "{id} has insert \"{name}\" control \"{control}\" that is not a finite number"
                                    ))
                                }
                            };
                            controls.push((control.clone(), value));
                        }
                    }
                    Some(_) => {
                        return Err(format!(
                            "{id} has insert \"{name}\" whose \"controls\" is not an object"
                        ))
                    }
                }
                (name, bypass, controls)
            }
            _ => {
                return Err(format!(
                    "{id} has an insert that is not a name or an object with a \"name\""
                ))
            }
        };
        let kind = InsertKind::parse(&name)
            .ok_or_else(|| format!("{id} names insert \"{name}\"; the engine does not build it"))?;
        for (control, _) in &controls {
            if kind.control_index(control).is_none() {
                return Err(format!(
                    "{id} names insert \"{name}\" control \"{control}\"; the effect has no such control"
                ));
            }
        }
        planned.push(PlannedInsert {
            kind,
            bypass,
            controls,
        });
    }
    Ok(planned)
}

/// A source's own trim, defaulting to unity. A negative gain or one past the
/// engine's +12 dB trim is a mistake in the plan rather than a value to clamp
/// silently, exactly as a route gain is.
fn source_gain(object: &Object, id: &str) -> Result<f32, String> {
    let gain = number(object, "gain")?.unwrap_or(1.0);
    if !(0.0..=Channel::MAX_GAIN).contains(&gain) {
        return Err(format!(
            "{id} has gain {gain}; a source gain is between 0 and {}",
            Channel::MAX_GAIN
        ));
    }
    Ok(gain)
}

/// A node's optional `"machine"` host. Absent or empty means "this machine",
/// which [`text`] already folds into `None`; a non-empty value is compared
/// case-insensitively against the engine's machine by the caller.
fn node_machine(object: &Object) -> Option<String> {
    text(object, "machine")
}

fn node_ref(object: &Object, key: &str) -> Result<String, String> {
    text(object, key).ok_or_else(|| format!("every route needs a \"{key}\" node id"))
}

/// The longest declared peer latency the engine will place: two seconds. A
/// larger number is a mistake in the plan rather than a value to clamp
/// silently, because clamping would place the source at a position the plan
/// never asked for. The manager writes `latency_ms` on every source; this
/// bound is the engine's own, checked only where the number is honoured.
const PEER_LATENCY_MAX_MS: f64 = 2_000.0;

/// A `peer` source's optional `"latency_ms"`: the capture/pipeline latency the
/// phone or deck carries, in milliseconds. A finite, non-negative number no
/// larger than [`PEER_LATENCY_MAX_MS`] is accepted; anything else is refused
/// by name (the source and the field), so a bad declaration is visible rather
/// than silently treated as zero.
fn peer_latency_ms(object: &Object, id: &str) -> Result<Option<f64>, String> {
    declared_ms(object, id, "peer", "latency_ms", "a latency", PEER_LATENCY_MAX_MS)
}

/// The longest declared peer buffer the engine will read with: two seconds,
/// the same bound as the declared latency. A larger number is a mistake in the
/// plan rather than a value to clamp silently.
const PEER_BUFFER_MAX_MS: f64 = 2_000.0;

/// A `peer` source's optional `"buffer_ms"`: how far behind the master clock
/// the uplink reads this source's audio. A late path (a deck on Wi-Fi) needs
/// more slack than the engine's one-window default; a plan may say so per
/// source instead of every peer paying for the slowest one. A finite,
/// non-negative number no larger than [`PEER_BUFFER_MAX_MS`] is accepted;
/// anything else is refused by name, like the latency.
fn peer_buffer_ms(object: &Object, id: &str) -> Result<Option<f64>, String> {
    declared_ms(object, id, "peer", "buffer_ms", "a buffer", PEER_BUFFER_MAX_MS)
}

/// The longest lead a `player` may declare: two seconds, the same bound as a
/// peer's placement. A player's lead is how far ahead of its arrival the local
/// audio input anchors its first frame, so a larger number is a plan that would
/// buffer more than a person can play along with.
const PLAYER_LEAD_MAX_MS: f64 = 2_000.0;

/// A `player` source's optional `"lead_ms"`: how far ahead of its arrival the
/// first frame is placed on the master timeline. The manager writes a small
/// lead (about a tenth of a second) so the forwarder's own jitter never starves
/// the reader; a value outside the bound is refused by name, like a peer's.
fn player_lead_ms(object: &Object, id: &str) -> Result<Option<f64>, String> {
    declared_ms(object, id, "player", "lead_ms", "a lead", PLAYER_LEAD_MAX_MS)
}

/// The longest read buffer a `player` may declare: two seconds, like a peer's.
const PLAYER_BUFFER_MAX_MS: f64 = 2_000.0;

/// A `player` source's optional `"buffer_ms"`: how far behind the clock the
/// local audio input reads this source. It is the same fact a peer declares,
/// with the same bound, because both are rings read by a reader of their own.
fn player_buffer_ms(object: &Object, id: &str) -> Result<Option<f64>, String> {
    declared_ms(object, id, "player", "buffer_ms", "a buffer", PLAYER_BUFFER_MAX_MS)
}

/// One source's optional millisecond declaration. A finite, non-negative
/// number no larger than `max` is accepted; anything else is refused by name
/// (the role, the source and the field), so a bad declaration is visible
/// rather than silently treated as zero.
fn declared_ms(
    object: &Object,
    id: &str,
    role: &str,
    field: &str,
    what: &str,
    max: f64,
) -> Result<Option<f64>, String> {
    match get(object, field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Num(value)) if !value.is_finite() => Err(format!(
            "the {role} source {id} has a \"{field}\" that is not finite; {what} is a finite number of milliseconds"
        )),
        Some(Value::Num(value)) if *value < 0.0 => Err(format!(
            "the {role} source {id} has \"{field}\": {value}; {what} cannot be negative"
        )),
        Some(Value::Num(value)) if *value > max => Err(format!(
            "the {role} source {id} has \"{field}\": {value}; the engine accepts at most {max} ms"
        )),
        Some(Value::Num(value)) => Ok(Some(*value)),
        Some(_) => Err(format!(
            "the {role} source {id} has a \"{field}\" that is not a number; {what} is milliseconds"
        )),
    }
}

fn number(object: &Object, key: &str) -> Result<Option<f32>, String> {
    match get(object, key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Num(value)) if value.is_finite() => Ok(Some(*value as f32)),
        Some(_) => Err(format!("\"{key}\" must be a finite number")),
    }
}

fn integer(object: &Object, key: &str) -> Result<Option<usize>, String> {
    match get(object, key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Num(value))
            if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 =>
        {
            Ok(Some(*value as usize))
        }
        Some(_) => Err(format!("\"{key}\" must be a whole, non-negative number")),
    }
}

// ---- the null run -----------------------------------------------------------

/// One null patch run, mirroring [`jawn_audio::listen::run_null`]. The null
/// backend is not paced: it exists to exercise the graph on a machine with no
/// sound card.
pub fn run_null(
    patchbay: &mut Patchbay,
    rate: u32,
    period: usize,
    channels: usize,
    total: Option<u64>,
    tone: Option<f32>,
    stop: &std::sync::atomic::AtomicBool,
    mut progress: impl FnMut(u64),
) -> Result<u64, String> {
    if period == 0 {
        return Err("a patch block must hold at least one frame".to_string());
    }
    if channels == 0 {
        return Err("a patch needs at least one capture channel".to_string());
    }
    patchbay.prepared(rate, period, channels)?;

    let mut device = NullDevice::new(rate, period, channels);
    if let Some(hz) = tone {
        device = device.with_tone(hz);
    }

    let mut source = vec![0.0f32; period * channels];
    let mut stereo = vec![0.0f32; period * 2];
    let mut frames = 0u64;

    loop {
        if stop.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        let want = match total {
            Some(total) if frames >= total => break,
            Some(total) => (total - frames).min(period as u64) as usize,
            None => period,
        };
        device
            .process(&mut source)
            .map_err(|error| format!("device: {error:?}"))?;
        let samples = want * channels;
        patchbay.block_f32(&source[..samples], &mut stereo[..want * 2])?;
        frames += want as u64;
        progress(frames);
        // Let a client polling `status` run between blocks.
        std::thread::yield_now();
    }

    Ok(frames)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::socket::parse_object;
    use std::sync::atomic::AtomicBool;

    fn bay(json: &str) -> Patchbay {
        let object = parse_object(json).expect("the plan parses");
        Patchbay::from_object(&object, 2, "local").expect("the plan compiles")
    }

    fn bay_for(json: &str, machine: &str) -> Patchbay {
        let object = parse_object(json).expect("the plan parses");
        Patchbay::from_object(&object, 2, machine).expect("the plan compiles")
    }

    /// A compile whose "does this machine offer this source?" answer is the
    /// test's own, so a microphone the test machine does not have can still be
    /// named (and an unknown one can be proven unknown).
    fn bay_probing(json: &str, probe: &dyn Fn(&str) -> Option<bool>) -> Patchbay {
        let object = parse_object(json).expect("the plan parses");
        Patchbay::from_object_with_probe(&object, 2, "local", probe)
            .expect("the plan compiles")
    }

    fn prepared(json: &str) -> Patchbay {
        let mut patchbay = bay(json);
        patchbay.prepared(48_000, 4, 2).expect("prepare");
        patchbay
    }

    /// The null run needs a stop flag; the tests that use it never set one and
    /// rely on `total`.
    fn never() -> AtomicBool {
        AtomicBool::new(false)
    }

    // Two sources into a bus, the bus into the one stereo sink. Channel 0 is
    // 0.5, channel 1 is 0.25; a centred source sits at 1/√2 in each speaker.
    const TWO_INTO_ONE: &str = r#"{
        "sources":[{"id":"in0","kind":"input","channel":0},{"id":"in1","kind":"input","channel":1}],
        "buses":[{"id":"house"}],
        "sinks":[{"id":"out","kind":"interface","channel":0}],
        "routes":[
            {"from":"in0","to":"house","gain":1,"pan":0},
            {"from":"in1","to":"house","gain":1,"pan":0},
            {"from":"house","to":"out","gain":1,"pan":0}
        ]
    }"#;

    #[test]
    fn a_plan_compiles_and_reports_its_shape() {
        let patchbay = bay(TWO_INTO_ONE);
        let summary = patchbay.summary();
        assert_eq!(summary.sources, 2);
        assert_eq!(summary.buses, 1);
        assert_eq!(summary.sinks, 1);
        assert_eq!(summary.routes, 3);
        assert_eq!(summary.bound_sources, 2);
        assert_eq!(summary.bound_sinks, 1);
        assert!(summary.silent.is_empty());
    }

    #[test]
    fn two_sources_sum_into_one_bus() {
        let mut patchbay = prepared(TWO_INTO_ONE);
        // 4 frames, interleaved: channel 0 = 0.5, channel 1 = 0.25.
        let input = [0.5f32, 0.25, 0.5, 0.25, 0.5, 0.25, 0.5, 0.25];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        // 0.75 at centre is 0.75/√2 in each speaker.
        let expected = 0.75f32 / std::f32::consts::SQRT_2;
        for frame in output.chunks(2) {
            assert!((frame[0] - expected).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - expected).abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_bus_tap_records_the_bus_it_names() {
        let mut patchbay = prepared(TWO_INTO_ONE);
        assert_eq!(patchbay.bus_ids(), ["house"]);
        let tap = patchbay.tap();
        let (producer, consumer) = jawn_audio::monbus::new(4096);
        assert!(tap.attach(0, producer, None), "the plan has bus 0");
        assert!(
            !tap.attach(1, jawn_audio::monbus::new(4096).0, None),
            "an index outside the plan is refused"
        );

        let input = [0.5f32, 0.25, 0.5, 0.25, 0.5, 0.25, 0.5, 0.25];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");

        let mut recorded = [0.0f32; 8];
        assert_eq!(consumer.pop(&mut recorded), 4, "the tap received the block");
        let expected = 0.75f32 / std::f32::consts::SQRT_2;
        for frame in recorded.chunks(2) {
            assert!((frame[0] - expected).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - expected).abs() < 1e-5, "{frame:?}");
        }

        // A detached tap stops receiving: the patch keeps playing, the WAV
        // does not grow.
        tap.detach();
        patchbay.block_f32(&input, &mut output).expect("run");
        let mut after = [7.0f32; 8];
        assert_eq!(consumer.pop(&mut after), 0, "a detached tap receives nothing");
    }

    #[test]
    fn a_bus_take_click_plays_on_the_output_and_never_in_the_bus() {
        let mut patchbay = bay(TWO_INTO_ONE);
        patchbay.prepared(48_000, 1024, 2).expect("prepare");
        let tap = patchbay.tap();
        let (producer, consumer) = jawn_audio::monbus::new(4096);
        let click = StandaloneClick::new(
            jawn_audio::playback::ClickSpec::new(120.0, 4, 1.0).expect("click"),
            48_000,
            1024,
        );
        assert!(tap.attach(0, producer, Some(click)));

        let input: Vec<f32> = (0..1024).flat_map(|_| [0.5f32, 0.25]).collect();
        let mut output = vec![0.0f32; 1024 * 2];
        patchbay.block_f32(&input, &mut output).expect("run");

        let mut recorded = vec![0.0f32; 1024 * 2];
        assert_eq!(consumer.pop(&mut recorded), 1024);
        let bus = 0.75f32 / std::f32::consts::SQRT_2;
        for frame in recorded.chunks(2) {
            assert!((frame[0] - bus).abs() < 1e-5, "the click reached the bus: {frame:?}");
            assert!((frame[1] - bus).abs() < 1e-5, "the click reached the bus: {frame:?}");
        }
        assert!(
            output
                .chunks(2)
                .any(|frame| (frame[0] - bus).abs() > 1e-3),
            "the click never reached the patch output"
        );
    }

    #[test]
    fn a_source_to_sink_route_bypasses_the_buses() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":1,"pan":-1}]
            }"#,
        );
        let input = [0.5f32, 0.0, 0.5, 0.0, 0.5, 0.0, 0.5, 0.0];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        for frame in output.chunks(2) {
            assert!((frame[0] - 0.5).abs() < 1e-5, "left {frame:?}");
            assert!(frame[1].abs() < 1e-5, "right {frame:?}");
        }
    }

    #[test]
    fn a_bus_send_adds_the_upstream_bus() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0}],
                "buses":[{"id":"a"},{"id":"b"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"in0","to":"a","gain":1,"pan":-1},
                    {"from":"a","to":"b","gain":0.5,"pan":0},
                    {"from":"b","to":"out","gain":1,"pan":0}
                ]
            }"#,
        );
        let input = [0.4f32, 0.0, 0.4, 0.0, 0.4, 0.0, 0.4, 0.0];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        // 0.4 at hard left, then 0.5 of it into b, then b to the sink at
        // unity: a stereo send keeps the image, so the left channel carries
        // 0.2 and the right stays silent.
        let expected = 0.2f32;
        for frame in output.chunks(2) {
            assert!((frame[0] - expected).abs() < 1e-5, "{frame:?}");
            assert!(frame[1].abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_muted_route_contributes_nothing() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"in0","to":"house","mute":1},
                    {"from":"house","to":"out","mute":0}
                ]
            }"#,
        );
        let input = [0.9f32, 0.0, 0.9, 0.0, 0.9, 0.0, 0.9, 0.0];
        let mut output = [1.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        assert!(output.iter().all(|sample| *sample == 0.0), "{output:?}");
    }

    #[test]
    fn a_mute_that_is_not_a_boolean_is_refused() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"in0","kind":"input"}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","mute":"yes"}]
            }"#,
        )
        .expect("parse");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
        assert!(error.contains("mute"), "{error}");
    }

    #[test]
    fn a_peer_source_is_pending_not_silent() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"phone","kind":"peer"}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"phone","to":"house"},{"from":"house","to":"out"}]
            }"#,
        );
        let summary = patchbay.summary();
        assert_eq!(summary.bound_sources, 1);
        assert!(summary.silent.is_empty(), "{:?}", summary.silent);
        assert_eq!(summary.peer, "pending");
        assert_eq!(
            patchbay.wants_peer(),
            vec![(0, "phone".to_string(), 0.0, None)],
            "a routed peer needs one ring"
        );
        assert!(!patchbay.wants_input(), "a peer is not a card capture");
    }

    #[test]
    fn a_peer_declares_its_latency_and_two_peers_can_differ() {
        let patchbay = bay(
            r#"{
                "sources":[
                    {"id":"phone","kind":"peer","latency_ms":30},
                    {"id":"deck","kind":"peer","latency_ms":12.5}
                ],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"phone","to":"house"},
                    {"from":"deck","to":"house"},
                    {"from":"house","to":"out"}
                ]
            }"#,
        );
        assert_eq!(
            patchbay.wants_peer(),
            vec![
                (0, "phone".to_string(), 30.0, None),
                (1, "deck".to_string(), 12.5, None)
            ],
            "each peer carries its own declaration"
        );
    }

    #[test]
    fn a_peer_buffer_is_declared_per_source() {
        let patchbay = bay(
            r#"{
                "sources":[
                    {"id":"phone","kind":"peer","latency_ms":30},
                    {"id":"deck","kind":"peer","latency_ms":40,"buffer_ms":200}
                ],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"phone","to":"house"},
                    {"from":"deck","to":"house"},
                    {"from":"house","to":"out"}
                ]
            }"#,
        );
        assert_eq!(
            patchbay.wants_peer(),
            vec![
                (0, "phone".to_string(), 30.0, None),
                (1, "deck".to_string(), 40.0, Some(200.0))
            ],
            "the deck carries its own read buffer; the peer that declares none keeps the default"
        );
    }

    #[test]
    fn a_peer_buffer_outside_the_bounds_is_refused() {
        for declaration in ["-1", "2001", "\"200\""] {
            let object = parse_object(&format!(
                r#"{{
                    "sources":[{{"id":"deck","kind":"peer","buffer_ms":{declaration}}}],
                    "buses":[], "sinks":[{{"id":"out","kind":"interface"}}],
                    "routes":[{{"from":"deck","to":"out"}}]
                }}"#
            ))
            .expect("parse");
            let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
            assert!(error.contains("buffer_ms"), "{error}");
            assert!(error.contains("deck"), "the refusal names the source: {error}");
        }

        let at_the_bound = bay(
            r#"{
                "sources":[{"id":"deck","kind":"peer","buffer_ms":2000}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"deck","to":"out"}]
            }"#,
        );
        assert_eq!(
            at_the_bound.wants_peer(),
            vec![(0, "deck".to_string(), 0.0, Some(2000.0))]
        );
    }

    #[test]
    fn a_peer_latency_outside_the_bounds_is_refused() {
        for declaration in ["-1", "2001", "\"30\""] {
            let object = parse_object(&format!(
                r#"{{
                    "sources":[{{"id":"phone","kind":"peer","latency_ms":{declaration}}}],
                    "buses":[], "sinks":[{{"id":"out","kind":"interface"}}],
                    "routes":[{{"from":"phone","to":"out"}}]
                }}"#
            ))
            .expect("parse");
            let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
            assert!(error.contains("latency_ms"), "{error}");
            assert!(error.contains("phone"), "the refusal names the source: {error}");
        }

        let at_the_bound = bay(
            r#"{
                "sources":[{"id":"phone","kind":"peer","latency_ms":2000}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"phone","to":"out"}]
            }"#,
        );
        assert_eq!(
            at_the_bound.wants_peer(),
            vec![(0, "phone".to_string(), 2000.0, None)]
        );
    }

    #[test]
    fn a_local_input_latency_is_kept_but_not_refused() {
        // The manager writes `latency_ms` on every source; only a peer's is
        // placed by this engine, so an input's must not break the plan.
        let patchbay = bay(
            r#"{
                "sources":[{"id":"gtr","kind":"input","channel":0,"latency_ms":2}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"gtr","to":"out"}]
            }"#,
        );
        assert_eq!(patchbay.summary().bound_sources, 1);
        assert!(patchbay.wants_peer().is_empty());
    }

    #[test]
    fn a_player_source_is_pending_not_silent() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"synth","kind":"player","lead_ms":100}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"synth","to":"house"},{"from":"house","to":"out"}]
            }"#,
        );
        let summary = patchbay.summary();
        assert_eq!(summary.bound_sources, 1);
        assert!(summary.silent.is_empty(), "{:?}", summary.silent);
        assert_eq!(summary.player, "pending");
        assert_eq!(summary.peer, "off");
        assert_eq!(
            patchbay.wants_player(),
            vec![(0, "synth".to_string(), 100.0, None)],
            "a routed player carries its lead and takes the default buffer"
        );
        assert!(!patchbay.wants_input(), "a player is not a card capture");
    }

    #[test]
    fn a_player_on_another_machine_is_silent() {
        let patchbay = bay_for(
            r#"{
                "sources":[{"id":"synth","kind":"player","machine":"elsewhere"}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"synth","to":"out"}]
            }"#,
            "local",
        );
        assert_eq!(patchbay.summary().silent, vec!["synth".to_string()]);
        assert_eq!(patchbay.summary().player, "off");
        assert!(patchbay.wants_player().is_empty());
        assert!(patchbay.wants_peer().is_empty());
    }

    #[test]
    fn a_player_lead_outside_the_bounds_is_refused() {
        for declaration in ["-1", "2001", "\"100\""] {
            let object = parse_object(&format!(
                r#"{{
                    "sources":[{{"id":"synth","kind":"player","lead_ms":{declaration}}}],
                    "buses":[], "sinks":[{{"id":"out","kind":"interface"}}],
                    "routes":[{{"from":"synth","to":"out"}}]
                }}"#
            ))
            .expect("parse");
            let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
            assert!(error.contains("lead_ms"), "{error}");
            assert!(
                error.contains("synth"),
                "the refusal names the source: {error}"
            );
        }
    }

    #[test]
    fn a_player_ring_mixes_stereo_like_a_parec_input() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"synth","kind":"player","lead_ms":100}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"synth","to":"house"},{"from":"house","to":"out"}]
            }"#,
        );
        let (producer, consumer) = jawn_audio::monbus::new(jawn_audio::monbus::MIN_FRAMES);
        patchbay.attach_player(0, consumer);
        assert_eq!(patchbay.summary().player, "capturing");
        // Four stereo frames: left 0.5, right 0.25.
        producer.push(&[0.5, 0.25, 0.5, 0.25, 0.5, 0.25, 0.5, 0.25]);

        let input = [0.0f32; 8];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        // A stereo source keeps its image: a centred route is unity in both
        // speakers, not an equal-power pan of one mono channel.
        for frame in output.chunks(2) {
            assert!((frame[0] - 0.5).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - 0.25).abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_peer_ring_mixes_like_a_parec_input() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"phone","kind":"peer"}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"phone","to":"house"},{"from":"house","to":"out"}]
            }"#,
        );
        let (producer, consumer) = jawn_audio::monbus::new(jawn_audio::monbus::MIN_FRAMES);
        patchbay.attach_input(0, consumer);
        assert_eq!(patchbay.summary().peer, "capturing");
        producer.push(&[0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]);

        let input = [0.0f32; 8];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        let expected = 0.5f32 / std::f32::consts::SQRT_2;
        for frame in output.chunks(2) {
            assert!((frame[0] - expected).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - expected).abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_peer_mixes_with_every_interface_channel_taken() {
        // The table's two UM2 channels are both local inputs; the peer voice
        // still binds because its uplink ring needs no channel of its own.
        let mut patchbay = prepared(
            r#"{
                "sources":[
                    {"id":"um2-in0","kind":"input","channel":0},
                    {"id":"um2-in1","kind":"input","channel":1},
                    {"id":"phone","kind":"peer"}
                ],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"um2-in0","to":"house"},
                    {"from":"um2-in1","to":"house"},
                    {"from":"phone","to":"house","gain":0.5},
                    {"from":"house","to":"out"}
                ]
            }"#,
        );
        assert!(
            !patchbay.summary().silent.contains(&"phone".to_string()),
            "{:?}",
            patchbay.summary().silent
        );
        assert_eq!(
            patchbay.wants_peer(),
            vec![(2, "phone".to_string(), 0.0, None)],
            "the peer is the third source, after both interface inputs"
        );
        assert_eq!(patchbay.summary().peer, "pending");

        let (producer, consumer) = jawn_audio::monbus::new(jawn_audio::monbus::MIN_FRAMES);
        patchbay.attach_input(2, consumer);
        assert_eq!(patchbay.summary().peer, "capturing");
        producer.push(&[0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]);

        // Both interface channels carry silence, so only the peer reaches the
        // output: 0.5 at the strip's half gain, centred.
        let input = [0.0f32; 8];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        let expected = 0.25f32 / std::f32::consts::SQRT_2;
        for frame in output.chunks(2) {
            assert!((frame[0] - expected).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - expected).abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_peer_on_another_machine_stays_silent() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"phone","kind":"peer","machine":"elsewhere"}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"phone","to":"house"},{"from":"house","to":"out"}]
            }"#,
        );
        let summary = patchbay.summary();
        assert_eq!(summary.bound_sources, 0);
        assert_eq!(summary.silent, vec!["phone".to_string()]);
        assert_eq!(summary.peer, "off");
        assert!(patchbay.wants_peer().is_empty());
    }

    #[test]
    fn a_source_channel_wider_than_the_device_is_silent() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"in9","kind":"input","channel":9}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in9","to":"out"}]
            }"#,
        );
        assert_eq!(patchbay.summary().silent, vec!["in9".to_string()]);
    }

    #[test]
    fn a_zone_sink_is_silent_and_named() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"in0","kind":"input"}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"amp","kind":"zone"}],
                "routes":[{"from":"in0","to":"house"},{"from":"house","to":"amp"}]
            }"#,
        );
        assert_eq!(patchbay.summary().bound_sinks, 0);
        assert!(patchbay.summary().silent.contains(&"amp".to_string()));
    }

    #[test]
    fn an_unknown_endpoint_is_refused() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"in0","kind":"input"}],
                "buses":[], "sinks":[],
                "routes":[{"from":"in0","to":"ghost"}]
            }"#,
        )
        .expect("parse");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
        assert!(error.contains("ghost"), "{error}");
    }

    #[test]
    fn a_bus_cycle_is_refused() {
        let object = parse_object(
            r#"{
                "sources":[], "sinks":[{"id":"out","kind":"interface"}],
                "buses":[{"id":"a"},{"id":"b"}],
                "routes":[
                    {"from":"a","to":"b"},
                    {"from":"b","to":"a"},
                    {"from":"a","to":"out"}
                ]
            }"#,
        )
        .expect("parse");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
        assert!(error.contains("loop"), "{error}");
    }

    #[test]
    fn a_route_delay_is_refused_rather_than_ignored() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"in0","kind":"input"}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","delay_ms":12}]
            }"#,
        )
        .expect("parse");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
        assert!(error.contains("delay"), "{error}");
    }

    #[test]
    fn a_gain_outside_the_range_is_refused() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"in0","kind":"input"}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":5}]
            }"#,
        )
        .expect("parse");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
        assert!(error.contains("gain"), "{error}");
    }

    #[test]
    fn a_sink_cannot_be_the_start_of_a_route() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"in0","kind":"input"}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"out","to":"in0"}]
            }"#,
        )
        .expect("parse");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
        assert!(error.contains("sink"), "{error}");
    }

    #[test]
    fn the_i16_path_round_trips_the_mix() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":1}],
                "buses":[], "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":1,"pan":1}]
            }"#,
        );
        // Channel 1 is 16384 = 0.5; hard right puts it in the right speaker.
        let input = [0i16, 16_384, 0, 16_384, 0, 16_384, 0, 16_384];
        let mut output = [7i16; 8];
        patchbay.block(&input, &mut output).expect("run");
        for frame in output.chunks(2) {
            assert_eq!(frame[0], 0, "{frame:?}");
            assert!((frame[1] - 16_384).abs() <= 1, "{frame:?}");
        }
    }

    #[test]
    fn a_null_run_renders_exactly_the_frames_asked_for() {
        let mut patchbay = bay(TWO_INTO_ONE);
        let stop = never();
        let frames = run_null(
            &mut patchbay,
            48_000,
            64,
            2,
            Some(300),
            Some(440.0),
            &stop,
            |_| {},
        )
        .expect("run");
        assert_eq!(frames, 300);
    }

    // --- machine attribution -------------------------------------------------

    const ONE_INPUT: &str = r#"{
        "sources":[{"id":"in0","kind":"input","channel":0}],
        "buses":[{"id":"house"}],
        "sinks":[{"id":"out","kind":"interface"}],
        "routes":[{"from":"in0","to":"house"},{"from":"house","to":"out"}]
    }"#;

    #[test]
    fn an_absent_machine_is_this_machine() {
        let patchbay = bay_for(ONE_INPUT, "table");
        assert_eq!(patchbay.summary().bound_sources, 1);
        assert_eq!(patchbay.summary().bound_sinks, 1);
        assert!(patchbay.summary().silent.is_empty());
    }

    #[test]
    fn a_matching_machine_binds_the_node() {
        let plan = r#"{
            "sources":[{"id":"in0","kind":"input","channel":0,"machine":"Table"}],
            "buses":[{"id":"house"}],
            "sinks":[{"id":"out","kind":"interface","machine":"table"}],
            "routes":[{"from":"in0","to":"house"},{"from":"house","to":"out"}]
        }"#;
        let patchbay = bay_for(plan, "table");
        assert_eq!(patchbay.summary().bound_sources, 1);
        assert_eq!(patchbay.summary().bound_sinks, 1);
    }

    #[test]
    fn a_non_matching_machine_is_silent_and_named() {
        let plan = r#"{
            "sources":[{"id":"mic","kind":"input","channel":0,"machine":"laptop"}],
            "buses":[{"id":"house"}],
            "sinks":[{"id":"amp","kind":"interface","machine":"den"}],
            "routes":[{"from":"mic","to":"house"},{"from":"house","to":"amp"}]
        }"#;
        let patchbay = bay_for(plan, "table");
        assert_eq!(patchbay.summary().bound_sources, 0);
        assert_eq!(patchbay.summary().bound_sinks, 0);
        assert!(patchbay.summary().silent.contains(&"mic".to_string()));
        assert!(patchbay.summary().silent.contains(&"amp".to_string()));
    }

    // --- live gain and pan ---------------------------------------------------

    #[test]
    fn a_live_gain_and_pan_change_take_effect_at_the_next_block() {
        let mut patchbay = prepared(TWO_INTO_ONE);
        let queue = patchbay.params();
        let input = [0.5f32, 0.25, 0.5, 0.25, 0.5, 0.25, 0.5, 0.25];
        let mut output = [0.0f32; 8];

        patchbay.block_f32(&input, &mut output).expect("first block");
        let full = 0.75f32 / std::f32::consts::SQRT_2;
        for frame in output.chunks(2) {
            assert!((frame[0] - full).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - full).abs() < 1e-5, "{frame:?}");
        }

        // Route 2 is house -> out: turn it down and hard left. It is a stereo
        // send, so pan -1 is left-only and the gain scales the whole bus.
        queue.push(2, ParamName::Gain, 0.5);
        queue.push(2, ParamName::Pan, -1.0);
        patchbay.block_f32(&input, &mut output).expect("second block");
        let expected = 0.5f32 * full;
        for frame in output.chunks(2) {
            assert!((frame[0] - expected).abs() < 1e-5, "{frame:?}");
            assert!(frame[1].abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_muted_route_has_no_live_strip() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"in0","to":"out","mute":1},
                    {"from":"in0","to":"out","gain":1,"pan":0}
                ]
            }"#,
        );
        assert!(!patchbay.route_live(0));
        assert!(patchbay.route_live(1));
    }

    // --- a source's own trim and inserts -------------------------------------

    /// A source's inserts run before its route, so the bus and the sink see the
    /// effected signal. The reference is the same strip a take would build.
    #[test]
    fn a_source_runs_its_inserts_before_its_route() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0,
                    "inserts":[{"name":"distortion"}]}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":1,"pan":-1}]
            }"#,
        );
        let input = [0.5f32, 0.0, 0.5, 0.0, 0.5, 0.0, 0.5, 0.0];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");

        let mut reference = Channel::new(1.0, -1.0);
        reference.push(InsertKind::Distortion.build());
        reference.prepare(48_000, 4);
        let mut expected = [0.0f32; 8];
        reference
            .process(&[0.5f32; 4], &mut expected)
            .expect("reference strip");

        for (got, want) in output.iter().zip(&expected) {
            assert!((got - want).abs() < 1e-5, "got {output:?}, want {expected:?}");
        }
        assert!(
            output[0].abs() > 1e-4,
            "the insert actually coloured the source: {output:?}"
        );
    }

    #[test]
    fn a_source_insert_can_be_bypassed_in_place() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0,
                    "inserts":[{"name":"distortion","bypass":true}]}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":1,"pan":-1}]
            }"#,
        );
        let input = [0.5f32, 0.0, 0.5, 0.0, 0.5, 0.0, 0.5, 0.0];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        for frame in output.chunks(2) {
            assert!((frame[0] - 0.5).abs() < 1e-6, "a bypassed insert was not a wire: {frame:?}");
            assert!(frame[1].abs() < 1e-6, "{frame:?}");
        }
    }

    #[test]
    fn a_source_gain_moves_live() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0,"gain":0.5}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":1,"pan":-1}]
            }"#,
        );
        let queue = patchbay.source_params();
        let input = [0.4f32, 0.0, 0.4, 0.0, 0.4, 0.0, 0.4, 0.0];
        let mut output = [0.0f32; 8];

        patchbay.block_f32(&input, &mut output).expect("first block");
        assert!((output[0] - 0.2).abs() < 1e-5, "the source trim ran first: {output:?}");

        queue.push(0, ParamName::Gain, 1.0);
        patchbay.block_f32(&input, &mut output).expect("second block");
        assert!((output[0] - 0.4).abs() < 1e-5, "the trim reached the audio thread: {output:?}");
    }

    #[test]
    fn a_source_insert_knob_moves_live() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0,
                    "inserts":["distortion"]}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":1,"pan":-1}]
            }"#,
        );
        let queue = patchbay.source_params();
        let input = [0.4f32, 0.0, 0.4, 0.0, 0.4, 0.0, 0.4, 0.0];
        let mut output = [0.0f32; 8];

        patchbay.block_f32(&input, &mut output).expect("first block");
        let before = output[0];
        queue.push(
            0,
            ParamName::parse("distortion.drive").expect("the insert's knob"),
            100.0,
        );
        patchbay.block_f32(&input, &mut output).expect("second block");
        assert!(
            (output[0] - before).abs() > 1e-3,
            "the insert knob reached the audio thread: before {before}, after {}",
            output[0]
        );
    }

    #[test]
    fn a_source_insert_starts_at_its_declared_controls() {
        // The plan's control map is native units. Distortion's drive is 0..100,
        // so 100 must sound like a strip built at 100, not at its default 50.
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0,
                    "inserts":[{"name":"distortion","controls":{"drive":100}}]}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":1,"pan":-1}]
            }"#,
        );
        let input = [0.5f32, 0.0, 0.5, 0.0, 0.5, 0.0, 0.5, 0.0];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");

        let mut reference = Channel::new(1.0, -1.0);
        reference.push(InsertKind::Distortion.build());
        reference.set("distortion.drive", 100.0);
        reference.prepare(48_000, 4);
        let mut expected = [0.0f32; 8];
        reference
            .process(&[0.5f32; 4], &mut expected)
            .expect("reference strip");

        for (got, want) in output.iter().zip(&expected) {
            assert!((got - want).abs() < 1e-5, "got {output:?}, want {expected:?}");
        }
    }

    #[test]
    fn an_unknown_source_control_is_refused() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0,
                    "inserts":[{"name":"distortion","controls":{"wobble":1}}]}],
                "buses":[],"sinks":[{"id":"out","kind":"interface"}],"routes":[]
            }"#,
        )
        .expect("the plan parses");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("the control is refused");
        assert!(
            error.contains("wobble") && error.contains("no such control"),
            "the refusal names the control: {error}"
        );
    }

    #[test]
    fn a_source_mute_stops_its_routes() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out","gain":1,"pan":-1}]
            }"#,
        );
        let queue = patchbay.source_params();
        let input = [0.4f32, 0.0, 0.4, 0.0, 0.4, 0.0, 0.4, 0.0];
        let mut output = [0.0f32; 8];

        patchbay.block_f32(&input, &mut output).expect("first block");
        assert!((output[0] - 0.4).abs() < 1e-5, "the source is audible: {output:?}");

        queue.push(0, ParamName::Mute, 1.0);
        patchbay.block_f32(&input, &mut output).expect("muted block");
        assert!(output[0].abs() < 1e-6, "the mute silenced the source: {output:?}");

        queue.push(0, ParamName::Mute, 0.0);
        patchbay.block_f32(&input, &mut output).expect("unmuted block");
        assert!((output[0] - 0.4).abs() < 1e-5, "unmute restored the trim: {output:?}");
    }

    #[test]
    fn a_source_gain_and_inserts_reach_the_bus_take() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0,"gain":0.5}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"in0","to":"house","gain":1,"pan":-1},
                    {"from":"house","to":"out","gain":1,"pan":0}
                ]
            }"#,
        );
        let tap = patchbay.tap();
        let (producer, consumer) = jawn_audio::monbus::new(4096);
        assert!(tap.attach(0, producer, None));
        let input = [0.5f32, 0.0, 0.5, 0.0, 0.5, 0.0, 0.5, 0.0];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");

        let mut recorded = [0.0f32; 8];
        assert_eq!(consumer.pop(&mut recorded), 4);
        for frame in recorded.chunks(2) {
            assert!((frame[0] - 0.25).abs() < 1e-5, "the tap saw the trimmed source: {frame:?}");
            assert!(frame[1].abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn two_device_sources_run_their_inserts_independently() {
        // Both sources read the same system mix. A shared block processed in
        // place would distort it twice for the second source; each source must
        // start from the untouched capture. One source and two sources must
        // therefore differ by exactly a factor of two, sample for sample.
        let mut single = bay(
            r#"{
                "sources":[{"id":"music","kind":"device","inserts":["distortion"]}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"music","to":"out","gain":1,"pan":-1}]
            }"#,
        );
        single.prepared(48_000, 4, 2).expect("prepare one");

        let mut double = bay(
            r#"{
                "sources":[
                    {"id":"music","kind":"device","inserts":["distortion"]},
                    {"id":"video","kind":"device","inserts":["distortion"]}
                ],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"music","to":"out","gain":1,"pan":-1},
                    {"from":"video","to":"out","gain":1,"pan":-1}
                ]
            }"#,
        );
        double.prepared(48_000, 4, 2).expect("prepare two");

        let input = [0.0f32; 8];
        let system = [0.4f32, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4];
        let mut one_out = [0.0f32; 8];
        let mut two_out = [0.0f32; 8];
        single
            .block_f32_with_system(&input, &system, &mut one_out)
            .expect("run one");
        double
            .block_f32_with_system(&input, &system, &mut two_out)
            .expect("run two");

        for (single_frame, double_frame) in one_out.chunks(2).zip(two_out.chunks(2)) {
            assert!(
                (double_frame[0] - single_frame[0] * 2.0).abs() < 1e-5,
                "a source processed another source's output: {single_frame:?} vs {double_frame:?}"
            );
            assert!(double_frame[1].abs() < 1e-5, "the pan kept the right silent");
        }
    }

    #[test]
    fn the_summary_reports_each_source_gain_and_insert_chain() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"in0","kind":"input","channel":0,
                    "gain":0.75,"inserts":["tone",{"name":"delay"}]}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"in0","to":"out"}]
            }"#,
        );
        let effects = &patchbay.summary().source_effects;
        assert_eq!(effects.len(), 1);
        assert_eq!(effects[0].id, "in0");
        assert_eq!(effects[0].gain, 0.75);
        assert!(!effects[0].mute, "a source from a plan is audible");
        assert_eq!(effects[0].inserts, vec!["tone", "delay"]);
        let line = patchbay.summary().json();
        assert!(
            line.contains("\"source_effects\":[{\"id\":\"in0\",\"gain\":0.75,\"mute\":false,\"inserts\":[\"tone\",\"delay\"]}]"),
            "{line}"
        );
    }

    #[test]
    fn a_source_insert_the_engine_cannot_build_is_refused() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"in0","kind":"input","inserts":["wobble"]}],
                "buses":[], "sinks":[], "routes":[]
            }"#,
        )
        .expect("parse");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
        assert!(error.contains("wobble"), "{error}");
    }

    #[test]
    fn a_source_gain_outside_the_trim_range_is_refused() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"in0","kind":"input","gain":5}],
                "buses":[], "sinks":[], "routes":[]
            }"#,
        )
        .expect("parse");
        let error = Patchbay::from_object(&object, 2, "local").expect_err("refused");
        assert!(error.contains("gain"), "{error}");
    }

    // --- the machine's own mix -------------------------------------------------

    #[test]
    fn the_system_mix_is_carried_when_the_plan_does_not_route_it() {
        // The plan draws a guitar into the interface and says nothing about the
        // machine's own audio. Music, video and a call must still be heard.
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"gtr","kind":"input","channel":0}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"gtr","to":"house"},
                    {"from":"house","to":"out"}
                ]
            }"#,
        );
        assert_eq!(patchbay.summary().system, "fallback");

        let input = [0.5f32; 8];
        let system = [0.25f32, -0.25, 0.25, -0.25, 0.25, -0.25, 0.25, -0.25];
        let mut output = [0.0f32; 8];
        patchbay
            .block_f32_with_system(&input, &system, &mut output)
            .expect("run");

        let guitar = 0.5f32 / std::f32::consts::SQRT_2;
        for frame in output.chunks(2) {
            assert!((frame[0] - (guitar + 0.25)).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - (guitar - 0.25)).abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_routed_device_source_replaces_the_fallback() {
        // The plan sends the machine's mix to the interface at half gain. The
        // fallback must not add a second, unison copy on top.
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"system","kind":"device"}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"system","to":"out","gain":0.5,"pan":0}]
            }"#,
        );
        assert_eq!(patchbay.summary().system, "routed");
        assert_eq!(patchbay.summary().bound_sources, 1);
        assert!(patchbay.summary().silent.is_empty());

        let input = [0.0f32; 8];
        let system = [0.4f32, -0.2, 0.4, -0.2, 0.4, -0.2, 0.4, -0.2];
        let mut output = [0.0f32; 8];
        patchbay
            .block_f32_with_system(&input, &system, &mut output)
            .expect("run");

        for frame in output.chunks(2) {
            assert!((frame[0] - 0.2).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] + 0.1).abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_muted_device_route_silences_the_mix_instead_of_falling_back() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"system","kind":"device"}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"system","to":"out","mute":1}]
            }"#,
        );
        assert_eq!(patchbay.summary().system, "routed");

        let input = [0.0f32; 8];
        let system = [0.5f32; 8];
        let mut output = [9.0f32; 8];
        patchbay
            .block_f32_with_system(&input, &system, &mut output)
            .expect("run");
        assert!(output.iter().all(|sample| *sample == 0.0), "{output:?}");
    }

    #[test]
    fn a_device_source_on_another_machine_does_not_silence_this_one() {
        let plan = r#"{
            "sources":[{"id":"laptop-system","kind":"device","machine":"laptop"}],
            "buses":[],
            "sinks":[{"id":"out","kind":"interface"}],
            "routes":[{"from":"laptop-system","to":"out"}]
        }"#;
        let mut patchbay = bay_for(plan, "table");
        assert_eq!(patchbay.summary().system, "fallback");
        assert!(patchbay.summary().silent.contains(&"laptop-system".to_string()));

        patchbay.prepared(48_000, 4, 2).expect("prepare");
        let input = [0.0f32; 8];
        let system = [0.125f32; 8];
        let mut output = [0.0f32; 8];
        patchbay
            .block_f32_with_system(&input, &system, &mut output)
            .expect("run");
        assert!(output.iter().all(|sample| (*sample - 0.125).abs() < 1e-6), "{output:?}");
    }

    #[test]
    fn the_i16_system_path_round_trips_the_mix() {
        let mut patchbay = prepared(
            r#"{
                "sources":[], "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[]
            }"#,
        );
        let input = [0i16; 8];
        let system = [16_384i16, -16_384, 16_384, -16_384, 16_384, -16_384, 16_384, -16_384];
        let mut output = [7i16; 8];
        patchbay
            .block_with_system(&input, &system, &mut output)
            .expect("run");
        for frame in output.chunks(2) {
            assert!((frame[0] - 16_384).abs() <= 1, "{frame:?}");
            assert!((frame[1] + 16_384).abs() <= 1, "{frame:?}");
        }
    }

    // --- whether the card's capture is needed ---------------------------------

    #[test]
    fn a_system_only_plan_wants_no_card_capture() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"system","kind":"device"}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"system","to":"out"}]
            }"#,
        );
        // The system mix is a `parec` capture of the virtual sink's monitor,
        // not the card: the microphone can stay with PipeWire.
        assert!(!patchbay.wants_input());
        assert_eq!(patchbay.summary().mode, "playback");
    }

    #[test]
    fn a_routed_local_input_wants_the_card_capture() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"gtr","kind":"input","channel":0}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"gtr","to":"out"}]
            }"#,
        );
        assert!(patchbay.wants_input());
        assert_eq!(patchbay.summary().mode, "duplex");
    }

    #[test]
    fn an_unrouted_local_input_wants_no_card_capture() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"gtr","kind":"input","channel":0}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[]
            }"#,
        );
        assert!(!patchbay.wants_input());
        assert_eq!(patchbay.summary().mode, "playback");
    }

    #[test]
    fn a_muted_local_input_route_wants_no_card_capture() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"gtr","kind":"input","channel":0}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"gtr","to":"out","mute":1}]
            }"#,
        );
        // A muted route is kept so the UI can unmute it, but it contributes
        // nothing: nothing reads the capture, so nothing needs the card.
        assert!(!patchbay.wants_input());
        assert_eq!(patchbay.summary().mode, "playback");
    }

    // --- which streams a backend opens ---------------------------------------

    #[test]
    fn a_pipewire_duplex_plan_plays_and_captures_each_routed_input_itself() {
        let patchbay = bay(
            r#"{
                "sources":[
                    {"id":"gtr","kind":"input","channel":0},
                    {"id":"keys","kind":"input","channel":1},
                    {"id":"room","kind":"input","channel":0}
                ],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"gtr","to":"out"},
                    {"from":"keys","to":"out"}
                ]
            }"#,
        );
        assert_eq!(patchbay.summary().mode, "duplex");

        let streams = patchbay.stream_plan(BackendKind::PipeWire);
        // The loop stays playback-only: the process plays the node the mix
        // replaced and cannot capture the card through the same pipewire-alsa
        // process. Each routed input is captured by a stream of its own.
        assert!(!streams.card_capture);
        assert_eq!(streams.inputs.len(), 2, "one per routed input: {:?}", streams.inputs);
        assert_eq!(streams.inputs[0].id, "gtr");
        assert_eq!(streams.inputs[0].channel, 0);
        assert_eq!(streams.inputs[1].id, "keys");
        assert_eq!(streams.inputs[1].channel, 1);
        assert!(
            !streams.inputs.iter().any(|input| input.id == "room"),
            "an unrouted input asks for no capture"
        );

        // ALSA is unchanged: one duplex open reads every channel.
        let streams = patchbay.stream_plan(BackendKind::Alsa);
        assert!(streams.card_capture);
        assert!(streams.inputs.is_empty(), "ALSA opens no second process");
    }

    #[test]
    fn a_plan_with_no_routed_input_asks_for_no_capture() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"system","kind":"device"}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"system","to":"out"}]
            }"#,
        );
        let streams = patchbay.stream_plan(BackendKind::PipeWire);
        assert!(!streams.card_capture);
        assert!(streams.inputs.is_empty(), "the microphone stays closed");
    }

    // --- naming the capture node ---------------------------------------------

    const NAMED_INPUT: &str = r#"{
        "sources":[{
            "id":"gtr","kind":"input","channel":0,
            "node":"alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo"
        }],
        "buses":[],
        "sinks":[{"id":"out","kind":"interface"}],
        "routes":[{"from":"gtr","to":"out"}]
    }"#;

    #[test]
    fn a_named_node_is_the_stream_the_input_captures() {
        let patchbay = bay_probing(NAMED_INPUT, &|_| Some(true));
        let streams = patchbay.stream_plan(BackendKind::PipeWire);
        assert_eq!(streams.inputs.len(), 1);
        assert_eq!(
            streams.inputs[0].node.as_deref(),
            Some("alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo")
        );
        // The status names the node the capture was given, so a take can say
        // which microphone it means.
        assert_eq!(
            patchbay.summary().inputs,
            vec![(
                "gtr".to_string(),
                "alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo".to_string()
            )]
        );
        // And the status line carries it, so the page reads the node the engine
        // bound rather than assuming one.
        let line = patchbay.summary().json();
        assert!(
            line.contains(
                "\"inputs\":[{\"id\":\"gtr\",\"node\":\"alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo\"}]"
            ),
            "{line}"
        );
    }

    #[test]
    fn an_input_without_a_node_reports_the_default_source_alias() {
        let patchbay = bay(ONE_INPUT);
        assert_eq!(
            patchbay.summary().inputs,
            vec![("in0".to_string(), DEFAULT_INPUT.to_string())]
        );
        assert_eq!(patchbay.stream_plan(BackendKind::PipeWire).inputs[0].node, None);
    }

    #[test]
    fn an_unknown_capture_node_is_silent_and_never_the_default() {
        // The machine does not offer the node the plan names. The input must
        // be named in `silent`, not quietly captured from the default source.
        let patchbay = bay_probing(NAMED_INPUT, &|_| Some(false));
        assert!(patchbay.summary().silent.contains(&"gtr".to_string()));
        assert_eq!(patchbay.summary().bound_sources, 0);
        assert!(
            patchbay.stream_plan(BackendKind::PipeWire).inputs.is_empty(),
            "no stream starts for a node this machine does not offer"
        );
        assert!(patchbay.summary().inputs.is_empty(), "and nothing is reported as bound");
    }

    #[test]
    fn a_node_the_machine_cannot_check_is_still_attempted() {
        // No pactl: the question cannot be asked, so the capture is attempted
        // with the named node rather than refused or replaced.
        let patchbay = bay_probing(NAMED_INPUT, &|_| None);
        assert!(patchbay.summary().silent.is_empty());
        assert_eq!(patchbay.stream_plan(BackendKind::PipeWire).inputs.len(), 1);
    }

    #[test]
    fn a_capture_node_that_is_not_a_name_is_refused() {
        let object = parse_object(
            r#"{
                "sources":[{"id":"gtr","kind":"input","node":"-device"}],
                "buses":[],
                "sinks":[],
                "routes":[]
            }"#,
        )
        .expect("the plan parses");
        assert!(
            Patchbay::from_object(&object, 2, "local").is_err(),
            "a name that `parec` would read as an option is refused"
        );
    }

    #[test]
    fn a_node_on_a_device_source_is_not_a_capture() {
        // `device` is the system mix and `handset` the call monitor; neither
        // captures from a node of its own, so a stray `node` is not one.
        let patchbay = bay_probing(
            r#"{
                "sources":[{"id":"system","kind":"device","node":"alsa_output.ghost.monitor"}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"system","to":"out"}]
            }"#,
            &|_| Some(false),
        );
        assert_eq!(patchbay.summary().system, "routed");
        assert!(patchbay.summary().silent.is_empty());
    }

    #[test]
    fn an_attached_input_feeds_its_plan_channel_and_can_be_silenced() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"gtr","kind":"input","channel":1}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"gtr","to":"out"}]
            }"#,
        );
        let (producer, consumer) = jawn_audio::monbus::MonitorBus::new(4096);
        producer.push(&[0.25f32, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25, 0.25]);
        patchbay.attach_input(0, consumer);

        let input = [0.0f32; 8];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        // The ring's samples land in plan channel 1 and are routed to the
        // stereo output, exactly as the ALSA duplex capture would be (a centred
        // mono source is equal-power, so 0.25 becomes 0.25/sqrt(2) per side).
        let expected = 0.25f32 / 2.0f32.sqrt();
        assert!(
            output.iter().all(|sample| (*sample - expected).abs() < 1e-6),
            "{output:?}"
        );

        // A capture that could not start silences only its own source.
        patchbay.silence_input(0);
        assert!(patchbay.summary().silent.contains(&"gtr".to_string()));
        let mut output = [7.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        assert!(output.iter().all(|sample| *sample == 0.0), "{output:?}");
    }

    // --- the reception handset -------------------------------------------------

    #[test]
    fn a_plan_without_a_handset_asks_for_no_second_capture() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"gtr","kind":"input","channel":0}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"gtr","to":"out"}]
            }"#,
        );
        assert!(!patchbay.wants_handset());
        assert_eq!(patchbay.summary().handset, "off");
    }

    #[test]
    fn a_handset_source_is_bound_and_mixed_like_a_stereo_source() {
        let mut patchbay = prepared(
            r#"{
                "sources":[{"id":"call","kind":"handset"}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"call","to":"house","gain":0.5,"pan":0},
                    {"from":"house","to":"out"}
                ]
            }"#,
        );
        assert!(patchbay.wants_handset());
        assert!(!patchbay.wants_input(), "a handset is a parec capture, not the card");
        assert_eq!(patchbay.summary().mode, "playback");
        assert_eq!(patchbay.summary().bound_sources, 1);
        assert!(patchbay.summary().silent.is_empty());
        assert_eq!(patchbay.summary().handset, "pending");

        let (producer, consumer) = jawn_audio::monbus::MonitorBus::new(4096);
        producer.push(&[0.5f32, -0.25, 0.5, -0.25, 0.5, -0.25, 0.5, -0.25]);
        patchbay.set_handset(consumer);
        assert_eq!(patchbay.summary().handset, "capturing");

        let input = [0.0f32; 8];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        for frame in output.chunks(2) {
            assert!((frame[0] - 0.25).abs() < 1e-6, "{frame:?}");
            assert!((frame[1] + 0.125).abs() < 1e-6, "{frame:?}");
        }
    }

    #[test]
    fn a_handset_source_on_another_machine_is_silent() {
        let patchbay = bay_for(
            r#"{
                "sources":[{"id":"call","kind":"handset","machine":"table"}],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"call","to":"out"}]
            }"#,
            "laptop",
        );
        assert!(!patchbay.wants_handset());
        assert_eq!(patchbay.summary().bound_sources, 0);
        assert!(patchbay.summary().silent.contains(&"call".to_string()));
        assert_eq!(patchbay.summary().handset, "off");
    }

    #[test]
    fn an_absent_call_sink_is_silent_and_the_rest_of_the_patch_still_runs() {
        let mut patchbay = prepared(
            r#"{
                "sources":[
                    {"id":"call","kind":"handset"},
                    {"id":"gtr","kind":"input","channel":0}
                ],
                "buses":[],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[
                    {"from":"call","to":"out"},
                    {"from":"gtr","to":"out"}
                ]
            }"#,
        );
        assert!(patchbay.wants_handset());
        // The sink is not there: the caller reports it silent rather than
        // failing the patch.
        patchbay.silence_handset();
        assert_eq!(patchbay.summary().handset, "unavailable");
        assert!(patchbay.summary().silent.contains(&"call".to_string()));
        assert_eq!(patchbay.summary().bound_sources, 1, "the guitar still binds");

        let input = [0.5f32, 0.0, 0.5, 0.0, 0.5, 0.0, 0.5, 0.0];
        let mut output = [0.0f32; 8];
        patchbay.block_f32(&input, &mut output).expect("run");
        let expected = 0.5f32 / std::f32::consts::SQRT_2;
        for frame in output.chunks(2) {
            assert!((frame[0] - expected).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - expected).abs() < 1e-5, "{frame:?}");
        }
    }
}
