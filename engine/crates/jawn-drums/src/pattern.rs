//! A sixteenth-note chart, for a later transport wiring.
//!
//! The Studio chart is a length in sixteenth steps and one velocity row per
//! voice (`studioDrums.steps` in `public/js/manager/studio/11_drums.js`). This
//! type is the same data in a fixed-size form: at most 128 steps, eight voice
//! rows, and a loop flag.
//!
//! It deliberately owns no clock. The caller supplies the frames per sixteenth
//! step (see [`sixteenth_frames`]), so a transport can ask "which steps begin in
//! this block, and at what sample offsets?" and pass each event straight to
//! [`Machine::trigger_at`](crate::Machine::trigger_at). The pattern API allocates
//! nothing: [`Pattern::events_at`] writes into a caller-provided slice.

use crate::Voice;

/// The shortest chart, four steps: one beat.
pub const MIN_STEPS: usize = 4;

/// The longest chart, 128 steps: eight bars.
pub const MAX_STEPS: usize = 128;

/// One scheduled hit: a voice slot, its velocity and where in the block it
/// starts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PatternEvent {
    /// The row, a [`Voice::index`].
    pub slot: usize,
    /// The Studio velocity, `1..=100`.
    pub velocity: u8,
    /// The frame offset from the block start passed to [`Pattern::events_at`].
    pub offset_frames: usize,
}

/// A loop of sixteenth steps with one velocity row per voice.
///
/// A velocity of `0` is an empty step. The chart starts with every step empty
/// and looping on, like `studioDrumsDefaults`.
#[derive(Debug, Clone)]
pub struct Pattern {
    frames_per_step: u64,
    length_steps: usize,
    looped: bool,
    rows: [[u8; MAX_STEPS]; Voice::COUNT],
}

impl Pattern {
    /// An empty chart of `length_steps` steps, where each step lasts
    /// `frames_per_step` frames.
    ///
    /// The length is normalised the way the Studio does it: zero or an
    /// unusable value opens as 16, the value is rounded to the nearest multiple
    /// of four, and the result is clamped to `4..=128`. A zero
    /// `frames_per_step` is treated as 1.
    pub fn new(length_steps: usize, frames_per_step: u64) -> Self {
        Pattern {
            frames_per_step: frames_per_step.max(1),
            length_steps: normalise_length(length_steps),
            looped: true,
            rows: [[0u8; MAX_STEPS]; Voice::COUNT],
        }
    }

    /// The chart length in sixteenth steps.
    pub fn length_steps(&self) -> usize {
        self.length_steps
    }

    /// The duration of one step in frames.
    pub fn frames_per_step(&self) -> u64 {
        self.frames_per_step
    }

    /// Whether the chart wraps to step zero after its last step.
    pub fn looped(&self) -> bool {
        self.looped
    }

    /// Set the loop flag.
    pub fn set_looped(&mut self, looped: bool) {
        self.looped = looped;
    }

    /// Place a velocity on one step. Zero clears it and values above 100 are
    /// clamped to 100, matching the Studio's percent scale.
    ///
    /// Returns `false` and changes nothing when `slot` is not a voice or `step`
    /// is outside the chart.
    pub fn set_velocity(&mut self, slot: usize, step: usize, velocity: u8) -> bool {
        if slot >= Voice::COUNT || step >= self.length_steps {
            return false;
        }
        self.rows[slot][step] = velocity.min(100);
        true
    }

    /// The velocity at one step, or `0` for an empty or out-of-range position.
    pub fn velocity(&self, slot: usize, step: usize) -> u8 {
        if slot >= Voice::COUNT || step >= self.length_steps {
            return 0;
        }
        self.rows[slot][step]
    }

    /// The number of complete steps since the chart's origin, counting whole
    /// loops. This is `frame / frames_per_step`; the chart's length does not cap
    /// it, so a transport can compare it with [`Pattern::is_finished`].
    pub fn steps_since(&self, frame: u64) -> u64 {
        frame / self.frames_per_step
    }

    /// The step that begins at or before `frame` after the chart's origin, or
    /// `None` once a non-looping chart has run past its last step.
    pub fn step_at(&self, frame: u64) -> Option<usize> {
        let step = self.steps_since(frame);
        if self.looped {
            Some((step % self.length_steps as u64) as usize)
        } else if step < self.length_steps as u64 {
            Some(step as usize)
        } else {
            None
        }
    }

    /// Whether a non-looping chart has played its last step by `frame`. Always
    /// `false` for a looping chart.
    pub fn is_finished(&self, frame: u64) -> bool {
        !self.looped && self.steps_since(frame) >= self.length_steps as u64
    }

