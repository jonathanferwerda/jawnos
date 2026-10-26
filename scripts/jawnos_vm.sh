#!/bin/sh
# Boot the newest built JawnOS raw image in QEMU, without rebuilding it and
# without writing to it. This is the quick "try the image" launcher; the
# desktop entry `jawnos-vm.desktop` runs it from the applications menu.
#
#   scripts/jawnos_vm.sh              # boot the newest desktop/mkosi/output/*.raw
#   scripts/jawnos_vm.sh --check      # show the image, firmware and command
#   JAWNOS_VM_IMAGE=/path/file.raw scripts/jawnos_vm.sh
#   JAWNOS_VM_RAM=8192 scripts/jawnos_vm.sh
#
# The disk is opened with snapshot=on, so the guest's first boot, its seeded
# database and anything else it writes disappear when the window closes. The
# built image is never modified; use `mkosi_build.pl --vm` when you want a
# persistent test disk or a different size.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/desktop/mkosi/output"
RAM=${JAWNOS_VM_RAM:-4096}
CPUS=${JAWNOS_VM_CPUS:-4}

CHECK=no
case ${1:-} in
	--check) CHECK=yes ;;
	-h|--help)
		sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	'') ;;
	*) echo "jawnos_vm: unknown argument: $1" >&2; exit 2 ;;
esac

notify() {
	printf 'jawnos_vm: %s\n' "$1" >&2
	if command -v notify-send >/dev/null 2>&1; then
		notify-send "JawnOS VM" "$1" 2>/dev/null || true
	fi
}

if [ -n "${JAWNOS_VM_IMAGE:-}" ]; then
	IMG=$JAWNOS_VM_IMAGE
else
	IMG=$(ls -t "$OUT"/*.raw 2>/dev/null | head -n 1 || true)
fi
if [ -z "${IMG:-}" ] || [ ! -f "$IMG" ]; then
	notify "No built image in $OUT. Build one with: sudo perl scripts/mkosi_build.pl"
	exit 1
fi

QEMU=$(command -v qemu-system-x86_64 || true)
if [ -z "$QEMU" ]; then
	notify "qemu-system-x86_64 is not installed. On Manjaro: sudo pacman -S qemu-desktop edk2-ovmf"
	exit 1
fi

CODE=
VARS=
for f in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd; do
	[ -f "$f" ] && { CODE=$f; break; }
done
for f in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd; do
	[ -f "$f" ] && { VARS=$f; break; }
done
if [ -z "$CODE" ] || [ -z "$VARS" ]; then
	notify "UEFI firmware not found. On Manjaro: sudo pacman -S edk2-ovmf"
	exit 1
fi

TMPVARS=${XDG_RUNTIME_DIR:-/tmp}/jawnos-vm-vars.fd
cp "$VARS" "$TMPVARS"
cleanup() { rm -f "$TMPVARS"; }
trap cleanup EXIT INT TERM

if [ "$CHECK" = yes ]; then
	printf 'image:  %s\n' "$IMG"
	printf 'firmware: %s\n' "$CODE"
	printf 'vars:   %s (temporary copy)\n' "$TMPVARS"
	printf 'qemu:   %s\n' "$QEMU"
	if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
		printf 'accel:  kvm\n'
	else
		printf 'accel:  tcg (no writable /dev/kvm)\n'
	fi
	printf 'ram:    %s MB, cpus: %s\n' "$RAM" "$CPUS"
	printf 'disk:   snapshot (writes discarded)\n'
	exit 0
fi

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	ACCEL="-enable-kvm -cpu host"
else
	ACCEL="-accel tcg,thread=multi -cpu max"
fi

# shellcheck disable=SC2086
"$QEMU" \
	-name "JawnOS VM" \
	-machine q35 $ACCEL \
	-m "$RAM" -smp "$CPUS" \
	-drive if=pflash,format=raw,readonly=on,file="$CODE" \
	-drive if=pflash,format=raw,file="$TMPVARS" \
	-drive file="$IMG",format=raw,if=virtio,snapshot=on \
	-vga std \
	-display gtk,zoom-to-fit=on \
	-netdev user,id=net0 \
	-device virtio-net-pci,netdev=net0 \
	-usb -device usb-tablet &
QPID=$!
stop_vm() {
	kill "$QPID" 2>/dev/null || true
	wait "$QPID" 2>/dev/null || true
	cleanup
}
trap stop_vm INT TERM HUP
wait "$QPID"
status=$?
cleanup
exit "$status"
