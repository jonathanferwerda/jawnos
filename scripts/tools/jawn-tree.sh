#!/bin/sh
# List JawnOS processes with parent, age, CPU ticks and PURPOSE.
#
# Answers: "what is the process tree right now, and which worker is hot?"
# Usage: jawn-tree.sh [PATTERN] [LOG_PATH]
# Example: jawn-tree.sh 'President\.pl'
# Read-only: reads /proc and tails the log.

PAT=${1:-'President\.pl|Manager\.pl|Websocket\.pl|/jawn'}
LOG=${2:-"$HOME/manager.log"}

echo "=== matching processes (pattern=$PAT)"
for dir in /proc/[0-9]*; do
	p=${dir#/proc/}
	[ -r "$dir/cmdline" ] || continue
	args=$(tr '\0' ' ' < "$dir/cmdline" 2>/dev/null)
	printf '%s' "$args" | grep -Eq "$PAT" || continue
	ppid=$(cut -d' ' -f4 "$dir/stat" 2>/dev/null)
	utime=$(cut -d' ' -f14 "$dir/stat" 2>/dev/null)
	stime=$(cut -d' ' -f15 "$dir/stat" 2>/dev/null)
	etime=$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')
	purpose=$(tr '\0' '\n' < "$dir/environ" 2>/dev/null | sed -n 's/^PURPOSE=//p' | head -1)
	echo "$p ppid=$ppid etime=${etime:-?} ticks=$utime/$stime PURPOSE=${purpose:-?} :: $(echo "$args" | cut -c1-70)"
done

echo "=== current top"
if ps -eo pid,pcpu,args --sort=-pcpu >/dev/null 2>&1; then
	ps -eo pid,pcpu,args --sort=-pcpu 2>/dev/null | head -10
elif ps -A -o pid,pcpu,args >/dev/null 2>&1; then
	ps -A -o pid,pcpu,args 2>/dev/null | sort -k2 -nr | head -10
else
	top -b -n 1 -m 10 2>/dev/null | tail -11
fi

echo "=== log tail (errors/workers)"
grep -aE "no heartbeat|worker spawn|worker mem|error" "$LOG" 2>/dev/null | tail -20 | cut -c1-170
