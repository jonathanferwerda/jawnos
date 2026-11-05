// The Phone app. Recents are the appointments whose subtype is 'phone';
// contacts are the house's known phone numbers; the dial pad places a call on a
// phone through /manager/phone/dial (termux-telephony-call). In the app it also
// reads the device's own contacts and live call state from window.JawnContacts,
// and writes a call appointment as the call happens.
var jawnPhoneApp = { number: '' };

// The screening face's Connect me opens this page with ?connect=me. The page is
// the WebRTC peer, so all that is left here is to press the button once the
// gateway says a call is up. The query is stripped straight away: a reload must
// not silently connect a device again.
var jawnPhoneConnectMeWanted = /[?&]connect=me(?:&|$)/.test(window.location.search || '');
if (jawnPhoneConnectMeWanted) {
	try { window.history.replaceState({}, '', window.location.pathname); } catch (e) { }
}

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

// The phone icon on a recent opens the device's default dialer with the number
// already typed. The native JawnPhone bridge is the only half that can do that;
// on the desktop the house's own dial pad is the fallback.
$(document).on('click', '#phone_app .phone_app_row_call', function (e) {
	e.stopPropagation();
	var row = $(this).closest('.phone_app_row');
	var number = $(this).attr('number') || row.attr('number') || '';
	if (!number) { jawnPhoneAppStatus(jawnosT('No number to dial.')); return; }
	if (window.JawnPhone && typeof window.JawnPhone.dial === 'function') {
		window.JawnPhone.dial(number);
		jawnPhoneAppStatus(jawnosT('Opening dialer…'));
		return;
	}
	jawnPhoneApp.number = number;
	$('#phone_app #phone_app_display').text(number);
	$('#phone_app .phone_app_tab[pane="dial"]').trigger('click');
});

