// ---- weather automations ----------------------------------------------------
// The old weather web-measure app kept rules such as "condition contains rain
// -> start raining". The Weather app now records the condition for the house's
// own coordinate, and this tab edits the same rule list.
var weatherAutomationLoaded = false;
var weatherAutomationData = null;

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

function weatherAutomationLoad(message) {
	var $w = $('.wind[app="weather"]').last();
	if (!$w.length) { return; }
	$w.find('#weather_automation_status').text(jawnosT('Loading…'));
	$.ajax({
		url: '/manager/weather/automations',
		type: 'GET',
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
			var html = '<div class="weather_automation_rule">'
				+ '<span class="weather_automation_text">' + weatherEsc(jawnosT('When the condition contains') + ' “' + (r.match || '') + '”, ' + verb + ' ') + '<b>' + weatherEsc(label) + '</b></span>'
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
}

function weatherAutomationError(message) {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_automation_status').text(message || '');
}

function weatherAutomationFormOpen(rule) {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_automation_uuid').val(rule ? (rule.uuid || '') : '');
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
		data: { uuid: uuid, remove: 1, timestamp: Date.now() },
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
