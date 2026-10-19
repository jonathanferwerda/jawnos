var global_constraints = { 'video': false, 'audio': false };
var configIntervals = { 'sysEvaluateInterval': '', 'sysEvaluateTimeout' : '' };

// The Configure tabs behave like tabs: opening one panel closes the others, so
// there is never a tall pile of half-scrolled panels. This runs before each
// panel's own handler and only acts when that panel is about to OPEN, so
// clicking the tab that is already open still closes it.
var jawnos_configure_panels = {
	me_settings: 'me_setting_list',
	restore_list: 'backup_list',
	system_setting_lister: 'system_list',
	misc_setting: 'misc_setting_list',
	plat_setting: 'plat_setting_list',
	appointment_list_grabber: 'configure_appointment_list',
	device_lister: 'device_list',
	tunnel_lister: 'tunnel_list',
	pseudonym_setting_lister: 'pseudonym_list',
	store_setting_lister: 'store_list'
};
// A tab's true label, captured once the first time we see it, so a panel that
// closes can put its button back exactly as it was when the screen loaded --
// even if a load was still in flight and left a '* loading' prefix behind.
function jawnosConfigureLabel(b) {
	var label = b.attr('data-label');
	if (!label) {
		label = (b.text() || '').replace(/^(\*\s*)+/, '').trim();
		b.attr('data-label', label);
	}
	return label;
}
function jawnosConfigureLabelAll() {
	$('.configure_toggle').each(function() {
		if (!$(this).attr('data-label')) {
			$(this).attr('data-label', ($(this).text() || '').replace(/^(\*\s*)+/, '').trim());
		}
	});
}
// Which tab the user last asked for. A panel's own load may finish after the
// user has moved on; it only gets to show itself if it is still the intent, so
// a slow panel can never stack a second one on screen.
var jawnos_configure_intent = null;
function jawnosConfigureShow(buttonId, c) {
	if (jawnos_configure_intent !== buttonId) { return false; }
	c.show();
	return true;
}
$(document).on('click', '.configure_toggle', function() {
	var b = $(this);
	var keep = jawnos_configure_panels[this.id];
	if (!keep) { return; }
	jawnosConfigureLabel(b);
	if ($('#' + keep).is(':visible')) { jawnos_configure_intent = null; return; }
	jawnos_configure_intent = this.id;
	$.each(jawnos_configure_panels, function(button, panel) {
		if (panel === keep) { return; }
		$('#' + panel).hide();
		$('#' + button).attr('status', 'inactive').text(jawnosConfigureLabel($('#' + button)));
	});
});

async function configureToggle() {
	var cb = $('#configure_balloon');
	if (cb.is(':visible')) {
		cb.hide();
	}
	else if (cb.find('#configure').length > 0) {
		cb.show();
	}
	else {
		var browser_tab_id = sessionStorage.getItem('browser_tab_id');
		var browser_tab = localStorage.getItem('browser_tab');
		$.ajax({
			url: '/manager/configure',
			type: 'GET',
			data: { 
				browser_tab_id: browser_tab_id,
				browser_tab: browser_tab
			},
			success: function(response) {
				//cb.show();
				//cb_check = 1;
				//cb.html(response);
				windowMaker(response);
				initializer();
				jawnosConfigureLabelAll();
			
				$('.media_picker').each(function(i,vd) {
					var v = $(vd);
					var type = v.attr('type');
					var kind = v.attr('kind');
					var device_id = v.attr('device_id');
					var mp = jawnosDevicePickGet(kind, device_id);
					if (mp == 'on') { v.attr('selected', 'on'); v.css({'background-color': 'green'}); }
				});
			}, error: function(response) { console.log(response); }
			
		});


	}
}

$(document).on('change', '.appointment_setting', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	if ($(this).is('select')) {
		value = JSON.stringify(value);
	}
	else if ($(this).attr('type') == 'checkbox') {
		if ($(this).prop('checked') == true) {
			value = 'on';
		}
		else {
			value == 'off';
		}
	}
	var app = $(this).attr('app') || $(this).closest('.appointment').attr('app') || $(this).closest('.wind').attr('app');
	var setter = { 'app': app, 'setting': setting, 'value': value };
	settingSetter(setter);
});

$(document).on('click', '.permission_asker', function() {
	permissionAsker();
});

async function permissionAsker(kind) {
	if (kind == 'location' || !kind) {

		navigator.geolocation.getCurrentPosition((position) => {

		});
	}
	if (kind == 'media' || !kind) {
		var constraints = await constraintMaker();
		var av = await navigator.mediaDevices.enumerateDevices();
		var avData = JSON.stringify(av);

		$.ajax({
			url: '/manager/configure/permissions',
			type: 'POST',
			data: {
				avData: avData,
				constraints: constraints
			}
		});
	}
	if (kind == 'notifications' || !kind) {
		Notification.requestPermission().then((result) => {

		});
	}
	if ((kind == 'nfc' || !kind) && typeof jawnNfcAvailable === 'function' && jawnNfcAvailable()) {
		nfc = {
			scanning: false,
			writing: false,
			abort: new AbortController(),
			initialized: false
		};
		nfc['ndef'] = jawnNfcMake();
		nfcInitializer();
		nfcListener();
	}
	if (kind == 'usb' || !kind) {
		navigator.usb.requestDevice({ filters: [] }).then(function(devices) { console.log(devices); });
	}

}


function numericals() {
	numerics = "";
	if ($('#ticket').is(':visible')) {
		numerics = "";
		$('#ticket').find('.ticket_input').each(function() {
			numerics = numerics + $(this).val();
		});
	}
	return numerics;
}

$(document).on('click', '#password_clear', function() {
	$('#credential_insert').val('');
	$('#ticket').find('.ticket_input').each(function() {
		$(this).val('');
	});
});

$(document).on('click','.delete_backup', function() {
	var a = $(this);
	var timestamp = Date.now();
	var filename = a.attr('filename');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		if (filename) {
			$.ajax({
				url: '/manager/configure/delete_backup',
				type: 'POST',
				data: { timestamp: timestamp, filename: filename },
				success:function(response) {
					if (response == 'backup deleted') {
						a.closest('.backup').remove();
					}
				}
			});
		}
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change', '.pos, .mab', function(e) {
	var d = $(this);
	var setting = d.attr('setting');
	var parent = d.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var a = d.attr('app');
	var o = e.currentTarget.selectedOptions[0];
	o = $(o).val();
	var now = Date.now();
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { timestamp: now, app: a, setting: setting, value: o },
		success: function(response) { display.html(response); }
	});
});
$(document).on('change', '.configure_checkbox', function(e) {
	var d = $(this);
	var parent = d.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var a = d.attr('app');
	var now = Date.now();
	var setting = d.attr('setting');
	if (d.is(':checked')) { value = "checked"; } else { value = "unchecked"; }
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: a, timestamp: timestamp, setting: setting, value: value },
		success: function(response) { 
			display.html(response); 
			localStorage.removeItem('manager_search_cache');
		}
	});
});
$(document).on('change', '.configure_input', function(e) {
	var e = $(this);
	url = '/manager/configure';
	var setting = e.attr('setting');
	var app = e.attr('app');
	var button = $('.app_configure_toggle[setting="' + setting + '"][app="' + app + '"]');
	var value = e.val();
	if (e.attr('type') == 'checkbox') {
		value = e.prop('checked') ? 'on' : 'off';
	}
	var parent = e.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var timestamp = Date.now();
	if (e.attr('multiple')) {
		value = JSON.stringify(value);
	}
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: app, timestamp: timestamp, setting: setting, value: value },
		success: function(response) {
			// a rename into a name the house already knows answers with a conflict,
			// not with a display: the panel asks which value keeps the name. This is
			// also the only path a phone takes - its keyboard has no Enter, just a
			// Next that blurs the field, so the change event is what fires there
			if (response && response.conflict) { nameConflictPanel(response); return; }
			display.html(response);
			localStorage.removeItem('manager_search_cache');
			// the theme select lives in the app's head, not in an ability panel
			if (setting != 'theme') {
				button.find('.ability_label').html('<b>' + button.attr('formatted_setting') + ':</b> ' + value.slice(0,20));
				configurationGrabber({ app: app, setting: [setting] });
			}
		}
	});
});

// The sync topology is a house setting, not a per-window preference: the Dev
// panel's select writes the shared `device: 'all'` row, the settings merge carries
// it to the other machines, and the reconnector reads it on each pass. It posts
// to the JSON setter rather than /manager/configure, which would answer with an
// appointment display for an app that has none.
$(document).on('change', '.sync_topology_select', function() {
	var status = $('#sync_topology_status');
	status.text('saving…');
	$.ajax({
		url: '/manager/setting_setter',
		type: 'POST',
		data: { app: 'sync', setting: 'topology', value: $(this).val(), device: 'all', timestamp: Date.now() },
		success: function() { status.text('house-wide — saved'); },
		error: function() { status.text('could not save'); }
	});
});

// A custom notification sound: the file is uploaded to the house, which files it
// beside the shipped ones, and every sound select is re-drawn so the new one can
// be picked (here and on any other app's Notifications panel)
$(document).on('change', '.app_notification_sound_upload', function () {
	var input = this;
	var app = $(this).attr('app');
	var status = $('.app_notification_sound_status[app="' + app + '"]');
	var f = input.files && input.files[0];
	if (!f) { return; }
	status.text('adding ' + f.name + '…');
	var data = new FormData();
	data.append('app', app);
	data.append('timestamp', Date.now());
	data.append('sound', f);
	$.ajax({
		url: '/manager/configure/notification_sound',
		type: 'POST',
		data: data,
		processData: false,
		contentType: false,
		success: function (response) {
			input.value = '';
			if (response && response.ok) {
				// the sound is on the house now: offer it in this app's selects without
				// re-drawing the panel (a re-draw would take the message with it)
				$('.app_notification_sound_selector[app="' + app + '"]').each(function () {
					if ($(this).find('option[value="' + response.sound + '"]').length) { return; }
					$(this).append($('<option></option>').attr('value', response.sound).text(response.name));
				});
				status.text('added ' + response.name + ' - pick it above');
			} else {
				status.text((response && response.error) || 'could not add that');
			}
		},
		error: function () { input.value = ''; status.text('could not add that'); }
	});
});

// The runtime Guide commands are one JSON list in a textarea, saved whole rather
// than on every keystroke, so a half-typed entry never reaches the server.
$(document).on('click', '#guide_verbs_save', function () {
	var status = $('#guide_verbs_status');
	status.text('saving…');
	$.ajax({
		url: '/manager/help/verbs',
		type: 'POST',
		dataType: 'json',
		data: { verbs: $('#guide_verbs_json').val() },
		success: function (r) {
			status.text((r && r.ok) ? ('saved — ' + (r.count || 0) + ' command(s)') : ((r && r.error) || 'could not save'));
		},
		error: function () { status.text('could not save'); }
	});
});

