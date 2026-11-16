#!/bin/sh
# The kiosk is hidden and frozen for a game (the games marker) or stopped for
# the dark idle (the screen marker). A marker with no game behind it is left
# over from a helper that died: it would keep the virtual gamepad alive and A a
# gamepad button.
#
# gou-kiosk-guard.timer runs this every fifteen seconds, so a run that heals
# nothing is the common case and it has to count as a success. The image's
# guard ended on a window search, so on a board where the search found nothing
# the oneshot failed every fifteen seconds - a permanent black mark in
# `systemctl --failed` and a journal full of a fault that was not one. Every
# path here exits 0.
marker=/home/jawn/.presence/gou-games
[ -e /run/jawnos-screen/off ] && exit 0
if [ -e "$marker" ]; then
	if pgrep -f jawnos_game_launch >/dev/null 2>&1 || pgrep -x retroarch >/dev/null 2>&1; then
		exit 0
	fi
	rm -f "$marker"
fi

# A helper that died between boosting and restoring leaves the CPU at
# performance: hot, and a flat battery in a bag. The governor it saved is left
# in /run/jawnos-games/governor for exactly this.
if [ -e /run/jawnos-games/governor ]; then
	g=$(cat /run/jawnos-games/governor 2>/dev/null)
	[ -n "$g" ] || g=schedutil
	for p in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
		echo "$g" > "$p" 2>/dev/null
	done
	rm -f /run/jawnos-games/governor
fi

# No game owns the panel, so the kiosk has to be running, awake and on screen.
# A helper that died between hiding and showing leaves the unit frozen
# (SIGSTOP) with its window unmapped, and a frozen process never handles the
# SIGTERM a restart begins with: wake it first, then map what it draws.
systemctl kill --signal=SIGCONT jawnos-kiosk >/dev/null 2>&1
if ! systemctl is-active --quiet jawnos-kiosk; then
	systemctl start jawnos-kiosk >/dev/null 2>&1
	exit 0
fi

# As the kiosk's own account: root cannot open that display, and the shell is
# the user whose xhost grant exists. The window is looked for by class and then
# by the title the shell sets, because a class that does not match is not a
# fault - it is simply a window this guard has nothing to do to.
as_jawn() {
	setpriv --reuid=jawn --regid=jawn --init-groups env DISPLAY=:0 "$@" 2>/dev/null
}

win=$(as_jawn xdotool search --onlyvisible --class JawnOS | head -1)
[ -n "$win" ] || win=$(as_jawn xdotool search --onlyvisible --name '^JawnOS$' | head -1)
[ -n "$win" ] || exit 0

as_jawn xdotool windowmap "$win" >/dev/null 2>&1
as_jawn xdotool windowraise "$win" >/dev/null 2>&1
exit 0
