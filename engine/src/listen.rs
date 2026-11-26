//! Live input monitoring: one captured channel through one channel strip to
//! the outputs.
//!
//! This is the path a plugged-in guitar takes when it is not being recorded.
//! The capture device's input `channel` becomes a mono block, passes through
//! the same [`Channel`] a take uses (trim -> inserts -> equal-power pan), and
//! is written to the stereo outputs. A listener may name several inputs: each
//! gets its own strip ([`MultiListenStrip`]) and the strips are summed, so a
//! microphone and an instrument can be heard together without a plan. The two
//! streams are unlinked, exactly as the loopback's are: the block size is the
//! latency budget, not a promise.
//!
//! A capture cannot feed both monitoring and a take yet. The socket refuses
//! `listen` while a take records and `record` while listening; sharing one
//! capture between listen and record is the next step.
//!
//! [`run_null`] is the suite's path: no card, a sine (or silence) as the
//! input, and the strip runs exactly as it does on hardware.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::device::Device;
use crate::effect::{Channel, InsertKind};
use crate::mixer::{Mixer, ParamQueue};
use crate::plan::{ChannelPlan, PlanInsert};

/// The strip a listener arms: which input, and the strip's knobs.
#[derive(Clone, Debug)]
pub struct ListenPlan {
    /// The device input to monitor, 0-based. It is the first of `channels`,
    /// kept so a single-input caller still names the field it always named.
    pub channel: usize,
    /// Every device input to monitor. One entry is the historical listen; more
    /// than one is the multi-input monitor, each through its own strip and
    /// summed on the output.
    pub channels: Vec<usize>,
    /// Trim before the inserts.
    pub gain: f32,
    /// -1 left ..= 1 right, after the inserts.
    pub pan: f32,
    /// The insert chain, in the order the caller gave it.
    pub inserts: Vec<InsertKind>,
}

impl ListenPlan {
    /// The chain order `status` reports, e.g. `tone,delay`.
    pub fn insert_list(&self) -> String {
        self.inserts
            .iter()
            .map(|kind| kind.name())
            .collect::<Vec<&str>>()
            .join(",")
    }
}

/// One captured input through a channel strip into a stereo block.
///
/// `process_i16` is the hardware path (ALSA's own S16 samples);
/// `process_f32` is the null path and the unit tests. Both select the same
/// input and run the same [`Channel`], so a live monitor and a recorded take
/// share one definition of trim, inserts and pan.
pub struct ListenStrip {
    channel: Channel,
    input: usize,
    /// The control ring a socket's `param` pushes to; `None` for the CLI.
    params: Option<Arc<ParamQueue>>,
    /// One mono block: the selected input, before the strip.
    mono: Vec<f32>,
    /// One stereo block: the strip's output, before conversion.
    stereo: Vec<f32>,
    /// The master rack the plan named, built into `master` by `prepare`.
    master_plan: Vec<PlanInsert>,
    /// The house mastering pass, after the strip's pan. `None` is no rack.
    master: Option<Mixer>,
}

impl ListenStrip {
    pub fn new(
        input: usize,
        gain: f32,
        pan: f32,
        inserts: &[InsertKind],
        params: Option<Arc<ParamQueue>>,
    ) -> Self {
        let mut channel = Channel::new(gain, pan);
        for kind in inserts {
            channel.push(kind.build());
        }
        ListenStrip {
            channel,
            input,
            params,
            mono: Vec::new(),
            stereo: Vec::new(),
            master_plan: Vec::new(),
            master: None,
        }
    }

    /// The strip a take plan describes: the same [`Channel`] the take records
    /// (`ChannelPlan::channel`), the plan's input channel, and its master rack.
    /// This is what makes a live monitor sound like the take it belongs to:
    /// one definition of the trim, the pedals, the pan and the mastering pass.
    pub fn from_plan(plan: &ChannelPlan, params: Option<Arc<ParamQueue>>) -> Self {
        ListenStrip {
            channel: plan.channel(),
            input: plan.input,
            params,
            mono: Vec::new(),
            stereo: Vec::new(),
            master_plan: plan.master.clone(),
            master: None,
        }
    }

    /// The device input this strip reads.
    pub fn input(&self) -> usize {
        self.input
    }

    /// The trim the strip reads at its next block.
    pub fn gain(&self) -> f32 {
        self.channel.gain()
    }

    /// The pan the strip reads at its next block, -1 left ..= 1 right.
    pub fn pan(&self) -> f32 {
        self.channel.pan()
    }

    /// Move one knob, exactly as a take's strip does. Returns false for a name
    /// this strip does not have.
    pub fn set(&mut self, name: &str, value: f32) -> bool {
        self.channel.set(name, value)
    }

