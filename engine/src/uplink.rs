//! The master side of P4: a peer machine's input becomes a patchbay source.
//!
//! The clock probe (`peer.rs`) gives a peer a session and the audio bearer
//! (`bearing.rs`) carries its PCM16 over that session. This module is the
//! thread that joins the two to a patchbay source: it owns the UDP socket, a
//! [`ClockMaster`] with the session key, and one [`AudioReceiver`] per routed
//! `peer` source once that source's stream has been claimed. The patchbay pops
//! the ring the receiver fills exactly as it pops a `parec` input's ring, so the
//! audio callback never locks or waits.
//!
//! # Datagrams
//!
//! Every datagram has the 32-byte header `proto.rs` defines. A clock control
//! stream ([`STREAM_CLOCK_HELLO`] or [`STREAM_CLOCK_PING`]) is handed to the
//! [`ClockMaster`] and its WELCOME/PONG is sent back to the datagram's origin;
//! this is how a peer gets a session, because the master opens no second port.
//! An audio stream is `AUDIO_STREAM_BASE` + the source's **index in the
//! compiled plan**, so `phone` at index 0 is `0x1000`, index 1 is `0x1001`, and
//! so on. The receiver for that stream accepts the body only for its session,
//! its key and a mono (one-channel) payload.
//!
//! A datagram whose stream names no peer source, whose tag is wrong, whose
//! session is foreign, or that carries stereo samples is counted and dropped.
//! None of those is an error that stops the uplink.
//!
//! # The session is the peer id
//!
//! The 32-byte header already carries the session id the master issued in its
//! WELCOME, and that is the peer's identity on the wire: more than one peer
//! needs no new header field, so `proto::VERSION` stays where it is. The audio
//! stream selects the plan source ([`audio_stream`], the base plus the index),
//! and the authenticated HELLO names the stream its peer will feed. The master
//! records that claim with the session, because a `--send-take` is a new
//! process on a new ephemeral UDP port for every take: the endpoint changes
//! between takes, while the claimed stream does not.
//!
//! A source's receiver is built by the first authenticated audio datagram on
//! its stream, never by a WELCOME, so one peer's handshake cannot rebuild
//! another peer's receiver. A stream belongs to one session at a time. A
//! different session takes it over when it claimed that stream (the same peer
//! reconnecting, even from a new port), or — for a claimless clock-only session
//! — when the session that owns it is no longer live in the master's table (a
//! master restart or a lease expiry) or the datagram comes from the same UDP
//! endpoint. A session that claimed another stream is refused, and so is a
//! claimless session from another endpoint while a live peer owns the stream;
//! both are counted in `status.rejected`.
//!
//! A retried HELLO is answered with the session the master already issued, so
//! it never reaches this decision: the source keeps its receiver, buffered
//! audio, pull cursor and counters. A receiver is replaced only when a different
//! session legitimately takes the stream, and its counters are not reset: the
//! outgoing receiver's totals are folded into a running baseline, so `status`
//! stays truthful across a peer's periodic quiet-spell re-handshake.
//!
//! # Declared latency
//!
//! A plan's `peer` source may carry `latency_ms`: the peer's own capture and
//! pipeline delay. Positive means the peer's audio is late, so the receiver
//! subtracts that many master frames from every datagram's stamped position
//! ([`AudioReceiver::accept_shifted`]) and the source is placed that much
//! earlier. The declaration travels [`UplinkSourceSpec`] -> [`UplinkSource`], is
//! converted to frames once at the engine's rate, and is reported per source.
//! A local `input` keeps its declaration in the plan but is not shifted here
//! yet; the plan's `latency_ms` on any other kind is ignored rather than
//! refused.
//!
//! # Pacing
//!
//! The thread reads a playback head that trails the master clock by each
//! source's buffer ([`PULL_BUFFER_FRAMES`] unless the plan declares more). It
//! wakes every [`PULL_INTERVAL_MS`] and pulls, per source, the frames the cursor
//! is behind that head by, never past it, with [`AudioReceiver::pull_to`]. One
//! process-wide [`InstantClock`] is shared with the [`ClockMaster`], so the fitted
//! `master_sample` a peer stamps its datagrams with and the head are the same
//! domain. Because the head never reaches a position until a datagram stamped
//! there has had the buffer's frames to arrive, a delayed or reordered datagram
//! is placed before its position is due instead of being refused as already
//! read. A full ring counts the frames the producer dropped.
//!
//! No key is ever logged or put in status.

use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::bearing::{
    audio_stream, is_audio_stream, Accepted, AudioReceiver, BearerError, PullReport, RecvCounters,
    DEFAULT_JITTER_FRAMES, MAX_DATAGRAM_LEN,
};
use crate::peer::{Clock, ClockMaster, InstantClock, STREAM_CLOCK_HELLO, STREAM_CLOCK_PING};
use crate::proto;
use crate::monbus::Producer;

