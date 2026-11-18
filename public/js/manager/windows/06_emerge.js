// Window emerge: a new window pours out of the control that opened it. A press
// records the control's rectangle before any window exists (a clothesline pill
// is drawn on a canvas, a start-menu icon is a DOM image), and windowMaker
// hands that rectangle to jawnosWindowEmerge once the window has its final
// place on the desk.
//
// Two pieces play the motion:
//
//   * The press-time preview (a body-level .jawnos_emerge_ghost) appears the
//     moment the pointer goes down. It already wears the standard window
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
// window while the window fades in. Either way only the real window's opacity
// and a tiny scale animate - its text is never squashed - and WebGL is not
// used. The ghost does animate its own box (left/top/width/height) while it
// grows, because a scaled chrome would distort the icon, the name and the
// controls; it is one fixed element for a few hundred milliseconds.

// A press is good for a while: a lazy app's chunk, a server round trip and a
// pile relayout all happen between the press and the window. An app-less press
// is only trusted for a moment, so a stray control cannot claim the next
// window that happens to arrive.
var JAWNOS_EMERGE_TTL = 10000;
var JAWNOS_EMERGE_FALLBACK = 1500;
var JAWNOS_EMERGE_MAX_ORIGINS = 16;
// The preview outlives a slow round trip, but a press that opens nothing must
// not leave a window-shaped ghost standing on the desk.
var JAWNOS_EMERGE_GHOST_TTL = 3000;

var jawnosWindowOrigins = {};
var jawnosWindowOriginLast = null;
var jawnosWindowEmergeGhost = null;

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
	var host = (el.closest ? el.closest('.window_toggle, .taskbar_pin, .start_menu_item, .app') : null);
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

