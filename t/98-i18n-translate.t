# tests-for: scripts/i18n_translate.pl
# covers:    the translator's dry run - which languages it targets, that it asks
#           no model and writes nothing, and what it refuses

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use JSON::PP ();
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# A dry run must cost nothing: no model call, no file written. That is the whole
# point of the flag, so it is what this pins - plus the two refusals (no catalog,
# no target language) that keep an accidental real run from doing nothing.

my $script = "$FindBin::Bin/../scripts/i18n_translate.pl";

sub fixture {
	my $dir = tempdir(CLEANUP => 1);
	write_file("$dir/strings.json", JSON::PP::encode_json({
		'count' => 3,
		'strings' => [ map { { 'text' => $_, 'sources' => ['templates/apps/chat.html.ep'] } }
			qw(Hello Open Save) ],
	}));
	write_file("$dir/ui-de.json", JSON::PP::encode_json({ 'Hello' => 'Hallo' }));
	return $dir;
}

sub translate {
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

# --- the dry run plans and stops --------------------------------------------
{
	my $dir = fixture();
	my $before = read_file("$dir/ui-de.json");
	my ($rc, $out) = translate('--dir', $dir, '--langs', 'de', '--dry-run');
	is($rc, 0, 'the dry run exits 0');
	like($out, qr/^de\b/m, 'it names the language it targeted');
	like($out, qr/^  batch 1: 2 strings, /m, 'and plans the two missing strings in one batch');
	like($out, qr/dry run|dry-run/i, 'saying that it wrote nothing');
	is(read_file("$dir/ui-de.json"), $before, 'the catalog is untouched');
}

# --- --limit narrows the work -----------------------------------------------
# The catalog is sorted, so --limit takes the first N strings, not the first N
# pending ones: Hello is already translated, Open is not.
{
	my $dir = fixture();
	my ($rc, $out) = translate('--dir', $dir, '--langs', 'de', '--limit', '2', '--dry-run');
	is($rc, 0, 'a limited dry run exits 0');
	like($out, qr/^  batch 1: 1 strings, /m, 'and plans exactly one pending string');
}

# --- refusals ---------------------------------------------------------------
{
	my $dir = fixture();
	my ($rc, $out, $err) = translate('--dir', $dir, '--langs', 'xx', '--dry-run');
	isnt($rc, 0, 'an unknown language is refused');
	like($err, qr/no target languages/, 'by name');

	my $empty = tempdir(CLEANUP => 1);
	($rc, $out, $err) = translate('--dir', $empty, '--dry-run');
	isnt($rc, 0, 'a missing catalog is refused');
	like($err, qr/missing .*strings\.json - run perl scripts\/i18n_extract\.pl first/,
		'with the command that makes one');
}

done_testing();