/// How many frames one wake pulls for each source. At 48 kHz this is one 10 ms
/// block, the same quantum the P3 bearer's datagrams are sized around.
pub const PULL_FRAMES: usize = 480;

/// The most frames one wake may pull. A delayed wake (a burst drained, or a
/// stall) catches up instead of dropping its backlog, but never dumps more
/// than four 10 ms blocks at once.
pub const PULL_MAX_FRAMES: usize = 4 * PULL_FRAMES;

/// How long the uplink thread sleeps between drains and pulls.
pub const PULL_INTERVAL_MS: u64 = 10;

/// The default read buffer, and the shortest one: a real jitter buffer.
///
/// A source's cursor never reads a position newer than `now - buffer`, so a
/// datagram delayed or reordered by up to this much slack is placed when it
/// arrives rather than lost because the cursor already read past it.
///
/// It is one jitter window ([`DEFAULT_JITTER_FRAMES`], about 85 ms at 48 kHz),
/// and it is what a source that declares no `buffer_ms` reads with. The sender
/// keeps the least-delayed exchange for five seconds, so a block's stamp no
/// longer swings with the path's queue depth; the pipeline it still pays is one
/// block plus the path's floor, and a window leaves an ordinary reorder room
/// after that. Half a window (43 ms) measured below the pipeline on the live
/// laptop → table path: a 10 s take at 2048 was late on nearly every datagram,
/// so one window is the floor. A path with more floor than that (a deck on
/// Wi-Fi) declares its own, longer buffer in the plan.
pub const PULL_BUFFER_FRAMES: usize = DEFAULT_JITTER_FRAMES;

/// The longest read buffer the uplink will run, in milliseconds: the same
/// two-second bound the plan parser puts on a peer's `buffer_ms`, checked again
/// here so a caller that builds a source directly cannot allocate an unbounded
/// receiver window.
pub const PULL_BUFFER_MAX_MS: f64 = 2_000.0;

/// The receiver window a source allocates: four jitter windows, or twice its
/// read buffer when that is longer, so a datagram ahead of the cursor still
/// fits when a burst drains (a stalled wake may hand the sender a burst of up
/// to [`PULL_MAX_FRAMES`]). A longer buffer is why this is no longer a
/// constant: the window must cover the buffer the source actually reads.
pub const PULL_WINDOW_FRAMES: usize = 4 * DEFAULT_JITTER_FRAMES;

/// Where the uplink listens and the key every datagram is authenticated with.
/// It has no `Debug` derivation on purpose: the key must never reach a log line
/// or a status object.
#[derive(Clone)]
pub struct UplinkConfig {
    /// The UDP address to bind. `0.0.0.0:7060` is the house's usual choice;
    /// `127.0.0.1:0` is what a test uses.
    pub bind: SocketAddr,
    /// The same 32-byte key the peer's clock probe uses.
    pub key: [u8; 32],
}

/// One peer source's counters, as `status` reports them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct UplinkSourceStatus {
    /// The source's index in the compiled plan, which is also its stream id's
    /// offset from `AUDIO_STREAM_BASE`.
    pub index: usize,
    /// The plan's node id.
    pub id: String,
    /// The plan's declared capture/pipeline latency, in milliseconds. Zero
    /// when the plan declares none.
    pub latency_ms: f64,
    /// The same declaration in master frames: how far earlier this source's
    /// audio is placed than the stamp on the wire.
    pub latency_frames: u64,
    /// The read buffer this source actually runs, in milliseconds: its
    /// `buffer_ms` declaration, or the engine floor ([`PULL_BUFFER_FRAMES`])
    /// when it declares none or too little.
    pub buffer_ms: f64,
    /// The same buffer in master frames: how far behind the clock this
    /// source's read cursor trails.
    pub buffer_frames: u64,
    /// The codec the attached session sends (`pcm16` or `pcm16k`), or empty
    /// before audio arrives. A deck is `pcm16k`: 16 kHz expanded to the master's
    /// 48 kHz timeline on receive.
    pub codec: String,
    /// Authenticated datagrams that arrived, including late ones.
    pub received: u64,
    /// Duplicates and datagrams whose payload was already read.
    pub late: u64,
    /// Silent frames emitted to cover holes, in the receiver's timeline.
    pub concealed: u64,
    /// Frames the producer could not place because the ring was full.
    pub dropped: u64,
    /// The master position of the last pulled block.
    pub last_master: u64,
    /// The next master position the receiver will pull. Read with `first_master`
    /// and the clock it tells whether the read cursor has run ahead of the
    /// datagrams that are still arriving.
    pub next_master: u64,
    /// The first placed datagram's start: where this session's timeline begins
    /// on the master clock. Zero before audio arrives.
    pub first_master: u64,
    /// The last pull concealed frames because of the deadline, not because a
    /// later datagram proved a hole.
    pub from_deadline: bool,
}

