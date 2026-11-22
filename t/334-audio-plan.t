# tests-for: lib/JawnOS/Audio/Plan.pm engine/src/session.rs
# covers:    the saved audio plan (docs/studio-audio-roadmap.md §7): a default plan validates, the
#            read path drops what cannot exist and clamps gain/pan, a bus send chain survives while a
#            cycle is refused, and the declared latency adds up along a path.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use JawnOS::Audio::Plan;

# The module is deliberately plain Perl (no exporter): the UI, the manager and
# the tests all say its full name, which is also what a reader greps for.
sub normalize { return JawnOS::Audio::Plan::audio_plan_normalize(@_) }
sub valid     { return JawnOS::Audio::Plan::audio_plan_valid(@_) }
sub latency   { return JawnOS::Audio::Plan::audio_plan_latency(@_) }

# A source and a sink with the minimum facts a plan needs.
sub source {
	my ($id, %rest) = @_;
	return { id => $id, label => $id, kind => 'input', rate => 48_000, channels => 1, latency_ms => 0, %rest };
}

sub sink {
	my ($id, %rest) = @_;
	return { id => $id, label => $id, kind => 'interface', rate => 48_000, channels => 2, latency_ms => 0, %rest };
}

sub route {
	my ($from, $to, %rest) = @_;
	return { from => $from, to => $to, gain => 1, pan => 0, mute => 0, delay_ms => 0, %rest };
}

# --- the default -------------------------------------------------------------
{
	my $plan = JawnOS::Audio::Plan::audio_plan_default();
	ok( valid($plan), 'the empty plan is valid' );
	is_deeply(
		$plan,
		{ sources => [], buses => [], sinks => [], routes => [] },
		'and it is four empty lists, so "nothing routed" has a shape'
	);
}

# --- the device channel a node binds to --------------------------------------
{
	# A plan written before the engine could bind a node meant channel 0; the
	# read path keeps that meaning and the write path accepts a whole, non-
	# negative index.
	my $old = normalize({
		sources => [ source('gtr') ],
		buses   => [],
		sinks   => [ sink('um2') ],
		routes  => [],
	});
	is($old->{sources}[0]{channel}, 0, 'a node with no channel is channel 0');
	is($old->{sinks}[0]{channel}, 0, 'and so is a sink');

	my $given = normalize({
		sources => [ source('gtr', channel => 1) ],
		buses   => [],
		sinks   => [ sink('um2', channel => 2) ],
		routes  => [],
	});
	is($given->{sources}[0]{channel}, 1, 'a source keeps its channel');
	is($given->{sinks}[0]{channel}, 2, 'a sink keeps its channel');

	ok( valid({ sources => [ source('gtr', channel => 1) ], buses => [], sinks => [], routes => [] }),
		'a whole, non-negative channel is valid');
	ok( !valid({ sources => [ source('gtr', channel => -1) ], buses => [], sinks => [], routes => [] }),
		'a negative channel is refused');
	ok( !valid({ sources => [ source('gtr', channel => 1.5) ], buses => [], sinks => [], routes => [] }),
		'a fractional channel is refused');
}

# --- a node's machine is optional --------------------------------------------
{
	my $plain = normalize({
		sources => [ source('gtr') ],
		buses   => [],
		sinks   => [ sink('um2') ],
		routes  => [],
	});
	is($plain->{sources}[0]{machine}, '', 'a node with no machine is this machine');
	is($plain->{sinks}[0]{machine}, '', 'and so is a sink');

	my $given = normalize({
		sources => [ source('gtr', machine => 'table') ],
		buses   => [],
		sinks   => [ sink('um2', machine => 'laptop') ],
		routes  => [],
	});
	is($given->{sources}[0]{machine}, 'table', 'a source keeps its machine');
	is($given->{sinks}[0]{machine}, 'laptop', 'a sink keeps its machine');

	ok( valid({ sources => [ source('gtr', machine => 'table') ], buses => [], sinks => [], routes => [] }),
		'a text machine is valid');
	ok( !valid({ sources => [ source('gtr', machine => { name => 'table' }) ], buses => [], sinks => [], routes => [] }),
		'a machine that is a ref is refused');
}

