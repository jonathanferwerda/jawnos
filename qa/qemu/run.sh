#!/bin/sh
# Boot the JawnOS image headlessly and measure it - and, with --contract, prove
# what the image promises: its version, its boot evidence, and that its own
# installer produces a disk that boots twice.
#
#   qa/qemu/run.sh                 # newest image: version, boot, health, markers
#   qa/qemu/run.sh --version-check # read the image's version; boot nothing
#   qa/qemu/run.sh --contract      # + install to a blank qcow2, boot it twice
#   qa/qemu/run.sh image.raw       # a specific image
#
# The image file is never written. The live disk is opened with snapshot=on,
# and the run boots it through a throwaway qcow2 overlay that carries one
# systemd drop-in: a serial-console autologin. The shipped image's root account
# is locked (`root:*` in /etc/shadow) and only tty1 autologins, so without that
# drop-in the console cannot be logged into and the image's own installer
# cannot be driven. The drop-in is an affordance of the harness, not of the
# image; the installer copies it onto the installed disk, so the installed
# boots can be driven too. Nothing else about the image changes.
#
# The contract's target is a fresh qcow2 ($QA_OUT/target.qcow2, 16G), never an
# existing file, and every VM keeps its own state partition: no VM is ever
# pointed at the host's live database.
#
# Output: $QA_OUT/qemu/  (default $QA_ROOT/qemu, usually ~/jawnos-qa/qemu)
#
#   version.txt             image version, repo version, and whether they match
#   serial-<phase>.log      the whole serial console transcript for that phase
#   serial-<phase>.status   one line per harness step (expect/send/match)
#   phase-<phase>.txt       that phase's numbers and the markers it printed
#   qemu.txt                every phase, one block each
#   results/device.json     flat l5.* metrics for `perl qa/budget.pl`

set -eu

QA=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=${QA_REPO:-$(CDPATH= cd -- "$QA/../.." && pwd)}
OUT=${QA_OUT:-${QA_ROOT:-$HOME/jawnos-qa}/qemu}
RES=$OUT/results

mkdir -p "$OUT" "$RES"

# Everything this run prints also lands in $OUT/run.log. POSIX sh has no process
# substitution, so the body re-runs itself through tee and reports the child's
# own exit status (tee's is always 0).
if [ -z "${QA_LOGGED:-}" ] && command -v tee >/dev/null 2>&1; then
	QA_LOGGED=1
	export QA_LOGGED
	rm -f "$OUT/.rc"
	( set +e; sh "$0" "$@"; echo "$?" > "$OUT/.rc" ) 2>&1 | tee -a "$OUT/run.log"
	rc=$(cat "$OUT/.rc" 2>/dev/null || echo 1)
	rm -f "$OUT/.rc"
	exit "$rc"
fi

IMG=
MODE=boot
for arg in "$@"; do
	case "$arg" in
		--version-check|--version) MODE=version ;;
		--contract) MODE=contract ;;
		--help|-h) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) echo "qa-qemu: unknown option $arg (try --help)" >&2; exit 2 ;;
		*) IMG=$arg ;;
	esac
done

