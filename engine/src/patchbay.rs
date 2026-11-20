//! The house patchbay: sources, buses and sinks from the saved plan
//! (`docs/studio-audio-roadmap.md` §8).
//!
//! A plan is data the manager owns; this module is the one place it becomes a
//! graph. Sources are the capture channels, buses are stereo sums, sinks are
//! the playback channels, and a route is an edge with a gain and a pan. The
//! graph is compiled once, before the device loop starts, and every buffer it
//! needs is allocated then: the audio callback only reads and writes memory it
//! already owns.
//!
//! Three rules keep the compile honest:
//!
//! * **A node the machine cannot bind is silent, not fatal.** A plan may name a
//!   phone, a peer machine or a zone. On this machine an `input` source is a
//!   capture channel, a `device` source is the machine's own system mix (Music,
//!   video, notifications, calls), a `handset` source is the reception mixer's
//!   screened-call monitor (`jawn_call_in.monitor`), and an
//!   `interface`/`speakers` sink is the local output; the rest are reported in
//!   [`PatchSummary::silent`] and their routes contribute nothing. A plan is one
//!   document for the whole house; applying it on one machine must not fail
//!   because the rest of the house is elsewhere.
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

use std::sync::Arc;

use jawn_audio::graph::{mix_mono_into_stereo, Strip};
use jawn_audio::listen::ListenSink;
use jawn_audio::mixer::{ParamName, ParamQueue};
use jawn_audio::monbus::Consumer;
use jawn_audio::{to_i16, Device, NullDevice};

use crate::backends::BackendKind;
use crate::socket::{get, Object, Value};