// Budgets and goals are edited as a list: each row is an amount, a measure (the
// app's own, money, or a plain count), a scope count + unit (none makes it a
// fixed level), and which way it runs. The rows are composed back into the one
// string everything downstream reads: "amount measure/scope", comma separated,
// with a leading "<=" on a ceiling.
// A duration amount carries its own time unit ("11h", "90m", "1h30m"); a
// duration selected with no unit at all is read as minutes.
function budgetGoalsIsTime(value) {
	value = $.trim(value || '');
	return /^[0-9]+(?:\.[0-9]+)?\s*[hmsdwMy](?:\s*[0-9]+(?:\.[0-9]+)?\s*[hmsdwMy])*$/.test(value);
}
function budgetGoalsDurationValue(value) {
	value = $.trim(value || '');
	if (!value || /[a-zA-Z]\s*$/.test(value)) { return value; }
	return value + 'm';
}
// one entry as the house reads it: "amount measure/scope", with a leading "<="
// on a ceiling
function budgetGoalsEntry(amount, measure, scope, direction) {
	var value = $.trim(amount || '');
	var entry;
	if (measure === '$') { entry = '$' + value; }
	else if (measure === 'duration') { entry = budgetGoalsDurationValue(value); }
	else { entry = value + (measure || ''); }
	if (scope) { entry += '/' + scope; }
	if (direction === 'ceiling') { entry = '<=' + entry; }
	return entry;
}
function budgetGoalsValue(container) {
	var parts = [];
	container.find('.budget_goals_row').each(function() {
		if ($(this).closest('.budget_goals_template').length) { return; }
		var row = $(this);
		var dir = row.find('.budget_goals_direction').val();
		var value = $.trim(row.find('.budget_goals_value').val() || '');
		var measure = row.find('.budget_goals_measure').val() || '';
		var count = $.trim(row.find('.budget_goals_count').val() || '');
		var unit = row.find('.budget_goals_unit').val() || '';
		if (value === '') { return; }
		var scope = unit ? (count || '1') + unit : '';
		parts.push(budgetGoalsEntry(value, measure, scope, dir));
	});
	return parts.join(',');
}
function budgetGoalsAddRow(container) {
	var row = container.find('.budget_goals_template').first().find('.budget_goals_row').first().clone();
	container.find('.budget_goals_adder').before(row);
	return row;
}
// set the row a recommendation belongs to (its measure names the circumstance),
// adding one when the app had no entry for that measure yet
function budgetGoalsRowSet(container, measure, amount, scope, direction) {
	var row = null;
	container.find('.budget_goals_row').each(function() {
		if ($(this).closest('.budget_goals_template').length) { return; }
		if (($(this).find('.budget_goals_measure').val() || '') === (measure || '')) {
			row = $(this);
			return false;
		}
	});
	if (!row) { row = budgetGoalsAddRow(container); }
	var select = row.find('.budget_goals_measure');
	if (measure && select.find('option[value="' + measure + '"]').length === 0) {
		$('<option>').attr('value', measure).text(measure).appendTo(select);
	}
	select.val(measure || '');
	row.find('.budget_goals_direction').val(direction === 'ceiling' ? 'ceiling' : 'floor');
	row.find('.budget_goals_value').val(amount || '');
	var m = /^([0-9]*)([a-zA-Z]+)$/.exec(scope || '');
	// an autocalc entry's scope may be a symbol ("d") where the row names the
	// unit in full ("day")
	var units = { m: 'minute', h: 'hour', d: 'day', w: 'week', M: 'month', y: 'year' };
	var unit = (m && m[2]) ? m[2] : '';
	if (units[unit]) { unit = units[unit]; }
	row.find('.budget_goals_count').val(m && m[1] ? m[1] : '');
	row.find('.budget_goals_unit').val(unit);
	return row;
}
function budgetGoalsSave(container) {
	var setting = container.attr('setting');
	var app = container.attr('app');
	var value = budgetGoalsValue(container);
	settingSetter({ 'app': app, 'setting': setting, 'value': value });
	var button = $('.app_configure_toggle[setting="' + setting + '"][app="' + app + '"]');
	if (button.length) {
		button.find('.ability_label').html('<b>' + button.attr('formatted_setting') + ':</b> ' + value.slice(0, 20));
	}
}
// typing a time ("11h") into the amount turns the measure to duration on its own
$(document).on('input', '.budget_goals_row .budget_goals_value', function() {
	var row = $(this).closest('.budget_goals_row');
	var select = row.find('.budget_goals_measure');
	if (select.val() !== 'duration' && budgetGoalsIsTime($(this).val())) {
		select.val('duration');
	}
});
$(document).on('change', '.budget_goals_row .budget_goals_value, .budget_goals_row .budget_goals_direction, .budget_goals_row .budget_goals_measure, .budget_goals_row .budget_goals_count, .budget_goals_row .budget_goals_unit', function() {
	budgetGoalsSave($(this).closest('.budget_goals'));
});
$(document).on('click', '.budget_goals_adder', function() {
	budgetGoalsAddRow($(this).closest('.budget_goals'));
});
$(document).on('click', '.budget_goals_remover', function() {
	var container = $(this).closest('.budget_goals');
	$(this).closest('.budget_goals_row').remove();
	budgetGoalsSave(container);
});

$(document).on('click', '.app_measure_configuration_adder', function() {
	var app = $(this).attr('app');
	var amc = $(this);
	var button = $('.app_configure_toggle[setting="measures"][app="' + app + '"]');
	var appmc = amc.closest('.app_measures_configurator');
	$.ajax({
		url: '/manager/configure/app_measure_configuration_adder',
		type: 'POST',
		data: { app: app },
		success: function(response) {
			button.find('.ability_label').html('<b>' + button.attr('formatted_setting') + ':</b> ' + response.header.slice(0,20));
			var ta = appmc.find('.configure_input[setting="app_measures"]');
			appmc.html(response.config);
			$('.re_measures[app="' + app + '"]').html(response.app_measure);
			configurationGrabber({ app: app, setting: ['measures'] });
		}
	});
});

$(document).on('click', '.app_measure_configuration_name', function() {
	var name = $(this).attr('name');
	var container = $(this).closest('.app_measures_configurator');
	var app = container.attr('app');
	var name_change = container.find('.app_measure_configuration[setting="measure"][oldvalue="' + name +'"]');
	if (name_change.is(':visible')) {
		name_change.hide();
	}
	else {
		name_change.show();
	}
	configurationGrabber({ app: app, setting: ['measures'] });
});

$(document).on('change', '.app_measure_configuration', function() {
	var amc = $(this);

	var app = amc.closest('.appointment').attr('app');
	var amcc = amc.closest('.app_measure_configuration_container');
	var appmc = amc.closest('.app_measures_configurator');
	var measure = amcc.attr('measure');
	var oldvalue = amc.attr('oldvalue');
	var setting = amc.attr('setting');
	var value = amc.val();
	var timestamp = Date.now();
	var button = $('.app_configure_toggle[setting="measures"][app="' + app + '"]');

	$.ajax({
		url: '/manager/configure/app_measure_configurator',
		type: 'POST',
		data: { app: app, setting: setting, value: value, measure: measure, oldvalue: oldvalue },
		success: function(response) {
			button.find('.ability_label').html('<b>' + button.attr('formatted_setting') + ':</b> ' + response.header.slice(0,20));
			var ta = appmc.find('.configure_input[setting="app_measures"]');
			ta.val(response.header);
			appmc.html(response.config);

			$('.re_measures[app="' + app + '"]').html(response.app_measure);
			configurationGrabber({ app: app, setting: ['measures'] });
		}
	});
});

$(document).on('change', '.app_measure_configuration_matcher', function() {
	var amcm = $(this);
	var amcmc = amcm.closest('.app_measure_configuration_matcher_container');
	var amcc = amcm.closest('.app_measure_configuration_container');
	var app = amcc.attr('app');
	var measure = amcc.attr('measure');
	var uuid = amcmc.attr('uuid');
	var value = amcm.val();
	var setting = amcm.attr('setting');
	var data = { app: app, measure: measure, uuid: uuid, setting: setting, value: value };
	$.ajax({
		url: '/manager/configuration/app_measure_configuration_matcher',
		type: 'POST',
		data: data,
		success: function(response) {
			amcmc.attr('uuid',  response.uuid);
			configurationGrabber({ app: app, setting: ['measures'] });
		}
	});

});

