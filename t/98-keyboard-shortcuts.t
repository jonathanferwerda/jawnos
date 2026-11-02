# tests-for: scripts/keyboard_shortcuts.pl
# covers:    the shortcut cheat sheet - the committed doc is current, a
#           regenerate writes the same bytes, and a missing or stale file fails
#           --check

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# scripts/keyboard_shortcuts.pl renders every topic's shortcut list from
# help.pl. The committed Markdown is what a person prints, so it must be the
# script's own output, byte for byte; --check is the gate that keeps it so.
# Only --out writes elsewhere, so these runs never touch the repository.

my $root   = "$FindBin::Bin/..";
my $script = "$root/scripts/keyboard_shortcuts.pl";
my $doc    = "$root/docs/KEYBOARD-SHORTCUTS.md";

require "$root/perl/help.pl";

sub run_shortcuts {
	my @args = @_;
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or return undef;
	binmode $fh;
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $rows = 0;
$rows += scalar @{ $_->{'rows'} } for help::shortcut_sheet();
cmp_ok($rows, '>', 0, "the registry publishes shortcuts ($rows)");

# --- the committed doc is what the script would write now -------------------
{
	my ($code, $out, $err) = run_shortcuts('--check');
	is($code, 0, '--check passes against the committed doc')
		or diag("stdout: $out\nstderr: $err");
	like($out, qr{^up to date: docs/KEYBOARD-SHORTCUTS\.md \(\Q$rows\E shortcuts\)$}m,
		'it reports the file current and counts every shortcut');
}

# --- a regenerate round-trips into a temporary file -------------------------
my $dir = tempdir(CLEANUP => 1);
my $gen = "$dir/KEYBOARD-SHORTCUTS.md";
my $miss = "$dir/absent.md";

{
	my ($code, $out) = run_shortcuts("--out=$gen");
	is($code, 0, 'a write run exits 0');
	like($out, qr{^wrote \Q$gen\E \(\Q$rows\E shortcuts\)$}m, 'it reports the path it wrote');
	ok(-f $gen, 'the output file exists');
	ok(!-e "$gen.tmp", 'the half-written .tmp file was renamed away');
}

my $generated = slurp($gen);
my $committed = slurp($doc);
ok(defined $generated && length $generated, 'the generated sheet can be read');
ok(defined $committed && length $committed, 'the committed sheet can be read');
is($generated, $committed, 'regenerating produces exactly the committed bytes');

# The shape a reader relies on: a title, one section per group, one table row
# per registry shortcut.
like($generated, qr{\A# JawnOS keyboard shortcuts\n}, 'it opens with the sheet title');
my @headings = $generated =~ /^## (.+)$/mg;
cmp_ok(scalar @headings, '>', 0, 'it has a section per shortcut group');
my @table_rows = $generated =~ /^\| `/mg;
is(scalar @table_rows, $rows, 'every registry shortcut has exactly one row');

{
	my ($code, $out) = run_shortcuts('--check', "--out=$gen");
	is($code, 0, '--check accepts the file it just wrote');
	like($out, qr{^up to date: \Q$gen\E }m, 'it checks the path it was given');
}

# --- missing and stale both fail, with distinct messages -------------------
{
	my ($code, $out) = run_shortcuts('--check', "--out=$miss");
	is($code, 1, 'a missing sheet fails --check');
	like($out, qr{^missing: \Q$miss\E \(run without --check to write it\)$}m,
		'it says the file is missing and how to create it');
	ok(!-e $miss, '--check never creates the file');
}

{
	open my $fh, '>>', $gen or die "cannot append to $gen: $!";
	print $fh "\n| `Bogus` | Added by hand |\n";
	close $fh;
	my ($code, $out) = run_shortcuts('--check', "--out=$gen");
	is($code, 1, 'a hand-edited sheet fails --check');
	like($out, qr{^stale: \Q$gen\E \(run without --check to regenerate\)$}m,
		'it is reported stale, not missing');
}

done_testing();