if [ -z "$IMG" ]; then
	IMG=$(cat "$OUT/image.path" 2>/dev/null || true)
	if [ -z "$IMG" ]; then
		IMG=$(ls -t "$REPO"/desktop/mkosi/output/*.raw 2>/dev/null | head -n 1 || true)
	fi
fi
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
	echo "qa-qemu: no image to boot (run qa/qemu/build.sh first, or pass one)" >&2
	exit 2
fi
IMG=$(CDPATH= cd -- "$(dirname -- "$IMG")" && pwd)/$(basename -- "$IMG")

RAM=${QA_VM_RAM:-3072}
CPUS=${QA_VM_CPUS:-2}
STEP_TIMEOUT=${QA_STEP_TIMEOUT:-900}
HEALTH_TIMEOUT=${QA_HEALTH_TIMEOUT:-600}
PHASE_EXIT_TIMEOUT=${QA_PHASE_EXIT_TIMEOUT:-180}
INSTALL_TIMEOUT=${QA_INSTALL_TIMEOUT:-900}

HOSTMANAGER=${QA_HOST_MANAGER:-24545}

# --- measured state, written out after every phase --------------------------
M_HEALTH=null
M_RSS=null
M_RSS_STEADY=null
M_INSTALLED_HEALTH=null
M_INSTALLED_SECOND_HEALTH=null
M_INSTALL=null
M_BOOTS=0
M_PERSIST=none
M_INSTALLED=no
V_IMAGE=unknown
V_IMAGE_SOURCE=none
V_GUEST=unknown
V_REPO=unknown
V_MATCH=unknown

json_str() {
	case "$1" in
		'') printf '"unknown"' ;;
		*) printf '"%s"' "$(printf '%s' "$1" | tr -d '"\\')" ;;
	esac
}

json_num() {
	case "$1" in
		''|null) printf 'null' ;;
		*) printf '%s' "$1" ;;
	esac
}

write_device() {
	{
		printf '{\n'
		printf '  "l5.health_s": %s,\n' "$(json_num "$M_HEALTH")"
		printf '  "l5.host_rss_mb": %s,\n' "$(json_num "$M_RSS")"
		printf '  "l5.host_rss_steady_mb": %s,\n' "$(json_num "$M_RSS_STEADY")"
		printf '  "l5.installed_health_s": %s,\n' "$(json_num "$M_INSTALLED_HEALTH")"
		printf '  "l5.installed_second_health_s": %s,\n' "$(json_num "$M_INSTALLED_SECOND_HEALTH")"
		printf '  "l5.install_s": %s,\n' "$(json_num "$M_INSTALL")"
		printf '  "l5.boots": %s,\n' "$M_BOOTS"
		printf '  "l5.installed": %s,\n' "$(json_str "$M_INSTALLED")"
		printf '  "l5.persistence": %s,\n' "$(json_str "$M_PERSIST")"
		printf '  "l5.image_version": %s,\n' "$(json_str "$V_IMAGE")"
		printf '  "l5.guest_version": %s,\n' "$(json_str "$V_GUEST")"
		printf '  "l5.repo_version": %s,\n' "$(json_str "$V_REPO")"
		printf '  "l5.version_match": %s\n' "$(json_str "$V_MATCH")"
		printf '}\n'
	} > "$RES/device.json"
}

# --- tools ------------------------------------------------------------------
QEMU=
if [ "$MODE" != version ]; then
	QEMU=$(command -v qemu-system-x86_64 || true)
	if [ -z "$QEMU" ]; then
		echo "qa-qemu: qemu-system-x86_64 is not installed" >&2
		exit 2
	fi
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
if [ "$MODE" != version ] && { [ -z "$CODE" ] || [ -z "$VARS" ]; }; then
	echo "qa-qemu: UEFI firmware not found (install edk2-ovmf)" >&2
	exit 2
fi

NBD=${QA_NBD:-}
NBD_DEV=
NBD_ATTACHED=0
NBD_MNT=$OUT/nbd-mnt
QPID=
DRIVER_PID=
LIVE_DISK=
TARGET=$OUT/target.qcow2

cleanup() {
	if [ -n "${DRIVER_PID:-}" ]; then
		kill "$DRIVER_PID" 2>/dev/null || true
		wait "$DRIVER_PID" 2>/dev/null || true
		DRIVER_PID=
	fi
	if [ -n "${QPID:-}" ]; then
		kill "$QPID" 2>/dev/null || true
		wait "$QPID" 2>/dev/null || true
		QPID=
	fi
	detach_nbd
}
trap cleanup EXIT INT TERM

# --- read-only inspection of a disk image -----------------------------------
attach_nbd() {
	# $1 = image file, $2 = ro|rw
	command -v qemu-nbd >/dev/null 2>&1 || return 1
	sudo -n true 2>/dev/null || return 1
	sudo -n modprobe nbd max_part=8 2>/dev/null || true
	# A device the kernel still lists a pid for is in use; and a wedged one
	# (I/O errors after a stale qemu-nbd) cannot be reused at all, so take the
	# first free device instead of insisting on nbd0.
	if [ -z "$NBD" ]; then
		NBD_AUTO=1
		i=0
		while [ "$i" -lt 16 ]; do
			if [ -b "/dev/nbd$i" ] && [ ! -e "/sys/block/nbd$i/pid" ]; then
				NBD=/dev/nbd$i
				break
			fi
			i=$((i + 1))
		done
	fi
	[ -n "$NBD" ] && [ -b "$NBD" ] || return 1
	sudo -n qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
	if [ "$2" = "ro" ]; then
		sudo -n qemu-nbd --read-only --connect="$NBD" "$1" 2>/dev/null || return 1
	else
		sudo -n qemu-nbd --connect="$NBD" "$1" 2>/dev/null || return 1
	fi
	NBD_DEV=$NBD
	NBD_ATTACHED=1
	i=0
	while [ "$i" -lt 40 ]; do
		[ -b "${NBD_DEV}p1" ] && break
		i=$((i + 1))
		sleep 0.25
	done
	return 0
}

detach_nbd() {
	if [ "$NBD_ATTACHED" = 1 ]; then
		sudo -n umount "$NBD_MNT" >/dev/null 2>&1 || true
		sudo -n qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
		NBD_ATTACHED=0
		NBD_DEV=
		if [ "${NBD_AUTO:-0}" = 1 ]; then NBD=; NBD_AUTO=0; fi
	fi
}

find_root_part() {
	ROOTPART=
	for p in "$NBD_DEV"p*; do
		[ -b "$p" ] || continue
		# lsblk reads the partition's label the way `blkid -L` does not: an
		# nbd-backed partition is not in udev's database yet.
		lab=$(lsblk -rno LABEL "$p" 2>/dev/null | head -n 1 | tr 'A-Z' 'a-z' || true)
		if [ "$lab" = "jawnos-root" ]; then
			ROOTPART=$p
			break
		fi
	done
	# The repart order is fixed (esp, root, state): p2 is the root of every
	# image this tree builds, so a label udev has not published must not make
	# the version unreadable.
	if [ -z "$ROOTPART" ] && [ -b "${NBD_DEV}p2" ]; then
		ROOTPART=${NBD_DEV}p2
	fi
	[ -n "$ROOTPART" ]
}

read_first() {
	# the first non-empty value of the named files under $NBD_MNT
	for f in "$@"; do
		if sudo -n test -f "$NBD_MNT/$f" 2>/dev/null; then
			v=$(sudo -n cat "$NBD_MNT/$f" 2>/dev/null | tr -d ' \t\r\n' || true)
			if [ -n "$v" ]; then
				printf '%s\n' "$v"
				return 0
			fi
		fi
	done
	return 1
}

image_version() {
	if command -v guestmount >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
		sudo -n mkdir -p "$NBD_MNT" || true
		if sudo -n guestmount --add "$IMG" --ro "$NBD_MNT" 2>/dev/null; then
			v=$(read_first etc/jawnos/VERSION opt/jawnos/tree/VERSION \
				home/jawn/jawnos/VERSION || true)
			sudo -n guestunmount "$NBD_MNT" 2>/dev/null || true
			if [ -n "$v" ]; then
				V_IMAGE=$v
				V_IMAGE_SOURCE=guestmount
				return 0
			fi
		fi
	fi
	attach_nbd "$IMG" ro || return 1
	if ! find_root_part || ! sudo -n mkdir -p "$NBD_MNT" \
		|| ! sudo -n mount -o ro "$ROOTPART" "$NBD_MNT"; then
		detach_nbd
		return 1
	fi
	v=$(read_first etc/jawnos/VERSION opt/jawnos/tree/VERSION home/jawn/jawnos/VERSION || true)
	sudo -n umount "$NBD_MNT" 2>/dev/null || true
	detach_nbd
	[ -n "$v" ] || return 1
	V_IMAGE=$v
	V_IMAGE_SOURCE="qemu-nbd $ROOTPART"
	return 0
}

version_check() {
	V_REPO=$(cat "$REPO/VERSION" 2>/dev/null | tr -d ' \t\r\n' || true)
	[ -n "$V_REPO" ] || V_REPO=${QA_REPO_VERSION:-unknown}
	image_version || true
	if [ "$V_IMAGE" = unknown ] || [ "$V_REPO" = unknown ]; then
		V_MATCH=unknown
	elif [ "$V_IMAGE" = "$V_REPO" ]; then
		V_MATCH=yes
	else
		V_MATCH=no
	fi
	{
		printf 'image %s\n' "$IMG"
		printf 'image_bytes %s\n' "$(wc -c < "$IMG")"
		printf 'image_version %s\n' "$V_IMAGE"
		printf 'image_version_source %s\n' "$V_IMAGE_SOURCE"
		printf 'repo_version %s\n' "$V_REPO"
		printf 'repo_path %s\n' "$REPO"
		printf 'version_match %s\n' "$V_MATCH"
	} > "$OUT/version.txt"
	cat "$OUT/version.txt"
}

# --- the throwaway live disk ------------------------------------------------
image_format() {
	# qemu-img 11 nests the protocol node (`"format": "file"`) above the driver
	# node, so the last match is the image's own format.
	qemu-img info --output=json "$1" 2>/dev/null \
		| grep -o '"format": *"[a-z0-9]*"' | tail -n 1 \
		| sed 's/.*"\([a-z0-9]*\)"$/\1/'
}

prepare_live_overlay() {
	LIVE_DISK=$OUT/live-overlay.qcow2
	FMT=$(image_format "$IMG")
	[ -n "$FMT" ] || FMT=raw
	rm -f "$LIVE_DISK"
	if ! qemu-img create -f qcow2 -F "$FMT" -b "$IMG" "$LIVE_DISK" >/dev/null; then
		echo "qa-qemu: could not create the live overlay" >&2
		return 1
	fi
	if ! attach_nbd "$LIVE_DISK" rw; then
		echo "qa-qemu: could not attach the live overlay (needs sudo and qemu-nbd)" >&2
		return 1
	fi
	if ! find_root_part || ! sudo -n mkdir -p "$NBD_MNT" \
		|| ! sudo -n mount "$ROOTPART" "$NBD_MNT"; then
		echo "qa-qemu: could not mount the overlay's root read-write" >&2
		detach_nbd
		return 1
	fi
	D=$NBD_MNT/etc/systemd/system/serial-getty@ttyS0.service.d
	sudo -n mkdir -p "$D"
	printf '%s\n' \
		'[Service]' \
		'ExecStart=' \
		'ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM' \
		| sudo -n tee "$D/autologin.conf" >/dev/null
	sudo -n sync
	if ! sudo -n umount "$NBD_MNT"; then
		echo "qa-qemu: could not unmount the overlay's root" >&2
		detach_nbd
		return 1
	fi
	detach_nbd
	return 0
}

prepare_target() {
	rm -f "$TARGET"
	qemu-img create -f qcow2 "$TARGET" 16G >/dev/null
}

# --- one boot at a time -----------------------------------------------------
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	ACCEL="-enable-kvm -cpu host"
else
	ACCEL="-accel tcg,thread=multi -cpu max"
fi

rss_peak_mb() {
	awk '/^VmHWM:/{print int($2 / 1024)}' "/proc/$QPID/status" 2>/dev/null || true
}

rss_now_mb() {
	awk '/^VmRSS:/{print int($2 / 1024)}' "/proc/$QPID/status" 2>/dev/null || true
}

pid_alive() {
	# kill -0 also succeeds for a zombie, and a child the shell has not reaped
	# yet is exactly that. Every wait loop here has to see "gone".
	[ -n "${1:-}" ] || return 1
	st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ' || true)
	[ -n "$st" ] || return 1
	case "$st" in Z*) return 1 ;; esac
	return 0
}

max_rss() {
	case "${1:-}" in ''|unknown|null) return 0 ;; esac
	case "$M_RSS" in
		null) M_RSS=$1; return 0 ;;
	esac
	[ "$1" -gt "$M_RSS" ] 2>/dev/null && M_RSS=$1
	return 0
}

start_phase() {
	# start_phase LABEL HOSTPORT VARSFILE DISKARGS STEPSFILE
	P_LABEL=$1
	P_PORT=$2
	P_VARS=$3
	P_DISKS=$4
	P_STEPS=$5
	P_SOCK=$OUT/serial-$P_LABEL.sock
	P_QMP=$OUT/qmp-$P_LABEL.sock
	P_LOG=$OUT/serial-$P_LABEL.log
	rm -f "$P_SOCK" "$P_QMP" "$OUT/phase.done" "$OUT/install.req"
	: > "$P_LOG"

	# shellcheck disable=SC2086
	"$QEMU" \
		-name "JawnOS QA $P_LABEL" \
		-machine q35 $ACCEL \
		-m "$RAM" -smp "$CPUS" \
		-drive if=pflash,format=raw,readonly=on,file="$CODE" \
		-drive if=pflash,format=raw,file="$P_VARS" \
		$P_DISKS \
		-display none \
		-chardev "socket,id=ser0,path=$P_SOCK,server=on,wait=off" \
		-serial chardev:ser0 \
		-qmp "unix:$P_QMP,server=on,wait=off" \
		-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$P_PORT-:45545" \
		-device virtio-net-pci,netdev=net0 \
		>"$OUT/qemu-$P_LABEL.log" 2>&1 &
	QPID=$!

	perl "$QA/serial.pl" \
		--socket "$P_SOCK" --log "$P_LOG" \
		--status "$OUT/serial-$P_LABEL.status" \
		--steps "$P_STEPS" --timeout "$STEP_TIMEOUT" \
		>"$OUT/serial-$P_LABEL.driver.log" 2>&1 &
	DRIVER_PID=$!
}

wait_health() {
	hp=$1
	limit=$2
	t0=$(date +%s)
	code=
	up=0
	while :; do
		code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 2 \
			"https://127.0.0.1:$hp/manager/health" 2>/dev/null || true)
		case "$code" in
			2*|3*|4*) up=1; break ;;
		esac
		if [ $(( $(date +%s) - t0 )) -ge "$limit" ]; then break; fi
		if ! pid_alive "$QPID"; then break; fi
		sleep 2
	done
	HEALTH_UP=$up
	HEALTH_S=$(( $(date +%s) - t0 ))
	HEALTH_CODE=${code:-000}
}

wait_vm_gone() {
	limit=$1
	# A console driver that already gave up will never type `poweroff`; do not
	# sit out the whole grace period waiting for it.
	if [ -n "${DRIVER_PID:-}" ] && ! pid_alive "$DRIVER_PID"; then
		limit=0
	fi
	i=0
	while pid_alive "$QPID"; do
		[ "$i" -ge "$limit" ] && break
		i=$((i + 1))
		sleep 1
	done
	if pid_alive "$QPID"; then
		perl "$QA/qmp.pl" --socket "$P_QMP" powerdown \
			>>"$P_LOG" 2>&1 || true
		i=0
		while pid_alive "$QPID"; do
			[ "$i" -ge 45 ] && break
			i=$((i + 1))
			sleep 1
		done
	fi
	if pid_alive "$QPID"; then
		echo "killed (would not power off)" > "$OUT/poweroff-$P_LABEL.txt"
		kill "$QPID" 2>/dev/null || true
	else
		echo "powered off" > "$OUT/poweroff-$P_LABEL.txt"
	fi
	wait "$QPID" 2>/dev/null || true
	QPID=
}

finish_phase() {
	if [ -n "${1:-}" ]; then touch "$OUT/$1"; fi
	wait_vm_gone "$2"
	if [ -n "${DRIVER_PID:-}" ]; then
		wait "$DRIVER_PID" 2>/dev/null || true
		DRIVER_PID=
	fi
}

driver_verdict() {
	tail -n 1 "$OUT/serial-$P_LABEL.status" 2>/dev/null | awk '{print $2}' || true
}

# --- what the image printed, and what the session saw -----------------------
markers() {
	# Counted on the transcript up to the first harness line, so the counts are
	# what the *image* printed and not the echo of a command we typed.
	lf=$OUT/serial-$P_LABEL.log
	bf=$OUT/serial-$P_LABEL.boot.log
	# The prompt does not end in a newline, so the harness's own line lands after
	# it on the same line: split on the marker wherever it is.
	sed '/#QA send:/q' "$lf" > "$bf" 2>/dev/null || : > "$bf"
	c() { grep -aFc "$1" "$bf" 2>/dev/null || true; }
	printf 'boot_marker_welcome %s\n' "$(c 'Welcome to JawnOS')"
	printf 'boot_marker_login_prompt %s\n' "$(c 'login:')"
	printf 'boot_marker_firstboot %s\n' "$(c 'jawnos-firstboot')"
	printf 'boot_marker_manager %s\n' "$(c 'manager')"
	printf 'boot_marker_health %s\n' "$(c 'manager/health')"
	printf 'boot_marker_session_prompt %s\n' "$(c 'root@')"
}

session_evidence() {
	lf=$OUT/serial-$P_LABEL.log
	printf 'session_first_command %s\n' \
		"$(grep -am 1 '#QA send:' "$lf" 2>/dev/null | sed 's/.*#QA send: //' | cut -c1-150 || true)"
	printf 'session_health_code %s\n' "${P_GUEST_HEALTH:-none}"
	printf 'session_house_bytes %s\n' "${P_HOUSE_BYTES:-none}"
	printf 'session_manager_line %s\n' "${P_MANAGER_LINE:-none}"
}

phase_report() {
	o=$OUT/phase-$P_LABEL.txt
	{
		printf 'phase %s\n' "$P_LABEL"
		printf 'image %s\n' "$IMG"
		printf 'acceleration %s\n' "$(printf '%s' "$ACCEL" | sed 's/ -cpu.*//')"
		printf 'ram_mb %s cpus %s\n' "$RAM" "$CPUS"
		if [ "$HEALTH_UP" = 1 ]; then
			printf 'health up after %ss (http %s)\n' "$HEALTH_S" "$HEALTH_CODE"
		else
			printf 'health NEVER answered after %ss\n' "$HEALTH_S"
		fi
		printf 'host_rss_peak_mb %s\n' "${P_RSS:-unknown}"
		printf 'host_rss_steady_mb %s\n' "${P_RSS_NOW:-unknown}"
		printf 'serial_driver %s\n' "${P_DRIVER:-unknown}"
		printf 'poweroff %s\n' "$(cat "$OUT/poweroff-$P_LABEL.txt" 2>/dev/null || echo unknown)"
		markers
		session_evidence
	} > "$o"
	{
		printf '=== %s ===\n' "$P_LABEL"
		sed -n '1,200p' "$o" | sed '1d'
	} >> "$OUT/qemu.txt"
	echo "$o"
}

