//! The peer's sending half of P4: a take, clocked to a master.
//!
//! A take is a WAV recorded on this machine. D14 says the peer owns it and the
//! master places it, so this module reads the take as one mono timeline, probes
//! the master's clock over the same authenticated UDP session the P3 bearer
//! uses, and streams the samples with `master_sample` set to where each
//! datagram belongs (docs/studio-audio-roadmap.md P3/P4). The master never has
//! to guess from arrival time.
//!
//! The loop is the clock peer's loop plus audio: one `CLOCK_PING` and its pong
//! per 10 ms, the fitted [`ClockOffset`] fed to a [`LinearResampler`], and the
//! frames the local clock advanced handed to an [`AudioBearer`]. Nothing here
//! opens a device: the take is already on disk, which is the whole point of a
//! take.
//!
//! # Stamping
//!
//! `local` is the take's sample position. A block that spans
//! `[local, local + elapsed)` is stamped at `offset.to_master(local)` and its
//! end is `offset.to_master(local + elapsed)`, so consecutive blocks meet on
//! the master timeline even though the fitted offset moves between loops.
//! Before the estimator has a trusted fit, the take is stamped with the
//! least-delayed pong's one-point offset; only a run with no accepted pong at
//! all falls back to the local position.
//!
//! # Refusals
//!
//! A missing file, a take whose rate is not `--rate`, an empty take and a
//! missing key are usage errors ([`validate_send`]); the take's rate is never
//! silently converted. A wrong key simply never gets a WELCOME, so the run
//! ends with a failure report and sends no audio. No key is ever printed.

use std::io::ErrorKind;
use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

use crate::bearing::{
    audio_stream, AudioBearer, BearerError, LinearResampler, AUDIO_STREAM_BASE, AUDIO_STREAM_LAST,
};
use crate::loopback::json_escape;
use crate::peer::{
    self, Clock, ClockEstimator, ClockPeer, InstantClock, ProbeSample, CLOCK_SESSION, HANDSHAKE_TIMEOUT,
    PING_INTERVAL_MS,
};
use crate::session::ClockOffset;
use crate::uplink::PULL_MAX_FRAMES;
use crate::wav::to_i16;
use crate::wav_read::read_wav;

/// What the CLI collects for `--send-take`, before anything is opened.
///
/// How old a ping whose pong arrives may be and still be measured. A reply
/// that outlives one 10 ms cycle is normal on Wi-Fi; one older than a second
/// is not the reply the sender is waiting on.
const PONG_MAX_AGE_MS: u64 = 1_000;
///
/// `seconds` is `None` when `--seconds` was not given: the take's own length
/// is then the run length, and the run ends the moment the take is exhausted.
#[derive(Clone, Debug)]
pub struct SendSpec {
    pub take_path: String,
    pub master: Option<String>,
    pub key_hex: Option<String>,
    /// The master source index; the wire stream is `AUDIO_STREAM_BASE + index`.
    pub stream: usize,
    pub rate: u32,
    pub seconds: Option<f64>,
    pub pong_timeout_ms: u64,
    pub window: usize,
}

/// A [`SendSpec`] that has been read and checked.
///
/// `take` is mono at `rate`; the key has no `Debug`, so it cannot reach a log
/// line through a derived formatter.
#[derive(Clone)]
pub struct ValidatedSend {
    pub take: Vec<i16>,
    pub master: SocketAddr,
    pub key: [u8; 32],
    pub stream: u16,
    pub rate: u32,
    pub seconds: f64,
    pub seconds_given: bool,
    pub pong_timeout_ms: u64,
    pub window: usize,
}

/// Everything about a validated send except the key. A derived `Debug` would
/// hand the 32 bytes to any caller that formats the value, which is exactly
/// what this module promises never to do.
impl std::fmt::Debug for ValidatedSend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ValidatedSend")
            .field("take_samples", &self.take.len())
            .field("master", &self.master)
            .field("stream", &self.stream)
            .field("rate", &self.rate)
            .field("seconds", &self.seconds)
            .field("seconds_given", &self.seconds_given)
            .field("pong_timeout_ms", &self.pong_timeout_ms)
            .field("window", &self.window)
            .finish()
    }
}

