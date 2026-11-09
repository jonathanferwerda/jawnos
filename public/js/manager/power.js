// The Power app: one battery reading, the CPU's current state, and the plan
// saved for each power source. The taskbar widget is core (taskbar_power.js);
// this file is the lazy chunk the window loads. Opening a plan saves it and,
// when that source is the one the machine is on, applies it at once.
var powerTimer = null;
var powerStatusData = null;

$(document).on('click', '#power_toggle, .power_toggle', function() {
	powerOpener();
});

function powerOpener(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/power',
		type: 'GET',
		data: { timestamp: timestamp, user_agent: navigator.userAgent },
		success: function(response) {
			if (!response) { return; }
			windowMaker(response.window || response);
			powerBind();
			powerLoad();
		}
	});
}

function powerBind() {
	var window_box = $('.wind[app="power"]');
	if (!window_box.length || window_box.data('power_bound')) { return; }
	window_box.data('power_bound', 1);
	window_box.on('click', '.power_save', function() {
		powerSave($(this).attr('data-source'));
	});
	window_box.on('click', '#power_apply', function() {
		powerApply();
	});
	window_box.on('click', '.power_system_button', function() {
		powerSystem($(this).attr('data-power-action'));
	});
	window_box.on('click', '#power_sleep_save', function() {
		powerSleepSave();
	});
	window_box.on('click', '#power_sleep_now', function() {
		powerSleepNow();
	});
	window_box.on('change', '#power_auto', function() {
		powerAuto($(this).prop('checked'));
	});
	window_box.on('change', '#power_charge', function() {
		powerCharge($(this).val());
	});
	window_box.on('input', '#power_charge', function() {
		$('#power_charge_value').text($(this).val() + '%');
	});
	window_box.on('change', '#power_sleep_plan', function() {
		$(this).data('picked', 1);
		powerSleepFill($(this).val());
	});
	window_box.on('input', '.power_limit', function() {
		var source = $(this).attr('data-source');
		$('#power_limit_value_' + source).text($(this).val() + '%');
	});
	window_box.on('change', '.power_plan_select', function() {
		powerDirty($(this).attr('data-source'));
	});
	window_box.on('change', '.power_limit', function() {
		powerDirty($(this).attr('data-source'));
	});
	if (powerTimer) { clearInterval(powerTimer); }
	powerTimer = setInterval(function() {
		if (!window_box.length || !window_box.is(':visible')) {
			clearInterval(powerTimer);
			powerTimer = null;
			return;
		}
		powerLoad();
	}, 20000);
}

function powerDirty(source) {
	$('#power_save_' + source).addClass('power_dirty');
}

// The CPU clock is reported in MHz but reads better in GHz to two places.
function powerGHz(mhz) {
	if (mhz === undefined || mhz === null || isNaN(parseFloat(mhz))) { return '—'; }
	return (parseFloat(mhz) / 1000).toFixed(2);
}

function powerDuration(hours) {
	var minutes = Math.round((parseFloat(hours) || 0) * 60);
	if (minutes <= 0) { return ''; }
	var h = Math.floor(minutes / 60);
	var m = minutes % 60;
	if (h <= 0) { return m + 'm'; }
	return h + 'h ' + (m < 10 ? '0' + m : m) + 'm';
}

