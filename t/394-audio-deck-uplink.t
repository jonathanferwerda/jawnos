# tests-for: lib/JawnOS/Domain/Audio.pm lib/JawnOS/Manager/Part35.pm
# covers:    the T-Deck's live audio handoff (docs/studio-audio-roadmap.md P4):
#            Now Me tells a deck the uplink to dial, the stream index it claims
#            and the session key it signs with. The selection is the peer source
#            on this machine that names the deck, or the only peer when there is
#            one; a bind-all saved address becomes the machine the deck already
#            reaches; an off uplink, no local peer, or an ambiguous peer hands
#            the deck empty fields so a stale address is cleared.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

require JawnOS::Domain::Audio;

# The selection is pure, so the suite drives it without a database: the saved
# address, the key and the plan are arguments, exactly as the Now Me wrapper
# reads them.
sub choose { return &subs::_audio_uplink_choose(@_) }

sub source {
	my ($id, %rest) = @_;
	return {
		id         => $id,
		label      => $id,
		kind       => 'peer',
		machine    => '',
		rate       => 16_000,
		channels   => 1,
		latency_ms => 0,
		%rest,
	};
}

sub plan {
	my (@sources) = @_;
	my @routes = map {
		{ from => $_->{id}, to => 'house', gain => 1, pan => 0, mute => 0, delay_ms => 0 }
	} grep { ref $_ eq 'HASH' && (($_->{kind} // '') eq 'peer') } @sources;
	return { sources => [@sources], buses => [{ id => 'house', label => 'house' }], sinks => [], routes => \@routes };
}

my $key = 'ab' x 32;

# --- the uplink is off --------------------------------------------------------
{
	is_deeply( choose( plan(source('deck')), '', $key, '10.0.0.5', 'chip', 'Deck' ), {},
		'an off uplink hands the deck nothing' );
}

# --- a peer source may run on another machine ---------------------------------
{
	my $elsewhere = plan(source('deck', machine => 'some-other-machine'));
	my $got = choose( $elsewhere, '0.0.0.0:7060', $key, '10.0.0.5', 'chip', 'Deck' );
	is( $got->{address}, '10.0.0.5:7060',
		'a mixer not in the House list falls back to the machine the deck reaches' );
	is( $got->{stream}, 0, 'and the deck still claims the peer source' );
	is_deeply( choose( plan(), '0.0.0.0:7060', $key, '10.0.0.5', 'chip', 'Deck' ), {},
		'a plan with no peer source has no stream to claim' );
}

# --- a bind-all address becomes the machine the deck reaches ------------------
{
	my $got = choose( plan(source('deck')), '0.0.0.0:7060', $key, '10.0.0.5', 'chip', 'Deck' );
	is( $got->{address}, '10.0.0.5:7060', 'the bind-all host is replaced by the House address' );
	is( $got->{stream}, 0, 'the stream is the peer source\'s plan index' );
	is( $got->{key}, $key, 'the deck gets the session key' );
	is( $got->{latency_ms}, 0, 'no declaration means no shift' );
}

# --- an explicit saved host is kept ------------------------------------------
{
	my $got = choose( plan(source('deck')), '192.168.1.9:7061', $key, '10.0.0.5', 'chip', 'Deck' );
	is( $got->{address}, '192.168.1.9:7061', 'a saved host is the address the deck dials' );
}

# --- an unrouted peer has nothing for the deck to feed -----------------------
{
	my $unrouted = {
		sources => [ source('deck') ],
		buses   => [{ id => 'house', label => 'house' }],
		sinks   => [],
		routes  => [],
	};
	is_deeply( choose( $unrouted, '0.0.0.0:7060', $key, '10.0.0.5', 'chip', 'Deck' ), {},
		'an unrouted peer source gets no stream handoff' );
}

# --- the index is the plan's, not the peer count ------------------------------
{
	my $plan = plan(
		{ id => 'gtr', label => 'gtr', kind => 'input', machine => '', rate => 48_000, channels => 1 },
		source('deck'),
	);
	my $got = choose( $plan, '0.0.0.0:7060', $key, '10.0.0.5', 'chip', 'Deck' );
	is( $got->{stream}, 1, 'a peer after an input keeps its plan index' );
}

# --- a source naming the deck wins over order --------------------------------
{
	my $plan = plan( source('left'), source('deck-abc', latency_ms => 30) );
	my $got = choose( $plan, '0.0.0.0:7060', $key, '10.0.0.5', 'abc', 'Some Deck' );
	ok( $got->{address}, 'a source whose id names the deck is selected' );
	is( $got->{stream}, 1, 'even when it is not the first peer' );
	is( $got->{latency_ms}, 30, 'its declared latency travels with the handoff' );
}

# --- two unnamed peers are ambiguous -----------------------------------------
{
	my $plan = plan( source('left'), source('right') );
	is_deeply( choose( $plan, '0.0.0.0:7060', $key, '10.0.0.5', 'chip', 'Deck' ), {},
		'two peers, neither naming the deck, is ambiguous and delivers nothing' );
}

# --- the mixer's machine, not necessarily the deck's homebase ---------------
{
	my $plan = plan( source('deck', machine => 'table') );
	my @machines = (
		{ name => 'Laptop', computer => 'house@laptop', ip => '10.0.0.5' },
		{ name => 'table',  computer => 'house@table',  ip => '10.0.0.9' },
	);
	my $got = choose( $plan, '0.0.0.0:7060', $key, '10.0.0.5', 'chip', 'Deck', \@machines );
	is( $got->{address}, '10.0.0.9:7060',
		'a bind-all uplink points at the machine the peer source runs on' );
}

# --- the address shape -------------------------------------------------------
{
	my ($host, $port) = &subs::_audio_uplink_split('127.0.0.1:7060');
	is( $host, '127.0.0.1', 'an IPv4 host splits from its port' );
	is( $port, 7060, 'and the port is a number' );
	($host, $port) = &subs::_audio_uplink_split('[::1]:7060');
	is( $host, '[::1]', 'a bracketed IPv6 host splits at the bracket' );
	is( $port, 7060, 'with its port' );
	is_deeply( [ &subs::_audio_uplink_split('not-an-address') ], [],
		'a value that is not host:port splits to nothing' );
}

done_testing();
