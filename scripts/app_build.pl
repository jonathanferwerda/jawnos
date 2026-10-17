#!/usr/bin/perl
# Bump the JawnOS Android apps and build+stage the next APKs, in one step.
#
#   perl scripts/app_build.pl [--product app|api|all] [--repo DIR] [--api-repo DIR] [--no-build]
#
# products:
#   app  termux-app  (~/jawnos-app/termux-app, JDK 11)  -> jawnos-app-<vc>-<vn>.apk
#   api  termux-api  (~/jawnos-app/termux-api, JDK 17)  -> jawnos-api-<vc>-<vn>.apk
#
# For each selected product it:
# 1. bumps versionCode (+1) and the patch segment of versionName in
#    app/build.gradle,
# 2. makes sure local.properties points at an Android SDK,
# 3. builds the debug APK (one universal file),
# 4. stages it with scripts/app_release.pl, replacing the old build of that
#    product so every peer's next app_release_sync carries it.
#
# The bump is what makes the in-app updater offer the build: it compares the
# staged APK's versionCode against the installed one, so a rebuild must be
# numbered above the last release. --no-build stops after the bump.
#
# The repos are left dirty on purpose: this script only builds and stages.
# Commit each bumped app/build.gradle afterwards.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Slurp qw(read_file write_file);

my $root = abs_path("$FindBin::Bin/..");
my $home = $ENV{'HOME'};
my %repo = (
	app => "$home/jawnos-app/termux-app",
	api => "$home/jawnos-app/termux-api",
);
my %jdk_major = ( app => 11, api => 17 );
my $product = 'all';
my $build = 1;
while ( defined(my $arg = shift @ARGV) ) {
	if ($arg eq '--product')  { $product = shift @ARGV; next; }
	if ($arg eq '--repo')     { $repo{'app'} = shift @ARGV; next; }
	if ($arg eq '--api-repo') { $repo{'api'} = shift @ARGV; next; }
	if ($arg eq '--no-build') { $build = 0; next; }
	die "usage: app_build.pl [--product app|api|all] [--repo DIR] [--api-repo DIR] [--no-build]\n";
}
die "app_build.pl: --product must be app, api or all\n" unless $product =~ /^(?:app|api|all)$/;
my @products = $product eq 'all' ? qw(app api) : ($product);

foreach my $p (@products) {
	my $dir = $repo{$p};
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
	print "$p: app/build.gradle: versionCode $old_vc -> $new_vc, versionName $maj.$min.$pat -> $new_vn\n";

	# 2. the SDK location gradle needs (local.properties is gitignored)
	my $props = "$dir/local.properties";
	unless (-f $props && (read_file($props) =~ /sdk\.dir\s*=/)) {
		my $sdk = $ENV{'ANDROID_SDK_ROOT'} || $ENV{'ANDROID_HOME'} || "$home/android-sdk";
		die "$sdk: no Android SDK found (set ANDROID_SDK_ROOT, or write $props)\n" unless -d $sdk;
		write_file($props, "sdk.dir=$sdk\n");
		print "wrote $props (sdk.dir=$sdk)\n";
	}

	next unless $build;

	# 3. a JDK of the major the product asks for, else the newest installed
	my $java = $ENV{'JAVA_HOME'};
	$java = undef unless defined $java && -x "$java/bin/java";
	unless ($java) {
		my @exact = grep { -x "$_/bin/java" } sort { $b cmp $a } glob("$home/jdk/jdk-$jdk_major{$p}.*");
		my @any = grep { -x "$_/bin/java" } sort { $b cmp $a } glob("$home/jdk/jdk-*");
		$java = $exact[0] || $any[0];
	}
	die "no JDK found (set JAVA_HOME)\n" unless $java;
	print "$p: building with $java\n";

	local $ENV{'JAVA_HOME'} = $java;
	$ENV{'ANDROID_SDK_ROOT'} ||= (read_file($props) =~ /sdk\.dir\s*=\s*(\S+)/)[0];
	$ENV{'TERMUX_SPLIT_APKS_FOR_DEBUG_BUILDS'} = '0';
	my $rc = system("$dir/gradlew", "-p", $dir, ":app:assembleDebug", "--no-daemon", "--max-workers=4");
	die "$p: build failed (exit $rc)\n" if $rc != 0;

	# 4. the universal build is the biggest APK in the debug output
	my @apks = grep { -f } glob("$dir/app/build/outputs/apk/debug/*.apk");
	die "$p: no debug APK under $dir/app/build/outputs/apk/debug\n" unless @apks;
	my ($apk) = sort { (-s $b) <=> (-s $a) } @apks;
	print "$p: apk $apk (" . (-s $apk) . " bytes)\n";
	system('perl', "$root/scripts/app_release.pl", $apk) == 0 or die "$p: app_release.pl failed\n";
}

if ($build) {
	print "next: commit each bumped app/build.gradle, then run perl scripts/app_publish.pl\n";
}