$(document).on('click', '.web_measure_delete', function() {
	var a = $(this);
	var app = a.attr('app');
	var measure = a.attr('measure');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/web/measure/delete',
			type: 'POST',
			data: { app: app, measure: measure },
			success: function(response) {
				a.closest('tr').remove();
			configurationGrabber({ app: app, setting: ['measures','web'] });
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change', '.packaging_config', function() {
	var uuid = $(this).closest('.packaging_config_container').attr('uuid');
	var name = $(this).attr('name');
	var value = $(this).val();
	var app = $(this).closest('.appointment').attr('app');
	var timestamp = Date.now();
	var selector = selectorMaker(this);
	$.ajax({
		url: '/manager/configure/packaging/save',
		type: 'POST',
		data: { app: app, name: name, uuid: uuid, value: value, timestamp: timestamp },
		success: function(response) {
			$('.app_packaging_configurator[app="' + app + '"]').html(response.html);
			$(selector).focus();
			configurationGrabber({ app: app, setting: ['packaging'] });
		}
	});
});

$(document).on('click', '.delete_packaging', function() {
	var uuid = $(this).attr('uuid');
	var app = $(this).closest('.appointment').attr('app');
	$.ajax({
		url: '/manager/configure/packaging/delete',
		type: 'POST',
		data: { app: app, uuid: uuid },
		success: function(response) {
			$('.app_packaging_configurator[app="' + app + '"]').html(response.html);
			configurationGrabber({ app: app, setting: ['packaging'] });
		}
	});
});

// The host box beside Ping keeps the stored value level with the box as it is
// edited: a moment after typing stops, and at once when the field is left, it
// saves itself - including a clear - so a value is never lost just because Ping
// or Scan was not pressed. save_only records it without pinging anything.
var pingHostSaveTimer = null;
function pingHostSave(host) {
	$.ajax({
		url: '/manager/configure/ping',
		type: 'GET',
		data: { host: host, save_only: 'yes', timestamp: Date.now() }
	});
}
$(document).on('input', '.ping_host', function() {
	var host = $(this).val();
	clearTimeout(pingHostSaveTimer);
	pingHostSaveTimer = setTimeout(function() { pingHostSave(host); }, 500);
});
$(document).on('change', '.ping_host', function() {
	clearTimeout(pingHostSaveTimer);
	pingHostSave($(this).val());
});

$(document).on('click', '#device_lister, .device_scan', function() {
	var b = $(this);
	var load_type = b.attr('load_type');
	var text = jawnosConfigureLabel(b);
	var host = $('.ping_host').val();
	if (b.hasClass('ping_scan')) {
		host = b.attr('ip_address');
	}
	b.text('* ' + text);
	var c = $('#device_list');
	if (c.is(':visible') && load_type == 'list') {
		b.text(jawnosConfigureLabel(b));
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		var timestamp = Date.now();
		var ping = $('#ping_results').html();
		$.ajax({
			url: '/manager/configure/device_lister',
			type: 'GET',
			data: { timestamp: timestamp, load_type: load_type, host: host },
			success: function(response) {
				$('#device_list').html(response);
				$('#ping_results').html(ping);
				printerInkLoad($('#device_list'));
				if (jawnosConfigureShow('device_lister', $('#device_list'))) {
					b.attr('status', 'active');
				}
				b.text(text);
				deviceListerRestoreButtons($('#device_list'));
			}
		}).fail(function(e) {
			b.text(text);
			$('#ping_results').text('scan failed (' + e.status + ')');
		});
	}
});

// A manual nudge for the bridge's adopt scan. Adoption already runs every 30 s;
// this lets a device that was just powered on be met (and listed) at once. The
// server starts the scan off-request, so refresh the panel while it works.
$(document).on('click', '.ble_adopt_scan', function() {
	var b = $(this);
	var text = b.text();
	b.prop('disabled', true).text('Scanning...');
	$.post('/manager/configure/ble_scan', {}, function() {
		setTimeout(function() { deviceLister(); }, 5000);
		setTimeout(function() {
			b.prop('disabled', false).text(text);
			deviceLister();
		}, 12000);
	}).fail(function() {
		b.prop('disabled', false).text(text);
	});
});

// Turn each restore-list blob the Dev panel received (a JSON list of a peer's
// backups) into file buttons, labelled by the file's own name.
function deviceListerRestoreButtons(scope) {
	$(scope || document).find('.remote_restore_list').each(function(i,v) {
		var r = $(v);
		if (r.html() == '' || r.html() == undefined) { return; }
		var neighbour;
		try { neighbour = JSON.parse(r.html() || '[]'); } catch(e) { return; }
		if (!neighbour) { return; }
		r.html('');
		$.each(neighbour, function(i,val) {
			if (val['archive'] == 'archive') { return; }
			// show the file's own name, not its long path; the button still carries
			// the full filename for the action
			var label = val['name'] || (val['filename'] || '').replace(/^.*\//, '');
			if (neighbour['verified'] == true) {
				r.append('<button class="neighbour_filepicker" filename="' + val['filename'] + '">Connected ' + label + '</button>');
				r.append('<button class="neighbour_filepicker" filename="' + val['filename'] + '">Connect</button>');
			}
			else {
				r.append('<button class="neighbour_filepicker" filename="' + val['filename'] + '">' + label + '</button>');
			}
		});
	});
}

// Re-fetch the Dev listing in place. The server pushes this as the console command
// deviceLister() when a tunnel comes up or goes down (and when a peer is
// enrolled), so the Dev panel shows a machine dialling in without a manual Scan.
// It acts only while the Dev panel is open.
function deviceLister() {
	var c = $('#device_list');
	if (!c.length || !c.is(':visible')) { return; }
	$.ajax({
		url: '/manager/configure/device_lister',
		type: 'GET',
		data: { timestamp: Date.now(), load_type: 'list' },
		success: function(response) {
			c.html(response);
			printerInkLoad(c);
			deviceListerRestoreButtons(c);
		}
	});
}

// A printer's ink and toner, asked over IPP once its row is in the Dev panel. The
// table is already on screen when this runs, so a printer that is off cannot hold
// up the whole listing: each readout fills in on its own call, or reports that the
// printer did not answer.
function printerInkBars(r) {
	if (!r || r.error || !r.markers || !r.markers.length) {
		var why = (r && r.error) ? r.error : 'no levels';
		return '<span class="printer_state">' + why + '</span>';
	}
	var html = '';
	$.each(r.markers, function(i, m) {
		var pct = (m.percent === null || m.percent === undefined) ? null : m.percent;
		var fill = '';
		if (m.colors && m.colors.length > 1) { fill = 'linear-gradient(90deg,' + m.colors.join(',') + ')'; }
		else if (m.colors && m.colors.length) { fill = m.colors[0]; }
		var low = (pct !== null && pct <= 10) ? ' ink_low' : '';
		html += '<span class="inker' + low + '" title="' + (m.name || '') + '">';
		html += '<span class="ink_name">' + (m.name || '') + '</span>';
		html += '<span class="ink_bar"><span class="ink_fill" style="width:' + (pct === null ? 0 : pct) + '%;background:' + fill + ';"></span></span>';
		html += '<span class="ink_pct">' + (pct === null ? '?' : pct + '%') + '</span>';
		html += '</span>';
	});
	var state = [];
	if (r.state) { state.push(r.state); }
	if (r.reasons && r.reasons.length) { state = state.concat(r.reasons); }
	if (state.length) { html += '<span class="printer_state">' + state.join(' · ') + '</span>'; }
	return html;
}

function printerInkLoad(scope) {
	var set = $(scope || document).find('.printer_ink');
	if (scope) { set = set.add($(scope).filter('.printer_ink')); }
	set.each(function() {
		var el = $(this);
		if (el.data('ink_loaded')) { return; }
		el.data('ink_loaded', true);
		$.getJSON('/manager/configure/printer_ink', { ip: el.attr('ip') })
			.done(function(r) { el.find('.printer_ink_body').html(printerInkBars(r)); })
			.fail(function() { el.find('.printer_ink_body').html('<span class="printer_state">ink unavailable</span>'); });
	});
}

// Clicking a readout asks the printer again, so a cartridge just changed shows at
// once without waiting for another Scan.
$(document).on('click', '.printer_ink', function() {
	var el = $(this);
	el.removeData('ink_loaded');
	el.find('.printer_ink_body').text('reading…');
	printerInkLoad(el);
});

$(document).on('click', '#tunnel_lister', function() {
	var b = $(this);
	var timestamp = Date.now();
	var c = $('#tunnel_list');

	if (c.is(':visible')) {
		b.text(jawnosConfigureLabel(b));
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		b.text('* ' + jawnosConfigureLabel(b));
		c.show();
		tunnelLister('open');
		b.attr('status', 'active');	
	}
});

function tunnelLister(b) {
	//if (b == 'open' || $('#tunnel_list').is(':visible')) {
		$.ajax({
			url: '/manager/configure/tunnel/list',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				$('#tunnel_list').html(response.html);

			}
		});
	//}
}

$(document).on('click', '#pseudonym_setting_lister', function() {
	var timestamp = Date.now();
	var b = $(this);
	var c = $('#pseudonym_list');
	if (c.is(':visible')) {
		b.text(jawnosConfigureLabel(b));
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		b.text('* ' + jawnosConfigureLabel(b));
		$.ajax({
			url: '/manager/configure/pseudonym_list',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				c.html(response);
				b.text(jawnosConfigureLabel(b));
				if (jawnosConfigureShow('pseudonym_setting_lister', c)) {
					b.attr('status', 'active');
				}
			}
		});
	}
});

$(document).on('change', '.pseudonym_setting', function() {
	var b = $(this);
	var timestamp = Date.now();
	var setting = b.attr('setting');
	var value = b.val();
	var name = b.closest('[pseudonym_name]').attr('pseudonym_name');
	var p = 
	$.ajax({
		url: '/manager/configure/pseudonym_setter',
		type: 'POST',
		data: { setting: setting, value: value, name: name, timestamp: timestamp },
		success: function(response) {
			$('#pseudonym_list').html(response);
			if (setting == 'status') {
				var p = $('.pseudonym.keyboard[toggle="' + name + '"]');
				jawnosDockIconSet(name, value);
				if (value == 'on') {
					p.show();
				}
				else if (value == 'button') {

				}
				else if (value == 'off') {
					p.hide();
				}
			}
		}
	});
});

$(document).on('click', '.pseudonym_icon_set', function() {
	var set = $(this);
	var name = set.attr('name');
	if ($('#whiteboard').is(':visible')) {
		$('#alert_message').html('Are you sure you want to change the pseudonym: ' + name + '\'s icon?<br><br>' +
			'<button pseudonym_name="' + name + '" id="pseudonym_icon_change_submit">Submit</button><button id="alert_cancel">Cancel</button>'
		);
		$('#alert').show();
	}
});

$(document).on('click', '#pseudonym_icon_change_submit',function() {
	var submit = $(this);
	var timestamp = Date.now();
	if ($('#whiteboard').is(':visible')) {
		var canvas = document.getElementById('whiteboard');
		// the marker zooms now, so take the drawing itself, not the zoomed view
		var img;
		if (typeof markerFlatten == 'function' && typeof markerLayers != 'undefined' && markerLayers.length > 0) {
			img = markerFlatten().toDataURL('image/png');
		}
		else {
			img = canvas.toDataURL('image/png');
		}
		var name = submit.attr('pseudonym_name');
		var prev_img = $('.pseudonym_icon_set[name="' + name + '"]').attr('src');
		$.ajax({
			url: '/manager/configure/pseudonym_icon_changer',
			type: 'POST',
			data: { timestamp: timestamp, image: img, name: name },
			success: function(response) {
				$('#pseudonym_list').html(response.list);
				$('[name="' + name + '"][src="' + prev_img + '"]').attr('src',img);
				$('#alert').hide();
			}
		});
	}
});

$(document).on('click', '.pseudonym_defaulter', function() {
	var name = $(this).attr('name');
	var prev_img = $('.pseudonym_icon_set[name="' + name + '"]').attr('src');
	$.ajax({
		url: '/manager/configure/pseudonym_defaulter',
		type: 'GET',
		data: { name: name },
		success: function(response) {
			$('#pseudonym_list').html(response);
			var now_img = $('.pseudonym_icon_set[name="' + name + '"]').attr('src');
			$('[name="' + name + '"][src="' + prev_img + '"]').attr('src',now_img);
		}
	});
});

$(document).on('click', '#store_setting_lister', function() {
	var timestamp = Date.now();
	var b = $(this);
	var c = $('#store_list');
	if (c.is(':visible')) {
		b.text(jawnosConfigureLabel(b));
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		b.text('* ' + jawnosConfigureLabel(b));
		$.ajax({
			url: '/manager/configure/store_list',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				c.html(response);
				b.text(jawnosConfigureLabel(b));
				if (jawnosConfigureShow('store_setting_lister', c)) {
					b.attr('status', 'active');
				}
			}
		});
	}
});


$(document).on('change', '.device_purpose', function() {
	var purpose = $(this);
	var new_purpose = purpose.val();
	var timestamp = Date.now();
	var device = purpose.closest('.device');
	var ip = purpose.closest('.remote_machine').attr('ip');
	var mac = purpose.closest('.remote_machine').attr('mac');
	var uuid = device.attr('uuid');
	var network_interface = purpose.closest('.network_interface');
	$.ajax({
		url: '/manager/configure/device_purpose',
		type: 'POST',
		data: {
			timestamp: timestamp,
			uuid: uuid,
			ip: ip,
			mac: mac,
			purpose: new_purpose
		},
		success: function(response) {

		}
	});

});

$(document).on('click', '.ping', function() {
	var ping = $(this);
	var ipC = ping.prev();
	var host = ipC.val();
	var timestamp = Date.now();
	ping.text('pinging');
	$.ajax({
		url: '/manager/configure/ping',
		type: 'GET',
		data: {
			host: host,
			timestamp: timestamp
		},
		success: function(response) {
			$('#ping_results').html(response);
			ping.text('ping');
		}
	}).fail(function(e) {
		ping.text('ping');
		$('#ping_results').text('ping failed (' + e.status + ')');
	});
});

$(document).on('click', '.neighbour_disconnect', function() {
	var rd = $(this);
	var ip = rd.attr('ip');
	var signatorial = rd.attr('signatorial');
	var timestamp = Date.now();
	
	if (rd.attr('armed') == 'yes') {

		$.ajax({
			url: '/manager/configure/remote_device_disconnect',
			type: 'POST',
			data: { ip: ip, timestamp: timestamp, signatorial: signatorial },
			success: function(response) {
				rd.closest('.remote_machine_buttons').html('');
			}
		});
	}
	else {
		rd.attr('armed', 'yes');
		var bgcolor = rd.css('background-color');
		rd.css({'background-color': 'red' });
		setTimeout(function() {
			rd.css({'background-color': bgcolor });
			rd.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click', '.neighbour_tunnel', function() {
	var nt = $(this);
	var ssh_port = nt.attr('ssh_port');
	var ip = nt.attr('ip');
	var signatorial = nt.attr('signatorial');
	var uuid = nt.attr('uuid');
	var status = nt.attr('status');
	var nic = nt.attr('nic');
	$.ajax({
		url: '/manager/configure/remote_machine/tunnel/toggle',
		type: 'POST',
		data: { 
			ssh_port: ssh_port,
			ip: ip,
			signatorial: signatorial,
			uuid: uuid,
			status: status,
			nic: nic
		},
		success: function(response) {
			nt.attr('status', response.tunnel);

		}
	});


});

$(document).on('click', '.neighbour_refresh', function() {
	var bti = $(this).attr('bti');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/remote_refresh',
		type: 'GET',
		data: { 'bti': bti, 'timestamp': timestamp },
		success: function(response) {

		}
	});
});

$(document).on('click', '.teletype_backup', function() {
	var ip = $(this).attr('ip');
	var mac = $(this).attr('mac');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/embedded/teletype_backup',
		type: 'GET',
		data: { ip: ip, mac: mac, timestamp: timestamp },
		success: function(response) {

		}
	});
});

