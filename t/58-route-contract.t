# tests-for: lib/JawnOS/Controller/ lib/JawnOS/Domain/Crest.pm lib/JawnOS/Routes.pm lib/JawnOS/Routes/ qa/lib/ qa/routes.policy.json
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

# --- and the other way: every action is reachable by a route --------------------
# The route table is the index for actions, so it has to be complete as well as
# correct: an action that exists in a controller but that no row reaches is dead
# surface, and an agent that greps the name will believe it is a live entry point.
my %routed = map { $_->{'action'} => 1 } @$routes;
my (%action, %action_in, %action_seen);
for my $file (glob "$repo/lib/JawnOS/Controller/*.pm") {
	my ($module) = $file =~ m{Controller/([^/]+)\.pm$};
	next unless $module;
	my $src = read_file($file);
	while ($src =~ /^\s*sub\s+(action_\d+)\b/mg) {
		my $name = $1;
		$action_seen{$name}++ if $action{$name};
		$action{$name}    = 1;
		$action_in{$name} = $module;
	}
}
cmp_ok(scalar(keys %action), '>=', 700, 'the controllers define their actions');

# Every controller is package Manager, so two files that declare the same
# action_<n> are one sub with two bodies: the later load silently wins and a
# route calls the wrong handler. That is how the Weather page's action once
# answered the printer's Find printers with a Weather place error.
my @redefined = grep { $action_seen{$_} } sort keys %action_seen;
is(scalar @redefined, 0, 'no controller action is defined twice')
	or diag('redefined: '
		. join(', ', map { "$_ ($action_in{$_}.pm)" } @redefined[0 .. ($#redefined > 4 ? 4 : $#redefined)]));

my (%id_seen, @id_dupes);
for my $r (@$routes) {
	my $id = $r->{'line'};
	push @id_dupes, "$r->{'module'}:$id ($r->{'method'} $r->{'path'})" if $id_seen{$id}++;
}
is(scalar @id_dupes, 0, 'no route index is used twice')
	or diag('reused: ' . join(', ', @id_dupes[0 .. ($#id_dupes > 4 ? 4 : $#id_dupes)]));

my @unrouted = grep { !$routed{$_} } sort keys %action;
is(scalar @unrouted, 0, 'every controller action has a route row')
	or diag('no route reaches: '
		. join(', ', map { "$_ ($action_in{$_}.pm)" } @unrouted[0 .. ($#unrouted > 4 ? 4 : $#unrouted)]));

# --- the row's order and its action agree ------------------------------------
# A row is [the line the route had in Manager.pl, method, path, action], and the
# action is named for that number. Renaming one without the other leaves the
# table ordered by a number that no longer names its handler - both drift without
# anything failing, because the pair still compiles and still routes.
my (@misnamed, $parsed);
$parsed = 0;
for my $file (glob "$repo/lib/JawnOS/Routes/*.pm") {
	my ($module) = $file =~ m{Routes/([^/]+)\.pm$};
	next unless $module;
	my $n = 0;
	for my $row (split /\n/, read_file($file)) {
		$n++;
		my @m = $row =~
			/\[\s*(\d+)\s*,\s*'[^'\n]*'\s*,\s*'[^'\n]*'\s*,\s*'(action_\d+)'\s*\]/;
		next unless @m == 2;
		$parsed++;
		push @misnamed, "$module:$n row $m[0] names $m[1]" if "action_$m[0]" ne $m[1];
	}
}
cmp_ok($parsed, '>=', 700, 'every route row is readable as [index, method, path, action]');
is(scalar @misnamed, 0, 'each route row is ordered by the number its action is named for')
	or diag(join(', ', @misnamed[0 .. ($#misnamed > 4 ? 4 : $#misnamed)]));

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
is(scalar(@dupes), 0, 'no route is registered twice') or diag("@dupes");

# The two duplicates the split left behind. The mail template delete was filed
# on the server-delete path, so its handler could never run while
# public/js/mailbox.js asked for /manager/mail/email/template/delete. A second
# clothesline POST shadowed nothing the timeline sends. Pin the corrected wiring
# so neither can drift back.
my %route_at = map { lc($_->{'method'}) . ' ' . $_->{'path'} => $_->{'action'} } @$routes;
is($route_at{'post /manager/mail/email/server/delete'}, 'action_31319',
	'the server-delete path answers the server handler');
is($route_at{'post /manager/mail/email/template/delete'}, 'action_31328',
	'and the template delete has its own path');
is($route_at{'post /manager/clothesline'}, 'action_41744',
	'the clothesline POST answers its setter');
my $misc12 = read_file("$repo/lib/JawnOS/Controller/manager_misc12.pm");
unlike($misc12, qr/sub action_41867\b/, 'the shadowed clothesline reader is retired');
like(read_file("$repo/public/js/mailbox.js"), qr#/manager/mail/email/template/delete#,
	'the mailbox script asks the template path');

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
