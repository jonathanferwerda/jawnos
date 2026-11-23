//! A mixer of independent channel strips, one per device input.
//!
//! Studio's interface is two inputs and two channels, not a stereo pair: a mic
//! on input 0 and an instrument on input 1 are different sources, so summing
//! them would put a vocal inside a guitar. Each [`Track`] therefore records
//! **one** input through its own [`Channel`] (trim, inserts, pan) and each track
//! has its own disk writer; [`Mixer::mix`] is the monitoring path that sums the
//! prepared tracks into one stereo bus.
//!
//! Nothing here allocates after [`Mixer::prepare`]: a take is many blocks over a
//! fixed period, and an allocation in the block loop is a dropout, not a
//! warning.
//!
//! The summed bus is the master. [`Mixer::push_master`] adds a fixed insert
//! chain that [`Mixer::mix`] runs over that sum, after every channel strip and
//! in order; it is the only place the whole mix exists at once.

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

use crate::effect::{Channel, Effect, InsertKind};

/// How many control changes may wait between the control thread and the next
/// block the audio thread runs. Each is one knob, so this is a second or two of
/// even a very fast hand on a fader.
pub const PARAM_QUEUE_LEN: usize = 64;

/// A parameter the control path can name, in the engine's own vocabulary.
///
/// An address is one 16-bit word: a master-rack bit, a 7-bit
/// [`InsertKind`] code, and the index of a control in
/// [`InsertKind::controls`]. The strip's own `gain` and `pan` use kind 0, so
/// every knob the socket can speak fits without a variant per effect. The
/// control list is the only table: [`parse`](ParamName::parse) and the socket
/// read it, and a new knob is one row rather than another enum arm.
///
/// `Copy`, `Eq` and 16 bits wide, so [`ParamQueue`] can pack it into the same
/// `u64` slot as the track and value and the audio thread never sees a string.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ParamName(u16);

const MASTER_BIT: u16 = 0x8000;
const KIND_SHIFT: u16 = 8;
const CONTROL_MASK: u16 = 0xFF;
/// Kind 0 is the channel strip itself, not an insert.
const STRIP_KIND: u8 = 0;
/// `master_<name>.bypass` is the master rack's footswitch, not an effect knob:
/// it is a pseudo-control that only a master address may name.
const BYPASS_CONTROL: u8 = 0xFF;

impl ParamName {
    /// The historical names, kept so existing callers and tests name the same
    /// knobs. They are the same `u16` the parser builds.
    #[allow(non_upper_case_globals)]
    pub const Gain: Self = Self::strip(0);
    #[allow(non_upper_case_globals)]
    pub const Pan: Self = Self::strip(1);
    /// The patchbay's source footswitch. A mixer strip has no mute here (its
    /// mute is the route or the take), so only a patch source reads this name.
    #[allow(non_upper_case_globals)]
    pub const Mute: Self = Self::strip(2);
    #[allow(non_upper_case_globals)]
    pub const ToneBass: Self = Self::from_insert(InsertKind::Tone, 0);
    #[allow(non_upper_case_globals)]
    pub const ToneMid: Self = Self::from_insert(InsertKind::Tone, 1);
    #[allow(non_upper_case_globals)]
    pub const ToneTreble: Self = Self::from_insert(InsertKind::Tone, 2);
    #[allow(non_upper_case_globals)]
    pub const DistortionDrive: Self = Self::from_insert(InsertKind::Distortion, 0);
    #[allow(non_upper_case_globals)]
    pub const DelayTime: Self = Self::from_insert(InsertKind::Delay, 0);
    #[allow(non_upper_case_globals)]
    pub const DelayFeedback: Self = Self::from_insert(InsertKind::Delay, 1);
    #[allow(non_upper_case_globals)]
    pub const DelayMix: Self = Self::from_insert(InsertKind::Delay, 2);
    #[allow(non_upper_case_globals)]
    pub const CompressorThreshold: Self = Self::from_insert(InsertKind::Compressor, 0);
    #[allow(non_upper_case_globals)]
    pub const CompressorAttack: Self = Self::from_insert(InsertKind::Compressor, 1);
    #[allow(non_upper_case_globals)]
    pub const CompressorMix: Self = Self::from_insert(InsertKind::Compressor, 5);
    #[allow(non_upper_case_globals)]
    pub const ReverbMix: Self = Self::from_insert(InsertKind::Reverb, 0);
    #[allow(non_upper_case_globals)]
    pub const ReverbVolume: Self = Self::from_insert(InsertKind::Reverb, 1);

    const fn strip(control: u8) -> Self {
        Self(((STRIP_KIND as u16) << KIND_SHIFT) | control as u16)
    }

    const fn from_insert(kind: InsertKind, control: u8) -> Self {
        Self(((kind.code() as u16) << KIND_SHIFT) | control as u16)
    }

