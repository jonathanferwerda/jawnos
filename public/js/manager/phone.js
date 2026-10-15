// The Phone app. Recents are the appointments whose subtype is 'phone';
// contacts are the house's known phone numbers; the dial pad places a call on a
// phone through /manager/phone/dial (termux-telephony-call). In the app it also
// reads the device's own contacts and live call state from window.JawnContacts,
// and writes a call appointment as the call happens.
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

// ---- live calls -----------------------------------------------------------
// While the app is up, a ring starts a call appointment (on the caller's own
// app when the number is known - the Call screening role supplies it at ring -
// else the fallback 'phone' app), a hangup stops it and a miss cancels it. In a
// browser the bridge is absent, so nothing fires here and the house's own
// call-log poll backfills instead.
var jawnPhoneAppCall = { prev: 'idle', uuid: '' };

function jawnPhoneAppNumber() {
	try {
		if (window.JawnContacts && typeof window.JawnContacts.incomingNumber === 'function') {
			return window.JawnContacts.incomingNumber() || '';
		}
	} catch (e) { }
	return '';
}

function jawnPhoneAppCallStart(direction) {
	if (jawnPhoneAppCall.uuid) return;
	$.ajax({
		url: '/manager/phone/call',
		type: 'POST',
		data: { event: 'ring', number: jawnPhoneAppNumber(), direction: direction, timestamp: Date.now() },
		success: function (res) { if (res && res.ok) { jawnPhoneAppCall.uuid = res.uuid || ''; } }
	});
}

function jawnPhoneAppCallFinish(event) {
	var uuid = jawnPhoneAppCall.uuid;
	jawnPhoneAppCall.uuid = '';
	if (!uuid) return;
	$.ajax({ url: '/manager/phone/call', type: 'POST', data: { event: event, uuid: uuid, timestamp: Date.now() } });
}

function jawnPhoneAppOnState(state) {
	var prev = jawnPhoneAppCall.prev;
	if (state === 'RINGING') {
		jawnPhoneAppStatus('Incoming call…');
		if (prev !== 'RINGING') jawnPhoneAppCallStart('incoming');
	} else if (state === 'OFFHOOK') {
		jawnPhoneAppStatus('On a call');
		if (prev === 'idle') jawnPhoneAppCallStart('outgoing');
	} else {
		jawnPhoneAppStatus('Idle');
		if (prev === 'RINGING') jawnPhoneAppCallFinish('miss');
		else if (prev === 'OFFHOOK') jawnPhoneAppCallFinish('end');
	}
	jawnPhoneAppCall.prev = state;
}

// The native bridge pushes call state here (window.JawnContacts -> the app).
window.__jawnPhoneEvent = function (type, payload) {
	if (type !== 'state') return;
	jawnPhoneAppOnState(payload && payload.state);
};

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
function jawnPhoneAppArm() {
	if (!window.JawnContacts || typeof window.JawnContacts.available !== 'function') { return; }
	if (window.JawnContacts.available() !== 'yes') {
		try { window.JawnContacts.request(); } catch (e) { }
	}
	window.__jawnContactsEvent = function (type, payload) {
		if (type === 'permission' && payload && payload.granted) { jawnPhoneAppNativeContacts(); }
		if (type === 'screening') { jawnPhoneAppCallerId(); }
	};
	jawnPhoneAppCallerId();
}

// The Caller ID (call screening) role. Held, the app learns who is calling at
// ring; not held, the button asks for the role.
function jawnPhoneAppCallerId() {
	if (!window.JawnContacts || typeof window.JawnContacts.screeningRole !== 'function') { return; }
	var held = false;
	try { held = window.JawnContacts.screeningRole() === 'yes'; } catch (e) { }
	$('#phone_app .phone_app_callerid').toggle(!held);
	$('#phone_app .phone_app_callerid_state').text(held ? 'Caller ID is on' : '');
}
$(document).on('click', '#phone_app .phone_app_callerid', function () {
	if (window.JawnContacts && typeof window.JawnContacts.requestScreening === 'function') {
		window.JawnContacts.requestScreening();
	}
});

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
