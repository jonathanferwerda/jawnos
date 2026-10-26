// The Clock app: four faces in one window, plus the little menu that hangs from
// the taskbar clock. Alarms and timers are server rows (routes under
// /manager/clock) so they fire even with no window open; the stopwatch and the
// world-clock list belong to the browser and live in localStorage.

var jawnosClockOffset = 0;
var jawnosClockState = null;
var jawnosClockRinging = [];
var jawnosClockRingingCurrent = null;
var jawnosClockPollTimer = null;
var jawnosClockTickTimer = null;
var jawnosClockObserver = null;
var jawnosClockObserverTimer = null;
var jawnosClockSaveTimers = {};
var jawnosClockStopwatch = null;
var jawnosClockWorld = null;

function jawnosClockEsc(value) {
	return $('<div>').text(value === undefined || value === null ? '' : String(value)).html();
}

function jawnosClockPad(n) {
	n = parseInt(n, 10);
	return (n < 10 ? '0' : '') + (isNaN(n) ? 0 : n);
}

function jawnosClockTime(hour, minute) {
	return jawnosClockPad(hour) + ':' + jawnosClockPad(minute);
}

// The alarm time field is a plain text box so the JawnOS soft keyboard shows
// digits (a native time picker is hard to use on the phone and WebKit's own
// picker is not the app's). Accept 7, 730, 0730, 7:30 and 07:30 alike and clamp
// to a real clock time, falling back to 07:00 when there is nothing to read.
function jawnosClockParseTime(value) {
	var digits = String(value === undefined || value === null ? '' : value).replace(/[^0-9]/g, '');
	var hour = 7;
	var minute = 0;
	if (digits.length) {
		if (digits.length <= 2) {
			hour = parseInt(digits, 10);
		}
		else {
			if (digits.length == 3) { digits = '0' + digits; }
			hour = parseInt(digits.slice(0, 2), 10);
			minute = parseInt(digits.slice(2, 4), 10);
		}
	}
	if (isNaN(hour)) { hour = 7; }
	if (isNaN(minute)) { minute = 0; }
	return [Math.min(23, Math.max(0, hour)), Math.min(59, Math.max(0, minute))];
}

function jawnosClockSnoozeValue(minutes) {
	minutes = parseInt(minutes, 10);
	if (isNaN(minutes) || minutes < 1) { minutes = 5; }
	return Math.min(60, minutes);
}

function jawnosClockSnoozeText(minutes) {
	return jawnosT('snooze') + ' ' + jawnosClockSnoozeValue(minutes) + ' ' + jawnosT('minutes');
}

function jawnosClockDeliveredTime(ms) {
	var when = new Date(parseInt(ms, 10));
	if (isNaN(when.getTime())) { return ''; }
	return jawnosClockTime(when.getHours(), when.getMinutes());
}

function jawnosClockNow() {
	return Date.now() + jawnosClockOffset;
}

function jawnosClockApp() {
	return $('.clock_app');
}

function jawnosClockActiveTab() {
	var app = jawnosClockApp().first();
	return app.length ? (app.attr('data-clock-tab') || 'alarm') : 'alarm';
}

// Open the Clock window on one of its four faces. A window already open is
// brought forward and switched rather than replaced, so the stopwatch keeps
// running across a visit to the alarm list.
function jawnosClockOpen(tab) {
	tab = tab || 'alarm';
	var existing = $('.wind[app="clock"]');
	if (existing.length) {
		if (existing.attr('visible') != 'yes') {
			existing.show().attr('visible', 'yes');
			if (typeof windowDimensionSetter == 'function') { windowDimensionSetter(existing); }
		}
		if (typeof topLevelNow == 'function') { topLevelNow(existing); }
		existing.attr('data-clock-explicit', 'yes');
		jawnosClockTab(tab);
		jawnosClockFill();
		return;
	}
	$.ajax({
		url: '/manager/clock',
		type: 'GET',
		data: { window_maker: 'yes', tab: tab, timestamp: Date.now() },
		success: function (response) {
			if (!response) { return; }
			windowMaker(response);
			$('.wind[app="clock"]').attr('data-clock-explicit', 'yes');
			jawnosClockTab(tab);
			jawnosClockFill();
		}
	});
}

// The face a person last used is remembered by this browser, so a window that
// the manager rebuilds (a timer that starts an appointment redraws it) comes
// back on the face that was open instead of on Alarm.
function jawnosClockTabRemembered() {
	try { return localStorage.getItem('jawnos_clock_tab') || ''; } catch (e) { return ''; }
}

function jawnosClockTabRemember(tab) {
	try { localStorage.setItem('jawnos_clock_tab', tab || 'alarm'); } catch (e) {}
}

function jawnosClockTab(tab) {
	tab = tab || 'alarm';
	jawnosClockTabRemember(tab);
	jawnosClockApp().each(function () {
		var app = $(this);
		app.attr('data-clock-tab', tab);
		app.find('.clock_tab').each(function () {
			var selected = $(this).attr('data-clock-tab') == tab;
			$(this).toggleClass('selected', selected).attr('aria-selected', selected ? 'true' : 'false');
		});
		app.find('.clock_panel').each(function () {
			$(this).toggleClass('selected', $(this).attr('data-clock-panel') == tab);
		});
	});
	if (tab == 'stopwatch') { jawnosClockRenderStopwatch(); }
	if (tab == 'world') { jawnosClockRenderWorld(); }
}

$(document).on('click', '#clock_toggle, .clock_nav_item[data-clock-open]', function (e) {
	var tab = $(this).attr('data-clock-open') || 'alarm';
	e.preventDefault();
	jawnosClockNavClose();
	jawnosClockOpen(tab);
});

$(document).on('click', '.clock_tab', function () {
	jawnosClockTab($(this).attr('data-clock-tab'));
});

// ---------------------------------------------------------------- hydrating
// A window opened now, or restored from the taskbar, is filled here. The server
// draws the first pass; this makes the stopwatch and the world clock appear and
// keeps the live data fresh.
function jawnosClockFill() {
	jawnosClockApp().each(function () {
		var app = $(this);
		if (app.attr('data-clock-hydrated') == 'yes') { return; }
		app.attr('data-clock-hydrated', 'yes');
		var tab = app.attr('data-clock-tab') || 'alarm';
		// A window the manager built on its own (a reload, or a redraw after an
		// appointment) has no explicit choice, so it opens on the face last used.
		if (app.attr('data-clock-explicit') != 'yes') {
			tab = jawnosClockTabRemembered() || tab;
		}
		jawnosClockStopwatchLoad();
		jawnosClockWorldLoad();
		jawnosClockTab(tab);
		jawnosClockRefresh(true);
	});
}

function jawnosClockHydrateAll() {
	jawnosClockApp().each(function () {
		if ($(this).attr('data-clock-hydrated') != 'yes') { jawnosClockFill(); }
	});
}

$(document).ready(function () {
	setTimeout(jawnosClockHydrateAll, 0);
	if (window.MutationObserver && document.body) {
		jawnosClockObserver = new MutationObserver(function () {
			if (jawnosClockObserverTimer) { return; }
			jawnosClockObserverTimer = setTimeout(function () {
				jawnosClockObserverTimer = null;
				jawnosClockHydrateAll();
			}, 80);
		});
		jawnosClockObserver.observe(document.body, { childList: true, subtree: true });
	}
	jawnosClockPollTimer = setInterval(function () {
		if (document.hidden) { return; }
		// The state is fetched even with no Clock window open, so a phone sitting
		// on the manager (or another app) still learns an alarm is ringing and
		// draws the ring card.
		jawnosClockRefresh();
	}, 5000);
	jawnosClockTickTimer = setInterval(jawnosClockTick, 250);
});

