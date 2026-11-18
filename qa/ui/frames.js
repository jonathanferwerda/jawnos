/* Frame timing for the real JawnOS view.
 *
 * Injected by qa/ui/frames.py; it can also be pasted into the console of the
 * running Manager:
 *
 *     jawnosFrames.run('idle').then(console.log)      // the display's cadence
 *     jawnosFrames.run('scroll').then(console.log)
 *     jawnosFrames.run('scrollpage').then(console.log)
 *     jawnosFrames.run('transform').then(console.log)
 *
 * Every run reduces requestAnimationFrame intervals to the numbers that decide
 * whether the view feels smooth: the display's own period (the median
 * interval), p50/p95/p99 and the longest frame, frames later than 1.5 periods,
 * and frames dropped against that period. Long Tasks -- and, where the engine
 * has it, Long Animation Frames with their style/layout time -- are recorded
 * alongside, so a badly painted CSS property can be told apart from a busy
 * main thread.
 *
 * The scenarios are the ones this house actually uses. A grid of tiles is
 * animated, not one box: a single element is cheap enough that every property
 * looks free, and the difference between compositor work (transform, opacity)
 * and main-thread work (box-shadow, border-color, width, filter) only shows at
 * the size of a page. 'scroll' is raster, 'scrollpage' scrolls whatever the
 * loaded page actually scrolls, and 'busy' stalls the main thread on purpose --
 * a positive control, so a probe that only ever reports a smooth run is caught.
 *
 * rAF intervals are main-thread frame production: they see a stalled thread and
 * a missed BeginFrame. They do not see time spent on the compositor thread, so
 * a smooth main thread with a starved GPU can still read as 60 fps here.
 */
