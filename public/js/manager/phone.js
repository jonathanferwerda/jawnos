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
// The appointment itself is written from the app's own record of the call (see
// jawnPhoneAppFileCalls below): a call arrives whether or not a page is up, and
// the native side is the only half that sees every one of them. That is what
// this listener used to get wrong - it wrote the appointment itself, so a call
// taken with the app in the background was written nowhere. All it does now is
// say what is happening on screen.
// 'prev' holds the bridge's own vocabulary (IDLE/RINGING/OFFHOOK): the native
// side spells the states in capitals, so comparing against a lowercase 'idle'
// never matched.
var jawnPhoneAppCall = { prev: 'IDLE' };

function jawnPhoneAppNumber() {
	try {
		if (window.JawnContacts && typeof window.JawnContacts.incomingNumber === 'function') {
			return window.JawnContacts.incomingNumber() || '';
		}
	} catch (e) { }
	return '';
}

function jawnPhoneAppOnState(state) {
	state = (state || '').toUpperCase();
	if (state === 'RINGING') { jawnPhoneAppStatus('Incoming call…'); }
	else if (state === 'OFFHOOK') { jawnPhoneAppStatus('On a call'); }
	else { jawnPhoneAppStatus('Idle'); }
	jawnPhoneAppCall.prev = state;
}

// The calls the app recorded (window.JawnPhone.takeCalls) become appointments,
// one each. Run at page load, on every jawnPhoneSync, and the moment the native
// side says a call has finished - so a call that happened while the app was in
// the background lands as soon as there is a page to file it.
function jawnPhoneAppFileCalls(reload) {
	if (!window.JawnPhone || typeof window.JawnPhone.takeCalls !== 'function') { return; }
	var calls = [];
	try { calls = JSON.parse(window.JawnPhone.takeCalls()) || []; } catch (e) { calls = []; }
	if (!calls.length) { return; }
	var filed = 0;
	$.each(calls, function (i, c) {
		if (!c) { return; }
		$.ajax({
			url: '/manager/phone/call',
			type: 'POST',
			data: {
				timestamp: c.ended || Date.now(),
				event: 'log',
				number: c.number || '',
				direction: c.direction || 'incoming',
				started: c.started || 0,
				ended: c.ended || 0,
				answered: c.answered ? 'yes' : 'no'
			},
			success: function (res) {
				filed++;
				if (filed === calls.length && reload && $('#phone_app').length) { jawnPhoneAppReload('recent'); }
			}
		});
	});
}

// the native side nudges us here when a call ends (JawnInCallService)
window.__jawnPhoneCalls = function () { jawnPhoneAppFileCalls(true); };

// The native bridge pushes call state here (window.JawnContacts -> the app).
window.__jawnPhoneEvent = function (type, payload) {
	if (type !== 'state') return;
	jawnPhoneAppOnState(payload && payload.state);
};

// Pull the whole app again and land on a pane: after a block or an unblock the
// panes a number touches have all changed, and a reload of the window is what
// keeps every one of them honest.
function jawnPhoneAppReload(pane) {
	$.ajax({
		url: '/manager/phone',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) {
			windowMaker(response);
			jawnPhoneAppRender();
			jawnPhoneAppArm();
			if (pane) { $('#phone_app .phone_app_tab[pane="' + pane + '"]').trigger('click'); }
		}
	});
}

$(document).on('click', '#phone_toggle', function () {
	jawnPhoneAppReload();
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

// Block a recent call: the first press arms it, the second within two seconds
// does it - the house's two-press habit for anything that leaves a lasting rule
$(document).on('click', '#phone_app .phone_app_block', function (e) {
	e.stopPropagation();
	var b = $(this);
	if (b.attr('armed') !== 'yes') {
		b.attr('armed', 'yes');
		b.css({ 'background-color': 'red', 'border-radius': '50%', 'padding': '2px' });
		setTimeout(function () {
			b.css({ 'background-color': '', 'border-radius': '', 'padding': '' });
			b.attr('armed', 'no');
		}, 2000);
		jawnPhoneAppStatus('Press again to block');
		return;
	}
	b.attr('armed', 'no');
	b.css({ 'background-color': '', 'border-radius': '', 'padding': '' });
	var row = b.closest('.phone_app_row');
	var number = row.attr('number') || row.attr('app') || '';
	if (!number) { jawnPhoneAppStatus('No number to block.'); return; }
	$.ajax({
		url: '/manager/box_office/blacklist/number',
		type: 'POST',
		data: { timestamp: Date.now(), number: number, app: row.attr('app') || '', name: row.attr('app') || '' },
		success: function (res) {
			if (res && res.ok) {
				jawnPhoneAppStatus('Blocked ' + res.number);
				if (typeof jawnPhoneSync === 'function') { jawnPhoneSync(); }
				jawnPhoneAppReload('recent');
			} else {
				jawnPhoneAppStatus('Enter a number.');
			}
		},
		error: function () { jawnPhoneAppStatus('Could not block.'); }
	});
});

// Unblock: the same two presses. The number comes off the desk's list, so it
// rings again (and may ask for a ticket at the door again)
$(document).on('click', '#phone_app .phone_app_unblock', function (e) {
	e.stopPropagation();
	var b = $(this);
	if (b.attr('armed') !== 'yes') {
		b.attr('armed', 'yes');
		setTimeout(function () { b.attr('armed', 'no'); }, 2000);
		jawnPhoneAppStatus('Press again to unblock');
		return;
	}
	b.attr('armed', 'no');
	$.ajax({
		url: '/manager/box_office/blacklist/remove',
		type: 'POST',
		data: { timestamp: Date.now(), stamp: b.attr('stamp') },
		success: function () {
			jawnPhoneAppStatus('Unblocked ' + (b.attr('number') || ''));
			if (typeof jawnPhoneSync === 'function') { jawnPhoneSync(); }
			jawnPhoneAppReload('blocked');
		},
		error: function () { jawnPhoneAppStatus('Could not unblock.'); }
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
		var pane = $('#phone_app .phone_app_pane[pane="known"]');
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
	// a call that ended while the app was away is still waiting to be filed
	jawnPhoneAppFileCalls();
});
