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
for the GUI — GTK 3 (`python3-gi`). Everything is per-user; nothing needs root.

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
    ui.py                the GTK dashboard
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

| Distro | packages |
|---|---|
| Arch / Manjaro | `python` `python-gobject` `python-dbus` `bluez` `bluez-utils` |
| Debian / Ubuntu | `python3` `python3-gi` `python3-dbus` `bluez` |
| Fedora | `python3` `python3-gobject` `python3-dbus` `bluez` |

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

## Windows

The supervisor in `jawnos_desktop/core.py` is deliberately written to be
portable. A Windows port would add a `core_win` layer (process spawn / kill and
the `%APPDATA%` paths) and a WinRT BLE backend for the bridge — the wire
protocol and the UI are already platform-neutral.
