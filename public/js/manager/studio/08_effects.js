// ===========================================================================
// Studio inserts - the browser side of the shared effect contract
// ===========================================================================
// docs/studio-effects.md is the contract with the native engine: the same
// names, the same controls, the same 0..100 sliders. Stereo Widener is the one
// deliberate exception - it is browser only (see its builder below). This part
// builds every insert studioInsert() can hand back. Each builder returns
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

// ---- the contract's natural units -----------------------------------------
// docs/studio-effects.md, "Numbering that both sides must share". One function
// turns a 0..100 slider (or a whole index from a dropdown) into the effect's
// own units: dB, milliseconds, hertz, a 0..1 amount. The engine POST and the
// WebAudio setters both read it, so a range cannot change on one side only.
var studioEffectIndices = {
	'reverb.model': 4,
	'amp.cabinet': 3,
	'autotune.key': 11,
	'autotune.scale': 3,
	'tremolo.shape': 2,
	'stereo_panner.shape': 2,
	'harmonizer.key': 11,
	'harmonizer.scale': 3,
	'harmonizer.degree': 6
};

function studioEffectNatural(kind, control, value) {
	var key = studioEffectKind(kind) + '.' + control;
	if (studioEffectIndices[key] !== undefined) {
		return Math.round(studioEffectClamp(value, 0, studioEffectIndices[key]));
	}
	var amount = studioEffectClamp(value, 0, 100) / 100;
	switch (key) {
		case 'equalizer.low':
		case 'equalizer.mid':
		case 'equalizer.high':
		case 'master_eq.low':
		case 'master_eq.mid':
		case 'master_eq.high':
		case 'equalizer.b32':
		case 'equalizer.b64':
		case 'equalizer.b125':
		case 'equalizer.b250':
		case 'equalizer.b500':
		case 'equalizer.b1k':
		case 'equalizer.b2k':
		case 'equalizer.b4k':
		case 'equalizer.b8k':
		case 'equalizer.b16k':
		case 'master_eq.b32':
		case 'master_eq.b64':
		case 'master_eq.b125':
		case 'master_eq.b250':
		case 'master_eq.b500':
		case 'master_eq.b1k':
		case 'master_eq.b2k':
		case 'master_eq.b4k':
		case 'master_eq.b8k':
		case 'master_eq.b16k':
		case 'amp.bass':
		case 'amp.mid':
		case 'amp.treble':
		case 'tone.bass':
		case 'tone.mid':
		case 'tone.treble':
			return -12 + amount * 24;
		case 'limiter.ceiling':
		case 'maximizer.ceiling':
			return -24 + amount * 24;
		case 'limiter.release':
			return 10 + amount * 490;
		case 'compressor.thresh':
			return -60 + amount * 60;
		case 'compressor.attack':
			return 1 + amount * 199;
		case 'compressor.ratio':
			return 1 + amount * 19;
		case 'compressor.release':
			return 50 + amount * 950;
		case 'compressor.knee':
			return amount * 24;
		case 'flanger.rate':
		case 'phaser.rate':
			return 0.05 + amount * 4.95;
		case 'tremolo.rate':
		case 'stereo_panner.rate':
			return 0.1 + amount * 19.9;
		case 'flanger.feedback':
		case 'phaser.feedback':
		case 'delay.feedback':
			return amount * 0.9;
		case 'delay.time':
			return amount * 1.5;
		case 'tone.gain':
			return amount * 2;
		// Width is a 0..2 gain on the side signal: 50 is the untouched
		// image, 0 folds it to mono and 100 doubles the side.
		case 'stereowidener.width':
			return amount * 2;
		// ---- the ten pedals in .shots/PEDAL-SPEC.md --------------------------
		// Both de-essers share the compressor's threshold band, the gate floor is
		// the closed level and 0 dB is transparent.
		case 'de_esser.thresh':
		case 'gate.thresh':
			return -60 + amount * 60;
		case 'gate.range':
			return -80 + amount * 80;
		case 'de_esser.freq':
			return 4000 + amount * 8000;
		// The five LFOs: chorus is the slow one, the rest share 0.1..20 Hz.
		case 'modulator.rate':
		case 'slider.rate':
		case 'wah.rate':
		case 'vibrato.rate':
			return 0.1 + amount * 19.9;
		case 'chorus.rate':
			return 0.05 + amount * 4.95;
		// A whole semitone: the shifter's ratio is 2^(semitones/12).
		case 'pitch_shift.semitones':
			return Math.round(-24 + amount * 48);
		case 'gate.attack':
			return 0.1 + amount * 49.9;
		case 'gate.hold':
			return amount * 500;
		case 'gate.release':
			return 20 + amount * 980;
		case 'slider.duty':
			return 0.05 + amount * 0.9;
		default:
			return amount;
	}
}

// The one browser-only insert needs an L/R pair the engine's mono insert chain
// does not hold. A native take and a native listen omit it rather than
// refusing the whole chain (engine/src/effect.rs). The stereo panner is native:
// its insert hands the channel a pan LFO (engine/src/effect/stereo_panner.rs).
function studioEffectBrowserOnly(name) {
	var kind = studioEffectKind(name);
	return kind === 'stereowidener';
}

// ---- tempo sync ------------------------------------------------------------
// A synced time control stores a division string in `values.sync` and resolves
// it against the song's BPM. The string is the page's, not the engine's: the
// engine is sent the resolved `delay.time` seconds or the LFO `rate` Hz. The
// parser is deliberately generous - any `n/d` fraction, `d` (dotted) and `t`
// (triplet) suffixes, a bare whole-note count, and a manual `250ms` or decimal
// number - because a person types into the field instead of only choosing from
// the datalist.
var studioTempoControls = {
	delay: 'time',
	flanger: 'rate',
	phaser: 'rate',
	tremolo: 'rate',
	stereo_panner: 'rate',
	modulator: 'rate',
	slider: 'rate',
	wah: 'rate',
	chorus: 'rate',
	vibrato: 'rate'
};

// The natural range each synced control clamps to. Delay time is seconds; the
// LFOs are hertz. A division can resolve beyond a manual knob's range, so these
// are the effect's own limits, not the slider's.
var studioTempoLimits = {
	delay: { min: 0.001, max: 8 },
	flanger: { min: 0.05, max: 8 },
	phaser: { min: 0.05, max: 5 },
	tremolo: { min: 0.1, max: 20 },
	stereo_panner: { min: 0.1, max: 20 },
	modulator: { min: 0.1, max: 20 },
	slider: { min: 0.1, max: 20 },
	wah: { min: 0.1, max: 20 },
	chorus: { min: 0.05, max: 5 },
	vibrato: { min: 0.1, max: 20 }
};

function studioTempoBpm() {
	var time = (typeof mixer !== 'undefined' && mixer && mixer['time']) ? mixer['time'] : {};
	var bpm = parseFloat(time['bpm']);
	return (isFinite(bpm) && bpm > 0) ? bpm : 120;
}

// The beats a division names, in 4/4 quarter notes. `n/d` is 4n/d beats, a bare
// integer N is N whole notes (4N beats), `d` multiplies by 1.5 and `t` by 2/3.
// `off`, a blank string and anything else are not a division: null.
function studioTempoDivision(text) {
	var s = String(text === undefined || text === null ? '' : text).trim().toLowerCase();
	if (!s || s === 'off') { return null; }
	var fraction = /^(\d+)\s*\/\s*(\d+)\s*([dt])?$/.exec(s);
	if (fraction) {
		var n = parseInt(fraction[1], 10);
		var d = parseInt(fraction[2], 10);
		if (!(n > 0) || !(d > 0)) { return null; }
		var beats = (4 * n) / d;
		if (fraction[3] === 'd') { beats *= 1.5; }
		else if (fraction[3] === 't') { beats *= 2 / 3; }
		return beats;
	}
	if (/^\d+$/.test(s)) {
		var whole = parseInt(s, 10);
		return whole > 0 ? whole * 4 : null;
	}
	return null;
}

// A manual value, in milliseconds: `250ms` or any decimal number. A bare
// integer is a whole-note count above, not a millisecond value.
function studioTempoManualMs(text) {
	var s = String(text === undefined || text === null ? '' : text).trim().toLowerCase();
	var ms = /^(\d+(?:\.\d+)?|\.\d+)\s*ms$/.exec(s);
	if (ms) { return parseFloat(ms[1]); }
	if (/^(\d+\.\d+|\.\d+)$/.test(s)) { return parseFloat(s); }
	return null;
}

// Resolve a sync string for a kind into the control's natural value. A division
// is beats against the BPM; a manual value is milliseconds (seconds for a delay
// time, a period for an LFO rate). `off`, blank and junk return null, which is
// the manual knob's turn.
function studioTempoResolveValue(kind, sync, bpm) {
	kind = studioEffectKind(kind);
	var control = studioTempoControls[kind];
	if (!control) { return null; }
	var limits = studioTempoLimits[kind] || { min: 0.001, max: 1000 };
	bpm = (isFinite(bpm) && bpm > 0) ? bpm : 120;
	var clamp = function (value) { return Math.max(limits.min, Math.min(limits.max, value)); };
	var beats = studioTempoDivision(sync);
	if (beats !== null) {
		return (control === 'time') ? clamp((60 / bpm) * beats) : clamp(bpm / 60 / beats);
	}
	var ms = studioTempoManualMs(sync);
	if (ms !== null && ms > 0) {
		return (control === 'time') ? clamp(ms / 1000) : clamp(1000 / ms);
	}
	return null;
}

function studioTempoSyncText(ins) {
	return (ins && ins.values && ins.values.sync !== undefined) ? String(ins.values.sync) : 'off';
}

// Apply one insert's sync string to its browser node and, while the engine is
// the path that is playing, to the engine. The engine never sees the string.
// `send` false keeps an output-chain insert off the engine: only the input
// chain is armed by a take.
function studioTempoSyncApply(ins, ch, send) {
	if (!ins) { return; }
	var kind = studioEffectKind(ins.name);
	var control = studioTempoControls[kind];
	if (!control || typeof ins.setNatural !== 'function') { return; }
	var sync = studioTempoSyncText(ins);
	var value = studioTempoResolveValue(kind, sync, studioTempoBpm());
	if (value === null) {
		var manual = ins.values ? ins.values[control] : undefined;
		if (manual !== undefined) { value = studioEffectNatural(kind, control, manual); }
	}
	if (value === null) { return; }
	ins.setNatural(control, value);
	if (send !== false && ch !== undefined && !studioEffectBrowserOnly(kind)) {
		studioEngineInsertParamNatural(ch, ins.name, control, value);
	}
}

function studioTempoSyncInsert(ins, ch, send) {
	studioTempoSyncApply(ins, ch, send);
}

// Re-apply every synced insert: on a BPM change, after a sync or manual knob
// change, and after a song's racks are restored. An Out insert is browser
// playback only, so it resolves locally and is never posted to a take.
function studioTempoSyncAll() {
	if (typeof studioAudio === 'undefined' || !studioAudio || !studioAudio.channels) { return; }
	$.each(studioAudio.channels, function (ch, c) {
		(c.inserts || []).forEach(function (ins) { studioTempoSyncApply(ins, ch, true); });
		(c.outInserts || []).forEach(function (ins) { studioTempoSyncApply(ins, ch, false); });
	});
}

// ---- the engine's control path ---------------------------------------------
// The native engine is the path that is playing only while an engine take is
// recording or a live listen is running. The browser's graph stays
// authoritative otherwise, so a knob is never sent twice for one movement.
function studioEngineIsPath() {
	return (typeof studioEngineRecording !== 'undefined' && studioEngineRecording)
		|| (typeof studioListenActive !== 'undefined' && studioListenActive);
}

var studioEngineParamTimers = {};
var studioEngineParamErrorShown = false;

// One POST per knob per 150 ms, like the patchbay faders: a drag is a handful
// of engine commands, not one per pixel.
function studioEngineParamPost(data, key) {
	// The browser-only width insert needs an L/R pair the engine's mono insert
	// chain does not hold, so a take neither arms nor moves it. The sync string
	// is the page's too: the engine is sent the resolved time or rate instead.
	if (data && /^(?:master_)?stereowidener\./.test(String(data.name || ''))) { return; }
	if (data && /\.sync$/.test(String(data.name || ''))) { return; }
	if (!studioEngineIsPath()) { return; }
	if (studioEngineParamTimers[key]) { clearTimeout(studioEngineParamTimers[key]); }
	studioEngineParamTimers[key] = setTimeout(function () {
		$.ajax({
			url: '/manager/studio/take',
			type: 'POST',
			data: data,
			dataType: 'json',
			success: function (answer) {
				answer = (typeof studioEngineAnswer === 'function') ? studioEngineAnswer(answer) : (answer || {});
				if (answer.ok === true) { studioEngineParamErrorShown = false; return; }
				if (!studioEngineParamErrorShown && typeof studioEngineShowError === 'function') {
					studioEngineParamErrorShown = true;
					studioEngineShowError(answer.error || studioEffectText('the audio engine did not answer'));
				}
			},
			error: function () {
				if (!studioEngineParamErrorShown && typeof studioEngineShowError === 'function') {
					studioEngineParamErrorShown = true;
					studioEngineShowError(studioEffectText('the audio engine did not answer'));
				}
			}
		});
	}, 150);
}

// One knob of a track's insert: the track is the 0-based engine track, the
// name is the effect's canonical prefix, and the value is the contract's units.
function studioEngineInsertParam(ch, insertName, control, value) {
	var track = Math.max(0, (parseInt(ch, 10) || 1) - 1);
	var kind = studioEffectKind(insertName);
	var name = kind + '.' + control;
	studioEngineParamPost(
		{ action: 'param', track: track, name: name, value: studioEffectNatural(kind, control, value) },
		'take:' + track + ':' + name
	);
}

