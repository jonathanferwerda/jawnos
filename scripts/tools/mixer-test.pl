#!/usr/bin/env perl
# What the virtual handset would do, and where the call's streams are now.
#
# Answers: "which capture/playback command would the handset use, and which
#           device is the call's pair on?"
# Usage:   mixer-test.pl [--mac ADDRESS] [--ensure]
# Example: mixer-test.pl --mac AA:BB:CC:DD:EE:FF
# Read-only by default; --ensure creates the null sinks and remap source.

use strict;
use warnings;

use FindBin ();
use Getopt::Long qw(GetOptions);

my $mac;
my $ensure = 0;
my $help = 0;

GetOptions(
	'mac=s'  => \$mac,
	'ensure!' => \$ensure,
	'help|h' => \$help,
) or usage(2);
usage(0) if $help;

my $root = "$FindBin::Bin/../..";
my $mixer = "$root/lib/JawnOS/Sco/Mixer.pm";
-e $mixer or die "mixer-test: no $mixer\n";

require $mixer;
my $m = bless {}, 'JawnOS::Sco::Mixer';

print "ensure: ", $m->ensure(), " new module(s)\n" if $ensure;
print "capture: ", $m->capture_command(), "\n";
print "playback: ", $m->playback_command(), "\n";

my $s = $m->call_streams($mac);
print 'streams: sink_input=', ($s->{'sink_input'} // '-'),
	' sink=', ($s->{'sink'} // '-'),
	' source_output=', ($s->{'source_output'} // '-'),
	' source=', ($s->{'source'} // '-'), "\n";

sub usage {
	my ($code) = @_;
	my $fh = $code ? \*STDERR : \*STDOUT;
	print $fh <<'TXT';
usage: mixer-test.pl [--mac ADDRESS] [--ensure]

  --mac ADDRESS  the Bluetooth card's address, to find the call's two streams.
  --ensure       load the null sinks and remap source if they are missing
                 (the only write; without it nothing is created).

Prints the capture and playback commands the handset would run, and for a MAC
the sink/source each of the call's streams is on.
TXT
	exit $code;
}
