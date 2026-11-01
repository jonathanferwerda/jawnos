// Play music or an episode by its name: ask the server (which runs the music
// app's own search) for every match, then open the music app on the list - a
// show plays through as a queue of episodes. The music app does the playing;
// the guide only has to name the thing.
function helpPlayMusic(query, cb, shuffle) {
	var q = $.trim(query || '');
	if (!q) { cb('I did not catch what to play.'); return; }
	$.get('/manager/help/music', { q: q, shuffle: shuffle ? 1 : 0 }, function (r) {
		if (!r || !r.found) { cb('I searched the library for “' + q + '” but found nothing to play.'); return; }
		if (typeof musicToggle !== 'function') { cb('The music app is not available here.'); return; }
		// every match rides along, so a show plays as a list of its episodes
		var list = (r.files && r.files.length) ? r.files : [r.file];
		musicToggle(list, r.same_order ? 1 : 0);
		if (list.length > 1) {
			cb('Playing ' + list.length + ' matches.', 'Now playing ' + list.length + ' matches.');
		}
		else {
			cb('Playing ' + r.title + '.', 'Now playing ' + r.title + '.');
		}
	}).fail(function () { cb('I could not reach the music library.'); });
}

// A message set to the Guide from outside this window: a clip the house heard
// and transcribed - from the watch, the t-deck, a board - or anything else
// addressed to the guide. It is put in the composer and asked exactly as if it
// had been typed here, so the Guide answers it in this conversation. The spoken
// half of the answer still goes back to the device (the server sends it), this
// is the Guide's own copy of the exchange.
function helpChatIngest(text) {
	var q = $.trim(text == null ? '' : String(text));
	if (!q) { return; }
	if (!$('.wind[app="help"] #help_question').length) { return; }	// no Guide window open
	$('#help_question').val(q);
	helpAsk();
}

function helpAsk() {
	var model = $('#help_model').val();
	var q = $.trim($('#help_question').val() || '');
	if (!model) {
		helpShowChat(true);
		helpChatAdd('step', 'Choose a model in the row above first — the guide needs one to think with.');
		return;
	}
	if (!q) {
		// an empty Send means "listen": record a clip, transcribe it, then ask
		helpListenToggle(function (text) { $('#help_question').val(text); helpAsk(); });
		return;
	}
	// the farewell is read first: "bye jawn" (or the End button) closes a
	// conversation. No wake phrase is needed to speak - opening the mic is the
	// whole of it.
	if (helpConversationBye(q)) { $('#help_question').val(''); if (jawnos_help_talking) { helpConversationEnd(); } return; }
	$('#help_question').val('');
	helpShowChat(true);
	jawnos_help_chat.push({ role: 'user', content: q });
	helpChatAdd('user', q);
	if (jawnos_help_coding) { helpCodingRun(q); return; }
	helpAgentStep(0);
}

// ---- speech in -----------------------------------------------------------
// One recorder, shared by the help window's guide and the associates: record a
// short clip from the browser, post the raw bytes and let the server's whisper
// pipeline turn it into words. In a conversation the clip ends itself once
// speech has been heard and the room falls quiet, so nobody has to press Stop
// between turns.
var jawn_clip = { recorder: null, chunks: [], pcm: [], pcm_rate: 0, listening: false, cb: null, discard: false, meter: null, maxtimer: null, audioctx: null, owner: null };

function jawnClipListening() { return jawn_clip.listening; }

function jawnClipCleanup() {
	if (jawn_clip.meter) { clearInterval(jawn_clip.meter); jawn_clip.meter = null; }
	if (jawn_clip.maxtimer) { clearTimeout(jawn_clip.maxtimer); jawn_clip.maxtimer = null; }
	if (jawn_clip.audioctx) { try { jawn_clip.audioctx.close(); } catch (e) {} jawn_clip.audioctx = null; }
}

// WebKit's MP4/AAC recorder reports support and then produces no data at all, so
// a type that actually writes (webm/ogg first) is preferred over the default.
function jawnClipMime() {
	if (!window.MediaRecorder || !MediaRecorder.isTypeSupported) { return ''; }
	var types = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/ogg', 'audio/mp4'];
	try {
		for (var i = 0; i < types.length; i++) {
			if (MediaRecorder.isTypeSupported(types[i])) { return types[i]; }
		}
	}
	catch (e) { return ''; }
	return '';
}

