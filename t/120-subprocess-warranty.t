# tests-for: lib/JawnOS/Domain/Process.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Lan.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Manager/Part02.pm lib/JawnOS/Manager/Part08.pm perl/President.pl jawn
# covers:    a subprocessor stamps a warranty, the reaper forgets a dead pid and kills a job past its
#            finite warranty, and a resident loop or a tunnel holder declared 'forever' is never touched.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

# The warranty is an absolute epoch-millisecond moment, the same unit every other
# warranty in the house uses, or subs::forever_warranty(). A finite value is a
# deadline from the child's start; 'forever' is for the resident loops, the
# servers and a tunnel holder, whose own stop path ends them.

subs::preload('subprocessor_command');
subs::preload('subprocessor_warranty_at');
subs::preload('subprocessor_warranty_for');
subs::preload('subprocessor_reap');

my $NOW = 1_700_000_000_000;

# ---------------------------------------------------------------- the resolver
is(&subs::subprocessor_warranty_at('forever', $NOW), &subs::forever_warranty(),
	'a tunnel or a server is the house forever, not a long lease');
is(&subs::subprocessor_warranty_at(undef, $NOW), &subs::forever_warranty(),
	'an unwarranted job is forever, so a new call is never killed on its first run');
is(&subs::subprocessor_warranty_at('nonsense', $NOW), &subs::forever_warranty(),
	'a spec the reader cannot parse is forever, never a deadline');
is(&subs::subprocessor_warranty_at('5s', $NOW), $NOW + 5000, 'seconds');
is(&subs::subprocessor_warranty_at('30m', $NOW), $NOW + 1_800_000, 'minutes');
is(&subs::subprocessor_warranty_at('2h', $NOW), $NOW + 7_200_000, 'hours');
is(&subs::subprocessor_warranty_at('-1d', $NOW), $NOW + 86_400_000,
	'the house sign: a negative offset already means ahead for a warranty');
is(&subs::subprocessor_warranty_at(1_800_000_000_000, $NOW), 1_800_000_000_000,
	'a resolved moment passes through unchanged');

# ------------------------------------------------------------------- seed map
is(&subs::subprocessor_warranty_for('centre view'), '60s', 'a window render has a minute');
is(&subs::subprocessor_warranty_for('document scanner'), '2m', 'the scanner has two');
is(&subs::subprocessor_warranty_for('Pro Main Server'), 'forever', 'a server is resident');
is(&subs::subprocessor_warranty_for('tunnel holder wss 4 ports'), 'forever',
	'a dynamic name finds its prefix');
is(&subs::subprocessor_warranty_for('tunnel peer enrol abcd1234'), '30s',
	'a dynamic enrol name finds its prefix');
is(&subs::subprocessor_warranty_for('nothing anyone declared'), undef,
	'an unlisted name has no seed value');

is(&subs::subprocessor_heartbeat_for('house levels'), '10m', 'a resident loop has a lease');
is(&subs::subprocessor_heartbeat_for('tunnel holder wss 4 ports'), undef,
	'a holder with no heartbeat listed has no lease');

# Every resident job President starts is in the map: a missing entry would still
# be safe (forever), but it would be an inventory nobody can review.
my $root = root();
my $president = read_file("$root/perl/President.pl");
my @seeded = ($president =~ /\},\s*\{\s*name\s*=>\s*'([^']+)'[^{}]*\}\);/g);
ok(scalar @seeded > 20, 'President names its subprocesses (' . scalar(@seeded) . ')');
my @unseeded = grep { !defined &subs::subprocessor_warranty_for($_) } @seeded;
is_deeply(\@unseeded, [], 'every named President subprocess has a warranty seed')
	or diag('add to Process.pm %WARRANTY: ' . join(', ', @unseeded));