// A value already in the effect's own units, for a tempo-synced time or rate
// that a 0..100 slider cannot express (a four-bar delay is past the knob's
// 1.5 s). It is the same address as studioEngineInsertParam, without the
// mapping step.
function studioEngineInsertParamNatural(ch, insertName, control, value) {
	var track = Math.max(0, (parseInt(ch, 10) || 1) - 1);
	var kind = studioEffectKind(insertName);
	var name = kind + '.' + control;
	studioEngineParamPost(
		{ action: 'param', track: track, name: name, value: value },
		'take:' + track + ':' + name
	);
}

// The master rack is its own address: `master_comp` is the wire prefix the
// contract names, and the effect is the same implementation a track uses.
function studioEngineMasterParam(insertName, control, value) {
	var kind = studioEffectKind(insertName);
	var name = insertName + '.' + control;
	studioEngineParamPost(
		{ action: 'param', target: 'master', name: name, value: studioEffectNatural(kind, control, value) },
		'master:' + name
	);
}

// The master rack's footswitch. The value is the bypass flag (1 bypassed,
// 0 heard), not a knob: only an effect the take armed has a slot to move, so
// switching on an effect that was off when the take began waits for the next
// take (the help topic says so).
function studioEngineMasterBypass(insertName, bypassed) {
	studioEngineParamPost(
		{ action: 'param', target: 'master', name: insertName + '.bypass', value: bypassed ? 1 : 0 },
		'master:' + insertName + ':bypass'
	);
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
		natural: {},
		values: {}
	};
	fx.input.connect(fx.dry).connect(fx.output);
	fx.wet.connect(fx.output);
	fx.dry.gain.value = 0;
	fx.wet.gain.value = 1;
	fx.set = function (control, value) {
		// A typed control (the tempo sync field) stores its string and hands the
		// setter that same string. Numeric controls keep the 0..100 path.
		if (studioEffectTyped(fx.name, control)) {
			fx.values[control] = String(value);
			if (fx.setters[control]) { fx.setters[control](String(value)); }
			return;
		}
		var n = studioEffectNumber(value);
		if (n === null) { return; }
		fx.values[control] = value;
		if (fx.setters[control]) { fx.setters[control](n); }
	};
	// A natural value (already seconds, Hz or a whole index) goes straight to
	// the node. Tempo sync uses this; the manual knobs keep fx.set's mapping.
	fx.setNatural = function (control, value) {
		var n = studioEffectNumber(value);
		if (n === null) { return; }
		if (fx.natural[control]) { fx.natural[control](n); }
	};
	fx.setBypass = function (on) {
		fx.bypassed = !!on;
		fx.dry.gain.value = fx.bypassed ? 1 : 0;
		fx.wet.gain.value = fx.bypassed ? 0 : 1;
	};
	return fx;
}

// The typed controls the page keeps as text. Only the tempo sync field today.
var studioEffectTypedControls = {
	'delay.sync': 1,
	'flanger.sync': 1,
	'phaser.sync': 1,
	'tremolo.sync': 1,
	'stereo_panner.sync': 1,
	'modulator.sync': 1,
	'slider.sync': 1,
	'wah.sync': 1,
	'chorus.sync': 1,
	'vibrato.sync': 1
};

function studioEffectTyped(kind, control) {
	return !!studioEffectTypedControls[studioEffectKind(kind) + '.' + control];
}

// Wire a tempo-synced control's natural setter and give the insert its starting
// `sync` string. Call it after the builder has set the manual knob defaults, so
// an `off` sync resolves back to the value the knob already holds.
function studioEffectTempo(fx, natural) {
	var kind = studioEffectKind(fx.name);
	var control = studioTempoControls[kind];
	if (!control) { return; }
	fx.natural[control] = natural;
	fx.set('sync', 'off');
}

// A tanh soft-clip curve for the pedals whose output stage is the op-amp's
// finite output swing (Dyna Comp, Electric Mistress). The WaveShaper's domain
// is -1..1, so a sample beyond that is clamped to the curve's endpoint; the
// engine's tanh runs on the full amplitude. That is part of the node-graph
// approximation the audit names.
function studioTanhCurve() {
	var n = 2048;
	var curve = new Float32Array(n);
	for (var i = 0; i < n; i++) {
		curve[i] = Math.tanh((i * 2) / (n - 1) - 1);
	}
	return curve;
}

// ---- reverb ----------------------------------------------------------------

// One shape per model, in the contract's order. The numbers are the doc's
// character, not a sample library. Spring and Plate are built as mechanical
// tanks (below); Room, Hall and Cave keep the generated-noise shape.
var studioReverbShapes = [
	{ name: 'Room',   seconds: 0.8, decay: 3.2, bright: 0.55, early: 1.0, low: 0.15 },
	{ name: 'Spring', seconds: 1.8, decay: 2.6, bright: 0.95, early: 0.15, low: 0.2, spring: 1 },
	{ name: 'Plate',  seconds: 2.2, decay: 2.4, bright: 0.75, early: 0.3, low: 0.35, plate: 1 },
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

// A one-pole highpass followed by a one-pole lowpass, applied to a finished
// impulse. The engine's model_impulse shades its tank the same way.
function studioImpulseShade(data, rate, highpassHz, lowpassHz) {
	var i, alpha;
	if (highpassHz > 0) {
		alpha = 1 - Math.exp(-2 * Math.PI * highpassHz / rate);
		var low = 0;
		for (i = 0; i < data.length; i++) {
			low += (data[i] - low) * alpha;
			data[i] -= low;
		}
	}
	if (lowpassHz > 0) {
		alpha = 1 - Math.exp(-2 * Math.PI * lowpassHz / rate);
		var shaped = 0;
		for (i = 0; i < data.length; i++) {
			shaped += (data[i] - shaped) * alpha;
			data[i] = shaped;
		}
	}
}

function studioNormalizeImpulse(data) {
	var peak = 0, i;
	for (i = 0; i < data.length; i++) { peak = Math.max(peak, Math.abs(data[i])); }
	if (peak > 0) {
		for (i = 0; i < data.length; i++) { data[i] = data[i] / peak * 0.8; }
	}
}

// The Fender 6G15 tank: two comb loops (the two springs) mixed, then two
// Schroeder allpass sections for the spring's dispersion. The loop gain is the
// model's RT60 over each line's own length, so the tail ends where the contract
// says it does (engine/src/reverb.rs, tank_impulse).
function studioSpringImpulse(ctx, shape) {
	var rate = ctx.sampleRate;
	var length = Math.max(1, Math.floor(rate * shape.seconds));
	var buffer = ctx.createBuffer(2, length, rate);
	var combs = [0.0293, 0.0341];
	var allpasses = [0.0017, 0.0053];
	for (var c = 0; c < 2; c++) {
		var data = buffer.getChannelData(c);
		var loops = [];
		for (var n = 0; n < combs.length; n++) {
			var seconds = combs[n] + c * 0.0007 + n * 0.0003;
			var line = Math.max(1, Math.round(rate * seconds));
			loops.push({
				buf: new Float32Array(line),
				pos: 0,
				gain: Math.pow(10, -3 * (line / rate) / shape.seconds)
			});
		}
		for (var i = 0; i < length; i++) {
			var source = (i === 0) ? 1 : 0;
			var sum = 0;
			for (var l = 0; l < loops.length; l++) {
				var loop = loops[l];
				var read = loop.buf[loop.pos];
				loop.buf[loop.pos] = source + read * loop.gain;
				loop.pos = (loop.pos + 1) % loop.buf.length;
				sum += read;
			}
			data[i] = sum;
		}
		for (var a = 0; a < allpasses.length; a++) {
			var apLine = Math.max(1, Math.round(rate * allpasses[a]));
			var apBuf = new Float32Array(apLine);
			var apPos = 0, g = -0.5;
			for (var j = 0; j < length; j++) {
				var delayed = apBuf[apPos];
				var value = data[j] + g * delayed;
				apBuf[apPos] = value;
				apPos = (apPos + 1) % apLine;
				data[j] = -g * value + delayed;
			}
		}
		studioImpulseShade(data, rate, 350, 8000);
		studioNormalizeImpulse(data);
	}
	return buffer;
}

// The EMT 140 plate: a dense wall of short early reflections (no gap before the
// tail) over a diffuse, slowly decaying noise bed. The engine builds a short
// delay-line network plus diffusers; this is the same density in a buffer.
function studioPlateImpulse(ctx, shape) {
	var rate = ctx.sampleRate;
	var length = Math.max(1, Math.floor(rate * shape.seconds));
	var buffer = ctx.createBuffer(2, length, rate);
	for (var c = 0; c < 2; c++) {
		var data = buffer.getChannelData(c);
		var taps = 64;
		for (var k = 0; k < taps; k++) {
			var spread = (k + 1) / taps;
			var at = Math.floor(rate * (0.0004 + 0.011 * Math.pow(spread, 0.6))
				+ c * rate * 0.00013);
			var gain = Math.pow(0.92, k) * ((k % 2) ? -1 : 1) * 0.5;
			if (at < length) { data[at] += gain; }
		}
		var bright = 0, low = 0;
		for (var i = 0; i < length; i++) {
			var t = i / length;
			var white = Math.random() * 2 - 1;
			bright += shape.bright * (white - bright);
			low += 0.02 * (white - low);
			data[i] += (bright * (1 - shape.low) + low * shape.low * 3)
				* Math.pow(1 - t, shape.decay) * 0.25;
		}
		studioImpulseShade(data, rate, 90, 0);
		studioNormalizeImpulse(data);
	}
	return buffer;
}

// Room, Hall and Cave keep the generated-noise shape: a decaying filtered-noise
// bed with the Room's discrete first bounces.
function studioNoiseImpulse(ctx, shape) {
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
			data[i] = (bright * (1 - shape.low) + low * shape.low * 3)
				* Math.pow(1 - t, shape.decay);
		}
		if (shape.early > 0) {
			early.forEach(function (seconds, n) {
				var spot = Math.floor((seconds + c * 0.0017) * rate);
				if (spot < length) { data[spot] += (n % 2 ? -1 : 1) * 0.55 * shape.early; }
			});
		}
		studioNormalizeImpulse(data);
	}
	return impulse;
}

// Built once per context and cached on it: a model change is a buffer swap,
// not a new tank, and the impulse is generated away from the audio callback
// (contract rule 1). The cache lives on the context because a buffer belongs to
// the context that made it.
function studioReverbImpulse(ctx, model) {
	var index = studioReverbModel(model);
	if (!ctx.jawnosReverbCache) { ctx.jawnosReverbCache = {}; }
	var cache = ctx.jawnosReverbCache;
	if (cache[index]) { return cache[index]; }
	var shape = studioReverbShapes[index];
	var impulse;
	if (shape.spring) { impulse = studioSpringImpulse(ctx, shape); }
	else if (shape.plate) { impulse = studioPlateImpulse(ctx, shape); }
	else { impulse = studioNoiseImpulse(ctx, shape); }
	cache[index] = impulse;
	return impulse;
}

function studioEffectReverb(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'reverb');
	var convolver = ctx.createConvolver();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	// Natural units, as the contract sends them. The `* 2` keeps the browser's
	// own volume centring at slider 50 (the engine clamps to 0..1).
	var mix = 0.35, volume = 0.5;
	var apply = function () {
		wet.gain.value = mix * 0.9 * volume * 2;
		dry.gain.value = 1 - mix * 0.6;
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
	fx.setters['mix'] = function (v) { mix = studioEffectNatural(fx.name, 'mix', v); apply(); };
	fx.setters['volume'] = function (v) { volume = studioEffectNatural(fx.name, 'volume', v); apply(); };
	// The old reverb2 defaults: a little room on the signal, then its level.
	fx.set('model', 2);
	fx.set('mix', 35);
	fx.set('volume', 50);
	return fx;
}

// ---- flanger ---------------------------------------------------------------
// The Electro-Harmonix Electric Mistress. The line is a SAD1024-class BBD swept
// by a triangle clock: 0.7 ms at the fast end to 5 ms at the slow end. The input
// is pre-amplified about 6 dB, compressed 2:1 above the compander threshold and
// soft-clipped by the BBD input; the line's output is filtered at 6.8 kHz and
// highpassed at 160 Hz, and the Color feedback returns through the same pair.
// The expander, the clock's dark top end and the clock whine need an
// AudioWorklet (engine/src/effect/flanger.rs is the reference); the node graph
// keeps the compressor, the clip and the filtered feedback, which is the sound
// the pedal is bought for. Dry is `1 - mix`: the old `1 - mix * 0.5` let the dry
// signal ride over a fully wet setting.
var studioFlangerMinDelay = 0.0007;
var studioFlangerMaxSweep = 0.0043;

