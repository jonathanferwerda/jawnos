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
STEP_TSV="$LOGS/$STAMP-steps.tsv"
RAN=0
SDK_DOWNLOAD=0
printf 'Step\tResult\tTime\tLog\n' > "$STEP_TSV"
RC=0

run() {
	name=$1
	shift
	log="$LOGS/$STAMP-$name.log"
	echo "$name: $log"
	RAN=$((RAN + 1))
	started=$(date +%s)
	state=ok
	if ! "$@" > "$log" 2>&1; then
		echo "qa-build: $name failed; tail of $log:" >&2
		tail -20 "$log" >&2
		RC=1
		state=failed
	fi
	seconds=$(( $(date +%s) - started ))
	printf '%s\t%s\t%dm %02ds\t%s\n' "$name" "$state" \
		"$((seconds / 60))" "$((seconds % 60))" "${log##*/}" >> "$STEP_TSV"
	[ "$state" = ok ]
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
	# A clean build. An incremental run where every task is UP-TO-DATE (which is
	# what this produced before) says nothing about the JDK, AGP, NDK or
	# build-tools that are installed, and catching drift in those is the point.
	CLEAN=1
	export CLEAN
	if run android sh "$REPO/qa/android/build.sh"; then
		# The build had to fetch an SDK component. The freshness check keeps
		# or installs what the build needs, so this means the two disagree --
		# exactly the drift this unit exists to catch (AGP wanted
		# build-tools 34.0.0 while the freshest ones were kept).
		ANDROID_LOG="$LOGS/$STAMP-android.log"
		if grep -q 'Installing Android SDK' "$ANDROID_LOG" 2>/dev/null; then
			echo "qa-build: the Android build had to download an SDK component:" >&2
			grep 'Installing Android SDK' "$ANDROID_LOG" | sed 's/^/  /' >&2
			SDK_DOWNLOAD=1
			RC=1
		fi
	fi
	unset CLEAN
fi

if [ "$RC" -eq 0 ]; then
	echo "qa-build: ok ($WHAT)"
else
	echo "qa-build: $WHAT had failures" >&2
fi

# The panel's report: one row per step, with the time it took, so a weekly run
# that quietly stopped compiling is visible as the step it was. The cadence is
# stamped on it, which is how the accordion says this one was the weekly.
STATUS=ok
if [ "$RC" -ne 0 ]; then STATUS=failed; fi
NOTE="$RAN step(s)"
# `set -e` aborts on a false test in an && list, so these stay if statements.
if [ "$SDK_DOWNLOAD" -eq 1 ]; then NOTE="the Android build downloaded an SDK component"; fi
perl "$REPO/scripts/qa_report.pl" --kind=build --schedule=weekly --status "$STATUS" \
	--title 'Weekly build' --note "$NOTE" --stamp "$STAMP" \
	--table "Steps:$STEP_TSV" --root "$QA_ROOT" > /dev/null 2>&1 \
	|| echo "qa-build: could not write the report" >&2

exit "$RC"