record_boot() {
	lf=$OUT/serial-$P_LABEL.log
	P_GUEST_VERSION=$(grep -ao 'QA-SESSION-[0-9][0-9.]*' "$lf" 2>/dev/null \
		| tail -n 1 | sed 's/^QA-SESSION-//' || true)
	[ -n "$P_GUEST_VERSION" ] || P_GUEST_VERSION=unknown
	P_GUEST_HEALTH=$(grep -ao 'QA-GUEST-HEALTH-[0-9][0-9][0-9]' "$lf" 2>/dev/null \
		| tail -n 1 | sed 's/^QA-GUEST-HEALTH-//' || true)
	P_HOUSE_BYTES=$(grep -ao 'QA-HOUSE-OK-[0-9]*' "$lf" 2>/dev/null \
		| tail -n 1 | sed 's/^QA-HOUSE-OK-//' || true)
	# The manager's own last log line, printed through the shell so it is one
	# line and not a file dump. The `%s` guard keeps the command's echo out.
	P_MANAGER_LINE=$(grep -a 'QA-MANAGER ' "$lf" 2>/dev/null \
		| grep -av 'QA-MANAGER %' | tail -n 1 \
		| sed 's/.*QA-MANAGER //' | cut -c1-140 || true)
	if [ "$V_GUEST" = unknown ] && [ "$P_GUEST_VERSION" != unknown ]; then
		V_GUEST=$P_GUEST_VERSION
	fi
}