/// Probes the fit needs before its drift is trusted: one second at the 10 ms
/// probe interval.
pub const FIT_MIN_PROBES: u64 = 100;

/// The smallest estimator span a take's converter trusts: one minute of probes,
/// so a fitted drift is a long-baseline measurement rather than a noisy rate
/// over a short take. Under it the sender keeps the one-point offset, drift 0.
pub const SENDER_FIT_MIN_SPAN_SECONDS: u64 = 60;

/// The smallest estimator window a take's converter keeps: 60 s of probes, so
/// the fitted drift is a long-baseline measurement rather than a noisy rate.
pub const SENDER_FIT_WINDOW: usize = 6_000;

/// How long the least-delayed exchange keeps stamping the take. A clock step
/// after a clean sample must not be hidden for longer than this; within it, the
/// sample's offset is a better estimate than any noisier, newer pong.
pub const PROVISIONAL_MAX_AGE_SECONDS: u64 = 5;

/// Whether the estimator has enough probes over a long enough baseline for its
/// slope to drive the converter. A probe count alone is not enough: 100 probes
/// at the 10 ms interval span one second, and a slope fitted to that burst can
/// report thousands of ppm on a three-second take.
fn drift_is_trusted(estimator: &ClockEstimator, rate: u32) -> bool {
    estimator.kept() >= FIT_MIN_PROBES
        && estimator.span_samples()
            >= u64::from(rate).saturating_mul(SENDER_FIT_MIN_SPAN_SECONDS)
}

/// Read and check a send request.
///
/// Everything that makes a run impossible *before* a socket opens lives here,
/// so the CLI can turn it into exit 2 and a direct caller cannot skip it:
/// the master address, the key, the stream range, the rate, the file, its
/// rate, and whether it holds any samples.
pub fn validate_send(spec: &SendSpec) -> Result<ValidatedSend, String> {
    let master_text = spec.master.as_deref().ok_or_else(|| {
        "--send-take needs --master IP:PORT: the master to send to".to_string()
    })?;
    let master: SocketAddr = master_text
        .parse()
        .map_err(|_| format!("--master wants ip:port, not `{master_text}`"))?;

    let key_text = spec.key_hex.as_deref().ok_or_else(|| {
        "a send session needs a key: pass --session-key-hex HEX64 \
         or set $JAWNOS_AUDIO_SESSION_KEY"
            .to_string()
    })?;
    let key = peer::parse_session_key(key_text).map_err(|error| format!("--session-key-hex: {error}"))?;

    let stream = audio_stream(spec.stream).ok_or_else(|| {
        format!(
            "--stream {} is outside the audio range (0..={})",
            spec.stream,
            AUDIO_STREAM_LAST - AUDIO_STREAM_BASE
        )
    })?;

    if spec.rate == 0 {
        return Err("--rate wants a positive sample rate".to_string());
    }
    if spec.pong_timeout_ms == 0 {
        return Err("--pong-timeout-ms wants a positive number of milliseconds".to_string());
    }
    if spec.window == 0 {
        return Err("--window wants at least one probe".to_string());
    }

    let audio = read_wav(&spec.take_path).map_err(|error| error.to_string())?;
    if audio.rate != spec.rate {
        return Err(format!(
            "{} is {} Hz, but --rate is {} Hz: a take is not resampled to another rate",
            spec.take_path, audio.rate, spec.rate
        ));
    }
    if audio.frames == 0 || audio.samples.is_empty() {
        return Err(format!(
            "{} is empty: there are no samples to send",
            spec.take_path
        ));
    }

    let take: Vec<i16> = audio.mono().iter().map(|sample| to_i16(*sample)).collect();
    if take.is_empty() {
        return Err(format!(
            "{} is empty: there are no samples to send",
            spec.take_path
        ));
    }

    let seconds = match spec.seconds {
        Some(seconds) => {
            if !(seconds.is_finite() && seconds > 0.0) {
                return Err("--seconds wants a positive, finite duration".to_string());
            }
            seconds
        }
        None => take.len() as f64 / spec.rate as f64,
    };

    Ok(ValidatedSend {
        take,
        master,
        key,
        stream,
        rate: spec.rate,
        seconds,
        seconds_given: spec.seconds.is_some(),
        pong_timeout_ms: spec.pong_timeout_ms,
        window: spec.window,
    })
}

