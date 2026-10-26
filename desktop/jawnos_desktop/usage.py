"""``jawnos-usage`` -- the Sway app-focus watcher.

Sway is the compositor, so it -- not the manager page -- knows which window a
person is actually looking at. This process subscribes to Sway's IPC and turns
each focus span into a ``usage_sessions`` row with ``kind=app`` and
``source=sway``:

* on a focus change it closes the previous span and queues it,
* every :data:`FLUSH_SECONDS` it posts the queued spans (and rolls the open one
  so a crash cannot lose more than the last half-minute),
* on exit it closes the open span and posts it.

The manager credential is the one the desktop app already holds: the login
ticket in :mod:`jawnos_desktop.secrets` (keyring, else the encrypted file). The
ticket is loaded once to mint a ``president`` session cookie, and every request
then rides that cookie -- no new token is minted and no secret is embedded here.

The helpers at the top (``get_workspaces``, ``get_tree``, ``focused_container``,
...) are also used by the session bar, so both surfaces read Sway the same way.
"""

import argparse
import collections
import datetime
import http.cookiejar
import json
import logging
import os
import re
import shutil
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from . import DESKTOP_DIR, core, secrets

LOG = logging.getLogger("jawnos.usage")

KIND = "app"
SOURCE = "sway"
MIN_SPAN_MS = 1000
MAX_SPAN_MS = 12 * 60 * 60 * 1000
FLUSH_SECONDS = 30
MAX_PENDING = 1000

# Lock screens and private browsing windows are not app time: they are the
# person deliberately not being observed, so the watcher closes the span and
# records nothing while one is focused.
LOCK_APPS = frozenset({
    "swaylock", "swaylock-effects", "gtklock", "hyprlock", "i3lock",
    "xsecurelock", "swayidle", "swaybg",
})
PRIVATE_TITLE = re.compile(
    r"(?i)(private browsing|private window|incognito|inprivate|"
    r"lock screen|screen locked|^locked$)"
)


# --------------------------------------------------------------------------
# Sway IPC (swaymsg)
# --------------------------------------------------------------------------

def swaymsg_available():
    return shutil.which("swaymsg") is not None


def swaymsg(args, timeout=3.0):
    """Run one ``swaymsg`` query and return its JSON, or None.

    ``-t subscribe`` is not run through here: it streams until killed, so the
    watcher owns that process itself.
    """
    exe = shutil.which("swaymsg")
    if not exe:
        return None
    try:
        done = subprocess.run(
            [exe] + list(args), capture_output=True, timeout=timeout,
            env=_sway_env())
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    try:
        return json.loads(done.stdout.decode("utf-8", "replace"))
    except ValueError:
        return None


def _sway_env():
    env = dict(os.environ)
    # A session started by greetd/`sway --unsupported-gpu` may not have exported
    # SWAYSOCK to the exec'd children; swaymsg can usually find it beside the
    # Wayland socket, but pass an explicit one through when it is known.
    if not env.get("SWAYSOCK") and env.get("I3SOCK"):
        env["SWAYSOCK"] = env["I3SOCK"]
    return env


def get_workspaces():
    value = swaymsg(["-t", "get_workspaces"])
    return value if isinstance(value, list) else []


def get_tree():
    value = swaymsg(["-t", "get_tree"])
    return value if isinstance(value, dict) else {}


def walk_tree(node):
    """Yield a Sway tree node and every child (tiling and floating)."""
    if not isinstance(node, dict):
        return
    yield node
    for child in node.get("nodes") or []:
        yield from walk_tree(child)
    for child in node.get("floating_nodes") or []:
        yield from walk_tree(child)


def container_app_key(node):
    """The app identity of a Sway container: app_id, else the X11 class."""
    if not isinstance(node, dict):
        return ""
    app_id = (node.get("app_id") or "").strip()
    if app_id:
        return app_id
    props = node.get("window_properties") or {}
    if not isinstance(props, dict):
        return ""
    for name in ("class", "instance"):
        value = (props.get(name) or "").strip()
        if value:
            return value
    return ""


def focused_container(tree):
    """The focused leaf window in a ``get_tree`` answer, or None."""
    if not isinstance(tree, dict):
        return None
    for node in walk_tree(tree):
        if not node.get("focused"):
            continue
        if container_app_key(node):
            return node
    return None


def private_window(node):
    """True for a lock screen, a private browser window, or no app at all."""
    key = container_app_key(node).lower()
    if not key:
        return True
    if key in LOCK_APPS or key.startswith("swaylock"):
        return True
    title = (node.get("name") or "") if isinstance(node, dict) else ""
    return bool(PRIVATE_TITLE.search(title or ""))


