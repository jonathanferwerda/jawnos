#!/bin/sh
# Boot the QA Android emulator, install the freshly built APK, drive the app
# through its real flows, and write the numbers the layer is judged on.
# Never touches a real tablet.
#
#   QADOCK=21011 qa/android/run.sh /path/to/app.apk
#
# The AVD is copied to a private directory per run (ANDROID_AVD_HOME), so the
# user's own AVD state is never written, and the emulator is started with
# -no-snapshot so a stale quickboot image cannot pass as the current build.
#
# The app is pointed at the QA instance, not at the live house. The instance is
# fenced (user/PID/net/mount namespaces), so its port is on its own loopback and
# `adb reverse` - which dials the *host's* 127.0.0.1 - cannot see it. With
# QA_INSTANCE=1 this script boots one, and qa/lib/Relay.pm bridges it:
#
#   instance netns: unix <run>/relay/qa-P.sock  ->  https://127.0.0.1:P
#   host:           127.0.0.1:P                  ->  unix <run>/relay/qa-P.sock
#   adb reverse tcp:P tcp:P, then the ticket URL is the login
#
# The helper writes its ports, sockets and ticket to $OUT/handle.json.
#
# The socket is a file, so both namespaces see it; it is deliberately NOT in
# /tmp (the fence makes /tmp private). The host relay binds loopback only, and
# the QA house's own ticket/session still gates the hop. Without QA_INSTANCE=1
# the script behaves exactly as before (QADOCK, or no reverse at all).
#
# What this records, per launch:
#   cold start (am start -W TotalTime), warm start (back/home + relaunch),
#   rotation portrait -> landscape -> portrait, an offline relaunch with the
#   QA reverse removed and airplane mode on, and a repeat-jank pass across
#   three launches. Each launch's gfxinfo jank % is reported separately.
#
# It attaches to the app's WebView devtools socket over CDP and asks what page
# is really loaded (URL, title, DOM node count, whether #start_menu exists).
# No page in the launch state is recorded as an explicit `skip` finding with
# the sockets and activity lines as evidence - never as a pass.
#
# Exit: 0 PASS, 1 FAIL (install, missing device, crash/ANR, budget), 2 setup.
# Cleanup is on EXIT/INT/TERM: forwards removed, emulator SIGKILLed.
#
#   qa/android/webview_probe.js <port>  is the CDP half of the probe.

set -eu

APK=${1:?usage: run.sh <apk> (see qa/README.md)}
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${QA_OUT:-${QA_ROOT:-$HOME/jawnos-qa}/android}
RESULTS=${QA_RESULTS:-$(dirname "$OUT")/results}
SDK=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/android-sdk}}
AVD_NAME=${QA_AVD:-jawnos}
DOCK=${QADOCK:-0}
CDP_PORT=${QA_CDP_PORT:-9223}
# Boot a fenced QA instance and relay it to the emulator. Off by default: the
# nightly and every other l4 run are unchanged unless this is set.
QA_INSTANCE=${QA_INSTANCE:-0}
APP_URL=
INST_PID=
INST_RUN=
INST_WORKING=
INST_DOCK=
INST_SOCK_WORKING=
INST_SOCK_DOCK=
REVERSE_PORTS=
INSIDE_FENCE=0
RELAY_WORKING_PID=
RELAY_DOCK_PID=
APP_PID=
EPID=
SERIAL=
PINNED=

mkdir -p "$OUT" "$RESULTS"
: > "$OUT/android.txt"
: > "$OUT/findings.txt"
RESULT="$OUT/result.txt"
: > "$RESULT"
HANDLE="$OUT/handle.json"
QA_STOP="$OUT/qa-stop"