/// One block ready for the bearer: where it starts and the master-time samples.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TakeBlock {
    pub master_sample: u64,
    pub frames: Vec<i16>,
}

/// The take's position and the converter that maps it to the master.
///
/// The struct holds no socket and no clock, so the pacing and stamping rules
/// are testable without a network: call [`TakeSender::block`] with the frames
/// one wake elapsed and inspect the stamp and the samples.
pub struct TakeSender {
    take: Vec<i16>,
    local: u64,
    estimate: Option<ClockOffset>,
}

impl TakeSender {
    /// A sender that starts at the take's first sample.
    pub fn new(take: Vec<i16>) -> Self {
        TakeSender {
            take,
            local: 0,
            estimate: None,
        }
    }

    /// The take's next local sample position.
    pub fn local(&self) -> u64 {
        self.local
    }

    /// The clock estimate the next block will use.
    pub fn estimate(&self) -> Option<ClockOffset> {
        self.estimate
    }

    /// Adopt the probe's latest fit. `None` means the prefix is passed through
    /// with the local position as the stamp.
    pub fn set_estimate(&mut self, estimate: Option<ClockOffset>) {
        self.estimate = estimate;
    }

    /// How many take samples have not been sent yet.
    pub fn remaining(&self) -> usize {
        self.take.len().saturating_sub(self.local as usize)
    }

    /// True once every take sample has been handed to the bearer.
    pub fn exhausted(&self) -> bool {
        self.local >= self.take.len() as u64
    }

    /// Take the next `elapsed` frames and place them on the master timeline.
    ///
    /// `elapsed` is what the local clock advanced since the last call, capped by
    /// the caller at one burst; the block holds exactly that many take frames
    /// (or the take's remainder). With an estimate, the block's end is
    /// `offset.to_master(local + elapsed)`, so the resampler's drift decides how
    /// many master samples that span holds; without one, the samples pass
    /// through unchanged and the local position is the master position.
    pub fn block(&mut self, elapsed: usize) -> Option<TakeBlock> {
        let remaining = self.remaining();
        if remaining == 0 || elapsed == 0 {
            return None;
        }
        let count = elapsed.min(remaining);
        let start = self.local as usize;
        let end = start + count;

        let (master_sample, frames) = match self.estimate {
            None => (self.local, self.take[start..end].to_vec()),
            Some(offset) => {
                let master_start = offset.to_master(self.local).max(0) as u64;
                let master_end = offset.to_master(end as u64).max(0) as u64;
                let wanted = master_end.saturating_sub(master_start) as usize;
                if wanted == 0 {
                    (master_start, Vec::new())
                } else {
                    // A fresh converter per block, anchored at the block's
                    // local start: its first output is exactly the block's
                    // stamp, and the block's end becomes the next block's
                    // start. One extra input sample on each side is the linear
                    // interpolation's right edge.
                    let mut resampler = LinearResampler::with_capacity(offset, count + 4);
                    resampler.reset_to(self.local);
                    let look_end = (end + 2).min(self.take.len());
                    // `count + 4` covers the lookahead, so this cannot fail.
                    let _ = resampler.push(&self.take[start..look_end]);
                    let mut out = vec![0i16; wanted];
                    let written = resampler.process(&mut out);
                    if written < wanted {
                        // The remainder of the take has no right edge to
                        // interpolate against. Holding the last sample keeps
                        // the master span intact for the few frames affected.
                        let last = if written > 0 { out[written - 1] } else { 0 };
                        for slot in &mut out[written..] {
                            *slot = last;
                        }
                    }
                    (master_start, out)
                }
            }
        };

        self.local = end as u64;
        Some(TakeBlock {
            master_sample,
            frames,
        })
    }
}

