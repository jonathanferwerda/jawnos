function softKbEval(source) {
	var s = String(source).replace(/×/g, '*').replace(/÷/g, '/').replace(/−/g, '-').replace(/\s+/g, '');
	var i = 0;
	function factor() {
		if (s[i] == '+') { i++; return factor(); }
		if (s[i] == '-') { i++; return -factor(); }
		if (s[i] == '(') {
			i++;
			var v = expression();
			if (s[i] != ')') { throw new Error('parenthesis'); }
			i++;
			return v;
		}
		var start = i;
		while (i < s.length && /[0-9.]/.test(s[i])) { i++; }
		if (start == i) { throw new Error('number'); }
		var n = parseFloat(s.slice(start, i));
		if (!isFinite(n)) { throw new Error('number'); }
		while (s[i] == '%') { n = n / 100; i++; }
		return n;
	}
	function term() {
		var v = factor();
		while (s[i] == '*' || s[i] == '/') {
			var op = s[i++];
			var r = factor();
			v = (op == '*') ? v * r : v / r;
		}
		return v;
	}
	function expression() {
		var v = term();
		while (s[i] == '+' || s[i] == '-') {
			var op = s[i++];
			var r = term();
			v = (op == '+') ? v + r : v - r;
		}
		return v;
	}
	var result = expression();
	if (i != s.length) { throw new Error('trailing'); }
	return result;
}

// ---- the magnified key under a finger --------------------------------------
// While a character key is held, a large copy of it rides above the key, the
// way a phone's own keyboard shows what the finger is covering. It lives on the
// body rather than inside the dock so a window's overflow cannot clip it, and it
// is shown only for keys that type a character - a modifier has no letter to
// enlarge.
var jawnSoftMagnify = null;

function softKbMagnifyEl() {
	if (!jawnSoftMagnify) {
		jawnSoftMagnify = $('<div id="soft_kb_magnify" class="soft_kb_magnify" aria-hidden="true"></div>').appendTo('body');
	}
	if (!jawnSoftMagnify.parent().length || !$.contains(document.documentElement, jawnSoftMagnify[0])) {
		jawnSoftMagnify.appendTo('body');
	}
	return jawnSoftMagnify;
}

function softKbMagnifyLabel(b) {
	if (b.attr('data-kb_char') != null) {
		var ch = String(b.attr('data-kb_char'));
		return ch.length ? ch : null;
	}
	var k = b.attr('data-kb_key');
	if (k == null) { return null; }
	// only a key that types something: shift, the arrows, space and the like
	// keep their ordinary pressed look
	if (String(k).length != 1) { return null; }
	// the key's printed face is what the finger is covering (the calculator's
	// ÷ and × are drawn over a different data-kb_key)
	var face = String(b.text() || '').replace(/\s+/g, ' ').trim();
	return face || String(k);
}

// Place the bubble above the key, or below it when the key is near the top of
// the screen, and never off the side of the viewport.
function softKbMagnifyPlace(el, rect) {
	var vw = window.innerWidth || $(window).width() || 0;
	var vh = window.innerHeight || $(window).height() || 0;
	var w = el.outerWidth() || 54;
	var h = el.outerHeight() || 58;
	var cx = rect.left + rect.width / 2;
	var half = w / 2 + 6;
	if (cx < half) { cx = half; }
	if (vw && cx > vw - half) { cx = vw - half; }
	var below = (rect.top - 8 - h) < 6;
	var top = below ? (rect.bottom + 8) : (rect.top - 8);
	if (vh && top > vh - 6) { top = vh - 6; }
	el.toggleClass('soft_kb_magnify_below', below).css({ left: cx + 'px', top: top + 'px' });
}

function softKbMagnifyShow(b) {
	var label = softKbMagnifyLabel(b);
	if (label == null || !b.length || !b[0].getBoundingClientRect) { return; }
	// a key pressed while the dock is still rising would leave the bubble where
	// the key was mid-slide, so this press gets the plain pressed look instead
	if (jawnSoftSlideAt && (Date.now() - jawnSoftSlideAt) < softKbSlideMs()) { return; }
	var el = softKbMagnifyEl();
	var rect = b[0].getBoundingClientRect();
	el.text(label).prop('hidden', false).addClass('on');
	softKbMagnifyPlace(el, rect);
}

