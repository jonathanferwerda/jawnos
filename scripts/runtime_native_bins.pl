#!/usr/bin/perl
# Turn a runtime archive's executables into jniLibs payload (M5,
# docs/roadmap-handoff.md).
#
#   perl scripts/runtime_native_bins.pl --zip FILE [--zip PART=FILE ...]
#       --out DIR [--abi arm64-v8a] [--prefix-path PATH] [--dry-run]
#
# --zip is repeatable: the core archive plus the optional parts. A value may be
# written PART=FILE (media=releases/jawnrt-aarch64-media-0.1.1710.zip) so the
# manifest records which part unlocks an executable; a bare path is the core.
# The merged runtime-bins.txt stays three tab-separated fields, exactly what the
# shipped app's JawnRuntimeBins reads; the part name goes in the side file
# runtime-bins-parts.txt for the updater's benefit.
#
# Android refuses to exec a file in app data at targetSdk 29+, but it will exec
# one extracted from the APK under nativeLibraryDir. A symlink in app data that
# points at nativeLibraryDir/libx.so does exec (Spike B, targetSdk 36). So every
# executable the runtime may run ships as jniLibs/<abi>/lib<slug>.so, and the app
# creates the symlink at the runtime's original path on each start.
#
# This script reads a staged runtime zip (scripts/runtime_zip.pl's output), takes
# only bin/ and libexec/, copies each regular executable to <out>/<abi>/lib<slug>.so
# and writes <out>/runtime-bins.txt: one tab-separated line per entry, sorted by
# path, either
#
#   bin/perl<TAB>file<TAB>bin_perl
#   bin/awk<TAB>link<TAB>bin/gawk
#
# A link line's target is resolved inside the archive when it names a path under
# bin/ or libexec/ (relative targets are resolved from the link's directory; a
# leading @TERMUX_PREFIX@ or --prefix-path is removed first). A target outside
# those two trees is stored as-is so the app can skip it.
#
# Exit status: 0 on success. --dry-run prints the plan and touches nothing.

use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Archive::Zip qw(:ERROR_CODES);

my ($out, $abi, $prefix_path, $dry, $help);
my @zip_args;
while ( defined(my $a = shift @ARGV) ) {
	if ($a eq '--zip') { push @zip_args, shift @ARGV }
	elsif ($a eq '--out') { $out = shift @ARGV }
	elsif ($a eq '--abi') { $abi = shift @ARGV }
	elsif ($a eq '--prefix-path') { $prefix_path = shift @ARGV }
	elsif ($a eq '--dry-run') { $dry = 1 }
	elsif ($a eq '--help' || $a eq '-h') { $help = 1 }
	else { die "runtime_native_bins.pl: unknown option $a\n" }
}
if ($help) {
	print <<'USAGE';
perl scripts/runtime_native_bins.pl --zip FILE [--zip PART=FILE ...] --out DIR
    [--abi arm64-v8a] [--prefix-path PATH] [--dry-run]

  --zip          a staged archive (bin/ and libexec/ are used); repeatable.
                 PART=FILE labels the archive's part (core, media, ocr)
  --out          the directory to write <abi>/lib<slug>.so and runtime-bins.txt
  --abi          the jniLibs ABI directory (default arm64-v8a)
  --prefix-path  an absolute prefix to strip from link targets, e.g.
                 /data/data/com.termux/files/usr (default: @TERMUX_PREFIX@ only)
  --dry-run      print the manifest plan and the counts; write nothing
USAGE
	exit 0;
}
die "runtime_native_bins.pl: --zip is required\n" unless @zip_args;
die "runtime_native_bins.pl: --out is required\n" unless defined $out && length $out;
my @zips;
foreach my $arg (@zip_args) {
	my ($part, $path) = ('core', $arg);
	if ($arg =~ m{^([A-Za-z0-9_-]+)=(.+)$} && -f $2) { ($part, $path) = ($1, $2) }
	die "runtime_native_bins.pl: no such zip: $path\n" unless -f $path;
	push @zips, { part => $part, path => $path };
}
$abi ||= 'arm64-v8a';
die "runtime_native_bins.pl: --abi looks wrong: $abi\n"
	unless $abi =~ m{^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*$};
