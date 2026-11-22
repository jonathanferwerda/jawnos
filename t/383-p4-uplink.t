# tests-for: engine/src/uplink.rs engine/src/socket.rs engine/src/patchbay.rs engine/src/main.rs engine/src/lib.rs engine/src/system_capture.rs engine/tests/uplink.rs
# covers:    P4's master side (docs/studio-audio-roadmap.md P4): a `peer` source is
#            another machine's input. It has no interface channel of its own, so
#            it binds even when every channel is taken; it is `pending` until
#            the uplink attaches its ring, and then mixes like a `parec` input
#            from a stereo block of its own. `--serve --uplink ADDR` starts one
#            UDP thread that answers a peer's HELLO with WELCOME on the clock
#            key, rebuilds every source's receiver with the issued session, and
#            feeds AUDIO_STREAM_BASE + plan index through `pull_at` into the
#            ring. A rebuild replaces the receiver, not the totals: the replaced
#            receiver's counters are folded in, so `status` never reads received
#            0 after a re-handshake. A foreign session, a wrong tag, a stereo
#            datagram or an unmapped stream is counted and dropped, never fatal.
#            Status keeps its keys and adds `uplink`. A failed patch names the
#            PCM it opened, the node target, and the server's then-default sink.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root    = abs_path("$FindBin::Bin/..");
my $uplink  = read_file("$root/engine/src/uplink.rs");
my $lib     = read_file("$root/engine/src/lib.rs");
my $socket  = read_file("$root/engine/src/socket.rs");
my $patch   = read_file("$root/engine/src/patchbay.rs");
my $main    = read_file("$root/engine/src/main.rs");
my $system  = read_file("$root/engine/src/system_capture.rs");
my $tests   = read_file("$root/engine/tests/uplink.rs");

ok( length $uplink, 'the uplink module is found' );
ok( length $lib,    'the engine lib is found' );
ok( length $socket, 'the control socket is found' );
ok( length $patch,  'the patchbay is found' );
ok( length $main,   'the engine CLI is found' );
ok( length $system, 'the system capture is found' );
ok( length $tests,  'the uplink integration test is found' );