# ---------------------------------------------------------------------- reaper
sub tracked_record {
	my (%record) = @_;
	my $pid = $record{'pid'} || 200;
	my $record = {
		parent => 100, pid => $pid, name => 'test job', status => 'start',
		warranty => &subs::forever_warranty(), pgid => 0, %record,
	};
	return { 100 => { subprocesses => { $pid => $record } } };
}

# A pid that is gone is forgotten, whatever its warranty said. A child killed
# with SIGKILL never writes its stop record, and that entry used to stay for the
# master's lifetime.
{
	my $tracked = tracked_record(warranty => $NOW - 1);
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 0 }, kill => sub { push @kills, [@_] }, starttime => sub { '' });
	is($report->{'reaped'}, 1, 'a dead pid is reaped');
	is_deeply(\@kills, [], 'a dead pid is never signalled');
	ok(!exists $tracked->{100}, 'the empty parent entry goes too');
}

# Alive and inside the warranty: untouched.
{
	my $tracked = tracked_record(warranty => $NOW + 60_000);
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { push @kills, [@_] }, starttime => sub { '' });
	is($report->{'expired'}, 0, 'a live job inside its warranty is not expired');
	is_deeply(\@kills, [], 'and is not signalled');
	ok(exists $tracked->{100}{subprocesses}{200}, 'and keeps its record');
}

# A finite warranty that has passed gets one TERM, a grace, then a KILL.
{
	my $tracked = tracked_record(warranty => $NOW - 1);
	my @kills;
	my $kill = sub { push @kills, [@_] };
	my @expired;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => $kill, starttime => sub { '' },
		on_expire => sub { push @expired, $_[1] });
	is($report->{'expired'}, 1, 'the warranty expired');
	is_deeply($kills[0], ['TERM', 200], 'the first pass sends TERM');
	ok(exists $tracked->{100}{subprocesses}{200}, 'the record stays for the grace');

	$report = &subs::subprocessor_reap($tracked,
		now => $NOW + 1000, alive => sub { 1 }, kill => $kill, starttime => sub { '' });
	is($report->{'killed'}, 0, 'a pass inside the five-second grace does not kill');
	is(scalar @kills, 1, 'and sends nothing more');

	$report = &subs::subprocessor_reap($tracked,
		now => $NOW + 6000, alive => sub { 1 }, kill => $kill, starttime => sub { '' });
	is($report->{'killed'}, 1, 'the grace over, the job is killed');
	is_deeply($kills[1], ['KILL', 200], 'the second pass sends KILL');
	ok(!exists $tracked->{100}, 'and the record is gone');
}

# 'Forever' is never expired, even far past every finite value.
{
	my $tracked = tracked_record(warranty => &subs::forever_warranty());
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => 4_000_000_000_000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' });
	is($report->{'expired'}, 0, 'a forever warranty does not expire');
	is_deeply(\@kills, [], 'and is not signalled');
}

# A pid the OS has handed to another process is forgotten, never signalled.
{
	my $tracked = tracked_record(warranty => $NOW - 1, start_ticks => '111');
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '222' });
	is($report->{'reaped'}, 1, 'a reused pid is forgotten');
	is_deeply(\@kills, [], 'a reused pid is never signalled');
}

# The listener also stores a 'status' key beside the parent pids; the reaper
# walks only numeric parents.
{
	my $tracked = { status => 'report' };
	my $report = &subs::subprocessor_reap($tracked, now => $NOW, alive => sub { 0 });
	is_deeply($report, { reaped => 0, expired => 0, killed => 0, extended => 0, capped => 0 }, 'the report key is not a parent');
}

# A 'forever' process with a stale heartbeat is wedged: the lease expires it.
{
	my $tracked = tracked_record(warranty => &subs::forever_warranty(),
		heartbeat_lease => 60_000, heartbeat_at => $NOW - 61_000);
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is($report->{'expired'}, 1, 'a stale heartbeat expires a forever job');
	is_deeply($kills[0], ['TERM', 200], 'the wedged job gets TERM');
}

