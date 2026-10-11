#!/bin/sh
# Turn a fresh Arch install into a JawnOS box (the Sway session).
#
# Run on the target machine, from the checkout, as a normal user with sudo:
#     ./desktop/wayland/bootstrap.sh
#
# It installs the graphics/session packages, the desktop app's deps, Zed, the
# JawnOS server's Perl deps, the app itself, and the sway/waybar config. It does
# NOT touch the disk layout, the bootloader, or auto-login -- install Arch first
# (the stock ISO + archinstall), then run this. See README.md.
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
say() { printf '\n== %s\n' "$*"; }

say "graphics + Wayland session"
$SUDO pacman -S --needed --noconfirm \
	mesa vulkan-intel intel-media-driver libva-utils \
	sway swaybg swayidle swaylock waybar foot fuzzel mako \
	wl-clipboard grim slurp xdg-desktop-portal-wlr polkit-gnome \
	wireplumber pipewire pipewire-pulse

say "the embedded view + media, and the editor"
$SUDO pacman -S --needed --noconfirm \
	python-gobject python-dbus webkit2gtk-4.1 bluez bluez-utils \
	gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly \
	gst-libav gst-plugin-va zed

say "the JawnOS server's Perl dependencies"
(cd "$REPO_ROOT" && perl scripts/jawnos_deps.pl --desktop --install) || true

say "the desktop app (per-user, into ~/.local)"
"$REPO_ROOT/desktop/install.sh"

say "sway + waybar config"
mkdir -p "$HOME/.config/sway" "$HOME/.config/waybar"
# Point the session at this checkout, wherever it actually is.
sed "s|set \$jawnos .*|set \$jawnos $REPO_ROOT|" \
	"$REPO_ROOT/desktop/wayland/sway.conf" > "$HOME/.config/sway/config"
install -m 0644 "$REPO_ROOT/desktop/wayland/waybar.conf" "$HOME/.config/waybar/config"
chmod +x "$REPO_ROOT/desktop/wayland/jawnos-session"

cat <<'NEXT'

== done. Next steps
1. Create JawnOS's config + database (the first-run wizard, web based):
       cd <this checkout> && ./jawn
   then stop it (Ctrl+C) and continue.
2. Start the session from a TTY:
       exec sway
   (Zed, foot and anything else float and drag; waybar lists them.)
3. Optional, auto-start on boot -- an autologin drop-in for tty1:
       sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
       printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$USER" \
         | sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf
   and, in ~/.bash_profile:
       [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = /dev/tty1 ] && exec dbus-run-session sway
4. Wayland input for the teletype: install `dotool` (AUR) or `wtype`.
NEXT
