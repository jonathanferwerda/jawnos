// The screening, on every device that has the house open.
//
// A call the receptionist answers is carried by the gateway, so a person on the
// tablet or the laptop has no idea it is happening. The gateway pushes
// `sco_screen` on the tab channel when a screening starts and when it ends; this
// draws a small floating panel with the live transcript and the two ways in, and
// polls /manager/sco/status while it is up (the push may arrive on a page that
// has just woken, and the lines are in the status anyway).
//
// The WebRTC bridge lives here rather than in the Phone app's script because the
// panel has to work on a page that never opened the Phone app. The Phone pane's
// own button calls the same functions.

var jawnScreenRtc = { pc: null, stream: null, audio: null, call: '' };

function jawnScreenRtcSignal(data) {
	$.ajax({
		url: '/manager/sco/rtc',
		type: 'POST',
		dataType: 'json',
		data: data,
		error: function () { }
	});
}

function jawnScreenRtcButton(text, on) {
	$('#phone_app #phone_transcript_connect').text(text).toggleClass('on', !!on);
	$('#jawn_screening #jawn_screening_connect').text(text).toggleClass('on', !!on);
}

function jawnScreenRtcStop(notify) {
	var rtc = jawnScreenRtc;
	var was = !!rtc.pc;
	try { if (rtc.pc) rtc.pc.close(); } catch (e) { }
	try { if (rtc.stream) rtc.stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) { }
	try {
		if (rtc.audio) { rtc.audio.pause(); rtc.audio.srcObject = null; }
	} catch (e) { }
	jawnScreenRtc = { pc: null, stream: null, audio: null, call: '' };
	jawnScreenRtcButton('Connect me', false);
	if (was && notify !== false) { jawnScreenRtcSignal({ action: 'stop' }); }
}

function jawnScreenRtcConnect(callId) {
	if (jawnScreenRtc.pc) { jawnScreenRtcStop(); return; }
	if (!window.RTCPeerConnection || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
		$('#jawn_screening #jawn_screening_note').text(jawnosT('This window cannot carry the call.'));
		return;
	}
	jawnScreenRtcSignal({ action: 'start' });
	navigator.mediaDevices.getUserMedia({
		audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
	}).then(function (stream) {
		// no STUN: the house is on its tailnet, where the peers can reach each
		// other's own candidates, and a public relay would only add a hop
		var pc = new RTCPeerConnection({ iceServers: [] });
		jawnScreenRtc = { pc: pc, stream: stream, audio: null, call: callId || '' };
		stream.getTracks().forEach(function (track) { pc.addTrack(track, stream); });
		pc.ontrack = function (event) {
			var audio = jawnScreenRtc.audio || new Audio();
			jawnScreenRtc.audio = audio;
			audio.srcObject = event.streams[0];
			audio.autoplay = true;
			audio.play().catch(function () { });
		};
		pc.onicecandidate = function (event) {
			if (!event.candidate) { return; }
			var c = event.candidate;
			jawnScreenRtcSignal({
				action: 'signal',
				candidate: c.candidate,
				sdp_mid: c.sdpMid || '0',
				sdp_mline_index: c.sdpMLineIndex || 0
			});
		};
		return pc.createOffer().then(function (offer) {
			return pc.setLocalDescription(offer);
		}).then(function () {
			jawnScreenRtcSignal({
				action: 'signal',
				sdp: pc.localDescription.sdp,
				sdp_type: pc.localDescription.type
			});
			jawnScreenRtcButton('Disconnect this device', true);
		});
	}).catch(function (err) {
		jawnScreenRtcStop(false);
		jawnScreenRtcSignal({ action: 'stop' });
		$('#jawn_screening #jawn_screening_note').text(jawnosT('The microphone could not be opened.') + ' ' + err);
	});
}

function jawnScreenRtcPushed(data) {
	if (!data || !jawnScreenRtc.pc) { return; }
	var pc = jawnScreenRtc.pc;
	if (data.answer) {
		pc.setRemoteDescription({ type: data.sdp_type || 'answer', sdp: data.answer }).catch(function () { });
	}
	else if (data.ice && data.ice.candidate) {
		pc.addIceCandidate({
			candidate: data.ice.candidate,
			sdpMid: data.ice.sdpMid,
			sdpMLineIndex: data.ice.sdpMLineIndex
		}).catch(function () { });
	}
	else if (data.error) {
		$('#jawn_screening #jawn_screening_note').text(data.error);
	}
}

// ---- the floating panel ---------------------------------------------------

var jawnScreen = { call: '', timer: null, seen: 0, hidden: false, top: 0, last: null };

