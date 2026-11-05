# tests-for: qa/android/build.sh qa/android/run.sh qa/android/weekly.sh qa/qemu/build.sh qa/qemu/run.sh qa/nightly_build.sh qa/systemd/jawnos-qa-emulator.service qa/systemd/jawnos-qa-emulator.timer scripts/verify_change.pl
# covers:    The device layers are shell scripts, which verify_change.pl does not look at.

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
	like($build, qr/CLEAN/, 'a clean build can be asked for');
	like($build, qr/gradlew[^\n]*clean[^\n]*:app:assembleDebug/,
		'a clean run compiles from scratch rather than reusing incremental state');
}

# --- the weekly emulator run --------------------------------------------------
{
	my $weekly = read_file("$qa/android/weekly.sh");
	ok( -f "$qa/android/weekly.sh", 'the weekly emulator job exists' );
	ok( -x "$qa/android/weekly.sh", 'and is executable' );
	is( system('sh', '-n', "$qa/android/weekly.sh"), 0, 'it parses under sh' );
	like( $weekly, qr{qa/android/build\.sh}, 'it builds the APK before booting anything' );
	like( $weekly, qr{qa/android/run\.sh}, 'and runs the same l4 checks a person runs' );
	like( $weekly, qr/QA_SCHEDULE=weekly/, 'labelling the report weekly, not manual' );
	like( $weekly, qr/^skip\(\)/m, 'a machine without the emulator skips' );
	like( $weekly, qr/--status "\$1"|--status \$1/, 'and leaves the skipped status for the panel' );
	unlike( $weekly, qr{app_publish\.pl|app_build\.pl}, 'it never publishes or bumps a release' );

	my $service = read_file("$qa/systemd/jawnos-qa-emulator.service");
	my $timer   = read_file("$qa/systemd/jawnos-qa-emulator.timer");
	like( $service, qr{ExecStart=/bin/sh \S+/qa/android/weekly\.sh}, 'the unit runs the weekly job' );
	like( $timer, qr/OnCalendar=Sun \*-\*-\* 07:00:00/, 'Sunday 07:00, after the build and the coding night' );
	unlike( $service, qr/device_target/, 'no device gate: it belongs where the AVD is' );
	like( $service, qr/TimeoutStartSec=45min/, 'a booted AVD is given room' );
}

# --- the weekly artefact build ------------------------------------------------
{
	my $weekly = read_file("$qa/nightly_build.sh");
	ok( -f "$qa/nightly_build.sh", 'the weekly build script exists' );
	is( system('sh', '-n', "$qa/nightly_build.sh"), 0, 'it parses under sh' );
	like($weekly, qr/CLEAN=1/, 'the Android step is a clean build, never an UP-TO-DATE no-op');
	like($weekly, qr/Installing Android SDK/,
		'a component the build had to download fails the run (the prune and the build disagree)');
	unlike($weekly, qr/app_publish\.pl|app_build\.pl/, 'it never publishes or bumps a release');
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