    /// The socket's name, e.g. `reverb.mix`, `amp.cabinet` or
    /// `master_comp.thresh`. The control must be in
    /// [`InsertKind::controls`] (the historical `compressor.threshold` and
    /// `delay.mix` spellings are aliases); anything else is `None`, which is
    /// how an unknown control is refused rather than silently ignored.
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "gain" => return Some(Self::Gain),
            "pan" => return Some(Self::Pan),
            "mute" => return Some(Self::Mute),
            _ => {}
        }
        let (prefix, control) = name.split_once('.')?;
        let kind = InsertKind::parse(prefix)?;
        let master = prefix.starts_with("master_");
        if master && control == "bypass" {
            return Some(Self::new(true, kind, BYPASS_CONTROL));
        }
        let control = kind.control_index(control)?;
        Some(Self::new(master, kind, control))
    }

    const fn new(master: bool, kind: InsertKind, control: u8) -> Self {
        let master = if master { MASTER_BIT } else { 0 };
        Self(master | ((kind.code() as u16) << KIND_SHIFT) | control as u16)
    }

    fn from_bits(bits: u16) -> Option<Self> {
        let master = bits & MASTER_BIT != 0;
        let kind_code = ((bits >> KIND_SHIFT) & 0x7F) as u8;
        let control = (bits & CONTROL_MASK) as usize;
        if kind_code == STRIP_KIND {
            return if !master && control < 3 {
                Some(Self(bits))
            } else {
                None
            };
        }
        let kind = InsertKind::from_code(kind_code)?;
        if master && control == usize::from(BYPASS_CONTROL) {
            return Some(Self(bits));
        }
        if control >= kind.controls().len() {
            return None;
        }
        Some(Self(bits))
    }

    /// The raw word the queue stores.
    pub fn bits(self) -> u16 {
        self.0
    }

    /// True for the master rack's fixed chain, false for a track strip.
    pub fn master(self) -> bool {
        self.0 & MASTER_BIT != 0
    }

    /// True for the master rack's footswitch pseudo-control.
    pub fn bypass(self) -> bool {
        self.master() && (self.0 & CONTROL_MASK) == u16::from(BYPASS_CONTROL)
    }

    /// The same address on the other bus.
    pub fn with_master(self, master: bool) -> Self {
        if master {
            Self(self.0 | MASTER_BIT)
        } else {
            Self(self.0 & !MASTER_BIT)
        }
    }

    /// The insert behind the address. `None` is the strip's own gain/pan.
    pub fn insert_kind(self) -> Option<InsertKind> {
        let code = ((self.0 >> KIND_SHIFT) & 0x7F) as u8;
        if code == STRIP_KIND {
            return None;
        }
        InsertKind::from_code(code)
    }

    /// The prefix a chain or the master rack resolves: `flanger`, `amp`, or
    /// `master_comp` for a master address. `None` is the strip itself.
    pub fn insert(self) -> Option<&'static str> {
        let kind = self.insert_kind()?;
        Some(if self.master() {
            kind.master_prefix().unwrap_or_else(|| kind.name())
        } else {
            kind.name()
        })
    }

    /// The control's name as the effect's `set` expects it (`drive`), or
    /// `gain`/`pan` for the strip.
    pub fn control(self) -> &'static str {
        if self.bypass() {
            return "bypass";
        }
        match self.insert_kind() {
            Some(kind) => kind.controls()
                .get((self.0 & CONTROL_MASK) as usize)
                .copied()
                .unwrap_or(""),
            None => {
                if self.0 & CONTROL_MASK == 0 {
                    "gain"
                } else if self.0 & CONTROL_MASK == 1 {
                    "pan"
                } else {
                    "mute"
                }
            }
        }
    }

    /// True when the master rack can build this effect. A `master_*` name that
    /// maps to an effect the rack does not hold is refused.
    pub fn master_capable(self) -> bool {
        self.insert_kind()
            .map(|kind| kind.master_prefix().is_some())
            .unwrap_or(false)
    }

    /// The wire value in the effect's internal units. The contract sends
    /// milliseconds for the compressor and limiter time controls; the effects
    /// hold seconds.
    pub fn native_value(self, value: f32) -> f32 {
        self.insert_kind()
            .map(|kind| kind.native_value(self.control(), value))
            .unwrap_or(value)
    }

    /// Apply this address to one channel strip. The mixer's take strips and the
    /// listen strip share this, so both send an insert knob the same way and a
    /// master address (which is not a track) is refused.
    pub fn apply_to(self, channel: &mut Channel, value: f32) -> bool {
        if self.master() {
            return false;
        }
        match self.insert_kind() {
            Some(kind) => channel.set_insert(kind.name(), self.control(), self.native_value(value)),
            None => channel.set(self.control(), self.native_value(value)),
        }
    }
}

/// One control change, packed into all 64 bits of one atomic slot: 16 bits of
/// name, 16 of track, 32 of the value's IEEE bits. The master address lives in
/// the name's top bit, so the same ring carries a master knob and a track knob
/// without a second queue or a lock.
fn pack(track: usize, name: ParamName, value: f32) -> u64 {
    u64::from(name.bits())
        | ((track as u64 & 0xFFFF) << 16)
        | (u64::from(value.to_bits()) << 32)
}

