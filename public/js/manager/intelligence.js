// The Intelligence app: the house's AI token ledger, read-only except for the
// evaluation cadence and weekdays, as five pills in one window - Overview,
// Agents, Evaluations, Providers and History. The server draws every panel and
// every History range in the one request; this script swaps what is shown,
// filters the evaluation rows, sorts the evaluation table, remembers the pill
// and range a person left, and sends a frequency or weekday change through the
// app's one cadence route.
var intelligenceSectionKey = 'intelligence_section';
var intelligenceSectionDefault = 'overview';
var intelligenceHistoryKey = 'intelligence_history_range';
var intelligenceHistoryDefault = '7d';

$(document).on('click', '#intelligence_toggle, .intelligence_toggle', function() {
	intelligenceOpener();
});

function intelligenceOpener(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/intelligence',
		type: 'GET',
		data: { timestamp: timestamp, user_agent: navigator.userAgent },
		success: function(response) {
			if (!response) { return; }
			windowMaker(response.window || response);
			intelligenceRestore();
		}
	});
}

// --- the section pills -------------------------------------------------------
// One section at a time, scrolled sideways on a narrow window rather than
// wrapped, and the section left is remembered in this browser.
function intelligenceSectionNames() {
	var names = [];
	$('#intelligence .intelligence_section_pill').each(function() {
		var name = $(this).attr('data-section');
		if (name) { names.push(name); }
	});
	return names;
}

function intelligenceSectionShow(name, remember) {
	var names = intelligenceSectionNames();
	if (!names.length) { return; }
	if ($.inArray(name, names) < 0) { name = intelligenceSectionDefault; }
	if ($.inArray(name, names) < 0) { name = names[0]; }
	$('#intelligence .intelligence_section_pill').each(function() {
		var on = $(this).attr('data-section') == name;
		$(this).toggleClass('is-active', on).attr('aria-selected', on ? 'true' : 'false');
	});
	$('#intelligence .intelligence_section').each(function() {
		var on = $(this).attr('data-section') == name;
		$(this).toggleClass('is-active', on).prop('hidden', !on);
	});
	if (remember) {
		try { localStorage.setItem(intelligenceSectionKey, name); } catch (e) {}
	}
}

function intelligenceSectionRestore() {
	var name = '';
	try { name = localStorage.getItem(intelligenceSectionKey) || ''; } catch (e) { name = ''; }
	intelligenceSectionShow(name, false);
}

// --- the History ranges ------------------------------------------------------
function intelligenceHistoryNames() {
	var names = [];
	$('#intelligence .intelligence_filter_pill[data-history-range]').each(function() {
		var name = $(this).attr('data-history-range');
		if (name) { names.push(name); }
	});
	return names;
}

function intelligenceHistoryShow(range, remember) {
	var names = intelligenceHistoryNames();
	if (!names.length) { return; }
	if ($.inArray(range, names) < 0) { range = intelligenceHistoryDefault; }
	if ($.inArray(range, names) < 0) { range = names[0]; }
	$('#intelligence .intelligence_filter_pill[data-history-range]').each(function() {
		$(this).toggleClass('is-active', $(this).attr('data-history-range') == range);
	});
	$('#intelligence .intelligence_history_panel').each(function() {
		$(this).toggleClass('is-active', $(this).attr('data-history-range-panel') == range);
	});
	if (remember) {
		try { localStorage.setItem(intelligenceHistoryKey, range); } catch (e) {}
	}
}

function intelligenceHistoryRestore() {
	var range = '';
	try { range = localStorage.getItem(intelligenceHistoryKey) || ''; } catch (e) { range = ''; }
	intelligenceHistoryShow(range, false);
}

// --- the evaluation filter ---------------------------------------------------
// Each scope wears one state; a pill shows only the rows of that state, while
// All shows every row.
function intelligenceEvalFilter(state) {
	if (!state) { state = 'all'; }
	$('#intelligence .intelligence_filter_pill[data-eval-filter]').each(function() {
		$(this).toggleClass('is-active', $(this).attr('data-eval-filter') == state);
	});
	$('#intelligence tr[data-eval-state]').each(function() {
		$(this).toggle(state == 'all' || $(this).attr('data-eval-state') == state);
	});
}

