#!/usr/bin/perl
# Bump the JawnOS Android app and build+stage the next APK, in one step.
#
#   perl scripts/app_build.pl [--repo DIR] [--no-build] [--release]
#
# It:
# 1. bumps versionCode (+1) and the patch segment of versionName in
#    app/build.gradle,
# 2. makes sure local.properties points at an Android SDK,
# 3. builds the debug APK (one universal file), or the signed release APK
#    with --release (needs the tree's .secrets/jawnos-release.jks, named by
#    the app repo's gitignored keystore.properties),
# 4. stages it with scripts/app_release.pl, replacing the old build so every
#    peer's next app_release_sync carries it.
#
# The bump is what makes the in-app updater offer the build: it compares the
# staged APK's versionCode against the installed one, so a rebuild must be
# numbered above the last release. --no-build stops after the bump.
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
my $release = 0;
while ( defined(my $arg = shift @ARGV) ) {
	if ($arg eq '--repo')     { $dir = shift @ARGV; next; }
	if ($arg eq '--no-build') { $build = 0; next; }
	if ($arg eq '--release')  { $release = 1; next; }
	die "usage: app_build.pl [--repo DIR] [--no-build] [--release]\n";
}
if ($release && !-f "$dir/keystore.properties") {
	die "$dir/keystore.properties is missing; the release build would be unsigned\n";
}
die "$dir: no such directory\n" unless -d $dir;
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
# directory so it can pack the libraries. The directory is absent on a machine
# that has not built native bins: nothing to do, and the app keeps its old
# layout.
my $native_bins = "$root/releases/native-bins";
my @gradle_props;
if (-d $native_bins) {
	my $manifest = "$native_bins/runtime-bins.txt";
	if (-f $manifest) {
		my $assets = "$dir/app/src/main/assets";
		make_path($assets) unless -d $assets;
		copy($manifest, "$assets/runtime-bins.txt")
			or die "app: could not copy $manifest to $assets/runtime-bins.txt: $!\n";
		print "app: runtime-bins.txt <- $manifest\n";
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
system('perl', "$root/scripts/app_release.pl", $apk) == 0 or die "app: app_release.pl failed\n";

print "next: commit the bumped app/build.gradle, then run perl scripts/app_publish.pl\n";
