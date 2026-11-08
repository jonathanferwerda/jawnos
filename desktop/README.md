# JawnOS for Linux (and the desktop)

This is the desktop port of the JawnOS Android app: the same two jobs, on a
normal Linux desktop.

1. **A supervisor** — start, stop and restart the jawn Perl tree, open its UI or
   its log, and report whether it is up. This mirrors the phone's dashboard.
2. **A Bluetooth LE bridge** — the Linux twin of the Android `JawnBleService`.
   It is a real BLE *central* (BlueZ over D-Bus) that links to the watch or a
   board and relays the same JSON the rest of jawn already speaks. The wire
   protocol is identical, so `scripts/jawn-bt` and jawn's own Perl listener work
   against it with no changes.

It runs on any distribution: the only requirements are `python3`, BlueZ, and —
for the GUI — PySide6 with **Qt WebEngine** (Chromium: the manager view, the
separate **Browse** window, and the session bar). Qt WebEngine is the only
engine and has WebRTC. Chat's SMS emoji want a colour emoji font (Noto Color
Emoji). Everything is per-user; nothing needs root.

## Layout

```
desktop/
  jawnosctl              the command line (start/stop/status/log/ble/…)
  jawnos-desktop         the desktop window (Qt WebEngine)
  jawnos-qt              the Qt WebEngine view directly
  jawnos-browse          the native Browse window (Qt WebEngine)
  jawnos-bt-daemon       the BLE bridge daemon (127.0.0.1:45999)
  jawnos_desktop/        the Python package behind the three tools
    core.py              the portable supervisor (ports, start/stop, settings)
    bridge.py            the toolkit-neutral page bridge (app key, scripts)
    ble.py               the BlueZ BLE bridge
    cli.py               jawnosctl
    qt_shell.py          the JawnOS view (Qt WebEngine / Chromium)
    browser.py           the Browse window (Qt WebEngine, own profile)
    shell.py             the session bar (Qt)
    secrets.py           encrypted storage for the login ticket
  systemd/               optional systemd --user units
  udev/                  the all-input rule for the desk
  jawnos.desktop.in      the application-menu entry
  icons/jawnos.png       the launcher icon
  install.sh             per-user installer
  install-wallet.sh      Sparrow + hardware-wallet USB rules (opt-in)
```

## Install

```sh
./desktop/install.sh                 # app + CLI + dashboard under ~/.local
./desktop/install.sh --autostart     # also bring the BLE bridge up at login
./desktop/install.sh --systemd       # also install systemd --user units
./desktop/install.sh --input-access  # also let the desk read all keyboards/mice
./desktop/install.sh --with-wallet   # also install Sparrow + USB wallet rules
```

The installer copies the tree to `~/.local/share/jawnos/desktop`, links the
three tools into `~/.local/bin`, installs the icon and the menu entry, and
optionally sets up autostart or `systemd --user` units. `--input-access` also
installs `/etc/udev/rules.d/99-jawnos-input.rules` for the installing user's
group, so the desk can read every keyboard, mouse, touchpad and tablet (X11 and
Wayland alike) and write `/dev/uinput`. It needs sudo once; replacing a mouse
or keyboard needs no rerun because the rule matches the standard `ID_INPUT`
tags. You do not have to install it at all — the commands live at the tree
root and run in place from the checkout (their implementation and installer
stay in `desktop/`):

```sh
./jawnosctl status
./jawnos-desktop
./jawnos-bt-daemon
```

`./jawn` is the service entry those commands (and both apps) start; it is not
normally typed. The installed copy links the same three commands into
`~/.local/bin`.

Distro packages, when you need them:

| Distro | base |
|---|---|
| Arch / Manjaro | `python` `python-gobject` `python-dbus` `bluez` `bluez-utils` |
| Debian / Ubuntu | `python3` `python3-gi` `python3-dbus` `bluez` |
| Fedora | `python3` `python3-gobject` `python3-dbus` `bluez` |

The default desktop view is **Qt WebEngine** (Chromium). Install it first:

