//! P4's peer sending half: a take clocked against a master.
//!
//! The pacing and stamping rules are exercised directly through [`TakeSender`];
//! the end-to-end tests put a real `ClockMaster` and `AudioReceiver` on two UDP
//! sockets, because there the session and the transport are the point.

use std::io::ErrorKind;
use std::net::UdpSocket;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use jawn_audio::{
    audio_stream, decode, decode_welcome, is_audio_stream, run_send_take, validate_send,
    AudioReceiver, Clock, ClockMaster, ClockOffset, SendSpec, SenderReport, TakeSender,
    ValidatedSend, WavWriter, STREAM_CLOCK_HELLO, STREAM_CLOCK_PING,
};

fn key(seed: u8) -> [u8; 32] {
    [seed; 32]
}

/// A smooth take: linear interpolation at a realistic drift moves a sample by a
/// fraction of this signal's one-sample step, so a tolerance can be honest
/// about resampling without hiding a wrong sample.
fn sine(frames: usize, hz: f64) -> Vec<i16> {
    (0..frames)
        .map(|index| {
            let phase = 2.0 * std::f64::consts::PI * hz * index as f64 / 48_000.0;
            (12_000.0 * phase.sin()).round() as i16
        })
        .collect()
}

/// What the test master saw. The receiver is handed over when the thread stops.
struct Snapshot {
    welcomed: u64,
    session: u32,
    audio_datagrams: u64,
    receiver: Option<AudioReceiver>,
}

impl Default for Snapshot {
    fn default() -> Self {
        Snapshot {
            welcomed: 0,
            session: 0,
            audio_datagrams: 0,
            receiver: None,
        }
    }
}

/// A real clock master on loopback: it answers HELLO/WELCOME and PING/PONG with
/// the session key and accepts audio for `stream` into one wide receiver. It is
/// a test fixture, not `uplink.rs`: no ring, no patchbay, no thread of its own.
fn start_master(
    key: [u8; 32],
    stream: u16,
    stop: Arc<AtomicBool>,
) -> (std::net::SocketAddr, Arc<Mutex<Snapshot>>, thread::JoinHandle<()>) {
    start_master_from(key, stream, stop, 0)
}

/// A clock that has already counted `base` samples when the thread starts. It
/// models the master's long-lived session clock, which is what makes the first
/// probe offset far larger than the receiver's jitter window.
struct BaseClock {
    start: Instant,
    base: u64,
}

impl Clock for BaseClock {
    fn now(&self) -> u64 {
        let nanos = self.start.elapsed().as_nanos() as f64;
        self.base + (nanos * 48_000.0 / 1_000_000_000.0).round() as u64
    }
}

