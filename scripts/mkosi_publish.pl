#!/usr/bin/env perl
# Publish the newest built JawnOS disk image to a GitHub release, compressed.
#
#   perl scripts/mkosi_publish.pl              # compress + upload to GitHub (needs gh auth)
#   perl scripts/mkosi_publish.pl --r2         # compress + upload as one file to Cloudflare R2
#   perl scripts/mkosi_publish.pl --dry-run    # show the plan, do nothing
#   perl scripts/mkosi_publish.pl --no-upload  # compress, hash, print the URL
#   perl scripts/mkosi_publish.pl --xz          # smaller, but much slower
#
# --r2 is the preferred home for the image: R2 has no 2 GiB asset cap and no
# egress charge through a custom domain, so the image is one object and the
# download page has one link. Credentials are read from
# .secrets/cloudflare.env (gitignored), or the environment:
#
#   JAWNOS_R2_ACCOUNT=<32 hex account id>
#   JAWNOS_R2_BUCKET=jawnos-downloads
#   JAWNOS_R2_ACCESS_KEY=<R2 access key id>
#   JAWNOS_R2_SECRET=<R2 secret access key>
#   JAWNOS_R2_PUBLIC_BASE=https://dl.jawnos.ca
#
# --dry-run needs none of them. The GitHub path is kept for the split that the
# 2 GiB cap forces when R2 is not configured.
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
my $r2 = 0;
my $r2_bucket;
my $r2_account;
my $public_base;
my $secrets = "$root/.secrets/cloudflare.env";

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
	'r2'              => \$r2,
	'r2-bucket=s'     => \$r2_bucket,
	'r2-account=s'    => \$r2_account,
	'public-base=s'   => \$public_base,
	'secrets=s'       => \$secrets,
) or die "usage: $0 [--file RAW] [--dir DIR] [--repo OWNER/NAME] [--tag TAG] "
	. "[--zstd|--xz] [--level N] [--name ASSET] [--part-size MB] [--dry-run] [--no-upload] "
	. "[--require-upload] [--force] [--r2 [--r2-bucket B] [--r2-account A] [--public-base URL]]\n";

die "mkosi_publish: --repo must be OWNER/NAME\n" unless $repo =~ m{^[^/\s]+/[^/\s]+\z};
die "mkosi_publish: --tag must be a release tag\n" unless $tag =~ /^[0-9A-Za-z._-]+\z/;
die "mkosi_publish: --dir does not exist: $dir\n" unless -d $dir;
# GitHub refuses a release asset over 2 GiB; 1900 MiB leaves room for the
# boundary chunk and stays well under the cap.
die "mkosi_publish: --part-size must be 100..2000 MB\n"
	unless $part_mb >= 100 && $part_mb <= 2000;