| Distro | Qt view |
|---|---|
| Arch / Manjaro | `pyside6` `qt6-webengine` `qt6-wayland` |
| Debian / Ubuntu | `python3-pyside6.qtwebenginewidgets` |
| Fedora | `python3-pyside6` `qt6-qtwebengine` `qt6-qtwayland` |

`qt6-wayland` is the Qt Wayland platform plugin; a Sway session has no X server
to fall back to. PySide6 with Qt WebEngine is **required**: `jawnos-desktop`
exits with an error and the package hint when it cannot import it. There is no
WebKitGTK fallback.

`install.sh` checks for the Qt view and prints the right command for your
distro if it is missing.

Chat relays SMS through the phone, so its emoji are part of the conversation.
If the system has no colour emoji font, every emoji draws as a blank box:

| Distro | emoji font |
|---|---|
| Arch / Manjaro | `noto-fonts-emoji` |
| Debian / Ubuntu | `fonts-noto-color-emoji` |
| Fedora | `google-noto-emoji-color-fonts` |

`install.sh` checks for it too, and `perl scripts/jawnos_deps.pl --desktop
--install` installs it with the other desktop extras (the first run of `./jawn`
does that automatically when a display is present).

Every system also needs the **VA-API driver for its GPU** (below), or video
decodes in software.

## Hardware wallet (Sparrow)

`./desktop/install.sh --with-wallet` installs **Sparrow Wallet** and the USB
rules a Ledger or Trezor needs. It is opt-in because a headless box has no GUI
wallet. The same work can be re-run alone:

```sh
./desktop/install-wallet.sh             # Sparrow + Ledger/Trezor rules
./desktop/install-wallet.sh --rules-only
./desktop/install-wallet.sh --dry-run
```

Arch/Manjaro uses the AUR (`sparrow-wallet`, `ledger-udev`); Debian/Ubuntu and
Fedora fetch the release package from GitHub and check its SHA-256 against the
published manifest; other systems get the official tarball under
`~/.local/opt/sparrow`. Every path is non-fatal: if it cannot install (no AUR
helper, no sudo), it prints the exact commands.

The wallet's key never leaves the device. JawnOS needs only the **account
xpub**:

1. Unlock the device and open its Bitcoin app.
2. Sparrow: **File -> New Wallet -> Single Signature -> Native Segwit (BIP84) ->
   Connected Hardware Wallet -> Scan -> Create Wallet**.
3. **Settings -> Wallet -> Show xpub**; copy the `zpub...`.
4. In JawnOS: **Configure -> App -> Account xpub**; paste it. Compare the "next
   invoice address" it reports with Sparrow's **Receive** tab.
5. Send a small test payment before relying on it.

The same hardware wallet can be used on **several Sparrows** (and several
machines): the key is on the device, and each Sparrow is an independent
watch-only view of the same account. Export the same account xpub, use the same
script type (`m/84'/0'/0'`), and close one app before opening the other (only
one process can hold the USB connection). Never "restore" the seed into a
computer; import the xpub instead. If two separate JawnOS houses share one
xpub, they will allocate the same address indexes independently - use one
house, or a different account per house, to avoid address reuse.

## The app's login ticket

The embedded view signs in with a ticket URL, stored encrypted under
`~/.config/jawnos/`: `jawnosctl ticket import <url>` stores one, `jawnosctl
ticket show` prints a masked copy, `jawnosctl ticket clear` forgets it.

On a machine that holds the house, `install.sh` mints the app its own ticket
once (`perl scripts/app_ticket.pl desktop`) and imports it. That ticket carries
the "forever" warranty, so it never expires and the manager opens without a
login. It is idempotent: an already-stored ticket is never overwritten, and
`JAWNOS_NO_TICKET=1 ./desktop/install.sh` skips the step. The ticket's row sits
in the box office beside the others and can be suspended or deleted there.

On a phone or tablet the same script with `--save` writes the URL to
`.shots/ticket.txt`, which is where the Android app's Open UI button looks for
it (and the fallback this view reads too): `perl scripts/app_ticket.pl phone
--save`.

## Headless server

A server wants the same supervisor with no screen. `install.sh --headless`
installs the `jawnosctl` CLI and a **system** systemd unit — no dashboard, no BLE
bridge, no menu entry, no login ticket:

```sh
./desktop/install.sh --headless
sudo install -m 0644 /tmp/jawnos-server.service /etc/systemd/system/jawnos.service
sudo systemctl daemon-reload && sudo systemctl enable --now jawnos.service
```

(Run the installer as root and it does those two lines itself.) Stop any jawn
already running by hand first — a `tmux` pane, say — so two masters do not fight
for the ports.

The unit runs `perl ./jawn` as the tree's owner, brings the master back if it
exits, and keeps the pty output in `~/.local/state/jawnos/jawn-stdout.log` (the
same file the desktop `--user` unit writes, so the error watch still tails it).
Control it with the same CLI:

```sh
jawnosctl status          # is jawn up? what version, and for how long?
jawnosctl log -n 200 -f   # tail the app's log
sudo systemctl restart jawnos
```

`status` reads the app's own `/manager/health` over loopback (no login needed
from the machine itself), so it reports the running version, uptime and peer
count, not merely that a port is open. The same data is a JSON read at
`/manager/health` and a plain page at `/manager/health/page`.

No GUI packages are needed — no PySide6 or PyGObject; `python3` alone runs the
CLI. The unit itself needs no Python at all.

## Using it

```sh
jawnosctl status              # is jawn up? is the BLE bridge up?
jawnosctl start               # start jawn (and the bridge, if tied)
jawnosctl stop                # take the whole tree down
jawnosctl restart             # restart jawn
jawnosctl watch               # restart when the running version is not the disk version
jawnosctl open                # open the JawnOS app (a browser on a headless box)
jawnosctl log -n 200 -f       # tail ~/manager.log
jawnosctl dir ~/jawnos        # point at a different jawn tree
jawnosctl autostart enable    # start the BLE bridge at login
```

`jawnos-desktop` is the same thing as a window, with a live status line, the
folder setting, and the autostart / "BLE bridge with jawn" checkboxes. On its
first run the window opens at two-thirds of the screen, in the screen's own
orientation (a wide monitor gets a wide window); after that it reopens where it
was left — same size and position, or maximized, or fullscreen if that is how
you left it. (Position is remembered on X11; Wayland lets the compositor place
windows, so only the size and the fullscreen/maximized state carry over there.)

`watch` keeps a host on the code that is actually on disk: every minute it
compares the running version (`/manager/health`) with `VERSION`, and restarts
the tree when they differ — a code sync (git or a peer tar) replaces the files
without touching the process, which is how a server could sit on old code while
its `VERSION` already said the new one. The dashboard runs the same check on its
own tick and also applies a newer `desktop/` tree and restarts itself, so a
pushed version lands without pressing **Update app**. That automatic restart is
tied to a `VERSION` bump, not to a file's modification time: an in-progress edit
changes the tree stamp but ships nothing, and it must not take the app down.
**Update app** still applies any edit under `desktop/` on demand.

Add `--tray` for a status-tray icon: it carries jawn's state as a coloured dot
in the corner of the icon — green running, amber starting/restarting, red
stopped. Left-click opens the window, right-click shows the menu, and **Quit and
stop jawn** takes the jawn tree (and the bridge) down before the app exits, so
quitting from the tray leaves no process behind. The plain **Quit** item closes
only this dashboard process and leaves jawn (and the bridge) running.

The jawn directory is found automatically (the checkout this lives in, else
`~/jawnos`); override it with `jawnosctl dir`, the `JAWNOS_DIR` environment
variable, or the folder box in the dashboard.

### How it maps to the phone

| Android | Linux |
|---|---|
| `JawnLauncher.startJawn` | `jawnosctl start` — `perl ./jawn`, detached |
| `JawnLauncher.stopJawn` | `jawnosctl stop` — `manager_killer.pl master` |
| `JawnDashboardActivity` | `jawnos-desktop` |
| `JawnLogActivity` | `jawnosctl log` / the dashboard's log window |
| `JawnDot` overlay | `jawnos-desktop --tray` |
| `JawnBootReceiver` | XDG autostart / `systemd --user` |
| `JawnBleService` (GATT central over Android Bluetooth) | `jawnos-bt-daemon` (GATT central over BlueZ D-Bus) |

