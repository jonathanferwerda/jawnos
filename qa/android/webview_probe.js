// Inspect the JawnOS app's WebView over Chrome DevTools Protocol.
//
//   adb -s <serial> forward tcp:<port> localabstract:webview_devtools_remote_<pid>
//   node qa/android/webview_probe.js <port> [settleMs]
//
// Prints ONE line of JSON and exits:
//   0  a page was attached and probed      ({"status":"ok", ...})
//   3  no page in the launch state         ({"status":"skip", ...}) - never a pass
//   1  the devtools port or socket failed  ({"status":"error", ...})
//
// The shape follows .shots/app_cdp.js: /json/list, the first page target, a
// WebSocket, Runtime/Log enabled, then one Runtime.evaluate.
//
// Console errors are only what arrives AFTER attach; a page that logged its
// errors while loading has already lost them. `page_loaded` is therefore based
// on the live DOM (a real URL, a body and a node count), not on the log.

const port = process.argv[2];
const settleMs = Number(process.argv[3] || 1500);

if (!port) {
	process.stdout.write(JSON.stringify({ status: 'error', reason: 'usage: webview_probe.js <port> [settleMs]' }) + '\n');
	process.exit(1);
}

const emit = (doc, code) => {
	process.stdout.write(JSON.stringify(doc) + '\n');
	process.exit(code);
};

const sleep = ms => new Promise(r => setTimeout(r, ms));

// The page probe: what is actually loaded, how big it is, and whether the
// start menu (templates/start_menu/start_menu.html.ep -> #start_menu) is there.
// A manager shell loads the menu hidden, so `visible` is reported separately
// from `found`.
const PAGE_PROBE = `(() => {
	const doc = document;
	const out = {};
	out.url = String(location.href);
	out.title = doc.title || '';
	out.readyState = doc.readyState;
	out.nodes = doc.getElementsByTagName('*').length;
	out.scripts = doc.getElementsByTagName('script').length;
	out.bodyTextLength = (doc.body && doc.body.innerText ? doc.body.innerText.length : 0);
	out.is_manager = /\\/manager(\\b|\\/|\\?|$)/.test(location.href);
	const selectors = ['#start_menu', '#start-menu', '#startMenu', '.start_menu'];
	out.start_menu = { found: false, selector: null, visible: false };
	for (const s of selectors) {
		const el = doc.querySelector(s);
		if (!el) continue;
		const st = getComputedStyle(el);
		out.start_menu = {
			found: true,
			selector: s,
			visible: st.display !== 'none' && st.visibility !== 'hidden' && el.offsetParent !== null
		};
		break;
	}
	out.app_window_opener = typeof window.appWindowOpener;
	out.jawnosT = typeof window.jawnosT;
	return out;
})()`;

(async () => {
	let list;
	try {
		list = await (await fetch('http://127.0.0.1:' + port + '/json/list')).json();
	} catch (e) {
		emit({ status: 'error', reason: 'devtools port ' + port + ' did not answer: ' + e.message }, 1);
	}
	if (!Array.isArray(list)) {
		emit({ status: 'error', reason: 'devtools /json/list was not an array' }, 1);
	}

	const targets = list.map(t => ({
		type: t.type || '',
		url: t.url || '',
		title: t.title || ''
	}));
	const pages = list.filter(t => t.type === 'page');
	if (!pages.length) {
		emit({
			status: 'skip',
			reason: 'no WebView page target in the launch state',
			targets
		}, 3);
	}

	const page = pages[0];
	const ws = new WebSocket(page.webSocketDebuggerUrl);
	try {
		await new Promise((res, rej) => {
			ws.onopen = res;
			ws.onerror = () => rej(new Error('websocket did not open'));
		});
	} catch (e) {
		emit({ status: 'error', reason: e.message, targets }, 1);
	}

	let id = 0;
	const pending = new Map();
	const consoleErrors = [];
	const exceptions = [];
	ws.onmessage = e => {
		let m;
		try { m = JSON.parse(e.data); } catch (_) { return; }
		if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); return; }
		if (m.method === 'Runtime.consoleAPICalled' && /error|assert|warning/.test(m.params.type || '')) {
			const text = (m.params.args || []).map(a => a.value !== undefined ? String(a.value) : (a.description || a.type)).join(' ');
			if (consoleErrors.length < 20) consoleErrors.push({ type: m.params.type, text });
		} else if (m.method === 'Runtime.exceptionThrown') {
			const d = m.params.exceptionDetails || {};
			if (exceptions.length < 20) exceptions.push(d.text || (d.exception && d.exception.description) || 'exception');
		} else if (m.method === 'Log.entryAdded') {
			const en = m.params.entry || {};
			if (en.level === 'error' && consoleErrors.length < 20) consoleErrors.push({ type: 'log', text: en.text || '' });
		}
	};

	const call = (method, params) => new Promise((res, rej) => {
		const mid = ++id;
		const timer = setTimeout(() => { pending.delete(mid); rej(new Error(method + ' timed out')); }, 15000);
		pending.set(mid, m => {
			clearTimeout(timer);
			m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
		});
		ws.send(JSON.stringify({ id: mid, method, params: params || {} }));
	});

	try {
		await call('Runtime.enable');
		await call('Log.enable');
		await call('Page.enable');
		await sleep(settleMs);
		const r = await call('Runtime.evaluate', {
			expression: PAGE_PROBE, returnByValue: true, awaitPromise: false, userGesture: false
		});
		if (r.exceptionDetails) {
			emit({ status: 'error', reason: 'page throw in probe', exception: JSON.stringify(r.exceptionDetails) }, 1);
		}
		const probe = r.result.value || {};
		const loaded = probe.url && !/^about:blank/.test(probe.url) && probe.nodes > 20;
		emit({
			status: 'ok',
			target: { url: page.url || '', title: page.title || '', type: page.type || '' },
			page_loaded: !!loaded,
			probe,
			console_errors: consoleErrors,
			exceptions
		}, 0);
	} catch (e) {
		emit({ status: 'error', reason: e.message, target: { url: page.url || '' } }, 1);
	} finally {
		try { ws.close(); } catch (_) {}
	}
})().catch(e => emit({ status: 'error', reason: String(e && e.message || e) }, 1));
