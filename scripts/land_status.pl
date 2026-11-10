#!/usr/bin/perl

# What is in the landing queue, and what happened to a ticket.
#
#   perl scripts/land_status.pl                  the queue and what is running
#   perl scripts/land_status.pl --id 00000007
#   perl scripts/land_status.pl --branch agent/pen
#   perl scripts/land_status.pl --id 7 --wait --timeout 60
#   perl scripts/land_status.pl --stats          measured waits and suite times
#   perl scripts/land_status.pl --refused         every refused ticket, with its why
#   perl scripts/land_status.pl --refused --check exit 1 when one is waiting
#   perl scripts/land_status.pl --all             every ticket, terminal ones included
#   perl scripts/land_status.pl --json
#
# --wait exists for a caller that wants a verdict in this turn; the coordinator
# owns the work either way, so a timeout is not a failure, only a later look.
# Exit: 0 landed (or a successful query) - 1 refused/blocked - 2 no ticket or
# timeout.

use strict;
use warnings;

use FindBin;
use Getopt::Long qw(GetOptions);
use JSON::PP ();

require "$FindBin::Bin/land_lib.pl";

my %opt = (
	'timeout'        => 60,
	'authority_port' => 8022,
	'authority_root' => '$HOME/jawnos',
);
GetOptions(
	'id=s'             => \$opt{'id'},
	'branch=s'         => \$opt{'branch'},
	'json'             => \$opt{'json'},
	'wait'             => \$opt{'wait'},
	'timeout=s'        => \$opt{'timeout'},
	'stats'            => \$opt{'stats'},
	'all'              => \$opt{'all'},
	'refused'          => \$opt{'refused'},
	'check'            => \$opt{'check'},
	'authority=s'      => \$opt{'authority'},
	'authority-root=s' => \$opt{'authority_root'},
	'authority-port=s' => \$opt{'authority_port'},
	'help'             => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'timeout'} =~ /^\d+$/;
usage(2) unless $opt{'authority_port'} =~ /^\d+$/;
# A check with no range asks the refused question: the one a monitor wants.
$opt{'refused'} = 1 if $opt{'check'} && !$opt{'all'};
$opt{'id'} = sprintf('%08d', $opt{'id'}) if defined $opt{'id'} && $opt{'id'} =~ /^\d+$/;

if ($opt{'authority'}) {
	my @fwd;
	push @fwd, '--id', $opt{'id'} if defined $opt{'id'};
	push @fwd, '--branch', $opt{'branch'} if defined $opt{'branch'};
	push @fwd, '--json' if $opt{'json'};
	push @fwd, '--wait' if $opt{'wait'};
	push @fwd, '--timeout', $opt{'timeout'};
	push @fwd, '--stats' if $opt{'stats'};
	push @fwd, '--all' if $opt{'all'};
	push @fwd, '--refused' if $opt{'refused'};
	push @fwd, '--check' if $opt{'check'};

	my ($lroot) = eval { LandQueue::repo() };
	my $primary = $lroot ? LandQueue::primary_checkout($lroot) : '';
	my ($arc, $aout, $aerr) = LandQueue::run_authority(
		host    => $opt{'authority'},
		port    => $opt{'authority_port'},
		root    => $opt{'authority_root'},
		script  => 'scripts/land_status.pl',
		args    => \@fwd,
		primary => $primary,
	);
	print STDOUT $aout if length $aout;
	print STDERR $aerr if length $aerr;
	exit $arc;
}

my ($root, $common) = eval { LandQueue::repo() };
if (!$root) {
	my $why = $@ || 'not inside a git worktree';
	$why =~ s/\s+$//;
	print STDERR "land_status: $why\n";
	exit 2;
}
my $dir = LandQueue::queue_dir($common);

if ($opt{'stats'}) {
	stats($dir);
	exit 0;
}

