# tests-for: lib/JawnOS/Domain/Sync.pm lib/JawnOS/Domain/Lan.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Manager/Part35.pm lib/JawnOS/Domain/Loader.pm perl/gb/01_state_and_defaults.pl perl/utility_jobs.pl perl/help/topics_features.pl scripts/sync_kick.pl
# covers:    the sync kick job clears the things that stall a rail and nudges the ordinary pass; a pull in flight neither hides another peer's failure nor gets its job reaped; a dead hub is not chosen; a controller holds its automatic sync until its card is mounted

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
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
{
	package SyncQuery;
	sub new { my ($class, $row) = @_; bless { row => $row || {} }, $class }
	sub hashes { [ $_[0]->{'row'} ] }
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
	local *subs::sync_backoff_remaining = sub { 0 };
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

# --- the kick drops short brakes, not a deliberate hold ----------------------
# The reconnector brakes a peer for 120 s or 300 s, and the kick exists to drop
# those. A peer braked for a day is a deliberate hold - it was serving rows that
# must not spread - so the kick must name it and leave the brake in place; only
# --force clears it.
{
	local *subs::rightNow = sub { $now };
	my (@backoff, @cache);
	local *subs::remote_upgrade_lock_state = sub { { busy => 1, value => 'running:123', age => 0 } };
	local *subs::remote_upgrade_marker_reapable = sub { 0 };
	local *subs::sync_jobs_reap = sub { 0 };
	local *subs::db_select = sub { StopRows->new([
		{ signatorial => 'short', connection => 'active' },
		{ signatorial => 'held',  connection => 'active' },
	]) };
	local *subs::sync_backoff_remaining = sub { $_[0] eq 'held' ? 86_400_000 : 120_000 };
	local *subs::sync_backoff_clear = sub { push @backoff, $_[0] };
	local *subs::setting_grabber = sub { '' };
	local *subs::setting_setter = sub { };
	local *subs::cache_set = sub { push @cache, $_[1] };

	my $note = subs::sync_kick();
	is_deeply(\@backoff, ['short'], 'a short brake is cleared and the deliberate hold is not');
	like($note, qr/1 deliberate backoff left in place/, 'the kick says which brake it left alone');

	@backoff = ();
	my $forced = subs::sync_kick({ force => 1 });
	is_deeply(\@backoff, ['short', 'held'], 'force clears the deliberate hold too');
	unlike($forced, qr/deliberate backoff/, 'and reports nothing held');
}

# --- a kick that looks past a busy marker leaves the live pull alone ----------
# The scheduled job now checks another peer's failure while a pull is in
# flight; it must not reap the job row of the pull that is still running.
{
	local *subs::rightNow = sub { $now };
	my @reaped;
	local *subs::remote_upgrade_lock_state = sub { { busy => 1, value => 'running:123', age => 0 } };
	local *subs::remote_upgrade_marker_reapable = sub { 0 };
	local *subs::sync_jobs_reap = sub { push @reaped, 1; return 0 };
	local *subs::db_select = sub { StopRows->new([]) };
	local *subs::setting_grabber = sub { '' };
	local *subs::setting_setter = sub { };
	local *subs::cache_set = sub { };
	my $note = subs::sync_kick();
	is(scalar @reaped, 0, 'a live pull job is not reaped while its marker is busy');
	is($note, 'nothing was holding it', 'and the kick reports it found nothing to clear');
}

# --- a controller waits for its card -----------------------------------------
# The card is the archive, so a pull before it is mounted writes the house's
# appointments and files to the eMMC. The board's own first boot sets
# archive_dir on adoption; an empty or unready root is the hold.
{
	my $mounted = tempdir(CLEANUP => 1);
	is(subs::sync_auto_hold({ device => 'controller', archive_dir => '' }),
		'no archive card', 'a controller with no card holds its sync');
	is(subs::sync_auto_hold({ device => 'controller', archive_dir => "$mounted/missing" }),
		'the archive card is not mounted', 'a card that is not there holds it too');
	is(subs::sync_auto_hold({ device => 'controller', archive_dir => $mounted, archive_dev => 1, root_dev => 1 }),
		'the archive card is not mounted', 'an empty mountpoint on the root filesystem is not a card');
	is(subs::sync_auto_hold({ device => 'controller', archive_dir => $mounted, archive_dev => 2, root_dev => 1 }), undef,
		'a card on its own device lets the pass run');
	is(subs::sync_auto_hold({ device => 'computer', archive_dir => '' }), undef,
		'a computer has no card rule');
	is(subs::sync_auto_hold({}), undef, 'a machine with no device class is not held');

	my $lan = read_file("$root/lib/JawnOS/Domain/Lan.pm");
	like($lan, qr/sync_auto_hold\(\{ device => \$device, archive_dir => \$archive_dir \}\)/,
		'the negotiator asks the hold before it dials a peer');
	like($lan, qr/config_reader\(\).*?archive_dir/s,
		'and reads the card this machine adopted, not a shared drive setting');
	like($lan, qr/return;/,
		'and leaves the pass when the card is not ready');
	my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
	like($loader, qr/JawnOS::Domain::Sync' for qw\([^)]*\bsync_auto_hold\b/s,
		'the domain loader maps the hold to Sync.pm');
}

# --- the job is declared, wired and documented -------------------------------
my $job = $gb::timeouts->{'sync_kick'};
ok(ref $job eq 'HASH', 'sync_kick is a declared utility');
is($job->{'toggle'}, 'on', 'it starts on: a stuck rail is the failure the job exists for');
is($job->{'group'}, 'fast', 'it runs in the fast pool');
ok(($job->{'timeout'} || 0) >= 30, 'it has a bounded slot');

my $president = read_file("$root/perl/utility_jobs.pl");
like($president, qr/\$gb::timeouts->\{'sync_kick'\}->\{'subroutine'\} = sub \{\s*return &subs::sync_kick\(\{ only_if_stalled => 1 \}\);/s,
	'utility_jobs.pl wires the scheduled job to the gated kick');

# --- the watchdog only touches a rail that looks blocked ---------------------
# A quiet house is healthy: the kick must not become another timed pull. It
# fires on a failed pull with no completed one since, on a dead marker, on an
# orphaned running job, or on an inactive saved hub.
{
	my %s = (
		up      => { busy => 0, value => '', age => 0 },
		running => 0,
		jobs    => [ { peer => 'phone', done => $now - 5 * 60 * 1000, fail => 0 } ],
		hub     => '',
		peers   => [],
	);
	local *subs::rightNow = sub { $now };
	local *subs::remote_upgrade_lock_state = sub { return { %{ $s{'up'} } }; };
	local *subs::db_query = sub {
		my ($sql) = @_;
		# The peer query now asks for a running count too, so match it first.
		return StopRows->new($s{'jobs'}) if $sql =~ /group by peer/;
		return SyncQuery->new({ c => $s{'running'} }) if $sql =~ /state = 'running'/;
		return SyncQuery->new({});
	};
	local *subs::db_select = sub { StopRows->new($s{'peers'}) };
	local *subs::setting_grabber = sub { $s{'hub'} };

	is(subs::sync_stalled(), '', 'a healthy quiet rail is left alone');
	is(subs::sync_kick({ only_if_stalled => 1 }), undef, 'the scheduled job does nothing on a quiet rail');

	$s{'jobs'} = [ { peer => 'phone', done => $now - 20 * 60 * 1000, fail => $now - 5 * 60 * 1000 } ];
	like(subs::sync_stalled(), qr/no pull has finished/, 'a failed pull with no success since is a stall');

	# A peer that has only ever failed has no done row at all, so its done time
	# is 0. That is not a duration: the note must not read it as minutes since
	# 1970 and report a decades-long stall (2026-11-23).
	$s{'jobs'} = [ { peer => 'phone', fail => $now - 5 * 60 * 1000 } ];
	my $never = subs::sync_stalled();
	like($never, qr/has ever finished|never completed a pull/,
		'a peer with no completed pull at all is a stall');
	like($never, qr/last failure \d+m ago/, 'and the note says when its last failure was');
	like($never, qr/phone/, 'and names the peer');
	unlike($never, qr/\b\d{4,}m/, 'and does not read the missing done time as a minute count');

	# A second peer that is pulling fine must not hide the broken one: the
	# house-wide newest-done test did exactly that, so the kick never fired.
	$s{'jobs'} = [
		{ peer => 'phone',  done => $now - 20 * 60 * 1000, fail => $now - 5 * 60 * 1000 },
		{ peer => 'laptop', done => $now - 1 * 60 * 1000,  fail => 0 },
	];
	like(subs::sync_stalled(), qr/no pull has finished/, 'a healthy peer does not mask a failing one');
	like(subs::sync_stalled(), qr/phone/, 'and the blocked peer is named in the note');

	$s{'jobs'} = [ { peer => 'phone', done => $now - 5 * 60 * 1000, fail => $now - 40 * 60 * 1000 } ];
	is(subs::sync_stalled(), '', 'an old failure after a long-quiet rail is history');

	# The failure window is twice the kick interval: a failure from 20 minutes
	# ago with no completed pull since is still a live block at the next slot,
	# because a 15-minute window let the 09:15 slot call the 08:59 failure
	# history (2026-11-19).
	$s{'jobs'} = [ { peer => 'phone', done => $now - 60 * 60 * 1000, fail => $now - 20 * 60 * 1000 } ];
	like(subs::sync_stalled(), qr/no pull has finished/, 'a failure older than the kick interval is still a stall');
	$s{'jobs'} = [ { peer => 'phone', done => $now - 60 * 60 * 1000, fail => $now - 40 * 60 * 1000 } ];
	is(subs::sync_stalled(), '', 'a failure older than twice the kick interval is history');

	$s{'jobs'} = [];
	is(subs::sync_stalled(), '', 'a database with no job history is not judged');

	$s{'jobs'} = [ { peer => 'phone', done => $now - 5 * 60 * 1000, fail => 0 } ];
	$s{'up'} = { busy => 1, value => 'running:123', age => 0 };
	is(subs::sync_stalled(), '', 'a pull in flight is not a stall');

	# The pass claims its marker before it forks, so the scheduled kick runs in
	# the same utility pass with a busy marker. That must not hide a different
	# peer whose pull failed with no completed one since (2026-11-19).
	$s{'jobs'} = [
		{ peer => 'phone',  done => $now - 60 * 60 * 1000, fail => $now - 10 * 60 * 1000, running => 0 },
		{ peer => 'laptop', done => $now - 2 * 60 * 1000,  fail => 0, running => 1 },
	];
	like(subs::sync_stalled(), qr/no pull has finished/, 'a pull in flight does not mask another peer\'s failed pull');
	like(subs::sync_stalled(), qr/phone/, 'and the stalled peer is named');
	$s{'jobs'} = [ { peer => 'phone', done => $now - 60 * 60 * 1000, fail => $now - 10 * 60 * 1000, running => 1 } ];
	is(subs::sync_stalled(), '', 'a peer that is pulling again is not a stall');

	$s{'up'} = { busy => 0, value => 'running:999999', age => 20 * 60 * 1000 };
	like(subs::sync_stalled(), qr/pull marker/, 'a marker no live process owns is a stall');

	$s{'up'} = { busy => 0, value => '', age => 0 };
	$s{'running'} = 1;
	like(subs::sync_stalled(), qr/pull job has been left running/, 'an orphaned running job is a stall');

	$s{'running'} = 0;
	$s{'hub'} = 'hub';
	$s{'peers'} = [ { signatorial => 'hub', connection => 'inactive' } ];
	like(subs::sync_stalled(), qr/saved hub/, 'an inactive saved hub is a stall');
}

# The headless relay is a queue drain, not a pooled background chore. It was
# cloned into the Fast pool, whose fifteen minutes swallowed its own minute;
# a row still carrying that default is healed on the controller's next tick.
my $relay_job = $gb::timeouts->{'remote_relay'};
ok(ref $relay_job eq 'HASH', 'remote_relay is a declared utility');
is($relay_job->{'interval'}, 60, 'it keeps its own minute');
ok(!$relay_job->{'group'}, 'and is not cloned into a batch pool');
like($president, qr/utility_relay_ungroup\(\$controls->\{\$signatorial\}\)/,
	'the controller heals a row still in the old Fast pool');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Sync' for qw\([^)]*\bsync_stalled\b/s,
	'the domain loader maps sync_stalled to Sync.pm');
like($loader, qr/JawnOS::Domain::Sync' for qw\([^)]*\bsync_kick\b/s,
	'the domain loader maps sync_kick to Sync.pm');
like($loader, qr/JawnOS::Domain::Sync' for qw\([^)]*\bsync_backoff_remaining\b/s,
	'the domain loader maps sync_backoff_remaining to Sync.pm');

my $script = read_file("$root/scripts/sync_kick.pl");
like($script, qr/subs::sync_kick\(/, 'the CLI runs the same sub');
like($script, qr/--force/, 'and can lift a deliberate hold');
like($script, qr/sync pass nudged/, 'and says the pass was nudged for the running manager');
like($script, qr/perl5\/lib\/perl5/, 'the CLI finds the local::lib tree a plain shell lacks');
unlike($script, qr/remote_machine_negotiator/, 'it does not try to build a controller in a bare shell');

my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/Sync kick is the sync rail/, 'the utility controller help names the job');
like($help, qr/looks first and only acts when the rail looks blocked/, 'the help says the scheduled job checks before it kicks');
like($help, qr/deliberate hold/, 'the help says a deliberate brake survives a kick');
like($help, qr/sync_kick\.pl --force/, 'and how to lift it');

done_testing();
