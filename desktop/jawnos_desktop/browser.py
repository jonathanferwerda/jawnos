"""``jawnos-browse`` -- the JawnOS Internet app's native browser window.

The Internet app has two halves. **Web** is the manager's saved-page and
measure pipeline. **Browse** is a real browser, and a live page cannot run
inside the manager's own WebView: it would share the manager's cookie jar and
its script bridge. So Browse is a sibling process with a WebKitGTK view of its
own, a data store of its own, and no bridge back into the manager.

What this window does:

* tabs (a ``Gtk.Notebook`` with a close button per tab), an address bar,
  back/forward/reload/stop, find-in-page, downloads, error pages and external
  protocol delegation;
* its own persistent :class:`WebKit2.WebsiteDataManager` under
  ``~/.local/share/jawnos/browser`` -- never the manager view's store;
* a local JSONL history;
* site-time accounting: the focused tab's registrable domain is queued as a
  ``usage_sessions`` row (``kind=site``, ``source=browser``) while this window
  is active. Spans are posted through the desktop app's stored ticket by
  :class:`jawnos_desktop.usage.ManagerClient`, which this module subclasses
  without changing;
* ``--mode measure``: a message-only element picker that posts the clicked
  element's document to ``/manager/web/measure/live`` and shows the returned
  candidates in a GTK dialog. The returned confirmation HTML is never loaded
  or evaluated.

Safety rules (see ``docs/internet-contract.md``):

* the browse view carries no ``JawnBrowse`` bridge -- only the picker handler,
  and only in measure mode;
* TLS errors are never ignored for external sites;
* navigation to loopback, link-local and other private addresses is refused
  unless ``JAWNOS_BROWSE_ALLOW_PRIVATE=1``.
"""

import argparse
import collections
import html as html_lib
import ipaddress
import json
import logging
import os
import sys
import threading
import urllib.parse

from . import core, usage

LOG = logging.getLogger("jawnos.browser")

KIND = "site"
SOURCE = "browser"
FLUSH_SECONDS = 30
MIN_SPAN_MS = 1000
MAX_SPAN_MS = 12 * 60 * 60 * 1000
MAX_PENDING = 1000

# The live document is capped at 1.5 MB before it leaves the page. The manager
# caps it at 2 MB again; this keeps a huge page from being copied twice.
MAX_MEASURE_HTML = 1572864

# External schemes this browser is willing to hand to the desktop. A page may
# link to anything; only these well-known handlers are delegated, so a
# ``file:`` or ``javascript:`` link can never reach an external program.
EXTERNAL_SCHEMES = frozenset({
    "mailto", "tel", "sms", "geo", "magnet", "bitcoin", "webcal",
    "irc", "ircs", "xmpp", "spotify", "steam",
})

# Registrable domains need a public-suffix list; the full PSL is not a Python
# dependency here, so this covers the common multi-label suffixes. A host whose
# suffix is missing falls back to its last two labels (the usual answer).
MULTI_LABEL_SUFFIXES = frozenset("""
ac.uk co.uk gov.uk ltd.uk me.uk net.uk nhs.uk org.uk plc.uk police.uk sch.uk
com.au net.au org.au edu.au gov.au id.au asn.au
co.nz net.nz org.nz govt.nz ac.nz geek.nz gen.nz kiwi.nz maori.nz school.nz
co.jp ne.jp or.jp ac.jp ad.jp ed.jp go.jp gr.jp lg.jp
com.br net.br org.br gov.br edu.br mil.br
com.cn net.cn org.cn gov.cn edu.cn ac.cn
com.hk net.hk org.hk gov.hk edu.hk idv.hk
com.tw net.tw org.tw gov.tw edu.tw idv.tw
com.sg net.sg org.sg gov.sg edu.sg per.sg
com.my net.my org.my gov.my edu.my
co.in net.in org.in firm.in gen.in ind.in gov.in ac.in edu.in res.in
co.id net.id org.id web.id ac.id sch.id go.id mil.id
co.kr ne.kr or.kr re.kr pe.kr go.kr mil.kr ac.kr
com.mx net.mx org.mx edu.mx gob.mx
com.ar net.ar org.ar gob.ar edu.ar
com.co net.co org.co edu.co gov.co
com.pe net.pe org.pe edu.pe gob.pe
com.ve net.ve org.ve edu.ve gov.ve
com.ec net.ec org.ec edu.ec gob.ec
com.uy net.uy org.uy edu.uy gub.uy
com.py net.py org.py edu.py gov.py
com.bo net.bo org.bo edu.bo gov.bo
com.do net.do org.do edu.do gov.do
com.gt net.gt org.gt edu.gt gob.gt
com.sv net.sv org.sv edu.sv gob.sv
com.ni net.ni org.ni edu.ni gob.ni
com.pa net.pa org.pa edu.pa gob.pa
com.ht net.ht org.ht edu.ht gob.ht
com.eg net.eg org.eg edu.eg gov.eg
com.sa net.sa org.sa edu.sa gov.sa
com.tr net.tr org.tr edu.tr gov.tr av.tr bbs.tr bel.tr biz.tr gen.tr
com.ua net.ua org.ua edu.ua gov.ua in.ua
com.ru net.ru org.ru pp.ru
com.pl net.pl org.pl biz.pl info.pl waw.pl
co.za net.za org.za gov.za ac.za edu.za web.za
co.ke net.ke org.ke go.ke ac.ke sc.ke
co.tz net.tz org.tz go.tz ac.tz sc.tz
co.ug net.ug org.ug go.ug ac.ug sc.ug
co.zw net.zw org.zw gov.zw ac.zw
co.ma net.ma org.ma gov.ma ac.ma press.ma
co.il net.il org.il gov.il ac.il edu.il muni.il
co.th net.th org.th gov.th ac.th in.th
co.uz net.uz org.uz
co.mz net.mz org.mz gov.mz ac.mz edu.mz
co.ao net.ao org.ao gov.ao ed.ao
co.bw net.bw org.bw gov.bw ac.bw
co.vi net.vi org.vi gov.vi ac.vi
com.ng net.ng org.ng gov.ng edu.ng
com.gh net.gh org.gh gov.gh edu.gh
com.pk net.pk org.pk gov.pk edu.pk
com.bd net.bd org.bd gov.bd edu.bd
com.np net.np org.np gov.np edu.np
com.lk net.lk org.lk gov.lk edu.lk
com.mm net.mm org.mm gov.mm edu.mm
com.kh net.kh org.kh gov.kh edu.kh
com.la net.la org.la edu.la gov.la
com.mo net.mo org.mo gov.mo edu.mo
com.ph net.ph org.ph gov.ph edu.ph
com.vn net.vn org.vn gov.vn edu.vn
com.af net.af org.af gov.af edu.af
com.ag net.ag org.ag edu.ag gov.ag
com.bz net.bz org.bz edu.bz gov.bz
com.cu net.cu org.cu edu.cu gov.cu
com.cy net.cy org.cy ac.cy gov.cy
com.dm net.dm org.dm edu.dm gov.dm
com.fj net.fj org.fj ac.fj gov.fj
com.gd net.gd org.gd edu.gd gov.gd
com.gy net.gy org.gy edu.gy gov.gy
com.jm net.jm org.jm edu.jm gov.jm
com.kn net.kn org.kn edu.kn gov.kn
com.lc net.lc org.lc edu.lc gov.lc
com.mt net.mt org.mt edu.mt gov.mt
com.pr net.pr org.pr edu.pr gov.pr
com.tt net.tt org.tt co.tt edu.tt gov.tt
com.vc net.vc org.vc edu.vc gov.vc
""".split())

# --------------------------------------------------------------------------
# GTK / WebKit, loaded without making ``--help`` depend on a display
# --------------------------------------------------------------------------

