var mLastX = 0;
var mLastY = 0;
var mLastTs = Date.now();
$(document).on('mousemove', function(e) {
	window.event = e;
	mouse = e;
});
function mouse_position() {
  var e = window.event;
	var data = { 'lastX': mLastX, 'lastY': mLastY, lastTs: mLastTs }; 
	if(e) {
 		mLastX = e.clientX;
  	mLastY = e.clientY;
		mLastTs = Date.now();
	}
	data['x'] = mLastX;
	data['y'] = mLastY;
	data['ts'] = Date.now();
  return data;
}

function say_it(words) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/say_it',
		type: 'GET',
		data: { 'words': words, 'timestamp': timestamp }
	});
}

function format_name(name) {
	var names = name.split('_');
	var named = [];
	var formatted = '';
	$.each(names, function(i,v) {
		v = v.charAt(0).toUpperCase() + v.slice(1);
		named.push(v);
	});
	formatted = named.join(' ');
	return formatted;
}

// The first few letters of a name, the way subs::shorthand_name() takes them:
// what a bar too narrow for the whole word can say instead.
function shorthand_name(name, shorten) {
	name = '' + (name || '');
	shorten = shorten || 5;
	return name.slice(0, shorten);
}

function quality_inventory(timestamp) {
	// a blank attribute - a warranty or OST the row never set - is not 1970:
	// leave the cell empty rather than reading it as fifty-odd years ago
	if (timestamp === undefined || timestamp === null || timestamp === '') { return ''; }
	var now = Date.now();
	var then = Number(timestamp);
	if (isNaN(then)) { return ''; }

	var since = (now - then);
	var future = since < 0;
	if (future) { since = Math.abs(since); }
	var seconds = (since / 1000);
	var minutes = (seconds / 60);
	var hours = (minutes / 60);
	var days = (hours / 24);
	var t = "";

	// A month is the average calendar month and a year the average calendar
	// year, and the month count is taken in whole months with the days left over,
	// so eleven months never rounds up into a twelfth: a year ago reads 1y, never
	// 12.1333M. The half day keeps 91 days from reading 2M 30d.
	var month_days = 30.4375;
	var months = Math.floor((days + 0.5) / month_days);

	// The short form is not fixed to one denomination: it wears the one the span
	// belongs to with the next smaller one beside it - hours under a day, then
	// days, months and years, each turning over as soon as there is a whole one.
	if (seconds < 60) { 
		t += Math.floor(seconds) + 's';
	}
	else if (minutes < 60) { 
		t += Math.floor(minutes) + 'm';
		var r = Math.floor(seconds % 60);
		if (r > 0) {
			t += ' ' + r + 's';
		}
	}
	else if (hours < 24) { 
		var parts = [];
		var hh = Math.floor(hours);
		var mm = Math.floor((seconds % 3600) / 60);
		var ss = Math.floor(seconds % 60);
		if (hh) { parts.push(hh + 'h'); }
		if (mm) { parts.push(mm + 'm'); }
		if (ss) { parts.push(ss + 's'); }
		t += parts.slice(0, 2).join(' ');
	}
	else if (months < 1) { 
		var parts = [];
		var dd = Math.floor(seconds / 86400);
		var hh = Math.floor((seconds % 86400) / 3600);
		var mm = Math.floor((seconds % 3600) / 60);
		parts.push(dd + 'd');
		if (hh) { parts.push(hh + 'h'); }
		if (mm) { parts.push(mm + 'm'); }
		t += parts.slice(0, 2).join(' ');
	}
	else {
		var years = Math.floor(months / 12);
		var leftover_months = months % 12;
		if (years > 0) { t += years + 'y'; }
		if (leftover_months > 0) {
			t += (t ? ' ' : '') + leftover_months + 'M';
		}
		var leftover_days = Math.max(0, Math.floor(days - months * month_days));
		if (leftover_days > 0) {
			t += (t ? ' ' : '') + leftover_days + 'd';
		}
	}

	if (future) { t = 'in ' + t; }
	return t; 
}

