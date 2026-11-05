# tests-for: scripts/sealed_selftest.pl lib/JawnOS/Domain/Note.pm
# covers:    the sealed-file self-test - every offered standard round-trips, and
#           a failure is reported as one

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# This script is the guard on the seal/open path: it seals a file under each
# cipher the Configure list offers, opens it again (including with the wrong
# credentials), strips the padding, streams it, and decrypts ranges. A defect in
# note_seal_container / note_open_slice / the cipher helpers is what it exists to
# catch, so it is worth running in the suite.

my $script = "$FindBin::Bin/../scripts/sealed_selftest.pl";

sub selftest {
	my @args = @_;
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

# --- one standard, byte for byte --------------------------------------------
{
	my ($rc, $out) = selftest('--standard', 'aes-256-cbc', '--bytes', 2000);
	is($rc, 0, 'aes-256-cbc round-trips');
	like($out, qr/^ok\s+aes-256-cbc$/m, 'and is reported ok');
	like($out, qr/all 1 standard\(s\) ok/, 'with a clean summary');
}

# --- a payload smaller than the range list ----------------------------------
# The ranges must stay inside the plaintext: a short --bytes asked the opener for
# bytes that were never there and the run blamed the cipher. This is the case
# that caught it.
{
	my ($rc, $out) = selftest('--standard', 'aes-256-cbc', '--bytes', 8);
	is($rc, 0, 'a payload of 8 bytes still passes every path');
	like($out, qr/^ok\s+aes-256-cbc$/m, 'including the range decryption');
}

# --- a cipher the machine does not have is a failure, not a crash -----------
{
	my ($rc, $out) = selftest('--standard', 'not-a-cipher', '--bytes', 500);
	is($rc, 1, 'an unusable standard exits 1');
	like($out, qr/^FAIL not-a-cipher: could not seal$/m, 'and says which step failed');
	like($out, qr/1 failure\(s\)/, 'and counts it');
}

# --- every offered standard, the way it is meant to be run ------------------
{
	my ($rc, $out) = selftest('--bytes', 12000);
	is($rc, 0, 'every offered standard round-trips');
	my @ok = $out =~ /^ok\s+(\S+)$/mg;
	cmp_ok(scalar @ok, '>=', 10, 'across the whole catalogue (' . scalar(@ok) . ' standards)');
	unlike($out, qr/^FAIL/m, 'with nothing failing');
}

# --- a known defect: what counts as proof a credential opened the file -----
# sealed_file_probe now tries a strong verdict first (a four-byte signature or a
# structural check) and only falls back to the loose one for a file whose type
# the house cannot name, which is what stopped the wrong-credential walk failing
# about once in fifteen runs under load. The loose verdict itself still says yes
# to a two-byte coincidence through File::Type, so a file of an unknown type can
# still be opened with a wrong credential. The right behaviour is that a
# two-byte magic alone is never proof; this asserts it and is expected to fail
# until the loose verdict is tightened too.
TODO: {
	local $TODO = "a wrong credential can match a weak File::Type signature (Note.pm:460)";
	my $root = "$FindBin::Bin/../";
	my $code = 'chdir "' . $root . '" or die;'
		. ' require "./perl/gb.pl"; require "./perl/subroutines.pl";'
		. ' my $g = "MZ" . join "", map { chr(($_ * 91 + 7) & 255) } 1 .. 200;'
		. ' exit(&subs::plaintext_verdict($g) ? 0 : 1)';
	my $errh = gensym;
	my $pid = open3(my $in, my $out, $errh, $^X, '-e', $code);
	close $in;
	my $ignored_out = do { local $/; <$out> };
	my $ignored_err = do { local $/; <$errh> };
	close $out;
	close $errh;
	waitpid($pid, 0);
	is($? >> 8, 1, 'a two-byte magic is not proof that a credential opened the file');
}

done_testing();
