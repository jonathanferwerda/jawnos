//! The real-time drum machine: rendered kit buffers and a fixed hit pool.
//!
//! [`Machine::load_kit`] renders all eight voices once and keeps them. After
//! that, [`Machine::render`] only reads those buffers: it allocates nothing,
//! takes no locks, opens no files and cannot panic on the audio thread.
//!
//! A trigger starts a hit at the next block's origin, or after a caller-chosen
//! frame offset. Hits overlap, like the browser's one `AudioBufferSourceNode`
//! per hit: retriggering the same slot starts a second voice instead of cutting
//! the first. At most [`MAX_HITS`] hits play at once; when a new trigger finds
//! the pool full it steals the oldest hit (the one triggered longest ago),
//! keeping the newest performance rather than silencing the new note.
//!
//! The machine is mono: a hit is written to both the left and right speaker at
//! unity, with no pan. Velocity is applied at playback, not baked into the
//! buffer, so one rendered kit serves every velocity.
//!
//! `render` treats `period` as the block size the caller intends to use, not a
//! requirement: it processes `min(left.len(), right.len())` frames, so a shorter
//! or longer block is safe. If the two slices differ in length, the tail of the
//! longer one is left untouched.

use crate::{dsp, Kit, Voice};

/// The largest number of hits that can sound at once.
///
/// The Studio has eight rows, but overlapping tails (and a retrigger of the same
/// row) mean more than eight hits can be live. A fixed pool keeps `render`
/// allocation-free; a trigger beyond this many live hits steals the oldest.
pub const MAX_HITS: usize = 32;

#[derive(Debug, Clone, Copy)]
struct Hit {
    slot: usize,
    pos: usize,
    delay: usize,
    gain: f32,
    age: u64,
    active: bool,
}

const IDLE: Hit = Hit {
    slot: 0,
    pos: 0,
    delay: 0,
    gain: 0.0,
    age: 0,
    active: false,
};

/// The drum machine's real-time state.
///
/// Build one at the engine's sample rate and block size, call
/// [`Machine::load_kit`] off the audio thread, then call [`Machine::render`]
/// once per block. Every buffer the render path reads was sized by `load_kit`.
#[derive(Debug)]
pub struct Machine {
    rate: u32,
    period: usize,
    buffers: [Vec<f32>; Voice::COUNT],
    hits: [Hit; MAX_HITS],
    next_age: u64,
    kit: Option<Kit>,
}

impl Machine {
    /// A machine with no kit loaded, at `rate` hertz and an intended block of
    /// `period` frames.
    ///
    /// # Panics
    ///
    /// Panics if `rate` or `period` is zero. Construction happens at startup,
    /// never in the audio callback.
    pub fn new(rate: u32, period: usize) -> Self {
        assert!(rate > 0, "a drum machine needs a sample rate");
        assert!(period > 0, "a drum machine needs a block size");
        Machine {
            rate,
            period,
            buffers: std::array::from_fn(|_| Vec::new()),
            hits: [IDLE; MAX_HITS],
            next_age: 0,
            kit: None,
        }
    }

    /// The sample rate this machine renders at.
    pub fn rate(&self) -> u32 {
        self.rate
    }

    /// The block size the caller said it would use.
    ///
    /// This is informational: [`Machine::render`] accepts any block length.
    pub fn period(&self) -> usize {
        self.period
    }

    /// The kit currently loaded, or `None` before the first [`Machine::load_kit`].
    pub fn kit(&self) -> Option<Kit> {
        self.kit
    }

    /// Render every voice of `kit` and store the eight buffers.
    ///
    /// This is the only method that grows a buffer, so it must be called off the
    /// audio thread. Loading a kit stops any ringing hits, because a slot's
    /// buffer is replaced whole; the browser leaves already-started sources on
    /// their old buffers, which this fixed-buffer design cannot do without a
    /// second allocation.
    pub fn load_kit(&mut self, kit: Kit) {
        self.reset();
        for voice in Voice::ALL {
            let spec = kit.spec(voice);
            let rendered =
                dsp::render_voice_with_seed(&spec, self.rate, dsp::voice_seed(voice));
            let buffer = &mut self.buffers[voice.index()];
            buffer.clear();
            buffer.extend_from_slice(&rendered);
        }
        self.kit = Some(kit);
    }

