//! The live monitor stream: the engine's final stereo output over loopback TCP.
//!
//! Studio's controller picker can name a peer's Studio and hear it on the
//! controller's own machine. That machine already has a Music receiver: a peer
//! manager connects to `/manager/music/stream`, sends `hello`, and its PCM is
//! played by `pacat`. This module supplies the other end of that same path —
//! raw interleaved S16LE at the device rate (48 kHz stereo) — so no browser
//! decoder is involved.
//!
//! # Why a separate TCP port
//!
//! The control socket (`socket.rs`) answers one line and closes; a stream is
//! continuous. The `monitor` command binds a loopback listener and answers with
//! the port it got, and the manager dials that port. The listener is never on a
//! routable address.
//!
//! # The tap
//!
//! [`TapSource`] wraps a [`RenderSource`](crate::playback::RenderSource) and
//! pushes every block *after* the source has rendered it. The transport's
//! source renders the clip mix through the master rack and then adds the click,
//! so the tap is the final stereo output the room hears — the master rack is
//! heard, not only the pre-master bus. The push is the lock-free
//! [`MonitorBus`](crate::monbus) ring: the audio thread allocates nothing and
//! takes no lock.
//!
//! # No client
//!
//! A writer thread owns the ring's consumer. With no controller connected it
//! drains and discards, so the ring stays at the live edge and a later listener
//! never starts on a stale backlog. A slow or broken client is dropped after a
//! short write timeout; the transport is never back-pressured.

use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::monbus::{Consumer, MonitorBus, Producer};
use crate::playback::RenderSource;
use crate::to_i16;

/// The rate the monitor stream always speaks. A receiver's `pacat` starts at
/// this rate, which is the engine's own default and the house norm.
pub const MONITOR_RATE: u32 = 48_000;

/// Interleaved stereo, like every other monitor bus in the engine.
pub const MONITOR_CHANNELS: usize = 2;

/// About 170 ms of stereo at 48 kHz: enough for a scheduling hiccup between the
/// transport and the writer, short enough that a stalled controller is a gap and
/// not a delay.
pub const MONITOR_RING_FRAMES: usize = 8192;

/// The most frames one pop converts. The ring is filled a period at a time, so
/// this is an upper bound the audio path never exceeds.
const MONITOR_BLOCK_FRAMES: usize = 4096;

/// A start/stop/quit instruction for the writer thread.
enum Control {
    /// Bind `port` (0 means an ephemeral port) and answer the bound one.
    Start {
        port: u16,
        reply: Sender<Result<u16, String>>,
    },
    /// Stop serving and close the client; answer when that has happened.
    Stop { reply: Sender<()> },
    /// End the writer thread.
    Quit,
}

/// The shareable handle the transport and `status` use. The producer is the
/// audio thread's side of the ring; the atomics are the writer's state.
#[derive(Clone)]
pub struct MonitorControl {
    producer: Arc<Producer>,
    control: Sender<Control>,
    port: Arc<AtomicU32>,
    enabled: Arc<AtomicBool>,
    streaming: Arc<AtomicBool>,
    frames: Arc<AtomicU64>,
    dropped: Arc<AtomicU64>,
}

impl MonitorControl {
    /// The audio thread's push side. Clone it into a [`TapSource`].
    pub fn producer(&self) -> Arc<Producer> {
        Arc::clone(&self.producer)
    }

    /// Whether the writer is asked to serve (a port is bound). This is the
    /// `stream` fact; `streaming` is a connected controller.
    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Acquire)
    }

    /// Whether a controller is connected right now.
    pub fn is_streaming(&self) -> bool {
        self.streaming.load(Ordering::Acquire)
    }

    /// The bound loopback port, or 0 while stopped.
    pub fn port(&self) -> u16 {
        self.port.load(Ordering::Acquire) as u16
    }

    /// Frames converted for a connected client since the stream started.
    pub fn frames(&self) -> u64 {
        self.frames.load(Ordering::Relaxed)
    }

    /// Frames the ring discarded because it was full.
    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }

    /// Bind a listener and answer the port actually granted. Synchronous:
    /// the caller reports the port to the manager before the manager dials.
    pub fn start(&self, port: u16) -> Result<u16, String> {
        let (reply, answer) = mpsc::channel();
        self.control
            .send(Control::Start { port, reply })
            .map_err(|_| "the monitor writer is gone".to_string())?;
        answer
            .recv_timeout(Duration::from_secs(3))
            .map_err(|_| "the monitor writer did not answer".to_string())?
    }

    /// Stop serving and close the client. Synchronous, so a following `status`
    /// describes the stopped stream rather than the one still closing.
    pub fn stop(&self) {
        let (reply, answer) = mpsc::channel();
        if self.control.send(Control::Stop { reply }).is_ok() {
            let _ = answer.recv_timeout(Duration::from_secs(2));
        }
    }

    /// The `stream` object every status line carries.
    pub fn status_fragment(&self) -> String {
        format!(
            "{{\"enabled\":{},\"streaming\":{},\"port\":{},\"rate\":{},\"channels\":{},\"monitor_frames\":{},\"dropped\":{}}}",
            self.is_enabled(),
            self.is_streaming(),
            self.port(),
            MONITOR_RATE,
            MONITOR_CHANNELS,
            self.frames(),
            self.dropped()
        )
    }
}

