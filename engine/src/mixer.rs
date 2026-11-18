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

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

use crate::effect::Channel;

/// How many control changes may wait between the control thread and the next
/// block the audio thread runs. Each is one knob, so this is a second or two of
/// even a very fast hand on a fader.
pub const PARAM_QUEUE_LEN: usize = 64;

/// A parameter the control path can name, in the engine's own vocabulary.
///
/// The names are the ones the socket speaks, split at the effect prefix so the
/// audio side does not have to parse strings. [`insert`](ParamName::insert) is
/// what a controller checks before sending: an effect parameter is only real
/// when that effect is in the track's chain.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ParamName {
    Gain = 1,
    Pan,
    ToneBass,
    ToneMid,
    ToneTreble,
    DistortionDrive,
    DelayTime,
    DelayFeedback,
    DelayMix,
    CompressorThreshold,
    CompressorAttack,
    CompressorMix,
    ReverbMix,
    ReverbVolume,
}

impl ParamName {
    /// The socket's name, e.g. `reverb.mix`.
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "gain" => Self::Gain,
            "pan" => Self::Pan,
            "tone.bass" => Self::ToneBass,
            "tone.mid" => Self::ToneMid,
            "tone.treble" => Self::ToneTreble,
            "distortion.drive" => Self::DistortionDrive,
            "delay.time" => Self::DelayTime,
            "delay.feedback" => Self::DelayFeedback,
            "delay.mix" => Self::DelayMix,
            "compressor.threshold" => Self::CompressorThreshold,
            "compressor.attack" => Self::CompressorAttack,
            "compressor.mix" => Self::CompressorMix,
            "reverb.mix" => Self::ReverbMix,
            "reverb.volume" => Self::ReverbVolume,
            _ => return None,
        })
    }

    /// The name [`Channel::set`] expects.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Gain => "gain",
            Self::Pan => "pan",
            Self::ToneBass => "tone.bass",
            Self::ToneMid => "tone.mid",
            Self::ToneTreble => "tone.treble",
            Self::DistortionDrive => "distortion.drive",
            Self::DelayTime => "delay.time",
            Self::DelayFeedback => "delay.feedback",
            Self::DelayMix => "delay.mix",
            Self::CompressorThreshold => "compressor.threshold",
            Self::CompressorAttack => "compressor.attack",
            Self::CompressorMix => "compressor.mix",
            Self::ReverbMix => "reverb.mix",
            Self::ReverbVolume => "reverb.volume",
        }
    }

    /// The insert that owns an effect parameter; `None` for the strip's own
    /// gain and pan.
    pub fn insert(self) -> Option<&'static str> {
        match self {
            Self::Gain | Self::Pan => None,
            Self::ToneBass | Self::ToneMid | Self::ToneTreble => Some("tone"),
            Self::DistortionDrive => Some("distortion"),
            Self::DelayTime | Self::DelayFeedback | Self::DelayMix => Some("delay"),
            Self::CompressorThreshold | Self::CompressorAttack | Self::CompressorMix => {
                Some("compressor")
            }
            Self::ReverbMix | Self::ReverbVolume => Some("reverb"),
        }
    }

    fn code(self) -> u8 {
        self as u8
    }

    fn from_code(code: u8) -> Option<Self> {
        Some(match code {
            1 => Self::Gain,
            2 => Self::Pan,
            3 => Self::ToneBass,
            4 => Self::ToneMid,
            5 => Self::ToneTreble,
            6 => Self::DistortionDrive,
            7 => Self::DelayTime,
            8 => Self::DelayFeedback,
            9 => Self::DelayMix,
            10 => Self::CompressorThreshold,
            11 => Self::CompressorAttack,
            12 => Self::CompressorMix,
            13 => Self::ReverbMix,
            14 => Self::ReverbVolume,
            _ => return None,
        })
    }
}

/// One control change, packed into 56 bits so it can sit in one atomic slot:
/// 8 bits of name, 16 of track, 32 of the value's IEEE bits.
fn pack(track: usize, name: ParamName, value: f32) -> u64 {
    u64::from(name.code())
        | ((track as u64 & 0xFFFF) << 8)
        | (u64::from(value.to_bits()) << 24)
}

fn unpack(packed: u64) -> Option<(usize, ParamName, f32)> {
    let name = ParamName::from_code((packed & 0xFF) as u8)?;
    let track = ((packed >> 8) & 0xFFFF) as usize;
    let value = f32::from_bits((packed >> 24) as u32);
    Some((track, name, value))
}

