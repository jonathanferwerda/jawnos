//! JACK playback and loopback, behind `--features jack`.
//!
//! JACK hands capture and playback to the same process callback, so a click
//! written in callback N is read in the same callback graph: that is why the
//! loopback method is `callback` and its uncertainty is one sample rather than
//! a period. The client is opened with `NO_START_SERVER`; the engine never
//! starts or stops a sound server (docs/studio-audio-roadmap.md P1).

use std::f32::consts::TAU;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use jack::{AudioIn, AudioOut, Client, ClientOptions, Control, ProcessScope};

use crate::backends::RunReport;
use crate::loopback::{self, LoopbackReport};

const CLIENT_NAME: &str = "jawn-audio";

/// Play `seconds` of silence or a sine through a JACK output port. JACK owns
/// the rate and period, so the report names what the server gave us.
pub fn run_playback(
    _device: &str,
    _rate: u32,
    _period: usize,
    _buffer: usize,
    seconds: f64,
    tone: Option<f32>,
) -> Result<RunReport, String> {
    let (client, _status) = Client::new(CLIENT_NAME, ClientOptions::NO_START_SERVER)
        .map_err(|error| format!("cannot open a JACK client: {error}"))?;
    let rate = client.sample_rate();
    let frames = client.buffer_size().max(1) as usize;
    let mut output = client
        .register_port("playback", AudioOut::default())
        .map_err(|error| format!("cannot register a JACK playback port: {error}"))?;

    let total = (seconds * rate as f64).round().max(0.0) as u64;
    let step = tone.map(|hz| TAU * hz / rate as f32);
    let written = Arc::new(AtomicU64::new(0));
    let peak_bits = Arc::new(AtomicU32::new(0));
    let written_in = Arc::clone(&written);
    let peak_in = Arc::clone(&peak_bits);

    let mut phase = 0.0f32;
    let process = jack::contrib::ClosureProcessHandler::new(
        move |_client: &Client, scope: &ProcessScope| {
            let out = output.as_mut_slice(scope);
            for sample in out.iter_mut() {
                let done = written_in.fetch_add(1, Ordering::Relaxed) >= total;
                if done {
                    *sample = 0.0;
                    continue;
                }
                let value = if let Some(step) = step {
                    let value = phase.sin();
                    phase = (phase + step) % TAU;
                    value
                } else {
                    0.0
                };
                peak_in.fetch_max(value.abs().to_bits(), Ordering::Relaxed);
                *sample = value;
            }
            if written_in.load(Ordering::Relaxed) >= total {
                Control::Quit
            } else {
                Control::Continue
            }
        },
    );

    let active = client
        .activate_async((), process)
        .map_err(|error| format!("cannot activate the JACK client: {error}"))?;

    // The callback quits itself after `total` frames; bound the wait anyway so
    // a stopped server cannot hang the command.
    let deadline = Instant::now() + Duration::from_secs_f64(seconds.max(0.0) + 2.0);
    while written.load(Ordering::Relaxed) < total && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    let _ = active.deactivate();

    let written_total = written.load(Ordering::Relaxed).min(total);
    Ok(RunReport {
        backend: "jack",
        device: "jack".to_string(),
        rate,
        frames,
        buffer: frames,
        channels: 1,
        blocks: if frames == 0 {
            0
        } else {
            (total as usize + frames - 1) / frames
        },
        samples: written_total as usize,
        peak: f32::from_bits(peak_bits.load(Ordering::Relaxed)),
        xruns: 0,
    })
}

/// One click out of the playback port, one capture of the input port, both in
/// the same callback. The ports must already be patched to the interface; the
/// engine does not rewire a user's JACK graph.
pub fn loopback(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> LoopbackReport {
    match measure() {
        Ok((samples, actual_rate)) => LoopbackReport::success(
            "jack",
            device,
            actual_rate,
            period,
            buffer,
            samples,
            1,
            "callback",
        ),
        Err(reason) => LoopbackReport::failure(
            "jack",
            device,
            rate,
            period,
            buffer,
            1,
            "callback",
            reason,
        ),
    }
}

fn measure() -> Result<(u64, u32), String> {
    let (client, _status) = Client::new(CLIENT_NAME, ClientOptions::NO_START_SERVER)
        .map_err(|error| format!("cannot open a JACK client: {error}"))?;
    let rate = client.sample_rate().max(1);
    let mut output = client
        .register_port("loopback_out", AudioOut::default())
        .map_err(|error| format!("cannot register a JACK playback port: {error}"))?;
    let input = client
        .register_port("loopback_in", AudioIn::default())
        .map_err(|error| format!("cannot register a JACK capture port: {error}"))?;

    let click = loopback::click_frames();
    let click_at = (rate as u64 * loopback::PRE_ROLL_MS as u64 / 1000).max(1);
    let limit = rate as u64 * loopback::CAPTURE_SECONDS as u64;
    let found = Arc::new(AtomicU64::new(u64::MAX));
    let position = Arc::new(AtomicU64::new(0));
    let done = Arc::new(AtomicBool::new(false));
    let found_in = Arc::clone(&found);
    let position_in = Arc::clone(&position);
    let done_in = Arc::clone(&done);

    let mut noise_peak = 0.0f32;
    let process = jack::contrib::ClosureProcessHandler::new(
        move |_client: &Client, scope: &ProcessScope| {
            let out = output.as_mut_slice(scope);
            let captured = input.as_slice(scope);
            let base = position_in.load(Ordering::Relaxed);

            for (index, sample) in out.iter_mut().enumerate() {
                let pos = base + index as u64;
                if pos < click_at {
                    // The pre-roll: no click yet, just learn the room.
                    noise_peak = noise_peak.max(captured[index].abs());
                    *sample = 0.0;
                    continue;
                }
                let threshold = loopback::threshold(noise_peak);
                let offset = (pos - click_at) as usize;
                *sample = if offset < click.len() {
                    click[offset]
                } else {
                    0.0
                };
                if found_in.load(Ordering::Relaxed) == u64::MAX
                    && pos < limit
                    && captured[index].abs() >= threshold
                {
                    let _ = found_in.compare_exchange(
                        u64::MAX,
                        pos,
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    );
                }
            }

            let next = base + out.len() as u64;
            position_in.store(next, Ordering::Relaxed);
            if found_in.load(Ordering::Relaxed) != u64::MAX || next >= limit {
                done_in.store(true, Ordering::Relaxed);
                Control::Quit
            } else {
                Control::Continue
            }
        },
    );

    let active = client
        .activate_async((), process)
        .map_err(|error| format!("cannot activate the JACK client: {error}"))?;
    let deadline = Instant::now() + Duration::from_secs(loopback::CAPTURE_SECONDS as u64 + 2);
    while !done.load(Ordering::Relaxed) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    let _ = active.deactivate();

    match found.load(Ordering::Relaxed) {
        u64::MAX => Err(format!(
            "no signal above the noise floor within {} s (are the JACK ports patched to the interface?)",
            loopback::CAPTURE_SECONDS
        )),
        samples => Ok((samples, rate)),
    }
}
