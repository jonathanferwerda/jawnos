// ===========================================================================
// Studio inserts - the browser side of the shared effect contract
// ===========================================================================
// docs/studio-effects.md is the contract with the native engine: the same
// names, the same controls, the same 0..100 sliders. This part builds every
// insert studioInsert() can hand back. Each builder returns
//
//   { name, input, output, set(control, value), setBypass(on), bypassed }
//
// The shell keeps a dry path and a wet path into the same output. A footswitch
// mutes the wet path and opens the dry one, so bypassing is an in-place change
// and never a graph rebuild (contract rule 5: a pedal is toggled, not removed).
// A builder's own dry/wet mix feeds the shell's wet node; its controls are the
// same 0..100 sliders the engine takes, except the whole-number dropdowns
// (model, cabinet, key, scale), which arrive already quantised by the UI.

function studioEffectText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function studioEffectNumber(value) {
	var n = (typeof value === 'number') ? value : parseFloat(value);
	return (isNaN(n) || !isFinite(n)) ? null : n;
}

function studioEffectClamp(value, low, high) {
	var n = studioEffectNumber(value);
	if (n === null) { return low; }
	return Math.max(low, Math.min(high, n));
}

// The shell every builder hangs its nodes from.
function studioEffectShell(ctx, name) {
	var fx = {
		name: name,
		input: ctx.createGain(),
		output: ctx.createGain(),
		dry: ctx.createGain(),
		wet: ctx.createGain(),
		bypassed: false,
		setters: {},
		values: {}
	};
	fx.input.connect(fx.dry).connect(fx.output);
	fx.wet.connect(fx.output);
	fx.dry.gain.value = 0;
	fx.wet.gain.value = 1;
	fx.set = function (control, value) {
		var n = studioEffectNumber(value);
		if (n === null) { return; }
		fx.values[control] = value;
		if (fx.setters[control]) { fx.setters[control](n); }
	};
	fx.setBypass = function (on) {
		fx.bypassed = !!on;
		fx.dry.gain.value = fx.bypassed ? 1 : 0;
		fx.wet.gain.value = fx.bypassed ? 0 : 1;
	};
	return fx;
}

// ---- reverb ----------------------------------------------------------------

// One shape per model, in the contract's order. The numbers are the doc's
// character, not a sample library: a generated impulse that decays the right
// way is enough to tell a room from a cave.
var studioReverbShapes = [
	{ name: 'Room',   seconds: 0.8, decay: 3.2, bright: 0.55, early: 1.0, low: 0.15 },
	{ name: 'Spring', seconds: 1.8, decay: 2.6, bright: 0.95, early: 0.15, low: 0.2, spring: 1 },
	{ name: 'Plate',  seconds: 2.2, decay: 2.4, bright: 0.75, early: 0.3, low: 0.35 },
	{ name: 'Hall',   seconds: 3.4, decay: 2.0, bright: 0.35, early: 0.25, low: 0.5 },
	{ name: 'Cave',   seconds: 6.0, decay: 1.6, bright: 0.18, early: 0.2, low: 0.8 }
];

function studioReverbModel(value) {
	var n = studioEffectNumber(value);
	if (n === null) { n = 2; }
	return Math.max(0, Math.min(4, Math.round(n)));
}

function studioReverbModelName(value) {
	var shape = studioReverbShapes[studioReverbModel(value)];
	return shape ? shape.name : 'Room';
}

