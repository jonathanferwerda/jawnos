#!/usr/bin/env bash
# Nightly installer freshness check. TESTING ONLY, METADATA ONLY.
#
# It asks the three repositories the installers use whether they still offer
# what the installers ask for, and how far an installed copy is behind the
# candidate:
#   CPAN   fastapi.metacpan.org  (every module in scripts/jawnos_deps.pl)
#   Debian api.ftp-master.debian.org madison (the apt package names)
#   Arch   archlinux.org package API (the pacman package names)
#   Android dl.google.com/android/repository/repository2-3.xml (the SDK/NDK
#          components this machine has, plus platform-tools and cmdline-tools)
#
# It downloads NO package, tarball or distribution, runs no `apt-get update`
# or `pacman -Sy`, needs no sudo and does not touch the live tree, database or
# ports. The whole check is a few kilobytes per name, which is what makes it
# safe to run nightly against hosts that pay for their own bandwidth.
#
# A missing upstream name is a FAIL. A package that is merely behind its
# candidate is reported, and fails only with STRICT=1 (the image deliberately
# pins older Mojo/Sereal/CryptX, so the nightly does not gate on that).
#
# The Android toolchain is the one thing this job installs: a newer build-tools
# or NDK than the SDK here has is fetched with the SDK's own sdkmanager
# (ANDROID_UPDATE=1, the default; set 0 to report only). That is tens of MB for
# build-tools and hundreds of MB for an NDK, once -- afterwards it is current.
# A newer NDK is staged, not adopted: the build keeps using the app's
# ndkVersion pin until that pin moves. cmdline-tools is reported, never
# installed, because it is the sdkmanager doing the installing.
#
# A checkout without curl, or a network where no repository answers, is a
# SKIP. A repository host that answers the probe but not the queries is a FAIL
# naming it, because "we can no longer see the module" is exactly the signal
# this job exists for.
#
# Runs are logged under $QA_ROOT/installers/<stamp>/freshness.log; the last 14
# are kept. Driven by qa/systemd/jawnos-qa-installers.timer (03:45, nightly).
#
# Each run also leaves `report.json` (the same document --json prints) and a
# one-word `status.txt` beside the log. Those two files are what Configure ->
# Plat -> QA shows, so the panel reads a finished run instead of re-running the
# check; a report is kept for 14 days.
#
# It checks the committed tree (git archive HEAD), like the Docker smoke, so a
# half-edited installer list is not judged. QA_SOURCE=worktree checks the
# working tree instead, for a manual run before committing.

set -euo pipefail

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
QA_ROOT=${QA_ROOT:-$HOME/jawnos-qa}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$QA_ROOT/installers/$STAMP"
TREE="$RUN_DIR/tree"
LOG="$RUN_DIR/freshness.log"
KEEP_DAYS=14
MAX_RUNS=60
STRICT=${STRICT:-0}
ANDROID_UPDATE=${ANDROID_UPDATE:-1}
QA_SOURCE=${QA_SOURCE:-head}

note() { printf '%s\n' "$*"; }

# What the panel shows for a run that never got as far as writing a report.
set_status() {
	printf '%s\n' "$1" > "$RUN_DIR/status.txt" 2>/dev/null || :
}

# One metadata request per repository: the same size as one row of the report.
probe() {
	local name=$1 url=$2 code attempt
	for attempt in 1 2; do
		code=$(curl -sS -o /dev/null -w '%{http_code}' \
			--connect-timeout 5 --max-time 12 "$url" 2>/dev/null || echo 000)
		case "$code" in
			2*|3*) return 0 ;;
			404|410) return 0 ;;   # reachable, and says "not here" honestly
		esac
		sleep 3
	done
	note "probe: $name answered HTTP $code"
	return 1
}

main() {
	if ! command -v curl >/dev/null 2>&1; then
		note "SKIP: curl is not installed; freshness needs it to read package metadata"
		set_status skipped
		return 0
	fi

	if ! probe metacpan 'https://fastapi.metacpan.org/v1/module/Mojolicious::Lite' \
		&& ! probe debian 'https://api.ftp-master.debian.org/madison?package=cpanminus&table=all' \
		&& ! probe arch 'https://archlinux.org/packages/search/json/?name=cpanminus'; then
		note "SKIP: no package repository is reachable from here"
		set_status skipped
		return 0
	fi

	# Read the committed tree, like the Docker smoke: half-edited installer
	# lists are not what a nightly should judge.
	mkdir -p "$TREE"
	if [ "$QA_SOURCE" = worktree ]; then
		tar -C "$REPO" --exclude=.git --exclude=.shots --exclude=releases \
			--exclude=database --exclude='*.pio' -cf - . | tar -x -C "$TREE"
	else
		git -C "$REPO" archive HEAD | tar -x -C "$TREE"
	fi

	note "installer freshness: $(git -C "$REPO" rev-parse --short HEAD) ($(cat "$REPO/VERSION" 2>/dev/null || echo v?))"

	local args=(--freshness --desktop --android --report-file "$RUN_DIR/report.json")
	[ "$STRICT" = 1 ] && args+=(--strict)
	[ "$ANDROID_UPDATE" = 1 ] && args+=(--android-update)
	if ! perl "$TREE/scripts/jawnos_deps.pl" "${args[@]}"; then
		note "FAIL: an installer's package is gone upstream, or every lookup failed"
		set_status failed
		return 1
	fi
	set_status ok
	note "PASS: every installer package is still offered upstream"
	[ "$STRICT" = 1 ] || note "PASS is not a freshness verdict: outdated rows are informational here (STRICT=1 fails them)"
	return 0
}

cleanup() {
	local rc=$?
	trap - EXIT
	set +e
	rm -rf "$TREE"
	# Keep 14 days of reports (the panel shows them) and, defensively, no more
	# than $MAX_RUNS extras if something ran far more often than nightly.
	find "$QA_ROOT/installers" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" \
		-exec rm -rf {} + 2>/dev/null || :
	ls -1dt "$QA_ROOT"/installers/*/ 2>/dev/null \
		| awk -v keep="$MAX_RUNS" 'NR > keep' \
		| while IFS= read -r old; do rm -rf "$old"; done
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$QA_ROOT/installers"
exec 9>"$QA_ROOT/installers/.lock"
if ! flock -n 9; then
	echo "installer freshness: another run holds the lock; skipping" >&2
	exit 0
fi

mkdir -p "$RUN_DIR"

# main runs in this shell (no pipeline), so the EXIT trap still sees $TREE.
rc=0
main >"$LOG" 2>&1 || rc=$?
cat "$LOG"
exit "$rc"
