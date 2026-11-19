// ===========================================================================
// The drum machine
// ===========================================================================
//
// Eight voices over one bar of sixteen steps. Every voice is synthesised: there
// are no samples and no files. The one-shots are rendered once into AudioBuffers
// with an OfflineAudioContext, so a step allocates only a source and its gain —
// never a buffer, an oscillator or a filter.
//
// The chart follows the Studio transport: it starts with play or record, takes
// its tempo from mixer.time.bpm, and loops the bar while Loop is on. Steps are
// placed on the AudioContext clock with a 25ms timer and a 100ms lookahead, so
// timer jitter never reaches the ear.
//
// `admin.drums` in the song is the whole state: steps, keys, loop, the per-voice
// mutes and the chosen MIDI input. A cleared chart (sixteen zeroes per voice) is
// a valid chart.
//
// Routing: the drum bus feeds studioAudio.master, which is the input of the
// mastering rack, so the drums are heard through the master chain like every
// channel. A second tap feeds the selected channel's recDest, so the browser's
// MediaRecorder take captures the drums (see studioStartTake). The native engine
// take cannot record them yet: engine/src/ has no drum voice and the engine
// cannot read this bus, so only the browser path records drums. Say so in the
// panel and the help; never imply the engine take has them.

var studioDrums = {
	ctx: null,
	out: null,
	rec: null,
	routedDest: null,
	buffers: {},
	buildState: 'idle',
	steps: {},
	keys: {},
	muted: {},
	loop: true,
	loaded: false,
	timer: 0,
	running: false,
	done: false,
	nextTime: 0,
	step: 0,
	anchor: 0,
	stepDur: 0.125,
	sources: [],
	learn: null,
	focus: false,
	midi: null,
	midiInput: ''
};

function studioDrumsText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function studioDrumsVoices() {
	var table = window.jawnos_studio_drums;
	return (table && table.length) ? table : [];
}

function studioDrumsVoiceNames() {
	return studioDrumsVoices().map(function (v) { return v.name; });
}

function studioDrumsDefaults() {
	studioDrums.steps = {};
	studioDrums.keys = {};
	studioDrums.muted = {};
	studioDrumsVoices().forEach(function (v) {
		studioDrums.steps[v.name] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
		studioDrums.keys[v.name] = String(v.key || '');
		studioDrums.muted[v.name] = false;
	});
	studioDrums.loop = true;
	studioDrums.loaded = true;
}

// ---- state, saved with the song -------------------------------------------

function studioDrumsSave() {
	var steps = {}, voices = {}, keys = {};
	studioDrumsVoices().forEach(function (v) {
		steps[v.name] = (studioDrums.steps[v.name] || []).slice(0, 16);
		voices[v.name] = { mute: studioDrums.muted[v.name] ? 1 : 0 };
		if (studioDrums.keys[v.name]) { keys[v.name] = studioDrums.keys[v.name]; }
	});
	return { steps: steps, keys: keys, loop: studioDrums.loop ? 1 : 0, voices: voices, midi: studioDrums.midiInput || '' };
}

function studioDrumsRestore(data) {
	studioDrumsDefaults();
	if (data && typeof data === 'object') {
		var saved = data.steps || {};
		studioDrumsVoices().forEach(function (v) {
			var row = saved[v.name];
			if (!row || !row.length) { return; }
			for (var i = 0; i < 16; i++) {
				var value = parseInt(row[i], 10);
				studioDrums.steps[v.name][i] = (value === 1 || value === 2) ? value : 0;
			}
		});
		var savedKeys = data.keys || {};
		Object.keys(savedKeys).forEach(function (voice) {
			var key = String(savedKeys[voice] || '').toLowerCase();
			if (key.length === 1 && studioDrums.steps[voice]) { studioDrums.keys[voice] = key; }
		});
		var muted = data.voices || {};
		Object.keys(muted).forEach(function (voice) {
			if (studioDrums.steps[voice] === undefined) { return; }
			var record = muted[voice];
			studioDrums.muted[voice] = !!(record && (record.mute == 1 || record.mute === true));
		});
		studioDrums.loop = !(data.loop == 0 || data.loop === false || data.loop === '0');
		if (data.midi) { studioDrums.midiInput = String(data.midi); }
	}
	studioDrums.loaded = true;
	if ($('#studio_drums').length) { studioDrumsRender(); }
}