// A span of time read in one unit: all of it in hours with the minutes left
// over, or all of it in minutes with the seconds left over.
function jawnosDurationHours(ms) {
	var s = Math.floor(Math.abs(Number(ms) || 0) / 1000);
	var h = Math.floor(s / 3600);
	var m = Math.floor((s % 3600) / 60);
	return h + 'h' + (m ? ' ' + m + 'm' : '');
}
function jawnosDurationMinutes(ms) {
	var s = Math.floor(Math.abs(Number(ms) || 0) / 1000);
	var m = Math.floor(s / 60);
	var sec = s % 60;
	return m + 'm' + (sec ? ' ' + sec + 's' : '');
}
function quality_inventory_hours(timestamp) {
	var now = Date.now();
	var then = Number(timestamp);
	if (timestamp === undefined || timestamp === null || timestamp === '' || isNaN(then)) { return ''; }
	return (now < then ? 'in ' : '') + jawnosDurationHours(Math.abs(now - then));
}
function quality_inventory_minutes(timestamp) {
	var now = Date.now();
	var then = Number(timestamp);
	if (timestamp === undefined || timestamp === null || timestamp === '' || isNaN(then)) { return ''; }
	return (now < then ? 'in ' : '') + jawnosDurationMinutes(Math.abs(now - then));
}

// The view a display keeps for its time labels. Each window's app remembers
// which reading it wore last, so a reload comes back the same way.
var timeDisplayCache = {};
var timeClickTimer;
function timeDisplayKey(display) {
	return display ? 'time_display:' + display : 'time_display';
}
function timeDisplaySaved(display) {
	var key = timeDisplayKey(display);
	if (!(key in timeDisplayCache)) {
		try { timeDisplayCache[key] = localStorage.getItem(key) || ''; }
		catch (e) { timeDisplayCache[key] = ''; }
	}
	return timeDisplayCache[key];
}
function timeDisplaySave(display, mode) {
	var key = timeDisplayKey(display);
	timeDisplayCache[key] = mode;
	try { localStorage.setItem(key, mode); } catch (e) {}
}

// The Dur column has its own three readings (there is no fixed duration), and
// its own remembered view per display.
var durationDisplayCache = {};
function durationDisplayKey(display) {
	return display ? 'duration_display:' + display : 'duration_display';
}
function durationDisplaySaved(display) {
	var key = durationDisplayKey(display);
	if (!(key in durationDisplayCache)) {
		try { durationDisplayCache[key] = localStorage.getItem(key) || ''; }
		catch (e) { durationDisplayCache[key] = ''; }
	}
	return durationDisplayCache[key];
}
function durationDisplaySave(display, mode) {
	var key = durationDisplayKey(display);
	durationDisplayCache[key] = mode;
	try { localStorage.setItem(key, mode); } catch (e) {}
}

// A reading that would print exactly what the label already says is no turn at
// all - two hours is "2h" in the short form and "2h" again in whole hours - so
// a click steps past it to the first reading that says something new.
function durationModeNext(ms, sign, current) {
	var modes = [ 'dynamic', 'hours', 'minutes' ];
	var start = modes.indexOf(current);
	if (start < 0) { start = 0; }
	sign = sign || '';
	if (typeof jawnosDurationText !== 'function') { return modes[(start + 1) % modes.length]; }
	var reading = sign + jawnosDurationText(ms / 1000, modes[start]);
	for (var i = 1; i <= modes.length; i++) {
		var candidate = modes[(start + i) % modes.length];
		if ((sign + jawnosDurationText(ms / 1000, candidate)) !== reading) { return candidate; }
	}
	return modes[(start + 1) % modes.length];
}

// The same rule for a time label: the short form and whole hours both read "3h"
// on an exact three hours, so the click carries on to the reading that differs.
var timeModeReading = {
	dynamic: function (timestamp) { return quality_inventory(timestamp); },
	hours: function (timestamp) { return quality_inventory_hours(timestamp); },
	minutes: function (timestamp) { return quality_inventory_minutes(timestamp); },
	fixed: function (timestamp) { return fixedTimeString(timestamp); }
};
function timeModeNext(timestamp, current, modes) {
	var start = modes.indexOf(current);
	if (start < 0) { start = 0; }
	var reading = timeModeReading[current] ? timeModeReading[current](timestamp) : '';
	for (var i = 1; i <= modes.length; i++) {
		var candidate = modes[(start + i) % modes.length];
		if (!timeModeReading[candidate]) { continue; }
		if (timeModeReading[candidate](timestamp) !== reading) { return candidate; }
	}
	return modes[(start + 1) % modes.length];
}

