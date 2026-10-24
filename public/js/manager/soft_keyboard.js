// The JawnOS on-screen keyboard.
//
// One dock serves every editable field in the manager: letters, a calculator for
// number fields, and a page of special characters. It suppresses the platform
// keyboard with inputmode="none", so the viewport never changes shape. On a phone
// it is the default; a desk keeps its hardware keyboard until the Chat keyboard
// button asks for the dock.
//
// Placement: inside the Chat composer it is an ordinary block (the composer makes
// room for it); inside another window it rides the window's foot; outside a
// window it is fixed above the taskbar. The focused field is scrolled clear of it.

var jawnSoftField = null;
var jawnSoftMode = 'letters';
var jawnSoftShift = false;
var jawnSoftNumeric = false;
var jawnSoftContext = '';
var jawnSoftExpr = '';
var jawnSoftSetting = false;
var jawnSoftKeyAt = 0;
var jawnSoftHideTimer = null;

function softKbOn() {
	var stored = localStorage.getItem('jawn_soft_keyboard');
	if (stored == 'off') { return false; }
	if (stored == 'on') { return true; }
	if (typeof windowPhoneChecker == 'function') { return windowPhoneChecker(); }
	return /Android|iPhone|iPad|iPod|Tablet|Mobile/i.test(navigator.userAgent || '');
}

function softKbRoot(el) {
	if (!el) { return null; }
	if (el.isContentEditable) { return el.closest('[contenteditable]') || el; }
	return el;
}

function softKbEditable(el) {
	if (!el || el.nodeType != 1) { return false; }
	if (el.disabled || el.readOnly) { return false; }
	if (el.getAttribute('data-soft_keyboard') == 'off') { return false; }
	if (el.isContentEditable) { return true; }
	var tag = el.tagName.toLowerCase();
	if (tag == 'textarea') { return true; }
	if (tag != 'input') { return false; }
	var type = (el.getAttribute('type') || 'text').toLowerCase();
	return ['text', 'search', 'email', 'url', 'password', 'tel', 'number'].indexOf(type) >= 0;
}

function softKbNumeric(el) {
	if (!el) { return false; }
	var type = (el.getAttribute('type') || '').toLowerCase();
	var mode = (el.getAttribute('inputmode') || el.getAttribute('data-soft_inputmode') || '').toLowerCase();
	return type == 'number' || mode == 'numeric' || mode == 'decimal';
}

function softKbSuppress(el) {
	el = softKbRoot(el);
	if (!el || el.getAttribute('data-soft_inputmode') != null) { return; }
	el.setAttribute('data-soft_inputmode', el.getAttribute('inputmode') || '');
	el.setAttribute('inputmode', 'none');
	if (el.isContentEditable) { el.setAttribute('virtualkeyboardpolicy', 'manual'); }
}

function softKbRestore(el) {
	el = softKbRoot(el);
	if (!el) { return; }
	var prior = el.getAttribute('data-soft_inputmode');
	if (prior != null) {
		if (prior) { el.setAttribute('inputmode', prior); }
		else { el.removeAttribute('inputmode'); }
		el.removeAttribute('data-soft_inputmode');
	}
	if (el.isContentEditable) { el.removeAttribute('virtualkeyboardpolicy'); }
}

