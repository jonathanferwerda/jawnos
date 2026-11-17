//! What two engines agree on: one fixed 32-byte header per datagram.
//!
//! The header carries the session, the stream, and — the field the whole plan
//! rests on — the master's sample position of the *first* sample in the payload.
//! A receiver therefore places a block by where it belongs, never by when it
//! arrived (docs/studio-audio-roadmap.md §10).
//!
//! Little-endian, fixed offsets, reserved bytes written as zero. No allocation:
//! a stream owns a scratch buffer and `encode_datagram` fills it.

/// A datagram begins with these four bytes. Cheap to check, cheap to reject.
pub const MAGIC: [u8; 4] = *b"JAWA";

/// Bumped when the layout changes in a way older peers cannot read.
pub const VERSION: u8 = 1;

/// Header length in bytes. Payload follows immediately.
pub const HEADER_LEN: usize = 32;

/// The sender's clock jumped (a reconnect, a seek): do not interpolate across it.
pub const FLAG_DISCONTINUITY: u16 = 1 << 0;

/// This block fills in for one that was lost: repeated or faded samples.
pub const FLAG_CONCEALED: u16 = 1 << 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProtoError {
    /// The buffer is shorter than a header, or than header plus payload.
    Short,
    /// Not an engine datagram at all.
    Magic,
    /// A peer from a future layout.
    Version(u8),
    /// A codec this build does not decode.
    Codec(u8),
}

/// How the payload's samples are encoded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Codec {
    /// 16-bit signed PCM, the interface's own depth.
    Pcm16 = 0,
    /// 24-bit signed PCM, for a wired bus that has the headroom.
    Pcm24 = 1,
    /// Opus, 10 ms frames — the phone and a Wi-Fi zone.
    Opus10 = 2,
    /// 16 kHz PCM from a small device, resampled by the receiver.
    Pcm16k = 3,
}

impl Codec {
    pub fn from_byte(byte: u8) -> Result<Codec, ProtoError> {
        match byte {
            0 => Ok(Codec::Pcm16),
            1 => Ok(Codec::Pcm24),
            2 => Ok(Codec::Opus10),
            3 => Ok(Codec::Pcm16k),
            other => Err(ProtoError::Codec(other)),
        }
    }
}

/// The fixed part of every datagram.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub codec: Codec,
    pub flags: u16,
    /// Which session's clock the position belongs to.
    pub session: u32,
    /// Which input, bus or zone feed this is.
    pub stream: u16,
    /// Channel count in the payload: 1 for a mono input, 2 for a bus.
    pub channels: u8,
    /// Wraps; the receiver compares it modulo `u32::MAX`.
    pub seq: u32,
    /// The master clock position of the payload's first sample.
    pub master_sample: u64,
}

impl Header {
    pub fn encode(&self) -> [u8; HEADER_LEN] {
        let mut out = [0u8; HEADER_LEN];
        out[0..4].copy_from_slice(&MAGIC);
        out[4] = VERSION;
        out[5] = self.codec as u8;
        out[6..8].copy_from_slice(&self.flags.to_le_bytes());
        out[8..12].copy_from_slice(&self.session.to_le_bytes());
        out[12..14].copy_from_slice(&self.stream.to_le_bytes());
        out[14] = self.channels;
        // out[15] is reserved.
        out[16..20].copy_from_slice(&self.seq.to_le_bytes());
        // out[20..24] is reserved.
        out[24..32].copy_from_slice(&self.master_sample.to_le_bytes());
        out
    }
}