// --- changing a scope's frequency -------------------------------------------
// The cadence setting, the weekdays and the Minion schedule are one thing: the
// route saves any weekdays in the same request and calls evaluation_cadence_apply,
// then answers with what now exists, not what was asked for.
function intelligenceNote(text) {
	var note = $('#intelligence .intelligence_note').first();
	if (!note.length) { return; }
	note.text(text || '');
}

function intelligenceCadenceSave(scope, cadence, days) {
	if (!scope) { return; }
	intelligenceNote('');
	var payload = { app: scope, cadence: cadence };
	if (typeof days !== 'undefined') { payload.days = days; }
	$.ajax({
		url: '/manager/intelligence/cadence',
		type: 'POST',
		dataType: 'json',
		data: payload,
		success: function(response) {
			var row = $('#intelligence .intelligence_cadence').filter(function() {
				return $(this).attr('data-scope') === scope;
			}).first().closest('tr');
			if (response && typeof response.days !== 'undefined') {
				var keep = String(response.days).split(',').filter(function(v) { return v !== '' && v !== 'none'; });
				intelligenceDaysPaint(row.find('.intelligence_days_button'), keep);
				row.children('td').eq(2).attr('data-sort', row.find('.intelligence_days_button').text().toLowerCase());
				if (intelligenceDaysOwner && intelligenceDaysOwner.closest('tr')[0] === row[0]) { intelligenceDaysCheck(keep); }
			}
			if (response && (response.ok === 0 || response.ok === 'no')) {
				if (response.cadence) { row.find('.intelligence_cadence').val(response.cadence); }
				intelligenceNote(response.error || jawnosT('Could not change the evaluation frequency.'));
				return;
			}
			var now = (response && response.cadence) ? response.cadence : cadence;
			row.find('.intelligence_cadence').val(now);
			var daysOn = (now === 'daily' || now === 'weekly');
			// The weekday picker is only a second control when it applies: an off,
			// hourly or monthly scope cannot have weekdays, so it shows a dash. The
			// cell stays in the table so every column keeps its own header.
			row.find('.intelligence_days_button').prop('disabled', !daysOn).prop('hidden', !daysOn);
			row.find('.intelligence_days_none').prop('hidden', daysOn);
			if (!daysOn) { intelligenceDaysClose(); }
			row.children('td').eq(1).attr('data-sort', row.find('.intelligence_cadence option:selected').text().toLowerCase());
			row.children('td').eq(2).attr('data-sort', daysOn ? row.find('.intelligence_days_button').text().toLowerCase() : '—');
			row.children('td').eq(3).attr('data-sort', (response && response.next_run) ? response.next_run : 9999999999999);
			var next = row.find('.intelligence_next_run').first();
			if (response && response.next_run) {
				next.text(new Date(response.next_run * 1000).toLocaleString());
			}
			else {
				next.text('—');
			}
			var state = (now === 'off') ? 'idle' : ((now === 'each_run') ? 'on_demand' : 'scheduled');
			row.attr('data-eval-state', state);
			var active = $('#intelligence .intelligence_filter_pill[data-eval-filter].is-active').attr('data-eval-filter') || 'all';
			intelligenceEvalFilter(active);
		},
		error: function() {
			intelligenceNote(jawnosT('Could not change the evaluation frequency.'));
		}
	});
}

$(document).on('change', '#intelligence .intelligence_cadence', function() {
	var pick = $(this);
	intelligenceCadenceSave(pick.attr('data-scope'), pick.val());
});

// --- the weekdays, as one multiselect dropdown -------------------------------
// The trigger shows the chosen days (Sun, Mon, ...); the menu holds a checkbox
// per day. It sends one cadence request per press, so the saved weekdays and
// the rebuilt schedule stay one. The menu is fixed-positioned inside the app,
// so the table's scroll box cannot clip it.
var intelligenceDayLabels = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
var intelligenceEveryDayLabel = 'Every day';
var intelligenceDaysMenu = null;
var intelligenceDaysOwner = null;

function intelligenceDayShort(index) {
	var label = intelligenceDayLabels[index] || ('Day ' + index);
	return label.substring(0, 3);
}