// ------------------------------------------------------------------- state
function jawnosClockApplyState(state) {
	if (!state || typeof state != 'object') { return; }
	jawnosClockState = state;
	jawnosClockOffset = (parseFloat(state.now) || Date.now()) - Date.now();
	jawnosClockRenderAlarms(state);
	jawnosClockRenderTimers(state);
	jawnosClockRenderApps(state);
	jawnosClockSyncRinging(state);
}

function jawnosClockTargetsMe(alarm, state) {
	var machines = alarm.machines || [];
	if (!machines.length) { return true; }
	var me = (state && state.me) || '';
	return me ? $.inArray(me, machines) >= 0 : true;
}

// A ring card follows the server's ringing flag as well as the live push, so a
// window opened (or reloaded) while an alarm is still sounding shows the card
// again, and one dismissed on another screen closes here too.
function jawnosClockSyncRinging(state) {
	var ringing = $.grep(state.alarms || [], function (a) { return a.ringing && jawnosClockTargetsMe(a, state); });
	if (jawnosClockRingingCurrent) {
		var still = $.grep(ringing, function (a) { return a.uuid == jawnosClockRingingCurrent.uuid; });
		if (!still.length) { jawnosClockAlarmStop(); }
		return;
	}
	if (ringing.length && !jawnosClockRinging.length) {
		var a = ringing[0];
		jawnosClockShowRing({
			uuid: a.uuid, label: a.label, hour: a.hour, minute: a.minute,
			sound: a.sound, volume: a.volume, ramp: a.ramp, app: a.app,
			snooze: a.snooze
		});
	}
}

function jawnosClockRefresh(force) {
	var focused = document.activeElement && $(document.activeElement).closest('.clock_app').length;
	if (focused && !force) { return; }
	$.ajax({
		url: '/manager/clock/state',
		type: 'GET',
		dataType: 'json',
		success: function (state) { jawnosClockApplyState(state); }
	});
}

function jawnosClockPost(url, data, success, complete) {
	$.ajax({
		url: url,
		type: 'POST',
		data: data || {},
		dataType: 'json',
		success: function (state) {
			if (state && typeof state == 'object') {
				jawnosClockApplyState(state);
				if (state.ok === 0) { jawnosClockToast(jawnosClockError(state.error)); }
			}
			if (success) { success(state); }
		},
		complete: complete || function () {}
	});
}

function jawnosClockError(code) {
	if (code == 'full') { return jawnosT('This app holds ten; delete one first.'); }
	if (code == 'time') { return jawnosT('Give the timer a length.'); }
	return jawnosT('That could not be saved.');
}

function jawnosClockRenderApps(state) {
	if (!state.apps) { return; }
	jawnosClockApps = state.apps;
	if (jawnosClockAppTarget) { jawnosClockAppsFill(jawnosClockAppTarget); }
}

// The linked-appointment picker. A datalist cannot carry a picture, and the
// house's icons are half the recognition, so this is a small popup list with
// each app's own icon. One menu is shared by every picker in the window.
var jawnosClockApps = [];
var jawnosClockAppTarget = null;

function jawnosClockAppsMenu() {
	var menu = $('#clock_app_menu');
	if (!menu.length) {
		menu = $('<div id="clock_app_menu" role="listbox"></div>').appendTo(document.body);
	}
	return menu;
}

function jawnosClockAppsFill(input) {
	var menu = jawnosClockAppsMenu();
	var term = (input.val() || '').toLowerCase();
	var chosen = input.attr('data-app') || '';
	var html = '';
	var n = 0;
	$.each(jawnosClockApps, function (i, app) {
		var label = app.label || app.value || '';
		if (term && label.toLowerCase().indexOf(term) < 0 && (app.value || '').toLowerCase().indexOf(term) < 0) { return; }
		if (n >= 80) { return; }
		n++;
		html += '<button type="button" class="clock_app_choice' + (app.value == chosen ? ' selected' : '') + '" data-app="' + jawnosClockEsc(app.value) + '">';
		html += (app.icon || '') + '<span>' + jawnosClockEsc(label) + '</span></button>';
	});
	menu.html(html);
}

function jawnosClockAppsShow(input) {
	if (!input || !input.length) { return; }
	jawnosClockAppTarget = input;
	jawnosClockAppsFill(input);
	var menu = jawnosClockAppsMenu();
	menu.addClass('open');
	var r = input[0].getBoundingClientRect();
	var room = $(window).height() - r.bottom - 12;
	menu.css({
		left: Math.max(4, Math.round(r.left)) + 'px',
		top: Math.round(r.bottom + 2) + 'px',
		'min-width': Math.round(r.width) + 'px',
		'max-height': Math.max(120, Math.min(280, room)) + 'px'
	});
}

function jawnosClockAppsHide() {
	jawnosClockAppTarget = null;
	jawnosClockAppsMenu().removeClass('open');
}

$(document).on('focus click', '.clock_alarm_app, .clock_timer_app', function () {
	jawnosClockAppsShow($(this));
});

$(document).on('input', '.clock_alarm_app, .clock_timer_app', function () {
	$(this).attr('data-app', '');
	if (jawnosClockAppTarget && jawnosClockAppTarget[0] == this) { jawnosClockAppsShow($(this)); }
});

$(document).on('click', '.clock_app_toggle', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var input = $(this).siblings('input').first();
	input.trigger('focus');
	jawnosClockAppsShow(input);
});

$(document).on('mousedown', '.clock_app_choice, #clock_app_menu', function (e) {
	e.preventDefault();
});

$(document).on('click', '.clock_app_choice', function () {
	var input = jawnosClockAppTarget;
	if (!input) { return; }
	var app = $(this).attr('data-app') || '';
	var label = $(this).find('span').first().text();
	input.attr('data-app', app).val(app ? label : '');
	jawnosClockAppsHide();
	input.trigger('change');
});

$(document).on('mousedown', function (e) {
	if ($(e.target).closest('#clock_app_menu, .clock_app_picker').length) { return; }
	jawnosClockAppsHide();
});

$(document).on('keydown', '.clock_alarm_app, .clock_timer_app', function (e) {
	if (e.key == 'Escape') { jawnosClockAppsHide(); }
});

// ------------------------------------------------------------------ alarms
// One alarm is open at a time; the header is the strip a person scans - time,
// name and the machines that carry it - and the body is the editors.
var jawnosClockOpenAlarm = null;

function jawnosClockAlarmHeadDevicesHtml(alarm, state) {
	var machines = alarm.machines || [];
	var delivered = alarm.delivered || {};
	var html = '';
	$.each((state && state.machines) || [], function (i, m) {
		if ($.inArray(m.value, machines) < 0) { return; }
		var ack = delivered[m.value];
		var ack_time = (ack === undefined || ack === null) ? '' : jawnosClockDeliveredTime(ack);
		html += '<span class="clock_machine_pill' + (ack_time ? ' confirmed' : '') + '" data-machine="' + jawnosClockEsc(m.value) + '"';
		if (ack_time) { html += ' title="' + jawnosClockEsc(jawnosT('delivered') + ' ' + ack_time) + '"'; }
		html += '>' + jawnosClockEsc(m.label) + (ack_time ? ' ✓' : '') + '</span>';
	});
	return html;
}