# --- step files -------------------------------------------------------------
# Each `send` is one line for the guest's shell. Guest-side `$( )`, `%{ }` and
# single quotes are literal here (the heredocs are quoted). A marker the guest
# prints is distinguished from the console echo of the command by a regex the
# echo cannot match: `QA-X-N` never appears in `QA-X-$( )`.

manager_line_cmd='m=$(tail -n 1 /home/jawn/manager.log 2>/dev/null | tr -d "\r"); printf "QA-MANAGER %s\n" "$m"; printf "QA-LOG-LINE-END-%s\n" ok'

steps_boot() {
	cat > "$OUT/steps-$1.txt" <<EOF
expect root@ 240
send while [ ! -f /home/jawn/.seeded ]; do sleep 3; done; printf 'QA-SEEDED-%s\n' ok
expect QA-SEEDED-ok 600
send echo QA-SESSION-\$(cat /home/jawn/jawnos/VERSION 2>/dev/null || cat /opt/jawnos/tree/VERSION); systemctl is-system-running; curl -k -s -o /dev/null -w "QA-GUEST-HEALTH-%{http_code}\n" https://127.0.0.1:45545/manager/health; test -s /home/jawn/jawnos/database/jawnos.db && echo QA-HOUSE-OK-\$(stat -c %s /home/jawn/jawnos/database/jawnos.db)
expect QA-HOUSE-OK-[0-9] 120
send $manager_line_cmd
expect QA-LOG-LINE-END-ok 60
until-file phase.done
send sync
sleep 2
send poweroff -f
EOF
}