// The fallback clip: the samples the room reader already saw, written as a plain
// 16-bit mono WAV that ffmpeg (and so whisper) reads anywhere.
function jawnClipWavBlob(pcm, rate) {
	var n = 0, i, j;
	for (i = 0; i < pcm.length; i++) { n += pcm[i].length; }
	if (!n) { return new Blob([], { type: 'audio/wav' }); }
	rate = rate || 48000;
	var buf = new ArrayBuffer(44 + n * 2);
	var view = new DataView(buf);
	var put = function (off, s) { for (var k = 0; k < s.length; k++) { view.setUint8(off + k, s.charCodeAt(k)); } };
	put(0, 'RIFF');
	view.setUint32(4, 36 + n * 2, true);
	put(8, 'WAVE');
	put(12, 'fmt ');
	view.setUint32(16, 16, true);
	view.setUint16(20, 1, true);   // PCM
	view.setUint16(22, 1, true);   // mono
	view.setUint32(24, rate, true);
	view.setUint32(28, rate * 2, true);
	view.setUint16(32, 2, true);
	view.setUint16(34, 16, true);
	put(36, 'data');
	view.setUint32(40, n * 2, true);
	var off = 44;
	for (i = 0; i < pcm.length; i++) {
		var ch = pcm[i];
		for (j = 0; j < ch.length; j++) {
			var s = Math.max(-1, Math.min(1, ch[j]));
			view.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
			off += 2;
		}
	}
	return new Blob([buf], { type: 'audio/wav' });
}

// end the clip now, or throw it away (the silence watch and the cap call this)
function jawnClipStop(discard) {
	if (discard) { jawn_clip.discard = true; }
	// Silence the meter and the cap at once, but leave the audio context for
	// onstop: closing it before the recorder stops starves the clip of its last
	// chunk in WebKit, which sends an empty body.
	if (jawn_clip.meter) { clearInterval(jawn_clip.meter); jawn_clip.meter = null; }
	if (jawn_clip.maxtimer) { clearTimeout(jawn_clip.maxtimer); jawn_clip.maxtimer = null; }
	if (jawn_clip.recorder && jawn_clip.recorder.state !== 'inactive') {
		// ask for what is buffered before the stop: an engine that only hands
		// data over on its own schedule still gives the clip a last chunk
		try { if (jawn_clip.recorder.requestData) { jawn_clip.recorder.requestData(); } } catch (e) {}
		jawn_clip.recorder.stop();
	}
	else { jawnClipCleanup(); }
}

