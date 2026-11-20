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
//! tooling simply has no system mix; the patch still runs. A dedicated thread
//! owns the child and a lock-free ring, and the device loop only pops whole
//! stereo frames, so a slow or missing `parec` is a dropout, never a stalled
//! callback.
//!
//! `parec` is retried while the engine runs: the supervisor may create the
//! sink a moment after the engine starts, and a PipeWire restart replaces the
//! monitor node. Stopping kills the child and joins the thread, so turning the
//! switch off leaves nothing behind.

use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use jawn_audio::monbus::{self, Consumer};

/// Frames the monitor ring holds: about 85 ms of stereo at 48 kHz, the same
/// cushion the take monitor uses. A `parec` stall longer than this is a gap.
const RING_FRAMES: usize = 4096;

/// One system capture: the child process, the thread reading it, and the ring
/// the device loop drains.
pub struct SystemCapture {
    stop: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
    handle: Option<JoinHandle<()>>,
}

impl SystemCapture {
    /// Start `parec` on `device` (usually `jawn_system.monitor`) at `rate`,
    /// returning the ring's consumer. The child is spawned on a thread that
    /// retries, so a sink created a moment later is still picked up.
    pub fn start(device: &str, rate: u32) -> Result<(SystemCapture, Consumer), String> {
        if !jawn_audio::backends::command_exists("parec") {
            return Err(
                "no parec on PATH; the machine's own audio cannot be captured".to_string()
            );
        }
        let (producer, consumer) = monbus::new(RING_FRAMES);
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
                    match spawn_parec(&device, rate) {
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
                                        push_whole_frames(&producer, &mut pending);
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
                handle: Some(handle),
            },
            consumer,
        ))
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

fn spawn_parec(device: &str, rate: u32) -> Result<Child, String> {
    Command::new("parec")
        .arg(format!("--device={device}"))
        .arg("--format=s16le")
        .arg(format!("--rate={rate}"))
        .arg("--channels=2")
        .arg("--raw")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("cannot start parec: {error}"))
}

/// Convert complete little-endian S16 stereo frames to f32 and push them. A
/// partial frame stays in `pending` for the next read; it is never guessed.
fn push_whole_frames(producer: &monbus::Producer, pending: &mut Vec<u8>) {
    let frames = pending.len() / 4;
    if frames == 0 {
        return;
    }
    let mut block = Vec::with_capacity(frames * 2);
    for frame in 0..frames {
        let offset = frame * 4;
        let left = i16::from_le_bytes([pending[offset], pending[offset + 1]]);
        let right = i16::from_le_bytes([pending[offset + 2], pending[offset + 3]]);
        block.push(f32::from(left) / 32_768.0);
        block.push(f32::from(right) / 32_768.0);
    }
    producer.push(&block);
    pending.drain(..frames * 4);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_frames_are_converted_and_a_partial_one_is_kept() {
        let (producer, consumer) = monbus::new(RING_FRAMES);
        let mut pending = vec![0x00, 0x40, 0x00, 0xC0, 0x00, 0x20];
        push_whole_frames(&producer, &mut pending);
        assert_eq!(pending.len(), 2, "the incomplete second frame stays");

        let mut out = [0.0f32; 2];
        assert_eq!(consumer.pop(&mut out), 1);
        assert!((out[0] - 0.5).abs() < 1e-6, "{out:?}");
        assert!((out[1] + 0.5).abs() < 1e-6, "{out:?}");
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
            Ok((mut capture, _consumer)) => capture.stop(),
            Err(error) => assert!(error.contains("parec"), "{error}"),
        }
    }
}
