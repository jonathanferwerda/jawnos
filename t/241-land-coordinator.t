# tests-for: scripts/land_lib.pl scripts/land_enqueue.pl scripts/land_status.pl scripts/land_coordinator.pl scripts/systemd/jawnos-land-coordinator.service scripts/systemd/jawnos-land-coordinator.timer
# covers:    the landing queue - enqueue validation and the backup push, the
#           coordinator's waves, one suite and one restart per wave, the hot-file
#           cap, the red-wave split into single tickets, landed-ticket records,
#           dead-running reaping, and the status/stats reader

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);
use Sys::Hostname qw(hostname);
use Test::More;

my $real = abs_path("$FindBin::Bin/..");

my $SUITE = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
use Cwd qw(getcwd);
my $dir = $ENV{'LAND_TEST_DIR'} || die "no LAND_TEST_DIR\n";
open(my $fh, '>>', "$dir/suite") or die $!;
print $fh "@ARGV\n";
close $fh;
open(my $cwd_fh, '>>', "$dir/cwd") or die $!;
print $cwd_fh getcwd(), "\n";
close $cwd_fh;
# The train worktree is the cwd, so a branch that adds BREAK makes this red.
exit(-e 'BREAK' ? 1 : 0);
PL

my $RESTART = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
my $dir = $ENV{'LAND_TEST_DIR'} || die "no LAND_TEST_DIR\n";
open(my $fh, '>>', "$dir/restart") or die $!;
print $fh "@ARGV\n";
close $fh;
if (grep { $_ eq '--status' } @ARGV) {
	my $v = '0.0.0';
	if (open(my $in, '<', 'VERSION')) { $v = <$in>; close $in; $v =~ s/\s+$// }
	print '{"ok":1,"pending":0,"version":"' . $v . '"}', "\n";
	exit 0;
}
print "restarted\n";
exit 0;
PL

sub sh {
	delete local @ENV{qw(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR)};
	my @cmd = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, @cmd);
	close $in;
	local $/;
	my $o = <$out> // '';
	my $e = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $o . $e);
}

sub git {
	my $dir = shift;
	my ($code, $out) = sh('git', '-C', $dir, @_);
	$out =~ s/\s+$//;
	return ($code, $out);
}

sub fixture {
	my $dir     = tempdir(CLEANUP => 1);
	# The train must not be under /tmp (t/71 exercises the relay's /tmp refusal), so
	# the fixture's QA root is under HOME, as the systemd unit's is.
	my $qa      = tempdir('land-qa-XXXXXX', DIR => ($ENV{'HOME'} || '.'), CLEANUP => 1);
	my $origin  = "$dir/origin.git";
	my $primary = "$dir/primary";
	my $wt1     = "$dir/work-one";
	my $wt2     = "$dir/work-two";
	my $marker  = "$dir/marker";

	my ($ic, $iout) = sh('git', 'init', '--bare', '-b', 'main', $origin);
	die "bare origin: $iout" if $ic != 0;
	my ($pc, $pout) = sh('git', 'init', '-b', 'main', $primary);
	die "primary: $pout" if $pc != 0;
	make_path("$primary/scripts", "$primary/.git-hooks", "$primary/perl",
		"$primary/lib/JawnOS/Manager", $marker);

	git($primary, 'config', 'user.email', 'land_queue@example.test');
	git($primary, 'config', 'user.name',  'land queue test');

	write_file("$primary/VERSION", "0.1.1\n");
	write_file("$primary/README", "base\n");
	write_file("$primary/.gitignore", ".shots/\nconfig.json\ndatabase/\n");
	write_file("$primary/perl/language.pl", "# language\n");
	write_file("$primary/lib/JawnOS/Manager/Index.pm", "# index\n");
	write_file("$primary/scripts/run_tests.pl", $SUITE);
	write_file("$primary/scripts/restart.pl", $RESTART);
	write_file("$primary/scripts/version_bump.pl", read_file("$real/scripts/version_bump.pl"));
	for my $name (qw(land_lib.pl land_enqueue.pl land_status.pl land_coordinator.pl)) {
		write_file("$primary/scripts/$name", read_file("$real/scripts/$name"));
	}
	for my $hook (qw(pre-commit pre-push)) {
		write_file("$primary/.git-hooks/$hook", "#!/bin/sh\nexit 0\n");
		chmod 0755, "$primary/.git-hooks/$hook" or die "chmod $hook: $!";
	}

	git($primary, 'add', '.');
	git($primary, 'commit', '-m', 'v0.1.1 - base');
	git($primary, 'remote', 'add', 'origin', $origin);
	git($primary, 'push', '-u', 'origin', 'main');
	git($primary, 'config', 'core.hooksPath', '.git-hooks');
	git($primary, 'worktree', 'add', $wt1, '-b', 'agent/one');
	git($primary, 'worktree', 'add', $wt2, '-b', 'agent/two');

	return {
		dir => $dir, origin => $origin, primary => $primary,
		wt1 => $wt1, wt2 => $wt2, marker => $marker, qa => $qa,
	};
}

