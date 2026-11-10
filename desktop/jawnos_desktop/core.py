"""The JawnOS desktop supervisor.

This mirrors the Android app's ``JawnLauncher``: it locates the jawn tree, reads
its ``config.json`` for the ports, reports whether jawn and the BLE bridge are
up, and starts / stops / restarts them. Nothing here imports a GUI or the BLE
implementation, so the CLI, the dashboard and the bridge all share one source of
truth.

The start/stop semantics deliberately match the phone:

* ``start`` runs ``perl ./jawn`` in the jawn directory, detached, its output to
  a log file. On Android this is a background Termux task.
* ``stop`` runs ``scripts/manager_killer.pl master`` -- the Android app's Stop
  button does exactly this, because stopping the terminal session alone only
  SIGKILLs the tree and leaves the master answering ``~/.process_watch``. Any
  master still alive after the killer is terminated directly.
* ``restart`` is a real stop-then-start: it kills the master and starts a fresh
  one, then waits for the tree to answer, so it cannot leave a half-boot window
  or a second master.

The platform-shaped pieces live beside this file and are re-exported here so
callers keep one import: ``core_paths`` (paths), ``core_process``
(spawn/kill/supervision), ``core_secrets`` (ticket storage), ``core_autostart``
(login unit) and ``core_shell`` (browser/terminal launch).
"""

import json
import os
import re
import socket
import ssl
import subprocess
import time
import urllib.request

from . import DESKTOP_DIR
from .core_autostart import (
    _AUTOSTART_UNIT, autostart_enabled, autostart_path, set_autostart,
)
from .core_paths import (
    DEFAULT_DIRNAME, _boot_id, _xdg, ble_log_path, ble_pid_path, config_dir,
    daemon_path, default_jawn_dir, held_path, home, is_held,
    jawn_stdout_log_path, set_held, settings_path, state_dir,
)
from .core_process import (
    _detached_children, _jawn_master_pids, _perl, _perl_env, _read_pidfile,
    _remove_stale_pidfile, _wait_port_closed, pid_alive, reap_detached,
    restart_jawn, spawn_detached, start_ble, start_jawn, stop_ble, stop_jawn,
)
from .core_secrets import manager_host
from .core_shell import _TERMINALS, desktop_launcher, open_console, open_ui

# The BLE bridge listens here on both Android and Linux; keep the number so
# scripts/jawn-bt (the shared client) needs no change.
BRIDGE_PORT = 45999
# config.json's "port" (the dock); 3000 is always answered even when the
# working port is something else.
DOCK_PORT = 3000


# --------------------------------------------------------------------------
# paths and settings
# --------------------------------------------------------------------------
# The path helpers live in core_paths.py and are re-exported at the top, so
# callers keep using core.config_dir() and friends.

def jawn_version(jawn_dir):
    """The human version from <jawn_dir>/VERSION, or None if unavailable."""
    try:
        with open(os.path.join(jawn_dir, "VERSION"), "r", encoding="utf-8") as fh:
            value = fh.read().strip()
        return value or None
    except OSError:
        return None


def desktop_version(jawn_dir):
    """This app's version, in the app-store shape: (versionCode, versionName).

    Both ride the tree's VERSION file, so the desktop carries the same version
    the rest of the house does and can compare itself the way the APK's
    versionCode does. code is 0 when the version is unknown."""
    name = jawn_version(jawn_dir) or ""
    code = 0
    parts = name.split(".")
    try:
        if len(parts) >= 3:
            code = int(parts[0]) * 1000000 + int(parts[1]) * 1000 + int(parts[2])
    except ValueError:
        code = 0
    return code, name


