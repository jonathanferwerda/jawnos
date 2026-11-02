use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

# The device layers are shell scripts, which verify_change.pl does not look at.
# These checks pin the two promises that make the layers honest:
#
#   1. they build from the newest source every run - no cached image, no stale
#      quickboot snapshot, no reused staged APK;
#   2. they never write the real release store or a real device.

my $qa = "$FindBin::Bin/../qa";

for my $script (qw(android/build.sh android/run.sh qemu/build.sh qemu/run.sh)) {
	my $path = "$qa/$script";
	ok(-f $path, "$script exists");
	ok(-x $path, "$script is executable");
	my $rc = system('sh', '-n', $path);
	is($rc, 0, "$script parses under sh");
}

# --- Android: build, never release -------------------------------------------
{
	my $build = read_file("$qa/android/build.sh");
	like($build, qr/:app:assembleDebug/, 'the APK is built from source');
	unlike($build, qr{^\s*(?:perl|sudo)\s+\S*app_build\.pl}m,
		'the release bump/stage script is not run');
	unlike($build, qr/versionCode\s*=/, 'versionCode is not touched');
	like($build, qr/java-17-openjdk|java-21-openjdk/, 'a supported JDK is selected');
}

{
	my $run = read_file("$qa/android/run.sh");
	like($run, qr/-no-snapshot/, 'a stale quickboot image cannot pass as current');
	like($run, qr/ANDROID_AVD_HOME=/, 'the AVD is copied, not written in place');
	like($run, qr/adb\s+-s\s+"?\$SERIAL"?\s+reverse/, 'the app is pointed at the QA instance');
	unlike($run, qr/adb\s+.*-s\s+.*(?:real|tablet)\b/i, 'no real device is named');
}

# --- QEMU: rebuild, then snapshot --------------------------------------------
{
	my $build = read_file("$qa/qemu/build.sh");
	like($build, qr/\$SUDO\s+perl\s+scripts\/mkosi_build\.pl|sudo\s+-n\s+perl\s+scripts\/mkosi_build\.pl/,
		'the image is rebuilt as root (directly, or through passwordless sudo)');
	unlike($build, qr/--no-build|reuse/i, 'there is no cached-image path');
}

{
	my $run = read_file("$qa/qemu/run.sh");
	like($run, qr/snapshot=on/, 'the image disk is opened with snapshot=on');
	like($run, qr/-display none/, 'the VM is headless');
	like($run, qr/hostfwd=.*45545/, 'the manager port is forwarded for a health check');
}

done_testing();