    /// Write the events that begin in the block `[frame, frame + frames)` into
    /// `out`, and return how many were written.
    ///
    /// A step boundary belongs to the block when its frame is at least `frame`
    /// and strictly less than `frame + frames`, so consecutive blocks cover the
    /// chart without double-triggering a boundary. Events are ordered by
    /// boundary time, then by slot. Zero velocities are skipped. If `out` is too
    /// small, the extra events are dropped and the return value is capped at
    /// `out.len()`; the caller can size it as
    /// `Voice::COUNT * ceil(frames / frames_per_step)`.
    pub fn events_at(
        &self,
        frame: u64,
        frames: usize,
        out: &mut [PatternEvent],
    ) -> usize {
        if frames == 0 || out.is_empty() {
            return 0;
        }
        let end = frame.saturating_add(frames as u64);
        let fps = self.frames_per_step;
        let mut boundary = (frame / fps) * fps;
        if boundary < frame {
            boundary = boundary.saturating_add(fps);
        }
        let mut written = 0usize;
        while boundary < end {
            let step_total = boundary / fps;
            let step = if self.looped {
                (step_total % self.length_steps as u64) as usize
            } else if step_total < self.length_steps as u64 {
                step_total as usize
            } else {
                break;
            };
            let offset = (boundary - frame) as usize;
            for slot in 0..Voice::COUNT {
                let velocity = self.rows[slot][step];
                if velocity == 0 {
                    continue;
                }
                if written >= out.len() {
                    return written;
                }
                out[written] = PatternEvent {
                    slot,
                    velocity,
                    offset_frames: offset,
                };
                written += 1;
            }
            if boundary > u64::MAX - fps {
                break;
            }
            boundary += fps;
        }
        written
    }
}

/// The number of frames in one sixteenth step at `rate` hertz and `bpm` beats
/// per minute.
///
/// The Studio's `stepDur` is `60 / bpm / 4` seconds (a sixteenth). This helper
/// rounds it to the nearest frame and never returns zero. An invalid rate or
/// tempo yields one frame.
pub fn sixteenth_frames(rate: u32, bpm: f32) -> u64 {
    if rate == 0 || !bpm.is_finite() || bpm <= 0.0 {
        return 1;
    }
    let frames = rate as f64 * 60.0 / bpm as f64 / 4.0;
    let rounded = frames.round();
    if rounded < 1.0 {
        1
    } else if rounded >= u64::MAX as f64 {
        u64::MAX
    } else {
        rounded as u64
    }
}

