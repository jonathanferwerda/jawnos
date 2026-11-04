#!/bin/sh
# Watch sync_jobs progress on a JawnOS database.
#
# Answers: "is a sync stuck, how many pulls finished, and is the box loaded?"
# One compact line per sample; the last eight job rows are appended per tick.
#
# Usage: sync-watch.sh [--db PATH] [--interval S] [--samples N] [--log FILE]
# Example: sync-watch.sh --interval 60 --samples 15
#
# Read-only: opens the database as mode=ro.
# WRITES: --log FILE appends each sample (and its job rows) to FILE.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DB=${JAWNOS_DB:-"$ROOT/database/jawnos.db"}
INTERVAL=60
SAMPLES=15
LOG=''

while [ $# -gt 0 ]; do
	case "$1" in
		--db) DB=$2; shift 2 ;;
		--interval) INTERVAL=$2; shift 2 ;;
		--samples) SAMPLES=$2; shift 2 ;;
		--log) LOG=$2; shift 2 ;;
		-h|--help) sed -n '2,14p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

[ -r "$DB" ] || { echo "no readable database: $DB" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 not found" >&2; exit 1; }

DBURI="file:${DB}?mode=ro"

emit() {
	if [ -n "$LOG" ]; then
		cat >> "$LOG"
	else
		cat
	fi
}

i=0
while [ "$i" -lt "$SAMPLES" ]; do
	now=$(date +%s)
	since=$(( (now - 900) * 1000 ))
	stamp=$(date '+%H:%M:%S')

	{
		echo "=== $stamp sample $i ==="
		sqlite3 "$DBURI" "select direction,peer,state,phase,substr(note,1,40),cast(updated as integer) from sync_jobs order by cast(updated as integer) desc limit 8;"
	} >> "${LOG:-/dev/null}"

	pulls=$(sqlite3 "$DBURI" "select 'done=' || ifnull(sum(state='done'),0) || ' failed=' || ifnull(sum(state='failed'),0) || ' skipped=' || ifnull(sum(state='skipped'),0) || ' running=' || ifnull(sum(state='running'),0) from sync_jobs where direction='pull' and cast(updated as integer) >= $since;")
	latest=$(sqlite3 "$DBURI" "select peer || ' ' || state || ' ' || substr(note,1,28) from sync_jobs where direction='pull' order by cast(updated as integer) desc limit 1;")
	setstep=$(sqlite3 "$DBURI" "select json_extract(value,'$.state') || ' ' || json_extract(value,'$.current') || '/' || json_extract(value,'$.total') from sync_jobs, json_each(steps) where direction='pull' and cast(updated as integer) >= $since and json_extract(value,'$.key')='merge:settings' order by cast(updated as integer) desc limit 1;")
	appts=$(sqlite3 "$DBURI" "select ifnull(max(cast(json_extract(value,'$.current') as integer)),0) from sync_jobs, json_each(steps) where direction='serve' and cast(updated as integer) >= $since and json_extract(value,'$.key')='export:appointments';")
	phone=$(sqlite3 "$DBURI" "select state || ' ' || substr(note,1,28) from sync_jobs where direction='pull' and peer like 'phone%' order by cast(updated as integer) desc limit 1;")
	load=$(cut -d' ' -f1-3 /proc/loadavg)

	echo "$stamp | $pulls | settings=$setstep | appts_served_max=$appts | load=$load | latest=$latest | phone=$phone" | emit

	i=$((i + 1))
	[ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
done
