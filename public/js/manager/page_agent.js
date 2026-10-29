// The page agent: the Guide attached to the Internet window's form.
//
// The Internet window's title bar carries the button (it replaces the question
// mark there); pressing it opens an associate scoped to that window and switches
// page mode on. While it is on, every turn carries a snapshot of the window's
// visible fields and buttons to /manager/help/act, and the guide may answer with
// a `page` action - fill, read or press - which is executed here against the real
// DOM. Values the guide is told to enter can come from the conversation itself,
// from the person's records (find, lookup, measure, where_when) or from a value it
// read out of the form first.
//
// The model never gets a selector, an eval or an event to run: it gets field
// and button keys (f1, f2, b1) that this file wrote onto the elements when it
// took the snapshot, and only a key (or a real id, name or label) can match.

// The panel whose turn is running, so helpDoAction can find the right window.
var jawnos_page_agent_panel = null;

function pageAgentApp(panel) {
	var app = (panel && panel.data) ? (panel.data('page_app') || '') : '';
	if (!app && typeof topWindow === 'function') { app = topWindow() || ''; }
	return app;
}

// The window the agent is attached to: the panel's own app when it has one,
// otherwise whatever window is in front.
function pageAgentRoot(panel) {
	// the exact window the person pressed the button in, when it is still open
	var stamp = (panel && panel.data) ? (panel.data('page_window') || '') : '';
	if (stamp) {
		var exact = document.getElementById('window_' + String(stamp).replace(/[^0-9]/g, ''));
		if (exact && $(exact).hasClass('wind') && $(exact).is(':visible')) { return exact; }
	}
	var app = pageAgentApp(panel);
	if (app) {
		var safe = String(app).replace(/["\\]/g, '\\$&');
		var w = $('.wind[app="' + safe + '"]').filter(':visible').last();
		if (w.length) { return w[0]; }
	}
	var top = (typeof topWindow === 'function') ? topWindow() : null;
	if (top) {
		var safe_top = String(top).replace(/["\\]/g, '\\$&');
		var tw = $('.wind[app="' + safe_top + '"]').filter(':visible').last();
		if (tw.length) { return tw[0]; }
	}
	return document.body;
}

function pageAgentMode(panel) {
	return !!(panel && panel.length && panel.data('page_on'));
}

// Switch page mode on or off for a panel. The app is kept with the panel, so a
// turn taken after the person has moved to another window still fills the one
// the agent was added to.
function pageAgentEnable(panel, app, on) {
	if (!panel || !panel.length) { return; }
	if (app) { panel.data('page_app', app); }
	panel.data('page_on', !!on);
	panel.find('.assistant_page_badge').toggle(!!on);
}

// The Internet window's button: add the Guide to that page. The timestamp is
// the window's own id, so two Internet windows keep their own form.
function pageAgentOpen(app, timestamp) {
	if (typeof assistantAppOpen !== 'function') { return; }
	var panel = assistantAppOpen(app || '');
	if (!panel || !panel.length) { return; }
	panel.data('page_window', timestamp || '');
	pageAgentEnable(panel, app || pageAgentApp(panel), true);
	assistantOpenPanel(panel);
	panel.find('.assistant_question').focus();
}

function pageAgentKind(el) {
	if (!el) { return 'text'; }
	if (el.tagName === 'SELECT') { return 'select'; }
	if (el.tagName === 'TEXTAREA') { return 'text'; }
	if (el.isContentEditable) { return 'text'; }
	return String(el.type || 'text').toLowerCase();
}

// A short, human label for a field: its own <label>, the label wrapped around
// it, its aria-label, its placeholder, its name or id, or the text just before
// it in the row.
function pageAgentLabel(el) {
	var $e = $(el);
	var text = '';
	if (el.labels && el.labels.length) { text = $(el.labels[0]).text(); }
	if (!text) {
		var wrap = $e.closest('label');
		if (wrap.length) { text = wrap.text(); }
	}
	if (!text) { text = $e.attr('aria-label') || ''; }
	if (!text) { text = $e.attr('placeholder') || ''; }
	if (!text) { text = $e.attr('title') || ''; }
	if (!text) { text = $e.attr('hint') || ''; }
	if (!text) {
		var hinted = $e.closest('[hint]');
		if (hinted.length) { text = hinted.attr('hint') || ''; }
	}
	if (!text) { text = $e.attr('name') || ''; }
	if (!text) { text = $e.attr('id') || ''; }
	if (!text) {
		var prev = $e.prevAll(':not(script):not(style)').first();
		if (prev.length) { text = prev.text(); }
	}
	if (!text && typeof el.className === 'string') {
		// a class is the last readable thing: clock_alarm_enabled says more than
		// an empty label ever will
		var cls = el.className.trim().split(/\s+/).filter(function (c) { return c && c !== 'hover' && c.indexOf('ui-') !== 0; });
		if (cls.length) { text = cls[0].replace(/[_-]+/g, ' '); }
	}
	text = $.trim(String(text || '')).replace(/\s+/g, ' ');
	return text.slice(0, 80);
}

// Take a snapshot of what the person can see and touch, and write a stable key
// on each control so the guide can name it. Values are capped, and a password
// field never carries one.
function pageAgentSnapshot(panel) {
	var root = pageAgentRoot(panel);
	$(root).find('[data-page-agent-field]').removeAttr('data-page-agent-field');
	$(root).find('[data-page-agent-button]').removeAttr('data-page-agent-button');
	var fields = [], buttons = [];
	$(root).find('input, textarea, select, [contenteditable="true"], [contenteditable=""]').each(function () {
		if (fields.length >= 60) { return false; }
		var el = this;
		if (el.disabled) { return; }
		if ($(el).closest('.top_navbar').length) { return; }
		if ($(el).closest('.assistant_view').length) { return; }
		var kind = pageAgentKind(el);
		if (kind === 'hidden' || kind === 'button' || kind === 'submit' || kind === 'reset' || kind === 'image' || kind === 'file') { return; }
		if (kind === 'radio' || kind === 'checkbox') {
			if (!$(el).is(':visible') && !$(el).closest('label').length) { return; }
		}
		else if (!$(el).is(':visible')) { return; }
		var key = 'f' + (fields.length + 1);
		$(el).attr('data-page-agent-field', key);
		var f = { field: key, label: pageAgentLabel(el), type: kind };
		if (el.id) { f.id = String(el.id).slice(0, 80); }
		if (typeof el.className === 'string' && el.className.trim()) { f.class = el.className.trim().split(/\s+/).slice(0, 2).join(' ').slice(0, 80); }
		if (kind === 'select') {
			var options = [];
			$(el).find('option').each(function () {
				var t = $.trim($(this).text());
				if (t && options.indexOf(t) < 0) { options.push(t.slice(0, 60)); }
			});
			f.options = options.slice(0, 24);
			f.value = $.trim($(el).find('option:selected').text()).slice(0, 120);
		}
		else if (kind === 'checkbox' || kind === 'radio') {
			f.value = el.checked ? 'checked' : '';
		}
		else if (kind === 'password') {
			f.value = '';
			f.secret = 1;
		}
		else {
			var v = $(el).val();
			f.value = String(v == null ? '' : v).slice(0, 160);
		}
		if (el.readOnly) { f.readonly = 1; }
		fields.push(f);
	});
	$(root).find('button, input[type="button"], input[type="submit"], [role="button"], span.button, span.internet_tab').each(function () {
		if (buttons.length >= 30) { return false; }
		var el = this;
		if (!$(el).is(':visible') || el.disabled) { return; }
		if ($(el).closest('.top_navbar').length) { return; }
		if ($(el).closest('.assistant_view').length) { return; }
		var label = $.trim($(el).is('input') ? ($(el).val() || '') : $(el).text()).replace(/\s+/g, ' ');
		var hint = $(el).attr('hint') || $(el).attr('title') || $(el).attr('aria-label') || '';
		if (!label && !hint) { return; }
		var key = 'b' + (buttons.length + 1);
		$(el).attr('data-page-agent-button', key);
		buttons.push({ target: key, label: label.slice(0, 60), hint: $.trim(hint).slice(0, 80) });
	});
	return {
		app: pageAgentApp(panel),
		title: $.trim($(root).find('.name_text').first().text()) || pageAgentApp(panel),
		fields: fields,
		buttons: buttons
	};
}

function pageAgentEsc(name) {
	return String(name || '').replace(/["\\]/g, '\\$&');
}

function pageAgentFindField(root, name) {
	name = $.trim(String(name == null ? '' : name));
	if (!name) { return $(); }
	var hit = $(root).find('[data-page-agent-field="' + pageAgentEsc(name) + '"]').first();
	if (hit.length) { return hit; }
	// a key from an earlier snapshot (or a hand-written id/name): try the DOM's
	// own names before giving up
	if (/^[A-Za-z][\w:.-]*$/.test(name)) {
		hit = $(root).find('#' + name).filter('input, textarea, select, [contenteditable]').first();
		if (hit.length) { return hit; }
		hit = $(root).find('[name="' + pageAgentEsc(name) + '"]').first();
		if (hit.length) { return hit; }
	}
	var want = name.toLowerCase();
	var found = $();
	$(root).find('input, textarea, select, [contenteditable="true"], [contenteditable=""]').each(function () {
		if (found.length) { return false; }
		if (pageAgentLabel(this).toLowerCase() === want) { found = $(this); }
	});
	return found;
}

function pageAgentFlash(el) {
	var $e = $(el);
	if (!$e.length) { return; }
	try { el.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); } catch (e) { el.scrollIntoView(); }
	var before = $e.css('outline');
	$e.css('outline', '2px solid #3aa757');
	setTimeout(function () { $e.css('outline', before); }, 1400);
}

// Put a value into one control the way a person would: the native setter so a
// framework observing the property sees it, then input and change so the app's
// own handlers run (JawnOS forms save from those).
function pageAgentSet(el, value) {
	var $e = $(el);
	var kind = pageAgentKind(el);
	value = (value == null) ? '' : String(value);
	// a password is never written by the agent, whatever the model asks
	if (kind === 'password') { return false; }
	if (kind === 'checkbox') {
		var on = /^(1|true|yes|on|checked)$/i.test($.trim(value));
		if ($e.prop('checked') !== on) { $e.prop('checked', on).trigger('change'); }
		return true;
	}
	if (kind === 'radio') {
		var want = $.trim(value).toLowerCase();
		if (!want || want === 'yes' || want === 'true' || want === 'on' || want === 'checked') {
			$e.prop('checked', true).trigger('change');
			return true;
		}
		if ((String(el.value || '').toLowerCase() === want) || (pageAgentLabel(el).toLowerCase() === want)) {
			$e.prop('checked', true).trigger('change');
			return true;
		}
		return false;
	}
	if (kind === 'select') {
		var target = $.trim(value).toLowerCase();
		var pick = null;
		$e.find('option').each(function () {
			if (pick) { return; }
			var v = String($(this).val() == null ? '' : $(this).val()).toLowerCase();
			var t = $.trim($(this).text()).toLowerCase();
			if (v === target || t === target) { pick = $(this); }
		});
		if (!pick && target) {
			$e.find('option').each(function () {
				if (pick) { return; }
				var t = $.trim($(this).text()).toLowerCase();
				if (t && t.indexOf(target) >= 0) { pick = $(this); }
			});
		}
		if (!pick) { return false; }
		$e.val(pick.val()).trigger('change');
		return true;
	}
	if (el.readOnly) { return false; }
	if (el.isContentEditable) {
		el.textContent = value;
		$e.trigger('input').trigger('change');
		return true;
	}
	var proto = (el.tagName === 'TEXTAREA') ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
	try {
		var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
		setter.call(el, value);
	} catch (e) { el.value = value; }
	$e.trigger('input').trigger('change');
	return true;
}

function pageAgentFindButton(root, name) {
	name = $.trim(String(name == null ? '' : name));
	if (!name) { return $(); }
	var hit = $(root).find('[data-page-agent-button="' + pageAgentEsc(name) + '"]').first();
	if (hit.length) { return hit; }
	var want = name.toLowerCase();
	var found = $();
	$(root).find('button, input[type="button"], input[type="submit"], [role="button"], span.button, span.internet_tab').each(function () {
		if (found.length || !$(this).is(':visible') || this.disabled) { return; }
		if ($(this).closest('.top_navbar').length) { return; }
		if ($(this).closest('.assistant_view').length) { return; }
		var label = $.trim($(this).is('input') ? ($(this).val() || '') : $(this).text()).replace(/\s+/g, ' ');
		var hint = $(this).attr('hint') || $(this).attr('title') || '';
		if (label.toLowerCase() === want || hint.toLowerCase() === want) { found = $(this); }
	});
	return found;
}

// Execute one page action and report back through cb(observation, friendly).
// friendly is left out so the guide gets the observation and chooses its next
// step: it can read, then fill, then press Save, in that order.
function pageAgentDo(a, cb) {
	a = a || {};
	var panel = jawnos_page_agent_panel;
	var root = pageAgentRoot(panel);
	var op = String(a.do || a.operation || 'read').toLowerCase();
	if (op === 'describe' || op === 'list') {
		var snap = pageAgentSnapshot(panel);
		var bits = [];
		(snap.fields || []).forEach(function (f) {
			bits.push(f.field + ' "' + f.label + '"' + (f.value ? (' = "' + f.value + '"') : ''));
		});
		cb(bits.length ? ('Fields: ' + bits.join('; ') + '.') : 'There are no fields on this page.');
		return;
	}
	if (op === 'press' || op === 'click') {
		var target = a.target || a.field || a.label || '';
		var button = pageAgentFindButton(root, target);
		if (!button.length) { cb('I could not find a button called "' + target + '" on this page.'); return; }
		var press_label = $.trim(button.text() || button.val() || target).slice(0, 60);
		var press_hint = button.attr('hint') || button.attr('title') || '';
		// A page button acts at once, so the page cannot stage a send, a payment
		// or a delete the way the Guide's own verbs do. Refuse those in code, not
		// only in the prompt.
		if (/\b(send|pay|buy|purchase|checkout|transfer|withdraw|donate|subscribe|delete|remove)\b/i.test(press_label + ' ' + press_hint)) {
			cb('I will not press "' + press_label + '" - sending, paying and deleting are not mine to do. I can fill the form, or press its save button instead.');
			return;
		}
		button.trigger('click');
		setTimeout(function () { cb('Pressed "' + press_label + '".'); }, 250);
		return;
	}
	// read: one field (target) or every field
	if (op === 'read' || op === 'get') {
		if (a.target || a.field) {
			var one = pageAgentFindField(root, a.target || a.field);
			if (!one.length) { cb('I could not find that field on this page.'); return; }
			var kind = pageAgentKind(one[0]);
			var v = kind === 'checkbox' ? (one.prop('checked') ? 'checked' : '')
				: (kind === 'select' ? $.trim(one.find('option:selected').text())
				: String(one.val() == null ? '' : one.val()));
			cb('"' + pageAgentLabel(one[0]) + '" is "' + v + '".', '"' + pageAgentLabel(one[0]) + '" is "' + v + '".');
			return;
		}
		var snap2 = pageAgentSnapshot(panel);
		var lines = (snap2.fields || []).map(function (f) { return f.label + ' (' + f.field + ') = "' + f.value + '"'; });
		cb(lines.length ? ('The page has: ' + lines.join('; ') + '.') : 'There are no fields on this page.');
		return;
	}
	// fill
	var list = a.fields;
	if (list && typeof list === 'object' && !$.isArray(list)) {
		var map = [];
		Object.keys(list).forEach(function (k) { map.push({ field: k, value: list[k] }); });
		list = map;
	}
	if (!$.isArray(list)) {
		list = [];
		if (a.field != null) { list.push({ field: a.field, value: a.value }); }
	}
	var filled = [], missed = [];
	list.forEach(function (row) {
		if (!row || typeof row !== 'object') { return; }
		var name = row.field || row.target || row.label || row.name || '';
		var el = pageAgentFindField(root, name);
		if (!el.length) { missed.push(name); return; }
		if (el[0].readOnly) { missed.push(name + ' (read only)'); return; }
		if (pageAgentSet(el[0], row.value)) {
			pageAgentFlash(el[0]);
			filled.push(pageAgentLabel(el[0]) || name);
		}
		else { missed.push(name); }
	});
	var obs = '';
	if (filled.length) { obs += 'Filled ' + filled.length + ' field' + (filled.length === 1 ? '' : 's') + ': ' + filled.join(', ') + '.'; }
	if (missed.length) { obs += (obs ? ' ' : '') + 'I could not fill: ' + missed.join(', ') + '.'; }
	if (!obs) { obs = 'I did not have a field to fill there.'; }
	cb(obs);
}

// ---- wiring ---------------------------------------------------------------

$(document).on('click', '.page_agent_button', function (e) {
	e.stopPropagation();
	pageAgentOpen($(this).attr('app') || '', $(this).attr('timestamp') || '');
});
