# The live session: tty1 starts Sway, and Sway starts JawnOS. The tree is the
# read-only copy the image carries; the first boot copies it onto the state
# partition, and this path then points at the writable house.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ]; then
    export JAWNOSCTL=/home/jawn/jawnos/desktop/jawnosctl
    export JAWNOS_APP=/home/jawn/jawnos/desktop/jawnos-desktop
    exec sway -c /home/jawn/.config/sway/config
fi
