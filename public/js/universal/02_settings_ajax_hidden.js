var months = [
	{ 'abbrev': 'jan', name: 'January', days: 31, leap_days: 31 },
	{ 'abbrev': 'feb', name: 'February', days: 28, leap_days: 29 },
	{ 'abbrev': 'mar', name: 'March', days: 31, leap_days: 31 },
	{ 'abbrev': 'apr', name: 'April', days: 30, leap_days: 30 },
	{ 'abbrev': 'may', name: 'May', days: 31, leap_days: 31 },
	{ 'abbrev': 'jun', name: 'June', days: 30, leap_days: 30 },
	{ 'abbrev': 'jul', name: 'July', days: 31, leap_days: 31 },
	{ 'abbrev': 'aug', name: 'August', days: 31, leap_days: 31 },
	{ 'abbrev': 'sep', name: 'September', days: 30, leap_days: 30 },
	{ 'abbrev': 'oct', name: 'October', days: 31, leap_days: 31 },
	{ 'abbrev': 'nov', name: 'November', days: 30, leap_days: 30 },
	{ 'abbrev': 'dec', name: 'December', days: 31, leap_days: 31 },
];

$(document).on('dblclick', '.time', function() {
	var header = $(this);
	if (!header.attr('timestamp')) { return; }
	clearTimeout(timeClickTimer);
	var timestamp = numeral(header.attr('timestamp')).value();
	var ago = fixedTimeString(timestamp);
	$('#time_machine').val(ago);
	localStorage.setItem('time_machine',ago);
});

$(document).on('click', '.time, .appointment_header, .since, .appointment_detail_duration, .jawnos_duration', function() {
	var header = $(this);
	// the outer appointment header carries the icon but no timestamp; the time
	// inside it is the one that reads, so only that one turns the page. A
	// templated duration carries its span instead, and turns the same way.
	if (!header.is('input') && (header.attr('timestamp') || header.attr('duration'))) {
		// A double-click carries the view to this time; wait out the second press
		// before turning the page, so one gesture is not also a mode change.
		clearTimeout(timeClickTimer);
		timeClickTimer = setTimeout(function() {
			var display = header.closest('.wind').attr('app') || '';
			if (header.hasClass('appointment_detail_duration') || header.hasClass('jawnos_duration')) {
				// a duration has no fixed reading: short, hours, minutes - and a
				// reading that would print the same words is stepped past
				var dcurrent = durationDisplaySaved(display) || 'dynamic';
				var span = (typeof jawnosDurationSpan === 'function') ? jawnosDurationSpan(header, Date.now()) : null;
				var dnext = span
					? durationModeNext(span.ms, span.sign, dcurrent)
					: ([ 'dynamic', 'hours', 'minutes' ][([ 'dynamic', 'hours', 'minutes' ].indexOf(dcurrent) + 1) % 3]);
				durationDisplaySave(display, dnext);
				if (typeof jawnosDurationTick === 'function') { jawnosDurationTick(); }
				return;
			}
			// drop the fixed-mode repaint gate so the new reading shows right away
			header.removeAttr('next_check');
			var modes = [ 'dynamic', 'hours', 'minutes', 'fixed' ];
			var current = header.attr('mode') || 'dynamic';
			var next = timeModeNext(numeral(header.attr('timestamp')).value(), current, modes);
			header.attr('mode', next);
			if (next == 'fixed') {
				var timestamp = numeral(header.attr('timestamp')).value();
				header.attr('formatted_time', fixedTimeString(timestamp));
			}
			timeDisplaySave(display, next);
			appointment_chron();
		}, 250);
	}
});

function fixedTimeString(timestamp) {
const date = new Date(timestamp);
	const datevalues = [
		date.getFullYear(),
		date.getMonth()+1,
		date.getDate(),
		date.getHours(),
		date.getMinutes(),
		date.getSeconds(),
		dayProcessor(date.getDay())
	];
	$.each(datevalues, function(i,v) {
		if (v < 10) {
			datevalues[i] = '0' + v;
		}
	});
	return datevalues[6] + ' ' + datevalues[1] + '/' + datevalues[2] + '/' + datevalues[0] + ' ' + datevalues[3] + ':' + datevalues[4] + ':' + datevalues[5]
			
}

function dayProcessor(day) {
	var d;
	if (day == 0) {
		d = 'Sun';
	}
	else if (day == 1) {
		d = 'Mon';
	}
	else if (day == 2) {
		d = 'Tue';
	}
	else if (day == 3) {
		d = 'Wed';
	}
	else if (day == 4) {
		d = 'Thu';
	}
	else if (day == 5) {
		d = 'Fri';
	}
	else if (day == 6) {
		d = 'Sat';
	}
	else { d = ''; }
	return d;
}

function isJson(str) {
	try {
		JSON.parse(str);
	}
	catch (e) {
		return false;
	}
	return true;
}

function timestampDater() {
	$('.timestamp').each(function() {
		var t = numeral($(this).text()).value();
		var m = moment(t).format('M/D/YYYY');
		$(this).text(m);
		$(this).removeClass('timestamp');
	});
}

$(document).on('click', '#error_dot', function() {
	clearTimeout(errorDotTimeout);
	if ($('#error_info').is(':visible')) {
		$('#error_info').hide();
	}
	else {
		$('#error_info').html('hey').show();
	}
});


