// ---- icon hints: hover label on desktop, long-press label on touch ------------
// Any element with a `hint="..."` attribute shows a small floating label when
// hovered (pointer devices) or long-pressed (touch). Draggable elements are
// skipped on touch so a long press can start a drag instead.
var jawnos_hint_timer = null;
var jawnos_touch_hint_active = false;
function jawnosHintNode() {
	var h = document.getElementById('jawnos_hint');
	if (!h) {
		h = document.createElement('div');
		h.id = 'jawnos_hint';
		h.style.cssText = 'position:fixed;display:none;z-index:90000;background:rgba(0,0,0,0.86);color:#fff;padding:3px 8px;border-radius:6px;font-size:13px;line-height:1.3;max-width:260px;pointer-events:none;box-shadow:0 1px 4px rgba(0,0,0,0.4);white-space:nowrap;';
		document.body.appendChild(h);
	}
	return h;
}
function jawnosHintShow(el, x, y, gap) {
	var hint = $(el).attr('hint');
	var topic = $(el).attr('help');
	// An element may carry a short label (hint), a help topic (help), or both.
	// When a topic is present the label says so, and F1 opens the full entry.
	var text = hint || '';
	if (topic) { text = text ? (text + ' \u00b7 F1') : 'Help \u00b7 F1'; }
	if (!text) { return; }
	if (gap == null) { gap = 12; }
	var h = jawnosHintNode();
	h.textContent = text;
	h.style.display = 'block';
	var w = h.offsetWidth, hh = h.offsetHeight;
	if (x == null) {
		var o = $(el).offset() || { left: 0, top: 0 };
		x = o.left + ($(el).width() / 2);
		y = o.top;
	}
	var left = Math.max(4, Math.min(x - (w / 2), $(window).width() - w - 4));
	var top = y - hh - gap;
	if (top < 4) { top = y + gap + 16; }
	h.style.left = left + 'px';
	h.style.top = top + 'px';
}
function jawnosHintHide() {
	var h = document.getElementById('jawnos_hint');
	if (h) { h.style.display = 'none'; }
}
var jawnos_click_killer = null;
var jawnos_killer_timer = null;
// how near the press a click has to land to be the press's own; a fingertip's
// worth of drift covers the lag between the finger and the browser's click
var jawnos_click_slop = 30;
// for a moment after a long press, throw away the click the browser is about to
// deliver, so reading a hint does not also press the thing underneath it. Only
// a click at the press is thrown away: that is where the press's own delayed
// click lands, while a later tap elsewhere - a row on the timeline, say - keeps
// its click even when it falls inside the moment. A press that names no point
// keeps the old whole-page hold, since there is nothing to measure against.
function jawnosSuppressClick(x, y) {
	jawnosUnsuppressClick();
	jawnos_click_killer = function (e) {
		if (x != undefined && (Math.abs(e.clientX - x) > jawnos_click_slop || Math.abs(e.clientY - y) > jawnos_click_slop)) { return; }
		e.stopPropagation();
		e.preventDefault();
		jawnosUnsuppressClick();
	};
	document.addEventListener('click', jawnos_click_killer, true);
	jawnos_killer_timer = setTimeout(jawnosUnsuppressClick, 700);
}
function jawnosUnsuppressClick() {
	if (jawnos_click_killer) {
		document.removeEventListener('click', jawnos_click_killer, true);
		jawnos_click_killer = null;
	}
	clearTimeout(jawnos_killer_timer);
	jawnos_killer_timer = null;
}

var jawnos_hover_capable = true;
try { jawnos_hover_capable = window.matchMedia('(hover: hover)').matches; } catch (e) {}

if (jawnos_hover_capable) {
	$(document).on('mouseenter', '[hint], [help]', function () {
		if (jawnos_touch_hint_active) { return; }
		var el = this;
		clearTimeout(jawnos_hint_timer);
		// wait before showing so the label doesn't flash on every pass
		jawnos_hint_timer = setTimeout(function () {
			var m = mouse_position();
			jawnosHintShow(el, m.x, m.y);
		}, 1000);
	});
	$(document).on('mouseleave', '[hint], [help]', function () {
		clearTimeout(jawnos_hint_timer);
		jawnosHintHide();
	});
	$(document).on('mousedown', function () { clearTimeout(jawnos_hint_timer); jawnosHintHide(); });
}

