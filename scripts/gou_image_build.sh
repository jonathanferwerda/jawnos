#!/usr/bin/env bash
# gou_image_build.sh - build, repair and delta the ODROID Go Ultra eMMC image.
#
#   gou_image_build.sh build  --from DUMP   --out IMG [options]
#   gou_image_build.sh repair --image IMAGE --out IMG [options]
#   gou_image_build.sh patch  --from OLD --to NEW --out PATCH
#
# build  rewrites a pristine microSD dump into an eMMC image: the eMMC's own
#        geometry, the exclusion list in this file, a fresh filesystem and the
#        per-device fixes below.
# repair applies the image-level fixes to an image that already exists. It is
#        what turns an image built before a fix into one that boots.
# patch  makes a zstd binary delta between two uncompressed images, for a bad
#        uplink; apply with `zstd -d --patch-from OLD PATCH > NEW`.
#
# Four things a GOU eMMC image must carry, each learned from a board that
# would not start:
#
#   1. The eMMC bootloader in the first 16 MiB. The microSD's u-boot is a
#      different build; the ROM rejects it on eMMC and the board stops at a red
#      light with no screen. It comes from the stock eMMC backup
#      (--stock-backup), never from the card.
#   2. /home/jawn/.local/state/jawnos/ , the jawnos.service StandardOutput
#      directory. Absent, systemd fails the unit with 209/STDOUT before Perl
#      runs and the kiosk shows "this page cannot be displayed".
#   3. The USB gadget profile (192.168.7.2 on usb0), so a board can be reached
#      over the cable without Wi-Fi.
#   4. A blank /etc/machine-id and no SSH host keys, so every board is itself.
#
# Wi-Fi, the hostname and the house token are NOT written here: the provision
# script writes those per board, and an image that carried one house's Wi-Fi
# would be wrong for every other.
#
# Every step writes only what it must: the source is opened read-only, the
# output is a new file.

set -euo pipefail

EMMC_BYTES=15634268160
P1_START=32768
P1_SECTORS=229376
P2_START=262144
P2_SECTORS=30273536
BOOT_BYTES=16777216
ROOT_UUID_DEFAULT="948b17cb-9a83-4a38-8bb6-8faea0409ac6"
BOOT_UUID_DEFAULT="5CDB-14C3"
DISK_ID=0x01e56600

COMPRESS=release
DRY_RUN=0
MODE=""
FROM=""
IMAGE=""
TO=""
OUT=""
STOCK=""
ROOT_UUID="$ROOT_UUID_DEFAULT"
BOOT_UUID="$BOOT_UUID_DEFAULT"

usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	cat <<'USAGE'

Options
  --from PATH          pristine microSD dump (build) or old image (patch)
  --image PATH         image to repair
  --to PATH            new image (patch)
  --out PATH           where to write the result
  --stock-backup PATH  the stock eMMC dump (compressed or not); the bootloader
                       is its first 16 MiB (required for build and repair)
  --root-uuid UUID     filesystem UUID for the root partition
  --boot-uuid UUID     filesystem UUID for the BOOT partition
  --compress MODE      release (zstd -19), fast (zstd -1) or none
  --dry-run            print the plan and change nothing
  -h, --help           this text

The output is left uncompressed with --compress none, which is what the
provision script wants when it flashes.
USAGE
}

log()  { printf '%s\n' "$*" >&2; }
die()  { log "gou_image_build: $*"; exit 1; }

need_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root (loop mounts, dd, mkfs)"
}

need_tools() {
	local t
	for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
}