# Cloudflare R2 takes the whole file: no 2 GiB asset cap, no parts, and egress
# through a custom domain is free. Credentials live in .secrets/cloudflare.env
# (gitignored) or the environment; a --dry-run needs no credentials at all.
if ($r2) {
	&load_env_file($secrets);
	$r2_account  = $ENV{'JAWNOS_R2_ACCOUNT'}  if !defined $r2_account  || $r2_account  eq '';
	$r2_bucket   = $ENV{'JAWNOS_R2_BUCKET'}   if !defined $r2_bucket   || $r2_bucket   eq '';
	$public_base = $ENV{'JAWNOS_R2_PUBLIC_BASE'} if !defined $public_base || $public_base eq '';
	$public_base = '' unless defined $public_base;
	$public_base =~ s{/+$}{};
	die "mkosi_publish: --r2 needs an account id (--r2-account or JAWNOS_R2_ACCOUNT)\n"
		unless ($r2_account // '') =~ /^[0-9a-f]{16,}$/i;
	die "mkosi_publish: --r2 needs a bucket (--r2-bucket or JAWNOS_R2_BUCKET)\n"
		unless ($r2_bucket // '') =~ /^[0-9a-z][0-9a-z-]{1,62}$/;
	die "mkosi_publish: --r2 needs a public base URL (--public-base or JAWNOS_R2_PUBLIC_BASE), e.g. https://dl.jawnos.ca\n"
		unless length $public_base;
	unless ($dry_run || $no_upload) {
		die "mkosi_publish: --r2 needs JAWNOS_R2_ACCESS_KEY and JAWNOS_R2_SECRET ($secrets)\n"
			unless ($ENV{'JAWNOS_R2_ACCESS_KEY'} // '') ne '' && ($ENV{'JAWNOS_R2_SECRET'} // '') ne '';
	}
}

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
printf "asset        %s%s\n", $asset, $r2 ? '' : ' (+ .partNN)';
printf "part size    %d MB\n", $part_mb unless $r2;
printf "destination  Cloudflare R2: %s/%s via %s\n", $r2_account, $r2_bucket, $public_base
	if $r2;
printf "repo / tag   %s / %s\n", $repo, $tag unless $r2;

if ($dry_run) {
	if ($r2) {
		print "dry run: would compress to $out, write $manifest, and PUT both to R2 ($r2_bucket)\n";
		print "download URL would be:\n  $public_base/$asset\n  $public_base/desktop_release.json\n";
	}
	else {
		print "dry run: would compress to $out, split it into <=${part_mb}MB parts, write $manifest, and upload to the '$tag' release\n";
		print "download URLs would be:\n  " . download_url($repo, $tag, "$asset.part01") . "\n  ...\n";
	}
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

# GitHub caps an asset at 2 GiB, so it takes the image in pieces. R2 has no
# such cap: one object, one link, one checksum, which is what people want.
my @parts;
my @part_paths;
if ($r2) {
	@parts = ({ name => $asset, size => $size + 0, sha256 => $compressed_sha });
	@part_paths = ($out);
}
else {
my $part_size = $part_mb * 1024 * 1024;
unlink glob("$dir/$asset.part*");
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
@part_paths = map { $dir . '/' . $_->{'name'} } @parts;
}

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
	($r2 ? () : (reassemble => "cat $asset.part* > $asset")),
	urls                => [ $r2 ? "$public_base/$asset" : map { download_url($repo, $tag, $_->{'name'}) } @parts ],
	manifest_url        => $r2 ? "$public_base/desktop_release.json" : $manifest_url,
	published           => iso8601_utc(),
	decompress          => $compression eq 'xz' ? 'xz -d' : 'zstd -d',
};
open my $mf, '>', $manifest or die "mkosi_publish: cannot write $manifest: $!\n";
print $mf JSON::PP->new->canonical->pretty->encode($meta);
close $mf;

printf "compressed   %d bytes (%.1f GiB, %.0f%% of the raw)\n",
	$size, $size / 1024**3, 100 * $size / $raw_size;
printf "parts        %d x <=%d MB\n", scalar(@parts), $part_mb unless $r2;
print "sha256       $compressed_sha\n";
print "manifest     $manifest\n";
print "download URLs:\n";
foreach my $p (@parts) {
	printf "  %s\n", $r2 ? "$public_base/$p->{'name'}" : download_url($repo, $tag, $p->{'name'});
}
print "checksum URL " . ($r2 ? "$public_base/desktop_release.json" : $manifest_url) . "\n";

if ($r2) {
	if ($no_upload) {
		print "\n--no-upload: prepared only; nothing was sent to R2.\n";
		exit 0;
	}
	print "\nuploading to R2 ($r2_bucket)...\n";
	&upload_r2($out, $asset, 'application/octet-stream');
	&upload_r2($manifest, 'desktop_release.json', 'application/json');
	print "\npublished $public_base/$asset\n";
	print "manifest  $public_base/desktop_release.json\n";
	# A public bucket (or custom domain) must answer; a 404 here usually means
	# public access is off or the DNS record is missing, not that the PUT failed.
	my $head = `curl -fsSI --max-time 20 $public_base/$asset 2>/dev/null`;
	if ($head =~ m{^HTTP/\S+\s+2\d\d}m) {
		print "verified  the object is publicly reachable\n";
	}
	else {
		print "note: $public_base/$asset did not answer yet; check R2 public access and the DNS record.\n";
	}
	exit 0;
}

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

# Read KEY=VALUE pairs without executing the file. Values already in the
# environment win, so a one-off `export` can override the saved secrets.
sub load_env_file {
	my ($path) = @_;
	return unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return;
	while (my $line = <$fh>) {
		chomp $line;
		next if $line =~ /^\s*(?:#|$)/;
		my ($key, $value) = $line =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/ or next;
		$value =~ s/^(['"])(.*)\1$/$2/;
		$ENV{$key} = $value unless defined $ENV{$key} && length $ENV{$key};
	}
	close $fh;
}

# PUT one object to R2 with curl's own SigV4 signer. The credentials go in on
# stdin (-K -) instead of argv, so they are not visible in the process list.
sub upload_r2 {
	my ($path, $key, $type) = @_;
	my $endpoint = sprintf('https://%s.r2.cloudflarestorage.com/%s/%s', $r2_account, $r2_bucket, $key);
	my @cmd = ('curl', '-fsS', '--retry', '3', '--retry-delay', '2',
		'--aws-sigv4', 'aws:amz:auto:s3', '-K', '-',
		'-X', 'PUT', '-H', "Content-Type: $type", '-T', $path, $endpoint);
	my $pid = open(my $fh, '|-', @cmd);
	die "mkosi_publish: cannot run curl: $!\n" unless defined $pid;
	printf {$fh} "user = \"%s:%s\"\n", $ENV{'JAWNOS_R2_ACCESS_KEY'}, $ENV{'JAWNOS_R2_SECRET'};
	close $fh;
	die "mkosi_publish: uploading $key to R2 failed\n" if $?;
	print "uploaded $key\n";
}

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
