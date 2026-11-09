// ---- weather automations ----------------------------------------------------
// The old weather web-measure app kept rules such as "condition contains rain
// -> start raining". The Weather app now records the condition for the house's
// own coordinate, and this tab edits the same rule list.
var weatherAutomationLoaded = false;
var weatherAutomationData = null;
// The rule-location key the tab is showing (the place the toolbar is on).
var weatherAutomationView = '';

function weatherAutomationDevice() {
	var $w = $('.wind[app="weather"]').last();
	return $w.find('#weather_device').val() || 'me';
}

$(document).on('click', '#weather_automation_add', function() {
	weatherAutomationFormOpen();
});
$(document).on('click', '#weather_automation_cancel', function() {
	weatherAutomationFormClose();
});
$(document).on('click', '#weather_automation_save', function() {
	weatherAutomationSave();
});
$(document).on('click', '#weather_automation_check', function() {
	weatherAutomationCheck();
});
$(document).on('click', '.weather_automation_edit', function() {
	weatherAutomationEdit($(this).attr('data-uuid'));
});
$(document).on('click', '.weather_automation_remove', function() {
	weatherAutomationRemove($(this).attr('data-uuid'));
});
$(document).on('click', '.weather_location_delete', function() {
	var $w = $('.wind[app="weather"]').last();
	var target = $(this).attr('data-target') || '';
	var uuid = $w.find('#' + target).val() || '';
	var status = target === 'weather_measure_location' ? '#weather_measure_status' : '#weather_automation_status';
	weatherLocationDelete(uuid, this, status);
});
$(document).on('change', '#weather_automation_location, #weather_measure_location', function() {
	if (typeof weatherDeleteState === 'function') { weatherDeleteState(); }
});

function weatherAutomationLoad(message) {
	var $w = $('.wind[app="weather"]').last();
	if (!$w.length) { return; }
	$w.find('#weather_automation_status').text(jawnosT('Loading…'));
	$.ajax({
		url: '/manager/weather/automations',
		type: 'GET',
		data: { device: weatherAutomationDevice() },
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				weatherAutomationError((response && response.error) || jawnosT('Automations are unavailable.'));
				return;
			}
			weatherAutomationRender(response, message);
		},
		error: function() { weatherAutomationError(jawnosT('Automations are unavailable.')); }
	});
}

function weatherAutomationRender(data, message) {
	var $w = $('.wind[app="weather"]').last();
	weatherAutomationLoaded = true;
	weatherAutomationData = data;
	if (data.view_location !== undefined) { weatherAutomationView = data.view_location || ''; }
	weatherAutomationLocations(data);
	if (typeof weatherDeleteState === 'function') { weatherDeleteState(); }
	var condition = data.condition_text || weatherAutomationWords(data.condition || '');
	var at = data.condition_at ? ' · ' + jawnosT('checked') + ' ' + weatherTime(data.condition_at) : '';
	$w.find('#weather_automation_condition').text(condition ? (condition + at) : jawnosT('No reading yet.'));
	var $list = $w.find('#weather_automation_list').empty();
	var rules = data.rules || [];
	if (!rules.length) {
		$list.html('<div class="weather_muted" style="padding:8px;">' + weatherEsc(jawnosT('No automations yet. Add one to start an app when the weather turns.')) + '</div>');
	} else {
		for (var i = 0; i < rules.length; i++) {
			var r = rules[i] || {};
			var label = r.app_label || weatherAutomationWords(r.app || '');
			var verb = (r.action === 'record') ? jawnosT('record') : jawnosT('start');
			var where = r.location_label ? (' ' + jawnosT('at') + ' ' + r.location_label) : '';
			var html = '<div class="weather_automation_rule">'
				+ '<span class="weather_automation_text">' + weatherEsc(jawnosT('When the condition contains') + ' “' + (r.match || '') + '”' + where + ', ' + verb + ' ') + '<b>' + weatherEsc(label) + '</b></span>'
				+ '<span class="weather_automation_actions">'
				+ '<button type="button" class="weather_automation_edit" data-uuid="' + weatherEsc(r.uuid || '') + '">' + jawnosT('Edit') + '</button>'
				+ '<button type="button" class="weather_automation_remove" data-uuid="' + weatherEsc(r.uuid || '') + '">' + jawnosT('Remove') + '</button>'
				+ '</span></div>';
			$list.append(html);
		}
	}
	var $seen = $w.find('#weather_automation_match_options').empty();
	var seen = data.seen || [];
	for (var j = 0; j < seen.length && j < 60; j++) {
		var text = weatherAutomationWords(seen[j]);
		if (!text) { continue; }
		$seen.append($('<option>').val(weatherAutomationKey(text)).text(text));
	}
	$w.find('#weather_automation_status').text(message || (rules.length + ' ' + jawnosT('automations')));
	weatherMeasurementRender(data);
}

