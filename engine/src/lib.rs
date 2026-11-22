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

pub mod auth;
pub mod backends;
pub mod bearing;
pub mod capture;
pub mod device;
pub mod disk;
pub mod effect;
pub mod graph;
pub mod listen;
pub mod loopback;
pub mod mixer;
pub mod monbus;
pub mod params;
pub mod peer;
pub mod pipewire_guard;
pub mod playback;
pub mod proto;
pub mod reverb;
pub mod sender;
pub mod session;
pub mod uplink;
pub mod wav;
pub mod wav_read;

#[cfg(feature = "alsa")]
pub mod alsa_device;
#[cfg(feature = "jack")]
pub mod jack_device;

pub use auth::{mac_tag, tags_match, MAC_LEN};
pub use backends::{availability, Availability, BackendKind, RunReport};
pub use bearing::{
    audio_stream, is_audio_stream, Accepted, AudioBearer, AudioReceiver, BearerError,
    LinearResampler, PullReport, RecvCounters, SendCounters, AUDIO_MAC_LEN, AUDIO_STREAM_BASE,
    AUDIO_STREAM_LAST, DEADLINE_GUARD_FRAMES, DEFAULT_JITTER_FRAMES, DEFAULT_RESAMPLER_CAPACITY,
    MAX_DATAGRAM_LEN, MAX_FRAMES_PER_DATAGRAM,
};
pub use device::{Device, DeviceError, NullDevice};
pub use disk::DiskWriter;
pub use effect::{
    Amp, Autotune, Channel, Compressor, Delay, Distortion, Effect, Equalizer, Flanger, Fuzz,
    InsertKind, Limiter, Maximizer, ToneStack,
};
pub use graph::{mix_mono_into_stereo, peak, GraphError, Strip};
pub use loopback::LoopbackReport;
pub use mixer::{Mixer, ParamName, ParamQueue, Track, MASTER_ORDER};
pub use monbus::{Consumer, MonitorBus, Producer};
pub use playback::{
    monitor_json, monitor_start, ClickSpec, MonitorSpec, PlayTrack, Playback, TransportClip,
    TransportControl, TransportLive, TransportPlan, TransportSource,
};
pub use params::Param;
pub use peer::{
    decode_hello, decode_ping, decode_pong, decode_welcome, encode_hello, encode_ping, encode_pong,
    encode_welcome, latest_estimate, new_shared_estimate, parse_session_key, publish_estimate,
    Clock, ClockEstimator, ClockMaster, ClockPeer, ClockReport, ControlReply, Hello, InstantClock,
    ManualClock, Pong, ProbeError, ProbeSample, SharedEstimate, SkewedClock, Welcome, CLOCK_SESSION,
    DEFAULT_BIND, ESTIMATOR_CAPACITY, HELLO_PAYLOAD_LEN, MIN_SAMPLES, PING_INTERVAL_MS,
    PING_PAYLOAD_LEN, PONG_PAYLOAD_LEN, PONG_TIMEOUT_MS, RTT_SLACK_MS, STREAM_CLOCK_HELLO,
    STREAM_CLOCK_PING, STREAM_CLOCK_PONG, STREAM_CLOCK_WELCOME, WELCOME_PAYLOAD_LEN,
};
pub use proto::{
    decode, encode_datagram, Codec, Header, ProtoError, FLAG_CONCEALED, FLAG_DISCONTINUITY,
    HEADER_LEN, VERSION,
};
pub use capture::{
    live_ring, start_hardware, start_source, CaptureHandle, LiveConsumer, LiveProducer, LiveSource,
    synthetic_sample, SyntheticSource, WindowReport, LIVE_RING_FRAMES,
};
pub use sender::{
    run_send_live, run_send_live_with_source, run_send_take, validate_live, validate_send, LiveSender,
    LiveSpec, SendSpec, SenderReport, TakeBlock, TakeSender, ValidatedLive, ValidatedSend,
};
pub use session::{align, elect, Candidate, ClockOffset, NodeId};
pub use uplink::{
    Offer, Uplink, UplinkConfig, UplinkSource, UplinkSourceSpec, UplinkSourceStatus, UplinkStatus,
    PULL_FRAMES, PULL_INTERVAL_MS,
};
pub use wav::{to_i16, WavError, WavWriter, HEADER_LEN as WAV_HEADER_LEN};
pub use wav_read::{read_wav, WavAudio, WavReadError};
