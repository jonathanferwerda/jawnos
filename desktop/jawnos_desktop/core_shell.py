"""Opening the manager, a console, and the browser.

``open_ui`` reads the stored ticket and the jawn tree's working port; only the
app, browser and terminal launch is platform-shaped. Linux uses
``webbrowser.open`` and a fixed X11/Wayland terminal list. Windows launches the
packaged shell with its own ``pythonw.exe`` and opens a console with
``CREATE_NEW_CONSOLE``; none of it assumes a POSIX executable bit.
"""

import os
import shutil
import subprocess
import sys
import webbrowser

from . import DESKTOP_DIR
from .core_paths import jawn_stdout_log_path
from .core_process import _perl, _perl_env, spawn_detached
from .core_secrets import load, manager_host

IS_WINDOWS = os.name == "nt"


def desktop_argv():
    """The command that starts the app, or ``None``.

    The installed POSIX script is executable and runs directly. On Windows it
    is a Python source file with no execution association, so the bundle's
    ``pythonw.exe`` (no console window) runs it explicitly.
    """
    script = os.path.join(DESKTOP_DIR, "jawnos-desktop")
    if os.path.isfile(script):
        if not IS_WINDOWS and os.access(script, os.X_OK):
            return [script]
        python = sys.executable or "python.exe"
        if IS_WINDOWS:
            windowless = os.path.join(os.path.dirname(python), "pythonw.exe")
            if os.path.isfile(windowless):
                python = windowless
        return [python, script]
    found = shutil.which("jawnos-desktop")
    if found:
        if IS_WINDOWS:
            return [sys.executable or "python.exe", found]
        return [found]
    return None


def desktop_launcher():
    """The installed jawnos-desktop launcher, if there is one to run."""
    argv = desktop_argv()
    return argv[0] if argv else None


def open_ui(jawn_dir, prefer_app=False):
    """Open the manager: the desktop app when asked and available, else a browser.

    With app access on Enforce a plain browser is answered with the
    open-in-the-app page, because it has no key. The CLI therefore starts the
    installed app (which holds one) when it can, and only falls back to the
    browser on a headless box or when the app is not installed.

    The browser path prefers the stored ticket: it is addressed on the
    machine's own domain and mints the session cookie on the way, so the
    browser lands on the manager instead of the gate on a host it has not
    logged in to. Fall back to the manager on the ticket's host, then loopback."""
    if prefer_app and (IS_WINDOWS or os.environ.get("DISPLAY")
                       or os.environ.get("WAYLAND_DISPLAY")):
        argv = desktop_argv()
        if argv:
            try:
                spawn_detached(argv, jawn_dir, jawn_stdout_log_path(),
                               env=_perl_env(jawn_dir))
                return True
            except OSError:
                pass
    try:
        ticket = load()
        if ticket:
            return webbrowser.open(ticket)
    except Exception:
        pass
    from . import core as _core
    port = _core.jawn_working_port(jawn_dir)
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
    if IS_WINDOWS:
        comspec = os.environ.get("COMSPEC") or "cmd.exe"
        argv = [comspec, "/k", _perl(jawn_dir), "jawn"]
        try:
            subprocess.Popen(
                argv, cwd=jawn_dir, env=_perl_env(jawn_dir),
                creationflags=0x00000010,  # CREATE_NEW_CONSOLE
            )
            return True, "opened a console"
        except OSError as exc:
            return False, str(exc)
    for name, extra in _TERMINALS:
        binary = shutil.which(name)
        if not binary:
            continue
        argv = [binary] + extra + [_perl(jawn_dir), "./jawn"]
        try:
            spawn_detached(argv, jawn_dir, jawn_stdout_log_path(),
                           env=_perl_env(jawn_dir))
            return True, "opened %s" % name
        except OSError:
            continue
    return False, "no terminal emulator found"
