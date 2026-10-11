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
  SIGKILLs the tree and leaves the master answering ``~/.process_watch``.
* ``restart`` prefers jawn's own sanctioned path (write ``restart`` to
  ``~/.president/status``) and falls back to stop-then-start.
"""

import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import webbrowser

from . import DESKTOP_DIR

# The BLE bridge listens here on both Android and Linux; keep the number so
# scripts/jawn-bt (the shared client) needs no change.
BRIDGE_PORT = 45999
# config.json's "port" (the dock); 3000 is always answered even when the
# working port is something else.
DOCK_PORT = 3000
DEFAULT_DIRNAME = "jawnos"


# --------------------------------------------------------------------------
# paths and settings
# --------------------------------------------------------------------------

def home():
    return os.path.expanduser("~")


def _xdg(env, default):
    value = os.environ.get(env)
    if value:
        return value
    return os.path.join(home(), default)


def config_dir():
    return os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "jawnos")


def state_dir():
    return os.path.join(_xdg("XDG_STATE_HOME", ".local/state"), "jawnos")


def settings_path():
    return os.path.join(config_dir(), "desktop.json")


def daemon_path():
    """The BLE bridge daemon that ships beside this package."""
    return os.path.join(DESKTOP_DIR, "jawnos-bt-daemon")


def default_jawn_dir():
    """Prefer the tree this package lives in (a checkout); else ~/jawnos.

    The package sits at ``<root>/desktop/jawnos_desktop/core.py``, so two
    levels above the package directory is the repo root."""
    root = os.path.dirname(DESKTOP_DIR)
    if os.path.exists(os.path.join(root, "jawn")):
        return root
    return os.path.join(home(), DEFAULT_DIRNAME)


def jawn_version(jawn_dir):
    """The human version from <jawn_dir>/VERSION, or None if unavailable."""
    try:
        with open(os.path.join(jawn_dir, "VERSION"), "r", encoding="utf-8") as fh:
            value = fh.read().strip()
        return value or None
    except OSError:
        return None


def load_settings():
    data = {
        "jawn_dir": default_jawn_dir(),
        "autostart": False,
        "ble_with_jawn": True,
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
    return port_open(jawn_working_port(jawn_dir)) or port_open(DOCK_PORT)


def ble_up():
    return port_open(BRIDGE_PORT)


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# --------------------------------------------------------------------------
# process helpers
# --------------------------------------------------------------------------

def _perl():
    return shutil.which("perl") or "perl"


def _perl_env():
    """Environment for the spawned perl, with the user's local::lib on @INC.

    The user's PERL5LIB lives in ~/.zshrc, which a desktop-launched app never
    sources -- so jawn (and the killer, which also uses local modules) came up
    with only the system @INC and died on 'Can't locate Mojo/...'. Mirror the
    shell: put ~/perl5/lib/perl5 (and its arch/version subdirs) first."""
    env = dict(os.environ)
    roots = [os.path.join(home(), "perl5", "lib", "perl5")]
    extra = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for entry in os.listdir(root):
            if "-linux-" in entry or re.match(r"^\d+\.\d+", entry):
                candidate = os.path.join(root, entry)
                if os.path.isdir(candidate):
                    extra.append(candidate)
    existing = [p for p in env.get("PERL5LIB", "").split(os.pathsep) if p]
    merged = []
    for path in roots + extra + existing:
        if path and path not in merged:
            merged.append(path)
    if merged:
        env["PERL5LIB"] = os.pathsep.join(merged)
    return env


def spawn_detached(argv, cwd, log_path, env=None):
    """Start a process in its own session, output appended to log_path.

    Its own session means it survives this call and is not killed when a
    terminal closes -- the desktop equivalent of a background Termux task.
    """
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    logf = open(log_path, "ab", buffering=0)
    try:
        proc = subprocess.Popen(
            argv, cwd=cwd, stdin=subprocess.DEVNULL,
            stdout=logf, stderr=subprocess.STDOUT,
            start_new_session=True, close_fds=True, env=env,
        )
    finally:
        logf.close()
    return proc


def start_jawn(jawn_dir):
    """Start jawn. Skips if it is already up. Returns (ok, message)."""
    if jawn_up(jawn_dir):
        return True, "jawn is already running"
    if not os.path.exists(os.path.join(jawn_dir, "jawn")):
        return False, "no 'jawn' launcher in %s" % jawn_dir
    argv = [_perl(), "./jawn"]
    spawn_detached(argv, jawn_dir, jawn_stdout_log_path(), env=_perl_env())
    return True, "starting jawn"


def stop_jawn(jawn_dir, wait=12.0):
    """Take the whole tree down via jawn's own killer (the phone's Stop path)."""
    killer = os.path.join(jawn_dir, "scripts", "manager_killer.pl")
    if not os.path.exists(killer):
        return False, "no scripts/manager_killer.pl in %s" % jawn_dir
    subprocess.run([_perl(), "scripts/manager_killer.pl", "master"], cwd=jawn_dir, env=_perl_env())
    deadline = time.time() + wait
    while time.time() < deadline:
        if not jawn_up(jawn_dir):
            return True, "jawn stopped"
        time.sleep(0.3)
    return False, "jawn still answering after the sweep"


def restart_jawn(jawn_dir):
    """Restart without a full stop. jawn's own status file is the clean path."""
    status_file = os.path.join(home(), ".president", "status")
    if jawn_up(jawn_dir) and os.path.isdir(os.path.dirname(status_file)):
        try:
            with open(status_file, "w", encoding="utf-8") as fh:
                fh.write("restart")
            return True, "restart queued (jawn reboots President.pl in ~2s)"
        except OSError as exc:
            return False, "could not write %s: %s" % (status_file, exc)
    stop_jawn(jawn_dir)
    ok, message = start_jawn(jawn_dir)
    return ok, message


