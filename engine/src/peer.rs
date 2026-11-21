//! The clock probe peers run before they share a transport.
//!
//! P3's first spike is deliberately only a clock: no audio device, no
//! resampling, no session handshake. Two engines exchange a `CLOCK_PING` and a
//! `CLOCK_PONG` over UDP; each pong carries the master's receive and send times,
//! so the peer can subtract the master's own turnaround from the round trip and
//! place the local and master *midpoints* on the same timeline. A bounded
//! least-squares fit of `master = a + b * local` then yields the offset and the
//! peer clock's drift (docs/studio-audio-roadmap.md §10 and §13 P3).
//!
//! Everything here is off the audio thread. The estimator owns a small
//! `VecDeque`, the CLI owns the `UdpSocket`, and the latest `ClockOffset` is
//! published behind an `Arc<Mutex<…>>`. A render loop should snapshot that value
//! at the top of a callback (or, better, have the probe thread write an atomic
//! pair) and never lock or allocate inside the callback itself.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::loopback::json_escape;
use crate::proto::{self, Codec, Header, ProtoError};
use crate::session::ClockOffset;

/// The header `stream` id for a clock ping. The audio streams use small ids;
/// the high half of the `u16` space is reserved for control traffic so a clock
/// datagram can never be mistaken for an input, bus or zone.
pub const STREAM_CLOCK_PING: u16 = 0xFF00;
/// The header `stream` id for a clock pong. One byte apart from the ping so a
/// trace reads the exchange as a pair.
pub const STREAM_CLOCK_PONG: u16 = 0xFF01;

/// Which session the probe belongs to. The session, MAC and handshake arrive
/// later in P3; this spike uses the reserved "no session yet" value.
pub const CLOCK_SESSION: u32 = 0;

/// A ping's payload: the peer's send time, in device samples.
pub const PING_PAYLOAD_LEN: usize = 8;
/// A pong's payload: the ping's send time echoed back, then the master's
/// receive and send times, each in device samples.
pub const PONG_PAYLOAD_LEN: usize = 24;

/// How often the peer pings, in milliseconds. Ten milliseconds is ten probes
/// per 10 ms audio block at 48 kHz and enough samples for a short fit.
pub const PING_INTERVAL_MS: u64 = 10;
/// How long the peer waits for a pong before giving up on that ping. A lost
/// reply costs one interval, not the probe.
pub const PONG_TIMEOUT_MS: u64 = 5;
/// The master's default bind: loopback only, an ephemeral port. Opening a port
/// another machine can reach is an explicit `--bind`.
pub const DEFAULT_BIND: &str = "127.0.0.1:0";

/// How many probes the estimator keeps. At one ping per 10 ms this is ~640 ms
/// of history: enough to reject jitter without pretending to remember a whole
/// session. The two-machine ten-minute run measures the long-term model.
pub const ESTIMATOR_CAPACITY: usize = 64;
/// A probe whose round trip is more than this much worse than the best one in
/// the window is treated as an outlier. The allowance scales with the best
/// round trip, so a slow LAN is not rejected wholesale.
pub const RTT_SLACK_MS: u64 = 20;
/// Two points define a line, but four keep a single bad timestamp from setting
/// the slope for the whole window.
pub const MIN_SAMPLES: usize = 4;

/// Why a datagram is not a usable clock message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProbeError {
    /// The 32-byte header itself is malformed.
    Proto(ProtoError),
    /// A well-formed header, but its `stream` is not a clock stream.
    NotClock(u16),
    /// The header is a clock stream but the payload is shorter than the role.
    ShortPayload,
}

impl From<ProtoError> for ProbeError {
    fn from(error: ProtoError) -> Self {
        ProbeError::Proto(error)
    }
}

/// A source of device-sample timestamps.
///
/// The real clock counts elapsed `Instant` time at the session's rate. Tests
/// inject a manual or skewed clock, so the estimator is exercised without
/// sleeping for ten minutes.
pub trait Clock: Send + Sync {
    /// The current device sample position. Monotonic for the life of a probe.
    fn now(&self) -> u64;
}

/// The production clock: `Instant` elapsed since construction, at `rate`.
#[derive(Clone, Debug)]
pub struct InstantClock {
    start: Instant,
    rate: f64,
}

impl InstantClock {
    /// A clock at exactly `rate` samples per second.
    pub fn new(rate: u32) -> Self {
        Self::with_ppm(rate, 0.0)
    }