/// One pong's one-point offset, with the round trip that produced it.
#[derive(Clone, Copy, Debug, PartialEq)]
struct ProbePoint {
    offset: ClockOffset,
    rtt_samples: u64,
    at: u64,
}

/// The one-point offset the take uses until a fitted drift is trusted.
///
/// The newest pong's midpoint is not the best estimate of the clock offset: on
/// Wi-Fi its round trip swings by tens of milliseconds, and a take stamped from
/// each fresh swing moves back and forth until the master refuses the overlap
/// as already read. The least-delayed exchange carries the least path noise, so
/// it is the one that stamps the take. A cleaner sample replaces it, and when
/// it is older than [`PROVISIONAL_MAX_AGE_SECONDS`] the newest sample takes
/// over, so a clock step cannot hide behind an old measurement.
#[derive(Clone, Debug)]
struct ProvisionalOffset {
    rate: u32,
    best: Option<ProbePoint>,
    latest: Option<ProbePoint>,
}

impl ProvisionalOffset {
    fn new(rate: u32) -> Self {
        Self {
            rate,
            best: None,
            latest: None,
        }
    }

    /// The oldest a clean exchange may be and still count.
    fn max_age(&self) -> u64 {
        u64::from(self.rate).saturating_mul(PROVISIONAL_MAX_AGE_SECONDS)
    }

    /// Offer a completed exchange. Its local receive position is the moment the
    /// offset is measured at.
    fn offer(&mut self, sample: &ProbeSample) {
        let point = ProbePoint {
            offset: ClockOffset::new(
                (sample.master_midpoint() - sample.local_midpoint()).round() as i64,
                0.0,
            ),
            rtt_samples: sample.rtt_samples,
            at: sample.local_recv,
        };
        // An expired sample must not keep winning: a path whose floor rose
        // would otherwise never be measured again. Expiry is judged at the new
        // sample's instant, so the comparison is against `point.at`, not a
        // caller's later `now`.
        let expired = self
            .best
            .map_or(true, |best| point.at.saturating_sub(best.at) > self.max_age());
        if expired || point.rtt_samples < self.best.map_or(u64::MAX, |best| best.rtt_samples) {
            self.best = Some(point);
        }
        self.latest = Some(point);
    }

    /// The offset to stamp with at local position `now`.
    fn current(&self, now: u64) -> Option<ClockOffset> {
        match self.best {
            Some(best) if now.saturating_sub(best.at) <= self.max_age() => Some(best.offset),
            _ => self.latest.map(|latest| latest.offset),
        }
    }
}

/// One `--send-take` result, in the one-line JSON shape the CLI promises.
#[derive(Clone, Debug)]
pub struct SenderReport {
    pub ok: bool,
    pub master: String,
    pub session: u32,
    pub sent: u64,
    pub frames: u64,
    pub handshakes: u64,
    pub estimate: Option<ClockOffset>,
    pub error: String,
}

impl SenderReport {
    /// A run that reached its end (the take finished, `--seconds` elapsed, or
    /// the master stopped answering).
    pub fn success(
        master: impl Into<String>,
        session: u32,
        sent: u64,
        frames: u64,
        handshakes: u64,
        estimate: Option<ClockOffset>,
    ) -> Self {
        SenderReport {
            ok: true,
            master: master.into(),
            session,
            sent,
            frames,
            handshakes,
            estimate,
            error: String::new(),
        }
    }

    /// A run that could not start, or could not get a session.
    pub fn failure(master: impl Into<String>, error: impl Into<String>) -> Self {
        SenderReport {
            ok: false,
            master: master.into(),
            session: 0,
            sent: 0,
            frames: 0,
            handshakes: 0,
            estimate: None,
            error: error.into(),
        }
    }

