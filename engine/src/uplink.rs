//! The master side of P4: a peer machine's input becomes a patchbay source.
//!
//! The clock probe (`peer.rs`) gives a peer a session and the audio bearer
//! (`bearing.rs`) carries its PCM16 over that session. This module is the
//! thread that joins the two to a patchbay source: it owns the UDP socket, a
//! [`ClockMaster`] with the session key, and one [`AudioReceiver`] per routed
//! `peer` source. The patchbay pops the ring the receiver fills exactly as it
//! pops a `parec` input's ring, so the audio callback never locks or waits.
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
//! # One session at a time
//!
//! P3/P4's first slice is one peer. When a WELCOME issues a session, every
//! source's receiver is rebuilt with that session id, so a re-handshake (or a
//! master restart on the other side) starts a clean timeline. The received,
//! late and concealed totals are not reset: each rebuild folds the outgoing
//! receiver's counters into the source's running total, so `status` stays
//! truthful across a peer's periodic quiet-spell re-handshake. Multiple peers
//! need a peer id in the stream id or in a session map before two sessions may
//! live at once; this module deliberately does not pretend otherwise.
//!
//! # Pacing
//!
//! The thread reads a playback head that trails the master clock by
//! [`PULL_BUFFER_FRAMES`], a real jitter buffer. It wakes every
//! [`PULL_INTERVAL_MS`] and pulls, per source, the frames the cursor is behind
//! that head by, never past it, with [`AudioReceiver::pull_to`]. One process-wide
//! [`InstantClock`] is shared with the [`ClockMaster`], so the fitted
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
use crate::peer::{
    self, Clock, ClockMaster, InstantClock, STREAM_CLOCK_HELLO, STREAM_CLOCK_PING,
};
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

/// How far behind the master clock the read cursor runs: a real jitter buffer.
///
/// The cursor never reads a position newer than `now - PULL_BUFFER_FRAMES`, so
/// a datagram delayed or reordered by up to this much slack is placed when it
/// arrives rather than lost because the cursor already read past it.
///
/// It is one jitter window ([`DEFAULT_JITTER_FRAMES`], about 85 ms at 48 kHz).
/// The sender now keeps the least-delayed exchange for five seconds, so a
/// block's stamp no longer swings with the path's queue depth; the pipeline it
/// still pays is one block plus the path's floor, and a window leaves an
/// ordinary reorder room after that. Two windows cost 171 ms of placement
/// latency for slack the stable stamp no longer needs. Half a window (43 ms)
/// measured below the pipeline on the live laptop → table path: a 10 s take at
/// 2048 was late on nearly every datagram, so one window is the floor.
pub const PULL_BUFFER_FRAMES: usize = DEFAULT_JITTER_FRAMES;

