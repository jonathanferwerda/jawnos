# tests-for: scripts/agent_land.pl
# covers:    the lander - the cross-worktree lock, the rebase, the suite gate, the
#           bump and subject rewrite, the fast-forward-only push, and moving the
#           primary checkout the dev server runs from

use strict;
use warnings;

use Cwd qw(getcwd);
use Fcntl qw(:flock);
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);
use Test::More;

my $real = "$FindBin::Bin/../scripts/agent_land.pl";

# The suite, the bump and the restart are fakes: the lander's job is the order
# and the bookkeeping around them, and running the real suite here would recurse
# into this test. Each fake records its argv in AGENT_LAND_TEST_DIR, outside the
# repo, so calling it never dirties the worktree.
my $SUITE = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
my $dir = $ENV{'AGENT_LAND_TEST_DIR'} || die "no AGENT_LAND_TEST_DIR\n";
open(my $fh, '>>', "$dir/suite") or die $!;
my $generated = -e "$dir/generated" ? 1 : 0;
print $fh "@ARGV generated=$generated\n";
close $fh;
system('git', 'config', 'core.bare', 'true') if -e "$dir/bare";
if (-e "$dir/moved") {
	my $list = `git worktree list --porcelain`;
	my ($p) = $list =~ /^worktree (.+)$/m;
	chomp $p;
	system('git', '-C', $p, '-c', 'user.email=qa-test@example.invalid',
		'-c', 'user.name=qa-test', 'commit', '--allow-empty', '-q', '-m', 'initial');
}
print "suite ran\n";
exit(-e "$dir/fail" ? 1 : 0);
PL

my $BUMP = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
open(my $in, '<', 'VERSION') or die "VERSION: $!\n";
my $v = <$in> // '0.0.0';
close $in;
chomp $v;
$v =~ /^(\d+)\.(\d+)\.(\d+)$/ or die "bad VERSION: $v\n";
my $new = "$1.$2." . ($3 + 1);
open(my $out, '>', 'VERSION') or die "VERSION: $!\n";
print $out "$new\n";
close $out;
print "$new\n";
PL

my $AGENT_HELP = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
my $dir = $ENV{'AGENT_LAND_TEST_DIR'} || die "no AGENT_LAND_TEST_DIR\n";
open(my $log, '>>', "$dir/generated") or die $!;
print $log "agent_help @ARGV\n";
close $log;
open(my $out, '>', 'qa/coding_night/agent-index.md') or die "index: $!\n";
print $out "generated index\n";
close $out;
print "wrote index\n";
exit 0;
PL

my $BAKE = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
my $dir = $ENV{'AGENT_LAND_TEST_DIR'} || die "no AGENT_LAND_TEST_DIR\n";
open(my $log, '>>', "$dir/generated") or die $!;
print $log "bake_agents_rules\n";
close $log;
open(my $out, '>', 'docs/coding_agent_protocols.md') or die "protocols: $!\n";
print $out "generated protocols\n";
close $out;
exit 0;
PL

my $RESTART = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
my $dir = $ENV{'AGENT_LAND_TEST_DIR'} || die "no AGENT_LAND_TEST_DIR\n";
open(my $fh, '>>', "$dir/restart") or die $!;
print $fh "@ARGV\n";
close $fh;
print "restarted\n";
exit 0;
PL