function jawnosClockAlarmHeadDevicesRefresh(row) {
	var html = '';
	row.find('.clock_machine.on').each(function () {
		html += '<span class="clock_machine_pill" data-machine="' + jawnosClockEsc($(this).attr('data-machine')) + '">' + jawnosClockEsc($(this).text()) + '</span>';
	});
	row.find('.clock_alarm_head_devices').html(html);
}

function jawnosClockAlarmHtml(alarm, state) {
	var days = alarm.days || [];
	var has_days = days.length > 0;
	var enabled = alarm.enabled ? 1 : 0;
	var open = (jawnosClockOpenAlarm && jawnosClockOpenAlarm == alarm.uuid) ? ' open' : '';
	var letters = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
	var html = '';
	html += '<div class="clock_alarm' + (enabled ? '' : ' off') + open + '" data-uuid="' + jawnosClockEsc(alarm.uuid) + '" data-enabled="' + enabled + '">';
	html += '<div class="clock_alarm_head" role="button" tabindex="0" aria-expanded="' + (open ? 'true' : 'false') + '">';
	html += '<button type="button" class="clock_alarm_caret" tabindex="-1" aria-hidden="true"></button>';
	html += '<span class="clock_alarm_head_time">' + jawnosClockTime(alarm.hour, alarm.minute) + '</span>';
	html += '<span class="clock_alarm_head_label">' + jawnosClockEsc(alarm.label) + '</span>';
	html += '<span class="clock_alarm_head_devices">' + jawnosClockAlarmHeadDevicesHtml(alarm, state) + '</span>';
	html += '<label class="clock_switch" hint="' + jawnosClockEsc(jawnosT('alarm')) + '"><input type="checkbox" class="clock_alarm_enabled"' + (enabled ? ' checked' : '') + '></label>';
	html += '</div>';
	html += '<div class="clock_alarm_body">';
	html += '<div class="clock_alarm_line">';
	html += '<input type="text" inputmode="numeric" maxlength="5" autocomplete="off" pattern="[0-9:]*" placeholder="HH:MM" class="clock_alarm_time" value="' + jawnosClockTime(alarm.hour, alarm.minute) + '" aria-label="' + jawnosClockEsc(jawnosT('alarm')) + '">';
	html += '<input type="text" class="clock_alarm_label" value="' + jawnosClockEsc(alarm.label) + '" maxlength="20" aria-label="' + jawnosClockEsc(jawnosT('label')) + '">';
	html += '</div>';
	html += '<div class="clock_alarm_days" role="group" aria-label="' + jawnosClockEsc(jawnosT('days')) + '">';
	for (var d = 0; d < 7; d++) {
		var on = days.indexOf(d) >= 0;
		html += '<button type="button" class="clock_day' + (on ? ' on' : '') + '" data-day="' + d + '" aria-pressed="' + (on ? 'true' : 'false') + '">' + letters[d] + '</button>';
	}
	html += '<button type="button" class="clock_day clock_day_once' + (has_days ? '' : ' on') + '" data-once="yes" aria-pressed="' + (has_days ? 'false' : 'true') + '">' + jawnosClockEsc(jawnosT('once')) + '</button>';
	html += '</div>';
	html += '<div class="clock_alarm_when">';
	html += '<span class="clock_alarm_next" data-next="' + (alarm.next_at || 0) + '"></span>';
	html += '<button type="button" class="clock_alarm_skip" hint="' + jawnosClockEsc(jawnosT('skip_today')) + '">' + jawnosClockEsc(jawnosT('skip_today')) + '</button>';
	html += '<button type="button" class="clock_alarm_delete" hint="' + jawnosClockEsc(jawnosT('delete')) + '" aria-label="' + jawnosClockEsc(jawnosT('delete')) + '">✕</button>';
	html += '</div>';
	html += '<div class="clock_alarm_extra">';
	html += '<label class="clock_field"><span>' + jawnosClockEsc(jawnosT('link_appointment')) + '</span><div class="clock_app_picker"><input type="text" class="clock_alarm_app" autocomplete="off" data-app="' + jawnosClockEsc(alarm.app || '') + '" value="' + jawnosClockEsc((alarm.app || '').replace(/_/g, ' ')) + '" placeholder="' + jawnosClockEsc(jawnosT('no_appointment')) + '"><button type="button" class="clock_app_toggle" tabindex="-1" aria-label="' + jawnosClockEsc(jawnosT('link_appointment')) + '">▾</button></div></label>';
	var machines = alarm.machines || [];
	html += '<label class="clock_field clock_alarm_machines"><span>' + jawnosClockEsc(jawnosT('shared_with')) + '</span><div class="clock_machine_list" role="group" aria-label="' + jawnosClockEsc(jawnosT('shared_with')) + '">';
	$.each((state && state.machines) || [], function (i, m) {
		var on = $.inArray(m.value, machines) >= 0;
		html += '<button type="button" class="clock_machine' + (on ? ' on' : '') + '" data-machine="' + jawnosClockEsc(m.value) + '" aria-pressed="' + (on ? 'true' : 'false') + '">' + jawnosClockEsc(m.label) + '</button>';
	});
	html += '</div></label>';
	html += '<label class="clock_field"><span>' + jawnosClockEsc(jawnosT('sound')) + '</span><div class="clock_sound_row"><select class="clock_alarm_sound">';
	$.each((state && state.alarm_sounds) || (state && state.sounds) || [], function (i, s) {
		var value = (typeof s == 'string') ? ('notifications/' + s) : (s.value || '');
		var label = (typeof s == 'string') ? s.replace(/\.mp3$/, '') : (s.label || value);
		if (typeof s == 'string') { label = label.charAt(0).toUpperCase() + label.slice(1); }
		html += '<option value="' + jawnosClockEsc(value) + '"' + (alarm.sound == value ? ' selected' : '') + '>' + jawnosClockEsc(label) + '</option>';
	});
	html += '</select><button type="button" class="clock_alarm_preview" hint="' + jawnosClockEsc(jawnosT('preview')) + '">' + jawnosClockEsc(jawnosT('preview')) + '</button></div></label>';
	html += '<label class="clock_field"><span>' + jawnosClockEsc(jawnosT('volume')) + ' · ' + (alarm.volume || 70) + '%</span><input type="range" min="5" max="100" step="5" class="clock_alarm_volume" inputmode="none" data-soft_keyboard="off" aria-label="' + jawnosClockEsc(jawnosT('volume')) + '" value="' + (alarm.volume || 70) + '"></label>';
	html += '<label class="clock_field"><span>' + jawnosClockEsc(jawnosT('ramp')) + ' · ' + (alarm.ramp || 0) + 's</span><input type="number" inputmode="numeric" min="0" max="600" step="5" class="clock_alarm_ramp" value="' + (alarm.ramp || 0) + '"></label>';
	html += '<label class="clock_field"><span>' + jawnosClockEsc(jawnosT('snooze_length')) + '</span><input type="number" inputmode="numeric" min="1" max="60" step="1" class="clock_alarm_snooze" value="' + jawnosClockSnoozeValue(alarm.snooze) + '" aria-label="' + jawnosClockEsc(jawnosT('snooze')) + '"></label>';
	html += '</div></div></div>';
	return html;
}

