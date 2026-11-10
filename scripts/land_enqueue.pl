#!/usr/bin/perl

# Put one committed branch in the landing queue.
#
#   perl scripts/land_enqueue.pl
#   perl scripts/land_enqueue.pl --branch agent/pen --reason "the pen fix"
#   perl scripts/land_enqueue.pl --json
#
# Run this from the worktree whose branch you want landed. It validates the
# branch, backs it up to origin (so the queue can lose nothing), and writes a
# ticket in the git common dir. The coordinator (scripts/land_coordinator.pl)
# drains the queue; this script never pushes the trunk and never restarts.
#
# A ticket is a snapshot of the committed sha. Re-running it for the same branch
# updates that snapshot and keeps the queue position. A branch already running
# is refused, not queued twice.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Sys::Hostname qw(hostname);

require "$FindBin::Bin/land_lib.pl";

my %opt = (
	'trunk'     => 'main',
	'max_queue' => 12,
);
GetOptions(
	'branch=s'  => \$opt{'branch'},
	'reason=s'  => \$opt{'reason'},
	'agent=s'   => \$opt{'agent'},
	'trunk=s'   => \$opt{'trunk'},
	'max-queue=s' => \$opt{'max_queue'},
	'json'      => \$opt{'json'},
	'help'      => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'max_queue'} =~ /^\d+$/ && $opt{'max_queue'} > 0;

my ($root, $common) = eval { LandQueue::repo() };
if (!$root) {
	my $why = $@ || 'not inside a git worktree';
	$why =~ s/\s+$//;
	finish(1, 'not_repo', $why);
}

