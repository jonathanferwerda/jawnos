#!/bin/sh
# Android battery/power/CPU sampler over adb.
#
# Answers: "is the phone awake, hot, charging, and who is using the CPU?"
# Usage: android-battery-log.sh [SERIAL] [COUNT] [INTERVAL]
# Example: android-battery-log.sh R58M123ABC 40 15
#
# Read-only: dumpsys, settings get and ps only. Requires adb on PATH; the
# phone must already be authorised for this machine.

SERIAL=${1:-}
COUNT=${2:-160}
INTERVAL=${3:-15}
ADB=${ADB:-adb}

command -v "$ADB" >/dev/null 2>&1 || { echo "adb not found: $ADB" >&2; exit 1; }

adb_() {
	if [ -n "$SERIAL" ]; then
		"$ADB" -s "$SERIAL" "$@"
	else
		"$ADB" "$@"
	fi
}

i=0
while [ "$i" -lt "$COUNT" ]; do
	echo "=== T $(date +%s) $(date +%H:%M:%S)"

	adb_ shell "dumpsys battery | head -16 | grep -E 'level:|status:|temperature:|charge counter:|current'" 2>/dev/null
	adb_ shell "settings get global stay_on_while_plugged_in; settings get system screen_off_timeout" 2>/dev/null | tr '\n' ' '
	echo
	adb_ shell "dumpsys power | grep -E 'mWakefulness=|mStayOn=|mScreenOffTimeout=' | head -3" 2>/dev/null
	adb_ shell "dumpsys activity activities 2>/dev/null | grep -m1 -E 'topResumedActivity|mResumedActivity'" 2>/dev/null
	adb_ shell "ps -A -o pid,pcpu,rss,args | grep -E 'com.jawnos|libbin_perl|surfaceflinger|system_server' | grep -v grep | sort -k2 -nr | head -7" 2>/dev/null
	echo

	i=$((i + 1))
	[ "$i" -lt "$COUNT" ] && sleep "$INTERVAL"
done