sub commit_file {
	my ($wt, $file, $text, $subject) = @_;
	my $path = "$wt/$file";
	if ($path =~ m{^(.*)/[^/]+$}) { make_path($1) unless -d $1 }
	write_file($path, $text);
	git($wt, 'add', '--', $file);
	my ($rc, $out) = git($wt, 'commit', '-m', $subject);
	die "commit: $out" if $rc != 0;
}

sub enqueue {
	my ($f, $wt, @args) = @_;
	local $ENV{'LAND_TEST_DIR'} = $f->{'marker'};
	my $cwd = getcwd();
	chdir $wt or die "chdir $wt: $!";
	my ($rc, $out) = sh($^X, 'scripts/land_enqueue.pl', '--json', @args);
	chdir $cwd or die "chdir back: $!";
	return ($rc, $out);
}

sub coordinator {
	my ($f, @args) = @_;
	local $ENV{'LAND_TEST_DIR'} = $f->{'marker'};
	local $ENV{'JAWNOS_QA_ROOT'} = $f->{'qa'};
	my $cwd = getcwd();
	chdir $f->{'primary'} or die "chdir primary: $!";
	my ($rc, $out) = sh($^X, 'scripts/land_coordinator.pl', @args);
	chdir $cwd or die "chdir back: $!";
	return ($rc, $out);
}

sub status {
	my ($f, @args) = @_;
	my $cwd = getcwd();
	chdir $f->{'primary'} or die "chdir primary: $!";
	my ($rc, $out) = sh($^X, 'scripts/land_status.pl', '--json', @args);
	chdir $cwd or die "chdir back: $!";
	my $j = eval { JSON::PP->new->decode($out) } || {};
	return ($rc, $j, $out);
}

sub status_stats {
	my ($f) = @_;
	my $cwd = getcwd();
	chdir $f->{'primary'} or die "chdir primary: $!";
	my ($rc, $out) = sh($^X, 'scripts/land_status.pl', '--stats');
	chdir $cwd or die "chdir back: $!";
	return ($rc, $out);
}