fn unpack(packed: u64) -> Option<(usize, ParamName, f32)> {
    let name = ParamName::from_bits((packed & 0xFFFF) as u16)?;
    let track = ((packed >> 16) & 0xFFFF) as usize;
    let value = f32::from_bits((packed >> 32) as u32);
    Some((track, name, value))
}

/// A fixed-size single-producer/single-consumer ring of control changes.
///
/// The control thread pushes; the audio thread pops at the top of a block.
/// Atomics only: the audio thread never waits for the writer, allocates, or
/// panics when the ring is full — [`push`](ParamQueue::push) tells the control
/// thread instead, so a knob turned faster than the block rate is bounded by
/// the block rate rather than by a lock.
#[derive(Debug)]
pub struct ParamQueue {
    slots: [AtomicU64; PARAM_QUEUE_LEN],
    /// The consumer's read position.
    head: AtomicUsize,
    /// The producer's write position; `tail - head` is what is waiting.
    tail: AtomicUsize,
}

impl ParamQueue {
    pub fn new() -> Self {
        ParamQueue {
            slots: std::array::from_fn(|_| AtomicU64::new(0)),
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
        }
    }

    /// Queue one change. False means the audio thread has not drained the ring
    /// yet; the caller should say so rather than block.
    pub fn push(&self, track: usize, name: ParamName, value: f32) -> bool {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Acquire);
        if tail.wrapping_sub(head) >= PARAM_QUEUE_LEN {
            return false;
        }
        self.slots[tail % PARAM_QUEUE_LEN].store(pack(track, name, value), Ordering::Relaxed);
        self.tail.store(tail.wrapping_add(1), Ordering::Release);
        true
    }

    /// Queue one master-rack change. The master flag rides in the name, so this
    /// is the same lock-free ring a track knob uses; the audio thread tells the
    /// two apart at the top of a block.
    pub fn push_master(&self, name: ParamName, value: f32) -> bool {
        self.push(0, name.with_master(true), value)
    }

    /// Pop one change. The audio thread calls this at the top of a block; the
    /// patchbay (a consumer in the binary crate) drains its own shared queue
    /// through this, exactly as [`Mixer::apply_pending`] does inside this crate.
    pub fn pop(&self) -> Option<(usize, ParamName, f32)> {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);
        if head == tail {
            return None;
        }
        let packed = self.slots[head % PARAM_QUEUE_LEN].load(Ordering::Relaxed);
        self.head.store(head.wrapping_add(1), Ordering::Release);
        unpack(packed)
    }
}

impl Default for ParamQueue {
    fn default() -> Self {
        Self::new()
    }
}

/// The effect behind a master-rack prefix. The song document and the socket
/// speak `master_comp`; the effect itself still calls itself a compressor,
/// because it is the same code a track uses. A prefix the rack does not know is
/// passed through, so a caller can also say `compressor.threshold`.
pub fn master_effect_name(prefix: &str) -> &str {
    match prefix {
        "master_comp" => "compressor",
        "master_eq" => "equalizer",
        "master_reverb" => "reverb",
        "master_maximizer" => "maximizer",
        "master_limiter" => "limiter",
        other => other,
    }
}

/// The contract's mastering order. The page and the engine both build the
/// rack in this order, whatever order the names arrived in; it is the house's
/// chain, not a per-song list (`docs/studio-effects.md`, "Master rack").
pub const MASTER_ORDER: [InsertKind; 5] = [
    InsertKind::Compressor,
    InsertKind::Equalizer,
    InsertKind::Reverb,
    InsertKind::Maximizer,
    InsertKind::Limiter,
];

/// One insert in the master rack.
///
/// [`Effect`] is a mono processor, so a stereo bus needs two instances rather
/// than one instance called twice: a reverb's convolution state is the tail,
/// and sharing it between left and right would fold the stereo image into a
/// mono one. The two instances are built from the same [`InsertKind`], so they
/// always agree on their knobs.
struct MasterSlot {
    left: Box<dyn Effect>,
    right: Box<dyn Effect>,
    bypassed: bool,
}

impl MasterSlot {
    fn new(kind: InsertKind) -> Self {
        MasterSlot {
            left: kind.build(),
            right: kind.build(),
            bypassed: false,
        }
    }

    fn name(&self) -> &'static str {
        self.left.name()
    }

    fn prepare(&mut self, rate: u32, frames: usize) {
        self.left.prepare(rate, frames);
        self.right.prepare(rate, frames);
    }

    fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        if self.bypassed {
            return;
        }
        self.left.process(left);
        self.right.process(right);
    }

    fn set(&mut self, knob: &str, value: f32) -> bool {
        let left = self.left.set(knob, value);
        let right = self.right.set(knob, value);
        left || right
    }

    /// The master rack's footswitch: the insert stays where it is and keeps its
    /// knobs, exactly as a pedal's bypass does on a track.
    fn set_bypass(&mut self, bypassed: bool) -> bool {
        self.bypassed = bypassed;
        true
    }

    fn reset(&mut self) {
        self.left.reset();
        self.right.reset();
    }
}

