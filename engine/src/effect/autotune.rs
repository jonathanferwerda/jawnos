//! `autotune`: a monophonic pitch corrector.
//!
//! # What it does
//!
//! 1. It keeps the last few hundred milliseconds of input in a ring.
//! 2. Every 512 samples it estimates the period by normalised autocorrelation
//!    over a window of about 21 ms, in the 70 Hz..1 kHz range. It takes the
//!    **first** strong peak rather than the tallest, so a 440 Hz note is not
//!    read as 220 Hz.
//! 3. It turns the period into a MIDI note, finds the nearest note that belongs
//!    to `key` and `scale`, and asks for the ratio between that note and the
//!    played one.
//! 4. It shifts the pitch with two crossfaded delay-line taps. The taps' delays
//!    sweep in opposite halves of a [`SHIFT_SECONDS`] window and their linear
//!    gains sum to one, so the weighted delay is exactly half the window at
//!    every phase. That fixed half-window is the effect's latency, and the dry
//!    leg is delayed by the same amount to keep a partial `amount` from
//!    combing.
//!
//! `speed` (0..1) sets the retune time from 200 ms down to 5 ms; `amount`
//! (0..1) blends the delayed dry leg with the corrected one. `key` is 0..11
//! (C..B) and `scale` is 0 Major, 1 Minor, 2 Chromatic, 3 Pentatonic, both
//! whole numbers. Ties between two scale tones resolve upward.
//!
//! # What it does not do, and must not pretend to
//!
//! * **One voice only.** Two notes at once produce a period that belongs to
//!   neither; the detector will lock onto one of them or lose lock. There is no
//!   polyphonic source separation here and no plan to fake one.
//! * **No formant preservation.** The corrected signal keeps the shifted
//!   spectrum, so a large correction on a voice can sound like a chipmunk. The
//!   nearest scale tone is never more than a semitone away, which keeps that
//!   small, but it is not Antares.
//! * **Latency, not zero.** The correction path costs half the shifter window
//!   (15 ms at the default 30 ms) plus the detection window and hop; expect
//!   roughly 40 ms before a note is corrected. It is an insert, not a
//!   look-ahead mastering tool.
//! * **Crossfade artefacts.** A sweeping delay tap is a resampler; a vibrato
//!   heavier than the retune can make the crossfade audible on held notes.
//! * **It is never a silent bypass.** With `amount` above zero the corrected
//!   leg is always calculated, even when the input is already in tune (where
//!   the ratio is 1 and the leg is just the aligned delay), so the pedal does
//!   not switch itself off behind the user's back.

use super::{one_pole, one_pole_block, Effect};

/// Seconds of input the detector looks at, about 21 ms at 48 kHz and scaled
/// with the rate so the lowest note stays reachable.
const ANALYSIS_SECONDS: f32 = 0.0213;
/// Analyse every 512 samples at 48 kHz: fast enough for a new note, slow enough
/// that the autocorrelation is not the pedal's whole cost.
pub(crate) const HOP_SECONDS: f32 = 0.0107;
/// The crossfaded delay window. Its half is the effect's latency. The
/// harmonizer and the pitch shifter reuse this window.
pub(crate) const SHIFT_SECONDS: f32 = 0.03;
const MIN_HZ: f32 = 70.0;
const MAX_HZ: f32 = 1_000.0;
const MIN_RETUNE_SECONDS: f32 = 0.005;
const MAX_RETUNE_SECONDS: f32 = 0.200;
pub(crate) const RING_SECONDS: f32 = 0.25;
pub(crate) const MIN_RING: usize = 4_096;
const MIN_PREPARED_RING: usize = 64;

/// C major, the intervals 0..11 from the key.
const MAJOR: [bool; 12] = [
    true, false, true, false, true, true, false, true, false, true, false, true,
];
/// Natural minor: the flat third, sixth and seventh.
const MINOR: [bool; 12] = [
    true, false, true, true, false, true, false, true, true, false, true, false,
];
/// Minor pentatonic: the root, flat third, fourth, fifth and flat seventh.
const PENTATONIC: [bool; 12] = [
    true, false, false, true, false, true, false, true, false, false, true, false,
];