function intelligenceDayLabelsLoad() {
	var section = $('#intelligence_section_evaluations');
	var raw = section.attr('data-day-labels') || '';
	if (raw) {
		var labels = raw.split('|');
		if (labels.length === 7) { intelligenceDayLabels = labels; }
	}
	var every = section.attr('data-every-day') || '';
	if (every) { intelligenceEveryDayLabel = every; }
}

function intelligenceDaysText(days) {
	if (!days || !days.length) { return '—'; }
	if (days.length === 7) { return intelligenceEveryDayLabel; }
	return $.map(days.slice().sort(function(a, b) { return a - b; }), function(d) {
		return intelligenceDayShort(parseInt(d, 10));
	}).join(', ');
}

function intelligenceDaysPaint(button, days) {
	button = $(button);
	if (!button.length) { return; }
	days = $.map(days || [], function(d) { return String(d); }).filter(function(d) { return d !== ''; });
	button.attr('data-days', days.join(',')).text(intelligenceDaysText(days));
}

function intelligenceDaysCheck(days) {
	if (!intelligenceDaysMenu) { return; }
	intelligenceDaysMenu.find('input[type=checkbox]').each(function() {
		$(this).prop('checked', $.inArray(String($(this).val()), days) >= 0);
	});
}

function intelligenceDaysClose() {
	if (intelligenceDaysMenu) { intelligenceDaysMenu.remove(); intelligenceDaysMenu = null; }
	if (intelligenceDaysOwner) { intelligenceDaysOwner.attr('aria-expanded', 'false'); intelligenceDaysOwner = null; }
}

function intelligenceDaysOpen(button) {
	intelligenceDaysClose();
	var selected = String(button.attr('data-days') || '').split(',').filter(function(v) { return v !== ''; });
	var menu = $('<div class="intelligence_days_menu" role="listbox" aria-multiselectable="true"></div>');
	for (var d = 0; d < 7; d++) {
		var label = $('<label class="intelligence_days_option"></label>');
		var box = $('<input type="checkbox">').attr('value', d).prop('checked', $.inArray(String(d), selected) >= 0);
		label.append(box).append($('<span></span>').text(intelligenceDayLabels[d] || ('Day ' + d)));
		menu.append(label);
	}
	$('#intelligence').append(menu);
	var rect = button[0].getBoundingClientRect();
	var top = rect.bottom + 2;
	var left = rect.left;
	var width = menu.outerWidth();
	var height = menu.outerHeight();
	if (left + width > window.innerWidth - 8) { left = Math.max(8, window.innerWidth - width - 8); }
	if (top + height > window.innerHeight - 8) { top = Math.max(8, rect.top - height - 2); }
	menu.css({ position: 'fixed', top: top, left: left, zIndex: 100000 });
	button.attr('aria-expanded', 'true');
	intelligenceDaysMenu = menu;
	intelligenceDaysOwner = button;
}

$(document).on('click', '#intelligence .intelligence_days_button', function(event) {
	event.stopPropagation();
	var button = $(this);
	if (button.prop('disabled')) { return; }
	if (intelligenceDaysOwner && intelligenceDaysOwner[0] === button[0]) { intelligenceDaysClose(); return; }
	intelligenceDaysOpen(button);
});

$(document).on('change', '#intelligence .intelligence_days_menu input[type=checkbox]', function() {
	if (!intelligenceDaysOwner) { return; }
	var button = intelligenceDaysOwner;
	var days = [];
	intelligenceDaysMenu.find('input:checked').each(function() { days.push(String($(this).val())); });
	intelligenceDaysPaint(button, days);
	var cadence = button.closest('tr').find('.intelligence_cadence').val() || 'off';
	intelligenceCadenceSave(button.attr('data-scope'), cadence, days.length ? days.join(',') : 'none');
});

$(document).on('click', function(event) {
	if (!intelligenceDaysMenu) { return; }
	if ($(event.target).closest('.intelligence_days_menu, .intelligence_days_button').length) { return; }
	intelligenceDaysClose();
});
$(document).on('keydown', function(event) {
	if (event.key === 'Escape') { intelligenceDaysClose(); }
});
document.addEventListener('scroll', function() { intelligenceDaysClose(); }, true);
$(window).on('resize', function() { intelligenceDaysClose(); });