function studioEffectFlanger(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'flanger');
	var preGain = ctx.createGain();
	preGain.gain.value = 2;
	var comp = ctx.createDynamicsCompressor();
	comp.threshold.value = -14;
	comp.knee.value = 0;
	comp.ratio.value = 2;
	comp.attack.value = 0.004;
	comp.release.value = 0.12;
	var shaper = ctx.createWaveShaper();
	shaper.curve = studioTanhCurve();
	var delay = ctx.createDelay(0.05);
	var wetLP = ctx.createBiquadFilter();
	wetLP.type = 'lowpass';
	wetLP.frequency.value = 6800;
	wetLP.Q.value = 0.707;
	var wetHP = ctx.createBiquadFilter();
	wetHP.type = 'highpass';
	wetHP.frequency.value = 160;
	wetHP.Q.value = 0.707;
	var colorLP = ctx.createBiquadFilter();
	colorLP.type = 'lowpass';
	colorLP.frequency.value = 6800;
	colorLP.Q.value = 0.707;
	var colorHP = ctx.createBiquadFilter();
	colorHP.type = 'highpass';
	colorHP.frequency.value = 160;
	colorHP.Q.value = 0.707;
	var feedback = ctx.createGain();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	var lfo = ctx.createOscillator();
	var sweep = ctx.createGain();
	lfo.type = 'triangle';
	lfo.connect(sweep).connect(delay.delayTime);
	fx.input.connect(preGain).connect(comp).connect(shaper).connect(delay);
	delay.connect(wetLP).connect(wetHP);
	wetHP.connect(wet).connect(fx.wet);
	wetHP.connect(colorLP).connect(colorHP).connect(feedback).connect(delay);
	fx.input.connect(dry).connect(fx.wet);
	try { lfo.start(0); } catch (e) {}
	var depthValue = 0.6;
	var applyDepth = function () {
		var amount = studioEffectClamp(depthValue, 0, 1);
		var span = studioFlangerMaxSweep * amount;
		delay.delayTime.value = studioFlangerMinDelay + span * 0.5;
		sweep.gain.value = span * 0.5;
	};
	// The manual knob maps to 0.05..5 Hz; a tempo-synced 1/16 at 120 BPM is
	// 8 Hz, the engine's cap (engine/src/effect/flanger.rs).
	var applyRate = function (hz) { lfo.frequency.value = studioEffectClamp(hz, 0.05, 8); };
	fx.natural['rate'] = applyRate;
	fx.setters['rate'] = function (v) { applyRate(studioEffectNatural(fx.name, 'rate', v)); };
	fx.setters['depth'] = function (v) { depthValue = studioEffectNatural(fx.name, 'depth', v); applyDepth(); };
	fx.setters['feedback'] = function (v) { feedback.gain.value = studioEffectNatural(fx.name, 'feedback', v); };
	fx.setters['mix'] = function (v) {
		var n = studioEffectNatural(fx.name, 'mix', v);
		wet.gain.value = n;
		dry.gain.value = 1 - n;
	};
	fx.destroy = function () { try { lfo.stop(); } catch (e) {} };
	fx.set('rate', 20);
	fx.set('depth', 60);
	fx.set('feedback', 25);
	fx.set('mix', 50);
	studioEffectTempo(fx, applyRate);
	return fx;
}

// ---- phaser ----------------------------------------------------------------
// The MXR Phase 90: four JFET allpass stages swept together by an LFO and summed
// with the dry signal at a fixed 50/50 blend, which is where the notches come
// from. The real pedal has one Speed knob; `depth`, `feedback` and `mix` are the
// documented mods (docs/pedal-audit.md): depth sets the sweep span, feedback
// returns the last stage to the first for resonance, and mix moves the fixed
// blend. The engine is engine/src/effect/phaser.rs; the browser uses four
// `allpass` biquads staggered a little apart for a wider sweep, one LFO driving
// every corner through a depth gain, and an internal dry/wet pair that feeds
// `fx.wet` - never `fx.dry`, which is the shell's bypass path.
var studioPhaserBases = [ 250, 400, 650, 1000 ];
var studioPhaserSwing = 0.9;

function studioEffectPhaser(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'phaser');
	var stages = [];
	var depths = [];
	var i;
	for (i = 0; i < studioPhaserBases.length; i++) {
		var stage = ctx.createBiquadFilter();
		stage.type = 'allpass';
		stage.frequency.value = studioPhaserBases[i];
		stage.Q.value = 0.707;
		stages.push(stage);
		var depthGain = ctx.createGain();
		depthGain.gain.value = 0;
		depths.push(depthGain);
	}
	var lfo = ctx.createOscillator();
	lfo.type = 'sine';
	lfo.frequency.value = 1.04;
	for (i = 0; i < stages.length; i++) { lfo.connect(depths[i]).connect(stages[i].frequency); }

	var feedback = ctx.createGain();
	feedback.gain.value = 0;
	// A WebAudio feedback cycle needs a DelayNode; its delay is effectively one
	// render quantum, not the single sample the engine's tap takes, so the loop
	// sounds a little more resonant than the native one. The gain stays below
	// unity, so that is a difference in colour, never in stability.
	var feedbackDelay = ctx.createDelay(0.02);
	feedbackDelay.delayTime.value = 0;

	var wet = ctx.createGain();
	var dry = ctx.createGain();
	fx.input.connect(stages[0]);
	for (i = 1; i < stages.length; i++) { stages[i - 1].connect(stages[i]); }
	stages[stages.length - 1].connect(wet).connect(fx.wet);
	stages[stages.length - 1].connect(feedback).connect(feedbackDelay).connect(stages[0]);
	fx.input.connect(dry).connect(fx.wet);
	try { lfo.start(0); } catch (e) {}

	var depthValue = 0.5;
	var applyDepth = function () {
		var amount = studioEffectClamp(depthValue, 0, 1);
		for (var k = 0; k < depths.length; k++) {
			depths[k].gain.value = studioPhaserBases[k] * studioPhaserSwing * amount;
		}
	};
	// The manual knob maps to 0.05..5 Hz, the same band the engine holds.
	var applyRate = function (hz) { lfo.frequency.value = studioEffectClamp(hz, 0.05, 5); };
	fx.natural['rate'] = applyRate;
	fx.setters['rate'] = function (v) { applyRate(studioEffectNatural(fx.name, 'rate', v)); };
	fx.setters['depth'] = function (v) { depthValue = studioEffectNatural(fx.name, 'depth', v); applyDepth(); };
	fx.setters['feedback'] = function (v) {
		// An allpass has unit magnitude, so a loop gain below 1 cannot run away.
		feedback.gain.value = studioEffectClamp(studioEffectNatural(fx.name, 'feedback', v), 0, 0.9);
	};
	fx.setters['mix'] = function (v) {
		var n = studioEffectNatural(fx.name, 'mix', v);
		wet.gain.value = n;
		dry.gain.value = 1 - n;
	};
	fx.destroy = function () { try { lfo.stop(); } catch (e) {} };
	// Slider 20 maps to 1.04 Hz through the shared 0.05 + amount * 4.95 band,
	// which is also the engine's build() default.
	fx.set('rate', 20);
	fx.set('depth', 50);
	fx.set('feedback', 25);
	fx.set('mix', 50);
	studioEffectTempo(fx, applyRate);
	return fx;
}

// ---- fuzz / distortion / amp ----------------------------------------------

// The ProCo RAT: an LM308 non-inverting stage whose feedback pot is the Drive
// knob, so the gain runs from 2 to 200 over the travel. A pair of silicon
// diodes to ground clips the stage at about 0.7 V, and the pedal's fixed Filter
// is a two-pole lowpass at 4 kHz because the contract has no Filter control.
// The curve is asymmetric (the two diodes are not matched) and carries the
// diode's short exponential shoulder; the op-amp's gain-dependent bandwidth and
// slew are the part a WaveShaper cannot model (engine/src/effect.rs is the
// reference).
var studioRatCurveCache = null;

function studioRatCurve() {
	if (studioRatCurveCache) { return studioRatCurveCache; }
	var n = 4096;
	var curve = new Float32Array(n);
	var knee = 0.04;
	for (var i = 0; i < n; i++) {
		var x = (i * 2) / (n - 1) - 1;
		var forward = (x < 0) ? 0.74 : 0.66;
		var magnitude = Math.abs(x);
		if (magnitude <= forward) {
			curve[i] = x;
		}
		else {
			curve[i] = (x < 0 ? -1 : 1)
				* (forward + knee * (1 - Math.exp(-(magnitude - forward) / knee)));
		}
	}
	studioRatCurveCache = curve;
	return curve;
}

// The JH-2 is a two-transistor germanium fuzz: a common-emitter stage with a
// 68 kΩ feedback resistor from the second stage's emitter. The circuit clips
// one half of the wave before the other (germanium's soft, low knee), and the
// fuzz pot bypasses more of the second emitter as it turns up. The engine
// solves the circuit's own nodes; this is the same transfer as a table, plus
// the two coupling caps and the feedback cap's top end.
function studioJH2Curve(fuzz) {
	var n = 4096;
	var curve = new Float32Array(n);
	var drive = 3 + fuzz * 55;
	var bias = 0.10 + 0.16 * fuzz;
	var knee = 1.35;
	var stage = function (x) {
		var up = Math.exp(Math.min(20, drive * (x + bias) / knee)) - 1;
		var down = Math.exp(Math.min(20, drive * (bias - x) / knee)) - 1;
		return (up - down) / (1 + up + down);
	};
	var peak = 0;
	for (var i = 0; i < n; i++) {
		var x = (i * 2) / (n - 1) - 1;
		var y = stage(-stage(x) * 0.85);
		curve[i] = y;
		peak = Math.max(peak, Math.abs(y));
	}
	if (peak > 0) { for (var j = 0; j < n; j++) { curve[j] /= peak; } }
	return curve;
}
var studioJH2Curves = {};

function studioEffectFuzz(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'fuzz');
	var inputHP = ctx.createBiquadFilter();
	inputHP.type = 'highpass';
	inputHP.frequency.value = 7;
	inputHP.Q.value = 0.7;
	var shaper = ctx.createWaveShaper();
	shaper.oversample = '4x';
	var outputHP = ctx.createBiquadFilter();
	outputHP.type = 'highpass';
	outputHP.frequency.value = 25;
	outputHP.Q.value = 0.7;
	var tone = ctx.createBiquadFilter();
	tone.type = 'lowpass';
	tone.frequency.value = 3000;
	tone.Q.value = 0.8;
	var level = ctx.createGain();
	fx.input.connect(inputHP).connect(shaper).connect(outputHP).connect(tone).connect(level).connect(fx.wet);
	var curveFor = function (v) {
		var f = studioEffectNatural(fx.name, 'gain', v);
		var key = Math.round(f * 20) / 20;
		if (!studioJH2Curves[key]) { studioJH2Curves[key] = studioJH2Curve(key); }
		return studioJH2Curves[key];
	};
	fx.setters['gain'] = function (v) { shaper.curve = curveFor(v); };
	// The JH-2 has no tone knob; this is the feedback-cap mod. Low is the
	// 47 pF cap's dark end, high opens it.
	fx.setters['tone'] = function (v) {
		var t = studioEffectNatural(fx.name, 'tone', v);
		tone.frequency.value = 1200 * Math.pow(6.5, t);
	};
	fx.setters['level'] = function (v) { level.gain.value = studioEffectNatural(fx.name, 'level', v) * 1.4; };
	fx.set('gain', 65);
	fx.set('tone', 45);
	fx.set('level', 60);
	return fx;
}

function studioEffectDistortion(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'distortion');
	var inputHP = ctx.createBiquadFilter();
	inputHP.type = 'highpass';
	inputHP.frequency.value = 10;
	inputHP.Q.value = 0.707;
	var preGain = ctx.createGain();
	var shaper = ctx.createWaveShaper();
	shaper.curve = studioRatCurve();
	shaper.oversample = '4x';
	var lp1 = ctx.createBiquadFilter();
	lp1.type = 'lowpass';
	lp1.frequency.value = 4000;
	lp1.Q.value = 0.5;
	var lp2 = ctx.createBiquadFilter();
	lp2.type = 'lowpass';
	lp2.frequency.value = 4000;
	lp2.Q.value = 0.5;
	var trim = ctx.createGain();
	trim.gain.value = 0.7;
	fx.input.connect(inputHP).connect(preGain).connect(shaper)
		.connect(lp1).connect(lp2).connect(trim).connect(fx.wet);
	var drive = function (v) {
		var travel = studioEffectClamp(studioEffectNatural(fx.name, 'drive', v) * 100, 0, 100) / 100;
		preGain.gain.value = 2 + travel * travel * 198;
	};
	fx.setters['drive'] = drive;
	// The old shelf pedal's knob is called gain; the contract calls it drive.
	fx.setters['gain'] = drive;
	fx.set('drive', 50);
	return fx;
}

// 0 Combo (1x12), 1 Open (2x12), 2 Closed (4x12), 3 Tweed (4x10). The engine's
// four cabinets follow this order; each also chooses the valve voice that
// suits the box (6V6 combo, 6L6 open-back, EL34 stack, tweed 4x10).
var studioAmpCabinets = [
	{ name: 'Combo',  highpass: 85,  lowpass: 5200, peak1: 2600, peak1Db: 2, peak1Q: 1.1, peak2: 1100, peak2Db: 2,   peak2Q: 1.5, reflection: 1.1, reflectionGain: 0.40, drive: 1.0, stage2: 2.2, bias: 0.050, sag: 0.12 },
	{ name: 'Open',   highpass: 70,  lowpass: 6000, peak1: 3000, peak1Db: 3, peak1Q: 1.0, peak2: 1400, peak2Db: 1.5, peak2Q: 1.4, reflection: 1.5, reflectionGain: 0.35, drive: 0.9, stage2: 2.0, bias: 0.035, sag: 0.08 },
	{ name: 'Closed', highpass: 55,  lowpass: 4500, peak1: 2200, peak1Db: 5, peak1Q: 0.9, peak2: 900,  peak2Db: 3,   peak2Q: 1.8, reflection: 2.2, reflectionGain: 0.50, drive: 1.2, stage2: 2.6, bias: 0.080, sag: 0.15 },
	{ name: 'Tweed',  highpass: 95,  lowpass: 4000, peak1: 1800, peak1Db: 4, peak1Q: 0.9, peak2: 1200, peak2Db: 2,   peak2Q: 1.6, reflection: 0.9, reflectionGain: 0.45, drive: 1.1, stage2: 2.4, bias: 0.060, sag: 0.20 }
];

