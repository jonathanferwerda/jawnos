//! Raw ALSA playback and the patch-cable loopback, behind `--features alsa`.
//!
//! The target is a USB class-compliant interface (a PCM2902), which accepts
//! only 48-sample periods at 48 kHz. We ask for the requested period with
//! `Near` and report what was granted, so a 64-frame block is honestly a block
//! spread across two USB frames rather than an imaginary 64-sample period
//! (docs/studio-audio-roadmap.md §2, P1).

use std::f32::consts::TAU;
use std::sync::atomic::{AtomicBool, Ordering};

use alsa::pcm::{Access, Format, HwParams, State, PCM};
use alsa::{Direction, ValueOr};

use crate::backends::RunReport;
use crate::listen::{edge_fade_frames, Edge};
use crate::loopback::{self, LoopbackReport};
use crate::monbus::Consumer;
use crate::pipewire_guard::PlaybackGuard;

/// A patch-cable loopback is the interface's stereo pair: the click leaves one
/// output and comes back on one input, so the measurement is stereo by nature
/// rather than by an assumption the capture path makes.
const LOOPBACK_CHANNELS: u32 = 2;

/// One open and configured PCM stream, plus the shape ALSA actually granted.
struct Stream {
    pcm: PCM,
    rate: u32,
    period: usize,
    buffer: usize,
    channels: usize,
}

fn sample_format() -> Format {
    if cfg!(target_endian = "little") {
        Format::S16LE
    } else {
        Format::S16BE
    }
}

fn open(
    device: &str,
    direction: Direction,
    rate: u32,
    period: usize,
    buffer: usize,
    channels: u32,
) -> Result<Stream, String> {
    let pcm = PCM::new(device, direction, false)
        .map_err(|error| format!("cannot open {device}: {error}"))?;

    // Fill the hardware parameter space, then ask for the requested shape and
    // read back the final one from the applied parameters.
    {
        let params =
            HwParams::any(&pcm).map_err(|error| format!("{device}: hardware parameters: {error}"))?;
        params
            .set_access(Access::RWInterleaved)
            .map_err(|error| format!("{device}: interleaved access: {error}"))?;
        params
            .set_channels(channels)
            .map_err(|error| format!("{device}: {channels} channels: {error}"))?;
        params
            .set_format(sample_format())
            .map_err(|error| format!("{device}: S16 format: {error}"))?;
        params
            .set_rate(rate, ValueOr::Nearest)
            .map_err(|error| format!("{device}: {rate} Hz: {error}"))?;
        params
            .set_period_size_near(period as i64, ValueOr::Nearest)
            .map_err(|error| format!("{device}: {period}-frame period: {error}"))?;
        params
            .set_buffer_size_near(buffer as i64)
            .map_err(|error| format!("{device}: {buffer}-frame buffer: {error}"))?;
        pcm.hw_params(&params)
            .map_err(|error| format!("{device}: apply hardware parameters: {error}"))?;
    }

    let applied = pcm
        .hw_params_current()
        .map_err(|error| format!("{device}: read hardware parameters: {error}"))?;
    let rate = applied.get_rate().unwrap_or(rate);
    let period = applied.get_period_size().unwrap_or(period as i64).max(1) as usize;
    let buffer = applied
        .get_buffer_size()
        .unwrap_or(buffer as i64)
        .max(period as i64) as usize;
    let granted = applied.get_channels().unwrap_or(channels) as usize;
    drop(applied);

    // A take's interleaving and every per-track input index are laid out from
    // the requested count, so a stream that grants a different one cannot be
    // read honestly. Name the granted number rather than silently reshaping.
    if granted != channels as usize {
        return Err(format!(
            "{device}: asked for {channels} channels, the device granted {granted}"
        ));
    }

    pcm.prepare()
        .map_err(|error| format!("{device}: prepare: {error}"))?;

    Ok(Stream {
        pcm,
        rate,
        period,
        buffer,
        channels: granted,
    })
}

fn to_i16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
}