steps_contract() {
	cat > "$OUT/steps-$1.txt" <<EOF
expect root@ 240
send while [ ! -f /home/jawn/.seeded ]; do sleep 3; done; printf 'QA-SEEDED-%s\n' ok
expect QA-SEEDED-ok 600
send echo QA-SESSION-\$(cat /home/jawn/jawnos/VERSION 2>/dev/null || cat /opt/jawnos/tree/VERSION); systemctl is-system-running; curl -k -s -o /dev/null -w "QA-GUEST-HEALTH-%{http_code}\n" https://127.0.0.1:45545/manager/health; test -s /home/jawn/jawnos/database/jawnos.db && echo QA-HOUSE-OK-\$(stat -c %s /home/jawn/jawnos/database/jawnos.db)
expect QA-HOUSE-OK-[0-9] 120
send $manager_line_cmd
expect QA-LOG-LINE-END-ok 60
until-file install.req
send lsblk -dno NAME,SIZE /dev/vdb; printf 'QA-TARGET-%s\n' "\$(lsblk -dno SIZE /dev/vdb 2>/dev/null | tr -d ' ')"
expect QA-TARGET-[^%] 60
send jawnos-install --yes /dev/vdb
expect (?i)done\. Remove the live media 1200
send sync
sleep 3
send poweroff -f
EOF
}

