function softKbConvertParse(text, strict) {
	softKbUnitsLoad();
	text = String(text || '');
	var best = null;
	// a space between the number and its unit is ordinary prose ("32.33 L"), and
	// a unit's own name can be longer than its code ("kilograms")
	var re = /(-?\d[\d,]*(?:\.\d+)?)\s*([A-Za-z]{1,12})/g;
	var m;
	while ((m = re.exec(text))) {
		if (/[A-Za-z]/.test(text.charAt(re.lastIndex))) { continue; }
		var code = softKbUnitCode(m[2]);
		var value = softKbNumber(m[1]);
		if (!code || value == null) { continue; }
		best = { value: value, unit: code, at: m.index, len: m[0].length };
	}
	var sre = /([$\u20ac\u00a3\u00a5\u20b9\u20bd\u20a9\u20ba\u20bf\u039e\u20b3\u0141\u00d0\u25ce])\s*(-?\d[\d,]*(?:\.\d+)?)/g;
	while ((m = sre.exec(text))) {
		var sym = (jawnSoftSymbols || {})[m[1]];
		var v = softKbNumber(m[2]);
		if (!sym || v == null) { continue; }
		if (!best || m.index >= best.at) { best = { value: v, unit: sym, at: m.index, len: m[0].length }; }
	}
	if (best) { return best; }
	if (!strict && jawnSoftMode == 'calc' && jawnSoftUnit) {
		var tm = text.match(/(-?\d[\d,]*(?:\.\d+)?)\s*$/);
		if (tm) {
			var n = softKbNumber(tm[1]);
			if (n != null) { return { value: n, unit: jawnSoftUnit, at: tm.index, len: tm[0].length, sticky: true }; }
		}
	}
	return null;
}