function jawnosClockRenderAlarms(state) {
	var app = jawnosClockApp().first();
	if (!app.length) { return; }
	var focused = document.activeElement && $(document.activeElement).closest('.clock_app .clock_alarm').length
		&& /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
	if (focused) { return; }
	var list = app.find('.clock_alarm_list');
	var alarms = state.alarms || [];
	var html = '';
	$.each(alarms, function (i, alarm) { html += jawnosClockAlarmHtml(alarm, state); });
	if (!alarms.length) {
		html = '<div class="clock_empty">' + jawnosClockEsc(jawnosT('No alarms yet - add one and it will be waiting for you here.')) + '</div>';
	}
	list.html(html);
	app.find('.clock_count').first().text(alarms.length + '/' + (state.max || 10));
	var add = app.find('.clock_add_alarm');
	add.prop('disabled', alarms.length >= (state.max || 10));
}

function jawnosClockAlarmData(row) {
	var uuid = row.attr('data-uuid');
	var time = jawnosClockParseTime(row.find('.clock_alarm_time').val());
	var days = [];
	row.find('.clock_day[data-day].on').each(function () { days.push($(this).attr('data-day')); });
	var machines = [];
	row.find('.clock_machine.on').each(function () { machines.push($(this).attr('data-machine')); });
	var app_input = row.find('.clock_alarm_app');
	return {
		action: 'save',
		uuid: uuid,
		hour: time[0],
		minute: time[1],
		label: row.find('.clock_alarm_label').val() || '',
		days: days.join(','),
		app: app_input.attr('data-app') || app_input.val() || '',
		sound: row.find('.clock_alarm_sound').val() || 'notifications/ring.mp3',
		volume: parseInt(row.find('.clock_alarm_volume').val() || 70, 10),
		ramp: parseInt(row.find('.clock_alarm_ramp').val() || 0, 10),
		snooze: jawnosClockSnoozeValue(row.find('.clock_alarm_snooze').val()),
		enabled: row.find('.clock_alarm_enabled').is(':checked') ? 1 : 0,
		machines: machines.join(',')
	};
}

function jawnosClockSaveAlarm(row, delay) {
	var uuid = row.attr('data-uuid');
	if (!uuid) { return; }
	if (jawnosClockSaveTimers[uuid]) { clearTimeout(jawnosClockSaveTimers[uuid]); }
	jawnosClockSaveTimers[uuid] = setTimeout(function () {
		delete jawnosClockSaveTimers[uuid];
		jawnosClockPost('/manager/clock/alarm', jawnosClockAlarmData(row), function () {
			jawnosClockRefresh(true);
		});
	}, delay || 0);
}

$(document).on('change', '.clock_alarm_time, .clock_alarm_label, .clock_alarm_app, .clock_alarm_sound, .clock_alarm_enabled', function () {
	var row = $(this).closest('.clock_alarm');
	if ($(this).hasClass('clock_alarm_time')) {
		var time = jawnosClockParseTime($(this).val());
		$(this).val(jawnosClockTime(time[0], time[1]));
		row.find('.clock_alarm_head_time').text(jawnosClockTime(time[0], time[1]));
	}
	row.toggleClass('off', !row.find('.clock_alarm_enabled').is(':checked'));
	jawnosClockSaveAlarm(row);
});

$(document).on('input', '.clock_alarm_volume', function () {
	var row = $(this).closest('.clock_alarm');
	row.find('.clock_alarm_volume').closest('.clock_field').find('span').first().text(jawnosT('volume') + ' · ' + $(this).val() + '%');
	jawnosClockSaveAlarm(row, 450);
});

$(document).on('input change', '.clock_alarm_ramp', function () {
	var row = $(this).closest('.clock_alarm');
	row.find('.clock_alarm_ramp').closest('.clock_field').find('span').first().text(jawnosT('ramp') + ' · ' + $(this).val() + 's');
	jawnosClockSaveAlarm(row, 450);
});

$(document).on('input', '.clock_alarm_snooze', function () {
	jawnosClockSaveAlarm($(this).closest('.clock_alarm'), 450);
});

$(document).on('change', '.clock_alarm_snooze', function () {
	var minutes = jawnosClockSnoozeValue($(this).val());
	$(this).val(minutes);
	jawnosClockSaveAlarm($(this).closest('.clock_alarm'), 450);
});

$(document).on('click', '.clock_machine', function () {
	var row = $(this).closest('.clock_alarm');
	$(this).toggleClass('on');
	$(this).attr('aria-pressed', $(this).hasClass('on') ? 'true' : 'false');
	// At least one machine carries an alarm; the first chip is "Me".
	if (!row.find('.clock_machine.on').length) {
		row.find('.clock_machine').first().addClass('on').attr('aria-pressed', 'true');
	}
	jawnosClockAlarmHeadDevicesRefresh(row);
	jawnosClockSaveAlarm(row);
});

// Audition a ringtone through the operating system. One plays at a time; the
// second press on the same button stops it.
$(document).on('click', '.clock_alarm_preview', function () {
	var button = $(this);
	var row = button.closest('.clock_alarm');
	if (button.attr('data-playing') == 'yes') {
		button.attr('data-playing', 'no');
		$.ajax({ url: '/manager/clock/preview', type: 'POST', data: { action: 'stop' }, dataType: 'json' });
		return;
	}
	button.attr('data-playing', 'yes');
	setTimeout(function () { button.attr('data-playing', 'no'); }, 10500);
	$.ajax({
		url: '/manager/clock/preview',
		type: 'POST',
		dataType: 'json',
		data: {
			sound: row.find('.clock_alarm_sound').val() || 'notifications/ring.mp3',
			volume: parseInt(row.find('.clock_alarm_volume').val() || 70, 10)
		},
		complete: function () {}
	});
});

$(document).on('click', '.clock_alarm_head', function (e) {
	if ($(e.target).closest('.clock_switch').length) { return; }
	jawnosClockAlarmToggle($(this).closest('.clock_alarm'));
});

$(document).on('keydown', '.clock_alarm_head', function (e) {
	if (e.key != 'Enter' && e.key != ' ') { return; }
	if ($(e.target).closest('.clock_switch').length) { return; }
	e.preventDefault();
	jawnosClockAlarmToggle($(this).closest('.clock_alarm'));
});

$(document).on('click', '.clock_alarm_caret', function (e) {
	e.stopPropagation();
	jawnosClockAlarmToggle($(this).closest('.clock_alarm'));
});

function jawnosClockAlarmToggle(row) {
	var open = row.hasClass('open');
	$('.clock_app .clock_alarm.open').not(row).removeClass('open').children('.clock_alarm_head').attr('aria-expanded', 'false');
	row.toggleClass('open', !open);
	row.children('.clock_alarm_head').attr('aria-expanded', open ? 'false' : 'true');
	jawnosClockOpenAlarm = open ? null : row.attr('data-uuid');
}

// The header is a summary of fields in the body; keep it in step while typing.
$(document).on('input', '.clock_alarm_label', function () {
	$(this).closest('.clock_alarm').find('.clock_alarm_head_label').text($(this).val());
});

$(document).on('change', '.clock_alarm_time', function () {
	$(this).closest('.clock_alarm').find('.clock_alarm_head_time').text($(this).val() || '');
});

$(document).on('click', '.clock_alarm_skip', function (e) {
	e.stopPropagation();
	var row = $(this).closest('.clock_alarm');
	jawnosClockPost('/manager/clock/alarm', { action: 'skip', uuid: row.attr('data-uuid') }, function (state) {
		if (state && state.ok !== 0) { jawnosClockToast(jawnosT('skipped_today')); }
		jawnosClockRefresh(true);
	});
});

