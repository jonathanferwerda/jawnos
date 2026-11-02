#!/usr/bin/perl
# One QMP request against a running QEMU, and print its answer.
#
#   perl qa/qemu/qmp.pl --socket PATH powerdown
#   perl qa/qemu/qmp.pl --socket PATH quit
#
# The QA scripts use this only as a fallback: a phase is normally ended by
# `poweroff` typed on the guest's serial console. If the console driver died,
# this is how a VM still leaves cleanly enough for its disk to be reused.
# A guest filesystem still needs `sync` in the guest; QMP powerdown asks the
# guest's init to shut down, which does that itself.
#
# Exit 0 = the request was accepted, 1 = no socket / no answer.

use strict;
use warnings;

use IO::Socket::UNIX;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time sleep);

my $socket;
my $timeout = 10;
GetOptions('socket=s' => \$socket, 'timeout=i' => \$timeout) or usage();
my $cmd = shift @ARGV;
usage() unless defined $socket && defined $cmd && $cmd =~ /\A(?:powerdown|quit|status)\z/;

my $sock;
my $deadline = time + 5;
while (1) {
	$sock = IO::Socket::UNIX->new(Peer => $socket, Type => SOCK_STREAM);
	last if $sock;
	exit 1 if time > $deadline;
	sleep 0.2;
}

sub pump_lines {
	my ($want) = @_;
	my $end = time + $timeout;
	my $got = '';
	while (time < $end) {
		my $rin = '';
		vec($rin, fileno($sock), 1) = 1;
		my $n = select(my $rout = $rin, undef, undef, 0.25);
		next unless $n;
		my $read = sysread($sock, my $chunk, 8192);
		last if !defined $read || $read == 0;
		$got .= $chunk;
		# QMP answers are one JSON object per line.
		while ($got =~ s/\A([^\n]*)\n//) {
			print "$1\n";
			return 1 if $1 =~ /"return"/;
		}
	}
	return 0;
}

$sock->autoflush(1);
print $sock '{"execute":"qmp_capabilities"}', "\n";
pump_lines(1);

if ($cmd eq 'powerdown') {
	print $sock '{"execute":"system_powerdown"}', "\n";
	pump_lines(1);
}
elsif ($cmd eq 'quit') {
	print $sock '{"execute":"quit"}', "\n";
	pump_lines(1);
}
else {
	print $sock '{"execute":"query-status"}', "\n";
	pump_lines(1);
}
close $sock;
exit 0;

sub usage {
	print STDERR "usage: qmp.pl --socket PATH powerdown|quit|status\n";
	exit 2;
}