# --- the module is part of the crate ----------------------------------------
like( $lib, qr/^pub mod uplink;/m, 'the uplink is declared beside session' );
like( $lib, qr/^pub use uplink::\{/m, 'the uplink API is re-exported from the crate root' );

# --- the patchbay binds a peer like an input --------------------------------
like( $patch, qr/fn wants_peer\(&self\)/, 'a peer source has one ring question' );
like( $patch, qr/peer:\s*bool/, 'a source records that it is a peer' );
like( $patch, qr/source\.peer/, 'a peer is routed exactly like an input' );
like( $patch, qr/pub peer:\s*&'static str/, 'the plan reports the peer state' );
like( $patch, qr/summary\.peer\s*=\s*"capturing"/, 'attaching the ring moves it out of pending' );
like( $patch, qr/!source\.peer/, 'a peer asks for no card capture or parec input' );
like( $patch, qr/peer_blocks/, 'a peer is popped into a block of its own, not an interface channel' );
like( $patch, qr/fn a_peer_mixes_with_every_interface_channel_taken/,
	'a peer mixes when every interface channel is taken' );

# --- the stream mapping and the session rule --------------------------------
like( $uplink, qr/audio_stream\(index\)/, 'the stream is AUDIO_STREAM_BASE + the plan index' );
like( $uplink, qr/is_audio_stream\(stream\)/, 'an audio stream must be in the reserved range' );
like( $uplink, qr/ClockMaster::new/, 'the thread owns a clock master with the key' );
like( $uplink, qr/decode_welcome/, 'a WELCOME names the session' );
like( $uplink, qr/source\.attach_session\(/, 'a session rebuilds every source receiver' );
like( $uplink, qr/past: RecvCounters/, 'a rebuilt receiver leaves its totals in a baseline' );
like( $uplink, qr/fn add_counters/, 'the totals are summed field by field' );
like( $uplink, qr/self\.past = add_counters/, 'a new session folds the outgoing receiver in' );
like( $uplink, qr/AudioReceiver::new\(/, 'a source owns a receiver' );
like( $uplink, qr/One session at a time|One audio session at a time/,
	'the one-session limit is documented where the code makes it' );

# --- pacing and the ring ----------------------------------------------------
like( $uplink, qr/PULL_FRAMES:\s*usize\s*=\s*480/, 'a wake pulls one 10 ms block' );
like( $uplink, qr/PULL_INTERVAL_MS:\s*u64\s*=\s*10/, 'the thread wakes every 10 ms' );
like( $uplink, qr/pull_at\(/, 'the pull has a leading-edge deadline' );
like( $uplink, qr/InstantClock::new/, 'one InstantClock is shared with the clock master' );
like( $uplink, qr/DEFAULT_JITTER_FRAMES/, 'the receiver uses the bearer jitter window' );
like( $uplink, qr/\.push\(&self\.pull_f32/, 'the block goes into a lock-free ring' );
like( $uplink, qr/\.stop\.store\(true/, 'the thread is stopped by a flag' );
like( $uplink, qr/handle\.join\(\)/, 'the stop joins the thread' );

# --- refusals are counted, never fatal --------------------------------------
like( $uplink, qr/STREAM_CLOCK_HELLO\s*\|\s*STREAM_CLOCK_PING/, 'clock control goes to the master' );
like( $uplink, qr/audio stream with no peer source|names no peer source/, 'an unmapped stream is named' );
like( $uplink, qr/\*rejected \+= 1/, 'a dropped datagram is counted' );
like( $uplink, qr/BearerError::Session\(0\)/, 'audio before a session has nowhere to go' );
like( $uplink, qr/No key is ever logged|never logged/, 'the key is explicitly kept out of logs' );

# --- status -----------------------------------------------------------------
like( $uplink, qr/pub struct UplinkStatus/, 'the uplink has one status object' );
like( $uplink, qr/\\"state\\"/, 'status names the state' );
like( $uplink, qr/\\"bind\\"/, 'status carries the bound address' );
like( $uplink, qr/\\"error\\"/, 'status carries a bind error' );
like( $uplink, qr/\\"sessions\\"/, 'status carries the session count' );
like( $uplink, qr/\\"received\\"/, 'each source reports received datagrams' );
like( $uplink, qr/\\"late\\"/, 'each source reports late datagrams' );
like( $uplink, qr/\\"concealed\\"/, 'each source reports concealed frames' );
like( $uplink, qr/\\"dropped\\"/, 'each source reports ring drops' );
like( $uplink, qr/\\"last_master\\"/, 'each source reports the last master position' );
like( $uplink, qr/\\"from_deadline\\"/, 'each source reports deadline concealment' );

# --- the server wires it and keeps every existing key -----------------------
like( $socket, qr/pub uplink:\s*Option<UplinkConfig>/, 'the serve config can name an uplink' );
like( $socket, qr/wants_peer\(\)/, 'the worker asks which sources need rings' );
like( $socket, qr/Uplink::start\(/, 'the worker starts the one uplink thread' );
like( $socket, qr/attach_input\(index, consumer\)/, 'the ring reaches the patch source' );
like( $socket, qr/UplinkStatus::failed/, 'a bind failure is reported without stopping the patch' );
like( $socket, qr/self\.uplink\.take\(\)/, 'the uplink is stopped and joined with the patch' );
like( $socket, qr/fn patch_error\(/, 'a failed patch has one sentence builder' );
like( $socket, qr/default sink/, 'a failed patch names the server default sink' );
like( $socket, qr/default_sink\(\)/, 'the default sink is read only when the patch fails' );
like( $system, qr/pub fn default_sink\(\)/, 'the sink question is asked through pactl' );
like( $socket, qr/\\"uplink\\":\{\}/, 'the status line gains an uplink object' );
like( $socket, qr/machine.*plan.*uplink/s, 'the status still carries the machine and plan keys' );

# --- the CLI ----------------------------------------------------------------
like( $main, qr/"--uplink"\s*=>/, 'the uplink flag is parsed' );
like( $main, qr/--uplink applies only to --serve/, 'the flag is refused outside serve' );
like( $main, qr/an uplink needs a session key/, 'the uplink requires a key' );
like( $main, qr/keyed_serve/, 'the key is allowed for serve when the uplink is named' );
like( $main, qr/--uplink ADDR/, 'the usage text names the flag' );
like( $main, qr/socket::Config\s*\{/s, 'the serve config is built in one place' );
like( $main, qr/uplink,/, 'the serve config carries the uplink' );

# --- the tests the module ships ---------------------------------------------
like( $tests, qr/fn a_clock_handshake_and_audio_datagram_fill_the_source_ring/, 'the handshake and ring are tested' );
like( $tests, qr/fn a_wrong_key_gets_no_welcome_and_no_audio/, 'a wrong key is tested' );
like( $tests, qr/fn a_lost_tail_is_concealed_and_visible_in_the_counters/, 'the deadline counters are tested' );
like( $tests, qr/fn two_real_sockets_carry_a_peer_block/, 'two real sockets are tested' );
like( $tests, qr/fn an_audio_stream_with_no_peer_source_is_counted_not_mixed/, 'an unmapped stream is tested' );
like( $tests, qr/fn a_rehandshake_keeps_the_counters/, 'the totals survive a re-handshake' );
like( $tests, qr/UdpSocket::bind\("127\.0\.0\.1:0"\)/, 'the loopback test uses an ephemeral port' );
like( $patch, qr/fn a_peer_source_is_pending_not_silent/, 'the patchbay peer state is tested' );
like( $patch, qr/fn a_peer_ring_mixes_like_a_parec_input/, 'the peer mix is tested' );

done_testing();
