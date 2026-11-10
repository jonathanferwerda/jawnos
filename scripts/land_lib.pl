#!/usr/bin/perl

# The landing queue's shared pieces: where the repo is, where the queue lives,
# how a ticket is written and read, and which files are hot.
#
# This is a library, not a command: land_enqueue.pl, land_status.pl and
# land_coordinator.pl require it. The queue sits in the git common dir, so every
# worktree of this checkout sees the same tickets and a landing that cannot
# finish leaves the work reachable from origin.
#
# A ticket is one committed branch waiting to land:
#
#   { id, branch, sha, base, worktree, box, agent, reason, submitted_at,
#     state, attempts, not_before, pid, started_at, finished_at, result }
#
# state: queued -> running -> landed | refused | blocked | superseded
# queued and running are live; the rest are terminal and never retried.

package LandQueue;

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use Fcntl qw(:flock);
use File::Path qw(make_path);
use IO::Handle ();
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);

# The files nearly every task edits. One branch touching these can join a wave;
# a second one waits, because integrating two of them is where the conflicts are.
my @HOT = qw(
	lib/JawnOS/Manager/Index.pm
	lib/JawnOS/Manager/Declarations.pm
	lib/JawnOS/Domain/Loader.pm
	perl/language.pl
);
my @HOT_PREFIX = qw(
	lib/JawnOS/Routes/
	perl/help/topics_
);

sub json { return JSON::PP->new->canonical }

# Git exports GIT_DIR and friends into hooks and pre-commit children. A helper
# that answers `git -C <fixture>` must not inherit them, or it acts on the live
# checkout instead of the one it was pointed at.
sub run_cmd {
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
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	my $code = $? >> 8;
	$stdout =~ s/\s+$//;
	$stderr =~ s/\s+$//;
	my $all = $stdout;
	$all .= (length $all ? "\n" : '') . $stderr if length $stderr;
	return ($code, $all);
}

sub run_in {
	my ($dir, @cmd) = @_;
	my $old = getcwd();
	chdir $dir or return (127, "cannot enter $dir: $!");
	my @out = run_cmd(@cmd);
	chdir $old;
	return @out;
}

sub repo {
	my ($rc, $root) = run_cmd('git', 'rev-parse', '--show-toplevel');
	die "not inside a git worktree\n$root\n" if $rc != 0 || !length $root;
	my ($crc, $common) = run_cmd('git', 'rev-parse', '--path-format=absolute', '--git-common-dir');
	if ($crc != 0 || $common !~ m{^/}) {
		($crc, $common) = run_cmd('git', 'rev-parse', '--git-common-dir');
		$common = abs_path($common) if $crc == 0 && $common !~ m{^/};
	}
	die "cannot find the git common dir\n" if $crc != 0 || !defined $common || !length $common;
	$root = abs_path($root);
	return ($root, $common);
}

sub queue_dir {
	my ($common) = @_;
	my $dir = "$common/land-queue";
	make_path($dir) unless -d $dir;
	return $dir;
}

sub metrics_path {
	my ($dir) = @_;
	return "$dir/land.jsonl";
}

sub ticket_path {
	my ($dir, $id) = @_;
	return "$dir/$id.json";
}

sub next_id {
	my ($dir) = @_;
	my $path = "$dir/.seq";
	open(my $fh, '+>>', $path) or die "cannot open $path: $!\n";
	flock($fh, LOCK_EX);
	seek($fh, 0, 0);
	my $n = <$fh> // '0';
	$n = 0 unless defined $n && $n =~ /^\d+/;
	$n++;
	seek($fh, 0, 0);
	truncate($fh, 0);
	print $fh "$n\n";
	$fh->flush;
	flock($fh, LOCK_UN);
	close $fh;
	return sprintf('%08d', $n);
}

sub read_ticket {
	my ($path) = @_;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	my $t = eval { json()->decode($text) };
	return ref $t eq 'HASH' ? $t : undef;
}

sub write_ticket {
	my ($dir, $t) = @_;
	my $id = $t->{'id'} or die "ticket has no id\n";
	my $path = ticket_path($dir, $id);
	my $tmp  = "$path.$$.tmp";
	open(my $fh, '>', $tmp) or die "cannot write $tmp: $!\n";
	print $fh json()->encode($t);
	close $fh;
	rename $tmp, $path or die "cannot rename $tmp: $!\n";
	return $path;
}