def focused_key_from_tree(tree):
    """(key, ok): the focused app key, and whether Sway answered at all.

    ``ok`` is False when the tree query failed, so a transient IPC error never
    ends the session that is currently open.
    """
    if not isinstance(tree, dict) or not tree:
        return None, False
    node = focused_container(tree)
    if node is None:
        return "", True
    if private_window(node):
        return "", True
    return container_app_key(node), True


# --------------------------------------------------------------------------
# The manager credential (the desktop app's stored ticket)
# --------------------------------------------------------------------------

def ticket_url():
    """The login ticket this app already holds, if any.

    Same order as the embedded view: the encrypted store first, then the
    gitignored live token a checkout may keep in ``.shots/ticket.txt``.
    """
    try:
        stored = secrets.load()
        if stored:
            return stored
    except Exception:
        pass
    root = os.path.dirname(DESKTOP_DIR)
    path = os.path.join(root, ".shots", "ticket.txt")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def local_midnight_ms(now=None):
    """Epoch milliseconds for local midnight today."""
    stamp = datetime.datetime.fromtimestamp(now if now is not None else time.time())
    start = stamp.replace(hour=0, minute=0, second=0, microsecond=0)
    return int(start.timestamp() * 1000)


def now_ms():
    return int(time.time() * 1000)


class ManagerClient:
    """Minimal authenticated client for the manager's usage routes.

    The manager's app gate accepts the ticket session the desktop already
    stores. Loading the ticket mints the session cookie; the cookie jar then
    carries it on every later request. A self-signed certificate on the box's
    own manager is not verified -- this is the app's own HTTP client, which the
    contract allows (it never applies to a Browse view).
    """

    def __init__(self, jawn_dir=None, timeout=6.0, logger=None):
        self.jawn_dir = os.path.expanduser(jawn_dir or core.load_settings()["jawn_dir"])
        self.timeout = timeout
        self.log = logger or LOG
        self._lock = threading.Lock()
        self._jar = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._jar),
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
        )
        self._base = None
        self._last_attempt = 0.0
        self._noted = False

    # ---- login -----------------------------------------------------------

    def _candidate_tickets(self, ticket):
        if not ticket:
            return []
        urls = [ticket]
        try:
            parts = urllib.parse.urlsplit(ticket)
            host = parts.hostname or ""
            if host and host not in ("127.0.0.1", "localhost", "::1"):
                port = parts.port or core.DOCK_PORT
                urls.append(urllib.parse.urlunsplit(
                    parts._replace(netloc="127.0.0.1:%d" % port)))
        except ValueError:
            pass
        return urls

    def _login_locked(self):
        """Mint a session cookie from the stored ticket (or fall back to loopback)."""
        self._last_attempt = time.time()
        ticket = ticket_url()
        for url in self._candidate_tickets(ticket):
            try:
                request = urllib.request.Request(
                    url, headers={"X-Requested-With": "jawnos-usage"})
                with self._opener.open(request, timeout=self.timeout) as response:
                    response.read(200000)
            except Exception as exc:
                self.log.debug("ticket login failed at %s: %s",
                               secrets.mask(url), exc)
                continue
            if len(self._jar):
                parts = urllib.parse.urlsplit(url)
                host = parts.hostname or "127.0.0.1"
                self._base = "https://%s:%d" % (
                    host, core.jawn_working_port(self.jawn_dir))
                self.log.debug("manager session minted from the stored ticket")
                return True
        # No ticket, or none of its addresses answered. Loopback is still worth
        # a try: a live boot trusts it, and `app_access: off` does too.
        self._base = "https://127.0.0.1:%d" % core.jawn_working_port(self.jawn_dir)
        return False

    def _ensure_locked(self):
        if self._base is not None:
            return True
        # A failed login is retried after five minutes, not on every span.
        if self._last_attempt and time.time() - self._last_attempt < 300:
            self._base = "https://127.0.0.1:%d" % core.jawn_working_port(self.jawn_dir)
            return False
        return self._login_locked()

    def _forget_session(self):
        self._base = None
        self._last_attempt = time.time()

    # ---- requests --------------------------------------------------------

    def _request(self, path, data=None):
        with self._lock:
            self._ensure_locked()
            base = self._base or ("https://127.0.0.1:%d"
                                  % core.jawn_working_port(self.jawn_dir))
            url = base + path
            body = urllib.parse.urlencode(data).encode("utf-8") if data else None
            headers = {"X-Requested-With": "jawnos-usage"}
            if body is not None:
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            request = urllib.request.Request(url, data=body, headers=headers)
            try:
                with self._opener.open(request, timeout=self.timeout) as response:
                    return json.loads(response.read(65536).decode("utf-8", "replace"))
            except urllib.error.HTTPError as exc:
                self.log.debug("manager answered %s for %s", exc.code, path)
            except Exception as exc:
                self.log.debug("manager request %s failed: %s", path, exc)
            return None

    def post_session(self, record):
        """POST one finished span. Returns True when the manager accepted it."""
        answer = self._request("/manager/usage/session", record)
        if isinstance(answer, dict) and answer.get("ok"):
            self._noted = False
            return True
        # An HTML answer is the app gate or the login screen, not a JSON error:
        # the cookie has gone stale, so let the next flush try the ticket again
        # (after the retry delay, not in a hot loop).
        self._forget_session()
        if not self._noted:
            self._noted = True
            self.log.warning(
                "the manager did not accept the usage session; it is retried "
                "from the stored ticket (app access may be set to Enforce)")
        return False

    def summary_today(self):
        """Rows from /manager/usage/summary for today, or None."""
        now = now_ms()
        query = urllib.parse.urlencode({
            "kind": KIND,
            "from": local_midnight_ms(),
            "to": now,
        })
        answer = self._request("/manager/usage/summary?" + query)
        if not isinstance(answer, dict) or not isinstance(answer.get("rows"), list):
            return None
        return answer["rows"]

    def total_ms_today(self):
        """Today's app time in milliseconds, or None when the manager is silent."""
        rows = self.summary_today()
        if rows is None:
            return None
        total = 0
        for row in rows:
            try:
                total += max(0, int(row.get("total_ms") or 0))
            except (TypeError, ValueError):
                continue
        return total