function softKbMagnifyHide() {
	if (!jawnSoftMagnify) { return; }
	jawnSoftMagnify.removeClass('on soft_kb_magnify_below').prop('hidden', true);
}

// ---- keys ------------------------------------------------------------------
function softKbKey(k) {
	// The vault's drawer is a field in the page: every key writes there, even
	// the 123 page's digits and operators (a site can need a dot or a slash).
	if (jawnVault.sheet) {
		if (k == 'shift') { softKbShiftSet(!jawnSoftShift); return; }
		if (k == 'backspace') { softKbBackspace(); return; }
		if (k == 'enter') { softKbVaultSheetEnter(); return; }
		if (k == 'space') { softKbInsert(' '); return; }
		if (k && k.length == 1) {
			var layout = softKbLayout();
			softKbInsert((jawnSoftShift && layout.cased !== false) ? softKbUpper(k, layout) : k);
			if (jawnSoftShift) { softKbShiftSet(false); }
		}
		return;
	}
	if (k == 'shift') { softKbShiftSet(!jawnSoftShift); return; }
	if (k == 'backspace') {
		if (jawnSoftMode == 'calc') { softKbCalcKey('backspace'); } else { softKbBackspace(); }
		return;
	}
	if (k == 'enter') { softKbEnter(); return; }
	if (jawnSoftMode == 'calc') { softKbCalcKey(k); return; }
	if (k == 'space') { softKbInsert(' '); return; }
	if (k && k.length) {
		var layout = softKbLayout();
		var out = (jawnSoftShift && layout.cased !== false) ? softKbUpper(k, layout) : k;
		softKbInsert(out);
		if (jawnSoftShift) { softKbShiftSet(false); }
	}
}

function softKbChar(c) {
	if (jawnVault.sheet) { softKbInsert(c); return; }
	if (jawnSoftMode == 'calc') {
		var map = { '×': '*', '÷': '/', '−': '-', '–': '-', '+': '+', '%': '%', '(': '(', ')': ')', '=': '=' };
		if (map[c] != null) { softKbCalcKey(map[c]); }
		else if (c == '±') { softKbCalcKey('sign'); }
		return;
	}
	if ((jawnSoftField || jawnSoftIme) && !jawnSoftNumeric) { softKbInsert(c); }
}

function softKbPress(b) {
	if (b.attr('data-kb_action') == 'vault_fill') { softKbVaultFillOpen(); return; }
	if (b.attr('data-kb_action') == 'vault_save') { softKbVaultSaveOpen(); return; }
	if (b.attr('data-kb_action') == 'vault_close') { softKbVaultClose(); return; }
	if (b.attr('data-kb_action') == 'vault_save_commit') { softKbVaultSaveCommit(); return; }
	if (b.attr('data-kb_vault_fill') != null) { softKbVaultFillOne(b.attr('data-kb_vault_fill')); return; }
	if (b.attr('data-kb_vault_forget') != null) { softKbVaultForget(b.attr('data-kb_vault_forget'), b); return; }
	if (b.attr('data-kb_mode')) { softKbModeSet(b.attr('data-kb_mode')); return; }
	if (b.attr('data-kb_layout')) { softKbLayoutSet(b.attr('data-kb_layout')); return; }
	if (b.attr('data-kb_action') == 'layouts') { softKbLayoutsToggle(); return; }
	if (b.attr('data-kb_action') == 'layouts_close') { softKbLayoutsToggle(false); return; }
	if (b.attr('data-kb_action') == 'dictate') { softKbDictateToggle(); return; }
	if (b.attr('data-kb_action') == 'close') {
		jawnSoftForced = false;
		// the input method's close is Android's own hide, not a slide-down: the
		// service owns the window and re-shows this page on the next field
		if (jawnSoftIme && window.JawnIme && typeof window.JawnIme.hide === 'function') { window.JawnIme.hide(); return; }
		softKbHide();
		return;
	}
	if (b.attr('data-kb_action') == 'clear_history') {
		jawnSoftHistory = [];
		softKbHistorySave();
		softKbHistoryRender();
		return;
	}
	if (b.attr('data-kb_history') != null) { softKbHistoryPick(b.attr('data-kb_history')); return; }
	if (b.attr('data-kb_convert_unit') != null) { softKbConvertPick(b.attr('data-kb_convert_unit'), b.attr('data-kb_convert_value')); return; }
	if (b.attr('data-kb_type') != null) { softKbTypePick(b.attr('data-kb_type'), b.attr('data-kb_type_unit')); return; }
	if (b.attr('data-kb_suggest') != null) { softKbSuggestPick(b.attr('data-kb_suggest')); return; }
	if (b.attr('data-kb_char') != null) { softKbChar(b.attr('data-kb_char')); return; }
	var k = b.attr('data-kb_key');
	if (k == null) { return; }
	softKbKey(k);
}