# The manager view applies the same renderer switches (webkit.env plus the
# Skylake/X11 fallback) before it imports WebKit. Importing it touches no
# WebView context, and it is the one place those switches are maintained. A
# machine without WebKit still gets a clean argparse error instead of a stack
# trace, because the import is guarded.
try:  # pragma: no cover - the import result depends on the installed typelibs
    from . import webview as _manager_view  # noqa: F401
except Exception:  # pragma: no cover
    _manager_view = None


def _load_gtk():
    try:
        import gi
        gi.require_version("Gtk", "3.0")
        gi.require_version("Gdk", "3.0")
        gi.require_version("Pango", "1.0")
        gi.require_version("WebKit2", "4.1")
        from gi.repository import Gdk, Gio, GLib, Gtk, Pango, WebKit2
        return (Gdk, Gio, GLib, Gtk, Pango, WebKit2), None
    except Exception as exc:  # pragma: no cover
        return None, exc


_GTK, _GTK_ERROR = _load_gtk()
if _GTK is not None:
    Gdk, Gio, GLib, Gtk, Pango, WebKit2 = _GTK
    _WindowBase = Gtk.Window
    _BoxBase = Gtk.Box
    _VBox = Gtk.Orientation.VERTICAL
    _HBox = Gtk.Orientation.HORIZONTAL
else:  # pragma: no cover - only when WebKitGTK is not installed
    Gdk = Gio = GLib = Gtk = Pango = WebKit2 = None
    _WindowBase = object
    _BoxBase = object
    _VBox = _HBox = None


# --------------------------------------------------------------------------
# Small pure helpers (importable without GTK)
# --------------------------------------------------------------------------

def browser_data_dir():
    """The browse window's own data store, separate from the manager's."""
    base = os.environ.get("XDG_DATA_HOME")
    if not base:
        base = os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "jawnos", "browser")


def allow_private():
    """Whether private-network navigation was explicitly allowed."""
    value = (os.environ.get("JAWNOS_BROWSE_ALLOW_PRIVATE") or "").strip().lower()
    return value in ("1", "true", "yes", "on")


def blocked_host(uri):
    """True for loopback, link-local, or another private-network address.

    Hostnames are checked literally; resolving every name would block the UI
    and leak DNS, so this is the contract's named set (127/8, ::1, localhost,
    169.254/16) plus the RFC 1918 and IPv6 equivalents. A public name that
    resolves to a private address (DNS rebinding) is outside this check.
    """
    try:
        host = urllib.parse.urlsplit(uri or "").hostname or ""
    except ValueError:
        return True
    host = host.strip().strip("[]").rstrip(".").lower()
    if not host:
        return False
    if host in ("localhost", "localhost.localdomain"):
        return True
    if host.endswith(".localhost"):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    mapped = getattr(address, "ipv4_mapped", None)
    if mapped is not None:
        address = mapped
    return bool(
        address.is_loopback
        or address.is_link_local
        or address.is_private
        or address.is_reserved
        or address.is_multicast
        or address.is_unspecified
    )


def registrable_domain(uri):
    """The site key for usage: eTLD+1, or an IP literal as itself."""
    try:
        host = urllib.parse.urlsplit(uri or "").hostname or ""
    except ValueError:
        return ""
    host = host.strip().strip("[]").rstrip(".").lower()
    if not host:
        return ""
    try:
        return str(ipaddress.ip_address(host))
    except ValueError:
        pass
    labels = host.split(".")
    if len(labels) <= 2:
        return host
    if ".".join(labels[-2:]) in MULTI_LABEL_SUFFIXES:
        return ".".join(labels[-3:])
    return ".".join(labels[-2:])


def normalise_url(text):
    """An address from the URL bar, or None when it is not http(s).

    A bare host (``example.com``, ``example.com:8080``) becomes https. A phrase
    or a non-http scheme is refused; there is no search engine to send it to.
    """
    text = (text or "").strip()
    if not text:
        return None
    if "://" in text:
        try:
            parts = urllib.parse.urlsplit(text)
        except ValueError:
            return None
        if parts.scheme.lower() in ("http", "https") and parts.netloc:
            return text
        return None
    if any(ch.isspace() for ch in text):
        return None
    host = text.split("/", 1)[0]
    bare = host
    if bare.startswith("["):
        bare = bare.split("]", 1)[0] + "]"
    elif ":" in bare:
        bare = bare.rsplit(":", 1)[0]
    bare = bare.strip("[]")
    if "." not in bare and bare.lower() not in ("localhost",):
        try:
            ipaddress.ip_address(bare)
        except ValueError:
            return None
    return "https://" + text


def manager_base(url):
    """``https://host:port`` from a manager URL, or None."""
    try:
        parts = urllib.parse.urlsplit(url or "")
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.netloc:
        return None
    return "%s://%s" % (parts.scheme, parts.netloc)


def _js_text(result):
    """The text a WebKit script-message handler received."""
    for getter in ("get_js_value", "get_value"):
        try:
            return getattr(result, getter)().to_string()
        except Exception:
            continue
    try:
        return result.to_string()
    except Exception:
        return ""


# --------------------------------------------------------------------------
# The manager client
# --------------------------------------------------------------------------

class BrowseClient(usage.ManagerClient):
    """The existing manager client, with a public form poster.

    ``ManagerClient`` posts usage spans and keeps the stored ticket's session
    cookie. The measure routes need the same authenticated POST for arbitrary
    paths; ``post_form`` is that public wrapper. ``--manager`` is used only as
    a fallback base when no ticket could mint a session (a ticket-derived base
    carries the cookie, which a different host would not).
    """

    def __init__(self, manager=None, logger=None):
        super().__init__(logger=logger)
        self.manager_base = manager_base(manager)

    def post_form(self, path, data=None):
        return self._request(path, data)

    def _login_locked(self):
        minted = super()._login_locked()
        if not minted and self.manager_base:
            self._base = self.manager_base
        return minted


# --------------------------------------------------------------------------
# Site-time accounting
# --------------------------------------------------------------------------

class SiteUsage:
    """Turn the focused tab's site into queued ``kind=site`` spans.

    The accounting rule is the contract's: count the focused tab's registrable
    domain while this window is foreground. Background tabs, a blurred window
    and internal error pages contribute nothing. Spans are queued and posted
    every :data:`FLUSH_SECONDS` (and on close), like the Sway watcher, so a
    crash cannot lose more than the last half-minute.
    """

    def __init__(self, client, logger=None):
        self.client = client
        self.log = logger or LOG
        self._lock = threading.RLock()
        self._queue = collections.deque()
        self._current = None
        self._stopped = False

    # ---- state -----------------------------------------------------------

    def visit(self, key, url, title):
        """The focused tab now shows ``key``/``url``; close any other span."""
        with self._lock:
            if self._stopped:
                return
            if not key:
                self._close_locked()
                return
            if self._current and self._current["key"] == key \
                    and self._current["url"] == url:
                self._current["title"] = title or self._current.get("title") or ""
                return
            self._close_locked()
            self._current = {
                "key": key,
                "url": url or "",
                "title": title or "",
                "started_at": usage.now_ms(),
            }

    def idle(self):
        """Nothing is being viewed: close the open span."""
        with self._lock:
            self._close_locked()

    def _close_locked(self, stamp=None):
        if not self._current:
            return
        stamp = usage.now_ms() if stamp is None else int(stamp)
        start = int(self._current["started_at"])
        if stamp > start:
            self._emit_locked(self._current, start, stamp)
        self._current = None

    def _emit_locked(self, current, start, end):
        # The manager rejects a span over 12 h; slice a suspend gap instead of
        # losing the whole span to its clamp.
        while end - start > MAX_SPAN_MS:
            self._queued_locked(current, start, start + MAX_SPAN_MS)
            start += MAX_SPAN_MS
        if end - start >= MIN_SPAN_MS:
            self._queued_locked(current, start, end)

    def _queued_locked(self, current, start, end):
        if len(self._queue) >= MAX_PENDING:
            self._queue.popleft()
            self.log.warning("usage queue full; dropped the oldest span")
        self._queue.append({
            "kind": KIND,
            "key": current["key"],
            "started_at": int(start),
            "ended_at": int(end),
            "idle_ms": 0,
            "source": SOURCE,
            "url": current.get("url") or "",
            "title": current.get("title") or "",
        })

    # ---- posting ---------------------------------------------------------

    def flush(self, roll=False):
        """Post queued spans; with ``roll``, also close and restart the open one."""
        with self._lock:
            if roll and self._current:
                stamp = usage.now_ms()
                self._emit_locked(self._current, int(self._current["started_at"]), stamp)
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
        if self.client is None:
            return True
        return self.client.post_session(record)

    def shutdown(self):
        """Close the open span and try to post everything before exit."""
        with self._lock:
            if self._stopped:
                return
            self._stopped = True
            self._close_locked()
        # A dead manager must not hold the window open. The queue is small, so
        # a short join is enough; unsent spans are lost after it (no disk
        # spool in this slice).
        worker = threading.Thread(target=self.flush, name="browse-flush",
                                  daemon=True)
        worker.start()
        worker.join(2.5)


