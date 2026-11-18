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
var jawnosWindowEffectClasses = 'jawnos_effect_stretch jawnos_effect_in jawnos_effect_out jawnos_effect_lock jawnos_effect_snap jawnos_effect_jiggle';

function jawnosWindowPhysicsCancel(win) {
	var el = $(win)[0];
	if (!el) { return; }
	var state = el.jawnosWobble;
	if (state && state.raf && typeof cancelAnimationFrame == 'function') { cancelAnimationFrame(state.raf); }
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
	if (transform) {
		el.style.transform = transform;
	}
	else if (!state.dragging) {
		el.style.transform = '';
		$(el).removeClass('jawnos_wobbling');
		state.raf = 0;
		el.jawnosWobble = null;
		return;
	}
	else {
		el.style.transform = '';
	}
	state.raf = requestAnimationFrame(function() { jawnosWindowWobbleFrame(el); });
}

function jawnosWindowWobbleStart(win) {
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
	jawnosWindowEffectsCancelHide(win);
	jawnosWindowEffect(win, 'out');
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
	jawnosWindowEffectsCancelHide(win);
	if (!jawnosWindowEffectsOn()) { return; }
	jawnosWindowEffect(win, 'in');
}