## The BLE bridge

The daemon listens on **127.0.0.1:45999** and speaks newline-delimited JSON —
exactly what the Android daemon speaks, so the shared `scripts/jawn-bt` client
works unchanged:

```sh
jawnosctl ble start           # the root command; the same as ./desktop/jawnosctl
./scripts/jawn-bt status
./scripts/jawn-bt scan 8      # lists nearby LE devices
./scripts/jawn-bt connect 64:E8:33:4B:38:39 \
    --service 6e400001-b5a3-f393-e0a9-e50e24dcca9e \
    --rx      6e400002-b5a3-f393-e0a9-e50e24dcca9e \
    --tx      6e400003-b5a3-f393-e0a9-e50e24dcca9e --mtu 512
./scripts/jawn-bt send '{"type":"hello"}'
jawnosctl ble stop
```

The daemon connects to the last device automatically when it starts (the target
is remembered in `~/.config/jawnos/ble.json`), and reconnects with backoff if
the link drops — the same hands-free behaviour as the phone.

Two implementation notes carried over from Android, because they matter:

* **Framing.** A payload that does not fit one write is split as `<i>/<n>:` plus
  a chunk and reassembled by the watch (`jw.ino::ble_frame_ingest`). The chunk
  size is derived from `--mtu` exactly as the Android daemon derives it.
* **Never block the loop.** The Android worker that one bug froze in a 25-second
  connect could not answer `shutdown`. Here all Bluetooth work runs on the GLib
  main loop and the D-Bus connect is asynchronous, so a slow or absent device
  never stalls the daemon.

jawn's own Perl bridge is allowed to answer watches from a machine that is not
the `mobile` hub as long as the daemon is actually reachable on loopback
(`subroutines.pl::ble_bridge_capable`). That is what lets a desktop with the
bridge running reply to a `room_request` or push a toggle; on the phone the
behaviour is unchanged.

## Media and video

Qt WebEngine decodes media through **Chromium's** own media stack (FFmpeg +
VA-API), so video quality follows Chromium and the GPU driver. There is no
WebKitGTK/GStreamer path any more. Hardware decode needs the VA-API driver for
your GPU (the table below); without one, video decodes on the CPU and the rest
of the view still uses the card.

`~/.config/jawnos/webkit.env` is kept as an escape hatch from the old GTK
shell: Chromium reads only its non-`WEBKIT_*` keys (`JAWNOS_GPU`,
`LIBVA_DRIVER_NAME`), and the `WEBKIT_*` switches are ignored.

### GPU on the Qt view

The Qt shell keeps the card in the render path. Before the `QApplication`
exists it sets

```sh
LIBVA_DRIVER_NAME=<the card's driver>
QTWEBENGINE_CHROMIUM_FLAGS=... --ignore-gpu-blocklist --enable-gpu-rasterization
```

The VA-API driver follows the DRM vendor in
`/sys/class/drm/card*/device/vendor`, and is named only when a
`/dev/dri/renderD*` node exists and the matching `*_drv_video.so` is installed:

| Card | Vendor ID | `LIBVA_DRIVER_NAME` | Installed by |
| --- | --- | --- | --- |
| Intel Gen9+ | `0x8086` | `iHD` | `intel-media-driver` |
| Intel older | `0x8086` | `i965` (fallback) | `libva-intel-driver` |
| AMD | `0x1002` | `radeonsi` | Mesa's VA-API driver |
| NVIDIA | `0x10de` | `nvidia` | `libva-nvidia-driver`, or VA-API from the proprietary driver |
| virtio, bochs, VMware, VirtualBox, qxl | `0x1af4`, `0x1234`, `0x15ad`, `0x80ee`, `0x1b36` | _(unset)_ | virtual GPUs have no VA-API |
| NVIDIA via nouveau | `0x10de` | _(unset)_ | nouveau has no VA-API |

A value you already exported (or put in `webkit.env`/`qt.env`) always wins: the
shell never overrides `LIBVA_DRIVER_NAME`. NVIDIA needs the proprietary driver
or `libva-nvidia-driver` for hardware decode; without one, video decodes on the
CPU and the rest of the view still uses the card.

