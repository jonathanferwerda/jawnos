// Window effects: the desk's own memory of a compositor. A dragged window leans
// and lags like a soft sheet, a half or maximized window stretches into its new
// size, a minimizing or returning window bounces, a window whose top was snapped
// up to the clothesline settles down from that edge, and a pinned one gives a
// small kick. Every motion is a transform on .wind (see manager.css), so layout,
// the saved geometry and the drag maths never see it. One Misc level - off,
// light, medium or maximum - sets the amplitude of the whole set.

function jawnosWindowEffectsLevel() {
	var raw = '';
	if (typeof jawnos_bar_settings != 'undefined' && jawnos_bar_settings) {
		raw = jawnos_bar_settings['window_effects'] || '';
	}
	if (raw === 'off') { return 'off'; }
	if (raw === 'light' || raw === 'maximum') { return raw; }
	// '' is a desk that never chose, and 'on' is the old two-state switch
	return 'medium';
}

function jawnosWindowEffectsOn() {
	return jawnosWindowEffectsLevel() !== 'off';
}

// The one-shot CSS obeys reduced motion by finishing at once; the physics has to
// ask before it starts, because it writes transforms frame by frame.
function jawnosWindowMotionAllowed() {
	if (typeof window != 'undefined' && window.matchMedia
		&& window.matchMedia('(prefers-reduced-motion: reduce)').matches) { return false; }
	return jawnosWindowEffectsOn();
}

// The amount the motions are multiplied by. The CSS reads its own copy of this
// through body[data-window-effects]; the physics and the emerge part read here.
function jawnosWindowEffectScale() {
	var level = jawnosWindowEffectsLevel();
	if (level === 'light') { return 0.5; }
	if (level === 'maximum') { return 1.9; }
	return 1;
}

// The panel's change handler calls this as soon as the level moves. The server
// also stamps the body, so the CSS amplitudes are right on the first paint; this
// keeps them right without a reload.
function jawnosWindowEffectsSet(value) {
	if (typeof jawnos_bar_settings == 'undefined' || !jawnos_bar_settings) { return; }
	var level = (value === 'off' || value === 'light' || value === 'maximum') ? value : 'medium';
	jawnos_bar_settings['window_effects'] = level;
	if (typeof document != 'undefined' && document.body) {
		document.body.setAttribute('data-window-effects', level);
	}
	if (level !== 'off') { return; }
	$('.wind').each(function() {
		// a close already in flight still has to finish: the window is on its way
		// out, and switching the effects off must not leave it on the desk
		if (this.jawnosCloseEnd) { this.jawnosCloseEnd(); }
		// a hide already in flight still has to finish: turning the effects off
		// must not leave a "minimised" window on the desk
		if (this.jawnosHideEnd) { this.jawnosHideEnd(); }
		jawnosWindowEffectCancel(this);
		if (typeof jawnosWindowEmergeCancel == 'function') { jawnosWindowEmergeCancel(this); }
	});
}

function jawnosWindowEffectsSeed() {
	if (typeof document != 'undefined' && document.body) {
		document.body.setAttribute('data-window-effects', jawnosWindowEffectsLevel());
	}
}
if (typeof document != 'undefined') {
	if (document.body) { jawnosWindowEffectsSeed(); }
	else if (document.addEventListener) { document.addEventListener('DOMContentLoaded', jawnosWindowEffectsSeed); }
}

// The one-shot classes live in one place so a new effect cannot leave another
// one behind when it starts. The wobble is not one of these: it writes its own
// transform while the title bar is held.
var jawnosWindowEffectClasses = 'jawnos_effect_stretch jawnos_effect_in jawnos_effect_out jawnos_effect_lock jawnos_effect_snap jawnos_effect_jiggle jawnos_effect_control';