// The IVR pane's save: the settings are the phone's own setting rows, and the
// machine is the remote_machines signatorial (or IP) the gateway runs on.
$(document).on('click', '#phone_app #phone_ivr_save', function (e) {
	e.preventDefault();
	var status = $('#phone_app #phone_ivr_status');
	status.text(jawnosT('Saving…'));
	var flows = {};
	$('#phone_app .phone_app_ivr_flow').each(function() {
		flows[$(this).attr('bucket')] = $(this).val();
	});
	$.ajax({
		url: '/manager/phone/ivr',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			enabled: $('#phone_app #phone_ivr_enabled').is(':checked') ? 'yes' : 'no',
			machine: $('#phone_app #phone_ivr_machine').val() || '',
			voice: $('#phone_app #phone_ivr_voice').val() || '',
			bluetooth: $('#phone_app #phone_ivr_bluetooth').val() || '',
			greeting: $('#phone_app #phone_ivr_greeting').val() || '',
			prompt: $('#phone_app #phone_ivr_prompt').val() || '',
			voicemail: $('#phone_app #phone_ivr_voicemail').val() || '',
			thanks: $('#phone_app #phone_ivr_thanks').val() || '',
			flows: JSON.stringify(flows)
		},
		success: function (res) {
			if (res && res.ok) {
				status.text(jawnosT('IVR saved.'));
				if (typeof jawnPhoneSync === 'function') { jawnPhoneSync(); }
			} else {
				status.text(jawnosT('Could not save IVR.'));
			}
		},
		error: function () { status.text(jawnosT('Could not save IVR.')); }
	});
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

// a person may keep more than one line: each is its own tap, dialing that one,
// while the row around them still dials the first
$(document).on('click', '#phone_app .phone_app_line', function (e) {
	e.stopPropagation();
	var n = $(this).attr('dial');
	if (!n) { return; }
	jawnPhoneApp.number = n;
	$('#phone_app #phone_app_display').text(n);
	$('#phone_app .phone_app_tab[pane="dial"]').trigger('click');
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
	// Without the phone role the system dialer answers the call and the house
	// never sees it, so the reception cannot work until this is on.
	var dialer = 'yes';
	try { dialer = (window.JawnPhone && typeof window.JawnPhone.dialerRole === 'function') ? window.JawnPhone.dialerRole() : 'yes'; } catch (e) { }
	$('#phone_app .phone_app_dialer').toggle(dialer !== 'yes');
}
$(document).on('click', '#phone_app .phone_app_dialer', function () {
	if (window.JawnPhone && typeof window.JawnPhone.requestDialer === 'function') {
		try { window.JawnPhone.requestDialer(); } catch (e) { }
	}
});

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

// ---- call routing for one number ----------------------------------------
// A person or a number can answer differently from the rest of their bucket.
// The sheet is one number at a time: the resolved route is fetched when it
// opens, so "Follow the person" shows what the relationship would do.

function jawnPhoneRouteOpen(number, app) {
	var sheet = $('#phone_app #phone_route_sheet');
	if (!number) { return; }
	sheet.attr('number', number).attr('app', app || '');
	$('#phone_app #phone_route_who').text((app ? jawnPhoneRouteName(app) + ' · ' : '') + number);
	$('#phone_app #phone_route_note').text('');
	$('#phone_app #phone_route_status').text('');
	$('#phone_app .phone_route_choice').removeClass('on');
	sheet.show();
	$.ajax({
		url: '/manager/phone/route',
		type: 'GET',
		dataType: 'json',
		data: { number: number, timestamp: Date.now() },
		success: function (res) {
			if (!res) { return; }
			var flow = res.flow || 'ring';
			var pick = (res.source === 'number') ? flow : 'default';
			$('#phone_app .phone_route_choice[route="' + pick + '"]').addClass('on');
			var source = res.source || '';
			var note = 'Now: ' + flow;
			if (source === 'number') { note += ' — set for this number'; }
			else if (source === 'off') { note += ' — the reception flow is off'; }
			else if (source) { note += ' — from ' + source; }
			$('#phone_app #phone_route_note').text(note);
		}
	});
}

function jawnPhoneRouteName(app) {
	var formatted = $('.people_person_link[app="' + app + '"]').text();
	if (formatted) { return formatted; }
	return app.replace(/_/g, ' ');
}

$(document).on('click', '#phone_app .phone_app_row_route', function (e) {
	e.stopPropagation();
	var icon = $(this);
	var row = icon.closest('.phone_app_row');
	var number = icon.attr('number') || row.attr('number') || '';
	jawnPhoneRouteOpen(number, icon.attr('app') || row.attr('app') || '');
});

$(document).on('click', '#phone_app #phone_route_close', function () {
	$('#phone_app #phone_route_sheet').hide();
});

$(document).on('click', '#phone_app .phone_route_choice', function () {
	var sheet = $('#phone_app #phone_route_sheet');
	var flow = $(this).attr('route');
	var number = sheet.attr('number');
	$.ajax({
		url: '/manager/phone/route',
		type: 'POST',
		dataType: 'json',
		data: { number: number, flow: flow, timestamp: Date.now() },
		success: function (res) {
			if (!res || !res.ok) {
				$('#phone_app #phone_route_status').text('Could not save.');
				return;
			}
			$('#phone_app .phone_route_choice').removeClass('on');
			$('#phone_app .phone_route_choice[route="' + flow + '"]').addClass('on');
			$('#phone_app #phone_route_status').text('Saved.');
			var saved = (flow === 'default') ? '' : flow;
			$('#phone_app .phone_app_row_route').filter(function () {
				return $(this).attr('number') === number;
			}).attr('route', saved);
			if (typeof jawnPhoneSync === 'function') { jawnPhoneSync(); }
			var resolved = res.resolved || {};
			$('#phone_app #phone_route_note').text(resolved.flow ? ('Now: ' + resolved.flow) : '');
		},
		error: function () { $('#phone_app #phone_route_status').text('Could not save.'); }
	});
});

// ---- the gateway's own state, on the IVR pane ---------------------------

// ---- the caller's words, live, on the IVR pane -----------------------------
// The gateway pushes a line as the caller finishes it and the sentence being
// said as it is recognised, on the phone's websocket. The same lines are in
// /manager/sco/status, so a pane opened in the middle of a call fills in what it
// missed - the push is the fast path, never the only one.
var jawnPhoneTranscriptSeen = 0;
var jawnPhoneTranscriptCall = '';

function jawnPhoneTranscriptClear() {
	jawnPhoneTranscriptSeen = 0;
	$('#phone_app #phone_transcript_lines').empty();
}

function jawnPhoneTranscriptLine(line) {
	if (!line || !line.text) { return; }
	var box = $('#phone_app #phone_transcript_lines');
	if (!box.length) { return; }
	$('<div class="phone_transcript_bubble"></div>')
		.attr('who', line.who || 'caller')
		.text(line.text)
		.appendTo(box);
	jawnPhoneTranscriptSeen++;
	$('#phone_app #phone_transcript').prop('hidden', false);
	box.scrollTop(box[0].scrollHeight);
}

function jawnPhoneTranscriptPartial(text) {
	var box = $('#phone_app #phone_transcript_lines');
	if (!box.length) { return; }
	var partial = box.find('.phone_transcript_bubble.phone_transcript_partial');
	if (!text) { partial.remove(); return; }
	if (!partial.length) {
		partial = $('<div class="phone_transcript_bubble phone_transcript_partial"></div>').appendTo(box);
	}
	partial.text(text);
	$('#phone_app #phone_transcript').prop('hidden', false);
	box.scrollTop(box[0].scrollHeight);
}

// The poll repeats every two seconds; only the lines it has not drawn yet are
// added, and a new call starts the bubbles over.
function jawnPhoneTranscriptSync(callId, lines, partial, note) {
	if ((callId || '') !== jawnPhoneTranscriptCall) {
		// a new call (or none) is not the one this device was listening to
		if (jawnScreenRtc.pc) { jawnPhoneRtcStop(); }
		jawnPhoneTranscriptCall = callId || '';
		jawnPhoneTranscriptClear();
	}
	$.each((lines || []).slice(jawnPhoneTranscriptSeen), function (i, line) {
		jawnPhoneTranscriptLine(line);
	});
	jawnPhoneTranscriptPartial(partial || '');
	$('#phone_app #phone_transcript_note').text(note || '');
	$('#phone_app #phone_transcript').prop('hidden',
		!(jawnPhoneTranscriptSeen || partial) && !note);
}

// A push arrives from another window/machine; the pane only draws it when it is
// on the IVR tab, and the status poll fills in whatever came before it opened.
function jawnPhoneTranscriptPushed(data) {
	if (!data) { return; }
	if (data.call_id && jawnPhoneTranscriptCall && data.call_id !== jawnPhoneTranscriptCall) {
		jawnPhoneTranscriptCall = data.call_id;
		jawnPhoneTranscriptClear();
	}
	if (data.line) { jawnPhoneTranscriptLine(data.line); }
	else if (typeof data.partial === 'string') { jawnPhoneTranscriptPartial(data.partial); }
}

// ---- Connect me -----------------------------------------------------------
// The bridge itself lives in screening.js, which every page loads: the floating
// screening panel draws on any device, so the WebRTC peer cannot live only in
// the Phone app's script. These names are the pane's own handle on it.
function jawnPhoneRtcConnect() { jawnScreenRtcConnect(jawnPhoneTranscriptCall); }
function jawnPhoneRtcStop(notify) { jawnScreenRtcStop(notify); }

var jawnPhoneGatewayTimer = null;

function jawnPhoneGatewayPoll(on) {
	if (jawnPhoneGatewayTimer) {
		clearInterval(jawnPhoneGatewayTimer);
		jawnPhoneGatewayTimer = null;
	}
	if (on) { jawnPhoneGatewayTimer = setInterval(jawnPhoneGatewayState, 2000); }
}

function jawnPhoneGatewayState() {
	$.ajax({
		url: '/manager/sco/status',
		type: 'GET',
		dataType: 'json',
		data: { timestamp: Date.now() },
		success: function (res) {
			var state = (res && res.state) || 'unavailable';
			var label = 'Gateway: ' + state;
			if (res && res.helper === 0) { label = 'Gateway: the helper is not built on this machine'; }
			else if (state === 'in_call') { label = 'Gateway: a call is up'; }
			else if (state === 'armed') { label = 'Gateway: listening for the next call'; }
			// a 2.4 GHz connection shares the antenna with Bluetooth on a combo
			// card: the caller breaks up instead of anything failing loudly
			if (res && res.wifi === '2.4') {
				label = label + ' - ' + jawnosT('this machine is on 2.4 GHz WiFi, so the caller will break up');
			}
			$('#phone_app #phone_ivr_gateway_state').text(label);
			jawnPhoneTranscriptSync(res && res.call_id, res && res.transcript, res && res.partial, res && res.transcript_note);
			if (jawnPhoneConnectMeWanted && (state === 'in_call' || state === 'done')) {
				jawnPhoneConnectMeWanted = false;
				jawnPhoneRtcConnect();
			}
		},
		error: function () { $('#phone_app #phone_ivr_gateway_state').text('Gateway: not answering'); }
	});
}

$(document).on('click', '#phone_app .phone_app_tab', function () {
	var pane = $(this).attr('pane');
	jawnPhoneGatewayPoll(pane === 'ivr');
	if (pane === 'ivr') { jawnPhoneGatewayState(); }
});

$(document).on('click', '#phone_app #phone_ivr_arm', function (e) {
	e.preventDefault();
	var label = $('#phone_app #phone_ivr_gateway_state');
	label.text('Arming…');
	$.ajax({
		url: '/manager/sco/arm',
		type: 'POST',
		dataType: 'json',
		data: {
			timestamp: Date.now(),
			voice: $('#phone_app #phone_ivr_voice').val() || '',
			bluetooth: $('#phone_app #phone_ivr_bluetooth').val() || '',
			greeting: $('#phone_app #phone_ivr_greeting').val() || '',
			prompt: $('#phone_app #phone_ivr_prompt').val() || '',
			thanks: $('#phone_app #phone_ivr_thanks').val() || ''
		},
		success: function (res) {
			if (res && res.ok) { jawnPhoneGatewayState(); }
			else { label.text('Gateway: ' + ((res && res.error) || 'could not arm')); }
		},
		error: function () { label.text('Gateway: not answering'); }
	});
});

// A face button lands on the Phone app with a pane to open; without this the
// status poll only starts on an IVR-tab click, and the auto-connect above would
// never see a call.
$(function () {
	if (!jawnPhoneConnectMeWanted) { return; }
	setTimeout(function () {
		if ($('#phone_app').length) {
			$('#phone_app .phone_app_tab[pane="ivr"]').trigger('click');
		}
	}, 400);
});