# A master that already has a restart pending answers the second caller busy.
# The lander must wait for that restart, then compare the version the tree
# actually booted rather than treating the refusal as a failed landing.
my $BUSY_RESTART = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
my $dir = $ENV{'AGENT_LAND_TEST_DIR'} || die "no AGENT_LAND_TEST_DIR\n";
open(my $fh, '>>', "$dir/restart") or die $!;
print $fh "@ARGV\n";
close $fh;
if (grep { $_ eq '--status' } @ARGV) {
	my $v = '0.0.0';
	if (open(my $in, '<', 'VERSION')) { $v = <$in>; close $in; $v =~ s/\s+$// }
	print '{"ok":1,"pending":0,"version":"' . $v . '"}', "\n";
	exit 0;
}
print "a restart is already pending\n";
exit 2;
PL

# A guard that outlives the control client's 150 s makes the verdict time out even
# though the tree is coming up on the new version. The lander must look, not fail.
my $TIMEOUT_RESTART = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
my $dir = $ENV{'AGENT_LAND_TEST_DIR'} || die "no AGENT_LAND_TEST_DIR\n";
open(my $fh, '>>', "$dir/restart") or die $!;
print $fh "@ARGV\n";
close $fh;
if (grep { $_ eq '--status' } @ARGV) {
	my $v = '0.0.0';
	if (open(my $in, '<', 'VERSION')) { $v = <$in>; close $in; $v =~ s/\s+$// }
	print '{"ok":1,"pending":0,"version":"' . $v . '"}', "\n";
	exit 0;
}
print STDERR "restart failed: the master did not answer within 150s\n";
exit 2;
PL

sub sh {
	# Git exports GIT_DIR to the pre-push hook that runs this suite. Without this
	# clear, `git -C <temp>` still acts on the live checkout.
	delete local $ENV{'GIT_DIR'};
	delete local $ENV{'GIT_WORK_TREE'};
	delete local $ENV{'GIT_INDEX_FILE'};
	delete local $ENV{'GIT_OBJECT_DIRECTORY'};
	delete local $ENV{'GIT_COMMON_DIR'};
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

# A bare origin, a primary checkout on main, and one agent worktree on
# agent/task - the shape the lander expects to find.
sub fixture {
	my (%arg) = @_;
	my $dir     = tempdir(CLEANUP => 1);
	my $origin  = "$dir/origin.git";
	my $primary = "$dir/primary";
	my $wt      = "$dir/work";
	my $marker  = "$dir/marker";

	my ($ic, $iout) = sh('git', 'init', '--bare', '-b', 'main', $origin);
	die "bare origin: $iout" if $ic != 0;
	my ($pc, $pout) = sh('git', 'init', '-b', 'main', $primary);
	die "primary: $pout" if $pc != 0;
	make_path($primary, "$primary/scripts", $marker);
	if ($arg{'generated'}) {
		make_path("$primary/qa/coding_night", "$primary/docs");
		write_file("$primary/qa/coding_night/agent-index.md", "stale index\n");
		write_file("$primary/docs/coding_agent_protocols.md", "stale protocols\n");
		write_file("$primary/scripts/agent_help.pl", $AGENT_HELP);
		write_file("$primary/scripts/bake_agents_rules.pl", $BAKE);
		write_file("$primary/AGENTS.md", "# fixture map\n");
	}

	git($primary, 'config', 'user.email', 'agent_land@example.test');
	git($primary, 'config', 'user.name',  'agent_land test');
my ($trc, $fixture_top) = git($primary, 'rev-parse', '--show-toplevel');
die "fixture repo is not isolated: $fixture_top\n" unless $trc == 0 && defined $fixture_top && $fixture_top eq $primary;

	write_file("$primary/VERSION",              "0.1.1\n");
	write_file("$primary/README",               "base\n");
	write_file("$primary/.gitignore",           ".shots/\n");
	write_file("$primary/scripts/run_tests.pl", $SUITE);
	write_file("$primary/scripts/version_bump.pl", $BUMP);
	write_file("$primary/scripts/restart.pl",   $arg{'restart'} // $RESTART);
	write_file("$primary/scripts/agent_land.pl", read_file($real));
	# Only the tests that land a firmware change need the board files; without
	# them the lander skips the firmware step, which is what every other fixture
	# here relies on.
	if ($arg{'firmware'}) {
		make_path("$primary/jt");
		write_file("$primary/jt/VERSION", "0.1.0\n");
		write_file("$primary/scripts/fw_bump.pl",
			read_file("$FindBin::Bin/../scripts/fw_bump.pl"));
	}

	# A pre-push hook that records the flag the lander sets. The landing under
	# test must reach it (not --no-verify) and must tell it the suite already ran.
	make_path("$primary/.git-hooks");
	write_file("$primary/.git-hooks/pre-push", <<'SH');
#!/bin/sh
printf 'HOOK-RAN JAWNOS_SUITE_ALREADY_RUN=%s\n' "${JAWNOS_SUITE_ALREADY_RUN:-unset}" >> "$AGENT_LAND_TEST_DIR/hook"
exit 0
SH
	chmod 0755, "$primary/.git-hooks/pre-push" or die "chmod hook: $!";

	git($primary, 'add', '.');
	git($primary, 'commit', '-m', 'v0.1.1 - base');
	git($primary, 'remote', 'add', 'origin', $origin);
	git($primary, 'push', '-u', 'origin', 'main');
	# Only now, so the setup push above does not run it.
	git($primary, 'config', 'core.hooksPath', '.git-hooks');
	git($primary, 'worktree', 'add', $wt, '-b', 'agent/task');

	# Isolation guard: this test has leaked a worktree registration into the live
	# repo under parallel runs. If the fixture repo did not get it, fail here rather
	# than leave the house repo holding an agent/task branch.
	my (undef, $wlist) = git($primary, 'worktree', 'list', '--porcelain');
	die "the fixture worktree did not register in the fixture repo\n"
		unless defined $wlist && index($wlist, $wt) >= 0;

	return {
		dir     => $dir,
		origin  => $origin,
		primary => $primary,
		wt      => $wt,
		marker  => $marker,
	};
}

sub land {
	my ($f, @args) = @_;
	local $ENV{'AGENT_LAND_TEST_DIR'} = $f->{'marker'};
	my $cwd = getcwd();
	chdir $f->{'wt'} or die "chdir worktree: $!";
	my ($code, $out) = sh($^X, 'scripts/agent_land.pl', @args);
	chdir $cwd or die "chdir back: $!";
	return ($code, $out);
}

sub commit_in_worktree {
	my ($f, $file, $text, $subject, %extra) = @_;
	write_file("$f->{'wt'}/$file", $text);
	write_file("$f->{'wt'}/VERSION", $extra{'version'}) if defined $extra{'version'};
	git($f->{'wt'}, 'add', '--', $file);
	git($f->{'wt'}, 'add', '--', 'VERSION') if defined $extra{'version'};
	my ($code, $out) = git($f->{'wt'}, 'commit', '-m', $subject);
	die "commit: $out" if $code != 0;
}

# --- the plan changes nothing ---------------------------------------------

subtest 'a dry run reports the plan and touches nothing' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');

	my ($rc, $out) = land($f, '--dry-run');
	is($rc, 0, 'the dry run exits cleanly');
	like($out, qr/would run: .*run_tests\.pl --jobs 2/, 'it names the suite and the shared job cap');
	like($out, qr/would back up agent\/task to origin\/agent\/task/,
		'it backs the branch up before it waits for the gate');
	like($out, qr/would fast-forward the primary checkout/, 'and the primary checkout step');
	like($out, qr/would remove this worktree afterwards/,
		'and the removal, because it is the default');
	ok(!-e "$f->{'marker'}/suite",   'no suite ran');
	ok(!-e "$f->{'marker'}/restart", 'nothing restarted');

	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	my (undef, $base)   = git($f->{'primary'}, 'rev-parse', 'main');
	is($origin, $base, 'origin/main did not move');
	is(read_file("$f->{'primary'}/VERSION"), "0.1.1\n", 'and VERSION did not move');
};

# --- the gate refuses before it pushes ------------------------------------

subtest 'a dirty worktree is refused' => sub {
	my $f = fixture();
	write_file("$f->{'wt'}/loose.txt", "uncommitted\n");

	my ($rc, $out) = land($f);
	is($rc, 1, 'the lander refuses');
	like($out, qr/uncommitted work/, 'and names the reason');
	ok(!-e "$f->{'marker'}/restart", 'nothing restarted');

	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	my (undef, $base)   = git($f->{'primary'}, 'rev-parse', 'main');
	is($origin, $base, 'origin/main did not move');
};

subtest 'a failing suite refuses the landing' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');
	write_file("$f->{'marker'}/fail", "1\n");

	my ($rc, $out) = land($f);
	is($rc, 1, 'the lander refuses');
	like($out, qr/the suite failed/, 'and says the suite failed');
	like(read_file("$f->{'marker'}/suite"), qr/--jobs 2/, 'the suite really ran first');
	ok(!-e "$f->{'marker'}/restart", 'nothing restarted');

	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	my (undef, $base)   = git($f->{'primary'}, 'rev-parse', 'main');
	is($origin, $base, 'origin/main did not move');
};

subtest 'a dirty primary checkout refuses before pushing' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');
	write_file("$f->{'primary'}/README", "local edit\n");

	my ($rc, $out) = land($f);
	is($rc, 1, 'the lander refuses');
	like($out, qr/primary checkout .* uncommitted/s, 'and names the primary checkout');

	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	my (undef, $base)   = git($f->{'primary'}, 'rev-parse', 'main');
	is($origin, $base, 'nothing was pushed');
};

# --- the landing itself ---------------------------------------------------

subtest 'a clean branch lands, bumps, pushes and updates the primary' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');

	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing exits cleanly') or diag($out);

	like(read_file("$f->{'marker'}/suite"), qr/--jobs 2/, 'the suite ran with the shared job cap');

	my (undef, $subject) = git($f->{'primary'}, 'log', '-1', '--format=%s', 'origin/main');
	is($subject, 'v0.1.2 - add a note', 'the pushed subject carries the bumped version');

	my (undef, $count) = git($f->{'primary'}, 'rev-list', '--count', 'origin/main');
	is($count, 2, 'the landing added exactly one commit');

	is(read_file("$f->{'primary'}/VERSION"), "0.1.2\n", 'the primary checkout is on the new version');

	my (undef, $head)   = git($f->{'primary'}, 'rev-parse', 'HEAD');
	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	is($head, $origin, 'the primary checkout was fast-forwarded, not left an hour behind');

	like(read_file("$f->{'marker'}/restart"), qr/--reason v0\.1\.2 - add a note/,
		'the restart names the landed version');
	like(read_file("$f->{'marker'}/hook"), qr/HOOK-RAN JAWNOS_SUITE_ALREADY_RUN=1/,
		'the push reaches the hook and tells it the suite already ran');
	like($out, qr/backing up agent\/task to origin\/agent\/task/,
		'the branch is backed up to origin before the gate is taken');
	my ($brev) = git($f->{'origin'}, 'rev-parse', '--verify', 'refs/heads/agent/task');
	isnt($brev, 0, 'and the backup branch is deleted once the work is on the trunk');
	ok(-e "$f->{'primary'}/.git/jawnos-land.lock", 'the lock lives in the shared common dir');
};