    /// A clock whose rate is deliberately off by `ppm` parts per million.
    /// `ppm` is positive when the counter runs fast. Used by tests and by a
    /// manual two-machine run that wants to simulate a skewed peer.
    pub fn with_ppm(rate: u32, ppm: f64) -> Self {
        InstantClock {
            start: Instant::now(),
            rate: rate as f64 * (1.0 + ppm / 1_000_000.0),
        }
    }

    /// The rate this clock is counting at, after any injected skew.
    pub fn rate(&self) -> f64 {
        self.rate
    }
}

impl Clock for InstantClock {
    fn now(&self) -> u64 {
        let nanos = self.start.elapsed().as_nanos() as f64;
        (nanos * self.rate / 1_000_000_000.0).round() as u64
    }
}

/// A clock the test advances by hand: `set` for the wall time, `advance` for a
/// step. Clones share the same counter, so one thread can be the master and
/// another the peer in a deterministic test.
#[derive(Clone, Debug, Default)]
pub struct ManualClock {
    now: Arc<AtomicU64>,
}

impl ManualClock {
    /// Start at `samples`.
    pub fn new(samples: u64) -> Self {
        ManualClock {
            now: Arc::new(AtomicU64::new(samples)),
        }
    }

    /// Put the counter at `samples`.
    pub fn set(&self, samples: u64) {
        self.now.store(samples, Ordering::SeqCst);
    }

    /// Move the counter forward, returning the new value.
    pub fn advance(&self, samples: u64) -> u64 {
        self.now.fetch_add(samples, Ordering::SeqCst) + samples
    }
}

impl Clock for ManualClock {
    fn now(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }
}

/// Another clock seen through a rate error: `local = origin + (inner - origin)
/// * (1 + ppm/1e6)`. Positive `ppm` means this view runs fast.
#[derive(Clone, Debug)]
pub struct SkewedClock<C: Clock> {
    inner: C,
    origin: u64,
    ppm: f64,
}

impl<C: Clock> SkewedClock<C> {
    /// Read `inner` now to fix the origin, then scale every later reading.
    pub fn new(inner: C, ppm: f64) -> Self {
        let origin = inner.now();
        SkewedClock {
            inner,
            origin,
            ppm,
        }
    }

    /// The rate error this view adds, in parts per million.
    pub fn ppm(&self) -> f64 {
        self.ppm
    }
}

impl<C: Clock> Clock for SkewedClock<C> {
    fn now(&self) -> u64 {
        let elapsed = self.inner.now().saturating_sub(self.origin) as f64;
        self.origin + (elapsed * (1.0 + self.ppm / 1_000_000.0)).round() as u64
    }
}

/// The three timestamps a pong carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pong {
    /// The ping's send time, echoed so a late or duplicate reply is ignored
    /// without keeping an outstanding-request table.
    pub echo_local_send: u64,
    /// When the master's clock read the ping.
    pub master_recv: u64,
    /// When the master's clock read the pong it sent back.
    pub master_send: u64,
}

/// One completed exchange, as the estimator sees it.
///
/// The two midpoints are the estimate's inputs. The round trip has the master's
/// turnaround removed, so a slow master does not look like a slow network.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProbeSample {
    pub local_send: u64,
    pub local_recv: u64,
    pub master_recv: u64,
    pub master_send: u64,
    /// `(local_recv - local_send) - (master_send - master_recv)`, in samples.
    pub rtt_samples: u64,
}

impl ProbeSample {
    /// Build a sample from a decoded pong and the local receive time.
    ///
    /// The turnaround is in master samples while the round trip is in local
    /// samples. At a few hundred ppm over a few milliseconds the units differ
    /// by far less than a sample, so subtracting them is honest at this scale.
    pub fn from_pong(pong: Pong, local_send: u64, local_recv: u64) -> Self {
        let round_trip = local_recv.saturating_sub(local_send);
        let turnaround = pong.master_send.saturating_sub(pong.master_recv);
        ProbeSample {
            local_send,
            local_recv,
            master_recv: pong.master_recv,
            master_send: pong.master_send,
            rtt_samples: round_trip.saturating_sub(turnaround),
        }
    }

    /// The local clock at the middle of the exchange.
    pub fn local_midpoint(&self) -> f64 {
        (self.local_send as f64 + self.local_recv as f64) / 2.0
    }

    /// The master clock at the middle of the exchange.
    pub fn master_midpoint(&self) -> f64 {
        (self.master_recv as f64 + self.master_send as f64) / 2.0
    }
}

