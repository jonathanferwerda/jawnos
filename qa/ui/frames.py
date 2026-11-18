#!/usr/bin/env python3
"""Measure how smoothly the real JawnOS view paints.

The view is Qt WebEngine (PySide6), the engine the desktop app uses, and the
graphics environment is the shell's own: ``jawnos_desktop.gpu.prepare_env``
reads ``~/.config/jawnos/qt.env`` and the real environment, so a run describes
the machine the way JawnOS actually runs it. ``--software`` asks for the
software path instead, which is what headless CI has.

    python3 qa/ui/frames.py                       # the real card, built-in page
    python3 qa/ui/frames.py --software            # CI-shaped (needs xvfb)
    python3 qa/ui/frames.py --url https://127.0.0.1:3001/manager
    python3 qa/ui/frames.py --scenario idle,scroll,transform,shadow
    python3 qa/ui/frames.py --video /tmp/clip.webm

Each scenario reports the display's cadence (the median frame interval),
p50/p95/p99 and the longest frame, frames later than 1.5 cadences, frames
dropped against that cadence, Long Task time, and -- where the engine has it --
Long Animation Frame time spent in style and layout. ``busy`` stalls the main
thread on purpose: if it does not score worse than ``idle``, the probe is not
measuring and the run exits non-zero.

Exit codes: 0 measured, 1 nothing was measured or the control did not jank,
2 the run timed out.
"""

import argparse
import json
import os
import socket
import sys
import time
from urllib.parse import urlsplit, urlunsplit

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FRAMES_JS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "frames.js")

# The QA host may be XFCE/GNOME, where Qt otherwise loads its GTK platform
# theme (and libgtk) into the process. This is a Qt-only probe.
os.environ.setdefault("QT_QPA_PLATFORMTHEME", "generic")

DEFAULT_SCENARIOS = ["idle", "scroll", "transform", "opacity", "shadow",
                    "border", "width", "blur", "busy"]

BENCH_PAGE = """<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;background:#101418}</style></head><body></body></html>"""


def apply_graphics(software):
    """Prepare the graphics environment; return (mode, applied)."""
    flags = os.environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "")
    if software:
        if "--disable-gpu" not in flags:
            os.environ["QTWEBENGINE_CHROMIUM_FLAGS"] = (
                flags + " --disable-gpu --disable-gpu-compositing").strip()
        return "software (asked for)"
    sys.path.insert(0, os.path.join(ROOT, "desktop"))
    try:
        from jawnos_desktop import gpu
    except Exception as exc:  # noqa: BLE001
        return "unprepared (%s)" % exc
    applied = gpu.prepare_env(os.environ)
    flags = os.environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "")
    # The effective value, not only what this call set: Chromium and libva also
    # pick a driver by PCI id when nothing names one, and a report that says
    # "no VA-API driver" while VA-API is failing in the log is worse than none.
    driver = os.environ.get("LIBVA_DRIVER_NAME") or "auto"
    if "LIBVA_DRIVER_NAME" in applied:
        driver += " (chosen here)"
    if "--disable-gpu" in flags:
        return "software (LIBVA_DRIVER_NAME=%s)" % driver
    return "gpu (LIBVA_DRIVER_NAME=%s); flags:%s" % (driver, flags or " none")


def accept_certificate(error):
    """A probe may measure a page over the house's own certificate."""
    try:
        overridable = getattr(error, "isOverridable", None)
        if callable(overridable) and not overridable():
            return
        accept = getattr(error, "acceptCertificate", None)
        if not callable(accept):
            accept = getattr(error, "accept", None)
        if callable(accept):
            accept()
    except Exception:  # noqa: BLE001
        pass