def load_settings():
    data = {
        "jawn_dir": default_jawn_dir(),
        "autostart": False,
        "ble_with_jawn": True,
        # The window's state on the last quit, so the next launch (and the
        # post-update restart) comes back the same way: fullscreen or
        # maximized, otherwise at the last normal size and position. A size of
        # 0 or a position of None means "not recorded yet".
        "fullscreen": False,
        "maximized": False,
        "window_width": 0,
        "window_height": 0,
        "window_x": None,
        "window_y": None,
    }
    try:
        with open(settings_path(), "r", encoding="utf-8") as fh:
            stored = json.load(fh)
        if isinstance(stored, dict):
            data.update({k: v for k, v in stored.items() if k in data})
    except (OSError, ValueError):
        pass
    # The environment always wins, so a service or a one-off can point elsewhere.
    env_dir = os.environ.get("JAWNOS_DIR")
    if env_dir:
        data["jawn_dir"] = os.path.expanduser(env_dir)
    data["jawn_dir"] = os.path.expanduser(data["jawn_dir"] or "")
    return data


def save_settings(settings):
    os.makedirs(config_dir(), exist_ok=True)
    tmp = settings_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(settings, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, settings_path())


# --------------------------------------------------------------------------
# update: the installed copy follows the repo's desktop/ tree, on the button
# --------------------------------------------------------------------------

# Build systems and their output live under desktop/ but are not part of the
# app. desktop/mkosi in particular can hold a running image build's 1 GB tree;
# counting or copying it made every build write look like a new desktop, so the
# dashboard reinstalled itself and restarted every couple of minutes (and the
# WebKit teardown aborted in Mesa each time).
_TREE_SKIP_DIRS = {
    "__pycache__",
    ".git",
    ".stage",
    ".venv",
    "mkosi",
    "node_modules",
    "output",
}


