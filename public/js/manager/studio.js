/* [[js-split]]
   studio.js is part 1. The rest live in studio/ in name order:
     01_transport.js  - input detach, take node/mime, transport helpers, waveform, audio-clock scheduler
     02_canvas.js  - take sync, video preview, waveform canvas drawing
     03_editing.js  - record offset, loop regions, take editing, pointer/selection handlers
     04_knobs.js  - studioInit, knobs and wheel, song save/retrieve
     05_inputs.js  - jog wheel, record/arm/jack/cord, channel select, input grabber, take start/stop
     06_controls.js  - play/stop/time, loop punch-out, transport tick, save/load/import, name/mark/config
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var mixer = {};
var studio;

// Button artwork follows the selected icon set; the studio window publishes a
// server-resolved map (see studio/studio.html.ep), falling back to the PNG.
function jawnosStudioButtonIcon(state, colour) {
	var map = (window.jawnos_studio_button_icons || {})[state];
	if (map && map[colour]) { return map[colour]; }
	return '/images/studio/button_' + state + '_' + colour + '.png';
}

// ===========================================================================
// Audio engine
// ===========================================================================
// A single AudioContext drives the whole studio. Each channel owns one
// persistent graph that survives record/play cycles:
//
//   live input -> trim -> bass -> mid -> treble -> [inserts] -> recGain -> recDest
//                                                              -> recAnalyser
//   take -> playGain -> playBus -> playPan -> master -> speakers
//
// Audio takes are decoded to AudioBuffers and scheduled on the AudioContext's
// own clock (see the scheduler further down), so they sit exactly under the
// metronome. Only video and undecodable takes still ride a hidden media element.
//
// Takes are captured *after* the inserts, so pedals are printed into the
// recording (a guitar tracks through its pedals). Playback runs through the
// channel volume/pan only, so nothing is processed twice. The live input is
// never routed to the speakers, which keeps monitoring from feeding back.
//
// A take recorded on a channel armed to L is a looping sample: while the
// transport runs it wraps back to its in-point every time its own length
// elapses, until it is snipped on the waveform canvas. Recording locks to the
// Start on setting (bar, beat, or free wheeling), runs for the configured
// number of bars, then punches out and repeats on the spot, and it can be
// preceded by a count-in of the configured number of beats (the signature's
// beats per bar by default), which clicks even when the metronome is off.
//
// The live input can be monitored through the pedals into the speakers when the
// song asks for it (headphones only — an open mic plus speakers will howl).

var studioAudio = { ctx: null, master: null, masterAnalyser: null, channels: {}, sources: [], lookahead: 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
var studioSelectedChannel = 1;

function studioContext() {
	if (!studioAudio.ctx) {
		var Ctor = window.AudioContext || window.webkitAudioContext;
		if (!Ctor) { return null; }
		var hint = studioLatencyHint();
		var options = { latencyHint: hint };
		var rate = studioSampleRate();
		if (rate > 0) { options.sampleRate = rate; }
		var ctx;
		try { ctx = new Ctor(options); }
		catch (e) { ctx = new Ctor({ latencyHint: hint }); }
		studioAudio.ctx = ctx;
		studioAudio.master = ctx.createGain();
		studioAudio.masterAnalyser = ctx.createAnalyser();
		studioAudio.masterAnalyser.fftSize = 2048;
		studioAudio.master.connect(studioAudio.masterAnalyser);
		studioAudio.masterAnalyser.connect(ctx.destination);
		if (!studioAudio.sources) { studioAudio.sources = []; }
	}
	if (studioAudio.ctx.state == 'suspended') { studioAudio.ctx.resume(); }
	return studioAudio.ctx;
}

function studioKnobNumber(value, fallback) {
	var n = numeral(value).value();
	return (n === null || n === undefined || isNaN(n)) ? fallback : n;
}

// The channel fader is nominally 0..100, but the template ships value="1", so
// treat values at or below 1 as an already-normalised fraction.
function studioVolumeFraction(value) {
	var v = studioKnobNumber(value, 1);
	if (v > 1) { v = v / 100; }
	return Math.max(0, Math.min(1, v));
}

// Capture/encode preferences (video size, bit rates, sample rate, channels)
// live in the app settings rather than the song, so they apply to whatever is
// recorded next.
function studioSettingNumber(setting, fallback) {
	var raw = mixer['settings'] ? mixer['settings'][setting] : undefined;
	if (raw === undefined || raw === null || String(raw).length == 0) { return fallback; }
	var n = studioKnobNumber(raw, fallback);
	return (n === null || n === undefined || isNaN(n)) ? fallback : n;
}

// 0 means "whatever the device does".
function studioSampleRate() {
	var rate = studioSettingNumber('sample_rate', 0);
	return rate >= 8000 ? Math.round(rate) : 0;
}

// How small an audio buffer to ask the browser for. The named hints map straight
// through; a bare number is a target in seconds, and the browser may quietly give
// a larger one - too small a buffer crackles. Fixed when the AudioContext is
// built, so changing it rebuilds the studio window.
function studioLatencyHint() {
	var raw = mixer['settings'] ? mixer['settings']['latency_hint'] : undefined;
	if (raw === undefined || raw === null || String(raw).length == 0) { return 'interactive'; }
	var s = String(raw);
	if (s == 'interactive' || s == 'balanced' || s == 'playback') { return s; }
	var n = numeral(s).value();
	return (n > 0) ? n : 'interactive';
}

// The buffer hint and the sample rate are fixed when the AudioContext is built,
// so a change to either tears the window down and brings it back up.
function studioRebuildWindow(setting, value) {
	studioFlushSources();
	if (studioAudio.ctx) { try { studioAudio.ctx.close(); } catch (e) {} }
	studioAudio = { ctx: null, master: null, masterAnalyser: null, channels: {}, sources: [], lookahead: 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
	setTimeout(function () {
		studioInit({ settings: [{ setting: setting, value: value }] });
	}, 500);
}

// ---- effect factories ------------------------------------------------------

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

function studioImpulse(ctx, seconds, decay) {
	var rate = ctx.sampleRate;
	var length = Math.max(1, Math.floor(rate * seconds));
	var impulse = ctx.createBuffer(2, length, rate);
	for (var c = 0; c < 2; c++) {
		var data = impulse.getChannelData(c);
		for (var i = 0; i < length; i++) {
			data[i] = (Math.random() * 2 - 1) * Math.pow(1 - (i / length), decay);
		}
	}
	return impulse;
}

// Returns { name, input, output, set(control, rawValue) }. Raw values are the
// 0..100 knob slider values.
function studioInsert(ctx, name) {
	var input = ctx.createGain();
	var output = ctx.createGain();
	var setters = {};
	var api = { name: name, input: input, output: output, set: function (control, value) {
		if (setters[control]) { setters[control](studioKnobNumber(value, 50)); }
	} };

	if (name == 'CompressionX') {
		var comp = ctx.createDynamicsCompressor();
		var wet = ctx.createGain();
		var dry = ctx.createGain();
		input.connect(comp).connect(wet).connect(output);
		input.connect(dry).connect(output);
		setters['thresh'] = function (v) { comp.threshold.value = -v / 2; };
		setters['attack'] = function (v) { comp.attack.value = Math.max(0.001, v / 500); };
		setters['mix'] = function (v) { wet.gain.value = v / 100; dry.gain.value = 1 - (v / 100); };
	}
	else if (name == 'Distorjawn') {
		var shaper = ctx.createWaveShaper();
		var lp = ctx.createBiquadFilter();
		lp.type = 'lowpass';
		lp.frequency.value = 4500;
		input.connect(shaper).connect(lp).connect(output);
		setters['gain'] = function (v) { shaper.curve = studioDistortionCurve((v / 100) * 100); shaper.oversample = '4x'; };
	}
	else if (name == 'Delayed') {
		var delay = ctx.createDelay(2.0);
		var feedback = ctx.createGain();
		var dwet = ctx.createGain();
		var ddry = ctx.createGain();
		input.connect(ddry).connect(output);
		input.connect(delay).connect(dwet).connect(output);
		delay.connect(feedback).connect(delay);
		ddry.gain.value = 0.7;
		setters['time'] = function (v) { delay.delayTime.value = (v / 100) * 1.5; };
		setters['feedback'] = function (v) { feedback.gain.value = (v / 100) * 0.9; };
		setters['vol'] = function (v) { dwet.gain.value = v / 100; };
		setters['time'](35); setters['feedback'](30); setters['vol'](40);
	}
	else if (name == 'reverb2') {
		var convolver = ctx.createConvolver();
		convolver.buffer = studioImpulse(ctx, 2.4, 2.6);
		var rwet = ctx.createGain();
		var rdry = ctx.createGain();
		input.connect(rdry).connect(output);
		input.connect(convolver).connect(rwet).connect(output);
		rdry.gain.value = 0.8;
		setters['mix'] = function (v) { rwet.gain.value = (v / 100) * 0.9; rdry.gain.value = 1 - (v / 100) * 0.4; };
		setters['volume'] = function (v) { rwet.gain.value = (v / 100) * 0.9; };
		setters['mix'](35);
	}
	else if (name == 'JawnSynth' && window.jawnosSynth && typeof window.jawnosSynth.outputNode === 'function') {
		// A generator pedal: the synth's output replaces the chain from here, so a
		// channel carrying this pedal records whatever the synth plays. Its knobs are
		// the synth's controls - each 0..100 slider mapped to a patch parameter.
		var synth = window.jawnosSynth;
		if (synth.context() !== ctx) { synth.attach(ctx, ctx.destination); }
		var src = synth.outputNode();
		if (src) {
			src.connect(output);
			api.destroy = function () { try { src.disconnect(output); } catch (e) {} };
		}
		var synthMap = {
			cutoff: 'filter.cutoff', reso: 'filter.q', attack: 'amp.a',
			release: 'amp.r', detune: 'osc2.detune', lfo: 'lfo.rate', level: 'drive'
		};
		Object.keys(synthMap).forEach(function (control) {
			setters[control] = function (v) { synth.set(synthMap[control], synth.knob(synthMap[control], v)); };
		});
	}
	else {
		input.connect(output);
	}

	return api;
}

function studioChannelEngine(ch) {
	var ctx = studioContext();
	if (!ctx) { return null; }
	if (studioAudio.channels[ch]) { return studioAudio.channels[ch]; }
	var c = {
		trim: ctx.createGain(),
		bass: ctx.createBiquadFilter(),
		mid: ctx.createBiquadFilter(),
		treble: ctx.createBiquadFilter(),
		recGain: ctx.createGain(),
		recAnalyser: ctx.createAnalyser(),
		recDest: ctx.createMediaStreamDestination(),
		playBus: ctx.createGain(),
		playPan: ctx.createStereoPanner(),
		monGain: ctx.createGain(),
		inserts: [],
		insertByName: {},
		source: null
	};
	c.bass.type = 'lowshelf'; c.bass.frequency.value = 220;
	c.mid.type = 'peaking'; c.mid.frequency.value = 1000; c.mid.Q.value = 1;
	c.treble.type = 'highshelf'; c.treble.frequency.value = 3500;
	c.recAnalyser.fftSize = 2048;
	c.recData = new Float32Array(c.recAnalyser.fftSize);
	// the recorded stream follows the configured channel count
	try { c.recDest.channelCount = studioSettingNumber('audio_channels', 2) || 2; } catch (e) {}
	c.trim.connect(c.bass).connect(c.mid).connect(c.treble);
	c.recGain.connect(c.recAnalyser);
	c.recGain.connect(c.recDest);
	// takes play through the channel fader + pan into the master bus
	c.playBus.connect(c.playPan).connect(studioAudio.master);
	// live monitoring taps the same post-pedal signal the recorder gets, so you
	// hear exactly what is being captured; it is muted until the song asks
	c.monGain.gain.value = 0;
	c.recGain.connect(c.monGain);
	c.monGain.connect(studioAudio.master);
	studioAudio.channels[ch] = c;
	return c;
}

function studioRebuildInserts(ch) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	try { c.trim.disconnect(); } catch (e) {}
	try { c.treble.disconnect(); } catch (e) {}
	c.trim.connect(c.bass);
	var node = c.treble;
	c.inserts.forEach(function (insert) {
		node.connect(insert.input);
		node = insert.output;
	});
	node.connect(c.recGain);
}

function studioApplyPedals() {
	$('.knob_control').each(function (i, v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		if (/^[0-9]+$/.test(channel)) { return; }
		$.each(studioAudio.channels, function (ch, c) {
			if (c.insertByName[channel]) { c.insertByName[channel].set(control, $(v).val()); }
		});
	});
}

function studioSetInsert(ch, name, on) {
	var c = studioChannelEngine(ch);
	if (!c) { return; }
	var at = -1;
	c.inserts.forEach(function (ins, i) { if (ins.name == name) { at = i; } });
	if (on && at == -1) {
		var ins = studioInsert(studioContext(), name);
		c.inserts.push(ins);
		c.insertByName[name] = ins;
	}
	else if (!on && at != -1) {
		var gone = c.inserts.splice(at, 1)[0];
		if (gone && gone.destroy) { try { gone.destroy(); } catch (e) {} }
		delete c.insertByName[name];
	}
	studioApplyPedals();
	studioRebuildInserts(ch);
	studioUpdateFxBadges();
}

function studioApplyChannel(ch) {
	var c = studioChannelEngine(ch);
	if (!c) { return; }
	var raw = function (control, fallback) {
		return studioKnobNumber($('.knob_control[channel="' + ch + '"][control="' + control + '"]').val(), fallback);
	};
	c.trim.gain.value = raw('gain', 50) / 50;
	c.bass.gain.value = (raw('bass', 50) - 50) / 50 * 12;
	c.mid.gain.value = (raw('mid', 50) - 50) / 50 * 12;
	c.treble.gain.value = (raw('treble', 50) - 50) / 50 * 12;
}

// Feed a live MediaStream (mic / camera / screen) into a channel and return its
// processed recording stream.
function studioAttachInput(ch, stream) {
	var ctx = studioContext();
	var c = studioChannelEngine(ch);
	if (!ctx || !c) { return null; }
	if (c.source) { try { c.source.disconnect(); } catch (e) {} c.source = null; }
	c.source = ctx.createMediaStreamSource(stream);
	c.source.connect(c.trim);
	studioApplyChannel(ch);
	studioRebuildInserts(ch);
	return c.recDest.stream;
}

// Feed the JawnOS synth engine into a channel the way a live input is fed, so it
// records through the channel's tone stack and pedals and can be monitored. The
// engine rides the studio's own context and stays audible on its own, so it can
// be played before anything is armed; the tap is a per-channel gain, so stopping
// it never silences the synth's own output.
function studioAttachSynth(ch) {
	var ctx = studioContext();
	var c = studioChannelEngine(ch);
	if (!ctx || !c || !window.jawnosSynth || typeof jawnosSynth.outputNode !== 'function') { return null; }
	if (jawnosSynth.context() !== ctx) { jawnosSynth.attach(ctx, ctx.destination); }
	var node = jawnosSynth.outputNode();
	if (!node) { return null; }
	if (c.source) { try { c.source.disconnect(); } catch (e) {} c.source = null; }
	if (c.synthTap) {
		try { c.synthTap.node.disconnect(c.synthTap.gain); } catch (e) {}
		try { c.synthTap.gain.disconnect(); } catch (e) {}
	}
	var tap = ctx.createGain();
	tap.gain.value = 1;
	node.connect(tap);
	tap.connect(c.trim);
	c.synthTap = { node: node, gain: tap };
	studioApplyChannel(ch);
	studioRebuildInserts(ch);
	return c.recDest.stream;
}

// Push a capture-quality change (channel count) onto the live channels.
function studioApplyCapture() {
	var chans = studioSettingNumber('audio_channels', 2) || 2;
	$.each(studioAudio.channels, function (ch, c) {
		if (!c.recDest) { return; }
		try { c.recDest.channelCount = chans; } catch (e) {}
	});
}

// Live monitoring: the processed input only reaches the speakers when the song
// asks for it, because an open mic plus speakers howls.
function studioApplyMonitor() {
	var on = mixer['time'] && mixer['time']['monitor'] == 'yes';
	$.each(studioAudio.channels, function (ch, c) {
		if (c.monGain) { c.monGain.gain.value = on ? 1 : 0; }
	});
}

// Persist an app-wide preference (capture quality) without rebuilding the
// window: the studio endpoint stores settings and hands back markup we ignore.
function studioSaveSettings(settings) {
	$.ajax({
		url: '/manager/studio',
		type: 'GET',
		data: { timestamp: Date.now(), data: JSON.stringify({ settings: settings }) }
	});
}

// What the browser reports about the round trip, so the record offset can be
// sanity-checked instead of guessed at.
function studioUpdateLatencyInfo() {
	var el = $('#studio_latency_info');
	if (!el.length) { return; }
	var ctx = studioAudio.ctx;
	if (!ctx) { el.text('engine idle'); return; }
	var ch = studioSelectedChannel;
	var m = mixer[ch] && mixer[ch].media;
	var parts = ['output ' + Math.round(((ctx.baseLatency || 0) + (ctx.outputLatency || 0)) * 1000) + ' ms'];
	if (m && m.latency > 0) { parts.push('input ' + Math.round(m.latency * 1000) + ' ms'); }
	parts.push('offset ' + Math.round(studioRecordOffset(ch) * 1000) + ' ms');
	parts.push('hint ' + studioLatencyHint());
	el.text(parts.join(' · '));
}

// ---- round-trip latency meter ----------------------------------------------
// Plays a few clicks out of the speakers and times the echo on the microphone
// on the AudioContext clock. What it reports is the monitoring round trip -
// output + air + input - which is the number that decides whether playing along
// through the app feels late. Speakers, not headphones, and a quiet room.

var studioLatencyProbeSource = [
	"class StudioLatencyProbe extends AudioWorkletProcessor {",
	"  constructor() {",
	"    super();",
	"    this.phase = 'idle'; this.after = 0; this.threshold = 0.05; this.fired = false;",
	"    this.port.onmessage = (e) => {",
	"      const d = e.data || {};",
	"      if (d.phase === 'ambient' || d.phase === 'idle') { this.phase = d.phase; }",
	"      else if (d.phase === 'arm') { this.phase = 'arm'; this.after = d.after || 0; this.threshold = d.threshold || 0.05; this.fired = false; }",
	"    };",
	"  }",
	"  process(inputs) {",
	"    const ch = inputs[0] && inputs[0][0];",
	"    if (ch) {",
	"      let peak = 0, at = 0;",
	"      for (let i = 0; i < ch.length; i++) { const v = ch[i] < 0 ? -ch[i] : ch[i]; if (v > peak) { peak = v; at = i; } }",
	"      if (this.phase === 'ambient') { this.port.postMessage({ level: peak, ambient: 1 }); }",
	"      else if (this.phase === 'arm' && !this.fired && peak > this.threshold && currentTime >= this.after) {",
	"        this.fired = true;",
	"        this.port.postMessage({ hit: currentTime + at / sampleRate });",
	"      }",
	"    }",
	"    return true;",
	"  }",
	"}",
	"registerProcessor('studio-latency-probe', StudioLatencyProbe);"
].join('\n');

var studioLatencyProbeLoaded = false;

function studioSleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

// A short broadband click (a decaying noise burst) with a sharp onset.
function studioLatencyClick(ctx) {
	var rate = ctx.sampleRate;
	var len = Math.max(1, Math.floor(rate * 0.004));
	var buf = ctx.createBuffer(1, len, rate);
	var d = buf.getChannelData(0);
	for (var i = 0; i < len; i++) { d[i] = (Math.random() * 2 - 1) * Math.pow(1 - (i / len), 2); }
	return buf;
}

async function studioLatencyMeter() {
	var out = $('#studio_latency_result');
	var ctx = studioContext();
	if (!ctx) { return; }
	if (!ctx.audioWorklet) { out.text('this browser cannot measure'); return; }
	out.text('measuring\u2026');

	var stream;
	try {
		stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
	} catch (e) {
		out.text('microphone refused');
		return;
	}

	try {
		if (!studioLatencyProbeLoaded) {
			var url = URL.createObjectURL(new Blob([studioLatencyProbeSource], { type: 'application/javascript' }));
			await ctx.audioWorklet.addModule(url);
			URL.revokeObjectURL(url);
			studioLatencyProbeLoaded = true;
		}
	} catch (e) {
		out.text('probe failed to load');
		stream.getTracks().forEach(function (t) { t.stop(); });
		return;
	}

	var source = ctx.createMediaStreamSource(stream);
	var node = new AudioWorkletNode(ctx, 'studio-latency-probe');
	var sink = ctx.createGain();
	sink.gain.value = 0;
	source.connect(node);
	node.connect(sink).connect(ctx.destination);

	var ambient = 0;
	var hits = [];
	node.port.onmessage = function (e) {
		var d = e.data || {};
		if (d.ambient && d.level > ambient) { ambient = d.level; }
		if (d.hit !== undefined) { hits.push(d.hit); }
	};

	// learn the room noise, so the echo threshold sits above it
	node.port.postMessage({ phase: 'ambient' });
	await studioSleep(500);
	node.port.postMessage({ phase: 'idle' });

	var threshold = Math.max(0.05, ambient * 4);
	var click = studioLatencyClick(ctx);
	var delays = [];

	for (var n = 0; n < 3; n++) {
		var when = ctx.currentTime + 0.25;
		node.port.postMessage({ phase: 'arm', after: when, threshold: threshold });
		var src = ctx.createBufferSource();
		src.buffer = click;
		var gain = ctx.createGain();
		gain.gain.value = 0.6;
		src.connect(gain).connect(ctx.destination);
		src.start(when);
		var seen = hits.length;
		await studioSleep(500);
		if (hits.length > seen) { delays.push(hits[hits.length - 1] - when); }
	}

	source.disconnect();
	node.disconnect();
	sink.disconnect();
	stream.getTracks().forEach(function (t) { t.stop(); });

	if (!delays.length) {
		out.text('no echo heard \u2014 use speakers, not headphones, and stay quiet');
		return;
	}
	delays.sort(function (a, b) { return a - b; });
	out.text(Math.round(delays[Math.floor(delays.length / 2)] * 1000) + ' ms (' + delays.length + '/3 echoes)');
}

