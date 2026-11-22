# tests-for: engine/src/sender.rs engine/src/lib.rs engine/src/main.rs engine/tests/sender.rs
# covers:    P4's peer sending half (docs/studio-audio-roadmap.md P4, D14): a
#            take recorded on this machine is read as mono, clocked against a
#            master over the same authenticated HELLO/WELCOME session the P3
#            probe and bearer use, resampled onto the master's timeline with
#            the fitted drift, and sent as audio datagrams stamped with
#            offset.to_master(local). The peer owns its take; the master places
#            it. A wrong key gets no WELCOME, so the run fails without audio; a
#            missing file, a rate the file does not have, an empty take and a
#            missing key are usage errors.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root   = abs_path("$FindBin::Bin/..");
my $sender = read_file("$root/engine/src/sender.rs");
my $lib    = read_file("$root/engine/src/lib.rs");
my $main   = read_file("$root/engine/src/main.rs");
my $tests  = read_file("$root/engine/tests/sender.rs");

ok( length $sender, 'the sender module is found' );
ok( length $lib,    'the engine lib is found' );
ok( length $main,   'the engine CLI is found' );
ok( length $tests,  'the sender integration test is found' );

# --- the module is part of the crate ----------------------------------------
like( $lib, qr/^pub mod sender;/m, 'the sender is declared beside session' );
like( $lib, qr/^pub use sender::\{/m, 'the sender API is re-exported from the crate root' );

# --- the request is validated before a socket opens -------------------------
like( $sender, qr/pub struct SendSpec/, 'the CLI request has one struct' );
like( $sender, qr/pub fn validate_send/, 'validation is callable without a CLI' );
like( $sender, qr/pub struct ValidatedSend/, 'a validated request is a named type' );
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
like( $sender, qr/\.hello\(/, 'a HELLO opens the session' );
like( $sender, qr/accept_welcome\(/, 'only a WELCOME issues a session' );
like( $sender, qr/CLOCK_SESSION/, 'no session means no audio' );
like( $sender, qr/ClockEstimator::with_capacity/, 'one estimator keeps the fit fresh' );
like( $sender, qr/fn drift_is_trusted/, 'a fitted drift waits for a long baseline' );
like( $sender, qr/SENDER_FIT_MIN_SPAN_SECONDS/, 'the baseline is a minute, not just 100 probes' );
like( $sender, qr/fn a_short_take_does_not_trust_a_fitted_drift/,
	'a short take keeps drift 0 and says so' );
like( $sender, qr/\.ping\(/, 'a CLOCK_PING goes out every loop' );
like( $sender, qr/ProbeSample::from_pong/, 'the pong becomes an estimator point' );
like( $sender, qr/AudioBearer::new\(config\.key, session\)/, 'the bearer signs with the same key and session' );
like( $sender, qr/bearer\.packetize\(/, 'the block becomes bearer datagrams' );

# --- pacing and a stopped master --------------------------------------------
like( $sender, qr/PING_INTERVAL_MS/, 'the loop is the clock peer 10 ms interval' );
like( $sender, qr/PULL_MAX_FRAMES/, 'a late wake is capped at one burst as the uplink does' );
like( $sender, qr/config\.seconds_given/, 'an absent --seconds ends with the take' );
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
like( $main, qr/"--stream"\s*=>/, 'the source index flag is parsed' );
like( $main, qr/--send-take options:/, 'the usage text names the mode' );
like( $main, qr/sender::SendSpec\s*\{/s, 'the CLI builds the sender request once' );
like( $main, qr/sender::validate_send\(/, 'a usage error is the validate call' );
like( $main, qr/sender::run_send_take\(/, 'the validated request starts the run' );
like( $main, qr/--stream applies only to --send-take/, 'the source index is refused outside the mode' );
like( $main, qr/--send-take needs --master/, 'the mode requires a master' );

# --- the tests the module ships ---------------------------------------------
like( $tests, qr/fn a_block_is_stamped_from_the_fit_and_a_late_wake_sends_what_elapsed/, 'pacing and stamping are tested' );
like( $tests, qr/fn before_the_first_estimate_the_take_passes_through_at_its_local_position/, 'the pre-estimate prefix is tested' );
like( $tests, qr/fn a_fast_peer_clock_emits_fewer_master_frames_for_the_same_take_span/, 'drift is tested' );
like( $tests, qr/fn a_real_master_receives_the_take_in_order_on_the_issued_session/, 'a real master and receiver are tested' );
like( $tests, qr/fn a_long_lived_master_still_places_the_whole_take/, 'a large first offset stays inside the receiver window' );
like( $tests, qr/fn a_wrong_key_gets_no_welcome_and_the_sender_sends_no_audio/, 'a wrong key is tested' );
like( $tests, qr/fn a_missing_key_wrong_rate_and_empty_take_are_usage_errors/, 'the usage errors are tested' );
like( $tests, qr/UdpSocket::bind\("127\.0\.0\.1:0"\)/, 'the loopback test uses an ephemeral port' );
like( $tests, qr/AudioReceiver::new/, 'the master side places by master position' );
like( $tests, qr/ClockMaster::new/, 'the master side issues a real session' );

done_testing();