// A short speaker impulse: two damped cone/box resonances, a one-pole highpass
// and lowpass for the box, and one mic-distance reflection. It mirrors
// engine/src/effect/amp.rs's design_cabinet; the four voices share the shape.
function studioCabinetImpulse(ctx, cab) {
	var rate = ctx.sampleRate;
	var length = Math.max(64, Math.round(rate * 0.0053));
	var buffer = ctx.createBuffer(1, length, rate);
	var data = buffer.getChannelData(0);
	var hpA = 1 - Math.exp(-2 * Math.PI * cab.highpass / rate);
	var lpA = 1 - Math.exp(-2 * Math.PI * cab.lowpass / rate);
	var p1 = 2 * Math.PI * cab.peak1 / rate;
	var p2 = 2 * Math.PI * cab.peak2 / rate;
	var hp = 0;
	var lp = 0;
	var raw = new Float32Array(length);
	for (var i = 0; i < length; i++) {
		var t = i / rate;
		var x = (i === 0) ? 1 : 0;
		x += 0.20 * Math.sin(p1 * i) * Math.exp(-t / 0.006) * (cab.peak1Db / 5);
		x += 0.16 * Math.sin(p2 * i) * Math.exp(-t / 0.010) * (cab.peak2Db / 5);
		hp += (x - hp) * hpA;
		x -= hp;
		lp += (x - lp) * lpA;
		raw[i] = lp;
	}
	var delay = Math.max(1, Math.round(rate * cab.reflection / 1000));
	for (var j = length - 1; j >= delay; j--) { raw[j] += raw[j - delay] * cab.reflectionGain; }
	var sum = 0;
	for (var k = 0; k < length; k++) { sum += Math.abs(raw[k]); }
	if (sum > 0) { for (var m = 0; m < length; m++) { data[m] = raw[m] / sum; } }
	return buffer;
}

// A single-ended valve stage: a soft knee around the grid bias, with a little
// second harmonic so the two halves do not match.
function studioTubeCurve(drive, bias) {
	var n = 4096;
	var curve = new Float32Array(n);
	for (var i = 0; i < n; i++) {
		var x = (i * 2) / (n - 1) - 1;
		var y = Math.tanh(x * drive + bias) - Math.tanh(bias);
		curve[i] = y + 0.08 * y * y;
	}
	return curve;
}

function studioEffectAmp(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'amp');
	var pre = ctx.createGain();
	var stage1 = ctx.createWaveShaper();
	stage1.curve = studioTubeCurve(1.0, 0.05);
	stage1.oversample = '4x';
	var stage2 = ctx.createWaveShaper();
	stage2.curve = studioTubeCurve(0.7, -0.025);
	stage2.oversample = '4x';
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
	var convolver = ctx.createConvolver();
	var level = ctx.createGain();
	fx.input.connect(pre).connect(stage1).connect(stage2)
		.connect(bass).connect(mid).connect(treble)
		.connect(convolver).connect(level).connect(fx.wet);
	var impulses = {};
	var impulseFor = function (index) {
		if (!impulses[index]) { impulses[index] = studioCabinetImpulse(ctx, studioAmpCabinets[index]); }
		return impulses[index];
	};
	fx.setters['gain'] = function (v) {
		pre.gain.value = Math.pow(10, ((studioEffectNatural(fx.name, 'gain', v) - 0.5) * 2 * 24) / 20);
	};
	var shelf = function (filter, control, v) { filter.gain.value = studioEffectNatural(fx.name, control, v); };
	fx.setters['bass'] = function (v) { shelf(bass, 'bass', v); };
	fx.setters['mid'] = function (v) { shelf(mid, 'mid', v); };
	fx.setters['treble'] = function (v) { shelf(treble, 'treble', v); };
	fx.setters['cabinet'] = function (v) {
		var index = studioEffectNatural(fx.name, 'cabinet', v);
		convolver.buffer = impulseFor(index);
	};
	level.gain.value = 2.0;
	fx.set('gain', 50);
	fx.set('bass', 50);
	fx.set('mid', 50);
	fx.set('treble', 50);
	fx.set('cabinet', 2);
	return fx;
}

// ---- limiter / maximizer ---------------------------------------------------
// The UREI 1176's FET detector, shared with the maximizer. The real detector is
// an inline AudioWorkletProcessor (engine/src/effect/limiter.rs is the
// algorithm): a fixed 20 us attack, a program-dependent release that blends a
// fast and a slow time constant through a sustain memory, a soft 2.5 dB knee
// above the ceiling, and a hard clamp on every sample. The synchronous builder
// returns a DynamicsCompressor (ratio 20) plus a hard-ceiling WaveShaper while
// the module loads; the worklet replaces that chain when addModule resolves, so
// a browser without AudioWorklet keeps the documented node-graph approximation
// instead of a silent pedal.
var studioFetWorkletSource = [
	"class JawnosFetProcessor extends AudioWorkletProcessor {",
	"  constructor() {",
	"    super();",
	"    this.ceilingDb = -6; this.targetCeilingDb = -6;",
	"    this.release = 0.1; this.targetRelease = 0.1;",
	"    this.driveDb = 0; this.targetDriveDb = 0;",
	"    this.attack = 1 - Math.exp(-1 / (20e-6 * sampleRate));",
	"    this.channels = [];",
	"    this.port.onmessage = (e) => {",
	"      const d = e.data || {};",
	"      if (typeof d.ceiling === 'number') { this.targetCeilingDb = d.ceiling; }",
	"      if (typeof d.release === 'number') { this.targetRelease = d.release; }",
	"      if (typeof d.drive === 'number') { this.targetDriveDb = d.drive; }",
	"    };",
	"  }",
	"  state(index) {",
	"    if (!this.channels[index]) { this.channels[index] = { env: 0, sustain: 0 }; }",
	"    return this.channels[index];",
	"  }",
	"  process(inputs, outputs) {",
	"    const input = inputs[0] || [];",
	"    const output = outputs[0] || [];",
	"    const frames = (output.length && output[0]) ? output[0].length : 128;",
	"    const alpha = 1 - Math.exp(-frames / (0.02 * sampleRate));",
	"    this.ceilingDb += (this.targetCeilingDb - this.ceilingDb) * alpha;",
	"    this.release += (this.targetRelease - this.release) * alpha;",
	"    this.driveDb += (this.targetDriveDb - this.driveDb) * alpha;",
	"    const ceiling = Math.pow(10, this.ceilingDb / 20);",
	"    const drive = Math.pow(10, this.driveDb / 20);",
	"    const release = Math.max(1e-5, this.release);",
	"    const fast = 1 - Math.exp(-1 / (release * 0.35 * sampleRate));",
	"    const slow = 1 - Math.exp(-1 / (release * sampleRate));",
	"    const sustainCoef = 1 - Math.exp(-1 / (0.02 * sampleRate));",
	"    const kneeDb = 2.5, kneeBow = kneeDb / 4, kneeTop = Math.pow(10, kneeDb / 20);",
	"    for (let c = 0; c < output.length; c++) {",
	"      const out = output[c];",
	"      const inp = input[c] || input[0];",
	"      const st = this.state(c);",
	"      for (let i = 0; i < out.length; i++) {",
	"        const x = (inp ? inp[i] : 0) * drive;",
	"        const magnitude = Math.abs(x);",
	"        if (!isFinite(magnitude)) { out[i] = 0; continue; }",
	"        if (magnitude > st.env) { st.env += (magnitude - st.env) * this.attack; }",
	"        else {",
	"          const r = fast + (slow - fast) * st.sustain;",
	"          st.env += (magnitude - st.env) * r;",
	"          if (st.env < 0) { st.env = 0; }",
	"        }",
	"        let gain = 1;",
	"        if (ceiling > 0 && st.env > ceiling) {",
	"          if (st.env >= ceiling * kneeTop) { gain = ceiling / st.env; }",
	"          else {",
	"            const excess = 20 * Math.log10(st.env) - this.ceilingDb;",
	"            const u = Math.max(0, Math.min(1, excess / kneeDb));",
	"            const reduction = excess + 4 * kneeBow * u * (1 - u);",
	"            gain = Math.pow(10, -reduction / 20);",
	"          }",
	"        }",
	"        const depth = 1 - gain;",
	"        if (depth > st.sustain) { st.sustain += (depth - st.sustain) * sustainCoef; }",
	"        else { st.sustain += (depth - st.sustain) * slow; }",
	"        const safe = magnitude > ceiling ? ceiling / magnitude : 1;",
	"        gain = Math.min(gain, safe);",
	"        let y = x * gain;",
	"        if (y > ceiling) { y = ceiling; } else if (y < -ceiling) { y = -ceiling; }",
	"        out[i] = y;",
	"      }",
	"    }",
	"    return true;",
	"  }",
	"}",
	"registerProcessor('jawnos-fet', JawnosFetProcessor);"
].join('\n');

// One module per context: two inserts of the same family share the load, and
// the promise is cached on the context so the processor name is registered
// once. A failed load leaves the caller's synchronous fallback in place.
function studioFetWorkletReady(ctx) {
	if (!ctx || !ctx.audioWorklet) { return null; }
	if (ctx.jawnosFetWorklet) { return ctx.jawnosFetWorklet; }
	var url;
	try {
		url = URL.createObjectURL(new Blob([studioFetWorkletSource], { type: 'application/javascript' }));
	}
	catch (e) {
		return null;
	}
	ctx.jawnosFetWorklet = ctx.audioWorklet.addModule(url).then(
		function () { try { URL.revokeObjectURL(url); } catch (e) {} return true; },
		function () { return false; }
	);
	return ctx.jawnosFetWorklet;
}

// The fallback's hard ceiling: unity below the ceiling, flat at it above. The
// WaveShaper's domain is -1..1, so the ceiling is also its endpoint.
function studioFetCeilingCurve(ceiling) {
	var n = 4096;
	var curve = new Float32Array(n);
	for (var i = 0; i < n; i++) {
		var x = (i * 2) / (n - 1) - 1;
		curve[i] = Math.max(-ceiling, Math.min(ceiling, x));
	}
	return curve;
}

function studioEffectFet(ctx, name, maximizer) {
	var fx = studioEffectShell(ctx, name || (maximizer ? 'maximizer' : 'limiter'));
	var state = {
		ceiling: -6,
		release: maximizer ? 0.1 : 0.06,
		drive: 0
	};
	// Synchronous fallback: a 20:1 compressor plus a hard ceiling. It has no
	// program-dependent release and no soft knee; the worklet below has both.
	var makeup = ctx.createGain();
	var comp = ctx.createDynamicsCompressor();
	comp.ratio.value = 20;
	comp.knee.value = 0;
	comp.attack.value = 0.00002;
	comp.release.value = maximizer ? 0.1 : state.release;
	var ceilingShaper = ctx.createWaveShaper();
	ceilingShaper.curve = studioFetCeilingCurve(Math.pow(10, state.ceiling / 20));
	fx.input.connect(makeup).connect(comp).connect(ceilingShaper).connect(fx.wet);
	var apply = function () {
		var ceiling = Math.pow(10, state.ceiling / 20);
		makeup.gain.value = Math.pow(10, state.drive / 20);
		comp.threshold.value = state.ceiling;
		comp.release.value = maximizer ? 0.1 : Math.max(0.001, state.release);
		ceilingShaper.curve = studioFetCeilingCurve(ceiling);
		if (fx.fetNode) {
			fx.fetNode.port.postMessage({
				ceiling: state.ceiling,
				release: state.release,
				drive: state.drive
			});
		}
	};
	var cancelled = false;
	var ready = studioFetWorkletReady(ctx);
	if (ready) {
		ready.then(function (loaded) {
			if (!loaded || cancelled) { return; }
			var node;
			try { node = new AudioWorkletNode(ctx, 'jawnos-fet'); }
			catch (e) { return; }
			try { fx.input.disconnect(makeup); } catch (e) {}
			try { makeup.disconnect(); } catch (e) {}
			try { comp.disconnect(); } catch (e) {}
			try { ceilingShaper.disconnect(); } catch (e) {}
			fx.input.connect(node);
			node.connect(fx.wet);
			fx.fetNode = node;
			apply();
		});
	}
	fx.destroy = function () {
		cancelled = true;
		if (fx.fetNode) {
			try { fx.input.disconnect(fx.fetNode); } catch (e) {}
			try { fx.fetNode.disconnect(); } catch (e) {}
			fx.fetNode = null;
		}
	};
	fx.setters['ceiling'] = function (v) {
		state.ceiling = studioEffectNatural(fx.name, 'ceiling', v);
		apply();
	};
	if (maximizer) {
		fx.setters['loudness'] = function (v) {
			var amount = studioEffectNatural(fx.name, 'loudness', v);
			state.drive = amount * 18;
			apply();
		};
		fx.set('ceiling', 90);
		fx.set('loudness', 20);
	}
	else {
		fx.setters['release'] = function (v) {
			state.release = studioEffectNatural(fx.name, 'release', v) / 1000;
			apply();
		};
		fx.set('ceiling', 85);
		fx.set('release', 40);
	}
	return fx;
}

function studioEffectLimiter(ctx, name) {
	return studioEffectFet(ctx, name || 'limiter', false);
}

// A maximizer is the same 1176 detector behind a 0..18 dB drive: `loudness` is
// the drive, `ceiling` the hard limit, and the release is the engine's fixed
// 0.1 s because the master rack gives it no release knob.
function studioEffectMaximizer(ctx, name) {
	return studioEffectFet(ctx, name || 'maximizer', true);
}