/// The engine's one monitor tap. It owns the writer thread and lives for the
/// process's lifetime; `start`/`stop` only toggle what the thread serves, so a
/// transport may start and stop under a stable tap.
pub struct MonitorTap {
    control: MonitorControl,
    handle: Option<JoinHandle<()>>,
}

impl MonitorTap {
    /// Build the ring and start the writer. The writer sleeps until a `start`
    /// arrives; the transport may always push.
    pub fn new() -> Self {
        let (producer, consumer) = MonitorBus::new(MONITOR_RING_FRAMES);
        let producer = Arc::new(producer);
        let dropped = producer.dropped_handle();
        let (control, rx) = mpsc::channel();
        let port = Arc::new(AtomicU32::new(0));
        let enabled = Arc::new(AtomicBool::new(false));
        let streaming = Arc::new(AtomicBool::new(false));
        let frames = Arc::new(AtomicU64::new(0));
        let handle = {
            let port = Arc::clone(&port);
            let enabled = Arc::clone(&enabled);
            let streaming = Arc::clone(&streaming);
            let frames = Arc::clone(&frames);
            thread::Builder::new()
                .name("jawn-audio-monitor".to_string())
                .spawn(move || {
                    run_monitor(consumer, rx, port, enabled, streaming, frames)
                })
                .expect("the monitor writer thread")
        };
        MonitorTap {
            control: MonitorControl {
                producer,
                control,
                port,
                enabled,
                streaming,
                frames,
                dropped,
            },
            handle: Some(handle),
        }
    }

    /// A cloneable handle for the transport and the status line.
    pub fn control(&self) -> MonitorControl {
        self.control.clone()
    }

    /// End the writer and wait for it. Called once by `Server::shutdown`.
    pub fn finish(&mut self) {
        if let Some(handle) = self.handle.take() {
            let _ = self.control.control.send(Control::Quit);
            let _ = handle.join();
        }
    }
}

impl Drop for MonitorTap {
    fn drop(&mut self) {
        self.finish();
    }
}

