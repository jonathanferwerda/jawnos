# tests-for: scripts/tools/wav-stat.pl scripts/tools/json-stress.pl
# covers:    the portable probes answer on a generated fixture, not a house file

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

my $root = "$FindBin::Bin/..";

sub run_tool {
	my (@args) = @_;
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

# --- wav-stat: a 100 ms tone then 100 ms of silence ----------------------
{
	my $tmp = tempdir(CLEANUP => 1);
	my $wav = "$tmp/tone.wav";
	my $rate = 8000;
	my @samples = (map { int(sin(2 * 3.14159 * 440 * $_ / $rate) * 8000) } 0 .. 799,
		(0) x 800);
	my $data = pack('s<*', @samples);
	open my $fh, '>:raw', $wav or die "$wav: $!";
	print {$fh} 'RIFF', pack('V', 36 + length $data), 'WAVEfmt ',
		pack('VvvVVvv', 16, 1, 1, $rate, $rate * 2, 2, 16),
		'data', pack('V', length $data), $data;
	close $fh;

	my ($code, $out, $err) = run_tool("$root/scripts/tools/wav-stat.pl", $wav, '--window', 100);
	is($code, 0, 'wav-stat reads the fixture') or diag $err;
	like($out, qr/^\s+0\.00s rms=\s*\d+ peak=\s*\d+ zc=\s*\d+$/m,
		'the tone window reports energy and crossings');
	like($out, qr/^\s+0\.10s rms=\s*0 peak=\s*0 zc=\s*\d+$/m,
		'the silent window reports zero energy');
	like($out, qr/windows=2 seconds=0\.20 /, 'two 100 ms windows over 0.20 s');
}

# --- json-stress: a big escape run decodes, an unterminated one does not --
{
	my ($code, $out, $err) = run_tool("$root/scripts/tools/json-stress.pl", 'uesc', 1);
	is($code, 0, 'json-stress runs') or diag $err;
	like($out, qr/^shape=uesc bytes=\d+$/m, 'names the shape and the line size');
	like($out, qr/^decode ok in [\d.]+s err=none$/m, 'a large escape run decodes');

	my (undef, $bad) = run_tool("$root/scripts/tools/json-stress.pl", 'unterminated', 1);
	like($bad, qr/^decode died in [\d.]+s err=\S/m, 'an unterminated string is refused');
}

done_testing();
