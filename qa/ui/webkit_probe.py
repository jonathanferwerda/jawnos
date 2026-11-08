#!/usr/bin/env python3
"""Load the QA manager in Qt WebEngine, the desktop's engine.

The file keeps its old name so existing QA commands keep working; the engine is
Qt WebEngine (PySide6), the same engine the desktop app uses.

    xvfb-run -a python3 webkit_probe.py <url> <out.json>

The QA instance runs with `live`, so a loopback request is the machine in
someone's hands and opens the manager without a cookie. The self-signed
certificate is accepted for the house's page through Qt's `certificateError`
signal; Qt then retries the load itself, so the old WebKit reload dance is gone.

A failed load reports what the view actually saw (`events`) so a fence or
engine problem reads as itself instead of a bare "timeout".

The probe also writes a PNG of the loaded page to `<outdir>/shots/<page>.png`
and names it in the report's `screenshot` key, beside the Chromium probe's
screenshots.
"""

import json
import os
import sys
from urllib.parse import urlparse

# The QA host may be XFCE/GNOME, where Qt otherwise loads its GTK platform
# theme (and libgtk) into the process. This is a Qt-only probe.
os.environ.setdefault("QT_QPA_PLATFORMTHEME", "generic")
os.environ.setdefault(
    "QTWEBENGINE_CHROMIUM_FLAGS",
    "--disable-gpu --no-sandbox --disable-dev-shm-usage")
os.environ.setdefault("QTWEBENGINE_DISABLE_SANDBOX", "1")

try:
    from PySide6.QtCore import QCoreApplication, QTimer, Qt, QUrl
    from PySide6.QtGui import QColor
    from PySide6.QtWidgets import QApplication
    from PySide6.QtWebEngineCore import QWebEnginePage
    from PySide6.QtWebEngineWidgets import QWebEngineView
    try:
        from PySide6.QtWebEngineCore import QWebEnginePermission as Permission
    except Exception:  # noqa: BLE001
        Permission = None
except Exception as exc:  # noqa: BLE001
    print("webkit_probe: PySide6 Qt WebEngine is required: %s" % exc,
          file=sys.stderr)
    raise SystemExit(2)

PROBE = """(() => {
    const vis = el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
    const q = s => [...document.querySelectorAll(s)].filter(vis);
    const name = el => ((el.innerText || '').trim() || el.getAttribute('aria-label')
        || el.getAttribute('title') || el.getAttribute('hint') || el.getAttribute('alt') || '');
    const buttons = q('button,[role="button"]');
    const inputs = q('input:not([type=hidden]),select,textarea');
    const links = q('a,button,[role="button"]');
    return {
        title: document.title,
        url: location.href,
        hasMenu: !!document.getElementById('start_menu_toggle'),
        buttons: buttons.length,
        unlabeled: buttons.filter(b => !name(b)).length,
        inputs: inputs.length,
        unlabeledInputs: inputs.filter(i => !((i.labels && i.labels.length)
            || i.getAttribute('aria-label') || i.getAttribute('placeholder')
            || i.getAttribute('title'))).length,
        imgsNoAlt: q('img').filter(i => !i.getAttribute('alt')).length,
        smallTargets: links.filter(e => { const r = e.getBoundingClientRect();
            return r.width > 0 && (r.width < 24 || r.height < 24); }).length,
        overflow: document.documentElement.scrollWidth > window.innerWidth + 2,
        nodes: document.querySelectorAll('*').length,
        budgetLight: (() => {
            // The appointment view's light is rendered by core pages that never
            // open the Budget app, so both the handler and budgetLight() must be
            // in the core bundle. Bound in a lazy chunk, every click before the
            // Budget app was opened did nothing (v0.1.1810). This asks the real
            // engine, on a page nothing has opened, whether the click reaches
            // the route at all.
            const out = { defined: typeof budgetLight === 'function', handled: false };
            if (!out.defined) { return out; }
            const calls = [];
            const ajax = jQuery.ajax;
            const setter = window.settingSetter;
            jQuery.ajax = function (o) {
                calls.push(o && o.url);
                return { done: function () { return this; },
                    fail: function () { return this; },
                    always: function () { return this; } };
            };
            window.settingSetter = function () {};
            try {
                jQuery('body').append('<span id="qa_probe_light" class="budget_light" app="__qa_probe__" circumstance="duration"></span>'
                    + '<div id="qa_probe_panel" class="budget_current_information" app="__qa_probe__"></div>');
                jQuery('#qa_probe_light').trigger('click');
                out.handled = calls.indexOf('/manager/budget/current_information') !== -1;
            } catch (e) {
                out.error = String(e);
            } finally {
                jQuery.ajax = ajax;
                window.settingSetter = setter;
                jQuery('#qa_probe_light, #qa_probe_panel').remove();
            }
            return out;
        })()
    };
})()"""


def _accept_certificate(error):
    """Accept the house's self-signed certificate when Qt lets us override it."""
    try:
        if hasattr(error, "isOverridable") and not error.isOverridable():
            return False
        # Qt 6.8 spells it acceptCertificate(); older bindings used accept().
        if hasattr(error, "acceptCertificate"):
            error.acceptCertificate()
        else:
            error.accept()
        return True
    except Exception:  # noqa: BLE001
        return False


