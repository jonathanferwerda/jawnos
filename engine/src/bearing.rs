//! The audio bearer: PCM16 between two engines on the clock session.
//!
//! The clock probe (`peer.rs`) proves two engines share a key and gives them a
//! session id and a fitted [`ClockOffset`]. This module carries actual audio
//! over the same authenticated session, and puts the receiver's copy back on
//! the master's timeline (docs/studio-audio-roadmap.md §10 and §13 P3).
//!
//! Nothing here opens an audio device. The input to [`AudioBearer`] is a slice
//! of interleaved `i16` frames the caller already has; the output of
//! [`AudioReceiver`] is a contiguous block of master-time samples plus the
//! gaps it had to conceal. Wiring capture and playback to the patchbay is P4.
//!
//! # The datagram
//!
//! The wire layout is exactly `peer.rs`'s, and both halves share one tag
//! implementation: [`crate::auth::mac_tag`] in `auth.rs`.
//!
//! ```text
//! offset 0                 32                      32 + body          + 16
//!         | 32-byte header | PCM16 LE interleaved | HMAC-SHA256 tag |
//! ```
//!
//! The body is `frames * channels * 2` bytes, little-endian signed 16-bit.
//! The tag is `HMAC-SHA256(key, header.encode() || body)[..16]`, the shared
//! construction in [`crate::auth`]. The header's `master_sample` is the
//! master-clock position of the body's **first** frame, so a receiver places a
//! block by where it belongs and never by when it arrived (§10).
//!
//! # Stream ids
//!
//! Audio streams live in `0x1000..=0x7FFF` ([`AUDIO_STREAM_BASE`] ..
//! [`AUDIO_STREAM_LAST`]). The clock control streams are `0xFF00..=0xFF03`
//! (`peer::STREAM_CLOCK_*`), and the engine's own small ids stay below
//! `0x1000` (the CLI self-test uses `2`). A receiver therefore refuses any
//! stream id outside the audio range, so an audio datagram can never be
//! mistaken for a clock message or a self-test message. `0x8000..=0xFEFF` and
//! `0xFF04..=0xFFFF` stay reserved for later control traffic.
//!
//! # Loss, duplicates and reordering
//!
//! [`AudioReceiver`] is a bounded jitter buffer. Datagrams whose `stream`,
//! `session`, codec, channel count or tag are wrong are *rejected*. An
//! authenticated datagram is *late* when it ends at or before the next frame
//! to read, or when every frame it carries is already buffered (a duplicate).
//! An authenticated datagram that lands behind the furthest start already seen
//! is *out of order* but still accepted if it is not late. A datagram further
//! ahead than the window is rejected rather than growing memory.
//!
//! When the reader reaches a hole that later data has already closed, it emits
//! silence for the missing span, counts the gap once, and keeps advancing the
//! master cursor by the concealed frames. The timeline never shifts. The gap is
//! reported in [`PullReport`]: `discontinuity` is set when a block conceals a
//! gap or carries the first real frame after one, and `concealed_frames` says
//! how much of this block was silence.
//!
//! [`AudioReceiver::pull`] stays conservative: it only conceals a hole that
//! later audio has already closed, so a permanently lost tail is never filled.
//! [`AudioReceiver::pull_at`] adds a leading-edge deadline: a frame whose whole
//! span ended [`DEADLINE_GUARD_FRAMES`] before the caller's master clock is
//! concealed even when no later audio proved the hole, which keeps a lost tail
//! from stalling the caller.
//!
//! # Resampling
//!
//! [`LinearResampler`] is the first-slice converter: linear interpolation
//! between adjacent peer samples, driven by [`ClockOffset::to_master`]. It is
//! deliberately replaceable — a windowed-sinc converter can take its place
//! without changing the caller (same `push` / `process` shape).

use std::net::{SocketAddr, UdpSocket};

use crate::auth::{mac_tag, tags_match};
use crate::proto::{self, Codec, Header, ProtoError, HEADER_LEN};
use crate::session::ClockOffset;

/// The bearer's name for the shared tag length ([`crate::auth::MAC_LEN`]).
pub const AUDIO_MAC_LEN: usize = crate::auth::MAC_LEN;

/// The largest number of frames one datagram may carry. 512 frames is 10.7 ms
/// at 48 kHz, and its stereo PCM body is 2048 bytes — one engine block. The
/// datagram itself carries the header and tag too, so a reader must size its
/// buffer with [`MAX_DATAGRAM_LEN`], not with the block size.
pub const MAX_FRAMES_PER_DATAGRAM: usize = 512;

/// The largest PCM body, stereo at [`MAX_FRAMES_PER_DATAGRAM`].
pub const MAX_SAMPLES_PER_DATAGRAM: usize = MAX_FRAMES_PER_DATAGRAM * 2;

/// A small device's 16 kHz stream is expanded by this factor to the master's
/// 48 kHz timeline before it is placed. `Codec::Pcm16k` carries the small-rate
/// samples, so the device sends no more than it captured and the receiver pays
/// the conversion once.
pub const PCM16K_RATIO: usize = 3;

/// The most 16 kHz frames one datagram may carry. Its expanded span must stay
/// within one master block ([`MAX_FRAMES_PER_DATAGRAM`]).
pub const MAX_PCM16K_FRAMES_PER_DATAGRAM: usize = MAX_FRAMES_PER_DATAGRAM / PCM16K_RATIO;

/// A whole datagram: header, the largest possible body, and the tag.
pub const MAX_DATAGRAM_LEN: usize =
    HEADER_LEN + MAX_SAMPLES_PER_DATAGRAM * 2 + AUDIO_MAC_LEN;

/// The first audio stream id. Low enough to leave the small control ids alone,
/// high enough to sit below the clock control block.
pub const AUDIO_STREAM_BASE: u16 = 0x1000;

/// The last audio stream id. See the module docs for the full reservation.
pub const AUDIO_STREAM_LAST: u16 = 0x7FFF;