// opts: { talking, owner, onText(text), onFail(reason), status(msg), onstart, onend }
function jawnClipListen(opts) {
	opts = opts || {};
	if (jawn_clip.listening) { return false; }
	if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
		if (opts.status) { opts.status('This device has no microphone I can reach.'); }
		if (opts.onFail) { opts.onFail('no microphone'); }
		return false;
	}
	// A level-based end-of-turn reader needs the room as it really is. Auto gain
	// lifts a laptop fan or a steady hiss up to speech level (a floor read at
	// 0.29 with the room at 0.4 is a room compressed nearly to full scale), and
	// noise suppression pumps as it gates. Echo cancellation is kept so the
	// guide's own spoken answer does not loop back as the person's turn.
	var mic = navigator.mediaDevices.getUserMedia({ audio: {
		echoCancellation: true,
		noiseSuppression: false,
		autoGainControl: false
	} }).catch(function () {
		// an engine that refuses the processing hints still gets a plain stream
		return navigator.mediaDevices.getUserMedia({ audio: true });
	});
	mic.then(function (stream) {
		// what the engine actually granted, in the same debug switch the room uses
		try {
			if (localStorage.getItem('jawn_room_debug') == 'on') {
				var mic_track = stream.getAudioTracks ? stream.getAudioTracks()[0] : null;
				var mic_settings = (mic_track && mic_track.getSettings) ? mic_track.getSettings() : {};
				console.log('[mic] ' + JSON.stringify(mic_settings));
			}
		} catch (e) {}
		jawn_clip.chunks = [];
		jawn_clip.pcm = [];
		jawn_clip.pcm_rate = 0;

		// One audio graph serves both readers: an analyser for the room (with a
		// fan's low rumble taken off) and a PCM tap that can stand in for the
		// recorder when the engine writes nothing. The tap is muted, never played.
		var an = null;
		try {
			var ctx = new (window.AudioContext || window.webkitAudioContext)();
			var src = ctx.createMediaStreamSource(stream);
			var hp = ctx.createBiquadFilter();
			hp.type = 'highpass';
			hp.frequency.value = 180;
			src.connect(hp);
			an = ctx.createAnalyser();
			an.fftSize = 1024;
			hp.connect(an);
			var mk = ctx.createScriptProcessor || ctx.createJavaScriptNode;
			if (mk) {
				var pcm_node = mk.call(ctx, 4096, 1, 1);
				jawn_clip.pcm_rate = ctx.sampleRate || 48000;
				pcm_node.onaudioprocess = function (e) {
					if (!jawn_clip.listening || !jawn_clip.pcm) { return; }
					var ch = e.inputBuffer.getChannelData(0);
					try { jawn_clip.pcm.push(ch.slice()); }
					catch (err) {
						var copy = new Float32Array(ch.length);
						copy.set(ch);
						jawn_clip.pcm.push(copy);
					}
				};
				var mute = ctx.createGain();
				mute.gain.value = 0;
				hp.connect(pcm_node);
				pcm_node.connect(mute);
				mute.connect(ctx.destination);
			}
			jawn_clip.audioctx = ctx;
			try { if (ctx.state === 'suspended' && ctx.resume) { ctx.resume(); } } catch (err) {}
		}
		catch (e) { an = null; }

		var mime = jawnClipMime();
		var rec = null;
		try { rec = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream); }
		catch (err) { try { rec = new MediaRecorder(stream); } catch (err2) { rec = null; } }
		if (!rec) {
			jawnClipCleanup();
			stream.getTracks().forEach(function (t) { t.stop(); });
			if (opts.status) { opts.status('I could not start the recorder.'); }
			if (opts.onFail) { opts.onFail('recorder'); }
			return;
		}
		jawn_clip.recorder = rec;
		jawn_clip.listening = true;
		jawn_clip.cb = opts.onText || null;
		jawn_clip.discard = false;
		jawn_clip.owner = opts.owner || null;
		if (opts.onstart) { opts.onstart(); }
		rec.ondataavailable = function (e) { if (e.data && e.data.size) { jawn_clip.chunks.push(e.data); } };
		rec.onstop = function () {
			jawn_clip.listening = false;
			jawn_clip.owner = null;
			var blob = new Blob(jawn_clip.chunks, { type: rec.mimeType || 'audio/webm' });
			var from = 'media';
			var pcm_n = 0, pi;
			if (jawn_clip.pcm) { for (pi = 0; pi < jawn_clip.pcm.length; pi++) { pcm_n += jawn_clip.pcm[pi].length; } }
			// a recorder that wrote nothing (WebKit's MP4/AAC) or only a sliver is
			// replaced by the samples the room reader already had
			if (pcm_n > (jawn_clip.pcm_rate || 48000) * 0.2 && blob.size < 4000) {
				blob = jawnClipWavBlob(jawn_clip.pcm, jawn_clip.pcm_rate);
				from = 'wav';
			}
			jawn_clip.last_from = from;
			jawn_clip.pcm = [];
			jawn_clip.pcm_rate = 0;
			jawnClipCleanup();
			stream.getTracks().forEach(function (t) { t.stop(); });
			if (opts.onend) { opts.onend(); }
			if (jawn_clip.discard) { jawn_clip.discard = false; return; }
			jawnClipSend(blob, opts);
		};
		if (opts.talking) {
			// hands-free: the clip ends by itself once speech has been heard and
			// the room falls quiet. The quiet is the room's own floor, learned by the
			// same reader the keyboard's dictation uses, rather than a fixed number
			// a fan or a steady hiss would sit above forever.
			if (opts.status) { opts.status('Listening…'); }
			if (an) {
				var data = new Uint8Array(an.fftSize);
				// the room reader lives with the keyboard's dictation; a page that
				// has no soft keyboard still ends a turn on the old fixed floor
				var has_room = (typeof jawnRoomThreshold === 'function');
				var threshold = has_room ? jawnRoomThreshold : function (onset) { return onset ? 0.06 : 0.04; };
				var learn = has_room ? jawnRoomLearn : function () {};
				var room_read = has_room ? jawnRoomRead : function () { return 0; };
				var read = has_room ? JAWN_ROOM_READ_FRAMES : 0;
				// the middle of three ticks already waits out a single tap, so one
				// median-loud tick is a voice that held
				var onset_frames = 1;
				var fallback = has_room ? JAWN_ROOM_FALLBACK : 0.02;
				// a conversation waits 1.1s before it lets go, so it can afford to
				// read a drop further under the turn's peak than dictation does; this
				// is the safety net when a fan sits above the floor it was given
				var peak_ratio = 2.5;
				var heard = false, run = 0, quiet_since = 0, peak = 0, win = [], recent = [], tick = 0;
				// diagnosing a room that will not go quiet: set jawn_room_debug=on
				// in the console and the level, floor and thresholds print once a second
				var debug_room = false;
				try { debug_room = (localStorage.getItem('jawn_room_debug') == 'on'); } catch (e) {}
				jawn_clip.meter = setInterval(function () {
					an.getByteTimeDomainData(data);
					var rms = 0;
					for (var i = 0; i < data.length; i++) { var d = (data[i] - 128) / 128; rms += d * d; }
					rms = Math.sqrt(rms / data.length);
					recent.push(rms);
					if (recent.length > 3) { recent.shift(); }
					// the middle of three ticks: a fan's own peaks and a single tap do
					// not read as speech, while a voice holds across the window
					var sorted_recent = recent.slice().sort(function (a, b) { return a - b; });
					var level = (sorted_recent.length >= 3) ? sorted_recent[1] : rms;
					// a turn opens by reading the room; the audio is already being
					// recorded, so speech in this moment is not lost
					if (read > 0) {
						win.push(rms);
						if (--read === 0) {
							// a window that wobbled might be a voice, but a conversation's
							// first window (just after Converse is pressed) is the room, so it
							// may trust its middle reading. A short answer that arrived before
							// the window closed still counts, if it is voice-loud.
							var steady = (room_read(win) != null);
							learn(win, true);
							if (!heard && !steady && Math.max.apply(null, win) > threshold(true)) {
								heard = true;
								run = 0;
								quiet_since = 0;
								peak = Math.max.apply(null, win);
							}
						}
						return;
					}
					var loud = (level > threshold(false));
					var quiet = (level <= threshold(false));
					if (debug_room && ((tick++ % 8) === 0)) {
						console.log('[conversation room] floor=' + (has_room ? (jawnRoom.floor || 0) : 0).toFixed(4)
							+ ' level=' + level.toFixed(4) + ' quiet<' + threshold(false).toFixed(4)
							+ ' onset>' + threshold(true).toFixed(4) + ' heard=' + heard);
					}
					if (!heard) {
						// the median already waits out a single tap or fan peak
						if (!loud) { run = 0; return; }
						if (++run < onset_frames) { return; }
						heard = true;
						run = 0;
						quiet_since = 0;
						peak = rms;
						return;
					}
					if (rms > peak) { peak = rms; }
					// the pause is read against the room and against the turn's own
					// peak, so a room that reads high or low still lets go
					var hushed = (peak > fallback && level * peak_ratio < peak);
					if (!quiet && !hushed) { quiet_since = 0; return; }
					if (!quiet_since) { quiet_since = Date.now(); return; }
					if (Date.now() - quiet_since > 1100) { jawnClipStop(); }
				}, 120);
			}
			// a clip with no analyser still needs its cap
			jawn_clip.maxtimer = setTimeout(function () { jawnClipStop(); }, 30000);
		}
		else if (opts.status) { opts.status('Listening — press Stop when you are done.'); }
		try { rec.start(250); }
		catch (err) {
			// a timeslice makes the chunks arrive while the clip runs; if the
			// engine will not take one, a plain start is still worth trying
			try { rec.start(); }
			catch (err2) {
				jawn_clip.listening = false;
				jawn_clip.recorder = null;
				jawnClipCleanup();
				stream.getTracks().forEach(function (t) { t.stop(); });
				if (opts.status) { opts.status('I could not start the recorder.'); }
				if (opts.onFail) { opts.onFail('recorder'); }
				return;
			}
		}
	}).catch(function () {
		jawn_clip.listening = false;
		if (opts.onend) { opts.onend(); }
		if (opts.status) { opts.status('I could not reach the microphone.'); }
		if (opts.onFail) { opts.onFail('microphone'); }
	});
	return true;
}