# --------------------------------------------------------------------------
# Local history
# --------------------------------------------------------------------------

class History:
    """A local JSONL history: url, title, visited_at (epoch ms)."""

    def __init__(self, path, limit=5000):
        self.path = path
        self.limit = max(100, int(limit or 5000))
        self.entries = []
        self._load()

    def _load(self):
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(entry, dict):
                        continue
                    url = entry.get("url")
                    if not isinstance(url, str) or not url:
                        continue
                    try:
                        visited = int(entry.get("visited_at") or 0)
                    except (TypeError, ValueError):
                        visited = 0
                    self.entries.append({
                        "url": url,
                        "title": str(entry.get("title") or ""),
                        "visited_at": visited,
                    })
        except OSError:
            pass
        if len(self.entries) > self.limit:
            self.entries = self.entries[-self.limit:]

    def add(self, url, title):
        if not url:
            return
        now = usage.now_ms()
        if self.entries:
            last = self.entries[-1]
            if last.get("url") == url and now - int(last.get("visited_at") or 0) < 5000:
                if title:
                    last["title"] = title
                return
        entry = {"url": url, "title": title or "", "visited_at": now}
        self.entries.append(entry)
        if len(self.entries) > self.limit:
            self.entries = self.entries[-self.limit:]
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
        except OSError as exc:
            LOG.debug("could not append history: %s", exc)

    def recent(self, limit=200):
        return list(reversed(self.entries[-max(1, int(limit)):]))


# --------------------------------------------------------------------------
# Pages the browser draws itself
# --------------------------------------------------------------------------

def _new_tab_html():
    return """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>New tab</title>
<style>
 html,body{height:100%;margin:0;background:#0a0a0a;color:#ededed;
           font-family:system-ui,sans-serif;}
 .wrap{height:100%;display:flex;flex-direction:column;align-items:center;
       justify-content:center;gap:10px;}
 h1{margin:0;font-size:34px;color:#ffcc00;}
 p{margin:0;opacity:.65;font-size:15px;}
</style></head>
<body><div class="wrap"><h1>JawnOS Browse</h1>
<p>Type an address above to begin.</p></div></body></html>"""


def _error_html(uri, message):
    safe_uri = html_lib.escape(uri or "")
    safe_message = html_lib.escape(message or "")
    retry = ""
    try:
        scheme = urllib.parse.urlsplit(uri or "").scheme.lower()
    except ValueError:
        scheme = ""
    if safe_uri and scheme in ("http", "https"):
        retry = '<p><a href="%s">Try again</a></p>' % safe_uri
    return """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Can't open this page</title>
<style>
 html,body{height:100%;margin:0;background:#111;color:#ededed;
           font-family:system-ui,sans-serif;}
 .wrap{max-width:720px;margin:0 auto;padding:10vh 24px;}
 h1{font-size:26px;margin:0 0 12px;color:#ffcc00;}
 p{line-height:1.5;margin:0 0 12px;}
 .u{opacity:.6;word-break:break-all;font-family:monospace;font-size:13px;}
 a{color:#ffcc00;}
</style></head>
<body><div class="wrap"><h1>Can't open this page</h1>
<p>%s</p><p class="u">%s</p>%s</div></body></html>""" % (
        safe_message, safe_uri, retry)


# --------------------------------------------------------------------------
# The element picker (measure mode only)
# --------------------------------------------------------------------------

_PICKER_JS = r"""
(function () {
    if (window.__jawnosPicker) { return; }
    var MAX_HTML = 1572864;
    var armed = false;
    var hovered = null;
    var saved = null;
    var savedCursor = null;

    function post(payload) {
        try {
            window.webkit.messageHandlers.jawnos_measure.postMessage(
                JSON.stringify(payload));
            return true;
        } catch (e) {
            return false;
        }
    }

    function cssEscape(value) {
        if (window.CSS && CSS.escape) { return CSS.escape(value); }
        return String(value).replace(/([^a-zA-Z0-9_-])/g, '\\$1');
    }

    function selectorFor(el) {
        if (!el || el.nodeType !== 1) { return ''; }
        if (el.id) {
            var byId = '#' + cssEscape(el.id);
            try {
                if (document.querySelectorAll(byId).length === 1) {
                    return byId;
                }
            } catch (e) {}
        }
        var parts = [];
        var node = el;
        while (node && node.nodeType === 1 &&
               node !== document.documentElement) {
            var tag = node.tagName.toLowerCase();
            var nth = 1;
            var sib = node;
            while (sib && sib.previousElementSibling) {
                sib = sib.previousElementSibling;
                if (sib.tagName === node.tagName) { nth++; }
            }
            parts.unshift(tag + ':nth-of-type(' + nth + ')');
            node = node.parentNode;
        }
        parts.unshift('html');
        return parts.join(' > ');
    }

    function indexOf(selector, el) {
        try {
            var all = document.querySelectorAll(selector);
            for (var i = 0; i < all.length; i++) {
                if (all[i] === el) { return i; }
            }
        } catch (e) {}
        return 0;
    }

    function restore() {
        if (hovered && saved) {
            hovered.style.outline = saved.outline;
            hovered.style.outlineOffset = saved.offset;
        }
        hovered = null;
        saved = null;
    }

    function highlight(el) {
        if (hovered === el) { return; }
        restore();
        hovered = el;
        if (!el || !el.style) { return; }
        saved = { outline: el.style.outline, offset: el.style.outlineOffset };
        el.style.outline = '2px solid #ffcc00';
        el.style.outlineOffset = '1px';
    }

    function onMove(ev) {
        if (!armed) { return; }
        highlight(ev.target);
    }

    function onClick(ev) {
        if (!armed || (ev.button !== undefined && ev.button !== 0)) { return; }
        var el = ev.target;
        if (!el || el.nodeType !== 1) { return; }
        ev.preventDefault();
        ev.stopPropagation();
        if (ev.stopImmediatePropagation) { ev.stopImmediatePropagation(); }

        var selector = selectorFor(el);
        var index = indexOf(selector, el);
        var doc = document.documentElement.outerHTML || '';
        if (doc.length > MAX_HTML) { doc = doc.slice(0, MAX_HTML); }

        armed = false;
        restore();
        setCursor(false);
        var sent = post({
            action: 'pick',
            selector: selector,
            index: index,
            html: doc,
            url: location.href,
            title: document.title || ''
        });
        // A missing handler is not a reason to leave the page unpickable.
        if (!sent) { arm(true); }
    }

    function onKey(ev) {
        if (armed && ev.key === 'Escape') {
            ev.preventDefault();
            ev.stopPropagation();
            arm(false);
        }
    }

    function setCursor(on) {
        if (!document.documentElement) { return; }
        if (on) {
            if (savedCursor === null) {
                savedCursor = document.documentElement.style.cursor || '';
            }
            document.documentElement.style.cursor = 'crosshair';
        } else if (savedCursor !== null) {
            document.documentElement.style.cursor = savedCursor;
            savedCursor = null;
        }
    }

    function arm(on) {
        armed = !!on;
        if (!armed) { restore(); }
        setCursor(armed);
    }

    window.__jawnosPicker = {
        arm: arm,
        armed: function () { return armed; }
    };
    document.addEventListener('mouseover', onMove, true);
    document.addEventListener('click', onClick, true);
    document.addEventListener('keydown', onKey, true);
    if (window.__jawnosMeasureAuto && /^https?:/i.test(location.href)) {
        arm(true);
    }
})();
"""


