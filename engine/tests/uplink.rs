//! P4's master side: a peer's audio becomes a patch source ring.
//!
//! These tests exercise the same code the `--serve --uplink` thread runs: a
//! real `ClockMaster` issues a session, `AudioBearer` datagrams for that
//! session fill a source's ring, and `pull_at` conceals a lost tail. Several of
//! them use real UDP sockets, because there the transport and the per-stream
//! session rule are the point: two peers feed two sources, a second session on a
//! live stream is refused, and a re-handshake only rebuilds the peer's own
//! source.

use std::net::{SocketAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use jawn_audio::monbus;
use jawn_audio::{
    audio_stream, decode_welcome, encode_hello, Accepted, AudioBearer, BearerError,
    ClockMaster, ControlReply, ManualClock, Offer, Uplink, UplinkConfig, UplinkSource,
    UplinkSourceSpec, UplinkStatus, DEADLINE_GUARD_FRAMES, MAX_DATAGRAM_LEN, PULL_FRAMES,
};

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

/// A second pattern, distinct from [`signal`] at every position, for the other
/// peer: a block that leaked across streams could not compare equal.
fn other_signal(frames: usize) -> Vec<i16> {
    (0..frames)
        .map(|index| ((index as i32 * 31) % 3001 - 1500) as i16)
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

fn loopback_origin(port: u16) -> SocketAddr {
    format!("127.0.0.1:{port}").parse().expect("loopback origin")
}

#[test]
fn a_clock_handshake_and_audio_datagram_fill_the_source_ring() {
    let session_key = key(0x11);
    let mut master = ClockMaster::new(session_key);
    let clock = ManualClock::new(1_000);
    let mut reply = [0u8; MAX_DATAGRAM_LEN];
    let mut hello = [0u8; MAX_DATAGRAM_LEN];
    let length = encode_hello(&mut hello, &session_key, 1, 0xABCD, None).expect("hello");
    let answer = master
        .answer(&hello[..length], &clock, &mut reply)
        .expect("the master answers a keyed hello");
    assert!(matches!(answer, ControlReply::Welcome(_)));
    let welcome = decode_welcome(&reply[..answer.length()], &session_key).expect("welcome");

    let (producer, consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source = UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    let origin = loopback_origin(9000);
    assert!(!source.has_session(), "no receiver before audio claims the stream");
    assert_eq!(source.session(), None);

    let frames = signal(480);
    let mut bearer = AudioBearer::new(session_key, welcome.session);
    let sent = datagrams(&mut bearer, source.stream(), &frames, 0);

    // The handshake does not attach a receiver; the first authenticated audio
    // datagram does. That is what keeps one peer's WELCOME away from another
    // peer's stream.
    assert_eq!(
        source.offer(
            session_key,
            welcome.session,
            origin,
            false,
            true,
            None,
            &sent[0]
        ),
        Offer::Taken(Accepted::Buffered),
        "the first authenticated datagram claims the stream"
    );
    assert!(source.has_session());
    assert_eq!(source.session(), Some(welcome.session));

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
    let length = encode_hello(&mut hello, &wrong_key, 1, 7, None).expect("hello");
    assert!(
        master.answer(&hello[..length], &clock, &mut reply).is_none(),
        "a hello for another key gets no welcome"
    );

    // Without a session there is nothing to authenticate audio for at all.
    let (producer, consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source = UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    let origin = loopback_origin(9001);
    let frames = signal(480);
    let mut bearer = AudioBearer::new(wrong_key, 99);
    let sent = datagrams(&mut bearer, audio_stream(0).expect("stream"), &frames, 0);
    assert_eq!(
        source.accept(&sent[0]),
        Err(BearerError::Session(0)),
        "no session means no receiver"
    );

    // With a live session, a datagram keyed differently is refused, and the
    // candidate never replaced anything: a bad tag cannot claim the stream.
    assert_eq!(
        source.offer(session_key, 99, origin, false, true, None, &sent[0]),
        Offer::Refused(BearerError::BadTag)
    );
    assert!(!source.has_session(), "a bad tag attached nothing");
    let mut out = vec![0.0f32; 2];
    assert_eq!(consumer.pop(&mut out), 0, "nothing reached the ring");

    // A session this master never issued cannot claim the stream either, even
    // with a well-formed datagram.
    assert_eq!(
        source.offer(session_key, 99, origin, false, false, None, &sent[0]),
        Offer::Refused(BearerError::Session(99))
    );
}

#[test]
fn a_lost_tail_is_concealed_and_visible_in_the_counters() {
    let session_key = key(0x44);
    let (producer, _consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source = UplinkSource::new(0, "phone".to_string(), producer).expect("source");

    // Only 100 frames arrive; the rest of the deadline's block is lost.
    let frames = signal(100);
    let mut bearer = AudioBearer::new(session_key, 7);
    let sent = datagrams(&mut bearer, source.stream(), &frames, 0);
    assert_eq!(
        source.offer(session_key, 7, loopback_origin(9002), false, true, None, &sent[0]),
        Offer::Taken(Accepted::Buffered)
    );

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
    let mut source = UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    let origin = loopback_origin(9003);

    // One block from the first session is accepted and pulled.
    let frames = signal(480);
    let mut bearer = AudioBearer::new(session_key, 7);
    let sent = datagrams(&mut bearer, source.stream(), &frames, 0);
    assert_eq!(
        source.offer(session_key, 7, origin, false, true, None, &sent[0]),
        Offer::Taken(Accepted::Buffered)
    );
    assert_eq!(source.pump(PULL_FRAMES, 0).expect("a session pulls").frames, 480);
    let before = source.status();
    assert_eq!(before.received, 1);

    // The peer re-handshakes after a quiet spell on the same socket: a new
    // session, a new receiver, but the counters and the master clock stay.
    let mut bearer = AudioBearer::new(session_key, 8);
    let sent = datagrams(&mut bearer, source.stream(), &frames, 0);
    assert_eq!(
        source.offer(session_key, 8, origin, true, true, None, &sent[0]),
        Offer::Taken(Accepted::Buffered),
        "the same endpoint may rebuild its own source"
    );
    let after = source.status();
    assert_eq!(
        after.received,
        before.received + 1,
        "the datagram that took the stream is authenticated and counted"
    );
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
    assert_eq!(source.pump(PULL_FRAMES, 0).expect("the new session pulls").frames, 480);
    let later = source.status();
    assert_eq!(later.received, before.received + 1);
}

#[test]
fn a_same_session_is_placed_while_a_new_one_rebuilds() {
    let session_key = key(0x78);
    let (producer, _consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source = UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    let origin = loopback_origin(9004);

    // Two blocks arrive; the first is pulled, the second stays buffered.
    let frames = signal(960);
    let mut bearer = AudioBearer::new(session_key, 7);
    let blocks: Vec<Vec<Vec<u8>>> = frames
        .chunks(480)
        .enumerate()
        .map(|(index, chunk)| {
            datagrams(&mut bearer, source.stream(), chunk, (index * 480) as u64)
        })
        .collect();
    assert_eq!(
        source.offer(session_key, 7, origin, false, true, None, &blocks[0][0]),
        Offer::Taken(Accepted::Buffered)
    );
    assert_eq!(source.accept(&blocks[1][0]), Ok(Accepted::Buffered));
    assert_eq!(source.pump(PULL_FRAMES, 0).expect("pull").frames, 480);

    // A retried HELLO is answered with the same session, which is the ordinary
    // path: nothing is rebuilt and the waiting block is untouched. Rebuilding
    // here would discard it and the next pull would conceal the hole.
    assert_eq!(
        source.offer(session_key, 7, origin, true, true, None, &blocks[0][0]),
        Offer::Placed(Accepted::Late),
        "the owning session never rebuilds the receiver"
    );
    let report = source.pump(PULL_FRAMES, 960).expect("pull");
    assert_eq!(report.frames, 480);
    assert_eq!(report.concealed_frames, 0, "{report:?}");

    // A genuinely new session from the same endpoint is still a rebuild.
    let mut bearer = AudioBearer::new(session_key, 8);
    let sent = datagrams(&mut bearer, source.stream(), &frames[..480], 960);
    assert!(
        matches!(
            source.offer(session_key, 8, origin, true, true, None, &sent[0]),
            Offer::Taken(_)
        ),
        "a new session for the same peer rebuilds its source"
    );
}

#[test]
fn a_datagram_delayed_inside_the_buffer_is_placed_not_late() {
    let session_key = key(0x99);
    let (producer, consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source = UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    let mut bearer = AudioBearer::new(session_key, 7);

    let base = 100_000u64;
    let signal_all = signal(3 * 480);
    let block_a = signal_all[..480].to_vec();
    let block_b = signal_all[480..960].to_vec();
    let block_c = signal_all[960..].to_vec();

    // A arrives. The playback head is still behind it, so nothing is read.
    let sent = datagrams(&mut bearer, source.stream(), &block_a, base);
    assert_eq!(
        source.offer(session_key, 7, loopback_origin(9005), false, true, None, &sent[0]),
        Offer::Taken(Accepted::Buffered)
    );
    assert!(
        source.pump_to(base).is_none(),
        "the head has not reached A yet"
    );

    // C arrives before B: a reordered datagram, but still inside the window.
    for datagram in datagrams(&mut bearer, source.stream(), &block_c, base + 960) {
        assert_eq!(source.accept(&datagram), Ok(Accepted::Buffered));
    }

    // The head advances one block. Only A is due; C is ahead and is not read,
    // and the cursor stops exactly at the head instead of jumping to C.
    let report = source.pump_to(base + 480).expect("a session pulls");
    assert_eq!(report.frames, 480);
    assert_eq!(report.concealed_frames, 0, "{report:?}");

    // B arrives late by nearly the whole buffer, before the head reaches it.
    // The read cursor trails the clock, so B is still ahead of it.
    for datagram in datagrams(&mut bearer, source.stream(), &block_b, base + 480) {
        assert!(
            matches!(source.accept(&datagram), Ok(Accepted::Buffered | Accepted::OutOfOrder)),
            "a delayed datagram inside the buffer is placed, not refused"
        );
    }
    let report = source.pump_to(base + 960).expect("the head reached B");
    assert_eq!(report.frames, 480);
    assert_eq!(report.concealed_frames, 0, "{report:?}");
    assert_eq!(source.status().late, 0, "nothing was dropped as already read");

    // The ring holds A then B, in order and untouched.
    let mut out = vec![0.0f32; 960 * 2];
    assert_eq!(consumer.pop(&mut out), 960);
    for (index, expected) in block_a.iter().chain(block_b.iter()).enumerate() {
        let expected = f32::from(*expected) / 32_768.0;
        assert!((out[index * 2] - expected).abs() < 1e-6, "frame {index}");
    }
}

#[test]
fn a_declared_latency_places_a_peer_earlier_than_an_undeclared_one() {
    let session_key = key(0x9A);
    let start = 48_000u64;
    let frames = signal(480);

    let (plain_producer, plain_consumer) = monbus::new(monbus::MIN_FRAMES);
    let (late_producer, late_consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut plain = UplinkSource::new(0, "deck".to_string(), plain_producer).expect("source");
    let mut declared =
        UplinkSource::with_latency(0, "phone".to_string(), late_producer, 30.0, 48_000)
            .expect("source");

    // The same datagram, stamped at the same master position, offered to a
    // source that declares no latency and one that declares 30 ms.
    let mut bearer = AudioBearer::new(session_key, 7);
    let sent = datagrams(&mut bearer, audio_stream(0).expect("stream"), &frames, start);
    assert_eq!(
        plain.offer(session_key, 7, loopback_origin(9006), false, true, None, &sent[0]),
        Offer::Taken(Accepted::Buffered)
    );
    assert_eq!(
        declared.offer(session_key, 7, loopback_origin(9007), false, true, None, &sent[0]),
        Offer::Taken(Accepted::Buffered)
    );

    let shift = 30u64 * 48; // 30 ms at 48 kHz
    assert_eq!(plain.status().first_master, start);
    assert_eq!(
        declared.status().first_master,
        start - shift,
        "a positive declaration places the source earlier"
    );
    assert_eq!(declared.status().latency_ms, 30.0);
    assert_eq!(declared.status().latency_frames, shift);

    let plain_report = plain.pump(PULL_FRAMES, 0).expect("a session pulls");
    let declared_report = declared.pump(PULL_FRAMES, 0).expect("a session pulls");
    assert_eq!(plain_report.master_sample, start);
    assert_eq!(declared_report.master_sample, start - shift);
    assert_eq!(declared_report.frames, 480);

    // Both rings carry the same audio; only its position on the master
    // timeline differs, and both pulled cursors advanced by the same block.
    assert_block(&collect(&plain_consumer, 480), &frames);
    assert_block(&collect(&late_consumer, 480), &frames);
    assert_eq!(plain.status().next_master, start + 480);
    assert_eq!(declared.status().next_master, start - shift + 480);
}

#[test]
fn a_claimed_stream_is_the_peer_identity_not_the_port() {
    let session_key = key(0x7A);
    let (producer, _consumer) = monbus::new(monbus::MIN_FRAMES);
    let mut source = UplinkSource::new(0, "phone".to_string(), producer).expect("source");
    let peer_a = loopback_origin(9100);
    let peer_b = loopback_origin(9200);
    let peer_c = loopback_origin(9300);
    let stream = source.stream();
    let frames = signal(480);
    let block = |session: u32, master: u64| {
        let mut bearer = AudioBearer::new(session_key, session);
        datagrams(&mut bearer, stream, &frames, master)
    };

    // Session 11 claimed this source's stream in its HELLO, so the first
    // datagram claims the stream.
    assert_eq!(
        source.offer(session_key, 11, peer_a, false, true, Some(stream), &block(11, 0)[0]),
        Offer::Taken(Accepted::Buffered)
    );

    // A live session that claimed a different stream is not this source's
    // peer, even though the owner is live and the endpoint is new.
    assert_eq!(
        source.offer(
            session_key,
            12,
            peer_b,
            true,
            true,
            Some(stream + 1),
            &block(12, 0)[0]
        ),
        Offer::Refused(BearerError::Stream(stream + 1))
    );
    assert_eq!(source.session(), Some(11), "the owner did not change");
    assert_eq!(
        source.status().received,
        1,
        "the refused datagram was not placed"
    );

    // A claimless session keeps the endpoint fallback: it may not evict a live
    // peer from another endpoint.
    assert_eq!(
        source.offer(session_key, 13, peer_b, true, true, None, &block(13, 0)[0]),
        Offer::Occupied
    );

    // A new session that claimed this stream takes it over immediately, from a
    // NEW endpoint: every --send-take is a new process on a new port. This is
    // the repeat-take case, and the counters fold rather than reset.
    assert_eq!(
        source.offer(session_key, 14, peer_b, true, true, Some(stream), &block(14, 0)[0]),
        Offer::Taken(Accepted::Buffered)
    );
    assert_eq!(source.session(), Some(14));
    assert_eq!(
        source.status().received,
        2,
        "the counters survived the rebuild"
    );

    // A session the master no longer issues cannot claim the stream at all.
    assert_eq!(
        source.offer(session_key, 15, peer_b, true, false, Some(stream), &block(15, 0)[0]),
        Offer::Refused(BearerError::Session(15))
    );

    // Once the owner is no longer live (a lease expiry or a master restart), a
    // claimless session from another endpoint may take it over too.
    assert_eq!(
        source.offer(session_key, 16, peer_c, false, true, None, &block(16, 0)[0]),
        Offer::Taken(Accepted::Buffered)
    );
    assert_eq!(source.session(), Some(16));
    assert_eq!(source.status().received, 3);
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
            latency_ms: 0.0,
        }],
    )
    .expect("the uplink binds loopback");
    let started = Instant::now();
    let address = uplink.local_addr();
    assert_ne!(address.port(), 0);

    let client = peer_socket();
    let session = handshake_session(&client, address, &session_key, 1, Some(audio_stream(0).expect("stream")));

    let frames = signal(480);
    let mut bearer = AudioBearer::new(session_key, session);
    bearer
        .send_block(
            &client,
            address,
            audio_stream(0).expect("stream"),
            1,
            &frames,
            stamp(&started),
        )
        .expect("send audio");

    let collected = collect(&consumer, 480);
    assert_block(&collected, &frames);
    assert_eq!(status.lock().expect("status").sessions, 1);
    uplink.stop();
}

#[test]
fn two_peers_share_the_uplink_and_a_third_cannot_take_a_busy_stream() {
    let session_key = key(0x5A);
    let status = Arc::new(Mutex::new(UplinkStatus::idle()));
    let (phone_producer, phone_consumer) = monbus::new(monbus::MIN_FRAMES);
    let (deck_producer, deck_consumer) = monbus::new(monbus::MIN_FRAMES);
    let config = UplinkConfig {
        bind: "127.0.0.1:0".parse().expect("loopback"),
        key: session_key,
    };
    let mut uplink = Uplink::start(
        &config,
        48_000,
        Arc::clone(&status),
        vec![
            UplinkSourceSpec {
                index: 0,
                id: "phone".to_string(),
                producer: phone_producer,
                latency_ms: 0.0,
            },
            UplinkSourceSpec {
                index: 1,
                id: "deck".to_string(),
                producer: deck_producer,
                latency_ms: 0.0,
            },
        ],
    )
    .expect("the uplink binds loopback");
    let started = Instant::now();
    let address = uplink.local_addr();
    let phone = peer_socket();
    let deck = peer_socket();
    let intruder = peer_socket();

    // Two peers, two sessions, two claimed streams.
    let phone_session = handshake_session(
        &phone,
        address,
        &session_key,
        41,
        Some(audio_stream(0).expect("stream 0")),
    );
    let deck_session = handshake_session(
        &deck,
        address,
        &session_key,
        42,
        Some(audio_stream(1).expect("stream 1")),
    );
    assert_ne!(phone_session, deck_session);

    let phone_frames = signal(480);
    let deck_frames = other_signal(480);
    let phone_stamp = stamp(&started);
    let deck_stamp = stamp(&started);
    let mut phone_bearer = AudioBearer::new(session_key, phone_session);
    phone_bearer
        .send_block(&phone, address, audio_stream(0).expect("stream 0"), 1, &phone_frames, phone_stamp)
        .expect("phone audio");
    let mut deck_bearer = AudioBearer::new(session_key, deck_session);
    deck_bearer
        .send_block(&deck, address, audio_stream(1).expect("stream 1"), 1, &deck_frames, deck_stamp)
        .expect("deck audio");

    // Each source receives its own peer's audio, and only its own.
    let phone_got = collect(&phone_consumer, 480);
    let deck_got = collect(&deck_consumer, 480);
    assert_block(&phone_got, &phone_frames);
    assert_block(&deck_got, &deck_frames);

    // The status is published after the wake's pulls, so wait for the snapshot
    // that reflects both accepted datagrams.
    wait_for(|| {
        let now = status.lock().expect("status");
        now.sessions == 2
            && now.sources.len() == 2
            && now.sources[0].received == 1
            && now.sources[1].received == 1
    });
    let snapshot = status.lock().expect("status").clone();
    let phone_first = snapshot.sources[0].first_master;
    let deck_first = snapshot.sources[1].first_master;
    assert_ne!(phone_first, 0);
    assert_ne!(deck_first, 0);

    // A retried HELLO (same nonce) gets the same session back: it is not a new
    // session, and it leaves both receivers' timelines where they were.
    assert_eq!(
        handshake_session(
            &phone,
            address,
            &session_key,
            41,
            Some(audio_stream(0).expect("stream 0")),
        ),
        phone_session
    );
    wait_for(|| {
        let now = status.lock().expect("status");
        now.sessions == 2
            && now.sources[0].first_master == phone_first
            && now.sources[1].first_master == deck_first
    });

    // A third peer claims its own stream, then tries the phone's busy stream.
    // It is refused and counted, and its audio never reaches the ring.
    let intruder_session = handshake_session(
        &intruder,
        address,
        &session_key,
        43,
        Some(audio_stream(1).expect("stream 1")),
    );
    assert_ne!(intruder_session, phone_session);
    drain(&phone_consumer);
    let rejected_before = status.lock().expect("status").rejected;
    let intruder_frames = other_signal(480);
    let mut intruder_bearer = AudioBearer::new(session_key, intruder_session);
    intruder_bearer
        .send_block(&intruder, address, audio_stream(0).expect("stream 0"), 1, &intruder_frames, stamp(&started))
        .expect("intruder audio");
    wait_for(|| status.lock().expect("status").rejected > rejected_before);

    let after_intruder = status.lock().expect("status").clone();
    assert_eq!(
        after_intruder.sources[0].received, 1,
        "the busy stream did not take the intruder's datagram"
    );
    assert!(
        after_intruder.rejected > rejected_before,
        "the refusal is counted in status.rejected"
    );
    assert_eq!(after_intruder.sessions, 3, "the intruder was still issued a session");
    // The phone's source conceals the silence after its one block; anything
    // non-zero here would be the intruder's audio leaking in.
    let mut out = vec![0.0f32; 480 * 2];
    let until = Instant::now() + Duration::from_millis(150);
    while Instant::now() < until {
        let got = phone_consumer.pop(&mut out);
        for sample in &out[..got * 2] {
            assert_eq!(*sample, 0.0, "the refused peer's audio reached the ring");
        }
        std::thread::sleep(Duration::from_millis(5));
    }

    // The same peer (same claimed stream) re-handshakes with a new nonce, gets
    // a new session, and only its own source is rebuilt; the deck is untouched.
    let phone_session_2 = handshake_session(
        &phone,
        address,
        &session_key,
        44,
        Some(audio_stream(0).expect("stream 0")),
    );
    assert_ne!(phone_session_2, phone_session);
    let new_stamp = stamp(&started);
    assert_ne!(new_stamp, phone_first);
    let mut phone_bearer_2 = AudioBearer::new(session_key, phone_session_2);
    phone_bearer_2
        .send_block(&phone, address, audio_stream(0).expect("stream 0"), 1, &phone_frames, new_stamp)
        .expect("phone audio on the new session");
    wait_for(|| status.lock().expect("status").sources[0].first_master == new_stamp);

    let done = status.lock().expect("status").clone();
    assert_eq!(
        done.sources[0].first_master, new_stamp,
        "the same peer rebuilt its own source"
    );
    assert_eq!(
        done.sources[1].first_master, deck_first,
        "the other peer's receiver was not rebuilt"
    );
    assert_eq!(done.sources[1].received, 1, "the other peer's stream is untouched");
    assert_eq!(done.sessions, 4);
    uplink.stop();
}

#[test]
fn a_repeat_take_from_a_new_port_takes_its_claimed_stream_back() {
    let session_key = key(0x5B);
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
            latency_ms: 0.0,
        }],
    )
    .expect("the uplink binds loopback");
    let started = Instant::now();
    let address = uplink.local_addr();
    let stream = audio_stream(0).expect("stream 0");

    // The first take: a handshake and a block, as `--send-take` does.
    let first_take = peer_socket();
    let first_session = handshake_session(&first_take, address, &session_key, 71, Some(stream));
    let first_frames = signal(480);
    let first_stamp = stamp(&started);
    let mut first_bearer = AudioBearer::new(session_key, first_session);
    first_bearer
        .send_block(&first_take, address, stream, 1, &first_frames, first_stamp)
        .expect("first take audio");
    let first_got = collect(&consumer, 480);
    assert_block(&first_got, &first_frames);
    wait_for(|| {
        let now = status.lock().expect("status");
        now.sources[0].received == 1 && now.sources[0].first_master == first_stamp
    });
    let first_port = first_take.local_addr().expect("first local address");

    // The second take is a new process on a NEW ephemeral port, so a new
    // session. It claims the same stream, so it takes its own source over at
    // once instead of waiting for the first session's 30 s lease to expire.
    let second_take = peer_socket();
    let second_port = second_take.local_addr().expect("second local address");
    assert_ne!(second_port, first_port, "a repeat take is a new endpoint");
    let second_session = handshake_session(&second_take, address, &session_key, 72, Some(stream));
    assert_ne!(second_session, first_session);
    drain(&consumer);
    let second_frames = other_signal(480);
    let second_stamp = stamp(&started);
    let mut second_bearer = AudioBearer::new(session_key, second_session);
    second_bearer
        .send_block(&second_take, address, stream, 1, &second_frames, second_stamp)
        .expect("second take audio");
    let second_got = collect_from(&consumer, &second_frames);
    assert_block(&second_got, &second_frames);
    wait_for(|| {
        let now = status.lock().expect("status");
        now.sources[0].received == 2 && now.sources[0].first_master == second_stamp
    });
    let after_repeat = status.lock().expect("status").clone();
    assert_eq!(
        after_repeat.sources[0].first_master, second_stamp,
        "the repeat take rebuilt its own source"
    );

    // A session that claims a DIFFERENT stream cannot take this source, even
    // though it is live and sending on this stream's id: the claim is checked.
    let stray = peer_socket();
    let stray_session = handshake_session(
        &stray,
        address,
        &session_key,
        73,
        Some(audio_stream(1).expect("stream 1")),
    );
    assert_ne!(stray_session, second_session);
    drain(&consumer);
    let rejected_before = status.lock().expect("status").rejected;
    let stray_frames = signal(480);
    let mut stray_bearer = AudioBearer::new(session_key, stray_session);
    stray_bearer
        .send_block(&stray, address, stream, 1, &stray_frames, stamp(&started))
        .expect("stray audio");
    wait_for(|| status.lock().expect("status").rejected > rejected_before);
    let after_stray = status.lock().expect("status").clone();
    assert_eq!(
        after_stray.sources[0].received, 2,
        "a different claimed stream was refused"
    );
    assert_eq!(
        after_stray.sources[0].first_master, second_stamp,
        "the owner did not change"
    );
    // The source conceals the silence after the second block; anything non-zero
    // here would be the stray session's audio leaking into the stream.
    let mut out = vec![0.0f32; 480 * 2];
    let until = Instant::now() + Duration::from_millis(100);
    while Instant::now() < until {
        let got = consumer.pop(&mut out);
        for sample in &out[..got * 2] {
            assert_eq!(*sample, 0.0, "the stray claim's audio reached the ring");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
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
            latency_ms: 0.0,
        }],
    )
    .expect("the uplink binds loopback");
    let address = uplink.local_addr();

    let client = peer_socket();
    let session = handshake_session(&client, address, &session_key, 2, Some(audio_stream(5).expect("stream")));

    // Stream 0x1005 names no source: only index 0 (0x1000) exists.
    let frames = signal(480);
    let mut bearer = AudioBearer::new(session_key, session);
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
        rejected = status.lock().expect("status").rejected;
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

/// A peer's UDP socket, with a read timeout so a lost reply fails the test
/// rather than hanging it.
fn peer_socket() -> UdpSocket {
    let socket = UdpSocket::bind("127.0.0.1:0").expect("peer socket");
    socket
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("timeout");
    socket
}

/// One HELLO/WELCOME exchange. A repeated `nonce` is a retried handshake and
/// gets the session the master already issued. `claim` is the audio stream the
/// peer will packetize on, or `None` for a clock-only probe.
fn handshake_session(
    socket: &UdpSocket,
    master: SocketAddr,
    key: &[u8; 32],
    nonce: u64,
    claim: Option<u16>,
) -> u32 {
    let mut hello = [0u8; MAX_DATAGRAM_LEN];
    let length = encode_hello(&mut hello, key, 1, nonce, claim).expect("hello");
    socket.send_to(&hello[..length], master).expect("send hello");
    let mut reply = [0u8; MAX_DATAGRAM_LEN];
    let (length, _) = socket.recv_from(&mut reply).expect("welcome");
    decode_welcome(&reply[..length], key)
        .expect("decode welcome")
        .session
}

/// The uplink's clock started just after `Uplink::start` returned, so this is
/// as close as a socket test can get to stamping a block at the thread's now.
fn stamp(started: &Instant) -> u64 {
    (started.elapsed().as_secs_f64() * 48_000.0) as u64
}

/// Pop `frames` stereo frames from a ring, giving the uplink time to fill it.
fn collect(consumer: &monbus::Consumer, frames: usize) -> Vec<f32> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut chunk = vec![0.0f32; frames * 2];
    let mut collected: Vec<f32> = Vec::new();
    while Instant::now() < deadline && collected.len() < frames * 2 {
        let got = consumer.pop(&mut chunk);
        if got > 0 {
            collected.extend_from_slice(&chunk[..got * 2]);
        } else {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    assert!(
        collected.len() >= frames * 2,
        "the peer's block arrived through the real socket"
    );
    collected.truncate(frames * 2);
    collected
}

/// Pop until the expected block's first sample appears, then return the next
/// `frames.len()` stereo frames. A source that has been concealing silence
/// pushes it ahead of the next take's block, so the ring is not at a block
/// boundary when a repeat take starts.
fn collect_from(consumer: &monbus::Consumer, frames: &[i16]) -> Vec<f32> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let wanted = f32::from(frames[0]) / 32_768.0;
    let wanted_len = frames.len() * 2;
    let mut chunk = vec![0.0f32; wanted_len];
    let mut collected: Vec<f32> = Vec::new();
    let mut synced = false;
    while Instant::now() < deadline && collected.len() < wanted_len {
        let got = consumer.pop(&mut chunk);
        if got == 0 {
            std::thread::sleep(Duration::from_millis(5));
            continue;
        }
        let start = if synced {
            0
        } else {
            match chunk[..got * 2]
                .iter()
                .position(|sample| *sample == wanted)
            {
                Some(index) if index % 2 == 0 => {
                    synced = true;
                    index
                }
                _ => continue,
            }
        };
        collected.extend_from_slice(&chunk[start..got * 2]);
    }
    assert!(
        collected.len() >= wanted_len,
        "the repeat take's block arrived through the real socket"
    );
    collected.truncate(wanted_len);
    collected
}

fn assert_block(collected: &[f32], frames: &[i16]) {
    for frame in 0..frames.len() {
        let expected = f32::from(frames[frame]) / 32_768.0;
        assert!(
            (collected[frame * 2] - expected).abs() < 1e-6,
            "frame {frame} was not this peer's audio"
        );
    }
}

fn drain(consumer: &monbus::Consumer) {
    let mut out = vec![0.0f32; monbus::MIN_FRAMES * 2];
    while consumer.pop(&mut out) > 0 {}
}

fn wait_for<F: Fn() -> bool>(predicate: F) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if predicate() {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!("the uplink did not reach the expected state in time");
}
