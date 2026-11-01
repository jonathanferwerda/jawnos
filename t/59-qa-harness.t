use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../qa/lib", "t/lib", "qa/lib";
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use IO::Socket::INET;
use Harness;
use Probe;

# The QA harness is the thing that promises the live house is safe, so its
# promises get tests like any other behaviour. These checks never boot a tree
# and never enter a namespace: they pin the refusals and the port arithmetic.

my $repo = "$FindBin::Bin/..";

# --- a QA root inside the live repo is refused ---------------------------------
# The fence bind-mounts the live repo read-only; a run root inside it could not
# even be created, and worse, a path that resolves there would be a write to the
# house. Harness::new must refuse before doing anything.
{
	my $err;
	eval { Harness->new(repo => $repo, root => abs_path("$repo/qa")) };
	$err = $@;
	like($err, qr/inside the live repo/, 'a QA root inside the repo is refused');
}

# --- the port block ------------------------------------------------------------
{
	my $sandbox = tempdir(CLEANUP => 1);
	my $h = Harness->new(repo => $repo, root => "$sandbox/qa");
	my $p = $h->pick_ports();
	is_deeply([sort keys %$p], [qw(dock working ws)], 'pick_ports names the three public ports');
	is($p->{'ws'}, $p->{'working'} + 1, 'the ws port follows the working port');
	cmp_ok($p->{'dock'}, '>', $p->{'working'} + 5, 'the dock port is outside the alarm block');

	# every port in the block is free when it was chosen
	my @wanted = (0 .. 5, 11, 101);
	my @list = map { $p->{'working'} + $_ } @wanted;
	my @busy;
	for my $port (@list) {
		my $s = IO::Socket::INET->new(
			LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 1, ReuseAddr => 1);
		push @busy, $port unless $s;
		close $s if $s;
	}
	is(scalar(@busy), 0, 'the whole eight-port block is free') or diag("@busy");
}

# --- classification is conservative -------------------------------------------
my $policy = Probe::load_policy("$FindBin::Bin/../qa/routes.policy.json");

my @cases = (
	[ { method => 'post', path => '/manager/announce' },        1, 'POST is skipped' ],
	[ { method => 'get',  path => '/manager/health' },          0, 'health is requested' ],
	[ { method => 'get',  path => '/manager/configure' },       0, 'configure is requested (and expected 403)' ],
	[ { method => 'get',  path => '/manager/configure/backup_now' }, 1, 'a write behind a GET is skipped' ],
	[ { method => 'get',  path => '/manager/self_deploy' },     1, 'a peer lever is skipped' ],
	[ { method => 'get',  path => '/manager/handbook/:chapter' }, 2, 'a parameterised path waits for arguments' ],
	[ { method => 'websocket', path => '/manager/ws' },         1, 'a websocket is skipped' ],
);
for my $c (@cases) {
	my ($route, $want, $name) = @$c;
	my ($got) = Probe::classify($policy, $route);
	is($got, $want, $name);
}

# --- the tier expectations match the app's own table --------------------------
is(Probe::tier_needed('/manager/people'),     'resident', 'people is resident tier');
is(Probe::tier_needed('/manager/configure'),  'citizen',  'configure is citizen tier');
is(Probe::tier_needed('/manager/security'),   'citizen',  'security is citizen tier');
is(Probe::tier_needed('/gate'),               '',         'the gate needs no tier');
is(Probe::expected_status($policy, { method => 'get', path => '/manager/configure' }, 'resident'),
	403, 'a resident session is expected to be refused configure');
is(Probe::expected_status($policy, { method => 'get', path => '/manager/security/padlock_state' }, 'resident'),
	200, 'the padlock rail is exempt from the tier check');
is(Probe::expected_status($policy, { method => 'get', path => '/manager/people' }, 'resident'),
	200, 'a resident session is expected to reach people');

# --- the policy names the routes that need UI arguments ----------------------
my $tol = Probe::tolerated($policy, { method => 'get', path => '/manager/appointment_details' });
ok(defined $tol && length $tol, 'a route that needs query arguments is tolerated with a reason');
is(Probe::tolerated($policy, { method => 'get', path => '/manager/people' }), undef,
	'an ordinary route is not tolerated');

# --- local::lib discovery ------------------------------------------------------
# A non-interactive ssh session exports no PERL5LIB, and the table's system perl
# has Mojo but not Sereal. The harness must find $HOME/perl5/lib/perl5 itself.
{
	my $lib = Harness::_local_lib($ENV{'HOME'}, '/inherited/lib');
	like($lib, qr{\Q/inherited/lib\E}, 'an inherited PERL5LIB is kept');
	if (-d "$ENV{'HOME'}/perl5/lib/perl5") {
		like($lib, qr{\Q$ENV{'HOME'}/perl5/lib/perl5\E}, 'the user local::lib is discovered');
	}
	else {
		pass('no local::lib on this machine to discover');
	}
}

done_testing();
