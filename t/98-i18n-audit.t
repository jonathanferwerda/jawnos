# tests-for: scripts/i18n_audit.pl
# covers:    the translation audit - completeness per language, the stale-key
#           check, --missing, and what --strict refuses to pass

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use JSON::PP ();
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# The audit compares the extractor's snapshot against each language's catalog.
# Its numbers decide whether a UI change ships untranslated, so the arithmetic
# and the two exit codes are what this pins - against a fixture catalog, via the
# script's --dir, so no real translation file is read or written.

my $script = "$FindBin::Bin/../scripts/i18n_audit.pl";

sub catalog {
	my $dir = shift;
	my @words = qw(Hello Open Save);
	my %label = map { $_ => ucfirst($_) } @words;
	write_file("$dir/strings.json",
		JSON::PP::encode_json({ 'count' => 3, 'strings' => [ map { { 'text' => $_ } } @words ] }));

	# Every non-English language gets a complete catalog, or the audit reports it
	# short - it walks the registry, not the files it finds.
	for my $code (qw(zh fr es de pt hi ar bn ru ja pa id ko it tr)) {
		write_file("$dir/ui-$code.json", JSON::PP::encode_json(\%label));
	}

	# German is missing one, French is complete but carries a key the UI dropped.
	write_file("$dir/ui-de.json", JSON::PP::encode_json({ 'Hello' => 'Hallo', 'Open' => 'Öffnen' }));
	write_file("$dir/ui-fr.json", JSON::PP::encode_json({ %label, 'Gone' => 'Parti' }));
	return $dir;
}

sub audit {
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

# --- the arithmetic ----------------------------------------------------------
{
	my $dir = catalog(tempdir(CLEANUP => 1));
	my ($rc, $out) = audit('--dir', $dir);
	is($rc, 0, 'a short language does not fail the default run');
	like($out, qr/^de\s+\S+\s+2\/3\s+66\.7%\s+missing 1/m, 'German is counted as 2 of 3');
	like($out, qr/^fr\s+\S+\s+3\/3\s+100\.0%\s+missing 0\s+stale 1/m,
		'French is complete, and its extra key is called stale');
	unlike($out, qr/^en\s/m, 'English is not audited against itself');
	like($out, qr/^1 language\(s\) short/m, 'one language is short');
}

# --- --strict is the gate ----------------------------------------------------
{
	my $dir = catalog(tempdir(CLEANUP => 1));
	my ($rc, $out) = audit('--dir', $dir, '--strict');
	is($rc, 1, '--strict fails while a language is short');

	# A complete catalog passes even under --strict.
	write_file("$dir/ui-de.json", JSON::PP::encode_json({ 'Hello' => 'Hallo', 'Open' => 'Öffnen', 'Save' => 'Speichern' }));
	write_file("$dir/ui-fr.json", JSON::PP::encode_json({ 'Hello' => 'Bonjour', 'Open' => 'Ouvrir', 'Save' => 'Enregistrer' }));
	my ($again, $out2) = audit('--dir', $dir, '--strict');
	is($again, 0, 'and passes when every language is complete');
	like($out2, qr/All listed languages are complete/, 'saying so');
}

# --- --missing names what is absent -----------------------------------------
{
	my $dir = catalog(tempdir(CLEANUP => 1));
	my ($rc, $out) = audit('--dir', $dir, '--missing');
	is($rc, 0, 'the listing run still exits 0');
	like($out, qr/^    - Save$/m, 'the missing string is named');
	my $count = () = $out =~ /^    - /mg;
	is($count, 1, 'and only the strings that are actually missing');
}

# --- no snapshot is a message, not a crash ----------------------------------
{
	my $empty = tempdir(CLEANUP => 1);
	my ($rc, $out, $err) = audit('--dir', $empty);
	is($rc, 0, 'a missing snapshot is not a failure by default');
	like($err, qr/missing .*strings\.json - run perl scripts\/i18n_extract\.pl/,
		'with the command that makes one');

	($rc, $out, $err) = audit('--dir', $empty, '--strict');
	is($rc, 1, 'but --strict refuses to pass without one');
}

done_testing();