/// Encode a `CLOCK_PING`. `master_sample` is the master's transport position
/// (0 for now); the peer leaves it zero. The header's codec byte is `Pcm16`
/// only because every header carries one: a clock payload has no samples.
pub fn encode_ping(
    out: &mut [u8],
    seq: u32,
    local_send: u64,
    master_sample: u64,
) -> Result<usize, ProtoError> {
    let header = Header {
        codec: Codec::Pcm16,
        flags: 0,
        session: CLOCK_SESSION,
        stream: STREAM_CLOCK_PING,
        channels: 0,
        seq,
        master_sample,
    };
    proto::encode_datagram(out, &header, &local_send.to_le_bytes())
}

/// Decode a `CLOCK_PING`, returning its header and the peer's send time.
pub fn decode_ping(datagram: &[u8]) -> Result<(Header, u64), ProbeError> {
    let (header, offset) = proto::decode(datagram)?;
    if header.stream != STREAM_CLOCK_PING {
        return Err(ProbeError::NotClock(header.stream));
    }
    let end = offset + PING_PAYLOAD_LEN;
    if datagram.len() < end {
        return Err(ProbeError::ShortPayload);
    }
    let local_send = u64::from_le_bytes(
        datagram[offset..end]
            .try_into()
            .expect("a slice of PING_PAYLOAD_LEN bytes"),
    );
    Ok((header, local_send))
}

/// Encode a `CLOCK_PONG`. `seq` comes from the ping so the peer can match the
/// reply; `master_sample` is the master's current transport position (the
/// ping's value, zero in this spike). The payload is the echo and the master's
/// two timestamps.
pub fn encode_pong(
    out: &mut [u8],
    seq: u32,
    pong: Pong,
    master_sample: u64,
) -> Result<usize, ProtoError> {
    let header = Header {
        codec: Codec::Pcm16,
        flags: 0,
        session: CLOCK_SESSION,
        stream: STREAM_CLOCK_PONG,
        channels: 0,
        seq,
        master_sample,
    };
    let mut payload = [0u8; PONG_PAYLOAD_LEN];
    payload[0..8].copy_from_slice(&pong.echo_local_send.to_le_bytes());
    payload[8..16].copy_from_slice(&pong.master_recv.to_le_bytes());
    payload[16..24].copy_from_slice(&pong.master_send.to_le_bytes());
    proto::encode_datagram(out, &header, &payload)
}

/// Decode a `CLOCK_PONG`.
pub fn decode_pong(datagram: &[u8]) -> Result<(Header, Pong), ProbeError> {
    let (header, offset) = proto::decode(datagram)?;
    if header.stream != STREAM_CLOCK_PONG {
        return Err(ProbeError::NotClock(header.stream));
    }
    let end = offset + PONG_PAYLOAD_LEN;
    if datagram.len() < end {
        return Err(ProbeError::ShortPayload);
    }
    let payload = &datagram[offset..end];
    let pong = Pong {
        echo_local_send: u64::from_le_bytes(
            payload[0..8].try_into().expect("a slice of eight bytes"),
        ),
        master_recv: u64::from_le_bytes(
            payload[8..16].try_into().expect("a slice of eight bytes"),
        ),
        master_send: u64::from_le_bytes(
            payload[16..24].try_into().expect("a slice of eight bytes"),
        ),
    };
    Ok((header, pong))
}

/// The master's one-line answer: decode a ping, stamp it, encode a pong.
///
/// `Ok(None)` means the datagram was a clock-shaped message for another stream
/// or a malformed payload, and is simply ignored. A header error is also
/// ignored in the return type so the caller's receive loop stays one match;
/// callers that need the reason can call `decode_ping` themselves.
pub fn answer_ping(
    datagram: &[u8],
    clock: &dyn Clock,
    out: &mut [u8],
) -> Result<Option<usize>, ProbeError> {
    let (header, local_send) = match decode_ping(datagram) {
        Ok(ping) => ping,
        Err(ProbeError::NotClock(_)) | Err(ProbeError::Proto(_)) => return Ok(None),
        Err(ProbeError::ShortPayload) => return Ok(None),
    };
    let master_recv = clock.now();
    let pong = Pong {
        echo_local_send: local_send,
        master_recv,
        master_send: clock.now(),
    };
    // The pong's `master_sample` is where the master's transport stood. This
    // spike has no transport, so the field keeps the ping's zero.
    let length = encode_pong(out, header.seq, pong, header.master_sample)?;
    Ok(Some(length))
}