subtest 'the VERSION hunk is taken from the trunk and re-bumped' => sub {
	my $f = fixture();

	# The trunk moves its own copy forward while the agent works.
	write_file("$f->{'primary'}/VERSION", "0.2.0\n");
	git($f->{'primary'}, 'add', '--', 'VERSION');
	git($f->{'primary'}, 'commit', '-m', 'v0.2.0 - trunk moves');
	git($f->{'primary'}, 'push', 'origin', 'main');

	# The agent's branch edited the same counter, so the rebase conflicts.
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.9 - add a note', version => "0.1.9\n");

	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing still succeeds') or diag($out);

	my (undef, $subject) = git($f->{'primary'}, 'log', '-1', '--format=%s', 'origin/main');
	is($subject, 'v0.2.1 - add a note', 'the trunk copy won and the bump moved past it');
	is(read_file("$f->{'primary'}/VERSION"), "0.2.1\n", 'VERSION is the trunk number, bumped once');
};

# --- the lock -------------------------------------------------------------

subtest 'a second landing waits for the lock and then gives up' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');

	my $lock_path = "$f->{'primary'}/.git/jawnos-land.lock";
	open(my $hold, '>>', $lock_path) or die "lock: $!";
	flock($hold, LOCK_EX | LOCK_NB) or die "could not take the test lock: $!";

	my ($rc, $out) = land($f, '--wait', '0');
	is($rc, 4, 'the second landing reports the held lock');
	like($out, qr/the gate is busy/, 'and says why');
	like($out, qr/already on origin\/agent\/task/, 'and that the work is already safe');
	ok(!-e "$f->{'marker'}/suite", 'it ran no suite');

	close($hold);
};