function powerRender(status) {
	powerStatusData = status;
	if (!status || !status.ok) {
		$('#power_status').text(jawnosT('The power reading is unavailable.'));
		return;
	}
	var battery = status.battery || {};
	var charge = String(battery.status || '').toLowerCase();
	var pct = Math.max(0, Math.min(100, Math.round(parseFloat(battery.percentage) || 0)));
	if (battery.present) {
		$('#power_battery_card').show();
		$('#power_battery_fill').css('width', pct + '%');
		$('#power_battery_card').attr('state', charge == 'charging' ? 'charging' : (pct <= 20 ? 'low' : (charge == 'full' ? 'full' : 'normal')));
		$('#power_battery_pct').text(pct + '%');
		var state = '';
		if (charge == 'charging') { state = jawnosT('Charging'); }
		else if (charge == 'discharging') { state = jawnosT('Discharging'); }
		else if (charge == 'full') { state = jawnosT('Full'); }
		$('#power_battery_state').text(state);
		var eta = charge == 'charging' ? battery.charge_eta : battery.discharge_eta;
		var eta_text = '';
		if (eta !== undefined && eta !== null && parseFloat(eta) > 0) {
			eta_text = (charge == 'charging' ? jawnosT('Time to full') : jawnosT('Time left')) + ' ' + powerDuration(eta);
		}
		$('#power_battery_eta').text(eta_text);
	}
	else {
		$('#power_battery_card').hide();
	}
	// The charge ceiling is a battery property: a pack without the sysfs
	// attribute hides the row rather than offering a dead control.
	var charge = status.charge || {};
	if (battery.present && charge.supported) {
		var charge_end = (charge.end !== undefined && charge.end !== null) ? charge.end : (charge.max || 100);
		$('#power_charge').val(charge_end);
		$('#power_charge_value').text(charge_end + '%');
		$('#power_charge_row').show();
	}
	else {
		$('#power_charge_row').hide();
	}
	['ac', 'battery'].forEach(function(source) {
		var entry = (status.config && status.config[source]) || {};
		$('#power_plan_' + source).val(entry.plan || 'balanced');
		$('#power_limit_' + source).val(entry.limit || (source == 'battery' ? 70 : 100));
		$('#power_limit_value_' + source).text((entry.limit || (source == 'battery' ? 70 : 100)) + '%');
		$('#power_source_' + source).attr('active', (status.source || '') == source ? 'yes' : 'no');
		$('#power_save_' + source).removeClass('power_dirty');
	});
	$('#power_auto').prop('checked', status.config && status.config.auto ? true : false);
	var sleepCaps = status.sleep || {};
	// The selector names the profile in effect; its own block, or the shared
	// fallback, fills the four controls. Once the person has picked a profile
	// to edit, a poll must not yank the selector back and discard their edits.
	if (!$('#power_sleep_plan').data('picked')) {
		var sleepPlan = status.sleep_plan || 'balanced';
		$('#power_sleep_plan').val(sleepPlan);
		powerSleepFill(sleepPlan);
	}
	if (sleepCaps.lid) { $('#power_lid_row').show(); } else { $('#power_lid_row').hide(); }
	var sleepTypes = sleepCaps.types || [];
	if (sleepCaps.screen && sleepCaps.screen.supported) {
		$('#power_screen_timeout').prop('disabled', false);
	}
	else {
		$('#power_screen_timeout').prop('disabled', true);
	}
	if (!sleepTypes.length) {
		$('#power_sleep_type').prop('disabled', true);
		$('#power_sleep_now').prop('disabled', true);
		$('#power_sleep_timeout').prop('disabled', true);
		$('#power_sleep_note').text(jawnosT('This machine offers no sleep states.'));
	}
	else {
		$('#power_sleep_type').prop('disabled', false);
		$('#power_sleep_now').prop('disabled', false);
		$('#power_sleep_timeout').prop('disabled', false);
		$('#power_sleep_note').text('');
	}
	var cpu = status.cpu || {};
	if (cpu.supported) {
		$('#power_cpu_note').hide();
		$('#power_cpu_grid').show();
		$('#power_cpu_governor').text(jawnosT('Governor') + ': ' + (cpu.governor || '—'));
		$('#power_cpu_governor_detail').text(cpu.governor || '—');
		$('#power_cpu_epp').text(cpu.epp || '—');
		$('#power_cpu_driver').text(cpu.driver || '—');
		$('#power_cpu_policies').text(cpu.policies || 0);
		$('#power_cpu_freq').text(powerGHz(cpu.cur_mhz) + ' / ' + powerGHz(cpu.max_mhz) + ' GHz');
		$('#power_cpu_turbo').text(cpu.turbo === undefined || cpu.turbo === null ? '—' : (cpu.turbo ? jawnosT('On') : jawnosT('Off')));
	}
	else {
		$('#power_cpu_grid').hide();
		$('#power_cpu_note').show();
	}
	var applied = status.applied || {};
	var applied_here = applied.source && applied.source == status.source;
	if (applied.error && applied_here) {
		$('#power_status').text(jawnosT('The plan could not be applied') + ': ' + applied.error);
	}
	else if (applied.supported === 0 && applied_here) {
		$('#power_status').text(jawnosT('Not available on this machine'));
	}
	else if (applied.plan && applied_here) {
		$('#power_status').text(jawnosT('Applied') + ': ' + powerPlanLabel(applied.plan) + (applied.limit ? ' · ' + applied.limit + '%' : ''));
	}
	else {
		$('#power_status').text('');
	}
}