say() { printf 'qa-android: %s\n' "$*"; }
finding() { # <ok|warn|skip|fail> <area> <text>
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT/findings.txt"
	say "finding[$1/$2] $3"
}
fail() {
	printf 'FAIL %s\n' "$*" >> "$RESULT"
	printf 'qa-android: FAIL - %s\n' "$*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# teardown: only SIGKILL. No graceful stop of anything jawn runs, and never
# scripts/manager_killer.pl - a QA teardown must not be able to reach a tree.
# ---------------------------------------------------------------------------
cleanup() {
	[ -n "$PINNED" ] && return 0
	PINNED=1
	for p in $REVERSE_PORTS; do
		[ -n "$SERIAL" ] && adb -s "$SERIAL" reverse --remove "tcp:$p" >/dev/null 2>&1 || true
	done
	if [ -n "$CDP_PORT" ] && [ -n "$SERIAL" ]; then
		adb -s "$SERIAL" forward --remove "tcp:$CDP_PORT" >/dev/null 2>&1 || true
	fi
	if [ "$DOCK" != "0" ] && [ -n "$SERIAL" ]; then
		adb -s "$SERIAL" reverse --remove "tcp:$DOCK" >/dev/null 2>&1 || true
	fi
	# the host half of the relay first: it must not outlive the bridge
	[ -n "$RELAY_WORKING_PID" ] && kill -9 "$RELAY_WORKING_PID" >/dev/null 2>&1 || true
	[ -n "$RELAY_DOCK_PID" ] && kill -9 "$RELAY_DOCK_PID" >/dev/null 2>&1 || true
	qa_instance_stop
	if [ -n "$SERIAL" ]; then
		adb -s "$SERIAL" emu kill >/dev/null 2>&1 || true
	fi
	if [ -n "$EPID" ]; then
		kill -9 "$EPID" >/dev/null 2>&1 || true
	fi
	return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
if [ ! -x "$SDK/emulator/emulator" ]; then
	say "no emulator under $SDK" >&2
	exit 2
fi
if ! command -v adb >/dev/null 2>&1; then
	say "adb is not on PATH" >&2
	exit 2
fi
if [ ! -f "$DIR/webview_probe.js" ]; then
	say "missing $DIR/webview_probe.js (the CDP probe)" >&2
	exit 2
fi

mem_avail() { free -m | awk '/^Mem:/{print $7}'; }
mem_guard() {
	A=$(mem_avail)
	[ "${A:-0}" -ge 400 ] && return 0
	fail "host memory below 400 MB available ($A MB); stopped instead of squeezing the box"
}

# Own session so a terminal's process-group cleanup does not take the instance
# (or its relay) down mid-run; teardown is still explicit below.
if command -v setsid >/dev/null 2>&1; then
	SETSID=setsid
else
	SETSID=
fi

# ---------------------------------------------------------------------------
# the QA instance and the fence hole
# ---------------------------------------------------------------------------
# handle_get <dotted.path> -> the value from $HANDLE, empty when absent
handle_get() {
	perl -MJSON::PP -e '
		my $key = shift @ARGV;
		my $h = JSON::PP->new->decode(do { local $/; <> });
		for my $k (split /\./, $key) {
			last unless ref($h) eq "HASH" && exists $h->{$k};
			$h = $h->{$k};
		}
		print ref($h) ? "" : (defined $h ? $h : "");
	' "$1" "$HANDLE" 2>/dev/null || true
}

# Spawn the fenced instance now and wait for it later, so its boot overlaps
# the emulator's.
qa_instance_spawn() {
	[ "$QA_INSTANCE" = "1" ] || return 0
	case "$OUT" in
	/tmp/*)
		finding warn instance "QA_OUT is under /tmp, which the fence makes a private tmpfs; not booting a QA instance"
		return 0
		;;
	esac
	if [ ! -f "$DIR/instance.pl" ]; then
		finding warn instance "no $DIR/instance.pl; the app has no QA instance"
		return 0
	fi
	if ! command -v unshare >/dev/null 2>&1; then
		finding warn instance "unshare is not installed; the QA instance would be unfenced, so it was not booted"
		return 0
	fi

	rm -f "$HANDLE" "$QA_STOP"
	say "booting a fenced QA instance (its relay sockets are named in $OUT/handle.json)"
	if [ "${JAWNOS_QA_NS:-}" = "1" ]; then
		# qa/run.pl already fenced this process tree. The instance inherits it,
		# but adb and the emulator are in that netns too, which is not a state
		# this layer was ever able to drive.
		INSIDE_FENCE=1
		finding warn instance "already inside a QA namespace; adb cannot reach the host from here"
		$SETSID perl "$DIR/instance.pl" --out "$OUT" --stop "$QA_STOP" \
			>"$OUT/instance-console.log" 2>&1 </dev/null &
	else
		$SETSID unshare --user --map-root-user --mount --pid --fork --mount-proc --net -- \
			perl "$DIR/instance.pl" --out "$OUT" --stop "$QA_STOP" \
			>"$OUT/instance-console.log" 2>&1 </dev/null &
	fi
	INST_PID=$!
	return 0
}

# Start the host half of the relay: 127.0.0.1:<port> -> <sock>. Loopback only.
relay_start() { # <socket> <port>  (prints the pid)
	$SETSID perl -I"$DIR/../lib" -MRelay -e 'exit Relay::cli(@ARGV)' down \
		--socket "$1" --port "$2" --log "$OUT/relay-$2.log" \
		</dev/null >>"$OUT/relay-$2.console" 2>&1 &
	printf '%s\n' "$!"
}

qa_instance_wait() {
	[ "$QA_INSTANCE" = "1" ] || return 0
	[ -n "$INST_PID" ] || return 0
	say "waiting for the QA instance"
	i=0
	while [ "$i" -lt 180 ]; do
		[ -s "$HANDLE" ] && break
		kill -0 "$INST_PID" 2>/dev/null || break
		mem_guard
		sleep 2
		i=$((i + 1))
	done
	if [ ! -s "$HANDLE" ]; then
		finding warn instance "the QA instance wrote no handle; see $OUT/instance-console.log"
		qa_instance_stop
		return 0
	fi

	INST_RUN=$(handle_get run)
	INST_WORKING=$(handle_get ports.working)
	INST_DOCK=$(handle_get ports.dock)
	INST_SOCK_WORKING=$(handle_get sockets.working)
	INST_SOCK_DOCK=$(handle_get sockets.dock)
	APP_URL=$(handle_get ticket)
	if [ -z "$INST_WORKING" ]; then
		finding warn instance "the handle names no working port; no relay started"
		qa_instance_stop
		return 0
	fi

	if [ "$INSIDE_FENCE" = "1" ]; then
		# The host half would bind the very port the instance already holds in
		# this shared netns. Say why there is no bridge instead.
		finding warn instance "no relay started: the instance's port is on this netns's loopback, and adb cannot reach the host from it"
		[ -z "$APP_URL" ] && finding warn instance "no ticket url ($(handle_get ticket_error | head -c 200))"
		return 0
	fi

	if [ -n "$INST_SOCK_WORKING" ]; then
		RELAY_WORKING_PID=$(relay_start "$INST_SOCK_WORKING" "$INST_WORKING")
	fi
	if [ -n "$INST_SOCK_DOCK" ] && [ -n "$INST_DOCK" ]; then
		RELAY_DOCK_PID=$(relay_start "$INST_SOCK_DOCK" "$INST_DOCK")
	fi
	REVERSE_PORTS="$INST_WORKING $INST_DOCK"
	sleep 1

	if [ -n "$RELAY_WORKING_PID" ] && kill -0 "$RELAY_WORKING_PID" 2>/dev/null; then
		finding ok instance "QA instance on $INST_WORKING/$INST_DOCK; host relay on 127.0.0.1 only; vault=$(handle_get vault) ticket=$([ -n "$APP_URL" ] && echo yes || echo no)"
	else
		finding warn instance "the host relay did not stay up; see $OUT/relay-$INST_WORKING.console"
	fi
	if [ -z "$APP_URL" ]; then
		finding warn instance "no ticket url ($(handle_get ticket_error | head -c 200)); the app falls back to the splash"
	fi
	return 0
}

# SIGKILL the helper and anything still running out of its run root. The helper
# does this itself on the stop file; this is for the case where it did not.
qa_instance_stop() {
	[ -n "$INST_PID" ] || return 0
	: > "$QA_STOP"
	i=0
	while [ "$i" -lt 12 ] && kill -0 "$INST_PID" 2>/dev/null; do
		sleep 1
		i=$((i + 1))
	done
	kill -9 "$INST_PID" >/dev/null 2>&1 || true
	if [ -n "$INST_RUN" ]; then
		for p in /proc/[0-9]*; do
			c=$(readlink "$p/cwd" 2>/dev/null) || continue
			case "$c" in
			"$INST_RUN"/*) kill -9 "${p#/proc/}" >/dev/null 2>&1 || true ;;
			esac
		done
	fi
	INST_PID=
	return 0
}

# Never reuse a serial that is already on the bus: a stale emulator (or, in
# principle, anything else answering to that serial) must not receive the APK.
PORT=
for p in 5580 5582 5584 5586 5588 5590 5592 5594; do
	if ! adb devices 2>/dev/null | grep -q "emulator-$p[[:space:]]"; then
		PORT=$p
		break
	fi
done
[ -n "$PORT" ] || fail "every emulator port 5580-5594 is already in use"
SERIAL="emulator-$PORT"

export ANDROID_AVD_HOME="$OUT/avd"
mkdir -p "$ANDROID_AVD_HOME"
SRC_INI="$HOME/.android/avd/$AVD_NAME.ini"
if [ ! -f "$SRC_INI" ] || [ ! -d "$HOME/.android/avd/$AVD_NAME.avd" ]; then
	say "AVD $AVD_NAME not found under ~/.android/avd" >&2
	exit 2
fi
if [ ! -d "$ANDROID_AVD_HOME/$AVD_NAME.avd" ]; then
	cp -a "$HOME/.android/avd/$AVD_NAME.avd" "$ANDROID_AVD_HOME/"
	sed "s|path=.*|path=$ANDROID_AVD_HOME/$AVD_NAME.avd|" \
		"$SRC_INI" > "$ANDROID_AVD_HOME/$AVD_NAME.ini"
fi

# ---------------------------------------------------------------------------
# package and activity, resolved from the APK, not guessed
# ---------------------------------------------------------------------------
apk_pkg() {
	for a in "$SDK"/build-tools/*/aapt "$SDK"/build-tools/*/aapt2; do
		[ -x "$a" ] || continue
		name=$("$a" dump badging "$APK" 2>/dev/null \
			| awk -F"'" '/^package: name=/{print $2; exit}' || true)
		if [ -n "$name" ]; then
			printf '%s\n' "$name"
			return 0
		fi
	done
	return 1
}
PKG=$(apk_pkg 2>/dev/null || true)
if [ -z "$PKG" ]; then
	PKG=${QA_PKG:-com.jawnos}
	finding warn apk "package not read from the APK (no aapt); assuming $PKG"
fi

# ---------------------------------------------------------------------------
# boot
# ---------------------------------------------------------------------------
mem_guard
# The instance is spawned first so its boot overlaps the emulator's.
qa_instance_spawn
say "starting the emulator on port $PORT"
# -accel auto uses KVM where it exists; on table it does.
"$SDK/emulator/emulator" \
	-avd "$AVD_NAME" \
	-no-window -no-audio -no-boot-anim -no-snapshot \
	-gpu swiftshader_indirect \
	-read-only \
	-port "$PORT" \
	>"$OUT/emulator.log" 2>&1 &
EPID=$!

say "waiting for the emulator"
# A dead emulator must hit this budget, not block here forever.
if ! timeout 240 adb -s "$SERIAL" wait-for-device >/dev/null 2>&1; then
	fail "the emulator never came up on $SERIAL (see $OUT/emulator.log)"
fi
i=0
BOOT=
while [ "$i" -lt 180 ]; do
	BOOT=$(timeout 30 adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
	[ "$BOOT" = "1" ] && break
	i=$((i + 1))
	sleep 2
done
[ "$BOOT" = "1" ] || fail "the emulator did not finish booting in 360 s"
mem_guard

# The reverse is only worth setting up if the relay behind it is listening.
qa_instance_wait

# ---------------------------------------------------------------------------
# install: -s is load-bearing, a real tablet must never receive the QA APK
# ---------------------------------------------------------------------------
say "installing $APK"
INSTALL=$(timeout 300 adb -s "$SERIAL" install -r "$APK" 2>&1 | tr -d '\r' || true)
if ! printf '%s\n' "$INSTALL" | grep -q '^Success'; then
	# A signature clash (a release build of the same package already there)
	# is the one install failure that a clean uninstall may legitimately fix.
	timeout 120 adb -s "$SERIAL" uninstall "$PKG" >/dev/null 2>&1 || true
	INSTALL=$(timeout 300 adb -s "$SERIAL" install -r "$APK" 2>&1 | tr -d '\r' || true)
fi
if ! printf '%s\n' "$INSTALL" | grep -q '^Success'; then
	printf '%s\n' "$INSTALL" >> "$OUT/android.txt"
	fail "adb install failed: $(printf '%s' "$INSTALL" | tail -n 3 | tr '\n' ' ')"
fi

if [ -n "$REVERSE_PORTS" ]; then
	for p in $REVERSE_PORTS; do
		timeout 60 adb -s "$SERIAL" reverse "tcp:$p" "tcp:$p" >/dev/null 2>&1 \
			|| finding warn dock "adb reverse tcp:$p failed; the app cannot reach the QA relay"
	done
elif [ "$DOCK" != "0" ]; then
	timeout 60 adb -s "$SERIAL" reverse "tcp:$DOCK" "tcp:$DOCK" >/dev/null 2>&1 \
		|| finding warn dock "adb reverse tcp:$DOCK failed; the app has no QA instance"
fi

# ---------------------------------------------------------------------------
# measure helpers
# ---------------------------------------------------------------------------
ACT=$(timeout 60 adb -s "$SERIAL" shell cmd package resolve-activity --brief "$PKG" 2>/dev/null \
	| tr -d '\r' | tail -n 1 || true)
[ -n "$ACT" ] || ACT="No activity found"

app_alive() {
	[ -n "$(timeout 30 adb -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true)" ]
}
app_pid() {
	timeout 30 adb -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'
}
resumed() {
	timeout 60 adb -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
		| tr -d '\r' | grep -m1 -E 'mResumedActivity|topResumedActivity' || true
}

# one launch; sets START_MS (empty when the platform did not report one)
START_MS=
start_app() { # <label>
	label=$1
	START_MS=
	if [ -n "$ACT" ] && [ "$ACT" != "No activity found" ]; then
		if [ -n "$APP_URL" ]; then
			# the view takes a URL extra: open the QA house's ticket directly,
			# exactly as a machine in someone's hands would
			out=$(timeout 150 adb -s "$SERIAL" shell am start -W -n "$ACT" \
				--es com.jawnos.app.EXTRA_URL "'$APP_URL'" 2>&1 | tr -d '\r' || true)
		else
			out=$(timeout 150 adb -s "$SERIAL" shell am start -W -n "$ACT" 2>&1 | tr -d '\r' || true)
		fi
	else
		out=$(timeout 150 adb -s "$SERIAL" shell monkey -p "$PKG" \
			-c android.intent.category.LAUNCHER 1 2>&1 | tr -d '\r' || true)
	fi
	printf '%s\n' "$out" > "$OUT/launch-$label.txt"
	START_MS=$(printf '%s\n' "$out" | sed -n 's/^TotalTime: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
	[ -n "$START_MS" ] \
		|| START_MS=$(printf '%s\n' "$out" | sed -n 's/^ThisTime: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
	return 0
}

# gfxinfo only becomes per-launch if the counters are reset first
GFX_RESET=0
gfx_reset() {
	timeout 60 adb -s "$SERIAL" shell dumpsys gfxinfo "$PKG" reset >/dev/null 2>&1 || true
	f=$(timeout 60 adb -s "$SERIAL" shell dumpsys gfxinfo "$PKG" 2>/dev/null \
		| tr -d '\r' | sed -n 's/^Total frames rendered: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
	[ "${f:-1}" = "0" ] && GFX_RESET=1 || GFX_RESET=0
}
jank_pct() {
	timeout 90 adb -s "$SERIAL" shell dumpsys gfxinfo "$PKG" 2>/dev/null \
		| tr -d '\r' | sed -n 's/.*Janky frames: *[0-9][0-9]* *(\([0-9.]*\)%).*/\1/p' | head -n 1
}
pss_kb() {
	timeout 90 adb -s "$SERIAL" shell dumpsys meminfo "$PKG" 2>/dev/null \
		| tr -d '\r' | awk '
			/App Summary/ { inapp = 1 }
			inapp && /^ *TOTAL:/ {
				v = $2; gsub(/[^0-9]/, "", v);
				if (v != "") { print v; exit }
			}
			/TOTAL PSS:/ {
				v = $3; gsub(/[^0-9]/, "", v);
				if (v != "") { print v; exit }
			}
		' | head -n 1
}
kb_to_mb() { awk -v k="${1:-}" 'BEGIN{ if (k == "") print ""; else printf "%.1f", k/1024 }'; }
ms_to_s()  { awk -v m="${1:-}" 'BEGIN{ if (m == "") print ""; else printf "%.1f", m/1000 }'; }
jnum() { case "${1:-}" in ''|*[!0-9.]*) printf 'null';; *) printf '%s' "$1";; esac; }