function jawnosWindowPhysicsCancel(win) {
	var el = $(win)[0];
	if (!el) { return; }
	var state = el.jawnosWobble;
	if (state && state.raf && typeof cancelAnimationFrame == 'function') { cancelAnimationFrame(state.raf); }
	// the pile the dragged window carried leans with it; putting the lean down
	// has to put the cards' down too, or one keeps a transform nothing owns
	if (state && state.followers) {
		for (var i = 0; i < state.followers.length; i++) {
			var follow = state.followers[i];
			if (!follow) { continue; }
			if (follow.style) { follow.style.transform = ''; }
			$(follow).removeClass('jawnos_wobbling');
		}
	}
	el.jawnosWobble = null;
	el.style.transform = '';
	$(el).removeClass('jawnos_wobbling');
}

function jawnosWindowEffectCancel(win) {
	var el = $(win)[0];
	if (!el) { return; }
	jawnosWindowPhysicsCancel(el);
	// a window being dragged, maximized or switched off should not still be
	// pouring out of the control that opened it
	if (typeof jawnosWindowEmergeCancel == 'function') { jawnosWindowEmergeCancel(el); }
	if (el.jawnosEffectTimer) {
		clearTimeout(el.jawnosEffectTimer);
		el.jawnosEffectTimer = null;
	}
	$(el).removeClass(jawnosWindowEffectClasses);
}

// One motion. The timer is only a ceiling: animationend is not guaranteed (a
// hidden window, a throttled tab, reduced motion), and the class must not
// outlive the motion.
function jawnosWindowEffect(win, name) {
	win = $(win);
	if (!win.length || !jawnosWindowEffectsOn()) { return; }
	var el = win[0];
	// A control press arrives twice - the pointerdown that starts the preview,
	// then the click that opens or raises - and one press wears one jiggle.
	// Anything inside a window is a raise only, so it never reaches here.
	if (name === 'jiggle') {
		var stamp = (typeof performance != 'undefined' && performance.now) ? performance.now() : Date.now();
		if (stamp - (el.jawnosJiggleAt || 0) < 500) { return; }
		el.jawnosJiggleAt = stamp;
	}
	jawnosWindowEffectCancel(el);
	// a reflow between removing and adding restarts the same keyframes, so
	// pressing the pin twice in a row still kicks twice
	void el.offsetWidth;
	win.addClass('jawnos_effect_' + name);
	el.jawnosEffectTimer = setTimeout(function() {
		el.jawnosEffectTimer = null;
		win.removeClass('jawnos_effect_' + name);
	}, 900);
}

// ---- the soft-sheet drag ---------------------------------------------------
// A damped spring behind the title bar. The pointer's own speed sets a target
// shear (the foot trails the hand) and a small 3D tilt; the spring runs up to
// the target while moving and overshoots back through zero when the hand stops,
// which is the jiggle. It is deliberately not a fixed keyframe loop: a still
// window should be still.

function jawnosWindowWobbleNow() {
	return (typeof performance != 'undefined' && performance.now) ? performance.now() : Date.now();
}

function jawnosWindowWobbleState(el) {
	if (!el.jawnosWobble) {
		el.jawnosWobble = {
			dragging: false,
			shear: 0, shearV: 0,
			yaw: 0, yawV: 0,
			pitch: 0, pitchV: 0,
			targetShear: 0, targetYaw: 0, targetPitch: 0,
			lastX: null, lastY: null, lastT: 0, lastMove: 0, lastFrame: 0,
			raf: 0
		};
	}
	return el.jawnosWobble;
}

