// The taskbar's battery widget. It is core, not part of the Power app's lazy
// chunk: the battery must be readable before the Power window is ever opened.
// The reading is the same /manager/power_status the app uses, polled once a
// minute while the taskbar is on screen.
//
// Clicking the widget opens a panel hung under it (taskbar_panel.js owns the
// frame). The panel is a quick glance and a short reach: the battery summary,
// the power profile for the source the machine is on right now, and a way into
// the app. Its contents are rebuilt on every open from the cached reading and
// again when a fresh /manager/power_status lands. A profile write asks for the
// status again instead of trusting its own answer, because saving a plan also
// applies it when that source is live.
var jawnosPowerTaskbarData = null;
// True while a plan write is in flight: a poll must not rebuild the panel and
// hand back enabled buttons mid-request.
var jawnosPowerTaskbarPanelBusy = false;

function jawnosPowerTaskbarDuration(hours) {
	var minutes = Math.round((parseFloat(hours) || 0) * 60);
	if (minutes <= 0) { return ''; }
	var h = Math.floor(minutes / 60);
	var m = minutes % 60;
	if (h <= 0) { return m + 'm'; }
	return h + 'h ' + (m < 10 ? '0' + m : m) + 'm';
}

function jawnosPowerTaskbarRender(status) {
	var widget = $('#taskbar_power');
	if (!widget.length) { return; }
	jawnosPowerTaskbarData = status;
	var battery = status && status.battery;
	if (!status || !status.ok || !battery || !battery.present) {
		widget.attr('hidden', 'hidden').hide();
		jawnosPowerTaskbarPanelSync();
		return;
	}
	var pct = Math.max(0, Math.min(100, Math.round(parseFloat(battery.percentage) || 0)));
	var state = String(battery.status || '').toLowerCase();
	var charging = state == 'charging';
	var eta = charging ? battery.charge_eta : battery.discharge_eta;
	var text = pct + '%';
	if (state == 'full') {
		text = pct + '% ' + jawnosT('Full');
	}
	else if (eta !== undefined && eta !== null && parseFloat(eta) > 0) {
		text = pct + '% ' + (charging ? '↑ ' : '↓ ') + jawnosPowerTaskbarDuration(eta);
	}
	widget.find('.taskbar_power_fill').css('width', pct + '%');
	widget.attr('state', charging ? 'charging' : (pct <= 20 ? 'low' : (state == 'full' ? 'full' : 'normal')));
	widget.find('.taskbar_power_text').text(text);
	var title = jawnosT('Power') + ' — ' + pct + '%';
	if (state == 'charging') { title += ' — ' + jawnosT('Charging'); }
	else if (state == 'discharging') { title += ' — ' + jawnosT('Discharging'); }
	if (eta !== undefined && eta !== null && parseFloat(eta) > 0) {
		title += ' — ' + (charging ? jawnosT('Time to full') : jawnosT('Time left')) + ' ' + jawnosPowerTaskbarDuration(eta);
	}
	widget.attr('title', title).removeAttr('hidden').show();
	jawnosPowerTaskbarPanelSync();
}

function jawnosPowerTaskbarLoad() {
	if (!$('#taskbar_power').length) { return; }
	if (typeof document !== 'undefined' && document.hidden) { return; }
	$.ajax({
		url: '/manager/power_status',
		type: 'GET',
		cache: false,
		success: function(status) { jawnosPowerTaskbarRender(status); },
		error: function() {
			$('#taskbar_power').attr('hidden', 'hidden').hide();
			jawnosPowerTaskbarPanelNote(jawnosT('The battery reading failed.'));
		}
	});
}

// ------------------------------------------------------------------ panel

function jawnosPowerTaskbarPanelOpen() {
	return typeof jawnosTaskbarPanelIsOpen === 'function'
		&& jawnosTaskbarPanelIsOpen('taskbar_power_panel');
}

function jawnosPowerTaskbarPanelNote(text) {
	if (!jawnosPowerTaskbarPanelOpen()) { return; }
	$('#taskbar_power_panel').find('[data-power-note]').text(text || '');
}

// A fresh reading on every open, and again after a write. The render repaints
// the widget and, unless a write is still out, rebuilds the panel in place.
function jawnosPowerTaskbarPanelReload() {
	$.ajax({
		url: '/manager/power_status',
		type: 'GET',
		cache: false,
		success: function(status) { jawnosPowerTaskbarRender(status); },
		error: function() { jawnosPowerTaskbarPanelNote(jawnosT('The battery reading failed.')); }
	});
}

// A panel opened before the first reading fills itself in when that reading
// lands, and a poll while it is open keeps the marked profile honest.
function jawnosPowerTaskbarPanelSync() {
	if (jawnosPowerTaskbarPanelBusy) { return; }
	if (!jawnosPowerTaskbarPanelOpen()) { return; }
	var panel = $('#taskbar_power_panel');
	if (!panel.length) { return; }
	jawnosPowerTaskbarPanelBuild(panel);
}

