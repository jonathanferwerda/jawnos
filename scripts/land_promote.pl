#!/usr/bin/perl

# Promote the working branch to main, after testing it.
#
#   perl scripts/land_promote.pl --once
#   perl scripts/land_promote.pl --once --dry-run
#   perl scripts/land_promote.pl --once --jobs 2
#
# The working branch is the coordinator's trunk: agents land their tickets
# there, tested. main is the stable branch the app runs. This job takes the land
# lock (so a wave is never half-landed), rebases nothing, and only then
# fast-forwards main to the working tip and restarts the primary checkout. The
# coordinator records the tip and the scope of the suite it passed; only a tip it
# tested with the FULL suite is promoted without another run (a normally scoped
# working wave, or a hand push, gets the full suite here first), so main is
# always gated by the whole suite. If main is not an ancestor of working, or the
# suite is red, nothing moves; the event log says why.
#
# It bootstraps origin/working from origin/main when the branch does not exist
# yet. One promotion at a time; a held land lock is a later look, not a failure.

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Path qw(make_path rmtree);
use File::Slurp qw(write_file);
use FindBin;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

require "$FindBin::Bin/land_lib.pl";

my %opt = (
	'trunk'   => 'working',
	'main'    => 'main',
	'jobs'    => 2,
	'timeout' => 1800,
	'restart' => 1,
	'once'    => 0,
	'dry_run' => 0,
);
GetOptions(
	'trunk=s'    => \$opt{'trunk'},
	'main=s'     => \$opt{'main'},
	'jobs=s'     => \$opt{'jobs'},
	'timeout=s'  => \$opt{'timeout'},
	'no-restart' => sub { $opt{'restart'} = 0 },
	'once'       => \$opt{'once'},
	'dry-run'    => \$opt{'dry_run'},
	'help'       => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'jobs'} =~ /^\d+$/ && $opt{'jobs'} >= 1 && $opt{'jobs'} <= 8;
usage(2) unless $opt{'timeout'} =~ /^\d+$/ && $opt{'timeout'} > 0;

my ($root, $common) = eval { LandQueue::repo() };
if (!$root) {
	my $why = $@ || 'not inside a git worktree';
	$why =~ s/\s+$//;
	print STDERR "land_promote: $why\n";
	exit 2;
}
my $primary = LandQueue::primary_checkout($root);
my $dir = LandQueue::queue_dir($common);
my $qa_root = ($ENV{'JAWNOS_QA_ROOT'} || (($ENV{'HOME'} || '.') . '/jawnos-qa'));
$qa_root =~ s{/+$}{};
my $promote_root = "$qa_root/promote";

# The coordinator's lock is the wave lock. A promotion that runs while a wave
# is integrating would read a trunk that is about to move.
my $lock;
if (!$opt{'dry_run'}) {
	open($lock, '>>', "$common/jawnos-land.lock") or do {
		print STDERR "land_promote: cannot open the land lock: $!\n";
		exit 2;
	};
	$lock->autoflush(1);
	unless (flock($lock, LOCK_EX | LOCK_NB)) {
		print STDERR "land_promote: a landing wave holds the lock; nothing to do\n";
		exit 0;
	}
}

my ($frc, $fout) = git_in($primary, 'fetch', 'origin', '--quiet');
if ($frc != 0) {
	print STDERR "land_promote: fetch failed: $fout\n";
	exit 0;
}

my $working = "origin/$opt{'trunk'}";
my $main = "origin/$opt{'main'}";
if (!ref_exists($working)) {
	if ($opt{'dry_run'}) {
		print "land_promote: would create $working from $main\n";
		exit 0;
	}
	my ($crc, $cout) = push_tested($primary, "$main:refs/heads/$opt{'trunk'}");
	if ($crc != 0) {
		print STDERR "land_promote: could not create $working from $main: $cout\n";
		event('create_failed', working => '', main => '');
		exit 0;
	}
	git_in($primary, 'fetch', 'origin', '--quiet');
	if (!ref_exists($working)) {
		print STDERR "land_promote: $working still does not exist after the create\n";
		event('create_failed', working => '', main => '');
		exit 0;
	}
}

my ($arc) = git_in($primary, 'merge-base', '--is-ancestor', $main, $working);
if ($arc != 0) {
	print STDERR "land_promote: $main is not an ancestor of $working; reconcile by hand\n";
	event('diverged', working => ref_sha($working), main => ref_sha($main));
	exit 0;
}

