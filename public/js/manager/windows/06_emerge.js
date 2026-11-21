// Window emerge: a new window pours out of the control that opened it. A press
// records the control's rectangle before any window exists (a clothesline pill
// is drawn on a canvas, a start-menu icon is a DOM image), and windowMaker
// hands that rectangle to jawnosWindowEmerge once the window has its final
// place on the desk.
//
// Two pieces play the motion:
//
//   * The press-time preview (a body-level .jawnos_emerge_ghost) appears the
//     moment the pointer goes down - on touch, after a short settle, so the
//     first frames of a scroll never draw it. It already wears the standard window
//     chrome - the title bar, the app's icon and name, minimise/maximise/close
//     - because every app window is drawn with the same controls. It grows
//     from the pressed control to the frame the window is predicted to take
//     (the default 480x640 at the cascade's next slot) and waits there.
//   * When the real window lands, windowMaker hands it over. The ghost is
//     retargeted to the window's actual rectangle (a slow server or a pinned
//     place can put it somewhere else) and cross-faded into the real window.
//
// A press path that never produced a ghost (an effects level that is off, a
// reduced-motion desk, or an opener that is not one of the four named controls)
// keeps the older fallback: a plain sheet stretched from the control to the
// window while the window fades in. Either way only opacity and a transform
// animate - text is never squashed by a resize, and WebGL is not used. The
// ghost is laid out at its predicted frame and grown by a transform back onto
// the pressed control, so the growth rides the compositor and keeps moving
// while a slow window's markup is built; it is one fixed element for a few
// hundred milliseconds.

// A press is good for a while: a lazy app's chunk, a server round trip and a
// pile relayout all happen between the press and the window. An app-less press
// is only trusted for a moment, so a stray control cannot claim the next
// window that happens to arrive.
var JAWNOS_EMERGE_TTL = 10000;
var JAWNOS_EMERGE_FALLBACK = 1500;
var JAWNOS_EMERGE_MAX_ORIGINS = 16;
// The preview outlives a slow round trip, but a press that opens nothing must
// not leave a window-shaped ghost standing on the desk. A preview whose window
// is still on its way is held rather than expired (see
// jawnosWindowEmergeGhostExpire); the absolute ceiling keeps a leaked
// reservation from leaving one forever.
var JAWNOS_EMERGE_GHOST_TTL = 3000;
var JAWNOS_EMERGE_GHOST_MAX = 30000;
// How long a dismissal is remembered while the window it cancelled is still on
// its way. A reservation carries its own timestamp, so this only bounds the
// app-keyed fallback an opener with no reservation leaves behind.
var JAWNOS_EMERGE_DISMISS_TTL = 30000;

var jawnosWindowOrigins = {};
var jawnosWindowOriginLast = null;
var jawnosWindowEmergeGhost = null;
// The dock's row rebuilds as a window lands, and a layout pass or a transition
// in the window's own beat is what froze the motion part way through. The dock
// asks here whether a motion is in flight and waits for the last one to settle
// before it lays the row out and animates the new face.
var jawnosWindowEmergeRunning = 0;
function jawnosWindowEmergeBusy() { return jawnosWindowEmergeRunning > 0; }
function jawnosWindowEmergeBegin() { jawnosWindowEmergeRunning++; }
function jawnosWindowEmergeEnd(el) {
	if (jawnosWindowEmergeRunning > 0) { jawnosWindowEmergeRunning--; }
	// The window has settled: its own markup is the next press's picture. Taken
	// once the desk is idle, so the clone never lands in the animation's last
	// frame or in the person's next press.
	if (el && typeof jawnosEmergePreviewCapture == 'function') {
		var drafted = function () { jawnosEmergePreviewCapture(el); };
		if (typeof requestIdleCallback == 'function') { requestIdleCallback(drafted, { timeout: 1200 }); }
		else { setTimeout(drafted, 300); }
	}
	if (jawnosWindowEmergeRunning > 0) { return; }
	if (typeof jawnosDockWindowsSettle == 'function') { jawnosDockWindowsSettle(1); }
}
// True from a press until it is released. A preview must not take the pointer
// while the press that made it is still down, or the click that opens the
// window lands on the preview and dismisses the open it was waiting for.
var jawnosWindowEmergePointerDown = false;
// Windows the person took back before they painted: keyed by the reservation's
// timestamp when there is one, otherwise by app. The landing window is hidden
// and closed instead of shown.
var jawnosWindowEmergeDismissals = {};
// The click that belongs to a dismissing press, so the opener is not asked a
// second time.
var jawnosWindowEmergeClickBlock = null;

// One place for the level's manners: a light desk only hints at the flow, the
// maximum lets it travel and overshoot. `travel` is how far the sheet's centre
// has gone by its overshoot frame; `window` is the window's own fade-in;
// `ghost` is the press-time preview's growth and `retarget` is the cross-fade
// from that preview to the real rectangle.
var jawnosWindowEmergeShape = {
	light:   { duration: 220, travel: 0.55, overshoot: 1.015, window: 180, delay: 40,  ghost: 180, retarget: 140 },
	medium:  { duration: 340, travel: 0.72, overshoot: 1.060, window: 240, delay: 90,  ghost: 280, retarget: 220 },
	maximum: { duration: 460, travel: 0.82, overshoot: 1.100, window: 320, delay: 120, ghost: 400, retarget: 300 }
};