// Setting writes are a POST each, and callers fire them on clicks, keystrokes,
// scrolls and resizes. The same value again is a wasted round trip and a
// database write, so remember what this page last sent for each key and skip an
// exact repeat. The first send for a key always goes through, and a failed one
// is forgotten so the next caller retries it.
var settingSetterSent = {};
async function settingSetter(setter) {
	var app = setter['app'];
	var value = setter['value'];
	var setting = setter['setting'];
	var timestamp = Date.now();
	var device = setter['device'];
	var key = (device || '') + '\u0000' + app + '\u0000' + setting + '\u0000' + (setter['subsetting'] || '');
	var encoded = (value === undefined || value === null) ? '' : String(value);
	if (settingSetterSent[key] === encoded) {
		return Promise.resolve(null);
	}
	settingSetterSent[key] = encoded;
	var request = $.ajax({
		url: '/manager/setting_setter',
		type: 'POST',
		data: { app: app, setting:setting, device: device, subsetting: setter['subsetting'], value:value, timestamp: timestamp},
		success: function(response) {
			return response;
		}
	});
	request.fail(function() {
		if (settingSetterSent[key] === encoded) { delete settingSetterSent[key]; }
	});
	return request;
}

async function settingGrabber(setter) {
	var timestamp = Date.now();
	var app = setter['app'];
	var setting = setter['setting'];
	var response = $.ajax({
		url: '/manager/setting_grabber',
		type: 'GET',
		data: { app: app, setting: setting, timestamp: timestamp},
		success: function(response) {

//			return response;
		}
	});
	if (isJson(response)) {
		response = JSON.parse(response);
	}
	return response;
}

function settingsGrabber(setter) {
	var timestamp = Date.now();
	var app = setter['app'];
	var device = setter['device'];
	$.ajax({
		url: '/manager/settings_grabber',
		type: 'GET',
		data: { app: app, device: device },
		success: function(response) {
			return response;
		}
	});
}


function settingDeleter(setter) {
	var timestamp = Date.now();
	var app = setter['app'];
	var setting = setter['setting'];
	var device = setter['device'];
	return $.ajax({
		url: '/manager/setting_deleter',
		type: 'POST',
		data: { app: app, device:device, setting: setting},
		success: function(response) {
			return response;
		}
	});
}

$(document).on('click', '.dot', function(e) {
	// A click inside the expanded info is reading it, not dismissing it.
	if ($(e.target).closest('.dot_info').length) { return; }
	var di = $(this).find('.dot_info');
	if (di.is(':visible')) {
		di.hide();
	}
	else {
		di.show();
	}
});

// Every request's own url is stashed on its jqXHR as it starts: the ajaxSetup
// error callback below is handed no settings, so without this the dot could
// only ever say "request" where it should name the route that failed.
$.ajaxPrefilter(function(options, original, jqXHR) {
	if (options && options.url) { jqXHR.jawnos_url = options.url; }
});

$.ajaxSetup({
	cache: false,
	data: { browser_tab_id: bti, browser_tab: bt, user_agent: navigator.userAgent, signatorial: signatorial },
	success: function(response) {
	},
	
	error: function(e,t,r) {
	//	errorInfo.push(e);
		// A request that never reached the server is not a fault to shout about: the
		// tree is restarting (an update is a push then a restart), the link
		// dropped, or the page is unloading as the tab reloads. Say it in the
		// console and leave the corner alone, so receiving an update never greets
		// someone with a red dot they cannot act on.
		if (t === 'abort' || !e || e.status === 0) {
			console.log('request did not reach jawn:', (e && e.jawnos_url) || '?', t);
			return;
		}
		// A lapsed session is not a request fault. The phone wakes with a stale
		// cookie after a long sleep, the first background request (the phone
		// facts sync) meets the Gate, and the old code painted a red dot for it
		// every time. Go back through the Gate instead: the app's page-finished
		// check hands over a fresh ticket, and a desktop simply lands on the Gate.
		if (e.status === 401) {
			console.log('session lapsed:', (e.jawnos_url || 'request'));
			if (!window.__jawnSessionReloading && !document.getElementById('welcome_logo')) {
				window.__jawnSessionReloading = true;
				setTimeout(function() { location.reload(); }, 400);
			}
			return;
		}
		var url = (e.jawnos_url || 'request').replace(/\?.*$/, '');
		var body = (e.responseText || '').replace(/\s+/g, ' ').trim();
		var message = e.status + ': ' + url + (body ? ' — ' + body : '');
		if (message.length > 200) {
			message = message.slice(0, 200) + '…';
		}
		$('#red_dot').show();
		$('#red_dot').find('.dot_info').text(message);
		errorDotTimeout = setTimeout(function() {
			$('#red_dot').fadeOut();
		},15000);
	}
});

// A phone that has been asleep longer than the session's activity window wakes
// with a stale cookie. Reload once on resume so the app can hand over a fresh
// ticket before the first tap, instead of losing that tap to a 401.
var jawnHiddenAt = 0;
document.addEventListener('visibilitychange', function() {
	if (document.hidden) { jawnHiddenAt = Date.now(); return; }
	var hidden = jawnHiddenAt ? (Date.now() - jawnHiddenAt) : 0;
	jawnHiddenAt = 0;
	if (hidden > 80 * 60 * 1000 && window.JawnPhone) { location.reload(); }
});