/// The bounded offset/drift estimator.
///
/// Each accepted probe is a point `(local_midpoint, master_midpoint)`. The
/// least-squares slope is `b` samples of master per local sample; a positive
/// `drift_ppm` is the local clock running fast, matching
/// [`crate::session::ClockOffset`]'s meaning (`to_master` subtracts the drift).
/// Since the fit is `master = a + b * local`, that is `(1 - b) * 1e6`: a fast
/// local clock counts more samples, so `b < 1`.
#[derive(Clone, Debug)]
pub struct ClockEstimator {
    samples: VecDeque<ProbeSample>,
    capacity: usize,
    rtt_slack: u64,
    accepted: u64,
    dropped: u64,
    last_rtt: Option<u64>,
}

impl ClockEstimator {
    /// An estimator sized for `rate`: a 64-sample window and a 20 ms outlier
    /// allowance.
    pub fn new(rate: u32) -> Self {
        Self::with_capacity(ESTIMATOR_CAPACITY, rate)
    }

    /// The same, with a different window length.
    pub fn with_capacity(capacity: usize, rate: u32) -> Self {
        let rtt_slack = (rate as u64).saturating_mul(RTT_SLACK_MS) / 1000;
        ClockEstimator {
            samples: VecDeque::with_capacity(capacity.max(1)),
            capacity: capacity.max(1),
            rtt_slack,
            accepted: 0,
            dropped: 0,
            last_rtt: None,
        }
    }

    /// Offer one completed exchange. Returns true when it was retained.
    ///
    /// The cutoff is `min_rtt + max(min_rtt, slack)`. It scales with the best
    /// sample in the window, so a LAN whose floor is 8 ms keeps 8 ms jitter
    /// while a 200 ms stall is discarded.
    pub fn push(&mut self, sample: ProbeSample) -> bool {
        self.last_rtt = Some(sample.rtt_samples);
        let floor = self
            .samples
            .iter()
            .map(|kept| kept.rtt_samples)
            .min()
            .unwrap_or(sample.rtt_samples);
        let allowance = floor.max(self.rtt_slack);
        if sample.rtt_samples > floor.saturating_add(allowance) {
            self.dropped += 1;
            return false;
        }
        self.samples.push_back(sample);
        while self.samples.len() > self.capacity {
            self.samples.pop_front();
        }
        self.accepted += 1;
        true
    }

    /// The current estimate, or `None` until the window has `MIN_SAMPLES`
    /// points (or all of them share one local time).
    pub fn estimate(&self) -> Option<ClockOffset> {
        if self.samples.len() < MIN_SAMPLES {
            return None;
        }
        let count = self.samples.len() as f64;
        let mut sum_x = 0.0;
        let mut sum_y = 0.0;
        for sample in &self.samples {
            sum_x += sample.local_midpoint();
            sum_y += sample.master_midpoint();
        }
        let mean_x = sum_x / count;
        let mean_y = sum_y / count;
        let mut sxx = 0.0;
        let mut sxy = 0.0;
        for sample in &self.samples {
            let dx = sample.local_midpoint() - mean_x;
            sxx += dx * dx;
            sxy += dx * (sample.master_midpoint() - mean_y);
        }
        if sxx <= 0.0 {
            return None;
        }
        let slope = sxy / sxx;
        let intercept = mean_y - slope * mean_x;
        Some(ClockOffset::new(
            intercept.round() as i64,
            (1.0 - slope) * 1_000_000.0,
        ))
    }

    /// The best round trip in the retained window.
    pub fn min_rtt(&self) -> Option<u64> {
        self.samples.iter().map(|sample| sample.rtt_samples).min()
    }

    /// The most recent round trip offered, including one that was dropped.
    pub fn last_rtt(&self) -> Option<u64> {
        self.last_rtt
    }

    /// Total probes retained (including ones aged out of the window).
    pub fn kept(&self) -> u64 {
        self.accepted
    }

    /// Total probes rejected as high-RTT outliers.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// How many points the current fit sees.
    pub fn window_len(&self) -> usize {
        self.samples.len()
    }
}

/// The latest estimate, off the audio thread.
///
/// The probe thread publishes; a render loop snapshots it once per callback and
/// then works from the copy. Nothing in this spike locks inside an audio
/// callback. When the render loop arrives, the snapshot should become two
/// atomics (`sample_offset` and a scaled integer drift) so the callback does
/// not touch the mutex at all.
pub type SharedEstimate = Arc<Mutex<Option<ClockOffset>>>;

