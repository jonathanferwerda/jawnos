# tests-for: scripts/land_lib.pl scripts/land_enqueue.pl scripts/land_status.pl scripts/land_coordinator.pl scripts/land_warden.pl scripts/systemd/jawnos-land-coordinator.service scripts/systemd/jawnos-land-coordinator.timer scripts/systemd/jawnos-land-warden.service scripts/systemd/jawnos-land-warden.timer
# covers:    the landing queue - enqueue validation and the backup push, the
#           coordinator's waves, one suite and one restart per wave, the hot-file
#           cap, the red-wave split into single tickets, landed-ticket records,
#           skipping a commit already on the trunk, the bounded enqueue wait,
#           the refused-ticket board, dead-running reaping, and the status/stats
#           reader

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
	for my $name (qw(land_lib.pl land_enqueue.pl land_status.pl land_coordinator.pl land_warden.pl)) {
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

sub enqueue_wait {
	my ($f, $wt, @args) = @_;
	local $ENV{'LAND_TEST_DIR'} = $f->{'marker'};
	my $cwd = getcwd();
	chdir $wt or die "chdir $wt: $!";
	my ($rc, $out) = sh($^X, 'scripts/land_enqueue.pl', '--wait', @args);
	chdir $cwd or die "chdir back: $!";
	return ($rc, $out);
}

sub warden {
	my ($f, @args) = @_;
	local $ENV{'LAND_TEST_DIR'} = $f->{'marker'};
	local $ENV{'JAWNOS_QA_ROOT'} = $f->{'qa'};
	my $cwd = getcwd();
	chdir $f->{'primary'} or die "chdir primary: $!";
	my ($rc, $out) = sh($^X, 'scripts/land_warden.pl', '--once', @args);
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

sub refuse_ticket {
	my ($f, $t) = @_;
	my $path = "$f->{'primary'}/.git/land-queue/$t->{'id'}.json";
	my $rec = JSON::PP->new->decode(read_file($path));
	$rec->{'state'} = 'refused';
	$rec->{'result'} = { code => 1, reason_class => 'suite', message => 'fixture: refused for the warden' };
	write_file($path, JSON::PP->new->canonical->encode($rec));
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
	my @cleanup = @{ $s2->{'cleanup'} || [] };
	like(join(' ', @cleanup), qr/git branch -D agent\/two/,
		'a landed ticket names the branch cleanup, since -d declines a rebased branch');
	ok(grep({ m{^git worktree remove } } @cleanup),
		'and the worktree removal, while the directory is still there');

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

# --- a re-enqueued branch carries its already-landed commit ----------------

subtest 'a commit already on the trunk does not refuse the rest of the branch' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'one.txt', "one\n", 'one: first landing');
	my ($e1, $eo1) = enqueue($f, $f->{'wt1'});
	is($e1, 0, 'the first branch enqueues') or diag($eo1);
	my ($c1, $co1) = coordinator($f, '--train-size', '1', '--jobs', '1', '--no-restart');
	is($c1, 0, 'the first ticket drains') or diag($co1);
	my (undef, $first) = git($f->{'primary'}, 'show', 'origin/main:one.txt');
	is($first, 'one', 'the first commit is on the trunk');

	# The branch still holds its original commit (the trunk has the rebased
	# copy), which is what a second commit and re-enqueue looks like.
	commit_file($f->{'wt1'}, 'two.txt', "two\n", 'one: second landing');
	my ($e2, $eo2) = enqueue($f, $f->{'wt1'});
	is($e2, 0, 'the branch re-enqueues with its old commit still in it') or diag($eo2);
	my ($c2, $co2) = coordinator($f, '--train-size', '1', '--jobs', '1', '--no-restart');
	is($c2, 0, 'the coordinator drains rather than refusing an empty patch') or diag($co2);
	my (undef, $second) = git($f->{'primary'}, 'show', 'origin/main:two.txt');
	is($second, 'two', 'the new work landed');
	my (undef, $st) = status($f, '--branch', 'agent/one');
	is($st->{'ticket'}{'state'}, 'landed', 'and the ticket is landed');
	my (undef, $version) = git($f->{'primary'}, 'show', 'origin/main:VERSION');
	is($version, '0.1.3', 'only the second ticket bumped the version');

	# A branch with nothing new at all is not a version-only landing.
	my ($e3, $eo3) = enqueue($f, $f->{'wt1'});
	is($e3, 0, 'the unchanged branch re-enqueues') or diag($eo3);
	my ($c3, $co3) = coordinator($f, '--train-size', '1', '--jobs', '1', '--no-restart');
	is($c3, 0, 'the coordinator drains') or diag($co3);
	my (undef, $st3) = status($f, '--branch', 'agent/one');
	is($st3->{'ticket'}{'result'}{'reason_class'}, 'nothing', 'and says there was nothing left to land');
	my (undef, $version3) = git($f->{'primary'}, 'show', 'origin/main:VERSION');
	is($version3, '0.1.3', 'no version-only commit was pushed');
};

# --- the bounded wait -------------------------------------------------------

subtest 'enqueue can wait for the verdict, bounded' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'one.txt', "one\n", 'one: add a branch');

	# No coordinator is running, so the ticket cannot reach a verdict. The wait
	# returns 2 and leaves the ticket queued: a timeout is a pause, not a loss.
	my ($rc, $out) = enqueue_wait($f, $f->{'wt1'}, '--timeout', '1');
	is($rc, 2, 'a queued ticket with no coordinator gives no verdict');
	like($out, qr/is still queued|waiting up to 1s/, 'the wait is bounded and says so');
	my (undef, $st) = status($f, '--branch', 'agent/one');
	is($st->{'ticket'}{'state'}, 'queued', 'the ticket is still queued, not lost');

	my ($jrc, $jout) = enqueue_wait($f, $f->{'wt1'}, '--json');
	is($jrc, 2, '--wait and --json are refused');
	like($jout, qr/cannot be combined/i, 'and the reason names the pair');
};