// One spring step. Kept pure so the tests can play it without a renderer.
function jawnosWindowWobbleStep(state, dt, scale) {
	dt = Math.max(0.001, Math.min(0.04, dt));
	var k = 120 + (scale - 1) * 20;
	var c = 15 - (scale - 1) * 1.5;
	if (c < 9) { c = 9; }
	function spring(pos, vel, target) {
		var acc = -k * (pos - target) - c * vel;
		vel += acc * dt;
		pos += vel * dt;
		return [pos, vel];
	}
	var s = spring(state.shear, state.shearV, state.targetShear);
	state.shear = s[0]; state.shearV = s[1];
	var y = spring(state.yaw, state.yawV, state.targetYaw);
	state.yaw = y[0]; state.yawV = y[1];
	var p = spring(state.pitch, state.pitchV, state.targetPitch);
	state.pitch = p[0]; state.pitchV = p[1];
	if (Math.abs(state.shear) < 0.01 && Math.abs(state.yaw) < 0.01 && Math.abs(state.pitch) < 0.01) {
		return '';
	}
	return 'perspective(1400px) rotateX(' + state.pitch.toFixed(2) + 'deg) rotateY('
		+ state.yaw.toFixed(2) + 'deg) skewX(' + state.shear.toFixed(2) + 'deg)';
}

function jawnosWindowWobbleMove(win, x, y) {
	var el = $(win)[0];
	if (!el || !el.jawnosWobble) { return; }
	var state = el.jawnosWobble;
	var now = jawnosWindowWobbleNow();
	if (state.lastX === null) {
		state.lastX = x; state.lastY = y;
		state.lastT = now; state.lastMove = now;
		return;
	}
	var dt = Math.max(4, Math.min(64, now - state.lastT));
	var vx = (x - state.lastX) / dt;   // px/ms
	var vy = (y - state.lastY) / dt;
	var scale = jawnosWindowEffectScale();
	var maxShear = 4.5 * scale, maxYaw = 2.0 * scale, maxPitch = 1.6 * scale;
	// the foot lags the hand: moving right shears the bottom left
	state.targetShear = Math.max(-maxShear, Math.min(maxShear, -vx * 4.2 * scale));
	state.targetYaw = Math.max(-maxYaw, Math.min(maxYaw, -vx * 1.15 * scale));
	state.targetPitch = Math.max(-maxPitch, Math.min(maxPitch, vy * 1.1 * scale));
	state.lastX = x; state.lastY = y;
	state.lastT = now; state.lastMove = now;
}

function jawnosWindowWobbleFrame(el) {
	var state = el.jawnosWobble;
	if (!state) { return; }
	if (!el.parentNode) { jawnosWindowPhysicsCancel(el); return; }
	var now = jawnosWindowWobbleNow();
	var dt = state.lastFrame ? (now - state.lastFrame) / 1000 : 0.016;
	state.lastFrame = now;
	if (now - state.lastMove > 55) {
		state.targetShear = 0; state.targetYaw = 0; state.targetPitch = 0;
	}
	var transform = jawnosWindowWobbleStep(state, dt, jawnosWindowEffectScale());
	// The pile below the card in the hand leans on the same frame: the pointer's
	// speed is one value, and a second loop per card would only multiply the
	// work on a desk that is already busy.
	if (state.followers) {
		for (var i = 0; i < state.followers.length; i++) {
			var follow = state.followers[i];
			if (follow && follow.style && follow.parentNode) { follow.style.transform = transform || ''; }
		}
	}
	if (transform) {
		el.style.transform = transform;
	}
	else if (!state.dragging) {
		// settled: the whole pile puts its lean down together
		jawnosWindowPhysicsCancel(el);
		return;
	}
	else {
		el.style.transform = '';
	}
	state.raf = requestAnimationFrame(function() { jawnosWindowWobbleFrame(el); });
}