/// An empty slot for the latest estimate.
pub fn new_shared_estimate() -> SharedEstimate {
    Arc::new(Mutex::new(None))
}

/// Write the latest estimate. A poisoned lock still holds a usable `Copy`
/// value, so it is recovered rather than panicking the probe.
pub fn publish_estimate(shared: &SharedEstimate, estimate: ClockOffset) {
    match shared.lock() {
        Ok(mut slot) => *slot = Some(estimate),
        Err(poisoned) => *poisoned.into_inner() = Some(estimate),
    }
}

/// Read the latest estimate.
pub fn latest_estimate(shared: &SharedEstimate) -> Option<ClockOffset> {
    match shared.lock() {
        Ok(slot) => *slot,
        Err(poisoned) => *poisoned.into_inner(),
    }
}

/// One `--clock-master` or `--clock-peer` result, in the exact JSON shape the
/// CLI promises.
#[derive(Clone, Debug)]
pub struct ClockReport {
    pub ok: bool,
    pub role: &'static str,
    /// The address the master bound, or the master the peer probed.
    pub address: String,
    pub rate: u32,
    pub seconds: f64,
    /// Master: pings answered. Peer: pings sent.
    pub sent: u64,
    /// Peer: pongs received.
    pub received: u64,
    pub kept: u64,
    pub dropped: u64,
    pub min_rtt_samples: Option<u64>,
    pub last_rtt_samples: Option<u64>,
    pub estimate: Option<ClockOffset>,
    pub error: String,
}

impl ClockReport {
    /// The master's final line: how many pings it answered.
    pub fn master(address: impl Into<String>, rate: u32, seconds: f64, served: u64) -> Self {
        ClockReport {
            ok: true,
            role: "master",
            address: address.into(),
            rate,
            seconds,
            sent: served,
            received: served,
            kept: 0,
            dropped: 0,
            min_rtt_samples: None,
            last_rtt_samples: None,
            estimate: None,
            error: String::new(),
        }
    }

    /// The peer's final line.
    pub fn peer(
        address: impl Into<String>,
        rate: u32,
        seconds: f64,
        sent: u64,
        received: u64,
        estimator: &ClockEstimator,
        estimate: Option<ClockOffset>,
    ) -> Self {
        ClockReport {
            ok: true,
            role: "peer",
            address: address.into(),
            rate,
            seconds,
            sent,
            received,
            kept: estimator.kept(),
            dropped: estimator.dropped(),
            min_rtt_samples: estimator.min_rtt(),
            last_rtt_samples: estimator.last_rtt(),
            estimate,
            error: String::new(),
        }
    }

    /// A run that could not start or could not continue.
    pub fn failure(role: &'static str, address: impl Into<String>, error: impl Into<String>) -> Self {
        ClockReport {
            ok: false,
            role,
            address: address.into(),
            rate: 0,
            seconds: 0.0,
            sent: 0,
            received: 0,
            kept: 0,
            dropped: 0,
            min_rtt_samples: None,
            last_rtt_samples: None,
            estimate: None,
            error: error.into(),
        }
    }

    /// The address key differs by role: a master reports its bind, a peer the
    /// master it probed.
    fn address_key(&self) -> &'static str {
        if self.role == "master" {
            "bind"
        } else {
            "master"
        }
    }

    pub fn to_json(&self) -> String {
        if !self.ok {
            return format!(
                "{{\"ok\":false,\"role\":\"{}\",\"{}\":\"{}\",\"error\":\"{}\"}}",
                json_escape(self.role),
                self.address_key(),
                json_escape(&self.address),
                json_escape(&self.error)
            );
        }
        if self.role == "master" {
            return format!(
                "{{\"ok\":true,\"role\":\"master\",\"bind\":\"{}\",\"rate\":{},\"seconds\":{},\"served\":{}}}",
                json_escape(&self.address),
                self.rate,
                self.seconds,
                self.sent
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
            "{{\"ok\":true,\"role\":\"peer\",\"master\":\"{}\",\"rate\":{},\"seconds\":{},\"sent\":{},\"received\":{},\"kept\":{},\"dropped\":{},\"min_rtt_samples\":{},\"last_rtt_samples\":{},\"offset_samples\":{},\"drift_ppm\":{}}}",
            json_escape(&self.address),
            self.rate,
            self.seconds,
            self.sent,
            self.received,
            self.kept,
            self.dropped,
            option_u64(self.min_rtt_samples),
            option_u64(self.last_rtt_samples),
            offset,
            drift
        )
    }

    pub fn prose(&self) -> String {
        if !self.ok {
            return format!("clock {} {}: failed: {}", self.role, self.address, self.error);
        }
        if self.role == "master" {
            return format!(
                "clock master on {}: served {} pings in {:.1} s",
                self.address, self.sent, self.seconds
            );
        }
        let estimate = match self.estimate {
            Some(estimate) => format!(
                "offset {} samples, drift {:.2} ppm",
                estimate.sample_offset, estimate.drift_ppm
            ),
            None => "no estimate yet".to_string(),
        };
        format!(
            "clock peer of {}: {}, {} sent, {} received, {} kept, {} dropped, RTT {} samples (min {})",
            self.address,
            estimate,
            self.sent,
            self.received,
            self.kept,
            self.dropped,
            self.last_rtt_samples
                .map(|rtt| rtt.to_string())
                .unwrap_or_else(|| "none".to_string()),
            self.min_rtt_samples
                .map(|rtt| rtt.to_string())
                .unwrap_or_else(|| "none".to_string())
        )
    }
}