# air is what makes a relaunch actually offline: loopback survives airplane
# mode, so the QA reverse (when set) is removed for the phase as well.
offline_on() {
	timeout 60 adb -s "$SERIAL" shell cmd connectivity airplane-mode enable >/dev/null 2>&1 \
		|| timeout 60 adb -s "$SERIAL" shell settings put global airplane_mode_on 1 >/dev/null 2>&1 \
		|| true
	timeout 60 adb -s "$SERIAL" shell svc wifi disable >/dev/null 2>&1 || true
	timeout 60 adb -s "$SERIAL" shell svc data disable >/dev/null 2>&1 || true
	for p in $REVERSE_PORTS; do
		timeout 60 adb -s "$SERIAL" reverse --remove "tcp:$p" >/dev/null 2>&1 || true
	done
	if [ "$DOCK" != "0" ]; then
		timeout 60 adb -s "$SERIAL" reverse --remove "tcp:$DOCK" >/dev/null 2>&1 || true
	fi
}
offline_off() {
	timeout 60 adb -s "$SERIAL" shell cmd connectivity airplane-mode disable >/dev/null 2>&1 \
		|| timeout 60 adb -s "$SERIAL" shell settings put global airplane_mode_on 0 >/dev/null 2>&1 \
		|| true
	for p in $REVERSE_PORTS; do
		timeout 60 adb -s "$SERIAL" reverse "tcp:$p" "tcp:$p" >/dev/null 2>&1 || true
	done
	if [ "$DOCK" != "0" ]; then
		timeout 60 adb -s "$SERIAL" reverse "tcp:$DOCK" "tcp:$DOCK" >/dev/null 2>&1 || true
	fi
}
offline_state() {
	timeout 30 adb -s "$SERIAL" shell cmd connectivity airplane-mode 2>/dev/null | tr -d '\r' | head -n 1 \
		|| timeout 30 adb -s "$SERIAL" shell settings get global airplane_mode_on 2>/dev/null | tr -d '\r' | head -n 1 \
		|| true
}