// Built once per context and cached on it: a model change is a buffer swap,
// not a new noise loop, and the impulse is generated away from the audio
// callback (contract rule 1). The cache lives on the context because a buffer
// belongs to the context that made it.
function studioReverbImpulse(ctx, model) {
	var index = studioReverbModel(model);
	if (!ctx.jawnosReverbCache) { ctx.jawnosReverbCache = {}; }
	var cache = ctx.jawnosReverbCache;
	if (cache[index]) { return cache[index]; }
	var shape = studioReverbShapes[index];
	var rate = ctx.sampleRate;
	var length = Math.max(1, Math.floor(rate * shape.seconds));
	var impulse = ctx.createBuffer(2, length, rate);
	var early = [0.011, 0.017, 0.023, 0.031, 0.043, 0.057];
	for (var c = 0; c < 2; c++) {
		var data = impulse.getChannelData(c);
		var bright = 0, low = 0;
		for (var i = 0; i < length; i++) {
			var t = i / length;
			var white = Math.random() * 2 - 1;
			// A one-pole pair stands in for the model's colour: the bright tap
			// keeps the noise's top, the slow tap is the low-mid weight.
			bright += shape.bright * (white - bright);
			low += 0.02 * (white - low);
			var s = bright * (1 - shape.low) + low * shape.low * 3;
			if (shape.spring) {
				// two short combs give the spring its metallic, narrow ring
				s += Math.sin(2 * Math.PI * (900 + c * 130) * (i / rate)) * 0.18 * Math.pow(1 - t, 3);
				s += Math.sin(2 * Math.PI * (1700 + c * 90) * (i / rate)) * 0.12 * Math.pow(1 - t, 4);
			}
			data[i] = s * Math.pow(1 - t, shape.decay);
		}
		// A room's first echo is loud and discrete; a plate has no early gap.
		if (shape.early > 0) {
			early.forEach(function (seconds, n) {
				var spot = Math.floor((seconds + c * 0.0017) * rate);
				if (spot < length) { data[spot] += (n % 2 ? -1 : 1) * 0.55 * shape.early; }
			});
		}
		var peak = 0;
		for (var j = 0; j < length; j++) { peak = Math.max(peak, Math.abs(data[j])); }
		if (peak > 0) {
			for (var k = 0; k < length; k++) { data[k] = data[k] / peak * 0.8; }
		}
	}
	cache[index] = impulse;
	return impulse;
}

function studioEffectReverb(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'reverb');
	var convolver = ctx.createConvolver();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	var mix = 35, volume = 50;
	var apply = function () {
		wet.gain.value = (mix / 100) * 0.9 * (volume / 50);
		dry.gain.value = 1 - (mix / 100) * 0.6;
	};
	fx.input.connect(convolver).connect(wet).connect(fx.wet);
	fx.input.connect(dry).connect(fx.wet);
	fx.modelValue = -1;
	fx.setters['model'] = function (v) {
		var m = studioReverbModel(v);
		if (m === fx.modelValue && convolver.buffer) { return; }
		fx.modelValue = m;
		convolver.buffer = studioReverbImpulse(ctx, m);
	};
	fx.setters['mix'] = function (v) { mix = v; apply(); };
	fx.setters['volume'] = function (v) { volume = v; apply(); };
	// The old reverb2 defaults: a little room on the signal, then its level.
	fx.set('model', 2);
	fx.set('mix', mix);
	fx.set('volume', volume);
	return fx;
}

// ---- flanger ---------------------------------------------------------------

function studioEffectFlanger(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'flanger');
	var delay = ctx.createDelay(0.05);
	delay.delayTime.value = 0.004;
	var feedback = ctx.createGain();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	var lfo = ctx.createOscillator();
	var depth = ctx.createGain();
	lfo.type = 'sine';
	lfo.connect(depth).connect(delay.delayTime);
	fx.input.connect(delay);
	delay.connect(feedback).connect(delay);
	delay.connect(wet).connect(fx.wet);
	fx.input.connect(dry).connect(fx.wet);
	try { lfo.start(0); } catch (e) {}
	fx.setters['rate'] = function (v) { lfo.frequency.value = 0.05 + (v / 100) * 5; };
	fx.setters['depth'] = function (v) { depth.gain.value = (v / 100) * 0.006; };
	fx.setters['feedback'] = function (v) { feedback.gain.value = Math.min(0.9, (v / 100) * 0.9); };
	fx.setters['mix'] = function (v) { wet.gain.value = v / 100; dry.gain.value = 1 - (v / 100) * 0.5; };
	fx.destroy = function () { try { lfo.stop(); } catch (e) {} };
	fx.set('rate', 20);
	fx.set('depth', 60);
	fx.set('feedback', 25);
	fx.set('mix', 50);
	return fx;
}

// ---- fuzz / distortion / amp ----------------------------------------------

function studioDistortionCurve(amount) {
	var n = 44100;
	var curve = new Float32Array(n);
	var deg = Math.PI / 180;
	for (var i = 0; i < n; i++) {
		var x = (i * 2) / n - 1;
		curve[i] = ((3 + amount) * x * 20 * deg) / (Math.PI + (amount * Math.abs(x)));
	}
	return curve;
}

// The fuzz curve is hard clipping with the quiet part squared away: a note
// speaks and the silence between does not, which is the gate in "gated".
function studioFuzzCurve(drive) {
	var n = 2048;
	var curve = new Float32Array(n);
	var k = 1 + drive * 40;
	for (var i = 0; i < n; i++) {
		var x = (i * 2) / (n - 1) - 1;
		var y = Math.tanh(x * k);
		if (Math.abs(y) < 0.02) { y = 0; }
		curve[i] = y;
	}
	return curve;
}