# --- a route's mute is a fact, not a word --------------------------------
{
	ok( valid({ sources => [ source('gtr') ], buses => [], sinks => [ sink('um2') ],
		routes => [ route('gtr', 'um2', mute => 1) ] }),
		'a numeric mute of 1 is valid');
	ok( valid({ sources => [ source('gtr') ], buses => [], sinks => [ sink('um2') ],
		routes => [ route('gtr', 'um2', mute => 0) ] }),
		'a numeric mute of 0 is valid');
	ok( !valid({ sources => [ source('gtr') ], buses => [], sinks => [ sink('um2') ],
		routes => [ route('gtr', 'um2', mute => 'yes') ] }),
		'a mute that is a word is refused, because the engine cannot run it');
}

# --- the write path refuses what the read path would repair ------------------
{
	my $raw = {
		sources => [ source('gtr', latency_ms => 2) ],
		buses   => [],
		sinks   => [ sink('um2', latency_ms => 1) ],
		routes  => [
			route('gtr', 'um2', gain => 0.8),
			route('gtr', 'ghost'),
		],
	};

	my $clean = normalize($raw);
	is( scalar @{ $clean->{routes} }, 1, 'a route to a sink that does not exist is dropped' );
	is( $clean->{routes}[0]{to}, 'um2', 'the remaining route is the one whose endpoints exist' );
	ok( !valid($raw), 'the raw plan with the dangling route is invalid for the write path' );
	ok( valid($clean), 'and the normalised plan is valid' );
}

# --- gain and pan ------------------------------------------------------------
{
	my $raw = {
		sources => [ source('gtr') ],
		buses   => [ { id => 'house' }, { id => 'monitor' } ],
		sinks   => [],
		routes  => [
			route('gtr', 'house',   gain => 5,   pan => -7),
			route('gtr', 'monitor', gain => -2,  pan => 9),
			route('gtr', 'house',   gain => 0.5, pan => 0.5),
		],
	};

	my $clean = normalize($raw);
	is( $clean->{routes}[0]{gain}, 1, 'gain above 1 is clamped to 1' );
	is( $clean->{routes}[0]{pan},  -1, 'pan below -1 is clamped to -1' );
	is( $clean->{routes}[1]{gain}, 0, 'gain below 0 is clamped to 0' );
	is( $clean->{routes}[1]{pan},  1, 'pan above 1 is clamped to 1' );
	is( $clean->{routes}[2]{gain}, 0.5, 'an in-range gain is left alone' );
	is( $clean->{routes}[2]{pan},  0.5, 'an in-range pan is left alone' );

	$raw->{routes}[0]{gain} = 5;
	ok( !valid($raw), 'the write path refuses an out-of-range gain instead of clamping it' );

	$raw->{routes}[0]{gain} = 0.5;
	$raw->{routes}[0]{pan}  = -7;
	ok( !valid($raw), 'and refuses an out-of-range pan' );
}

# --- a bus may feed a bus ----------------------------------------------------
{
	my $raw = {
		sources => [ source('gtr') ],
		buses   => [ { id => 'house' }, { id => 'monitor' } ],
		sinks   => [ sink('um2') ],
		routes  => [
			route('gtr', 'house'),
			route('house', 'monitor'),
			route('monitor', 'um2'),
		],
	};

	my $clean = normalize($raw);
	is( scalar @{ $clean->{routes} }, 3, 'a source -> bus -> bus -> sink chain is kept whole' );
	ok( valid($raw), 'and it is valid' );
}

# --- a loop is not a plan ----------------------------------------------------
{
	my $raw = {
		sources => [ source('gtr') ],
		buses   => [ { id => 'house' }, { id => 'monitor' } ],
		sinks   => [ sink('um2') ],
		routes  => [
			route('gtr', 'house'),
			route('house', 'monitor'),
			route('monitor', 'house'),    # closes the loop
			route('monitor', 'um2'),
		],
	};

	my $clean = normalize($raw);
	my @bus_routes = grep { $_->{from} eq 'monitor' && $_->{to} eq 'house' } @{ $clean->{routes} };
	is( scalar @bus_routes, 0, 'the route that closes a bus -> bus loop is dropped' );
	is( scalar @{ $clean->{routes} }, 3, 'the acyclic part of the plan survives' );
	ok( !valid($raw), 'and the looping plan is invalid for the write path' );

	my $self = {
		sources => [ source('gtr') ],
		buses   => [ { id => 'house' } ],
		sinks   => [],
		routes  => [ route('gtr', 'house'), route('house', 'house') ],
	};
	is(
		scalar @{ normalize($self)->{routes} },
		1,
		'a bus routed to itself is the shortest loop and is dropped too'
	);
}

