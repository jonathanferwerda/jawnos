"""Process supervision for the desktop shell.

Linux (today) spawns with ``subprocess.Popen(start_new_session=True)``, finds
masters and zombies through ``/proc``, and signals with ``os.kill``. The
platform branch points the macOS and Windows lanes fill in P2/P3 are:

* spawn: ``start_new_session=True`` becomes ``CREATE_NEW_PROCESS_GROUP`` /
  ``DETACHED_PROCESS`` on ``os.name == "nt"``; macOS keeps ``setsid``.
* discovery: ``/proc/*/cmdline`` and ``/proc/*/stat`` become ``ps`` on
  ``sys.platform == "darwin"`` and ``tasklist``/``Win32::Process::Info`` on
  Windows.
* kill: ``os.kill`` signals become ``TerminateProcess`` on Windows (``signal
  .SIGTERM`` has no direct equivalent there).
* reap: the ``waitpid``/``/proc`` zombie sweep becomes a handle wait on
  Windows.
* environment: ``_perl_env`` builds a POSIX ``PERL5LIB``; the Windows backend
  joins with ``;`` and reads the Strawberry Perl local::lib layout.

Every function here is still the Linux implementation. The supervision
functions read the liveness helpers from ``core`` at call time so a test can
monkeypatch ``core.jawn_up`` exactly as before.
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


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _jawn_master_pids():
    """PIDs of a running jawn master, however it was invoked (scans /proc).

    The desktop starts it as `perl ./jawn`, but an autostart or a terminal can
    use the absolute path (`perl /home/.../jawn`). Matching only `./jawn` made
    the guard miss a master that was merely mid-restart and start a second tree
    (2026-10-21), so match the script's basename instead.
    """
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
    from . import core as _core

    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    _core.cap_log(log_path)
    logf = open(log_path, "ab", buffering=0)
    try:
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
    argv = [_perl(), "./jawn"]
    spawn_detached(argv, jawn_dir, jawn_stdout_log_path(), env=_perl_env())
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
    subprocess.run([_perl(), "scripts/manager_killer.pl", "master"], cwd=jawn_dir, env=_perl_env())
    deadline = time.time() + wait
    while time.time() < deadline:
        if not _core.jawn_up(jawn_dir) and not _jawn_master_pids():
            return True, "jawn stopped"
        time.sleep(0.3)
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