function studioEffectFuzz(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'fuzz');
	var shaper = ctx.createWaveShaper();
	shaper.oversample = '4x';
	var tone = ctx.createBiquadFilter();
	tone.type = 'lowpass';
	tone.frequency.value = 3000;
	var level = ctx.createGain();
	fx.input.connect(shaper).connect(tone).connect(level).connect(fx.wet);
	fx.setters['gain'] = function (v) { shaper.curve = studioFuzzCurve(v / 100); };
	fx.setters['tone'] = function (v) { tone.frequency.value = 500 + (v / 100) * 7500; };
	fx.setters['level'] = function (v) { level.gain.value = (v / 100) * 1.2; };
	fx.set('gain', 65);
	fx.set('tone', 45);
	fx.set('level', 60);
	return fx;
}

function studioEffectDistortion(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'distortion');
	var shaper = ctx.createWaveShaper();
	var lp = ctx.createBiquadFilter();
	lp.type = 'lowpass';
	lp.frequency.value = 4500;
	fx.input.connect(shaper).connect(lp).connect(fx.wet);
	var drive = function (v) { shaper.curve = studioDistortionCurve((v / 100) * 100); shaper.oversample = '4x'; };
	// The shelf pedal's knob is called gain; the contract calls it drive.
	fx.setters['drive'] = drive;
	fx.setters['gain'] = drive;
	fx.set('drive', 50);
	return fx;
}

// 0 Combo (1x12), 1 Open (2x12), 2 Closed (4x12), 3 Tweed (4x10). The engine's
// four cabinets follow this order; the names come from the palette's data.
var studioAmpCabinets = [
	{ name: 'Combo',  highpass: 90,  lowpass: 5200, presence: 2600, presenceGain: 2 },
	{ name: 'Open',   highpass: 75,  lowpass: 6000, presence: 3000, presenceGain: 3 },
	{ name: 'Closed', highpass: 60,  lowpass: 4500, presence: 2200, presenceGain: 5 },
	{ name: 'Tweed',  highpass: 110, lowpass: 4000, presence: 1800, presenceGain: 4 }
];

function studioEffectAmp(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'amp');
	var pre = ctx.createGain();
	var shaper = ctx.createWaveShaper();
	shaper.curve = studioFuzzCurve(0.15);
	shaper.oversample = '4x';
	var bass = ctx.createBiquadFilter();
	bass.type = 'lowshelf';
	bass.frequency.value = 120;
	var mid = ctx.createBiquadFilter();
	mid.type = 'peaking';
	mid.frequency.value = 800;
	mid.Q.value = 1;
	var treble = ctx.createBiquadFilter();
	treble.type = 'highshelf';
	treble.frequency.value = 3000;
	var hp = ctx.createBiquadFilter();
	hp.type = 'highpass';
	var presence = ctx.createBiquadFilter();
	presence.type = 'peaking';
	presence.Q.value = 0.9;
	var lp = ctx.createBiquadFilter();
	lp.type = 'lowpass';
	var level = ctx.createGain();
	fx.input.connect(pre).connect(shaper).connect(bass).connect(mid).connect(treble)
		.connect(hp).connect(presence).connect(lp).connect(level).connect(fx.wet);
	fx.setters['gain'] = function (v) {
		// -15 dB to +15 dB around the shaper, which saturates as it is pushed
		pre.gain.value = Math.pow(10, ((v - 50) / 50 * 15) / 20);
	};
	var shelf = function (filter, v) { filter.gain.value = (v - 50) / 50 * 12; };
	fx.setters['bass'] = function (v) { shelf(bass, v); };
	fx.setters['mid'] = function (v) { shelf(mid, v); };
	fx.setters['treble'] = function (v) { shelf(treble, v); };
	fx.setters['cabinet'] = function (v) {
		var cab = studioAmpCabinets[Math.max(0, Math.min(3, Math.round(v)))] || studioAmpCabinets[0];
		hp.frequency.value = cab.highpass;
		presence.frequency.value = cab.presence;
		presence.gain.value = cab.presenceGain;
		lp.frequency.value = cab.lowpass;
	};
	level.gain.value = 0.7;
	fx.set('gain', 50);
	fx.set('bass', 50);
	fx.set('mid', 50);
	fx.set('treble', 50);
	fx.set('cabinet', 2);
	return fx;
}

// ---- limiter ---------------------------------------------------------------