// A chip in the conversion/history/recommendation row sits inside a sideways
// scroller. It must not act on pointerdown, or a swipe becomes a tap; record
// where the finger landed and act on a release that did not travel.
var jawnSoftChipStart = null;
var jawnSoftChipAt = 0;

$(document).on('pointerdown', '#jawn_soft_keyboard button', function (e) {
	if (e.button != null && e.button != 0) { return; }
	if ($(this).hasClass('soft_kb_convert_item') || $(this).hasClass('soft_kb_history_item') || $(this).hasClass('soft_kb_layout_item')) {
		jawnSoftChipStart = { x: e.clientX, y: e.clientY, el: this };
		return;
	}
	// act on the press and keep the caret in the field
	e.preventDefault();
	jawnSoftKeyAt = Date.now();
	softKbMagnifyShow($(this));
	if ($(this).attr('data-kb_key') == 'backspace') { softKbBackspaceDown(this); return; }
	// any other key puts a hold on backspace away
	softKbRepeatStop();
	softKbPress($(this));
});
$(document).on('pointerup', '#jawn_soft_keyboard button', function (e) {
	if (!jawnSoftChipStart) { return; }
	var start = jawnSoftChipStart;
	jawnSoftChipStart = null;
	if (!$(this).hasClass('soft_kb_convert_item') && !$(this).hasClass('soft_kb_history_item') && !$(this).hasClass('soft_kb_layout_item')) { return; }
	var dx = Math.abs((e.clientX || 0) - start.x);
	var dy = Math.abs((e.clientY || 0) - start.y);
	if (dx > 12 || dy > 12) { jawnSoftChipAt = Date.now(); return; }   // a swipe, not a tap
	e.preventDefault();
	jawnSoftChipAt = Date.now();
	softKbPress($(start.el));
});
$(document).on('pointerup pointercancel', '#jawn_soft_keyboard button', function () {
	softKbMagnifyHide();
	softKbRepeatStop();
});
$(document).on('pointerup pointercancel', function () { softKbMagnifyHide(); if (jawnSoftChipStart) { jawnSoftChipAt = Date.now(); jawnSoftChipStart = null; } softKbRepeatStop(); });
$(window).on('blur', function () { softKbMagnifyHide(); });
$(document).on('click', '#jawn_soft_keyboard button', function () {
	if (Date.now() - jawnSoftKeyAt < 600) { return; }
	if (Date.now() - jawnSoftChipAt < 700) { return; }
	// a long hold can outlive the press guard; its release must not delete again
	if ($(this).attr('data-kb_key') == 'backspace' && Date.now() - jawnSoftHoldAt < 800) { return; }
	softKbPress($(this));
});
$(document).on('pointerdown', '#jawn_soft_keyboard', function (e) {
	// On a desk the calculator is a window of its own: a press anywhere on it
	// takes the keypad back from the field that was being typed in. The letters
	// page keeps the field's focus, which is where its keys type.
	if (jawnSoftMode == 'calc' && softKbDesk() && document.activeElement !== this) {
		try { this.focus({ preventScroll: true }); } catch (err) { this.focus(); }
	}
	// the bar above the keys is the panel's handle: its press must reach the
	// draggable, or cancelling it here stops the panel from ever moving
	if ($(e.target).closest('.soft_kb_bar, button, .soft_kb_convert_rows').length) { return; }
	e.preventDefault();
});

