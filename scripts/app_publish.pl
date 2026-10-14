#!/usr/bin/perl
# Publish the newest staged app APK to GitHub, so every device can pull it from
# github.com as well as from a peer (see subs::app_release_sync).
#
#   perl scripts/app_publish.pl [--repo OWNER/NAME] [--tag TAG] [--apk FILE] [--dry-run]
#
# The APK is a gitignored blob, so it is never in git history - it rides a
# GitHub *release asset* instead, which does not bloat the repo. A small
# app_release.json manifest (product, versionCode, versionName, filename, sha256)
# is staged beside the APK and uploaded with it. Both live under a fixed tag, so
# the sync's download URL never moves even as builds replace one another.
#
# Requires the `gh` CLI, authenticated. The repo is public, so devices fetch the
# assets with no token.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Slurp qw(read_file write_file);
use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(encode_json);

my $root = abs_path("$FindBin::Bin/..");
my $dir  = "$root/releases";
my ($repo, $tag, $apk, $dry_run) = ('jonathanferwerda/jawnos', 'releases', undef, 0);
while ( defined(my $arg = shift @ARGV) ) {
	if ($arg eq '--repo')    { $repo = shift @ARGV; next; }
	if ($arg eq '--tag')     { $tag = shift @ARGV; next; }
	if ($arg eq '--apk')     { $apk = shift @ARGV; next; }
	if ($arg eq '--dir')     { $dir = shift @ARGV; next; }
	if ($arg eq '--dry-run') { $dry_run = 1; next; }
	die "app_publish.pl: unknown option $arg\n";
}
die "usage: app_publish.pl [--repo OWNER/NAME] [--tag TAG] [--apk FILE] [--dry-run]\n"
	unless $repo =~ m{^[^/\s]+/[^/\s]+\z} && $tag && $tag =~ /^[0-9A-Za-z._-]+\z/;

# The newest staged app build, unless one was named.
if (!$apk) {
	my @f = sort { ( ($b =~ /-(\d+)-/) )[0] <=> ( ($a =~ /-(\d+)-/) )[0] }
		glob("$dir/jawnos-app-*.apk");
	$apk = $f[0];
}
die "no staged app APK in $dir (build one with scripts/app_build.pl)\n" unless $apk && -f $apk;

my ($filename) = $apk =~ m{([^/]+)\z};
my ($product, $vc, $vn) = $filename =~ /^jawnos-(app|api)-(\d+)-(.+)\.apk\z/
	or die "$apk: not a jawnos-<product>-<versionCode>-<versionName>.apk\n";
my $sha = sha256_hex(read_file($apk));
my $size = -s $apk;
my $manifest = encode_json({
	product     => $product,
	versionCode => $vc + 0,
	versionName => $vn,
	filename    => $filename,
	size        => $size + 0,
	sha256      => $sha,
});
my $manifest_path = "$dir/app_release.json";
write_file($manifest_path, $manifest);

printf "publishing %s\n  versionCode %s / %s\n  %d bytes\n  sha256 %s\n  repo %s, tag %s\n",
	$filename, $vc, $vn, $size, $sha, $repo, $tag;

if ($dry_run) {
	print "dry run: would create/update release '$tag' with $filename and app_release.json\n";
	exit 0;
}

# Reuse the release if it is already there (a later build replaces the assets);
# otherwise create it, marked as the latest.
my $exists = system('gh', 'release', 'view', $tag, '--repo', $repo) == 0;
my @cmd = $exists
	? ('gh', 'release', 'upload', $tag,   $apk, $manifest_path, '--clobber', '--repo', $repo)
	: ('gh', 'release', 'create', $tag,   $apk, $manifest_path, '--repo', $repo,
		'--title', 'JawnOS app releases',
		'--notes', "The newest JawnOS app build, served as a release asset.\n\n$product $vn (versionCode $vc)\nsha256: $sha\n",
		'--latest');
system(@cmd) == 0 or die "publish failed (exit " . ($? >> 8) . ")\n";
print "published https://github.com/$repo/releases/tag/$tag\n";
