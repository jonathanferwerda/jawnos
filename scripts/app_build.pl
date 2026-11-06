#!/usr/bin/perl
# Bump the JawnOS Android app and build+stage the next APK, in one step.
#
#   perl scripts/app_build.pl [--repo DIR] [--no-build] [--debug]
#
# It:
# 1. bumps versionCode (+1) and the patch segment of versionName in
#    app/build.gradle,
# 2. makes sure local.properties points at an Android SDK,
# 3. builds the signed release APK (the default whenever the app repo carries
#    keystore.properties, which names the tree's .secrets/jawnos-release.jks),
#    or a debug APK with --debug,
# 4. stages it with scripts/app_release.pl, replacing the old build so every
#    peer's next app_release_sync carries it.
#
# The bump is what makes the in-app updater offer the build: it compares the
# staged APK's versionCode against the installed one, so a rebuild must be
# numbered above the last release. --no-build stops after the bump.
#
# The signing key is the app's identity. A device that already runs a
# release-signed build refuses a debug-signed APK with SIGNATURE_MISMATCH, and
# the in-app updater cannot fall back: 0.118.296 went out that way on
# 2026-11-06 - correctly numbered, published, and uninstallable everywhere. So a
# release build is the default and its certificate is compared against the
# keystore's before anything is staged.
#
# The repo is left dirty on purpose: this script only builds and stages.
# Commit app/build.gradle afterwards.
#
# Only one app is built now. The retired API app (com.termux.api) is not a
# product: its BLE bridge and permission screens moved into this APK in M1.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);

my $root = abs_path("$FindBin::Bin/..");
my $home = $ENV{'HOME'};
my $dir = "$home/jawnos-app/termux-app";
my $build = 1;
my $release;    # undef means: decide from the key, below
while ( defined(my $arg = shift @ARGV) ) {
	if ($arg eq '--repo')     { $dir = shift @ARGV; next; }
	if ($arg eq '--no-build') { $build = 0; next; }
	if ($arg eq '--release')  { $release = 1; next; }
	if ($arg eq '--debug')    { $release = 0; next; }
	die "usage: app_build.pl [--repo DIR] [--no-build] [--debug]\n";
}
die "$dir: no such directory\n" unless -d $dir;

# The APK a phone installs is always the signed release build. Build it
# whenever this tree holds the key; --debug is the deliberate dev escape, and
# it says out loud what the artifact cannot do.
$release = -f "$dir/keystore.properties" ? 1 : 0 unless defined $release;
if ($release && !-f "$dir/keystore.properties") {
	die "$dir/keystore.properties is missing; the release build would be unsigned\n";
}
if (!$release && $build) {
	print "app: building the debug variant; this APK cannot install over a release-signed app\n";
}
my $gradle = "$dir/app/build.gradle";
die "$gradle: missing\n" unless -f $gradle;

# 1. bump
my $text = read_file($gradle);
my ($old_vc) = $text =~ /versionCode\s+(\d+)/;
die "no versionCode in $gradle\n" unless defined $old_vc;
my ($maj, $min, $pat) = $text =~ /versionName\s+"(\d+)\.(\d+)\.(\d+)"/;
die "no semantic versionName in $gradle\n" unless defined $pat;
my $new_vc = $old_vc + 1;
my $new_vn = "$maj.$min." . ($pat + 1);
$text =~ s/versionCode\s+\d+/versionCode $new_vc/;
$text =~ s/versionName\s+"\d+\.\d+\.\d+"/versionName "$new_vn"/;
write_file($gradle, $text);
print "app: app/build.gradle: versionCode $old_vc -> $new_vc, versionName $maj.$min.$pat -> $new_vn\n";

# 2. the SDK location gradle needs (local.properties is gitignored)
my $props = "$dir/local.properties";
unless (-f $props && (read_file($props) =~ /sdk\.dir\s*=/)) {
	my $sdk = $ENV{'ANDROID_SDK_ROOT'} || $ENV{'ANDROID_HOME'} || "$home/android-sdk";
	die "$sdk: no Android SDK found (set ANDROID_SDK_ROOT, or write $props)\n" unless -d $sdk;
	write_file($props, "sdk.dir=$sdk\n");
	print "wrote $props (sdk.dir=$sdk)\n";
}

exit 0 unless $build;