# A fresh heartbeat keeps it.
{
	my $tracked = tracked_record(warranty => &subs::forever_warranty(),
		heartbeat_lease => 60_000, heartbeat_at => $NOW - 1000);
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is($report->{'expired'}, 0, 'a fresh heartbeat keeps a forever job');
	is_deeply(\@kills, [], 'and signals nothing');
}

# A live descendant extends its ancestor for the descendant's run, so a wrapper
# waiting on ffmpeg is not killed at its own deadline.
{
	my $tracked = tracked_record(warranty => $NOW - 1, pgid => 200);
	my @kills;
	my @scanned;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { push @scanned, $_[1]; ['300'] });
	is($report->{'extended'}, 1, 'a live descendant extends the ancestor');
	is($report->{'expired'}, 0, 'and the ancestor is not expired');
	is_deeply(\@kills, [], 'and is not signalled');
	is_deeply(\@scanned, [200], 'the scan asks for the wrapper group');
	my $record = $tracked->{100}{subprocesses}{200};
	is_deeply($record->{'extended_for'}, ['300'], 'the record names the descendant');
	cmp_ok($record->{'warranty'}, '>', $NOW, 'the deadline moved forward');

	# With the descendant gone and the extension spent, the original deadline wins.
	$report = &subs::subprocessor_reap($tracked,
		now => $NOW + 31_000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is($report->{'expired'}, 1, 'the descendant gone, the ancestor expires');
}

# The child's warranty walks the parent chain: the parents and the parents'
# parents keep their deadline for the length of the child's run.
{
	my $tracked = {
		100 => { subprocesses => { 111 => { parent => 100, pid => 111, warranty => $NOW + 60_000, pgid => 0 } } },
		111 => { subprocesses => { 200 => { parent => 111, pid => 200, warranty => $NOW + 60_000, pgid => 0 } } },
		200 => { subprocesses => { 300 => { parent => 200, pid => 300, warranty => $NOW + 600_000, pgid => 0 } } },
	};
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { die 'no kill' },
		starttime => sub { '' }, descendants => sub { [] }, descendant_step => 30_000);
	my $child = $tracked->{200}{subprocesses}{300};
	my $parent = $tracked->{111}{subprocesses}{200};
	my $grand = $tracked->{100}{subprocesses}{111};
	cmp_ok($parent->{'warranty'}, '>', $NOW + 600_000, 'the parent keeps the child deadline plus a step');
	cmp_ok($grand->{'warranty'}, '>=', $child->{'warranty'}, 'the grandparent keeps at least the child deadline');
	cmp_ok($grand->{'warranty'}, '>=', $NOW + 600_000, 'which is the grandchild run plus a step');
	ok($report->{'extended'} >= 2, 'both ancestors were extended');
}

# The wrapper owns its process group, so an expired job takes its grandchildren
# with it.
{
	my $tracked = tracked_record(warranty => $NOW - 1, pid => 424242, pgid => 424242);
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is_deeply($kills[0], ['TERM', -424242], 'TERM goes to the wrapper group');
	$report = &subs::subprocessor_reap($tracked,
		now => $NOW + 6000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is_deeply($kills[1], ['KILL', -424242], 'KILL goes to the wrapper group');
}

# --------------------------------------------------------- a tracked command
{
	my $run = &subs::subprocessor_command([$^X, '-e', 'print "hello"'],
		{ name => 'test command', record => 0, warranty => '5s' });
	is($run->{'ok'}, 1, 'a command that exits zero is ok');
	is($run->{'output'}, 'hello', 'the command output is captured');

	$run = &subs::subprocessor_command([$^X, '-e', 'exit 3'],
		{ name => 'test command', record => 0, warranty => '5s' });
	is($run->{'ok'}, 0, 'a non-zero command is not ok');
	is($run->{'exit'}, 3, 'the exit status is reported');

	$run = &subs::subprocessor_command([$^X, '-e', 'sleep 10'],
		{ name => 'test command', record => 0, warranty => '0.2s' });
	ok($run->{'timed_out'}, 'a command past its warranty is stopped');
	ok(!$run->{'ok'}, 'and reports failure');
}

# An untracked descendant cannot extend an ancestor forever: past the cap the
# ancestor expires and the group kill takes the hung descendant.
{
	my $tracked = tracked_record(warranty => $NOW - 1, pgid => 200);
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { ['300'] }, max_descendant_ms => 0);
	is($report->{'expired'}, 1, 'a spent descendant cap lets the ancestor expire');
	is($report->{'capped'}, 1, 'the cap was reached');
}

