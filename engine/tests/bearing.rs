//! The P3 audio bearer: real packetization, authentication, jitter buffering
//! and resampling, with no sound card anywhere. Only the loopback test uses two
//! real UDP endpoints, because there the transport itself is the point.

use std::net::UdpSocket;
use std::time::Duration;

use jawn_audio::{
    decode, Accepted, AudioBearer, AudioReceiver, BearerError, ClockOffset, Codec, LinearResampler,
    AUDIO_MAC_LEN, AUDIO_STREAM_BASE, DEADLINE_GUARD_FRAMES, DEFAULT_JITTER_FRAMES, HEADER_LEN,
    MAX_DATAGRAM_LEN,
};

fn key(seed: u8) -> [u8; 32] {
    [seed; 32]
}

/// A deterministic interleaved pattern: every sample differs from its
/// neighbours, so a shifted block cannot compare equal by accident.
fn signal(frames: usize, channels: u8) -> Vec<i16> {
    (0..frames * channels as usize)
        .map(|index| ((index as i32 * 37) % 4001 - 2000) as i16)
        .collect()
}

fn sine(frames: usize, hz: f64, sample_rate: f64, amplitude: f64) -> Vec<i16> {
    (0..frames)
        .map(|index| {
            let phase = 2.0 * std::f64::consts::PI * hz * index as f64 / sample_rate;
            (amplitude * phase.sin()).round() as i16
        })
        .collect()
}

fn zero_crossings(samples: &[i16]) -> usize {
    let mut crossings = 0usize;
    let mut previous = 0i32;
    for &sample in samples {
        let value = sample as i32;
        if value == 0 {
            continue;
        }
        if previous != 0 && (value > 0) != (previous > 0) {
            crossings += 1;
        }
        previous = value;
    }
    crossings
}

fn datagrams(bearer: &mut AudioBearer, stream: u16, channels: u8, frames: &[i16], master: u64) -> Vec<Vec<u8>> {
    let mut collected = Vec::new();
    bearer
        .packetize(stream, channels, frames, master, |datagram| {
            collected.push(datagram.to_vec());
            Ok(())
        })
        .expect("packetize");
    collected
}

#[test]
fn a_datagram_round_trips_and_a_wrong_key_or_foreign_session_is_refused() {
    let session = 0xA1B2_C3D4;
    let stream = AUDIO_STREAM_BASE;
    let channels = 2u8;
    let master = 123_456u64;
    let frames = signal(700, channels); // 512 + 188: two datagrams.

    let mut bearer = AudioBearer::new(key(0x11), session);
    let sent = datagrams(&mut bearer, stream, channels, &frames, master);
    assert_eq!(sent.len(), 2);
    assert_eq!(bearer.counters().sent, 2);

    for (index, datagram) in sent.iter().enumerate() {
        // Layout: 0..32 header, then the whole body, then the 16-byte tag.
        let (header, offset) = decode(datagram).expect("decode");
        assert_eq!(offset, HEADER_LEN);
        assert_eq!(header.codec, Codec::Pcm16);
        assert_eq!(header.session, session);
        assert_eq!(header.stream, stream);
        assert_eq!(header.channels, channels);
        assert_eq!(header.seq, index as u32);
        assert_eq!(header.master_sample, master + (index * 512) as u64);
        let body = &datagram[HEADER_LEN..datagram.len() - AUDIO_MAC_LEN];
        assert_eq!(body.len() % (channels as usize * 2), 0);
        assert!(body.len() / (channels as usize * 2) <= 512);
    }

    let mut receiver = AudioReceiver::new(key(0x11), session, stream, channels, DEFAULT_JITTER_FRAMES)
        .expect("receiver");
    for datagram in &sent {
        assert_eq!(receiver.accept(datagram), Ok(Accepted::Buffered));
    }
    assert_eq!(receiver.counters().received, 2);
    assert_eq!(receiver.counters().rejected, 0);

    let mut pulled = vec![0i16; frames.len()];
    let report = receiver.pull(&mut pulled, 700);
    assert_eq!(report.master_sample, master);
    assert_eq!(report.frames, 700);
    assert!(!report.discontinuity);
    assert_eq!(report.concealed_frames, 0);
    assert_eq!(pulled, frames);

    // The same bytes with a different key is authenticated by nobody.
    let mut wrong_key =
        AudioReceiver::new(key(0x22), session, stream, channels, DEFAULT_JITTER_FRAMES)
            .expect("receiver");
    assert_eq!(wrong_key.accept(&sent[0]), Err(BearerError::BadTag));
    assert_eq!(wrong_key.counters().rejected, 1);
    assert_eq!(wrong_key.counters().received, 0);

    // A key that is right but a session the master never issued is foreign.
    let mut foreign =
        AudioReceiver::new(key(0x11), session + 1, stream, channels, DEFAULT_JITTER_FRAMES)
            .expect("receiver");
    assert_eq!(foreign.accept(&sent[0]), Err(BearerError::Session(session)));
    assert_eq!(foreign.counters().rejected, 1);
    assert_eq!(foreign.counters().received, 0);
}

