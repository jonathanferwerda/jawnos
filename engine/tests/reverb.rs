//! The convolver's contract: the web's impulse, no added latency, and the same
//! output however the host chops the stream.
//!
//! These run the real `Reverb` on a null device, so they exercise the actual
//! partition assembly rather than a model of it. The impulse is generated from a
//! fixed seed, which is what makes the delta test exact.

use jawn_audio::effect::Effect;
use jawn_audio::reverb::{
    Reverb, DECAY, DEFAULT_MODEL, MIX_DEFAULT, MODEL_NAMES, MODEL_SECONDS, NAME, PARTITION,
    VOLUME_DEFAULT,
};

const RATE: u32 = 48_000;

fn prepared() -> Reverb {
    let mut reverb = Reverb::new();
    reverb.prepare(RATE, 512);
    reverb
}

fn rms(samples: &[f32]) -> f32 {
    (samples.iter().map(|sample| sample * sample).sum::<f32>() / samples.len() as f32).sqrt()
}

/// A deterministic, band-wide signal: two sines and a slow pseudo-noise term.
/// No `rand`, no time, so the chunk comparison is reproducible.
fn signal(frames: usize) -> Vec<f32> {
    (0..frames)
        .map(|index| {
            let time = index as f32 / RATE as f32;
            (std::f32::consts::TAU * 220.0 * time).sin() * 0.4
                + (std::f32::consts::TAU * 1_310.0 * time).sin() * 0.2
                + ((index.wrapping_mul(1_237) % 1_000) as f32 / 1_000.0 - 0.5) * 0.1
        })
        .collect()
}

#[test]
fn it_is_the_web_reverbs_impulse_with_the_web_knobs() {
    let mut reverb = prepared();
    assert_eq!(reverb.name(), NAME);
    assert_eq!(NAME, "reverb");
    assert_eq!(reverb.model_name(), MODEL_NAMES[DEFAULT_MODEL]);

    let ir = reverb.impulse();
    assert_eq!(
        ir.len(),
        (RATE as f32 * MODEL_SECONDS[DEFAULT_MODEL]).round() as usize
    );
    assert!(ir.iter().all(|sample| sample.is_finite()));
    // The generated noise decays by (1 - t)^2.6 and is then normalized, so the
    // last second is thousands of times quieter than the first, never louder.
    assert!(rms(&ir[..4_800]) > rms(&ir[ir.len() - 4_800..]) * 10.0);

    // `setters['mix'](35)` with `volume` at 35: wet 0.315, dry 0.86.
    assert!((reverb.wet_gain() - MIX_DEFAULT * 0.9).abs() < 1e-6);
    assert!((reverb.dry_gain() - (1.0 - MIX_DEFAULT * 0.4)).abs() < 1e-6);

    reverb.set_mix(0.0);
    assert_eq!(reverb.wet_gain(), 0.0);
    assert!((reverb.dry_gain() - 1.0).abs() < 1e-6);

    // The page's volume knob writes the same wet node, and leaves the dry leg.
    reverb.set_mix(0.35);
    reverb.set_volume(1.0);
    assert!((reverb.wet_gain() - 0.9).abs() < 1e-6);
    assert!((reverb.dry_gain() - (1.0 - 0.35 * 0.4)).abs() < 1e-6);

    // A non-finite knob is refused, not stored.
    reverb.set_mix(f32::NAN);
    assert!((reverb.wet_gain() - 0.9).abs() < 1e-6);
    assert_eq!(VOLUME_DEFAULT, 0.35);
    assert_eq!(DECAY, 2.6);

    // A model switch is applied at the next block boundary and swaps the
    // whole tail, with no re-preparation by the caller.
    assert!(reverb.set("model", 4.0));
    let mut boundary = vec![0.0f32; PARTITION];
    reverb.process(&mut boundary);
    assert_eq!(reverb.model_name(), "Cave");
    assert_eq!(
        reverb.impulse().len(),
        (RATE as f32 * MODEL_SECONDS[4]).round() as usize
    );
}

#[test]
fn mix_zero_settles_into_the_dry_signal() {
    let mut reverb = prepared();
    reverb.set_mix(0.0);
    // Let the wet gain come down the way a real knob move would.
    let mut warm = vec![0.0f32; 8 * PARTITION];
    reverb.process(&mut warm);

    let mut block = vec![0.0f32; PARTITION];
    block[0] = 1.0;
    reverb.process(&mut block);
    assert!(
        (block[0] - 1.0).abs() < 1e-2,
        "the dry leg did not reach unity: {}",
        block[0]
    );
    assert!(
        block[1..].iter().all(|sample| sample.abs() < 1e-4),
        "a silent wet path still rang"
    );
}