# --------------------------------------------------------------------------
# the BLE bridge
# --------------------------------------------------------------------------

def start_ble():
    """Bring up the BLE bridge daemon. No-op if the port already answers."""
    if ble_up():
        return True, "BLE bridge already running"
    daemon = daemon_path()
    if not os.path.exists(daemon):
        return False, "BLE bridge daemon not found at %s" % daemon
    spawn_detached([sys.executable or "python3", daemon], DESKTOP_DIR, ble_log_path())
    deadline = time.time() + 8.0
    while time.time() < deadline:
        if ble_up():
            return True, "BLE bridge started"
        time.sleep(0.3)
    return False, "BLE bridge did not come up (see %s)" % ble_log_path()


def stop_ble(wait=6.0):
    """Ask the daemon to shut down, then make sure it did.

    The graceful path is a ``shutdown`` command; if that does not land (a busy
    or wedged bridge) fall back to the pid file, so stop is never a no-op."""
    if not ble_up():
        _remove_stale_pidfile()
        return True, "BLE bridge is not running"
    try:
        from . import ble as _ble
        _ble.send_command({"cmd": "shutdown"}, wait_event=None, timeout=0.6)
    except Exception:
        pass
    if _wait_port_closed(wait):
        return True, "BLE bridge stopped"
    pid = _read_pidfile()
    if pid:
        for signum in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(pid, signum)
            except OSError:
                break
            if _wait_port_closed(3.0):
                return True, "BLE bridge stopped"
    _remove_stale_pidfile()
    if ble_up():
        return False, "BLE bridge still answering on %d" % BRIDGE_PORT
    return True, "BLE bridge stopped"


