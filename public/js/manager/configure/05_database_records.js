$(document).on('click', '#database_vacuum', function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/database_vacuum',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			jawnosAlert(response.html);
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
			jawnosAlert(response.html);
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