// --- sorting the Evaluations table -------------------------------------------
// Every header cell sorts its column; pressing it again reverses the order. The
// server puts data-sort on each cell (a lowercased label, an epoch, or a raw
// number), so a token count sorts as a number and a next-run sorts by the
// moment it will happen rather than by its printed text.
var intelligenceSortKey = 'intelligence_sort';
function intelligenceSortState() {
	try { var raw = localStorage.getItem(intelligenceSortKey); return raw ? JSON.parse(raw) : null; } catch (e) { return null; }
}
function intelligenceSortSave(key, direction) {
	if (!key) { return; }
	try { localStorage.setItem(intelligenceSortKey, JSON.stringify({ key: key, dir: direction })); } catch (e) {}
}
function intelligenceSortRestore() {
	var state = intelligenceSortState();
	if (!state || !state.key) { return; }
	var th = $('#intelligence_section_evaluations th[data-sort-key="' + state.key + '"]').first();
	if (!th.length) { return; }
	intelligenceSort(th, state.dir === 'desc' ? 'desc' : 'asc');
}
function intelligenceSort(th, direction) {
	var table = th.closest('table');
	var body = table.find('tbody');
	var column = th[0].cellIndex;
	var type = th.attr('data-sort-type') || 'text';
	var previous = th.attr('data-sort-dir');
	direction = (direction === 'asc' || direction === 'desc') ? direction : (previous === 'asc' ? 'desc' : 'asc');
	table.find('th').removeAttr('data-sort-dir');
	th.attr('data-sort-dir', direction);
	intelligenceSortSave(th.attr('data-sort-key'), direction);
	var rows = body.children('tr').get();
	rows.sort(function(a, b) {
		var aCell = $(a).children('td').eq(column);
		var bCell = $(b).children('td').eq(column);
		var aValue = aCell.attr('data-sort');
		var bValue = bCell.attr('data-sort');
		if (typeof aValue === 'undefined') { aValue = aCell.text(); }
		if (typeof bValue === 'undefined') { bValue = bCell.text(); }
		var compare;
		if (type === 'num') {
			compare = parseFloat(aValue || 0) - parseFloat(bValue || 0);
		}
		else {
			compare = String(aValue).localeCompare(String(bValue), undefined, { numeric: true, sensitivity: 'base' });
		}
		if (compare === 0) {
			var aScope = $(a).children('td').eq(0).attr('data-sort') || '';
			var bScope = $(b).children('td').eq(0).attr('data-sort') || '';
			compare = String(aScope).localeCompare(String(bScope));
		}
		return direction === 'asc' ? compare : -compare;
	});
	body.append(rows);
}

$(document).on('click', '#intelligence_section_evaluations th.intelligence_sort', function() {
	intelligenceSort($(this));
});

$(document).on('keydown', '#intelligence_section_evaluations th.intelligence_sort', function(event) {
	if (event.key === 'Enter' || event.key === ' ') {
		event.preventDefault();
		intelligenceSort($(this));
	}
});

// --- spreading the schedules ---------------------------------------------
// The button asks the server to give every timed scope its own day and time,
// weighted by the tokens it spends. The window refreshes with its own stamp, so
// the place it was put, the remembered pill and the remembered sort stay put.
var intelligenceSpreadPending = '';

function intelligenceSpreadNoteShow() {
	if (!intelligenceSpreadPending) { return; }
	intelligenceNote(intelligenceSpreadPending);
	intelligenceSpreadPending = '';
}

$(document).on('click', '#intelligence .intelligence_spread_button', function() {
	var button = $(this);
	if (button.prop('disabled')) { return; }
	button.prop('disabled', true);
	intelligenceNote(jawnosT('Spreading the evaluations...'));
	$.ajax({
		url: '/manager/intelligence/spread',
		type: 'POST',
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			if (response && (response.ok === 0 || response.ok === 'no')) {
				intelligenceNote(response.error || jawnosT('Could not spread the evaluations.'));
				return;
			}
			intelligenceSpreadPending = (response && response.summary) ? response.summary : '';
			var wind = $('#intelligence').closest('.wind');
			var stamp = wind.length ? parseInt(wind.attr('timestamp'), 10) : NaN;
			intelligenceOpener(isFinite(stamp) ? stamp : Date.now());
		},
		error: function() {
			button.prop('disabled', false);
			intelligenceNote(jawnosT('Could not spread the evaluations.'));
		}
	});
});