    /// Start one hit at the next block's first frame.
    ///
    /// `slot` is a [`Voice::index`] in `0..Voice::COUNT`; an out-of-range slot is
    /// ignored. `velocity` is `0..=100`: zero is off and allocates no hit, and
    /// values above 100 are clamped to 100. Velocity maps to gain
    /// `velocity / 100`. A trigger before a kit is loaded is ignored.
    pub fn trigger(&mut self, slot: usize, velocity: u8) {
        self.trigger_at(slot, velocity, 0);
    }

    /// Start one hit `offset_frames` frames after the next block's first frame.
    ///
    /// The offset is measured from the start of the next [`Machine::render`]
    /// call and may span blocks. The rest of the contract is
    /// [`Machine::trigger`]'s.
    pub fn trigger_at(&mut self, slot: usize, velocity: u8, offset_frames: usize) {
        if slot >= Voice::COUNT || velocity == 0 {
            return;
        }
        if self.buffers[slot].is_empty() {
            return;
        }
        let gain = velocity.min(100) as f32 / 100.0;
        let index = self.allocate_hit();
        self.next_age = self.next_age.wrapping_add(1);
        self.hits[index] = Hit {
            slot,
            pos: 0,
            delay: offset_frames,
            gain,
            age: self.next_age,
            active: true,
        };
    }

    /// Render one block into `left` and `right`, overwriting their contents.
    ///
    /// Frames `0..min(left.len(), right.len())` are written in both slices. The
    /// output is the sum of every live hit, with no clipping or limiting here:
    /// the engine's master chain owns that. A block of any length is accepted;
    /// `period` does not constrain it.
    pub fn render(&mut self, left: &mut [f32], right: &mut [f32]) {
        let frames = left.len().min(right.len());
        left[..frames].fill(0.0);
        right[..frames].fill(0.0);

        let buffers = &self.buffers;
        for hit in self.hits.iter_mut() {
            if !hit.active {
                continue;
            }
            if hit.delay >= frames {
                hit.delay -= frames;
                continue;
            }
            let mut frame = hit.delay;
            hit.delay = 0;
            let buffer = &buffers[hit.slot];
            while frame < frames && hit.pos < buffer.len() {
                let sample = buffer[hit.pos] * hit.gain;
                left[frame] += sample;
                right[frame] += sample;
                hit.pos += 1;
                frame += 1;
            }
            if hit.pos >= buffer.len() {
                hit.active = false;
            }
        }
    }

    /// Stop every hit and free its pool slot. The loaded kit is kept.
    pub fn reset(&mut self) {
        self.hits = [IDLE; MAX_HITS];
    }

    /// How many hits are live, including ones scheduled for a later frame in the
    /// next block.
    pub fn active_voices(&self) -> usize {
        self.hits.iter().filter(|hit| hit.active).count()
    }

