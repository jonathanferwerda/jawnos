#!/bin/sh
# Boot the freshly built JawnOS image headlessly and measure it.
#
#   qa/qemu/run.sh [image.raw]
#
# The disk is opened with snapshot=on, so nothing the guest writes survives the
# run and the image file is not modified. The guest's manager port is forwarded
# to a loopback port on the host, so health is checked without a login or an SSH
# key; the serial console and QMP are captured for evidence.
#
# Output: $QA_OUT/qemu.txt, serial.log, qmp.log, and host-side samples.

set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=${QA_OUT:-${QA_ROOT:-$HOME/jawnos-qa}/qemu}
IMG=${1:-$(cat "$OUT/image.path" 2>/dev/null || ls -t "$REPO"/desktop/mkosi/output/*.raw 2>/dev/null | head -n 1 || true)}
HOSTMANAGER=${QA_HOST_MANAGER:-24545}
HOSTDOCK=${QA_HOST_DOCK:-23000}
RAM=${QA_VM_RAM:-4096}
CPUS=${QA_VM_CPUS:-4}

if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
	echo "qa-qemu: no image to boot (run qa/qemu/build.sh first, or pass one)" >&2
	exit 2
fi
QEMU=${QEMU:-$(command -v qemu-system-x86_64 || true)}
if [ -z "$QEMU" ]; then
	echo "qa-qemu: qemu-system-x86_64 is not installed" >&2
	exit 2
fi

CODE=
VARS=
for f in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd \
	/usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
	[ -f "$f" ] && { CODE=$f; break; }
done
for f in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd \
	/usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
	[ -f "$f" ] && { VARS=$f; break; }
done
if [ -z "$CODE" ] || [ -z "$VARS" ]; then
	echo "qa-qemu: UEFI firmware not found (install edk2-ovmf)" >&2
	exit 2
fi

mkdir -p "$OUT"
cp -f "$VARS" "$OUT/vars.fd"
: > "$OUT/serial.log"
: > "$OUT/qmp.log"

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	ACCEL="-enable-kvm -cpu host"
else
	ACCEL="-accel tcg,thread=multi -cpu max"
fi

QMP="$OUT/qmp.sock"
rm -f "$QMP"

# shellcheck disable=SC2086
"$QEMU" \
	-name "JawnOS QA" \
	-machine q35 $ACCEL \
	-m "$RAM" -smp "$CPUS" \
	-drive if=pflash,format=raw,readonly=on,file="$CODE" \
	-drive if=pflash,format=raw,file="$OUT/vars.fd" \
	-drive file="$IMG",format=raw,if=virtio,snapshot=on \
	-display none \
	-serial "file:$OUT/serial.log" \
	-qmp "unix:$QMP,server=on,wait=off" \
	-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$HOSTMANAGER-:45545,hostfwd=tcp:127.0.0.1:$HOSTDOCK-:3000" \
	-device virtio-net-pci,netdev=net0 \
	>"$OUT/qemu.log" 2>&1 &
QPID=$!

cleanup() {
	kill "$QPID" 2>/dev/null || true
	wait "$QPID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

START=$(date +%s)
UP=0
i=0
while [ "$i" -lt 240 ]; do
	CODE_HTTP=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 2 \
		"https://127.0.0.1:$HOSTMANAGER/manager/health" 2>/dev/null || true)
	case "$CODE_HTTP" in
		2*|3*|4*) UP=1; break ;;
	esac
	i=$((i + 1))
	sleep 2
done
SECS=$(( $(date +%s) - START ))

{
	echo "image $IMG"
	echo "image_bytes $(wc -c < "$IMG")"
	echo "acceleration $(printf '%s' "$ACCEL" | sed 's/ -cpu.*//')"
	echo "ram_mb $RAM cpus $CPUS"
	if [ "$UP" = "1" ]; then
		echo "health up after ${SECS}s (http $CODE_HTTP)"
	else
		echo "health NEVER answered after ${SECS}s"
	fi
	# host-side resource use of the VM process
	if [ -d "/proc/$QPID" ]; then
		awk '/VmRSS|VmPeak|VmSize/{print "qemu_" $1 " " $2 " " $3}' "/proc/$QPID/status" 2>/dev/null || true
		set -- $(awk '{print $14, $15}' "/proc/$QPID/stat" 2>/dev/null || echo "0 0")
		echo "qemu_cpu_ticks $1 $2"
	fi
} > "$OUT/qemu.txt"

# A clean guest power-off through QMP, then quit.
if command -v socat >/dev/null 2>&1 && [ -S "$QMP" ]; then
	{
		printf '{"execute":"qmp_capabilities"}\n'
		printf '{"execute":"system_powerdown"}\n'
		sleep 8
		printf '{"execute":"quit"}\n'
	} | socat - UNIX-CONNECT:"$QMP" > "$OUT/qmp.log" 2>&1 || true
fi

echo "$OUT/qemu.txt"