/// The default jitter window: eight packets, about 85 ms at 48 kHz. Large
/// enough for the LAN's reordering and a slow Wi-Fi hop, small enough that a
/// lost packet is concealed rather than remembered.
pub const DEFAULT_JITTER_FRAMES: usize = 8 * MAX_FRAMES_PER_DATAGRAM;

/// The leading-edge guard for [`AudioReceiver::pull_at`]: one datagram's worth,
/// about 10.7 ms at 48 kHz. A frame is only declared lost when its whole span
/// ended this far before the caller's master clock, so a datagram still in
/// flight (or merely late) is never concealed out from under the network.
pub const DEADLINE_GUARD_FRAMES: usize = 4 * MAX_FRAMES_PER_DATAGRAM;

/// The default resampler input budget. A caller that feeds bigger blocks at a
/// time should use [`LinearResampler::with_capacity`].
pub const DEFAULT_RESAMPLER_CAPACITY: usize = 4 * MAX_FRAMES_PER_DATAGRAM;

/// Is `id` an audio stream id this build sends and accepts?
pub fn is_audio_stream(id: u16) -> bool {
    (AUDIO_STREAM_BASE..=AUDIO_STREAM_LAST).contains(&id)
}

/// The audio stream id for input `index` (0-based), or `None` when the range is
/// exhausted. Naming a stream through this helper is how the caller stays
/// inside the reserved range.
pub fn audio_stream(index: usize) -> Option<u16> {
    let offset = u16::try_from(index).ok()?;
    AUDIO_STREAM_BASE.checked_add(offset).filter(|id| is_audio_stream(*id))
}

/// Why a datagram or a resampler call was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BearerError {
    /// The 32-byte header could not be decoded.
    Proto(ProtoError),
    /// Channels were not 1 or 2, or the sample count was not a whole number of
    /// frames, or there were no frames at all.
    Shape,
    /// More frames than [`MAX_FRAMES_PER_DATAGRAM`].
    TooManyFrames(usize),
    /// Not an audio stream id (see [`is_audio_stream`]).
    Stream(u16),
    /// The datagram belongs to a different session.
    Session(u32),
    /// Shorter than a header plus a tag.
    Short,
    /// The HMAC tag did not match.
    BadTag,
    /// The destination slice is too small.
    Output,
    /// The datagram starts beyond the receiver's window, or does not fit inside
    /// it. Dropping it bounds the buffer.
    Window,
    /// The resampler's preallocated input budget is full; process before
    /// pushing more.
    PendingFull,
    /// The caller's transport failed.
    Io(std::io::ErrorKind),
}

/// The sender's counters. One per datagram handed to the transport.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SendCounters {
    pub sent: u64,
}

/// The receiver's counters.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RecvCounters {
    /// Authenticated datagrams that arrived, including late ones.
    pub received: u64,
    /// Bad tag, foreign session, wrong stream or channels, bad shape, or a
    /// datagram that does not fit the window.
    pub rejected: u64,
    /// Accepted datagrams that began behind the furthest start already seen.
    pub out_of_order: u64,
    /// Duplicates and datagrams whose payload was already read.
    pub late: u64,
    /// Contiguous holes that were concealed (counted once each).
    pub gaps: u64,
    /// Total silent frames emitted to cover those holes.
    pub concealed_frames: u64,
}

/// What a datagram did on arrival.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Accepted {
    /// Placed in the buffer in order.
    Buffered,
    /// Placed in the buffer behind an earlier datagram.
    OutOfOrder,
    /// Authenticated but already read or a duplicate; dropped.
    Late,
}

/// What one [`AudioReceiver::pull`] or [`AudioReceiver::pull_at`] produced.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PullReport {
    /// The master position of the first frame in this block.
    pub master_sample: u64,
    /// Frames written to the caller's slice (real plus concealed).
    pub frames: usize,
    /// A gap was concealed in this block, or this block begins with the first
    /// real audio after a gap. Stamp the outbound header with
    /// `FLAG_DISCONTINUITY` when this is true.
    pub discontinuity: bool,
    /// Silent frames emitted in this block. Counted in `frames` too.
    pub concealed_frames: usize,
    /// At least some concealment here came from [`AudioReceiver::pull_at`]'s
    /// deadline rather than from later audio proving a hole.
    pub from_deadline: bool,
}

/// Validate the channel count and that the samples are whole frames, without
/// limiting the block size. `packetize` uses this before it splits a block.
fn validate_stream_shape(channels: u8, sample_count: usize) -> Result<usize, BearerError> {
    if channels != 1 && channels != 2 {
        return Err(BearerError::Shape);
    }
    if sample_count % channels as usize != 0 {
        return Err(BearerError::Shape);
    }
    let frames = sample_count / channels as usize;
    if frames == 0 {
        return Err(BearerError::Shape);
    }
    Ok(frames)
}

/// Validate one datagram's shape for `codec`, returning the number of
/// **captured** frames in its payload. The block limit is applied separately:
/// a 16 kHz payload is smaller than its master-rate span.
fn validate_stream_shape_for(
    codec: Codec,
    channels: u8,
    sample_count: usize,
) -> Result<usize, BearerError> {
    match codec {
        Codec::Pcm16 => validate_stream_shape(channels, sample_count),
        Codec::Pcm16k => {
            // The small device's microphone is mono; a stereo 16 kHz payload has
            // no defined shape in this protocol.
            if channels != 1 || sample_count == 0 {
                return Err(BearerError::Shape);
            }
            Ok(sample_count)
        }
        // A codec this build knows but cannot decode is refused here rather
        // than misread as PCM16.
        _ => Err(BearerError::Shape),
    }
}

/// How many master frames one datagram's `frames` occupy for `codec`.
fn codec_master_span(codec: Codec, frames: usize) -> usize {
    match codec {
        Codec::Pcm16k => frames * PCM16K_RATIO,
        _ => frames,
    }
}

