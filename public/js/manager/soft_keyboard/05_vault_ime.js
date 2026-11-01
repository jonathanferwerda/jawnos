var jawnVault = {
	locked: false,
	matches: [],
	seq: 0,
	timer: null,
	flash: null,
	open: false,
	prior: null,
	priorNumeric: false,
	priorContext: '',
	sheet: null,
	ctx: null
};
var jawnImeMeta = null;
var jawnImeLastText = '';

function softKbVaultLower(value) {
	return String(value == null ? '' : value).toLowerCase();
}

function softKbVaultHints(el) {
	var out = [];
	var add = function (value) {
		value = softKbVaultLower(value).replace(/^\s+|\s+$/g, '');
		if (value && out.indexOf(value) < 0) { out.push(value); }
	};
	if (!el) { return out; }
	add(el.getAttribute('type'));
	add(el.getAttribute('name'));
	add(el.getAttribute('id'));
	add(el.getAttribute('autocomplete'));
	add(el.getAttribute('placeholder'));
	add(el.getAttribute('data-context'));
	add(el.getAttribute('hint'));
	var type = softKbVaultLower(el.getAttribute('type'));
	var name = (el.getAttribute('name') || '') + ' ' + (el.getAttribute('id') || '') + ' ' + (el.getAttribute('autocomplete') || '');
	if (type == 'password') { add('password'); add('autofill:password'); }
	if (type == 'email' || /email|user|login/i.test(name)) { add('username'); add('autofill:username'); }
	return out;
}

function softKbVaultContext() {
	if (jawnSoftIme && !jawnVault.sheet) {
		var meta = jawnImeMeta || {};
		return {
			app: softKbVaultLower(meta.app),
			origin: softKbVaultLower(meta.origin),
			web: !!meta.web,
			password: !!meta.password,
			hints: (meta.hints || []).slice(0),
			field: String(meta.field == null ? '' : meta.field)
		};
	}
	var el = jawnVault.sheet || jawnSoftField;
	if (!el) { return { app: '', origin: '', web: false, password: false, hints: [], field: '' }; }
	var type = softKbVaultLower(el.getAttribute('type'));
	var app = $(el).closest('[app]').attr('app') || $(el).closest('.wind').attr('app') || 'manager';
	return {
		app: softKbVaultLower(app),
		// the manager's own page is the site here; the vault keeps app forms apart
		// by their app as well
		origin: softKbVaultLower(location.host || ''),
		web: false,
		password: type == 'password',
		hints: softKbVaultHints(el),
		field: (el.getAttribute('name') || el.id || '')
	};
}

function softKbVaultFieldValue() {
	if (jawnVault.sheet) { return jawnVault.sheet.value || ''; }
	if (jawnSoftIme) { return jawnImeText || ''; }
	if (!jawnSoftField) { return ''; }
	return jawnSoftField.isContentEditable ? $(jawnSoftField).text() : (jawnSoftField.value || '');
}

function softKbVaultFieldName(ctx) {
	var el = jawnVault.prior || jawnSoftField;
	if (!el) { return ctx.field || 'Saved'; }
	return el.getAttribute('placeholder') || el.getAttribute('name') || el.id || ctx.field || 'Saved';
}

function softKbVaultLastUser(ctx) {
	if (jawnSoftIme) { return jawnImeLastText || ''; }
	var el = jawnVault.prior || jawnSoftField;
	if (!el) { return ''; }
	var form = $(el).closest('form');
	var scope = form.length ? form : $(el).closest('.window_contents, .appointment_contents');
	var found = '';
	scope.find('input,textarea').each(function () {
		if (softKbVaultLower(this.getAttribute('type')) == 'password') { return; }
		var hint = (this.getAttribute('name') || '') + ' ' + (this.getAttribute('id') || '') + ' ' + (this.getAttribute('autocomplete') || '');
		if (/user|email|login/i.test(hint) && this.value) { found = this.value; return false; }
	});
	return found;
}