$(document).on('click', '.remote_rsync', function() {
	var r = $(this);
	var ip = r.attr('ip');
	var ssh_port = r.attr('ssh_port');
	var remote_device = r.attr('device');
	var hostname = r.attr('hostname');
	var direction = r.attr('direction');
	var uuid = r.attr('uuid');
	var signatorial = r.attr('signatorial');
	var home = r.attr('home');
	$.ajax({
		url: '/manager/configure/remote_rsync',
		type: 'POST',
		data: { 
			timestamp: timestamp, 
			ip: ip, 
			direction: direction, 
			ssh_port: ssh_port, 
			home: home,
			signatorial: signatorial,
			uuid: uuid
		 },
		success: function(response) {
			r.closest('.network_interface').prepend('<br>Me: ' + response);
		}
	});
});

$(document).on('click', '.remote_upgrade_clear', function() {
	settingSetter({ 'app': '__president', 'setting': 'remote_upgrade', 'value': 'inactive' });
});

$(document).on('click', '.remote_upgrade', function() {
	var r = $(this);
	var ip = r.attr('ip');
	var ssh_port = r.attr('ssh_port');
	var remote_device = r.attr('device');
	var hostname = r.attr('hostname');
	var device = r.closest('.device');
	var database = r.attr('database');
	var signatorial = r.attr('signatorial');
	var uuid = r.attr('uuid');
	var gimme = $('.gimme_input[name="gimme"][signatorial="' + signatorial + '"][uuid="' + uuid + '"]').val();
	$.ajax({
		url: '/manager/configure/remote_upgrade',
		type: 'POST',
		data: { 
			timestamp: timestamp, 
			ip: ip, 
			ssh_port: ssh_port, 
			device: remote_device, 
			hostname: hostname,
			database: database,
			signatorial: signatorial,
			uuid: uuid,
			gimme: gimme
		},
		success: function(response) {
			$('.gimme_input[name="gimme"][signatorial="' + signatorial + '"][uuid="' + uuid + '"]').val('');
			r.closest('.network_interface').append('<br>Me: ' + response);
		}
	});
});

// Dev's migration action: ask a linked device to pull the whole house from
// this machine. The server sends the signed pull-now lever; this only starts
// it and follows the donor's own progress.
$(document).on('click', '.remote_migrate', function() {
	var b = $(this);
	var actions = b.closest('.device_actions');
	var sig = b.attr('signatorial');
	b.prop('disabled', true).text('Migrating…');
	$('.migration_status').remove();
	$.post('/manager/configure/migrate', { signatorial: sig, timestamp: Date.now() }, function(res) {
		if (!res || !res.ok) {
			b.prop('disabled', false).text('Migrate');
			actions.append($('<span class="migration_status"></span>').text(' ' + ((res && res.error) || 'failed')));
			return;
		}
		var span = $('<span class="migration_status"></span>').text(' migrating…');
		actions.append(span);
		var poll = function() {
			$.get('/manager/configure/migrate/status', { uuid: res.migration }, function(s) {
				if (!s || !s.ok) { span.text(' migration lost'); b.prop('disabled', false).text('Migrate'); return; }
				var snap = s.snapshot || {};
				var size = snap.size ? ' ' + Math.round(snap.size / 1048576) + 'MB' : '';
				span.text(' ' + (s.migration.state || '') + ' ' + (snap.state || '') + size);
				if (snap.state === 'done' || snap.state === 'failed' || s.migration.state === 'done') {
					b.prop('disabled', false).text('Migrate');
					return;
				}
				setTimeout(poll, 2000);
			}, 'json');
		};
		setTimeout(poll, 2000);
	}, 'json').fail(function() {
		b.prop('disabled', false).text('Migrate');
		actions.append($('<span class="migration_status"> failed</span>'));
	});
});

$(document).on('change', '.remote_machine_input', function() {
	var input = $(this);
	var timestamp = Date.now();
	var signatorial = input.attr('signatorial');
	var uuid = input.attr('uuid');
	var ip = input.attr('ip');
	var value = input.val();
	var name = input.attr('name');

	$.ajax({
		url: '/manager/configure/remote_machine_input',
		type: 'POST',
		data: { 
			timestamp: timestamp,
			signatorial: signatorial,
			ip: ip,
			value: value,
			uuid: uuid,
			name: name
		},
		success: function(response) {
			input.css({ 'background-color': 'lightgreen' });
			setTimeout(function() {
				input.css({ 'background-color': 'white' });
			},2000);
		}
	});
});

$(document).on('click', '.remote_device_locker', function() {
	var locker = $(this);
	var timestamp = Date.now();
	var uuid = locker.attr('uuid');
	var ip = locker.attr('ip');
	var status = locker.attr('status');
	var nic = locker.attr('nic');
	$.ajax({
		url: '/manager/configure/remote_device_locker',
		type: 'POST',
		data: { uuid: uuid, ip: ip, status: status, nic: nic, timestamp: timestamp },
		success: function(response) {
			locker.attr('status', response.locked);
			if (response.locked == 'yes') {
				locker.attr('src', '/images/jbuttons/padlock lock.png');
				locker.css({ 'background-color': 'red' });
			}
			else {
				locker.attr('src', '/images/jbuttons/padlock unlock.png');
				locker.css({ 'background-color': 'lightgreen' });
			}
		}
	});
});

$(document).on('click', '.neighbour_filepicker', function() {
	var chosen = $(this);
	var filename = chosen.attr('filename');
	var manager = chosen.closest('.remote_restore_list').attr('manager');
	var tunnel = chosen.closest('.remote_machine').attr('tunnel');
	var timestamp = chosen.closest('.device').attr('timestamp');
	var ip = chosen.closest('.remote_machine').attr('ip');
	var port = chosen.closest('.remote_machine').attr('port');
	var signatorial = chosen.closest('.remote_machine').attr('signatorial');
	var nic = chosen.closest('.network_interface').attr('nic');
	var uuid = chosen.closest('.device').attr('uuid');
	var websockets = [];
	$.each(ws, function(i,v) { websockets.push(i) });
	var json_websockets = JSON.stringify(websockets);
	chosen.closest('.device').find('.device_president').val(filename).trigger('change');
	$.ajax({
		url: '/manager/configure/remote_device_connect',
		type: 'GET',
		data: { 
			manager: manager,
			filename: filename,
			timestamp: timestamp,
			signatorial: signatorial,
			port: port,
			ip: ip,
			websockets: 
			json_websockets,
			nic: nic,
			uuid: uuid,
			tunnel: tunnel
		},
		success: function(update) {

			chosen.text(update['status']);
			if (update['body']['authentication'] == 'approved') {
				chosen.closest('.remote_machine').find('.remote_machine_buttons').html(update['button'])
				var sw = chosen.closest('.device').find('.machine_name');
				chosen.closest('.remote_machine').find('.device_purpose').val(update['body']['device']);
//				sw.val(update['body']['me'][update['body'][device]]['my_name']).trigger('change');
				if (update['colour']) {
					sw.css({'background-color': update['colour'] });
				}
				setTimeout(function() {
					sw.css({'background-color': 'white' });
				},500);
			}
		},
		error: function(e) { console.log(e); }
	});
});

$(document).on('click', '#misc_setting', function() {
	var b = $(this);
	if (!$('#misc_setting_list').is(':visible')) {
		var timestamp = Date.now();
		$.ajax({
			url: '/manager/configure/misc_setting_list',
			type:'GET',
			data: { timestamp: timestamp },
			success: function(response){
				$('#misc_setting_list').html(response);
				if (jawnosConfigureShow('misc_setting', $('#misc_setting_list'))) {
					b.attr('status', 'active');
				}
			}
		});
	}
	else {
		$('#misc_setting_list').hide();
		b.attr('status', 'inactive');
	}
});

$(document).on('click', '#plat_setting', function() {
		var b = $(this);
		if (!$('#plat_setting_list').is(':visible')) {
			var timestamp = Date.now();
			$.ajax({
				url: '/manager/configure/plat_setting_list',
				type:'GET',
				data: { timestamp: timestamp },
				success: function(response){
					$('#plat_setting_list').html(response);
					if (jawnosConfigureShow('plat_setting', $('#plat_setting_list'))) {
						b.attr('status', 'active');
					}
				}
			});
		}
		else {
			$('#plat_setting_list').hide();
			b.attr('status', 'inactive');
		}
	});

// the thinking choice rides beside an agent's model and is shown only while the
// chosen model is one that reasons; each option carries what it thinks, so the
// row moves with the pick (the stored level is kept either way). The fallback
// select mirrors the model list minus the primary, so it follows the pick too.
$(document).on('change', '.ai_role_model', function() {
	var role = $(this).closest('.ai_role');
	var thinks = $(this).find('option:selected').data('thinks');
	role.find('.ai_thinking_row').toggle(!!thinks);
	var primary = $(this).val();
	var fb = role.find('.ai_role_fallback');
	fb.find('option').each(function() {
		var o = $(this);
		o.prop('disabled', o.val() !== '' && o.val() === primary);
	});
	if (fb.val() === primary) { fb.val(''); }
});

// the Speech setting's Preview button: speak a test phrase in the voice chosen
// for that device, rather than waiting for a real say_it to happen
$(document).on('click', '.say_voice_test', function() {
	var voice = $(this).closest('.misc_device_block').find('.misc_setting[setting="say_voice"]').val();
	$.ajax({
		url: '/manager/say_it',
		type: 'GET',
		data: { words: 'This is the voice you have chosen.', voice: voice, timestamp: Date.now() }
	});
});

$(document).on('change','.misc_setting', function() {
	var timestamp = Date.now();
	var set = $(this);
	var setting = set.attr('setting');
	var object = set.attr('object');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="misc"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.misc_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/misc_setting',
		type: 'POST',
		data: { timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
			$.each(response, function(i,v) {
				if (v.setting == 'manager_background_colour' && dev == v.device) {
					// a running appointment theme owns the desktop until it stops
					if ($('body').attr('data-appt-theme') != 'yes') {
						$('body').css({'background-color':v.value});
						if (typeof jawnosApplyInk == 'function') { jawnosApplyInk(); }
					}
				}
				if (v.setting == 'configure_background_colour' && dev == v.device) {
					$('#configure').css({'background-color': v.value});
				}
				if (v.setting == 'title_font' && dev == v.device) {
					$('.title_font').css({'font-family': v.value});
				}
				if ($('#' + object)) {
					$('#' + object).css({'background-color': value});
				}
				if ($('.' + object).length > 0) {
					$('.' + object).css({'background-color': value});
				}
				$('.misc_setting[device="' + v.device + '"][setting="' + v.setting + '"]').val(v.value);
			});
		}

	});

});

$(document).on('change','.sys_setting', function() {
	var timestamp = Date.now();
	var set = $(this);
	var setting = set.attr('setting');
	var object = set.attr('object');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="sys"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.misc_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/sys_setting',
		type: 'POST',
		data: { timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
		}
	});
});