# crashes are read from the crash buffer and the ANR lines, scoped to this
# package - another app's death is not this layer's finding.
CRASH_LINES=
ANR_LINES=
scan_crashes() {
	CRASH_LINES=$(timeout 120 adb -s "$SERIAL" logcat -d -b crash 2>/dev/null \
		| tr -d '\r' | grep -F "$PKG" | head -n 20 || true)
	ANR_LINES=$(timeout 120 adb -s "$SERIAL" logcat -d 2>/dev/null \
		| tr -d '\r' | grep -E "ANR in .*$PKG|Reason: .*$PKG" | head -n 10 || true)
}

# ---------------------------------------------------------------------------
# flow: cold, warm, rotation, offline, third launch
# ---------------------------------------------------------------------------
timeout 60 adb -s "$SERIAL" logcat -c >/dev/null 2>&1 || true

# 1. cold start
mem_guard
timeout 60 adb -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
sleep 1
gfx_reset
start_app cold
COLD_MS=$START_MS
sleep 6
JANK1=$(jank_pct); PSS_KB=$(pss_kb)
app_alive || fail "the app is not running after the cold start"
COLD_ALIVE=1
COLD_PSS_MB=$(kb_to_mb "$PSS_KB")
COLD_JANK=$JANK1
COLD_RESUMED=$(resumed)