$(document).on('touchstart', '[hint], [help]', function (e) {
	var el = this;
	if ($(el).hasClass('draggable') || $(el).closest('.draggable').length > 0) { return; }
	// where a context menu is registered the hold belongs to it, not the hint
	if (typeof jawnosHasContextMenu == 'function' && jawnosHasContextMenu(el)) { return; }
	// the start menu rows wear their name already; a long press there must not
	// swallow the tap that would open the app
	if ($(el).closest('.start_menu_item').length > 0) { return; }
	// a fresh press owns its click, whatever the last long press left behind
	jawnosUnsuppressClick();
	var touch = e.originalEvent.touches && e.originalEvent.touches[0];
	if (!touch) { return; }
	var tx = touch.clientX, ty = touch.clientY;
	clearTimeout(jawnos_hint_timer);
	jawnos_hint_timer = setTimeout(function () {
		jawnos_touch_hint_active = true;
		jawnosHintShow(el, tx, ty, 30);
		jawnosSuppressClick(tx, ty);
	}, 500);
});
$(document).on('touchend touchcancel', function () {
	clearTimeout(jawnos_hint_timer);
	if (jawnos_touch_hint_active) {
		setTimeout(function () { jawnosHintHide(); jawnos_touch_hint_active = false; }, 1200);
	}
});
$(document).on('touchmove', function () {
	if (!jawnos_touch_hint_active) { clearTimeout(jawnos_hint_timer); }
});

// ---- long press opens the context menus on touch --------------------------
// A hold on a registered surface dispatches the very contextmenu event the right
// button raises on a desk, at the finger, so every handler that answers a
// right-click answers a hold too. The hint's own long press stands down on those
// surfaces (see jawnosHasContextMenu above), so a menu and a label never race.
var jawnos_context_selectors = [];
var jawnos_context_timer = null;
function jawnosContextMenuOn(selector) {
	if (jawnos_context_selectors.indexOf(selector) < 0) { jawnos_context_selectors.push(selector); }
}
function jawnosHasContextMenu(el) {
	for (var i = 0; i < jawnos_context_selectors.length; i++) {
		if ($(el).closest(jawnos_context_selectors[i]).length) { return true; }
	}
	return false;
}
$(document).on('touchstart', function (e) {
	for (var i = 0; i < jawnos_context_selectors.length; i++) {
		if (!$(e.target).closest(jawnos_context_selectors[i]).length) { continue; }
		var t = e.originalEvent.touches && e.originalEvent.touches[0];
		if (!t) { return; }
		var target = e.target;
		var x = t.clientX, y = t.clientY;
		clearTimeout(jawnos_context_timer);
		jawnos_context_timer = setTimeout(function () {
			jawnosHintHide();
			jawnos_touch_hint_active = false;
			jawnosSuppressClick(x, y);
			target.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2 }));
		}, 550);
		return;
	}
});
$(document).on('touchend touchcancel touchmove', function () {
	clearTimeout(jawnos_context_timer);
});

