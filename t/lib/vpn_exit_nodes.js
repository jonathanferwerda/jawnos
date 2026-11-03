#!/usr/bin/env node
// Exercise the exit-node filter behind the remote_control VPN button
// (public/js/manager/keyboard/03_editor_switcher.js).
//
// Only the one pure function is evaluated: the file around it is a browser
// script that binds handlers at load time. Output is one assertion per line:
// "ok <name>" or "not ok <name>", and the exit status is the number of
// failures.

'use strict';

const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');

const match = source.match(/function jawnosVpnNodes\(status\) \{[\s\S]*?\n\}/);
if (!match) {
	console.log('not ok jawnosVpnNodes is found');
	process.exit(1);
}

const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(match[0], sandbox);

let failures = 0;
function check(condition, name) {
	console.log((condition ? 'ok ' : 'not ok ') + name);
	if (!condition) { failures++; }
}

function nodes(status) { return sandbox.jawnosVpnNodes(status); }

// A tailnet with one usable exit node, an offline one, a peer with no exit
// node, and a peer with no address of its own.
const status = { peers: [
	{ ip: '100.64.0.11', name: 'house', exit: 1, online: 1 },
	{ ip: '100.64.0.1', name: 'table', exit: 1, online: 0 },
	{ ip: '100.64.0.9', name: 'phone', exit: 0, online: 1 },
	{ ip: '', name: 'nameless', exit: 1, online: 1 },
] };

const list = nodes(status);
check(list.length === 1, 'only the online exit node is offered');
check(list[0].ip === '100.64.0.11', 'the offered node keeps its tailnet address');
check(list[0].name === 'house', 'the offered node keeps its name');

const two = nodes({ peers: [
	{ ip: '100.64.0.11', name: 'house', exit: 1, online: 1 },
	{ ip: '100.64.0.2', name: 'cloud', exit: 1, online: 1 },
] });
check(two.length === 2, 'every online exit node is offered');
check(two[0].ip === '100.64.0.11' && two[1].ip === '100.64.0.2',
	'the tailnet order is kept for the list');

check(nodes({}).length === 0, 'a status with no peers offers none');
check(nodes({ peers: [] }).length === 0, 'an empty peer list offers none');

const unnamed = nodes({ peers: [{ ip: '100.64.0.7', exit: 1, online: 1 }] });
check(unnamed.length === 1 && unnamed[0].name === '100.64.0.7',
	'a node with no name falls back to its address');

process.exit(failures);
