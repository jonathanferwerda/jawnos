#!/bin/sh
# Watch the BLE listener: is it burning a core, and what were the last events
# before the parent's guard restarted it?
#
# Answers: "the phone is hot again - is it the listener, and which event?"
# Usage:   ble-watch.sh [MANAGER_LOG] [INTERVAL_S] [COUNT]
# Example: ble-watch.sh ~/manager.log 30 20     # one sample every ~30 s, 20 times
# Read-only: reads the log and the event ring; never writes them.
#
# The ring is $JAWNOS_BT_RING, else $HOME/.jawn-bt-ring.log, written by
# scripts/jawn-bt (event type, byte length, MAC, short head) before it prints
# the event. When the guard fires it logs the ring tail in the manager log.

LOG=${1:-$HOME/manager.log}
INTERVAL=${2:-30}
COUNT=${3:-20}
RING=${JAWNOS_BT_RING:-$HOME/.jawn-bt-ring.log}

listener_pid() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -f 'scripts/jawn-bt listen' 2>/dev/null | head -1
	else
		ps -A -o PID,ARGS 2>/dev/null | grep '[s]cripts/jawn-bt listen' | awk '{print $1}' | head -1
	fi
}

count_events() {
	grep -ac 'BLE listener held a core\|BLE listener closed' "$LOG" 2>/dev/null || true
}

seen=$(count_events)
case "$seen" in ''|*[!0-9]*) seen=0 ;; esac

i=0
while [ "$i" -lt "$COUNT" ]; do
	i=$((i + 1))
	pid=$(listener_pid)
	if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
		a=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null)
		sleep 1
		b=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null)
		case "$a$b" in ''|*[!0-9]*) cpu='?' ;; *) cpu=$((b - a)) ;; esac
		echo "$(date '+%H:%M:%S') pid=$pid cpu=${cpu}% ring=$(wc -l < "$RING" 2>/dev/null || echo 0) events"
	else
		echo "$(date '+%H:%M:%S') no listener"
	fi

	now=$(count_events)
	case "$now" in ''|*[!0-9]*) now=$seen ;; esac
	if [ "$now" -gt "$seen" ]; then
		echo "--- guard/close since the last check:"
		grep -a 'BLE listener held a core\|BLE listener closed' "$LOG" | tail -n $((now - seen))
		echo "--- last events in the ring:"
		tail -n 8 "$RING" 2>/dev/null
		seen=$now
	fi

	[ "$i" -lt "$COUNT" ] && sleep "$INTERVAL"
done
