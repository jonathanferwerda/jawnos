// translate.js - the dependency-free interface translator.
//
// Two layers:
//   - window.jawnos_lang      the hand-written core labels for the chosen
//                              interface language (loaded by the layout)
//   - window.jawnos_ui_lang   an optional generated catalog, or the map built by
//                              the Guide's on-demand translation engine
//
// Exact English strings are replaced in text nodes and visible attributes, at
// load and whenever the manager inserts new HTML. User-content containers and
// editable fields are skipped. If no catalog is present the file is inert.

(function () {
	'use strict';

	function t(key) {
		var s = key;
		var ui = window.jawnos_ui_lang || {};
		if (ui[key] !== undefined) {
			s = ui[key];
		}
		else if (window.jawnos_lang && window.jawnos_lang[key] !== undefined) {
			s = window.jawnos_lang[key];
		}
		for (var i = 1; i < arguments.length; i++) {
			s = s.split('{' + (i - 1) + '}').join(arguments[i]);
		}
		return s;
	}
	window.jawnosT = t;

	var TEXT_SKIP = 'script,style,noscript,code,pre,textarea,input,[contenteditable="true"],[contenteditable=""],[data-no-translate],.article_content,.item_description,.model_description,.option_description,.description,.note,.mail_body,.email_body,.chat_message,.terminal,.editor_content,.syntax,.code_block';
	var ATTR_SKIP = 'script,style,noscript,code,pre,[contenteditable="true"],[contenteditable=""],[data-no-translate]';
	var ATTRS = ['hint', 'placeholder', 'title', 'alt', 'aria-label'];
	var observer = null;

	function catalog() {
		window.jawnos_ui_lang = window.jawnos_ui_lang || {};
		return window.jawnos_ui_lang;
	}

	// Restore the on-demand translations this browser already paid for. The
	// interface's own catalog is loaded by the layout; this adds the target the
	// person last asked the Guide to translate the window into.
	(function restore() {
		var code = window.jawnos_lang_code || '';
		try {
			var saved_target = localStorage.getItem('jawnos_translation_target') || '';
			var codes = [code, saved_target];
			for (var i = 0; i < codes.length; i++) {
				if (!codes[i] || codes[i] === 'en') { continue; }
				var raw = localStorage.getItem('jawnos_ui_lang_' + codes[i]);
				if (!raw) { continue; }
				var map = JSON.parse(raw);
				if (!map || typeof map !== 'object') { continue; }
				for (var k in map) {
					if (Object.prototype.hasOwnProperty.call(map, k) && map[k]) {
						catalog()[k] = map[k];
					}
				}
			}
		}
		catch (e) { /* storage can be blocked; translation still works in memory */ }
	})();

	function skipped(el, selector) {
		return !!(el && el.closest && el.closest(selector));
	}

	function normalize(s) {
		return String(s).replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
	}

	function translated(value) {
		var key = normalize(value);
		if (!key) { return null; }
		var out = catalog()[key];
		return (out !== undefined && out !== key) ? out : null;
	}

	function translateText(node) {
		if (!node || node.nodeType !== 3) { return false; }
		if (skipped(node.parentElement, TEXT_SKIP)) { return false; }
		var raw = node.nodeValue;
		var m = raw.match(/^(\s*)([\s\S]*?)(\s*)$/);
		if (!m) { return false; }
		var out = translated(m[2]);
		if (out === null || out === undefined) { return false; }
		node.nodeValue = m[1] + out + m[3];
		return true;
	}

	function translateAttr(el, name) {
		if (!el || !el.getAttribute) { return false; }
		if (skipped(el, ATTR_SKIP)) { return false; }
		var raw = el.getAttribute(name);
		if (!raw) { return false; }
		var out = translated(raw);
		if (out === null || out === undefined) { return false; }
		el.setAttribute(name, out);
		return true;
	}

	function walk(node) {
		if (!node) { return; }
		if (node.nodeType === 3) { translateText(node); return; }
		if (node.nodeType !== 1) { return; }
		if (skipped(node, TEXT_SKIP)) { return; }
		for (var a = 0; a < ATTRS.length; a++) {
			translateAttr(node, ATTRS[a]);
		}
		for (var c = node.firstChild; c; c = c.nextSibling) {
			walk(c);
		}
	}

	// Collect the visible English strings the engine does not know yet. The same
	// skip rules apply, so a note or an article is never sent for translation.
	function collectStrings(root, limit, char_limit) {
		root = root || document.body;
		limit = limit || 400;
		char_limit = char_limit || 40000;
		var known = {};
		var cat = catalog();
		for (var k in cat) {
			if (Object.prototype.hasOwnProperty.call(cat, k)) {
				known[k] = 1;
				known[cat[k]] = 1;
			}
		}
		var out = [];
		var seen = {};
		var chars = 0;
		function add(value) {
			if (out.length >= limit) { return; }
			var key = normalize(value);
			if (!key || seen[key] || known[key]) { return; }
			if (!/[A-Za-z\u00C0-\uFFFF]/.test(key)) { return; }
			if (chars + key.length > char_limit) { return; }
			seen[key] = 1;
			chars += key.length;
			out.push(key);
		}
		function scan(node) {
			if (!node || out.length >= limit) { return; }
			if (node.nodeType === 3) {
				if (!skipped(node.parentElement, TEXT_SKIP)) { add(node.nodeValue); }
				return;
			}
			if (node.nodeType !== 1) { return; }
			if (skipped(node, TEXT_SKIP)) { return; }
			for (var a = 0; a < ATTRS.length; a++) {
				if (!skipped(node, ATTR_SKIP)) {
					var v = node.getAttribute(ATTRS[a]);
					if (v) { add(v); }
				}
			}
			for (var c = node.firstChild; c && out.length < limit; c = c.nextSibling) {
				scan(c);
			}
		}
		scan(root);
		return out;
	}

	function applyTranslations(map, root) {
		if (!map || typeof map !== 'object') { return 0; }
		var cat = catalog();
		var n = 0;
		for (var k in map) {
			if (!Object.prototype.hasOwnProperty.call(map, k)) { continue; }
			var v = map[k];
			if (typeof v !== 'string' || !v.length || v === k) { continue; }
			cat[k] = v;
			n++;
		}
		walk(root || document.body);
		startObserver();
		return n;
	}

	function persist(code, map) {
		if (!code) { return; }
		try {
			var key = 'jawnos_ui_lang_' + code;
			var old = JSON.parse(localStorage.getItem(key) || '{}') || {};
			for (var k in map) {
				if (Object.prototype.hasOwnProperty.call(map, k) && map[k]) { old[k] = map[k]; }
			}
			localStorage.setItem(key, JSON.stringify(old));
			localStorage.setItem('jawnos_translation_target', code);
		}
		catch (e) { /* storage can be blocked; the in-memory map still applies */ }
	}

	function post(url, data, ok, fail) {
		if (window.jQuery && window.jQuery.post) {
			window.jQuery.post(url, data, ok).fail(fail);
			return;
		}
		var body = Object.keys(data).map(function (k) {
			return encodeURIComponent(k) + '=' + encodeURIComponent(data[k]);
		}).join('&');
		fetch(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
			body: body,
			credentials: 'same-origin'
		}).then(function (r) { return r.json(); }).then(ok).catch(fail);
	}

	// Translate the visible window on demand, through the Guide's cached engine.
	// `to` may be a code, a native name or an English name. The callback gets the
	// server's result; the second callback gets a failure.
	function translatePage(to, ok, fail, root, model) {
		ok = ok || function () {};
		fail = fail || function () {};
		root = root || document.body;
		model = model || '';
		to = String(to || '').replace(/^\s+|\s+$/g, '');
		if (!to) { fail({ ok: 0, error: 'Name a language to translate into.' }); return; }
		var strings = collectStrings(root);
		if (!strings.length) {
			ok({ ok: 1, to: { code: '', native: to, name: to }, translations: {}, translated: 0, cached: 0 });
			return;
		}
		post('/manager/translate', { to: to, strings: JSON.stringify(strings), model: model }, function (r) {
			if (!r || !r.ok) { fail(r || { ok: 0, error: 'the translator did not answer' }); return; }
			var n = applyTranslations(r.translations || {}, root);
			if (r.to && r.to.code) { persist(r.to.code, r.translations || {}); }
			r.applied = n;
			ok(r);
		}, function () {
			fail({ ok: 0, error: 'the translator could not be reached' });
		});
	}

	function startObserver() {
		if (observer || !window.MutationObserver || !document.body) { return; }
		observer = new MutationObserver(function (mutations) {
			for (var i = 0; i < mutations.length; i++) {
				var m = mutations[i];
				if (m.type === 'characterData') {
					translateText(m.target);
				}
				else if (m.type === 'attributes') {
					translateAttr(m.target, m.attributeName);
				}
				else {
					for (var j = 0; j < m.addedNodes.length; j++) {
						walk(m.addedNodes[j]);
					}
				}
			}
		});
		observer.observe(document.body, {
			childList: true,
			subtree: true,
			characterData: true,
			attributes: true,
			attributeFilter: ATTRS
		});
	}

	function start() {
		if (!window.jawnos_ui_lang || !Object.keys(window.jawnos_ui_lang).length) { return; }
		walk(document.body);
		startObserver();
	}

	window.jawnosTranslatePage = translatePage;
	window.jawnosCollectStrings = collectStrings;
	window.jawnosApplyTranslations = applyTranslations;
	window.jawnosTranslateStart = start;

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', start);
	}
	else {
		start();
	}
})();