function weatherAutomationError(message) {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_automation_status').text(message || '');
}

// The location picker and the app suggestions are the same for both rule forms.
function weatherAutomationLocations(data) {
	var $w = $('.wind[app="weather"]').last();
	var locations = data.locations || [];
	function fill(selector) {
		var $select = $w.find(selector);
		var current = $select.val();
		$select.empty();
		for (var i = 0; i < locations.length; i++) {
			var location = locations[i] || {};
			$select.append($('<option>').val(location.key || '').text(jawnosT(location.label || location.key || '')));
		}
		if (current !== undefined && current !== null) { $select.val(current); }
	}
	fill('#weather_automation_location');
	fill('#weather_measure_location');
	var $options = $w.find('#weather_app_options').empty();
	var apps = data.apps || [];
	for (var j = 0; j < apps.length; j++) {
		var app = apps[j] || {};
		$options.append($('<option>').val(app.key || '').attr('label', app.label || app.key || ''));
	}
}

// A rule can name a place the picker no longer lists (the device has not
// reported a fix lately). Keep that value selectable so saving an edit does
// not silently move the rule back to "Any location".
function weatherAutomationLocationSet(selector, value, label) {
	var $w = $('.wind[app="weather"]').last();
	var $select = $w.find(selector);
	value = value || '';
	if (value && $select.find('option').filter(function() { return this.value === value; }).length === 0) {
		$select.append($('<option>').val(value).text(label || value));
	}
	$select.val(value);
}

function weatherAutomationFormOpen(rule) {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_automation_uuid').val(rule ? (rule.uuid || '') : '');
	weatherAutomationLocationSet('#weather_automation_location', rule ? (rule.location || '') : weatherAutomationView, rule ? (rule.location_label || '') : '');
	if (typeof weatherDeleteState === 'function') { weatherDeleteState(); }
	$w.find('#weather_automation_match').val(rule ? (rule.match || '') : '');
	$w.find('#weather_automation_app').val(rule ? (rule.app || '') : '');
	$w.find('#weather_automation_action').val(rule && rule.action === 'record' ? 'record' : 'start');
	$w.find('#weather_automation_form').show();
	$w.find('#weather_automation_match').trigger('focus');
}

function weatherAutomationFormClose() {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_automation_form').hide();
	$w.find('#weather_automation_uuid').val('');
	$w.find('#weather_automation_match').val('');
	$w.find('#weather_automation_app').val('');
	$w.find('#weather_automation_action').val('start');
}

function weatherAutomationEdit(uuid) {
	var rules = (weatherAutomationData && weatherAutomationData.rules) || [];
	for (var i = 0; i < rules.length; i++) {
		if ((rules[i].uuid || '') === uuid) { weatherAutomationFormOpen(rules[i]); return; }
	}
}

function weatherAutomationSave() {
	var $w = $('.wind[app="weather"]').last();
	var match = $.trim($w.find('#weather_automation_match').val() || '');
	var app = $.trim($w.find('#weather_automation_app').val() || '');
	if (!match || !app) {
		weatherAutomationError(jawnosT('A rule needs a condition and an app.'));
		return;
	}
	$w.find('#weather_automation_status').text(jawnosT('Saving…'));
	$.ajax({
		url: '/manager/weather/automation',
		type: 'POST',
		data: {
			uuid: $w.find('#weather_automation_uuid').val() || '',
			device: weatherAutomationDevice(),
			location: $w.find('#weather_automation_location').val() || '',
			match: match,
			app: app,
			action: $w.find('#weather_automation_action').val() || 'start',
			timestamp: Date.now()
		},
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				weatherAutomationError((response && response.error) || jawnosT('The automation was not saved.'));
				return;
			}
			weatherAutomationFormClose();
			weatherAutomationRender(response);
			$w.find('#weather_automation_status').text(jawnosT('Saved.'));
		},
		error: function() { weatherAutomationError(jawnosT('The automation was not saved.')); }
	});
}

