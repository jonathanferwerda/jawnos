/* refresh-probe.js - explain a WebUI reload, across a long run.
 *
 * Served by the app (public/js/probe/). The manager layout includes it only
 * when the browser asks for it with ?probe=1 or already carries the cookie this
 * file sets; a normal page load never loads it, and ?probe=0 opts a browser
 * back out. That is the whole point of living here rather than in the console:
 * a reload (the event being measured) wipes a pasted script, but the next page
 * loads this file again from the cookie.
 *
 * It posts one JSON record per event to the collector:
 *     perl scripts/tools/refresh-probe.pl --port 45997 \
 *          --listen '*' --cert server/fullchain.pem --key server/privkey.pem
 *
 * A page on https cannot post to a plain-http collector (mixed content), so the
 * collector presents the app's own certificate and the endpoint is the same
 * host name the browser already trusts. Install once per device:
 *
 *   /manager?probe=1&probe_device=phone
 *          &probe_endpoint=https%3A%2F%2Fdev.example.com%3A45997%2Fevent
 *
 * probe_device and probe_endpoint are remembered in localStorage, so later
 * loads only need the cookie. ?probe=0 clears both and stops the probe.
 *
 * State lives in localStorage, so the last few events of the previous page
 * survive the reload this is meant to explain, even when the beacon that would
 * have sent them was lost with the page.
 */
