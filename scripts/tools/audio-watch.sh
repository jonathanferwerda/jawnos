#!/bin/sh
# PipeWire nodes and Bluetooth card profile, sampled around a call.
#
# Answers: "which sink/source/card profile is a call using, and when does it
#           change?"
# Usage: audio-watch.sh [INTERVAL] [COUNT]
# Example: audio-watch.sh 2 30
# Read-only: pactl listings only.

interval=${1:-2}
count=${2:-30}

case "$interval" in ''|*[!0-9]*) echo "interval must be seconds" >&2; exit 2 ;; esac
case "$count" in ''|*[!0-9]*) echo "count must be a number of samples" >&2; exit 2 ;; esac
command -v pactl >/dev/null 2>&1 || { echo "pactl not found" >&2; exit 1; }

# The call path is the phone's bluez nodes plus the house's virtual handset, so
# keep those two families and leave the music/desktop devices out of the line.
i=0
while [ "$i" -lt "$count" ]; do
	src=$(pactl list short sources 2>/dev/null | grep -Ei 'bluez|jawn' | tr '\t' ' ')
	snk=$(pactl list short sinks 2>/dev/null | grep -Ei 'bluez|jawn' | tr '\t' ' ')
	card=$(pactl list cards 2>/dev/null | grep -A1 'Name: bluez_card' | grep 'Active Profile' | tr -d '\t')
	printf '%s src[%s] sink[%s] card[%s]\n' "$(date +%H:%M:%S)" "$src" "$snk" "$card"
	i=$((i + 1))
	[ "$i" -lt "$count" ] && sleep "$interval"
done