/// The source kinds a saved plan may name. `input` is a capture channel,
/// `device` is this machine's system mix, and `handset` is the reception
/// mixer's screened call; `player` and `peer` are declared but silent here.
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
/// (`jawn_call_in.monitor`) from a capture of its own. `input` is the source's
/// own `parec` ring on a PipeWire machine, where the card is never opened for
/// capture: its samples land in the plan's `channel` each block.
#[derive(Debug)]
struct Source {
    id: String,
    channel: Option<usize>,
    system: bool,
    handset: bool,
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
    /// the microphone to PipeWire. The system mix and the handset are external
    /// `parec` captures and do not make a plan `duplex`.
    pub mode: &'static str,
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
        format!(
            "\"sources\":{},\"buses\":{},\"sinks\":{},\"routes\":{},\"bound_sources\":{},\"bound_sinks\":{},\"silent\":[{}],\"system_route\":\"{}\",\"handset\":\"{}\",\"mode\":\"{}\"",
            self.sources,
            self.buses,
            self.sinks,
            self.routes,
            self.bound_sources,
            self.bound_sinks,
            silent,
            self.system,
            self.handset,
            self.mode
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
    summary: PatchSummary,
    /// Whether a bound `device` source is routed by the plan. When it is not,
    /// the system mix is added to the output at unity instead of disappearing.
    system_routed: bool,
    /// Interleaved f32 capture, one block.
    input: Vec<f32>,
    /// One stereo block popped from an input's own `parec` ring, then written
    /// into that source's plan channel before the graph renders.
    capture_block: Vec<f32>,
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
    /// One stereo block per bus.
    buses: Vec<Vec<f32>>,
    /// One stereo block per sink.
    sink_buffers: Vec<Vec<f32>>,
    /// The summed stereo block written to the device.
    mix: Vec<f32>,
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
            // places it elsewhere.
            let system = kind == "device" && on_this_machine;
            let handset = kind == "handset" && on_this_machine;
            let reachable =
                kind == "input" && on_this_machine && channel < config_channels;
            if !reachable && !system && !handset {
                // A plan saved for a wider interface (or a peer/phone, or a
                // route delegated elsewhere) is a declared node this machine
                // cannot reach, not a broken plan.
                silent.push(id.clone());
            }
            sources.push(Source {
                id,
                channel: reachable.then_some(channel),
                system,
                handset,
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
                    if sources[source].channel.is_some()
                        || sources[source].system
                        || sources[source].handset
                    {
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
                    if (sources[source].channel.is_some()
                        || sources[source].system
                        || sources[source].handset)
                        && sinks[sink].bound
                    {
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
        let summary = PatchSummary {
            sources: sources.len(),
            buses: buses.len(),
            sinks: sinks.len(),
            routes: route_count,
            bound_sources: sources
                .iter()
                .filter(|source| {
                    source.channel.is_some() || source.system || source.handset
                })
                .count(),
            bound_sinks: sinks.iter().filter(|sink| sink.bound).count(),
            silent,
            system: if system_routed { "routed" } else { "fallback" },
            handset: if sources.iter().any(|source| source.handset) {
                "pending"
            } else {
                "off"
            },
            mode,
        };

        let bus_count = buses.len();
        let sink_count = sinks.len();
        Ok(Patchbay {
            channels: config_channels,
            period: 0,
            sources,
            bus_routes,
            sink_bus_routes,
            order,
            strips,
            params: Arc::new(ParamQueue::new()),
            summary,
            system_routed,
            input: Vec::new(),
            capture_block: Vec::new(),
            system: Vec::new(),
            handset: None,
            handset_block: Vec::new(),
            mono: Vec::new(),
            buses: (0..bus_count).map(|_| Vec::new()).collect(),
            sink_buffers: (0..sink_count).map(|_| Vec::new()).collect(),
            mix: Vec::new(),
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

    /// Whether the compiled plan needs the card's capture.
    ///
    /// True only when at least one local `input` source is bound to a real
    /// channel *and* has an executable route. A source declared for another
    /// machine, a `device` source (the system mix), a `handset` source (the
    /// reception mixer's call monitor), an unrouted input and a muted route are
    /// all external or silent and need no card capture. A plan without one runs
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
                    let channel = source.channel?;
                    if source.routes.is_empty() {
                        return None;
                    }
                    Some(InputStream {
                        index,
                        id: source.id.clone(),
                        channel,
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

    /// Attach a routed input's own capture. Its samples are written into the
    /// source's plan channel at the top of each block, exactly where the ALSA
    /// duplex loop's card capture would have put them.
    #[cfg_attr(not(feature = "alsa"), allow(dead_code))]
    pub fn attach_input(&mut self, index: usize, consumer: Consumer) {
        if let Some(source) = self.sources.get_mut(index) {
            source.input = Some(consumer);
        }
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
            .filter(|source| source.channel.is_some() || source.system || source.handset)
            .count();
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
            .filter(|source| source.channel.is_some() || source.system)
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
    }

    /// Size every buffer. This is the only allocation in the patchbay; the
    /// device loop then only reads and writes what this owns.
    pub fn prepared(&mut self, _rate: u32, period: usize, channels: usize) -> Result<(), String> {
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
        self.input = vec![0.0; period.saturating_mul(channels)];
        self.capture_block = vec![0.0; period.saturating_mul(2)];
        self.system = vec![0.0; period.saturating_mul(2)];
        // Allocated whether or not a ring is attached yet: the socket can attach
        // the call capture after the graph is prepared, and the callback must
        // never grow a buffer.
        if self.handset.is_some() {
            self.handset_block = vec![0.0; period.saturating_mul(2)];
        }
        self.mono = vec![0.0; period];
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
        for source in &self.sources {
            let (Some(consumer), Some(channel)) = (source.input.as_ref(), source.channel) else {
                continue;
            };
            consumer.pop(&mut self.capture_block[..stereo]);
            for frame in 0..frames {
                self.input[frame * self.channels + channel] = self.capture_block[frame * 2];
            }
        }

        // The handset ring is read once per block, before the sources, the same
        // way the take's live monitor pops its ring. A short ring is silence.
        if let Some(consumer) = &self.handset {
            consumer.pop(&mut self.handset_block[..stereo]);
        }

        // Sources first: each one is read once, then summed into every place
        // it was routed to. An `input` source is one capture channel; a
        // `device` source is the machine's stereo system mix.
        for source in &self.sources {
            if source.routes.is_empty() {
                continue;
            }
            if let Some(channel) = source.channel {
                for frame in 0..frames {
                    self.mono[frame] = self.input[frame * self.channels + channel];
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
                for route in &source.routes {
                    match route {
                        SourceRoute::Bus { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.buses[*index][..stereo],
                                &self.system[..stereo],
                                strip,
                            );
                        }
                        SourceRoute::Sink { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.sink_buffers[*index][..stereo],
                                &self.system[..stereo],
                                strip,
                            );
                        }
                    }
                }
            } else if source.handset {
                for route in &source.routes {
                    match route {
                        SourceRoute::Bus { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.buses[*index][..stereo],
                                &self.handset_block[..stereo],
                                strip,
                            );
                        }
                        SourceRoute::Sink { index, strip } => {
                            let Some(strip) = &self.strips[*strip] else {
                                continue;
                            };
                            mix_stereo_into_stereo(
                                &mut self.sink_buffers[*index][..stereo],
                                &self.handset_block[..stereo],
                                strip,
                            );
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

/// Whether any local `input` source is both bound and routed. The one fact
/// behind [`Patchbay::wants_input`] and the summary's `mode`.
fn sources_want_input(sources: &[Source]) -> bool {
    sources
        .iter()
        .any(|source| source.channel.is_some() && !source.routes.is_empty())
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

/// A node's optional `"machine"` host. Absent or empty means "this machine",
/// which [`text`] already folds into `None`; a non-empty value is compared
/// case-insensitively against the engine's machine by the caller.
fn node_machine(object: &Object) -> Option<String> {
    text(object, "machine")
}

fn node_ref(object: &Object, key: &str) -> Result<String, String> {
    text(object, key).ok_or_else(|| format!("every route needs a \"{key}\" node id"))
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
    fn a_peer_source_is_silent_and_named() {
        let patchbay = bay(
            r#"{
                "sources":[{"id":"phone","kind":"peer"}],
                "buses":[{"id":"house"}],
                "sinks":[{"id":"out","kind":"interface"}],
                "routes":[{"from":"phone","to":"house"},{"from":"house","to":"out"}]
            }"#,
        );
        let summary = patchbay.summary();
        assert_eq!(summary.bound_sources, 0);
        assert_eq!(summary.silent, vec!["phone".to_string()]);
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
