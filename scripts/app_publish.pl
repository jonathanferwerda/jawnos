#!/usr/bin/perl
# Publish the newest staged JawnOS APKs to GitHub, so every device can pull
# them from github.com as well as from a peer (see subs::app_release_sync).
#
#   perl scripts/app_publish.pl [--repo OWNER/NAME] [--tag TAG]
#                               [--apk FILE] [--dry-run]
#
# One product rides the release/tag:
#   jawnos-app-<versionCode>-<versionName>.apk  + app_release.json
# The retired API app (com.termux.api) is not published any more; a publish
# also removes its old assets, so a release that carried them cleans itself up.
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
use Mojo::JSON qw(encode_json decode_json);

my $root = abs_path("$FindBin::Bin/..");
my $dir  = "$root/releases";
my ($repo, $tag, $apk, $dry_run) = ('jonathanferwerda/jawnos', 'releases', undef, 0);

# The release body is the newest dated section of docs/app-release-notes.md
# (a real changelog, written when the build is made) plus the version codes
# that are actually staged below it. A release with no notes still publishes,
# but the text is then only the build list.
our $release_date = '';
sub release_notes {
	my (@current) = @_;
	my $notes_path = "$root/docs/app-release-notes.md";
	my $body = '';
	if (-f $notes_path) {
		my $text = read_file($notes_path);
		if ($text =~ /^##\s+(.+?)\n(.*?)(?=^##\s+|\z)/ms) {
			my ($heading, $section) = ($1, $2);
			($release_date) = $heading =~ /^(\d{4}-\d{2}-\d{2})/;
			$section =~ s/\s+\z//;
			$body = "## $heading\n\n$section";
		}
	}
	my $list = join("\n", map { "- $_" } @current);
	return "The newest JawnOS app builds, served as release assets.\n\n"
		. ($body ? "$body\n\n" : '')
		. "---\n\n**Builds in this release:**\n\n$list\n";
}
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

# The newest staged app, or the one --apk names.
my @jobs;
{
	my $product = 'app';
	my $file = $apk;
	if (!$file) {
		my @f = sort { ( ($b =~ /-(\d+)-/) )[0] <=> ( ($a =~ /-(\d+)-/) )[0] }
			glob("$dir/jawnos-app-*.apk");
		$file = $f[0];
	}
	unless ($file && -f $file) {
		die "no staged app APK in $dir" . ($apk ? " ($apk)" : '') . "\n";
	}
	my ($filename) = $file =~ m{([^/]+)\z};
	my ($vc, $vn) = $filename =~ /^jawnos-app-(\d+)-(.+)\.apk\z/
		or die "$file: not a jawnos-app-<versionCode>-<versionName>.apk\n";
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
		path     => "$dir/app_release.json",
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
my @initial = map { "$_->{'product'} $_->{'vn'} (versionCode $_->{'vc'})" } @jobs;
my $initial_notes = release_notes(@initial);
my $exists = system('gh', 'release', 'view', $tag, '--repo', $repo) == 0;
unless ($exists) {
	system('gh', 'release', 'create', $tag, '--repo', $repo,
		'--title', 'JawnOS app releases' . ($release_date ? " — $release_date" : ''), '--notes', $initial_notes, '--latest') == 0
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

# The site is static and its host has no outbound network, so it reads this one
# small file from raw.githubusercontent (the only cross-origin place a browser
# can read). Update it after a real upload; the routine that publishes also
# commits it, which is what makes jawnos.ca see the new build.
sub update_downloads_json {
	my ($j) = @_;
	return unless ($j->{'product'} || '') eq 'app';
	my $path = "$root/downloads.json";
	my $data = {};
	if (-f $path) {
		my $text = eval { read_file($path) };
		$data = eval { decode_json($text) } || {} if defined $text && length $text;
	}
	my @t = gmtime(time());
	$data->{'generated'} = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
	$data->{'app'} = {
		'ok' => Mojo::JSON::true,
		'url' => "https://github.com/$repo/releases/download/$tag/" . $j->{'filename'},
		'filename' => $j->{'filename'},
		'versionName' => $j->{'vn'},
		'versionCode' => $j->{'vc'} + 0,
		'size' => $j->{'size'} + 0,
		'sha256' => $j->{'sha'},
		'source' => 'https://github.com/jonathanferwerda/termux-app',
		'license' => 'GPL-2.0',
	};
	write_file($path, encode_json($data));
	print "updated downloads.json (commit it so jawnos.ca sees this build)\n";
}

foreach my $j (@jobs) {
	update_downloads_json($j);
}

# Keep the release notes naming the builds that are actually on the release.
# The notes used to be written only when the release was first created, so a
# later publish left the body advertising an old versionCode while the assets
# (and app_release.json) were current.
my @current;
{
	my $path = "$dir/app_release.json";
	if (-f $path) {
		my $m = eval { decode_json(read_file($path)) } || {};
		push @current, "app $m->{'versionName'} (versionCode $m->{'versionCode'})"
			if $m->{'product'} && $m->{'versionName'};
	}
}
if (@current) {
	my $notes = release_notes(@current);
	my @title = $release_date ? ('--title', "JawnOS app releases — $release_date") : ();
	system('gh', 'release', 'edit', $tag, '--repo', $repo, @title, '--notes', $notes) == 0
		or warn "could not update the release notes for $tag\n";
}

# The API app is retired (M1): its APK and manifest must not linger on the
# release, or a device on an older tree would still be told an "api" update
# exists. Deleting an absent asset is not an error, so this stays quiet.
my $assets = `gh release view $tag --repo $repo --json assets -q '.assets[].name' 2>/dev/null`;
foreach my $name ( split /\s+/, $assets ) {
	next unless $name eq 'api_release.json' || $name =~ /^jawnos-api-\d+-/;
	system('gh', 'release', 'delete-asset', $tag, $name, '--repo', $repo, '--yes') == 0
		and print "removed retired API asset $name\n";
}

print "published https://github.com/$repo/releases/tag/$tag\n";
