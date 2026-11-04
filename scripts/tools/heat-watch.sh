#!/bin/sh
# Phone heat and battery sampler: temperature, charge, and the hottest worker.
#
# Answers: "is the device hot, charging or draining, and which JawnOS purpose
#           is burning CPU at that moment?"
# Usage: heat-watch.sh [--interval S] [--count N] [--log FILE]
# Example: heat-watch.sh --interval 60 --count 10
#
# Read-only by default: one line per sample on stdout.
# WRITES: --log FILE appends one line per sample to FILE.
# Needs termux-battery-status (Android/Termux); elsewhere temp/pct/cur show "?".

INTERVAL=300
COUNT=0
LOG=''
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DB=${JAWNOS_DB:-"$ROOT/database/jawnos.db"}

while [ $# -gt 0 ]; do
	case "$1" in
		--interval) INTERVAL=$2; shift 2 ;;
		--count) COUNT=$2; shift 2 ;;
		--log) LOG=$2; shift 2 ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

emit() {
	if [ -n "$LOG" ]; then
		cat >> "$LOG"
	else
		cat
	fi
}

i=0
while :; do
	ts=$(date '+%Y-%m-%d %H:%M:%S')

	bat=$(termux-battery-status 2>/dev/null | tr -d '\n')
	temp=$(printf '%s' "$bat" | sed -n 's/.*"temperature": *\([0-9.]*\).*/\1/p')
	pct=$(printf '%s' "$bat" | sed -n 's/.*"percentage": *\([0-9]*\).*/\1/p')
	cur=$(printf '%s' "$bat" | sed -n 's/.*"current": *\(-\{0,1\}[0-9]*\).*/\1/p')

	if ps -eo pid,pcpu,args --sort=-pcpu >/dev/null 2>&1; then
		top=$(ps -eo pid,pcpu,args --sort=-pcpu 2>/dev/null | grep -E 'President\.pl|Manager\.pl|Websocket\.pl|/jawn ' | head -1)
	elif ps -A -o pid,pcpu,args >/dev/null 2>&1; then
		top=$(ps -A -o pid,pcpu,args 2>/dev/null | grep -E 'President\.pl|Manager\.pl|Websocket\.pl|/jawn ' | sort -k2 -nr | head -1)
	else
		top=$(top -b -n 1 -m 10 2>/dev/null | grep -E 'President\.pl|Manager\.pl|Websocket\.pl|/jawn ' | head -1)
	fi
	tpid=$(printf '%s' "$top" | awk '{print $1}')
	tcpu=$(printf '%s' "$top" | awk '{print $2}')
	purpose=$(tr '\0' '\n' < "/proc/$tpid/environ" 2>/dev/null | sed -n 's/^PURPOSE=//p' | head -1)
	job=$(sqlite3 -readonly "$DB" "select note from sync_jobs order by cast(updated as integer) desc limit 1;" 2>/dev/null)

	printf '%s temp=%s pct=%s cur=%s top_pid=%s top_cpu=%s purpose=%s job=%s\n' \
		"$ts" "${temp:-?}" "${pct:-?}" "${cur:-?}" "${tpid:-?}" "${tcpu:-?}" \
		"${purpose:-?}" "${job:-?}" | emit

	i=$((i + 1))
	[ "$COUNT" -gt 0 ] && [ "$i" -ge "$COUNT" ] && break
	sleep "$INTERVAL"
done
