/* [[js-split]]
   clock.js is part 1. The rest live in clock/ in name order:
     01_alarms_timers.js - alarm editing, timers, countdown and tick
     02_stopwatch_world_ring.js - stopwatch, world clock, ring card and taskbar nav
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
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
// The little arithmetic gate on the ring card: null when the alarm rings
// plainly, otherwise { a, b, c, answer, solved }.
var jawnosClockRingMath = null;

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
	// Both loops reschedule themselves instead of running a fixed interval: a
	// fixed 250 ms tick kept the main thread awake 4x/s with nothing to draw, and a
	// fixed 5 s poll asked the server about a window that was not open.
	var clockPollSchedule = function (delay) {
		clearTimeout(jawnosClockPollTimer);
		jawnosClockPollTimer = setTimeout(function () {
			if (document.hidden) { clockPollSchedule(5000); return; }
			var open = $('.clock_app').length > 0;
			// The state is fetched even with no Clock window open, so a phone sitting
			// on the manager (or another app) still learns an alarm is ringing and
			// draws the ring card. That backstop has nothing on screen to keep in step,
			// so it can wait 60 s; an open window keeps the old 5 s cadence.
			jawnosClockRefresh();
			clockPollSchedule(open ? 5000 : 60000);
		}, delay);
	};
	var clockTickSchedule = function (delay) {
		clearTimeout(jawnosClockTickTimer);
		jawnosClockTickTimer = setTimeout(function () {
			// A hidden tab (or one with no Clock window) has nothing to tick: wake
			// once a second, cheaply, and leave the 4 Hz work to an open window.
			if (document.hidden || !$('.clock_app').length) { clockTickSchedule(1000); return; }
			jawnosClockTick();
			clockTickSchedule(250);
		}, delay);
	};
	// A window opened later is hydrated (and refreshed) by the observer above, so
	// the idle poll can stay slow until its next wake sees the window.
	clockPollSchedule(5000);
	clockTickSchedule(250);
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

// A ring card follows the server's ringing flag as well as the live push, so a
// window opened (or reloaded) while an alarm is still sounding shows the card
// again, and one dismissed on another screen closes here too. Every machine
// draws the card, not only the one carrying the sound: the answer is a shared
// edit, so any open Manager window can end the ring everywhere.
function jawnosClockSyncRinging(state) {
	var alarms = state.alarms || [];
	var ringing = $.grep(alarms, function (a) { return a.ringing; });
	if (jawnosClockRingingCurrent) {
		var current = jawnosClockRingingCurrent;
		var same = $.grep(alarms, function (a) { return a.uuid == current.uuid; });
		// A relayed notice can arrive before the shared row does. Keep the card
		// until its own guard runs out rather than closing it on an empty poll.
		if (!same.length) { return; }
		var a = same[0];
		var at = parseInt(current.ring_at || current.fired_at || 0, 10) || 0;
		var stopAt = parseInt(a.stop_at || 0, 10) || 0;
		// A peer's notice can arrive before the shared row has caught up with
		// the ring. Only a stop at or after this ring - or the five-minute
		// guard running out - takes the card down early.
		if (stopAt && at && stopAt >= at) { jawnosClockAlarmStop(); return; }
		if (!a.ringing && at && (Date.now() - at) > 300000) { jawnosClockAlarmStop(); return; }
		if (!a.ringing && !at) { jawnosClockAlarmStop(); return; }
		return;
	}
	if (ringing.length && !jawnosClockRinging.length) {
		var a = ringing[0];
		jawnosClockShowRing({
			uuid: a.uuid, label: a.label, hour: a.hour, minute: a.minute,
			sound: a.sound, volume: a.volume, ramp: a.ramp, app: a.app,
			snooze: a.snooze, play: a.play, nfc: (a.nfc_ready || 0), nfc_action: a.nfc_action,
			fired_at: a.ring_started || 0
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

// The name a linked appointment wears in the picker and in the alarm row. The
// state carries the house's own label (format_name), so the row and the menu
// agree; an app that has not written an appointment yet falls back to its key.
function jawnosClockAppLabel(app) {
	app = app || '';
	if (!app) { return ''; }
	var label = '';
	$.each(jawnosClockApps || [], function (i, a) {
		if ((a.value || '') == app) { label = a.label || a.value || ''; return false; }
	});
	return label || app.replace(/_/g, ' ');
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
		html += '<button type="button" class="clock_app_choice' + (app.value == chosen ? ' selected' : '') + '" data-app="' + jawnosClockEsc(app.value) + '" data-label="' + jawnosClockEsc(label) + '">';
		// The icon may be a span of initials ("WU") when the app has no picture,
		// so the label carries its own class; selecting the first span picked the
		// icon and put "WU" in the field instead of "Wake Up".
		html += (app.icon || '') + '<span class="clock_app_choice_label">' + jawnosClockEsc(label) + '</span></button>';
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
	if ($(this).hasClass('clock_alarm_app')) {
		jawnosClockNfcVisibility($(this).closest('.clock_alarm'), jawnosClockState);
	}
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
	var label = $(this).attr('data-label') || $(this).find('.clock_app_choice_label').first().text();
	if (!label) { label = $(this).find('span').last().text(); }
	input.attr('data-app', app).attr('data-label', label || '').val(app ? label : '');
	if (input.hasClass('clock_alarm_app')) {
		jawnosClockNfcVisibility(input.closest('.clock_alarm'), jawnosClockState);
	}
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

// The NFC toggle is only useful when the linked appointment carries an NFC
// start tag; the server says which apps do in state.nfc_apps. An alarm that is
// already on keeps its field (and its checkbox live) even after the tag goes,
// so it can be turned back off.
function jawnosClockNfcVisibility(row, state) {
	if (!row || !row.length) { return; }
	var field = row.find('.clock_alarm_nfc_field');
	if (!field.length) { return; }
	state = state || jawnosClockState || {};
	var app = row.find('.clock_alarm_app').attr('data-app') || '';
	var tags = state.nfc_apps || {};
	var has_tag = !!(app && tags[app]);
	var box = field.find('.clock_alarm_nfc');
	var on = box.is(':checked');
	field.toggle(has_tag || on);
	box.prop('disabled', !has_tag && !on);
	field.find('.clock_nfc_hint').toggle(!has_tag);
	field.find('.clock_alarm_nfc_action').toggle(on);
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
	html += '<label class="clock_field"><span>' + jawnosClockEsc(jawnosT('link_appointment')) + '</span><div class="clock_app_picker"><input type="text" class="clock_alarm_app" autocomplete="off" data-app="' + jawnosClockEsc(alarm.app || '') + '" value="' + jawnosClockEsc(jawnosClockAppLabel(alarm.app)) + '" placeholder="' + jawnosClockEsc(jawnosT('no_appointment')) + '"><button type="button" class="clock_app_toggle" tabindex="-1" aria-label="' + jawnosClockEsc(jawnosT('link_appointment')) + '">▾</button></div></label>';
	var nfc_tags = (state && state.nfc_apps) || {};
	var nfc_tag = (alarm.app && nfc_tags[alarm.app]) ? 1 : 0;
	var nfc_on = alarm.nfc ? 1 : 0;
	var nfc_action = (alarm.nfc_action == 'dismiss') ? 'dismiss' : 'snooze';
	html += '<label class="clock_field"><span>' + jawnosClockEsc(jawnosT('play_mode')) + '</span><select class="clock_alarm_play">';
	html += '<option value=""' + ((alarm.play || '') == 'math' ? '' : ' selected') + '>' + jawnosClockEsc(jawnosT('none')) + '</option>';
	html += '<option value="math"' + ((alarm.play || '') == 'math' ? ' selected' : '') + '>' + jawnosClockEsc(jawnosT('math')) + '</option>';
	html += '</select></label>';
	html += '<label class="clock_field clock_alarm_nfc_field"' + ((nfc_tag || nfc_on) ? '' : ' style="display:none;"') + '>';
	html += '<span>' + jawnosClockEsc(jawnosT('use_nfc_to_snooze')) + '</span>';
	html += '<div class="clock_nfc_row"><input type="checkbox" class="clock_alarm_nfc"' + (nfc_on ? ' checked' : '') + ((nfc_tag || nfc_on) ? '' : ' disabled') + '>';
	html += '<select class="clock_alarm_nfc_action" aria-label="' + jawnosClockEsc(jawnosT('nfc_action')) + '"' + (nfc_on ? '' : ' style="display:none;"') + '>';
	html += '<option value="snooze"' + (nfc_action == 'dismiss' ? '' : ' selected') + '>' + jawnosClockEsc(jawnosT('snooze')) + '</option>';
	html += '<option value="dismiss"' + (nfc_action == 'dismiss' ? ' selected' : '') + '>' + jawnosClockEsc(jawnosT('dismiss')) + '</option>';
	html += '</select></div>';
	html += '<span class="clock_nfc_hint"' + (nfc_tag ? ' style="display:none;"' : '') + '>' + jawnosClockEsc(jawnosT('Link an appointment with an NFC start tag to use this.')) + '</span>';
	html += '</label>';
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
	list.find('.clock_alarm').each(function () { jawnosClockNfcVisibility($(this), state); });
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
		play: row.find('.clock_alarm_play').val() || '',
		nfc: row.find('.clock_alarm_nfc').is(':checked') ? 1 : 0,
		nfc_action: row.find('.clock_alarm_nfc_action').val() || 'snooze',
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
			// The delivery confirmations are written by the background push, which
			// answers after this save does. Look again shortly so the ✓ marks appear
			// as the machines confirm instead of waiting for the five-second poll.
			setTimeout(function () { jawnosClockRefresh(true); }, 1200);
			setTimeout(function () { jawnosClockRefresh(true); }, 3200);
		});
	}, delay || 0);
}

$(document).on('change', '.clock_alarm_time, .clock_alarm_label, .clock_alarm_app, .clock_alarm_sound, .clock_alarm_enabled, .clock_alarm_play, .clock_alarm_nfc, .clock_alarm_nfc_action', function () {
	var row = $(this).closest('.clock_alarm');
	if ($(this).hasClass('clock_alarm_time')) {
		var time = jawnosClockParseTime($(this).val());
		$(this).val(jawnosClockTime(time[0], time[1]));
		row.find('.clock_alarm_head_time').text(jawnosClockTime(time[0], time[1]));
	}
	if ($(this).hasClass('clock_alarm_app') || $(this).hasClass('clock_alarm_nfc')) {
		jawnosClockNfcVisibility(row, jawnosClockState);
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