// ---- attaching to fields ---------------------------------------------------
// Sweep the page and every window it adds: the platform keyboard is told to
// stay away before the field can ask for it, not after it has opened.
function softKbSweep(root) {
	if (!softKbOn() || !$('#jawn_soft_keyboard').length) { return; }
	$(root).find('input, textarea, [contenteditable="true"]').addBack('input, textarea, [contenteditable="true"]').each(function () {
		if (softKbEditable(this) && this.getAttribute('data-soft_inputmode') == null) { softKbSuppress(this); }
	});
}
var softKbSweepTimer;
if (window.MutationObserver) {
	new MutationObserver(function () {
		clearTimeout(softKbSweepTimer);
		softKbSweepTimer = setTimeout(function () { softKbSweep(document); }, 150);
	}).observe(document.documentElement, { childList: true, subtree: true });
}
$(function () { softKbSweep(document); });

// ---- selecting text by dragging --------------------------------------------
// A finger dragged across a field selects from where it landed as it moves, so
// the highlight appears at once instead of waiting for the platform's long-press
// handles. Chromium reports the caret inside an input/textarea through
// caretPositionFromPoint; a contenteditable reports its text node.
var jawnTextDrag = null;

function jawnTextSelectable(el) {
	if (!el || el.nodeType != 1 || el.disabled) { return false; }
	if (el.isContentEditable) { return true; }
	var tag = (el.tagName || '').toLowerCase();
	if (tag == 'textarea') { return true; }
	if (tag != 'input') { return false; }
	var type = (el.getAttribute('type') || 'text').toLowerCase();
	return ['text', 'search', 'email', 'url', 'tel', 'password'].indexOf(type) >= 0;
}

function jawnTextCaretAt(x, y) {
	try {
		if (document.caretPositionFromPoint) {
			var p = document.caretPositionFromPoint(x, y);
			if (p && p.offsetNode) { return { node: p.offsetNode, offset: p.offset }; }
		}
		if (document.caretRangeFromPoint) {
			var r = document.caretRangeFromPoint(x, y);
			if (r) { return { node: r.startContainer, offset: r.startOffset }; }
		}
	} catch (err) {}
	return null;
}

function jawnTextOwns(field, node) {
	if (!node) { return false; }
	if (node === field) { return true; }
	return field.contains(node);
}

function jawnTextDragAnchor(d) {
	var el = d.el;
	var a = jawnTextCaretAt(d.x, d.y);
	if (el.isContentEditable) {
		if (a && jawnTextOwns(el, a.node)) { d.anchorNode = a.node; d.anchorOffset = a.offset; return; }
		d.anchorNode = el;
		d.anchorOffset = 0;
		return;
	}
	if (a && a.node === el) { d.anchor = a.offset; return; }
	d.anchor = (el.selectionStart == null) ? 0 : el.selectionStart;
}

function jawnTextDragOffset(d, x, y) {
	var el = d.el;
	var a = jawnTextCaretAt(x, y);
	if (el.isContentEditable) {
		if (a && jawnTextOwns(el, a.node)) { return a; }
		var r = el.getBoundingClientRect();
		var range = document.createRange();
		range.selectNodeContents(el);
		range.collapse(y < r.top || (y <= r.bottom && x < r.left));
		return { node: range.startContainer, offset: range.startOffset };
	}
	if (a && a.node === el) { return { node: el, offset: a.offset }; }
	var rect = el.getBoundingClientRect();
	var before = (y < rect.top) || (y <= rect.bottom && x < rect.left);
	return { node: el, offset: before ? 0 : (el.value || '').length };
}

function jawnTextDragApply(d, x, y) {
	var el = d.el;
	var cur = jawnTextDragOffset(d, x, y);
	if (!cur) { return; }
	if (el.isContentEditable) {
		if (d.anchorNode == null) { return; }
		var sel = window.getSelection ? window.getSelection() : null;
		if (!sel) { return; }
		var range = document.createRange();
		try {
			range.setStart(d.anchorNode, d.anchorOffset);
			range.setEnd(d.anchorNode, d.anchorOffset);
			var probe = document.createRange();
			probe.setStart(cur.node, cur.offset);
			probe.setEnd(cur.node, cur.offset);
			if (range.compareBoundaryPoints(Range.START_TO_START, probe) <= 0) {
				range.setEnd(cur.node, cur.offset);
			}
			else {
				range.setStart(cur.node, cur.offset);
				range.setEnd(d.anchorNode, d.anchorOffset);
			}
		} catch (err) { return; }
		sel.removeAllRanges();
		sel.addRange(range);
		return;
	}
	var a = (d.anchor == null) ? 0 : d.anchor;
	var o = cur.offset;
	try { el.setSelectionRange(Math.min(a, o), Math.max(a, o)); } catch (err) {}
}