function studioEffectLimiter(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'limiter');
	var comp = ctx.createDynamicsCompressor();
	comp.ratio.value = 20;
	comp.knee.value = 0;
	comp.attack.value = 0.002;
	fx.input.connect(comp).connect(fx.wet);
	// The slider is the ceiling, so a higher slider limits less and plays louder.
	fx.setters['ceiling'] = function (v) { comp.threshold.value = -24 + (v / 100) * 24; };
	fx.setters['release'] = function (v) { comp.release.value = 0.01 + (v / 100) * 0.49; };
	fx.set('ceiling', 85);
	fx.set('release', 40);
	return fx;
}

// A maximiser is the limiter with loudness make-up and a hard ceiling: the
// compressor catches the peaks, the shaper guarantees the ceiling.
function studioMaximizerCurve(ceiling) {
	var n = 4096;
	var curve = new Float32Array(n);
	var scale = Math.tanh(1 / ceiling);
	for (var i = 0; i < n; i++) {
		var x = (i * 2) / (n - 1) - 1;
		curve[i] = ceiling * Math.tanh(x / ceiling) / scale;
	}
	return curve;
}

function studioEffectMaximizer(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'master_maximizer');
	var comp = ctx.createDynamicsCompressor();
	comp.ratio.value = 20;
	comp.knee.value = 0;
	comp.attack.value = 0.003;
	comp.release.value = 0.2;
	var makeup = ctx.createGain();
	var clip = ctx.createWaveShaper();
	var ceiling = 0.9;
	fx.input.connect(comp).connect(makeup).connect(clip).connect(fx.wet);
	fx.setters['ceiling'] = function (v) {
		var ceiling_db = -24 + (v / 100) * 24;
		ceiling = Math.pow(10, ceiling_db / 20);
		comp.threshold.value = ceiling_db;
		clip.curve = studioMaximizerCurve(ceiling);
	};
	fx.setters['loudness'] = function (v) {
		makeup.gain.value = Math.pow(10, ((v / 100) * 12) / 20);
	};
	fx.set('ceiling', 90);
	fx.set('loudness', 20);
	return fx;
}

// ---- equalizer / compressor / delay / tone --------------------------------

function studioEffectEqualizer(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'equalizer');
	var low = ctx.createBiquadFilter();
	low.type = 'lowshelf';
	low.frequency.value = 200;
	var mid = ctx.createBiquadFilter();
	mid.type = 'peaking';
	mid.frequency.value = 1000;
	mid.Q.value = 1;
	var high = ctx.createBiquadFilter();
	high.type = 'highshelf';
	high.frequency.value = 4000;
	fx.input.connect(low).connect(mid).connect(high).connect(fx.wet);
	fx.setters['low'] = function (v) { low.gain.value = (v - 50) / 50 * 12; };
	fx.setters['mid'] = function (v) { mid.gain.value = (v - 50) / 50 * 12; };
	fx.setters['high'] = function (v) { high.gain.value = (v - 50) / 50 * 12; };
	fx.set('low', 50);
	fx.set('mid', 50);
	fx.set('high', 50);
	return fx;
}

function studioEffectCompressor(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'compressor');
	var comp = ctx.createDynamicsCompressor();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	fx.input.connect(comp).connect(wet).connect(fx.wet);
	fx.input.connect(dry).connect(fx.wet);
	fx.setters['thresh'] = function (v) { comp.threshold.value = -60 + (v / 100) * 60; };
	fx.setters['attack'] = function (v) { comp.attack.value = Math.max(0.001, v / 500); };
	fx.setters['ratio'] = function (v) { comp.ratio.value = 1 + (v / 100) * 19; };
	fx.setters['release'] = function (v) { comp.release.value = 0.05 + (v / 100) * 0.95; };
	fx.setters['knee'] = function (v) { comp.knee.value = (v / 100) * 24; };
	fx.setters['mix'] = function (v) { wet.gain.value = v / 100; dry.gain.value = 1 - v / 100; };
	fx.set('thresh', 50);
	fx.set('attack', 20);
	fx.set('ratio', 50);
	fx.set('release', 25);
	fx.set('knee', 30);
	fx.set('mix', 100);
	return fx;
}

function studioEffectDelay(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'delay');
	var delay = ctx.createDelay(2.0);
	var feedback = ctx.createGain();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	fx.input.connect(dry).connect(fx.wet);
	fx.input.connect(delay).connect(wet).connect(fx.wet);
	delay.connect(feedback).connect(delay);
	dry.gain.value = 0.7;
	fx.setters['time'] = function (v) { delay.delayTime.value = (v / 100) * 1.5; };
	fx.setters['feedback'] = function (v) { feedback.gain.value = (v / 100) * 0.9; };
	fx.setters['vol'] = function (v) { wet.gain.value = v / 100; };
	fx.set('time', 35);
	fx.set('feedback', 30);
	fx.set('vol', 40);
	return fx;
}

