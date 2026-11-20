//! The machine's ordinary audio, captured from a virtual sink.
//!
//! When the engine owns the interface it holds the card exclusively, so the
//! Music app, a video, a notification or a call has nowhere to play. The
//! manager makes a null sink the default output and the engine captures that
//! sink's monitor here, then mixes it like any other source
//! (`docs/studio-audio-roadmap.md` §8-§9).
//!
//! The capture is `parec` — the same PulseAudio/PipeWire tooling the reception
//! mixer and the remote Music receiver already use — so a machine without that
//! tooling simply has no system mix; the patch still runs. `parec` is asked for
//! a small process latency: its own default buffers seconds of a monitor
//! source and hands it over in bursts, which a ring sized for a few periods
//! cannot hold. A dedicated thread owns the child and a lock-free ring, and the
//! device loop only pops whole stereo frames, so a slow or missing `parec` is a
//! dropout, never a stalled callback. Nothing prefills the ring: the output
//! starts as silence on the frame it is asked for, not a period late.
//!
//! `parec` is retried while the engine runs: the supervisor may create the
//! sink a moment after the engine starts, and a PipeWire restart replaces the
//! monitor node. Stopping kills the child and joins the thread, so turning the
//! switch off leaves nothing behind.

use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use jawn_audio::monbus::{self, Consumer};

/// The process latency `parec` is asked for: small, steady chunks. Left to
/// itself the server hands a monitor source seconds of audio in bursts, which
/// no modest ring can hold; the device loop then hears a third of a second on,
/// a third off, two seconds behind.
pub const LATENCY_MSEC: u32 = 20;

/// The ring spans about one chunk plus a cushion — the same ~85 ms of stereo
/// the take monitor uses. `monbus` rounds up to a power of two and never goes
/// below its own floor, so this is the minimum.
const RING_MSEC: u32 = 85;

/// The PulseAudio/PipeWire alias for this machine's default input. A plan's
/// `input` source names a channel, not a node, so the engine records the
/// default source; the system mix only moves the default output.
#[cfg_attr(not(feature = "alsa"), allow(dead_code))]
pub const DEFAULT_INPUT: &str = "@DEFAULT_SOURCE@";

/// Frames in one `parec` process period at `rate`.
fn chunk_frames(rate: u32) -> usize {
    (u64::from(rate) * u64::from(LATENCY_MSEC) / 1000) as usize
}

/// The ring's minimum span in frames: one 20 ms chunk plus the cushion. It is
/// never smaller than two chunks, so a full period may arrive while the device
/// loop is mid-buffer without an immediate drop.
fn ring_frames(rate: u32) -> usize {
    let span = (u64::from(rate) * u64::from(RING_MSEC) / 1000) as usize;
    span.max(2 * chunk_frames(rate))
}

/// One system capture: the child process, the thread reading it, and the ring
/// the device loop drains.
pub struct SystemCapture {
    stop: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
    /// Frames the ring discarded because it was full. Shared with the bus, so a
    /// future status field can read it while the capture runs (nothing reads it
    /// yet, hence `allow`).
    #[allow(dead_code)]
    drops: Arc<AtomicU64>,
    handle: Option<JoinHandle<()>>,
}

impl SystemCapture {
    /// Start `parec` on `device` (usually `jawn_system.monitor`) at `rate`,
    /// returning the ring's consumer. The child is spawned on a thread that
    /// retries, so a sink created a moment later is still picked up.
    pub fn start(device: &str, rate: u32) -> Result<(SystemCapture, Consumer), String> {
        Self::start_with(device, rate, 2, None)
    }

    /// Start one routed input's own capture. `channels` is the plan's capture
    /// width; the samples of `channel` are kept and duplicated into the stereo
    /// ring every capture uses, so the patchbay can read it like a card
    /// channel. The stream is separate from the system mix and from every
    /// other input, and uses the same 20 ms pacing.
    #[cfg_attr(not(feature = "alsa"), allow(dead_code))]
    pub fn start_channel(
        device: &str,
        rate: u32,
        channel: usize,
        channels: usize,
    ) -> Result<(SystemCapture, Consumer), String> {
        if channels <= channel {
            return Err(format!(
                "input channel {channel} is outside the {channels}-channel capture"
            ));
        }
        Self::start_with(device, rate, channels, Some(channel))
    }