/// How many captured frames of `codec` fit in one datagram.
fn codec_datagram_frames(codec: Codec) -> usize {
    match codec {
        Codec::Pcm16k => MAX_PCM16K_FRAMES_PER_DATAGRAM,
        _ => MAX_FRAMES_PER_DATAGRAM,
    }
}

/// Validate one datagram's shape for `codec`, including the packet limit. The
/// reported frame count is the captured count; [`codec_master_span`] gives the
/// master span the receiver checks its window against.
fn validate_shape_for(
    codec: Codec,
    channels: u8,
    sample_count: usize,
) -> Result<usize, BearerError> {
    let frames = validate_stream_shape_for(codec, channels, sample_count)?;
    if frames > codec_datagram_frames(codec) {
        return Err(BearerError::TooManyFrames(codec_master_span(codec, frames)));
    }
    Ok(frames)
}

/// One master-rate sample from a 16 kHz body at output offset `offset`, linearly
/// interpolated. The last captured frame holds its value for the two outputs
/// whose right-hand neighbour is in the next datagram; that datagram's first
/// sample is the true continuation, so the seam is a one-frame hold, never a
/// jump.
fn expand_pcm16k(body: &[u8], frames: usize, offset: usize) -> i16 {
    let index = (offset / PCM16K_RATIO).min(frames.saturating_sub(1));
    let phase = (offset % PCM16K_RATIO) as i32;
    let first = i16::from_le_bytes([body[index * 2], body[index * 2 + 1]]);
    let next = if index + 1 < frames {
        i16::from_le_bytes([body[(index + 1) * 2], body[(index + 1) * 2 + 1]])
    } else {
        first
    };
    let delta = (i32::from(next) - i32::from(first)) * phase;
    // Round half away from zero; a plain integer division would bias every
    // negative-going edge toward zero.
    let step = if delta >= 0 {
        (delta + 1) / PCM16K_RATIO as i32
    } else {
        (delta - 1) / PCM16K_RATIO as i32
    };
    (i32::from(first) + step).clamp(i32::from(i16::MIN), i32::from(i16::MAX)) as i16
}

/// The sending half: packetize one input's frames into authenticated datagrams.
///
/// The bearer owns only a sequence number and the counters; the caller owns the
/// socket. [`AudioBearer::packetize`] writes each datagram into a stack buffer
/// (bounded by [`MAX_DATAGRAM_LEN`]) and hands it to a closure, so the
/// steady-state path allocates nothing.
pub struct AudioBearer {
    key: [u8; 32],
    session: u32,
    next_seq: u32,
    counters: SendCounters,
}

impl AudioBearer {
    /// A sender for one authenticated session. `key` is the same 32-byte
    /// session key the clock probe used.
    pub fn new(key: [u8; 32], session: u32) -> Self {
        AudioBearer {
            key,
            session,
            next_seq: 0,
            counters: SendCounters::default(),
        }
    }

    /// The session these datagrams carry.
    pub fn session(&self) -> u32 {
        self.session
    }

    /// The sequence number the next datagram will carry.
    pub fn next_seq(&self) -> u32 {
        self.next_seq
    }

    /// How many datagrams have been encoded.
    pub fn counters(&self) -> SendCounters {
        self.counters
    }

    /// Encode one datagram into `out`, as 48 kHz PCM16.
    ///
    /// `frames` is interleaved for `channels`; at most
    /// [`MAX_FRAMES_PER_DATAGRAM`] frames. `master_sample` is the master-clock
    /// position of the first frame. The call advances the wrapping `seq` and
    /// increments `sent`.
    pub fn encode_datagram(
        &mut self,
        out: &mut [u8],
        stream: u16,
        channels: u8,
        frames: &[i16],
        master_sample: u64,
    ) -> Result<usize, BearerError> {
        self.encode_datagram_as(Codec::Pcm16, out, stream, channels, frames, master_sample)
    }

    /// Encode one datagram into `out` with `codec`.
    ///
    /// `frames` is interleaved for `channels`. `Pcm16` is one master frame per
    /// sample; `Pcm16k` is mono at 16 kHz, and the receiver expands it by
    /// [`PCM16K_RATIO`] before placement. `master_sample` is the master-clock
    /// position of the **first captured frame**, so the receiver can place the
    /// expanded block where the device played it.
    pub fn encode_datagram_as(
        &mut self,
        codec: Codec,
        out: &mut [u8],
        stream: u16,
        channels: u8,
        frames: &[i16],
        master_sample: u64,
    ) -> Result<usize, BearerError> {
        if !is_audio_stream(stream) {
            return Err(BearerError::Stream(stream));
        }
        validate_shape_for(codec, channels, frames.len())?;
        let body_len = frames.len() * 2;
        let total = HEADER_LEN + body_len + AUDIO_MAC_LEN;
        if out.len() < total {
            return Err(BearerError::Output);
        }

        let header = Header {
            codec,
            flags: 0,
            session: self.session,
            stream,
            channels,
            seq: self.next_seq,
            master_sample,
        };
        out[..HEADER_LEN].copy_from_slice(&header.encode());
        let mut cursor = HEADER_LEN;
        for sample in frames {
            let bytes = sample.to_le_bytes();
            out[cursor] = bytes[0];
            out[cursor + 1] = bytes[1];
            cursor += 2;
        }
        let tag = mac_tag(&self.key, &header, &out[HEADER_LEN..HEADER_LEN + body_len]);
        out[HEADER_LEN + body_len..total].copy_from_slice(&tag);

        self.next_seq = self.next_seq.wrapping_add(1);
        self.counters.sent += 1;
        Ok(total)
    }

    /// Split `frames` into 48 kHz PCM16 datagrams of at most
    /// [`MAX_FRAMES_PER_DATAGRAM`] and hand each one to `sink`.
    pub fn packetize<F>(
        &mut self,
        stream: u16,
        channels: u8,
        frames: &[i16],
        master_sample: u64,
        sink: F,
    ) -> Result<u64, BearerError>
    where
        F: FnMut(&[u8]) -> std::io::Result<()>,
    {
        self.packetize_as(Codec::Pcm16, stream, channels, frames, master_sample, sink)
    }

