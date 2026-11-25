//! The `gate` pedal: a noise gate with attack, hold and release.
//!
//! # The model
//!
//! ```text
//! in ──► peak follower ──► threshold compare ──► hold ──► gain ramp ──► out
//!                                    │                         ▲
//!                          above: open over attack             │
//!                          below: close to range over release ─┘
//! ```
//!
//! The detector is a fast peak follower. While it is above `thresh` the gate
//! opens over `attack`; when it falls below, the gate waits `hold` (so a
//! decaying note is not chopped between its cycles) and then closes toward the
//! `range` floor over `release`. The gain is a one-pole toward the current
//! target, so both edges are ramps rather than steps and neither clicks.
//!
//! `thresh` and `range` are dBFS; `range` is the closed floor, and `0 dB` makes
//! the closed state unity, so the pedal is exactly transparent. The engine holds
//! `attack`, `hold` and `release` in **seconds**; the wire sends milliseconds
//! and [`InsertKind::native_value`](crate::effect::InsertKind::native_value)
//! converts them, the same way the compressor and limiter do.
//!
//! # The honest approximation
//!
//! * The detector is a one-pole peak follower, not a sample-by-sample true RMS
//!   or a look-ahead window. A gate with look-ahead can open before a transient
//!   and is a different tool; this one reacts, so a very fast attack can clip
//!   the first few milliseconds of a hard note.
//! * There is no hysteresis band. `hold` is what stops chatter around the
//!   threshold; a signal hovering exactly at `thresh` can still flutter, which
//!   is the honest behaviour of a gate without a key filter.
//! * The closed floor is a gain, not a mute: at `range = −80 dB` the residual is
//!   inaudible but not arithmetically zero. `range = 0 dB` is the only
//!   bit-exactly transparent setting.
//! * Knob moves are one-pole smoothed once per block, so a threshold or time
//!   drag cannot step the gain. Silence in stays exact silence out, because the
//!   pedal only scales the input.

use super::{one_pole, one_pole_block, Effect, SMOOTH_SECONDS};

/// The detector's own attack and release: fast enough to follow a note, slow
/// enough not to follow a single sample. These are not the gate's knobs.
const DETECTOR_ATTACK_SECONDS: f32 = 0.0005;
const DETECTOR_RELEASE_SECONDS: f32 = 0.02;

#[derive(Debug)]
pub struct Gate {
    rate: u32,
    target_thresh_db: f32,
    thresh_db: f32,
    target_attack_s: f32,
    attack_s: f32,
    target_hold_s: f32,
    hold_s: f32,
    target_release_s: f32,
    release_s: f32,
    target_range_db: f32,
    range_db: f32,
    detector: f32,
    gain: f32,
    hold_remaining: usize,
    detector_attack: f32,
    detector_release: f32,
    smooth: f32,
}

impl Gate {
    pub const MIN_THRESH_DB: f32 = -60.0;
    pub const MAX_THRESH_DB: f32 = 0.0;
    pub const MIN_ATTACK_S: f32 = 0.000_1;
    pub const MAX_ATTACK_S: f32 = 0.05;
    pub const MIN_HOLD_S: f32 = 0.0;
    pub const MAX_HOLD_S: f32 = 0.5;
    pub const MIN_RELEASE_S: f32 = 0.02;
    pub const MAX_RELEASE_S: f32 = 1.0;
    pub const MIN_RANGE_DB: f32 = -80.0;
    pub const MAX_RANGE_DB: f32 = 0.0;

    pub fn new(thresh_db: f32, attack_s: f32, hold_s: f32, release_s: f32, range_db: f32) -> Self {
        let thresh_db = thresh_db.clamp(Self::MIN_THRESH_DB, Self::MAX_THRESH_DB);
        let attack_s = attack_s.clamp(Self::MIN_ATTACK_S, Self::MAX_ATTACK_S);
        let hold_s = hold_s.clamp(Self::MIN_HOLD_S, Self::MAX_HOLD_S);
        let release_s = release_s.clamp(Self::MIN_RELEASE_S, Self::MAX_RELEASE_S);
        let range_db = range_db.clamp(Self::MIN_RANGE_DB, Self::MAX_RANGE_DB);
        Gate {
            rate: 48_000,
            target_thresh_db: thresh_db,
            thresh_db,
            target_attack_s: attack_s,
            attack_s,
            target_hold_s: hold_s,
            hold_s,
            target_release_s: release_s,
            release_s,
            target_range_db: range_db,
            range_db,
            detector: 0.0,
            gain: 1.0,
            hold_remaining: 0,
            detector_attack: 0.0,
            detector_release: 0.0,
            smooth: 0.0,
        }
    }
}

