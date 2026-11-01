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
# Exit codes: 0 accepted (or status/verify passed) - 1 refused - 2 no master or
# no answer - 3 asked through the status file, unconfirmed (an older master with
# no control socket; --no-fallback turns that into a 2).

BEGIN {
	# A coded agent's shell may not have sourced ~/.zshrc, so only the system
	# @INC is present and Mojo::JSON is missing. Same fix as manager_killer.pl.
	my $base = (($ENV{HOME} || (getpwuid $<)[7] || '') . '/perl5/lib/perl5');
	if ($base =~ m{/} && -d $base) {
		my @dirs = ($base);
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ /-linux-/ || $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
		my %in_inc = map { $_ => 1 } @INC;
		unshift @INC, grep { !$in_inc{$_} } @dirs;
		my $lib = join ':', @dirs;
		$ENV{PERL5LIB} = $ENV{PERL5LIB} ? "$lib:$ENV{PERL5LIB}" : $lib;
	}
}

use strict;
use warnings;
use FindBin;
use Mojo::JSON qw(decode_json encode_json);
use File::Slurp qw(write_file);

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
	my $status_file = $ENV{'HOME'} ? "$ENV{'HOME'}/.president/status" : '.president/status';
	my $line = 'restart' . (length $opt{'reason'} ? ': ' . &control::clean_text($opt{'reason'}, 400) : '');
	unless (eval { write_file($status_file, $line); 1 }) {
		print STDERR "could not write $status_file: $@\n";
		exit 2;
	}
	print "asked through the status file instead (the master has no control socket); "
		. "the reason is recorded, but there is no verdict - check ~/.president/restart.json\n"
		unless $opt{'quiet'};
	exit 3;
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
	return 2 if ($reply->{'error'} || '') eq 'no-master' || ($reply->{'error'} || '') eq 'timeout';
	return ($reply->{'refused'} || '') eq 'verify' ? 1 : 2;
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
                    guard can take minutes)
  --json            print the master's reply verbatim
  --no-fallback     fail instead of writing the status file when the master
                    has no control socket

Exit: 0 accepted - 1 refused (the report names the file) - 2 no master or no
answer - 3 asked through the status file, no verdict.
USAGE
	exit $code;
}