$(document).on('pointerdown', 'input, textarea, [contenteditable="true"]', function (e) {
	if (e.pointerType === 'mouse') { return; }
	if (e.isPrimary === false) { return; }
	var el = softKbRoot(this);
	if (!jawnTextSelectable(el)) { return; }
	jawnTextDrag = { el: el, x: e.clientX, y: e.clientY, pointerId: e.pointerId, moved: false, anchor: null, anchorNode: null, anchorOffset: 0 };
});

$(document).on('pointermove', function (e) {
	var d = jawnTextDrag;
	if (!d) { return; }
	if (e.pointerId != null && d.pointerId != null && e.pointerId !== d.pointerId) { return; }
	if (!d.moved) {
		if (Math.abs(e.clientX - d.x) < 6 && Math.abs(e.clientY - d.y) < 6) { return; }
		d.moved = true;
		// the field is focused so the selection is visible, but the dock stays
		// down: this is a selection, not a tap that asks to type
		jawnSoftDragFocus = true;
		try { d.el.focus({ preventScroll: true }); } catch (err) {}
		setTimeout(function () { jawnSoftDragFocus = false; }, 0);
		jawnTextDragAnchor(d);
	}
	e.preventDefault();
	jawnTextDragApply(d, e.clientX, e.clientY);
});

$(document).on('pointerup pointercancel', function (e) {
	var d = jawnTextDrag;
	if (!d) { return; }
	if (e && e.pointerId != null && d.pointerId != null && e.pointerId !== d.pointerId) { return; }
	jawnTextDrag = null;
	// the click that closes a drag ends a selection; it is not a tap on the field
	if (d.moved) {
		jawnSoftDragClick = true;
		setTimeout(function () { jawnSoftDragClick = false; }, 350);
	}
});

document.addEventListener('pointerdown', function (e) {
	var el = e.target;
	if (softKbOn() && (softKbEditable(el) || (el.isContentEditable))) { softKbSuppress(el); }
}, true);
document.addEventListener('touchstart', function (e) {
	var el = e.target;
	// a finger means the phone is back in hand, even if a Bluetooth keyboard was
	// used a moment ago
	if (jawnSoftHardware) { softKbHardwareClear(); }
	if (softKbOn() && (softKbEditable(el) || (el.isContentEditable))) { softKbSuppress(el); }
}, true);

// A key from a real keyboard while the dock holds the input. In calculator mode
// the keypad belongs to the calculator when it has the focus; a field being
// typed in keeps the key (the calculator follows it through the field's input),
// and pressing the calculator takes the keypad back. Returns true when the dock
// took the key.
function softKbHardwareKey(e) {
	if (jawnSoftIme || jawnSoftMode != 'calc') { return false; }
	if (softKbEditable(e.target)) { return false; }
	var key = e.key || '';
	if (!key || e.ctrlKey || e.metaKey || e.altKey) { return false; }
	// a focused on-screen key keeps the Enter that presses it
	if (key == 'Enter' && e.target && e.target.closest && e.target.closest('#jawn_soft_keyboard button')) { return false; }
	var map = { 'Enter': '=', '=': '=', 'Backspace': 'backspace', 'Delete': 'clear', 'Escape': 'clear', ',': '.' };
	if (/^[0-9]$/.test(key) || key == '.') { softKbCalcKey(key); return true; }
	if (key.length == 1 && '+-*/%()'.indexOf(key) >= 0) { softKbCalcKey(key); return true; }
	if (Object.prototype.hasOwnProperty.call(map, key)) { softKbCalcKey(map[key]); return true; }
	return false;
}

