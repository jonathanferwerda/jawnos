// One fenced UI attempt for the l6 UX loop.
//
//   node attempt.js <debugPort> <url> <noteJson> <outdir>
//
// Opens the Notes app in the QA copy, waits for it, looks for the note's text,
// clicks the JawnOS chip when it is on screen, and records the evidence the
// rubric needs: steps, where it got stuck, console errors and a screenshot.
// It never touches the live house; the URL is the QA instance.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const [port, url, noteFile, outdir] = process.argv.slice(2);
if (!port || !url || !noteFile || !outdir) {
	console.error('usage: attempt.js <debugPort> <url> <noteJson> <outdir>');
	process.exit(2);
}
const note = JSON.parse(fs.readFileSync(noteFile, 'utf8'));
fs.mkdirSync(path.join(outdir, 'shots'), { recursive: true });

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function pageTarget() {
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
	const target = await pageTarget();
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
	const evaluate = async expression => {
		const r = await call('Runtime.evaluate', {
			expression, returnByValue: true, awaitPromise: true,
		});
		return r.result.value;
	};

	await call('Page.enable');
	await call('Network.enable');
	await call('Runtime.enable');
	await call('Log.enable');

	const steps = [];
	let stuck = '';
	let status = null;
	const mark = events.length;

	steps.push('navigate ' + url);
	await call('Page.navigate', { url });
	await sleep(2200);
	for (const ev of events.slice(mark)) {
		if (ev.method === 'Network.responseReceived'
			&& ev.params.type === 'Document' && status === null) {
			status = ev.params.response.status;
		}
	}

	const needle = (note.text || '').trim().slice(0, 60).replace(/\s+/g, ' ');
	const probe = await evaluate(`(() => {
		const text = (document.body && document.body.innerText) || '';
		const norm = text.replace(/\\s+/g, ' ');
		const chips = [...document.querySelectorAll('button,a,[role="button"]')]
			.filter(e => (e.innerText || '').trim());
		const jawn = chips.find(e => /^JawnOS$/i.test((e.innerText || '').trim()))
			|| chips.find(e => /JawnOS/i.test((e.innerText || '').trim()));
		const note = ${JSON.stringify(needle)};
		return {
			title: document.title,
			hasMenu: !!document.getElementById('start_menu_toggle'),
			nodes: document.querySelectorAll('*').length,
			noteVisible: note.length ? norm.indexOf(note) !== -1 : false,
			jawnChip: !!jawn,
			chips: chips.slice(0, 24).map(e => (e.innerText || '').trim()).slice(0, 24)
		};
	})()`);

	if (!probe.hasMenu) stuck = 'the manager shell (start menu) did not render';
	else if (!probe.noteVisible) stuck = 'the note text was not visible on the Notes page';
	else steps.push('found the note text');
	if (probe.jawnChip) {
		await evaluate(`(() => {
			const e = [...document.querySelectorAll('button,a,[role="button"]')]
				.find(x => /^JawnOS$/i.test((x.innerText || '').trim()));
			if (e) e.click();
			return !!e;
		})()`);
		steps.push('clicked the JawnOS chip');
		await sleep(900);
	} else {
		steps.push('JawnOS chip not found');
	}

	const consoleErrors = [];
	for (const ev of events.slice(mark)) {
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
	}

	let screenshot = null;
	try {
		const slug = (note.id || 'note').replace(/[^A-Za-z0-9]+/g, '_');
		const r = await call('Page.captureScreenshot', { format: 'png' });
		const png = path.join(outdir, 'shots', slug + '.png');
		fs.writeFileSync(png, Buffer.from(r.data, 'base64'));
		screenshot = png;
		try {
			const webp = path.join(outdir, 'shots', slug + '.webp');
			execFileSync('magick', [png, '-quality', '80', webp], { stdio: 'ignore' });
			fs.unlinkSync(png);
			screenshot = webp;
		} catch (e) { /* keep the PNG */ }
	} catch (e) { /* no shot */ }

	const result = {
		id: note.id, url, status,
		steps, stuck,
		console_errors: consoleErrors.slice(0, 20),
		screenshot,
		probe,
	};
	fs.writeFileSync(path.join(outdir, 'attempt.json'),
		JSON.stringify(result, null, 1));
	ws.close();
	console.log(JSON.stringify({ id: note.id, stuck: !!stuck }));
	process.exit(0);
}

main().catch(e => {
	const dir = process.argv[5] || '.';
	try {
		fs.mkdirSync(dir, { recursive: true });
		fs.writeFileSync(path.join(dir, 'attempt.json'), JSON.stringify({
			id: (process.argv[4] ? JSON.parse(fs.readFileSync(process.argv[4], 'utf8')).id : ''),
			steps: [], stuck: 'browser attempt failed: ' + e.message,
			console_errors: [], screenshot: null,
		}, null, 1));
	} catch (_) { /* nothing else to do */ }
	console.error('attempt: ' + e.message);
	process.exit(1);
});
