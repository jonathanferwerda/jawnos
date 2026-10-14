// JawnOS synth: a polyphonic synthesizer engine the studio hosts.
//
// One engine, one AudioContext. When the studio is open the engine rides the
// studio's context (so the synth is just another source on a channel: it can be
// armed, recorded and monitored like a mic); on its own window it makes its own
// context. It exposes window.jawnosSynth:
//
//   attach(ctx, destination)   build the engine on a context, feeding destination
//   noteOn(note, velocity)     a MIDI note number (60 = middle C) and 0..1
//   noteOff(note)  allNotesOff()
//   set(param, value)  setPatch(obj)  getPatch()  loadPreset(name)  presets()
//   voices()                   how many are sounding right now
//   midi.start()  midi.devices()  midi.select(id)  midi.onnotes(fn)
//
// Two voice engines, chosen by the patch: 'subtractive' (two oscillators and a
// noise transient through a resonant filter, each with its own ADSR and a shared
// LFO) and 'pluck' (Karplus-Strong: a noise burst into a tuned delay line, which
// is where a convincing plucked string/piano comes from without any samples).
//
// Polyphony is capped by patch.voices (32 by default) with oldest-voice stealing,
// so a held sustain pedal never runs away.

(function () {
	'use strict';

	var NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

	function midiToFreq(note) { return 440 * Math.pow(2, (note - 69) / 12); }
	function noteName(note) { return NOTE_NAMES[((note % 12) + 12) % 12] + (Math.floor(note / 12) - 1); }
	function clampNumber(v, lo, hi, fallback) {
		var n = parseFloat(v);
		if (n === null || n === undefined || isNaN(n)) { return fallback; }
		return Math.max(lo, Math.min(hi, n));
	}

	// A harmonic recipe for a PeriodicWave, so piano/organ/bell voices get their
	// partials without any samples: real[0] (DC) is dropped by Web Audio.
	function periodicWave(ctx, harmonics) {
		var n = harmonics.length + 1;
		var real = new Float32Array(n);
		var imag = new Float32Array(n);
		for (var i = 0; i < harmonics.length; i++) { imag[i + 1] = harmonics[i]; }
		return ctx.createPeriodicWave(real, imag, { disableNormalization: false });
	}

	var HARMONICS = {
		piano:  [1, 0.62, 0.42, 0.29, 0.2, 0.14, 0.1, 0.07, 0.05, 0.035, 0.025],
		organ:  [1, 0.0, 0.5, 0.0, 0.35, 0.0, 0.25],
		bell:   [1, 0.0, 0.0, 0.55, 0.0, 0.0, 0.0, 0.35, 0.0, 0.0, 0.0, 0.25],
		strings:[1, 0.7, 0.55, 0.45, 0.35, 0.28, 0.22, 0.16]
	};

	// ---- the factory patches ---------------------------------------------------
	// Each is a full patch; loadPreset copies one and set() tweaks it. Values are
	// all normalised to small numbers so the studio's 0..100 knobs can map onto
	// them (see jawnosSynth.knob()).
	var PRESETS = {
		'Grand Piano': {
			engine: 'subtractive', wave: 'piano', noise: 0.16, voices: 32,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 0, detune: 4, level: 0.5 }],
			filter: { type: 'lowpass', cutoff: 3800, q: 0.6, env: 0.25, keytrack: 0.35 },
			amp: { a: 0.004, d: 2.6, s: 0.0, r: 0.5 },
			fenv: { a: 0.002, d: 1.4, s: 0.0, r: 0.4 },
			lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		},
		'Electric Piano': {
			engine: 'subtractive', wave: 'sine', noise: 0.05, voices: 24,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 1, detune: 3, level: 0.3 }],
			filter: { type: 'lowpass', cutoff: 2600, q: 0.9, env: 0.4, keytrack: 0.5 },
			amp: { a: 0.004, d: 1.8, s: 0.0, r: 0.4 },
			fenv: { a: 0.002, d: 0.9, s: 0.0, r: 0.3 },
			lfo: { rate: 3.6, pitch: 0, cutoff: 0, amp: 0.12 }
		},
		'Bell': {
			engine: 'subtractive', wave: 'bell', noise: 0.02, voices: 16,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 1, detune: 7, level: 0.4 }],
			filter: { type: 'bandpass', cutoff: 3000, q: 1.2, env: 0.2, keytrack: 0.6 },
			amp: { a: 0.002, d: 3.5, s: 0.0, r: 1.2 },
			fenv: { a: 0.002, d: 2.0, s: 0.0, r: 0.8 },
			lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		},
		'Warm Pad': {
			engine: 'subtractive', wave: 'sawtooth', noise: 0.0, voices: 24,
			osc: [{ octave: 0, detune: -7, level: 0.7 }, { octave: 0, detune: 7, level: 0.7 }],
			filter: { type: 'lowpass', cutoff: 1400, q: 1.4, env: 0.5, keytrack: 0.2 },
			amp: { a: 0.9, d: 1.2, s: 0.75, r: 1.6 },
			fenv: { a: 1.2, d: 1.5, s: 0.4, r: 1.2 },
			lfo: { rate: 0.5, pitch: 0.04, cutoff: 0.15, amp: 0 }
		},
		'Saw Lead': {
			engine: 'subtractive', wave: 'sawtooth', noise: 0.0, voices: 8,
			osc: [{ octave: 0, detune: -10, level: 0.8 }, { octave: 0, detune: 10, level: 0.8 }],
			filter: { type: 'lowpass', cutoff: 3200, q: 3.5, env: 0.6, keytrack: 0.4 },
			amp: { a: 0.01, d: 0.3, s: 0.7, r: 0.25 },
			fenv: { a: 0.02, d: 0.5, s: 0.3, r: 0.3 },
			lfo: { rate: 5.2, pitch: 0.06, cutoff: 0, amp: 0 }
		},
		'Sub Bass': {
			engine: 'subtractive', wave: 'square', noise: 0.0, voices: 6,
			osc: [{ octave: -1, detune: 0, level: 1.0 }, { octave: 0, detune: 0, level: 0.25 }],
			filter: { type: 'lowpass', cutoff: 900, q: 4.0, env: 0.7, keytrack: 0.1 },
			amp: { a: 0.008, d: 0.5, s: 0.6, r: 0.15 },
			fenv: { a: 0.005, d: 0.35, s: 0.1, r: 0.2 },
			lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		},
		'Strings': {
			engine: 'subtractive', wave: 'strings', noise: 0.02, voices: 24,
			osc: [{ octave: 0, detune: -12, level: 0.6 }, { octave: 0, detune: 12, level: 0.6 }],
			filter: { type: 'lowpass', cutoff: 2400, q: 0.8, env: 0.3, keytrack: 0.3 },
			amp: { a: 0.5, d: 0.8, s: 0.8, r: 0.9 },
			fenv: { a: 0.6, d: 1.0, s: 0.6, r: 0.8 },
			lfo: { rate: 5.0, pitch: 0.05, cutoff: 0.08, amp: 0 }
		},
		'Organ': {
			engine: 'subtractive', wave: 'organ', noise: 0.0, voices: 16,
			osc: [{ octave: 0, detune: 0, level: 1.0 }, { octave: 1, detune: 0, level: 0.4 }],
			filter: { type: 'lowpass', cutoff: 5000, q: 0.4, env: 0.0, keytrack: 0.4 },
			amp: { a: 0.01, d: 0.1, s: 0.95, r: 0.1 },
			fenv: { a: 0.01, d: 0.1, s: 1.0, r: 0.1 },
			lfo: { rate: 6.4, pitch: 0, cutoff: 0, amp: 0.06 }
		},
		'Pluck': {
			engine: 'pluck', damping: 0.5, brightness: 0.6, voices: 24,
			amp: { a: 0.001, d: 1.6, s: 0.0, r: 0.35 }, lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		},
		'Nylon Pluck': {
			engine: 'pluck', damping: 0.35, brightness: 0.45, voices: 24,
			amp: { a: 0.001, d: 2.4, s: 0.0, r: 0.5 }, lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 }
		}
	};

	var S = {
		ctx: null,
		out: null,
		drive: null,
		comp: null,
		patch: null,
		preset: 'Grand Piano',
		voices: {},      // id -> voice
		order: [],       // note-on order, oldest first
		nextId: 1,
		playing: {},     // note -> true (for sustain / ui)
		sustain: false,
		sustainNotes: [],
		bend: 0,
		mod: 0,
		lfo: null,
		lfoPitch: null,
		lfoCutoff: null,
		lfoAmp: null,
		midi: { access: null, inputs: [], selected: null, listeners: [] }
	};

	function copyPatch(p) { return JSON.parse(JSON.stringify(p)); }

	// ---- the engine graph ------------------------------------------------------

	function attach(ctx, destination) {
		if (!ctx) { return null; }
		if (S.ctx === ctx && S.out) { return S }        // already on this context
		detach();
		S.ctx = ctx;
		S.out = ctx.createGain();
		S.drive = ctx.createWaveShaper();
		S.comp = ctx.createDynamicsCompressor();
		S.comp.threshold.value = -12;
		S.comp.ratio.value = 4;
		S.out.connect(S.drive).connect(S.comp).connect(destination || ctx.destination);
		// the shared LFO: one oscillator, three depth taps (pitch, cutoff, tremolo)
		S.lfo = ctx.createOscillator();
		S.lfo.type = 'sine';
		S.lfo.frequency.value = 5;
		S.lfoPitch = ctx.createGain();   // cents, wired into each voice's detune
		S.lfoCutoff = ctx.createGain();  // Hz, wired into each voice's filter
		S.lfoAmp = ctx.createGain();     // tremolo on the master out
		S.lfoPitch.gain.value = 0;
		S.lfoCutoff.gain.value = 0;
		S.lfoAmp.gain.value = 0;
		S.lfo.connect(S.lfoPitch);
		S.lfo.connect(S.lfoCutoff);
		S.lfo.connect(S.lfoAmp);
		S.lfoAmp.connect(S.out.gain);
		S.lfo.start();
		if (!S.patch) { S.patch = copyPatch(PRESETS[S.preset]); }
		applyLfo();
		applyDrive();
		return S;
	}

	function detach() {
		if (S.ctx) {
			try { S.lfo.stop(); } catch (e) {}
			Object.keys(S.voices).forEach(function (id) { killVoice(S.voices[id], true); });
			S.voices = {}; S.order = [];
			if (S.out && S.out.disconnect) { try { S.out.disconnect(); } catch (e) {} }
		}
		S.ctx = null; S.out = null; S.drive = null; S.comp = null; S.lfo = null;
	}

	function applyLfo() {
		if (!S.ctx) { return; }
		var l = S.patch.lfo || {};
		var rate = clampNumber(l.rate, 0, 20, 0);
		S.lfo.frequency.value = rate > 0 ? rate : 5;
		S.lfoPitch.gain.value = (l.pitch || 0) * 1200;      // fraction of an octave
		S.lfoCutoff.gain.value = (l.cutoff || 0) * 2400;
		S.lfoAmp.gain.value = (l.amp || 0) * 0.5;
	}

	function applyDrive() {
		if (!S.drive || !S.ctx) { return; }
		var amount = clampNumber(S.patch.drive, 0, 1, 0);
		if (amount <= 0.001) { S.drive.curve = null; return; }
		var n = 1024, curve = new Float32Array(n), k = amount * 40;
		for (var i = 0; i < n; i++) {
			var x = (i * 2) / n - 1;
			curve[i] = ((1 + k) * x) / (1 + k * Math.abs(x));
		}
		S.drive.curve = curve;
		S.drive.oversample = '4x';
	}

	// ---- voices ----------------------------------------------------------------

	function voiceEnv(gainParam, env, t0, peak) {
		var a = Math.max(0.001, env.a || 0.005);
		var d = Math.max(0.001, env.d || 0.2);
		var s = clampNumber(env.s, 0, 1, 0.7);
		gainParam.cancelScheduledValues(t0);
		gainParam.setValueAtTime(0.0001, t0);
		gainParam.linearRampToValueAtTime(peak, t0 + a);
		gainParam.linearRampToValueAtTime(Math.max(0.0001, peak * s), t0 + a + d);
	}

	function filterEnv(filter, base, env, t0, keytrack, freq) {
		var a = Math.max(0.001, env.a || 0.005);
		var d = Math.max(0.001, env.d || 0.2);
		var s = clampNumber(env.s, 0, 1, 0.0);
		var key = 1 + keytrack * (freq / 261.63 - 1);
		var baseHz = Math.max(40, Math.min(18000, base * key));
		var peak = Math.max(40, Math.min(18000, baseHz * (1 + (env.amount || 0) * 6)));
		filter.frequency.cancelScheduledValues(t0);
		filter.frequency.setValueAtTime(peak, t0);
		filter.frequency.exponentialRampToValueAtTime(Math.max(40, baseHz * (0.2 + s * 0.8)), t0 + a + d);
	}

	function newVoice(note, velocity) {
		var ctx = S.ctx, p = S.patch;
		var t0 = ctx.currentTime;
		var freq = midiToFreq(note + (S.patch.transpose || 0));
		var amp = ctx.createGain();
		amp.gain.value = 0.0001;
		amp.connect(S.out);
		var voice = { id: S.nextId++, note: note, freq: freq, velocity: velocity, amp: amp, nodes: [], released: false, started: t0 };

		if (p.engine === 'pluck') {
			var period = 1 / freq;
			var delay = ctx.createDelay(0.05);
			delay.delayTime.value = period;
			var damp = ctx.createBiquadFilter();
			damp.type = 'lowpass';
			damp.frequency.value = Math.min(18000, freq * (2 + (p.brightness || 0.5) * 12));
			var fb = ctx.createGain();
			fb.gain.value = Math.min(0.999, 0.8 + (p.damping || 0.5) * 0.199);
			delay.connect(damp);
			damp.connect(fb);
			fb.connect(delay);
			delay.connect(amp);
			// excite with a short noise burst through the loop
			var len = Math.max(1, Math.floor(ctx.sampleRate * period));
			var buf = ctx.createBuffer(1, len, ctx.sampleRate);
			var data = buf.getChannelData(0);
			for (var i = 0; i < len; i++) { data[i] = (Math.random() * 2 - 1); }
			var src = ctx.createBufferSource();
			src.buffer = buf;
			src.connect(delay);
			src.start(t0);
			src.stop(t0 + period);
			voice.nodes.push(delay, damp, fb, src);
			voiceEnv(amp.gain, p.amp || { a: 0.001, d: 1.6, s: 0, r: 0.35 }, t0, 0.5 + velocity * 0.5);
			voice.stopSoon = function (t1) {
				var r = Math.max(0.05, (p.amp && p.amp.r) || 0.35);
				amp.gain.cancelScheduledValues(t1);
				if (amp.gain.cancelAndHoldAtTime) { amp.gain.cancelAndHoldAtTime(t1); }
				amp.gain.setTargetAtTime(0.0001, t1, r / 4);
				setTimeout(function () { killVoice(voice, false); }, (r + 0.1) * 1000);
			};
			return voice;
		}

		// subtractive: two oscillators (+ noise transient) -> filter -> amp
		var mix = ctx.createGain();
		mix.gain.value = 0.5;
		var filter = ctx.createBiquadFilter();
		filter.type = (p.filter && p.filter.type) || 'lowpass';
		filter.Q.value = (p.filter && p.filter.q) || 1;
		mix.connect(filter).connect(amp);
		voice.nodes.push(mix, filter);
		var harmonics = HARMONICS[p.wave] || null;
		var waveType = harmonics ? periodicWave(ctx, harmonics) : null;
		var oscLevels = p.osc || [{ level: 1 }, { level: 0.5 }];
		oscLevels.forEach(function (o, idx) {
			var osc = ctx.createOscillator();
			var detune = S.bend * 200 + (o.detune || 0) + (S.mod * 50);
			if (waveType && !o.wave) { osc.setPeriodicWave(waveType); }
			else { osc.type = o.wave || p.wave || 'sawtooth'; }
			osc.frequency.value = freq;
			osc.detune.value = detune;
			var g = ctx.createGain();
			g.gain.value = (o.level == null ? 1 : o.level) / Math.max(1, oscLevels.length);
			osc.connect(g).connect(mix);
			osc.start(t0);
			voice.nodes.push(osc, g);
			voice.oscs = voice.oscs || [];
			voice.oscs.push(osc);
			if (S.lfoPitch) { S.lfoPitch.connect(osc.detune); }
		});
		if (p.noise > 0) {
			var nlen = Math.max(1, Math.floor(ctx.sampleRate * 0.06));
			var nbuf = ctx.createBuffer(1, nlen, ctx.sampleRate);
			var nd = nbuf.getChannelData(0);
			for (var j = 0; j < nlen; j++) { nd[j] = (Math.random() * 2 - 1) * Math.pow(1 - j / nlen, 2); }
			var nsrc = ctx.createBufferSource();
			nsrc.buffer = nbuf;
			var ng = ctx.createGain();
			ng.gain.value = p.noise;
			nsrc.connect(ng).connect(mix);
			nsrc.start(t0);
			voice.nodes.push(nsrc, ng);
		}
		if (S.lfoCutoff) { S.lfoCutoff.connect(filter.frequency); }
		filterEnv(filter, (p.filter && p.filter.cutoff) || 3000, (p.fenv && { a: p.fenv.a, d: p.fenv.d, s: p.fenv.s, amount: (p.filter && p.filter.env) || 0 }) || { a: 0.01, d: 0.2, s: 0, amount: 0 }, t0, (p.filter && p.filter.keytrack) || 0, freq);
		voiceEnv(amp.gain, p.amp || { a: 0.01, d: 0.3, s: 0.7, r: 0.3 }, t0, 0.25 + velocity * 0.6);
		voice.stopSoon = function (t1) {
			var r = Math.max(0.02, (p.amp && p.amp.r) || 0.3);
			amp.gain.cancelScheduledValues(t1);
			if (amp.gain.cancelAndHoldAtTime) { amp.gain.cancelAndHoldAtTime(t1); }
			amp.gain.setTargetAtTime(0.0001, t1, r / 4);
			(voice.oscs || []).forEach(function (osc) { try { osc.stop(t1 + r + 0.1); } catch (e) {} });
			setTimeout(function () { killVoice(voice, false); }, (r + 0.2) * 1000);
		};
		return voice;
	}

	function killVoice(voice, immediate) {
		if (!voice || voice.dead) { return; }
		voice.dead = true;
		if (immediate) {
			(voice.oscs || []).forEach(function (osc) { try { osc.stop(); } catch (e) {} });
			voice.nodes.forEach(function (n) { try { n.stop && n.stop(); } catch (e) {} });
		}
		voice.nodes.forEach(function (n) { try { n.disconnect(); } catch (e) {} });
		try { voice.amp.disconnect(); } catch (e) {}
		delete S.voices[voice.id];
		S.order = S.order.filter(function (id) { return id !== voice.id; });
	}

	function stealing() {
		var max = clampNumber((S.patch && S.patch.voices), 1, 64, 32);
		while (S.order.length >= max) {
			var oldest = S.voices[S.order[0]];
			if (!oldest) { S.order.shift(); continue; }
			try { oldest.amp.gain.cancelScheduledValues(S.ctx.currentTime); } catch (e) {}
			killVoice(oldest, true);
		}
	}

	function noteOn(note, velocity) {
		if (!S.ctx) { return; }
		note = Math.round(clampNumber(note, 0, 127, 60));
		velocity = clampNumber(velocity, 0, 1, 0.8);
		S.playing[note] = true;
		var v = newVoice(note, velocity);
		S.voices[v.id] = v;
		S.order.push(v.id);
		stealing();
	}

	function noteOff(note) {
		if (!S.ctx) { return; }
		note = Math.round(clampNumber(note, 0, 127, 60));
		if (S.sustain) { S.sustainNotes.push(note); return; }
		releaseNote(note);
	}

	function releaseNote(note) {
		delete S.playing[note];
		var t1 = S.ctx.currentTime;
		Object.keys(S.voices).forEach(function (id) {
			var v = S.voices[id];
			if (v.note === note && !v.released) { v.released = true; if (v.stopSoon) { v.stopSoon(t1); } }
		});
	}

	function allNotesOff() {
		S.sustainNotes = [];
		Object.keys(S.voices).forEach(function (id) {
			var v = S.voices[id];
			if (!v.released) { v.released = true; if (v.stopSoon) { v.stopSoon(S.ctx.currentTime); } }
		});
		S.playing = {};
	}

	function voices() { return Object.keys(S.voices).length; }

	// ---- patch access ----------------------------------------------------------

	function patchShapes() {
		if (!S.patch) { S.patch = copyPatch(PRESETS[S.preset]); }
		if (!S.patch.osc) { S.patch.osc = [{ octave: 0, detune: 0, level: 1 }, { octave: 0, detune: 0, level: 0.4 }]; }
		if (!S.patch.amp) { S.patch.amp = { a: 0.01, d: 0.3, s: 0.7, r: 0.3 }; }
		if (!S.patch.fenv) { S.patch.fenv = { a: 0.01, d: 0.2, s: 0.0, r: 0.2 }; }
		if (!S.patch.filter) { S.patch.filter = { type: 'lowpass', cutoff: 3000, q: 1, env: 0, keytrack: 0 }; }
		if (!S.patch.lfo) { S.patch.lfo = { rate: 0, pitch: 0, cutoff: 0, amp: 0 }; }
	}

	function set(param, value) {
		patchShapes();
		if (param === 'preset') { return loadPreset(value); }
		if (param === 'wave') { S.patch.wave = value; }
		else if (param === 'drive') { S.patch.drive = clampNumber(value, 0, 1, 0); applyDrive(); }
		else if (param === 'voices') { S.patch.voices = clampNumber(value, 1, 64, 32); }
		else if (param === 'transpose') { S.patch.transpose = clampNumber(value, -36, 36, 0); }
		else if (param === 'filter.type') { S.patch.filter.type = value; }
		else if (param === 'filter.cutoff') { S.patch.filter.cutoff = clampNumber(value, 40, 18000, 3000); }
		else if (param === 'filter.q') { S.patch.filter.q = clampNumber(value, 0.0001, 30, 1); }
		else if (param === 'filter.env') { S.patch.filter.env = clampNumber(value, 0, 1, 0); }
		else if (param && param.indexOf('amp.') === 0) { S.patch.amp[param.slice(4)] = clampNumber(value, 0, 10, 0.1); }
		else if (param && param.indexOf('fenv.') === 0) { S.patch.fenv[param.slice(5)] = clampNumber(value, 0, 10, 0.1); }
		else if (param && param.indexOf('lfo.') === 0) { S.patch.lfo[param.slice(4)] = clampNumber(value, -20, 20, 0); applyLfo(); }
		else if (param && param.indexOf('osc1.') === 0) { S.patch.osc[0][param.slice(5)] = value; }
		else if (param && param.indexOf('osc2.') === 0) { S.patch.osc[1][param.slice(5)] = value; }
		return S.patch;
	}

	function setPatch(obj) {
		S.patch = copyPatch(obj || {});
		patchShapes();
		applyLfo(); applyDrive();
		return S.patch;
	}

	function getPatch() { return copyPatch(S.patch || PRESETS[S.preset]); }

	function loadPreset(name) {
		if (!PRESETS[name]) { return S.patch; }
		S.preset = name;
		S.patch = copyPatch(PRESETS[name]);
		applyLfo(); applyDrive();
		return S.patch;
	}

	// ---- USB MIDI (Web MIDI) ---------------------------------------------------

	function noteFromMidimessage(e) {
		var d = e.data;
		var cmd = d[0] & 0xf0;
		if (cmd === 0x90 && d[2] > 0) { noteOn(d[1], d[2] / 127); }
		else if (cmd === 0x80 || (cmd === 0x90 && d[2] === 0)) { noteOff(d[1]); }
		else if (cmd === 0xb0) {
			if (d[1] === 64) { S.sustain = d[2] >= 64; if (!S.sustain && S.sustainNotes.length) { S.sustainNotes.forEach(releaseNote); S.sustainNotes = []; } }
			else if (d[1] === 1) { S.mod = d[2] / 127; }
		}
		else if (cmd === 0xe0) { S.bend = ((d[2] << 7) + d[1] - 8192) / 8192; }
		midiListeners().forEach(function (fn) { try { fn(e); } catch (err) {} });
	}

	function midiListeners() { return S.midi.listeners || []; }

	function midiStart(cb) {
		if (cb) { S.midi.listeners.push(cb); }
		if (S.midi.access) { return Promise.resolve(S.midi.access); }
		if (!navigator.requestMIDIAccess) { return Promise.reject(new Error('Web MIDI is not available here')); }
		return navigator.requestMIDIAccess({ sysex: false }).then(function (access) {
			S.midi.access = access;
			refreshMidiInputs();
			access.onstatechange = function () { refreshMidiInputs(); };
			return access;
		});
	}

	function refreshMidiInputs() {
		S.midi.inputs = [];
		if (!S.midi.access) { return S.midi.inputs; }
		S.midi.access.inputs.forEach(function (input) {
			input.onmidimessage = noteFromMidimessage;
			S.midi.inputs.push({ id: input.id, name: input.name, manufacturer: input.manufacturer });
		});
		if (!S.midi.selected && S.midi.inputs.length) { S.midi.selected = S.midi.inputs[0].id; }
		return S.midi.inputs;
	}

	function selectMidi(id) {
		if (!S.midi.access) { return false; }
		S.midi.selected = id;
		S.midi.access.inputs.forEach(function (input) { input.onmidimessage = (input.id === id) ? noteFromMidimessage : null; });
		return true;
	}

	window.jawnosSynth = {
		attach: attach,
		detach: detach,
		context: function () { return S.ctx; },
		get out() { return S.out; },
		// the post-drive/compressor node, so the studio can tap the synth into a
		// channel without disturbing its own path to the speakers
		outputNode: function () { return S.comp || S.out; },
		noteOn: noteOn,
		noteOff: noteOff,
		allNotesOff: allNotesOff,
		releaseAll: allNotesOff,
		voices: voices,
		set: set,
		setPatch: setPatch,
		getPatch: getPatch,
		loadPreset: loadPreset,
		presets: function () { return Object.keys(PRESETS); },
		noteName: noteName,
		midi: {
			start: midiStart,
			devices: function () { return S.midi.inputs || []; },
			refresh: refreshMidiInputs,
			select: selectMidi,
			selected: function () { return S.midi.selected; },
			onnotes: function (fn) { S.midi.listeners.push(fn); }
		}
	};

	// ---- the standalone Synth window (kept working; the studio hosts the engine) --

	var pianoMidiBase = 60;

	window.pianoInit = function () {
		var Ctor = window.AudioContext || window.webkitAudioContext;
		// ride the studio's context when its window is already open, so the synth is
		// just another source there; otherwise make one of our own
		var ctx = (typeof studioAudio !== 'undefined' && studioAudio.ctx) ? studioAudio.ctx : null;
		if (!ctx) { if (!Ctor) { return null; } ctx = new Ctor(); }
		jawnosSynth.attach(ctx, ctx.destination);
		return ctx;
	};

	$(document).on('click', '#synth_toggle', function () {
		$.ajax({
			url: '/manager/synth',
			type: 'GET',
			data: { timestamp: Date.now(), window_maker: 'yes' },
			success: function (response) {
				windowMaker(response);
				pianoInit();
			}
		});
	});

	$(document).on('click', '.piano_key', function () {
		if (!jawnosSynth.context()) { pianoInit(); }
		var note = parseInt($(this).attr('note'), 10);
		if (isNaN(note)) { var n = $(this).text(); note = noteNameToMidi(n); }
		var preset = $('#synth_preset').val() || $('#synth_waveform').val();
		if (preset && jawnosSynth.presets().indexOf(preset) >= 0) { jawnosSynth.loadPreset(preset); }
		jawnosSynth.noteOn(note, 0.85);
		setTimeout(function () { jawnosSynth.noteOff(note); }, 700);
	});

	function noteNameToMidi(name) {
		var m = /^([A-Ga-g])(#|b)?(-?\d+)$/.exec(String(name).replace(/\s+/g, ''));
		if (!m) { return 60; }
		var base = NOTE_NAMES.indexOf(m[1].toUpperCase() + (m[2] === '#' ? '#' : ''));
		if (m[2] === 'b') { base = NOTE_NAMES.indexOf(m[1].toUpperCase()); base = (base + 11) % 12; }
		return base + (parseInt(m[3], 10) + 1) * 12;
	}
})();