(function () {
  if (window.jawnosRefreshProbe) { return; }

  var HISTORY = 'jawnos_refresh_probe_history';
  var LAST = 'jawnos_refresh_probe_last';
  var STAMP = 'jawnos_refresh_probe_last_t';
  var ENDPOINT_KEY = 'jawnos_refresh_probe_endpoint';
  var DEVICE_KEY = 'jawnos_refresh_probe_device';
  var COOKIE = 'jawnos_probe';
  // A reload investigation runs for days. The cookie is the opt-in the layout
  // reads to include this file again, so an armed browser renews it on every
  // load instead of falling out after the first two days. The opt-out stays
  // short: ?probe=0 is a deliberate stop, not a state to keep alive.
  var PROBE_AGE = 30 * 86400;
  var OPTOUT_AGE = 2 * 86400;
  var MAX = 400;

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
  function params() {
    var out = {};
    try {
      var search = new URLSearchParams(location.search || '');
      search.forEach(function (v, k) { out[k] = v; });
    } catch (e) {}
    return out;
  }
  // Which socket this was is the one thing the old record could not say: the
  // URL tail was the user agent for every app. The query carries the session
  // token, so the app name and the origin are recorded, never the whole URL.
  function socketApp(url) {
    try {
      var m = String(url).match(/[?&]app=([^&]*)/);
      return m ? decodeURIComponent(m[1]) : '';
    } catch (e) { return ''; }
  }
  function socketOrigin(url) {
    try { return String(url).replace(/^([a-z]+:\/\/[^\/]+).*$/i, '$1'); } catch (e) { return ''; }
  }
  function navType() {
    try {
      var n = performance.getEntriesByType('navigation')[0];
      return n ? n.type : '';
    } catch (e) { return ''; }
  }
  function guessDevice() {
    var ua = navigator.userAgent || '';
    if (/iPad|Tablet/i.test(ua)) { return 'tablet'; }
    if (/iPhone|iPod|Android.*Mobile/i.test(ua)) { return 'phone'; }
    if (/Android/i.test(ua)) { return 'tablet'; }
    if (/Macintosh|Windows NT|Linux|X11|CrOS/i.test(ua)) { return 'laptop'; }
    return '';
  }
  function cookie(value, age) {
    try {
      document.cookie = COOKIE + '=' + value + '; path=/; max-age=' + age
        + '; SameSite=Lax' + (location.protocol === 'https:' ? '; Secure' : '');
    } catch (e) {}
  }
  function cookieValue(name) {
    try {
      var m = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
      return m ? decodeURIComponent(m[1]) : '';
    } catch (e) { return ''; }
  }

  var q = params();

  // An explicit ?probe=1 pins the probe in this browser. The temporary
  // default-on layout includes this file without a param and must not leave a
  // cookie that outlives that window; ?probe=0 records the opt-out instead.
  // A browser that already said yes renews the same cookie on every load: the
  // layout only serves this file because that cookie is there, so a long run
  // must not end when the first two-day window does.
  if (q.probe === '1') { cookie('1', PROBE_AGE); }
  else if (q.probe === '0') { cookie('0', OPTOUT_AGE); }
  else if (cookieValue(COOKIE) === '1') { cookie('1', PROBE_AGE); }

  var injectedEndpoint = (typeof window.jawnos_probe_endpoint === 'string')
    ? window.jawnos_probe_endpoint : '';
  var endpoint = q.probe_endpoint;
  if (endpoint && /^https?:\/\//i.test(endpoint)) { write(ENDPOINT_KEY, endpoint); }
  endpoint = read(ENDPOINT_KEY, '') || '';
  if (!endpoint) {
    endpoint = /^https?:\/\//i.test(injectedEndpoint) ? injectedEndpoint
      : (location.protocol + '//' + location.hostname + ':45997/event');
  }

  var injectedHost = (typeof window.jawnos_probe_host === 'string')
    ? window.jawnos_probe_host : '';
  var device = q.probe_device;
  if (device) { write(DEVICE_KEY, device); }
  device = read(DEVICE_KEY, '') || '';
  if (!device) {
    device = (injectedHost && injectedHost !== 'localhost'
      && injectedHost !== 'localhost.localdomain') ? injectedHost : guessDevice();
  }

  var started = now();
  var timer = 0;
  var alive = true;

  function post(rec) {
    var body = JSON.stringify(rec);
    try {
      if (navigator.sendBeacon) {
        return navigator.sendBeacon(endpoint, new Blob([body], { type: 'text/plain;charset=UTF-8' }));
      }
    } catch (e) {}
    try {
      fetch(endpoint, { method: 'POST', body: body, mode: 'no-cors', keepalive: true });
    } catch (e) {}
  }
  function send(ev, extra) {
    if (!alive) { return null; }
    var rec = {
      t: now(), src: 'browser', ev: ev, device: device,
      hidden: document.hidden ? 1 : 0, path: location.pathname
    };
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
  write(LAST, { t: now(), path: location.pathname, hidden_at: (prev && prev.hidden_at) || 0,
    events: read(HISTORY, []).slice(-12) });
  send('page_load', {
    nav: navType(),
    host: location.hostname,
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
      send('heartbeat', { up_ms: now() - started, hidden: 0 });
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
      var app = socketApp(url);
      var origin = socketOrigin(url);
      socket.addEventListener('open', function () { send('ws_open', { url: tail, app: app, origin: origin, after_ms: now() - opened }); });
      socket.addEventListener('close', function (e) {
        send('ws_close', { url: tail, app: app, origin: origin, code: e.code, reason: String(e.reason || '').slice(0, 60),
          clean: e.wasClean ? 1 : 0, life_ms: now() - opened });
      });
      socket.addEventListener('error', function () { send('ws_error', { url: tail, app: app, origin: origin }); });
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
  var wrapTimer = setInterval(function () { wrapAll(); if (++tries > 120) { clearInterval(wrapTimer); } }, 500);

  // ---- liveness over a long run ----------------------------------------
  // A gap in these is how the report tells "nothing happened" from "the probe
  // was not running", which a 24-hour capture needs to say honestly.
  function heartbeat() { send('heartbeat', { up_ms: now() - started }); }
  timer = setInterval(heartbeat, 60000);
  heartbeat();

  window.jawnosRefreshProbe = {
    url: endpoint,
    device: device,
    test: function () { return send('probe_test', { hello: 1 }); },
    dump: function () { return read(HISTORY, []); },
    disable: function () {
      alive = false;
      if (timer) { clearInterval(timer); }
      cookie('', 0);
      try {
        localStorage.removeItem(HISTORY);
        localStorage.removeItem(LAST);
        localStorage.removeItem(ENDPOINT_KEY);
        localStorage.removeItem(DEVICE_KEY);
      } catch (e) {}
    }
  };
  send('probe_ready');
})();