/// The receiver window the uplink allocates: four jitter windows, independent
/// of the read buffer so a datagram ahead of the cursor still fits when a burst
/// drains (a stalled wake may hand the sender a burst of up to
/// [`PULL_MAX_FRAMES`]).
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
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UplinkSourceStatus {
    /// The source's index in the compiled plan, which is also its stream id's
    /// offset from `AUDIO_STREAM_BASE`.
    pub index: usize,
    /// The plan's node id.
    pub id: String,
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
            "{{\"index\":{},\"id\":\"{}\",\"received\":{},\"late\":{},\"concealed\":{},\"dropped\":{},\"last_master\":{},\"next_master\":{},\"first_master\":{},\"from_deadline\":{}}}",
            self.index,
            crate::loopback::json_escape(&self.id),
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
#[derive(Clone, Debug, Default, PartialEq, Eq)]
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
    /// Sessions issued (a retried HELLO for the session already attached does
    /// not count). A new session rebuilds every source's receiver.
    pub sessions: u64,
    /// Datagrams dropped before they reached a source: an unknown stream, a
    /// failed tag/session check, a malformed header or a stereo payload.
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

/// One routed peer source and the ring that carries its samples to the patch.
///
/// It is public so a test can drive the exact code the thread drives (attach a
/// session, accept a datagram, pull with a deadline) without a socket.
pub struct UplinkSource {
    index: usize,
    id: String,
    stream: u16,
    producer: Producer,
    /// `None` until a WELCOME issues a session.
    receiver: Option<AudioReceiver>,
    /// The session the current receiver belongs to. A retried HELLO gets the
    /// same session back, and its WELCOME must not replace the receiver that is
    /// already filling with audio.
    session: Option<u32>,
    /// Reused conversion buffers; a wake allocates nothing.
    pull_i16: Vec<i16>,
    pull_f32: Vec<f32>,
    /// Every replaced receiver's counters, folded in by [`Self::attach_session`],
    /// so a re-handshake does not restart the house's totals.
    past: RecvCounters,
    dropped: u64,
    /// The last pull report. Kept across a re-handshake: it names a position on
    /// the one master clock, which a new session does not change, so clearing it
    /// would only make `last_master` blink without telling the house anything
    /// false.
    last: Option<PullReport>,
}

impl UplinkSource {
    /// A source for plan index `index`, fed to `producer`. Its stream id is
    /// [`audio_stream(index)`], which is exactly `AUDIO_STREAM_BASE + index`.
    pub fn new(index: usize, id: String, producer: Producer) -> Result<Self, String> {
        let stream = audio_stream(index)
            .ok_or_else(|| format!("peer source {id} at index {index} has no audio stream id"))?;
        Ok(UplinkSource {
            index,
            id,
            stream,
            producer,
            receiver: None,
            session: None,
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

    /// A WELCOME issued `session`: rebuild the receiver with it. Any audio
    /// buffered for the old session belongs to a dead timeline and is dropped.
    ///
    /// A WELCOME for the session already attached is a retried handshake, not a
    /// new one: it returns `false` and keeps the receiver, its buffered audio
    /// and its pull cursor. Rebuilding on every retry would throw away the
    /// jitter window and make the next pull conceal the whole outage, which is
    /// what a Wi-Fi handshake (several HELLOs before one WELCOME is read) looked
    /// like from the master.
    ///
    /// The receiver is replaced, its counters are not: the outgoing one's
    /// counters are folded into `past` first, so [`counters`](Self::counters)
    /// keeps the sum across a re-handshake. The last pull report is kept too
    /// (see the `last` field): the master clock is the same one either side of
    /// the rebuild. Returns true when a new session took the receiver.
    pub fn attach_session(&mut self, key: [u8; 32], session: u32) -> bool {
        if self.session == Some(session) && self.receiver.is_some() {
            return false;
        }
        if let Some(receiver) = self.receiver.take() {
            self.past = add_counters(self.past, receiver.counters());
        }
        self.receiver = AudioReceiver::new(
            key,
            session,
            self.stream,
            1,
            PULL_WINDOW_FRAMES,
        )
        .ok();
        self.session = self.receiver.is_some().then_some(session);
        true
    }

    /// Whether a session has been issued and a receiver exists.
    pub fn has_session(&self) -> bool {
        self.receiver.is_some()
    }

    /// Authenticate and place one audio datagram. `Err` covers a wrong tag, a
    /// foreign session, a stereo/non-mono payload and the bounded-window
    /// refusal; the caller counts it and carries on.
    pub fn accept(&mut self, datagram: &[u8]) -> Result<Accepted, BearerError> {
        match self.receiver.as_mut() {
            Some(receiver) => receiver.accept(datagram),
            // No session was issued, so there is nothing to authenticate it for.
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
    /// The head trails the master clock by [`PULL_BUFFER_FRAMES`], so this is
    /// the paced read the uplink thread runs: it asks for exactly the frames the
    /// cursor is behind the head by (at most [`PULL_MAX_FRAMES`]), and
    /// [`AudioReceiver::pull_to`] conceals only what is genuinely due at the
    /// head. `None` means no session exists, audio has not started, or the head
    /// has not advanced past the cursor.
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
        UplinkSourceStatus {
            index: self.index,
            id: self.id.clone(),
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
            sources.push(UplinkSource::new(spec.index, spec.id, spec.producer)?);
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
    let mut sessions = 0u64;
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
                    &mut sessions,
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
        // Read behind the clock by the jitter buffer. Each source pulls exactly
        // the frames its cursor is behind this head by, so a wake that could not
        // fill its block carries the remainder into the next wake instead of
        // discarding it, and no datagram is read before it has had the buffer's
        // time to arrive.
        let head = now.saturating_sub(PULL_BUFFER_FRAMES as u64);
        for source in &mut sources {
            source.pump_to(head);
        }

        publish(&status, &bound, sessions, rejected, &sources, "running");
        thread::sleep(Duration::from_millis(PULL_INTERVAL_MS));
    }

    publish(&status, "", sessions, rejected, &sources, "off");
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
    sessions: &mut u64,
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
            if answer.is_pong() {
                return;
            }
            // A WELCOME issued a session. One audio session at a time: every
            // source's receiver is rebuilt when the id changes. A retried HELLO
            // gets the same id back, so it is neither counted as a new session
            // nor allowed to discard the audio already buffered for it. Two
            // peers need a peer id in the stream or a session map before this
            // can grow.
            if let Ok(welcome) = peer::decode_welcome(&reply[..length], key) {
                let mut changed = false;
                for source in sources.iter_mut() {
                    changed |= source.attach_session(*key, welcome.session);
                }
                if changed {
                    *sessions += 1;
                }
            }
        }
        stream if is_audio_stream(stream) => match sources
            .iter_mut()
            .find(|source| source.stream() == stream)
        {
            Some(source) => {
                if source.accept(datagram).is_err() {
                    *rejected += 1;
                }
            }
            None => *rejected += 1,
        },
        _ => *rejected += 1,
    }
}
