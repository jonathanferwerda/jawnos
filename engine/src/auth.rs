//! The one authentication tag both P3 transports share.
//!
//! The clock probe (`peer.rs`) and the audio bearer (`bearing.rs`) put the same
//! tag on every datagram: HMAC-SHA256 over the whole encoded header and the
//! body, truncated to [`MAC_LEN`]. Keeping the construction in one place is
//! what makes a clock datagram and an audio datagram authenticate identically
//! (docs/studio-audio-roadmap.md §10 and §13 P3).

use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::proto::Header;

type HmacSha256 = Hmac<Sha256>;

/// The authentication tag appended to every clock and audio payload:
/// HMAC-SHA256 over the header fields that matter and the body, truncated to
/// 16 bytes.
pub const MAC_LEN: usize = 16;

/// The 16-byte tag: HMAC-SHA256 over the whole encoded header and the body
/// before the tag. Covering every header byte (codec, flags, channels and the
/// reserved bytes too) keeps the same tag honest when the audio bearer starts
/// carrying `flags` and `channels` that a receiver acts on.
pub fn mac_tag(key: &[u8; 32], header: &Header, body: &[u8]) -> [u8; MAC_LEN] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts a 32-byte key");
    mac.update(&header.encode());
    mac.update(body);
    let full = mac.finalize().into_bytes();
    let mut tag = [0u8; MAC_LEN];
    tag.copy_from_slice(&full[..MAC_LEN]);
    tag
}

/// Compare two tags without an early exit, so a wrong tag costs the same time
/// as a right one. A length mismatch is refused before the comparison.
pub fn tags_match(expected: &[u8], found: &[u8]) -> bool {
    if expected.len() != found.len() {
        return false;
    }
    let mut difference = 0u8;
    for (left, right) in expected.iter().zip(found) {
        difference |= left ^ right;
    }
    difference == 0
}
