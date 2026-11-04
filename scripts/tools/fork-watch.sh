#!/bin/sh
# Count short-lived process spawns and log growth: a fork/flap storm.
#
# Answers: "is something spawning jawn-bt / helpers in a tight loop?"
# It samples /proc once a second and prints each distinct pid+command seen,
# then measures how fast the manager log grows.
#
# Usage: fork-watch.sh [PATTERN] [SECONDS] [LOG_PATH]
# Example: fork-watch.sh 'jawn-bt' 20 ~/manager.log
# Read-only: reads /proc and the log size.

PAT=${1:-'jawn-bt|termux-api|jawn-'}
SECS=${2:-20}
LOG=${3:-"$HOME/manager.log"}

echo "=== distinct spawns in ${SECS}s (pattern=$PAT)"
i=0
while [ "$i" -lt "$SECS" ]; do
	for dir in /proc/[0-9]*; do
		p=${dir#/proc/}
		[ -r "$dir/cmdline" ] || continue
		args=$(tr '\0' ' ' < "$dir/cmdline" 2>/dev/null)
		printf '%s' "$args" | grep -Eq "$PAT" || continue
		echo "$p $args"
	done
	i=$((i + 1))
	sleep 1
done | sort -u

echo "=== log growth"
if [ -r "$LOG" ]; then
	a=$(wc -c < "$LOG")
	sleep 10
	b=$(wc -c < "$LOG")
	echo "$LOG grew $((b - a)) bytes in 10s"
	tail -c 4000 "$LOG" | tr ',' '\n' | grep -c '"event"' || true
else
	echo "log not readable: $LOG" >&2
fi
