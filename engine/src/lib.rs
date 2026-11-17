//! The JawnOS audio engine.
//!
//! P1 is deliberately the part that must be right *before* a sound card is
//! involved: the datagram header peers agree on, the parameter path the control
//! thread writes and the audio thread reads, and a block graph that never
//! allocates. A null device makes all of it runnable on a machine with no audio
//! at all, which is how the suite exercises the real code (docs/studio-audio-roadmap.md).
//!
//! No crate here needs the network or a toolchain beyond `cargo`.

pub mod device;
pub mod graph;
pub mod params;
pub mod proto;

pub use device::{Device, DeviceError, NullDevice};
pub use graph::{mix_mono_into_stereo, peak, GraphError, Strip};
pub use params::Param;
pub use proto::{
    decode, encode_datagram, Codec, Header, ProtoError, FLAG_CONCEALED, FLAG_DISCONTINUITY,
    HEADER_LEN, VERSION,
};