function softKbConvertText() {
	var el = jawnSoftField;
	if (!jawnSoftIme && el && (el.getAttribute('type') || '').toLowerCase() == 'password') { return ''; }
	if (jawnSoftMode == 'calc') { return jawnSoftExpr || ''; }
	if (jawnSoftIme) { return jawnImeText; }
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
	// the vault's drawer is the thing being typed in; conversions would be noise
	if (jawnVault.open) { softKbConvertHide(); return; }
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
	if (jawnSoftNumeric && (jawnSoftField || jawnSoftIme)) {
		jawnSoftExpr = String(value);
		softKbCalcRender();
		softKbCalcSyncNumeric();
		if (jawnSoftField) { try { jawnSoftField.focus({ preventScroll: true }); } catch (err) {} }
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

// ---- the same conversions, beside the field -------------------------------
// The dock is a phone's keyboard. A desk types with its own and the dock stays
// closed, but a quantity that names a unit (32.33L, $32.31, 5jpy) still has
// every other unit of its kind to offer, so that row rides just above the field
// being typed in. It is the same parse and the same server answer as the dock's
// row; only the place is different, and the quantity is replaced by the answer
// instead of the number being appended at the caret.
var jawnMeasureField = null;
var jawnMeasureHit = null;
var jawnMeasureTimer = null;
var jawnMeasureSeq = 0;
var jawnMeasureHideTimer = null;
var jawnMeasureQuiet = 0;

function jawnMeasureUsable(el) {
	if (!el || el.nodeType != 1) { return false; }
	if ($(el).closest('#jawn_soft_keyboard, #jawn_measure_pop').length) { return false; }
	return softKbEditable(el);
}

function jawnMeasureText(el) {
	if (!el) { return ''; }
	return el.isContentEditable ? $(el).text() : (el.value || '');
}

// The template carries this row; a page that was rendered before it existed
// still gets one, so the feature cannot depend on a stale template.
function jawnMeasureRoot() {
	var pop = $('#jawn_measure_pop');
	if (!pop.length) {
		pop = $('<div id="jawn_measure_pop" class="soft_kb_convert" hidden><span id="jawn_measure_pop_src" class="soft_kb_convert_src"></span><div id="jawn_measure_pop_rows" class="soft_kb_convert_rows"></div></div>');
		$('body').append(pop);
	}
	return pop;
}

function jawnMeasureHide() {
	clearTimeout(jawnMeasureTimer);
	jawnMeasureSeq++;
	jawnMeasureHit = null;
	var pop = $('#jawn_measure_pop');
	if (pop.length && !pop.prop('hidden')) { pop.prop('hidden', true); }
}

function jawnMeasureFocus(el) {
	if (!jawnMeasureUsable(el)) { jawnMeasureField = null; jawnMeasureHide(); return; }
	jawnMeasureField = el;
	jawnMeasureUpdate();
}

function jawnMeasureUpdate() {
	var el = jawnMeasureField;
	if (!el || !document.contains(el)) { jawnMeasureHide(); return; }
	if (Date.now() - jawnMeasureQuiet < 400) { return; }
	// the dock's own row is the one to read while the keys are up
	if (softKbVisible()) { jawnMeasureHide(); return; }
	// a time, a length, a warranty or a repeat names its own units; "5m" there
	// is five minutes and must not be read as metres. Another kind of quantity
	// in such a field (32.33 L, $5) still converts - only the time-shaped units
	// are left to the field.
	var context = softKbContext(el);
	if (context == 'password') { jawnMeasureHide(); return; }
	var hit = softKbConvertParse(jawnMeasureText(el), true);
	if (!hit) { jawnMeasureHide(); return; }
	if ((context == 'when' || context == 'duration' || context == 'warranty' || context == 'schedule')
		&& /^(s|m|min|mins|h|hr|hrs|d|w|M|mo|y|yr)$/.test(hit.unit)) {
		jawnMeasureHide();
		return;
	}
	jawnMeasureHit = hit;
	var seq = ++jawnMeasureSeq;
	clearTimeout(jawnMeasureTimer);
	jawnMeasureTimer = setTimeout(function () {
		$.get('/manager/keyboard/convert', { unit: hit.unit, value: hit.value }, function (r) {
			if (seq != jawnMeasureSeq) { return; }
			if (!r || !r.ok || !r.rows || !r.rows.length) { jawnMeasureHide(); return; }
			jawnMeasureRender(r, hit);
		}, 'json').fail(function () {
			if (seq == jawnMeasureSeq) { jawnMeasureHide(); }
		});
	}, 260);
}

function jawnMeasureRender(r, hit) {
	var pop = jawnMeasureRoot();
	jawnSoftUnit = r.unit || (hit && hit.unit) || jawnSoftUnit;
	try { localStorage.setItem('jawn_soft_calc_unit', jawnSoftUnit); } catch (err) {}
	$('#jawn_measure_pop_src').text(r.text || ((r.value != null ? r.value : hit.value) + ' ' + jawnSoftUnit));
	var use = softKbUseLoad();
	var rows = (r.rows || []).slice(0);
	rows.sort(function (a, b) { return (Number(use[b.unit]) || 0) - (Number(use[a.unit]) || 0); });
	if (rows.length > JAWN_SOFT_CONVERT_MAX) { rows.length = JAWN_SOFT_CONVERT_MAX; }
	var box = $('#jawn_measure_pop_rows').empty();
	for (var i = 0; i < rows.length; i++) {
		var row = rows[i];
		var text = row.text || (row.value + ' ' + row.unit);
		$('<button type="button" class="soft_kb_convert_item"></button>')
			.attr({
				'data-measure_unit': row.unit,
				'data-measure_value': row.value,
				'data-measure_text': text,
				title: (row.name || row.unit),
				'aria-label': text + ' ' + (row.name || '')
			})
			.text(text)
			.appendTo(box);
	}
	pop.prop('hidden', false);
	jawnMeasurePlace();
}

// Above the field, or below it when the top of the page has no room. The row
// keeps the field's own width where it can, and never runs off the screen.
function jawnMeasurePlace() {
	var pop = $('#jawn_measure_pop');
	var el = jawnMeasureField;
	if (!pop.length || pop.prop('hidden') || !el || !document.contains(el)) { return; }
	var rect = el.getBoundingClientRect();
	var vw = window.innerWidth || $(window).width();
	var vh = window.innerHeight || $(window).height();
	if (rect.bottom < 0 || rect.top > vh) { jawnMeasureHide(); return; }
	var width = Math.min(Math.max(rect.width, 240), 460, vw - 16);
	pop.css('width', width + 'px');
	var h = pop.outerHeight() || 0;
	var gap = 8;
	var left = Math.max(8, Math.min(rect.left, vw - width - 8));
	var top = rect.top - h - gap;
	if (top < 8) { top = Math.min(vh - h - 8, rect.bottom + gap); }
	pop.css({ left: left + 'px', top: Math.max(8, top) + 'px' });
}

// Tapping a conversion writes its answer: a number field takes the number, and
// a text field has the quantity it typed (unit and all) replaced by the answer.
function jawnMeasurePick(unit, value, text) {
	var el = jawnMeasureField;
	var hit = jawnMeasureHit;
	if (!el) { return; }
	var num = softKbNumber(value);
	if (unit) {
		jawnSoftUnit = unit;
		softKbUseAdd(unit);
		try {
			localStorage.setItem('jawn_soft_calc_unit', unit);
			if (jawnSoftType) { localStorage.setItem('jawn_soft_unit_' + jawnSoftType, unit); }
		} catch (err) {}
	}
	jawnMeasureQuiet = Date.now();
	if (num != null) {
		if (!el.isContentEditable && softKbNumeric(el)) {
			el.value = String(num);
			try { el.focus({ preventScroll: true }); el.setSelectionRange(el.value.length, el.value.length); } catch (err) {}
			softKbNotify(el);
		}
		else if (!el.isContentEditable && hit && text) {
			var start = hit.at;
			var end = hit.at + (hit.len || 0);
			if (start < 0 || start > el.value.length) { start = el.value.length; end = start; }
			if (end > el.value.length || end < start) { end = el.value.length; }
			el.value = el.value.slice(0, start) + text + el.value.slice(end);
			try { el.focus({ preventScroll: true }); el.setSelectionRange(start + text.length, start + text.length); } catch (err) {}
			softKbNotify(el);
		}
		else {
			softKbInsert(text || String(num), el);
		}
	}
	jawnMeasureHide();
}

// The row answers a press without taking the caret out of the field. A chip
// answers a release that did not travel, the way the dock's own chips do, so a
// sideways drag along the row pans it instead of choosing.
var jawnMeasureTap = null;
$(document).on('pointerdown', '#jawn_measure_pop button', function (e) {
	if (e.button != null && e.button != 0) { return; }
	e.preventDefault();
	jawnMeasureTap = { x: e.clientX, y: e.clientY, el: this };
});
$(document).on('pointerup', '#jawn_measure_pop button', function (e) {
	var tap = jawnMeasureTap;
	jawnMeasureTap = null;
	if (!tap || tap.el !== this) { return; }
	if (Math.abs((e.clientX || 0) - tap.x) > 12 || Math.abs((e.clientY || 0) - tap.y) > 12) { return; }
	e.preventDefault();
	jawnMeasurePick($(this).attr('data-measure_unit'), $(this).attr('data-measure_value'), $(this).attr('data-measure_text'));
});
$(document).on('pointerup pointercancel', function () { jawnMeasureTap = null; });

$(document).on('focusin', function (e) { jawnMeasureFocus(e.target); });

$(document).on('focusout', function (e) {
	if (e.target !== jawnMeasureField) { return; }
	clearTimeout(jawnMeasureHideTimer);
	jawnMeasureHideTimer = setTimeout(function () {
		if ($(document.activeElement).closest('#jawn_measure_pop').length) { return; }
		jawnMeasureHide();
		jawnMeasureField = null;
	}, 240);
});

// typing in a contenteditable fires input too; the dock's own listener covers
// input and textarea
if (document.addEventListener) {
	document.addEventListener('input', function (e) {
		if (e.target && e.target === jawnMeasureField) { jawnMeasureUpdate(); }
	}, true);
}

document.addEventListener('scroll', function () {
	if (!jawnMeasureField) { return; }
	var pop = document.getElementById('jawn_measure_pop');
	if (!pop || pop.hidden) { return; }
	jawnMeasurePlace();
}, true);

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
	if (jawnSoftIme) { return jawnImeText; }
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
	// while the vault's drawer is open it owns the space above the keys
	if (jawnVault.open) {
		if (wrap.length && !wrap.prop('hidden')) { wrap.prop('hidden', true); softKbReserve(); }
		return;
	}
	var def = jawnSoftSuggestDefs[jawnSoftContext];
	if (!def || (!jawnSoftField && !jawnSoftIme)) {
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
	if (value == null) { return; }
	if (jawnSoftIme) {
		if (jawnSoftNumeric) {
			jawnSoftExpr = value;
			softKbCalcRender();
			softKbImeSetNumber(value);
		}
		else { softKbImeReplace(value); }
		softKbConvertUpdate();
		softKbSuggestSync();
		return;
	}
	var el = jawnSoftField;
	if (!el) { return; }
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
