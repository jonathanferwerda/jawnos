// Opening test: drive the real manager in headless Chromium and open a row of
// apps, asserting that the tile gives each one its own step of the cascade.
//
//   node qa/ui/open_probe.js <ticket-file> [app,app,...]
//
// The list may contain --reload, which reloads the page and lets the manager
// restore what was on the desk before the remaining apps open. The probe starts
// from an empty desk and closes what it opened at the end.
//
// Chromium is driven over CDP. appWindowOpener is the function the start menu
// calls, so this exercises the real open path and the real server round trip,
// not a synthetic windowMaker call.
//
// Exit 0 when every app opened, every snapshot had one window per slot, and the
// final stack is 0..n-1 with no hole and no two windows in one slot.

const fs = require('fs');
const { spawn } = require('child_process');

const ticketFile = process.argv[2];
const apps = (process.argv[3] || 'notes,clock,weather,power,sound,network,help').split(',');
if (!ticketFile) {
	console.error('usage: open_probe.js <ticket-file> [app,app,...]');
	process.exit(2);
}
const ticket = fs.readFileSync(ticketFile, 'utf8').trim();
if (!/^https?:\/\//.test(ticket)) {
	console.error('open_probe: the ticket file does not hold a ticket URL');
	process.exit(2);
}

const CHROME = process.env.CHROMIUM || '/usr/bin/chromium';
const PORT = Number(process.env.OPEN_PROBE_PORT || 9333);
const PROFILE = process.env.OPEN_PROBE_PROFILE || '/tmp/jawnos-open-probe';
const SETTLE = Number(process.env.OPEN_PROBE_SETTLE || 900);
const RELOAD_WAIT = Number(process.env.OPEN_PROBE_RELOAD_WAIT || 12000);
const sleep = ms => new Promise(r => setTimeout(r, ms));

function launch() {
	fs.rmSync(PROFILE, { recursive: true, force: true });
	const p = spawn(CHROME, [
		'--headless=new', '--no-sandbox', '--disable-gpu',
		'--disable-dev-shm-usage', '--ignore-certificate-errors',
		'--disable-background-networking', '--no-first-run',
		'--window-size=1280,900',
		'--remote-debugging-port=' + PORT,
		'--user-data-dir=' + PROFILE,
		'about:blank'
	], { detached: true, stdio: 'ignore' });
	p.unref();
	return p;
}

async function pageTarget() {
	for (let i = 0; i < 80; i++) {
		try {
			const r = await fetch('http://127.0.0.1:' + PORT + '/json/list');
			const list = await r.json();
			const page = list.find(t => t.type === 'page');
			if (page) { return page; }
		} catch (e) { /* not up yet */ }
		await sleep(250);
	}
	throw new Error('no CDP page target');
}

