// Chromium CDP smoke probe for the JawnOS QA UI layer.
//
//   node probe.js <debugPort> <urls.json> <outdir>
//
// Visits every URL in one page, collecting console errors, failed requests and
// 4xx assets, then evaluates a small accessibility/layout probe. Screenshots go
// to <outdir>/shots (PNG, then WebP when ImageMagick is present) and the result
// to <outdir>/ui.json.
//
// Chromium is used for breadth, not as the real engine: the desktop app is
// Qt WebEngine, and qa/ui/webkit_probe.py is the engine check. A page that
// passes here can still be wrong in Qt WebEngine.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const [port, urlsFile, outdir] = process.argv.slice(2);
if (!port || !urlsFile || !outdir) {
	console.error('usage: probe.js <debugPort> <urls.json> <outdir>');
	process.exit(2);
}
const urls = JSON.parse(fs.readFileSync(urlsFile, 'utf8'));
const shots = path.join(outdir, 'shots');
fs.mkdirSync(shots, { recursive: true });

const PROBE = `(() => {
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
})()`;

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function listTargets() {
	for (let i = 0; i < 40; i++) {
		try {
			const r = await fetch(`http://127.0.0.1:${port}/json/list`);
			const list = await r.json();
			const page = list.find(t => t.type === 'page');
			if (page) return page;
		} catch (e) { /* not up yet */ }
		await sleep(250);
	}
	throw new Error('no CDP page target');
}

async function main() {
	const target = await listTargets();
	const ws = new WebSocket(target.webSocketDebuggerUrl);
	await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

	let id = 0;
	const pending = new Map();
	const events = [];
	ws.onmessage = e => {
		const m = JSON.parse(e.data);
		if (m.id && pending.has(m.id)) {
			const { res, rej } = pending.get(m.id);
			pending.delete(m.id);
			m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
		} else if (m.method) {
			events.push(m);
		}
	};
	const call = (method, params, ms) => new Promise((res, rej) => {
		const mid = ++id;
		const timer = setTimeout(() => {
			pending.delete(mid);
			rej(new Error('CDP timeout: ' + method));
		}, ms || 20000);
		pending.set(mid, {
			res: v => { clearTimeout(timer); res(v); },
			rej: e => { clearTimeout(timer); rej(e); },
		});
		ws.send(JSON.stringify({ id: mid, method, params: params || {} }));
	});

	await call('Page.enable');
	await call('Network.enable');
	await call('Runtime.enable');
	await call('Log.enable');

	const pages = [];
	for (const url of urls) {
		try {
		const mark = events.length;
		let mainStatus = null;
		let loadResolve;
		const loaded = new Promise(r => { loadResolve = r; });
		const timer = setTimeout(() => loadResolve('timeout'), 25000);
		const onLoad = () => loadResolve('load');
		// Page.loadEventFired arrives as an event; watch the shared buffer.
		const waiter = setInterval(() => {
			for (const ev of events.slice(mark)) {
				if (ev.method === 'Page.loadEventFired') { onLoad(); }
			}
		}, 100);
		await call('Page.navigate', { url });
		const how = await loaded;
		clearTimeout(timer);
		clearInterval(waiter);
		await sleep(1200);

		const mine = events.slice(mark);
		for (const ev of mine) {
			if (ev.method === 'Network.responseReceived'
				&& ev.params.type === 'Document' && mainStatus === null) {
				mainStatus = ev.params.response.status;
			}
		}
		let probe = {};
		try {
			const r = await call('Runtime.evaluate', {
				expression: PROBE, returnByValue: true, awaitPromise: true,
			});
			probe = r.result.value || {};
		} catch (e) { probe = { error: e.message }; }

		const consoleErrors = [];
		const failed = [];
		const badAssets = [];
		for (const ev of mine) {
			if (ev.method === 'Runtime.exceptionThrown') {
				consoleErrors.push(ev.params.exceptionDetails.exception?.description
					|| ev.params.exceptionDetails.text || 'exception');
			}
			if (ev.method === 'Log.entryAdded' && ev.params.entry.level === 'error') {
				consoleErrors.push(ev.params.entry.text);
			}
			if (ev.method === 'Runtime.consoleAPICalled' && ev.params.type === 'error') {
				consoleErrors.push((ev.params.args || []).map(a => a.value ?? a.description).join(' '));
			}
			if (ev.method === 'Network.loadingFailed'
				&& !String(ev.params.errorText || '').includes('ERR_ABORTED')) {
				failed.push(ev.params.errorText || 'failed');
			}
			if (ev.method === 'Network.responseReceived'
				&& ev.params.response.status >= 400
				&& ['Script', 'Stylesheet', 'Image', 'Font'].includes(ev.params.type)) {
				badAssets.push(`${ev.params.type} ${ev.params.response.status} ${ev.params.response.url}`);
			}
		}

		const slug = url.replace(/^https?:\/\/[^/]+/, '').replace(/[^A-Za-z0-9]+/g, '_') || 'root';
		let shot = null;
		try {
			const r = await call('Page.captureScreenshot', { format: 'png' });
			const png = path.join(shots, slug + '.png');
			fs.writeFileSync(png, Buffer.from(r.data, 'base64'));
			shot = png;
			try {
				const webp = path.join(shots, slug + '.webp');
				execFileSync('magick', [png, '-quality', '80', webp], { stdio: 'ignore' });
				fs.unlinkSync(png);
				shot = webp;
			} catch (e) { /* keep the PNG */ }
		} catch (e) { /* no shot */ }

		pages.push({
			url, how, status: mainStatus, probe,
			consoleErrors: consoleErrors.slice(0, 20),
			failed: failed.slice(0, 20),
			badAssets: badAssets.slice(0, 20),
			shot,
		});
		} catch (e) {
			// One page (store, say) must not lose the seven already captured.
			pages.push({ url, error: e.message });
		}
		// write after every page: a later hang must not lose the earlier evidence.
		// Write then rename, so a kill mid-write cannot leave invalid JSON.
		const tmp = path.join(outdir, 'ui.json.tmp');
		fs.writeFileSync(tmp, JSON.stringify({ engine: 'chromium', pages }, null, 1));
		fs.renameSync(tmp, path.join(outdir, 'ui.json'));
	}

	ws.close();
	const out = { engine: 'chromium', pages };
	const tmpOut = path.join(outdir, 'ui.json.tmp');
	fs.writeFileSync(tmpOut, JSON.stringify(out, null, 1));
	fs.renameSync(tmpOut, path.join(outdir, 'ui.json'));
	console.log(JSON.stringify({ pages: pages.length }));
	// The CDP socket can keep the loop alive after close(); do not wait for it.
	process.exit(0);
}

main().catch(e => { console.error('probe: ' + e.message); process.exit(1); });
