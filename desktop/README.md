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
for the GUI — GTK 3 (`python3-gi`). The embedded JawnOS view (below) also wants
WebKitGTK 4.1, and smooth video wants the GStreamer plugin set with a VA-API
plugin. Everything is per-user; nothing needs root.

## Layout

```
desktop/
  jawnosctl              the command line (start/stop/status/log/ble/…)
  jawnos-desktop         the GTK dashboard window
  jawnos-bt-daemon       the BLE bridge daemon (127.0.0.1:45999)
  jawnos_desktop/        the Python package behind the three tools
    core.py              the portable supervisor (ports, start/stop, settings)
    ble.py               the BlueZ BLE bridge
    cli.py               jawnosctl
    ui.py                the GTK dashboard and its embedded-view tab
    webview.py           the embedded JawnOS view (WebKitGTK)
    secrets.py           encrypted storage for the login ticket
  systemd/               optional systemd --user units
  jawnos.desktop.in      the application-menu entry
  icons/jawnos.png       the launcher icon
  install.sh             per-user installer
```

## Install

```sh
./desktop/install.sh                 # app + CLI + dashboard under ~/.local
./desktop/install.sh --autostart     # also bring the BLE bridge up at login
./desktop/install.sh --systemd       # also install systemd --user units
```

The installer copies the tree to `~/.local/share/jawnos/desktop`, links the
three tools into `~/.local/bin`, installs the icon and the menu entry, and
optionally sets up autostart or `systemd --user` units. You do not have to
install it at all — the tools run in place from the checkout:

```sh
./desktop/jawnosctl status
./desktop/jawnos-desktop
./desktop/jawnos-bt-daemon
```

Distro packages, when you need them:

| Distro | base |
|---|---|
| Arch / Manjaro | `python` `python-gobject` `python-dbus` `bluez` `bluez-utils` |
| Debian / Ubuntu | `python3` `python3-gi` `python3-dbus` `bluez` |
| Fedora | `python3` `python3-gobject` `python3-dbus` `bluez` |

For the embedded view and for smooth media, add the WebKitGTK and GStreamer
packages (the base table alone will not play video well — see
[Media and video](#media-and-video)):

| Distro | embedded view + media |
|---|---|
| Arch / Manjaro | `webkit2gtk-4.1` `gst-plugins-base` `gst-plugins-good` `gst-plugins-bad` `gst-plugins-ugly` `gst-libav` `libva-utils` |
| Debian / Ubuntu | `gir1.2-webkit2-4.1` `gstreamer1.0-plugins-base` `gstreamer1.0-plugins-good` `gstreamer1.0-plugins-bad` `gstreamer1.0-plugins-ugly` `gstreamer1.0-libav` `gstreamer1.0-vaapi` `vainfo` |
| Fedora | `webkit2gtk4.1` `gstreamer1-plugins-base` `gstreamer1-plugins-good` `gstreamer1-plugins-bad-free` `gstreamer1-plugins-ugly` `gstreamer1-libav` `gstreamer1-vaapi` |

`install.sh` checks for these and prints the right command for your distro if
they are missing. On Arch the VA-API plugin used to be a separate
`gst-plugin-va` package; on current Arch it ships inside `gst-plugins-bad`.

Every system also needs the **VA-API driver for its GPU** (below), or video
decodes in software.

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

## Using it

```sh
jawnosctl status              # is jawn up? is the BLE bridge up?
jawnosctl start               # start jawn (and the bridge, if tied)
jawnosctl stop                # take the whole tree down
jawnosctl restart             # restart jawn
jawnosctl open                # open the JawnOS UI in a browser
jawnosctl log -n 200 -f       # tail ~/manager.log
jawnosctl dir ~/jawnos        # point at a different jawn tree
jawnosctl autostart enable    # start the BLE bridge at login
```

`jawnos-desktop` is the same thing as a window, with a live status line, the
folder setting, and the autostart / "BLE bridge with jawn" checkboxes. Add
`--tray` for a status-tray icon.

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
jawnosctl ble start           # or: ./desktop/jawnosctl ble start
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

Everything in the UI runs in the embedded **WebKitGTK** view, which decodes
media through the system **GStreamer**. So the video experience is GStreamer's,
not the app's:

* Install the full plugin set listed above (`gst-plugins-base/good/bad/ugly` and
  `gst-libav`). Without them WebKit has only a software h264 decoder and HD video
  is choppy.
* Install the **VA-API plugin** (`gstreamer1.0-vaapi`, or the `va` plugin that
  ships inside `gst-plugins-bad` on newer GStreamer) so decode happens on the
  GPU. That is the single biggest win.
* It *also* needs the driver for your GPU (`intel-media-driver` or
  `libva-intel-driver` on Arch; `intel-media-va-driver-non-free` or
  `i965-va-driver` on Debian). Without a driver the plugin loads but registers
  **zero** elements, so video quietly stays on software decode — this is the
  usual reason a machine still stutters after the plugin is installed.
* Confirm with `gst-inspect-1.0 vah264dec` (the element WebKit actually uses),
  not just `gst-inspect-1.0 va` — the latter succeeds even on a plugin that
  offers nothing, and `vainfo` should list H264/HEVC profiles.

On Arch/Manjaro the plugin ships inside `gst-plugins-bad`, which must be
installed *with* the rest of the `gst-*` stack (they pin each other exactly, so
a lone install is refused — upgrade them together):

```sh
sudo pacman -S gst-plugins-base gst-plugins-good gst-plugins-bad \
  gst-plugins-ugly gst-libav
```

(An older Arch split the plugin into a `gst-plugin-va` package; that no longer
exists.)

If video is still not right, the renderer can be tuned without touching code:
write `KEY=VALUE` lines to `~/.config/jawnos/webkit.env` (WebKit reads them at
startup — the real environment wins over the file).

## Windows

The supervisor in `jawnos_desktop/core.py` is deliberately written to be
portable. A Windows port would add a `core_win` layer (process spawn / kill and
the `%APPDATA%` paths) and a WinRT BLE backend for the bridge — the wire
protocol and the UI are already platform-neutral.