if ($opt{'all'} || $opt{'refused'}) {
	my @all = @{ LandQueue::tickets($dir) };
	my @shown = $opt{'refused'} ? grep { is_refused($_) } @all : @all;
	my %state;
	$state{ $_->{'state'} // 'queued' }++ for @all;
	my $bad = grep { is_refused($_) } @shown;
	if ($opt{'json'}) {
		print JSON::PP->new->canonical->encode({
			ok => 1,
			tickets => \@shown,
			counts => \%state,
		}), "\n";
	}
	else {
		if (!@shown) {
			print $opt{'refused'} ? "no refused tickets\n" : "no tickets\n";
		}
		print_ticket($_) for @shown;
		print 'tickets: ', join(', ', map { "$_ $state{$_}" } sort keys %state), "\n" if %state;
	}
	exit(($opt{'check'} && $bad) ? 1 : 0);
}

my $t = LandQueue::find_ticket($dir,
	defined $opt{'id'} ? (id => $opt{'id'}) : (branch => $opt{'branch'}));
if (!$t && (defined $opt{'id'} || defined $opt{'branch'})) {
	print STDERR "land_status: no ticket for " . ($opt{'id'} // $opt{'branch'}) . "\n";
	exit 2;
}

if ($t && $opt{'wait'}) {
	my $deadline = time + $opt{'timeout'};
	while (LandQueue::live($t) && time < $deadline) {
		sleep 2;
		$t = LandQueue::find_ticket($dir, id => $t->{'id'}) || $t;
	}
	if (LandQueue::live($t)) {
		print STDERR "land_status: ticket $t->{'id'} is still " . ($t->{'state'} // 'queued')
			. " after $opt{'timeout'} s\n";
		print_ticket($t) unless $opt{'json'};
		print json_line($t) if $opt{'json'};
		exit 2;
	}
}

print json_line($t) if $opt{'json'};
print_ticket($t) unless $opt{'json'};
print_queue($dir) unless $opt{'json'} || $t;

if ($t) {
	my $s = $t->{'state'} // 'queued';
	exit 0 if $s eq 'landed';
	exit 1 if $s eq 'refused' || $s eq 'blocked' || $s eq 'superseded';
	exit 0;
}
exit 0;

# A refused ticket is a terminal one that did not land: it still owes a fix or a
# decision, and that is what the board must show.
sub is_refused {
	my ($t) = @_;
	my $s = ($t->{'state'} // '');
	return $s eq 'refused' || $s eq 'blocked' || $s eq 'superseded';
}

sub json_line {
	my ($t) = @_;
	my $pos = $t ? LandQueue::position($dir, $t->{'id'}) : 0;
	return JSON::PP->new->canonical->encode({
		ok => 1,
		ticket => $t,
		position => $pos,
		counts => LandQueue::counts($dir),
		($t ? (cleanup => [ cleanup_steps($t) ]) : ()),
	}) . "\n";
}

# A queued landing rebases, so the branch's original commits are not ancestors
# of the trunk any more and `git branch -d` declines them. The verdict is where
# the agent is standing, so name the two steps that are safe once it says
# landed -- and only then: a refused ticket keeps its worktree for the fix.
sub cleanup_steps {
	my ($t) = @_;
	return () unless ($t->{'state'} // '') eq 'landed';
	my @steps;
	my $wt = $t->{'worktree'} // '';
	push @steps, "git worktree remove $wt" if length $wt && -d $wt;
	push @steps, "git branch -D $t->{'branch'}" if length($t->{'branch'} // '');
	return @steps;
}

sub print_ticket {
	my ($t) = @_;
	return unless $t;
	my $s = $t->{'state'} // 'queued';
	my $pos = LandQueue::position($dir, $t->{'id'});
	my $line = "ticket $t->{'id'}: $s";
	$line .= " (position $pos)" if LandQueue::live($t) && $pos;
	$line .= " v$t->{'result'}{'version'}" if ref $t->{'result'} eq 'HASH'
		&& length($t->{'result'}{'version'} // '');
	print "$line\n";
	print '  branch: ', ($t->{'branch'} // '?'), "\n";
	print '  box: ', ($t->{'box'} // '?'), ', agent: ', ($t->{'agent'} // '?'), "\n";
	print '  reason: ', ($t->{'reason'} // ''), "\n" if length($t->{'reason'} // '');
	print '  submitted: ', age($t->{'submitted_at'}), " ago\n";
	if (ref $t->{'result'} eq 'HASH' && length($t->{'result'}{'message'} // '')) {
		print '  result: ', $t->{'result'}{'message'}, "\n";
	}
	if (ref $t->{'warden'} eq 'HASH') {
		print '  warden: ', ($t->{'warden'}{'state'} // '?'), ' - ', ($t->{'warden'}{'detail'} // ''), "\n";
		print '  warden worktree: ', $t->{'warden'}{'worktree'}, "\n"
			if length($t->{'warden'}{'worktree'} // '');
		print '  warden report: ', $t->{'warden'}{'report'}, "\n"
			if length($t->{'warden'}{'report'} // '');
	}
	my @next = cleanup_steps($t);
	print '  next: your work is on the trunk, so these are safe now: `',
		join('`, `', @next), "`\n" if @next;
}

sub print_queue {
	my ($dir) = @_;
	my $c = LandQueue::counts($dir);
	print 'queue: ', ($c->{'queued'} // 0), ' queued, ', ($c->{'running'} // 0), " running\n";
	my @live = grep { LandQueue::live($_) } @{ LandQueue::tickets($dir) };
	my $n = 0;
	for my $t (@live) {
		$n++;
		if (($t->{'state'} // '') eq 'running') {
			my $pid = $t->{'pid'} // 0;
			print "  running $t->{'id'}  $t->{'branch'}", ($pid ? " (pid $pid)" : ''), "\n";
		}
		else {
			print "  $n. $t->{'id'}  $t->{'branch'}  ", age($t->{'submitted_at'}), "\n";
		}
	}
	return unless @live;
}

sub stats {
	my ($dir) = @_;
	my $events = LandQueue::events($dir);
	my (@waits, @suites, @sizes);
	my %result;
	for my $e (@$events) {
		if (($e->{'event'} // '') eq 'wave') {
			push @suites, $e->{'suite_ms'} if defined $e->{'suite_ms'};
			push @sizes,  $e->{'size'}     if defined $e->{'size'};
			$result{$e->{'result'} // 'unknown'}++;
		}
		elsif (($e->{'event'} // '') eq 'landed' && defined $e->{'wait_s'}) {
			push @waits, $e->{'wait_s'};
		}
	}
	print 'waves: ', scalar(@suites), "\n";
	print 'results: ', join(', ', map { "$_ $result{$_}" } sort keys %result), "\n" if %result;
	print 'wait (s): p50 ', fmt(LandQueue::percentile(\@waits, 0.5)),
		'  p95 ', fmt(LandQueue::percentile(\@waits, 0.95)), "\n" if @waits;
	print 'suite (s): p50 ', fmt(LandQueue::percentile(\@suites, 0.5) / 1000),
		'  p95 ', fmt(LandQueue::percentile(\@suites, 0.95) / 1000), "\n" if @suites;
	print 'wave size: ', join(', ', sort { $a <=> $b } @sizes), "\n" if @sizes;
}

sub fmt {
	my ($v) = @_;
	return 'n/a' unless defined $v;
	return sprintf('%.1f', $v);
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
land_status.pl - what is in the landing queue
  perl scripts/land_status.pl [--id ID | --branch B] [--wait] [--timeout 60]
                              [--stats] [--json]
                              [--refused [--check] | --all]
                              [--authority HOST] [--authority-root PATH]
                              [--authority-port 8022]
  --refused lists the tickets that are refused, blocked or superseded; --check
  exits 1 when one is waiting and implies --refused. --all lists every ticket.
USAGE
	exit $code;
}