sub ticket_json {
	my ($json) = @_;
	my ($obj) = $json =~ /(\{.*\})/s;
	return eval { JSON::PP->new->decode($obj // '') } || {};
}

sub lines {
	my ($path) = @_;
	return () unless -f $path;
	return grep { length } split /\n/, read_file($path);
}

# --- one wave, one suite, one restart --------------------------------------

subtest 'two branches land in one wave, with one suite and one restart' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'one.txt', "one\n", 'one: add a branch');
	commit_file($f->{'wt2'}, 'two.txt', "two\n", 'two: add another');

	my ($c1, $o1) = enqueue($f, $f->{'wt1'});
	is($c1, 0, 'the first branch enqueues') or diag($o1);
	my ($c2, $o2) = enqueue($f, $f->{'wt2'});
	is($c2, 0, 'the second branch enqueues') or diag($o2);
	my $t1 = ticket_json($o1);
	my $t2 = ticket_json($o2);
	isnt($t1->{'id'}, $t2->{'id'}, 'the two branches get two tickets');

	my ($rc, $out) = coordinator($f, '--train-size', '2', '--jobs', '1');
	is($rc, 0, 'the coordinator drains') or diag($out);

	my (undef, $one) = git($f->{'primary'}, 'show', 'origin/main:one.txt');
	my (undef, $two) = git($f->{'primary'}, 'show', 'origin/main:two.txt');
	is($one, 'one', 'the first branch is on the trunk');
	is($two, 'two', 'and so is the second');
	my (undef, $version) = git($f->{'primary'}, 'show', 'origin/main:VERSION');
	is($version, '0.1.3', 'each branch took its own patch bump');
	my (undef, $count) = git($f->{'primary'}, 'rev-list', '--count', 'origin/main');
	is($count, 3, 'the wave added two commits to the base');

	my @suite = lines("$f->{'marker'}/suite");
	is(scalar @suite, 1, 'the wave ran the suite exactly once');
	like($suite[0], qr/--jobs 1/, 'with the coordinator job cap');

	my @cwd = grep { length } split /\n/, read_file("$f->{'marker'}/cwd");
	ok(@cwd && index($cwd[0], "$f->{'qa'}/train") == 0,
		'the train runs under the QA root');
	unlike($cwd[0] // '', qr{^/tmp/}, 'not under /tmp, where the relay refuses sockets');

	my @restart = lines("$f->{'marker'}/restart");
	is(scalar @restart, 1, 'the wave restarted once');
	like($restart[0], qr/v0\.1\.3 - two: add another/, 'for the last version it landed');

	my (undef, $head)   = git($f->{'primary'}, 'rev-parse', 'HEAD');
	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	is($head, $origin, 'the primary checkout fast-forwarded onto the wave');

	my (undef, $s1) = status($f, '--id', $t1->{'id'});
	is($s1->{'ticket'}{'state'}, 'landed', 'the first ticket is landed');
	is($s1->{'ticket'}{'result'}{'version'}, '0.1.2', 'with its own version');
	my (undef, $s2) = status($f, '--id', $t2->{'id'});
	is($s2->{'ticket'}{'result'}{'version'}, '0.1.3', 'the second carries the next one');

	my (undef, $stats) = status_stats($f);
	like($stats, qr/waves: 1/, 'the stats count the one wave');

	my $ledger = "$f->{'primary'}/.git/land-queue/land.jsonl";
	my ($wave_line) = grep {
		my $e = eval { JSON::PP->new->decode($_) } || {};
		($e->{'event'} // '') eq 'wave' && ($e->{'result'} // '') eq 'landed';
	} lines($ledger);
	my $wave = eval { JSON::PP->new->decode($wave_line // '') } || {};
	is_deeply($wave->{'tickets'}, [$t1->{'id'}, $t2->{'id'}],
		'the landed wave names the tickets it landed, not null');
};

# --- a red wave splits, and the good branch still lands --------------------

subtest 'a red wave splits and lands the branches that pass' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'BREAK', "1\n", 'one: break the suite');
	commit_file($f->{'wt2'}, 'two.txt', "two\n", 'two: add another');
	enqueue($f, $f->{'wt1'});
	enqueue($f, $f->{'wt2'});

	my ($rc, $out) = coordinator($f, '--train-size', '2', '--jobs', '1', '--suite-retries', '0');
	is($rc, 0, 'the coordinator drains') or diag($out);

	my (undef, $two) = git($f->{'primary'}, 'show', 'origin/main:two.txt');
	is($two, 'two', 'the good branch landed');
	my ($bad) = git($f->{'primary'}, 'cat-file', '-e', 'origin/main:BREAK');
	isnt($bad, 0, 'the breaking branch did not');

	my @suite = lines("$f->{'marker'}/suite");
	is(scalar @suite, 3, 'the red wave, then each branch on its own');

	my (undef, $s1) = status($f, '--branch', 'agent/one');
	is($s1->{'ticket'}{'state'}, 'refused', 'the breaking ticket is refused');
	is($s1->{'ticket'}{'result'}{'reason_class'}, 'suite', 'and names the suite');
	my (undef, $s2) = status($f, '--branch', 'agent/two');
	is($s2->{'ticket'}{'state'}, 'landed', 'the good ticket is landed');
};

# --- one hot-file branch per wave -----------------------------------------

subtest 'two hot-file branches land one wave at a time' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'perl/language.pl', "# one\n", 'one: hot file');
	commit_file($f->{'wt2'}, 'lib/JawnOS/Manager/Index.pm', "# two\n", 'two: hot file');
	enqueue($f, $f->{'wt1'});
	enqueue($f, $f->{'wt2'});

	my ($rc, $out) = coordinator($f, '--train-size', '2', '--jobs', '1', '--no-restart');
	is($rc, 0, 'the coordinator drains') or diag($out);

	my @suite = lines("$f->{'marker'}/suite");
	is(scalar @suite, 2, 'the hot-file cap made two waves');
	my (undef, $v) = git($f->{'primary'}, 'show', 'origin/main:VERSION');
	is($v, '0.1.3', 'both branches are on the trunk');
};