function softKbVaultButtons() {
	var fill = $('#soft_kb_vault_fill');
	var save = $('#soft_kb_vault_save');
	if (!fill.length && !save.length) { return; }
	var ctx = softKbVaultContext();
	var has_value = String(softKbVaultFieldValue() || '').length > 0;
	var can_fill = !jawnVault.locked && !jawnVault.open && (jawnVault.matches || []).length > 0;
	var can_save = !jawnVault.locked && !jawnVault.open && has_value;
	fill.prop('hidden', !can_fill);
	save.prop('hidden', !can_save);
	save.text(ctx.password ? '🔐' : '💾');
	fill.attr('aria-label', softKbLabel('Fill from the vault')).attr('hint', softKbLabel('Fill this field from a saved entry'));
	save.attr('aria-label', softKbLabel(ctx.password ? 'Save this password' : 'Save this field'))
		.attr('hint', softKbLabel(ctx.password ? 'Save this password in the vault' : 'Save this value in the vault'));
}

function softKbVaultSync() {
	if (jawnVault.open || !softKbVisible()) { return; }
	var ctx = softKbVaultContext();
	if (!ctx.app && !ctx.origin) { jawnVault.matches = []; jawnVault.locked = false; softKbVaultButtons(); return; }
	clearTimeout(jawnVault.timer);
	jawnVault.timer = setTimeout(function () {
		var seq = ++jawnVault.seq;
		$.get('/manager/credentials/status', {
			app: ctx.app,
			origin: ctx.origin,
			hints: JSON.stringify(ctx.hints || [])
		}, function (r) {
			if (seq != jawnVault.seq) { return; }
			jawnVault.locked = !!(r && r.locked);
			jawnVault.matches = (r && r.matches) || [];
			softKbVaultButtons();
		}, 'json').fail(function () {});
	}, 250);
}

function softKbVaultFlash(text) {
	var title = $('#jawn_soft_keyboard .soft_kb_title');
	if (!title.length) { return; }
	title.text(text);
	clearTimeout(jawnVault.flash);
	jawnVault.flash = setTimeout(function () { softKbTitleUpdate(); }, 1800);
}

function softKbVaultSaveOpen() {
	if (jawnVault.locked) { return; }
	var ctx = softKbVaultContext();
	var value = softKbVaultFieldValue() || '';
	jawnVault.ctx = ctx;
	jawnVault.prior = jawnSoftField;
	jawnVault.priorNumeric = jawnSoftNumeric;
	jawnVault.priorContext = jawnSoftContext;
	jawnVault.open = true;
	jawnVault.sheet = null;
	$('body').addClass('soft_kb_vault_open');
	softKbLayoutsToggle(false);
	$('#soft_kb_vault_list').empty();
	$('#soft_kb_vault_head').text(softKbLabel(ctx.password ? 'Save password' : 'Save this field'));
	$('#soft_kb_vault_note').text('');
	var site = (ctx.origin || '').replace(/:\d+$/, '');
	$('#soft_kb_vault_site').val(site);
	$('#soft_kb_vault_site_wrap').prop('hidden', !(ctx.web || ctx.password && ctx.app && /chrome|browser|firefox|opera|edge|brave|vivaldi|samsung/i.test(ctx.app)));
	$('#soft_kb_vault_user_wrap').prop('hidden', !ctx.password);
	$('#soft_kb_vault_user').val(softKbVaultLastUser(ctx) || '');
	$('#soft_kb_vault_secret').val(ctx.password ? value : '');
	$('#soft_kb_vault_secret_wrap').prop('hidden', !ctx.password);
	$('#soft_kb_vault_value').val(ctx.password ? '' : value);
	$('#soft_kb_vault_value_wrap').prop('hidden', !!ctx.password);
	$('#soft_kb_vault_label').val(ctx.password ? (site || ctx.app || 'Saved') : softKbVaultFieldName(ctx));
	$('#soft_kb_vault_form').prop('hidden', false);
	$('#soft_kb_vault').prop('hidden', false);
	softKbVaultButtons();
	softKbVaultSheetFocus('#soft_kb_vault_label');
}

function softKbVaultSheetFocus(target) {
	var el = (typeof target == 'string') ? $(target)[0] : target;
	if (!el) { return; }
	$('#soft_kb_vault input').removeClass('soft_kb_vault_active');
	$(el).addClass('soft_kb_vault_active');
	jawnVault.sheet = el;
	jawnSoftField = el;
	jawnSoftNumeric = false;
	jawnSoftContext = '';
	softKbSuppress(el);
	// In an input method the page must not take focus from the app's editor;
	// the keys still write here through the DOM, and the outline shows the target.
	if (!jawnSoftIme) {
		try { el.focus({ preventScroll: true }); } catch (err) { try { el.focus(); } catch (err2) {} }
	}
	try { el.setSelectionRange((el.value || '').length, (el.value || '').length); } catch (err) {}
	softKbModeSet('letters');
	softKbTitleUpdate();
}