# The master (./jawn) hands its options as one hashref - `subprocessor_reap($subprocesses,
# { now => ..., on_expire => ... })`. Destructured as `my ($t, %opt) = @_` that is an
# even-sized list: it warned and emptied %opt, so every pass ran with defaults and
# nothing was ever expired. The reaper must work with either shape.
{
	for my $shape (qw(hashref list)) {
		my $record = { parent => 100, pid => 200, name => 'test job', warranty => $NOW - 1, pgid => 0 };
		my $tracked = { 100 => { subprocesses => { 200 => $record } } };
		my %opt = (now => $NOW, alive => sub { 1 }, kill => sub { 0 }, starttime => sub { '' },
			descendants => sub { [] });
		my $report = ($shape eq 'hashref')
			? &subs::subprocessor_reap($tracked, \%opt)
			: &subs::subprocessor_reap($tracked, %opt);
		is($report->{'expired'}, 1, "the reaper honours its options given as a $shape");
	}
}

# A job asked for through run_p is forked on the caller's next tick, so its
# record is stamped at the ask but its process starts later - seconds later on a
# busy phone. Its warranty must run from the fork, not from the ask: a 5s header
# render was half spent before it existed and the reaper TERM'd it mid-render.
{
	my $tracked = tracked_record(
		name => 'appt_header_printer',
		warranty => $NOW + 5000,
		deferred_warranty_spec => '10s',
		pgid => 200, pid => 200);
	my $record = $tracked->{100}{subprocesses}{200};
	my @kills;
	# The fork lands late: the first pass that sees the live pid is the start.
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW + 3000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] }, descendant_step => 30_000);
	is($record->{'warranty'}, $NOW + 3000 + 10_000, 'a deferred job starts its warranty when its process appears');
	is($record->{'warranty_started_at'}, $NOW + 3000, 'and the pass that saw it is named');
	is($report->{'expired'}, 0, 'so the ask-to-fork wait is not billed to it');

	# A later pass judges it by that clock: 11s after the fork is past 10s.
	&subs::subprocessor_reap($tracked,
		now => $NOW + 12_500, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is_deeply(\@kills, [], 'inside its own run it is left alone');
	&subs::subprocessor_reap($tracked,
		now => $NOW + 13_100, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is(scalar @kills, 1, 'past ten seconds of its own run it is expired');

	# Stamping is once: a pass must not push the deadline it is judged by.
	my $moved = $record->{'warranty'};
	&subs::subprocessor_reap($tracked,
		now => $NOW + 40_000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is($record->{'warranty'}, $moved, 'a later pass does not restamp the deadline');
}

# A fork that never lands keeps the moment it was due and is signalled then.
{
	my $tracked = tracked_record(
		name => 'appt_header_printer',
		warranty => $NOW + 10_000,
		warranty_started_at => $NOW,
		deferred_warranty_spec => '10s',
		pgid => 0, pid => 200);
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW + 11_000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '' }, descendants => sub { [] });
	is($report->{'expired'}, 1, 'a job whose process never appeared still expires on its last moment');
	is(scalar @kills, 1, 'and is signalled once');
	is($tracked->{100}{subprocesses}{200}{'warranty'}, $NOW + 10_000, 'without moving that moment');
}

# --------------------------------------------------------------- the wiring
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
like($calendar, qr/subprocessor_warranty_at\(\$warranty_spec, \$started\)/,
	'the wrapper resolves the warranty at start');
