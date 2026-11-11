$(document).on('click', '#update_now_button', function() {
	var button = $(this);
	var status = $('#update_now_status');
	var t = function(s) { return (typeof jawnosT === 'function') ? jawnosT(s) : s; };
	if (button.attr('disabled') == 'disabled') { return; }
	var post = function(force) {
		button.attr('disabled', 'disabled');
		status.text(t(force ? 'updating, discarding local changes…' : 'updating…'));
		$.ajax({
			url: '/manager/configure/update_now',
			type: 'POST',
			dataType: 'json',
			data: { force: force ? 1 : 0, timestamp: Date.now() },
			success: function(r) {
				button.removeAttr('disabled');
				if (r && r.version) { jawnosConfigureVersion(r.version); }
				var s = (r && r.status) || 'unknown';
				if (s == 'updated' || s == 'reset' || s == 'peer/updated') {
					status.text(t('updated — restarting…'));
					return;
				}
				if (s == 'current') { status.text(t('already up to date')); return; }
				if (s == 'none') { status.text(t('no newer code found')); return; }
				if (s == 'ahead' || s == 'diverged' || s == 'peer/diverged') {
					// The tree holds commits the authority does not have, so a plain pull
					// cannot move it. Offer the force the server already knows how to do:
					// reset the checkout hard to the authority's head. The reason is on
					// screen with the question, so declining leaves it there.
					status.text(t('local commits block the update'));
					if (!force) {
						jawnosConfirm(t('Local commits block the update. Discard them and pull the latest code anyway?'), function() {
							post(1);
						});
					}
					return;
				}
				if (s == 'dirty') {
					var files = ((r && r.output) || '').trim();
					status.text(t('local changes block the update') + (files ? ': ' + files.split('\n').slice(0, 3).join(' ') : ''));
					if (!force) {
						jawnosConfirm(t('Local changes block the update. Discard them and update anyway?'), function() {
							post(1);
						});
					}
					return;
				}
				status.text(s + ((r && r.output) ? ': ' + r.output : ''));
			},
			error: function() {
				button.removeAttr('disabled');
				status.text(t('could not update'));
			}
		});
	};
	post(0);
});

// ---- Windows: the install has no checkout to pull ---------------------------
// A Windows house is a git-archive copy with no .git, so the git update above
// has nothing to report for it. It updates the way a Windows program does: the
// manager names the next Setup.exe and a detached helper downloads, verifies
// and runs it. The card stays hidden until the feed offers one.
function windowsUpdateCheck() {
	var card = $('#windows_update_card');
	if (!card.length) { return; }
	// The server pushes deviceLister() on tunnel and peer changes, which would
	// otherwise ask GitHub on every push. One check per open panel is enough;
	// a failed check clears the flag so a later push tries again.
	var panel = card.closest('#device_list');
	if (panel.length && panel.data('windowsUpdateChecked')) { return; }
	if (panel.length) { panel.data('windowsUpdateChecked', 1); }
	$.ajax({
		url: '/manager/windows_update',
		type: 'GET',
		dataType: 'json',
		cache: false,
		data: { timestamp: Date.now() },
		success: function(r) {
			if (!r || !r.available) { card.hide(); return; }
			$('#windows_update_version').text(r.version || '');
			card.css('display', 'flex');
		},
		error: function() {
			if (panel.length) { panel.removeData('windowsUpdateChecked'); }
			card.hide();
		}
	});
}
$(document).on('click', '#windows_update_button', function() {
	var button = $(this);
	var status = $('#windows_update_status');
	var t = function(s) { return (typeof jawnosT === 'function') ? jawnosT(s) : s; };
	if (button.attr('disabled') == 'disabled') { return; }
	button.attr('disabled', 'disabled');
	status.text(t('installing — the app will restart when it is ready'));
	$.ajax({
		url: '/manager/windows_update',
		type: 'POST',
		dataType: 'json',
		data: { timestamp: Date.now() },
		success: function(r) {
			if (r && r.ok) { return; }
			button.removeAttr('disabled');
			status.text((r && r.error) || t('could not start the update'));
		},
		error: function() {
			button.removeAttr('disabled');
			status.text(t('could not start the update'));
		}
	});
});