    fn start_with(
        device: &str,
        rate: u32,
        channels: usize,
        pick: Option<usize>,
    ) -> Result<(SystemCapture, Consumer), String> {
        if !jawn_audio::backends::command_exists("parec") {
            return Err(
                "no parec on PATH; the machine's own audio cannot be captured".to_string()
            );
        }
        let (producer, consumer) = monbus::new(ring_frames(rate));
        let drops = producer.dropped_handle();
        let stop = Arc::new(AtomicBool::new(false));
        let child = Arc::new(Mutex::new(None));
        let thread_stop = Arc::clone(&stop);
        let thread_child = Arc::clone(&child);
        let device = device.to_string();

        let handle = thread::Builder::new()
            .name("jawn-audio-system-mix".to_string())
            .spawn(move || {
                let mut complained = false;
                while !thread_stop.load(Ordering::SeqCst) {
                    match spawn_parec(&device, rate, channels) {
                        Ok(mut running) => {
                            let Some(mut stdout) = running.stdout.take() else {
                                let _ = running.kill();
                                continue;
                            };
                            *lock(&thread_child) = Some(running);
                            // Stop may have found the slot empty just before
                            // this spawn; do not start reading a child nobody
                            // will kill.
                            if thread_stop.load(Ordering::SeqCst) {
                                if let Some(mut late) = lock(&thread_child).take() {
                                    let _ = late.kill();
                                    let _ = late.wait();
                                }
                                break;
                            }
                            let mut bytes = vec![0u8; 4096];
                            let mut pending: Vec<u8> = Vec::new();
                            loop {
                                if thread_stop.load(Ordering::SeqCst) {
                                    break;
                                }
                                match stdout.read(&mut bytes) {
                                    Ok(0) => break,
                                    Ok(count) => {
                                        pending.extend_from_slice(&bytes[..count]);
                                        push_whole_frames(&producer, &mut pending, channels, pick);
                                    }
                                    Err(error) => {
                                        if !complained {
                                            complained = true;
                                            eprintln!("jawn-audio: system mix read: {error}");
                                        }
                                        break;
                                    }
                                }
                            }
                            // The reader is gone; reap the child and let the
                            // next attempt start a fresh one.
                            if let Some(mut finished) = lock(&thread_child).take() {
                                let _ = finished.kill();
                                let _ = finished.wait();
                            }
                        }
                        Err(error) => {
                            if !complained {
                                complained = true;
                                eprintln!("jawn-audio: system mix: {error}");
                            }
                        }
                    }
                    if thread_stop.load(Ordering::SeqCst) {
                        break;
                    }
                    // The sink may not exist yet, or the server may be
                    // restarting. Wait and try again; the engine keeps playing
                    // the patch's own sources meanwhile.
                    thread::sleep(Duration::from_millis(250));
                }
            })
            .map_err(|error| format!("cannot start the system-mix thread: {error}"))?;

        Ok((
            SystemCapture {
                stop,
                child,
                drops,
                handle: Some(handle),
            },
            consumer,
        ))
    }

    /// Frames the ring has discarded because `parec` delivered a burst larger
    /// than the ring could hold. Whole frames only; a non-zero count is the
    /// measure of a capture that is still too slow, not an error. Nothing reads
    /// it yet; a status field is the intended caller.
    #[allow(dead_code)]
    pub fn dropped(&self) -> u64 {
        self.drops.load(Ordering::Relaxed)
    }

