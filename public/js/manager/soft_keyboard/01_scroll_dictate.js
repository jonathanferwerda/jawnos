function softKbScrollField(el) {
	if (!el) { return; }
	if (el.id == 'message' && $(el).closest('.chat_shell').length) { return; }
	setTimeout(function () {
		var dock = $('#jawn_soft_keyboard');
		if (!dock.is(':visible')) { return; }
		var h = dock.outerHeight() || 0;
		el.style.scrollMarginBottom = (h + 18) + 'px';
		el.style.scrollMarginTop = '18px';
		try { el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' }); }
		catch (err) { el.scrollIntoView(); }
	}, 30);
}

function softKbTitleUpdate() {
	var dock = $('#jawn_soft_keyboard');
	var mode = jawnSoftMode;
	// The layout's own name is not printed: the bar is for actions (the page
	// chips, the layout chooser, dictation, the vault), and the chosen layout
	// is already highlighted in the chooser. Only a page or a dictation state
	// needs a word here.
	var title = mode == 'calc' ? softKbLabel('Calculator')
		: (mode == 'symbols' ? softKbLabel('Special characters') : '');
	dock.find('.soft_kb_title').text(title);
}

function softKbModeSet(mode) {
	softKbMagnifyHide();
	if (jawnSoftNumeric && mode == 'letters') { mode = 'calc'; }
	jawnSoftMode = mode;
	var dock = $('#jawn_soft_keyboard');
	dock.find('.soft_kb_mode').removeClass('active').filter('[data-kb_mode="' + mode + '"]').addClass('active');
	dock.find('.soft_kb_panel').prop('hidden', true).filter('[data-kb_panel="' + mode + '"]').prop('hidden', false);
	dock.find('.soft_kb_mode[data-kb_mode="letters"]').prop('hidden', jawnSoftNumeric);
	if (mode == 'letters') { softKbLayoutRender(); }
	if (!jawnSoftListening) { softKbTitleUpdate(); }
	if (mode == 'calc') { softKbCalcRender(); softKbHistoryRender(); }
	softKbConvertUpdate();
	softKbReserve();
	if (jawnSoftField) { softKbScrollField(jawnSoftField); }
}

function softKbShiftSet(on) {
	jawnSoftShift = !!on;
	softKbLayoutRender();
}

// ---- dictation -------------------------------------------------------------
// The microphone beside the hide key records a phrase and hands the audio to
// the house's own transcription: whisper.cpp on this machine, or the cloud
// model chosen for the transcription role. A phrase ends by itself when the
// room falls quiet, and the next recording starts at once so talking continues
// while the last phrase is transcribed. The Guide's model then restores
// punctuation without changing a word. Nothing goes to a browser or phone
// speech service.
var JAWN_DICTATE_SILENCE = 850;
var JAWN_DICTATE_MAX = 20000;
// ---- reading the room -------------------------------------------------------
// A laptop fan or a steady hiss sits above any fixed number that reads as
// silence, so a fixed threshold never hears the pause and a phrase runs to its
// cap. Instead the room is read from the microphone itself: a fan or a hiss is
// steady, a voice is not, so a short window that wobbles is speech and the
// room already known is kept. The floor that window yields is what a phrase is
// measured against - the pause sits a margin above it, and speech has to clear
// a wider margin to start, so the room's own jitter does not read as a word.
// The keyboard's dictation and the Guide's spoken conversation share this one
// reader, so both hear the same room the same way.
var JAWN_ROOM_FALLBACK = 0.02; // until a room has been read
var JAWN_ROOM_MARGIN = 0.015;  // the pause sits at least this far above the room
var JAWN_ROOM_SCALE = 0.5;     // ... and half the room's own level, so a loud room scales
var JAWN_ROOM_ONSET_SCALE = 1.5; // speech clears a wider margin than the pause
var JAWN_ROOM_ONSET_FRAMES = 3;  // loud ticks before a phrase is taken to have begun
var JAWN_ROOM_READ_FRAMES = 5;   // the room is read over half a second at a phrase's start
var JAWN_ROOM_CV = 0.4;          // a window spread above this is speech, not the room
var JAWN_ROOM_PEAK_RATIO = 3.5;  // a pause is this far under the phrase's own peak
var JAWN_ROOM_LEARN_RATIO = 2.5; // a window this much louder than the room is speech
var jawnRoom = { floor: 0 };

var jawnDictate = {
	stream: null,
	audio: null,
	analyser: null,
	data: null,
	recorder: null,
	meter: null,
	maxTimer: null,
	target: null,
	lang: 'auto',
	segments: [],
	sending: false,
	session: 0
};

var jawnDictateFieldButton = null;

function softKbDictateHint(text) {
	$('#jawn_soft_keyboard .soft_kb_title').text(text || '');
	// a rich editor's microphone is not in the dock, so the state it shows has to
	// travel to the button that started it
	$('.text_editor_container .text_editor_dictate').each(function () {
		var box = $(this).closest('.text_editor_container').find('.text_editor')[0];
		if (box && jawnDictate.target === box) { $(this).attr('title', text || ''); }
	});
	if (!jawnDictate.target && jawnDictateFieldButton && jawnDictateFieldButton.length) {
		jawnDictateFieldButton.attr('title', text || '');
	}
	// with the dock closed there is no title to read, so a failure has to be said
	// out loud; the progress words are not failures
	var progress = (text == softKbLabel('Listening…') || text == softKbLabel('Transcribing…') || !text);
	if (!progress && !softKbVisible() && typeof jawnosAlert === 'function') { jawnosAlert(text); }
}

function softKbDictateErrorText(code) {
	if (code == 'no-audio') { return softKbLabel('I did not catch any audio'); }
	if (code == 'unreadable') { return softKbLabel('I could not make out any words'); }
	if (code == 'no-model') { return softKbLabel('No transcription is set up on this machine'); }
	if (code == 'words') { return softKbLabel('I could not punctuate that'); }
	return softKbLabel('I could not transcribe that');
}

function softKbMicState() {
	var on = !!jawnSoftListening;
	$('#soft_kb_mic_button')
		.toggleClass('active soft_kb_mic_listening', on)
		.attr('aria-pressed', on ? 'true' : 'false')
		.attr('aria-label', softKbLabel(on ? 'Stop dictation' : 'Start dictation'))
		.attr('hint', softKbLabel(on ? 'Stop dictation' : 'Start dictation'));
	// the same dictation can be started from a rich text editor's toolbox
	$('.text_editor_container .text_editor_dictate').each(function () {
		var btn = $(this);
		var box = btn.closest('.text_editor_container').find('.text_editor')[0];
		var live = on && jawnDictate.target && box === jawnDictate.target;
		btn.toggleClass('active', !!live).attr('aria-pressed', live ? 'true' : 'false');
		btn.attr('aria-label', softKbLabel(live ? 'Stop dictation' : 'Start dictation'));
	});
}

// The level a phrase must cross to start (onset) or fall back under to end
// (quiet): the room's own level plus a margin.
function jawnRoomThreshold(onset) {
	var floor = jawnRoom.floor || JAWN_ROOM_FALLBACK;
	var margin = floor * JAWN_ROOM_SCALE;
	if (margin < JAWN_ROOM_MARGIN) { margin = JAWN_ROOM_MARGIN; }
	if (onset) { margin *= JAWN_ROOM_ONSET_SCALE; }
	return floor + margin;
}

// The room's own level from a short window of ticks: its mean when the window is
// steady, or null when it wobbles like a voice. The spread is taken from the
// same window, so a quiet room's floor is not thrown by a little jitter.
function jawnRoomRead(win) {
	var n = win.length, sum = 0, i;
	for (i = 0; i < n; i++) { sum += win[i]; }
	var mean = sum / n;
	if (!mean) { return 0; }
	var spread = 0;
	for (i = 0; i < n; i++) { var d = win[i] - mean; spread += d * d; }
	if (Math.sqrt(spread / n) / mean > JAWN_ROOM_CV) { return null; }
	return mean;
}

// Learn the room from a read window. With no room yet, a steady window is the
// room; a wobbling window is taken at its median for a conversation (whose
// first window, just after Converse is pressed, is clean) and at its quietest
// tick for dictation (whose first phrase may already contain speech). Once a
// room is known, a window only replaces it when it is not much louder: a voice,
// or the guide's own reply, must not drag the floor up.
function jawnRoomLearn(win, trust_wobble) {
	var n = win.length, i, sum = 0;
	for (i = 0; i < n; i++) { sum += win[i]; }
	var mean = sum / n;
	if (!jawnRoom.floor) {
		var steady = jawnRoomRead(win);
		if (steady != null && steady > 0) { jawnRoom.floor = steady; return; }
		var pick;
		if (trust_wobble) {
			var sorted = win.slice().sort(function (a, b) { return a - b; });
			pick = sorted[Math.floor(sorted.length / 2)];
		}
		else {
			pick = win[0];
			for (i = 1; i < n; i++) { if (win[i] < pick) { pick = win[i]; } }
		}
		jawnRoom.floor = pick || 0;
		return;
	}
	if (mean > 0 && mean <= jawnRoom.floor * JAWN_ROOM_LEARN_RATIO) { jawnRoom.floor = mean; }
}

// A new session reads its own room: the machine may have been carried
// somewhere louder since the last one.
function jawnRoomReset() { jawnRoom.floor = 0; }

function softKbDictateCut() {
	if (jawnDictate.meter) { clearInterval(jawnDictate.meter); jawnDictate.meter = null; }
	if (jawnDictate.maxTimer) { clearTimeout(jawnDictate.maxTimer); jawnDictate.maxTimer = null; }
	var rec = jawnDictate.recorder;
	jawnDictate.recorder = null;
	if (rec && rec.state != 'inactive') { try { rec.stop(); } catch (err) {} }
}

function softKbDictateRelease() {
	if (jawnDictate.stream) {
		jawnDictate.stream.getTracks().forEach(function (t) { try { t.stop(); } catch (err) {} });
		jawnDictate.stream = null;
	}
	if (jawnDictate.audio) {
		try { jawnDictate.audio.close(); } catch (err) {}
		jawnDictate.audio = null;
	}
	jawnDictate.analyser = null;
	jawnDictate.data = null;
}

function softKbDictateStop() {
	jawnSoftListening = false;
	jawnDictate.session++;
	softKbDictateCut();
	softKbDictateRelease();
	jawnDictate.target = null;
	softKbMicState();
	if (!jawnDictate.sending && !jawnDictate.segments.length) { softKbTitleUpdate(); }
}

function softKbDictateUnavailable() {
	jawnSoftListening = false;
	jawnDictate.session++;
	softKbDictateCut();
	softKbDictateRelease();
	softKbMicState();
	softKbDictateHint(softKbLabel('Dictation is not available in this browser'));
}

function softKbDictateMime() {
	if (!window.MediaRecorder || !MediaRecorder.isTypeSupported) { return ''; }
	var types = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/mp4'];
	try {
		for (var i = 0; i < types.length; i++) {
			if (MediaRecorder.isTypeSupported(types[i])) { return types[i]; }
		}
	}
	catch (err) { return ''; }
	return '';
}

// One phrase. The recorder is replaced only after the last one has really
// stopped, so a phrase can never be captured twice by two live recorders.
function softKbDictateSegment() {
	if (!jawnSoftListening || !jawnDictate.stream || jawnDictate.recorder) { return; }
	var mime = softKbDictateMime();
	var rec;
	try {
		rec = mime ? new MediaRecorder(jawnDictate.stream, { mimeType: mime }) : new MediaRecorder(jawnDictate.stream);
	}
	catch (err) {
		try { rec = new MediaRecorder(jawnDictate.stream); }
		catch (err2) { softKbDictateUnavailable(); return; }
	}
	var seg = { chunks: [], heard: false, run: 0, quiet: 0, peak: 0, read: JAWN_ROOM_READ_FRAMES, win: [], target: jawnDictate.target, mime: mime || rec.mimeType || 'audio/webm' };
	jawnDictate.recorder = rec;
	rec.ondataavailable = function (e) { if (e.data && e.data.size) { seg.chunks.push(e.data); } };
	rec.onstop = function () {
		if (jawnDictate.recorder === rec) { jawnDictate.recorder = null; }
		if (seg.heard && seg.chunks.length) {
			var blob = new Blob(seg.chunks, { type: seg.mime });
			if (blob.size > 1200) {
				jawnDictate.segments.push({ blob: blob, target: seg.target });
				softKbDictateQueue();
			}
		}
		if (jawnSoftListening) { setTimeout(function () { softKbDictateSegment(); }, 0); }
	};
	try { rec.start(250); }
	catch (err) { jawnDictate.recorder = null; softKbDictateUnavailable(); return; }
	if (jawnDictate.analyser) {
		jawnDictate.meter = setInterval(function () {
			if (!jawnDictate.analyser) { return; }
			jawnDictate.analyser.getByteTimeDomainData(jawnDictate.data);
			var rms = 0;
			for (var i = 0; i < jawnDictate.data.length; i++) {
				var d = (jawnDictate.data[i] - 128) / 128;
				rms += d * d;
			}
			rms = Math.sqrt(rms / jawnDictate.data.length);
			// a phrase opens by reading the room, before any of it is judged. The
			// audio is already being recorded, so nothing said in this moment is lost.
			if (seg.read > 0) {
				seg.win.push(rms);
				if (--seg.read === 0) { jawnRoomLearn(seg.win); }
				return;
			}
			var loud = (rms > jawnRoomThreshold(true));
			var quiet = (rms <= jawnRoomThreshold(false));
			if (!seg.heard) {
				// one loud tick is the room or a tap, so speech has to hold before the
				// phrase is taken to have started
				if (!loud) { seg.run = 0; return; }
				if (++seg.run < JAWN_ROOM_ONSET_FRAMES) { return; }
				seg.heard = true;
				seg.run = 0;
				seg.quiet = 0;
				seg.peak = rms;
				return;
			}
			// the pause is measured against the room read before the phrase, and
			// against the phrase's own peak when that room reads high or low
			if (rms > seg.peak) { seg.peak = rms; }
			var hushed = (seg.peak > JAWN_ROOM_FALLBACK && rms * JAWN_ROOM_PEAK_RATIO < seg.peak);
			if (!quiet && !hushed) { seg.quiet = 0; return; }
			if (!seg.quiet) { seg.quiet = Date.now(); return; }
			if (Date.now() - seg.quiet > JAWN_DICTATE_SILENCE) { softKbDictateFinishSegment(rec); }
		}, 100);
	}
	jawnDictate.maxTimer = setTimeout(function () { softKbDictateFinishSegment(rec); }, JAWN_DICTATE_MAX);
}

function softKbDictateFinishSegment(rec) {
	if (!rec || rec.state == 'inactive') { return; }
	if (jawnDictate.meter) { clearInterval(jawnDictate.meter); jawnDictate.meter = null; }
	if (jawnDictate.maxTimer) { clearTimeout(jawnDictate.maxTimer); jawnDictate.maxTimer = null; }
	try { rec.stop(); } catch (err) {}
}

// Transcribe the finished phrases in the order they were spoken, while the next
// one is already being recorded.
function softKbDictateQueue() {
	if (jawnDictate.sending) { return; }
	var item = jawnDictate.segments.shift();
	if (!item) {
		if (jawnSoftListening) { softKbDictateHint(softKbLabel('Listening…')); }
		else { softKbTitleUpdate(); }
		return;
	}
	jawnDictate.sending = true;
	if (!jawnSoftListening) { softKbDictateHint(softKbLabel('Transcribing…')); }
	$.ajax({
		url: '/manager/dictate?lang=' + encodeURIComponent(jawnDictate.lang || 'auto'),
		type: 'POST',
		data: item.blob,
		processData: false,
		contentType: 'application/octet-stream',
		dataType: 'json',
		timeout: 120000,
		success: function (r) {
			jawnDictate.sending = false;
			if (r && r.text) {
				softKbDictationAppend(item.target, r.text);
				if (jawnSoftListening) { softKbDictateHint(softKbLabel('Listening…')); }
			}
			else if (r && r.error) { softKbDictateHint(softKbDictateErrorText(r.error)); }
			softKbDictateQueue();
		},
		error: function () {
			jawnDictate.sending = false;
			softKbDictateHint(softKbLabel('I could not transcribe that'));
			softKbDictateQueue();
		}
	});
}

// A dictation phrase joins the field where the microphone was opened, even if
// the person has moved on to another window while it was being transcribed.
function softKbDictationAppend(target, text) {
	text = String(text || '').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
	if (!text) { return; }
	// the input method has no field: the phrase joins the editor at the caret
	if (jawnSoftIme) {
		var ime_last = (jawnImeText || '').slice(-1);
		var ime_sep = (ime_last && !/\s/.test(ime_last) && !/^[,.;:!?)]/.test(text)) ? ' ' : '';
		softKbImeSend(ime_sep + text);
		return;
	}
	if (!target || !document.contains(target) || !softKbEditable(target)) { return; }
	var sep = '';
	if (!target.isContentEditable) {
		var caret = (target.selectionStart == null) ? (target.value || '').length : target.selectionStart;
		var before = (target.value || '').charAt(caret - 1);
		if (caret > 0 && before && !/\s/.test(before) && !/^[,.;:!?)]/.test(text)) { sep = ' '; }
	}
	else {
		var last = (target.textContent || '').slice(-1);
		if (last && !/\s/.test(last) && !/^[,.;:!?)]/.test(text)) { sep = ' '; }
	}
	softKbInsert(sep + text, target, true);
}