// ---- the panel ------------------------------------------------------------

function studioDrumsRender() {
	$('#studio_drums_loop').prop('checked', !!studioDrums.loop);
	$('#studio_drums .studio_drums_row').each(function () {
		var row = $(this);
		var voice = row.attr('data-voice');
		var key = studioDrums.keys[voice] || '';
		row.find('.studio_drums_key')
			.text(key ? key.toUpperCase() : '\u2014')
			.attr('title', key ? key.toUpperCase() : studioDrumsText('No key'));
		row.find('.studio_drums_lamp')
			.attr('aria-pressed', studioDrums.muted[voice] ? 'false' : 'true')
			.attr('title', studioDrums.muted[voice] ? studioDrumsText('Muted') : studioDrumsText('Audible'));
		studioDrumsRenderSteps(voice);
	});
	studioDrumsFocusState();
}

function studioDrumsRenderSteps(voice) {
	var row = studioDrums.steps[voice] || [];
	$('#studio_drums .studio_drums_step[data-voice="' + voice + '"]').each(function () {
		var step = parseInt($(this).attr('data-step'), 10) || 0;
		var value = row[step] || 0;
		$(this)
			.attr('aria-pressed', value ? 'true' : 'false')
			.attr('data-accent', value === 2 ? 'yes' : 'no');
	});
}

function studioDrumsFocusState() {
	var el = $('#studio_drums_key_state');
	if (!el.length) { return; }
	var text;
	if (studioDrums.learn) {
		text = studioDrumsText('Press a key for this drum, Escape cancels');
	}
	else if (studioDrumsTyping()) {
		text = studioDrumsText('Typing: drum keys are paused');
	}
	else if (typeof studioSelectedTake !== 'undefined' && studioSelectedTake) {
		// the take editor owns S (split) while a take is selected, so the drum
		// keys stand down rather than playing and splitting at once
		text = studioDrumsText('A take is selected: drum keys paused');
	}
	else if (!studioDrums.focus) {
		text = studioDrumsText('Click Studio to play the drum keys');
	}
	else {
		text = studioDrumsText('Keys live');
	}
	el.text(text);
}

// Typing in a name or a tempo field must never fire a drum. The key map is
// also paused until the Studio window is the one the person last touched.
function studioDrumsTyping() {
	var el = document.activeElement;
	if (!el) { return false; }
	var tag = String(el.tagName || '').toLowerCase();
	if (tag === 'input' || tag === 'textarea' || tag === 'select') { return true; }
	return !!el.isContentEditable;
}

function studioDrumsGridState() {
	var panel = $('#studio_drums');
	var open = panel.length && panel.is(':visible') && !panel.hasClass('studio_panel_floating');
	$('#studio_grid').toggleClass('studio_drums_open', !!open);
}

// ---- the bus --------------------------------------------------------------

function studioDrumsBus() {
	var ctx = studioContext();
	if (!ctx) { return null; }
	if (studioDrums.ctx !== ctx) {
		studioDrums.ctx = ctx;
		studioDrums.out = null;
		studioDrums.rec = null;
		studioDrums.routedDest = null;
		studioDrums.buffers = {};
	}
	if (!studioDrums.out) {
		// heard through the master chain, and captured by the browser take
		studioDrums.out = ctx.createGain();
		studioDrums.out.gain.value = 0.9;
		studioDrums.out.connect(studioAudio.master);
		studioDrums.rec = ctx.createGain();
		studioDrums.rec.gain.value = 0.9;
		studioDrumsBuild(ctx);
	}
	studioDrumsRouteSelection();
	return ctx;
}

