//! The clock probe peers run before they share a transport.
//!
//! Two engines exchange a `CLOCK_HELLO` / `CLOCK_WELCOME` handshake, then a
//! `CLOCK_PING` and a `CLOCK_PONG` over UDP. Each pong carries the master's
//! receive and send times, so the peer can subtract the master's own turnaround
//! from the round trip and place the local and master *midpoints* on the same
//! timeline. A bounded least-squares fit of `master = a + b * local` then yields
//! the offset and the peer clock's drift (docs/studio-audio-roadmap.md §10 and
//! §13 P3).
//!
//! The master is never an open port. The peer proves it knows the 32-byte
//! session key in its HELLO; the master answers with a fresh, unguessable
//! session id; and every later datagram carries a 16-byte truncated
//! HMAC-SHA256 over the header fields that matter and the payload. Pings for a
//! session the master did not issue, pings with a bad MAC, and replays of an
//! already accepted `seq` are dropped and counted.
//!
//! Everything here is off the audio thread. The estimator owns a small
//! `VecDeque`, the CLI owns the `UdpSocket`, and the latest `ClockOffset` is
//! published behind an `Arc<Mutex<…>>`. A render loop should snapshot that value
//! at the top of a callback (or, better, have the probe thread write an atomic
//! pair) and never lock or allocate inside the callback itself.

use std::collections::{HashMap, HashSet, VecDeque};
use std::io::Read;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::loopback::json_escape;
use crate::proto::{self, Codec, Header, ProtoError};
use crate::session::ClockOffset;

type HmacSha256 = Hmac<Sha256>;

/// The header `stream` id for a clock ping. The audio streams use small ids;
/// the high half of the `u16` space is reserved for control traffic so a clock
/// datagram can never be mistaken for an input, bus or zone.
pub const STREAM_CLOCK_PING: u16 = 0xFF00;
/// The header `stream` id for a clock pong. One byte apart from the ping so a
/// trace reads the exchange as a pair.
pub const STREAM_CLOCK_PONG: u16 = 0xFF01;
/// The peer's opening handshake: it proves knowledge of the session key and
/// asks the master for a session id.
pub const STREAM_CLOCK_HELLO: u16 = 0xFF02;
/// The master's answer to a HELLO: the fresh session id the peer must use.
pub const STREAM_CLOCK_WELCOME: u16 = 0xFF03;

/// The reserved "no session yet" value. A HELLO carries it; the master never
/// issues it, so a ping with this session is always rejected.
pub const CLOCK_SESSION: u32 = 0;

/// A HELLO's body: an unpredictable nonce, so two HELLOs are distinct on the
/// wire even when sent from the same process.
pub const HELLO_NONCE_LEN: usize = 8;
/// A WELCOME's body: the session id, little-endian.
pub const WELCOME_BODY_LEN: usize = 4;
/// A ping's body: the peer's send time, in device samples.
pub const PING_BODY_LEN: usize = 8;
/// A pong's body: the ping's send time echoed back, then the master's receive
/// and send times, each in device samples.
pub const PONG_BODY_LEN: usize = 24;

/// The authentication tag appended to every clock payload: HMAC-SHA256 over
/// the header fields that matter and the body, truncated to 16 bytes.
pub const MAC_LEN: usize = 16;

/// The body lengths above, plus the tag, are the wire payload lengths.
pub const HELLO_PAYLOAD_LEN: usize = HELLO_NONCE_LEN + MAC_LEN;
pub const WELCOME_PAYLOAD_LEN: usize = WELCOME_BODY_LEN + MAC_LEN;
pub const PING_PAYLOAD_LEN: usize = PING_BODY_LEN + MAC_LEN;
pub const PONG_PAYLOAD_LEN: usize = PONG_BODY_LEN + MAC_LEN;

// The wire layout after the 32-byte header (all fields little-endian):
//
//   HELLO   | nonce u64                        | tag (16) |
//   WELCOME | session u32                      | tag (16) |
//   PING    | local_send u64                   | tag (16) |
//   PONG    | echo u64 | master_recv u64 | master_send u64 | tag (16) |
//
// The tag is HMAC-SHA256(stream u16 || seq u32 || session u32 ||
// master_sample u64 || body)[..16]. It is the last 16 bytes of every payload.

/// How often the peer pings, in milliseconds. Ten milliseconds is ten probes
/// per 10 ms audio block at 48 kHz and enough samples for a short fit.
pub const PING_INTERVAL_MS: u64 = 10;
/// How long the peer waits for a pong before giving up on that ping. A lost
/// reply costs one interval, not the probe. It must exceed the path's round
/// trip: twenty milliseconds clears a Wi-Fi LAN whose ping floor is a few
/// milliseconds, and a reply that arrives sooner still returns the call at
/// once, so the loopback case pays nothing.
pub const PONG_TIMEOUT_MS: u64 = 20;
/// How long the master keeps a session that has gone quiet. A peer that keeps
/// pinging refreshes its session on every accepted ping; one that stops for
/// longer than the lease is forgotten, so a vanished peer leaves nothing
/// behind. Measured from the last datagram that used the session.
pub const DEFAULT_LEASE_MS: u64 = 30_000;
/// The most sessions the master keeps live at once. A HELLO names no session,
/// so a flood of HELLOs cannot be told apart from real handshakes; the table
/// evicts the least recently used session rather than growing without bound.
pub const MAX_SESSIONS: usize = 64;
/// How long the peer tolerates silence from the master before it treats the
/// session as lost and handshakes again. Two seconds clears a dropped pong or
/// two, and `100 * PING_INTERVAL_MS` scales the same rule to a slower probe.
/// This is the rule that lets a peer survive a master restart: it stops pinging
/// an unknown session and asks for a new one.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(if 2_000 > 100 * PING_INTERVAL_MS {
    2_000
} else {
    100 * PING_INTERVAL_MS
});
/// The master's default bind: loopback only, an ephemeral port. Opening a port
/// another machine can reach is an explicit `--bind`.
pub const DEFAULT_BIND: &str = "127.0.0.1:0";

/// How many probes the estimator keeps. At one ping per 10 ms this is ~640 ms
/// of history: enough to reject jitter without pretending to remember a whole
/// session. A caller that needs the long-term model (`--window`) widens it
/// rather than changing this default: a ten-minute run keeps every probe, so
/// the fit's slope spans the run.
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
    /// The payload is long enough but its HMAC tag does not verify.
    BadMac,
    /// A control message names a session that cannot be used: a HELLO with a
    /// session, or a WELCOME whose payload and header disagree (or name the
    /// reserved session).
    BadSession,
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