// ---- system dependencies a code update left for a person ---------------------
// scripts/jawnos_deps.pl --after-update installs the system packages a new tree
// needs when sudo already works without a password. When it does not, it leaves
// a request; this lists what would be installed and asks for the password at
// the machine that owns the packages. The password goes to sudo on stdin and is
// never written anywhere else.
var jawnos_deps_pending = null;

function jawnosDepsT(s) { return (typeof jawnosT === 'function') ? jawnosT(s) : s; }

function jawnosDepsPackageList(pending) {
	var missing = (pending && pending.missing) || [];
	var out = [];
	for (var i = 0; i < missing.length; i++) {
		var m = missing[i] || {};
		var label = m.label || '';
		var pkg = m.package || '';
		out.push(label && pkg && label != pkg ? (label + ' — ' + pkg) : (label || pkg));
	}
	return out;
}

function jawnosDepsCard() {
	var button = $('#deps_pending_button');
	if (!button.length) { return; }
	var pending = jawnos_deps_pending;
	if (!pending) {
		button.hide();
		$('#deps_pending_status').text('');
		return;
	}
	var pkgs = (pending.packages || []).filter(function (p) { return !!p; });
	$('#deps_pending_status').text(jawnosDepsT('system packages waiting:') + ' ' + pkgs.join(', '));
	button.show();
}

function jawnosDepsPrompt(pending) {
	if (!pending) { return; }
	jawnosAlert('', { title: jawnosDepsT("Install the update's system packages") });
	var body = $('#alert').empty();
	body.append($('<p>').text(jawnosDepsT('The update needs system packages that are not installed:')));
	var list = $('<ul class="deps_pending_list"></ul>');
	$.each(jawnosDepsPackageList(pending), function (i, text) {
		list.append($('<li>').text(text));
	});
	body.append(list);
	var commands = pending.commands || [];
	if (commands.length) {
		body.append($('<p>').text(jawnosDepsT('They are installed with:')));
		body.append($('<pre class="deps_pending_commands"></pre>').text(commands.join('\n')));
	}
	var row = $('<div class="deps_pending_form"></div>');
	row.append($('<label for="deps_root_password"></label>').text(jawnosDepsT('Root password')));
	row.append($('<input type="password" id="deps_root_password" autocomplete="new-password">'));
	body.append(row);
	var buttons = $('<div class="deps_pending_buttons"></div>');
	buttons.append($('<button type="button" id="deps_install" class="button"></button>').text(jawnosDepsT('Install')));
	buttons.append($('<button type="button" id="deps_later" class="button"></button>').text(jawnosDepsT('Not now')));
	body.append(buttons);
	body.append($('<div id="deps_pending_dialog_status" class="device_when"></div>'));
	body.append($('<pre id="deps_pending_output" class="deps_pending_commands" style="display:none;"></pre>'));
	$('#deps_root_password').focus();
}

function jawnosDepsCheck(force) {
	$.ajax({
		url: '/manager/configure/deps_pending',
		type: 'GET',
		dataType: 'json',
		cache: false,
		success: function (r) {
			var pending = (r && r.pending) ? r.pending : null;
			jawnos_deps_pending = pending;
			jawnosDepsCard();
			if (!pending || !r.local) { return; }
			var dismissed = '';
			try { dismissed = localStorage.getItem('jawnos_deps_dismissed') || ''; } catch (e) {}
			if (!force && dismissed && dismissed == String(pending.timestamp)) { return; }
			// a dialog already on screen is the person's to answer; do not rebuild
			// it under their hands when the Dev listing refreshes
			if ($('#deps_install').length) { return; }
			jawnosDepsPrompt(pending);
		}
	});
}

$(document).on('click', '#deps_later', function () {
	try {
		if (jawnos_deps_pending && jawnos_deps_pending.timestamp) {
			localStorage.setItem('jawnos_deps_dismissed', String(jawnos_deps_pending.timestamp));
		}
	} catch (e) {}
	jawnosAlertClose();
});