subtest 'a landing removes its worktree by default' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');

	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing exits cleanly') or diag($out);
	like($out, qr/removed the worktree/, 'and says the worktree went with it');
	like($out, qr/its \.shots\/ scratch went with it/,
		'and that its scratch went too, so a continuing thread does not hunt for it');
	ok(!-d $f->{'wt'}, 'the worktree directory is gone');
	my ($code) = git($f->{'primary'}, 'rev-parse', '--verify', 'refs/heads/agent/task');
	isnt($code, 0, 'and its branch is deleted');
};

subtest 'an open checkpoint keeps the worktree and its shots' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');
	make_path("$f->{'wt'}/.shots");
	write_file("$f->{'wt'}/.shots/AGENT-CHECKPOINT.md", "goal: still open\n");
	write_file("$f->{'wt'}/.shots/probe-shot.webp", "fake image\n");

	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing exits cleanly') or diag($out);
	like($out, qr/worktree kept: an agent checkpoint is open/, 'it says why it kept it');
	ok(-d $f->{'wt'}, 'the worktree is still there');
	ok(-e "$f->{'wt'}/.shots/probe-shot.webp", 'so is the scratch the agent still needs');

	my (undef, $status) = sh('git', '-C', $f->{'wt'}, 'status', '--porcelain');
	is($status, '', 'the open checkpoint did not count as uncommitted work');
};

