//! P4's master side: a peer's audio becomes a patch source ring.
//!
//! These tests exercise the same code the `--serve --uplink` thread runs: a
//! real `ClockMaster` issues a session, `AudioBearer` datagrams for that
//! session fill a source's ring, and `pull_at` conceals a lost tail. Two of
//! them use two real UDP sockets, because there the transport is the point.

use std::net::UdpSocket;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use jawn_audio::{
    audio_stream, decode_welcome, encode_hello, Accepted, AudioBearer, BearerError, ClockMaster,
    ControlReply, ManualClock, Uplink, UplinkConfig, UplinkSource, UplinkSourceSpec, UplinkStatus,
    DEADLINE_GUARD_FRAMES, MAX_DATAGRAM_LEN, PULL_FRAMES,
};
use jawn_audio::monbus;

fn key(seed: u8) -> [u8; 32] {
    [seed; 32]
}

/// A deterministic mono pattern; every sample differs from its neighbours, so
/// a shifted block cannot compare equal by accident.
fn signal(frames: usize) -> Vec<i16> {
    (0..frames)
        .map(|index| ((index as i32 * 53) % 4001 - 2000) as i16)
        .collect()
}

/// Packetize a mono block into the datagrams a peer would send.
fn datagrams(bearer: &mut AudioBearer, stream: u16, frames: &[i16], master: u64) -> Vec<Vec<u8>> {
    let mut collected = Vec::new();
    bearer
        .packetize(stream, 1, frames, master, |datagram| {
            collected.push(datagram.to_vec());
            Ok(())
        })
        .expect("packetize");
    collected
}