impl UplinkSourceStatus {
    fn json(&self) -> String {
        format!(
            "{{\"index\":{},\"id\":\"{}\",\"latency_ms\":{},\"latency_frames\":{},\"buffer_ms\":{},\"buffer_frames\":{},\"codec\":\"{}\",\"received\":{},\"late\":{},\"concealed\":{},\"dropped\":{},\"last_master\":{},\"next_master\":{},\"first_master\":{},\"from_deadline\":{}}}",
            self.index,
            crate::loopback::json_escape(&self.id),
            self.latency_ms,
            self.latency_frames,
            self.buffer_ms,
            self.buffer_frames,
            self.codec,
            self.received,
            self.late,
            self.concealed,
            self.dropped,
            self.last_master,
            self.next_master,
            self.first_master,
            self.from_deadline
        )
    }
}

/// What `status` reports for the uplink as a whole.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct UplinkStatus {
    /// `off` when no uplink is configured, `idle` while configured but no patch
    /// with a peer source is running, `running` while the thread owns a bound
    /// socket, `error` when the bind failed, and `off` again after the patch
    /// ends.
    pub state: &'static str,
    /// The address the socket actually bound (with port 0 resolved), or empty
    /// when there is no socket.
    pub bind: String,
    /// Why the bind failed, when `state` is `error`. Empty otherwise.
    pub error: String,
    /// Sessions the clock master has issued (a retried HELLO for the session it
    /// already issued does not count). This is a lifetime count, not the number
    /// of sources currently attached: a session is issued before its peer's
    /// first audio datagram claims a stream.
    pub sessions: u64,
    /// Datagrams dropped before they were placed: an unknown stream, a failed
    /// tag/session check, a malformed header, a stereo payload, or a session
    /// that tried to take a stream another live session owns.
    pub rejected: u64,
    /// One entry per peer source on this machine.
    pub sources: Vec<UplinkSourceStatus>,
}

impl UplinkStatus {
    /// No uplink was asked for.
    pub fn off() -> Self {
        UplinkStatus {
            state: "off",
            ..UplinkStatus::default()
        }
    }

    /// An uplink is configured but no patch with a peer source is running.
    pub fn idle() -> Self {
        UplinkStatus {
            state: "idle",
            ..UplinkStatus::default()
        }
    }

    /// The bind could not happen. The rest of the engine still runs.
    pub fn failed(error: impl Into<String>) -> Self {
        UplinkStatus {
            state: "error",
            error: error.into(),
            ..UplinkStatus::default()
        }
    }

    /// The JSON fragment `status` splices into its line.
    pub fn json(&self) -> String {
        let sources = self
            .sources
            .iter()
            .map(UplinkSourceStatus::json)
            .collect::<Vec<String>>()
            .join(",");
        format!(
            "{{\"state\":\"{}\",\"bind\":\"{}\",\"error\":\"{}\",\"sessions\":{},\"rejected\":{},\"sources\":[{}]}}",
            self.state,
            crate::loopback::json_escape(&self.bind),
            crate::loopback::json_escape(&self.error),
            self.sessions,
            self.rejected,
            sources
        )
    }
}

/// What one audio datagram did to a source: the ownership decision for its
/// stream and, when it was placed, what the receiver did with it.
///
/// [`UplinkSource::offer`] takes the two liveness answers the thread reads from
/// its [`ClockMaster`], so the multi-peer rule is tested without a socket.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Offer {
    /// The session already owned the stream; the receiver placed the datagram,
    /// or counted it as late.
    Placed(Accepted),
    /// A new session took the stream and its first datagram was placed.
    Taken(Accepted),
    /// Another session owns the stream and is still live: the datagram was
    /// dropped and the owner is untouched.
    Occupied,
    /// The datagram did not authenticate, or named a session this master did
    /// not issue (or has forgotten); nothing was attached.
    Refused(BearerError),
}