function studioEffectTone(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'tone');
	var gain = ctx.createGain();
	var bass = ctx.createBiquadFilter();
	bass.type = 'lowshelf';
	bass.frequency.value = 220;
	var mid = ctx.createBiquadFilter();
	mid.type = 'peaking';
	mid.frequency.value = 1000;
	mid.Q.value = 1;
	var treble = ctx.createBiquadFilter();
	treble.type = 'highshelf';
	treble.frequency.value = 3500;
	fx.input.connect(gain).connect(bass).connect(mid).connect(treble).connect(fx.wet);
	fx.setters['gain'] = function (v) { gain.gain.value = v / 50; };
	fx.setters['bass'] = function (v) { bass.gain.value = (v - 50) / 50 * 12; };
	fx.setters['mid'] = function (v) { mid.gain.value = (v - 50) / 50 * 12; };
	fx.setters['treble'] = function (v) { treble.gain.value = (v - 50) / 50 * 12; };
	fx.set('gain', 50);
	fx.set('bass', 50);
	fx.set('mid', 50);
	fx.set('treble', 50);
	return fx;
}

// ---- autotune --------------------------------------------------------------
// An honest monophonic pitch corrector, not a polyphonic Antares clone. It
// tracks one period from the input, picks the nearest tone in the chosen key
// and scale, and re-synthesises the signal pitch-synchronously: grains of two
// periods, taken at the input's own pitch marks, are laid down at the target
// period and crossfaded with a Hann window, so the output repeats at the
// target (PSOLA). That is why it corrects a few cents as well as a whole tone.
// A chord confuses the detector - that is the documented limit - and the effect
// is never bypassed silently: if this browser has no script processor it falls
// back to a swept delay line, which is cruder but still shifts.

var studioAutotuneScales = [
	[0, 2, 4, 5, 7, 9, 11],          // Major
	[0, 2, 3, 5, 7, 8, 10],          // Minor
	[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], // Chromatic
	[0, 3, 5, 7, 10]                 // Pentatonic
];

function studioAutotuneKey(value) {
	return Math.max(0, Math.min(11, Math.round(studioEffectClamp(value, 0, 0) / 100 * 11)));
}

function studioAutotuneScale(value) {
	return Math.max(0, Math.min(3, Math.round(studioEffectClamp(value, 0, 0) / 100 * 3)));
}

// The nearest scale tone to a detected frequency, as a frequency again.
function studioAutotuneTarget(hz, key, scale) {
	if (!(hz > 0)) { return 0; }
	var midi = 69 + 12 * Math.log(hz / 440) / Math.LN2;
	var base = Math.round(midi);
	var tones = studioAutotuneScales[scale] || studioAutotuneScales[0];
	var best = base, bestDistance = 1e9;
	for (var n = base - 1; n <= base + 1; n++) {
		var pc = ((n % 12) + 12) % 12;
		var inScale = false;
		for (var i = 0; i < tones.length; i++) {
			if ((((tones[i] + key) % 12) + 12) % 12 === pc) { inScale = true; break; }
		}
		if (!inScale) { continue; }
		var distance = Math.abs(n - midi);
		if (distance < bestDistance) { bestDistance = distance; best = n; }
	}
	return 440 * Math.pow(2, (best - 69) / 12);
}

// Autocorrelation over one window. `scratch` is a preallocated correlation
// table so the audio callback does not allocate (contract rule 1).
function studioAutotunePitch(samples, rate, scratch) {
	var n = samples.length;
	var minLag = Math.max(2, Math.floor(rate / 1200));
	var maxLag = Math.min(n - 8, Math.floor(rate / 80));
	if (maxLag <= minLag + 2) { return 0; }
	var mean = 0;
	for (var i = 0; i < n; i++) { mean += samples[i]; }
	mean = mean / n;
	var energy = 0;
	for (var j = 0; j < n; j++) { var d = samples[j] - mean; energy += d * d; }
	if (energy / n < 1e-6) { return 0; }
	var table = scratch || new Float32Array(maxLag + 2);
	var best = 0, bestLag = 0;
	for (var lag = minLag; lag <= maxLag; lag++) {
		var sum = 0;
		for (var k = 0; k + lag < n; k++) { sum += (samples[k] - mean) * (samples[k + lag] - mean); }
		table[lag] = sum;
		if (sum > best) { best = sum; bestLag = lag; }
	}
	if (!bestLag || best < energy * 0.25) { return 0; }
	// The first strong peak wins, not the tallest: the tallest is often a
	// harmonic's multiple of the period, an octave down from what was played.
	var threshold = best * 0.9;
	for (var m = minLag + 1; m < maxLag; m++) {
		if (table[m] >= threshold && table[m] >= table[m - 1] && table[m] >= table[m + 1]) {
			bestLag = m;
			break;
		}
	}
	// parabolic interpolation around the integer lag
	var left = table[bestLag - 1] || 0, centre = table[bestLag] || 0, right = table[bestLag + 1] || 0;
	var shift = 0;
	var denom = left - 2 * centre + right;
	if (denom) { shift = 0.5 * (left - right) / denom; }
	shift = Math.max(-0.5, Math.min(0.5, shift));
	return rate / (bestLag + shift);
}

