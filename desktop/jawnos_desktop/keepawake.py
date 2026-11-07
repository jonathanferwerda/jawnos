"""Inhibit the desktop's idle screen-saver while media is playing.

This is the GTK-free implementation used by the Qt shell: it starts a
``systemd-inhibit --what=idle`` process holding logind's idle block, which
every major desktop's power manager honours, and terminates it when the media
stops. If ``systemd-inhibit`` is not installed the class quietly no-ops, so a
bare session never breaks the app.

The old implementation talked to the screensaver, the power manager and logind
through Gio/GLib. Those extra interfaces were only reachable with PyGObject,
which the Qt shell should not need; logind is the portable interface and is the
one the old code called last.
"""

import shutil
import subprocess


class ScreensaverInhibitor:
    """Holds one idle inhibitor; inhibit/uninhibit are idempotent."""

    def __init__(self, app="JawnOS"):
        self.app = app
        self._proc = None

    def inhibit(self, reason="media playing"):
        if self._proc is not None and self._proc.poll() is None:
            return
        inhibitor = shutil.which("systemd-inhibit")
        if not inhibitor:
            return
        try:
            self._proc = subprocess.Popen(
                [inhibitor, "--what=idle", "--who=%s" % self.app,
                 "--why=%s" % reason, "--mode=block", "sleep", "infinity"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            self._proc = None

    def uninhibit(self):
        proc, self._proc = self._proc, None
        if proc is None:
            return
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass

    def __del__(self):
        self.uninhibit()
