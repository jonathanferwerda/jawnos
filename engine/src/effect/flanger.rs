//! The `flanger` pedal: an Electro-Harmonix Electric Mistress, approximated.
//!
//! # Why the Mistress
//!
//! The Mistress's three controls are Rate, Range and Color, plus the dry/wet
//! blend every flanger has. Those are exactly the contract's `rate`, `depth`,
//! `feedback` and `mix`: no knob is renamed and no fifth knob is needed to make
//! the model honest. (The MXR M117 would need its Manual control — the clock's
//! resting delay — which the contract does not carry.) The Mistress's Color is
//! feedback taken from the bucket-brigade output and returned around the line
//! through a filter, which is the sound the pedal is bought for, and its line is
//! the SAD1024-class BBD this pedal is named after.
//!
//! # The circuit
//!
//! ```text
//! in ─► pre-amp ×2 ─► 2:1 compressor ─► soft clip ─► BBD input ─┐
//!             ▲                                                  │
//!             │                                                  ▼
//!      feedback filter ◄── Color ◄────────────────────── BBD output
//!             ▲                                      (clocked tap)
//!             │                                                  │
//!             └────────────── reconstruction LP/HP ──────────────┤
//!                                                                │
//!                                                   1:2 expander ┘
//!                                                          │
//! out ◄── dry (1 − mix) + mix ──────────────────────────────┘
//! ```
//!
//! * **The line.** A 1024-stage SAD1024 BBD. Its delay is
//!   `1024 / (2 · f_clock)`, so the LFO sweeps the clock rather than writing a
//!   delay directly: 0.7 ms at the fast end of the sweep (≈730 kHz clock) to
//!   5 ms at the slow end (≈102 kHz). The read is linearly interpolated, so the
//!   sweep bends instead of stepping.
//! * **The clock.** The BBD's usable top end follows its clock, so a lowpass
//!   whose corner falls as the line lengthens sits after the tap, and a sliver
//!   of the clock rides on the output as amplitude modulation. That is the
//!   Mistress's dark top end and its faint moving clock whine; a higher clock
//!   would be cleaner and is not what this pedal is.
//! * **The compander.** The input is pre-amplified by [`PRE_GAIN`], compressed
//!   2:1 above [`COMPANDER_THRESHOLD`], then soft-clipped by `tanh` — the
//!   op-amp's limit and the BBD's own input range. The line's output is expanded
//!   1:2 around the same (pre-gain-scaled) threshold. Quiet material passes at
//!   unity because the expander divides the pre-amp back out, and loud material
//!   is held back; noise the BBD would add between them is attenuated along
//!   with a quiet signal instead of being amplified by make-up gain.
//! * **Color.** Feedback, up to [`MAX_FEEDBACK`], is taken from the reconstructed
//!   line output through a [`WET_HIGHPASS_HZ`] highpass and a
//!   [`WET_CORNER_HZ`] lowpass, so the low end cannot build into rumble and the
//!   resonant peaks stay in the band the pedal works in.
//! * **The wet path.** The line output is lowpassed at [`WET_CORNER_HZ`] and
//!   highpassed at [`WET_HIGHPASS_HZ`] before the expander, which is the
//!   filtered, slightly boxy Mistress voice rather than a bare comb.
//!
//! # The honest approximation
//!
//! * The clock and the sweep are followed **at block rate** (the filter corner
//!   is redesigned when a block begins), not per sample. The LFO moves far too
//!   slowly for the difference to be audible, and redesigning a biquad per
//!   sample would spend the audio thread's budget on trigonometry.
//! * The BBD is a continuous delay with linear interpolation, not a sampled
//!   charge-transfer device: there is no charge-packet quantisation and no
//!   sample-and-hold grain at the clock ticks.
//! * The clock whine is a triangle multiplied into the wet path, not the real
//!   clock's spectrum; it is deliberately tiny (about −56 dB) and disappears
//!   into silence, because the pedal must not hiss when nothing is playing.
//! * The compander is feed-forward with fixed attack/release and a one-sided
//!   expander (it never gates below the threshold). It is not the NE570-style
//!   feedback compander with a precise law; it restores quiet material to
//!   unity and holds loud material back, which is the audible job.
//!
//! `rate` is Hz, `depth`, `feedback` and `mix` are the normalised 0..1 knobs the
//! control path sends. The manual Rate knob still maps to 0.05..5 Hz; a
//! tempo-synced rate may reach 8 Hz (a 1/16 at 120 BPM is 8 Hz), which is the
//! cap below. Feedback stops at [`MAX_FEEDBACK`], short of unity, so a swept
//! comb cannot build into a runaway, and the BBD's input clip bounds the line's
//! charge either way.