With a render node and a real card, the two Chromium flags keep a blocklisted
GPU off SwiftShader and the raster work on the card, which is what stays smooth
when the machine is busy. A machine with **no render node**, or with **only a
virtual display GPU**, gets the software path instead
(`--disable-gpu --disable-gpu-compositing`), so Chromium does not spin a failing
GPU process (the live image under QEMU otherwise logs ZINK/Vulkan and DRM
errors); the page still renders. `JAWNOS_GPU=1` forces the GPU flags even on a
virtual card, `JAWNOS_GPU=0` asks for software, and an existing `--disable-gpu`
in the flags is never touched.

`--probe` reports the WebGL renderer, so this is checkable rather than
assumed:

```sh
./desktop/jawnos-qt --probe
# ... "gpu":"Mesa Intel(R) HD Graphics 530 (SKL GT2) / Mesa Intel(R) HD Graphics 530 (SKL GT2)"
```

`~/.config/jawnos/qt.env` is the Qt escape hatch (`KEY=VALUE` per line, `#`
comments; the real environment always wins). `JAWNOS_GPU=0` there asks for the
software path (`--disable-gpu --disable-gpu-compositing`), and any extra
Chromium flag can be added with `QTWEBENGINE_CHROMIUM_FLAGS=...`. `webkit.env`'s
non-`WEBKIT_*` keys are honoured too, so `JAWNOS_GPU` and `LIBVA_DRIVER_NAME`
still work there; its `WEBKIT_*` switches mean nothing to Chromium and are
skipped.

### Scrolling on the Qt view

Qt leaves Chromium's scroll animator off by default, which reads as scrolling
in steps: a flick of the trackpad stops as soon as the fingers lift. The shell
turns it on (`ScrollAnimatorEnabled`) in the Qt profile before the first page
exists, so the Manager and every peer Manager window opened from it glide and
coast. Browse asks for the same attribute on each of its own views. This is the
Qt counterpart of the removed WebKitGTK view's `enable-smooth-scrolling`.

## Desktop engine: Qt WebEngine

The desktop shell is **Qt WebEngine** (Chromium), the only engine: it has the
reference WebRTC implementation the chat and the screening's Connect me need,
and it is the engine family Android's WebView already uses. Install it:

    sudo pacman -S pyside6 qt6-webengine qt6-wayland        # Arch
    sudo apt install python3-pyside6.qtwebenginewidgets    # Debian 13
    ./jawnos-desktop                  # Qt WebEngine
    ./jawnos-desktop --engine qt      # explicit (auto is the default)
    ./desktop/jawnos-qt --url https://<house>:3000/manager
    ./desktop/jawnos-qt --probe       # WebRTC, media and bridge support

It uses the same stored ticket as always: loading the ticket URL
mints the session cookie, and the shell then loads the Manager on that host.
The profile (`~/.config/jawnos/qt-webengine`) keeps the cookie across launches.
Certificate errors are accepted for the house's self-signed certificate, and
microphone/camera requests are granted to the page. Qt 6.8 and 6.12 spell web
permissions differently; both the `permissionRequested`/`QWebEnginePermission`
path and the older `featurePermissionRequested` one are handled. `--probe` is
also the regression check in `t/185-desktop-qt-shell.t`, which skips on a
machine without the PySide6 package.

It is a full shell, not only a view. The page bridge
(`window.webkit.messageHandlers.jawnos`, forwarded over QWebChannel) keeps the
app key, peer Manager windows, the native Browse window and media keep-awake
working. The shell supervises jawn (start/stop/restart, the version restart and
the desktop self-update), keeps a tray when the desktop provides one, and
handles F11 and a page's own fullscreen request. On Sway it points Qt and
Chromium at Wayland (`QT_QPA_PLATFORM=wayland`, `--ozone-platform-hint=auto`)
unless those are already set.