$(document).on('click', '#deps_install', function () {
	var button = $(this);
	var status = $('#deps_pending_dialog_status');
	var field = $('#deps_root_password');
	var password = field.val();
	field.val('');
	if (!password) { status.text(jawnosDepsT('Enter the root password.')); return; }
	button.attr('disabled', 'disabled');
	status.text(jawnosDepsT('installing…'));
	$.ajax({
		url: '/manager/configure/deps_install',
		type: 'POST',
		dataType: 'json',
		data: { password: password, timestamp: Date.now() },
		success: function (r) {
			button.removeAttr('disabled');
			if (r && r.ok && !r.pending) {
				status.text(jawnosDepsT('installed.'));
				jawnos_deps_pending = null;
				jawnosDepsCard();
				try { localStorage.removeItem('jawnos_deps_dismissed'); } catch (e) {}
				setTimeout(function () { jawnosAlertClose(); }, 1500);
				return;
			}
			jawnos_deps_pending = (r && r.pending) ? r.pending : jawnos_deps_pending;
			jawnosDepsCard();
			var output = $('#deps_pending_output');
			if (r && r.output) { output.text(r.output).show(); } else { output.text('').hide(); }
			status.text((r && (r.error || r.reason)) ? (r.error || r.reason) : jawnosDepsT('the packages were not installed.'));
		},
		error: function () {
			button.removeAttr('disabled');
			status.text(jawnosDepsT('could not install the packages.'));
		}
	});
});

$(document).on('click', '#deps_pending_button', function () {
	jawnosDepsCheck(true);
});

$(document).ready(function () { jawnosDepsCheck(); });

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
	var timestamp = Date.now();
	var ping = $('#ping_results').html();
	$.ajax({
		url: '/manager/configure/device_lister',
		type: 'GET',
		data: { timestamp: timestamp, load_type: load_type, host: host },
		success: function(response) {
			var keep = gimmeInputSnapshot($('#device_list'));
			$('#device_list').html(response);
			$('#ping_results').html(ping);
			printerInkLoad($('#device_list'));
			// The auto-reload switch rides the update card in this panel; it is
			// localStorage, so it is painted from the browser, not the response.
			if (typeof jawnosUpdateAutoreloadPaint === 'function') { jawnosUpdateAutoreloadPaint(); }
			if (jawnosConfigureShow('device_lister', $('#device_list'))) {
				b.attr('status', 'active');
				// Only a panel that is actually on screen needs its queues read; a
				// load that lost the race to another tab must not start one.
				printerQueuesLoad($('#device_list'));
			}
			b.text(text);
			deviceListerRestoreButtons($('#device_list'));
			gimmeInputRestore($('#device_list'), keep);
		}
	}).fail(function(e) {
		b.text(text);
		$('#ping_results').text('scan failed (' + e.status + ')');
	});
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

// The Dev listing is repainted in place whenever a peer appears (the server pushes
// deviceLister()), and the gimme window is typed inside that HTML. Carry a
// half-typed value - and the caret - across the repaint so a push cannot wipe it.
function gimmeInputSnapshot(scope) {
	var keep = { values: {}, focus: null };
	$(scope).find('.gimme_input').each(function() {
		var v = $(this).val();
		if (v !== undefined && v !== null && v !== '') {
			keep.values[$(this).attr('signatorial') + '|' + $(this).attr('uuid')] = v;
		}
	});
	var active = document.activeElement;
	if (active && scope && scope[0] && scope[0].contains(active) && $(active).hasClass('gimme_input')) {
		keep.focus = {
			key: $(active).attr('signatorial') + '|' + $(active).attr('uuid'),
			start: active.selectionStart,
			end: active.selectionEnd
		};
	}
	return keep;
}

function gimmeInputRestore(scope, keep) {
	if (!keep) { return; }
	$(scope).find('.gimme_input').each(function() {
		var el = this;
		var key = $(el).attr('signatorial') + '|' + $(el).attr('uuid');
		if (keep.values[key] !== undefined) { $(el).val(keep.values[key]); }
		if (keep.focus && keep.focus.key === key) {
			el.focus();
			if (keep.focus.start !== null && el.setSelectionRange) {
				try { el.setSelectionRange(keep.focus.start, keep.focus.end); } catch (e) {}
			}
		}
	});
}

