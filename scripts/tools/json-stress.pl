#!/usr/bin/env perl
# Time JSON::PP on the shapes that have bitten the bridge and the sync rail.
#
# Answers: "how long does JSON::PP take on this escape/nesting shape, and does
#           it refuse it?"
# Usage:   json-stress.pl [SHAPE] [MB]
# Example: json-stress.pl uesc 4
# Read-only: builds a string in memory; touches no file.

use strict;
use warnings;

use JSON::PP ();
use Time::HiRes qw(time);

my $shape = shift @ARGV || 'uesc';
my $mb = shift @ARGV || 4;
$mb = 1 if $mb !~ /^\d+$/ || $mb < 1;
my $n = $mb * 1024 * 1024;

# The escape shapes are a bridge event (`{"event":"message",...}`) whose data is
# one long escape run; the nesting shapes are the raw text a broken encoder
# sends, with no wrapper.
my $line;
my $wrapped = 0;
if    ($shape eq 'uesc')   { $line = ('\u0000' x int($n / 6)); $wrapped = 1 }
elsif ($shape eq 'bslash') { $line = ('\\\\' x int($n / 2));   $wrapped = 1 }
elsif ($shape eq 'escquote') { $line = ('\\"' x int($n / 2));  $wrapped = 1 }
elsif ($shape eq 'wide')   { $line = ('0,' x int($n / 2));     $wrapped = 1 }
elsif ($shape eq 'nested') { $line = ('[' x $n) }
elsif ($shape eq 'obj')    { $line = ('{"a":' . ('[' x $n)) }
elsif ($shape eq 'commas') { $line = ('[' . ('1,' x ($n / 2)) . '1]') }
elsif ($shape eq 'unterminated') { $line = ('"' . ('x' x $n)) }
elsif ($shape eq 'plain')  { $line = ('x' x $n) }
else {
	warn "json-stress: unknown shape '$shape'\n";
	usage(2);
}
$line = '{"event":"message","mac":"AA:BB","data":"' . $line . '"}' if $wrapped;

print "shape=$shape bytes=", length($line), "\n";
my $t = time;
my $ok = eval { JSON::PP->new->decode($line); 1 };
printf "decode %s in %.2fs err=%s\n",
	($ok ? 'ok' : 'died'), time - $t,
	(defined $@ && $@ ? substr($@, 0, 80) : 'none');
exit 0;

sub usage {
	my ($code) = @_;
	my $fh = $code ? \*STDERR : \*STDOUT;
	print $fh <<'TXT';
usage: json-stress.pl [SHAPE] [MB]

SHAPE is one of:
  uesc          an escaped NUL run inside a bridge message   (default)
  bslash        an escaped-backslash run
  escquote      an escaped-quote run
  wide          bare comma-separated digits (the old wide-character reply)
  nested        a lone run of '[' (deep nesting)
  obj           an object opening into deep nesting
  commas        many small numbers in one array
  unterminated  an unterminated string
  plain         unescaped filler

MB is the payload size (default 4). The line is built and decoded in memory;
a decode that dies is the answer, not a failure of the probe.
TXT
	exit $code;
}
