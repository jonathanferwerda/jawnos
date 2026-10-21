#!/bin/sh
# Install the JawnOS desktop app for the current user. No root required
# (except the optional --input-access grant, which needs sudo once).
#
#   ./desktop/install.sh                 # app + CLI + dashboard into ~/.local
#   ./desktop/install.sh --autostart     # also start the BLE bridge at login
#   ./desktop/install.sh --systemd       # also install systemd --user units
#   ./desktop/install.sh --input-access  # let the desk read all keyboards/mice
#   ./desktop/install.sh --headless      # a server: CLI only, plus a SYSTEM
#                                        # service (installing it needs root)
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
WITH_INPUT_ACCESS=0
WITH_HEADLESS=0
for arg in "$@"; do
	case "$arg" in
		--autostart) WITH_AUTOSTART=1 ;;
		--systemd) WITH_SYSTEMD=1 ;;
		--input-access) WITH_INPUT_ACCESS=1 ;;
		--headless|--server) WITH_HEADLESS=1 ;;
		-h|--help)
			sed -n '2,12p' "$0"
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
if [ "$WITH_HEADLESS" -eq 0 ]; then
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
fi

# The embedded view (WebKitGTK 4.1) and smooth video (the GStreamer plugin set,
# with a VA-API plugin for GPU decode) are distro packages. Warn with the exact
# command; never fail -- the dashboard works without the view, and video merely
# decodes in software.
if [ "$WITH_HEADLESS" -eq 0 ]; then
with_view=1
"$PYTHON" -c 'import gi; gi.require_version("WebKit2", "4.1")' 2>/dev/null || with_view=0
with_va=0
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
	# The *plugin* loading is not enough: without a VA-API driver the "va"
	# plugin registers zero features, so the old check passed on a build that
	# could not decode a single frame and video stayed on software decode. Look
	# for an element WebKit actually uses to decode.
	if gst-inspect-1.0 vah264dec >/dev/null 2>&1 \
		|| gst-inspect-1.0 vah265dec >/dev/null 2>&1 \
		|| gst-inspect-1.0 vaapih264dec >/dev/null 2>&1; then
		with_va=1
	fi
fi
if [ "$with_view" -eq 0 ] || [ "$with_va" -eq 0 ]; then
	echo "install.sh: the embedded view / video want WebKitGTK 4.1 and the"
	echo "  GStreamer plugins (including a VA-API plugin for GPU decode):"
	os_id=$( . /etc/os-release 2>/dev/null || true; echo "${ID:-}${ID_LIKE:-}" )
	case "$os_id" in
		*arch*|*manjaro*)
			echo "  sudo pacman -S webkit2gtk-4.1 gst-plugins-base gst-plugins-good \\"
			echo "      gst-plugins-bad gst-plugins-ugly gst-libav intel-media-driver libva-utils"
			echo "  (intel-media-driver for Gen8+ Intel GPUs; on older Intel use"
			echo "   libva-intel-driver. Verify with: vainfo)"
			;;
		*debian*|*ubuntu*)
			echo "  sudo apt install gir1.2-webkit2-4.1 gstreamer1.0-plugins-base \\"
			echo "      gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \\"
			echo "      gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-vaapi vainfo"
			;;
		*fedora*|*rhel*)
			echo "  sudo dnf install webkit2gtk4.1 gstreamer1-plugins-base \\"
			echo "      gstreamer1-plugins-good gstreamer1-plugins-bad-free \\"
			echo "      gstreamer1-plugins-ugly gstreamer1-libav gstreamer1-vaapi"
			;;
		*)
			echo "  install WebKitGTK 4.1, the GStreamer plugin set, and your GPU's"
			echo "  VA-API plugin (gst-plugin-va / gstreamer1.0-vaapi). See desktop/README.md."
			;;
	esac
fi
fi