On the first Qt run it copies the removed GTK shell's page layout out of
WebKit's per-origin store (`~/.local/share/jawnos-desktop/localstorage/https_<host>_<port>.localstorage`)
into the Qt profile - `layout`, `background_images`, `dock_icons`,
`window_places` and the rest - once, marked so later Qt changes are kept. The
live tab id is deliberately not copied. `device_uuid` is: it is this machine's
own device identity, the one the app key is paired with, and the app-required
page needs it to sign in. An older Qt profile that was migrated without it is
seeded once at document start (`__jawn_device_seeded`). The window geometry,
maximized and fullscreen state come from `~/.config/jawnos/desktop.json` and are
written back on close.

A fresh profile still lands on the padlock Gate. The **Qt control panel** is
the admin window: the tray's **Control panel** item, or the page's start-menu
admin icon. It carries the supervisor's controls (tailnet start/stop, the BLE
autostart setting, ticket import, the app update, the log) in the desktop's
look — black ground, rounded cards with upper-case section headers, the jawn
yellow for the primary action, and a coloured dot beside each live status line —
so it reads like the Android dashboard. The tray badge carries the same state
dot: green running, amber starting/restarting, red stopped. Its menu has no
browser item; **Open in browser** stays a button in the panel's Open card.
PySide6 with Qt WebEngine is a hard requirement; the only remaining PyGObject
use is the BLE daemon's GLib main loop (not GTK). The Arch live image installs
`pyside6`, `qt6-webengine`, `qt6-wayland` and `layer-shell-qt`
(`desktop/mkosi/mkosi.conf`).

The **session bar** (`desktop/jawnos-shell`, `jawnos_desktop/shell.py`) is Qt
too. On Wayland it takes the same wlr-layer-shell top layer, top/left/right
anchors, exclusive zone and keyboard mode as the old GTK bar: layer-shell-qt
has no C API, so `shell.py` resolves its C++ setters with a small ctypes shim
and passes the QWindow PySide6 created. Install `layer-shell-qt` for that path.
Without the package, on X11, or on a compositor without wlr-layer-shell, the bar
falls back to a frameless always-on-top window: on Sway it asks `swaymsg` to
float it at 0,0, size it to the output and make it sticky (lowering Sway's
floating minimum height when the bar is shorter than 50px). That overlays
windows instead of reserving an exclusive zone, and a fullscreen window covers
it. On the layer-shell path the exclusive zone is unchanged, so a fullscreen
JawnOS window still has the bar over it.

## Browse window

The Internet app's **Browse** half is a native Qt WebEngine window, started
with `./desktop/jawnos-browse` (the manager page reaches the same launcher
through `JawnBrowse.open`). It is a real browser, not a manager view: tabs, an
address bar that also searches a phrase, back/forward/reload/stop, home,
find-in-page, downloads, a local history, new-window popups as tabs, and the
same keyboard shortcuts as before (Ctrl+L/T/W/F/G, F5/Ctrl+R, Alt+Left/Right,
Alt+Home; Esc leaves bug mode, closes find, or stops a load).

It keeps a **separate, named profile** — `QWebEngineProfile("jawnos-browse")`
under `~/.config/jawnos/browse-webengine` — so its cookies are never the
manager view's (`jawnos`). That is what makes Browse
independent: signing into a site there does not touch the manager session. The
window accepts the house's self-signed certificate (the same exception the Qt
shell makes) and grants microphone/camera capture; other permissions are
denied. It calls `gpu.prepare_env()` before the `QApplication` exists, so the
same Chromium GPU flags apply.

The page bridge (`window.webkit.messageHandlers.*`, forwarded over
QWebChannel) carries media state for keep-awake, the local ad-block picker and
(in measure mode) the measure picker. It deliberately has **no app-key or
manager-window actions**: a public page loaded in Browse cannot borrow the
desktop app's identity. The ad-block picker runs in an isolated Qt script
world; it reaches Python through a DOM event and the selector is validated
again there. Site visits still post `kind=site` usage spans through the stored
ticket, as before. `--mode measure` is unchanged: pick an element, the live
document goes to `/manager/web/measure/live`, and the returned candidates are
shown in a dialog.

## Windows

The supervisor in `jawnos_desktop/core.py` is deliberately written to be
portable. A Windows port would add a `core_win` layer (process spawn / kill and
the `%APPDATA%` paths) and a WinRT BLE backend for the bridge — the wire
protocol and the UI are already platform-neutral.