// The plan's own name. These are the four core labels the plan cards use.
function powerPlanLabel(plan) {
	if (plan == 'saver') { return jawnosT('Power saver'); }
	if (plan == 'performance') { return jawnosT('Performance'); }
	if (plan == 'balanced') { return jawnosT('Balanced'); }
	return jawnosT('Auto');
}

// Only the sleep states this machine reports are offered. Rebuilding the list
// each poll also drops a saved state the machine no longer supports.
var powerSleepLabels = {
	suspend: 'Suspend',
	hibernate: 'Hibernate',
	hybrid_sleep: 'Hybrid suspend',
	suspend_then_hibernate: 'Suspend then hibernate'
};

// The block a profile runs with: its own saved one, or the shared fallback.
function powerSleepPlanBlock(plan) {
	var config = (powerStatusData && powerStatusData.config) || {};
	var profiles = config.profiles || {};
	if (plan && profiles[plan]) { return profiles[plan]; }
	return config.sleep || {};
}

function powerSleepFill(plan) {
	var block = powerSleepPlanBlock(plan);
	$('#power_screen_timeout').val(String(block.screen_timeout === undefined || block.screen_timeout === null ? 0 : block.screen_timeout));
	$('#power_sleep_timeout').val(String(block.sleep_timeout === undefined || block.sleep_timeout === null ? 0 : block.sleep_timeout));
	$('#power_lid_action').val(block.lid_action || 'suspend');
	var caps = (powerStatusData && powerStatusData.sleep) || {};
	powerSleepTypes(caps.types || [], block.sleep_type);
}

function powerSleepTypes(types, wanted) {
	var select = $('#power_sleep_type');
	select.empty();
	var chosen = null;
	(types || []).forEach(function(type) {
		var label = powerSleepLabels[type];
		if (!label) { return; }
		select.append($('<option>').attr('value', type).text(jawnosT(label)));
		if (!chosen) { chosen = type; }
		if (type == wanted) { chosen = type; }
	});
	if (chosen) { select.val(chosen); }
}

function powerCharge(end) {
	$('#power_status').text(jawnosT('Saving…'));
	$.post('/manager/power/charge', { end: end }, function(result) {
		if (!result || !result.ok) {
			$('#power_status').text((result && result.error) ? result.error : jawnosT('The charge limit could not be saved.'));
			return;
		}
		powerLoad();
	}, 'json');
}

function powerSleepSave() {
	var data = {
		screen_timeout: $('#power_screen_timeout').val(),
		sleep_timeout: $('#power_sleep_timeout').val()
	};
	var plan = $('#power_sleep_plan').val();
	if (plan) { data.plan = plan; }
	var lid = $('#power_lid_action').val();
	if (lid) { data.lid_action = lid; }
	var type = $('#power_sleep_type').val();
	if (type) { data.sleep_type = type; }
	$('#power_sleep_status').text(jawnosT('Saving…'));
	$.post('/manager/power/sleep', data, function(result) {
		if (!result || !result.ok) {
			var reason = (result && result.error) ? result.error : jawnosT('The sleep settings could not be saved.');
			$('#power_sleep_status').text(reason);
			return;
		}
		powerSleepReport(result);
		powerLoad();
	}, 'json');
}