    /// Size the strip and its scratch buffers. Allocation happens here and
    /// nowhere else; the device loop then only reads and writes memory it owns.
    pub fn prepare(&mut self, rate: u32, period: usize) {
        self.channel.prepare(rate, period);
        self.mono = vec![0.0; period];
        self.stereo = vec![0.0; period * 2];
        if !self.master_plan.is_empty() {
            // An empty mixer is the house's mastering pass: `run_master` is the
            // one bus shared by a transport, a playback and this listener.
            let kinds: Vec<InsertKind> =
                self.master_plan.iter().map(|insert| insert.kind).collect();
            let mut rack = Mixer::new(&[], &[]);
            rack.set_master_chain(&kinds, rate, period);
            for insert in &self.master_plan {
                let prefix = insert.kind.master_prefix().unwrap_or(insert.kind.name());
                for (knob, value) in &insert.knobs {
                    rack.set_master(&format!("{prefix}.{knob}"), *value);
                }
            }
            rack.prepare(rate, period);
            self.master = Some(rack);
        } else {
            self.master = None;
        }
    }

    /// Apply every waiting control change at the top of a block.
    fn apply_pending(&mut self) {
        let Some(params) = &self.params else {
            return;
        };
        while let Some((index, name, value)) = params.pop() {
            if index == 0 {
                name.apply_to(&mut self.channel, value);
            }
        }
    }

    /// One interleaved f32 capture block at `channels` samples per frame, and
    /// the stereo block to play. Returns the frames rendered.
    pub fn process_f32(
        &mut self,
        input: &[f32],
        channels: usize,
        out: &mut [f32],
    ) -> Result<usize, String> {
        let frames = self.select_f32(input, channels)?;
        self.render(frames, out.len())?;
        out[..frames * 2].copy_from_slice(&self.stereo[..frames * 2]);
        Ok(frames)
    }

    /// The same, from interleaved i16 capture samples into i16 playback
    /// samples. This is the only conversion the hardware path does.
    pub fn process_i16(
        &mut self,
        input: &[i16],
        channels: usize,
        out: &mut [i16],
    ) -> Result<usize, String> {
        let frames = self.select_i16(input, channels)?;
        self.render(frames, out.len())?;
        for (target, sample) in out[..frames * 2].iter_mut().zip(&self.stereo[..frames * 2]) {
            *target = crate::to_i16(*sample);
        }
        Ok(frames)
    }

    fn block_frames(&self, samples: usize, channels: usize) -> Result<usize, String> {
        if channels == 0 {
            return Err("a capture needs at least one channel".to_string());
        }
        if self.input >= channels {
            return Err(format!(
                "listen input {} is outside the {channels}-channel capture",
                self.input
            ));
        }
        if samples % channels != 0 {
            return Err(format!(
                "a capture block of {samples} samples is not whole {channels}-channel frames"
            ));
        }
        let frames = samples / channels;
        if frames > self.mono.len() {
            return Err(format!(
                "a {frames}-frame block is longer than the prepared {} frames",
                self.mono.len()
            ));
        }
        Ok(frames)
    }

    fn select_f32(&mut self, input: &[f32], channels: usize) -> Result<usize, String> {
        let frames = self.block_frames(input.len(), channels)?;
        for (frame, sample) in self.mono[..frames].iter_mut().enumerate() {
            *sample = input[frame * channels + self.input];
        }
        Ok(frames)
    }

    fn select_i16(&mut self, input: &[i16], channels: usize) -> Result<usize, String> {
        let frames = self.block_frames(input.len(), channels)?;
        for (frame, sample) in self.mono[..frames].iter_mut().enumerate() {
            *sample = f32::from(input[frame * channels + self.input]) / 32_768.0;
        }
        Ok(frames)
    }

    /// Run the strip over `mono[..frames]` into `stereo[..frames * 2]`. The
    /// caller's buffer must be at least that long.
    fn render(&mut self, frames: usize, out_len: usize) -> Result<(), String> {
        self.apply_pending();
        let stereo = frames * 2;
        if out_len < stereo {
            return Err(format!(
                "the listen output holds {out_len} samples, the block needs {stereo}"
            ));
        }
        self.channel
            .process(&self.mono[..frames], &mut self.stereo[..stereo])
            .map_err(|error| format!("listen strip: {error:?}"))?;
        if let Some(rack) = self.master.as_mut() {
            rack.run_master(&mut self.stereo[..stereo])
                .map_err(|error| format!("listen master: {error}"))?;
        }
        Ok(())
    }

    /// The strip's channel, for the unit test that proves the chain order.
    #[cfg(test)]
    pub(crate) fn channel_mut(&mut self) -> &mut Channel {
        &mut self.channel
    }
}

/// Several inputs monitored at once, each through its own [`ListenStrip`] and
/// summed on the output.
///
/// The historical listen is one input. Studio can need to hear two at once
/// (a microphone and an instrument) before a take starts, and the patchbay is
/// the house's multi-source path; this is the same idea without a plan: every
/// input keeps its own trim, inserts and pan, and the output is their sum.
/// Each strip is built separately, so an insert's state is never shared between
/// inputs.
pub struct MultiListenStrip {
    strips: Vec<ListenStrip>,
    /// The one control ring every strip drains. A `param` is broadcast: a page
    /// that moves the monitor's gain expects every input to move, exactly as
    /// the one-input listen does.
    params: Option<Arc<ParamQueue>>,
}

