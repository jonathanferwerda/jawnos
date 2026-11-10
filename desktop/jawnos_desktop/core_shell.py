"""Opening the manager, a console, and the browser.

Linux (today) uses ``webbrowser.open`` and a fixed X11/Wayland terminal list,
and asks the stored ticket for the host to open. The platform branch points the
macOS and Windows lanes fill in P2/P3 are:

* ``sys.platform == "darwin"``: ``open`` and ``osascript`` for URLs and
  Terminal.app instead of ``webbrowser``/the X11 terminal list.
* ``os.name == "nt"``: ``ShellExecute``/``start`` and Windows Terminal or
  conhost instead of ``webbrowser``/the X11 terminal list.

``open_ui`` still reads the stored ticket and the jawn tree's working port;
only the browser and terminal launch is platform-shaped.
"""

import os
import shutil
import webbrowser

from . import DESKTOP_DIR
from .core_paths import jawn_stdout_log_path
from .core_process import _perl, _perl_env, spawn_detached
from .core_secrets import load, manager_host


def desktop_launcher():
    """The installed jawnos-desktop launcher, if there is one to run."""
    for candidate in (os.path.join(DESKTOP_DIR, "jawnos-desktop"),
                      shutil.which("jawnos-desktop")):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return None


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
    if prefer_app and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        launcher = desktop_launcher()
        if launcher:
            try:
                spawn_detached([launcher], jawn_dir, jawn_stdout_log_path(), env=_perl_env())
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