# --- a loop is a loop, whatever it runs through ------------------------------
# The roadmap calls out bus -> bus because sends are where a loop is easiest to
# draw, but the latency walk follows every edge: a loop through two sinks has
# to be refused as well or the walk never returns.
{
	my $raw = {
		sources => [],
		buses   => [],
		sinks   => [ sink('left'), sink('right') ],
		routes  => [ route('left', 'right'), route('right', 'left') ],
	};

	my $clean = normalize($raw);
	is( scalar @{ $clean->{routes} }, 1, 'a loop through non-bus endpoints is refused too' );
	ok( !valid($raw), 'and it is invalid for the write path' );
}

# --- the send-depth limit ----------------------------------------------------
{
	my $limit = $JawnOS::Audio::Plan::audio_plan_max_send_depth;
	my @buses = map { { id => "b$_" } } 0 .. $limit + 1;
	my @routes;
	push @routes, route( 'gtr', 'b0' );
	push @routes, map { route( "b$_", 'b' . ( $_ + 1 ) ) } 0 .. $limit;
	my $raw = {
		sources => [ source('gtr') ],
		buses   => \@buses,
		sinks   => [],
		routes  => \@routes,
	};

	my $clean = normalize($raw);
	my $kept = grep { $_->{from} =~ /^b\d+$/ && $_->{to} =~ /^b\d+$/ } @{ $clean->{routes} };
	is( $kept, $limit, "at most $limit consecutive sends are kept" );
	is( $raw->{routes}[-1]{to}, 'b' . ( $limit + 1 ), 'the chain in the fixture is longer than the limit' );
	ok( !valid($raw), 'a chain past the limit is invalid for the write path' );
}

# --- kinds and ids -----------------------------------------------------------
{
	my $raw = {
		sources => [
			source('gtr'),
			source('magic', kind => 'conjuring'),
			source('gtr'),    # the same id twice
		],
		buses   => [ { id => 'gtr' }, { id => 'house' } ],
		sinks   => [ sink('um2') ],
		routes  => [ route('magic', 'house'), route('gtr', 'house') ],
	};

	my $clean = normalize($raw);
	is( scalar @{ $clean->{sources} }, 1, 'an unknown source kind and a duplicate id are dropped' );
	is( $clean->{sources}[0]{id}, 'gtr', 'the first declaration of an id is the one kept' );
	is( scalar @{ $clean->{buses} }, 1, 'an id may name only one thing, so the duplicate bus is dropped' );
	is( scalar @{ $clean->{routes} }, 1, 'a route that names a dropped node is dropped' );
	ok( !valid($raw), 'and the raw plan is invalid' );
}

# --- a local input may name its capture node ---------------------------------
# Without a node every routed input takes the machine's default source, so a
# laptop with a built-in mic and a UM2 cannot say which one a take means. The
# value is a PipeWire/Pulse source name, never a path, and a name that begins
# with `-` would be read by `parec` as an option.
{
	my $node = 'alsa_input.usb-BEHRINGER_UMC202HD-00.analog-stereo';
	my $named = normalize({
		sources => [ source('mic', node => $node) ],
		buses   => [],
		sinks   => [ sink('out') ],
		routes  => [],
	});
	is($named->{sources}[0]{node}, $node, 'an input keeps the node it names');

	my $plain = normalize({
		sources => [ source('mic') ],
		buses   => [],
		sinks   => [],
		routes  => [],
	});
	is($plain->{sources}[0]{node}, '', 'an input with no node reads as the machine default');

	ok(valid({ sources => [ source('mic', node => $node) ], buses => [], sinks => [], routes => [] }),
		'a PipeWire source name is valid');
	ok(!valid({ sources => [ source('mic', node => '-device') ], buses => [], sinks => [], routes => [] }),
		'a name that begins with - is refused, because parec would read it as an option');
	ok(!valid({ sources => [ source('mic', node => '/dev/snd/by-id/mic') ], buses => [], sinks => [], routes => [] }),
		'a path is not a node');
	ok(!valid({ sources => [ source('mic', node => 'a b') ], buses => [], sinks => [], routes => [] }),
		'a name with a space is refused');
	ok(!valid({ sources => [ source('mic', node => { name => $node }) ], buses => [], sinks => [], routes => [] }),
		'a node that is a ref is refused');

	# The read path drops a name the engine must never receive, so a hand-edited
	# setting cannot turn into a command option; the write path refuses it.
	my $bad = normalize({
		sources => [ source('mic', node => '-device') ],
		buses   => [],
		sinks   => [],
		routes  => [],
	});
	is($bad->{sources}[0]{node}, '', 'the read path drops a name the engine would read as an option');

	# Only an `input` captures from a node: a `device` source is the system mix
	# and a `handset` is the call monitor.
	my $sink = normalize({
		sources => [ source('system', kind => 'device', node => $node) ],
		buses   => [],
		sinks   => [ sink('out', node => $node) ],
		routes  => [],
	});
	is($sink->{sources}[0]{node}, '', 'a device source has no node of its own');
	is($sink->{sinks}[0]{node}, '', 'and a sink keeps none');
	ok(!valid({ sources => [], buses => [], sinks => [ sink('out', node => $node) ], routes => [] }),
		'a node on a sink is refused on save');
}