pub(crate) fn in_scale(key: u8, scale: u8, note: i32) -> bool {
    let interval = (note.rem_euclid(12) - i32::from(key)).rem_euclid(12) as usize;
    match scale {
        0 => MAJOR[interval],
        1 => MINOR[interval],
        2 => true,
        _ => PENTATONIC[interval],
    }
}

/// The nearest whole MIDI note that belongs to the key and scale. A tie goes to
/// the higher note, which keeps a scale with a gap (the minor third, for
/// instance) from pulling every ambiguous note down.
pub(crate) fn nearest_in_scale(midi: f32, key: u8, scale: u8) -> f32 {
    let centre = midi.round() as i32;
    let mut best = centre;
    let mut best_distance = f32::INFINITY;
    for delta in 0..=6i32 {
        for sign in [1i32, -1] {
            if delta == 0 && sign < 0 {
                continue;
            }
            let note = centre + sign * delta;
            if in_scale(key, scale, note) {
                let distance = (midi - note as f32).abs();
                if distance < best_distance - 1e-6 {
                    best_distance = distance;
                    best = note;
                }
            }
        }
    }
    best as f32
}

/// One linearly interpolated read `delay` samples behind `write` in a ring.
///
/// Shared with the harmonizer and the pitch shifter, whose grains read the same
/// kind of history. Unlike [`Autotune::tap`]'s legacy fractional read, this one
/// interpolates between `floor(delay)` and `floor(delay) + 1`, so a sweeping
/// delay is monotonic and a full-interval shift does not jump two samples at
/// every integer boundary.
#[inline]
pub(crate) fn grain_tap(ring: &[f32], write: usize, delay: f32) -> f32 {
    let length = ring.len();
    if length < 2 {
        return 0.0;
    }
    let reach = (length - 2) as f32;
    let back = delay.clamp(0.0, reach);
    let base = back.floor();
    let fraction = back - base;
    // `base` is the older sample, `base + 1` the newer one; interpolating
    // toward the newer sample keeps the read monotonic as the grain sweeps.
    let first = (write as isize - base as isize).rem_euclid(length as isize) as usize;
    let second = (first + length - 1) % length;
    ring[first] * (1.0 - fraction) + ring[second] * fraction
}

/// The two crossfaded grain taps at `phase` (turns): each tap's fraction of the
/// shift window and its linear gain. The gains sum to one, so the weighted
/// delay is constant and the pair never dips in level.
#[inline]
pub(crate) fn grain_taps(phase: f32) -> (f32, f32, f32, f32) {
    let other = (phase + 0.5).fract();
    let gain_a = 1.0 - (2.0 * phase - 1.0).abs();
    let gain_b = 1.0 - (2.0 * other - 1.0).abs();
    (phase, gain_a, other, gain_b)
}

/// The monophonic period detector the corrector, harmonizer and pitch shifter
/// share: a normalised autocorrelation over a short history ring, taking the
/// first strong peak so an octave does not read as the note below it.
///
/// It owns only its analysis and correlation scratch buffers. The caller keeps
/// the history ring and the write position, because a shifter reads that same
/// ring for its grains. `detect` runs on the caller's analysis hop, not every
/// sample.
#[derive(Debug)]
pub(crate) struct PitchDetector {
    rate: u32,
    analysis_len: usize,
    analysis: Vec<f32>,
    corr: Vec<f32>,
}

impl PitchDetector {
    pub(crate) fn new() -> Self {
        PitchDetector {
            rate: 48_000,
            analysis_len: 0,
            analysis: Vec::new(),
            corr: Vec::new(),
        }
    }

    /// Size the scratch buffers for `rate` and the caller's history ring.
    pub(crate) fn prepare(&mut self, rate: u32, ring_len: usize) {
        self.rate = rate.max(1);
        let analysis_len = ((self.rate as f32 * ANALYSIS_SECONDS) as usize)
            .max(256)
            .min(ring_len / 2);
        self.analysis_len = analysis_len;
        let max_lag = ((self.rate as f32 / MIN_HZ) as usize).min(analysis_len.saturating_sub(2));
        self.analysis = vec![0.0; analysis_len + 2];
        self.corr = vec![0.0; max_lag + 2];
    }

