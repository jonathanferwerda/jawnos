#!/usr/bin/perl

# Ask the running jawn to restart its tree, and wait for the answer.
#
#   perl scripts/restart.pl --reason "v0.1.1734 - the fix"
#   perl scripts/restart.pl --status            # what the master is doing now
#   perl scripts/restart.pl --verify            # run the tree guard without restarting
#
# A restart used to be a word written into ~/.president/status and hoped for: the
# guard could refuse it (unparseable code) and the caller never found out, so an
# agent waited out a tree that was never coming. This speaks to the master's
# control socket instead and prints the verdict - accepted and verified, or
# refused with the report naming the file. Every restart also lands in
# ~/.president/restart.json (the last one) and restart.log (all of them).
#
# Exit codes: 0 accepted (or status/verify passed) - 1 refused - 2 no master, or no
# verdict yet (the guard is still sweeping, or the socket did not answer and the
# status-file fallback saw nothing) - 3 asked through the status file, unconfirmed
# (an older master with no control socket; --no-fallback turns that into a 2).

BEGIN {
	# A coded agent's shell may not have sourced ~/.zshrc, so only the system
	# @INC is present and Mojo::JSON is missing. Same fix as manager_killer.pl.
	#
	# Windows has no getpwuid - the call dies rather than answering - and a
	# service or a scheduled task has no HOME, so the home is resolved in the
	# same order as the platform module: HOME, USERPROFILE, the older
	# HOMEDRIVE+HOMEPATH pair, then a guarded getpwuid. The unguarded getpwuid
	# this script used to call aborted the Windows restart before it began.
	my $home = $ENV{HOME};
	$home = $ENV{USERPROFILE} if !defined $home || !length $home;
	if (!defined $home || !length $home) {
		my $drive = $ENV{HOMEDRIVE} || '';
		my $path  = $ENV{HOMEPATH} || '';
		$home = $drive . $path if length $drive || length $path;
	}
	$home = eval { (getpwuid $<)[7] } if !defined $home || !length $home;
	$home = '' unless defined $home;
	my $base = $home . '/perl5/lib/perl5';
	if ($base =~ m{/} && -d $base) {
		my @dirs = ($base);
		# The local::lib subdirectory names differ per platform. Linux keeps
		# exactly the test it has always had, so its seeded @INC cannot move;
		# Windows names its own flavour directory instead.
		my $flavour = $^O eq 'MSWin32'
			? qr/-(?:MSWin32|cygwin)-|^(?:MSWin32|x86_64|i[3-9]86)\b/i
			: qr/-linux-/;
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ $flavour || $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
		my %in_inc = map { $_ => 1 } @INC;
		unshift @INC, grep { !$in_inc{$_} } @dirs;
		# PERL5LIB is ';'-separated on Windows and ':' elsewhere.
		my $sep = $^O eq 'MSWin32' ? ';' : ':';
		my $lib = join $sep, @dirs;
		$ENV{PERL5LIB} = $ENV{PERL5LIB} ? "$lib$sep$ENV{PERL5LIB}" : $lib;
	}
}

use strict;
use warnings;
use FindBin;
use Mojo::JSON qw(decode_json encode_json);

require "$FindBin::Bin/../perl/control.pl";

my (@argv, %opt);
while (@ARGV) {
	my $arg = shift @ARGV;
	if ($arg eq '--reason' || $arg eq '-m') { $opt{'reason'} = shift @ARGV }
	elsif ($arg eq '--source') { $opt{'source'} = shift @ARGV }
	elsif ($arg eq '--timeout') { $opt{'timeout'} = shift @ARGV }
	elsif ($arg eq '--socket') { $opt{'socket'} = shift @ARGV }
	elsif ($arg eq '--status') { $opt{'cmd'} = 'status' }
	elsif ($arg eq '--verify') { $opt{'cmd'} = 'verify' }
	elsif ($arg eq '--json') { $opt{'json'} = 1 }
	elsif ($arg eq '--quiet') { $opt{'quiet'} = 1 }
	elsif ($arg eq '--no-fallback') { $opt{'no_fallback'} = 1 }
	elsif ($arg eq '--help' || $arg eq '-h') { &usage(0) }
	elsif ($arg =~ /^--/) { print STDERR "restart.pl: unknown option $arg\n"; &usage(2) }
	else { push @argv, $arg }
}
$opt{'cmd'} ||= 'restart';
$opt{'reason'} = join ' ', @argv if @argv && !defined $opt{'reason'};
$opt{'reason'} = '' unless defined $opt{'reason'};