steps_installed_first() {
	cat > "$OUT/steps-$1.txt" <<EOF
expect root@ 240
send date +%s > /home/jawn/.qa-boot1; printf 'QA-BOOTMARK %s\n' "\$(cat /home/jawn/.qa-boot1)"
expect QA-BOOTMARK [0-9] 60
send echo QA-SESSION-\$(cat /home/jawn/jawnos/VERSION 2>/dev/null || echo unknown); curl -k -s -o /dev/null -w "QA-GUEST-HEALTH-%{http_code}\n" https://127.0.0.1:45545/manager/health; test -s /home/jawn/jawnos/database/jawnos.db && echo QA-HOUSE-OK-\$(stat -c %s /home/jawn/jawnos/database/jawnos.db)
expect QA-HOUSE-OK-[0-9] 120
send $manager_line_cmd
expect QA-LOG-LINE-END-ok 60
until-file phase.done
send sync
sleep 2
send poweroff -f
EOF
}

steps_installed_second() {
	cat > "$OUT/steps-$1.txt" <<EOF
expect root@ 240
send test -s /home/jawn/.qa-boot1 && printf 'QA-PERSIST %s\n' "\$(cat /home/jawn/.qa-boot1)" || echo QA-PERSIST MISSING
expect QA-PERSIST [0-9] 60
send echo QA-SESSION-\$(cat /home/jawn/jawnos/VERSION 2>/dev/null || echo unknown); curl -k -s -o /dev/null -w "QA-GUEST-HEALTH-%{http_code}\n" https://127.0.0.1:45545/manager/health; test -s /home/jawn/jawnos/database/jawnos.db && echo QA-HOUSE-OK-\$(stat -c %s /home/jawn/jawnos/database/jawnos.db)
expect QA-HOUSE-OK-[0-9] 120
send $manager_line_cmd
expect QA-LOG-LINE-END-ok 60
until-file phase.done
send sync
sleep 2
send poweroff -f
EOF
}