$(document).on('click', '.clock_day', function () {
	var row = $(this).closest('.clock_alarm');
	if ($(this).attr('data-once') == 'yes') {
		row.find('.clock_day[data-day]').removeClass('on').attr('aria-pressed', 'false');
		$(this).addClass('on').attr('aria-pressed', 'true');
	}
	else {
		$(this).toggleClass('on');
		$(this).attr('aria-pressed', $(this).hasClass('on') ? 'true' : 'false');
		row.find('.clock_day_once').toggleClass('on', row.find('.clock_day[data-day].on').length == 0);
	}
	jawnosClockSaveAlarm(row);
});

$(document).on('click', '.clock_add_alarm', function () {
	jawnosClockPost('/manager/clock/alarm', { action: 'add' }, function () { jawnosClockRefresh(true); });
});

// delete is a two-press X: the first press arms it for two seconds
$(document).on('click', '.clock_alarm_delete', function () {
	var button = $(this);
	if (button.attr('armed') == 'yes') {
		var row = button.closest('.clock_alarm');
		jawnosClockPost('/manager/clock/alarm', { action: 'delete', uuid: row.attr('data-uuid') }, function () {
			jawnosClockRefresh(true);
		});
		return;
	}
	button.attr('armed', 'yes').css('color', '#c94f4f');
	setTimeout(function () { button.attr('armed', 'no').css('color', ''); }, 2000);
});

// ------------------------------------------------------------------ timers
function jawnosClockFormatSeconds(seconds) {
	seconds = Math.max(0, Math.floor(parseInt(seconds, 10) || 0));
	var h = Math.floor(seconds / 3600);
	var m = Math.floor((seconds % 3600) / 60);
	var s = seconds % 60;
	return h > 0 ? jawnosClockPad(h) + ':' + jawnosClockPad(m) + ':' + jawnosClockPad(s) : jawnosClockPad(m) + ':' + jawnosClockPad(s);
}

function jawnosClockTimerHtml(timer) {
	var state = timer.state || 'running';
	var remaining = state == 'running' ? Math.max(0, Math.floor((timer.ends_at - jawnosClockNow()) / 1000)) : 0;
	var html = '';
	html += '<div class="clock_timer state_' + jawnosClockEsc(state) + '" data-uuid="' + jawnosClockEsc(timer.uuid) + '" data-state="' + jawnosClockEsc(state) + '" data-ends="' + (timer.ends_at || 0) + '">';
	html += '<div class="clock_timer_top"><span class="clock_timer_countdown">' + jawnosClockFormatSeconds(remaining) + '</span>';
	html += '<span class="clock_timer_label_text">' + jawnosClockEsc(timer.label);
	if (timer.app) { html += '<span class="clock_timer_app_text">' + jawnosClockEsc(jawnosT('link_appointment')) + ': ' + jawnosClockEsc(timer.app.replace(/_/g, ' ')) + '</span>'; }
	html += '</span>';
	if (state == 'running') {
		html += '<button type="button" class="clock_timer_action clock_timer_stop" hint="' + jawnosClockEsc(jawnosT('stop')) + '">' + jawnosClockEsc(jawnosT('stop')) + '</button>';
	}
	else {
		html += '<div class="clock_timer_buttons">';
		html += '<button type="button" class="clock_timer_action clock_timer_restore" hint="' + jawnosClockEsc(jawnosT('restore')) + '">' + jawnosClockEsc(jawnosT('restore')) + '</button>';
		html += '<button type="button" class="clock_timer_action clock_timer_remove" hint="' + jawnosClockEsc(jawnosT('delete')) + '">' + jawnosClockEsc(jawnosT('delete')) + '</button>';
		html += '</div>';
	}
	html += '</div>';
	if (state != 'running') {
		html += '<div class="clock_timer_app_text">' + jawnosClockEsc(state == 'done' ? jawnosT('done') : jawnosT('cancelled')) + '</div>';
	}
	html += '</div>';
	return html;
}

function jawnosClockRenderTimers(state) {
	var app = jawnosClockApp().first();
	if (!app.length) { return; }
	var focused = document.activeElement && $(document.activeElement).closest('.clock_app .clock_timer_new').length;
	if (focused) { return; }
	var timers = state.timers || [];
	var html = '';
	$.each(timers, function (i, timer) { html += jawnosClockTimerHtml(timer); });
	if (!timers.length) {
		html = '<div class="clock_empty">' + jawnosClockEsc(jawnosT('No timers yet - add one above, or press a preset.')) + '</div>';
	}
	app.find('.clock_timer_list').html(html);
	var running = 0;
	$.each(timers, function (i, timer) { if ((timer.state || '') == 'running') { running++; } });
	app.find('.clock_panel[data-clock-panel=timer] .clock_count').text(running + '/' + (state.max || 10));
	app.find('.clock_add_timer').prop('disabled', running >= (state.max || 10));
}

$(document).on('click', '.clock_preset', function () {
	var seconds = parseInt($(this).attr('data-preset'), 10) || 0;
	var panel = $(this).closest('.clock_panel');
	panel.find('.clock_timer_hours').val(Math.floor(seconds / 3600));
	panel.find('.clock_timer_minutes').val(Math.floor((seconds % 3600) / 60));
	panel.find('.clock_timer_seconds').val(seconds % 60);
});

$(document).on('click', '.clock_add_timer', function () {
	var panel = $(this).closest('.clock_panel');
	var hours = parseInt(panel.find('.clock_timer_hours').val() || 0, 10) || 0;
	var minutes = parseInt(panel.find('.clock_timer_minutes').val() || 0, 10) || 0;
	var seconds = parseInt(panel.find('.clock_timer_seconds').val() || 0, 10) || 0;
	if ((hours * 3600) + (minutes * 60) + seconds < 1) {
		jawnosClockToast(jawnosClockError('time'));
		return;
	}
	var label = panel.find('.clock_timer_label').val() || '';
	var app_input = panel.find('.clock_timer_app');
	var app = app_input.attr('data-app') || app_input.val() || '';
	jawnosClockPost('/manager/clock/timer', {
		action: 'start', hours: hours, minutes: minutes, seconds: seconds, label: label, app: app
	}, function (state) {
		if (state && state.ok !== 0) {
			panel.find('.clock_timer_hours, .clock_timer_minutes, .clock_timer_seconds, .clock_timer_label, .clock_timer_app').val('');
			panel.find('.clock_timer_app').attr('data-app', '');
			jawnosClockRefresh(true);
		}
	});
});

$(document).on('click', '.clock_timer_restore', function () {
	var row = $(this).closest('.clock_timer');
	jawnosClockPost('/manager/clock/timer', { action: 'restore', uuid: row.attr('data-uuid') }, function () {
		jawnosClockRefresh(true);
	});
});

$(document).on('click', '.clock_timer_stop', function () {
	var row = $(this).closest('.clock_timer');
	jawnosClockPost('/manager/clock/timer', { action: 'stop', uuid: row.attr('data-uuid') }, function () {
		jawnosClockRefresh(true);
	});
});

$(document).on('click', '.clock_timer_remove', function () {
	var row = $(this).closest('.clock_timer');
	jawnosClockPost('/manager/clock/timer', { action: 'delete', uuid: row.attr('data-uuid') }, function () {
		jawnosClockRefresh(true);
	});
});