// Re-fetch the Dev listing in place. The server pushes this as the console command
// deviceLister() when a tunnel comes up or goes down (and when a peer is
// enrolled), so the Dev panel shows a machine dialling in without a manual Scan.
// It acts only while the Dev panel is open.
function deviceLister() {
	var c = $('#device_list');
	if (!c.length || !c.is(':visible')) { return; }
	var focus = document.activeElement;
	if (focus && focus !== document.body && c.find(focus).length
		&& /^(INPUT|TEXTAREA|SELECT)$/.test(focus.tagName)) {
		// The server pushes deviceLister() when a peer or tunnel changes.
		// Re-rendering under someone's cursor steals the field, so wait
		// until they leave it and then apply the listing once.
		if (!c.data('listerWait')) {
			c.data('listerWait', 1);
			$(focus).one('blur', function () {
				c.removeData('listerWait');
				deviceLister();
			});
		}
		return;
	}
	$.ajax({
		url: '/manager/configure/device_lister',
		type: 'GET',
		data: { timestamp: Date.now(), load_type: 'list' },
		success: function(response) {
			var keep = gimmeInputSnapshot(c);
			c.html(response);
			jawnosDepsCheck();
			if (typeof jawnosUpdateAutoreloadPaint === 'function') { jawnosUpdateAutoreloadPaint(); }
			printerInkLoad(c);
			printerQueuesLoad(c);
			deviceListerRestoreButtons(c);
			windowsUpdateCheck();
			gimmeInputRestore(c, keep);
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

// The Dev panel draws its printer card at once and fills it a moment later:
// lpstat talks to cupsd, and a machine with a network printer can take seconds
// to answer, which used to hold the whole panel. The card reserves one line of
// height while it waits, and if it does grow, a reader who has already scrolled
// past it keeps their place: the growth is given back to the scroll offset so
// the content below does not jump.
function printerQueuesLoad(scope) {
	var card = $(scope || document).find('#printer_card').first();
	if (!card.length || card.data('queues_loading')) { return; }
	card.data('queues_loading', true);
	card.data('queues_height', card[0].getBoundingClientRect().height);
	var line = card.find('#printer_queues_line');
	var sel = card.find('#default_printer_select');
	var initial = sel.val();
	$.getJSON('/manager/configure/printer_list', { queues_only: 1 })
		.done(function(r) {
			var printers = (r && r.printers) || [];
			// A person may have picked a queue while this was in flight: keep their
			// choice, otherwise take the validated saved default.
			var current = sel.val();
			var keep = (current !== initial) ? current : ((r && typeof r.default === 'string') ? r.default : '');
			var ask = card.attr('data-ask') || 'Ask each time';
			var sysdef = card.attr('data-system-default') || 'system default';
			var found = false;
			sel.empty().append($('<option value=""></option>').text(ask));
			$.each(printers, function(i, p) {
				if (!p || !p.name) { return; }
				var label = p.name + (p.default ? ' (' + sysdef + ')' : '');
				sel.append($('<option></option>').attr('value', p.name).text(label));
				if (keep && p.name === keep) { found = true; }
			});
			sel.val(found ? keep : '');
			if (!printers.length) {
				line.text(card.attr('data-none') || 'No CUPS printers yet.');
			}
			else {
				line.text((card.attr('data-queues') || 'CUPS queues') + ': ' + $.map(printers, function(p) { return p.name; }).join(', '));
			}
			printerQueuesSettle(card);
		})
		.fail(function() {
			line.text(card.attr('data-unavailable') || 'Printers unavailable.');
			printerQueuesSettle(card);
		});
}

// Give back the height the card grew to a reader who has scrolled past it. Only
// a card fully above the visible area can push the text they are reading; a card
// still on screen is expected to grow downward.
function printerQueuesSettle(card) {
	card.removeData('queues_loading');
	var panel = card.closest('.wind').find('#configure')[0];
	if (!panel) { return; }
	var rect = card[0].getBoundingClientRect();
	var before = card.data('queues_height') || rect.height;
	var view = panel.getBoundingClientRect();
	if (rect.bottom <= view.top) {
		var grew = rect.height - before;
		if (grew > 0) {
			panel.scrollTop += grew;
			window.jawnos_configure_bar_last = panel.scrollTop;
		}
	}
	card.removeData('queues_height');
}

// Clicking a readout asks the printer again, so a cartridge just changed shows at
// once without waiting for another Scan.
$(document).on('click', '.printer_ink', function() {
	var el = $(this);
	el.removeData('ink_loaded');
	el.find('.printer_ink_body').text('reading…');
	printerInkLoad(el);
});