// The only honest test for a real keyboard is a real key: the page may not
// enumerate input devices, but a trusted key press is proof enough. It puts the
// dock away at once and keeps it away, so a desk never has to dismiss it twice.
// Modifier-only keys and shortcuts are not typing, and the dock's own buttons
// are not evidence of anything.
document.addEventListener('keydown', function (e) {
	if (!e || e.isTrusted === false) { return; }
	if (e.ctrlKey || e.metaKey || e.altKey) { return; }
	var k = e.key || '';
	if (!k) { return; }
	if (k == 'Escape') { jawnMeasureHide(); }
	if (k == 'Shift' || k == 'Alt' || k == 'Control' || k == 'Meta' || k == 'CapsLock' || k == 'Tab') { return; }
	var target = e.target;
	var on_dock = !!(target && target.closest && target.closest('#jawn_soft_keyboard, #jawn_measure_pop'));
	// The dock was asked for on a desk, and while it is up it holds the input the
	// way a window does: a real key is the field's or the calculator's, never a
	// reason to put it away. A phone with a keyboard keeps the old rule.
	if (softKbVisible() && (jawnSoftSticky || jawnSoftForced) && softKbDesk()) {
		if (softKbHardwareKey(e)) { e.preventDefault(); }
		return;
	}
	// A key pressed while the keys themselves have focus is still the
	// calculator's (a button keeps its own Enter and Space).
	if (on_dock) { return; }
	if (k == 'Escape') { return; }
	softKbHardwareMark();
}, true);

$(document).on('focusin', function (e) {
	var el = e.target;
	if (!softKbOn() || !softKbEditable(el)) { return; }
	softKbSuppress(el);
	// a drag across the field focuses it to show the selection; that focus must
	// not raise the keys, so scrolling or selecting never opens the keyboard
	if (jawnSoftDragFocus) { return; }
	softKbShow(el);
});

$(document).on('click', 'input, textarea, [contenteditable="true"]', function () {
	if (!softKbOn() || !softKbEditable(this)) { return; }
	if (jawnSoftDragClick) { return; }
	softKbShow(this);
});

$(document).on('focusout', function (e) {
	if (!softKbEditable(e.target)) { return; }
	// a desk's dock keeps the input until another field asks for it (or the
	// dock is closed); focusing a window's body or raising another window must
	// not take the keys away
	if (jawnSoftSticky) { return; }
	clearTimeout(jawnSoftHideTimer);
	jawnSoftHideTimer = setTimeout(function () {
		var active = document.activeElement;
		if ($(active).closest('#jawn_soft_keyboard').length) { return; }
		if ($(active).is('#chat_soft_toggle')) { return; }
		if (softKbEditable(active) && softKbOn()) { return; }
		softKbHide();
	}, 260);
});

// A number field typed into from a hardware keyboard keeps the calculator in step.
$(document).on('input', 'input, textarea', function () {
	if (this === jawnSoftField && jawnSoftNumeric && !jawnSoftSetting) {
		jawnSoftExpr = this.value || '';
		$('#soft_kb_expr').text(jawnSoftExpr || '0');
		$('#soft_kb_result').text('');
	}
	if (this === jawnSoftField) {
		softKbConvertUpdate();
		softKbSuggestSync();
		if (!jawnVault.open) { softKbVaultButtons(); softKbVaultSync(); }
	}
});

// The Chat composer's keyboard button asks for the dock; pressing it again puts
// it away. It also turns the dock on for a desk that has not asked for it yet.
$(document).on('click', '#chat_soft_toggle', function () {
	var el = document.getElementById('message');
	if (!el) { return; }
	if (softKbVisible() && jawnSoftField === el) { jawnSoftForced = false; softKbHide(); return; }
	softKbForce();
	try { el.focus({ preventScroll: true }); } catch (err) { el.focus(); }
	softKbShow(el);
});

// Sending must not put the dock away.
$(document).on('click', '#send_it', function () {
	if (!jawnSoftField || jawnSoftField.id != 'message' || !softKbVisible()) { return; }
	setTimeout(function () {
		var el = document.getElementById('message');
		if (!el) { return; }
		try { el.focus({ preventScroll: true }); } catch (err) { el.focus(); }
	}, 0);
});

$(window).on('resize', function () { if (softKbVisible()) { softKbReserve(); } jawnMeasurePlace(); });

// ---- the vault -------------------------------------------------------------
// A saved login or field lives in the manager's `credentials` table, sealed with
// the house key. The bar offers it only for the field in hand: a row with an
// `origin` is that site's, a row without one is that app's. While the house is
// padlocked the server answers `locked` and nothing is offered or saved.