    /// Split `frames` of `codec` into datagrams and hand each one to `sink`.
    /// Returns how many datagrams were produced.
    ///
    /// The first datagram starts at `master_sample`; each later one starts the
    /// master span of the captured frames already emitted. A 16 kHz block is
    /// split into at most [`MAX_PCM16K_FRAMES_PER_DATAGRAM`] captured frames so
    /// its expanded span still fits one master block.
    pub fn packetize_as<F>(
        &mut self,
        codec: Codec,
        stream: u16,
        channels: u8,
        frames: &[i16],
        master_sample: u64,
        mut sink: F,
    ) -> Result<u64, BearerError>
    where
        F: FnMut(&[u8]) -> std::io::Result<()>,
    {
        if !is_audio_stream(stream) {
            return Err(BearerError::Stream(stream));
        }
        let frame_count = validate_stream_shape_for(codec, channels, frames.len())?;
        let chunk = codec_datagram_frames(codec);
        let mut scratch = [0u8; MAX_DATAGRAM_LEN];
        let mut emitted = 0u64;
        let mut start = 0usize;
        while start < frame_count {
            let end = (start + chunk).min(frame_count);
            let first_sample = start * channels as usize;
            let last_sample = end * channels as usize;
            let length = self.encode_datagram_as(
                codec,
                &mut scratch,
                stream,
                channels,
                &frames[first_sample..last_sample],
                master_sample + codec_master_span(codec, start) as u64,
            )?;
            sink(&scratch[..length]).map_err(|error| BearerError::Io(error.kind()))?;
            emitted += 1;
            start = end;
        }
        Ok(emitted)
    }

    /// Packetize and send every datagram to `addr` over `socket`.
    pub fn send_block(
        &mut self,
        socket: &UdpSocket,
        addr: SocketAddr,
        stream: u16,
        channels: u8,
        frames: &[i16],
        master_sample: u64,
    ) -> Result<u64, BearerError> {
        self.packetize(stream, channels, frames, master_sample, |datagram| {
            socket.send_to(datagram, addr).map(|_| ())
        })
    }
}

/// The receiving half: authenticate, place by master position, and hand back
/// contiguous master-time audio.
///
/// The buffer is a fixed ring of `window_frames * channels` samples plus one
/// validity bit per frame, allocated once. `accept` copies into it and `pull`
/// copies out; neither allocates. Positions outside `[next, next + window)` are
/// refused, which is what bounds both latency and memory.
pub struct AudioReceiver {
    key: [u8; 32],
    session: u32,
    stream: u16,
    channels: u8,
    /// The first authenticated datagram's codec. `None` until audio arrives; a
    /// session cannot change rates midway without a new receiver.
    codec: Option<Codec>,
    window_frames: usize,
    samples: Vec<i16>,
    valid: Vec<bool>,
    started: bool,
    next_master: u64,
    /// The first placed datagram's start, i.e. where this session's timeline
    /// begins on the master clock. Zero until audio arrives.
    first_master: u64,
    highest_start: Option<u64>,
    /// A hole is being concealed but its first real frame has not been read.
    after_gap: bool,
    counters: RecvCounters,
}

impl AudioReceiver {
    /// A receiver for one stream, session and channel count.
    ///
    /// `window_frames` is the jitter window in frames; it must be at least one
    /// datagram ([`MAX_FRAMES_PER_DATAGRAM`]). [`DEFAULT_JITTER_FRAMES`] is the
    /// intended default.
    pub fn new(
        key: [u8; 32],
        session: u32,
        stream: u16,
        channels: u8,
        window_frames: usize,
    ) -> Result<Self, BearerError> {
        if (channels != 1 && channels != 2) || !is_audio_stream(stream) {
            return Err(BearerError::Shape);
        }
        if window_frames < MAX_FRAMES_PER_DATAGRAM {
            return Err(BearerError::Window);
        }
        Ok(AudioReceiver {
            key,
            session,
            stream,
            channels,
            codec: None,
            window_frames,
            samples: vec![0i16; window_frames * channels as usize],
            valid: vec![false; window_frames],
            started: false,
            next_master: 0,
            first_master: 0,
            highest_start: None,
            after_gap: false,
            counters: RecvCounters::default(),
        })
    }

    /// The session this receiver accepts.
    pub fn session(&self) -> u32 {
        self.session
    }

    /// The codec this receiver locked to, or `None` before the first
    /// authenticated datagram.
    pub fn codec(&self) -> Option<Codec> {
        self.codec
    }

    /// The next master position `pull` will return.
    pub fn next_master(&self) -> u64 {
        self.next_master
    }

    /// The first placed datagram's start, or zero before audio arrives.
    pub fn first_master(&self) -> u64 {
        self.first_master
    }

    /// Whether any audio has been placed yet.
    pub fn started(&self) -> bool {
        self.started
    }

    /// The jitter window, in frames.
    pub fn window_frames(&self) -> usize {
        self.window_frames
    }

    /// The running counters.
    pub fn counters(&self) -> RecvCounters {
        self.counters
    }

    fn slot(&self, master_sample: u64) -> usize {
        (master_sample % self.window_frames as u64) as usize
    }

    /// Verify one datagram and place it in the jitter buffer.
    ///
    /// Rejections increment `rejected` and return the reason; late and
    /// out-of-order datagrams are authenticated, counted, and handled without
    /// an error.
    pub fn accept(&mut self, datagram: &[u8]) -> Result<Accepted, BearerError> {
        self.accept_shifted(datagram, 0)
    }

