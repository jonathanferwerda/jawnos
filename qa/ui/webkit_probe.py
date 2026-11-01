#!/usr/bin/env python3
"""Load the QA manager in WebKitGTK, the engine the desktop app uses.

    xvfb-run -a python3 webkit_probe.py <url> <out.json>

The QA instance runs with `live`, so a loopback request is the machine in
someone's hands and opens the manager without a cookie. The self-signed
certificate is allowed for this host only.

Two details make that TLS path work, and both are load-bearing:

  * `allow_tls_certificate_for_host` takes a *host* (`127.0.0.1`), not the
    failing URI. Handing it the URI files the exception under a key that
    never matches the request, so every reload fails the same way.
  * the reload must happen after the signal handler has returned. Reloading
    from inside it (an idle in the same iteration) cancels the load that is
    still unwinding and leaves the view on about:blank.

A failed load reports what the view actually saw (`events`) so a fence or
engine problem reads as itself instead of a bare "timeout".

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
    state = {"done": False, "load": "none", "url": url, "errors": [],
             "events": [], "tls": 0}

    def note(what, detail=""):
        state["events"].append(f"{what}: {detail}" if detail else what)
        del state["events"][:-10]

    def finish(result):
        if state["done"]:
            return
        state["done"] = True
        result.setdefault("engine", "webkit2gtk-4.1")
        result.setdefault("events", state["events"])
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

    def on_tls(_view, failing_uri, certificate, tls_errors):
        # self-signed, and only for this host
        try:
            host = GLib.Uri.parse(failing_uri, GLib.UriFlags.NONE).get_host() or ""
        except Exception:  # noqa: BLE001
            host = ""
        state["tls"] += 1
        note("tls-error", f"{host or '?'} flags={int(tls_errors)}")
        if not host or state["tls"] > 3:
            note("tls", "certificate refused; not reloading")
            return True
        try:
            ctx.allow_tls_certificate_for_host(certificate, host)
        except Exception as exc:  # noqa: BLE001
            note("tls-allow-failed", str(exc))
            return True
        note("tls-allowed", host)
        # Not idle: the handler must return before this reload replaces the
        # load that is still unwinding (otherwise: about:blank).
        GLib.timeout_add(150, lambda: (view.load_uri(failing_uri), False)[1])
        return True

    def on_fail(_view, _event, failing_uri, error):
        message = error.message or ""
        note("load-failed", f"{message} ({failing_uri})")
        # The reload above cancels the request that raised the TLS error.
        if state["tls"] and message.lower().startswith("operation was cancelled"):
            return True
        state["errors"].append(f"{message} ({failing_uri})")
        return False

    view.connect("load-failed-with-tls-errors", on_tls)
    view.connect("load-failed", on_fail)
    try:
        view.connect("web-process-terminated",
            lambda _view, reason: note("web-process-terminated", str(reason)))
    except TypeError:
        pass  # older WebKit without the signal
    win.add(view)
    win.show_all()

    def on_js(_view, task):
        try:
            res = view.run_javascript_finish(task)
            data = json.loads(res.get_js_value().to_json(0))
        except Exception as exc:  # noqa: BLE001
            finish({"error": f"javascript probe failed: {exc}",
                    "url": view.get_uri() or ""})
            return
        data["engine"] = "webkit2gtk-4.1"
        data["load"] = state["load"]
        data["errors"] = state["errors"]
        finish(data)

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
        note("finished", uri)
        GLib.timeout_add(1500, lambda: (view.run_javascript(PROBE, None, on_js), False)[1])

    def on_timeout():
        finish({
            "error": "timeout",
            "reason": (f"no load finished in 45s (load={state['load']}, "
                       f"tls-errors={state['tls']}, url={view.get_uri() or url})"),
            "url": view.get_uri() or "",
        })
        return False

    view.connect("load-changed", on_load)
    GLib.timeout_add_seconds(45, on_timeout)
    view.load_uri(url)
    Gtk.main()
    return 0 if state["done"] else 1


if __name__ == "__main__":
    sys.exit(main())