// The prediction's dials. The arithmetic lives in jawnosWindowEmergePredict;
// these are the few numbers a measurement pass can move without rewriting it.
// `across` and the bar/border fallbacks mirror windowTileAcrossStep and the CSS
// defaults; the live values come from jawnosBars (navbar - border) first. The
// foot is windowFit's own: shrink the height to the viewport, never move the
// slot's top (the measured table matches that; a bottom bar is not subtracted
// from a tiled window).
var JAWNOS_EMERGE_GEOMETRY = {
	across: 50,
	barFallback: 36,
	borderFallback: 3,
	minWidth: 240,
	minHeight: 240
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

function jawnosEmergeTrim(text) {
	return String(text || '').replace(/^\s+|\s+$/g, '');
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
		// The preview can be drawn before the server names the window: the
		// pressed control already knows which app it opens and what it looks
		// like.
		icon: rect.icon || '',
		name: rect.name || '',
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
// or pin wears the app, a start-menu icon wears an id in the toggle map, and
// the switcher's cell carries a window_toggle inside it.
function jawnosWindowOriginApp(el) {
	if (!el || el.nodeType !== 1) { return ''; }
	var app = (el.getAttribute && (el.getAttribute('app') || el.getAttribute('data-app'))) || '';
	if (app) { return app; }
	if (el.id && typeof startMenuIconApps != 'undefined' && startMenuIconApps[el.id]) {
		return startMenuIconApps[el.id];
	}
	var host = (el.closest ? el.closest('.window_toggle, .taskbar_pin, .start_menu_item, .app, .manager_search_result') : null);
	if (host) {
		var host_app = (host.getAttribute && host.getAttribute('app')) || '';
		if (host_app) { return host_app; }
		var toggle = (host.querySelector ? host.querySelector('.window_toggle') : null);
		if (toggle && toggle.getAttribute && toggle.getAttribute('app')) {
			return toggle.getAttribute('app');
		}
		var img = (host.querySelector ? host.querySelector('img') : null);
		if (img && img.id && typeof startMenuIconApps != 'undefined' && startMenuIconApps[img.id]) {
			return startMenuIconApps[img.id];
		}
	}
	return '';
}

// A pressed control's picture and its on-screen name. The start menu's icon
// wears `hint`, a taskbar pin wears `hint`, a window tile wears
// `formatted_name`; the first one found wins, and the app name is the last
// resort so the preview is never nameless.
function jawnosWindowOriginImage(el) {
	if (!el || el.nodeType !== 1) { return ''; }
	var img = null;
	if (el.tagName == 'IMG') { img = el; }
	if (!img && el.querySelector) { img = el.querySelector('.taskbar_app_pin_icon, .window_toggle_icon, .window_icon'); }
	if (!img && el.querySelector) { img = el.querySelector('img'); }
	if (!img) { return ''; }
	var src = (img.getAttribute && (img.getAttribute('src') || '')) || img.src || '';
	return src || '';
}

function jawnosWindowOriginLabel(el, app) {
	if (!el || el.nodeType !== 1) { return app || ''; }
	var candidates = [el];
	if (el.querySelector) {
		var name_el = el.querySelector('.window_toggle_name_text, .start_menu_item_text, .window_toggle_name');
		if (name_el && name_el.textContent) {
			var named = jawnosEmergeTrim(name_el.textContent);
			if (named) { return named; }
		}
		var toggle = el.querySelector('.window_toggle');
		if (toggle) { candidates.push(toggle); }
		var img = el.querySelector('img');
		if (img) { candidates.push(img); }
	}
	var attrs = ['formatted_name', 'hint', 'title', 'alt'];
	for (var c = 0; c < candidates.length; c++) {
		var node = candidates[c];
		if (!node || !node.getAttribute) { continue; }
		for (var a = 0; a < attrs.length; a++) {
			var value = node.getAttribute(attrs[a]);
			if (value) { return value; }
		}
	}
	if (app && typeof format_name == 'function') { return format_name(app); }
	return app || '';
}

// A start-menu icon for an app that was pressed somewhere with no DOM icon
// beside it (a clothesline pill). The menu already holds every built-in icon,
// so this is a lookup rather than a second copy of the icon table.
function jawnosWindowOriginIconForApp(app) {
	if (!app || typeof document == 'undefined' || !document.getElementById) { return ''; }
	if (typeof startMenuIconApps == 'undefined') { return ''; }
	for (var id in startMenuIconApps) {
		if (!startMenuIconApps.hasOwnProperty(id) || startMenuIconApps[id] !== app) { continue; }
		var img = document.getElementById(id);
		var src = img && (img.getAttribute ? (img.getAttribute('src') || '') : (img.src || ''));
		if (src) { return src; }
	}
	return '';
}

function jawnosWindowOriginFromElement(el, app, now) {
	if (!el || el.nodeType !== 1 || !el.getBoundingClientRect) { return null; }
	var rect = el.getBoundingClientRect();
	if (!rect || !rect.width || !rect.height) { return null; }
	app = app || jawnosWindowOriginApp(el);
	return jawnosWindowOriginSet({
		left: rect.left,
		top: rect.top,
		width: rect.width,
		height: rect.height,
		radius: Math.min(rect.width, rect.height) * 0.28,
		icon: jawnosWindowOriginImage(el),
		name: jawnosWindowOriginLabel(el, app)
	}, app, now);
}

// A canvas has no element per control, so its painter reports the pressed
// pill's rectangle in viewport units: the press point is the centre and the
// measured box gives the size. The painter may also pass a seventh argument
// (an object) with the app's icon/name when it has them, so the preview can be
// drawn at once; a numeric seventh argument is still the timestamp.
function jawnosWindowOriginFromPoint(x, y, width, height, radius, app, now, meta) {
	if (now && typeof now === 'object') { meta = now; now = undefined; }
	meta = meta || {};
	var w = Math.max(6, jawnosEmergeNumber(width, 6));
	var h = Math.max(6, jawnosEmergeNumber(height, 6));
	return jawnosWindowOriginSet({
		left: jawnosEmergeNumber(x, 0) - w / 2,
		top: jawnosEmergeNumber(y, 0) - h / 2,
		width: w,
		height: h,
		radius: radius,
		icon: meta.icon || '',
		name: meta.name || ''
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

// The preview is taken the same way: once, and only by a window that answers
// for its app. An app-less ghost is the latest press, so any window may take it.
function jawnosWindowEmergeGhostTake(app) {
	var ghost = jawnosWindowEmergeGhost;
	if (!ghost) { return null; }
	if (app && ghost.app && ghost.app != app) { return null; }
	// an app-less window must not claim a named control's preview
	if (!app && ghost.app) { return null; }
	jawnosWindowEmergeGhost = null;
	return ghost;
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

function jawnosEmergePx(value) {
	if (typeof value != 'string') { return undefined; }
	var match = /^(-?\d+(?:\.\d+)?)px$/.exec(value);
	return match ? parseFloat(match[1]) : undefined;
}

// The window's own layout box, not its transformed rect. A window arriving
// mid-enter is at scale(0.985), so getBoundingClientRect reports 472.8x630.4
// for a 480x640 window; retargeting the ghost there leaves it 1.5% small.
// The settled CSS left/top/width/height (or offsetWidth/offsetHeight for a
// percentage width, as a phone uses) are the layout pixels the ghost speaks.
function jawnosWindowEmergeLayoutRect(el, measured, zoom) {
	zoom = (isFinite(zoom) && zoom > 0) ? zoom : 1;
	var left = el && el.style ? jawnosEmergePx(el.style.left) : undefined;
	var top = el && el.style ? jawnosEmergePx(el.style.top) : undefined;
	var width = el && el.style ? jawnosEmergePx(el.style.width) : undefined;
	var height = el && el.style ? jawnosEmergePx(el.style.height) : undefined;
	if (left === undefined) { left = measured.left / zoom; }
	if (top === undefined) { top = measured.top / zoom; }
	if (width === undefined || !width) { width = (el && el.offsetWidth) || (measured.width / zoom); }
	if (height === undefined || !height) { height = (el && el.offsetHeight) || (measured.height / zoom); }
	return { left: left, top: top, width: width, height: height };
}

function jawnosWindowEmergeCssNumber(name, fallback) {
	try {
		if (typeof getComputedStyle == 'function' && typeof document != 'undefined' && document.documentElement) {
			var value = parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name));
			if (isFinite(value)) { return value; }
		}
	}
	catch (e) {}
	return fallback;
}

// The same viewport windowFit reads, so the prediction and the real fit agree
// about a display-zoomed desk: visualViewport first, then the jQuery viewport.
function jawnosWindowEmergeViewport() {
	try {
		if (typeof windowViewport == 'function') {
			var fitted = windowViewport();
			if (fitted && fitted.width > 0 && fitted.height > 0) {
				return { width: fitted.width, height: fitted.height };
			}
		}
	}
	catch (e) {}
	var width = 0;
	var height = 0;
	try {
		if (typeof window != 'undefined') {
			width = (window.visualViewport && window.visualViewport.width) || window.innerWidth || 0;
			height = (window.visualViewport && window.visualViewport.height) || window.innerHeight || 0;
		}
		if ((!width || !height) && typeof document != 'undefined' && document.documentElement) {
			width = width || document.documentElement.clientWidth || 0;
			height = height || document.documentElement.clientHeight || 0;
		}
	}
	catch (e) {}
	return { width: width || 1024, height: height || 768 };
}

function jawnosWindowEmergeRadius() {
	return jawnosWindowEmergeCssNumber('--window_radius', 12);
}

// The app's saved title-bar colour and ink, seeded by the layout's
// jawnos_app_colours map (lib/JawnOS/Domain/Contrast.pm's app_colour_map). No
// hash, no guess: the preview paints exactly what the real navbar paints.
function jawnosWindowEmergeAppColour(app) {
	if (!app) { return null; }
	var map = null;
	try {
		if (typeof jawnos_app_colours != 'undefined') { map = jawnos_app_colours; }
		else if (typeof window != 'undefined') { map = window.jawnos_app_colours; }
	}
	catch (e) {}
	if (!map || !map[app]) { return null; }
	var info = map[app];
	if (!info || !info.colour) { return null; }
	return info;
}

// A pinned window's saved place, seeded by the layout's jawnos_app_places map
// (subs::app_window_places). The box is in the saved screen's pixels; the
// caller rescales it exactly as windowPlaceRestore does.
function jawnosWindowEmergeAppPlace(app) {
	if (!app) { return null; }
	var map = null;
	try {
		if (typeof jawnos_app_places != 'undefined') { map = jawnos_app_places; }
		else if (typeof window != 'undefined') { map = window.jawnos_app_places; }
	}
	catch (e) {}
	if (!map || !map[app]) { return null; }
	var place = map[app];
	if (!place || !(place.width > 0) || !(place.height > 0) || !(place.vw > 0) || !(place.vh > 0)) { return null; }
	return place;
}

// windowPlaceRestore's rescale, in layout pixels: keep the edge the window was
// nearest (right or bottom), scale by the smaller of the two screen ratios,
// and never go below 240x160. The exact clamp in jawnosWindowEmergePredict
// applies windowFit afterwards, as it does to the real window.
function jawnosWindowEmergePlaceRect(place, view) {
	if (!place || !view) { return null; }
	var saved_w = jawnosEmergeNumber(place.vw, 0);
	var saved_h = jawnosEmergeNumber(place.vh, 0);
	var now_w = jawnosEmergeNumber(view.width, 0);
	var now_h = jawnosEmergeNumber(view.height, 0);
	var left = jawnosEmergeNumber(place.left, 0);
	var top = jawnosEmergeNumber(place.top, 0);
	var width = jawnosEmergeNumber(place.width, 0);
	var height = jawnosEmergeNumber(place.height, 0);
	if (!saved_w || !saved_h || !now_w || !now_h || !width || !height) { return null; }
	// a place saved on this exact screen is used as it stands
	if (Math.abs(saved_w - now_w) < 8 && Math.abs(saved_h - now_h) < 8) {
		return { left: left, top: top, width: width, height: height };
	}
	var scale = Math.min(now_w / saved_w, now_h / saved_h);
	if (!isFinite(scale) || scale <= 0) { return null; }
	var from_right = saved_w - (left + width);
	var from_bottom = saved_h - (top + height);
	var new_w = Math.max(240, Math.round(width * scale));
	var new_h = Math.max(160, Math.round(height * scale));
	var new_left = (from_right < left) ? (now_w - from_right - new_w) : (left * scale);
	var new_top = (from_bottom < top) ? (now_h - from_bottom - new_h) : (top * scale);
	return {
		left: Math.max(0, Math.round(new_left)),
		top: Math.max(0, Math.round(new_top)),
		width: new_w,
		height: new_h
	};
}

// The small set of skeleton bodies. The app name is all the press has, so the
// map is the whole rule; an unknown app keeps the neutral generic body.
var jawnosWindowEmergeArchetypes = {
	terminal: ['terminal', 'ide', 'embedded', 'console', 'process_monitor'],
	grid:     ['gallery', 'cards', 'store', 'controllers', 'box_office', 'home', 'twirl'],
	media:    ['music', 'synth', 'studio', 'video', 'camera'],
	map:      ['travel', 'maps', 'map'],
	chat:     ['chat'],
	calendar: ['clock', 'calendar', 'schedule'],
	list:     ['notes', 'editor', 'budget', 'relational', 'email', 'search', 'internet',
		'security', 'notifications', 'weather', 'configure', 'handbook', 'help', 'files', 'folders']
};

function jawnosWindowEmergeArchetype(app) {
	if (!app) { return 'generic'; }
	for (var kind in jawnosWindowEmergeArchetypes) {
		if (!jawnosWindowEmergeArchetypes.hasOwnProperty(kind)) { continue; }
		if (jawnosWindowEmergeArchetypes[kind].indexOf(app) >= 0) { return kind; }
	}
	return 'generic';
}

// The step a phone's cascade has already taken: every window on this desk,
// plus presses whose windows have not landed yet. windowReorganizer uses the
// same count (winCount) and the bar's outer height less its border.
function jawnosWindowEmergePhoneSlot(stack) {
	stack = stack || '0';
	var count = 0;
	try {
		if (typeof $ == 'function') {
			$('.wind').each(function () {
				if (typeof jawnosWorkspaceWindowHere == 'function' && !jawnosWorkspaceWindowHere(this)) { return; }
				count++;
			});
		}
		else if (typeof document != 'undefined' && document.querySelectorAll) {
			var winds = document.querySelectorAll('.wind');
			for (var i = 0; i < winds.length; i++) {
				if (typeof jawnosWorkspaceWindowHere == 'function' && !jawnosWorkspaceWindowHere(winds[i])) { continue; }
				count++;
			}
		}
	}
	catch (e) {}
	try {
		if (typeof windowTiledPending != 'undefined' && windowTiledPending) {
			var now = Date.now();
			for (var stamp in windowTiledPending) {
				if (!windowTiledPending.hasOwnProperty(stamp)) { continue; }
				var pending = windowTiledPending[stamp];
				if (!pending) { continue; }
				if ((pending.stack || stack) !== stack) { continue; }
				if (now - (pending.at || 0) > 20000) { continue; }
				count++;
			}
		}
	}
	catch (e) {}
	return count;
}

// The frame a fresh window is about to take: the standard 480x640 at the slot
// the press will occupy. It follows the real placer's geometry - the same
// viewport source, windowTopLimit(), jawnosBars' navbar/border step, the
// cascade's across step and a reservation this press already made - and then
// applies windowFit's own clamp and 240px floors. `near` is the already
// zoom-corrected press rectangle, used only when the page has no placer.
function jawnosWindowEmergePredict(origin, near) {
	origin = origin || {};
	var view = jawnosWindowEmergeViewport();
	var width = (typeof windowTileDefaultWidth == 'number' && windowTileDefaultWidth > 0) ? windowTileDefaultWidth : 480;
	var height = (typeof windowTileDefaultHeight == 'number' && windowTileDefaultHeight > 0) ? windowTileDefaultHeight : 640;
	var left = 0;
	var top = 0;
	var placed = false;
	var topLimit = (typeof windowTopLimit == 'function') ? Math.max(0, jawnosEmergeNumber(windowTopLimit(), 0)) : 0;
	var across = (typeof windowTileAcrossStep == 'number' && windowTileAcrossStep > 0)
		? windowTileAcrossStep : JAWNOS_EMERGE_GEOMETRY.across;
	// The cascade's step is the bar less its border, from the same setting the
	// window's own title bar wears. The CSS defaults (36/3) are only for a page
	// with no jawnosBars yet; a 44/2 desk must step 42, not 33.
	var bar = JAWNOS_EMERGE_GEOMETRY.barFallback;
	var border = JAWNOS_EMERGE_GEOMETRY.borderFallback;
	if (typeof jawnosBars != 'undefined' && jawnosBars) {
		if (jawnosBars.navbar !== undefined && jawnosBars.navbar !== null) {
			bar = jawnosEmergeNumber(jawnosBars.navbar, bar);
		}
		if (jawnosBars.border !== undefined && jawnosBars.border !== null) {
			border = jawnosEmergeNumber(jawnosBars.border, border);
		}
	}
	var step = Math.max(20, bar - border);
	var stack = (typeof jawnosWorkspaceStackDefault == 'function')
		? jawnosWorkspaceStackDefault()
		: ((typeof windowTiledDefaultStack != 'undefined') ? windowTiledDefaultStack : '0');
	var slot = (typeof windowNextTileSlot == 'function') ? (windowNextTileSlot(stack) || 0) : 0;

	// A lazy replay or a bespoke opener may already have reserved this press's
	// slot. The window lands there, so the picture has to be drawn there too -
	// including the pile the reservation chose, which may not be the default one.
	var press_pending = null;
	if (origin.app && typeof windowTiledPendingApp != 'undefined' && typeof windowTiledPending != 'undefined') {
		var stamp = windowTiledPendingApp[origin.app];
		var pending = stamp && windowTiledPending[stamp];
		if (pending && pending.slot >= 0) {
			press_pending = pending;
			if ((pending.stack || stack) === stack) { slot = pending.slot; }
		}
	}

	var phone = (typeof windowPhoneChecker == 'function' && windowPhoneChecker());

	// A pinned window opens at the place it was pinned to, not in the cascade.
	// A phone ignores the saved place (Part22 only pre-dimensions a non-phone).
	if (!phone) {
		var saved_place = jawnosWindowEmergeAppPlace(origin.app);
		if (saved_place) {
			var saved_rect = jawnosWindowEmergePlaceRect(saved_place, view);
			if (saved_rect) {
				left = saved_rect.left;
				top = saved_rect.top;
				width = saved_rect.width;
				height = saved_rect.height;
				placed = true;
			}
		}
	}

	if (!placed && phone) {
		// the real window is width:100% / height:71.28% in the same layout pixels
		// windowViewport reports; its top steps down the pile like the desk
		width = view.width;
		height = Math.round(view.height * 0.7128);
		left = 0;
		if (typeof windowPhoneCascadePlace == 'function') {
			// the deck the window will join, and its step in that deck's cascade
			var phone_plan = windowPhoneCascadePlace({ height: height, step: step });
			top = jawnosEmergeNumber(phone_plan.top, topLimit) + phone_plan.slot * step;
		}
		else {
			top = topLimit + jawnosWindowEmergePhoneSlot(stack) * step;
		}
		placed = true;
	}
	else if (!placed && press_pending && typeof windowTiledAnchor == 'function') {
		// the reservation is where the window will land, whatever pile it chose
		var press_anchor = windowTiledAnchor(press_pending.stack || stack) || { left: 0, top: topLimit };
		left = jawnosEmergeNumber(press_anchor.left, 0) + press_pending.slot * across;
		top = jawnosEmergeNumber(press_anchor.top, topLimit) + press_pending.slot * step;
		placed = true;
	}
	else if (!placed && typeof windowTiledCascadePlace == 'function') {
		// the same answer the placement itself takes: the right-most pile with
		// room, or a fresh one half a window across
		var next_place = windowTiledCascadePlace(null, { width: width, height: height, step: step });
		left = jawnosEmergeNumber(next_place.anchor.left, 0) + next_place.slot * across;
		top = jawnosEmergeNumber(next_place.anchor.top, topLimit) + next_place.slot * step;
		placed = true;
	}
	else if (!placed && typeof windowTiledAnchor == 'function') {
		var anchor = windowTiledAnchor(stack) || { left: 0, top: topLimit };
		left = jawnosEmergeNumber(anchor.left, 0) + slot * across;
		top = jawnosEmergeNumber(anchor.top, topLimit) + slot * step;
		placed = true;
	}

	if (!placed) {
		// no stack reader on this page: stand the preview beside the press
		if (!near) { near = jawnosWindowEmergeCssRect(origin, jawnosWindowEmergeZoom(null, origin)); }
		left = jawnosEmergeNumber(near.left, 0);
		top = jawnosEmergeNumber(near.top, 0);
	}

	if (left < 0) { left = 0; }
	if (top < 0) { top = 0; }
	// Exactly windowFit's clamp, in its order: shrink the box to the room,
	// then slide it back on screen only if the floor (240) still overhangs.
	// The slot's top is kept; the height is what gives way.
	if (left + width > view.width) {
		width = Math.max(JAWNOS_EMERGE_GEOMETRY.minWidth, view.width - left);
	}
	if (top + height > view.height) {
		height = Math.max(JAWNOS_EMERGE_GEOMETRY.minHeight, view.height - top);
	}
	if (left + width > view.width) {
		left = Math.max(0, view.width - width);
	}
	if (top + height > view.height) {
		top = Math.max(0, view.height - height);
	}
	// windowMaker's own guard, applied after windowFit: no window opens in the
	// desk's top strip (40px) or hanging off the right edge, so a cascade that
	// starts at 0 lands at 40 instead of where the tile placed it. windowFit is
	// not run again after this, so only the edge moves. Without it a phone and a
	// desk with no top bar preview 40px too high, then jump down when the
	// window arrives.
	if (left >= view.width - 40) { left = 0; }
	if (top <= 40) { top = 40; }
	if (top >= view.height - 40) { top = 40; }

	return {
		left: left,
		top: top,
		width: width,
		height: height,
		radius: jawnosWindowEmergeRadius()
	};
}

// One skeleton body per archetype: neutral theme surfaces, no words. The
// shapes are painted by the rules appended to the emerge block in manager.css;
// this builds only the boxes, so the handoff to real content is a change of
// tone rather than a change of silhouette.
function jawnosWindowEmergeSkeleton(kind) {
	var body = jawnosEmergeElement('div', 'jawnos_emerge_body jawnos_emerge_body_' + kind + ' jawnos_emerge_skeleton jawnos_emerge_skeleton_' + kind);
	if (!body) { return null; }
	var i;
	var wrap;
	if (kind === 'list') {
		for (i = 0; i < 6; i++) {
			var row = jawnosEmergeElement('div', 'jawnos_emerge_row');
			jawnosEmergeAppend(row, jawnosEmergeElement('span', 'jawnos_emerge_dot'));
			var lines = jawnosEmergeElement('span', 'jawnos_emerge_lines');
			jawnosEmergeAppend(lines, jawnosEmergeElement('span', 'jawnos_emerge_line jawnos_emerge_line_wide'));
			jawnosEmergeAppend(lines, jawnosEmergeElement('span', 'jawnos_emerge_line'));
			jawnosEmergeAppend(row, lines);
			jawnosEmergeAppend(body, row);
		}
	}
	else if (kind === 'grid') {
		for (i = 0; i < 6; i++) {
			jawnosEmergeAppend(body, jawnosEmergeElement('div', 'jawnos_emerge_tile'));
		}
	}
	else if (kind === 'terminal') {
		wrap = jawnosEmergeElement('div', 'jawnos_emerge_term');
		for (i = 0; i < 5; i++) {
			var term_line = jawnosEmergeElement('div', 'jawnos_emerge_term_line jawnos_emerge_term_line_' + i);
			jawnosEmergeAppend(wrap, term_line);
		}
		jawnosEmergeAppend(body, wrap);
	}
	else if (kind === 'media') {
		jawnosEmergeAppend(body, jawnosEmergeElement('div', 'jawnos_emerge_media_art'));
		wrap = jawnosEmergeElement('div', 'jawnos_emerge_media_bars');
		for (i = 0; i < 3; i++) {
			jawnosEmergeAppend(wrap, jawnosEmergeElement('span', 'jawnos_emerge_media_bar jawnos_emerge_media_bar_' + i));
		}
		jawnosEmergeAppend(body, wrap);
	}
	else if (kind === 'map') {
		wrap = jawnosEmergeElement('div', 'jawnos_emerge_map');
		jawnosEmergeAppend(wrap, jawnosEmergeElement('span', 'jawnos_emerge_map_route'));
		jawnosEmergeAppend(wrap, jawnosEmergeElement('span', 'jawnos_emerge_map_pin'));
		jawnosEmergeAppend(body, wrap);
	}
	else if (kind === 'chat') {
		for (i = 0; i < 4; i++) {
			var bubble = jawnosEmergeElement('div', 'jawnos_emerge_bubble ' + (i % 2 ? 'jawnos_emerge_bubble_out' : 'jawnos_emerge_bubble_in'));
			jawnosEmergeAppend(body, bubble);
		}
	}
	else if (kind === 'calendar') {
		wrap = jawnosEmergeElement('div', 'jawnos_emerge_calendar');
		for (i = 0; i < 28; i++) {
			jawnosEmergeAppend(wrap, jawnosEmergeElement('span', 'jawnos_emerge_cell'));
		}
		jawnosEmergeAppend(body, wrap);
	}
	else {
		for (i = 0; i < 3; i++) {
			jawnosEmergeAppend(body, jawnosEmergeElement('div', 'jawnos_emerge_block jawnos_emerge_block_' + i));
		}
	}
	return body;
}

function jawnosEmergeElement(tag, className, text) {
	var el = (typeof document != 'undefined' && document.createElement) ? document.createElement(tag) : null;
	if (!el) { return null; }
	if (className) { el.className = className; }
	if (text !== undefined) { el.textContent = text; }
	return el;
}

function jawnosEmergeAppend(parent, child) {
	if (parent && child && parent.appendChild) { parent.appendChild(child); }
}

function jawnosEmergeBoxStyle(el, rect) {
	if (!el || !el.style) { return; }
	el.style.left = rect.left + 'px';
	el.style.top = rect.top + 'px';
	el.style.width = rect.width + 'px';
	el.style.height = rect.height + 'px';
	if (rect.radius !== undefined) { el.style.borderRadius = rect.radius + 'px'; }
}

// The chrome every app window wears: a title bar at the navbar's height, the
// pressed app's icon and name, and the same minimise/maximise/close controls.
// It is inert and click-through; it is a picture of a window, not a window.
function jawnosWindowEmergeChrome(origin) {
	origin = origin || {};
	var chrome = jawnosEmergeElement('div', 'jawnos_emerge_chrome');
	if (!chrome) { return null; }
	var bar = jawnosEmergeElement('div', 'jawnos_emerge_bar');
	// The real navbar carries data-appt-tint="yes"; universal.css repaints that
	// hook with --appt-dark on a dark desk. The ghost needs the same hook, or it
	// keeps the light inline colour while the real bar changes. The name and
	// controls then follow manager.css's dark-theme ink rule, as top_navbar does.
	if (bar && bar.setAttribute) { bar.setAttribute('data-appt-tint', 'yes'); }
	// The real window's title bar is the app's saved colour and the ink that
	// reads on it. Set it inline so there is no rule to keep in step; on a dark
	// desk the shared stylesheet brings the bar back to the theme ink, exactly
	// as top_navbar does for the real window.
	var app_colour = jawnosWindowEmergeAppColour(origin.app);
	if (bar && app_colour) {
		if (app_colour.colour) { bar.style.backgroundColor = app_colour.colour; }
		if (app_colour.ink) { bar.style.color = app_colour.ink; }
		if (bar.style.setProperty) {
			bar.style.setProperty('--appt-dark', app_colour.dark || '');
			bar.style.setProperty('--appt-dark-ink', app_colour.dark_ink || '');
		}
	}
	var icon_holder = jawnosEmergeElement('span', 'jawnos_emerge_icon_holder');
	var icon_src = origin.icon || jawnosWindowOriginIconForApp(origin.app);
	if (icon_src) {
		var img = jawnosEmergeElement('img', 'jawnos_emerge_icon');
		if (img && img.setAttribute) {
			img.setAttribute('src', icon_src);
			img.setAttribute('alt', '');
			icon_holder.appendChild(img);
		}
	}
	else {
		var initial = (origin.name || origin.app || '?').replace(/^\s+/, '').charAt(0).toUpperCase() || '?';
		jawnosEmergeAppend(icon_holder, jawnosEmergeElement('span', 'jawnos_emerge_initial', initial));
	}
	var name = jawnosEmergeElement('span', 'jawnos_emerge_name');
	if (name) {
		name.textContent = origin.name || ((origin.app && typeof format_name == 'function') ? format_name(origin.app) : (origin.app || ''));
	}
	var buttons = jawnosEmergeElement('span', 'jawnos_emerge_buttons');
	if (buttons) {
		var controls = [
			['minimize', '\u2013'],
			['maximize', '\u25a1'],
			['close', '\u00d7']
		];
		for (var i = 0; i < controls.length; i++) {
			jawnosEmergeAppend(buttons, jawnosEmergeElement('span', 'jawnos_emerge_button jawnos_emerge_button_' + controls[i][0], controls[i][1]));
		}
	}
	jawnosEmergeAppend(bar, icon_holder);
	jawnosEmergeAppend(bar, name);
	jawnosEmergeAppend(bar, buttons);
	jawnosEmergeAppend(chrome, bar);
	var archetype = jawnosWindowEmergeArchetype(origin.app);
	jawnosEmergeAppend(chrome, jawnosWindowEmergeSkeleton(archetype));
	return chrome;
}

// Put the preview away. It is called by a new press, by the TTL, by the window
// it became being closed or hidden, and by effects being switched off; each
// caller may pass the record or nothing (the current one).
function jawnosWindowEmergeGhostCancel(ghost) {
	if (ghost === undefined) { ghost = jawnosWindowEmergeGhost; }
	if (!ghost) { return; }
	if (jawnosWindowEmergeGhost === ghost) { jawnosWindowEmergeGhost = null; }
	if (ghost.timer) {
		clearTimeout(ghost.timer);
		ghost.timer = null;
	}
	if (ghost.openAnim) {
		try { ghost.openAnim.cancel(); } catch (e) {}
		ghost.openAnim = null;
	}
	if (ghost.pourTimer) {
		clearTimeout(ghost.pourTimer);
		ghost.pourTimer = null;
	}
	if (ghost.retargetAnims) {
		for (var r = 0; r < ghost.retargetAnims.length; r++) {
			try { ghost.retargetAnims[r].cancel(); } catch (e) {}
		}
		ghost.retargetAnims = null;
	}
	if (ghost.retargetAnim) {
		try { ghost.retargetAnim.cancel(); } catch (e) {}
		ghost.retargetAnim = null;
	}
	if (ghost.chromeAnim) {
		try { ghost.chromeAnim.cancel(); } catch (e) {}
		ghost.chromeAnim = null;
	}
	if (ghost.observer) {
		try { ghost.observer.disconnect(); } catch (e) {}
		ghost.observer = null;
	}
	var el = ghost.el;
	ghost.el = null;
	if (el) {
		if (ghost.win && ghost.win.jawnosEmergeGhost === ghost) { ghost.win.jawnosEmergeGhost = null; }
		if (el.parentNode) { el.parentNode.removeChild(el); }
	}
	ghost.win = null;
}

// The preview is held while a window for its app is still on its way. The press
// that opened it reserved a slot (windowTiledReserve) before the server was
// asked, so the reservation is the honest "still loading" signal: an app-less
// press, or one that opened nothing, has none and keeps the old short TTL.
function jawnosWindowEmergeGhostPending(ghost) {
	if (!ghost || !ghost.app) { return false; }
	try {
		if (typeof windowTiledPendingApp == 'undefined' || !windowTiledPendingApp) { return false; }
		return !!windowTiledPendingApp[ghost.app];
	}
	catch (e) { return false; }
}

// The old ceiling hid the preview before a slow app could paint, leaving a blank
// desk between the press and the window. While the open is still in flight the
// preview stands where it is; the motion is untouched, only its lifetime grows.
function jawnosWindowEmergeGhostExpire(ghost) {
	if (!ghost || jawnosWindowEmergeGhost !== ghost) { return; }
	ghost.timer = null;
	ghost.waited = (ghost.waited || 0) + JAWNOS_EMERGE_GHOST_TTL;
	if (ghost.waited < JAWNOS_EMERGE_GHOST_MAX && jawnosWindowEmergeGhostPending(ghost)) {
		ghost.timer = setTimeout(function () { jawnosWindowEmergeGhostExpire(ghost); }, JAWNOS_EMERGE_GHOST_TTL);
		return;
	}
	// the open never answered: a press kept against the picture has no window to
	// be replayed on, so it is dropped rather than fired later against a stale one
	if (ghost.app && typeof jawnosPredictionPressQueue != 'undefined' && jawnosPredictionPressQueue) {
		jawnosPredictionPressQueue.drop(ghost.app);
	}
	jawnosWindowEmergeGhostCancel(ghost);
}

// Is this node the preview, or inside it? A press on the ghost is a dismissal,
// not a press on the desk underneath.
function jawnosWindowEmergeGhostHolds(ghost, el) {
	if (!ghost || !ghost.el || !el || el.nodeType !== 1) { return false; }
	var node = ghost.el;
	if (el === node) { return true; }
	if (node.contains && node.contains(el)) { return true; }
	var parent = el.parentNode;
	while (parent) {
		if (parent === node) { return true; }
		parent = parent.parentNode;
	}
	return false;
}

// The waiting preview is the one live control on the desk: it takes the pointer
// so a press on it can be a dismissal. The class comes off at retarget, so the
// cross-fade is click-through again.
function jawnosWindowEmergeGhostWaiting(el) {
	if (!el) { return; }
	if (el.classList && el.classList.add) { el.classList.add('jawnos_emerge_waiting'); return; }
	if (String(el.className || '').indexOf('jawnos_emerge_waiting') < 0) { el.className = (el.className ? el.className + ' ' : '') + 'jawnos_emerge_waiting'; }
}

// The waiting preview takes the pointer so a press on it can be a dismissal -
// but only once it has arrived (poured), the press that started it is over, and
// its own click has passed. Arming earlier swallows the click that opens the
// window, which is the one click this preview must never eat.
function jawnosWindowEmergeGhostArm(ghost) {
	if (!ghost || !ghost.el || ghost.win || ghost.armed) { return false; }
	if (jawnosWindowEmergePointerDown) { return false; }
	if (Date.now() - (ghost.at || 0) < 250) {
		if (!ghost.armTimer && typeof setTimeout == 'function') {
			ghost.armTimer = setTimeout(function () {
				ghost.armTimer = null;
				jawnosWindowEmergeGhostArm(ghost);
			}, 260);
		}
		return false;
	}
	if (!ghost.poured) { return false; }
	ghost.armed = true;
	jawnosWindowEmergeGhostWaiting(ghost.el);
	return true;
}

function jawnosWindowEmergeGhostPassThrough(el) {
	if (!el) { return; }
	if (el.classList && el.classList.remove) { el.classList.remove('jawnos_emerge_waiting'); return; }
	el.className = String(el.className || '').replace(/(^|\s)jawnos_emerge_waiting(?=\s|$)/g, '').replace(/^\s+|\s+$/g, '');
}

function jawnosWindowEmergeDismissedPrune(now) {
	var stamp = (now === undefined) ? Date.now() : now;
	for (var key in jawnosWindowEmergeDismissals) {
		if (!jawnosWindowEmergeDismissals.hasOwnProperty(key)) { continue; }
		var record = jawnosWindowEmergeDismissals[key];
		if (!record || stamp - record.at > JAWNOS_EMERGE_DISMISS_TTL) { delete jawnosWindowEmergeDismissals[key]; }
	}
}

// Take back the open the preview was waiting for. The opener may already be on
// the server round trip, so this records which landing to cancel rather than
// pretending the request never happened. The reservation's timestamp identifies
// the exact window; an opener with no reservation falls back to its app.
function jawnosWindowEmergeDismiss(ghost) {
	if (ghost === undefined) { ghost = jawnosWindowEmergeGhost; }
	if (!ghost) { return false; }
	var app = ghost.app || '';
	var stamp = '';
	try {
		if (app && typeof windowTiledPendingApp != 'undefined' && windowTiledPendingApp && windowTiledPendingApp[app]) {
			stamp = String(windowTiledPendingApp[app]);
		}
	}
	catch (e) {}
	var now = Date.now();
	jawnosWindowEmergeDismissedPrune(now);
	var key = stamp || (app ? ('app:' + app) : '');
	if (key) {
		jawnosWindowEmergeDismissals[key] = { app: app, stamp: stamp, at: now };
	}
	// a dismissal cancels the open, so a press kept against its picture must not
	// fire against the window that is now being taken back
	if (app && typeof jawnosPredictionPressQueue != 'undefined' && jawnosPredictionPressQueue) {
		jawnosPredictionPressQueue.drop(app);
	}
	jawnosWindowEmergeGhostCancel(ghost);
	return true;
}

// Put a landed window away instead of letting it appear after its preview was
// dismissed. closeWindow is the desk's own teardown (taskbar tile, server
// record, websocket), so the cancelled open leaves nothing behind; a page
// without it still keeps the window off the screen.
function jawnosWindowEmergeTakeBack($win, el) {
	if (el && el.jawnosEmergeGhost) { jawnosWindowEmergeCancel(el); }
	var stamp = ($win && typeof $win.attr == 'function') ? ($win.attr('timestamp') || '') : '';
	if (stamp && typeof closeWindow == 'function') {
		closeWindow(stamp);
		return true;
	}
	if ($win && typeof $win.hide == 'function') { $win.hide(); }
	else if (el && el.parentNode) { el.parentNode.removeChild(el); }
	return true;
}

// The handoff: did this landing answer a dismissed preview? Returns true when
// the window was taken back, so windowMaker can skip the emerge motion.
function jawnosWindowEmergeDismissed(win) {
	if (!win) { return false; }
	var $win = (typeof $ == 'function') ? $(win) : null;
	var el = ($win && $win.length) ? $win[0] : ((win.nodeType === 1) ? win : null);
	if (!el) { return false; }
	var app = '';
	var stamp = '';
	try {
		if ($win && typeof $win.attr == 'function') {
			app = $win.attr('app') || '';
			stamp = $win.attr('timestamp') || '';
		}
		if (!app && el.getAttribute) { app = el.getAttribute('app') || ''; }
		if (!stamp && el.getAttribute) { stamp = el.getAttribute('timestamp') || ''; }
	}
	catch (e) {}
	var key = '';
	var record = null;
	if (stamp && jawnosWindowEmergeDismissals[String(stamp)]) {
		key = String(stamp);
		record = jawnosWindowEmergeDismissals[key];
	}
	else if (app && jawnosWindowEmergeDismissals['app:' + app]) {
		key = 'app:' + app;
		record = jawnosWindowEmergeDismissals[key];
	}
	if (!record) {
		// no cancelled open: a press kept from the prediction is handed to the
		// real window now that its contents are in place
		if (typeof jawnosPredictionPressQueue != 'undefined' && jawnosPredictionPressQueue && typeof jawnosPredictionPressQueue.replay == 'function') {
			jawnosPredictionPressQueue.replay(win);
		}
		return false;
	}
	if (record.app && app && record.app !== app) { return false; }
	if (record.stamp && stamp && String(record.stamp) !== String(stamp)) { return false; }
	delete jawnosWindowEmergeDismissals[key];
	jawnosWindowEmergeTakeBack($win, el);
	return true;
}

// A press that dismisses must not hand its click to the opener: the same
// control pressed again would otherwise ask for the window all over again. The
// capture listener stops the event before it reaches the control (inline
// onClick, a delegated start-menu row, or the canvas) and before the opener's
// own handler runs.
function jawnosWindowEmergeBlockNextClick(app) {
	if (!app || typeof setTimeout != 'function') { return; }
	var token = { app: app, at: Date.now() };
	jawnosWindowEmergeClickBlock = token;
	setTimeout(function () {
		if (jawnosWindowEmergeClickBlock === token) { jawnosWindowEmergeClickBlock = null; }
	}, 700);
}

function jawnosWindowEmergeSwallowClick(e) {
	// the lift that ended a scroll belongs to the gesture, not to the row under
	// the finger: it must neither open an app nor close the menu
	if (jawnosWindowEmergeDragSwallow) {
		if (!e || !e.target || e.target.nodeType !== 1) { return false; }
		if (!jawnosWindowEmergePressHost(e.target)) { return false; }
		jawnosWindowEmergeDragSwallow = false;
		if (e.preventDefault) { e.preventDefault(); }
		if (e.stopImmediatePropagation) { e.stopImmediatePropagation(); }
		else if (e.stopPropagation) { e.stopPropagation(); }
		return true;
	}
	var token = jawnosWindowEmergeClickBlock;
	if (!token || !e || !e.target || e.target.nodeType !== 1) { return false; }
	var control = jawnosWindowEmergeControl(e.target);
	if (!control || control.app !== token.app) { return false; }
	jawnosWindowEmergeClickBlock = null;
	if (e.preventDefault) { e.preventDefault(); }
	if (e.stopImmediatePropagation) { e.stopImmediatePropagation(); }
	else if (e.stopPropagation) { e.stopPropagation(); }
	return true;
}

// ---- presses made against a picture -----------------------------------------
// The preview may be the only thing on the desk while the real window is on its
// way. A press that lands on one of the app's own controls is meant for the
// window, not for the picture: it must not dismiss the open. Keep it as a press
// with the moment it happened and the values the prediction was showing, then
// hand it to the real control once windowMaker installs the window. The server
// ordering is still appointmentResetSend's per-app queue; this one only waits
// for a control to exist.
var JAWNOS_PREDICTION_PRESS_TTL = 30000;

// A control's identity as markup, so the same control can be found in the
// prediction and in the real render. The class list is sorted and the attrs
// that choose one control among its siblings are kept.
function jawnosPredictionPressKey(el) {
	if (!el || el.nodeType !== 1) { return ''; }
	var tag = String(el.tagName || '').toLowerCase();
	var classes = String(el.className || '').split(/\s+/).filter(Boolean).sort().join('.');
	var out = tag + (classes ? '.' + classes : '');
	var attrs = ['type', 'name', 'camera', 'feed', 'media_group', 'group', 'app'];
	for (var i = 0; i < attrs.length; i++) {
		var v = el.getAttribute ? el.getAttribute(attrs[i]) : null;
		if (v) { out += '[' + attrs[i] + '=' + v + ']'; }
	}
	return out;
}

function jawnosPredictionPressRead(root, selectors, as_html) {
	if (!root || !root.querySelector) { return undefined; }
	for (var i = 0; i < selectors.length; i++) {
		var el = null;
		try { el = root.querySelector(selectors[i]); } catch (e) { el = null; }
		if (!el) { continue; }
		if (as_html) {
			if (el.innerHTML !== undefined) { return el.innerHTML; }
			if (el.textContent !== undefined) { return el.textContent; }
		}
		if (el.value !== undefined) { return el.value; }
		if (el.getAttribute) { var v = el.getAttribute('value'); if (v !== null) { return v; } }
	}
	return undefined;
}

// The values the prediction was showing (or the desk held at the press). They
// go back into the real form before the replay, so a typed "ago 5m" is part of
// the appointment even when the server's render started from a clean form.
function jawnosPredictionPressValues(app, root) {
	var values = {
		ago: jawnosPredictionPressRead(root, ['.ago'], false),
		duration: jawnosPredictionPressRead(root, ['.duration'], false),
		quantity: jawnosPredictionPressRead(root, ['.main_input.quantity'], false),
		notes: jawnosPredictionPressRead(root, ['.text_editor', '.app_notes'], true),
		schedule: jawnosPredictionPressRead(root, ['.schedule'], false),
		warranty: jawnosPredictionPressRead(root, ['.warranty'], false)
	};
	try {
		if (typeof localStorage != 'undefined' && localStorage) {
			values.project = localStorage.getItem('project');
			// the same expression managerReset uses, so an unset pair stays 0
			values.timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		}
	} catch (e) {}
	// the desk's own ago field and the machine are outside the window
	if ((values.ago === undefined || values.ago === '') && typeof $ == 'function') {
		try { var ago = $('#ago'); if (ago && typeof ago.val == 'function') { values.ago = ago.val(); } } catch (e) {}
	}
	try {
		var tm = (typeof document != 'undefined' && document.getElementById) ? document.getElementById('time_machine') : null;
		if (tm && tm.value !== undefined && tm.value !== '') { values.time_machine = tm.value; }
		else if (typeof localStorage != 'undefined' && localStorage) { values.time_machine = localStorage.getItem('time_machine'); }
	} catch (e) {}
	if (typeof jawnosAppFieldGet == 'function') {
		try { values.duration_typed = (jawnosAppFieldGet(app, 'duration_typed') === 'yes') ? 'yes' : 'no'; } catch (e) {}
	}
	return values;
}

// Mark the controls a press can land on. The shadow is closed, so a click on
// the picture arrives at its host: the element and key kept here let the click
// be resolved by geometry against the layout the preview is already wearing.
function jawnosPredictionPressMark(root) {
	var out = [];
	if (!root || !root.querySelectorAll) { return out; }
	var nodes = null;
	// only .save_appointment calls managerReset: the .app_act row opens details,
	// measures and configuration, and replaying one of those as a reset would
	// write a record the person never pressed
	try { nodes = root.querySelectorAll('.save_appointment'); } catch (e) { nodes = null; }
	if (!nodes) { return out; }
	for (var i = 0; i < nodes.length; i++) {
		var el = nodes[i];
		if (!el || el.nodeType !== 1) { continue; }
		var key = jawnosPredictionPressKey(el);
		if (!key) { continue; }
		if (el.setAttribute) { el.setAttribute('data-jawnos-predict-press', key); }
		out.push({ el: el, key: key });
	}
	return out;
}

function jawnosPredictionPressFind(root, key) {
	if (!root || !root.querySelectorAll || !key) { return null; }
	var nodes = null;
	try { nodes = root.querySelectorAll('.save_appointment'); } catch (e) { nodes = null; }
	if (!nodes) { return null; }
	for (var i = 0; i < nodes.length; i++) {
		if (jawnosPredictionPressKey(nodes[i]) === key) { return nodes[i]; }
	}
	return null;
}

function jawnosPredictionPressResolve(ghost, e) {
	if (!ghost || !ghost.pressables || !ghost.pressables.length) { return null; }
	var x = (e && typeof e.clientX == 'number') ? e.clientX : null;
	var y = (e && typeof e.clientY == 'number') ? e.clientY : null;
	if (x === null || y === null) { return null; }
	for (var i = 0; i < ghost.pressables.length; i++) {
		var item = ghost.pressables[i];
		var rect = null;
		try { rect = (item && item.el && item.el.getBoundingClientRect) ? item.el.getBoundingClientRect() : null; } catch (err) { rect = null; }
		if (!rect || !(rect.width > 0) || !(rect.height > 0)) { continue; }
		if (x >= rect.left && x <= rect.left + rect.width && y >= rect.top && y <= rect.top + rect.height) { return item; }
	}
	return null;
}

function jawnosPredictionPressReserve(app) {
	try {
		if (typeof windowTiledPendingApp != 'undefined' && windowTiledPendingApp && windowTiledPendingApp[app]) {
			return String(windowTiledPendingApp[app]);
		}
	} catch (e) {}
	return '';
}

// The queue lives on window so the window manager's replay sees it even when
// the preview part and the appointment part are loaded separately. Entries are
// keyed by app and the reserved landing stamp; a press that was not answered by
// that same open is dropped rather than fired against a stale window.
var jawnosPredictionPressQueue = {
	items: {},
	prune: function (now) {
		now = now || Date.now();
		for (var key in this.items) {
			if (!this.items.hasOwnProperty(key)) { continue; }
			if (now - (this.items[key].at || 0) > JAWNOS_PREDICTION_PRESS_TTL) { delete this.items[key]; }
		}
	},
	queue: function (app, press) {
		if (!app || !press) { return null; }
		this.prune();
		var stamp = String(press.stamp || '') || jawnosPredictionPressReserve(app);
		var record = {
			app: app,
			stamp: stamp,
			key: press.key || '',
			at: press.at || Date.now(),
			values: press.values || null,
			ctrlKey: !!press.ctrlKey
		};
		this.items[app + '|' + stamp] = record;
		return record;
	},
	take: function (app, stamp) {
		if (!app) { return null; }
		stamp = String(stamp || '');
		var exact = app + '|' + stamp;
		if (this.items[exact]) { var found = this.items[exact]; delete this.items[exact]; return found; }
		// a press queued before the reservation was known answers the first
		// landing for its app
		var loose = app + '|';
		if (stamp && this.items[loose]) { var l = this.items[loose]; delete this.items[loose]; return l; }
		// an entry for another open of this app is not this window's press:
		// leave it for its own landing (the TTL prunes it if that never comes)
		return null;
	},
	drop: function (app) {
		for (var key in this.items) {
			if (!this.items.hasOwnProperty(key)) { continue; }
			if (!app || this.items[key].app === app) { delete this.items[key]; }
		}
	},
	replay: function (win) {
		if (typeof managerReset != 'function') { return false; }
		var el = null;
		try { el = (typeof $ == 'function') ? $(win)[0] : win; } catch (e) { el = null; }
		if (!el || !el.getAttribute) { return false; }
		var app = el.getAttribute('app') || '';
		var stamp = el.getAttribute('timestamp') || '';
		if (!app) { return false; }
		var record = this.take(app, stamp);
		if (!record) { return false; }
		var root = (el.closest && el.closest('.wind')) || el;
		var control = jawnosPredictionPressFind(root, record.key);
		if (!control) { return false; }
		// a replay must never take the window's own install down with it
		try { managerReset($(control), { ctrlKey: !!record.ctrlKey }, record); }
		catch (e) { return false; }
		return true;
	}
};
window.jawnosPredictionPressQueue = jawnosPredictionPressQueue;

function jawnosPredictionPressOffer(ghost, e) {
	if (!ghost || !ghost.app) { return null; }
	var item = jawnosPredictionPressResolve(ghost, e);
	if (!item) { return null; }
	// Prefer a real window that has already been installed under the picture:
	// its fields hold what the person has typed. With no window yet, the clone
	// the picture was drawn from is the only copy of those values.
	var root = null;
	if (typeof document != 'undefined' && document.querySelector) {
		var app_name = String(ghost.app).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
		try { root = document.querySelector('.appointment[app="' + app_name + '"]'); } catch (err) { root = null; }
	}
	if (!root) { root = ghost.scope || null; }
	var press = {
		key: item.key,
		at: Date.now(),
		stamp: jawnosPredictionPressReserve(ghost.app),
		ctrlKey: !!(e && e.ctrlKey),
		values: jawnosPredictionPressValues(ghost.app, root)
	};
	return jawnosPredictionPressQueue.queue(ghost.app, press);
}

// ---- the app's own window as the preview ------------------------------------
// A press should show the window it is about to open, not a neutral skeleton:
// the app's own title bar and buttons, its colours and its layout. The last
// settled window of each app is cloned - stripped of anything live - and offered
// to the next press. It is drawn in a shadow root, so its ids can never answer a
// document lookup meant for the real window, and the page's own rules are
// carried in scoped to the preview. The palette is inherited from the live root
// rather than copied, and a picture captured under another theme is refused, so
// a prediction never wears the previous theme. The last copy of each app is kept
// in the encrypted windows store (00_store.js), so a reload still opens into a
// real-looking preview.
// How much the cache holds. The numbers live in the windows store beside the
// encrypted records, and are aliased here so the preview and the shell agree on
// one budget. It is per app, not per window: the desk writes a median of 192
// appointment records a day (512 days of appointments.server_time; the mean,
// 234, is pulled up by import days), and a day's work is spread over the desk's
// ~30 apps - so thirty-two slots are a day's apps with the room the twenty
// percent asks for, and more entries than the desk has apps would never be used.
var JAWNOS_EMERGE_PREVIEW_APPS = (typeof JAWNOS_WINDOWS_MAX_APPS == 'number') ? JAWNOS_WINDOWS_MAX_APPS : 32;
// One window: a gallery with its photographs trimmed is ~40KB and a heavy app a
// couple of hundred, so 1.5MB is a whole window of any of them.
var JAWNOS_EMERGE_PREVIEW_BYTES = (typeof JAWNOS_WINDOWS_MAX_WINDOW_BYTES == 'number') ? JAWNOS_WINDOWS_MAX_WINDOW_BYTES : 1500000;
// The store on the device, across every app: the fifty megabytes asked for. The
// oldest go first when it is reached.
var JAWNOS_EMERGE_PREVIEW_BUDGET = (typeof JAWNOS_WINDOWS_MAX_BYTES == 'number') ? JAWNOS_WINDOWS_MAX_BYTES : 52428800;
// The parsed copies live in memory for the session; a parsed DOM costs several
// times its markup, so the hot set is budgeted by the markup it keeps rather
// than by the store's disk allowance.
var JAWNOS_EMERGE_PREVIEW_MEMORY = 8000000;
// A photograph embedded in the markup is no part of what a preview is for, and
// one of them can be most of an app's window: the box stays, the picture does
// not.
var JAWNOS_EMERGE_PREVIEW_IMAGE = 8000;
var JAWNOS_EMERGE_PREVIEW_BLANK = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';
var jawnosEmergePreviews = {};
var jawnosEmergePreviewSheetCache = null;
var JAWNOS_EMERGE_PREVIEW_SCOPE = 'jawnos_emerge_scope';

// The theme the desk is wearing now. Both the kept pictures and the copied
// stylesheet belong to one dressing; a picture from another is refused rather
// than painted, so a prediction never shows last theme's buttons and icons.
function jawnosEmergeThemeNow() {
	if (typeof jawnosWindowsThemeNow == 'function') { return jawnosWindowsThemeNow(); }
	if (typeof document == 'undefined' || !document.body || !document.body.getAttribute) { return ''; }
	return document.body.getAttribute('data-theme-sig') || '';
}

function jawnosEmergePreviewAll() {
	if (typeof jawnosWindowsAll != 'function') { return Promise.resolve([]); }
	return jawnosWindowsAll();
}

// One copy per app, and the oldest go first: a preview from a month ago is not
// worth the space, and the desk's own memory only ever holds the last one. The
// sweep is by held bytes as well as by count, and both windows in a record -
// the shell and the picture - count against it.
function jawnosEmergePreviewPrune() {
	if (typeof jawnosWindowsPrune != 'function') { return Promise.resolve(); }
	return jawnosWindowsPrune();
}

function jawnosEmergePreviewSave(record, el) {
	if (!record || !record.app || record.app == 'Denied' || typeof jawnosWindowsSave != 'function') { return Promise.resolve(); }
	// A private place itself is kept; a live private grant, a private app, or a
	// media app showing a fingerprint-unlocked private album is refused. The
	// picture may still be drawn in memory (it never leaves the page), but no
	// copy of that window is written to the disk.
	if (typeof jawnosWindowsPublicNow == 'function' && !jawnosWindowsPublicNow(el, { allow_private_place: true })) {
		if (typeof jawnosWindowsDelete == 'function') { jawnosWindowsDelete(jawnosWindowsIdentity(record.app, {})); }
		return Promise.resolve();
	}
	// a preview is per app; the empty instance suffix is also the identity every
	// single-window app's shell uses, so the two share one record
	return jawnosWindowsSave(jawnosWindowsIdentity(record.app, {}), {
		app: record.app,
		preview: record.html,
		theme: (record.theme !== undefined) ? record.theme : jawnosEmergeThemeNow(),
		at: record.at || Date.now()
	});
}

function jawnosEmergePreviewParse(html) {
	if (!html || typeof document == 'undefined' || !document.createElement) { return null; }
	try {
		var box = document.createElement('div');
		box.innerHTML = html;
		var node = box.firstElementChild;
		if (!node && box.children && box.children.length) { node = box.children[0]; }
		return node || null;
	}
	catch (e) { return null; }
}

// A reload should not start the previews over. Read once, at idle, and keep the
// parsed node so a press never pays for a parse. A theme change while the page
// was away left another dressing's records behind, so they are reaped before
// the load; the memory map holds the newest desk of apps, within its own budget.
function jawnosEmergePreviewLoad() {
	var theme = jawnosEmergeThemeNow();
	var load = function () {
		jawnosEmergePreviewAll().then(function (rows) {
			rows.sort(function (a, b) { return (b.at || 0) - (a.at || 0); });
			var held = 0;
			var loaded = 0;
			for (var i = 0; i < rows.length; i++) {
				var row = rows[i];
				if (!row || !row.app || !row.preview || jawnosEmergePreviews[row.app]) { continue; }
				// a record from another theme is not the picture the desk is about to
				// wear; the reap above should have removed it, but a race is left unread
				if (String(row.theme || '') !== String(theme)) { continue; }
				if (loaded >= JAWNOS_EMERGE_PREVIEW_APPS) { break; }
				var html = String(row.preview || '');
				if (held + html.length > JAWNOS_EMERGE_PREVIEW_MEMORY) { continue; }
				var node = jawnosEmergePreviewParse(row.preview);
				if (node) {
					jawnosEmergePreviews[row.app] = { node: node, html: row.preview, at: row.at || 0, theme: String(row.theme || '') };
					held += html.length;
					loaded++;
				}
			}
		}).then(null, function () {});
	};
	if (typeof jawnosWindowsReapTheme == 'function') { jawnosWindowsReapTheme(theme).then(load, load); }
	else { load(); }
}

// Nothing live belongs in a picture: no scripts, no handlers, no sound and no
// second page loading behind the preview.
function jawnosEmergePreviewSanitize(node) {
	if (!node || node.nodeType !== 1) { return node; }
	var children = node.children || [];
	for (var i = children.length - 1; i >= 0; i--) {
		var child = children[i];
		if (!child) { continue; }
		var tag = String(child.tagName || '').toUpperCase();
		if (tag == 'SCRIPT' || tag == 'NOSCRIPT') {
			if (node.removeChild) { node.removeChild(child); }
			continue;
		}
		var names = child.getAttributeNames ? (child.getAttributeNames() || []) : [];
		for (var n = 0; n < names.length; n++) {
			var name = names[n];
			if (/^on/i.test(name)) { child.removeAttribute(name); }
		}
		if (tag == 'VIDEO' || tag == 'AUDIO' || tag == 'IFRAME' || tag == 'OBJECT' || tag == 'EMBED') {
			if (child.removeAttribute) {
				child.removeAttribute('src');
				child.removeAttribute('data');
				child.removeAttribute('autoplay');
			}
		}
		if (tag == 'IMG' && child.getAttribute && child.setAttribute) {
			var src = child.getAttribute('src') || '';
			// an embedded photograph is most of a gallery's window and none of what
			// the preview is for: a blank of the same size keeps the layout
			if (src.length > JAWNOS_EMERGE_PREVIEW_IMAGE && /^data:/i.test(src)) {
				child.setAttribute('src', JAWNOS_EMERGE_PREVIEW_BLANK);
			}
		}
		jawnosEmergePreviewSanitize(child);
	}
	return node;
}

// Keep the app's settled window as the next press's picture. The clone is taken
// after the open's motion is over, so the copy never competes with the frame it
// is made from.
function jawnosEmergePreviewCapture(win) {
	if (typeof document == 'undefined' || !document.body) { return false; }
	// The window itself is kept for the next reload whether or not a picture is
	// drawn: a desk with the motions off still wants its windows back at once.
	// The shell's own capture refuses a private app, a live grant or a media
	// unlock; the picture follows the same rule, so a locked window never becomes
	// the next press's prediction.
	if (typeof jawnosWindowsShellCapture == 'function') { jawnosWindowsShellCapture(win); }
	if (typeof jawnosWindowEffectsOn == 'function' && !jawnosWindowEffectsOn()) { return false; }
	if (typeof jawnosWindowEmergeLevel == 'function' && jawnosWindowEmergeLevel() == 'off') { return false; }
	win = $(win)[0];
	if (!win || win.nodeType !== 1 || !win.parentNode) { return false; }
	if (win.getClientRects && !win.getClientRects().length) { return false; }
	var app = win.getAttribute ? (win.getAttribute('app') || '') : '';
	if (!app || app == 'Denied') { return false; }
	if (typeof jawnosWindowsPublicNow == 'function' && !jawnosWindowsPublicNow(win, { allow_private_place: true })) {
		delete jawnosEmergePreviews[app];
		return false;
	}
	var node = null;
	try { node = win.cloneNode(true); } catch (e) { node = null; }
	if (!node) { return false; }
	jawnosEmergePreviewSanitize(node);
	var html = '';
	try { html = node.outerHTML || ''; } catch (e) { html = ''; }
	var at = Date.now();
	var theme = jawnosEmergeThemeNow();
	jawnosEmergePreviews[app] = { node: node, html: html, at: at, theme: theme };
	// memory keeps the most recently used, like the store does: by count, and by
	// the markup it is holding, so a handful of big windows cannot crowd out the
	// rest of the desk
	var apps = [];
	for (var key in jawnosEmergePreviews) {
		if (jawnosEmergePreviews.hasOwnProperty(key)) { apps.push(key); }
	}
	apps.sort(function (a, b) { return (jawnosEmergePreviews[a].at || 0) - (jawnosEmergePreviews[b].at || 0); });
	var held = 0;
	for (var s = 0; s < apps.length; s++) { held += (jawnosEmergePreviews[apps[s]].html || '').length; }
	for (var cut = 0; cut < apps.length; cut++) {
		var over_count = (apps.length - cut) > JAWNOS_EMERGE_PREVIEW_APPS;
		if (!over_count && held <= JAWNOS_EMERGE_PREVIEW_MEMORY) { break; }
		held -= (jawnosEmergePreviews[apps[cut]].html || '').length;
		delete jawnosEmergePreviews[apps[cut]];
	}
	if (html && html.length <= JAWNOS_EMERGE_PREVIEW_BYTES) {
		jawnosEmergePreviewSave({ app: app, html: html, at: at, theme: theme }, win).then(jawnosEmergePreviewPrune, function () {});
	}
	return true;
}

// A selector list's commas, split only between selectors. A comma inside
// :where()/:is()/:not() (the form-control focus and texture rules use them)
// is not a list separator: splitting there produced invalid CSS and those
// rules silently never reached the preview.
function jawnosEmergePreviewParts(text) {
	var parts = [];
	var depth = 0;
	var quote = '';
	var start = 0;
	text = String(text || '');
	for (var i = 0; i < text.length; i++) {
		var ch = text.charAt(i);
		if (quote) {
			if (ch === '\\') { i++; continue; }
			if (ch === quote) { quote = ''; }
			continue;
		}
		if (ch === '"' || ch === "'") { quote = ch; continue; }
		if (ch === '(' || ch === '[') { depth++; continue; }
		if (ch === ')' || ch === ']') { if (depth) { depth--; } continue; }
		if (ch === ',' && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
	}
	parts.push(text.slice(start));
	return parts;
}

// True when every part of the list dresses only body/html/:root itself and not
// a descendant. Those are the rules that carry the palette (`body.dark_theme {
// --panel: ... }`); the live desk already provides it by inheritance.
function jawnosEmergePreviewRootOnly(text) {
	var parts = jawnosEmergePreviewParts(text);
	if (!parts.length) { return false; }
	for (var i = 0; i < parts.length; i++) {
		var part = parts[i].replace(/\s+/g, ' ').trim();
		if (!part) { return false; }
		if (!/^(?::root|html|body)(?:[.#\[:][^\s]*)*$/i.test(part)) { return false; }
	}
	return true;
}

// The page's declarations without the theme palette. A copied `body.dark_theme
// { --panel: ... }` rule would sit on the preview wrapper and outrank the
// custom properties inherited from body, pinning the preview (its inputs
// included) to the stylesheet's static light/dark defaults instead of the
// desk's actual colours. `color-scheme` and any non-variable declaration stay.
function jawnosEmergePreviewDeclarations(style) {
	if (!style) { return ''; }
	if (style.length !== undefined && typeof style.item == 'function') {
		var kept = [];
		for (var i = 0; i < style.length; i++) {
			var name = style.item(i);
			if (String(name).indexOf('--') === 0) { continue; }
			var priority = (typeof style.getPropertyPriority == 'function') ? style.getPropertyPriority(name) : '';
			kept.push(name + ':' + style.getPropertyValue(name) + (priority ? ' !important' : ''));
		}
		return kept.join(';');
	}
	var parts = String(style.cssText || '').split(';');
	var out = [];
	for (var p = 0; p < parts.length; p++) {
		if (/^\s*--/.test(parts[p])) { continue; }
		if (parts[p].trim()) { out.push(parts[p].trim()); }
	}
	return out.join(';');
}

function jawnosEmergePreviewSelector(text) {
	var parts = jawnosEmergePreviewParts(text);
	var out = [];
	for (var i = 0; i < parts.length; i++) {
		var part = parts[i].replace(/\s+/g, ' ').trim();
		if (!part) { continue; }
		var root_only = /(^|[\s>+~])(:root|html)(?=$|[\s.:#\[>+~])/i.test(part);
		if (root_only && !/\bbody\b/i.test(part)) { continue; }
		part = part.replace(/(^|[\s>+~])(?::root|html)(?=$|[\s.:#\[>+~])/gi, '$1');
		part = part.replace(/\bbody\b/gi, '.' + JAWNOS_EMERGE_PREVIEW_SCOPE).replace(/\s+/g, ' ').trim();
		if (part) { out.push(part); }
	}
	return out.length ? out.join(', ') : null;
}

function jawnosEmergePreviewRules(rules, out) {
	for (var i = 0; i < rules.length; i++) {
		var rule = rules[i];
		try {
			if (rule.selectorText !== undefined && rule.style) {
				var scoped = jawnosEmergePreviewSelector(rule.selectorText);
				// the palette belongs to the live root; only the rest of a body-only
				// rule is copied, so the preview inherits the desk's real colours
				var declarations = jawnosEmergePreviewRootOnly(rule.selectorText)
					? jawnosEmergePreviewDeclarations(rule.style)
					: rule.style.cssText;
				if (scoped && declarations) { out.push(scoped + '{' + declarations + '}'); }
			}
			else if (rule.cssRules && rule.type === 4) {
				out.push('@media ' + rule.media.mediaText + '{');
				jawnosEmergePreviewRules(rule.cssRules, out);
				out.push('}');
			}
			else if (rule.cssRules && rule.type === 12) {
				out.push('@supports ' + rule.conditionText + '{');
				jawnosEmergePreviewRules(rule.cssRules, out);
				out.push('}');
			}
			else if (rule.cssText) {
				out.push(rule.cssText);
			}
		}
		catch (e) {}
	}
	return out;
}

function jawnosEmergePreviewCss() {
	var out = [];
	try {
		var sheets = (typeof document != 'undefined' && document.styleSheets) ? document.styleSheets : [];
		for (var i = 0; i < sheets.length; i++) {
			var rules = null;
			try { rules = sheets[i].cssRules; } catch (e) { rules = null; }
			if (rules) { jawnosEmergePreviewRules(rules, out); }
		}
	}
	catch (e) {}
	// The preview is a picture: nothing in it takes a press, and the window's own
	// saved geometry gives way to the ghost's box.
	out.push('.' + JAWNOS_EMERGE_PREVIEW_SCOPE + ',.' + JAWNOS_EMERGE_PREVIEW_SCOPE + ' *{pointer-events:none!important}');
	out.push('.' + JAWNOS_EMERGE_PREVIEW_SCOPE + ' .wind{position:absolute!important;left:0!important;top:0!important;right:auto!important;bottom:auto!important;margin:0!important;width:100%!important;height:100%!important;transform:none!important;border-radius:0!important;box-shadow:none!important}');
	return out.join('\n');
}

// Built once per theme: serialising every rule is not something a press should
// pay for. A live theme change drops the cache (jawnosEmergePreviewThemeReset)
// and the signature check here is the second guard.
function jawnosEmergePreviewSheet() {
	var theme = jawnosEmergeThemeNow();
	if (jawnosEmergePreviewSheetCache && jawnosEmergePreviewSheetCache.theme === theme) { return jawnosEmergePreviewSheetCache; }
	var css = jawnosEmergePreviewCss();
	var sheet = null;
	try {
		if (typeof CSSStyleSheet == 'function' && CSSStyleSheet.prototype && CSSStyleSheet.prototype.replaceSync) {
			sheet = new CSSStyleSheet();
			sheet.replaceSync(css);
		}
	}
	catch (e) { sheet = null; }
	jawnosEmergePreviewSheetCache = { sheet: sheet, css: css, theme: theme };
	return jawnosEmergePreviewSheetCache;
}

// A live theme change makes every kept picture and the copied stylesheet a
// picture of the old dressing. Drop both, and let the load reap the store's
// records from the other theme before it reads the current ones; a press then
// draws the current-theme skeleton until a window is captured under the new
// theme.
function jawnosEmergePreviewThemeReset() {
	jawnosEmergePreviews = {};
	jawnosEmergePreviewSheetCache = null;
	if (typeof jawnosWindowEmergeGhostCancel == 'function') { jawnosWindowEmergeGhostCancel(jawnosWindowEmergeGhost); }
	if (typeof jawnosEmergePreviewLoad == 'function') { jawnosEmergePreviewLoad(); }
}

// Draw the app's last window into the ghost. Answers false when there is no
// snapshot, so the caller falls back to the drawn chrome and skeleton. Nothing
// is created after the shadow is attached: a failure there would leave the host
// with an empty shadow, and the fallback would be light DOM it hides.
function jawnosEmergePreviewBuild(origin, host) {
	origin = origin || {};
	if (!host || !host.attachShadow || !origin.app) { return false; }
	var snapshot = jawnosEmergePreviews[origin.app];
	if (!snapshot || !snapshot.node) { return false; }
	// The captured inline styles, the baked icon paths and the copied stylesheet
	// are one theme's picture. A snapshot from another dressing cannot be
	// honestly re-themed, so it is refused and the caller draws the current-theme
	// skeleton instead of showing last theme's buttons.
	if (String(snapshot.theme || '') !== String(jawnosEmergeThemeNow())) { return false; }
	// using it is using the app: the copy the store and the memory map drop first
	// is the one the desk has not looked at in the longest time
	snapshot.at = Date.now();
	var node = null;
	var scope = null;
	var built = null;
	var style = null;
	try {
		node = snapshot.node.cloneNode(true);
		scope = document.createElement('div');
		style = document.createElement('style');
		built = jawnosEmergePreviewSheet();
	}
	catch (e) { return false; }
	if (!node || !scope || !built) { return false; }
	var classes = JAWNOS_EMERGE_PREVIEW_SCOPE;
	if (document.body && document.body.className) { classes += ' ' + document.body.className; }
	if (document.documentElement && document.documentElement.className) { classes += ' ' + document.documentElement.className; }
	scope.className = classes;
	// the body's state attributes as well (data-appt-theme, data-window-effects,
	// data-icon-set): the rules answer to them, and the desk's state is live
	var body_attrs = (document.body && document.body.getAttributeNames) ? document.body.getAttributeNames() : [];
	for (var b = 0; b < body_attrs.length; b++) {
		var body_attr = body_attrs[b];
		if (body_attr == 'class' || body_attr == 'style' || body_attr == 'id') { continue; }
		if (scope.setAttribute) { scope.setAttribute(body_attr, document.body.getAttribute(body_attr)); }
	}
	scope.appendChild(node);
	// The bar wears the app's own colour and the appointment tint, re-read now:
	// the captured copy could be from before either of them changed.
	var bar = scope.querySelector ? scope.querySelector('.top_navbar') : null;
	var app_colour = jawnosWindowEmergeAppColour(origin.app);
	if (bar && bar.style && app_colour) {
		if (app_colour.colour) { bar.style.backgroundColor = app_colour.colour; }
		if (app_colour.ink) { bar.style.color = app_colour.ink; }
		if (bar.style.setProperty) {
			bar.style.setProperty('--appt-dark', app_colour.dark || '');
			bar.style.setProperty('--appt-dark-ink', app_colour.dark_ink || '');
		}
	}
	if (style) { style.textContent = built.css; }
	var shadow = null;
	try { shadow = host.attachShadow({ mode: 'closed' }); } catch (e) { return false; }
	if (!shadow) { return false; }
	var adopted = false;
	if (built.sheet && 'adoptedStyleSheets' in shadow) {
		try { shadow.adoptedStyleSheets = [built.sheet]; adopted = shadow.adoptedStyleSheets && shadow.adoptedStyleSheets.length > 0; }
		catch (e) { adopted = false; }
	}
	if (!adopted && style) { shadow.appendChild(style); }
	shadow.appendChild(scope);
	// The picture is a closed shadow tree: keep the scope and mark its controls
	// so a press on one can be resolved by geometry and replayed when the real
	// control lands (jawnosPredictionPressResolve). Only a picture that actually
	// reached the desk is pressable.
	if (host) {
		host.jawnosEmergeScope = scope;
		host.jawnosEmergePressables = jawnosPredictionPressMark(scope);
	}
	return true;
}

// The picture can go stale while a window is open - a jopen, the budget light,
// a rearranged list. Closing the window is the moment that matters most: that is
// the view the person last saw, so closeWindow takes the copy before the
// farewell starts. One open window is also refreshed per idle sweep, for the
// windows that go away some other way (a reload, the server's own close).
var JAWNOS_EMERGE_PREVIEW_SWEEP = 20000;

function jawnosEmergePreviewSweep() {
	if (typeof document == 'undefined' || !document.querySelectorAll) { return false; }
	if (typeof jawnosWindowEffectsOn == 'function' && !jawnosWindowEffectsOn()) { return false; }
	var winds = document.querySelectorAll('.wind');
	if (!winds || !winds.length) { return false; }
	// the oldest picture first, so every open app is reached in turn
	var pick = null;
	var oldest = 0;
	for (var i = 0; i < winds.length; i++) {
		var win = winds[i];
		if (!win || !win.getAttribute) { continue; }
		var app = win.getAttribute('app') || '';
		if (!app) { continue; }
		if (typeof jawnosWindowsPublicNow == 'function' && !jawnosWindowsPublicNow(win, { allow_private_place: true })) { continue; }
		if (win.getClientRects && !win.getClientRects().length) { continue; }
		var at = jawnosEmergePreviews[app] ? (jawnosEmergePreviews[app].at || 0) : 0;
		if (!pick || at < oldest) { pick = win; oldest = at; }
	}
	return pick ? jawnosEmergePreviewCapture(pick) : false;
}

function jawnosEmergePreviewSweepStart() {
	if (typeof setInterval != 'function') { return; }
	setInterval(function () {
		if (typeof requestIdleCallback == 'function') { requestIdleCallback(jawnosEmergePreviewSweep, { timeout: 4000 }); }
		else { jawnosEmergePreviewSweep(); }
	}, JAWNOS_EMERGE_PREVIEW_SWEEP);
}

// Warm the two things a press must not pay for: the scoped stylesheet and the
// snapshots kept from the last run. Both are idle work - the sheet is serialised
// once and the stored windows are parsed once.
(function () {
	if (typeof document == 'undefined' || !document.addEventListener) { return; }
	document.addEventListener('DOMContentLoaded', function () {
		var warm = function () {
			try { jawnosEmergePreviewSheet(); } catch (e) {}
			try { jawnosEmergePreviewLoad(); } catch (e) {}
			try { jawnosEmergePreviewSweepStart(); } catch (e) {}
		};
		if (typeof requestIdleCallback == 'function') { requestIdleCallback(function () { warm(); }, { timeout: 4000 }); }
		else { setTimeout(warm, 1500); }
	});
})();

// The press-time preview. It is created inside pointerdown, so the desktop has
// already answered before the app's chunk or the server is asked. The chrome
// fades in as the box grows readable, then the preview holds at the predicted
// frame until the real window lands (or the TTL puts it away).
// How long a window takes to arrive on this desk. The preview's growth is sized
// to it: the level's fixed tail stood still on a slow server and was squeezed
// into the cross-fade on a fast one, and both read as choppy. The last few opens
// are kept and the median is used, so one heavy first open - a lazy app's chunk
// - does not slow every preview after it. The samples are stored on the device,
// so a reload does not start the estimate over.
var JAWNOS_EMERGE_LATENCY_SAMPLES = 5;
var JAWNOS_EMERGE_LATENCY_KEY = 'jawnos_emerge_latency';
var jawnosWindowEmergeLatencies = null;

function jawnosWindowEmergeLatencyStore() {
	if (jawnosWindowEmergeLatencies) { return jawnosWindowEmergeLatencies; }
	jawnosWindowEmergeLatencies = [];
	try {
		if (typeof localStorage != 'undefined' && localStorage) {
			var saved = JSON.parse(localStorage.getItem(JAWNOS_EMERGE_LATENCY_KEY) || '[]');
			if (saved && saved.length) {
				for (var i = 0; i < saved.length && i < JAWNOS_EMERGE_LATENCY_SAMPLES; i++) {
					var ms = parseFloat(saved[i]);
					if (isFinite(ms) && ms >= 40 && ms <= 10000) { jawnosWindowEmergeLatencies.push(ms); }
				}
			}
		}
	}
	catch (e) {}
	return jawnosWindowEmergeLatencies;
}

function jawnosWindowEmergeLatencyRecord(ms) {
	ms = parseFloat(ms);
	// a press answered by a window already on the desk is not an open
	if (!isFinite(ms) || ms < 40 || ms > 10000) { return; }
	var samples = jawnosWindowEmergeLatencyStore();
	samples.push(ms);
	while (samples.length > JAWNOS_EMERGE_LATENCY_SAMPLES) { samples.shift(); }
	try {
		if (typeof localStorage != 'undefined' && localStorage) {
			localStorage.setItem(JAWNOS_EMERGE_LATENCY_KEY, JSON.stringify(samples));
		}
	}
	catch (e) {}
}

function jawnosWindowEmergeLatencyMedian() {
	var samples = jawnosWindowEmergeLatencyStore();
	if (!samples.length) { return 0; }
	var sorted = samples.slice().sort(function (a, b) { return a - b; });
	var mid = Math.floor(sorted.length / 2);
	return (sorted.length % 2) ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// The growth's own duration: the level's beat until the desk has measured an
// open, then the device's own pace with a short overshoot, so the box is still
// moving when its window lands - neither standing at the frame nor rushing the
// tail into the cross-fade.
function jawnosWindowEmergeGrowTime(shape) {
	shape = shape || jawnosWindowEmergeShape[jawnosWindowEmergeLevel()] || jawnosWindowEmergeShape.medium;
	var base = Math.max(shape.ghost, Math.round(shape.ghost * 3));
	var pace = jawnosWindowEmergeLatencyMedian();
	if (!(pace > 0)) { return base; }
	return Math.max(shape.ghost, Math.min(2000, Math.round(pace * 1.08)));
}

function jawnosWindowEmergeGhostStart(origin) {
	if (!origin) { return null; }
	if (typeof jawnosWindowEffectsOn == 'function' && !jawnosWindowEffectsOn()) { return null; }
	var level = jawnosWindowEmergeLevel();
	if (level == 'off' || jawnosWindowEmergeReduced()) { return null; }
	if (typeof document == 'undefined' || !document.body) { return null; }

	// only one preview at a time: a new press replaces an unspent one
	jawnosWindowEmergeGhostCancel();

	var shape = jawnosWindowEmergeShape[level] || jawnosWindowEmergeShape.medium;
	var zoom = jawnosWindowEmergeZoom(null, origin);
	var from = jawnosWindowEmergeCssRect(origin, zoom);
	var to = jawnosWindowEmergePredict(origin, from);
	var el = jawnosEmergeElement('div', 'jawnos_emerge_ghost');
	if (!el) { return null; }
	el.setAttribute('aria-hidden', 'true');
	// It does not take the pointer yet: it is still the control's own rectangle
	// and the press that started it has not clicked. jawnosWindowEmergeGhostArm
	// hands it the pointer once it has poured and the press is over.
	//
	// The box is laid out at its predicted frame from the start and the growth
	// is a transform back onto the pressed control. A left/top/width/height
	// animation is a layout animation: it freezes whenever the main thread is
	// busy (a slow window's own insertion is exactly that), which read as the
	// preview pausing two-thirds through. A transform rides the compositor and
	// keeps moving while the window is built.
	var grow_dx = from.left - to.left;
	var grow_dy = from.top - to.top;
	var grow_sx = (to.width > 0) ? (from.width / to.width) : 1;
	var grow_sy = (to.height > 0) ? (from.height / to.height) : 1;
	var grow_from = 'translate(' + grow_dx + 'px, ' + grow_dy + 'px) scale(' + grow_sx + ', ' + grow_sy + ')';
	el.style.transformOrigin = '0 0';
	el.style.transform = grow_from;
	jawnosEmergeBoxStyle(el, to);

	var chrome = null;
	// The app's own last window, when the desk has one: its title bar and buttons,
	// its colours and its layout, instead of the drawn chrome and skeleton.
	if (!jawnosEmergePreviewBuild(origin, el)) { chrome = jawnosWindowEmergeChrome(origin); }
	if (chrome) {
		chrome.style.opacity = '0';
		el.appendChild(chrome);
	}

	var ghost = { el: el, chrome: chrome, app: origin.app || '', origin: origin, to: to, timer: null, openAnim: null, chromeAnim: null, win: null, waited: 0, at: Date.now(), poured: !el.animate, armed: false, armTimer: null, pourTimer: null, scope: el.jawnosEmergeScope || null, pressables: el.jawnosEmergePressables || [] };
	document.body.appendChild(el);
	jawnosWindowEmergeGhost = ghost;

	// The waiting preview takes the pointer so a press on it can be one of two
	// things: a dismissal, or a press meant for the window's own controls.
	// The class is removed at retarget, so the cross-fade is click-through again.
	if (el.addEventListener) {
		el.addEventListener('click', function (e) {
			// a queued click can land after the window has taken the frame
			if (ghost.win) { return; }
			if (e && e.preventDefault) { e.preventDefault(); }
			if (e && e.stopImmediatePropagation) { e.stopImmediatePropagation(); }
			else if (e && e.stopPropagation) { e.stopPropagation(); }
			// A press on a predicted control is the press the person meant for
			// the app: keep it (with its own moment and values) and do not
			// dismiss the open it is waiting for. Anything else is a dismissal.
			if (jawnosPredictionPressOffer(ghost, e)) { return; }
			jawnosWindowEmergeDismiss(ghost);
		});
	}

	if (el.animate) {
		// The growth runs for the device's measured pace when there is one: a
		// remote server can keep a window a third to half a second behind a local
		// one, and a preview that reaches its frame and then stands still reads as
		// a pause in the animation - while a fixed tail on a fast desk is still
		// running when the window lands and has to be squeezed into the
		// cross-fade. The same ease covers most of the distance quickly; what is
		// left is the tail the retarget takes the rest of the way.
		ghost.openAnim = el.animate([
			{ transform: grow_from, offset: 0 },
			{ transform: 'none', offset: 1 }
		], {
			duration: jawnosWindowEmergeGrowTime(shape),
			easing: 'cubic-bezier(.2,.85,.25,1)',
			fill: 'both'
		});
	}
	else {
		el.style.transform = '';
		el.style.transformOrigin = '';
		jawnosEmergeBoxStyle(el, to);
	}

	// The preview has poured once its box has had the level's own beat to grow
	// out of the control; only then is a press on it a dismissal. This rides a
	// timer, not the animation's finish, so the longer tail above does not keep
	// the preview from taking the pointer.
	if (el.animate) {
		ghost.pourTimer = setTimeout(function () {
			ghost.pourTimer = null;
			ghost.poured = true;
			jawnosWindowEmergeGhostArm(ghost);
		}, shape.ghost);
	}

	if (chrome && chrome.animate) {
		ghost.chromeAnim = chrome.animate([
			{ opacity: 0, offset: 0 },
			{ opacity: 1, offset: 1 }
		], {
			duration: Math.max(80, Math.round(shape.ghost * 0.45)),
			delay: Math.round(shape.ghost * 0.38),
			easing: 'ease-out',
			fill: 'both'
		});
	}
	else if (chrome) {
		chrome.style.opacity = '1';
	}

	// A window may be slow; while its reservation is live the preview stands
	// rather than leave a blank desk (jawnosWindowEmergeGhostExpire).
	ghost.timer = setTimeout(function () { jawnosWindowEmergeGhostExpire(ghost); }, JAWNOS_EMERGE_GHOST_TTL);
	jawnosWindowEmergeGhostWatch(ghost);
	return ghost;
}

// Watch only while a preview is standing: the desk mutates constantly, and an
// observer on the whole body would be paid for by every app. Turning the
// effects off and closing the window the preview became are the two changes
// that must put it away before its own timers would.
function jawnosWindowEmergeGhostWatch(ghost) {
	if (!ghost || typeof MutationObserver != 'function') { return; }
	if (typeof document == 'undefined' || !document.body) { return; }
	try {
		ghost.observer = new MutationObserver(function () {
			if (jawnosWindowEmergeLevel() == 'off' || jawnosWindowEmergeReduced()) {
				jawnosWindowEmergeGhostCancel(ghost);
				return;
			}
			if (ghost.win && !ghost.win.parentNode) { jawnosWindowEmergeGhostCancel(ghost); }
		});
		ghost.observer.observe(document.body, {
			attributes: true,
			attributeFilter: ['data-window-effects'],
			childList: true,
			subtree: true
		});
	}
	catch (e) { ghost.observer = null; }
}

// How much of the press-time growth is still to run: 0 when there is none (an
// engine without animations) or when it has already arrived. The number is in
// the animation's own clock, which is what playbackRate scales.
function jawnosWindowEmergeGrowthLeft(ghost) {
	if (!ghost || !ghost.openAnim) { return 0; }
	try {
		var anim = ghost.openAnim;
		if (!anim.effect || !anim.effect.getTiming || typeof anim.currentTime != 'number') { return 0; }
		var whole = parseFloat(anim.effect.getTiming().duration);
		if (!isFinite(whole) || whole <= 0) { return 0; }
		return Math.max(0, whole - anim.currentTime);
	}
	catch (e) { return 0; }
}

// Write the window's own frame into the growth's last keyframe, so the preview
// carries on from where it is towards the window on the clock it already has.
// Re-basing the transform instead restarts the ease midway, and the stretch the
// tail was covering gets travelled a second time - the little redo at the end.
function jawnosWindowEmergeGrowthRetarget(ghost, end_t) {
	var anim = ghost && ghost.openAnim;
	if (!anim || !anim.effect || !anim.effect.getKeyframes || !anim.effect.setKeyframes) { return false; }
	try {
		var keys = anim.effect.getKeyframes();
		if (!keys || keys.length < 2) { return false; }
		var next = [];
		for (var i = 0; i < keys.length; i++) {
			var key = keys[i];
			var offset = (typeof key.offset == 'number') ? key.offset : key.computedOffset;
			var entry = {};
			if (typeof offset == 'number') { entry.offset = offset; }
			if (key.transform !== undefined && key.transform !== null) { entry.transform = key.transform; }
			if (key.opacity !== undefined && key.opacity !== null) { entry.opacity = key.opacity; }
			next.push(entry);
		}
		next[next.length - 1].transform = end_t;
		anim.effect.setKeyframes(next);
		return true;
	}
	catch (e) { return false; }
}

// When the real window lands: if it sits where the preview is growing into,
// let that growth finish and fade the preview off it. Anywhere else (a pinned
// place or a slow slot), retarget the growth's own end so it arrives on the
// window, or - once the growth is over - take the box back and play the rest.
// The real window is never moved to the ghost: the ghost comes to the window.
// The motion starts at once, from the box the preview has reached - a hold at
// the start read as a pause part way through whenever a press moved before its
// window landed.
function jawnosWindowEmergeGhostRetarget(ghost, win_el, to, zoom) {
	if (!ghost || !ghost.el || !win_el) { return false; }
	var level = jawnosWindowEmergeLevel();
	var shape = jawnosWindowEmergeShape[level] || jawnosWindowEmergeShape.medium;
	var el = ghost.el;
	// the desk has now seen one window arrive behind its preview: remember how
	// long it took, so the next growth is sized to this device's own pace
	if (ghost.at) { jawnosWindowEmergeLatencyRecord(Date.now() - ghost.at); }
	// the real window is here: stop taking clicks for a dismissal
	jawnosWindowEmergeGhostPassThrough(el);

	// read where it actually is before cancelling the fill: an animation mid
	// flight has a real box, not the predicted one
	var current = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
	if (ghost.chromeAnim) {
		try { ghost.chromeAnim.cancel(); } catch (e) {}
		ghost.chromeAnim = null;
	}
	if (ghost.chrome) { ghost.chrome.style.opacity = '1'; }

	var from;
	if (current && current.width && current.height) {
		from = jawnosWindowEmergeCssRect(current, zoom);
	}
	else {
		// ghost.to is already in layout units; it must not be divided again
		var predicted = ghost.to || to;
		from = { left: predicted.left, top: predicted.top, width: predicted.width, height: predicted.height, radius: predicted.radius || jawnosWindowEmergeRadius() };
	}
	var through = jawnosWindowEmergeCssRect(to, zoom);
	// a measured window rectangle carries no radius; keep the window's own
	if (!to.radius) { through.radius = jawnosWindowEmergeRadius(); }

	// The preview's box has stayed at the predicted frame since the press (the
	// growth is a transform from the control onto it), so the frame it is headed
	// for is the predicted one - not wherever the growth has reached. A window
	// that lands on that frame while the long tail is still running is on the
	// same move; re-basing the transform there would replay the last stretch as
	// a second little move at the very end of the animation.
	var base = ghost.to || { left: from.left, top: from.top, width: from.width, height: from.height };
	if (!(base.width > 0) || !(base.height > 0)) {
		base = { left: from.left, top: from.top, width: from.width, height: from.height };
	}
	var off_target = Math.abs(through.left - base.left) > 0.5
		|| Math.abs(through.top - base.top) > 0.5
		|| Math.abs(through.width - base.width) > 0.5
		|| Math.abs(through.height - base.height) > 0.5;
	var duration = off_target ? shape.retarget : Math.min(shape.retarget, 160);
	var end_t = 'translate(' + (through.left - base.left) + 'px, ' + (through.top - base.top) + 'px) scale(' + (through.width / base.width) + ', ' + (through.height / base.height) + ')';

	// A window that lands while the growth is still running - a phone opens
	// locally in a few hundred ms - is not a reason to start the stretch again.
	// The window's frame is written into the growth's own last keyframe, so the
	// preview keeps its path and its clock and only speeds up enough to arrive by
	// the time the cross-fade ends. The stretch is travelled once, forwards.
	var growth_left = jawnosWindowEmergeGrowthLeft(ghost);
	var ride = growth_left > 0 && (!off_target || jawnosWindowEmergeGrowthRetarget(ghost, end_t));
	if (ride && growth_left > duration) {
		try { ghost.openAnim.playbackRate = Math.max(1, growth_left / duration); } catch (e) {}
	}

	// The preview holds its own frame while the real window fades in underneath
	// it, and only then goes: two half-transparent layers over the desk let it
	// show through, which reads as the window blinking clear at the handoff.
	var fade = function () {
		if (!el.animate) { el.style.opacity = '0'; return null; }
		var anim = el.animate([
			{ opacity: 1, offset: 0 },
			{ opacity: 1, offset: 0.7, easing: 'ease-out' },
			{ opacity: 0, offset: 1 }
		], {
			duration: duration,
			fill: 'both'
		});
		ghost.retargetAnims = ghost.retargetAnims || [];
		ghost.retargetAnims.push(anim);
		ghost.retargetAnim = anim;
		return anim;
	};

	if (ride || !off_target) {
		// The growth owns the motion; the preview only fades off it.
		fade();
	}
	else {
		// The growth has finished (or an engine cannot retarget it), and the
		// window is somewhere else: take the box back and play the rest from
		// where the preview has reached. Nothing is replayed here - the growth is
		// over, so this is only the distance to the real frame.
		if (ghost.openAnim) {
			try { ghost.openAnim.cancel(); } catch (e) {}
			ghost.openAnim = null;
		}
		el.style.transform = '';
		el.style.transformOrigin = '';
		jawnosEmergeBoxStyle(el, base);
		var start_t = 'translate(' + (from.left - base.left) + 'px, ' + (from.top - base.top) + 'px) scale(' + (from.width / base.width) + ', ' + (from.height / base.height) + ')';
		el.style.transformOrigin = '0 0';
		el.style.transform = start_t;
		if (el.animate) {
			var move = el.animate([
				{ transform: start_t, offset: 0 },
				{ transform: end_t, offset: 1 }
			], {
				duration: duration,
				easing: 'ease-out',
				fill: 'both'
			});
			ghost.retargetAnims = ghost.retargetAnims || [];
			ghost.retargetAnims.push(move);
			ghost.retargetAnim = move;
			fade();
		}
		else {
			el.style.transform = end_t;
			el.style.opacity = '0';
		}
	}

	// The real window fades in over the same beat: no snap, and no moment when
	// both are opaque enough to read as a double frame. It fades only - a scale
	// here would move its own edges (a 0.985 scale is ~5px at the foot of a
	// phone window) while the preview is landing on the layout rect, which reads
	// as the prediction sitting a few pixels high before the window catches up.
	if (win_el.animate) {
		win_el.jawnosEmergeWindowAnim = win_el.animate([
			{ opacity: 0, offset: 0 },
			{ opacity: 1, offset: 1 }
		], {
			duration: Math.max(140, duration),
			easing: 'ease-out',
			fill: 'both'
		});
	}

	ghost.win = win_el;
	win_el.jawnosEmergeGhost = ghost;
	jawnosWindowEmergeBegin();
	var finish = function () { jawnosWindowEmergeCancel(win_el); jawnosWindowEmergeEnd(win_el); };
	if (win_el.jawnosEmergeWindowAnim && win_el.jawnosEmergeWindowAnim.finished
		&& win_el.jawnosEmergeWindowAnim.finished.then) {
		win_el.jawnosEmergeWindowAnim.finished.then(finish, finish);
	}
	if (win_el.jawnosEmergeTimer) { clearTimeout(win_el.jawnosEmergeTimer); }
	win_el.jawnosEmergeTimer = setTimeout(finish, Math.max(140, duration) + 500);
	return true;
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
			{ opacity: 0, offset: 0 },
			{ opacity: 1, offset: 1 }
		]
	};
}

// A window can be re-rendered or closed mid-flight, so the preview, the sheet
// and both animations are always put down together - never left to an
// animationend that a cancelled animation will not send.
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
	// a half snap writes its transform from the release corner; clear it when
	// the motion is put down so the next drag or effect starts from the default
	if (el.jawnosHalfSnapOrigin) {
		el.style.transformOrigin = '';
		el.jawnosHalfSnapOrigin = false;
	}
	var ghost = el.jawnosEmergeGhost;
	el.jawnosEmergeGhost = null;
	if (ghost) { jawnosWindowEmergeGhostCancel(ghost); }
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
	// an old class effect and this motion both own transform; the newer one wins,
	// and it must be gone before the window's rectangle is measured
	if (typeof jawnosWindowEffectCancel == 'function') { jawnosWindowEffectCancel(el); }
	jawnosWindowEmergeCancel(el);

	var app = win.attr('app');
	origin = origin || jawnosWindowOriginTake(app);
	var ghost = jawnosWindowEmergeGhostTake(app);
	if (!origin && !ghost) { return false; }
	var measured = el.getBoundingClientRect();
	if (!measured || !measured.width || !measured.height) {
		// the window is not measurable; keep a press-time preview for its TTL
		if (ghost) { jawnosWindowEmergeGhost = ghost; }
		return false;
	}
	// The root's display zoom only. Reading it from the window's rect would
	// mistake an enter transform for zoom (the 1.5% landing error).
	var zoom = jawnosWindowEmergeZoom(null, measured);
	var layout = jawnosWindowEmergeLayoutRect(el, measured, zoom);
	// the rest of this file compares viewport-space rects and divides by zoom
	var to = {
		left: layout.left * zoom,
		top: layout.top * zoom,
		width: layout.width * zoom,
		height: layout.height * zoom
	};

	if (ghost) {
		jawnosWindowEmergeGhostRetarget(ghost, el, to, Math.max(1, zoom));
	}
	else {
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

		jawnosWindowEmergeBegin();
		var finish = function () { jawnosWindowEmergeCancel(el); jawnosWindowEmergeEnd(el); };
		if (sheet.jawnosEmergeSheetAnim.finished && sheet.jawnosEmergeSheetAnim.finished.then) {
			sheet.jawnosEmergeSheetAnim.finished.then(finish, finish);
		}
		// a throttled tab or a cancelled animation may never settle the promise;
		// the ceiling is the shape the class effects already use
		el.jawnosEmergeTimer = setTimeout(finish, keyframes.duration + 500);
	}
	// An opener that asked for a window it does not want shown hides it after
	// windowMaker returns. The preview or sheet must not outlive the window it
	// came from.
	setTimeout(function () {
		if (el.getClientRects && el.getClientRects().length === 0) { jawnosWindowEmergeCancel(el); }
	}, 0);
	return true;
}

// A press that can open an app window: the four paths the person uses. Window
// controls and anything inside a window are excluded, and a press answered by
// a window already on the desk is a raise, not a new emerge.
function jawnosWindowEmergeOpen(app) {
	if (!app || typeof document == 'undefined' || !document.querySelectorAll) { return false; }
	var winds = document.querySelectorAll('.wind');
	for (var i = 0; i < winds.length; i++) {
		if (winds[i] && winds[i].getAttribute && winds[i].getAttribute('app') === app) { return true; }
	}
	return false;
}

function jawnosWindowEmergeControl(el, opts) {
	if (!el || el.nodeType !== 1 || el.tagName == 'CANVAS') { return null; }
	if (el.closest && el.closest('.wind')) { return null; }
	var host = null;
	if (el.id && typeof startMenuIconApps != 'undefined' && startMenuIconApps[el.id]) { host = el; }
	if (!host && el.closest) { host = el.closest('.start_menu_item, .taskbar_pin, .window_toggle, .manager_search_result'); }
	if (!host && el.closest) { host = el.closest('#app_switcher .app'); }
	if (!host) { return null; }
	var app = jawnosWindowOriginApp(host) || jawnosWindowOriginApp(el);
	if (!app && host.getAttribute) {
		var sel = host.getAttribute('sel');
		if (sel && typeof jawnosTaskbarDeriveApp == 'function') { app = jawnosTaskbarDeriveApp(sel) || ''; }
	}
	if (!app) { return null; }
	// the window is already here: the press raises or restores it, and the
	// preview would promise a second window that never comes. A caller that
	// wants to answer that press itself asks for it with opts.reopen
	if (jawnosWindowEmergeOpen(app)) {
		return (opts && opts.reopen) ? { el: host, app: app, open: true } : null;
	}
	return { el: host, app: app };
}

// Every opener does not pass through windowTiledPress, which is where a raise
// gets its jiggle: a start menu icon with its own opener (music, network, help),
// a pin, or the switcher would answer an already-open press with nothing at
// all. The desk answers here instead, once, for all of them - raise the window
// it already has and give it the same jiggle. A taskbar tile is left out: its
// own click already minds raise and minimise.
function jawnosWindowEmergeRaise(control) {
	if (!control || !control.app || typeof document == 'undefined' || !document.querySelectorAll) { return false; }
	var winds = document.querySelectorAll('.wind');
	for (var i = 0; i < winds.length; i++) {
		var win = winds[i];
		if (!win || !win.getAttribute || win.getAttribute('app') !== control.app) { continue; }
		// the raise is windowTiledPress's job; the jiggle is the press's
		if (typeof jawnosWindowEffect == 'function') { jawnosWindowEffect(win, 'jiggle'); }
		if (typeof windowTiledPress == 'function') { windowTiledPress(win); }
		return true;
	}
	return false;
}

// The click that belongs to a dismissing press never reaches the opener: the
// same control pressed again means "never mind", and the inline onClick (or a
// delegated start-menu row) would otherwise ask for the window all over again.
// A capture listener sees the event before the target, so it can stop it.
if (typeof document != 'undefined' && document.addEventListener) {
	document.addEventListener('click', function (e) { jawnosWindowEmergeSwallowClick(e); }, true);
}

// A scroll is not a press. The menu is scrolled with the same finger that
// opens an app, and the browser still answers a lift that barely moved with a
// click: a scroll began an open, the preview took its frame, the row's click
// closed the menu, and the window the finger never asked for never came - only
// its picture stood on the desk. A move past the slop Touch Punch calls a drag
// (public/js/touch-threshold.js) takes the preview back at once and keeps that
// click off the row. The slop is the shim's own 12px, so a tap that drifts a
// few pixels still opens its app.
var JAWNOS_EMERGE_DRAG_SLOP = 12;
var jawnosWindowEmergePressAt = null;
var jawnosWindowEmergeDragSwallow = false;

function jawnosWindowEmergePoint(e) {
	if (!e) { return null; }
	var oe = e.originalEvent || e;
	if (oe.touches && oe.touches.length) { return { x: oe.touches[0].clientX, y: oe.touches[0].clientY }; }
	if (oe.changedTouches && oe.changedTouches.length) { return { x: oe.changedTouches[0].clientX, y: oe.changedTouches[0].clientY }; }
	if (oe.clientX != null) { return { x: oe.clientX, y: oe.clientY }; }
	return null;
}

// The controls a press can open from: the paths the preview reads, named once
// so the drag's swallow and the opener agree on what a press is.
function jawnosWindowEmergePressHost(el) {
	if (!el || el.nodeType !== 1) { return null; }
	if (el.id && typeof startMenuIconApps != 'undefined' && startMenuIconApps[el.id]) { return el; }
	if (!el.closest) { return null; }
	return el.closest('.start_menu_item, .taskbar_pin, .window_toggle, .manager_search_result, #app_switcher .app');
}

function jawnosWindowEmergePressMoved(e) {
	if (!jawnosWindowEmergePressAt) { return false; }
	var p = jawnosWindowEmergePoint(e);
	if (!p) { return false; }
	var dx = p.x - jawnosWindowEmergePressAt.x;
	var dy = p.y - jawnosWindowEmergePressAt.y;
	return (dx * dx + dy * dy) >= (JAWNOS_EMERGE_DRAG_SLOP * JAWNOS_EMERGE_DRAG_SLOP);
}

// Take the press back: no preview, and the lift it ends opens nothing. The
// swallow is short-lived and the next press clears it, so a tap made right
// after a scroll still answers.
function jawnosWindowEmergeAbandonPress() {
	jawnosWindowEmergePressClear();
	if (!jawnosWindowEmergePressAt) { return false; }
	jawnosWindowEmergePressAt = null;
	jawnosWindowEmergePointerDown = false;
	jawnosWindowEmergeGhostCancel();
	jawnosWindowEmergeDragSwallow = true;
	if (typeof setTimeout == 'function') {
		setTimeout(function () { jawnosWindowEmergeDragSwallow = false; }, 700);
	}
	return true;
}

// A touch press may be the first frame of a scroll, and the preview begins to
// grow the moment the press is made - on a phone that is a window flashing up
// for the frames it takes the finger to move. On touch the preview waits for the
// settle: a finger that stays inside the slop for a moment is a press, one that
// moves has already taken the preview back before it was ever drawn. A mouse
// cannot scroll the menu and still starts at once.
var JAWNOS_EMERGE_PRESS_SETTLE = 120;
var jawnosWindowEmergePressTimer = null;

function jawnosWindowEmergePressIsTouch(e) {
	var oe = (e && e.originalEvent) || e || {};
	if (oe.pointerType) { return oe.pointerType === 'touch'; }
	return (typeof window != 'undefined') && ('ontouchstart' in window);
}

function jawnosWindowEmergePressClear() {
	if (jawnosWindowEmergePressTimer && typeof clearTimeout == 'function') { clearTimeout(jawnosWindowEmergePressTimer); }
	jawnosWindowEmergePressTimer = null;
}

function jawnosWindowEmergePressStart(origin, e) {
	if (!origin) { return false; }
	jawnosWindowEmergePressClear();
	if (!jawnosWindowEmergePressIsTouch(e)) { return !!jawnosWindowEmergeGhostStart(origin); }
	if (typeof setTimeout != 'function') { return !!jawnosWindowEmergeGhostStart(origin); }
	jawnosWindowEmergePressTimer = setTimeout(function () {
		jawnosWindowEmergePressTimer = null;
		jawnosWindowEmergeGhostStart(origin);
	}, JAWNOS_EMERGE_PRESS_SETTLE);
	return true;
}

// A press records its control here: pointerdown catches the ordinary press
// before the menu closes or the tile re-renders. A canvas is skipped because
// its own press handler knows which pill was hit and records that rectangle (and
// starts the preview itself).
(function () {
	if (typeof $ != 'function' || typeof document == 'undefined') { return; }
	var doc = $(document);
	if (!doc || typeof doc.on != 'function') { return; }
	var press = (typeof window != 'undefined' && window.PointerEvent) ? 'pointerdown' : 'mousedown touchstart';
	doc.on(press, function (e) {
		if (!e || (e.button != null && e.button !== 0)) { return; }
		var el = e.target;
		if (!el || el.nodeType !== 1) { return; }
		jawnosWindowEmergePointerDown = true;
		// where the press landed, so a scroll is told from a tap
		jawnosWindowEmergePressAt = jawnosWindowEmergePoint(e);
		jawnosWindowEmergeDragSwallow = false;
		var waiting = jawnosWindowEmergeGhost;
		// A press on the preview itself belongs to the preview: the click that
		// follows dismisses it. Returning here keeps the press from being read as
		// one on the desk underneath, and from being recorded as an origin.
		if (waiting && !waiting.win && jawnosWindowEmergeGhostHolds(waiting, el)) { return; }
		if (el.tagName == 'CANVAS') {
			// the canvas painter records its own pill and starts the preview
			jawnosWindowEmergeGhostCancel();
			return;
		}
		var control = jawnosWindowEmergeControl(el);
		// The same control pressed again, before its window has painted, takes
		// the open back. The click that belongs to this press is swallowed, so
		// the opener is never asked a second time.
		if (waiting && !waiting.win && waiting.app && control && control.app === waiting.app) {
			jawnosWindowEmergeBlockNextClick(waiting.app);
			jawnosWindowEmergeDismiss(waiting);
			return;
		}
		// a new press replaces whatever the last one was still showing
		jawnosWindowEmergeGhostCancel();
		if (control) {
			var origin = jawnosWindowOriginFromElement(control.el, control.app);
			if (origin) { jawnosWindowEmergePressStart(origin, e); }
			return;
		}
		// the app is already on the desk: raise its window with the desk's jiggle
		// rather than leave the press unanswered, and record no origin - a window
		// that later opens must not fly in from a control pressed for a raise
		if (!(el.closest && el.closest('.window_toggle')) && jawnosWindowEmergeRaise(jawnosWindowEmergeControl(el, { reopen: true }))) {
			return;
		}
		var host = (el.closest ? el.closest('.start_menu_item, .taskbar_pin, .window_toggle') : null);
		if (host) { el = host; }
		jawnosWindowOriginFromElement(el);
	});
	// The release ends the press. The preview takes the pointer a moment later,
	// never before this press's own click has gone by: the preview's predicted
	// frame can sit over the control that started it, and a click caught there
	// would dismiss the very open it is waiting for.
	var release = function () {
		var dragged = jawnosWindowEmergeDragSwallow;
		// a tap shorter than the settle is answered by its own window; there is no
		// loading gap for a preview to cover
		jawnosWindowEmergePressClear();
		jawnosWindowEmergePressAt = null;
		jawnosWindowEmergePointerDown = false;
		var ghost = jawnosWindowEmergeGhost;
		// a scroll's lift: the preview is already gone and the click that comes
		// with the lift must not open the row it lands on
		if (dragged || !ghost || ghost.win) { return; }
		if (ghost.releaseTimer) { clearTimeout(ghost.releaseTimer); }
		ghost.releaseTimer = setTimeout(function () {
			ghost.releaseTimer = null;
			jawnosWindowEmergeGhostArm(ghost);
		}, 220);
	};
	var onmove = function (e) {
		if (jawnosWindowEmergePressMoved(e)) { jawnosWindowEmergeAbandonPress(); }
	};
	// the browser took the gesture - a scroll, a palm, an alert: the press was
	// not a tap, so the preview goes and its lift opens nothing
	var oncancel = function () { jawnosWindowEmergeAbandonPress(); };
	if (document.addEventListener) {
		document.addEventListener('pointerup', release, true);
		document.addEventListener('mouseup', release, true);
		document.addEventListener('touchend', release, true);
		document.addEventListener('pointermove', onmove, true);
		document.addEventListener('mousemove', onmove, true);
		document.addEventListener('touchmove', onmove, true);
		document.addEventListener('pointercancel', oncancel, true);
		document.addEventListener('touchcancel', oncancel, true);
	}
})();