    /// Verify one datagram exactly as [`AudioReceiver::accept`] does, then place
    /// it `shift` frames earlier on the master timeline.
    ///
    /// A peer that declares a capture/pipeline latency stamps each datagram
    /// where its sender believes the audio belongs, but the audio itself is
    /// that much late. A positive `shift` is therefore subtracted from the
    /// decoded master position before the datagram enters the jitter buffer,
    /// so the source is placed earlier and a take played `shift` frames late
    /// is recorded in time. The tag is verified against the datagram's own
    /// header, before any shift, so the wire format and authentication are
    /// unchanged; `accept` is this call with a shift of zero.
    ///
    /// `first_master`, `next_master` and every pulled position are on the
    /// shifted timeline. A datagram whose original position is smaller than
    /// the shift (only possible near the master's own origin) saturates at
    /// zero rather than wrapping.
    pub fn accept_shifted(&mut self, datagram: &[u8], shift: u64) -> Result<Accepted, BearerError> {
        let decoded = match proto::decode(datagram) {
            Ok(decoded) => decoded,
            Err(error) => {
                self.counters.rejected += 1;
                return Err(BearerError::Proto(error));
            }
        };
        let (header, header_end) = decoded;

        if header.stream != self.stream {
            self.counters.rejected += 1;
            return Err(BearerError::Stream(header.stream));
        }
        if header.session != self.session {
            self.counters.rejected += 1;
            return Err(BearerError::Session(header.session));
        }
        if header.channels != self.channels {
            self.counters.rejected += 1;
            return Err(BearerError::Shape);
        }
        if !matches!(header.codec, Codec::Pcm16 | Codec::Pcm16k) {
            self.counters.rejected += 1;
            return Err(BearerError::Shape);
        }
        // The small device's stream is mono. A master-rate stream may be stereo;
        // a 16 kHz one cannot, because its samples are expanded into one lane.
        if header.codec == Codec::Pcm16k && header.channels != 1 {
            self.counters.rejected += 1;
            return Err(BearerError::Shape);
        }
        if datagram.len() < header_end + AUDIO_MAC_LEN {
            self.counters.rejected += 1;
            return Err(BearerError::Short);
        }

        let body_end = datagram.len() - AUDIO_MAC_LEN;
        let body = &datagram[header_end..body_end];
        let tag = &datagram[body_end..];
        if !tags_match(&mac_tag(&self.key, &header, body), tag) {
            self.counters.rejected += 1;
            return Err(BearerError::BadTag);
        }

        // Authenticated. Only now is it safe to trust the body's shape.
        if body.len() % 2 != 0 {
            self.counters.rejected += 1;
            return Err(BearerError::Shape);
        }
        // The first datagram fixes the session's codec. A stream cannot switch
        // between master-rate and small-rate audio without a new receiver.
        if let Some(codec) = self.codec {
            if codec != header.codec {
                self.counters.rejected += 1;
                return Err(BearerError::Shape);
            }
        }
        let frames = match validate_shape_for(header.codec, self.channels, body.len() / 2) {
            Ok(frames) => frames,
            Err(error) => {
                self.counters.rejected += 1;
                return Err(error);
            }
        };
        if self.codec.is_none() {
            self.codec = Some(header.codec);
        }
        let master_frames = codec_master_span(header.codec, frames);
        let start = header.master_sample.saturating_sub(shift);
        let end = start.saturating_add(master_frames as u64);

        if !self.started {
            self.started = true;
            self.next_master = start;
            self.first_master = start;
        }

        if end <= self.next_master {
            self.counters.received += 1;
            self.counters.late += 1;
            return Ok(Accepted::Late);
        }

        let window_end = self.next_master.saturating_add(self.window_frames as u64);
        if start >= window_end || end > window_end {
            self.counters.rejected += 1;
            return Err(BearerError::Window);
        }
        self.counters.received += 1;

        let from = start.max(self.next_master);
        let width = self.channels as usize;
        let mut wrote = false;
        let mut skipped = false;
        if header.codec == Codec::Pcm16k {
            // Mono (checked above): one expanded sample per master frame.
            for position in from..end {
                let slot = self.slot(position);
                if self.valid[slot] {
                    skipped = true;
                    continue;
                }
                let offset = (position - start) as usize;
                self.samples[slot] = expand_pcm16k(body, frames, offset);
                self.valid[slot] = true;
                wrote = true;
            }
        } else {
            let mut cursor = (from - start) as usize;
            for position in from..end {
                let slot = self.slot(position);
                if self.valid[slot] {
                    skipped = true;
                    cursor += 1;
                    continue;
                }
                let target = slot * width;
                let source = cursor * width * 2;
                for channel in 0..width {
                    let byte = source + channel * 2;
                    self.samples[target + channel] =
                        i16::from_le_bytes([body[byte], body[byte + 1]]);
                }
                self.valid[slot] = true;
                wrote = true;
                cursor += 1;
            }
        }

        let out_of_order = start >= self.next_master
            && matches!(self.highest_start, Some(highest) if start < highest);

        if !wrote {
            self.counters.late += 1;
            return Ok(Accepted::Late);
        }
        if skipped || start < self.next_master {
            self.counters.late += 1;
        }
        if out_of_order {
            self.counters.out_of_order += 1;
        }
        self.highest_start = Some(match self.highest_start {
            Some(highest) => highest.max(start),
            None => start,
        });

        Ok(if out_of_order {
            Accepted::OutOfOrder
        } else {
            Accepted::Buffered
        })
    }

    /// Read up to `frames` contiguous master-time frames into `out`.
    ///
    /// `out` is interleaved for the receiver's channel count. The return value
    /// carries how much was written, whether a discontinuity is represented,
    /// and how much of the block was concealment. If the next frame has not
    /// arrived but no later frame has either, the call stops rather than
    /// guessing: a gap is only concealed once later audio proves it is a hole.
    /// [`AudioReceiver::pull_at`] is the same read with a leading-edge deadline.
    pub fn pull(&mut self, out: &mut [i16], frames: usize) -> PullReport {
        self.pull_with_deadline(out, frames, None, None)
    }

