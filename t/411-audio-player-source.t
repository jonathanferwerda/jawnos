# tests-for: engine/src/patchbay.rs lib/JawnOS/Audio/Plan.pm
# covers:    a `player` source (docs/studio-audio-roadmap.md P5): a Studio app's
#            own PCM, carried to the engine by this machine's local audio input
#            instead of the uplink. It is declared by the plan now and ships
#            inert: a compiled player is `pending`, not `silent`, and costs no
#            ring until the reader is wired. The plan writes its `lead_ms` (how
#            far ahead of arrival the first frame is anchored) and `buffer_ms`
#            (how far behind the clock it is read), both with the peer sanity
#            bound. The block mixes a player as interleaved stereo through two
#            independent insert chains, exactly as it mixes a `device` source,
#            so a centred route keeps the app's stereo image.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

use lib "$FindBin::Bin/../lib";
use JawnOS::Audio::Plan;

my $root  = abs_path("$FindBin::Bin/..");
my $patch = read_file("$root/engine/src/patchbay.rs");

ok( length $patch, 'the patchbay is found' );

# --- the patchbay binds a player like a peer --------------------------------
like( $patch, qr/fn wants_player\(&self\)/, 'a player source has one ring question' );
like( $patch, qr/player:\s*bool/, 'a source records that it is a player' );
like( $patch, qr/lead_ms:\s*f64/, 'a source carries its declared lead' );
like( $patch, qr/pub player:\s*&'static str/, 'the plan reports the player state' );
like( $patch, qr/summary\.player\s*=\s*"capturing"/, 'attaching the ring moves it out of pending' );
like( $patch, qr/fn source_feeds/, 'one question decides whether a source can feed a route' );
like( $patch, qr/player_blocks/, 'a player is popped into a block of its own, not an interface channel' );
like( $patch, qr/fn attach_player/, 'the local audio input attaches a ring by source index' );
like( $patch, qr/fn player_lead_ms/, 'a player source may declare its lead' );
like( $patch, qr/PLAYER_LEAD_MAX_MS/, 'the lead has a stated upper bound' );
like( $patch, qr/fn player_buffer_ms/, 'a player source may declare its own read buffer' );
like( $patch, qr/PLAYER_BUFFER_MAX_MS/, 'the buffer has a stated upper bound too' );
like( $patch, qr/fn a_player_source_is_pending_not_silent/, 'the pending state is tested' );
like( $patch, qr/fn a_player_on_another_machine_is_silent/, 'a player elsewhere is silent' );
like( $patch, qr/fn a_player_lead_outside_the_bounds_is_refused/, 'a bad lead is refused by name' );
like( $patch, qr/fn a_player_ring_mixes_stereo_like_a_parec_input/, 'a player mixes as stereo' );
like( $patch, qr/source\.chains\.split_at_mut\(1\)/, 'its two sides run independent insert chains' );

# --- the plan writes a player's placement ----------------------------------
sub player_plan {
	my (%facts) = @_;
	my %source = (id => 'synth', label => 'synth', kind => 'player', rate => 48_000, channels => 2);
	for my $key (qw(lead_ms buffer_ms)) {
		$source{$key} = $facts{$key} if defined $facts{$key};
	}
	return {
		sources => [ \%source ],
		buses   => [],
		sinks   => [],
		routes  => [],
	};
}

{
	my $normal = JawnOS::Audio::Plan::audio_plan_normalize(player_plan());
	is( $normal->{sources}[0]{lead_ms}, 100,
		'a player that declares no lead is written with the small default' );
	is( $normal->{sources}[0]{buffer_ms}, 85,
		'and takes the one-window read buffer a peer starts with' );

	my $declared = JawnOS::Audio::Plan::audio_plan_normalize(
		player_plan(lead_ms => 150, buffer_ms => 200)
	);
	is( $declared->{sources}[0]{lead_ms}, 150, 'a declared lead inside the bound is kept' );
	is( $declared->{sources}[0]{buffer_ms}, 200, 'a declared buffer inside the bound is kept' );

	is( JawnOS::Audio::Plan::audio_plan_normalize(player_plan(lead_ms => 5_000))->{sources}[0]{lead_ms},
		2_000, 'the read path clamps a lead past the engine bound' );

	ok( JawnOS::Audio::Plan::audio_plan_valid(player_plan(lead_ms => 2_000)),
		'a lead at the bound is valid' );
	ok( !JawnOS::Audio::Plan::audio_plan_valid(player_plan(lead_ms => 2_001)),
		'a lead above the bound is refused on save' );
	ok( !JawnOS::Audio::Plan::audio_plan_valid(player_plan(lead_ms => -1)),
		'and a negative lead is refused' );
	ok( JawnOS::Audio::Plan::audio_plan_valid(player_plan(buffer_ms => 2_000)),
		'a player buffer at the bound is valid' );
	ok( !JawnOS::Audio::Plan::audio_plan_valid(player_plan(buffer_ms => 2_001)),
		'a player buffer above the bound is refused on save' );

	# A lead on an older kind is not placed by this engine, so it is dropped
	# by the read path rather than carried as a promise.
	my $input = player_plan(lead_ms => 150);
	$input->{sources}[0]{kind} = 'input';
	ok( !exists JawnOS::Audio::Plan::audio_plan_normalize($input)->{sources}[0]{lead_ms},
		'only a player carries a lead' );
}

done_testing();
