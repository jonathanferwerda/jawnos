#!/usr/bin/perl
# Publish the newest staged JawnOS APKs to GitHub, so every device can pull
# them from github.com as well as from a peer (see subs::app_release_sync).
#
#   perl scripts/app_publish.pl [--product app|api|all] [--repo OWNER/NAME]
#                               [--tag TAG] [--apk FILE] [--dry-run]
#
# Both products ride the same release/tag:
#   jawnos-app-<versionCode>-<versionName>.apk  + app_release.json
#   jawnos-api-<versionCode>-<versionName>.apk  + api_release.json
# The app manifest keeps its historical name; the api one is new, and the
# server's GitHub sync reads both. One manifest per product means publishing
# the API build no longer displaces the app build (or the reverse).
#
# The APKs are gitignored blobs, so they ride GitHub *release assets*, not git
# history. Requires the `gh` CLI, authenticated. The repo is public, so
# devices fetch the assets with no token.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Slurp qw(read_file write_file);
use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(encode_json);

my $root = abs_path("$FindBin::Bin/..");
my $dir  = "$root/releases";
my ($repo, $tag, $apk, $dry_run, $product_opt) = ('jonathanferwerda/jawnos', 'releases', undef, 0, 'all');
while ( defined(my $arg = shift @ARGV) ) {
	if ($arg eq '--repo')    { $repo = shift @ARGV; next; }
	if ($arg eq '--tag')     { $tag = shift @ARGV; next; }
	if ($arg eq '--apk')     { $apk = shift @ARGV; next; }
	if ($arg eq '--dir')     { $dir = shift @ARGV; next; }
	if ($arg eq '--product') { $product_opt = shift @ARGV; next; }
	if ($arg eq '--dry-run') { $dry_run = 1; next; }
	die "app_publish.pl: unknown option $arg\n";
}
die "usage: app_publish.pl [--product app|api|all] [--repo OWNER/NAME] [--tag TAG] [--apk FILE] [--dry-run]\n"
	unless $repo =~ m{^[^/\s]+/[^/\s]+\z} && $tag && $tag =~ /^[0-9A-Za-z._-]+\z/;
die "app_publish.pl: --product must be app, api or all\n"
	unless $product_opt =~ /^(?:app|api|all)$/;

# Which products to publish. An explicit --apk names exactly one; otherwise
# --product selects, defaulting to both.
my @products;
if ($apk) {
	my ($p) = $apk =~ m{/jawnos-(app|api)-\d+-[^/]+\.apk\z};
	die "$apk: not a staged jawnos-<product>-<versionCode>-<versionName>.apk\n" unless $p;
	@products = ($p);
}
else {
	@products = $product_opt eq 'all' ? qw(app api) : ($product_opt);
}

my %MANIFEST = ( app => 'app_release.json', api => 'api_release.json' );
my @jobs;
foreach my $product (@products) {
	my $file = $apk;
	if (!$file) {
		my @f = sort { ( ($b =~ /-(\d+)-/) )[0] <=> ( ($a =~ /-(\d+)-/) )[0] }
			glob("$dir/jawnos-$product-*.apk");
		$file = $f[0];
	}
	unless ($file && -f $file) {
		warn "no staged $product APK in $dir" . ($apk ? " ($apk)" : '') . "\n";
		next;
	}
	my ($filename) = $file =~ m{([^/]+)\z};
	my ($got_product, $vc, $vn) = $filename =~ /^jawnos-(app|api)-(\d+)-(.+)\.apk\z/
		or die "$file: not a jawnos-<product>-<versionCode>-<versionName>.apk\n";
	die "$file: product $got_product does not match $product\n" unless $got_product eq $product;
	my $sha = sha256_hex(read_file($file));
	my $size = -s $file;
	my $manifest = encode_json({
		product     => $product,
		versionCode => $vc + 0,
		versionName => $vn,
		filename    => $filename,
		size        => $size + 0,
		sha256      => $sha,
	});
	push @jobs, {
		product  => $product,
		apk      => $file,
		filename => $filename,
		vc       => $vc,
		vn       => $vn,
		sha      => $sha,
		size     => $size,
		manifest => $manifest,
		path     => "$dir/$MANIFEST{$product}",
	};
}
die "app_publish.pl: no staged APKs to publish\n" unless @jobs;

foreach my $j (@jobs) {
	printf "publishing %s\n  versionCode %s / %s\n  %d bytes\n  sha256 %s\n  manifest %s\n",
		$j->{'filename'}, $j->{'vc'}, $j->{'vn'}, $j->{'size'}, $j->{'sha'}, $j->{'path'};
}
print "  repo $repo, tag $tag\n";

if ($dry_run) {
	print "dry run: would create/update release '$tag' with the assets above\n";
	exit 0;
}

# Create the release once (empty on first use), then upload each product's APK
# and manifest. A fixed tag means the download URLs never move.
my $exists = system('gh', 'release', 'view', $tag, '--repo', $repo) == 0;
unless ($exists) {
	my $notes = "The newest JawnOS app builds, served as release assets.\n\n";
	$notes .= join("\n", map { "$_->{'product'} $_->{'vn'} (versionCode $_->{'vc'})" } @jobs);
	system('gh', 'release', 'create', $tag, '--repo', $repo,
		'--title', 'JawnOS app releases', '--notes', $notes, '--latest') == 0
		or die "publish failed: could not create release $tag\n";
}

foreach my $j (@jobs) {
	write_file($j->{'path'}, $j->{'manifest'});
	system('gh', 'release', 'upload', $tag, $j->{'apk'}, $j->{'path'}, '--clobber', '--repo', $repo) == 0
		or die "publish failed: could not upload $j->{'filename'}\n";

	# One build per product: the asset name carries the version, so --clobber
	# alone leaves older ones behind. Drop this product's stale APK assets.
	my $assets = `gh release view $tag --repo $repo --json assets -q '.assets[].name' 2>/dev/null`;
	foreach my $name ( split /\s+/, $assets ) {
		next unless $name =~ /^jawnos-\Q$j->{'product'}\E-\d+-/ && $name ne $j->{'filename'};
		system('gh', 'release', 'delete-asset', $tag, $name, '--repo', $repo, '--yes') == 0
			and print "removed stale asset $name\n";
	}
}

print "published https://github.com/$repo/releases/tag/$tag\n";
