# tests-for: lib/JawnOS/Domain/File.pm
# covers:    spent cache claims are pruned on a write, at most once per ten minutes, so the
#            nonce index cannot grow without bound.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

# The domain layer is lazy: load the real definition before the local stub below.
subs::preload('cache_expire_stale');

my $NOW = 1_700_000_000_000;
my @calls;

{
	no warnings 'once';
	local $subs::cache_pruned_at;
	local *subs::rightNow = sub { $NOW };
	local *subs::db_query = sub {
		my ($sql, @params) = @_;
		push @calls, [ $sql, @params ];
		return 1;
	};

	# The first write of a fresh worker does the sweep.
	is(&subs::cache_expire_stale($NOW), 1, 'the first call prunes');
	is(scalar(@calls), 5, 'the minute-lived contexts are swept');
	my %contexts = map { $_->[1] => $_->[2] } @calls;
	is_deeply([ sort keys %contexts ], [ qw(app_challenge button_press command_applied padlock_challenge peer_nonce) ],
		'the sweep names the nonce, challenge, command and press contexts');
	is($contexts{'peer_nonce'}, $NOW - 15 * 60 * 1000,
		'a row must be a quarter of an hour old before it goes: the verifier already refuses after ten');
	like($calls[0]->[0], qr/delete from cache where context = \? and server_time < \?/,
		'the sweep is one bounded delete per context');

	# A write a second later must not pay the sweep again.
	@calls = ();
	is(&subs::cache_expire_stale($NOW + 1000), 0, 'a second call inside ten minutes does nothing');
	is(scalar(@calls), 0, 'and runs no query at all');

	# Once the window has passed it runs again.
	is(&subs::cache_expire_stale($NOW + 600_001), 1, 'the sweep runs again after ten minutes');
	is(scalar(@calls), 5, 'and issues the deletes again');
}

done_testing();
