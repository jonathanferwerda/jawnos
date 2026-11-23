# tests-for: engine/src/uplink.rs engine/src/socket.rs engine/src/patchbay.rs engine/src/main.rs engine/src/lib.rs engine/src/system_capture.rs engine/tests/uplink.rs
# covers:    P4's master side (docs/studio-audio-roadmap.md P4): a `peer` source is
#            another machine's input. It has no interface channel of its own, so
#            it binds even when every channel is taken; it is `pending` until
#            the uplink attaches its ring, and then mixes like a `parec` input
#            from a stereo block of its own. `--serve --uplink ADDR` starts one
#            UDP thread that answers a peer's HELLO with WELCOME on the clock
#            key and feeds AUDIO_STREAM_BASE + plan index through `pull_at` into
#            the ring. The session in the 32-byte header is the peer id, so more
#            than one peer can feed one master: each stream is claimed by its
#            peer's first authenticated audio datagram, never by a WELCOME, so a
#            second peer's handshake leaves the first receiver alone. A stream
#            belongs to one session at a time; a different session takes it when
#            its authenticated HELLO claimed that stream (the stable peer
#            identity: every --send-take is a new process on a new port), or -
#            for a claimless clock-only session - when the owner is no longer
#            live in the master's table or from the same UDP endpoint. A session
#            claiming another stream is refused. A live stream claimed by a
#            second peer, an unissued session, a foreign session, a wrong tag, a
#            stereo datagram or an unmapped stream is counted and dropped, never
#            fatal. A rebuild replaces the receiver, not the totals: the replaced
#            receiver's counters are folded in, so `status` never reads received
#            0 after a re-handshake. `status.sessions` counts sessions the master
#            issued, not WELCOMEs. Status keeps its keys and adds `uplink`.
#            A `peer` source may declare `latency_ms`: its capture/pipeline
#            latency. A positive declaration is carried to the uplink and
#            subtracted from each datagram's master position, so that source is
#            placed that much earlier and a take played late is recorded in
#            time. Only a peer is shifted; a local input's declaration is kept
#            by the plan but not compensated on this path yet. Status names the
#            codec a source locked to (`pcm16` or `pcm16k`), so a deck's 16 kHz
#            stream is visible beside the master-rate ones.
#            A `peer` source may also declare `buffer_ms`: how far behind the
#            master clock the uplink reads that source, so a path with more
#            floor than one jitter window (a deck on Wi-Fi) is given more slack
#            without every peer paying for the slowest one. The engine floor is
#            one window, the bound is two seconds, and `status` reports the
#            buffer each source actually ran and its receiver window's size.

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
like( $patch, qr/fn peer_latency_ms/, 'a peer source may declare its latency' );
like( $patch, qr/PEER_LATENCY_MAX_MS/, 'the declaration has a stated upper bound' );
like( $patch, qr/latency_ms/, 'the compiled source carries the declaration to the uplink' );
like( $patch, qr/fn peer_buffer_ms/, 'a peer source may declare its own read buffer' );
like( $patch, qr/PEER_BUFFER_MAX_MS/, 'the buffer has a stated upper bound too' );
like( $patch, qr/fn a_peer_declares_its_latency_and_two_peers_can_differ/,
	'two peers may declare different latencies' );
like( $patch, qr/fn a_peer_buffer_is_declared_per_source/,
	'one peer may read with a longer buffer than another' );
like( $patch, qr/fn a_peer_buffer_outside_the_bounds_is_refused/,
	'a negative or over-bound buffer is refused by name' );
like( $patch, qr/fn a_peer_latency_outside_the_bounds_is_refused/,
	'a negative or over-bound declaration is refused by name' );
like( $patch, qr/fn a_local_input_latency_is_kept_but_not_refused/,
	'a local input latency is kept but not refused' );
like( $patch, qr/\(\s*index,\s*source\.id\.clone\(\),\s*source\.latency_ms,\s*source\.buffer_ms,\s*\)/s,
	'wants_peer carries both declarations with the source' );

