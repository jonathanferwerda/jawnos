//! Playing recorded takes back through the strips that recorded them.
//!
//! A take on disk is the stereo output of one channel strip. Playback runs it
//! backwards through the same kind of strip: every file is downmixed to one
//! mono timeline, trimmed, sent through its inserts in chain order, panned to
//! the equal-power pair, and summed with the other files into one stereo block
//! ([`crate::mixer::Mixer`] owns the strips, so playback and recording share
//! one definition of a channel).
//!
//! The whole file is held in memory because a take is minutes, not hours, and
//! the alternative — seeking per block — would make the block loop depend on
//! the disk. [`Playback::render`] allocates nothing after [`Playback::prepare`]:
//! the null and ALSA drivers both call it from the loop that feeds the device.
//!
//! All files share one timeline and one sample rate. They are assumed to have
//! been recorded from the same transport, and `--start-at` skips the same
//! number of frames in every one of them.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use crate::effect::{Channel, InsertKind};
use crate::mixer::{Mixer, ParamQueue};
use crate::monbus::Consumer;
use crate::wav_read::{read_wav, WavAudio};

/// One file and the strip it plays through.
pub struct PlayTrack {
    /// The path the report and diagnostics name.
    pub path: String,
    /// The file's rate; every track in one playback must agree.
    pub rate: u32,
    /// One mono sample per frame, already downmixed from the file.
    pub samples: Vec<f32>,
    /// Trim before the inserts.
    pub gain: f32,
    /// -1 left ..= 1 right, after the inserts.
    pub pan: f32,
    /// The insert chain, in the order the caller gave it.
    pub inserts: Vec<InsertKind>,
}

impl PlayTrack {
    /// Decode `path` into a mono timeline. The reader names the file and what
    /// it found when it refuses a shape.
    pub fn from_wav(
        path: impl Into<String>,
        gain: f32,
        pan: f32,
        inserts: Vec<InsertKind>,
    ) -> Result<Self, String> {
        let path = path.into();
        let audio = read_wav(&path).map_err(|error| error.to_string())?;
        Ok(Self::from_audio(path, audio, gain, pan, inserts))
    }

    /// The same, from an already-decoded file (tests and callers that hold one).
    pub fn from_audio(
        path: impl Into<String>,
        audio: WavAudio,
        gain: f32,
        pan: f32,
        inserts: Vec<InsertKind>,
    ) -> Self {
        PlayTrack {
            path: path.into(),
            rate: audio.rate,
            samples: audio.mono(),
            gain,
            pan,
            inserts,
        }
    }
}

/// One monitor file and the strip it plays through.
///
/// The monitor bus is a playback like any other, so a monitor file is a
/// [`PlayTrack`] with its own gain, pan and inserts rather than a bare wire.
/// Keeping the plan separate from the decoded samples lets the socket answer
/// `status` with what the caller armed before the playback thread exists.
#[derive(Clone, Debug)]
pub struct MonitorSpec {
    /// The absolute path the caller named.
    pub path: String,
    /// Trim before the inserts.
    pub gain: f32,
    /// -1 left ..= 1 right, after the inserts.
    pub pan: f32,
    /// The insert chain, in the order the caller gave it.
    pub inserts: Vec<InsertKind>,
}

impl MonitorSpec {
    /// A bare wire: unity trim, centre pan, no inserts. This is what the
    /// historical list of monitor paths arms.
    pub fn wire(path: impl Into<String>) -> Self {
        MonitorSpec {
            path: path.into(),
            gain: 1.0,
            pan: 0.0,
            inserts: Vec::new(),
        }
    }

    /// The chain order `status` reports, e.g. `tone,delay`.
    pub fn insert_list(&self) -> String {
        self.inserts
            .iter()
            .map(|kind| kind.name())
            .collect::<Vec<&str>>()
            .join(",")
    }
}

/// The `monitor` array `status` carries, e.g.
/// `,"monitor":[{"file":"/a.wav","gain":1,"pan":0,"inserts":[]}]`.
///
/// Empty for a playback that is not a monitor, so appending the result cannot
/// add a key no caller asked for.
pub fn monitor_json(specs: &[MonitorSpec]) -> String {
    if specs.is_empty() {
        return String::new();
    }
    let entries: Vec<String> = specs
        .iter()
        .map(|spec| {
            let inserts: Vec<String> = spec
                .inserts
                .iter()
                .map(|kind| format!("\"{}\"", kind.name()))
                .collect();
            format!(
                "{{\"file\":\"{}\",\"gain\":{},\"pan\":{},\"inserts\":[{}]}}",
                crate::loopback::json_escape(&spec.path),
                spec.gain,
                spec.pan,
                inserts.join(",")
            )
        })
        .collect();
    format!(",\"monitor\":[{}]", entries.join(","))
}

/// Where the monitor starts, given the take's stamp and the measured capture
/// offset.
///
/// The monitor is started *earlier* by the round trip the capture will add, so
/// the sound the person hears while playing lands at the take's first sample.
/// A take at sample 0 cannot start earlier, so the result is clamped at zero;
/// the correction is a start offset, never a negative position.
pub fn monitor_start(take_start: u64, align_samples: u64) -> u64 {
    take_start.saturating_sub(align_samples)
}