subtest '--remove forces past an open checkpoint' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');
	make_path("$f->{'wt'}/.shots");
	write_file("$f->{'wt'}/.shots/AGENT-CHECKPOINT.md", "goal: still open\n");

	my ($rc, $out) = land($f, '--remove');
	is($rc, 0, 'the landing exits cleanly') or diag($out);
	ok(!-d $f->{'wt'}, 'the explicit order removes it anyway');
};

subtest '--keep spares the worktree' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');

	my ($rc, $out) = land($f, '--keep');
	is($rc, 0, 'the landing exits cleanly') or diag($out);
	like($out, qr/worktree kept: git worktree remove/, 'and names the command to drop it');
	ok(-d $f->{'wt'}, 'the worktree is still there');
	my ($code) = git($f->{'primary'}, 'rev-parse', '--verify', 'refs/heads/agent/task');
	is($code, 0, 'and so is its branch');
};

subtest 're-running the gate on an already-merged branch refuses' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');

	my ($first) = land($f, '--keep');
	is($first, 0, 'the first landing succeeds');

	my ($rc, $out) = land($f);
	is($rc, 1, 'the second run refuses') or diag($out);
	like($out, qr/nothing to land/, 'because the branch is already merged');

	my (undef, $count) = git($f->{'primary'}, 'rev-list', '--count', 'origin/main');
	is($count, 2, 'and trunk did not grow a duplicate commit');
	is(read_file("$f->{'primary'}/VERSION"), "0.1.2\n", 'nor a duplicate version');
};

