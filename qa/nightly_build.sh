#!/bin/sh
# Build the QA artefacts from the current tree, unattended.
#
#   qa/nightly_build.sh            # QEMU image, then the Android APK
#   qa/nightly_build.sh qemu       # image only
#   qa/nightly_build.sh android    # APK only
#
# Each step is the same script a person runs by hand (qa/qemu/build.sh,
# qa/android/build.sh), so what a nightly proves is what a run boots. Nothing
# is staged into releases/ and no versionCode is bumped: these are dev builds.
#
# Output: the artefact path in $QA_ROOT/{qemu/image.path,android/*.apk} and a log
# per step under $QA_ROOT/build/. The QEMU image needs root or passwordless sudo;
# the APK needs a full JDK 17 (javac + jlink) and ~/android-sdk.
#
# Driven by qa/systemd/jawnos-qa-build.timer (weekly). It is deliberately not
# part of the 05:00 QA suite: a cold image build is ~20-40 min, and the suite
# must stay fast enough to run every night.

set -eu

WHAT=${1:-all}
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
QA_ROOT=${QA_ROOT:-$HOME/jawnos-qa}
LOGS="$QA_ROOT/build"

case "$WHAT" in
	all|qemu|android) ;;
	*) echo "usage: $0 [all|qemu|android]" >&2; exit 2 ;;
esac

mkdir -p "$LOGS"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RC=0

run() {
	name=$1
	shift
	log="$LOGS/$STAMP-$name.log"
	echo "$name: $log"
	if ! "$@" > "$log" 2>&1; then
		echo "qa-build: $name failed; tail of $log:" >&2
		tail -20 "$log" >&2
		RC=1
		return 1
	fi
	return 0
}

# One build at a time: a second start while the first is running would race for
# the same output directory.
if command -v flock > /dev/null 2>&1; then
	exec 9> "$LOGS/.lock"
	if ! flock -n 9; then
		echo "qa-build: another build is running (lock $LOGS/.lock)" >&2
		exit 3
	fi
fi

cd "$REPO"

if [ "$WHAT" = all ] || [ "$WHAT" = qemu ]; then
	run qemu sh "$REPO/qa/qemu/build.sh" || :
fi
if [ "$WHAT" = all ] || [ "$WHAT" = android ]; then
	run android sh "$REPO/qa/android/build.sh" || :
fi

if [ "$RC" -eq 0 ]; then
	echo "qa-build: ok ($WHAT)"
else
	echo "qa-build: $WHAT had failures" >&2
fi
exit "$RC"