/// Parse the 64 hex characters the CLI accepts as a session key.
pub fn parse_session_key(text: &str) -> Result<[u8; 32], String> {
    let text = text.trim();
    // Never echo the key itself: a typo is still most of a real key, and this
    // message reaches a terminal and the log. The shape is enough to fix it.
    let bad = || "a session key is exactly 64 hex characters (32 bytes)".to_string();
    if text.len() != 64 {
        return Err(bad());
    }
    let mut key = [0u8; 32];
    let bytes = text.as_bytes();
    for (index, slot) in key.iter_mut().enumerate() {
        let high = hex_digit(bytes[index * 2]).ok_or_else(&bad)?;
        let low = hex_digit(bytes[index * 2 + 1]).ok_or_else(&bad)?;
        *slot = (high << 4) | low;
    }
    Ok(key)
}

fn hex_digit(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// The 16-byte tag: HMAC-SHA256 over the whole encoded header and the body
/// before the tag. Covering every header byte (codec, flags, channels and the
/// reserved bytes too) keeps the same tag honest when the audio bearer starts
/// carrying `flags` and `channels` that a receiver acts on.
fn mac_tag(key: &[u8; 32], header: &Header, body: &[u8]) -> [u8; MAC_LEN] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts a 32-byte key");
    mac.update(&header.encode());
    mac.update(body);
    let full = mac.finalize().into_bytes();
    let mut tag = [0u8; MAC_LEN];
    tag.copy_from_slice(&full[..MAC_LEN]);
    tag
}

fn tags_match(expected: &[u8], found: &[u8]) -> bool {
    if expected.len() != found.len() {
        return false;
    }
    let mut difference = 0u8;
    for (left, right) in expected.iter().zip(found) {
        difference |= left ^ right;
    }
    difference == 0
}

/// Write a header and `body`, then its tag, into `out`.
fn encode_authenticated(
    out: &mut [u8],
    key: &[u8; 32],
    header: &Header,
    body: &[u8],
) -> Result<usize, ProtoError> {
    let mut payload = [0u8; 64];
    let end = body.len() + MAC_LEN;
    if end > payload.len() {
        return Err(ProtoError::Short);
    }
    payload[..body.len()].copy_from_slice(body);
    payload[body.len()..end].copy_from_slice(&mac_tag(key, header, body));
    proto::encode_datagram(out, header, &payload[..end])
}

/// Read a header and a fixed-length body, verifying the tag before returning
/// the body. The tag's position is always `body_len` bytes past the header.
fn decode_authenticated<'a>(
    datagram: &'a [u8],
    key: &[u8; 32],
    stream: u16,
    body_len: usize,
) -> Result<(Header, &'a [u8]), ProbeError> {
    let (header, offset) = proto::decode(datagram)?;
    if header.stream != stream {
        return Err(ProbeError::NotClock(header.stream));
    }
    let body_end = offset + body_len;
    let end = body_end + MAC_LEN;
    if datagram.len() < end {
        return Err(ProbeError::ShortPayload);
    }
    let body = &datagram[offset..body_end];
    if !tags_match(&mac_tag(key, &header, body), &datagram[body_end..end]) {
        return Err(ProbeError::BadMac);
    }
    Ok((header, body))
}

/// A decoded HELLO.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hello {
    pub header: Header,
    pub nonce: u64,
}

/// A decoded WELCOME.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Welcome {
    pub header: Header,
    pub session: u32,
}

/// Encode a `CLOCK_HELLO`: a nonce and a tag, on the reserved no-session id.
pub fn encode_hello(
    out: &mut [u8],
    key: &[u8; 32],
    seq: u32,
    nonce: u64,
) -> Result<usize, ProtoError> {
    let header = Header {
        codec: Codec::Pcm16,
        flags: 0,
        session: CLOCK_SESSION,
        stream: STREAM_CLOCK_HELLO,
        channels: 0,
        seq,
        master_sample: 0,
    };
    encode_authenticated(out, key, &header, &nonce.to_le_bytes())
}

/// Decode a `CLOCK_HELLO`, verifying its tag with `key`.
pub fn decode_hello(datagram: &[u8], key: &[u8; 32]) -> Result<Hello, ProbeError> {
    let (header, body) = decode_authenticated(datagram, key, STREAM_CLOCK_HELLO, HELLO_NONCE_LEN)?;
    if header.session != CLOCK_SESSION {
        return Err(ProbeError::BadSession);
    }
    let nonce = u64::from_le_bytes(
        body[..HELLO_NONCE_LEN]
            .try_into()
            .expect("a slice of HELLO_NONCE_LEN bytes"),
    );
    Ok(Hello { header, nonce })
}

/// Encode a `CLOCK_WELCOME`: the session id in the header and the body, then
/// a tag the peer verifies with the same key.
pub fn encode_welcome(
    out: &mut [u8],
    key: &[u8; 32],
    seq: u32,
    session: u32,
) -> Result<usize, ProtoError> {
    let header = Header {
        codec: Codec::Pcm16,
        flags: 0,
        session,
        stream: STREAM_CLOCK_WELCOME,
        channels: 0,
        seq,
        master_sample: 0,
    };
    encode_authenticated(out, key, &header, &session.to_le_bytes())
}

/// Decode a `CLOCK_WELCOME`, verifying its tag. The header and the body must
/// name the same non-zero session.
pub fn decode_welcome(datagram: &[u8], key: &[u8; 32]) -> Result<Welcome, ProbeError> {
    let (header, body) =
        decode_authenticated(datagram, key, STREAM_CLOCK_WELCOME, WELCOME_BODY_LEN)?;
    let session = u32::from_le_bytes(
        body[..WELCOME_BODY_LEN]
            .try_into()
            .expect("a slice of WELCOME_BODY_LEN bytes"),
    );
    if session == CLOCK_SESSION || header.session != session {
        return Err(ProbeError::BadSession);
    }
    Ok(Welcome { header, session })
}

/// Encode a `CLOCK_PING`. `master_sample` is the master's transport position
/// (0 for now); the peer leaves it zero. The header's codec byte is `Pcm16`
/// only because every header carries one: a clock payload has no samples.
pub fn encode_ping(
    out: &mut [u8],
    key: &[u8; 32],
    seq: u32,
    session: u32,
    local_send: u64,
    master_sample: u64,
) -> Result<usize, ProtoError> {
    let header = Header {
        codec: Codec::Pcm16,
        flags: 0,
        session,
        stream: STREAM_CLOCK_PING,
        channels: 0,
        seq,
        master_sample,
    };
    encode_authenticated(out, key, &header, &local_send.to_le_bytes())
}

/// Decode a `CLOCK_PING`, verifying its tag and returning its header and the
/// peer's send time.
pub fn decode_ping(datagram: &[u8], key: &[u8; 32]) -> Result<(Header, u64), ProbeError> {
    let (header, body) = decode_authenticated(datagram, key, STREAM_CLOCK_PING, PING_BODY_LEN)?;
    let local_send = u64::from_le_bytes(
        body[..PING_BODY_LEN]
            .try_into()
            .expect("a slice of PING_BODY_LEN bytes"),
    );
    Ok((header, local_send))
}