# 3. the M5 exec model. releases/native-bins/ (written by whoever builds the
# runtime) holds the executables as native libraries and a runtime-bins.txt
# naming each prefix path that wants one. Copy the manifest over the checked-in
# empty placeholder so the APK always has the asset, and point gradle at the
# directory so it can pack the libraries. The merged manifest covers the core
# and every optional part (scripts/runtime_native_bins.pl --zip PART=FILE);
# its side file names which part unlocks each entry. The directory is absent on
# a machine that has not built native bins: nothing to do, and the app keeps its
# old layout.
my $native_bins = "$root/releases/native-bins";
my @gradle_props;
# A release APK is what every phone installs, and every files/usr/bin entry on
# a device is a symlink into its lib/arm64-v8a. Built without the bins it ships
# no runtime at all: 0.118.294 was staged that way and every phone that took it
# stopped at "starting" with a dangling perl. A worktree has no releases/ (the
# directory is gitignored), so this is the shape the mistake takes.
die "app: $native_bins is missing; a release APK built without it ships no runtime, "
	. "and every install stops at 'starting'. Build the native bins on this checkout first.\n"
	if $release && !-d $native_bins;
if (-d $native_bins) {
	my $manifest = "$native_bins/runtime-bins.txt";
	if (-f $manifest) {
		my $assets = "$dir/app/src/main/assets";
		make_path($assets) unless -d $assets;
		copy($manifest, "$assets/runtime-bins.txt")
			or die "app: could not copy $manifest to $assets/runtime-bins.txt: $!\n";
		print "app: runtime-bins.txt <- $manifest\n";
		my $parts = "$native_bins/runtime-bins-parts.txt";
		if (-f $parts) {
			copy($parts, "$assets/runtime-bins-parts.txt")
				or die "app: could not copy $parts to $assets/runtime-bins-parts.txt: $!\n";
			print "app: runtime-bins-parts.txt <- $parts\n";
		}
	}
	else {
		print "app: $native_bins has no runtime-bins.txt; leaving the asset alone\n";
	}
	push @gradle_props, '-PjawnNativeBins=' . abs_path($native_bins);
}

# 3. a JDK 17, else the newest installed. AGP 8 requires 17: picking the
# oldest JDK first (11) was the pre-upgrade rule and fails now.
my $java = $ENV{'JAVA_HOME'};
$java = undef unless defined $java && -x "$java/bin/java";
unless ($java) {
	my @exact = grep { -x "$_/bin/java" } sort { $b cmp $a } glob("$home/jdk/jdk-17.*");
	my @any = grep { -x "$_/bin/java" } sort { $b cmp $a } glob("$home/jdk/jdk-*");
	$java = $exact[0] || $any[0];
}
die "no JDK found (set JAVA_HOME)\n" unless $java;
print "app: building with $java\n";

local $ENV{'JAVA_HOME'} = $java;
$ENV{'ANDROID_SDK_ROOT'} ||= (read_file($props) =~ /sdk\.dir\s*=\s*(\S+)/)[0];
$ENV{'TERMUX_SPLIT_APKS_FOR_DEBUG_BUILDS'} = '0';
$ENV{'TERMUX_SPLIT_APKS_FOR_RELEASE_BUILDS'} = '0';
my $task = $release ? ':app:assembleRelease' : ':app:assembleDebug';
my $flavour = $release ? 'release' : 'debug';
my $rc = system("$dir/gradlew", "-p", $dir, @gradle_props, $task, "--no-daemon", "--max-workers=4");
die "app: build failed (exit $rc)\n" if $rc != 0;

