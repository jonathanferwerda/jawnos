#!/usr/bin/perl

# Put one committed branch in the landing queue.
#
#   perl scripts/land_enqueue.pl
#   perl scripts/land_enqueue.pl --branch agent/pen --reason "the pen fix"
#   perl scripts/land_enqueue.pl --authority dev
#   perl scripts/land_enqueue.pl --json
#   perl scripts/land_enqueue.pl --wait --timeout 300
#
# Run this from the worktree whose branch you want landed. It validates the
# branch, backs it up to origin (so the queue can lose nothing), and writes a
# ticket. With --authority the ticket is written by the authority's copy of this
# script instead, over ssh: the worker pushes the branch, the authority owns the
# queue and the trunk. A local authority is just the primary's copy, no sshd.
#
# The coordinator (scripts/land_coordinator.pl) drains the queue; this script
# never pushes the trunk and never restarts. A ticket is a snapshot of the
# committed sha. Re-running it for the same branch updates that snapshot and
# keeps the queue position. A branch already running is refused, not queued
# twice.
#
# --wait asks for the verdict in this turn: it waits for the ticket to land or be
# refused, or for --timeout seconds to pass (default 300). The exit is then 0
# landed, 1 refused and 2 no verdict. Without --wait the exit is 0 once the
# ticket exists; read the verdict later with land_status.pl --branch.

use strict;
use warnings;

# The wait prints its verdict after the queued line; do not let a pipe reorder them.
$| = 1;

use Cwd qw(abs_path);
use FindBin;
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Sys::Hostname qw(hostname);

require "$FindBin::Bin/land_lib.pl";

my %opt = (
	'trunk'          => 'main',
	'max_queue'      => 12,
	'timeout'        => 300,
	'authority_port' => 8022,
	'authority_root' => '$HOME/jawnos',
);
GetOptions(
	'branch=s'       => \$opt{'branch'},
	'reason=s'       => \$opt{'reason'},
	'agent=s'        => \$opt{'agent'},
	'trunk=s'        => \$opt{'trunk'},
	'max-queue=s'    => \$opt{'max_queue'},
	'authority=s'    => \$opt{'authority'},
	'authority-root=s' => \$opt{'authority_root'},
	'authority-port=s' => \$opt{'authority_port'},
	'remote'         => \$opt{'remote'},
	'sha=s'          => \$opt{'sha'},
	'box=s'          => \$opt{'box'},
	'json'           => \$opt{'json'},
	'wait'           => \$opt{'wait'},
	'timeout=s'      => \$opt{'timeout'},
	'help'           => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'max_queue'} =~ /^\d+$/ && $opt{'max_queue'} > 0;
usage(2) unless $opt{'authority_port'} =~ /^\d+$/;
usage(2) unless $opt{'timeout'} =~ /^\d+$/ && $opt{'timeout'} > 0;
finish(2, 'usage', '--wait and --json cannot be combined; wait without --json, '
	. 'or read the verdict with land_status.pl --json')
	if $opt{'wait'} && $opt{'json'};

# The authority's own half: the worker has already pushed, so there is no local
# branch to inspect and no primary-checkout rule. Keep the same validation the
# local path uses where it can, and add the two things only the authority can
# see: the commit's identity and that origin really has that sha.
if ($opt{'remote'}) {
	remote_enqueue();
	exit 0;
}

my ($branch, $remote, $primary) = local_enqueue();
exit wait_for_verdict($branch, $remote, $primary) if $opt{'wait'};
exit 0;

sub repo_or_finish {
	my ($root, $common) = eval { LandQueue::repo() };
	if (!$root) {
		my $why = $@ || 'not inside a git worktree';
		$why =~ s/\s+$//;
		finish(1, 'not_repo', $why);
	}
	return ($root, $common, LandQueue::primary_checkout($root));
}