function softKbVaultSheetEnter() {
	if (!jawnVault.open || !jawnVault.sheet) { return; }
	var list = $('#soft_kb_vault input').filter(function () { return this.offsetParent !== null; }).toArray();
	var at = list.indexOf(jawnVault.sheet);
	if (at >= 0 && at + 1 < list.length) { softKbVaultSheetFocus(list[at + 1]); return; }
	if (at >= 0) { softKbVaultSaveCommit(); }
}

function softKbVaultClose() {
	clearTimeout(jawnVault.flash);
	jawnVault.open = false;
	jawnVault.sheet = null;
	$('body').removeClass('soft_kb_vault_open');
	$('#soft_kb_vault').prop('hidden', true);
	$('#soft_kb_vault_form').prop('hidden', true);
	$('#soft_kb_vault_list').empty();
	$('#soft_kb_vault_note').text('');
	$('#soft_kb_vault input').removeClass('soft_kb_vault_active');
	jawnSoftField = jawnVault.prior || null;
	if (!jawnSoftIme) {
		jawnSoftNumeric = !!jawnVault.priorNumeric;
		jawnSoftContext = jawnVault.priorContext || '';
	}
	jawnVault.prior = null;
	if (jawnSoftField) { softKbSuppress(jawnSoftField); }
	softKbModeSet(jawnSoftNumeric ? 'calc' : 'letters');
	softKbTitleUpdate();
	softKbVaultSync();
}

function softKbVaultSaveCommit() {
	if (!jawnVault.open) { return; }
	var ctx = jawnVault.ctx || softKbVaultContext();
	var label = $('#soft_kb_vault_label').val() || '';
	var site = ($('#soft_kb_vault_site').val() || '').replace(/^\s+|\s+$/g, '');
	var user = $('#soft_kb_vault_user').val() || '';
	var secret = $('#soft_kb_vault_secret').val() || '';
	var value = $('#soft_kb_vault_value').val() || '';
	var params = { app: ctx.app || '', label: label };
	var origin = site || (ctx.web ? '' : ctx.origin);
	if (origin) { params.origin = origin; }
	// a browser entry's name is its site unless the person named it otherwise
	if (site && (!label || label == ctx.app)) { label = site; params.label = label; }
	if (ctx.password) {
		if (user) { params.username = user; }
		if (secret) { params.password = secret; }
	}
	else { params.value = value; }
	var hints = (ctx.hints || []).slice(0);
	if (ctx.password) {
		if (hints.indexOf('password') < 0) { hints.push('password'); }
		if (hints.indexOf('username') < 0) { hints.push('username'); }
	}
	params.hints = JSON.stringify(hints);
	// the manager's own forms can be filled again field by field later
	if (!jawnSoftIme && jawnVault.prior) {
		var form = $(jawnVault.prior).closest('form');
		var scope = form.length ? form : $(jawnVault.prior).closest('.window_contents, .appointment_contents');
		var fields = {};
		scope.find('input,textarea,select').each(function () {
			var key = this.name || this.id;
			if (!key || !this.value || softKbVaultLower(this.getAttribute('type')) == 'password') { return; }
			fields[key] = this.value;
		});
		if (Object.keys(fields).length) { params.fields = JSON.stringify(fields); }
	}
	$('#soft_kb_vault_note').text(softKbLabel('Saving…'));
	$.post('/manager/credentials/save', params, function (r) {
		if (!r || !r.ok) {
			var msg = 'Could not save';
			if (r && r.error == 'site-required') { msg = 'A site is needed for a browser password'; }
			else if (r && r.error == 'locked') { msg = 'The house is locked'; }
			else if (r && r.error == 'no-vault') { msg = 'There is no vault on this machine'; }
			$('#soft_kb_vault_note').text(softKbLabel(msg));
			return;
		}
		softKbVaultClose();
		softKbVaultFlash(softKbLabel('Saved'));
		softKbVaultSync();
	}, 'json').fail(function () { $('#soft_kb_vault_note').text(softKbLabel('Could not save')); });
}

