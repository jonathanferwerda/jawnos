#!/usr/bin/env perl
# ---------------------------------------------------------------------------
# sealed_selftest.pl - prove every offered encryption standard still round-trips.
#
# For each standard the Configure list offers, this seals a temporary file, opens
# it through the same helpers rock_and_roll uses (wrong credentials included),
# strips the padding, and decrypts a handful of ranges. It is deliberately
# database-free and writes only to a temp directory, so it is safe to run beside
# the live app.
#
#   perl scripts/sealed_selftest.pl
#   perl scripts/sealed_selftest.pl --standard aes-256-cbc --bytes 20000
#
# Exit status is 0 only when every check passes. Run it after touching
# note_cipher_spec / note_seal_container / note_open_container / note_open_slice.
# ---------------------------------------------------------------------------
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Getopt::Long qw(GetOptions);
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use File::Type;

my $root = File::Spec->catdir($Bin, '..');
chdir $root or die "cannot enter $root: $!\n";
require './gb.pl';
require './subroutines.pl';

my ($only, $bytes) = (undef, 120_000);
GetOptions('standard=s' => \$only, 'bytes=i' => \$bytes) or die "usage: $0 [--standard NAME] [--bytes N]\n";

my @standards = $only ? ($only) : @{ subs::note_encryption_standards() };
die "no standards to test\n" unless @standards;

# A known magic on the front so the plaintext verdict has something to find.
my $plain = "\x89PNG\r\n\x1a\n" . join '', map { chr(($_ * 37 + 11) & 255) } 1 .. $bytes;
my $dir = tempdir(CLEANUP => 1);
my ($pt, $enc) = ("$dir/plain.bin", "$dir/sealed.enc");
write_file($pt, $plain);

my $inspect = sub {
	return &subs::plaintext_verdict($_[0]);
};

my @ranges = ([0, 100], [1, 1], [15, 33], [4096, 8192], [length($plain) - 10, 10], [int(length($plain) / 2), undef]);
my $fail = 0;

for my $std (@standards) {
	unlink $enc;
	my $ok = 1;
	my $why = '';

	unless (subs::seal_file($pt, $enc, 'selftest-secret', $std)) {
		print "FAIL $std: could not seal\n";
		$fail++;
		next;
	}

	my $container = read_file($enc);
	my $raw = subs::note_open_container($container, 'selftest-secret', $std, 1);

	# the credential walk, including keys that must not open it
	my $opened = subs::sealed_file_open($enc, [ 'wrong-one', 'wrong-two', 'selftest-secret' ], [$std], 1, $inspect);
	if (!$opened || $opened->{'data'} ne $raw) { $ok = 0; $why = 'wrong-credential walk' }

	# padding stripped (the note/file payload path)
	my $stripped = subs::sealed_file_open($enc, ['selftest-secret'], [$std], 0, $inspect);
	if (!$stripped || $stripped->{'data'} ne $plain) { $ok = 0; $why ||= 'padding strip' }

	# the streaming path: the same container pumped out in 1 MiB chunks
	if (subs::note_cipher_spec($std)) {
		my $job = subs::sealed_file_open($enc, ['selftest-secret'], [$std], 1, $inspect, undef, 1);
		if (!$job || !$job->{'stream'}) { $ok = 0; $why ||= 'stream open' }
		else {
			my $spec = $job->{'spec'};
			my $mode = $spec->{'family'} eq 'ctr' ? subs::note_ctr_mode($spec) : subs::note_cbc_mode($spec, 1);
			my $stream = $mode->start_decrypt($job->{'key'}, $job->{'iv'});
			my $container = $job->{'container'};
			my ($offset, $end, $step, $out) = (0, length($container) - 16, 1024 * 1024, '');
			while ($offset < $end) {
				my $take = $offset + $step > $end ? $end - $offset : $step;
				$out .= $stream->add(substr($container, 16 + $offset, $take));
				$offset += $take;
			}
			$out .= $stream->finish;
			if ($out ne $raw) { $ok = 0; $why ||= 'stream body' }
		}
	}

	# range decryption against the same byte stream rock_and_roll serves
	for my $r (@ranges) {
		my ($start, $len) = @{$r};
		my $got = subs::sealed_file_open($enc, ['selftest-secret'], [$std], 1, $inspect, [ $start, $len ]);
		my $want = defined $len ? substr($raw, $start, $len) : substr($raw, $start);
		if (!$got || $got->{'data'} ne $want || $got->{'start'} != $start) {
			$ok = 0;
			$why ||= "range $start/" . (defined $len ? $len : 'end');
			last;
		}
	}

	if ($ok) { print "ok   $std\n" }
	else { print "FAIL $std: $why\n"; $fail++ }
}

print $fail ? "sealed self-test: $fail failure(s)\n" : "sealed self-test: all " . scalar(@standards) . " standard(s) ok\n";
exit($fail ? 1 : 0);