    pub fn to_json(&self) -> String {
        if !self.ok {
            return format!(
                "{{\"ok\":false,\"role\":\"sender\",\"master\":\"{}\",\"error\":\"{}\"}}",
                json_escape(&self.master),
                json_escape(&self.error)
            );
        }
        let (offset, drift) = match self.estimate {
            Some(estimate) => (
                estimate.sample_offset.to_string(),
                format!("{:.6}", estimate.drift_ppm),
            ),
            None => ("null".to_string(), "null".to_string()),
        };
        format!(
            "{{\"ok\":true,\"role\":\"sender\",\"master\":\"{}\",\"session\":{},\"sent\":{},\"frames\":{},\"handshakes\":{},\"offset_samples\":{},\"drift_ppm\":{}}}",
            json_escape(&self.master),
            self.session,
            self.sent,
            self.frames,
            self.handshakes,
            offset,
            drift
        )
    }

    pub fn prose(&self) -> String {
        if !self.ok {
            return format!("send-take {}: failed: {}", self.master, self.error);
        }
        format!(
            "send-take to {}: {} datagrams, {} frames, {} handshakes",
            self.master, self.sent, self.frames, self.handshakes
        )
    }
}

/// Send a validated take to its master. Never panics and never hangs on a
/// vanished master: a failed handshake or a master that stops answering leaves
/// a report with the counts reached so far.
pub fn run_send_take(config: &ValidatedSend) -> SenderReport {
    match send_take(config) {
        Ok(report) => report,
        Err(error) => SenderReport::failure(config.master.to_string(), error),
    }
}