$(document).on('click', '.clock_clear_finished', function () {
	jawnosClockPost('/manager/clock/timer', { action: 'clear_finished' }, function () {
		jawnosClockRefresh(true);
	});
});

// ----------------------------------------------------------------- the tick
// The next run's countdown, written into every alarm header.
function jawnosClockCountdown(ms) {
	var s = Math.max(0, Math.round(ms / 1000));
	var d = Math.floor(s / 86400); s -= d * 86400;
	var h = Math.floor(s / 3600); s -= h * 3600;
	var m = Math.floor(s / 60); s -= m * 60;
	if (d > 0) { return d + 'd ' + h + 'h'; }
	if (h > 0) { return h + 'h ' + m + 'm'; }
	if (m > 0) { return m + 'm ' + s + 's'; }
	return s + 's';
}

function jawnosClockNextText(next) {
	if (!next) { return ''; }
	var when = new Date(next);
	var day = '', time = '';
	try { day = when.toLocaleDateString(undefined, { weekday: 'short' }); } catch (e) { day = ''; }
	try { time = when.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' }); } catch (e) { time = jawnosClockTime(when.getHours(), when.getMinutes()); }
	return jawnosT('next') + ' ' + (day ? day + ' ' : '') + time + ' · ' + jawnosClockCountdown(next - jawnosClockNow());
}

function jawnosClockNextRefresh() {
	$('.clock_app .clock_alarm_next').each(function () {
		var next = parseInt($(this).attr('data-next'), 10) || 0;
		if (!next) { $(this).text(''); return; }
		$(this).text(jawnosClockNextText(next));
	});
}

function jawnosClockTick() {
	var app = jawnosClockApp().first();
	if (!app.length) { return; }
	jawnosClockNextRefresh();
	if (document.activeElement && $(document.activeElement).closest('.clock_app').length) {
		// still animate a running stopwatch while its own controls are in use
		if (jawnosClockActiveTab() == 'stopwatch') { jawnosClockRenderStopwatch(); }
		return;
	}
	app.find('.clock_timer[data-state=running]').each(function () {
		var row = $(this);
		var ends = parseFloat(row.attr('data-ends')) || 0;
		var remaining = Math.max(0, Math.floor((ends - jawnosClockNow()) / 1000));
		row.find('.clock_timer_countdown').text(jawnosClockFormatSeconds(remaining));
	});
	if (jawnosClockActiveTab() == 'stopwatch') { jawnosClockRenderStopwatch(); }
	if (jawnosClockActiveTab() == 'world') { jawnosClockRenderWorld(); }
}

// ---------------------------------------------------------------- stopwatch
function jawnosClockStopwatchLoad() {
	if (jawnosClockStopwatch) { return; }
	var saved = null;
	try { saved = JSON.parse(localStorage.getItem('jawnos_clock_stopwatch') || 'null'); } catch (e) { saved = null; }
	if (!saved || typeof saved != 'object') {
		saved = { running: false, started: 0, elapsed: 0, laps: [], last_lap: 0 };
	}
	jawnosClockStopwatch = saved;
}

function jawnosClockStopwatchSave() {
	try { localStorage.setItem('jawnos_clock_stopwatch', JSON.stringify(jawnosClockStopwatch)); } catch (e) {}
}

function jawnosClockStopwatchElapsed() {
	jawnosClockStopwatchLoad();
	var sw = jawnosClockStopwatch;
	return (parseFloat(sw.elapsed) || 0) + (sw.running ? (Date.now() - (parseFloat(sw.started) || Date.now())) : 0);
}

function jawnosClockStopwatchText(ms) {
	ms = Math.max(0, ms);
	var total = Math.floor(ms / 1000);
	var h = Math.floor(total / 3600);
	var m = Math.floor((total % 3600) / 60);
	var s = total % 60;
	var cs = Math.floor((ms % 1000) / 10);
	return jawnosClockPad(h) + ':' + jawnosClockPad(m) + ':' + jawnosClockPad(s) + '.' + jawnosClockPad(cs);
}

function jawnosClockRenderStopwatch() {
	jawnosClockLoadDefaults();
	var sw = jawnosClockStopwatch;
	var app = jawnosClockApp().first();
	if (!app.length) { return; }
	app.find('.clock_sw_display').text(jawnosClockStopwatchText(jawnosClockStopwatchElapsed()));
	app.find('.clock_sw_start').text(sw.running ? jawnosT('stop') : jawnosT('start'));
	app.find('.clock_sw_lap').prop('disabled', !sw.running);
	var html = '';
	$.each(sw.laps || [], function (i, lap) {
		html += '<div class="clock_sw_lap_row"><span>' + jawnosClockEsc(jawnosT('lap') + ' ' + lap.n) + '</span><span>' + jawnosClockStopwatchText(lap.split) + '</span></div>';
	});
	app.find('.clock_sw_laps').html(html);
}

function jawnosClockLoadDefaults() {
	jawnosClockStopwatchLoad();
	jawnosClockWorldLoad();
}

$(document).on('click', '.clock_sw_start', function () {
	jawnosClockStopwatchLoad();
	var sw = jawnosClockStopwatch;
	if (sw.running) {
		sw.elapsed = jawnosClockStopwatchElapsed();
		sw.running = false;
		sw.started = 0;
	}
	else {
		sw.started = Date.now();
		sw.running = true;
	}
	jawnosClockStopwatchSave();
	jawnosClockRenderStopwatch();
});

$(document).on('click', '.clock_sw_lap', function () {
	jawnosClockStopwatchLoad();
	var sw = jawnosClockStopwatch;
	if (!sw.running) { return; }
	var total = jawnosClockStopwatchElapsed();
	var split = total - (parseFloat(sw.last_lap) || 0);
	sw.last_lap = total;
	sw.laps = sw.laps || [];
	sw.laps.unshift({ n: sw.laps.length + 1, total: total, split: split });
	if (sw.laps.length > 100) { sw.laps.length = 100; }
	jawnosClockStopwatchSave();
	jawnosClockRenderStopwatch();
});

$(document).on('click', '.clock_sw_reset', function () {
	jawnosClockStopwatch = { running: false, started: 0, elapsed: 0, laps: [], last_lap: 0 };
	jawnosClockStopwatchSave();
	jawnosClockRenderStopwatch();
});

// --------------------------------------------------------------- world clock
function jawnosClockDefaultWorld() {
	return [
		{ zone: 'America/New_York', name: 'New York' },
		{ zone: 'Europe/London', name: 'London' },
		{ zone: 'Asia/Tokyo', name: 'Tokyo' }
	];
}

function jawnosClockWorldLoad() {
	if (jawnosClockWorld) { return; }
	var saved = null;
	try { saved = JSON.parse(localStorage.getItem('jawnos_clock_world') || 'null'); } catch (e) { saved = null; }
	if (!saved || !saved.length) { saved = jawnosClockDefaultWorld(); }
	jawnosClockWorld = saved;
	jawnosClockWorldZonesFill();
}

function jawnosClockWorldSave() {
	try { localStorage.setItem('jawnos_clock_world', JSON.stringify(jawnosClockWorld)); } catch (e) {}
}

function jawnosClockWorldZonesFill() {
	var datalist = $('#clock_zones');
	if (!datalist.length || datalist.attr('filled') == 'yes') { return; }
	var zones = [];
	try {
		if (Intl && Intl.supportedValuesOf) { zones = Intl.supportedValuesOf('timeZone'); }
	} catch (e) { zones = []; }
	if (!zones.length) {
		zones = ['America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
			'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Europe/Madrid', 'Europe/Rome',
			'Asia/Tokyo', 'Asia/Shanghai', 'Asia/Kolkata', 'Asia/Dubai', 'Australia/Sydney',
			'Pacific/Auckland', 'Africa/Cairo', 'Africa/Johannesburg', 'America/Sao_Paulo'];
	}
	var html = '';
	$.each(zones, function (i, zone) { html += '<option value="' + jawnosClockEsc(zone) + '"></option>'; });
	datalist.html(html).attr('filled', 'yes');
}

function jawnosClockZoneName(zone) {
	var parts = String(zone || '').split('/');
	var name = parts[parts.length - 1] || zone;
	return name.replace(/_/g, ' ');
}

function jawnosClockZoneParts(zone, date) {
	var opts = { timeZone: zone, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', weekday: 'short' };
	var parts = {};
	try {
		new Intl.DateTimeFormat('en-US', opts).formatToParts(date).forEach(function (p) { parts[p.type] = p.value; });
	} catch (e) { return null; }
	if (parts.hour == '24') { parts.hour = '00'; }
	return parts;
}

function jawnosClockZoneClock(zone, date) {
	var parts = jawnosClockZoneParts(zone, date);
	if (!parts) { return { time: '--:--', day: '', offset: 0 }; }
	var hours = parseInt(parts.hour, 10);
	var time;
	if (typeof jawnos_clock_format != 'undefined' && jawnos_clock_format == '12') {
		var meridiem = hours < 12 ? 'am' : 'pm';
		var face = hours % 12;
		if (face == 0) { face = 12; }
		time = face + ':' + parts.minute + ':' + parts.second + meridiem;
	}
	else {
		time = jawnosClockPad(hours) + ':' + parts.minute + ':' + parts.second;
	}
	return { time: time, day: parts.weekday + ' ' + parts.month + '/' + parts.day, offset: 0 };
}

function jawnosClockLocalDateKey(date) {
	return date.getFullYear() + '-' + (date.getMonth() + 1) + '-' + date.getDate();
}

function jawnosClockZoneDateKey(zone, date) {
	var parts = jawnosClockZoneParts(zone, date);
	if (!parts) { return ''; }
	return parts.year + '-' + parts.month + '-' + parts.day;
}

function jawnosClockRenderWorld() {
	jawnosClockWorldLoad();
	var app = jawnosClockApp().first();
	if (!app.length) { return; }
	jawnosClockWorldZonesFill();
	var now = new Date();
	var local_key = jawnosClockLocalDateKey(now);
	var local = jawnosClockZoneClock(Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC', now);
	var html = '';
	html += '<div class="clock_world_row" data-zone="__local__">';
	html += '<div class="clock_world_name">' + jawnosClockEsc(jawnosT('local')) + '<small>' + jawnosClockEsc(Intl.DateTimeFormat().resolvedOptions().timeZone || '') + '</small></div>';
	html += '<div class="clock_world_time">' + jawnosClockEsc(local.time) + '</div>';
	html += '<div class="clock_world_day">' + jawnosClockEsc(local.day) + '</div>';
	html += '</div>';
	$.each(jawnosClockWorld, function (i, entry) {
		var clock = jawnosClockZoneClock(entry.zone, now);
		var key = jawnosClockZoneDateKey(entry.zone, now);
		var day_note = '';
		if (key && key != local_key) {
			day_note = key > local_key ? '+1' : '-1';
		}
		html += '<div class="clock_world_row" data-zone="' + jawnosClockEsc(entry.zone) + '">';
		html += '<div class="clock_world_name">' + jawnosClockEsc(entry.name || jawnosClockZoneName(entry.zone)) + '<small>' + jawnosClockEsc(entry.zone) + '</small></div>';
		html += '<div class="clock_world_time">' + jawnosClockEsc(clock.time) + '</div>';
		html += '<div class="clock_world_day">' + jawnosClockEsc(clock.day) + (day_note ? '<br>' + day_note : '') + '</div>';
		html += '<button type="button" class="clock_world_delete" aria-label="' + jawnosClockEsc(jawnosT('delete')) + '" hint="' + jawnosClockEsc(jawnosT('delete')) + '">✕</button>';
		html += '</div>';
	});
	app.find('.clock_world_list').html(html);
}

$(document).on('click', '.clock_world_add_button', function () {
	var panel = $(this).closest('.clock_world');
	var input = panel.find('.clock_world_zone');
	var value = (input.val() || '').replace(/^\s+|\s+$/g, '');
	if (!value) { return; }
	var zone = value;
	try { new Intl.DateTimeFormat('en-US', { timeZone: zone }); }
	catch (e) {
		// allow a city name: find the first zone whose last segment matches
		var match = null;
		try {
			var zones = Intl.supportedValuesOf ? Intl.supportedValuesOf('timeZone') : [];
			$.each(zones, function (i, z) {
				if (match) { return false; }
				if (jawnosClockZoneName(z).toLowerCase() == value.toLowerCase()) { match = z; }
			});
		} catch (e2) {}
		if (!match) { jawnosClockToast(jawnosT('That is not a time zone.')); return; }
		zone = match;
	}
	jawnosClockWorldLoad();
	jawnosClockWorld.push({ zone: zone, name: jawnosClockZoneName(zone) });
	jawnosClockWorldSave();
	input.val('');
	jawnosClockRenderWorld();
});

$(document).on('click', '.clock_world_delete', function () {
	var zone = $(this).closest('.clock_world_row').attr('data-zone');
	jawnosClockWorldLoad();
	jawnosClockWorld = $.grep(jawnosClockWorld, function (entry) { return entry.zone != zone; });
	jawnosClockWorldSave();
	jawnosClockRenderWorld();
});

// ------------------------------------------------------------- alarm ring
function jawnosClockRingClaim(uuid) {
	try {
		var key = 'jawnos_clock_ring_' + uuid;
		var last = parseFloat(localStorage.getItem(key) || '0');
		var now = Date.now();
		if (last && now - last < 15000) { return false; }
		localStorage.setItem(key, String(now));
		return true;
	} catch (e) { return true; }
}

function jawnosClockRingCard() {
	var card = $('#clock_ring_overlay');
	if (card.length) { return card; }
	card = $('<div id="clock_ring_overlay" class="clock_ring_overlay" style="display:none;">'
		+ '<div class="clock_ring_card">'
		+ '<div class="clock_ring_title">' + jawnosClockEsc(jawnosT('alarm_ringing')) + '</div>'
		+ '<div class="clock_ring_label"></div>'
		+ '<div class="clock_ring_time"></div>'
		+ '<div class="clock_ring_buttons">'
		+ '<button type="button" class="clock_ring_snooze" title="' + jawnosClockEsc(jawnosClockSnoozeText(5)) + '">' + jawnosClockEsc(jawnosClockSnoozeText(5)) + '</button>'
		+ '<button type="button" class="clock_ring_dismiss">' + jawnosClockEsc(jawnosT('dismiss')) + '</button>'
		+ '</div>'
		+ '</div></div>');
	$('body').append(card);
	return card;
}

function jawnosClockShowRing(payload) {
	jawnosClockRingingCurrent = payload;
	var card = jawnosClockRingCard();
	card.find('.clock_ring_label').text(payload.label || jawnosT('alarm'));
	card.find('.clock_ring_time').text(jawnosClockTime(payload.hour, payload.minute) + (payload.app ? ' · ' + String(payload.app).replace(/_/g, ' ') : ''));
	card.find('.clock_ring_snooze').text(jawnosClockSnoozeText(payload.snooze)).attr('title', jawnosClockSnoozeText(payload.snooze));
	card.show();
	$('.clock_alarm[data-uuid="' + payload.uuid + '"]').addClass('ringing');
	// The sound is the server's: it plays through the operating system and
	// repeats there until Dismiss or Snooze clears the alarm.
	jawnosClockShowTitle(jawnosT('alarm_ringing') + ': ' + (payload.label || ''));
	setTimeout(function () { jawnosClockRefresh(true); }, 1200);
}

function jawnosClockAlarmRing(payload) {
	if (!payload || !payload.uuid) { return; }
	if (!jawnosClockRingClaim(payload.uuid)) { return; }
	var found = $.grep(jawnosClockRinging, function (a) { return a.uuid == payload.uuid; });
	if (found.length) { return; }
	jawnosClockRinging.push(payload);
	if (!jawnosClockRingingCurrent) { jawnosClockShowRing(jawnosClockRinging.shift()); }
}

function jawnosClockAlarmStop() {
	jawnosClockRingingCurrent = null;
	$('#clock_ring_overlay').hide();
	$('.clock_alarm.ringing').removeClass('ringing');
	jawnosClockShowTitle('');
	if (jawnosClockRinging.length) { jawnosClockShowRing(jawnosClockRinging.shift()); }
}

$(document).on('click', '.clock_ring_dismiss', function () {
	if (!jawnosClockRingingCurrent) { return; }
	var payload = jawnosClockRingingCurrent;
	jawnosClockPost('/manager/clock/alarm', { action: 'dismiss', uuid: payload.uuid }, function () {
		jawnosClockAlarmStop();
	});
	jawnosClockAlarmStop();
});

$(document).on('click', '.clock_ring_snooze', function () {
	if (!jawnosClockRingingCurrent) { return; }
	var payload = jawnosClockRingingCurrent;
	jawnosClockPost('/manager/clock/alarm', { action: 'snooze', uuid: payload.uuid, minutes: jawnosClockSnoozeValue(payload.snooze) }, function () {
		jawnosClockAlarmStop();
	});
	jawnosClockAlarmStop();
});

function jawnosClockTimerDone(payload) {
	if (!payload) { return; }
	jawnosClockToastEnsure();
	var toast = $('#clock_toast');
	toast.find('.clock_toast_text').text(jawnosT('timer_finished') + ': ' + (payload.label || ''));
	toast.stop(true, true).fadeIn(120);
	clearTimeout(toast.data('hide'));
	toast.data('hide', setTimeout(function () { toast.fadeOut(200); }, 12000));
	// The chime is the server's notification, played through the operating
	// system; the browser only shows the finished notice.
	jawnosClockShowTitle(jawnosT('timer_finished'));
	jawnosClockRefresh(true);
}

function jawnosClockToastEnsure() {
	var toast = $('#clock_toast');
	if (!toast.length) {
		toast = $('<div id="clock_toast" class="clock_toast" style="display:none;"><span class="clock_toast_text"></span><button type="button" class="clock_toast_close" aria-label="' + jawnosClockEsc(jawnosT('dismiss')) + '">✕</button></div>');
		$('body').append(toast);
	}
	return toast;
}

$(document).on('click', '.clock_toast_close', function () {
	$(this).closest('#clock_toast').fadeOut(150);
	jawnosClockShowTitle('');
});

function jawnosClockToast(text) {
	if (!text) { return; }
	var toast = jawnosClockToastEnsure();
	toast.find('.clock_toast_text').text(text);
	toast.stop(true, true).fadeIn(120);
	clearTimeout(toast.data('hide'));
	toast.data('hide', setTimeout(function () { toast.fadeOut(200); }, 6000));
}

var jawnosClockBaseTitle = null;
function jawnosClockShowTitle(text) {
	try {
		if (jawnosClockBaseTitle === null) { jawnosClockBaseTitle = document.title; }
		document.title = text ? text + ' - JawnOS' : jawnosClockBaseTitle;
	} catch (e) {}
}

// ------------------------------------------------------------- taskbar menu
function jawnosClockNavOpen() {
	var nav = $('#clock_nav');
	if (!nav.length) { return; }
	nav.addClass('open').show();
	jawnosClockNavPlace();
}

function jawnosClockNavClose() {
	$('#clock_nav').removeClass('open').hide();
}

function jawnosClockNavToggle() {
	if ($('#clock_nav').hasClass('open')) { jawnosClockNavClose(); }
	else { jawnosClockNavOpen(); }
}

function jawnosClockNavPlace() {
	var nav = $('#clock_nav');
	var clock = $('#taskbar_clock');
	if (!nav.length || !clock.length || !nav.is(':visible') || !clock.is(':visible')) { return; }
	var rect = clock[0].getBoundingClientRect();
	var width = $(window).width();
	var height = $(window).height();
	var gap = 4;
	var nav_width = Math.min(nav.outerWidth() || 200, width);
	var left = rect.right - nav_width;
	left = Math.max(4, Math.min(left, width - nav_width - 4));
	// The menu hangs away from the bar: below a top bar, above a bottom bar,
	// and below a bar on either side (where it is not off the top or bottom of
	// the screen).
	var edge = $('#taskbar').attr('position') || (typeof jawnosBars != 'undefined' ? jawnosBars.taskbar : 'bottom');
	var below = (edge != 'bottom');
	var place = { left: Math.round(left) + 'px', right: 'auto' };
	if (below) {
		place.top = Math.round(rect.bottom + gap) + 'px';
		place.bottom = 'auto';
	}
	else {
		place.bottom = Math.round(height - rect.top + gap) + 'px';
		place.top = 'auto';
	}
	if (place.top != 'auto') {
		var max_height = height - (rect.bottom + gap) - 8;
		if (max_height < 100) { max_height = 100; }
		nav.css('max-height', Math.round(max_height) + 'px');
	}
	else {
		var max_height2 = rect.top - gap - 8;
		if (max_height2 < 100) { max_height2 = 100; }
		nav.css('max-height', Math.round(max_height2) + 'px');
	}
	nav.css(place);
}

$(document).on('click', '#taskbar_clock', function (e) {
	if ($(e.target).is('.taskbar_clock_input')) { return; }
	if (typeof jawnosClockEditing == 'function' && jawnosClockEditing()) { return; }
	if (typeof jawnosTaskbarEditing == 'function' && jawnosTaskbarEditing()) { return; }
	jawnosClockNavToggle();
});

$(document).on('click', '#clock_nav [data-clock-action="time_machine"]', function () {
	jawnosClockNavClose();
	if (typeof jawnosClockEditStart == 'function') { jawnosClockEditStart(); }
	if (typeof jawnosClockNavClose == 'function') { jawnosClockNavClose(); }
});

$(document).on('click', function (e) {
	if (!$(e.target).closest('#clock_nav, #taskbar_clock').length) { jawnosClockNavClose(); }
});

$(document).on('keydown', function (e) {
	if (e.keyCode == 27) { jawnosClockNavClose(); }
});

$(window).on('resize', function () {
	if ($('#clock_nav').hasClass('open')) { jawnosClockNavPlace(); }
});