/// One input and the strip that records it.
pub struct Track {
    /// The device input index this track records, 0-based.
    pub input: usize,
    /// How many device channels this track claims: `1` mono, `2` stereo. A
    /// stereo pair is averaged at `0.5` each *before* the mono strip.
    pub channels: usize,
    /// The name a take report and a file name use, e.g. `ch1`.
    pub label: String,
    /// Trim -> inserts in order -> equal-power pan.
    pub channel: Channel,
}

/// A set of tracks that can run one block at a time.
///
/// `new` builds one track per label; a label with no matching entry in `inputs`
/// falls back to its own index. Tracks are positional: track 0 is the first
/// label and the first entry in `inputs`.
pub struct Mixer {
    tracks: Vec<Track>,
    /// One stereo block shared by [`Mixer::mix`], sized by `prepare`.
    scratch: Vec<f32>,
    /// The master rack, applied to the summed stereo bus after every channel.
    master: Vec<MasterSlot>,
    /// The deinterleaved bus the master slots run over, sized by `prepare`.
    master_scratch: Vec<f32>,
    /// Control changes from the socket, drained at the top of a block.
    params: Arc<ParamQueue>,
}

impl Mixer {
    /// One track per label; `inputs` is the device input index (0-based) for
    /// each positional track.
    pub fn new(inputs: &[usize], labels: &[&str]) -> Self {
        Self::with_queue(inputs, labels, Arc::new(ParamQueue::new()))
    }

    /// The same, with a queue the control thread already holds. The take thread
    /// builds the strips (a `Box<dyn Effect>` need not be `Send`), but the
    /// socket has to be able to push to them before that thread exists.
    pub fn with_queue(inputs: &[usize], labels: &[&str], params: Arc<ParamQueue>) -> Self {
        let tracks = labels
            .iter()
            .enumerate()
            .map(|(index, label)| Track {
                input: inputs.get(index).copied().unwrap_or(index),
                channels: 1,
                label: (*label).to_string(),
                channel: Channel::new(1.0, 0.0),
            })
            .collect();
        Mixer {
            tracks,
            scratch: Vec::new(),
            master: Vec::new(),
            master_scratch: Vec::new(),
            params,
        }
    }

    /// Add one insert to the end of the master chain. Call it before
    /// [`prepare`](Mixer::prepare): the rack is a fixed set for the life of the
    /// stream, which is what the UI's master rack shows.
    pub fn push_master(&mut self, kind: InsertKind) {
        self.master.push(MasterSlot::new(kind));
    }

    /// Replace the master chain in place, building and sizing the new inserts
    /// for `period`. The caller is on the thread that runs the strips (an
    /// insert need not be `Send`), so this is a plan-update or setup call, never
    /// a steady-state one. The track strips are left alone, so a master edit
    /// does not reset a take's tails.
    pub fn set_master_chain(&mut self, kinds: &[InsertKind], rate: u32, period: usize) {
        self.master.clear();
        for kind in kinds {
            self.master.push(MasterSlot::new(*kind));
        }
        for slot in &mut self.master {
            slot.prepare(rate, period);
        }
    }

    /// The master chain's implementation names, for a report: `limiter,eq`.
    /// Bypassed inserts are still in the rack, so they are still named.
    pub fn master_insert_names(&self) -> String {
        let mut names: Vec<&str> = Vec::with_capacity(self.master.len());
        for slot in &self.master {
            names.push(slot.name());
        }
        names.join(",")
    }

    /// Move one master knob by name: `master_comp.threshold`,
    /// `master_eq.low`, `master_reverb.model`, `master_maximizer.loudness`,
    /// `master_limiter.ceiling`. The prefix is resolved by
    /// [`master_effect_name`], so the canonical `compressor.threshold` also
    /// works. Returns false when the named insert is not in the rack.
    ///
    /// Like [`Channel::set`], this only writes a smoothed target and is meant
    /// for the setup thread or the audio thread between blocks; a control
    /// thread with its own queue uses [`ParamQueue`] for the channel strips.
    pub fn set_master(&mut self, name: &str, value: f32) -> bool {
        let (prefix, knob) = match name.split_once('.') {
            Some(pair) => pair,
            None => return false,
        };
        let effect = master_effect_name(prefix);
        let value = match InsertKind::parse(prefix) {
            Some(kind) => kind.native_value(knob, value),
            None => value,
        };
        for slot in &mut self.master {
            if slot.name() == effect {
                return slot.set(knob, value);
            }
        }
        false
    }

    /// Bypass or restore a master insert in place. The insert keeps its knobs
    /// and its position; a bypassed slot is simply not run, which is exactly
    /// what a pedal's footswitch does.
    pub fn bypass_master(&mut self, prefix: &str, bypassed: bool) -> bool {
        let effect = master_effect_name(prefix);
        for slot in &mut self.master {
            if slot.name() == effect {
                slot.bypassed = bypassed;
                return true;
            }
        }
        false
    }