/// Play `seconds` of silence or a sine through `device`. Returns the shape ALSA
/// granted, the peak, and the number of underruns recovered from.
pub fn run_playback(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    channels: usize,
    seconds: f64,
    tone: Option<f32>,
) -> Result<RunReport, String> {
    let stream = open(
        device,
        Direction::Playback,
        rate,
        period,
        buffer,
        channels as u32,
    )?;
    let channels = stream.channels;
    let io = stream
        .pcm
        .io_i16()
        .map_err(|error| format!("{device}: S16 stream: {error}"))?;

    let frames = stream.period.max(1);
    let total_frames = (seconds * stream.rate as f64).round();
    let blocks = (total_frames / frames as f64) as usize;
    let step = tone.map(|hz| TAU * hz / stream.rate as f32);

    let mut block = vec![0i16; frames * channels];
    let mut phase = 0.0f32;
    let mut peak = 0.0f32;
    let mut xruns = 0usize;

    for _ in 0..blocks {
        for frame in block.chunks_mut(channels) {
            let sample = if let Some(step) = step {
                let value = phase.sin();
                phase = (phase + step) % TAU;
                value
            } else {
                0.0
            };
            peak = peak.max(sample.abs());
            let quantised = to_i16(sample);
            for out in frame.iter_mut() {
                *out = quantised;
            }
        }

        // `writei` counts frames; the buffer is interleaved, so advance by
        // frames * channels. A partial write is normal near the end of a block.
        let mut written = 0usize;
        while written < block.len() {
            match io.writei(&block[written..]) {
                Ok(0) => break,
                Ok(count) => written += count * channels,
                Err(error) => {
                    let message = format!("{error}");
                    match stream.pcm.try_recover(error, true) {
                        Ok(()) => xruns += 1,
                        Err(_) => return Err(format!("{device}: write: {message}")),
                    }
                }
            }
        }
    }

    // Let the last buffered period reach the device; a drain timeout is not a
    // failure of the run itself.
    let _ = stream.pcm.drain();

    Ok(RunReport {
        backend: "alsa",
        device: device.to_string(),
        rate: stream.rate,
        frames,
        buffer: stream.buffer,
        channels,
        blocks,
        samples: blocks * frames * channels,
        peak,
        xruns,
    })
}

/// What a file-backed playback produced: the shape ALSA granted and the
/// frames the source supplied.
#[derive(Debug, Clone)]
pub struct PlaybackReport {
    pub rate: u32,
    pub period: usize,
    pub buffer: usize,
    pub channels: usize,
    pub frames: u64,
    pub xruns: usize,
}

