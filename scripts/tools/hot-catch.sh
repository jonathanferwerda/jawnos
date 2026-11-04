#!/bin/sh
# Catch a sustained CPU hog and dump what it is doing.
#
# Answers: "which process is pinning a core, and is it looping or blocked?"
# CPU comes from /proc ticks (not top), and it only fires after the same PID is
# over the threshold for two consecutive samples, so a one-off burst is ignored.
#
# Usage: hot-catch.sh [--pattern REGEX] [--seconds N] [--pct N] [--out FILE]
# Example: hot-catch.sh --pattern 'jawn-bt' --seconds 600 --pct 80
#
# Read-only by default: the evidence dump goes to stdout.
# WRITES: --out FILE appends the evidence dump to FILE.

PAT='President\.pl'
SECS=1200
PCT=60
OUT=''
INTERVAL=2

while [ $# -gt 0 ]; do
	case "$1" in
		--pattern) PAT=$2; shift 2 ;;
		--seconds) SECS=$2; shift 2 ;;
		--pct) PCT=$2; shift 2 ;;
		--out) OUT=$2; shift 2 ;;
		-h|--help) sed -n '2,14p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
THR=$((PCT * HZ * INTERVAL / 100))
[ "$THR" -lt 1 ] && THR=1
N=$((SECS / INTERVAL))
[ "$N" -lt 1 ] && N=1

emit() {
	if [ -n "$OUT" ]; then
		cat >> "$OUT"
	else
		cat
	fi
}

echo "watch start $(date) interval=${INTERVAL}s threshold=${THR} ticks/${INTERVAL}s pattern=$PAT" >&2

prev=''
hits=''
i=0
while [ "$i" -lt "$N" ]; do
	cur=''
	for dir in /proc/[0-9]*; do
		p=${dir#/proc/}
		[ -r "$dir/cmdline" ] || continue
		tr '\0' ' ' < "$dir/cmdline" 2>/dev/null | grep -Eq "$PAT" || continue
		t=$(cut -d' ' -f14,15 "$dir/stat" 2>/dev/null)
		[ -n "$t" ] || continue
		set -- $t
		cur="$cur $p:$(($1 + $2))"
	done

	if [ -n "$prev" ]; then
		for entry in $cur; do
			p=${entry%%:*}
			n=${entry##*:}
			old=''
			for was in $prev; do
				case "$was" in
					"$p:"*) old=${was##*:} ;;
				esac
			done
			[ -n "$old" ] || continue
			delta=$((n - old))
			[ "$delta" -ge "$THR" ] || continue
			hits="$hits $p"
			seen=0
			for h in $hits; do
				[ "$h" = "$p" ] && seen=$((seen + 1))
			done
			[ "$seen" -ge 2 ] || continue

			a1=$(cut -d' ' -f14 "/proc/$p/stat" 2>/dev/null)
			b1=$(cut -d' ' -f15 "/proc/$p/stat" 2>/dev/null)
			f1=$(cut -d' ' -f10 "/proc/$p/stat" 2>/dev/null)
			r1=$(sed -n 's/^rchar: //p' "/proc/$p/io" 2>/dev/null)
			w1=$(sed -n 's/^wchar: //p' "/proc/$p/io" 2>/dev/null)
			c1=$(sed -n 's/^voluntary_ctxt_switches: //p' "/proc/$p/status" 2>/dev/null)

			{
				echo "=== caught pid $p at $(date) ticks+$delta/${INTERVAL}s"
				echo "--- stat"
				cat "/proc/$p/stat" 2>/dev/null
				echo "--- status"
				grep -E 'State|Threads|VmRSS|voluntary' "/proc/$p/status" 2>/dev/null
				echo "--- cmdline"
				tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null
				echo
				echo "--- environ"
				tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -E 'PURPOSE|PORT_ENV'
			} | emit

			sleep 3

			a2=$(cut -d' ' -f14 "/proc/$p/stat" 2>/dev/null)
			b2=$(cut -d' ' -f15 "/proc/$p/stat" 2>/dev/null)
			f2=$(cut -d' ' -f10 "/proc/$p/stat" 2>/dev/null)
			r2=$(sed -n 's/^rchar: //p' "/proc/$p/io" 2>/dev/null)
			w2=$(sed -n 's/^wchar: //p' "/proc/$p/io" 2>/dev/null)
			c2=$(sed -n 's/^voluntary_ctxt_switches: //p' "/proc/$p/status" 2>/dev/null)

			{
				echo "u+$(( ${a2:-0} - ${a1:-0} )) s+$(( ${b2:-0} - ${b1:-0} )) minflt+$(( ${f2:-0} - ${f1:-0} )) rchar+$(( ${r2:-0} - ${r1:-0} )) wchar+$(( ${w2:-0} - ${w1:-0} )) ctxt+$(( ${c2:-0} - ${c1:-0} )) in 3s"
				echo "--- syscall x30"
				j=0
				while [ "$j" -lt 30 ]; do
					cat "/proc/$p/syscall" 2>/dev/null
					j=$((j + 1))
				done
				echo "--- fds"
				ls -l "/proc/$p/fd" 2>/dev/null | awk 'NR>1{print $9, $10, $11}' | head -40
			} | emit

			exit 0
		done
	fi

	prev="$cur"
	i=$((i + 1))
	sleep "$INTERVAL"
done

echo "no sustained hit in ${SECS}s" >&2
exit 1
