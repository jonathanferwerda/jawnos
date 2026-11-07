#!/usr/bin/env node
// Exercise the screening panel's paint path
// (public/js/manager/screening.js) against a small stand-in DOM.
//
// The panel is what draws a screened call on a device that does not have the
// Phone app loaded, and its bugs are ordering bugs a screenshot cannot show: a
// line arrives while the panel is closed, a call ends and the next begins while
// the window sleeps, the gateway's 200-line history drops its front. The file
// is a browser script, so the whole of it is evaluated in a sandbox with a
// jQuery-shaped stub - no real DOM, but the same calls the real page makes.
//
// Output is one assertion per line: "ok <name>" or "not ok <name>", and the
// exit status is the number of failures.

'use strict';

const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');

// ---- the smallest DOM that answers what screening.js asks ----------------

const registry = new Map();

class El {
	constructor(tag) {
		this.tag = tag || 'div';
		this.id = '';
		this.classes = [];
		this.children = [];
		this.parent = null;
		this.attrs = {};
		this.style = {};
		this.value = '';
		this.texts = [];
		this.shown = true;
		this.scroll = 0;
	}
	get scrollHeight() { return this.children.length * 20; }
}

function register(el) {
	if (el.id) { registry.set(el.id, el); }
	el.children.forEach(register);
}

function unregister(el) {
	if (el.id && registry.get(el.id) === el) { registry.delete(el.id); }
	el.children.forEach(unregister);
}

class J {
	constructor(els) {
		this.els = els || [];
		this.length = this.els.length;
		this.els.forEach((el, i) => { this[i] = el; });
	}
	each(fn) { this.els.forEach((el, i) => fn.call(el, i, el)); return this; }
	on() { return this; }
	trigger() { return this; }
	toggleClass() { return this; }
	prop() { return this; }
	is() { return false; }
	css(k, v) {
		if (v === undefined) { return this.els[0] ? this.els[0].style[k] : undefined; }
		this.els.forEach(el => { el.style[k] = v; });
		return this;
	}
	attr(k, v) {
		if (v === undefined) { return this.els[0] ? this.els[0].attrs[k] : undefined; }
		this.els.forEach(el => {
			el.attrs[k] = v;
			if (k === 'id') { el.id = v; register(el); }
		});
		return this;
	}
	text(v) {
		if (v === undefined) {
			return this.els.map(el => (el.texts.length ? el.texts[el.texts.length - 1] : '')).join('');
		}
		this.els.forEach(el => { el.texts.push(String(v)); el.children = []; });
		return this;
	}
	val(v) {
		if (v === undefined) { return this.els[0] ? this.els[0].value : ''; }
		this.els.forEach(el => { el.value = v; });
		return this;
	}
	toggle(on) { this.els.forEach(el => { el.shown = !!on; }); return this; }
	empty() {
		this.els.forEach(el => { el.children.forEach(unregister); el.children = []; });
		return this;
	}
	append(other) {
		const kids = other instanceof J ? other.els : (other instanceof El ? [other] : []);
		this.els.forEach(el => {
			kids.forEach(kid => { kid.parent = el; el.children.push(kid); register(kid); });
		});
		return this;
	}
	appendTo(parent) { (parent instanceof J ? parent : new J([parent])).append(this); return this; }
	remove() {
		this.els.forEach(el => {
			if (el.parent) {
				const at = el.parent.children.indexOf(el);
				if (at >= 0) { el.parent.children.splice(at, 1); }
			}
			unregister(el);
			el.parent = null;
		});
		return this;
	}
	find(sel) {
		const wanted = sel.split('.').filter(Boolean);
		const out = [];
		const walk = el => el.children.forEach(kid => {
			if (wanted.every(c => kid.classes.indexOf(c) >= 0)) { out.push(kid); }
			walk(kid);
		});
		this.els.forEach(walk);
		return new J(out);
	}
	scrollTop(v) {
		if (v === undefined) { return this.els[0] ? this.els[0].scroll : 0; }
		this.els.forEach(el => { el.scroll = v; });
		return this;
	}
}

const body = new El('body');

function make(html) {
	const el = new El((html.match(/^<\s*([a-zA-Z0-9]+)/) || [])[1] || 'div');
	const id = html.match(/\bid="([^"]*)"/);
	if (id) { el.id = id[1]; }
	const cls = html.match(/\bclass="([^"]*)"/);
	if (cls) { el.classes = cls[1].split(/\s+/).filter(Boolean); }
	register(el);
	return el;
}

const pending = [];

function $(arg) {
	// a DOM-ready callback is never run: the test drives the functions itself
	if (typeof arg === 'function') { return new J([]); }
	if (typeof arg === 'string') {
		if (arg.charAt(0) === '<') { return new J([make(arg)]); }
		if (arg.charAt(0) === '#') {
			const el = registry.get(arg.slice(1));
			return new J(el ? [el] : []);
		}
		if (arg === 'body') { return new J([body]); }
		return new J([]);
	}
	if (arg instanceof El) { return new J([arg]); }
	return new J([]);
}
$.ajax = function (opts) { pending.push(opts); };

const sandbox = {
	$, jQuery: $,
	document: { getElementById: id => registry.get(id) || null, hidden: false },
	window: {},
	jawnosT: s => s,
	setInterval: () => 1,
	clearInterval: () => {},
	setTimeout: () => 1,
	Audio: function () { },
	Date, console,
};
vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: 'screening.js' });

// ---- reading the panel back ----------------------------------------------

let failures = 0;
function check(condition, name) {
	console.log((condition ? 'ok ' : 'not ok ') + name);
	if (!condition) { failures++; }
}

