//! Tests for the render contract: silence, pitch, polyphony, determinism and
//! the patch clamps. Every test builds a fresh [`Synth`] so the shared LFO and
//! compressor state are known.

use crate::{midi_to_hz, Engine, Envelope, Filter, FilterKind, Lfo, Osc, Patch, Synth, Wave};

const RATE: f32 = 48_000.0;

/// A clean, single-oscillator sine patch with a wide-open filter.
fn sine_patch() -> Patch {
    Patch {
        engine: Engine::Subtractive,
        wave: Wave::Sine,
        noise: 0.0,
        voices: 16,
        transpose: 0.0,
        glide: 0.0,
        drive: 0.0,
        damping: 0.5,
        brightness: 0.5,
        osc: [
            Osc { octave: 0, detune: 0.0, level: 1.0 },
            Osc { octave: 0, detune: 0.0, level: 0.0 },
        ],
        osc_count: 1,
        filter: Filter {
            kind: FilterKind::Lowpass,
            cutoff: 18_000.0,
            q: 0.707,
            env: 0.0,
            keytrack: 0.0,
        },
        amp: Envelope { a: 0.001, d: 0.001, s: 1.0, r: 0.05 },
        fenv: Envelope { a: 0.001, d: 0.001, s: 0.0, r: 0.05 },
        lfo: Lfo { rate: 0.0, pitch: 0.0, cutoff: 0.0, amp: 0.0 },
    }
}

fn synth(patch: Patch) -> Synth {
    let mut synth = Synth::new(patch, RATE);
    synth.prepare(256);
    synth
}

fn render(synth: &mut Synth, frames: usize) -> (Vec<f32>, Vec<f32>) {
    let mut left = vec![0.0; frames];
    let mut right = vec![0.0; frames];
    synth.render(&mut left, &mut right);
    (left, right)
}

fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0f32, |m, &s| m.max(s.abs()))
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (samples.iter().map(|&s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
}

fn bits(samples: &[f32]) -> Vec<u32> {
    samples.iter().map(|s| s.to_bits()).collect()
}

/// Frequency from the linearly interpolated upward zero crossings.
fn measured_freq(samples: &[f32], rate: f32) -> f32 {
    let mut first = None;
    let mut last = None;
    let mut periods = 0usize;
    for i in 1..samples.len() {
        let (previous, current) = (samples[i - 1], samples[i]);
        if previous <= 0.0 && current > 0.0 && current - previous > 1e-9 {
            let crossing = (i - 1) as f32 + (-previous) / (current - previous);
            match first {
                None => first = Some(crossing),
                Some(_) => {
                    last = Some(crossing);
                    periods += 1;
                }
            }
        }
    }
    match (first, last) {
        (Some(start), Some(end)) if periods > 0 && end > start => {
            periods as f32 * rate / (end - start)
        }
        _ => 0.0,
    }
}

#[test]
fn silence_without_notes() {
    let mut synth = synth(sine_patch());
    let (left, right) = render(&mut synth, 9_600);
    assert!(left.iter().all(|&s| s == 0.0));
    assert!(right.iter().all(|&s| s == 0.0));
}

#[test]
fn note_on_sounds_and_note_off_decays_to_exact_zero() {
    let mut patch = sine_patch();
    patch.amp = Envelope { a: 0.002, d: 0.05, s: 0.6, r: 0.05 };
    let mut synth = synth(patch);
    synth.note_on(60, 0.8);
    let (left, _) = render(&mut synth, 9_600);
    assert!(peak(&left) > 0.01, "note_on made no sound");

    synth.note_off(60);
    let (left, _) = render(&mut synth, 2_400 + 4 * 256);
    let release = (0.05 * RATE) as usize;
    assert!(peak(&left[..release]) > 0.0, "release started silent");
    assert_eq!(peak(&left[release + 1..]), 0.0, "release did not reach zero");
    assert_eq!(synth.active_voices(), 0);
}

#[test]
fn pitch_is_accurate_at_low_middle_and_high_notes() {
    for (note, seconds) in [(36u8, 3.0f32), (69, 1.0), (91, 1.0)] {
        let mut synth = synth(sine_patch());
        synth.note_on(note, 0.8);
        let (left, _) = render(&mut synth, (RATE * seconds) as usize + 1);
        let frequency = measured_freq(&left, RATE);
        let wanted = midi_to_hz(note as f32);
        let error = (frequency - wanted).abs() / wanted;
        assert!(
            error < 0.005,
            "note {note}: measured {frequency:.3} Hz, wanted {wanted:.3} Hz"
        );
    }
}

#[test]
fn polyphony_sums_notes_and_caps_voices() {
    let mut patch = sine_patch();
    patch.amp = Envelope { a: 0.001, d: 0.001, s: 0.8, r: 0.05 };
    patch.osc[0].level = 0.3;

    let mut one = synth(patch);
    one.note_on(60, 0.8);
    let (a, _) = render(&mut one, 24_000);

    let mut other = synth(patch);
    other.note_on(67, 0.8);
    let (b, _) = render(&mut other, 24_000);

    let mut both = synth(patch);
    both.note_on(60, 0.8);
    both.note_on(67, 0.8);
    assert_eq!(both.active_voices(), 2);
    let (ab, _) = render(&mut both, 24_000);

    let expected = (rms(&a) * rms(&a) + rms(&b) * rms(&b)).sqrt();
    let error = (rms(&ab) - expected).abs() / expected;
    assert!(error < 0.08, "sum {:.5}, expected {:.5}", rms(&ab), expected);

    // Cap: the oldest note is stolen when the third arrives.
    patch.voices = 2;
    let mut capped = synth(patch);
    capped.note_on(60, 0.8);
    capped.note_on(64, 0.8);
    capped.note_on(67, 0.8);
    assert_eq!(capped.active_voices(), 2);
    assert!(!capped.note_active(60), "the stolen note is still active");
    assert!(capped.note_active(64));
    assert!(capped.note_active(67));
}

#[test]
fn detuned_oscillators_beat_and_are_deterministic() {
    let mut patch = sine_patch();
    patch.osc = [
        Osc { octave: 0, detune: -15.0, level: 0.5 },
        Osc { octave: 0, detune: 15.0, level: 0.5 },
    ];
    patch.osc_count = 2;

    let mut pair = synth(patch);
    pair.note_on(69, 0.8);
    let (left, _) = render(&mut pair, 72_000);

    // Peak per 20 ms window: a beat shows as a deep swing between windows.
    let window = (RATE * 0.02) as usize;
    let windows: Vec<f32> = left.chunks(window).map(peak).collect();
    let loudest = windows.iter().fold(0.0f32, |m, &v| m.max(v));
    let quietest = windows.iter().fold(f32::MAX, |m, &v| m.min(v));
    assert!(loudest > 0.01, "detuned pair made no sound");
    assert!(
        loudest > quietest * 2.0,
        "no beat: loudest {loudest:.4}, quietest {quietest:.4}"
    );

    let mut again = synth(patch.clone());
    again.note_on(69, 0.8);
    let (repeat, _) = render(&mut again, 72_000);
    assert_eq!(bits(&left), bits(&repeat));

    // The pair differs from one oscillator.
    let mut single_patch = patch;
    single_patch.osc_count = 1;
    let mut single = synth(single_patch);
    single.note_on(69, 0.8);
    let (one, _) = render(&mut single, 72_000);
    assert_ne!(bits(&left), bits(&one));
}

#[test]
fn drive_shapes_the_peak_and_lowers_crest() {
    let mut clean_patch = sine_patch();
    clean_patch.amp = Envelope { a: 0.001, d: 0.001, s: 1.0, r: 0.05 };
    let mut clean = synth(clean_patch);
    clean.note_on(60, 0.8);
    let (clean_out, _) = render(&mut clean, 24_000);

    let mut dirty_patch = clean_patch;
    dirty_patch.drive = 0.8;
    let mut dirty = synth(dirty_patch);
    dirty.note_on(60, 0.8);
    let (dirty_out, _) = render(&mut dirty, 24_000);

    let clean_crest = peak(&clean_out[4_800..]) / rms(&clean_out[4_800..]);
    let dirty_crest = peak(&dirty_out[4_800..]) / rms(&dirty_out[4_800..]);
    assert_ne!(bits(&clean_out), bits(&dirty_out));
    // A wave-shaper squares the wave, so crest factor falls. (The brief said
    // "increases"; physics says otherwise, and this test asserts the truth.)
    assert!(
        dirty_crest < clean_crest * 0.95,
        "clean {clean_crest:.3}, driven {dirty_crest:.3}"
    );
}

#[test]
fn hot_patch_stays_finite_and_below_full_scale() {
    let mut patch = Patch::default();
    patch.drive = 1.0;
    patch.noise = 0.5;
    patch.filter.q = 20.0;
    patch.amp = Envelope { a: 0.001, d: 0.5, s: 0.9, r: 0.1 };
    patch.lfo = Lfo { rate: 6.0, pitch: 0.02, cutoff: 800.0, amp: 0.5 };
    patch.voices = 8;
    let mut synth = synth(patch);
    for note in 48..56 {
        synth.note_on(note, 1.0);
    }
    assert_eq!(synth.active_voices(), 8);
    let (left, right) = render(&mut synth, 24_000);
    for &sample in left.iter().chain(right.iter()) {
        assert!(sample.is_finite(), "non-finite sample");
        assert!(sample.abs() < 1.0, "sample {sample} at full scale");
    }
    assert!(peak(&left) > 0.1, "hot patch was silent");
}

#[test]
fn every_waveform_sounds_and_is_deterministic() {
    for waveform in Wave::ALL {
        let mut patch = sine_patch();
        patch.wave = waveform;
        let mut first = synth(patch);
        first.note_on(60, 0.8);
        let (a, _) = render(&mut first, 12_000);
        assert!(peak(&a) > 1e-3, "{} made no sound", waveform.name());

        let mut second = synth(patch);
        second.note_on(60, 0.8);
        let (b, _) = render(&mut second, 12_000);
        assert_eq!(bits(&a), bits(&b), "{} is not deterministic", waveform.name());
    }
}

#[test]
fn pluck_rings_then_decays() {
    let mut patch = Patch::default();
    patch.engine = Engine::Pluck;
    patch.damping = 0.5;
    patch.brightness = 0.6;
    patch.amp = Envelope { a: 0.001, d: 1.6, s: 0.0, r: 0.35 };
    patch.lfo = Lfo { rate: 0.0, pitch: 0.0, cutoff: 0.0, amp: 0.0 };
    let mut synth = synth(patch);
    synth.note_on(45, 0.9);

    let (onset, _) = render(&mut synth, 4_800);
    assert!(peak(&onset) > 0.01, "pluck onset was silent");

    let (tail, _) = render(&mut synth, 240_000);
    let last = (RATE * 0.1) as usize;
    assert!(
        peak(&tail[tail.len() - last..]) < 1e-6,
        "pluck did not decay to silence"
    );
    for &sample in onset.iter().chain(tail.iter()) {
        assert!(sample.is_finite());
    }
}

#[test]
fn patch_values_are_clamped() {
    let mut patch = Patch::default();
    patch.noise = 9.0;
    patch.voices = 200;
    patch.transpose = -999.0;
    patch.glide = 9.0;
    patch.drive = 4.0;
    patch.damping = -1.0;
    patch.brightness = 2.0;
    patch.osc = [
        Osc { octave: 40, detune: 1_000.0, level: 9.0 },
        Osc { octave: -40, detune: -1_000.0, level: -3.0 },
    ];
    patch.osc_count = 9;
    patch.filter = Filter {
        kind: FilterKind::Bandpass,
        cutoff: -5.0,
        q: 1e9,
        env: 9.0,
        keytrack: 9.0,
    };
    patch.amp = Envelope { a: -1.0, d: 1e9, s: 9.0, r: -4.0 };
    patch.fenv = Envelope { a: 1e9, d: -1.0, s: -1.0, r: 1e9 };
    patch.lfo = Lfo { rate: 999.0, pitch: 9.0, cutoff: 99_999.0, amp: 9.0 };
    patch.clamp();

    assert_eq!(patch.noise, 1.0);
    assert_eq!(patch.voices, 64);
    assert_eq!(patch.transpose, -36.0);
    assert_eq!(patch.glide, 3.0);
    assert_eq!(patch.drive, 1.0);
    assert_eq!(patch.damping, 0.0);
    assert_eq!(patch.brightness, 1.0);
    assert_eq!(patch.osc[0].octave, 4);
    assert_eq!(patch.osc[0].detune, 100.0);
    assert_eq!(patch.osc[0].level, 1.0);
    assert_eq!(patch.osc[1].octave, -4);
    assert_eq!(patch.osc[1].level, 0.0);
    assert_eq!(patch.osc_count, 2);
    assert_eq!(patch.filter.cutoff, 40.0);
    assert_eq!(patch.filter.q, 30.0);
    assert_eq!(patch.filter.env, 1.0);
    assert_eq!(patch.filter.keytrack, 1.0);
    assert_eq!(patch.amp.a, 0.0);
    assert_eq!(patch.amp.d, 10.0);
    assert_eq!(patch.amp.s, 1.0);
    assert_eq!(patch.amp.r, 0.0);
    assert_eq!(patch.fenv.d, 0.0);
    assert_eq!(patch.lfo.rate, 20.0);
    assert_eq!(patch.lfo.pitch, 1.0);
    assert_eq!(patch.lfo.cutoff, 2400.0);
    assert_eq!(patch.lfo.amp, 1.0);

    // Velocity is clamped at note-on: 5.0 behaves exactly like 1.0.
    let mut loud = synth(sine_patch());
    loud.note_on(60, 5.0);
    let (a, _) = render(&mut loud, 4_800);
    let mut full = synth(sine_patch());
    full.note_on(60, 1.0);
    let (b, _) = render(&mut full, 4_800);
    assert_eq!(bits(&a), bits(&b));

    let mut negative = synth(sine_patch());
    negative.note_on(60, -2.0);
    let (c, _) = render(&mut negative, 4_800);
    assert!(c.iter().all(|s| s.is_finite()));
}

#[test]
fn set_patch_changes_the_sound_without_rebuilding() {
    let mut synth = synth(sine_patch());
    synth.note_on(60, 0.8);
    let (before, _) = render(&mut synth, 9_600);

    synth.all_notes_off();
    let _ = render(&mut synth, 4_800);

    let mut square = sine_patch();
    square.wave = Wave::Square;
    synth.set_patch(square);
    synth.note_on(60, 0.8);
    let (after, _) = render(&mut synth, 9_600);

    assert!(rms(&after) > 0.001);
    assert_ne!(bits(&before), bits(&after));
}

#[test]
fn identical_event_sequences_render_byte_identical_output() {
    fn run() -> Vec<u32> {
        let mut patch = Patch::default();
        patch.amp = Envelope { a: 0.002, d: 0.3, s: 0.5, r: 0.05 };
        patch.drive = 0.2;
        let mut synth = synth(patch);
        let mut out = Vec::new();
        synth.note_on(57, 0.7);
        synth.note_on(64, 0.9);
        out.extend(bits(&render(&mut synth, 4_800).0));
        synth.note_off(57);
        out.extend(bits(&render(&mut synth, 4_800).0));
        synth.sustain(true);
        synth.note_off(64);
        out.extend(bits(&render(&mut synth, 4_800).0));
        synth.sustain(false);
        out.extend(bits(&render(&mut synth, 4_800).0));
        out
    }
    assert_eq!(run(), run());
}

#[test]
fn render_accepts_any_length_after_prepare() {
    let mut synth = synth(sine_patch());
    synth.prepare(64);
    synth.note_on(60, 0.8);

    let (zero, _) = render(&mut synth, 0);
    assert!(zero.is_empty());

    let (short, _) = render(&mut synth, 100);
    assert!(peak(&short) > 0.0);

    let (long, _) = render(&mut synth, 300);
    assert!(peak(&long) > 0.0);

    // A mismatched pair still renders the shorter length and leaves the rest.
    let mut left = [0.0f32; 128];
    let mut right = [0.0f32; 32];
    synth.render(&mut left, &mut right);
    assert!(right.iter().all(|s| s.is_finite()));
    assert!(left[32..].iter().all(|&s| s == 0.0));
}

#[test]
fn same_note_retrigger_replaces_instead_of_stacking() {
    let mut synth = synth(sine_patch());
    synth.note_on(60, 0.8);
    synth.note_on(60, 0.9);
    assert_eq!(synth.active_voices(), 1);
}

#[test]
fn sustain_holds_notes_until_the_pedal_lifts() {
    let mut patch = sine_patch();
    patch.amp = Envelope { a: 0.001, d: 0.001, s: 0.8, r: 0.05 };
    let mut synth = synth(patch);
    synth.note_on(60, 0.8);
    let _ = render(&mut synth, 2_400);

    synth.sustain(true);
    synth.note_off(60);
    let (held, _) = render(&mut synth, 4_800);
    assert!(peak(&held[2_400..]) > 0.01, "sustain let the note go");
    assert_eq!(synth.active_voices(), 1);

    synth.sustain(false);
    let (released, _) = render(&mut synth, 4_800);
    let last = (RATE * 0.05) as usize + 1;
    assert_eq!(peak(&released[last..]), 0.0, "pedal release did not stop");
    assert_eq!(synth.active_voices(), 0);
}