/// The metronome click a take asked for: its tempo, the beats in a bar, and the
/// page's trim. It is built into the monitor output only; a take's WAV never
/// sees it.
///
/// The wire shape is `{"bpm":120,"beats_per_bar":4,"gain":0.5}`. A malformed
/// value is refused before any file or thread exists, exactly as a malformed
/// monitor is.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ClickSpec {
    /// Beats per minute, a finite number greater than zero.
    pub bpm: f64,
    /// Beats in one bar; the first beat of each bar is accented.
    pub beats_per_bar: u32,
    /// The monitor bus trim, 0..=1.
    pub gain: f32,
}

impl ClickSpec {
    /// The gain used when the page sends no trim.
    pub const DEFAULT_GAIN: f32 = 0.5;

    /// Validate one click request. The engine refuses anything a later block
    /// loop could not represent, rather than clamping it into a different
    /// tempo than the person asked for.
    pub fn new(bpm: f64, beats_per_bar: u32, gain: f32) -> Result<Self, String> {
        if !bpm.is_finite() || bpm <= 0.0 {
            return Err("click \"bpm\" must be a finite number greater than zero".to_string());
        }
        if !(1..=32).contains(&beats_per_bar) {
            return Err("click \"beats_per_bar\" must be a whole number from 1 to 32".to_string());
        }
        if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
            return Err("click \"gain\" must be a finite number from 0 to 1".to_string());
        }
        Ok(ClickSpec {
            bpm,
            beats_per_bar,
            gain,
        })
    }
}

/// How long one click sounds. Short enough that a fast tempo still has silence
/// between beats, long enough to be a tone rather than a sample step.
const CLICK_SECONDS: f64 = 0.020;
/// The regular beat, and the first beat of a bar. The accent is both higher and
/// louder, so it reads as an accent on any speaker.
const CLICK_HZ: f32 = 900.0;
const CLICK_ACCENT_HZ: f32 = 1100.0;
const CLICK_LEVEL: f32 = 0.72;

/// The click, ready for the block loop. Every buffer is built in `prepare`, so
/// `render` only adds samples.
struct ClickState {
    /// One click tone per buffer, mono, zero at both ends.
    beat: Vec<f32>,
    accent: Vec<f32>,
    gain: f32,
    /// Frames between onsets, rounded from the tempo at the device rate.
    beat_frames: f64,
    beats_per_bar: u64,
    /// The prepared block size, so `render` can validate a caller's block.
    period: usize,
    /// The output frame (from the playback's first frame) of the next onset.
    next_beat: u64,
    /// How many beats have started, which decides the accent.
    beat_index: u64,
    /// Samples already played of the current tone; past its end is silence.
    tone_offset: usize,
    /// Whether the tone currently sounding is the bar's accent.
    accenting: bool,
}

impl ClickState {
    fn build(spec: ClickSpec, rate: u32, period: usize) -> Self {
        let length = ((rate as f64 * CLICK_SECONDS).round() as usize).max(2);
        let beat = click_tone(length, rate, CLICK_HZ, CLICK_LEVEL);
        let accent = click_tone(length, rate, CLICK_ACCENT_HZ, 1.0);
        // At least one frame between beats, even for an absurd tempo, so the
        // grid advances instead of firing the same onset forever.
        let beat_frames = (rate as f64 * 60.0 / spec.bpm).max(1.0);
        let tone_offset = beat.len();
        ClickState {
            beat,
            accent,
            gain: spec.gain,
            beat_frames,
            beats_per_bar: u64::from(spec.beats_per_bar),
            period,
            next_beat: 0,
            beat_index: 0,
            tone_offset,
            accenting: true,
        }
    }

    /// Add this block's clicks to `out`, starting at the playback's frame
    /// `start`. The first onset is frame 0 of the playback, which is
    /// `monitor_at`: the click receives the same start correction as the
    /// monitor files, so the performer's captured playing lands on the click
    /// grid even when `align_samples` starts the monitor early.
    fn render_into(&mut self, out: &mut [f32], start: u64) {
        let frames = out.len() / 2;
        for frame in 0..frames {
            let at = start + frame as u64;
            if at >= self.next_beat {
                self.tone_offset = 0;
                self.accenting = self.beat_index % self.beats_per_bar == 0;
                self.beat_index += 1;
                let next = (self.beat_index as f64 * self.beat_frames).round() as u64;
                // A tempo so fast that two onsets round to one frame must still
                // move the grid forward.
                self.next_beat = next.max(at + 1);
            }
            if self.tone_offset < self.beat.len() {
                let sample = if self.accenting {
                    self.accent[self.tone_offset]
                } else {
                    self.beat[self.tone_offset]
                } * self.gain;
                out[frame * 2] += sample;
                out[frame * 2 + 1] += sample;
                self.tone_offset += 1;
            }
        }
    }
}

/// One click tone: a sine carrier under a half-sine envelope, so it starts and
/// ends at exactly zero and has no DC or hard edge.
fn click_tone(length: usize, rate: u32, hz: f32, level: f32) -> Vec<f32> {
    let mut samples = Vec::with_capacity(length);
    let last = (length - 1) as f32;
    for index in 0..length {
        let t = index as f32 / rate as f32;
        let carrier = (2.0 * std::f32::consts::PI * hz * t).sin();
        let envelope = (std::f32::consts::PI * index as f32 / last).sin();
        samples.push(carrier * envelope * level);
    }
    samples
}