function weatherAutomationRemove(uuid) {
	if (!uuid) { return; }
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_automation_status').text(jawnosT('Removing…'));
	$.ajax({
		url: '/manager/weather/automation',
		type: 'POST',
		data: { uuid: uuid, device: weatherAutomationDevice(), remove: 1, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				weatherAutomationError((response && response.error) || jawnosT('The automation was not removed.'));
				return;
			}
			weatherAutomationRender(response);
			$w.find('#weather_automation_status').text(jawnosT('Removed.'));
		},
		error: function() { weatherAutomationError(jawnosT('The automation was not removed.')); }
	});
}

function weatherAutomationCheck() {
	var $w = $('.wind[app="weather"]').last();
	var button = $w.find('#weather_automation_check');
	if (button.prop('disabled')) { return; }
	button.prop('disabled', true);
	$w.find('#weather_automation_status').text(jawnosT('Checking…'));
	var data = { timestamp: Date.now() };
	if (weatherLastLocation && weatherLastLocation.lat !== undefined && weatherLastLocation.lon !== undefined) {
		data.lat = weatherLastLocation.lat;
		data.lon = weatherLastLocation.lon;
	}
	if (weatherLastLocation && weatherLastLocation.location) { data.location = weatherLastLocation.location; }
	$.ajax({
		url: '/manager/weather/observe',
		type: 'POST',
		data: data,
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				weatherAutomationError((response && response.error) || jawnosT('The weather could not be checked.'));
				return;
			}
			if (response.skipped === 'no rules') {
				$w.find('#weather_automation_status').text(jawnosT('Add a rule first.'));
				return;
			}
			if (response.skipped === 'no fix') {
				$w.find('#weather_automation_status').text(jawnosT('No recent GPS fix for this device.'));
				return;
			}
			if (response.leader === 0) {
				weatherAutomationLoad(jawnosT('Recorded here. The house server runs the automations.'));
				return;
			}
			var text = response.condition ? weatherAutomationWords(response.condition) : '';
			var matched = response.matched || [];
			var message;
			if (matched.length) {
				var names = [];
				for (var i = 0; i < matched.length; i++) { names.push(weatherAutomationWords(matched[i].app || '')); }
				message = text + ' — ' + jawnosT('started') + ' ' + names.join(', ');
			} else {
				message = text ? (text + ' — ' + jawnosT('no rule matched.')) : jawnosT('Checked.');
			}
			var fired = response.rules || [];
			if (fired.length) {
				var done = [];
				for (var k = 0; k < fired.length; k++) {
					var f = fired[k] || {};
					var verb = f.action === 'run' ? jawnosT('ran') : (f.action === 'stop' ? jawnosT('stopped') : jawnosT('started'));
					done.push(verb + ' ' + (f.name || weatherAutomationWords(f.app || '')));
				}
				message = (text ? (text + ' — ') : '') + done.join(', ');
			}
			weatherAutomationLoad(message);
		},
		error: function() { weatherAutomationError(jawnosT('The weather could not be checked.')); },
		complete: function() { button.prop('disabled', false); }
	});
}

// A stored key ("light_rain") reads as words; the service also sends a formatted
// label, so this is only the fallback and the current condition.
function weatherAutomationWords(text) {
	var t = String(text === undefined || text === null ? '' : text).replace(/_/g, ' ');
	if (!t) { return ''; }
	return t.replace(/\b\w/g, function(c) { return c.toUpperCase(); });
}

function weatherAutomationKey(text) {
	return String(text || '').toLowerCase().replace(/\s+/g, '_');
}

// ---- measurement rules ------------------------------------------------------
var weatherMeasurementData = null;

$(document).on('click', '#weather_measure_add', function() { weatherMeasureFormOpen(); });
$(document).on('click', '#weather_measure_condition_add', function() { weatherMeasureConditionAdd(null); });
$(document).on('click', '#weather_measure_save', function() { weatherMeasureSave(); });
$(document).on('click', '#weather_measure_cancel', function() { weatherMeasureFormClose(); });
$(document).on('change', '#weather_measure_action', function() { weatherMeasureActionFields(); });
$(document).on('click', '.weather_measure_edit', function() { weatherMeasureEdit($(this).attr('data-uuid')); });
$(document).on('click', '.weather_measure_remove', function() { weatherMeasureRemove($(this).attr('data-uuid')); });