#[test]
fn out_of_order_and_duplicate_delivery_produce_contiguous_audio() {
    let session = 5;
    let stream = AUDIO_STREAM_BASE + 3;
    let channels = 1u8;
    let frames = signal(3 * 512, channels);

    let mut bearer = AudioBearer::new(key(0x33), session);
    let sent = datagrams(&mut bearer, stream, channels, &frames, 0);
    assert_eq!(sent.len(), 3);

    let mut receiver = AudioReceiver::new(key(0x33), session, stream, channels, DEFAULT_JITTER_FRAMES)
        .expect("receiver");
    assert_eq!(receiver.accept(&sent[0]), Ok(Accepted::Buffered));
    assert_eq!(receiver.accept(&sent[2]), Ok(Accepted::Buffered));
    assert_eq!(receiver.accept(&sent[1]), Ok(Accepted::OutOfOrder));
    assert_eq!(receiver.accept(&sent[1]), Ok(Accepted::Late));

    let counters = receiver.counters();
    assert_eq!(counters.received, 4);
    assert_eq!(counters.rejected, 0);
    assert_eq!(counters.out_of_order, 1);
    assert_eq!(counters.late, 1);

    let mut pulled = vec![0i16; frames.len()];
    let report = receiver.pull(&mut pulled, 3 * 512);
    assert_eq!(report.frames, 3 * 512);
    assert!(!report.discontinuity);
    assert_eq!(report.concealed_frames, 0);
    assert_eq!(pulled, frames);
}

#[test]
fn a_lost_packet_becomes_silence_and_a_discontinuity_without_shifting() {
    let session = 6;
    let stream = AUDIO_STREAM_BASE + 4;
    let channels = 1u8;
    let frames = signal(3 * 512, channels);

    let mut bearer = AudioBearer::new(key(0x44), session);
    let sent = datagrams(&mut bearer, stream, channels, &frames, 0);
    assert_eq!(sent.len(), 3);

    let mut receiver = AudioReceiver::new(key(0x44), session, stream, channels, DEFAULT_JITTER_FRAMES)
        .expect("receiver");
    // Packet 1 never arrives. Packet 2 does, which is what proves the hole.
    assert_eq!(receiver.accept(&sent[0]), Ok(Accepted::Buffered));
    assert_eq!(receiver.accept(&sent[2]), Ok(Accepted::Buffered));
    assert_eq!(receiver.counters().received, 2);
    assert_eq!(receiver.counters().late, 0);

    // Fill with a non-zero sentinel so an unwritten silence is not mistaken
    // for a correctly concealed one.
    let mut pulled = vec![1i16; frames.len()];
    let report = receiver.pull(&mut pulled, 3 * 512);
    assert_eq!(report.master_sample, 0);
    assert_eq!(report.frames, 3 * 512);
    assert!(report.discontinuity, "the gap must be flagged");
    assert_eq!(report.concealed_frames, 512);

    assert_eq!(&pulled[..512], &frames[..512]);
    assert!(pulled[512..1024].iter().all(|sample| *sample == 0));
    // The timeline did not shift: packet 2 is still where it said it was.
    assert_eq!(&pulled[1024..], &frames[1024..]);
    assert_eq!(receiver.next_master(), 3 * 512);

    let counters = receiver.counters();
    assert_eq!(counters.gaps, 1);
    assert_eq!(counters.concealed_frames, 512);
    assert_eq!(counters.late, 0);
}