function softKbDictateToggle() {
	if (jawnSoftListening) { softKbDictateStop(); return; }
	if (!jawnSoftField && !jawnSoftIme) { softKbDictateHint(softKbLabel('Tap a field first')); return; }
	if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
		softKbDictateUnavailable();
		return;
	}
	softKbLayoutsToggle(false);
	jawnSoftListening = true;
	var session = ++jawnDictate.session;
	jawnDictate.target = jawnSoftIme ? null : jawnSoftField;
	jawnDictate.lang = String(softKbLayout().lang || 'auto').split('-')[0];
	softKbMicState();
	softKbDictateHint(softKbLabel('Listening…'));
	// the conversation's capture settings, so the one room floor both readers
	// share is measured on signals processed the same way
	var dictate_mic = navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: false } }).catch(function () {
		return navigator.mediaDevices.getUserMedia({ audio: true });
	});
	dictate_mic.then(function (stream) {
		if (!jawnSoftListening || session != jawnDictate.session) {
			stream.getTracks().forEach(function (t) { try { t.stop(); } catch (err) {} });
			return;
		}
		jawnDictate.stream = stream;
		// a session reads its own room: the machine may have been carried somewhere
		// louder since the last one
		jawnRoomReset();
		try {
			jawnDictate.audio = new (window.AudioContext || window.webkitAudioContext)();
			var src = jawnDictate.audio.createMediaStreamSource(stream);
			// the same high pass the Guide's conversation uses: a fan's low rumble
			// must not be the room either side of the shared floor
			var hp = jawnDictate.audio.createBiquadFilter();
			hp.type = 'highpass';
			hp.frequency.value = 180;
			src.connect(hp);
			jawnDictate.analyser = jawnDictate.audio.createAnalyser();
			jawnDictate.analyser.fftSize = 1024;
			jawnDictate.data = new Uint8Array(jawnDictate.analyser.fftSize);
			hp.connect(jawnDictate.analyser);
		}
		catch (err) { jawnDictate.analyser = null; jawnDictate.data = null; }
		softKbDictateSegment();
	}).catch(function () {
		if (session != jawnDictate.session) { return; }
		jawnSoftListening = false;
		softKbMicState();
		softKbDictateHint(softKbLabel('I could not reach the microphone'));
	});
}