# 5. the universal build is the biggest APK in the output
my @apks = grep { -f } glob("$dir/app/build/outputs/apk/$flavour/*.apk");
die "app: no $flavour APK under $dir/app/build/outputs/apk/$flavour\n" unless @apks;
my ($apk) = sort { (-s $b) <=> (-s $a) } @apks;
print "app: apk $apk (" . (-s $apk) . " bytes)\n";
# Check the artifact itself, not only the inputs: a release that cannot start
# must never reach releases/ (and so never reach a phone's updater).
if ($release) {
	my $listing = `unzip -l "$apk" 2>/dev/null`;
	unless ($listing =~ m{libbin_perl\.so} && $listing =~ m{runtime-bins\.txt}) {
		die "app: $apk carries no libbin_perl.so / runtime-bins.txt; "
			. "a release without the runtime cannot start. Not staging it.\n";
	}
}
# The signature is the identity, not just "signed". A debug-signed build is a
# valid APK and still cannot install over the release build on every phone, so
# the certificate the artifact carries must be the one in the configured
# keystore. Checked before staging so a wrong-identity build never rides the
# mesh or GitHub.
if ($release) {
	my ($apk_digest, $apk_why) = apk_signer_sha256($apk);
	die "app: $apk_why; not staging $apk\n" unless $apk_digest;
	my ($key_digest, $key_why) = keystore_signer_sha256($dir, $java);
	die "app: $key_why\n" unless $key_digest;
	die "app: $apk is signed by $apk_digest, not the release key $key_digest. "
		. "A device running a release build refuses that APK (SIGNATURE_MISMATCH). Not staging it.\n"
		if $apk_digest ne $key_digest;
	print "app: signed with the release key (" . substr($apk_digest, 0, 16) . ")\n";
}
system('perl', "$root/scripts/app_release.pl", $apk) == 0 or die "app: app_release.pl failed\n";

print "next: commit the bumped app/build.gradle, then run perl scripts/app_publish.pl\n";

# The SDK tool of that name, newest build-tools first; undef when the SDK does
# not have one.
sub sdk_tool {
	my ($name) = @_;
	my $sdk = $ENV{'ANDROID_SDK_ROOT'};
	return undef unless $sdk;
	my @found;
	foreach my $p ( glob("$sdk/build-tools/*/$name") ) {
		next unless -x $p;
		my ($v) = $p =~ m{/build-tools/([^/]+)/};
		my @n = split /\./, ( $v || '0' );
		push @found, [ ($n[0] || 0) * 1_000_000 + ($n[1] || 0) * 1_000 + ($n[2] || 0), $p ];
	}
	return undef unless @found;
	@found = sort { $b->[0] <=> $a->[0] } @found;
	return $found[0][1];
}

# The APK's signer as lowercase hex, or the reason it could not be read.
sub apk_signer_sha256 {
	my ($apk) = @_;
	my $apksigner = sdk_tool('apksigner');
	return (undef, 'no apksigner in the Android SDK build-tools')
		unless $apksigner;
	my $out = `"$apksigner" verify --print-certs "$apk" 2>&1`;
	return (undef, 'apksigner does not verify the APK as signed') if $? != 0;
	my ($hex) = $out =~ /certificate SHA-256 digest:\s*([0-9a-fA-F]+)/;
	return (undef, 'apksigner printed no signer certificate') unless $hex;
	$hex = lc $hex;
	$hex =~ s/[^0-9a-f]//g;
	return ($hex);
}

# The release key's certificate as lowercase hex, or the reason it could not be
# read. keystore.properties is gitignored and names the store, password and
# alias the gradle release signingConfig uses.
sub keystore_signer_sha256 {
	my ($repo, $java) = @_;
	my $props = "$repo/keystore.properties";
	my %p;
	foreach my $line (split /\n/, read_file($props)) {
		next unless $line =~ /^\s*([^=:#\s]+)\s*[=:]\s*(.*?)\s*$/;
		$p{$1} = $2;
	}
	return (undef, "$props names no storeFile") unless length($p{'storeFile'} || '');
	my $store = $p{'storeFile'};
	$store = "$repo/$store" unless $store =~ m{^/};
	return (undef, "$store: no such keystore") unless -f $store;
	my $keytool = "$java/bin/keytool";
	return (undef, "$keytool: no keytool in the JDK") unless -x $keytool;
	my @args = ($keytool, '-list', '-v', '-keystore', $store, '-storepass', $p{'storePassword'} || '');
	push @args, ('-alias', $p{'keyAlias'}) if length($p{'keyAlias'} || '');
	open(my $fh, '-|', @args) or return (undef, "could not run $keytool: $!");
	my $out = do { local $/; <$fh> };
	close $fh;
	my ($hex) = $out =~ /SHA256:\s*([0-9A-Fa-f:]+)/;
	return (undef, "$store: could not read the certificate for " . ($p{'keyAlias'} || 'the key'))
		unless $hex;
	$hex = lc $hex;
	$hex =~ s/[^0-9a-f]//g;
	return ($hex);
}