    /// Read up to `frames` contiguous master-time frames, concealing a tail
    /// that no later audio can prove.
    ///
    /// This is [`AudioReceiver::pull`] plus a deadline. A frame is declared
    /// lost when its **whole span** has ended at least [`DEADLINE_GUARD_FRAMES`]
    /// before `now_master`, i.e. when `position + 1 <= now_master -
    /// DEADLINE_GUARD_FRAMES`. The guard is one datagram's worth: a datagram
    /// still in flight, or one the jitter window is still holding room for, is
    /// not concealed out from under the network. A hole that later audio
    /// closes is still concealed exactly as `pull` does it (and is not counted
    /// as `from_deadline`).
    ///
    /// The report's `from_deadline` is true when this block concealed frames
    /// because of the deadline rather than because a later datagram arrived.
    /// A datagram for a span the deadline already concealed is refused as
    /// [`Accepted::Late`] by [`AudioReceiver::accept`]; the read cursor never
    /// moves backwards.
    pub fn pull_at(&mut self, out: &mut [i16], frames: usize, now_master: i64) -> PullReport {
        self.pull_with_deadline(out, frames, deadline_after(now_master), None)
    }

    /// Read up to `frames` contiguous master-time frames but never past
    /// `head_master`, concealing a hole up to that head.
    ///
    /// This is the jitter-buffer read. A caller that keeps `head_master` behind
    /// its clock by the buffer depth gives every datagram that many frames to
    /// arrive: a delayed or reordered datagram whose span is still ahead of the
    /// head is placed before the cursor reaches it, instead of being refused as
    /// [`Accepted::Late`] after the cursor has already read past it. Frames
    /// missing at the head are genuinely due and are concealed; the guard in
    /// [`AudioReceiver::pull_at`] is unnecessary here because the buffer itself
    /// already holds the slack.
    pub fn pull_to(&mut self, out: &mut [i16], frames: usize, head_master: u64) -> PullReport {
        self.pull_with_deadline(out, frames, Some(head_master), Some(head_master))
    }

    fn pull_with_deadline(
        &mut self,
        out: &mut [i16],
        frames: usize,
        deadline: Option<u64>,
        stop: Option<u64>,
    ) -> PullReport {
        let capacity = frames.min(out.len() / self.channels as usize);
        let stop_at = stop.unwrap_or(u64::MAX);
        let first = self.next_master;
        let mut written = 0usize;
        let mut concealed = 0usize;
        let mut discontinuity = false;
        let mut from_deadline = false;

        if self.started && capacity > 0 {
            let window = self.window_frames as u64;
            while written < capacity {
                let position = self.next_master;
                if position >= stop_at {
                    break;
                }
                let slot = self.slot(position);
                if self.valid[slot] {
                    let source = slot * self.channels as usize;
                    let target = written * self.channels as usize;
                    let width = self.channels as usize;
                    out[target..target + width]
                        .copy_from_slice(&self.samples[source..source + width]);
                    self.valid[slot] = false;
                    self.next_master += 1;
                    written += 1;
                    if self.after_gap {
                        // The first real frame after a concealed hole: flag the
                        // block so its outbound header says so.
                        self.after_gap = false;
                        discontinuity = true;
                    }
                    continue;
                }

                // Is the hole closed by later data? Look only inside the
                // bounded window; if nothing is there, wait for the next push
                // unless a deadline says the frames are already lost.
                let limit = position.saturating_add(window);
                let mut probe = position + 1;
                let mut next_valid = None;
                while probe < limit {
                    if self.valid[self.slot(probe)] {
                        next_valid = Some(probe);
                        break;
                    }
                    probe += 1;
                }
                let hole_end = match next_valid {
                    Some(hole_end) => hole_end.min(stop_at),
                    None => {
                        // No later audio proves the hole. Conceal the prefix
                        // whose whole span is older than the deadline (never
                        // past the bounded window, never past the block).
                        let Some(deadline) = deadline else { break };
                        let end = limit.min(deadline).min(stop_at);
                        if end <= position {
                            break;
                        }
                        from_deadline = true;
                        end
                    }
                };

                if !self.after_gap {
                    self.after_gap = true;
                    self.counters.gaps += 1;
                }
                discontinuity = true;
                let remaining = capacity - written;
                let hole = (hole_end - position).min(remaining as u64) as usize;
                let target = written * self.channels as usize;
                let width = self.channels as usize;
                for sample in &mut out[target..target + hole * width] {
                    *sample = 0;
                }
                written += hole;
                concealed += hole;
                self.counters.concealed_frames += hole as u64;
                self.next_master += hole as u64;
            }
        }

        PullReport {
            master_sample: first,
            frames: written,
            discontinuity,
            concealed_frames: concealed,
            from_deadline,
        }
    }
}

/// The exclusive master position before which a frame is declared lost, or
/// `None` when `now_master` is too small to have a deadline yet.
fn deadline_after(now_master: i64) -> Option<u64> {
    if now_master <= 0 {
        return None;
    }
    Some((now_master as u64).saturating_sub(DEADLINE_GUARD_FRAMES as u64))
}

/// Linear-interpolation converter from a peer's local samples to the master.
///
/// The peer records on its own clock; a positive `drift_ppm` means that clock
/// runs fast, so one master sample spans slightly more than one local sample.
/// The converter carries a fractional local position and reads between adjacent
/// input samples:
///
/// ```text
/// local_step = 1 / (1 - drift_ppm / 1e6)
/// output[m]  = input[floor(local)] + frac * (input[floor(local) + 1] - input[floor(local)])
/// local     += local_step, master += 1
/// ```
///
/// That rate is the slope [`ClockOffset::to_master`] reports (`1 - drift`), so
/// the first output lands on `offset.to_master(start_local)` and the master
/// cursor is the position the peer's stream should occupy. This is the
/// first-slice converter: a windowed-sinc one can replace the interpolation
/// while keeping `push` / `process` and the same rate contract.
///
/// `push` and `process` allocate nothing once the preallocated input budget is
/// large enough for the caller's blocks; feed a block, process it, repeat.
pub struct LinearResampler {
    offset: ClockOffset,
    /// Local samples consumed per master sample.
    local_per_master: f64,
    /// Local samples not yet consumed; `pending_base` is pending[0]'s index.
    pending: Vec<i16>,
    pending_base: u64,
    /// The sample immediately before `pending_base`, for the block boundary.
    previous: Option<i16>,
    /// Fractional local position of the next output sample.
    next_local: f64,
    /// Master position of the next output sample.
    next_master: i64,
}