my (undef, $ahead) = git_in($primary, 'rev-list', '--count', "$main..$working");
if (($ahead // '') eq '0') {
	print "land_promote: $working has nothing new for $main\n";
	event('nothing', working => ref_sha($working), main => ref_sha($main));
	exit 0;
}

my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
my $wt = "$promote_root/$stamp";
my $log = "$qa_root/promote-$stamp.log";

# The coordinator records the tip and the scope of the suite it passed before it
# pushes. Only a tip it tested with the FULL suite is promoted without another
# run: a scoped working gate is the fast gate, and main is the release branch,
# so a release always runs everything. A hand push (no record) is the same.
my $working_sha = ref_sha($working);
my $main_sha = ref_sha($main);
my $tested = LandQueue::tested_read($dir);
my $recorded = ($tested && ($tested->{'sha'} // '') eq $working_sha) ? 1 : 0;
my $trusted = ($recorded && ($tested->{'scope'} // '') eq 'full') ? 1 : 0;

if ($opt{'dry_run'}) {
	print "land_promote: would " . ($trusted ? 'fast-forward' : 'test')
		. " $working ($ahead commit(s)) and fast-forward $main\n";
	exit 0;
}

my $worktree_made = 0;
if ($trusted) {
	print "land_promote: $working is the tip the queue tested with the full suite; the suite is not repeated\n";
}
else {
	print "land_promote: $working was not fully tested, so the release branch gets the full suite\n"
		if $recorded;
	make_path($promote_root) unless -d $promote_root;
	my ($wrc, $wout) = git_in($primary, 'worktree', 'add', '--detach', $wt, $working);
	if ($wrc != 0) {
		print STDERR "land_promote: could not create the promotion worktree: $wout\n";
		event('worktree_failed', working => $working_sha, main => $main_sha);
		exit 0;
	}
	$worktree_made = 1;

	my ($src, $sout) = LandQueue::run_in($wt,
		'timeout', $opt{'timeout'}, $^X, "$wt/scripts/run_tests.pl", '--jobs', $opt{'jobs'});
	write_file($log, $sout);
	if ($src != 0) {
		git_in($primary, 'worktree', 'remove', '--force', $wt);
		print STDERR "land_promote: the suite is red on $working; nothing moved (exit $src, log $log)\n";
		event('red', working => $working_sha, main => $main_sha, suite_exit => $src, log => $log);
		exit 0;
	}
}

my $version_at = $worktree_made ? $wt : $primary;
my $version_ref = $worktree_made ? 'HEAD' : $working_sha;
my (undef, $version) = git_in($version_at, 'show', "$version_ref:VERSION");
$version = '' unless defined $version;
$version =~ s/\s+//g;
my (undef, $subject) = git_in($version_at, 'log', '-1', '--format=%s', $version_ref);
$subject = '' unless defined $subject;
$subject =~ s/^\s*v?\d+\.\d+\.\d+\s*-\s*//;
$subject =~ s/\s+$//;

my ($prc, $pout) = push_tested($primary, "$working:refs/heads/$opt{'main'}");
if ($prc != 0) {
	git_in($primary, 'worktree', 'remove', '--force', $wt) if $worktree_made;
	print STDERR "land_promote: the main push was refused: $pout\n";
	event('push_rejected', working => $working_sha, main => $main_sha, version => $version);
	exit 0;
}

my ($applied, $apply_why, $restart) = apply_primary($primary, $opt{'main'}, $opt{'restart'} ? $version : '', $subject);
if (!$applied) {
	print STDERR "land_promote: promoted $working_sha, but the primary checkout did not take it: $apply_why\n";
}
elsif ($restart eq 'failed') {
	print STDERR "land_promote: promoted $working_sha, but the restart failed\n";
}
else {
	print "land_promote: promoted $opt{'main'} to $working_sha" . (length $version ? " (v$version)" : '') . "\n";
}
event('promoted',
	working => $working_sha, main => $main_sha, version => $version,
	suite => $trusted ? 'recorded' : 'ran',
	apply => $applied ? 'ok' : 'blocked', restart => $restart,
);
git_in($primary, 'worktree', 'remove', '--force', $wt) if $worktree_made;
exit 0;

# The pre-push hook is the gate for a hand push. This job already ran the suite
# on the tree it is promoting (or, for the bootstrap, pushes the tip of main,
# which the queue tested), so tell the hook not to run it a second time: a
# flaky repeat would block a green promotion. The coordinator and agent_land
# mark their pushes the same way.
sub push_tested {
	my ($cwd, $spec) = @_;
	local $ENV{'JAWNOS_SUITE_ALREADY_RUN'} = 1;
	return git_in($cwd, 'push', 'origin', $spec);
}

sub apply_primary {
	my ($primary, $main, $version, $subject) = @_;
	my ($frc, $fout) = git_in($primary, 'fetch', 'origin', '--quiet');
	return (0, "fetch failed: $fout", 'skipped') if $frc != 0;
	my (undef, $dirty) = git_in($primary, 'status', '--porcelain', '--untracked-files=no');
	return (0, "the primary checkout has uncommitted changes:\n$dirty", 'skipped') if length $dirty;
	my ($mrc, $mout) = git_in($primary, 'merge', '--ff-only', "origin/$main");
	return (0, "fast-forward failed: $mout", 'skipped') if $mrc != 0;
	return (1, '', 'skipped') unless $opt{'restart'};
	my $script = "$primary/scripts/restart.pl";
	return (1, '', 'skipped') unless -f $script;
	my $reason = 'promotion' . (length $version ? " v$version" : '') . (length $subject ? " - $subject" : '');
	my ($rrc, $rout) = LandQueue::run_cmd($^X, $script, '--reason', $reason);
	return (1, '', $rrc == 0 ? 'ok' : 'failed');
}

sub event {
	my ($result, %a) = @_;
	LandQueue::event($dir, { event => 'promotion', result => $result, %a });
}

sub ref_exists {
	my ($ref) = @_;
	my ($rc) = git_in($primary, 'rev-parse', '--verify', '--quiet', $ref);
	return $rc == 0;
}

sub ref_sha {
	my ($ref) = @_;
	my (undef, $sha) = git_in($primary, 'rev-parse', '--verify', $ref);
	$sha =~ s/\s+//g;
	return $sha;
}

sub git_in {
	my ($cwd, @cmd) = @_;
	return LandQueue::run_in($cwd, 'git', @cmd);
}

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
land_promote.pl - test working and fast-forward main to it
  perl scripts/land_promote.pl [--once] [--trunk working] [--main main]
                               [--jobs 2] [--timeout 1800] [--no-restart]
                               [--dry-run]
  The working branch is the coordinator's trunk. This job holds the land lock,
  promotes a tip the queue recorded as tested without repeating the suite, and
  otherwise runs the full suite first. Only then does it fast-forward main and
  restart the primary checkout. It never rebases or integrates a ticket.
USAGE
	exit $code;
}