(function () {
  "use strict";
  if (window.jawnosFrames) { return; }

  var SCENARIOS = ["idle", "scroll", "scrollpage", "transform", "opacity",
                   "shadow", "border", "width", "blur", "video", "busy"];
  var TILES = 36;

  var CSS = [
    "#jp-bench{position:fixed;inset:0;z-index:2147483647;background:#101418;overflow:hidden}",
    "#jp-bench .jp-row{height:44px;box-sizing:border-box;padding:12px 16px;color:#cfd8dc;",
    "font:14px/20px sans-serif;border-bottom:1px solid #263238;background:#141a1f}",
    "#jp-grid{position:absolute;inset:0;display:grid;grid-template-columns:repeat(6,1fr);",
    "gap:8px;padding:8px;box-sizing:border-box}",
    "#jp-grid .jp-tile{box-sizing:border-box;padding:8px;overflow:hidden;background:#1b262c;",
    "color:#b0bec5;font:13px/16px sans-serif;border:4px solid #2e7d32}",
    "@keyframes jp-tx{from{transform:translate3d(0,0,0)}to{transform:translate3d(34px,0,0)}}",
    "@keyframes jp-op{from{opacity:1}to{opacity:.55}}",
    "@keyframes jp-shadow{from{box-shadow:0 1px 2px rgba(0,0,0,.25)}",
    "to{box-shadow:0 10px 30px 10px rgba(0,0,0,.85)}}",
    "@keyframes jp-border{from{border-color:#2e7d32}to{border-color:#e53935}}",
    "@keyframes jp-width{from{width:100%}to{width:62%}}",
    "@keyframes jp-blur{from{filter:blur(0)}to{filter:blur(5px)}}",
    "#jp-grid.jp-tx .jp-tile{animation:jp-tx 1.2s linear infinite alternate;will-change:transform}",
    "#jp-grid.jp-op .jp-tile{animation:jp-op 1.2s linear infinite alternate;will-change:opacity}",
    "#jp-grid.jp-shadow .jp-tile{animation:jp-shadow 1.2s linear infinite alternate}",
    "#jp-grid.jp-border .jp-tile{animation:jp-border 1.2s linear infinite alternate}",
    "#jp-grid.jp-width .jp-tile{animation:jp-width 1.2s linear infinite alternate}",
    "#jp-grid.jp-blur{animation:jp-blur 1.2s linear infinite alternate}"
  ].join("");

  function bench() {
    var found = document.getElementById("jp-bench");
    if (found) { return found; }
    var style = document.createElement("style");
    style.textContent = CSS;
    document.head.appendChild(style);
    found = document.createElement("div");
    found.id = "jp-bench";
    document.documentElement.appendChild(found);
    return found;
  }

  function grid(host) {
    var found = document.getElementById("jp-grid");
    if (found) { return found; }
    found = document.createElement("div");
    found.id = "jp-grid";
    var fragment = document.createDocumentFragment();
    for (var i = 0; i < TILES; i++) {
      var tile = document.createElement("div");
      tile.className = "jp-tile";
      tile.textContent = "tile " + i + " - the quick brown fox jumps over the lazy dog";
      fragment.appendChild(tile);
    }
    found.appendChild(fragment);
    host.appendChild(found);
    return found;
  }

  function makeRows(host, count) {
    host.innerHTML = "";
    var fragment = document.createDocumentFragment();
    for (var i = 0; i < count; i++) {
      var row = document.createElement("div");
      row.className = "jp-row";
      row.textContent = "row " + i + " - the quick brown fox jumps over the lazy dog";
      fragment.appendChild(row);
    }
    host.appendChild(fragment);
    return host;
  }

  /* The largest scroller on the page: whatever a person would actually drag. */
  function pickScroller() {
    var best = null, bestArea = 0;
    var elements = document.querySelectorAll("div,main,section,article,ul,ol");
    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      if (el.closest("#jp-bench")) { continue; }
      if (el.scrollHeight <= el.clientHeight + 48 || el.clientHeight < 120) { continue; }
      var area = el.clientHeight * Math.max(el.clientWidth, 1);
      if (area > bestArea) { bestArea = area; best = el; }
    }
    return best || document.scrollingElement || document.documentElement;
  }

  function measure(ms, onFrame) {
    return new Promise(function (resolve) {
      var intervals = [], first = 0, last = 0;
      function step(stamp) {
        if (!first) { first = stamp; }
        if (last) { intervals.push(stamp - last); }
        last = stamp;
        if (onFrame) { onFrame(stamp - first); }
        if (stamp - first < ms) { requestAnimationFrame(step); }
        else { resolve(intervals); }
      }
      requestAnimationFrame(step);
    });
  }

  function round(value, places) {
    var factor = Math.pow(10, places === undefined ? 1 : places);
    return Math.round(value * factor) / factor;
  }

  function reduce(intervals, period) {
    if (!intervals.length) { return { frames: 0 }; }
    var sorted = intervals.slice().sort(function (a, b) { return a - b; });
    function percentile(p) {
      return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
    }
    var total = 0, slow = 0, i;
    for (i = 0; i < intervals.length; i++) {
      total += intervals[i];
      if (intervals[i] > 34) { slow++; }
    }
    var cadence = period || percentile(0.5);
    var late = 0;
    for (i = 0; i < intervals.length; i++) {
      if (intervals[i] > cadence * 1.5) { late++; }
    }
    return {
      frames: intervals.length,
      durationMs: round(total),
      periodMs: round(cadence, 2),
      fps: round(1000 / percentile(0.5), 1),
      p50: round(percentile(0.5), 2),
      p95: round(percentile(0.95), 2),
      p99: round(percentile(0.99), 2),
      max: round(sorted[sorted.length - 1], 2),
      lateFrames: late,
      latePct: round(100 * late / intervals.length),
      over33ms: slow,
      dropped: Math.max(0, Math.round(total / cadence) - intervals.length)
    };
  }

  function watch() {
    var longTasks = [], animationFrames = [], stops = [];
    try {
      var tasks = new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (entry) { longTasks.push(entry.duration); });
      });
      tasks.observe({ type: "longtask" });
      stops.push(function () {
        tasks.takeRecords().forEach(function (entry) { longTasks.push(entry.duration); });
        tasks.disconnect();
      });
    } catch (e) { /* no Long Tasks: an older engine */ }
    try {
      var types = (window.PerformanceObserver && PerformanceObserver.supportedEntryTypes) || [];
      if (types.indexOf("long-animation-frame") >= 0) {
        var frames = new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (entry) {
            var start = entry.styleAndLayoutStart || 0;
            animationFrames.push({
              duration: entry.duration,
              styleLayout: start ? (entry.startTime + entry.duration - start) : 0
            });
          });
        });
        frames.observe({ type: "long-animation-frame" });
        stops.push(function () { frames.disconnect(); });
      }
    } catch (e) { /* Long Animation Frames arrived after this engine */ }
    return {
      longTasks: longTasks,
      animationFrames: animationFrames,
      stop: function () { stops.forEach(function (fn) { fn(); }); }
    };
  }

  function setUp(name, opts) {
    var host = bench();
    host.style.display = "";
    var board = grid(host);
    board.className = "";

    if (name === "idle") { return {}; }

    if (name === "scroll") {
      var rows = document.getElementById("jp-rows");
      if (!rows) {
        rows = document.createElement("div");
        rows.id = "jp-rows";
        rows.style.cssText = "position:absolute;inset:0;overflow-y:auto";
        host.appendChild(rows);
      }
      makeRows(rows, 320);
      var span = Math.max(0, rows.scrollHeight - rows.clientHeight);
      return {
        frame: function (t) { rows.scrollTop = Math.round((t / opts.ms) * span); },
        done: function () { if (rows.parentNode) { rows.parentNode.removeChild(rows); } }
      };
    }

    if (name === "scrollpage") {
      host.style.display = "none";
      var scroller = pickScroller();
      var range = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
      return {
        frame: function (t) { scroller.scrollTop = Math.round((t / opts.ms) * range); },
        target: (scroller.tagName || "?") + (scroller.id ? "#" + scroller.id : "")
      };
    }

    var animated = { transform: "jp-tx", opacity: "jp-op", shadow: "jp-shadow",
                     border: "jp-border", width: "jp-width", blur: "jp-blur" };
    if (animated[name]) {
      board.className = animated[name];
      return { done: function () { board.className = ""; } };
    }

    if (name === "video") {
      if (!opts.videoSrc) { return { skipped: "video needs --video <file>" }; }
      var player = document.createElement("video");
      player.muted = true;
      player.loop = true;
      player.autoplay = true;
      player.playsInline = true;
      player.src = opts.videoSrc;
      player.style.cssText = "position:absolute;left:24px;top:80px;width:640px;height:360px";
      host.appendChild(player);
      var played = player.play();
      if (played && played.catch) { played.catch(function () {}); }
      return {
        done: function () {
          player.pause();
          if (player.parentNode) { player.parentNode.removeChild(player); }
        }
      };
    }

    if (name === "busy") {
      /* A main-thread stall every frame: the positive control. It has to cost
       * more than one display period, or a 60 Hz frame absorbs it and the run
       * reads as smooth -- which is exactly how a broken probe hides. */
      var stall = Math.max(12, (opts.period || 16.7) * 1.6);
      return { frame: function () {
        var until = performance.now() + stall;
        while (performance.now() < until) { /* stall */ }
      } };
    }

    return { skipped: "unknown scenario: " + name };
  }

  function renderer() {
    try {
      var canvas = document.createElement("canvas");
      var gl = canvas.getContext("webgl") || canvas.getContext("experimental-webgl");
      if (!gl) { return "none"; }
      var info = gl.getExtension("WEBGL_debug_renderer_info");
      var vendor = info ? gl.getParameter(info.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
      var device = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
      return String(vendor) + " / " + String(device);
    } catch (e) { return "error: " + e; }
  }

  function run(name, opts) {
    opts = opts || {};
    opts.ms = opts.ms || (name === "idle" ? 1200 : 1500);
    if (SCENARIOS.indexOf(name) < 0) {
      return Promise.reject(new Error("unknown scenario: " + name));
    }
    var seen = watch();
    var setup = setUp(name, opts);
    if (setup.skipped) {
      seen.stop();
      return Promise.resolve({ scenario: name, skipped: setup.skipped });
    }
    return measure(opts.ms, setup.frame).then(function (intervals) {
      seen.stop();
      if (setup.done) { setup.done(); }
      var out = reduce(intervals, opts.period);
      out.scenario = name;
      out.width = window.innerWidth;
      out.height = window.innerHeight;
      out.dpr = window.devicePixelRatio;
      if (setup.target) { out.target = setup.target; }
      out.longTasks = seen.longTasks.length;
      out.longTaskMs = Math.round(seen.longTasks.reduce(function (a, v) { return a + v; }, 0));
      if (seen.animationFrames.length) {
        out.loafFrames = seen.animationFrames.length;
        out.loafStyleLayoutMs = Math.round(seen.animationFrames.reduce(
          function (a, e) { return a + e.styleLayout; }, 0));
        out.loafWorstMs = Math.round(Math.max.apply(null, seen.animationFrames.map(
          function (e) { return e.duration; })));
      }
      return out;
    });
  }

  window.jawnosFrames = { scenarios: SCENARIOS, run: run, renderer: renderer };

  /* The Qt driver cannot await a promise through runJavaScript, so a run parks
   * its JSON here and the driver polls for it. */
  window.__jfRun = function (name, opts) {
    window.__jfResult = "";
    run(name, opts).then(
      function (metrics) { window.__jfResult = JSON.stringify(metrics); },
      function (error) { window.__jfResult = JSON.stringify({ scenario: name, error: String(error) }); });
  };
})();
