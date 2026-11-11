# tests-for: scripts/publish_lib.pl scripts/mkosi_publish.pl scripts/app_publish.pl
# covers:    A publish that names the build the site already has must not touch
#            server/downloads.json (and especially must not move its `generated`
#            stamp): the file is tracked, and an automatic rerun left the
#            primary dirty with a timestamp-only change. A genuinely newer
#            build still rewrites it, keeps the other product's entry, and is
#            left for the release routine to commit.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

require "$FindBin::Bin/../scripts/publish_lib.pl";

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

my $tmp = tempdir(CLEANUP => 1);
my $path = "$tmp/downloads.json";
my $enc = sub { JSON::PP->new->canonical->pretty->encode($_[0]) };
my $dec = sub { JSON::PP->new->decode($_[0]) };

my $desktop = {
	'ok' => JSON::PP::true,
	'url' => 'https://dl.jawnos.ca/jawnos-live.raw.zst',
	'manifest' => 'https://dl.jawnos.ca/desktop_release.json',
	'size' => 1234,
	'sha256' => 'a' x 64,
	'version' => '1.0',
	'label' => 'One file, no parts',
};

my $wrote = PublishManifest::update($path, { 'desktop' => $desktop }, $enc, $dec);
is($wrote, 1, 'a first publish writes the manifest');
my $first = slurp($path);
like($first, qr/"generated"\s*:/, 'and stamps it');

# Simulate an older run, then publish the same image again. The only difference
# the old code would have written is the generated stamp.
my $sentinel = $first;
$sentinel =~ s/"generated"\s*:\s*"[^"]*"/"generated": "2000-01-01T00:00:00Z"/;
spew($path, $sentinel);
$wrote = PublishManifest::update($path, { 'desktop' => $desktop }, $enc, $dec);
is($wrote, 0, 'the same image published again writes nothing');
is(slurp($path), $sentinel, 'and leaves the file, generated stamp included, untouched');

# The other product's entry is preserved, and its presence alone is not a
# reason to rewrite the file.
my $both = JSON::PP->new->canonical->pretty->encode({
	'app' => {
		'ok' => JSON::PP::true,
		'filename' => 'jawnos-app-1309-0.118.311.apk',
		'versionName' => '0.118.311',
		'versionCode' => 1309,
	},
	'desktop' => $desktop,
	'generated' => '2000-01-01T00:00:00Z',
});
spew($path, $both);
$wrote = PublishManifest::update($path, { 'desktop' => $desktop }, $enc, $dec);
is($wrote, 0, 'a manifest carrying the app entry does not make the image publish a change');
like(slurp($path), qr/0\.118\.311/, 'and the app entry is kept');

# A real change writes once and moves the stamp.
my $newer = { %$desktop, 'version' => '2.0' };
$wrote = PublishManifest::update($path, { 'desktop' => $newer }, $enc, $dec);
is($wrote, 1, 'a newer image writes the manifest');
my $third = slurp($path);
unlike($third, qr/2000-01-01T00:00:00Z/, 'and refreshes the generated stamp');
like($third, qr/"version"\s*:\s*"2\.0"/, 'with the new version');
like($third, qr/0\.118\.311/, 'and keeps the app entry');

# --- app_publish.pl through its real command path ---------------------------
# The app publisher uses Mojo::JSON, so a boolean decoded from the file and the
# Mojo boolean it writes must compare equal: otherwise every run would look like
# a change.

subtest 'app_publish leaves an unchanged manifest alone' => sub {
	my $script = "$FindBin::Bin/../scripts/app_publish.pl";
	my $fake_root = "$tmp/root";
	my $releases = "$tmp/releases";
	my $app_repo = "$tmp/app-repo";
	make_path("$fake_root/scripts", "$fake_root/server", "$fake_root/docs", $releases);
	make_path("$app_repo/app/src/main/assets");
	spew("$fake_root/scripts/app_publish.pl", slurp($script));
	spew("$fake_root/scripts/publish_lib.pl",
		slurp("$FindBin::Bin/../scripts/publish_lib.pl"));
	spew("$fake_root/server/downloads.json", "{}");

	my $apk = "$releases/jawnos-app-7-0.0.7.apk";
	spew($apk, "not really an apk\n");

	my $bin = "$tmp/bin";
	make_path($bin);
	my $fake_gh = "$bin/gh";
	spew($fake_gh, "#!/bin/sh\nexit 0\n");
	chmod 0755, $fake_gh or die "chmod gh: $!";

	local $ENV{'PATH'} = "$bin:$ENV{'PATH'}";
	my $copy = "$fake_root/scripts/app_publish.pl";
	my $run = sub {
		my $out = qx{$^X '$copy' --dir '$releases' --app-repo '$app_repo' --no-runtime --repo owner/name 2>&1};
		return ($? >> 8, $out);
	};

	my ($code, $out) = $run->();
	is($code, 0, 'the publish runs against the fake gh') or diag($out);
	my $manifest = "$fake_root/server/downloads.json";
	my $before = slurp($manifest);
	like($before, qr/"versionCode"\s*:\s*7/, 'the first publish records the staged build');

	my $again = $before;
	$again =~ s/"generated"\s*:\s*"[^"]*"/"generated": "2000-01-01T00:00:00Z"/;
	spew($manifest, $again);
	($code, $out) = $run->();
	is($code, 0, 'the same build publishes again') or diag($out);
	is(slurp($manifest), $again, 'and downloads.json is byte-for-byte unchanged');
	unlike($out, qr/updated downloads\.json/, 'with no update notice');

	spew("$releases/jawnos-app-8-0.0.8.apk", "a newer apk\n");
	($code, $out) = $run->();
	is($code, 0, 'a newer staged build publishes') or diag($out);
	like(slurp($manifest), qr/"versionCode"\s*:\s*8/, 'and rewrites the manifest for it');
	like($out, qr/updated downloads\.json/, 'with the commit reminder');
};

# The image publisher shares the same writer; a direct write would reintroduce
# the dirty-file bug on the desktop side.
my $mkosi = slurp("$FindBin::Bin/../scripts/mkosi_publish.pl");
like($mkosi, qr/PublishManifest::update/, 'mkosi_publish uses the shared writer');
unlike($mkosi, qr/write_file\(\s*\$path/, 'and does not write downloads.json itself');

done_testing();