// The recording tap follows the selected track: that is the channel whose take
// the drums print to, and the channel the person arms. Reconnected on a change
// of selection, never duplicated.
function studioDrumsRouteSelection() {
	var ctx = studioDrums.ctx;
	if (!ctx || !studioDrums.rec) { return; }
	var ch = parseInt(studioSelectedChannel, 10) || 1;
	var c = studioAudio.channels[ch];
	if (!c && typeof studioChannelEngine === 'function') { c = studioChannelEngine(ch); }
	if (!c || !c.recDest || studioDrums.routedDest === c.recDest) { return; }
	try { studioDrums.rec.disconnect(); } catch (e) {}
	studioDrums.rec.connect(c.recDest);
	studioDrums.routedDest = c.recDest;
}

function studioDrumsBuild(ctx) {
	var Ctor = window.OfflineAudioContext || window.webkitOfflineAudioContext;
	var voices = studioDrumsVoices();
	if (!Ctor || !voices.length) { studioDrums.buildState = 'unsupported'; return; }
	studioDrums.buildState = 'building';
	var rate = ctx.sampleRate || 44100;
	var pending = voices.length;
	var finish = function (voice, buffer) {
		if (buffer) { studioDrums.buffers[voice] = buffer; }
		pending--;
		if (pending <= 0) { studioDrums.buildState = 'ready'; }
	};
	voices.forEach(function (v) {
		var spec = studioDrumsVoiceSpec(v.name);
		var off;
		try { off = new Ctor(1, Math.ceil(rate * (spec.length || 0.6)), rate); }
		catch (e) { finish(v.name, null); return; }
		studioDrumsRenderVoice(off, v.name);
		var rendering;
		try { rendering = off.startRendering(); }
		catch (e) { finish(v.name, null); return; }
		if (rendering && rendering.then) {
			rendering.then(function (buffer) { finish(v.name, buffer); })
				.catch(function () { finish(v.name, null); });
		}
		else {
			off.oncomplete = function (event) { finish(v.name, event.renderedBuffer); };
		}
	});
}

function studioDrumsNoiseBuffer(off, seconds) {
	var rate = off.sampleRate || 44100;
	var buffer = off.createBuffer(1, Math.ceil(rate * seconds), rate);
	var data = buffer.getChannelData(0);
	for (var i = 0; i < data.length; i++) { data[i] = Math.random() * 2 - 1; }
	return buffer;
}

// A voice is a shape, not a sample: one or two pitched sweeps plus a filtered
// noise wash. Everything below is rendered once, offline.
function studioDrumsVoiceSpec(name) {
	switch (name) {
		case 'kick':
			return { length: 0.55,
				tones: [{ type: 'sine', from: 150, to: 45, dur: 0.18, gain: 1.0, env: 0.45 }],
				noise: [{ filter: 'highpass', freq: 3000, dur: 0.012, gain: 0.25 }] };
		case 'snare':
			return { length: 0.35,
				tones: [{ type: 'triangle', from: 190, to: 160, dur: 0.12, gain: 0.45, env: 0.16 }],
				noise: [{ filter: 'bandpass', freq: 1800, q: 0.8, dur: 0.18, gain: 0.9 }] };
		case 'closed_hat':
			return { length: 0.15, noise: [{ filter: 'highpass', freq: 7500, dur: 0.055, gain: 0.6 }] };
		case 'open_hat':
			return { length: 0.45, noise: [{ filter: 'highpass', freq: 6500, dur: 0.32, gain: 0.55 }] };
		case 'clap':
			return { length: 0.35, noise: [
				{ filter: 'bandpass', freq: 1200, q: 1.2, at: 0, dur: 0.02, gain: 0.6 },
				{ filter: 'bandpass', freq: 1200, q: 1.2, at: 0.011, dur: 0.02, gain: 0.6 },
				{ filter: 'bandpass', freq: 1200, q: 1.2, at: 0.022, dur: 0.02, gain: 0.6 },
				{ filter: 'bandpass', freq: 1200, q: 1.2, at: 0.03, dur: 0.12, gain: 0.4 }
			] };
		case 'low_tom':
			return { length: 0.45, tones: [{ type: 'sine', from: 130, to: 75, dur: 0.22, gain: 0.9, env: 0.35 }] };
		case 'high_tom':
			return { length: 0.35, tones: [{ type: 'sine', from: 220, to: 130, dur: 0.18, gain: 0.85, env: 0.28 }] };
		case 'rim':
			return { length: 0.12,
				tones: [{ type: 'square', from: 900, to: 700, dur: 0.02, gain: 0.3, env: 0.05 }],
				noise: [{ filter: 'bandpass', freq: 2500, q: 1.4, dur: 0.02, gain: 0.4 }] };
	}
	return { length: 0.2, noise: [{ filter: 'highpass', freq: 2000, dur: 0.05, gain: 0.4 }] };
}

