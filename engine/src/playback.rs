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
//!
//! ## Channel sends (the Studio output cord)
//!
//! A clip or an app routing tap may name a Studio `channel` (1..=32), and the
//! plan may carry `sends` — one destination per source, no self edge and no
//! cycle. A channel's sources are summed after their own fader, inserts and
//! pan, which is the post-fader, post-pan stereo block a cord carries. When
//! channel `A` sends to channel `B`, that block is added to `B`'s input and
//! runs through `B`'s **fader and inserts, not its pan**, so the source's pan
//! image is preserved; if `B` also sends, its total (its own sources plus
//! everything sent to it) travels on to `B`'s destination. A channel with no
//! send sums into the master bus, and a clip or tap with no channel is summed
//! there directly, exactly as before sends existed. A destination channel's
//! fader and inserts are the ones its own sources carry; a channel named only
//! by a send is a unity wire with no inserts. The send graph is a function
//! (one destination per source), so it is evaluated once in topological order
//! per block and costs nothing for a channel no source or send names.
//!
//! The take's live monitor input and the click are deliberately outside this
//! graph: the live input joins the pre-master sum at its armed gain and is
//! never sent, and the click is added after the master rack. The browser routes
//! a Studio output cord into the destination's record path instead; this is the
//! engine's playback meaning of the same cord.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::Arc;

use jawn_drums::{Kit, Machine, Performance, Voice};
use jawn_synth::{Patch, Synth};