// ---- equalizer / compressor / delay / tone --------------------------------
// The Baxandall bass/treble pair from engine/src/effect/equalizer.rs: one
// coupled second-order section whose bass and treble corners share a feedback
// loop, so each knob also reshapes the other arm's transition. The mid knob is
// the separate RBJ bell. Flat settings return exact identity coefficients, so
// the flat pedal is transparent. The coefficients are rebuilt in place when a
// bass or treble knob moves; `createIIRFilter` is synchronous, so this does not
// break studioInsert's contract. A browser without IIRFilterNode keeps the
// three cheap biquads and says so here.
function studioBaxandallCoefficients(rate, lowDb, highDb) {
	var bass = Math.pow(10, lowDb / 20);
	var treble = Math.pow(10, highDb / 20);
	var corner = function (hz) { return Math.max(1, Math.min(rate * 0.49, hz)); };
	var wLow = 2 * rate * Math.tan(Math.PI * corner(200) / rate);
	var wHigh = 2 * rate * Math.tan(Math.PI * corner(4000) / rate);
	// One zero per arm, at the corner scaled by that arm's plateau gain.
	var bassZero = wLow * bass;
	var trebleZero = wHigh;
	// The shared feedback loop shifts the two poles by the bass/treble balance,
	// keeping their product so the plateaus stay exactly `bass` and `treble`.
	var shift = Math.pow(bass / treble, 0.15);
	var poleLow = wLow * shift;
	var poleHigh = wHigh / shift;
	var n2 = treble;
	var n1 = trebleZero + bassZero * treble;
	var n0 = bassZero * trebleZero;
	var d1 = poleLow + poleHigh;
	var d0 = poleLow * poleHigh;
	// Bilinear transform: s = 2*rate*(1 - z^-1)/(1 + z^-1).
	var k = 2 * rate;
	var b0 = n2 * k * k + n1 * k + n0;
	var b1 = -2 * n2 * k * k + 2 * n0;
	var b2 = n2 * k * k - n1 * k + n0;
	var a0 = k * k + d1 * k + d0;
	var a1 = -2 * k * k + 2 * d0;
	var a2 = k * k - d1 * k + d0;
	if (!isFinite(a0) || Math.abs(a0) < 1e-12) { return null; }
	var feedforward = [b0 / a0, b1 / a0, b2 / a0];
	var feedback = [1, a1 / a0, a2 / a0];
	for (var i = 0; i < 3; i++) {
		if (!isFinite(feedforward[i]) || !isFinite(feedback[i])) { return null; }
	}
	return { feedforward: feedforward, feedback: feedback };
}

function studioEffectEqualizer(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'equalizer');
	var mid = ctx.createBiquadFilter();
	mid.type = 'peaking';
	mid.frequency.value = 1000;
	mid.Q.value = 1;
	var state = { low: 0, mid: 0, high: 0 };
	var coupled = null;
	var lowShelf = null;
	var highShelf = null;
	var canIIR = (typeof ctx.createIIRFilter === 'function');
	if (canIIR) {
		coupled = ctx.createIIRFilter([1, 0, 0], [1, 0, 0]);
		fx.input.connect(coupled).connect(mid).connect(fx.wet);
	}
	else {
		// No IIRFilterNode: the cheap approximation, three independent filters.
		lowShelf = ctx.createBiquadFilter();
		lowShelf.type = 'lowshelf';
		lowShelf.frequency.value = 200;
		highShelf = ctx.createBiquadFilter();
		highShelf.type = 'highshelf';
		highShelf.frequency.value = 4000;
		fx.input.connect(lowShelf).connect(highShelf).connect(mid).connect(fx.wet);
	}
	var design = function () {
		if (!canIIR) {
			lowShelf.gain.value = state.low;
			highShelf.gain.value = state.high;
			return;
		}
		var coefficients = studioBaxandallCoefficients(ctx.sampleRate, state.low, state.high);
		if (!coefficients) { return; }
		var next;
		try { next = ctx.createIIRFilter(coefficients.feedforward, coefficients.feedback); }
		catch (e) { return; }
		try { fx.input.disconnect(coupled); } catch (e) {}
		try { coupled.disconnect(mid); } catch (e) {}
		fx.input.connect(next);
		next.connect(mid);
		coupled = next;
	};
	fx.setters['low'] = function (v) {
		var db = studioEffectNatural(fx.name, 'low', v);
		if (db === state.low) { return; }
		state.low = db;
		design();
	};
	fx.setters['mid'] = function (v) {
		state.mid = studioEffectNatural(fx.name, 'mid', v);
		mid.gain.value = state.mid;
	};
	fx.setters['high'] = function (v) {
		var db = studioEffectNatural(fx.name, 'high', v);
		if (db === state.high) { return; }
		state.high = db;
		design();
	};
	fx.set('low', 50);
	fx.set('mid', 50);
	fx.set('high', 50);
	return fx;
}

// The MXR Dyna Comp: a CA3080 OTA with a fast attack, a slow release and the
// level-dependent squash no fixed-ratio compressor has. WebAudio's
// DynamicsCompressor supplies the four contract knobs (threshold, ratio, attack,
// release, knee); the tanh WaveShaper is the OTA's finite output swing, and the
// dry/wet mix is the pedal's parallel blend. The extra slope the OTA's control
// current adds at high level (the engine's SQUASH term) is the one part a
// node-graph compressor cannot follow; engine/src/effect.rs is the reference.
function studioEffectCompressor(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'compressor');
	var comp = ctx.createDynamicsCompressor();
	var shaper = ctx.createWaveShaper();
	shaper.curve = studioTanhCurve();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	fx.input.connect(comp).connect(shaper).connect(wet).connect(fx.wet);
	fx.input.connect(dry).connect(fx.wet);
	fx.setters['thresh'] = function (v) { comp.threshold.value = studioEffectNatural(fx.name, 'thresh', v); };
	fx.setters['attack'] = function (v) { comp.attack.value = Math.max(0.001, studioEffectNatural(fx.name, 'attack', v) / 1000); };
	fx.setters['ratio'] = function (v) { comp.ratio.value = studioEffectNatural(fx.name, 'ratio', v); };
	fx.setters['release'] = function (v) { comp.release.value = studioEffectNatural(fx.name, 'release', v) / 1000; };
	fx.setters['knee'] = function (v) { comp.knee.value = studioEffectNatural(fx.name, 'knee', v); };
	fx.setters['mix'] = function (v) {
		var n = studioEffectNatural(fx.name, 'mix', v);
		wet.gain.value = n;
		dry.gain.value = 1 - n;
	};
	fx.set('thresh', 50);
	fx.set('attack', 20);
	fx.set('ratio', 50);
	fx.set('release', 25);
	fx.set('knee', 30);
	fx.set('mix', 100);
	return fx;
}

// The Boss DM-2: a BBD line with an NE570-style compander and clock-dependent
// bandwidth. The engine's encoder/expander and its clock feedthrough need an
// AudioWorklet; the node graph keeps the input compressor, the DelayNode and
// the feedback lowpass whose corner follows the delay time, which is the DM-2's
// darkening repeat. The manual Time knob still maps to 0..1.5 s; the DelayNode
// is 8 s long so a tempo-synced four-bar delay (8 s at 120 BPM) fits. The wet
// path's first sample lands at `time` (the DelayNode's own delay); WebAudio's
// compressor has a few milliseconds of look-ahead the engine's feed-forward
// encoder does not, and that is the documented difference.
function studioDm2Bandwidth(seconds) {
	var time = Math.max(0.001, seconds);
	return Math.max(700, Math.min(8000, 8000 * Math.sqrt(0.02 / time)));
}

function studioEffectDelay(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'delay');
	var inputHP = ctx.createBiquadFilter();
	inputHP.type = 'highpass';
	inputHP.frequency.value = 20;
	inputHP.Q.value = 0.707;
	var comp = ctx.createDynamicsCompressor();
	comp.threshold.value = -30;
	comp.knee.value = 0;
	comp.ratio.value = 2;
	comp.attack.value = 0.005;
	comp.release.value = 0.08;
	// The engine's line is 8.5 s for the same four-bar ceiling.
	var delay = ctx.createDelay(8);
	var feedbackLP = ctx.createBiquadFilter();
	feedbackLP.type = 'lowpass';
	feedbackLP.frequency.value = 8000;
	feedbackLP.Q.value = 0.707;
	var feedback = ctx.createGain();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	fx.input.connect(inputHP).connect(comp).connect(delay);
	delay.connect(wet).connect(fx.wet);
	delay.connect(feedbackLP).connect(feedback).connect(delay);
	fx.input.connect(dry).connect(fx.wet);
	dry.gain.value = 0.7;
	// The effect's own time: a tempo division may be longer than the knob's
	// 1.5 s travel, so both the manual and the synced path land here.
	var applyTime = function (seconds) {
		var time = studioEffectClamp(seconds, 0.001, 8);
		delay.delayTime.value = time;
		feedbackLP.frequency.value = studioDm2Bandwidth(time);
	};
	fx.natural['time'] = applyTime;
	fx.setters['time'] = function (v) { applyTime(studioEffectNatural(fx.name, 'time', v)); };
	fx.setters['feedback'] = function (v) { feedback.gain.value = studioEffectNatural(fx.name, 'feedback', v); };
	fx.setters['vol'] = function (v) { wet.gain.value = studioEffectNatural(fx.name, 'vol', v); };
	fx.set('time', 35);
	fx.set('feedback', 30);
	fx.set('vol', 40);
	studioEffectTempo(fx, applyTime);
	return fx;
}

// ---- tremolo / stereo panner -----------------------------------------------
// The Tremolo is a mono amplitude modulator: a `depth`-scaled LFO rides on the
// gain between `1 - depth` and unity, with the shape index the engine shares
// (0 sine, 1 triangle, 2 square). The engine is `engine/src/effect/tremolo.rs`;
// the two sides agree on the number bands and may differ only in the square's
// edge smoothing. A tempo-synced `rate` is resolved to Hz before it arrives.
function studioEffectTremolo(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'tremolo');
	var amp = ctx.createGain();
	var lfo = ctx.createOscillator();
	var depthGain = ctx.createGain();
	lfo.type = 'sine';
	amp.gain.value = 1;
	depthGain.gain.value = 0;
	lfo.connect(depthGain).connect(amp.gain);
	fx.input.connect(amp).connect(fx.wet);
	try { lfo.start(0); } catch (e) {}
	var depthValue = 0.5;
	var applyDepth = function () {
		var d = studioEffectClamp(depthValue, 0, 1);
		amp.gain.value = 1 - d * 0.5;
		depthGain.gain.value = d * 0.5;
	};
	var applyRate = function (hz) { lfo.frequency.value = studioEffectClamp(hz, 0.1, 20); };
	fx.natural['rate'] = applyRate;
	fx.setters['rate'] = function (v) { applyRate(studioEffectNatural(fx.name, 'rate', v)); };
	fx.setters['depth'] = function (v) { depthValue = studioEffectNatural(fx.name, 'depth', v); applyDepth(); };
	fx.setters['shape'] = function (v) {
		var shape = Math.round(studioEffectNatural(fx.name, 'shape', v));
		lfo.type = (shape === 1) ? 'triangle' : ((shape === 2) ? 'square' : 'sine');
	};
	fx.set('rate', 25);
	fx.set('depth', 50);
	fx.set('shape', 0);
	studioEffectTempo(fx, applyRate);
	fx.destroy = function () { try { lfo.stop(); } catch (e) {} };
	return fx;
}

// A stereo panner whose modulation lands after the pedalboard, as the engine's
// does. Neither insert chain holds an L/R pair, so neither side pans inside it:
// the insert is a pass-through carrying a configuration, and the channel's own
// pan stage applies `depth * lfo` on top of the channel pan
// (engine/src/effect/stereo_panner.rs, `Effect::pan_lfo`). The browser's pan
// stage is still a real `ctx.createStereoPanner()` node, built in
// `studioChannelEngine`; it is not this insert's. The two sides share the
// controls (`rate`, `depth`, `shape`) and the shape indexes: 0 sine, 1
// triangle, 2 square.
//
// `fx.panner` is the resolved configuration the pan stage reads: `rate` in Hz
// (a tempo-synced rate arrives resolved), `depth` the swing in the -1..1 field,
// `shape` the whole index. Every setter updates it and asks the page to
// re-read the channel (the insert does not know which channel owns it).
function studioEffectStereoPanner(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'stereo_panner');
	fx.input.connect(fx.wet);
	fx.panner = { rate: 1, depth: 0, shape: 0 };
	var apply = function () {
		if (typeof studioPanLfoAll === 'function') { studioPanLfoAll(); }
	};
	var applyRate = function (hz) {
		fx.panner.rate = studioEffectClamp(hz, 0.1, 20);
		apply();
	};
	fx.natural['rate'] = applyRate;
	fx.setters['rate'] = function (v) { applyRate(studioEffectNatural(fx.name, 'rate', v)); };
	fx.setters['depth'] = function (v) {
		fx.panner.depth = studioEffectClamp(studioEffectNatural(fx.name, 'depth', v), 0, 1);
		apply();
	};
	fx.setters['shape'] = function (v) {
		fx.panner.shape = Math.round(studioEffectNatural(fx.name, 'shape', v));
		apply();
	};
	fx.set('rate', 25);
	fx.set('depth', 50);
	fx.set('shape', 0);
	studioEffectTempo(fx, applyRate);
	// The footswitch is heard at the pan stage, so it has to reach that stage too.
	var shellBypass = fx.setBypass;
	fx.setBypass = function (on) { shellBypass(on); apply(); };
	return fx;
}

