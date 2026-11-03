# tests-for: lib/JawnOS/Domain/Process.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Lan.pm lib/JawnOS/Domain/Loader.pm perl/President.pl jawn
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
	my $record = {
		parent => 100, pid => 200, name => 'test job', status => 'start',
		warranty => &subs::forever_warranty(), %record,
	};
	return { 100 => { subprocesses => { 200 => $record } } };
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
	is_deeply($report, { reaped => 0, expired => 0, killed => 0 }, 'the report key is not a parent');
}

# --------------------------------------------------------------- the wiring
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
like($calendar, qr/subprocessor_warranty_at\(\$warranty_spec, \$started\)/,
	'the wrapper resolves the warranty at start');
like($calendar, qr/warranty\s*=>\s*\$warranty/, 'the record carries the absolute warranty');
like($calendar, qr/start_ticks\s*=>\s*\$start_ticks/, 'the record carries the pid-reuse guard');

my $launcher = read_file("$root/jawn");
like($launcher, qr/subs::subprocessor_reap\(\$subprocesses/,
	'the master reaps the records the workers send it');
like($launcher, qr/Mojo::IOLoop->recurring\(5 => sub/, 'the reaper runs on its own tick');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Process' for qw\([^)]*subprocessor_reap[^)]*subprocessor_warranty_at[^)]*subprocessor_warranty_for/,
	'the loader maps the process helpers');

my $lan = read_file("$root/lib/JawnOS/Domain/Lan.pm");
like($lan, qr/warranty => &subs::forever_warranty\(\)/,
	'a tunnel row is warrantied forever');
like($lan, qr/name => 'tunnel holder wss ' .*?warranty => 'forever'/s,
	'the tunnel holder is a forever subprocess');

done_testing();
