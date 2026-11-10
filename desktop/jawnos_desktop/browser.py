"""``jawnos-browse`` -- the JawnOS Internet app's native browser window.

The Internet app has two halves. **Web** is the manager's saved-page and
measure pipeline. **Browse** is a real browser, and a live page cannot run
inside the manager's own WebView: it would share the manager's cookie jar and
its script bridge. So Browse is a sibling process with a Qt WebEngine
(Chromium) view of its own, a named on-disk profile of its own, and no app-key
bridge back into the manager.

What this window does:

* tabs, an address bar that also searches a phrase, back/forward/reload/stop,
  home, find-in-page, downloads, error pages and external protocol
  delegation;
* its own persistent ``QWebEngineProfile("jawnos-browse")`` under
  ``~/.config/jawnos/browse-webengine`` -- never the manager view's profile
  (``jawnos``) and never WebKitGTK's store;
* a local JSONL history;
* site-time accounting: the focused tab's registrable domain is queued as a
  ``usage_sessions`` row (``kind=site``, ``source=browser``) while this window
  is active. Spans are posted through the desktop app's stored ticket by
  :class:`jawnos_desktop.usage.ManagerClient`, which this module subclasses
  without changing;
* an ad blocker: a small baseline of ad-serving hosts enforced by a
  ``QWebEngineUrlRequestInterceptor`` plus cosmetic selectors injected into an
  isolated script world, and bug mode -- a picker that hides the element a
  person taps and remembers that selector for the site in ``adblock.json``;
* ``--mode measure``: a message-only element picker that posts the clicked
  element's document to ``/manager/web/measure/live`` and shows the returned
  candidates. The returned confirmation HTML is never loaded or evaluated.

Safety rules (see ``docs/internet-contract.md``):

* the browse view carries no app-key bridge. The page-bridge channel it does
  expose answers only media state, its own ``JawnBrowse`` tab request, the
  local ad-block picker and (in measure mode) the measure picker; an
  ``app_pubkey`` or ``open_manager`` request from a page is ignored;
* the ad-block picker runs in an isolated Qt script world, so a page cannot
  see or call it; its messages reach Python over a DOM event and are validated
  again here;
* TLS errors are accepted for the house's self-signed certificate, the same
  exception the Qt shell makes; external ``file:`` and unknown schemes are
  refused;
* navigation to loopback, link-local and other private addresses is refused
  unless ``JAWNOS_BROWSE_ALLOW_PRIVATE=1``.
"""

import argparse
import collections
import ipaddress
import json
import logging
import os
import re
import sys
import threading
import urllib.parse

from . import bridge, core, errorpage, gpu, keepawake, usage

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

# The Browse profile is named and on-disk, under the house config directory.
# It is deliberately not the manager view's "jawnos" profile: the two stores
# must not share a cookie jar.
PROFILE_NAME = "jawnos-browse"
PROFILE_DIR_NAME = "browse-webengine"

# The address bar searches a phrase. DuckDuckGo is the house's own default
# general engine (perl/gb/03_engines_and_tools.pl), so a phrase typed in Browse
# lands somewhere the rest of the house already treats as neutral.
SEARCH_PREFIX = "https://duckduckgo.com/?q="

# --------------------------------------------------------------------------
# The ad-block standard
# --------------------------------------------------------------------------
# ``adblock.json`` in the browse data directory holds the person's own list:
#
#   {"version": 1, "enabled": true,
#    "sites": {"example.com": {"selectors": ["..."]}}}
#
# The baseline below ships with the window. It is deliberately small and
# readable: it blocks the hosts that serve display/video ads and hides the
# containers they leave behind. It is not an EasyList mirror; bug mode is the
# part that learns a site's own shapes.
ADBLOCK_FILE = "adblock.json"
ADBLOCK_VERSION = 1
MAX_SELECTOR_CHARS = 512
MAX_SELECTORS_PER_SITE = 500

# Hosts that serve advertisements. A subdomain matches too
# (``securepubads.g.doubleclick.net``). Keep this list to ad serving, not
# general analytics: an analytics request can be load-bearing for a page.
BASELINE_AD_HOSTS = (
    "2o7.net", "33across.com", "adform.net", "adnxs.com", "adroll.com",
    "ads.tubi.io", "adsafeprotected.com", "adsrvr.org", "advertising.com",
    "agkn.com", "amazon-adsystem.com", "bidswitch.net",
    "casalemedia.com", "criteo.com", "criteo.net", "demdex.net",
    "district-m.net", "doubleclick.net", "everesttech.net",
    "flashtalking.com", "freewheel.tv", "fwmrm.net",
    "googleadservices.com", "googlesyndication.com", "gumgum.com",
    "imrworldwide.com", "indexww.com", "innovid.com", "lijit.com",
    "mathtag.com", "media.net", "moatads.com", "omtrdc.net",
    "openx.net", "outbrain.com", "pubmatic.com", "quantserve.com",
    "rubiconproject.com", "scorecardresearch.com", "serving-sys.com",
    "sharethrough.com", "smartadserver.com", "sovrn.com",
    "spotxchange.com", "taboola.com", "tapad.com", "teads.tv",
    "tremorhub.com", "turn.com", "undertone.com", "yieldlab.net",
    "yieldmo.com", "zedo.com",
)

# Common containers an ad host leaves behind. These are specific names, not
# ``[class*="ad"]`` (which would also match "shadow" and "header") and not
# ``[class^="ad-"]`` (which would hide an "ad-free" page state).
BASELINE_COSMETIC_SELECTORS = (
    "ins.adsbygoogle",
    "[data-ad]",
    "[data-ads]",
    "[data-ad-slot]",
    "[data-ad-unit]",
    "[data-advertisement]",
    "[data-google-query-id]",
    "[id^='google_ads']",
    "[id^='div-gpt-ad']",
    "[id^='ad-slot']",
    "[id^='ad_slot']",
    "[id*='taboola']",
    "[id*='outbrain']",
    "[class~='ad']",
    "[class~='ads']",
    "[class~='advert']",
    "[class~='advertisement']",
    "[class~='adsbygoogle']",
    "[class~='sponsored']",
    "[class~='sponsor']",
    "[class*='ad-slot']",
    "[class*='ad-container']",
    "[class*='ad-wrapper']",
    "[class*='ad-banner']",
    "[class*='ad-unit']",
    "[class*='ad-placement']",
    "[class*='ad-zone']",
    "[class*='advertisement']",
    "[class*='sponsored']",
    "[class*='sponsor-']",
    "[class*='google-ad']",
    "[class*='gpt-ad']",
    "[class*='dfp-ad']",
    "[id*='ad-slot']",
    "[id*='ad-container']",
    "[id*='ad-banner']",
    "[id*='google_ads']",
    "[id*='div-gpt-ad']",
    "[aria-label='Advertisement']",
    "[aria-label='Advertisements']",
) + tuple(
    "%s[src*='//%s']" % (tag, host)
    for host in BASELINE_AD_HOSTS
    for tag in ("iframe", "img")
)


def is_ad_host(host):
    """True when ``host`` is one of the baseline ad hosts or a subdomain."""
    host = (host or "").strip().strip(".").lower()
    if not host:
        return False
    return any(host == name or host.endswith("." + name)
               for name in BASELINE_AD_HOSTS)


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
# Qt WebEngine, loaded without making ``--help`` depend on a display
# --------------------------------------------------------------------------
# PySide6 is imported here so the module's own helpers can be tested on a
# machine without Qt. The GUI entry point refuses cleanly when the import
# failed; nothing in this module falls back to GTK.
_QT_ERROR = None
try:  # pragma: no cover - the import result depends on the installed packages
    from PySide6.QtCore import (
        QFile,
        QIODevice,
        QObject,
        QStandardPaths,
        QTimer,
        QUrl,
        Qt,
        Signal,
        Slot,
    )
    from PySide6.QtGui import (
        QDesktopServices,
        QIcon,
        QKeySequence,
        QShortcut,
    )
    from PySide6.QtWidgets import (
        QApplication,
        QButtonGroup,
        QDialog,
        QDialogButtonBox,
        QFileDialog,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QMainWindow,
        QMenu,
        QMessageBox,
        QProgressBar,
        QRadioButton,
        QScrollArea,
        QStatusBar,
        QTabWidget,
        QToolBar,
        QToolButton,
        QVBoxLayout,
        QWidget,
    )
    from PySide6.QtWebEngineCore import (
        QWebEngineDownloadRequest,
        QWebEnginePage,
        QWebEngineProfile,
        QWebEngineScript,
        QWebEngineSettings,
        QWebEngineUrlRequestInterceptor,
    )
    from PySide6.QtWebEngineWidgets import QWebEngineView
    try:
        from PySide6.QtWebEngineCore import QWebEnginePermission
    except Exception:
        QWebEnginePermission = None
    try:
        from PySide6.QtWebChannel import QWebChannel
    except Exception:
        QWebChannel = None
    # The window painter and the one certificate rule live in qt_shell; both
    # are toolkit code shared with the manager view, so they are imported
    # rather than copied. qt_shell imports no toolkit at module level.
    from .qt_shell import _accept_certificate, black_page, prepare_wayland_env
    _QT_OK = True
except Exception as _exc:  # pragma: no cover - only without PySide6/Qt WebEngine
    _QT_OK = False
    _QT_ERROR = _exc
    QApplication = QWebEnginePage = QWebEngineProfile = None
    QWebEngineScript = QWebEngineSettings = QWebEngineView = None
    QWebEngineUrlRequestInterceptor = QWebEngineDownloadRequest = None
    QWebEnginePermission = QWebChannel = None
    # Every name the module subclasses at import time has to exist even here, or
    # the import dies with a NameError and the clean "Qt is required" path is
    # unreachable (QLineEdit is AddressEntry's base).
    QLineEdit = object
    QObject = QWidget = QMainWindow = QTabWidget = object
    _accept_certificate = black_page = prepare_wayland_env = None