function softKbVaultFillOpen() {
	var matches = jawnVault.matches || [];
	if (!matches.length || jawnVault.locked) { return; }
	if (matches.length == 1) { softKbVaultFillOne(matches[0].uuid); return; }
	jawnVault.ctx = softKbVaultContext();
	jawnVault.prior = jawnSoftField;
	jawnVault.priorNumeric = jawnSoftNumeric;
	jawnVault.priorContext = jawnSoftContext;
	jawnVault.open = true;
	jawnVault.sheet = null;
	$('body').addClass('soft_kb_vault_open');
	softKbLayoutsToggle(false);
	$('#soft_kb_vault_head').text(softKbLabel('Fill from the vault'));
	$('#soft_kb_vault_form').prop('hidden', true);
	var list = $('#soft_kb_vault_list').empty();
	matches.forEach(function (row) {
		var item = $('<div class="soft_kb_vault_item"></div>');
		$('<span class="soft_kb_vault_item_name"></span>').text(row.label || row.origin || row.app || 'Saved').appendTo(item);
		var meta = [];
		if (row.has_user) { meta.push(softKbLabel('username')); }
		if (row.has_password) { meta.push(softKbLabel('password')); }
		if (meta.length) { $('<span class="soft_kb_vault_item_meta"></span>').text(meta.join(' · ')).appendTo(item); }
		$('<button type="button" class="soft_kb_vault_primary"></button>').text(softKbLabel('Fill'))
			.attr('data-kb_vault_fill', row.uuid).appendTo(item);
		$('<button type="button" class="soft_kb_vault_forget" aria-label="' + softKbHtml(softKbLabel('Forget')) + '"></button>')
			.text('×').attr('data-kb_vault_forget', row.uuid).appendTo(item);
		list.append(item);
	});
	$('#soft_kb_vault').prop('hidden', false);
	softKbVaultButtons();
}

function softKbVaultForget(uuid, button) {
	var btn = $(button);
	if (!btn.data('armed')) {
		btn.data('armed', 1).text(softKbLabel('Sure?'));
		return;
	}
	$.post('/manager/credentials/forget', { uuid: uuid }, function (r) {
		if (r && r.ok) { softKbVaultClose(); softKbVaultFlash(softKbLabel('Forgotten')); softKbVaultSync(); }
	}, 'json');
}

function softKbVaultFillOne(uuid) {
	$.post('/manager/credentials/fill', { uuid: uuid }, function (r) {
		if (!r || !r.ok) {
			softKbVaultFlash(softKbLabel(r && r.locked ? 'The house is locked' : 'Could not fill'));
			return;
		}
		var fields = r.fields || {};
		if (jawnSoftIme) {
			var ctx = jawnVault.open ? (jawnVault.ctx || softKbVaultContext()) : softKbVaultContext();
			var value = null;
			if (ctx.password) { value = fields.password; }
			if (value == null) { value = fields.username; }
			if (value == null && fields.fields) {
				var keys = Object.keys(fields.fields);
				for (var i = 0; i < keys.length; i++) {
					if (keys[i] == ctx.field) { value = fields.fields[keys[i]]; break; }
				}
				if (value == null && keys.length == 1) { value = fields.fields[keys[0]]; }
			}
			if (value == null) { value = fields.value; }
			if (value != null) { softKbImeReplace(value); }
		}
		else { softKbVaultFillDom(fields); }
		softKbVaultClose();
		softKbVaultFlash(softKbLabel('Filled'));
		softKbVaultSync();
	}, 'json');
}

function softKbVaultFillDom(fields) {
	var el = jawnVault.prior || jawnSoftField;
	if (!el) { return; }
	var form = $(el).closest('form');
	var scope = form.length ? form : $(el).closest('.window_contents, .appointment_contents');
	if (!scope.length) { scope = $(el).parent(); }
	var inputs = scope.find('input,textarea,select').addBack('input,textarea,select');
	var map = fields.fields || {};
	var used = false;
	inputs.each(function () {
		var type = softKbVaultLower(this.getAttribute('type'));
		var key = this.name || this.id || '';
		var hint = (this.name || '') + ' ' + (this.id || '') + ' ' + (this.getAttribute('placeholder') || '') + ' ' + (this.getAttribute('autocomplete') || '');
		var value = map[key];
		if (value == null) {
			if (type == 'password' || /pass/i.test(hint)) { value = fields.password; }
			else if (/user|email|login/i.test(hint)) { value = fields.username; }
		}
		if (value == null && inputs.length == 1) { value = fields.value; }
		if (value != null) { this.value = value; softKbNotify(this); used = true; }
	});
	if (!used) {
		var value = fields.password != null ? fields.password : (fields.username != null ? fields.username : fields.value);
		if (value != null) { softKbInsert(value, el); }
	}
}