my $request = { cmd => $opt{'cmd'}, source => $opt{'source'} || 'scripts/restart.pl' };
$request->{'reason'} = $opt{'reason'} if length $opt{'reason'};

my %send_opt;
$send_opt{'timeout'} = $opt{'timeout'} if defined $opt{'timeout'};
$send_opt{'socket'} = $opt{'socket'} if defined $opt{'socket'};

my $asked_at = time;
my $reply = &control::send($request, %send_opt);

if ($opt{'json'}) {
	print eval { encode_json($reply) }, "\n";
	exit &exit_code($reply);
}

if (($reply->{'error'} || '') eq 'no-master') {
	# Only a restart has a fallback: status and verify cannot be answered by a
	# file, so an absent master is the answer.
	if ($opt{'cmd'} ne 'restart' || $opt{'no_fallback'}) {
		print STDERR $reply->{'message'}, "\n";
		exit 2;
	}
	exit &ask_status_file($reply->{'message'}, %send_opt);
}

# The master connected but said nothing at all. That is not the same as a master
# that is working: the listener can be bound and never read (on Windows a child
# that inherited it takes the accept away from the master), or the master can be
# wedged. The status file is read by the master's own tick every second and
# needs no listener, so the restart is ordered there rather than lost - and the
# record, which the master writes before it swaps the tree, still answers.
# --no-fallback keeps the strict reading.
if (($reply->{'error'} || '') eq 'timeout' && $opt{'cmd'} eq 'restart' && !$opt{'no_fallback'}) {
	print STDERR "the control socket did not answer (" . &control::clean_text($reply->{'message'} || '', 200) . ")\n";
	exit &ask_status_file('the master did not answer over the control socket', %send_opt);
}

# status and verify have no file to fall back to: silence is their answer.
if (!$reply->{'ok'} && length($reply->{'error'} || '') && $opt{'cmd'} ne 'restart') {
	print STDERR &control::clean_text($reply->{'message'} || $reply->{'error'}, 400), "\n";
	exit 2;
}

if ($opt{'cmd'} eq 'status') {
	my $last = $reply->{'last_restart'};
	print 'jawn master ', ($reply->{'pid'} || '?'), ': status ', ($reply->{'status'} || '?'),
		(length($reply->{'version'} || '') ? ', version ' . $reply->{'version'} : ''), "\n";
	print 'why: ', &control::clean_text($reply->{'why'}, 300), "\n" if length($reply->{'why'} || '');
	print "a restart is already pending\n" if $reply->{'pending'};
	if (ref $last eq 'HASH') {
		print 'last restart ', ($last->{'at'} || '?'),
			' by ', &control::clean_text($last->{'source'} || '?', 40),
			': ', &control::clean_text($last->{'reason'} || '(no reason given)', 300), "\n";
		printf("  %s; %s\n",
			$last->{'ok'} ? 'accepted' : 'refused',
			&control::clean_text($last->{'verify'} || $last->{'report'} || '', 300));
	}
	else { print "no restart has been recorded yet\n" }
	exit 0;
}

if ($opt{'cmd'} eq 'verify') {
	if ($reply->{'ok'}) {
		print 'the tree verifies', (length($reply->{'verify'} || '') ? ': ' . $reply->{'verify'} : ''), "\n";
		exit 0;
	}
	print "the tree does not verify:\n", &control::clean_text($reply->{'report'} || $reply->{'message'} || '', 4000), "\n";
	exit 1;
}

# The request landed and the guard is still running. The restart will happen (or
# be refused with a report) when the sweep lands; the record names which. An
# agent that cannot wait that long reads the same record later, so this is said
# plainly rather than as a failure to reach the master.
if (($reply->{'error'} || '') eq 'pending') {
	print 'restart accepted by master ', ($reply->{'ack'}->{'pid'} || '?'),
		'; the guard is still running (waited ', ($send_opt{'timeout'} || 150),
		"s, the tree is still serving)\n";
	print '  reason: ', $reply->{'reason'}, "\n" if length($reply->{'reason'} || '');
	print "  the verdict lands in ~/.president/restart.json (and restart.log)\n";
	exit 2;
}