function jawnosWindowEmergeViewport() {
	var width = 0;
	var height = 0;
	try {
		if (typeof window != 'undefined') {
			width = window.innerWidth || 0;
			height = window.innerHeight || 0;
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
	try {
		if (typeof getComputedStyle == 'function' && typeof document != 'undefined' && document.documentElement) {
			var served = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--window_radius'));
			if (isFinite(served) && served >= 0) { return served; }
		}
	}
	catch (e) {}
	return 12;
}

// The frame a fresh window is about to take: the standard 480x640 at the next
// slot of the default pile. The press has not reserved its slot yet (that
// happens on click), so windowNextTileSlot already names the slot it will get;
// a slot another press is still holding is counted, so two quick presses do not
// predict the same place.
function jawnosWindowEmergePredict(origin) {
	origin = origin || {};
	var view = jawnosWindowEmergeViewport();
	var width = (typeof windowTileDefaultWidth == 'number' && windowTileDefaultWidth > 0) ? windowTileDefaultWidth : 480;
	var height = (typeof windowTileDefaultHeight == 'number' && windowTileDefaultHeight > 0) ? windowTileDefaultHeight : 640;
	var left = 0;
	var top = 0;
	var placed = false;

	if (typeof windowPhoneChecker == 'function' && windowPhoneChecker()) {
		// a phone's window is the width of the desk and most of its height
		width = view.width;
		height = Math.max(200, Math.round(view.height * 0.7128));
		top = (typeof windowTopLimit == 'function') ? Math.max(0, windowTopLimit()) : 0;
		placed = true;
	}
	else if (typeof windowTiledAnchor == 'function' && typeof windowNextTileSlot == 'function') {
		var stack = (typeof jawnosWorkspaceStackDefault == 'function')
			? jawnosWorkspaceStackDefault()
			: ((typeof windowTiledDefaultStack != 'undefined') ? windowTiledDefaultStack : '0');
		var anchor = windowTiledAnchor(stack) || { left: 0, top: 0 };
		var slot = windowNextTileSlot(stack) || 0;
		// A cascade steps across by 50 and down by the title bar less its border.
		var bar = 36;
		var border = 3;
		var probe = (typeof document != 'undefined' && document.querySelector) ? document.querySelector('.top_navbar') : null;
		if (probe && probe.getBoundingClientRect && typeof getComputedStyle == 'function') {
			var box = probe.getBoundingClientRect();
			var served_border = parseFloat(getComputedStyle(probe).borderTopWidth);
			if (box && box.height) { bar = box.height; }
			if (isFinite(served_border)) { border = served_border; }
		}
		left = (jawnosEmergeNumber(anchor.left, 0)) + slot * 50;
		top = (jawnosEmergeNumber(anchor.top, 0)) + slot * Math.max(20, bar - border);
		placed = true;
	}

	if (!placed) {
		// no stack reader on this page: stand the preview beside the press
		left = jawnosEmergeNumber(origin.left, 0);
		top = jawnosEmergeNumber(origin.top, 0);
	}

	// keep the frame on the desk, the way windowFit would
	if (width > view.width - 8) { width = Math.max(160, view.width - 8); }
	if (left + width > view.width - 8) { left = Math.max(0, view.width - width - 8); }
	if (left < 0) { left = 0; }
	if (height > view.height - 16) { height = Math.max(160, view.height - 16); }
	if (top + height > view.height - 8) { top = Math.max(0, view.height - height - 8); }
	if (top < 0) { top = 0; }

	return {
		left: left,
		top: top,
		width: width,
		height: height,
		radius: jawnosWindowEmergeRadius()
	};
}

// A stable, quiet tint that tells one app's preview from another without
// claiming the bold colour the server saved for its title bar (which the
// preview cannot know before the response). It is only a wash over the
// standard surface, so the cross-fade has little to undo.
function jawnosWindowEmergeTint(app) {
	if (!app) { return 'transparent'; }
	var hash = 0;
	for (var i = 0; i < app.length; i++) {
		hash = ((hash * 31) + app.charCodeAt(i)) % 360;
	}
	return 'hsla(' + hash + ', 46%, 52%, 0.20)';
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
	var chrome = jawnosEmergeElement('div', 'jawnos_emerge_chrome');
	if (!chrome) { return null; }
	var bar = jawnosEmergeElement('div', 'jawnos_emerge_bar');
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
	jawnosEmergeAppend(chrome, jawnosEmergeElement('div', 'jawnos_emerge_body'));
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

// The press-time preview. It is created inside pointerdown, so the desktop has
// already answered before the app's chunk or the server is asked. The chrome
// fades in as the box grows readable, then the preview holds at the predicted
// frame until the real window lands (or the TTL puts it away).
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
	var to = jawnosWindowEmergePredict(origin);
	var el = jawnosEmergeElement('div', 'jawnos_emerge_ghost');
	if (!el) { return null; }
	el.setAttribute('aria-hidden', 'true');
	el.style.setProperty('--emerge_tint', jawnosWindowEmergeTint(origin.app));
	jawnosEmergeBoxStyle(el, from);

	var chrome = jawnosWindowEmergeChrome(origin);
	if (chrome) {
		chrome.style.opacity = '0';
		el.appendChild(chrome);
	}

	var ghost = { el: el, chrome: chrome, app: origin.app || '', origin: origin, to: to, timer: null, openAnim: null, chromeAnim: null, win: null };
	document.body.appendChild(el);
	jawnosWindowEmergeGhost = ghost;

	if (el.animate) {
		ghost.openAnim = el.animate([
			{ left: from.left + 'px', top: from.top + 'px', width: from.width + 'px', height: from.height + 'px', borderRadius: from.radius + 'px', offset: 0 },
			{ left: to.left + 'px', top: to.top + 'px', width: to.width + 'px', height: to.height + 'px', borderRadius: to.radius + 'px', offset: 1 }
		], {
			duration: shape.ghost,
			easing: 'cubic-bezier(.2,.85,.25,1)',
			fill: 'both'
		});
	}
	else {
		jawnosEmergeBoxStyle(el, to);
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

	// A window may be slow; three seconds of a window-shaped ghost is already
	// long enough to look like a leak.
	ghost.timer = setTimeout(function () { jawnosWindowEmergeGhostCancel(ghost); }, JAWNOS_EMERGE_GHOST_TTL);
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

// When the real window lands: freeze the preview where it has reached, retarget
// it to the window's own rectangle (a pinned place or a slow slot can differ
// from the prediction), and cross-fade the two. The real window is never moved
// to the ghost: the ghost comes to the window.
function jawnosWindowEmergeGhostRetarget(ghost, win_el, to, zoom) {
	if (!ghost || !ghost.el || !win_el) { return false; }
	var level = jawnosWindowEmergeLevel();
	var shape = jawnosWindowEmergeShape[level] || jawnosWindowEmergeShape.medium;
	var el = ghost.el;

	// read where it actually is before cancelling the fill: an animation mid
	// flight has a real box, not the predicted one
	var current = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
	if (ghost.openAnim) {
		try { ghost.openAnim.cancel(); } catch (e) {}
		ghost.openAnim = null;
	}
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
	var moved = Math.abs(through.left - from.left) > 0.5
		|| Math.abs(through.top - from.top) > 0.5
		|| Math.abs(through.width - from.width) > 0.5
		|| Math.abs(through.height - from.height) > 0.5;
	var duration = moved ? shape.retarget : Math.min(shape.retarget, 160);

	jawnosEmergeBoxStyle(el, from);
	if (el.animate) {
		ghost.retargetAnim = el.animate([
			{ left: from.left + 'px', top: from.top + 'px', width: from.width + 'px', height: from.height + 'px', borderRadius: from.radius + 'px', opacity: 1, offset: 0 },
			{ left: from.left + 'px', top: from.top + 'px', width: from.width + 'px', height: from.height + 'px', borderRadius: from.radius + 'px', opacity: 1, offset: 0.42 },
			{ left: through.left + 'px', top: through.top + 'px', width: through.width + 'px', height: through.height + 'px', borderRadius: through.radius + 'px', opacity: 0, offset: 1 }
		], {
			duration: duration,
			easing: 'ease-out',
			fill: 'both'
		});
	}
	else {
		jawnosEmergeBoxStyle(el, through);
		el.style.opacity = '0';
	}

	// The real window fades in over the same beat: no snap, and no moment when
	// both are opaque enough to read as a double frame.
	if (win_el.animate) {
		win_el.jawnosEmergeWindowAnim = win_el.animate([
			{ opacity: 0, transform: 'scale(0.985)', offset: 0 },
			{ opacity: 1, transform: 'scale(1)', offset: 1 }
		], {
			duration: Math.max(140, duration),
			easing: 'ease-out',
			fill: 'both'
		});
	}

	ghost.win = win_el;
	win_el.jawnosEmergeGhost = ghost;
	var finish = function () { jawnosWindowEmergeCancel(win_el); };
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
			{ opacity: 0, transform: 'scale(0.985)', offset: 0 },
			{ opacity: 1, transform: 'scale(1)', offset: 1 }
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
	var to = el.getBoundingClientRect();
	if (!to || !to.width || !to.height) {
		// the window is not measurable; keep a press-time preview for its TTL
		if (ghost) { jawnosWindowEmergeGhost = ghost; }
		return false;
	}
	var zoom = jawnosWindowEmergeZoom(el, to);

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

		var finish = function () { jawnosWindowEmergeCancel(el); };
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

function jawnosWindowEmergeControl(el) {
	if (!el || el.nodeType !== 1 || el.tagName == 'CANVAS') { return null; }
	if (el.closest && el.closest('.wind')) { return null; }
	var host = null;
	if (el.id && typeof startMenuIconApps != 'undefined' && startMenuIconApps[el.id]) { host = el; }
	if (!host && el.closest) { host = el.closest('.start_menu_item, .taskbar_pin, .window_toggle'); }
	if (!host && el.closest) { host = el.closest('#app_switcher .app'); }
	if (!host) { return null; }
	var app = jawnosWindowOriginApp(host) || jawnosWindowOriginApp(el);
	if (!app && host.getAttribute) {
		var sel = host.getAttribute('sel');
		if (sel && typeof jawnosTaskbarDeriveApp == 'function') { app = jawnosTaskbarDeriveApp(sel) || ''; }
	}
	if (!app) { return null; }
	// the window is already here: the press raises or restores it, and the
	// preview would promise a second window that never comes
	if (jawnosWindowEmergeOpen(app)) { return null; }
	return { el: host, app: app };
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
		// a new press replaces whatever the last one was still showing
		jawnosWindowEmergeGhostCancel();
		if (el.tagName == 'CANVAS') { return; }
		var control = jawnosWindowEmergeControl(el);
		if (control) {
			var origin = jawnosWindowOriginFromElement(control.el, control.app);
			if (origin) { jawnosWindowEmergeGhostStart(origin); }
			return;
		}
		var host = (el.closest ? el.closest('.start_menu_item, .taskbar_pin, .window_toggle') : null);
		if (host) { el = host; }
		jawnosWindowOriginFromElement(el);
	});
})();