// The channel strip's own three-band tone control. The exact passive FMV
// network is a 5x5 nodal solve at the block edge in the engine (ToneStack in
// engine/src/effect.rs), where the three pots load one another the way the
// circuit does. The browser keeps the three-biquad approximation below: the
// exact interaction needs an AudioWorklet, which is the remaining mirror work
// the pedal audit names.
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
	fx.setters['gain'] = function (v) { gain.gain.value = studioEffectNatural(fx.name, 'gain', v); };
	fx.setters['bass'] = function (v) { bass.gain.value = studioEffectNatural(fx.name, 'bass', v); };
	fx.setters['mid'] = function (v) { mid.gain.value = studioEffectNatural(fx.name, 'mid', v); };
	fx.setters['treble'] = function (v) { treble.gain.value = studioEffectNatural(fx.name, 'treble', v); };
	fx.set('gain', 50);
	fx.set('bass', 50);
	fx.set('mid', 50);
	fx.set('treble', 50);
	return fx;
}

// ---- stereo widener --------------------------------------------------------
// A mid/side matrix, not a Haas delay or an all-pass pair: mid = (L+R)/2 and
// side = (L-R)/2, the side is scaled by Width and the two are summed back into
// L and R. Width runs 0..2 (50 is the untouched image, 0 folds it to mono,
// 100 doubles the side) and Mix 0..1 (50 blends half the matrix with half the
// dry signal). The input is forced to two channels before the splitter, so a
// mono source arrives as L = R: its side is exactly zero and it stays mono,
// centred and finite at every Width, instead of becoming a phase-inverted pair
// invented out of one channel. The engine's inserts are mono processors, so
// there is no L/R pair to take a matrix from and a take omits this pedal
// (engine/src/effect.rs); the browser is the only place it runs.
function studioEffectStereoWidener(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'stereowidener');
	// Up-mix a mono source to two equal channels; a stereo one passes through.
	var two = ctx.createGain();
	two.channelCount = 2;
	two.channelCountMode = 'explicit';
	two.channelInterpretation = 'speakers';
	var split = ctx.createChannelSplitter(2);
	var merge = ctx.createChannelMerger(2);
	// mid = (L + R) / 2
	var mid = ctx.createGain();
	mid.gain.value = 0.5;
	// side = (L - R) / 2
	var side = ctx.createGain();
	side.gain.value = 0.5;
	var minus = ctx.createGain();
	minus.gain.value = -1;
	var width = ctx.createGain();
	width.gain.value = 1;
	// R is mid minus the widened side, so its own copy is inverted.
	var invert = ctx.createGain();
	invert.gain.value = -1;
	var wetGain = ctx.createGain();
	var dryGain = ctx.createGain();

	fx.input.connect(two).connect(split);
	split.connect(mid, 0);
	split.connect(mid, 1);
	split.connect(side, 0);
	split.connect(minus, 1);
	minus.connect(side);
	side.connect(width);
	mid.connect(merge, 0, 0);
	width.connect(merge, 0, 0);
	mid.connect(merge, 0, 1);
	width.connect(invert, 0);
	invert.connect(merge, 0, 1);
	two.connect(dryGain).connect(fx.wet);
	merge.connect(wetGain).connect(fx.wet);

	fx.setters['width'] = function (v) { width.gain.value = studioEffectNatural(fx.name, 'width', v); };
	fx.setters['mix'] = function (v) {
		var n = studioEffectNatural(fx.name, 'mix', v);
		wetGain.gain.value = n;
		dryGain.gain.value = 1 - n;
	};
	fx.set('width', 50);
	fx.set('mix', 50);
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
	return studioEffectNatural('autotune', 'key', value);
}

function studioAutotuneScale(value) {
	return studioEffectNatural('autotune', 'scale', value);
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
		shiftGrains: [],
		shiftNext: 0,
		shiftSample: 0,
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

// A fixed ratio (pitch_shift) is a stream of resampled grains, not the
// corrector's detected splice. Every grain reads at 2^(semitones/12), so the
// interval is exact; grains sit end to end with a short raised-cosine seam, so
// only the seam crossfades two copies. A triangular two-tap crossfade keeps
// both copies audible all the time and, at the larger intervals, cancels the
// shifted carrier (an octave would come out almost a semitone flat). This is
// the model engine/src/effect/pitch_shift.rs uses, so -24..+24 semitones are
// the same interval on both sides. The builder delays the dry leg by BASE so a
// partial mix cannot comb.
var STUDIO_PITCH_BASE_SECONDS = 0.04;
var STUDIO_PITCH_MAX_GRAIN_SECONDS = 0.12;
var STUDIO_PITCH_FADE = 0.1;
function studioPitchShiftBlock(state, event, settings) {
	var input = event.inputBuffer;
	var output = event.outputBuffer;
	var channels = Math.min(input.numberOfChannels, output.numberOfChannels);
	if (!channels) { return; }
	var n = input.length, rate = state.rate, size = state.ringSize;
	if (state.rings.length !== channels) {
		state.rings = [];
		state.write = 0;
		state.shiftSample = 0;
		state.shiftNext = 0;
		state.shiftGrains = [];
	}
	var ratio = (settings.ratio > 0) ? settings.ratio : 1;
	var base = Math.max(64, Math.round(rate * STUDIO_PITCH_BASE_SECONDS));
	var maxLength = Math.max(64, Math.min(size / 4, Math.round(rate * STUDIO_PITCH_MAX_GRAIN_SECONDS)));
	var span = Math.abs(1 - ratio);
	var length = (span < 1e-4)
		? maxLength
		: Math.max(64, Math.min(maxLength, Math.round(base / span)));
	var fade = Math.max(16, Math.min(length / 2, Math.round(length * STUDIO_PITCH_FADE)));
	var hop = Math.max(1, length - fade);
	var ins = [], outs = [], rings = [];
	for (var c = 0; c < channels; c++) {
		rings[c] = state.rings[c] || (state.rings[c] = new Float32Array(size));
		ins[c] = input.getChannelData(c);
		outs[c] = output.getChannelData(c);
	}
	// capture the whole block first: grains read history, never the future
	for (var i = 0; i < n; i++) {
		for (var w = 0; w < channels; w++) { rings[w][state.write] = ins[w][i]; }
		state.write = (state.write + 1) % size;
	}
	// Schedule from the ratio this block starts with; a knob move lands on the
	// next grain, one seam away.
	var blockStart = state.shiftSample, blockEnd = blockStart + n;
	if (state.shiftNext < blockStart) { state.shiftNext = blockStart; }
	var guard = 0;
	while (state.shiftNext < blockEnd && guard++ < 4096) {
		state.shiftGrains.push({
			start: state.shiftNext, length: length, fade: fade, base: base, ratio: ratio
		});
		state.shiftNext += hop;
	}
	state.shiftGrains = state.shiftGrains.filter(function (grain) {
		return grain.start + grain.length > blockStart;
	});
	var weights = state.shiftWeights;
	if (!weights || weights.length < n) { weights = state.shiftWeights = new Float64Array(Math.max(1024, n)); }
	var s, c2;
	for (s = 0; s < n; s++) {
		weights[s] = 0;
		for (c2 = 0; c2 < channels; c2++) { outs[c2][s] = 0; }
	}
	for (var gi = 0; gi < state.shiftGrains.length; gi++) {
		var grain = state.shiftGrains[gi];
		var from = Math.max(0, Math.ceil(grain.start - blockStart));
		var to = Math.min(n, Math.ceil(grain.start + grain.length - blockStart));
		for (s = from; s < to; s++) {
			var p = blockStart + s - grain.start;
			if (p < 0 || p >= grain.length) { continue; }
			var gain = 1;
			if (p < grain.fade) {
				gain = 0.5 - 0.5 * Math.cos(Math.PI * p / grain.fade);
			}
			else if (p > grain.length - grain.fade) {
				gain = 0.5 - 0.5 * Math.cos(Math.PI * (grain.length - p) / grain.fade);
			}
			var delay = grain.base + p * (1 - grain.ratio);
			if (delay < 0) { continue; }
			weights[s] += gain;
			// the write index of this sample is the captured block's end minus
			// the samples still ahead of it
			var at = state.write - n + s;
			for (c2 = 0; c2 < channels; c2++) {
				outs[c2][s] += studioAutotuneRead(rings[c2], size, at - delay) * gain;
			}
		}
	}
	for (s = 0; s < n; s++) {
		if (weights[s] > 1e-6) {
			for (c2 = 0; c2 < channels; c2++) { outs[c2][s] /= weights[s]; }
		}
	}
	state.shiftSample = blockEnd;
}

function studioAutotuneBlock(state, event, settings) {
	// The pitch shifter has its own fixed-ratio path; the detected correction
	// below is only for autotune and the harmonizer.
	if (settings.ratio > 0) { studioPitchShiftBlock(state, event, settings); return; }
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
	// A fixed target (the harmonizer's diatonic interval) overrides the
	// corrector's nearest-scale-tone choice; autotune leaves it undefined.
	var target = (typeof settings.target === 'function')
		? settings.target(hz)
		: studioAutotuneTarget(hz, settings.key, settings.scale);
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
		var glide = 0.05 + settings.speed * 0.9;
		state.period += (inputPeriod - state.period) * glide;
		var wanted = inputPeriod + (targetPeriod - inputPeriod) * settings.amount;
		state.target += (wanted - state.target) * glide;
	}
	var period = state.period > 0 ? state.period : 128;
	period = Math.max(16, Math.min(rate / 40, period));
	var synth = state.target > 0 ? state.target : period;
	synth = Math.max(16, Math.min(rate / 40, synth));

	// The corrector lays one grain per estimated period and the harmonizer moves
	// the detected note; the shifter's fixed ratio never reaches here.
	var step = synth, hop = synth, grainFactor = 2;

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
			length: Math.max(32, Math.round(grainFactor * period))
		});
		state.analysis += step;
		state.nextGrain += hop;
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
		// the Hann windows may not sum to one when overlapping grains differ;
		// normalise so a partial amount cannot change the level
		for (s = 0; s < n; s++) {
			if (weights[s] > 1e-6) { out[s] = out[s] / weights[s]; }
		}
	}
	state.sample = blockEnd;
}

// No script processor? The correction is the same; only the scheduling moves
// to a timer, which sweeps two delay heads a grain at a time.
function studioAutotuneRamp(ctx, fx, settings) {
	var grain = settings.grain || 0.08, base = settings.base || 0.16;
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
		var desired;
		if (settings.ratio > 0) {
			// pitch_shift: a fixed ratio, no detector and no 0.5..2 cap.
			desired = settings.ratio;
		}
		else {
			analyser.getFloatTimeDomainData(data);
			var hz = studioAutotunePitch(data, ctx.sampleRate, corr);
			var target = (typeof settings.target === 'function')
				? settings.target(hz)
				: studioAutotuneTarget(hz, settings.key, settings.scale);
			desired = (hz > 0 && target > 0) ? target / hz : 1;
			desired = 1 + (desired - 1) * settings.amount;
			desired = Math.max(0.5, Math.min(2, desired));
		}
		ratio += (desired - ratio) * (0.1 + settings.speed * 0.8);
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
	var settings = { speed: 0.4, amount: 1, key: 0, scale: 0 };
	fx.setters['speed'] = function (v) { settings.speed = studioEffectNatural(fx.name, 'speed', v); };
	fx.setters['amount'] = function (v) { settings.amount = studioEffectNatural(fx.name, 'amount', v); };
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

// ---- the ten pedals in .shots/PEDAL-SPEC.md -------------------------------
// The browser side of the new pedals. The engine has its own files; both sides
// share the wire names, control order and natural units, not samples. Each
// builder ends by setting the contract's defaults through fx.set (a default
// whose natural value lands between slider steps is given as that fraction).

// The harmonizer's diatonic interval: the nearest scale tone to `hz`, moved
// `degree - 3` scale steps (0..6 is 4th below .. 4th above). A chord gives the
// detector one pitch only - this and the autotune above are monophonic.
function studioHarmonizerTarget(hz, key, scale, degree) {
	if (!(hz > 0)) { return 0; }
	var steps = Math.round(studioEffectClamp(degree, 0, 6)) - 3;
	if (steps === 0) { return hz; }
	var tones = studioAutotuneScales[scale] || studioAutotuneScales[0];
	var midi = 69 + 12 * Math.log(hz / 440) / Math.LN2;
	var base = Math.round(midi);
	var best = base, bestIndex = -1, bestDistance = 1e9;
	for (var n = base - 1; n <= base + 1; n++) {
		var pc = ((n % 12) + 12) % 12;
		for (var i = 0; i < tones.length; i++) {
			if ((((tones[i] + key) % 12) + 12) % 12 === pc) {
				var distance = Math.abs(n - midi);
				if (distance < bestDistance) { bestDistance = distance; best = n; bestIndex = i; }
				break;
			}
		}
	}
	if (bestIndex < 0) { return hz; }
	var raw = bestIndex + steps;
	var octave = Math.floor(raw / tones.length);
	var index = ((raw % tones.length) + tones.length) % tones.length;
	var targetMidi = best + (tones[index] - tones[bestIndex]) + 12 * octave;
	return 440 * Math.pow(2, (targetMidi - 69) / 12);
}

// The two grain pedals share this: a 1024-sample ScriptProcessor running the
// autotune grain block, or the two-head delay ramp when the browser has none.
// Returns the teardown the shell stores as fx.destroy.
function studioEffectGrain(ctx, input, wet, settings) {
	var maker = ctx.createScriptProcessor || ctx.createJavaScriptNode;
	if (maker) {
		var node = maker.call(ctx, 1024, 2, 2);
		var state = studioAutotuneState(ctx.sampleRate);
		node.onaudioprocess = function (event) { studioAutotuneBlock(state, event, settings); };
		input.connect(node).connect(wet);
		return function () {
			try { input.disconnect(node); } catch (e) {}
			try { node.disconnect(); } catch (e) {}
		};
	}
	return studioAutotuneRamp(ctx, { input: input, wet: wet }, settings);
}

// Harmonizer: a monophonic diatonic harmony. It tracks one pitch from the
// input (channel one of the detector) and re-synthesises the same signal a
// fixed number of scale steps away, then mixes the copy with dry at `mix`.
// The grain path carries about 80 ms of look-back plus one 1024-sample block
// of latency; a chord confuses the detector, the same limit the autotune above
// documents, so this is not a polyphonic harmoniser.
function studioEffectHarmonizer(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'harmonizer');
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	var settings = { amount: 1, speed: 0.5, key: 0, scale: 0, degree: 5 };
	settings.target = function (hz) {
		return studioHarmonizerTarget(hz, settings.key, settings.scale, settings.degree);
	};
	var mix = 0.35;
	var applyMix = function () {
		wet.gain.value = mix;
		dry.gain.value = 1 - mix;
	};
	fx.setters['key'] = function (v) { settings.key = studioEffectNatural(fx.name, 'key', v); };
	fx.setters['scale'] = function (v) { settings.scale = studioEffectNatural(fx.name, 'scale', v); };
	fx.setters['degree'] = function (v) { settings.degree = studioEffectNatural(fx.name, 'degree', v); };
	fx.setters['mix'] = function (v) { mix = studioEffectNatural(fx.name, 'mix', v); applyMix(); };
	wet.connect(fx.wet);
	fx.input.connect(dry).connect(fx.wet);
	fx.destroy = studioEffectGrain(ctx, fx.input, wet, settings);
	fx.set('key', 0);
	fx.set('scale', 0);
	fx.set('degree', 5);
	fx.set('mix', 35);
	return fx;
}

