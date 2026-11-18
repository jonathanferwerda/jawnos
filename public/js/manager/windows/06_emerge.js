// Window emerge: a new window pours out of the control that opened it. A press
// records the control's rectangle before any window exists (a clothesline pill
// is drawn on a canvas, a start-menu icon is a DOM image), and windowMaker
// hands that rectangle to jawnosWindowEmerge once the window has its final
// place on the desk.
//
// The motion is a body-level "sheet" - a plain fixed surface with no content -
// that stretches from the control's rectangle to the window's rectangle while
// the real window fades in at its final geometry. Only transform and opacity
// are animated, so the window's own text is never squashed and the work stays
// on the compositor. A clip-path on the window could not start outside its own
// box (the clothesline sits above it) and would repaint the whole window each
// frame; WebGL cannot carry live DOM at all, so neither is used.

// A press is good for a while: a lazy app's chunk, a server round trip and a
// pile relayout all happen between the press and the window. An app-less press
// is only trusted for a moment, so a stray control cannot claim the next
// window that happens to arrive.
var JAWNOS_EMERGE_TTL = 10000;
var JAWNOS_EMERGE_FALLBACK = 1500;
var JAWNOS_EMERGE_MAX_ORIGINS = 16;

var jawnosWindowOrigins = {};
var jawnosWindowOriginLast = null;

// One place for the level's manners: a light desk only hints at the flow, the
// maximum lets it travel and overshoot. `travel` is how far the sheet's centre
// has gone by its overshoot frame; `window` is the window's own fade-in.
var jawnosWindowEmergeShape = {
	light:   { duration: 220, travel: 0.55, overshoot: 1.015, window: 180, delay: 40 },
	medium:  { duration: 340, travel: 0.72, overshoot: 1.060, window: 240, delay: 90 },
	maximum: { duration: 460, travel: 0.82, overshoot: 1.100, window: 320, delay: 120 }
};

function jawnosEmergeNumber(value, fallback) {
	var n = parseFloat(value);
	return isFinite(n) ? n : fallback;
}

function jawnosEmergeRound(value) {
	return Math.round(value * 1000) / 1000;
}

// The level is owned by 05_effects.js. It may not be there on a page whose
// bundle predates it; medium is the intended desk, and an unknown word must not
// switch the motion off by accident.
function jawnosWindowEmergeLevel() {
	var level = 'medium';
	if (typeof jawnosWindowEffectsLevel == 'function') {
		level = jawnosWindowEffectsLevel();
	}
	if (level == 'off') { return 'off'; }
	if (level == 'light' || level == 'maximum') { return level; }
	return 'medium';
}

function jawnosWindowEmergeReduced() {
	try {
		return !!(typeof window != 'undefined' && window.matchMedia
			&& window.matchMedia('(prefers-reduced-motion: reduce)').matches);
	}
	catch (e) { return false; }
}

function jawnosWindowOriginNormalize(rect, app, now) {
	rect = rect || {};
	var width = Math.max(6, jawnosEmergeNumber(rect.width, 6));
	var height = Math.max(6, jawnosEmergeNumber(rect.height, 6));
	var radius = jawnosEmergeNumber(rect.radius, Math.min(width, height) * 0.28);
	return {
		left: jawnosEmergeNumber(rect.left, 0),
		top: jawnosEmergeNumber(rect.top, 0),
		width: width,
		height: height,
		radius: Math.max(0, Math.min(radius, Math.min(width, height) / 2)),
		app: app || '',
		at: (now === undefined) ? Date.now() : now
	};
}

