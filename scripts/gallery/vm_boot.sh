#!/bin/sh
# Table-side: boot the prepared JawnOS live image headless.
#
#   scp scripts/gallery/vm_boot.sh table:/tmp/
#   ssh table 'sh /tmp/vm_boot.sh'
#
# The image must already be prepared by table_prepare_demo.sh (sshd, tty1
# autologin, /etc/jawnos-demo-image, the table's key in the home skeleton).
# Running this when the VM is already up prints "already running" and leaves it
# alone, so it is safe to call before every capture.
set -eu

RAW=${RAW:-/home/jawn/jawnos-demo-base.raw}
MON=${MON:-/tmp/qmon-demo.sock}
VARS=${VARS:-/tmp/ovmf-vars-demo.fd}
SER=${SER:-/tmp/ser-demo.log}
LOG=${LOG:-/tmp/qemu-demo.log}

if pgrep -f "$RAW" >/dev/null 2>&1; then
  echo "already running: $RAW"
  exit 0
fi

test -f "$RAW" || { echo "vm_boot: no image at $RAW" >&2; exit 1; }

cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$VARS"
rm -f "$MON" "$SER"

setsid nohup qemu-system-x86_64 \
  -name JawnOS-Demo \
  -machine q35 -enable-kvm -cpu host \
  -m 3072 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$VARS" \
  -drive file="$RAW",format=raw,if=virtio,cache=writeback \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:14545-:45545,hostfwd=tcp:127.0.0.1:13000-:3000 \
  -device virtio-net-pci,netdev=n0 \
  -vga std \
  -vnc 127.0.0.1:5 \
  -usb -device usb-tablet \
  -serial file:"$SER" \
  -monitor unix:"$MON",server,nowait \
  >"$LOG" 2>&1 </dev/null &

echo "qemu pid $!"