# --- phases -----------------------------------------------------------------
phase_boot() {
	PORT=$HOSTMANAGER
	cp -f "$VARS" "$OUT/vars-boot.fd"
	steps_boot boot
	start_phase boot "$PORT" "$OUT/vars-boot.fd" \
		"-drive file=$LIVE_DISK,format=qcow2,if=virtio,snapshot=on" \
		"$OUT/steps-boot.txt"
	wait_health "$PORT" "$HEALTH_TIMEOUT"
	P_RSS=$(rss_peak_mb)
	P_RSS_NOW=$(rss_now_mb)
	[ -n "$P_RSS_NOW" ] || P_RSS_NOW=unknown
	[ "$M_RSS_STEADY" = null ] && M_RSS_STEADY=$P_RSS_NOW
	[ -n "$P_RSS" ] || P_RSS=unknown
	max_rss "$P_RSS"
	M_BOOTS=1
	[ "$HEALTH_UP" = 1 ] && M_HEALTH=$HEALTH_S
	finish_phase phase.done "$PHASE_EXIT_TIMEOUT"
	P_DRIVER=$(driver_verdict)
	[ -n "$P_DRIVER" ] || P_DRIVER=unknown
	record_boot
	phase_report
	write_device
	return 0
}

phase_contract_live() {
	PORT=$HOSTMANAGER
	cp -f "$VARS" "$OUT/vars-install.fd"
	steps_contract contract
	start_phase contract "$PORT" "$OUT/vars-install.fd" \
		"-drive file=$LIVE_DISK,format=qcow2,if=virtio,snapshot=on -drive file=$TARGET,format=qcow2,if=virtio" \
		"$OUT/steps-contract.txt"
	wait_health "$PORT" "$HEALTH_TIMEOUT"
	P_RSS=$(rss_peak_mb)
	P_RSS_NOW=$(rss_now_mb)
	[ -n "$P_RSS_NOW" ] || P_RSS_NOW=unknown
	[ "$M_RSS_STEADY" = null ] && M_RSS_STEADY=$P_RSS_NOW
	[ -n "$P_RSS" ] || P_RSS=unknown
	max_rss "$P_RSS"
	M_BOOTS=1
	[ "$HEALTH_UP" = 1 ] && M_HEALTH=$HEALTH_S

	# The installer runs only after the image has answered health, so the house
	# it carries is the one this boot seeded.
	INSTALL_T0=$(date +%s)
	touch "$OUT/install.req"
	i=0
	while [ "$i" -lt "$INSTALL_TIMEOUT" ]; do
		if grep -aq 'Remove the live media' "$OUT/serial-contract.log" 2>/dev/null; then
			M_INSTALL=$(( $(date +%s) - INSTALL_T0 ))
			break
		fi
		if ! pid_alive "$QPID"; then break; fi
		# a driver that died (no console login) will never send the install
		if [ -n "${DRIVER_PID:-}" ] && ! pid_alive "$DRIVER_PID"; then break; fi
		i=$((i + 1))
		sleep 1
	done
	finish_phase "" "$PHASE_EXIT_TIMEOUT"
	P_DRIVER=$(driver_verdict)
	[ -n "$P_DRIVER" ] || P_DRIVER=unknown
	if grep -aq 'Remove the live media' "$OUT/serial-contract.log" 2>/dev/null; then
		M_INSTALLED=yes
	fi
	record_boot
	phase_report
	write_device
	[ "$M_INSTALLED" = yes ]
}