function studioDrumsEnvelope(off, dur, peak, at) {
	var gain = off.createGain();
	var start = at || 0;
	gain.gain.setValueAtTime(0.0001, start);
	gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, peak), start + 0.003);
	gain.gain.exponentialRampToValueAtTime(0.0001, start + Math.max(0.004, dur));
	return gain;
}

function studioDrumsRenderVoice(off, name) {
	var spec = studioDrumsVoiceSpec(name);
	var noise = (spec.noise && spec.noise.length) ? studioDrumsNoiseBuffer(off, spec.length || 0.6) : null;
	(spec.tones || []).forEach(function (tone) {
		var at = tone.at || 0;
		var osc = off.createOscillator();
		var env = studioDrumsEnvelope(off, tone.env || tone.dur, tone.gain || 0.8, at);
		osc.type = tone.type || 'sine';
		osc.frequency.setValueAtTime(tone.from, at);
		osc.frequency.exponentialRampToValueAtTime(Math.max(20, tone.to), at + tone.dur);
		osc.connect(env);
		env.connect(off.destination);
		osc.start(at);
		osc.stop(at + Math.max(tone.dur, tone.env || 0) + 0.02);
	});
	(spec.noise || []).forEach(function (burst) {
		var at = burst.at || 0;
		var src = off.createBufferSource();
		var filter = off.createBiquadFilter();
		var env = studioDrumsEnvelope(off, burst.dur, burst.gain || 0.5, at);
		src.buffer = noise;
		filter.type = burst.filter || 'highpass';
		filter.frequency.value = burst.freq || 2000;
		if (burst.q) { filter.Q.value = burst.q; }
		src.connect(filter);
		filter.connect(env);
		env.connect(off.destination);
		src.start(at, 0, Math.min(burst.dur + 0.02, (spec.length || 0.6)));
	});
}

// ---- playing --------------------------------------------------------------

function studioDrumsPlay(voice, when, velocity) {
	var ctx = studioDrums.ctx;
	var buffer = studioDrums.buffers[voice];
	if (!ctx || !buffer || !studioDrums.out) { return; }
	var src = ctx.createBufferSource();
	var gain = ctx.createGain();
	src.buffer = buffer;
	gain.gain.value = Math.max(0.1, Math.min(1, velocity || 1));
	src.connect(gain);
	gain.connect(studioDrums.out);
	if (studioDrums.rec) { gain.connect(studioDrums.rec); }
	var at = when || ctx.currentTime;
	src.start(at);
	studioDrums.sources.push(src);
	src.onended = function () {
		var at_index = studioDrums.sources.indexOf(src);
		if (at_index >= 0) { studioDrums.sources.splice(at_index, 1); }
		try { gain.disconnect(); } catch (e) {}
	};
}

function studioDrumsStopSources() {
	studioDrums.sources.slice().forEach(function (src) {
		try { src.stop(); } catch (e) {}
	});
	studioDrums.sources = [];
}

function studioDrumsRecording() {
	if (!mixer || !mixer['time']) { return false; }
	if (mixer['time']['status'] === 'record') { return true; }
	var armed = false;
	$.each(mixer, function (ch, record) {
		if (!/^[0-9]+$/.test(ch) || !record || !record.armed) { return; }
		if (record.armed.state === 'rec') { armed = true; }
	});
	return armed;
}