/// One routed peer source and the ring that carries its samples to the patch.
///
/// It is public so a test can drive the exact code the thread drives (offer a
/// datagram, pull with a deadline) without a socket.
pub struct UplinkSource {
    index: usize,
    id: String,
    stream: u16,
    producer: Producer,
    /// The plan's declared capture/pipeline latency, in milliseconds. Positive
    /// means the peer's audio is late, so [`Self::shift_frames`] moves its
    /// placement that much earlier on the master timeline.
    latency_ms: f64,
    /// The same declaration in master frames, computed once from the engine's
    /// rate: the number every datagram's placement is shifted by.
    shift_frames: u64,
    /// How far behind the master clock this source's read cursor trails, in
    /// master frames. The plan's `buffer_ms`, raised to at least one jitter
    /// window, so a path that delivers late datagrams still has them placed
    /// instead of concealed.
    buffer_frames: usize,
    /// The same buffer in milliseconds, after the floor and ceiling are
    /// applied: what `status` reports, so a plan that asked for less than the
    /// floor says what it actually got.
    buffer_ms: f64,
    /// `None` until the first authenticated audio datagram claims the stream
    /// with a session the master issued. A WELCOME does not attach a receiver.
    receiver: Option<AudioReceiver>,
    /// The session the current receiver belongs to. A retried HELLO gets the
    /// same session back, and its audio must not replace the receiver that is
    /// already filling.
    session: Option<u32>,
    /// The UDP endpoint that claimed the current session. A claimed stream is
    /// the peer's identity; the endpoint is only the fallback for a claimless
    /// clock-only session, where a new session from the same endpoint is that
    /// peer re-handshaking and one from another endpoint is a second peer.
    origin: Option<SocketAddr>,
    /// Reused conversion buffers; a wake allocates nothing.
    pull_i16: Vec<i16>,
    pull_f32: Vec<f32>,
    /// Every replaced receiver's counters, folded in by [`Self::offer`], so a
    /// re-handshake does not restart the house's totals.
    past: RecvCounters,
    dropped: u64,
    /// The last pull report. Kept across a re-handshake: it names a position on
    /// the one master clock, which a new session does not change, so clearing it
    /// would only make `last_master` blink without telling the house anything
    /// false.
    last: Option<PullReport>,
}

/// Convert a declared latency in milliseconds to whole master frames, rounded
/// to the nearest frame. A non-positive or non-finite value is no latency; the
/// plan parser refuses those for a peer, so this is only a safe floor for a
/// caller that builds a source directly.
fn latency_frames(latency_ms: f64, rate: u32) -> u64 {
    if !latency_ms.is_finite() || latency_ms <= 0.0 {
        return 0;
    }
    ((latency_ms / 1_000.0) * f64::from(rate)).round() as u64
}

/// Convert a declared read buffer in milliseconds to whole master frames. No
/// declaration (zero, negative or non-finite) means [`PULL_BUFFER_FRAMES`], the
/// engine floor, and a declaration shorter than the floor is raised to it: the
/// pipeline below that is already known to be late on every datagram. A longer
/// one is honoured up to [`PULL_BUFFER_MAX_MS`], the same bound the plan parser
/// puts on `buffer_ms`.
fn buffer_frames(buffer_ms: f64, rate: u32) -> usize {
    let frames = if !buffer_ms.is_finite() || buffer_ms <= 0.0 {
        PULL_BUFFER_FRAMES
    } else {
        ((buffer_ms / 1_000.0) * f64::from(rate)).round() as usize
    };
    let ceiling = ((PULL_BUFFER_MAX_MS / 1_000.0) * f64::from(rate)).round() as usize;
    frames.clamp(PULL_BUFFER_FRAMES, ceiling.max(PULL_BUFFER_FRAMES))
}

impl UplinkSource {
    /// A source for plan index `index`, fed to `producer`. Its stream id is
    /// [`audio_stream(index)`], which is exactly `AUDIO_STREAM_BASE + index`.
    pub fn new(index: usize, id: String, producer: Producer) -> Result<Self, String> {
        Self::build(index, id, producer, 0.0, 0, PULL_BUFFER_FRAMES, 0.0)
    }

    /// A source that is `latency_ms` late, placed `latency_ms` earlier on the
    /// master timeline. `rate` is the master's sample rate, so the declaration
    /// is converted to frames once here instead of on every datagram. The read
    /// buffer is the engine default.
    pub fn with_latency(
        index: usize,
        id: String,
        producer: Producer,
        latency_ms: f64,
        rate: u32,
    ) -> Result<Self, String> {
        Self::with_latency_and_buffer(index, id, producer, latency_ms, None, rate)
    }

    /// A source that is `latency_ms` late and whose read cursor trails the
    /// clock by `buffer_ms` (`None`, non-positive or non-finite takes the
    /// engine floor; a declaration beyond two seconds is clamped to it).
    pub fn with_latency_and_buffer(
        index: usize,
        id: String,
        producer: Producer,
        latency_ms: f64,
        buffer_ms: Option<f64>,
        rate: u32,
    ) -> Result<Self, String> {
        let shift = latency_frames(latency_ms, rate);
        let frames = buffer_frames(buffer_ms.unwrap_or(0.0), rate);
        let effective_ms = frames as f64 * 1_000.0 / f64::from(rate);
        Self::build(index, id, producer, latency_ms, shift, frames, effective_ms)
    }

