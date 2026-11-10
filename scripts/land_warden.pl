#!/usr/bin/perl

# Rescue a refused landing into a worktree someone can finish.
#
#   perl scripts/land_warden.pl --once
#   perl scripts/land_warden.pl --once --dry-run
#   perl scripts/land_warden.pl --ticket 00000001
#   perl scripts/land_warden.pl --once --max 1 --jobs 2
#
# The coordinator is the traffic controller; this is the warden for the tickets
# it refuses. For each refused ticket it:
#
#   rescue    create warden/land-<id>-<stamp> from the ticket's commit or its
#             origin branch, in $JAWNOS_QA_ROOT/warden/<id>, and rebase onto
#             origin/main
#   test      run scripts/run_tests.pl --jobs N in that worktree
#   green     push the warden branch and enqueue it; the coordinator lands it
#   red       leave the worktree and write the failing lines to the report
#   conflict  leave the rebase in place and name the conflicted files
#
# It never rewrites the owner's branch and never pushes the trunk. One attempt
# per ticket; --retry allows another. The report is a Markdown file beside the
# worktrees, so a person can pick it up without an inbox.

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use FindBin;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

require "$FindBin::Bin/land_lib.pl";

my %opt = (
	'ticket' => undef,
	'max'    => 1,
	'jobs'   => 2,
	'timeout' => 1800,
	'report' => undef,
	'trunk'  => 'main',
	'dry_run' => 0,
	'retry' => 0,
	'once' => 0,
);
GetOptions(
	'ticket=s'  => \$opt{'ticket'},
	'max=s'     => \$opt{'max'},
	'jobs=s'    => \$opt{'jobs'},
	'timeout=s' => \$opt{'timeout'},
	'report=s'  => \$opt{'report'},
	'trunk=s'   => \$opt{'trunk'},
	'dry-run'   => \$opt{'dry_run'},
	'retry'     => \$opt{'retry'},
	'once'      => \$opt{'once'},
	'help'      => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'max'} =~ /^\d+$/ && $opt{'max'} > 0;
usage(2) unless $opt{'jobs'} =~ /^\d+$/ && $opt{'jobs'} >= 1 && $opt{'jobs'} <= 8;
usage(2) unless $opt{'timeout'} =~ /^\d+$/ && $opt{'timeout'} > 0;
$opt{'ticket'} = sprintf('%08d', $opt{'ticket'}) if defined $opt{'ticket'} && $opt{'ticket'} =~ /^\d+$/;

my ($root, $common) = eval { LandQueue::repo() };
if (!$root) {
	my $why = $@ || 'not inside a git worktree';
	$why =~ s/\s+$//;
	print STDERR "land_warden: $why\n";
	exit 2;
}
my $primary = LandQueue::primary_checkout($root);
my $dir = LandQueue::queue_dir($common);
my $qa_root = ($ENV{'JAWNOS_QA_ROOT'} || (($ENV{'HOME'} || '.') . '/jawnos-qa'));
$qa_root =~ s{/+$}{};
my $work_root = "$qa_root/warden";
my $report_dir = $opt{'report'} || $work_root;
my $report_on = warden_report_enabled($primary);

# One warden at a time; a second timer tick exits quietly.
my $lock;
if (!$opt{'dry_run'}) {
	open($lock, '>>', "$common/land-warden.lock") or do {
		print STDERR "land_warden: cannot open the lock: $!\n";
		exit 2;
	};
	$lock->autoflush(1);
	unless (flock($lock, LOCK_EX | LOCK_NB)) {
		print STDERR "land_warden: another warden is running; nothing to do\n";
		exit 0;
	}
	make_path($work_root) unless -d $work_root;
	make_path($report_dir) unless -d $report_dir;
}

