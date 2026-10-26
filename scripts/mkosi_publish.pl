#!/usr/bin/env perl
# Publish the newest built JawnOS disk image to a GitHub release, compressed.
#
#   perl scripts/mkosi_publish.pl              # compress + upload (needs gh auth)
#   perl scripts/mkosi_publish.pl --dry-run    # show the plan, do nothing
#   perl scripts/mkosi_publish.pl --no-upload  # compress, hash, print the URL
#   perl scripts/mkosi_publish.pl --xz          # smaller, but much slower
#
# The raw image is ~8.1G on disk and is mostly a read-only system image: it
# compresses to about 3.0G with zstd -3 (measured here: 47s) and rather less
# with xz, which took over five minutes on the same box. zstd is the default
# because publishing is a repeated operation and every modern Linux/macOS has
# (or can install) `zstd -d`; --xz is there for a release where the last
# 500MB matters more than the CPU time. The build itself stays at its minimum
# size; do not pre-grow it for the download.
#
# The asset name is stable (`jawnos-live.raw.zst`), so the jawnos.ca link never
# moves. GitHub caps a release asset at 2 GiB, and the compressed image is ~3
# GiB, so the file is uploaded as `jawnos-live.raw.zst.partNN` pieces; the
# version, sizes, checksums and the reassembly command travel in
# desktop_release.json beside them. The image families are gitignored blobs,
# like the APK store: they ride GitHub release assets, not git history.
#
# Credentials are never required to prepare a build. Without `gh` auth the
# script still compresses, hashes and prints the exact upload commands with a
# GH_TOKEN=<token> placeholder; pass --require-upload in CI to make that fail.
# Repo and tag come from JAWNOS_DESKTOP_REPO / JAWNOS_DESKTOP_TAG.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(basename);
use Digest::SHA ();
use JSON::PP ();
use Getopt::Long qw(GetOptions);

my $root = abs_path("$FindBin::Bin/..");
my $dir  = "$root/desktop/mkosi/output";
my $repo = $ENV{'JAWNOS_DESKTOP_REPO'} || 'jonathanferwerda/jawnos';
my $tag  = $ENV{'JAWNOS_DESKTOP_TAG'}  || 'desktop';
my $file;
my $compression = 'zstd';
my $level;
my $name;
my $part_mb = 1900;
my $dry_run = 0;
my $no_upload = 0;
my $require_upload = 0;
my $force = 0;

GetOptions(
	'file=s'          => \$file,
	'dir=s'           => \$dir,
	'repo=s'          => \$repo,
	'tag=s'           => \$tag,
	'zstd'            => sub { $compression = 'zstd' },
	'xz'              => sub { $compression = 'xz' },
	'level=i'         => \$level,
	'name=s'          => \$name,
	'part-size=i'     => \$part_mb,
	'dry-run'         => \$dry_run,
	'no-upload'       => \$no_upload,
	'require-upload'  => \$require_upload,
	'force'           => \$force,
) or die "usage: $0 [--file RAW] [--dir DIR] [--repo OWNER/NAME] [--tag TAG] "
	. "[--zstd|--xz] [--level N] [--name ASSET] [--part-size MB] [--dry-run] [--no-upload] "
	. "[--require-upload] [--force]\n";

die "mkosi_publish: --repo must be OWNER/NAME\n" unless $repo =~ m{^[^/\s]+/[^/\s]+\z};
die "mkosi_publish: --tag must be a release tag\n" unless $tag =~ /^[0-9A-Za-z._-]+\z/;
die "mkosi_publish: --dir does not exist: $dir\n" unless -d $dir;
# GitHub refuses a release asset over 2 GiB; 1900 MiB leaves room for the
# boundary chunk and stays well under the cap.
die "mkosi_publish: --part-size must be 100..2000 MB\n"
	unless $part_mb >= 100 && $part_mb <= 2000;

# The newest raw image wins; --file names one explicitly (a staged copy from
# another machine is fine too).
if (!defined $file) {
	my @raw = sort { (-M $a) <=> (-M $b) } glob("$dir/*.raw");
	die "mkosi_publish: no *.raw image in $dir (build one with scripts/mkosi_build.pl)\n"
		unless @raw;
	$file = $raw[0];
}
die "mkosi_publish: no such image: $file\n" unless -f $file;

my $raw_name = basename($file);
my ($version) = $raw_name =~ /_([0-9][0-9A-Za-z._-]*)\.raw\z/;
$version = 'unknown' unless defined $version;