    fn build(
        index: usize,
        id: String,
        producer: Producer,
        latency_ms: f64,
        shift_frames: u64,
        buffer_frames: usize,
        buffer_ms: f64,
    ) -> Result<Self, String> {
        let stream = audio_stream(index)
            .ok_or_else(|| format!("peer source {id} at index {index} has no audio stream id"))?;
        Ok(UplinkSource {
            index,
            id,
            stream,
            producer,
            latency_ms,
            shift_frames,
            buffer_frames,
            buffer_ms,
            receiver: None,
            session: None,
            origin: None,
            pull_i16: vec![0; PULL_MAX_FRAMES],
            pull_f32: vec![0.0; PULL_MAX_FRAMES * 2],
            past: RecvCounters::default(),
            dropped: 0,
            last: None,
        })
    }

    /// The stream this source listens on.
    pub fn stream(&self) -> u16 {
        self.stream
    }

    /// The plan's node id.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The plan's declared latency for this source, in milliseconds.
    pub fn latency_ms(&self) -> f64 {
        self.latency_ms
    }

    /// The same declaration in master frames: how far earlier than the
    /// datagram's stamp this source is placed.
    pub fn shift_frames(&self) -> u64 {
        self.shift_frames
    }

    /// The read buffer this source runs, in master frames.
    pub fn buffer_frames(&self) -> usize {
        self.buffer_frames
    }

    /// The read buffer this source runs, in milliseconds.
    pub fn buffer_ms(&self) -> f64 {
        self.buffer_ms
    }

    /// The receiver window this source allocates. It covers the read buffer
    /// twice over, so a datagram that arrives ahead of the cursor always fits
    /// even when a stalled wake hands the sender a burst.
    fn window_frames(&self) -> usize {
        PULL_WINDOW_FRAMES.max(2 * self.buffer_frames)
    }

    /// The session that owns this stream, if any.
    pub fn session(&self) -> Option<u32> {
        self.session
    }

    /// Whether a session has claimed the stream and a receiver exists.
    pub fn has_session(&self) -> bool {
        self.receiver.is_some()
    }

    /// Offer one audio datagram to this stream.
    ///
    /// `owner_live` says whether the session that already owns the stream is
    /// still in the master's table; `session_live` whether the datagram's
    /// session is; `claim` is the audio stream that session declared in its
    /// HELLO. The thread reads all three from its [`ClockMaster`], so the
    /// source does not keep a second copy of the lease or the claims.
    ///
    /// A datagram for the owning session is the ordinary path and never
    /// rebuilds anything: that is what makes a retried HELLO (which the master
    /// answers with the session it already issued) harmless.
    ///
    /// A different live session takes the stream only if it claimed this
    /// source's stream. The claim is the peer's stable identity: every
    /// `--send-take` is a new process on a new ephemeral port, so the endpoint
    /// changes between takes while the stream does not. A session claiming a
    /// different stream is refused. A claimless (clock-only) session keeps the
    /// older endpoint fallback: it may feed a dead or same-endpoint stream but
    /// may not evict a live peer from another endpoint. Either way a candidate
    /// receiver authenticates the datagram before it replaces anything, so a
    /// forged or stale datagram cannot evict a live peer.
    pub fn offer(
        &mut self,
        key: [u8; 32],
        session: u32,
        origin: SocketAddr,
        owner_live: bool,
        session_live: bool,
        claim: Option<u16>,
        datagram: &[u8],
    ) -> Offer {
        if self.session == Some(session) && self.receiver.is_some() {
            return match self.accept(datagram) {
                Ok(accepted) => Offer::Placed(accepted),
                Err(error) => Offer::Refused(error),
            };
        }
        // The session is the peer id, so the id must be one this master
        // minted: an unknown or lease-expired session cannot claim a stream.
        if !session_live {
            return Offer::Refused(BearerError::Session(session));
        }
        match claim {
            // A declared stream identifies the peer without the endpoint. It
            // may take its own source over at once, even while the previous
            // session is live and from another port.
            Some(claimed) if claimed == self.stream => {}
            // A session that declared another stream is not this source's
            // peer, live owner or not.
            Some(claimed) => return Offer::Refused(BearerError::Stream(claimed)),
            // Clock-only sessions fall back to the endpoint rule: a live owner
            // still keeps its stream from a different endpoint.
            None => {
                if owner_live && self.origin != Some(origin) {
                    return Offer::Occupied;
                }
            }
        }
        let mut candidate = match AudioReceiver::new(
            key,
            session,
            self.stream,
            1,
            self.window_frames(),
        ) {
            Ok(receiver) => receiver,
            Err(error) => return Offer::Refused(error),
        };
        // The candidate is built for this source, so its placement carries the
        // same declared shift as an already-attached receiver.
        let accepted = match candidate.accept_shifted(datagram, self.shift_frames) {
            Ok(accepted) => accepted,
            Err(error) => return Offer::Refused(error),
        };
        if let Some(receiver) = self.receiver.take() {
            self.past = add_counters(self.past, receiver.counters());
        }
        self.receiver = Some(candidate);
        self.session = Some(session);
        self.origin = Some(origin);
        Offer::Taken(accepted)
    }

