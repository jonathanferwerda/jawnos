#!/usr/bin/env node
// Capture the 1920x1080 gallery scenes from the live JawnOS guest over CDP.
//
//   CDP_PORT=9225 \
//   JAWNOS_URL=https://127.0.0.1:14650/manager \
//   OUT=.shots/scenes-live \
//   node scripts/gallery/capture.mjs
//
// The browser must already be open on the guest through the loopback tunnel
// (scripts/gallery/run.sh starts both). Each scene's real window rect is saved
// to OUT/rects.json so the publisher can crop without hand-measured numbers.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MANIFEST = process.env.SCENES || path.join(HERE, 'scenes.json');
const CDP_PORT = process.env.CDP_PORT || '9225';
const BASE = process.env.JAWNOS_URL || 'https://127.0.0.1:14650/manager';
const OUT = process.env.OUT || '.shots/scenes-live';
const ONLY = (process.env.ONLY || '').split(',').map((s) => s.trim()).filter(Boolean);
const TICKET_COOKIE = process.env.TICKET_COOKIE || '';
const TICKET_COOKIE_NAME = process.env.TICKET_COOKIE_NAME || '';

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const defaults = manifest.defaults || {};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync(OUT, { recursive: true });

const wanted = (id) => !ONLY.length || ONLY.some((token) => id.includes(token));

const getJson = (p) => new Promise((resolve, reject) => {
  http.get({ host: '127.0.0.1', port: CDP_PORT, path: p }, (res) => {
    let body = '';
    res.on('data', (d) => { body += d; });
    res.on('end', () => { try { resolve(JSON.parse(body)); } catch (e) { reject(e); } });
  }).on('error', reject);
});