my $ext = $compression eq 'xz' ? 'xz' : 'zst';
$level = $compression eq 'xz' ? 6 : 3 unless defined $level;
my $max_level = $compression eq 'xz' ? 9 : 19;
die "mkosi_publish: compression level must be 1..$max_level\n"
	unless $level >= 1 && $level <= $max_level;

my $asset = $name || "jawnos-live.raw.$ext";
die "mkosi_publish: --name must be a plain file name\n" unless $asset =~ /^[0-9A-Za-z._-]+\z/;
my $out = "$dir/$asset";
my $manifest = "$dir/desktop_release.json";
my $raw_size = -s $file;

printf "image        %s (%d bytes, %.1f GiB)\n", $file, $raw_size, $raw_size / 1024**3;
printf "compression  %s -%d\n", $compression, $level;
printf "asset        %s (+ .partNN)\n", $asset;
printf "part size    %d MB\n", $part_mb;
printf "repo / tag   %s / %s\n", $repo, $tag;

if ($dry_run) {
	print "dry run: would compress to $out, split it into <=${part_mb}MB parts, write $manifest, and upload to the '$tag' release\n";
	print "download URLs would be:\n  " . download_url($repo, $tag, "$asset.part01") . "\n  ...\n";
	exit 0;
}

# Reuse a compression of the same image if one is already newer (a re-run after
# an upload failure should not spend another minute on the CPU). zstd preserves
# the source's mtime, so an equal timestamp means the same input was compressed.
my $reuse = !$force && -f $out && -M $out <= -M $file;
if ($reuse) {
	print "reusing     $out (newer than the image)\n";
}
else {
	unlink $out if -e $out;
	print "compressing with $compression (this can take a minute)...\n";
	if ($compression eq 'xz') {
		# xz writes <raw>.xz; keep the raw and move the result onto the stable
		# asset name so the URL never moves.
		system('xz', '-T0', "-$level", '-k', '-f', $file) == 0
			or die "mkosi_publish: xz failed\n";
		my $made = "$file.xz";
		die "mkosi_publish: xz produced no $made\n" unless -f $made;
		rename($made, $out) or die "mkosi_publish: could not move $made to $out: $!\n";
	}
	else {
		system('zstd', '-q', '-T0', "-$level", '-f', '-o', $out, $file) == 0
			or die "mkosi_publish: zstd failed\n";
	}
}
die "mkosi_publish: compression produced no file at $out\n" unless -f $out;

my $size = -s $out;
my $compressed_sha = sha256($out);
my $raw_sha = sha256($file);
my $manifest_url = download_url($repo, $tag, 'desktop_release.json');

# Split into pieces small enough for a GitHub release asset. Even a small image
# gets one part, so the download instructions are the same path every time.
my $part_size = $part_mb * 1024 * 1024;
unlink glob("$dir/$asset.part*");
my @parts;
{
	open my $in, '<:raw', $out or die "mkosi_publish: cannot read $out: $!\n";
	my $fh;
	my $written = 0;
	while (1) {
		my $buf;
		my $n = read($in, $buf, 8 * 1024 * 1024);
		die "mkosi_publish: read failed: $!\n" unless defined $n;
		last if $n == 0;
		if (!$fh || $written >= $part_size) {
			close $fh if $fh;
			my $index = scalar(@parts) + 1;
			my $part_name = sprintf('%s.part%02d', $asset, $index);
			open $fh, '>:raw', "$dir/$part_name" or die "mkosi_publish: cannot write $part_name: $!\n";
			push @parts, { name => $part_name };
			$written = 0;
		}
		print {$fh} $buf or die "mkosi_publish: write failed: $!\n";
		$written += $n;
	}
	close $fh if $fh;
	close $in;
}
foreach my $p (@parts) {
	my $path = "$dir/$p->{'name'}";
	$p->{'size'} = (-s $path) + 0;
	$p->{'sha256'} = sha256($path);
}
my @part_paths = map { $dir . '/' . $_->{'name'} } @parts;

my $meta = {
	product             => 'desktop',
	format              => 'raw-disk-image',
	version             => $version,
	source              => $raw_name,
	filename            => $asset,
	compression         => $compression,
	compressed_size     => $size + 0,
	compressed_sha256   => $compressed_sha,
	raw_size            => $raw_size + 0,
	raw_sha256          => $raw_sha,
	parts               => [ map { { name => $_->{'name'}, size => $_->{'size'}, sha256 => $_->{'sha256'} } } @parts ],
	reassemble          => "cat $asset.part* > $asset",
	urls                => [ map { download_url($repo, $tag, $_->{'name'}) } @parts ],
	manifest_url        => $manifest_url,
	published           => iso8601_utc(),
	decompress          => $compression eq 'xz' ? 'xz -d' : 'zstd -d',
};
open my $mf, '>', $manifest or die "mkosi_publish: cannot write $manifest: $!\n";
print $mf JSON::PP->new->canonical->pretty->encode($meta);
close $mf;