def _wait_port_closed(timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not ble_up():
            return True
        time.sleep(0.3)
    return False


def _read_pidfile():
    try:
        with open(ble_pid_path(), "r", encoding="utf-8") as fh:
            pid = int(fh.read().strip())
        return pid if pid_alive(pid) else None
    except (OSError, ValueError):
        return None


def _remove_stale_pidfile():
    try:
        os.remove(ble_pid_path())
    except OSError:
        pass


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
    if with_ble:
        message = stop_ble()[1]
    ok, jawn_message = stop_jawn(jawn_dir, wait=wait)
    return ok, (message + "; " + jawn_message) if message else jawn_message


def restart_all(jawn_dir, with_ble=True):
    ok, message = restart_jawn(jawn_dir)
    # A queued status-file restart leaves the bridge alone; only bring it back
    # if the checkbox asks for it and it is actually down.
    if ok and with_ble and not ble_up():
        _ok, ble_message = start_ble()
        message = "%s; %s" % (message, ble_message)
    return ok, message


# --------------------------------------------------------------------------
# autostart (the XDG analogue of the Android boot receiver)
# --------------------------------------------------------------------------

def autostart_path():
    return os.path.join(_xdg("XDG_CONFIG_HOME", ".config"), "autostart", "jawnos-bt.desktop")


def autostart_enabled():
    return os.path.exists(autostart_path())


def set_autostart(enabled):
    path = autostart_path()
    if not enabled:
        for candidate in (path, path.replace("jawnos-bt.desktop", "jawnos-desktop.desktop")):
            try:
                os.remove(candidate)
            except OSError:
                pass
        return not autostart_enabled()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(_AUTOSTART_UNIT.format(
            daemon=daemon_path(),
            log=ble_log_path(),
            python=sys.executable,
        ))
    return True


_AUTOSTART_UNIT = """[Desktop Entry]
Type=Application
Name=JawnOS BLE bridge
Comment=Start the JawnOS Bluetooth LE bridge at login
Exec={python} "{daemon}"
Icon=jawnos
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
"""


# --------------------------------------------------------------------------
# opening things
# --------------------------------------------------------------------------

def manager_host():
    """The host the stored ticket logs in on.

    The ticket's session cookie is scoped to that host, so the manager must be
    opened from it too -- the loopback address is a different origin and shows
    the login gate. Falls back to loopback when there is no stored ticket."""
    try:
        from urllib.parse import urlparse
        from . import secrets
        ticket = secrets.load()
        if ticket:
            return urlparse(ticket).hostname or "127.0.0.1"
    except Exception:
        pass
    return "127.0.0.1"


def open_ui(jawn_dir):
    """Open the manager in the user's browser.

    Prefer the stored ticket: it is addressed on the machine's own domain and
    mints the session cookie on the way, so the browser lands on the manager
    instead of the gate on a host it has not logged in to. Fall back to the
    manager on the ticket's host, then loopback."""
    try:
        from . import secrets
        ticket = secrets.load()
        if ticket:
            return webbrowser.open(ticket)
    except Exception:
        pass
    port = jawn_working_port(jawn_dir)
    return webbrowser.open("https://%s:%d/manager" % (manager_host(), port))


_TERMINALS = [
    ("x-terminal-emulator", ["-e"]),
    ("kgx", ["-e"]),
    ("gnome-terminal", ["--"]),
    ("konsole", ["-e"]),
    ("alacritty", ["-e"]),
    ("kitty", []),
    ("wezterm", ["start", "--"]),
    ("xterm", ["-e"]),
]


def open_console(jawn_dir):
    """Open a terminal running jawn in the foreground, as a hand-run would."""
    for name, extra in _TERMINALS:
        binary = shutil.which(name)
        if not binary:
            continue
        argv = [binary] + extra + [_perl(), "./jawn"]
        try:
            spawn_detached(argv, jawn_dir, jawn_stdout_log_path(), env=_perl_env())
            return True, "opened %s" % name
        except OSError:
            continue
    return False, "no terminal emulator found"


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
    return {
        "jawn_dir": jawn_dir,
        "jawn_up": jawn_up(jawn_dir),
        "jawn_port": jawn_working_port(jawn_dir),
        "ble_up": ble_up(),
        "autostart": autostart_enabled(),
        "ble_with_jawn": bool(settings.get("ble_with_jawn", True)),
    }