impl LinearResampler {
    /// A converter for `offset`, starting at local sample 0.
    pub fn new(offset: ClockOffset) -> Self {
        Self::with_capacity(offset, DEFAULT_RESAMPLER_CAPACITY)
    }

    /// A converter with room for `capacity` unprocessed input samples.
    pub fn with_capacity(offset: ClockOffset, capacity: usize) -> Self {
        let denominator = 1.0 - offset.drift_ppm / 1_000_000.0;
        // A drift this large is not a clock; avoid a division blow-up and keep
        // the converter finite. Real crystals are tens of ppm.
        let local_per_master = if denominator.abs() < 1e-6 {
            1.0
        } else {
            1.0 / denominator
        };
        LinearResampler {
            offset,
            local_per_master,
            pending: Vec::with_capacity(capacity.max(1)),
            pending_base: 0,
            previous: None,
            next_local: 0.0,
            next_master: offset.to_master(0),
        }
    }

    /// The offset this converter was built from.
    pub fn offset(&self) -> ClockOffset {
        self.offset
    }

    /// Local samples per master sample. `1.0` at zero drift; greater than one
    /// when the local clock runs fast.
    pub fn local_per_master(&self) -> f64 {
        self.local_per_master
    }

    /// Master position of the next output sample, matching
    /// [`ClockOffset::to_master`] at the current local position.
    pub fn master_position(&self) -> i64 {
        self.next_master
    }

    /// Fractional local position of the next output sample.
    pub fn local_position(&self) -> f64 {
        self.next_local
    }

    /// Start a new stream at absolute local sample `local_sample`.
    pub fn reset_to(&mut self, local_sample: u64) {
        self.pending.clear();
        self.pending_base = local_sample;
        self.previous = None;
        self.next_local = local_sample as f64;
        self.next_master = self.offset.to_master(local_sample);
    }

    /// Append the next contiguous local block. Returns `PendingFull` when the
    /// block does not fit the preallocated budget; process first, or build the
    /// converter with [`LinearResampler::with_capacity`].
    pub fn push(&mut self, input: &[i16]) -> Result<usize, BearerError> {
        if input.is_empty() {
            return Ok(0);
        }
        if self.pending.len() + input.len() > self.pending.capacity() {
            return Err(BearerError::PendingFull);
        }
        self.pending.extend_from_slice(input);
        Ok(input.len())
    }

    /// Produce master-time samples into `out`, returning how many were written.
    ///
    /// The last input sample (and any fractional position past it) is carried
    /// to the next call, so block boundaries are transparent.
    pub fn process(&mut self, out: &mut [i16]) -> usize {
        let mut written = 0usize;
        while written < out.len() {
            let relative = self.next_local - self.pending_base as f64;
            let floor = relative.floor();
            if floor < -1.0 {
                break;
            }
            let fraction = relative - floor;
            let (left, right);
            if floor == -1.0 {
                let Some(previous) = self.previous else {
                    break;
                };
                if self.pending.is_empty() {
                    break;
                }
                left = previous;
                right = self.pending[0];
            } else {
                let index = floor as usize;
                if index + 1 >= self.pending.len() {
                    break;
                }
                left = self.pending[index];
                right = self.pending[index + 1];
            }
            let value = left as f64 + (right as f64 - left as f64) * fraction;
            out[written] =
                value.round().clamp(i16::MIN as f64, i16::MAX as f64) as i16;
            written += 1;
            self.next_local += self.local_per_master;
            self.next_master += 1;
        }
        self.drop_consumed();
        written
    }