#[test]
fn a_lost_tail_is_not_concealed_by_pull_and_the_deadline_conceals_it() {
    let session = 12;
    let stream = AUDIO_STREAM_BASE + 12;
    let channels = 1u8;
    let frames = signal(3 * 512, channels);

    let mut bearer = AudioBearer::new(key(0x99), session);
    let sent = datagrams(&mut bearer, stream, channels, &frames, 0);
    assert_eq!(sent.len(), 3);

    let mut receiver =
        AudioReceiver::new(key(0x99), session, stream, channels, DEFAULT_JITTER_FRAMES)
            .expect("receiver");
    // The last packet never arrives. Two real packets do.
    assert_eq!(receiver.accept(&sent[0]), Ok(Accepted::Buffered));
    assert_eq!(receiver.accept(&sent[1]), Ok(Accepted::Buffered));

    // `pull` cannot prove the tail is lost, so it stops after the real audio.
    let mut pulled = vec![1i16; 3 * 512];
    let report = receiver.pull(&mut pulled, 3 * 512);
    assert_eq!(report.frames, 2 * 512);
    assert_eq!(report.concealed_frames, 0);
    assert!(!report.discontinuity);
    assert!(!report.from_deadline);
    assert_eq!(receiver.next_master(), 2 * 512);

    // Still inside the guard: nothing is declared lost yet.
    let mut held = vec![1i16; 512];
    let report = receiver.pull_at(&mut held, 512, (2 * 512 + DEADLINE_GUARD_FRAMES) as i64);
    assert_eq!(report.frames, 0, "the guard keeps a frame in flight alive");
    assert!(!report.from_deadline);
    assert_eq!(receiver.next_master(), 2 * 512);

    // A caller whose master clock has passed the whole span declares it lost.
    let mut concealed = vec![1i16; 512];
    let now = (3 * 512 + DEADLINE_GUARD_FRAMES) as i64;
    let report = receiver.pull_at(&mut concealed, 512, now);
    assert_eq!(report.master_sample, 2 * 512);
    assert_eq!(report.frames, 512);
    assert_eq!(report.concealed_frames, 512);
    assert!(report.discontinuity);
    assert!(report.from_deadline, "the deadline, not later audio, closed it");
    assert!(concealed.iter().all(|sample| *sample == 0));
    assert_eq!(receiver.next_master(), 3 * 512);
    assert_eq!(receiver.counters().concealed_frames, 512);
    assert_eq!(receiver.counters().gaps, 1);
}

#[test]
fn a_datagram_after_the_deadline_is_late_and_does_not_shift_the_timeline() {
    let session = 13;
    let stream = AUDIO_STREAM_BASE + 13;
    let channels = 1u8;
    let frames = signal(3 * 512, channels);

    let mut bearer = AudioBearer::new(key(0xAA), session);
    let sent = datagrams(&mut bearer, stream, channels, &frames, 0);
    assert_eq!(sent.len(), 3);

    let mut receiver =
        AudioReceiver::new(key(0xAA), session, stream, channels, DEFAULT_JITTER_FRAMES)
            .expect("receiver");
    assert_eq!(receiver.accept(&sent[0]), Ok(Accepted::Buffered));
    assert_eq!(receiver.accept(&sent[1]), Ok(Accepted::Buffered));

    // Drain the two good packets first; `pull` then stops at the lost tail.
    let mut drained = vec![1i16; 2 * 512];
    let report = receiver.pull(&mut drained, 2 * 512);
    assert_eq!(report.frames, 2 * 512);
    assert_eq!(report.concealed_frames, 0);

    // The deadline conceals the missing third packet's span.
    let mut concealed = vec![1i16; 512];
    let report = receiver.pull_at(&mut concealed, 512, (3 * 512 + DEADLINE_GUARD_FRAMES) as i64);
    assert_eq!(report.concealed_frames, 512);
    assert!(report.from_deadline);
    assert_eq!(receiver.next_master(), 3 * 512);

    // That packet arrives after the deadline. It is counted late, not inserted,
    // and the read cursor does not move backwards to its position.
    assert_eq!(receiver.accept(&sent[2]), Ok(Accepted::Late));
    assert_eq!(receiver.counters().late, 1);
    assert_eq!(receiver.counters().received, 3);
    assert_eq!(receiver.next_master(), 3 * 512);

    // Nothing is left to read; the timeline stays where it was.
    let mut out = vec![1i16; 512];
    let report = receiver.pull(&mut out, 512);
    assert_eq!(report.frames, 0);
    assert_eq!(report.master_sample, 3 * 512);
    assert_eq!(receiver.next_master(), 3 * 512);
}