// Pitch shift: a fixed-interval shifter, ratio 2^(semitones/12). It does not
// detect pitch; it reads the input as a stream of grains at the ratio, so any
// material shifts (a chord included) by exactly the chosen interval from -24
// to +24 semitones. The wet leg sits a base-look-back behind, so the dry leg is
// delayed by the same amount before the two are mixed.
function studioEffectPitchShift(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'pitch_shift');
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	var dryDelay = ctx.createDelay(0.1);
	dryDelay.delayTime.value = STUDIO_PITCH_BASE_SECONDS;
	var settings = {
		amount: 0, speed: 0.5, key: 0, scale: 0,
		ratio: Math.pow(2, 7 / 12),
		base: STUDIO_PITCH_BASE_SECONDS, grain: 0.04
	};
	var mix = 1;
	var applyMix = function () {
		wet.gain.value = mix;
		dry.gain.value = 1 - mix;
	};
	fx.setters['semitones'] = function (v) {
		var semitones = studioEffectNatural(fx.name, 'semitones', v);
		settings.ratio = Math.pow(2, semitones / 12);
	};
	fx.setters['mix'] = function (v) { mix = studioEffectNatural(fx.name, 'mix', v); applyMix(); };
	wet.connect(fx.wet);
	fx.input.connect(dryDelay).connect(dry).connect(fx.wet);
	fx.destroy = studioEffectGrain(ctx, fx.input, wet, settings);
	fx.set('semitones', 64.583);
	fx.set('mix', 100);
	return fx;
}

// De-esser: a lowpass/highpass split at `freq`; only the high band runs through
// a peak follower that reduces it once the band passes `thresh`. `amount`
// scales the maximum reduction from 0 to 24 dB, so 0 leaves the band alone.
// The low band is delayed by one script block so the halves line up; the split
// is a 2nd-order pair, not a linear-phase crossover.
function studioDeEsserBlock(state, event, settings) {
	var input = event.inputBuffer;
	var output = event.outputBuffer;
	var n = input.length;
	var rate = input.sampleRate;
	var src = input.getChannelData(0);
	if (!state.gains || state.gains.length < n) { state.gains = new Float32Array(n); }
	var gains = state.gains;
	var thresh = Math.pow(10, settings.thresh / 20);
	var attack = Math.exp(-1 / (rate * 0.001));
	var release = Math.exp(-1 / (rate * 0.05));
	var detRelease = Math.exp(-1 / (rate * 0.02));
	var env = state.env, gain = state.gain;
	for (var i = 0; i < n; i++) {
		var x = Math.abs(src[i]);
		env = (x > env) ? x : env + (x - env) * detRelease;
		var target = 1;
		if (env > thresh && thresh > 0) {
			var overDb = 20 * Math.log(env / thresh) / Math.LN10;
			target = Math.pow(10, -Math.min(24, overDb) * settings.amount / 20);
		}
		var coef = (target < gain) ? attack : release;
		gain = target + (gain - target) * coef;
		gains[i] = gain;
	}
	state.env = env;
	state.gain = gain;
	var channels = Math.min(input.numberOfChannels, output.numberOfChannels);
	for (var c = 0; c < channels; c++) {
		var inData = input.getChannelData(c);
		var out = output.getChannelData(c);
		for (var s = 0; s < n; s++) { out[s] = inData[s] * gains[s]; }
	}
}

function studioEffectDeEsser(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'de_esser');
	var low = ctx.createBiquadFilter();
	low.type = 'lowpass';
	low.frequency.value = 6500;
	low.Q.value = 0.707;
	var high = ctx.createBiquadFilter();
	high.type = 'highpass';
	high.frequency.value = 6500;
	high.Q.value = 0.707;
	var settings = { thresh: -28, freq: 6500, amount: 0.6 };
	var maker = ctx.createScriptProcessor || ctx.createJavaScriptNode;
	if (maker) {
		var node = maker.call(ctx, 1024, 2, 2);
		var state = { env: 0, gain: 1, gains: null };
		node.onaudioprocess = function (event) { studioDeEsserBlock(state, event, settings); };
		var align = ctx.createDelay(0.25);
		align.delayTime.value = node.bufferSize / ctx.sampleRate;
		fx.input.connect(low).connect(align).connect(fx.wet);
		fx.input.connect(high).connect(node).connect(fx.wet);
		fx.destroy = function () {
			try { high.disconnect(node); } catch (e) {}
			try { node.disconnect(); } catch (e) {}
		};
	}
	else {
		// No script processor: keep the split and skip the reduction. The knobs
		// still save and travel.
		fx.input.connect(low).connect(fx.wet);
		fx.input.connect(high).connect(fx.wet);
	}
	fx.setters['thresh'] = function (v) { settings.thresh = studioEffectNatural(fx.name, 'thresh', v); };
	fx.setters['freq'] = function (v) {
		settings.freq = studioEffectNatural(fx.name, 'freq', v);
		low.frequency.value = settings.freq;
		high.frequency.value = settings.freq;
	};
	fx.setters['amount'] = function (v) { settings.amount = studioEffectNatural(fx.name, 'amount', v); };
	fx.set('thresh', 53.333);
	fx.set('freq', 31.25);
	fx.set('amount', 60);
	return fx;
}

// Gate: a noise gate with a peak detector. Below `thresh` the gain holds for
// `hold` ms and then closes toward `range` dB over `release`; it opens over
// `attack`. `range` 0 dB is the transparent setting. The detector runs on
// channel one and the same gain is applied to every channel (a mono insert).
function studioGateBlock(state, event, settings) {
	var input = event.inputBuffer;
	var output = event.outputBuffer;
	var n = input.length;
	var rate = input.sampleRate;
	var src = input.getChannelData(0);
	if (!state.gains || state.gains.length < n) { state.gains = new Float32Array(n); }
	var gains = state.gains;
	var thresh = Math.pow(10, settings.thresh / 20);
	var floor = Math.pow(10, settings.range / 20);
	var attack = Math.exp(-1 / (rate * Math.max(0.0001, settings.attack / 1000)));
	var release = Math.exp(-1 / (rate * Math.max(0.001, settings.release / 1000)));
	var detRelease = Math.exp(-1 / (rate * 0.01));
	var holdSamples = Math.max(0, Math.round(settings.hold / 1000 * rate));
	var env = state.env, gain = state.gain, hold = state.hold;
	for (var i = 0; i < n; i++) {
		var x = Math.abs(src[i]);
		env = (x > env) ? x : env + (x - env) * detRelease;
		var target;
		if (env > thresh) { hold = holdSamples; target = 1; }
		else if (hold > 0) { hold--; target = 1; }
		else { target = floor; }
		var coef = (target > gain) ? attack : release;
		gain = target + (gain - target) * coef;
		gains[i] = gain;
	}
	state.env = env;
	state.gain = gain;
	state.hold = hold;
	var channels = Math.min(input.numberOfChannels, output.numberOfChannels);
	for (var c = 0; c < channels; c++) {
		var inData = input.getChannelData(c);
		var out = output.getChannelData(c);
		for (var s = 0; s < n; s++) { out[s] = inData[s] * gains[s]; }
	}
}

function studioEffectGate(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'gate');
	var settings = { thresh: -45, attack: 1, hold: 50, release: 150, range: -60 };
	var maker = ctx.createScriptProcessor || ctx.createJavaScriptNode;
	if (maker) {
		var node = maker.call(ctx, 1024, 2, 2);
		var state = { env: 0, gain: 1, hold: 0, gains: null };
		node.onaudioprocess = function (event) { studioGateBlock(state, event, settings); };
		fx.input.connect(node).connect(fx.wet);
		fx.destroy = function () {
			try { fx.input.disconnect(node); } catch (e) {}
			try { node.disconnect(); } catch (e) {}
		};
	}
	else {
		// No script processor: a transparent pass-through, never a stuck gate.
		fx.input.connect(fx.wet);
	}
	fx.setters['thresh'] = function (v) { settings.thresh = studioEffectNatural(fx.name, 'thresh', v); };
	fx.setters['attack'] = function (v) { settings.attack = studioEffectNatural(fx.name, 'attack', v); };
	fx.setters['hold'] = function (v) { settings.hold = studioEffectNatural(fx.name, 'hold', v); };
	fx.setters['release'] = function (v) { settings.release = studioEffectNatural(fx.name, 'release', v); };
	fx.setters['range'] = function (v) { settings.range = studioEffectNatural(fx.name, 'range', v); };
	fx.set('thresh', 25);
	fx.set('attack', 1.804);
	fx.set('hold', 10);
	fx.set('release', 13.265);
	fx.set('range', 25);
	return fx;
}

// Slider: a hard-cutting tremolo. A square LFO opens the gain while the phase
// is below `duty` and cuts it to 1 - depth for the rest of the cycle; the
// edges are hard on purpose, like the tremolo's square. Only knob moves are
// smoothed, and the phase stays continuous across a rate change.
function studioSliderBlock(state, event, settings) {
	var input = event.inputBuffer;
	var output = event.outputBuffer;
	var n = input.length;
	var step = settings.rate / input.sampleRate;
	var depth = settings.depth;
	var duty = settings.duty;
	if (!state.gains || state.gains.length < n) { state.gains = new Float32Array(n); }
	var gains = state.gains;
	var phase = state.phase;
	for (var i = 0; i < n; i++) {
		gains[i] = (phase < duty) ? 1 : (1 - depth);
		phase += step;
		if (phase >= 1) { phase -= Math.floor(phase); }
	}
	state.phase = phase;
	var channels = Math.min(input.numberOfChannels, output.numberOfChannels);
	for (var c = 0; c < channels; c++) {
		var inData = input.getChannelData(c);
		var out = output.getChannelData(c);
		for (var s = 0; s < n; s++) { out[s] = inData[s] * gains[s]; }
	}
}

function studioEffectSlider(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'slider');
	var settings = { rate: 6, depth: 0.8, duty: 0.5 };
	var lfo = null, amp = null, depthGain = null;
	var maker = ctx.createScriptProcessor || ctx.createJavaScriptNode;
	if (maker) {
		var node = maker.call(ctx, 1024, 2, 2);
		var state = { phase: 0, gains: null };
		node.onaudioprocess = function (event) { studioSliderBlock(state, event, settings); };
		fx.input.connect(node).connect(fx.wet);
		fx.destroy = function () {
			try { fx.input.disconnect(node); } catch (e) {}
			try { node.disconnect(); } catch (e) {}
		};
	}
	else {
		// No script processor: a 50% square LFO into a gain. Duty cannot be
		// honoured on this path, which is the documented fallback.
		amp = ctx.createGain();
		depthGain = ctx.createGain();
		lfo = ctx.createOscillator();
		lfo.type = 'square';
		lfo.connect(depthGain).connect(amp.gain);
		fx.input.connect(amp).connect(fx.wet);
		try { lfo.start(0); } catch (e) {}
	}
	fx.setters['rate'] = function (v) {
		settings.rate = studioEffectNatural(fx.name, 'rate', v);
		if (lfo) { lfo.frequency.value = settings.rate; }
	};
	fx.setters['depth'] = function (v) {
		settings.depth = studioEffectNatural(fx.name, 'depth', v);
		if (lfo) {
			amp.gain.value = 1 - settings.depth * 0.5;
			depthGain.gain.value = settings.depth * 0.5;
		}
	};
	fx.setters['duty'] = function (v) { settings.duty = studioEffectNatural(fx.name, 'duty', v); };
	fx.set('rate', 29.648);
	fx.set('depth', 80);
	fx.set('duty', 50);
	studioEffectTempo(fx, function (hz) {
		settings.rate = studioEffectClamp(hz, 0.1, 20);
		if (lfo) { lfo.frequency.value = settings.rate; }
	});
	return fx;
}

// Overdrive: a highpass into a soft asymmetric clip, a tone lowpass and a
// level. The curve leans one way like a valve stage; the WaveShaper clamps
// beyond -1..1, which is where the pre-gain's hardest drive lands (the same
// node-graph limit studioTanhCurve documents).
function studioOverdriveCurve() {
	var n = 2048;
	var curve = new Float32Array(n);
	var bias = 0.09;
	var zero = Math.tanh(bias * 2);
	for (var i = 0; i < n; i++) {
		var x = (i * 2) / (n - 1) - 1;
		curve[i] = Math.tanh((x + bias) * 2) - zero;
	}
	return curve;
}