if ($reply->{'ok'}) {
	print 'restart accepted', (length($reply->{'version'} || '') ? ' (v' . $reply->{'version'} . ')' : ''), "\n";
	print '  reason: ', $reply->{'reason'}, "\n" if length($reply->{'reason'} || '');
	print '  guard:  ', $reply->{'verify'}, "\n" if length($reply->{'verify'} || '');
	exit 0;
}
if (($reply->{'refused'} || '') eq 'verify') {
	print "restart REFUSED - the tree is still serving and the code does not verify:\n",
		&control::clean_text($reply->{'report'} || '', 4000), "\n";
	exit 1;
}
print STDERR 'restart failed: ', &control::clean_text($reply->{'message'} || $reply->{'error'} || 'no answer', 400), "\n";
exit 2;

sub exit_code {
	my $reply = shift;
	return 0 if $reply->{'ok'};
	return 2 if ($reply->{'error'} || '') eq 'no-master'
		|| ($reply->{'error'} || '') eq 'timeout'
		|| ($reply->{'error'} || '') eq 'pending';
	return ($reply->{'refused'} || '') eq 'verify' ? 1 : 2;
}

# The old channel: one word in a file the master reads every second. It carries
# the reason, so the record the master writes names this request, and the record
# is what answers when the socket does not. HOME is not set on Windows (a service
# or a scheduled task has only USERPROFILE), so the path comes from the platform
# module - the old expression wrote ./.president/status, which no master reads.
sub ask_status_file {
	my ($why, %send_opt) = @_;
	my $status_file = &control::status_file();
	my $line = 'restart' . (length $opt{'reason'} ? ': ' . &control::clean_text($opt{'reason'}, 400) : '');
	# force: this caller's request replaces an older unread one, and the writer
	# creates ~/.president when this is the first thing on the box (a packaged
	# install that has never run a master).
	my $wrote = &control::publish_status($status_file, $line, force => 1);
	unless ($wrote) {
		print STDERR "could not write $status_file\n";
		exit 2;
	}
	print STDERR "asked through the status file instead ($why); the reason is recorded there\n"
		unless $opt{'quiet'};
	# The master writes the record before it swaps the tree, so a bounded wait
	# here turns the fallback into a verdict instead of a hope. A guard that is
	# still sweeping keeps the tree serving and the record unwritten: that is the
	# 3 - asked, no verdict yet.
	my $record = &control::await_record(
		since => $asked_at,
		# the master's own wording for a reasonless file request
		reason => length($opt{'reason'} || '') ? $opt{'reason'} : 'asked through the status file',
		timeout => ($send_opt{'timeout'} || 150) > 60 ? 60 : ($send_opt{'timeout'} || 150),
	);
	if ($record) {
		if ($record->{'ok'}) {
			print 'restart accepted', (length($record->{'version'} || '') ? ' (v' . $record->{'version'} . ')' : ''), "\n";
			print '  reason: ', $record->{'reason'}, "\n" if length($record->{'reason'} || '');
			print '  guard:  ', $record->{'verify'}, "\n" if length($record->{'verify'} || '');
			exit 0;
		}
		if (($record->{'refused'} || '') eq 'verify') {
			print "restart REFUSED - the tree is still serving and the code does not verify:\n",
				&control::clean_text($record->{'report'} || '', 4000), "\n";
			exit 1;
		}
		print STDERR 'restart failed: ', &control::clean_text($record->{'report'} || $record->{'refused'} || 'refused', 400), "\n";
		exit 2;
	}
	print "the restart is ordered, but there is no verdict yet - check ~/.president/restart.json\n"
		unless $opt{'quiet'};
	exit 3;
}

sub usage {
	my $code = shift;
	print <<'USAGE';
restart.pl - ask the jawn master to restart its tree, and hear why it did

  perl scripts/restart.pl [--reason "why"] [--source name]
  perl scripts/restart.pl --status        the master's state and the last restart
  perl scripts/restart.pl --verify        run the tree guard, change nothing

  --reason TEXT     what this restart is for; it travels into the record
  --source NAME     who asked (default scripts/restart.pl)
  --timeout SECS    how long to wait for the verdict (default 150; a cold
                    guard can take minutes, and an acknowledgement arrives at
                    once either way)
  --json            print the master's reply verbatim
  --no-fallback     fail instead of ordering the restart through the status
                    file when the control socket is absent or silent

Exit: 0 accepted - 1 refused (the report names the file) - 2 no master or no
verdict yet - 3 ordered through the status file, no verdict yet.
USAGE
	exit $code;
}
