// The Phone app. Recent calls are the appointments whose subtype is 'phone';
// contacts are the house's known phone numbers; the dial pad places a call on a
// phone through /manager/phone/dial (termux-telephony-call). In the app it also
// reads the device's own contacts and live call state from window.JawnContacts.
var jawnPhoneApp = { number: '' };

function jawnPhoneAppStatus(text) {
	$('#phone_app #phone_app_status').text(text || 'Idle');
}

// A millisecond count (the stored duration may be negative) to "3m 12s".
function jawnPhoneAppHuman(ms) {
	ms = Math.abs(Number(ms || 0));
	if (!ms) return '';
	var s = Math.floor(ms / 1000);
	var m = Math.floor(s / 60); s %= 60;
	var h = Math.floor(m / 60); m %= 60;
	if (h) return h + 'h ' + m + 'm';
	if (m) return m + 'm ' + s + 's';
	return s + 's';
}

// Fill in each recent row's duration beside its clock time.
function jawnPhoneAppRender() {
	$('#phone_app .phone_app_row[app]').each(function () {
		var sub = $(this).find('.phone_app_sub');
		var d = sub.attr('duration');
		if (d) {
			var dur = jawnPhoneAppHuman(d);
			if (dur) sub.text(sub.text() + ' · ' + dur);
		}
	});
}

$(document).on('click', '#phone_toggle', function () {
	$.ajax({
		url: '/manager/phone',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) { windowMaker(response); jawnPhoneAppRender(); jawnPhoneAppArm(); }
	});
});

// tab switching
$(document).on('click', '#phone_app .phone_app_tab', function () {
	$('#phone_app .phone_app_tab').removeClass('on');
	$(this).addClass('on');
	var pane = $(this).attr('pane');
	$('#phone_app .phone_app_pane').removeClass('on');
	$('#phone_app .phone_app_pane[pane="' + pane + '"]').addClass('on');
});

// dial pad
$(document).on('click', '#phone_app .phone_app_key', function () {
	jawnPhoneApp.number += $(this).attr('key');
	$('#phone_app #phone_app_display').text(jawnPhoneApp.number);
});
$(document).on('click', '#phone_app .phone_app_dial_btn', function () {
	var n = jawnPhoneApp.number;
	if (!n) { jawnPhoneAppStatus('Dial a number first.'); return; }
	jawnPhoneAppStatus('Calling ' + n + '…');
	$.ajax({
		url: '/manager/phone/dial',
		type: 'POST',
		data: { number: n, timestamp: Date.now() },
		success: function (res) {
			if (res && res.ok) {
				jawnPhoneApp.number = '';
				$('#phone_app #phone_app_display').text('');
				jawnPhoneAppStatus('Calling ' + n + '…');
			} else {
				jawnPhoneAppStatus((res && res.error) || 'Could not dial.');
			}
		},
		error: function () { jawnPhoneAppStatus('Could not dial.'); }
	});
});

// a contact tap fills the dial pad; a recent tap opens the caller's own thread
$(document).on('click', '#phone_app .phone_app_row', function () {
	var number = $(this).attr('number');
	var app = $(this).attr('app');
	if (number) {
		jawnPhoneApp.number = number;
		$('#phone_app #phone_app_display').text(number);
		$('#phone_app .phone_app_tab[pane="dial"]').trigger('click');
	} else if (app && typeof appointmentGrabber === 'function') {
		appointmentGrabber(app, Date.now());
	}
});

// ---- native (window.JawnContacts) ----------------------------------------
// Ask for the contact/call permissions, and replace the server's contact list
// with the device's own once they are granted. Live call state lands here too,
// so the status line reads Ringing / On a call / Idle as the phone does.
function jawnPhoneAppArm() {
	if (!window.JawnContacts || typeof window.JawnContacts.available !== 'function') { return; }
	if (window.JawnContacts.available() !== 'yes') {
		try { window.JawnContacts.request(); } catch (e) { }
	}
	window.__jawnContactsEvent = function (type, payload) {
		if (type === 'permission' && payload && payload.granted) { jawnPhoneAppNativeContacts(); }
	};
	window.__jawnPhoneEvent = function (type, payload) {
		if (type !== 'state') return;
		var state = payload && payload.state;
		if (state === 'RINGING') jawnPhoneAppStatus('Incoming call…');
		else if (state === 'OFFHOOK') jawnPhoneAppStatus('On a call');
		else jawnPhoneAppStatus('Idle');
	};
}

function jawnPhoneAppNativeContacts() {
	if (!window.JawnContacts || typeof window.JawnContacts.list !== 'function') return;
	try {
		var data = JSON.parse(window.JawnContacts.list(''));
		if (!data || !data.contacts || !data.contacts.length) return;
		var pane = $('#phone_app .phone_app_pane[pane="contacts"]');
		var list = $('<div class="phone_app_list"></div>');
		$.each(data.contacts, function (i, c) {
			var number = (c.numbers && c.numbers[0] && c.numbers[0].number) || '';
			var row = $('<div class="phone_app_row"></div>').attr('number', number).attr('app', c.name || '');
			$('<span class="phone_app_avatar"></span>')
				.append($('<img>').attr('src', '/images/decipherable/phone.png')).appendTo(row);
			$('<span class="phone_app_name"></span>').text(c.name || '').appendTo(row);
			$('<span class="phone_app_sub"></span>').text(number).appendTo(row);
			list.append(row);
		});
		pane.find('.phone_app_list, .phone_app_empty').remove();
		pane.prepend(list);
	} catch (e) { }
}

$(document).ready(function () {
	if ($('#phone_app').length) { jawnPhoneAppRender(); jawnPhoneAppArm(); }
});