$(document).on('change', '.utility_controller', function() {
	var b = $(this);
	var control = b.attr('control');
	var device = b.attr('device');
	var setting = b.attr('setting');
	var value = b.val();

	if (b.attr('type') == 'checkbox') {
		if (b.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}
	$.ajax({
		url: '/manager/configure/utility_controller/save',
		type: 'POST',
		data: { control: control, device: device, value: value, setting: setting },
		success: function(response) {
			$('#utility_controls_container').html(response.html);
		},
		error: function(e) {
			// a failed save must not leave the switch reading the value we tried to set
			// (the 5s reloader would then look like the toggle unchecked itself) -
			// repaint from the server; the error dot names the failure
			utilityControllerReloader();
		}
	});
});

function utilityControllerReloader() {
	$.ajax({
		url: '/manager/configure/utility_controller',
		type: 'GET',
		data: {  },
		success: function(response) {
			$('#utility_controls_container').html(response.html);
			appointment_chron();
		}
	});
}


$(document).on('change', '.device_domain', function() {
	var b = $(this);
	var timestamp = b.attr('timestamp');
	var domain = b.val();
	var device = b.attr('device');
	var address = b.attr('address');
	var uuid = b.attr('uuid');
	$.ajax({
		url: '/manager/configure/device_domain_updater',
		type: 'POST',
		data: { 
			device: device,
			domain: domain,
			timestamp: timestamp, 
			uuid: uuid
		}
	});
});

$(document).on('click','.delete_device', function() {
	var a = $(this);
	var device = a.attr('device');
	var timestamp = a.attr('timestamp');
	var uuid = a.attr('uuid');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/configure/device_deleter',
			type: 'POST',
			data: { device: device, timestamp: timestamp, uuid: uuid },
			success:function(response) {
				$('.device[uuid="' + uuid + '"]').remove();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click', '.delete_neighbour_device', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var rm = a.closest('.remote_machine');
	var rm_uuid = a.attr('rm_uuid');
	var device = a.closest('.device');
	var device_uuid = device.attr('uuid');

	if (a.attr('armed') == 'yes') {
		a.attr('armed','pending');
		$.ajax({ 
			url: '/manager/configure/device/neighbour_delete',
			data: { device_uuid: device_uuid, uuid: uuid, rm_uuid: rm_uuid },
			type: 'POST',
			success: function(response) {
				rm.remove();
				a.css({'background-color': 'lightgreen' });
				setTimeout(function() {
					a.attr('armed', 'no');
					var obg = a.attr('obg');
					a.css({'background-color': obg });
				},2000);
			}
		});
	}
	else if (a.attr('armed') != 'pending') {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'orange' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click','#stop_all', function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/stop_all_appointments',
		type:'POST',
		data: { timestamp: timestamp },
		success:function(response) {

		}
	});
});

$(document).on('click', '#me_settings', function() {
	var timestamp = Date.now();
	var b = $(this);
	var ml = $('#me_setting_list');
	if (!ml.is(':visible')) {
		$.ajax({
			url: '/manager/configure/me_settings',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				ml.html(response);
				if (jawnosConfigureShow('me_settings', ml)) {
					b.attr('status', 'active');
				}
			}
		});
	}
	else {
		ml.hide();
		b.attr('status', 'inactive');
	}
});

$(document).on('change', '.me_setting', function() {
	var set = $(this);
	var timestamp = Date.now();
	var setting = set.attr('setting');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="me"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.me_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/me_setting',
		type: 'POST',
		data: { 
			timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
			if (response.setting == 'my_name') {
				my_name = response['value'];
			}
		}
	});
});

$(document).on('click', '.home_plate_record', function() {
	var device = $(this).attr('device');
	var timestamp = Date.now();
	continent_record({device: device, app:'me', timestamp:timestamp,purpose:'home_plate'});
});

$(document).on('click', '#restore_list', function() {
	var c = $('#backup_list');
	var b = $(this);
	var text = jawnosConfigureLabel(b);
	b.text('* ' + text);
	if (c.is(':visible')) {
		b.text(jawnosConfigureLabel(b));
		c.hide();
		b.attr('status', 'inactive');
	} 
	else {
		var president = $('#president').val();
		$.ajax({
			url: '/manager/configure/restore_list',
			type: 'GET',
			data: { 'president': president },
			success:function(response) {
				c.html(response);
				if (jawnosConfigureShow('restore_list', c)) {
					b.text(text);
					b.attr('status', 'active');
				}
			}
		});
	}
});

$(document).on('click', '#system_setting_lister', function() {
	var c = $('#system_list');
	var b = $(this);
	var text = jawnosConfigureLabel(b);
	var local_storage = JSON.stringify(localStorage);
	b.text('* ' + text);
	if (c.is(':visible')) {
		b.text(jawnosConfigureLabel(b));
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		$.ajax({
			url: '/manager/configure/system_list',
			// POST: localStorage can be large, and in a GET query it would blow the
			// manager's 64k request-line cap and the panel would come back as the Gate
			type: 'POST',
			data: { local_storage: local_storage },
			success: function(response) {
				c.html(response);
				if (jawnosConfigureShow('system_setting_lister', c)) {
					b.text(text);
					b.attr('status', 'active');
				}
			},
			error: function(e) {
				b.text(jawnosConfigureLabel(b));
				c.html('<div class="cfg-note">the Sys panel did not load (' + e.status + '); press Sys to try again</div>').show();
			}
		});
	}
});

$(document).on('click', '.localstorage_delete', function() {
	var key = $(this).attr('key');
	localStorage.removeItem(key);
	$('.system_localstorage[key="' + key + '"]').remove();
});

$(document).on('click', '#appointment_list_grabber', function() {

	var b = $(this);
	var text = jawnosConfigureLabel(b);
	b.text('* ' + text);
	var c = $('#configure_appointment_list');
	if (c.is(':visible')) {
		b.text(jawnosConfigureLabel(b));
		c.hide();
		b.attr('status', 'inactive');
	} else {
		$.ajax({
			url: '/manager/configure/appointment_list',
			type:'GET',
			success:function(response) {
				$('#configure_appointment_list').html(response);
				if (jawnosConfigureShow('appointment_list_grabber', $('#configure_appointment_list'))) {
					b.text(text);
					b.attr('status', 'active');
				}
			},
		});
	}
});

$(document).on('click', '.appointment_configuration_grabber', function() {
	var t = $(this);
	var app = t.attr('app');
	var parent = t.closest('.wind');
	var display = $('.appointment_display[app="' + app + '"]');
	if (display.is(':visible')) {
		display.hide();
		t.attr('status', 'active');
	}
	else {
		appActExclusive(app, 'appointment_configuration_grabber');
		configurationGrabber({ app: app, display: display });
		t.attr('status', 'active');
	}
});

function configurationGrabber(data) {
	var app = data['app'];
	var display = data['display'];
	if (!display) {
		display = $('.appointment_display[app="' + app + '"]');
	}
	var setting = data['setting'] || [];
	var jSetting = JSON.stringify(setting);
	var focused = selectorMaker($(document).find(':focus')[0]);
	var elementCount = $(display).length;
	var config = 0;
	if (display.closest('.wind').attr('app') == 'configure') {
		config = 1;
	}
	var visible = [];
	$('.app_configure_input[app="' + app + '"]').each(function(i,v) {
	  if ($(v).is(':visible')) {
			visible.push($(v).attr('setting'));
		 }
	});

	$.ajax({
		url: '/manager/configure/appointment_display',
		type: 'GET',
		data: { app: app, config: config, setting: jSetting },
		success: function(response) {

			if (setting.length > 0) {
				$.each(setting, function(i,v) {
					var container = $(response).find('.configuration_ability_container[setting="' + v + '"]').html();
					$('.configuration_ability_container[setting="' + v + '"]').html(container);
				});
			} else {
				display.html(response).show();
			}
			$.each(visible, function(i,v) {
				$('.app_configure_input[app="' + app + '"][setting="' + v + '"]').show().closest('.configuration_ability_container').addClass('open');
			});
			if ($(display).length == elementCount) {
				$(focused).focus();
			}
			else {
				if (elementCount > $(display).length) {
					if (!$(focused).is('select') && $(focused).attr('type') != 'checkbox') {
						$(focused).focus();
						$(document).find(':focus').next();
					}
				}
				else {
					if (!$(focused).is('select') && $(focused).attr('type') != 'checkbox') {
						$(focused).focus();
						$(document).find(':focus').prev();
					}
				}
			}
		}
	});
}

function configurationReloader(app,timeout) {
	if (timeout == undefined) {
		timeout = 50;
	}
	setTimeout(function() {
		var window = $('.wind[app="' + app + '"]');
		var display = window.find('.appointment_display');
		configurationGrabber({ app: app, display: display });
	}, timeout);
}

$(document).on('click', '#backup_now', function() {
	var credential = $('#credential').val();
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/backup_now',
		type: 'GET',
		data: { task: 'backup', timestamp: timestamp, credential: credential },
		success: function(response) {

		}
	});
});

$(document).on('keyup', '.ticket_input', function() {
	var input = $(this);
	var timestamp = Date.now();
	var input_number = input.attr('data-input_number');
	var form = input.closest('.ticket_form');
	if (input_number < 8 && input.val().length > 0) {
		if (input.val().length > 1) {

		}
		else {
			input_number++;
			$('#ticket_number_' + input_number).focus();
		}
	}
	if ( input_number == 8) {
		var numerics = numericals();
		var formData = new FormData(document.getElementById('signatorial_upload'));
		formData.delete('timestamp');
		formData.append('timestamp', timestamp);
		formData.append('numerics', numerics);

		var m =	$('#signatorial_upload_input');
		if (m[0]['files'].length == 0) {
			formData.delete('fileupload');
		}
		$.ajax({
			url: '/manager/configure/password_update',
			type: 'POST',
			data: formData,
			success: function(response) {
				m = undefined;
				formData.delete('fileupload');
				$('#signatorial_upload').remove();
				$('#signatorial_upload_container').html(sig_h);
			},
			cache: false,
			contentType: false,
			processData: false
		});
	}
});
var sig_h;
$(document).on('click', '#signatorial_upload_button', function() {
	var m =	$('#signatorial_upload_input');
	sig_h = $('#signatorial_upload_container').html();
	m.trigger('click');
});


$(document).on('change', '#signatorial_upload_input', function() {
	var m =	$('#signatorial_upload_input');
	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('#ticket_number_0').focus();
	}
});

var mug_h;
$(document).on('click', '.mugshot_upload_button', function() {
	var device = $(this).attr('device');
	var m = $('.mugshot_upload_input[device="' + device + '"]');
	mug_h = $('.mugshot_upload_container[device="' + device + '"]').html();
	m.trigger('click');
});

$(document).on('change', '.mugshot_upload_input', function() {
	var device = $(this).attr('device');
	var m =	$('.mugshot_upload_input[device="' + device + '"]');

	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('.mugshot_upload[device="' + device + '"]').trigger('submit');
	}
});



$(document).on('submit', ".mugshot_upload", function(e) {
	var device = $(this).attr('device');
  e.preventDefault();
	var mui =	$('.mugshot_upload_input[device="' + device + '"]');
  var formData = new FormData(this);
	formData.delete('timestamp');
	formData.append('timestamp', Date.now());
	formData.append('device', device);
  $.ajax({
      url: '/manager/configure/mugshot_upload',
      type: 'POST',
      data: formData,
      success: function (response) {
				$('.mugshot_upload_button[device="' + device + '"]').attr('src', response);
				mug_h = undefined;
				formData.delete('fileupload');
				$('.mugshot_upload[device="' + device + '"]').remove();
				$('.main_upload_container[device="' + device + '"]').html(mug_h);
      },
      cache: false,
      contentType: false,
      processData: false
  });
});