impl MultiListenStrip {
    pub fn new(
        inputs: &[usize],
        gain: f32,
        pan: f32,
        inserts: &[InsertKind],
        params: Option<Arc<ParamQueue>>,
    ) -> Self {
        let strips = inputs
            .iter()
            .map(|input| ListenStrip::new(*input, gain, pan, inserts, None))
            .collect();
        MultiListenStrip { strips, params }
    }

    pub fn inputs(&self) -> Vec<usize> {
        self.strips.iter().map(ListenStrip::input).collect()
    }

    pub fn prepare(&mut self, rate: u32, period: usize) {
        for strip in &mut self.strips {
            strip.prepare(rate, period);
        }
    }

    fn apply_pending(&mut self) {
        let Some(params) = &self.params else {
            return;
        };
        while let Some((_index, name, value)) = params.pop() {
            for strip in &mut self.strips {
                name.apply_to(&mut strip.channel, value);
            }
        }
    }

    fn block_frames(&self, samples: usize, channels: usize) -> Result<usize, String> {
        if channels == 0 {
            return Err("a capture needs at least one channel".to_string());
        }
        for strip in &self.strips {
            if strip.input() >= channels {
                return Err(format!(
                    "listen input {} is outside the {channels}-channel capture",
                    strip.input()
                ));
            }
        }
        if samples % channels != 0 {
            return Err(format!(
                "a capture block of {samples} samples is not whole {channels}-channel frames"
            ));
        }
        let frames = samples / channels;
        for strip in &self.strips {
            if frames > strip.mono.len() {
                return Err(format!(
                    "a {frames}-frame block is longer than the prepared {} frames",
                    strip.mono.len()
                ));
            }
        }
        Ok(frames)
    }

    /// One interleaved f32 capture block at `channels` samples per frame, and
    /// the summed stereo block to play.
    pub fn process_f32(
        &mut self,
        input: &[f32],
        channels: usize,
        out: &mut [f32],
    ) -> Result<usize, String> {
        let frames = self.block_frames(input.len(), channels)?;
        let stereo = frames * 2;
        if out.len() < stereo {
            return Err(format!(
                "the listen output holds {} samples, the block needs {stereo}",
                out.len()
            ));
        }
        self.apply_pending();
        out[..stereo].fill(0.0);
        for strip in &mut self.strips {
            strip.select_f32(input, channels)?;
            let out_len = strip.stereo.len();
            strip.render(frames, out_len)?;
            for (target, sample) in out[..stereo].iter_mut().zip(&strip.stereo[..stereo]) {
                *target += sample;
            }
        }
        Ok(frames)
    }

    /// The same, from interleaved i16 capture samples into i16 playback samples.
    pub fn process_i16(
        &mut self,
        input: &[i16],
        channels: usize,
        out: &mut [i16],
    ) -> Result<usize, String> {
        let frames = self.block_frames(input.len(), channels)?;
        let stereo = frames * 2;
        if out.len() < stereo {
            return Err(format!(
                "the listen output holds {} samples, the block needs {stereo}",
                out.len()
            ));
        }
        self.apply_pending();
        out[..stereo].fill(0);
        for strip in &mut self.strips {
            strip.select_i16(input, channels)?;
            let out_len = strip.stereo.len();
            strip.render(frames, out_len)?;
            for (target, sample) in out[..stereo].iter_mut().zip(&strip.stereo[..stereo]) {
                *target = target.saturating_add(crate::to_i16(*sample));
            }
        }
        Ok(frames)
    }
}

/// The strip a listen actually runs: one input or the same strip once per
/// input. The worker, the null loop and the hardware sink all speak to this one
/// type, so a one-input listen takes exactly the old path.
pub enum ListenUnit {
    One(ListenStrip),
    Many(MultiListenStrip),
}

impl ListenUnit {
    /// Build the unit a plan asks for. One channel is the historical strip;
    /// several are a strip per channel. The plan's `channel` is the first entry
    /// of `channels`, so a caller that only filled the old field still works.
    pub fn new(plan: &ListenPlan, params: Option<Arc<ParamQueue>>) -> Self {
        if plan.channels.len() > 1 {
            ListenUnit::Many(MultiListenStrip::new(
                &plan.channels,
                plan.gain,
                plan.pan,
                &plan.inserts,
                params,
            ))
        } else {
            let channel = plan.channels.first().copied().unwrap_or(plan.channel);
            ListenUnit::One(ListenStrip::new(
                channel,
                plan.gain,
                plan.pan,
                &plan.inserts,
                params,
            ))
        }
    }
}

/// What one listen loop produced: the shape the device granted and the frames
/// that went through the strip.
#[derive(Clone, Debug)]
pub struct ListenRun {
    pub rate: u32,
    pub period: usize,
    pub buffer: usize,
    pub channels: usize,
    pub frames: u64,
    pub xruns: usize,
}