function jawnScreenPanelOpen() {
	if ($('#jawn_screening').length) { return; }
	// On the Phone app's own IVR pane the transcript is already on screen; a
	// second copy floating over it would only cover it.
	if ($('#phone_app .phone_app_pane[pane="ivr"]').is(':visible')) { return; }
	var box = $('<div id="jawn_screening" class="jawn_screening"></div>');
	box.append($('<div class="jawn_screening_head"></div>')
		.append($('<span class="jawn_screening_title"></span>').text(jawnosT('Screened call')))
		.append($('<button class="jawn_screening_close" hint="Hide"></button>').text(jawnosT('Hide'))));
	box.append($('<div class="jawn_screening_peer" id="jawn_screening_peer"></div>'));
	box.append($('<div class="jawn_screening_lines" id="jawn_screening_lines"></div>'));
	box.append($('<div class="jawn_screening_note" id="jawn_screening_note"></div>'));
	// The phone carrying the call has the app's own call screen (hang up,
	// speaker, WebRTC); a second Connect me here opened the Phone page over it
	// with its layout broken, and nobody needs both.
	var buttons = $('<div class="jawn_screening_buttons"></div>');
	if (!window.JawnPhone) {
		buttons.append($('<button id="jawn_screening_connect" hint="Connect me">Connect me</button>'));
	}
	buttons.append($('<button id="jawn_screening_phone" hint="Open the Phone app">Open Phone</button>'));
	box.append(buttons);
	// Type to a caller who is waiting: the gateway speaks it and the answer
	// arrives in the same transcript.
	box.append($('<div class="jawn_screening_say_row"></div>')
		.append($('<input type="text" id="jawn_screening_say" hint="Message the caller" maxlength="400" autocomplete="off">')
			.attr('placeholder', jawnosT('Message the caller')))
		.append($('<button id="jawn_screening_say_send" hint="Send"></button>').text(jawnosT('Send'))));
	$('body').append(box);
	// The panel hangs from the top edge, like the app's own screening face. The
	// taskbar offset is in the CSS; a dock on the top edge sits below it and is
	// tucked, so the bottom of its visible strip is where the panel must start.
	var top = jawnScreenTopOffset(box);
	jawnScreen.top = top;
	box.css('top', top + 'px');
	box.css('max-height', 'min(62vh, calc(100vh - ' + Math.ceil(top + 16) + 'px))');
}

// The top edge the panel hangs from: the CSS already clears a top taskbar, and
// a top dock's visible strip is measured here. The dock is #pseudonym_home; the
// old `#dock` lookup was the store's customer ribbon, which no Manager page has.
function jawnScreenTopOffset(box) {
	var top = parseFloat(box.css('top')) || 16;
	var dock = document.getElementById('pseudonym_home');
	if (dock && dock.getAttribute('position') === 'top') {
		var rect = dock.getBoundingClientRect();
		if (rect && rect.height) { top = Math.max(top, Math.ceil(rect.bottom) + 16); }
	}
	return top;
}

function jawnScreenPanelClose() {
	$('#jawn_screening').remove();
	$('#jawn_screening_pill').remove();
	jawnScreen = { call: '', timer: null, seen: 0, hidden: false, top: 0, last: null };
}

// Hide is a tuck, not an end: the panel folds into a pill on the same edge. A
// call this device is carrying over WebRTC keeps its audio - hiding is about
// the window, not the call - and a device that hid the panel is not asked to
// reopen it until the next screening.
function jawnScreenHide() {
	$('#jawn_screening').remove();
	jawnScreen.hidden = true;
	jawnScreenPillOpen();
}

function jawnScreenPillOpen() {
	if ($('#jawn_screening_pill').length) { return; }
	var pill = $('<button id="jawn_screening_pill" class="jawn_screening_pill" hint="Show the screened call"></button>');
	pill.css('top', (jawnScreen.top || 16) + 'px');
	$('body').append(pill);
	jawnScreenPillPaint();
}

function jawnScreenPillPaint() {
	var pill = $('#jawn_screening_pill');
	if (!pill.length) { return; }
	var res = jawnScreen.last || {};
	var caller = res.caller || {};
	var who = caller.name || caller.number || '';
	pill.text(who ? (jawnosT('Screened call') + ' \u00b7 ' + who) : jawnosT('Screened call'));
}

function jawnScreenShow() {
	jawnScreen.hidden = false;
	jawnScreenPanelOpen();
	if (jawnScreen.last) { jawnScreenPanelPaint(jawnScreen.last); }
	// the Phone app's IVR pane can own the view instead; then the pill stays,
	// because this person has not been given the panel back
	if ($('#jawn_screening').length) { $('#jawn_screening_pill').remove(); }
}

function jawnScreenPanelLine(line) {
	if (!line || !line.text) { return; }
	var box = $('#jawn_screening_lines');
	if (!box.length) { return; }
	$('<div class="jawn_screening_bubble"></div>')
		.attr('who', line.who || 'caller')
		.text(line.text)
		.appendTo(box);
	jawnScreen.seen++;
	box.scrollTop(box[0].scrollHeight);
}

function jawnScreenPanelPartial(text) {
	var box = $('#jawn_screening_lines');
	if (!box.length) { return; }
	var partial = box.find('.jawn_screening_bubble.jawn_screening_partial');
	if (!text) { partial.remove(); return; }
	if (!partial.length) {
		partial = $('<div class="jawn_screening_bubble jawn_screening_partial"></div>').appendTo(box);
	}
	partial.text(text);
	box.scrollTop(box[0].scrollHeight);
}