function jawnosPowerTaskbarPanelBattery(panel) {
	var status = jawnosPowerTaskbarData;
	var battery = (status && status.battery) || null;
	var section = $('<div class="taskbar_panel_section"></div>');
	section.append($('<h4></h4>').text(jawnosT('Battery')));
	if (!status || !status.ok || !battery) {
		section.append($('<p class="taskbar_panel_empty"></p>').text(jawnosT('The battery reading has not arrived yet.')));
		panel.append(section);
		return;
	}
	if (!battery.present) {
		section.append($('<p class="taskbar_panel_empty"></p>').text(jawnosT('This machine has no battery.')));
		panel.append(section);
		return;
	}
	var pct = Math.max(0, Math.min(100, Math.round(parseFloat(battery.percentage) || 0)));
	var state = String(battery.status || '').toLowerCase();
	var charging = state == 'charging';
	var badge = '';
	if (state == 'full') { badge = jawnosT('Full'); }
	else if (charging) { badge = jawnosT('Charging'); }
	else if (state == 'discharging') { badge = jawnosT('Discharging'); }
	var row = $('<div class="taskbar_panel_row"></div>');
	row.append($('<span class="taskbar_panel_label"></span>').text(jawnosT('Battery')));
	row.append($('<span class="taskbar_panel_value"></span>').text(pct + '%'));
	if (badge) {
		row.append($('<span class="taskbar_panel_badge"></span>').text(badge));
	}
	section.append(row);
	var eta = charging ? battery.charge_eta : battery.discharge_eta;
	if (eta !== undefined && eta !== null && parseFloat(eta) > 0) {
		var time_row = $('<div class="taskbar_panel_row"></div>');
		time_row.append($('<span class="taskbar_panel_label"></span>').text(charging ? jawnosT('Time to full') : jawnosT('Time left')));
		time_row.append($('<span class="taskbar_panel_value"></span>').text(jawnosPowerTaskbarDuration(eta)));
		section.append(time_row);
	}
	panel.append(section);
}

// The app keeps a plan for ac and one for battery; this edits the one for the
// source the machine is on now, and preserves that source's saved CPU limit.
function jawnosPowerTaskbarPanelProfile(panel) {
	var status = jawnosPowerTaskbarData;
	var live = !!(status && status.ok && status.source);
	var source = live ? String(status.source) : '';
	var entry = (live && (status.config || {})[source]) || {};
	var current = entry.plan || 'balanced';
	var section = $('<div class="taskbar_panel_section"></div>');
	section.append($('<h4></h4>').text(jawnosT('Power profile')));
	if (source == 'ac') {
		section.append($('<div class="taskbar_panel_note"></div>').text(jawnosT('On AC power')));
	}
	else if (source == 'battery') {
		section.append($('<div class="taskbar_panel_note"></div>').text(jawnosT('On battery power')));
	}
	var plans = [
		['auto', jawnosT('Auto')],
		['saver', jawnosT('Power saver')],
		['balanced', jawnosT('Balanced')],
		['performance', jawnosT('Performance')]
	];
	// The section is a flex column, so the four choices stack as a menu.
	for (var i = 0; i < plans.length; i++) {
		var button = $('<button type="button"></button>')
			.attr('data-power-plan', plans[i][0])
			.attr('aria-pressed', plans[i][0] == current ? 'true' : 'false')
			.text(plans[i][1]);
		if (plans[i][0] == current) { button.addClass('taskbar_panel_active'); }
		section.append(button);
	}
	section.append($('<p class="taskbar_panel_note"></p>').attr('data-power-note', '1'));
	panel.append(section);
}

function jawnosPowerTaskbarPanelBuild(panel) {
	if (!panel || !panel.length) { return; }
	panel.empty();
	jawnosPowerTaskbarPanelBattery(panel);
	jawnosPowerTaskbarPanelProfile(panel);
	var footer = $('<div class="taskbar_panel_footer"></div>');
	footer.append($('<button type="button" class="taskbar_panel_open"></button>')
		.attr('data-app', 'power')
		.text(jawnosT('Open Power')));
	panel.append(footer);
}

$(document).on('click', '#taskbar_power', function() {
	if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
	if (typeof jawnosTaskbarPanelToggle !== 'function') { return; }
	jawnosTaskbarPanelToggle('taskbar_power_panel', '#taskbar_power', jawnosPowerTaskbarPanelBuild);
	if (jawnosPowerTaskbarPanelOpen()) { jawnosPowerTaskbarPanelReload(); }
});

$(document).on('click', '#taskbar_power_panel [data-power-plan]', function() {
	var button = $(this);
	var panel = button.closest('#taskbar_power_panel');
	if (jawnosPowerTaskbarPanelBusy) { return; }
	var status = jawnosPowerTaskbarData;
	if (!status || !status.ok || !status.source) {
		jawnosPowerTaskbarPanelNote(jawnosT('The battery reading has not arrived yet.'));
		return;
	}
	var plan = button.attr('data-power-plan') || '';
	if (!plan) { return; }
	var source = String(status.source);
	// Keep the limit the app saved for this source; only the plan changes.
	var limit = ((status.config || {})[source] || {}).limit;
	jawnosPowerTaskbarPanelBusy = true;
	panel.find('[data-power-plan]').prop('disabled', true);
	jawnosPowerTaskbarPanelNote(jawnosT('Saving…'));
	$.ajax({
		url: '/manager/power/plan',
		type: 'POST',
		dataType: 'json',
		data: { source: source, plan: plan, limit: limit }
	}).done(function(response) {
		jawnosPowerTaskbarPanelBusy = false;
		// Re-enable before the reload so a failed reading cannot strand them.
		panel.find('[data-power-plan]').prop('disabled', false);
		if (response && response.ok) {
			jawnosPowerTaskbarPanelNote('');
			jawnosPowerTaskbarPanelReload();
			return;
		}
		jawnosPowerTaskbarPanelNote((response && response.error) || jawnosT('The power profile could not be saved.'));
	}).fail(function(xhr) {
		jawnosPowerTaskbarPanelBusy = false;
		panel.find('[data-power-plan]').prop('disabled', false);
		jawnosPowerTaskbarPanelNote(jawnosT('The request failed.') + ' (' + xhr.status + ')');
	});
});

$(function() {
	setTimeout(jawnosPowerTaskbarLoad, 1500);
	setInterval(jawnosPowerTaskbarLoad, 60000);
});