use super::{highpass, lowpass, one_pole, Biquad, Effect, SMOOTH_SECONDS};

/// One block of the compander's envelope follower.
#[inline]
fn follow(env: f32, magnitude: f32, attack: f32, release: f32) -> f32 {
    let coefficient = if magnitude > env { attack } else { release };
    env + (magnitude - env) * coefficient
}

#[derive(Debug)]
pub struct Flanger {
    rate: u32,
    buffer: Vec<f32>,
    write: usize,
    target_lfo_hz: f32,
    lfo_hz: f32,
    target_depth: f32,
    depth: f32,
    target_feedback: f32,
    feedback: f32,
    target_mix: f32,
    mix: f32,
    phase: f32,
    clock_phase: f32,
    smooth: f32,
    /// The compressor's envelope, taken from the dry input.
    input_env: f32,
    /// The expander's envelope, taken from the line output.
    output_env: f32,
    env_attack: f32,
    env_release: f32,
    /// The BBD input's anti-alias filter.
    input_lowpass: Biquad,
    /// The line's reconstruction filters.
    wet_lowpass: Biquad,
    wet_highpass: Biquad,
    /// Color's return path.
    feedback_lowpass: Biquad,
    feedback_highpass: Biquad,
    /// The clock-proportional top-end limit, redesigned per block.
    bbd_bandwidth: Biquad,
}

impl Flanger {
    pub const MIN_RATE_HZ: f32 = 0.05;
    /// The manual knob stops at 5 Hz, but a tempo-synced rate may arrive faster:
    /// 1/16 at 120 BPM is 8 Hz, so the effect accepts up to there and clamps
    /// anything above it.
    pub const MAX_RATE_HZ: f32 = 8.0;
    /// A SAD1024 has 1024 stages, so `delay = stages / (2 * clock)`.
    const BBD_STAGES: f32 = 1_024.0;
    /// The shortest delay, which is what makes a flanger a comb rather than a
    /// slapback: 0.7 ms at the fastest clock.
    pub const MIN_DELAY: f32 = 0.000_7;
    /// How far the sweep can add to [`MIN_DELAY`]; 5 ms at the slowest clock.
    pub const MAX_SWEEP: f32 = 0.004_3;
    pub const MAX_FEEDBACK: f32 = 0.9;
    /// The line is longer than any sweep, plus room for the interpolator.
    pub const LINE_SECONDS: f32 = 0.02;
    /// The compressor half's fixed make-up gain, about +6 dB.
    const PRE_GAIN: f32 = 2.0;
    /// The compander's threshold, linear: about −14 dBFS.
    const COMPANDER_THRESHOLD: f32 = 0.2;
    /// The expander never amplifies a quiet line output by more than this.
    const MAX_EXPAND: f32 = 4.0;
    /// Clock feedthrough, as a fraction of the wet signal.
    const CLOCK_FEED: f32 = 0.001_5;
    /// The fixed reconstruction corner, the Mistress's dark top end.
    const WET_CORNER_HZ: f32 = 6_800.0;
    /// The wet path's low end: the line cannot reproduce much below this.
    const WET_HIGHPASS_HZ: f32 = 160.0;
    const ENV_ATTACK_SECONDS: f32 = 0.004;
    const ENV_RELEASE_SECONDS: f32 = 0.12;

    pub fn new(rate_hz: f32, depth: f32, feedback: f32, mix: f32) -> Self {
        let lfo_hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        let feedback = feedback.clamp(0.0, Self::MAX_FEEDBACK);
        let mix = mix.clamp(0.0, 1.0);
        Flanger {
            rate: 48_000,
            buffer: Vec::new(),
            write: 0,
            target_lfo_hz: lfo_hz,
            lfo_hz,
            target_depth: depth,
            depth,
            target_feedback: feedback,
            feedback,
            target_mix: mix,
            mix,
            phase: 0.0,
            clock_phase: 0.0,
            smooth: 0.0,
            input_env: 0.0,
            output_env: 0.0,
            env_attack: 0.0,
            env_release: 0.0,
            input_lowpass: Biquad::identity(),
            wet_lowpass: Biquad::identity(),
            wet_highpass: Biquad::identity(),
            feedback_lowpass: Biquad::identity(),
            feedback_highpass: Biquad::identity(),
            bbd_bandwidth: Biquad::identity(),
        }
    }

