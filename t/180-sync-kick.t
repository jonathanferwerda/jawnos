# tests-for: lib/JawnOS/Domain/Sync.pm lib/JawnOS/Manager/Part35.pm lib/JawnOS/Domain/Loader.pm perl/gb/01_state_and_defaults.pl perl/utility_jobs.pl perl/help/topics_features.pl scripts/sync_kick.pl
# covers:    the sync kick job clears the three things that stall a rail and nudges the ordinary pass; a dead hub is not chosen

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();
require "$root/perl/gb/01_state_and_defaults.pl";
require "$root/lib/JawnOS/Manager/Part35.pm";
require "$root/lib/JawnOS/Domain/Sync.pm";

{
	package StopRows;
	sub new { my ($class, $rows) = @_; bless { rows => $rows || [] }, $class }
	sub hashes { $_[0]->{'rows'} }
}

my $now = JawnOSTest::ts(2026, 11, 5, 14, 0, 0);

# --- hub selection: a dead peer cannot pin the house -------------------------
{
	local *subs::rightNow = sub { $now };
	local *subs::signatorial_designer = sub { 'self' };
	my $saved = '';
	my @writes;
	local *subs::setting_grabber = sub { $saved };
	local *subs::setting_setter = sub { push @writes, $_[0]->{'value'} };

	my @machines = (
		{ signatorial => 'dead', device => 'server', connection => 'inactive', server_time => $now },
		{ signatorial => 'live', device => 'server', connection => 'active', server_time => $now - 1000 },
		{ signatorial => 'laptop', device => 'computer', connection => 'active', server_time => $now - 2000 },
	);
	$saved = 'dead';
	is(Manager::sync_hub_pick(\@machines, 0), 'live',
		'an inactive saved hub is replaced by the live server');
	is_deeply(\@writes, ['live'], 'and the live pick is stored');

	my @dead = ({ signatorial => 'dead', device => 'server', connection => 'inactive', server_time => $now });
	$saved = 'dead';
	@writes = ();
	is(Manager::sync_hub_pick(\@dead, 0), '',
		'with no live server the pick is empty, so the pass walks the mesh');
	is_deeply(\@writes, [], 'and a dead hub is not written back');

	my @both = (
		{ signatorial => 'live', device => 'server', connection => 'active', server_time => $now },
		{ signatorial => 'other', device => 'server', connection => 'active', server_time => $now - 1000 },
	);
	$saved = 'live';
	@writes = ();
	is(Manager::sync_hub_pick(\@both, 0), 'live', 'a live saved hub is kept');
	is_deeply(\@writes, [], 'without rewriting it');

	my @comp = ({ signatorial => 'comp', device => 'computer', connection => 'active', server_time => $now });
	$saved = 'comp';
	@writes = ();
	is(Manager::sync_hub_pick(\@comp, 0), 'comp',
		'an explicit hub that is live is kept even when it is not a server');

	is(Manager::sync_hub_status({ signatorial => 'dead', connection => 'inactive', server_time => $now }), 0,
		'an inactive hub is not a hub');
	is(Manager::sync_hub_status({ signatorial => 'live', connection => 'active', server_time => $now }), 1,
		'an active fresh hub is a hub');
	is(Manager::sync_hub_status({ signatorial => 'old', connection => 'active', server_time => $now - 7 * 60 * 1000 }), 0,
		'a stale hub is not a hub');
}

# --- the kick clears the brakes and nudges the pass ---------------------------
{
	local *subs::rightNow = sub { $now };
	my (@sets, @backoff, @cache);
	local *subs::remote_upgrade_lock_state = sub { { value => 'running:999999', busy => 0 } };
	local *subs::remote_upgrade_marker_reapable = sub { 1 };
	local *subs::sync_jobs_reap = sub { 2 };
	local *subs::db_select = sub { StopRows->new([
		{ signatorial => 'live', connection => 'active' },
		{ signatorial => 'dead', connection => 'inactive' },
	]) };
	local *subs::sync_backoff_clear = sub { push @backoff, $_[0] };
	local *subs::setting_grabber = sub { 'dead' };
	local *subs::setting_setter = sub { push @sets, [ $_[0]->{'setting'}, $_[0]->{'value'} ] };
	local *subs::cache_set = sub { push @cache, $_[1] };

	my $note = subs::sync_kick();
	like($note, qr/pull marker cleared/, 'a marker no live process owns is cleared');
	like($note, qr/2 pull job/, 'orphaned pull jobs are reaped');
	is_deeply(\@backoff, ['live'], 'backoff is cleared only for the active peer');
	like($note, qr/inactive hub released/, 'a hub the reconnector marked inactive is released');
	is_deeply([ map { $_->[0] } @sets ],
		[ 'remote_upgrade', 'sync_hub', 'remote_connect_timer' ],
		'the marker, the hub and the pass timer are written');
	is($sets[1][1], '', 'the hub setting is cleared');
	is($sets[2][1], 0, 'the reconnector timer is reset');
	is(scalar @cache, 1, 'the ordinary pass is nudged once');
}

# --- the job is declared, wired and documented -------------------------------
my $job = $gb::timeouts->{'sync_kick'};
ok(ref $job eq 'HASH', 'sync_kick is a declared utility');
is($job->{'toggle'}, 'on', 'it starts on: a stuck rail is the failure the job exists for');
is($job->{'group'}, 'fast', 'it runs in the fast pool');
ok(($job->{'timeout'} || 0) >= 30, 'it has a bounded slot');

my $president = read_file("$root/perl/utility_jobs.pl");
like($president, qr/\$gb::timeouts->\{'sync_kick'\}->\{'subroutine'\} = sub \{\s*return &subs::sync_kick\(\);/s,
	'utility_jobs.pl wires the job to subs::sync_kick');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Sync' for qw\([^)]*\bsync_kick\b/s,
	'the domain loader maps sync_kick to Sync.pm');

my $script = read_file("$root/scripts/sync_kick.pl");
like($script, qr/subs::sync_kick\(\)/, 'the CLI runs the same sub');
like($script, qr/sync pass nudged/, 'and says the pass was nudged for the running manager');
like($script, qr/perl5\/lib\/perl5/, 'the CLI finds the local::lib tree a plain shell lacks');
unlike($script, qr/remote_machine_negotiator/, 'it does not try to build a controller in a bare shell');

my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/Sync kick is the sync rail/, 'the utility controller help names the job');

done_testing();