def parse_size(text):
    try:
        width, height = text.lower().split("x", 1)
        return max(320, int(width)), max(200, int(height))
    except ValueError:
        raise argparse.ArgumentTypeError("size must be WIDTHxHEIGHT, e.g. 1280x800")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Frame timing for the real Qt WebEngine view.")
    parser.add_argument("--url", help="page to measure (default: the built-in bench)")
    parser.add_argument("--scenario", action="append", metavar="LIST",
                        help="comma-separated scenarios (repeatable); --list shows them")
    parser.add_argument("--video", help="a media file the 'video' scenario plays")
    parser.add_argument("--inject", action="append", default=[], metavar="FILE",
                        help="a script to load into the page before measuring (repeatable); "
                             "'drag' needs the app's own "
                             "public/js/manager/windows/05_effects.js and jQuery")
    parser.add_argument("--effects", choices=["off", "light", "medium", "maximum"],
                        help="the window effects level the injected app code reads")
    parser.add_argument("--out", default="-", help="write the JSON report here ('-' is stdout)")
    parser.add_argument("--size", type=parse_size, default=(1280, 800), metavar="WxH")
    parser.add_argument("--software", action="store_true",
                        help="measure the software path (what headless CI has)")
    parser.add_argument("--no-sandbox", action="store_true",
                        help="add Chromium's --no-sandbox (containers without the setuid helper)")
    parser.add_argument("--hidden", action="store_true", help="do not show the window")
    parser.add_argument("--settle", type=float, default=1.0, metavar="SECONDS",
                        help="let a real page settle after load before the first "
                             "scenario (default 1); the Manager keeps opening its "
                             "saved windows after loadFinished")
    parser.add_argument("--timeout", type=float, default=150.0,
                        help="seconds before the whole run gives up (default 150)")
    parser.add_argument("--scenario-timeout", type=float, default=20.0,
                        help="seconds to wait for one scenario (default 20)")
    parser.add_argument("--repeat", type=int, default=1,
                        help="run each scenario N times and keep its worst run")
    parser.add_argument("--list", action="store_true", help="print the scenario names")
    args = parser.parse_args(argv)

    names = []
    for chunk in args.scenario or []:
        names.extend(part.strip() for part in chunk.split(",") if part.strip())
    if not names:
        names = list(DEFAULT_SCENARIOS)
    if args.video and "video" not in names:
        names.append("video")
    args.scenarios = names
    # --inject is already a list (action="append"); keep one spelling for the
    # rest of the file, where a typo here is a Qt-slot exception and a timeout.
    args.injects = list(args.inject or [])
    return args


def scenarios_in_js():
    try:
        with open(FRAMES_JS, "r", encoding="utf-8") as handle:
            text = handle.read()
        start = text.index("var SCENARIOS =")
        end = text.index("];", start)
        raw = text[start:end].split("[", 1)[1]
        return [part.strip().strip('"') for part in raw.replace("\n", " ").split(",") if part.strip()]
    except (OSError, ValueError):
        return []


def redact_url(url):
    """A ticket URL carries the session token; never capture it in a report.

    The token is the whole credential: a probe that prints the URL it failed to
    load puts a live ticket into a terminal, a log and a pasted report. Only the
    scheme and host survive, which is all a report needs.
    """
    try:
        parts = urlsplit(url)
    except ValueError:
        return "<unparsable url>"
    if not parts.netloc:
        return url if not parts.query else parts.scheme + ":"
    return urlunsplit((parts.scheme, parts.netloc, "", "", ""))


def format_row(row):
    name = str(row.get("scenario", "?"))[:11]
    if row.get("skipped") or row.get("error"):
        return "%-11s %s" % (name, row.get("skipped") or row.get("error"))
    return "%-11s %5s %6.1f %6.2f %6.2f %6.2f %6.2f %6.1f %6d %7s %8s" % (
        name,
        row.get("frames", 0),
        row.get("fps", 0),
        row.get("p50", 0),
        row.get("p95", 0),
        row.get("p99", 0),
        row.get("max", 0),
        row.get("latePct", 0),
        row.get("dropped", 0),
        row.get("longTaskMs", 0),
        row.get("loafStyleLayoutMs", "-"),
    )


def verdict(rows):
    by_name = {row.get("scenario"): row for row in rows}
    idle, busy = by_name.get("idle"), by_name.get("busy")
    if not (idle and busy and idle.get("frames") and busy.get("frames")):
        return "detects-jank=untested (needs idle and busy)"
    worse = busy.get("p95", 0) > idle.get("p95", 0) and busy.get("latePct", 0) > idle.get("latePct", 0)
    return "detects-jank=" + ("yes" if worse else "NO")