function jawnScreenPanelPaint(res) {
	if (!res || !$('#jawn_screening').length) { return; }
	var call = res.call_id || '';
	if (call && call !== jawnScreen.call) {
		jawnScreen.call = call;
		jawnScreen.seen = 0;
		$('#jawn_screening_lines').empty();
	}
	var lines = res.transcript || [];
	for (var i = jawnScreen.seen; i < lines.length; i++) { jawnScreenPanelLine(lines[i]); }
	jawnScreenPanelPartial(res.partial || '');
	var caller = res.caller || {};
	var who = caller.name || caller.number || '';
	$('#jawn_screening_peer').text(who
		? (jawnosT('Call from: ') + who)
		: (res.peer ? jawnosT('Caller line') + ': ' + res.peer : ''));
	$('#jawn_screening_note').text(res.transcript_note || '');
}

// The caller's number lives on the phone's bridge; a browser without the app
// has none, and the gateway keeps the last number it was told.
function jawnScreenCallerNumber() {
	try {
		if (window.JawnContacts && typeof window.JawnContacts.incomingNumber === 'function') {
			return window.JawnContacts.incomingNumber() || '';
		}
	} catch (e) { }
	return '';
}

function jawnScreenPoll() {
	$.ajax({
		url: '/manager/sco/status',
		type: 'GET',
		dataType: 'json',
		data: { timestamp: Date.now(), number: jawnScreenCallerNumber() },
		success: function (res) {
			var state = (res && res.state) || 'idle';
			if (state !== 'in_call' && state !== 'done' && state !== 'armed' && state !== 'waiting') {
				jawnScreenEnd();
				return;
			}
			var live = (state === 'in_call' || state === 'done');
			// An armed gateway is not a screening, so nothing hunts the screen for
			// one. A device that hid the panel keeps polling so the pill can name
			// the caller and go away when the line is free.
			if (!live && !$('#jawn_screening').length && !$('#jawn_screening_pill').length) { return; }
			jawnScreen.last = res;
			if (!jawnScreen.timer) { jawnScreen.timer = setInterval(jawnScreenPoll, 1500); }
			// A window opened, reloaded or woken while the line is up never saw the
			// start push; the poll is what puts the panel there. A hidden panel
			// stays hidden until the person takes it back from the pill.
			if (live && !jawnScreen.hidden && !$('#jawn_screening').length) {
				jawnScreenPanelOpen();
				// the Phone app's IVR pane is showing it instead
				if (!$('#jawn_screening').length) { return; }
			}
			if (jawnScreen.hidden) { jawnScreenPillPaint(); }
			jawnScreenPanelPaint(res);
		}
	});
}

function jawnScreenStart() {
	jawnScreenPoll();
}

function jawnScreenEnd() {
	if (jawnScreen.timer) { clearInterval(jawnScreen.timer); }
	if (jawnScreenRtc.pc) { jawnScreenRtcStop(); }
	jawnScreenPanelClose();
}

// The gateway's announcement: a screening began, or the line is free again.
function jawnScreenPushed(data) {
	if (!data) { return; }
	if (data.state === 'ended') { jawnScreenEnd(); return; }
	jawnScreenStart();
}

$(document).on('click', '#jawn_screening #jawn_screening_connect', function (e) {
	e.preventDefault();
	if (jawnScreenRtc.pc) { jawnScreenRtcStop(); } else { jawnScreenRtcConnect(jawnScreen.call); }
});

// One message, spoken by the gateway on the machine that has the voice.
$(document).on('click', '#jawn_screening_say_send', function (e) {
	e.preventDefault();
	var input = $('#jawn_screening_say');
	var text = (input.val() || '').replace(/^\s+|\s+$/g, '');
	if (!text) { return; }
	input.val('');
	$.ajax({
		url: '/manager/sco/say',
		type: 'POST',
		dataType: 'json',
		data: { timestamp: Date.now(), text: text },
		success: function (res) {
			if (!res || !res.ok) {
				$('#jawn_screening_note').text((res && res.error) || jawnosT('The message did not go through.'));
			}
		},
		error: function () { $('#jawn_screening_note').text(jawnosT('The message did not go through.')); }
	});
});

$(document).on('keydown', '#jawn_screening_say', function (e) {
	if (e.key !== 'Enter') { return; }
	e.preventDefault();
	$('#jawn_screening_say_send').trigger('click');
});

$(document).on('click', '#jawn_screening #jawn_screening_phone', function (e) {
	e.preventDefault();
	window.location.href = '/manager/phone?connect=me';
});

$(document).on('click', '#jawn_screening .jawn_screening_close', function (e) {
	e.preventDefault();
	jawnScreenHide();
});

$(document).on('click', '#jawn_screening_pill', function (e) {
	e.preventDefault();
	jawnScreenShow();
	jawnScreenPoll();
});

// A page that loads during a screening asks once, so a late window is not blind
// until the next call; a laptop that wakes asks again, because its socket was
// away when the screening was announced.
$(function () {
	if (typeof jawnScreenPoll === 'function') { jawnScreenPoll(); }
});

$(document).on('visibilitychange', function () {
	if (!document.hidden && typeof jawnScreenPoll === 'function') { jawnScreenPoll(); }
});
