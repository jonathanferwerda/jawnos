#!/bin/sh
# The weekly emulator run (qa/systemd/jawnos-qa-emulator.timer, Sunday 07:00).
#
# It builds the APK from the app repo's HEAD and then runs the same l4 checks a
# person runs by hand (qa/android/run.sh), so what the timer proves is what a
# run boots. Nothing is published and no versionCode is bumped: a dev build.
#
# It belongs on the machine with the SDK, the AVD and KVM -- table, as the QA
# map says -- like the weekly build belongs where mkosi and qemu are. On a
# machine that cannot run it, it writes a `skipped` report and exits 0: the
# unit must not go red for a toolchain that is deliberately elsewhere, and the
# panel then says so instead of showing nothing.
#
# The report is what Configure -> Plat -> QA -> Nightly reports shows, stamped
# `weekly` because that is how this run was started.

set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
QA_ROOT=${QA_ROOT:-$HOME/jawnos-qa}
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/android-sdk}}
AVD=${QA_AVD:-jawnos}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOGS="$QA_ROOT/build"

report() {
	# $1 status, $2 note
	perl "$REPO/scripts/qa_report.pl" --kind=emulator --schedule=weekly \
		--status "$1" --title 'Emulator run' --note "$2" --stamp "$STAMP" \
		--root "$QA_ROOT" >/dev/null 2>&1 || :
}

skip() {
	report skipped "$1"
	echo "qa-emulator: skipped - $1"
	exit 0
}

[ -x "$SDK/emulator/emulator" ] || skip "no emulator under $SDK"
[ -f "$HOME/.android/avd/$AVD.ini" ] || skip "no AVD named $AVD under ~/.android/avd"
[ -e /dev/kvm ] || skip "no /dev/kvm here, so the emulator would be too slow to be a test"

mkdir -p "$LOGS"
BUILD_LOG="$LOGS/$STAMP-emulator-apk.log"
if ! sh "$REPO/qa/android/build.sh" "$QA_ROOT/android" > "$BUILD_LOG" 2>&1; then
	tail -20 "$BUILD_LOG" >&2
	report failed "the APK did not build (see $BUILD_LOG)"
	echo "qa-emulator: the APK did not build" >&2
	exit 1
fi

APK=$(tail -n 1 "$BUILD_LOG")
if [ ! -s "$APK" ]; then
	report failed "the build printed no APK path"
	echo "qa-emulator: the build printed no APK path" >&2
	exit 1
fi

# run.sh writes the report itself, on pass and on failure, and reads the cadence
# from QA_SCHEDULE so this run is labelled weekly rather than manual.
QA_SCHEDULE=weekly sh "$REPO/qa/android/run.sh" "$APK"
