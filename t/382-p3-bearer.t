# tests-for: engine/src/bearing.rs
# covers:    P3's audio bearer (docs/studio-audio-roadmap.md §10 and §13 P3): PCM16
#            frames for one input travel in authenticated datagrams on the clock
#            session, a bounded jitter buffer places them by master position and
#            conceals a gap without shifting the timeline, and a linear converter
#            resamples the peer's stream to the master rate using the fitted
#            offset and drift. No device is opened here; wiring capture and the
#            patchbay is P4.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root  = abs_path("$FindBin::Bin/..");
my $bear  = read_file("$root/engine/src/bearing.rs");
my $lib   = read_file("$root/engine/src/lib.rs");
my $peer  = read_file("$root/engine/src/peer.rs");
my $tests = read_file("$root/engine/tests/bearing.rs");

ok( length $bear,  'the audio bearer module is found' );
ok( length $lib,   'the engine lib is found' );
ok( length $peer,  'the clock peer module is found' );
ok( length $tests, 'the bearer integration test is found' );

# --- the module is part of the crate ----------------------------------------
like( $lib, qr/^pub mod bearing;/m, 'the bearer module is declared beside peer and proto' );
like( $lib, qr/^pub use bearing::\{/m, 'the bearer API is re-exported' );

# --- the stream range cannot collide with the clock -------------------------
like( $bear, qr/AUDIO_STREAM_BASE:\s*u16\s*=\s*0x1000/, 'audio streams start above the small control ids' );
like( $bear, qr/AUDIO_STREAM_LAST:\s*u16\s*=\s*0x7FFF/, 'audio streams stop below the clock control block' );
like( $bear, qr/fn is_audio_stream/, 'the range is checked in one place' );
like( $peer, qr/STREAM_CLOCK_PING:\s*u16\s*=\s*0xFF00/, 'the clock keeps the 0xFF00 block the range avoids' );

# --- the datagram -----------------------------------------------------------
like( $bear, qr/MAX_FRAMES_PER_DATAGRAM:\s*usize\s*=\s*512/, 'a datagram carries at most 512 frames' );
like( $bear, qr/MAX_DATAGRAM_LEN:\s*usize\s*=\s*HEADER_LEN\s*\+\s*MAX_SAMPLES_PER_DATAGRAM\s*\*\s*2\s*\+\s*AUDIO_MAC_LEN/,
	'the whole datagram is header, body and tag' );
like( $bear, qr/AUDIO_MAC_LEN:\s*usize\s*=\s*16/, 'the tag is sixteen bytes' );
like( $bear, qr/pub fn encode_datagram/, 'a datagram is encoded into a caller buffer' );
like( $bear, qr/pub fn packetize/, 'a block is split into datagrams' );
like( $bear, qr/pub fn send_block/, 'a block can be sent to an address' );
like( $bear, qr/master_sample:\s*u64/, 'the header carries the first frame master position' );

# The tag must be the same construction the clock session uses, or the two
# halves of P3 authenticate differently. Both cover the whole header.
like( $bear, qr/mac\.update\(&header\.encode\(\)\)/, 'the bearer tags the whole header' );
like( $peer, qr/mac\.update\(&header\.encode\(\)\)/, 'the clock session tags the whole header' );
like( $bear, qr/This must stay byte-for-byte identical to `peer::mac_tag`/,
	'the copy says it must stay identical to the clock tag' );
like( $bear, qr/fn tags_match/, 'the tag is compared without early exit' );

# --- the receiver -----------------------------------------------------------
like( $bear, qr/pub struct AudioReceiver/, 'the receiving half is a named type' );
like( $bear, qr/pub fn accept\(/, 'a received datagram is authenticated and placed' );
like( $bear, qr/pub fn pull\(/, 'contiguous audio is pulled in master order' );
like( $bear, qr/DEFAULT_JITTER_FRAMES/, 'the jitter window has one bound' );
like( $bear, qr/FLAG_DISCONTINUITY/, 'a concealed gap is marked, not hidden' );
like( $bear, qr/concealed_frames/, 'concealed frames are counted' );

# --- the converter ----------------------------------------------------------
like( $bear, qr/pub struct LinearResampler/, 'the converter is a named type' );
like( $bear, qr/pub fn process\(/, 'the converter produces master-time samples' );
like( $bear, qr/local_per_master/, 'the converter carries its rate' );
like( $bear, qr/ClockOffset/, 'the converter is driven by the fitted clock' );

# --- the tests the module ships ---------------------------------------------
like( $tests, qr/fn a_datagram_round_trips_and_a_wrong_key_or_foreign_session_is_refused/, 'the tag and the session are tested' );
like( $tests, qr/fn out_of_order_and_duplicate_delivery_produce_contiguous_audio/, 'reordering is tested' );
like( $tests, qr/fn a_lost_packet_becomes_silence_and_a_discontinuity_without_shifting/, 'loss is tested' );
like( $tests, qr/fn a_hundred_ppm_fast_peer_clock_resamples_to_the_master_rate/, 'the drift compensation is tested' );
like( $tests, qr/fn two_engines_carry_a_block_over_loopback_udp/, 'two real sockets carry a block' );

done_testing();
