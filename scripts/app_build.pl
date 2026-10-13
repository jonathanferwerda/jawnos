#!/usr/bin/perl
# Bump the JawnOS Android app and build+stage the next APK, in one step.
#
#   perl scripts/app_build.pl [--repo DIR] [--no-build]
#
# 1. bumps versionCode and the versionName patch in app/build.gradle
#    (1007 / 0.118.8 -> 1008 / 0.118.9),
# 2. makes sure local.properties points at an Android SDK,
# 3. builds the debug APK (debug splits off, so one universal file),
# 4. stages it with scripts/app_release.pl - replacing the old build of the
#    product, so every peer's next app_release_sync carries it.
#
# The bump is what makes the in-app updater offer the build: it compares the
# staged APK's versionCode against the installed one, so a rebuild must be
# numbered above the last release (docs/AGENTS-notes.md, the version-code
# note). --no-build stops after the bump, for preparing a release before the
# long build.
#
# The app repo is left dirty on purpose: this script only builds and stages.
# Commit the bumped app/build.gradle (and push) as usual afterwards.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Slurp qw(read_file write_file);

my $root = abs_path("$FindBin::Bin/..");
my $repo = "$ENV{'HOME'}/jawnos-app/termux-app";
my $build = 1;
while (defined(my $arg = shift @ARGV)) {
	if ($arg eq '--repo')     { $repo = shift @ARGV; next; }
	if ($arg eq '--no-build') { $build = 0; next; }
	die "usage: app_build.pl [--repo DIR] [--no-build]\n";
}
die "$repo: no such directory\n" unless -d $repo;
my $gradle = "$repo/app/build.gradle";
die "$gradle: missing\n" unless -f $gradle;

# 1. bump. versionCode is the series the updater compares; versionName is the
#    human label ("0.118.8"), bumped at its patch segment.
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
print "app/build.gradle: versionCode $old_vc -> $new_vc, versionName $maj.$min.$pat -> $new_vn\n";

# 2. the SDK location gradle needs (local.properties is gitignored)
my $props = "$repo/local.properties";
unless (-f $props && (read_file($props) =~ /sdk\.dir\s*=/)) {
	my $sdk = $ENV{'ANDROID_SDK_ROOT'} || $ENV{'ANDROID_HOME'} || "$ENV{'HOME'}/android-sdk";
	die "$sdk: no Android SDK found (set ANDROID_SDK_ROOT, or write $props)\n" unless -d $sdk;
	write_file($props, "sdk.dir=$sdk\n");
	print "wrote $props (sdk.dir=$sdk)\n";
}

unless ($build) {
	print "stopped before the build (--no-build); run without it to build and stage\n";
	exit 0;
}

# 3. a JDK: JAVA_HOME when it holds one, else the newest ~/jdk/jdk-*
my $java = $ENV{'JAVA_HOME'};
$java = undef unless defined $java && -x "$java/bin/java";
unless ($java) {
	my @jdks = grep { -x "$_/bin/java" } sort { $b cmp $a } glob("$ENV{'HOME'}/jdk/jdk-*");
	$java = shift @jdks;
}
die "no JDK found (set JAVA_HOME)\n" unless $java;
print "building with $java\n";

local $ENV{'JAVA_HOME'} = $java;
$ENV{'ANDROID_SDK_ROOT'} ||= (read_file($props) =~ /sdk\.dir\s*=\s*(\S+)/)[0];
$ENV{'TERMUX_SPLIT_APKS_FOR_DEBUG_BUILDS'} = '0';
my $rc = system("$repo/gradlew", "-p", $repo, ":app:assembleDebug", "--no-daemon", "--max-workers=4");
die "build failed (exit $rc)\n" if $rc != 0;

# 4. the universal build is the biggest APK in the debug output
my @apks = grep { -f } glob("$repo/app/build/outputs/apk/debug/*.apk");
die "no debug APK under $repo/app/build/outputs/apk/debug\n" unless @apks;
my ($apk) = sort { (-s $b) <=> (-s $a) } @apks;
print "apk: $apk (" . (-s $apk) . " bytes)\n";
system('perl', "$root/scripts/app_release.pl", $apk) == 0 or die "app_release.pl failed\n";
print "next: commit the bump - git -C $repo add app/build.gradle\n";
