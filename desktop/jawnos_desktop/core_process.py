"""Process supervision for the desktop shell.

Linux spawns with ``subprocess.Popen(start_new_session=True)``, finds masters
and zombies through ``/proc``, and signals with ``os.kill``. Windows uses the
Windows process API instead:

* spawn: ``CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS`` so the tree outlives
  the shell and gets no console window.
* discovery: the master's ``~/.president/pid`` record, checked against the
  running image (``QueryFullProcessImageNameW``); a recycled pid is never a
  master.
* kill: ``taskkill /PID <pid> /T /F`` for the forced path; the clean path is
  still the tree's own ``manager_killer.pl``.
* reap: only the ``Popen`` objects this process owns; Windows has no zombie
  sweep to do.
* environment: the bundled ``runtime\\perl\\bin`` and ``runtime\\c\\bin`` go first
  on ``PATH``, with ``JAWNOS_PORTABLE`` / ``JAWNOS_TRANSPORT`` / ``JAWNOS_DIR``
  matching ``launch.bat``.

The supervision functions read the liveness helpers from ``core`` at call time
so a test can monkeypatch ``core.jawn_up`` exactly as before.
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import time

from . import DESKTOP_DIR
from .core_paths import (
    ble_log_path,
    ble_pid_path,
    daemon_path,
    home,
    jawn_stdout_log_path,
)

IS_WINDOWS = os.name == "nt"


def _windows_process_name(pid):
    """The image name of a running pid, or ``""`` when it is gone.

    ``os.kill(pid, 0)`` is not a liveness probe on Windows: Python maps any
    other signal (including 0) to ``TerminateProcess``. Asking for the image
    name is safe, and it also rejects a recycled pid that is not the master.
    """
    if not pid:
        return ""
    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.windll.kernel32
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD),
        ]
        # PROCESS_QUERY_LIMITED_INFORMATION is enough for the image name and
        # is what a per-user process grants without elevation.
        handle = kernel32.OpenProcess(0x1000, False, int(pid))
        if not handle:
            return ""
        try:
            buf = ctypes.create_unicode_buffer(1024)
            size = wintypes.DWORD(len(buf))
            if not kernel32.QueryFullProcessImageNameW(
                    handle, 0, buf, ctypes.byref(size)):
                return ""
            return os.path.basename(buf.value)
        finally:
            kernel32.CloseHandle(handle)
    except Exception:
        return ""


def pid_alive(pid):
    if not pid:
        return False
    if IS_WINDOWS:
        return bool(_windows_process_name(pid))
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _windows_master_pids():
    """The master recorded in ``~/.president/pid``, if it is still perl.exe.

    The master writes that file on every boot (``president/pid``), and the
    Windows updater already reads it for the same purpose. A pid that is alive
    but is not a perl image is a recycled pid, not the master.
    """
    path = os.path.join(home(), ".president", "pid")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return []
    if not pid_alive(pid):
        return []
    name = _windows_process_name(pid)
    if not name.lower().startswith("perl"):
        return []
    return [pid]


def _jawn_master_pids():
    """PIDs of a running jawn master, however it was invoked.

    On Linux this scans ``/proc``: the desktop starts it as `perl ./jawn`, but
    an autostart or a terminal can use the absolute path, so match the script's
    basename instead. On Windows the master's own pid record is the source.
    """
    if IS_WINDOWS:
        return _windows_master_pids()
    pids = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(os.path.join("/proc", name, "cmdline"), "rb") as fh:
                raw = fh.read().replace(b"\x00", b" ")
        except OSError:
            continue
        cmd = raw.decode("utf-8", "replace")
        if "perl" not in cmd:
            continue
        if any(os.path.basename(part) == "jawn" for part in cmd.split()):
            pids.append(int(name))
    return pids


# --------------------------------------------------------------------------
# process helpers
# --------------------------------------------------------------------------

def _perl(jawn_dir=None):
    if IS_WINDOWS:
        override = os.environ.get("JAWNOS_PERL")
        if override and os.path.isfile(override):
            return override
        if jawn_dir:
            root = os.path.dirname(os.path.abspath(jawn_dir))
            candidate = os.path.join(root, "runtime", "perl", "bin", "perl.exe")
            if os.path.isfile(candidate):
                return candidate
        return shutil.which("perl") or "perl"
    return shutil.which("perl") or "perl"


def _perl_env(jawn_dir=None):
    """Environment for the spawned perl.

    On Linux the user's PERL5LIB lives in ~/.zshrc, which a desktop-launched app
    never sources -- so jawn (and the killer, which also uses local modules)
    came up with only the system @INC and died on 'Can't locate Mojo/...'.
    Mirror the shell: put ~/perl5/lib/perl5 (and its arch/version subdirs)
    first.

    On Windows the bundle carries its own Strawberry tree; the same three
    directories and the portable/tcp flags ``launch.bat`` sets are used here, so
    a shell-started tree and a launcher-started tree are the same tree."""
    env = dict(os.environ)
    if IS_WINDOWS:
        if jawn_dir:
            root = os.path.dirname(os.path.abspath(jawn_dir))
            c_bin = os.path.join(root, "runtime", "c", "bin")
            perl_bin = os.path.join(root, "runtime", "perl", "bin")
            if os.path.isdir(perl_bin):
                env.setdefault("JAWNOS_PORTABLE", "1")
                env.setdefault("JAWNOS_TRANSPORT", "tcp")
                env["JAWNOS_DIR"] = os.path.abspath(jawn_dir)
                existing = [p for p in env.get("PATH", "").split(os.pathsep) if p]
                merged = []
                for path in (c_bin, perl_bin) + tuple(existing):
                    if path and path not in merged:
                        merged.append(path)
                env["PATH"] = os.pathsep.join(merged)
        return env
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
    from . import core as _core

    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    _core.cap_log(log_path)
    logf = open(log_path, "ab", buffering=0)
    try:
        if IS_WINDOWS:
            # DETACHED_PROCESS keeps the tree out of the shell's console and
            # lets it outlive the shell; CREATE_NEW_PROCESS_GROUP keeps the
            # tree's own signals from reaching this process.
            proc = subprocess.Popen(
                argv, cwd=cwd, stdin=subprocess.DEVNULL,
                stdout=logf, stderr=subprocess.STDOUT,
                creationflags=0x00000008 | 0x00000200,
                close_fds=True, env=env,
            )
        else:
            proc = subprocess.Popen(
                argv, cwd=cwd, stdin=subprocess.DEVNULL,
                stdout=logf, stderr=subprocess.STDOUT,
                start_new_session=True, close_fds=True, env=env,
            )
    finally:
        logf.close()
    # A detached process is still our child (start_new_session only moves its
    # session, not its parent). Python reaps a Popen only when it is polled or
    # waited on, so dropping the object left an exited jawn master as
    # `[perl] <defunct>` under the desktop app for as long as it ran.
    _detached_children.append(proc)
    return proc


# Detached children we still owe a waitpid(). Polled from the dashboard tick;
# poll() collects an exited child and is a no-op while it runs.
_detached_children = []


def reap_detached():
    """Collect detached children that have exited, plus any zombie of ours.

    Popen.poll() only knows the processes we spawned in this run, so a stale
    zombie inherited from an earlier launch is found by its /proc state instead.
    """
    for proc in list(_detached_children):
        try:
            if proc.poll() is not None:
                _detached_children.remove(proc)
        except OSError:
            _detached_children.remove(proc)
    if IS_WINDOWS:
        # Windows has no zombie state and no /proc entries to sweep.
        return
    me = os.getpid()
    try:
        entries = os.listdir("/proc")
    except OSError:
        return
    for name in entries:
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % name, "rb") as fh:
                line = fh.read().decode("utf-8", "replace")
        except OSError:
            continue
        # "pid (comm) state ppid ..." - comm may hold spaces and parens
        fields = line[line.rfind(")") + 2:].split()
        if len(fields) < 2 or fields[0] != "Z" or fields[1] != str(me):
            continue
        try:
            os.waitpid(int(name), os.WNOHANG)
        except OSError:
            pass


def start_jawn(jawn_dir):
    """Start jawn. Skips if it is already up, or a master is mid-restart."""
    from . import core as _core

    # An explicit start ends a deliberate stop; the watcher may supervise again.
    _core.set_held(False)
    _core.mark_start_requested()
    if _core.jawn_up(jawn_dir):
        return True, "jawn is already running"
    if _jawn_master_pids():
        return True, "a jawn master is already running (mid-restart); not starting a second"
    if not os.path.exists(os.path.join(jawn_dir, "jawn")):
        return False, "no 'jawn' launcher in %s" % jawn_dir
    argv = [_perl(jawn_dir), "jawn" if IS_WINDOWS else "./jawn"]
    try:
        spawn_detached(argv, jawn_dir, jawn_stdout_log_path(),
                       env=_perl_env(jawn_dir))
    except OSError as exc:
        return False, "could not start jawn (%s)" % exc
    return True, "starting jawn"


def stop_jawn(jawn_dir, wait=12.0):
    """Take the whole tree and the master down. The killer is the clean path:
    it first asks the tree to leave over its control channel, then sweeps what
    did not answer; a master still alive after it is terminated directly, so
    stop is never a no-op when the master is wedged."""
    from . import core as _core

    # Remember the choice before the killer runs: a watcher tick during the stop
    # must not read the gap as a crash and start the tree again.
    _core.set_held(True)
    killer = os.path.join(jawn_dir, "scripts", "manager_killer.pl")
    if not os.path.exists(killer):
        return False, "no scripts/manager_killer.pl in %s" % jawn_dir
    subprocess.run([_perl(jawn_dir), "scripts/manager_killer.pl", "master"],
                   cwd=jawn_dir, env=_perl_env(jawn_dir))
    deadline = time.time() + wait
    while time.time() < deadline:
        if not _core.jawn_up(jawn_dir) and not _jawn_master_pids():
            return True, "jawn stopped"
        time.sleep(0.3)
    pids = _jawn_master_pids()
    if IS_WINDOWS:
        for pid in pids:
            try:
                subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                               capture_output=True, timeout=15)
            except (OSError, subprocess.SubprocessError):
                pass
        if not _jawn_master_pids():
            return True, "jawn stopped"
    else:
        for signum in (signal.SIGTERM, signal.SIGKILL):
            for pid in _jawn_master_pids():
                try:
                    os.kill(pid, signum)
                except OSError:
                    pass
            time.sleep(0.5)
            if not _jawn_master_pids():
                return True, "jawn stopped"
    return False, "jawn still answering after the sweep"


def restart_jawn(jawn_dir):
    """A real restart: kill the master, start a fresh one, and wait for it to
    answer, so the caller can trust the result (no half-boot window)."""
    from . import core as _core

    # The whole restart reads as "starting...", the stop included. Marking it
    # here means the tray does not drop through red on the way to amber.
    _core.mark_start_requested()
    stop_jawn(jawn_dir)
    ok, message = start_jawn(jawn_dir)
    if not ok:
        return ok, message
    deadline = time.time() + 90.0
    while time.time() < deadline:
        if _core.jawn_up(jawn_dir):
            return True, "jawn restarted"
        time.sleep(0.5)
    return False, "jawn did not come back up (see %s)" % _core.jawn_log_path(jawn_dir)


# --------------------------------------------------------------------------
# the BLE bridge
# --------------------------------------------------------------------------

def start_ble():
    """Bring up the BLE bridge daemon. No-op if the port already answers."""
    from . import core as _core

    if IS_WINDOWS:
        # The bridge is a BlueZ (D-Bus) central; Windows has no BlueZ. A no-op
        # that reports success keeps Start from failing for a feature that is
        # simply not part of this platform yet.
        return True, "the BLE bridge is not available on Windows"
    if _core.ble_up():
        return True, "BLE bridge already running"
    daemon = daemon_path()
    if not os.path.exists(daemon):
        return False, "BLE bridge daemon not found at %s" % daemon
    spawn_detached([sys.executable or "python3", daemon], DESKTOP_DIR, ble_log_path())
    deadline = time.time() + 8.0
    while time.time() < deadline:
        if _core.ble_up():
            return True, "BLE bridge started"
        time.sleep(0.3)
    return False, "BLE bridge did not come up (see %s)" % ble_log_path()


def stop_ble(wait=6.0):
    """Ask the daemon to shut down, then make sure it did.

    The graceful path is a ``shutdown`` command; if that does not land (a busy
    or wedged bridge) fall back to the pid file, so stop is never a no-op."""
    from . import core as _core

    if IS_WINDOWS:
        return True, "the BLE bridge is not available on Windows"
    if not _core.ble_up():
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
    if _core.ble_up():
        return False, "BLE bridge still answering on %d" % _core.BRIDGE_PORT
    return True, "BLE bridge stopped"


def _wait_port_closed(timeout):
    from . import core as _core

    deadline = time.time() + timeout
    while time.time() < deadline:
        if not _core.ble_up():
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