sub tickets {
	my ($dir) = @_;
	opendir(my $dh, $dir) or return [];
	my @paths = map { "$dir/$_" } grep { /^\d+\.json$/ } readdir $dh;
	closedir $dh;
	my @t;
	for my $path (@paths) {
		my $t = read_ticket($path);
		push @t, $t if $t;
	}
	return [ sort {
		($a->{'submitted_at'} // 0) <=> ($b->{'submitted_at'} // 0)
			|| ($a->{'id'} // '') cmp ($b->{'id'} // '')
	} @t ];
}

sub find_ticket {
	my ($dir, %want) = @_;
	my $found;
	for my $t (@{ tickets($dir) }) {
		if (defined $want{'id'}) {
			return $t if $t->{'id'} eq $want{'id'};
			next;
		}
		next unless defined $want{'branch'} && ($t->{'branch'} // '') eq $want{'branch'};
		next if defined $want{'live'} && $want{'live'} && !live($t);
		# The newest ticket for a branch is the one to report; an older landed
		# one must not hide the refusal that came after it.
		$found = $t;
	}
	return $found;
}

sub live {
	my ($t) = @_;
	my $s = $t->{'state'} // 'queued';
	return $s eq 'queued' || $s eq 'running';
}

sub due {
	my ($t) = @_;
	# Time::HiRes hands the coordinator a float; an integer comparison keeps a
	# zero-delay requeue due in the same second the wave returned.
	return int($t->{'not_before'} // 0) <= time;
}

sub position {
	my ($dir, $id) = @_;
	my @live = grep { live($_) } @{ tickets($dir) };
	my $n = 0;
	for my $t (@live) {
		$n++;
		return $n if $t->{'id'} eq $id;
	}
	return 0;
}

sub live_count {
	my ($dir) = @_;
	return scalar grep { live($_) } @{ tickets($dir) };
}

sub counts {
	my ($dir) = @_;
	my %c = (queued => 0, running => 0);
	for my $t (@{ tickets($dir) }) {
		my $s = $t->{'state'} // 'queued';
		$c{$s}++ if exists $c{$s};
	}
	return \%c;
}

# A ticket left running by a coordinator that died is not live: its pid is gone.
# Requeue it so the next drain picks it up; the branch is on origin either way.
sub reap {
	my ($dir) = @_;
	my @reaped;
	for my $t (@{ tickets($dir) }) {
		next unless ($t->{'state'} // '') eq 'running';
		my $pid = $t->{'pid'} // 0;
		my $alive = $pid && kill(0, $pid);
		next if $alive;
		$t->{'state'}      = 'queued';
		$t->{'pid'}        = 0;
		$t->{'started_at'} = 0;
		$t->{'not_before'} = time;
		$t->{'reaped_at'}  = time;
		write_ticket($dir, $t);
		push @reaped, $t->{'id'};
	}
	return @reaped;
}

sub is_hot_path {
	my ($path) = @_;
	return 1 if grep { $path eq $_ } @HOT;
	return 1 if grep { index($path, $_) == 0 } @HOT_PREFIX;
	return 0;
}

sub is_hot_ticket {
	my ($root, $t) = @_;
	my $base = $t->{'base'} // '';
	my $sha  = $t->{'sha'} // '';
	return 0 unless length $base && length $sha;
	my ($rc, $out) = run_cmd('git', '-C', $root, 'diff', '--name-only', "$base..$sha");
	return 0 if $rc != 0;
	for my $path (split /\n/, $out) {
		return 1 if is_hot_path($path);
	}
	return 0;
}

sub changed_files {
	my ($root, $base, $sha) = @_;
	my ($rc, $out) = run_cmd('git', '-C', $root, 'diff', '--name-only', "$base..$sha");
	return () if $rc != 0;
	return grep { length } split /\n/, $out;
}

sub event {
	my ($dir, $entry) = @_;
	$entry->{'at'} = time unless defined $entry->{'at'};
	open(my $fh, '>>', metrics_path($dir)) or return;
	flock($fh, LOCK_EX);
	print $fh json()->encode($entry), "\n";
	$fh->flush;
	flock($fh, LOCK_UN);
	close $fh;
}

sub events {
	my ($dir) = @_;
	open(my $fh, '<', metrics_path($dir)) or return [];
	my @out;
	while (my $line = <$fh>) {
		next unless $line =~ /\S/;
		my $e = eval { json()->decode($line) };
		push @out, $e if ref $e eq 'HASH';
	}
	close $fh;
	return \@out;
}

sub percentile {
	my ($values, $p) = @_;
	return undef unless @$values;
	my @v = sort { $a <=> $b } @$values;
	my $i = int((@v - 1) * $p + 0.5);
	$i = 0 if $i < 0;
	$i = $#v if $i > $#v;
	return $v[$i];
}

1;
