function softKbImeSync() {
	if (window.JawnIme && typeof window.JawnIme.sync === 'function') { window.JawnIme.sync(); }
}

function softKbImeSend(text) {
	if (window.JawnIme && typeof window.JawnIme.send === 'function') { window.JawnIme.send(String(text)); }
	softKbImeSync();
}

function softKbImeBackspace() {
	if (window.JawnIme && typeof window.JawnIme.backspace === 'function') { window.JawnIme.backspace(); }
	softKbImeSync();
}

// A number field holds one answer, so the calculator's operand replaces it
// rather than being appended (the dock does this by assigning field.value).
function softKbImeSetNumber(value) {
	if (window.JawnIme && typeof window.JawnIme.setNumber === 'function') { window.JawnIme.setNumber(String(value)); }
	else if (window.JawnIme && typeof window.JawnIme.replaceAll === 'function') { window.JawnIme.replaceAll(String(value)); }
	softKbImeSync();
}

function softKbImeReplace(value) {
	if (window.JawnIme && typeof window.JawnIme.replaceAll === 'function') { window.JawnIme.replaceAll(String(value)); }
	softKbImeSync();
}

function softKbInsert(text, target, nofocus) {
	var el = target || jawnSoftField;
	// the vault's own form is a real field in the page: write it in place, not
	// into the app's editor
	if (jawnSoftIme && !el) { softKbImeSend(text); return; }
	if (!el) { return; }
	if (jawnVault.sheet && el === jawnVault.sheet) { nofocus = true; }
	if (el.isContentEditable) {
		// A transcribed phrase for a field that is no longer focused appends to
		// its end; focusing it would take the caret away from where the person is.
		if (document.activeElement !== el) {
			if (nofocus) {
				try { el.appendChild(document.createTextNode(text)); }
				catch (err) {}
				softKbNotify(el);
				return;
			}
		}
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
	if (!nofocus) { try { el.focus({ preventScroll: true }); } catch (err2) { el.focus(); } }
	softKbNotify(el);
}

function softKbBackspace() {
	if (jawnSoftIme && !jawnSoftField) { softKbImeBackspace(); return; }
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
	if (!(jawnVault.sheet && el === jawnVault.sheet)) {
		try { el.focus({ preventScroll: true }); } catch (err2) { el.focus(); }
	}
	softKbNotify(el);
}

// ---- hold-to-repeat ---------------------------------------------------------
// A held backspace repeats characters, starting after a short wait and getting
// faster the longer it is held. Every tap — however quickly it follows the last
// — deletes one character; there is no double-tap word delete.
var JAWN_SOFT_HOLD_DELAY = 450;
var JAWN_SOFT_CHAR_FIRST = 140;
var JAWN_SOFT_CHAR_MIN = 30;
var JAWN_SOFT_ACCEL = 0.82;
var jawnSoftHold = null;
var jawnSoftHoldAt = 0;

function softKbRepeatStop() {
	if (!jawnSoftHold) { return; }
	clearTimeout(jawnSoftHold.timer);
	jawnSoftHold = null;
	jawnSoftHoldAt = Date.now();
}

function softKbRepeatBegin() {
	var hold = jawnSoftHold;
	if (!hold) { return; }
	if (!jawnSoftField && !jawnSoftIme) { softKbRepeatStop(); return; }
	if (hold.mode == 'calc') {
		softKbRepeatStart(hold, JAWN_SOFT_CHAR_FIRST, JAWN_SOFT_CHAR_MIN, function () { softKbCalcKey('backspace'); });
		return;
	}
	softKbRepeatStart(hold, JAWN_SOFT_CHAR_FIRST, JAWN_SOFT_CHAR_MIN, softKbBackspace);
}

// Each repeat comes a little sooner than the last, down to a floor.
function softKbRepeatStart(hold, every, min, fn) {
	hold.every = every;
	hold.min = min;
	hold.fn = fn;
	hold.timer = setTimeout(function () { softKbRepeatStep(hold); }, every);
}

function softKbRepeatStep(hold) {
	if (jawnSoftHold !== hold) { return; }
	if (!jawnSoftField && !jawnSoftIme) { softKbRepeatStop(); return; }
	hold.fn();
	hold.every = Math.max(hold.min, Math.round(hold.every * JAWN_SOFT_ACCEL));
	hold.timer = setTimeout(function () { softKbRepeatStep(hold); }, hold.every);
}

// The backspace press itself still deletes at once; the hold is armed behind it.
function softKbBackspaceOnce() {
	if (jawnSoftMode == 'calc') { softKbCalcKey('backspace'); }
	else { softKbBackspace(); }
}

function softKbBackspaceDown(el) {
	var now = Date.now();
	softKbRepeatStop();
	softKbBackspaceOnce();
	if (!jawnSoftField && !jawnSoftIme) { return; }
	jawnSoftHold = {
		mode: (jawnSoftMode == 'calc') ? 'calc' : 'char',
		started: now,
		timer: null, every: 0, min: 0, fn: null
	};
	jawnSoftHold.timer = setTimeout(function () { softKbRepeatBegin(); }, JAWN_SOFT_HOLD_DELAY);
}

function softKbEnter() {
	if (jawnVault.sheet) { softKbVaultSheetEnter(); return; }
	if (jawnSoftMode == 'calc') { softKbCalcEquals(); return; }
	if (jawnSoftIme && !jawnSoftField) {
		if (window.JawnIme && typeof window.JawnIme.enter === 'function') { window.JawnIme.enter(); }
		return;
	}
	var el = jawnSoftField;
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
	if (!jawnSoftNumeric) { return; }
	var m = jawnSoftExpr.match(/(-?\d*\.?\d*)$/);
	var value = m ? m[1] : '';
	if (value == '-' || value == '.') { value = ''; }
	if (/\.$/.test(value)) { value = value.slice(0, -1); }
	if (jawnSoftIme && !jawnSoftField) { softKbImeSetNumber(value); return; }
	if (!jawnSoftField) { return; }
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
	if (jawnSoftNumeric && (jawnSoftField || jawnSoftIme)) {
		if (jawnSoftIme) {
			softKbCalcRender();
			softKbImeSetNumber(out);
			return;
		}
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
	if (jawnSoftNumeric && (jawnSoftField || jawnSoftIme)) {
		jawnSoftExpr = out;
		softKbCalcRender();
		softKbCalcSyncNumeric();
		if (jawnSoftField) { try { jawnSoftField.focus({ preventScroll: true }); } catch (err) {} }
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
// only in the calculator, so composing a message is not turned into money. The
// desk's row passes `strict` so a bare number in an ordinary field is left be.
