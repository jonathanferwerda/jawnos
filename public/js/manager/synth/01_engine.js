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

	// ---- note capture ----------------------------------------------------------
	// Studio records the notes the synth plays, so the lowest voice layer reports
	// every note edge: on when a voice is born, exactly one off when that voice is
	// released or stolen. Arp, Seq, Mono and MIDI all go through here because they
	// all end in a voice. The offline renderer's voices are silent to the tap, and
	// the tap is paused while it schedules them, so a render never looks like you
	// playing. `window.jawnosSynth.onnote` subscribes.
	var noteListeners = [];
	var offlineRendering = false;

	function noteEmit(on, note, velocity, at) {
		if (!noteListeners.length) { return; }
		var time = (S.ctx && !offlineRendering) ? S.ctx.currentTime : at;
		var event = { on: !!on, note: note, velocity: velocity, time: time };
		noteListeners.slice().forEach(function (fn) { try { fn(event); } catch (e) {} });
	}

	function noteTapOn(voice, at) {
		if (!voice || offlineRendering) { return; }
		voice.tapped = true;
		noteEmit(true, voice.note, voice.velocity, at);
	}

	function noteTapOff(voice, at) {
		if (!voice || !voice.tapped || voice.tappedOff) { return; }
		voice.tappedOff = true;
		if (offlineRendering) { return; }
		noteEmit(false, voice.note, voice.velocity, at);
	}

	function subscribeNote(fn) {
		if (typeof fn !== 'function') { return function () {}; }
		noteListeners.push(fn);
		return function () {
			var at = noteListeners.indexOf(fn);
			if (at >= 0) { noteListeners.splice(at, 1); }
		};
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
	// Built from the preset library (synth_presets.js, window.jawnosSynthFamilies):
	// twelve instruments, twenty sounds each, most popular first. A patch is the
	// family's base with the entry's overrides applied; loadPreset copies one and
	// set() tweaks it. Values are small numbers so the studio's 0..100 knobs map
	// onto them (see jawnosSynth.knob()).
	var PRESETS = {};
	var FAMILIES = [];
	var FAMILY_PRESETS = {};

	function presetOverride(patch, key, value) {
		if (key === 'engine' || key === 'wave' || key === 'noise' || key === 'damping' || key === 'brightness' || key === 'drive' || key === 'voices' || key === 'transpose') {
			patch[key] = value;
			return;
		}
		if (key.indexOf('osc1.') === 0) { patch.osc[0][key.slice(5)] = value; return; }
		if (key.indexOf('osc2.') === 0) {
			while (patch.osc.length < 2) { patch.osc.push({ octave: 0, detune: 0, level: 0.4 }); }
			patch.osc[1][key.slice(5)] = value;
			return;
		}
		var parts = key.split('.');
		var cur = patch;
		for (var n = 0; n < parts.length - 1; n++) { cur[parts[n]] = cur[parts[n]] || {}; cur = cur[parts[n]]; }
		cur[parts[parts.length - 1]] = value;
	}

	function buildPresets() {
		var fams = window.jawnosSynthFamilies;
		if (!fams || !fams.length) {
			// the data file did not ride this build: one usable fallback
			PRESETS = { 'Grand Piano': { engine: 'subtractive', wave: 'piano', noise: 0.16, voices: 32, osc: [{ octave: 0, detune: 0, level: 1 }, { octave: 0, detune: 4, level: 0.5 }], filter: { type: 'lowpass', cutoff: 3800, q: 0.6, env: 0.25, keytrack: 0.35 }, amp: { a: 0.004, d: 2.6, s: 0, r: 0.5 }, fenv: { a: 0.002, d: 1.4, s: 0, r: 0.4 }, lfo: { rate: 0, pitch: 0, cutoff: 0, amp: 0 } } };
			FAMILIES = ['Piano'];
			FAMILY_PRESETS = { 'Piano': ['Grand Piano'] };
			return;
		}
		PRESETS = {}; FAMILIES = []; FAMILY_PRESETS = {};
		fams.forEach(function (fam) {
			FAMILIES.push(fam.name);
			FAMILY_PRESETS[fam.name] = [];
			fam.presets.forEach(function (entry) {
				var name = entry[0];
				var patch = JSON.parse(JSON.stringify(fam.base));
				var over = entry[1] || {};
				Object.keys(over).forEach(function (k) { presetOverride(patch, k, over[k]); });
				patch.family = fam.name;
				PRESETS[name] = patch;
				FAMILY_PRESETS[fam.name].push(name);
			});
		});
	}
	buildPresets();
	var DEFAULT_PRESET = FAMILIES.length ? FAMILY_PRESETS[FAMILIES[0]][0] : 'Grand Piano';

	var S = {
		ctx: null,
		out: null,
		drive: null,
		comp: null,
		post: null,      // the mute point: comp -> post -> destination (and any channel tap)
		patch: null,
		preset: DEFAULT_PRESET,
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
		arp: { on: false, rate: 8, mode: 'up', octaves: 1, held: [], step: 0, timer: null },
		learn: { armed: null, map: {} },
		seq: { on: false, rate: 8, steps: 16, root: 60, rows: 13, cells: {}, step: 0, timer: null, listeners: [] },
		midi: { access: null, inputs: [], selected: null, listeners: [] },
		sound: synthSoundStored(),   // 'engine' | 'browser' — where the notes are made
		enginePlaying: false,
		enginePatchJson: null,
		engineBusy: false,
		engineWarned: false,
		enginePoll: null,
		muted: false,
		capture: false   // a Studio take records the browser graph, not the engine
	};

	function copyPatch(p) { return JSON.parse(JSON.stringify(p)); }

	// A patch parameter as a 0..100 knob: `to` maps a slider to the parameter, `from`
	// maps the parameter back to a slider (so loading a preset moves the knobs). One
	// table drives both the studio's Synth pedal and the standalone window.
	var KNOBS = {
		'filter.cutoff': { to: function (v) { return 40 * Math.pow(450, v / 100); }, from: function (c) { return 100 * Math.log(c / 40) / Math.log(450); } },
		'filter.q': { to: function (v) { return 0.1 + (v / 100) * 18; }, from: function (q) { return (q - 0.1) / 18 * 100; } },
		'filter.env': { to: function (v) { return v / 100; }, from: function (e) { return e * 100; } },
		'amp.a': { to: function (v) { return 0.001 + Math.pow(v / 100, 2) * 3; }, from: function (a) { return 100 * Math.sqrt(Math.max(0, (a - 0.001) / 3)); } },
		'amp.d': { to: function (v) { return 0.01 + Math.pow(v / 100, 2) * 4; }, from: function (d) { return 100 * Math.sqrt(Math.max(0, (d - 0.01) / 4)); } },
		'amp.s': { to: function (v) { return v / 100; }, from: function (s) { return s * 100; } },
		'amp.r': { to: function (v) { return 0.02 + Math.pow(v / 100, 2) * 4; }, from: function (r) { return 100 * Math.sqrt(Math.max(0, (r - 0.02) / 4)); } },
		'osc2.detune': { to: function (v) { return (v / 100) * 40 - 20; }, from: function (d) { return (d + 20) / 40 * 100; } },
		'lfo.rate': { to: function (v) { return (v / 100) * 12; }, from: function (r) { return r / 12 * 100; } },
		'lfo.pitch': { to: function (v) { return (v / 100) * 0.1; }, from: function (p) { return p / 0.1 * 100; } },
		'drive': { to: function (v) { return v / 100; }, from: function (d) { return d * 100; } }
	};

	function patchGet(path) {
		var cur = S.patch || PRESETS[S.preset];
		if (!cur) { return undefined; }
		if (path === 'osc1.detune' || path === 'osc2.detune') {
			var i = path === 'osc1.detune' ? 0 : 1;
			return (cur.osc && cur.osc[i]) ? cur.osc[i].detune : 0;
		}
		var parts = String(path).split('.');
		for (var n = 0; n < parts.length && cur != null; n++) { cur = cur[parts[n]]; }
		return cur;
	}

	function knobMap(name, value) { var k = KNOBS[name]; return k ? k.to(clampNumber(value, 0, 100, 50)) : value; }
	function knobPosition(name) { var k = KNOBS[name]; return k ? Math.max(0, Math.min(100, k.from(patchGet(name)))) : 50; }
	function learnPersist() { try { localStorage.setItem('synth_midi_learn', JSON.stringify(S.learn.map)); } catch (e) {} }
	function learnLoad() { try { var m = JSON.parse(localStorage.getItem('synth_midi_learn') || '{}'); if (m && typeof m === 'object') { S.learn.map = m; } } catch (e) {} }

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
		// the mute point: every consumer (the speakers, the studio tap) sits behind it
		S.post = ctx.createGain();
		S.post.gain.value = S.muted ? 0 : 1;
		S.out.connect(S.drive).connect(S.comp).connect(S.post).connect(destination || ctx.destination);
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
		learnLoad();
		applyLfo();
		applyDrive();
		enginePollEnsure();
		return S;
	}

	function detach() {
		if (S.enginePoll) { clearInterval(S.enginePoll); S.enginePoll = null; }
		S.enginePlaying = false; S.enginePatchJson = null; S.engineBusy = false;
		if (S.ctx) {
			try { S.lfo.stop(); } catch (e) {}
			Object.keys(S.voices).forEach(function (id) { killVoice(S.voices[id], true); });
			S.voices = {}; S.order = [];
			if (S.out && S.out.disconnect) { try { S.out.disconnect(); } catch (e) {} }
			if (S.post && S.post.disconnect) { try { S.post.disconnect(); } catch (e) {} }
		}
		S.ctx = null; S.out = null; S.drive = null; S.comp = null; S.post = null; S.lfo = null;
	}

	// The LFO depths and the drive curve are pure functions of the patch, so the
	// offline renderer can build the same master chain without the live nodes.
	function lfoParams(patch) {
		var l = (patch && patch.lfo) || {};
		return {
			rate: clampNumber(l.rate, 0, 20, 0),
			pitch: l.pitch || 0,
			cutoff: l.cutoff || 0,
			amp: l.amp || 0
		};
	}

	function driveCurve(amount) {
		amount = clampNumber(amount, 0, 1, 0);
		if (amount <= 0.001) { return null; }
		var n = 1024, curve = new Float32Array(n), k = amount * 40;
		for (var i = 0; i < n; i++) {
			var x = (i * 2) / n - 1;
			curve[i] = ((1 + k) * x) / (1 + k * Math.abs(x));
		}
		return curve;
	}

	function applyLfo() {
		if (!S.ctx) { return; }
		var l = lfoParams(S.patch);
		S.lfo.frequency.value = l.rate > 0 ? l.rate : 5;
		S.lfoPitch.gain.value = l.pitch * 1200;      // fraction of an octave
		S.lfoCutoff.gain.value = l.cutoff * 2400;
		S.lfoAmp.gain.value = l.amp * 0.5;
	}

	function applyDrive() {
		if (!S.drive || !S.ctx) { return; }
		S.drive.curve = driveCurve(S.patch.drive);
		if (S.drive.curve) { S.drive.oversample = '4x'; }
	}

	// ---- the arpeggiator: held notes are stepped through, in time ---------------

	function arpEnsure() {
		if (S.arp.timer) { return; }
		S.arp.timer = setInterval(arpTick, Math.max(20, 1000 / Math.max(0.5, S.arp.rate)));
	}

	function arpStop() {
		if (S.arp.timer) { clearInterval(S.arp.timer); S.arp.timer = null; }
		S.arp.step = 0;
	}

	function arpPattern() {
		var held = S.arp.held.slice();
		if (!held.length) { return []; }
		var notes = [];
		for (var o = 0; o < Math.max(1, S.arp.octaves); o++) {
			held.forEach(function (n) { notes.push(n + o * 12); });
		}
		notes.sort(function (a, b) { return a - b; });
		if (S.arp.mode === 'down') { notes.reverse(); }
		else if (S.arp.mode === 'updown' && notes.length > 2) { notes = notes.concat(notes.slice(1, -1).reverse()); }
		else if (S.arp.mode === 'random') { notes.sort(function () { return Math.random() - 0.5; }); }
		return notes;
	}

	function arpTick() {
		if (!S.arp.on || !S.arp.held.length) { arpStop(); return; }
		var pattern = arpPattern();
		if (!pattern.length) { return; }
		var note = pattern[S.arp.step % pattern.length];
		S.arp.step++;
		var gate = Math.max(40, (1000 / Math.max(0.5, S.arp.rate)) * 0.6);
		soundNote(note, 0.85);
		setTimeout(function () { releaseNote(note); }, gate);
	}

	// ---- the step sequencer: a looping grid of steps --------------------------

	function seqCellKey(row, step) { return row + ':' + step; }

	function seqEnsure() {
		if (S.seq.timer) { return; }
		S.seq.timer = setInterval(seqTick, Math.max(20, 1000 / Math.max(0.5, S.seq.rate)));
	}

	function seqStop() {
		if (S.seq.timer) { clearInterval(S.seq.timer); S.seq.timer = null; }
		S.seq.step = 0;
	}

	function seqTick() {
		if (!S.seq.on) { seqStop(); return; }
		var steps = Math.max(1, S.seq.steps);
		var step = S.seq.step % steps;
		var gate = Math.max(40, (1000 / Math.max(0.5, S.seq.rate)) * 0.6);
		for (var row = 0; row < S.seq.rows; row++) {
			if (!S.seq.cells[seqCellKey(row, step)]) { continue; }
			var note = S.seq.root + row;
			soundNote(note, 0.85);
			(function (n) { setTimeout(function () { releaseNote(n); }, gate); })(note);
		}
		S.seq.step = (step + 1) % steps;
		S.seq.listeners.forEach(function (fn) { try { fn(S.seq.step); } catch (e) {} });
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

	// A voice's surroundings are explicit, so the offline renderer can speak the
	// same DSP on its own context, patch, output and start time without reading
	// the live S.* graph.
	function liveVoiceContext() {
		return {
			ctx: S.ctx,
			patch: S.patch,
			out: S.out,
			start: S.ctx.currentTime,
			bend: S.bend || 0,
			mod: S.mod || 0,
			lfoPitch: S.lfoPitch,
			lfoCutoff: S.lfoCutoff,
			offline: false
		};
	}

	function newVoice(note, velocity, glideFrom, vctx) {
		var host = vctx || liveVoiceContext();
		var ctx = host.ctx, p = host.patch, out = host.out;
		var t0 = host.start;
		var freq = midiToFreq(note + (p.transpose || 0));
		if (!host.offline) { S.lastFreq = freq; }
		var amp = ctx.createGain();
		amp.gain.value = 0.0001;
		amp.connect(out);
		var voice = { id: S.nextId++, note: note, freq: freq, velocity: velocity, amp: amp, nodes: [], released: false, started: t0 };

		if (p.engine === 'pluck') {
			var period = 1 / freq;
			var delay = ctx.createDelay(0.05);
			delay.delayTime.value = period;
			var damp = ctx.createBiquadFilter();
			damp.type = 'lowpass';
			// a harder strike opens the loop filter (velocity is timbre, not only level)
			damp.frequency.value = Math.min(18000, freq * (2 + (p.brightness || 0.5) * 12) * (0.6 + 0.8 * velocity));
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
				noteTapOff(voice, t1);
				var r = Math.max(0.05, (p.amp && p.amp.r) || 0.35);
				amp.gain.cancelScheduledValues(t1);
				if (amp.gain.cancelAndHoldAtTime) { amp.gain.cancelAndHoldAtTime(t1); }
				amp.gain.setTargetAtTime(0.0001, t1, r / 4);
				// only the live graph needs the cleanup timer; an offline render ends
				// with its buffer and must not leave a timer behind
				if (!host.offline) { setTimeout(function () { killVoice(voice, false); }, (r + 0.1) * 1000); }
			};
			if (!host.offline) { noteTapOn(voice, t0); }
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
			var detune = host.bend * 200 + (o.detune || 0) + (host.mod * 50);
			if (waveType && !o.wave) { osc.setPeriodicWave(waveType); }
			else { osc.type = o.wave || p.wave || 'sawtooth'; }
			var oct = Math.pow(2, o.octave || 0);
			var target = freq * oct;
			var glide = clampNumber(p.glide, 0, 3, 0);
			if (glideFrom && glide > 0) {
				osc.frequency.setValueAtTime(Math.max(1, glideFrom * oct), t0);
				osc.frequency.exponentialRampToValueAtTime(Math.max(1, target), t0 + glide);
			}
			else { osc.frequency.value = target; }
			osc.detune.value = detune;
			var g = ctx.createGain();
			g.gain.value = (o.level == null ? 1 : o.level) / Math.max(1, oscLevels.length);
			osc.connect(g).connect(mix);
			osc.start(t0);
			voice.nodes.push(osc, g);
			voice.oscs = voice.oscs || [];
			voice.oscs.push(osc);
			if (host.lfoPitch) { host.lfoPitch.connect(osc.detune); }
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
		if (host.lfoCutoff) { host.lfoCutoff.connect(filter.frequency); }
		filterEnv(filter, ((p.filter && p.filter.cutoff) || 3000) * (0.6 + 0.7 * velocity), (p.fenv && { a: p.fenv.a, d: p.fenv.d, s: p.fenv.s, amount: (p.filter && p.filter.env) || 0 }) || { a: 0.01, d: 0.2, s: 0, amount: 0 }, t0, (p.filter && p.filter.keytrack) || 0, freq);
		voiceEnv(amp.gain, p.amp || { a: 0.01, d: 0.3, s: 0.7, r: 0.3 }, t0, 0.25 + velocity * 0.6);
		voice.stopSoon = function (t1) {
			noteTapOff(voice, t1);
			var r = Math.max(0.02, (p.amp && p.amp.r) || 0.3);
			amp.gain.cancelScheduledValues(t1);
			if (amp.gain.cancelAndHoldAtTime) { amp.gain.cancelAndHoldAtTime(t1); }
			amp.gain.setTargetAtTime(0.0001, t1, r / 4);
			(voice.oscs || []).forEach(function (osc) { try { osc.stop(t1 + r + 0.1); } catch (e) {} });
			if (!host.offline) { setTimeout(function () { killVoice(voice, false); }, (r + 0.2) * 1000); }
		};
		if (!host.offline) { noteTapOn(voice, t0); }
		return voice;
	}

	function killVoice(voice, immediate) {
		if (!voice || voice.dead) { return; }
		// a stolen voice still owes its one off, even if its release never came
		noteTapOff(voice, S.ctx ? S.ctx.currentTime : voice.started);
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
		while (S.order.length > max) {
			var oldest = S.voices[S.order[0]];
			if (!oldest) { S.order.shift(); continue; }
			try { oldest.amp.gain.cancelScheduledValues(S.ctx.currentTime); } catch (e) {}
			killVoice(oldest, true);
		}
	}

	function soundNote(note, velocity, glideFrom) {
		var v = newVoice(note, velocity, glideFrom);
		S.voices[v.id] = v;
		S.order.push(v.id);
		stealing();
	}

	// Mono (with glide): one voice, moving to the new note instead of stacking.
	function monoOn(note, velocity) {
		var glideFrom = S.lastFreq;
		var now = S.ctx.currentTime;
		Object.keys(S.voices).forEach(function (id) {
			var v = S.voices[id];
			if (!v.released && v.stopSoon) { v.released = true; v.stopSoon(now); }
		});
		soundNote(note, velocity, (S.patch.glide > 0) ? glideFrom : 0);
	}

	function noteOn(note, velocity) {
		if (!S.ctx) { return; }
		note = Math.round(clampNumber(note, 0, 127, 60));
		velocity = clampNumber(velocity, 0, 1, 0.8);
		engineNote(note, velocity, true);
		S.playing[note] = true;
		if (S.arp.on) {
			if (S.arp.held.indexOf(note) === -1) { S.arp.held.push(note); }
			arpEnsure();
			return;
		}
		if (S.patch && S.patch.mono) { monoOn(note, velocity); return; }
		soundNote(note, velocity);
	}

	function noteOff(note) {
		if (!S.ctx) { return; }
		note = Math.round(clampNumber(note, 0, 127, 60));
		engineNote(note, 0, false);
		if (S.arp.on) {
			var at = S.arp.held.indexOf(note);
			if (at >= 0) { S.arp.held.splice(at, 1); }
			if (!S.arp.held.length) { arpStop(); }
			return;
		}
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
		engineAllOff();
		S.sustainNotes = [];
		arpStop();
		S.arp.held = [];
		Object.keys(S.voices).forEach(function (id) {
			var v = S.voices[id];
			if (!v.released) { v.released = true; if (v.stopSoon) { v.stopSoon(S.ctx.currentTime); } }
		});
		S.playing = {};
	}

	function voices() { return Object.keys(S.voices).length; }

	// ---- offline render --------------------------------------------------------
	// Studio renders a loop to a buffer for browser playback: the same voices and
	// the same master chain on a fresh OfflineAudioContext. Notes are in beats, so
	// a tempo change only re-renders; the live graph is never touched.
	// opts = { notes: [{ n, t, d, v }], patch, bpm, beats, rate }
	function render(opts) {
		opts = opts || {};
		var notes = Array.isArray(opts.notes) ? opts.notes.slice() : [];
		var bpm = clampNumber(opts.bpm, 1, 400, 120);
		var rate = Math.round(clampNumber(opts.rate, 8000, 96000, 44100));
		var secondsPerBeat = 60 / bpm;
		var beats = clampNumber(opts.beats, 0, 4096, 0);
		if (!(beats > 0)) {
			notes.forEach(function (n) {
				beats = Math.max(beats, (Number(n.t) || 0) + (Number(n.d) || 0));
			});
		}
		if (!(beats > 0)) { beats = 1; }
		var length = Math.max(1, Math.ceil(beats * 60 / bpm * rate));

		var Ctor = window.OfflineAudioContext || window.webkitOfflineAudioContext;
		if (!Ctor) { return Promise.reject(new Error('OfflineAudioContext is not available here')); }
		var ctx;
		try { ctx = new Ctor(2, length, rate); } catch (e) { return Promise.reject(e); }

		// the same master chain as attach(): out -> drive -> compressor -> post
		var out = ctx.createGain();
		var shaper = ctx.createWaveShaper();
		var comp = ctx.createDynamicsCompressor();
		comp.threshold.value = -12;
		comp.ratio.value = 4;
		var post = ctx.createGain();          // mute-free: a render is what was played
		post.gain.value = 1;
		out.connect(shaper).connect(comp).connect(post).connect(ctx.destination);
		var patch = patchArg(opts);
		var curve = driveCurve(patch.drive);
		if (curve) { shaper.curve = curve; shaper.oversample = '4x'; }

		// the shared LFO with the same three taps the live voices read
		var lfo = ctx.createOscillator();
		lfo.type = 'sine';
		var depths = lfoParams(patch);
		lfo.frequency.value = depths.rate > 0 ? depths.rate : 5;
		var lfoPitch = ctx.createGain();
		var lfoCutoff = ctx.createGain();
		var lfoAmp = ctx.createGain();
		lfoPitch.gain.value = depths.pitch * 1200;
		lfoCutoff.gain.value = depths.cutoff * 2400;
		lfoAmp.gain.value = depths.amp * 0.5;
		lfo.connect(lfoPitch);
		lfo.connect(lfoCutoff);
		lfo.connect(lfoAmp);
		lfoAmp.connect(out.gain);
		lfo.start(0);

		notes.sort(function (a, b) { return (Number(a.t) || 0) - (Number(b.t) || 0); });
		var mono = !!patch.mono;
		var current = null, lastFreq = 0;
		var scheduleError = null;
		offlineRendering = true;
		try {
			notes.forEach(function (n) {
				var note = Math.round(clampNumber(n.n, 0, 127, 60));
				var at = Math.max(0, (Number(n.t) || 0) * secondsPerBeat);
				var d = Math.max(0.01, (Number(n.d) || 0) * secondsPerBeat);
				var velocity = clampNumber(n.v, 0, 1, 0.8);
				var glideFrom = 0;
				if (mono) {
					if (current && current.stopSoon) { current.released = true; current.stopSoon(at); }
					glideFrom = (patch.glide > 0) ? lastFreq : 0;
				}
				var v = newVoice(note, velocity, glideFrom, {
					ctx: ctx, patch: patch, out: out, start: at,
					bend: 0, mod: 0, lfoPitch: lfoPitch, lfoCutoff: lfoCutoff,
					offline: true
				});
				lastFreq = v.freq;
				if (mono) { current = v; }
				v.released = true;
				if (v.stopSoon) { v.stopSoon(at + d); }
			});
		} catch (e) {
			scheduleError = e;
		} finally {
			offlineRendering = false;      // the tap is live again: no renderer voice is left to make
		}
		if (scheduleError) { return Promise.reject(scheduleError); }

		var rendering;
		try { rendering = ctx.startRendering(); } catch (e) { return Promise.reject(e); }
		return Promise.resolve(rendering);
	}

	function patchArg(opts) {
		var patch = copyPatch(opts.patch || S.patch || PRESETS[S.preset]);
		return patchDefaults(patch);
	}

	// ---- patch access ----------------------------------------------------------

	function patchDefaults(patch) {
		if (!patch.osc) { patch.osc = [{ octave: 0, detune: 0, level: 1 }, { octave: 0, detune: 0, level: 0.4 }]; }
		if (!patch.amp) { patch.amp = { a: 0.01, d: 0.3, s: 0.7, r: 0.3 }; }
		if (!patch.fenv) { patch.fenv = { a: 0.01, d: 0.2, s: 0.0, r: 0.2 }; }
		if (!patch.filter) { patch.filter = { type: 'lowpass', cutoff: 3000, q: 1, env: 0, keytrack: 0 }; }
		if (!patch.lfo) { patch.lfo = { rate: 0, pitch: 0, cutoff: 0, amp: 0 }; }
		if (patch.mono == null) { patch.mono = false; }
		if (patch.glide == null) { patch.glide = 0; }
		return patch;
	}

	function patchShapes() {
		if (!S.patch) { S.patch = copyPatch(PRESETS[S.preset]); }
		patchDefaults(S.patch);
	}

	function set(param, value) {
		patchShapes();
		if (param === 'preset') { return loadPreset(value); }
		if (param === 'wave') { S.patch.wave = value; }
		else if (param === 'drive') { S.patch.drive = clampNumber(value, 0, 1, 0); applyDrive(); }
		else if (param === 'mono') { S.patch.mono = (value === true || value === 1 || value === '1' || value === 'on'); if (S.patch.mono) { allNotesOff(); } }
		else if (param === 'glide') { S.patch.glide = clampNumber(value, 0, 3, 0); }
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

	// ---- the JawnOS engine voice ----------------------------------------------
	//
	// While the engine transport plays, the same patch can be rendered natively by
	// the JawnOS engine. The browser voices keep running (so the API, voices() and
	// the UI do not change) but the browser output is muted, so the listener hears
	// one synth, not two. The browser is the fallback: any refusal, and any status
	// that is not 'playing', makes it audible again on the next tick.

	function synthSoundStored() {
		try { return (localStorage.getItem('jawnos_synth_sound') === 'browser') ? 'browser' : 'engine'; } catch (e) { return 'engine'; }
	}

	function applyMute(on) {
		S.muted = !!on;
		if (S.post) { S.post.gain.value = S.muted ? 0 : 1; }
	}

	// A Studio take records the browser graph, so while capture is on the browser
	// voices stay audible even when the Sound choice is the engine (which keeps
	// playing the rest of the song) and no live note is sent to the engine. The
	// saved Sound choice and its panel select are untouched; turning capture off
	// hands the mute decision back to engineSyncOutput().
	function synthCapture(on) {
		on = !!on;
		if (on === S.capture) { return S.capture; }
		S.capture = on;
		if (on) {
			engineAllOff();          // the browser take owns the live notes now
			applyMute(false);        // the take records post -> channel, so it must sound
		}
		else {
			engineSyncOutput();
		}
		return S.capture;
	}

	function engineSyncOutput() {
		applyMute(!S.capture && S.sound === 'engine' && S.enginePlaying);
	}

	function engineFallback() {
		S.enginePlaying = false;
		S.enginePatchJson = null;
		engineSyncOutput();
		if (!S.engineWarned) {
			S.engineWarned = true;
			console.warn('synth: the JawnOS engine did not take the synth; using the browser');
		}
	}

	function engineApi(action, extra, done) {
		var data = { action: action };
		if (extra) { $.extend(data, extra); }
		$.ajax({ url: '/manager/studio/synth', type: 'POST', data: data, dataType: 'json' })
			.done(function (answer) {
				if (answer && answer.ok) { S.engineWarned = false; } else { engineFallback(); }
				if (done) { done(answer || null); }
			})
			.fail(function () {
				engineFallback();
				if (done) { done(null); }
			});
	}

	function engineSendPatch() {
		var json = JSON.stringify(getPatch());
		if (json === S.enginePatchJson) { return; }
		S.enginePatchJson = json;
		engineApi('patch', { patch_json: json }, function (answer) {
			if (!answer || !answer.ok) { S.enginePatchJson = null; }   // send it again when it plays
		});
	}

	function engineLive() { return S.sound === 'engine' && S.enginePlaying && !!S.ctx; }

	function engineNote(note, velocity, on) {
		// while a Studio take captures the browser graph, the engine must not sound
		// a second voice for the same key
		if (S.capture || !engineLive()) { return; }
		engineApi('note', { note: note, velocity: velocity, on: on ? 1 : 0 });
	}

	function engineAllOff() {
		if (!engineLive()) { return; }
		engineApi('all_off');
	}

	function engineTick() {
		if (!S.ctx || S.engineBusy || S.sound !== 'engine') { return; }
		S.engineBusy = true;
		$.ajax({ url: '/manager/studio/transport', type: 'POST', data: { action: 'status' }, dataType: 'json' })
			.done(function (answer) {
				S.engineBusy = false;
				var playing = !!(answer && answer.ok && answer.transport && answer.transport.state === 'playing');
				var was = S.enginePlaying;
				S.enginePlaying = playing;
				engineSyncOutput();             // mute first, before the patch goes over
				if (playing) { engineSendPatch(); }
				else if (was) { S.enginePatchJson = null; }
			})
			.fail(function () {
				S.engineBusy = false;
				engineFallback();               // no answer: the browser sounds
			});
	}

	function enginePollEnsure() {
		if (S.enginePoll) { clearInterval(S.enginePoll); S.enginePoll = null; }
		if (!S.ctx || S.sound !== 'engine') { return; }
		S.enginePoll = setInterval(engineTick, 500);
		engineTick();
	}

	function synthSetSound(mode) {
		var next = (mode === 'browser') ? 'browser' : 'engine';
		if (next === 'browser') { engineAllOff(); }   // do not leave engine voices under the browser
		S.sound = next;
		try { localStorage.setItem('jawnos_synth_sound', S.sound); } catch (e) {}
		if (S.sound !== 'engine') { S.enginePlaying = false; S.enginePatchJson = null; }
		engineSyncOutput();
		enginePollEnsure();
		$('.synth_sound').val(S.sound);
	}

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
			// MIDI learn: the next CC binds the armed parameter; mapped CCs drive theirs
			if (S.learn.armed) { S.learn.map[d[1]] = S.learn.armed; S.learn.armed = null; learnPersist(); }
			else if (S.learn.map[d[1]]) { set(S.learn.map[d[1]], knobMap(S.learn.map[d[1]], d[2] / 127 * 100)); }
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
		// the post-drive/compressor master (the mute point), so the studio can tap
		// the synth into a channel without disturbing its own path to the speakers
		outputNode: function () { return S.post || S.comp || S.out; },
		// silence the browser output while the engine renders the patch; the voices
		// keep running, so voices() and the UI do not change
		mute: function (on) { applyMute(!!on); },
		noteOn: noteOn,
		noteOff: noteOff,
		allNotesOff: allNotesOff,
		releaseAll: allNotesOff,
		voices: voices,
		// Studio captures note clips through the same voice layer (Arp, Seq, Mono
		// and MIDI included) and renders a loop offline for playback.
		onnote: subscribeNote,
		render: render,
		// the computer-keyboard ownership the Studio drum map can ask about
		keysOn: function () { return keyboardOn; },
		keysOwned: keysOwned,
		// a Studio take records the browser graph: audible browser voices and no
		// engine notes while on, the normal Sound choice restored when off
		capture: synthCapture,
		seq: {
			set: function (opts) {
				opts = opts || {};
				if ('on' in opts) { S.seq.on = !!opts.on; if (S.seq.on) { seqEnsure(); } else { seqStop(); } }
				if ('rate' in opts) { S.seq.rate = clampNumber(opts.rate, 0.5, 30, 8); if (S.seq.timer) { seqStop(); seqEnsure(); } }
				if ('steps' in opts) { S.seq.steps = Math.round(clampNumber(opts.steps, 4, 32, 16)); S.seq.step = 0; }
				if ('root' in opts) { S.seq.root = Math.round(clampNumber(opts.root, 12, 108, 60)); }
				return S.seq.on;
			},
			toggleCell: function (row, step) {
				var key = seqCellKey(row, step);
				if (S.seq.cells[key]) { delete S.seq.cells[key]; } else { S.seq.cells[key] = 1; }
				return !!S.seq.cells[key];
			},
			cell: function (row, step) { return !!S.seq.cells[seqCellKey(row, step)]; },
			clear: function () { S.seq.cells = {}; },
			setCells: function (cells) { S.seq.cells = cells || {}; },
			get: function () { return { on: S.seq.on, rate: S.seq.rate, steps: S.seq.steps, root: S.seq.root, rows: S.seq.rows, cells: JSON.parse(JSON.stringify(S.seq.cells)) }; },
			onstep: function (fn) { S.seq.listeners.push(fn); }
		},
		arp: {
			set: function (opts) {
				opts = opts || {};
				if ('on' in opts) { S.arp.on = !!opts.on; if (!S.arp.on) { arpStop(); S.arp.held = []; } }
				if ('rate' in opts) { S.arp.rate = clampNumber(opts.rate, 0.5, 30, 8); if (S.arp.timer) { arpStop(); arpEnsure(); } }
				if ('mode' in opts) { S.arp.mode = String(opts.mode); }
				if ('octaves' in opts) { S.arp.octaves = Math.round(clampNumber(opts.octaves, 1, 4, 1)); }
				if (S.arp.on && S.arp.held.length) { arpEnsure(); }
				return S.arp.on;
			},
			get: function () { return { on: S.arp.on, rate: S.arp.rate, mode: S.arp.mode, octaves: S.arp.octaves }; }
		},
		set: set,
		setPatch: setPatch,
		getPatch: getPatch,
		loadPreset: loadPreset,
		presets: function () { return Object.keys(PRESETS); },
		families: function () { return FAMILIES.slice(); },
		familyPresets: function (family) { return (FAMILY_PRESETS[family] || []).slice(); },
		presetName: function () { return S.preset; },
		// the 0..100 knob view of a patch parameter, shared by the studio pedal and
		// the standalone window
		knob: knobMap,
		knobPos: knobPosition,
		setKnob: function (name, value) { return set(name, knobMap(name, value)); },
		learn: {
			start: function (param) { S.learn.armed = param || null; return S.learn.armed; },
			cancel: function () { S.learn.armed = null; },
			armed: function () { return S.learn.armed; },
			map: function () { return JSON.parse(JSON.stringify(S.learn.map)); },
			clear: function () { S.learn.map = {}; learnPersist(); }
		},
		knobNames: function () { return Object.keys(KNOBS); },
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

	// A full 88-key range (A0..C8), built here so the layout is exact: the white
	// keys flow inline and the black keys sit absolutely over the boundaries.
	var SYNTH_FIRST = 21, SYNTH_LAST = 108, WHITE_W = 26, BLACK_W = 16;

	function synthIsBlack(n) {
		var p = ((n % 12) + 12) % 12;
		return p === 1 || p === 3 || p === 6 || p === 8 || p === 10;
	}

	function synthBuildKeys() {
		$('.synth_keys').each(function () {
			var host = $(this);
			if (host.data('built')) { return; }
			host.empty();
			// the keys live in an inner strip of full width, so the roll itself is only
			// ever as wide as its container and the mouse scrolls the strip inside it
			var inner = $('<div class="synth_keys_inner"></div>');
			host.append(inner);
			var whiteCount = 0, i;
			for (i = SYNTH_FIRST; i <= SYNTH_LAST; i++) {
				if (synthIsBlack(i)) { continue; }
				var key = $('<div class="piano_key white"></div>').attr('midi', i).attr('note', i).css('width', WHITE_W + 'px');
				if (i % 12 === 0) { key.text('C' + (i / 12 - 1)); }
				inner.append(key);
				whiteCount++;
			}
			var seen = 0;
			for (i = SYNTH_FIRST; i <= SYNTH_LAST; i++) {
				if (!synthIsBlack(i)) { seen++; continue; }
				var black = $('<div class="piano_key black"></div>').attr('midi', i).attr('note', i);
				black.css('left', (seen * WHITE_W - BLACK_W / 2) + 'px');
				inner.append(black);
			}
			inner.css('width', (whiteCount * WHITE_W) + 'px');
			host.data('built', 1);
		});
	}

	// Bring the octave the computer keyboard is on into view, centred in whatever
	// width each roll's window gives it.
	function synthFocusOctave() {
		$('.synth_keys').each(function () {
			var host = $(this);
			if (!host.data('built')) { return; }
			var base = keyboardOctave * 12 + 12;
			var key = host.find('.piano_key[midi="' + base + '"]');
			if (!key.length) { return; }
			var octaveW = 7 * WHITE_W;
			var target = key.position().left - Math.max(0, (host.width() - octaveW) / 2);
			host.stop(true).animate({ scrollLeft: Math.max(0, target) }, 180);
		});
	}

	// The computer keyboard plays the piano: the usual A W S E D F T G Y H U J K row,
	// Z/X shift the octave. Off until the Keys button turns it on, and it never
	// steals a keypress aimed at a form field. The key handler only sounds while a
	// synth host owns the last press: the standalone Synth window's roll or the
	// Studio panel (`#studio_synth`). Clicking anywhere else hands the keys back, so
	// the Studio drum map can play too.
	var keyboardOn = false, keyboardOctave = 4, keyboardHeld = {};
	var keyboardOwner = null;   // 'standalone' | 'studio' | null
	var KEYMAP = { a: 0, w: 1, s: 2, e: 3, d: 4, f: 5, t: 6, g: 7, y: 8, h: 9, u: 10, j: 11, k: 12, o: 13, l: 14, p: 15, ';': 16, "'": 17 };

	function synthKeyboardNote(k) { return keyboardOctave * 12 + 12 + KEYMAP[k]; }

	// Which synth host an element belongs to: Studio's own panel, or the standalone
	// Synth window's roll (a #synth that is not the Studio panel's body).
	function synthOwnerFor(el) {
		if (!el) { return null; }
		var $el = $(el);
		if (!$el.length) { return null; }
		if ($el.closest('#studio_synth').length) { return 'studio'; }
		if ($el.closest('.wind[app="synth"]').length) { return 'standalone'; }
		if ($el.closest('#synth').length && !$el.closest('#studio').length) { return 'standalone'; }
		return null;
	}

	function standaloneSynthHost() {
		return $('#synth').filter(function () { return !$(this).closest('#studio_synth').length; }).length > 0;
	}

	// Answered for the Studio drum map: is the synth's computer keyboard the owner
	// of key events right now (and, when an element is given, does it belong to
	// that owner)? False unless Keys is on and a synth host owns the last press.
	function keysOwned(el) {
		if (!keyboardOn || !keyboardOwner) { return false; }
		if (!el) { return true; }
		var owner = synthOwnerFor(el);
		return !owner || owner === keyboardOwner;
	}

	function synthKeysOwned(e) {
		if (!keyboardOn) { return false; }
		var owner = synthOwnerFor(e && e.target);
		if (owner) { keyboardOwner = owner; }
		return !!keyboardOwner;
	}

	function synthRenderOctave() { $('.synth_octave').text('octave ' + keyboardOctave); }

	// The standalone window's controls. The studio's Synth pedal drives the same
	// engine through KNOBS, so a patch set in one place reads the same in the other.
	function synthSyncSliders() {
		$('.synth_param').each(function () {
			var param = $(this).attr('param');
			if (param) { $(this).val(Math.round(window.jawnosSynth.knobPos(param))); }
		});
	}

	function synthPopulatePresets() {
		$('.synth_preset').each(function () {
			var sel = $(this);
			if (sel.data('filled')) { return; }
			window.jawnosSynth.families().forEach(function (fam) {
				var group = $('<optgroup></optgroup>').attr('label', fam);
				window.jawnosSynth.familyPresets(fam).forEach(function (name) {
					group.append($('<option></option>').attr('value', name).text(name));
				});
				sel.append(group);
			});
			sel.data('filled', 1);
			sel.val(window.jawnosSynth.presetName());
		});
	}

	function synthPopulateMidi() {
		var hosts = $('.synth_midi');
		if (!hosts.length) { return; }
		var devs = window.jawnosSynth.midi.devices();
		hosts.each(function () {
			var sel = $(this);
			sel.empty();
			if (!devs.length) { sel.append($('<option></option>').attr('value', '').text('no MIDI device')); return; }
			devs.forEach(function (d) { sel.append($('<option></option>').attr('value', d.id).text(d.name || d.manufacturer || d.id)); });
			sel.val(window.jawnosSynth.midi.selected() || '');
		});
	}

	// Make sure the engine is running on whatever context is at hand: the studio's
	// own when its window is open (so a studio-hosted panel rides it), else a new one.
	function synthEnsureAudio() {
		var current = window.jawnosSynth.context();
		if (current) {
			// A host that built its context at page load, or a Studio page whose
			// context was replaced, can be suspended until a gesture. The first
			// key is that gesture, so resume the graph it will play on.
			if (current.state === 'suspended' && typeof current.resume === 'function') {
				try { current.resume(); } catch (e) {}
			}
			return;
		}
		var Ctor = window.AudioContext || window.webkitAudioContext;
		var ctx = (typeof studioAudio !== 'undefined' && studioAudio.ctx) ? studioAudio.ctx : (Ctor ? new Ctor() : null);
		if (ctx) { window.jawnosSynth.attach(ctx, ctx.destination); }
	}

	window.pianoInit = function () {
		var Ctor = window.AudioContext || window.webkitAudioContext;
		// ride the studio's context when its window is already open, so the synth is
		// just another source there; otherwise make one of our own
		var ctx = (typeof studioAudio !== 'undefined' && studioAudio.ctx) ? studioAudio.ctx : null;
		if (!ctx) { if (!Ctor) { return null; } ctx = new Ctor(); }
		jawnosSynth.attach(ctx, ctx.destination);
		synthBuildKeys();
		synthBuildSeq();
		synthPopulatePresets();
		synthSyncSliders();
		synthPopulateMidi();
		synthPopulateLearn();
		synthRenderOctave();
		synthFocusOctave();
		// opening the standalone Synth window hands it the computer keyboard; the
		// Studio panel only takes it once it is clicked
		if (standaloneSynthHost()) { keyboardOwner = 'standalone'; }
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

	$(document).on('mousedown touchstart', '.piano_key', function (e) {
		synthEnsureAudio();
		var note = parseInt($(this).attr('midi'), 10);
		if (isNaN(note)) { note = noteNameToMidi($(this).attr('note')); }
		if (isNaN(note)) { return; }
		$(this).addClass('piano_key_on');
		jawnosSynth.noteOn(note, 0.85);
		e.preventDefault();
	});

	$(document).on('mouseup touchend mouseleave', '.piano_key', function () {
		var note = parseInt($(this).attr('midi'), 10);
		if (isNaN(note)) { return; }
		$(this).removeClass('piano_key_on');
		jawnosSynth.noteOff(note);
	});

	$(document).on('change', '.synth_preset', function () {
		window.jawnosSynth.loadPreset($(this).val());
		$('.synth_preset').val($(this).val());
		synthSyncSliders();
	});

	$(document).on('change', '.synth_sound', function () {
		synthSetSound($(this).val());
	});

	$(document).on('input change', '.synth_param', function () {
		synthEnsureAudio();
		window.jawnosSynth.setKnob($(this).attr('param'), $(this).val());
	});

	$(document).on('click', '.synth_midi_connect', function () {
		var el = $(this);
		el.text('connecting…');
		window.jawnosSynth.midi.start().then(function () {
			synthPopulateMidi();
			$('.synth_midi_connect').text(window.jawnosSynth.midi.devices().length ? 'MIDI ready' : 'no MIDI device');
		}).catch(function () { $('.synth_midi_connect').text('MIDI unavailable'); });
	});

	$(document).on('change', '.synth_midi', function () {
		window.jawnosSynth.midi.select($(this).val());
		$('.synth_midi').val($(this).val());
	});

	$(document).on('click', '.synth_keyboard_toggle', function () {
		keyboardOn = !keyboardOn;
		$('.synth_keyboard_toggle').text('Keys: ' + (keyboardOn ? 'on' : 'off'));
		if (!keyboardOn) {
			Object.keys(keyboardHeld).forEach(function (k) {
				jawnosSynth.noteOff(keyboardHeld[k]);
				$('.piano_key[midi="' + keyboardHeld[k] + '"]').removeClass('piano_key_on');
			});
			keyboardHeld = {};
		}
		else { synthEnsureAudio(); }
		synthFocusOctave();
	});

	$(document).on('click', '.synth_arp_toggle', function () {
		var on = window.jawnosSynth.arp.get().on;
		window.jawnosSynth.arp.set({ on: !on });
		$('.synth_arp_toggle').text('Arp: ' + (!on ? 'on' : 'off'));
	});

	$(document).on('change', '.synth_arp_rate, .synth_arp_mode, .synth_arp_octaves', function () {
		window.jawnosSynth.arp.set({
			rate: $('.synth_arp_rate').val(),
			mode: $('.synth_arp_mode').val(),
			octaves: $('.synth_arp_octaves').val()
		});
		var g = window.jawnosSynth.arp.get();
		$('.synth_arp_rate').val(String(g.rate));
		$('.synth_arp_mode').val(g.mode);
		$('.synth_arp_octaves').val(String(g.octaves));
	});

	// ---- mono / glide ---------------------------------------------------------
	$(document).on('click', '.synth_mono_toggle', function () {
		var mono = window.jawnosSynth.getPatch().mono;
		window.jawnosSynth.set('mono', !mono);
		$('.synth_mono_toggle').text('Mono: ' + (!mono ? 'on' : 'off'));
	});
	$(document).on('input change', '.synth_glide', function () {
		var ms = parseFloat($(this).val());
		window.jawnosSynth.set('glide', ms / 1000);
		$('.synth_glide').val(String(ms));
	});

	// ---- MIDI learn -----------------------------------------------------------
	function synthPopulateLearn() {
		$('.synth_learn_param').each(function () {
			var sel = $(this);
			if (sel.data('filled')) { return; }
			window.jawnosSynth.knobNames().forEach(function (name) {
				sel.append($('<option></option>').attr('value', name).text(name));
			});
			sel.data('filled', 1);
		});
	}
	$(document).on('click', '.synth_learn', function () {
		var param = $('.synth_learn_param').val();
		window.jawnosSynth.learn.start(param);
		$('.synth_learn_state').text('learning ' + param + ' — move a knob');
	});
	$(document).on('click', '.synth_learn_clear', function () {
		window.jawnosSynth.learn.clear();
		$('.synth_learn_state').text('learned cleared');
	});

	// ---- step sequencer -------------------------------------------------------
	function synthBuildSeq() {
		$('.synth_seq').each(function () {
			var host = $(this);
			host.empty();
			var g = window.jawnosSynth.seq.get();
			for (var row = g.rows - 1; row >= 0; row--) {
				var line = $('<div class="synth_seq_row"></div>');
				line.append($('<span class="synth_seq_label"></span>').text(window.jawnosSynth.noteName(g.root + row)));
				for (var step = 0; step < g.steps; step++) {
					var cell = $('<span class="synth_seq_cell"></span>').attr('row', row).attr('step', step);
					if (window.jawnosSynth.seq.cell(row, step)) { cell.addClass('on'); }
					line.append(cell);
				}
				host.append(line);
			}
		});
	}
	$(document).on('click', '.synth_seq_cell', function () {
		var row = parseInt($(this).attr('row'), 10), step = parseInt($(this).attr('step'), 10);
		$(this).toggleClass('on', window.jawnosSynth.seq.toggleCell(row, step));
	});
	$(document).on('click', '.synth_seq_toggle', function () {
		var on = window.jawnosSynth.seq.get().on;
		window.jawnosSynth.seq.set({ on: !on });
		$('.synth_seq_toggle').text('Seq: ' + (!on ? 'on' : 'off'));
		synthEnsureAudio();
	});
	$(document).on('change', '.synth_seq_rate, .synth_seq_steps', function () {
		window.jawnosSynth.seq.set({ rate: $('.synth_seq_rate').val(), steps: $('.synth_seq_steps').val() });
		var g = window.jawnosSynth.seq.get();
		$('.synth_seq_rate').val(String(g.rate));
		$('.synth_seq_steps').val(String(g.steps));
		synthBuildSeq();
	});
	$(document).on('click', '.synth_seq_clear', function () {
		window.jawnosSynth.seq.clear();
		$('.synth_seq_cell').removeClass('on');
	});
	window.jawnosSynth.seq.onstep(function (step) {
		$('.synth_seq').each(function () {
			var host = $(this);
			host.find('.synth_seq_playing').removeClass('synth_seq_playing');
			host.find('.synth_seq_cell[step="' + step + '"]').addClass('synth_seq_playing');
		});
	});

	// The last press decides which synth host owns the computer keyboard. A press
	// anywhere else (the drum map, another Studio panel) hands it back.
	$(document).on('pointerdown', function (e) {
		keyboardOwner = synthOwnerFor(e.target);
	});
	$(document).on('focusin', function (e) {
		var owner = synthOwnerFor(e.target);
		if (owner) { keyboardOwner = owner; }
	});

	$(document).on('keydown', function (e) {
		if (!keyboardOn || e.metaKey || e.ctrlKey || e.altKey) { return; }
		if ($(e.target).is('input, select, textarea, [contenteditable]')) { return; }
		if (!synthKeysOwned(e)) { return; }
		var k = String(e.key || '').toLowerCase();
		if (k === 'z') { keyboardOctave = Math.max(0, keyboardOctave - 1); synthRenderOctave(); synthFocusOctave(); e.preventDefault(); return; }
		if (k === 'x') { keyboardOctave = Math.min(8, keyboardOctave + 1); synthRenderOctave(); synthFocusOctave(); e.preventDefault(); return; }
		if (!(k in KEYMAP) || keyboardHeld[k] != null) { return; }
		synthEnsureAudio();
		var note = synthKeyboardNote(k);
		keyboardHeld[k] = note;
		e.preventDefault();
		jawnosSynth.noteOn(note, 0.85);
		$('.piano_key[midi="' + note + '"]').addClass('piano_key_on');
	});

	$(document).on('keyup', function (e) {
		if (!keyboardOn) { return; }
		var k = String(e.key || '').toLowerCase();
		if (!(k in KEYMAP) || keyboardHeld[k] == null) { return; }
		var note = keyboardHeld[k];
		delete keyboardHeld[k];
		jawnosSynth.noteOff(note);
		$('.piano_key[midi="' + note + '"]').removeClass('piano_key_on');
	});

	// ---- page init -------------------------------------------------------------
	// The roll, controls and step grid are built once per page, whether the host is
	// the standalone Synth window or the Studio panel (which may be inserted long
	// after the page is ready). The guard keeps a second include from initialising
	// twice; the class-based builders still fill a host that arrives later.
	var synthPageInited = false;

	function synthStatusTick() {
		if (document.hidden) { return; }
		var v = window.jawnosSynth.voices();
		$('.synth_voice_count').text(v ? (v + ' voice' + (v === 1 ? '' : 's')) : '');
		var armed = window.jawnosSynth.learn.armed();
		var mapped = Object.keys(window.jawnosSynth.learn.map()).length;
		$('.synth_learn_state').text(armed ? ('learning ' + armed + ' — move a knob') : (mapped ? (mapped + ' control' + (mapped === 1 ? '' : 's') + ' learned') : ''));
	}

	function synthPageInit() {
		if (synthPageInited || !$('#synth').length) { return false; }
		synthPageInited = true;
		pianoInit();
		$('.synth_sound').val(S.sound);
		if (standaloneSynthHost()) { keyboardOwner = 'standalone'; }
		setInterval(synthStatusTick, 250);
		return true;
	}

	function synthBuildPanels() {
		synthBuildKeys(); synthBuildSeq(); synthPopulatePresets(); synthSyncSliders(); synthPopulateMidi(); synthPopulateLearn(); synthRenderOctave();
	}

	function synthWatchPanels() {
		if (typeof MutationObserver === 'undefined' || !document.body) { return; }
		var observer = new MutationObserver(function (records) {
			var host = false;
			for (var i = 0; i < records.length && !host; i++) {
				var added = records[i].addedNodes;
				for (var j = 0; j < added.length; j++) {
					var node = added[j];
					if (node.nodeType !== 1) { continue; }
					if (node.id === 'synth' || (node.querySelector && node.querySelector('#synth'))) { host = true; break; }
				}
			}
			if (!host) { return; }
			if (!synthPageInited) { synthPageInit(); }
			else { synthBuildPanels(); }
		});
		observer.observe(document.body, { childList: true, subtree: true });
	}

	$(function () {
		synthPageInit();
		synthWatchPanels();
	});

	// A studio-hosted panel builds itself on the same classes (its own synth engine
	// is the same singleton), so the standalone window and the studio panel can be
	// open at once without stepping on each other.
	$(document).on('click', '#studio_synth_hide', function () {
		$('#studio_synth .studio_synth_body').hide();
		$(this).hide();
		$('#studio_synth_show').show();
	});
	$(document).on('click', '#studio_synth_show', function () {
		$('#studio_synth .studio_synth_body').show();
		$(this).hide();
		$('#studio_synth_hide').show();
	});

	$(document).on('jawnos_synth_panel', function () {
		synthPageInit();
		synthBuildPanels();
	});

	function noteNameToMidi(name) {
		var m = /^([A-Ga-g])(#|b)?(-?\d+)$/.exec(String(name).replace(/\s+/g, ''));
		if (!m) { return 60; }
		var base = NOTE_NAMES.indexOf(m[1].toUpperCase() + (m[2] === '#' ? '#' : ''));
		if (m[2] === 'b') { base = NOTE_NAMES.indexOf(m[1].toUpperCase()); base = (base + 11) % 12; }
		return base + (parseInt(m[3], 10) + 1) * 12;
	}
})();