function studioDrumsCurrentStep() {
	if (!studioDrums.running || !studioDrums.stepDur) { return 0; }
	var elapsed = (studioDrums.ctx.currentTime - studioDrums.anchor) / studioDrums.stepDur;
	var step = Math.floor(elapsed) % 16;
	return (step + 16) % 16;
}

// A mapped key, a MIDI note, the voice's own name button, or a shelf-style hit:
// one entry point, so recording and auditioning cannot disagree.
function studioDrumsTrigger(voice, velocity, record) {
	var ctx = studioDrumsBus();
	if (!ctx || !studioDrums.steps[voice]) { return; }
	var step = studioDrumsCurrentStep();
	studioDrumsPlay(voice, ctx.currentTime + 0.008, velocity);
	if (record !== false && studioDrumsRecording()) {
		studioDrums.steps[voice][step] = (velocity >= 2) ? 2 : 1;
		studioDrumsRenderSteps(voice);
		studioSaver();
	}
	studioDrumsHighlightStep(studioDrums.running ? step : -1);
}

// ---- the scheduler --------------------------------------------------------

function studioDrumsTransport(on) {
	if (on) {
		var ctx = studioDrumsBus();
		if (!ctx) { return; }
		studioDrums.running = true;
		studioDrums.done = false;
		studioDrums.step = 0;
		studioDrums.anchor = ctx.currentTime + 0.05;
		studioDrums.nextTime = studioDrums.anchor;
		if (!studioDrums.timer) { studioDrums.timer = setInterval(studioDrumsSchedule, 25); }
		studioDrumsSchedule();
		return;
	}
	studioDrums.running = false;
	studioDrums.done = false;
	studioDrums.nextTime = 0;
	studioDrums.step = 0;
	if (studioDrums.timer) { clearInterval(studioDrums.timer); studioDrums.timer = 0; }
	studioDrumsStopSources();
	studioDrumsHighlightStep(-1);
}

function studioDrumsSchedule() {
	if (!studioDrums.running) { return; }
	var status = mixer && mixer['time'] ? mixer['time']['status'] : 'stop';
	if (status !== 'play' && status !== 'record') { studioDrumsTransport(false); return; }
	var ctx = studioDrumsBus();
	if (!ctx) { return; }
	var bpm = studioKnobNumber(mixer['time']['bpm'], 120) || 120;
	var stepDur = 60 / bpm / 4;
	studioDrums.stepDur = stepDur;
	var now = ctx.currentTime;
	var guard = 0;
	while (studioDrums.nextTime < now + 0.1 && guard++ < 64) {
		studioDrumsPlayRow(studioDrums.step, studioDrums.nextTime);
		studioDrums.nextTime += stepDur;
		studioDrums.step = (studioDrums.step + 1) % 16;
		if (studioDrums.step === 0 && !studioDrums.loop) { studioDrums.done = true; break; }
	}
	if (studioDrums.done) {
		studioDrums.running = false;
		if (studioDrums.timer) { clearInterval(studioDrums.timer); studioDrums.timer = 0; }
		studioDrumsHighlightStep(-1);
		return;
	}
	var elapsed = (now - studioDrums.anchor) / stepDur;
	studioDrumsHighlightStep(((Math.floor(elapsed) % 16) + 16) % 16);
}

function studioDrumsPlayRow(step, when) {
	studioDrumsVoices().forEach(function (v) {
		if (studioDrums.muted[v.name]) { return; }
		var value = (studioDrums.steps[v.name] || [])[step] || 0;
		if (!value) { return; }
		studioDrumsPlay(v.name, when, value === 2 ? 1 : 0.7);
	});
}

function studioDrumsHighlightStep(step) {
	var row = $('#studio_drums .studio_drums_row');
	row.find('.studio_drums_step').removeClass('studio_drums_playing');
	if (step >= 0) {
		row.find('.studio_drums_step[data-step="' + step + '"]').addClass('studio_drums_playing');
	}
}