# 2. warm start: back to the launcher, then bring the live process forward
mem_guard
timeout 60 adb -s "$SERIAL" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
sleep 2
gfx_reset
start_app warm
WARM_MS=$START_MS
sleep 4
JANK2=$(jank_pct)
WARM_ALIVE=0; app_alive && WARM_ALIVE=1
WARM_PSS_MB=$(kb_to_mb "$(pss_kb)")

# 3. rotation: portrait -> landscape -> portrait
ROT_OK=1
OTHER_ACT=$(timeout 30 adb -s "$SERIAL" shell cmd package resolve-activity --brief "$PKG" 2>/dev/null | tr -d '\r' | tail -n 1 || true)
timeout 60 adb -s "$SERIAL" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
timeout 60 adb -s "$SERIAL" shell settings put system user_rotation 1 >/dev/null 2>&1 || true
sleep 3
app_alive || ROT_OK=0
if [ -n "$OTHER_ACT" ] && [ "$OTHER_ACT" != "No activity found" ]; then
	timeout 60 adb -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
		| tr -d '\r' | grep -qF "$OTHER_ACT" || ROT_OK=0
fi
# a crash or an ANR during the turn is a rotation failure, not a separate one
scan_crashes
[ -z "$CRASH_LINES" ] || ROT_OK=0
timeout 60 adb -s "$SERIAL" shell settings put system user_rotation 0 >/dev/null 2>&1 || true
sleep 3
app_alive || ROT_OK=0
ROT_PSS_MB=$(kb_to_mb "$(pss_kb)")
ROT_JANK=$(jank_pct)