function jawnosWindowWobbleStart(win, followers) {
	win = $(win);
	if (!win.length || !jawnosWindowMotionAllowed()) { return; }
	var el = win[0];
	jawnosWindowEffectCancel(win);
	var state = jawnosWindowWobbleState(el);
	state.dragging = true;
	state.lastX = null; state.lastY = null;
	state.lastT = 0; state.lastMove = 0; state.lastFrame = 0;
	state.shear = state.shearV = 0;
	state.yaw = state.yawV = 0;
	state.pitch = state.pitchV = 0;
	state.targetShear = state.targetYaw = state.targetPitch = 0;
	// The cards the drag carries (a pile's windows below the held one) lean with
	// it, so a cascade does not come apart while it travels. They are given the
	// same pivot as the held card, so the whole pile turns as one sheet.
	state.followers = [];
	if (followers) {
		for (var i = 0; i < followers.length; i++) {
			var follow = followers[i];
			var node = (follow && follow.nodeType === 1) ? follow : (follow && follow.el ? follow.el : null);
			if (!node || node === el) { continue; }
			state.followers.push(node);
			$(node).addClass('jawnos_wobbling');
		}
	}
	win.addClass('jawnos_wobbling');
	if (typeof requestAnimationFrame == 'function') {
		state.raf = requestAnimationFrame(function() { jawnosWindowWobbleFrame(el); });
	}
	else {
		jawnosWindowPhysicsCancel(el);
	}
}

function jawnosWindowWobbleStop(win) {
	var el = $(win)[0];
	if (!el) { return; }
	var state = el.jawnosWobble;
	if (!state) { return; }
	state.dragging = false;
	state.targetShear = 0; state.targetYaw = 0; state.targetPitch = 0;
	// with no frame loop (an odd engine) there is nothing to settle
	if (!state.raf) { jawnosWindowPhysicsCancel(el); }
}

// ---- the control a window goes into, and comes out of ----------------------
// A minimising window should read as going into its own taskbar tile (or the
// dock pin holding it), and a restored one as coming out of it. The control is
// measured once, before the motion starts, and its offset and size are handed
// to the keyframes in manager.css as custom properties; the level's travel and
// collapse decide how much of the way the window goes, so light stays a hint
// and maximum overshoots. A control with no box on screen - an autohide tile
// tucked past the edge, a hidden dock, a phone with no bar - is no control at
// all: the window keeps the centre bounce it always had, because chasing a tile
// off the viewport would drag the window off the desk with it.

// Does this control have a box the person could actually press? A hidden bar
// leaves its tile in the document, so the box, not the presence, is the answer.
function jawnosWindowEffectControlShown(node) {
	if (!node || !node.getBoundingClientRect) { return false; }
	var rect = node.getBoundingClientRect();
	if (!rect || !rect.width || !rect.height) { return false; }
	var vw = 0, vh = 0;
	if (typeof window != 'undefined') {
		vw = (window.visualViewport && window.visualViewport.width) || window.innerWidth || 0;
		vh = (window.visualViewport && window.visualViewport.height) || window.innerHeight || 0;
	}
	if (vw && vh) {
		// an autohidden bar slides its tile past the edge and keeps only a seam
		// on screen; a centre out there is a control the window must not chase
		var cx = rect.left + rect.width / 2;
		var cy = rect.top + rect.height / 2;
		if (cx < 0 || cy < 0 || cx > vw || cy > vh) { return false; }
	}
	return true;
}

function jawnosWindowEffectControlFind(selector, attr, value) {
	var found = null;
	$(selector).each(function() {
		if (found || !this.getAttribute) { return; }
		if (this.getAttribute(attr) !== value) { return; }
		if (jawnosWindowEffectControlShown(this)) { found = this; }
	});
	return found;
}

// The control a window answers for. Its own tile first - a dialog, a Terminal
// or a Folders window shares its app name with its siblings, and only one tile
// is its own - then the app's tile, then the dock pin the tile lives in.
function jawnosWindowEffectControl(win) {
	var el = $(win)[0];
	if (!el || !el.getAttribute) { return null; }
	var pairs = [
		['data-dialog-id', el.getAttribute('data-dialog-id') || ''],
		['data-terminal-id', el.getAttribute('data-terminal-id') || ''],
		['data-window-id', el.getAttribute('data-window-id') || ''],
		['app', el.getAttribute('app') || '']
	];
	for (var i = 0; i < pairs.length; i++) {
		if (!pairs[i][1]) { continue; }
		var tile = jawnosWindowEffectControlFind('.window_toggle', pairs[i][0], pairs[i][1]);
		if (tile) { return tile; }
	}
	var app = el.getAttribute('app') || '';
	if (!app) { return null; }
	return jawnosWindowEffectControlFind('.taskbar_pin', 'app', app);
}

