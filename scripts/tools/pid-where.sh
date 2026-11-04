#!/bin/sh
# What is a known PID doing? Syscall samples, io deltas, open fds, cwd.
#
# Answers: "this process is hot - is it looping in a syscall, blocked, or
#           churning file descriptors?"
# Usage: pid-where.sh PID [SAMPLES]
# Example: pid-where.sh 12345 8
# Read-only: reads /proc/<pid> only.
#
# /proc/<pid>/syscall and /proc/<pid>/stack may be denied on Android; the
# denial is shown rather than hidden.

P=${1:?usage: pid-where.sh PID [SAMPLES]}
SAMPLES=${2:-8}

echo "=== pid $P stat"
cut -d' ' -f1-20 "/proc/$P/stat" 2>/dev/null
echo "=== syscall samples ($SAMPLES)"
i=0
while [ "$i" -lt "$SAMPLES" ]; do
	cat "/proc/$P/syscall" 2>&1 | cut -c1-90
	i=$((i + 1))
done
echo "=== io t0"
cat "/proc/$P/io" 2>/dev/null
sleep 2
echo "=== io t1"
cat "/proc/$P/io" 2>/dev/null
echo "=== fds"
ls -l "/proc/$P/fd" 2>/dev/null | awk 'NR>1{print $9, $10, $11}' | head -60
echo "=== task count"
ls "/proc/$P/task" 2>/dev/null | wc -l
echo "=== cwd"
ls -l "/proc/$P/cwd" 2>/dev/null