use crate::effect::{Channel, EffectChain, InsertKind};
use crate::graph::pan_coefficients;
use crate::mixer::{send_order, Mixer, ParamQueue};
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
#[derive(Debug)]
struct ClickState {
    /// One click tone per buffer, mono, zero at both ends.
    beat: Vec<f32>,
    accent: Vec<f32>,
    gain: f32,
    /// The device rate the tone buffers were built at, so a tempo change can
    /// recompute the frame grid without rebuilding the buffers.
    rate: u32,
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
    /// Absolute mode: onsets come from the absolute output frame and the
    /// song's own beat grid (beat 0 at position 0), not from a counter that
    /// restarts at the transport's start.
    absolute: bool,
    /// The absolute output frame in absolute mode.
    position: u64,
    /// The loop's absolute frame bounds; equal bounds mean no loop.
    loop_start: u64,
    loop_end: u64,
    /// The last absolute beat that sounded. A beat crosses from a frame's own
    /// grid index to the next one exactly when its onset arrives.
    last_beat: i64,
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
            rate,
            beat_frames,
            beats_per_bar: u64::from(spec.beats_per_bar),
            period,
            next_beat: 0,
            beat_index: 0,
            tone_offset,
            accenting: true,
            absolute: false,
            position: 0,
            loop_start: 0,
            loop_end: 0,
            last_beat: 0,
        }
    }

    /// A click on the song's own grid, for the transport. `position` is the
    /// absolute frame the output starts at: the first onset is the next grid
    /// beat at or after it, accented when it is the first beat of an absolute
    /// bar. A loop wraps the position and re-reads the grid from the wrapped
    /// point, so a repeat stays musical instead of restarting a bar at an
    /// arbitrary place.
    fn build_absolute(
        spec: ClickSpec,
        rate: u32,
        period: usize,
        position: u64,
        loop_start: u64,
        loop_end: u64,
    ) -> Self {
        let mut click = Self::build(spec, rate, period);
        click.absolute = true;
        click.loop_start = loop_start;
        click.loop_end = loop_end;
        click.seek(position);
        click
    }

    /// Jump the absolute grid to `position`. A position exactly on a grid line
    /// sounds that beat at once; one between lines waits for the next, so a
    /// seek never clicks off the song's phase.
    fn seek(&mut self, position: u64) {
        self.position = position;
        let beat = (position as f64 / self.beat_frames).floor() as i64;
        let onset = (beat.max(0) as f64 * self.beat_frames).ceil() as u64;
        self.last_beat = if beat >= 0 && position == onset {
            beat - 1
        } else {
            beat
        };
        // A seek is a jump: a tone from the old place must not carry across it.
        self.tone_offset = self.beat.len();
    }

    /// Move the beat grid to a new tempo without rebuilding the tone buffers.
    /// The grid is re-anchored at the current absolute position, so the change
    /// takes effect on the next beat rather than shifting every earlier one.
    fn set_tempo(&mut self, bpm: f64) {
        let frames = (self.rate as f64 * 60.0 / bpm).max(1.0);
        if frames != self.beat_frames {
            self.beat_frames = frames;
            self.seek(self.position);
        }
    }

    fn set_beats_per_bar(&mut self, beats_per_bar: u32) {
        self.beats_per_bar = u64::from(beats_per_bar.max(1));
    }

    fn set_gain(&mut self, gain: f32) {
        self.gain = gain;
    }

    fn set_loop(&mut self, loop_start: u64, loop_end: u64) {
        self.loop_start = loop_start;
        self.loop_end = loop_end;
    }

    fn position(&self) -> u64 {
        self.position
    }

    /// Add this block's absolute-grid clicks to `out`. The position advances
    /// frame by frame, so a loop wrap is sample-accurate and the tone's own
    /// phase follows the wrapped position rather than a counter.
    fn render_absolute_into(&mut self, out: &mut [f32]) {
        let frames = out.len() / 2;
        for frame in 0..frames {
            let beat = (self.position as f64 / self.beat_frames).floor() as i64;
            if beat != self.last_beat {
                self.last_beat = beat;
                self.tone_offset = 0;
                self.accenting = beat.rem_euclid(self.beats_per_bar as i64) == 0;
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
            self.position += 1;
            if self.loop_end > self.loop_start && self.position >= self.loop_end {
                let length = self.loop_end - self.loop_start;
                let wrapped = self.loop_start + (self.position - self.loop_end) % length;
                self.seek(wrapped);
            }
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

/// A click a caller outside a playback can render itself: the patchbay's bus
/// take puts it on the patch's output, never on the bus it records. It is built
/// off the audio path and its `render_into` only adds pre-built samples, the
/// same way [`ClickState`] does for a take's monitor. Its clock starts at the
/// first block it renders, which is when the bus take attached.
#[derive(Debug)]
pub struct StandaloneClick {
    state: ClickState,
    /// Frames rendered since the clock started.
    start: u64,
}

impl StandaloneClick {
    pub fn new(spec: ClickSpec, rate: u32, period: usize) -> Self {
        StandaloneClick {
            state: ClickState::build(spec, rate, period),
            start: 0,
        }
    }

    /// Add this block's clicks to the stereo block `out`.
    pub fn render_into(&mut self, out: &mut [f32]) {
        let start = self.start;
        self.state.render_into(out, start);
        self.start = start.wrapping_add((out.len() / 2) as u64);
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

/// Decode a take WAV into the one mono timeline a transport clip renders.
///
/// A take is a source, not a strip output, so a stereo file is averaged rather
/// than summed. The whole decode is returned behind an [`Arc`], so the control
/// thread's cache can hand the same samples to every plan that names this file.
/// This is the only place that reads a take for the transport.
pub fn decode_take(path: &str) -> Result<(u32, Arc<[f32]>), String> {
    let audio = read_wav(path).map_err(|error| error.to_string())?;
    let samples: Vec<f32> = match audio.channels {
        1 => audio
            .samples
            .iter()
            .map(|sample| f32::from(*sample) / 32_768.0)
            .collect(),
        _ => audio
            .samples
            .chunks_exact(2)
            .map(|pair| (f32::from(pair[0]) + f32::from(pair[1])) / 2.0 / 32_768.0)
            .collect(),
    };
    Ok((audio.rate, Arc::from(samples)))
}

/// One recorded take placed on the transport timeline.
///
/// A browser take is a file on disk and a span on the song's timeline. The
/// engine reads the file once, at `start`, and renders it on the same device
/// clock as the metronome: `start` says where the clip begins, `offset` where
/// inside the file it begins, and `duration` how long it occupies the timeline.
/// A looping clip repeats every `duration` from `start`, which is how a drum
/// loop or a punched phrase stays on the grid across a wrap.
///
/// `start` is signed on purpose. A take recorded with a negative latency
/// correction starts before the timeline's zero, and the browser already places
/// it there; the engine must hear the part that falls at or past zero, not drop
/// the clip.
pub struct TransportClip {
    /// The path the report and diagnostics name.
    pub path: String,
    /// The file's rate; every clip in one transport must agree with the device.
    pub rate: u32,
    /// One mono sample per frame, averaged from the file. A take is a source,
    /// not a strip output, so a stereo file is averaged rather than summed.
    ///
    /// The samples are shared, not copied: a placement-only plan update moves
    /// the same megabytes rather than re-reading and re-decoding the file.
    pub samples: Arc<[f32]>,
    /// Timeline frame where the clip begins (may be negative).
    pub start: i64,
    /// Source frame the clip begins at when the timeline reaches `start`.
    pub offset: u64,
    /// Length on the timeline in frames; never zero after loading.
    pub duration: u64,
    /// Trim before the strip's inserts.
    pub gain: f32,
    /// -1 left ..= 1 right, after the inserts.
    pub pan: f32,
    /// Repeat every `duration` from `start` (a looping sample).
    pub looped: bool,
    /// Half-crossfade length in frames at each edge, matching the browser's
    /// clip gain ramps. Zero is a hard edge.
    pub fade_in: u64,
    pub fade_out: u64,
    /// The insert chain, in the order the caller gave it.
    pub inserts: Vec<InsertKind>,
    /// The Studio channel this take belongs to, 1..=32. Its post-fader,
    /// post-pan block follows that channel's output cord; `None` sums straight
    /// into the master bus, which is how every clip sounded before sends.
    pub channel: Option<usize>,
}

impl TransportClip {
    /// Decode `path` and place it. The reader names the file and what it found
    /// when it refuses a shape. `duration` of zero means the rest of the file.
    #[allow(clippy::too_many_arguments)]
    pub fn from_wav(
        path: impl Into<String>,
        start: i64,
        offset: u64,
        duration: u64,
        gain: f32,
        pan: f32,
        looped: bool,
        fade_in: u64,
        fade_out: u64,
        inserts: Vec<InsertKind>,
    ) -> Result<Self, String> {
        let path = path.into();
        let (rate, samples) = decode_take(&path)?;
        Self::from_samples(
            path, rate, samples, start, offset, duration, gain, pan, looped, fade_in, fade_out,
            inserts,
        )
    }

    /// The same, from samples the caller already decoded (the control thread's
    /// take cache). `duration` of zero means the rest of the file.
    #[allow(clippy::too_many_arguments)]
    pub fn from_samples(
        path: impl Into<String>,
        rate: u32,
        samples: Arc<[f32]>,
        start: i64,
        offset: u64,
        duration: u64,
        gain: f32,
        pan: f32,
        looped: bool,
        fade_in: u64,
        fade_out: u64,
        inserts: Vec<InsertKind>,
    ) -> Result<Self, String> {
        let path = path.into();
        let available = (samples.len() as u64).saturating_sub(offset);
        let duration = if duration == 0 {
            available
        } else {
            duration.min(available.max(1))
        };
        if duration == 0 {
            return Err(format!(
                "{path} has no frames after its start offset; a transport clip needs audio"
            ));
        }
        Ok(TransportClip {
            path,
            rate,
            samples,
            start,
            offset,
            duration,
            gain,
            pan,
            looped,
            fade_in,
            fade_out,
            inserts,
            channel: None,
        })
    }

    /// One source sample for a timeline position, or `None` when the clip is
    /// silent there. A looping clip repeats from its in-point; a one-shot clip
    /// is silent outside its span.
    fn source_at(&self, position: u64) -> Option<usize> {
        let position = position as i64;
        if !self.looped {
            if position < self.start {
                return None;
            }
            let into = (position - self.start) as u64;
            if into >= self.duration {
                return None;
            }
            return self.frame_at(self.offset + into);
        }
        if position < self.start {
            return None;
        }
        let into = ((position - self.start) as u64) % self.duration;
        self.frame_at(self.offset + into)
    }

    fn frame_at(&self, source: u64) -> Option<usize> {
        if source < self.samples.len() as u64 {
            Some(source as usize)
        } else {
            None
        }
    }

    /// The clip-edge gain at a timeline position, matching the browser's
    /// `studioTakeGain`: a fade in over `2 * fade_in` from `start - fade_in`,
    /// and a fade out over `2 * fade_out` to `end + fade_out`. A looping clip
    /// never fades out.
    fn edge_gain(&self, position: u64) -> f32 {
        let mut gain = 1.0f32;
        if self.fade_in > 0 {
            let position = position as i64;
            let begin = self.start - self.fade_in as i64;
            let span = (2 * self.fade_in) as f32;
            gain *= (((position - begin) as f32) / span).clamp(0.0, 1.0);
        }
        if !self.looped && self.fade_out > 0 {
            let end = self.start.saturating_add(self.duration as i64);
            let finish = end + self.fade_out as i64;
            let span = (2 * self.fade_out) as f32;
            gain *= (((finish - position as i64) as f32) / span).clamp(0.0, 1.0);
        }
        gain
    }
}

/// The transport's mutable controls, shared by the socket and the render
/// thread. Every field is an atomic: a seek, tempo change or loop change takes
/// effect at the next block without stopping the device or reallocating the
/// click, so the transport never opens a gap to move a knob.
///
/// Positions are absolute output frames at the device rate. The socket speaks
/// seconds and converts with [`TransportControl::rate`], which `prepared`
/// records from the device.
pub struct TransportControl {
    stop: AtomicBool,
    playing: AtomicBool,
    /// BPM as `f64` bits.
    bpm: AtomicU64,
    beats_per_bar: AtomicU32,
    /// The click trim as `f32` bits.
    gain: AtomicU32,
    loop_start: AtomicU64,
    loop_end: AtomicU64,
    /// The next seek target, paired with `seek_seq` so several writes in a row
    /// cannot be read half-applied.
    seek_frames: AtomicU64,
    seek_seq: AtomicU64,
    position: AtomicU64,
    rate: AtomicU32,
}

impl TransportControl {
    pub fn new(spec: ClickSpec, position: u64, loop_start: u64, loop_end: u64) -> Self {
        TransportControl {
            stop: AtomicBool::new(false),
            playing: AtomicBool::new(false),
            bpm: AtomicU64::new(spec.bpm.to_bits()),
            beats_per_bar: AtomicU32::new(spec.beats_per_bar),
            gain: AtomicU32::new(spec.gain.to_bits()),
            loop_start: AtomicU64::new(loop_start),
            loop_end: AtomicU64::new(loop_end),
            seek_frames: AtomicU64::new(position),
            seek_seq: AtomicU64::new(0),
            position: AtomicU64::new(position),
            rate: AtomicU32::new(48_000),
        }
    }

    fn spec(&self) -> ClickSpec {
        ClickSpec {
            bpm: f64::from_bits(self.bpm.load(Ordering::Acquire)),
            beats_per_bar: self.beats_per_bar.load(Ordering::Acquire),
            gain: f32::from_bits(self.gain.load(Ordering::Acquire)),
        }
    }

    pub fn bpm(&self) -> f64 {
        f64::from_bits(self.bpm.load(Ordering::Acquire))
    }

    pub fn beats_per_bar(&self) -> u32 {
        self.beats_per_bar.load(Ordering::Acquire)
    }

    pub fn gain(&self) -> f32 {
        f32::from_bits(self.gain.load(Ordering::Acquire))
    }

    pub fn loop_start(&self) -> u64 {
        self.loop_start.load(Ordering::Acquire)
    }

    pub fn loop_end(&self) -> u64 {
        self.loop_end.load(Ordering::Acquire)
    }

    pub fn position(&self) -> u64 {
        self.position.load(Ordering::Acquire)
    }

    pub fn rate(&self) -> u32 {
        self.rate.load(Ordering::Acquire).max(1)
    }

    /// Move the transport to `position` at the next block. The last request
    /// wins; the render thread sees a whole seek or none of it.
    ///
    /// A request that lands within 20 ms of where the transport already is is
    /// not a move: a tempo, loop or metronome knob sends the playhead it is
    /// already at, and honouring it would reset every strip's tail - and
    /// restart the drum chart - for no audible gain. A real seek is further.
    pub fn seek(&self, position: u64) {
        let slack = (self.rate() as u64 / 50).max(1);
        if position.abs_diff(self.position()) <= slack {
            return;
        }
        self.seek_frames.store(position, Ordering::Release);
        self.position.store(position, Ordering::Release);
        self.seek_seq.fetch_add(1, Ordering::AcqRel);
    }

    /// Retune in place. A running transport re-reads the grid at its current
    /// position; the device is never closed.
    pub fn set_tempo(&self, bpm: f64, beats_per_bar: u32, gain: f32) {
        self.bpm.store(bpm.to_bits(), Ordering::Release);
        self.beats_per_bar
            .store(beats_per_bar, Ordering::Release);
        self.gain.store(gain.to_bits(), Ordering::Release);
    }

    pub fn set_loop(&self, loop_start: u64, loop_end: u64) {
        self.loop_start.store(loop_start, Ordering::Release);
        self.loop_end.store(loop_end, Ordering::Release);
    }

    pub fn set_playing(&self, playing: bool) {
        self.playing.store(playing, Ordering::Release);
    }

    pub fn is_playing(&self) -> bool {
        self.playing.load(Ordering::Acquire)
    }

    pub fn request_stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }

    pub fn is_stopping(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }

    fn seek_seq(&self) -> u64 {
        self.seek_seq.load(Ordering::Acquire)
    }

    /// The seek target, kept apart from the live `position` the render thread
    /// publishes. The two must not share one word: a block that read its old
    /// position could overwrite a seek before applying it.
    fn seek_frames(&self) -> u64 {
        self.seek_frames.load(Ordering::Acquire)
    }

    fn bpm_bits(&self) -> u64 {
        self.bpm.load(Ordering::Acquire)
    }

    fn gain_bits(&self) -> u32 {
        self.gain.load(Ordering::Acquire)
    }

    fn set_rate(&self, rate: u32) {
        self.rate.store(rate.max(1), Ordering::Release);
    }

    fn store_position(&self, position: u64) {
        self.position.store(position, Ordering::Release);
    }
}

/// One routing tap on the pre-master app bus: the three facts a Studio
/// channel puts between an app and the mix — a fader gain, an equal-power pan
/// and an insert chain — plus the channel it belongs to.
///
/// A patched app follows its channel's OUT chain. The browser's one-output
/// model lets one app fan out to several channels, so the routing is a list:
/// each entry is one strip and the app is heard through every one of them,
/// summed. An empty list means the app is not patched into a channel and is
/// summed straight into the bus, exactly as the engine sounded before routing.
/// A tap that names a `channel` follows that channel's output cord; the same
/// channel number on several taps means one channel, and its fader and inserts
/// (as carried by those taps) shape whatever a send hands it.
#[derive(Clone, Debug, PartialEq)]
pub struct AppRoute {
    /// Fader gain, `0..=1` (the socket refuses anything outside that range).
    pub gain: f32,
    /// `-1.0` (hard left) ..= `1.0` (hard right), equal-power.
    pub pan: f32,
    /// The channel's inserts, in the order the page gave them.
    pub inserts: Vec<InsertKind>,
    /// The Studio channel this tap belongs to, 1..=32. `None` sums straight
    /// into the app bus with no cord to follow.
    pub channel: Option<usize>,
}

impl AppRoute {
    /// A wire: unity gain, centre pan, no inserts and no channel.
    pub fn wire() -> Self {
        AppRoute {
            gain: 1.0,
            pan: 0.0,
            inserts: Vec::new(),
            channel: None,
        }
    }
}

/// A sixteenth-note drum chart the transport plays through the native
/// [`jawn_drums::Machine`].
///
/// One row per step; a row holds a `0..=100` velocity per voice in
/// [`jawn_drums::Voice::index`] order. Step 0 sits at the frame the transport
/// was started (or seeked) at, and a transport loop restarts the chart at step
/// 0 when the position wraps to `loop_start`.
#[derive(Clone, Debug, PartialEq)]
pub struct DrumChart {
    /// The kit whose voices the machine renders.
    pub kit: Kit,
    /// The chart's length in sixteenth steps, `1..=MAX_STEPS`.
    pub length: usize,
    /// Repeat the chart after its last step; `false` plays it once.
    pub looped: bool,
    /// Exactly `length` rows; each row is one velocity per voice.
    pub steps: Vec<[u8; Voice::COUNT]>,
    /// Who is playing the chart, and how hard, or `None` for the grid exactly
    /// as written. A player moves each hit a few milliseconds and widens or
    /// narrows its velocity; it never changes which steps fire.
    pub performance: Option<Performance>,
    /// The channels this app is patched into, each rendered through its own
    /// strip on the pre-master app bus. Empty is the unpatched wire.
    pub routing: Vec<AppRoute>,
}

impl DrumChart {
    /// The most sixteenth steps one chart may carry, matching the crate's
    /// [`jawn_drums::Pattern`] limit.
    pub const MAX_STEPS: usize = 128;

    /// A chart, padded or cut to `length`. The socket validates the wire shape;
    /// this keeps the render thread's assumption (one row per step) true for
    /// every caller.
    pub fn new(kit: Kit, length: usize, looped: bool, mut steps: Vec<[u8; Voice::COUNT]>) -> Self {
        let length = length.clamp(1, Self::MAX_STEPS);
        steps.resize(length, [0; Voice::COUNT]);
        steps.truncate(length);
        DrumChart {
            kit,
            length,
            looped,
            steps,
            performance: None,
            routing: Vec::new(),
        }
    }

    /// Play the chart through a named player, in a style. A chart without one
    /// plays the grid exactly as written, which is how every song made before
    /// players existed still sounds.
    pub fn with_performance(mut self, performance: Performance) -> Self {
        self.performance = Some(performance);
        self
    }

    /// Attach the Studio channel strips this chart's kit is patched into. A
    /// chart built without one plays through the unpatched wire.
    pub fn with_routing(mut self, routing: Vec<AppRoute>) -> Self {
        self.routing = routing;
        self
    }

    /// The kit's wire name, as the status line reports it.
    pub fn kit_name(&self) -> &'static str {
        self.kit.name()
    }
}

/// A value that moves linearly across one block from where it is to where a
/// plan put it.
///
/// The step a raw assignment makes is a click, and a filter or a reverb fed a
/// step rings with it. One block is 1.33 ms at the house's 64 frames, which is
/// short enough to be inaudible as a slide and long enough to remove the step.
/// The ramp lives beside the strip, so a plan that moves a fader every few
/// milliseconds keeps starting from the value actually heard.
#[derive(Clone, Copy, Debug)]
struct Ramp {
    current: f32,
    target: f32,
}

impl Ramp {
    fn new(value: f32) -> Self {
        Ramp {
            current: value,
            target: value,
        }
    }

    /// Where this control is heading. Read at the next block, never applied at
    /// the moment it is written.
    fn set_target(&mut self, value: f32) {
        self.target = value;
    }

    /// The value at frame `frame` of a `frames`-frame block. Frame zero is
    /// still the previous block's value, so the join makes no jump.
    fn value(&self, frame: usize, frames: usize) -> f32 {
        if frames <= 1 {
            return self.target;
        }
        let t = frame as f32 / (frames - 1) as f32;
        self.current + (self.target - self.current) * t
    }

    /// Arrive. The next block starts where this one ended.
    fn finish(&mut self) {
        self.current = self.target;
    }
}

/// Add one interleaved stereo block into another. Nothing here allocates or
/// panics; the caller owns both shapes.
fn add_stereo(out: &mut [f32], input: &[f32]) {
    for (out, sample) in out.iter_mut().zip(input.iter()) {
        *out += sample;
    }
}

/// Build an insert chain and size it. Allocation happens here, at a setup or
/// plan edge, never in a block.
fn build_chain(inserts: &[InsertKind], rate: u32, period: usize) -> EffectChain {
    let mut chain = EffectChain::new();
    for kind in inserts {
        chain.push(*kind);
    }
    chain.prepare(rate, period);
    chain
}

/// One prepared app-bus strip: ramped fader and pan, plus the channel's
/// inserts. Built at a plan edge (an insert's `prepare` allocates), then
/// reconciled in place when only the fader or pan moved, so a fader drag does
/// not reset a reverb tail. [`route_app_source`] runs it in the steady-state
/// block with no allocation.
struct AppStrip {
    gain: Ramp,
    pan: Ramp,
    /// The insert list the chain was built from. A change rebuilds the chain
    /// (and therefore its tails); a gain or pan move does not.
    inserts: Vec<InsertKind>,
    chain: EffectChain,
    /// The Studio channel this tap follows, if any.
    channel: Option<usize>,
    /// One mono block, sized when the strip is built.
    scratch: Vec<f32>,
}

impl AppStrip {
    fn new(route: &AppRoute, rate: u32, period: usize) -> Self {
        AppStrip {
            gain: Ramp::new(route.gain.clamp(0.0, 1.0)),
            pan: Ramp::new(route.pan.clamp(-1.0, 1.0)),
            inserts: route.inserts.clone(),
            chain: build_chain(&route.inserts, rate, period),
            channel: route.channel,
            scratch: vec![0.0; period],
        }
    }

    /// Follow a new tap. Only an insert-list change rebuilds the chain: a
    /// gain or pan move writes a ramp target, so a running reverb keeps its
    /// tail across a fader drag.
    fn reconcile(&mut self, route: &AppRoute, rate: u32, period: usize) {
        self.gain.set_target(route.gain.clamp(0.0, 1.0));
        self.pan.set_target(route.pan.clamp(-1.0, 1.0));
        self.channel = route.channel;
        if self.inserts != route.inserts {
            self.inserts = route.inserts.clone();
            self.chain = build_chain(&self.inserts, rate, period);
        }
    }
}

/// Build the strips for a routing list. Everything here allocates, so it runs
/// in `prepared` or at a plan edge, never in the block loop.
fn build_app_strips(routing: &[AppRoute], rate: u32, period: usize) -> Vec<AppStrip> {
    routing
        .iter()
        .map(|route| AppStrip::new(route, rate, period))
        .collect()
}

/// Bring existing strips up to a new routing without rebuilding the ones
/// whose insert list did not change. A changed entry count is a new routing
/// shape and rebuilds the list, exactly as before.
fn reconcile_app_strips(
    strips: &mut Vec<AppStrip>,
    routing: &[AppRoute],
    rate: u32,
    period: usize,
) {
    if strips.len() != routing.len() {
        *strips = build_app_strips(routing, rate, period);
        return;
    }
    for (strip, route) in strips.iter_mut().zip(routing.iter()) {
        strip.reconcile(route, rate, period);
    }
}

/// One destination channel of the output cord: the fader and inserts applied
/// to what a send hands it, and the two blocks it is built from.
///
/// `own` holds the channel's own sources after their strips (post-fader,
/// post-pan), which is the block the cord carries. `incoming` holds what other
/// channels sent here, still unshaped; it runs through this channel's fader
/// and inserts but never its pan, so the sources keep their pan images. `next`
/// is the destination's index in the strip list, or `None` for the master bus.
/// Built at a plan edge and never per block.
struct SendStrip {
    channel: usize,
    gain: Ramp,
    /// The insert list both chains were built from.
    inserts: Vec<InsertKind>,
    /// One chain per side, like the master rack: a stereo send has two images,
    /// and a reverb run left-then-right on one chain would bleed one into the
    /// other and lose the pan image.
    left_chain: EffectChain,
    right_chain: EffectChain,
    own: Vec<f32>,
    incoming: Vec<f32>,
    /// Deinterleaved halves the inserts run over, sized at build.
    left: Vec<f32>,
    right: Vec<f32>,
    /// The destination strip this channel feeds, or `None` for the master bus.
    next: Option<usize>,
}

impl SendStrip {
    fn new(channel: usize, gain: f32, inserts: &[InsertKind], rate: u32, period: usize) -> Self {
        SendStrip {
            channel,
            gain: Ramp::new(gain),
            inserts: inserts.to_vec(),
            left_chain: build_chain(inserts, rate, period),
            right_chain: build_chain(inserts, rate, period),
            own: vec![0.0; period * 2],
            incoming: vec![0.0; period * 2],
            left: vec![0.0; period],
            right: vec![0.0; period],
            next: None,
        }
    }

    /// Take a new fader value and insert list. Only the insert list rebuilds
    /// the chains, so a fader move on a destination keeps its reverb tail.
    fn reconcile(
        &mut self,
        channel: usize,
        gain: f32,
        inserts: &[InsertKind],
        rate: u32,
        period: usize,
    ) {
        self.channel = channel;
        self.gain.set_target(gain);
        if self.inserts != inserts {
            self.inserts = inserts.to_vec();
            self.left_chain = build_chain(&self.inserts, rate, period);
            self.right_chain = build_chain(&self.inserts, rate, period);
        }
    }

    /// Start a block: both blocks are silent before a source or a send fills
    /// them.
    fn clear(&mut self, frames: usize) {
        let samples = frames * 2;
        self.own[..samples].fill(0.0);
        self.incoming[..samples].fill(0.0);
    }

    /// Run the ramped fader and the inserts over what arrived from upstream.
    /// The fader is linear across the block; the inserts see the ramped signal
    /// on each side separately, so a stereo send keeps its two images apart.
    fn shape_incoming(&mut self, frames: usize) -> Result<(), String> {
        for frame in 0..frames {
            let gain = self.gain.value(frame, frames);
            self.left[frame] = self.incoming[frame * 2] * gain;
            self.right[frame] = self.incoming[frame * 2 + 1] * gain;
        }
        self.left_chain
            .process(&mut self.left[..frames])
            .map_err(|error| format!("send channel {}: {error:?}", self.channel))?;
        self.right_chain
            .process(&mut self.right[..frames])
            .map_err(|error| format!("send channel {}: {error:?}", self.channel))?;
        for frame in 0..frames {
            self.incoming[frame * 2] = self.left[frame];
            self.incoming[frame * 2 + 1] = self.right[frame];
        }
        self.gain.finish();
        Ok(())
    }

    /// The channel's total for this block: its own sources plus the shaped
    /// incoming sum. `total` is overwritten.
    fn total_into(&self, frames: usize, total: &mut [f32]) {
        let samples = frames * 2;
        for (index, sample) in total[..samples].iter_mut().enumerate() {
            *sample = self.own[index] + self.incoming[index];
        }
    }
}

/// Add one rendered app source into its channels and the pre-master bus.
///
/// An empty routing is the unpatched wire: the source's dual-mono block is
/// summed as it is, exactly as before routing existed. Otherwise the source's
/// left sample is the mono signal; it takes the strip's ramped fader, runs the
/// channel's inserts, then fans out through the ramped equal-power pan. A tap
/// that names a channel adds into that channel's own block so the send graph
/// can carry it; a tap with no channel adds straight to the pre-master bus.
/// Nothing here allocates.
fn route_app_source(
    strips: &mut [AppStrip],
    stereo: &[f32],
    frames: usize,
    master: &mut [f32],
    channels: &mut [SendStrip],
) -> Result<(), String> {
    let samples = frames * 2;
    if strips.is_empty() {
        for (out, sample) in master[..samples].iter_mut().zip(stereo[..samples].iter()) {
            *out += sample;
        }
        return Ok(());
    }
    for strip in strips.iter_mut() {
        let scratch = &mut strip.scratch[..frames];
        for (frame, sample) in scratch.iter_mut().enumerate() {
            *sample = stereo[frame * 2] * strip.gain.value(frame, frames);
        }
        strip
            .chain
            .process(scratch)
            .map_err(|error| format!("app routing: {error:?}"))?;
        // The destination is resolved once per strip, not per frame.
        let destination = match strip.channel {
            None => None,
            Some(channel) => Some(
                channels
                    .iter()
                    .position(|bus| bus.channel == channel)
                    .ok_or_else(|| format!("app routing names channel {channel}, which has no strip"))?,
            ),
        };
        match destination {
            Some(index) => {
                let out = &mut channels[index].own[..samples];
                for frame in 0..frames {
                    let (left, right) = pan_coefficients(strip.pan.value(frame, frames));
                    out[frame * 2] += scratch[frame] * left;
                    out[frame * 2 + 1] += scratch[frame] * right;
                }
            }
            None => {
                for frame in 0..frames {
                    let (left, right) = pan_coefficients(strip.pan.value(frame, frames));
                    master[frame * 2] += scratch[frame] * left;
                    master[frame * 2 + 1] += scratch[frame] * right;
                }
            }
        }
        strip.gain.finish();
        strip.pan.finish();
    }
    Ok(())
}

/// The transport's live drum state: the loaded kit, the pool of hits and the
/// sixteenth-step cursor. Built in `prepared` or at a plan edge, never per
/// block, because loading a kit renders every voice and allocates.
struct DrumRender {
    machine: Machine,
    chart: DrumChart,
    /// The strips this chart's routing built, kept across a step-only edit so
    /// an insert tail (a reverb, a delay) is not reset mid-phrase.
    strips: Vec<AppStrip>,
    /// The next chart step to trigger.
    step: usize,
    /// How many sixteenths have been played since this chart was built. It never
    /// wraps at the chart length, so each loop pass carries a different player
    /// wobble instead of repeating the first one.
    steps_played: u64,
    /// The song's own frame counter (wrapped at the transport loop), kept in
    /// frames so a tempo change moves the boundaries, not the cursor. It is the
    /// absolute grid the metronome clicks are on, not a count from the chart's
    /// own start: a chart is a repeating pattern on the song, so a start, seek
    /// or loop wrap joins it at the step the beat is on.
    phase: f64,
    /// The absolute song frame of the next step boundary.
    next_phase: f64,
    /// The step length the current boundary was measured with; a change
    /// re-anchors the next boundary on the new grid.
    step_frames: f64,
    /// A one-shot chart that has played its last step.
    finished: bool,
}

/// How many frames one sixteenth lasts at `bpm`. A chart step is a sixteenth,
/// so four steps make a beat and sixteen make a 4/4 bar. At least one frame,
/// even for an absurd tempo.
fn drum_step_frames(rate: u32, bpm: f64) -> f64 {
    if bpm.is_finite() && bpm > 0.0 {
        (rate as f64 * 60.0 / bpm / 4.0).max(1.0)
    } else {
        1.0
    }
}

impl DrumRender {
    fn new(chart: DrumChart, rate: u32, period: usize) -> Self {
        let mut machine = Machine::new(rate, period);
        machine.load_kit(chart.kit);
        let strips = build_app_strips(&chart.routing, rate, period);
        DrumRender {
            machine,
            chart,
            strips,
            step: 0,
            steps_played: 0,
            phase: 0.0,
            next_phase: 0.0,
            step_frames: 0.0,
            finished: false,
        }
    }

    /// Put the chart on the song's absolute sixteenth grid at `position`.
    ///
    /// Step `s` sounds at song frame `s*q + n*length*q`, with step 0 on frame 0,
    /// so the chart shares the metronome's beat grid instead of restarting on
    /// an arbitrary playhead. The next boundary at or after `position` fires the
    /// step the grid says is there; a position exactly on a boundary fires it on
    /// the block's first frame. `steps_played` is left alone so the player's
    /// wobble keeps counting across a loop wrap.
    fn align_to(&mut self, position: u64, q: f64) {
        let length = self.chart.length.max(1);
        let index = (position as f64 / q).ceil();
        let delta = (index * q - position as f64).max(0.0);
        self.step = index.max(0.0) as u64 as usize % length;
        self.phase = position as f64;
        self.next_phase = position as f64 + delta;
        self.step_frames = q;
        self.finished = false;
    }
}

/// A whole replacement placement plan for a running transport.
///
/// The control thread parses a plan (a full set of takes, already decoded) and
/// sends it over a channel; the render thread swaps it in at the next block.
/// Each field is optional and `None` leaves that part of the transport alone:
/// `clips` is the placement, `master` the armed rack, and `master_values` the
/// rack's knobs (a value-only update carries no takes).
pub struct TransportPlan {
    /// A replacement placement, or `None` for a values-only update (a master
    /// knob moved while the takes did not).
    pub clips: Option<Vec<TransportClip>>,
    /// A replacement rack, or `None` to leave the armed one alone.
    pub master: Option<Vec<InsertKind>>,
    /// Live master knob positions as `("master_comp.thresh", -18.0)`. They ride
    /// the same block edge as a placement and never rebuild the rack, so a knob
    /// turn does not reset a reverb or a limiter's gain.
    pub master_values: Option<Vec<(String, f32)>>,
    /// A replacement drum chart, or `None` to leave the playing chart alone.
    /// A chart or kit change rebuilds the machine here, at a block edge; the
    /// device stays open.
    pub drums: Option<DrumChart>,
    /// A synth patch to load, or `None` to leave the playing synth alone. A
    /// transport that already has a synth retunes it in place, so held notes
    /// keep sounding; otherwise the render thread builds one here.
    pub synth: Option<SynthPlan>,
    /// A replacement output-cord plan, as `(from, to)` channel pairs. `None`
    /// leaves the current graph alone; the socket has already refused a self
    /// edge, a second destination for one source and a cycle.
    pub sends: Option<Vec<(usize, usize)>>,
}

/// A patch and/or routing for the transport's native synth, applied at a
/// block edge.
///
/// The socket sends one when the page changes a patch or Studio re-patches the
/// synth into a channel. The render thread keeps the synth across blocks, so a
/// later plan calls [`jawn_synth::Synth::set_patch`] rather than rebuilding it:
/// running voices finish with the patch they started with, exactly as the
/// browser does. A routing-only plan carries no patch, and a later patch plan
/// carries no routing, so neither clears the other.
pub struct SynthPlan {
    /// The browser patch, or `None` for a routing-only update that must not
    /// retune or rebuild the sounding synth.
    pub patch: Option<Patch>,
    /// Replacement routing strips, or `None` to keep the current routing.
    /// Studio sends this because the synth app does not know which channel it
    /// feeds.
    pub routing: Option<Vec<AppRoute>>,
}

/// A note edge for the transport's native synth, read at a block edge.
///
/// The socket sends these while the transport plays, so a page can audition a
/// patch on the same output as the takes, drums and click. Edges are applied in
/// the order they arrive, before the block renders.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TransportNote {
    /// Start (`on`) or release a note; `velocity` is in `0..=1`.
    Note {
        /// `true` starts the note, `false` releases it.
        on: bool,
        /// A MIDI note number, `0..=127`.
        note: u8,
        /// Note-on velocity, `0..=1`.
        velocity: f32,
    },
    /// Release every voice, exactly as the page's panic button does.
    AllOff,
}

/// A one-shot drum hit for audition, read at a block edge.
///
/// A hit needs the chart's loaded machine: a transport with no chart has no
/// kit to render, so the edge is dropped rather than building one on the audio
/// thread (loading a kit allocates).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransportHit {
    /// The slot in [`jawn_drums::Voice::index`] order.
    pub voice: usize,
    /// Velocity on the machine's own `1..=100` scale.
    pub velocity: u8,
}

/// An attach or detach of a take's live input on a running transport.
///
/// The socket sends one of these when a take starts beside the transport or
/// stops, so the transport's one output carries the take's live input without
/// opening a second device. The render thread reads the newest edge at a block
/// edge, exactly as it reads a [`TransportPlan`].
pub enum TransportLive {
    /// Sum this consumer into the transport's master chain, trimmed by `gain`.
    Attach {
        consumer: Consumer,
        gain: Arc<AtomicU32>,
    },
    /// Stop summing the live input; the transport keeps playing its clips and
    /// click, and the live part of its bus becomes silence.
    Detach,
}

/// The take's live input on a transport: the monitoring ring's read side and
/// the trim the socket can move mid-take.
struct TransportLiveInput {
    consumer: Consumer,
    /// `f32` bits of the live trim, clamped to `0..=4` by the control path.
    gain: Arc<AtomicU32>,
}

/// The transport's render source: the same click buffers as a take's
/// metronome, read from the absolute song grid and blended with the mutable
/// controls at the top of every block, plus the recorded takes placed on the
/// same timeline. It allocates nothing in the steady-state block loop; a plan
/// update that changes the clip count or insert set may rebuild the strips once
/// at a block edge (a placement-only update swaps in place).
pub struct TransportSource {
    control: Arc<TransportControl>,
    click: Option<ClickState>,
    /// The takes this transport renders, each through its own strip.
    clips: Vec<TransportClip>,
    /// The master rack armed on the clip mix, so the transport hears the same
    /// mastering chain a take does (the browser's `studioAudio.master`).
    master: Vec<InsertKind>,
    /// The last master knob positions the control thread sent. Kept so a rack
    /// rebuilt by a later plan starts where the page left it.
    master_values: Vec<(String, f32)>,
    mixer: Mixer,
    /// One mono block per clip, reused by every block.
    voices: Vec<Vec<f32>>,
    /// The take's live input, when one is attached to this transport. It joins
    /// the clips before the master chain, so the person and the takes hear one
    /// mastering pass; the click stays after it.
    live: Option<TransportLiveInput>,
    /// One stereo block for the live input, filled by the ring at the top of a
    /// block. Sized in `prepared`, so an attach mid-song never allocates on the
    /// audio thread.
    live_block: Vec<f32>,
    /// Attach and detach edges from the control thread. `try_recv` never
    /// blocks, so an edge that is not ready waits for a later block.
    live_rx: Option<Receiver<TransportLive>>,
    /// New placement plans from the control thread. `try_recv` never blocks, so
    /// a plan that is not ready waits for a later block instead of stalling the
    /// device.
    plan_rx: Option<Receiver<TransportPlan>>,
    /// The drum chart this transport plays, if any. It arrives before the device
    /// opens or rides a plan; the render machine is built from it in `prepared`
    /// and at a plan edge that changes the kit.
    drums: Option<DrumChart>,
    /// The native drum machine and its sixteenth-step cursor, once a chart is
    /// loaded.
    drum_render: Option<DrumRender>,
    /// The machine's planar block (left half, then right half), sized in
    /// `prepared`.
    drum_block: Vec<f32>,
    /// The same block interleaved for the stereo mix bus. The machine renders
    /// mono to both channels; this is the only per-block copy, and it allocates
    /// nothing.
    drum_stereo: Vec<f32>,
    /// The patch the page last sent, kept so `prepared` can build the synth when
    /// the device opens.
    synth_patch: Option<Patch>,
    /// The channels Studio patched the synth into, and the strips built from
    /// them. They arrive separately from the patch, so a patch change never
    /// clears the routing and a routing change never retunes the patch.
    synth_routes: Vec<AppRoute>,
    synth_strips: Vec<AppStrip>,
    /// The native synth, built in `prepared` and retuned at a plan edge.
    synth: Option<Synth>,
    /// The synth's planar block (left half, then right half), sized in
    /// `prepared`.
    synth_block: Vec<f32>,
    /// The same block interleaved for the app bus. The synth writes planar
    /// halves; this is the only per-block copy, and it allocates nothing.
    synth_stereo: Vec<f32>,
    /// The pre-master bus: every source with no channel, and every channel with
    /// no send, summed before the master chain. The drums and the synth land
    /// here when they are unpatched, and the take's live input joins them. One
    /// mastering pass covers all of it.
    pre_master: Vec<f32>,
    /// One stereo block for a clip's panned output before it is added to its
    /// channel or to the pre-master bus.
    clip_stereo: Vec<f32>,
    /// The output-cord edges as `(from, to)`, already validated by the socket.
    sends: Vec<(usize, usize)>,
    /// One destination strip per channel the sources or sends name. Only used
    /// channels are built, so an unused channel costs no buffer at all.
    send_strips: Vec<SendStrip>,
    /// The order the destination strips run in: upstream before downstream.
    send_order: Vec<usize>,
    /// Note edges from the control thread, drained at a block edge.
    note_rx: Option<Receiver<TransportNote>>,
    /// One-shot drum hits from the control thread, drained at a block edge.
    hit_rx: Option<Receiver<TransportHit>>,
    /// The device rate and prepared period, kept so a plan that changes the
    /// clip count or insert set can rebuild the strips on the render thread.
    rate: u32,
    period: usize,
    /// The clip timeline's absolute frame, advanced in step with the click.
    clip_position: u64,
    clip_loop: (u64, u64),
    seek_seq: u64,
    bpm_bits: u64,
    beats_per_bar: u32,
    gain_bits: u32,
    loop_bounds: (u64, u64),
}

impl TransportSource {
    pub fn new(control: Arc<TransportControl>) -> Self {
        TransportSource {
            control,
            click: None,
            clips: Vec::new(),
            master: Vec::new(),
            master_values: Vec::new(),
            mixer: Mixer::new(&[], &[]),
            voices: Vec::new(),
            live: None,
            live_block: Vec::new(),
            live_rx: None,
            plan_rx: None,
            drums: None,
            drum_render: None,
            drum_block: Vec::new(),
            drum_stereo: Vec::new(),
            synth_patch: None,
            synth_routes: Vec::new(),
            synth_strips: Vec::new(),
            synth: None,
            synth_block: Vec::new(),
            synth_stereo: Vec::new(),
            pre_master: Vec::new(),
            clip_stereo: Vec::new(),
            sends: Vec::new(),
            send_strips: Vec::new(),
            send_order: Vec::new(),
            note_rx: None,
            hit_rx: None,
            rate: 0,
            period: 0,
            clip_position: 0,
            clip_loop: (0, 0),
            seek_seq: 0,
            bpm_bits: 0,
            beats_per_bar: 0,
            gain_bits: 0,
            loop_bounds: (0, 0),
        }
    }

    /// The same source carrying recorded takes. The clips are read before the
    /// device opens, so a missing or wrong-shaped file is a refusal from
    /// `transport start`, never a silent gap in the audio.
    pub fn with_clips(mut self, clips: Vec<TransportClip>) -> Self {
        self.clips = clips;
        self
    }

    /// The output-cord graph this transport follows, as `(from, to)` Studio
    /// channel pairs. The socket refuses a malformed graph before a device
    /// opens; this stores what it validated. Without a send every source sums
    /// into the master bus.
    pub fn with_sends(mut self, sends: Vec<(usize, usize)>) -> Self {
        self.sends = sends;
        self
    }

    /// The mastering rack the clip mix runs through, in the order the socket
    /// already put it (the contract's order). It is armed before the device
    /// opens; a later [`TransportPlan`] may replace it at a block edge without
    /// reopening the device.
    pub fn with_master(mut self, master: Vec<InsertKind>) -> Self {
        self.master = master;
        self
    }

    /// The master rack's knob positions, applied once the rack is prepared.
    /// They are stored, so a later rebuild restores them at the same edge.
    pub fn with_master_values(mut self, values: Vec<(String, f32)>) -> Self {
        self.master_values = values;
        self
    }

    /// Take placement plans from the control thread. The receiver lives on the
    /// render thread, so applying a plan never needs a lock the control thread
    /// holds; the socket keeps the matching sender.
    pub fn with_plan_rx(mut self, plans: Receiver<TransportPlan>) -> Self {
        self.plan_rx = Some(plans);
        self
    }

    /// The drum chart to play before the device opens. A chart that arrives
    /// beside a running transport rides a [`TransportPlan`] instead, so the
    /// device is never reopened.
    pub fn with_drums(mut self, chart: DrumChart) -> Self {
        self.drums = Some(chart);
        self
    }

    /// Attach the take's live input before the device opens. A take that starts
    /// beside an already-running transport uses [`with_live_rx`] instead,
    /// because the device is already open and the edge must reach the render
    /// thread.
    pub fn with_live_input(mut self, consumer: Consumer, gain: Arc<AtomicU32>) -> Self {
        self.live = Some(TransportLiveInput { consumer, gain });
        self
    }

    /// Attach/detach edges for the take's live input. The receiver lives on the
    /// render thread and is drained at a block edge, so a take that starts or
    /// stops beside a playing transport never stops or reopens the device.
    pub fn with_live_rx(mut self, live: Receiver<TransportLive>) -> Self {
        self.live_rx = Some(live);
        self
    }

    /// Note edges for the native synth. The receiver lives on the render thread
    /// and is drained at a block edge, so a page can play the synth without
    /// reopening the device. An edge that arrives before a patch is loaded is a
    /// no-op.
    pub fn with_note_rx(mut self, notes: Receiver<TransportNote>) -> Self {
        self.note_rx = Some(notes);
        self
    }

    /// One-shot drum hits for audition. The receiver lives on the render thread
    /// and is drained at a block edge; a hit with no chart loaded is dropped,
    /// because there is no machine to render it.
    pub fn with_hit_rx(mut self, hits: Receiver<TransportHit>) -> Self {
        self.hit_rx = Some(hits);
        self
    }

    /// Apply one attach or detach edge. Setup or a block-edge call, never a
    /// steady-state one: the block is already sized in `prepared`, so neither
    /// direction allocates here.
    fn apply_live(&mut self, edge: TransportLive) {
        match edge {
            TransportLive::Attach { consumer, gain } => {
                self.live = Some(TransportLiveInput { consumer, gain });
            }
            TransportLive::Detach => {
                self.live = None;
                // A later attach starts from silence rather than the block the
                // old take left behind.
                self.live_block.fill(0.0);
            }
        }
    }

    /// How many takes this transport carries, for the status line and a test.
    pub fn clip_count(&self) -> usize {
        self.clips.len()
    }

    /// Apply a replacement plan at a block edge.
    ///
    /// A placement-only change (same takes, same files, same insert chains)
    /// moves the start, in-point, length, fades, loop, gain and pan in place: the
    /// strips keep their insert tails, so a move or a trim does not reset a
    /// reverb or delay mid-phrase. A different number of takes, a different file
    /// or a different insert set rebuilds the strips and voices once, here on the
    /// render thread (an insert need not be `Send`); that rebuild does reset the
    /// tails, exactly as a seek does. `clip_position` is never reset, so the new
    /// placement is heard from where the transport already is.
    fn apply_plan(&mut self, plan: TransportPlan) {
        let TransportPlan {
            clips,
            master,
            master_values,
            drums,
            synth,
            sends,
        } = plan;
        // The destination strips and the source-to-channel map are rebuilt once
        // here when either half of the routing moved; a values-only or
        // placement-only plan leaves their tails alone.
        let mut routing_dirty = false;
        if let Some(sends) = sends {
            if sends != self.sends {
                self.sends = sends;
                routing_dirty = true;
            }
        }
        // A patch change retunes a loaded synth (its voices keep sounding) or
        // builds one here, at the block edge; the device stays open.
        if let Some(synth) = synth {
            let before = self.synth_routes.clone();
            self.apply_synth_plan(synth);
            if self.synth_routes != before {
                routing_dirty = true;
            }
        }
        // A chart or kit change builds (or reloads) the machine here, at the
        // block edge; the device stays open and the clip strips are untouched.
        if let Some(chart) = drums {
            let before = self
                .drums
                .as_ref()
                .map(|chart| chart.routing.clone())
                .unwrap_or_default();
            self.apply_drum_chart(chart);
            let after = self
                .drums
                .as_ref()
                .map(|chart| chart.routing.clone())
                .unwrap_or_default();
            if before != after {
                routing_dirty = true;
            }
        }
        if let Some(master) = master {
            if master != self.master {
                self.master = master;
                self.mixer
                    .set_master_chain(&self.master, self.rate, self.period);
                // The rebuilt inserts start at their defaults; the page's last
                // knob positions are restored at this same edge.
                self.apply_master_values();
            }
        }
        if let Some(values) = master_values {
            self.master_values = values;
            self.apply_master_values();
        }
        // A values-only plan carries no placement: the takes keep playing.
        let Some(clips) = clips else {
            if routing_dirty {
                self.rebuild_send_strips();
            }
            return;
        };
        // The channel a take names is part of the routing, so any replacement
        // placement reconciles the send strips even when every strip is
        // unchanged; reconciliation keeps the tails.
        routing_dirty = true;
        let placement_only = clips.len() == self.clips.len()
            && clips
                .iter()
                .zip(self.clips.iter())
                .all(|(new, old)| new.path == old.path && new.inserts == old.inserts);
        if placement_only {
            for (index, clip) in clips.into_iter().enumerate() {
                if let Some(track) = self.mixer.tracks_mut().get_mut(index) {
                    // `Channel::set` writes a smoothed target, so a fader or pan
                    // move is a ramp rather than a click and the inserts are
                    // never rebuilt.
                    track.channel.set("gain", clip.gain);
                    track.channel.set("pan", clip.pan);
                }
                self.clips[index] = clip;
            }
        } else {
            self.clips = clips;
            self.rebuild_strips();
        }
        if routing_dirty {
            self.rebuild_send_strips();
        }
    }

    /// Load or retune the synth at a plan edge, and/or replace its routing.
    ///
    /// A synth that is already loaded takes the patch with
    /// [`Synth::set_patch`], so a page that keeps editing the patch never cuts
    /// a held note; the first patch builds the synth here, which is the only
    /// allocation this path performs. The two halves are independent: a patch
    /// plan leaves the routing alone, and a routing plan (the synth's own
    /// `routing` command) never touches the patch or the sounding voices.
    fn apply_synth_plan(&mut self, plan: SynthPlan) {
        if let Some(patch) = plan.patch {
            match self.synth.as_mut() {
                Some(synth) => synth.set_patch(patch),
                None if self.period > 0 && self.rate > 0 => {
                    let mut synth = Synth::new(patch, self.rate as f32);
                    synth.prepare(self.period);
                    self.synth = Some(synth);
                }
                // A plan that arrives before `prepared` only records the patch;
                // the synth is built when the device rate and period are known.
                None => {}
            }
            self.synth_patch = Some(patch);
        }
        if let Some(routing) = plan.routing {
            self.synth_routes = routing;
            if self.period > 0 {
                reconcile_app_strips(
                    &mut self.synth_strips,
                    &self.synth_routes,
                    self.rate,
                    self.period,
                );
            }
        }
    }

    /// Apply one note edge. The synth lives on this thread, so an edge that
    /// arrives before a patch was loaded is a no-op, never a panic.
    fn apply_note(&mut self, edge: TransportNote) {
        let Some(synth) = self.synth.as_mut() else {
            return;
        };
        match edge {
            TransportNote::Note {
                on: true,
                note,
                velocity,
            } => synth.note_on(note, velocity),
            TransportNote::Note {
                on: false, note, ..
            } => synth.note_off(note),
            TransportNote::AllOff => synth.all_notes_off(),
        }
    }

    /// Apply one audition hit. A transport with no chart has no machine, so the
    /// edge is dropped rather than building one on the audio thread.
    fn apply_hit(&mut self, hit: TransportHit) {
        if let Some(render) = self.drum_render.as_mut() {
            render.machine.trigger_at(hit.voice, hit.velocity, 0);
        }
    }

    /// Render one block of the synth and copy it into the stereo app bus. The
    /// synth writes planar halves, so this is the one per-block copy; the
    /// buffers are sized in `prepared` and nothing allocates here.
    fn render_synth(&mut self, frames: usize) {
        let TransportSource {
            synth,
            synth_block,
            synth_stereo,
            ..
        } = self;
        let Some(synth) = synth.as_mut() else {
            return;
        };
        let block = &mut synth_block[..frames * 2];
        let (left, right) = block.split_at_mut(frames);
        synth.render(left, right);
        for frame in 0..frames {
            synth_stereo[frame * 2] = left[frame];
            synth_stereo[frame * 2 + 1] = right[frame];
        }
    }

    /// Replace the drum chart at a plan edge. A different kit rebuilds the
    /// machine (and renders its voices) once here; a same-kit chart swaps the
    /// rows in place, so an edit never allocates on the audio thread. The
    /// cursor keeps its place unless the new chart is shorter than it.
    fn apply_drum_chart(&mut self, chart: DrumChart) {
        let rate = self.rate;
        let period = self.period;
        // A rebuilt or re-lengthed chart starts on the song's sixteenth grid at
        // the transport's current position, not at step 0 in the middle of a
        // bar. The click is already there.
        let position = self.click.as_ref().map(|click| click.position()).unwrap_or(0);
        let q = drum_step_frames(rate, f64::from_bits(self.bpm_bits));
        let same_kit = self
            .drum_render
            .as_ref()
            .map(|render| render.chart.kit == chart.kit)
            .unwrap_or(false);
        if same_kit {
            let render = self
                .drum_render
                .as_mut()
                .expect("same_kit means a render machine exists");
            // A different length means the chart changed identity (the page
            // silences the engine kit with a one-step chart when the browser
            // plays it). Re-read the grid here, so a mid-song switch stays on
            // the beat rather than restarting at a stale phase.
            let relength = render.chart.length != chart.length;
            // A step-only edit keeps the same routing, so the strips (and their
            // tails) stay; a routing change reconciles them, which moves a
            // fader or pan in place and rebuilds only a changed insert list.
            if render.chart.routing != chart.routing {
                reconcile_app_strips(&mut render.strips, &chart.routing, rate, period);
            }
            render.chart = chart.clone();
            if relength {
                render.steps_played = 0;
                render.align_to(position, q);
            } else if render.step >= render.chart.length {
                render.step %= render.chart.length;
                render.finished = false;
            }
        } else if period > 0 && rate > 0 {
            let mut render = DrumRender::new(chart.clone(), rate, period);
            render.align_to(position, q);
            self.drum_render = Some(render);
        }
        self.drums = Some(chart);
    }

    /// Render one block of drums and schedule its steps.
    ///
    /// The phase is kept in frames since step 0, so a tempo change moves the
    /// next boundary to the new sixteenth length without jumping the cursor.
    /// A transport loop resets the phase and the chart position at the wrap, so
    /// every loop begins on step 0 at `loop_start`. Every trigger is placed
    /// with [`Machine::trigger_at`], so a step can land anywhere inside the
    /// block, then the machine renders the whole block once.
    fn render_drums(&mut self, song_start: u64, frames: usize) {
        let Some(render) = self.drum_render.as_mut() else {
            return;
        };
        let q = drum_step_frames(self.rate, f64::from_bits(self.bpm_bits));
        // A tempo change moves the sixteenths, so the chart re-reads the same
        // absolute grid the click re-anchored at this block's position.
        if render.step_frames > 0.0 && (q - render.step_frames).abs() > 1e-9 {
            render.align_to(song_start, q);
        }
        render.step_frames = q;
        if render.next_phase < render.phase {
            render.next_phase = ((render.phase / q).floor() + 1.0) * q;
        }

        let loop_bounds = self.clip_loop;
        let mut phase = render.phase;
        let mut song = song_start;
        let performance = render.chart.performance;
        let chart_length = render.chart.length.max(1);
        for frame in 0..frames {
            if !render.finished && phase + 1e-9 >= render.next_phase {
                // The step is a function of the boundary's own place on the
                // song grid, so a start, seek or loop wrap can never leave the
                // chart a step away from the beat the click is on.
                let metric_step =
                    ((render.next_phase / q).round().max(0.0) as u64 as usize) % chart_length;
                let steps_played = render.steps_played;
                if let Some(row) = render.chart.steps.get(metric_step) {
                    for voice in Voice::ALL {
                        let velocity = row[voice.index()];
                        if velocity == 0 {
                            continue;
                        }
                        let (velocity, offset) = match performance {
                            Some(performance) => {
                                let played = performance.play(
                                    voice,
                                    velocity,
                                    steps_played,
                                    metric_step,
                                    q,
                                    self.rate,
                                );
                                (played.velocity, played.offset_frames)
                            }
                            None => (velocity, 0),
                        };
                        render.machine.trigger_at(voice.index(), velocity, frame + offset);
                    }
                }
                render.step = (metric_step + 1) % chart_length;
                render.steps_played = render.steps_played.wrapping_add(1);
                // A one-shot chart plays its length once; a looping chart never
                // finishes and its step comes from the grid each boundary.
                if !render.chart.looped && render.steps_played >= chart_length as u64 {
                    render.finished = true;
                }
                render.next_phase += q;
            }
            phase += 1.0;
            song += 1;
            if loop_bounds.1 > loop_bounds.0 && song >= loop_bounds.1 {
                let length = loop_bounds.1 - loop_bounds.0;
                song = loop_bounds.0 + (song - loop_bounds.1) % length;
                // The transport loop jumps the song position; the chart
                // re-reads the grid there so it stays under the click, which
                // wraps to the same point. `steps_played` keeps counting, so
                // the next pass is played, not replayed.
                render.align_to(song, q);
                phase = render.phase;
            }
        }
        render.phase = phase;

        let block = &mut self.drum_block[..frames * 2];
        let (left, right) = block.split_at_mut(frames);
        render.machine.render(left, right);
        // The machine writes planar halves; the mix bus is interleaved.
        for frame in 0..frames {
            self.drum_stereo[frame * 2] = left[frame];
            self.drum_stereo[frame * 2 + 1] = right[frame];
        }
    }

    /// Rebuild the clip strips and voices for the current plan. Called from
    /// `prepared` and from a plan update that changes the clip count or insert
    /// set; the short buffer is reused when only the master rack changed.
    fn rebuild_strips(&mut self) {
        if self.period == 0 {
            return;
        }
        let (mixer, voices) = build_clip_mixer(
            &self.clips,
            &self.master,
            &self.master_values,
            self.rate,
            self.period,
        );
        self.mixer = mixer;
        self.voices = voices;
    }

    /// Recompute the output-cord destination strips from the current clips,
    /// app taps and sends. A plan-edge call only: an insert allocates, and the
    /// buffers are sized for the prepared block. Strips are matched by channel
    /// number and reconciled, so a fader or pan move keeps its insert tail; a
    /// removed channel's strip is dropped.
    fn rebuild_send_strips(&mut self) {
        if self.period == 0 {
            return;
        }
        let empty: &[AppRoute] = &[];
        let drum_routing = self
            .drums
            .as_ref()
            .map(|chart| chart.routing.as_slice())
            .unwrap_or(empty);
        let specs = channel_specs(&self.clips, drum_routing, &self.synth_routes, &self.sends);
        let mut old: Vec<Option<SendStrip>> = std::mem::take(&mut self.send_strips)
            .into_iter()
            .map(Some)
            .collect();
        let mut fresh = Vec::with_capacity(specs.len());
        for (channel, gain, inserts) in specs {
            let position = old.iter().position(|strip| {
                strip
                    .as_ref()
                    .map(|strip| strip.channel == channel)
                    .unwrap_or(false)
            });
            match position.and_then(|position| old[position].take()) {
                Some(mut strip) => {
                    strip.reconcile(channel, gain, &inserts, self.rate, self.period);
                    fresh.push(strip);
                }
                None => fresh.push(SendStrip::new(
                    channel, gain, &inserts, self.rate, self.period,
                )),
            }
        }
        // One destination per source, so each strip's `next` is a single
        // position in the fresh list.
        let next_positions: Vec<Option<usize>> = fresh
            .iter()
            .map(|strip| {
                self.sends
                    .iter()
                    .find(|(from, _)| *from == strip.channel)
                    .and_then(|(_, to)| fresh.iter().position(|dest| dest.channel == *to))
            })
            .collect();
        for (strip, next) in fresh.iter_mut().zip(next_positions) {
            strip.next = next;
        }
        // Evaluate upstream before downstream. The socket refused a cycle; a
        // direct caller that still hands one in gets numeric order rather than
        // a spinner.
        let mut by_destination = vec![None; 32];
        for &(from, to) in &self.sends {
            if (1..=32).contains(&from) && (1..=32).contains(&to) {
                by_destination[to - 1] = Some(from - 1);
            }
        }
        let mut used = [false; 32];
        for strip in &fresh {
            if (1..=32).contains(&strip.channel) {
                used[strip.channel - 1] = true;
            }
        }
        let order = match send_order(&by_destination) {
            Ok(order) => order,
            Err(_) => (0..32).collect(),
        };
        self.send_order = order
            .into_iter()
            .filter(|channel| used[*channel])
            .filter_map(|channel| {
                fresh
                    .iter()
                    .position(|strip| strip.channel == channel + 1)
            })
            .collect();
        self.send_strips = fresh;
    }

    /// Push the stored master knob positions into the current rack. A setup or
    /// plan-edge call, never a steady-state one. A freshly built rack already
    /// carries them (they go in before `prepare`); this is for a rack replaced
    /// under a running transport.
    fn apply_master_values(&mut self) {
        let TransportSource {
            mixer,
            master_values,
            ..
        } = self;
        for (name, value) in master_values.iter() {
            mixer.set_master(name, *value);
        }
    }
}

/// Build the strips and voice buffers for a clip plan. Everything here
/// allocates, so it runs in `prepared` or at a plan update, never in the steady
/// state block loop.
fn build_clip_mixer(
    clips: &[TransportClip],
    master: &[InsertKind],
    master_values: &[(String, f32)],
    rate: u32,
    period: usize,
) -> (Mixer, Vec<Vec<f32>>) {
    let inputs: Vec<usize> = (0..clips.len()).collect();
    let labels: Vec<String> = (1..=clips.len()).map(|n| format!("c{n}")).collect();
    let label_refs: Vec<&str> = labels.iter().map(|label| label.as_str()).collect();
    let mut mixer = Mixer::new(&inputs, &label_refs);
    for (index, clip) in clips.iter().enumerate() {
        let mut channel = Channel::new(clip.gain, clip.pan.clamp(-1.0, 1.0));
        for kind in &clip.inserts {
            channel.push(kind.build());
        }
        mixer.tracks_mut()[index].channel = channel;
    }
    for kind in master {
        mixer.push_master(*kind);
    }
    // The page's knob positions go in before `prepare`, so an insert that
    // copies its target into its running state at prepare starts at the value
    // the page shows rather than its default and a block of smoothing.
    for (name, value) in master_values {
        mixer.set_master(name, *value);
    }
    mixer.prepare(rate, period);
    let voices = vec![vec![0.0; period]; clips.len()];
    (mixer, voices)
}

/// The fader and inserts each channel number carries, in first-seen order.
///
/// A Studio channel's settings travel on its sources — every clip and every
/// app tap names the channel and repeats its fader and Out inserts, exactly as
/// the page already sent gain, pan and inserts. The first source that names a
/// channel therefore defines the strip a send into that channel runs through.
/// A channel named only by a send is a unity wire with no inserts. The pan is
/// deliberately not taken: a destination never re-pans what a source already
/// placed.
fn channel_specs(
    clips: &[TransportClip],
    drums: &[AppRoute],
    synth: &[AppRoute],
    sends: &[(usize, usize)],
) -> Vec<(usize, f32, Vec<InsertKind>)> {
    let mut specs: Vec<(usize, f32, Vec<InsertKind>)> = Vec::new();
    for clip in clips {
        note_channel(&mut specs, clip.channel, clip.gain, &clip.inserts);
    }
    for route in drums.iter().chain(synth.iter()) {
        note_channel(&mut specs, route.channel, route.gain, &route.inserts);
    }
    for &(from, to) in sends {
        note_channel(&mut specs, Some(from), 1.0, &[]);
        note_channel(&mut specs, Some(to), 1.0, &[]);
    }
    specs
}

/// Add one channel definition if it is in range and not already known.
fn note_channel(
    specs: &mut Vec<(usize, f32, Vec<InsertKind>)>,
    channel: Option<usize>,
    gain: f32,
    inserts: &[InsertKind],
) {
    let Some(channel) = channel else { return };
    if !(1..=32).contains(&channel) {
        return;
    }
    if specs.iter().any(|(known, _, _)| *known == channel) {
        return;
    }
    specs.push((
        channel,
        gain.clamp(0.0, Channel::MAX_GAIN),
        inserts.to_vec(),
    ));
}

impl RenderSource for TransportSource {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        if period == 0 {
            return Err("a transport block must hold at least one frame".to_string());
        }
        self.control.set_rate(rate);
        self.seek_seq = self.control.seek_seq();
        self.bpm_bits = self.control.bpm_bits();
        self.beats_per_bar = self.control.beats_per_bar();
        self.gain_bits = self.control.gain_bits();
        self.loop_bounds = (self.control.loop_start(), self.control.loop_end());
        let spec = self.control.spec();
        self.click = Some(ClickState::build_absolute(
            spec,
            rate,
            period,
            self.control.seek_frames(),
            self.loop_bounds.0,
            self.loop_bounds.1,
        ));
        // Every clip runs through the same kind of strip a playback uses, so a
        // take's gain, pan and inserts read the same here as there. The strips
        // are built on the render thread: an insert need not be `Send`.
        let (mixer, voices) = build_clip_mixer(
            &self.clips,
            &self.master,
            &self.master_values,
            rate,
            period,
        );
        self.mixer = mixer;
        self.voices = voices;
        // Sized even without a live input, so an attach beside a running
        // transport is one assignment rather than an allocation on the audio
        // thread.
        self.live_block = vec![0.0; period.saturating_mul(2)];
        // A chart that arrived before the device opened builds its machine
        // here; loading a kit renders every voice, so the audio thread still
        // only renders.
        self.drum_block = vec![0.0; period.saturating_mul(2)];
        self.drum_stereo = vec![0.0; period.saturating_mul(2)];
        self.drum_render = self
            .drums
            .as_ref()
            .map(|chart| DrumRender::new(chart.clone(), rate, period));
        // The chart follows the song's absolute sixteenth grid, so a transport
        // that starts part-way through a song (or after its clips staged) joins
        // the beat the metronome is on instead of restarting off-beat.
        if let Some(render) = self.drum_render.as_mut() {
            render.align_to(
                self.control.seek_frames(),
                drum_step_frames(rate, f64::from_bits(self.bpm_bits)),
            );
        }
        // The synth is built here when the page sent a patch before the device
        // opened; its buffers join the same prepared size as the drums and the
        // app bus, so every block below is allocation-free.
        self.synth_block = vec![0.0; period.saturating_mul(2)];
        self.synth_stereo = vec![0.0; period.saturating_mul(2)];
        self.pre_master = vec![0.0; period.saturating_mul(2)];
        self.clip_stereo = vec![0.0; period.saturating_mul(2)];
        self.synth = self.synth_patch.map(|patch| {
            let mut synth = Synth::new(patch, rate as f32);
            synth.prepare(period);
            synth
        });
        self.rate = rate;
        self.period = period;
        // A routing that arrived before the device opened builds its strips
        // here, where an insert's `prepare` is allowed to allocate.
        self.synth_strips = build_app_strips(&self.synth_routes, rate, period);
        // The output-cord destination strips are built from the clips and taps
        // that arrived before the device opened. Their blocks are sized for the
        // prepared period, so a re-prepare rebuilds them rather than reusing a
        // different-sized buffer.
        self.send_strips.clear();
        self.rebuild_send_strips();
        self.clip_position = self.control.seek_frames();
        self.clip_loop = self.loop_bounds;
        Ok(())
    }

    fn block(&mut self, out: &mut [f32]) -> Result<(), String> {
        if self.control.is_stopping() {
            return Err("stopped".to_string());
        }
        // The transport is the only producer of this buffer, so it starts each
        // block silent rather than trusting what the previous block left.
        out.fill(0.0);
        if out.len() % 2 != 0 {
            return Err(format!(
                "the transport block must hold whole stereo frames, found {} samples",
                out.len()
            ));
        }
        let frames = out.len() / 2;
        if self.click.is_none() {
            return Err("the transport was not prepared".to_string());
        }
        if frames > self.period {
            return Err(format!(
                "a {frames}-frame block is longer than the prepared {} frames",
                self.period
            ));
        }

        // A take that started or stopped beside this transport sends one edge;
        // applying it here keeps the device open and the clips and click steady.
        let live_edge = match self.live_rx.as_ref() {
            Some(live) => {
                let mut latest = None;
                while let Ok(edge) = live.try_recv() {
                    latest = Some(edge);
                }
                latest
            }
            None => None,
        };
        if let Some(edge) = live_edge {
            self.apply_live(edge);
        }

        // A plan from the control thread (a take moved, trimmed, split, deleted
        // or added) replaces the placement at this block edge. The plan carries
        // decoded takes, so the render thread reads nothing from disk; only the
        // newest queued plan is applied, because each one is the whole set.
        let pending = match self.plan_rx.as_ref() {
            Some(plans) => {
                let mut latest = None;
                while let Ok(plan) = plans.try_recv() {
                    latest = Some(plan);
                }
                latest
            }
            None => None,
        };
        if let Some(plan) = pending {
            self.apply_plan(plan);
        }

        // Note edges from the page are drained in order and applied before the
        // synth renders this block, so a note-on is heard on the block's first
        // frame. `try_recv` never blocks and applying an edge allocates nothing.
        loop {
            let edge = match self.note_rx.as_ref() {
                Some(notes) => notes.try_recv().ok(),
                None => None,
            };
            let Some(edge) = edge else { break };
            self.apply_note(edge);
        }
        // One-shot hits land on the loaded machine's first frame. A transport
        // with no chart drops them; it has no kit to render.
        loop {
            let hit = match self.hit_rx.as_ref() {
                Some(hits) => hits.try_recv().ok(),
                None => None,
            };
            let Some(hit) = hit else { break };
            self.apply_hit(hit);
        }

        // The click's cursor is the transport's absolute song frame at this
        // block's first frame; the drums schedule against the same grid and
        // wrap at the same loop bounds. The borrow is scoped so the drum and
        // clip passes can borrow their own fields below.
        let song_start = {
            let click = self.click.as_mut().expect("the transport was prepared above");

            // A seek is applied before tempo or loop changes so a `start` that
            // carries all three lands on the new position with the new grid.
            let seq = self.control.seek_seq();
            let mut reanchor_drums = false;
            if seq != self.seek_seq {
                self.seek_seq = seq;
                click.seek(self.control.seek_frames());
                // The clip timeline jumps with the click, and the strips forget
                // their tails so a seek does not carry the old place's reverb.
                self.clip_position = self.control.seek_frames();
                self.mixer.reset();
                reanchor_drums = true;
            }
            let bpm_bits = self.control.bpm_bits();
            if bpm_bits != self.bpm_bits {
                self.bpm_bits = bpm_bits;
                click.set_tempo(f64::from_bits(bpm_bits));
                reanchor_drums = true;
            }
            let beats = self.control.beats_per_bar();
            if beats != self.beats_per_bar {
                self.beats_per_bar = beats;
                click.set_beats_per_bar(beats);
            }
            let gain_bits = self.control.gain_bits();
            if gain_bits != self.gain_bits {
                self.gain_bits = gain_bits;
                click.set_gain(f32::from_bits(gain_bits));
            }
            let loop_bounds = (self.control.loop_start(), self.control.loop_end());
            if loop_bounds != self.loop_bounds {
                self.loop_bounds = loop_bounds;
                click.set_loop(loop_bounds.0, loop_bounds.1);
                self.clip_loop = loop_bounds;
            }
            // A seek or a tempo change moves the click's absolute grid; the
            // chart follows the same sixteenth grid, so it re-reads it at the
            // position the click just anchored.
            if reanchor_drums {
                if let Some(render) = self.drum_render.as_mut() {
                    // A seek to the same place hears the same pass: the
                    // player's wobble is a function of the step since the
                    // chart's origin, not of how many loops have run.
                    render.steps_played = 0;
                    render.align_to(
                        click.position(),
                        drum_step_frames(self.rate, f64::from_bits(self.bpm_bits)),
                    );
                }
            }
            click.position()
        };

        // Sources are summed here rather than by `mix_with_live_and_extra`,
        // because a clip or an app tap may name a Studio channel with an output
        // cord. Each source's panned stereo block goes to its channel's own
        // block (post-fader, post-pan, after its inserts) or straight to the
        // pre-master bus. The destination graph then runs upstream first: a
        // channel's incoming sum takes its fader and inserts — never its pan —
        // and its total either moves to the next channel or joins the
        // pre-master bus. The take's live input joins that bus at its armed
        // gain and is never sent. One master pass covers the whole sum, and the
        // click is added after it, exactly as it is for a take's monitor.
        let has_clips = !self.clips.is_empty();
        let has_live = self.live.is_some();
        let has_drums = self.drum_render.is_some();
        let has_synth = self.synth.is_some();
        if has_clips || has_live || has_drums || has_synth {
            // The drum machine schedules this block's steps and renders once,
            // before the mix reads every bus; `trigger_at` places a step at its
            // own frame inside the block. The synth renders after the note
            // edges above, once for the whole block.
            if has_drums {
                self.render_drums(song_start, frames);
            }
            if has_synth {
                self.render_synth(frames);
            }
            let TransportSource {
                clips,
                mixer,
                voices,
                live,
                live_block,
                clip_position,
                clip_loop,
                drum_render,
                drum_stereo,
                synth_strips,
                synth_stereo,
                pre_master,
                clip_stereo,
                send_strips,
                send_order,
                ..
            } = self;
            if has_clips {
                let mut position = *clip_position;
                for frame in 0..frames {
                    for (index, clip) in clips.iter().enumerate() {
                        voices[index][frame] = match clip.source_at(position) {
                            Some(at) => clip.samples[at] * clip.edge_gain(position),
                            None => 0.0,
                        };
                    }
                    // The clip timeline wraps on the same frame as the click,
                    // so a loop repeats the section in time with the metronome.
                    position += 1;
                    if clip_loop.1 > clip_loop.0 && position >= clip_loop.1 {
                        let length = clip_loop.1 - clip_loop.0;
                        position = clip_loop.0 + (position - clip_loop.1) % length;
                    }
                }
                *clip_position = position;
            }
            // Pop the live ring once per block and trim it at the armed gain.
            // A short ring is zero-filled by the consumer, and a gain of zero
            // is true silence, exactly as the take's own monitor does it.
            let live_samples = match live.as_mut() {
                Some(live) => {
                    let samples = frames * 2;
                    live.consumer.pop(&mut live_block[..samples]);
                    let gain = f32::from_bits(live.gain.load(Ordering::Acquire));
                    if gain == 0.0 {
                        live_block[..samples].fill(0.0);
                    } else if gain != 1.0 {
                        for sample in &mut live_block[..samples] {
                            *sample *= gain;
                        }
                    }
                    Some(&live_block[..samples])
                }
                None => None,
            };
            let samples = frames * 2;
            // The pre-master bus and every channel block start silent, so a
            // source that stops cannot leave last block's material behind.
            pre_master[..samples].fill(0.0);
            for strip in send_strips.iter_mut() {
                strip.clear(frames);
            }
            // Each clip's strip writes its panned block, which follows its
            // channel's cord or joins the master directly.
            if has_clips {
                for (index, clip) in clips.iter().enumerate() {
                    mixer.tracks_mut()[index]
                        .channel
                        .process(&voices[index][..frames], &mut clip_stereo[..samples])
                        .map_err(|error| format!("track {index}: {error:?}"))?;
                    match clip.channel {
                        Some(channel) => {
                            let strip = send_strips
                                .iter_mut()
                                .find(|strip| strip.channel == channel)
                                .ok_or_else(|| {
                                    format!("clip {index} names channel {channel}, which has no strip")
                                })?;
                            add_stereo(&mut strip.own[..samples], &clip_stereo[..samples]);
                        }
                        None => add_stereo(&mut pre_master[..samples], &clip_stereo[..samples]),
                    }
                }
            }
            // Each app source follows the taps it is patched into; a tap with a
            // channel feeds that channel's own block, a tap without one joins
            // the pre-master bus, and an empty routing is the unpatched wire.
            if has_drums {
                if let Some(render) = drum_render.as_mut() {
                    route_app_source(
                        &mut render.strips,
                        &drum_stereo[..samples],
                        frames,
                        &mut pre_master[..samples],
                        send_strips,
                    )?;
                }
            }
            if has_synth {
                route_app_source(
                    synth_strips,
                    &synth_stereo[..samples],
                    frames,
                    &mut pre_master[..samples],
                    send_strips,
                )?;
            }
            // One destination per source and no cycle, so this walk visits each
            // strip once, upstream before downstream. `clip_stereo` is free
            // here and carries the total between channels.
            for step in 0..send_order.len() {
                let index = send_order[step];
                send_strips[index].shape_incoming(frames)?;
                send_strips[index].total_into(frames, &mut clip_stereo[..samples]);
                match send_strips[index].next {
                    Some(next) => {
                        add_stereo(&mut send_strips[next].incoming[..samples], &clip_stereo[..samples]);
                    }
                    None => add_stereo(&mut pre_master[..samples], &clip_stereo[..samples]),
                }
            }
            // The live monitor path is not sent: it joins the pre-master sum
            // after every channel and before the one mastering pass.
            if let Some(live) = live_samples {
                add_stereo(&mut pre_master[..samples], live);
            }
            out[..samples].copy_from_slice(&pre_master[..samples]);
            mixer
                .run_master(&mut out[..samples])
                .map_err(|error| format!("transport: {error}"))?;
        }

        {
            let click = self.click.as_mut().expect("the transport was prepared above");
            click.render_absolute_into(out);
            self.control.store_position(click.position());
        }
        Ok(())
    }
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
    use jawn_drums::Player;

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

    // --- transport: the absolute song grid -----------------------------------

    /// A 4000-frame block at 8 kHz, interleaved stereo.
    const TRANSPORT_BLOCK: usize = 8_000;

    fn transport(
        bpm: f64,
        position: u64,
        loop_start: u64,
        loop_end: u64,
    ) -> (Arc<TransportControl>, TransportSource) {
        let control = Arc::new(TransportControl::new(
            click_spec(bpm, 4, 1.0),
            position,
            loop_start,
            loop_end,
        ));
        let source = TransportSource::new(Arc::clone(&control));
        (control, source)
    }

    #[test]
    fn a_transport_started_mid_bar_waits_for_the_next_absolute_beat() {
        // 120 bpm at 8 kHz is 4000 frames per beat. Position 10000 is halfway
        // through beat 2; the next grid beat is beat 3 at frame 12000, not a
        // click on the first frame of this playback.
        let (_, mut source) = transport(120.0, 10_000, 0, 0);
        source.prepared(8_000, 4_000).expect("prepare");
        let mut block = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut block).expect("block");

        assert!(
            block[..4_000].iter().all(|sample| sample.abs() < 1e-9),
            "a mid-bar start clicked before its next beat"
        );
        assert!(peak(&block[4_000..4_640]) > 0.3, "no click on the next beat");
    }

    #[test]
    fn a_transport_accent_follows_the_absolute_bar_not_the_start() {
        let (_, mut source) = transport(120.0, 0, 0, 0);
        source.prepared(8_000, 4_000).expect("prepare");
        let mut peaks = Vec::new();
        for _ in 0..8 {
            let mut block = vec![0.0f32; TRANSPORT_BLOCK];
            source.block(&mut block).expect("block");
            peaks.push(peak(&block[..320]));
        }
        assert!(peaks[0] > peaks[1] * 1.15, "beat 0 is not accented: {peaks:?}");
        assert!(peaks[4] > peaks[1] * 1.15, "bar two lost its accent: {peaks:?}");
        for beat in [1, 2, 3, 5, 6, 7] {
            assert!(peaks[beat] < peaks[0] * 0.9, "beat {beat} is accented: {peaks:?}");
        }
    }

    #[test]
    fn a_transport_loop_wraps_the_position_and_the_bar_phase() {
        // Two beats per loop at 120 bpm: 0..8000. After the wrap the click is
        // back on absolute beat 0, so the loop's downbeat stays a downbeat.
        let (control, mut source) = transport(120.0, 0, 0, 8_000);
        source.prepared(8_000, 4_000).expect("prepare");

        let mut first = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut first).expect("block");
        let mut second = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut second).expect("block");
        let mut third = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut third).expect("block");

        assert!(peak(&first[..320]) > 0.3, "no downbeat at position 0");
        assert!(peak(&second[..320]) > 0.3, "no click on the loop's second beat");
        assert!(peak(&third[..320]) > 0.3, "no click after the loop wrapped");
        assert!(third[320..].iter().all(|sample| sample.abs() < 1e-9));
        assert_eq!(control.position(), 4_000, "the wrapped position is wrong");
    }

    #[test]
    fn a_transport_seek_moves_the_grid_to_the_new_position() {
        let (control, mut source) = transport(120.0, 0, 0, 0);
        source.prepared(8_000, 4_000).expect("prepare");
        let mut first = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut first).expect("block");
        assert!(peak(&first[..320]) > 0.3);

        // 6000 is halfway through beat 1; the next grid beat is 8000, which is
        // frame 2000 of the next block.
        control.seek(6_000);
        let mut second = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut second).expect("block");
        assert!(
            second[..4_000].iter().all(|sample| sample.abs() < 1e-9),
            "the seek clicked before the next absolute beat"
        );
        assert!(peak(&second[4_000..4_640]) > 0.3, "no click after the seek");
        assert_eq!(control.position(), 10_000);
    }

    #[test]
    fn a_seek_survives_a_stale_position_published_by_the_render_thread() {
        // The render thread publishes its position every block. A seek that
        // arrives just before that store must still land on its own target:
        // the target lives in its own word, so a stale publish cannot erase it.
        let (control, mut source) = transport(120.0, 0, 0, 0);
        source.prepared(8_000, 4_000).expect("prepare");
        control.seek(6_000);
        control.store_position(2_000);

        let mut block = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut block).expect("block");
        assert!(
            block[..4_000].iter().all(|sample| sample.abs() < 1e-9),
            "the stale publish moved the seek back"
        );
        assert!(peak(&block[4_000..4_640]) > 0.3, "the seek target was lost");
        assert_eq!(control.position(), 10_000);
    }

    #[test]
    fn a_retune_at_the_playhead_is_not_a_seek() {
        // A tempo, loop or metronome knob sends the position the transport is
        // already at. Honouring it would reset every strip's tail and restart
        // the drum chart on every knob turn, so a move this small is ignored.
        let (control, mut source) = transport(120.0, 0, 0, 0);
        source.prepared(8_000, 4_000).expect("prepare");
        let mut block = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut block).expect("block");
        let played = control.position();
        let seq = control.seek_seq();

        control.seek(played + 40);
        assert_eq!(control.seek_seq(), seq, "a 5 ms move restarted the transport");
        control.seek(played);
        assert_eq!(control.seek_seq(), seq, "the playhead itself restarted it");

        control.seek(played + 4_000);
        assert_ne!(control.seek_seq(), seq, "a half-second seek was ignored");
    }

    #[test]
    fn a_transport_tempo_change_is_read_at_the_next_block() {
        let (control, mut source) = transport(120.0, 0, 0, 0);
        source.prepared(8_000, 4_000).expect("prepare");
        let mut first = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut first).expect("block");

        // 240 bpm at 8 kHz is 2000 frames per beat. Position 4000 is now
        // exactly absolute beat 2, so the grid re-seats on the downbeat and
        // the next block starts on it without reopening the device.
        control.set_tempo(240.0, 4, 1.0);
        let mut second = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut second).expect("block");
        assert!(peak(&second[..320]) > 0.3, "the new grid did not sound");
        assert_eq!(control.position(), 8_000);
    }

    #[test]
    fn a_transport_gain_change_silences_the_next_block() {
        // The render thread reads the click trim at the top of every block, so
        // the browser's metronome knob can move mid-song without reopening the
        // device. A zero trim is the metronome-off state, and it must silence
        // the very next beat, not the one after it.
        let (control, mut source) = transport(120.0, 0, 0, 0);
        source.prepared(8_000, 4_000).expect("prepare");
        let mut first = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut first).expect("block");
        assert!(peak(&first[..320]) > 0.3, "the first downbeat did not sound");

        // Same tempo and signature, gain to zero. Position 8000 is beat 2, so
        // this block would click on its first frame if the trim were stale.
        control.set_tempo(120.0, 4, 0.0);
        let mut second = vec![0.0f32; TRANSPORT_BLOCK];
        source.block(&mut second).expect("block");
        assert!(
            second.iter().all(|sample| sample.abs() < 1e-9),
            "the gain change did not silence the next block"
        );
        assert_eq!(control.position(), 8_000);
    }

    // --- transport clips: recorded takes on the same timeline ----------------

    fn clip(samples: Vec<f32>, start: i64, duration: u64, looped: bool) -> TransportClip {
        TransportClip {
            path: "take.wav".to_string(),
            rate: 8_000,
            samples: Arc::from(samples),
            start,
            offset: 0,
            duration,
            gain: 1.0,
            // Hard left keeps the expected samples exact: the strip's equal
            // power pan puts all of a hard-left source in the left channel.
            pan: -1.0,
            looped,
            fade_in: 0,
            fade_out: 0,
            inserts: Vec::new(),
            channel: None,
        }
    }

    fn clip_transport(
        clips: Vec<TransportClip>,
        position: u64,
        loop_start: u64,
        loop_end: u64,
        period: usize,
    ) -> (Arc<TransportControl>, TransportSource) {
        clip_transport_with(clips, Vec::new(), position, loop_start, loop_end, period)
    }

    fn clip_transport_with(
        clips: Vec<TransportClip>,
        master: Vec<InsertKind>,
        position: u64,
        loop_start: u64,
        loop_end: u64,
        period: usize,
    ) -> (Arc<TransportControl>, TransportSource) {
        let control = Arc::new(TransportControl::new(
            click_spec(120.0, 4, 0.0),
            position,
            loop_start,
            loop_end,
        ));
        let mut source = TransportSource::new(Arc::clone(&control))
            .with_clips(clips)
            .with_master(master);
        source.prepared(8_000, period).expect("prepare");
        (control, source)
    }

    fn left_channel(out: &[f32]) -> Vec<f32> {
        out.chunks_exact(2).map(|frame| frame[0]).collect()
    }

    fn right_channel(out: &[f32]) -> Vec<f32> {
        out.chunks_exact(2).map(|frame| frame[1]).collect()
    }

    /// A clip that names a Studio channel, with its own fader, pan and Out
    /// inserts. `samples` fill the whole prepared block from frame zero.
    fn routed_clip(
        samples: Vec<f32>,
        channel: usize,
        gain: f32,
        pan: f32,
        inserts: Vec<InsertKind>,
    ) -> TransportClip {
        let duration = samples.len() as u64;
        let mut clip = clip(samples, 0, duration, false);
        clip.channel = Some(channel);
        clip.gain = gain;
        clip.pan = pan;
        clip.inserts = inserts;
        clip
    }

    /// A silent clip on a channel. Its own audio contributes nothing, but the
    /// fader and inserts it carries are the channel's strip, which a send into
    /// that channel runs through.
    fn silent_clip(channel: usize, gain: f32, inserts: Vec<InsertKind>) -> TransportClip {
        routed_clip(vec![0.0; 8], channel, gain, 0.0, inserts)
    }

    /// A transport with an output-cord graph and no click, prepared at 8 kHz.
    fn send_transport(
        clips: Vec<TransportClip>,
        sends: Vec<(usize, usize)>,
        period: usize,
    ) -> TransportSource {
        let control = Arc::new(TransportControl::new(click_spec(120.0, 4, 0.0), 0, 0, 0));
        let mut source = TransportSource::new(control)
            .with_clips(clips)
            .with_sends(sends);
        source.prepared(8_000, period).expect("prepare");
        source
    }

    fn block_once(source: &mut TransportSource, period: usize) -> Vec<f32> {
        let mut out = vec![0.0f32; period * 2];
        source.block(&mut out).expect("block");
        out
    }

    #[test]
    fn a_transport_clip_plays_at_its_timeline_start() {
        // Four loud frames placed at timeline frame 2: silent before, loud
        // across 2..=5, silent after 6 in an eight-frame block.
        let (_, mut source) = clip_transport(
            vec![clip(vec![1.0; 4], 2, 4, false)],
            0,
            0,
            0,
            8,
        );
        let mut out = vec![0.0f32; 16];
        source.block(&mut out).expect("block");
        let left = left_channel(&out);
        for (frame, sample) in left.iter().enumerate() {
            if (2..6).contains(&frame) {
                assert!((sample - 1.0).abs() < 1e-6, "frame {frame}: {left:?}");
            } else {
                assert!(sample.abs() < 1e-9, "frame {frame} should be silent: {left:?}");
            }
        }
    }

    /// A source with a plan channel attached before `prepared`, which is the
    /// shape `transport start` builds for a running device.
    fn clip_transport_with_plan(
        clips: Vec<TransportClip>,
        period: usize,
    ) -> (
        std::sync::mpsc::Sender<TransportPlan>,
        Arc<TransportControl>,
        TransportSource,
    ) {
        let control = Arc::new(TransportControl::new(
            click_spec(120.0, 4, 0.0),
            0,
            0,
            0,
        ));
        let (plans, rx) = std::sync::mpsc::channel();
        let mut source = TransportSource::new(Arc::clone(&control))
            .with_clips(clips)
            .with_plan_rx(rx);
        source.prepared(8_000, period).expect("prepare");
        (plans, control, source)
    }

    /// The same, with a master rack and its knob positions, for a test that
    /// moves one knob through a value-only plan.
    fn clip_transport_with_values(
        clips: Vec<TransportClip>,
        master: Vec<InsertKind>,
        values: Vec<(String, f32)>,
        period: usize,
    ) -> (
        std::sync::mpsc::Sender<TransportPlan>,
        Arc<TransportControl>,
        TransportSource,
    ) {
        let control = Arc::new(TransportControl::new(
            click_spec(120.0, 4, 0.0),
            0,
            0,
            0,
        ));
        let (plans, rx) = std::sync::mpsc::channel();
        let mut source = TransportSource::new(Arc::clone(&control))
            .with_clips(clips)
            .with_master(master)
            .with_master_values(values)
            .with_plan_rx(rx);
        source.prepared(8_000, period).expect("prepare");
        (plans, control, source)
    }

    #[test]
    fn a_transport_plan_update_moves_and_trims_a_clip_without_reopening() {
        // Eight frames on one timeline, four frames per block. The initial plan
        // starts at zero, so block one hears frames 1..4 and block two 5..8.
        let samples = vec![1.0f32, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
        let (plans, _, mut source) =
            clip_transport_with_plan(vec![clip(samples.clone(), 0, 8, false)], 4);
        let mut first = vec![0.0f32; 8];
        source.block(&mut first).expect("block");
        assert_eq!(left_channel(&first), vec![1.0, 2.0, 3.0, 4.0]);

        // Move the same take four frames later: a placement-only change, so the
        // strip and its voices are kept and the new start is heard at once.
        plans
            .send(TransportPlan {
                clips: Some(vec![clip(samples.clone(), 4, 8, false)]),
                master: None,
                master_values: None,
                drums: None,
                synth: None,

                sends: None,
            })
            .expect("send the moved plan");
        let mut second = vec![0.0f32; 8];
        source.block(&mut second).expect("block");
        assert_eq!(
            left_channel(&second),
            vec![1.0, 2.0, 3.0, 4.0],
            "the moved clip did not play from its new start"
        );

        // Trim its end to the half already heard: block three is past it, so a
        // removed span stops sounding at the very next block.
        plans
            .send(TransportPlan {
                clips: Some(vec![clip(samples, 4, 4, false)]),
                master: None,
                master_values: None,
                drums: None,
                synth: None,

                sends: None,
            })
            .expect("send the trimmed plan");
        let mut third = vec![0.0f32; 8];
        source.block(&mut third).expect("block");
        assert!(
            third.iter().all(|sample| sample.abs() < 1e-9),
            "the trimmed take still sounded: {:?}",
            left_channel(&third)
        );
        // The same source and unbroken timeline prove the device was not
        // stopped and reopened: its position advanced by three blocks.
        assert_eq!(source.clip_count(), 1);
    }

    #[test]
    fn a_transport_plan_update_that_removes_a_clip_silences_it_next_block() {
        let (plans, _, mut source) = clip_transport_with_plan(
            vec![clip(vec![1.0; 4], 0, 4, false)],
            4,
        );
        let mut first = vec![0.0f32; 8];
        source.block(&mut first).expect("block");
        assert_eq!(left_channel(&first), vec![1.0; 4]);

        // The plan is now empty. That changes the clip count, so the strips are
        // rebuilt once at this block edge and the take stops sounding.
        plans
            .send(TransportPlan {
                clips: Some(Vec::new()),
                master: None,
                master_values: None,
                drums: None,
                synth: None,

                sends: None,
            })
            .expect("send the empty plan");
        let mut second = vec![0.0f32; 8];
        source.block(&mut second).expect("block");
        assert!(
            second.iter().all(|sample| sample.abs() < 1e-9),
            "a deleted take kept sounding: {:?}",
            left_channel(&second)
        );
        assert_eq!(source.clip_count(), 0);
    }

    #[test]
    fn a_looping_transport_clip_repeats_every_duration() {
        // The four-frame sample repeats across a twelve-frame block.
        let (_, mut source) = clip_transport(
            vec![clip(vec![1.0, 2.0, 3.0, 4.0], 0, 4, true)],
            0,
            0,
            0,
            12,
        );
        let mut out = vec![0.0f32; 24];
        source.block(&mut out).expect("block");
        let left = left_channel(&out);
        for (frame, sample) in left.iter().enumerate() {
            let expected = (frame % 4 + 1) as f32;
            assert!((sample - expected).abs() < 1e-6, "frame {frame}: {left:?}");
        }
    }

    #[test]
    fn a_transport_loop_restarts_the_clip_inside_the_region() {
        // The clip covers the looped region 4..8, so both passes sound. The
        // wrap moves the clip timeline with the click, not past it.
        let (_, mut source) = clip_transport(
            vec![clip(vec![1.0, 2.0, 3.0, 4.0], 4, 4, false)],
            4,
            4,
            8,
            8,
        );
        let mut out = vec![0.0f32; 16];
        source.block(&mut out).expect("block");
        let left = left_channel(&out);
        let expected = [1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 4.0];
        for (frame, sample) in left.iter().enumerate() {
            assert!(
                (sample - expected[frame]).abs() < 1e-6,
                "frame {frame}: {left:?}"
            );
        }
    }

    #[test]
    fn a_transport_clip_runs_through_its_output_insert() {
        // A dry clip keeps a full-scale sample. The default limiter holds it at
        // its -3 dBFS ceiling, so the smaller peak proves the clip's Out chain
        // was built on the engine strip, not just recorded.
        let mut take = clip(vec![1.0; 4], 0, 4, false);
        take.inserts = vec![InsertKind::Limiter];
        let (_, mut source) = clip_transport(vec![take], 0, 0, 0, 4);
        let mut out = vec![0.0f32; 8];
        source.block(&mut out).expect("block");
        let ceiling = 10f32.powf(-3.0 / 20.0);
        for (frame, sample) in left_channel(&out).iter().enumerate() {
            assert!(
                (sample - ceiling).abs() < 1e-5,
                "frame {frame}: {out:?}"
            );
        }
    }

    #[test]
    fn a_transport_master_insert_masters_the_clip_mix() {
        // The clip has no insert of its own, so only the master rack can lower
        // it. The default maximizer drives a full-scale sample into its
        // -0.8 dBFS ceiling, which is what the browser's master bus would do.
        let (_, mut source) = clip_transport_with(
            vec![clip(vec![1.0; 4], 0, 4, false)],
            vec![InsertKind::Maximizer],
            0,
            0,
            0,
            4,
        );
        let mut out = vec![0.0f32; 8];
        source.block(&mut out).expect("block");
        let ceiling = 10f32.powf(-0.8 / 20.0);
        for (frame, sample) in left_channel(&out).iter().enumerate() {
            assert!(
                (sample - ceiling).abs() < 1e-5,
                "frame {frame}: {out:?}"
            );
        }
    }

    #[test]
    fn a_transport_master_knob_change_is_heard_at_the_next_block() {
        // The limiter's ceiling starts wide open, so the first block is a clean
        // full-scale take. A value-only plan at the next edge pulls it to
        // -12 dBFS: the take keeps playing (the plan carries no clips) and the
        // rack is not rebuilt, so its state moves rather than restarts.
        let (plans, _, mut source) = clip_transport_with_values(
            vec![clip(vec![1.0; 2_000], 0, 2_000, false)],
            vec![InsertKind::Limiter],
            vec![("master_limiter.ceiling".to_string(), 0.0)],
            400,
        );
        let mut first = vec![0.0f32; 800];
        source.block(&mut first).expect("block");
        let first_left = left_channel(&first);
        assert!(
            first_left
                .iter()
                .all(|sample| (sample.abs() - 1.0).abs() < 1e-5),
            "the open ceiling already limited the take: {first_left:?}"
        );

        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: Some(vec![("master_limiter.ceiling".to_string(), -12.0)]),
                drums: None,
                synth: None,

                sends: None,
            })
            .expect("send the knob plan");
        let mut second = vec![0.0f32; 800];
        source.block(&mut second).expect("block");
        let second_left = left_channel(&second);
        assert!(
            second_left.iter().all(|sample| sample.abs() > 0.1),
            "the value-only plan silenced the take: {second_left:?}"
        );
        assert!(
            second_left.last().copied().unwrap_or(1.0) < 0.4,
            "the knob change was not heard at the next block: {second_left:?}"
        );

        // The ceiling smooths toward its target over the following edge, and
        // the take never stops sounding through it.
        let mut third = vec![0.0f32; 800];
        source.block(&mut third).expect("block");
        let mut fourth = vec![0.0f32; 800];
        source.block(&mut fourth).expect("block");
        let settled = left_channel(&fourth);
        let ceiling = 10f32.powf(-12.0 / 20.0);
        assert!(
            (settled.last().copied().unwrap_or(0.0) - ceiling).abs() < 1e-3,
            "the master knob did not settle at -12 dBFS: {settled:?}"
        );
    }

    #[test]
    fn a_transport_clip_that_starts_before_zero_hears_its_later_part() {
        // A negative start is a take pulled earlier to cancel latency. Its
        // first frames are before the timeline's zero, so a position of zero
        // already sits inside the clip.
        let (_, mut source) = clip_transport(
            vec![clip(vec![1.0, 2.0, 3.0, 4.0], -2, 4, false)],
            0,
            0,
            0,
            4,
        );
        let mut out = vec![0.0f32; 8];
        source.block(&mut out).expect("block");
        let left = left_channel(&out);
        let expected = [3.0, 4.0, 0.0, 0.0];
        for (frame, sample) in left.iter().enumerate() {
            assert!(
                (sample - expected[frame]).abs() < 1e-6,
                "frame {frame}: {left:?}"
            );
        }
    }

    // --- transport: a take's live input on the transport's own output --------

    /// A transport with no clips, the transport's click silent, and the take's
    /// live ring attached before the device opens.
    fn live_transport(
        consumer: crate::monbus::Consumer,
        gain: Arc<AtomicU32>,
        master: Vec<InsertKind>,
        period: usize,
    ) -> TransportSource {
        let control = Arc::new(TransportControl::new(
            click_spec(120.0, 4, 0.0),
            0,
            0,
            0,
        ));
        let mut source = TransportSource::new(control)
            .with_master(master)
            .with_live_input(consumer, gain);
        source.prepared(8_000, period).expect("prepare");
        source
    }

    #[test]
    fn a_transport_block_carries_the_live_input_at_its_armed_gain() {
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        let input = [0.5f32, -0.5, 0.25, -0.25, 1.0, 1.0, -1.0, -1.0];
        producer.push(&input);
        let mut source = live_transport(consumer, live_gain(0.5), Vec::new(), 4);
        let mut out = vec![0.0f32; 8];
        source.block(&mut out).expect("block");
        for (sample, expected) in out.iter().zip(input.iter()) {
            assert!(
                (sample - expected * 0.5).abs() < 1e-6,
                "the live trim did not reach the transport: {out:?}"
            );
        }
    }

    #[test]
    fn a_transport_with_no_clips_plus_a_live_input_renders() {
        // No clips at all: the ring alone must still reach the bus, which is the
        // click-only transport a take's live input joins beside the takes.
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        producer.push(&[0.25f32; 16]);
        let mut source = live_transport(consumer, live_gain(1.0), Vec::new(), 4);
        assert_eq!(source.clip_count(), 0);
        for _ in 0..2 {
            let mut out = vec![0.0f32; 8];
            source.block(&mut out).expect("block");
            assert!(
                out.iter().all(|sample| (sample - 0.25).abs() < 1e-6),
                "a clip-less transport did not render its live input: {out:?}"
            );
        }
    }

    #[test]
    fn a_transport_live_input_never_reaches_the_take_path() {
        // The transport is monitoring the live ring; the take's own path is the
        // capture mixer that feeds its DiskWriter. The same live block must not
        // leak into it.
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        producer.push(&[0.75f32; 8]);
        let mut source = live_transport(consumer, live_gain(1.0), Vec::new(), 4);
        let mut monitor = vec![0.0f32; 8];
        source.block(&mut monitor).expect("block");
        assert!(
            monitor.iter().all(|sample| (sample - 0.75).abs() < 1e-6),
            "the transport did not hear the live input: {monitor:?}"
        );

        // What the take writes is its capture block through its own strip, with
        // no ring in the path at all.
        let mut take = Mixer::new(&[0], &["ch1"]);
        take.prepare(8_000, 4);
        let mut recorded = vec![0.0f32; 8];
        take.process(0, &[0.0f32; 4], &mut recorded)
            .expect("take block");
        assert!(
            recorded.iter().all(|sample| *sample == 0.0),
            "the take path saw the transport's live input: {recorded:?}"
        );
    }

    #[test]
    fn a_transport_live_input_detaches_to_silence() {
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        let control = Arc::new(TransportControl::new(
            click_spec(120.0, 4, 0.0),
            0,
            0,
            0,
        ));
        let (live_tx, live_rx) = std::sync::mpsc::channel();
        let mut source = TransportSource::new(control).with_live_rx(live_rx);
        source.prepared(8_000, 4).expect("prepare");

        producer.push(&[0.5f32; 8]);
        live_tx
            .send(TransportLive::Attach {
                consumer,
                gain: live_gain(1.0),
            })
            .expect("attach the live input");
        let mut first = vec![0.0f32; 8];
        source.block(&mut first).expect("block");
        assert!(
            first.iter().all(|sample| (sample - 0.5).abs() < 1e-6),
            "the attached live input did not sound: {first:?}"
        );

        live_tx.send(TransportLive::Detach).expect("detach");
        let mut second = vec![0.0f32; 8];
        source.block(&mut second).expect("block");
        assert!(
            second.iter().all(|sample| *sample == 0.0),
            "the detached live input still sounded: {second:?}"
        );
    }

    // --- transport drums: the native machine on the song grid ---------------

    /// A chart from sparse rows: one velocity list per voice.
    fn drum_chart(
        kit: Kit,
        length: usize,
        looped: bool,
        rows: &[(Voice, &[u8])],
    ) -> DrumChart {
        let mut steps = vec![[0u8; Voice::COUNT]; length];
        for (voice, cells) in rows {
            for (step, velocity) in cells.iter().take(length).enumerate() {
                steps[step][voice.index()] = *velocity;
            }
        }
        DrumChart::new(kit, length, looped, steps)
    }

    fn drum_transport(
        rate: u32,
        bpm: f64,
        position: u64,
        loop_start: u64,
        loop_end: u64,
        chart: DrumChart,
        period: usize,
    ) -> (Arc<TransportControl>, TransportSource) {
        let control = Arc::new(TransportControl::new(
            click_spec(bpm, 4, 0.0),
            position,
            loop_start,
            loop_end,
        ));
        let mut source = TransportSource::new(Arc::clone(&control)).with_drums(chart);
        source.prepared(rate, period).expect("prepare");
        (control, source)
    }

    fn first_audible(samples: &[f32], threshold: f32) -> Option<usize> {
        samples.iter().position(|sample| sample.abs() > threshold)
    }

    fn drum_block(source: &mut TransportSource, frames: usize) -> Vec<f32> {
        let mut out = vec![0.0f32; frames * 2];
        source.block(&mut out).expect("block");
        out
    }

    #[test]
    fn a_drum_step_zero_lands_on_the_transport_start() {
        // A kick on step 0 is the transport's start frame itself: the block
        // that contains frame 0 carries the onset within a few frames (the
        // voice's own attack, never a step late).
        let chart = drum_chart(Kit::Acoustic, 4, true, &[(Voice::Kick, &[100, 0, 0, 0])]);
        let (_, mut source) = drum_transport(8_000, 120.0, 0, 0, 0, chart, 64);
        let left = left_channel(&drum_block(&mut source, 64));
        let onset = first_audible(&left, 1e-6).expect("the kick on step 0 never sounded");
        assert!(onset <= 8, "the step 0 onset was at frame {onset}");
    }

    #[test]
    fn a_player_sits_behind_the_grid_and_softens_the_hit() {
        // The same chart, once as written and once through Tuck at his own
        // (soft) style. The player delays the onset and lowers the peak; the
        // grid still decides which steps fire.
        let plain = drum_chart(Kit::Acoustic, 4, true, &[(Voice::Kick, &[100, 0, 0, 0])]);
        let played = plain.clone().with_performance(Performance::of(Player::Tuck));
        let (_, mut a) = drum_transport(48_000, 120.0, 0, 0, 0, plain, 12_000);
        let (_, mut b) = drum_transport(48_000, 120.0, 0, 0, 0, played, 12_000);
        let plain_block = left_channel(&drum_block(&mut a, 12_000));
        let played_block = left_channel(&drum_block(&mut b, 12_000));
        let plain_onset = first_audible(&plain_block, 1e-6).expect("the plain kick never sounded");
        let played_onset = first_audible(&played_block, 1e-6).expect("the played kick never sounded");
        assert!(
            played_onset >= plain_onset + 400,
            "Tuck should sit ~13 ms back: plain {plain_onset}, played {played_onset}"
        );
        assert!(
            peak(&played_block) < peak(&plain_block),
            "a soft player should not hit as hard: {} vs {}",
            peak(&played_block),
            peak(&plain_block)
        );
    }

    #[test]
    fn a_drum_chart_is_silent_before_its_first_sounding_step() {
        // Step 0 is empty and step 1 is the kick (1000 frames at 8 kHz, 120 bpm),
        // so the whole first block is silence and the next block opens on it.
        let chart = drum_chart(Kit::Acoustic, 4, true, &[(Voice::Kick, &[0, 100, 0, 0])]);
        let (_, mut source) = drum_transport(8_000, 120.0, 0, 0, 0, chart, 1_000);
        let first = drum_block(&mut source, 1_000);
        assert!(
            first.iter().all(|sample| sample.abs() < 1e-9),
            "the chart sounded before its first step"
        );
        let second = left_channel(&drum_block(&mut source, 1_000));
        let onset = first_audible(&second, 1e-6).expect("the first sounding step never arrived");
        assert!(onset <= 8, "the step 1 onset was at frame {onset}");
    }

    #[test]
    fn a_drum_step_at_a_sixteenth_lands_at_frame_6000() {
        // 48 kHz at 120 bpm: one sixteenth is 48000 * 60 / 120 / 4 = 6000
        // frames, so the chart's second step starts exactly there.
        let chart = drum_chart(Kit::Acoustic, 4, true, &[(Voice::Kick, &[0, 100, 0, 0])]);
        let (_, mut source) = drum_transport(48_000, 120.0, 0, 0, 0, chart, 12_000);
        let left = left_channel(&drum_block(&mut source, 12_000));
        let onset = first_audible(&left, 1e-6).expect("the second sixteenth never sounded");
        assert!(
            (onset as i64 - 6_000).abs() <= 8,
            "the sixteenth landed at frame {onset}, not 6000"
        );
    }

    #[test]
    fn a_velocity_zero_drum_row_is_silent() {
        let chart = drum_chart(Kit::Acoustic, 4, true, &[(Voice::Kick, &[0, 0, 0, 0])]);
        let (_, mut source) = drum_transport(8_000, 120.0, 0, 0, 0, chart, 1_000);
        for pass in 0..4 {
            let out = drum_block(&mut source, 1_000);
            assert!(
                out.iter().all(|sample| sample.abs() < 1e-9),
                "a zero-velocity row sounded (pass {pass})"
            );
        }
    }

    #[test]
    fn a_one_shot_drum_chart_plays_once() {
        // Two steps, a rim on step 0, no loop. The rim is short enough to die
        // inside its own step, so the empty step 1 and the blocks after it are
        // true silence.
        let chart = drum_chart(Kit::Acoustic, 2, false, &[(Voice::Rim, &[100, 0])]);
        let (_, mut source) = drum_transport(8_000, 120.0, 0, 0, 0, chart, 1_000);
        let first = left_channel(&drum_block(&mut source, 1_000));
        assert!(first_audible(&first, 1e-6).is_some(), "the one-shot chart did not start");
        for pass in 0..2 {
            let out = drum_block(&mut source, 1_000);
            assert!(
                out.iter().all(|sample| sample.abs() < 1e-9),
                "a one-shot chart repeated (pass {pass})"
            );
        }
    }

    #[test]
    fn a_looping_drum_chart_wraps_to_its_first_step() {
        let chart = drum_chart(Kit::Acoustic, 2, true, &[(Voice::Rim, &[100, 0])]);
        let (_, mut source) = drum_transport(8_000, 120.0, 0, 0, 0, chart, 1_000);
        let first = left_channel(&drum_block(&mut source, 1_000));
        assert!(first_audible(&first, 1e-6).is_some(), "the chart did not start");
        let second = left_channel(&drum_block(&mut source, 1_000));
        assert!(
            first_audible(&second, 1e-6).is_none(),
            "the empty second step sounded"
        );
        let third = left_channel(&drum_block(&mut source, 1_000));
        let onset = first_audible(&third, 1e-6).expect("the looping chart did not wrap");
        assert!(onset <= 8, "the wrapped step 0 onset was at frame {onset}");
    }

    #[test]
    fn a_transport_loop_restarts_the_drum_chart_at_loop_start() {
        // A one-shot chart, so only the transport's own loop can restart it.
        // The loop is 0..2000 (two 1000-frame steps); the wrap lands at the end
        // of block 2 and step 0 sounds again at loop_start on block 3.
        let chart = drum_chart(
            Kit::Acoustic,
            8,
            false,
            &[(Voice::Rim, &[100, 0, 0, 0, 0, 0, 0, 0])],
        );
        let (_, mut source) = drum_transport(8_000, 120.0, 0, 0, 2_000, chart, 1_000);
        let first = left_channel(&drum_block(&mut source, 1_000));
        assert!(first_audible(&first, 1e-6).is_some(), "the chart did not start");
        let second = left_channel(&drum_block(&mut source, 1_000));
        assert!(
            first_audible(&second, 1e-6).is_none(),
            "step 1 should have been empty"
        );
        let third = left_channel(&drum_block(&mut source, 1_000));
        let onset = first_audible(&third, 1e-6).expect("the transport loop did not restart the chart");
        assert!(onset <= 8, "the restarted step 0 onset was at frame {onset}");
    }

    #[test]
    fn a_seek_joins_the_drum_chart_on_the_song_grid() {
        // Step 0 is empty and step 1 carries the rim. At 8 kHz and 120 bpm a
        // sixteenth is 1000 frames, so step 1 owns frames 1000..2000.
        let chart = drum_chart(
            Kit::Acoustic,
            8,
            true,
            &[(Voice::Rim, &[0, 100, 0, 0, 0, 0, 0, 0])],
        );
        let (control, mut source) = drum_transport(8_000, 120.0, 0, 0, 0, chart, 1_000);
        let first = left_channel(&drum_block(&mut source, 1_000));
        assert!(first_audible(&first, 1e-6).is_none(), "step 0 is empty");
        let second = left_channel(&drum_block(&mut source, 1_000));
        assert!(first_audible(&second, 1e-6).is_some(), "step 1 is the rim");
        // A seek to 500 lands half-way through step 0. The chart must wait for
        // the absolute step-1 boundary at frame 1000, not fire the rim at the
        // seek and lose the beat.
        control.seek(500);
        let after = left_channel(&drum_block(&mut source, 1_000));
        let onset = first_audible(&after, 1e-6).expect("the step after the seek never sounded");
        assert!(
            (onset as i64 - 500).abs() <= 8,
            "the rim landed at frame {onset}, not 500 frames into the seek"
        );
    }

    #[test]
    fn a_bpm_change_keeps_the_drum_cursor_and_moves_the_next_step() {
        // Step 0 is empty and step 1 carries the rim. At 120 bpm the next step
        // is 1000 frames after step 0; at 60 bpm it is 2000. The phase must not
        // jump, so the onset waits for the new sixteenth boundary.
        let chart = drum_chart(Kit::Acoustic, 4, true, &[(Voice::Rim, &[0, 100, 0, 0])]);
        let (control, mut source) = drum_transport(8_000, 120.0, 0, 0, 0, chart, 500);
        let first = drum_block(&mut source, 500);
        assert!(first.iter().all(|sample| sample.abs() < 1e-9));
        control.set_tempo(60.0, 4, 0.0);
        // Phases 500..2000 are still before the re-anchored 2000 boundary.
        for pass in 0..3 {
            let out = drum_block(&mut source, 500);
            assert!(
                out.iter().all(|sample| sample.abs() < 1e-9),
                "a step fired before the new sixteenth boundary (pass {pass})"
            );
        }
        let onset = first_audible(&left_channel(&drum_block(&mut source, 500)), 1e-6)
            .expect("the step did not land on the new sixteenth boundary");
        assert!(onset <= 8, "the new-boundary onset was at frame {onset}");
    }

    #[test]
    fn a_drum_chart_plan_update_changes_the_kit_without_a_rebuild_error() {
        let chart = drum_chart(Kit::Acoustic, 1, true, &[(Voice::Rim, &[100])]);
        let control = Arc::new(TransportControl::new(click_spec(120.0, 4, 0.0), 0, 0, 0));
        let (plans, rx) = std::sync::mpsc::channel();
        let mut source = TransportSource::new(Arc::clone(&control))
            .with_drums(chart)
            .with_plan_rx(rx);
        source.prepared(8_000, 1_000).expect("prepare");
        let first = left_channel(&drum_block(&mut source, 1_000));
        assert!(first_audible(&first, 1e-6).is_some(), "the chart did not start");

        let metal = drum_chart(Kit::Metal, 1, true, &[(Voice::Rim, &[100])]);
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: Some(metal),
                synth: None,

                sends: None,
            })
            .expect("send the chart update");
        let second = left_channel(&drum_block(&mut source, 1_000));
        assert!(
            first_audible(&second, 1e-6).is_some(),
            "the updated chart stopped sounding"
        );
        assert_eq!(
            source
                .drum_render
                .as_ref()
                .expect("a machine")
                .chart
                .kit,
            Kit::Metal,
            "the plan did not install the new kit"
        );
    }

    // --- app routing: the Studio channel strips an app is patched into ------

    /// A one-step kick through one routing list, rendered for its own period.
    fn routed_drum_block(routing: Vec<AppRoute>) -> Vec<f32> {
        let mut chart = drum_chart(Kit::Acoustic, 1, true, &[(Voice::Kick, &[100])]);
        chart.routing = routing;
        let (_, mut source) = drum_transport(8_000, 120.0, 0, 0, 0, chart, 1_000);
        drum_block(&mut source, 1_000)
    }

    #[test]
    fn an_app_tap_on_a_channel_follows_its_output_cord() {
        let route = |channel| AppRoute {
            gain: 1.0,
            pan: -1.0,
            inserts: Vec::new(),
            channel: Some(channel),
        };
        let mut chart = drum_chart(Kit::Acoustic, 1, true, &[(Voice::Kick, &[100])]);
        chart.routing = vec![route(1)];

        let control = Arc::new(TransportControl::new(click_spec(120.0, 4, 0.0), 0, 0, 0));
        let mut plain = TransportSource::new(Arc::clone(&control))
            .with_drums(chart.clone())
            .with_sends(Vec::new());
        plain.prepared(8_000, 256).expect("prepare the plain kit");
        let dry = peak(&left_channel(&drum_block(&mut plain, 256)));
        assert!(dry > 1e-4, "the routed kit never sounded");

        // The kick's channel 1 sends into channel 2, whose fader sits at 0.5.
        let mut sent = TransportSource::new(Arc::clone(&control))
            .with_clips(vec![silent_clip(2, 0.5, Vec::new())])
            .with_drums(chart)
            .with_sends(vec![(1, 2)]);
        sent.prepared(8_000, 256).expect("prepare the sent kit");
        let wet = peak(&left_channel(&drum_block(&mut sent, 256)));
        assert!(
            (wet - dry * 0.5).abs() < 1e-5,
            "the app tap did not follow its output cord: {wet} vs {dry}"
        );
    }

    #[test]
    fn an_app_gain_of_zero_silences_the_drum_bus() {
        let out = routed_drum_block(vec![AppRoute {
            gain: 0.0,
            pan: 0.0,
            inserts: Vec::new(),

            channel: None,
        }]);
        assert!(
            out.iter().all(|sample| sample.abs() < 1e-9),
            "a zero-gain strip let the drums through: {out:?}"
        );
    }

    #[test]
    fn an_app_gain_halves_the_peak() {
        let unity = routed_drum_block(vec![AppRoute {
            gain: 1.0,
            pan: 0.0,
            inserts: Vec::new(),

            channel: None,
        }]);
        let half = routed_drum_block(vec![AppRoute {
            gain: 0.5,
            pan: 0.0,
            inserts: Vec::new(),

            channel: None,
        }]);
        let unity_peak = peak(&unity);
        assert!(unity_peak > 1e-3, "the unity routing never sounded");
        assert!(
            (peak(&half) - unity_peak * 0.5).abs() < 1e-5,
            "half the fader did not halve the peak: {} vs {}",
            peak(&half),
            unity_peak
        );
    }

    #[test]
    fn an_app_pan_places_the_source_hard_left_and_hard_right() {
        // Equal-power: one side is exactly silent at either extreme.
        let left = routed_drum_block(vec![AppRoute {
            gain: 1.0,
            pan: -1.0,
            inserts: Vec::new(),

            channel: None,
        }]);
        assert!(peak(&left_channel(&left)) > 1e-3, "hard left was silent");
        assert!(
            peak(&right_channel(&left)) < 1e-6,
            "hard left leaked into the right: {:?}",
            right_channel(&left)
        );

        let right = routed_drum_block(vec![AppRoute {
            gain: 1.0,
            pan: 1.0,
            inserts: Vec::new(),

            channel: None,
        }]);
        assert!(peak(&right_channel(&right)) > 1e-3, "hard right was silent");
        assert!(
            peak(&left_channel(&right)) < 1e-6,
            "hard right leaked into the left: {:?}",
            left_channel(&right)
        );
    }

    #[test]
    fn an_app_insert_runs_and_is_deterministic() {
        let render = |inserts: Vec<InsertKind>| {
            routed_drum_block(vec![AppRoute {
                gain: 1.0,
                pan: 0.0,
                inserts,

                channel: None,
            }])
        };
        let dry = render(Vec::new());
        let wet = render(vec![InsertKind::Fuzz]);
        assert_ne!(dry, wet, "the routed insert did not change the sound");
        assert!(peak(&wet) > 1e-4, "the routed insert left the drums silent");
        assert_eq!(
            wet,
            render(vec![InsertKind::Fuzz]),
            "the same routed insert was not deterministic"
        );
    }

    #[test]
    fn two_app_routing_entries_sum() {
        let route = AppRoute {
            gain: 0.5,
            pan: -0.5,
            inserts: Vec::new(),

            channel: None,
        };
        let one = peak(&routed_drum_block(vec![route.clone()]));
        let two = peak(&routed_drum_block(vec![route.clone(), route]));
        assert!(one > 1e-3, "the single routing entry never sounded");
        assert!(
            (two - one * 2.0).abs() < 1e-5,
            "two identical strips did not sum: {two} vs {one}"
        );
    }

    #[test]
    fn a_step_only_chart_update_keeps_the_routed_reverb_tail() {
        // Eight steps at 8 kHz / 120 bpm are 1000 frames each; a 4096-frame
        // block covers the kick on step 0 and leaves the reverb ringing into
        // the next block.
        let mut chart = drum_chart(Kit::Acoustic, 8, false, &[(Voice::Kick, &[100])]);
        chart.routing = vec![AppRoute {
            gain: 1.0,
            pan: 0.0,
            inserts: vec![InsertKind::Reverb],

            channel: None,
        }];
        let control = Arc::new(TransportControl::new(click_spec(120.0, 4, 0.0), 0, 0, 0));
        let (plans, rx) = std::sync::mpsc::channel();
        let mut source = TransportSource::new(Arc::clone(&control))
            .with_drums(chart.clone())
            .with_plan_rx(rx);
        source.prepared(8_000, 4_096).expect("prepare");
        let first = drum_block(&mut source, 4_096);
        assert!(peak(&first) > 1e-4, "the routed kick never sounded");

        // A step-only edit: same kit, same length, same routing, silent rows.
        // The strips (and the reverb's tail) must survive it.
        let mut silent = chart.clone();
        silent.steps.iter_mut().for_each(|row| *row = [0u8; Voice::COUNT]);
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: Some(silent),
                synth: None,

                sends: None,
            })
            .expect("send the step-only update");
        let second = drum_block(&mut source, 4_096);
        assert!(
            peak(&second) > 1e-6,
            "a step-only edit reset the routed reverb tail: {:?}",
            left_channel(&second)
        );
    }

    #[test]
    fn an_empty_routing_is_the_unpatched_unity_wire() {
        // Unpatched, the machine's dual-mono block is summed unchanged: left
        // and right are identical and no equal-power trim is applied.
        let unpatched = routed_drum_block(Vec::new());
        assert_eq!(
            left_channel(&unpatched),
            right_channel(&unpatched),
            "the unpatched bus was no longer dual-mono"
        );
        let unity = peak(&unpatched);
        assert!(unity > 1e-3, "the unpatched drums never sounded");

        // One centre strip is the equal-power wire, so it sits at 1/√2 of the
        // unpatched peak — proof the empty list took no strip at all.
        let wired = routed_drum_block(vec![AppRoute::wire()]);
        let expected = unity * std::f32::consts::FRAC_1_SQRT_2;
        assert!(
            (peak(&wired) - expected).abs() < 1e-5,
            "the routed wire was not equal-power centre: {} vs {expected}",
            peak(&wired)
        );
    }

    #[test]
    fn a_send_plays_the_source_through_the_destinations_fader() {
        // A hard-left at unity, B silent but its channel's fader sits at 0.5.
        let a = routed_clip(vec![0.25; 8], 1, 1.0, -1.0, Vec::new());
        let b = silent_clip(2, 0.5, Vec::new());
        let mut source = send_transport(vec![a, b], vec![(1, 2)], 8);
        let out = block_once(&mut source, 8);
        let left = left_channel(&out);
        assert!(
            left.iter().all(|sample| (sample - 0.125).abs() < 1e-6),
            "the source did not pass through the destination fader: {left:?}"
        );
        assert!(
            peak(&right_channel(&out)) < 1e-6,
            "a hard-left source leaked right through the send"
        );
    }

    #[test]
    fn a_send_runs_the_destinations_inserts_deterministically() {
        let render = |inserts: Vec<InsertKind>| {
            let a = routed_clip(vec![0.25; 8], 1, 1.0, -1.0, Vec::new());
            let b = silent_clip(2, 0.5, inserts);
            let mut source = send_transport(vec![a, b], vec![(1, 2)], 8);
            block_once(&mut source, 8)
        };
        let dry = render(Vec::new());
        let wet = render(vec![InsertKind::Reverb]);
        assert_ne!(dry, wet, "the destination's insert did not shape the send");
        assert!(peak(&wet) > 1e-6, "the destination insert left the send silent");
        assert_eq!(
            wet,
            render(vec![InsertKind::Reverb]),
            "the routing was not deterministic"
        );
    }

    #[test]
    fn a_send_preserves_the_sources_pan_image() {
        // The destination is hard right, but a destination never re-pans a
        // send: A's hard-left image survives.
        let a = routed_clip(vec![0.25; 8], 1, 1.0, -1.0, Vec::new());
        let mut b = silent_clip(2, 1.0, Vec::new());
        b.pan = 1.0;
        let mut source = send_transport(vec![a, b], vec![(1, 2)], 8);
        let out = block_once(&mut source, 8);
        assert!(peak(&left_channel(&out)) > 1e-3, "the send lost its left image");
        assert!(
            peak(&right_channel(&out)) < 1e-6,
            "the destination panned the send again: {:?}",
            right_channel(&out)
        );
    }

    #[test]
    fn a_destination_reverb_keeps_the_two_images_apart() {
        // A shared reverb would let the hard-left send ring into the right
        // side when the insert runs the two halves. One chain per side keeps
        // the right at exact silence.
        let a = routed_clip(vec![0.025; 8], 1, 1.0, -1.0, Vec::new());
        let b = silent_clip(2, 1.0, vec![InsertKind::Reverb]);
        let mut source = send_transport(vec![a, b], vec![(1, 2)], 8);
        let out = block_once(&mut source, 8);
        assert!(peak(&left_channel(&out)) > 1e-6, "the reverb send never sounded");
        assert!(
            peak(&right_channel(&out)) < 1e-9,
            "the destination reverb bled the left image into the right: {:?}",
            right_channel(&out)
        );
    }

    #[test]
    fn a_send_chain_applies_every_destination_in_order() {
        // A -> B -> C, with both destination faders at 0.5: a quarter survives.
        let a = routed_clip(vec![0.25; 8], 1, 1.0, -1.0, Vec::new());
        let b = silent_clip(2, 0.5, Vec::new());
        let c = silent_clip(3, 0.5, Vec::new());
        let mut source = send_transport(vec![a, b, c], vec![(1, 2), (2, 3)], 8);
        let out = block_once(&mut source, 8);
        let left = left_channel(&out);
        assert!(
            left.iter().all(|sample| (sample - 0.0625).abs() < 1e-6),
            "the chain did not apply B then C: {left:?}"
        );
    }

    #[test]
    fn two_channels_send_into_one_destination_and_sum() {
        let one = routed_clip(vec![0.125; 8], 1, 1.0, -1.0, Vec::new());
        let two = routed_clip(vec![0.25; 8], 2, 1.0, -1.0, Vec::new());
        let bus = silent_clip(3, 0.5, Vec::new());
        let mut source = send_transport(vec![one, two, bus], vec![(1, 3), (2, 3)], 8);
        let out = block_once(&mut source, 8);
        let left = left_channel(&out);
        assert!(
            left.iter().all(|sample| (sample - 0.1875).abs() < 1e-6),
            "the two sends did not sum before the destination fader: {left:?}"
        );
    }

    #[test]
    fn a_send_reaches_a_destination_with_no_sources_as_a_unity_wire() {
        // Channel 2 has no clip and no tap, so its strip is unity and dry. The
        // incoming sum still leaves through it rather than disappearing.
        let a = routed_clip(vec![0.25; 8], 1, 1.0, -1.0, Vec::new());
        let mut source = send_transport(vec![a], vec![(1, 2)], 8);
        let out = block_once(&mut source, 8);
        let left = left_channel(&out);
        assert!(
            left.iter().all(|sample| (sample - 0.25).abs() < 1e-6),
            "a source-less destination did not pass the send: {left:?}"
        );
    }

    #[test]
    fn a_channel_with_no_send_is_unaffected() {
        let mut plain_source =
            send_transport(vec![clip(vec![0.25; 8], 0, 8, false)], Vec::new(), 8);
        let plain_out = block_once(&mut plain_source, 8);

        let mut routed = clip(vec![0.25; 8], 0, 8, false);
        routed.channel = Some(1);
        // Channel 2 has no source of its own, so its cord to 3 carries silence.
        let b = silent_clip(3, 0.5, Vec::new());
        let mut source = send_transport(vec![routed, b], vec![(2, 3)], 8);
        let out = block_once(&mut source, 8);
        assert_eq!(
            plain_out, out,
            "an unrelated send changed a channel that has no cord of its own"
        );
    }

    #[test]
    fn a_clip_with_no_channel_still_sums_straight_into_the_master() {
        // The clip carries no channel, so no cord can take it: the two silent
        // channels and their send are inaudible and leave it exactly as before.
        let mut bare = send_transport(vec![clip(vec![0.25; 8], 0, 8, false)], Vec::new(), 8);
        let bare_out = block_once(&mut bare, 8);
        let mut source = send_transport(
            vec![
                clip(vec![0.25; 8], 0, 8, false),
                silent_clip(1, 0.5, Vec::new()),
                silent_clip(2, 0.5, Vec::new()),
            ],
            vec![(1, 2)],
            8,
        );
        let out = block_once(&mut source, 8);
        assert_eq!(bare_out, out, "a clip with no channel was changed by a send graph");
    }

    // --- the app strip's live, ramped fader and pan --------------------------

    fn ramp_route(gain: f32, pan: f32, inserts: Vec<InsertKind>) -> AppRoute {
        AppRoute {
            gain,
            pan,
            inserts,
            channel: None,
        }
    }

    /// One prepared app strip fed a constant dual-mono block. Returns the left
    /// channel of what it added.
    fn ramp_block(
        strips: &mut Vec<AppStrip>,
        amplitude: f32,
        frames: usize,
    ) -> Vec<f32> {
        let signal = vec![amplitude; frames * 2];
        let mut master = vec![0.0; frames * 2];
        route_app_source(strips, &signal, frames, &mut master, &mut [])
            .expect("route the app source");
        left_channel(&master)
    }

    #[test]
    fn an_app_fader_change_ramps_across_the_block_without_a_step() {
        let frames = 16;
        let mut strips = build_app_strips(&[ramp_route(1.0, 0.0, Vec::new())], 8_000, frames);
        let before = ramp_block(&mut strips, 0.5, frames);
        assert!(before[0] > 1e-3, "the app strip never sounded");

        // Move the fader to half. The next block starts where the last one
        // ended and slides down, so there is no jump at the block edge and no
        // step between frames larger than the ramp allows.
        reconcile_app_strips(
            &mut strips,
            &[ramp_route(0.5, 0.0, Vec::new())],
            8_000,
            frames,
        );
        let after = ramp_block(&mut strips, 0.5, frames);
        assert!(
            (after[0] - before[0]).abs() < 1e-6,
            "the fader stepped at the block edge: {} then {}",
            before[0],
            after[0]
        );
        let step = before[0] * 0.5 / (frames - 1) as f32;
        for pair in after.windows(2) {
            let delta = (pair[0] - pair[1]).abs();
            assert!(
                delta <= step * 1.001 + 1e-7,
                "the ramp jumped {delta}, more than {step} in one frame: {after:?}"
            );
        }
        assert!(
            (after[frames - 1] - before[0] * 0.5).abs() < 1e-5,
            "the ramp did not arrive at the new fader: {after:?}"
        );
    }

    #[test]
    fn an_app_pan_change_ramps_across_the_block() {
        let frames = 16;
        let mut strips = build_app_strips(&[ramp_route(1.0, -1.0, Vec::new())], 8_000, frames);
        let signal = vec![0.5f32; frames * 2];
        let mut master = vec![0.0; frames * 2];
        route_app_source(&mut strips, &signal, frames, &mut master, &mut [])
            .expect("route the app source");
        let full_left = peak(&left_channel(&master));
        assert!(full_left > 1e-3, "hard left never sounded");

        reconcile_app_strips(
            &mut strips,
            &[ramp_route(1.0, 1.0, Vec::new())],
            8_000,
            frames,
        );
        master.fill(0.0);
        route_app_source(&mut strips, &signal, frames, &mut master, &mut [])
            .expect("route the app source");
        let left = left_channel(&master);
        let right = right_channel(&master);
        assert!(
            (left[0] - full_left).abs() < 1e-6,
            "the pan stepped at the block edge: {} then {}",
            full_left,
            left[0]
        );
        for pair in left.windows(2) {
            assert!(pair[0] + 1e-7 >= pair[1], "the left side was not ramped down: {left:?}");
        }
        for pair in right.windows(2) {
            assert!(pair[1] + 1e-7 >= pair[0], "the right side was not ramped up: {right:?}");
        }
        assert!(left[frames - 1] < full_left * 0.05, "the pan did not reach the right: {left:?}");
        assert!(right[frames - 1] > full_left * 0.95, "the right side did not arrive: {right:?}");
    }

    #[test]
    fn an_app_gain_change_keeps_a_reverb_tail() {
        let frames = 256;
        let mut strips = build_app_strips(
            &[ramp_route(1.0, 0.0, vec![InsertKind::Reverb])],
            8_000,
            frames,
        );
        let mut impulse = vec![0.0f32; frames * 2];
        impulse[0] = 1.0;
        let mut master = vec![0.0; frames * 2];
        route_app_source(&mut strips, &impulse, frames, &mut master, &mut [])
            .expect("the impulse");

        // A gain-only update must not rebuild the chain: the tail keeps
        // ringing through the next block (attenuated by the ramping fader).
        reconcile_app_strips(
            &mut strips,
            &[ramp_route(0.0, 0.0, vec![InsertKind::Reverb])],
            8_000,
            frames,
        );
        master.fill(0.0);
        let silence = vec![0.0f32; frames * 2];
        route_app_source(&mut strips, &silence, frames, &mut master, &mut [])
            .expect("the tail");
        assert!(
            peak(&master) > 1e-8,
            "a gain-only change reset the reverb tail"
        );
    }

    #[test]
    fn an_app_insert_list_change_rebuilds_and_drops_the_tail() {
        let frames = 256;
        let mut strips = build_app_strips(
            &[ramp_route(1.0, 0.0, vec![InsertKind::Reverb])],
            8_000,
            frames,
        );
        let mut impulse = vec![0.0f32; frames * 2];
        impulse[0] = 1.0;
        let mut master = vec![0.0; frames * 2];
        route_app_source(&mut strips, &impulse, frames, &mut master, &mut [])
            .expect("the impulse");

        reconcile_app_strips(
            &mut strips,
            &[ramp_route(1.0, 0.0, Vec::new())],
            8_000,
            frames,
        );
        master.fill(0.0);
        let silence = vec![0.0f32; frames * 2];
        route_app_source(&mut strips, &silence, frames, &mut master, &mut [])
            .expect("the rebuilt strip");
        assert!(
            peak(&master) < 1e-9,
            "a changed insert list kept the old chain's tail: {:?}",
            peak(&master)
        );
    }

    #[test]
    fn a_destination_fader_change_ramps_across_the_block() {
        let frames = 16;
        let mut strip = SendStrip::new(2, 1.0, &[], 8_000, frames);
        strip.clear(frames);
        strip.incoming[..frames * 2].fill(0.5);
        strip.shape_incoming(frames).expect("the first block");
        let mut total = vec![0.0f32; frames * 2];
        strip.total_into(frames, &mut total);
        let before = total[0];
        assert!((before - 0.5).abs() < 1e-6, "the destination was not a wire: {before}");

        strip.reconcile(2, 0.5, &[], 8_000, frames);
        strip.clear(frames);
        strip.incoming[..frames * 2].fill(0.5);
        strip.shape_incoming(frames).expect("the next block");
        strip.total_into(frames, &mut total);
        assert!(
            (total[0] - before).abs() < 1e-6,
            "the destination fader stepped at the block edge: {} then {}",
            before,
            total[0]
        );
        assert!(
            (total[(frames - 1) * 2] - before * 0.5).abs() < 1e-5,
            "the destination fader did not ramp to half: {:?}",
            left_channel(&total)
        );
        let step = before * 0.5 / (frames - 1) as f32;
        for pair in left_channel(&total).windows(2) {
            let delta = (pair[0] - pair[1]).abs();
            assert!(
                delta <= step * 1.001 + 1e-7,
                "the destination ramp jumped {delta}, more than {step} in one frame"
            );
        }
    }

    #[test]
    fn a_destination_fader_change_keeps_its_reverb_tail() {
        let frames = 64;
        // Two identical destinations ring from the same impulse. Only one
        // moves its fader in the next block, so the other is the control.
        let mut changed = SendStrip::new(2, 1.0, &[InsertKind::Reverb], 8_000, frames);
        let mut steady = SendStrip::new(2, 1.0, &[InsertKind::Reverb], 8_000, frames);
        for strip in [&mut changed, &mut steady] {
            strip.incoming[0] = 1.0;
            strip.shape_incoming(frames).expect("shape the first block");
        }
        changed.reconcile(2, 0.5, &[InsertKind::Reverb], 8_000, frames);
        let mut changed_total = vec![0.0f32; frames * 2];
        let mut steady_total = vec![0.0f32; frames * 2];
        for (strip, total) in [
            (&mut changed, &mut changed_total),
            (&mut steady, &mut steady_total),
        ] {
            strip.clear(frames);
            strip.shape_incoming(frames).expect("shape the next block");
            strip.total_into(frames, total);
        }
        assert!(peak(&steady_total) > 1e-8, "the reverb tail did not ring");
        assert!(
            (changed_total[0] - steady_total[0]).abs() < 1e-6,
            "the destination fader stepped at the block edge: {} vs {}",
            changed_total[0],
            steady_total[0]
        );
        assert!(
            peak(&changed_total) > 1e-8,
            "a fader-only change reset the destination's reverb tail"
        );
    }

    #[test]
    fn the_synth_renders_through_its_routing_and_a_patch_keeps_it() {
        let (plans, notes, _, mut source) = app_transport(None, Vec::new(), Vec::new(), 256);
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(synth_patch_plan(4_000.0)),

                sends: None,
            })
            .expect("send the patch");
        note_on(&notes, 60);
        let dry = drum_block(&mut source, 256);
        assert!(peak(&dry) > 1e-4, "the routed synth never sounded");

        // A routing-only plan: the note keeps sounding but the strip's fader
        // takes it to silence.
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(SynthPlan {
                    patch: None,
                    routing: Some(vec![AppRoute {
                        gain: 0.0,
                        pan: 0.0,
                        inserts: Vec::new(),

                        channel: None,
                    }]),
                }),

                sends: None,
            })
            .expect("send the routing");
        let muted = drum_block(&mut source, 256);
        assert!(
            muted.iter().all(|sample| sample.abs() < 1e-9),
            "the synth routing did not mute the app bus: {muted:?}"
        );
        assert_eq!(
            source.synth.as_ref().expect("a synth").active_voices(),
            1,
            "the routing change touched the sounding voice"
        );

        // A later patch must not clear the routing: the synth is still muted.
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(synth_patch_plan(9_000.0)),

                sends: None,
            })
            .expect("send the second patch");
        let still_muted = drum_block(&mut source, 256);
        assert!(
            still_muted.iter().all(|sample| sample.abs() < 1e-9),
            "a patch cleared the synth routing: {still_muted:?}"
        );
        assert_eq!(
            source.synth.as_ref().expect("a synth").active_voices(),
            1,
            "the patch rebuild dropped the held voice"
        );
    }

    // --- transport synth and audition hits -----------------------------------

    /// A transport with the plan, note and hit channels attached before
    /// `prepared`, which is the shape `transport start` builds.
    fn app_transport(
        chart: Option<DrumChart>,
        master: Vec<InsertKind>,
        master_values: Vec<(String, f32)>,
        period: usize,
    ) -> (
        std::sync::mpsc::Sender<TransportPlan>,
        std::sync::mpsc::Sender<TransportNote>,
        std::sync::mpsc::Sender<TransportHit>,
        TransportSource,
    ) {
        let control = Arc::new(TransportControl::new(click_spec(120.0, 4, 0.0), 0, 0, 0));
        let (plans, plan_rx) = std::sync::mpsc::channel();
        let (notes, note_rx) = std::sync::mpsc::channel();
        let (hits, hit_rx) = std::sync::mpsc::channel();
        let mut source = TransportSource::new(Arc::clone(&control))
            .with_master(master)
            .with_master_values(master_values)
            .with_plan_rx(plan_rx)
            .with_note_rx(note_rx)
            .with_hit_rx(hit_rx);
        if let Some(chart) = chart {
            source = source.with_drums(chart);
        }
        source.prepared(8_000, period).expect("prepare");
        (plans, notes, hits, source)
    }

    /// A patch whose only difference from the default is its filter cutoff.
    fn synth_patch_plan(cutoff: f32) -> SynthPlan {
        let mut patch = Patch::default();
        patch.filter.cutoff = cutoff;
        SynthPlan {
            patch: Some(patch),
            routing: None,
        }
    }

    fn note_on(notes: &std::sync::mpsc::Sender<TransportNote>, note: u8) {
        notes
            .send(TransportNote::Note {
                on: true,
                note,
                velocity: 1.0,
            })
            .expect("send the note-on");
    }

    fn note_off(notes: &std::sync::mpsc::Sender<TransportNote>, note: u8) {
        notes
            .send(TransportNote::Note {
                on: false,
                note,
                velocity: 0.0,
            })
            .expect("send the note-off");
    }

    #[test]
    fn a_synth_patch_plan_creates_a_synth_that_answers_a_note() {
        let (plans, notes, _, mut source) = app_transport(None, Vec::new(), Vec::new(), 1_000);
        assert!(source.synth.is_none(), "a synth existed before any patch");
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(synth_patch_plan(4_000.0)),

                sends: None,
            })
            .expect("send the patch");
        note_on(&notes, 60);
        let out = drum_block(&mut source, 1_000);
        assert!(
            source.synth.is_some(),
            "the patch plan did not build the synth"
        );
        assert!(
            peak(&out) > 1e-4,
            "the note-on rendered silence: {:?}",
            left_channel(&out)
        );
    }

    #[test]
    fn a_note_off_releases_the_synth_to_exact_silence() {
        let (plans, notes, _, mut source) = app_transport(None, Vec::new(), Vec::new(), 1_000);
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(synth_patch_plan(4_000.0)),

                sends: None,
            })
            .expect("send the patch");
        note_on(&notes, 60);
        let held = drum_block(&mut source, 1_000);
        assert!(peak(&held) > 1e-4, "the held note never sounded");

        note_off(&notes, 60);
        // The default patch releases over 0.5 s, so five 1000-frame blocks at
        // 8 kHz cover it; the tail is monotonic and then exactly zero.
        let mut previous = peak(&held);
        for pass in 0..4 {
            let out = drum_block(&mut source, 1_000);
            let current = peak(&out);
            assert!(current <= previous + 1e-6, "release pass {pass} rose: {current} > {previous}");
            previous = current;
        }
        let silent = drum_block(&mut source, 1_000);
        assert!(
            silent.iter().all(|sample| *sample == 0.0),
            "the released synth was not silent: {:?}",
            left_channel(&silent)
        );
        assert_eq!(
            source.synth.as_ref().expect("a synth").active_voices(),
            0,
            "the released voice stayed active"
        );
    }

    #[test]
    fn all_off_silences_the_synth() {
        let (plans, notes, _, mut source) = app_transport(None, Vec::new(), Vec::new(), 1_000);
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(synth_patch_plan(4_000.0)),

                sends: None,
            })
            .expect("send the patch");
        note_on(&notes, 60);
        assert!(peak(&drum_block(&mut source, 1_000)) > 1e-4);

        notes
            .send(TransportNote::AllOff)
            .expect("send the all-off");
        for _ in 0..4 {
            let _ = drum_block(&mut source, 1_000);
        }
        let silent = drum_block(&mut source, 1_000);
        assert!(
            silent.iter().all(|sample| *sample == 0.0),
            "all_off left the synth sounding: {:?}",
            left_channel(&silent)
        );
        assert_eq!(
            source.synth.as_ref().expect("a synth").active_voices(),
            0,
            "all_off left an active voice"
        );
    }

    #[test]
    fn a_new_patch_while_a_note_is_held_keeps_the_voice_sounding() {
        let (plans, notes, _, mut source) = app_transport(None, Vec::new(), Vec::new(), 1_000);
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(synth_patch_plan(2_000.0)),

                sends: None,
            })
            .expect("send the patch");
        note_on(&notes, 60);
        assert!(peak(&drum_block(&mut source, 1_000)) > 1e-4, "the note never sounded");

        // A second patch rides the same plan edge. `set_patch` retunes the
        // loaded synth, so the held voice is still there; a rebuild would have
        // dropped it and rendered silence.
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(synth_patch_plan(12_000.0)),

                sends: None,
            })
            .expect("send the second patch");
        let out = drum_block(&mut source, 1_000);
        assert!(
            peak(&out) > 1e-4,
            "the patch change silenced the held note: {:?}",
            left_channel(&out)
        );
        assert_eq!(
            source.synth.as_ref().expect("a synth").active_voices(),
            1,
            "the patch change rebuilt the synth instead of retuning it"
        );
    }

    #[test]
    fn the_synth_and_drums_share_one_pre_master_bus() {
        // Both sources alone are hotter than a -40 dBFS master ceiling, so a
        // render through the limiter that stays at the ceiling proves neither
        // one bypassed the master rack: a post-master add would poke above it.
        let ceiling = 10f32.powf(-40.0 / 20.0);
        let chart = drum_chart(Kit::Acoustic, 1, true, &[(Voice::Kick, &[100])]);

        let (plans, notes, _, mut synth_only) = app_transport(None, Vec::new(), Vec::new(), 1_000);
        plans
            .send(TransportPlan {
                clips: None,
                master: None,
                master_values: None,
                drums: None,
                synth: Some(synth_patch_plan(4_000.0)),

                sends: None,
            })
            .expect("send the patch");
        note_on(&notes, 60);
        assert!(
            peak(&drum_block(&mut synth_only, 1_000)) > ceiling * 2.0,
            "the synth was not loud enough to prove the ceiling"
        );

        let (_, _, _, mut drums_only) = app_transport(Some(chart.clone()), Vec::new(), Vec::new(), 1_000);
        assert!(
            peak(&drum_block(&mut drums_only, 1_000)) > ceiling * 2.0,
            "the kick was not loud enough to prove the ceiling"
        );

        let (_, notes, _, mut both) = app_transport(
            Some(chart),
            vec![InsertKind::Limiter],
            // The default -3 dBFS ceiling would not clamp either source; -40
            // dBFS is below both, so every sounding sample lands exactly on it.
            // The value goes in before `prepare`, so the block is not heard
            // through a ceiling still smoothing down from its default.
            vec![("master_limiter.ceiling".to_string(), -40.0)],
            1_000,
        );
        note_on(&notes, 60);
        let out = drum_block(&mut both, 1_000);
        assert!(
            peak(&out) <= ceiling * 1.001,
            "a master ceiling of {ceiling} was exceeded: peak {}",
            peak(&out)
        );
        assert!(
            peak(&out) >= ceiling * 0.999,
            "neither source reached the master bus: peak {}",
            peak(&out)
        );
    }

    #[test]
    fn a_drum_hit_with_no_chart_is_harmless() {
        let (_, _, hits, mut source) = app_transport(None, Vec::new(), Vec::new(), 1_000);
        hits.send(TransportHit {
            voice: Voice::Kick.index(),
            velocity: 100,
        })
        .expect("send the hit");
        let out = drum_block(&mut source, 1_000);
        assert!(
            out.iter().all(|sample| *sample == 0.0),
            "a hit with no chart made sound: {out:?}"
        );
    }

    #[test]
    fn a_drum_hit_renders_through_the_loaded_chart_machine() {
        // The chart itself is empty, so the only sound is the auditioned kick.
        let chart = drum_chart(Kit::Acoustic, 4, true, &[(Voice::Kick, &[0, 0, 0, 0])]);
        let (_, _, hits, mut source) = app_transport(Some(chart), Vec::new(), Vec::new(), 1_000);
        hits.send(TransportHit {
            voice: Voice::Kick.index(),
            velocity: 100,
        })
        .expect("send the hit");
        let left = left_channel(&drum_block(&mut source, 1_000));
        let onset = first_audible(&left, 1e-6).expect("the auditioned kick never sounded");
        assert!(onset <= 8, "the hit landed at frame {onset}");
    }

    #[test]
    fn a_transport_live_input_runs_through_the_armed_master_limiter() {
        // A full-scale live input through the default limiter settles at its
        // -3 dBFS ceiling, proving the live ring joins the clips before the
        // master chain rather than being added after it.
        let (producer, consumer) = crate::monbus::MonitorBus::new(4096);
        producer.push(&[1.0f32; 8]);
        let mut source = live_transport(
            consumer,
            live_gain(1.0),
            vec![InsertKind::Limiter],
            4,
        );
        let mut out = vec![0.0f32; 8];
        source.block(&mut out).expect("block");
        let ceiling = 10f32.powf(-3.0 / 20.0);
        for (frame, sample) in out.iter().enumerate() {
            assert!(
                (sample.abs() - ceiling).abs() < 1e-5,
                "frame {frame} did not pass the master limiter: {out:?}"
            );
        }
    }
}