# --- the stream mapping and the session rule --------------------------------
like( $uplink, qr/audio_stream\(index\)/, 'the stream is AUDIO_STREAM_BASE + the plan index' );
like( $uplink, qr/is_audio_stream\(stream\)/, 'an audio stream must be in the reserved range' );
like( $uplink, qr/ClockMaster::new/, 'the thread owns a clock master with the key' );
like( $uplink, qr/pub fn offer\(/, 'an audio datagram claims its stream, a WELCOME does not' );
like( $uplink, qr/A stream belongs to one session at a time/,
	'the one-owner rule is documented where the code makes it' );
like( $uplink, qr/master\.is_live\(/, 'session liveness comes from the master session table' );
like( $uplink, qr/master\.session_claim\(/, 'the master records the stream a HELLO claimed' );
like( $uplink, qr/Some\(claimed\) if claimed == self\.stream/, 'a session that claimed this stream takes it over' );
like( $uplink, qr/Offer::Occupied/, 'a claimless session cannot evict a live peer' );
like( $uplink, qr/self\.origin != Some\(origin\)/, 'the endpoint is only the claimless fallback' );
like( $uplink, qr/session_live/, 'a session the master did not issue claims nothing' );
like( $uplink, qr/self\.session == Some\(session\)/, 'the owning session is the ordinary path, never a rebuild' );
like( $uplink, qr/past: RecvCounters/, 'a rebuilt receiver leaves its totals in a baseline' );
like( $uplink, qr/fn add_counters/, 'the totals are summed field by field' );
like( $uplink, qr/self\.past = add_counters/, 'a new session folds the outgoing receiver in' );
like( $uplink, qr/AudioReceiver::new\(/, 'a source owns a receiver' );
like( $uplink, qr/fn with_latency/, 'a source can be built with a declared latency' );
like( $uplink, qr/fn with_latency_and_buffer/, 'a source can be built with its own read buffer' );
like( $uplink, qr/fn latency_frames/, 'the declaration is converted to master frames' );
like( $uplink, qr/fn buffer_frames/, 'the buffer declaration is converted to master frames once' );
like( $uplink, qr/PULL_BUFFER_MAX_MS/, 'the buffer has the same two-second bound as the latency' );
like( $uplink, qr/fn accept_shifted/, 'the receiver authenticates then shifts placement' );
like( $uplink, qr/candidate\.accept_shifted\(datagram, self\.shift_frames\)/,
	'a new receiver is built on the shifted timeline' );
like( $uplink, qr/master\.issued\(\)/, 'status.sessions counts the sessions the master issued' );

# --- pacing and the ring ----------------------------------------------------
like( $uplink, qr/PULL_FRAMES:\s*usize\s*=\s*480/, 'a wake pulls one 10 ms block' );
like( $uplink, qr/PULL_INTERVAL_MS:\s*u64\s*=\s*10/, 'the thread wakes every 10 ms' );
like( $uplink, qr/PULL_BUFFER_FRAMES:/, 'the read cursor trails the clock by a jitter buffer' );
like( $uplink, qr/PULL_BUFFER_FRAMES:\s*usize\s*=\s*DEFAULT_JITTER_FRAMES;/,
	'the placement buffer is one jitter window (4096 frames), not two' );
like( $uplink, qr/PULL_WINDOW_FRAMES:\s*usize\s*=\s*4\s*\*\s*DEFAULT_JITTER_FRAMES;/,
	'the receiver window stays four windows so a burst still fits' );
like( $uplink, qr/pull_at\(/, 'the pull has a leading-edge deadline' );
like( $uplink, qr/pull_to\(/, 'the paced read never passes the playback head' );
like( $uplink, qr/\bsource\.pump_to\(/, 'the thread pulls to the playback head' );
like( $uplink, qr/now\.saturating_sub\(source\.buffer_frames\(\) as u64\)/,
	'each source reads behind its own buffer, not one process-wide value' );
like( $uplink, qr/fn window_frames/, 'the receiver window covers the source\'s own buffer' );
like( $uplink, qr/PULL_WINDOW_FRAMES\.max\(2 \* self\.buffer_frames\)/,
	'and is at least twice it, so a burst ahead of the cursor still fits' );
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
like( $uplink, qr/\\"next_master\\"/, 'each source reports the next pull position' );
like( $uplink, qr/\\"first_master\\"/, 'each source reports where the timeline starts' );
like( $uplink, qr/\\"from_deadline\\"/, 'each source reports deadline concealment' );
like( $uplink, qr/\\"latency_ms\\"/, 'each source reports its declared latency in ms' );
like( $uplink, qr/\\"latency_frames\\"/, 'each source reports the same declaration in frames' );
like( $uplink, qr/\\"buffer_ms\\"/, 'each source reports the read buffer it actually ran' );
like( $uplink, qr/\\"buffer_frames\\"/, 'and the same buffer in frames' );
like( $uplink, qr/\\"codec\\"/, 'each source reports the codec it locked to' );

# --- the server wires it and keeps every existing key -----------------------
like( $socket, qr/pub uplink:\s*Option<UplinkConfig>/, 'the serve config can name an uplink' );
like( $socket, qr/wants_peer\(\)/, 'the worker asks which sources need rings' );
like( $socket, qr/Uplink::start\(/, 'the worker starts the one uplink thread' );
like( $socket, qr/attach_input\(\s*index, consumer\)/, 'the ring reaches the patch source' );
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
like( $tests, qr/fn a_same_session_is_placed_while_a_new_one_rebuilds/,
	'a retried handshake keeps the buffered audio and a new session rebuilds' );
like( $tests, qr/fn a_claimed_stream_is_the_peer_identity_not_the_port/,
	'a claim identifies the peer, the endpoint does not' );
like( $tests, qr/fn a_repeat_take_from_a_new_port_takes_its_claimed_stream_back/,
	'a repeat take from a new port takes its stream back and a mismatched claim is refused' );
like( $tests, qr/fn two_peers_share_the_uplink_and_a_third_cannot_take_a_busy_stream/,
	'two peers feed two streams and a third cannot take a busy one' );
like( $tests, qr/fn a_datagram_delayed_inside_the_buffer_is_placed_not_late/,
	'a delayed datagram inside the buffer is placed, not refused' );
like( $tests, qr/fn a_declared_latency_places_a_peer_earlier_than_an_undeclared_one/,
	'a declared latency places a peer earlier than an undeclared one' );
like( $tests, qr/fn a_source_may_read_further_behind_the_clock_than_another/,
	'a source with a longer buffer places a datagram another already read' );
like( $tests, qr/fn a_short_buffer_reads_no_newer_than_one_window/,
	'the buffer floor and ceiling are pinned' );
like( $tests, qr/UdpSocket::bind\("127\.0\.0\.1:0"\)/, 'the loopback test uses an ephemeral port' );
like( $patch, qr/fn a_peer_source_is_pending_not_silent/, 'the patchbay peer state is tested' );
like( $patch, qr/fn a_peer_ring_mixes_like_a_parec_input/, 'the peer mix is tested' );

done_testing();