function studioAutotuneState(rate) {
	var ringSize = 32768;
	return {
		rate: rate,
		ringSize: ringSize,
		write: 0,
		sample: 0,
		base: Math.max(512, Math.round(rate * 0.08)),
		period: 0,
		target: 0,
		analysis: 0,
		mark: 0,
		nextGrain: 0,
		grains: [],
		started: false,
		window: 768,
		rings: [],
		decimated: new Float32Array(768),
		corr: new Float32Array(1204)
	};
}

function studioAutotuneRead(ring, size, at) {
	var pos = at;
	pos = pos - Math.floor(pos / size) * size;
	var i0 = Math.floor(pos), frac = pos - i0;
	var a = ring[i0 % size], b = ring[(i0 + 1) % size];
	return a + (b - a) * frac;
}

// The detector's input: the first channel's last few milliseconds, decimated
// by two so the lag search stays cheap. Reading only channel one is part of
// the monophonic limit above.
function studioAutotuneWindow(state) {
	var ring = state.rings[0];
	if (!ring) { return null; }
	var dec = state.decimated;
	var count = state.window;
	var at = state.write - count * 2;
	for (var i = 0; i < count; i++) {
		var a = studioAutotuneRead(ring, state.ringSize, at + i * 2);
		var b = studioAutotuneRead(ring, state.ringSize, at + i * 2 + 1);
		dec[i] = (a + b) / 2;
	}
	return dec;
}