/// The writer: poll for a start/stop, accept one client, drain the ring, and
/// convert whole stereo blocks to little-endian S16LE. It never touches the
/// audio thread's state beyond the lock-free ring.
fn run_monitor(
    consumer: Consumer,
    rx: Receiver<Control>,
    port: Arc<AtomicU32>,
    enabled: Arc<AtomicBool>,
    streaming: Arc<AtomicBool>,
    frames: Arc<AtomicU64>,
) {
    let mut listener: Option<TcpListener> = None;
    let mut client: Option<TcpStream> = None;
    let mut block = vec![0.0f32; MONITOR_BLOCK_FRAMES * 2];
    let mut bytes = vec![0u8; MONITOR_BLOCK_FRAMES * 4];

    loop {
        // Control first: a start/stop must not wait behind a ring pop.
        loop {
            match rx.try_recv() {
                Ok(Control::Start {
                    port: wanted,
                    reply,
                }) => {
                    client = None;
                    listener = None;
                    streaming.store(false, Ordering::Release);
                    match TcpListener::bind(("127.0.0.1", wanted)) {
                        Ok(bound) => {
                            let _ = bound.set_nonblocking(true);
                            let actual = bound.local_addr().map(|addr| addr.port()).unwrap_or(0);
                            listener = Some(bound);
                            port.store(u32::from(actual), Ordering::Release);
                            enabled.store(true, Ordering::Release);
                            let _ = reply.send(Ok(actual));
                        }
                        Err(error) => {
                            enabled.store(false, Ordering::Release);
                            port.store(0, Ordering::Release);
                            let _ = reply.send(Err(format!(
                                "cannot listen on 127.0.0.1:{wanted}: {error}"
                            )));
                        }
                    }
                }
                Ok(Control::Stop { reply }) => {
                    client = None;
                    listener = None;
                    enabled.store(false, Ordering::Release);
                    streaming.store(false, Ordering::Release);
                    port.store(0, Ordering::Release);
                    let _ = reply.send(());
                }
                Ok(Control::Quit) => return,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return,
            }
        }

        if let Some(bound) = listener.as_ref() {
            if client.is_none() {
                match bound.accept() {
                    Ok((socket, _)) => {
                        let _ = socket.set_nodelay(true);
                        // A controller that stops reading is dropped, not allowed
                        // to hold the writer (and the transport) hostage.
                        let _ = socket.set_write_timeout(Some(Duration::from_millis(200)));
                        client = Some(socket);
                        streaming.store(true, Ordering::Release);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(_) => {}
                }
            }
        }

        let got = consumer.pop(&mut block);
        if got == 0 {
            thread::sleep(Duration::from_millis(1));
            continue;
        }
        // With the stream stopped, keep the ring at the live edge so a later
        // listener does not begin on a stale backlog.
        if !enabled.load(Ordering::Acquire) {
            continue;
        }
        frames.fetch_add(got as u64, Ordering::Relaxed);
        if let Some(socket) = client.as_mut() {
            let mut len = 0;
            for sample in &block[..got * 2] {
                let value = to_i16(*sample).to_le_bytes();
                bytes[len] = value[0];
                bytes[len + 1] = value[1];
                len += 2;
            }
            if socket.write_all(&bytes[..len]).is_err() {
                client = None;
                streaming.store(false, Ordering::Release);
            }
        }
    }
}

/// A render source that copies every finished block into the monitor ring. The
/// tap runs after the wrapped source has rendered, so it sees the final stereo
/// output (master rack and click included).
pub struct TapSource<S> {
    inner: S,
    producer: Arc<Producer>,
}

impl<S> TapSource<S> {
    pub fn new(inner: S, producer: Arc<Producer>) -> Self {
        TapSource { inner, producer }
    }
}

impl<S: RenderSource> RenderSource for TapSource<S> {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        self.inner.prepared(rate, period)
    }

    fn block(&mut self, out: &mut [f32]) -> Result<(), String> {
        self.inner.block(out)?;
        // Dropped frames are counted by the ring; the audio path never waits.
        let _ = self.producer.push(out);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::net::TcpStream;

    fn read_exact(stream: &mut TcpStream, len: usize) -> Vec<u8> {
        let mut buffer = vec![0u8; len];
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("read timeout");
        stream.read_exact(&mut buffer).expect("monitor bytes");
        buffer
    }

    #[test]
    fn a_connected_client_receives_little_endian_stereo() {
        let tap = MonitorTap::new();
        let control = tap.control();
        let port = control.start(0).expect("bind");
        assert!(port > 0, "an ephemeral port was granted");
        assert!(control.is_enabled(), "the stream is enabled");
        assert!(!control.is_streaming(), "no client yet");

        let mut client = TcpStream::connect(("127.0.0.1", port)).expect("connect");
        // Wait for the writer's accept, so the block below is not drained
        // before a client exists.
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !control.is_streaming() && std::time::Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
        }
        assert!(control.is_streaming(), "the client was accepted");

        control
            .producer()
            .push(&[1.0f32, -1.0, 0.5, -0.5]);
        let bytes = read_exact(&mut client, 8);
        assert_eq!(i16::from_le_bytes([bytes[0], bytes[1]]), i16::MAX);
        assert_eq!(i16::from_le_bytes([bytes[2], bytes[3]]), -i16::MAX);
        assert_eq!(i16::from_le_bytes([bytes[4], bytes[5]]), 16_384);
        assert_eq!(i16::from_le_bytes([bytes[6], bytes[7]]), -16_384);
        assert!(control.frames() >= 2, "the monitor counted its frames");
    }

    #[test]
    fn stop_closes_the_client_and_frees_the_port() {
        let tap = MonitorTap::new();
        let control = tap.control();
        let port = control.start(0).expect("bind");
        let client = TcpStream::connect(("127.0.0.1", port)).expect("connect");
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while !control.is_streaming() && std::time::Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
        }
        control.stop();
        assert!(!control.is_enabled(), "stop ends the stream");
        assert!(!control.is_streaming(), "and drops the client");
        assert_eq!(control.port(), 0, "the port is released");
        // The listener is gone, so a reconnect is refused.
        assert!(TcpStream::connect(("127.0.0.1", port)).is_err());
        drop(client);
    }

    #[test]
    fn a_port_already_in_use_is_refused_with_its_own_sentence() {
        let held = TcpListener::bind(("127.0.0.1", 0)).expect("bind a port");
        let port = held.local_addr().expect("address").port();
        let tap = MonitorTap::new();
        let error = tap.control().start(port).expect_err("the port is taken");
        assert!(error.contains("cannot listen on 127.0.0.1:"), "{error}");
        assert!(!tap.control().is_enabled(), "a refused start does not serve");
    }

    #[test]
    fn the_status_fragment_names_the_rate_and_the_stream_state() {
        let tap = MonitorTap::new();
        let control = tap.control();
        let fragment = control.status_fragment();
        assert!(fragment.contains("\"enabled\":false"), "{fragment}");
        assert!(fragment.contains("\"streaming\":false"), "{fragment}");
        assert!(fragment.contains("\"rate\":48000"), "{fragment}");
        assert!(fragment.contains("\"channels\":2"), "{fragment}");
        control.start(0).expect("bind");
        assert!(control.status_fragment().contains("\"enabled\":true"));
        control.stop();
    }
}