/// The one JSON line `--listen` prints, and the line a socket `stop` carries:
/// `{"ok":true,"backend":"alsa","device":"hw:1,0","channel":1,...}`. A failed
/// run keeps the same shape with zero frames, so a caller parses one struct
/// either way.
#[derive(Clone, Debug)]
pub struct ListenReport {
    pub ok: bool,
    pub backend: &'static str,
    pub device: String,
    pub channel: usize,
    pub frames: u64,
    pub rate: u32,
    pub xruns: usize,
    pub error: String,
}

impl ListenReport {
    pub fn success(
        backend: &'static str,
        device: String,
        channel: usize,
        frames: u64,
        rate: u32,
        xruns: usize,
    ) -> Self {
        ListenReport {
            ok: true,
            backend,
            device,
            channel,
            frames,
            rate,
            xruns,
            error: String::new(),
        }
    }

    pub fn failure(
        backend: &'static str,
        device: String,
        channel: usize,
        rate: u32,
        error: String,
    ) -> Self {
        ListenReport {
            ok: false,
            backend,
            device,
            channel,
            frames: 0,
            rate,
            xruns: 0,
            error,
        }
    }

    pub fn to_json(&self) -> String {
        format!(
            "{{\"ok\":{},\"backend\":\"{}\",\"device\":\"{}\",\"channel\":{},\"frames\":{},\"rate\":{},\"xruns\":{},\"error\":\"{}\"}}",
            self.ok,
            crate::loopback::json_escape(self.backend),
            crate::loopback::json_escape(&self.device),
            self.channel,
            self.frames,
            self.rate,
            self.xruns,
            crate::loopback::json_escape(&self.error)
        )
    }
}

/// The lead a duplex monitor primes before its first capture read: one full
/// playback buffer, and never less than one period. A playback auto-starts on
/// its first write and drains while the loop blocks on the next capture read,
/// so a single write per read gives it no cushion and it underruns almost every
/// block. One buffer of silence absorbs the capture read's jitter; capture and
/// playback share the card's clock, so the lead does not drift away.
pub fn monitor_prefill_frames(buffer: usize, period: usize) -> usize {
    buffer.max(period).max(1)
}

/// How long the physical output takes to reach silence when the engine is told
/// to stop, and to come back up when it starts. Twenty milliseconds is short
/// enough to hand the device over inside the supervisor's stop grace, and long
/// enough that the edge is a fade rather than a step. A step is a click, and a
/// click at release is what the person hears as the engine letting go of the
/// audio.
pub const EDGE_FADE_MS: u32 = 20;

/// The fade's length in frames at `rate`, and never zero.
pub fn edge_fade_frames(rate: u32) -> usize {
    ((u64::from(rate) * u64::from(EDGE_FADE_MS)) / 1000) as usize
}

/// A one-frame-at-a-time gain ramp for the device's edge.
///
/// The loop renders whole blocks, so a fade cannot be one ramp: the gain has to
/// carry across blocks and land exactly on its target when the last frame of
/// the fade has been written. [`Edge::new`] starts it at silence and fades in;
/// [`Edge::toward`] reverses it, and [`Edge::silent`] is the caller's signal
/// that the fade to silence has arrived and the device can be drained.
#[derive(Clone, Copy, Debug)]
pub struct Edge {
    frames: usize,
    left: usize,
    gain: f32,
    step: f32,
    target: f32,
}

impl Edge {
    pub fn new(frames: usize) -> Self {
        let frames = frames.max(1);
        // The first frame is silence and the last frame of the fade is unity,
        // so the step spans the frames between them.
        let span = frames.saturating_sub(1).max(1) as f32;
        Edge {
            frames,
            left: frames,
            gain: 0.0,
            step: 1.0 / span,
            target: 1.0,
        }
    }

    /// Start a fade to `target` over the configured length. Asking for the
    /// target already in flight changes nothing; asking for the other one
    /// reverses the ramp from wherever the gain is now, so no step appears.
    pub fn toward(&mut self, target: f32) {
        let target = target.clamp(0.0, 1.0);
        if (target - self.target).abs() < f32::EPSILON {
            return;
        }
        self.target = target;
        self.left = self.frames;
        // The first frame keeps the gain it already had and the last frame of
        // the fade lands on the target, so the ramp neither steps in nor out.
        let span = self.frames.saturating_sub(1).max(1) as f32;
        self.step = (target - self.gain) / span;
    }

    /// True once a fade to silence has written its last frame. The caller stops
    /// there rather than at the stop flag, so the release is silent.
    pub fn silent(&self) -> bool {
        self.left == 0 && self.gain <= 0.0
    }