# --- copy the tree ----------------------------------------------------------
echo "Installing to $DEST"
mkdir -p "$DEST"
cp -R "$DESKTOP_SRC/." "$DEST/"
find "$DEST" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
chmod +x "$DEST/jawnosctl" "$DEST/jawnos-desktop" "$DEST/jawnos-bt-daemon"
# Record what was installed, so the app's own Update button offers only a newer
# repo tree - a plain install is "up to date" from the start.
"$PYTHON" -c "import sys; sys.path.insert(0, r'$DEST'); from jawnos_desktop import core; core.apply_update(dict(jawn_dir=r'$JAWN_DIR'))" >/dev/null 2>&1 || true

# --- entry points -----------------------------------------------------------
mkdir -p "$BIN"
if [ "$WITH_HEADLESS" -eq 1 ]; then
	ln -sf "$DEST/jawnosctl" "$BIN/jawnosctl"
	echo "Linked jawnosctl into $BIN"
else
	for tool in jawnosctl jawnos-desktop jawnos-bt-daemon; do
		ln -sf "$DEST/$tool" "$BIN/$tool"
	done
	echo "Linked jawnosctl, jawnos-desktop, jawnos-bt-daemon into $BIN"
fi

# --- icon and desktop entry -------------------------------------------------
if [ "$WITH_HEADLESS" -eq 0 ]; then
mkdir -p "$ICON_DIR" "$APPS"
cp "$DESKTOP_SRC/icons/jawnos.png" "$ICON_DIR/jawnos.png"
sed "s|@DESKTOP@|$DEST|g" "$DESKTOP_SRC/jawnos.desktop.in" > "$APPS/jawnos.desktop"
echo "Installed desktop entry and icon"
fi

# --- remember the jawn directory -------------------------------------------
# The installed copy lives under ~/.local, not in the checkout, so store where
# jawn actually is.
"$DEST/jawnosctl" dir "$JAWN_DIR" >/dev/null

# --- the app's own forever ticket -------------------------------------------
# A machine that holds the house mints the app a ticket that never expires, so
# the embedded view opens the manager without ever asking for a login. Skipped
# when a ticket is already stored (a routine code update must never rotate it)
# and when there is no house here to mint from; JAWNOS_NO_TICKET=1 turns it off.
if [ "$WITH_HEADLESS" -eq 0 ] && [ -z "${JAWNOS_NO_TICKET:-}" ] && [ -f "$REPO_ROOT/scripts/app_ticket.pl" ] \
	&& ! "$DEST/jawnosctl" ticket show >/dev/null 2>&1; then
	app_ticket=$(cd "$REPO_ROOT" && "$PERL" scripts/app_ticket.pl desktop 2>/dev/null | head -n 1 || true)
	case "$app_ticket" in
		https://*) "$DEST/jawnosctl" ticket import "$app_ticket" >/dev/null \
			&& echo "Stored the desktop's forever ticket" ;;
esac
fi

