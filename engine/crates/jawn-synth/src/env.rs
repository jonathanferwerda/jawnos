//! The two envelopes: the amp ADSR and the filter envelope.
//!
//! The amp envelope is linear, matching `voiceEnv()` in `01_engine.js`, which
//! schedules `linearRampToValueAtTime`. Its release is a linear ramp to exactly
//! zero, so a released voice really is silent when the release ends; the
//! browser uses `setTargetAtTime`, which approaches its floor but never reaches
//! it, and then kills the voice on a timer. That is a deliberate divergence:
//! this engine can prove the tail is zero.
//!
//! The filter envelope copies `filterEnv()`: it starts at the velocity- and
//! keytrack-scaled peak at note-on and exponentially falls to the sustain
//! cutoff over attack plus decay, then holds. The browser never releases the
//! filter envelope, so `fenv.r` is read for compatibility and otherwise
//! unused, exactly as in the browser.

use crate::patch::Envelope;

/// Where an ADSR currently is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
    Idle,
    Attack,
    Decay,
    Sustain,
    Release,
}

/// A linear ADSR.
pub(crate) struct Adsr {
    stage: Stage,
    level: f32,
    peak: f32,
    sustain: f32,
    attack_step: f32,
    decay_step: f32,
    release_step: f32,
}

impl Adsr {
    /// An idle envelope at zero.
    pub fn new() -> Self {
        Adsr {
            stage: Stage::Idle,
            level: 0.0,
            peak: 0.0,
            sustain: 0.0,
            attack_step: 0.0,
            decay_step: 0.0,
            release_step: 0.0,
        }
    }

    /// Start a new attack to `peak`, with the stage times in `env`.
    pub fn trigger(&mut self, env: &Envelope, peak: f32, rate: f32) {
        // `voiceEnv` floors both times at one millisecond.
        let attack = env.a.max(0.001);
        let decay = env.d.max(0.001);
        self.peak = peak;
        self.sustain = peak * env.s.clamp(0.0, 1.0);
        self.level = 0.0;
        self.attack_step = peak / (attack * rate);
        self.decay_step = (peak - self.sustain) / (decay * rate);
        self.release_step = 0.0;
        self.stage = Stage::Attack;
    }

    /// Advance one sample and return the new level.
    pub fn next(&mut self) -> f32 {
        match self.stage {
            Stage::Attack => {
                self.level += self.attack_step;
                if self.level >= self.peak {
                    self.level = self.peak;
                    self.stage = if self.sustain >= self.peak {
                        Stage::Sustain
                    } else {
                        Stage::Decay
                    };
                }
            }
            Stage::Decay => {
                if self.decay_step <= 0.0 {
                    self.level = self.sustain;
                    self.stage = Stage::Sustain;
                } else {
                    self.level -= self.decay_step;
                    if self.level <= self.sustain {
                        self.level = self.sustain;
                        self.stage = Stage::Sustain;
                    }
                }
            }
            Stage::Sustain => {}
            Stage::Release => {
                self.level -= self.release_step;
                if self.level <= 0.0 {
                    self.level = 0.0;
                    self.stage = Stage::Idle;
                }
            }
            Stage::Idle => {
                self.level = 0.0;
            }
        }
        self.level
    }

    /// Begin the release from the current level. The ramp reaches exactly zero
    /// after `env.r` seconds (`0.001` if shorter).
    pub fn release(&mut self, env: &Envelope, rate: f32) {
        if self.stage == Stage::Idle || self.level <= 0.0 {
            self.level = 0.0;
            self.stage = Stage::Idle;
            return;
        }
        let release = env.r.max(0.001);
        self.release_step = self.level / (release * rate);
        self.stage = Stage::Release;
    }

    /// Cut the envelope off immediately, for voice stealing.
    pub fn hard_stop(&mut self) {
        self.stage = Stage::Idle;
        self.level = 0.0;
    }

    /// Whether the envelope has reached the end of a release.
    pub fn is_idle(&self) -> bool {
        self.stage == Stage::Idle
    }
}

/// The filter envelope, in Hz.
pub(crate) struct FilterEnv {
    current: f32,
    target: f32,
    ratio: f32,
    left: u32,
}

impl FilterEnv {
    /// An idle envelope.
    pub fn new() -> Self {
        FilterEnv { current: 0.0, target: 0.0, ratio: 1.0, left: 0 }
    }

    /// Forget the current state.
    pub fn reset(&mut self) {
        self.current = 0.0;
        self.target = 0.0;
        self.ratio = 1.0;
        self.left = 0;
    }

    /// Start at `peak_hz` and exponentially fall to `target_hz` over
    /// `a + d` seconds.
    pub fn trigger(&mut self, peak_hz: f32, target_hz: f32, a: f32, d: f32, rate: f32) {
        let peak = peak_hz.max(1.0);
        let target = target_hz.max(1.0);
        let steps = ((a.max(0.001) + d.max(0.001)) * rate).max(1.0) as u32;
        self.current = peak;
        self.target = target;
        self.left = steps;
        self.ratio = if steps > 0 {
            (target / peak).powf(1.0 / steps as f32)
        } else {
            1.0
        };
    }

    /// Advance one sample and return the cutoff in Hz.
    pub fn next(&mut self) -> f32 {
        if self.left > 0 {
            self.current *= self.ratio;
            self.left -= 1;
            if self.left == 0 {
                self.current = self.target;
            }
        }
        self.current
    }
}

#[cfg(test)]
mod tests {
    use super::{Adsr, FilterEnv};
    use crate::patch::Envelope;

    #[test]
    fn attack_decay_sustain_release() {
        let env = Envelope { a: 0.001, d: 0.001, s: 0.5, r: 0.001 };
        let rate = 48000.0;
        let mut adsr = Adsr::new();
        adsr.trigger(&env, 1.0, rate);
        let mut last = 0.0;
        for _ in 0..48 {
            last = adsr.next();
        }
        assert!((last - 1.0).abs() < 0.01, "attack peak {last}");
        for _ in 0..4800 {
            last = adsr.next();
        }
        assert!((last - 0.5).abs() < 0.01, "sustain {last}");
        adsr.release(&env, rate);
        for _ in 0..96 {
            last = adsr.next();
        }
        assert_eq!(last, 0.0);
        assert!(adsr.is_idle());
    }

    #[test]
    fn filter_env_falls_to_target() {
        let mut f = FilterEnv::new();
        f.trigger(1000.0, 200.0, 0.01, 0.01, 48000.0);
        let mut last = 0.0;
        for _ in 0..2000 {
            last = f.next();
        }
        assert!((last - 200.0).abs() < 0.5, "{last}");
    }
}
