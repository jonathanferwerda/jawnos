#!/usr/bin/perl
# Bump the JawnOS Android app and build+stage the next APK, in one step.
#
#   perl scripts/app_build.pl [--repo DIR] [--no-build]
#
# It:
# 1. bumps versionCode (+1) and the patch segment of versionName in
#    app/build.gradle,
# 2. makes sure local.properties points at an Android SDK,
# 3. builds the debug APK (one universal file),
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
use File::Slurp qw(read_file write_file);

my $root = abs_path("$FindBin::Bin/..");
my $home = $ENV{'HOME'};
my $dir = "$home/jawnos-app/termux-app";
my $build = 1;
while ( defined(my $arg = shift @ARGV) ) {
	if ($arg eq '--repo')     { $dir = shift @ARGV; next; }
	if ($arg eq '--no-build') { $build = 0; next; }
	die "usage: app_build.pl [--repo DIR] [--no-build]\n";
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

# 3. a JDK 11, else the newest installed
my $java = $ENV{'JAVA_HOME'};
$java = undef unless defined $java && -x "$java/bin/java";
unless ($java) {
	my @exact = grep { -x "$_/bin/java" } sort { $b cmp $a } glob("$home/jdk/jdk-11.*");
	my @any = grep { -x "$_/bin/java" } sort { $b cmp $a } glob("$home/jdk/jdk-*");
	$java = $exact[0] || $any[0];
}
die "no JDK found (set JAVA_HOME)\n" unless $java;
print "app: building with $java\n";

local $ENV{'JAVA_HOME'} = $java;
$ENV{'ANDROID_SDK_ROOT'} ||= (read_file($props) =~ /sdk\.dir\s*=\s*(\S+)/)[0];
$ENV{'TERMUX_SPLIT_APKS_FOR_DEBUG_BUILDS'} = '0';
my $rc = system("$dir/gradlew", "-p", $dir, ":app:assembleDebug", "--no-daemon", "--max-workers=4");
die "app: build failed (exit $rc)\n" if $rc != 0;

# 4. the universal build is the biggest APK in the debug output
my @apks = grep { -f } glob("$dir/app/build/outputs/apk/debug/*.apk");
die "app: no debug APK under $dir/app/build/outputs/apk/debug\n" unless @apks;
my ($apk) = sort { (-s $b) <=> (-s $a) } @apks;
print "app: apk $apk (" . (-s $apk) . " bytes)\n";
system('perl', "$root/scripts/app_release.pl", $apk) == 0 or die "app: app_release.pl failed\n";

print "next: commit the bumped app/build.gradle, then run perl scripts/app_publish.pl\n";
