#!/usr/bin/env node
// Exercise the note upgrader in public/js/manager/keyboard/03_editor_switcher.js.
//
// Only the one function is evaluated: the file around it binds browser handlers
// at load time. The fake jQuery here keeps the parts the upgrader touches.
// Output is one assertion per line: "ok <name>" or "not ok <name>", and the
// exit status is the number of failures.

'use strict';

const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');

const match = source.match(/function textareaUpgrader\(\) \{[\s\S]*?\n\}/);
if (!match) {
	console.log('not ok textareaUpgrader is found');
	process.exit(1);
}

let failures = 0;
function check(condition, name) {
	console.log((condition ? 'ok ' : 'not ok ') + name);
	if (!condition) { failures++; }
}

let fields = [];
let ajaxCalls = [];
const selectors = [];

function makeField(id) {
	return {
		attrs: { id: id, upgradeable: 'yes', placeholder: 'Note' },
		classList: [ 'timed_input', 'notes' ],
		attributes: [
			{ name: 'id', value: id },
			{ name: 'class', value: 'timed_input notes' },
			{ name: 'upgradeable', value: 'yes' },
		],
		value: '',
	};
}

function wrap(el) {
	const jq = { 0: el, length: 1 };
	jq.attr = function(name, value) {
		if (value === undefined) { return el.attrs[name]; }
		el.attrs[name] = value;
		return jq;
	};
	jq.removeAttr = function(name) { delete el.attrs[name]; return jq; };
	jq.val = function() { return el.value; };
	jq.outerHeight = function() { return 24; };
	jq.css = function() { return 0; };
	jq.before = function() { return jq; };
	jq.hide = function() { return jq; };
	jq.addClass = function() { return jq; };
	jq.removeClass = function() { return jq; };
	jq.html = function() { return jq; };
	return jq;
}

function selectorResult(list) {
	return {
		length: list.length,
		each: function(fn) {
			list.forEach(function(el, i) { fn.call(el, i, el); });
			return this;
		},
	};
}

function $(arg) {
	if (typeof arg === 'string') {
		selectors.push(arg);
		// jQuery/Sizzle rejects an attribute selector with no closing bracket.
		if (arg === 'textarea[upgradeable="yes"]') {
			return selectorResult(fields.filter(function(f) { return f.attrs.upgradeable === 'yes'; }));
		}
		return selectorResult([]);
	}
	return wrap(arg);
}
$.each = function(coll, fn) { for (let i = 0; i < coll.length; i++) { fn(i, coll[i]); } };
$.ajax = function(opts) { ajaxCalls.push(opts); };

const sandbox = { $: $, Math: Math, parseInt: parseInt, parseFloat: parseFloat };
vm.createContext(sandbox);
vm.runInContext(match[0], sandbox);

// --- the selector is complete -----------------------------------------------
fields = [ makeField('note1') ];
sandbox.textareaUpgrader();
check(selectors.indexOf('textarea[upgradeable="yes"]') !== -1,
	'the upgrader uses a complete [upgradeable="yes"] selector');
check(ajaxCalls.length === 1, 'one upgrade request per field');

// --- a restore that passes twice starts one editor --------------------------
sandbox.textareaUpgrader();
check(ajaxCalls.length === 1, 'a second pass while the request is in flight asks for no second editor');

// --- a failed request gives the field back ----------------------------------
ajaxCalls = [];
fields = [ makeField('note2') ];
sandbox.textareaUpgrader();
check(ajaxCalls.length === 1, 'the field is claimed for its request');
if (ajaxCalls[0]) { ajaxCalls[0].error(); }
sandbox.textareaUpgrader();
check(ajaxCalls.length === 2, 'a failed request releases the claim for a later pass');

process.exit(failures);