function weatherMeasurementRender(data) {
	var $w = $('.wind[app="weather"]').last();
	weatherMeasurementData = data;
	var values = data.values || {};
	var catalog = data.measures || [];
	var parts = [];
	for (var i = 0; i < catalog.length && parts.length < 4; i++) {
		var def = catalog[i] || {};
		if (values[def.key] === undefined || values[def.key] === null) { continue; }
		var value = values[def.key];
		if (def.type === 'number') { value = weatherNum(value); }
		else if (def.type === 'direction') { value = String(value).toUpperCase(); }
		else { value = weatherAutomationWords(value); }
		parts.push(jawnosT(def.label) + ' ' + value + (def.unit ? ' ' + def.unit : ''));
	}
	$w.find('#weather_now_values').text(parts.length ? (jawnosT('Now') + ': ' + parts.join(' · ')) : '');
	var $list = $w.find('#weather_measure_list').empty();
	var rules = data.measure_rules || [];
	if (!rules.length) {
		$list.html('<div class="weather_muted" style="padding:8px;">' + weatherEsc(jawnosT('No measurement rules yet.')) + '</div>');
	}
	else {
		for (var j = 0; j < rules.length; j++) {
			var rule = rules[j] || {};
			var html = '<div class="weather_automation_rule">'
				+ '<span class="weather_automation_text">' + weatherEsc(weatherMeasureSentence(rule)) + '</span>'
				+ '<span class="weather_automation_actions">'
				+ '<button type="button" class="weather_measure_edit" data-uuid="' + weatherEsc(rule.uuid || '') + '">' + jawnosT('Edit') + '</button>'
				+ '<button type="button" class="weather_measure_remove" data-uuid="' + weatherEsc(rule.uuid || '') + '">' + jawnosT('Remove') + '</button>'
				+ '</span></div>';
			$list.append(html);
		}
	}
	$w.find('#weather_measure_status').text(rules.length + ' ' + jawnosT('measurement rules'));
}

function weatherMeasureDef(key) {
	var catalog = (weatherMeasurementData && weatherMeasurementData.measures) || [];
	for (var i = 0; i < catalog.length; i++) {
		if ((catalog[i].key || '') === key) { return catalog[i]; }
	}
	return null;
}

function weatherMeasureOpText(op) {
	return ({ '>=': '≥', '<=': '≤', '==': '=', '!=': '≠' })[op] || op;
}

function weatherMeasureValueText(value, def) {
	if (!def) { return String(value === undefined || value === null ? '' : value); }
	if (def.type === 'direction') { return String(value || '').toUpperCase(); }
	if (def.type === 'number') { return weatherNum(value) + (def.unit ? ' ' + def.unit : ''); }
	return weatherAutomationWords(value);
}

function weatherMeasureDurationText(ms) {
	if (!ms) { return ''; }
	if (ms % 3600000 === 0) { return (ms / 3600000) + ' ' + jawnosT('hours'); }
	return Math.round(ms / 60000) + ' ' + jawnosT('minutes');
}

function weatherMeasureSentence(rule) {
	var when = rule.when || [];
	var parts = [];
	for (var i = 0; i < when.length; i++) {
		var condition = when[i] || {};
		var def = weatherMeasureDef(condition.measure);
		var label = def ? jawnosT(def.label) : (condition.measure || '');
		var op = condition.op === 'from' || condition.op === 'is' || condition.op === 'contains' ? jawnosT(condition.op) : weatherMeasureOpText(condition.op);
		parts.push(label + ' ' + op + ' ' + weatherMeasureValueText(condition.value, def));
	}
	var sentence = jawnosT('When') + ' ' + parts.join(' ' + jawnosT('and') + ' ');
	if (rule.for_ms) { sentence += ' ' + jawnosT('for') + ' ' + weatherMeasureDurationText(rule.for_ms); }
	if (rule.action === 'run') {
		sentence += ', ' + jawnosT('run') + ' ' + (rule.command || '');
	}
	else if (rule.action === 'stop') {
		sentence += ', ' + jawnosT('stop') + ' ' + weatherAutomationWords(rule.app_label || rule.app || '');
	}
	else {
		sentence += ', ' + jawnosT('start') + ' ' + weatherAutomationWords(rule.app_label || rule.app || '');
	}
	var where = rule.location_label ? (jawnosT('At') + ' ' + rule.location_label + ': ') : '';
	return where + (rule.name ? (rule.name + ': ') : '') + sentence + '.';
}