fn send_take(config: &ValidatedSend) -> Result<SenderReport, String> {
    let master = config.master;
    let local = local_bind(master);
    let socket = UdpSocket::bind(local)
        .map_err(|error| format!("--send-take cannot bind {local}: {error}"))?;
    socket
        .connect(master)
        .map_err(|error| format!("--send-take cannot reach {master}: {error}"))?;
    socket
        .set_read_timeout(Some(Duration::from_millis(config.pong_timeout_ms)))
        .map_err(|error| format!("send-take timeout: {error}"))?;

    let mut probe = ClockPeer::new(config.key);
    // A take is minutes long, so its converter needs a drift that is measured
    // over a baseline worth tens of seconds, not the clock probe's 640 ms. The
    // caller's `--window` still wins when it is larger.
    let mut estimator = ClockEstimator::with_capacity(
        config.window.max(SENDER_FIT_WINDOW),
        config.rate,
    );
    // The first pong is already a one-point offset. The least-squares fit needs
    // `MIN_SAMPLES`, and on a long-lived master its offset is the master's uptime
    // minus this process's, far larger than the receiver's jitter window: using
    // the bare local position for those first blocks and then jumping would make
    // the master reject the stream. The provisional offset keeps the take on the
    // master's timeline from the first datagram, and takes the least-delayed
    // exchange rather than the newest, so Wi-Fi queueing cannot move the stamp;
    // `TakeSender` still has the local fallback when no pong has been accepted.
    let mut provisional = ProvisionalOffset::new(config.rate);
    let mut outgoing = [0u8; 128];
    let mut incoming = [0u8; 2048];

    // No session, no audio. The startup handshake gets its own short budget so
    // a missing or wrongly-keyed master fails promptly instead of consuming a
    // ten-minute take's whole `--seconds`.
    let handshake_budget = Duration::from_secs_f64(config.seconds).min(HANDSHAKE_TIMEOUT);
    let handshake_deadline = Instant::now() + handshake_budget;
    let mut handshakes = 0u64;
    if handshake(
        &socket,
        &mut probe,
        handshake_deadline,
        &mut outgoing,
        &mut incoming,
    )? {
        handshakes += 1;
    } else {
        return Ok(SenderReport::failure(
            master.to_string(),
            "no clock master answered the HELLO handshake",
        ));
    }
    let mut session = probe.session();

    // The clock starts with the audio, not with the handshake: local sample 0
    // is what the take's first frame should occupy on the master.
    let clock = InstantClock::new(config.rate);
    let pong_max_age = u64::from(config.rate).saturating_mul(PONG_MAX_AGE_MS) / 1_000;
    let mut last_now = clock.now();
    let mut sender = TakeSender::new(config.take.clone());
    let mut bearer = AudioBearer::new(config.key, session);
    // An explicit `--seconds` bounds the run. Without one there is no wall-clock
    // stop at all: the take's length is the pacing target, but the last block is
    // stamped after the wake that carries it, and a delayed wake is capped at
    // `PULL_MAX_FRAMES`, so the remainder may need more than one block. The loop
    // ends when the take is exhausted instead.
    let run_deadline = config
        .seconds_given
        .then(|| Instant::now() + Duration::from_secs_f64(config.seconds));
    let interval = Duration::from_millis(PING_INTERVAL_MS);
    let mut sent = 0u64;
    let mut frames = 0u64;

    loop {
        // Without an explicit `--seconds` the take's end is the end. With one,
        // the loop keeps the clock fresh until it elapses, even after the take
        // has no more samples to give.
        if !config.seconds_given && sender.exhausted() {
            break;
        }
        if let Some(deadline) = run_deadline {
            if Instant::now() >= deadline {
                break;
            }
        }
        let cycle = Instant::now();

        if probe.needs_handshake(Instant::now()) {
            probe.reset_session();
            let deadline = run_deadline
                .map(|run| (Instant::now() + HANDSHAKE_TIMEOUT).min(run))
                .unwrap_or_else(|| Instant::now() + HANDSHAKE_TIMEOUT);
            if handshake(&socket, &mut probe, deadline, &mut outgoing, &mut incoming)? {
                handshakes += 1;
                session = probe.session();
                bearer = AudioBearer::new(config.key, session);
            } else {
                // The master stayed quiet through a whole re-handshake. Stop
                // with what was sent rather than looping at a closed port.
                break;
            }
        }

        let local_send = clock.now();
        let length = probe
            .ping(&mut outgoing, local_send, 0)
            .map_err(|error| format!("send-take ping: {error:?}"))?;
        if let Err(error) = socket.send(&outgoing[..length]) {
            if !quiet_io(error.kind()) {
                return Err(format!("send-take send: {error}"));
            }
        }
        // Audio first, then the pong: a lost round trip must not delay the
        // take. The block is stamped from the estimate the previous cycle
        // fitted, so the wait cannot move the timeline.
        let now = clock.now();
        let elapsed = now.saturating_sub(last_now).min(PULL_MAX_FRAMES as u64) as usize;
        if sender.estimate().is_some() {
            last_now = now;
            if let Some(block) = sender.block(elapsed) {
                match bearer.packetize(
                    config.stream,
                    1,
                    &block.frames,
                    block.master_sample,
                    |datagram| socket.send(datagram).map(|_| ()),
                ) {
                    Ok(emitted) => {
                        sent += emitted;
                        frames += block.frames.len() as u64;
                    }
                    Err(BearerError::Io(kind)) if quiet_io(kind) => {}
                    Err(error) => return Err(format!("send-take audio: {error:?}")),
                }
            }
        }
        // No position yet (the first pong below supplies one): sending the take
        // stamped at local zero would land it where the master is not.

        match socket.recv(&mut incoming) {
            Ok(length) => {
                let local_recv = clock.now();
                // `accept_pong_since` checks the tag, session, echo age and replay
                // window before the point reaches the fit. A Wi-Fi reply can
                // outlive the cycle it was sent in; the echoed stamp is the ping
                // its round trip is measured from, not the newest one.
                if let Some(pong) =
                    probe.accept_pong_since(&incoming[..length], local_send, pong_max_age)
                {
                    let sample = ProbeSample::from_pong(pong, pong.echo_local_send, local_recv);
                    estimator.push(sample);
                    // The fit may take a minute; until then the take is stamped
                    // from the least-delayed exchange, not this one.
                    provisional.offer(&sample);
                }
            }
            Err(error) if quiet_io(error.kind()) => {}
            Err(error) => return Err(format!("send-take receive: {error}")),
        }
        // A slope fitted to a handful of noisy round trips can be thousands of
        // ppm out, which stretches the take by percents. Until the fit has a
        // second of probes AND a minute of span, the one-point offset with drift
        // 0 is the better model: 100 probes at 10 ms span one second, and a 3 s
        // take would otherwise report a rate of -400 to -1300 ppm.
        let fitted = if estimator.kept() >= FIT_MIN_PROBES
            && estimator.span_samples()
                >= u64::from(config.rate).saturating_mul(SENDER_FIT_MIN_SPAN_SECONDS)
        {
            estimator.estimate()
        } else {
            None
        };
        sender.set_estimate(fitted.or(provisional.current(clock.now())));

        let spent = cycle.elapsed();
        if spent < interval {
            std::thread::sleep(interval - spent);
        }
    }

    Ok(SenderReport::success(
        master.to_string(),
        session,
        sent,
        frames,
        handshakes,
        // The model the take actually used, not the raw fit: a short take keeps
        // drift 0, and its report must say so.
        sender.estimate(),
    ))
}