/// Encode a `CLOCK_PONG`. `seq` comes from the ping so the peer can match the
/// reply; `master_sample` is the master's current transport position (the
/// ping's value, zero in this spike). The body is the echo and the master's
/// two timestamps.
pub fn encode_pong(
    out: &mut [u8],
    key: &[u8; 32],
    seq: u32,
    session: u32,
    pong: Pong,
    master_sample: u64,
) -> Result<usize, ProtoError> {
    let header = Header {
        codec: Codec::Pcm16,
        flags: 0,
        session,
        stream: STREAM_CLOCK_PONG,
        channels: 0,
        seq,
        master_sample,
    };
    let mut body = [0u8; PONG_BODY_LEN];
    body[0..8].copy_from_slice(&pong.echo_local_send.to_le_bytes());
    body[8..16].copy_from_slice(&pong.master_recv.to_le_bytes());
    body[16..24].copy_from_slice(&pong.master_send.to_le_bytes());
    encode_authenticated(out, key, &header, &body)
}

/// Decode a `CLOCK_PONG`, verifying its tag.
pub fn decode_pong(datagram: &[u8], key: &[u8; 32]) -> Result<(Header, Pong), ProbeError> {
    let (header, body) = decode_authenticated(datagram, key, STREAM_CLOCK_PONG, PONG_BODY_LEN)?;
    let pong = Pong {
        echo_local_send: u64::from_le_bytes(
            body[0..8].try_into().expect("a slice of eight bytes"),
        ),
        master_recv: u64::from_le_bytes(
            body[8..16].try_into().expect("a slice of eight bytes"),
        ),
        master_send: u64::from_le_bytes(
            body[16..24].try_into().expect("a slice of eight bytes"),
        ),
    };
    Ok((header, pong))
}

/// One unpredictable nonce for a HELLO.
fn random_nonce() -> u64 {
    let mut bytes = [0u8; 8];
    if random_bytes(&mut bytes) {
        return u64::from_ne_bytes(bytes);
    }
    fallback_random_u64()
}

/// A fresh session id for a HELLO. It is never zero and never repeats inside
/// the master's live session table.
fn random_session_id() -> u32 {
    let mut bytes = [0u8; 4];
    if random_bytes(&mut bytes) {
        let id = u32::from_ne_bytes(bytes);
        if id != CLOCK_SESSION {
            return id;
        }
    }
    let id = fallback_random_u64() as u32;
    if id != CLOCK_SESSION {
        id
    } else {
        1
    }
}

fn random_bytes(buffer: &mut [u8]) -> bool {
    std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(buffer))
        .is_ok()
}

fn fallback_random_u64() -> u64 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos() as u64)
        .unwrap_or(0);
    let mut z = nanos ^ ((std::process::id() as u64) << 32) ^ 0x9E37_79B9_7F4A_7C15;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// What the master sent back for one datagram.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlReply {
    Welcome(usize),
    Pong(usize),
}

impl ControlReply {
    /// How many bytes of `out` the reply occupies.
    pub fn length(self) -> usize {
        match self {
            ControlReply::Welcome(length) | ControlReply::Pong(length) => length,
        }
    }

    /// Whether this reply is a pong (a ping was served) rather than a welcome.
    pub fn is_pong(self) -> bool {
        matches!(self, ControlReply::Pong(_))
    }
}

/// One issued session: the `seq` values already served and when the session
/// last carried an accepted datagram.
struct Session {
    seen: HashSet<u32>,
    last_used: Instant,
}

/// The clock master's session table and key.
///
/// A HELLO for the key issues a session; only pings for an issued session are
/// answered. A clock message that fails its MAC, names a session this master
/// did not issue, or repeats an accepted `seq` is dropped and counted. Sessions
/// expire on a lease and the table has a hard cap, so neither a vanished peer
/// nor a HELLO flood can grow it without bound.
pub struct ClockMaster {
    key: [u8; 32],
    sessions: HashMap<u32, Session>,
    lease: Duration,
    rejected: u64,
}

impl ClockMaster {
    /// A master that will speak only to peers holding `key`.
    pub fn new(key: [u8; 32]) -> Self {
        ClockMaster {
            key,
            sessions: HashMap::new(),
            lease: Duration::from_millis(DEFAULT_LEASE_MS),
            rejected: 0,
        }
    }

    /// The same master, forgetting a session that has been idle for `lease`.
    pub fn with_lease(mut self, lease: Duration) -> Self {
        self.lease = lease;
        self
    }

    /// Answer one datagram, or ignore it. The caller sends the returned bytes
    /// to the datagram's origin.
    ///
    /// Every datagram first prunes sessions idle past the lease: a ping naming
    /// a session that has expired is indistinguishable from one this master
    /// never issued, so it is dropped and counted.
    pub fn answer(
        &mut self,
        datagram: &[u8],
        clock: &dyn Clock,
        out: &mut [u8],
    ) -> Option<ControlReply> {
        self.answer_at(datagram, clock, Instant::now(), out)
    }

    /// The same answer, with the moment supplied. A test drives the lease with
    /// `base + Duration` rather than sleeping, so a loaded machine cannot turn
    /// a busy session into an expired one.
    fn answer_at(
        &mut self,
        datagram: &[u8],
        clock: &dyn Clock,
        now: Instant,
        out: &mut [u8],
    ) -> Option<ControlReply> {
        self.prune(now);
        let (header, _) = proto::decode(datagram).ok()?;
        match header.stream {
            STREAM_CLOCK_HELLO => {
                let hello = match decode_hello(datagram, &self.key) {
                    Ok(hello) => hello,
                    Err(error) => {
                        self.note_rejection(&error);
                        return None;
                    }
                };
                let session = self.fresh_session();
                let length = encode_welcome(out, &self.key, hello.header.seq, session).ok()?;
                self.remember(session, now);
                Some(ControlReply::Welcome(length))
            }
            STREAM_CLOCK_PING => {
                let (header, local_send) = match decode_ping(datagram, &self.key) {
                    Ok(ping) => ping,
                    Err(error) => {
                        self.note_rejection(&error);
                        return None;
                    }
                };
                let session = match self.sessions.get_mut(&header.session) {
                    Some(session) => session,
                    None => {
                        self.rejected += 1;
                        return None;
                    }
                };
                if !session.seen.insert(header.seq) {
                    self.rejected += 1;
                    return None;
                }
                session.last_used = now;
                let master_recv = clock.now();
                let pong = Pong {
                    echo_local_send: local_send,
                    master_recv,
                    master_send: clock.now(),
                };
                let length = encode_pong(
                    out,
                    &self.key,
                    header.seq,
                    header.session,
                    pong,
                    header.master_sample,
                )
                .ok()?;
                Some(ControlReply::Pong(length))
            }
            _ => None,
        }
    }

    /// Drop every session whose last accepted datagram is older than the lease.
    fn prune(&mut self, now: Instant) {
        let lease = self.lease;
        self.sessions
            .retain(|_, session| now.duration_since(session.last_used) < lease);
    }

