//! The measurement half of the duplex round-trip probe, with no Oboe in it.
//!
//! `docs/studio-mobile-audio.md` §6 asks for the input-to-output round trip on
//! the phone. The probe plays one short chirp, captures what comes back, and
//! times the distance between the two streams with each stream's own
//! `getTimestamp(CLOCK_MONOTONIC)` reading:
//!
//! * the output stamp is taken at a known **output frame** (the frame the chirp
//!   starts on), so its presentation time is the stamp's time extrapolated to
//!   that frame;
//! * the input stamp is taken at a known **input frame** (where the correlation
//!   puts the chirp's onset), extrapolated the same way.
//!
//! Two frame counters from two streams are not comparable; two CLOCK_MONOTONIC
//! readings are. [`measure`] does only that subtraction. [`find_click`] is the
//! part that can be tested on a laptop: a normalized cross-correlation of the
//! same chirp against a captured buffer, with a threshold so noise is not a
//! detection.
//!
//! No dependency, no allocation in the scan beyond the template, and no Oboe —
//! the always-compiled suite runs every test in this file.

/// `CLOCK_MONOTONIC` on Linux/Android (`bits/time.h`). Oboe's `getTimestamp`
/// takes a `clockid_t`; this is the one both Java and AAudio document for
/// elapsed time.
pub const CLOCK_MONOTONIC: i32 = 1;

/// The chirp is 6 ms; at 48 kHz that is 288 frames, short enough to be a click
/// and long enough to survive a speaker and a microphone.
pub const CLICK_MS: f32 = 6.0;

/// The chirp's own amplitude. It is deliberately below full scale: a phone
/// speaker driven at 1.0 clips and the clipped click correlates worse.
pub const CLICK_AMPLITUDE: f32 = 0.8;

/// The correlation a detection must reach. A cable loop is near 1.0; a speaker
/// and microphone through a room is lower. 0.35 is the floor that a synthetic
/// noise test below shows is not reached by chance.
pub const MIN_SCORE: f32 = 0.35;

/// One chirp: a Hann-windowed linear sweep from 1 kHz to 5 kHz.
pub fn click(rate: u32) -> Vec<f32> {
    let rate = rate.max(8) as f32;
    let frames = ((rate * CLICK_MS / 1000.0).round() as usize).max(8);
    let seconds = frames as f32 / rate;
    let mut out = Vec::with_capacity(frames);
    for index in 0..frames {
        let time = index as f32 / rate;
        // Integral of a linear sweep f(t) = f0 + (f1-f0)t/T.
        let phase = std::f32::consts::TAU
            * (1_000.0 * time + (5_000.0 - 1_000.0) * time * time / (2.0 * seconds));
        let window = 0.5 - 0.5 * (std::f32::consts::TAU * index as f32 / (frames - 1) as f32).cos();
        out.push(CLICK_AMPLITUDE * window * phase.sin());
    }
    out
}

/// Where the chirp was found, and how well it matched.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClickHit {
    /// The first sample of the chirp in the buffer handed to [`find_click`].
    pub offset: usize,
    /// Normalized correlation, 0..=1. A perfect copy is 1.0.
    pub score: f32,
}

impl ClickHit {
    /// The chirp's onset in the stream's own frame counter, when `captured[0]`
    /// is stream frame `base`. Without a ring drop that base is 0.
    pub fn frame_in_stream(&self, base: u64) -> u64 {
        base + self.offset as u64
    }
}

/// Find the chirp in `samples`, scanning from `from`. The correlation removes
/// the local mean and normalizes both energies, so a loud passage elsewhere in
/// the buffer cannot win by amplitude alone.
///
/// `None` when the buffer is shorter than the chirp, or when nothing reaches
/// `MIN_SCORE`. The best score is returned by [`best_click`] even below the
/// threshold, which is what a failed probe reports.
pub fn find_click(rate: u32, samples: &[f32], from: usize) -> Option<ClickHit> {
    best_click(rate, samples, from).filter(|hit| hit.score >= MIN_SCORE)
}

/// Like [`find_click`], but always answers the best candidate. A probe that
/// heard nothing reports this score so the person can see how far from a
/// detection it was.
pub fn best_click(rate: u32, samples: &[f32], from: usize) -> Option<ClickHit> {
    let template = click(rate);
    find_with(&template, samples, from)
}

