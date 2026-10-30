use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# `subs::remote_upgrade_marker_state` is the one place this machine's pull
# marker is interpreted (the reconnector, the Upgrade route, remote_upgrade and
# the negotiator all read it through subs::remote_upgrade_lock_state).
#
# Regression: Mojo::IOLoop::subprocess forks on the *next* tick, so the caller
# writes `running:claim` before any child exists. That claim used to carry the
# caller's pid; if the fork never happened (a restart took the tick, a failed
# fork) the marker looked like a live pull for the full thirty-minute bound and
# blocked every automatic sync - the reason Upgrade had to be pressed by hand.
# A claim must hold only briefly, while a live pid keeps the long bound.

my $now = JawnOSTest::ts(2026, 10, 30, 12, 0, 0);

sub state {
	my ($value, $age_ms, $alive) = @_;
	return subs::remote_upgrade_marker_state($value, $now - ($age_ms || 0), $now, $alive);
}

is(state('', 0, 0)->{'flag'}, '', 'an empty marker is idle');
ok(!state('', 0, 0)->{'busy'}, 'an empty marker does not hold the pull');

is(state('inactive', 0, 0)->{'flag'}, 'inactive', 'the panel clear value is kept');
ok(!state('inactive', 0, 0)->{'busy'}, 'inactive does not hold the pull');

my $claim = state('running:claim', 0, 0);
is($claim->{'flag'}, 'running', 'a claim keeps the running flag');
is($claim->{'claim'}, 1, 'a claim is recognised');
ok(!$claim->{'live'}, 'a claim is not a live owner');
is($claim->{'bound'}, 120000, 'a claim expires in two minutes');
ok($claim->{'busy'}, 'a fresh claim holds the pull');

ok(state('running:claim', 119000, 0)->{'busy'}, 'a claim is still held just inside its bound');
ok(!state('running:claim', 121000, 0)->{'busy'}, 'a claim whose fork never ran stops blocking after two minutes');

my $live = state('running:4242', 0, 1);
ok($live->{'live'}, 'a numeric pid with kill 0 is a live owner');
is($live->{'bound'}, 1800000, 'a live owner keeps the long bound');
ok($live->{'busy'}, 'a live owner holds the pull');
ok(state('running:4242', 29 * 60 * 1000, 1)->{'busy'}, 'a live owner still holds just inside thirty minutes');
ok(!state('running:4242', 31 * 60 * 1000, 1)->{'busy'}, 'a live owner that is far too old stops blocking');

my $dead = state('running:4242', 0, 0);
ok(!$dead->{'live'}, 'a pid that is gone is not a live owner');
ok(!$dead->{'busy'}, 'a dead owner does not hold the pull');

my $legacy = state('running', 0, 0);
is($legacy->{'claim'}, 1, 'a bare running marker from an older build is a claim');
ok($legacy->{'busy'}, 'a fresh bare running marker holds the pull');
ok(!state('running', 11 * 60 * 1000, 0)->{'busy'}, 'a stale bare running marker stops blocking');

my $odd = state('running:claim:7', 0, 0);
is($odd->{'claim'}, 1, 'a claim with a trailing field is still a claim');
ok($odd->{'busy'}, 'an odd claim value is still bounded');

done_testing();