// Never claim a change the helper could not make: the screen row is best effort.
function powerSleepReport(result) {
	var applied = result.applied || {};
	var screen = applied.screen || {};
	if (applied.dry_run) {
		$('#power_sleep_status').text(jawnosT('The settings were saved. This machine is in a dry run, so nothing was written.'));
	}
	else if (screen.supported === 0) {
		$('#power_sleep_status').text(jawnosT('The settings were saved, but the screen timer is not available on this machine.'));
	}
	else if (screen.ok === 0) {
		$('#power_sleep_status').text(jawnosT('The settings were saved, but the screen timer could not be changed.'));
	}
	else {
		$('#power_sleep_status').text(jawnosT('The sleep and display settings were saved.'));
	}
}

function powerSleepNow() {
	var type = $('#power_sleep_type').val();
	if (!type) {
		$('#power_sleep_status').text(jawnosT('This machine offers no sleep states.'));
		return;
	}
	$('#power_sleep_status').text(jawnosT('Sleeping…'));
	$.post('/manager/power/sleep_now', { type: type }, function(result) {
		if (!result || !result.ok) {
			var reason = (result && result.error) ? result.error : jawnosT('That did not work.');
			$('#power_sleep_status').text(reason);
		}
	}, 'json');
}

function powerLoad() {
	if (!$('.wind[app="power"]').length) { return; }
	$.ajax({
		url: '/manager/power_status',
		type: 'GET',
		cache: false,
		success: function(status) { powerRender(status); }
	});
}

function powerSave(source) {
	var plan = $('#power_plan_' + source).val();
	var limit = $('#power_limit_' + source).val();
	$('#power_status').text(jawnosT('Saving…'));
	$.post('/manager/power/plan', { source: source, plan: plan, limit: limit }, function(result) {
		if (!result || !result.ok) {
			$('#power_status').text(jawnosT('The plan could not be saved.'));
			return;
		}
		powerLoad();
	}, 'json');
}

function powerAuto(on) {
	$.post('/manager/power/auto', { auto: on ? 1 : 0 }, function(result) {
		if (!result || !result.ok) { $('#power_status').text(jawnosT('The setting could not be saved.')); }
		else { powerLoad(); }
	}, 'json');
}

function powerApply() {
	$('#power_status').text(jawnosT('Applying…'));
	$.post('/manager/power/apply', {}, function(result) {
		if (!result || !result.ok) {
			$('#power_status').text(jawnosT('The plan could not be applied') + (result && result.error ? ': ' + result.error : '.'));
			return;
		}
		powerLoad();
	}, 'json');
}

// Restart, shut down and sleep are the same fixed actions the Leave menu uses.
// The server refuses any word outside power_actions(), so the button carries a
// word, never a command.
function powerSystem(action) {
	var working = action == 'sleep' ? 'Sleeping…' : (action == 'restart' ? 'Restarting…' : 'Shutting down…');
	if (typeof jawnosAlert === 'function') {
		jawnosAlert('<p>' + jawnosT(working) + '</p>', { title: jawnosT('power_leave') });
	}
	$.ajax({
		url: '/manager/power',
		type: 'POST',
		dataType: 'json',
		data: { action: action, timestamp: Date.now() },
		success: function(result) {
			if (result && result.ok) { return; }
			if (typeof jawnosAlert === 'function') { jawnosAlert('<p>' + jawnosT('That did not work.') + '</p>', { title: jawnosT('power_leave') }); }
		},
		error: function() {
			if (typeof jawnosAlert === 'function') { jawnosAlert('<p>' + jawnosT('That did not work.') + '</p>', { title: jawnosT('power_leave') }); }
		}
	});
}