// ---- the key map ----------------------------------------------------------

function studioDrumsVoiceForKey(key) {
	key = String(key || '').toLowerCase();
	var found = '';
	studioDrumsVoices().forEach(function (v) {
		if (studioDrums.keys[v.name] === key) { found = v.name; }
	});
	return found;
}

function studioDrumsVoiceForNote(note) {
	var found = '';
	studioDrumsVoices().forEach(function (v) {
		if (parseInt(v.note, 10) === parseInt(note, 10)) { found = v.name; }
	});
	return found;
}

function studioDrumsAssignKey(voice, key) {
	key = String(key || '').toLowerCase();
	if (key.length !== 1) { return; }
	studioDrumsVoices().forEach(function (v) {
		if (studioDrums.keys[v.name] === key) { delete studioDrums.keys[v.name]; }
	});
	studioDrums.keys[voice] = key;
	studioDrumsRender();
}

$(document).on('click', '.studio_drums_key', function (e) {
	e.preventDefault();
	var voice = $(this).attr('data-voice');
	studioDrums.learn = (studioDrums.learn === voice) ? null : voice;
	$('.studio_drums_key').attr('aria-pressed', 'false');
	if (studioDrums.learn) { $(this).attr('aria-pressed', 'true'); }
	studioDrumsFocusState();
});

$(document).on('click', '.studio_drums_voice', function (e) {
	e.preventDefault();
	studioDrumsTrigger($(this).attr('data-voice'), 1, false);
});

$(document).on('click', '.studio_drums_lamp', function (e) {
	e.preventDefault();
	var voice = $(this).attr('data-voice');
	studioDrums.muted[voice] = !studioDrums.muted[voice];
	studioDrumsRender();
	studioSaver();
});

$(document).on('click', '.studio_drums_step', function (e) {
	e.preventDefault();
	var voice = $(this).attr('data-voice');
	var step = parseInt($(this).attr('data-step'), 10) || 0;
	if (!studioDrums.steps[voice]) { return; }
	var current = studioDrums.steps[voice][step] || 0;
	// Shift marks the beat as an accent; a normal click is on or off.
	studioDrums.steps[voice][step] = e.shiftKey ? (current === 2 ? 0 : 2) : (current ? 0 : 1);
	studioDrumsRenderSteps(voice);
	if (studioDrums.steps[voice][step]) { studioDrumsTrigger(voice, studioDrums.steps[voice][step], false); }
	studioSaver();
});

$(document).on('change', '#studio_drums_loop', function () {
	studioDrums.loop = $(this).prop('checked');
	studioSaver();
});

$(document).on('click', '#studio_drums_clear', function (e) {
	e.preventDefault();
	studioDrumsVoices().forEach(function (v) {
		studioDrums.steps[v.name] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	});
	studioDrumsRender();
	studioSaver();
});

// The guard that keeps a track name from playing a kick: a mapped key only
// sounds when no text field has focus and Studio was the last window touched.
$(document).on('keydown', function (e) {
	if (e.metaKey || e.ctrlKey || e.altKey) { return; }
	if (!$('#studio').is(':visible') || !$('#studio_drums').length) { return; }
	if (studioDrums.learn) {
		if (e.key === 'Escape') {
			studioDrums.learn = null;
			$('.studio_drums_key').attr('aria-pressed', 'false');
			studioDrumsFocusState();
			e.preventDefault();
			return;
		}
		if (String(e.key || '').length !== 1) { return; }
		studioDrumsAssignKey(studioDrums.learn, e.key);
		studioDrums.learn = null;
		$('.studio_drums_key').attr('aria-pressed', 'false');
		studioDrumsFocusState();
		studioSaver();
		e.preventDefault();
		return;
	}
	if (studioDrumsTyping() || !studioDrums.focus || e.repeat) { return; }
	if (typeof studioSelectedTake !== 'undefined' && studioSelectedTake) { return; }
	var voice = studioDrumsVoiceForKey(e.key);
	if (!voice) { return; }
	studioDrumsTrigger(voice, e.shiftKey ? 2 : 1, true);
	e.preventDefault();
});

