#!/usr/bin/perl

# Drain the landing queue in waves.
#
#   perl scripts/land_coordinator.pl --drain
#   perl scripts/land_coordinator.pl --once --train-size 4 --jobs 4
#   perl scripts/land_coordinator.pl --dry-run
#
# One coordinator per checkout (the lock is in the git common dir). It takes the
# oldest tickets, rebases each branch onto the growing tip, bumps VERSION per
# branch, regenerates the generated indexes once at the tip, runs the suite ONCE
# on the integrated tree, pushes that tree atomically and restarts once. A wave
# that is red is retried once, then split into single-ticket waves so one bad
# branch cannot hold the rest.
#
# Why a train: the suite is a couple of minutes and the trunk is one ref. Twelve
# agents do not need twelve suites; they need two or three, and they need the
# trunk to move only when the integrated tree is green.
#
# The coordinator is not a manager utility job: it must be able to land the fix
# when the tree is broken. Run it from systemd (scripts/systemd/).
#
# Exit: 0 drained (some tickets may be refused; the queue is the truth) -
#       2 bad usage. A held coordinator or landing lock is a 0 with a message,
#       because the timer will try again.

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use Fcntl qw(:flock);
use File::Path qw(make_path rmtree);
use File::Temp qw(tempdir tempfile);
use FindBin;
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use Time::HiRes qw(time);

require "$FindBin::Bin/land_lib.pl";

my %opt = (
	'trunk'         => 'main',
	'train_size'    => 1,
	'jobs'          => 4,
	'suite_retries' => 1,
	'restart'       => 1,
	'wait'          => 0,
	'once'          => 0,
);
GetOptions(
	'trunk=s'        => \$opt{'trunk'},
	'train-size=s'   => \$opt{'train_size'},
	'jobs=s'         => \$opt{'jobs'},
	'suite-retries=s'=> \$opt{'suite_retries'},
	'no-restart'     => sub { $opt{'restart'} = 0 },
	'wait=s'         => \$opt{'wait'},
	'once'           => \$opt{'once'},
	'dry-run'        => \$opt{'dry_run'},
	'help'           => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'train_size'} =~ /^\d+$/ && $opt{'train_size'} >= 1 && $opt{'train_size'} <= 8;
usage(2) unless $opt{'jobs'} =~ /^\d+$/ && $opt{'jobs'} >= 1 && $opt{'jobs'} <= 8;
usage(2) unless $opt{'suite_retries'} =~ /^\d+$/ && $opt{'suite_retries'} <= 3;
usage(2) unless $opt{'wait'} =~ /^\d+$/;

$ENV{'GIT_EDITOR'} = 'true';

my ($root, $common) = eval { LandQueue::repo() };
if (!$root) {
	my $why = $@ || 'not inside a git worktree';
	$why =~ s/\s+$//;
	logit($why);
	exit 2;
}
my $dir = LandQueue::queue_dir($common);
my $primary = primary_checkout($root);

my $clock;
open($clock, '>>', "$common/land-coordinator.lock") or do {
	logit("cannot open $common/land-coordinator.lock: $!");
	exit 2;
};
$clock->autoflush(1);
unless (flock($clock, LOCK_EX | LOCK_NB)) {
	logit('another coordinator drain is running; nothing to do');
	exit 0;
}

my @reaped = LandQueue::reap($dir);
logit('requeued dead running ticket(s): ' . join(', ', @reaped)) if @reaped;

# Best effort before selection, so a hot-file ticket enqueued since the last
# drain is seen as hot. A failure is not fatal: run_wave fetches again.
git_in($root, 'fetch', 'origin', '--quiet');