def _walk_installable(root):
    """os.walk for the app's own tree, without build systems or caches."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in _TREE_SKIP_DIRS)
        yield dirpath, dirnames, filenames


def _tree_stamp(root):
    """A stamp that changes when any file in the tree does: newest mtime and
    the file count."""
    newest = 0
    count = 0
    for dirpath, dirnames, filenames in _walk_installable(root):
        for name in filenames:
            try:
                newest = max(newest, os.path.getmtime(os.path.join(dirpath, name)))
                count += 1
            except OSError:
                pass
    return "%d-%d" % (int(newest), count)


def installed_stamp_path():
    return os.path.join(DESKTOP_DIR, ".installed")


def repo_desktop_dir(settings):
    return os.path.join(settings.get("jawn_dir") or default_jawn_dir(), "desktop")


def installed_info():
    """The stamp and version recorded when this copy was last written."""
    try:
        with open(installed_stamp_path(), "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {}


def _write_installed_stamp(stamp, name, code):
    try:
        with open(installed_stamp_path(), "w", encoding="utf-8") as fh:
            json.dump({"stamp": stamp, "versionName": name, "versionCode": code}, fh)
            fh.write("\n")
    except OSError:
        pass


def repo_desktop_ready(settings):
    """True when the repo carries a desktop tree that is not this very copy."""
    repo = repo_desktop_dir(settings)
    if not os.path.isfile(os.path.join(repo, "jawnos_desktop", "qt_shell.py")):
        return False
    try:
        return os.path.realpath(repo) != os.path.realpath(DESKTOP_DIR)
    except OSError:
        return False


def update_available(settings):
    """(versionName, versionCode) of a newer repo desktop tree, or None.

    "Newer" is the tree stamp: any edit under the repo's desktop/ makes the
    installed copy out of date, the way a bumped versionCode makes an APK so."""
    if not repo_desktop_ready(settings):
        return None
    repo = repo_desktop_dir(settings)
    stamp = _tree_stamp(repo)
    if installed_info().get("stamp") == stamp:
        return None
    code, name = desktop_version(settings.get("jawn_dir") or default_jawn_dir())
    return (name or "", code)


def auto_update_available(settings):
    """(versionName, versionCode) when a release makes this copy out of date.

    The automatic path restarts the app (os.execv), so it must not fire for
    every edit under the repo's desktop/ tree. A code sync, or a person writing
    a file, changes the tree stamp without shipping anything; watching the
    stamp alone restarted the app every minute or two while desktop/ was being
    edited. A release is signalled by VERSION, the same app-store shape this
    app already uses. The manual "Update app" button still calls
    update_available(), which follows any edit."""
    if not repo_desktop_ready(settings):
        return None
    info = installed_info()
    code, name = desktop_version(settings.get("jawn_dir") or default_jawn_dir())
    try:
        installed_code = int(info.get("versionCode") or 0)
    except (TypeError, ValueError):
        installed_code = 0
    if not code or code <= installed_code:
        return None
    if _tree_stamp(repo_desktop_dir(settings)) == info.get("stamp"):
        return None
    return (name or "", code)


def apply_update(settings):
    """Copy the repo's desktop/ over this copy and record the new version.

    Returns (ok, versionName, versionCode). The caller restarts to run the new
    code (a running process cannot swap its own modules). The stored login
    ticket lives in the config dir, not here, so the copy leaves it alone."""
    if not repo_desktop_ready(settings):
        return (False, "", 0)
    repo = repo_desktop_dir(settings)
    import shutil
    for dirpath, dirnames, filenames in _walk_installable(repo):
        rel = os.path.relpath(dirpath, repo)
        dest = DESKTOP_DIR if rel == "." else os.path.join(DESKTOP_DIR, rel)
        try:
            os.makedirs(dest, exist_ok=True)
        except OSError:
            continue
        for name in filenames:
            try:
                shutil.copy2(os.path.join(dirpath, name), os.path.join(dest, name))
            except OSError:
                pass
    for tool in ("jawnosctl", "jawnos-desktop", "jawnos-qt", "jawnos-bt-daemon"):
        path = os.path.join(DESKTOP_DIR, tool)
        if os.path.exists(path):
            try:
                os.chmod(path, 0o755)
            except OSError:
                pass
    code, vname = desktop_version(settings.get("jawn_dir") or default_jawn_dir())
    _write_installed_stamp(_tree_stamp(repo), vname, code)
    return (True, vname, code)


# --------------------------------------------------------------------------
# the jawn tree: config, ports, liveness
# --------------------------------------------------------------------------

def read_app_config(jawn_dir):
    """Parse <jawn_dir>/config.json. It is written with a UTF-8 BOM."""
    try:
        with open(os.path.join(jawn_dir, "config.json"), "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _as_port(value, fallback):
    try:
        port = int(str(value).strip())
        return port if 0 < port < 65536 else fallback
    except (TypeError, ValueError):
        return fallback


def jawn_working_port(jawn_dir):
    return _as_port(read_app_config(jawn_dir).get("working_port"), DOCK_PORT)


def jawn_log_path(jawn_dir):
    """Where jawn writes manager.log (config's 'logfile', default ~/manager.log)."""
    raw = read_app_config(jawn_dir).get("logfile") or "~/manager.log"
    return os.path.expanduser(raw)


def jawn_stdout_log_path():
    return os.path.join(state_dir(), "jawn-stdout.log")


DEFAULT_LOG_CAP = 32 * 1024 * 1024


def cap_log(path, cap=DEFAULT_LOG_CAP):
    """Keep a grown console log bounded.

    The tree's stdout is opened append-only here and inherited by ./jawn, so the
    writer's descriptor is O_APPEND: truncating the file makes the next write
    land at offset 0 instead of leaving a hole. The tail is copied to <path>.1
    first, so the last words before the cap survive.
    """
    try:
        size = os.path.getsize(path)
    except OSError:
        return False
    if size <= cap:
        return False
    keep = min(size, cap // 2)
    try:
        with open(path, "rb") as src:
            src.seek(size - keep)
            tail = src.read()
        with open(path + ".1", "wb") as dst:
            dst.write(tail)
        os.chmod(path + ".1", 0o600)
        os.truncate(path, 0)
    except OSError:
        return False
    return True


def ble_log_path():
    return os.path.join(state_dir(), "jawnos-bt.log")


def ble_pid_path():
    return os.path.join(state_dir(), "jawnos-bt.pid")


def port_open(port, host="127.0.0.1", timeout=0.4):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def jawn_up(jawn_dir):
    """jawn answers on its working port and always on the dock port (3000)."""
    reap_detached()
    return port_open(jawn_working_port(jawn_dir)) or port_open(DOCK_PORT)


# --------------------------------------------------------------------------
# a start request, while the tree is still coming up
# --------------------------------------------------------------------------

# start/restart return as soon as the tree is spawned; the port can take a
# while to answer on a slow disk. The Qt panel, the tray badge and the GTK
# dashboard all want to say "starting..." for that window rather than "not
# running", and they share this clock so they always agree. It describes this
# process's own request, so it is deliberately not persisted.
STARTING_WINDOW = 150.0
_start_requested_at = 0.0


def mark_start_requested(now=None):
    """Remember when a start or restart was asked for (monotonic seconds)."""
    global _start_requested_at
    _start_requested_at = time.monotonic() if now is None else float(now)
    return _start_requested_at


def start_requested_at():
    return _start_requested_at


def clear_start_requested():
    global _start_requested_at
    _start_requested_at = 0.0


def jawn_status(jawn_up, now=None):
    """``(label, tone)`` for jawn's status line and the tray badge.

    ``tone`` is green, amber or red. Running is green; a start/restart this
    process asked for and that is younger than ``STARTING_WINDOW`` is amber
    with its age; anything else is red. The panel, the tray badge and the
    session bar all read this one rule.
    """
    if jawn_up:
        clear_start_requested()
        return "running", "green"
    started = start_requested_at()
    if started:
        age = max(0, int((time.monotonic() if now is None else now) - started))
        if age < STARTING_WINDOW:
            return "starting... (%ds)" % age, "amber"
    return "not running", "red"


def jawn_health(jawn_dir, timeout=2.5):
    """Ask the app's own /manager/health over loopback. Returns a dict or None.

    The route trusts a loopback caller (no session needed), so status can report
    what the running tree itself says - version, uptime, peers - and not merely
    that a port is open. The cert is self-signed, so it is not verified.
    """
    port = jawn_working_port(jawn_dir)
    request = urllib.request.Request(
        "https://127.0.0.1:%d/manager/health" % port,
        headers={"X-Requested-With": "jawnosctl"})
    context = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:
        return None


def ble_up():
    return port_open(BRIDGE_PORT)


def running_version(jawn_dir):
    """The version the live tree reports, or None when it cannot say."""
    health = jawn_health(jawn_dir)
    if not health:
        return None
    version = str(health.get("version") or "").strip()
    return version or None


def version_mismatch(jawn_dir):
    """(running, on_disk) when the live tree is not running the tree on disk.

    The running version is frozen at boot, while a code sync (git or a peer
    tar) can replace the files and VERSION without restarting the tree - that
    is how a host sat on old code with a current VERSION file. Any difference
    is a reason to restart, not only a newer disk: a rollback needs the same
    treatment. None means the tree is down, or the two versions agree.
    """
    if not jawn_up(jawn_dir):
        return None
    disk = jawn_version(jawn_dir)
    running = running_version(jawn_dir)
    if not disk or not running or disk == running:
        return None
    return (running, disk)


def restart_if_stale(jawn_dir, with_ble=True):
    """Keep the tree up, and on the on-disk version.

    Returns (action, message): ``current``, ``started``, ``down``, ``restarted``
    or ``failed``. A tree that is simply down is started, so ``jawnosctl watch``
    is a supervisor and not only a version chaser; a running tree whose version
    is not the on-disk one is restarted whole, as the Restart button is, so no
    half-boot window is left behind.
    """
    mismatch = version_mismatch(jawn_dir)
    if not mismatch:
        if not jawn_up(jawn_dir):
            if is_held():
                return "held", "stopped by request"
            ok, message = start_all(jawn_dir, with_ble=with_ble)
            if ok:
                return "started", "jawn was down; started it (%s)" % message
            return "failed", "jawn is down and could not be started (%s)" % message
        return "current", "running the on-disk version"
    running, disk = mismatch
    ok, message = restart_all(jawn_dir, with_ble=with_ble)
    if ok:
        return "restarted", "restarted %s -> %s" % (running, disk)
    return "failed", "restart failed (%s); running %s, disk %s" % (message, running, disk)


# --------------------------------------------------------------------------
# process helpers
# --------------------------------------------------------------------------
# pid_alive, the /proc scans, detached spawn/reap and the jawn/BLE lifecycle
# live in core_process.py and are re-exported at the top.


# --------------------------------------------------------------------------
# the combined lifecycle the Start/Stop/Restart buttons drive
# --------------------------------------------------------------------------
#
# The checkbox says "Start/stop the BLE bridge with jawn", so jawn and the
# bridge move together through one call. The dashboard used to start jawn
# alone, so its Start left the watch with no bridge while the CLI's start did
# not -- the two now share these wrappers.

def start_all(jawn_dir, with_ble=True):
    ok, message = start_jawn(jawn_dir)
    if ok and with_ble:
        _ok, ble_message = start_ble()
        message = "%s; %s" % (message, ble_message)
    return ok, message


def stop_all(jawn_dir, with_ble=True, wait=12.0):
    message = ""
    # A deliberate stop is not a slow start: no amber "starting..." window.
    clear_start_requested()
    if with_ble:
        message = stop_ble()[1]
    ok, jawn_message = stop_jawn(jawn_dir, wait=wait)
    return ok, (message + "; " + jawn_message) if message else jawn_message


def restart_all(jawn_dir, with_ble=True):
    ok, message = restart_jawn(jawn_dir)
    # a real restart takes the bridge down with the tree only if it was tied; if
    # it is actually down afterwards and the checkbox asks for it, bring it back
    if ok and with_ble and not ble_up():
        _ok, ble_message = start_ble()
        message = "%s; %s" % (message, ble_message)
    return ok, message


# --------------------------------------------------------------------------
# autostart (the XDG analogue of the Android boot receiver)
# --------------------------------------------------------------------------

# The XDG autostart unit lives in core_autostart.py and is re-exported at the
# top (autostart_path, autostart_enabled, set_autostart).


# --------------------------------------------------------------------------
# opening things
# --------------------------------------------------------------------------
# manager_host lives in core_secrets.py; desktop_launcher, open_ui, the
# terminal list and open_console live in core_shell.py. Both are re-exported
# at the top.


def tail_log(path, lines=200):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            block = min(size, max(lines * 256, 16384))
            fh.seek(size - block)
            data = fh.read()
        text = data.decode("utf-8", "replace")
        return "\n".join(text.splitlines()[-lines:])
    except OSError:
        return ""


# --------------------------------------------------------------------------
# a one-shot status snapshot
# --------------------------------------------------------------------------

def status(settings=None):
    settings = settings or load_settings()
    jawn_dir = settings["jawn_dir"]
    up = jawn_up(jawn_dir)
    return {
        "jawn_dir": jawn_dir,
        "jawn_up": up,
        "jawn_port": jawn_working_port(jawn_dir),
        "health": jawn_health(jawn_dir) if up else None,
        "ble_up": ble_up(),
        "autostart": autostart_enabled(),
        "ble_with_jawn": bool(settings.get("ble_with_jawn", True)),
    }


# --------------------------------------------------------------------------
# tailnet (Tailscale) control
# --------------------------------------------------------------------------
# The phone carries an embedded tailnet client; on the desktop the tailnet is
# the machine's own tailscaled, so "start" and "stop" are `tailscale up` and
# `tailscale down`. The dashboard shows the state and offers both, and a small
# watcher restarts the tunnel after the physical network changes -- the same
# rule the phone needs, because a switch can leave the old route pinned.

# Interfaces that are not the physical network (the tunnel itself, containers,
# bridges and the loopback). Names are matched as prefixes.
_NOT_PHYSICAL = (
    "lo", "tailscale", "tun", "tap", "wg", "docker", "veth",
    "br-", "virbr", "vmnet", "zt",
)

_TAILNET_NET = {"ifaces": None, "changed_at": 0.0, "restarted_for": 0.0}


def tailscale_bin():
    return os.environ.get("TAILSCALE_BIN", "tailscale")


def _tailscale(args, timeout=25):
    """Run the tailscale CLI. Returns (ok, message) -- never raises."""
    try:
        out = subprocess.run(
            [tailscale_bin()] + list(args),
            capture_output=True, text=True, timeout=timeout,
        )
        text = ((out.stdout or "") + (out.stderr or "")).strip()
        ok = out.returncode == 0
        if not text:
            text = "tailscale %s: exit %d" % (args[0], out.returncode)
        return ok, text
    except Exception as exc:  # a missing binary is a normal answer here
        return False, str(exc)


def tailnet_state():
    """The tailnet's backend state, as the dashboard's status line needs it."""
    try:
        out = subprocess.run(
            [tailscale_bin(), "status", "--json"],
            capture_output=True, text=True, timeout=4,
        )
        data = json.loads(out.stdout or "{}")
        state = data.get("BackendState", "")
        return {
            "available": bool(state),
            "state": state,
            "running": state == "Running",
            "login_url": data.get("AuthURL", "") or "",
        }
    except Exception as exc:
        return {"available": False, "state": "", "running": False, "error": str(exc)}


def tailnet_up():
    return _tailscale(["up"])


def tailnet_down():
    return _tailscale(["down"])


def physical_interfaces():
    """The machine's non-tunnel IPv4 networks, as a stable tuple.

    A switch between two Wi-Fi networks often keeps the same interface name, so
    the address (and the default gateway) is part of the signature; the tunnel's
    own interface is left out so the VPN coming up does not look like a switch.
    """
    try:
        out = subprocess.run(
            ["ip", "-o", "-4", "addr", "show", "up", "scope", "global"],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except Exception:
        return ()
    parts = set()
    for line in out.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        name = fields[1].split("@")[0]
        if any(name.startswith(prefix) for prefix in _NOT_PHYSICAL):
            continue
        parts.add(name + "|" + fields[3])
    try:
        routes = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except Exception:
        routes = ""
    match = re.search(r"default\s+via\s+(\S+)\s+dev\s+(\S+)", routes)
    if match and not any(match.group(2).startswith(prefix) for prefix in _NOT_PHYSICAL):
        parts.add("gateway|" + match.group(1))
    return tuple(sorted(parts))


def tailnet_network_tick(state=None):
    """Restart a running tailnet after the physical network changes.

    The call is cheap and is meant to ride the dashboard's two-second status
    tick. A change is debounced for three seconds (a Wi-Fi switch produces a
    down and an up in quick succession), then a running tunnel is stopped and
    started again so the Go client binds the new default route instead of the
    old one. A stopped tunnel is left stopped.
    """
    state = state if state is not None else {}
    now = time.monotonic()
    ifaces = physical_interfaces()
    if not ifaces:
        return state
    last = _TAILNET_NET.get("ifaces")
    if last is None:
        _TAILNET_NET["ifaces"] = ifaces
        return state
    if ifaces != last:
        _TAILNET_NET["ifaces"] = ifaces
        _TAILNET_NET["changed_at"] = now
        return state
    changed_at = _TAILNET_NET.get("changed_at") or 0.0
    if not changed_at or now - changed_at < 3.0:
        return state
    if _TAILNET_NET.get("restarted_for") == changed_at:
        return state
    _TAILNET_NET["restarted_for"] = changed_at
    if not state.get("running"):
        return state
    _tailscale(["down"])
    time.sleep(1.0)
    ok, message = _tailscale(["up"])
    state["network_restart"] = ("restarted after a network change"
                                if ok else ("network restart failed: " + message))
    return state