/// Answer "can this device be opened for playback?", with the rate it granted,
/// and close it again. The socket asks before it answers `playing`, so a busy
/// device is a refusal rather than a status that fails a moment later.
pub fn check_playback(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> Result<u32, String> {
    let stream = open(device, Direction::Playback, rate, period, buffer, 2)?;
    let granted = stream.rate;
    let _ = stream.pcm.drop();
    Ok(granted)
}

/// Play `total_frames` stereo frames from `source` through `device`.
///
/// The device is always asked for two channels, because a playback block is
/// the summed stereo output of the strips. The rate is the files' rate: a card
/// that grants another one would pitch-shift every take, so it is refused
/// rather than reported and played.
pub fn run_file_playback<S: crate::playback::RenderSource>(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    total_frames: u64,
    source: S,
) -> Result<PlaybackReport, String> {
    run_file_playback_guarded(device, rate, period, buffer, total_frames, source, None)
}

/// The same playback with an optional PipeWire guard. The guard arms the
/// stream target before the PCM opens and verifies the resulting graph before
/// a block is rendered, so a stream that fell back to the mix sink stops the
/// pass instead of feeding it.
pub fn run_file_playback_guarded<S: crate::playback::RenderSource>(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    total_frames: u64,
    mut source: S,
    guard: Option<&PlaybackGuard>,
) -> Result<PlaybackReport, String> {
    if let Some(guard) = guard {
        guard.arm();
    }
    let stream = open(device, Direction::Playback, rate, period, buffer, 2)?;
    if let Some(guard) = guard {
        guard.verify()?;
    }
    if stream.rate != rate {
        return Err(format!(
            "{device}: asked for {rate} Hz, the device granted {} Hz; the takes would play at the wrong pitch",
            stream.rate
        ));
    }
    let channels = stream.channels;
    let io = stream
        .pcm
        .io_i16()
        .map_err(|error| format!("{device}: S16 stream: {error}"))?;

    let frames = stream.period.max(1);
    // The source sizes its scratch from the granted shape before the first
    // block; after this it must not allocate.
    source.prepared(stream.rate, frames)?;

    let mut remaining = total_frames;
    let mut played = 0u64;
    let mut xruns = 0usize;
    let mut block = vec![0.0f32; frames * channels];
    let mut pcm = vec![0i16; frames * channels];

    while remaining > 0 {
        let want = remaining.min(frames as u64) as usize;
        let samples = want * channels;
        source.block(&mut block[..samples])?;
        for (out, sample) in pcm[..samples].iter_mut().zip(&block[..samples]) {
            *out = to_i16(*sample);
        }

        // `writei` counts frames; a partial write is normal near the end of a
        // block, and an underrun is recovered and counted like `--run` does.
        let mut written = 0usize;
        while written < samples {
            match io.writei(&pcm[written..samples]) {
                Ok(0) => break,
                Ok(count) => written += count * channels,
                Err(error) => {
                    let message = format!("{error}");
                    match stream.pcm.try_recover(error, true) {
                        Ok(()) => xruns += 1,
                        Err(_) => return Err(format!("{device}: write: {message}")),
                    }
                }
            }
        }
        played += want as u64;
        remaining -= want as u64;
    }

    let _ = stream.pcm.drain();

    Ok(PlaybackReport {
        rate: stream.rate,
        period: frames,
        buffer: stream.buffer,
        channels,
        frames: played,
        xruns,
    })
}

/// What one real-device capture produced: the shape ALSA granted, and the
/// frames that actually reached the caller's sink.
#[derive(Debug, Clone)]
pub struct CaptureReport {
    pub rate: u32,
    pub period: usize,
    pub buffer: usize,
    pub channels: usize,
    pub frames: u64,
    pub xruns: usize,
}

/// Answer "can this device be opened for capture?", with the channel count it
/// granted, and close it again.
///
/// `--record` asks this before it creates the output file, so a take that
/// cannot start never truncates a path the caller already named. Opening twice
/// costs a millisecond and saves an existing take; the real open follows.
pub fn check_capture(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    channels: usize,
) -> Result<usize, String> {
    let stream = open(
        device,
        Direction::Capture,
        rate,
        period,
        buffer,
        channels as u32,
    )?;
    let granted = stream.channels;
    let _ = stream.pcm.drop();
    Ok(granted)
}

/// What a capture does with the blocks it reads, and a chance to size its
/// buffers against the shape ALSA granted. `prepared` runs once, after the
/// device opens and before the first read, so a channel can allocate its
/// scratch and delay lines at the real rate rather than guessing.
pub trait CaptureSink {
    fn prepared(&mut self, _rate: u32, _period: usize, _channels: usize) -> Result<(), String> {
        Ok(())
    }
    /// One interleaved block of the device's own i16 samples, `channels`
    /// samples per frame.
    fn block(&mut self, block: &[i16]) -> Result<(), String>;
}

/// Capture `seconds` of the input, handing each block to `sink` as interleaved
/// S16 samples at the granted channel count. The sink does the writing, so this
/// module stays about the device and the take's WAV layout stays in `wav`
/// (docs/studio-audio-roadmap.md §7, P2).
///
/// The final block is short when the requested duration is not a whole number
/// of periods: the take is exactly `seconds`, not padded to the block size.
pub fn run_capture<S: CaptureSink>(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    channels: usize,
    seconds: f64,
    mut sink: S,
) -> Result<CaptureReport, String> {
    let stream = open(
        device,
        Direction::Capture,
        rate,
        period,
        buffer,
        channels as u32,
    )?;
    let channels = stream.channels;
    let io = stream
        .pcm
        .io_i16()
        .map_err(|error| format!("{device}: S16 stream: {error}"))?;

    let frames = stream.period.max(1);
    // Let the sink size itself from the granted shape before the first read:
    // this is setup, not the audio path.
    sink.prepared(stream.rate, frames, channels)?;

    // Capture starts when read is called, but starting it explicitly makes the
    // first frame's position unambiguous and matches the loopback path.
    stream
        .pcm
        .start()
        .map_err(|error| format!("{device}: start capture: {error}"))?;

    let total = (seconds.max(0.0) * stream.rate as f64).round() as u64;
    let mut remaining = total;
    let mut captured = 0u64;
    let mut xruns = 0usize;
    let mut block = vec![0i16; frames * channels];

    while remaining > 0 {
        let want = remaining.min(frames as u64) as usize;
        let slice = &mut block[..want * channels];
        match io.readi(slice) {
            Ok(0) => break,
            Ok(got) => {
                let got = got.min(want);
                sink.block(&slice[..got * channels])
                    .map_err(|error| format!("{device}: write take: {error}"))?;
                captured += got as u64;
                remaining -= got as u64;
            }
            Err(error) => {
                let message = format!("{error}");
                match stream.pcm.try_recover(error, true) {
                    Ok(()) => xruns += 1,
                    Err(_) => return Err(format!("{device}: capture: {message}")),
                }
            }
        }
    }

    let _ = stream.pcm.drop();

    Ok(CaptureReport {
        rate: stream.rate,
        period: frames,
        buffer: stream.buffer,
        channels,
        frames: captured,
        xruns,
    })
}

/// Monitor one input on the outputs: open capture and playback on the same
/// device, read one block, hand it to `sink`, write the stereo result.
pub fn run_listen<S: crate::listen::ListenSink>(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    capture_channels: usize,
    total: Option<u64>,
    stop: &AtomicBool,
    sink: S,
) -> Result<crate::listen::ListenRun, String> {
    run_listen_with_system(
        device,
        rate,
        period,
        buffer,
        capture_channels,
        total,
        stop,
        sink,
        None,
        None,
    )
}

/// The same monitor, plus the machine's system mix from a virtual sink's
/// monitor. `system` is a lock-free ring filled by a second capture; its
/// frames are added to the block handed to the sink. A missing ring is the
/// ordinary monitor, unchanged.
///
/// The second stream is not the clock: it is drained between blocks and
/// zero-filled on an underrun, exactly as the monitor bus already behaves. That
/// keeps a stalled `parec` a dropout rather than a stalled device loop.
pub fn run_listen_with_system<S: crate::listen::ListenSink>(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    capture_channels: usize,
    total: Option<u64>,
    stop: &AtomicBool,
    mut sink: S,
    mut system: Option<&mut Consumer>,
    guard: Option<&PlaybackGuard>,
) -> Result<crate::listen::ListenRun, String> {
    if capture_channels == 0 {
        return Err("a capture needs at least one channel".to_string());
    }
    // Capture opens first, before the target is armed: `PIPEWIRE_NODE` applies
    // to every stream the ALSA plugin creates, and a capture must keep the
    // default source while the playback goes to the named output.
    let capture = open(
        device,
        Direction::Capture,
        rate,
        period,
        buffer,
        capture_channels as u32,
    )?;
    if let Some(guard) = guard {
        guard.arm();
    }
    let playback = open(device, Direction::Playback, rate, period, buffer, 2)?;
    if let Some(guard) = guard {
        guard.verify()?;
    }
    if capture.rate != playback.rate {
        return Err(format!(
            "{device}: capture runs at {} Hz but playback at {} Hz; monitoring needs one clock",
            capture.rate, playback.rate
        ));
    }

    let rate = capture.rate;
    let channels = capture.channels;
    let frames = capture.period.max(1);
    // Size the strip against the shape the device granted, before the first
    // block; after this the sink only reads and writes memory it owns.
    sink.prepared(rate, frames, channels)?;

    let capture_io = capture
        .pcm
        .io_i16()
        .map_err(|error| format!("{device}: capture stream: {error}"))?;
    let playback_io = playback
        .pcm
        .io_i16()
        .map_err(|error| format!("{device}: playback stream: {error}"))?;

    // Prime the playback with one full buffer of silence and start it before
    // the capture loop. A playback auto-starts on its first write and drains
    // while the loop blocks on the next capture read, so a single write per
    // read leaves it with no cushion and it underruns nearly every block (the
    // hardware run on `table` counted 4,178 in ten seconds). Capture and
    // playback share the card's clock, so the lead absorbs the read's jitter
    // without drifting away. The silence is monitor-only, never part of a take.
    let lead = crate::listen::monitor_prefill_frames(playback.buffer, frames);
    let silence = vec![0i16; lead * 2];
    let mut primed = 0usize;
    while primed < lead {
        match playback_io.writei(&silence[primed * 2..]) {
            Ok(0) => break,
            Ok(count) => primed += count,
            Err(error) => {
                let message = format!("{error}");
                match playback.pcm.try_recover(error, true) {
                    Ok(()) => {}
                    Err(_) => {
                        return Err(format!("{device}: prime playback: {message}"))
                    }
                }
            }
        }
    }
    // A full buffer may already have crossed ALSA's start threshold, in which
    // case the stream is running and `start` is a no-op. Either way the lead
    // is queued and the clock is moving.
    match playback.pcm.start() {
        Ok(()) => {}
        Err(_) if playback.pcm.state() == State::Running => {}
        Err(error) => return Err(format!("{device}: start playback: {error}")),
    }

    // Capture starts after the lead is queued, so the first read has somewhere
    // to go and the playback clock is already running.
    capture
        .pcm
        .start()
        .map_err(|error| format!("{device}: start capture: {error}"))?;

    let mut input = vec![0i16; frames * channels];
    let mut output = vec![0i16; frames * 2];
    let mut system_block = vec![0.0f32; frames * 2];
    let mut remaining = total;
    let mut played = 0u64;
    let mut xruns = 0usize;
    let mut edge = Edge::new(edge_fade_frames(rate));
    let mut stopping = false;

    loop {
        if !stopping && stop.load(Ordering::SeqCst) {
            // The device is handed back from silence: a step from the last
            // sample to nothing is a click, and the capture tail left in the
            // ring is the echo the next path does not have.
            stopping = true;
            edge.toward(0.0);
        }
        if stopping && edge.silent() {
            break;
        }
        let want = match remaining {
            Some(0) => break,
            Some(left) => left.min(frames as u64) as usize,
            None => frames,
        };

        let got = match capture_io.readi(&mut input[..want * channels]) {
            Ok(0) => break,
            Ok(got) => got.min(want),
            Err(error) => {
                let message = format!("{error}");
                match capture.pcm.try_recover(error, true) {
                    Ok(()) => {
                        xruns += 1;
                        continue;
                    }
                    Err(_) => return Err(format!("{device}: capture: {message}")),
                }
            }
        };
        if got == 0 {
            break;
        }

        let system_len = got * 2;
        match system.as_deref_mut() {
            Some(consumer) => {
                consumer.pop(&mut system_block[..system_len]);
            }
            None => system_block[..system_len].fill(0.0),
        }
        sink.block_with_system(
            &input[..got * channels],
            &system_block[..system_len],
            &mut output[..got * 2],
        )?;
        edge.apply(&mut output[..got * 2], 2);

        // `writei` counts frames; a partial write is normal near the end of a
        // block, and an underrun is recovered and counted like `--run` does.
        let samples = got * 2;
        let mut written = 0usize;
        while written < samples {
            match playback_io.writei(&output[written..samples]) {
                Ok(0) => break,
                Ok(count) => written += count * 2,
                Err(error) => {
                    let message = format!("{error}");
                    match playback.pcm.try_recover(error, true) {
                        Ok(()) => xruns += 1,
                        Err(_) => return Err(format!("{device}: playback: {message}")),
                    }
                }
            }
        }

        played += got as u64;
        if let Some(left) = remaining.as_mut() {
            *left = left.saturating_sub(got as u64);
        }
    }

    // Let the last buffered block reach the device; a drain timeout is not a
    // failure of the run itself.
    let _ = playback.pcm.drain();
    let _ = playback.pcm.drop();
    let _ = capture.pcm.drop();

    Ok(crate::listen::ListenRun {
        rate,
        period: frames,
        buffer: capture.buffer,
        channels,
        frames: played,
        xruns,
    })
}

/// The patch that needs no card capture: open only the output and write the
/// mixed stereo block.
///
/// This is the laptop's path. When WirePlumber owns the microphone, opening
/// capture on the same card is `Device or resource busy`; a playback-only open
/// leaves the capture to PipeWire (so the privacy indicator stays off) while
/// the plan's own audio is still mixed to the outputs. The machine's ordinary
/// audio arrives in `system` (the virtual sink's monitor) and is drained
/// between blocks exactly as the duplex loop drains it; a `handset` source is a
/// separate `parec` ring the patchbay pops inside its own render. The sink is
/// prepared against `input_channels` and handed a zero block, so no capture
/// stream is ever opened.
///
/// Timing comes from the output: one buffer of silence is queued before the
/// start, and each blocking write is paced by the device clock rather than by
/// the loop's own speed.
pub fn run_playback_with_system<S: crate::listen::ListenSink>(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    input_channels: usize,
    total: Option<u64>,
    stop: &AtomicBool,
    mut sink: S,
    mut system: Option<&mut Consumer>,
    guard: Option<&PlaybackGuard>,
) -> Result<crate::listen::ListenRun, String> {
    if input_channels == 0 {
        return Err("a patch needs at least one channel".to_string());
    }
    if let Some(guard) = guard {
        guard.arm();
    }
    let playback = open(device, Direction::Playback, rate, period, buffer, 2)?;
    if let Some(guard) = guard {
        guard.verify()?;
    }
    let rate = playback.rate;
    let frames = playback.period.max(1);
    // The graph is still compiled against the width the plan named, so its
    // buffers match; the block it renders is silence for every channel.
    sink.prepared(rate, frames, input_channels)?;

    let playback_io = playback
        .pcm
        .io_i16()
        .map_err(|error| format!("{device}: playback stream: {error}"))?;

    // The same lead as the duplex loop: queue one buffer of silence and start
    // before the first real block, so the blocking writes below are paced by
    // the device and the loop does not spin ahead of it.
    let lead = crate::listen::monitor_prefill_frames(playback.buffer, frames);
    let silence = vec![0i16; lead * 2];
    let mut primed = 0usize;
    while primed < lead {
        match playback_io.writei(&silence[primed * 2..]) {
            Ok(0) => break,
            Ok(count) => primed += count,
            Err(error) => {
                let message = format!("{error}");
                match playback.pcm.try_recover(error, true) {
                    Ok(()) => {}
                    Err(_) => {
                        return Err(format!("{device}: prime playback: {message}"))
                    }
                }
            }
        }
    }
    match playback.pcm.start() {
        Ok(()) => {}
        Err(_) if playback.pcm.state() == State::Running => {}
        Err(error) => return Err(format!("{device}: start playback: {error}")),
    }

    // The plan's capture is zero, and this buffer is never written: no card
    // input is opened, which is the whole point of the playback-only patch.
    let input = vec![0i16; frames * input_channels];
    let mut output = vec![0i16; frames * 2];
    let mut system_block = vec![0.0f32; frames * 2];
    let mut remaining = total;
    let mut played = 0u64;
    let mut xruns = 0usize;
    let mut edge = Edge::new(edge_fade_frames(rate));
    let mut stopping = false;

    loop {
        if !stopping && stop.load(Ordering::SeqCst) {
            // The device is handed back from silence: a step from the last
            // sample to nothing is a click, and the capture tail left in the
            // ring is the echo the next path does not have.
            stopping = true;
            edge.toward(0.0);
        }
        if stopping && edge.silent() {
            break;
        }
        let want = match remaining {
            Some(0) => break,
            Some(left) => left.min(frames as u64) as usize,
            None => frames,
        };

        let stereo = want * 2;
        match system.as_deref_mut() {
            Some(consumer) => {
                consumer.pop(&mut system_block[..stereo]);
            }
            None => system_block[..stereo].fill(0.0),
        }
        sink.block_with_system(
            &input[..want * input_channels],
            &system_block[..stereo],
            &mut output[..stereo],
        )?;
        edge.apply(&mut output[..stereo], 2);

        let mut written = 0usize;
        while written < stereo {
            match playback_io.writei(&output[written..stereo]) {
                Ok(0) => break,
                Ok(count) => written += count * 2,
                Err(error) => {
                    let message = format!("{error}");
                    match playback.pcm.try_recover(error, true) {
                        Ok(()) => xruns += 1,
                        Err(_) => return Err(format!("{device}: playback: {message}")),
                    }
                }
            }
        }

        played += want as u64;
        if let Some(left) = remaining.as_mut() {
            *left = left.saturating_sub(want as u64);
        }
    }

    // Let the last buffered block reach the device; a drain timeout is not a
    // failure of the run itself.
    let _ = playback.pcm.drain();
    let _ = playback.pcm.drop();

    Ok(crate::listen::ListenRun {
        rate,
        period: frames,
        buffer: playback.buffer,
        channels: input_channels,
        frames: played,
        xruns,
    })
}

/// Write one click and find it again. Capture starts first; playback starts a
/// moment later, so `precision_samples` is the period ALSA granted, not a
/// claim of sample alignment.
pub fn loopback(
    backend: &'static str,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> LoopbackReport {
    match measure(device, rate, period, buffer) {
        Ok(result) => LoopbackReport::success(
            backend,
            device,
            result.rate,
            period,
            buffer,
            result.samples,
            result.precision,
            "unlinked",
        ),
        Err(failure) => LoopbackReport::failure(
            backend,
            device,
            rate,
            period,
            buffer,
            failure.precision,
            "unlinked",
            failure.reason,
        ),
    }
}

struct Measurement {
    samples: u64,
    rate: u32,
    precision: u64,
}

struct Failure {
    reason: String,
    precision: u64,
}

fn measure(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> Result<Measurement, Failure> {
    let requested_period = period.max(1) as u64;
    let fail = |reason: String| Failure {
        reason,
        precision: requested_period,
    };

    let capture = open(
        device,
        Direction::Capture,
        rate,
        period,
        buffer,
        LOOPBACK_CHANNELS,
    )
    .map_err(fail)?;
    let playback = open(
        device,
        Direction::Playback,
        rate,
        period,
        buffer,
        LOOPBACK_CHANNELS,
    )
    .map_err(fail)?;
    let precision = capture.period.max(1) as u64;

    // Start playback on a full buffer. A short click alone would otherwise
    // auto-start on the first write and underrun before the explicit start; a
    // threshold larger than the buffer is rejected by `snd_pcm_start`.
    {
        let sw = playback
            .pcm
            .sw_params_current()
            .map_err(|error| fail(format!("{device}: software parameters: {error}")))?;
        let threshold = (playback.buffer as i64).max(1);
        sw.set_start_threshold(threshold)
            .map_err(|error| fail(format!("{device}: start threshold: {error}")))?;
        playback
            .pcm
            .sw_params(&sw)
            .map_err(|error| fail(format!("{device}: software parameters: {error}")))?;
    }

    let capture_io = capture
        .pcm
        .io_i16()
        .map_err(|error| fail(format!("{device}: capture stream: {error}")))?;
    let playback_io = playback
        .pcm
        .io_i16()
        .map_err(|error| fail(format!("{device}: playback stream: {error}")))?;

    // Capture first: a click written into a stopped capture stream would be
    // gone before anything listened.
    capture
        .pcm
        .start()
        .map_err(|error| fail(format!("{device}: start capture: {error}")))?;

    // Learn the room's noise floor before sending anything.
    let preroll_frames =
        ((capture.rate as f64 * loopback::PRE_ROLL_MS as f64 / 1000.0).round() as usize).max(1);
    let mut noise_peak = 0.0f32;
    let mut read_frames = 0usize;
    let mut chunk = vec![0i16; capture.period.max(1) * LOOPBACK_CHANNELS as usize];
    while read_frames < preroll_frames {
        let want = (preroll_frames - read_frames).min(capture.period.max(1));
        let got = capture_io
            .readi(&mut chunk[..want * LOOPBACK_CHANNELS as usize])
            .map_err(|error| fail(format!("{device}: capture: {error}")))?;
        if got == 0 {
            break;
        }
        for frame in chunk[..got * LOOPBACK_CHANNELS as usize].chunks(LOOPBACK_CHANNELS as usize) {
            for sample in frame {
                noise_peak = noise_peak.max(sample.unsigned_abs() as f32 / 32768.0);
            }
        }
        read_frames += got;
    }
    let threshold = loopback::threshold(noise_peak);

    // The capture position when playback begins. Everything before this is our
    // own pre-roll and start-up, not latency, so it must not be in the number.
    let origin = read_frames as u64;

    // One full playback buffer: the click, then silence to the start
    // threshold. The first buffer lasts longer than the round trip at the
    // target's 256-frame buffer, so playback has not underrun before the click
    // comes back.
    let click_frames = loopback::click_frames();
    let play_frames = playback.buffer.max(click_frames.len());
    let mut click = vec![0i16; play_frames * LOOPBACK_CHANNELS as usize];
    for (frame, sample) in click_frames.iter().enumerate() {
        let quantised = to_i16(*sample);
        click[frame * LOOPBACK_CHANNELS as usize] = quantised;
        click[frame * LOOPBACK_CHANNELS as usize + 1] = quantised;
    }

    // Buffer the click while playback is still stopped, then start playback:
    // the two streams are not linked, which is exactly why the result carries
    // a one-period uncertainty. A short write may have auto-started playback
    // already, so only start a stream that is still prepared.
    let mut written = 0usize;
    while written < click.len() {
        let got = playback_io
            .writei(&click[written..])
            .map_err(|error| fail(format!("{device}: playback: {error}")))?;
        if got == 0 {
            return Err(fail(format!("{device}: playback wrote nothing")));
        }
        written += got * LOOPBACK_CHANNELS as usize;
    }
    if playback.pcm.state() != State::Running {
        let state = playback.pcm.state();
        playback
            .pcm
            .start()
            .map_err(|error| fail(format!("{device}: start playback in state {state:?}: {error}")))?;
    }

    let limit = capture.rate as usize * loopback::CAPTURE_SECONDS as usize;
    let mut position = read_frames;
    let mut peak_seen = 0.0f32;
    while position < limit {
        let want = (limit - position).min(capture.period.max(1));
        let got = capture_io
            .readi(&mut chunk[..want * LOOPBACK_CHANNELS as usize])
            .map_err(|error| fail(format!("{device}: capture: {error}")))?;
        if got == 0 {
            continue;
        }
        for (offset, frame) in chunk[..got * LOOPBACK_CHANNELS as usize]
            .chunks(LOOPBACK_CHANNELS as usize)
            .enumerate()
        {
            let level = frame
                .iter()
                .fold(0.0f32, |loudest, sample| {
                    loudest.max(sample.unsigned_abs() as f32 / 32768.0)
                });
            peak_seen = peak_seen.max(level);
            if level >= threshold {
                let _ = playback.pcm.drop();
                let _ = capture.pcm.drop();
                let elapsed = (position + offset) as u64;
                return Ok(Measurement {
                    samples: elapsed.saturating_sub(origin),
                    rate: capture.rate,
                    precision,
                });
            }
        }
        position += got;
    }

    let _ = playback.pcm.drop();
    let _ = capture.pcm.drop();
    Err(fail(format!(
        "no signal above the noise floor (threshold {threshold:.3}, loudest {peak_seen:.3}) within {} s (is the output patched into the input?)",
        loopback::CAPTURE_SECONDS
    )))
}