/// Run the HELLO/WELCOME exchange until a session is issued or `deadline`
/// passes. The startup handshake and every re-handshake share this.
fn handshake(
    socket: &UdpSocket,
    probe: &mut ClockPeer,
    deadline: Instant,
    outgoing: &mut [u8],
    incoming: &mut [u8],
) -> Result<bool, String> {
    while probe.session() == CLOCK_SESSION && Instant::now() < deadline {
        let length = probe
            .hello(outgoing)
            .map_err(|error| format!("send-take hello: {error:?}"))?;
        if let Err(error) = socket.send(&outgoing[..length]) {
            if !quiet_io(error.kind()) {
                return Err(format!("send-take send: {error}"));
            }
        }
        match socket.recv(incoming) {
            Ok(length) => {
                let _ = probe.accept_welcome(&incoming[..length]);
            }
            Err(error) if quiet_io(error.kind()) => {}
            Err(error) => return Err(format!("send-take receive: {error}")),
        }
    }
    Ok(probe.session() != CLOCK_SESSION)
}

/// The local address family that can reach `master`, mirroring the clock peer.
fn local_bind(master: SocketAddr) -> &'static str {
    if master.is_ipv6() {
        if master.ip().is_loopback() {
            "[::1]:0"
        } else {
            "[::]:0"
        }
    } else if master.ip().is_loopback() {
        "127.0.0.1:0"
    } else {
        "0.0.0.0:0"
    }
}