/// A running playback: the sources, their strips, and where on the shared
/// timeline the next block starts.
pub struct Playback {
    tracks: Vec<PlayTrack>,
    mixer: Mixer,
    rate: u32,
    /// Frames skipped at the start of every file.
    start_at: u64,
    /// Frames this playback renders, after `start_at` and any `--seconds` cap.
    total_frames: u64,
    /// Frames already rendered.
    position: u64,
    /// One mono block per track, reused by every [`Playback::render`].
    voices: Vec<Vec<f32>>,
    /// The take's live input, when this playback is also monitoring it.
    live: Option<LiveInput>,
    /// The machine's ordinary audio, added to the monitor output only. It is
    /// never part of a take: the capture loop writes the take from its own
    /// [`Mixer`], not from this playback.
    system: Option<SystemInput>,
    /// The take's metronome click, built from `click_spec` in `prepare` and
    /// added to the monitor output after the master chain.
    click: Option<ClickState>,
    /// The page's click request, kept until `prepare` knows the device rate.
    click_spec: Option<ClickSpec>,
}

/// The monitoring ring's read side and the gain the socket can move mid-take.
struct LiveInput {
    consumer: Consumer,
    /// `f32` bits of the live trim, clamped to `0..=4` by the control path.
    gain: Arc<AtomicU32>,
    /// One stereo block, popped and trimmed at the top of a render.
    block: Vec<f32>,
}

/// The machine's own mix, captured from a virtual sink's monitor. The monitor
/// output only; the take's WAV never sees it.
struct SystemInput {
    consumer: Consumer,
    /// One stereo block, popped at the top of a render.
    block: Vec<f32>,
}

/// Validate the file set without building strips, and return its rate and its
/// longest file in frames.
///
/// A strip chain is not `Send` (an insert is built for the thread that runs
/// it), so a server builds the strips on the playback thread. This check is
/// the control thread's half: it refuses an empty set or mixed rates, and
/// gives the caller the rate to probe the device and the length to report
/// before any worker exists.
pub fn check_tracks(tracks: &[PlayTrack]) -> Result<(u32, u64), String> {
    let Some(first) = tracks.first() else {
        return Err("playback needs at least one file".to_string());
    };
    let rate = first.rate;
    for track in tracks {
        if track.rate != rate {
            return Err(format!(
                "{} is {} Hz and {} is {} Hz; every file in one playback must share a sample rate",
                first.path, rate, track.path, track.rate
            ));
        }
    }
    let longest = tracks
        .iter()
        .map(|track| track.samples.len() as u64)
        .max()
        .unwrap_or(0);
    Ok((rate, longest))
}

impl Playback {
    /// Build the strips. Refuses an empty set and files that do not share a
    /// sample rate: resampling here would silently change the material, and
    /// the takes this engine records are all one rate.
    pub fn new(tracks: Vec<PlayTrack>, start_at: u64) -> Result<Self, String> {
        Self::with_queue(tracks, start_at, Arc::new(ParamQueue::new()))
    }

    /// The same, with a control queue the socket already holds, so a `param`
    /// can move a monitor strip while it plays. A plain playback gets a queue
    /// nobody writes to.
    pub fn with_queue(
        tracks: Vec<PlayTrack>,
        start_at: u64,
        params: Arc<ParamQueue>,
    ) -> Result<Self, String> {
        let (rate, longest) = check_tracks(&tracks)?;
        let total_frames = longest.saturating_sub(start_at);

        let inputs: Vec<usize> = (0..tracks.len()).collect();
        let labels: Vec<String> = (1..=tracks.len()).map(|file| format!("f{file}")).collect();
        let label_refs: Vec<&str> = labels.iter().map(|label| label.as_str()).collect();
        let mut mixer = Mixer::with_queue(&inputs, &label_refs, params);
        for (index, track) in tracks.iter().enumerate() {
            let mut channel = Channel::new(track.gain, track.pan.clamp(-1.0, 1.0));
            for kind in &track.inserts {
                channel.push(kind.build());
            }
            mixer.tracks_mut()[index].channel = channel;
        }

        Ok(Playback {
            tracks,
            mixer,
            rate,
            start_at,
            total_frames,
            position: 0,
            voices: Vec::new(),
            live: None,
            system: None,
            click: None,
            click_spec: None,
        })
    }

    /// A monitor with no files: only the take's live input, for `frames`
    /// frames. It has no file rate to insist on, so `prepare` accepts whatever
    /// rate the device grants.
    pub fn live(
        rate: u32,
        frames: u64,
        consumer: Consumer,
        gain: Arc<AtomicU32>,
    ) -> Self {
        Playback {
            tracks: Vec::new(),
            mixer: Mixer::new(&[], &[]),
            rate,
            start_at: 0,
            total_frames: frames,
            position: 0,
            voices: Vec::new(),
            live: Some(LiveInput {
                consumer,
                gain,
                block: Vec::new(),
            }),
            system: None,
            click: None,
            click_spec: None,
        }
    }

    /// A monitor with neither files nor a live input: just the take's click for
    /// `frames` frames. Like [`Playback::live`] it has no file rate to insist on,
    /// so `prepare` accepts whatever rate the device grants.
    pub fn click_only(rate: u32, frames: u64) -> Self {
        Playback {
            tracks: Vec::new(),
            mixer: Mixer::new(&[], &[]),
            rate,
            start_at: 0,
            total_frames: frames,
            position: 0,
            voices: Vec::new(),
            live: None,
            system: None,
            click: None,
            click_spec: None,
        }
    }

    /// Attach the take's live input to an existing playback, so the monitor
    /// files and the live input share one master chain.
    pub fn with_live_input(mut self, consumer: Consumer, gain: Arc<AtomicU32>) -> Self {
        self.live = Some(LiveInput {
            consumer,
            gain,
            block: Vec::new(),
        });
        self
    }