    pub(crate) fn analysis_len(&self) -> usize {
        self.analysis_len
    }

    pub(crate) fn reset(&mut self) {
        self.analysis.fill(0.0);
        self.corr.fill(0.0);
    }

    /// Estimate the period, in Hz, from the newest [`analysis_len`] samples of
    /// `ring`. Zero means "not a usable pitched note", never "pitch 0".
    pub(crate) fn detect(&mut self, ring: &[f32], write: usize) -> f32 {
        let n = self.analysis_len;
        if n < 64 || ring.len() < n + 2 {
            return 0.0;
        }
        let length = ring.len();
        // The caller advanced `write` after storing the sample, so the newest
        // sample at analysis time is the slot before it.
        let newest = (write + length - 1) % length;
        for (index, slot) in self.analysis[..n].iter_mut().enumerate() {
            *slot = ring[(newest + length - (n - 1 - index)) % length];
        }

        let window = &self.analysis[..n];
        let energy: f32 = window.iter().map(|value| value * value).sum();
        if energy / n as f32 <= 1e-8 {
            return 0.0;
        }
        let power = energy / n as f32;

        let min_lag = ((self.rate as f32 / MAX_HZ) as usize).max(2);
        let max_lag = ((self.rate as f32 / MIN_HZ) as usize).min(n - 2);
        if max_lag <= min_lag + 1 || self.corr.len() <= max_lag + 1 {
            return 0.0;
        }

        let corr = &mut self.corr;
        let mut best_lag = 0usize;
        let mut best = 0.0f32;
        for lag in min_lag..=max_lag {
            let count = n - lag;
            let mut sum = 0.0f32;
            for index in 0..count {
                sum += window[index] * window[index + lag];
            }
            let value = sum / (count as f32 * power);
            corr[lag] = value;
            if value > best {
                best = value;
                best_lag = lag;
            }
        }
        // Unvoiced, breath, or a percussive hit: hold the last ratio rather than
        // inventing a note from noise.
        if best_lag == 0 || best < 0.5 {
            return 0.0;
        }

        // The first peak close to the tallest one is the period; the taller
        // peaks at 2x, 3x, ... are octave errors.
        let threshold = best * 0.85;
        let mut chosen = best_lag;
        for lag in (min_lag + 1)..max_lag {
            if corr[lag] >= threshold && corr[lag] > corr[lag - 1] && corr[lag] >= corr[lag + 1] {
                chosen = lag;
                break;
            }
        }

        // Parabolic interpolation: the true period rarely lands on a sample.
        let (left, centre, right) = (corr[chosen - 1], corr[chosen], corr[chosen + 1]);
        let denominator = left - 2.0 * centre + right;
        let offset = if denominator.abs() > 1e-9 {
            0.5 * (left - right) / denominator
        } else {
            0.0
        };
        let lag = chosen as f32 + offset.clamp(-0.5, 0.5);
        let hz = self.rate as f32 / lag.max(1.0);
        if hz.is_finite() && (55.0..=1_200.0).contains(&hz) {
            hz
        } else {
            0.0
        }
    }
}

#[derive(Debug)]
pub struct Autotune {
    rate: u32,
    target_speed: f32,
    speed: f32,
    target_amount: f32,
    amount: f32,
    key: u8,
    scale: u8,
    ring: Vec<f32>,
    write: usize,
    shift_window: usize,
    hop: usize,
    detector: PitchDetector,
    since_analysis: usize,
    ratio: f32,
    current_ratio: f32,
    phase: f32,
    smooth: f32,
    prepared: bool,
}

