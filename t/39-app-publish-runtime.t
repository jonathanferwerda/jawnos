use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();

# M3/M5 (docs/leaving-termux.md): a clean install downloads the runtime files
# named in the APK's assets/jawnrt.json from the same release tag as the APK.
# app_publish.pl used to upload only the APK and its manifest, so a publish
# could leave the pin pointing at an asset that was never there, and the first
# run failed on a fresh install. The preflight below refuses that publish; the
# help text on the release is not what these tests check.

my $script = "$FindBin::Bin/../scripts/app_publish.pl";
my $tmp    = tempdir(CLEANUP => 1);
my $dir    = "$tmp/releases";
my $app    = "$tmp/app";
make_path($dir, "$app/app/src/main/assets");

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "$path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

sub spew {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $text;
	close $fh;
}

my $apk = "$dir/jawnos-app-7-0.0.7.apk";
spew($apk, "not really an apk\n");

my $runtime = "$dir/jawnrt-aarch64-9.9.9.zip";
spew($runtime, "runtime bytes\n");
my $sha = sha256_hex(slurp($runtime));

sub write_pin {
	my ($repo, $sha, $file) = @_;
	my $json = JSON::PP->new->canonical->pretty->encode({
		abi => {
			aarch64 => {
				file    => $file,
				sha256  => $sha,
				size    => 14,
				version => '9.9.9',
			},
		},
	});
	spew("$repo/app/src/main/assets/jawnrt.json", $json);
}

sub run_publish {
	my ($repo, @args) = @_;
	my $out = qx{$^X '$script' --dir '$dir' --app-repo '$repo' --dry-run @args 2>&1};
	return ($? >> 8, $out);
}

write_pin($app, $sha, 'jawnrt-aarch64-9.9.9.zip');

my ($code, $out) = run_publish($app);
is($code, 0, 'a staged runtime that matches the pin passes the preflight');
like($out, qr/runtime aarch64 jawnrt-aarch64-9\.9\.9\.zip/,
	'and the plan names it');

($code, $out) = run_publish($app, '--no-runtime');
is($code, 0, '--no-runtime still publishes');
unlike($out, qr/runtime aarch64/, 'and does not check the pin');

write_pin($app, '0' x 64, 'jawnrt-aarch64-9.9.9.zip');
($code, $out) = run_publish($app);
isnt($code, 0, 'a runtime that does not match its pinned sha256 refuses the publish');
like($out, qr/does not match the sha256 pinned/, 'and says why');

write_pin($app, $sha, 'jawnrt-missing.zip');
($code, $out) = run_publish($app);
isnt($code, 0, 'a pinned runtime that is not staged refuses the publish');
like($out, qr/is not staged/, 'and names the missing file');

my $nopin = "$tmp/nopin";
make_path("$nopin/app/src/main/assets");
($code, $out) = run_publish($nopin);
is($code, 0, 'an app repo with no pin publishes as before');

($code, $out) = run_publish($nopin, '--runtime');
isnt($code, 0, '--runtime without a pin is an error');
like($out, qr/does not exist/, 'and says the pin is missing');

done_testing();