function weatherMeasureFormOpen(rule) {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_measure_uuid').val(rule ? (rule.uuid || '') : '');
	weatherAutomationLocationSet('#weather_measure_location', rule ? (rule.location || '') : weatherAutomationView, rule ? (rule.location_label || '') : '');
	if (typeof weatherDeleteState === 'function') { weatherDeleteState(); }
	$w.find('#weather_measure_name').val(rule ? (rule.name || '') : '');
	var forMs = rule ? (rule.for_ms || 0) : 0;
	if (forMs && forMs % 3600000 === 0) {
		$w.find('#weather_measure_for').val(forMs / 3600000);
		$w.find('#weather_measure_for_unit').val('3600000');
	}
	else if (forMs) {
		$w.find('#weather_measure_for').val(Math.round(forMs / 60000));
		$w.find('#weather_measure_for_unit').val('60000');
	}
	else {
		$w.find('#weather_measure_for').val('0');
		$w.find('#weather_measure_for_unit').val('3600000');
	}
	$w.find('#weather_measure_action').val(rule ? (rule.action || 'start') : 'start');
	$w.find('#weather_measure_app').val(rule ? (rule.app || '') : '');
	$w.find('#weather_measure_command').val(rule ? (rule.command || '') : '');
	$w.find('#weather_measure_conditions').empty();
	var conditions = rule && rule.when ? rule.when : [null];
	for (var i = 0; i < conditions.length; i++) { weatherMeasureConditionAdd(conditions[i]); }
	weatherMeasureActionFields();
	$w.find('#weather_measure_form').show();
	document.getElementById('weather_measure_form').scrollIntoView({ block: 'nearest' });
}

function weatherMeasureFormClose() {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_measure_form').hide();
	$w.find('#weather_measure_conditions').empty();
}

function weatherMeasureEdit(uuid) {
	var rules = (weatherMeasurementData && weatherMeasurementData.measure_rules) || [];
	for (var i = 0; i < rules.length; i++) {
		if ((rules[i].uuid || '') === uuid) { weatherMeasureFormOpen(rules[i]); return; }
	}
}

function weatherMeasureConditionAdd(condition) {
	var $w = $('.wind[app="weather"]').last();
	var catalog = (weatherMeasurementData && weatherMeasurementData.measures) || [];
	var $row = $('<div class="weather_measure_condition"></div>');
	var $measure = $('<select class="weather_measure_measure"></select>');
	for (var i = 0; i < catalog.length; i++) {
		$measure.append($('<option>').val(catalog[i].key).text(jawnosT(catalog[i].label)));
	}
	var $op = $('<select class="weather_measure_op"></select>');
	var $value = $('<input class="weather_measure_value" type="number" step="any">');
	var $direction = $('<select class="weather_measure_direction" style="display:none;"></select>');
	var $unit = $('<span class="weather_measure_unit weather_muted"></span>');
	var $remove = $('<button type="button" class="weather_measure_condition_remove" title="' + weatherEsc(jawnosT('Remove')) + '">×</button>');
	$row.append($measure).append($op).append($value).append($direction).append($unit).append($remove);
	$w.find('#weather_measure_conditions').append($row);
	if (condition && condition.measure) { $measure.val(condition.measure); }
	weatherMeasureConditionSync($row, condition);
	$measure.on('change', function() { weatherMeasureConditionSync($row, null); });
	$remove.on('click', function() { $row.remove(); });
}