fn option_u64(value: Option<u64>) -> String {
    match value {
        Some(number) => number.to_string(),
        None => "null".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::UdpSocket;
    use std::thread;
    use std::time::Duration;

    const RATE: u32 = 48_000;

    /// One exchange on a perfect line: `delay` each way and `delay` of master
    /// turnaround, so the two midpoints agree. `jitter` shifts the master's two
    /// stamps without changing the round trip, which is exactly the midpoint
    /// noise the estimator has to reject.
    fn sample_at(t: u64, delay: u64, master_base: u64, ppm: f64, jitter: i64) -> ProbeSample {
        let scale = 1.0 + ppm / 1_000_000.0;
        let local_send = (t as f64 * scale).round() as u64;
        let master_recv = (master_base as i64 + t as i64 + delay as i64 + jitter) as u64;
        let pong = Pong {
            echo_local_send: local_send,
            master_recv,
            master_send: master_recv + delay,
        };
        let local_recv = ((t + 3 * delay) as f64 * scale).round() as u64;
        ProbeSample::from_pong(pong, local_send, local_recv)
    }

    /// Deterministic jitter: splitmix64, so the sequence is independent of the
    /// sample index rather than an LCG's low-bit pattern.
    fn noise(seed: &mut u64) -> i64 {
        *seed = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = *seed;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z % 241) as i64 - 120
    }

    #[test]
    fn a_clock_ping_round_trips_the_header_and_its_send_time() {
        let mut datagram = [0u8; 64];
        let length = encode_ping(&mut datagram, 7, 123_456, 0).expect("encode ping");
        let (header, local_send) = decode_ping(&datagram[..length]).expect("decode ping");
        assert_eq!(header.stream, STREAM_CLOCK_PING);
        assert_eq!(header.seq, 7);
        assert_eq!(header.codec, Codec::Pcm16);
        assert_eq!(local_send, 123_456);
    }

    #[test]
    fn a_clock_pong_round_trips_the_echo_and_both_master_times() {
        let pong = Pong {
            echo_local_send: 111,
            master_recv: 222,
            master_send: 333,
        };
        let mut datagram = [0u8; 64];
        let length = encode_pong(&mut datagram, 9, pong, 0).expect("encode pong");
        let (header, back) = decode_pong(&datagram[..length]).expect("decode pong");
        assert_eq!(header.stream, STREAM_CLOCK_PONG);
        assert_eq!(header.seq, 9);
        assert_eq!(back, pong);
    }

    #[test]
    fn a_clock_stream_with_a_short_payload_is_rejected() {
        let mut datagram = [0u8; 64];
        let length = encode_ping(&mut datagram, 1, 42, 0).expect("encode ping");
        assert_eq!(
            decode_ping(&datagram[..length - 1]),
            Err(ProbeError::ShortPayload)
        );
        assert_eq!(decode_pong(&datagram[..length]), Err(ProbeError::NotClock(STREAM_CLOCK_PING)));
    }

    #[test]
    fn the_master_answers_a_ping_and_ignores_anything_else() {
        let clock = ManualClock::new(10_000);
        let mut ping = [0u8; 64];
        let length = encode_ping(&mut ping, 3, 5_000, 0).expect("encode ping");
        let mut reply = [0u8; 64];
        let answered = answer_ping(&ping[..length], &clock, &mut reply)
            .expect("answer")
            .expect("a pong");
        let (header, pong) = decode_pong(&reply[..answered]).expect("decode pong");
        assert_eq!(header.seq, 3);
        assert_eq!(pong.echo_local_send, 5_000);
        assert_eq!(pong.master_recv, 10_000);

        let mut audio = [0u8; 64];
        let audio_length = proto::encode_datagram(
            &mut audio,
            &Header {
                codec: Codec::Pcm16,
                flags: 0,
                session: 0,
                stream: 7,
                channels: 1,
                seq: 0,
                master_sample: 0,
            },
            &[0u8; 4],
        )
        .expect("encode audio");
        assert_eq!(
            answer_ping(&audio[..audio_length], &clock, &mut reply),
            Ok(None)
        );
    }

    #[test]
    fn an_estimator_needs_a_few_points_before_it_speaks() {
        let mut estimator = ClockEstimator::new(RATE);
        assert_eq!(estimator.estimate(), None);
        for index in 0..(MIN_SAMPLES - 1) {
            estimator.push(sample_at(index as u64 * 480, 48, 1_000_000, 0.0, 0));
            assert_eq!(estimator.estimate(), None);
        }
        estimator.push(sample_at(MIN_SAMPLES as u64 * 480, 48, 1_000_000, 0.0, 0));
        assert!(estimator.estimate().is_some());
    }

    #[test]
    fn the_estimator_recovers_a_linear_clock_with_jitter() {
        let offset = 1_000_000i64;
        let ppm = 250.0;
        // A window long enough to hold all 200 points: this test is the
        // least-squares math, not the default 64-point rolling window.
        let mut estimator = ClockEstimator::with_capacity(256, RATE);
        let mut seed = 0x0BAD_F00D_1234_5678u64;
        for index in 0..200u64 {
            let t = index * 4_800; // 200 points over 20 s
            let sample = sample_at(t, 96, offset as u64, ppm, noise(&mut seed) / 10);
            estimator.push(sample);
        }
        let estimate = estimator.estimate().expect("an estimate");
        assert!(
            (estimate.drift_ppm - ppm).abs() < 5.0,
            "drift {} wanted {ppm}",
            estimate.drift_ppm
        );
        assert!(
            (estimate.sample_offset - offset).abs() < 500,
            "offset {} wanted {offset}",
            estimate.sample_offset
        );
        assert_eq!(estimator.dropped(), 0);
    }

    #[test]
    fn high_round_trip_outliers_are_dropped_not_fitted() {
        let mut estimator = ClockEstimator::with_capacity(256, RATE);
        let mut seed = 0x5EED_0000_0000_0001u64;
        for index in 0..200u64 {
            estimator.push(sample_at(
                index * 4_800,
                96,
                1_000_000,
                100.0,
                noise(&mut seed) / 10,
            ));
        }
        let before = estimator.estimate().expect("an estimate");
        for index in 200..210u64 {
            // A 300 ms one-way stall: a high-RTT and a badly biased midpoint.
            let sample = sample_at(index * 4_800, 96 + 14_400, 1_000_000, 100.0, 60);
            assert!(!estimator.push(sample), "outlier {index} should be dropped");
        }
        let after = estimator.estimate().expect("an estimate");
        assert_eq!(estimator.dropped(), 10);
        assert!(
            (after.drift_ppm - 100.0).abs() < 5.0,
            "drift {} after outliers",
            after.drift_ppm
        );
        assert!((after.drift_ppm - before.drift_ppm).abs() < 0.5);
    }

    #[test]
    fn a_skewed_peer_clock_is_recovered_within_a_few_ppm() {
        let master_clock = ManualClock::new(1_000_000);
        let local_base = ManualClock::new(0);
        let peer_clock = SkewedClock::new(local_base.clone(), 100.0);
        let mut estimator = ClockEstimator::new(RATE);

        // Twenty probes over twenty seconds of virtual time, with a 1 ms
        // each-way delay. No sleeping: the clocks are set by the test.
        let delay = RATE as u64 / 1000; // 1 ms each way, 1 ms turnaround
        for index in 0..20u64 {
            let elapsed = index * RATE as u64;
            local_base.set(elapsed);
            let local_send = peer_clock.now();

            master_clock.set(1_000_000 + elapsed + delay);
            let master_recv = master_clock.now();
            local_base.set(elapsed + 3 * delay);
            let local_recv = peer_clock.now();
            let pong = Pong {
                echo_local_send: local_send,
                master_recv,
                master_send: master_recv + delay,
            };
            estimator.push(ProbeSample::from_pong(pong, local_send, local_recv));
        }

        let estimate = estimator.estimate().expect("an estimate");
        assert!(
            (estimate.drift_ppm - 100.0).abs() < 3.0,
            "drift {} wanted ~100",
            estimate.drift_ppm
        );
        assert!(
            (estimate.sample_offset - 1_000_000).abs() < 4,
            "offset {} wanted ~1000000",
            estimate.sample_offset
        );
    }

    #[test]
    fn the_shared_estimate_publishes_off_the_audio_thread() {
        let shared = new_shared_estimate();
        assert_eq!(latest_estimate(&shared), None);
        let estimate = ClockOffset::new(123, -4.5);
        publish_estimate(&shared, estimate);
        assert_eq!(latest_estimate(&shared), Some(estimate));
    }

    #[test]
    fn a_udp_loopback_recovers_near_zero_offset_and_drift_and_tolerates_loss() {
        let clock = Arc::new(InstantClock::new(RATE));
        let master = UdpSocket::bind("127.0.0.1:0").expect("bind master");
        master
            .set_read_timeout(Some(Duration::from_millis(50)))
            .expect("master timeout");
        let address = master.local_addr().expect("master address");

        let master_clock = Arc::clone(&clock);
        let handler = thread::spawn(move || {
            let mut incoming = [0u8; 2048];
            let mut reply = [0u8; 2048];
            let mut served = 0u64;
            let deadline = Instant::now() + Duration::from_millis(700);
            while Instant::now() < deadline {
                let (length, origin) = match master.recv_from(&mut incoming) {
                    Ok(pair) => pair,
                    Err(_) => continue,
                };
                // Drop every third ping: the peer must still estimate.
                if let Ok((header, _)) = decode_ping(&incoming[..length]) {
                    if header.seq % 3 == 0 {
                        continue;
                    }
                }
                if let Ok(Some(length)) =
                    answer_ping(&incoming[..length], master_clock.as_ref(), &mut reply)
                {
                    if master.send_to(&reply[..length], origin).is_ok() {
                        served += 1;
                    }
                }
            }
            served
        });

        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind peer");
        socket.connect(address).expect("connect peer");
        socket
            .set_read_timeout(Some(Duration::from_millis(PONG_TIMEOUT_MS)))
            .expect("peer timeout");
        let mut estimator = ClockEstimator::new(RATE);
        let mut incoming = [0u8; 2048];
        let mut outgoing = [0u8; 64];
        let mut sent = 0u64;
        let mut seq = 0u32;
        let deadline = Instant::now() + Duration::from_millis(600);
        while Instant::now() < deadline {
            let cycle = Instant::now();
            let local_send = clock.now();
            seq = seq.wrapping_add(1);
            let length = encode_ping(&mut outgoing, seq, local_send, 0).expect("encode ping");
            socket.send(&outgoing[..length]).expect("send ping");
            sent += 1;
            if let Ok(length) = socket.recv(&mut incoming) {
                let local_recv = clock.now();
                if let Ok((_, pong)) = decode_pong(&incoming[..length]) {
                    if pong.echo_local_send == local_send {
                        estimator.push(ProbeSample::from_pong(pong, local_send, local_recv));
                    }
                }
            }
            let elapsed = cycle.elapsed();
            let interval = Duration::from_millis(PING_INTERVAL_MS);
            if elapsed < interval {
                thread::sleep(interval - elapsed);
            }
        }

        let served = handler.join().expect("master thread");
        assert!(served > 0, "the master answered no pings");
        assert!(
            sent > estimator.kept(),
            "the dropped pings should be visible: {sent} sent, {} kept",
            estimator.kept()
        );
        assert!(
            estimator.kept() > 10,
            "too few probes to fit: {} kept",
            estimator.kept()
        );
        let estimate = estimator.estimate().expect("an estimate after ~600 ms");
        let rtt = estimator.min_rtt().expect("a round trip");
        assert!(rtt < RATE as u64, "min RTT {rtt} samples is not finite");
        assert!(
            estimate.sample_offset.abs() < 480,
            "loopback offset {} samples",
            estimate.sample_offset
        );
        assert!(
            estimate.drift_ppm.abs() < 500.0,
            "loopback drift {} ppm",
            estimate.drift_ppm
        );
    }
}