    /// Authenticate and place one audio datagram. `Err` covers a wrong tag, a
    /// foreign session, a stereo/non-mono payload and the bounded-window
    /// refusal; the caller counts it and carries on.
    pub fn accept(&mut self, datagram: &[u8]) -> Result<Accepted, BearerError> {
        self.accept_shifted(datagram, self.shift_frames)
    }

    /// Authenticate and place one audio datagram, shifted `shift` frames
    /// earlier. The source's own `accept` uses its declared shift; the
    /// parameter exists so a caller (and a test) can ask for a different
    /// placement without building a second source.
    pub fn accept_shifted(
        &mut self,
        datagram: &[u8],
        shift: u64,
    ) -> Result<Accepted, BearerError> {
        match self.receiver.as_mut() {
            Some(receiver) => receiver.accept_shifted(datagram, shift),
            // No session has claimed this stream, so there is nothing to
            // authenticate the datagram for.
            None => Err(BearerError::Session(0)),
        }
    }

    /// Pull `frames` (at most [`PULL_MAX_FRAMES`]) master-time frames and push them to the ring as
    /// interleaved stereo f32. A mono peer sample is placed in both channels;
    /// the patchbay reads the left one, the same way it reads a `parec` input.
    ///
    /// `None` means no session has been issued yet, so there is nothing to
    /// pull. A full ring is counted in `dropped`, never an error.
    pub fn pump(&mut self, frames: usize, now_master: i64) -> Option<PullReport> {
        let frames = frames.clamp(1, self.pull_i16.len());
        let report = {
            let receiver = self.receiver.as_mut()?;
            receiver.pull_at(&mut self.pull_i16, frames, now_master)
        };
        Some(self.deliver(report))
    }

    /// Pull up to the playback head `head_master`, never past it.
    ///
    /// The head trails the master clock by this source's buffer
    /// ([`Self::buffer_frames`]), so this is the paced read the uplink thread
    /// runs: it asks for exactly the frames the cursor is behind the head by
    /// (at most [`PULL_MAX_FRAMES`]), and [`AudioReceiver::pull_to`] conceals
    /// only what is genuinely due at the head. `None` means no session exists,
    /// audio has not started, or the head has not advanced past the cursor.
    pub fn pump_to(&mut self, head_master: u64) -> Option<PullReport> {
        let report = {
            let receiver = self.receiver.as_mut()?;
            if !receiver.started() || head_master <= receiver.next_master() {
                return None;
            }
            let want = (head_master - receiver.next_master()).min(PULL_MAX_FRAMES as u64) as usize;
            receiver.pull_to(&mut self.pull_i16, want, head_master)
        };
        Some(self.deliver(report))
    }

    /// Convert a pull report to stereo f32 and push it to the ring.
    fn deliver(&mut self, report: PullReport) -> PullReport {
        self.last = Some(report);
        if report.frames == 0 {
            return report;
        }
        for frame in 0..report.frames {
            let sample = f32::from(self.pull_i16[frame]) / 32_768.0;
            self.pull_f32[frame * 2] = sample;
            self.pull_f32[frame * 2 + 1] = sample;
        }
        let dropped = self
            .producer
            .push(&self.pull_f32[..report.frames * 2]);
        self.dropped += dropped as u64;
        report
    }

    /// The counters for every session this source has carried, or zeroes before
    /// a session exists.
    ///
    /// A re-handshake replaces the receiver, not the totals: `past` holds what
    /// the replaced receivers counted, and this returns that plus the current
    /// receiver's own counters. `received`, `late` and `concealed` therefore
    /// never go backwards when a peer re-handshakes.
    pub fn counters(&self) -> RecvCounters {
        let session = self
            .receiver
            .as_ref()
            .map(AudioReceiver::counters)
            .unwrap_or_default();
        add_counters(self.past, session)
    }