    /// Scale one interleaved block and advance the ramp.
    pub fn apply(&mut self, block: &mut [i16], channels: usize) {
        if channels == 0 {
            return;
        }
        for frame in block.chunks_mut(channels) {
            let gain = self.gain;
            for sample in frame.iter_mut() {
                *sample = (f32::from(*sample) * gain).round() as i16;
            }
            if self.left > 0 {
                self.left -= 1;
                self.gain = if self.left == 0 {
                    self.target
                } else {
                    (self.gain + self.step).clamp(0.0, 1.0)
                };
            }
        }
    }
}

/// Add the machine's system mix to an already-rendered stereo i16 block. The
/// listen strip's own input is the capture; the system mix is the machine's
/// ordinary audio and stays at unity, exactly as the patchbay's fallback does.
/// A short ring is silence for the part it does not carry.
pub fn add_system_to_i16(output: &mut [i16], system: &[f32], frames: usize) {
    let samples = frames.saturating_mul(2).min(output.len());
    let carried = system.len().min(samples);
    for (target, sample) in output[..carried].iter_mut().zip(&system[..carried]) {
        *target = target.saturating_add(crate::to_i16(*sample));
    }
}

/// What a hardware listen loop hands its blocks to. The ALSA module owns the
/// streams; this trait keeps it free of the strip's types, exactly as
/// [`crate::alsa_device::CaptureSink`] does for a take.
pub trait ListenSink {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String>;
    /// One interleaved capture block and the stereo block to play.
    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String>;
    /// The same block with the machine's system mix (interleaved stereo f32,
    /// already at the capture's frame count). A sink that has no use for it
    /// keeps the old two-argument path exactly.
    fn block_with_system(
        &mut self,
        input: &[i16],
        system: &[f32],
        output: &mut [i16],
    ) -> Result<(), String> {
        let _ = system;
        self.block(input, output)
    }

    /// The f32 shape, for the null loop and its tests. A hardware sink does not
    /// need it, so the default names that rather than converting twice. The
    /// capture width is explicit because an f32 block carries no frame marker.
    fn block_f32(
        &mut self,
        _input: &[f32],
        _channels: usize,
        _output: &mut [f32],
    ) -> Result<usize, String> {
        Err("this listen sink has no f32 path".to_string())
    }
}

impl ListenSink for ListenStrip {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        let _ = channels;
        self.prepare(rate, period);
        Ok(())
    }

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        let channels = channels_of(input.len(), output.len());
        self.process_i16(input, channels, output)?;
        Ok(())
    }

    fn block_with_system(
        &mut self,
        input: &[i16],
        system: &[f32],
        output: &mut [i16],
    ) -> Result<(), String> {
        let channels = channels_of(input.len(), output.len());
        let frames = self.process_i16(input, channels, output)?;
        add_system_to_i16(output, system, frames);
        Ok(())
    }

    fn block_f32(
        &mut self,
        input: &[f32],
        channels: usize,
        output: &mut [f32],
    ) -> Result<usize, String> {
        self.process_f32(input, channels, output)
    }
}

/// The trait's `block` methods carry no channel count, because a hardware sink
/// is handed the block's shape by its device loop. These impls derive it from
/// the capture and output lengths (the output is always twice the frames); the
/// null path passes the width explicitly through `block_f32`.
impl ListenSink for MultiListenStrip {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        let _ = channels;
        self.prepare(rate, period);
        Ok(())
    }

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        let channels = channels_of(input.len(), output.len());
        self.process_i16(input, channels, output)?;
        Ok(())
    }

    fn block_f32(
        &mut self,
        input: &[f32],
        channels: usize,
        output: &mut [f32],
    ) -> Result<usize, String> {
        self.process_f32(input, channels, output)
    }
}

impl ListenSink for ListenUnit {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        let _ = channels;
        match self {
            ListenUnit::One(strip) => strip.prepare(rate, period),
            ListenUnit::Many(strips) => strips.prepare(rate, period),
        }
        Ok(())
    }

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        let channels = channels_of(input.len(), output.len());
        match self {
            ListenUnit::One(strip) => {
                strip.process_i16(input, channels, output)?;
            }
            ListenUnit::Many(strips) => {
                strips.process_i16(input, channels, output)?;
            }
        }
        Ok(())
    }

    fn block_with_system(
        &mut self,
        input: &[i16],
        system: &[f32],
        output: &mut [i16],
    ) -> Result<(), String> {
        self.block(input, output)?;
        let frames = output.len() / 2;
        add_system_to_i16(output, system, frames);
        Ok(())
    }

    fn block_f32(
        &mut self,
        input: &[f32],
        channels: usize,
        output: &mut [f32],
    ) -> Result<usize, String> {
        match self {
            ListenUnit::One(strip) => strip.process_f32(input, channels, output),
            ListenUnit::Many(strips) => strips.process_f32(input, channels, output),
        }
    }
}

/// The channel count of an i16 capture/output pair. The trait hands a sink the
/// blocks without a width, so it is derived from the pair: the output is twice
/// the frames and the capture is `channels` samples per frame. The null path
/// does not use this; it passes the width to `block_f32` explicitly.
fn channels_of(input_len: usize, output_len: usize) -> usize {
    let frames = output_len / 2;
    if frames == 0 {
        1
    } else {
        (input_len / frames).max(1)
    }
}