# --- enqueue refuses what it cannot land ----------------------------------

subtest 'enqueue refuses dirty, primary, already-merged and full queues' => sub {
	my $f = fixture();

	write_file("$f->{'wt1'}/loose.txt", "uncommitted\n");
	my ($dirty, $dout) = enqueue($f, $f->{'wt1'});
	is($dirty, 1, 'a dirty worktree is refused');
	is(ticket_json($dout)->{'reason_class'}, 'dirty', 'and names the dirt');
	unlink "$f->{'wt1'}/loose.txt";

	my ($primary, $pout) = enqueue($f, $f->{'primary'});
	is($primary, 1, 'the primary checkout cannot enqueue');
	is(ticket_json($pout)->{'reason_class'}, 'primary', 'and says why');

	commit_file($f->{'wt2'}, 'two.txt', "two\n", 'two: add another');
	my ($ok, $oout) = enqueue($f, $f->{'wt2'});
	like($oout, qr/land_status\.pl --branch agent\/two.*keep the worktree/s,
		'a ticket names the verdict and says to keep the worktree');
	is($ok, 0, 'a clean branch enqueues') or diag($oout);
	my $first = ticket_json($oout);

	my ($again, $aout) = enqueue($f, $f->{'wt2'});
	is($again, 0, 're-enqueueing refreshes the snapshot');
	is(ticket_json($aout)->{'id'}, $first->{'id'}, 'and keeps the same ticket');
	is(ticket_json($aout)->{'position'}, 1, 'in the same place');

	commit_file($f->{'wt1'}, 'one.txt', "one\n", 'one: add a branch');
	my ($full, $fout) = enqueue($f, $f->{'wt1'}, '--max-queue', '1');
	is($full, 1, 'a full queue refuses another ticket');
	is(ticket_json($fout)->{'reason_class'}, 'queue_full', 'and says the queue is full');
};

# --- a dead coordinator's running ticket is requeued ----------------------