fn start_master_from(
    key: [u8; 32],
    stream: u16,
    stop: Arc<AtomicBool>,
    base: u64,
) -> (std::net::SocketAddr, Arc<Mutex<Snapshot>>, thread::JoinHandle<()>) {
    let socket = UdpSocket::bind("127.0.0.1:0").expect("bind the test master");
    let address = socket.local_addr().expect("master address");
    socket
        .set_read_timeout(Some(Duration::from_millis(20)))
        .expect("master timeout");
    let state = Arc::new(Mutex::new(Snapshot::default()));
    let shared = Arc::clone(&state);

    let handle = thread::spawn(move || {
        let clock = BaseClock {
            start: Instant::now(),
            base,
        };
        let mut master = ClockMaster::new(key);
        let mut snapshot = Snapshot::default();
        let mut receiver: Option<AudioReceiver> = None;
        let mut incoming = [0u8; 2048];
        let mut reply = [0u8; 2048];

        while !stop.load(Ordering::SeqCst) {
            match socket.recv_from(&mut incoming) {
                Ok((length, origin)) => {
                    let header = match decode(&incoming[..length]) {
                        Ok((header, _)) => header,
                        Err(_) => continue,
                    };
                    if matches!(header.stream, STREAM_CLOCK_HELLO | STREAM_CLOCK_PING) {
                        if let Some(answer) = master.answer(&incoming[..length], &clock, &mut reply) {
                            let length = answer.length();
                            let _ = socket.send_to(&reply[..length], origin);
                            if let Ok(welcome) = decode_welcome(&reply[..length], &key) {
                                snapshot.welcomed += 1;
                                snapshot.session = welcome.session;
                                receiver =
                                    AudioReceiver::new(key, welcome.session, stream, 1, 1 << 16)
                                        .ok();
                            }
                        }
                    } else if is_audio_stream(header.stream) {
                        snapshot.audio_datagrams += 1;
                        if let Some(sink) = receiver.as_mut() {
                            let _ = sink.accept(&incoming[..length]);
                        }
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
                    ) => {}
                Err(_) => {}
            }
        }

        snapshot.receiver = receiver;
        *shared.lock().expect("snapshot") = snapshot;
    });

    (address, state, handle)
}

/// How many of the take's samples appear in `received`, in order, within
/// `tolerance`. Concealed frames (zeros) are skipped, and the search allows a
/// small forward step so a resampler rounding one sample either way is not
/// counted as a lost frame.
fn matched_in_order(received: &[i16], take: &[i16], tolerance: i32) -> usize {
    let mut index = 0usize;
    let mut matched = 0usize;
    for &sample in received {
        if index >= take.len() {
            break;
        }
        if sample == 0 {
            continue;
        }
        let end = (index + 8).min(take.len());
        if let Some(found) = (index..end)
            .find(|probe| (i32::from(sample) - i32::from(take[*probe])).abs() <= tolerance)
        {
            matched += 1;
            index = found + 1;
        }
    }
    matched
}

#[test]
fn a_block_is_stamped_from_the_fit_and_a_late_wake_sends_what_elapsed() {
    let take: Vec<i16> = (0..2_000).map(|index| ((index % 200) as i16) - 100).collect();
    let mut sender = TakeSender::new(take.clone());
    sender.set_estimate(Some(ClockOffset::new(1_000, 0.0)));

    let first = sender.block(480).expect("a first block");
    assert_eq!(first.master_sample, 1_000, "offset.to_master(0)");
    assert_eq!(first.frames.len(), 480);
    assert_eq!(first.frames, take[..480].to_vec(), "zero drift passes through");
    assert_eq!(sender.local(), 480);

    // A wake that arrives 20 ms late sends 960 frames, not a fixed 480, and
    // starts exactly where the previous block ended.
    let late = sender.block(960).expect("a late block");
    assert_eq!(late.master_sample, 1_480);
    assert_eq!(late.frames.len(), 960);
    assert_eq!(late.frames, take[480..1_440].to_vec());
    assert_eq!(sender.local(), 1_440);
}

#[test]
fn before_the_first_estimate_the_take_passes_through_at_its_local_position() {
    let take: Vec<i16> = (0..600).map(|index| index as i16).collect();
    let mut sender = TakeSender::new(take.clone());
    assert_eq!(sender.estimate(), None);

    let block = sender.block(480).expect("a block before the fit");
    assert_eq!(block.master_sample, 0, "the local position is the stamp");
    assert_eq!(block.frames, take[..480].to_vec());
    assert_eq!(sender.local(), 480);
}

#[test]
fn a_fast_peer_clock_emits_fewer_master_frames_for_the_same_take_span() {
    let mut sender = TakeSender::new(vec![0i16; 4_000]);
    // 2000 ppm over 480 local frames is 479.04 master frames.
    sender.set_estimate(Some(ClockOffset::new(0, 2_000.0)));

    let block = sender.block(480).expect("a block");
    assert_eq!(block.master_sample, 0);
    assert_eq!(
        block.frames.len(),
        479,
        "the fitted drift decides the master span"
    );
    assert_eq!(sender.local(), 480, "the take still advances by its own clock");
}

#[test]
fn a_block_never_reads_past_the_end_of_the_take() {
    let mut sender = TakeSender::new(vec![7i16; 500]);
    assert_eq!(sender.block(480).expect("a full block").frames.len(), 480);

    let last = sender.block(480).expect("the remainder");
    assert_eq!(last.frames.len(), 20, "only the frames the take still holds");
    assert!(last.frames.iter().all(|sample| *sample == 7));
    assert!(sender.exhausted());
    assert!(sender.block(480).is_none(), "nothing left to send");
}

#[test]
fn the_report_is_one_line_with_the_sender_keys_and_never_the_key() {
    let report = SenderReport::success(
        "127.0.0.1:9",
        7,
        3,
        1_440,
        1,
        Some(ClockOffset::new(120, 2.5)),
    );
    let json = report.to_json();
    for key in [
        "\"ok\":true",
        "\"role\":\"sender\"",
        "\"master\":\"127.0.0.1:9\"",
        "\"session\":7",
        "\"sent\":3",
        "\"frames\":1440",
        "\"handshakes\":1",
        "\"offset_samples\":120",
        "\"drift_ppm\":2.500000",
    ] {
        assert!(json.contains(key), "{key} is missing from {json}");
    }
    assert_eq!(json.lines().count(), 1, "one JSON line");

    let failure = SenderReport::failure("127.0.0.1:9", "no master answered");
    let json = failure.to_json();
    assert!(json.contains("\"ok\":false"), "{json}");
    assert!(json.contains("\"error\":\"no master answered\""), "{json}");
    assert_eq!(json.lines().count(), 1, "one JSON line on failure too");
}

#[test]
fn a_real_master_receives_the_take_in_order_on_the_issued_session() {
    let session_key = key(0x71);
    let stream = audio_stream(1).expect("an audio stream");
    let stop = Arc::new(AtomicBool::new(false));
    let (address, state, handle) = start_master(session_key, stream, Arc::clone(&stop));

    let take = sine(12_000, 220.0); // 0.25 s at 48 kHz
    let config = ValidatedSend {
        take: take.clone(),
        master: address,
        key: session_key,
        stream,
        rate: 48_000,
        seconds: 0.5,
        seconds_given: false,
        pong_timeout_ms: 20,
        window: 64,
    };

    let report = run_send_take(&config);
    stop.store(true, Ordering::SeqCst);
    handle.join().expect("join the test master");

    assert!(report.ok, "report: {}", report.to_json());
    assert!(report.sent > 0, "datagrams were sent: {}", report.to_json());
    assert!(
        report.frames >= take.len() as u64 * 9 / 10,
        "most of the take was sent: {} of {}",
        report.frames,
        take.len()
    );

    let mut snapshot = state.lock().expect("snapshot");
    assert!(snapshot.welcomed >= 1, "the master issued a session");
    assert_eq!(
        report.session, snapshot.session,
        "the report names the issued session"
    );
    assert_eq!(report.handshakes, 1);
    assert_eq!(
        snapshot.audio_datagrams, report.sent,
        "every datagram reached the master"
    );

    let receiver = snapshot
        .receiver
        .as_mut()
        .expect("the welcome built a receiver");
    let mut out = vec![0i16; take.len() + 8_192];
    let capacity = out.len();
    let pulled = receiver.pull(&mut out, capacity);
    assert!(pulled.frames > 0, "the receiver holds audio");
    let matched = matched_in_order(&out[..pulled.frames], &take, 400);
    assert!(
        matched >= take.len() * 9 / 10,
        "the take arrived in order: {matched} of {} frames",
        take.len()
    );

    // The resampler is the only thing that may alter a sample, and the receiver
    // never authenticated a foreign datagram.
    assert_eq!(
        snapshot.receiver.as_ref().expect("receiver").counters().rejected,
        0,
        "a right key and session were never refused"
    );
}

#[test]
fn a_long_lived_master_still_places_the_whole_take() {
    // The master has been up an hour, so its offset is millions of samples and
    // the receiver's jitter window is small. A take stamped with the bare local
    // position for its first blocks and then with the fitted offset would jump
    // past that window and be refused. The first pong's midpoint anchors it.
    let session_key = key(0x91);
    let stream = audio_stream(0).expect("an audio stream");
    let stop = Arc::new(AtomicBool::new(false));
    let (address, state, handle) = start_master_from(
        session_key,
        stream,
        Arc::clone(&stop),
        48_000 * 3_600,
    );

    let take = sine(12_000, 220.0);
    let config = ValidatedSend {
        take: take.clone(),
        master: address,
        key: session_key,
        stream,
        rate: 48_000,
        seconds: 0.5,
        seconds_given: false,
        pong_timeout_ms: 20,
        window: 64,
    };

    let report = run_send_take(&config);
    stop.store(true, Ordering::SeqCst);
    handle.join().expect("join the test master");

    assert!(report.ok, "report: {}", report.to_json());
    assert!(
        report.estimate.expect("a fit").sample_offset > 48_000 * 3_000,
        "the offset is the master's uptime: {}",
        report.to_json()
    );

    let mut snapshot = state.lock().expect("snapshot");
    let receiver = snapshot
        .receiver
        .as_mut()
        .expect("the welcome built a receiver");
    let mut out = vec![0i16; take.len() + 8_192];
    let capacity = out.len();
    let pulled = receiver.pull(&mut out, capacity);
    assert_eq!(
        receiver.counters().rejected,
        0,
        "no datagram fell outside the receiver's window"
    );
    let matched = matched_in_order(&out[..pulled.frames], &take, 400);
    assert!(
        matched >= take.len() * 9 / 10,
        "the take arrived in order: {matched} of {} frames",
        take.len()
    );
}

#[test]
fn a_wrong_key_gets_no_welcome_and_the_sender_sends_no_audio() {
    let master_key = key(0x81);
    let wrong_key = key(0x82);
    let stream = audio_stream(0).expect("an audio stream");
    let stop = Arc::new(AtomicBool::new(false));
    let (address, state, handle) = start_master(master_key, stream, Arc::clone(&stop));

    let config = ValidatedSend {
        take: sine(9_600, 220.0),
        master: address,
        key: wrong_key,
        stream,
        rate: 48_000,
        seconds: 0.15,
        seconds_given: true,
        pong_timeout_ms: 20,
        window: 64,
    };

    let report = run_send_take(&config);
    stop.store(true, Ordering::SeqCst);
    handle.join().expect("join the test master");

    assert!(!report.ok, "report: {}", report.to_json());
    assert!(
        report.error.contains("handshake"),
        "the failure names the handshake: {}",
        report.error
    );
    assert_eq!(report.sent, 0, "no datagram left before a session");
    assert_eq!(report.frames, 0);

    let snapshot = state.lock().expect("snapshot");
    assert_eq!(snapshot.welcomed, 0, "the wrong key gets no WELCOME");
    assert_eq!(
        snapshot.audio_datagrams, 0,
        "no session means no audio at all"
    );
}

/// A path under the temp directory, removed however the test ends.
struct TempWav {
    path: PathBuf,
}

impl TempWav {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "jawn-audio-sender-{}-{name}.wav",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        TempWav { path }
    }
}