// Dictation aimed at a rich text editor's contenteditable, from the microphone
// in its toolbox. It is the dock's own dictation: the editor becomes the field
// being typed in, and each phrase joins the words where the caret is.
function softKbDictateField(el) {
	if (!el) { return; }
	if (jawnSoftListening) { softKbDictateStop(); return; }
	jawnSoftField = el;
	jawnSoftNumeric = false;
	jawnSoftContext = softKbContext(el);
	jawnDictateFieldButton = $(el).closest('.text_editor_container').find('.text_editor_dictate');
	softKbDictateToggle();
}

$(document).on('pointerdown', '.text_editor_dictate', function (e) {
	if (e.button != null && e.button != 0) { return; }
	// keep the caret in the words: a focused button would make the phrase append
	e.preventDefault();
});

$(document).on('click', '.text_editor_dictate', function (e) {
	e.preventDefault();
	var box = $(this).closest('.text_editor_container').find('.text_editor')[0];
	if (box) { softKbDictateField(box); }
});

function softKbNotify(el) {
	if (!el) { return; }
	var fire = function () {
		$(el).trigger('input');
		// older fields listen on keyup rather than input (the search box, the
		// text editor); a harmless space code keeps their handlers in step
		$(el).trigger($.Event('keyup', { key: ' ', keyCode: 32 }));
		if (!el.isContentEditable) { return; }
		// The house's rich text editor keeps a source textarea beside its
		// contenteditable; copy the words across so the app's own save sees them.
		var source = el.getAttribute('source_id');
		if (source && $('#' + source).length) {
			$('#' + source).val($(el).text());
			$('#' + source).trigger('change');
		}
	};
	if (window.requestAnimationFrame) { requestAnimationFrame(fire); }
	else { setTimeout(fire, 0); }
	// A dictation phrase can arrive for a field that is no longer the one being
	// typed in; only the current field's conversion and suggestion rows follow it.
	if (el === jawnSoftField) {
		softKbConvertUpdate();
		softKbSuggestSync();
	}
}

// ---- the Android input method ---------------------------------------------
// window.JawnIme is the service's bridge. Every write asks it to report the
// editor's text back (imeText below) so the rows follow what the app holds, the
// same way a DOM field's input event does in the manager.