like($calendar, qr/warranty\s*=>\s*\$warranty/, 'the record carries the absolute warranty');
like($calendar, qr/start_ticks\s*=>\s*\$start_ticks/, 'the record carries the pid-reuse guard');
like($calendar, qr/heartbeat_lease\s*=>\s*\$heartbeat_lease/, 'the record carries the heartbeat lease');
like($calendar, qr/pgid\s*=>\s*\$pgid/, 'the record carries its process group');
like($calendar, qr/deferred_warranty_spec\s*=>\s*\$warranty_spec/, 'a run_p job asks for its warranty at its fork');
like($calendar, qr/my \$forked = \$gb::subprocessed > 1 && !\$params->\{'fork'\} \? 0 : 1;/,
	'a job that may run inline is not stamped as deferred');
like($calendar, qr/setpgrp\(0, 0\)/, 'the wrapper owns its process group');
like($president, qr/subs::subprocessor_heartbeat\(\)/, 'a resident loop heartbeats');

my $launcher = read_file("$root/jawn");
like($launcher, qr/subs::subprocessor_reap\(\$subprocesses/,
	'the master reaps the records the workers send it');
like($launcher, qr/Mojo::IOLoop->recurring\(5 => sub/, 'the reaper runs on its own tick');
like($launcher, qr/'heartbeat'/, 'the master accepts a heartbeat');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Process' for qw\([^)]*subprocessor_reap[^)]*subprocessor_warranty_at[^)]*subprocessor_warranty_for/,
	'the loader maps the process helpers');
like($loader, qr/JawnOS::Domain::Process' for qw\([^)]*subprocessor_heartbeat[^)]*subprocessor_heartbeat_for/,
	'the loader maps the heartbeat helpers');
like($loader, qr/JawnOS::Domain::Process' for qw\([^)]*subprocessor_command/, 'the loader maps the command helper');

my $render = read_file("$root/lib/JawnOS/Domain/Render.pm");
like($render, qr/subs::subprocessor_command\(\$command/, 'the arbitrary command runner tracks its child');
my $part08 = read_file("$root/lib/JawnOS/Manager/Part08.pm");
like($part08, qr/subs::subprocessor_command/, 'the network helper is a tracked command');
my $part02 = read_file("$root/lib/JawnOS/Manager/Part02.pm");
like($part02, qr/subs::subprocessor_command\(\$command/, 'the scanner command is tracked');

my $lan = read_file("$root/lib/JawnOS/Domain/Lan.pm");
like($lan, qr/warranty => &subs::forever_warranty\(\)/,
	'a tunnel row is warrantied forever');
like($lan, qr/name => 'tunnel holder wss ' .*?warranty => 'forever'/s,
	'the tunnel holder is a forever subprocess');
# The presence listener is a resident loop with a two-minute lease. A blocking
# recv on a quiet network never returns, so its heartbeat stopped, the reaper
# expired it, and the presence wake never fired again on that machine.
like($lan, qr/\$sock->blocking\(0\);/, 'the presence listener reads without blocking');
like($lan, qr/sleep 1;\n\s*my %pending;/, 'it wakes once a second and drains the queued datagrams');
unlike($lan, qr/\$ready->can_read\(/, 'the per-datagram select is gone');
like($lan, qr/sub lan_presence_listen \{.*?subprocessor_heartbeat.*?\n\}/s,
	'the presence listener heartbeats while it waits');
like($loader, qr/JawnOS::Domain::Lan' for qw\([^)]*lan_presence_listen[^)]*lan_presence_wait/,
	'the loader maps the presence wait helper');

# Waiting out a quiet spell must heartbeat in chunks, not sleep past the lease.
like($lan, qr/sub lan_presence_wait \{.*?subprocessor_heartbeat.*?sleep\(.*?\n\}/s,
	'the wait helper heartbeats between short sleeps');

done_testing();
