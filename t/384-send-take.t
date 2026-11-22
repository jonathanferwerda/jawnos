# tests-for: engine/src/sender.rs engine/src/capture.rs engine/src/lib.rs engine/src/main.rs engine/tests/sender.rs
# covers:    P4's peer sending half (docs/studio-audio-roadmap.md P4, D14): a
#            take recorded on this machine is read as mono, clocked against a
#            master over the same authenticated HELLO/WELCOME session the P3
#            probe and bearer use, resampled onto the master's timeline with
#            the fitted drift, and sent as audio datagrams stamped with
#            offset.to_master(local). The peer owns its take; the master places
#            it. A wrong key gets no WELCOME, so the run fails without audio; a
#            missing file, a rate the file does not have, an empty take and a
#            missing key are usage errors. `--send-live` is the same send with
#            a capture device: a dedicated thread writes every block to the
#            local WAV first, then offers the same frames to a fixed ring the
#            clock loop pops. A full ring overwrites its oldest frames so the live
#            edge survives; a window whose whole span is older than the ring
#            resynchronises to the live edge instead of stalling. The capture
#            sequence is the local timeline: every wake sends exactly the frames
#            the device produced since the last send, so a device that runs at
#            47 976 Hz is not padded up to the wall's 48 000. The loop reports
#            captured, sent, dropped, padded and resynced.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root    = abs_path("$FindBin::Bin/..");
my $sender  = read_file("$root/engine/src/sender.rs");
my $capture = read_file("$root/engine/src/capture.rs");
my $lib     = read_file("$root/engine/src/lib.rs");
my $main    = read_file("$root/engine/src/main.rs");
my $tests   = read_file("$root/engine/tests/sender.rs");

ok( length $sender,  'the sender module is found' );
ok( length $capture, 'the live capture module is found' );
ok( length $lib,     'the engine lib is found' );
ok( length $main,    'the engine CLI is found' );
ok( length $tests,   'the sender integration test is found' );