var logo_h;
$(document).on('click', '.logo_upload_button', function() {
	var device = $(this).attr('device');
	var m = $('.logo_upload_input[device="' + device + '"]');
	mug_h = $('.logo_upload_container[device="' + device + '"]').html();
	m.trigger('click');
});

$(document).on('change', '.logo_upload_input', function() {
	var device = $(this).attr('device');
	var m =	$('.logo_upload_input[device="' + device + '"]');

	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('.logo_upload[device="' + device + '"]').trigger('submit');
	}
});



$(document).on('submit', ".logo_upload", function(e) {
	var device = $(this).attr('device');
  e.preventDefault();
	var mui =	$('.logo_upload_input[device="' + device + '"]');
  var formData = new FormData(this);
	formData.delete('timestamp');
	formData.append('timestamp', Date.now());
	formData.append('device', device);
  $.ajax({
      url: '/manager/configure/logo_upload',
      type: 'POST',
      data: formData,
      success: function (response) {
				$('.logo_upload_button[device="' + device + '"]').attr('src', response);
				logo_h = undefined;
				formData.delete('fileupload');
				$('.logo_upload[device="' + device + '"]').remove();
				$('.logo_upload_container[device="' + device + '"]').html(logo_h);
      },
      cache: false,
      contentType: false,
      processData: false
  });
});

$(document).on('click','#sms_list_check',function() {
	var phone = $(this).attr('phone');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/sms_list_check',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
		}
	});
});


$(document).on('click', '.restore_database', function() {
	var b = $(this);
	var text = b.text();
	b.text('* ' + text);
	var filename = b.attr('filename');
	$.ajax({ 
		url: '/manager/configure/restore_now',
		type: 'POST',
		data: { filename: filename },
		success: function(response) {
			response = JSON.parse(response);
			$('#manager_file').text(response.disposition);
			var disposition = 'F';
			if (response.status == 'fail') {
				b.text('N ' + text);
			}
			else {
				b.text('Y ' + text);
			}

			localStorage.removeItem('manager_search_cache');
			setTimeout(function() {
				b.text(text);
			},1500);
		},
		error: function(response) { console.log(response); }
	});
});

$(document).on('click','.merge_database', function() { 
	var b = $(this);
	var text = b.text();
	b.text('* ' + text);
	var filename = b.attr('filename');
	var action = b.attr('action');
	$.ajax({ 
		url: '/manager/configure/merge_database',
		type: 'POST',
		data: { action: action, filename: filename },
		success: function(response) {
			response = JSON.parse(response);
			$('#manager_file').text(response.disposition);
			localStorage.removeItem('manager_search_cache');
			if (response.status == 'fail') {
				b.text('N ' + text);
			}
			else {
				b.text('Y ' + text);
			}
			localStorage.removeItem('manager_search_cache');
			setTimeout(function() {
				b.text(text);
			},1500);
		},
		error: function(response) { console.log(response); }
	});
});


$(document).on('click','#new_database', function() {
	var timestamp = Date.now();
	var president = $('#president').val();
	var credential = $('#credential').val();
	$.ajax({
		url: '/manager/configure/new_database',
		type: 'POST',
		data: { timestamp: timestamp, president: president, credential: credential },
		success: function(response) {
			$('#manager_file').text(response);
		}
	});
});

$(document).on('click', '.vacuum_app', function() {
	var app = $(this).attr('app');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/vacuum_app',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			$('#alert').html(response).show();
		}
	});
});

$(document).on('click', '.app_configure_toggle', function() {
	var app = $(this).attr('app');
	var setting = $(this).attr('setting');
	var input = $('.app_configure_input[app="' + app + '"][setting="' + setting + '"]');
	var container = $(this).closest('.configuration_ability_container');
	if (input.is(':visible')) {
		input.hide();
		container.removeClass('open');
	}
	else {
		input.show();
		container.addClass('open');
	}
});

$(document).on('click', '#vacuum_app_confirm', function() {
	var app = $(this).attr('app');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/vacuum_app_confirm',
		type: 'POST',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			$('#alert').html(response).show();
			$('.appointment_configuration_cell[app="' + app + '"]').remove();
			$('.wind[app="' + app + '"]').remove();
		}
	});
});

$(document).on('click', '.adopt_app', function() {
	var app = $(this).attr('app');
	var scope = localStorage.getItem('scope');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/adopt_app',
		data: { app: app, timestamp: timestamp, scope: scope },
		success: function(response) {
			$('#alert').html(response).show();
		}
	});
});

$(document).on('click', '.adopt_file', function() {
	var file = $(this);
	var adopted = file.attr('adopted');
	if (adopted == 'yes') {
		adopted = 'no';
	}
	else {
		adopted = 'yes';
	}
	file.attr('adopted', adopted);
});

$(document).on('click', '#adopt_app_confirm', function() {
	var files = [];
	var app = $(this).attr('app');
	var timestamp = Date.now();
	$('.adopt_file[adopted="yes"').each(function(i,v) {
		var timestamp = $(v).attr('timestamp');
		var file = $(v).attr('file');
		var app = $(v).attr('app');
		var type = $(v).attr('type');
		files.push({ app: app, type: type, file: file, timestamp: timestamp });
	});
	var jfiles = JSON.stringify(files);
	$.ajax({
		url: '/manager/configure/adopt_app_confirm',
		type: 'POST',
		data: { app: app, timestamp, timestamp, files: jfiles },
		success: function(response) {
			$('#alert').html('').hide();
		}
	});
});

