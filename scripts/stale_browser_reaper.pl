#!/usr/bin/perl

# stale_browser_reaper.pl - stop headless Chromium trees whose launcher is gone.
#
#   perl scripts/stale_browser_reaper.pl --dry-run    # say what would be reaped
#   perl scripts/stale_browser_reaper.pl              # reap
#   perl scripts/stale_browser_reaper.pl --proc-root /tmp/fake-proc --dry-run
#
# qa/lib/Ui.pm starts Chromium with --headless, a private --user-data-dir and a
# --remote-debugging-port, in its own session, and kills the process group when
# the probe ends. When the launcher dies first, the browser is reparented to
# init (ppid 1) and nothing ever signals it again. In 2026-11 four such trees ran
# for 26 hours and held ~0.8 of eight cores with no client ever connected.
#
# Safety, in order:
#   - only a browser *parent* is a candidate: it must carry --headless,
#     --user-data-dir and --remote-debugging-port, and must not carry --type=
#     (a GPU, renderer or zygote child does);
#   - a live CDP client on its debug port is never touched, and neither is a
#     port this script cannot read (0 means the browser chose one);
#   - a tree younger than --min-age (600s) is never touched;
#   - by default the parent must also be orphaned (ppid 1). --max-age (default
#     0, disabled) is the one exception: setting it reaps a browser whose live
#     launcher has held it that long with no client. It is off by default so a
#     scheduled run only touches trees nothing owns.
#
# Headed browsers, Qt WebEngine and the desktop app never carry all three flags,
# so they are not candidates at all. The exit status is 0 for any ordinary run.
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use POSIX ();

