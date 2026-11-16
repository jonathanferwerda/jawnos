#!/usr/bin/env node
// Exercise the vector-basemap provider rules in
// public/js/manager/mapengine/01_engine.js.
//
// The engine is a browser script, so it is evaluated in a vm against a small
// fake DOM (one canvas inside a positioned div), a recording 2D context, an
// Image that never loads, and a fake MapLibre whose map records every jumpTo,
// resize and remove. Output is one assertion per line: "ok <name>" or
// "not ok <name>", and the exit status is the number of failures.

'use strict';

const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');

let failures = 0;
function ok(cond, name) {
	if (cond) { console.log('ok ' + name); }
	else { failures++; console.log('not ok ' + name); }
}
function eq(got, want, name) {
	ok(got === want, name + (got === want ? '' : ' (got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want) + ')'));
}

// ---- a small fake DOM ------------------------------------------------------
function makeElement(tag) {
	const el = {
		tagName: tag, className: '', id: '', children: [], parentNode: null,
		style: {}, offsetLeft: 0, offsetTop: 0, offsetWidth: 800, offsetHeight: 400, clientWidth: 800, clientHeight: 400,
		appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
		insertBefore(child, ref) {
			const at = el.children.indexOf(ref);
			if (at < 0) { el.children.push(child); } else { el.children.splice(at, 0, child); }
			child.parentNode = el;
			return child;
		},
		removeChild(child) {
			const at = el.children.indexOf(child);
			if (at >= 0) { el.children.splice(at, 1); }
			child.parentNode = null;
			return child;
		},
		addEventListener() {},
		removeEventListener() {},
		getBoundingClientRect() { return { left: 0, top: 0, width: 800, height: 400 }; },
		getContext() { return el.ctx; }
	};
	return el;
}

function makeCtx() {
	const calls = [];
	return new Proxy({}, {
		get(target, key) {
			if (key === 'calls') { return calls; }
			if (key in target) { return target[key]; }
			return function () { calls.push(key); };
		},
		set(target, key, value) { target[key] = value; return true; }
	});
}

function FakeImage() {
	FakeImage.created++;
	this._src = '';
	this.onload = null;
	this.onerror = null;
}
FakeImage.created = 0;
FakeImage.srcs = [];
Object.defineProperty(FakeImage.prototype, 'src', {
	get() { return this._src; },
	set(value) { this._src = value; FakeImage.srcs.push(value); }
});

function FakeMap(options) {
	FakeMap.instances.push(this);
	this.options = options;
	this.container = options.container;
	this.moves = [];
	this.resizes = 0;
	this.removed = false;
	this.listeners = 0;
}
FakeMap.instances = [];
FakeMap.prototype.jumpTo = function (view) { this.moves.push(view); };
FakeMap.prototype.resize = function () { this.resizes++; };
FakeMap.prototype.on = function () { this.listeners++; };
FakeMap.prototype.off = function () { this.listeners--; };
FakeMap.prototype.remove = function () { this.removed = true; this.listeners = 0; };

// A fresh engine per scenario: the module's IIFE keeps per-create state inside
// each create(), and the fake page shares nothing between loads.
function boot() {
	FakeMap.instances.length = 0;
	const canvas = makeElement('canvas');
	canvas.ctx = makeCtx();
	const parent = makeElement('div');
	parent.appendChild(canvas);
	const document = {
		getElementById(id) { return id === 'map' ? canvas : null; },
		createElement(tag) { return makeElement(tag); }
	};
	const window = {
		document,
		addEventListener() {},
		removeEventListener() {},
		maplibregl: { Map: FakeMap },
		pmtiles: {}
	};
	const sandbox = {
		window, document, Image: FakeImage, console,
		setTimeout, clearTimeout, setInterval, clearInterval,
		Date, Math, JSON, parseInt, parseFloat, isFinite, isNaN, encodeURIComponent,
		requestAnimationFrame() { return 0; },
		cancelAnimationFrame() {}
	};
	vm.createContext(sandbox);
	vm.runInContext(source, sandbox);
	return { map: sandbox.window.jawnosMap, canvas, parent, window };
}

function create(state, opts) {
	const options = Object.assign({
		width() { return 800; },
		height() { return 400; }
	}, opts || {});
	return state.map.create('map', options);
}

const VECTOR_OK = {
	load(done) { VECTOR_OK.loads++; done(true); },
	register() { VECTOR_OK.registered++; },
	maxZoom(url, done) { VECTOR_OK.urls.push(url); done(17, true); },
	style(maxzoom) { return { version: 8, house: { maxzoom } }; },
	url: '/manager/travel/basemap'
};
VECTOR_OK.registered = 0;
VECTOR_OK.urls = [];
VECTOR_OK.loads = 0;

// ---- the provider row ------------------------------------------------------
{
	const state = boot();
	const p = state.map.providers.house;
	ok(!!p, 'the house basemap is a provider row');
	eq(p && p.group, 'house', 'it has a picker group of its own');
	ok(p && /OpenStreetMap/.test(p.credit || ''), 'its credit names OpenStreetMap');
	eq(p && p.vector, true, 'the row says it is drawn as vectors');
}

// ---- the vector path: a map behind the canvas, the engine on top -----------
{
	const state = boot();
	VECTOR_OK.loads = 0;
	let status = null;
	const engine = create(state, {
		provider: 'house',
		vector: VECTOR_OK,
		onStatus(text) { status = text; }
	});
	engine.draw();

	const layer = FakeMap.instances[0];
	ok(!!layer, 'drawing the house provider builds a MapLibre map');
	const box = state.parent.children[0];
	eq(box, layer && layer.container, 'MapLibre gets a box of its own');
	eq(state.parent.children[1], state.canvas, 'the box sits immediately before the canvas');
	ok(/position:absolute/.test(box.style.cssText), 'the box is absolutely positioned');
	ok(/pointer-events:none/.test(box.style.cssText), 'and every pointer event passes through it');
	eq(layer.options.interactive, false, 'MapLibre does not take over interaction');
	eq(layer.options.maxZoom, 17, 'its zoom ceiling is the archive header\'s');
	eq(layer.options.style.house.maxzoom, 17, 'and the style was built for that archive');
	eq(layer.options.center[1], engine.view().lat, 'it opens on the engine\'s latitude');
	eq(layer.options.center[0], engine.view().lon, 'and its longitude');
	eq(layer.options.zoom, 13, 'MapLibre opens one 512-based zoom below the engine\'s z14');
	eq(VECTOR_OK.registered, 1, 'the PMTiles protocol is registered once');
	eq(VECTOR_OK.loads, 0, 'an already installed MapLibre is reused, not re-executed');
	eq(VECTOR_OK.urls[0], '/manager/travel/basemap', 'the archive header is read from the house route');
	eq(status, '', 'no status note when the layer is up');
	eq(state.canvas.style.zIndex, '1', 'the canvas is lifted above the backdrop');
	eq(FakeImage.created, 0, 'no raster tile is fetched for the vector provider');
	eq(state.canvas.ctx.calls.indexOf('fillRect'), -1, 'and the canvas keeps its background transparent');

	// the engine still owns the view: a move drives jumpTo
	const before = layer.moves.length;
	engine.center(10, 20);
	ok(layer.moves.length > before, 'a view change drives jumpTo');
	const last = layer.moves[layer.moves.length - 1];
	eq(last.center[1], 10, 'jumpTo follows the engine\'s latitude');
	eq(last.center[0], 20, 'and longitude');
	engine.setZoom(15.5);
	const zoomed = layer.moves[layer.moves.length - 1];
	eq(zoomed.zoom, 14.5, 'jumpTo carries the engine\'s fractional zoom, one step shallower');
	engine.setZoom(19);
	ok(engine.view().z <= 18, 'clampZ reaches one past the archive\'s deepest zoom, so its deepest tiles are asked for');

	// a CSS-scaled canvas (Travel's width:100%;height:70vh) is matched, not
	// stretched, and the backdrop is never larger than the canvas itself
	state.canvas.offsetHeight = 200;
	engine.draw();
	eq(box.style.transform, 'scale(1,0.5)', 'the backdrop takes the canvas\'s CSS scale');
	eq(box.style.width, state.canvas.width + 'px', 'and is exactly the canvas box, never doubled');
	state.canvas.offsetHeight = 400;
	engine.draw();

	// switching away lets go of the GL map and the box
	engine.setProvider('esri', '', {});
	ok(layer.removed, 'switching provider disposes the MapLibre map');
	ok(box.parentNode === null, 'and removes its box');
	eq(state.canvas.style.zIndex, '', 'and puts the canvas back as it was');
	ok(FakeImage.created > 0, 'the raster provider then fetches its own tiles');
	ok(/arcgisonline/.test(FakeImage.srcs[FakeImage.srcs.length - 1]), 'from the provider just chosen');
}

// ---- no libraries: say so and fall back to the previous raster ------------
{
	const state = boot();
	delete state.window.maplibregl;
	delete state.window.pmtiles;
	const notes = [];
	const engine = create(state, {
		provider: 'esri',
		vector: {
			load(done) { done(false); },
			register() {},
			maxZoom(url, done) { done(17, true); },
			style() { return {}; },
			url: '/manager/travel/basemap'
		},
		onStatus(text) { notes.push(text); }
	});
	engine.draw();
	engine.setProvider('house', '', {});
	eq(FakeMap.instances.length, 0, 'missing libraries build no MapLibre map');
	ok(notes.some(function (t) { return /fetch_basemap_libs\.sh/.test(t); }),
		'the status text names the installer');
	ok(FakeImage.created > 0, 'the previous raster provider is drawn instead');
	ok(/arcgisonline/.test(FakeImage.srcs[FakeImage.srcs.length - 1]),
		'and it is the provider the person had before');
}

// ---- no archive staged: the header read reports it ------------------------
{
	const state = boot();
	const notes = [];
	const engine = create(state, {
		provider: 'house',
		vector: {
			load(done) { done(true); },
			register() {},
			maxZoom(url, done) { done(14, false); },
			style() { return {}; },
			url: '/manager/travel/basemap'
		},
		onStatus(text) { notes.push(text); }
	});
	engine.draw();
	eq(FakeMap.instances.length, 0, 'an unreadable archive builds no backdrop');
	ok(notes.some(function (t) { return /osm_basemap\.pl --all/.test(t); }),
		'the status text says how to build one');
	ok(FakeImage.created > 0, 'the raster fallback is drawn rather than a blank map');
}

// ---- no vector option at all (another app's engine) -----------------------
{
	const state = boot();
	const notes = [];
	const engine = create(state, { provider: 'house', onStatus(text) { notes.push(text); } });
	engine.draw();
	eq(FakeMap.instances.length, 0, 'an engine with no loader builds nothing');
	ok(notes.some(function (t) { return /fetch_basemap_libs\.sh/.test(t); }),
		'and says the libraries are not installed');
	ok(FakeImage.created > 0, 'while still showing a raster map');
}

// ---- teardown --------------------------------------------------------------
{
	const state = boot();
	const engine = create(state, { provider: 'house', vector: VECTOR_OK });
	engine.draw();
	const layer = FakeMap.instances[FakeMap.instances.length - 1];
	const box = layer.container;
	engine.destroy();
	const builtBefore = FakeMap.instances.length;
	engine.draw();
	eq(FakeMap.instances.length, builtBefore, 'a destroyed engine does not build a layer again');
	ok(layer.removed, 'destroy() disposes the MapLibre map');
	ok(box.parentNode === null, 'destroy() removes its box');
	eq(state.canvas.style.zIndex, '', 'destroy() restores the canvas stacking');
	eq(engine.providers.house.group, 'house', 'the provider table survives teardown');
}

process.exit(failures);