subtest 'a suite that leaves the repo bare refuses the landing' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');
	write_file("$f->{'marker'}/bare", "1\n");

	my ($rc, $out) = land($f);
	is($rc, 1, 'the lander refuses') or diag($out);
	like($out, qr/left the repository bare/, 'and names the corruption');
	ok(!-e "$f->{'marker'}/restart", 'it never restarts');

	my (undef, $bare) = git($f->{'primary'}, 'config', '--get', 'core.bare');
	is($bare, 'false', 'and it healed the flag so the next run can work');
	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	my (undef, $base)   = git($f->{'primary'}, 'rev-parse', 'main');
	is($origin, $base, 'nothing was pushed');
};

subtest 'a suite that moves the trunk is put back and refuses' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');
	write_file("$f->{'marker'}/moved", "1\n");

	my ($rc, $out) = land($f);
	is($rc, 1, 'the lander refuses') or diag($out);
	like($out, qr/fixture commit/, 'and names it as a fixture commit');

	my (undef, $head)   = git($f->{'primary'}, 'rev-parse', 'main');
	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	is($head, $origin, 'the trunk was put back where it was');
	ok(!-e "$f->{'marker'}/restart", 'nothing restarted');
};

# --- a firmware change takes the board's own number with it -----------------
subtest 'the lander bumps the board whose firmware it changed' => sub {
	my $f = fixture(firmware => 1);
	write_file("$f->{'wt'}/jt/jt_99_extra.ino", "// one more line of deck firmware\n");
	git($f->{'wt'}, 'add', '--', 'jt/jt_99_extra.ino');
	my ($cc, $co) = git($f->{'wt'}, 'commit', '-m', 'deck: one more line');
	die "commit: $co" if $cc != 0;

	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing goes through');
	like($out, qr/deck 0\.1\.0 -> 0\.1\.1/, 'the deck takes a patch bump');

	my (undef, $jt) = git($f->{'primary'}, 'show', 'main:jt/VERSION');
	is($jt, '0.1.1', 'and the tip commit carries it');
	my (undef, $house) = git($f->{'primary'}, 'show', 'main:VERSION');
	is($house, '0.1.2', 'the house counter still moves on its own');
};

# --- the scheme follows the house -------------------------------------------
subtest 'a board on an older major.minor follows the house' => sub {
	my $f = fixture(firmware => 1);
	# the house moves a minor the way a person does it: by hand, then pushed
	write_file("$f->{'primary'}/VERSION", "0.2.0\n");
	git($f->{'primary'}, 'add', '--', 'VERSION');
	my ($cc, $co) = git($f->{'primary'}, 'commit', '-m', 'v0.2.0 - a new scheme');
	die "commit: $co" if $cc != 0;
	my ($pc, $po) = git($f->{'primary'}, 'push', '--no-verify', 'origin', 'main');
	die "push: $po" if $pc != 0;

	commit_in_worktree($f, 'note.txt', "a\n", 'a note');
	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing goes through');
	like($out, qr/deck 0\.1\.0 -> 0\.2\.0 \(follows house 0\.2\)/,
		'the deck moves onto the house scheme, though its firmware did not change');

	my (undef, $jt) = git($f->{'primary'}, 'show', 'main:jt/VERSION');
	is($jt, '0.2.0', 'and the tip commit carries it');
	my (undef, $house) = git($f->{'primary'}, 'show', 'main:VERSION');
	is($house, '0.2.1', 'while the house counter moves on its own');
};