# 4. offline relaunch: airplane mode, the QA reverse gone, cold relaunch
mem_guard
offline_on
AIRPLANE=$(offline_state)
timeout 60 adb -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
sleep 1
gfx_reset
start_app offline
OFFLINE_MS=$START_MS
sleep 8
OFFLINE_ALIVE=0
app_alive && OFFLINE_ALIVE=1
OFFLINE_RESUMED=$(resumed)
JANK3=$(jank_pct); OFFLINE_PSS_MB=$(kb_to_mb "$(pss_kb)")
if [ -n "$OFFLINE_RESUMED" ]; then
	finding ok offline "relaunch kept a resumed activity: $(printf '%s' "$OFFLINE_RESUMED" | cut -c1-200)"
else
	finding warn offline "no resumed activity line after the offline relaunch; pid ${APP_PID:-none}"
fi
scan_crashes
OFFLINE_CRASH=$CRASH_LINES
OFFLINE_ANR=$ANR_LINES
offline_off
timeout 60 adb -s "$SERIAL" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
sleep 1
start_app recover
sleep 4

# ---------------------------------------------------------------------------
# WebView CDP: what page is actually loaded
# ---------------------------------------------------------------------------
CDP_STATUS=error; CDP_PAGE_LOADED=; CDP_NODES=; CDP_MENU=; CDP_URL=; CDP_TITLE=
CDP_CONSOLE=; CDP_EXCEPTIONS=
APP_PID=$(app_pid)
SOCKETS=$(timeout 30 adb -s "$SERIAL" shell cat /proc/net/unix 2>/dev/null \
	| tr -d '\r' | grep -o 'webview_devtools_remote_[0-9][0-9]*' | sort -u | tr '\n' ' ' || true)
EVIDENCE=$(timeout 60 adb -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
	| tr -d '\r' | grep -E 'mResumedActivity|topResumedActivity|mFocusedApp' | head -n 5 || true)
SOCKET_NAME=
CDP_CANDIDATES=
CDP_SAW_SKIP=0
if [ -n "$APP_PID" ]; then
	CDP_CANDIDATES="webview_devtools_remote_$APP_PID"
fi
# /proc/net/unix keeps entries for dead process ids, and a stale socket answers
# /json/list with an empty target list. Try the live pid's socket first, then
# the rest, so a skip means every socket was actually asked.
for s in $SOCKETS; do
	case " $CDP_CANDIDATES " in
	*" $s "*) ;;
	*) CDP_CANDIDATES="$CDP_CANDIDATES $s" ;;
	esac
done
CDP_CANDIDATES=$(printf '%s' "$CDP_CANDIDATES" | sed 's/^ *//; s/  */ /g')
CDP_TRY=
CDP_EVIDENCE=
PROBE=
if [ -z "$CDP_CANDIDATES" ]; then
	finding skip cdp "no WebView devtools socket and no app pid; activity=[$EVIDENCE]"
