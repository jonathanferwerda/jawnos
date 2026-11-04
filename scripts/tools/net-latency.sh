#!/bin/sh
# Per-host connect/response timing for JawnOS managers.
#
# Answers: "which peer is slow or unreachable, and is that connect or server?"
# Tries HTTPS first, then falls back to plain HTTP when TLS gets no response.
#
# Usage: net-latency.sh [--port N] [--path PATH] [--log FILE] HOST...
# Example: net-latency.sh --port 45545 192.0.2.1 192.0.2.2
#
# Read-only: HTTP GETs only. --log optionally tails a manager log first.

PORT=45545
REQ_PATH='/manager'
LOG=''

while [ $# -gt 0 ]; do
	case "$1" in
		--port) PORT=$2; shift 2 ;;
		--path) REQ_PATH=$2; shift 2 ;;
		--log) LOG=$2; shift 2 ;;
		-h|--help) sed -n '2,13p' "$0"; exit 0 ;;
		--*) echo "unknown argument: $1" >&2; exit 2 ;;
		*) break ;;
	esac
done

[ $# -gt 0 ] || { echo "usage: net-latency.sh [--port N] [--path PATH] [--log FILE] HOST..." >&2; exit 2; }

if [ -n "$LOG" ]; then
	echo '=== log tail ==='
	tail -20 "$LOG" 2>/dev/null
fi

echo "=== per-host probe (https, max 8s, port $PORT)"
for h in "$@"; do
	out=$(curl -k -s -o /dev/null --max-time 8 \
		-w 'connect=%{time_connect} total=%{time_total} code=%{http_code}' \
		"https://$h:$PORT$REQ_PATH" 2>&1)
	echo "$h  $out"
	case "$out" in
		*code=000*)
			out=$(curl -s -o /dev/null --max-time 8 \
				-w 'connect=%{time_connect} total=%{time_total} code=%{http_code}' \
				"http://$h:$PORT$REQ_PATH" 2>&1)
			echo "$h  http fallback  $out"
			;;
	esac
done