#[test]
fn drift_zero_preserves_a_one_kilohertz_sine() {
    let input = sine(48_000, 1_000.0, 48_000.0, 12_000.0);
    let mut resampler = LinearResampler::with_capacity(ClockOffset::new(0, 0.0), 4_096);
    let mut output = Vec::with_capacity(input.len());

    for block in input.chunks(1_024) {
        resampler.push(block).expect("push");
        let mut produced = vec![0i16; block.len()];
        let written = resampler.process(&mut produced);
        output.extend_from_slice(&produced[..written]);
    }

    // One sample is always carried to the next call; a stream loses nothing.
    assert!(
        output.len() + 2 >= input.len(),
        "kept {} of {} samples",
        output.len(),
        input.len()
    );
    let mut worst = 0i32;
    for (produced, original) in output.iter().zip(&input) {
        worst = worst.max((*produced as i32 - *original as i32).abs());
    }
    assert!(worst <= 1, "drift 0 must be transparent, worst error {worst}");
    // One second of 1 kHz is 2000 crossings; the carried sample leaves one
    // crossing at the tail.
    assert!(
        (zero_crossings(&output) as i64 - 2_000).abs() <= 2,
        "still 1 kHz"
    );
}

#[test]
fn a_hundred_ppm_fast_peer_clock_resamples_to_the_master_rate() {
    let ppm = 100.0f64;
    let epsilon = ppm / 1_000_000.0;
    let peer_rate = 48_000.0 * (1.0 + epsilon);
    let seconds = 2.0;

    // A physical 1 kHz tone as the fast peer's own ADC would record it: the
    // local period is longer than 48 samples because the clock runs fast.
    let input = sine(
        (peer_rate * seconds).round() as usize,
        1_000.0,
        peer_rate,
        12_000.0,
    );
    let offset = ClockOffset::new(0, ppm);
    let mut resampler = LinearResampler::with_capacity(offset, 4_096);
    let mut output = Vec::new();

    for block in input.chunks(512) {
        resampler.push(block).expect("push");
        let mut produced = vec![0i16; block.len()];
        let written = resampler.process(&mut produced);
        output.extend_from_slice(&produced[..written]);
    }

    // Compensating the fast clock produces one master second of output per
    // (1 + ppm) peer seconds. Without it the count would be about ten samples
    // long over this run.
    let expected = (48_000.0 * seconds) as i64;
    assert!(
        (output.len() as i64 - expected).abs() <= 5,
        "got {} frames, expected {expected}",
        output.len()
    );

    // 2 s of a 1 kHz tone is 4000 zero crossings if the frequency survived.
    let crossings = zero_crossings(&output);
    assert!(
        (crossings as i64 - 4_000).abs() <= 4,
        "frequency did not survive: {crossings} crossings"
    );

    // The master cursor is exactly where to_master puts the input's end.
    let end = offset.to_master(input.len() as u64);
    assert!(
        (resampler.master_position() - end).abs() <= 2,
        "cursor {} vs to_master {end}",
        resampler.master_position()
    );
}