WORK=""
LOOP_DUMP=""
LOOP_OUT=""
MNT_SRC=""
MNT_P1=""
MNT_P2=""
cleanup() {
	set +e
	[[ -n "$MNT_P2"   ]] && mountpoint -q "$MNT_P2"   && umount "$MNT_P2"
	[[ -n "$MNT_P1"   ]] && mountpoint -q "$MNT_P1"   && umount "$MNT_P1"
	[[ -n "$MNT_SRC"  ]] && mountpoint -q "$MNT_SRC"  && umount "$MNT_SRC"
	[[ -n "$LOOP_OUT" ]] && losetup -d "$LOOP_OUT" 2>/dev/null
	[[ -n "$LOOP_DUMP" ]] && losetup -d "$LOOP_DUMP" 2>/dev/null
	[[ -n "$WORK"     ]] && rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- the exclusion list ------------------------------------------------------
# What the card had that an image must not: build trees, caches, journals,
# personal data and the identifying files. Kept here rather than in a separate
# file so a build is one document.
write_excludes() {
	cat > "$1" <<'EXCLUDES'
/proc/*
/sys/*
/dev/*
/run/*
/tmp/*
/mnt/*
/media/*
/lost+found/*
/root/kbuild
/root/RetroArch-1.22.2
/root/.cpanm
/root/gou-audio
/root/linux-7.3.3.tar.xz
/root/.cache
/root/.ssh
/root/.bash_history
/root/.config
/root/.local
/root/.pki
/root/modtest
/root/gou-poke
/root/gou-gamma
/root/gou-peek
/root/kd50-build
/root/meson-src
/root/xorg-backup
/var/cache/pacman
/var/log/*
/var/tmp/*
/var/lib/bluetooth
/var/lib/NetworkManager
/var/lib/systemd/random-seed
/home/jawn/build
/home/jawn/.cache
/home/jawn/roms
/home/jawn/.president
/home/jawn/.presence
/home/jawn/.pki
/home/jawn/.local/state
/home/jawn/.local/share/Trash
/home/jawn/.jawn-bt-ring.log
/home/jawn/coding.log
/home/jawn/cdp*.py
/home/jawn/jawnos-before-*.tar.gz
/home/jawn/jawnos/.git
/home/jawn/jawnos/releases
/home/jawn/jawnos/.shots
/home/jawn/jawnos/run
/home/jawn/jawnos/config.json
/home/jawn/jawnos/database/jawnos.db*
/home/jawn/jawnos/database/.jawnos_signatorial_id
/home/jawn/jawnos/database/backups
/home/jawn/jawnos/database/initial.enc
/home/jawn/.jawnos_signatorial
/home/jawn/.jawnos_signatorial_id
/home/jawn/.house.key
/home/jawn/.peer.key
/home/jawn/.peer.pub
/etc/machine-id
/etc/ssh/ssh_host_*
/etc/NetworkManager/system-connections/*.nmconnection
/opt/retroarch-stock
/usr/share/doc
/usr/share/man
/boot/dtbs/qcom
/boot/dtbs/freescale
/boot/dtbs/rockchip
/boot/dtbs/mediatek
/usr/lib/firmware/intel
/usr/lib/firmware/nvidia
/usr/lib/firmware/netronome
/usr/lib/firmware/amdgpu
/usr/lib/firmware/ath11k
/usr/lib/firmware/ath12k
/usr/lib/firmware/i915
/usr/lib/firmware/liquidio
/usr/lib/firmware/mediatek
EXCLUDES
}

# --- the fixes, applied to a mounted root ------------------------------------
apply_fixes() {
	local root="$1"
	local boot_uuid="$2"
	local root_uuid="$3"

	# 2. the directory the server unit appends its stdout to
	install -d -o 1001 -g 1001 -m 755 "$root/home/jawn/.local/state/jawnos"

	# 3. the USB gadget link, so the board answers on the cable
	install -d -o 0 -g 0 -m 700 "$root/etc/NetworkManager/system-connections"
	cat > "$root/etc/NetworkManager/system-connections/usb-gadget.nmconnection" <<'NM'
[connection]
id=usb-gadget
type=ethernet
autoconnect=true

[ethernet]

[ipv4]
method=manual
address1=192.168.7.2/24

[ipv6]
method=ignore
NM
	chmod 600 "$root/etc/NetworkManager/system-connections/usb-gadget.nmconnection"
	chown 0:0 "$root/etc/NetworkManager/system-connections/usb-gadget.nmconnection"

	# 4. per-board identity: an empty machine-id is generated on first boot
	: > "$root/etc/machine-id"
	chmod 444 "$root/etc/machine-id"
	printf 'gou\n' > "$root/etc/hostname"

	# The boot partition and the root are named by UUID, never by LABEL: the
	# stock card and the eMMC both call their partition BOOT, and a LABEL
	# lookup picks whichever the kernel happens to find.
	cat > "$root/etc/fstab" <<FSTAB
UUID=$boot_uuid /boot/oem vfat umask=0077 0 1
UUID=$root_uuid / ext4 rw,relatime,x-systemd.growfs 0 1
FSTAB
	chmod 644 "$root/etc/fstab"
}

# --- helpers -----------------------------------------------------------------
bootloader_from() {
	local src="$1" dest="$2"
	if [[ "$src" == *.zst ]]; then
		zstd -dc "$src" 2>/dev/null | head -c "$BOOT_BYTES" > "$dest" || true
	else
		head -c "$BOOT_BYTES" "$src" > "$dest"
	fi
	[[ $(stat -c %s "$dest") -eq $BOOT_BYTES ]] || die "could not read 16 MiB of bootloader from $src"
}

compress_out() {
	local plain="$1" out="$2"
	case "$COMPRESS" in
		none)   mv -f "$plain" "$out" ;;
		fast)   zstd -1 -T0 -f "$plain" -o "$out" && rm -f "$plain" ;;
		release) zstd -19 -T0 -f "$plain" -o "$out" && rm -f "$plain" ;;
		*) die "unknown --compress $COMPRESS" ;;
	esac
}

# --- repair ------------------------------------------------------------------
do_repair() {
	[[ -n "$IMAGE" ]] || die "repair needs --image"
	[[ -f "$IMAGE" ]] || die "no such image: $IMAGE"
	[[ -n "$OUT" ]]  || die "repair needs --out"
	[[ -n "$STOCK" ]] || die "repair needs --stock-backup (the eMMC bootloader comes from it)"

	log "plan: write the eMMC bootloader, add the state directory and the gadget link,"
	log "      rewrite fstab by UUID, blank the machine-id, then compress=$COMPRESS"
	if [[ $DRY_RUN -eq 1 ]]; then log "dry run: nothing written"; return 0; fi

	need_root
	need_tools dd losetup mount umount mkfs.ext4 sfdisk blkid stat

	WORK=$(mktemp -d)
	local plain="$WORK/image.img"
	if [[ "$IMAGE" == *.zst ]]; then
		log "decompressing $IMAGE"
		zstd -dc "$IMAGE" > "$plain"
	else
		plain="$IMAGE"
	fi

	bootloader_from "$STOCK" "$WORK/boot.bin"
	dd if="$WORK/boot.bin" of="$plain" bs=1M conv=notrunc status=none
	sync

	LOOP_OUT=$(losetup -Pf --show "$plain")
	MNT_P2="$WORK/p2"
	mkdir -p "$MNT_P2"
	mount "${LOOP_OUT}p2" "$MNT_P2"

	local root_uuid boot_uuid
	root_uuid=$(blkid -s UUID -o value "${LOOP_OUT}p2")
	boot_uuid=$(blkid -s UUID -o value "${LOOP_OUT}p1")
	[[ -n "$root_uuid" ]] || die "the root partition has no UUID"
	[[ -n "$boot_uuid" ]] || die "the boot partition has no UUID"

	apply_fixes "$MNT_P2" "$boot_uuid" "$root_uuid"

	sync
	umount "$MNT_P2"
	MNT_P2=""
	losetup -d "$LOOP_OUT"
	LOOP_OUT=""

	compress_out "$plain" "$OUT"
	log "wrote $OUT ($(stat -c %s "$OUT") bytes)"
}

# --- build -------------------------------------------------------------------
do_build() {
	[[ -n "$FROM" ]] || die "build needs --from (a pristine microSD dump)"
	[[ -f "$FROM" ]] || die "no such dump: $FROM"
	[[ -n "$OUT" ]]  || die "build needs --out"
	[[ -n "$STOCK" ]] || die "build needs --stock-backup (the eMMC bootloader comes from it)"

	log "plan: eMMC geometry ${EMMC_BYTES}B, p1 @${P1_START} (${P1_SECTORS}), p2 @${P2_START}"
	log "      bootloader from $STOCK; root uuid $ROOT_UUID; compress=$COMPRESS"
	if [[ $DRY_RUN -eq 1 ]]; then log "dry run: nothing written"; return 0; fi

	need_root
	need_tools dd losetup mount umount mkfs.vfat mkfs.ext4 rsync sfdisk blkid \
		e2fsck resize2fs tune2fs dumpe2fs stat truncate zstd

	WORK=$(mktemp -d)
	write_excludes "$WORK/excludes.txt"

	local img="$WORK/image.img"
	truncate -s "$EMMC_BYTES" "$img"

	bootloader_from "$STOCK" "$WORK/boot.bin"
	dd if="$WORK/boot.bin" of="$img" bs=1M conv=notrunc status=none

	printf 'label: dos\nlabel-id: %s\nunit: sectors\nsector-size: 512\n/dev/loop0p1 : start=%s, size=%s, type=c\n/dev/loop0p2 : start=%s, size=%s, type=83\n' \
		"$DISK_ID" "$P1_START" "$P1_SECTORS" "$P2_START" "$P2_SECTORS" > "$WORK/table"
	sfdisk --force "$img" < "$WORK/table" >/dev/null

	LOOP_OUT=$(losetup -Pf --show "$img")
	mkfs.vfat -n BOOT -i "$BOOT_UUID" "${LOOP_OUT}p1" >/dev/null
	mkfs.ext4 -q -m 1 -L rootfs -U "$ROOT_UUID" "${LOOP_OUT}p2"

	LOOP_DUMP=$(losetup -Pf --show "$FROM")
	MNT_SRC="$WORK/src"
	mkdir -p "$MNT_SRC"
	mount -o ro "${LOOP_DUMP}p2" "$MNT_SRC"

	MNT_P1="$WORK/p1"
	mkdir -p "$MNT_P1"
	mount "${LOOP_OUT}p1" "$MNT_P1"
	rsync -a --no-perms "${LOOP_DUMP}p1"/ "$MNT_P1"/
	# u-boot on the eMMC is mmc 0; the card's own script says mmc 1.
	sed -i 's/mmc 1:1/mmc 0:1/g' "$MNT_P1/boot.ini"
	umount "$MNT_P1"
	MNT_P1=""

	MNT_P2="$WORK/p2"
	mkdir -p "$MNT_P2"
	mount "${LOOP_OUT}p2" "$MNT_P2"
	rsync -aHAX --numeric-ids --exclude-from="$WORK/excludes.txt" "$MNT_SRC"/ "$MNT_P2"/
	# an empty roms home, owned by the person, for the ROM shelf to fill
	install -d -o 1001 -g 1001 -m 755 "$MNT_P2/home/jawn/roms"
	apply_fixes "$MNT_P2" "$BOOT_UUID" "$ROOT_UUID"
	sync

	umount "$MNT_P2"
	MNT_P2=""
	umount "$MNT_SRC"
	MNT_SRC=""
	losetup -d "$LOOP_DUMP"
	LOOP_DUMP=""

	e2fsck -fy "${LOOP_OUT}p2" >/dev/null || true
	resize2fs "${LOOP_OUT}p2" 6400M >/dev/null
	tune2fs -m 0 "${LOOP_OUT}p2" >/dev/null
	local blocks size
	blocks=$(dumpe2fs -h "${LOOP_OUT}p2" 2>/dev/null | awk '/^Block count:/ {print $3}')
	size=$(( P2_START * 512 + blocks * 4096 ))
	losetup -d "$LOOP_OUT"
	LOOP_OUT=""
	truncate -s "$size" "$img"

	compress_out "$img" "$OUT"
	log "wrote $OUT ($(stat -c %s "$OUT") bytes, $size uncompressed)"
}

# --- patch -------------------------------------------------------------------
do_patch() {
	[[ -n "$FROM" && -n "$TO" && -n "$OUT" ]] || die "patch needs --from OLD --to NEW --out PATCH"
	[[ -f "$FROM" ]] || die "no such image: $FROM"
	[[ -f "$TO"   ]] || die "no such image: $TO"
	need_tools zstd
	log "plan: zstd patch $FROM -> $TO into $OUT"
	[[ $DRY_RUN -eq 1 ]] && { log "dry run: nothing written"; return 0; }
	zstd -19 -T0 --patch-from="$FROM" -f "$TO" -o "$OUT"
	log "wrote $OUT ($(stat -c %s "$OUT") bytes)"
}

# --- arguments ---------------------------------------------------------------
[[ $# -gt 0 ]] || { usage; exit 1; }
case "$1" in
	-h|--help) usage; exit 0 ;;
	build|repair|patch) MODE="$1"; shift ;;
	*) die "unknown command: $1 (try --help)" ;;
esac

while [[ $# -gt 0 ]]; do
	case "$1" in
		--from)        FROM="$2"; shift 2 ;;
		--image)       IMAGE="$2"; shift 2 ;;
		--to)          TO="$2"; shift 2 ;;
		--out)         OUT="$2"; shift 2 ;;
		--stock-backup) STOCK="$2"; shift 2 ;;
		--root-uuid)   ROOT_UUID="$2"; shift 2 ;;
		--boot-uuid)   BOOT_UUID="$2"; shift 2 ;;
		--compress)    COMPRESS="$2"; shift 2 ;;
		--dry-run)     DRY_RUN=1; shift ;;
		-h|--help)     usage; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

case "$MODE" in
	build)  do_build ;;
	repair) do_repair ;;
	patch)  do_patch ;;
esac