subtest 'enqueue --wait returns the landed verdict' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'one.txt', "one\n", 'one: add a branch');

	# The coordinator drains in another process while the enqueue waits.
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if (!$pid) {
		sleep 1;
		coordinator($f, '--train-size', '1', '--jobs', '1', '--no-restart');
		require POSIX;
		POSIX::_exit(0);
	}

	my ($rc, $out) = enqueue_wait($f, $f->{'wt1'}, '--timeout', '60');
	waitpid($pid, 0);
	is($rc, 0, 'the wait returns 0 when the ticket lands') or diag($out);
	like($out, qr/landed/, 'and prints the landed verdict');
	my (undef, $st) = status($f, '--branch', 'agent/one');
	is($st->{'ticket'}{'state'}, 'landed', 'the ticket is landed');
};

# --- the refused board answers without a ticket id -------------------------

subtest 'the refused list answers without a branch id' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'BREAK', "1\n", 'one: break the suite');
	enqueue($f, $f->{'wt1'});
	my ($rc, $out) = coordinator($f, '--train-size', '1', '--jobs', '1', '--suite-retries', '0', '--no-restart');
	is($rc, 0, 'the coordinator drains') or diag($out);

	my ($lrc, $lj, $lout) = status($f, '--refused', '--check');
	is($lrc, 1, '--check exits 1 when a refusal is waiting') or diag($lout);
	my ($t) = grep { ($_->{'branch'} // '') eq 'agent/one' } @{ $lj->{'tickets'} || [] };
	ok($t, 'the refused ticket is listed without a branch id') or diag($lout);
	is($t->{'state'}, 'refused', 'with its state');
	is($t->{'result'}{'reason_class'}, 'suite', 'and the class a fixer needs');
	is($lj->{'counts'}{'refused'}, 1, 'the summary counts it');

	my ($arc, $aj) = status($f, '--all');
	is($arc, 0, '--all reads the whole queue');
	ok(scalar(grep { ($_->{'state'} // '') eq 'refused' } @{ $aj->{'tickets'} || [] }),
		'and includes the refusal');

	my ($crc, $cj) = status($f, '--refused');
	is($crc, 0, 'the report without --check succeeds');
	ok(ref $cj->{'tickets'} eq 'ARRAY', 'and still carries the list');
};

# --- the warden rescues what the coordinator refused -----------------------

subtest 'the warden rescues a green refused ticket' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'one.txt', "one\n", 'one: a green branch');
	my ($erc, $eout) = enqueue($f, $f->{'wt1'});
	is($erc, 0, 'the branch enqueues') or diag($eout);
	my $t = ticket_json($eout);

	# Stand in for the coordinator refusing a green branch: the ticket is the
	# warden's input, and this keeps the rescue deterministic.
	my $path = "$f->{'primary'}/.git/land-queue/$t->{'id'}.json";
	my $rec = JSON::PP->new->decode(read_file($path));
	$rec->{'state'} = 'refused';
	$rec->{'result'} = { code => 1, reason_class => 'suite', message => 'fixture: refused for the warden' };
	write_file($path, JSON::PP->new->canonical->encode($rec));

	my ($wrc, $wout) = warden($f);
	is($wrc, 0, 'the warden runs') or diag($wout);
	like($wout, qr/enqueued/, 'it enqueues the rescued branch');
	my (undef, $s1) = status($f, '--branch', 'agent/one');
	is($s1->{'ticket'}{'warden'}{'state'}, 'enqueued', 'the refused ticket records the rescue');
	ok($s1->{'ticket'}{'warden'}{'report'} && -f $s1->{'ticket'}{'warden'}{'report'},
		'the report is written');

	my ($crc, $cout) = coordinator($f, '--train-size', '1', '--jobs', '1', '--no-restart');
	is($crc, 0, 'the rescued ticket drains') or diag($cout);
	my (undef, $one) = git($f->{'primary'}, 'show', 'origin/main:one.txt');
	is($one, 'one', 'the rescued work is on the trunk');
};

subtest 'the warden resumes a resolved conflict' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'README', "branch\n", 'one: change the readme');
	my ($erc, $eout) = enqueue($f, $f->{'wt1'});
	is($erc, 0, 'the branch enqueues') or diag($eout);
	my $t = ticket_json($eout);

	# Move the trunk under the branch, so the warden's rebase conflicts.
	commit_file($f->{'primary'}, 'README', "trunk\n", 'trunk: change the readme too');
	my ($prc) = git($f->{'primary'}, 'push', 'origin', 'main');
	is($prc, 0, 'the trunk moves');
	refuse_ticket($f, $t);

	my ($wrc, $wout) = warden($f);
	is($wrc, 0, 'the warden runs') or diag($wout);
	like($wout, qr/conflict/, 'it reports the conflict');
	my (undef, $s1) = status($f, '--branch', 'agent/one');
	my $wt = $s1->{'ticket'}{'warden'}{'worktree'};
	ok($wt && -d $wt, 'the conflict worktree is left');

	# The person resolves the marker: keep the branch's text and finish the rebase.
	my ($crc) = git($wt, 'checkout', '--theirs', 'README');
	is($crc, 0, 'the branch side is kept');
	git($wt, 'add', 'README');
	local $ENV{'GIT_EDITOR'} = 'true';
	my ($rrc, $rout) = git($wt, 'rebase', '--continue');
	is($rrc, 0, 'the rebase finishes') or diag($rout);

	my ($wrc2, $wout2) = warden($f);
	is($wrc2, 0, 'the warden resumes') or diag($wout2);
	like($wout2, qr/enqueued/, 'it enqueues the resolved branch');
	my ($crc2, $cout2) = coordinator($f, '--train-size', '1', '--jobs', '1', '--no-restart');
	is($crc2, 0, 'the rescued ticket drains') or diag($cout2);
	my (undef, $readme) = git($f->{'primary'}, 'show', 'origin/main:README');
	is($readme, 'branch', 'the resolved work is on the trunk');
};

