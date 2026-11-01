#!/usr/bin/env node
// Exercise the mail socket's reconnect rules from public/js/mailbox.js.
//
// The file itself is a browser script; only the four functions the rules live
// in are evaluated, against a virtual clock and a WebSocket that always fails
// the handshake. Output is one assertion per line: "ok <name>" or "not ok
// <name>", and the exit status is the number of failures.

'use strict';

const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');

function grab(name) {
	const match = source.match(new RegExp('function ' + name + '\\(\\) \\{[\\s\\S]*?\\n\\}'));
	if (!match) {
		console.log('not ok ' + name + ' is found');
		process.exit(1);
	}
	return match[0];
}

const code = [
	'var mailws = undefined, mailwsInterval, mailwsLastAnswer = 0, mailwsSignature = "";',
	'var mailwsRetryTimer, mailwsFailures = 0, mailwsBlockedUntil = 0;',
	'var bti = "t", bt = "b", mail_ws_url = "wss://127.0.0.1:45546/mail/ws", last_mail_message = 0;',
	grab('mailWebSocketStart'),
	grab('mailWebSocketClose'),
	grab('mailWebSocketRetry'),
	grab('mailWebSocketStop'),
].join('\n');

let now = 1000000;
let timers = [];
let next_id = 1;

function setTimeout_(fn, ms) {
	const id = next_id++;
	timers.push({ id: id, at: now + (ms || 0), fn: fn });
	return id;
}

function clearTimeout_(id) {
	timers = timers.filter(function (t) { return t.id !== id; });
}

function setInterval_(fn, ms) { return next_id++; }
function clearInterval_() {}

function advance(ms) {
	const end = now + ms;
	for (;;) {
		timers.sort(function (a, b) { return a.at - b.at; });
		const due = timers.find(function (t) { return t.at <= end; });
		if (!due) { break; }
		timers = timers.filter(function (t) { return t !== due; });
		now = due.at;
		due.fn();
	}
	now = end;
}

let attempts = 0;

class WebSocket {
	constructor(url) {
		attempts++;
		this.url = url;
		this.readyState = 0;
		// Every handshake fails. onclose owns the retry, so report it on the
		// next tick exactly as the engine would after a refused certificate.
		setTimeout_(function () {
			this.readyState = 3;
			if (typeof this.onclose === 'function') { this.onclose.call(this, { code: 1006 }); }
		}.bind(this), 1);
	}
	close() { this.readyState = 3; }
	send() {}
}

const sandbox = {
	document: { hidden: false, addEventListener: function () {} },
	WebSocket: WebSocket,
	console: { log: function () {} },
	setTimeout: setTimeout_,
	clearTimeout: clearTimeout_,
	setInterval: setInterval_,
	clearInterval: clearInterval_,
	Date: { now: function () { return now; } },
	sessionStorage: { getItem: function () { return null; } },
	localStorage: { getItem: function () { return null; } },
	mailAddressGrabber: function () { return { section: 'chat' }; },
};

vm.createContext(sandbox);
vm.runInContext(code, sandbox);

let failures = 0;
function check(condition, name) {
	console.log((condition ? 'ok ' : 'not ok ') + name);
	if (!condition) { failures++; }
}

function start() { vm.runInContext('mailWebSocketStart()', sandbox); }
function hide(hidden) { sandbox.document.hidden = hidden; }

// 1. A burst of callers while the first attempt is still connecting builds
//    exactly one socket. This is the boot storm: dozens of callers rebuilt it
//    every time a window rendered.
start();
for (let i = 0; i < 40; i++) { start(); }
check(attempts === 1, 'a burst of callers while connecting opens one socket');

// 2. The failed handshake schedules a retry rather than a rebuild on demand.
advance(2);
check(attempts === 1, 'the failed socket is not rebuilt by the callers');
for (let i = 0; i < 40; i++) { start(); }
check(attempts === 1, 'a pending retry absorbs the callers');

// 3. Over a minute the delay doubles: 2 + 4 + 8 + 16 + 30 seconds.
for (let i = 0; i < 70; i++) {
	advance(1000);
	for (let j = 0; j < 10; j++) { start(); }
}
check(attempts >= 4 && attempts <= 8, 'a minute of failures is a handful of attempts (' + attempts + ')');

// 4. A hidden page schedules nothing at all.
hide(true);
const hidden_before = attempts;
for (let i = 0; i < 70; i++) {
	advance(1000);
	for (let j = 0; j < 10; j++) { start(); }
}
check(attempts === hidden_before, 'a hidden page opens and retries nothing');

// 5. Coming back on screen opens it once.
hide(false);
start();
check(attempts === hidden_before + 1, 'a visible page opens one socket again');

process.exit(failures);