function bubbles() {
	const box = registry.get('jawn_screening_lines');
	if (!box) { return []; }
	return box.children
		.filter(c => c.classes.indexOf('jawn_screening_bubble') >= 0
			&& c.classes.indexOf('jawn_screening_partial') < 0)
		.map(c => (c.texts.length ? c.texts[c.texts.length - 1] : ''));
}

function note() { return $('#jawn_screening_note').text(); }

function paint(res) { sandbox.jawnScreenPanelPaint(res); }
function openPanel() { sandbox.jawnScreenPanelOpen(); }
function closePanel() { $('#jawn_screening').remove(); }

function status(callId, texts) {
	return {
		state: 'in_call', call_id: callId,
		transcript: texts.map((text, i) => ({ who: 'caller', text, at: 100 + i, ms: 900 })),
	};
}

function history(first, count) {
	const out = [];
	for (let i = 0; i < count; i++) {
		out.push({ who: 'caller', text: 'line ' + (first + i), at: first + i, ms: 900 });
	}
	return { state: 'in_call', call_id: 'long', transcript: out };
}

// ---- the paint ------------------------------------------------------------

// A line the reader timed at 0 ms is a line the caller said, whatever the index
// over lines happens to be.
openPanel();
paint({
	state: 'in_call', call_id: 'call-a',
	transcript: [
		{ who: 'caller', text: 'may i ask whose calling', at: 100, ms: 0 },
		{ who: 'caller', text: 'this is john', at: 104, ms: 2400 },
	],
});
check(JSON.stringify(bubbles()) === JSON.stringify(['may i ask whose calling', 'this is john']),
	'a line with ms:0 is drawn with the rest');
paint(status('call-a', ['one', 'two']));
paint(status('call-a', ['one', 'two']));
check(bubbles().length === 2, 'painting the same status twice does not duplicate a line');

// Lines that arrive while the panel is closed (hidden, or the window asleep)
// are still there when it opens: the status is the whole truth, not a delta.
closePanel();
paint(status('call-a', ['one', 'two', 'three', 'four', 'five']));
check(bubbles().length === 0, 'nothing is drawn while the panel is not on the page');
openPanel();
paint(status('call-a', ['one', 'two', 'three', 'four', 'five']));
check(JSON.stringify(bubbles()) === JSON.stringify(['one', 'two', 'three', 'four', 'five']),
	'the lines that arrived while it was closed are all there when it opens');

// Two calls back to back with no call_id: the old count must not be measured
// against the new, shorter transcript (the "index past the end" panel).
paint(status('', ['a', 'b', 'c']));
paint(status('', ['only line']));
check(JSON.stringify(bubbles()) === JSON.stringify(['only line']),
	'a shorter status from the next call is drawn, not skipped');
check(JSON.stringify(bubbles()) !== JSON.stringify(['a', 'b', 'c']),
	'and the previous call\'s lines are gone');

// The gateway keeps the newest 200 lines, so the front of the list falls off:
// the line that pushed it off must still be drawn.
paint(history(1, 200));
check(bubbles().length === 200, 'the panel keeps the gateway\'s whole history');
paint(history(2, 200));
check(bubbles()[bubbles().length - 1] === 'line 201',
	'a line that pushed the oldest one off the front is drawn');
check(bubbles().length === 200, 'and the panel still holds 200 lines, not 201');

// An unreachable gateway: the panel says which machine did not answer instead
// of showing an empty transcript.
paint({ state: 'unreachable', transcript: [],
	transcript_note: 'The gateway did not answer: bad token' });
check(note() === 'The gateway did not answer: bad token',
	'an unreachable gateway says so in the panel, not in an empty transcript');
paint({ state: 'unreachable', transcript: [] });
check(note() === 'The gateway did not answer.',
	'and the panel has its own words when the answer carries none');

// ---- the poll and the push ------------------------------------------------

closePanel();
sandbox.jawnScreen = { call: '', timer: null, drawn: [], hidden: false, top: 0, last: null, wanted: false };

sandbox.jawnScreenPushed({ state: 'started' });
check(sandbox.jawnScreen.wanted === true,
	'a screening push marks the panel as wanted, so an unreachable status still shows');
pending.length = 0;

sandbox.jawnScreenPoll();
check(pending.length === 1, 'the poll asks the status route');
pending.shift().success({ state: 'unreachable', transcript: [],
	transcript_note: 'The gateway did not answer: bad token' });
check($('#jawn_screening').length === 1,
	'a gateway that does not answer does not close a screening this device was told about');
check(note() === 'The gateway did not answer: bad token', 'and the panel carries the reason');

closePanel();
sandbox.jawnScreen.hidden = false;
sandbox.jawnScreen.wanted = false;
pending.length = 0;
sandbox.jawnScreenPoll();
pending.shift().success({ state: 'unreachable', transcript: [], transcript_note: 'nope' });
check($('#jawn_screening').length === 0,
	'a house with no gateway is not given a panel it never asked for');

pending.length = 0;
sandbox.jawnScreenPoll();
pending.shift().success({
	state: 'in_call', call_id: 'call-c',
	transcript: [{ who: 'caller', text: 'hello', at: 500, ms: 0 }],
});
check($('#jawn_screening').length === 1, 'a live call opens the panel from the poll alone');
check(bubbles()[0] === 'hello', 'and its first line, timed at 0 ms, is on it');

sandbox.jawnScreen.timer = null;
sandbox.jawnScreenPushed({ state: 'ended' });
check(sandbox.jawnScreen.wanted === false, 'the end push stops the chase');

console.log((failures ? 'not ok ' : 'ok ') + failures + ' failure(s)');
process.exit(failures);