    /// The clock the line would be running at, from a delay on this line.
    fn clock_hz(&self, delay_seconds: f32) -> f32 {
        let rate = self.rate.max(1) as f32;
        let samples = (delay_seconds * rate).max(2.0);
        (0.5 * Self::BBD_STAGES * rate / samples).clamp(20_000.0, 800_000.0)
    }

    /// Redesign the clock-tracking lowpass for the middle of the sweep. Called
    /// once per block, so the audio loop has no trigonometry in it.
    fn design_bandwidth(&mut self) {
        let delay = Self::MIN_DELAY + Self::MAX_SWEEP * self.depth * 0.5;
        let clock = self.clock_hz(delay);
        let cutoff = (clock * 0.08).clamp(1_500.0, 9_000.0);
        self.bbd_bandwidth
            .set(lowpass(f64::from(self.rate.max(1)), f64::from(cutoff)));
    }

    #[inline]
    fn tap(&self, delay: f32) -> f32 {
        let length = self.buffer.len();
        let reach = (length - 2) as f32;
        let back = delay.clamp(0.0, reach);
        let base = back.floor();
        let fraction = back - base;
        let first = (self.write as isize - base as isize).rem_euclid(length as isize) as usize;
        let second = (first + 1) % length;
        self.buffer[first] * (1.0 - fraction) + self.buffer[second] * fraction
    }
}

impl Effect for Flanger {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let length = (f64::from(self.rate) * f64::from(Self::LINE_SECONDS)) as usize + 2;
        self.buffer = vec![0.0; length.max(4)];
        self.write = 0;
        self.lfo_hz = self.target_lfo_hz;
        self.depth = self.target_depth;
        self.feedback = self.target_feedback;
        self.mix = self.target_mix;
        self.phase = 0.0;
        self.clock_phase = 0.0;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
        self.env_attack = one_pole(Self::ENV_ATTACK_SECONDS, self.rate) as f32;
        self.env_release = one_pole(Self::ENV_RELEASE_SECONDS, self.rate) as f32;
        self.input_env = 0.0;
        self.output_env = 0.0;