if _QT_OK:
    _ObjectBase = QObject
    _WidgetBase = QWidget
    _MainWindowBase = QMainWindow
    _PageBase = QWebEnginePage
    _ViewBase = QWebEngineView
    _InterceptorBase = QWebEngineUrlRequestInterceptor
else:  # pragma: no cover
    _ObjectBase = _WidgetBase = _MainWindowBase = object
    _PageBase = _ViewBase = _InterceptorBase = object


# --------------------------------------------------------------------------
# Small pure helpers (importable without Qt)
# --------------------------------------------------------------------------

def browser_data_dir():
    """The browse window's own data store, separate from the manager's."""
    base = os.environ.get("XDG_DATA_HOME")
    if not base:
        base = os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "jawnos", "browser")


def profile_store_dir():
    """The Qt profile's on-disk store: ``~/.config/jawnos/browse-webengine``."""
    return os.path.join(core.config_dir(), PROFILE_DIR_NAME)


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
    or a non-http scheme is refused; :func:`address_url` is what the address
    bar uses to turn a phrase into a search.
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


_SCHEME_RE = re.compile(r"^[a-z][a-z0-9+.-]*:", re.IGNORECASE)


def search_url(text):
    """A search URL for a phrase, or None when the text names a scheme.

    A phrase (spaces) or a bare word has no scheme, so it is a search. A
    mistyped scheme such as ``ftp://host`` is left alone: the browser refuses
    it instead of turning it into a query.
    """
    text = (text or "").strip()
    if not text:
        return None
    if "://" in text or _SCHEME_RE.match(text):
        return None
    return SEARCH_PREFIX + urllib.parse.quote_plus(text)


def address_url(text):
    """What the address bar means: an http(s) URL, or a search for a phrase."""
    return normalise_url(text) or search_url(text)


def manager_base(url):
    """``https://host:port`` from a manager URL, or None."""
    try:
        parts = urllib.parse.urlsplit(url or "")
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.netloc:
        return None
    return "%s://%s" % (parts.scheme, parts.netloc)


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
            if self._current and self._current["key"] == key:
                # A page-to-page move on the same site is the same visit. The
                # phone already keeps its span this way; closing on a URL
                # change is what split one site visit into an appointment per
                # page.
                self._current["url"] = url or ""
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
# The person's block list
# --------------------------------------------------------------------------

def _valid_selector(selector):
    """A selector fit to write into the block sheet, or ``""``.

    The list is injected as CSS text, so braces, semicolons, @rules and
    selector-list commas could smuggle extra rules. The picker never produces
    them; a forged message might try.
    """
    if not isinstance(selector, str):
        return ""
    selector = selector.strip()
    if not selector or len(selector) > MAX_SELECTOR_CHARS:
        return ""
    if any(ch in selector for ch in "{};@,\r\n\0"):
        return ""
    if "/*" in selector or "*/" in selector:
        return ""
    return selector


