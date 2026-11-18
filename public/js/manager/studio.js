/* [[js-split]]
   studio.js is part 1. The rest live in studio/ in name order:
     01_transport.js  - input detach, take node/mime, transport helpers, waveform, audio-clock scheduler
     02_canvas.js  - take sync, video preview, waveform canvas drawing
     03_editing.js  - record offset, loop regions, take editing, pointer/selection handlers
     04_knobs.js  - studioInit, knobs and wheel, song save/retrieve
     05_inputs.js  - jog wheel, record/arm/jack/cord, channel select, input grabber, take start/stop
     06_controls.js  - play/stop/time, loop punch-out, transport tick, save/load/import, name/mark/config
     07_layout.js  - per-track panels, hide toggles, floating panels, add/delete tracks, automation
     08_effects.js  - the insert builders (the browser side of docs/studio-effects.md)
     09_pedals.js  - the per-track rack: palette, order, footswitch, remove
     10_master.js  - the mastering chain after the mix, its UI and its song state
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

var studioAudio = { ctx: null, master: null, masterAnalyser: null, masterChain: null, channels: {}, sources: [], lookahead: 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
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
		// The mastering rack sits on the mixer's bus: after every channel sum,
		// before the analyser that feeds the destination. It is a fixed chain
		// with its own footswitches, so a bypass never rewires the window.
		var rack = null;
		try { rack = studioMasterChain(ctx); } catch (e) { rack = null; }
		studioAudio.masterChain = rack;
		if (rack) {
			studioAudio.master.connect(rack.input);
			rack.output.connect(studioAudio.masterAnalyser);
		}
		else {
			studioAudio.master.connect(studioAudio.masterAnalyser);
		}
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
	studioAudio = { ctx: null, master: null, masterAnalyser: null, masterChain: null, channels: {}, sources: [], lookahead: 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
	setTimeout(function () {
		studioInit({ settings: [{ setting: setting, value: value }] });
	}, 500);
}

// ---- effect factories ------------------------------------------------------
// The builders live in studio/08_effects.js; this is the dispatcher the rest of
// the window calls. Every contract name resolves to a builder there, and an
// unknown name is a plain pass-through so a stale song still loads.
function studioInsert(ctx, name) {
	var build = studioEffectBuilder(name);
	if (build) { return build(ctx, name); }
	var input = ctx.createGain();
	var output = ctx.createGain();
	input.connect(output);
	return {
		name: name, input: input, output: output, bypassed: false, values: {},
		set: function (control, value) { this.values[control] = value; },
		setBypass: function (on) { this.bypassed = !!on; }
	};
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
	// The shelf's pedals are global: a knob on the artwork pushes its value to
	// every insert of that kind, however it was named when it was added (the
	// shelf says reverb2, the palette says reverb).
	$('.knob_control, .studio_pedal_model').each(function (i, v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		if (!channel || !control || /^[0-9]+$/.test(channel)) { return; }
		var kind = studioEffectKind(channel);
		$.each(studioAudio.channels, function (ch, c) {
			$.each(c.insertByName, function (name, ins) {
				if (studioEffectKind(name) === kind) { ins.set(control, $(v).val()); }
			});
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
	// keep every rack view of this channel in step with the engine
	if (typeof studioRackRender === 'function') { studioRackRender(ch); }
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
	var base = ctx.baseLatency || 0;
	var out = ctx.outputLatency || 0;
	var parts = ['output ' + Math.round((base + out) * 1000) + ' ms (' + studioAudioLabel('base') + ' ' + Math.round(base * 1000) + ' · ' + studioAudioLabel('out') + ' ' + Math.round(out * 1000) + ')'];
	if (ctx.sampleRate) { parts.push(studioAudioLabel('rate') + ' ' + ctx.sampleRate + ' Hz'); }
	if (m && m.latency > 0) { parts.push('input ' + Math.round(m.latency * 1000) + ' ms'); }
	parts.push('offset ' + Math.round(studioRecordOffset(ch) * 1000) + ' ms');
	parts.push('hint ' + studioLatencyHint());
	el.text(parts.join(' · '));
}

// A translated word for the latency readout; translate.js may not be loaded in
// every shell, so fall back to the English text.
function studioAudioLabel(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// One plain object describing what the browser actually gave this studio, so
// the WebAudio path can be measured before a native engine replaces it. Read
// only: it never builds a context or changes the graph.
function studioAudioReport() {
	var ctx = studioAudio.ctx || null;
	var probe = studioAudio.probe || null;
	var delay = (studioAudio.recorderStartDelayMs === undefined) ? null : studioAudio.recorderStartDelayMs;
	return {
		userAgent: (typeof navigator !== 'undefined') ? navigator.userAgent : null,
		state: ctx ? ctx.state : null,
		sampleRate: ctx ? ctx.sampleRate : null,
		sampleRateAsked: studioSampleRate(),
		latencyHintAsked: studioLatencyHint(),
		baseLatency: (ctx && typeof ctx.baseLatency === 'number') ? ctx.baseLatency : null,
		outputLatency: (ctx && typeof ctx.outputLatency === 'number') ? ctx.outputLatency : null,
		roundTrip: probe ? {
			seconds: probe.seconds,
			ms: probe.ms,
			measured: 'output + air + input',
			echoes: probe.echoes,
			of: probe.of,
			at: probe.at
		} : null,
		recorderStartDelayMs: delay,
		capturedAt: new Date().toISOString()
	};
}
window.studioAudioReport = studioAudioReport;

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
	var median = delays[Math.floor(delays.length / 2)];
	studioAudio.probe = {
		seconds: median,
		ms: Math.round(median * 1000),
		echoes: delays.length,
		of: 3,
		at: new Date().toISOString()
	};
	out.text(Math.round(median * 1000) + ' ms (' + delays.length + '/3 echoes)');
	console.log(JSON.stringify(studioAudioReport()));
}


// ---- the backend picker ----------------------------------------------------
// Four names, matching the select beside the meter and the route's own list.
// `javascript` stays in the page, so its number is the browser probe; the native
// names are measured by the engine behind POST /manager/studio/latency.
var studioLatencyBackends = [ 'javascript', 'alsa', 'pipewire', 'jack' ];

function studioLatencyMeasure() {
	var out = $('#studio_latency_result');
	if (!out.length) { return; }
	var backend = $('#studio_latency_backend').val() || 'javascript';
	if (studioLatencyBackends.indexOf(backend) < 0) { backend = 'javascript'; }
	if (backend === 'javascript') { return studioLatencyMeter(); }

	out.text(studioAudioLabel('measuring') + '\u2026');
	$.ajax({
		url: '/manager/studio/latency',
		type: 'POST',
		data: { backend: backend },
		dataType: 'json',
		success: function (data) {
			if (data && data.ok === true && typeof data.ms === 'number') {
				out.text(backend + ' ' + data.ms + ' ms' + (data.device ? ' (' + data.device + ')' : ''));
				return;
			}
			out.text(backend + ': ' + ((data && data.error) ? data.error : studioAudioLabel('the audio engine did not answer')));
		},
		error: function (xhr) {
			var data = xhr && xhr.responseJSON;
			out.text(backend + ': ' + ((data && data.error) ? data.error : studioAudioLabel('the audio engine did not answer')));
		}
	});
}

// ---- the engine take panel -------------------------------------------------
// The panel beside the latency readout speaks to the native engine through
// POST /manager/studio/take; the WebAudio graph above is not involved. A take
// is armed with a length and a track plan, read back with `status` every 750 ms
// while it records, and each strip's gain/pan slider sends one `param`.
// A number the engine did not report is shown as an em dash, never guessed.

var studioEngineTimer = 0;

function studioEngineAnswer(data) {
	if (!data || typeof data !== 'object') {
		return { ok: false, error: studioAudioLabel('the audio engine did not answer') };
	}
	return data;
}

function studioEngineShowError(text) {
	var el = $('#studio_engine_error');
	if (el.length) { el.text(text || ''); }
}

function studioEngineFailed(xhr) {
	var data = xhr && xhr.responseJSON;
	studioEnginePollStop();
	studioEngineShowError((data && data.error) ? data.error : studioAudioLabel('the audio engine did not answer'));
}

function studioEnginePollStart() {
	if (studioEngineTimer) { return; }
	studioEngineTimer = setInterval(studioEngineStatus, 750);
}

function studioEnginePollStop() {
	if (studioEngineTimer) { clearInterval(studioEngineTimer); studioEngineTimer = 0; }
}

// The engine puts one track's fields at the top level and adds a `tracks` array
// only when a take has more than one, so a one-track take still gets a row.
function studioEngineStrips(data) {
	if (Array.isArray(data.tracks) && data.tracks.length) { return data.tracks; }
	if (typeof data.frames === 'number' || typeof data.dropped === 'number') { return [ data ]; }
	return [];
}

function studioEngineNumber(value) {
	return (typeof value === 'number' && isFinite(value)) ? String(value) : '\u2014';
}

function studioEngineRow(index) {
	var row = $('<div class="studio_engine_strip"></div>').attr('data-track', index).css({ margin: '2px 0' });
	var slider = { width: '80px', 'vertical-align': 'middle' };
	row.append($('<span class="studio_engine_state"></span>').css({ 'margin-right': '8px' }));
	row.append($('<span class="studio_engine_frames"></span>').css({ 'margin-right': '8px' }));
	row.append($('<span class="studio_engine_dropped"></span>').css({ 'margin-right': '8px' }));
	row.append($('<label></label>').append($('<span></span>').text(studioAudioLabel('Gain') + ' ')).append(
		$('<input type="range" class="studio_engine_gain" min="0" max="4" step="0.01">')
			.attr('data-track', index).css(slider)
	));
	row.append($('<label></label>').css({ 'margin-left': '8px' }).append($('<span></span>').text(studioAudioLabel('Pan') + ' ')).append(
		$('<input type="range" class="studio_engine_pan" min="-1" max="1" step="0.01">')
			.attr('data-track', index).css(slider)
	));
	return row;
}

function studioEngineRender(data) {
	var box = $('#studio_engine_strips');
	if (!box.length) { return; }
	var strips = studioEngineStrips(data);
	var state = (typeof data.state === 'string') ? data.state : '';

	box.children('.studio_engine_strip').slice(strips.length).remove();

	for (var i = 0; i < strips.length; i++) {
		var track = strips[i] || {};
		var row = box.children('.studio_engine_strip').eq(i);
		if (!row.length) { row = studioEngineRow(i); box.append(row); }
		row.attr('data-track', i);
		row.find('.studio_engine_state').text(state || '\u2014');
		row.find('.studio_engine_frames').text(studioAudioLabel('frames') + ' ' + studioEngineNumber(track.frames));
		row.find('.studio_engine_dropped').text(studioAudioLabel('dropped') + ' ' + studioEngineNumber(track.dropped));
		var gain = row.find('.studio_engine_gain').show();
		var pan = row.find('.studio_engine_pan').show();
		// A slider being dragged keeps its own position until it is let go.
		if (!gain.is(':focus') && typeof track.gain === 'number') { gain.val(track.gain); }
		if (!pan.is(':focus') && typeof track.pan === 'number') { pan.val(track.pan); }
	}

	if (!strips.length) {
		// Idle, or a take that has not reported a track yet: the state alone.
		var only = box.children('.studio_engine_strip').eq(0);
		if (!only.length) { only = studioEngineRow(0); box.append(only); }
		only.find('.studio_engine_state').text(state || '\u2014');
		only.find('.studio_engine_frames').text('');
		only.find('.studio_engine_dropped').text('');
		only.find('.studio_engine_gain, .studio_engine_pan').hide();
	}
}

function studioEngineStatus() {
	if (!$('#studio_engine_panel').length) { studioEnginePollStop(); return; }
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'status' },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioEnginePollStop();
				// The frames we last drew belong to a take we can no longer read.
				jQuery('#studio_engine_strips').empty();
				studioEngineShowError(data.error || studioAudioLabel('the audio engine did not answer'));
				return;
			}
			if (typeof data.error === 'string' && data.error.length) { studioEngineShowError(data.error); }
			studioEngineRender(data);
			if (data.state === 'recording') { studioEnginePollStart(); }
			else { studioEnginePollStop(); }
		},
		error: studioEngineFailed
	});
}

function studioEngineStart() {
	studioEngineShowError('');
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: {
			action: 'start',
			seconds: $('#studio_engine_seconds').val(),
			tracks: $('#studio_engine_tracks').val(),
			inputs: $('#studio_engine_inputs').val(),
			inserts: $('#studio_engine_inserts').val()
		},
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioEnginePollStop();
				studioEngineShowError(data.error || studioAudioLabel('the audio engine did not answer'));
				return;
			}
			studioEngineRender(data);
			studioEnginePollStart();
			studioEngineStatus();
		},
		error: studioEngineFailed
	});
}

function studioEngineStop() {
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'stop' },
		dataType: 'json',
		success: function (data) {
			studioEnginePollStop();
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioEngineShowError(data.error || studioAudioLabel('the audio engine did not answer'));
				return;
			}
			if (typeof data.error === 'string' && data.error.length) { studioEngineShowError(data.error); }
			studioEngineRender(data);
		},
		error: studioEngineFailed
	});
}

function studioEngineParam(track, name, value) {
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'param', track: track, name: name, value: value },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioEngineShowError(data.error || studioAudioLabel('the audio engine did not answer'));
			}
		},
		error: studioEngineFailed
	});
}
