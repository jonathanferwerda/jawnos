#!/bin/sh
# Does the virtual handset carry a tone end to end, with no phone call?
#
# Answers: "does a tone into the call sink reach its monitor, and a tone into the
#           prompt sink reach the virtual microphone?"
# Usage:   audio-pipe-test.sh [CALL_IN [PROMPT [IVR_MIC]]]
# Example: audio-pipe-test.sh jawn_call_in jawn_prompt jawn_ivr_mic
# Plays a 0.5 s tone; writes only temporary raw files.

call_in=${1:-jawn_call_in}
prompt=${2:-jawn_prompt}
ivr_mic=${3:-jawn_ivr_mic}

usage() {
	cat <<'TXT'
usage: audio-pipe-test.sh [CALL_IN [PROMPT [IVR_MIC]]]

  CALL_IN   the sink the caller's voice is played into (default jawn_call_in)
  PROMPT    the sink the house's prompts are played into (default jawn_prompt)
  IVR_MIC   the source the phone reads as its microphone (default jawn_ivr_mic)

A nonzero byte count for each capture means the virtual handset is wired. The
tone is audible; the test writes only under its own temporary directory.
TXT
}

case "${1:-}" in
	-h|--help) usage; exit 0 ;;
esac

for c in parec pacat perl mktemp; do
	command -v "$c" >/dev/null 2>&1 || { echo "$c not found" >&2; exit 1; }
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/audio-pipe-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

# A 0.5 s 440 Hz tone at the handset's 8 kHz mono S16_LE.
perl -e 'binmode STDOUT; for my $i (0..15999) { print pack("s<", int(sin(2*3.14159*440*$i/8000)*8000)) }' > "$tmp/tone.raw"

capture() {
	parec --raw --format=s16le --rate=8000 --channels=1 --device="$1" --file-format=raw "$2" 2>/dev/null &
	echo $!
}

play() {
	pacat --raw --format=s16le --rate=8000 --channels=1 --playback --device="$1" < "$tmp/tone.raw" 2>/dev/null
}

in_pid=$(capture "$call_in.monitor" "$tmp/in.raw")
sleep 0.5
play "$call_in"
sleep 0.5
kill "$in_pid" 2>/dev/null

mic_pid=$(capture "$ivr_mic" "$tmp/mic.raw")
sleep 0.5
play "$prompt"
sleep 0.5
kill "$mic_pid" 2>/dev/null
wait 2>/dev/null

size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
echo "in.raw:  $(size "$tmp/in.raw") bytes"
echo "mic.raw: $(size "$tmp/mic.raw") bytes"