_DOMAIN_RE = re.compile(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")


class AdBlockStore:
    """The person's blocked-element list, one selector set per site.

    The key is the registrable domain, so a rule learned on
    ``www.tubitv.com`` also applies to ``tubitv.com``. Writes are atomic
    (a temp file then ``os.replace``): a crash never leaves a half-written
    list that the next start cannot read.
    """

    def __init__(self, path, logger=None):
        self.path = path
        self.log = logger or LOG
        self.enabled = True
        self._sites = {}
        self._lock = threading.Lock()
        self._load()

    def _load(self):
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except FileNotFoundError:
            return
        except (OSError, ValueError) as exc:
            self.log.warning("could not read the block list: %s", exc)
            return
        if not isinstance(data, dict):
            return
        self.enabled = data.get("enabled") is not False
        sites = data.get("sites")
        if not isinstance(sites, dict):
            return
        for domain, entry in sites.items():
            if not isinstance(domain, str) or not _DOMAIN_RE.match(domain):
                continue
            raw = entry.get("selectors") if isinstance(entry, dict) else entry
            if not isinstance(raw, list):
                continue
            selectors = []
            for item in raw:
                selector = _valid_selector(item)
                if selector and selector not in selectors:
                    selectors.append(selector)
                if len(selectors) >= MAX_SELECTORS_PER_SITE:
                    break
            if selectors:
                self._sites[domain] = selectors

    def _save_locked(self):
        data = {
            "version": ADBLOCK_VERSION,
            "enabled": bool(self.enabled),
            "sites": {
                domain: {"selectors": list(selectors)}
                for domain, selectors in self._sites.items() if selectors
            },
        }
        tmp = self.path + ".tmp"
        try:
            folder = os.path.dirname(self.path)
            if folder:
                os.makedirs(folder, exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(data, handle, ensure_ascii=False, indent=2,
                          sort_keys=True)
                handle.write("\n")
            os.replace(tmp, self.path)
        except OSError as exc:
            self.log.warning("could not save the block list: %s", exc)
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def set_enabled(self, enabled):
        with self._lock:
            self.enabled = bool(enabled)
            self._save_locked()

    def site_selectors(self, uri):
        """The person's selectors for the site that ``uri`` belongs to."""
        domain = registrable_domain(uri)
        if not domain:
            return []
        with self._lock:
            return list(self._sites.get(domain, []))

    def site_entries(self):
        """A copy of every site's selectors, for the injected sheet."""
        with self._lock:
            return {domain: list(selectors)
                    for domain, selectors in self._sites.items() if selectors}

    def add(self, uri, selector):
        """Add one selector; the site's new list, or ``None`` if refused."""
        selector = _valid_selector(selector)
        domain = registrable_domain(uri)
        if not selector or not domain:
            return None
        with self._lock:
            selectors = self._sites.setdefault(domain, [])
            if selector not in selectors:
                if len(selectors) >= MAX_SELECTORS_PER_SITE:
                    return None
                selectors.append(selector)
            self._save_locked()
            return list(selectors)

    def remove(self, uri, selector):
        """Remove one selector; the site's new list (possibly empty)."""
        domain = registrable_domain(uri)
        if not domain:
            return None
        with self._lock:
            selectors = self._sites.get(domain)
            if selectors is None:
                return []
            if selector in selectors:
                selectors.remove(selector)
            if not selectors:
                self._sites.pop(domain, None)
            self._save_locked()
            return list(selectors)

    def clear(self, uri):
        """Forget everything learned for the site."""
        domain = registrable_domain(uri)
        if not domain:
            return None
        with self._lock:
            self._sites.pop(domain, None)
            self._save_locked()
            return []


# --------------------------------------------------------------------------
# The in-page half: baseline sheet, per-site sheet and the bug picker
# --------------------------------------------------------------------------

_ADBLOCK_JS_TEMPLATE = r"""
(function () {
    if (window.__jawnosAdblock) { return; }
    var BASELINE = __JAWNOS_BASELINE__;
    var STYLE_ID = '__jawnos_adblock_style';
    var AD_NAME = /(^|[\s_-])(ad|ads|advert|advertisement|sponsor|sponsored|promo|promotion|banner)([\s_-]|$)/i;
    var site = [];
    var enabled = true;
    var armed = false;
    var overlay = null;
    var hovered = null;
    var savedOutline = null;
    var savedOffset = null;
    var savedCursor = null;

    function post(payload) {
        try {
            window.webkit.messageHandlers.jawnos_adblock.postMessage(
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

    function inDocument(selector) {
        try { return document.querySelectorAll(selector).length; }
        catch (e) { return 0; }
    }

    function selectorFor(el) {
        if (!el || el.nodeType !== 1) { return ''; }
        if (el === document.documentElement) { return 'html'; }
        if (el.id) {
            var byId = '#' + cssEscape(el.id);
            if (inDocument(byId) === 1) { return byId; }
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

    function stableClasses(el) {
        var out = [];
        var raw = (el.getAttribute('class') || '').split(/\s+/);
        for (var i = 0; i < raw.length && out.length < 3; i++) {
            var name = raw[i];
            if (!name || name.length > 40) { continue; }
            if (/^\d/.test(name)) { continue; }
            if (/(^|[-_])(css|sc|jsx|svelte)-?[a-z0-9]{4,}$/i.test(name)) {
                continue;
            }
            if (/[0-9a-f]{8,}/i.test(name)) { continue; }
            out.push(name);
        }
        return out;
    }

    function classSelector(el) {
        if (!el || el.nodeType !== 1) { return ''; }
        if (el === document.documentElement) { return 'html'; }
        var tag = el.tagName.toLowerCase();
        if (el.id) {
            var byId = '#' + cssEscape(el.id);
            if (inDocument(byId) === 1) { return byId; }
        }
        var names = stableClasses(el);
        // An ad-named class is meant to match every slot with that name, so a
        // multi-match selector is right here.
        for (var i = 0; i < names.length; i++) {
            if (!AD_NAME.test(names[i])) { continue; }
            var byTag = tag + '.' + cssEscape(names[i]);
            if (inDocument(byTag)) { return byTag; }
            var byClass = '.' + cssEscape(names[i]);
            if (inDocument(byClass)) { return byClass; }
        }
        if (names.length) {
            var combo = tag + '.' + names.map(cssEscape).join('.');
            if (inDocument(combo) === 1) { return combo; }
            for (var j = 0; j < names.length; j++) {
                var one = '.' + cssEscape(names[j]);
                if (inDocument(one) === 1) { return one; }
            }
        }
        return '';
    }

    function targetFor(el) {
        // The clicked thing is often a span inside a slot; walk up a little to
        // a container that names itself as an ad, so one tap removes the block.
        var node = el;
        for (var depth = 0; node && depth < 4; depth++) {
            if (node === document.body || node === document.documentElement) {
                break;
            }
            var name = (node.id || '') + ' ' +
                       (node.getAttribute('class') || '');
            if (AD_NAME.test(name)) { return node; }
            node = node.parentElement;
        }
        return el;
    }

    function styleNode() {
        var node = document.getElementById(STYLE_ID);
        if (!node) {
            node = document.createElement('style');
            node.id = STYLE_ID;
            node.type = 'text/css';
            var root = document.head || document.documentElement;
            if (!root) { return null; }
            root.appendChild(node);
        }
        return node;
    }

    function render() {
        var node = styleNode();
        if (!node) { return; }
        if (!enabled) { node.textContent = ''; return; }
        var list = BASELINE.concat(site);
        node.textContent = list.length ?
            list.join(',') + '{display:none !important;}' : '';
    }

    function apply(list) {
        site = Array.isArray(list) ? list.slice() : [];
        render();
    }

    function setEnabled(on) {
        enabled = !!on;
        render();
    }

    function add(selector) {
        if (!selector) { return; }
        if (site.indexOf(selector) === -1) { site.push(selector); }
        render();
    }

    function remove(selector) {
        var at = site.indexOf(selector);
        if (at !== -1) { site.splice(at, 1); }
        render();
    }

    function ensureOverlay() {
        if (overlay) { return overlay; }
        overlay = document.createElement('div');
        overlay.id = '__jawnos_bug_overlay';
        overlay.setAttribute('aria-hidden', 'true');
        overlay.style.cssText = 'position:fixed;top:0;right:0;bottom:0;' +
            'left:0;z-index:2147483647;background:transparent;' +
            'cursor:crosshair;margin:0;padding:0;border:0;';
        overlay.addEventListener('mousemove', onMove, true);
        overlay.addEventListener('click', onClick, true);
        overlay.addEventListener('wheel', onWheel, {passive: false});
        document.documentElement.appendChild(overlay);
        return overlay;
    }

    function underPoint(x, y) {
        var list = [];
        try { list = document.elementsFromPoint(x, y) || []; } catch (e) {}
        for (var i = 0; i < list.length; i++) {
            var el = list[i];
            if (el === overlay || el.id === STYLE_ID) { continue; }
            return el;
        }
        // Older WebKit has no elementsFromPoint; drop the overlay out of hit
        // testing for the one lookup.
        var was = null;
        try {
            if (overlay) {
                was = overlay.style.pointerEvents;
                overlay.style.pointerEvents = 'none';
            }
        } catch (e) {}
        var found = null;
        try { found = document.elementFromPoint(x, y); } catch (e) {}
        try {
            if (overlay) { overlay.style.pointerEvents = was || ''; }
        } catch (e) {}
        if (found && found.id === STYLE_ID) { return null; }
        return found;
    }

    function restore() {
        if (hovered && savedOutline !== null) {
            hovered.style.outline = savedOutline;
            hovered.style.outlineOffset = savedOffset;
        }
        hovered = null;
        savedOutline = null;
        savedOffset = null;
    }

    function highlight(el) {
        if (hovered === el) { return; }
        restore();
        if (!el || !el.style) { return; }
        hovered = el;
        savedOutline = el.style.outline;
        savedOffset = el.style.outlineOffset;
        el.style.outline = '2px solid #ffcc00';
        el.style.outlineOffset = '-2px';
    }

    function onMove(ev) {
        if (!armed) { return; }
        var el = underPoint(ev.clientX, ev.clientY);
        highlight(el ? targetFor(el) : null);
    }

    function onClick(ev) {
        if (!armed) { return; }
        ev.preventDefault();
        ev.stopPropagation();
        if (ev.stopImmediatePropagation) { ev.stopImmediatePropagation(); }
        var el = underPoint(ev.clientX, ev.clientY);
        if (!el || el.nodeType !== 1) { return; }
        var target = targetFor(el);
        var selector = classSelector(target) || selectorFor(target);
        if (!selector) { return; }
        add(selector);
        restore();
        post({action: 'block', selector: selector,
              url: location.href, title: document.title || ''});
    }

    function onWheel(ev) {
        // The overlay is above the page, so it must forward the wheel or the
        // person cannot scroll to the thing they want to block.
        try { window.scrollBy(ev.deltaX || 0, ev.deltaY || 0); } catch (e) {}
        ev.preventDefault();
    }

    function onKey(ev) {
        if (armed && ev.key === 'Escape') {
            ev.preventDefault();
            ev.stopPropagation();
            arm(false);
            post({action: 'exit'});
        }
    }

    function setCursor(on) {
        var root = document.documentElement;
        if (!root) { return; }
        if (on) {
            if (savedCursor === null) {
                savedCursor = root.style.cursor || '';
            }
            root.style.cursor = 'crosshair';
        } else if (savedCursor !== null) {
            root.style.cursor = savedCursor;
            savedCursor = null;
        }
    }

    function arm(on) {
        armed = !!on;
        if (armed) {
            ensureOverlay().style.display = 'block';
        } else {
            restore();
            if (overlay) { overlay.style.display = 'none'; }
        }
        setCursor(armed);
    }

    document.addEventListener('keydown', onKey, true);
    window.__jawnosAdblock = {
        apply: apply,
        add: add,
        remove: remove,
        setEnabled: setEnabled,
        arm: arm,
        armed: function () { return armed; },
        selectors: function () { return BASELINE.concat(site); }
    };
    try { render(); } catch (e) {}
})();
"""

_ADBLOCK_JS = _ADBLOCK_JS_TEMPLATE.replace(
    "__JAWNOS_BASELINE__", json.dumps(list(BASELINE_COSMETIC_SELECTORS)))


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
<p>Type an address or a phrase above to begin.</p></div></body></html>"""


def _error_html(uri, message):
    return errorpage.dark_page(message, uri, title="Can't open this page")


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
# Qt page-world plumbing
# --------------------------------------------------------------------------
# Qt injects qwebchannel.js's transport into the main world only. The page
# bridge therefore lives in the main world, and the ad-block picker -- which
# must not be visible to a page -- lives in the isolated UserWorld and reaches
# the bridge through a DOM event. Both directions are validated in Python.

_BROWSE_SHIM_JS = r"""
(function () {
  if (window.__jawnBrowseQtShim) { return; }
  window.__jawnBrowseQtShim = true;
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.__jawnBrowseQueue = [];
  window.__jawnBrowsePost = function (name, raw) {
    if (window.__jawnBrowseBridge) {
      try { window.__jawnBrowseBridge.postMessage(name, String(raw)); } catch (e) {}
    } else {
      window.__jawnBrowseQueue.push([name, String(raw)]);
    }
  };
  ['jawnos', 'jawnos_browse', 'jawnos_adblock', 'jawnos_measure']
    .forEach(function (name) {
      window.webkit.messageHandlers[name] = {
        postMessage: function (raw) { window.__jawnBrowsePost(name, raw); }
      };
    });
  document.addEventListener('__jawnos_adblock_message', function (ev) {
    try { window.__jawnBrowsePost('jawnos_adblock', String(ev.detail)); }
    catch (e) {}
  });
  if (typeof QWebChannel !== 'function' || !window.qt ||
      !window.qt.webChannelTransport) { return; }
  try {
    new QWebChannel(window.qt.webChannelTransport, function (channel) {
      window.__jawnBrowseBridge = channel.objects.jawnos;
      var queued = window.__jawnBrowseQueue || [];
      window.__jawnBrowseQueue = [];
      for (var i = 0; i < queued.length; i++) {
        try {
          window.__jawnBrowseBridge.postMessage(queued[i][0], queued[i][1]);
        } catch (e) {}
      }
    });
  } catch (e) {}
})();
"""

_USER_WORLD_SHIM_JS = r"""
(function () {
  if (window.__jawnAdblockShim) { return; }
  window.__jawnAdblockShim = true;
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.jawnos_adblock = {
    postMessage: function (raw) {
      try {
        document.dispatchEvent(new CustomEvent('__jawnos_adblock_message',
                                               { detail: String(raw) }));
      } catch (e) {}
    }
  };
})();
"""

_MEASURE_AUTO_JS = "window.__jawnosMeasureAuto = true;"


def _webchannel_js():
    """Qt's QWebChannel JavaScript, read from the resource the library ships."""
    if not _QT_OK:
        return ""
    handle = QFile(":/qtwebchannel/qwebchannel.js")
    if not handle.open(QIODevice.ReadOnly):
        return ""
    try:
        return bytes(handle.readAll()).decode("utf-8")
    finally:
        handle.close()


def grant_media_permissions(page):
    """Grant this page the microphone and camera; deny everything else.

    Qt 6.8 moved web permissions to ``QWebEnginePermission``; older bindings
    use ``QWebEnginePage.featurePermissionRequested``. Both are handled, and
    only capture features are granted -- geolocation, notifications and
    clipboard stay denied.
    """
    granted_names = ("MediaAudioCapture", "MediaVideoCapture",
                     "MediaAudioVideoCapture")
    enum = getattr(QWebEnginePermission, "PermissionType", None) \
        if QWebEnginePermission is not None else None
    if enum is not None and hasattr(page, "permissionRequested"):
        granted = {getattr(enum, name) for name in granted_names
                   if hasattr(enum, name)}

        def decide(permission):
            try:
                if permission.permissionType() in granted:
                    permission.grant()
                else:
                    permission.deny()
            except Exception:
                pass

        page.permissionRequested.connect(decide)
        return

    granted = set()
    for name in granted_names:
        value = getattr(QWebEnginePage.Feature, name, None)
        if value is not None:
            granted.add(value)

    def decide_legacy(origin, feature):
        policy = (QWebEnginePage.PermissionPolicy.PermissionGrantedByUser
                  if feature in granted else
                  QWebEnginePage.PermissionPolicy.PermissionDeniedByUser)
        page.setFeaturePermission(origin, feature, policy)

    page.featurePermissionRequested.connect(decide_legacy)


class _AdInterceptor(_InterceptorBase):
    """Block requests to the baseline ad hosts, third-party only.

    A request from a page on the same registrable domain as the ad host is
    left alone: a person who visits an ad host directly asked for it. The
    interceptor runs on Chromium's IO thread, so it reads the store's flag and
    nothing else.
    """

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self._store = store

    def interceptRequest(self, info):
        try:
            if not self._store.enabled:
                return
            host = (info.requestUrl().host() or "").strip(".").lower()
            if not is_ad_host(host):
                return
            first = (info.firstPartyUrl().host() or "").strip(".").lower()
            if first and (registrable_domain("https://" + first)
                          == registrable_domain("https://" + host)):
                return
            info.block(True)
        except Exception:
            pass


if _QT_OK:
    class _BridgeRelay(QObject):
        """One tab's page -> app channel (QWebChannel object ``jawnos``)."""

        def __init__(self, window, tab, parent=None):
            super().__init__(parent)
            self._window = window
            self._tab = tab

        @Slot(str, str)
        def postMessage(self, name, raw):
            self._window.on_bridge_message(name, raw, self._tab)

    class _Relay(QObject):
        """Carry a worker thread's result onto the GUI thread."""

        deliver = Signal(object)
else:  # pragma: no cover - only without PySide6
    _BridgeRelay = None
    _Relay = None


class BrowsePage(_PageBase):
    """A Chromium page bound to one tab: policy, bridge and window creation."""

    def __init__(self, profile, tab):
        super().__init__(profile, tab)
        self._tab = tab
        self.certificateError.connect(_accept_certificate)
        self._configure_settings()
        grant_media_permissions(self)
        self.loadStarted.connect(self._tab.on_load_started)
        self.loadProgress.connect(self._tab.on_load_progress)
        if hasattr(self, "loadingChanged"):
            self.loadingChanged.connect(self._tab.on_loading_changed)
        else:  # pragma: no cover - Qt older than 6.5
            self.loadFinished.connect(self._tab.on_load_finished)
        self.urlChanged.connect(self._tab.on_url_changed)
        self.titleChanged.connect(self._tab.on_title_changed)
        self.iconChanged.connect(self._tab.on_icon_changed)
        self.fullScreenRequested.connect(self._tab.on_fullscreen_request)
        if hasattr(self, "recentlyAudibleChanged"):
            self.recentlyAudibleChanged.connect(self._tab.on_audible)
        self._install_bridge()

    def _configure_settings(self):
        settings = self.settings()
        wanted = (
            ("JavascriptEnabled", True),
            # A page's window.open becomes a tab in this window (the tab is
            # the containment: we never create a top-level window for it).
            ("JavascriptCanOpenWindows", True),
            ("JavascriptCanAccessClipboard", False),
            ("JavascriptCanPaste", False),
            ("PlaybackRequiresUserGesture", False),
            ("FullScreenSupportEnabled", True),
            ("LocalStorageEnabled", True),
            ("PluginsEnabled", False),
            ("PdfViewerEnabled", True),
            ("WebGLEnabled", True),
            ("Accelerated2dCanvasEnabled", True),
            ("ScrollAnimatorEnabled", True),
            ("DnsPrefetchEnabled", True),
            # Qt's own error page would replace the house's explanation.
            ("ErrorPageEnabled", False),
            ("AllowWindowActivationFromJavaScript", False),
            ("HyperlinkAuditingEnabled", False),
        )
        for name, value in wanted:
            attr = getattr(QWebEngineSettings.WebAttribute, name, None)
            if attr is None:
                continue
            try:
                settings.setAttribute(attr, value)
            except Exception:
                pass

    def _install_bridge(self):
        if QWebChannel is None:
            LOG.warning("QtWebChannel is missing; the Browse bridge is inert")
            return
        channel = QWebChannel(self)
        handler = _BridgeRelay(self._tab.window, self._tab, self)
        channel.registerObject("jawnos", handler)
        self.setWebChannel(channel)
        self._jawn_channel = channel
        self._jawn_handler = handler

    def createWindow(self, _window_type):
        """A popup or ``target=_blank`` becomes a tab in this same window.

        Returning a page (rather than None or a new top-level view) makes Qt
        load the requested URL into the tab we just created.
        """
        tab = self._tab.window.new_tab(uri=None, placeholder=False, switch=True)
        return tab.page if tab is not None else None

    def acceptNavigationRequest(self, url, nav_type, is_main_frame):
        return self._tab.window.accept_navigation(
            self._tab, url, nav_type, is_main_frame)


class BrowseView(_ViewBase):
    """The view, with Escape left to the page unless the window needs it."""

    def __init__(self, window):
        super().__init__()
        self._window = window

    def keyPressEvent(self, event):
        if self._window.handle_escape():
            event.accept()
            return
        super().keyPressEvent(event)


class AddressEntry(QLineEdit):
    """The address bar; Escape behaves like the window's Escape."""

    def __init__(self, window):
        super().__init__()
        self._window = window

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape and self._window.handle_escape():
            event.accept()
            return
        super().keyPressEvent(event)


# --------------------------------------------------------------------------
# Widgets
# --------------------------------------------------------------------------

class BrowserTab(_WidgetBase):
    """One browser tab: a WebEngine view, its page, and its state."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.internal = False
        self.error_page = False
        self.page = BrowsePage(window.profile, self)
        self.view = BrowseView(window)
        self.view.setPage(self.page)
        black_page(self.page, self.view)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.view)

    # ---- loading ---------------------------------------------------------

    def load_uri(self, uri):
        self.internal = False
        self.error_page = False
        self.view.setUrl(QUrl(uri))

    def show_placeholder(self):
        self.internal = True
        self.error_page = False
        self.view.setHtml(_new_tab_html())

    def show_error(self, uri, message):
        self.internal = True
        self.error_page = True
        # No base URL: the error page keeps about:blank, so internal/error
        # state cannot be mistaken for a real navigation, exactly as the
        # WebKit window's load_html(html, None) behaved. The Try again link
        # in the page is absolute.
        self.view.setHtml(_error_html(uri, message))

    def current_title(self):
        try:
            title = self.page.title() or ""
        except Exception:
            title = ""
        if title:
            return title
        try:
            uri = self.page.url().toString()
        except Exception:
            uri = ""
        host = urllib.parse.urlsplit(uri).hostname or ""
        return host or "New tab"

    def update_label(self):
        title = self.current_title()
        self.window.set_tab_label(self, title)

    # ---- page signals ----------------------------------------------------

    def on_load_started(self):
        self.window.on_load_started(self)

    def on_load_progress(self, percent):
        self.window.on_load_progress(self, percent)

    def on_loading_changed(self, info):
        try:
            status = info.status()
        except Exception:
            return
        names = QWebEngineLoadingInfoLoadStatus
        if status == names.get("started"):
            self.on_load_started()
        elif status == names.get("succeeded"):
            self.window.on_load_succeeded(self)
        elif status == names.get("failed"):
            self.window.on_load_failed(
                self, info.url().toString(),
                info.errorString() or "The page could not be loaded.")
        elif status == names.get("stopped"):
            self.window.on_load_stopped(self)

    def on_load_finished(self, ok):  # pragma: no cover - Qt older than 6.5
        if ok:
            self.window.on_load_succeeded(self)
        else:
            self.window.on_load_failed(
                self, self.page.url().toString(),
                "The page could not be loaded.")

    def on_url_changed(self, url):
        uri = url.toString()
        if uri and not uri.startswith(("about:", "data:")):
            self.internal = False
            self.error_page = False
        self.window.on_url_changed(self)

    def on_title_changed(self, _title):
        if not self.internal:
            self.update_label()
        self.window.on_title_changed(self)

    def on_icon_changed(self, icon):
        self.window.on_icon_changed(self, icon)

    def on_fullscreen_request(self, request):
        self.window.on_fullscreen_request(request)

    def on_audible(self, on):
        self.window.set_engine_audio(self, bool(on))


# Map the Qt 6.5+ loading status enum by name once, so a binding that renames
# the members still works (the numeric ordering is documented as stable, but
# the names are easier to read and check).
if _QT_OK:
    try:
        from PySide6.QtWebEngineCore import QWebEngineLoadingInfo

        _status = QWebEngineLoadingInfo.LoadStatus
        QWebEngineLoadingInfoLoadStatus = {
            "started": _status.LoadStartedStatus,
            "succeeded": _status.LoadSucceededStatus,
            "failed": _status.LoadFailedStatus,
            "stopped": _status.LoadStoppedStatus,
        }
    except Exception:  # pragma: no cover - Qt older than 6.5
        QWebEngineLoadingInfoLoadStatus = {}
else:  # pragma: no cover
    QWebEngineLoadingInfoLoadStatus = {}


class BrowserWindow(_MainWindowBase):
    """The native browse window."""

    def __init__(self, args, check=False):
        super().__init__()
        self.setWindowTitle("JawnOS Browse")
        self.resize(1200, 850)
        self.args = args
        self.check_mode = check
        self.mode = "measure" if args.mode == "measure" else "browse"
        self.app = (args.app or "")[:200]
        self.uuid = (args.uuid or "")[:200]
        self.manager = args.manager or ""
        self._closing = False
        self._downloads = set()
        self._bug_tab = None
        self._chrome_before_page_fullscreen = None
        self._media = {}
        self._engine_audio = {}

        self.data_dir = browser_data_dir()
        try:
            os.makedirs(self.data_dir, exist_ok=True)
        except OSError as exc:
            LOG.warning("could not create the browse data directory: %s", exc)
        self.history = History(os.path.join(self.data_dir, "history.jsonl"))
        self.adblock = AdBlockStore(
            os.path.join(self.data_dir, ADBLOCK_FILE), logger=LOG)
        self.client = BrowseClient(manager=self.manager, logger=LOG)
        self.usage = SiteUsage(self.client, logger=LOG)

        self._inhibitor = keepawake.ScreensaverInhibitor()

        self.profile = self._build_profile()
        self._install_profile_scripts()
        self._build_ui()

        self._relay = _Relay(self)
        self._relay.deliver.connect(self._deliver)

        self._flush_timer = QTimer(self)
        self._flush_timer.setInterval(FLUSH_SECONDS * 1000)
        self._flush_timer.timeout.connect(self._on_flush_timer)
        self._flush_timer.start()

        app = QApplication.instance()
        if app is not None:
            try:
                app.applicationStateChanged.connect(self._on_app_state)
            except Exception:
                pass

        uri = None
        if not check:
            uri = normalise_url(args.url)
        tab = self.new_tab(uri=uri, placeholder=uri is None and not check,
                           switch=True)
        if not check:
            if uri is None and (args.url or "").strip():
                self._set_status("Enter an http or https address.")
            if tab is not None and uri is None:
                self.url_entry.setFocus()
        QTimer.singleShot(0, self._sync_site)

    # ---- construction ----------------------------------------------------

    def _build_profile(self):
        store = profile_store_dir()
        try:
            os.makedirs(os.path.join(store, "storage"), exist_ok=True)
            os.makedirs(os.path.join(store, "cache"), exist_ok=True)
        except OSError as exc:
            LOG.warning("could not create the browse profile directory: %s", exc)
        profile = QWebEngineProfile(PROFILE_NAME, self)
        profile.setPersistentStoragePath(os.path.join(store, "storage"))
        profile.setCachePath(os.path.join(store, "cache"))
        profile.setPersistentCookiesPolicy(
            QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
        try:
            profile.setHttpCacheType(
                QWebEngineProfile.HttpCacheType.DiskHttpCache)
        except Exception:
            pass
        self._interceptor = _AdInterceptor(self.adblock, profile)
        try:
            profile.setUrlRequestInterceptor(self._interceptor)
        except Exception:
            LOG.exception("could not install the ad-request interceptor")
        try:
            profile.downloadRequested.connect(self.on_download_requested)
        except Exception:
            LOG.exception("could not watch for downloads")
        return profile

    def _profile_script(self, source, name, point, world=None):
        script = QWebEngineScript()
        script.setName(name)
        script.setSourceCode(source)
        try:
            script.setInjectionPoint(point)
            if world is not None:
                script.setWorldId(world)
        except Exception:
            script.setInjectionPoint(QWebEngineScript.InjectionPoint.DocumentReady)
        script.setRunsOnSubFrames(False)
        self.profile.scripts().insert(script)

    def _install_profile_scripts(self):
        creation = QWebEngineScript.InjectionPoint.DocumentCreation
        ready = QWebEngineScript.InjectionPoint.DocumentReady
        main = QWebEngineScript.ScriptWorldId.MainWorld
        user = QWebEngineScript.ScriptWorldId.UserWorld

        source = ""
        channel_js = _webchannel_js()
        if channel_js:
            source += channel_js + "\n"
        source += _BROWSE_SHIM_JS + "\n" + bridge.BROWSE_BRIDGE_JS
        self._profile_script(source, "jawnos-browse-bridge", creation, main)
        self._profile_script(bridge.MEDIA_MONITOR_JS,
                             "jawnos-browse-media", ready, main)

        # The picker API is isolated from the page (UserWorld). Its messages
        # cross to the main world as a DOM event, which the bridge forwards.
        self._profile_script(_USER_WORLD_SHIM_JS + "\n" + _ADBLOCK_JS,
                             "jawnos-browse-adblock", ready, user)

        if self.mode == "measure":
            self._profile_script(_MEASURE_AUTO_JS, "jawnos-browse-measure-flag",
                                 creation, main)
            self._profile_script(_PICKER_JS, "jawnos-browse-picker", ready,
                                 main)

    def _build_ui(self):
        self.toolbar = QToolBar("Browse", self)
        self.toolbar.setMovable(False)
        self.toolbar.setFloatable(False)
        self.addToolBar(Qt.ToolBarArea.TopToolBarArea, self.toolbar)

        self.back_button = self._tool_button(
            "go-previous", "Back", "Back", self.go_back)
        self.forward_button = self._tool_button(
            "go-next", "Forward", "Forward", self.go_forward)
        self.reload_button = self._tool_button(
            "view-refresh", "Reload", "Reload", self.reload_or_stop)
        self.home_button = self._tool_button(
            "go-home", "Home", "Home", self.go_home)
        for button in (self.back_button, self.forward_button,
                       self.reload_button, self.home_button):
            self.toolbar.addWidget(button)

        self.url_entry = AddressEntry(self)
        self.url_entry.setPlaceholderText("Enter an address or search")
        self.url_entry.setClearButtonEnabled(True)
        self.url_entry.returnPressed.connect(self.on_url_activate)
        self.toolbar.addWidget(self.url_entry)

        self.new_tab_button = self._tool_button(
            "tab-new", "+", "New tab", lambda: self.new_tab())
        self.find_button = self._tool_button(
            "edit-find", "Find", "Find in page (Ctrl+F)", self.open_find)
        self.history_button = QToolButton()
        self.history_button.setToolTip("History")
        self.history_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        icon = QIcon.fromTheme("document-open-recent")
        if not icon.isNull():
            self.history_button.setIcon(icon)
        else:
            self.history_button.setText("History")
        self.history_menu = QMenu(self)
        self.history_menu.aboutToShow.connect(self.reload_history_menu)
        self.history_button.setMenu(self.history_menu)
        for button in (self.new_tab_button, self.find_button):
            self.toolbar.addWidget(button)
        self.toolbar.addWidget(self.history_button)

        self.find_bar = self._build_find_bar()

        self.tabs = QTabWidget()
        self.tabs.setTabsClosable(True)
        self.tabs.setMovable(True)
        self.tabs.setDocumentMode(True)
        self.tabs.currentChanged.connect(self.on_switch_page)
        self.tabs.tabCloseRequested.connect(self.on_tab_close_requested)

        # The bug controls sit at the end of the tab row, where the person is
        # already looking when a page misbehaves.
        self.bug_button = QToolButton()
        self.bug_button.setCheckable(True)
        self.bug_button.setToolTip("Block page elements (bug mode)")
        bug_icon = QIcon(os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "icons", "jawnos-bug.svg"))
        if not bug_icon.isNull():
            self.bug_button.setIcon(bug_icon)
        else:
            self.bug_button.setText("Bug")
        self.bug_button.toggled.connect(self.on_bug_toggled)

        self.block_list_button = QToolButton()
        self.block_list_button.setToolTip("Blocked elements on this site")
        self.block_list_button.setPopupMode(
            QToolButton.ToolButtonPopupMode.InstantPopup)
        list_icon = QIcon.fromTheme("view-list")
        if not list_icon.isNull():
            self.block_list_button.setIcon(list_icon)
        else:
            self.block_list_button.setText("Blocked")
        self.block_list_menu = QMenu(self)
        self.block_list_menu.aboutToShow.connect(self.reload_block_list)
        self.block_list_button.setMenu(self.block_list_menu)

        tab_actions = QWidget()
        tab_actions_layout = QHBoxLayout(tab_actions)
        tab_actions_layout.setContentsMargins(0, 0, 0, 0)
        tab_actions_layout.setSpacing(2)
        tab_actions_layout.addWidget(self.bug_button)
        tab_actions_layout.addWidget(self.block_list_button)
        self.tabs.setCornerWidget(tab_actions, Qt.Corner.TopRightCorner)
        tab_actions.setVisible(self.mode != "measure")

        central = QWidget()
        layout = QVBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(self.find_bar)
        layout.addWidget(self.tabs)
        self.setCentralWidget(central)

        status = QStatusBar(self)
        self.status_label = QLabel("")
        self.progress_bar = QProgressBar()
        self.progress_bar.setMaximumWidth(170)
        self.progress_bar.setVisible(False)
        status.addWidget(self.status_label, 1)
        status.addPermanentWidget(self.progress_bar)
        self.setStatusBar(status)

        self._install_shortcuts()

    def _tool_button(self, icon_name, fallback, tooltip, callback):
        button = QToolButton()
        button.setToolTip(tooltip)
        button.setAutoRaise(True)
        icon = QIcon.fromTheme(icon_name)
        if not icon.isNull():
            button.setIcon(icon)
        else:
            button.setText(fallback)
        button.clicked.connect(lambda *_: callback())
        return button

    def _build_find_bar(self):
        bar = QWidget()
        layout = QHBoxLayout(bar)
        layout.setContentsMargins(4, 4, 4, 4)
        layout.setSpacing(6)
        self.find_entry = QLineEdit()
        self.find_entry.setPlaceholderText("Find in page")
        self.find_entry.setClearButtonEnabled(True)
        self.find_entry.textChanged.connect(self.on_find_changed)
        self.find_entry.returnPressed.connect(self.find_next)
        layout.addWidget(self.find_entry, 1)
        layout.addWidget(self._tool_button(
            "go-up", "Previous", "Previous match", self.find_previous))
        layout.addWidget(self._tool_button(
            "go-down", "Next", "Next match", self.find_next))
        layout.addWidget(self._tool_button(
            "window-close", "Close", "Close find", self.close_find))
        bar.setVisible(False)
        return bar

    def _install_shortcuts(self):
        pairs = (
            ("Ctrl+L", self.focus_address),
            ("Ctrl+T", lambda: self.new_tab()),
            ("Ctrl+W", self.close_current_tab),
            ("Ctrl+F", self.open_find),
            ("Ctrl+G", self.find_next),
            ("Ctrl+Shift+G", self.find_previous),
            ("F5", self.reload_or_stop),
            ("Ctrl+R", self.reload_or_stop),
            ("Alt+Left", self.go_back),
            ("Alt+Right", self.go_forward),
            ("Alt+Home", self.go_home),
        )
        for sequence, callback in pairs:
            shortcut = QShortcut(QKeySequence(sequence), self)
            shortcut.setContext(Qt.ShortcutContext.WindowShortcut)
            shortcut.activated.connect(lambda cb=callback: cb())

    # ---- blocking --------------------------------------------------------

    def on_bug_toggled(self, checked):
        if checked and not self.adblock.enabled:
            self.bug_button.setChecked(False)
            self._set_status("Turn ad blocking on first.")
            return
        if checked:
            self._bug_tab = self.current_tab()
            self._apply_adblock(self._bug_tab)
            self._arm_bug_picker(self._bug_tab, True)
            self._set_status(
                "Bug mode: tap what you do not want to see. Esc to stop.")
        else:
            self._arm_bug_picker(self._bug_tab or self.current_tab(), False)
            self._bug_tab = None
            self._set_status("")

    def _arm_bug_picker(self, tab, on):
        if not isinstance(tab, BrowserTab):
            return
        script = ("window.__jawnosAdblock && window.__jawnosAdblock.arm(%s);"
                  % ("true" if on else "false"))
        self._run_in_user_world(tab.page, script)

    def _apply_adblock(self, tab):
        """Push the site's saved selectors and the on/off state into a tab."""
        if not isinstance(tab, BrowserTab):
            return
        uri = self._tab_uri(tab)
        selectors = self.adblock.site_selectors(uri) if uri else []
        script = (
            "(function(){var a=window.__jawnosAdblock;if(!a){return;}"
            "a.setEnabled(%s);a.apply(%s);})()"
            % ("true" if self.adblock.enabled else "false",
               json.dumps(selectors, ensure_ascii=True)))
        self._run_in_user_world(tab.page, script)

    def _run_in_user_world(self, page, script):
        try:
            page.runJavaScript(
                script, QWebEngineScript.ScriptWorldId.UserWorld)
        except TypeError:  # pragma: no cover - Qt without a world argument
            try:
                page.runJavaScript(script)
            except Exception:
                pass
        except Exception:
            pass

    def on_adblock_message(self, raw, tab):
        if not raw or len(raw) > 4096:
            return
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            return
        if not isinstance(payload, dict) or self.mode != "browse":
            return
        action = payload.get("action")
        if action == "exit":
            if self.bug_button.isChecked():
                self.bug_button.setChecked(False)
            return
        if action != "block" or not self.bug_button.isChecked():
            return
        selector = _valid_selector(payload.get("selector"))
        if not selector:
            return
        if tab is None:
            tab = self.current_tab()
        if tab is None:
            return
        uri = self._tab_uri(tab)
        if not uri.startswith(("http://", "https://")):
            return
        # Key on the page's own URI, never on the message's ``url``: a page
        # can lie in the payload, and the handler writes a persistent list.
        selectors = self.adblock.add(uri, selector)
        if selectors is None:
            self._set_status("That element could not be blocked.")
            return
        self._set_status("Blocked %d element%s on %s." % (
            len(selectors), "" if len(selectors) == 1 else "s",
            registrable_domain(uri)))

    def on_block_remove(self, selector):
        tab = self.current_tab()
        uri = self._tab_uri(tab)
        if not uri:
            return
        selectors = self.adblock.remove(uri, selector)
        if selectors is None:
            return
        self._apply_adblock(tab)
        self.reload_block_list()
        self._set_status("No longer blocking that element.")

    def on_block_clear(self):
        tab = self.current_tab()
        uri = self._tab_uri(tab)
        if not uri:
            return
        selectors = self.adblock.clear(uri)
        if selectors is None:
            return
        self._apply_adblock(tab)
        self.reload_block_list()
        self._set_status("Cleared this site's blocked elements.")

    def on_block_enabled(self, enabled):
        enabled = bool(enabled)
        if enabled == self.adblock.enabled:
            return
        self.adblock.set_enabled(enabled)
        for index in range(self.tabs.count()):
            tab = self.tabs.widget(index)
            if isinstance(tab, BrowserTab):
                self._apply_adblock(tab)
        if not enabled and self.bug_button.isChecked():
            self.bug_button.setChecked(False)
        self._set_status("Ad blocking on." if enabled else "Ad blocking off.")

    def reload_block_list(self):
        menu = self.block_list_menu
        menu.clear()
        enabling = menu.addAction("Block ads")
        enabling.setCheckable(True)
        enabling.blockSignals(True)
        enabling.setChecked(self.adblock.enabled)
        enabling.blockSignals(False)
        enabling.toggled.connect(self.on_block_enabled)
        menu.addSeparator()

        tab = self.current_tab()
        uri = self._tab_uri(tab)
        domain = registrable_domain(uri) if uri else ""
        heading = menu.addAction(domain or "No site open")
        heading.setEnabled(False)
        selectors = self.adblock.site_selectors(uri) if domain else []
        if not selectors:
            empty = menu.addAction(
                "Nothing blocked on this site yet. Turn on bug mode, then tap "
                "what you do not want to see.")
            empty.setEnabled(False)
            return
        for selector in selectors:
            action = menu.addAction("Stop blocking %s" % selector)
            action.setToolTip(selector)
            action.triggered.connect(
                lambda *_a, s=selector: self.on_block_remove(s))
        menu.addSeparator()
        clear = menu.addAction("Clear this site")
        clear.triggered.connect(lambda *_: self.on_block_clear())

    # ---- tabs ------------------------------------------------------------

    def current_tab(self):
        widget = self.tabs.currentWidget()
        return widget if isinstance(widget, BrowserTab) else None

    def _tab_index(self, tab):
        return self.tabs.indexOf(tab)

    def new_tab(self, uri=None, placeholder=True, switch=True):
        tab = BrowserTab(self)
        index = self.tabs.addTab(tab, "New tab")
        self.tabs.setTabToolTip(index, "New tab")
        if switch:
            self.tabs.setCurrentIndex(index)
        if uri:
            self._navigate(uri, tab)
        elif placeholder:
            tab.show_placeholder()
        if switch and not self.check_mode and placeholder and not uri:
            self.url_entry.setFocus()
        self._sync_toolbar()
        self._update_url_bar(tab, force=True)
        return tab

    def close_tab(self, tab):
        if self._closing:
            return
        index = self._tab_index(tab)
        if index < 0:
            return
        if self.tabs.count() <= 1:
            self.close()
            return
        try:
            tab.view.stop()
        except Exception:
            pass
        self._media.pop(id(tab), None)
        self._engine_audio.pop(id(tab), None)
        self.tabs.removeTab(index)
        if self._bug_tab is tab:
            self._bug_tab = None
        tab.deleteLater()
        self._reconcile_media()
        self._sync_site()
        self._sync_toolbar()

    def on_tab_close_requested(self, index):
        tab = self.tabs.widget(index)
        if isinstance(tab, BrowserTab):
            self.close_tab(tab)

    def close_current_tab(self):
        tab = self.current_tab()
        if tab is not None:
            self.close_tab(tab)

    def set_tab_label(self, tab, title):
        index = self._tab_index(tab)
        if index < 0:
            return
        self.tabs.setTabText(index, (title or "New tab")[:60])
        self.tabs.setTabToolTip(index, title or "")

    def on_icon_changed(self, tab, icon):
        index = self._tab_index(tab)
        if index >= 0 and icon is not None and not icon.isNull():
            self.tabs.setTabIcon(index, icon)

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

    def accept_navigation(self, tab, url, nav_type, is_main_frame):
        """Policy for every navigation request the engine asks about."""
        uri = url.toString()
        scheme = (url.scheme() or "").lower()
        if not uri or uri == "about:blank":
            return True
        if scheme in ("http", "https"):
            if blocked_host(uri) and not allow_private():
                if is_main_frame:
                    tab.show_error(
                        uri,
                        "Browse will not open this address because it is on a "
                        "private network (loopback, link-local, or another "
                        "local range).")
                self._set_status("Blocked a private-network address.")
                return False
            return True
        if scheme in ("about", "data", "blob"):
            return True
        if scheme == "file":
            self._set_status("Browse does not open local files.")
            return False
        if scheme in EXTERNAL_SCHEMES \
                and nav_type == QWebEnginePage.NavigationType.NavigationTypeLinkClicked:
            self._launch_external(uri)
            return False
        self._set_status("Browse does not open this kind of link.")
        return False

    def on_url_activate(self):
        uri = address_url(self.url_entry.text())
        if not uri:
            self._set_status("Enter an address like example.com.")
            return
        self._navigate(uri)

    def focus_address(self):
        self.url_entry.setFocus()
        self.url_entry.selectAll()

    def go_back(self):
        tab = self.current_tab()
        if tab is None:
            return
        history = tab.page.history()
        if history.canGoBack():
            history.back()

    def go_forward(self):
        tab = self.current_tab()
        if tab is None:
            return
        history = tab.page.history()
        if history.canGoForward():
            history.forward()

    def reload_or_stop(self):
        tab = self.current_tab()
        if tab is None:
            return
        if tab.page.isLoading():
            tab.view.stop()
        else:
            tab.view.reload()

    def go_home(self):
        tab = self.current_tab()
        if tab is None:
            tab = self.new_tab()
        if tab is not None:
            tab.show_placeholder()
            self._update_url_bar(tab, force=True)
            self.url_entry.setFocus()

    def _sync_toolbar(self):
        tab = self.current_tab()
        if tab is None:
            self.back_button.setEnabled(False)
            self.forward_button.setEnabled(False)
            self._set_loading(False)
            if getattr(self, "bug_button", None):
                self.bug_button.setEnabled(False)
                self.block_list_button.setEnabled(False)
            return
        history = tab.page.history()
        self.back_button.setEnabled(history.canGoBack())
        self.forward_button.setEnabled(history.canGoForward())
        self._set_loading(tab.page.isLoading())
        if getattr(self, "bug_button", None):
            self.bug_button.setEnabled(True)
            self.block_list_button.setEnabled(True)
        self._update_url_bar(tab)

    def _set_loading(self, loading):
        icon = QIcon.fromTheme("process-stop" if loading else "view-refresh")
        if icon.isNull():
            self.reload_button.setIcon(QIcon())
            self.reload_button.setText("Stop" if loading else "Reload")
        else:
            self.reload_button.setIcon(icon)
            self.reload_button.setText("")
        self.reload_button.setToolTip("Stop" if loading else "Reload")

    def _update_url_bar(self, tab, force=False):
        if tab is None:
            return
        uri = self._tab_uri(tab)
        if tab.internal and (not uri or uri.startswith(("about:", "data:"))):
            text = ""
        else:
            text = uri
        if force or not self.url_entry.hasFocus():
            self.url_entry.setText(text)
            self.url_entry.setCursorPosition(len(text))

    def _tab_uri(self, tab):
        if not isinstance(tab, BrowserTab):
            return ""
        try:
            return tab.page.url().toString() or ""
        except Exception:
            return ""

    def _sync_site(self):
        if self._closing:
            return
        tab = self.current_tab()
        try:
            active = bool(self.isActiveWindow())
        except Exception:
            active = False
        if not active or tab is None:
            self.usage.idle()
            return
        uri = self._tab_uri(tab)
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
            title = tab.page.title() or ""
        except Exception:
            title = ""
        self.usage.visit(key, uri, title)

    # ---- page signals ----------------------------------------------------

    def on_load_started(self, tab):
        if tab is self.current_tab():
            self._set_loading(True)
            self._sync_toolbar()

    def on_load_progress(self, tab, percent):
        if tab is not self.current_tab():
            return
        if 0 <= percent < 100:
            self.progress_bar.setValue(int(percent))
            self.progress_bar.setVisible(True)
        else:
            self.progress_bar.setVisible(False)

    def on_load_succeeded(self, tab):
        tab.update_label()
        self._apply_adblock(tab)
        if tab is self.current_tab() and not tab.internal \
                and self.bug_button.isChecked():
            self._arm_bug_picker(tab, True)
        if tab is self.current_tab():
            self.setWindowTitle("%s — JawnOS Browse" % tab.current_title())
            self._sync_toolbar()
            self._set_status("")
            self._sync_site()
            self.progress_bar.setVisible(False)
        uri = self._tab_uri(tab)
        if not tab.internal and not tab.error_page \
                and uri.startswith(("http://", "https://")):
            try:
                title = tab.page.title() or ""
            except Exception:
                title = ""
            self.history.add(uri, title)
        # A measure window re-arms itself through the injected start script,
        # but the first about:blank page never gets the flag. Arm only a real
        # page that finished loading.
        if self.mode == "measure" and tab is self.current_tab() \
                and not tab.internal \
                and uri.startswith(("http://", "https://")):
            self._arm_picker()

    def on_load_failed(self, tab, failing_uri, message):
        if failing_uri.startswith(("about:", "data:")):
            return
        if blocked_host(failing_uri) and not allow_private():
            message = ("Browse will not open this address because it is on a "
                       "private network (loopback, link-local, or another "
                       "local range).")
        tab.show_error(failing_uri, message)
        if tab is self.current_tab():
            self._set_status(message)
            self.progress_bar.setVisible(False)
            self._sync_toolbar()
        self._sync_site()

    def on_load_stopped(self, tab):
        if tab is self.current_tab():
            self._set_loading(False)
            self.progress_bar.setVisible(False)
            self._sync_toolbar()

    def on_url_changed(self, tab):
        if tab is self.current_tab():
            self._update_url_bar(tab)
            self._sync_toolbar()
            self._sync_site()
        if not tab.internal:
            tab.update_label()

    def on_title_changed(self, tab):
        if tab is self.current_tab():
            self.setWindowTitle("%s — JawnOS Browse" % tab.current_title())
            self._sync_site()

    def on_switch_page(self, _index):
        tab = self.current_tab()
        if tab is None:
            return
        if getattr(self, "bug_button", None) and self.bug_button.isChecked():
            self._apply_adblock(tab)
            if not tab.internal:
                self._arm_bug_picker(tab, True)
            self._bug_tab = tab
        self._update_url_bar(tab, force=True)
        self._sync_toolbar()
        self.setWindowTitle("%s — JawnOS Browse" % tab.current_title())
        self._sync_site()
        if self.find_bar.isVisible():
            self.on_find_changed(self.find_entry.text())

    # ---- history ---------------------------------------------------------

    def on_history_row(self, uri):
        if uri:
            self._navigate(uri)

    def reload_history_menu(self):
        menu = self.history_menu
        menu.clear()
        entries = self.history.recent(100)
        if not entries:
            empty = menu.addAction("No history yet")
            empty.setEnabled(False)
            return
        for entry in entries:
            title = entry.get("title") or entry.get("url") or ""
            url = entry.get("url") or ""
            action = menu.addAction(
                "%s — %s" % (title[:70], url[:90]))
            action.setToolTip(url)
            action.triggered.connect(
                lambda *_a, u=url: self.on_history_row(u))

    # ---- find ------------------------------------------------------------

    def _find(self, text, backwards=False):
        tab = self.current_tab()
        if tab is None:
            return
        flags = QWebEnginePage.FindFlag(0)
        if backwards:
            flags |= QWebEnginePage.FindFlag.FindBackward
        try:
            tab.page.findText(text or "", flags)
        except Exception:
            pass

    def on_find_changed(self, text):
        self._find(text)

    def on_find_next(self):
        self._find(self.find_entry.text())

    def find_next(self):
        self._find(self.find_entry.text())

    def find_previous(self):
        self._find(self.find_entry.text(), backwards=True)

    def open_find(self):
        self.find_bar.setVisible(True)
        self.find_entry.setFocus()
        self.find_entry.selectAll()

    def close_find(self):
        self.find_bar.setVisible(False)
        self.find_entry.setText("")
        self._find("")

    # ---- keyboard --------------------------------------------------------

    def handle_escape(self):
        """The behaviour the GTK window gave Escape, or False to pass it on."""
        if getattr(self, "bug_button", None) and self.bug_button.isChecked():
            self.bug_button.setChecked(False)
            return True
        if self.find_bar.isVisible():
            self.close_find()
            return True
        tab = self.current_tab()
        if tab is not None and tab.page.isLoading():
            tab.view.stop()
            return True
        return False

    # ---- fullscreen ------------------------------------------------------

    def on_fullscreen_request(self, request):
        try:
            on = bool(request.toggleOn())
            request.accept()
        except Exception:
            return
        self._set_fullscreen_chrome(on)

    def _set_fullscreen_chrome(self, on):
        """Take the window's own bars out of a page's fullscreen.

        A video that asks for fullscreen must fill the screen: the tool bar,
        the tab strip and the status line are exactly the bars a person sees at
        the top and bottom of the picture. Restoring puts back the tab strip
        and a find bar that was open, not a new one.
        """
        try:
            if on:
                self._chrome_before_page_fullscreen = (
                    self.toolbar.isVisible(),
                    self.tabs.tabBar().isVisible(),
                    self.find_bar.isVisible(),
                )
                self.toolbar.setVisible(False)
                self.tabs.tabBar().setVisible(False)
                self.statusBar().setVisible(False)
                self.find_bar.setVisible(False)
                self.showFullScreen()
            else:
                show_toolbar, show_tabs, find_open = \
                    self._chrome_before_page_fullscreen or (True, True, False)
                self.toolbar.setVisible(show_toolbar)
                self.tabs.tabBar().setVisible(show_tabs)
                self.statusBar().setVisible(True)
                self.find_bar.setVisible(find_open)
                self._chrome_before_page_fullscreen = None
                self.showNormal()
        except Exception:
            LOG.exception("could not toggle the fullscreen chrome")

    # ---- downloads -------------------------------------------------------

    def on_download_requested(self, item):
        suggested = (item.suggestedFileName() or "download").strip() or "download"
        folder = QStandardPaths.writableLocation(
            QStandardPaths.StandardLocation.DownloadLocation)
        if not folder:
            folder = os.path.expanduser("~")
        path, _selected = QFileDialog.getSaveFileName(
            self, "Save download", os.path.join(folder, suggested))
        if not path:
            try:
                item.cancel()
            except Exception:
                pass
            return
        try:
            item.setDownloadDirectory(os.path.dirname(path) or folder)
            item.setDownloadFileName(os.path.basename(path))
            item.receivedBytesChanged.connect(
                lambda: self.on_download_progress(item))
            item.stateChanged.connect(
                lambda state: self.on_download_state(item, state))
            item.accept()
        except Exception as exc:
            self._set_status("Could not start the download: %s" % exc)
            return
        self._downloads.add(item)
        self._set_status("Downloading %s…" % os.path.basename(path))
        self.progress_bar.setValue(0)
        self.progress_bar.setVisible(True)

    def on_download_progress(self, item):
        try:
            total = item.totalBytes()
            if total > 0:
                self.progress_bar.setValue(
                    int(item.receivedBytes() * 100 / total))
                self.progress_bar.setVisible(True)
        except Exception:
            pass

    def on_download_state(self, item, state):
        try:
            if state == QWebEngineDownloadRequest.DownloadState.DownloadCompleted:
                name = item.downloadFileName() or "file"
                self._set_status("Downloaded %s" % name)
                self._downloads.discard(item)
            elif state in (
                    QWebEngineDownloadRequest.DownloadState.DownloadInterrupted,
                    QWebEngineDownloadRequest.DownloadState.DownloadCancelled):
                reason = item.interruptReasonString() or "the download failed"
                self._set_status("Download failed: %s" % reason)
                self._downloads.discard(item)
            if not self._downloads:
                self.progress_bar.setVisible(False)
        except Exception:
            pass

    # ---- external links / media -----------------------------------------

    def _launch_external(self, uri):
        scheme = urllib.parse.urlsplit(uri).scheme.lower()
        if scheme not in EXTERNAL_SCHEMES:
            self._set_status("Browse does not open this kind of link.")
            return
        try:
            if QDesktopServices.openUrl(QUrl(uri)):
                self._set_status("Opened in another app.")
                return
        except Exception:
            pass
        self._set_status("No app is registered for this link.")

    def set_page_media(self, tab, audio, video):
        self._media[id(tab)] = bool(audio) or bool(video)
        self._reconcile_media()

    def set_engine_audio(self, tab, on):
        self._engine_audio[id(tab)] = bool(on)
        self._reconcile_media()

    def _reconcile_media(self):
        if self._closing:
            return
        playing = any(self._media.values()) or any(self._engine_audio.values())
        try:
            if playing:
                self._inhibitor.inhibit("media playing")
            else:
                self._inhibitor.uninhibit()
        except Exception:
            pass

    def on_bridge_message(self, name, raw, tab):
        if name == "jawnos_adblock":
            self.on_adblock_message(raw, tab)
        elif name == "jawnos_measure":
            self.on_measure_message(raw, tab)
        elif name == "jawnos":
            self.on_media_message(raw, tab)
        elif name == "jawnos_browse":
            self.on_browse_message(raw)

    def on_media_message(self, raw, tab):
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            return
        if not isinstance(payload, dict) or payload.get("action") != "media_state":
            return
        if tab is not None:
            self.set_page_media(tab, payload.get("audio"), payload.get("video"))

    def on_browse_message(self, raw):
        """The page's ``JawnBrowse.open`` request becomes a tab in this window."""
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            return
        if not isinstance(payload, dict) or payload.get("action") != "browse":
            return
        uri = payload.get("url") or ""
        parsed = urllib.parse.urlsplit(str(uri))
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            return
        self.new_tab(uri=None, placeholder=False, switch=True)
        tab = self.current_tab()
        self._navigate(str(uri), tab)

    # ---- measure ---------------------------------------------------------

    def on_measure_message(self, raw, tab):
        if not raw:
            return
        # A message can only be a pick payload. Anything else is ignored; the
        # injected user script is the only thing that sends this handler a
        # message.
        if len(raw) > MAX_MEASURE_HTML * 3:
            return
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            return
        if not isinstance(payload, dict) or payload.get("action") != "pick":
            return
        if self.mode != "measure":
            return
        selector = payload.get("selector")
        document = payload.get("html")
        if not isinstance(selector, str) or not selector.strip():
            return
        if not isinstance(document, str) or not document:
            return
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
            return
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

    def _arm_picker(self):
        tab = self.current_tab()
        if self.mode != "measure" or tab is None or tab.internal:
            return
        try:
            tab.page.runJavaScript(
                "window.__jawnosPicker && window.__jawnosPicker.arm(true);")
        except Exception:
            pass

    def _measure_live(self, data):
        answer = self.client.post_form("/manager/web/measure/live", data)
        self._relay.deliver.emit((self._after_measure_live, (data, answer)))

    def _after_measure_live(self, data, answer):
        if self._closing:
            return
        if not isinstance(answer, dict) or not answer.get("ok"):
            self._set_status("The manager did not measure this page.")
            self._show_message(
                "Could not measure",
                "The manager did not answer the live-page request. Check that "
                "it is running and that this app is signed in.")
            return
        candidates = answer.get("candidates")
        if not isinstance(candidates, list) or not candidates:
            self._set_status("")
            self._show_message(
                "Nothing to measure",
                "Nothing on this page read as a value. Try clicking the "
                "number itself.")
            return
        self._set_status("")
        self._show_candidates(data, answer, candidates)

    def _show_candidates(self, data, answer, candidates):
        dialog = QDialog(self)
        dialog.setWindowTitle("Choose what to measure")
        dialog.resize(680, 500)
        layout = QVBoxLayout(dialog)
        intro = QLabel(
            "Pick the shape that should be watched. Each one is tested "
            "against this page.")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        inner = QWidget()
        inner_layout = QVBoxLayout(inner)
        group = QButtonGroup(dialog)
        choices = []
        first = None
        for candidate in candidates:
            if not isinstance(candidate, dict):
                continue
            spec = candidate.get("spec")
            if not isinstance(spec, dict):
                continue
            kind = str(candidate.get("kind") or "")
            value = str(candidate.get("value") or "")
            radio = QRadioButton("%s — %s" % (kind, value))
            spec_text = json.dumps(spec, sort_keys=True, ensure_ascii=False)
            radio.setToolTip(spec_text)
            inner_layout.addWidget(radio)
            spec_label = QLabel(spec_text)
            spec_label.setWordWrap(True)
            spec_label.setStyleSheet("color:#8e8e8e;")
            inner_layout.addWidget(spec_label)
            group.addButton(radio)
            choices.append((radio, spec))
            if first is None:
                first = radio
        if first is not None:
            first.setChecked(True)
        inner_layout.addStretch(1)
        scroll.setWidget(inner)
        layout.addWidget(scroll, 1)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        layout.addWidget(buttons)

        if not choices:
            dialog.deleteLater()
            self._show_message(
                "Nothing to measure",
                "Nothing on this page read as a value. Try clicking the "
                "number itself.")
            return
        accepted = dialog.exec() == QDialog.DialogCode.Accepted
        chosen = None
        if accepted:
            for radio, spec in choices:
                if radio.isChecked():
                    chosen = spec
                    break
        dialog.deleteLater()
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
        self._relay.deliver.emit((self._after_measure_submit, (answer,)))

    def _after_measure_submit(self, answer):
        if self._closing:
            return
        if isinstance(answer, dict):
            self._set_status("Measure saved.")
            self._show_message("Measure saved",
                               "The chosen shape is now stored for this app.")
        else:
            self._set_status("The measure was not saved.")
            self._show_message(
                "Not saved",
                "The manager did not answer the save request.")

    def _deliver(self, payload):
        callback, args = payload
        try:
            callback(*args)
        except Exception:
            LOG.exception("could not deliver a worker result")

    # ---- status / shutdown ----------------------------------------------

    def _set_status(self, text):
        try:
            self.status_label.setText(text or "")
        except Exception:
            pass

    def _show_message(self, title, body):
        if self._closing:
            return
        try:
            QMessageBox.information(self, title, body)
        except Exception:
            pass

    def _on_app_state(self, _state):
        self._sync_site()

    def focusInEvent(self, event):
        super().focusInEvent(event)
        self._sync_site()

    def focusOutEvent(self, event):
        super().focusOutEvent(event)
        self._sync_site()

    def _on_flush_timer(self):
        if self._closing:
            return
        threading.Thread(target=self.usage.flush, kwargs={"roll": True},
                         name="browse-flush", daemon=True).start()

    def shutdown(self):
        if self._closing:
            return
        self._closing = True
        try:
            self._flush_timer.stop()
        except Exception:
            pass
        try:
            self._inhibitor.uninhibit()
        except Exception:
            pass
        try:
            self.usage.shutdown()
        except Exception:
            LOG.exception("could not flush site time")

    def closeEvent(self, event):
        self.shutdown()
        self._close_pages()
        super().closeEvent(event)

    def _close_pages(self):
        """Drop the pages before the profile goes, so Qt tears down cleanly."""
        try:
            if self.tabs is None:
                return
            while self.tabs.count():
                tab = self.tabs.widget(0)
                self.tabs.removeTab(0)
                if isinstance(tab, BrowserTab):
                    try:
                        tab.view.stop()
                    except Exception:
                        pass
                    try:
                        tab.page.deleteLater()
                    except Exception:
                        pass
                    tab.deleteLater()
        except Exception:
            pass


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def _parser():
    parser = argparse.ArgumentParser(
        prog="jawnos-browse",
        description="JawnOS Browse -- the native Qt WebEngine browser window.",
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
    if not _QT_OK:
        sys.stderr.write(
            "jawnos-browse: PySide6 with Qt WebEngine is required (%s)\n"
            % _QT_ERROR)
        return 2
    # Before QApplication: Qt WebEngine reads the VA-API driver and the
    # Chromium flags when it initialises.
    gpu.prepare_env()
    prepare_wayland_env()

    app = QApplication([sys.argv[0]])
    app.setApplicationName("JawnOS Browse")
    app.setApplicationDisplayName("JawnOS Browse")
    app.setOrganizationName("JawnOS")
    try:
        app.setDesktopFileName("jawnos-browse")
    except Exception:
        pass

    window = BrowserWindow(args, check=args.check)
    if args.check:
        window.close()
        QApplication.processEvents()
        print("jawnos-browse: window constructed")
        return 0
    window.show()
    QTimer.singleShot(0, window._sync_site)
    return app.exec()


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
