// The taskbar's battery widget. It is core, not part of the Power app's lazy
// chunk: the battery must be readable before the Power window is ever opened.
// The reading is the same /manager/power_status the app uses, polled once a
// minute while the taskbar is on screen. Clicking the widget opens the app.
var jawnosPowerTaskbarData = null;

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
}

function jawnosPowerTaskbarLoad() {
	if (!$('#taskbar_power').length) { return; }
	if (typeof document !== 'undefined' && document.hidden) { return; }
	$.ajax({
		url: '/manager/power_status',
		type: 'GET',
		cache: false,
		success: function(status) { jawnosPowerTaskbarRender(status); },
		error: function() { $('#taskbar_power').attr('hidden', 'hidden').hide(); }
	});
}

$(document).on('click', '#taskbar_power', function() {
	if (typeof appWindowOpener === 'function') {
		appWindowOpener('power', Date.now(), { visible: 'yes' });
	}
});

$(function() {
	setTimeout(jawnosPowerTaskbarLoad, 1500);
	setInterval(jawnosPowerTaskbarLoad, 60000);
});