function softKbLabel(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// What kind of field the dock is typing into. The class, name and placeholder
// are the house's own conventions ("ago", "duration", "warranty", "schedule",
// "notes"), and a `time` input is a timestamp written in words. The answer
// decides both the recommendation row and whether a typed "5m" is minutes or
// metres.
function softKbContext(el) {
	if (!el) { return ''; }
	if ((el.getAttribute('type') || '').toLowerCase() == 'password') { return 'password'; }
	var raw = [
		el.id,
		el.getAttribute('name'),
		el.getAttribute('placeholder'),
		el.getAttribute('text'),
		el.getAttribute('attribute'),
		el.getAttribute('hint'),
		el.getAttribute('data-context'),
		el.className
	].join(' ').toLowerCase();
	var tokens = raw.split(/[^a-z0-9]+/);
	var has = function (t) { return tokens.indexOf(t) >= 0; };
	if (has('duration')) { return 'duration'; }
	if (has('warranty')) { return 'warranty'; }
	if (has('schedule')) { return 'schedule'; }
	if (has('timestamp') || has('ago') || has('time')) { return 'when'; }
	if (has('notes') || has('note')) { return 'notes'; }
	if (el.id == 'message' || $(el).closest('.chat_shell').length) { return 'chat'; }
	if (softKbNumeric(el)) { return 'number'; }
	return 'text';
}

function softKbShow(el) {
	if (!softKbOn()) { return; }
	el = softKbRoot(el);
	if (!softKbEditable(el)) { return; }
	var dock = $('#jawn_soft_keyboard');
	if (!dock.length) { return; }
	var changed = jawnSoftField !== el;
	jawnSoftField = el;
	jawnSoftNumeric = softKbNumeric(el);
	jawnSoftContext = softKbContext(el);
	if (changed) {
		jawnSoftExpr = jawnSoftNumeric ? (el.value || '') : '';
		softKbShiftSet(false);
	}
	softKbSuppress(el);
	softKbPlace(el);
	dock.prop('hidden', false).attr('aria-hidden', 'false');
	// the search itself rises above the keys; the bar it lives in (dock or
	// taskbar) keeps whatever mode it was in
	var search_field = el.id == 'search' || $(el).closest('#search_entanglement').length > 0;
	$('body').toggleClass('soft_kb_search_field', search_field);
	$('.soft_kb_search_lifted').removeClass('soft_kb_search_lifted');
	if (search_field) { $(el).closest('#search_entanglement').addClass('soft_kb_search_lifted'); }
	$('body').addClass('soft_kb_open');
	softKbModeSet(jawnSoftNumeric ? 'calc' : 'letters');
	softKbSuggestSync();
	softKbReserve();
	softKbScrollField(el);
	// the search dropdown is measured against the keyboard while the keys are up
	setTimeout(function () {
		if (typeof jawnosSearchResultsPlace === 'function') { jawnosSearchResultsPlace(); }
	}, 20);
	var chat = el.id == 'message';
	$('#chat_soft_toggle').toggleClass('active', chat).attr('aria-expanded', chat ? 'true' : 'false');
}

function softKbHide() {
	softKbRepeatStop();
	$('#jawn_soft_keyboard').prop('hidden', true).attr('aria-hidden', 'true');
	$('body').removeClass('soft_kb_open soft_kb_dock_field soft_kb_bar_field soft_kb_search_field');
	$('.soft_kb_search_lifted').removeClass('soft_kb_search_lifted');
	$('.chat_shell').css('padding-bottom', '');
	$('.soft_kb_reserved').css('padding-bottom', '').removeClass('soft_kb_reserved');
	softKbConvertHide();
	$('#soft_kb_suggest').prop('hidden', true);
	jawnSoftContext = '';
	jawnSoftField = null;
	if (typeof jawnosSearchResultsPlace === 'function') { setTimeout(jawnosSearchResultsPlace, 0); }
	$('#chat_soft_toggle').removeClass('active').attr('aria-expanded', 'false');
}

function softKbVisible() {
	return $('#jawn_soft_keyboard').is(':visible');
}

function softKbPlace(el) {
	var dock = $('#jawn_soft_keyboard');
	// The dock always lives in the body: a window that re-renders or closes
	// cannot take the keyboard with it.
	if (!dock.parent().is('body')) { $('body').append(dock); }
	dock.removeClass('soft_kb_in_window soft_kb_inline');
}

// Keep the field's own scrolling area above the keys: the Chat shell gives up
// the overlap at its foot, and an appointment (or any other window) gives it up
// in its scroll area, so its lower fields and buttons stay reachable. The window
// itself keeps its shape.
function softKbReserve() {
	$('.chat_shell').css('padding-bottom', '');
	$('.soft_kb_reserved').css('padding-bottom', '').removeClass('soft_kb_reserved');
	var dock = $('#jawn_soft_keyboard');
	if (!dock.is(':visible') || !jawnSoftField) { return; }
	// the dock and taskbar rules lift themselves by this much
	if (document.body && document.body.style) {
		document.body.style.setProperty('--soft_kb_h', (dock.outerHeight() || 0) + 'px');
	}
	// the search dropdown lives in the space above the keys, and the keys just
	// changed height
	if (typeof jawnosSearchResultsPlace === 'function') { jawnosSearchResultsPlace(); }
	var chat = $(jawnSoftField).closest('.chat_shell');
	var scroller = chat.length ? chat : $(jawnSoftField).closest('.appointment_contents, .window_contents');
	if (!scroller.length) { return; }
	if (!chat.length && !scroller.closest('.wind').length) { return; }
	var dockTop = dock[0].getBoundingClientRect().top;
	var box = scroller[0].getBoundingClientRect();
	var bottom = Math.min(box.bottom, window.innerHeight);
	var overlap = Math.max(0, bottom - dockTop);
	if (overlap <= 0) { return; }
	if (chat.length) { chat.css('padding-bottom', overlap + 'px'); }
	else { scroller.addClass('soft_kb_reserved').css('padding-bottom', overlap + 'px'); }
}

function softKbScrollField(el) {
	if (!el) { return; }
	if (el.id == 'message' && $(el).closest('.chat_shell').length) { return; }
	setTimeout(function () {
		var dock = $('#jawn_soft_keyboard');
		if (!dock.is(':visible')) { return; }
		var h = dock.outerHeight() || 0;
		el.style.scrollMarginBottom = (h + 18) + 'px';
		el.style.scrollMarginTop = '18px';
		try { el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' }); }
		catch (err) { el.scrollIntoView(); }
	}, 30);
}

function softKbModeSet(mode) {
	if (jawnSoftNumeric && mode == 'letters') { mode = 'calc'; }
	jawnSoftMode = mode;
	var dock = $('#jawn_soft_keyboard');
	dock.find('.soft_kb_mode').removeClass('active').filter('[data-kb_mode="' + mode + '"]').addClass('active');
	dock.find('.soft_kb_panel').prop('hidden', true).filter('[data-kb_panel="' + mode + '"]').prop('hidden', false);
	dock.find('.soft_kb_title').text(mode == 'calc' ? softKbLabel('Calculator') : (mode == 'symbols' ? softKbLabel('Special characters') : softKbLabel('Keyboard')));
	dock.find('.soft_kb_mode[data-kb_mode="letters"]').prop('hidden', jawnSoftNumeric);
	if (mode == 'calc') { softKbCalcRender(); softKbHistoryRender(); }
	softKbConvertUpdate();
	softKbReserve();
	if (jawnSoftField) { softKbScrollField(jawnSoftField); }
}

function softKbShiftSet(on) {
	jawnSoftShift = !!on;
	$('#jawn_soft_keyboard .soft_kb_letter').each(function () {
		var k = $(this).attr('data-kb_key') || '';
		$(this).text(jawnSoftShift ? k.toUpperCase() : k);
	});
	$('#jawn_soft_keyboard .soft_kb_key[data-kb_key="shift"]').toggleClass('active', jawnSoftShift);
}

function softKbNotify(el) {
	if (!el) { return; }
	var fire = function () {
		$(el).trigger('input');
		// older fields listen on keyup rather than input (the search box, the
		// text editor); a harmless space code keeps their handlers in step
		$(el).trigger($.Event('keyup', { key: ' ', keyCode: 32 }));
		if (!el.isContentEditable) { return; }
		// The house's rich text editor keeps a source textarea beside its
		// contenteditable; copy the words across so the app's own save sees them.
		var source = el.getAttribute('source_id');
		if (source && $('#' + source).length) {
			$('#' + source).val($(el).text());
			$('#' + source).trigger('change');
		}
	};
	if (window.requestAnimationFrame) { requestAnimationFrame(fire); }
	else { setTimeout(fire, 0); }
	softKbConvertUpdate();
	softKbSuggestSync();
}

function softKbInsert(text) {
	var el = jawnSoftField;
	if (!el) { return; }
	if (el.isContentEditable) {
		el.focus({ preventScroll: true });
		var ok = false;
		try {
			ok = (text == '\n')
				? document.execCommand('insertHTML', false, '<br>')
				: document.execCommand('insertText', false, text);
		} catch (err) { ok = false; }
		if (!ok) {
			var sel = window.getSelection();
			if (sel && sel.rangeCount) {
				var range = sel.getRangeAt(0);
				range.deleteContents();
				var node = document.createTextNode(text);
				range.insertNode(node);
				range.setStartAfter(node);
				range.collapse(true);
				sel.removeAllRanges();
				sel.addRange(range);
			}
		}
		softKbNotify(el);
		return;
	}
	var start = (el.selectionStart == null) ? el.value.length : el.selectionStart;
	var end = (el.selectionEnd == null) ? start : el.selectionEnd;
	try { el.setRangeText(text, start, end, 'end'); }
	catch (err) {
		el.value = el.value.slice(0, start) + text + el.value.slice(end);
		el.selectionStart = el.selectionEnd = start + text.length;
	}
	try { el.focus({ preventScroll: true }); } catch (err2) { el.focus(); }
	softKbNotify(el);
}

function softKbBackspace() {
	var el = jawnSoftField;
	if (!el) { return; }
	if (el.isContentEditable) {
		el.focus({ preventScroll: true });
		try { document.execCommand('delete'); } catch (err) {}
		softKbNotify(el);
		return;
	}
	var start = (el.selectionStart == null) ? el.value.length : el.selectionStart;
	var end = (el.selectionEnd == null) ? start : el.selectionEnd;
	if (start == end) {
		if (start == 0) { return; }
		var code = el.value.charCodeAt(start - 1);
		if (code >= 0xDC00 && code <= 0xDFFF && start >= 2) {
			var high = el.value.charCodeAt(start - 2);
			start = (high >= 0xD800 && high <= 0xDBFF) ? start - 2 : start - 1;
		}
		else { start--; }
	}
	try { el.setRangeText('', start, end, 'end'); }
	catch (err) {
		el.value = el.value.slice(0, start) + el.value.slice(end);
		el.selectionStart = el.selectionEnd = start;
	}
	try { el.focus({ preventScroll: true }); } catch (err2) { el.focus(); }
	softKbNotify(el);
}

// ---- hold-to-repeat ---------------------------------------------------------
// A held backspace eats whole words after a short wait. A double-tap and hold
// repeats characters like a normal key, then climbs to a sentence at three
// seconds and clears the field at six. The calculator repeats its expression one
// character at a time (there are no words in a sum).
var JAWN_SOFT_HOLD_DELAY = 450;
var JAWN_SOFT_WORD_EVERY = 240;
var JAWN_SOFT_CHAR_EVERY = 60;
var JAWN_SOFT_SENTENCE_AT = 3000;
var JAWN_SOFT_WHOLE_AT = 6000;
var JAWN_SOFT_DOUBLE = 380;
var jawnSoftHold = null;
var jawnSoftHoldAt = 0;
var jawnSoftBackspaceAt = 0;

function softKbDeleteSpan(el, start, end) {
	if (!el || start == null || end == null || start >= end) { return; }
	try { el.setRangeText('', start, end, 'end'); }
	catch (err) {
		el.value = el.value.slice(0, start) + el.value.slice(end);
		el.selectionStart = el.selectionEnd = start;
	}
	try { el.focus({ preventScroll: true }); } catch (err2) { el.focus(); }
	softKbNotify(el);
}

// backward to the start of the previous word, trailing spaces included
function softKbDeleteWord() {
	var el = jawnSoftField;
	if (!el) { return; }
	if (el.isContentEditable) { softKbDeleteGranularity('word'); return; }
	var v = el.value || '';
	var end = (el.selectionStart == null) ? v.length : el.selectionStart;
	var start = (el.selectionEnd == null) ? end : el.selectionEnd;
	if (start != end) { softKbDeleteSpan(el, start, end); return; }
	var i = end;
	while (i > 0 && /\s/.test(v.charAt(i - 1))) { i--; }
	while (i > 0 && !/\s/.test(v.charAt(i - 1))) { i--; }
	softKbDeleteSpan(el, i, end);
}

// backward to the previous sentence end (. ! ? or a blank line)
function softKbDeleteSentence() {
	var el = jawnSoftField;
	if (!el) { return; }
	if (el.isContentEditable) { softKbDeleteGranularity('sentence'); return; }
	var v = el.value || '';
	var end = (el.selectionStart == null) ? v.length : el.selectionStart;
	var start = (el.selectionEnd == null) ? end : el.selectionEnd;
	if (start != end) { softKbDeleteSpan(el, start, end); return; }
	if (end == 0) { return; }
	var i = end;
	while (i > 0 && /\s/.test(v.charAt(i - 1))) { i--; }
	while (i > 0) {
		var c = v.charAt(i - 1);
		i--;
		if (c == '.' || c == '!' || c == '?') { break; }
		if (c == '\n' && i > 0 && v.charAt(i - 1) == '\n') { i--; break; }
	}
	softKbDeleteSpan(el, i, end);
}

function softKbDeleteAll() {
	var el = jawnSoftField;
	if (!el) { return; }
	if (el.isContentEditable) {
		try { el.focus({ preventScroll: true }); } catch (err) {}
		try {
			var range = document.createRange();
			range.selectNodeContents(el);
			var sel = window.getSelection();
			sel.removeAllRanges();
			sel.addRange(range);
			document.execCommand('delete');
		} catch (err2) { try { document.execCommand('delete'); } catch (err3) {} }
		softKbNotify(el);
		return;
	}
	el.value = '';
	el.selectionStart = el.selectionEnd = 0;
	try { el.focus({ preventScroll: true }); } catch (err4) {}
	softKbNotify(el);
}

// contenteditable: let the selection walk back by a word/sentence, then delete
function softKbDeleteGranularity(gran) {
	var el = jawnSoftField;
	if (!el) { return; }
	try { el.focus({ preventScroll: true }); } catch (err) {}
	var sel = window.getSelection ? window.getSelection() : null;
	if (sel && sel.rangeCount) {
		try { sel.modify('extend', 'backward', gran); }
		catch (err2) { sel = null; }
		if (sel) {
			try { document.execCommand('delete'); } catch (err3) {}
			softKbNotify(el);
			return;
		}
	}
	try { document.execCommand('delete'); } catch (err4) {}
	softKbNotify(el);
}

function softKbRepeatStop() {
	if (!jawnSoftHold) { return; }
	clearTimeout(jawnSoftHold.timer);
	clearInterval(jawnSoftHold.interval);
	clearTimeout(jawnSoftHold.sentence);
	clearTimeout(jawnSoftHold.whole);
	jawnSoftHold = null;
	jawnSoftHoldAt = Date.now();
}

function softKbRepeatBegin() {
	var hold = jawnSoftHold;
	if (!hold) { return; }
	if (!jawnSoftField) { softKbRepeatStop(); return; }
	if (hold.mode == 'calc') {
		hold.interval = setInterval(function () {
			if (!jawnSoftField) { softKbRepeatStop(); return; }
			softKbCalcKey('backspace');
		}, JAWN_SOFT_CHAR_EVERY);
		return;
	}
	if (hold.mode == 'word') {
		hold.interval = setInterval(function () {
			if (!jawnSoftField) { softKbRepeatStop(); return; }
			softKbDeleteWord();
		}, JAWN_SOFT_WORD_EVERY);
		return;
	}
	// double-tap hold: characters first, then sentences, then the whole field
	hold.interval = setInterval(function () {
		if (!jawnSoftField) { softKbRepeatStop(); return; }
		softKbBackspace();
	}, JAWN_SOFT_CHAR_EVERY);
	hold.sentence = setTimeout(function () {
		if (!jawnSoftHold) { return; }
		clearInterval(jawnSoftHold.interval);
		jawnSoftHold.interval = setInterval(function () {
			if (!jawnSoftField) { softKbRepeatStop(); return; }
			softKbDeleteSentence();
		}, 400);
	}, JAWN_SOFT_SENTENCE_AT - JAWN_SOFT_HOLD_DELAY);
	hold.whole = setTimeout(function () {
		if (!jawnSoftHold) { return; }
		softKbRepeatStop();
		softKbDeleteAll();
	}, JAWN_SOFT_WHOLE_AT - JAWN_SOFT_HOLD_DELAY);
}

// The backspace press itself still deletes at once; the hold is armed behind it.
function softKbBackspaceOnce() {
	if (jawnSoftMode == 'calc') { softKbCalcKey('backspace'); }
	else { softKbBackspace(); }
}

function softKbBackspaceDown(el) {
	var now = Date.now();
	var double = (now - jawnSoftBackspaceAt) < JAWN_SOFT_DOUBLE;
	jawnSoftBackspaceAt = now;
	softKbRepeatStop();
	softKbBackspaceOnce();
	if (!jawnSoftField) { return; }
	jawnSoftHold = {
		mode: (jawnSoftMode == 'calc') ? 'calc' : (double ? 'fast' : 'word'),
		started: now,
		timer: null, interval: null, sentence: null, whole: null
	};
	jawnSoftHold.timer = setTimeout(function () { softKbRepeatBegin(); }, JAWN_SOFT_HOLD_DELAY);
}

function softKbEnter() {
	var el = jawnSoftField;
	if (jawnSoftMode == 'calc') { softKbCalcEquals(); return; }
	if (!el) { return; }
	if (el.tagName == 'TEXTAREA' || el.isContentEditable) { softKbInsert('\n'); return; }
	$(el).trigger($.Event('keydown', { key: 'Enter', keyCode: 13, which: 13 }));
	$(el).trigger($.Event('keyup', { key: 'Enter', keyCode: 13, which: 13 }));
}

// ---- calculator ------------------------------------------------------------
function softKbCalcKey(k) {
	if (k == '=') { softKbCalcEquals(); softKbConvertUpdate(); return; }
	if (k == 'clear') { jawnSoftExpr = ''; softKbCalcRender(); softKbCalcSyncNumeric(); softKbConvertUpdate(); return; }
	if (k == 'backspace') { jawnSoftExpr = jawnSoftExpr.slice(0, -1); softKbCalcRender(); softKbCalcSyncNumeric(); softKbConvertUpdate(); return; }
	if (k == 'sign') {
		var m = jawnSoftExpr.match(/(\d*\.?\d+)$/);
		if (m) {
			var at = jawnSoftExpr.length - m[1].length;
			jawnSoftExpr = jawnSoftExpr.slice(0, at) + (m[1].charAt(0) == '-' ? m[1].slice(1) : '-' + m[1]);
			softKbCalcRender();
			softKbCalcSyncNumeric();
			softKbConvertUpdate();
		}
		return;
	}
	if (/^[0-9.]$/.test(k) || ['+', '-', '*', '/', '(', ')', '%'].indexOf(k) >= 0) {
		jawnSoftExpr += k;
		softKbCalcRender();
		softKbCalcSyncNumeric();
		softKbConvertUpdate();
	}
}

// A number field mirrors the operand currently being typed, not the whole
// expression (a number input cannot hold '+' or '('). Backspace therefore edits
// the field as well as the calculator screen.
function softKbCalcSyncNumeric() {
	if (!jawnSoftNumeric || !jawnSoftField) { return; }
	var m = jawnSoftExpr.match(/(-?\d*\.?\d*)$/);
	var value = m ? m[1] : '';
	if (value == '-' || value == '.') { value = ''; }
	if (/\.$/.test(value)) { value = value.slice(0, -1); }
	jawnSoftSetting = true;
	jawnSoftField.value = value;
	$(jawnSoftField).trigger('input');
	$(jawnSoftField).trigger($.Event('keyup', { key: ' ', keyCode: 32 }));
	jawnSoftSetting = false;
}

function softKbCalcRender() {
	$('#soft_kb_expr').text(jawnSoftExpr || '0');
	$('#soft_kb_result').text('');
}

function softKbCalcEquals() {
	var expr = jawnSoftExpr.trim();
	if (!expr) { return; }
	var value = null;
	try { value = softKbEval(expr); } catch (err) { value = null; }
	if (value == null || !isFinite(value)) {
		$('#soft_kb_result').text(softKbLabel('Error'));
		return;
	}
	var out = softKbFormat(value);
	jawnSoftExpr = out;
	$('#soft_kb_expr').text(out);
	$('#soft_kb_result').text('');
	softKbHistoryAdd(expr, out);
	if (jawnSoftNumeric && jawnSoftField) {
		jawnSoftSetting = true;
		jawnSoftField.value = out;
		try { jawnSoftField.focus({ preventScroll: true }); } catch (err) { jawnSoftField.focus(); }
		$(jawnSoftField).trigger('input');
		$(jawnSoftField).trigger('change');
		jawnSoftSetting = false;
	}
	else { softKbInsert(out); }
}

// ---- the running list of calculations and conversions ----------------------
// Kept in localStorage so the sums a person works out survive a reload. A chip
// carries the result back into the field; the newest sum sits first.
var jawnSoftHistory = null;

function softKbHistoryLoad() {
	if (jawnSoftHistory) { return jawnSoftHistory; }
	var list = [];
	try {
		var raw = localStorage.getItem('jawn_soft_calc_history');
		var parsed = raw ? JSON.parse(raw) : null;
		if (parsed && parsed.length) {
			for (var i = 0; i < parsed.length; i++) {
				var item = parsed[i];
				if (item && typeof item.expr == 'string' && typeof item.out == 'string') { list.push({ expr: item.expr, out: item.out }); }
			}
		}
	} catch (err) { list = []; }
	if (list.length > 30) { list.length = 30; }
	jawnSoftHistory = list;
	return jawnSoftHistory;
}

function softKbHistorySave() {
	try { localStorage.setItem('jawn_soft_calc_history', JSON.stringify(jawnSoftHistory || [])); } catch (err) {}
}

function softKbHistoryAdd(expr, out) {
	expr = (expr || '').trim();
	if (!expr || !out || expr == out) { return; }
	var list = softKbHistoryLoad().filter(function (item) { return item.expr != expr; });
	list.unshift({ expr: expr, out: out });
	if (list.length > 30) { list.length = 30; }
	jawnSoftHistory = list;
	softKbHistorySave();
	softKbHistoryRender();
}

function softKbHistoryRender() {
	var box = $('#soft_kb_history');
	if (!box.length) { return; }
	var list = softKbHistoryLoad();
	var wrap = $('#soft_kb_history_wrap');
	box.empty();
	if (!list.length) { wrap.prop('hidden', true); return; }
	for (var i = 0; i < list.length; i++) {
		var label = list[i].expr + ' = ' + list[i].out;
		$('<button type="button" class="soft_kb_history_item"></button>')
			.attr({ 'data-kb_history': list[i].out, title: label, 'aria-label': label })
			.text(label)
			.appendTo(box);
	}
	wrap.prop('hidden', false);
}

function softKbHistoryPick(out) {
	if (!out) { return; }
	if (jawnSoftNumeric && jawnSoftField) {
		jawnSoftExpr = out;
		softKbCalcRender();
		softKbCalcSyncNumeric();
		try { jawnSoftField.focus({ preventScroll: true }); } catch (err) {}
		return;
	}
	if (jawnSoftMode == 'calc') {
		jawnSoftExpr = out;
		softKbCalcRender();
	}
	softKbInsert(out);
}

// ---- the units a typed quantity converts to --------------------------------
// A quantity typed as "$32.31", "5jpy" or "32.33L" names its unit; every other
// unit of the same kind is offered in a row under the display. The last unit
// used is remembered, so a bare number keeps converting without typing "usd"
// again. The server answers from the same registry the old calculator used.
var jawnSoftUnit = null;
var jawnSoftUnits = null;
var jawnSoftSymbols = null;
var jawnSoftBase = null;
var jawnSoftTypes = null;
var jawnSoftType = '';
var jawnSoftUse = null;
var jawnSoftConvertTimer = null;
var jawnSoftConvertSeq = 0;
var JAWN_SOFT_CONVERT_MAX = 12;

function softKbUnitsLoad() {
	if (jawnSoftUnits) { return jawnSoftUnits; }
	jawnSoftUnits = {};
	jawnSoftSymbols = {};
	jawnSoftTypes = [];
	var el = document.getElementById('soft_kb_units');
	if (el) {
		try {
			var data = JSON.parse(el.textContent || el.innerHTML || '{}');
			jawnSoftUnits = data.units || {};
			jawnSoftSymbols = data.symbols || {};
			jawnSoftBase = data.base || null;
			jawnSoftTypes = data.types || [];
		} catch (err) {}
	}
	return jawnSoftUnits;
}

function softKbTypeLabel(key) {
	var labels = {
		currency: 'Currency', weight: 'Weight', volume: 'Volume', distance: 'Distance',
		temperature: 'Temperature', speed: 'Speed', power: 'Power', resistance: 'Resistance'
	};
	return softKbLabel(labels[key] || key);
}

// How often each target unit has been used: the row puts the most-used first.
function softKbUseLoad() {
	if (jawnSoftUse) { return jawnSoftUse; }
	jawnSoftUse = {};
	try {
		var raw = localStorage.getItem('jawn_soft_convert_use');
		var parsed = raw ? JSON.parse(raw) : null;
		if (parsed && typeof parsed == 'object') { jawnSoftUse = parsed; }
	} catch (err) { jawnSoftUse = {}; }
	return jawnSoftUse;
}

function softKbUseAdd(unit) {
	if (!unit) { return; }
	var use = softKbUseLoad();
	use[unit] = (Number(use[unit]) || 0) + 1;
	try { localStorage.setItem('jawn_soft_convert_use', JSON.stringify(use)); } catch (err) {}
}

function softKbUnitCode(raw) {
	var units = softKbUnitsLoad();
	if (!raw) { return null; }
	if (units[raw]) { return raw; }
	if (units[raw.toUpperCase()]) { return raw.toUpperCase(); }
	if (units[raw.toLowerCase()]) { return raw.toLowerCase(); }
	var low = String(raw).toLowerCase();
	for (var k in units) {
		var u = units[k] || {};
		if (u.name && String(u.name).toLowerCase() == low) { return k; }
		if (u.plural && String(u.plural).toLowerCase() == low) { return k; }
	}
	if (low.length > 3 && /s$/.test(low)) { return softKbUnitCode(low.slice(0, -1)); }
	return null;
}

function softKbNumber(text) {
	var n = parseFloat(String(text || '').replace(/,/g, ''));
	return isFinite(n) ? n : null;
}

// The last quantity in the text: a number followed by a code, or a currency
// symbol followed by a number. A bare number falls back to the remembered unit
// only in the calculator, so composing a message is not turned into money.
function softKbConvertParse(text) {
	softKbUnitsLoad();
	text = String(text || '');
	var best = null;
	var re = /(-?\d[\d,]*(?:\.\d+)?)([A-Za-z]{1,6})/g;
	var m;
	while ((m = re.exec(text))) {
		if (/[A-Za-z]/.test(text.charAt(re.lastIndex))) { continue; }
		var code = softKbUnitCode(m[2]);
		var value = softKbNumber(m[1]);
		if (!code || value == null) { continue; }
		best = { value: value, unit: code, at: m.index };
	}
	var sre = /([$€£¥₹₽₩₺₿Ξ₳ŁÐ◎])\s*(-?\d[\d,]*(?:\.\d+)?)/g;
	while ((m = sre.exec(text))) {
		var sym = (jawnSoftSymbols || {})[m[1]];
		var v = softKbNumber(m[2]);
		if (!sym || v == null) { continue; }
		if (!best || m.index >= best.at) { best = { value: v, unit: sym, at: m.index }; }
	}
	if (best) { return best; }
	if (jawnSoftMode == 'calc' && jawnSoftUnit) {
		var tm = text.match(/(-?\d[\d,]*(?:\.\d+)?)\s*$/);
		if (tm) {
			var n = softKbNumber(tm[1]);
			if (n != null) { return { value: n, unit: jawnSoftUnit, at: tm.index, sticky: true }; }
		}
	}
	return null;
}

function softKbConvertText() {
	var el = jawnSoftField;
	if (el && (el.getAttribute('type') || '').toLowerCase() == 'password') { return ''; }
	if (jawnSoftMode == 'calc') { return jawnSoftExpr || ''; }
	if (!el) { return ''; }
	return el.isContentEditable ? $(el).text() : (el.value || '');
}

function softKbConvertHide() {
	clearTimeout(jawnSoftConvertTimer);
	jawnSoftConvertSeq++;
	var wrap = $('#soft_kb_convert');
	var types = $('#soft_kb_types');
	var shown = false;
	if (wrap.length && !wrap.prop('hidden')) { wrap.prop('hidden', true); shown = true; }
	if (types.length && !types.prop('hidden')) { types.prop('hidden', true); shown = true; }
	if (shown) { softKbReserve(); }
}

function softKbConvertUpdate() {
	if (!$('#jawn_soft_keyboard').is(':visible')) { return; }
	// a time, a length, a warranty or a repeat already names its own units;
	// "5m" there is five minutes and must not be read as metres
	if (jawnSoftContext == 'when' || jawnSoftContext == 'duration' || jawnSoftContext == 'warranty' || jawnSoftContext == 'schedule' || jawnSoftContext == 'password') {
		softKbConvertHide();
		return;
	}
	var hit = softKbConvertParse(softKbConvertText());
	if (!hit) { softKbConvertHide(); return; }
	jawnSoftUnit = hit.unit;
	try { localStorage.setItem('jawn_soft_calc_unit', hit.unit); } catch (err) {}
	var seq = ++jawnSoftConvertSeq;
	clearTimeout(jawnSoftConvertTimer);
	jawnSoftConvertTimer = setTimeout(function () {
		$.get('/manager/keyboard/convert', { unit: hit.unit, value: hit.value }, function (r) {
			if (seq != jawnSoftConvertSeq) { return; }
			if (!r || !r.ok || !r.rows || !r.rows.length) { softKbConvertHide(); return; }
			softKbConvertRender(r);
		}, 'json').fail(function () {
			if (seq == jawnSoftConvertSeq) { softKbConvertHide(); }
		});
	}, 260);
}

function softKbConvertRender(r) {
	var wrap = $('#soft_kb_convert');
	if (!wrap.length) { return; }
	softKbUnitsLoad();
	jawnSoftType = r.type ? (r.type == 'mass' ? 'weight' : r.type) : jawnSoftType;
	// the kinds of measure, the active one wearing the highlight
	var typeWrap = $('#soft_kb_types');
	if (typeWrap.length && jawnSoftTypes && jawnSoftTypes.length) {
		var types = $('#soft_kb_types_rows').empty();
		for (var t = 0; t < jawnSoftTypes.length; t++) {
			var ty = jawnSoftTypes[t] || {};
			if (!ty.key) { continue; }
			var chip = $('<button type="button" class="soft_kb_convert_item soft_kb_type_item"></button>')
				.attr({ 'data-kb_type': ty.key, 'data-kb_type_unit': ty.unit || '', 'aria-label': softKbTypeLabel(ty.key) })
				.text(softKbTypeLabel(ty.key));
			if (ty.key == jawnSoftType) { chip.addClass('active'); }
			chip.appendTo(types);
		}
		typeWrap.prop('hidden', false);
	}
	$('#soft_kb_convert_src').text(r.text || (r.value + ' ' + r.unit));
	// the units used most first, then the registry's own order
	var use = softKbUseLoad();
	var rows = (r.rows || []).slice(0);
	rows.sort(function (a, b) { return (Number(use[b.unit]) || 0) - (Number(use[a.unit]) || 0); });
	if (rows.length > JAWN_SOFT_CONVERT_MAX) { rows.length = JAWN_SOFT_CONVERT_MAX; }
	var box = $('#soft_kb_convert_rows').empty();
	for (var i = 0; i < rows.length; i++) {
		var row = rows[i];
		$('<button type="button" class="soft_kb_convert_item"></button>')
			.attr({
				'data-kb_convert_unit': row.unit,
				'data-kb_convert_value': row.value,
				title: (row.name || row.unit),
				'aria-label': (row.text || '') + ' ' + (row.name || '')
			})
			.text(row.text || (row.value + ' ' + row.unit))
			.appendTo(box);
	}
	wrap.prop('hidden', false);
	softKbReserve();
}

// Choosing a kind converts from the unit last used for that kind (or the kind's
// own representative), so the row changes without retyping a unit.
function softKbTypePick(type, unit) {
	if (!type) { return; }
	var src = unit;
	try { src = localStorage.getItem('jawn_soft_unit_' + type) || unit; } catch (err) {}
	if (!src) { return; }
	jawnSoftUnit = src;
	jawnSoftType = type;
	try { localStorage.setItem('jawn_soft_calc_unit', src); } catch (err) {}
	softKbConvertUpdate();
}

// Tapping a conversion uses its answer: a number field takes it as the value,
// and it becomes the remembered unit so the next number converts from there.
function softKbConvertPick(unit, value) {
	value = softKbNumber(value);
	if (unit) {
		jawnSoftUnit = unit;
		softKbUseAdd(unit);
		try {
			localStorage.setItem('jawn_soft_calc_unit', unit);
			if (jawnSoftType) { localStorage.setItem('jawn_soft_unit_' + jawnSoftType, unit); }
		} catch (err) {}
	}
	if (value == null) { return; }
	if (jawnSoftNumeric && jawnSoftField) {
		jawnSoftExpr = String(value);
		softKbCalcRender();
		softKbCalcSyncNumeric();
		try { jawnSoftField.focus({ preventScroll: true }); } catch (err) {}
		softKbConvertUpdate();
		return;
	}
	if (jawnSoftMode == 'calc') {
		jawnSoftExpr = String(value);
		softKbCalcRender();
	}
	softKbInsert(String(value));
	softKbConvertUpdate();
}

// ---- what the field is asking for ------------------------------------------
// The row names the kind of value the field wants. A tap writes the whole value
// (instead of appending it) because these fields hold one answer, and the value
// goes through input/keyup/change so the app saves it the way typing would.
var jawnSoftSuggestDefs = {
	when: {
		label: 'Time',
		items: ['now', '5m', '15m', '1h', '4h', '1d', '1w', '1M', 'yesterday', 'today', 'tomorrow', 'in 1h', 'in 1d']
	},
	duration: {
		label: 'Duration',
		items: ['5m', '15m', '30m', '1h', '2h', '4h', '8h', '1d', '1w']
	},
	warranty: {
		label: 'Warranty',
		items: ['-1d', '-1w', '-1M', '-3M', '-6M', '-1y', '-2y', '-5y', '-10y']
	},
	schedule: {
		label: 'Repeat',
		items: ['once', '1d', '1w', '1M', '1y', '1d for -2w', '1w for -8w']
	}
};

function softKbSuggestText() {
	var el = jawnSoftField;
	if (!el) { return ''; }
	return el.isContentEditable ? $(el).text() : (el.value || '');
}

// A number already typed steers the row: 5 in a time field offers 5s, 5m, 5h,
// 5d, 5w, 5M and 5y, in a duration 5m through 5y, and a warranty takes them
// negative. The fixed chips follow, without repeats.
function softKbSuggestItems(def) {
	var items = [];
	var found = String(softKbSuggestText() || '').match(/\d+(?:\.\d+)?/g);
	var n = found ? found[found.length - 1] : '';
	if (n) {
		var units = (jawnSoftContext == 'when') ? ['s', 'm', 'h', 'd', 'w', 'M', 'y'] : ['m', 'h', 'd', 'w', 'M', 'y'];
		for (var i = 0; i < units.length; i++) {
			var v = n + units[i];
			if (jawnSoftContext == 'warranty') { v = '-' + v; }
			items.push(v);
		}
	}
	for (var j = 0; j < def.items.length; j++) {
		if (items.indexOf(def.items[j]) < 0) { items.push(def.items[j]); }
	}
	return items;
}

function softKbSuggestSync() {
	var wrap = $('#soft_kb_suggest');
	var def = jawnSoftSuggestDefs[jawnSoftContext];
	if (!def || !jawnSoftField) {
		if (wrap.length && !wrap.prop('hidden')) { wrap.prop('hidden', true); softKbReserve(); }
		return;
	}
	var was = wrap.prop('hidden');
	$('#soft_kb_suggest_label').text(softKbLabel(def.label));
	var items = softKbSuggestItems(def);
	var rows = $('#soft_kb_suggest_rows').empty();
	for (var i = 0; i < items.length; i++) {
		$('<button type="button" class="soft_kb_convert_item"></button>')
			.attr({ 'data-kb_suggest': items[i], 'aria-label': items[i] })
			.text(items[i])
			.appendTo(rows);
	}
	wrap.prop('hidden', false);
	if (was) { softKbReserve(); }
}

function softKbSuggestPick(value) {
	var el = jawnSoftField;
	if (!el || value == null) { return; }
	if (el.isContentEditable) { softKbInsert(value); return; }
	el.value = value;
	try { el.focus({ preventScroll: true }); el.setSelectionRange(value.length, value.length); } catch (err) {}
	softKbNotify(el);
	$(el).trigger('change');
	softKbConvertUpdate();
	softKbSuggestSync();
}

function softKbFormat(value) {
	var out = String(Math.round(value * 1e12) / 1e12);
	if (out.indexOf('e') >= 0 || out.length > 18) { out = String(parseFloat(value.toPrecision(12))); }
	return out;
}

// A small recursive-descent evaluation: + - * /, parentheses, unary signs and a
// postfix percent. No eval, and anything outside that grammar is refused.
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

// ---- keys ------------------------------------------------------------------
function softKbKey(k) {
	if (k == 'shift') { softKbShiftSet(!jawnSoftShift); return; }
	if (k == 'backspace') {
		if (jawnSoftMode == 'calc') { softKbCalcKey('backspace'); } else { softKbBackspace(); }
		return;
	}
	if (k == 'enter') { softKbEnter(); return; }
	if (jawnSoftMode == 'calc') { softKbCalcKey(k); return; }
	if (k == 'space') { softKbInsert(' '); return; }
	if (k.length == 1) {
		softKbInsert(jawnSoftShift ? k.toUpperCase() : k);
		if (jawnSoftShift) { softKbShiftSet(false); }
	}
}

function softKbChar(c) {
	if (jawnSoftMode == 'calc') {
		var map = { '×': '*', '÷': '/', '−': '-', '–': '-', '+': '+', '%': '%', '(': '(', ')': ')', '=': '=' };
		if (map[c] != null) { softKbCalcKey(map[c]); }
		else if (c == '±') { softKbCalcKey('sign'); }
		return;
	}
	if (jawnSoftField && !jawnSoftNumeric) { softKbInsert(c); }
}

function softKbPress(b) {
	if (b.attr('data-kb_mode')) { softKbModeSet(b.attr('data-kb_mode')); return; }
	if (b.attr('data-kb_action') == 'close') { softKbHide(); return; }
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
	if ($(this).hasClass('soft_kb_convert_item') || $(this).hasClass('soft_kb_history_item')) {
		jawnSoftChipStart = { x: e.clientX, y: e.clientY, el: this };
		return;
	}
	// act on the press and keep the caret in the field
	e.preventDefault();
	jawnSoftKeyAt = Date.now();
	if ($(this).attr('data-kb_key') == 'backspace') { softKbBackspaceDown(this); return; }
	// any other key puts a hold on backspace away
	softKbRepeatStop();
	softKbPress($(this));
});
$(document).on('pointerup', '#jawn_soft_keyboard button', function (e) {
	if (!jawnSoftChipStart) { return; }
	var start = jawnSoftChipStart;
	jawnSoftChipStart = null;
	if (!$(this).hasClass('soft_kb_convert_item') && !$(this).hasClass('soft_kb_history_item')) { return; }
	var dx = Math.abs((e.clientX || 0) - start.x);
	var dy = Math.abs((e.clientY || 0) - start.y);
	if (dx > 12 || dy > 12) { jawnSoftChipAt = Date.now(); return; }   // a swipe, not a tap
	e.preventDefault();
	jawnSoftChipAt = Date.now();
	softKbPress($(start.el));
});
$(document).on('pointerup pointercancel', '#jawn_soft_keyboard button', function () {
	softKbRepeatStop();
});
$(document).on('pointerup pointercancel', function () { if (jawnSoftChipStart) { jawnSoftChipAt = Date.now(); jawnSoftChipStart = null; } softKbRepeatStop(); });
$(document).on('click', '#jawn_soft_keyboard button', function () {
	if (Date.now() - jawnSoftKeyAt < 600) { return; }
	if (Date.now() - jawnSoftChipAt < 700) { return; }
	// a long hold can outlive the press guard; its release must not delete again
	if ($(this).attr('data-kb_key') == 'backspace' && Date.now() - jawnSoftHoldAt < 800) { return; }
	softKbPress($(this));
});
$(document).on('pointerdown', '#jawn_soft_keyboard', function (e) {
	if (!$(e.target).closest('button').length && !$(e.target).closest('.soft_kb_convert_rows').length) { e.preventDefault(); }
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

document.addEventListener('pointerdown', function (e) {
	var el = e.target;
	if (softKbOn() && (softKbEditable(el) || (el.isContentEditable))) { softKbSuppress(el); }
}, true);
document.addEventListener('touchstart', function (e) {
	var el = e.target;
	if (softKbOn() && (softKbEditable(el) || (el.isContentEditable))) { softKbSuppress(el); }
}, true);

$(document).on('focusin', function (e) {
	var el = e.target;
	if (!softKbOn() || !softKbEditable(el)) { return; }
	softKbSuppress(el);
	softKbShow(el);
});

$(document).on('click', 'input, textarea, [contenteditable="true"]', function () {
	if (softKbOn() && softKbEditable(this)) { softKbShow(this); }
});

$(document).on('focusout', function (e) {
	if (!softKbEditable(e.target)) { return; }
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
	if (this === jawnSoftField) { softKbConvertUpdate(); softKbSuggestSync(); }
});

// The Chat composer's keyboard button asks for the dock; pressing it again puts
// it away. It also turns the dock on for a desk that has not asked for it yet.
$(document).on('click', '#chat_soft_toggle', function () {
	var el = document.getElementById('message');
	if (!el) { return; }
	if (softKbVisible() && jawnSoftField === el) { softKbHide(); return; }
	if (!softKbOn()) { localStorage.setItem('jawn_soft_keyboard', 'on'); }
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

$(window).on('resize', function () { if (softKbVisible()) { softKbReserve(); } });

$(function () {
	softKbHistoryRender();
	softKbUnitsLoad();
	try { jawnSoftUnit = localStorage.getItem('jawn_soft_calc_unit') || null; } catch (err) {}
	// a bare number in the calculator starts in the house's own currency, so
	// the conversion row is there before a unit has been typed
	if (!jawnSoftUnit) { jawnSoftUnit = jawnSoftBase || null; }
});