phase_installed() {
	# phase_installed LABEL STEPSFUNC HOSTPORT
	P_LAST=$1
	$2 "$P_LAST"
	start_phase "$P_LAST" "$3" "$OUT/vars-install.fd" \
		"-drive file=$TARGET,format=qcow2,if=virtio" \
		"$OUT/steps-$P_LAST.txt"
	wait_health "$3" "$HEALTH_TIMEOUT"
	P_RSS=$(rss_peak_mb)
	P_RSS_NOW=$(rss_now_mb)
	[ -n "$P_RSS_NOW" ] || P_RSS_NOW=unknown
	[ "$M_RSS_STEADY" = null ] && M_RSS_STEADY=$P_RSS_NOW
	[ -n "$P_RSS" ] || P_RSS=unknown
	max_rss "$P_RSS"
	M_BOOTS=$((M_BOOTS + 1))
	finish_phase phase.done "$PHASE_EXIT_TIMEOUT"
	P_DRIVER=$(driver_verdict)
	[ -n "$P_DRIVER" ] || P_DRIVER=unknown
	record_boot
	phase_report
	write_device
}

# --- main -------------------------------------------------------------------
version_check
if [ "$MODE" = version ]; then
	exit 0
fi

if ! prepare_live_overlay; then
	echo "qa-qemu: cannot boot with a drivable serial console (needs qemu-img + sudo qemu-nbd)" >&2
	exit 2
fi

: > "$OUT/qemu.txt"
printf 'harness_overlay serial-getty@ttyS0 autologin (root is locked in the shipped image)\n' \
	>> "$OUT/qemu.txt"

if [ "$MODE" = contract ]; then
	if ! prepare_target; then
		echo "qa-qemu: cannot create the install target" >&2
		exit 2
	fi
	if ! phase_contract_live; then
		echo "qa-qemu: the installer did not finish; see $OUT/serial-contract.log" >&2
		echo "qa-qemu: the phase evidence is in $OUT/phase-contract.txt" >&2
		exit 1
	fi
	phase_installed installed-first steps_installed_first "$((HOSTMANAGER + 1))"
	[ "$HEALTH_UP" = 1 ] && M_INSTALLED_HEALTH=$HEALTH_S
	[ "$M_PERSIST" = none ] && M_PERSIST=pending
	write_device
	phase_installed installed-second steps_installed_second "$((HOSTMANAGER + 2))"
	[ "$HEALTH_UP" = 1 ] && M_INSTALLED_SECOND_HEALTH=$HEALTH_S
	if grep -aq 'QA-PERSIST [0-9]' "$OUT/serial-installed-second.log" 2>/dev/null; then
		M_PERSIST=yes
	else
		M_PERSIST=no
	fi
	write_device
else
	phase_boot
fi

write_device

echo "qa-qemu: $OUT"
echo "qa-qemu: version image=$V_IMAGE repo=$V_REPO match=$V_MATCH"
case "$M_HEALTH" in
	null) echo "qa-qemu: health never answered (see $OUT/serial-*.log)" ;;
	*) echo "qa-qemu: health ${M_HEALTH}s, host peak ${M_RSS} MB" ;;
esac
if [ "$MODE" = contract ]; then
	echo "qa-qemu: installed=$M_INSTALLED install=${M_INSTALL}s first=${M_INSTALLED_HEALTH}s second=${M_INSTALLED_SECOND_HEALTH}s persistence=$M_PERSIST"
fi
echo "qa-qemu: metrics $RES/device.json"

if [ "$M_HEALTH" = null ]; then
	echo "qa-qemu: FAIL - the image never answered health" >&2
	exit 1
fi
if [ "$MODE" = contract ]; then
	if [ "$M_INSTALLED" != yes ] || [ "$M_INSTALLED_HEALTH" = null ] || [ "$M_PERSIST" != yes ]; then
		echo "qa-qemu: FAIL - installed=$M_INSTALLED first=${M_INSTALLED_HEALTH}s persistence=$M_PERSIST" >&2
		exit 1
	fi
fi
exit 0