    /// This source's `status` entry.
    pub fn status(&self) -> UplinkSourceStatus {
        let counters = self.counters();
        let (next_master, first_master) = match self.receiver.as_ref() {
            Some(receiver) => (receiver.next_master(), receiver.first_master()),
            None => (0, 0),
        };
        let codec = match self.receiver.as_ref().and_then(AudioReceiver::codec) {
            Some(proto::Codec::Pcm16) => "pcm16",
            Some(proto::Codec::Pcm16k) => "pcm16k",
            Some(_) => "other",
            None => "",
        };
        UplinkSourceStatus {
            index: self.index,
            id: self.id.clone(),
            latency_ms: self.latency_ms,
            latency_frames: self.shift_frames,
            buffer_ms: self.buffer_ms,
            buffer_frames: self.buffer_frames as u64,
            codec: codec.to_string(),
            received: counters.received,
            late: counters.late,
            concealed: counters.concealed_frames,
            dropped: self.dropped,
            last_master: self.last.map_or(0, |report| report.master_sample),
            next_master,
            first_master,
            from_deadline: self.last.is_some_and(|report| report.from_deadline),
        }
    }
}

/// Add two counter snapshots field by field, saturating at `u64::MAX` so a
/// lifetime's total can never wrap into a smaller, untrue number.
fn add_counters(base: RecvCounters, session: RecvCounters) -> RecvCounters {
    RecvCounters {
        received: base.received.saturating_add(session.received),
        rejected: base.rejected.saturating_add(session.rejected),
        out_of_order: base.out_of_order.saturating_add(session.out_of_order),
        late: base.late.saturating_add(session.late),
        gaps: base.gaps.saturating_add(session.gaps),
        concealed_frames: base.concealed_frames.saturating_add(session.concealed_frames),
    }
}

/// One source the caller wants the uplink to feed.
pub struct UplinkSourceSpec {
    /// The source's index in the compiled plan (and its stream offset).
    pub index: usize,
    /// The plan's node id, for status.
    pub id: String,
    /// The ring's producer. The patchbay holds the matching consumer.
    pub producer: Producer,
    /// The plan's declared capture/pipeline latency, in milliseconds. The
    /// source is placed this much earlier on the master timeline; zero for a
    /// source that declares none.
    pub latency_ms: f64,
    /// The plan's declared read buffer, in milliseconds: how far behind the
    /// clock this source is read. `None` takes the engine floor.
    pub buffer_ms: Option<f64>,
}

/// The running uplink thread and the status it publishes.
pub struct Uplink {
    status: Arc<Mutex<UplinkStatus>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    local_addr: SocketAddr,
}

impl Uplink {
    /// Bind, publish `running`, and start the thread. A bind failure is an
    /// `Err` so the caller can report it without stopping the engine.
    ///
    /// `status` is the server's shared object; the thread writes a fresh
    /// snapshot into it every wake, so `status` is truthful without a second
    /// lock on the audio path.
    pub fn start(
        config: &UplinkConfig,
        rate: u32,
        status: Arc<Mutex<UplinkStatus>>,
        specs: Vec<UplinkSourceSpec>,
    ) -> Result<Uplink, String> {
        let mut sources = Vec::with_capacity(specs.len());
        for spec in specs {
            sources.push(UplinkSource::with_latency_and_buffer(
                spec.index,
                spec.id,
                spec.producer,
                spec.latency_ms,
                spec.buffer_ms,
                rate,
            )?);
        }

        let socket = UdpSocket::bind(config.bind)
            .map_err(|error| format!("cannot bind the uplink on {}: {error}", config.bind))?;
        let local_addr = socket
            .local_addr()
            .unwrap_or(config.bind);
        socket
            .set_nonblocking(true)
            .map_err(|error| format!("cannot make the uplink socket non-blocking: {error}"))?;

        let bound = local_addr.to_string();
        {
            let mut current = status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *current = UplinkStatus {
                state: "running",
                bind: bound.clone(),
                sessions: 0,
                rejected: 0,
                sources: sources.iter().map(UplinkSource::status).collect(),
                ..UplinkStatus::default()
            };
        }

        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread_status = Arc::clone(&status);
        let key = config.key;
        let handle = thread::Builder::new()
            .name("jawn-audio-uplink".to_string())
            .spawn(move || {
                run_uplink(socket, key, rate, sources, thread_stop, thread_status);
            })
            .map_err(|error| format!("cannot start the uplink thread: {error}"))?;

        Ok(Uplink {
            status,
            stop,
            handle: Some(handle),
            local_addr,
        })
    }

