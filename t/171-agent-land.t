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
print $fh "@ARGV\n";
close $fh;
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

sub sh {
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

	git($primary, 'config', 'user.email', 'agent_land@example.test');
	git($primary, 'config', 'user.name',  'agent_land test');

	write_file("$primary/VERSION",              "0.1.1\n");
	write_file("$primary/README",               "base\n");
	write_file("$primary/scripts/run_tests.pl", $SUITE);
	write_file("$primary/scripts/version_bump.pl", $BUMP);
	write_file("$primary/scripts/restart.pl",   $RESTART);
	write_file("$primary/scripts/agent_land.pl", read_file($real));

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
	my ($brev, $bout) = git($f->{'origin'}, 'rev-parse', '--verify', 'refs/heads/agent/task');
	is($brev, 0, "and origin really has the branch ($bout)");
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

subtest 'a landing can drop its worktree' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');

	my ($rc, $out) = land($f, '--remove');
	is($rc, 0, 'the landing exits cleanly') or diag($out);
	ok(!-d $f->{'wt'}, 'the worktree directory is gone');
	my ($code) = git($f->{'primary'}, 'rev-parse', '--verify', 'refs/heads/agent/task');
	isnt($code, 0, 'and its branch is deleted');
};

subtest 're-running the gate on an already-merged branch refuses' => sub {
	my $f = fixture();
	commit_in_worktree($f, 'note.txt', "a\n", 'v0.1.1 - add a note');

	my ($first) = land($f);
	is($first, 0, 'the first landing succeeds');

	my ($rc, $out) = land($f);
	is($rc, 1, 'the second run refuses') or diag($out);
	like($out, qr/nothing to land/, 'because the branch is already merged');

	my (undef, $count) = git($f->{'primary'}, 'rev-list', '--count', 'origin/main');
	is($count, 2, 'and trunk did not grow a duplicate commit');
	is(read_file("$f->{'primary'}/VERSION"), "0.1.2\n", 'nor a duplicate version');
};

done_testing();