def format_duration(ms):
    """A compact duration for the bar: 0m, 42m, 1h 05m, 2h."""
    try:
        ms = max(0, int(ms))
    except (TypeError, ValueError):
        return "0m"
    minutes = ms // 60000
    if minutes < 1:
        return "0m"
    hours, minutes = divmod(minutes, 60)
    if hours:
        return "%dh %02dm" % (hours, minutes) if minutes else "%dh" % hours
    return "%dm" % minutes


# --------------------------------------------------------------------------
# The watcher
# --------------------------------------------------------------------------

class FocusWatcher:
    """Turn Sway focus events into ``usage_sessions`` rows."""

    def __init__(self, client=None, flush_seconds=FLUSH_SECONDS, dry_run=False,
                 logger=None):
        self.client = client
        self.flush_seconds = max(5, int(flush_seconds or FLUSH_SECONDS))
        self.dry_run = dry_run
        self.log = logger or LOG
        self.stop = threading.Event()
        self._lock = threading.RLock()
        self._queue = collections.deque()
        self._current = None

    # ---- state ----

    def _emit_locked(self, key, start, end):
        start = int(start)
        end = int(end)
        if end <= start:
            return
        # The manager rejects a span over 12 h; slice a long sleep/suspend gap
        # instead of losing the whole span to the clamp.
        while end - start > MAX_SPAN_MS:
            self._queued_locked(key, start, start + MAX_SPAN_MS)
            start += MAX_SPAN_MS
        if end - start >= MIN_SPAN_MS:
            self._queued_locked(key, start, end)

    def _queued_locked(self, key, start, end):
        if len(self._queue) >= MAX_PENDING:
            self._queue.popleft()
            self.log.warning("usage queue full; dropped the oldest span")
        self._queue.append({
            "kind": KIND,
            "key": key,
            "started_at": start,
            "ended_at": end,
            "idle_ms": 0,
            "source": SOURCE,
        })

    def _set_focus(self, key):
        if key is None:
            return
        with self._lock:
            if self._current and self._current["key"] == key:
                return
            stamp = now_ms()
            self._close_locked(stamp)
            if key:
                self._current = {"key": key, "started_at": stamp}
                self.log.info("focus: %s", key)

    def _close_locked(self, stamp=None):
        if not self._current:
            return
        stamp = stamp if stamp is not None else now_ms()
        self._emit_locked(self._current["key"], self._current["started_at"], stamp)
        self._current = None

    def poll_state(self):
        """Re-read the focused window. A failed query leaves the span open."""
        key, ok = focused_key_from_tree(get_tree())
        if ok:
            self._set_focus(key)

    # ---- posting ----

    def flush(self, roll=False):
        """Post queued spans; with ``roll``, also close and restart the open one."""
        with self._lock:
            if roll and self._current:
                stamp = now_ms()
                self._emit_locked(self._current["key"],
                                  self._current["started_at"], stamp)
                self._current["started_at"] = stamp
        while True:
            with self._lock:
                if not self._queue:
                    break
                record = self._queue.popleft()
            if self._post(record):
                continue
            with self._lock:
                self._queue.appendleft(record)
            break

    def _post(self, record):
        if self.dry_run:
            print(json.dumps(record, sort_keys=True), flush=True)
            return True
        if self.client is None:
            return True
        return self.client.post_session(record)

    # ---- Sway events ----

    def _handle_event(self, line):
        try:
            event = json.loads(line)
        except ValueError:
            return
        if not isinstance(event, dict):
            return
        change = event.get("change") or ""
        if "container" in event and change == "focus":
            container = event.get("container")
            if private_window(container):
                self._set_focus("")
            else:
                self._set_focus(container_app_key(container))
            return
        if "current" in event:
            # workspace events: focus may have moved to an empty workspace
            self.poll_state()
            return
        if change in ("exit", "reload") and "container" not in event:
            self.log.info("Sway is shutting down; closing the session")
            self.stop.set()

    def _subscribe_loop(self):
        exe = shutil.which("swaymsg")
        while not self.stop.is_set():
            proc = None
            try:
                proc = subprocess.Popen(
                    [exe, "-t", "subscribe", '["window","workspace","shutdown"]'],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    text=True, bufsize=1, env=_sway_env(),
                )
                for line in proc.stdout:
                    if self.stop.is_set():
                        break
                    line = line.strip()
                    if line:
                        self._handle_event(line)
            except OSError as exc:
                self.log.warning("could not subscribe to Sway: %s", exc)
            finally:
                if proc is not None:
                    try:
                        proc.terminate()
                        proc.wait(timeout=2)
                    except Exception:
                        try:
                            proc.kill()
                        except OSError:
                            pass
            if not self.stop.is_set():
                self.stop.wait(5)

    # ---- main ----

    def run(self):
        if not swaymsg_available():
            self.log.error("swaymsg was not found; app time is recorded only "
                           "inside a Sway session")
            return 1
        self.log.info("watching Sway focus (kind=%s, source=%s, flush=%ds)",
                      KIND, SOURCE, self.flush_seconds)
        self.poll_state()
        subscriber = threading.Thread(
            target=self._subscribe_loop, name="sway-subscribe", daemon=True)
        subscriber.start()
        last_flush = time.monotonic()
        last_poll = time.monotonic()
        try:
            while not self.stop.wait(0.5):
                stamp = time.monotonic()
                if stamp - last_flush >= self.flush_seconds:
                    self.flush(roll=True)
                    last_flush = stamp
                if stamp - last_poll >= 5.0:
                    self.poll_state()
                    last_poll = stamp
        finally:
            with self._lock:
                self._close_locked()
            self.flush()
        return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _single_instance():
    """Hold a lock beside the state so two watchers cannot double-count."""
    try:
        import fcntl
    except ImportError:
        return None
    os.makedirs(core.state_dir(), exist_ok=True)
    path = os.path.join(core.state_dir(), "jawnos-usage.lock")
    handle = open(path, "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    handle.write(str(os.getpid()))
    handle.flush()
    return handle


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="jawnos-usage",
        description="Record the focused Sway app as JawnOS usage sessions.")
    parser.add_argument("--jawn-dir", default=None,
                        help="the jawn tree (default: the desktop setting, "
                             "or $JAWNOS_DIR)")
    parser.add_argument("--flush-seconds", type=int, default=FLUSH_SECONDS,
                        help="how often a span is persisted (default: 30)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print finished spans as JSON lines; post nothing")
    parser.add_argument("--verbose", action="store_true",
                        help="log debug detail (session minting, IPC errors)")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s jawnos-usage %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    settings = core.load_settings()
    jawn_dir = os.path.expanduser(args.jawn_dir or settings["jawn_dir"])

    lock = None
    if not args.dry_run:
        lock = _single_instance()
        if lock is None:
            LOG.info("another jawnos-usage is already watching; nothing to do")
            return 0

    client = None if args.dry_run else ManagerClient(jawn_dir)
    watcher = FocusWatcher(client, flush_seconds=args.flush_seconds,
                           dry_run=args.dry_run)

    def _stop(signum=None, frame=None):
        watcher.stop.set()

    try:
        import signal
        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGINT, _stop)
    except (ImportError, ValueError):
        pass

    try:
        return watcher.run()
    finally:
        if lock is not None:
            try:
                lock.close()
            except OSError:
                pass