my ($wrc, $wlist) = LandQueue::run_cmd('git', '-C', $root, 'worktree', 'list', '--porcelain');
my ($primary) = ($wlist // '') =~ /^worktree\s+(.+)$/m;
if (defined $primary && length $primary) {
	$primary =~ s/\s+$//;
	if (abs_path($root) eq abs_path($primary)) {
		finish(1, 'primary', "this is the primary checkout at $primary; "
			. 'enqueue from the worktree whose branch you want landed');
	}
}

my $branch = $opt{'branch'};
if (!defined $branch || !length $branch) {
	my ($crc, $b) = LandQueue::run_cmd('git', '-C', $root, 'rev-parse', '--abbrev-ref', 'HEAD');
	finish(1, 'branch', "cannot read the current branch: $b") if $crc != 0;
	$branch = $b;
}
finish(1, 'trunk', "$branch is the trunk; enqueue a branch that is not $opt{'trunk'}")
	if $branch eq $opt{'trunk'};

my ($vrc, $valid) = LandQueue::run_cmd('git', '-C', $root, 'check-ref-format', '--branch', $branch);
finish(1, 'branch', "'$branch' is not a valid branch name") if $vrc != 0;

my ($drc, $dirty) = LandQueue::run_cmd('git', '-C', $root, 'status', '--porcelain');
finish(1, 'dirty', "the worktree has uncommitted work; commit it first:\n$dirty") if length $dirty;

my ($src, $sha) = LandQueue::run_cmd('git', '-C', $root, 'rev-parse', '--verify', "refs/heads/$branch");
finish(1, 'branch', "$branch has no commit: $sha") if $src != 0;

my ($frc, $fetch) = LandQueue::run_cmd('git', '-C', $root, 'fetch', 'origin', '--quiet');
finish(1, 'fetch', "git fetch failed: $fetch") if $frc != 0;

my ($arc, $ancestor) = LandQueue::run_cmd('git', '-C', $root, 'merge-base', '--is-ancestor', $sha, "origin/$opt{'trunk'}");
finish(1, 'nothing', "$branch is already merged into origin/$opt{'trunk'}") if $arc == 0;

my (undef, $base) = LandQueue::run_cmd('git', '-C', $root, 'merge-base', "origin/$opt{'trunk'}", $sha);
finish(1, 'branch', "cannot find the merge base of $branch with origin/$opt{'trunk'}") unless defined $base && length $base;

my (undef, $ahead) = LandQueue::run_cmd('git', '-C', $root, 'rev-list', '--count', "origin/$opt{'trunk'}..$sha");
finish(1, 'nothing', "$branch has no commits ahead of origin/$opt{'trunk'}") unless ($ahead // '') =~ /^\d+$/ && $ahead > 0;

my ($hrc, $hooks) = LandQueue::run_cmd('git', '-C', $root, 'config', '--get', 'core.hooksPath');
if ($hrc != 0 || !length $hooks) {
	finish(1, 'hooks', 'core.hooksPath is not set, so the commit guards never ran. '
		. "Set it once per clone: git config core.hooksPath .githooks");
}

my $dir = LandQueue::queue_dir($common);

# Re-enqueueing the same branch is how a worktree refreshes its snapshot after a
# fix: update the sha and the reason, keep the place in line. A running ticket is
# already being landed and must not change under the coordinator.
my $existing = LandQueue::find_ticket($dir, branch => $branch, live => 1);
if ($existing) {
	if (($existing->{'state'} // '') eq 'running') {
		finish(1, 'running', "$branch is already landing as ticket $existing->{'id'}");
	}
	$existing->{'sha'}        = $sha;
	$existing->{'base'}       = $base;
	$existing->{'reason'}     = $opt{'reason'} if defined $opt{'reason'};
	$existing->{'agent'}      = $opt{'agent'} if defined $opt{'agent'};
	$existing->{'not_before'} = 0;
	LandQueue::write_ticket($dir, $existing);
	my $pos = LandQueue::position($dir, $existing->{'id'});
	output($existing, $pos, "refreshed $branch in ticket $existing->{'id'} (position $pos)");
	exit 0;
}

my $live = LandQueue::live_count($dir);
finish(1, 'queue_full', "the landing queue already holds $live ticket(s); land one and enqueue again")
	if $live >= $opt{'max_queue'};

# The backup is what makes a queue timeout a pause rather than a loss. It needs
# no lock and collides with nobody, so it happens before the ticket exists.
my ($prc, $pout) = LandQueue::run_cmd('git', '-C', $root, 'push', '--no-verify',
	'--force-with-lease', 'origin', "$sha:refs/heads/$branch");
print STDERR "land_enqueue: the branch backup did not go through (the coordinator can still use the local branch): $pout\n"
	if $prc != 0;

my $id = LandQueue::next_id($dir);
my $t = {
	id           => $id,
	branch       => $branch,
	sha          => $sha,
	base         => $base,
	worktree     => $root,
	box          => hostname(),
	agent        => defined $opt{'agent'} ? $opt{'agent'}
		: (defined $ENV{'JAWNOS_AGENT'} && length $ENV{'JAWNOS_AGENT'} ? $ENV{'JAWNOS_AGENT'}
		: ($ENV{'USER'} // 'unknown')),
	reason       => $opt{'reason'} // '',
	submitted_at => time,
	state        => 'queued',
	attempts     => 0,
	not_before   => 0,
	pid          => 0,
	started_at   => 0,
	finished_at  => 0,
	result       => {},
};
LandQueue::write_ticket($dir, $t);
my $pos = LandQueue::position($dir, $id);
LandQueue::event($dir, {
	event => 'enqueued', id => $id, branch => $branch, sha => $sha,
	box => $t->{'box'}, agent => $t->{'agent'},
});
output($t, $pos, "queued $branch as ticket $id (position $pos)");
exit 0;

sub output {
	my ($t, $pos, $line) = @_;
	if ($opt{'json'}) {
		print JSON::PP->new->canonical->encode({
			ok => 1, id => $t->{'id'}, branch => $t->{'branch'}, sha => $t->{'sha'},
			position => $pos,
		}), "\n";
		print STDERR "land_enqueue: $line\n";
	}
	else {
		print "land_enqueue: $line\n";
	}
}

sub finish {
	my ($code, $class, $message) = @_;
	if ($opt{'json'}) {
		print JSON::PP->new->canonical->encode({
			ok => 0, code => $code, reason_class => $class, message => $message // '',
		}), "\n";
	}
	print STDERR "land_enqueue: refused: $message\n" if $code != 0;
	exit $code;
}

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
land_enqueue.pl - put one committed branch in the landing queue
  perl scripts/land_enqueue.pl [--branch B] [--reason TEXT] [--agent NAME]
                               [--trunk main] [--max-queue 12] [--json]
  Run it from the worktree whose branch you want landed.
USAGE
	exit $code;
}