// The last pointer press decides which window owns the keys; the panel bar says
// so in words, so a person is never guessing.
$(document).on('pointerdown', function (e) {
	studioDrums.focus = !!$(e.target).closest('#studio').length;
	studioDrumsFocusState();
});

$(document).on('focusin', function (e) {
	if ($(e.target).closest('#studio').length) { studioDrums.focus = true; }
	studioDrumsFocusState();
});

// ---- Web MIDI -------------------------------------------------------------

function studioDrumsMidiProbe() {
	var button = $('#studio_drums_midi');
	var state = $('#studio_drums_midi_state');
	if (!navigator.requestMIDIAccess) {
		button.prop('disabled', true);
		state.text(studioDrumsText('Web MIDI is not available in this browser.'));
		return;
	}
	button.prop('disabled', false);
	if (!state.text()) { state.text(studioDrumsText('MIDI ready')); }
}

function studioDrumsMidiConnect() {
	if (!navigator.requestMIDIAccess) { studioDrumsMidiProbe(); return; }
	var state = $('#studio_drums_midi_state');
	state.text(studioDrumsText('Opening MIDI...'));
	navigator.requestMIDIAccess().then(function (access) {
		studioDrums.midi = access;
		studioDrumsMidiList(access);
		access.onstatechange = function () { studioDrumsMidiList(access); };
	}).catch(function (error) {
		state.text(studioDrumsText('MIDI could not be opened.') + (error && error.message ? ' ' + error.message : ''));
	});
}

function studioDrumsMidiList(access) {
	var select = $('#studio_drums_midi_input');
	var state = $('#studio_drums_midi_state');
	var inputs = [];
	access.inputs.forEach(function (input) { inputs.push(input); });
	select.empty();
	select.append($('<option></option>').attr('value', '').text(studioDrumsText('No MIDI input')));
	inputs.forEach(function (input) {
		select.append($('<option></option>').attr('value', input.id).text(input.name || input.id));
		input.onmidimessage = function (event) { studioDrumsMidiMessage(input, event); };
	});
	if (!studioDrums.midiInput || !inputs.some(function (i) { return i.id === studioDrums.midiInput; })) {
		studioDrums.midiInput = inputs.length ? inputs[0].id : '';
	}
	select.val(studioDrums.midiInput);
	select.prop('disabled', !inputs.length);
	state.text(inputs.length
		? studioDrumsText('MIDI notes play these drums; the accent follows velocity.')
		: studioDrumsText('No MIDI input was found.'));
}

function studioDrumsMidiMessage(input, event) {
	if (input.id !== studioDrums.midiInput) { return; }
	var data = event.data;
	if (!data || data.length < 3) { return; }
	if ((data[0] & 0xf0) !== 0x90 || data[2] === 0) { return; }
	var voice = studioDrumsVoiceForNote(data[1]);
	if (!voice) { return; }
	studioDrumsTrigger(voice, data[2] > 96 ? 2 : 1, true);
}

$(document).on('click', '#studio_drums_midi', function (e) {
	e.preventDefault();
	studioDrumsMidiConnect();
});

$(document).on('change', '#studio_drums_midi_input', function () {
	studioDrums.midiInput = $(this).val() || '';
	studioSaver();
});

// The drum bus follows the selected track, so arming that track captures the
// drums. The selection handlers live in 03_editing.js and 09_pedals.js; this
// one runs after them and only re-routes the recording tap.
$(document).on('click', '.channel, .studio_track_panel', function () {
	studioDrumsRouteSelection();
});

// ---- init -----------------------------------------------------------------

function studioDrumsInit() {
	if (!studioDrumsVoices().length) { return; }
	if (!studioDrums.loaded) { studioDrumsDefaults(); }
	studioDrumsRender();
	studioDrums.focus = !!$('#studio').is(':visible');
	studioDrumsBus();
	studioDrumsMidiProbe();
	studioDrumsGridState();
	studioDrumsFocusState();
}