subtest 'the warden reports a red ticket and tries it once' => sub {
	my $f = fixture();
	commit_file($f->{'wt1'}, 'BREAK', "1\n", 'one: break the suite');
	enqueue($f, $f->{'wt1'});
	my ($crc, $cout) = coordinator($f, '--train-size', '1', '--jobs', '1', '--suite-retries', '0', '--no-restart');
	is($crc, 0, 'the coordinator drains') or diag($cout);
	my (undef, $s1) = status($f, '--branch', 'agent/one');
	is($s1->{'ticket'}{'state'}, 'refused', 'the red branch is refused');

	my ($wrc, $wout) = warden($f);
	is($wrc, 0, 'the warden runs') or diag($wout);
	like($wout, qr/red/, 'it reports the red suite');
	my (undef, $s1b) = status($f, '--branch', 'agent/one');
	is($s1b->{'ticket'}{'warden'}{'state'}, 'red', 'the ticket records the red attempt');
	ok($s1b->{'ticket'}{'warden'}{'worktree'} && -d $s1b->{'ticket'}{'warden'}{'worktree'},
		'the worktree is left for the fix');
	ok($s1b->{'ticket'}{'warden'}{'report'} && -f $s1b->{'ticket'}{'warden'}{'report'},
		'the report is written');

	my ($wrc2, $wout2) = warden($f);
	is($wrc2, 0, 'the second run is quiet');
	like($wout2, qr/no stranded ticket/, 'it does not retry the same ticket');
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

subtest 'the warden reads the QA panel switch' => sub {
	my $src = read_file("$real/scripts/land_warden.pl");
	like($src, qr/qa_warden_report/, 'it reads the setting the QA panel saves');
	like($src, qr{/manager/note_save}, 'and files the report through the app note route');
};

subtest 'the systemd units run the coordinator and point the timer at it' => sub {
	my $service = read_file("$real/scripts/systemd/jawnos-land-coordinator.service");
	my $timer   = read_file("$real/scripts/systemd/jawnos-land-coordinator.timer");
	my $wservice = read_file("$real/scripts/systemd/jawnos-land-warden.service");
	my $wtimer   = read_file("$real/scripts/systemd/jawnos-land-warden.timer");
	like($service, qr{^Type=oneshot}m, 'the drain is a oneshot');
	like($service, qr{ExecStart=.*land_coordinator\.pl --train-size 6 --jobs 4},
		'it runs the coordinator with the wave and job caps');
	like($service, qr{^TimeoutStartSec=4h}m, 'a wave may serve several branches');
	like($service, qr{^Environment=JAWNOS_QA_ROOT=}m, 'the unit pins the QA root for the train');
	like($timer, qr{^Unit=jawnos-land-coordinator\.service}m, 'the timer fires the service');
	like($timer, qr{OnUnitActiveSec=60s}, 'and re-arms a minute after the drain ends');
	like($wservice, qr/ExecStart=.*land_warden\.pl --once --max 1 --jobs 2/,
		'the warden runs one ticket with the shared job cap');
	like($wservice, qr/CPUQuota=200%/, 'and is capped on the shared box');
	like($wtimer, qr/OnUnitActiveSec=15min/, 'the warden timer ticks every fifteen minutes');
};

done_testing();
