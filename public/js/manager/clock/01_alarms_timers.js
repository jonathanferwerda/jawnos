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

$(document).on('input', '.clock_timer_volume', function () {
	var field = $(this).closest('.clock_timer_volume_field');
	field.find('span').first().text(jawnosT('volume') + ' · ' + $(this).val() + '%');
});

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
	var volume = parseInt(panel.find('.clock_timer_volume').val() || 70, 10);
	jawnosClockPost('/manager/clock/timer', {
		action: 'start', hours: hours, minutes: minutes, seconds: seconds, label: label, app: app, volume: volume
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