if (defined $prefix_path && length $prefix_path) {
	$prefix_path =~ s{/+$}{};
	die "runtime_native_bins.pl: --prefix-path must be absolute\n"
		unless $prefix_path =~ m{^/};
}

# --- read the archives ------------------------------------------------------
sub open_zip {
	my ($path) = @_;
	my $zip = Archive::Zip->new;
	my $rc = $zip->read($path);
	if ($rc != AZ_OK) {
		my %why = (
			AZ_ERROR        => 'read error',
			AZ_FORMAT_ERROR => 'not a zip archive',
			AZ_IO_ERROR     => 'I/O error',
		);
		die "runtime_native_bins: cannot read $path: "
			. ($why{$rc} // "Archive::Zip error $rc") . "\n";
	}
	return $zip;
}

# --- options that touch a link target ---------------------------------------
# A symlink in bin/ is usually a short relative name (bin/awk -> gawk); git's
# libexec helpers point up at ../../bin/git. Some prefixes store an absolute
# target instead, either with the build-time placeholder or with the real
# prefix. Everything is turned into a prefix-relative path when it lands in
# bin/ or libexec/, so the app can match a link line to a file line.
sub normalize_rel {
	my ($path) = @_;
	my @out;
	foreach my $seg (split m{/}, $path) {
		next if $seg eq '' || $seg eq '.';
		if ($seg eq '..') {
			return undef unless @out;   # climbed above the archive root
			pop @out;
		}
		else { push @out, $seg }
	}
	return join '/', @out;
}

sub link_target {
	my ($entry, $stored) = @_;
	my $target = defined $stored ? $stored : '';
	my $original = $target;
	my $relative = 0;

	if ($target =~ m{^\@TERMUX_PREFIX\@(?=/|$)}) {
		$target = substr($target, length '@TERMUX_PREFIX@');
		$target =~ s{^/+}{};
		$relative = 1;
	}
	elsif (defined $prefix_path && length $prefix_path
		&& ($target eq $prefix_path || index($target, "$prefix_path/") == 0)) {
		$target = substr($target, length $prefix_path);
		$target =~ s{^/+}{};
		$relative = 1;
	}
	elsif ($target !~ m{^/}) {
		$target = dirname($entry) . '/' . $target;
		$relative = 1;
	}
	return $original unless $relative;

	my $resolved = normalize_rel($target);
	return $original unless defined $resolved;
	return $resolved if $resolved =~ m{^(?:bin|libexec)(?:/|$)};
	return $original;
}

# --- select bin/ and libexec/ ------------------------------------------------
my (@records, %used_slug, %seen_path);
my ($entries, $executables, $symlinks, $other, $bytes) = (0, 0, 0, 0, 0);

foreach my $source (@zips) {
	my $zip = open_zip($source->{path});
	foreach my $member ($zip->members) {
		next if $member->isDirectory;
		my $path = $member->fileName;
		$path =~ s{^\./}{};
		next unless $path =~ m{^(?:bin|libexec)/};
		next if $path =~ m{^bin/?$} || $path =~ m{^libexec/?$};
		if ($seen_path{$path}++) {
			die "runtime_native_bins: $path appears in more than one archive; "
				. "a merged manifest cannot name it twice\n";
		}

		$entries++;
		my $mode = $member->unixFileAttributes;
		my $type = $mode & 0170000;

		if ($type == 0120000) {                      # S_IFLNK
			my $target = $member->contents;
			push @records, {
				path   => $path,
				kind   => 'link',
				target => link_target($path, $target),
				part   => $source->{part},
			};
			$symlinks++;
		}
		elsif (($type == 0 || $type == 0100000) && ($mode & 0111)) {
			push @records, {
				path   => $path,
				kind   => 'file',
				member => $member,
				mode   => $mode,
				size   => $member->uncompressedSize,
				part   => $source->{part},
				zip    => $source->{path},
			};
			$executables++;
			$bytes += $member->uncompressedSize;
		}
		else {
			$other++;   # scripts sourced by git, docs, anything not executable
		}
	}
}

die "runtime_native_bins: no executables under bin/ or libexec/ in "
	. join(', ', map { $_->{path} } @zips) . "\n"
	unless $executables;

# --- assign slugs and build the manifest ------------------------------------
@records = sort { $a->{path} cmp $b->{path} } @records;
sub unique_slug {
	my ($path) = @_;
	(my $base = $path) =~ s{[^A-Za-z0-9_]}{_}g;
	my $slug = $base;
	my $n = 1;
	while ($used_slug{$slug}) {
		$n++;
		$slug = "${base}_$n";
	}
	$used_slug{$slug} = 1;
	return $slug;
}

my @manifest;
my @parts_manifest;
foreach my $record (@records) {
	if ($record->{kind} eq 'file') {
		$record->{slug} = unique_slug($record->{path});
		push @manifest, join("\t", $record->{path}, 'file', $record->{slug});
	}
	else {
		push @manifest, join("\t", $record->{path}, 'link', $record->{target});
	}
	push @parts_manifest, join("\t", $record->{part}, $record->{path}, $record->{kind});
}

my $mb = sprintf('%.1f', $bytes / (1024 * 1024));
if ($dry) {
	print "$_\n" foreach @manifest;
	printf "runtime_native_bins: %d entries under bin/ libexec/ (%d executables, %d symlinks, %d other)\n",
		$entries, $executables, $symlinks, $other;
	printf "runtime_native_bins: dry-run - would write %d files, %s MB to %s/%s and a manifest to %s/runtime-bins.txt\n",
		$executables, $mb, $out, $abi, $out;
	exit 0;
}

# --- write the payload and the manifest --------------------------------------
make_path("$out/$abi");
foreach my $record (grep { $_->{kind} eq 'file' } @records) {
	my $data = $record->{member}->contents;
	die "runtime_native_bins: cannot read $record->{path} from $record->{zip}\n"
		unless defined $data;
	my $file = "$out/$abi/lib$record->{slug}.so";
	open(my $fh, '>', $file) or die "runtime_native_bins: $file: $!\n";
	binmode $fh;
	print {$fh} $data;
	close $fh or die "runtime_native_bins: $file: $!\n";
	# The archive says 0700; jniLibs payload is data, but keep it 0755-ish so
	# the same file works if someone runs it while debugging on the host.
	chmod((($record->{mode} & 0777) | 0555), $file);
}

my $manifest_path = "$out/runtime-bins.txt";
open(my $mf, '>:encoding(UTF-8)', $manifest_path)
	or die "runtime_native_bins: $manifest_path: $!\n";
print {$mf} "$_\n" foreach @manifest;
close $mf or die "runtime_native_bins: $manifest_path: $!\n";

# The side file names the part that unlocks each entry. It is not read by the
# shipped JawnRuntimeBins (whose format is fixed at three fields), but it is
# the contract the part installer uses to know what a downloaded part adds.
my $parts_path = "$out/runtime-bins-parts.txt";
open(my $pf, '>:encoding(UTF-8)', $parts_path)
	or die "runtime_native_bins: $parts_path: $!\n";
print {$pf} "$_\n" foreach @parts_manifest;
close $pf or die "runtime_native_bins: $parts_path: $!\n";

printf "runtime_native_bins: %d entries under bin/ libexec/ (%d executables, %d symlinks, %d other)\n",
	$entries, $executables, $symlinks, $other;
printf "runtime_native_bins: wrote %d files, %s MB to %s/%s\n",
	$executables, $mb, $out, $abi;
# A runtime built with a narrow prefix rewrite (.../files/usr) leaves the home
# path that sshd and sshd-session carry, and every phone login then prints
# "Could not chdir to home directory /data/data/com.termux/files/home". That
# shipped once (0.1.1750's jniLibs), so refuse to emit such a library.
for my $so (glob("$out/$abi/*.so")) {
	open(my $sh, '<', $so) or die "runtime_native_bins: $so: $!\n";
	binmode $sh;
	local $/;
	my $raw = <$sh>;
	close $sh;
	if (defined $raw && $raw =~ /com\.termux/) {
		die "runtime_native_bins: $so still names com.termux; build the runtime with\n"
		  . "  --rewrite-prefix /data/data/com.termux/files=/data/data/com.jawnos/files\n";
	}
}

printf "runtime_native_bins: manifest %s (%d entries: %d file, %d link)\n",
	$manifest_path, scalar(@manifest), $executables, $symlinks;
printf "runtime_native_bins: parts %s (%d entries)\n", $parts_path, scalar(@parts_manifest);
