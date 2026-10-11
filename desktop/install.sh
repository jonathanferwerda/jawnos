#!/bin/sh
# Install the JawnOS desktop app for the current user. No root required.
#
#   ./desktop/install.sh                 # app + CLI + dashboard into ~/.local
#   ./desktop/install.sh --autostart     # also start the BLE bridge at login
#   ./desktop/install.sh --systemd       # also install systemd --user units
#
# Everything lands under ~/.local, so removing it is just deleting the
# directories this prints at the end.
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DESKTOP_SRC="$REPO_ROOT/desktop"
DEST="$HOME/.local/share/jawnos/desktop"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
UNITS="$HOME/.config/systemd/user"

JAWN_DIR=${JAWNOS_DIR:-$REPO_ROOT}

WITH_AUTOSTART=0
WITH_SYSTEMD=0
for arg in "$@"; do
	case "$arg" in
		--autostart) WITH_AUTOSTART=1 ;;
		--systemd) WITH_SYSTEMD=1 ;;
		-h|--help)
			sed -n '2,9p' "$0"
			exit 0
			;;
		*) echo "install.sh: unknown option $arg" >&2; exit 2 ;;
	esac
done

PYTHON=${PYTHON:-$(command -v python3 || true)}
PERL=${PERL:-$(command -v perl || true)}
if [ -z "$PYTHON" ]; then
	echo "install.sh: python3 is required" >&2
	exit 1
fi

# --- dependency sanity (warn, do not fail: distro package names differ) -----
missing=""
"$PYTHON" -c 'import gi' 2>/dev/null || missing="$missing python3-gi"
"$PYTHON" -c 'import dbus' 2>/dev/null || missing="$missing python3-dbus"
if [ -n "$missing" ]; then
	echo "install.sh: warning - missing:$missing"
	echo "  the CLI still works; the dashboard needs PyGObject (python3-gi) and"
	echo "  the BLE bridge needs python3-dbus. Install them with your package manager."
fi
if ! command -v bluetoothctl >/dev/null 2>&1; then
	echo "install.sh: warning - bluez not found; the BLE bridge needs it"
fi

# --- copy the tree ----------------------------------------------------------
echo "Installing to $DEST"
mkdir -p "$DEST"
cp -R "$DESKTOP_SRC/." "$DEST/"
find "$DEST" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
chmod +x "$DEST/jawnosctl" "$DEST/jawnos-desktop" "$DEST/jawnos-bt-daemon"

# --- entry points -----------------------------------------------------------
mkdir -p "$BIN"
for tool in jawnosctl jawnos-desktop jawnos-bt-daemon; do
	ln -sf "$DEST/$tool" "$BIN/$tool"
done
echo "Linked jawnosctl, jawnos-desktop, jawnos-bt-daemon into $BIN"

# --- icon and desktop entry -------------------------------------------------
mkdir -p "$ICON_DIR" "$APPS"
cp "$DESKTOP_SRC/icons/jawnos.png" "$ICON_DIR/jawnos.png"
sed "s|@DESKTOP@|$DEST|g" "$DESKTOP_SRC/jawnos.desktop.in" > "$APPS/jawnos.desktop"
echo "Installed desktop entry and icon"

# --- remember the jawn directory -------------------------------------------
# The installed copy lives under ~/.local, not in the checkout, so store where
# jawn actually is.
"$DEST/jawnosctl" dir "$JAWN_DIR" >/dev/null

# --- systemd --user units ---------------------------------------------------
if [ "$WITH_SYSTEMD" -eq 1 ]; then
	mkdir -p "$UNITS"
	for unit in jawnos-bt jawnos; do
		sed -e "s|@PYTHON@|$PYTHON|g" \
			-e "s|@PERL@|${PERL:-/usr/bin/perl}|g" \
			-e "s|@DESKTOP@|$DEST|g" \
			-e "s|@JAWN_DIR@|$JAWN_DIR|g" \
			"$DESKTOP_SRC/systemd/$unit.service.in" > "$UNITS/$unit.service"
	done
	echo "Wrote $UNITS/jawnos-bt.service and jawnos.service"
	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user daemon-reload || true
		systemctl --user enable --now jawnos-bt.service 2>/dev/null \
			&& echo "Enabled jawnos-bt.service" \
			|| echo "Enable it with: systemctl --user enable --now jawnos-bt.service"
		echo "For jawn itself: systemctl --user enable --now jawnos.service"
	fi
fi

# --- XDG autostart ----------------------------------------------------------
if [ "$WITH_AUTOSTART" -eq 1 ]; then
	"$DEST/jawnosctl" autostart enable
fi

echo
echo "Done."
case ":$PATH:" in
	*":$BIN:"*) ;;
	*) echo "Note: $BIN is not on your PATH; add it to use jawnosctl by name." ;;
esac
echo "Try:  jawnosctl status     (report jawn and the BLE bridge)"
echo "      jawnos-desktop       (open the dashboard)"
echo "      jawnosctl ble scan   (list nearby Bluetooth LE devices)"