function studioAutotuneBlock(state, event, settings) {
	var input = event.inputBuffer;
	var output = event.outputBuffer;
	var channels = Math.min(input.numberOfChannels, output.numberOfChannels);
	if (!channels) { return; }
	if (state.rings.length !== channels) { state.rings = []; }
	var n = input.length;
	var ringSize = state.ringSize, rate = state.rate;

	// capture this block first: the grains read history, never the future
	for (var c = 0; c < channels; c++) {
		var ring = state.rings[c];
		if (!ring) { ring = state.rings[c] = new Float32Array(ringSize); }
		var inData = input.getChannelData(c);
		var write = state.write;
		for (var i = 0; i < n; i++) {
			ring[write] = inData[i];
			write = (write + 1) % ringSize;
		}
	}
	state.write = (state.write + n) % ringSize;

	// one pitch decision per block, from channel one's history
	var hz = 0;
	if (settings.amount > 0) {
		var window = studioAutotuneWindow(state);
		if (window) { hz = studioAutotunePitch(window, rate / 2, state.corr); }
	}
	var inputPeriod = (hz > 0) ? rate / hz : state.period;
	var target = studioAutotuneTarget(hz, settings.key, settings.scale);
	var targetPeriod = (hz > 0 && target > 0) ? rate / target : inputPeriod;

	if (!state.started) {
		state.period = inputPeriod;
		state.target = inputPeriod;
		state.analysis = state.sample - state.base;
		state.mark = state.analysis;
		state.nextGrain = state.sample;
		state.started = true;
	}
	if (inputPeriod > 0) {
		// speed is how fast the correction glides, one pole per block
		var glide = 0.05 + (settings.speed / 100) * 0.9;
		state.period += (inputPeriod - state.period) * glide;
		var wanted = inputPeriod + (targetPeriod - inputPeriod) * (settings.amount / 100);
		state.target += (wanted - state.target) * glide;
	}
	var period = state.period > 0 ? state.period : 128;
	period = Math.max(16, Math.min(rate / 40, period));
	var synth = state.target > 0 ? state.target : period;
	synth = Math.max(16, Math.min(rate / 40, synth));

	var blockStart = state.sample, blockEnd = state.sample + n;
	// Lay a grain every target period. The tracking position advances with real
	// time (so it never runs behind the write head), and each grain's analysis
	// mark is snapped to the nearest whole period *after the last mark*, never to
	// an absolute multiple: the period estimate drifts by a fraction of a sample
	// per block, and marks anchored to absolute zero would move under it and
	// break the phase alignment the overlap-add depends on.
	var guard = 0;
	while (state.nextGrain < blockEnd && guard++ < 512) {
		var steps = Math.round((state.analysis - state.mark) / period);
		state.mark = state.mark + steps * period;
		state.grains.push({
			start: state.nextGrain,
			analysis: state.mark,
			length: Math.max(32, Math.round(2 * period))
		});
		state.analysis += synth;
		state.nextGrain += synth;
	}
	state.grains = state.grains.filter(function (grain) { return grain.start + grain.length > blockStart; });

	var weights = state.weights;
	if (!weights || weights.length < n) { weights = state.weights = new Float32Array(Math.max(1024, n)); }
	for (var ch = 0; ch < channels; ch++) {
		var source = state.rings[ch];
		var out = output.getChannelData(ch);
		var s;
		for (s = 0; s < n; s++) { out[s] = 0; weights[s] = 0; }
		for (var gi = 0; gi < state.grains.length; gi++) {
			var grain = state.grains[gi];
			var from = Math.max(0, Math.ceil(grain.start - blockStart));
			var to = Math.min(n, Math.ceil(grain.start + grain.length - blockStart));
			for (var si = from; si < to; si++) {
				var p = blockStart + si - grain.start;
				if (p < 0 || p >= grain.length) { continue; }
				var w = 0.5 - 0.5 * Math.cos(2 * Math.PI * p / grain.length);
				out[si] += studioAutotuneRead(source, ringSize, grain.analysis - grain.length / 2 + p) * w;
				weights[si] += w;
			}
		}
		// the Hann windows may not sum to one when the ratio bends; normalise
		for (s = 0; s < n; s++) {
			if (weights[s] > 1e-6) { out[s] = out[s] / weights[s]; }
		}
	}
	state.sample = blockEnd;
}

// No script processor? The correction is the same; only the scheduling moves
// to a timer, which sweeps two delay heads a grain at a time.
function studioAutotuneRamp(ctx, fx, settings) {
	var grain = 0.08, base = 0.16;
	var da = ctx.createDelay(1), db = ctx.createDelay(1);
	var ga = ctx.createGain(), gb = ctx.createGain();
	fx.input.connect(da).connect(ga).connect(fx.wet);
	fx.input.connect(db).connect(gb).connect(fx.wet);
	ga.gain.value = 0;
	gb.gain.value = 0;
	var analyser = ctx.createAnalyser();
	analyser.fftSize = 2048;
	fx.input.connect(analyser);
	var data = new Float32Array(analyser.fftSize);
	var corr = new Float32Array(2048);
	var ratio = 1, next = ctx.currentTime + 0.05, flip = 0;
	var timer = setInterval(function () {
		analyser.getFloatTimeDomainData(data);
		var hz = studioAutotunePitch(data, ctx.sampleRate, corr);
		var target = studioAutotuneTarget(hz, settings.key, settings.scale);
		var desired = (hz > 0 && target > 0) ? target / hz : 1;
		desired = 1 + (desired - 1) * (settings.amount / 100);
		desired = Math.max(0.5, Math.min(2, desired));
		ratio += (desired - ratio) * (0.1 + (settings.speed / 100) * 0.8);
		while (next < ctx.currentTime + 0.3) {
			var to = flip ? db : da;
			var toGain = flip ? gb : ga;
			var fromGain = flip ? ga : gb;
			var end = Math.max(0.002, base + (1 - ratio) * grain);
			to.delayTime.cancelScheduledValues(next);
			to.delayTime.setValueAtTime(base, next);
			to.delayTime.linearRampToValueAtTime(end, next + grain);
			toGain.gain.setValueAtTime(0, next);
			toGain.gain.linearRampToValueAtTime(1, next + grain * 0.5);
			toGain.gain.linearRampToValueAtTime(0, next + grain);
			fromGain.gain.setValueAtTime(1, next);
			fromGain.gain.linearRampToValueAtTime(0, next + grain);
			next += grain;
			flip = 1 - flip;
		}
	}, 50);
	return function () {
		clearInterval(timer);
		try { fx.input.disconnect(analyser); } catch (e) {}
	};
}