// Prune before inserting: the map is small, but a long session with many
// presses must not keep every control it ever touched.
function jawnosWindowOriginPrune(now) {
	var stamp = (now === undefined) ? Date.now() : now;
	var keys = [];
	for (var app in jawnosWindowOrigins) {
		if (!jawnosWindowOrigins.hasOwnProperty(app)) { continue; }
		var origin = jawnosWindowOrigins[app];
		if (!origin || stamp - origin.at > JAWNOS_EMERGE_TTL) { delete jawnosWindowOrigins[app]; }
		else { keys.push(app); }
	}
	while (keys.length > JAWNOS_EMERGE_MAX_ORIGINS) { delete jawnosWindowOrigins[keys.shift()]; }
	if (jawnosWindowOriginLast && stamp - jawnosWindowOriginLast.at > JAWNOS_EMERGE_FALLBACK) {
		jawnosWindowOriginLast = null;
	}
}

function jawnosWindowOriginSet(rect, app, now) {
	var stamp = (now === undefined) ? Date.now() : now;
	jawnosWindowOriginPrune(stamp);
	var origin = jawnosWindowOriginNormalize(rect, app, stamp);
	if (origin.app) { jawnosWindowOrigins[origin.app] = origin; }
	else { jawnosWindowOriginLast = origin; }
	return origin;
}

// The app a pressed control opens, when the control names it: a taskbar tile
// or pin wears the app, a start-menu icon wears an id in the toggle map.
function jawnosWindowOriginApp(el) {
	if (!el || el.nodeType !== 1) { return ''; }
	var app = (el.getAttribute && (el.getAttribute('app') || el.getAttribute('data-app'))) || '';
	if (app) { return app; }
	if (el.id && typeof startMenuIconApps != 'undefined' && startMenuIconApps[el.id]) {
		return startMenuIconApps[el.id];
	}
	var host = (el.closest ? el.closest('.window_toggle, .taskbar_pin, .start_menu_item') : null);
	if (host) {
		var host_app = (host.getAttribute && host.getAttribute('app')) || '';
		if (host_app) { return host_app; }
		var img = (host.querySelector ? host.querySelector('img') : null);
		if (img && img.id && typeof startMenuIconApps != 'undefined' && startMenuIconApps[img.id]) {
			return startMenuIconApps[img.id];
		}
	}
	return '';
}

function jawnosWindowOriginFromElement(el, app, now) {
	if (!el || el.nodeType !== 1 || !el.getBoundingClientRect) { return null; }
	var rect = el.getBoundingClientRect();
	if (!rect || !rect.width || !rect.height) { return null; }
	return jawnosWindowOriginSet({
		left: rect.left,
		top: rect.top,
		width: rect.width,
		height: rect.height,
		radius: Math.min(rect.width, rect.height) * 0.28
	}, app || jawnosWindowOriginApp(el), now);
}

// A canvas has no element per control, so its painter reports the pressed
// pill's rectangle in viewport units: the press point is the centre and the
// measured box gives the size.
function jawnosWindowOriginFromPoint(x, y, width, height, radius, app, now) {
	var w = Math.max(6, jawnosEmergeNumber(width, 6));
	var h = Math.max(6, jawnosEmergeNumber(height, 6));
	return jawnosWindowOriginSet({
		left: jawnosEmergeNumber(x, 0) - w / 2,
		top: jawnosEmergeNumber(y, 0) - h / 2,
		width: w,
		height: h,
		radius: radius
	}, app, now);
}

// Consume-once: the press is spent on the first window that answers for its
// app, so a later background refresh cannot replay an old motion. An app-less
// press may still be the one that opened this window, but only while fresh.
function jawnosWindowOriginTake(app, now) {
	var stamp = (now === undefined) ? Date.now() : now;
	var origin = (app && jawnosWindowOrigins[app]) ? jawnosWindowOrigins[app] : null;
	if (origin) {
		delete jawnosWindowOrigins[app];
		if (stamp - origin.at > JAWNOS_EMERGE_TTL) { return null; }
		return origin;
	}
	origin = jawnosWindowOriginLast;
	jawnosWindowOriginLast = null;
	if (!origin || stamp - origin.at > JAWNOS_EMERGE_FALLBACK) { return null; }
	return origin;
}

