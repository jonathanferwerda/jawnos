/* [[js-split]]
   universal.js is part 1. The rest live in universal/ in name order:
     01_inventory_time_readings.js - mouse, names, quality inventory, duration and time readings
     02_settings_ajax_hidden.js - fixed times, day processing, setting writes, ajaxSetup, hidden reload
     03_unlock_requests_media_locks.js - unlock confirmations, app-only access, media padlocks
     04_padlock_prompts_approvals.js - padlock prompts, signing, Go approvals, the padlock tick
     05_theme_ink_icon_swap.js - theme ink and the icon set swap
     06_biometric_unlock.js - the device's own biometric key
     07_hints_long_press_multiselect.js - hover/touch hints, long press menus, multi-selects
     08_device_shares_shadow_mode.js - device shares and the shadow-mode page
   Every page loads these through subs::js_script_urls('public/js/universal.js');
   the gate, homepage, public_view, store, music, manager, locked and
   app_required layouts all expand it, and perl/hooks.pl whitelists the whole
   /js/universal/ folder for a sessionless load.
   [[/js-split]] */
var tree = {};
var appointment_chronicler;
var appointment_windows = {};
var errorDotTimeout;
var errorInfo = [];
	// `!signatorial in window` parses as `(!signatorial) in window` and throws on
	// pages that never define it (the public homepage), so use typeof instead
	if (typeof signatorial === 'undefined' || !signatorial) {
		globalThis.signatorial = 'unknown';
	}
	// bti and bt are read by the ajaxSetup below. A layout that loads this file
	// before its own tab stamps (the locked page did) must not abort the whole
	// script here: a ReferenceError would leave every later handler unbound,
	// including the padlock's fingerprint button.
	if (typeof bti === 'undefined') { globalThis.bti = ''; }
	if (typeof bt === 'undefined') { globalThis.bt = ''; }

// The repaint work (the appointment chrons, the calculators, the little
// animations) only matters while the page is really being looked at. A hidden
// tab is the usual case; a fullscreen video is the other, and document.hidden
// stays false there - without this the chrons and the appointment poll keep
// churning behind the picture. Anything that must keep the app connected or
// aware (the websocket, the alarms, a recording in progress) must NOT be gated
// on this.
function jawn_resting() {
	return document.hidden || !!document.fullscreenElement || !!document.webkitFullscreenElement;
}
var jawn_was_resting = jawn_resting();
function jawn_rest_change() {
	var resting = jawn_resting();
	if (jawn_was_resting && !resting) {
		// back on screen: paint the chrons at once, and let the calculator resync
		// the view it stopped polling while it was covered
		appointment_chron();
		if (typeof calculator == 'function') { calculator(); }
	}
	jawn_was_resting = resting;
}
document.addEventListener('fullscreenchange', jawn_rest_change);
document.addEventListener('webkitfullscreenchange', jawn_rest_change);

$(document).ready(function() {
	appointment_chron();
});

$(document).on('keyup click change input', 'textarea, .text-editor', function() {
	var ta = $(this);
	var el = ta[0];
	if (el && el.tagName == 'TEXTAREA') {
		if (ta.val() == '') {
			ta.height(30);
			if (typeof chatKeepPinned === 'function') { chatKeepPinned(); }
			return;
		}
		// Grow only by the overflow. scrollHeight and clientHeight both count the
		// padding, so their difference is the real content overflow; the old pass
		// set the box's height to scrollHeight and so added the padding again on
		// every keyup, which is what made the box crawl open.
		var overflow = el.scrollHeight - el.clientHeight;
		if (overflow <= 1) { return; }
		var style = window.getComputedStyle(el);
		var pad = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
		var target;
		if (style.boxSizing == 'border-box') {
			target = el.getBoundingClientRect().height + overflow;
		}
		else {
			target = (parseFloat(style.height) || (el.clientHeight - pad)) + overflow;
		}
		var max = parseFloat(style.maxHeight);
		if (!isNaN(max) && max > 0) { target = Math.min(target, max); }
		el.style.height = target + 'px';
		// the Chat thread follows its composer: a growing box must not swallow
		// the newest bubbles
		if (typeof chatKeepPinned === 'function') { chatKeepPinned(); }
		return;
	}
	var scrollHeight = el.scrollHeight;
	var height = ta.height();
	if (scrollHeight > (height + 5) || scrollHeight < (height - 5)) {
		if (scrollHeight < 700) {
			ta.height(scrollHeight);
		}
	}
	if (ta.val() == '') {
		ta.height(30);
	}
});


// Everything that paints time shares one second tick. The appointment clocks
// and the duration readouts used to run two separate 1 Hz intervals, each
// walking its own DOM; a page with both paid twice. A hidden page (or one
// covered by a fullscreen video) paints nothing.
var jawnos_tick_jobs = {};
function jawnos_tick_register(name, fn) {
	jawnos_tick_jobs[name] = fn;
	if (!appointment_chronicler) {
		appointment_chronicler = setInterval(function(){
			if (jawn_resting()) { return; }
			for (var key in jawnos_tick_jobs) {
				try { jawnos_tick_jobs[key](); } catch (e) {}
			}
		},1000);
	}
}