/// The null listen loop: a sine (or silence) as the capture input, the strip,
/// and a stereo block nobody plays.
///
/// `total` is the run's frame count (`--seconds`); `None` runs until `stop`.
/// `progress` is called once per block so the socket's `status` can report
/// frames while the loop runs. The null backend is not paced: it exists to
/// exercise the whole path on a machine with no sound card.
pub fn run_null(
    strip: &mut ListenStrip,
    rate: u32,
    period: usize,
    channels: usize,
    total: Option<u64>,
    tone: Option<f32>,
    stop: &AtomicBool,
    progress: impl FnMut(u64),
) -> Result<ListenRun, String> {
    let input = strip.input();
    run_null_sink(
        strip, &[input], rate, period, channels, total, tone, stop, progress,
    )
}

/// The same null loop over any sink: the unit a multi listen builds, a bare
/// strip, or a test double. `inputs` is the set of device inputs the run asked
/// for, validated here rather than trusted from the caller.
pub fn run_null_sink(
    sink: &mut dyn ListenSink,
    inputs: &[usize],
    rate: u32,
    period: usize,
    channels: usize,
    total: Option<u64>,
    tone: Option<f32>,
    stop: &AtomicBool,
    mut progress: impl FnMut(u64),
) -> Result<ListenRun, String> {
    if period == 0 {
        return Err("a listen block must hold at least one frame".to_string());
    }
    if channels == 0 {
        return Err("a capture needs at least one channel".to_string());
    }
    if inputs.is_empty() {
        return Err("a listen needs at least one input".to_string());
    }
    for input in inputs {
        if *input >= channels {
            return Err(format!(
                "listen input {input} is outside the {channels}-channel capture"
            ));
        }
    }

    let mut device = crate::device::NullDevice::new(rate, period, channels);
    if let Some(hz) = tone {
        device = device.with_tone(hz);
    }
    sink.prepared(rate, period, channels)?;

    let mut source = vec![0.0f32; period * channels];
    let mut stereo = vec![0.0f32; period * 2];
    let mut frames = 0u64;

    loop {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        let want = match total {
            Some(total) if frames >= total => break,
            Some(total) => (total - frames).min(period as u64) as usize,
            None => period,
        };
        // The device is always asked for a whole period; the last block of a
        // `--seconds` run uses only the frames that remain.
        device
            .process(&mut source)
            .map_err(|error| format!("device: {error:?}"))?;
        let samples = want * channels;
        let rendered = sink.block_f32(&source[..samples], channels, &mut stereo[..want * 2])?;
        frames += rendered as u64;
        progress(frames);
        // Let a client polling `status` run between blocks; a tight loop would
        // starve the control thread.
        std::thread::yield_now();
    }

    Ok(ListenRun {
        rate,
        period,
        buffer: period,
        channels,
        frames,
        xruns: 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::Effect;

    const RATE: u32 = 48_000;

    /// Test-only effects with a non-commuting pair of operations, so the order
    /// the strip runs its inserts in is observable.
    struct Add(f32);
    impl Effect for Add {
        fn prepare(&mut self, _rate: u32, _max_frames: usize) {}
        fn process(&mut self, block: &mut [f32]) {
            for sample in block.iter_mut() {
                *sample += self.0;
            }
        }
        fn reset(&mut self) {}
        fn name(&self) -> &'static str {
            "add"
        }
    }

    struct Multiply(f32);
    impl Effect for Multiply {
        fn prepare(&mut self, _rate: u32, _max_frames: usize) {}
        fn process(&mut self, block: &mut [f32]) {
            for sample in block.iter_mut() {
                *sample *= self.0;
            }
        }
        fn reset(&mut self) {}
        fn name(&self) -> &'static str {
            "multiply"
        }
    }

    #[test]
    fn the_listen_strip_runs_gain_then_inserts_then_pan() {
        // The same order a take's Channel proves: a gain, then an add, then a
        // multiply, then a hard-left pan. Any other order gives another number.
        let mut strip = ListenStrip::new(0, 0.5, -1.0, &[], None);
        strip.channel_mut().push(Box::new(Add(0.25)));
        strip.channel_mut().push(Box::new(Multiply(4.0)));
        strip.prepare(RATE, 4);

        let input = vec![0.2f32; 4];
        let mut out = vec![0.0f32; 8];
        let frames = strip.process_f32(&input, 1, &mut out).expect("process");
        assert_eq!(frames, 4);

        // 0.2 * gain 0.5 = 0.1; + 0.25 = 0.35; * 4 = 1.4; hard left.
        assert!((out[0] - 1.4).abs() < 1e-6, "left was {}", out[0]);
        assert!(out[1].abs() < 1e-6, "right was {}", out[1]);
        assert!((out[6] - 1.4).abs() < 1e-6);
    }

    #[test]
    fn a_listen_strip_selects_only_its_channel() {
        // Interleaved left/right: input 1 is the second sample of every frame.
        let mut strip = ListenStrip::new(1, 1.0, -1.0, &[], None);
        strip.prepare(RATE, 2);
        let input = [9.0, 0.5, 9.0, 0.25];
        let mut out = vec![0.0f32; 4];
        strip.process_f32(&input, 2, &mut out).expect("process");
        assert!((out[0] - 0.5).abs() < 1e-6, "left was {}", out[0]);
        assert!(out[1].abs() < 1e-6, "right was {}", out[1]);
        assert!((out[2] - 0.25).abs() < 1e-6);
    }

    #[test]
    fn an_input_outside_the_capture_is_an_error() {
        let mut strip = ListenStrip::new(2, 1.0, 0.0, &[], None);
        strip.prepare(RATE, 2);
        let mut out = vec![0.0f32; 4];
        let error = strip.process_f32(&[0.0; 4], 2, &mut out).unwrap_err();
        assert!(error.contains("outside"), "{error}");
    }

    #[test]
    fn a_listen_strip_can_be_built_from_a_take_plan() {
        // The same plan a take records through: input 1, a trim, and the song's
        // master rack after the pan. The rack's ceiling is what tells the two
        // renders apart, so the monitor keeps the chain the take belongs to.
        fn peak(plan_text: &str) -> f32 {
            let plan = crate::plan::parse_plan(Some(plan_text))
                .expect("valid")
                .expect("not raw");
            let mut strip = ListenStrip::from_plan(&plan, None);
            strip.prepare(RATE, 64);
            let mut input = vec![0.0f32; 128];
            for frame in 0..64 {
                input[frame * 2 + 1] = 0.8;
            }
            let mut out = vec![0.0f32; 128];
            let mut peak = 0.0f32;
            for _ in 0..8 {
                strip.process_f32(&input, 2, &mut out).expect("render");
                peak = peak.max(out.iter().cloned().fold(0.0, f32::max));
            }
            peak
        }

        let dry = peak(r#"{"channel":1,"gain":4}"#);
        let limited = peak(r#"{"channel":1,"gain":4,"master_limiter":{"ceiling":-24}}"#);
        assert!(dry > 1.0, "the instrument channel was not monitored: {dry}");
        assert!(
            limited < dry * 0.5,
            "the master rack did not run: dry {dry}, limited {limited}"
        );
    }

    #[test]
    fn a_null_run_renders_exactly_seconds() {
        let stop = AtomicBool::new(false);
        let mut strip = ListenStrip::new(1, 0.5, 0.0, &[InsertKind::Tone], None);
        let run = run_null(
            &mut strip,
            48_000,
            64,
            2,
            Some(4_800),
            Some(440.0),
            &stop,
            |_| {},
        )
        .expect("null listen");
        assert_eq!(run.frames, 4_800);
        assert_eq!(run.rate, 48_000);
        assert_eq!(run.channels, 2);
        assert_eq!(run.xruns, 0);
    }

    #[test]
    fn a_stopped_null_run_reports_the_frames_it_had() {
        let stop = AtomicBool::new(true);
        let mut strip = ListenStrip::new(0, 1.0, 0.0, &[], None);
        let run = run_null(&mut strip, 48_000, 64, 2, None, None, &stop, |_| {})
            .expect("null listen");
        assert_eq!(run.frames, 0);
    }

    #[test]
    fn a_listen_output_carries_the_system_mix_at_unity() {
        // The strip renders 0.25; the system ring adds -0.25. The monitor
        // hears the sum; an absent ring leaves the strip's own block untouched.
        let mut out = vec![crate::to_i16(0.25f32); 4];
        let system = [0.25f32, -0.25, 0.25, -0.25, 0.25, -0.25];
        add_system_to_i16(&mut out, &system, 4);
        assert_eq!(out[0], crate::to_i16(0.5));
        assert_eq!(out[1], crate::to_i16(0.0));
        assert_eq!(out[2], crate::to_i16(0.5));
        assert_eq!(out[3], crate::to_i16(0.0));

        let mut untouched = vec![1234i16; 4];
        add_system_to_i16(&mut untouched, &[], 2);
        assert_eq!(untouched, vec![1234i16; 4], "an absent ring is silence");
    }

    #[test]
    fn the_edge_starts_silent_and_rises_to_unity() {
        let mut edge = Edge::new(4);
        let mut block = vec![10_000i16; 8];
        edge.apply(&mut block, 2);
        // Frame 0 is silence, and the last frame of the fade is full scale.
        assert_eq!(&block[0..2], &[0, 0]);
        assert_eq!(block[6], 10_000);
        assert!(!edge.silent());
        // A second block is past the fade and passes through unchanged.
        let mut after = vec![10_000i16; 4];
        edge.apply(&mut after, 2);
        assert_eq!(after, vec![10_000i16; 4]);
    }

    #[test]
    fn a_stop_ramps_to_silence_and_reports_it() {
        let mut edge = Edge::new(4);
        // Finish the fade-in first, so the fade-out starts at unity.
        let mut warm = vec![10_000i16; 8];
        edge.apply(&mut warm, 2);
        edge.toward(0.0);
        let mut block = vec![10_000i16; 8];
        edge.apply(&mut block, 2);
        assert_eq!(block[0], 10_000, "the fade keeps the gain it had");
        assert_eq!(block[6], 0, "the last frame of the fade is silent");
        assert!(edge.silent(), "the loop can stop there, not one block later");
    }

    #[test]
    fn an_edge_never_divides_by_zero_and_keeps_the_channels() {
        let mut edge = Edge::new(0);
        let mut block = vec![5_000i16; 6];
        edge.apply(&mut block, 2);
        assert_eq!(&block[0..2], &[0, 0], "a zero-frame fade is one frame of silence");
        assert_eq!(block.len(), 6, "every channel is written");
        let mut empty: [i16; 0] = [];
        edge.apply(&mut empty, 2);
        assert_eq!(edge_fade_frames(48_000), 960);
    }

    #[test]
    fn a_duplex_monitor_primes_at_least_one_full_playback_buffer() {
        // The 64/256 shape on the table: a 256-frame lead, four periods deep.
        assert_eq!(monitor_prefill_frames(256, 64), 256);
        // A buffer smaller than the period (unusual, but granted) still primes
        // one whole period rather than nothing.
        assert_eq!(monitor_prefill_frames(48, 64), 64);
        assert_eq!(monitor_prefill_frames(0, 0), 1);
    }

    #[test]
    fn the_report_is_one_line_with_the_contract_keys() {
        let report = ListenReport::success("alsa", "hw:1,0".to_string(), 1, 4_800, 48_000, 0);
        assert_eq!(
            report.to_json(),
            "{\"ok\":true,\"backend\":\"alsa\",\"device\":\"hw:1,0\",\"channel\":1,\"frames\":4800,\"rate\":48000,\"xruns\":0,\"error\":\"\"}"
        );
        let failed = ListenReport::failure("null", "null".to_string(), 0, 48_000, "no card".into());
        assert!(failed.to_json().starts_with("{\"ok\":false,"));
        assert!(failed.to_json().contains("\"frames\":0"));
    }

    #[test]
    fn a_multi_listen_sums_each_input_through_its_own_strip() {
        let mut strip = MultiListenStrip::new(&[0, 1], 1.0, 0.0, &[], None);
        strip.prepare(RATE, 4);
        let input = [0.5f32, 0.25, 0.5, 0.25, 0.5, 0.25, 0.5, 0.25];
        let mut out = vec![0.0f32; 8];
        let frames = strip.process_f32(&input, 2, &mut out).expect("process");
        assert_eq!(frames, 4);
        // 0.5 + 0.25 at a centred pan is 0.75/√2 in each speaker.
        let expected = 0.75f32 / std::f32::consts::SQRT_2;
        for frame in out.chunks(2) {
            assert!((frame[0] - expected).abs() < 1e-5, "{frame:?}");
            assert!((frame[1] - expected).abs() < 1e-5, "{frame:?}");
        }
    }

    #[test]
    fn a_multi_listen_broadcasts_one_param_to_every_input() {
        let params = Arc::new(ParamQueue::new());
        let mut strip = MultiListenStrip::new(&[0, 1], 0.5, 0.0, &[], Some(Arc::clone(&params)));
        strip.prepare(RATE, 4);
        let input = [0.5f32, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5];
        let mut out = vec![0.0f32; 8];
        strip.process_f32(&input, 2, &mut out).expect("first block");
        let quiet = out[0];

        params.push(0, crate::mixer::ParamName::Gain, 1.0);
        strip.process_f32(&input, 2, &mut out).expect("second block");
        assert!(out[0] > quiet, "the trim moved both inputs: {quiet} -> {}", out[0]);
    }

    #[test]
    fn a_null_run_over_several_inputs_renders_its_frames() {
        let stop = AtomicBool::new(false);
        let mut strip = MultiListenStrip::new(&[0, 1], 0.8, 0.0, &[InsertKind::Tone], None);
        let run = run_null_sink(
            &mut strip,
            &[0, 1],
            48_000,
            64,
            2,
            Some(64),
            Some(440.0),
            &stop,
            |_| {},
        )
        .expect("null multi listen");
        assert_eq!(run.frames, 64);
    }

    #[test]
    fn a_multi_listen_refuses_an_input_the_capture_does_not_have() {
        let mut strip = MultiListenStrip::new(&[0, 2], 1.0, 0.0, &[], None);
        strip.prepare(RATE, 2);
        let mut out = vec![0.0f32; 4];
        let error = strip
            .process_f32(&[0.0; 4], 2, &mut out)
            .expect_err("refused");
        assert!(error.contains("outside"), "{error}");
    }
}