$(document).on('click', '#database_doctor', function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/database_doctor',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});

$(document).on('click', '#database_doctor_confirm', function() {
	var timestamp = Date.now();
	var auuid = $('#alert').attr('uuid');
	$.ajax({
		url: '/manager/configure/database_doctor_confirm',
		type: 'POST',
		data: { timestamp: timestamp, auuid: auuid },
		success: function(response) {
		}
	});
});

$(document).on('click', '#database_vacuum', function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/database_vacuum',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});


$(document).on('click', '#database_vacuum_confirm', function() {
	var timestamp = Date.now();
	var checkboxes = $('#alert').find('.database_vacuum_checkbox');
	var checked = [];
	checkboxes.each(function(i,v) {
		if ($(v).prop('checked') == true) {
			checked.push($(v).attr('app'));
		}
	});

	checked = JSON.stringify(checked);
	$.ajax({
		url: '/manager/configure/database_vacuum_confirm',
		type: 'POST',
		data: { timestamp: timestamp, checkboxes: checked },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});

$(document).on('click', '#database_uuid_cleaner', function() {
	$.ajax({
		url: '/manager/configure/database_uuid_cleaner',
		type: 'POST',
		data: {},
		success: function(response) {

		}
	});
});

$(document).on('click','.create_environment_qr', function() {
	var pos = $(this).attr('pos');
	var app = $(this).attr('app');
	$.ajax({
		url: '/manager/configure/environment/qr',
		type: 'POST',
		data: { pos: pos, app: app },
		success: function(response) {
		}
	});
});

$(document).on('click', '.appointment_distance', function() {
	var a = $(this);
	var app = a.attr('app');
	var app_uuid = a.attr('app_uuid');
	var uuid = a.attr('uuid');
	if (a.attr('armed') == 'yes') {
		a.attr('armed','pending');
		$.ajax({ 
			url: '/manager/configure/home_plate/save',
			data: { app: app, app_uuid: app_uuid, uuid: uuid },
			type: 'POST',
			success: function(response) {
				a.css({'background-color': 'lightgreen' });
				setTimeout(function() {
					a.attr('armed', 'no');
					var obg = a.attr('obg');
					a.css({'background-color': obg });
				},2000);
			}
		});
	}
	else if (a.attr('armed') != 'pending') {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'orange' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change', '.manual_home_plate', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var device = $(this).attr('device');
	var app = $(this).attr('app');

	$.ajax({
		url: '/manager/configure/home_plate/manual',
		type: 'POST',
		data: { app: app, device: device, value: value, setting: setting },
		success: function(response) {
		}
	});
});

$(document).on('click', '.home_plate_setting_save', function() {
	var uuid = $(this).attr('uuid');
	var app = $(this).attr('app');
	var hpSettings = { uuid: uuid };
	$('.home_plate_setting[uuid="' + uuid + '"').each(function(i,v) {
		var setting = $(v).attr('setting');
		var value = $(v).val();
		if ($(v).attr('type') == 'checkbox') {
			if ($(v).prop('checked') == true) {
				value = 'on';
			}
			else {
				value = 'off';
			}
		}
		hpSettings[setting] = value;
	});
	console.log(hpSettings);

	$.ajax({ 
		url: '/manager/configure/home_plate/settings',
		type: 'POST',
		data: {
			home_plate: JSON.stringify(hpSettings),
			timestamp: timestamp,
			app: app
		},
		success: function(response) {
			console.log(response);
			$('.home_plate_configuration[app="' + app + '"]').html(response.html);
		}
	});
});

$(document).on('change', '.home_plate_setting[setting="self"]', function() {
	var check = $(this);
	var uuid = check.attr('uuid');
	var appSetting = $('.home_plate_setting[setting="app"][uuid="' + uuid + '"]');
	if (check.prop('checked') == true) {
		appSetting.hide();
	} else {
		appSetting.show();
	}
});

$(document).on('click', '.home_plate_setting_deleter', function() {
	var app = $(this).attr('app');
	var uuid = $(this).attr('uuid');
	var a = $(this);
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/configure/home_plate/settings/delete',
			type: 'POST',
			data: { uuid: uuid, app: app },
			success: function(response) {
				console.log(response);
				$('.home_plate_setting_container[uuid="' + uuid + '"]').remove();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change', '.nfc_setting', function() {
	var b = $(this);
	var nsettings = $(this).closest('.nfc_settings');
	var app = nsettings.attr('app');
	var setting = b.attr('setting');
	var value = b.val();
	var uuid = nsettings.attr('uuid');
	$.ajax({
		url: '/manager/configure/nfc/setting',
		type: 'POST',
		data: { app: app, setting: setting, value: value, uuid: uuid },
		success: function(response) {
			configurationReloader(app);
		}
	});
});

$(document).on('click', '.nfc_appt_writer', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var app = a.attr('app');
	var msg = { uuid: uuid, app: app, type: 'app' };
	
	nfcWriter(msg,a);

});

$(document).on('click', '.nfc_deleter', function() {
	var a = $(this);

	var armed = a.attr('armed');

	if (armed == 'yes') {
		var uuid = a.attr('uuid');
		var app = a.attr('app');
		$.ajax({
			url: '/manager/configure/nfc/delete',
			type: 'POST',
			data: { app: app, uuid: uuid },
			success:function(response) {
				$('.nfc_settings[app="' + response.app + '"][uuid="' + response.uuid + '"]').remove();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

// A typed contact list (phones/emails): a number or address per row, each with a
// type - mobile, home, work, or a custom label. A new row mints its own uuid and
// is written to the setting on its first field change; every later change finds
// the same row by that uuid.
function contactRowMint() {
	return 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
}
$(document).on('click', '.contact_add', function() {
	var b = $(this);
	var container = b.closest('.contact_list');
	var kind = b.attr('kind') || 'phone';
	var uuid = contactRowMint();
	var row = $('<div class="contact_row"></div>').attr('uuid', uuid);
	var select = $('<select class="contact_field" field="type"></select>');
	$.each(['mobile', 'home', 'work', 'custom'], function (i, t) {
		select.append($('<option></option>').val(t).text(t.charAt(0).toUpperCase() + t.slice(1)));
	});
	row.append(select);
	row.append($('<input class="contact_field contact_label" field="label" placeholder="label" style="display:none;">'));
	row.append($('<input class="contact_field contact_value" field="value">').attr('placeholder', kind));
	row.append('<img src="/icons/trash.png" hint="Delete" class="little_thumb contact_delete hover">');
	container.find('.contact_rows').append(row);
	row.find('.contact_value').focus();
});

$(document).on('change', '.contact_field', function() {
	var f = $(this);
	var row = f.closest('.contact_row');
	var container = f.closest('.contact_list');
	var field = f.attr('field');
	var value = f.val();
	// only a custom entry carries a label of its own; a named type says it all
	if (field === 'type') {
		row.find('.contact_label').toggle(value === 'custom');
	}
	$.ajax({
		url: '/manager/configure/contact/setting',
		type: 'POST',
		data: { app: container.attr('app'), list: container.attr('list'), uuid: row.attr('uuid'), field: field, value: value },
		success: function (response) {
			if (response && response.uuid) { row.attr('uuid', response.uuid); }
		}
	});
});

$(document).on('click', '.contact_delete', function() {
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		var row = a.closest('.contact_row');
		var container = a.closest('.contact_list');
		$.ajax({
			url: '/manager/configure/contact/delete',
			type: 'POST',
			data: { app: container.attr('app'), list: container.attr('list'), uuid: row.attr('uuid') },
			success: function () { row.remove(); }
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');
		},2000);
	}
});










// A stood-down AI provider (out of credit): its paid models are hidden until it
// clears. This clears the flag now, then reloads the panel so the models return.
$(document).on('click', '.ai_avail_clear', function() {
	var bucket = $(this).attr('bucket');
	$.ajax({
		url: '/manager/configure/ai_availability_clear',
		type: 'POST',
		data: { bucket: bucket },
		success: function() {
			$.ajax({
				url: '/manager/configure/plat_setting_list',
				type: 'GET',
				data: { timestamp: Date.now() },
				success: function(response) { $('#plat_setting_list').html(response); }
			});
		}
	});
});

// ---- the rename-merge panel -------------------------------------------
// A rename into a name the house already knows is a merge: the two apps share
// settings, so the panel picks which value keeps the name per setting - the
// renaming app's, the existing app's, or a natural merge for the settings that
// join (nfc tags, measures).
function nameConflictPanel(response) {
	$('#name_conflict_panel').remove();
	var panel = $('<div id="name_conflict_panel" style="position:fixed;left:15%;top:10%;width:70%;max-height:78%;overflow:auto;z-index:994200;background:var(--panel);border:3px solid var(--line);border-radius:12px;padding:14px;box-shadow:0 6px 30px rgba(0,0,0,.5);">');
	panel.append('<h3 style="margin-top:0;">Rename into ' + nameConflictEscape(response.new) + '</h3>');
	panel.append('<p>"' + nameConflictEscape(response.new) + '" is already a name the house knows. For each shared setting, choose which value keeps the name. A value marked <i>(house default)</i> is one nobody ever chose, so the other side is picked for you. A contact either side holds - a phone number, an email, a typed entry - is carried over unless you drop it.</p>');
	var pairs = response.pairs || [];
	if (!pairs.length) { panel.append('<p>No shared settings - the records will simply join.</p>'); }
	$.each(pairs, function (i, p) {
		var prefer = p.prefer || (p.natural ? 'merge' : 'new');
		var row = $('<div style="border-top:1px solid var(--line);padding:8px 0;">');
		row.append('<b>' + settingLabel(p.setting) + '</b><br>');
		if (p.only === 'old') {
			// only the app being renamed holds it: keep it, or drop it
			row.append('<label style="display:block;margin:2px 0;"><input type="radio" name="nc_' + p.setting + '" value="new"' + (prefer === 'new' ? ' checked' : '') + '> keep this app\'s: <span style="opacity:.85;">' + shortSettingValue(p.old_value) + '</span></label>');
			row.append('<label style="display:block;margin:2px 0;"><input type="radio" name="nc_' + p.setting + '" value="old"' + (prefer === 'old' ? ' checked' : '') + '> drop it</label>');
		}
		else if (p.only === 'new') {
			// only the existing record holds it: it stays unless dropped
			row.append('<label style="display:block;margin:2px 0;"><input type="radio" name="nc_' + p.setting + '" value="old"' + (prefer === 'old' ? ' checked' : '') + '> keep ' + nameConflictEscape(response.new) + '\'s: <span style="opacity:.85;">' + shortSettingValue(p.new_value) + '</span></label>');
			row.append('<label style="display:block;margin:2px 0;"><input type="radio" name="nc_' + p.setting + '" value="new"' + (prefer === 'new' ? ' checked' : '') + '> drop it</label>');
		}
		else {
			row.append('<label style="display:block;margin:2px 0;"><input type="radio" name="nc_' + p.setting + '" value="new"' + (prefer === 'new' ? ' checked' : '') + '> this app: <span style="opacity:.85;">' + shortSettingValue(p.old_value) + '</span>' + (p.old_default ? ' <i>(house default)</i>' : '') + '</label>');
			row.append('<label style="display:block;margin:2px 0;"><input type="radio" name="nc_' + p.setting + '" value="old"' + (prefer === 'old' ? ' checked' : '') + '> ' + nameConflictEscape(response.new) + ': <span style="opacity:.85;">' + shortSettingValue(p.new_value) + '</span>' + (p.new_default ? ' <i>(house default)</i>' : '') + '</label>');
			if (p.natural) {
				row.append('<label style="display:block;margin:2px 0;"><input type="radio" name="nc_' + p.setting + '" value="merge"' + (prefer === 'merge' ? ' checked' : '') + '> merge (keep both)</label>');
			}
		}
		panel.append(row);
	});

	var appts = response.appointments;
	var oldRows = (appts && appts.old) ? Number(appts.old.rows != null ? appts.old.rows : (appts.old.sessions || 0)) : 0;
	var newRows = (appts && appts['new']) ? Number(appts['new'].rows != null ? appts['new'].rows : (appts['new'].sessions || 0)) : 0;
	if (appts && appts.old && appts['new'] && (oldRows || newRows)) {
		panel.append('<h4 style="margin-bottom:4px;">What is in each</h4>');
		panel.append(nameConflictSummary('This app: ' + (appts.old.label || response.app), appts.old));
		panel.append(nameConflictSummary('Existing: ' + (appts['new'].label || response.new), appts['new']));
		panel.append('<p style="opacity:.8;">The settings choices above decide which value keeps the name. The history policy below decides what happens to the appointment rows; settings still merge normally.</p>');
		var opts = appts.options || [];
		var defaultPolicy = appts.default_policy || 'keep_all';
		$.each(opts, function (i, o) {
			var bits = [Number(o.sessions || 0) + ' session(s)'];
			if (o.dropped) { bits.push('drop ' + Number(o.dropped) + ' row(s)'); }
			if (o.flagged) { bits.push('flag ' + Number(o.flagged)); }
			var row = $('<label style="display:block;margin:4px 0;' + (o.destructive ? 'border-left:3px solid var(--line);padding-left:7px;' : '') + '">');
			row.append('<input type="radio" name="appt_policy" value="' + nameConflictEscape(o.policy) + '"' + (o.policy === defaultPolicy ? ' checked' : '') + '> ');
			row.append('<b>' + nameConflictEscape(o.label) + '</b> <span style="opacity:.75;">(' + nameConflictEscape(bits.join(', ')) + ')</span>');
			if (o.note) { row.append('<br><span style="opacity:.65;font-size:12px;">' + nameConflictEscape(o.note) + '</span>'); }
			panel.append(row);
		});
		if (appts.proposed_total) {
			var details = $('<details style="margin:8px 0;"><summary>Review ' + Number(appts.proposed_total) + ' candidate(s)</summary></details>');
			$.each(appts.proposed || [], function (i, p) {
				var line = '<div style="border-top:1px solid var(--line);padding:5px 0;">';
				line += '<b>' + nameConflictEscape(p.kind) + '</b> - ' + nameConflictEscape(p.reason) + '<br>';
				if (p.keep) {
					line += 'keep ' + nameConflictEscape(p.keep.app + ' ' + p.keep.start_label + ' -> ' + p.keep.end_label + ' (row ' + p.keep.rowid + ')');
				}
				if (p.drop) {
					line += '<br>drop ' + nameConflictEscape(p.drop.app + ' ' + p.drop.start_label + ' -> ' + p.drop.end_label + ' (row ' + p.drop.rowid + ')');
				}
				if (p.other) {
					line += '<br>other ' + nameConflictEscape(p.other.app + ' ' + p.other.start_label + ' -> ' + p.other.end_label + ' (row ' + p.other.rowid + ')');
				}
				line += '</div>';
				details.append(line);
			});
			if (Number(appts.proposed_total) > (appts.proposed || []).length) {
				details.append('<p style="opacity:.7;">... ' + (Number(appts.proposed_total) - (appts.proposed || []).length) + ' more; the apply step uses the full set.</p>');
			}
			panel.append(details);
		}
	}

	panel.append('<br><button id="name_conflict_go" style="margin-right:8px;">Rename &amp; merge</button><button id="name_conflict_cancel">Cancel</button>');
	// on the body, not inside the Configure panel: mounted in the app list it could
	// land inside a scrolled or hidden ancestor and never be seen - which is what
	// "nothing happened" looked like when a rename met a name the house knows
	$('body').append(panel);
	$('#name_conflict_go').on('click', function () {
		var choices = {};
		panel.find('input[type=radio]:checked').each(function () {
			var name = $(this).attr('name') || '';
			if (name.indexOf('nc_') === 0) { choices[name.replace('nc_', '')] = $(this).val(); }
		});
		var policy = panel.find('input[name=appt_policy]:checked').val() || 'keep_all';
		var selected = null;
		$.each((response.appointments && response.appointments.options) || [], function (i, o) {
			if (o.policy === policy) { selected = o; }
		});
		if (selected && Number(selected.dropped) > 0 && policy !== 'keep_all' && policy !== 'flag') {
			var who = '';
			if (policy === 'keep_old') { who = ' from ' + response.new; }
			else if (policy === 'keep_new') { who = ' from ' + response.app; }
			if (!window.confirm('This will drop ' + Number(selected.dropped) + ' appointment row(s)' + who + '. Continue?')) { return; }
		}
		var button = $(this);
		button.prop('disabled', true).text('Merging...');
		$.ajax({
			url: '/manager/configure',
			type: 'POST',
			data: { app: response.app, setting: 'name_change', value: response.new, choices: JSON.stringify(choices), appt_policy: policy, timestamp: Date.now() },
			success: function (resp) {
				if (resp && typeof resp === 'object' && resp.conflict) { nameConflictPanel(resp); return; }
				if (resp && typeof resp === 'object' && resp.error) {
					window.alert(resp.error);
					button.prop('disabled', false).text('Rename & merge');
					return;
				}
				panel.remove();
				if (typeof appointment_chron === 'function') { appointment_chron(); }
			},
			error: function () {
				button.prop('disabled', false).text('Rename & merge');
				window.alert('The merge request failed; nothing was changed on this screen.');
			}
		});
	});
	$('#name_conflict_cancel').on('click', function () { panel.remove(); });
}

function nameConflictEscape(v) {
	return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
		return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
	});
}

function nameConflictMinutes(ms) {
	if (ms == null || isNaN(Number(ms))) { return '-'; }
	return (Math.round(Number(ms) / 600) / 100) + 'm';
}

function nameConflictMonths(months) {
	if (!months || !months.length) { return ''; }
	var max = 1;
	$.each(months, function (i, m) { max = Math.max(max, Number(m.count || 0)); });
	var out = ['<div style="display:flex;align-items:flex-end;gap:2px;height:28px;margin:6px 0;">'];
	$.each(months, function (i, m) {
		var h = Math.max(2, Math.round((Number(m.count || 0) / max) * 26));
		var op = Number(m.count || 0) ? '1' : '.2';
		out.push('<span title="' + nameConflictEscape(m.month + ': ' + (m.count || 0)) + '" style="display:inline-block;width:7px;height:' + h + 'px;background:var(--line);border-radius:1px;opacity:' + op + ';"></span>');
	});
	out.push('</div>');
	return out.join('');
}

function nameConflictSummary(title, s) {
	if (!s) { return ''; }
	var out = [];
	out.push('<div style="border:1px solid var(--line);border-radius:8px;padding:8px;margin:6px 0;">');
	out.push('<b>' + nameConflictEscape(title) + '</b>');
	var vol = Number(s.sessions || 0) + ' session(s)';
	if (s.rows != null && Number(s.rows) !== Number(s.sessions || 0)) { vol += ' - ' + Number(s.rows) + ' row(s)'; }
	out.push(' - ' + vol);
	if (s.first_label) { out.push('<br>' + nameConflictEscape(s.first_label) + ' -> ' + nameConflictEscape(s.last_label)); }
	if (s.days) { out.push(' - ' + Number(s.days) + ' day(s), ' + nameConflictEscape(s.per_day) + '/day'); }
	if (s.median_ms != null) {
		out.push('<br>median ' + nameConflictMinutes(s.median_ms) + ' - p10 ' + nameConflictMinutes(s.p10_ms) + ' - p90 ' + nameConflictMinutes(s.p90_ms));
	}
	if (s.configured_ms != null) { out.push(' - configured ' + nameConflictMinutes(s.configured_ms)); }
	var types = [];
	$.each(s.by_type || {}, function (k, v) { types.push(k + ' ' + v); });
	if (types.length) { out.push('<br>' + nameConflictEscape(types.join(', '))); }
	var periods = [];
	$.each(s.period || {}, function (k, v) { if (v) { periods.push(k + ' ' + v); } });
	if (periods.length) { out.push(' - ' + nameConflictEscape(periods.join(', '))); }
	out.push(nameConflictMonths(s.months));
	var flags = [];
	if (s.open) { flags.push(s.open + ' open'); }
	if (s.missing_stop) { flags.push(s.missing_stop + ' implied end(s)'); }
	if (s.exact_spare) { flags.push(s.exact_spare + ' exact dupe(s)'); }
	if (s.shared_spare) { flags.push(s.shared_spare + ' shared-stop spare(s)'); }
	if (s.malformed) { flags.push(s.malformed + ' malformed'); }
	if (s.expired) { flags.push(s.expired + ' expired'); }
	out.push('<br><span style="opacity:.75;">' + nameConflictEscape(flags.length ? flags.join(' - ') : 'no data-quality flags') + '</span>');
	if (s.warranty) {
		out.push('<br><span style="opacity:.65;">warranty ' + nameConflictEscape(s.warranty) + ' - ' + Number(s.expired || 0) + ' past it</span>');
	}
	out.push('</div>');
	return out.join('');
}

function settingLabel(s) {
	return String(s == null ? '' : s).replace(/_/g, ' ').replace(/\b\w/g, function (c) { return c.toUpperCase(); });
}

function shortSettingValue(v) {
	v = String(v == null ? '' : v);
	if (v.length > 60) { v = v.slice(0, 60) + '…'; }
	return v.replace(/</g, '&lt;');
}

// Let the Guide suggest how an item is sold (a six-pack, a case) and fill the
// packaging in, so every pack is not typed by hand.
$(document).on('click', '.autofill_packaging', function() {
	var app = $(this).attr('app');
	$.ajax({
		url: '/manager/configure/packaging/suggest',
		type: 'POST',
		data: { app: app, timestamp: Date.now() },
		success: function(response) {
			if (response && response.html) {
				$('.app_packaging_configurator[app="' + app + '"]').html(response.html);
				configurationGrabber({ app: app, setting: ['packaging'] });
			}
		}
	});
});

// ---- the records watch's staging area ---------------------------------------
// The mirror of the error watch's fixes: findings the fixed audit staged, each
// with the rows it proposes to tombstone or repair. Nothing is written until
// Apply. The list re-fetches after each action, and scan now runs the audit.
function recordsRender() {
	var list = $('#records_list');
	list.show().html('Loading…');
	$.get('/manager/records/fixes', function(res) {
		var rows = (res && res.findings) || [];
		$('#records_waiting_n').text(rows.length ? (rows.length + ' waiting') : 'nothing waiting');
		if (!rows.length) { list.html('<div style="opacity:.6;">Nothing waiting.</div>'); return; }
		list.html('');
		$.each(rows, function(i, f) {
			var acts = (f.proposed && f.proposed.actions) || [];
			var line = $('<div style="padding:6px 0;border-top:1px solid var(--line);"></div>');
			line.append($('<div></div>').text((f.kind || '') + ' · ' + (f.app || '') + ' — ' + (f.sample || '')));
			line.append($('<div style="opacity:.7;"></div>').text(acts.length + ' action(s): ' + $.map(acts, function(a){ return a.action + ' ' + String(a.uuid || '').slice(0, 10); }).join(', ')));
			var bar = $('<div style="margin-top:4px;display:flex;gap:8px;flex-wrap:wrap;"></div>');
			$('<button type="button"></button>').addClass('records_apply').attr('uuid', f.uuid).text('Apply').appendTo(bar);
			$('<button type="button"></button>').addClass('records_discard').attr('uuid', f.uuid).text('Discard').appendTo(bar);
			$('<button type="button"></button>').addClass('records_leave_app').attr('uuid', f.uuid).attr('app', f.app || '').text('Leave this app alone').appendTo(bar);
			line.append(bar);
			// the findings a rule cannot judge - a genuinely long appointment - can be put
			// to the Coding agent and talked through before anything is applied
			var area = $('<div class="records_ask_area" style="margin-top:6px;"></div>');
			var ans = $('<div class="records_answer" style="white-space:pre-wrap;opacity:.85;"></div>');
			var askrow = $('<div style="display:flex;gap:6px;margin-top:4px;"></div>');
			$('<input type="text" class="records_ask_q" placeholder="Ask the Coding agent about this finding…"></input>').css({ flex: '1', minWidth: '0' }).appendTo(askrow);
			$('<button type="button"></button>').addClass('records_ask').attr('uuid', f.uuid).text('Ask').appendTo(askrow);
			area.append(ans, askrow);
			line.append(area);
			list.append(line);
		});
	}).fail(function() { list.html('<div style="opacity:.6;">Could not load the findings.</div>'); });
}
$(document).on('click', '#records_open', function() {
	if ($('#records_list').is(':visible')) { $('#records_list').hide(); return; }
	recordsRender();
});
$(document).on('click', '.records_apply', function() {
	var b = $(this); b.prop('disabled', true).text('…');
	$.post('/manager/records/fixes_apply', { uuid: b.attr('uuid') }, function() { recordsRender(); $('#records_fixed_list').hide(); });
});
$(document).on('click', '.records_discard', function() {
	var b = $(this); b.prop('disabled', true).text('…');
	$.post('/manager/records/fixes_discard', { uuid: b.attr('uuid') }, function() { recordsRender(); });
});
// put one finding to the Coding agent and keep the exchange on screen; each turn
// sends the transcript so far, so a follow-up question has the context
$(document).on('click', '.records_ask', function() {
	var b = $(this), area = b.closest('.records_ask_area');
	var qi = area.find('.records_ask_q'), ans = area.find('.records_answer');
	var question = qi.val() || '';
	var history = ans.attr('convo') || '';
	qi.val('');
	b.prop('disabled', true).text('…');
	ans.text((history ? history + '\n' : '') + 'You: ' + question + '\nAgent: thinking…');
	$.post('/manager/records/fixes_ask', { uuid: b.attr('uuid'), question: question, history: history }, function(res) {
		var answer = (res && res.answer) ? res.answer : '(no answer)';
		var convo = (history ? history + '\n' : '') + 'You: ' + question + '\nAgent: ' + answer;
		ans.attr('convo', convo).text(convo);
		b.prop('disabled', false).text('Ask');
	}).fail(function() {
		ans.text(history);
		b.prop('disabled', false).text('Ask');
	});
});
$(document).on('keydown', '.records_ask_q', function(e) {
	if (e.which === 13) { $(this).closest('.records_ask_area').find('.records_ask').trigger('click'); }
});
// a class the person knows is really long: silence the audit for that app
$(document).on('click', '.records_leave_app', function() {
	var b = $(this), app = b.attr('app');
	if (app && !confirm('Leave "' + app + '" alone? The records audit will stop reporting it.')) { return; }
	b.prop('disabled', true).text('…');
	$.post('/manager/records/fixes_exempt', { uuid: b.attr('uuid'), app: app }, function() { recordsRender(); });
});
$(document).on('click', '#records_scan_now', function() {
	var s = $(this); s.text('scanning…');
	$.post('/manager/records/scan', {}, function() {
		s.text('scan now');
		recordsRender();
	});
});
$(document).on('click', '#records_fixed_open', function() {
	var list = $('#records_fixed_list');
	if (list.is(':visible')) { list.hide(); return; }
	list.show().html('Loading…');
	$.get('/manager/records/fixes_fixed', function(res) {
		var rows = (res && res.fixed) || [];
		if (!rows.length) { list.html('<div style="opacity:.6;">Nothing fixed yet.</div>'); return; }
		list.html('');
		$.each(rows, function(i, f) {
			list.append($('<div style="padding:4px 0;border-top:1px solid var(--line);"></div>').text((f.kind || '') + ' · ' + (f.app || '') + ' — ' + (f.sample || '') + ' — ' + (f.note || '')));
		});
	}).fail(function() { list.html('<div style="opacity:.6;">Could not load the list.</div>'); });
});

// ---- the Plat page's sub-tabs (AI / OAuth2) and the OAuth2 client registry ---
$(document).on('click', '#plat_setting_list .cfg_tab_toggle', function() {
	var tab = $(this).attr('tab');
	$('#plat_setting_list .cfg_tab_toggle').removeClass('active');
	$(this).addClass('active');
	$('#plat_setting_list .cfg_tab_panel').hide();
	$('#' + tab).show();
});

function oauthPanelRefresh() {
	$.get('/manager/configure/oauth_panel', function(r) { $('#plat_oauth').html(r); });
}
$(document).on('click', '#oauth_client_add', function() {
	$.post('/manager/configure/oauth_client/add', {}, function() {
		$('#plat_oauth').show();
		$('#plat_setting_list .cfg_tab_toggle').removeClass('active');
		$('#plat_setting_list .cfg_tab_toggle[tab="plat_oauth"]').addClass('active');
		$('#plat_ai').hide();
		oauthPanelRefresh();
	});
});
$(document).on('click', '.oauth_client_remove', function() {
	$.post('/manager/configure/oauth_client/remove', { uuid: $(this).attr('uuid') }, function() { oauthPanelRefresh(); });
});
$(document).on('change', '.oauth_client_field', function() {
	var t = $(this);
	var field = t.attr('field');
	if (field === 'client_secret' && !t.val()) { return; }
	$.post('/manager/configure/oauth_client/save', { uuid: t.attr('uuid'), field: field, value: t.val() }, function() {
		if (field === 'client_secret') { oauthPanelRefresh(); }
	});
});