/// The correlation itself, with the template supplied so the test can use a
/// shorter or longer one without changing the rate.
pub fn find_with(template: &[f32], samples: &[f32], from: usize) -> Option<ClickHit> {
    let width = template.len();
    if width == 0 || samples.len() < width {
        return None;
    }
    let last = samples.len() - width;
    if from > last {
        return None;
    }
    let template_mean = mean(template);
    let template_centered: Vec<f32> = template.iter().map(|value| value - template_mean).collect();
    let template_energy: f64 = template_centered
        .iter()
        .map(|value| f64::from(*value) * f64::from(*value))
        .sum();
    if template_energy <= f64::EPSILON {
        return None;
    }

    let mut best = None;
    let mut window_sum: f64 = samples[from..from + width]
        .iter()
        .map(|value| f64::from(*value))
        .sum();
    for start in from..=last {
        if start > from {
            window_sum += f64::from(samples[start + width - 1]) - f64::from(samples[start - 1]);
        }
        let window_mean = window_sum / width as f64;
        let mut dot = 0.0f64;
        let mut energy = 0.0f64;
        for (index, template) in template_centered.iter().enumerate() {
            let sample = f64::from(samples[start + index]) - window_mean;
            dot += sample * f64::from(*template);
            energy += sample * sample;
        }
        let score = if energy > 1e-12 {
            (dot / (energy.sqrt() * template_energy.sqrt())).clamp(0.0, 1.0) as f32
        } else {
            0.0
        };
        if best.map_or(true, |hit: ClickHit| score > hit.score) {
            best = Some(ClickHit {
                offset: start,
                score,
            });
        }
    }
    best
}

fn mean(values: &[f32]) -> f32 {
    (values.iter().map(|value| f64::from(*value)).sum::<f64>() / values.len() as f64) as f32
}

/// One stream's timestamp reading: `time_ns` was `frame`'s timestamp, per
/// `AudioStream::getTimestamp(CLOCK_MONOTONIC)`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StreamStamp {
    pub frame: i64,
    pub time_ns: i64,
    pub rate: u32,
}

impl StreamStamp {
    /// The CLOCK_MONOTONIC time of another frame in the same stream, assuming
    /// the stream runs at its granted rate. Timestamps are given for one
    /// position; a click a few hundred frames away is far inside the clock's
    /// accuracy over that span.
    pub fn time_at(&self, frame: i64) -> f64 {
        let rate = self.rate.max(1) as f64;
        self.time_ns as f64 + (frame - self.frame) as f64 * 1_000_000_000.0 / rate
    }
}

/// A measured round trip.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RoundTrip {
    pub round_trip_ms: f64,
    pub round_trip_frames: f64,
}