function studioEffectAutotune(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'autotune');
	var settings = { speed: 40, amount: 100, key: 0, scale: 0 };
	fx.setters['speed'] = function (v) { settings.speed = v; };
	fx.setters['amount'] = function (v) { settings.amount = v; };
	fx.setters['key'] = function (v) { settings.key = studioAutotuneKey(v); };
	fx.setters['scale'] = function (v) { settings.scale = studioAutotuneScale(v); };
	var maker = ctx.createScriptProcessor || ctx.createJavaScriptNode;
	if (maker) {
		var node = maker.call(ctx, 1024, 2, 2);
		var state = studioAutotuneState(ctx.sampleRate);
		node.onaudioprocess = function (event) { studioAutotuneBlock(state, event, settings); };
		fx.input.connect(node);
		node.connect(fx.wet);
		fx.destroy = function () {
			try { fx.input.disconnect(node); } catch (e) {}
			try { node.disconnect(); } catch (e) {}
		};
	}
	else {
		var stop = studioAutotuneRamp(ctx, fx, settings);
		fx.destroy = function () { stop(); };
	}
	fx.set('speed', 40);
	fx.set('amount', 100);
	fx.set('key', 0);
	fx.set('scale', 0);
	return fx;
}

// ---- the synth pedal -------------------------------------------------------

function studioEffectSynth(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'JawnSynth');
	var synth = window.jawnosSynth;
	if (!synth || typeof synth.outputNode !== 'function') { return fx; }
	// A generator pedal: the synth's output replaces the chain from here, so a
	// channel carrying this pedal records whatever the synth plays.
	if (synth.context() !== ctx) { synth.attach(ctx, ctx.destination); }
	var src = synth.outputNode();
	if (src) {
		src.connect(fx.wet);
		fx.destroy = function () { try { src.disconnect(fx.wet); } catch (e) {} };
	}
	var synthMap = {
		cutoff: 'filter.cutoff', reso: 'filter.q', attack: 'amp.a',
		release: 'amp.r', detune: 'osc2.detune', lfo: 'lfo.rate', level: 'drive'
	};
	Object.keys(synthMap).forEach(function (control) {
		fx.setters[control] = function (v) { synth.set(synthMap[control], synth.knob(synthMap[control], v)); };
	});
	return fx;
}

// ---- the dispatch table ----------------------------------------------------

// Every name the contract (and the old song files) can ask for, mapped to the
// builder that implements it. master_* uses the same implementations; the
// prefix says where the insert belongs, not what it does.
var studioEffectAliases = {
	compressor: 'compressor',
	CompressionX: 'compressor',
	distortion: 'distortion',
	Distorjawn: 'distortion',
	delay: 'delay',
	Delayed: 'delay',
	reverb: 'reverb',
	reverb2: 'reverb',
	flanger: 'flanger',
	fuzz: 'fuzz',
	amp: 'amp',
	limiter: 'limiter',
	autotune: 'autotune',
	equalizer: 'equalizer',
	tone: 'tone',
	JawnSynth: 'synth',
	master_comp: 'compressor',
	master_eq: 'equalizer',
	master_reverb: 'reverb',
	master_maximizer: 'maximizer',
	master_limiter: 'limiter'
};

var studioEffectBuilders = {
	compressor: studioEffectCompressor,
	distortion: studioEffectDistortion,
	delay: studioEffectDelay,
	reverb: studioEffectReverb,
	flanger: studioEffectFlanger,
	fuzz: studioEffectFuzz,
	amp: studioEffectAmp,
	limiter: studioEffectLimiter,
	maximizer: studioEffectMaximizer,
	autotune: studioEffectAutotune,
	equalizer: studioEffectEqualizer,
	tone: studioEffectTone,
	synth: studioEffectSynth
};

// The canonical kind behind a name, so an insert added from the shelf
// ("reverb2") and one added from the palette ("reverb") are the same effect.
function studioEffectKind(name) {
	return studioEffectAliases[name] || String(name || '');
}

function studioEffectBuilder(name) {
	return studioEffectBuilders[studioEffectKind(name)] || null;
}

// The label and controls the server's effect table gives a name, if any.
function studioEffectSpec(name) {
	var table = window.jawnos_studio_effects || {};
	var kind = studioEffectKind(name);
	if (table[kind]) { return table[kind]; }
	if (table[name]) { return table[name]; }
	var master = window.jawnos_studio_master || [];
	for (var i = 0; i < master.length; i++) {
		if (master[i]['name'] === name) { return master[i]; }
	}
	return null;
}
