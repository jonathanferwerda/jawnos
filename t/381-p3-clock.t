# tests-for: engine/src/peer.rs engine/src/main.rs engine/src/lib.rs engine/src/auth.rs
# covers:    P3's first spike (docs/studio-audio-roadmap.md §10 and §13 P3): a
#            clock-only UDP probe between two engines. A peer sends HELLO and
#            the master answers WELCOME with a session id; a CLOCK_PING for that
#            session is answered by a CLOCK_PONG carrying the master's receive
#            and send times. Every clock datagram carries a 16-byte HMAC tag, so
#            the master is never an open port. The peer fits master = a + b*local
#            over a bounded window and reports an offset and a drift. There is
#            no audio path and no resampling yet, so the module must stay free
#            of device code, the CLI must expose both roles, and the default
#            bind must stay on loopback.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");
my $peer = read_file("$root/engine/src/peer.rs");
my $main = read_file("$root/engine/src/main.rs");
my $auth = read_file("$root/engine/src/auth.rs");
my $lib  = read_file("$root/engine/src/lib.rs");

ok( length $peer, 'the clock peer module is found' );
ok( length $main, 'the engine CLI is found' );
ok( length $auth, 'the shared auth module is found' );
ok( length $lib,  'the engine lib is found' );

# --- the module is part of the crate ----------------------------------------
like( $lib, qr/^pub mod peer;/m, 'the peer module is declared beside session and proto' );
like( $lib, qr/^pub mod auth;/m, 'the shared tag module is declared' );
like( $lib, qr/^pub use auth::\{/m, 'the shared tag API is re-exported from the crate root' );
like( $lib, qr/^pub use peer::\{/m, 'the peer API is re-exported from the crate root' );

# --- the protocol ------------------------------------------------------------
like( $peer, qr/STREAM_CLOCK_PING:\s*u16\s*=\s*0xFF00/, 'the ping stream id is reserved in the high half' );
like( $peer, qr/STREAM_CLOCK_PONG:\s*u16\s*=\s*0xFF01/, 'the pong stream id is its pair' );
like( $peer, qr/PING_PAYLOAD_LEN:\s*usize\s*=\s*PING_BODY_LEN\s*\+\s*MAC_LEN/, 'a ping carries its send time and a tag' );
like( $peer, qr/PONG_PAYLOAD_LEN:\s*usize\s*=\s*PONG_BODY_LEN\s*\+\s*MAC_LEN/, 'a pong echoes the ping, carries both master times and a tag' );
like( $auth, qr/MAC_LEN:\s*usize\s*=\s*16/, 'a tag is sixteen bytes' );
like( $peer, qr/pub use crate::auth::MAC_LEN;/, 'the peer re-exports the shared tag length' );
like( $peer, qr/STREAM_CLOCK_HELLO:\s*u16\s*=\s*0xFF02/, 'the handshake has its own stream' );
like( $peer, qr/STREAM_CLOCK_WELCOME:\s*u16\s*=\s*0xFF03/, 'the welcome is its pair' );
like( $peer, qr/pub fn encode_hello/, 'a hello is encoded with its tag' );
like( $peer, qr/pub fn decode_hello/, 'a hello verifies its tag before the master issues a session' );
like( $peer, qr/pub fn encode_welcome/, 'a welcome is encoded' );
like( $peer, qr/pub fn decode_welcome/, 'a welcome is decoded' );
like( $peer, qr/pub fn encode_ping/, 'a ping is encoded without allocating a header' );
like( $peer, qr/pub fn decode_ping/, 'a ping is decoded' );
like( $peer, qr/pub fn encode_pong/, 'a pong is encoded' );
like( $peer, qr/pub fn decode_pong/, 'a pong is decoded' );
like( $peer, qr/pub struct ClockMaster/, 'the master owns the session table in one type' );
like( $peer, qr/pub struct ClockPeer/, 'the peer owns its session and replay window' );
like( $peer, qr/pub fn answer\(/, 'the master answers in one call' );
like( $auth, qr/pub fn mac_tag/, 'every clock datagram carries an HMAC tag' );
like( $auth, qr/pub fn tags_match/, 'a tag is compared without early exit' );
like( $peer, qr/use crate::auth::\{mac_tag, tags_match\}/, 'the clock imports the shared tag implementation' );
like( $peer, qr/pub fn parse_session_key/, 'the 32-byte key is parsed from hex' );
like( $peer, qr/pub fn hello\(/, 'the peer handshakes before it pings' );
like( $peer, qr/pub fn accept_welcome/, 'the peer takes the session id from the welcome' );
like( $peer, qr/pub fn accept_pong/, 'a pong is verified before it reaches the estimator' );
like( $peer, qr/pub fn accept_pong_since/, 'a reply that outlives its cycle is still measured' );
like( $peer, qr/fn a_pong_for_an_older_ping_is_measured_within_the_window/,
	'a stale-but-recent reply is tested' );
like( $peer, qr/STREAM_CLOCK_PONG/, 'the master replies on the pong stream' );
like( $peer, qr/echo_local_send/, 'the pong echoes the ping so a late reply is ignored' );

# --- the estimator -----------------------------------------------------------
like( $peer, qr/pub trait Clock/, 'a Clock abstraction lets a test inject time' );
like( $peer, qr/pub struct InstantClock/, 'the real clock is Instant plus a rate' );
like( $peer, qr/pub struct ManualClock/, 'the test clock is settable' );
like( $peer, qr/pub struct SkewedClock/, 'a skewed view models a fast or slow peer' );
like( $peer, qr/pub struct ClockEstimator/, 'the estimator is a named type' );
like( $peer, qr/VecDeque/, 'the estimate is bounded, not an unbounded history' );
like( $peer, qr/ESTIMATOR_CAPACITY:\s*usize\s*=\s*64/, 'the default window is 64 probes' );
like( $peer, qr/RTT_SLACK_MS/, 'the outlier cutoff scales with the round trip' );
like( $peer, qr/rtt_samples/, 'a probe carries its round trip for the outlier test' );
like( $peer, qr/fn local_midpoint/, 'the fit uses the local midpoint' );
like( $peer, qr/fn master_midpoint/, 'the fit uses the master midpoint' );
like( $peer, qr/\(1\.0 - slope\) \* 1_000_000\.0/, 'drift is the local rate error in ppm' );
like( $peer, qr/pub type SharedEstimate/, 'the latest estimate has a shared home' );
like( $peer, qr/pub fn publish_estimate/, 'the probe thread publishes an estimate' );
like( $peer, qr/pub fn latest_estimate/, 'a later render loop can read the latest estimate' );

# The spike is clock-only: no device opens in this module.
unlike( $peer, qr/\b(?:NullDevice|Device|Playback|Mixer)\b/, 'the clock module touches no audio device' );
unlike( $peer, qr/\.president/, 'the clock module writes no socket under ~/.president' );

# --- the tests the module ships ---------------------------------------------
like( $peer, qr/fn the_tag_is_the_last_sixteen_bytes_of_every_clock_payload/, 'the tag placement is pinned' );
like( $peer, qr/fn a_hello_gets_a_session_a_retry_keeps_it_and_a_wrong_key_gets_none/, 'a wrong key gets no session' );
like( $peer, qr/fn a_pong_with_a_corrupted_mac_is_not_accepted/, 'a corrupted tag is refused' );
like( $peer, qr/fn a_ping_for_an_unknown_session_is_ignored_and_counted/, 'an unknown session is dropped' );
like( $peer, qr/fn a_replayed_ping_seq_is_ignored_and_counted/, 'a replay is dropped' );
like( $peer, qr/fn a_clock_ping_round_trips_the_header_and_its_send_time/, 'the ping round-trip is tested' );
like( $peer, qr/fn a_clock_pong_round_trips_the_echo_and_both_master_times/, 'the pong round-trip is tested' );
like( $peer, qr/fn the_estimator_recovers_a_linear_clock_with_jitter/, 'the estimator recovers offset and drift' );
like( $peer, qr/fn high_round_trip_outliers_are_dropped_not_fitted/, 'high-RTT outliers are discarded' );
like( $peer, qr/fn a_skewed_peer_clock_is_recovered_within_a_few_ppm/, 'a 100 ppm peer is recovered' );
like( $peer, qr/fn a_udp_loopback_recovers_near_zero_offset_and_drift_and_tolerates_loss/, 'two threads on 127.0.0.1 exchange real datagrams' );
like( $peer, qr/UdpSocket::bind\("127\.0\.0\.1:0"\)/, 'the loopback test uses an ephemeral loopback port' );

# --- the CLI -----------------------------------------------------------------
like( $main, qr/^\s*ClockMaster,/m, 'the clock master is a mode' );
like( $main, qr/^\s*ClockPeer,/m, 'the clock peer is a mode' );
like( $main, qr/"--clock-master"\s*=>/, 'the master flag is parsed' );
like( $main, qr/"--clock-peer"\s*=>/, 'the peer flag is parsed' );
like( $main, qr/"--bind"\s*=>/, 'the master bind flag is parsed' );
like( $main, qr/"--master"\s*=>/, 'the peer master flag is parsed' );
like( $main, qr/Mode::ClockMaster\s*=>\s*run_clock_master/, 'the master mode runs its own function' );
like( $main, qr/Mode::ClockPeer\s*=>\s*run_clock_peer/, 'the peer mode runs its own function' );
like( $main, qr/fn run_clock_master/, 'the master run function exists' );
like( $main, qr/fn run_clock_peer/, 'the peer run function exists' );
like( $main, qr/options\.bind\.as_deref\(\)\.unwrap_or\(peer::DEFAULT_BIND\)/, 'the master bind defaults to the module constant' );
like( $peer, qr/DEFAULT_BIND:\s*&str\s*=\s*"127\.0\.0\.1:0"/, 'the default bind is loopback, not a public port' );
like( $main, qr/--clock-peer needs --master IP:PORT/, 'a peer without a master is refused' );
like( $main, qr/--bind applies only to --clock-master/, 'the bind flag is not silently accepted elsewhere' );
like( $main, qr/--master applies only to --clock-peer/, 'the master flag is not silently accepted elsewhere' );
like( $main, qr/"--session-key-hex"\s*=>/, 'the session key flag is parsed' );
like( $main, qr/a clock session needs a key/, 'a clock mode without a key is a usage error' );
like( $main, qr/JAWNOS_AUDIO_SESSION_KEY/, 'the supervisor can supply the key in the environment' );
like( $peer, qr/Never echo the key/, 'a malformed key is never repeated back' );
like( $main, qr/ClockReport::master/, 'the master prints its bound port and served count' );
like( $main, qr/ClockReport::peer/, 'the peer prints its estimate and counts' );
like( $main, qr/clock master listening on \{bound\}/, 'the bound port is printed before the run ends' );
like( $main, qr/--clock-master \[options\]/, 'the usage names the master mode' );
like( $main, qr/--clock-peer \[options\]/, 'the usage names the peer mode' );
like( $main, qr/--master IP:PORT  the clock master to probe/, 'the usage asks for the peer master' );

done_testing();