$(document).on('pointerdown', '#soft_kb_vault input', function (e) {
	e.preventDefault();
	softKbVaultSheetFocus(this);
});

$(document).on('keydown', '#soft_kb_vault input', function (e) {
	if (e.key == 'Enter') { e.preventDefault(); softKbVaultSheetEnter(); }
	else if (e.key == 'Escape') { e.preventDefault(); softKbVaultClose(); }
});

// ---- the input method's own entry points ----------------------------------
// Called by templates/ime.html.ep after this file has run. The service calls
// imeConfigure when a field starts and imeText after every edit; both drive the
// same panels the dock uses, with no DOM field in between.
function softKbImeStart() {
	if (!jawnSoftIme) { return; }
	var dock = $('#jawn_soft_keyboard');
	if (!dock.length) { return; }
	jawnSoftField = null;
	softKbPlace(null);
	dock.prop('hidden', false).attr('aria-hidden', 'false');
	$('body').addClass('soft_kb_open');
	softKbModeSet(jawnSoftNumeric ? 'calc' : 'letters');
	softKbSlideUp(dock);
	softKbTitleUpdate();
	softKbConvertUpdate();
	softKbSuggestSync();
	softKbVaultButtons();
}

// numeric: the field is a number/phone editor, so the calculator page opens.
// context: what kind of value the field names, when the app tells us (Android's
// EditorInfo hint or class); the recommendation row uses it.
window.imeConfigure = function (numeric, context, text) {
	if (!jawnSoftIme) { return; }
	if (jawnVault.open) { softKbVaultClose(); }
	jawnSoftNumeric = !!numeric;
	jawnSoftContext = context || '';
	jawnSoftField = null;
	jawnSoftExpr = '';
	// the field's own text, read when it begins: a number field seeds the
	// calculator with what it already holds instead of the last field's words
	if (text != null) { jawnImeText = String(text); }
	if (jawnSoftNumeric) { jawnSoftExpr = jawnImeText || ''; }
	softKbShiftSet(false);
	softKbModeSet(jawnSoftNumeric ? 'calc' : 'letters');
	softKbTitleUpdate();
	softKbConvertUpdate();
	softKbSuggestSync();
	jawnVault.matches = [];
	softKbVaultButtons();
};

// The field's own facts from Android's EditorInfo: which app it is, whether it
// is a password (or web) field, and the hints the app published. The vault uses
// them to offer only the entries scoped to this app (or, for a site row, this
// site - the input method cannot see a browser's address, so a browser password
// is saved with a site the person names and offered by the Autofill service).
window.imeField = function (meta) {
	if (!jawnSoftIme) { return; }
	jawnImeMeta = meta || null;
	if (jawnVault.open) { softKbVaultClose(); }
	jawnVault.matches = [];
	softKbVaultButtons();
	softKbVaultSync();
};

// The service's report of the editor text before the caret. A conversion reads
// the quantity being typed, and the recommendation row reads the same words a
// DOM field would have offered.
window.imeText = function (before) {
	if (!jawnSoftIme) { return; }
	jawnImeText = String(before == null ? '' : before);
	// the next password's save sheet offers the last ordinary field as the
	// username, the way a browser remembers the pair
	if (!(jawnImeMeta && jawnImeMeta.password) && jawnImeText) { jawnImeLastText = jawnImeText; }
	softKbConvertUpdate();
	softKbSuggestSync();
	if (!jawnVault.open) { softKbVaultButtons(); softKbVaultSync(); }
};

$(function () {
	softKbHistoryRender();
	softKbLayoutRender();
	softKbLayoutsRender();
	softKbMicState();
	softKbUnitsLoad();
	// the row lives in the body, like the dock: a transformed ancestor would
	// make position:fixed a child of that ancestor instead of the page
	var measure_pop = $('#jawn_measure_pop');
	if (measure_pop.length && !measure_pop.parent().is('body')) { $('body').append(measure_pop); }
	try { jawnSoftUnit = localStorage.getItem('jawn_soft_calc_unit') || null; } catch (err) {}
	// a bare number in the calculator starts in the house's own currency, so
	// the conversion row is there before a unit has been typed
	if (!jawnSoftUnit) { jawnSoftUnit = jawnSoftBase || null; }
});
