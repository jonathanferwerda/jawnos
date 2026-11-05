#!/usr/bin/env perl
# WAV energy report: per-window RMS, peak and zero crossings.
#
# Answers: "is this clip silence, a tone or speech, and where does it start?"
# Usage:   wav-stat.pl FILE [--window MS] [--seconds N]
# Example: wav-stat.pl /tmp/call.wav --window 100
# Read-only: reads the named file only.

use strict;
use warnings;

use Getopt::Long qw(GetOptions);

my $window_ms = 1000;
my $seconds;
my $help = 0;

GetOptions(
	'window=i'  => \$window_ms,
	'seconds=i' => \$seconds,
	'help|h'    => \$help,
) or usage(2);
usage(0) if $help;
usage(2) unless @ARGV;

my $file = shift @ARGV;
usage(2) if @ARGV;
usage(2) if $window_ms < 1;
usage(2) if defined $seconds && $seconds < 1;

open(my $fh, '<:raw', $file) or die "$file: $!\n";
my $riff = do { local $/; <$fh> };
close $fh;
die "$file: not a RIFF file\n" unless substr($riff, 0, 4) eq 'RIFF';

# Walk the chunks rather than assuming a 44-byte header: ffmpeg and sox add
# LIST/fact chunks before `data`, and the old fixed offset reads their bytes as
# audio.
my ($format, $channels, $rate, $bits, $data) = (0, 0, 0, 0, undef);
my $off = 12;
while ($off + 8 <= length $riff) {
	my ($id, $len) = unpack('a4 V', substr($riff, $off, 8));
	my $body = substr($riff, $off + 8, $len);
	if ($id eq 'fmt ' && length $body >= 16) {
		($format, $channels, $rate) = unpack('v v V', $body);
		$bits = unpack('v', substr($body, 14, 2));
	}
	elsif ($id eq 'data') {
		$data = $body;
		last;
	}
	$off += 8 + $len + ($len % 2);    # chunks are word-aligned
}
die "$file: no fmt/data chunk\n" unless defined $data && $rate;
die "$file: not 16-bit PCM\n" unless $format == 1 && $bits == 16 && $channels;
$channels = 1 if $channels < 1;

my @all = unpack('s<*', $data);
my @samples = $channels == 1 ? @all : @all[ map { $_ * $channels } 0 .. int(@all / $channels) - 1 ];

my $per_window = int($rate * $window_ms / 1000);
$per_window = 1 if $per_window < 1;
my $limit = defined $seconds ? int($rate * $seconds) : scalar @samples;
$limit = scalar @samples if $limit > @samples;

my ($at, $windows, $sum_rms, $peak) = (0, 0, 0, 0);
while ($at < $limit) {
	my $end = $at + $per_window;
	$end = $limit if $end > $limit;

	my ($sum_sq, $window_peak, $crossings, $prev) = (0, 0, 0, 0);
	for my $v (@samples[ $at .. $end - 1 ]) {
		$sum_sq += $v * $v;
		my $abs = abs($v);
		$window_peak = $abs if $abs > $window_peak;
		$crossings++ if ($v >= 0) != ($prev >= 0);
		$prev = $v;
	}
	my $rms = $end > $at ? int(sqrt($sum_sq / ($end - $at))) : 0;
	$peak = $window_peak if $window_peak > $peak;
	$sum_rms += $rms;
	$windows++;
	printf "%8.2fs rms=%5d peak=%5d zc=%4d\n", $at / $rate, $rms, $window_peak, $crossings;

	$at = $end;
}

my $seconds_total = $rate ? @samples / $rate : 0;
printf "windows=%d seconds=%.2f mean_rms=%d peak=%d\n",
	$windows, $seconds_total, ($windows ? int($sum_rms / $windows) : 0), $peak;

sub usage {
	my ($code) = @_;
	my $fh = $code ? \*STDERR : \*STDOUT;
	print $fh <<'TXT';
usage: wav-stat.pl FILE [--window MS] [--seconds N]

  FILE       a 16-bit PCM WAV; the data chunk is found by walking the RIFF.
  --window   the report window in milliseconds (default 1000; 100 is the
             scale a voice gate judges a pause on).
  --seconds  stop after the first N seconds (default: the whole file).

Each window prints RMS, peak and zero crossings; the last line summarises the
windows analysed. Silence is rms=0, a tone has a steady rms and few crossings,
and speech moves between them.
TXT
	exit $code;
}