#[test]
fn a_large_master_offset_keeps_its_position() {
    let session = 9;
    let stream = AUDIO_STREAM_BASE + 10;
    let channels = 1u8;
    let offset = ClockOffset::new(4_000_000_000, 0.0);
    let base_master = 5_000_000_000u64;
    assert_eq!(offset.to_master(48_000), 4_000_048_000);

    let frames = signal(512, channels);
    let mut bearer = AudioBearer::new(key(0x66), session);
    let sent = datagrams(&mut bearer, stream, channels, &frames, base_master);
    assert_eq!(sent.len(), 1);

    let mut receiver = AudioReceiver::new(key(0x66), session, stream, channels, DEFAULT_JITTER_FRAMES)
        .expect("receiver");
    receiver.accept(&sent[0]).expect("accept");
    assert_eq!(receiver.next_master(), base_master);

    let mut pulled = vec![0i16; 512];
    let report = receiver.pull(&mut pulled, 512);
    assert_eq!(report.master_sample, base_master);
    assert_eq!(report.frames, 512);
    assert_eq!(pulled, frames);

    let mut resampler = LinearResampler::new(offset);
    assert_eq!(resampler.master_position(), 4_000_000_000);
    let input = signal(100, 1);
    resampler.push(&input).expect("push");
    let mut produced = vec![0i16; 200];
    let written = resampler.process(&mut produced);
    assert!(written >= 98, "processed {written} of 100");
    assert_eq!(
        resampler.master_position() - 4_000_000_000,
        written as i64
    );
}

#[test]
fn a_datagram_beyond_the_window_is_rejected_instead_of_growing_memory() {
    let session = 11;
    let stream = AUDIO_STREAM_BASE + 11;
    let channels = 1u8;
    let frames = signal(512, channels);
    let mut bearer = AudioBearer::new(key(0x88), session);

    let near = datagrams(&mut bearer, stream, channels, &frames, 0);
    let far = datagrams(&mut bearer, stream, channels, &frames, 3 * 1_024);

    let mut receiver =
        AudioReceiver::new(key(0x88), session, stream, channels, 1_024).expect("receiver");
    assert_eq!(receiver.window_frames(), 1_024);
    assert_eq!(receiver.accept(&near[0]), Ok(Accepted::Buffered));
    assert_eq!(receiver.accept(&far[0]), Err(BearerError::Window));

    let counters = receiver.counters();
    assert_eq!(counters.received, 1, "the far datagram was not received");
    assert_eq!(counters.rejected, 1);
    assert_eq!(counters.late, 0);
}

#[test]
fn two_engines_carry_a_block_over_loopback_udp() {
    let session = 42;
    let stream = AUDIO_STREAM_BASE + 7;
    let channels = 2u8;
    let frames = signal(1_000, channels); // 512 + 488: two datagrams.

    let receiver_socket = UdpSocket::bind("127.0.0.1:0").expect("bind receiver");
    receiver_socket
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("read timeout");
    let address = receiver_socket.local_addr().expect("receiver address");
    let sender_socket = UdpSocket::bind("127.0.0.1:0").expect("bind sender");

    let mut bearer = AudioBearer::new(key(0x77), session);
    let sent = bearer
        .send_block(
            &sender_socket,
            address,
            stream,
            channels,
            &frames,
            1_000,
        )
        .expect("send");
    assert_eq!(sent, 2);

    let mut receiver = AudioReceiver::new(key(0x77), session, stream, channels, DEFAULT_JITTER_FRAMES)
        .expect("receiver");
    let mut buffer = [0u8; MAX_DATAGRAM_LEN];
    for _ in 0..sent {
        let (length, _) = receiver_socket.recv_from(&mut buffer).expect("recv");
        receiver.accept(&buffer[..length]).expect("accept");
    }
    assert_eq!(receiver.counters().received, 2);

    let mut pulled = vec![0i16; frames.len()];
    let report = receiver.pull(&mut pulled, 1_000);
    assert_eq!(report.master_sample, 1_000);
    assert_eq!(report.frames, 1_000);
    assert!(!report.discontinuity);
    assert_eq!(pulled, frames);
}