/// A fixed-size single-producer/single-consumer ring of control changes.
///
/// The control thread pushes; the audio thread pops at the top of a block.
/// Atomics only: the audio thread never waits for the writer, allocates, or
/// panics when the ring is full — [`push`](ParamQueue::push) tells the control
/// thread instead, so a knob turned faster than the block rate is bounded by
/// the block rate rather than by a lock.
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

    fn pop(&self) -> Option<(usize, ParamName, f32)> {
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

/// One input and the strip that records it.
pub struct Track {
    /// The device input index this track records, 0-based.
    pub input: usize,
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
                label: (*label).to_string(),
                channel: Channel::new(1.0, 0.0),
            })
            .collect();
        Mixer {
            tracks,
            scratch: Vec::new(),
            params,
        }
    }

    /// The queue the control thread pushes to.
    pub fn params(&self) -> Arc<ParamQueue> {
        Arc::clone(&self.params)
    }

    /// Apply every waiting control change. Called at the top of a block, so a
    /// param that arrived between blocks is heard at this block's edge.
    pub fn apply_pending(&mut self) {
        while let Some((index, name, value)) = self.params.pop() {
            if let Some(track) = self.tracks.get_mut(index) {
                track.channel.set(name.as_str(), value);
            }
        }
    }

    /// Size every strip, and the shared mix block, for `period` frames. This is
    /// the only allocation in the mixer.
    pub fn prepare(&mut self, rate: u32, period: usize) {
        for track in &mut self.tracks {
            track.channel.prepare(rate, period);
        }
        self.scratch = vec![0.0; period.saturating_mul(2)];
    }

    pub fn tracks(&self) -> &[Track] {
        &self.tracks
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
        self.apply_pending();
        if bus.len() % 2 != 0 {
            return Err(format!(
                "the mix bus must hold whole stereo frames, found {} samples",
                bus.len()
            ));
        }
        let frames = bus.len() / 2;
        let track_count = self.tracks.len();
        if inputs.len() < track_count {
            return Err(format!(
                "mix needs one input per track: {track_count} tracks, {} inputs",
                inputs.len()
            ));
        }
        if frames > self.scratch.len() / 2 {
            return Err(format!(
                "a {frames}-frame mix block is longer than the prepared {} frames",
                self.scratch.len() / 2
            ));
        }
        // Validate every input before the bus is touched, so a bad call leaves
        // the caller's buffer as it found it.
        for (index, input) in inputs.iter().take(track_count).enumerate() {
            if input.len() != frames {
                return Err(format!(
                    "track {index} input has {} frames, the bus has {frames}",
                    input.len()
                ));
            }
        }

        bus.fill(0.0);
        let Mixer { tracks, scratch, .. } = self;
        for (index, track) in tracks.iter_mut().enumerate() {
            let stereo = &mut scratch[..frames * 2];
            track
                .channel
                .process(inputs[index], stereo)
                .map_err(|error| format!("track {index}: {error:?}"))?;
            for (out, sample) in bus.iter_mut().zip(stereo.iter()) {
                *out += sample;
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
    fn every_parameter_name_parses_and_names_its_insert() {
        for (text, name, insert) in [
            ("gain", ParamName::Gain, None),
            ("pan", ParamName::Pan, None),
            ("tone.bass", ParamName::ToneBass, Some("tone")),
            ("tone.mid", ParamName::ToneMid, Some("tone")),
            ("tone.treble", ParamName::ToneTreble, Some("tone")),
            ("distortion.drive", ParamName::DistortionDrive, Some("distortion")),
            ("delay.time", ParamName::DelayTime, Some("delay")),
            ("delay.feedback", ParamName::DelayFeedback, Some("delay")),
            ("delay.mix", ParamName::DelayMix, Some("delay")),
            (
                "compressor.threshold",
                ParamName::CompressorThreshold,
                Some("compressor"),
            ),
            (
                "compressor.attack",
                ParamName::CompressorAttack,
                Some("compressor"),
            ),
            ("compressor.mix", ParamName::CompressorMix, Some("compressor")),
            ("reverb.mix", ParamName::ReverbMix, Some("reverb")),
            ("reverb.volume", ParamName::ReverbVolume, Some("reverb")),
        ] {
            assert_eq!(ParamName::parse(text), Some(name), "{text}");
            assert_eq!(name.as_str(), text);
            assert_eq!(name.insert(), insert, "{text}");
        }
        assert_eq!(ParamName::parse("banana"), None);
        assert_eq!(ParamName::parse("delay"), None);
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
    fn the_queue_keeps_its_order_and_its_values() {
        let queue = ParamQueue::new();
        assert!(queue.push(0, ParamName::Gain, 0.25));
        assert!(queue.push(1, ParamName::Pan, -1.0));
        assert!(queue.push(0, ParamName::ReverbMix, 0.75));

        assert_eq!(queue.pop(), Some((0, ParamName::Gain, 0.25)));
        assert_eq!(queue.pop(), Some((1, ParamName::Pan, -1.0)));
        assert_eq!(queue.pop(), Some((0, ParamName::ReverbMix, 0.75)));
        assert_eq!(queue.pop(), None);
    }
}