async function main() {
	const proc = launch();
	const target = await pageTarget();
	const ws = new WebSocket(target.webSocketDebuggerUrl);
	await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

	let id = 0;
	const pending = new Map();
	const errors = [];
	ws.onmessage = e => {
		const m = JSON.parse(e.data);
		if (m.id && pending.has(m.id)) {
			const { res, rej } = pending.get(m.id);
			pending.delete(m.id);
			m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
		} else if (m.method === 'Runtime.exceptionThrown') {
			errors.push((m.params.exceptionDetails.exception || {}).description || m.params.exceptionDetails.text);
		}
	};
	const call = (method, params, ms) => new Promise((res, rej) => {
		const mid = ++id;
		const timer = setTimeout(() => { pending.delete(mid); rej(new Error('CDP timeout: ' + method)); }, ms || 20000);
		pending.set(mid, {
			res: v => { clearTimeout(timer); res(v); },
			rej: e => { clearTimeout(timer); rej(e); }
		});
		ws.send(JSON.stringify({ id: mid, method, params: params || {} }));
	});
	const evaluate = async (expression, ms) => {
		const r = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, ms || 30000);
		if (r.exceptionDetails) {
			throw new Error((r.exceptionDetails.exception || {}).description || r.exceptionDetails.text || 'eval failed');
		}
		return r.result ? r.result.value : undefined;
	};
	const count = () => evaluate("$('.wind').length");
	const read = `(function(){
		return $('.wind').map(function(){
			var el = $(this);
			return {
				app: el.attr('app'), id: el.attr('id'),
				tile: el.attr('tile'), free: el.attr('free'),
				top: el.css('top'), left: el.css('left'),
				width: el.css('width')
			};
		}).get();
	})()`;

	const check = (label, windows, allowHoles) => {
		const slots = {};
		const bad = [];
		for (const w of windows) {
			if (w.tile === undefined || w.tile === null || w.tile === '') { continue; }
			const s = String(w.tile);
			if (!/^\d+$/.test(s)) { bad.push(w.app + ' has tile=' + s); continue; }
			(slots[s] = slots[s] || []).push(w.app);
		}
		const dup = Object.keys(slots).filter(k => slots[k].length > 1);
		if (!allowHoles) {
			const nums = Object.keys(slots).map(Number).sort((a, b) => a - b);
			for (let i = 0; i < nums.length; i++) {
				if (nums[i] !== i) { bad.push('slot ' + i + ' is missing'); break; }
			}
		}
		for (const d of dup) { bad.push('two windows in slot ' + d); }
		if (bad.length) { console.log('FAIL ' + label + ': ' + bad.join('; ')); }
		return { slots, bad };
	};

	await call('Page.enable');
	await call('Runtime.enable');
	await call('Page.navigate', { url: ticket }, 60000);

	let at_manager = false;
	for (let i = 0; i < 120; i++) {
		await sleep(250);
		try {
			at_manager = await evaluate("location.href.indexOf('/manager') >= 0 && typeof appWindowOpener === 'function' && document.readyState !== 'loading'");
		} catch (e) { /* navigating */ }
		if (at_manager) { break; }
	}
	if (!at_manager) { throw new Error('never reached /manager'); }
	await sleep(2000);

	// A reload restores the server's saved windows as their responses arrive, so
	// wait for the desk to stop changing before closing it; otherwise a window
	// still in flight would appear after the close and rejoin the test.
	let prev = -1;
	let stable = 0;
	for (let i = 0; i < 40; i++) {
		const n = await count();
		if (n === prev) { stable += 1; } else { stable = 0; prev = n; }
		if (stable >= 4) { break; }
		await sleep(500);
	}
	for (let i = 0; i < 20; i++) {
		await evaluate(`(function(){
			$('.wind').each(function(){
				try { closeWindow($(this).attr('timestamp')); } catch (e) {}
			});
			sessionStorage.removeItem('window_storage');
			return $('.wind').length;
		})()`);
		await sleep(700);
		if ((await count()) === 0) { break; }
	}
	await sleep(1500);
	const start = await count();
	console.log('START windows=' + start);
	if (start !== 0) { throw new Error('the desk did not clear: ' + start + ' window(s) left'); }

	let failed = false;
	const snapshots = [];
	for (const app of apps) {
		if (app === '--reload') {
			// let the 10s heartbeat save the layout, then reload and let the
			// manager restore what was on the desk
			await sleep(RELOAD_WAIT);
			await call('Page.reload', { ignoreCache: true }, 60000);
			let back = false;
			for (let i = 0; i < 120; i++) {
				await sleep(250);
				try {
					back = await evaluate("location.href.indexOf('/manager') >= 0 && typeof appWindowOpener === 'function' && document.readyState !== 'loading'");
				} catch (e) { back = false; }
				if (back) { break; }
			}
			await sleep(4000);
			const restored = await evaluate(read);
			snapshots.push({ app: '--reload', windows: restored });
			console.log('RELOAD back=' + back + ' restored=' + restored.length);
			if (!back) { failed = true; }
			if (check('restore', restored, true).bad.length) { failed = true; }
			continue;
		}
		let opened = false;
		for (let attempt = 0; attempt < 3 && !opened; attempt++) {
			await evaluate("appWindowOpener(" + JSON.stringify(app) + ", Date.now(), { visible: 'yes' })");
			for (let i = 0; i < 100; i++) {
				await sleep(100);
				try {
					opened = await evaluate("$('.wind[app=" + JSON.stringify(app) + "]').length > 0");
				} catch (e) { opened = false; }
				if (opened) { break; }
			}
		}
		await sleep(SETTLE);
		const windows = await evaluate(read);
		snapshots.push({ app, windows });
		console.log('OPEN ' + app + ' opened=' + opened + ' count=' + windows.length);
		for (const w of windows) {
			console.log('  ' + String(w.app).padEnd(10) + ' tile=' + String(w.tile).padEnd(4)
				+ ' free=' + String(w.free).padEnd(5) + ' top=' + String(w.top).padEnd(8)
				+ ' left=' + String(w.left).padEnd(8) + ' w=' + w.width);
		}
		if (!opened) { failed = true; }
		if (check('open ' + app, windows).bad.length) { failed = true; }
	}

	const last = snapshots.length ? snapshots[snapshots.length - 1].windows : [];
	const final = check('final', last);
	if (final.bad.length) { failed = true; }
	console.log('FINAL count=' + last.length + ' slots=' + JSON.stringify(final.slots));
	if (errors.length) {
		console.log('PAGE ERRORS ' + JSON.stringify(errors.slice(0, 8)));
		failed = true;
	}

	// leave the desk clean for whoever uses the ticket next
	try {
		await evaluate(`(function(){
			$('.wind').each(function(){
				try { closeWindow($(this).attr('timestamp')); } catch (e) {}
			});
			sessionStorage.removeItem('window_storage');
		})()`);
		await sleep(1200);
	} catch (e) { /* the page may already be gone */ }

	ws.close();
	try { process.kill(-proc.pid, 'SIGKILL'); } catch (e) { try { proc.kill('SIGKILL'); } catch (e2) {} }
	console.log(failed ? 'RESULT fail' : 'RESULT pass');
	process.exit(failed ? 1 : 0);
}

main().catch(e => { console.error('open_probe: ' + e.message); process.exit(1); });