    /// A free pool slot, or the oldest active one when the pool is full.
    fn allocate_hit(&mut self) -> usize {
        if let Some(free) = self.hits.iter().position(|hit| !hit.active) {
            return free;
        }
        let mut oldest = 0;
        for index in 1..self.hits.len() {
            if self.hits[index].age < self.hits[oldest].age {
                oldest = index;
            }
        }
        oldest
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine(kit: Kit) -> Machine {
        let mut machine = Machine::new(44_100, 64);
        machine.load_kit(kit);
        machine
    }

    fn render(machine: &mut Machine, frames: usize) -> (Vec<f32>, Vec<f32>) {
        let mut left = vec![0.0f32; frames];
        let mut right = vec![0.0f32; frames];
        machine.render(&mut left, &mut right);
        (left, right)
    }

    fn peak(samples: &[f32]) -> f32 {
        samples.iter().fold(0.0f32, |loudest, s| loudest.max(s.abs()))
    }

    fn first_audible(samples: &[f32], threshold: f32) -> Option<usize> {
        samples.iter().position(|s| s.abs() > threshold)
    }

    #[test]
    fn silence_before_any_trigger() {
        let mut drum = machine(Kit::Acoustic);
        let mut left = vec![0.7f32; 128];
        let mut right = vec![0.7f32; 128];
        drum.render(&mut left, &mut right);
        assert!(left.iter().all(|s| *s == 0.0));
        assert!(right.iter().all(|s| *s == 0.0));
        assert_eq!(drum.active_voices(), 0);
    }

    #[test]
    fn a_trigger_has_an_onset_within_a_few_frames() {
        let mut drum = machine(Kit::Acoustic);
        drum.trigger(Voice::Kick.index(), 100);
        let (left, right) = render(&mut drum, 64);
        let onset = first_audible(&left, 1e-6).expect("an onset");
        assert!(onset < 8, "onset at frame {onset}");
        assert_eq!(left, right);
    }

    #[test]
    fn the_voice_decays_and_its_slot_is_freed() {
        let mut drum = machine(Kit::Acoustic);
        drum.trigger(Voice::Kick.index(), 100);
        let mut heard = false;
        let mut freed = false;
        for _ in 0..500 {
            let (left, _) = render(&mut drum, 128);
            heard |= peak(&left) > 0.0;
            if drum.active_voices() == 0 {
                freed = true;
                break;
            }
        }
        assert!(heard);
        assert!(freed, "the hit outlived its 0.55 s buffer");
        let (left, right) = render(&mut drum, 256);
        assert!(left.iter().all(|s| *s == 0.0));
        assert!(right.iter().all(|s| *s == 0.0));
    }

    #[test]
    fn velocity_scales_the_peak_and_zero_is_silent() {
        let mut loud = machine(Kit::Acoustic);
        let mut medium = machine(Kit::Acoustic);
        let mut quiet = machine(Kit::Acoustic);
        loud.trigger(Voice::Kick.index(), 100);
        medium.trigger(Voice::Kick.index(), 50);
        quiet.trigger(Voice::Kick.index(), 25);
        let loud_peak = peak(&render(&mut loud, 30_000).0);
        let medium_peak = peak(&render(&mut medium, 30_000).0);
        let quiet_peak = peak(&render(&mut quiet, 30_000).0);
        assert!(loud_peak > medium_peak, "{loud_peak} vs {medium_peak}");
        assert!(medium_peak > quiet_peak, "{medium_peak} vs {quiet_peak}");
        assert!(quiet_peak > 0.0);

        let mut silent = machine(Kit::Acoustic);
        silent.trigger(Voice::Kick.index(), 0);
        assert_eq!(silent.active_voices(), 0);
        let (left, _) = render(&mut silent, 1024);
        assert!(left.iter().all(|s| *s == 0.0));
    }

    #[test]
    fn velocity_above_one_hundred_is_clamped() {
        let mut top = machine(Kit::Acoustic);
        let mut over = machine(Kit::Acoustic);
        top.trigger(Voice::Kick.index(), 100);
        over.trigger(Voice::Kick.index(), 255);
        assert_eq!(render(&mut top, 512).0, render(&mut over, 512).0);
    }

    #[test]
    fn trigger_at_starts_later_by_exactly_the_offset() {
        let mut now = machine(Kit::Acoustic);
        let mut later = machine(Kit::Acoustic);
        now.trigger(Voice::Kick.index(), 100);
        later.trigger_at(Voice::Kick.index(), 100, 37);
        let (now_left, _) = render(&mut now, 200);
        let (later_left, _) = render(&mut later, 200);
        assert!(later_left[..37].iter().all(|s| *s == 0.0));
        assert_eq!(&later_left[37..], &now_left[..163]);
    }

    #[test]
    fn two_voices_mix_louder_than_either_alone() {
        let mut kick = machine(Kit::Acoustic);
        let mut snare = machine(Kit::Acoustic);
        let mut both = machine(Kit::Acoustic);
        kick.trigger(Voice::Kick.index(), 100);
        snare.trigger(Voice::Snare.index(), 100);
        both.trigger(Voice::Kick.index(), 100);
        both.trigger(Voice::Snare.index(), 100);
        let kick_peak = peak(&render(&mut kick, 8_000).0);
        let snare_peak = peak(&render(&mut snare, 8_000).0);
        let both_peak = peak(&render(&mut both, 8_000).0);
        assert!(both_peak > kick_peak, "{both_peak} vs {kick_peak}");
        assert!(both_peak > snare_peak, "{both_peak} vs {snare_peak}");
    }

    #[test]
    fn a_retrigger_overlaps_rather_than_stealing_the_same_slot() {
        let mut drum = machine(Kit::Acoustic);
        drum.trigger(Voice::Kick.index(), 100);
        render(&mut drum, 64);
        assert_eq!(drum.active_voices(), 1);
        drum.trigger(Voice::Kick.index(), 100);
        assert_eq!(drum.active_voices(), 2, "the first hit keeps ringing");
        render(&mut drum, 64);
        assert_eq!(drum.active_voices(), 2);
        for _ in 0..500 {
            render(&mut drum, 128);
            if drum.active_voices() == 0 {
                break;
            }
        }
        assert_eq!(drum.active_voices(), 0);
    }

    #[test]
    fn the_pool_steals_the_oldest_hit_when_full() {
        let mut drum = machine(Kit::Acoustic);
        for _ in 0..MAX_HITS + 5 {
            drum.trigger(Voice::Kick.index(), 100);
        }
        assert_eq!(drum.active_voices(), MAX_HITS);
        render(&mut drum, 128);
        assert_eq!(drum.active_voices(), MAX_HITS);
    }

    #[test]
    fn two_machines_with_the_same_kit_and_triggers_are_byte_identical() {
        let mut a = machine(Kit::Electronic);
        let mut b = machine(Kit::Electronic);
        for drum in [&mut a, &mut b] {
            drum.trigger(Voice::Kick.index(), 100);
            drum.trigger_at(Voice::Snare.index(), 70, 31);
            drum.trigger_at(Voice::Clap.index(), 90, 200);
            drum.trigger_at(Voice::ClosedHat.index(), 55, 5);
        }
        let mut a_bits = Vec::new();
        let mut b_bits = Vec::new();
        for _ in 0..8 {
            let (left, right) = render(&mut a, 256);
            a_bits.extend(left.iter().chain(right.iter()).map(|s| s.to_bits()));
            let (left, right) = render(&mut b, 256);
            b_bits.extend(left.iter().chain(right.iter()).map(|s| s.to_bits()));
        }
        assert_eq!(a_bits, b_bits);
    }

    #[test]
    fn reset_stops_every_hit_but_keeps_the_kit() {
        let mut drum = machine(Kit::Acoustic);
        drum.trigger(Voice::Kick.index(), 100);
        render(&mut drum, 10);
        drum.reset();
        assert_eq!(drum.active_voices(), 0);
        assert_eq!(drum.kit(), Some(Kit::Acoustic));
        let (left, _) = render(&mut drum, 128);
        assert!(left.iter().all(|s| *s == 0.0));
        drum.trigger(Voice::Kick.index(), 100);
        assert_eq!(drum.active_voices(), 1);
    }

    #[test]
    fn bad_slots_and_triggers_before_a_kit_are_ignored() {
        let mut drum = Machine::new(44_100, 64);
        drum.trigger(Voice::Kick.index(), 100);
        assert_eq!(drum.active_voices(), 0);

        let mut drum = machine(Kit::Acoustic);
        drum.trigger(Voice::COUNT, 100);
        drum.trigger(usize::MAX, 100);
        assert_eq!(drum.active_voices(), 0);
    }

    #[test]
    fn a_different_block_split_gives_the_same_samples() {
        let mut split = Machine::new(44_100, 10);
        let mut whole = Machine::new(44_100, 20);
        split.load_kit(Kit::Techno);
        whole.load_kit(Kit::Techno);
        for drum in [&mut split, &mut whole] {
            drum.trigger(Voice::Kick.index(), 100);
            drum.trigger_at(Voice::Snare.index(), 80, 13);
        }
        let mut split_left = Vec::new();
        let mut split_right = Vec::new();
        for frames in [37usize, 27, 64] {
            let (left, right) = render(&mut split, frames);
            split_left.extend(left.into_iter().map(|s| s.to_bits()));
            split_right.extend(right.into_iter().map(|s| s.to_bits()));
        }
        let (whole_left, whole_right) = render(&mut whole, 128);
        let whole_left: Vec<u32> = whole_left.iter().map(|s| s.to_bits()).collect();
        let whole_right: Vec<u32> = whole_right.iter().map(|s| s.to_bits()).collect();
        assert_eq!(split_left, whole_left);
        assert_eq!(split_right, whole_right);
    }

    #[test]
    fn a_short_right_slice_is_not_indexed_out_of_bounds() {
        let mut drum = machine(Kit::Acoustic);
        drum.trigger(Voice::Kick.index(), 100);
        let mut left = vec![9.0f32; 8];
        let mut right = vec![9.0f32; 5];
        drum.render(&mut left, &mut right);
        assert_eq!(&left[..5], &right[..5]);
        assert!(left[5..].iter().all(|sample| *sample == 9.0));
    }

    #[test]
    fn an_empty_block_changes_nothing() {
        let mut drum = machine(Kit::Acoustic);
        drum.trigger_at(Voice::Kick.index(), 100, 4);
        let mut left: Vec<f32> = Vec::new();
        let mut right: Vec<f32> = Vec::new();
        drum.render(&mut left, &mut right);
        assert_eq!(drum.active_voices(), 1);
        let (left, _) = render(&mut drum, 8);
        assert!(left[..4].iter().all(|s| *s == 0.0));
        assert!(left[4..].iter().any(|s| *s != 0.0));
    }
}
