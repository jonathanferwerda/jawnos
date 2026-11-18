#!/bin/sh
# After a warm reboot the Realtek 8821CU combo adapter sometimes fails to
# re-enumerate, so wlan0 never appears and the box looks dead until it is
# power-cycled. Force a port reset and reload the driver, then let
# NetworkManager try again.
#
# gou-wifi-reset.service runs this at boot and gou-wifi-reset.timer runs it
# again every minute, so a board that lost the adapter after the boot pass is
# recovered without a hand on the power switch. A run with wlan0 already up
# changes nothing and exits at once.
set -u

# The adapter's own USB port, then any port it enumerated on after a reboot.
DEV=${GOU_WIFI_DEV:-/sys/bus/usb/devices/1-1}
IFACE=${GOU_WIFI_IFACE:-wlan0}
TRIES=${GOU_WIFI_TRIES:-20}

find_device() {
	if [ -w "$DEV/authorized" ]; then
		echo "$DEV"
		return 0
	fi
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		[ -f "$d/idProduct" ] || continue
		[ "$(cat "$d/idVendor")" = "0bda" ] || continue
		[ "$(cat "$d/idProduct")" = "c820" ] || continue
		[ -w "$d/authorized" ] || continue
		echo "$d"
		return 0
	done
	return 1
}

link_up() {
	[ -e "/sys/class/net/$IFACE" ] && return 0
	# The interface name is not the point: any wireless link means the
	# adapter enumerated, and a renamed one must not be reset every minute.
	for n in /sys/class/net/*; do
		[ -e "$n/wireless" ] && return 0
	done
	return 1
}

wait_link() {
	i=0
	while [ "$i" -lt "$TRIES" ]; do
		link_up && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# Normal case: the interface showed up on its own.
wait_link && exit 0

# No adapter to reset (this board has no dongle, or it is not in the tree).
DEV=$(find_device) || exit 0

logger -t gou-wifi "$IFACE missing after boot, resetting $DEV"
if [ -w "$DEV/authorized" ]; then
	echo 0 > "$DEV/authorized"
	sleep 1
	echo 1 > "$DEV/authorized"
	sleep 2
fi

modprobe -r rtw88_8821cu 2>/dev/null
sleep 1
modprobe rtw88_8821cu 2>/dev/null

wait_link && exit 0

logger -t gou-wifi "$IFACE still missing, restarting NetworkManager"
systemctl restart NetworkManager
wait_link && exit 0

logger -t gou-wifi "$IFACE did not come up"
exit 1