// Write the control's offset and size onto the window for the keyframes. The
// window is still laid out where it was when this runs, so both rects are the
// settled ones; the desk's display zoom is taken out because the properties
// become layout pixels inside the same zoom.
function jawnosWindowEffectAim(win) {
	var el = $(win)[0];
	if (!el || !el.getBoundingClientRect || !el.style || !el.style.setProperty) { return false; }
	var rect = el.getBoundingClientRect();
	if (!rect || !rect.width || !rect.height) { return false; }
	var node = jawnosWindowEffectControl(el);
	if (!node) { return false; }
	var cr = node.getBoundingClientRect();
	if (!cr || !cr.width || !cr.height) { return false; }
	var zoom = (el.offsetWidth && rect.width) ? rect.width / el.offsetWidth : 1;
	if (!isFinite(zoom) || zoom <= 0) { zoom = 1; }
	var ox = ((cr.left + cr.width / 2) - (rect.left + rect.width / 2)) / zoom;
	var oy = ((cr.top + cr.height / 2) - (rect.top + rect.height / 2)) / zoom;
	var sx = Math.max(0.02, Math.min(1, cr.width / rect.width));
	var sy = Math.max(0.02, Math.min(1, cr.height / rect.height));
	// the 'in' motion hangs from the title bar, so its foot-scale already lifts
	// the middle: the offset that lands the scaled window on the tile is shorter
	// than the middle-to-middle one the 'out' motion uses
	var iy = (cr.top + cr.height / 2 - rect.top) / zoom - (rect.height / zoom) / 2 * sy;
	el.style.setProperty('--je-out-x', ox.toFixed(1) + 'px');
	el.style.setProperty('--je-out-y', oy.toFixed(1) + 'px');
	el.style.setProperty('--je-in-y', iy.toFixed(1) + 'px');
	el.style.setProperty('--je-out-sx', sx.toFixed(4));
	el.style.setProperty('--je-out-sy', sy.toFixed(4));
	return true;
}

// One aimed one-shot. The aim is measured before the class goes on, because the
// rect has to be the window's own box; the marker that switches the keyframes
// is added after it, because the one-shot's own cancel clears the classes.
function jawnosWindowEffectToControl(win, name) {
	win = $(win);
	if (!win.length) { return; }
	var aimed = jawnosWindowEffectAim(win);
	jawnosWindowEffect(win, name);
	if (aimed) { win.addClass('jawnos_effect_control'); }
}

// Hiding a window takes two steps when the effect is on: the 'out' animation
// shrinks and fades it, and the hide waits for the animation to end. The token
// lets a restore that lands mid-flight cancel the hide instead of letting the
// window vanish after it has been called back.
function jawnosWindowEffectsCancelHide(win) {
	var el = $(win)[0];
	if (!el) { return; }
	el.jawnosHideToken = null;
	if (el.jawnosHideTimer) {
		clearTimeout(el.jawnosHideTimer);
		el.jawnosHideTimer = null;
	}
	if (el.jawnosHideEnd) {
		el.removeEventListener('animationend', el.jawnosHideEnd);
		el.jawnosHideEnd = null;
	}
}

function jawnosWindowMinimizeOut(win) {
	win = $(win);
	if (!win.length || !jawnosWindowEffectsOn()) { return false; }
	var el = win[0];
	// a window already closing is on its way out; the tile cannot freeze it
	if (el.jawnosCloseToken) { return true; }
	jawnosWindowEffectsCancelHide(win);
	jawnosWindowEffectToControl(win, 'out');
	var token = {};
	el.jawnosHideToken = token;
	var finish = function(ev) {
		// a child's own animation bubbles; only the window's out motion ends it
		if (ev && ev.target !== el) { return; }
		if (el.jawnosHideToken !== token) { return; }
		el.jawnosHideToken = null;
		jawnosWindowEffectsCancelHide(win);
		win.hide();
		if (typeof windowBackgroundAdjuster == 'function') { windowBackgroundAdjuster(); }
	};
	el.jawnosHideEnd = finish;
	el.addEventListener('animationend', finish);
	// the effect class also owns a ceiling; this one only matters when the
	// animation never starts, so it is longer than any motion
	el.jawnosHideTimer = setTimeout(finish, 500);
	return true;
}

