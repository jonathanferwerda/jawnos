#!/bin/sh
# Boot the QA Android emulator, install the freshly built APK, and record the
# numbers the app layer is judged on. Never touches a real tablet.
#
#   QADOCK=21011 QAWORKING=21000 qa/android/run.sh /path/to/app.apk
#
# The AVD is copied to a private directory per run (ANDROID_AVD_HOME), so the
# user's own AVD state is never written, and the emulator is started with
# -no-snapshot so a stale quickboot image cannot pass as the current build.
#
# The app is pointed at the QA instance, not at the live house:
#   adb reverse tcp:$QADOCK tcp:$QADOCK
# and the ticket in $QA_TICKET (minted by the run) is the login.
#
# Output: $QA_OUT android.txt, with the start time, PSS, jank and a few props.

set -eu

APK=${1:?usage: run.sh <apk> (see qa/README.md)}
OUT=${QA_OUT:-${QA_ROOT:-$HOME/jawnos-qa}/android}
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/android-sdk}}
AVD_NAME=${QA_AVD:-jawnos}
DOCK=${QADOCK:-0}

if [ ! -x "$SDK/emulator/emulator" ]; then
	echo "qa-android: no emulator under $SDK" >&2
	exit 2
fi
if ! command -v adb >/dev/null 2>&1; then
	echo "qa-android: adb is not on PATH" >&2
	exit 2
fi

mkdir -p "$OUT"
SERIAL=emulator-5580
export ANDROID_AVD_HOME="$OUT/avd"
mkdir -p "$ANDROID_AVD_HOME"

# copy the AVD definition and disk so the run is disposable
SRC_INI="$HOME/.android/avd/$AVD_NAME.ini"
if [ ! -f "$SRC_INI" ] || [ ! -d "$HOME/.android/avd/$AVD_NAME.avd" ]; then
	echo "qa-android: AVD $AVD_NAME not found under ~/.android/avd" >&2
	exit 2
fi
if [ ! -d "$ANDROID_AVD_HOME/$AVD_NAME.avd" ]; then
	cp -a "$HOME/.android/avd/$AVD_NAME.avd" "$ANDROID_AVD_HOME/"
	sed "s|path=.*|path=$ANDROID_AVD_HOME/$AVD_NAME.avd|" \
		"$SRC_INI" > "$ANDROID_AVD_HOME/$AVD_NAME.ini"
fi

# -accel auto uses KVM where it exists; on table it does.
"$SDK/emulator/emulator" \
	-avd "$AVD_NAME" \
	-no-window -no-audio -no-boot-anim -no-snapshot \
	-gpu swiftshader_indirect \
	-read-only \
	-port 5580 \
	>"$OUT/emulator.log" 2>&1 &
EPID=$!
cleanup() {
	adb -s "$SERIAL" emu kill >/dev/null 2>&1 || true
	kill "$EPID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "waiting for the emulator"
adb -s "$SERIAL" wait-for-device
i=0
while [ "$i" -lt 180 ]; do
	BOOT=$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
	[ "$BOOT" = "1" ] && break
	i=$((i + 1))
	sleep 2
done
if [ "$BOOT" != "1" ]; then
	echo "qa-android: the emulator did not finish booting" >&2
	exit 1
fi

adb -s "$SERIAL" install -r "$APK" >/dev/null
PKG=${QA_PKG:-com.termux}

if [ "$DOCK" != "0" ]; then
	adb -s "$SERIAL" reverse "tcp:$DOCK" "tcp:$DOCK" >/dev/null
fi

{
	echo "apk $APK"
	echo "avd $AVD_NAME"
	echo "package $PKG"
	# cold start
	adb -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
	adb -s "$SERIAL" shell am start -W -n "$PKG/.app.TermuxActivity" 2>&1 || true
	sleep 5
	echo '--- meminfo (PSS) ---'
	adb -s "$SERIAL" shell dumpsys meminfo "$PKG" 2>/dev/null | sed -n '1,20p'
	echo '--- gfxinfo ---'
	adb -s "$SERIAL" shell dumpsys gfxinfo "$PKG" 2>/dev/null | sed -n '1,25p'
	echo '--- top ---'
	adb -s "$SERIAL" shell top -b -n 1 -o %CPU,RSS,ARGS 2>/dev/null | head -n 15
} > "$OUT/android.txt" 2>&1

echo "$OUT/android.txt"