    /// Record a newly issued session, evicting the least recently used one when
    /// the table is full. `last_used` is set to `now` by the caller.
    fn remember(&mut self, session: u32, now: Instant) {
        if self.sessions.len() >= MAX_SESSIONS {
            let oldest = self
                .sessions
                .iter()
                .min_by_key(|(_id, record)| record.last_used)
                .map(|(id, _)| *id);
            if let Some(oldest) = oldest {
                self.sessions.remove(&oldest);
            }
        }
        self.sessions.insert(
            session,
            Session {
                seen: HashSet::new(),
                last_used: now,
            },
        );
    }

    fn note_rejection(&mut self, error: &ProbeError) {
        if matches!(error, ProbeError::BadMac | ProbeError::BadSession) {
            self.rejected += 1;
        }
    }

    fn fresh_session(&self) -> u32 {
        loop {
            let id = random_session_id();
            if !self.sessions.contains_key(&id) {
                return id;
            }
        }
    }

    /// Clock datagrams this master dropped for authentication or replay.
    pub fn rejected(&self) -> u64 {
        self.rejected
    }

    /// How many sessions this master has issued (a test and diagnostic hook).
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }
}

/// The peer's key, session, and the pings it has already accepted.
///
/// `last_heard` is the peer's quiet timer: it starts when a WELCOME issues the
/// session and is refreshed by every accepted pong. When it runs past
/// `HANDSHAKE_TIMEOUT` the session is presumed lost (a master restart strands
/// it) and the peer hands over to `reset_session` before a fresh HELLO.
pub struct ClockPeer {
    key: [u8; 32],
    session: u32,
    next_seq: u32,
    seen: HashSet<u32>,
    rejected: u64,
    last_heard: Option<Instant>,
}

impl ClockPeer {
    /// A peer that must handshake with a master holding `key`.
    pub fn new(key: [u8; 32]) -> Self {
        ClockPeer {
            key,
            session: CLOCK_SESSION,
            next_seq: 0,
            seen: HashSet::new(),
            rejected: 0,
            last_heard: None,
        }
    }

    /// The session the master issued, or `CLOCK_SESSION` before the handshake.
    pub fn session(&self) -> u32 {
        self.session
    }

    /// Datagrams this peer dropped for authentication or replay.
    pub fn rejected(&self) -> u64 {
        self.rejected
    }

    /// Whether the peer must run the HELLO/WELCOME exchange again before its
    /// next ping: there is no session, or the master has been quiet for
    /// `HANDSHAKE_TIMEOUT` since the welcome or the last accepted pong.
    pub fn needs_handshake(&self, now: Instant) -> bool {
        if self.session == CLOCK_SESSION {
            return true;
        }
        match self.last_heard {
            Some(heard) => now.duration_since(heard) >= HANDSHAKE_TIMEOUT,
            None => true,
        }
    }

    /// Forget the session, the replay window and the quiet timer, so the next
    /// HELLO starts clean. `next_seq` keeps counting: a `seq` is never reused
    /// across sessions.
    pub fn reset_session(&mut self) {
        self.session = CLOCK_SESSION;
        self.seen.clear();
        self.last_heard = None;
    }