    /// Discard input that interpolation can no longer reach, keeping the last
    /// consumed sample for the next block's left edge.
    fn drop_consumed(&mut self) {
        let floor = self.next_local.floor();
        if floor <= self.pending_base as f64 {
            return;
        }
        let drop = ((floor - self.pending_base as f64) as usize).min(self.pending.len());
        if drop == 0 {
            return;
        }
        self.previous = Some(self.pending[drop - 1]);
        self.pending.drain(..drop);
        self.pending_base += drop as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> [u8; 32] {
        [0x5A; 32]
    }

    #[test]
    fn the_audio_range_misses_control_and_small_ids() {
        assert!(is_audio_stream(AUDIO_STREAM_BASE));
        assert!(is_audio_stream(AUDIO_STREAM_LAST));
        for control in [0xFF00u16, 0xFF01, 0xFF02, 0xFF03] {
            assert!(!is_audio_stream(control));
        }
        // The CLI self-test's stream and the reserved zero are not audio.
        assert!(!is_audio_stream(0));
        assert!(!is_audio_stream(2));
        assert_eq!(audio_stream(0), Some(AUDIO_STREAM_BASE));
        assert_eq!(audio_stream(1), Some(AUDIO_STREAM_BASE + 1));
        assert_eq!(audio_stream(0x7000), None);
    }

    #[test]
    fn only_audio_stream_ids_are_encoded() {
        let mut bearer = AudioBearer::new(key(), 7);
        let mut out = [0u8; MAX_DATAGRAM_LEN];
        assert_eq!(
            bearer.encode_datagram(&mut out, 0xFF00, 1, &[1i16; 8], 0),
            Err(BearerError::Stream(0xFF00))
        );
        assert_eq!(bearer.counters().sent, 0);
    }

    #[test]
    fn the_packet_limit_is_five_hundred_twelve_frames() {
        let mut bearer = AudioBearer::new(key(), 7);
        assert_eq!(
            bearer.encode_datagram(
                &mut [0u8; MAX_DATAGRAM_LEN],
                AUDIO_STREAM_BASE,
                2,
                &[0i16; (MAX_FRAMES_PER_DATAGRAM + 1) * 2],
                0
            ),
            Err(BearerError::TooManyFrames(MAX_FRAMES_PER_DATAGRAM + 1))
        );
    }

    #[test]
    fn a_16k_stream_is_expanded_to_the_master_rate() {
        let session = 9;
        let stream = AUDIO_STREAM_BASE;
        let mut bearer = AudioBearer::new(key(), session);
        let mut datagram = [0u8; MAX_DATAGRAM_LEN];
        let length = bearer
            .encode_datagram_as(
                Codec::Pcm16k,
                &mut datagram,
                stream,
                1,
                &[0i16, 300, 600],
                100,
            )
            .expect("encode 16k");

        let mut receiver = AudioReceiver::new(key(), session, stream, 1, DEFAULT_JITTER_FRAMES)
            .expect("receiver");
        assert_eq!(receiver.accept(&datagram[..length]), Ok(Accepted::Buffered));
        assert_eq!(receiver.codec(), Some(Codec::Pcm16k));

        let mut pulled = [0i16; 9];
        let report = receiver.pull(&mut pulled, 9);
        assert_eq!(report.master_sample, 100);
        assert_eq!(report.frames, 9);
        // Three samples become three master frames each, interpolated. The last
        // captured frame holds for its two outputs until the next datagram.
        assert_eq!(pulled, [0, 100, 200, 300, 400, 500, 600, 600, 600]);
    }

    #[test]
    fn a_16k_session_cannot_switch_to_pcm16() {
        let session = 10;
        let stream = AUDIO_STREAM_BASE;
        let mut small = AudioBearer::new(key(), session);
        let mut first = [0u8; MAX_DATAGRAM_LEN];
        let first_len = small
            .encode_datagram_as(Codec::Pcm16k, &mut first, stream, 1, &[1i16; 3], 0)
            .expect("encode 16k");

        let mut receiver = AudioReceiver::new(key(), session, stream, 1, DEFAULT_JITTER_FRAMES)
            .expect("receiver");
        assert_eq!(receiver.accept(&first[..first_len]), Ok(Accepted::Buffered));

        let mut master = AudioBearer::new(key(), session);
        let mut second = [0u8; MAX_DATAGRAM_LEN];
        let second_len = master
            .encode_datagram(&mut second, stream, 1, &[2i16; 3], 100)
            .expect("encode 48k");
        assert_eq!(receiver.accept(&second[..second_len]), Err(BearerError::Shape));
        assert_eq!(receiver.counters().rejected, 1);
        assert_eq!(receiver.codec(), Some(Codec::Pcm16k));
    }

    #[test]
    fn a_16k_datagram_is_capped_at_one_master_block() {
        let mut bearer = AudioBearer::new(key(), 11);
        let too_many = vec![0i16; MAX_PCM16K_FRAMES_PER_DATAGRAM + 1];
        assert_eq!(
            bearer.encode_datagram_as(
                Codec::Pcm16k,
                &mut [0u8; MAX_DATAGRAM_LEN],
                AUDIO_STREAM_BASE,
                1,
                &too_many,
                0,
            ),
            Err(BearerError::TooManyFrames(
                (MAX_PCM16K_FRAMES_PER_DATAGRAM + 1) * PCM16K_RATIO
            ))
        );

        // A longer block is split so every expanded datagram still fits.
        let mut collected = Vec::new();
        let emitted = bearer
            .packetize_as(
                Codec::Pcm16k,
                AUDIO_STREAM_BASE,
                1,
                &vec![7i16; 400],
                0,
                |datagram| {
                    collected.push(datagram.to_vec());
                    Ok(())
                },
            )
            .expect("packetize 16k");
        assert_eq!(emitted, 3);
        let starts: Vec<u64> = collected
            .iter()
            .map(|datagram| {
                let (header, _) = proto::decode(datagram).expect("decode");
                assert_eq!(header.codec, Codec::Pcm16k);
                assert_eq!(header.channels, 1);
                assert!(datagram.len() - HEADER_LEN - AUDIO_MAC_LEN <= MAX_PCM16K_FRAMES_PER_DATAGRAM * 2);
                header.master_sample
            })
            .collect();
        assert_eq!(starts, vec![0, 510, 1020]);
    }

    #[test]
    fn a_stereo_16k_payload_is_refused() {
        let mut bearer = AudioBearer::new(key(), 12);
        assert_eq!(
            bearer.encode_datagram_as(
                Codec::Pcm16k,
                &mut [0u8; MAX_DATAGRAM_LEN],
                AUDIO_STREAM_BASE,
                2,
                &[1i16, 2, 3, 4],
                0,
            ),
            Err(BearerError::Shape)
        );
    }

    #[test]
    fn a_tag_covers_the_header_and_the_body() {
        let mut bearer = AudioBearer::new(key(), 7);
        let mut out = [0u8; MAX_DATAGRAM_LEN];
        let length = bearer
            .encode_datagram(&mut out, AUDIO_STREAM_BASE, 1, &[1i16, 2, 3, 4], 99)
            .expect("encode");
        let (header, offset) = proto::decode(&out[..length]).expect("decode");
        let body = &out[offset..length - AUDIO_MAC_LEN];
        let expected = mac_tag(&key(), &header, body);
        assert!(tags_match(&expected, &out[length - AUDIO_MAC_LEN..length]));

        // Flipping a header bit or a body bit must break the tag.
        let mut header_flip = out;
        header_flip[12] ^= 0x01;
        let (flipped_header, _) = proto::decode(&header_flip[..length]).expect("decode");
        assert!(!tags_match(
            &mac_tag(&key(), &flipped_header, body),
            &header_flip[length - AUDIO_MAC_LEN..length]
        ));
    }
}