    /// The queue the control thread pushes to.
    pub fn params(&self) -> Arc<ParamQueue> {
        Arc::clone(&self.params)
    }

    /// Apply every waiting control change. Called at the top of a block, so a
    /// param that arrived between blocks is heard at this block's edge.
    pub fn apply_pending(&mut self) {
        while let Some((index, name, value)) = self.params.pop() {
            if name.master() {
                self.apply_master(name, value);
                continue;
            }
            if let Some(track) = self.tracks.get_mut(index) {
                name.apply_to(&mut track.channel, value);
            }
        }
    }

    /// One master-rack knob, applied between blocks. Returns false when the
    /// rack does not hold that effect; the control path has already refused an
    /// unknown control, so a false here is a rack that is not armed.
    fn apply_master(&mut self, name: ParamName, value: f32) -> bool {
        let prefix = match name.insert() {
            Some(prefix) => prefix,
            None => return false,
        };
        let effect = master_effect_name(prefix);
        for slot in &mut self.master {
            if slot.name() == effect {
                if name.bypass() {
                    return slot.set_bypass(value >= 0.5);
                }
                return slot.set(name.control(), name.native_value(value));
            }
        }
        false
    }

    /// Size every strip, and the shared mix block, for `period` frames. This is
    /// the only allocation in the mixer.
    pub fn prepare(&mut self, rate: u32, period: usize) {
        for track in &mut self.tracks {
            track.channel.prepare(rate, period);
        }
        for slot in &mut self.master {
            slot.prepare(rate, period);
        }
        self.scratch = vec![0.0; period.saturating_mul(2)];
        self.master_scratch = vec![0.0; period.saturating_mul(2)];
    }

    pub fn tracks(&self) -> &[Track] {
        &self.tracks
    }

    /// Clear every strip and the master tail, so the next block sounds like the
    /// first one after a seek or a stop.
    pub fn reset(&mut self) {
        for track in &mut self.tracks {
            track.channel.reset();
        }
        for slot in &mut self.master {
            slot.reset();
        }
    }

    pub fn tracks_mut(&mut self) -> &mut [Track] {
        &mut self.tracks
    }

    /// Run track `index`'s strip over one mono input block into its stereo out.
    ///
    /// `stereo` must be exactly `mono.len() * 2` samples and no longer than the
    /// prepared period. A short buffer or a long block is an error, never a
    /// reallocation or a panic: the caller owns the block's shape.
    pub fn process(
        &mut self,
        index: usize,
        mono: &[f32],
        stereo: &mut [f32],
    ) -> Result<(), String> {
        self.apply_pending();
        let count = self.tracks.len();
        let track = self
            .tracks
            .get_mut(index)
            .ok_or_else(|| format!("no track {index} (the mixer has {count})"))?;
        track
            .channel
            .process(mono, stereo)
            .map_err(|error| format!("track {index}: {error:?}"))
    }

    /// Sum every track's panned output into one stereo bus (monitoring).
    ///
    /// `bus` is overwritten with the sum and must hold whole stereo frames;
    /// `inputs[index]` is the mono block for track `index`. Missing inputs,
    /// mismatched frame counts and a bus longer than the prepared period are
    /// errors rather than silence pretending to be a mix.
    pub fn mix(&mut self, inputs: &[&[f32]], bus: &mut [f32]) -> Result<(), String> {
        let track_count = self.tracks.len();
        if inputs.len() < track_count {
            return Err(format!(
                "mix needs one input per track: {track_count} tracks, {} inputs",
                inputs.len()
            ));
        }
        self.mix_with(bus, |index| inputs[index])
    }

    /// The same sum, with a caller-owned block provider instead of a slice of
    /// slices. A playback keeps its blocks in its own `Vec<Vec<f32>>`; this lets
    /// it hand them over by index without building a temporary slice of
    /// references on the audio thread.
    pub fn mix_with<'a, F>(&mut self, bus: &mut [f32], input: F) -> Result<(), String>
    where
        F: Fn(usize) -> &'a [f32],
    {
        self.mix_with_live(bus, input, None)
    }