// The desk can be display-zoomed (the root's `zoom`): getBoundingClientRect
// reports the zoomed pixels, while a fixed element's left/width are written in
// layout pixels. One zoom factor puts both ends back into the sheet's units.
function jawnosWindowEmergeZoom(el, to) {
	var zoom = 1;
	if (el && el.offsetWidth && to && to.width) { zoom = to.width / el.offsetWidth; }
	try {
		if (typeof document != 'undefined' && document.documentElement && typeof getComputedStyle == 'function') {
			var z = getComputedStyle(document.documentElement).zoom;
			var served_zoom = parseFloat(z);
			if (z && z != 'normal' && isFinite(served_zoom) && served_zoom > 0) { zoom = served_zoom; }
		}
	}
	catch (e) {}
	return (isFinite(zoom) && zoom > 0) ? zoom : 1;
}

function jawnosWindowEmergeCssRect(rect, zoom) {
	zoom = (isFinite(zoom) && zoom > 0) ? zoom : 1;
	return {
		left: rect.left / zoom,
		top: rect.top / zoom,
		width: rect.width / zoom,
		height: rect.height / zoom,
		radius: (rect.radius || 0) / zoom
	};
}

// Pure geometry, so the shape can be played and asserted without a browser.
function jawnosWindowEmergeKeyframes(from, to, level) {
	var shape = jawnosWindowEmergeShape[level] || jawnosWindowEmergeShape.medium;
	var dx = (to.left + (to.width / 2)) - (from.left + (from.width / 2));
	var dy = (to.top + (to.height / 2)) - (from.top + (from.height / 2));
	var sx = jawnosEmergeRound(to.width / from.width);
	var sy = jawnosEmergeRound(to.height / from.height);
	var mid_x = jawnosEmergeRound(dx * shape.travel);
	var mid_y = jawnosEmergeRound(dy * shape.travel);
	var mid_sx = jawnosEmergeRound(sx * shape.overshoot);
	var mid_sy = jawnosEmergeRound(sy * shape.overshoot);
	return {
		duration: shape.duration,
		windowDuration: shape.window,
		delay: shape.delay,
		sheet: [
			{ transform: 'translate(0px, 0px) scale(1, 1)', opacity: 0.85, offset: 0 },
			{ transform: 'translate(' + mid_x + 'px, ' + mid_y + 'px) scale(' + mid_sx + ', ' + mid_sy + ')', opacity: 1, offset: 0.62 },
			{ transform: 'translate(' + jawnosEmergeRound(dx) + 'px, ' + jawnosEmergeRound(dy) + 'px) scale(' + sx + ', ' + sy + ')', opacity: 0, offset: 1 }
		],
		window: [
			{ opacity: 0, transform: 'scale(0.985)', offset: 0 },
			{ opacity: 1, transform: 'scale(1)', offset: 1 }
		]
	};
}

// A window can be re-rendered or closed mid-flight, so the sheet and both
// animations are always put down together - never left to an animationend that
// a cancelled animation will not send.
function jawnosWindowEmergeCancel(el) {
	if (!el) { return; }
	if (el.jawnosEmergeTimer) {
		clearTimeout(el.jawnosEmergeTimer);
		el.jawnosEmergeTimer = null;
	}
	if (el.jawnosEmergeWindowAnim) {
		try { el.jawnosEmergeWindowAnim.cancel(); } catch (e) {}
		el.jawnosEmergeWindowAnim = null;
	}
	var sheet = el.jawnosEmergeSheet;
	el.jawnosEmergeSheet = null;
	if (sheet) {
		if (sheet.jawnosEmergeSheetAnim) {
			try { sheet.jawnosEmergeSheetAnim.cancel(); } catch (e) {}
			sheet.jawnosEmergeSheetAnim = null;
		}
		if (sheet.parentNode) { sheet.parentNode.removeChild(sheet); }
	}
}