/// Read a header, returning it and the offset where its payload starts.
pub fn decode(buf: &[u8]) -> Result<(Header, usize), ProtoError> {
    if buf.len() < HEADER_LEN {
        return Err(ProtoError::Short);
    }
    if buf[0..4] != MAGIC {
        return Err(ProtoError::Magic);
    }
    if buf[4] != VERSION {
        return Err(ProtoError::Version(buf[4]));
    }
    let codec = Codec::from_byte(buf[5])?;
    let header = Header {
        codec,
        flags: u16::from_le_bytes([buf[6], buf[7]]),
        session: u32::from_le_bytes([buf[8], buf[9], buf[10], buf[11]]),
        stream: u16::from_le_bytes([buf[12], buf[13]]),
        channels: buf[14],
        seq: u32::from_le_bytes([buf[16], buf[17], buf[18], buf[19]]),
        master_sample: u64::from_le_bytes([
            buf[24], buf[25], buf[26], buf[27], buf[28], buf[29], buf[30], buf[31],
        ]),
    };
    Ok((header, HEADER_LEN))
}

/// Write header and payload into `out`, returning the datagram's length.
///
/// `out` must already hold `HEADER_LEN + payload.len()` bytes: the audio thread
/// calls this with a per-stream scratch buffer, so it may not allocate.
pub fn encode_datagram(out: &mut [u8], header: &Header, payload: &[u8]) -> Result<usize, ProtoError> {
    let need = HEADER_LEN + payload.len();
    if out.len() < need {
        return Err(ProtoError::Short);
    }
    out[..HEADER_LEN].copy_from_slice(&header.encode());
    out[HEADER_LEN..need].copy_from_slice(payload);
    Ok(need)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header() -> Header {
        Header {
            codec: Codec::Pcm24,
            flags: FLAG_DISCONTINUITY,
            session: 0xDEAD_BEEF,
            stream: 42,
            channels: 2,
            seq: 0x0102_0304,
            master_sample: 0x0102_0304_0506_0708,
        }
    }

    #[test]
    fn round_trips_every_field() {
        let original = header();
        let (back, offset) = decode(&original.encode()).expect("decode");
        assert_eq!(back, original);
        assert_eq!(offset, HEADER_LEN);
    }

    #[test]
    fn reserved_bytes_stay_zero() {
        let bytes = header().encode();
        assert_eq!(bytes[15], 0);
        assert!(bytes[20..24].iter().all(|b| *b == 0));
    }

    #[test]
    fn a_short_buffer_is_rejected() {
        let short = [0u8; HEADER_LEN - 1];
        assert_eq!(decode(&short), Err(ProtoError::Short));
    }

    #[test]
    fn a_bad_magic_is_rejected() {
        let mut bytes = header().encode();
        bytes[0] = b'X';
        assert_eq!(decode(&bytes), Err(ProtoError::Magic));
    }

    #[test]
    fn a_future_version_is_rejected() {
        let mut bytes = header().encode();
        bytes[4] = VERSION + 1;
        assert_eq!(decode(&bytes), Err(ProtoError::Version(VERSION + 1)));
    }

    #[test]
    fn an_unknown_codec_is_rejected() {
        let mut bytes = header().encode();
        bytes[5] = 200;
        assert_eq!(decode(&bytes), Err(ProtoError::Codec(200)));
    }

    #[test]
    fn every_declared_codec_round_trips() {
        for codec in [Codec::Pcm16, Codec::Pcm24, Codec::Opus10, Codec::Pcm16k] {
            let mut h = header();
            h.codec = codec;
            let (back, _) = decode(&h.encode()).expect("decode");
            assert_eq!(back.codec, codec);
        }
    }

    #[test]
    fn a_datagram_carries_its_payload() {
        let original = header();
        let payload = [1u8, 2, 3, 4, 5, 6];
        let mut out = vec![0u8; HEADER_LEN + payload.len()];
        let len = encode_datagram(&mut out, &original, &payload).expect("encode");
        assert_eq!(len, out.len());
        let (back, offset) = decode(&out[..len]).expect("decode");
        assert_eq!(back, original);
        assert_eq!(&out[offset..len], &payload[..]);
    }

    #[test]
    fn a_datagram_needs_room_for_its_payload() {
        let mut out = vec![0u8; HEADER_LEN + 3];
        assert_eq!(
            encode_datagram(&mut out, &header(), &[0u8; 4]),
            Err(ProtoError::Short)
        );
    }
}