// --- the Rules pill ---------------------------------------------------------
// The Guide's behavioural rules and runtime commands are one house setting each
// (guide_rules, guide_verbs), and the server draws them as readable rows. This
// script adds, edits and deletes one entry at a time, then writes the whole list
// back through the shared setting writer. It starts from the rendered entry, so
// a field the panel does not understand rides along untouched.
var intelligenceRulesNotePending = '';

function intelligenceRulesReload() {
	var wind = $('#intelligence').closest('.wind');
	var stamp = wind.length ? parseInt(wind.attr('timestamp'), 10) : NaN;
	intelligenceOpener(isFinite(stamp) ? stamp : Date.now());
}

function intelligenceRulesNote(text) {
	var note = $('#intelligence_rules_note');
	if (note.length && text) { note.text(text); }
}

function intelligenceRulesNoteShow() {
	if (!intelligenceRulesNotePending) { return; }
	intelligenceRulesNote(intelligenceRulesNotePending);
	intelligenceRulesNotePending = '';
}

function intelligenceListEntries(listSelector) {
	var rows = [];
	$(listSelector).find('[data-entry]').each(function() {
		var raw = $(this).attr('data-entry');
		try { rows.push(JSON.parse(raw)); }
		catch (e) { rows.push(raw); }
	});
	return rows;
}

function intelligenceRulesEntries() {
	return intelligenceListEntries('#intelligence .intelligence_rule_list');
}

function intelligenceCommandsEntries() {
	return intelligenceListEntries('#intelligence .intelligence_command_list');
}

function intelligenceRulesWrite(rows) {
	return settingSetter({ app: '__president', setting: 'guide_rules', device: 'all', value: JSON.stringify(rows, null, 2) });
}

function intelligenceCommandsWrite(rows) {
	return settingSetter({ app: '__president', setting: 'guide_verbs', device: 'all', value: JSON.stringify(rows, null, 2) });
}

function intelligenceRuleTriggers(value) {
	return String(value || '').split(',').map(function(w) { return $.trim(w); }).filter(function(w) { return w.length; });
}

function intelligenceRuleFormReset() {
	$('#intelligence_rule_match, #intelligence_rule_text, #intelligence_rule_app, #intelligence_rule_when').val('');
	$('#intelligence_rule_index').val('');
	$('#intelligence_rule_save').text($('#intelligence_rule_save').attr('data-add-label') || jawnosT('Add rule'));
	$('#intelligence_rule_cancel').prop('hidden', true);
}

function intelligenceCommandFormReset() {
	$('#intelligence_command_name, #intelligence_command_desc, #intelligence_command_params').val('');
	$('#intelligence_command_primitive').val('say');
	$('#intelligence_command_index').val('');
	$('#intelligence_command_save').text($('#intelligence_command_save').attr('data-add-label') || jawnosT('Add command'));
	$('#intelligence_command_cancel').prop('hidden', true);
}

function intelligenceCommandPrimitive(entry) {
	if (!entry || typeof entry !== 'object') { return ''; }
	var p = entry.primitive;
	if (p && typeof p === 'object') { return String(p.name || ''); }
	return (typeof p === 'string') ? p : '';
}

function intelligenceCommandParams(entry) {
	if (!entry || typeof entry !== 'object') { return {}; }
	var p = entry.primitive;
	if (p && typeof p === 'object' && p.params && typeof p.params === 'object') { return p.params; }
	if (entry.params && typeof entry.params === 'object') { return entry.params; }
	return {};
}