/// The subtraction the probe needs: the input time of the heard chirp minus the
/// output time of the played chirp.
///
/// A negative or absurd result is an error sentence, not a number: two streams
/// whose clocks disagree, or a chirp matched to the wrong thing, must not be
/// reported as a latency.
pub fn measure(
    output: StreamStamp,
    click_frame: i64,
    input: StreamStamp,
    heard_frame: i64,
) -> Result<RoundTrip, String> {
    if output.rate == 0 || input.rate == 0 {
        return Err("a round-trip measurement needs a non-zero rate".to_string());
    }
    let heard_ns = input.time_at(heard_frame);
    let click_ns = output.time_at(click_frame);
    let delta_ms = (heard_ns - click_ns) / 1_000_000.0;
    if !delta_ms.is_finite() {
        return Err("the stream timestamps were not finite".to_string());
    }
    if delta_ms < 0.0 {
        return Err(format!(
            "the input stamp is {:.3} ms before the output stamp; the two streams do not share a clock",
            -delta_ms
        ));
    }
    if delta_ms > 5_000.0 {
        return Err(format!(
            "the measured round trip is {delta_ms:.1} ms, which is not a click in the same take"
        ));
    }
    let frames = delta_ms * f64::from(output.rate) / 1000.0;
    Ok(RoundTrip {
        round_trip_ms: delta_ms,
        round_trip_frames: frames,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 48_000;

    fn noise(frames: usize, amplitude: f32) -> Vec<f32> {
        let mut seed = 0x2545_f491u32;
        (0..frames)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                (seed as f32 / u32::MAX as f32 * 2.0 - 1.0) * amplitude
            })
            .collect()
    }

    fn noisy_click(offset: usize, frames: usize, amplitude: f32) -> Vec<f32> {
        let mut samples = noise(frames, amplitude);
        for (index, sample) in click(RATE).iter().enumerate() {
            if offset + index < frames {
                samples[offset + index] += sample;
            }
        }
        samples
    }

    #[test]
    fn the_chirp_is_short_and_bounded() {
        let template = click(RATE);
        assert_eq!(template.len(), 288, "6 ms at 48 kHz");
        assert!(template.iter().all(|value| value.abs() <= CLICK_AMPLITUDE));
        assert!(template.iter().any(|value| value.abs() > 0.5));
        // It starts and ends at zero (a Hann window), so a cut is not a click.
        assert!(template[0].abs() < 0.01);
        assert!(template[template.len() - 1].abs() < 0.01);
    }

    #[test]
    fn a_clean_click_is_found_at_its_exact_offset() {
        let samples = noisy_click(1_234, 6_000, 0.0);
        let hit = find_click(RATE, &samples, 0).expect("the click is in the buffer");
        assert_eq!(hit.offset, 1_234);
        assert!(hit.score > 0.999, "a clean copy scored {}", hit.score);
    }

    #[test]
    fn a_click_in_noise_is_found_within_two_samples() {
        let samples = noisy_click(5_000, 12_000, 0.25);
        let hit = find_click(RATE, &samples, 0).expect("the click is above the noise");
        assert!(
            hit.offset.abs_diff(5_000) <= 2,
            "found at {} (want 5000), score {}",
            hit.offset,
            hit.score
        );
        assert!(hit.score > MIN_SCORE);
    }

    #[test]
    fn noise_alone_does_not_cross_the_threshold() {
        let samples = noise(12_000, 0.5);
        let best = best_click(RATE, &samples, 0).expect("a buffer long enough");
        assert!(
            best.score < MIN_SCORE,
            "noise scored {} and would read as a click",
            best.score
        );
        assert!(find_click(RATE, &samples, 0).is_none());
    }

    #[test]
    fn the_scan_can_start_after_the_played_click() {
        // The first chirp is the output leak (a direct electrical path); the
        // acoustic one follows. Asking from after the leak finds the second.
        let mut samples = noisy_click(1_000, 9_000, 0.05);
        for (index, sample) in click(RATE).iter().enumerate() {
            samples[4_000 + index] += sample;
        }
        let first = find_click(RATE, &samples, 0).expect("first");
        assert_eq!(first.offset, 1_000);
        let second = find_click(RATE, &samples, 2_000).expect("second");
        assert_eq!(second.offset, 4_000);
    }

    #[test]
    fn silence_and_short_buffers_are_no_detection() {
        assert!(find_click(RATE, &vec![0.0; 4_096], 0).is_none());
        let short = vec![0.0f32; click(RATE).len() - 1];
        assert!(find_click(RATE, &short, 0).is_none());
        let samples = noisy_click(100, 1_000, 0.0);
        assert!(find_click(RATE, &samples, 900).is_none());
    }

    #[test]
    fn the_stamp_extrapolates_at_the_granted_rate() {
        let stamp = StreamStamp {
            frame: 1_000,
            time_ns: 1_000_000_000,
            rate: RATE,
        };
        // 480 frames later is 10 ms later.
        assert!((stamp.time_at(1_480) - 1_010_000_000.0).abs() < 0.001);
        // And 480 frames earlier is 10 ms earlier.
        assert!((stamp.time_at(520) - 990_000_000.0).abs() < 0.001);
    }

    #[test]
    fn the_round_trip_is_the_difference_of_two_stream_times() {
        let output = StreamStamp {
            frame: 12_000,
            time_ns: 2_000_000_000,
            rate: RATE,
        };
        let input = StreamStamp {
            frame: 500,
            time_ns: 2_062_000_000,
            rate: RATE,
        };
        // Click at output frame 12_000 (the stamp's own frame); heard at input
        // frame 980, which is 480 frames (10 ms) after the input stamp.
        let trip = measure(output, 12_000, input, 980).expect("a measurement");
        assert!(
            (trip.round_trip_ms - 72.0).abs() < 0.001,
            "round trip was {} ms",
            trip.round_trip_ms
        );
        assert!((trip.round_trip_frames - (72.0 * 48.0)).abs() < 0.01);
    }

    #[test]
    fn a_backwards_or_absurd_pair_is_a_sentence() {
        let output = StreamStamp {
            frame: 0,
            time_ns: 2_000_000_000,
            rate: RATE,
        };
        let input = StreamStamp {
            frame: 0,
            time_ns: 1_900_000_000,
            rate: RATE,
        };
        let error = measure(output, 0, input, 0).unwrap_err();
        assert!(error.contains("do not share a clock"), "{error}");

        let late = StreamStamp {
            frame: 0,
            time_ns: 20_000_000_000,
            rate: RATE,
        };
        let error = measure(output, 0, late, 0).unwrap_err();
        assert!(error.contains("not a click in the same take"), "{error}");

        let zero = StreamStamp {
            frame: 0,
            time_ns: 0,
            rate: 0,
        };
        assert!(measure(output, 0, zero, 0).is_err());
    }
}
