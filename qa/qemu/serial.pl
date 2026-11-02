#!/usr/bin/perl
# Drive a guest's serial console from a step file.
#
#   perl qa/qemu/serial.pl --socket PATH --log PATH --status PATH \
#        --steps PATH [--timeout SECONDS] [--connect-timeout SECONDS]
#
# A step file holds one instruction per line:
#
#   expect REGEX [SECONDS]   wait until the guest's output matches REGEX
#   send TEXT                write TEXT and a carriage return to the guest
#   until-file NAME          wait until NAME exists (relative to the log's
#                            directory), draining the console while it waits
#   sleep SECONDS            keep draining the console for a while
#
# Everything the guest writes is appended raw to --log; what the harness sends
# is appended as a `#QA send: ...` line, so one file is the whole transcript.
# --status gets one line per step and a final verdict, so the shell driver does
# not have to parse the transcript.
#
# Two properties matter:
#
#   * the buffer after a `send` is cleared, so an `expect` never matches the
#     text the harness just typed (the console echoes it back);
#   * the console is drained while waiting on a file or a sleep, because a guest
#     writing into a full serial buffer blocks the writer, not us.
#
# Exit 0 = every step matched, 3 = a step timed out or the console closed,
# 4 = the harness itself could not start (bad arguments, no socket).

use strict;
use warnings;

use IO::Socket::UNIX;
use IO::Select;
use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname);
use File::Spec;
use Time::HiRes qw(time sleep);

my %opt = (
	'timeout'         => 600,
	'connect-timeout' => 30,
);
GetOptions(\%opt, 'socket=s', 'log=s', 'status=s', 'steps=s',
	'timeout=i', 'connect-timeout=i')
	or do { print STDERR usage(); exit 4 };
for my $need (qw(socket log status steps)) {
	next if defined $opt{$need} && length $opt{$need};
	print STDERR usage();
	exit 4;
}

sub usage {
	return "usage: serial.pl --socket PATH --log PATH --status PATH --steps PATH "
		. "[--timeout SECONDS] [--connect-timeout SECONDS]\n";
}

my @steps;
{
	open(my $fh, '<', $opt{'steps'}) or do {
		print STDERR "serial: $opt{steps}: $!\n";
		exit 4;
	};
	while (my $line = <$fh>) {
		$line =~ s/\r?\n\z//;
		next if $line =~ /\A\s*(?:#|$)/;
		my ($verb, $arg) = $line =~ /\A\s*(\S+)\s?(.*)\z/;
		unless (defined $verb && $verb =~ /\A(?:expect|send|until-file|sleep)\z/) {
			print STDERR "serial: unknown step: $line\n";
			exit 4;
		}
		push @steps, [ $verb, (defined $arg ? $arg : '') ];
	}
	close $fh;
}

open(my $status, '>', $opt{'status'}) or do {
	print STDERR "serial: $opt{status}: $!\n";
	exit 4;
};
$status->autoflush(1);
open(my $log, '>>', $opt{'log'}) or do {
	print STDERR "serial: $opt{log}: $!\n";
	exit 4;
};
$log->autoflush(1);

my $sock;
my $deadline = time + $opt{'connect-timeout'};
while (1) {
	$sock = IO::Socket::UNIX->new(Peer => $opt{'socket'}, Type => SOCK_STREAM);
	last if $sock;
	if (time > $deadline) {
		print STDERR "serial: cannot connect to $opt{socket}: $!\n";
		print $status "driver fail no socket\n";
		exit 4;
	}
	sleep 0.2;
}
my $sel = IO::Select->new($sock);
my $buf = '';
my $eof = 0;

sub say_status { print $status join(' ', @_), "\n" }

sub pump {
	my ($secs) = @_;
	my $end = time + $secs;
	while (!$eof) {
		my $left = $end - time;
		last if $left <= 0;
		my $wait = $left > 0.25 ? 0.25 : $left;
		my @ready = $sel->can_read($wait);
		last unless @ready;
		my $n = sysread($sock, my $chunk, 8192);
		if (!defined $n || $n == 0) { $eof = 1; last }
		print $log $chunk;
		$buf .= $chunk;
		# A runaway guest must not grow this process; the tail is all an
		# expect pattern needs.
		$buf = substr($buf, -262144) if length($buf) > 262144;
	}
	return $eof;
}

sub wait_for {
	my ($pattern, $limit) = @_;
	my $re = eval { qr/$pattern/ };
	return (0, 'bad regex') unless $re;
	return (1, 'already') if $buf =~ $re;
	my $t0 = time;
	while (1) {
		return (0, 'timeout after ' . int(time - $t0) . 's') if time - $t0 > $limit;
		my $was = $buf;
		pump(0.25);
		return (1, 'matched') if $buf =~ $re;
		return (0, 'console closed') if $eof && $buf eq $was;
	}
}

sub until_file {
	my ($name, $limit) = @_;
	my $path = $name =~ m{\A/}
		? $name
		: File::Spec->catfile(dirname(File::Spec->rel2abs($opt{'log'})), $name);
	my $t0 = time;
	while (!-e $path) {
		return (0, 'timeout after ' . int(time - $t0) . 's') if time - $t0 > $limit;
		pump(0.25);
	}
	return (1, 'found');
}

my $verdict = 'ok';
my $n = 0;
for my $step (@steps) {
	$n++;
	my ($verb, $arg) = @$step;
	my ($ok, $why) = (1, 'done');

	if ($verb eq 'expect') {
		my $limit = $opt{'timeout'};
		# `expect REGEX SECONDS` pins one step's budget; the pattern never
		# ends in a bare number in the step files we ship.
		if ($arg =~ /\A(.*?)\s+(\d+)\z/s) { $arg = $1; $limit = $2 }
		($ok, $why) = wait_for($arg, $limit);
	}
	elsif ($verb eq 'send') {
		print $log "#QA send: $arg\n";
		my $out = "$arg\r";
		while (length $out) {
			my $w = syswrite($sock, $out);
			if (!defined $w) { $ok = 0; $why = 'console closed'; last }
			substr($out, 0, $w) = '';
		}
		$buf = '';
	}
	elsif ($verb eq 'until-file') {
		($ok, $why) = until_file($arg, $opt{'timeout'});
	}
	elsif ($verb eq 'sleep') {
		pump($arg + 0);
	}

	say_status($n, $verb, ($ok ? 'ok' : 'FAIL'), $why);
	unless ($ok) { $verdict = 'fail'; last }
}

pump(5);
say_status('driver', $verdict);
print $log "#QA driver $verdict\n";
close $log;
exit($verdict eq 'ok' ? 0 : 3);