    /// Stop the child and join the thread. Called by `Drop` as well, so a
    /// crashed or stopped patch never leaves `parec` behind.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(mut child) = lock(&self.child).take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for SystemCapture {
    fn drop(&mut self) {
        self.stop();
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Whether `device` is a source the sound server currently offers. `None`
/// means the question cannot be asked here (no `pactl`, or it failed), and the
/// caller starts the capture anyway rather than refusing a source it cannot
/// check. A `handset` source treats `Some(false)` as silent, not an error.
pub fn source_exists(device: &str) -> Option<bool> {
    if !jawn_audio::backends::command_exists("pactl") {
        return None;
    }
    let output = Command::new("pactl")
        .arg("list")
        .arg("short")
        .arg("sources")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(lists_source(&String::from_utf8_lossy(&output.stdout), device))
}

/// One `pactl list short sources` line is `index<TAB>name<TAB>driver<TAB>…`.
fn lists_source(listing: &str, device: &str) -> bool {
    listing
        .lines()
        .any(|line| line.split('\t').nth(1) == Some(device))
}

/// The `parec` argument vector. Factored out so a test can assert its shape
/// without a sound server; the explicit process latency is the fix, not a
/// preference: without it the server's own default is seconds of buffer, and
/// each burst exceeds the ring.
fn parec_args(device: &str, rate: u32, channels: usize) -> Vec<String> {
    vec![
        format!("--device={device}"),
        "--format=s16le".to_string(),
        format!("--rate={rate}"),
        format!("--channels={channels}"),
        format!("--latency-msec={LATENCY_MSEC}"),
        format!("--process-time-msec={LATENCY_MSEC}"),
        "--raw".to_string(),
    ]
}

fn spawn_parec(device: &str, rate: u32, channels: usize) -> Result<Child, String> {
    Command::new("parec")
        .args(parec_args(device, rate, channels))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("cannot start parec: {error}"))
}

/// Convert complete little-endian S16 frames to f32 and push them. `pick`
/// selects one channel and duplicates it to both sides, which is how a routed
/// input keeps its own channel; without it the first two channels are kept. A
/// partial frame stays in `pending` for the next read; it is never guessed.
fn push_whole_frames(
    producer: &monbus::Producer,
    pending: &mut Vec<u8>,
    channels: usize,
    pick: Option<usize>,
) {
    let width = channels.max(1) * 2;
    let frames = pending.len() / width;
    if frames == 0 {
        return;
    }
    let mut block = Vec::with_capacity(frames * 2);
    for frame in 0..frames {
        let base = frame * width;
        let sample = |channel: usize| {
            let offset = base + channel.min(channels.saturating_sub(1)) * 2;
            let value = i16::from_le_bytes([pending[offset], pending[offset + 1]]);
            f32::from(value) / 32_768.0
        };
        let (left, right) = match pick {
            Some(channel) => {
                let value = sample(channel);
                (value, value)
            }
            None if channels >= 2 => (sample(0), sample(1)),
            None => {
                let value = sample(0);
                (value, value)
            }
        };
        block.push(left);
        block.push(right);
    }
    producer.push(&block);
    pending.drain(..frames * width);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_frames_are_converted_and_a_partial_one_is_kept() {
        let (producer, consumer) = monbus::new(ring_frames(48_000));
        let mut pending = vec![0x00, 0x40, 0x00, 0xC0, 0x00, 0x20];
        push_whole_frames(&producer, &mut pending, 2, None);
        assert_eq!(pending.len(), 2, "the incomplete second frame stays");

        let mut out = [0.0f32; 2];
        assert_eq!(consumer.pop(&mut out), 1);
        assert!((out[0] - 0.5).abs() < 1e-6, "{out:?}");
        assert!((out[1] + 0.5).abs() < 1e-6, "{out:?}");
    }

    #[test]
    fn an_input_capture_keeps_only_the_channel_it_was_started_for() {
        // Two four-channel frames: channels 0..3 are 0.1, 0.2, 0.3, 0.4.
        let (producer, consumer) = monbus::new(ring_frames(48_000));
        let sample = |value: f32| ((value * 32_768.0) as i16).to_le_bytes();
        let mut pending = Vec::new();
        for _ in 0..2 {
            for value in [0.1f32, 0.2, 0.3, 0.4] {
                pending.extend_from_slice(&sample(value));
            }
        }
        push_whole_frames(&producer, &mut pending, 4, Some(2));
        assert!(pending.is_empty(), "both whole frames were consumed");

        let mut out = [0.0f32; 4];
        assert_eq!(consumer.pop(&mut out), 2);
        for frame in out.chunks(2) {
            assert!((frame[0] - 0.3).abs() < 1e-3, "{out:?}");
            assert!((frame[1] - 0.3).abs() < 1e-3, "the channel feeds both sides");
        }
    }

    #[test]
    fn the_capture_asks_for_small_steady_chunks() {
        let args = parec_args("jawn_system.monitor", 48_000, 2);
        assert!(args.contains(&"--device=jawn_system.monitor".to_string()), "{args:?}");
        assert!(args.contains(&"--format=s16le".to_string()), "{args:?}");
        assert!(args.contains(&"--rate=48000".to_string()), "{args:?}");
        assert!(args.contains(&"--channels=2".to_string()), "{args:?}");
        assert!(args.contains(&"--raw".to_string()), "{args:?}");
        // The whole point of the change: an explicit process latency, so the
        // server does not answer with seconds of buffered audio at once.
        assert!(
            args.contains(&format!("--latency-msec={LATENCY_MSEC}")),
            "{args:?}"
        );
        assert!(
            args.contains(&format!("--process-time-msec={LATENCY_MSEC}")),
            "{args:?}"
        );
    }

    #[test]
    fn an_input_capture_asks_for_the_plan_width_with_the_same_pacing() {
        let args = parec_args(DEFAULT_INPUT, 48_000, 4);
        assert!(
            args.contains(&format!("--device={DEFAULT_INPUT}")),
            "{args:?}"
        );
        assert!(args.contains(&"--channels=4".to_string()), "{args:?}");
        assert!(
            args.contains(&format!("--latency-msec={LATENCY_MSEC}")),
            "an input uses the same 20 ms pacing: {args:?}"
        );
        assert!(
            args.contains(&format!("--process-time-msec={LATENCY_MSEC}")),
            "{args:?}"
        );
    }

    #[test]
    fn a_channel_outside_the_capture_is_refused_before_a_process_starts() {
        let error = SystemCapture::start_channel(DEFAULT_INPUT, 48_000, 2, 2)
            .err()
            .expect("channel 2 cannot exist in a two-channel capture");
        assert!(error.contains("channel 2"), "{error}");
    }

    #[test]
    fn the_ring_holds_more_than_two_chunks() {
        let rate = 48_000;
        assert_eq!(chunk_frames(rate), 960, "20 ms at 48 kHz");
        assert!(
            ring_frames(rate) >= 2 * chunk_frames(rate),
            "{} frames is not two chunks",
            ring_frames(rate)
        );
    }

    #[test]
    fn a_steady_twenty_millisecond_pace_drops_nothing() {
        let rate = 48_000;
        let (producer, consumer) = monbus::new(ring_frames(rate));
        let chunk = chunk_frames(rate);
        let mut out = vec![0.0f32; chunk * 2];
        let mut frame = 0u64;
        for period in 0..200 {
            let block: Vec<f32> = (0..chunk)
                .flat_map(|_| {
                    let value = frame as f32;
                    frame += 1;
                    [value, -value]
                })
                .collect();
            assert_eq!(
                producer.push(&block),
                0,
                "period {period} overflowed the ring"
            );
            assert_eq!(consumer.pop(&mut out), chunk, "period {period} underran");
            for index in 0..chunk {
                let left = out[index * 2];
                assert_eq!(out[index * 2 + 1], -left, "period {period} split a frame");
            }
        }
        assert_eq!(producer.dropped(), 0, "a steady pace never drops");
        assert_eq!(frame, 200 * chunk as u64, "every frame was produced");
    }

    #[test]
    fn a_burst_drops_whole_frames_and_never_a_partial_one() {
        let rate = 48_000;
        let (producer, consumer) = monbus::new(ring_frames(rate));
        let capacity = ring_frames(rate).max(monbus::MIN_FRAMES).next_power_of_two();
        let burst = capacity + 960 * 7;
        let block: Vec<f32> = (0..burst)
            .flat_map(|frame| [frame as f32, -(frame as f32)])
            .collect();

        let dropped = producer.push(&block);
        assert_eq!(dropped, burst - capacity, "the newest frames are dropped");
        assert_eq!(producer.dropped() as usize, dropped, "the count is exposed");

        let mut out = vec![0.0f32; capacity * 2];
        assert_eq!(consumer.pop(&mut out), capacity);
        for frame in 0..capacity {
            let left = out[frame * 2];
            assert_eq!(left, frame as f32, "frame {frame} was not the oldest");
            assert_eq!(out[frame * 2 + 1], -left, "a partial frame was emitted");
        }
    }

    #[test]
    fn a_new_capture_holds_no_startup_silence() {
        // Nothing prefills the ring and nothing on the output side waits: a
        // capture that has not delivered yet is a zero-frame pop, not a
        // delayed start.
        let (_producer, consumer) = monbus::new(ring_frames(48_000));
        let mut out = vec![7.0f32; 64];
        assert_eq!(consumer.pop(&mut out), 0);
        assert!(out.iter().all(|sample| *sample == 0.0), "{out:?}");
    }

    #[test]
    fn a_short_source_listing_names_the_sink_monitor() {
        let listing = "47\tjawn_call_in.monitor\tPipeWire\ts16le 2ch 48000Hz\n48\tjawn_system.monitor\tPipeWire\ts16le 2ch 48000Hz\n";
        assert!(lists_source(listing, "jawn_call_in.monitor"));
        assert!(!lists_source(listing, "jawn_call_in"));
        assert!(!lists_source(listing, "jawn_call_out.monitor"));
    }

    #[test]
    fn a_missing_tool_is_a_sentence_not_a_panic() {
        // The build machine may have parec, so only the shape is asserted: a
        // start either returns a running capture or the sentence.
        match SystemCapture::start("jawn_system.monitor", 48_000) {
            Ok((mut capture, _consumer)) => {
                assert_eq!(capture.dropped(), 0, "a fresh capture has dropped nothing");
                capture.stop();
            }
            Err(error) => assert!(error.contains("parec"), "{error}"),
        }
    }
}