#[test]
fn a_clock_handshake_and_audio_datagram_fill_the_source_ring() {
    let session_key = key(0x11);
    let mut master = ClockMaster::new(session_key);
    let clock = ManualClock::new(1_000);
    let mut reply = [0u8; MAX_DATAGRAM_LEN];
    let mut hello = [0u8; MAX_DATAGRAM_LEN];
    let length = encode_hello(&mut hello, &session_key, 1, 0xABCD).expect("hello");
    let answer = master
        .answer(&hello[..length], &clock, &mut reply)
        .expect("the master answers a keyed hello");
    assert!(matches!(answer, ControlReply::Welcome(_)));
    let welcome = decode_welcome(&reply[..answer.length()], &session_key).expect("welcome");

    let (producer, consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source =
        UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    assert!(!source.has_session(), "no session before the welcome");
    source.attach_session(session_key, welcome.session);
    assert!(source.has_session());

    let frames = signal(480);
    let mut bearer = AudioBearer::new(session_key, welcome.session);
    for datagram in datagrams(&mut bearer, source.stream(), &frames, 0) {
        assert_eq!(
            source.accept(&datagram),
            Ok(Accepted::Buffered),
            "the right key and session are accepted"
        );
    }

    let report = source.pump(PULL_FRAMES, 0).expect("a session pulls");
    assert_eq!(report.frames, 480);
    assert!(!report.discontinuity);
    let mut out = vec![0.0f32; 480 * 2];
    assert_eq!(consumer.pop(&mut out), 480, "the ring holds the block");
    for frame in 0..480 {
        let expected = f32::from(frames[frame]) / 32_768.0;
        assert!((out[frame * 2] - expected).abs() < 1e-6, "frame {frame}");
        assert!((out[frame * 2 + 1] - expected).abs() < 1e-6, "frame {frame}");
    }
    assert_eq!(source.status().received, 1);
    assert_eq!(source.status().dropped, 0);
}

#[test]
fn a_wrong_key_gets_no_welcome_and_no_audio() {
    let session_key = key(0x22);
    let wrong_key = key(0x33);
    let mut master = ClockMaster::new(session_key);
    let clock = ManualClock::new(0);
    let mut reply = [0u8; MAX_DATAGRAM_LEN];

    let mut hello = [0u8; MAX_DATAGRAM_LEN];
    let length = encode_hello(&mut hello, &wrong_key, 1, 7).expect("hello");
    assert!(
        master.answer(&hello[..length], &clock, &mut reply).is_none(),
        "a hello for another key gets no welcome"
    );

    // Without a session there is nothing to authenticate audio for at all.
    let (producer, consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source =
        UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    let frames = signal(480);
    let mut bearer = AudioBearer::new(wrong_key, 99);
    let sent = datagrams(&mut bearer, audio_stream(0).expect("stream"), &frames, 0);
    assert_eq!(
        source.accept(&sent[0]),
        Err(BearerError::Session(0)),
        "no session means no receiver"
    );

    // With the right session, a datagram keyed differently is still refused.
    source.attach_session(session_key, 99);
    source.accept(&sent[0]).expect_err("a wrong-key datagram is refused");
    let mut out = vec![0.0f32; 2];
    assert_eq!(consumer.pop(&mut out), 0, "nothing reached the ring");
}

#[test]
fn a_lost_tail_is_concealed_and_visible_in_the_counters() {
    let session_key = key(0x44);
    let (producer, _consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source =
        UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    source.attach_session(session_key, 7);

    // Only 100 frames arrive; the rest of the deadline's block is lost.
    let frames = signal(100);
    let mut bearer = AudioBearer::new(session_key, 7);
    for datagram in datagrams(&mut bearer, source.stream(), &frames, 0) {
        source.accept(&datagram).expect("accepted");
    }

    let now = 100 + DEADLINE_GUARD_FRAMES as i64 + 1;
    let report = source.pump(PULL_FRAMES, now).expect("a session pulls");
    assert!(report.from_deadline, "the missing tail hit the deadline");
    assert!(report.concealed_frames > 0, "{report:?}");

    let status = source.status();
    assert!(status.from_deadline, "the deadline is visible in status");
    assert_eq!(status.concealed, source.counters().concealed_frames);
    assert!(status.concealed > 0);
    assert_eq!(status.last_master, report.master_sample);
}

#[test]
fn a_rehandshake_keeps_the_counters() {
    let session_key = key(0x77);
    let (producer, _consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source =
        UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    source.attach_session(session_key, 7);

    // One block from the first session is accepted and pulled.
    let frames = signal(480);
    let mut bearer = AudioBearer::new(session_key, 7);
    for datagram in datagrams(&mut bearer, source.stream(), &frames, 0) {
        source.accept(&datagram).expect("accepted");
    }
    assert_eq!(source.pump(PULL_FRAMES, 0).expect("a session pulls").frames, 480);
    let before = source.status();
    assert_eq!(before.received, 1);

    // The peer re-handshakes after a quiet spell: a new session, a new receiver.
    source.attach_session(session_key, 8);
    let after = source.status();
    assert_eq!(after.received, before.received, "received survives the rebuild");
    assert_eq!(after.late, before.late, "late survives the rebuild");
    assert_eq!(
        after.concealed, before.concealed,
        "concealed survives the rebuild"
    );
    assert_eq!(
        after.last_master, before.last_master,
        "the last pull is on the same master clock"
    );

    // Audio on the new session keeps adding to the pre-rebuild total.
    let mut bearer = AudioBearer::new(session_key, 8);
    for datagram in datagrams(&mut bearer, source.stream(), &frames, 0) {
        source.accept(&datagram).expect("accepted");
    }
    assert_eq!(source.pump(PULL_FRAMES, 0).expect("the new session pulls").frames, 480);
    let later = source.status();
    assert_eq!(later.received, before.received + 1);
}

#[test]
fn a_retried_welcome_keeps_the_buffered_audio() {
    let session_key = key(0x78);
    let (producer, _consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source =
        UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    assert!(
        source.attach_session(session_key, 7),
        "the first session builds the receiver"
    );
    assert!(
        !source.attach_session(session_key, 7),
        "the same session is a retried handshake, not a rebuild"
    );

    // Two blocks arrive; the first is pulled, the second stays buffered.
    let frames = signal(960);
    let mut bearer = AudioBearer::new(session_key, 7);
    for (index, chunk) in frames.chunks(480).enumerate() {
        for datagram in datagrams(&mut bearer, source.stream(), chunk, (index * 480) as u64) {
            source.accept(&datagram).expect("accepted");
        }
    }
    assert_eq!(source.pump(PULL_FRAMES, 0).expect("pull").frames, 480);

    // A WELCOME for the same session arrives while the second block waits. A
    // rebuild would discard it and the next pull would conceal the hole.
    assert!(!source.attach_session(session_key, 7));
    let report = source.pump(PULL_FRAMES, 960).expect("pull");
    assert_eq!(report.frames, 480);
    assert_eq!(report.concealed_frames, 0, "{report:?}");
    assert_eq!(source.status().received, 2);

    // A genuinely new session is still a rebuild.
    assert!(source.attach_session(session_key, 8));
}

#[test]
fn two_real_sockets_carry_a_peer_block() {
    let session_key = key(0x55);
    let status = Arc::new(Mutex::new(UplinkStatus::idle()));
    let (producer, consumer) = monbus::new(monbus::MIN_FRAMES);
    let config = UplinkConfig {
        bind: "127.0.0.1:0".parse().expect("loopback"),
        key: session_key,
    };
    let mut uplink = Uplink::start(
        &config,
        48_000,
        Arc::clone(&status),
        vec![UplinkSourceSpec {
            index: 0,
            id: "phone".to_string(),
            producer,
        }],
    )
    .expect("the uplink binds loopback");
    let address = uplink.local_addr();
    assert_ne!(address.port(), 0);

    let client = UdpSocket::bind("127.0.0.1:0").expect("client socket");
    client
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("timeout");

    let mut hello = [0u8; MAX_DATAGRAM_LEN];
    let length = encode_hello(&mut hello, &session_key, 1, 1).expect("hello");
    client.send_to(&hello[..length], address).expect("send hello");
    let mut reply = [0u8; MAX_DATAGRAM_LEN];
    let (length, _) = client.recv_from(&mut reply).expect("welcome");
    let welcome = decode_welcome(&reply[..length], &session_key).expect("welcome");

    let frames = signal(480);
    let mut bearer = AudioBearer::new(session_key, welcome.session);
    bearer
        .send_block(
            &client,
            address,
            audio_stream(0).expect("stream"),
            1,
            &frames,
            0,
        )
        .expect("send audio");

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut out = vec![0.0f32; 480 * 2];
    let mut got = 0usize;
    while Instant::now() < deadline && got == 0 {
        got = consumer.pop(&mut out);
        if got == 0 {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    assert_eq!(got, 480, "the peer's block arrived through the real socket");
    for frame in 0..480 {
        let expected = f32::from(frames[frame]) / 32_768.0;
        assert!((out[frame * 2] - expected).abs() < 1e-6, "frame {frame}");
    }
    assert_eq!(status.lock().expect("status").sessions, 1);
    uplink.stop();
}

#[test]
fn an_audio_stream_with_no_peer_source_is_counted_not_mixed() {
    let session_key = key(0x66);
    let status = Arc::new(Mutex::new(UplinkStatus::idle()));
    let (producer, consumer) = monbus::new(monbus::MIN_FRAMES);
    let config = UplinkConfig {
        bind: "127.0.0.1:0".parse().expect("loopback"),
        key: session_key,
    };
    let mut uplink = Uplink::start(
        &config,
        48_000,
        Arc::clone(&status),
        vec![UplinkSourceSpec {
            index: 0,
            id: "phone".to_string(),
            producer,
        }],
    )
    .expect("the uplink binds loopback");
    let address = uplink.local_addr();

    let client = UdpSocket::bind("127.0.0.1:0").expect("client socket");
    client
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("timeout");
    let mut hello = [0u8; MAX_DATAGRAM_LEN];
    let length = encode_hello(&mut hello, &session_key, 1, 2).expect("hello");
    client.send_to(&hello[..length], address).expect("send hello");
    let mut reply = [0u8; MAX_DATAGRAM_LEN];
    let (length, _) = client.recv_from(&mut reply).expect("welcome");
    let welcome = decode_welcome(&reply[..length], &session_key).expect("welcome");

    // Stream 0x1005 names no source: only index 0 (0x1000) exists.
    let frames = signal(480);
    let mut bearer = AudioBearer::new(session_key, welcome.session);
    bearer
        .send_block(
            &client,
            address,
            audio_stream(5).expect("stream"),
            1,
            &frames,
            0,
        )
        .expect("send audio");

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut rejected = 0u64;
    while Instant::now() < deadline && rejected == 0 {
        rejected = status
            .lock()
            .expect("status")
            .rejected;
        if rejected == 0 {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    assert!(rejected >= 1, "the unmapped stream was counted");
    let snapshot = status.lock().expect("status").clone();
    assert_eq!(snapshot.sources.len(), 1);
    assert_eq!(snapshot.sources[0].received, 0, "nothing was mixed");
    let mut out = vec![0.0f32; 2];
    assert_eq!(consumer.pop(&mut out), 0);
    uplink.stop();
}