impl Autotune {
    pub const SCALES: [&'static str; 4] = ["Major", "Minor", "Chromatic", "Pentatonic"];
    pub const MAX_KEY: u8 = 11;

    pub fn new(speed: f32, amount: f32, key: u8, scale: u8) -> Self {
        Autotune {
            rate: 48_000,
            target_speed: speed.clamp(0.0, 1.0),
            speed: speed.clamp(0.0, 1.0),
            target_amount: amount.clamp(0.0, 1.0),
            amount: amount.clamp(0.0, 1.0),
            key: key.min(Self::MAX_KEY),
            scale: scale.min(Self::SCALES.len() as u8 - 1),
            ring: Vec::new(),
            write: 0,
            shift_window: 0,
            hop: 0,
            detector: PitchDetector::new(),
            since_analysis: 0,
            ratio: 1.0,
            current_ratio: 1.0,
            phase: 0.0,
            smooth: 0.0,
            prepared: false,
        }
    }

    /// One interpolated read `delay` samples behind the write pointer.
    #[inline]
    fn tap(&self, delay: f32) -> f32 {
        let length = self.ring.len();
        let reach = (length - 2) as f32;
        let back = delay.clamp(0.0, reach);
        let base = back.floor();
        let fraction = back - base;
        let first = (self.write as isize - base as isize).rem_euclid(length as isize) as usize;
        let second = (first + 1) % length;
        self.ring[first] * (1.0 - fraction) + self.ring[second] * fraction
    }

    /// Estimate the input period, in Hz, from the last analysis window. Zero
    /// means "not a usable pitched note", never "pitch 0".
    fn detect_hz(&mut self) -> f32 {
        self.detector.detect(&self.ring, self.write)
    }

    fn apply_detection(&mut self, hz: f32) {
        if hz <= 0.0 {
            return;
        }
        let midi = 69.0 + 12.0 * (hz / 440.0).log2();
        let corrected = nearest_in_scale(midi, self.key, self.scale);
        let target_hz = 440.0 * 2f32.powf((corrected - 69.0) / 12.0);
        if target_hz.is_finite() && target_hz > 0.0 {
            // The nearest scale tone is at most a semitone away, so this clamp
            // only catches a wild detector jump, never a normal correction.
            self.ratio = (target_hz / hz).clamp(0.5, 2.0);
        }
    }
}

impl Effect for Autotune {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let ring_len = ((self.rate as f32 * RING_SECONDS) as usize).max(MIN_RING);
        self.shift_window = ((self.rate as f32 * SHIFT_SECONDS) as usize).clamp(64, ring_len / 4);
        self.hop = ((self.rate as f32 * HOP_SECONDS) as usize).max(64);
        self.ring = vec![0.0; ring_len];
        self.detector.prepare(self.rate, ring_len);
        self.write = 0;
        self.since_analysis = 0;
        self.speed = self.target_speed;
        self.amount = self.target_amount;
        self.ratio = 1.0;
        self.current_ratio = 1.0;
        self.phase = 0.0;
        self.smooth = one_pole(0.01, self.rate) as f32;
        self.prepared = true;
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared
            || self.ring.len() < MIN_PREPARED_RING
            || self.shift_window < 8
            || self.detector.analysis_len() < 64
        {
            return;
        }
        // The retune coefficient changes only when `speed` changes, so it is
        // computed once per block; the per-sample loop stays a multiply-add.
        let block_alpha = one_pole_block(0.02, self.rate, block.len()) as f32;
        self.speed += (self.target_speed - self.speed) * block_alpha;
        let retune_seconds = MIN_RETUNE_SECONDS
            + (1.0 - self.speed.clamp(0.0, 1.0)) * (MAX_RETUNE_SECONDS - MIN_RETUNE_SECONDS);
        let retune = one_pole(retune_seconds, self.rate) as f32;

        let window = self.shift_window as f32;
        let length = self.ring.len();
        for sample in block.iter_mut() {
            self.ring[self.write] = *sample;
            self.amount += (self.target_amount - self.amount) * self.smooth;
            self.current_ratio += (self.ratio - self.current_ratio) * retune;

            let (tap_a, gain_a, tap_b, gain_b) = grain_taps(self.phase);
            let wet = self.tap(tap_a * window) * gain_a + self.tap(tap_b * window) * gain_b;
            // The two taps' weighted delay is exactly half the window, so the
            // dry leg can be aligned to it and `amount` does not comb.
            let dry = self.tap(window * 0.5);
            *sample = dry + (wet - dry) * self.amount;

            // Delay grows by (1 - ratio) samples per sample, so the read
            // pointer travels at `ratio` and the pitch follows it.
            let increment = (1.0 - self.current_ratio) / window;
            self.phase += increment;
            if self.phase >= 1.0 {
                self.phase -= 1.0;
            } else if self.phase < 0.0 {
                self.phase += 1.0;
            }
            self.write = (self.write + 1) % length;

            self.since_analysis += 1;
            if self.since_analysis >= self.hop {
                self.since_analysis = 0;
                let hz = self.detect_hz();
                self.apply_detection(hz);
            }
        }
    }

