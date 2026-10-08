var tree = {};
var appointment_chronicler;
var appointment_windows = {};
var errorDotTimeout;
var errorInfo = [];
if (!signatorial in window) {
	globalThis.signatorial = 'unknown';
}
$(document).ready(function() {
	appointment_chron();
});

$(document).on('keyup click change', 'textarea, .text-editor', function() {
	var ta = $(this);
	var scrollHeight = ta[0].scrollHeight;
	var scrollTop = ta.scrollTop();
	var height = ta.height();
	if (scrollHeight > (height + 5) || scrollHeight < (height - 5)) {
		if (scrollHeight < 700) {
			ta.height(scrollHeight);
		}
	}
	if (ta.val() == '') {
		ta.height(30);
	}
});


function appointment_chron() {
	clearInterval(appointment_chronicler);
	time_updater();
	appointment_chronicler = setInterval(function(){
		// no point repainting clocks while the page isn't on screen
		if (document.hidden) { return; }
		time_updater();
	},1000);
	function time_updater() {
		var now = Date.now();
		$('.since, .time').each( function() {
			var header = $(this);
			var mode = $(this).attr('mode');
			var timestamp = $(this).attr('timestamp');

			if (mode == 'fixed') {
				// Fixed times never change, so paint one and skip the element for a
				// while. Clicking the element drops next_check, so the toggle back to
				// fixed paints straight away instead of waiting out this hour.
				var next_check = numeral(header.attr('next_check')).value();
				if (next_check && next_check > now) { return; }
				if (!header.attr('formatted_time')) {
					header.attr('formatted_time', fixedTimeString(numeral(timestamp).value()));
				}
				if (header.is('input') && !header.hasClass('editing')) {
					header.val(header.attr('formatted_time')).css({'background-color': '#ddffee'});
				}
				else if (header.hasClass('editing')) {
					header.css({'background-color': '#ddffee'})
				}
				else {
					header.text(header.attr('formatted_time'));
				}
				header.attr('next_check', now + 3600000);
			}
			else {
				// Dynamic times read "in 3m 12s" or "3d 4h ago", so they are worked out
				// every second -- the DOM is only touched when the text really changed.
				if (header.is('input') && !header.hasClass('editing')) {
					var value = quality_inventory(timestamp);
					if (header.val() != value) { header.val(value).css({'background-color': '#ffffff'}); }
				}
				else if (header.hasClass('editing')) {
					header.css({'background-color': '#ffffff'});
					header.attr('mode', 'dynamic');
					// while typing, keep repainting so it settles as soon as they stop
					return;
				}
				else {
					var text = quality_inventory(timestamp);
					if (header.text() != text) { header.text(text); }
				}
				header.attr('mode', 'dynamic');
			}

		});
	}
}

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

function quality_inventory(timestamp) {
	var now = numeral(Date.now()).value();
	var then = timestamp;


	var since = (now - then);
	var t = "";
	if (now < then) {  since = Math.abs(since); }
	var seconds = (since / 1000);
	var minutes = (seconds / 60);
	var hours = (minutes / 60);
	var days = numeral(hours / 24).format('0.000');
	var weeks = numeral( days / 7 ).format('0.000');
	var months = numeral( days / 30 ).format('0.000');
	var seasons = numeral( days / 90 ).format('0.000');
	var years = numeral( days / 365 ).format('0.000');


	if (seconds < 60) { 
		t += numeral(seconds).format('10') + 's';
	}
	if ( seconds >= 60 && minutes < 60 ) { 
		t += Math.floor(minutes) + 'm';
		var r = (minutes - Math.floor(minutes)) * 60;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 's';
		}
	}
	if (minutes >= 60 && hours <= 24 ) { 
		t += Math.floor(hours) + 'h';
		var r = (hours - Math.floor(hours)) * 60;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'm';
		}
		r = r - Math.floor(r);
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r * 60) + 's';
		}
	}
	if (hours > 24 && days <= 90) { 
		t += Math.floor(days) + 'd';
		var r = (days - Math.floor(days)) * 24;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'h';
		}
		r = (r - Math.floor(r)) * 60;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'm';
		}

	}
	if (days > 90 && months < 24) { 
		t += numeral(months).format('0,0.0000') + 'M';
	}
	if (years >= 2) { 
		t += Math.floor(years) + 'y';
		var r = years - Math.floor(years);
		r = r * 12;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'M';
		}
		r = numeral((r - Math.floor(r)) * 30).format('0.000');
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'd';
		}

	}



	if (now < then) { t = 'in ' + t; since = Math.abs(since); }
	return t; 
}

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
	var ago = $(this).attr('formatted_time');
	$('#time_machine').val(ago);
	localStorage.setItem('time_machine',ago);
});