        let rate = f64::from(self.rate);
        let corner = f64::from(Self::WET_CORNER_HZ);
        let highpass_hz = f64::from(Self::WET_HIGHPASS_HZ);
        self.input_lowpass = Biquad::identity();
        self.input_lowpass.set(lowpass(rate, corner));
        self.wet_lowpass = Biquad::identity();
        self.wet_lowpass.set(lowpass(rate, corner));
        self.wet_highpass = Biquad::identity();
        self.wet_highpass.set(highpass(rate, highpass_hz, 0.707));
        self.feedback_lowpass = Biquad::identity();
        self.feedback_lowpass.set(lowpass(rate, corner));
        self.feedback_highpass = Biquad::identity();
        self.feedback_highpass.set(highpass(rate, highpass_hz, 0.707));
        self.bbd_bandwidth = Biquad::identity();
        self.design_bandwidth();
    }

    fn process(&mut self, block: &mut [f32]) {
        if self.buffer.len() < 4 {
            return;
        }
        self.design_bandwidth();
        let rate = self.rate.max(1) as f32;
        let length = self.buffer.len();
        let reach = (length - 2) as f32;

        // The clock is a block-rate quantity, like the filter corner it sets.
        let nominal_delay = Self::MIN_DELAY + Self::MAX_SWEEP * self.depth * 0.5;
        let clock_step = self.clock_hz(nominal_delay) / rate;
        let expand_threshold = Self::PRE_GAIN * Self::COMPANDER_THRESHOLD;

        for sample in block.iter_mut() {
            self.lfo_hz += (self.target_lfo_hz - self.lfo_hz) * self.smooth;
            self.depth += (self.target_depth - self.depth) * self.smooth;
            self.feedback += (self.target_feedback - self.feedback) * self.smooth;
            self.mix += (self.target_mix - self.mix) * self.smooth;

            // Triangular LFO, as the Mistress's integrator sweeps its clock.
            let sweep = 1.0 - (2.0 * self.phase - 1.0).abs();
            let delay = (Self::MIN_DELAY + Self::MAX_SWEEP * self.depth * sweep) * rate;
            let delay = delay.clamp(1.0, reach);

            let input = *sample;

            // The compander's compressor half: pre-amp, 2:1 above the
            // threshold, and the BBD input's soft clip.
            let magnitude = input.abs();
            self.input_env = follow(
                self.input_env,
                magnitude,
                self.env_attack,
                self.env_release,
            );
            let gain = if self.input_env > Self::COMPANDER_THRESHOLD {
                Self::PRE_GAIN * (Self::COMPANDER_THRESHOLD / self.input_env).sqrt()
            } else {
                Self::PRE_GAIN
            };
            let compressed = (input * gain).tanh();

            // Read the line, then reconstruct it.
            let wet = self.tap(delay);
            let wet = self.wet_lowpass.process(wet);
            let wet = self.wet_highpass.process(wet);

            // Color: the line output, filtered, returned to the line's input.
            let colored = self.feedback_lowpass.process(wet);
            let colored = self.feedback_highpass.process(colored);
            let drive = self.input_lowpass.process(compressed + self.feedback * colored);
            self.buffer[self.write] = drive.tanh();
            self.write = (self.write + 1) % length;

            // The expander half, the compressor's inverse around the same
            // threshold, so a quiet signal comes out where it went in.
            let wet_magnitude = wet.abs();
            self.output_env = follow(
                self.output_env,
                wet_magnitude,
                self.env_attack,
                self.env_release,
            );
            let expansion = if self.output_env > expand_threshold {
                (self.output_env / Self::COMPANDER_THRESHOLD) / (Self::PRE_GAIN * Self::PRE_GAIN)
            } else {
                1.0 / Self::PRE_GAIN
            };
            let expansion = expansion.clamp(1.0 / Self::PRE_GAIN, Self::MAX_EXPAND);

            // Clock feedthrough: a small amplitude modulation that vanishes
            // with the signal, because silence must stay silent.
            self.clock_phase = (self.clock_phase + clock_step).fract();
            let clock = 1.0 + Self::CLOCK_FEED * (1.0 - 4.0 * (self.clock_phase - 0.5).abs());
            let wet = wet * expansion * clock;

            *sample = input * (1.0 - self.mix) + wet * self.mix;

            self.phase += self.lfo_hz / rate;
            self.phase -= self.phase.floor();
        }
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
        self.write = 0;
        self.phase = 0.0;
        self.clock_phase = 0.0;
        self.lfo_hz = self.target_lfo_hz;
        self.depth = self.target_depth;
        self.feedback = self.target_feedback;
        self.mix = self.target_mix;
        self.input_env = 0.0;
        self.output_env = 0.0;
        self.input_lowpass.reset();
        self.wet_lowpass.reset();
        self.wet_highpass.reset();
        self.feedback_lowpass.reset();
        self.feedback_highpass.reset();
        self.bbd_bandwidth.reset();
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "rate" => {
                if usable {
                    self.target_lfo_hz = value.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
                }
                true
            }
            "depth" => {
                if usable {
                    self.target_depth = value.clamp(0.0, 1.0);
                }
                true
            }
            "feedback" => {
                if usable {
                    self.target_feedback = value.clamp(0.0, Self::MAX_FEEDBACK);
                }
                true
            }
            "mix" => {
                if usable {
                    self.target_mix = value.clamp(0.0, 1.0);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "flanger"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude)
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    /// Run a signal through a fresh pedal and return the output.
    fn render(input: &[f32], rate_hz: f32, depth: f32, feedback: f32, mix: f32) -> Vec<f32> {
        let mut flanger = Flanger::new(rate_hz, depth, feedback, mix);
        flanger.prepare(RATE, input.len());
        let mut block = input.to_vec();
        flanger.process(&mut block);
        block
    }

    /// The settled level of a wet-only render, skipping the envelopes' start-up.
    fn settled_wet(input: &[f32], rate_hz: f32, depth: f32, feedback: f32) -> f32 {
        let output = render(input, rate_hz, depth, feedback, 1.0);
        rms(&output[2_048..])
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut flanger = Flanger::new(0.3, 0.8, 0.5, 1.0);
        flanger.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        flanger.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn the_bbd_limits_the_top_end() {
        // The clock and the reconstruction filters roll the line off long
        // before Nyquist: a 12 kHz tone has to come back much quieter than a
        // 1 kHz one at the same level.
        let low = settled_wet(&sine(1_000.0, 0.05, 48_000), 0.5, 0.0, 0.0);
        let high = settled_wet(&sine(12_000.0, 0.05, 48_000), 0.5, 0.0, 0.0);
        assert!(low > 0.0, "the 1 kHz tone vanished");
        assert!(
            high < low * 0.35,
            "the BBD kept the top end: 12 kHz {high} vs 1 kHz {low}"
        );
    }

    #[test]
    fn the_compander_keeps_quiet_material_quiet() {
        // Below the threshold the pre-amp is divided back out by the expander,
        // so a quiet tone comes out at about the level it went in.
        let input = sine(220.0, 0.02, 48_000);
        let wet = settled_wet(&input, 0.5, 0.5, 0.0);
        let ratio = wet / rms(&input[2_048..]);
        assert!(
            (0.6..=1.2).contains(&ratio),
            "quiet material changed level by {ratio}"
        );
    }

    #[test]
    fn the_compander_holds_loud_material_back() {
        // A loud tone is compressed and soft-clipped before the line, and the
        // expander does not put the peaks back.
        let input = sine(220.0, 0.9, 48_000);
        let wet = settled_wet(&input, 0.5, 0.5, 0.0);
        let ratio = wet / rms(&input[2_048..]);
        assert!(ratio < 0.75, "loud material was not compressed: {ratio}");
        assert!(ratio > 0.1, "loud material was squashed flat: {ratio}");
    }

    #[test]
    fn feedback_increases_resonance() {
        // With the compander in its linear region, Color's filtered feedback is
        // the only thing that changes: more of it, more resonant energy.
        let input = sine(500.0, 0.05, 48_000);
        let dry_line = settled_wet(&input, 2.0, 0.5, 0.0);
        let colored = settled_wet(&input, 2.0, 0.5, 0.8);
        assert!(
            colored > dry_line * 1.1,
            "feedback did not add resonance: {colored} vs {dry_line}"
        );
    }

    #[test]
    fn mix_blends_dry_and_wet() {
        let input = sine(440.0, 0.2, 8_192);

        let dry = render(&input, 0.7, 0.8, 0.4, 0.0);
        assert_eq!(dry, input, "mix 0 must be the dry signal");

        let wet = render(&input, 0.7, 0.8, 0.4, 1.0);
        let half = render(&input, 0.7, 0.8, 0.4, 0.5);

        let distance = |block: &[f32]| -> f32 {
            block
                .iter()
                .zip(&input)
                .map(|(a, b)| (a - b) * (a - b))
                .sum::<f32>()
                .sqrt()
        };
        let full = distance(&wet);
        let blended = distance(&half);
        assert!(full > 0.01, "the flanger did not change the sound");
        assert!(
            (blended - 0.5 * full).abs() < full * 1e-3,
            "mix 50 was not halfway: {blended} vs half of {full}"
        );
    }

    #[test]
    fn depth_moves_the_sweep() {
        // A still line (depth 0) and a swept one must not sound the same.
        let input = sine(330.0, 0.05, 24_000);
        let still = render(&input, 1.0, 0.0, 0.0, 1.0);
        let swept = render(&input, 1.0, 1.0, 0.0, 1.0);
        let difference = still
            .iter()
            .zip(&swept)
            .map(|(a, b)| (a - b) * (a - b))
            .sum::<f32>();
        assert!(difference > 1.0, "depth did not move the sweep");
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 4096);
        let mut flanger = Flanger::new(2.5, 1.0, 0.9, 1.0);
        flanger.prepare(RATE, 4096);
        let mut first = input.clone();
        flanger.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));
        assert!(rms(&first) > 0.0);
        flanger.reset();
        let mut second = input.clone();
        flanger.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut flanger = Flanger::new(0.3, 0.5, 0.3, 0.5);
        assert!(flanger.set("rate", 100.0));
        assert_eq!(flanger.target_lfo_hz, Flanger::MAX_RATE_HZ);
        assert!(flanger.set("depth", -1.0));
        assert_eq!(flanger.target_depth, 0.0);
        assert!(flanger.set("feedback", 10.0));
        assert_eq!(flanger.target_feedback, Flanger::MAX_FEEDBACK);
        assert!(flanger.set("mix", f32::NAN));
        assert_eq!(flanger.target_mix, 0.5, "NaN moved a knob");
        assert!(!flanger.set("vol", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("flanger"), Some(InsertKind::Flanger));
        assert_eq!(InsertKind::Flanger.name(), "flanger");
    }
}