my @tickets = @{ LandQueue::tickets($dir) };
my @candidates = grep { is_stranded($_) } @tickets;
if (defined $opt{'ticket'}) {
	my @one = grep { ($_->{'id'} // '') eq $opt{'ticket'} } @candidates;
	if (!@one) {
		print STDERR "land_warden: no stranded ticket $opt{'ticket'}\n";
		exit 2;
	}
	@candidates = @one;
}
@candidates = grep {
	$opt{'retry'}
		|| (($_->{'warden'}{'attempt'} // 0) < 1)
		|| resumable($_)
} @candidates;
@candidates = sort {
	($a->{'submitted_at'} // 0) <=> ($b->{'submitted_at'} // 0)
		|| ($a->{'id'} // '') cmp ($b->{'id'} // '')
} @candidates;
splice(@candidates, $opt{'max'}) if scalar @candidates > $opt{'max'};

if (!@candidates) {
	print "land_warden: no stranded ticket to handle\n";
	exit 0;
}

my $fetched = 0;
if (!$opt{'dry_run'}) {
	my ($frc) = git_in($primary, 'fetch', 'origin', '--quiet');
	$fetched = 1 if $frc == 0;
}

for my $t (@candidates) {
	handle_ticket($t, $fetched);
}

exit 0;

# A stranded ticket is a terminal one that did not land. Superseded is left
# alone: its work is already on the trunk.
sub is_stranded {
	my ($t) = @_;
	my $s = $t->{'state'} // '';
	return $s eq 'refused' || $s eq 'blocked';
}

sub handle_ticket {
	my ($t, $fetched) = @_;
	my $id = $t->{'id'} // '';
	my $branch = $t->{'branch'} // '';
	my $sha = $t->{'sha'} // '';

	my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
	my $wbranch = "warden/land-$id-$stamp";
	my $wt = "$work_root/$id";

	# A worktree the warden left for a conflict is resumed once the person has
	# finished the rebase; that is the automatic half of the handoff. Its branch
	# is the only ref that matters now, so this comes before the recoverability
	# test.
	if (-e $wt) {
		if ($opt{'dry_run'}) {
			print "land_warden: would resume $id in $wt\n";
			return;
		}
		return resume_existing($t, $wt);
	}

	my $ref = recover_ref($branch, $sha, $fetched);
	if (!length $ref) {
		write_report($t, {
			state => 'gone',
			detail => 'the commit and its branch are both missing; there is nothing to rescue',
		});
		return;
	}

	# The same patch may already be on the trunk under another sha (a re-enqueued
	# ticket, or a branch that landed while it was refused). git cherry answers
	# by patch id, so no worktree and no suite are needed.
	if (already_upstream($primary, $ref)) {
		$t->{'state'} = 'superseded';
		$t->{'result'} = { code => 0, reason_class => 'nothing',
			message => 'the warden found every commit already on the trunk' };
		write_report($t, {
			state => 'nothing',
			detail => 'every commit is already on the trunk; no worktree was needed',
		});
		return;
	}

	if ($opt{'dry_run'}) {
		print "land_warden: would rescue $id ($branch) from $ref into $wt\n";
		return;
	}

	my ($wrc, $wout) = git_in($primary, 'worktree', 'add', '-b', $wbranch, $wt, $ref);
	if ($wrc != 0) {
		write_report($t, {
			state => 'blocked',
			detail => "could not create the warden worktree: $wout",
			worktree => $wt,
		});
		return;
	}

	my ($rrc, $rout) = git_in($wt, 'rebase', "origin/$opt{'trunk'}");
	if ($rrc != 0) {
		my (undef, $conflicts) = git_in($wt, 'diff', '--name-only', '--diff-filter=U');
		my @files = grep { length } split /\n/, ($conflicts // '');
		write_report($t, {
			state => 'conflict',
			detail => 'the rebase stopped; the worktree is left with the conflict markers',
			worktree => $wt,
			branch => $wbranch,
			files => \@files,
			output => $rout,
		});
		return;
	}

	return finish_branch($t, $wt, $wbranch);
}

# Resume a warden worktree the person has finished with. It must be out of the
# rebase and have no uncommitted work; then it is tested and enqueued like a
# fresh rescue. A red ticket is resumed only with --retry.
sub resume_existing {
	my ($t, $wt) = @_;
	if (already_upstream($wt, 'HEAD')) {
		$t->{'state'} = 'superseded';
		$t->{'result'} = { code => 0, reason_class => 'nothing',
			message => 'the warden found every commit already on the trunk' };
		write_report($t, {
			state => 'nothing',
			detail => 'every commit is already on the trunk; the worktree may be removed',
			worktree => $wt,
		});
		return;
	}
	if (in_rebase($wt)) {
		write_report($t, {
			state => 'conflict',
			detail => 'the rebase is still in progress in the warden worktree',
			worktree => $wt,
		});
		return;
	}
	my (undef, $status) = git_in($wt, 'status', '--porcelain');
	if (($status // '') =~ /\S/) {
		write_report($t, {
			state => 'blocked',
			detail => 'the warden worktree has uncommitted work; commit the fix, then run the warden again',
			worktree => $wt,
		});
		return;
	}
	my (undef, $wbranch) = git_in($wt, 'rev-parse', '--abbrev-ref', 'HEAD');
	$wbranch =~ s/\s+//g;
	if (!length $wbranch || $wbranch eq 'HEAD') {
		write_report($t, {
			state => 'blocked',
			detail => 'the warden worktree is not on a branch',
			worktree => $wt,
		});
		return;
	}
	return finish_branch($t, $wt, $wbranch);
}

# The suite, the push and the enqueue are the same whether the branch was just
# rebased or resumed after a conflict.
sub finish_branch {
	my ($t, $wt, $wbranch) = @_;
	my $id = $t->{'id'} // '';
	my (undef, $ahead) = git_in($wt, 'rev-list', '--count', "origin/$opt{'trunk'}..HEAD");
	if (($ahead // '') eq '0') {
		$t->{'state'} = 'superseded';
		$t->{'result'} = { code => 0, reason_class => 'nothing',
			message => 'the warden rebased it and found nothing left to land; the work is already on the trunk' };
		git_in($primary, 'worktree', 'remove', $wt);
		git_in($primary, 'branch', '-D', $wbranch);
		write_report($t, {
			state => 'nothing',
			detail => 'every commit was already on the trunk after the rebase',
			worktree => $wt,
		});
		return;
	}

	my $log = "$work_root/$id-suite.log";
	my ($src, $sout) = LandQueue::run_in($wt,
		'timeout', $opt{'timeout'}, $^X, "$wt/scripts/run_tests.pl", '--jobs', $opt{'jobs'});
	write_file($log, $sout);
	if ($src != 0) {
		write_report($t, {
			state => ($src == 124 ? 'timeout' : 'red'),
			detail => 'the suite failed on the rebased branch; the worktree is left for the fix',
			worktree => $wt,
			branch => $wbranch,
			suite_exit => $src,
			log => $log,
			failing => [ failing_lines($sout) ],
		});
		return;
	}

	my ($prc, $pout) = git_in($wt, 'push', '-u', 'origin', "HEAD:refs/heads/$wbranch");
	if ($prc != 0) {
		write_report($t, {
			state => 'push_failed',
			detail => "the green warden branch could not be pushed: $pout",
			worktree => $wt,
			branch => $wbranch,
		});
		return;
	}

	my ($erc, $eout) = LandQueue::run_in($wt,
		$^X, "$wt/scripts/land_enqueue.pl",
		'--branch', $wbranch,
		'--agent', 'warden',
		'--reason', "warden rescue of ticket $id",
	);
	my ($new_id) = $eout =~ /ticket (\d{8})/;
	if ($erc != 0) {
		write_report($t, {
			state => 'enqueue_failed',
			detail => "the green warden branch could not be enqueued: $eout",
			worktree => $wt,
			branch => $wbranch,
		});
		return;
	}

	write_report($t, {
		state => 'enqueued',
		detail => 'the green warden branch is in the queue; the coordinator owns the landing',
		worktree => $wt,
		branch => $wbranch,
		new_ticket => ($new_id // ''),
	});
}

# Prefer the branch on origin (the enqueue backup), then the local branch, then
# the ticket's commit. A worktree may be gone; the object store is what matters.
# True when git cherry sees no commit that is not already upstream. An empty
# answer means the ref is an ancestor; every '-' line is an equivalent patch.
sub already_upstream {
	my ($cwd, $ref) = @_;
	my ($rc, $out) = git_in($cwd, 'cherry', "origin/$opt{'trunk'}", $ref);
	return 0 if $rc != 0;
	my @lines = grep { length } split /\n/, ($out // '');
	return 1 unless @lines;
	return 0 if grep { /^\+/ } @lines;
	return 1;
}

sub recover_ref {
	my ($branch, $sha, $fetched) = @_;
	if (length $branch) {
		for my $ref ("refs/remotes/origin/$branch", "refs/heads/$branch") {
			my ($rc) = git_in($primary, 'rev-parse', '--verify', '--quiet', $ref);
			return $ref if $rc == 0;
		}
	}
	if (length $sha) {
		my ($rc) = git_in($primary, 'cat-file', '-e', "$sha^{commit}");
		return $sha if $rc == 0;
	}
	return '';
}

# A conflict worktree is worth revisiting once the rebase has been finished and
# the tree is clean; a red ticket needs --retry so a broken fix is not a suite
# every fifteen minutes.
sub resumable {
	my ($t) = @_;
	return 0 unless (($t->{'warden'}{'state'} // '') eq 'conflict');
	my $wt = $t->{'warden'}{'worktree'} // '';
	return 0 unless length $wt && -d $wt;
	return !in_rebase($wt);
}

sub in_rebase {
	my ($wt) = @_;
	return 0 unless defined $wt && length $wt && -d $wt;
	for my $name (qw(rebase-merge rebase-apply)) {
		my (undef, $path) = git_in($wt, 'rev-parse', '--git-path', $name);
		$path =~ s/\s+//g;
		return 1 if length $path && -e $path;
	}
	return 0;
}

sub failing_lines {
	my ($out) = @_;
	my @lines = grep { /\S/ } split /\n/, ($out // '');
	my @fail = grep { /not ok|FAILED|Result: FAIL|tests failed/i } @lines;
	my @pick = @fail ? @fail : @lines[( @lines > 12 ? -12 : 0 ) .. $#lines];
	@pick = @pick[0 .. 19] if @pick > 20;
	return @pick;
}

sub write_report {
	my ($t, $w) = @_;
	my $id = $t->{'id'} // '';
	my $path = "$report_dir/ticket-$id.md";
	my @lines = (
		"# Land warden: ticket $id",
		'',
		'- at: ' . strftime('%Y-%m-%d %H:%M:%S', localtime),
		'- state: ' . ($w->{'state'} // 'unknown'),
		'- branch: ' . ($t->{'branch'} // ''),
		'- commit: ' . ($t->{'sha'} // ''),
		'- owner: ' . ($t->{'agent'} // '') . ' on ' . ($t->{'box'} // ''),
		'- submitted: ' . ($t->{'submitted_at'} // '') . ' (' . age($t->{'submitted_at'}) . ' ago)',
		'- refused: ' . (($t->{'result'}{'reason_class'} // '') || 'unknown'),
		'- detail: ' . ($w->{'detail'} // ''),
	);
	push @lines, '- worktree: ' . $w->{'worktree'} if length($w->{'worktree'} // '');
	push @lines, '- warden branch: ' . $w->{'branch'} if length($w->{'branch'} // '');
	push @lines, '- new ticket: ' . $w->{'new_ticket'} if length($w->{'new_ticket'} // '');
	push @lines, '- suite exit: ' . $w->{'suite_exit'} if defined $w->{'suite_exit'};
	push @lines, '- log: ' . $w->{'log'} if length($w->{'log'} // '');
	if (ref $w->{'files'} eq 'ARRAY' && @{ $w->{'files'} }) {
		push @lines, '', '## Conflicted files', '', map { "- $_" } @{ $w->{'files'} };
	}
	if (ref $w->{'failing'} eq 'ARRAY' && @{ $w->{'failing'} }) {
		push @lines, '', '## Failing lines', '', map { "    $_" } @{ $w->{'failing'} };
	}
	if (length($w->{'output'} // '')) {
		push @lines, '', '## Output', '', '    ' . join("\n    ", split /\n/, $w->{'output'});
	}
	push @lines, '', '## Refusal on record', '', '    ' . join("\n    ", split /\n/, ($t->{'result'}{'message'} // ''));
	push @lines, '';

	if (!$opt{'dry_run'}) {
		write_file($path, join("\n", @lines));
		write_file("$report_dir/latest.md", join("\n", @lines));
		$t->{'warden'} = {
			at => time,
			attempt => (($t->{'warden'}{'attempt'} // 0) + 1),
			state => $w->{'state'},
			report => $path,
			detail => $w->{'detail'},
			(defined $w->{'worktree'} ? (worktree => $w->{'worktree'}) : ()),
			(defined $w->{'branch'} ? (branch => $w->{'branch'}) : ()),
			(defined $w->{'new_ticket'} ? (new_ticket => $w->{'new_ticket'}) : ()),
		};
		LandQueue::write_ticket($dir, $t);
		LandQueue::event($dir, {
			event => 'warden',
			id => $id,
			branch => ($t->{'branch'} // ''),
			state => $w->{'state'},
		});
		notify_report($t, $w, $path);
	}
	print 'land_warden: ticket ', $id, ' ', ($w->{'state'} // 'unknown'), ': ', ($w->{'detail'} // ''), "\n";
}

# The report is also a Handbook note when the panel asks for one. Only the
# states that leave a person something to do are sent; enqueued and nothing are
# the queue's own answer.
sub notify_report {
	my ($t, $w, $path) = @_;
	return unless $report_on;
	my $state = $w->{'state'} // '';
	my %attention = map { $_ => 1 } qw(conflict red timeout gone push_failed enqueue_failed blocked);
	return unless $attention{$state};
	my $live = live_url($primary);
	my $ticket = ticket_url($primary);
	return unless length $live && length $ticket;
	require Mojo::UserAgent;
	my $ua = Mojo::UserAgent->new(insecure => 1, max_redirects => 5, request_timeout => 30);
	my $mint = eval { $ua->get($ticket) };
	unless ($mint && $mint->res->is_success) {
		print STDERR "land_warden: the Handbook note was not filed; the ticket did not mint a session\n";
		return;
	}
	my $id = $t->{'id'} // '';
	my @lines = (
		"Land warden: ticket $id $state",
		'',
		($w->{'detail'} // ''),
		'',
		'- branch: ' . ($t->{'branch'} // ''),
		'- worktree: ' . ($w->{'worktree'} // ''),
		'- report: ' . $path,
	);
	if (ref $w->{'failing'} eq 'ARRAY' && @{ $w->{'failing'} }) {
		push @lines, '', 'Failing lines:', map { "    $_" } @{ $w->{'failing'} };
	}
	my $text = join("\n", @lines);
	my $post = eval { $ua->post($live . '/manager/note_save' => form => { text => $text, category => 'journal' }) };
	unless ($post && $post->res->is_success) {
		print STDERR "land_warden: the Handbook note was not filed\n";
	}
}

sub warden_report_enabled {
	my ($repo) = @_;
	my $lib = "$FindBin::Bin/../qa/lib";
	return 1 unless -f "$lib/QaSetting.pm";
	eval { require "$lib/QaSetting.pm"; 1 } or return 1;
	my $db = "$repo/database/jawnos.db";
	return 1 unless -f $db;
	my $v = eval { QaSetting::read_setting($db, 'qa_warden_report') };
	return 1 unless defined $v && length $v;
	return $v eq 'off' ? 0 : 1;
}

sub live_url {
	my ($repo) = @_;
	my $path = "$repo/config.json";
	my $port = 3000;
	if (-f $path) {
		open(my $fh, '<', $path) or return "https://127.0.0.1:$port";
		local $/;
		my $json = <$fh> // '';
		close $fh;
		my $cfg = eval { JSON::PP->new->utf8->decode($json) };
		$port = $cfg->{'working_port'} if ref $cfg eq 'HASH' && $cfg->{'working_port'};
	}
	return "https://127.0.0.1:$port";
}

sub ticket_url {
	my ($repo) = @_;
	my $path = "$repo/.shots/ticket.txt";
	return '' unless -f $path;
	open(my $fh, '<', $path) or return '';
	my $url = <$fh> // '';
	close $fh;
	$url =~ s/^\s+|\s+$//g;
	return $url;
}

sub git_in {
	my ($cwd, @cmd) = @_;
	return LandQueue::run_in($cwd, 'git', @cmd);
}

sub age {
	my ($t) = @_;
	return 'unknown' unless defined $t && $t > 0;
	my $s = time - $t;
	return $s . 's' if $s < 60;
	return int($s / 60) . 'm' if $s < 3600;
	return int($s / 3600) . 'h';
}

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
land_warden.pl - rescue a refused ticket into a worktree
  perl scripts/land_warden.pl [--once] [--ticket ID] [--max 1]
                              [--jobs 2] [--timeout 1800]
                              [--report DIR] [--trunk main] [--retry] [--dry-run]
  Runs on the authority, where the queue is. It leaves the owner's branch and
  the primary checkout alone; its worktrees live under $JAWNOS_QA_ROOT/warden.
USAGE
	exit $code;
}