    /// The address the socket actually bound.
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// A snapshot of the shared status.
    pub fn status(&self) -> UplinkStatus {
        self.status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// The shared status object, so the server can keep reading it after this
    /// handle is dropped.
    pub fn status_arc(&self) -> Arc<Mutex<UplinkStatus>> {
        Arc::clone(&self.status)
    }

    /// Stop the thread and wait for it. Idempotent.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Uplink {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The thread: drain datagrams, pull every source, publish, sleep.
fn run_uplink(
    socket: UdpSocket,
    key: [u8; 32],
    rate: u32,
    mut sources: Vec<UplinkSource>,
    stop: Arc<AtomicBool>,
    status: Arc<Mutex<UplinkStatus>>,
) {
    // One clock for both roles. The master stamps its pongs from it and the
    // playback head below is derived from it, so a peer's fitted master position
    // and this read are the same timeline.
    let clock = InstantClock::new(rate);
    let mut master = ClockMaster::new(key);
    let mut rejected = 0u64;
    let mut buffer = [0u8; MAX_DATAGRAM_LEN];
    let mut reply = [0u8; MAX_DATAGRAM_LEN];
    let bound = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .bind
        .clone();

    while !stop.load(Ordering::SeqCst) {
        // Drain everything the socket holds. A non-blocking read is the whole
        // wait: the sleep below is the pacing, so a burst does not become one
        // datagram per 10 ms.
        loop {
            match socket.recv_from(&mut buffer) {
                Ok((length, origin)) => dispatch(
                    &socket,
                    &buffer[..length],
                    origin,
                    &key,
                    &mut master,
                    &clock,
                    &mut sources,
                    &mut rejected,
                    &mut reply,
                ),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    rejected += 1;
                    break;
                }
            }
        }

        let now = clock.now();
        // Read behind the clock by each source's own buffer: a path with more
        // floor than the default (a deck on Wi-Fi) declares a longer one, and
        // pays for it only on its own channel. Each source pulls exactly the
        // frames its cursor is behind its head by, so a wake that could not
        // fill its block carries the remainder into the next wake instead of
        // discarding it, and no datagram is read before it has had the
        // buffer's time to arrive.
        for source in &mut sources {
            let head = now.saturating_sub(source.buffer_frames() as u64);
            source.pump_to(head);
        }

        publish(&status, &bound, master.issued(), rejected, &sources, "running");
        thread::sleep(Duration::from_millis(PULL_INTERVAL_MS));
    }

    publish(&status, "", master.issued(), rejected, &sources, "off");
}

/// Publish one snapshot. The audio path never calls this; only the uplink
/// thread does, once per wake.
fn publish(
    status: &Arc<Mutex<UplinkStatus>>,
    bound: &str,
    sessions: u64,
    rejected: u64,
    sources: &[UplinkSource],
    state: &'static str,
) {
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut next = UplinkStatus {
        state,
        bind: bound.to_string(),
        sessions,
        rejected,
        sources: sources.iter().map(UplinkSource::status).collect(),
        ..UplinkStatus::default()
    };
    if state == "off" {
        next.sources.clear();
    }
    *current = next;
}

/// One datagram: clock control to the master, audio to its source, everything
/// else counted and dropped.
#[allow(clippy::too_many_arguments)]
fn dispatch(
    socket: &UdpSocket,
    datagram: &[u8],
    origin: SocketAddr,
    key: &[u8; 32],
    master: &mut ClockMaster,
    clock: &dyn Clock,
    sources: &mut [UplinkSource],
    rejected: &mut u64,
    reply: &mut [u8],
) {
    let header = match proto::decode(datagram) {
        Ok((header, _)) => header,
        Err(_) => {
            *rejected += 1;
            return;
        }
    };

    match header.stream {
        STREAM_CLOCK_HELLO | STREAM_CLOCK_PING => {
            let answered = master.answer(datagram, clock, reply);
            let Some(answer) = answered else {
                *rejected += 1;
                return;
            };
            let length = answer.length();
            let _ = socket.send_to(&reply[..length], origin);
            // A WELCOME issues a session, and that is all the thread does with
            // it: the session is the peer id, and each stream is claimed by
            // that peer's first authenticated audio datagram. Attaching here
            // would let one peer's handshake rebuild another peer's receiver.
        }
        stream if is_audio_stream(stream) => {
            let Some(source) = sources
                .iter_mut()
                .find(|source| source.stream() == stream)
            else {
                *rejected += 1;
                return;
            };
            // The answers the source's claim rule needs, read from the one
            // session table: whether the stream's owner is still live, whether
            // the datagram's session is one this master issued, and the stream
            // that session claimed in its HELLO.
            let owner_live = source.session().is_some_and(|owner| master.is_live(owner));
            let session_live = master.is_live(header.session);
            let claim = master.session_claim(header.session);
            match source.offer(
                *key,
                header.session,
                origin,
                owner_live,
                session_live,
                claim,
                datagram,
            ) {
                Offer::Placed(_) | Offer::Taken(_) => {}
                // A second peer on a live stream, an unissued session, or a
                // datagram that did not authenticate: dropped and counted.
                Offer::Occupied | Offer::Refused(_) => *rejected += 1,
            }
        }
        _ => *rejected += 1,
    }
}