def _grant_permissions(page):
    """Grant the microphone/camera requests the manager page makes."""
    if Permission is not None and hasattr(page, "permissionRequested"):
        enum = getattr(Permission, "PermissionType", None)
        if enum is None:
            enum = getattr(Permission, "Feature", Permission)
        granted = set()
        for name in ("MediaAudioCapture", "MediaVideoCapture",
                     "MediaAudioVideoCapture"):
            value = getattr(enum, name, None)
            if value is not None:
                granted.add(value)

        def decide(permission):
            try:
                if permission.permissionType() in granted:
                    permission.grant()
                else:
                    permission.deny()
            except Exception:  # noqa: BLE001
                pass

        page.permissionRequested.connect(decide)
        return

    granted = set()
    for name in ("MediaAudioCapture", "MediaVideoCapture",
                 "MediaAudioVideoCapture"):
        value = getattr(QWebEnginePage.Feature, name, None)
        if value is not None:
            granted.add(value)

    def decide_legacy(origin, feature):
        policy = (QWebEnginePage.PermissionPolicy.PermissionGrantedByUser
                  if feature in granted else
                  QWebEnginePage.PermissionPolicy.PermissionDeniedByUser)
        page.setFeaturePermission(origin, feature, policy)

    page.featurePermissionRequested.connect(decide_legacy)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: webkit_probe.py <url> <out.json>", file=sys.stderr)
        return 2
    url, out = sys.argv[1], sys.argv[2]
    state = {"done": False, "load": "none", "url": url, "errors": [],
             "events": [], "tls": 0, "probed": False}

    def note(what, detail=""):
        state["events"].append(f"{what}: {detail}" if detail else what)
        del state["events"][:-10]

    try:
        QCoreApplication.setAttribute(Qt.ApplicationAttribute.AA_ShareOpenGLContexts)
    except Exception:  # noqa: BLE001
        pass
    app = QApplication.instance() or QApplication([sys.argv[0]])
    app.setApplicationName("jawnos-qa-probe")

    view = QWebEngineView()
    view.resize(1280, 900)
    page = view.page()
    page.setBackgroundColor(QColor("black"))
    _grant_permissions(page)

    def screenshot(result):
        try:
            outdir = os.path.dirname(os.path.abspath(out)) or "."
            shots = os.path.join(outdir, "shots")
            os.makedirs(shots, exist_ok=True)
            slug = urlparse(url).path.strip("/").replace("/", "-") or "page"
            path = os.path.join(shots, slug + ".png")
            if view.grab().save(path):
                result.setdefault("screenshot", path)
        except Exception as exc:  # noqa: BLE001
            result.setdefault("screenshot_error", str(exc))

    def finish(result):
        if state["done"]:
            return
        state["done"] = True
        result.setdefault("engine", "qtwebengine")
        result.setdefault("events", state["events"])
        result.setdefault("errors", state["errors"])
        try:
            with open(out, "w") as fh:
                json.dump(result, fh)
        except Exception as exc:  # noqa: BLE001
            print(f"webkit_probe: cannot write {out}: {exc}", file=sys.stderr)
        app.quit()

    def on_tls(error):
        try:
            failing = error.url().toString() if hasattr(error, "url") else ""
        except Exception:  # noqa: BLE001
            failing = ""
        host = urlparse(failing).hostname or ""
        state["tls"] += 1
        note("tls-error", f"{host or '?'}")
        if state["tls"] > 3:
            note("tls", "certificate refused after retries")
            return False
        if _accept_certificate(error):
            note("tls-accepted", host or "?")
            return True
        note("tls", "certificate refused")
        return False

    def on_js(result):
        try:
            data = result if isinstance(result, dict) else json.loads(result)
        except Exception as exc:  # noqa: BLE001
            finish({"error": f"javascript probe failed: {exc}",
                    "url": page.url().toString()})
            return
        data["engine"] = "qtwebengine"
        data["load"] = state["load"]
        data["errors"] = list(state["errors"])
        screenshot(data)
        finish(data)

    def on_timeout():
        if state["done"]:
            return
        finish({
            "error": "timeout",
            "reason": (f"no load finished in 45s (load={state['load']}, "
                       f"tls-errors={state['tls']}, url={page.url().toString() or url})"),
            "url": page.url().toString() or "",
        })

    def on_load(ok):
        if state["done"]:
            return
        current = page.url().toString()
        # The view's initial about:blank finishes before setUrl takes effect.
        if not current or current.startswith("about:"):
            return
        if not ok:
            state["errors"].append(f"load-failed ({current})")
            note("load-failed", current)
            return
        if state["probed"]:
            return
        if current != state["url"] and not current.startswith(state["url"]):
            return
        state["probed"] = True
        state["load"] = "finished"
        note("finished", current)
        # Qt hands back an object as an empty string; JSON.stringify gives the
        # same JSON shape the WebKit probe read with to_json(0).
        QTimer.singleShot(1500, lambda: page.runJavaScript(
            "JSON.stringify(" + PROBE + ")", on_js))

    page.certificateError.connect(on_tls)
    page.loadStarted.connect(lambda: note("load-started", page.url().toString()))
    page.loadFinished.connect(on_load)
    QTimer.singleShot(45000, on_timeout)

    view.show()
    view.setUrl(QUrl(url))
    app.exec()
    return 0 if state["done"] else 1


if __name__ == "__main__":
    sys.exit(main())