// ---- multi-selects, the phone way -------------------------------------------
// A <select multiple> is a tall list that eats the page. It is painted as a
// compact trigger instead, and opened in a popup whose options are toggles -
// the way a phone shows a multi picker. The real select stays behind the
// trigger (kept, only hidden), so every existing change handler still fires.
(function () {
	if (window.jawnos_multiselect_installed) { return; }
	window.jawnos_multiselect_installed = true;
	var css = document.createElement('style');
	css.textContent = [
		'.ms-native { position:absolute !important; width:1px !important; height:1px !important; opacity:0 !important; pointer-events:none !important; left:-9999px !important; }',
		'.ms-trigger { font:inherit; text-align:left; cursor:pointer; padding:3px 24px 3px 8px; border:1px solid var(--line, rgba(0,0,0,.35)); border-radius:5px; background:var(--panel, #fff); color:var(--ink, #111); position:relative; max-width:280px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; vertical-align:top; }',
		'.ms-trigger:after { content:"\\25be"; position:absolute; right:8px; top:50%; transform:translateY(-50%); opacity:.55; }',
		'.ms-popup { position:fixed; z-index:100000; background:var(--panel, #fff); color:var(--ink, #111); border:1px solid var(--line, rgba(0,0,0,.4)); border-radius:8px; box-shadow:0 12px 44px rgba(0,0,0,.35); display:flex; flex-direction:column; min-width:200px; max-width:min(420px,92vw); }',
		'.ms-head { padding:9px 14px; font-weight:700; border-bottom:1px solid var(--line, rgba(0,0,0,.15)); }',
		'.ms-body { overflow:auto; padding:6px 0; }',
		'.ms-option { display:flex; align-items:center; gap:10px; padding:8px 14px; cursor:pointer; white-space:nowrap; }',
		'.ms-option:hover { background:var(--panel-2, rgba(0,0,0,.06)); }',
		'.ms-option input { width:18px; height:18px; accent-color:var(--accent, #0d47a1); }',
		'.ms-foot { border-top:1px solid var(--line, rgba(0,0,0,.15)); padding:6px 12px; text-align:right; }',
		'.ms-foot button { font:inherit; padding:4px 18px; border-radius:5px; border:1px solid var(--line, rgba(0,0,0,.3)); background:var(--panel-2, #f2f2f2); color:var(--ink, #111); cursor:pointer; }'
	].join('\n');
	document.head.appendChild(css);
})();
function multiselectSummary(sel) {
	var chosen = $(sel).find('option:selected').map(function () { return $.trim($(this).text()); }).get();
	chosen = chosen.filter(function (t) { return t.length; });
	if (!chosen.length) { return 'none'; }
	if (chosen.length <= 2) { return chosen.join(', '); }
	return chosen.length + ' selected';
}
function multiselectPaint(sel) {
	$(sel).siblings('.ms-trigger').first().text(multiselectSummary(sel));
}
function multiselectUpgrade(root) {
	$(root || document.body).find('select[multiple]').each(function () {
		var s = $(this);
		if (s.data('ms')) { return; }
		s.data('ms', 1);
		s.addClass('ms-native').before('<button type="button" class="ms-trigger"></button>');
		s.on('change', function () { multiselectPaint(this); });
		multiselectPaint(this);
	});
}
var ms_current, ms_current_sel;
function multiselectClose() {
	if (ms_current) { ms_current.remove(); ms_current = null; ms_current_sel = null; }
}
function multiselectOpen(sel) {
	multiselectClose();
	var s = $(sel);
	if (!s.length) { return; }
	var pop = $('<div class="ms-popup"></div>');
	pop.append($('<div class="ms-head"></div>').text(s.attr('hint') || s.attr('name') || 'Choose'));
	var body = $('<div class="ms-body"></div>');
	s.find('option').each(function () {
		var o = $(this);
		var cb = $('<input type="checkbox">').prop('checked', o.is(':selected'));
		cb.on('change', function () { o.prop('selected', this.checked); s.trigger('change'); });
		body.append($('<label class="ms-option"></label>').append(cb).append($('<span></span>').text(o.text() || '(none)')));
	});
	pop.append(body);
	pop.append($('<div class="ms-foot"><button type="button" class="ms-done">Done</button></div>'));
	$('body').append(pop);
	var maxH = Math.min(window.innerHeight * 0.72, 500);
	pop.css({ 'max-height': maxH + 'px' });
	body.css({ 'max-height': (maxH - 92) + 'px' });
	var t = s.siblings('.ms-trigger').first();
	var r = (t.length ? t[0] : s[0]).getBoundingClientRect();
	var left = Math.min(r.left, window.innerWidth - pop.outerWidth() - 8);
	if (left < 8) { left = 8; }
	var top = r.bottom + 4;
	if (top + pop.outerHeight() > window.innerHeight && r.top - pop.outerHeight() - 4 > 0) { top = r.top - pop.outerHeight() - 4; }
	if (top < 8) { top = 8; }
	pop.css({ left: left + 'px', top: top + 'px' });
	pop.find('.ms-done').on('click', function (e) { e.preventDefault(); multiselectClose(); });
	ms_current = pop;
	ms_current_sel = s;
}
$(document).on('click', '.ms-trigger', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var sel = $(this).siblings('select[multiple]').first();
	// pressing the same trigger again puts the picker away
	if (ms_current && ms_current_sel && ms_current_sel.is(sel)) { multiselectClose(); return; }
	multiselectOpen(sel);
});
$(document).on('click', function (e) {
	if (!ms_current) { return; }
	if ($(e.target).closest('.ms-popup, .ms-trigger').length) { return; }
	multiselectClose();
});
$(document).on('keydown', function (e) {
	if (e.key === 'Escape') { multiselectClose(); }
});
// upgrade the selects already on the page and any a window brings in later; the
// sweep is debounced because the house re-renders a lot
var ms_sweep;
function multiselectSweep() {
	clearTimeout(ms_sweep);
	ms_sweep = setTimeout(function () { multiselectUpgrade(document.body); }, 120);
}
$(document).ready(function () { multiselectUpgrade(document.body); });
new MutationObserver(multiselectSweep).observe(document.documentElement, { childList: true, subtree: true });