function jawnosWindowEmerge(win, origin) {
	if (typeof jawnosWindowEffectsOn == 'function' && !jawnosWindowEffectsOn()) { return false; }
	var level = jawnosWindowEmergeLevel();
	if (level == 'off' || jawnosWindowEmergeReduced()) { return false; }
	win = $(win);
	if (!win.length) { return false; }
	var el = win[0];
	if (!el || typeof el.animate != 'function' || typeof document == 'undefined') { return false; }
	// a hidden window has no rectangle to pour into; the opener may still be
	// about to hide it, and a motion on nothing would only leave a sheet behind
	if (el.getClientRects && el.getClientRects().length === 0) { return false; }
	origin = origin || jawnosWindowOriginTake(win.attr('app'));
	if (!origin) { return false; }
	// an old class effect and this motion both own transform; the newer one wins,
	// and it must be gone before the window's rectangle is measured
	if (typeof jawnosWindowEffectCancel == 'function') { jawnosWindowEffectCancel(el); }
	jawnosWindowEmergeCancel(el);
	var to = el.getBoundingClientRect();
	if (!to || !to.width || !to.height) { return false; }

	var zoom = jawnosWindowEmergeZoom(el, to);
	var from_css = jawnosWindowEmergeCssRect(origin, zoom);
	var to_css = jawnosWindowEmergeCssRect(to, zoom);
	var keyframes = jawnosWindowEmergeKeyframes(from_css, to_css, level);
	el.jawnosEmergeWindowAnim = el.animate(keyframes.window, {
		duration: keyframes.windowDuration,
		delay: keyframes.delay,
		easing: 'ease-out',
		fill: 'both'
	});

	// The sheet starts as the control itself and is worn by no window: it is
	// anchored to the viewport, not to the window's stacking context.
	var sheet = document.createElement('div');
	sheet.className = 'jawnos_emerge_sheet';
	sheet.style.left = from_css.left + 'px';
	sheet.style.top = from_css.top + 'px';
	sheet.style.width = from_css.width + 'px';
	sheet.style.height = from_css.height + 'px';
	sheet.style.borderRadius = from_css.radius + 'px';
	document.body.appendChild(sheet);
	el.jawnosEmergeSheet = sheet;
	sheet.jawnosEmergeSheetAnim = sheet.animate(keyframes.sheet, {
		duration: keyframes.duration,
		easing: 'cubic-bezier(.2,.85,.25,1)',
		fill: 'both'
	});

	var finish = function() { jawnosWindowEmergeCancel(el); };
	if (sheet.jawnosEmergeSheetAnim.finished && sheet.jawnosEmergeSheetAnim.finished.then) {
		sheet.jawnosEmergeSheetAnim.finished.then(finish, finish);
	}
	// a throttled tab or a cancelled animation may never settle the promise;
	// the ceiling is the shape the class effects already use
	el.jawnosEmergeTimer = setTimeout(finish, keyframes.duration + 500);
	// An opener that asked for a window it does not want shown hides it after
	// windowMaker returns. The sheet must not outlive the window it came from.
	setTimeout(function () {
		if (el.getClientRects && el.getClientRects().length === 0) { jawnosWindowEmergeCancel(el); }
	}, 0);
	return true;
}

// A press records its control here: pointerdown catches the ordinary press
// before the menu closes or the tile re-renders. A canvas is skipped because
// its own press handler knows which pill was hit and records that rectangle.
(function () {
	if (typeof $ != 'function' || typeof document == 'undefined') { return; }
	var doc = $(document);
	if (!doc || typeof doc.on != 'function') { return; }
	var press = (typeof window != 'undefined' && window.PointerEvent) ? 'pointerdown' : 'mousedown touchstart';
	doc.on(press, function (e) {
		if (!e || (e.button != null && e.button !== 0)) { return; }
		var el = e.target;
		if (!el || el.nodeType !== 1 || el.tagName == 'CANVAS') { return; }
		var host = (el.closest ? el.closest('.start_menu_item, .taskbar_pin, .window_toggle') : null);
		if (host) { el = host; }
		jawnosWindowOriginFromElement(el);
	});
})();