(async () => {
  let targets = [];
  for (let i = 0; i < 40 && !targets.length; i++) {
    try { targets = (await getJson('/json/list')).filter((t) => t.type === 'page'); } catch (e) { /* not up yet */ }
    if (!targets.length) await sleep(500);
  }
  if (!targets.length) { console.error('capture: no CDP page target on port ' + CDP_PORT); process.exit(2); }

  const ws = new WebSocket(targets[0].webSocketDebuggerUrl);
  let seq = 0;
  const pending = new Map();
  const errors = [];
  ws.onmessage = (event) => {
    const m = JSON.parse(event.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    else if (m.method === 'Runtime.exceptionThrown') {
      const text = (m.params.exceptionDetails.exception || {}).description || m.params.exceptionDetails.text || '';
      errors.push(text.split('\n')[0].slice(0, 200));
    }
  };
  await new Promise((resolve) => { ws.onopen = resolve; });
  const send = (method, params = {}) => new Promise((resolve) => {
    const id = ++seq;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });
  const ev = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.result && r.result.exceptionDetails) {
      return 'ERR: ' + ((r.result.exceptionDetails.exception || {}).description || r.result.exceptionDetails.text || '').slice(0, 200);
    }
    return r.result ? r.result.result.value : undefined;
  };
  const waitFor = async (expression, ms = 20000) => {
    const started = Date.now();
    while (Date.now() - started < ms) {
      if (await ev(expression)) return true;
      await sleep(250);
    }
    return false;
  };
  const shot = async (id) => {
    const r = await send('Page.captureScreenshot', { format: 'png', fromSurface: true });
    fs.writeFileSync(path.join(OUT, id + '.png'), Buffer.from(r.result.data, 'base64'));
  };
  const windowRect = () => ev("(function(){var w=$('.wind').last(); if(!w.length) return null; var r=w[0].getBoundingClientRect(); return [Math.round(r.x),Math.round(r.y),Math.round(r.width),Math.round(r.height)];})()");

  const ready = "typeof response === 'object' && response && response.appts && response.appts.__specs";
  const prep = async (opts = {}) => {
    const settings = {
      scope: opts.scope || 'day',
      sorts: opts.sorts || 'timestamp',
      layout: opts.layout || 'timeline',
      filter: 'all',
      project: 'all',
      account: 'all',
      background_images: opts.bg || 'off',
      background_images_opacity: opts.opacity || '0.45'
    };
    await ev(`(function(){
      var s = ${JSON.stringify(settings)};
      Object.keys(s).forEach(function (k) { localStorage.setItem(k, s[k]); });
      localStorage.removeItem('timeshift'); localStorage.removeItem('timeshift_scope');
      localStorage.removeItem('time_machine');
      return 'prepped';
    })()`);
    if (opts.theme) {
      await ev(`new Promise(function(res){ $.post('/manager/setting_setter', { app:'misc', setting:'appearance_theme', value:${JSON.stringify(opts.theme)}, device:'computer', timestamp:Date.now() }, function(){ res(1); }); })`);
    }
  };

  const reload = async () => {
    await send('Page.reload', { ignoreCache: true });
    await waitFor(ready, 25000);
    await sleep(1500);
    await waitFor("Object.keys(response.appts).filter(function(k){return k[0] != '_';}).length > 6", 12000);
  };

  const closeWindows = () => ev("$('.wind').remove(); $('#taskbar_windows').empty();");

  const openApp = async (kind, rect, z) => {
    const before = await ev("$('.wind').length");
    if (kind === 'email') {
      await ev("$.ajax({url:'/manager/email',type:'GET',data:{timestamp:Date.now(),window_maker:'yes'},success:function(r){windowMaker(r);}})");
    } else if (kind === 'people') {
      await ev("typeof peopleOpener === 'function' && peopleOpener()");
    } else if (kind === 'clock') {
      await ev("typeof jawnosClockOpen === 'function' && jawnosClockOpen('alarm')");
    } else if (kind === 'marker') {
      await ev("$.ajax({url:'/manager/marker',type:'GET',data:{window_maker:'yes',app:(typeof topWindow==='function'?topWindow('marker'):'marker'),timestamp:Date.now(),browser_tab_id:(typeof bti!=='undefined'?bti:'')},success:function(r){windowMaker(r); if(typeof markerInit==='function')markerInit();}})");
    } else if (kind === 'synth') {
      await ev("$.ajax({url:'/manager/synth',type:'GET',data:{timestamp:Date.now(),window_maker:'yes'},success:function(r){windowMaker(r); if(typeof pianoInit==='function')pianoInit();}})");
    } else {
      await ev(`typeof appWindowOpener === 'function' ? appWindowOpener(${JSON.stringify(kind)}, Date.now(), {visible:'yes'}) : 0`);
    }
    // People walks the crest and the construct index before it draws; on a cold
    // worker that can pass 12 s, so give it its own budget.
    const opened = await waitFor(`$('.wind').length > ${before}`, kind === 'people' ? 45000 : 12000);
    if (!opened) return false;
    const box = rect || defaults.window || [77, 97, 1766, 886];
    await ev(`(function(){
      var w = $('.wind').last();
      if (!w.length) return 0;
      w.css({ width: '${box[2]}px', height: '${box[3]}px', left: '${box[0]}px', top: '${box[1]}px', zIndex: ${z || 40} });
      return 1;
    })()`);
    await sleep(kind === 'gallery' ? 4500 : 2200);
    await waitFor("(function(){var w=$('.wind').last(); if(!w.length) return 0; var t=(w[0].innerText||'').replace(/\\s+/g,' ').trim(); var c=w.find('canvas'); return t.length > 40 || (c.length && c[0].width > 50);})()", 12000);
    return true;
  };

  await send('Page.enable');
  await send('Runtime.enable');
  await send('Network.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  // run.sh consumes the citizen ticket and passes its session cookie; without
  // it the guest's loopback is a resident and People renders empty.
  if (TICKET_COOKIE && TICKET_COOKIE_NAME) {
    const cookie = await send('Network.setCookie', {
      name: TICKET_COOKIE_NAME, value: TICKET_COOKIE, url: new URL(BASE).origin,
      path: '/', secure: true, httpOnly: true, sameSite: 'Lax'
    });
    if (!(cookie.result && cookie.result.success)) console.error('capture: warning: the citizen cookie was not accepted');
  }
  await send('Page.navigate', { url: BASE });
  await sleep(2000);

  const title = await ev('document.title');
  if (!(await waitFor(ready, 30000))) {
    console.error('capture: the manager never became ready (title: ' + title + ').');
    console.error('capture: is the browser on the guest loopback tunnel? The Gate/app-required page means it is not.');
    process.exit(3);
  }

  // Start every run from the same layout and theme: the previous run left the
  // last layout's theme behind (the app scenes otherwise inherit it). A
  // composite/layout first scene already resets both in its own prep.
  const firstWanted = manifest.scenes.find((s) => wanted(s.id));
  if (defaults.theme && firstWanted && (firstWanted.kind === 'app' || firstWanted.kind === 'start-menu')) {
    await prep({ layout: 'timeline', scope: 'day', sorts: 'timestamp', bg: 'off', theme: defaults.theme });
    await reload();
  }

  const rects = {};
  const results = [];
  const startedAll = Date.now();

  for (const scene of manifest.scenes) {
    if (!wanted(scene.id)) continue;
    const started = Date.now();
    let ok = true;
    let rect = null;

    if (scene.kind === 'app') {
      await closeWindows();
      await sleep(300);
      ok = await openApp(scene.app, scene.window);
      rect = await windowRect();
      await sleep(scene.settle || defaults.settle || 2400);
    }
    else if (scene.kind === 'composite') {
      await prep(Object.assign({ theme: defaults.theme }, scene.prep || {}));
      await reload();
      await closeWindows();
      for (const spec of scene.windows || []) {
        ok = await openApp(spec.app, spec.rect, spec.z) && ok;
      }
      await sleep(2500);
    }
    else if (scene.kind === 'start-menu') {
      await closeWindows();
      await ev("typeof appWindowOpener === 'function' && appWindowOpener('gallery', Date.now()); typeof appWindowOpener === 'function' && appWindowOpener('handbook', Date.now())");
      await sleep(3500);
      await closeWindows();
      await ev("document.querySelector('#start_menu_toggle') && document.querySelector('#start_menu_toggle').click()");
      await sleep(1500);
      await ev("var m=document.querySelector('#start_menu'); if(m){m.style.left='24px';m.style.top='64px';m.style.right='auto';m.style.width='640px';}");
      await sleep(400);
    }
    else if (scene.kind === 'layout') {
      await prep(scene.prep || {});
      await reload();
      if ((scene.prep || {}).layout === 'continent') {
        await waitFor("typeof jawnosContinentMap !== 'undefined' && jawnosContinentMap && jawnosContinentMap.__framed", 15000);
      } else if ((scene.prep || {}).layout === 'desk') {
        await waitFor("typeof desk_visible !== 'undefined' && desk_visible && document.querySelectorAll('#desk_layer .folders_file').length > 2", 15000);
      }
      await sleep(3000);
    }

    await shot(scene.id);
    if (scene.kind === 'start-menu') {
      await ev("document.querySelector('#start_menu_toggle') && document.querySelector('#start_menu_toggle').click()");
    }
    rects[scene.id] = rect;
    const ms = Date.now() - started;
    results.push({ id: scene.id, ok, rect, ms, site: !!((scene.site || {}).include) });
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${scene.id}  ${(ms / 1000).toFixed(1)}s  ${rect ? rect.join(',') : 'full'}`);
  }

  fs.writeFileSync(path.join(OUT, 'rects.json'), JSON.stringify(rects, null, 2) + '\n');
  fs.writeFileSync(path.join(OUT, 'shots.json'), JSON.stringify({ base: BASE, scenes: results, errors: errors.slice(-10) }, null, 2) + '\n');
  const failedSites = results.filter((r) => r.site && !r.ok);
  console.log(`capture: ${results.length} scenes, ${((Date.now() - startedAll) / 1000).toFixed(1)}s, ${failedSites.length} failed site scene(s)`);
  if (errors.length) console.log('capture: page exceptions: ' + errors.slice(-3).join(' | '));
  ws.close();
  process.exit(failedSites.length ? 1 : 0);
})().catch((e) => { console.error('capture: ' + e.message); process.exit(2); });