function weatherMeasureConditionSync($row, condition) {
	var def = weatherMeasureDef($row.find('.weather_measure_measure').val());
	var $op = $row.find('.weather_measure_op').empty();
	var ops = def ? (def.ops || []) : [];
	for (var i = 0; i < ops.length; i++) { $op.append($('<option>').val(ops[i]).text(weatherMeasureOpText(ops[i]))); }
	var $value = $row.find('.weather_measure_value');
	var $direction = $row.find('.weather_measure_direction');
	$row.find('.weather_measure_unit').text(def && def.unit ? def.unit : '');
	var type = def ? def.type : 'number';
	if (type === 'direction') {
		$value.hide();
		$direction.show().empty();
		var points = def.points || [];
		for (var j = 0; j < points.length; j++) { $direction.append($('<option>').val(points[j]).text(points[j])); }
		if (condition && condition.value) { $direction.val(String(condition.value).toUpperCase()); }
	}
	else {
		$direction.hide();
		$value.show().attr('type', type === 'number' ? 'number' : 'text');
		if (type === 'number') { $value.attr('step', 'any'); } else { $value.removeAttr('step'); }
		if (condition && condition.value !== undefined) { $value.val(condition.value); }
	}
	if (condition && condition.op) { $op.val(condition.op); }
}

function weatherMeasureActionFields() {
	var $w = $('.wind[app="weather"]').last();
	var run = ($w.find('#weather_measure_action').val() || 'start') === 'run';
	$w.find('#weather_measure_command').toggle(run);
	$w.find('#weather_measure_app').toggle(!run);
}

function weatherMeasureSave() {
	var $w = $('.wind[app="weather"]').last();
	var conditions = [];
	$w.find('.weather_measure_condition').each(function() {
		var key = $(this).find('.weather_measure_measure').val();
		var op = $(this).find('.weather_measure_op').val();
		var def = weatherMeasureDef(key);
		var value;
		if (def && def.type === 'direction') { value = $(this).find('.weather_measure_direction').val(); }
		else { value = $.trim($(this).find('.weather_measure_value').val() || ''); }
		if (!key || !op || value === undefined || value === '') { return; }
		conditions.push({ measure: key, op: op, value: value });
	});
	if (!conditions.length) {
		$w.find('#weather_measure_status').text(jawnosT('A measurement rule needs at least one complete condition.'));
		return;
	}
	var forValue = parseFloat($w.find('#weather_measure_for').val());
	var unit = parseInt($w.find('#weather_measure_for_unit').val(), 10) || 3600000;
	var forMs = (isFinite(forValue) && forValue > 0) ? Math.round(forValue * unit) : 0;
	var action = $w.find('#weather_measure_action').val() || 'start';
	var app = $.trim($w.find('#weather_measure_app').val() || '');
	var command = $.trim($w.find('#weather_measure_command').val() || '');
	if (action === 'run' && !command) {
		$w.find('#weather_measure_status').text(jawnosT('Type the command to run.'));
		return;
	}
	if (action !== 'run' && !app) {
		$w.find('#weather_measure_status').text(jawnosT('Type the app to start or stop.'));
		return;
	}
	$w.find('#weather_measure_status').text(jawnosT('Saving…'));
	$.ajax({
		url: '/manager/weather/measure_rule',
		type: 'POST',
		data: {
			uuid: $w.find('#weather_measure_uuid').val() || '',
			device: weatherAutomationDevice(),
			name: $w.find('#weather_measure_name').val() || '',
			location: $w.find('#weather_measure_location').val() || '',
			when: JSON.stringify(conditions),
			for_ms: forMs,
			action: action,
			app: app,
			command: command,
			timestamp: Date.now()
		},
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				$w.find('#weather_measure_status').text((response && response.error) || jawnosT('The measurement rule was not saved.'));
				return;
			}
			weatherMeasureFormClose();
			weatherAutomationRender(response, jawnosT('Saved.'));
		},
		error: function() { $w.find('#weather_measure_status').text(jawnosT('The measurement rule was not saved.')); }
	});
}

function weatherMeasureRemove(uuid) {
	if (!uuid) { return; }
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_measure_status').text(jawnosT('Removing…'));
	$.ajax({
		url: '/manager/weather/measure_rule',
		type: 'POST',
		data: { uuid: uuid, device: weatherAutomationDevice(), remove: 1, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				$w.find('#weather_measure_status').text((response && response.error) || jawnosT('The measurement rule was not removed.'));
				return;
			}
			weatherAutomationRender(response, jawnosT('Removed.'));
		},
		error: function() { $w.find('#weather_measure_status').text(jawnosT('The measurement rule was not removed.')); }
	});
}
