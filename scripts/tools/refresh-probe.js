/* refresh-probe.js - explain a WebUI reload.
 *
 * Paste into the page's console (DevTools) or load it after the app bundle.
 * It posts one JSON record per event to the Perl half:
 *     perl scripts/tools/refresh-probe.pl --port 45997
 * Run that collector on the same machine as the browser (the page posts to
 * 127.0.0.1), then read the capture with --report.
 *
 * What it watches: the navigation type of each load, hide/wake/freeze, socket
 * open/close, and the app's own reload paths (jawnosReloadWhenReady,
 * jawnosUpdateQuietReload, jawnosRevisionArrived, websocketRebuild, ...), each
 * with the stack that called it. State lives in localStorage, so the last few
 * events of the previous page survive the reload that this is meant to explain.
 */
(function () {
  if (window.jawnosRefreshProbe) { return; }

  var URL_ = 'http://127.0.0.1:45997/event';
  var HISTORY = 'jawnos_refresh_probe_history';
  var LAST = 'jawnos_refresh_probe_last';
  var STAMP = 'jawnos_refresh_probe_last_t';
  var MAX = 300;

  function now() { return Date.now(); }
  function read(key, dflt) {
    try {
      var v = localStorage.getItem(key);
      return v ? JSON.parse(v) : dflt;
    } catch (e) { return dflt; }
  }
  function write(key, val) {
    try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) {}
  }
  function navType() {
    try {
      var n = performance.getEntriesByType('navigation')[0];
      return n ? n.type : '';
    } catch (e) { return ''; }
  }
  function post(rec) {
    var body = JSON.stringify(rec);
    try {
      if (navigator.sendBeacon) {
        return navigator.sendBeacon(URL_, new Blob([body], { type: 'text/plain;charset=UTF-8' }));
      }
    } catch (e) {}
    try {
      fetch(URL_, { method: 'POST', body: body, mode: 'no-cors', keepalive: true });
    } catch (e) {}
  }
  function send(ev, extra) {
    var rec = { t: now(), src: 'browser', ev: ev, hidden: document.hidden ? 1 : 0 };
    if (extra) {
      for (var k in extra) {
        if (Object.prototype.hasOwnProperty.call(extra, k)) { rec[k] = extra[k]; }
      }
    }
    var hist = read(HISTORY, []);
    hist.push({ t: rec.t, ev: ev });
    if (hist.length > MAX) { hist = hist.slice(-MAX); }
    write(HISTORY, hist);
    try { localStorage.setItem(STAMP, String(rec.t)); } catch (e) {}
    post(rec);
    return rec;
  }

  // ---- what this load is ------------------------------------------------
  var prev = read(LAST, null);
  var lastT = 0;
  try { lastT = parseFloat(localStorage.getItem(STAMP) || '0') || 0; } catch (e) {}
  write(LAST, { t: now(), href: location.href, hidden_at: (prev && prev.hidden_at) || 0,
    events: read(HISTORY, []).slice(-12) });
  send('page_load', {
    nav: navType(),
    href: location.href,
    version: (typeof jawnos_version !== 'undefined') ? jawnos_version : '',
    autoreload: (function () { try { return localStorage.getItem('jawnos_update_autoreload') || 'off'; } catch (e) { return '?'; } })(),
    since_prev_ms: lastT ? (now() - lastT) : null,
    prev_uptime_ms: prev ? (now() - prev.t) : null,
    prev_hidden_ms: (prev && prev.hidden_at) ? (now() - prev.hidden_at) : null,
    prev_events: prev ? (prev.events || []) : [],
    ua: navigator.userAgent
  });

  // ---- waking and hiding ------------------------------------------------
  var hiddenAt = 0;
  document.addEventListener('visibilitychange', function () {
    var last = read(LAST, {}) || {};
    if (document.hidden) {
      hiddenAt = now();
      last.hidden_at = hiddenAt;
      write(LAST, last);
      send('hidden');
    } else {
      send('visible', { away_ms: hiddenAt ? (now() - hiddenAt) : null });
    }
  });
  window.addEventListener('pageshow', function (e) { send('pageshow', { persisted: e.persisted ? 1 : 0 }); });
  window.addEventListener('pagehide', function (e) { send('pagehide', { persisted: e.persisted ? 1 : 0 }); });
  document.addEventListener('freeze', function () { send('freeze'); });
  document.addEventListener('resume', function () { send('resume'); });
  window.addEventListener('online', function () { send('online'); });
  window.addEventListener('offline', function () { send('offline'); });
  window.addEventListener('beforeunload', function () { send('beforeunload'); });

  // ---- socket life ------------------------------------------------------
  if (window.WebSocket) {
    var NativeWS = window.WebSocket;
    var Wrapped = function (url, protocols) {
      var socket = (protocols === undefined) ? new NativeWS(url) : new NativeWS(url, protocols);
      var opened = now();
      var tail = String(url).replace(/^[a-z]+:\/\//, '').slice(-40);
      socket.addEventListener('open', function () { send('ws_open', { url: tail, after_ms: now() - opened }); });
      socket.addEventListener('close', function (e) {
        send('ws_close', { url: tail, code: e.code, reason: String(e.reason || '').slice(0, 60),
          clean: e.wasClean ? 1 : 0, life_ms: now() - opened });
      });
      socket.addEventListener('error', function () { send('ws_error', { url: tail }); });
      return socket;
    };
    Wrapped.prototype = NativeWS.prototype;
    Wrapped.CONNECTING = 0; Wrapped.OPEN = 1; Wrapped.CLOSING = 2; Wrapped.CLOSED = 3;
    try { window.WebSocket = Wrapped; } catch (e) {}
  }

  // ---- the app's own reload paths --------------------------------------
  var CALLS = ['jawnosRevisionArrived', 'jawnosUpdateQuietReload', 'jawnosReloadWhenReady',
               'jawnosUpdateInPlace', 'jawnosUpdateWindows', 'websocketRebuild', 'websocketWake'];
  var wrapped = {};
  function stackOf() {
    var s = (new Error()).stack || '';
    return s.split('\n').slice(2, 5).map(function (l) {
      return l.replace(/^\s+at\s+/, '').replace(/\(.*\//, '(').slice(0, 140);
    });
  }
  function wrapAll() {
    CALLS.forEach(function (name) {
      if (wrapped[name]) { return; }
      var fn = window[name];
      if (typeof fn !== 'function') { return; }
      wrapped[name] = 1;
      window[name] = function () {
        var extra = { name: name, stack: stackOf() };
        if (name === 'jawnosRevisionArrived') {
          extra.parts = arguments[0];
          extra.their_version = arguments[1];
        }
        send('call:' + name, extra);
        return fn.apply(this, arguments);
      };
    });
  }
  wrapAll();
  var tries = 0;
  var timer = setInterval(function () { wrapAll(); if (++tries > 120) { clearInterval(timer); } }, 500);

  window.jawnosRefreshProbe = {
    url: URL_,
    test: function () { return send('probe_test', { hello: 1 }); },
    dump: function () { return read(HISTORY, []); },
    clear: function () {
      try { localStorage.removeItem(HISTORY); localStorage.removeItem(LAST); } catch (e) {}
    }
  };
  send('probe_ready');
})();
