#!/bin/sh
# Launch Zed inside a transient systemd scope with a hard memory ceiling.
#
# Zed's agent panel has grown the editor process to 6-10 GB on this box and
# taken the whole machine with it. The scope covers the editor and every LSP
# child, so a runaway is contained instead of filling RAM and swap. The editor
# still resumes its threads after the cap kills it; the checkpoint in
# .shots/AGENT-CHECKPOINT.md is what makes that cheap.
#
# MemoryHigh is kept equal to MemoryMax on purpose. A lower soft cap makes the
# kernel throttle every allocation above it, which surfaces as a frozen editor
# (the 4G/6G/1G default did exactly that) instead of a fast, contained OOM kill.
#
# Limits can be overridden per launch:
#   ZED_MEMORY_HIGH=8G ZED_MEMORY_MAX=12G ZED_MEMORY_SWAP_MAX=2G zed
set -u

REAL_ZED=/usr/bin/zed.real
HIGH=${ZED_MEMORY_HIGH:-10G}
MAX=${ZED_MEMORY_MAX:-10G}
SWAP=${ZED_MEMORY_SWAP_MAX:-4G}

export ZED_UPDATE_EXPLANATION='Updates are handled by your package manager'

# systemd-run --user needs the user manager. If it is not usable (a bare TTY, a
# container, an old systemd), start Zed normally rather than refusing to run.
if systemd-run --user --scope --quiet true 2>/dev/null; then
	exec systemd-run --user --scope --quiet \
		-p MemoryHigh="$HIGH" -p MemoryMax="$MAX" -p MemorySwapMax="$SWAP" \
		"$REAL_ZED" "$@"
fi

exec "$REAL_ZED" "$@"