else
	for SOCKET_NAME in $CDP_CANDIDATES; do
		CDP_TRY="$CDP_TRY $SOCKET_NAME"
		timeout 60 adb -s "$SERIAL" forward --remove "tcp:$CDP_PORT" >/dev/null 2>&1 || true
		if ! timeout 60 adb -s "$SERIAL" forward "tcp:$CDP_PORT" "localabstract:$SOCKET_NAME" >/dev/null 2>&1; then
			CDP_EVIDENCE="$CDP_EVIDENCE forward($SOCKET_NAME)=failed"
			CDP_STATUS=error
			continue
		fi
		PROBE=$(timeout 90 node "$DIR/webview_probe.js" "$CDP_PORT" 1500 2>&1 || true)
		printf '%s\n' "$PROBE" > "$OUT/cdp-$SOCKET_NAME.json"
		CDP_STATUS=$(printf '%s' "$PROBE" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -n 1)
		case "$CDP_STATUS" in
		ok) break ;;
		skip)
			CDP_SAW_SKIP=1
			REASON=$(printf '%s' "$PROBE" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -n 1)
			CDP_EVIDENCE="$CDP_EVIDENCE skip($SOCKET_NAME)=${REASON:-no reason}"
			;;
		*)
			REASON=$(printf '%s' "$PROBE" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -n 1)
			CDP_EVIDENCE="$CDP_EVIDENCE error($SOCKET_NAME)=${REASON:-unparseable}"
			;;
		esac
	done
	case "$CDP_STATUS" in
	ok)
		printf '%s\n' "$PROBE" > "$OUT/cdp.json"
		CDP_PAGE_LOADED=$(printf '%s' "$PROBE" | sed -n 's/.*"page_loaded":\(true\|false\).*/\1/p' | head -n 1)
		[ "$CDP_PAGE_LOADED" = "true" ] && CDP_PAGE_LOADED=1 || CDP_PAGE_LOADED=0
		CDP_NODES=$(printf '%s' "$PROBE" | sed -n 's/.*"nodes":\([0-9][0-9]*\).*/\1/p' | head -n 1)
		CDP_MENU=$(printf '%s' "$PROBE" | sed -n 's/.*"start_menu":{"found":\(true\|false\).*/\1/p' | head -n 1)
		[ "$CDP_MENU" = "true" ] && CDP_MENU=1 || CDP_MENU=0
		CDP_URL=$(printf '%s' "$PROBE" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p' | head -n 1)
		CDP_TITLE=$(printf '%s' "$PROBE" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p' | head -n 1)
		CDP_CONSOLE=$(printf '%s' "$PROBE" | sed -n 's/.*"console_errors":\[\([^]]*\)\].*/\1/p' | head -n 1 | cut -c1-400)
		CDP_EXCEPTIONS=$(printf '%s' "$PROBE" | sed -n 's/.*"exceptions":\[\([^]]*\)\].*/\1/p' | head -n 1 | cut -c1-400)
		if [ "$CDP_PAGE_LOADED" = "1" ]; then
			finding ok cdp "page loaded socket=$SOCKET_NAME url=$CDP_URL title=$CDP_TITLE nodes=${CDP_NODES:-?} start_menu=${CDP_MENU:-?} console_errors=[$CDP_CONSOLE] exceptions=[$CDP_EXCEPTIONS]"
		else
			# A splash asset or about:blank is not a page: nothing was exercised,
			# so this is a skip with its evidence, never a pass.
			CDP_STATUS=skip
			finding skip cdp "attached to $SOCKET_NAME but no page is loaded (url=$CDP_URL title=$CDP_TITLE nodes=${CDP_NODES:-?}); pid=${APP_PID:-none} activity=[$EVIDENCE]"
		fi
		;;
	*)
		if [ "$CDP_SAW_SKIP" = "1" ]; then
			CDP_STATUS=skip
			finding skip cdp "no WebView page in the launch state (tried:$CDP_TRY |$CDP_EVIDENCE); pid=${APP_PID:-none} activity=[$EVIDENCE]"
		else
			finding warn cdp "CDP could not be probed (tried:$CDP_TRY |$CDP_EVIDENCE); sockets=[$SOCKETS]"
		fi
		;;
	esac
fi

# ---------------------------------------------------------------------------
# crash / ANR verdict for the whole run
# ---------------------------------------------------------------------------
scan_crashes
if [ -n "$OFFLINE_CRASH" ]; then
	CRASH_LINES=$(printf '%s\n%s\n' "$CRASH_LINES" "$OFFLINE_CRASH" | grep -v '^$' | head -n 20 | sort -u)
fi
if [ -n "$OFFLINE_ANR" ]; then
	ANR_LINES=$(printf '%s\n%s\n' "$ANR_LINES" "$OFFLINE_ANR" | grep -v '^$' | head -n 10 | sort -u)
fi
CRASH=0; ANR=0
[ -n "$CRASH_LINES" ] && CRASH=1
[ -n "$ANR_LINES" ] && ANR=1

# The reset is issued while the app is stopped, so a readback of zero is not
# always possible; say so rather than letting three "per-launch" figures be
# read as independent when they may be cumulative.
if [ "$GFX_RESET" != "1" ]; then
	finding warn gfxinfo "gfxinfo reset was not confirmed; the per-launch jank figures may be cumulative"
fi

# ---------------------------------------------------------------------------
# metrics file the budget reads
# ---------------------------------------------------------------------------
DEVJSON="$RESULTS/device.json"
{
	printf '{\n'
	printf '  "l4.install_ok": 1,\n'
	printf '  "l4.cold_start_s": %s,\n' "$(jnum "$(ms_to_s "$COLD_MS")")"
	printf '  "l4.warm_start_s": %s,\n' "$(jnum "$(ms_to_s "$WARM_MS")")"
	printf '  "l4.pss_mb": %s,\n' "$(jnum "${COLD_PSS_MB:-}")"
	printf '  "l4.jank_pct": %s,\n' "$(jnum "${JANK3:-${JANK2:-${JANK1:-}}}")"
	printf '  "l4.jank_pct_run1": %s,\n' "$(jnum "$JANK1")"
	printf '  "l4.jank_pct_run2": %s,\n' "$(jnum "$JANK2")"
	printf '  "l4.jank_pct_run3": %s,\n' "$(jnum "$JANK3")"
	printf '  "l4.rotation_ok": %s,\n' "$ROT_OK"
	printf '  "l4.rotation_pss_mb": %s,\n' "$(jnum "${ROT_PSS_MB:-}")"
		printf '  "l4.rotation_jank_pct": %s,\n' "$(jnum "$ROT_JANK")"
	printf '  "l4.offline_ok": %s,\n' "$OFFLINE_ALIVE"
	printf '  "l4.offline_start_s": %s,\n' "$(jnum "$(ms_to_s "$OFFLINE_MS")")"
	printf '  "l4.crash": %s,\n' "$CRASH"
	printf '  "l4.anr": %s,\n' "$ANR"
	printf '  "l4.gfxinfo_reset": %s,\n' "$GFX_RESET"
	printf '  "l4.cdp_page_loaded": %s,\n' "$(jnum "$CDP_PAGE_LOADED")"
	printf '  "l4.cdp_nodes": %s,\n' "$(jnum "$CDP_NODES")"
	printf '  "l4.cdp_start_menu": %s,\n' "$(jnum "$CDP_MENU")"
	printf '  "l4.qa_instance": %s\n' "$([ -n "$INST_WORKING" ] && echo 1 || echo 0)"
	printf '}\n'
} > "$DEVJSON"

# ---------------------------------------------------------------------------
# android.txt: the human record
# ---------------------------------------------------------------------------
{
	echo "apk $APK"
	echo "avd $AVD_NAME"
	echo "serial $SERIAL"
	echo "qa_instance $QA_INSTANCE working=${INST_WORKING:-none} dock=${INST_DOCK:-none} vault=$(handle_get vault) ticket=$([ -n "$APP_URL" ] && echo yes || echo no)"
	echo "package $PKG"
	echo "activity $ACT"
	echo "sdk $(timeout 30 adb -s "$SERIAL" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
	echo "cold_start_s $(ms_to_s "$COLD_MS") warm_start_s $(ms_to_s "$WARM_MS")"
	echo "pss_mb ${COLD_PSS_MB:-none} jank_pct ${JANK3:-none} (run1 ${JANK1:-none} run2 ${JANK2:-none} run3 ${JANK3:-none})"
	echo "rotation_ok $ROT_OK (pss ${ROT_PSS_MB:-none} jank ${ROT_JANK:-none}) offline_ok $OFFLINE_ALIVE crash $CRASH anr $ANR airplane [$AIRPLANE]"
	echo "cold_resumed $(printf '%s' "$COLD_RESUMED" | cut -c1-200)"
	echo "cdp status=$CDP_STATUS page_loaded=$CDP_PAGE_LOADED url=$CDP_URL nodes=$CDP_NODES start_menu=$CDP_MENU"
	echo '--- am start (cold) ---'
	cat "$OUT/launch-cold.txt" 2>/dev/null || true
	echo '--- am start (warm) ---'
	cat "$OUT/launch-warm.txt" 2>/dev/null || true
	echo '--- am start (offline) ---'
	cat "$OUT/launch-offline.txt" 2>/dev/null || true
	echo '--- meminfo (PSS) ---'
	timeout 90 adb -s "$SERIAL" shell dumpsys meminfo "$PKG" 2>/dev/null | sed -n '1,40p' || true
	echo '--- gfxinfo ---'
	timeout 90 adb -s "$SERIAL" shell dumpsys gfxinfo "$PKG" 2>/dev/null | sed -n '1,30p' || true
	echo '--- top ---'
	timeout 60 adb -s "$SERIAL" shell top -b -n 1 -o %CPU,RSS,ARGS 2>/dev/null \
		| { head -n 1; grep -F "$PKG"; } | head -n 6 || true
	echo '--- findings ---'
	cat "$OUT/findings.txt"
} >> "$OUT/android.txt" 2>&1

# ---------------------------------------------------------------------------
# budget
# ---------------------------------------------------------------------------
BUDGET_RC=0
BUDGET_OUT=
if [ -f "$DIR/../budget.pl" ]; then
	set +e
	BUDGET_OUT=$(perl "$DIR/../budget.pl" "$DEVJSON" 2>&1)
	BUDGET_RC=$?
	set -e
	printf '%s\n' "$BUDGET_OUT" | tee "$RESULTS/budget.txt"
else
	finding warn budget "no budget.pl at $DIR/../budget.pl; the numbers were not judged"
fi

# ---------------------------------------------------------------------------
# verdict
# ---------------------------------------------------------------------------
if [ "$CRASH" = "1" ]; then
	printf '%s\n' "$CRASH_LINES" >> "$OUT/android.txt"
	fail "the app crashed (FATAL EXCEPTION in the crash buffer): $(printf '%s' "$CRASH_LINES" | head -n 2 | tr '\n' ' ')"
fi
if [ "$ANR" = "1" ]; then
	printf '%s\n' "$ANR_LINES" >> "$OUT/android.txt"
	fail "the app was not responding (ANR): $(printf '%s' "$ANR_LINES" | head -n 2 | tr '\n' ' ')"
fi
if [ "$ROT_OK" != "1" ]; then
	fail "rotation broke the app (alive/crash/resumed check failed)"
fi
if [ "$QA_INSTANCE" = "1" ] && [ -n "$APP_URL" ] && [ "$CDP_PAGE_LOADED" != "1" ]; then
	# A relay, a ticket and an emulator were all asked for; sitting on the
	# splash means the path is not proven, so this is the honest blocker and
	# not a pass. The evidence is the probe JSON and the logcat crash buffer.
	fail "the WebView never loaded the QA manager (url=${CDP_URL:-none} nodes=${CDP_NODES:-none} start_menu=${CDP_MENU:-?}); see $OUT/cdp.json and $OUT/cdp-*.json"
fi
if [ "$OFFLINE_ALIVE" != "1" ]; then
	fail "the app did not survive an offline relaunch"
fi
if [ "$BUDGET_RC" -ne 0 ]; then
	fail "the budget check did not pass (exit $BUDGET_RC; see $RESULTS/budget.txt)"
fi

printf 'PASS cold=%ss warm=%ss pss=%sMB jank=%s%% (run1 %s run2 %s run3 %s) cdp=%s rotation=%s offline=%s\n' \
	"$(ms_to_s "$COLD_MS")" "$(ms_to_s "$WARM_MS")" "${COLD_PSS_MB:-?}" "${JANK3:-?}" \
	"${JANK1:-?}" "${JANK2:-?}" "${JANK3:-?}" "$CDP_STATUS" "$ROT_OK" "$OFFLINE_ALIVE"
printf 'PASS\n' >> "$RESULT"
say "metrics $DEVJSON"
say "record $OUT/android.txt"
exit 0