# --------------------------------------------------------------------------
# Widgets
# --------------------------------------------------------------------------

class BrowserTab(_BoxBase):
    """One browser tab: a WebView and its notebook label."""

    def __init__(self, window):
        super().__init__(orientation=_VBox)
        self.window = window
        self.internal = False
        self.error_page = False
        self.view = WebKit2.WebView(
            web_context=window.context,
            user_content_manager=window.content_manager,
        )
        self._configure()
        self.pack_start(self.view, True, True, 0)

        self.title_label = Gtk.Label(label="New tab")
        self.title_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.title_label.set_max_width_chars(30)
        self.title_label.set_xalign(0)
        close = Gtk.Button.new_from_icon_name(
            "window-close-symbolic", Gtk.IconSize.MENU)
        close.set_relief(Gtk.ReliefStyle.NONE)
        close.set_focus_on_click(False)
        close.set_tooltip_text("Close tab")
        close.connect("clicked", lambda *_: window.close_tab(self))
        label = Gtk.Box(orientation=_HBox, spacing=6)
        label.pack_start(self.title_label, True, True, 0)
        label.pack_start(close, False, False, 0)
        label.show_all()
        self.tab_label = label
        self.show_all()

    def _configure(self):
        view = self.view
        settings = view.get_settings()
        for prop, value in (
            ("enable-smooth-scrolling", True),
            ("enable-accelerated-2d-canvas", True),
            ("enable-html5-local-storage", True),
            ("enable-media", True),
            ("enable-mediasource", True),
            ("enable-webaudio", True),
            # A page cannot open windows without a user gesture. A real click
            # still reaches the notebook's ``create`` handler as a new tab.
            ("javascript-can-open-windows-automatically", False),
        ):
            try:
                settings.set_property(prop, value)
            except Exception:
                pass
        view.connect("load-changed", self.window.on_load_changed, self)
        view.connect("load-failed", self.window.on_load_failed, self)
        view.connect("load-failed-with-tls-errors", self.window.on_tls_error, self)
        view.connect("decide-policy", self.window.on_decide_policy, self)
        view.connect("create", self.window.on_create, self)
        view.connect("notify::uri", self.window.on_uri_changed, self)
        view.connect("notify::title", self.window.on_title_changed, self)
        view.connect("permission-request", self.window.on_permission, self)
        view.connect("enter-fullscreen", self.window.on_enter_fullscreen, self)
        view.connect("leave-fullscreen", self.window.on_leave_fullscreen, self)
        try:
            view.connect("key-press-event", self.window.on_key, self)
        except Exception:
            pass

    def load_uri(self, uri):
        self.internal = False
        self.error_page = False
        self.view.load_uri(uri)

    def show_placeholder(self):
        self.internal = True
        self.error_page = False
        self.view.load_html(_new_tab_html(), None)

    def show_error(self, uri, message):
        self.internal = True
        self.error_page = True
        self.view.load_html(_error_html(uri, message), None)

    def current_title(self):
        try:
            title = self.view.get_title() or ""
        except Exception:
            title = ""
        if title:
            return title
        try:
            uri = self.view.get_uri() or ""
        except Exception:
            uri = ""
        host = urllib.parse.urlsplit(uri).hostname or ""
        return host or "New tab"

    def update_label(self):
        title = self.current_title()
        self.title_label.set_text(title[:60])
        self.title_label.set_tooltip_text(title)


