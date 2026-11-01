#!/bin/sh
# Rebuild the JawnOS QEMU image from the current tree, every run.
#
#   qa/qemu/build.sh                 # sudo, network, ~10 min
#   qa/qemu/build.sh /path/to/out    # copy the image there as well
#
# mkosi needs root, Arch's mirrors and several GB. The output stays at
# desktop/mkosi/output/jawnos-live_0.1.raw, which is what qa/qemu/run.sh boots
# with -snapshot, so the image file itself is never written by a run.

set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=${1:-${QA_ROOT:-$HOME/jawnos-qa}/qemu}

cd "$REPO"
if [ ! -f scripts/mkosi_build.pl ]; then
	echo "qa-qemu: scripts/mkosi_build.pl is missing" >&2
	exit 2
fi

# Always rebuild: a cached image is the failure this layer exists to catch.
sudo perl scripts/mkosi_build.pl

IMG=$(ls -t desktop/mkosi/output/*.raw 2>/dev/null | head -n 1 || true)
if [ -z "$IMG" ]; then
	echo "qa-qemu: mkosi produced no image in desktop/mkosi/output" >&2
	exit 1
fi

mkdir -p "$OUT"
echo "$IMG" > "$OUT/image.path"
echo "$IMG"