# --- declared latency --------------------------------------------------------
{
	my $raw = {
		sources => [
			source('gtr', latency_ms => 2),
			source('vox', latency_ms => 10),
		],
		buses  => [ { id => 'house' } ],
		sinks  => [ sink('um2', latency_ms => 5) ],
		routes => [
			route('gtr', 'house', delay_ms => 3),
			route('vox', 'house', delay_ms => 0),
			route('house', 'um2', delay_ms => 4),
		],
	};

	is( latency($raw, 'um2'), 19, 'the latest input plus the send delay plus the sink is the zone delay' );
	is( latency($raw, 'nowhere'), 0, 'a sink that does not exist has no latency' );

	my $chain = {
		sources => [ source('gtr', latency_ms => 2) ],
		buses   => [ { id => 'house' }, { id => 'monitor' } ],
		sinks   => [ sink('zone', latency_ms => 5) ],
		routes  => [
			route('gtr', 'house', delay_ms => 3),
			route('house', 'monitor', delay_ms => 4),
			route('monitor', 'zone', delay_ms => 5),
		],
	};
	is( latency($chain, 'zone'), 19, 'a send chain adds each declared delay once' );

	# A peer's declaration is placed by the engine, so it carries the engine's
	# bound. A local input's declaration is kept but not placed, so only the
	# non-negative rule applies to it.
	my $peer_plan = sub {
		my ($kind, $latency) = @_;
		return {
			sources => [ source('x', kind => $kind, latency_ms => $latency) ],
			buses   => [],
			sinks   => [],
			routes  => [],
		};
	};
	ok( valid($peer_plan->('peer', 2_000)), 'a peer latency at the 2000 ms bound is valid' );
	ok( !valid($peer_plan->('peer', 2_001)), 'a peer latency above the bound is refused on save' );
	ok( !valid($peer_plan->('peer', -1)), 'and the non-negative rule still refuses a negative one' );
	ok( valid($peer_plan->('input', 2_001)),
		'a local input keeps the non-negative range above the peer bound' );
	is( normalize($peer_plan->('peer', 5_000))->{sources}[0]{latency_ms}, 2_000,
		'the read path clamps a peer declaration to the engine bound' );
	is( normalize($peer_plan->('input', 5_000))->{sources}[0]{latency_ms}, 5_000,
		'while a local input declaration is not clamped' );
}

# --- which machine a node belongs to -----------------------------------------
# A blank `machine` is this machine's older spelling; a named one is local only
# when it is this host, compared without regard to case. The input picker, the
# write path and SystemMix's mode check all ask this one question.
{
	is(JawnOS::Audio::Plan::audio_plan_on_this_machine('', 'table'), 1,
		'a blank machine is this machine');
	is(JawnOS::Audio::Plan::audio_plan_on_this_machine('table', 'table'), 1,
		'the hostname names this machine');
	is(JawnOS::Audio::Plan::audio_plan_on_this_machine('TABLE', 'table'), 1,
		'and the comparison folds case');
	is(JawnOS::Audio::Plan::audio_plan_on_this_machine('elsewhere', 'table'), 0,
		'another machine is not this one');
	is(JawnOS::Audio::Plan::audio_plan_on_this_machine(undef, 'table'), 1,
		'a missing field is a blank one');
	is(JawnOS::Audio::Plan::audio_plan_on_this_machine('table', ''), 0,
		'without a host, only a blank machine is local');
}

done_testing();