$(document).on('click', '.time, .appointment_header, .since', function() {
	var header = $(this);
	if (!header.is('input')) {
		// drop the fixed-mode repaint gate so the switch shows up right away
		header.removeAttr('next_check');
		if (header.attr('mode') == 'fixed') {
			header.attr('mode', 'dynamic');
		}
		else {
			header.attr('mode', 'fixed');
			var timestamp = numeral(header.attr('timestamp')).value();
			header.attr('formatted_time', fixedTimeString(timestamp));
		}
		appointment_chron();
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


async function settingSetter(setter) {
	var app = setter['app'];
	var value = setter['value'];
	var setting = setter['setting'];
	var timestamp = Date.now();
	var device = setter['device'];
	$.ajax({
		url: '/manager/setting_setter',
		type: 'POST',
		data: { app: app, setting:setting, device: device, value:value, timestamp: timestamp},
		success: function(response) {
			return response;
		}
	});
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
	$.ajax({
		url: '/manager/setting_deleter',
		type: 'POST',
		data: { app: app, device:device, setting: setting},
		success: function(response) {
			return response;
		}
	});
}

$(document).on('click', '.dot', function() {
	var di = $(this).find('.dot_info');
	if (di.is(':visible')) {
		di.hide();
	}
	else {
		di.show();
	}
});

$.ajaxSetup({
	cache: false,
	data: { browser_tab_id: bti, browser_tab: bt, user_agent: navigator.userAgent, signatorial: signatorial },
	success: function(response) {
	},
	
	error: function(e,t,r,settings) {
	//	errorInfo.push(e);
		$('#red_dot').show();
		$('#red_dot').find('.dot_info').text(e.status);// + ': ' + settings.url);
		errorDotTimeout = setTimeout(function() {
			$('#red_dot').fadeOut();
		},15000);
	}
});


var padlock_jw_deg =  0;
var padlock_last = 'out';
var padlock_jw_position = 0;
var padlock_numbers = { 
	diffs: [], 
	turns: [], 
	sequence: [], 
	digits: [], 
	direction: '', 
	last_timestamp: Date.now(), 
	reset: '',
	pulled: [],
	padlock: undefined
};

$(document).on('touchmove mousemove', '.padlock_jog_wheel', function(e) {
	e.preventDefault();			e.preventDefault();
	var j = $(this);
	var jc = j.closest('.padlock_jog_wheel_frame').find('.padlock_jog_wheel_centre');
	if (e.which === 1 || e.originalEvent.type == 'touchmove') {
		var x = e.originalEvent.clientX;
		var y = e.originalEvent.clientY;
		if (e.originalEvent.targetTouches) {
			x = e.originalEvent.targetTouches[0].clientX;
			y = e.originalEvent.targetTouches[0].clientY;
		}
		var middle_x = numeral(jc.offset().left + (jc.width() / 2)).value();
		var middle_y = numeral(jc.offset().top + (jc.height() / 2)).value();
		var deltaX = middle_x - x;
		var deltaY = middle_y - y;
		var rad = Math.atan2(deltaY, deltaX); 
		var deg = (rad * (180 / Math.PI) - 90);
		var diff = 0;

		if (padlock_last == 'in') {
			diff = (deg - padlock_jw_deg);
		}
		padlock_jw_deg = padlock_jw_deg + diff;
		padlockPicker(j,diff,'wheel');
	}
});

function padlockPicker(j,diff,source) {
	padlock_numbers.padlock = j;
	if (diff) {
		padlock_numbers.diffs.push(diff);
	}
	var movement_ratio = .8;
	if (source == 'mouse') {
		movement_ratio = .8;
	}
	padlock_numbers.last_timestamp = Date.now();
	j.css({'rotate': padlock_jw_deg + 'deg' });
	padlock_last = 'in';

	var numbering = padlock_jw_deg;
	if (numbering > 0) {
		numbering = numbering - 360;
	}
	padlock_jw_position = Math.abs(numeral(numbering / 30).format('0'));
	if (padlock_jw_position == 12) {
		padlock_jw_position = 0;
	}
	padlock_numbers.sequence.push(padlock_jw_position);
	var direction;
	var last_value;
	$.each(padlock_numbers.sequence, function(i,v) {
		if (i >= 1) {
			if (padlock_numbers.sequence[i] == padlock_numbers.sequence[i - 1] || padlock_numbers.sequence[i] == NaN) {
				padlock_numbers.sequence.splice(i,1);
			}
			else if (v != 0 && v < padlock_numbers.sequence[i - 1] || (v == 11 && padlock_numbers.sequence[i - 1] == 0)) {
				direction = 'negative';
			}
			else if (v != 11 && v > padlock_numbers.sequence[i - 1] || (v == 0 && padlock_numbers.sequence[i - 1] == 11)) {
				direction = 'positive';
			}				
		}
		last_value = v;
	});
	var diff_total = { positive: [], negative: [], total: [] };

	$.each(padlock_numbers.diffs, function(i,v) {
		if (v > 0) {
			diff_total.negative.push(v);
		}
		else if (v < 0) {
			diff_total.positive.push(v);
		}
		diff_total.total.push(v);
	});
	if (diff_total.negative.length / diff_total.total.length > movement_ratio) {
		direction = 'negative';
	}
	else if (diff_total.positive.length / diff_total.total.length > movement_ratio) {
		direction = 'positive';
	}
	if (padlock_numbers.diffs.length > 40) {
		padlock_numbers.diffs.splice(0,1);
	}


	if (padlock_numbers.sequence.length >= 12) {
		var checks_positive = [];
		var checks_negative = [];
		padlock_numbers.diffs = [];
		$.each(padlock_numbers.sequence, function(i,v) {
			if (v != 11 && v > padlock_numbers.sequence[i - 1] || (v == 0 && padlock_numbers.sequence[i - 1] == 11)) {
				checks_positive.push('yes');
				checks_negative.push('no');
			}
			if (v != 0 && v < padlock_numbers.sequence[i - 1] || (v == 11 && padlock_numbers.sequence[i - 1] == 0)) {
				checks_negative.push('yes');
				checks_positive.push('no');
			}
		});
		var positive;
		var negative;

		$.each(checks_positive, function(i,v) {
			if (v == 'yes' && positive != 'no') {
				positive = 'yes';
			}
		});
		$.each(checks_negative, function(i,v) {
			if (v == 'yes' && negative != 'no') {
				negative = 'yes';
			}
		});
		if (positive == 'yes') {
			padlock_numbers.turns.push('positive');
		}
		if (negative == 'yes') {
			padlock_numbers.turns.push('negative');
		}

		padlock_numbers.sequence = [];
	}
	if (direction == 'negative' && padlock_numbers.turns[padlock_numbers.turns.length - 1] == 'negative' && 
				padlock_numbers.turns[padlock_numbers.turns.length - 2] == 'negative' && 
				padlock_numbers.turns[padlock_numbers.turns.length - 3] == 'negative') {
		padlockReset(j);
		padlock_numbers.turns.push('negative');
		padlock_numbers.turns.push('negative');
		padlock_numbers.diffs = [];
		$('.padlock_lock').show();
		$('.padlock_unlock').hide();
	}
	else if (direction == 'positive' && padlock_numbers.turns[padlock_numbers.turns.length - 1] == 'negative' && 
				padlock_numbers.turns[padlock_numbers.turns.length - 2] == 'negative' && 
				padlock_numbers.digits.length == 0) {
		padlock_numbers.digits[0] = last_value;
		$('.padlock_light.blue').show();
		$('.padlock_digit.blue').html(last_value).show();
		padlock_numbers.sequence = [];
		padlock_numbers.diffs = [];
	}
	else if (direction == 'negative' && padlock_numbers.turns[padlock_numbers.turns.length - 1] == 'positive' && 
			padlock_numbers.turns[padlock_numbers.turns.length - 2] == 'negative' && 
			padlock_numbers.digits.length == 1) {
		padlock_numbers.digits[1] = last_value;
		$('.padlock_light.green').show();
		$('.padlock_digit.green').html(last_value).show();
		padlock_numbers.sequence = [];
		padlock_numbers.diffs = [];
	}
	else if (direction == 'positive' && 
		padlock_numbers.turns[padlock_numbers.turns.length - 1] == 'negative' && 
		padlock_numbers.digits.length == 2) {
		padlock_numbers.digits[2] = last_value;
		$('.padlock_light.red').show();
		$('.padlock_digit.red').html(last_value).show();
		padlock_numbers.sequence = [];
		padlock_numbers.diffs = [];
		padlockPull(j);
	}

	clearTimeout(padlock_numbers.reset);
	padlock_numbers.reset = setTimeout(function() {
		var timestamp = Date.now();
		if (timestamp > padlock_numbers.last_timestamp + 4999) {
			padlockReset(j);
			clearTimeout(padlock_numbers.reset);
		}
	},15000);
}
var padlockInterval;
padlockInterval = setInterval(function() {
	var timestamp = Date.now();
	if (!$('.wind[app="security"]').is('visible') || timestamp > padlock_numbers.last_timestamp + 69999) {
		clearInterval(padlockInterval);
		padlock_numbers.pulled = [];
		$('.padlock_light.yellow').hide();
	}
}, 5000);
function padlockReset(j) {
	var pulled = padlock_numbers.pulled;
	padlock_numbers = { 
		diffs: [], 
		turns: [], 
		sequence: [], 
		digits: [], 
		direction: '',
		last_timestamp: Date.now(), 
		reset: '',
		pulled: [],
		padlock: undefined
	};
	if (pulled.length > 0 && j.attr('mode') == 'security') {
		padlock_numbers.pulled = pulled;
		$('.padlock_light').hide();
		$('.padlock_digit').hide();
		$('.padlock_light.yellow').show();
	}
	else {
		$('.padlock_light').hide();
		$('.padlock_digit').hide();
		$('.padlock_lock').show();
		$('.padlock_unlock').hide();
	}
}
function padlockPull(j) {
	var timestamp = Date.now();
	var digits = JSON.stringify(padlock_numbers.digits);
	var mode = j.closest('.padlock_frame').attr('mode');
	if (padlock_numbers.pulled.length == 0) {
		$.ajax({
			url: '/manager/security/padlock_pull',
			type: 'POST',
			data: { timestamp: timestamp, digits: digits, mode: mode },
			success: function(response) {
				if (response.status == 'success') {
					$('.padlock_unlock').show();
					$('.padlock_lock').hide();
					$('.padlock_light.yellow').show();
					padlock_numbers.pulled = JSON.parse(response.pulled);
				}
				else {
					$('.padlock_lock').show();
					$('.padlock_unlock').hide();
				}
			}
		});
	}
}

$(document).on('mouseout touchend mouseup', '.padlock_jog_wheel', function() {
	padlock_last = 'out';
});

$(document).on('mousewheel', '.padlock_jog_wheel', function(e) {
	var j = $(this);
	var mvmt = numeral(e.originalEvent.wheelDelta).value();

	var diff = numeral(mvmt / 20).value() ;
	padlock_jw_deg = (padlock_jw_deg + diff);
	if (padlock_jw_deg > 360 || padlock_jw_deg < -360) {
		padlock_jw_deg = 0;
	}
	padlockPicker(j,diff,'mouse');
});


$(document).on('click', '#download_program', function() {
	var text = $(this).text();
	$(this).text('hold on...');
	var timestamp = Date.now();
	window.location='/download_program?timestamp=' + timestamp;
	$(this).text(text);
});

var vidControls = {};

// ---- theme ink: light text/icons when the background is dark -------------------
function jawnosInk() {
	var c = '';
	try { c = getComputedStyle(document.body).getPropertyValue('--ink'); } catch (e) { c = ''; }
	return (c && c.trim()) || '#000000';
}
// A colour that contrasts with the ink. Canvas art that is drawn over a user's
// background picture cannot trust the themed ink alone (a dark scheme gives
// near-white ink, which vanishes on a light photo), so it gets outlined with
// this instead.
function jawnosInkHalo(ink) {
	var hex = (ink || '#000000').replace('#', '');
	if (hex.length == 3) { hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]; }
	var n = parseInt(hex, 16);
	if (isNaN(n)) { n = 0; }
	var lum = (0.2126 * ((n >> 16) & 255) + 0.7152 * ((n >> 8) & 255) + 0.0722 * (n & 255)) / 255;
	return lum > 0.5 ? 'rgba(0,0,0,0.6)' : 'rgba(255,255,255,0.6)';
}
// Canvas text for the manager printers. The themed ink alone vanishes over a
// background picture, so when pictures are on the text is stroked with the
// contrasting halo first, then filled. Vertical centring is the default -
// the printers reason about marker rows, not baselines.
function jawnosPrinterText(ctx, text, x, y, opts) {
	opts = opts || {};
	ctx.save();
	if (opts.font) { ctx.font = opts.font; }
	if (opts.align) { ctx.textAlign = opts.align; }
	ctx.textBaseline = opts.baseline || 'middle';
	if (opts.alpha != null) { ctx.globalAlpha = opts.alpha; }
	if (opts.halo) {
		ctx.lineWidth = opts.haloWidth || 3;
		ctx.strokeStyle = opts.halo;
		ctx.strokeText('' + text, x, y);
	}
	ctx.fillStyle = opts.colour || jawnosInk();
	ctx.fillText('' + text, x, y);
	ctx.restore();
}
// The halo to draw under printer text, or undefined when no picture is up.
function jawnosPrinterHalo() {
	if (localStorage.getItem('background_images') == 'on' && typeof jawnosInkHalo == 'function') {
		return jawnosInkHalo(jawnosInk());
	}
	return undefined;
}
function jawnosRgbToHsl(r, g, b) {
	r /= 255; g /= 255; b /= 255;
	var max = Math.max(r, g, b), min = Math.min(r, g, b);
	var h = 0, s = 0, l = (max + min) / 2, d = max - min;
	if (d) {
		s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
		if (max === r) { h = (g - b) / d + (g < b ? 6 : 0); }
		else if (max === g) { h = (b - r) / d + 2; }
		else { h = (r - g) / d + 4; }
		h *= 60;
	}
	return [h, s, l];
}
function jawnosHslToHex(h, s, l) {
	h = ((h % 360) + 360) % 360;
	var c = (1 - Math.abs(2 * l - 1)) * s;
	var x = c * (1 - Math.abs(((h / 60) % 2) - 1));
	var m = l - c / 2;
	var r = 0, g = 0, b = 0;
	if (h < 60) { r = c; g = x; }
	else if (h < 120) { r = x; g = c; }
	else if (h < 180) { g = c; b = x; }
	else if (h < 240) { g = x; b = c; }
	else if (h < 300) { r = x; b = c; }
	else { r = c; b = x; }
	var part = function (v) { var p = Math.round((v + m) * 255).toString(16); return p.length < 2 ? '0' + p : p; };
	return '#' + part(r) + part(g) + part(b);
}
// Recompute the panel and ink variables from the page background so windows and
// text follow the active colour scheme. configure.js updates the body colour on a
// live scheme change and then calls this, so windows re-theme without a reload.
function jawnosApplyInk() {
	var bg = '';
	try { bg = getComputedStyle(document.body).backgroundColor || ''; } catch (e) { bg = ''; }
	var m = bg.match(/rgba?\(([^)]+)\)/);
	if (!m) { return; }
	var parts = m[1].split(',').map(function (x) { return parseFloat(x); });
	if (parts.length < 3) { return; }
	// a transparent body has no scheme colour to derive from; deriving one from
	// black would flip the ink to white and hide the canvas art
	if (parts.length >= 4 && parts[3] === 0) { return; }
	var r = parts[0], g = parts[1], b = parts[2];
	var lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
	var hsl = jawnosRgbToHsl(r, g, b);
	var tint = hsl[1] < 0.18 ? hsl[1] : 0.18;
	var panel, panel2, ink, ink_muted;
	if (lum < 0.5) {
		panel = jawnosHslToHex(hsl[0], tint, 0.16);
		panel2 = jawnosHslToHex(hsl[0], tint, 0.23);
		ink = '#f2f2f2'; ink_muted = '#cccccc';
	}
	else {
		panel = jawnosHslToHex(hsl[0], tint, 0.88);
		panel2 = jawnosHslToHex(hsl[0], tint, 0.80);
		ink = '#000000'; ink_muted = '#333333';
	}
	var style = document.body.style;
	style.setProperty('--panel', panel);
	style.setProperty('--panel-2', panel2);
	style.setProperty('--ink', ink);
	style.setProperty('--ink-muted', ink_muted);
	document.body.classList.toggle('dark_theme', lum < 0.5);
}
$(function () { jawnosApplyInk(); });

// ---- icon set swap: refresh the icons currently on screen ----------------------
// Called over the websocket after the pseudonym icon set changes; re-renders any
// open appointment windows and rebuilds the start-menu dock from their icons.
function jawnosReloadIcons() {
	try {
		// The desktop's own buttons were rendered with the old set, and only the
		// server knows where a path lives in the new one, so ask it for those
		// paths again and swap the sources.
		var nodes = $('[jawnos_icon]');
		if (nodes.length > 0) {
			var paths = [];
			nodes.each(function () {
				var p = $(this).attr('jawnos_icon');
				if (p && paths.indexOf(p) == -1) { paths.push(p); }
			});
			$.ajax({
				url: '/manager/icons',
				type: 'GET',
				data: { paths: JSON.stringify(paths) },
				success: function (response) {
					nodes.each(function () {
						var p = $(this).attr('jawnos_icon');
						if (response.icons && response.icons[p]) { $(this).attr('src', response.icons[p]); }
					});
				}
			});
		}
		$('.wind').each(function () {
			var app = $(this).attr('app');
			if (!app) { return; }
			if (typeof appWindowOpener === 'function') {
				appWindowOpener(app, Date.now(), { visible: 'yes' });
			}
			else if (typeof appointmentGrabber === 'function') {
				appointmentGrabber(app);
			}
		});
		// refresh an open start menu (passing `source` skips the close branch)
		if (typeof startMenuToggle === 'function' && $('#start_menu').is(':visible')) {
			startMenuToggle({ source: 'icon_refresh' });
		}
		if (typeof startMenuListify === 'function') { startMenuListify(); }
		if (typeof taskbarDisplayer === 'function') {
			setTimeout(function () { taskbarDisplayer(); }, 1200);
		}
	} catch (e) {}
}

// ---- icon hints: hover label on desktop, long-press label on touch ------------
// Any element with a `hint="..."` attribute shows a small floating label when
// hovered (pointer devices) or long-pressed (touch). Draggable elements are
// skipped on touch so a long press can start a drag instead.
var jawnos_hint_timer = null;
var jawnos_touch_hint_active = false;
function jawnosHintNode() {
	var h = document.getElementById('jawnos_hint');
	if (!h) {
		h = document.createElement('div');
		h.id = 'jawnos_hint';
		h.style.cssText = 'position:fixed;display:none;z-index:90000;background:rgba(0,0,0,0.86);color:#fff;padding:3px 8px;border-radius:6px;font-size:13px;line-height:1.3;max-width:260px;pointer-events:none;box-shadow:0 1px 4px rgba(0,0,0,0.4);white-space:nowrap;';
		document.body.appendChild(h);
	}
	return h;
}
function jawnosHintShow(el, x, y, gap) {
	var text = $(el).attr('hint');
	if (!text) { return; }
	if (gap == null) { gap = 12; }
	var h = jawnosHintNode();
	h.textContent = text;
	h.style.display = 'block';
	var w = h.offsetWidth, hh = h.offsetHeight;
	if (x == null) {
		var o = $(el).offset() || { left: 0, top: 0 };
		x = o.left + ($(el).width() / 2);
		y = o.top;
	}
	var left = Math.max(4, Math.min(x - (w / 2), $(window).width() - w - 4));
	var top = y - hh - gap;
	if (top < 4) { top = y + gap + 16; }
	h.style.left = left + 'px';
	h.style.top = top + 'px';
}
function jawnosHintHide() {
	var h = document.getElementById('jawnos_hint');
	if (h) { h.style.display = 'none'; }
}
var jawnos_click_killer = null;
var jawnos_killer_timer = null;
// for a moment after a long press, throw away the click the browser is about to
// deliver, so reading a hint does not also press the thing underneath it
function jawnosSuppressClick() {
	jawnosUnsuppressClick();
	jawnos_click_killer = function (e) { e.stopPropagation(); e.preventDefault(); jawnosUnsuppressClick(); };
	document.addEventListener('click', jawnos_click_killer, true);
	jawnos_killer_timer = setTimeout(jawnosUnsuppressClick, 700);
}
function jawnosUnsuppressClick() {
	if (jawnos_click_killer) {
		document.removeEventListener('click', jawnos_click_killer, true);
		jawnos_click_killer = null;
	}
	clearTimeout(jawnos_killer_timer);
	jawnos_killer_timer = null;
}

var jawnos_hover_capable = true;
try { jawnos_hover_capable = window.matchMedia('(hover: hover)').matches; } catch (e) {}

if (jawnos_hover_capable) {
	$(document).on('mouseenter', '[hint]', function () {
		if (jawnos_touch_hint_active) { return; }
		var el = this;
		clearTimeout(jawnos_hint_timer);
		// wait before showing so the label doesn't flash on every pass
		jawnos_hint_timer = setTimeout(function () {
			var m = mouse_position();
			jawnosHintShow(el, m.x, m.y);
		}, 1000);
	});
	$(document).on('mouseleave', '[hint]', function () {
		clearTimeout(jawnos_hint_timer);
		jawnosHintHide();
	});
	$(document).on('mousedown', function () { clearTimeout(jawnos_hint_timer); jawnosHintHide(); });
}

$(document).on('touchstart', '[hint]', function (e) {
	var el = this;
	if ($(el).hasClass('draggable') || $(el).closest('.draggable').length > 0) { return; }
	// the start menu rows wear their name already; a long press there must not
	// swallow the tap that would open the app
	if ($(el).closest('.start_menu_item').length > 0) { return; }
	// a fresh press owns its click, whatever the last long press left behind
	jawnosUnsuppressClick();
	var touch = e.originalEvent.touches && e.originalEvent.touches[0];
	if (!touch) { return; }
	var tx = touch.clientX, ty = touch.clientY;
	clearTimeout(jawnos_hint_timer);
	jawnos_hint_timer = setTimeout(function () {
		jawnos_touch_hint_active = true;
		jawnosHintShow(el, tx, ty, 30);
		jawnosSuppressClick();
	}, 500);
});
$(document).on('touchend touchcancel', function () {
	clearTimeout(jawnos_hint_timer);
	if (jawnos_touch_hint_active) {
		setTimeout(function () { jawnosHintHide(); jawnos_touch_hint_active = false; }, 1200);
	}
});
$(document).on('touchmove', function () {
	if (!jawnos_touch_hint_active) { clearTimeout(jawnos_hint_timer); }
});
