// Window effects: the desk's own memory of a compositor. A window leans while it
// is dragged, stretches into a half or the whole screen, bounces as it leaves or
// comes back, and gives a small kick when it is pinned. Every effect is a
// transient CSS transform on .wind (see manager.css), so layout, the saved
// geometry and the drag maths never see it. The whole set is one Misc setting,
// window_effects, seeded into jawnos_bar_settings; a still desk is a legitimate
// choice, and a device can keep one.

function jawnosWindowEffectsOn() {
	return !(typeof jawnos_bar_settings != 'undefined' && jawnos_bar_settings
		&& jawnos_bar_settings['window_effects'] === 'off');
}

// The panel's change handler calls this as soon as the switch moves, so a desk
// whose effects were just turned off does not keep an old animation running.
function jawnosWindowEffectsSet(value) {
	if (typeof jawnos_bar_settings == 'undefined' || !jawnos_bar_settings) { return; }
	jawnos_bar_settings['window_effects'] = (value === 'off') ? 'off' : 'on';
	if (jawnosWindowEffectsOn()) { return; }
	$('.wind').each(function() {
		// a hide already in flight still has to finish: turning the effects off
		// must not leave a "minimised" window on the desk
		if (this.jawnosHideEnd) { this.jawnosHideEnd(); }
		jawnosWindowEffectCancel(this);
	});
}

// The class names live in one place so a new effect cannot leave another one
// behind when it starts.
var jawnosWindowEffectClasses = 'jawnos_effect_wobble jawnos_effect_settle jawnos_effect_stretch jawnos_effect_in jawnos_effect_out jawnos_effect_lock';

function jawnosWindowEffectCancel(win) {
	var el = $(win)[0];
	if (!el) { return; }
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

// The lean while the title bar is in the hand. It is the one effect that runs
// until told to stop, so it is kept out of the one-shot timer above.
function jawnosWindowWobbleStart(win) {
	win = $(win);
	if (!win.length || !jawnosWindowEffectsOn()) { return; }
	jawnosWindowEffectCancel(win);
	win.addClass('jawnos_effect_wobble');
}

function jawnosWindowWobbleStop(win) {
	win = $(win);
	if (!win.length) { return; }
	win.removeClass('jawnos_effect_wobble');
	jawnosWindowEffect(win, 'settle');
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