// Is the window still on screen only because its out motion is playing? A tile
// pressed now means "bring it back", not "minimise it again".
function jawnosWindowEffectLeaving(win) {
	var el = $(win)[0];
	return !!(el && el.jawnosHideToken);
}

// A window coming back: cancel any hide still in flight, then bounce it in.
function jawnosWindowRestoreIn(win) {
	win = $(win);
	if (!win.length) { return; }
	// a closing window is not coming back; its close finishes and removes it
	if (win[0].jawnosCloseToken) { return; }
	jawnosWindowEffectsCancelHide(win);
	if (!jawnosWindowEffectsOn()) { return; }
	jawnosWindowEffectToControl(win, 'in');
}

// ---- closing ---------------------------------------------------------------
// A closed window used to be torn down at once, which read as a blink. The
// level now owns a farewell that plays before the teardown: light fades, medium
// crumbles, maximum bursts. The pieces are cut from the window's own rectangle
// - a handful of translucent blocks on a fixed overlay, never a copy of its
// content - so the cost is one CSS animation and a few divs. The overlay cannot
// swallow a press, cannot change layout, and is removed with the window. The
// ceiling is short because the teardown (the save and the window_closer POST)
// waits on it.

var jawnosWindowCloseClasses = 'jawnos_effect_close_fade jawnos_effect_close_crumble jawnos_effect_close_burst';

// The pieces: a 4x2 grid of the window's face. Medium drops one cell so a
// crumble looks chipped; maximum keeps all eight. Each piece knows which way it
// lies from the window's middle, and the keyframes multiply that. No DOM clone
// of the window is made; these are plain blocks in the window's own colours.
function jawnosWindowCloseShards(el, rect, level) {
	if (typeof document == 'undefined' || !document.body || !document.createElement) { return null; }
	var zoom = (el && el.offsetWidth && rect.width) ? rect.width / el.offsetWidth : 1;
	if (!isFinite(zoom) || zoom <= 0) { zoom = 1; }
	var width = rect.width / zoom;
	var height = rect.height / zoom;
	var box = document.createElement('div');
	box.className = 'jawnos_close_shards';
	box.setAttribute('aria-hidden', 'true');
	box.style.cssText = 'position:fixed;pointer-events:none;overflow:visible;'
		+ 'left:' + (rect.left / zoom).toFixed(1) + 'px;top:' + (rect.top / zoom).toFixed(1) + 'px;'
		+ 'width:' + width.toFixed(1) + 'px;height:' + height.toFixed(1) + 'px;';
	var z = 0;
	try { z = parseInt($(el).css('z-index'), 10) || 0; } catch (e) { z = 0; }
	// A row inside a window has no stacking level of its own; the overlay would
	// land at the body's lowest layer, under the glass that holds the row. Borrow
	// the nearest window's level (or, when it has none, the browser context's), so
	// the pieces ride above it. A window answers with itself and keeps its z.
	try {
		var host = 0;
		if (typeof $(el).closest === 'function') {
			var glass = $(el).closest('.wind');
			var browser_ctx = $(el).closest('#browser');
			if (glass.length) { host = parseInt(glass.css('z-index'), 10) || 0; }
			if (browser_ctx.length) { host = Math.max(host, parseInt(browser_ctx.css('z-index'), 10) || 0); }
		}
		if (host > z) { z = host; }
	} catch (e) {}
	box.style.zIndex = z + 1;
	var cols = 4;
	var rows = 2;
	var cell_width = width / cols;
	var cell_height = height / rows;
	var count = (level === 'maximum') ? cols * rows : cols * rows - 1;
	for (var i = 0; i < count; i++) {
		var col = i % cols;
		var row = Math.floor(i / cols);
		var shard = document.createElement('div');
		shard.className = 'jawnos_close_shard' + (level === 'maximum' ? ' jawnos_close_shard_burst' : '');
		shard.style.cssText = 'position:absolute;left:' + (col * cell_width).toFixed(1) + 'px;top:' + (row * cell_height).toFixed(1) + 'px;'
			+ 'width:' + cell_width.toFixed(1) + 'px;height:' + cell_height.toFixed(1) + 'px;';
		shard.style.setProperty('--je-shard-x', ((col + .5) * cell_width - width / 2).toFixed(1) + 'px');
		shard.style.setProperty('--je-shard-y', ((row + .5) * cell_height - height / 2).toFixed(1) + 'px');
		// the crumble chips away from one side; the burst leaves together
		shard.style.animationDelay = (i * 8) + 'ms';
		box.appendChild(shard);
	}
	if (level === 'maximum') {
		var flash = document.createElement('div');
		flash.className = 'jawnos_close_flash';
		box.appendChild(flash);
	}
	document.body.appendChild(box);
	return box;
}

