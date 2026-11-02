# tests-for: scripts/js_parts_check.pl
# covers:    the split verifier - a reconstructed script must be byte-identical,
#           and it must say where the first difference is

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# A big script is split by keeping the old path as an index (the first segment)
# and moving the rest into a folder of the same name, in numeric order. The only
# text a split may add is the [[js-split]] manifest. scripts/js_parts_check.pl is
# what makes that safe, and nothing was testing it - it is the tool the split
# rules depend on, so a regression here would silently mangle a script.

my $root   = "$FindBin::Bin/..";
my $script = "$root/scripts/js_parts_check.pl";

sub check {
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

my $manifest = "/* [[js-split]]\n\t01_c.js 02_d.js\n[[/js-split]] */\n";
my $original = "var a = 1;\nvar b = 2;\nvar c = 3;\nvar d = 4;\n";

sub fixture {
	my %a = @_;
	my $dir = tempdir(CLEANUP => 1);
	write_file("$dir/orig.js", $original);
	make_path("$dir/big");
	write_file("$dir/big.js", $manifest . "var a = 1;\nvar b = 2;\n");
	write_file("$dir/big/01_c.js", $a{'part'} // "var c = 3;\n");
	write_file("$dir/big/02_d.js", "var d = 4;\n");
	return $dir;
}

# --- an honest split reconstructs the original -------------------------------
{
	my $dir = fixture();
	my ($rc, $out) = check("$dir/orig.js", "$dir/big.js");
	is($rc, 0, 'a faithful split passes');
	like($out, qr/^OK big\.js:/m, 'and says so');
	unlike($out, qr/MISMATCH|SYNTAX/, 'with no complaint');
}

# --- a changed part is caught, and located ----------------------------------
{
	my $dir = fixture(part => "var c = 33;\n");
	my ($rc, $out) = check("$dir/orig.js", "$dir/big.js");
	is($rc, 1, 'a changed part fails');
	like($out, qr/MISMATCH at reconstructed line 3/, 'at the line it diverges');
	like($out, qr/var c = 3;/, 'showing the original');
	like($out, qr/var c = 33;/, 'and the rebuilt text');
}

# --- the index must declare the split ---------------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/big");
	write_file("$dir/orig.js", $original);
	write_file("$dir/big.js", "var a = 1;\n");
	write_file("$dir/big/01.js", "var b = 2;\n");
	my ($rc, $out) = check("$dir/orig.js", "$dir/big.js");
	is($rc, 1, 'an index with no manifest is refused');
	like($out, qr/NO MANIFEST/, 'by name');
}

# --- a split with no parts is refused ---------------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/big");
	write_file("$dir/orig.js", $original);
	write_file("$dir/big.js", $manifest . "var a = 1;\n");
	my ($rc) = check("$dir/orig.js", "$dir/big.js");
	isnt($rc, 0, 'an empty parts folder is refused');
}

done_testing();