    /// The same sum, with the take's live input added to the bus **before** the
    /// single master pass, so the person and the monitor files hear one
    /// mastering chain. `live` is interleaved stereo and must match the bus;
    /// `None` is exactly [`mix_with`](Mixer::mix_with).
    pub fn mix_with_live<'a, F>(
        &mut self,
        bus: &mut [f32],
        input: F,
        live: Option<&[f32]>,
    ) -> Result<(), String>
    where
        F: Fn(usize) -> &'a [f32],
    {
        self.apply_pending();
        if bus.len() % 2 != 0 {
            return Err(format!(
                "the mix bus must hold whole stereo frames, found {} samples",
                bus.len()
            ));
        }
        let frames = bus.len() / 2;
        let track_count = self.tracks.len();
        if frames > self.scratch.len() / 2 {
            return Err(format!(
                "a {frames}-frame mix block is longer than the prepared {} frames",
                self.scratch.len() / 2
            ));
        }
        // Validate every input before the bus is touched, so a bad call leaves
        // the caller's buffer as it found it.
        for index in 0..track_count {
            if input(index).len() != frames {
                return Err(format!(
                    "track {index} input has {} frames, the bus has {frames}",
                    input(index).len()
                ));
            }
        }
        if let Some(live) = live {
            if live.len() != bus.len() {
                return Err(format!(
                    "the live input has {} samples, the bus has {}",
                    live.len(),
                    bus.len()
                ));
            }
        }

        bus.fill(0.0);
        let Mixer {
            tracks,
            scratch,
            master,
            master_scratch,
            ..
        } = self;
        for (index, track) in tracks.iter_mut().enumerate() {
            let stereo = &mut scratch[..frames * 2];
            track
                .channel
                .process(input(index), stereo)
                .map_err(|error| format!("track {index}: {error:?}"))?;
            for (out, sample) in bus.iter_mut().zip(stereo.iter()) {
                *out += sample;
            }
        }

        // The live input joins the bus here, after every strip and before the
        // master pass below: a master insert that scales the files must scale
        // the live input by the same amount.
        if let Some(live) = live {
            for (out, sample) in bus.iter_mut().zip(live.iter()) {
                *out += sample;
            }
        }

        // The master chain sees the sum, never a track: this is the only place
        // the whole mix exists at once. Each slot runs once per bus channel on
        // deinterleaved halves, so a stereo effect keeps its two tails apart.
        if !master.is_empty() {
            if master_scratch.len() < frames * 2 {
                return Err("the master chain was not prepared for this block".to_string());
            }
            let (left, right) = master_scratch.split_at_mut(frames);
            for (index, frame) in bus.chunks_exact(2).enumerate() {
                left[index] = frame[0];
                right[index] = frame[1];
            }
            for slot in master.iter_mut() {
                slot.process(left, right);
            }
            for (index, frame) in bus.chunks_exact_mut(2).enumerate() {
                frame[0] = left[index];
                frame[1] = right[index];
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_track_per_label_and_the_input_index_is_kept() {
        let mixer = Mixer::new(&[1, 0], &["guitar", "vocal"]);
        assert_eq!(mixer.tracks().len(), 2);
        assert_eq!(mixer.tracks()[0].input, 1);
        assert_eq!(mixer.tracks()[0].label, "guitar");
        assert_eq!(mixer.tracks()[1].input, 0);
        assert_eq!(mixer.tracks()[1].label, "vocal");
    }

    #[test]
    fn a_label_without_an_input_falls_back_to_its_index() {
        let mixer = Mixer::new(&[1], &["one", "two"]);
        assert_eq!(mixer.tracks()[0].input, 1);
        assert_eq!(mixer.tracks()[1].input, 1, "the fallback is the position");
    }

    #[test]
    fn a_centre_strip_is_equal_power() {
        let mut mixer = Mixer::new(&[0], &["ch1"]);
        mixer.prepare(48_000, 4);
        let mut stereo = vec![0.0f32; 2];
        mixer.process(0, &[1.0], &mut stereo).expect("process");
        let level = std::f32::consts::FRAC_1_SQRT_2;
        assert!((stereo[0] - level).abs() < 1e-6);
        assert!((stereo[1] - level).abs() < 1e-6);
    }

    #[test]
    fn process_refuses_an_unknown_track() {
        let mut mixer = Mixer::new(&[0], &["ch1"]);
        mixer.prepare(48_000, 4);
        let mut stereo = vec![0.0f32; 2];
        assert!(mixer.process(1, &[1.0], &mut stereo).is_err());
    }

    #[test]
    fn mix_waits_for_every_input() {
        let mut mixer = Mixer::new(&[0, 1], &["ch1", "ch2"]);
        mixer.prepare(48_000, 4);
        let mut bus = vec![0.0f32; 4];
        assert!(mixer.mix(&[&[1.0, 1.0]], &mut bus).is_err());
    }

    #[test]
    fn every_control_of_every_insert_parses_and_names_its_insert() {
        for kind in [
            InsertKind::Tone,
            InsertKind::Distortion,
            InsertKind::Delay,
            InsertKind::Compressor,
            InsertKind::Reverb,
            InsertKind::Flanger,
            InsertKind::Fuzz,
            InsertKind::Amp,
            InsertKind::Limiter,
            InsertKind::Autotune,
            InsertKind::Equalizer,
            InsertKind::Maximizer,
        ] {
            for control in kind.controls() {
                let text = format!("{}.{}", kind.name(), control);
                let name = ParamName::parse(&text).unwrap_or_else(|| panic!("{text}"));
                assert_eq!(name.insert_kind(), Some(kind), "{text}");
                assert_eq!(name.insert(), Some(kind.name()), "{text}");
                assert_eq!(name.control(), *control, "{text}");
                assert!(!name.master(), "{text}");
            }
        }
        assert_eq!(ParamName::parse("gain"), Some(ParamName::Gain));
        assert_eq!(ParamName::parse("pan"), Some(ParamName::Pan));
        // The old spellings still parse to the same control.
        assert_eq!(
            ParamName::parse("compressor.threshold"),
            Some(ParamName::CompressorThreshold)
        );
        assert_eq!(ParamName::parse("delay.mix"), Some(ParamName::DelayMix));
        // An unknown control is refused, not clamped onto a neighbour.
        assert_eq!(ParamName::parse("flanger.wobble"), None);
        assert_eq!(ParamName::parse("amp.volume"), None);
        assert_eq!(ParamName::parse("banana"), None);
        assert_eq!(ParamName::parse("delay"), None);
    }

    #[test]
    fn a_master_name_carries_the_master_flag_and_the_rack_prefix() {
        let name = ParamName::parse("master_comp.thresh").expect("master_comp.thresh");
        assert!(name.master());
        assert!(name.master_capable());
        assert_eq!(name.insert(), Some("master_comp"));
        assert_eq!(name.control(), "thresh");
        assert_eq!(name.with_master(false).insert(), Some("compressor"));

        assert!(ParamName::parse("master_limiter.release").expect("release").master());
        assert_eq!(ParamName::parse("master_comp.wobble"), None);

        let bypass = ParamName::parse("master_comp.bypass").expect("bypass");
        assert!(bypass.master());
        assert!(bypass.bypass());
        assert!(bypass.master_capable());
        assert_eq!(bypass.control(), "bypass");
        assert_eq!(bypass.insert(), Some("master_comp"));
        assert_eq!(ParamName::parse("compressor.bypass"), None);

        assert!(!ParamName::Gain.master());
        assert!(!ParamName::Gain.master_capable());
    }

    #[test]
    fn the_wire_milliseconds_reach_the_effect_as_seconds() {
        let attack = ParamName::parse("compressor.attack").expect("attack");
        assert!((attack.native_value(100.0) - 0.1).abs() < 1e-6);
        let release = ParamName::parse("compressor.release").expect("release");
        assert!((release.native_value(500.0) - 0.5).abs() < 1e-6);
        let ceiling = ParamName::parse("limiter.ceiling").expect("ceiling");
        assert_eq!(ceiling.native_value(-6.0), -6.0);
    }

    #[test]
    fn a_param_queue_applies_to_its_track_at_the_next_block() {
        let mut mixer = Mixer::new(&[0], &["ch1"]);
        mixer.prepare(48_000, 4);
        let queue = mixer.params();
        assert!(queue.push(0, ParamName::Gain, 0.5));
        assert!(queue.push(0, ParamName::Pan, -1.0));

        let mut stereo = vec![0.0f32; 2];
        mixer.process(0, &[1.0], &mut stereo).expect("process");
        assert!((stereo[0] - 0.5).abs() < 1e-6, "left was {}", stereo[0]);
        assert!(stereo[1].abs() < 1e-6, "right was {}", stereo[1]);
    }

    #[test]
    fn a_parameter_after_reset_reaches_the_strip() {
        let mut mixer = Mixer::new(&[0], &["ch1"]);
        mixer.prepare(48_000, 4);
        mixer.tracks_mut()[0].channel.reset();
        assert!(mixer.params().push(0, ParamName::Gain, 0.25));

        let mut stereo = vec![0.0f32; 2];
        mixer.process(0, &[1.0], &mut stereo).expect("process");
        let expected = 0.25 * std::f32::consts::FRAC_1_SQRT_2;
        assert!(
            (stereo[0] - expected).abs() < 1e-6,
            "left was {} not {expected}",
            stereo[0]
        );
    }

    #[test]
    fn a_param_for_another_track_is_refused_by_the_strip_that_has_it() {
        let mut mixer = Mixer::new(&[0], &["ch1"]);
        mixer.prepare(48_000, 4);
        // The ring carries the index; a stale one must not panic or move track 0.
        assert!(mixer.params().push(9, ParamName::Gain, 0.25));

        let mut stereo = vec![0.0f32; 2];
        mixer.process(0, &[1.0], &mut stereo).expect("process");
        let expected = std::f32::consts::FRAC_1_SQRT_2;
        assert!((stereo[0] - expected).abs() < 1e-6);
    }

    #[test]
    fn a_full_param_queue_refuses_instead_of_blocking() {
        let queue = ParamQueue::new();
        for _ in 0..PARAM_QUEUE_LEN {
            assert!(queue.push(0, ParamName::Gain, 1.0));
        }
        assert!(!queue.push(0, ParamName::Gain, 1.0), "the ring overflowed");

        assert!(queue.pop().is_some(), "the oldest change is at the head");
        assert!(queue.push(0, ParamName::Pan, 0.0), "a drained slot is reusable");
    }

    #[test]
    fn the_master_chain_runs_after_the_channels() {
        // Two centred tracks at 0.8 sum to 1.13 per side, above full scale.
        let input = [0.8f32; 8];
        let mut plain = Mixer::new(&[0, 1], &["a", "b"]);
        plain.prepare(48_000, 8);
        let mut plain_bus = vec![0.0f32; 16];
        plain.mix(&[&input, &input], &mut plain_bus).expect("mix");
        let plain_peak = plain_bus
            .iter()
            .fold(0.0f32, |highest, sample| highest.max(sample.abs()));
        assert!(
            plain_peak > 1.0,
            "the two tracks did not sum above full scale: {plain_peak}"
        );

        let mut mixer = Mixer::new(&[0, 1], &["a", "b"]);
        mixer.push_master(InsertKind::Limiter);
        assert!(mixer.set_master("master_limiter.ceiling", -1.0));
        mixer.prepare(48_000, 8);
        let mut bus = vec![0.0f32; 16];
        mixer.mix(&[&input, &input], &mut bus).expect("mix");

        let ceiling = 10f32.powf(-1.0 / 20.0);
        assert!(
            bus.iter().all(|sample| sample.abs() <= ceiling + 1e-4),
            "the master limiter did not catch the summed bus"
        );
    }

    #[test]
    fn a_master_parameter_reaches_the_rack_through_the_queue() {
        let input = [0.8f32; 4096];
        let mut mixer = Mixer::new(&[0], &["ch1"]);
        mixer.push_master(InsertKind::Limiter);
        mixer.prepare(48_000, 4096);
        let name = ParamName::parse("master_limiter.ceiling").expect("ceiling");
        assert!(name.master());
        assert!(mixer.params().push_master(name, -6.0));

        let mut bus = vec![0.0f32; 8192];
        for _ in 0..4 {
            mixer.mix(&[&input], &mut bus).expect("mix");
        }
        let ceiling = 10f32.powf(-6.0 / 20.0);
        assert!(
            bus.iter().all(|sample| sample.abs() <= ceiling + 1e-3),
            "the queued master ceiling did not reach the bus: {bus:?}"
        );
    }

    #[test]
    fn a_bypassed_master_insert_is_transparent() {
        let input: Vec<f32> = (0..256)
            .map(|index| (std::f32::consts::TAU * 220.0 * index as f32 / 48_000.0).sin() * 0.5)
            .collect();

        let mut plain = Mixer::new(&[0], &["ch1"]);
        plain.prepare(48_000, 256);
        let mut expected = vec![0.0f32; 512];
        plain.mix(&[&input], &mut expected).expect("mix");

        let mut mixer = Mixer::new(&[0], &["ch1"]);
        mixer.push_master(InsertKind::Compressor);
        assert!(mixer.set_master("master_comp.threshold", -40.0));
        assert!(mixer.set_master("master_comp.mix", 1.0));
        assert!(mixer.bypass_master("master_comp", true));
        mixer.prepare(48_000, 256);
        let mut bus = vec![0.0f32; 512];
        mixer.mix(&[&input], &mut bus).expect("mix");
        assert_eq!(bus, expected, "a bypassed master insert was not transparent");

        assert!(mixer.bypass_master("master_comp", false));
        mixer.mix(&[&input], &mut bus).expect("mix");
        let changed: f32 = bus
            .iter()
            .zip(&expected)
            .map(|(sample, plain)| (sample - plain).abs())
            .sum();
        assert!(changed > 1e-3, "restoring the insert changed nothing");
    }

    #[test]
    fn the_master_rack_routes_its_prefixed_names() {
        let mut mixer = Mixer::new(&[0], &["ch1"]);
        mixer.push_master(InsertKind::Equalizer);
        assert!(mixer.set_master("master_eq.low", 6.0));
        assert!(mixer.set_master("equalizer.high", -6.0));
        assert!(!mixer.set_master("master_comp.threshold", -10.0));
        assert!(!mixer.set_master("gain", 0.5));
        assert!(mixer.bypass_master("master_eq", true));
        assert!(!mixer.bypass_master("master_limiter", true));
        assert_eq!(mixer.master_insert_names(), "equalizer");
    }

    #[test]
    fn the_live_input_is_summed_before_the_master_chain() {
        // With no files at all the bus is the live input, summed at unity.
        let live = vec![0.8f32; 256];
        let mut plain = Mixer::new(&[], &[]);
        plain.prepare(48_000, 128);
        let mut bus = vec![0.0f32; 256];
        plain
            .mix_with_live(&mut bus, |_| &[] as &[f32], Some(&live))
            .expect("mix");
        assert_eq!(bus, live);

        // A master insert that scales the bus must scale the live input too:
        // the limiter catches the live path exactly as it catches a file.
        let mut mixer = Mixer::new(&[], &[]);
        mixer.push_master(InsertKind::Limiter);
        assert!(mixer.set_master("master_limiter.ceiling", -6.0));
        mixer.prepare(48_000, 128);
        let mut bus = vec![0.0f32; 256];
        for _ in 0..4 {
            mixer
                .mix_with_live(&mut bus, |_| &[] as &[f32], Some(&live))
                .expect("mix");
        }
        let ceiling = 10f32.powf(-6.0 / 20.0);
        assert!(
            bus.iter().all(|sample| sample.abs() <= ceiling + 2e-2),
            "the master chain did not see the live input: {bus:?}"
        );
    }
}
