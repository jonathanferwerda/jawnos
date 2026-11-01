#!/usr/bin/env python3
"""Load the QA manager in WebKitGTK, the engine the desktop app uses.

    xvfb-run -a python3 webkit_probe.py <url> <out.json>

The QA instance runs with `live`, so a loopback request is the machine in
someone's hands and opens the manager without a cookie. The self-signed
certificate is allowed for this host only.

This is the engine check the project asks for: Chromium proves breadth, this
proves the app in the WebView people actually use.
"""

import json
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import GLib, Gtk, WebKit2  # noqa: E402

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
        nodes: document.querySelectorAll('*').length
    };
})()"""


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: webkit_probe.py <url> <out.json>", file=sys.stderr)
        return 2
    url, out = sys.argv[1], sys.argv[2]
    state = {"done": False, "load": "none", "url": url, "errors": []}

    def finish(result):
        if state["done"]:
            return
        state["done"] = True
        try:
            with open(out, "w") as fh:
                json.dump(result, fh)
        except Exception as exc:  # noqa: BLE001
            print(f"webkit_probe: cannot write {out}: {exc}", file=sys.stderr)
        Gtk.main_quit()

    win = Gtk.Window()
    win.set_default_size(1280, 900)
    view = WebKit2.WebView()
    ctx = WebKit2.WebContext.get_default()

    def on_tls(_view, failing_uri, certificate, _errors):
        # self-signed, and only for this host
        ctx.allow_tls_certificate_for_host(certificate, failing_uri)
        GLib.idle_add(lambda: (view.load_uri(failing_uri), False)[1])
        return True

    def on_fail(_view, _event, failing_uri, error):
        state["errors"].append(f"{error.message} ({failing_uri})")
        return False

    view.connect("load-failed-with-tls-errors", on_tls)
    view.connect("load-failed", on_fail)
    win.add(view)
    win.show_all()

    def on_js(_view, task):
        try:
            res = view.run_javascript_finish(task)
            value = res.get_js_value().to_json(0)
            data = json.loads(value)
            data["engine"] = "webkit2gtk-4.1"
            data["load"] = state["load"]
            data["errors"] = state["errors"]
            finish(data)
        except Exception as exc:  # noqa: BLE001
            finish({"engine": "webkit2gtk-4.1", "error": str(exc)})

    def on_load(_view, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        if state.get("probed"):
            return
        uri = view.get_uri() or ""
        # The view's initial about:blank finishes before load_uri takes effect.
        if not uri or uri.startswith("about:"):
            return
        if uri != state["url"] and not uri.startswith(state["url"]):
            return
        state["probed"] = True
        state["load"] = "finished"
        GLib.timeout_add(1500, lambda: (view.run_javascript(PROBE, None, on_js), False)[1])

    view.connect("load-changed", on_load)
    GLib.timeout_add_seconds(45, lambda: (finish({
        "engine": "webkit2gtk-4.1", "error": "timeout",
        "errors": state["errors"], "url": view.get_uri() or "",
    }), False)[1])
    view.load_uri(url)
    Gtk.main()
    return 0 if state["done"] else 1


if __name__ == "__main__":
    sys.exit(main())