// Fatal JavaScript errors report themselves to the error watch (the same
// staging area the tree's own log feeds), so the Coding agent can propose a
// fix. Only uncaught things are sent - an uncaught exception, an unhandled
// promise rejection, a script or stylesheet that would not load - because
// those are the fatal ones; console chatter is not. Each fault reports once
// and then at most every ten minutes, carrying the count it has reached; an
// extension's own errors and the browser's blank cross-origin "Script error."
// are ignored. Reporting must never be the thing that breaks the page, so the
// whole thing is wrapped and quiet.
(function () {
	if (window.jawnosJSErrorsReady) { return; }
	window.jawnosJSErrorsReady = true;
	var sent = {};      // signature -> when it was last sent
	var counts = {};    // signature -> times seen since that send
	var RESEND_MS = 10 * 60 * 1000;
	function report(message, source, line, column, stack) {
		try {
			message = String(message == null ? 'Unknown error' : message).slice(0, 500);
			source = String(source || '').slice(0, 500);
			stack = String(stack || '').slice(0, 2000);
			if (/^(?:chrome|moz|safari|edge)-extension:/.test(source)) { return; }
			if (/^Script error\.?$/.test(message)) { return; }
			var key = message + '|' + source + '|' + (line || 0);
			var now = Date.now();
			counts[key] = (counts[key] || 0) + 1;
			if (sent[key] && (now - sent[key]) < RESEND_MS) { return; }
			var count = counts[key];
			counts[key] = 0;
			sent[key] = now;
			var payload = JSON.stringify({
				page: location.pathname + location.hash,
				message: message,
				source: source,
				line: line || 0,
				column: column || 0,
				stack: stack,
				count: count,
				agent: navigator.userAgent
			});
			if (navigator.sendBeacon) {
				navigator.sendBeacon('/manager/js_error', new Blob([payload], { type: 'application/json' }));
			}
			else {
				var xhr = new XMLHttpRequest();
				xhr.open('POST', '/manager/js_error', true);
				xhr.setRequestHeader('Content-Type', 'application/json');
				xhr.send(payload);
			}
		}
		catch (e) { /* reporting must never be the error */ }
	}
	window.addEventListener('error', function (e) {
		if (e.target && e.target !== window && e.target.tagName) {
			var t = e.target.tagName;
			if (t === 'SCRIPT' || t === 'LINK') {
				var href = e.target.src || e.target.href || '';
				report('failed to load ' + t.toLowerCase() + ': ' + href, href, 0, 0, '');
			}
			return;
		}
		var err = e.error || {};
		report(e.message, e.filename, e.lineno, e.colno, err.stack || '');
	}, true);
	window.addEventListener('unhandledrejection', function (e) {
		var r = e.reason || {};
		var msg = (r && r.message) ? r.message : (typeof r === 'string' ? r : 'unknown reason');
		report('Unhandled promise rejection: ' + msg, '', 0, 0, (r && r.stack) || '');
	});
})();