class BrowserWindow(_WindowBase):
    """The native browse window."""

    def __init__(self, args, check=False):
        super().__init__(title="JawnOS Browse")
        self.set_default_size(1200, 850)
        self.args = args
        self.check_mode = check
        self.mode = "measure" if args.mode == "measure" else "browse"
        self.app = (args.app or "")[:200]
        self.uuid = (args.uuid or "")[:200]
        self.manager = args.manager or ""
        self._closing = False
        self._main_running = False
        self._flush_source = 0
        self._downloads = set()

        self.data_dir = browser_data_dir()
        try:
            os.makedirs(self.data_dir, exist_ok=True)
        except OSError as exc:
            LOG.warning("could not create the browse data directory: %s", exc)
        self.history = History(os.path.join(self.data_dir, "history.jsonl"))
        self.client = BrowseClient(manager=self.manager, logger=LOG)
        self.usage = SiteUsage(self.client, logger=LOG)

        self._build_context()
        self._build_ui()
        self.connect("notify::is-active", self._on_active_changed)
        self.connect("focus-in-event", self._on_active_changed)
        self.connect("focus-out-event", self._on_active_changed)
        self.connect("key-press-event", self.on_key)
        self.url_entry.connect("key-press-event", self.on_key)
        self.connect("destroy", self._on_destroy)

        uri = None
        if not check:
            uri = normalise_url(args.url)
        tab = self.new_tab(uri=uri, placeholder=uri is None)
        if not check:
            if uri is None and (args.url or "").strip():
                self._set_status("Enter an http or https address.")
            if tab is not None and uri is None:
                self.url_entry.grab_focus()
            self._flush_source = GLib.timeout_add_seconds(
                FLUSH_SECONDS, self._on_flush_timer)

    # ---- construction ----------------------------------------------------

    def _build_context(self):
        data_path = os.path.join(self.data_dir, "data")
        cache_path = os.path.join(self.data_dir, "cache")
        context = None
        try:
            os.makedirs(data_path, exist_ok=True)
            os.makedirs(cache_path, exist_ok=True)
            manager = WebKit2.WebsiteDataManager(
                base_data_directory=data_path,
                base_cache_directory=cache_path,
            )
            context = WebKit2.WebContext.new_with_website_data_manager(manager)
        except Exception as exc:
            # Never fall back to the default context: it is the manager view's
            # store. An ephemeral context is still a separate cookie jar.
            LOG.warning("could not open the persistent browse store (%s); "
                        "using an in-memory store", exc)
            context = WebKit2.WebContext.new_ephemeral()
        self.context = context
        try:
            self.context.set_cache_model(WebKit2.CacheModel.DOCUMENT_BROWSER)
        except Exception:
            pass
        try:
            # Explicit, even though it is the default: no exception is ever
            # added for an external site.
            self.context.set_tls_errors_policy(WebKit2.TLSErrorsPolicy.FAIL)
        except Exception:
            pass
        try:
            self.context.connect("download-started", self.on_download_started)
        except Exception:
            pass

        self.content_manager = WebKit2.UserContentManager()
        if self.mode == "measure":
            try:
                self.content_manager.register_script_message_handler("jawnos_measure")
                self.content_manager.connect(
                    "script-message-received::jawnos_measure",
                    self.on_measure_message)
                self.content_manager.add_script(WebKit2.UserScript.new(
                    "window.__jawnosMeasureAuto = true;",
                    WebKit2.UserContentInjectedFrames.TOP_FRAME,
                    WebKit2.UserScriptInjectionTime.START,
                    None, None,
                ))
                self.content_manager.add_script(WebKit2.UserScript.new(
                    _PICKER_JS,
                    WebKit2.UserContentInjectedFrames.TOP_FRAME,
                    WebKit2.UserScriptInjectionTime.END,
                    None, None,
                ))
            except Exception:
                LOG.exception("could not install the measure picker")

    def _build_ui(self):
        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.set_title("JawnOS Browse")
        header.set_subtitle("Measure mode" if self.mode == "measure" else "")
        self.set_titlebar(header)

        self.back_button = self._tool_button(
            "go-previous-symbolic", "Back", self.go_back)
        self.forward_button = self._tool_button(
            "go-forward-symbolic", "Forward", self.go_forward)
        self.reload_button = self._tool_button(
            "view-refresh-symbolic", "Reload", self.reload_or_stop)
        header.pack_start(self.back_button)
        header.pack_start(self.forward_button)
        header.pack_start(self.reload_button)

        self.url_entry = Gtk.Entry()
        self.url_entry.set_placeholder_text("Enter an address")
        self.url_entry.set_width_chars(52)
        self.url_entry.set_hexpand(True)
        self.url_entry.connect("activate", self.on_url_activate)
        header.set_custom_title(self.url_entry)

        self.new_tab_button = self._tool_button(
            "tab-new-symbolic", "New tab", lambda *_: self.new_tab())
        self.find_button = self._tool_button(
            "edit-find-symbolic", "Find in page (Ctrl+F)", self.open_find)
        self.history_button = Gtk.MenuButton()
        self.history_button.set_image(Gtk.Image.new_from_icon_name(
            "document-open-recent-symbolic", Gtk.IconSize.LARGE_TOOLBAR))
        self.history_button.set_tooltip_text("History")
        self.history_button.set_popover(self._build_history_popover())
        header.pack_end(self.history_button)
        header.pack_end(self.new_tab_button)
        header.pack_end(self.find_button)

        root = Gtk.Box(orientation=_VBox)
        self.find_bar = self._build_find_bar()
        root.pack_start(self.find_bar, False, False, 0)

        self.notebook = Gtk.Notebook()
        self.notebook.set_scrollable(True)
        self.notebook.set_show_border(False)
        self.notebook.connect("switch-page", self.on_switch_page)
        root.pack_start(self.notebook, True, True, 0)

        status_bar = Gtk.Box(orientation=_HBox, spacing=6)
        status_bar.set_border_width(4)
        self.status_label = Gtk.Label(label="")
        self.status_label.set_xalign(0)
        self.status_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.progress_bar = Gtk.ProgressBar()
        self.progress_bar.set_no_show_all(True)
        self.progress_bar.set_size_request(170, -1)
        status_bar.pack_start(self.status_label, True, True, 0)
        status_bar.pack_start(self.progress_bar, False, False, 0)
        root.pack_start(status_bar, False, False, 0)

        self.add(root)

    def _tool_button(self, icon, tooltip, callback):
        button = Gtk.Button.new_from_icon_name(icon, Gtk.IconSize.LARGE_TOOLBAR)
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.set_tooltip_text(tooltip)
        button.connect("clicked", callback)
        return button

    def _build_find_bar(self):
        revealer = Gtk.Revealer()
        revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_DOWN)
        bar = Gtk.Box(orientation=_HBox, spacing=6)
        bar.set_border_width(4)
        self.find_entry = Gtk.SearchEntry()
        self.find_entry.set_placeholder_text("Find in page")
        self.find_entry.set_hexpand(True)
        self.find_entry.connect("search-changed", self.on_find_changed)
        self.find_entry.connect("activate", self.on_find_next)
        bar.pack_start(self.find_entry, True, True, 0)
        bar.pack_start(self._tool_button(
            "go-up-symbolic", "Previous match", self.find_previous), False, False, 0)
        bar.pack_start(self._tool_button(
            "go-down-symbolic", "Next match", self.find_next), False, False, 0)
        bar.pack_start(self._tool_button(
            "window-close-symbolic", "Close find", self.close_find), False, False, 0)
        bar.show_all()
        revealer.add(bar)
        revealer.set_reveal_child(False)
        return revealer

    def _build_history_popover(self):
        self.history_popover = Gtk.Popover()
        box = Gtk.Box(orientation=_VBox, spacing=6)
        box.set_border_width(8)
        heading = Gtk.Label(label="History")
        heading.set_xalign(0)
        box.pack_start(heading, False, False, 0)
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_min_content_width(430)
        scrolled.set_min_content_height(420)
        self.history_list = Gtk.ListBox()
        self.history_list.set_selection_mode(Gtk.SelectionMode.NONE)
        self.history_list.connect("row-activated", self.on_history_row)
        scrolled.add(self.history_list)
        box.pack_start(scrolled, True, True, 0)
        box.show_all()
        self.history_popover.add(box)
        self.history_popover.connect("show", lambda *_: self.reload_history())
        return self.history_popover

    # ---- tabs ------------------------------------------------------------

    def current_tab(self):
        try:
            page = self.notebook.get_nth_page(self.notebook.get_current_page())
        except Exception:
            page = None
        return page if isinstance(page, BrowserTab) else None

    def new_tab(self, uri=None, placeholder=True, switch=True):
        tab = BrowserTab(self)
        page = self.notebook.append_page(tab, tab.tab_label)
        self.notebook.show_all()
        if switch:
            self.notebook.set_current_page(page)
        if uri:
            self._navigate(uri, tab)
        elif placeholder:
            tab.show_placeholder()
        if switch and not self.check_mode and placeholder and not uri:
            self.url_entry.grab_focus()
        self._sync_toolbar()
        self._update_url_bar(tab, force=True)
        return tab

    def close_tab(self, tab):
        if self._closing:
            return
        page = self.notebook.page_num(tab)
        if page < 0:
            return
        if self.notebook.get_n_pages() <= 1:
            self.close()
            return
        try:
            tab.view.stop_loading()
        except Exception:
            pass
        self.notebook.remove_page(page)
        try:
            tab.tab_label.destroy()
        except Exception:
            pass
        tab.destroy()
        self._sync_site()
        self._sync_toolbar()

    # ---- navigation ------------------------------------------------------

    def _navigate(self, uri, tab=None):
        tab = tab or self.current_tab()
        if tab is None:
            return False
        parsed = urllib.parse.urlsplit(uri or "")
        if parsed.scheme.lower() not in ("http", "https") or not parsed.netloc:
            self._set_status("Only http and https addresses can be opened.")
            return False
        if blocked_host(uri) and not allow_private():
            tab.show_error(
                uri,
                "Browse will not open this address because it is on a private "
                "network (loopback, link-local, or another local range).")
            self._set_status("Blocked a private-network address.")
            return False
        tab.load_uri(uri)
        return True

    def on_url_activate(self, entry):
        uri = normalise_url(entry.get_text())
        if not uri:
            self._set_status("Enter an address like example.com.")
            return
        self._navigate(uri)

    def go_back(self, *_):
        tab = self.current_tab()
        if tab and tab.view.can_go_back():
            tab.view.go_back()

    def go_forward(self, *_):
        tab = self.current_tab()
        if tab and tab.view.can_go_forward():
            tab.view.go_forward()

    def reload_or_stop(self, *_):
        tab = self.current_tab()
        if not tab:
            return
        if tab.view.is_loading():
            tab.view.stop_loading()
        else:
            tab.view.reload()

    def _sync_toolbar(self):
        tab = self.current_tab()
        if tab is None:
            self.back_button.set_sensitive(False)
            self.forward_button.set_sensitive(False)
            self._set_loading(False)
            return
        try:
            self.back_button.set_sensitive(tab.view.can_go_back())
            self.forward_button.set_sensitive(tab.view.can_go_forward())
            loading = tab.view.is_loading()
        except Exception:
            loading = False
        self._set_loading(loading)
        self._update_url_bar(tab)

    def _set_loading(self, loading):
        icon = "process-stop-symbolic" if loading else "view-refresh-symbolic"
        self.reload_button.set_image(Gtk.Image.new_from_icon_name(
            icon, Gtk.IconSize.LARGE_TOOLBAR))
        self.reload_button.set_tooltip_text("Stop" if loading else "Reload")

    def _update_url_bar(self, tab, force=False):
        if tab is None:
            return
        try:
            uri = tab.view.get_uri() or ""
        except Exception:
            uri = ""
        if tab.internal and (not uri or uri.startswith(("about:", "data:"))):
            text = ""
        else:
            text = uri
        if force or not self.url_entry.has_focus():
            self.url_entry.set_text(text)
        self.url_entry.set_position(-1)

    def _sync_site(self):
        if self._closing:
            return
        tab = self.current_tab()
        try:
            active = bool(self.get_property("is-active"))
        except Exception:
            active = False
        if not active or tab is None:
            self.usage.idle()
            return
        try:
            uri = tab.view.get_uri() or ""
        except Exception:
            uri = ""
        if tab.internal or not uri.startswith(("http://", "https://")):
            self.usage.idle()
            return
        if blocked_host(uri) and not allow_private():
            self.usage.idle()
            return
        key = registrable_domain(uri)
        if not key:
            self.usage.idle()
            return
        try:
            title = tab.view.get_title() or ""
        except Exception:
            title = ""
        self.usage.visit(key, uri, title)

    # ---- WebKit signals --------------------------------------------------

    def on_load_changed(self, view, event, tab):
        try:
            if event == WebKit2.LoadEvent.STARTED:
                if tab is self.current_tab():
                    self._set_loading(True)
                    self._sync_toolbar()
                return
            if event in (WebKit2.LoadEvent.COMMITTED, WebKit2.LoadEvent.REDIRECTED):
                if tab is self.current_tab():
                    self._sync_toolbar()
                return
            if event != WebKit2.LoadEvent.FINISHED:
                return
        except Exception:
            return
        tab.update_label()
        if tab is self.current_tab():
            self.set_title("%s — JawnOS Browse" % tab.current_title())
            self._sync_toolbar()
            self._set_status("")
            self.url_entry.set_position(-1)
            self._sync_site()
        try:
            uri = view.get_uri() or ""
        except Exception:
            uri = ""
        if not tab.internal and not tab.error_page and uri.startswith(("http://", "https://")):
            self.history.add(uri, view.get_title() or "")
        # A measure window re-arms itself through the injected start script,
        # but the first about:blank page never gets the flag. Arm only a real
        # page that finished loading.
        if self.mode == "measure" and tab is self.current_tab() \
                and not tab.internal and uri.startswith(("http://", "https://")):
            self._arm_picker()

    def _arm_picker(self):
        tab = self.current_tab()
        if self.mode != "measure" or tab is None or tab.internal:
            return
        try:
            tab.view.evaluate_javascript(
                "window.__jawnosPicker && window.__jawnosPicker.arm(true);",
                -1, None, None, None, None, None)
        except Exception:
            pass

    def on_uri_changed(self, view, _pspec, tab):
        try:
            uri = view.get_uri() or ""
        except Exception:
            uri = ""
        if uri and not uri.startswith(("about:", "data:")):
            tab.internal = False
            tab.error_page = False
        if tab is self.current_tab():
            self._update_url_bar(tab)
            self._sync_toolbar()
            self._sync_site()
        if not tab.internal:
            tab.update_label()

    def on_title_changed(self, view, _pspec, tab):
        tab.update_label()
        if tab is self.current_tab():
            self.set_title("%s — JawnOS Browse" % tab.current_title())
            self._sync_site()

    def on_load_failed(self, view, load_event, failing_uri, error, tab):
        code = None
        try:
            code = error.code
        except Exception:
            pass
        try:
            if code == WebKit2.NetworkError.CANCELLED:
                return False
        except Exception:
            pass
        if not failing_uri or failing_uri.startswith(("about:", "data:")):
            return False
        message = "The page could not be loaded."
        try:
            if error and error.message:
                message = error.message
        except Exception:
            pass
        if blocked_host(failing_uri) and not allow_private():
            tab.show_error(
                failing_uri,
                "Browse will not open this address because it is on a private "
                "network (loopback, link-local, or another local range).")
        else:
            tab.show_error(failing_uri, message)
        if tab is self.current_tab():
            self._set_status(message)
            self._sync_toolbar()
        self._sync_site()
        return True

    def on_tls_error(self, view, failing_uri, certificate, errors, tab):
        # Returning False lets the load fail. Never call
        # allow_tls_certificate_for_host here: that rule belongs to the
        # manager's own HTTP client, not to a page from the internet.
        self._set_status("The site's certificate could not be verified.")
        return False

    def on_decide_policy(self, view, decision, decision_type, tab):
        try:
            if decision_type == WebKit2.PolicyDecisionType.NAVIGATION_ACTION \
                    or decision_type == WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION:
                action = decision.get_navigation_action()
                uri = action.get_request().get_uri() or ""
                if not uri or uri == "about:blank":
                    decision.use()
                    return True
                parsed = urllib.parse.urlsplit(uri)
                scheme = (parsed.scheme or "").lower()
                if scheme in ("http", "https"):
                    if blocked_host(uri) and not allow_private():
                        decision.ignore()
                        if decision_type == WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
                            tab.show_error(
                                uri,
                                "Browse will not open this address because it "
                                "is on a private network (loopback, link-local, "
                                "or another local range).")
                        self._set_status("Blocked a private-network address.")
                        return True
                    decision.use()
                    return True
                if scheme in ("about", "data", "blob"):
                    decision.use()
                    return True
                decision.ignore()
                if scheme == "file":
                    self._set_status("Browse does not open local files.")
                elif scheme in EXTERNAL_SCHEMES and action.is_user_gesture():
                    self._launch_external(uri)
                else:
                    self._set_status(
                        "Browse does not open this kind of link.")
                return True
            decision.use()
        except Exception:
            try:
                decision.ignore()
            except Exception:
                pass
        return True

    def on_create(self, view, navigation_action, tab):
        try:
            uri = navigation_action.get_request().get_uri() or ""
        except Exception:
            uri = ""
        if uri and blocked_host(uri) and not allow_private():
            self._set_status("Blocked a private-network address.")
            return None
        new_tab = self.new_tab(uri=None, placeholder=not uri, switch=True)
        return new_tab.view if new_tab is not None else None

    def on_permission(self, view, request, tab):
        # Browse asks for nothing: no camera, microphone, location or
        # notifications. Media playback itself is not a permission request.
        try:
            request.deny()
        except Exception:
            pass
        return True

    def on_enter_fullscreen(self, view, tab):
        try:
            self.fullscreen()
        except Exception:
            pass
        return False

    def on_leave_fullscreen(self, view, tab):
        try:
            self.unfullscreen()
        except Exception:
            pass
        return False

    def _on_active_changed(self, *_):
        self._sync_site()

    def _on_flush_timer(self):
        if self._closing:
            return False
        threading.Thread(target=self.usage.flush, kwargs={"roll": True},
                         name="browse-flush", daemon=True).start()
        return True

    def _launch_external(self, uri):
        scheme = urllib.parse.urlsplit(uri).scheme.lower()
        if scheme not in EXTERNAL_SCHEMES:
            self._set_status("Browse does not open this kind of link.")
            return
        try:
            if Gtk.show_uri_on_window(self, uri, Gdk.CURRENT_TIME):
                self._set_status("Opened in another app.")
                return
        except Exception:
            pass
        try:
            Gio.AppInfo.launch_default_for_uri(uri, None)
            self._set_status("Opened in another app.")
        except Exception:
            self._set_status("No app is registered for this link.")

    # ---- tabs / notebook -------------------------------------------------

    def on_switch_page(self, notebook, page, page_num):
        if not isinstance(page, BrowserTab):
            return
        self._update_url_bar(page, force=True)
        self._sync_toolbar()
        if page is self.current_tab():
            self.set_title("%s — JawnOS Browse" % page.current_title())
            self._sync_site()
            if self.find_bar.get_reveal_child():
                self.on_find_changed(self.find_entry)

    def on_history_row(self, _listbox, row):
        uri = getattr(row, "uri", "")
        self.history_popover.popdown()
        if uri:
            self._navigate(uri)

    def reload_history(self):
        for child in self.history_list.get_children():
            self.history_list.remove(child)
        for entry in self.history.recent(200):
            row = Gtk.ListBoxRow()
            box = Gtk.Box(orientation=_VBox, spacing=2)
            box.set_border_width(6)
            title = Gtk.Label(label=(entry.get("title") or entry.get("url") or "")[:140])
            title.set_xalign(0)
            title.set_ellipsize(Pango.EllipsizeMode.END)
            url = Gtk.Label(label=(entry.get("url") or "")[:180])
            url.set_xalign(0)
            url.set_ellipsize(Pango.EllipsizeMode.END)
            url.get_style_context().add_class("dim-label")
            box.pack_start(title, False, False, 0)
            box.pack_start(url, False, False, 0)
            row.add(box)
            row.uri = entry.get("url") or ""
            self.history_list.add(row)
        self.history_list.show_all()

    # ---- find ------------------------------------------------------------

    def open_find(self, *_):
        self.find_bar.set_reveal_child(True)
        self.find_entry.grab_focus()
        self.find_entry.select_region(0, -1)

    def close_find(self, *_):
        self.find_bar.set_reveal_child(False)
        self.find_entry.set_text("")
        tab = self.current_tab()
        if tab:
            try:
                tab.view.get_find_controller().search(
                    "", WebKit2.FindOptions.CASE_INSENSITIVE, 0)
            except Exception:
                pass

    def _find(self, text, backwards=False):
        tab = self.current_tab()
        if not tab:
            return
        options = WebKit2.FindOptions.CASE_INSENSITIVE | WebKit2.FindOptions.WRAP_AROUND
        if backwards:
            options |= WebKit2.FindOptions.BACKWARDS
        try:
            controller = tab.view.get_find_controller()
            if text:
                controller.search(text, options, 0)
            else:
                controller.search("", options, 0)
        except Exception:
            pass

    def on_find_changed(self, entry):
        self._find(entry.get_text())

    def on_find_next(self, entry):
        self._find(entry.get_text())

    def find_next(self, *_):
        self._find(self.find_entry.get_text())

    def find_previous(self, *_):
        self._find(self.find_entry.get_text(), backwards=True)

    # ---- keyboard --------------------------------------------------------

    def on_key(self, _widget, event, _tab=None):
        try:
            key = event.keyval
            state = event.state & Gtk.accelerator_get_default_mod_mask()
            control = bool(state & Gdk.ModifierType.CONTROL_MASK)
            alt = bool(state & Gdk.ModifierType.ALT_MASK)
            shift = bool(state & Gdk.ModifierType.SHIFT_MASK)
        except Exception:
            return False
        if control and key in (Gdk.KEY_l, Gdk.KEY_L):
            self.url_entry.grab_focus()
            self.url_entry.select_region(0, -1)
            return True
        if control and key in (Gdk.KEY_t, Gdk.KEY_T):
            self.new_tab()
            return True
        if control and key in (Gdk.KEY_w, Gdk.KEY_W):
            tab = self.current_tab()
            if tab:
                self.close_tab(tab)
            return True
        if control and key in (Gdk.KEY_f, Gdk.KEY_F):
            self.open_find()
            return True
        if control and key in (Gdk.KEY_g, Gdk.KEY_G):
            if shift:
                self.find_previous()
            else:
                self.find_next()
            return True
        if key == Gdk.KEY_F5 or (control and key in (Gdk.KEY_r, Gdk.KEY_R)):
            self.reload_or_stop()
            return True
        if alt and key == Gdk.KEY_Left:
            self.go_back()
            return True
        if alt and key == Gdk.KEY_Right:
            self.go_forward()
            return True
        if key == Gdk.KEY_Escape:
            if self.find_bar.get_reveal_child():
                self.close_find()
                return True
            tab = self.current_tab()
            if tab and tab.view.is_loading():
                tab.view.stop_loading()
                return True
        return False

    # ---- downloads -------------------------------------------------------

    def on_download_started(self, context, download):
        try:
            download.set_allow_overwrite(True)
            download.connect("decide-destination", self.on_decide_destination)
            download.connect("received-data", self.on_download_progress, download)
            download.connect("finished", self.on_download_finished, download)
            download.connect("failed", self.on_download_failed, download)
            self._downloads.add(download)
        except Exception:
            LOG.exception("could not attach to the download")

    def on_decide_destination(self, download, suggested_filename, _data):
        suggested = (suggested_filename or "download").strip() or "download"
        dialog = Gtk.FileChooserDialog(
            title="Save download",
            transient_for=self,
            action=Gtk.FileChooserAction.SAVE,
        )
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Save", Gtk.ResponseType.OK)
        dialog.set_do_overwrite_confirmation(True)
        dialog.set_current_name(suggested)
        folder = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DOWNLOAD)
        if not folder:
            folder = os.path.expanduser("~")
        try:
            dialog.set_current_folder(folder)
        except Exception:
            pass
        response = dialog.run()
        path = dialog.get_filename()
        dialog.destroy()
        if response != Gtk.ResponseType.OK or not path:
            try:
                download.cancel()
            except Exception:
                pass
            return True
        try:
            download.set_destination(Gio.File.new_for_path(path).get_uri())
            self._set_status("Downloading %s…" % os.path.basename(path))
            self.progress_bar.set_fraction(0.0)
            self.progress_bar.show()
        except Exception as exc:
            self._set_status("Could not start the download: %s" % exc)
        return True

    def on_download_progress(self, download, data_length, _data):
        try:
            fraction = download.get_estimated_progress()
            if 0.0 <= fraction <= 1.0:
                self.progress_bar.set_fraction(fraction)
                self.progress_bar.show()
        except Exception:
            pass

    def on_download_finished(self, download, _data):
        self._downloads.discard(download)
        name = "file"
        try:
            dest = download.get_destination() or ""
            name = os.path.basename(urllib.parse.unquote(
                urllib.parse.urlsplit(dest).path)) or "file"
        except Exception:
            pass
        self._set_status("Downloaded %s" % name)
        if not self._downloads:
            self.progress_bar.hide()

    def on_download_failed(self, download, error, _data):
        self._downloads.discard(download)
        message = getattr(error, "message", None) or "the download failed"
        self._set_status("Download failed: %s" % message)
        if not self._downloads:
            self.progress_bar.hide()

    # ---- measure ---------------------------------------------------------

    def on_measure_message(self, _content, result):
        raw = _js_text(result)
        if not raw:
            return False
        # A message can only be a pick payload. Anything else is ignored; the
        # user script is the only thing that sends this handler a message.
        if len(raw) > MAX_MEASURE_HTML * 3:
            return False
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            return False
        if not isinstance(payload, dict) or payload.get("action") != "pick":
            return False
        if self.mode != "measure":
            return False
        selector = payload.get("selector")
        document = payload.get("html")
        if not isinstance(selector, str) or not selector.strip():
            return False
        if not isinstance(document, str) or not document:
            return False
        index = payload.get("index")
        if not isinstance(index, int) or isinstance(index, bool) or index < 0:
            index = 0
        uri = payload.get("url") if isinstance(payload.get("url"), str) else ""
        title = payload.get("title") if isinstance(payload.get("title"), str) else ""
        document = document[:MAX_MEASURE_HTML]

        if not self.app:
            self._show_message(
                "Measuring needs an app",
                "This window was opened without an app name. Open the saved "
                "page from Internet and use its measure button.")
            return False
        data = {
            "app": self.app,
            "uuid": self.uuid,
            "url": uri,
            "selector": selector,
            "index": index,
            "html": document,
            "title": title,
        }
        self._set_status("Measuring…")
        threading.Thread(target=self._measure_live, args=(data,),
                         name="browse-measure", daemon=True).start()
        return False

    def _measure_live(self, data):
        answer = self.client.post_form("/manager/web/measure/live", data)
        GLib.idle_add(self._after_measure_live, data, answer)

    def _after_measure_live(self, data, answer):
        if self._closing:
            return False
        if not isinstance(answer, dict) or not answer.get("ok"):
            self._set_status("The manager did not measure this page.")
            self._show_message(
                "Could not measure",
                "The manager did not answer the live-page request. Check that "
                "it is running and that this app is signed in.")
            return False
        candidates = answer.get("candidates")
        if not isinstance(candidates, list) or not candidates:
            self._set_status("")
            self._show_message(
                "Nothing to measure",
                "Nothing on this page read as a value. Try clicking the "
                "number itself.")
            return False
        self._set_status("")
        self._show_candidates(data, answer, candidates)
        return False

    def _show_candidates(self, data, answer, candidates):
        dialog = Gtk.Dialog(
            title="Choose what to measure",
            transient_for=self,
            modal=True,
        )
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Save", Gtk.ResponseType.OK)
        dialog.set_default_size(680, 500)
        content = dialog.get_content_area()
        intro = Gtk.Label(
            label="Pick the shape that should be watched. Each one is tested "
                  "against this page.")
        intro.set_xalign(0)
        intro.set_line_wrap(True)
        content.pack_start(intro, False, False, 6)

        scrolled = Gtk.ScrolledWindow()
        scrolled.set_hexpand(True)
        scrolled.set_vexpand(True)
        rows = Gtk.Box(orientation=_VBox, spacing=8)
        group = None
        choices = []
        for candidate in candidates:
            if not isinstance(candidate, dict):
                continue
            spec = candidate.get("spec")
            if not isinstance(spec, dict):
                continue
            kind = str(candidate.get("kind") or "")
            value = str(candidate.get("value") or "")
            radio = Gtk.RadioButton.new_with_label_from_widget(
                group, "%s — %s" % (kind, value))
            if group is None:
                group = radio
            spec_text = json.dumps(spec, sort_keys=True, ensure_ascii=False)
            radio.set_tooltip_text(spec_text)
            row = Gtk.Box(orientation=_VBox, spacing=2)
            row.pack_start(radio, False, False, 0)
            spec_label = Gtk.Label(label=spec_text)
            spec_label.set_xalign(0)
            spec_label.set_line_wrap(True)
            spec_label.set_selectable(True)
            spec_label.get_style_context().add_class("dim-label")
            row.pack_start(spec_label, False, False, 0)
            rows.pack_start(row, False, False, 0)
            choices.append((radio, spec))
        scrolled.add(rows)
        content.pack_start(scrolled, True, True, 0)
        if not choices:
            dialog.destroy()
            self._show_message(
                "Nothing to measure",
                "Nothing on this page read as a value. Try clicking the "
                "number itself.")
            return
        dialog.show_all()
        response = dialog.run()
        chosen = None
        if response == Gtk.ResponseType.OK:
            for radio, spec in choices:
                if radio.get_active():
                    chosen = spec
                    break
        dialog.destroy()
        if chosen is None:
            self._set_status("")
            return
        # The launch contract carries no measure name (the live route accepts
        # one, but no caller supplies it), so this is the empty name the
        # confirmation form would have used. See the contract-gap note in the
        # module docstring.
        submit = {
            "app": self.app,
            "measure": str(answer.get("measure") or data.get("measure") or ""),
            "spec": json.dumps(chosen, ensure_ascii=False),
        }
        self._set_status("Saving the measure…")
        threading.Thread(target=self._measure_submit, args=(submit,),
                         name="browse-measure-save", daemon=True).start()

    def _measure_submit(self, submit):
        answer = self.client.post_form("/manager/web/measure/submit", submit)
        GLib.idle_add(self._after_measure_submit, answer)

    def _after_measure_submit(self, answer):
        if self._closing:
            return False
        if isinstance(answer, dict):
            self._set_status("Measure saved.")
            self._show_message("Measure saved",
                               "The chosen shape is now stored for this app.")
        else:
            self._set_status("The measure was not saved.")
            self._show_message(
                "Not saved",
                "The manager did not answer the save request.")
        return False

    # ---- status / shutdown ----------------------------------------------

    def _set_status(self, text):
        try:
            self.status_label.set_text(text or "")
        except Exception:
            pass

    def _show_message(self, title, body):
        if self._closing:
            return
        try:
            dialog = Gtk.MessageDialog(
                transient_for=self,
                modal=True,
                message_type=Gtk.MessageType.INFO,
                buttons=Gtk.ButtonsType.OK,
                text=title,
            )
            dialog.format_secondary_text(body)
            dialog.run()
            dialog.destroy()
        except Exception:
            pass

    def shutdown(self):
        if self._closing:
            return
        self._closing = True
        if self._flush_source:
            try:
                GLib.source_remove(self._flush_source)
            except Exception:
                pass
            self._flush_source = 0
        try:
            self.usage.shutdown()
        except Exception:
            LOG.exception("could not flush site time")

    def _on_destroy(self, *_):
        self.shutdown()
        if self._main_running:
            try:
                Gtk.main_quit()
            except Exception:
                pass


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def _parser():
    parser = argparse.ArgumentParser(
        prog="jawnos-browse",
        description="JawnOS Browse -- the native WebKitGTK browser window.",
        epilog="The window posts site-time spans and live page measures through "
               "the desktop app's stored manager ticket.",
    )
    parser.add_argument("--manager", default="",
                        help="the manager URL that launched this window")
    parser.add_argument("--url", default="", help="address to open")
    parser.add_argument("--mode", choices=("browse", "measure"),
                        default="browse", help="arm the element picker in measure mode")
    parser.add_argument("--app", default="", help="app to store a measure for")
    parser.add_argument("--uuid", default="", help="saved-page uuid to measure")
    parser.add_argument("--token", default="",
                        help="unused; accepted for the launcher contract")
    parser.add_argument("--check", "--dry-run", dest="check", action="store_true",
                        help="construct the window and exit without loading a page")
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if _GTK is None:
        sys.stderr.write(
            "jawnos-browse: WebKitGTK 4.1 and PyGObject are required (%s)\n"
            % _GTK_ERROR)
        return 2
    ok, _argv = Gtk.init_check([])
    if not ok:
        sys.stderr.write("jawnos-browse: no display is available\n")
        return 2
    window = BrowserWindow(args, check=args.check)
    if args.check:
        window.destroy()
        print("jawnos-browse: window constructed")
        return 0
    window._main_running = True
    window.show_all()
    window.present()
    GLib.idle_add(window._sync_site)
    Gtk.main()
    window.shutdown()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