sub json_out {
	my ($out) = @_;
	my ($line) = grep { /^\{/ } split /\n/, $out;
	return eval { JSON::PP->new->decode($line // '') } || {};
}

# --- the queue's two additions to a hand landing ---------------------------

subtest '--defer-restart lands and leaves the restart to the queue' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'add a note');

	my ($rc, $out) = land($f, '--defer-restart', '--json', '--keep');
	is($rc, 0, 'the landing exits cleanly') or diag($out);
	my $j = json_out($out);
	is($j->{'version'}, '0.1.2', 'the JSON names the landed version');
	ok($j->{'restart_deferred'}, 'and says the restart was deferred');
	ok(!-e "$f->{'marker'}/restart", 'nothing restarted');

	my (undef, $subject) = git($f->{'primary'}, 'log', '-1', '--format=%s', 'origin/main');
	is($subject, 'v0.1.2 - add a note', 'the trunk still took the versioned commit');
	my (undef, $head)   = git($f->{'primary'}, 'rev-parse', 'HEAD');
	my (undef, $origin) = git($f->{'primary'}, 'rev-parse', 'origin/main');
	is($head, $origin, 'and the primary checkout still moved');
};

subtest '--json puts a refusal on stdout and keeps progress on stderr' => sub {
	my $f = fixture();
	write_file("$f->{'wt'}/loose.txt", "uncommitted\n");

	my ($rc, $out) = land($f, '--json');
	is($rc, 1, 'the lander refuses');
	my $j = json_out($out);
	is($j->{'ok'}, 0, 'the JSON says it did not land');
	is($j->{'code'}, 1, 'with the refusal exit code');
	is($j->{'reason_class'}, 'dirty_worktree', 'and a machine-readable reason');
	like($j->{'message'}, qr/uncommitted work/, 'that still names the work');
};

subtest 'a timed-out restart verdict checks the version the tree booted' => sub {
	my $f = fixture(restart => $TIMEOUT_RESTART);
	commit_in_worktree($f, 'note.txt', "a\n", 'add a note');

	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing is not failed by a slow verdict') or diag($out);
	like($out, qr/verdict timed out/, 'it says the verdict timed out');
	like($out, qr/checking the version/, 'and that it is checking the tree');

	my @calls = grep { length } split /\n/, read_file("$f->{'marker'}/restart");
	ok(@calls >= 2, 'it asked, then checked the running version');
	like($calls[1], qr/--status --json/, 'the second was the version check');
};

subtest 'a busy restart waits for the pending tree and verifies the version' => sub {
	my $f = fixture(restart => $BUSY_RESTART);
	commit_in_worktree($f, 'note.txt', "a\n", 'add a note');

	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing is not failed by the busy master') or diag($out);
	like($out, qr/a restart is already pending/, 'it saw the pending restart');
	like($out, qr/waiting for the tree it boots/, 'and waited for the version');

	my @calls = grep { length } split /\n/, read_file("$f->{'marker'}/restart");
	ok(@calls >= 2, 'it asked, then checked the running version');
	like($calls[0], qr/--reason v0\.1\.2/, 'the first call was the restart');
	like($calls[1], qr/--status --json/, 'the second was the version check');
};

subtest 'the lander refreshes the generated index before the suite' => sub {
	my $f = fixture(generated => 1);
	commit_in_worktree($f, 'note.txt', "a\n", 'add a note');

	my ($rc, $out) = land($f);
	is($rc, 0, 'the landing exits cleanly') or diag($out);
	like($out, qr/refreshing the generated agent index/, 'it says it refreshed the generated files');

	my @suite = grep { /--jobs/ } split /\n/, read_file("$f->{'marker'}/suite");
	like($suite[0] // '', qr/generated=1/, 'the suite ran after the refresh');

	my (undef, $index) = git($f->{'primary'}, 'show', 'origin/main:qa/coding_night/agent-index.md');
	my (undef, $protocols) = git($f->{'primary'}, 'show', 'origin/main:docs/coding_agent_protocols.md');
	is($index, 'generated index', 'the pushed tip carries the refreshed index');
	is($protocols, 'generated protocols', 'and the refreshed baked protocols');
	my (undef, $count) = git($f->{'primary'}, 'rev-list', '--count', 'origin/main');
	is($count, 2, 'the refresh rides the landing commit, not a second one');
};

done_testing();