def merge_rows(rows, repeat):
    """One row per scenario, keeping the worst run.

    A 1.5 s window is a sample: the same CSS property can cost nothing on a warm
    cache and drop a dozen frames while something else on the box is busy. With
    repeats the report keeps the worst p95 (then the worst late%), never the
    flattering average.
    """
    if repeat <= 1:
        return rows
    grouped, order = {}, []
    for row in rows:
        name = row.get("scenario")
        if name not in grouped:
            grouped[name] = []
            order.append(name)
        grouped[name].append(row)
    merged = []
    for name in order:
        runs = grouped[name]
        scored = [row for row in runs if row.get("frames")]
        if not scored:
            merged.extend(runs[:1])
            continue
        worst = dict(max(scored, key=lambda row: (row.get("p95", 0), row.get("latePct", 0))))
        worst["runs"] = len(runs)
        merged.append(worst)
    return merged


def report(rows, meta, args):
    width, height = args.size
    print("engine: qtwebengine   machine: %s   window: %dx%d   gpu: %s" % (
        meta.get("machine", "?"), width, height, meta.get("gpu", "?")), flush=True)
    print("graphics: %s" % meta.get("graphics", "?"), flush=True)
    page_info = meta.get("page") or {}
    if page_info:
        print("page: %s%s | %s nodes | %s scrollable | load %s" % (
            page_info.get("host", "?"), page_info.get("path", ""),
            page_info.get("nodes", "?"), page_info.get("scrollables", "?"),
            "ok" if meta.get("loadOk") else "FAILED"), flush=True)
    print("%-11s %5s %6s %6s %6s %6s %6s %6s %6s %7s %8s" % (
        "scenario", "frames", "fps", "p50", "p95", "p99", "max", "late%", "drops",
        "taskms", "loafms"), flush=True)
    for row in rows:
        print(format_row(row), flush=True)
    print("verdict: %s" % verdict(rows), flush=True)