# One line: is this command line a headless browser parent? Pure, so a test can
# drive the exclusions without a real Chromium. Accepts the /proc argv list or a
# plain string; Chromium accepts `--flag=value` and `--flag value` both.
sub browser_parent {
	my ($cmdline) = @_;
	my $line = ref $cmdline ? join(' ', @{$cmdline}) : ($cmdline // '');
	return 0 unless $line =~ /(?:^|\s)--headless(?:=|\s|$)/;
	return 0 unless $line =~ /(?:^|\s)--user-data-dir(?:=|\s|$)/;
	return 0 unless $line =~ /(?:^|\s)--remote-debugging-port(?:=|\s|$)/;
	# Children inherit the profile and debug switches; selecting them too would
	# double-count and could signal a group twice.
	return 0 if $line =~ /(?:^|\s)--type=/;
	# The desktop's engine is Qt's, never Chromium's; name it so a future Qt
	# launch with debugging on cannot slip through.
	return 0 if $line =~ /QtWebEngineProcess/;
	return 1;
}

# The port CDP listens on, or undef when the flag carries no number.
sub debug_port {
	my ($cmdline) = @_;
	my $line = ref $cmdline ? join(' ', @{$cmdline}) : ($cmdline // '');
	return $1 if $line =~ /--remote-debugging-port=(\d+)/;
	return $1 if $line =~ /--remote-debugging-port\s+(\d+)/;
	return undef;
}

# The decision, and nothing else. A process record is a hash of pid, ppid,
# age_s, cmdline and client_connected. Returns the reason to reap, or undef to
# leave it alone. Pure: the scan and the test both call this.
sub reap_reason {
	my ($rec, $opt) = @_;
	return undef unless browser_parent($rec->{'cmdline'});
	# A connected client is a run in progress, whoever launched it.
	return undef if $rec->{'client_connected'};
	return undef if ($rec->{'age_s'} // 0) < $opt->{'min_age'};

	# The leak this guards: the launcher is gone, so nothing else will ever
	# signal this tree. That is the only case on by default.
	return 'orphaned' if ($rec->{'ppid'} // 0) == 1;

	# A launcher that is alive but has held an idle browser this long is stuck
	# too; the ceiling is off at 0.
	my $max = $opt->{'max_age'} // 0;
	return 'past --max-age' if $max > 0 && $rec->{'age_s'} >= $max;
	return undef;
}

# Split one scan into the trees to reap and the ones to leave. Each reaped
# record carries the reason; the caller only prints and kills.
sub select_reaps {
	my ($records, $opt) = @_;
	my (@reap, @keep);
	for my $rec (@{$records}) {
		my $why = reap_reason($rec, $opt);
		if (defined $why) { push @reap, { %{$rec}, 'reason' => $why } }
		else              { push @keep, $rec }
	}
	return (\@reap, \@keep);
}

# Local ports with an ESTABLISHED socket. Reading /proc/net is enough here and
# avoids depending on ss; a port is reported busy even when the connection
# belongs to another process, which errs towards leaving the browser alone.
sub established_ports {
	my ($root) = @_;
	my %busy;
	for my $file ('net/tcp', 'net/tcp6') {
		open(my $fh, '<', "$root/$file") or next;
		while (my $line = <$fh>) {
			next if $line =~ /^\s*sl\s/;
			my @f = split ' ', $line;
			next unless @f >= 4 && $f[3] eq '01';   # 01 = ESTABLISHED
			my ($addr, $port) = split /:/, $f[1];
			$busy{hex $port} = 1 if defined $port;
		}
		close $fh;
	}
	return \%busy;
}

# Field 3 of /proc/<pid>/stat onward, after the comm (which may contain spaces
# and parentheses, so split at the last ')').
sub read_stat {
	my ($root, $pid) = @_;
	open(my $fh, '<', "$root/$pid/stat") or return undef;
	local $/;
	my $raw = <$fh> // '';
	close $fh;
	my $close = rindex($raw, ')');
	return undef if $close < 0;
	my @f = split ' ', substr($raw, $close + 1);
	return undef unless @f >= 20;
	# index 0 is state (field 3), 1 is ppid (4), 2 is pgrp (5), 19 is
	# starttime (22).
	return { state => $f[0], ppid => $f[1], pgid => $f[2], start_ticks => $f[19] };
}

sub read_cmdline {
	my ($root, $pid) = @_;
	open(my $fh, '<', "$root/$pid/cmdline") or return undef;
	local $/;
	my $raw = <$fh> // '';
	close $fh;
	my @args = grep { length } split /\0/, $raw;
	return \@args;
}

# Every browser parent in the proc root, as process records. The age comes from
# starttime against uptime; a proc root a test supplies carries both files.
sub scan {
	my ($root) = @_;
	my $hz = POSIX::sysconf(POSIX::_SC_CLK_TCK()) || 100;
	my $uptime = 0;
	if (open(my $fh, '<', "$root/uptime")) {
		my $line = <$fh> // '';
		close $fh;
		($uptime) = $line =~ /^([\d.]+)/;
	}
	my $busy = established_ports($root);

	my @records;
	opendir(my $dh, $root) or return \@records;
	for my $name (readdir $dh) {
		next unless $name =~ /^\d+$/;
		my $stat = read_stat($root, $name);
		next unless $stat && defined $stat->{'start_ticks'};
		my $cmdline = read_cmdline($root, $name);
		next unless $cmdline && @{$cmdline};
		next unless browser_parent($cmdline);
		my $port = debug_port($cmdline);
		push @records, {
			'pid'              => $name + 0,
			'ppid'             => $stat->{'ppid'} + 0,
			'pgid'             => $stat->{'pgid'} + 0,
			'age_s'            => $uptime - $stat->{'start_ticks'} / $hz,
			'cmdline'          => $cmdline,
			'start_ticks'      => $stat->{'start_ticks'} + 0,
			# A port of 0 (or an unreadable flag) means the browser chose it, so
			# its client state cannot be proven: count it as connected.
			'client_connected' => (!defined $port || $port == 0) ? 1 : ($busy->{$port} ? 1 : 0),
		};
	}
	closedir $dh;
	return \@records;
}

# The record must still describe the process at that pid before it is signalled:
# a pid can be reused while the scan runs.
sub still_same {
	my ($rec, $root) = @_;
	my $stat = read_stat($root, $rec->{'pid'});
	return 0 unless $stat && defined $stat->{'start_ticks'};
	return 0 unless defined $rec->{'start_ticks'}
		&& $stat->{'start_ticks'} == $rec->{'start_ticks'};
	my $cmdline = read_cmdline($root, $rec->{'pid'});
	return 0 unless $cmdline && browser_parent($cmdline);
	return join("\0", @{$cmdline}) eq join("\0", @{$rec->{'cmdline'}});
}

sub is_zombie {
	my ($root, $pid) = @_;
	my $stat = read_stat($root, $pid);
	return $stat && ($stat->{'state'} // '') eq 'Z';
}

# Is anything in the tree still running? A zombie leader may sit in the table
# until init reaps it, so the leader alone is not the answer for a group.
sub tree_alive {
	my ($pid, $target, $root) = @_;
	return 1 if $target < 0 && kill(0, $target);
	return 0 if is_zombie($root, $pid);
	return kill(0, $pid) ? 1 : 0;
}

# TERM the whole session, then KILL what is left after --grace. qa/lib/Ui.pm
# calls POSIX::setsid() in the child, so the browser's pid is its process-group
# id and one signal reaches the GPU and renderer children. Never signal -$pid
# when the pgrp in /proc says otherwise: an unrelated group could share the
# number. ESRCH is not an error - the tree died between scan and kill.
sub kill_tree {
	my ($rec, $opt) = @_;
	my $pid = $rec->{'pid'};
	my $root = $opt->{'proc_root'};
	my $target = ($rec->{'pgid'} // 0) == $pid ? -$pid : $pid;

	kill 'TERM', $target;
	my $deadline = time + $opt->{'grace'};
	while (time < $deadline) {
		last unless tree_alive($pid, $target, $root);
		select undef, undef, undef, 0.2;
	}
	kill 'KILL', $target if tree_alive($pid, $target, $root);
	return $target < 0 ? 'group' : 'pid';
}

sub usage {
	return <<'USAGE';
usage: stale_browser_reaper.pl [--dry-run] [--min-age SECONDS] [--max-age SECONDS]
                               [--grace SECONDS] [--proc-root DIR] [--verbose]
USAGE
}

sub main {
	my (@argv) = @_;
	my %opt = (
		'proc_root' => '/proc',
		'min_age'   => 600,
		'max_age'   => 0,
		'grace'     => 5,
		'dry_run'   => 0,
		'verbose'   => 0,
	);
	GetOptions(
		'dry-run'     => \$opt{'dry_run'},
		'min-age=i'   => \$opt{'min_age'},
		'max-age=i'   => \$opt{'max_age'},
		'grace=i'     => \$opt{'grace'},
		'proc-root=s' => \$opt{'proc_root'},
		'verbose'     => \$opt{'verbose'},
		'help|?'      => sub { print usage(); exit 0 },
	) or do { print STDERR usage(); return 2 };

	if ($opt{'min_age'} < 0 || $opt{'max_age'} < 0 || $opt{'grace'} < 0) {
		print STDERR "stale_browser_reaper: ages and grace cannot be negative\n";
		return 2;
	}
	if ($opt{'max_age'} && $opt{'max_age'} < $opt{'min_age'}) {
		print STDERR "stale_browser_reaper: --max-age is below --min-age\n";
		return 2;
	}
	unless (-d $opt{'proc_root'}) {
		print STDERR "stale_browser_reaper: no proc root at $opt{'proc_root'}\n";
		return 2;
	}

	my $records = scan($opt{'proc_root'});
	my ($reap, $keep) = select_reaps($records, \%opt);

	my ($killed, $stale) = (0, 0);
	for my $rec (@{$reap}) {
		# Rule out pid reuse before a signal: the command line and start time
		# that made it a candidate must still be there.
		unless (still_same($rec, $opt{'proc_root'})) {
			$stale++;
			next;
		}
		if ($opt{'dry_run'} || $opt{'verbose'}) {
			printf "  pid %d (%s, %ds old%s)%s\n", $rec->{'pid'}, $rec->{'reason'},
				int($rec->{'age_s'}),
				$rec->{'ppid'} == 1 ? '' : ", ppid $rec->{'ppid'}",
				$opt{'dry_run'} ? ' - would reap' : '';
		}
		next if $opt{'dry_run'};
		my $how = kill_tree($rec, \%opt);
		$killed++;
		printf "  pid %d (%s, %ds old): TERM+KILL on %s\n", $rec->{'pid'},
			$rec->{'reason'}, int($rec->{'age_s'}), $how if $opt{'verbose'};
	}

	my $skipped = scalar(@{$keep}) + $stale;
	if ($opt{'dry_run'}) {
		printf "stale_browser_reaper: dry run - would reap %d, skipped %d\n",
			scalar(@{$reap}) - $stale, $skipped;
	}
	else {
		printf "stale_browser_reaper: reaped %d, skipped %d\n", $killed, $skipped;
	}
	return 0;
}

exit(main(@ARGV)) unless caller;