function jawnosWindowCloseFinish(el, shards, done) {
	el.jawnosCloseToken = null;
	if (el.jawnosCloseEnd) {
		el.removeEventListener('animationend', el.jawnosCloseEnd);
		el.jawnosCloseEnd = null;
	}
	if (el.jawnosCloseTimer) {
		clearTimeout(el.jawnosCloseTimer);
		el.jawnosCloseTimer = null;
	}
	if (shards && shards.parentNode) { shards.parentNode.removeChild(shards); }
	$(el).removeClass(jawnosWindowCloseClasses);
	if (typeof done == 'function') { done(); }
	// a close asked for while this one was already playing waits here, so its
	// own teardown and its caller's moment still happen, once
	var waits = el.jawnosCloseWaits;
	el.jawnosCloseWaits = null;
	if (waits) {
		for (var i = 0; i < waits.length; i++) {
			try { waits[i](); } catch (e) {}
		}
	}
}

// Play the level's farewell, then tear the window down. Returns false when the
// desk wants no motion, and closeWindow() removes the window at once, as before.
function jawnosWindowCloseEffect(win, done) {
	win = $(win);
	if (!win.length || !jawnosWindowMotionAllowed()) { return false; }
	var el = win[0];
	var level = jawnosWindowEffectsLevel();
	var name = (level === 'light') ? 'close_fade' : ((level === 'maximum') ? 'close_burst' : 'close_crumble');
	var rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
	// a window with no box (already hidden) has nothing to animate; the teardown
	// is the whole motion
	if (!rect || !rect.width || !rect.height) { return false; }
	var shards = null;
	if (name !== 'close_fade' && rect && rect.width && rect.height) {
		shards = jawnosWindowCloseShards(el, rect, level);
	}
	// a hide still waiting on its animation must not fire over the teardown
	jawnosWindowEffectsCancelHide(el);
	jawnosWindowEffectCancel(el);
	var token = {};
	el.jawnosCloseToken = token;
	// a reflow between removing and adding restarts the keyframes
	void el.offsetWidth;
	win.addClass('jawnos_effect_' + name);
	var finish = function(ev) {
		// a child's own animation bubbles; only the window's close ends it
		if (ev && ev.target && ev.target !== el) { return; }
		if (el.jawnosCloseToken !== token) { return; }
		jawnosWindowCloseFinish(el, shards, done);
	};
	el.jawnosCloseEnd = finish;
	el.addEventListener('animationend', finish);
	// the ceiling only matters when the animation never starts; it is longer
	// than every close, and short enough that the bookkeeping barely waits
	el.jawnosCloseTimer = setTimeout(finish, 300);
	return true;
}