    /// Build the opening HELLO. The caller sends it and waits for a WELCOME.
    pub fn hello(&mut self, out: &mut [u8]) -> Result<usize, ProtoError> {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);
        encode_hello(out, &self.key, seq, random_nonce())
    }

    /// Verify a WELCOME and adopt its session. A bad tag is counted. The
    /// welcome also starts the quiet timer: the master has just spoken, so the
    /// peer should not immediately ask to handshake again before its first
    /// pong arrives.
    pub fn accept_welcome(&mut self, datagram: &[u8]) -> Result<u32, ProbeError> {
        match decode_welcome(datagram, &self.key) {
            Ok(welcome) => {
                self.session = welcome.session;
                self.seen.clear();
                self.last_heard = Some(Instant::now());
                Ok(self.session)
            }
            Err(error) => {
                if matches!(error, ProbeError::BadMac | ProbeError::BadSession) {
                    self.rejected += 1;
                }
                Err(error)
            }
        }
    }

    /// Build one ping for the session the handshake established.
    pub fn ping(
        &mut self,
        out: &mut [u8],
        local_send: u64,
        master_sample: u64,
    ) -> Result<usize, ProtoError> {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);
        encode_ping(out, &self.key, seq, self.session, local_send, master_sample)
    }

    /// Verify a pong against the key, the session and the pings already
    /// accepted. `None` means this datagram contributes no sample. A bad MAC,
    /// a foreign session or a replay is also counted as rejected. An accepted
    /// pong refreshes the quiet timer.
    pub fn accept_pong(&mut self, datagram: &[u8], local_send: u64) -> Option<Pong> {
        let (header, pong) = match decode_pong(datagram, &self.key) {
            Ok(pong) => pong,
            Err(error) => {
                if matches!(error, ProbeError::BadMac) {
                    self.rejected += 1;
                }
                return None;
            }
        };
        if self.session == CLOCK_SESSION || header.session != self.session {
            self.rejected += 1;
            return None;
        }
        if pong.echo_local_send != local_send {
            return None;
        }
        if !self.seen.insert(header.seq) {
            self.rejected += 1;
            return None;
        }
        self.last_heard = Some(Instant::now());
        Some(pong)
    }
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
        self.fit().map(|(estimate, _quality)| estimate)
    }

    /// The current estimate with the fit's own quality.
    ///
    /// `slope_error_ppm` is the slope's standard error. Over a run of `T`
    /// seconds it is the corrected drift the model leaves behind:
    /// `slope_error_ppm * T * rate / 1e6` samples. A ten-minute gate reads
    /// that number rather than the raw drift, because the raw drift is what
    /// the fitted rate exists to cancel.
    pub fn fit(&self) -> Option<(ClockOffset, FitQuality)> {
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
        let mut sse = 0.0;
        for sample in &self.samples {
            let residual =
                sample.master_midpoint() - (intercept + slope * sample.local_midpoint());
            sse += residual * residual;
        }
        let rms_residual_samples = (sse / count).sqrt();
        // Two fitted parameters cost two degrees of freedom.
        let slope_error_ppm = if self.samples.len() > 2 {
            (sse / (count - 2.0) / sxx).sqrt() * 1_000_000.0
        } else {
            f64::INFINITY
        };
        Some((
            ClockOffset::new(
                intercept.round() as i64,
                (1.0 - slope) * 1_000_000.0,
            ),
            FitQuality {
                rms_residual_samples,
                slope_error_ppm,
            },
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

/// How well the line explains the probes it was fitted to.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FitQuality {
    /// RMS distance of the kept probes from the fitted line, in samples.
    pub rms_residual_samples: f64,
    /// The slope's standard error, in ppm.
    pub slope_error_ppm: f64,
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
    /// The fit's residual and slope error, for a peer run long enough to fit.
    pub quality: Option<FitQuality>,
    /// The session the master issued (peer), or 0 (master).
    pub session: u32,
    /// How many HELLO/WELCOME exchanges the peer completed, one at startup and
    /// another each time the master went quiet long enough to re-handshake.
    pub handshakes: u64,
    /// Clock datagrams dropped for authentication, an unknown session or a
    /// replay, on either role.
    pub rejected: u64,
    pub error: String,
}

impl ClockReport {
    /// The master's final line: how many pings it answered and how many clock
    /// datagrams it refused.
    pub fn master(
        address: impl Into<String>,
        rate: u32,
        seconds: f64,
        served: u64,
        rejected: u64,
    ) -> Self {
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
            quality: None,
            session: 0,
            handshakes: 0,
            rejected,
            error: String::new(),
        }
    }

    /// The peer's final line.
    #[allow(clippy::too_many_arguments)]
    pub fn peer(
        address: impl Into<String>,
        rate: u32,
        seconds: f64,
        sent: u64,
        received: u64,
        estimator: &ClockEstimator,
        estimate: Option<ClockOffset>,
        session: u32,
        handshakes: u64,
        rejected: u64,
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
            quality: estimator.fit().map(|(_estimate, quality)| quality),
            session,
            handshakes,
            rejected,
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
            quality: None,
            session: 0,
            handshakes: 0,
            rejected: 0,
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
                "{{\"ok\":true,\"role\":\"master\",\"bind\":\"{}\",\"rate\":{},\"seconds\":{},\"served\":{},\"rejected\":{}}}",
                json_escape(&self.address),
                self.rate,
                self.seconds,
                self.sent,
                self.rejected
            );
        }
        let (offset, drift) = match self.estimate {
            Some(estimate) => (
                estimate.sample_offset.to_string(),
                format!("{:.6}", estimate.drift_ppm),
            ),
            None => ("null".to_string(), "null".to_string()),
        };
        let (rms, slope_error) = match self.quality {
            Some(quality) => (
                format!("{:.3}", quality.rms_residual_samples),
                format!("{:.6}", quality.slope_error_ppm),
            ),
            None => ("null".to_string(), "null".to_string()),
        };
        format!(
            "{{\"ok\":true,\"role\":\"peer\",\"master\":\"{}\",\"rate\":{},\"seconds\":{},\"sent\":{},\"received\":{},\"kept\":{},\"dropped\":{},\"min_rtt_samples\":{},\"last_rtt_samples\":{},\"offset_samples\":{},\"drift_ppm\":{},\"rms_residual_samples\":{},\"slope_error_ppm\":{},\"session\":{},\"handshakes\":{},\"rejected\":{}}}",
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
            drift,
            rms,
            slope_error,
            self.session,
            self.handshakes,
            self.rejected
        )
    }

    pub fn prose(&self) -> String {
        if !self.ok {
            return format!("clock {} {}: failed: {}", self.role, self.address, self.error);
        }
        if self.role == "master" {
            return format!(
                "clock master on {}: served {} pings in {:.1} s, {} rejected",
                self.address, self.sent, self.seconds, self.rejected
            );
        }
        let estimate = match self.estimate {
            Some(estimate) => format!(
                "offset {} samples, drift {:.2} ppm",
                estimate.sample_offset, estimate.drift_ppm
            ),
            None => "no estimate yet".to_string(),
        };
        let fit = match self.quality {
            Some(quality) => format!(
                ", fit rms {:.2} samples, slope ±{:.3} ppm",
                quality.rms_residual_samples, quality.slope_error_ppm
            ),
            None => String::new(),
        };
        format!(
            "clock peer of {}: {}{}, {} sent, {} received, {} kept, {} dropped, {} rejected, {} handshakes, session {}, RTT {} samples (min {})",
            self.address,
            estimate,
            fit,
            self.sent,
            self.received,
            self.kept,
            self.dropped,
            self.rejected,
            self.handshakes,
            self.session,
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

    const KEY: [u8; 32] = [0x42; 32];
    const WRONG_KEY: [u8; 32] = [0x43; 32];
    const SESSION: u32 = 0xDEAD_BEEF;

    /// Handshake a fresh master and peer, returning the session they agreed on.
    fn handshake(master: &mut ClockMaster, peer: &mut ClockPeer, clock: &dyn Clock) -> u32 {
        let mut hello = [0u8; 128];
        let hello_length = peer.hello(&mut hello).expect("encode hello");
        let mut reply = [0u8; 128];
        let welcome = master
            .answer(&hello[..hello_length], clock, &mut reply)
            .expect("a welcome");
        assert!(matches!(welcome, ControlReply::Welcome(_)));
        peer.accept_welcome(&reply[..welcome.length()])
            .expect("accept welcome")
    }

    #[test]
    fn a_clock_ping_round_trips_the_header_and_its_send_time() {
        let mut datagram = [0u8; 128];
        let length = encode_ping(&mut datagram, &KEY, 7, SESSION, 123_456, 0).expect("encode ping");
        let (header, local_send) = decode_ping(&datagram[..length], &KEY).expect("decode ping");
        assert_eq!(header.stream, STREAM_CLOCK_PING);
        assert_eq!(header.session, SESSION);
        assert_eq!(header.seq, 7);
        assert_eq!(header.codec, Codec::Pcm16);
        assert_eq!(local_send, 123_456);
        assert_eq!(
            decode_ping(&datagram[..length], &WRONG_KEY),
            Err(ProbeError::BadMac)
        );
    }

    #[test]
    fn a_clock_pong_round_trips_the_echo_and_both_master_times() {
        let pong = Pong {
            echo_local_send: 111,
            master_recv: 222,
            master_send: 333,
        };
        let mut datagram = [0u8; 128];
        let length = encode_pong(&mut datagram, &KEY, 9, SESSION, pong, 0).expect("encode pong");
        let (header, back) = decode_pong(&datagram[..length], &KEY).expect("decode pong");
        assert_eq!(header.stream, STREAM_CLOCK_PONG);
        assert_eq!(header.session, SESSION);
        assert_eq!(header.seq, 9);
        assert_eq!(back, pong);
        assert_eq!(
            decode_pong(&datagram[..length], &WRONG_KEY),
            Err(ProbeError::BadMac)
        );
    }

    #[test]
    fn the_tag_is_the_last_sixteen_bytes_of_every_clock_payload() {
        assert_eq!(HELLO_PAYLOAD_LEN, 24);
        assert_eq!(WELCOME_PAYLOAD_LEN, 20);
        assert_eq!(PING_PAYLOAD_LEN, 24);
        assert_eq!(PONG_PAYLOAD_LEN, 40);

        let mut out = [0u8; 128];
        let hello_length = encode_hello(&mut out, &KEY, 1, 0x1122_3344_5566_7788).expect("hello");
        assert_eq!(hello_length, proto::HEADER_LEN + HELLO_PAYLOAD_LEN);
        let (header, _) = proto::decode(&out[..hello_length]).expect("header");
        let body = &out[proto::HEADER_LEN..proto::HEADER_LEN + HELLO_NONCE_LEN];
        assert_eq!(
            &out[hello_length - MAC_LEN..hello_length],
            &mac_tag(&KEY, &header, body)
        );

        let welcome_length = encode_welcome(&mut out, &KEY, 1, SESSION).expect("welcome");
        assert_eq!(welcome_length, proto::HEADER_LEN + WELCOME_PAYLOAD_LEN);
        let (header, _) = proto::decode(&out[..welcome_length]).expect("header");
        let body = &out[proto::HEADER_LEN..proto::HEADER_LEN + WELCOME_BODY_LEN];
        assert_eq!(
            &out[welcome_length - MAC_LEN..welcome_length],
            &mac_tag(&KEY, &header, body)
        );

        let ping_length = encode_ping(&mut out, &KEY, 2, SESSION, 123, 0).expect("ping");
        assert_eq!(ping_length, proto::HEADER_LEN + PING_PAYLOAD_LEN);
        let (header, _) = proto::decode(&out[..ping_length]).expect("header");
        let body = &out[proto::HEADER_LEN..proto::HEADER_LEN + PING_BODY_LEN];
        assert_eq!(
            &out[ping_length - MAC_LEN..ping_length],
            &mac_tag(&KEY, &header, body)
        );

        let pong = Pong {
            echo_local_send: 1,
            master_recv: 2,
            master_send: 3,
        };
        let pong_length = encode_pong(&mut out, &KEY, 2, SESSION, pong, 0).expect("pong");
        assert_eq!(pong_length, proto::HEADER_LEN + PONG_PAYLOAD_LEN);
        let (header, _) = proto::decode(&out[..pong_length]).expect("header");
        let body = &out[proto::HEADER_LEN..proto::HEADER_LEN + PONG_BODY_LEN];
        assert_eq!(
            &out[pong_length - MAC_LEN..pong_length],
            &mac_tag(&KEY, &header, body)
        );
    }

    #[test]
    fn a_clock_stream_with_a_short_payload_is_rejected() {
        let mut datagram = [0u8; 128];
        let length = encode_ping(&mut datagram, &KEY, 1, SESSION, 42, 0).expect("encode ping");
        assert_eq!(
            decode_ping(&datagram[..length - 1], &KEY),
            Err(ProbeError::ShortPayload)
        );
        assert_eq!(
            decode_pong(&datagram[..length], &KEY),
            Err(ProbeError::NotClock(STREAM_CLOCK_PING))
        );
    }

    #[test]
    fn a_hello_with_the_right_key_gets_a_fresh_session_and_a_wrong_key_does_not() {
        let clock = ManualClock::new(0);
        let mut master = ClockMaster::new(KEY);
        let mut hello = [0u8; 128];
        let length = encode_hello(&mut hello, &KEY, 1, 0xABCD).expect("encode hello");
        let mut reply = [0u8; 128];

        let welcome = master
            .answer(&hello[..length], &clock, &mut reply)
            .expect("a welcome");
        let welcome_length = welcome.length();
        let first = decode_welcome(&reply[..welcome_length], &KEY).expect("decode welcome");
        assert!(matches!(welcome, ControlReply::Welcome(_)));
        assert_ne!(first.session, CLOCK_SESSION);
        assert_eq!(first.header.seq, 1);
        assert_eq!(master.session_count(), 1);
        assert_eq!(master.rejected(), 0);

        // A new HELLO gets a new session.
        let welcome = master
            .answer(&hello[..length], &clock, &mut reply)
            .expect("a second welcome");
        let second = decode_welcome(&reply[..welcome.length()], &KEY).expect("decode welcome");
        assert_ne!(second.session, first.session);
        assert_eq!(master.session_count(), 2);

        // The wrong key cannot authenticate a HELLO, and the peer cannot
        // authenticate the master's WELCOME with it either.
        let length = encode_hello(&mut hello, &WRONG_KEY, 2, 0xDCBA).expect("encode hello");
        assert_eq!(master.answer(&hello[..length], &clock, &mut reply), None);
        assert_eq!(master.rejected(), 1);
        let mut peer = ClockPeer::new(WRONG_KEY);
        assert_eq!(
            peer.accept_welcome(&reply[..welcome_length]),
            Err(ProbeError::BadMac)
        );
        assert_eq!(peer.rejected(), 1);
    }

    #[test]
    fn the_master_issues_a_session_answers_its_pings_and_ignores_anything_else() {
        let clock = ManualClock::new(10_000);
        let mut master = ClockMaster::new(KEY);
        let mut peer = ClockPeer::new(KEY);
        let session = handshake(&mut master, &mut peer, &clock);
        assert_ne!(session, CLOCK_SESSION);

        let mut ping = [0u8; 128];
        let length = encode_ping(&mut ping, &KEY, 3, session, 5_000, 0).expect("encode ping");
        let mut reply = [0u8; 128];
        let answered = master
            .answer(&ping[..length], &clock, &mut reply)
            .expect("a pong");
        assert!(answered.is_pong());
        let (header, pong) = decode_pong(&reply[..answered.length()], &KEY).expect("decode pong");
        assert_eq!(header.seq, 3);
        assert_eq!(header.session, session);
        assert_eq!(pong.echo_local_send, 5_000);
        assert_eq!(pong.master_recv, 10_000);
        assert_eq!(master.rejected(), 0);

        let mut audio = [0u8; 64];
        let audio_length = proto::encode_datagram(
            &mut audio,
            &Header {
                codec: Codec::Pcm16,
                flags: 0,
                session,
                stream: 7,
                channels: 1,
                seq: 0,
                master_sample: 0,
            },
            &[0u8; 4],
        )
        .expect("encode audio");
        assert_eq!(master.answer(&audio[..audio_length], &clock, &mut reply), None);
    }

    #[test]
    fn a_pong_with_a_corrupted_mac_is_not_accepted() {
        let clock = ManualClock::new(1_000);
        let mut master = ClockMaster::new(KEY);
        let mut peer = ClockPeer::new(KEY);
        let session = handshake(&mut master, &mut peer, &clock);
        assert_ne!(session, CLOCK_SESSION);

        let mut ping = [0u8; 128];
        let length = peer.ping(&mut ping, 5_000, 0).expect("encode ping");
        let mut reply = [0u8; 128];
        let pong = master
            .answer(&ping[..length], &clock, &mut reply)
            .expect("a pong");
        let pong_length = pong.length();
        assert_eq!(
            decode_pong(&reply[..pong_length], &WRONG_KEY),
            Err(ProbeError::BadMac)
        );

        // Corrupt the tag's last byte: the peer must refuse it and count it.
        let last = pong_length - 1;
        reply[last] ^= 0x01;
        assert_eq!(peer.accept_pong(&reply[..pong_length], 5_000), None);
        assert_eq!(peer.rejected(), 1);

        // Restoring the byte makes the same pong acceptable.
        reply[last] ^= 0x01;
        assert_eq!(
            peer.accept_pong(&reply[..pong_length], 5_000),
            Some(Pong {
                echo_local_send: 5_000,
                master_recv: 1_000,
                master_send: 1_000,
            })
        );
    }

    #[test]
    fn a_ping_for_an_unknown_session_is_ignored_and_counted() {
        let clock = ManualClock::new(0);
        let mut master = ClockMaster::new(KEY);
        let mut ping = [0u8; 128];
        let length = encode_ping(&mut ping, &KEY, 1, 0x1234_5678, 5, 0).expect("encode ping");
        let mut reply = [0u8; 128];
        assert_eq!(master.answer(&ping[..length], &clock, &mut reply), None);
        assert_eq!(master.rejected(), 1);
        assert_eq!(master.session_count(), 0);
    }

    #[test]
    fn a_replayed_ping_seq_is_ignored_and_counted() {
        let clock = ManualClock::new(0);
        let mut master = ClockMaster::new(KEY);
        let mut peer = ClockPeer::new(KEY);
        let session = handshake(&mut master, &mut peer, &clock);

        let mut ping = [0u8; 128];
        let length = encode_ping(&mut ping, &KEY, 7, session, 5, 0).expect("encode ping");
        let mut reply = [0u8; 128];
        assert!(master
            .answer(&ping[..length], &clock, &mut reply)
            .expect("a pong")
            .is_pong());
        // The exact datagram again: same session, same seq.
        assert_eq!(master.answer(&ping[..length], &clock, &mut reply), None);
        assert_eq!(master.rejected(), 1);

        // A different seq in the same session is still served.
        let length = encode_ping(&mut ping, &KEY, 8, session, 6, 0).expect("encode ping");
        assert!(master
            .answer(&ping[..length], &clock, &mut reply)
            .expect("a pong")
            .is_pong());
    }

    #[test]
    fn a_busy_session_outlives_its_lease_and_an_idle_one_does_not() {
        let clock = ManualClock::new(0);
        let lease = Duration::from_millis(200);
        let mut master = ClockMaster::new(KEY).with_lease(lease);
        let mut peer = ClockPeer::new(KEY);
        let session = handshake(&mut master, &mut peer, &clock);
        let base = Instant::now();

        let mut ping = [0u8; 128];
        let mut reply = [0u8; 128];
        // Pings spread across more than a lease: each accepted ping refreshes
        // the session, so it never expires. The moments are supplied rather
        // than slept for, so a loaded machine cannot expire a busy session.
        for step in 0..12u32 {
            let now = base + Duration::from_millis(step as u64 * 50);
            let length = encode_ping(&mut ping, &KEY, step, session, 5, 0).expect("encode ping");
            assert!(
                master
                    .answer_at(&ping[..length], &clock, now, &mut reply)
                    .expect("a pong")
                    .is_pong(),
                "the session expired while it was still pinging"
            );
        }
        assert_eq!(master.session_count(), 1);
        assert_eq!(master.rejected(), 0);

        // Go quiet past the lease, measured from the last ping: the session is
        // pruned, and a ping naming it is unknown and counted.
        let now = base + Duration::from_millis(11 * 50) + lease + Duration::from_millis(1);
        let length = encode_ping(&mut ping, &KEY, 10_000, session, 5, 0).expect("encode ping");
        assert_eq!(master.answer_at(&ping[..length], &clock, now, &mut reply), None);
        assert_eq!(master.rejected(), 1);
        assert_eq!(master.session_count(), 0);
    }

    #[test]
    fn a_hello_flood_stays_at_the_session_cap_and_evicts_the_oldest() {
        let clock = ManualClock::new(0);
        let mut master = ClockMaster::new(KEY);
        let mut hello = [0u8; 128];
        let mut reply = [0u8; 128];
        let base = Instant::now();

        // The first session is the one a flood must eventually evict.
        let length = encode_hello(&mut hello, &KEY, 0, 0xAAAA).expect("encode hello");
        let welcome = master
            .answer_at(&hello[..length], &clock, base, &mut reply)
            .expect("a welcome");
        let oldest = decode_welcome(&reply[..welcome.length()], &KEY)
            .expect("decode welcome")
            .session;

        for seq in 1..=(MAX_SESSIONS as u32 + 8) {
            // A distinct moment per HELLO keeps "oldest" unambiguous.
            let now = base + Duration::from_millis(seq as u64);
            let length = encode_hello(&mut hello, &KEY, seq, seq as u64).expect("encode hello");
            assert!(matches!(
                master.answer_at(&hello[..length], &clock, now, &mut reply),
                Some(ControlReply::Welcome(_))
            ));
        }
        assert_eq!(master.session_count(), MAX_SESSIONS);

        // The first session was evicted: a ping naming it is unknown and counted.
        let mut ping = [0u8; 128];
        let now = base + Duration::from_millis(1_000);
        let length = encode_ping(&mut ping, &KEY, 1, oldest, 5, 0).expect("encode ping");
        assert_eq!(master.answer_at(&ping[..length], &clock, now, &mut reply), None);
        assert_eq!(master.rejected(), 1);
    }

    #[test]
    fn the_peer_handshakes_again_only_after_the_quiet_timeout() {
        let clock = ManualClock::new(0);
        let mut master = ClockMaster::new(KEY);
        let mut peer = ClockPeer::new(KEY);

        // No session yet.
        assert!(peer.needs_handshake(Instant::now()));

        let session = handshake(&mut master, &mut peer, &clock);
        // The WELCOME starts the quiet timer, and an accepted pong refreshes it.
        assert!(!peer.needs_handshake(Instant::now()));
        let mut ping = [0u8; 128];
        let mut reply = [0u8; 128];
        let length = peer.ping(&mut ping, 5_000, 0).expect("encode ping");
        let pong = master
            .answer(&ping[..length], &clock, &mut reply)
            .expect("a pong");
        assert!(peer.accept_pong(&reply[..pong.length()], 5_000).is_some());
        assert!(!peer.seen.is_empty(), "the replay window has the accepted seq");

        let heard = Instant::now();
        assert!(!peer.needs_handshake(heard + HANDSHAKE_TIMEOUT - Duration::from_millis(1)));
        assert!(peer.needs_handshake(heard + HANDSHAKE_TIMEOUT + Duration::from_millis(1)));

        // A reset clears the session and the replay window, then a fresh HELLO
        // gets a new session from the same master.
        peer.reset_session();
        assert_eq!(peer.session(), CLOCK_SESSION);
        assert!(peer.seen.is_empty(), "the replay window was not cleared");
        assert!(peer.needs_handshake(Instant::now()));
        let fresh = handshake(&mut master, &mut peer, &clock);
        assert_ne!(fresh, session);
        assert!(!peer.needs_handshake(Instant::now()));
    }

    #[test]
    fn the_peer_report_carries_the_handshake_count() {
        let estimator = ClockEstimator::new(RATE);
        let report = ClockReport::peer(
            "127.0.0.1:7050",
            RATE,
            1.0,
            0,
            0,
            &estimator,
            None,
            SESSION,
            3,
            0,
        );
        assert!(report.to_json().contains("\"handshakes\":3"), "{}", report.to_json());
        assert!(report.prose().contains("3 handshakes"), "{}", report.prose());
    }

    #[test]
    fn a_session_key_is_exactly_sixty_four_hex_characters() {
        let zeros = parse_session_key(&"00".repeat(32)).expect("all-zero bytes");
        assert!(zeros.iter().all(|byte| *byte == 0));
        let mixed = parse_session_key(&"aB".repeat(32)).expect("mixed case");
        assert!(mixed.iter().all(|byte| *byte == 0xAB));
        assert!(parse_session_key("00ff10A2").is_err());
        assert!(parse_session_key(&"aB".repeat(32)).is_ok());
        assert!(parse_session_key(&"g".repeat(64)).is_err());
        assert!(parse_session_key(&"0".repeat(63)).is_err());
        assert!(parse_session_key(&"0".repeat(65)).is_err());
        // The refusal must not repeat what was typed: a typo is still most of
        // a real key, and the message goes to a terminal and the log.
        let message = parse_session_key(&"g".repeat(64)).expect_err("a bad key");
        assert!(
            !message.contains('g'),
            "the error echoed the key: {message}"
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
    fn a_long_window_fits_the_whole_run_not_its_tail() {
        // A ten-minute run is ~60 000 probes; 4 000 keeps the test quick and
        // is still 60x the default window. The exact drift is 4 ppm; at this
        // baseline a fourth of a ppm is the integer stamp's own floor, and the
        // 640 ms default window's slope is an order of magnitude noisier.
        let mut wide = ClockEstimator::with_capacity(4_096, RATE);
        let mut tail = ClockEstimator::new(RATE);
        for index in 0..4_000u64 {
            // Probes 10 ms apart with a one-sample jitter either way.
            let sample = sample_at(index * 480, 48, 1_000_000, 4.0, (index % 3) as i64 - 1);
            wide.push(sample);
            tail.push(sample);
        }
        assert_eq!(wide.window_len(), 4_000);
        assert_eq!(tail.window_len(), ESTIMATOR_CAPACITY);
        let estimate = wide.estimate().expect("an estimate");
        assert!(
            (estimate.drift_ppm - 4.0).abs() < 0.2,
            "drift {} wanted ~4 ppm",
            estimate.drift_ppm
        );
        // The wide fit pins the slope down; the tail cannot, because its
        // baseline is a second rather than the run.
        let (_estimate, wide_quality) = wide.fit().expect("a fit");
        let (_estimate, tail_quality) = tail.fit().expect("a fit");
        assert!(
            wide_quality.rms_residual_samples < 2.0,
            "rms {} samples wanted under 2",
            wide_quality.rms_residual_samples
        );
        assert!(
            wide_quality.slope_error_ppm < tail_quality.slope_error_ppm / 4.0,
            "slope error wide {} tail {}",
            wide_quality.slope_error_ppm,
            tail_quality.slope_error_ppm
        );
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
            let mut clock_master = ClockMaster::new(KEY);
            let mut incoming = [0u8; 2048];
            let mut reply = [0u8; 2048];
            let mut served = 0u64;
            let deadline = Instant::now() + Duration::from_millis(1_400);
            while Instant::now() < deadline {
                let (length, origin) = match master.recv_from(&mut incoming) {
                    Ok(pair) => pair,
                    Err(_) => continue,
                };
                // Drop every third ping: the peer must still estimate.
                if let Ok((header, _)) = decode_ping(&incoming[..length], &KEY) {
                    if header.seq % 3 == 0 {
                        continue;
                    }
                }
                if let Some(answer) =
                    clock_master.answer(&incoming[..length], master_clock.as_ref(), &mut reply)
                {
                    if master.send_to(&reply[..answer.length()], origin).is_ok()
                        && answer.is_pong()
                    {
                        served += 1;
                    }
                }
            }
            (served, clock_master.rejected())
        });

        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind peer");
        socket.connect(address).expect("connect peer");
        socket
            .set_read_timeout(Some(Duration::from_millis(PONG_TIMEOUT_MS)))
            .expect("peer timeout");
        // A 1.2 s baseline keeps the slope's noise well below the 500 ppm cap
        // even while the rest of the suite is running on the same box. The
        // wider window keeps every kept probe, so the fit spans the run.
        let mut estimator = ClockEstimator::with_capacity(512, RATE);
        let mut probe = ClockPeer::new(KEY);
        let mut incoming = [0u8; 2048];
        let mut outgoing = [0u8; 128];
        let mut sent = 0u64;
        let deadline = Instant::now() + Duration::from_millis(1_200);

        // HELLO first; retry until the master's WELCOME arrives or the run ends.
        let mut session = CLOCK_SESSION;
        while session == CLOCK_SESSION && Instant::now() < deadline {
            let length = probe.hello(&mut outgoing).expect("encode hello");
            socket.send(&outgoing[..length]).expect("send hello");
            if let Ok(length) = socket.recv(&mut incoming) {
                if let Ok(id) = probe.accept_welcome(&incoming[..length]) {
                    session = id;
                }
            }
        }
        assert_ne!(session, CLOCK_SESSION, "the master never completed the handshake");

        while Instant::now() < deadline {
            let cycle = Instant::now();
            let local_send = clock.now();
            let length = probe.ping(&mut outgoing, local_send, 0).expect("encode ping");
            socket.send(&outgoing[..length]).expect("send ping");
            sent += 1;
            if let Ok(length) = socket.recv(&mut incoming) {
                let local_recv = clock.now();
                if let Some(pong) = probe.accept_pong(&incoming[..length], local_send) {
                    estimator.push(ProbeSample::from_pong(pong, local_send, local_recv));
                }
            }
            let elapsed = cycle.elapsed();
            let interval = Duration::from_millis(PING_INTERVAL_MS);
            if elapsed < interval {
                thread::sleep(interval - elapsed);
            }
        }

        let (served, rejected) = handler.join().expect("master thread");
        assert!(served > 0, "the master answered no pings");
        assert_eq!(rejected, 0, "every loopback ping was authenticated");
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
        // This is the transport smoke test, not the precision test: the
        // deterministic skewed-clock case above pins the drift to a few ppm.
        // Under a loaded suite a real loopback's midpoint jitter can move a
        // short fit by hundreds of ppm, so only a gross rate error fails here.
        assert!(
            estimate.drift_ppm.abs() < 2_000.0,
            "loopback drift {} ppm",
            estimate.drift_ppm
        );
    }
}
