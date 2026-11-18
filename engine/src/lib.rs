//! The JawnOS audio engine.
//!
//! P1 is deliberately the part that must be right *before* a sound card is
//! involved: the datagram header peers agree on, the parameter path the control
//! thread writes and the audio thread reads, and a block graph that never
//! allocates. A null device makes all of it runnable on a machine with no audio
//! at all, which is how the suite exercises the real code (docs/studio-audio-roadmap.md).
//!
//! Real hardware is an opt-in feature (`alsa`, `jack`), so the crate has no
//! default dependency and the suite builds anywhere. The patch-cable loopback
//! reports the monitoring round trip and its honest precision.

pub mod backends;
pub mod device;
pub mod disk;
pub mod effect;
pub mod graph;
pub mod listen;
pub mod loopback;
pub mod mixer;
pub mod params;
pub mod playback;
pub mod proto;
pub mod reverb;
pub mod session;
pub mod wav;
pub mod wav_read;

#[cfg(feature = "alsa")]
pub mod alsa_device;
#[cfg(feature = "jack")]
pub mod jack_device;

pub use backends::{availability, Availability, BackendKind, RunReport};
pub use device::{Device, DeviceError, NullDevice};
pub use disk::DiskWriter;
pub use effect::{Channel, Compressor, Delay, Distortion, Effect, InsertKind, ToneStack};
pub use graph::{mix_mono_into_stereo, peak, GraphError, Strip};
pub use loopback::LoopbackReport;
pub use mixer::{Mixer, ParamName, ParamQueue, Track};
pub use playback::{monitor_json, monitor_start, MonitorSpec, PlayTrack, Playback};
pub use params::Param;
pub use proto::{
    decode, encode_datagram, Codec, Header, ProtoError, FLAG_CONCEALED, FLAG_DISCONTINUITY,
    HEADER_LEN, VERSION,
};
pub use session::{align, elect, Candidate, ClockOffset, NodeId};
pub use wav::{to_i16, WavError, WavWriter, HEADER_LEN as WAV_HEADER_LEN};
pub use wav_read::{read_wav, WavAudio, WavReadError};