    fn reset(&mut self) {
        self.ring.fill(0.0);
        self.detector.reset();
        self.write = 0;
        self.since_analysis = 0;
        self.speed = self.target_speed;
        self.amount = self.target_amount;
        self.ratio = 1.0;
        self.current_ratio = 1.0;
        self.phase = 0.0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "speed" => {
                if usable {
                    self.target_speed = value.clamp(0.0, 1.0);
                }
                true
            }
            "amount" => {
                if usable {
                    self.target_amount = value.clamp(0.0, 1.0);
                }
                true
            }
            "key" => {
                if usable {
                    self.key = (value.round() as i32).clamp(0, i32::from(Self::MAX_KEY)) as u8;
                }
                true
            }
            "scale" => {
                if usable {
                    self.scale = (value.round() as i32)
                        .clamp(0, Self::SCALES.len() as i32 - 1)
                        as u8;
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "autotune"
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

    /// A test-only period estimator, independent of the effect's own detector,
    /// so the pitch test can disagree with it if the effect is wrong. It uses
    /// the same first-strong-peak rule, because a pure sine correlates equally
    /// well at every multiple of its period.
    fn estimate_hz(block: &[f32], rate: u32) -> f32 {
        let n = block.len().min(8_192);
        let window = &block[block.len() - n..];
        let min_lag = (rate as f32 / 1_200.0) as usize;
        let max_lag = (rate as f32 / 80.0) as usize;
        let mut values = vec![0.0f32; max_lag + 2];
        let mut best = 0.0f32;
        for lag in min_lag..=max_lag {
            let count = n.saturating_sub(lag);
            if count < 64 {
                continue;
            }
            let mut sum = 0.0;
            let mut first = 0.0;
            let mut second = 0.0;
            for index in 0..count {
                sum += window[index] * window[index + lag];
                first += window[index] * window[index];
                second += window[index + lag] * window[index + lag];
            }
            let denominator = (first * second).sqrt();
            let value = if denominator > 1e-12 {
                sum / denominator
            } else {
                0.0
            };
            values[lag] = value;
            best = best.max(value);
        }
        let threshold = best * 0.9;
        let mut best_lag = min_lag;
        for lag in (min_lag + 1)..max_lag {
            if values[lag] >= threshold
                && values[lag] > values[lag - 1]
                && values[lag] >= values[lag + 1]
            {
                best_lag = lag;
                break;
            }
        }
        rate as f32 / best_lag as f32
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut autotune = Autotune::new(1.0, 1.0, 0, 0);
        autotune.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        autotune.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn a_sharp_note_is_pulled_towards_the_scale() {
        // A4 is 440 Hz; 452 Hz is 47 cents sharp. The key is C major, where A
        // belongs, so the nearest scale tone is A4.
        let mut autotune = Autotune::new(1.0, 1.0, 0, 0);
        autotune.prepare(RATE, 96_000);
        let mut block = sine(452.0, 0.3, 96_000);
        autotune.process(&mut block);

        let hz = estimate_hz(&block[48_000..], RATE);
        assert!(
            (hz - 440.0).abs() < 6.0,
            "the output settled at {hz} Hz, not the 440 Hz scale tone"
        );
    }

    #[test]
    fn an_in_tune_note_is_left_alone() {
        let input = sine(440.0, 0.3, 48_000);
        let mut autotune = Autotune::new(1.0, 1.0, 0, 0);
        autotune.prepare(RATE, 48_000);
        let mut block = input.clone();
        autotune.process(&mut block);
        let hz = estimate_hz(&block[24_000..], RATE);
        assert!(
            (hz - 440.0).abs() < 2.0,
            "an in-tune note was moved to {hz} Hz"
        );
    }

    #[test]
    fn amount_moves_a_sharp_note() {
        let input = sine(452.0, 0.3, 48_000);

        let mut dry = Autotune::new(1.0, 0.0, 0, 0);
        dry.prepare(RATE, 48_000);
        let mut dry_block = input.clone();
        dry.process(&mut dry_block);
        let dry_hz = estimate_hz(&dry_block[24_000..], RATE);
        assert!(
            (dry_hz - 452.0).abs() < 3.0,
            "amount 0 changed the note to {dry_hz} Hz"
        );

        let mut wet = Autotune::new(1.0, 1.0, 0, 0);
        wet.prepare(RATE, 48_000);
        let mut wet_block = input.clone();
        wet.process(&mut wet_block);
        let wet_hz = estimate_hz(&wet_block[24_000..], RATE);
        assert!(
            (wet_hz - 440.0).abs() < 3.0,
            "amount 1 left the note at {wet_hz} Hz"
        );

        let difference: f32 = wet_block[24_000..]
            .iter()
            .zip(&dry_block[24_000..])
            .map(|(a, b)| (a - b) * (a - b))
            .sum();
        assert!(difference > 1.0, "amount did not move the sound");
    }

    #[test]
    fn different_speeds_reach_the_same_note() {
        let mut slow = Autotune::new(0.0, 1.0, 0, 2);
        slow.prepare(RATE, 72_000);
        let mut slow_block = sine(452.0, 0.3, 72_000);
        slow.process(&mut slow_block);

        let slow_hz = estimate_hz(&slow_block[48_000..], RATE);
        assert!(
            (slow_hz - 440.0).abs() < 6.0,
            "the slow retune settled at {slow_hz} Hz"
        );
    }

    #[test]
    fn reset_matches_the_first_run() {
        let input = sine(452.0, 0.3, 4_096);
        let mut autotune = Autotune::new(1.0, 1.0, 0, 0);
        autotune.prepare(RATE, 4_096);
        let mut first = input.clone();
        autotune.process(&mut first);
        autotune.reset();
        let mut second = input.clone();
        autotune.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn full_scale_input_stays_finite() {
        let mut autotune = Autotune::new(1.0, 1.0, 0, 1);
        autotune.prepare(RATE, 8_192);
        let mut alternating = vec![0.0f32; 8_192];
        for (index, sample) in alternating.iter_mut().enumerate() {
            *sample = if index % 2 == 0 { 1.0 } else { -1.0 };
        }
        autotune.process(&mut alternating);
        assert!(alternating.iter().all(|sample| sample.is_finite()));
        assert!(rms(&alternating) > 0.0);
    }

    #[test]
    fn the_scale_table_chooses_the_nearest_member() {
        // C#4 sits between C (in C major) and D (in C major): the tie goes up.
        assert_eq!(nearest_in_scale(61.0, 0, 0), 62.0);
        // In D major the same note is already a member.
        assert_eq!(nearest_in_scale(61.0, 2, 0), 61.0);
        // Chromatic accepts every semitone.
        assert_eq!(nearest_in_scale(61.4, 0, 2), 61.0);
        // In C minor pentatonic, C#4 is not a member; C4 is the nearest.
        assert_eq!(nearest_in_scale(61.4, 0, 3), 60.0);
        // D#4 is not in C major; the nearest members are D and E, and 62.6 is
        // closer to D (62) than to E (64).
        assert_eq!(nearest_in_scale(62.6, 0, 0), 62.0);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut autotune = Autotune::new(0.5, 0.5, 0, 0);
        assert!(autotune.set("speed", 10.0));
        assert_eq!(autotune.target_speed, 1.0);
        assert!(autotune.set("amount", -10.0));
        assert_eq!(autotune.target_amount, 0.0);
        assert!(autotune.set("key", 99.0));
        assert_eq!(autotune.key, 11);
        assert!(autotune.set("scale", 99.0));
        assert_eq!(autotune.scale, 3);
        assert!(autotune.set("scale", f32::NAN));
        assert_eq!(autotune.scale, 3, "NaN moved the scale");
        assert!(!autotune.set("thresh", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("autotune"), Some(InsertKind::Autotune));
        assert_eq!(InsertKind::Autotune.name(), "autotune");
    }
}