sub local_enqueue {
	my ($root, $common, $primary) = repo_or_finish();

	if (abs_path($root) eq abs_path($primary)) {
		finish(1, 'primary', "this is the primary checkout at $primary; "
			. 'enqueue from the worktree whose branch you want landed');
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

	my ($arc, $ancestor) = LandQueue::run_cmd('git', '-C', $root, 'merge-base', '--is-ancestor',
		$sha, "origin/$opt{'trunk'}");
	finish(1, 'nothing', "$branch is already merged into origin/$opt{'trunk'}") if $arc == 0;

	my (undef, $base) = LandQueue::run_cmd('git', '-C', $root, 'merge-base', "origin/$opt{'trunk'}", $sha);
	finish(1, 'branch', "cannot find the merge base of $branch with origin/$opt{'trunk'}")
		unless defined $base && length $base;

	my (undef, $ahead) = LandQueue::run_cmd('git', '-C', $root, 'rev-list', '--count',
		"origin/$opt{'trunk'}..$sha");
	finish(1, 'nothing', "$branch has no commits ahead of origin/$opt{'trunk'}")
		unless ($ahead // '') =~ /^\d+$/ && $ahead > 0;

	my ($hrc, $hooks) = LandQueue::run_cmd('git', '-C', $root, 'config', '--get', 'core.hooksPath');
	if ($hrc != 0 || !length $hooks) {
		finish(1, 'hooks', 'core.hooksPath is not set, so the commit guards never ran. '
			. "Set it once per clone: git config core.hooksPath .githooks");
	}

	# The backup is what makes a queue timeout a pause rather than a loss. It
	# needs no lock and collides with nobody, so it happens before the ticket.
	my ($prc, $pout) = LandQueue::run_cmd('git', '-C', $root, 'push', '--no-verify',
		'--force-with-lease', 'origin', "$sha:refs/heads/$branch");
	print STDERR "land_enqueue: the branch backup did not go through (the authority can still fetch it): $pout\n"
		if $prc != 0;

	if ($opt{'authority'}) {
		my $arc = enqueue_on_authority($primary, $branch, $sha);
		return ($branch, 1, $primary) if $arc == 0;
		exit $arc;
	}

	my $dir = LandQueue::queue_dir($common);
	write_or_refresh($dir, {
		branch => $branch, sha => $sha, base => $base,
		worktree => $root, remote => 0,
	});
	return ($branch, 0, $primary);
}

# One wait, whichever queue owns the ticket. The authority path asks its own
# land_status over the same rail the enqueue used; a local ticket is read here.
# The status script owns the polling and the 0/1/2 verdict codes.
sub wait_for_verdict {
	my ($branch, $remote, $primary) = @_;
	my @args = ('--branch', $branch, '--wait', '--timeout', $opt{'timeout'});
	my ($rc, $out, $err);
	if ($remote) {
		($rc, $out, $err) = LandQueue::run_authority(
			host    => $opt{'authority'},
			port    => $opt{'authority_port'},
			root    => $opt{'authority_root'},
			script  => 'scripts/land_status.pl',
			args    => \@args,
			primary => $primary,
		);
	}
	else {
		($rc, $out, $err) = LandQueue::run_cmd_split($^X, "$FindBin::Bin/land_status.pl", @args);
	}
	$out =~ s/\s+$//;
	$err =~ s/\s+$//;
	print STDOUT "$out\n" if length $out;
	print STDERR "$err\n" if length $err;
	return $rc;
}

sub enqueue_on_authority {
	my ($primary, $branch, $sha) = @_;
	my @fwd = (
		'--remote',
		'--branch', $branch,
		'--sha', $sha,
		'--box', hostname(),
		'--agent', agent_name(),
		'--reason', ($opt{'reason'} // ''),
		'--max-queue', $opt{'max_queue'},
	);
	push @fwd, '--json' if $opt{'json'};

	print STDERR "land_enqueue: pushed $branch; enqueueing on $opt{'authority'}\n"
		unless $opt{'json'} || LandQueue::is_local_host($opt{'authority'});

	my ($arc, $aout, $aerr) = LandQueue::run_authority(
		host    => $opt{'authority'},
		port    => $opt{'authority_port'},
		root    => $opt{'authority_root'},
		script  => 'scripts/land_enqueue.pl',
		args    => \@fwd,
		primary => $primary,
	);
	print STDOUT $aout if length $aout;
	print STDERR $aerr if length $aerr;
	if ($arc == 255) {
		print STDERR "land_enqueue: the authority $opt{'authority'} could not be reached; "
			. "the branch is safe on origin/$branch\n";
	}
	return $arc;
}

sub remote_enqueue {
	my ($root, $common, $primary) = repo_or_finish();

	my $branch = $opt{'branch'} // '';
	my $sha    = $opt{'sha'} // '';
	finish(1, 'usage', '--remote needs --branch and --sha') unless length $branch && length $sha;
	finish(1, 'trunk', "$branch is the trunk") if $branch eq $opt{'trunk'};

	my ($vrc) = LandQueue::run_cmd('git', '-C', $root, 'check-ref-format', '--branch', $branch);
	finish(1, 'branch', "'$branch' is not a valid branch name") if $vrc != 0;

	my ($frc, $fetch) = LandQueue::run_cmd('git', '-C', $root, 'fetch', 'origin', '--quiet');
	finish(1, 'fetch', "git fetch failed: $fetch") if $frc != 0;

	my ($brc, $origin_sha) = LandQueue::run_cmd('git', '-C', $root, 'rev-parse', '--verify',
		"refs/remotes/origin/$branch");
	finish(1, 'branch', "origin/$branch is not on origin; the worker must push it first: $origin_sha")
		if $brc != 0;
	finish(1, 'stale', "origin/$branch is $origin_sha, not the enqueued $sha; push it again")
		if $origin_sha ne $sha;

	my ($crc, $cout) = LandQueue::run_cmd('git', '-C', $root, 'cat-file', '-e', "$sha^{commit}");
	finish(1, 'stale', "the commit $sha is not in the repository: $cout") if $crc != 0;

	# The pre-commit hook guards the worker's own clone. A remote commit arrives
	# without that hook ever running here, so the authority checks the identity
	# the house publishes as before it accepts the ticket.
	if (!$ENV{'JAWNOS_ALLOW_FOREIGN_COMMIT'}) {
		my (undef, $name)  = LandQueue::run_cmd('git', '-C', $root, 'config', 'user.name');
		my (undef, $email) = LandQueue::run_cmd('git', '-C', $root, 'config', 'user.email');
		if (length $name && length $email) {
			my (undef, $idents) = LandQueue::run_cmd('git', '-C', $root, 'log', '-1',
				'--format=%an%x00%ae%x00%cn%x00%ce', $sha);
			my @id = split /\0/, ($idents // '');
			if (@id >= 4 && ($id[0] ne $name || $id[1] ne $email || $id[2] ne $name || $id[3] ne $email)) {
				finish(1, 'identity', "the commit is authored/committed as "
					. "$id[0] <$id[1]> / $id[2] <$id[3]>, but this house publishes as "
					. "$name <$email>. Re-commit it as the house, or set "
					. 'JAWNOS_ALLOW_FOREIGN_COMMIT=1 on the authority for an import');
			}
		}
	}

	my ($arc) = LandQueue::run_cmd('git', '-C', $root, 'merge-base', '--is-ancestor',
		$sha, "origin/$opt{'trunk'}");
	finish(1, 'nothing', "$branch is already merged into origin/$opt{'trunk'}") if $arc == 0;

	my (undef, $base) = LandQueue::run_cmd('git', '-C', $root, 'merge-base', "origin/$opt{'trunk'}", $sha);
	finish(1, 'branch', "cannot find the merge base of $branch with origin/$opt{'trunk'}")
		unless defined $base && length $base;

	my (undef, $ahead) = LandQueue::run_cmd('git', '-C', $root, 'rev-list', '--count',
		"origin/$opt{'trunk'}..$sha");
	finish(1, 'nothing', "$branch has no commits ahead of origin/$opt{'trunk'}")
		unless ($ahead // '') =~ /^\d+$/ && $ahead > 0;

	my ($hrc, $hooks) = LandQueue::run_cmd('git', '-C', $root, 'config', '--get', 'core.hooksPath');
	if ($hrc != 0 || !length $hooks) {
		finish(1, 'hooks', 'core.hooksPath is not set on the authority, so its commit guards never run. '
			. "Set it once per clone: git config core.hooksPath .githooks");
	}

	my $dir = LandQueue::queue_dir($common);
	write_or_refresh($dir, {
		branch => $branch, sha => $sha, base => $base,
		worktree => '', remote => 1,
		box => $opt{'box'} // 'remote',
	});
}

# The same branch in the queue is a refreshed snapshot, not a second ticket. A
# running ticket is already in the coordinator's hands and must not move.
sub write_or_refresh {
	my ($dir, $w) = @_;
	my $branch = $w->{'branch'};
	my $existing = LandQueue::find_ticket($dir, branch => $branch, live => 1);
	if ($existing) {
		if (($existing->{'state'} // '') eq 'running') {
			finish(1, 'running', "$branch is already landing as ticket $existing->{'id'}");
		}
		$existing->{'sha'}        = $w->{'sha'};
		$existing->{'base'}       = $w->{'base'};
		$existing->{'reason'}     = $opt{'reason'} if defined $opt{'reason'};
		$existing->{'agent'}      = agent_name();
		$existing->{'box'}        = $w->{'box'} if defined $w->{'box'};
		$existing->{'remote'}     = $w->{'remote'};
		$existing->{'worktree'}   = $w->{'worktree'} if defined $w->{'worktree'};
		$existing->{'not_before'} = 0;
		LandQueue::write_ticket($dir, $existing);
		my $pos = LandQueue::position($dir, $existing->{'id'});
		output($existing, $pos, "refreshed $branch in ticket $existing->{'id'} (position $pos)");
		return;
	}

	my $live = LandQueue::live_count($dir);
	finish(1, 'queue_full', "the landing queue already holds $live ticket(s); land one and enqueue again")
		if $live >= $opt{'max_queue'};

	my $id = LandQueue::next_id($dir);
	my $t = {
		id           => $id,
		branch       => $branch,
		sha          => $w->{'sha'},
		base         => $w->{'base'},
		worktree     => $w->{'worktree'},
		remote       => $w->{'remote'} ? 1 : 0,
		box          => $w->{'box'} // hostname(),
		agent        => agent_name(),
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
		event => 'enqueued', id => $id, branch => $branch, sha => $w->{'sha'},
		box => $t->{'box'}, agent => $t->{'agent'}, remote => $t->{'remote'},
	});
	output($t, $pos, "queued $branch as ticket $id (position $pos)");
}

sub agent_name {
	return $opt{'agent'} if defined $opt{'agent'} && length $opt{'agent'};
	return $ENV{'JAWNOS_AGENT'} if defined $ENV{'JAWNOS_AGENT'} && length $ENV{'JAWNOS_AGENT'};
	return $ENV{'USER'} // 'unknown';
}

sub output {
	my ($t, $pos, $line) = @_;
	# The ticket is not the landing: say where the verdict comes from, so nobody
	# deletes the worktree while the coordinator is still working on it.
	my $next = $opt{'wait'}
		? "waiting up to $opt{'timeout'}s for the verdict"
		: 'the coordinator drains it within a minute; '
			. "`perl scripts/land_status.pl --branch $t->{'branch'}` is the verdict; "
			. 'keep the worktree until it lands';
	$next = 'the authority drains it; '
		. "`perl scripts/land_status.pl --authority <host> --branch $t->{'branch'}` is the verdict; "
		. 'keep the worktree until it lands'
		if $t->{'remote'} && !$opt{'wait'};
	if ($opt{'json'}) {
		print JSON::PP->new->canonical->encode({
			ok => 1, id => $t->{'id'}, branch => $t->{'branch'}, sha => $t->{'sha'},
			position => $pos, remote => $t->{'remote'} ? 1 : 0,
		}), "\n";
		print STDERR "land_enqueue: $line\nland_enqueue: $next\n";
	}
	else {
		print "land_enqueue: $line\nland_enqueue: $next\n";
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
                               [--wait] [--timeout 300]
                               [--authority HOST] [--authority-root PATH]
                               [--authority-port 8022]
  --wait holds this call until the ticket lands (exit 0), is refused (exit 1)
  or --timeout seconds pass (exit 2). --json cannot be combined with --wait.
  Run it from the worktree whose branch you want landed. --authority hands the
  ticket to another checkout (default root $HOME/jawnos there, ssh port 8022).
  --remote is the authority's own half and is normally not run by hand.
USAGE
	exit $code;
}