impl Drop for TempWav {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn write_take(path: &PathBuf, rate: u32, samples: &[i16]) {
    let mut writer =
        WavWriter::create(path, rate, 1, samples.len().max(4)).expect("create the take");
    if !samples.is_empty() {
        writer.write_i16(samples).expect("write the take");
    }
    writer.finish().expect("finish the take");
}

fn spec(path: &PathBuf, rate: u32) -> SendSpec {
    SendSpec {
        take_path: path.to_string_lossy().into_owned(),
        master: Some("127.0.0.1:7050".to_string()),
        key_hex: Some("00".repeat(32)),
        stream: 0,
        rate,
        seconds: None,
        pong_timeout_ms: 20,
        window: 64,
    }
}

#[test]
fn a_missing_key_wrong_rate_and_empty_take_are_usage_errors() {
    let good = TempWav::new("good");
    write_take(&good.path, 44_100, &[1, 2, 3, 4]);
    let base = spec(&good.path, 44_100);
    let validated = validate_send(&base).expect("the valid shape reads");
    assert_eq!(validated.take, vec![1, 2, 3, 4]);
    assert_eq!(validated.stream, audio_stream(0).expect("stream"));
    assert!(validated.seconds > 0.0);

    let missing_key = SendSpec {
        key_hex: None,
        ..base.clone()
    };
    let error = validate_send(&missing_key).expect_err("a send needs a key");
    assert!(error.contains("key"), "{error}");

    let wrong_rate = SendSpec {
        rate: 48_000,
        ..base.clone()
    };
    let error = validate_send(&wrong_rate).expect_err("44100 is not 48000");
    assert!(
        error.contains("not resampled"),
        "the refusal says the rate is not converted: {error}"
    );

    let empty = TempWav::new("empty");
    write_take(&empty.path, 48_000, &[]);
    let empty_spec = SendSpec {
        take_path: empty.path.to_string_lossy().into_owned(),
        rate: 48_000,
        ..base.clone()
    };
    let error = validate_send(&empty_spec).expect_err("an empty take has nothing to send");
    assert!(error.contains("empty"), "{error}");

    let missing_file = SendSpec {
        take_path: "/no/such/jawn-take.wav".to_string(),
        ..base.clone()
    };
    assert!(
        validate_send(&missing_file).is_err(),
        "a missing file is refused"
    );

    let bad_stream = SendSpec {
        stream: usize::MAX,
        ..base.clone()
    };
    assert!(
        validate_send(&bad_stream).is_err(),
        "a stream outside the audio range is refused"
    );
}