// --- editing a rule ---------------------------------------------------------
$(document).on('click', '#intelligence .intelligence_edit[data-kind="rule"]', function() {
	var index = parseInt($(this).attr('data-index'), 10);
	var entries = intelligenceRulesEntries();
	var entry = entries[index];
	if (!entry || typeof entry !== 'object') { return; }
	$('#intelligence_rule_match').val($.isArray(entry.match) ? entry.match.join(', ') : (typeof entry.match === 'string' ? entry.match : ''));
	$('#intelligence_rule_text').val(typeof entry.rule === 'string' ? entry.rule : '');
	$('#intelligence_rule_app').val(typeof entry.app === 'string' ? entry.app : '');
	$('#intelligence_rule_when').val(typeof entry.when === 'string' ? entry.when : '');
	$('#intelligence_rule_index').val(String(index));
	$('#intelligence_rule_save').text(jawnosT('Save changes'));
	$('#intelligence_rule_cancel').prop('hidden', false);
	$('#intelligence_rule_match').trigger('focus');
});

$(document).on('click', '#intelligence_rule_cancel', function() {
	intelligenceRuleFormReset();
});

$(document).on('submit', '#intelligence_rule_form', function(event) {
	event.preventDefault();
	var triggers = intelligenceRuleTriggers($('#intelligence_rule_match').val());
	var rule = $.trim($('#intelligence_rule_text').val() || '');
	if (!triggers.length) { intelligenceRulesNote(jawnosT('Give the rule the words that call it up.')); return; }
	if (!rule.length) { intelligenceRulesNote(jawnosT('Give the rule a short sentence.')); return; }
	var app = $.trim($('#intelligence_rule_app').val() || '');
	var when = $.trim($('#intelligence_rule_when').val() || '');
	var entries = intelligenceRulesEntries();
	var index = $('#intelligence_rule_index').val();
	var entry;
	if (index !== '') {
		entry = entries[parseInt(index, 10)];
		if (!entry || typeof entry !== 'object') { entry = {}; entries[parseInt(index, 10)] = entry; }
	}
	else {
		entry = {};
		entries.push(entry);
	}
	entry.match = triggers;
	entry.rule = rule;
	if (app.length) { entry.app = app; } else { delete entry.app; }
	if (when.length) { entry.when = when; } else { delete entry.when; }
	intelligenceRulesNote(jawnosT('Saving...'));
	intelligenceRulesWrite(entries).then(function() {
		intelligenceRulesNotePending = jawnosT('Rule saved.');
		intelligenceRuleFormReset();
		intelligenceRulesReload();
	}, function() {
		intelligenceRulesNote(jawnosT('Could not save the rules.'));
	});
});

$(document).on('click', '#intelligence .intelligence_delete[data-kind="rule"]', function() {
	var index = parseInt($(this).attr('data-index'), 10);
	jawnosConfirm(jawnosT('Delete this rule?'), function() {
		var entries = intelligenceRulesEntries();
		if (!(index >= 0 && index < entries.length)) { return; }
		entries.splice(index, 1);
		intelligenceRulesWrite(entries).then(function() {
			intelligenceRulesNotePending = jawnosT('Rule deleted.');
			intelligenceRulesReload();
		}, function() {
			intelligenceRulesNote(jawnosT('Could not save the rules.'));
		});
	});
});

// --- editing a command ------------------------------------------------------
$(document).on('click', '#intelligence .intelligence_edit[data-kind="command"]', function() {
	var index = parseInt($(this).attr('data-index'), 10);
	var entries = intelligenceCommandsEntries();
	var entry = entries[index];
	if (!entry || typeof entry !== 'object') { return; }
	var params = intelligenceCommandParams(entry);
	$('#intelligence_command_name').val(typeof entry.name === 'string' ? entry.name : '');
	$('#intelligence_command_desc').val(typeof entry.desc === 'string' ? entry.desc : '');
	$('#intelligence_command_primitive').val(intelligenceCommandPrimitive(entry) || 'say');
	$('#intelligence_command_params').val(Object.keys(params).length ? JSON.stringify(params, null, 2) : '');
	$('#intelligence_command_index').val(String(index));
	$('#intelligence_command_save').text(jawnosT('Save changes'));
	$('#intelligence_command_cancel').prop('hidden', false);
	$('#intelligence_command_name').trigger('focus');
});

$(document).on('click', '#intelligence_command_cancel', function() {
	intelligenceCommandFormReset();
});