#[test]
fn a_delta_is_the_impulse_with_no_delay() {
    let mut reverb = prepared();
    let ir: Vec<f32> = reverb.impulse().to_vec();
    let wet = reverb.wet_gain();
    let dry = reverb.dry_gain();

    // Long enough to cover the whole impulse, so the direct head and every FFT
    // partition have their turn.
    let mut buffer = vec![0.0f32; ir.len() + 4_800];
    buffer[0] = 1.0;
    reverb.process(&mut buffer);

    // Sample 0 is the delta through the dry leg plus the impulse's first tap
    // through the wet leg: there is no silent first block.
    assert!(
        (buffer[0] - (dry + wet * ir[0])).abs() < 1e-6,
        "sample 0 is {}, expected {}",
        buffer[0],
        dry + wet * ir[0]
    );

    // Every later sample is the impulse, in order, with no shift anywhere: the
    // first partition is direct, the rest are the partitioned convolution.
    for index in 1..ir.len() {
        let error = (buffer[index] - wet * ir[index]).abs();
        assert!(
            error < 1e-5,
            "sample {index} is {}, the impulse says {}",
            buffer[index],
            wet * ir[index]
        );
    }
    assert!(
        buffer[1..PARTITION]
            .iter()
            .any(|sample| sample.abs() > 1e-4),
        "the wet path contributed nothing"
    );

    // The tail decays rather than growing, and it is still alive at the very end.
    let head = rms(&buffer[1..4_800]);
    let middle = rms(&buffer[40_000..44_800]);
    let last = rms(&buffer[ir.len() - 4_800..ir.len()]);
    assert!(last > 0.0, "the tail is silent before the impulse ends");
    assert!(middle < head * 0.5, "the tail grew: {middle} against {head}");
    assert!(
        last < head * 0.01,
        "the tail did not decay: {last} against {head}"
    );
}

#[test]
fn silence_stays_exactly_silent() {
    let mut reverb = prepared();
    let mut block = vec![0.0f32; RATE as usize];
    reverb.process(&mut block);
    assert!(
        block.iter().all(|sample| *sample == 0.0),
        "an all-zero input produced a non-zero sample"
    );
}

#[test]
fn full_scale_for_ten_seconds_stays_finite_and_bounded() {
    let mut reverb = prepared();
    let mut block = vec![0.0f32; PARTITION];
    let mut peak = 0.0f32;
    // Alternating full scale is the worst case for a summing convolver: every
    // tap adds in phase at Nyquist.
    for index in 0..(RATE as usize * 10 / PARTITION) {
        for (offset, sample) in block.iter_mut().enumerate() {
            *sample = if (index * PARTITION + offset) % 2 == 0 {
                1.0
            } else {
                -1.0
            };
        }
        reverb.process(&mut block);
        for sample in &block {
            assert!(sample.is_finite(), "a full-scale run produced {sample}");
            peak = peak.max(sample.abs());
        }
    }
    assert!(peak > 0.0, "ten seconds of full scale produced silence");
    assert!(peak < 1_000.0, "the output ran away: peak {peak}");
}

#[test]
fn sixty_four_frame_calls_match_one_long_call() {
    let input = signal(RATE as usize);

    let mut whole = prepared();
    let mut once = input.clone();
    whole.process(&mut once);

    let mut chunked = prepared();
    let mut pieces = input.clone();
    for chunk in pieces.chunks_mut(64) {
        chunked.process(chunk);
    }

    let mut worst = 0.0f32;
    for (index, (a, b)) in once.iter().zip(&pieces).enumerate() {
        worst = worst.max((a - b).abs());
        assert!(
            (a - b).abs() <= 1e-4,
            "sample {index}: one call {a}, 64-frame calls {b}"
        );
    }
    // The partition schedule is a property of the sample count, not of the call
    // sizes, so this is exact and not merely close.
    assert_eq!(worst, 0.0, "chunking changed the output by {worst}");
    assert!(
        once.iter().any(|sample| sample.abs() > 1e-3),
        "the comparison had no signal to protect"
    );
}

#[test]
fn reset_returns_to_the_first_run() {
    let input = signal(RATE as usize);

    let mut reverb = prepared();
    let mut first = input.clone();
    reverb.process(&mut first);

    reverb.reset();
    let mut second = input.clone();
    reverb.process(&mut second);

    assert_eq!(
        first, second,
        "a reset reverb did not repeat its first run sample for sample"
    );
}

#[test]
fn nothing_is_audible_before_its_input_arrives() {
    // One call, so every internal block boundary is crossed.
    let mut reverb = prepared();
    let mut buffer = vec![0.0f32; 20_000];
    buffer[5_000] = 1.0;
    reverb.process(&mut buffer);
    assert!(
        buffer[..5_000].iter().all(|sample| *sample == 0.0),
        "the reverb anticipated its input inside one call"
    );

    // And across 97-frame calls, which do not line up with the partitions.
    let mut chunked = prepared();
    let mut pieces = vec![0.0f32; 20_000];
    pieces[5_000] = 1.0;
    for chunk in pieces.chunks_mut(97) {
        chunked.process(chunk);
    }
    assert!(
        pieces[..5_000].iter().all(|sample| *sample == 0.0),
        "the reverb anticipated its input across chunk boundaries"
    );

    // The impulse starts at the delta even mid-block, with no shifted copy.
    let mut mid = prepared();
    let ir: Vec<f32> = mid.impulse().to_vec();
    let wet = mid.wet_gain();
    let dry = mid.dry_gain();
    let mut offset = vec![0.0f32; 8_192];
    offset[5_000] = 1.0;
    mid.process(&mut offset);
    let first = dry + wet * ir[0];
    assert!(
        (offset[5_000] - first).abs() < 1e-6,
        "the delta itself is {}, expected {first}",
        offset[5_000]
    );
    for index in 1..64 {
        let expected = wet * ir[index];
        assert!(
            (offset[5_000 + index] - expected).abs() < 1e-6,
            "tap {index} after a mid-block delta is {}, expected {expected}",
            offset[5_000 + index]
        );
    }
}