    /// Attach the machine's own mix to the monitor output. It is added after
    /// the master chain at unity, exactly like the patchbay's `device`
    /// fallback, and never reaches a take's capture or disk writer.
    pub fn with_system_input(mut self, consumer: Consumer) -> Self {
        self.system = Some(SystemInput {
            consumer,
            block: Vec::new(),
        });
        self
    }

    /// Attach the take's metronome click. The buffers are built in `prepare`,
    /// once the device rate is known; until then this is just the request.
    pub fn with_click(mut self, spec: ClickSpec) -> Self {
        self.click_spec = Some(spec);
        self
    }

    /// Set the playback's length. A live-only monitor uses the take's frames;
    /// a file monitor with live input runs for the take too, so the live path
    /// is not cut off when the shortest file ends.
    pub fn set_length(&mut self, frames: u64) {
        self.total_frames = frames;
    }

    /// The files' rate. `prepare` takes it as an argument so a device that
    /// grants another rate is refused rather than played at the wrong pitch.
    pub fn rate(&self) -> u32 {
        self.rate
    }

    /// The frames the files cover together, after `start_at`.
    pub fn total_frames(&self) -> u64 {
        self.total_frames
    }

    /// Frames left to render.
    pub fn remaining(&self) -> u64 {
        self.total_frames - self.position
    }

    /// Frames rendered so far.
    pub fn position(&self) -> u64 {
        self.position
    }

    /// Cap the playback at `frames`, for `--seconds`. The longest file still
    /// decides when a cap is longer than the material.
    pub fn limit(&mut self, frames: u64) {
        self.total_frames = self.total_frames.min(frames);
    }

    /// Size every strip and every scratch buffer. This is the only place
    /// playback allocates; `render` then only reads and writes memory it owns.
    pub fn prepare(&mut self, rate: u32, period: usize) -> Result<(), String> {
        if period == 0 {
            return Err("a playback block must hold at least one frame".to_string());
        }
        // A monitor with no files (live input or click only) has no file whose
        // pitch could be wrong, so it takes the device's rate; with files the
        // rate must still match.
        let no_files = self.tracks.is_empty();
        if no_files {
            self.rate = rate;
        } else if rate != self.rate {
            return Err(format!(
                "the device runs at {rate} Hz but the files are {} Hz; the takes would play at the wrong pitch",
                self.rate
            ));
        }
        self.mixer.prepare(rate, period);
        self.voices = vec![vec![0.0; period]; self.tracks.len()];
        if let Some(live) = &mut self.live {
            live.block = vec![0.0; period * 2];
        }
        if let Some(system) = &mut self.system {
            system.block = vec![0.0; period * 2];
        }
        // The click's tone buffers are built here, before the device opens, so
        // the block loop only adds samples.
        self.click = self
            .click_spec
            .map(|spec| ClickState::build(spec, rate, period));
        Ok(())
    }

    /// Add the master inserts a take armed, in the contract's order. Call it
    /// before [`prepare`](Playback::prepare): the rack is fixed for the life of
    /// the playback, and a bypass moves an insert in place without rebuilding
    /// the bus (the same rule a track's pedalboard follows).
    pub fn arm_master(&mut self, kinds: &[InsertKind]) {
        for kind in kinds {
            self.mixer.push_master(*kind);
        }
    }

    /// Bypass or restore an armed master insert. False means the rack does not
    /// hold that effect: an effect switched on after the take started has no
    /// slot in this playback, and only the next take can arm it.
    pub fn bypass_master(&mut self, prefix: &str, bypassed: bool) -> bool {
        self.mixer.bypass_master(prefix, bypassed)
    }

    /// Move one armed master knob, in the control path's units.
    pub fn set_master(&mut self, name: &str, value: f32) -> bool {
        self.mixer.set_master(name, value)
    }

    /// Render the next stereo block into `out`, which holds whole interleaved
    /// frames and is overwritten.
    ///
    /// Every track is trimmed, inserted and panned into its own stereo block,
    /// then the blocks are summed in file order; silence past the end of a
    /// shorter file is what makes files of different lengths share a timeline.
    pub fn render(&mut self, out: &mut [f32]) -> Result<(), String> {
        if out.len() % 2 != 0 {
            return Err(format!(
                "the playback block must hold whole stereo frames, found {} samples",
                out.len()
            ));
        }
        let frames = out.len() / 2;
        let prepared = self
            .voices
            .first()
            .map(Vec::len)
            .or_else(|| self.live.as_ref().map(|live| live.block.len() / 2))
            .or_else(|| self.click.as_ref().map(|click| click.period))
            .unwrap_or(0);
        if frames > prepared {
            return Err(format!(
                "a {frames}-frame block is longer than the prepared {prepared} frames"
            ));
        }
        if frames as u64 > self.remaining() {
            return Err(format!(
                "a {frames}-frame block is longer than the {} frames left",
                self.remaining()
            ));
        }

        let base = self.start_at + self.position;
        let position = self.position;
        for index in 0..self.tracks.len() {
            let samples = &self.tracks[index].samples;
            let voice = &mut self.voices[index][..frames];
            for (offset, sample) in voice.iter_mut().enumerate() {
                let at = base + offset as u64;
                *sample = if at < samples.len() as u64 {
                    samples[at as usize]
                } else {
                    // A live monitor can outlast its files: past a file's end
                    // its voice is silence, not a held sample.
                    0.0
                };
            }
        }

        // Pop the live ring once per render, trim it, and hand it to the same
        // master bus as the files. A short ring is already zero-filled by the
        // consumer, and a gain of zero is true silence.
        {
            let Playback {
                mixer,
                voices,
                live,
                system,
                click,
                ..
            } = self;
            let live_block = match live.as_mut() {
                Some(live) => {
                    let samples = frames * 2;
                    live.consumer.pop(&mut live.block[..samples]);
                    let gain = f32::from_bits(live.gain.load(Ordering::Acquire));
                    if gain == 0.0 {
                        live.block[..samples].fill(0.0);
                    } else if gain != 1.0 {
                        for sample in &mut live.block[..samples] {
                            *sample *= gain;
                        }
                    }
                    Some(&live.block[..samples])
                }
                None => None,
            };
            // `mix_with_live` takes the voices by index and the live block by
            // slice: no temporary slice of references is built on the audio
            // thread.
            mixer
                .mix_with_live(out, |index| &voices[index][..frames], live_block)
                .map_err(|error| format!("playback: {error}"))?;

            // The click is monitor-only and sits after the master chain, so a
            // limiter on the master cannot squash it; it is never in the
            // capture path. Its origin is frame 0 of this playback, which is
            // `monitor_at`: an alignment that started the monitor early still
            // hears the first click on the take's start.
            if let Some(click) = click.as_mut() {
                click.render_into(out, position);
            }

            // The machine's own mix is monitor-only, added after the master
            // chain at unity. A short ring is silence for the part it misses.
            if let Some(system) = system.as_mut() {
                let samples = frames * 2;
                system.consumer.pop(&mut system.block[..samples]);
                for (target, sample) in out[..samples].iter_mut().zip(&system.block[..samples]) {
                    *target += sample;
                }
            }
        }
        self.position += frames as u64;
        Ok(())
    }
}

