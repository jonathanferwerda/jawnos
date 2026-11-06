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

var jawnScreen = { call: '', timer: null, seen: 0 };

function jawnScreenPanelOpen() {
	if ($('#jawn_screening').length) { return; }
	// On the Phone app's own IVR pane the transcript is already on screen; a
	// second copy floating over it would only cover it.
	if ($('#phone_app .phone_app_pane[pane="ivr"]').is(':visible')) { return; }
	var box = $('<div id="jawn_screening" class="jawn_screening"></div>');
	box.append($('<div class="jawn_screening_head"></div>')
		.append($('<span class="jawn_screening_title"></span>').text(jawnosT('Screened call')))
		.append($('<button class="jawn_screening_close" hint="Dismiss">&times;</button>')));
	box.append($('<div class="jawn_screening_peer" id="jawn_screening_peer"></div>'));
	box.append($('<div class="jawn_screening_lines" id="jawn_screening_lines"></div>'));
	box.append($('<div class="jawn_screening_note" id="jawn_screening_note"></div>'));
	box.append($('<div class="jawn_screening_buttons"></div>')
		.append($('<button id="jawn_screening_connect" hint="Connect me">Connect me</button>'))
		.append($('<button id="jawn_screening_phone" hint="Open the Phone app">Open Phone</button>')));
	$('body').append(box);
}

function jawnScreenPanelClose() {
	$('#jawn_screening').remove();
	jawnScreen = { call: '', timer: null, seen: 0 };
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
			// A window opened or reloaded while the line is up never sees the
			// start push; the poll is what puts the panel there. An armed gateway
			// is not a screening, so it opens nothing by itself.
			if (!$('#jawn_screening').length) {
				if (state !== 'in_call' && state !== 'done') { return; }
				jawnScreenPanelOpen();
				// the Phone app's IVR pane is showing it instead
				if (!$('#jawn_screening').length) { return; }
			}
			if (!jawnScreen.timer) { jawnScreen.timer = setInterval(jawnScreenPoll, 1500); }
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

$(document).on('click', '#jawn_screening #jawn_screening_phone', function (e) {
	e.preventDefault();
	window.location.href = '/manager/phone?connect=me';
});

$(document).on('click', '#jawn_screening .jawn_screening_close', function (e) {
	e.preventDefault();
	jawnScreenEnd();
});

// A page that loads during a screening asks once, so a late window is not blind
// until the next call.
$(function () {
	if (typeof jawnScreenPoll === 'function') { jawnScreenPoll(); }
});