def main(argv=None):
    args = parse_args(argv)
    if args.list:
        print(", ".join(scenarios_in_js()))
        return 0

    if args.hidden:
        # Chromium pauses the animation clock for an occluded page, so a hidden
        # window reads as "no result" or an artificially smooth run. Measured on
        # a real window by mistake once; say it instead of reporting it.
        print("frames: --hidden throttles the animation clock; these numbers are "
              "not the real view", file=sys.stderr)

    graphics = apply_graphics(args.software)
    flags = os.environ.get("QTWEBENGINE_CHROMIUM_FLAGS", "")
    if args.no_sandbox and "--no-sandbox" not in flags:
        os.environ["QTWEBENGINE_CHROMIUM_FLAGS"] = (flags + " --no-sandbox").strip()

    try:
        from PySide6.QtCore import QTimer, QUrl
        from PySide6.QtWidgets import QApplication
        from PySide6.QtWebEngineWidgets import QWebEngineView
    except Exception as exc:  # noqa: BLE001
        print("frames: PySide6 Qt WebEngine is required: %s" % exc, file=sys.stderr)
        return 2

    try:
        with open(FRAMES_JS, "r", encoding="utf-8") as handle:
            probe = handle.read()
    except OSError as exc:
        print("frames: cannot read %s: %s" % (FRAMES_JS, exc), file=sys.stderr)
        return 2

    state = {"results": [],
             "queue": [name for name in args.scenarios for _ in range(max(1, args.repeat))],
             "period": None,
             "meta": {"machine": socket.gethostname(), "graphics": graphics}}

    app = QApplication([])
    view = QWebEngineView()
    view.setWindowTitle("JawnOS frame probe")
    view.resize(*args.size)
    page = view.page()
    try:
        page.certificateError.connect(accept_certificate)
    except Exception:  # noqa: BLE001
        pass
    if not args.hidden:
        view.show()

    def finish(code):
        rows = merge_rows(state["results"], args.repeat)
        if code and not rows:
            print("frames: nothing was measured (%s)" % args.url if args.url else
                  "frames: nothing was measured", file=sys.stderr)
        report(rows, state["meta"], args)
        payload = {
            "engine": "qtwebengine",
            "machine": state["meta"].get("machine"),
            "gpu": state["meta"].get("gpu"),
            "graphics": graphics,
            "window": list(args.size),
            "url": redact_url(args.url) if args.url else "about:blank (built-in bench)",
            "page": state["meta"].get("page"),
            "loadOk": state["meta"].get("loadOk"),
            "scenarios": rows,
            "verdict": verdict(rows),
        }
        if args.out and args.out != "-":
            try:
                with open(args.out, "w", encoding="utf-8") as handle:
                    json.dump(payload, handle, indent=2, sort_keys=True)
                    handle.write("\n")
            except OSError as exc:
                print("frames: cannot write %s: %s" % (args.out, exc), file=sys.stderr)
        else:
            print(json.dumps(payload, sort_keys=True), flush=True)
        QTimer.singleShot(0, lambda: os._exit(code))

    def timed_out():
        print("frames: timed out after %.0fs" % args.timeout, file=sys.stderr)
        finish(2)

    def start_next():
        if not state["queue"]:
            return finish(0)
        name = state["queue"].pop(0)
        options = {"period": state["period"]}
        if name == "video" and args.video:
            options["videoSrc"] = QUrl.fromLocalFile(os.path.abspath(args.video)).toString()
        page.runJavaScript("window.__jfRun(%s, %s)" % (
            json.dumps(name), json.dumps(options)))
        poll(name, time.time() + args.scenario_timeout)

    def poll(name, deadline):
        def got(value):
            text = str(value or "")
            if text:
                try:
                    row = json.loads(text)
                except ValueError:
                    row = {"scenario": name, "error": "unparsable result"}
                if row.get("scenario") == "idle" and row.get("periodMs"):
                    state["period"] = row["periodMs"]
                state["results"].append(row)
                QTimer.singleShot(120, start_next)
            elif time.time() > deadline:
                state["results"].append({"scenario": name, "error": "no result"})
                start_next()
            else:
                QTimer.singleShot(100, lambda: poll(name, deadline))
        page.runJavaScript("window.__jfResult || ''", got)

    def loaded(ok):
        state["meta"]["loadOk"] = bool(ok)
        state["meta"]["loads"] = state["meta"].get("loads", 0) + 1
        if not ok and args.url:
            print("frames: the page reported a failed load: %s" % redact_url(args.url),
                  file=sys.stderr)
        page.runJavaScript(probe)
        if args.effects:
            page.runJavaScript(
                "(window.jawnos_bar_settings = window.jawnos_bar_settings || {})"
                ".window_effects = %s" % json.dumps(args.effects))
        for path in args.injects:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    text = handle.read()
            except OSError as exc:
                print("frames: cannot read %s: %s" % (path, exc), file=sys.stderr)
                continue
            page.runJavaScript(text)
        if state.get("started"):
            # A redirect or a late frame can finish twice; measure once.
            return
        state["started"] = True

        def go():
            page.runJavaScript("jawnosFrames.renderer()", begin)
        page.runJavaScript("typeof jawnosFrames", lambda ready: QTimer.singleShot(
            50, go) if str(ready) == "object" else QTimer.singleShot(100, go))

    def begin(renderer):
        text = str(renderer)
        state["meta"]["gpu"] = "none (software path)" if text == "none" else text
        QTimer.singleShot(int(max(0.0, args.settle) * 1000), sample_page)

    def sample_page():
        """What was actually loaded: a report must not claim a page it guessed."""
        page.runJavaScript(
            "JSON.stringify({title: document.title.slice(0, 60),"
            " host: location.host,"
            " path: location.pathname.split('/').slice(0, 2).join('/'),"
            " nodes: document.querySelectorAll('*').length,"
            " scrollables: (function () { var n = 0; var e = document.querySelectorAll("
            "'div,main,section,article,ul,ol,pre,textarea');"
            " for (var i = 0; i < e.length; i++) {"
            " if (e[i].scrollHeight > e[i].clientHeight + 20 && e[i].clientHeight > 60) { n++; } }"
            " return n; })()})",
            got_page)

    def got_page(value):
        try:
            state["meta"]["page"] = json.loads(str(value or "{}"))
        except ValueError:
            state["meta"]["page"] = {}
        start_next()

    page.loadFinished.connect(loaded)
    if args.url:
        page.load(QUrl(args.url))
    else:
        page.setHtml(BENCH_PAGE, QUrl("file:///tmp/jawnos-frames.html"))

    QTimer.singleShot(int(args.timeout * 1000), timed_out)
    app.exec()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