printf "compressed   %d bytes (%.1f GiB, %.0f%% of the raw)\n",
	$size, $size / 1024**3, 100 * $size / $raw_size;
printf "parts        %d x <=%d MB\n", scalar(@parts), $part_mb;
print "sha256       $compressed_sha\n";
print "manifest     $manifest\n";
print "download URLs:\n";
foreach my $p (@parts) {
	printf "  %s\n", download_url($repo, $tag, $p->{'name'});
}
print "checksum URL $manifest_url\n";

# gh is only needed for the upload. `gh auth status` writes to stderr, so run it
# through sh with the noise discarded.
my $gh = `command -v gh 2>/dev/null`;
chomp $gh;
my $authed = $gh && system('sh', '-c', 'gh auth status >/dev/null 2>&1') == 0;

if ($no_upload || !$authed) {
	if ($no_upload) {
		print "\n--no-upload: prepared only; nothing was sent to GitHub.\n";
	}
	else {
		print "\ngh is not installed or not authenticated. The image is ready and hashed.\n";
		print "Authenticate once, or supply a token in the environment:\n\n";
		print "  gh auth login            # interactive\n";
		print "  export GH_TOKEN=<token>  # a GitHub token with 'repo' scope\n\n";
		print "Then upload with:\n\n";
		printf "  gh release create %s --repo %s --title 'JawnOS desktop image' --notes 'Compressed disk image for USB sticks and QEMU.'\n", $tag, $repo;
		printf "  gh release upload %s %s %s --clobber --repo %s\n",
			$tag, join(' ', @part_paths), $manifest, $repo;
		print "\n(create is only needed the first time; the upload works either way)\n";
		print "Reassemble with: cat $asset.part* > $asset\n";
		print "\nPlaceholders to supply: GH_TOKEN (or gh auth login), ";
		print "JAWNOS_DESKTOP_REPO (currently $repo), JAWNOS_DESKTOP_TAG (currently $tag).\n";
		exit($require_upload ? 1 : 0);
	}
	exit 0;
}

# Create the release once; a fixed tag means the download URLs never move. No
# --latest here: that belongs to the APK release.
my $exists = system('sh', '-c', 'gh release view ' . shell_quote($tag) . ' --repo ' . shell_quote($repo) . ' >/dev/null 2>&1') == 0;
unless ($exists) {
	system('gh', 'release', 'create', $tag,
		'--repo', $repo,
		'--title', 'JawnOS desktop image',
		'--notes', 'The newest JawnOS disk image, compressed. Write it to a USB stick or boot it in QEMU.',
	) == 0 or die "mkosi_publish: could not create release $tag\n";
}

system('gh', 'release', 'upload', $tag, @part_paths, $manifest, '--clobber', '--repo', $repo) == 0
	or die "mkosi_publish: upload failed\n";

# One current image per release: drop this product's older part assets that are
# not in the current set, and the old single-file asset if one is still there.
my %keep = map { $_->{'name'} => 1 } @parts;
my $assets = `gh release view $tag --repo $repo --json assets -q '.assets[].name' 2>/dev/null`;
foreach my $old ( split /\s+/, $assets ) {
	next if $old eq 'desktop_release.json' || $keep{$old};
	next unless $old eq $asset || $old =~ /^jawnos-live(?:[._-].*)?\.raw\.(?:zst|xz)(?:\.part\d+)?$/;
	system('gh', 'release', 'delete-asset', $tag, $old, '--repo', $repo, '--yes') == 0
		and print "removed stale asset $old\n";
}

print "\npublished https://github.com/$repo/releases/tag/$tag\n";
print "download  " . download_url($repo, $tag, $parts[0]->{'name'}) . " (and the other parts)\n";

exit 0;

sub download_url {
	my ($r, $t, $n) = @_;
	return "https://github.com/$r/releases/download/$t/$n";
}

sub sha256 {
	my ($path) = @_;
	my $sha = Digest::SHA->new(256);
	$sha->addfile($path, 'b');
	return $sha->hexdigest;
}

sub iso8601_utc {
	my @t = gmtime(time());
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Only used for the two fixed strings (tag/repo), never for a user-supplied path.
sub shell_quote {
	my ($s) = @_;
	$s =~ s/'/'\\''/g;
	return "'$s'";
}