my $force_single = 0;
my $waves = 0;
while (1) {
	my $wave = select_wave($root, $dir, $opt{'train_size'}, $force_single);
	last unless @$wave;

	if ($opt{'dry_run'}) {
		logit('would land: ' . join(', ', map { $_->{'id'} . ' ' . $_->{'branch'} } @$wave));
		last;
	}

	my $result = run_wave($root, $common, $primary, $dir, $wave, \%opt);
	$waves++;

	if (($result->{'result'} // '') eq 'red' && @$wave > 1) {
		# One bad branch must not hold the rest. Keep the drain single-file for
		# the remainder; the next timer run starts a fresh train.
		$force_single = 1;
	}
	last if $opt{'once'};
	last if $result->{'stop'};
}

logit("drained $waves wave(s)") if $waves;
exit 0;

# --- the wave --------------------------------------------------------------

sub select_wave {
	my ($root, $dir, $size, $force_single) = @_;
	$size = 1 if $force_single;
	my @queued = grep {
		($_->{'state'} // '') eq 'queued' && LandQueue::due($_)
	} @{ LandQueue::tickets($dir) };

	my @pick;
	my $hot = 0;
	for my $t (@queued) {
		last if @pick >= $size;
		if (LandQueue::is_hot_ticket($root, $t)) {
			next if $hot;
			$hot = 1;
		}
		push @pick, $t;
	}
	return \@pick;
}

sub run_wave {
	my ($root, $common, $primary, $dir, $wave, $opt) = @_;

	my $lock = land_lock($common, $opt->{'wait'});
	if (!$lock) {
		logit('the landing gate is held by another process; the queue is safe, try again later');
		return { result => 'busy', stop => 1 };
	}

	my $now = time;
	for my $t (@$wave) {
		$t->{'state'}      = 'running';
		$t->{'pid'}        = $$;
		$t->{'started_at'} = $now;
		$t->{'attempts'}   = ($t->{'attempts'} // 0) + 1;
		LandQueue::write_ticket($dir, $t);
		LandQueue::event($dir, {
			event => 'started', id => $t->{'id'}, branch => $t->{'branch'},
			wave => [ map { $_->{'id'} } @$wave ],
		});
	}

	my ($frc, $fout) = git_in($root, 'fetch', 'origin', '--quiet');
	if ($frc != 0) {
		requeue($dir, $wave, 60);
		release($lock);
		logit("fetch failed: $fout");
		return { result => 'fetch_failed', stop => 1 };
	}

	# The train must not live under /tmp: the relay deliberately refuses /tmp,
	# and a train there makes t/71 fail for a reason that has nothing to do with
	# the ticket. Use the QA root (the systemd unit leaves it writable), or the
	# home directory for a hand run.
	my $train_root = $ENV{'JAWNOS_QA_ROOT'} || (($ENV{'HOME'} || '.') . '/jawnos-qa');
	$train_root =~ s{/+$}{};
	my $train_parent = "$train_root/train";
	make_path($train_parent) unless -d $train_parent;

	# A coordinator that died can leave a detached train worktree, which
	# worktree_gc would keep. A wave is minutes; an hour is certainly dead.
	if (opendir(my $tdh, $train_parent)) {
		for my $name (grep { /^jawnos-train-/ } readdir $tdh) {
			my $path = "$train_parent/$name";
			next unless -d $path;
			my $age = time - ((stat($path))[9] || 0);
			next if $age < 3600;
			git_in($root, 'worktree', 'remove', '--force', "$path/tree");
			rmtree($path);
		}
		closedir $tdh;
	}

	my $parent = eval { tempdir('jawnos-train-XXXXXX', DIR => $train_parent, CLEANUP => 0) };
	if (!$parent) {
		my $why = $@ || 'tempdir failed';
		$why =~ s/\s+$//;
		requeue($dir, $wave, 60);
		release($lock);
		logit("cannot make the train worktree under $train_parent: $why");
		return { result => 'worktree_failed', stop => 1 };
	}
	my $tmp = "$parent/tree";
	my ($wrc, $wout) = git_in($root, 'worktree', 'add', '--detach', $tmp, "origin/$opt->{'trunk'}");
	if ($wrc != 0) {
		requeue($dir, $wave, 60);
		rmtree($parent);
		release($lock);
		logit("could not make the train worktree: $wout");
		return { result => 'worktree_failed', stop => 1 };
	}

	my (undef, $prev) = git_in($tmp, 'rev-parse', 'HEAD');
	my @integrated;
	my $integrate_start = time;
	my $hot_in_wave = 0;

	for my $t (@$wave) {
		my $was_hot = LandQueue::is_hot_ticket($root, $t);
		if ($was_hot && $hot_in_wave) {
			refuse_ticket($dir, $t, 'hot', 'another hot-file branch is already in this wave');
			next;
		}
		my ($ok, $class, $why, $version, $subject, $tip) =
			integrate_ticket($root, $tmp, $t, $prev, $opt);
		if (!$ok) {
			refuse_ticket($dir, $t, $class, $why);
			next;
		}
		$hot_in_wave = 1 if $was_hot;
		$prev = $tip;
		push @integrated, {
			ticket => $t, version => $version, subject => $subject, tip => $tip,
		};
	}

	if (!@integrated) {
		cleanup_train($root, $tmp, $parent);
		release($lock);
		return { result => 'nothing_integrated' };
	}

	my $integrate_ms = int((time - $integrate_start) * 1000);
	regenerate($root, $tmp);
	my $suite_start = time;
	my ($sok, $sout) = run_suite($root, $tmp, $opt->{'jobs'});

	my $attempts = 0;
	while (!$sok && $attempts < $opt->{'suite_retries'}) {
		$attempts++;
		logit("the suite failed; retrying once before splitting the wave ($attempts)");
		($sok, $sout) = run_suite($root, $tmp, $opt->{'jobs'});
	}
	my $suite_ms = int((time - $suite_start) * 1000);

	if (!$sok) {
		my $tail = failure_tail($sout);
		if (@$wave > 1) {
			requeue($dir, $wave, 0);
			cleanup_train($root, $tmp, $parent);
			release($lock);
			LandQueue::event($dir, {
				event => 'wave', size => scalar(@$wave),
				tickets => [ map { $_->{'id'} } @$wave ],
				integrate_ms => $integrate_ms, suite_ms => $suite_ms,
				jobs => $opt->{'jobs'}, result => 'red', retries => $attempts,
			});
			logit("the integrated suite is red; splitting the wave and retrying one branch at a time");
			return { result => 'red' };
		}
		for my $i (@integrated) {
			refuse_ticket($dir, $i->{'ticket'}, 'suite', $tail);
		}
		cleanup_train($root, $tmp, $parent);
		release($lock);
		LandQueue::event($dir, {
			event => 'wave', size => 1,
			tickets => [ map { $_->{'id'} } @$wave ],
			integrate_ms => $integrate_ms, suite_ms => $suite_ms,
			jobs => $opt->{'jobs'}, result => 'red', retries => $attempts,
		});
		return { result => 'red' };
	}

	local $ENV{'JAWNOS_SUITE_ALREADY_RUN'} = 1;
	my ($prc, $pout) = git_in($tmp, 'push', 'origin', "HEAD:refs/heads/$opt->{'trunk'}");
	if ($prc != 0) {
		requeue($dir, $wave, 30);
		cleanup_train($root, $tmp, $parent);
		release($lock);
		LandQueue::event($dir, {
			event => 'wave', size => scalar(@$wave),
			tickets => [ map { $_->{'id'} } @$wave ],
			integrate_ms => $integrate_ms, suite_ms => $suite_ms,
			jobs => $opt->{'jobs'}, result => 'push_rejected',
		});
		logit("the push was refused; the tickets are back in the queue: $pout");
		return { result => 'push_rejected', stop => 1 };
	}

	my $finished = time;
	for my $i (@integrated) {
		my $t = $i->{'ticket'};
		my $wait = ($t->{'started_at'} // $finished) - ($t->{'submitted_at'} // $finished);
		mark_landed($dir, $t, $i->{'version'}, $i->{'subject'}, $i->{'tip'}, $wait, $finished);
		git_in($root, 'push', 'origin', '--delete', $t->{'branch'});
	}

	cleanup_train($root, $tmp, $parent);

	my ($applied, $apply_why) = apply_primary($primary, $opt->{'trunk'});
	my $restart = 'skipped';
	my $last = $integrated[-1];
	if ($applied && $opt->{'restart'}) {
		my ($ok, $why) = restart_once($primary, $last->{'version'}, $last->{'subject'});
		$restart = $ok ? 'ok' : 'failed';
		logit("the restart failed: $why") if !$ok;
	}
	elsif (!$applied) {
		logit("landed, but the primary checkout did not take it: $apply_why");
	}

	release($lock);
	LandQueue::event($dir, {
		event => 'wave', size => scalar(@integrated),
		tickets => [ map { $_->{'ticket'}{'id'} } @integrated ],
		integrate_ms => $integrate_ms, suite_ms => $suite_ms,
		jobs => $opt->{'jobs'}, result => 'landed', retries => $attempts,
		apply => $applied ? 'ok' : 'blocked', restart => $restart,
	});
	my $n = scalar @integrated;
	logit("landed $n branch(es) in one wave: "
		. join(', ', map { $_->{'ticket'}{'branch'} } @integrated));
	return { result => 'landed' };
}

# --- integrating one ticket ------------------------------------------------

sub integrate_ticket {
	my ($root, $tmp, $t, $prev, $opt) = @_;
	# keep git's messages in one language: the empty-patch guard below reads them
	local $ENV{'LC_ALL'} = 'C';
	my $sha = $t->{'sha'} // '';
	return (0, 'stale', 'the ticket has no sha') unless length $sha;

	my ($erc, $eout) = git_in($root, 'cat-file', '-e', "$sha^{commit}");
	return (0, 'stale', "the ticket's commit $sha is not in the repository; enqueue again")
		if $erc != 0;

	my (undef, $base) = git_in($root, 'merge-base', "origin/$opt->{'trunk'}", $sha);
	return (0, 'stale', "cannot find the merge base of $sha with origin/$opt->{'trunk'}")
		unless defined $base && length $base;

	my ($mrc, $merges) = git_in($root, 'rev-list', '--merges', '--count', "$base..$sha");
	return (0, 'rebase', 'the branch contains merge commits; rebase it linear before enqueueing')
		if $mrc == 0 && ($merges // 0) > 0;

	my ($crc, $count) = git_in($root, 'rev-list', '--count', "$base..$sha");
	return (0, 'nothing', 'the branch has no commits left to land; it is already on the trunk')
		if $crc == 0 && ($count // 0) == 0;

	my (undef, $train_before) = git_in($tmp, 'rev-parse', 'HEAD');
	my ($prc, $pout) = git_in($tmp, 'cherry-pick', '--allow-empty', "$base..$sha");
	while ($prc != 0) {
		my (undef, $unmerged) = git_in($tmp, 'diff', '--name-only', '--diff-filter=U');
		my @unmerged = grep { length } split /\n/, $unmerged;
		if (@unmerged && !grep { $_ ne 'VERSION' } @unmerged) {
			# VERSION is the train's, and the bump below moves it past whatever
			# the branch carried, so the number stays unique.
			git_in($tmp, 'checkout', '--ours', '--', 'VERSION');
			git_in($tmp, 'add', '--', 'VERSION');
			($prc, $pout) = git_in($tmp, 'cherry-pick', '--continue');
			next;
		}
		if (!@unmerged && $pout =~ /previous cherry-pick is now empty/i) {
			# The branch still carries a commit the trunk already has under
			# another sha - it landed from an earlier ticket, and re-enqueueing
			# kept the original commit in the branch. That is not a conflict:
			# skip the empty patch and carry on with the rest of the branch.
			($prc, $pout) = git_in($tmp, 'cherry-pick', '--skip');
			next;
		}
		git_in($tmp, 'cherry-pick', '--abort');
		my $files = @unmerged ? join(', ', @unmerged) : 'unknown files';
		return (0, 'rebase', "the branch conflicts with the train ($files); "
			. 'rebase it onto the new trunk and enqueue again');
	}
	my (undef, $train_after) = git_in($tmp, 'rev-parse', 'HEAD');
	return (0, 'nothing', 'the branch has no commits left to land; it is already on the trunk')
		if $train_after eq $train_before;

	my ($brc, $bump) = LandQueue::run_in($tmp, $^X, "$tmp/scripts/version_bump.pl");
	return (0, 'bump', "version_bump.pl failed: $bump") if $brc != 0;
	my @versions = ($bump // '') =~ /(\d+\.\d+\.\d+)/g;
	my $version = $versions[-1] // '';
	return (0, 'bump', "version_bump.pl printed no version: $bump")
		unless $version =~ /^\d+\.\d+\.\d+$/;

	my @fw_version_files = grep { -f "$tmp/$_" } qw(jt/VERSION jw/VERSION jp/alarmclock/VERSION);
	if (-f "$tmp/scripts/fw_bump.pl" && @fw_version_files) {
		my ($frc, $fout) = LandQueue::run_in($tmp, $^X, "$tmp/scripts/fw_bump.pl",
			'--sync', '--from', $prev, '--house', $version);
		return (0, 'bump', "fw_bump.pl failed: $fout") if $frc != 0;
	}

	my (undef, $subject) = git_in($tmp, 'log', '-1', '--format=%s');
	my (undef, $body)    = git_in($tmp, 'log', '-1', '--format=%b');
	$subject =~ s/^\s*v\d+\.\d+\.\d+\s+-\s+//;
	$subject =~ s/\s+$//;
	return (0, 'commit', 'the branch tip has no subject') unless length $subject;
	$body =~ s/\s+$//;

	git_in($tmp, 'add', '--', 'VERSION', @fw_version_files);
	my ($fh, $msg) = tempfile(UNLINK => 1, SUFFIX => '.msg');
	print $fh "v$version - $subject" . (length $body ? "\n\n$body" : '');
	close $fh;

	# A dirty primary blocks this box's apply, not the trunk. The commit is in
	# the train worktree and never touches the primary, so the guard's reason
	# for refusing does not apply here.
	local $ENV{'JAWNOS_ALLOW_DIRTY_PRIMARY'} = 1;
	my ($amrc, $amout) = git_in($tmp, 'commit', '--amend', '-F', $msg);
	unlink $msg;
	return (0, 'commit', "amending the train tip failed: $amout") if $amrc != 0;

	my (undef, $tip) = git_in($tmp, 'rev-parse', 'HEAD');
	return (1, '', '', $version, $subject, $tip);
}

sub regenerate {
	my ($root, $tmp) = @_;
	# The train's own copies: these scripts read the tree above themselves, and
	# the primary's copy would read the primary instead of the train.
	if (-f "$tmp/scripts/agent_help.pl") {
		my ($rc, $out) = LandQueue::run_in($tmp, $^X, "$tmp/scripts/agent_help.pl", '--write-index');
		logit("agent_help --write-index failed: $out") if $rc != 0;
	}
	if (-f "$tmp/scripts/bake_agents_rules.pl" && -f "$tmp/AGENTS.md") {
		my ($rc, $out) = LandQueue::run_in($tmp, $^X, "$tmp/scripts/bake_agents_rules.pl");
		logit("bake_agents_rules failed: $out") if $rc != 0;
	}
	my (undef, $dirty) = git_in($tmp, 'status', '--porcelain');
	return unless length $dirty;
	git_in($tmp, 'add', '-A');
	local $ENV{'JAWNOS_ALLOW_DIRTY_PRIMARY'} = 1;
	my ($rc, $out) = git_in($tmp, 'commit', '--amend', '--no-edit');
	logit("could not fold the regenerated indexes into the tip: $out") if $rc != 0;
}

sub run_suite {
	my ($root, $tmp, $jobs) = @_;
	my ($rc, $out) = LandQueue::run_in($tmp, $^X, "$tmp/scripts/run_tests.pl", '--jobs', $jobs);
	return ($rc == 0, $out);
}

sub failure_tail {
	my ($out) = @_;
	my @lines = grep { /\S/ } split /\n/, ($out // '');
	return 'the suite failed (no output)' unless @lines;
	my @fail = grep { /not ok|FAILED|Result: FAIL|tests failed/i } @lines;
	my @pick = @fail ? @fail : @lines[(@lines > 12 ? -12 : 0) .. $#lines];
	return join("\n", @lines > 40 ? @pick[0 .. ($#pick > 19 ? 19 : $#pick)] : @pick);
}

# --- state -----------------------------------------------------------------

sub mark_landed {
	my ($dir, $t, $version, $subject, $tip, $wait, $finished) = @_;
	$t->{'state'}       = 'landed';
	$t->{'pid'}         = 0;
	$t->{'finished_at'} = $finished;
	$t->{'result'} = {
		code => 0, version => $version, subject => $subject, sha => $tip,
		message => "landed v$version - $subject",
	};
	LandQueue::write_ticket($dir, $t);
	LandQueue::event($dir, {
		event => 'landed', id => $t->{'id'}, branch => $t->{'branch'},
		version => $version, wait_s => $wait,
		land_s => $finished - ($t->{'started_at'} // $finished),
	});
}

sub refuse_ticket {
	my ($dir, $t, $class, $why) = @_;
	$t->{'state'}       = ($class eq 'stale') ? 'superseded' : 'refused';
	$t->{'pid'}         = 0;
	$t->{'finished_at'} = time;
	$t->{'result'} = {
		code => 1, reason_class => $class, message => $why // '',
	};
	LandQueue::write_ticket($dir, $t);
	LandQueue::event($dir, {
		event => $t->{'state'}, id => $t->{'id'}, branch => $t->{'branch'},
		reason_class => $class,
	});
	logit("refused $t->{'branch'} ($class): $why");
}

sub requeue {
	my ($dir, $tickets, $delay) = @_;
	my $at = int(time) + $delay;
	for my $t (@$tickets) {
		next unless ($t->{'state'} // '') eq 'running';
		$t->{'state'}      = 'queued';
		$t->{'pid'}        = 0;
		$t->{'started_at'} = 0;
		$t->{'not_before'} = $at;
		LandQueue::write_ticket($dir, $t);
	}
}

# --- the checkout and the master -------------------------------------------

sub primary_checkout {
	my ($root) = @_;
	my (undef, $out) = git_in($root, 'worktree', 'list', '--porcelain');
	my ($p) = ($out // '') =~ /^worktree\s+(.+)$/m;
	return defined $p ? $p : $root;
}

sub apply_primary {
	my ($primary, $trunk) = @_;
	$trunk = 'main' unless defined $trunk && length $trunk;
	my ($frc, $fout) = git_in($primary, 'fetch', 'origin', '--quiet');
	return (0, "fetch failed: $fout") if $frc != 0;
	my (undef, $dirty) = git_in($primary, 'status', '--porcelain', '--untracked-files=no');
	return (0, "the primary checkout has uncommitted changes:\n$dirty") if length $dirty;
	my ($mrc, $mout) = git_in($primary, 'merge', '--ff-only', "origin/$trunk");
	return (0, "fast-forward failed: $mout") if $mrc != 0;
	return (1, '');
}

sub restart_once {
	my ($primary, $version, $subject) = @_;
	my $script = "$primary/scripts/restart.pl";
	return (1, '') unless -f $script;
	my $reason = "v$version - $subject";
	my ($rc, $out) = LandQueue::run_cmd($^X, $script, '--reason', $reason);
	return (1, '') if $rc == 0;
	return (0, $out) unless $out =~ /already pending|busy/i;

	my $deadline = time + 180;
	while (time < $deadline) {
		my ($src, $sout) = LandQueue::run_cmd($^X, $script, '--status', '--json');
		if ($src == 0) {
			my $reply = eval { JSON::PP->new->decode($sout) };
			if (ref $reply eq 'HASH' && !$reply->{'pending'}) {
				return (1, '') if version_ge($reply->{'version'}, $version);
				last;
			}
		}
		sleep 2;
	}
	my ($rrc, $rout) = LandQueue::run_cmd($^X, $script, '--reason', $reason);
	return ($rrc == 0 ? (1, '') : (0, $rout));
}

sub version_ge {
	my ($a, $b) = @_;
	my @a = (($a // '') =~ /^v?(\d+)\.(\d+)\.(\d+)/) ? ($1, $2, $3) : (0, 0, 0);
	my @b = (($b // '') =~ /^v?(\d+)\.(\d+)\.(\d+)/) ? ($1, $2, $3) : (0, 0, 0);
	for my $i (0 .. 2) {
		return 1 if $a[$i] > $b[$i];
		return 0 if $a[$i] < $b[$i];
	}
	return 1;
}

# --- locks and small helpers ------------------------------------------------

sub land_lock {
	my ($common, $wait) = @_;
	my $path = "$common/jawnos-land.lock";
	open(my $fh, '>>', $path) or do {
		logit("cannot open $path: $!");
		return undef;
	};
	$fh->autoflush(1);
	my $deadline = time + $wait;
	while (!flock($fh, LOCK_EX | LOCK_NB)) {
		if (time >= $deadline) {
			close $fh;
			return undef;
		}
		sleep 1;
	}
	seek($fh, 0, 0);
	truncate($fh, 0);
	print $fh "$$ coordinator\n";
	return $fh;
}

sub release {
	my ($fh) = @_;
	return unless $fh;
	flock($fh, LOCK_UN);
	close $fh;
}

sub cleanup_train {
	my ($root, $tmp, $parent) = @_;
	my ($rc) = git_in($root, 'worktree', 'remove', '--force', $tmp);
	git_in($root, 'worktree', 'prune') if $rc != 0;
	rmtree($parent) if defined $parent && -d $parent;
}

sub git_in {
	my ($dir, @args) = @_;
	return LandQueue::run_cmd('git', '-C', $dir, @args);
}

sub logit {
	print STDERR 'land_coordinator: ', join('', @_), "\n";
}

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
land_coordinator.pl - drain the landing queue in waves
  perl scripts/land_coordinator.pl [--train-size 1] [--jobs 4] [--once]
                                   [--suite-retries 1] [--no-restart]
                                   [--wait 0] [--dry-run]
  Run it from the primary checkout. One instance per repository.
USAGE
	exit $code;
}