# --- desk input access (opt-in) --------------------------------------------
# Keyboard/mouse sharing reads the physical devices below the compositor (the
# same path on X11 and Wayland) and creates virtual ones through uinput. This
# grants the installing user's own group access to every keyboard, mouse,
# touchpad and tablet, and to /dev/uinput. It is opt-in because it widens what
# the app may read; new hardware matches the same ID_INPUT tags, so replacing a
# mouse or keyboard needs no rerun.
if [ "$WITH_INPUT_ACCESS" -eq 1 ] && [ "$WITH_HEADLESS" -eq 0 ]; then
	INPUT_USER=${SUDO_USER:-$(id -un)}
	INPUT_GROUP=$(id -gn "$INPUT_USER" 2>/dev/null || id -gn)
	RULE_OUT="${TMPDIR:-/tmp}/99-jawnos-input.rules"
	sed -e "s|@GROUP@|$INPUT_GROUP|g" "$DEST/udev/99-jawnos-input.rules.in" > "$RULE_OUT"
	if [ "$(id -u)" -eq 0 ]; then
		SUDO=""
	elif command -v sudo >/dev/null 2>&1; then
		SUDO=sudo
	else
		SUDO=""
	fi
	if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then
		if $SUDO install -m 0644 "$RULE_OUT" /etc/udev/rules.d/99-jawnos-input.rules; then
			$SUDO modprobe uinput >/dev/null 2>&1 || true
			$SUDO udevadm control --reload-rules 2>/dev/null || true
			$SUDO udevadm trigger --subsystem-match=input 2>/dev/null || true
			$SUDO udevadm trigger --action=change --subsystem-match=misc 2>/dev/null || true
			if [ -e /dev/uinput ]; then
				$SUDO chgrp "$INPUT_GROUP" /dev/uinput 2>/dev/null || true
				$SUDO chmod 0660 /dev/uinput 2>/dev/null || true
			fi
			echo "Granted $INPUT_GROUP access to keyboards, mice, touchpads and uinput"
		else
			echo "Could not install the input rule; run these as root:"
			echo "  sudo install -m 0644 $RULE_OUT /etc/udev/rules.d/99-jawnos-input.rules"
			echo "  sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=input"
			echo "  sudo udevadm trigger --action=change --subsystem-match=misc"
			echo "  sudo chgrp $INPUT_GROUP /dev/uinput && sudo chmod 0660 /dev/uinput"
		fi
	else
		echo "No sudo available; to grant the desk input access run as root:"
		echo "  install -m 0644 $RULE_OUT /etc/udev/rules.d/99-jawnos-input.rules"
		echo "  udevadm control --reload-rules && udevadm trigger --subsystem-match=input"
		echo "  udevadm trigger --action=change --subsystem-match=misc"
		echo "  chgrp $INPUT_GROUP /dev/uinput && chmod 0660 /dev/uinput"
	fi
elif [ "$WITH_INPUT_ACCESS" -eq 1 ]; then
echo "--input-access is not used by a headless install (no desk input)"
fi

# --- systemd --user units (a desktop, not a server) -------------------------
if [ "$WITH_SYSTEMD" -eq 1 ] && [ "$WITH_HEADLESS" -eq 0 ]; then
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

# --- systemd system unit (the headless server) ------------------------------
# A server has no login session, so it takes a plain system service that starts
# at boot: the same jawn, run like a daemon rather than in a tmux pane.
if [ "$WITH_HEADLESS" -eq 1 ]; then
	JAWN_USER=${SUDO_USER:-$(id -un)}
	JAWN_GROUP=$(id -gn "$JAWN_USER" 2>/dev/null || echo "$JAWN_USER")
	JAWN_HOME=$(getent passwd "$JAWN_USER" 2>/dev/null | cut -d: -f6)
	[ -n "$JAWN_HOME" ] || JAWN_HOME=$HOME
	mkdir -p "$JAWN_HOME/.local/state/jawnos" 2>/dev/null || true
	UNIT_OUT="${TMPDIR:-/tmp}/jawnos-server.service"
	sed -e "s|@PERL@|${PERL:-/usr/bin/perl}|g" \
		-e "s|@JAWN_DIR@|$JAWN_DIR|g" \
		-e "s|@JAWN_USER@|$JAWN_USER|g" \
		-e "s|@JAWN_GROUP@|$JAWN_GROUP|g" \
		-e "s|@JAWN_HOME@|$JAWN_HOME|g" \
		"$DESKTOP_SRC/systemd/jawnos-server.service.in" > "$UNIT_OUT"
	echo "Wrote the server unit to $UNIT_OUT"
	if [ "$(id -u)" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
		install -m 0644 "$UNIT_OUT" /etc/systemd/system/jawnos.service
		systemctl daemon-reload
		systemctl enable --now jawnos.service && echo "Enabled jawnos.service (starts at boot)"
	else
		echo "Install it as root (and, if jawn is already up in tmux, stop that first):"
		echo "  sudo install -m 0644 $UNIT_OUT /etc/systemd/system/jawnos.service"
		echo "  sudo systemctl daemon-reload && sudo systemctl enable --now jawnos.service"
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
if [ "$WITH_HEADLESS" -eq 1 ]; then
	echo "      jawnosctl log -n 200 (tail the app's log)"
	echo "      systemctl status jawnos"
else
	echo "      jawnos-desktop       (open the dashboard)"
	echo "      jawnosctl ble scan   (list nearby Bluetooth LE devices)"
fi
