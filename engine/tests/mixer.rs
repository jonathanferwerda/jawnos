//! The mixer is the piece that lets both inputs of a two-in interface become
//! tracks. These tests run the real strips and the real disk writers, with no
//! sound card: `Mixer` owns no device, it only turns mono blocks into stereo.

use std::fs;
use std::path::PathBuf;

use jawn_audio::{to_i16, Channel, DiskWriter, Effect, Mixer};

/// Two paths under the system temp directory, removed however the test ends.
struct TempTakes {
    paths: Vec<PathBuf>,
}

impl TempTakes {
    fn new(tag: &str, count: usize) -> Self {
        let mut paths = Vec::with_capacity(count);
        for track in 0..count {
            let path = std::env::temp_dir().join(format!(
                "jawn-audio-mixer-{}-{tag}-{}.wav",
                std::process::id(),
                track + 1
            ));
            let _ = fs::remove_file(&path);
            paths.push(path);
        }
        TempTakes { paths }
    }
}

impl Drop for TempTakes {
    fn drop(&mut self) {
        for path in &self.paths {
            let _ = fs::remove_file(path);
        }
    }
}

/// Write one interleaved stereo block through a real `DiskWriter` and finish it.
fn write_take(path: &str, stereo: &[f32]) -> Vec<u8> {
    let mut writer = DiskWriter::spawn(std::path::Path::new(path), 48_000, 2, 64, 4)
        .expect("spawn a take writer");
    let pcm: Vec<i16> = stereo.iter().map(|sample| to_i16(*sample)).collect();
    assert_eq!(writer.push(&pcm), 0, "the whole block fits the queue");
    writer.finish().expect("finish the take");
    fs::read(path).expect("read the take")
}

fn peaks(bytes: &[u8]) -> (i32, i32) {
    let data = &bytes[44..];
    let mut left = 0i32;
    let mut right = 0i32;
    for frame in data.chunks_exact(4) {
        let l = i16::from_le_bytes([frame[0], frame[1]]) as i32;
        let r = i16::from_le_bytes([frame[2], frame[3]]) as i32;
        left = left.max(l.abs());
        right = right.max(r.abs());
    }
    (left, right)
}

/// A test insert: scales the block. `prepare` is where an effect may allocate,
/// and this one needs nothing.
struct Scale(f32);

impl Effect for Scale {
    fn prepare(&mut self, _rate: u32, _max_frames: usize) {}
    fn process(&mut self, block: &mut [f32]) {
        for sample in block {
            *sample *= self.0;
        }
    }
    fn reset(&mut self) {}
    fn name(&self) -> &'static str {
        "scale"
    }
}

/// A test insert: adds a constant. Ordered after a `Scale`, it proves the chain
/// is not silently sorted.
struct Offset(f32);

impl Effect for Offset {
    fn prepare(&mut self, _rate: u32, _max_frames: usize) {}
    fn process(&mut self, block: &mut [f32]) {
        for sample in block {
            *sample += self.0;
        }
    }
    fn reset(&mut self) {}
    fn name(&self) -> &'static str {
        "offset"
    }
}

#[test]
fn two_tracks_with_different_gain_and_pan_produce_different_files() {
    let takes = TempTakes::new("gain-pan", 2);
    let mut mixer = Mixer::new(&[0, 1], &["ch1", "ch2"]);
    // Track 1: full gain hard left. Track 2: half gain hard right.
    mixer.tracks_mut()[0].channel = Channel::new(1.0, -1.0);
    mixer.tracks_mut()[1].channel = Channel::new(0.5, 1.0);
    mixer.prepare(48_000, 64);

    let mono = vec![0.5f32; 64];
    let mut first = vec![0.0f32; 128];
    let mut second = vec![0.0f32; 128];
    mixer.process(0, &mono, &mut first).expect("track 1");
    mixer.process(1, &mono, &mut second).expect("track 2");

    let first_bytes = write_take(
        takes.paths[0].to_str().expect("UTF-8 path"),
        &first,
    );
    let second_bytes = write_take(
        takes.paths[1].to_str().expect("UTF-8 path"),
        &second,
    );
    assert_ne!(first_bytes, second_bytes, "the two tracks are the same take");

    let (left, right) = peaks(&first_bytes);
    let full = i16::MAX as i32;
    assert!(
        (left - full / 2).abs() < full / 20,
        "track 1 left peak {left} was not half scale"
    );
    assert!(right < full / 100, "track 1 right peak {right} was not silent");

    let (left, right) = peaks(&second_bytes);
    assert!(left < full / 100, "track 2 left peak {left} was not silent");
    assert!(
        (right - full / 4).abs() < full / 20,
        "track 2 right peak {right} was not a quarter scale"
    );
}

#[test]
fn mix_sums_every_track_into_one_bus() {
    let mut mixer = Mixer::new(&[0, 1], &["ch1", "ch2"]);
    mixer.tracks_mut()[0].channel = Channel::new(1.0, -1.0);
    mixer.tracks_mut()[1].channel = Channel::new(1.0, -1.0);
    mixer.prepare(48_000, 2);

    let first = [0.5f32, 0.25];
    let second = [0.25f32, 0.125];
    let mut bus = [9.0f32; 4];
    mixer.mix(&[&first, &second], &mut bus).expect("mix");

    assert!((bus[0] - 0.75).abs() < 1e-6, "left sum: {:?}", bus);
    assert!((bus[1] - 0.0).abs() < 1e-6, "right is silent: {:?}", bus);
    assert!((bus[2] - 0.375).abs() < 1e-6, "left sum: {:?}", bus);
    assert!((bus[3] - 0.0).abs() < 1e-6, "right is silent: {:?}", bus);
}

#[test]
fn a_tracks_inserts_run_in_the_order_they_were_given() {
    let mut mixer = Mixer::new(&[0], &["ch1"]);
    let mut channel = Channel::new(1.0, -1.0);
    // 2x then +1 is 3, not 4: reversing the inserts would hear the difference.
    channel.push(Box::new(Scale(2.0)));
    channel.push(Box::new(Offset(1.0)));
    mixer.tracks_mut()[0].channel = channel;
    mixer.prepare(48_000, 1);

    let mut stereo = vec![0.0f32; 2];
    mixer.process(0, &[1.0], &mut stereo).expect("process");
    assert!((stereo[0] - 3.0).abs() < 1e-6, "left: {:?}", stereo);
    assert!(stereo[1].abs() < 1e-6, "right: {:?}", stereo);
}

#[test]
fn process_refuses_a_short_stereo_buffer_instead_of_panicking() {
    let mut mixer = Mixer::new(&[0], &["ch1"]);
    mixer.prepare(48_000, 4);

    let mut short = vec![0.0f32; 3];
    let error = mixer
        .process(0, &[0.0, 0.0], &mut short)
        .expect_err("a short stereo buffer must be refused");
    assert!(error.contains("BadBlock"), "unexpected error: {error}");

    // A block longer than the prepared period is refused too, not reallocated.
    let mut stereo = vec![0.0f32; 16];
    let error = mixer
        .process(0, &[0.0; 8], &mut stereo)
        .expect_err("an over-long block must be refused");
    assert!(error.contains("BlockTooLong"), "unexpected error: {error}");
}