function studioEffectOverdrive(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'overdrive');
	var highpass = ctx.createBiquadFilter();
	highpass.type = 'highpass';
	highpass.frequency.value = 720;
	highpass.Q.value = 0.707;
	var preGain = ctx.createGain();
	var shaper = ctx.createWaveShaper();
	shaper.curve = studioOverdriveCurve();
	shaper.oversample = '4x';
	var tone = ctx.createBiquadFilter();
	tone.type = 'lowpass';
	tone.frequency.value = 1900;
	tone.Q.value = 0.707;
	var level = ctx.createGain();
	fx.input.connect(highpass).connect(preGain).connect(shaper).connect(tone).connect(level).connect(fx.wet);
	fx.setters['drive'] = function (v) {
		var d = studioEffectNatural(fx.name, 'drive', v);
		preGain.gain.value = 1 + d * 49;
	};
	fx.setters['tone'] = function (v) {
		var t = studioEffectNatural(fx.name, 'tone', v);
		tone.frequency.value = 600 * Math.pow(10, t);
	};
	fx.setters['level'] = function (v) {
		level.gain.value = studioEffectNatural(fx.name, 'level', v) * 1.2;
	};
	fx.set('drive', 50);
	fx.set('tone', 50);
	fx.set('level', 60);
	return fx;
}

// Wah: an LFO-swept resonant bandpass. The centre sits at 1400 Hz and `depth`
// is the sweep span, so full depth covers about 300..2500 Hz at Q 4; `mix`
// blends the swept signal with dry. A synced rate is resolved to Hz.
function studioEffectWah(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'wah');
	var filter = ctx.createBiquadFilter();
	filter.type = 'bandpass';
	filter.frequency.value = 1400;
	filter.Q.value = 4;
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	var lfo = ctx.createOscillator();
	var depthGain = ctx.createGain();
	lfo.type = 'sine';
	lfo.connect(depthGain).connect(filter.frequency);
	fx.input.connect(filter).connect(wet).connect(fx.wet);
	fx.input.connect(dry).connect(fx.wet);
	try { lfo.start(0); } catch (e) {}
	var depth = 0.7, mix = 1;
	var applyDepth = function () { depthGain.gain.value = studioEffectClamp(depth, 0, 1) * 1100; };
	var applyMix = function () { wet.gain.value = mix; dry.gain.value = 1 - mix; };
	var applyRate = function (hz) { lfo.frequency.value = studioEffectClamp(hz, 0.1, 20); };
	fx.setters['rate'] = function (v) { applyRate(studioEffectNatural(fx.name, 'rate', v)); };
	fx.setters['depth'] = function (v) { depth = studioEffectNatural(fx.name, 'depth', v); applyDepth(); };
	fx.setters['mix'] = function (v) { mix = studioEffectNatural(fx.name, 'mix', v); applyMix(); };
	fx.set('rate', 9.548);
	fx.set('depth', 70);
	fx.set('mix', 100);
	studioEffectTempo(fx, applyRate);
	fx.destroy = function () { try { lfo.stop(); } catch (e) {} };
	return fx;
}

// Modulator: a ring modulator. The gain is (1 - depth) + depth * sin, so
// depth 0 is unity and depth 1 swings through zero and inverts; `mix` blends
// the product with dry. A synced rate is resolved to Hz.
function studioEffectModulator(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'modulator');
	var ring = ctx.createGain();
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	var lfo = ctx.createOscillator();
	var depthGain = ctx.createGain();
	lfo.type = 'sine';
	lfo.connect(depthGain).connect(ring.gain);
	fx.input.connect(ring).connect(wet).connect(fx.wet);
	fx.input.connect(dry).connect(fx.wet);
	try { lfo.start(0); } catch (e) {}
	var depth = 0.7, mix = 0.5;
	var applyDepth = function () {
		var d = studioEffectClamp(depth, 0, 1);
		ring.gain.value = 1 - d;
		depthGain.gain.value = d;
	};
	var applyMix = function () { wet.gain.value = mix; dry.gain.value = 1 - mix; };
	var applyRate = function (hz) { lfo.frequency.value = studioEffectClamp(hz, 0.1, 20); };
	fx.setters['rate'] = function (v) { applyRate(studioEffectNatural(fx.name, 'rate', v)); };
	fx.setters['depth'] = function (v) { depth = studioEffectNatural(fx.name, 'depth', v); applyDepth(); };
	fx.setters['mix'] = function (v) { mix = studioEffectNatural(fx.name, 'mix', v); applyMix(); };
	fx.set('rate', 24.623);
	fx.set('depth', 70);
	fx.set('mix', 50);
	studioEffectTempo(fx, applyRate);
	fx.destroy = function () { try { lfo.stop(); } catch (e) {} };
	return fx;
}

// Chorus: one modulated short delay (5..30 ms) with a sine LFO. `depth`
// scales the 12.5 ms swing around the 17.5 ms centre and `mix` blends with
// dry; mono, one voice, as the contract says.
function studioEffectChorus(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'chorus');
	var delay = ctx.createDelay(0.05);
	delay.delayTime.value = 0.0175;
	var wet = ctx.createGain();
	var dry = ctx.createGain();
	var lfo = ctx.createOscillator();
	var depthGain = ctx.createGain();
	lfo.type = 'sine';
	lfo.connect(depthGain).connect(delay.delayTime);
	fx.input.connect(delay).connect(wet).connect(fx.wet);
	fx.input.connect(dry).connect(fx.wet);
	try { lfo.start(0); } catch (e) {}
	var depth = 0.5, mix = 0.5;
	var applyDepth = function () { depthGain.gain.value = studioEffectClamp(depth, 0, 1) * 0.0125; };
	var applyMix = function () { wet.gain.value = mix; dry.gain.value = 1 - mix; };
	var applyRate = function (hz) { lfo.frequency.value = studioEffectClamp(hz, 0.05, 5); };
	fx.setters['rate'] = function (v) { applyRate(studioEffectNatural(fx.name, 'rate', v)); };
	fx.setters['depth'] = function (v) { depth = studioEffectNatural(fx.name, 'depth', v); applyDepth(); };
	fx.setters['mix'] = function (v) { mix = studioEffectNatural(fx.name, 'mix', v); applyMix(); };
	fx.set('rate', 15.152);
	fx.set('depth', 50);
	fx.set('mix', 50);
	studioEffectTempo(fx, applyRate);
	fx.destroy = function () { try { lfo.stop(); } catch (e) {} };
	return fx;
}

// Vibrato: the same short delay with no dry path. `depth` scales the swing
// around a 7 ms centre (2..12 ms), which is the pitch vibrato; a synced rate
// is resolved to Hz.
function studioEffectVibrato(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'vibrato');
	var delay = ctx.createDelay(0.05);
	delay.delayTime.value = 0.007;
	var lfo = ctx.createOscillator();
	var depthGain = ctx.createGain();
	lfo.type = 'sine';
	lfo.connect(depthGain).connect(delay.delayTime);
	fx.input.connect(delay).connect(fx.wet);
	try { lfo.start(0); } catch (e) {}
	var depth = 0.4;
	var applyDepth = function () { depthGain.gain.value = studioEffectClamp(depth, 0, 1) * 0.005; };
	var applyRate = function (hz) { lfo.frequency.value = studioEffectClamp(hz, 0.1, 20); };
	fx.setters['rate'] = function (v) { applyRate(studioEffectNatural(fx.name, 'rate', v)); };
	fx.setters['depth'] = function (v) { depth = studioEffectNatural(fx.name, 'depth', v); applyDepth(); };
	fx.set('rate', 24.623);
	fx.set('depth', 40);
	studioEffectTempo(fx, applyRate);
	fx.destroy = function () { try { lfo.stop(); } catch (e) {} };
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

// ---- master graphic equalizer ----------------------------------------------
// The master rack's graphic EQ: ten peaking bands on the octave centres, Q 1.4,
// each knob -12..+12 dB. `master_eq` keeps the track equalizer's kind in the
// alias table, so the contract's natural-unit mapping (dB) applies to all ten
// band names and to the three old names; those are shortcuts onto 125 Hz,
// 1 kHz and 8 kHz so an old song lands on the right bands. The builder is
// registered under its exact name in studioEffectBuilders (not its alias kind), so studioInsert(ctx,
// 'master_eq') returns this one rather than the track's Baxandall equalizer.
var studioMasterEqBands = [
	{ control: 'b32',  hz: 32 },
	{ control: 'b64',  hz: 64 },
	{ control: 'b125', hz: 125 },
	{ control: 'b250', hz: 250 },
	{ control: 'b500', hz: 500 },
	{ control: 'b1k',  hz: 1000 },
	{ control: 'b2k',  hz: 2000 },
	{ control: 'b4k',  hz: 4000 },
	{ control: 'b8k',  hz: 8000 },
	{ control: 'b16k', hz: 16000 }
];

function studioMasterEqDb(value) {
	return -12 + studioEffectClamp(value, 0, 100) / 100 * 24;
}

function studioEffectMasterEq(ctx, name) {
	var fx = studioEffectShell(ctx, name || 'master_eq');
	var bands = {};
	var chain = [];
	studioMasterEqBands.forEach(function (band) {
		var filter = ctx.createBiquadFilter();
		filter.type = 'peaking';
		filter.frequency.value = Math.min(band.hz, ctx.sampleRate * 0.49);
		filter.Q.value = 1.4;
		bands[band.control] = filter;
		chain.push(filter);
	});
	var node = fx.input;
	chain.forEach(function (filter) { node.connect(filter); node = filter; });
	node.connect(fx.wet);
	var setBand = function (control, v) {
		bands[control].gain.value = studioMasterEqDb(v);
	};
	studioMasterEqBands.forEach(function (entry) {
		fx.setters[entry.control] = function (v) { setBand(entry.control, v); };
	});
	// The contract's three old names, each a shortcut onto a band.
	var legacy = { low: 'b125', mid: 'b1k', high: 'b8k' };
	Object.keys(legacy).forEach(function (control) {
		fx.setters[control] = function (v) { setBand(legacy[control], v); };
	});
	studioMasterEqBands.forEach(function (entry) { fx.set(entry.control, 50); });
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
	// Jtune is a listen-only tuner: it has no alias here and no builder below,
	// so studioInsert builds the pass-through and the engine plan (which asks
	// for a builder) leaves it out. It is still a real rack insert in the song.
	flanger: 'flanger',
	phaser: 'phaser',
	fuzz: 'fuzz',
	amp: 'amp',
	limiter: 'limiter',
	// The wire name autotune stays for the engine, the socket and old songs;
	// the UI labels it JawnPitch (the effects table in 05_abilities_and_studio.pl).
	autotune: 'autotune',
	equalizer: 'equalizer',
	tone: 'tone',
	// Browser only: the engine's inserts are mono and have no mid/side
	// matrix (engine/src/effect.rs), so only this side ever builds it.
	stereowidener: 'stereowidener',
	tremolo: 'tremolo',
	// Native as a pass-through: the browser's alias shares the name, and its
	// insert carries the pan LFO the channel applies after the chain.
	stereo_panner: 'stereo_panner',
	// The ten pedals in .shots/PEDAL-SPEC.md. Identity aliases: the wire name is
	// already the canonical kind, and each builder is registered under it below.
	harmonizer: 'harmonizer',
	de_esser: 'de_esser',
	modulator: 'modulator',
	pitch_shift: 'pitch_shift',
	gate: 'gate',
	slider: 'slider',
	overdrive: 'overdrive',
	wah: 'wah',
	chorus: 'chorus',
	vibrato: 'vibrato',
	JawnSynth: 'synth',
	master_comp: 'compressor',
	master_eq: 'equalizer',
	master_stereowidener: 'stereowidener',
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
	phaser: studioEffectPhaser,
	fuzz: studioEffectFuzz,
	amp: studioEffectAmp,
	limiter: studioEffectLimiter,
	maximizer: studioEffectMaximizer,
	autotune: studioEffectAutotune,
	equalizer: studioEffectEqualizer,
	tone: studioEffectTone,
	stereowidener: studioEffectStereoWidener,
	tremolo: studioEffectTremolo,
	stereo_panner: studioEffectStereoPanner,
	// The ten pedals in .shots/PEDAL-SPEC.md, under their exact wire names.
	harmonizer: studioEffectHarmonizer,
	de_esser: studioEffectDeEsser,
	modulator: studioEffectModulator,
	pitch_shift: studioEffectPitchShift,
	gate: studioEffectGate,
	slider: studioEffectSlider,
	overdrive: studioEffectOverdrive,
	wah: studioEffectWah,
	chorus: studioEffectChorus,
	vibrato: studioEffectVibrato,
	synth: studioEffectSynth,
	// The master rack's ten-band graphic EQ is its own builder, under its exact
	// wire name; the alias table still maps it to the track equalizer's kind for
	// the contract's natural units.
	master_eq: studioEffectMasterEq
};

// The canonical kind behind a name, so an insert added from the shelf
// ("reverb2") and one added from the palette ("reverb") are the same effect.
function studioEffectKind(name) {
	return studioEffectAliases[name] || String(name || '');
}

function studioEffectBuilder(name) {
	// An exact builder name wins over the alias kind (the master Eq has its own
	// builder but shares the equalizer kind for its natural units). `hasOwnProperty`
	// keeps Object.prototype names out of the lookup.
	if (Object.prototype.hasOwnProperty.call(studioEffectBuilders, name)) {
		return studioEffectBuilders[name];
	}
	var kind = studioEffectKind(name);
	if (Object.prototype.hasOwnProperty.call(studioEffectBuilders, kind)) {
		return studioEffectBuilders[kind];
	}
	return null;
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