/// A receive error that means "nothing yet" rather than "this run is broken":
/// a timeout, or the ICMP errors a connected socket sees when the far end's
/// port closes (the master stopped or restarted).
fn quiet_io(kind: ErrorKind) -> bool {
    matches!(
        kind,
        ErrorKind::WouldBlock
            | ErrorKind::TimedOut
            | ErrorKind::ConnectionRefused
            | ErrorKind::ConnectionReset
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe(local: u64) -> ProbeSample {
        ProbeSample {
            local_send: local,
            local_recv: local + 48,
            master_recv: local + 500,
            master_send: local + 548,
            rtt_samples: 48,
        }
    }

    /// An exchange that completed at `local`, with `rtt` samples of round trip
    /// and an implied clock offset of `offset` samples.
    fn exchange(local: u64, rtt: u64, offset: i64) -> ProbeSample {
        let midpoint = local as i64 + (rtt / 2) as i64;
        ProbeSample {
            local_send: local,
            local_recv: local + rtt,
            master_recv: (midpoint + offset) as u64,
            master_send: (midpoint + offset) as u64,
            rtt_samples: rtt,
        }
    }

    #[test]
    fn a_jittery_pong_does_not_move_the_stamp() {
        let mut provisional = ProvisionalOffset::new(48_000);
        provisional.offer(&exchange(0, 12, 500));
        assert_eq!(provisional.current(0), Some(ClockOffset::new(500, 0.0)));

        // Newer exchanges on a loaded path arrive later and their midpoints
        // imply a different offset. None is cleaner than the first, so none may
        // stamp the take: that swing is the overlap the master refused.
        for index in 1..20u64 {
            let at = index * 480;
            provisional.offer(&exchange(at, 12 + 40 * index, 500 + 100 * index as i64));
            assert_eq!(
                provisional.current(at),
                Some(ClockOffset::new(500, 0.0)),
                "the take still uses the least-delayed exchange"
            );
        }

        // A cleaner exchange is a better measurement and does replace it.
        provisional.offer(&exchange(10_000, 8, 480));
        assert_eq!(provisional.current(10_000), Some(ClockOffset::new(480, 0.0)));
    }

    #[test]
    fn a_provisional_offset_falls_back_when_the_clean_sample_goes_stale() {
        let rate = 48_000;
        let max_age = u64::from(rate) * PROVISIONAL_MAX_AGE_SECONDS;
        let mut provisional = ProvisionalOffset::new(rate);
        provisional.offer(&exchange(0, 12, 500));

        // A later, noisier exchange cannot displace the clean one while it is fresh.
        provisional.offer(&exchange(max_age - 60, 60, 700));
        assert_eq!(
            provisional.current(max_age),
            Some(ClockOffset::new(500, 0.0))
        );

        // One sample past the cap the clean exchange is no longer evidence about
        // the clocks today; the newest exchange takes over rather than hiding a
        // clock step behind an old measurement. Age is counted from the clean
        // sample's receive position (`local + rtt`), not its send position.
        let stale = 12 + max_age + 1;
        assert_eq!(
            provisional.current(stale),
            Some(ClockOffset::new(700, 0.0))
        );
        assert_eq!(ProvisionalOffset::new(rate).current(0), None);
    }

    #[test]
    fn a_clean_sample_that_has_expired_does_not_block_the_path_it_measures() {
        let rate = 48_000;
        let max_age = u64::from(rate) * PROVISIONAL_MAX_AGE_SECONDS;
        let mut provisional = ProvisionalOffset::new(rate);

        // The first five seconds have a 12 ms floor; then the path changes and
        // the floor is 60 ms.
        provisional.offer(&exchange(0, 12, 500));
        provisional.offer(&exchange(max_age, 60, 700));

        // The newest exchange on the new path is noisier still. The take must
        // stay on the 60 ms sample: expiry drops the old floor without making
        // "newest wins" the rule again.
        provisional.offer(&exchange(max_age + 480, 70, 800));
        assert_eq!(
            provisional.current(max_age + 550),
            Some(ClockOffset::new(700, 0.0)),
            "the least-delayed exchange on the new path is kept"
        );
    }

    #[test]
    fn a_short_take_does_not_trust_a_fitted_drift() {
        // 100 probes at the 10 ms interval: enough samples, one second of baseline.
        let mut estimator = ClockEstimator::with_capacity(256, 48_000);
        for index in 0..FIT_MIN_PROBES {
            estimator.push(probe(index * 480));
        }
        assert_eq!(estimator.kept(), FIT_MIN_PROBES);
        assert!(
            !drift_is_trusted(&estimator, 48_000),
            "one second is not a minute"
        );

        // The same count spread over 99 s is a baseline a slope can be read from.
        let mut estimator = ClockEstimator::with_capacity(256, 48_000);
        for index in 0..FIT_MIN_PROBES {
            estimator.push(probe(index * 48_000));
        }
        assert!(
            drift_is_trusted(&estimator, 48_000),
            "99 s is a long enough baseline"
        );
    }
}
