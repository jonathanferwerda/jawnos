//! Live input monitoring: one captured channel through one channel strip to
//! the outputs.
//!
//! This is the path a plugged-in guitar takes when it is not being recorded.
//! The capture device's input `channel` becomes a mono block, passes through
//! the same [`Channel`] a take uses (trim -> inserts -> equal-power pan), and
//! is written to the stereo outputs. The two streams are unlinked, exactly as
//! the loopback's are: the block size is the latency budget, not a promise.
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
use crate::mixer::ParamQueue;

/// The strip a listener arms: which input, and the strip's knobs.
#[derive(Clone, Debug)]
pub struct ListenPlan {
    /// The device input to monitor, 0-based.
    pub channel: usize,
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
            .map_err(|error| format!("listen strip: {error:?}"))
    }

    /// The strip's channel, for the unit test that proves the chain order.
    #[cfg(test)]
    pub(crate) fn channel_mut(&mut self) -> &mut Channel {
        &mut self.channel
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
    mut progress: impl FnMut(u64),
) -> Result<ListenRun, String> {
    if period == 0 {
        return Err("a listen block must hold at least one frame".to_string());
    }
    if channels == 0 {
        return Err("a capture needs at least one channel".to_string());
    }
    if strip.input() >= channels {
        return Err(format!(
            "listen input {} is outside the {channels}-channel capture",
            strip.input()
        ));
    }

    let mut device = crate::device::NullDevice::new(rate, period, channels);
    if let Some(hz) = tone {
        device = device.with_tone(hz);
    }
    strip.prepare(rate, period);

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
        strip.process_f32(&source[..samples], channels, &mut stereo[..want * 2])?;
        frames += want as u64;
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
}