# --- the module is part of the crate ----------------------------------------
like( $lib, qr/^pub mod sender;/m, 'the sender is declared beside session' );
like( $lib, qr/^pub mod capture;/m, 'the live capture is declared beside the sender' );
like( $lib, qr/^pub use sender::\{/m, 'the sender API is re-exported from the crate root' );
like( $lib, qr/^pub use capture::\{/m, 'the capture API is re-exported from the crate root' );

# --- the live capture, written locally first (D14) ---------------------------
like( $capture, qr/pub trait LiveSource/, 'a live source is one seam the CLI can swap' );
like( $capture, qr/pub struct SyntheticSource/, 'the null backend has a test source, not fake hardware' );
like( $capture, qr/pub fn live_ring/, 'capture and sender share one fixed ring' );
like( $capture, qr/write_i16_unsynced/, 'each captured block reaches the local WAV' );
like( $capture, qr/producer\.push\(block\)|producer\.push\(mono\)/,
	'the same frames are offered to the sender after the WAV write' );
like( $capture, qr/pub fn start_source/, 'a software source runs the same thread' );
like( $capture, qr/pub fn start_hardware/, 'the existing ALSA capture seam starts the device' );
like( $capture, qr/run_capture\(/, 'hardware capture reuses run_capture' );
like( $capture, qr/a live capture is not resampled to another rate/,
	'a granted rate that differs is refused, not converted' );
like( $capture, qr/window\(&self, local: u64/, 'the sender asks for a local-time window' );
like( $capture, qr/out\.fill\(0\)/, 'a short capture is padded by the stated rule' );
like( $capture, qr/seq < start/, 'frames from a span already padded are stale' );
like( $capture, qr/fn pack\(/, 'one atomic carries a frame sequence and its sample' );
like( $capture, qr/oldest_seq >= requested_end/, 'a window behind the whole ring is detected' );
like( $capture, qr/pub resync: Option<u64>/, 'the consumer names the live edge it resynchronised to' );
like( $capture, qr/write\s*\.\s*saturating_sub\(out\.len\(\) as u64\)/,
	'the window resynchronises to the newest full window, not the stale oldest' );
like( $capture, qr/read\.fetch_max/, 'the consumer cursor never moves backwards' );
like( $capture, qr/overflow\s*\.\s*fetch_add/, 'ring overwrites are counted, never blocking' );
like( $capture, qr/pub fn with_cadence/, 'a test source can produce at a deliberate device rate' );
like( $capture, qr/cadence_hz: u32/, 'the source separates its sample rate from its wall cadence' );

# --- the request is validated before a socket opens -------------------------
like( $sender, qr/pub struct SendSpec/, 'the CLI request has one struct' );
like( $sender, qr/pub fn validate_send/, 'validation is callable without a CLI' );
like( $sender, qr/pub struct ValidatedSend/, 'a validated request is a named type' );
like( $sender, qr/pub struct LiveSpec/, 'the live request is its own struct' );
like( $sender, qr/pub fn validate_live/, 'live validation is callable without a CLI' );
like( $sender, qr/pub struct ValidatedLive/, 'a validated live request is a named type' );
like( $sender, qr/pub struct LiveSender/, 'a live block has one position holder' );
like( $sender, qr/pub fn fill\(&mut self, input: &\[i16\]\)/, 'one live wake is stamped and resampled' );
like( $sender, qr/pub fn run_send_live\b/, 'a live send has an entry point' );
like( $sender, qr/pub fn run_send_live_with_source/, 'the suite can run a software source' );
like( $sender, qr/pub fn success_live/, 'a live report carries the capture counts' );
like( $sender, qr/\\"resynced\\":/, 'the live report carries the live-edge skip count' );
like( $sender, qr/pub fn resync_to/, 'a live sender can adopt a resynchronised position' );
like( $sender, qr/let local_send = producer\.produced\(\);/,
	'the ping timestamp is a captured position, not the wall' );
like( $sender, qr/let local_recv = producer\.produced\(\);/,
	'the pong is received at a captured position' );
like( $sender, qr/let available = producer\.written\(\)\.saturating_sub\(sender\.local\(\)\);/,
	'each wake sends exactly the frames captured since the last send' );
like( $sender, qr/available\.min\(PULL_MAX_FRAMES as u64\)/,
	'a capture burst is still capped per wake' );
like( $sender, qr/provisional\.current\(producer\.produced\(\)\)/,
	'the provisional offset ages on the capture timeline' );
like( $sender, qr/window\.resync/, 'the sender adopts the consumer resynchronisation' );
like( $sender, qr/--send-live needs --device NAME/, 'a live send requires a device' );
like( $sender, qr/--send-live needs --out FILE\.wav/, 'a live send requires its local take' );
like( $sender, qr/consumer\.window\(sender\.local\(\)/, 'the clock loop pops only its local window' );
like( $sender, qr/capture\.finished\(\) && consumer\.pending\(\) == 0/,
	'--seconds bounds the capture and the loop drains the ring' );
like( $sender, qr/capture\.stop\(\)/, 'the capture is stopped before the report' );
like( $sender, qr/capture\.join\(\)/, 'the capture thread is joined so the take closes' );
like( $sender, qr/a take is not resampled to another rate/, 'a rate mismatch names the refusal' );
like( $sender, qr/is empty: there are no samples to send/, 'an empty take is refused' );
like( $sender, qr/a send session needs a key/, 'a missing key is refused' );
like( $sender, qr/audio_stream\(spec\.stream\)/, 'the stream is an audio index' );

# --- the take's position and the converter ----------------------------------
like( $sender, qr/pub struct TakeSender/, 'the take has one position holder' );
like( $sender, qr/pub fn block\(/, 'one block is planned and resampled at a time' );
like( $sender, qr/offset\.to_master\(self\.local\)/, 'a block starts where the fit puts it' );
like( $sender, qr/offset\.to_master\(end as u64\)/, 'a block ends where the fit puts the next one' );
like( $sender, qr/None => \(self\.local,/, 'the local position is the pre-estimate stamp' );
like( $sender, qr/LinearResampler::with_capacity/, 'the fitted drift drives the converter' );
like( $sender, qr/resampler\.reset_to\(self\.local\)/, 'the converter is anchored at the block' );
like( $sender, qr/resampler\.push\(/, 'the take is pushed into the converter' );
like( $sender, qr/resampler\.process\(/, 'the master-time output is produced' );
like( $sender, qr/self\.local = end as u64/, 'the take advances by its own clock' );

# --- the authenticated session and the bearer -------------------------------
like( $sender, qr/ClockPeer::new/, 'the sender handshakes with a clock peer' );
like( $sender, qr/with_claim\(Some\(config\.stream\)\)/,
	'the HELLO claims the stream this take will packetize on' );
like( $sender, qr/\.hello\(/, 'a HELLO opens the session' );
like( $sender, qr/accept_welcome\(/, 'only a WELCOME issues a session' );
like( $sender, qr/CLOCK_SESSION/, 'no session means no audio' );
like( $sender, qr/ClockEstimator::with_capacity/, 'one estimator keeps the fit fresh' );
like( $sender, qr/fn drift_is_trusted/, 'a fitted drift waits for a long baseline' );
like( $sender, qr/SENDER_FIT_MIN_SPAN_SECONDS/, 'the baseline is a minute, not just 100 probes' );
like( $sender, qr/fn a_short_take_does_not_trust_a_fitted_drift/,
	'a short take keeps drift 0 and says so' );
like( $sender, qr/struct ProvisionalOffset/, 'the pre-fit offset is one named holder' );
like( $sender, qr/PROVISIONAL_MAX_AGE_SECONDS/, 'a clean exchange does not stamp forever' );
like( $sender, qr/fn offer\(/, 'every measured pong is offered to the pre-fit offset' );
like( $sender, qr/provisional\.current\(/, 'each block asks the stable offset, not the newest pong' );
like( $sender, qr/fn a_jittery_pong_does_not_move_the_stamp/, 'jitter is tested against the stamp' );
like( $sender, qr/fn a_provisional_offset_falls_back_when_the_clean_sample_goes_stale/,
	'the stale fallback is tested' );
like( $sender, qr/fn a_clean_sample_that_has_expired_does_not_block_the_path_it_measures/,
	'a changed path is re-learned after expiry' );
like( $sender, qr/\.ping\(/, 'a CLOCK_PING goes out every loop' );
like( $sender, qr/accept_pong_since/, 'a reply older than the newest ping is measured within a window' );
like( $sender, qr/pong\.echo_local_send/, 'the echoed stamp is the ping time the round trip uses' );
like( $sender, qr/PONG_MAX_AGE_MS/, 'the window is bounded, so an old reply is not a sample' );
like( $sender, qr/ProbeSample::from_pong/, 'the pong becomes an estimator point' );
like( $sender, qr/AudioBearer::new\(config\.key, session\)/, 'the bearer signs with the same key and session' );
like( $sender, qr/bearer\.packetize\(/, 'the block becomes bearer datagrams' );

# --- pacing and a stopped master --------------------------------------------
like( $sender, qr/PING_INTERVAL_MS/, 'the loop is the clock peer 10 ms interval' );
like( $sender, qr/PULL_MAX_FRAMES/, 'a late wake is capped at one burst as the uplink does' );
like( $sender, qr/config\.seconds_given/, 'an absent --seconds ends with the take' );
like( $sender, qr/\.seconds_given\s*\.then\(/, 'only an explicit --seconds sets a wall-clock stop' );
like( $sender, qr/needs_handshake/, 'a quiet master triggers a re-handshake' );
like( $sender, qr/ConnectionRefused|quiet_io/, 'a closed master port is not fatal' );
like( $sender, qr/handshakes \+= 1/, 'every completed handshake is counted' );

# --- the one-line report -----------------------------------------------------
like( $sender, qr/pub struct SenderReport/, 'the run has one report type' );
like( $sender, qr/\\"role\\":\\"sender\\"/, 'the report names the sender role' );
like( $sender, qr/\\"master\\":/, 'the report names the master' );
like( $sender, qr/\\"session\\":/, 'the report carries the session' );
like( $sender, qr/\\"sent\\":/, 'the report carries datagrams sent' );
like( $sender, qr/\\"frames\\":/, 'the report carries audio frames' );
like( $sender, qr/\\"handshakes\\":/, 'the report carries handshakes' );
like( $sender, qr/\\"offset_samples\\":/, 'the report carries the fitted offset' );
like( $sender, qr/\\"drift_ppm\\":/, 'the report carries the fitted drift' );
like( $sender, qr/\\"ok\\":false/, 'a failure keeps the clock peer error shape' );
like( $sender, qr/No key is ever printed/, 'the key is explicitly kept out of output' );

# --- the CLI ----------------------------------------------------------------
like( $main, qr/"--send-take"\s*=>/, 'the send-take flag is parsed' );
like( $main, qr/"--send-live"\s*=>/, 'the send-live flag is parsed' );
like( $main, qr/--send-live options:/, 'the usage text names the live mode' );
like( $main, qr/sender::LiveSpec\s*\{/s, 'the CLI builds the live request once' );
like( $main, qr/sender::validate_live\(/, 'a live usage error is the validate call' );
like( $main, qr/sender::run_send_live\(/, 'the validated live request starts the run' );
like( $main, qr/--send-live needs a capture backend/, 'the null backend is refused for live capture' );
like( $main, qr/"--stream"\s*=>/, 'the source index flag is parsed' );
like( $main, qr/--send-take options:/, 'the usage text names the mode' );
like( $main, qr/sender::SendSpec\s*\{/s, 'the CLI builds the sender request once' );
like( $main, qr/sender::validate_send\(/, 'a usage error is the validate call' );
like( $main, qr/sender::run_send_take\(/, 'the validated request starts the run' );
like( $main, qr/--stream applies only to --send-take/, 'the source index is refused outside the mode' );
like( $main, qr/needs --master IP:PORT: the master to send to/, 'the mode requires a master' );

# --- the tests the module ships ---------------------------------------------
like( $tests, qr/fn a_block_is_stamped_from_the_fit_and_a_late_wake_sends_what_elapsed/, 'pacing and stamping are tested' );
like( $tests, qr/fn before_the_first_estimate_the_take_passes_through_at_its_local_position/, 'the pre-estimate prefix is tested' );
like( $tests, qr/fn a_fast_peer_clock_emits_fewer_master_frames_for_the_same_take_span/, 'drift is tested' );
like( $tests, qr/fn a_real_master_receives_the_take_in_order_on_the_issued_session/, 'a real master and receiver are tested' );
like( $tests, qr/fn a_no_seconds_take_sends_its_last_block_before_exiting/, 'a no-seconds take delivers its last block' );
like( $tests, qr/fn a_long_lived_master_still_places_the_whole_take/, 'a large first offset stays inside the receiver window' );
like( $tests, qr/fn a_wrong_key_gets_no_welcome_and_the_sender_sends_no_audio/, 'a wrong key is tested' );
like( $tests, qr/fn a_missing_key_wrong_rate_and_empty_take_are_usage_errors/, 'the usage errors are tested' );
like( $tests, qr/fn a_live_capture_is_written_locally_first_and_reaches_the_master_in_order/,
	'a synthetic live source reaches a real master and its WAV' );
like( $tests, qr/fn a_live_capture_survives_a_sender_stall_without_late_audio/,
	'a delayed sender wake is resynchronised and the master is not late' );
like( $tests, qr/fn a_live_capture_survives_a_source_stall_and_a_ring_wrap/,
	'a source stall and small ring still deliver live audio' );
like( $tests, qr/fn a_live_capture_is_clocked_by_its_source_not_the_wall/,
	'a slow device is clocked by its frames, not by the wall' );
like( $tests, qr/SyntheticSource::with_cadence\(rate, cadence, total, 480\)/,
	'the regression source injects the device rate error' );
like( $capture, qr/fn a_full_ring_resynchronises_to_the_live_edge_instead_of_stalling/,
	'the full-ring resync is unit tested' );
like( $capture, qr/fn a_window_never_stalls_while_the_ring_wraps/,
	'the window is proved never to stall while the ring wraps' );
like( $tests, qr/fn a_live_send_needs_a_device_an_out_and_an_audio_stream/,
	'the live usage errors are tested' );
like( $tests, qr/read_wav\(&take\.path\)/, 'the local take is read back and checked' );
like( $tests, qr/SyntheticSource::new\(48_000, total, 480\)/, 'the test source has a known pattern' );
like( $tests, qr/UdpSocket::bind\("127\.0\.0\.1:0"\)/, 'the loopback test uses an ephemeral port' );
like( $tests, qr/AudioReceiver::new/, 'the master side places by master position' );
like( $tests, qr/ClockMaster::new/, 'the master side issues a real session' );

done_testing();