subtest 'a ticket left running by a dead coordinator is reaped and landed' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'one.txt', "one\n", 'one: add a branch');
	enqueue($f, $f->{'wt1'});

	my $path = "$f->{'primary'}/.git/land-queue/00000001.json";
	my $t = JSON::PP->new->decode(read_file($path));
	$t->{'state'} = 'running';
	$t->{'pid'} = 0;
	$t->{'started_at'} = time;
	write_file($path, JSON::PP->new->canonical->encode($t));

	my ($rc, $out) = coordinator($f, '--train-size', '1', '--jobs', '1', '--no-restart');
	is($rc, 0, 'the coordinator drains') or diag($out);
	like($out, qr/requeued dead running ticket/, 'it says the dead ticket was reaped');

	my (undef, $s) = status($f, '--branch', 'agent/one');
	is($s->{'ticket'}{'state'}, 'landed', 'the reaped ticket landed');
};

subtest 'a worker enqueues on the authority and the train lands it' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'one.txt', "one\n", 'one: add a branch');

	my $host = hostname();
	my ($rc, $out) = enqueue($f, $f->{'wt1'}, '--authority', $host);
	is($rc, 0, 'the worker enqueues through the authority') or diag($out);
	my $j = ticket_json($out);
	ok($j->{'id'}, 'the authority returned a ticket');

	my (undef, $st) = status($f, '--id', $j->{'id'});
	is($st->{'ticket'}{'remote'}, 1, 'the ticket is marked remote');
	ok(!length($st->{'ticket'}{'worktree'} // ''), 'and carries no worktree path');

	my $cwd = getcwd();
	chdir $f->{'wt1'} or die "chdir worktree: $!";
	my ($src, $sout) = sh($^X, 'scripts/land_status.pl',
		'--authority', $host, '--id', $j->{'id'}, '--json');
	chdir $cwd or die "chdir back: $!";
	is($src, 0, 'the worker reads the authority queue') or diag($sout);
	my $sj = eval { JSON::PP->new->decode($sout) } || {};
	is($sj->{'ticket'}{'state'}, 'queued', 'and sees the queued ticket');

	my ($crc, $cout) = coordinator($f, '--train-size', '1', '--jobs', '1', '--no-restart');
	is($crc, 0, 'the coordinator drains') or diag($cout);
	my (undef, $done) = status($f, '--id', $j->{'id'});
	is($done->{'ticket'}{'state'}, 'landed', 'the remote ticket landed');
	my (undef, $one) = git($f->{'primary'}, 'show', 'origin/main:one.txt');
	is($one, 'one', 'and its work is on the trunk');
};

subtest 'the authority refuses a foreign commit identity' => sub {
	my $f = fixture();
	write_file("$f->{'wt1'}/one.txt", "one\n");
	git($f->{'wt1'}, 'add', '--', 'one.txt');
	my ($cc, $co) = git($f->{'wt1'}, '-c', 'user.name=Zed', '-c', 'user.email=zed@jawnos.local',
		'commit', '-m', 'one: foreign commit');
	die "foreign commit: $co" if $cc != 0;

	my ($rc, $out) = enqueue($f, $f->{'wt1'}, '--authority', hostname());
	is($rc, 1, 'the authority refuses it');
	is(ticket_json($out)->{'reason_class'}, 'identity', 'and names the identity');
};

subtest 'the systemd units run the coordinator and point the timer at it' => sub {
	my $service = read_file("$real/scripts/systemd/jawnos-land-coordinator.service");
	my $timer   = read_file("$real/scripts/systemd/jawnos-land-coordinator.timer");
	like($service, qr{^Type=oneshot}m, 'the drain is a oneshot');
	like($service, qr{ExecStart=.*land_coordinator\.pl --train-size 6 --jobs 4},
		'it runs the coordinator with the wave and job caps');
	like($service, qr{^TimeoutStartSec=4h}m, 'a wave may serve several branches');
	like($service, qr{^Environment=JAWNOS_QA_ROOT=}m, 'the unit pins the QA root for the train');
	like($timer, qr{^Unit=jawnos-land-coordinator\.service}m, 'the timer fires the service');
	like($timer, qr{OnUnitActiveSec=60s}, 'and re-arms a minute after the drain ends');
};

done_testing();
