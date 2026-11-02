# tests-for: scripts/runtime_native_bins.pl scripts/runtime_zip.pl
# covers:    M5 (docs/roadmap-handoff.md): Android refuses to exec a file in app data at targetSdk 29+, but execs one extra...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use IO::Compress::Zip qw($ZipError);

# M5 (docs/roadmap-handoff.md): Android refuses to exec a file in app data at
# targetSdk 29+, but execs one extracted under nativeLibraryDir. So the runtime's
# executables ship as jniLibs/<abi>/lib<slug>.so and the app symlinks the
# runtime path at them. This pins the converter: which entries move, how a
# symlink is recorded, what is ignored, and the dry run's promise.

my $root = "$FindBin::Bin/..";
my $bin  = "$root/scripts/runtime_native_bins.pl";

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "$path: $!";
	binmode $fh;
	local $/;
	my $body = <$fh>;
	close $fh;
	return $body;
}

# Build a zip the way scripts/runtime_zip.pl does: the Unix mode rides the
# external attributes and a symlink's target is the entry data with S_IFLNK set.
sub make_zip {
	my ($path, @entries) = @_;
	my $zip;
	foreach my $entry (@entries) {
		my ($name, $data, $mode) = @$entry;
		my $attr = ($mode << 16) & 0xFFFFFFFF;
		if (!$zip) {
			$zip = IO::Compress::Zip->new($path,
				Name    => $name,
				Time    => 315532800,
				ExtAttr => $attr,
			) or die "zip $path: $ZipError";
		}
		else {
			$zip->newStream(
				Name    => $name,
				Time    => 315532800,
				ExtAttr => $attr,
			) or die "zip $name: " . ($IO::Compress::Zip::ZipError || $ZipError);
		}
		print {$zip} $data;
	}
	$zip->close or die "zip close: " . ($ZipError // 'unknown error');
}

my $tmp = tempdir(CLEANUP => 1);
my $zip = "$tmp/runtime.zip";
my $foo = "#!/bin/sh\necho foo\n";
make_zip($zip,
	['bin/foo',        $foo,       0100755],
	['bin/bar',        'foo',      0120777],   # symlink: data is the target
	['bin/readme.txt', "read me\n", 0100644],
	['lib/x.so',       "ELF\n",    0100755],   # outside bin/ and libexec/
);

my $out = "$tmp/out";
my $run = qx{"$^X" "$bin" --zip "$zip" --out "$out" --abi arm64-v8a 2>&1};
is($? >> 8, 0, 'the converter accepts a staged runtime') or diag($run);
like($run, qr/1 executables, 1 symlinks/, 'the summary counts the entries');

ok(-f "$out/arm64-v8a/libbin_foo.so", 'the executable is written as libbin_foo.so');
is(slurp("$out/arm64-v8a/libbin_foo.so"), $foo, 'the payload is the archive bytes');
ok(((stat("$out/arm64-v8a/libbin_foo.so"))[2] & 0111), 'the payload keeps an execute bit');

ok(!-e "$out/arm64-v8a/libbin_readme_txt.so", 'a non-executable bin/ entry is not payload');
ok(!-e "$out/arm64-v8a/liblib_x_so.so", 'an executable outside bin/ and libexec/ is ignored');

my @lines = split /\n/, slurp("$out/runtime-bins.txt");
is_deeply(\@lines, [
	"bin/bar\tlink\tbin/foo",
	"bin/foo\tfile\tbin_foo",
], 'the manifest is sorted and names the file and link entries');
ok(!grep({ m{^(?:bin/readme\.txt|lib/)} } @lines), 'the ignored entries are absent from the manifest');

# A dry run is a plan only: it prints the same lines and creates nothing.
my $dry_out = "$tmp/dry-out";
my $dry = qx{"$^X" "$bin" --zip "$zip" --out "$dry_out" --abi arm64-v8a --dry-run 2>&1};
is($? >> 8, 0, 'the dry run succeeds') or diag($dry);
ok(!-e $dry_out, 'the dry run writes nothing');
like($dry, qr/^bin\/bar\tlink\tbin\/foo$/m, 'the dry run prints a link line');
like($dry, qr/^bin\/foo\tfile\tbin_foo$/m, 'the dry run prints a file line');

# A zip with only non-executables has no jniLibs payload to make.
my $empty_zip = "$tmp/empty.zip";
make_zip($empty_zip, ['bin/readme.txt', "read me\n", 0100644]);
my $empty = qx{"$^X" "$bin" --zip "$empty_zip" --out "$tmp/empty-out" 2>&1};
isnt($? >> 8, 0, 'a zip with no executables is refused');
like($empty, qr/no executables under bin\/ or libexec\//, 'and the refusal says why');

# A link stored with the build-time placeholder resolves to the archive path.
my $prefixed_zip = "$tmp/prefixed.zip";
make_zip($prefixed_zip,
	['bin/foo', $foo, 0100755],
	['bin/baz', '@TERMUX_PREFIX@/bin/foo', 0120777],
);
my $pout = "$tmp/prefixed-out";
my $p = qx{"$^X" "$bin" --zip "$prefixed_zip" --out "$pout" 2>&1};
is($? >> 8, 0, 'a placeholder link target is accepted') or diag($p);
like(slurp("$pout/runtime-bins.txt"), qr/^bin\/baz\tlink\tbin\/foo$/m,
	'a placeholder target becomes a prefix-relative path');

# A missing archive is a refusal, not an empty output tree.
my $missing = qx{"$^X" "$bin" --zip "$tmp/nope.zip" --out "$tmp/none" 2>&1};
isnt($? >> 8, 0, 'a missing zip is refused');
like($missing, qr/no such zip|cannot read/, 'and the refusal says which archive');

done_testing();