/// What a device loop asks for: size once against the shape it granted, then
/// one stereo block at a time. [`Playback`] is the implementation the engine
/// ships; the trait keeps `alsa_device` free of the mixer's types.
pub trait RenderSource {
    /// Size against the rate and period the device granted. Runs once, before
    /// the first block.
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String>;
    /// Fill `out` with whole interleaved stereo frames. The loop slices this to
    /// the frames that remain, so the last block may be short.
    fn block(&mut self, out: &mut [f32]) -> Result<(), String>;
}

impl RenderSource for Playback {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        self.prepare(rate, period)
    }

    fn block(&mut self, out: &mut [f32]) -> Result<(), String> {
        self.render(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(name: &str, level: f32, gain: f32, pan: f32) -> PlayTrack {
        PlayTrack {
            path: name.to_string(),
            rate: 48_000,
            samples: vec![level; 4],
            gain,
            pan,
            inserts: Vec::new(),
        }
    }

    #[test]
    fn two_buffers_with_their_own_strips_sum_into_the_expected_samples() {
        // A is a constant 1.0 at unity, hard left: all of it reaches the left
        // speaker. B is a constant 0.5 trimmed to 0.5 and hard right: 0.25 in
        // the right speaker. Nothing crosses over.
        let mut playback = Playback::new(
            vec![track("a.wav", 1.0, 1.0, -1.0), track("b.wav", 0.5, 0.5, 1.0)],
            0,
        )
        .expect("playback");
        playback.prepare(48_000, 4).expect("prepare");

        let mut out = vec![0.0f32; 8];
        playback.render(&mut out).expect("render");
        for frame in out.chunks_exact(2) {
            assert!((frame[0] - 1.0).abs() < 1e-6, "left: {out:?}");
            assert!((frame[1] - 0.25).abs() < 1e-6, "right: {out:?}");
        }
        assert_eq!(playback.remaining(), 0);
    }

    #[test]
    fn two_centre_strips_sum_with_equal_power() {
        // Each centre strip contributes level/√2 to each side, and the two
        // contributions add in the shared bus.
        let mut playback = Playback::new(
            vec![track("a.wav", 1.0, 1.0, 0.0), track("b.wav", 0.5, 1.0, 0.0)],
            0,
        )
        .expect("playback");
        playback.prepare(48_000, 4).expect("prepare");
        let mut out = vec![0.0f32; 8];
        playback.render(&mut out).expect("render");
        let expected = (1.0 + 0.5) * std::f32::consts::FRAC_1_SQRT_2;
        for sample in &out {
            assert!((sample - expected).abs() < 1e-6, "{out:?}");
        }
    }

    #[test]
    fn a_shorter_file_is_silent_after_its_end() {
        let mut short = track("short.wav", 1.0, 1.0, -1.0);
        short.samples = vec![1.0, 1.0];
        // A silent four-frame file keeps the timeline going past the short one.
        let mut long = track("long.wav", 0.0, 1.0, 1.0);
        long.samples = vec![0.0; 4];
        let mut playback = Playback::new(vec![short, long], 0).expect("playback");
        assert_eq!(playback.total_frames(), 4);
        playback.prepare(48_000, 4).expect("prepare");
        let mut out = vec![0.0f32; 8];
        playback.render(&mut out).expect("render");
        // The short file's two frames are heard, then silence: not the last
        // sample held forever.
        assert_eq!(&out[0..2], &[1.0, 0.0]);
        assert_eq!(&out[2..4], &[1.0, 0.0]);
        assert_eq!(&out[4..6], &[0.0, 0.0]);
        assert_eq!(&out[6..8], &[0.0, 0.0]);
    }

    #[test]
    fn start_at_skips_the_same_frames_in_every_file() {
        let mut first = track("a.wav", 1.0, 1.0, -1.0);
        first.samples = vec![0.0, 0.0, 0.25, 0.25];
        let mut second = track("b.wav", 2.0, 1.0, -1.0);
        second.samples = vec![0.0, 0.0, 0.5, 0.5];
        let mut playback = Playback::new(vec![first, second], 2).expect("playback");
        assert_eq!(playback.total_frames(), 2);
        playback.prepare(48_000, 2).expect("prepare");
        let mut out = vec![0.0f32; 4];
        playback.render(&mut out).expect("render");
        assert!((out[0] - 0.75).abs() < 1e-6, "{out:?}");
        assert!((out[2] - 0.75).abs() < 1e-6, "{out:?}");
    }

    #[test]
    fn files_of_different_rates_are_refused_by_name() {
        let mut second = track("b.wav", 1.0, 1.0, 0.0);
        second.rate = 44_100;
        let error = Playback::new(vec![track("a.wav", 1.0, 1.0, 0.0), second], 0)
            .err()
            .expect("mixed rates must be refused");
        assert!(error.contains("a.wav"), "{error}");
        assert!(error.contains("b.wav"), "{error}");
        assert!(error.contains("44100"), "{error}");
    }

    #[test]
    fn a_monitor_starts_before_the_take_by_the_measured_offset() {
        // File frame 5 is the first loud one. A take stamped at frame 10 with
        // an 8-sample offset starts the monitor at frame 2, so the first
        // rendered block begins on file frame 2 (silent) and reaches the loud
        // frame 3 frames later.
        let mut source = track("a.wav", 0.0, 1.0, -1.0);
        source.samples = vec![0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0];
        let start = monitor_start(10, 8);
        assert_eq!(start, 2);
        let mut playback = Playback::new(vec![source], start).expect("playback");
        playback.prepare(48_000, 4).expect("prepare");
        let mut out = vec![0.0f32; 8];
        playback.render(&mut out).expect("render");
        // Frames 2, 3 and 4 are silent; frame 5 is the loud one, so the third
        // rendered frame is the first audible sample.
        assert_eq!(&out[0..6], &[0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
        assert!((out[6] - 1.0).abs() < 1e-6, "{out:?}");
        assert!(out[7].abs() < 1e-6, "hard left leaves the right silent: {out:?}");
    }

    #[test]
    fn an_alignment_never_starts_before_sample_zero() {
        assert_eq!(monitor_start(0, 96), 0);
        assert_eq!(monitor_start(40, 96), 0);
        assert_eq!(monitor_start(96, 96), 0);
        assert_eq!(monitor_start(100, 96), 4);
    }

    #[test]
    fn two_monitor_files_run_their_own_gain_and_pan() {
        // A at unity hard left, B at half trim hard right: the same sum the
        // recording path makes, because both use one `Channel` per file.
        let mut a = track("a.wav", 1.0, 1.0, -1.0);
        a.samples = vec![1.0; 4];
        let mut b = track("b.wav", 0.5, 0.5, 1.0);
        b.samples = vec![0.5; 4];
        let mut playback = Playback::new(vec![a, b], 0).expect("playback");
        playback.prepare(48_000, 4).expect("prepare");
        let mut out = vec![0.0f32; 8];
        playback.render(&mut out).expect("render");
        for frame in out.chunks_exact(2) {
            assert!((frame[0] - 1.0).abs() < 1e-6, "left: {out:?}");
            assert!((frame[1] - 0.25).abs() < 1e-6, "right: {out:?}");
        }
    }

    #[test]
    fn a_monitor_spec_names_its_strip() {
        use crate::effect::InsertKind;
        let spec = MonitorSpec::wire("/a.wav");
        assert_eq!(spec.gain, 1.0);
        assert_eq!(spec.pan, 0.0);
        assert!(spec.inserts.is_empty());
        assert_eq!(spec.insert_list(), "");
        let spec = MonitorSpec {
            path: "/b.wav".to_string(),
            gain: 0.8,
            pan: -0.2,
            inserts: vec![InsertKind::Tone, InsertKind::Delay],
        };
        assert_eq!(spec.insert_list(), "tone,delay");
    }

    #[test]
    fn a_master_limiter_runs_over_the_monitored_bus() {
        let mut source = track("a.wav", 0.8, 1.0, 0.0);
        source.samples = vec![0.8; 4096 * 4];
        let mut playback = Playback::new(vec![source], 0).expect("playback");
        playback.arm_master(&[InsertKind::Limiter]);
        assert!(playback.set_master("master_limiter.ceiling", -6.0));
        playback.prepare(48_000, 4096).expect("prepare");

        let mut out = vec![0.0f32; 8192];
        for _ in 0..4 {
            playback.render(&mut out).expect("render");
        }
        let ceiling = 10f32.powf(-6.0 / 20.0);
        assert!(
            out.iter().all(|sample| sample.abs() <= ceiling + 2e-2),
            "the master limiter did not catch the monitored bus: {out:?}"
        );
    }

    #[test]
    fn a_bypassed_master_insert_is_transparent_on_the_monitor() {
        let source = || {
            let mut source = track("a.wav", 0.8, 1.0, 0.0);
            source.samples = vec![0.8; 64];
            source
        };

        let mut plain = Playback::new(vec![source()], 0).expect("playback");
        plain.prepare(48_000, 64).expect("prepare");
        let mut expected = vec![0.0f32; 128];
        plain.render(&mut expected).expect("render");

        let mut playback = Playback::new(vec![source()], 0).expect("playback");
        playback.arm_master(&[InsertKind::Limiter]);
        assert!(playback.set_master("master_limiter.ceiling", -6.0));
        assert!(playback.bypass_master("master_limiter", true));
        playback.prepare(48_000, 64).expect("prepare");
        let mut out = vec![0.0f32; 128];
        playback.render(&mut out).expect("render");
        assert_eq!(out, expected, "a bypassed master insert was not transparent");

        assert!(playback.bypass_master("master_limiter", false), "armed slot");
        assert!(!playback.bypass_master("master_comp", true), "unarmed slot");
    }

    #[test]
    fn a_block_longer_than_the_material_is_refused() {
        let mut playback = Playback::new(vec![track("a.wav", 1.0, 1.0, 0.0)], 0).expect("playback");
        playback.prepare(48_000, 8).expect("prepare");
        let mut out = vec![0.0f32; 10];
        assert!(playback.render(&mut out).is_err());
        assert_eq!(playback.position(), 0);
    }

    fn live_gain(value: f32) -> Arc<AtomicU32> {
        Arc::new(AtomicU32::new(value.to_bits()))
    }

    #[test]
    fn a_live_only_monitor_plays_the_ring_for_its_length() {
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        let input = [0.5f32, -0.5, 0.25, -0.25];
        producer.push(&input);
        let mut playback = Playback::live(48_000, 2, consumer, live_gain(1.0));
        // No file rate to protect: the device may grant another one.
        playback.prepare(44_100, 4).expect("a live-only playback accepts the device rate");
        let mut out = vec![0.0f32; 4];
        playback.render(&mut out).expect("render");
        assert_eq!(out, input);
        assert_eq!(playback.remaining(), 0);
    }

    #[test]
    fn a_zero_live_gain_is_silence() {
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        producer.push(&[1.0f32; 8]);
        let mut playback = Playback::live(48_000, 4, consumer, live_gain(0.0));
        playback.prepare(48_000, 4).expect("prepare");
        let mut out = vec![9.0f32; 8];
        playback.render(&mut out).expect("render");
        assert!(out.iter().all(|sample| *sample == 0.0), "{out:?}");
    }

    #[test]
    fn a_live_input_runs_past_the_end_of_its_files() {
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        // Four frames of live input at a quarter, while the file has two.
        producer.push(&[0.25f32; 8]);
        let mut source = track("a.wav", 0.5, 1.0, -1.0);
        source.samples = vec![0.5; 2];
        let mut playback = Playback::new(vec![source], 0)
            .expect("playback")
            .with_live_input(consumer, live_gain(1.0));
        playback.set_length(4);
        playback.prepare(48_000, 4).expect("prepare");
        let mut out = vec![0.0f32; 8];
        playback.render(&mut out).expect("render");
        // The file is hard left, so it adds nothing to the right; the live
        // input is centred. Past the file's end only the live input remains.
        assert!((out[0] - 0.75).abs() < 1e-6, "{out:?}");
        assert!((out[1] - 0.25).abs() < 1e-6, "{out:?}");
        assert!((out[4] - 0.25).abs() < 1e-6, "{out:?}");
        assert!((out[5] - 0.25).abs() < 1e-6, "{out:?}");
    }

    #[test]
    fn the_monitor_carries_the_system_ring_but_the_take_mix_does_not() {
        // The take path is the capture's `Mixer`; the monitor path is this
        // playback. The same live block feeds both, and only the monitor sees
        // the machine's own mix.
        let (live_producer, live_consumer) = crate::monbus::MonitorBus::new(4096);
        live_producer.push(&[0.5f32; 8]);
        let (system_producer, system_consumer) = crate::monbus::MonitorBus::new(4096);
        system_producer.push(&[0.25f32; 8]);

        let mut playback = Playback::live(48_000, 4, live_consumer, live_gain(1.0))
            .with_system_input(system_consumer);
        playback.prepare(48_000, 4).expect("prepare");
        let mut out = vec![0.0f32; 8];
        playback.render(&mut out).expect("render");
        for sample in &out {
            assert!((sample - 0.75).abs() < 1e-6, "monitor: {out:?}");
        }

        // What the disk writer receives: the same capture block through the
        // take's strip, with no ring in the path at all.
        let mut take = Mixer::new(&[0], &["ch1"]);
        take.prepare(48_000, 4);
        let mut recorded = vec![0.0f32; 8];
        take.process(0, &[0.5f32; 4], &mut recorded)
            .expect("take block");
        for sample in &recorded {
            // The take's centre strip is equal-power, so the live input alone
            // yields 0.5 / sqrt(2); the system ring is not in this path.
            let expected = 0.5 / 2f32.sqrt();
            assert!((sample - expected).abs() < 1e-6, "take: {recorded:?}");
        }
    }

    #[test]
    fn a_monitor_without_a_system_ring_is_unchanged() {
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        producer.push(&[0.5f32; 8]);
        let mut playback = Playback::live(48_000, 4, consumer, live_gain(1.0));
        playback.prepare(48_000, 4).expect("prepare");
        let mut out = vec![0.0f32; 8];
        playback.render(&mut out).expect("render");
        for sample in &out {
            assert!((sample - 0.5).abs() < 1e-6, "{out:?}");
        }
    }

    fn click_spec(bpm: f64, beats_per_bar: u32, gain: f32) -> ClickSpec {
        ClickSpec::new(bpm, beats_per_bar, gain).expect("click spec")
    }

    /// A click-only playback at 8 kHz: 120 bpm is exactly 4000 frames per beat,
    /// and 900/1100 Hz stay under Nyquist. One tone is 160 frames.
    fn click_playback(frames: u64) -> Playback {
        Playback::click_only(8_000, frames).with_click(click_spec(120.0, 4, 1.0))
    }

    fn peak(samples: &[f32]) -> f32 {
        samples.iter().fold(0.0f32, |high, sample| high.max(sample.abs()))
    }

    #[test]
    fn a_click_spec_refuses_values_the_block_loop_could_not_represent() {
        assert!(ClickSpec::new(0.0, 4, 0.5).is_err());
        assert!(ClickSpec::new(-120.0, 4, 0.5).is_err());
        assert!(ClickSpec::new(f64::INFINITY, 4, 0.5).is_err());
        assert!(ClickSpec::new(120.0, 0, 0.5).is_err());
        assert!(ClickSpec::new(120.0, 33, 0.5).is_err());
        assert!(ClickSpec::new(120.0, 4, -0.1).is_err());
        assert!(ClickSpec::new(120.0, 4, 1.1).is_err());
        assert!(ClickSpec::new(120.0, 4, f32::NAN).is_err());
        assert_eq!(
            ClickSpec::new(120.0, 4, 0.0).expect("a muted click is legal"),
            click_spec(120.0, 4, 0.0)
        );
    }

    #[test]
    fn a_click_only_playback_clicks_on_every_beat_and_is_silent_between() {
        let mut playback = click_playback(12_000);
        playback.prepare(8_000, 4_000).expect("prepare");

        let mut first = vec![0.0f32; 8_000];
        playback.render(&mut first).expect("render");
        // The envelope starts at zero, so the very first sample is silent even
        // though the tone starts on frame 0.
        assert!(first[0].abs() < 1e-6 && first[1].abs() < 1e-6, "{:?}", &first[..8]);
        assert!(peak(&first[..320]) > 0.3, "no click on the first beat");
        // 160 frames of tone, then nothing until the next beat.
        assert!(
            first[320..].iter().all(|sample| sample.abs() < 1e-9),
            "the click is not silent between beats"
        );

        let mut second = vec![0.0f32; 8_000];
        playback.render(&mut second).expect("render");
        assert!(peak(&second[..320]) > 0.3, "no click on the second beat");
        assert!(second[320..].iter().all(|sample| sample.abs() < 1e-9));
    }

    #[test]
    fn the_first_beat_of_each_bar_is_accented() {
        let mut playback = click_playback(32_000);
        playback.prepare(8_000, 4_000).expect("prepare");
        let mut peaks = Vec::new();
        for _ in 0..8 {
            let mut block = vec![0.0f32; 8_000];
            playback.render(&mut block).expect("render");
            peaks.push(peak(&block[..320]));
        }
        assert!(peaks[0] > peaks[1] * 1.15, "the first beat is not accented: {peaks:?}");
        assert!(peaks[4] > peaks[1] * 1.15, "bar two lost its accent: {peaks:?}");
        for beat in [1, 2, 3, 5, 6, 7] {
            assert!(peaks[beat] < peaks[0] * 0.9, "beat {beat} is accented: {peaks:?}");
        }
    }

    #[test]
    fn a_click_only_playback_accepts_the_device_rate() {
        let mut playback = Playback::click_only(44_100, 100).with_click(click_spec(120.0, 4, 0.5));
        playback
            .prepare(48_000, 100)
            .expect("a click-only playback accepts the device rate");
        assert_eq!(playback.rate(), 48_000);
    }

    #[test]
    fn the_first_click_lands_on_the_monitor_start_not_the_file_start() {
        // The monitor starts two frames before the take's stamp for an
        // alignment; the click is anchored at frame 0 of the monitor, so it
        // shares the monitor's start correction rather than being shifted
        // again by `start_at`.
        let mut source = track("a.wav", 0.0, 1.0, 0.0);
        source.rate = 8_000;
        source.samples = vec![0.0; 4_000];
        let start = monitor_start(10, 8);
        assert_eq!(start, 2);
        let mut playback = Playback::new(vec![source], start)
            .expect("playback")
            .with_click(click_spec(120.0, 4, 1.0));
        playback.prepare(8_000, 4_000).expect("prepare");

        let mut out = vec![0.0f32; 3_998 * 2];
        playback.render(&mut out).expect("render");
        assert!(peak(&out[..320]) > 0.3, "the first click did not land on monitor_at");
    }

    #[test]
    fn a_click_does_not_change_a_track_except_by_adding_the_click() {
        let source = || {
            let mut source = track("a.wav", 0.3, 1.0, -1.0);
            source.rate = 8_000;
            source.samples = vec![0.3; 4_000];
            source
        };
        let spec = click_spec(120.0, 4, 1.0);

        let mut plain = Playback::new(vec![source()], 0).expect("playback");
        plain.prepare(8_000, 4_000).expect("prepare");
        let mut without = vec![0.0f32; 8_000];
        plain.render(&mut without).expect("render");

        let mut clicked = Playback::new(vec![source()], 0)
            .expect("playback")
            .with_click(spec);
        clicked.prepare(8_000, 4_000).expect("prepare");
        let mut with = vec![0.0f32; 8_000];
        clicked.render(&mut with).expect("render");

        let mut alone = click_playback(4_000);
        alone.prepare(8_000, 4_000).expect("prepare");
        let mut click = vec![0.0f32; 8_000];
        alone.render(&mut click).expect("render");

        for index in 0..8_000 {
            let added = with[index] - without[index];
            assert!(
                (added - click[index]).abs() < 1e-6,
                "sample {index}: the take changed by {added}, the click is {}",
                click[index]
            );
        }
    }
}