impl Effect for Gate {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.thresh_db = self.target_thresh_db;
        self.attack_s = self.target_attack_s;
        self.hold_s = self.target_hold_s;
        self.release_s = self.target_release_s;
        self.range_db = self.target_range_db;
        self.detector = 0.0;
        self.gain = 1.0;
        self.hold_remaining = 0;
        self.detector_attack = one_pole(DETECTOR_ATTACK_SECONDS, self.rate) as f32;
        self.detector_release = one_pole(DETECTOR_RELEASE_SECONDS, self.rate) as f32;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() || self.rate == 0 {
            return;
        }
        // Time constants are rebuilt once per block from the smoothed knobs, so
        // the sample loop is arithmetic only.
        let block_smooth = one_pole_block(SMOOTH_SECONDS, self.rate, block.len()) as f32;
        self.thresh_db += (self.target_thresh_db - self.thresh_db) * block_smooth;
        self.attack_s += (self.target_attack_s - self.attack_s) * block_smooth;
        self.hold_s += (self.target_hold_s - self.hold_s) * block_smooth;
        self.release_s += (self.target_release_s - self.release_s) * block_smooth;
        self.range_db += (self.target_range_db - self.range_db) * block_smooth;

        let rate = self.rate as f32;
        let threshold = 10f32.powf(self.thresh_db / 20.0);
        let floor = 10f32.powf(self.range_db / 20.0).clamp(0.0, 1.0);
        let attack = one_pole(self.attack_s, self.rate) as f32;
        let release = one_pole(self.release_s, self.rate) as f32;
        let hold_samples = (self.hold_s * rate).round() as usize;