/// The Studio's `studioDrumsNormaliseLength`: 0 opens as 16, then round to the
/// nearest multiple of four and clamp to one beat through eight bars.
fn normalise_length(steps: usize) -> usize {
    let steps = if steps == 0 { 16 } else { steps };
    let rounded = steps.saturating_add(2) / 4 * 4;
    rounded.clamp(MIN_STEPS, MAX_STEPS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lengths_are_normalised_like_the_studio() {
        assert_eq!(Pattern::new(0, 100).length_steps(), 16);
        assert_eq!(Pattern::new(1, 100).length_steps(), 4);
        assert_eq!(Pattern::new(3, 100).length_steps(), 4);
        assert_eq!(Pattern::new(6, 100).length_steps(), 8);
        assert_eq!(Pattern::new(100, 100).length_steps(), 100);
        assert_eq!(Pattern::new(129, 100).length_steps(), 128);
        assert_eq!(Pattern::new(1_000, 100).length_steps(), 128);
        assert_eq!(Pattern::new(16, 0).frames_per_step(), 1);
    }

    #[test]
    fn velocities_are_clamped_and_bounds_are_checked() {
        let mut pattern = Pattern::new(16, 100);
        assert!(pattern.set_velocity(Voice::Kick.index(), 0, 250));
        assert_eq!(pattern.velocity(Voice::Kick.index(), 0), 100);
        assert!(pattern.set_velocity(Voice::Kick.index(), 1, 70));
        assert_eq!(pattern.velocity(Voice::Kick.index(), 1), 70);
        assert!(pattern.set_velocity(Voice::Kick.index(), 1, 0));
        assert_eq!(pattern.velocity(Voice::Kick.index(), 1), 0);
        assert!(!pattern.set_velocity(Voice::COUNT, 0, 100));
        assert!(!pattern.set_velocity(Voice::Kick.index(), 16, 100));
        assert_eq!(pattern.velocity(Voice::COUNT, 0), 0);
        assert_eq!(pattern.velocity(Voice::Kick.index(), 16), 0);
    }

    #[test]
    fn steps_since_and_step_at_follow_the_clock() {
        let mut pattern = Pattern::new(8, 100);
        assert_eq!(pattern.steps_since(0), 0);
        assert_eq!(pattern.steps_since(99), 0);
        assert_eq!(pattern.steps_since(100), 1);
        assert_eq!(pattern.steps_since(899), 8);
        assert_eq!(pattern.step_at(0), Some(0));
        assert_eq!(pattern.step_at(799), Some(7));
        assert_eq!(pattern.step_at(800), Some(0), "a looping chart wraps");

        pattern.set_looped(false);
        assert_eq!(pattern.step_at(799), Some(7));
        assert_eq!(pattern.step_at(800), None);
        assert!(!pattern.is_finished(799));
        assert!(pattern.is_finished(800));
    }

    #[test]
    fn events_carry_their_sample_offsets() {
        let mut pattern = Pattern::new(16, 1000);
        pattern.set_velocity(Voice::Kick.index(), 0, 100);
        pattern.set_velocity(Voice::Snare.index(), 2, 70);
        pattern.set_velocity(Voice::ClosedHat.index(), 2, 40);
        let mut events = [PatternEvent {
            slot: 0,
            velocity: 0,
            offset_frames: 0,
        }; 16];
        let count = pattern.events_at(0, 5_000, &mut events);
        assert_eq!(count, 3);
        assert_eq!(events[0].slot, Voice::Kick.index());
        assert_eq!(events[0].offset_frames, 0);
        assert_eq!(events[1].slot, Voice::Snare.index());
        assert_eq!(events[1].velocity, 70);
        assert_eq!(events[1].offset_frames, 2_000);
        assert_eq!(events[2].slot, Voice::ClosedHat.index());
        assert_eq!(events[2].offset_frames, 2_000);
    }

    #[test]
    fn events_respect_a_block_that_starts_mid_step() {
        let mut pattern = Pattern::new(16, 1000);
        pattern.set_velocity(Voice::Snare.index(), 2, 70);
        let mut events = [PatternEvent {
            slot: 0,
            velocity: 0,
            offset_frames: 0,
        }; 8];
        let count = pattern.events_at(1_500, 1_000, &mut events);
        assert_eq!(count, 1);
        assert_eq!(events[0].offset_frames, 500);
    }

    #[test]
    fn a_loop_repeats_and_a_non_loop_stops() {
        let mut pattern = Pattern::new(4, 100);
        pattern.set_velocity(Voice::Kick.index(), 0, 100);
        let mut events = [PatternEvent {
            slot: 0,
            velocity: 0,
            offset_frames: 0,
        }; 16];
        let count = pattern.events_at(0, 1_000, &mut events);
        assert_eq!(count, 3);
        assert_eq!(events[0].offset_frames, 0);
        assert_eq!(events[1].offset_frames, 400);
        assert_eq!(events[2].offset_frames, 800);

        pattern.set_looped(false);
        let count = pattern.events_at(0, 1_000, &mut events);
        assert_eq!(count, 1, "a non-looping chart ends after step 3");
    }

    #[test]
    fn a_small_output_slice_truncates_without_panicking() {
        let mut pattern = Pattern::new(4, 100);
        for voice in Voice::ALL {
            pattern.set_velocity(voice.index(), 0, 100);
        }
        let mut events = [PatternEvent {
            slot: 0,
            velocity: 0,
            offset_frames: 0,
        }; 3];
        let count = pattern.events_at(0, 100, &mut events);
        assert_eq!(count, 3);
    }

    #[test]
    fn an_empty_block_has_no_events() {
        let mut pattern = Pattern::new(16, 100);
        pattern.set_velocity(Voice::Kick.index(), 0, 100);
        let mut events = [PatternEvent {
            slot: 0,
            velocity: 0,
            offset_frames: 0,
        }; 8];
        assert_eq!(pattern.events_at(50, 0, &mut events), 0);
        assert_eq!(pattern.events_at(51, 10, &mut events), 0);
    }

    #[test]
    fn sixteenth_frames_matches_a_sixteenth_at_120_bpm() {
        assert_eq!(sixteenth_frames(48_000, 120.0), 6_000);
        assert_eq!(sixteenth_frames(44_100, 120.0), 5_513);
        assert_eq!(sixteenth_frames(48_000, 0.0), 1);
        assert_eq!(sixteenth_frames(0, 120.0), 1);
    }
}
