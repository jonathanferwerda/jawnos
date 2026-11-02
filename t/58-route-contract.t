# tests-for: lib/JawnOS/Controller/ lib/JawnOS/Domain/Crest.pm lib/JawnOS/Routes.pm qa/lib/ qa/routes.policy.json
# covers:    The route table is the app's whole private surface: 796 paths, one action each, registered in a fixed order.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../qa/lib", "$FindBin::Bin/../lib", "t/lib", "qa/lib", "lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use Probe;

# The route table is the app's whole private surface: 796 paths, one action
# each, registered in a fixed order. The QA suite drives them over HTTP, so a
# route that has no action, no module entry, or a tier the suite disagrees with
# is a test failure here rather than a surprise there.
#
# Probe::tier_needed mirrors subs::tier_needed so the route layer can classify
# without booting the app. The parity check below is what keeps the mirror
# honest.

my $repo   = root();
my $routes = Probe::routes($repo);

ok(scalar(@$routes) >= 700, 'the route table is large enough to be interesting')
	or diag('found ' . scalar(@$routes) . ' routes');

# --- every route has a handler -------------------------------------------------
my %text;
my %missing;
for my $r (@$routes) {
	my $file = "$repo/lib/JawnOS/Controller/$r->{'module'}.pm";
	$text{$r->{'module'}} //= do {
		-f $file ? read_file($file) : '';
	};
	$missing{"$r->{'module'} $r->{'action'}"}++
		unless $text{$r->{'module'}} =~ /\bsub\s+\Q$r->{'action'}\E\b/;
}
is(scalar(keys %missing), 0, 'every route action exists in its controller')
	or diag('missing: ' . join(', ', (sort keys %missing)[0 .. 4]));

# --- every route module is registered -----------------------------------------
no warnings q{once};
require "$repo/lib/JawnOS/Routes.pm";
my %named = map { $_ => 1 } @JawnOS::Routes::NAMES;
my %present = map { $_->{'module'} => 1 } @$routes;
my @unnamed = grep { !$named{$_} } sort keys %present;
my @empty   = grep { !$present{$_} } sort keys %named;
is(scalar(@unnamed), 0, 'every route module appears in @NAMES') or diag("@unnamed");
is(scalar(@empty),   0, 'every @NAMES entry has routes')         or diag("@empty");

# --- no duplicate method + path ------------------------------------------------
my %seen;
my @dupes;
for my $r (@$routes) {
	my $key = lc($r->{'method'}) . ' ' . $r->{'path'};
	push @dupes, $key if $seen{$key}++;
}
TODO: {
	local $TODO = 'duplicate registrations found 2026-11-01: manager_misc12:41744 vs :41867 '
		. '(POST /manager/clothesline), manager_mail:31319 vs :31328 '
		. '(POST /manager/mail/email/server/delete) - the later handler can never run';
	is(scalar(@dupes), 0, 'no route is registered twice') or diag("@dupes");
}

# --- every path is absolute ----------------------------------------------------
my @relative = grep { ($_->{'path'} // '') !~ m{^/} } @$routes;
TODO: {
	local $TODO = 'Root_misc:47831 registers "manager/ws/remote_control" without a leading '
		. 'slash, so it is not the path it reads as';
	is(scalar(@relative), 0, 'every route path is absolute')
		or diag(join(', ', map { "$_->{module}:$_->{line} $_->{path}" } @relative));
}

# --- the tier mirror matches the app ------------------------------------------
my @drift;
for my $r (@$routes) {
	my $app  = subs::tier_needed($r->{'path'});
	my $mirror = Probe::tier_needed($r->{'path'});
	push @drift, "$r->{'path'} ($mirror vs $app)" if $mirror ne $app;
}
is(scalar(@drift), 0, 'Probe::tier_needed matches subs::tier_needed for every route')
	or diag('drift: ' . join(', ', @drift[0 .. 4]));

# --- the suite's policy parses and covers the classes it claims ----------------
my $policy = Probe::load_policy("$FindBin::Bin/../qa/routes.policy.json");
ok(ref $policy->{'skip'} eq 'ARRAY' && @{ $policy->{'skip'} }, 'route policy loaded');
ok(defined $policy->{'tier_exempt'} && length $policy->{'tier_exempt'}, 'tier exemptions are named');

# A POST is never requested in this layer; a known read always is.
my ($skip_post) = Probe::classify($policy, { method => 'post', path => '/manager/say_it' });
my ($skip_read) = Probe::classify($policy, { method => 'get',  path => '/manager/health' });
my ($skip_arg)  = Probe::classify($policy, { method => 'get',  path => '/manager/handbook/:chapter' });
my ($skip_w)    = Probe::classify($policy, { method => 'get',  path => '/manager/configure/backup_now' });
is($skip_post, 1, 'a POST route is skipped');
is($skip_read, 0, 'a safe GET is requested');
is($skip_arg,  2, 'a parameterised route is held for fixture arguments');
is($skip_w,    1, 'a GET that writes is skipped');

done_testing();