        for sample in block.iter_mut() {
            let magnitude = sample.abs();
            let coefficient = if magnitude > self.detector {
                self.detector_attack
            } else {
                self.detector_release
            };
            self.detector += (magnitude - self.detector) * coefficient;

            let target = if self.detector >= threshold {
                self.hold_remaining = hold_samples;
                1.0
            } else if self.hold_remaining > 0 {
                self.hold_remaining -= 1;
                1.0
            } else {
                floor
            };

            let ramp = if target > self.gain { attack } else { release };
            self.gain += (target - self.gain) * ramp;
            *sample *= self.gain;
        }
    }

    fn reset(&mut self) {
        self.thresh_db = self.target_thresh_db;
        self.attack_s = self.target_attack_s;
        self.hold_s = self.target_hold_s;
        self.release_s = self.target_release_s;
        self.range_db = self.target_range_db;
        self.detector = 0.0;
        self.gain = 1.0;
        self.hold_remaining = 0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "thresh" => {
                if usable {
                    self.target_thresh_db = value.clamp(Self::MIN_THRESH_DB, Self::MAX_THRESH_DB);
                }
                true
            }
            // The wire's milliseconds arrive here as seconds.
            "attack" => {
                if usable {
                    self.target_attack_s = value.clamp(Self::MIN_ATTACK_S, Self::MAX_ATTACK_S);
                }
                true
            }
            "hold" => {
                if usable {
                    self.target_hold_s = value.clamp(Self::MIN_HOLD_S, Self::MAX_HOLD_S);
                }
                true
            }
            "release" => {
                if usable {
                    self.target_release_s = value.clamp(Self::MIN_RELEASE_S, Self::MAX_RELEASE_S);
                }
                true
            }
            "range" => {
                if usable {
                    self.target_range_db = value.clamp(Self::MIN_RANGE_DB, Self::MAX_RANGE_DB);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "gate"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| {
                (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude
            })
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    fn render(gate: &mut Gate, input: &[f32]) -> Vec<f32> {
        gate.prepare(RATE, input.len());
        let mut block = input.to_vec();
        gate.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut gate = Gate::new(-45.0, 0.001, 0.05, 0.15, -60.0);
        let output = render(&mut gate, &vec![0.0f32; 8192]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn a_zero_range_is_transparent() {
        // The closed floor is unity, so the gain never moves off one.
        let input = sine(440.0, 0.5, 8192);
        let mut gate = Gate::new(-30.0, 0.001, 0.05, 0.15, 0.0);
        let output = render(&mut gate, &input);
        assert_eq!(output, input, "a 0 dB range still gated");
    }

    #[test]
    fn a_loud_note_passes_and_a_quiet_one_closes() {
        let loud = sine(440.0, 0.5, RATE as usize);
        let mut open = Gate::new(-30.0, 0.001, 0.01, 0.05, -60.0);
        let output = render(&mut open, &loud);
        let ratio = rms(&output[4_800..]) / rms(&loud[4_800..]);
        assert!(ratio > 0.9, "the gate closed on a loud note: {ratio}");

        // −60 dBFS is well below the −30 dB threshold.
        let quiet = sine(440.0, 0.001, RATE as usize);
        let mut closed = Gate::new(-30.0, 0.001, 0.01, 0.05, -60.0);
        let output = render(&mut closed, &quiet);
        let ratio = rms(&output[9_600..]) / rms(&quiet[9_600..]);
        assert!(ratio < 0.1, "the gate stayed open on a quiet note: {ratio}");
    }

    #[test]
    fn a_longer_hold_keeps_the_gate_open_after_the_signal() {
        // A 20 ms burst, then a quiet tail below the threshold: with a 400 ms
        // hold the tail passes while the hold runs, with no hold it closes.
        let mut signal = vec![0.005f32; RATE as usize / 2];
        for sample in signal.iter_mut().take(960) {
            *sample = 0.5;
        }
        let mut long = Gate::new(-30.0, 0.001, 0.4, 0.02, -60.0);
        let held = render(&mut long, &signal);
        let kept = rms(&held[12_000..18_000]);
        assert!(kept > 0.002, "the hold did not keep the gate open: {kept}");

        let mut short = Gate::new(-30.0, 0.001, 0.0, 0.02, -60.0);
        let closed = render(&mut short, &signal);
        let gone = rms(&closed[12_000..18_000]);
        assert!(
            gone < kept / 10.0,
            "without a hold the tail stayed open: {gone} against {kept}"
        );
    }

    #[test]
    fn attack_and_release_clamp_and_nan_is_ignored() {
        let mut gate = Gate::new(-45.0, 0.001, 0.05, 0.15, -60.0);
        assert!(gate.set("thresh", 10.0));
        assert_eq!(gate.target_thresh_db, 0.0);
        assert!(gate.set("attack", 1.0));
        assert_eq!(gate.target_attack_s, Gate::MAX_ATTACK_S);
        assert!(gate.set("hold", 10.0));
        assert_eq!(gate.target_hold_s, Gate::MAX_HOLD_S);
        assert!(gate.set("release", 0.0));
        assert_eq!(gate.target_release_s, Gate::MIN_RELEASE_S);
        assert!(gate.set("range", -200.0));
        assert_eq!(gate.target_range_db, Gate::MIN_RANGE_DB);
        assert!(gate.set("range", f32::NAN));
        assert_eq!(gate.target_range_db, Gate::MIN_RANGE_DB);
        assert!(!gate.set("mix", 1.0));
        assert!(!gate.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_wire_milliseconds_become_seconds() {
        assert_eq!(
            InsertKind::Gate.native_value("attack", 1.0),
            0.001,
            "attack was not converted"
        );
        assert_eq!(InsertKind::Gate.native_value("hold", 50.0), 0.05);
        assert_eq!(InsertKind::Gate.native_value("release", 150.0), 0.15);
        // Threshold and range are dB and must not be divided.
        assert_eq!(InsertKind::Gate.native_value("thresh", -45.0), -45.0);
        assert_eq!(InsertKind::Gate.native_value("range", -60.0), -60.0);
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("gate"), Some(InsertKind::Gate));
        assert_eq!(InsertKind::Gate.name(), "gate");
        assert_eq!(
            InsertKind::Gate.controls(),
            &["thresh", "attack", "hold", "release", "range"]
        );
        assert_eq!(InsertKind::Gate.code(), 21);
        assert_eq!(InsertKind::from_code(21), Some(InsertKind::Gate));
        assert_eq!(InsertKind::Gate.build().name(), "gate");
    }
}