// The 1 Hz walk reads every .since/.time on the page. Wrapping each one, and
// climbing to its window for the display's saved preference, is the expensive
// part - and a clock does not move between ticks. Do that once and keep the
// list until the page's nodes change, so an idle second touches only the text
// that actually moved.
var jawnosChronNodes = null;
function jawnosChronDirty() { jawnosChronNodes = null; }
function jawnosChronNodeList() {
	if (jawnosChronNodes) { return jawnosChronNodes; }
	var nodes = [];
	$('.since, .time').each(function(i, el) {
		var j = $(el);
		nodes.push({ j: j, app: j.closest('.wind').attr('app') || '' });
	});
	jawnosChronNodes = nodes;
	return nodes;
}
(function jawnosChronWatch() {
	if (typeof MutationObserver !== 'function' || typeof document === 'undefined') { return; }
	var observer = new MutationObserver(function(mutations) {
		for (var m = 0; m < mutations.length; m++) {
			var lists = [mutations[m].addedNodes, mutations[m].removedNodes];
			for (var l = 0; l < lists.length; l++) {
				for (var n = 0; n < lists[l].length; n++) {
					// a clock rewriting its own text adds a text node, not a clock
					if (lists[l][n].nodeType === 1) { jawnosChronNodes = null; return; }
				}
			}
		}
	});
	var watch = function() {
		if (document.body) { observer.observe(document.body, { childList: true, subtree: true }); }
	};
	if (document.readyState == 'loading') { document.addEventListener('DOMContentLoaded', watch); }
	else { watch(); }
})();

function appointment_chron() {
	jawnosChronDirty();
	time_updater();
	// durations share the same tick; give them a pass here too so a freshly
	// loaded details panel wears its saved reading at once
	if (typeof jawnosDurationTick === 'function') { jawnosDurationTick(); }
	jawnos_tick_register('time', time_updater);
	function time_updater() {
		var now = Date.now();
		var nodes = jawnosChronNodeList();
		for (var n = 0; n < nodes.length; n++) {
			var header = nodes[n].j;
			if (!header[0]) { continue; }
			var mode = header.attr('mode');
			var timestamp = header.attr('timestamp');
			var display = nodes[n].app;
			var saved_mode = timeDisplaySaved(display);
			if (saved_mode == 'dynamic' || saved_mode == 'hours' || saved_mode == 'minutes' || saved_mode == 'fixed') {
				mode = saved_mode;
				header.attr('mode', saved_mode);
			}

			if (mode == 'fixed') {
				// Fixed times never change, so paint one and skip the element for a
				// while. Clicking the element drops next_check, so the toggle back to
				// fixed paints straight away instead of waiting out this hour.
				var next_check = numeral(header.attr('next_check')).value();
				if (next_check && next_check > now) { continue; }
				if (!header.attr('formatted_time')) {
					header.attr('formatted_time', fixedTimeString(numeral(timestamp).value()));
				}
				if (header.is('input') && !header.hasClass('editing')) {
					header.val(header.attr('formatted_time')).css({'background-color': 'var(--time-fixed)'});
				}
				else if (header.hasClass('editing')) {
					header.css({'background-color': 'var(--time-fixed)'})
				}
				else {
					header.text(header.attr('formatted_time'));
				}
				header.attr('next_check', now + 3600000);
			}
			else if (mode == 'hours' || mode == 'minutes') {
				// The same span read in one unit: 130h 10m, or 7810m 22s.
				var unit_text = mode == 'hours' ? quality_inventory_hours(timestamp) : quality_inventory_minutes(timestamp);
				if (header.is('input') && !header.hasClass('editing')) {
					if (header.val() != unit_text) { header.val(unit_text).css({'background-color': ''}); }
				}
				else if (header.hasClass('editing')) {
					header.css({'background-color': ''});
					continue;
				}
				else {
					if (header.text() != unit_text) { header.text(unit_text); }
				}
				header.attr('mode', mode);
			}
			else {
				// Dynamic times read "in 3m 12s" or "3d 4h ago", so they are worked out
				// every second -- the DOM is only touched when the text really changed.
				if (header.is('input') && !header.hasClass('editing')) {
					var value = quality_inventory(timestamp);
					if (header.val() != value) { header.val(value).css({'background-color': ''}); }
				}
				else if (header.hasClass('editing')) {
					header.css({'background-color': ''});
					header.attr('mode', 'dynamic');
					// while typing, keep repainting so it settles as soon as they stop
					continue;
				}
				else {
					var text = quality_inventory(timestamp);
					if (header.text() != text) { header.text(text); }
				}
				header.attr('mode', 'dynamic');
			}

		}
	}
}