$(document).on('submit', '#intelligence_command_form', function(event) {
	event.preventDefault();
	var name = $.trim($('#intelligence_command_name').val() || '');
	if (!/^[a-z][a-z0-9_]{1,40}$/.test(name)) { intelligenceRulesNote(jawnosT('A command name is lowercase letters, digits and underscores.')); return; }
	var desc = $.trim($('#intelligence_command_desc').val() || '');
	var primitive = $('#intelligence_command_primitive').val() || 'say';
	var paramsText = $.trim($('#intelligence_command_params').val() || '');
	var params = {};
	if (paramsText.length) {
		try { params = JSON.parse(paramsText); }
		catch (e) { intelligenceRulesNote(jawnosT('The parameters are not valid JSON.')); return; }
		if (!params || typeof params !== 'object' || $.isArray(params)) { intelligenceRulesNote(jawnosT('The parameters must be a JSON object.')); return; }
	}
	var entries = intelligenceCommandsEntries();
	var index = $('#intelligence_command_index').val();
	var entry;
	if (index !== '') {
		entry = entries[parseInt(index, 10)];
		if (!entry || typeof entry !== 'object') { entry = {}; entries[parseInt(index, 10)] = entry; }
	}
	else {
		entry = {};
		entries.push(entry);
	}
	entry.name = name;
	entry.desc = desc;
	if (entry.primitive && typeof entry.primitive === 'object') {
		entry.primitive.name = primitive;
		entry.primitive.params = params;
	}
	else {
		entry.primitive = primitive;
		entry.params = params;
	}
	intelligenceRulesNote(jawnosT('Saving...'));
	intelligenceCommandsWrite(entries).then(function() {
		intelligenceRulesNotePending = jawnosT('Command saved.');
		intelligenceCommandFormReset();
		intelligenceRulesReload();
	}, function() {
		intelligenceRulesNote(jawnosT('Could not save the commands.'));
	});
});

$(document).on('click', '#intelligence .intelligence_delete[data-kind="command"]', function() {
	var index = parseInt($(this).attr('data-index'), 10);
	jawnosConfirm(jawnosT('Delete this command?'), function() {
		var entries = intelligenceCommandsEntries();
		if (!(index >= 0 && index < entries.length)) { return; }
		entries.splice(index, 1);
		intelligenceCommandsWrite(entries).then(function() {
			intelligenceRulesNotePending = jawnosT('Command deleted.');
			intelligenceRulesReload();
		}, function() {
			intelligenceRulesNote(jawnosT('Could not save the commands.'));
		});
	});
});

function intelligenceRestore() {
	intelligenceSectionRestore();
	intelligenceHistoryRestore();
	intelligenceEvalFilter('all');
	intelligenceDayLabelsLoad();
	intelligenceDaysClose();
	intelligenceSortRestore();
	intelligenceSpreadNoteShow();
	intelligenceRulesNoteShow();
}

// --- provider balances in the chosen currency --------------------------------
// The Providers panel reuses Configure's currency_amount include, so each
// balance carries its house-currency figure and a picker of the loaded rates.
// Configure's own handler is only bound once that app has been opened, so the
// Intelligence window converts from the same data itself.
function intelligenceCurrencyValue(value) {
	if (!isFinite(value)) { return ''; }
	var abs = Math.abs(value);
	return (abs > 0 && abs < 0.1) ? value.toFixed(4) : value.toFixed(2);
}

$(document).on('change', '#intelligence .currency_picker', function() {
	var select = this;
	var option = select.options[select.selectedIndex];
	var rate = option ? parseFloat(option.getAttribute('data-rate')) : NaN;
	var amount = $(select).closest('.currency_amount');
	var base = parseFloat(amount.attr('data-base-amount'));
	if (!isFinite(rate) || !isFinite(base)) { return; }
	amount.find('.currency_value').text(intelligenceCurrencyValue(base * rate));
});

$(document).on('click', '#intelligence .intelligence_section_pill', function() {
	intelligenceSectionShow($(this).attr('data-section'), true);
});

$(document).on('click', '#intelligence .intelligence_filter_pill[data-history-range]', function() {
	intelligenceHistoryShow($(this).attr('data-history-range'), true);
});

$(document).on('click', '#intelligence .intelligence_filter_pill[data-eval-filter]', function() {
	intelligenceEvalFilter($(this).attr('data-eval-filter'));
});
