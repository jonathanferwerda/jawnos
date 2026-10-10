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
		var options = { latencyHint: 'interactive' };
		var rate = studioSampleRate();
		if (rate > 0) { options.sampleRate = rate; }
		var ctx;
		try { ctx = new Ctor(options); }
		catch (e) { ctx = new Ctor({ latencyHint: 'interactive' }); }
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
		c.inserts.splice(at, 1);
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

$(document).on('click', '#studio_latency_measure', function () { studioLatencyMeter(); });

function studioDetachInput(ch) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	if (c.source) { try { c.source.disconnect(); } catch (e) {} c.source = null; }
}

// Route a take's media element through the channel's playback bus. A media
// element can only be captured once, so the node is cached on the take.
function studioTakeNode(ch, take) {
	var ctx = studioContext();
	var c = studioChannelEngine(ch);
	if (!ctx || !c || !take || !take.track) { return null; }
	if (!take.node) {
		try {
			take.node = ctx.createMediaElementSource(take.track);
			take.playGain = ctx.createGain();
			take.node.connect(take.playGain).connect(c.playBus);
		} catch (e) {
			console.log('studio: could not route take', e);
			return null;
		}
	}
	return take.node;
}

function studioPickMime(hasVideo) {
	if (!window.MediaRecorder) { return ''; }
	var options = hasVideo
		? ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm']
		: ['audio/webm;codecs=opus', 'audio/webm'];
	for (var i = 0; i < options.length; i++) {
		if (MediaRecorder.isTypeSupported(options[i])) { return options[i]; }
	}
	return '';
}

// ---- transport helpers -----------------------------------------------------

// Crossfade length in seconds (configurable; 50ms declick by default).
function studioCrossfade() {
	var raw = mixer['time']['crossfade'];
	var v = (raw !== undefined && raw !== null && String(raw).length > 0) ? numeral(raw).value() : NaN;
	if (v === null || v === undefined || isNaN(v)) { v = 0.05; }
	return Math.max(0, v);
}

function studioChannelTakes(ch, includeRecording) {
	var media = mixer[ch] && mixer[ch].media;
	return ((media && media.out) || [])
		.filter(function (t) { return t && (includeRecording || t.status != 'recording'); })
		.slice()
		.sort(function (a, b) { return a.startTime - b.startTime; });
}

// Waveform peaks per source URL, shared by both halves of a split.
var studioWaveformCache = {};
var studioWaveformLoading = {};

function studioEnsureWaveform(ch, take) {
	if (!take || !take.src || take.waveform) { return; }
	if (studioWaveformCache[take.src] === 'failed') { return; }
	if (studioWaveformCache[take.src]) { take.waveform = studioWaveformCache[take.src]; return; }
	if (studioWaveformLoading[take.src]) { return; }
	var ctx = studioContext();
	if (!ctx) { return; }
	studioWaveformLoading[take.src] = true;
	fetch(take.src).then(function (r) { return r.arrayBuffer(); }).then(function (buf) {
		return ctx.decodeAudioData(buf);
	}).then(function (audio) {
		var buckets = 600;
		var data = audio.getChannelData(0);
		var peaks = new Float32Array(buckets);
		var step = Math.max(1, Math.floor(data.length / buckets));
		for (var b = 0; b < buckets; b++) {
			var m = 0;
			for (var i = b * step; i < (b + 1) * step && i < data.length; i++) {
				var v = Math.abs(data[i]);
				if (v > m) { m = v; }
			}
			peaks[b] = m;
		}
		studioWaveformCache[take.src] = peaks;
		delete studioWaveformLoading[take.src];
		take.waveform = peaks;
		studioDrawChannel(ch);
	}).catch(function (e) {
		studioWaveformCache[take.src] = 'failed';
		delete studioWaveformLoading[take.src];
	});
}

// Only browsers that expose loop points can repeat a trimmed span; without
// them el.loop would repeat the whole media file rather than the take.
function studioSetTakeLoop(el, start, end) {
	if (!('loopStart' in el) || !('loopEnd' in el)) { return; }
	if (end > start) {
		if (el.loopStart != start) { try { el.loopStart = start; } catch (e) {} }
		if (el.loopEnd != end) { try { el.loopEnd = end; } catch (e) {} }
		if (!el.loop) { el.loop = true; }
	}
	else if (el.loop) { el.loop = false; }
}

// Elements start rolling a little after play() is called, so a take can sit a
// fixed distance behind the transport. Small errors are trimmed back with a
// tiny playback-rate bend (no click, no gap); only a clearly adrift take is
// hard-seeked, and not again until the previous seek has had time to land.
function studioSyncTakeClock(take, el, target, period) {
	var delta = el.currentTime - target;
	if (period > 0) {
		// compare on the loop cycle, so a wrap never reads as an error
		delta = ((delta % period) + period) % period;
		if (delta > period / 2) { delta -= period; }
	}
	var mag = Math.abs(delta);
	var now = Date.now();
	if (mag > 0.25 || (mag > 0.08 && (!take.seekedAt || (now - take.seekedAt) > 400))) {
		take.seekedAt = now;
		el.playbackRate = 1;
		try { el.currentTime = target; } catch (e) {}
		return;
	}
	if (mag > 0.02) {
		el.playbackRate = Math.max(0.95, Math.min(1.05, 1 - (delta * 0.5)));
	}
	else if (el.playbackRate != 1) {
		el.playbackRate = 1;
	}
}

// ---- audio-clock transport + lookahead scheduler ---------------------------
//
// The transport runs on the AudioContext's own clock. Takes are decoded to
// AudioBuffers once and scheduled ahead with AudioBufferSourceNodes, so the
// metronome click and every take are placed on the very same sample clock.
// Playing takes through an HTMLMediaElement instead leaves them sitting a fixed
// buffer behind the click (the element's own pipeline latency, chased by a 25 ms
// timer), which is exactly what made the backing track sound late.
//
// The transport is a chain of pieces. Each piece maps a span of transport time
// [pos0, pos1) onto a span of AudioContext time beginning at ctx0 and names the
// position the next piece starts at (nextPos). A loop is simply a piece whose
// nextPos is its own start, so AudioContext time stays continuous across a wrap
// while the transport position jumps.

function studioSegmentFrom(pos, ctx0) {
	var end = mixer['time']['duration'] || 0;
	var mode = mixer['time']['loop'] || 'off';
	// while recording the transport never wraps; it runs on to the punch-out
	if (mixer['time']['status'] == 'record') {
		return { pos0: pos, pos1: Infinity, ctx0: ctx0, nextPos: null };
	}
	if (mode == 'ongoing') {
		var region = studioLoopRegion();
		if (region && region.end > region.start && pos < region.end) {
			return { pos0: pos, pos1: region.end, ctx0: ctx0, nextPos: region.start };
		}
		if (end > pos) {
			return { pos0: pos, pos1: end, ctx0: ctx0, nextPos: 0 };
		}
	}
	else if (mode == 'on' && end > pos) {
		return { pos0: pos, pos1: end, ctx0: ctx0, nextPos: null };
	}
	return { pos0: pos, pos1: Infinity, ctx0: ctx0, nextPos: null };
}

function studioSegmentNext(seg) {
	if (!seg || seg.nextPos === null || seg.pos1 === Infinity) { return null; }
	return studioSegmentFrom(seg.nextPos, seg.ctx0 + (seg.pos1 - seg.pos0));
}

function studioSegmentCopy(seg) {
	return seg ? { pos0: seg.pos0, pos1: seg.pos1, ctx0: seg.ctx0, nextPos: seg.nextPos } : null;
}

// Transport position -> AudioContext time within one piece.
function studioTimeAt(pos, p0, ctx0) {
	return ctx0 + (pos - p0);
}

function studioFlushSources() {
	var list = studioAudio.sources || [];
	list.forEach(function (entry) {
		try { entry.src.stop(0); } catch (e) {}
		try { entry.src.disconnect(); } catch (e) {}
		if (entry.gain) { try { entry.gain.disconnect(); } catch (e) {} }
	});
	studioAudio.sources = [];
}

// A take was added, moved, trimmed or removed while the transport runs: drop
// what was queued for the rest of this pass and re-anchor scheduling at the
// playhead, so the edit is heard on the next tick instead of at the next wrap.
function studioTakesChanged() {
	if (mixer['time']['status'] != 'play' && mixer['time']['status'] != 'record') { return; }
	var ctx = studioAudio.ctx;
	var seg = studioAudio.playSeg;
	if (!ctx || !seg) { return; }
	var pos = seg.pos0 + (ctx.currentTime - seg.ctx0);
	studioFlushSources();
	seg = studioSegmentFrom(pos, ctx.currentTime);
	studioAudio.playSeg = seg;
	studioAudio.schedSeg = studioSegmentCopy(seg);
	studioAudio.clickSeg = studioSegmentCopy(seg);
	studioScheduleTick();
}

// Park a scheduled source so it can be flushed on a stop, seek or wrap.
function studioTrackSource(src, gain) {
	var entry = { src: src, gain: gain };
	src.onended = function () {
		var list = studioAudio.sources;
		var at = list.indexOf(entry);
		if (at != -1) { list.splice(at, 1); }
		try { src.disconnect(); } catch (e) {}
		if (gain) { try { gain.disconnect(); } catch (e) {} }
	};
	studioAudio.sources.push(entry);
}

// Begin (or restart) the transport at a transport position, anchored to now.
function studioClockStart(pos) {
	var ctx = studioContext();
	if (!ctx) { return; }
	// resuming past a committed loop lands back on its in-point, so the section
	// repeats instead of running on past its end
	var region = studioLoopRegion();
	if ((mixer['time']['loop'] == 'ongoing') && region && pos >= region.end) { pos = region.start; }
	studioFlushSources();
	var seg = studioSegmentFrom(pos, ctx.currentTime);
	studioAudio.playSeg = seg;
	studioAudio.schedSeg = studioSegmentCopy(seg);
	studioAudio.clickSeg = studioSegmentCopy(seg);
	mixer['time']['position'] = pos;
	studioScheduleTick();
}

// Move the playhead along the clock, wrapping or finishing at a piece boundary.
function studioClockAdvance() {
	var ctx = studioAudio.ctx;
	var seg = studioAudio.playSeg;
	if (!ctx || !seg) { return; }
	var now = ctx.currentTime;
	var pos = seg.pos0 + (now - seg.ctx0);
	if (seg.pos1 !== Infinity && pos >= seg.pos1 - 1e-9) {
		var next = studioSegmentNext(seg);
		if (next) {
			studioAudio.playSeg = next;
			seg = next;
			pos = seg.pos0 + (now - seg.ctx0);
		}
		else {
			mixer['time']['position'] = seg.pos1;
			studioStop();
			mixer['time']['status'] = 'stop';
			return;
		}
	}
	mixer['time']['position'] = pos;
}

// Place everything that will be heard in the next `lookahead` seconds.
function studioScheduleTick() {
	var ctx = studioAudio.ctx;
	if (!ctx || !studioAudio.schedSeg) { return; }
	var horizon = ctx.currentTime + (studioAudio.lookahead || 0.12);
	var guard = 0;

	// Takes: a bounded piece (one loop pass, or the run to the song's end) is
	// committed whole, so a looping take is a single grid-locked block per pass
	// with no seams. An open-ended run (recording) is committed in chunks.
	while (studioAudio.schedSeg && guard++ < 256) {
		var seg = studioAudio.schedSeg;
		if (seg.ctx0 > horizon) { break; }
		if (seg.pos1 === Infinity) {
			var to = seg.pos0 + (studioAudio.chunk || 1.0);
			studioScheduleTakes(seg.pos0, to, seg.ctx0);
			seg.ctx0 += (to - seg.pos0);
			seg.pos0 = to;
		}
		else {
			studioScheduleTakes(seg.pos0, seg.pos1, seg.ctx0);
			studioAudio.schedSeg = studioSegmentNext(seg);
		}
	}

	// Clicks: placed in short chunks so the metronome answers a toggle or a
	// tempo change quickly, and so a wrap never schedules a beat on the wrong
	// side of the loop point.
	var cguard = 0;
	while (studioAudio.clickSeg && cguard++ < 256) {
		var c = studioAudio.clickSeg;
		if (c.ctx0 > horizon) { break; }
		var span = (c.pos1 === Infinity) ? Infinity : (c.pos1 - c.pos0);
		var step = 0.5;
		var to2 = (span === Infinity) ? (c.pos0 + step) : Math.min(c.pos1, c.pos0 + step);
		studioScheduleClicks(c.pos0, to2, c.ctx0);
		if (span !== Infinity && to2 >= c.pos1 - 1e-9) {
			studioAudio.clickSeg = studioSegmentNext(c);
		}
		else {
			c.ctx0 += (to2 - c.pos0);
			c.pos0 = to2;
		}
	}
}

// The channel fader / pan feed the take bus, so set them once per pass rather
// than per take.
function studioApplyPlaybackMix() {
	$.each(studioAudio.channels, function (ch, c) {
		if (!c) { return; }
		c.playBus.gain.value = studioVolumeFraction($('.channel_volume[channel="' + ch + '"]').val());
		c.playPan.pan.value = (studioKnobNumber($('.knob_control[channel="' + ch + '"][control="pan"]').val(), 50) - 50) / 50;
	});
}

// The clip-edge gain, matching the media-element path's ramps: fade in over the
// first 2*fIn of the window, fade out over the last 2*fOut.
function studioTakeGain(winStart, fadeIn, winEnd, fadeOut, pos) {
	var g = 1;
	if (fadeIn > 0) { g *= Math.max(0, Math.min(1, (pos - winStart) / fadeIn)); }
	if (fadeOut > 0 && isFinite(winEnd)) { g *= Math.max(0, Math.min(1, (winEnd - pos) / fadeOut)); }
	return g;
}

function studioScheduleTakes(p0, p1, ctx0) {
	if (!(p1 > p0)) { return; }
	studioApplyPlaybackMix();
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m.media || !m.media.out) { return; }
		var armed = m.armed && (m.armed.state == 'rec' || m.armed.state == 'play' || m.armed.state == 'loop');
		if (!armed) { return; }
		var ordered = studioChannelTakes(ch);
		ordered.forEach(function (take, i) {
			if (!take || take.status == 'recording') { return; }
			if (take.encoding && take.encoding.indexOf('video') !== -1) { return; }
			if (!take.buffer) { studioTakeRequestBuffer(take); return; }
			studioScheduleTake(ch, take, ordered, i, p0, p1, ctx0);
		});
	});
}

function studioScheduleTake(ch, take, ordered, i, p0, p1, ctx0) {
	var c = studioAudio.channels[ch];
	if (!c || !c.playBus) { return; }
	var buf = take.buffer;
	if (!buf) { return; }
	var off = take.offset || 0;
	var ts = take.startTime;
	var dom = take.duration || 0;
	if (!(dom > 0)) { dom = buf.duration || 0; }
	if (!(dom > 0)) { return; }
	var looping = !!take.loop;
	var end = ts + dom;

	var xf = studioCrossfade();
	var prev = ordered[i - 1];
	var next = ordered[i + 1];
	var fIn = 0, fOut = 0;
	if (prev) {
		var fi = Math.min(xf, prev.duration || 0, dom) / 2;
		if (fi > 0 && prev.src !== take.src && Math.abs(ts - (prev.startTime + (prev.duration || 0))) <= fi * 2) { fIn = fi; }
	}
	if (next && !looping) {
		var fo = Math.min(xf, dom, next.duration || 0) / 2;
		if (fo > 0 && next.src !== take.src && Math.abs(next.startTime - end) <= fo * 2) { fOut = fo; }
	}
	var winStart = ts - fIn;
	var winEnd = looping ? Infinity : end + fOut;
	var timeAt = function (p) { return studioTimeAt(p, p0, ctx0); };

	var scheduleOne = function (a, b, bufferOffset) {
		if (!(b > a)) { return; }
		var when = timeAt(a);
		var dur = b - a;
		var now = studioAudio.ctx.currentTime;
		// scheduling fell behind (a throttled timer): start late instead of in
		// the past, trimming the buffer offset by however much was skipped
		if (when < now) {
			var trim = now - when;
			if (trim >= dur) { return; }
			when = now; bufferOffset += trim; dur -= trim;
		}
		if (bufferOffset < 0) { bufferOffset = 0; }
		if (isFinite(buf.duration) && bufferOffset >= buf.duration - 1e-4) { return; }
		var src = studioAudio.ctx.createBufferSource();
		src.buffer = buf;
		var g = studioAudio.ctx.createGain();
		src.connect(g).connect(c.playBus);
		g.gain.setValueAtTime(studioTakeGain(winStart, 2 * fIn, winEnd, 2 * fOut, a), when);
		var fiEnd = winStart + (2 * fIn);
		if (fIn > 0 && fiEnd > a && fiEnd <= b) { g.gain.linearRampToValueAtTime(1, timeAt(fiEnd)); }
		if (fOut > 0 && isFinite(winEnd)) {
			var foStart = winEnd - (2 * fOut);
			if (foStart > a && foStart < b) { g.gain.setValueAtTime(1, timeAt(foStart)); }
			g.gain.linearRampToValueAtTime(0, timeAt(winEnd));
		}
		src.start(when, bufferOffset, dur);
		studioTrackSource(src, g);
	};

	if (looping) {
		// a looping sample repeats every `dom` seconds from its in-point
		var k = Math.floor((p0 - ts) / dom);
		if (!isFinite(k) || k < 0) { k = 0; }
		var cs = ts + (k * dom);
		var guard = 0;
		while (cs < p1 && guard++ < 4096) {
			var a = Math.max(p0, cs);
			var b = Math.min(p1, cs + dom);
			scheduleOne(a, b, off + (a - cs));
			cs += dom;
		}
	}
	else {
		var a2 = Math.max(p0, ts);
		var b2 = Math.min(p1, end);
		scheduleOne(a2, b2, off + (a2 - ts));
	}
}

function studioScheduleClicks(p0, p1, ctx0) {
	var ctx = studioAudio.ctx;
	if (!ctx || !mixer['time']['bpm']) { return; }
	var beat = studioBeatSeconds();
	if (!(beat > 0)) { return; }
	var on = mixer['time']['metronome'] == 'yes';
	var punch = mixer['time']['punch_in'];
	var counting = mixer['time']['status'] == 'record' && punch !== undefined && punch !== null;
	if (!on && !counting) { return; }
	var beatsPerBar = studioKnobNumber(String(mixer['time']['sig'] || '4/4').split('/')[0], 4) || 4;
	var volume = studioKnobNumber($('.knob_control[channel="metronome"][control="volume"]').val(), 50) / 100;
	var k0 = Math.ceil((p0 / beat) - 1e-6);
	var k1 = Math.floor(((p1 - 1e-6) / beat));
	var guard = 0;
	for (var k = k0; k <= k1 && guard++ < 1024; k++) {
		var pos = k * beat;
		// a count-in clicks even with the metronome off, but only up to the punch
		if (counting && !on && pos >= punch) { continue; }
		var when = studioTimeAt(pos, p0, ctx0);
		if (when < ctx.currentTime) { continue; }
		var accent = (Math.abs(k) % beatsPerBar) ? 0 : 1;
		var osc = ctx.createOscillator();
		var gain = ctx.createGain();
		osc.frequency.value = accent ? 1100 : 900;
		osc.type = 'triangle';
		gain.gain.value = volume;
		osc.connect(gain).connect(ctx.destination);
		osc.start(when);
		osc.stop(when + 0.02);
		studioTrackSource(osc, gain);
	}
}

// Decode a take's blob (or file) into an AudioBuffer so it can be scheduled.
function studioTakeArrayBuffer(take) {
	if (take.data && take.data.arrayBuffer) { return take.data.arrayBuffer(); }
	if (take.src) { return fetch(take.src).then(function (r) { return r.arrayBuffer(); }); }
	return Promise.reject(new Error('no source'));
}

function studioTakeRequestBuffer(take) {
	if (!take || take.buffer || take.bufferFailed || take.bufferLoading) { return; }
	if (take.encoding && take.encoding.indexOf('video') !== -1) { return; }
	if (!take.data && !take.src) { return; }
	var ctx = studioAudio.ctx || studioContext();
	if (!ctx) { return; }
	take.bufferLoading = true;
	studioTakeArrayBuffer(take).then(function (ab) {
		return new Promise(function (resolve, reject) { ctx.decodeAudioData(ab, resolve, reject); });
	}).then(function (audio) {
		take.buffer = audio;
		delete take.bufferLoading;
		if (!(take.duration > 0)) { take.duration = audio.duration || 0; }
		// if the transport is already past this take for the current pass, re-anchor
		// so the freshly decoded audio joins now rather than at the next wrap
		studioTakesChanged();
	}).catch(function (e) {
		take.bufferFailed = true;
		delete take.bufferLoading;
		console.log('studio: could not decode take, falling back to its element', e);
	});
}

// Audio takes ride the audio clock; video (and undecodable) takes keep a media
// element, whose own pipeline latency cannot be removed.
function studioTakeUsesBuffer(take) {
	if (!take) { return false; }
	if (take.buffer) { return true; }
	if (take.bufferFailed) { return false; }
	if (take.encoding && take.encoding.indexOf('video') !== -1) { return false; }
	return true;
}

// Keep every take aligned to the transport. A take maps timeline position to
// its own source time as  source = (position - startTime) + offset, where
// `offset` is the in-point after any left trim or split. Where a clip meets a
// neighbour (butted or overlapping) each side ramps over half the crossfade
// length into the other's territory, so the two gains sum to about one.
// Looping takes never ramp out; they wrap to their in-point instead.
function studioSyncTakes() {
	var pos = mixer['time']['position'];
	studioApplyPlaybackMix();
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m.media || !m.media.out) { return; }
		var armed = m.armed && (m.armed.state == 'rec' || m.armed.state == 'play' || m.armed.state == 'loop');
		if (!armed) { return; }

		var xf = studioCrossfade();
		var ordered = studioChannelTakes(ch);
		ordered.forEach(function (take, i) {
			// audio takes are placed by the scheduler on the audio clock; only
			// video / undecodable takes ride a media element
			if (studioTakeUsesBuffer(take)) { return; }
			var el = take.track;
			if (!el || !el.src) { return; }
			var offset = take.offset || 0;
			var start = take.startTime;
			var dur = take.duration || 0;
			var end = start + dur;
			var looping = !!(take.loop && dur > 0);
			var prev = ordered[i - 1];
			var next = ordered[i + 1];

			var fIn = 0, fOut = 0;
			if (prev) {
				var fi = Math.min(xf, prev.duration || 0, dur) / 2;
				if (fi > 0 && prev.src !== take.src && Math.abs(start - (prev.startTime + (prev.duration || 0))) <= fi * 2) { fIn = fi; }
			}
			if (next && !looping) {
				var fo = Math.min(xf, dur, next.duration || 0) / 2;
				if (fo > 0 && next.src !== take.src && Math.abs(next.startTime - end) <= fo * 2) { fOut = fo; }
			}

			var winStart = start - fIn;
			var winEnd = looping ? Infinity : end + fOut;
			var routed = !!studioTakeNode(ch, take);
			if (!routed) { el.volume = studioVolumeFraction($('.channel_volume[channel="' + ch + '"]').val()); }

			studioSetTakeLoop(el, looping ? offset : 0, looping ? offset + dur : 0);

			if (pos < winStart || pos >= winEnd) {
				if (!el.paused) { try { el.pause(); } catch (e) {} }
				var reset = offset - fIn;
				if (reset < 0) { reset = 0; }
				if (el.currentTime != reset) { try { el.currentTime = reset; } catch (e) {} }
				if (take.playGain) { take.playGain.gain.value = 0; }
				el.playbackRate = 1;
				return;
			}

			var g = 1;
			if (fIn > 0) { g *= Math.max(0, Math.min(1, (pos - winStart) / (2 * fIn))); }
			if (fOut > 0) { g *= Math.max(0, Math.min(1, (winEnd - pos) / (2 * fOut))); }
			if (take.playGain) { take.playGain.gain.value = g; }

			var elapsed = pos - start;
			if (elapsed < 0) { elapsed = 0; }
			var target = elapsed + offset;
			if (looping) { target = offset + (elapsed % dur); }
			if (target < 0) { target = 0; }
			if (mixer['time']['status'] == 'scroll') { try { el.currentTime = target; } catch (e) {} el.playbackRate = 1; return; }
			if (el.paused) {
				// Never start past the end of the file: the element would silently
				// seek back to the top, which sounds like a blip of the take's start.
				if (isFinite(el.duration) && el.duration > 0 && target >= el.duration - 0.005) {
					if (take.playGain) { take.playGain.gain.value = 0; }
					return;
				}
				el.playbackRate = 1;
				try { el.currentTime = target; } catch (e) {}
				var p = el.play();
				if (p && p.catch) { p.catch(function () {}); }
			}
			else {
				studioSyncTakeClock(take, el, target, looping ? dur : 0);
				if (looping && !('loopStart' in el) && el.currentTime >= offset + dur - 0.005) {
					// no loop points to lean on: wrap the take by hand
					try { el.currentTime = target; } catch (e) {}
				}
			}
		});
	});
	studioVideoPreview(pos);
}

// Mirror the clip currently under the playhead to the main video monitor, so you
// can see what you're cutting (the selected channel wins).
function studioVideoPreview(pos) {
	var monitor = document.getElementById('studio_video_monitor');
	if (!monitor) { return; }
	var status = mixer['time']['status'];
	if (status != 'play' && status != 'record' && status != 'scroll') { return; }
	var channels = Object.keys(mixer).filter(function (k) { return /^[0-9]+$/.test(k); });
	channels.sort(function (a, b) {
		return (b == studioSelectedChannel ? 1 : 0) - (a == studioSelectedChannel ? 1 : 0);
	});
	var found = null;
	for (var i = 0; i < channels.length && !found; i++) {
		var takes = (mixer[channels[i]].media && mixer[channels[i]].media.out) || [];
		for (var n = 0; n < takes.length; n++) {
			var take = takes[n];
			if (!take || !take.src || take.status == 'recording') { continue; }
			if (take.encoding && take.encoding.indexOf('video') === -1) { continue; }
			if (pos >= take.startTime && pos < take.startTime + (take.duration || 0)) { found = take; break; }
		}
	}
	if (!found) { return; }
	if (monitor.getAttribute('data-take-src') != found.src) {
		monitor.setAttribute('data-take-src', found.src);
		monitor.src = found.src;
		monitor.muted = true;
	}
	var t = pos - found.startTime + (found.offset || 0);
	if (Math.abs((monitor.currentTime || 0) - t) > 0.2) {
		try { monitor.currentTime = t; } catch (e) {}
	}
	monitor.style.display = '';
}

// ---- canvas -----------------------------------------------------------------

function studioFitCanvas(canvas) {
	if (!canvas) { return; }
	var w = canvas.clientWidth || canvas.width || 300;
	var h = canvas.clientHeight || canvas.height || 60;
	if (canvas.width != w) { canvas.width = w; }
	if (canvas.height != h) { canvas.height = h; }
}

function studioDrawChannel(ch) {
	var canvas = document.getElementById('track_view_' + ch);
	if (!canvas) { return; }
	studioFitCanvas(canvas);
	var ctx = canvas.getContext('2d');
	var w = canvas.width, h = canvas.height;
	ctx.clearRect(0, 0, w, h);
	ctx.fillStyle = 'rgba(255,255,255,0.18)';
	ctx.fillRect(0, 0, w, h);

	var duration = mixer['time']['duration'] > 0 ? mixer['time']['duration'] : 1;
	var m = mixer[ch] || {};
	var co = studioAudio.channels[ch];

	if (co && co.source) {
		co.recAnalyser.getFloatTimeDomainData(co.recData);
		ctx.strokeStyle = '#0a8a3a';
		ctx.lineWidth = 1;
		ctx.beginPath();
		for (var i = 0; i < w; i++) {
			var v = co.recData[Math.floor(i / w * co.recData.length)] || 0;
			var y = (h / 2) + (v * h * 0.45);
			if (i === 0) { ctx.moveTo(i, y); } else { ctx.lineTo(i, y); }
		}
		ctx.stroke();
	}

	// the loop region: reserved bars, or what arming L would reserve now
	var region = studioVisibleRegion();
	var region_x = 0, region_w = 0;
	if (region && region.end > region.start) {
		region_x = (region.start / duration) * w;
		region_w = Math.max(2, ((region.end - region.start) / duration) * w);
		ctx.fillStyle = 'rgba(255,255,255,0.22)';
		ctx.fillRect(region_x, 0, region_w, h);
	}

	if (m.media && m.media.out) {
		var orderedDraw = studioChannelTakes(ch, true);
		var xfDraw = studioCrossfade();
		orderedDraw.forEach(function (take, tIndex) {
			if (!take) { return; }
			studioEnsureWaveform(ch, take);
			var x = (take.startTime / duration) * w;
			var tw = Math.max(2, ((take.duration || 0) / duration) * w);
			var selected = studioSelectedTake && studioSelectedTake.take === take;
			var isVideo = take.encoding && take.encoding.indexOf('video') !== -1;
			ctx.fillStyle = take.status == 'recording' ? 'rgba(220,0,0,0.55)' : (isVideo ? 'rgba(120,60,190,0.5)' : 'rgba(20,90,190,0.5)');
			ctx.fillRect(x, 3, tw, h - 6);

			// a looping take repeats across the rest of the song: ghost those passes
			if (take.loop && take.duration > 0) {
				ctx.save();
				ctx.globalAlpha = 0.16;
				ctx.fillStyle = '#145abe';
				for (var gx = x + tw; gx < w; gx += tw) { ctx.fillRect(gx, 3, tw, h - 6); }
				ctx.restore();
			}

			// waveform peaks
			if (take.waveform && take.waveform.length) {
				var peaks = take.waveform;
				var mid = h / 2;
				ctx.save();
				ctx.beginPath();
				ctx.rect(x, 3, tw, h - 6);
				ctx.clip();
				ctx.strokeStyle = 'rgba(255,255,255,0.85)';
				ctx.lineWidth = 1;
				ctx.beginPath();
				for (var b = 0; b < tw; b++) {
					var idx = Math.min(peaks.length - 1, Math.floor((b / tw) * peaks.length));
					var amp = peaks[idx] * (h * 0.42);
					ctx.moveTo(x + b, mid - amp);
					ctx.lineTo(x + b, mid + amp);
				}
				ctx.stroke();
				ctx.restore();
			}

			// crossfade shading at the junctions
			if (xfDraw > 0 && take.duration) {
				var endT = take.startTime + take.duration;
				var prev = orderedDraw[tIndex - 1];
				var next = orderedDraw[tIndex + 1];
				var shade = function (from, to) {
					var fx = (from / duration) * w;
					var tx = (to / duration) * w;
					ctx.fillStyle = 'rgba(255,220,40,0.30)';
					ctx.fillRect(fx, 3, Math.max(1, tx - fx), h - 6);
				};
				if (prev && prev.src !== take.src) {
					var fi = Math.min(xfDraw, prev.duration || 0, take.duration) / 2;
					if (fi > 0 && Math.abs(take.startTime - (prev.startTime + (prev.duration || 0))) <= fi * 2) { shade(take.startTime - fi, take.startTime + fi); }
				}
				if (next && next.src !== take.src) {
					var fo = Math.min(xfDraw, take.duration, next.duration || 0) / 2;
					if (fo > 0 && Math.abs(next.startTime - endT) <= fo * 2) { shade(endT - fo, endT + fo); }
				}
			}

			ctx.strokeStyle = selected ? '#ffd21e' : '#04325f';
			ctx.lineWidth = selected ? 3 : 1;
			ctx.strokeRect(x, 3, tw, h - 6);
			// grab handles
			ctx.fillStyle = '#04325f';
			ctx.fillRect(x, 3, 3, h - 6);
			ctx.fillRect(x + tw - 3, 3, 3, h - 6);
			// a paler bar marks a trimmed/split in-point
			if (take.offset > 0 && tw > 6) {
				ctx.fillStyle = '#ffe9a8';
				ctx.fillRect(x + 3, 3, 3, h - 6);
			}
			// a dashed edge + arrow marks a looping sample
			if (take.loop && take.duration > 0) {
				ctx.save();
				ctx.strokeStyle = 'rgba(255,255,255,0.9)';
				ctx.setLineDash([4, 3]);
				ctx.strokeRect(x + 1.5, 4.5, Math.max(1, tw - 3), h - 9);
				ctx.restore();
				ctx.fillStyle = '#ffffff';
				ctx.font = '10px sans-serif';
				ctx.fillText('\u21bb', x + 6, 14);
			}
		});
	}

	if (region && region.end > region.start) {
		ctx.save();
		ctx.strokeStyle = 'rgba(255,255,255,0.9)';
		ctx.setLineDash([5, 4]);
		ctx.lineWidth = 1;
		ctx.strokeRect(region_x + 0.5, 0.5, Math.max(1, region_w - 1), h - 1);
		ctx.restore();
		ctx.fillStyle = '#04325f';
		ctx.font = '10px sans-serif';
		ctx.fillText(studioBarLabel(region.start) + ' \u2192 ' + studioBarLabel(region.end) + (region.tentative ? ' loop' : ' (loop)'), region_x + 4, h - 3);
	}

	if (mixer['time']['position'] > 0) {
		var px = (mixer['time']['position'] / duration) * w;
		ctx.strokeStyle = 'black';
		ctx.lineWidth = 2;
		ctx.beginPath();
		ctx.moveTo(px, 0);
		ctx.lineTo(px, h);
		ctx.stroke();
	}
}

function studioDrawMetre(ch) {
	var canvas = document.getElementById('channel_volume_metre_' + ch);
	var co = studioAudio.channels[ch];
	if (!canvas || !co || !co.source) { return; }
	studioFitCanvas(canvas);
	var ctx = canvas.getContext('2d');
	var w = canvas.width, h = canvas.height;
	ctx.clearRect(0, 0, w, h);
	co.recAnalyser.getFloatTimeDomainData(co.recData);
	var sum = 0;
	for (var i = 0; i < co.recData.length; i++) { sum += co.recData[i] * co.recData[i]; }
	var level = Math.min(1, Math.sqrt(sum / co.recData.length) * 3);
	ctx.fillStyle = 'green';
	ctx.fillRect(0, h - (level * h), w, level * h);
}

function studioDrawTracks() {
	// the transport keeps running while the tab is hidden, but there is no point
	// repainting canvases nobody can see
	if (document.hidden) { return; }
	$.each(mixer, function (ch) {
		if (!/^[0-9]+$/.test(ch)) { return; }
		studioDrawChannel(ch);
		studioDrawMetre(ch);
	});
}

function studioUpdateFxBadges() {
	$.each(studioAudio.channels, function (ch, c) {
		var holder = $('.channel_fx[channel="' + ch + '"]');
		holder.empty();
		c.inserts.forEach(function (ins) {
			var src = $('.pedal_background[hint="' + ins.name + '"]').attr('src') || '';
			$('<img class="channel_fx_pedal">').attr('src', src).attr('hint', ins.name).appendTo(holder);
		});
	});
}

// Knob hints carry the knob's current value, since the artwork alone can't show it.
function studioUpdateKnobHints() {
	$('.knob').each(function () {
		var knob = $(this);
		var control = knob.attr('control');
		if (!control) { return; }
		var input = $('.knob_control[control="' + control + '"][channel="' + knob.attr('channel') + '"]');
		if (!input.length) { return; }
		var value = numeral(input.val()).value();
		if (value === null || value === undefined || isNaN(value)) { value = input.val(); }
		else if (Math.abs(value - Math.round(value)) < 0.05) { value = Math.round(value); }
		else { value = numeral(value).format('0.0'); }
		knob.attr('hint', String(control).replace(/_/g, ' ') + ': ' + value);
	});
}

// ---- take editing on the canvas --------------------------------------------

// How far to pull a freshly recorded take back in time to cancel the round
// trip. An explicit record_offset (ms) in the song admin wins; otherwise use
// the AudioContext's reported output latency plus whatever the input stream
// reports for itself, since the browser's output figure on its own is often an
// under-estimate of what the player actually hears and plays against.
function studioRecordOffset(ch) {
	var raw = mixer['time']['record_offset'];
	if (raw !== undefined && raw !== null && String(raw).length > 0) {
		var n = numeral(raw).value();
		if (n !== null && n !== undefined && !isNaN(n)) { return n / 1000; }
	}
	var ctx = studioAudio.ctx;
	if (!ctx) { return 0; }
	var offset = (ctx.baseLatency || 0) + (ctx.outputLatency || 0);
	var m = (ch !== undefined && ch !== null) ? (mixer[ch] && mixer[ch].media) : null;
	if (m && m.latency > 0) { offset += m.latency; }
	return offset;
}

// ---- loop regions ----------------------------------------------------------

// One bar of the current tempo + signature, in seconds.
function studioBarSeconds() {
	var bpm = studioKnobNumber(mixer['time']['bpm'], 120) || 120;
	var sig = String(mixer['time']['sig'] || '4/4').split('/');
	var beats = studioKnobNumber(sig[0], 4) || 4;
	return Math.max(0.05, (60 / bpm) * beats);
}

// How many bars a loop take covers. Blank or 0 means "follow the playing": no
// region is reserved, and only the take's length is snapped to whole bars.
function studioLoopBars() {
	var raw = mixer['time']['loop_bars'];
	if (raw === undefined || raw === null) { return 4; }
	var n = studioKnobNumber(raw, 0);
	return n > 0 ? Math.floor(n) : 0;
}

function studioBeatSeconds() {
	var bpm = studioKnobNumber(mixer['time']['bpm'], 120) || 120;
	return 60 / bpm;
}

// Where a recording locks: the bar line (default), the nearest beat, or
// nothing at all — free wheeling from wherever the playhead happens to be.
function studioSnapUnit() {
	var mode = String((mixer['time'] && mixer['time']['snap']) || 'bar');
	if (mode == 'off' || mode == 'free' || mode == 'none') { return 0; }
	if (mode == 'beat') { return studioBeatSeconds(); }
	return studioBarSeconds();
}

// Beats of count-in before a recording starts. Blank follows the signature (4
// in 4/4, 3 in 3/4); 0 turns the count-in off.
function studioCountInBeats() {
	var raw = mixer['time']['count_in'];
	if (raw === undefined || raw === null || String(raw).length == 0) {
		var sig = String(mixer['time']['sig'] || '4/4').split('/');
		return studioKnobNumber(sig[0], 4) || 4;
	}
	var n = studioKnobNumber(raw, 0);
	return n > 0 ? Math.floor(n) : 0;
}

// The committed region: where the last loop take was recorded, which is also
// the section the transport repeats while "ongoing". Stored as a bar, so a
// tempo change keeps it musical.
function studioLoopRegion() {
	var r = mixer['time'] && mixer['time']['loop_region'];
	if (!r || !(r.bars > 0)) { return null; }
	var bar = studioBarSeconds();
	return { start: r.start, bars: r.bars, end: r.start + (r.bars * bar) };
}

// What recording now would commit: the snapped position the playhead is at (or
// in), for the configured number of bars. Drawn while a channel waits on L, so
// the bars can be lined up before a note is played.
function studioProspectiveRegion() {
	var status = mixer['time']['status'];
	if (status != 'stop' && status != 'scroll') { return null; }
	if (!studioAnyChannelArmed('loop')) { return null; }
	var bars = studioLoopBars();
	if (bars <= 0) { return null; }
	var start = mixer['time']['position'];
	var unit = studioSnapUnit();
	if (unit > 0) { start = Math.floor(start / unit) * unit; }
	return { start: start, bars: bars, end: start + (bars * studioBarSeconds()), tentative: true };
}

function studioVisibleRegion() {
	var status = mixer['time']['status'];
	if (status == 'stop' || status == 'scroll') {
		var prospective = studioProspectiveRegion();
		if (prospective) { return prospective; }
	}
	return studioLoopRegion();
}

// "2:1" style, the same numbering the time display uses.
function studioBarLabel(seconds) {
	return Math.round(seconds / studioBarSeconds()) + ':1';
}

function studioAnyChannelArmed(state) {
	var found = false;
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m.armed) { return; }
		if (m.armed.state == state) { found = true; }
	});
	return found;
}

// How long a take that repeats should be: the committed region when its end was
// reached, otherwise the played span snapped to the grid the recording started
// on (whole bars, whole beats, or untouched when free wheeling).
function studioLoopTakeDuration(take) {
	var region = take.region;
	var bar = studioBarSeconds();
	if (region && region.bars > 0 && mixer['time']['position'] >= region.end) { return region.bars * bar; }
	var span = mixer['time']['position'] - take.startTime - (take.latency || 0);
	var unit = studioSnapUnit();
	if (unit > 0) { span = Math.max(unit, Math.round(span / unit) * unit); }
	else { span = Math.max(0.05, span); }
	if (region && region.bars > 0) { span = Math.min(span, region.bars * bar); }
	return span;
}

var studioTakeDrag = null;
var studioSelectedTake = null;

function studioCanvasChannel(canvas) {
	var m = (canvas && canvas.id || '').match(/^track_view_(\d+)$/);
	return m ? m[1] : null;
}

// Everything a clip edge can snap to: the playhead, the ends of the song, and
// every other clip's edges across all channels.
function studioSnapTargets(ch, exclude) {
	var targets = [0, mixer['time']['position']];
	if (mixer['time']['duration']) { targets.push(mixer['time']['duration']); }
	$.each(mixer, function (c, m) {
		if (!/^[0-9]+$/.test(c) || !m.media || !m.media.out) { return; }
		m.media.out.forEach(function (take) {
			if (!take || take === exclude) { return; }
			targets.push(take.startTime);
			targets.push(take.startTime + (take.duration || 0));
		});
	});
	return targets;
}

function studioSnap(value, targets, threshold) {
	var best = value;
	var bestd = threshold;
	targets.forEach(function (t) {
		var d = Math.abs(t - value);
		if (d < bestd) { bestd = d; best = t; }
	});
	return best;
}

function studioCanvasHit(canvas, clientX) {
	var ch = studioCanvasChannel(canvas);
	if (!ch) { return null; }
	var rect = canvas.getBoundingClientRect();
	if (!rect.width) { return null; }
	var duration = mixer['time']['duration'] > 0 ? mixer['time']['duration'] : 1;
	var x = clientX - rect.left;
	var t = (x / rect.width) * duration;
	var tpp = duration / rect.width;
	var takes = (mixer[ch] && mixer[ch].media && mixer[ch].media.out) || [];
	for (var i = takes.length - 1; i >= 0; i--) {
		var take = takes[i];
		if (!take || take.status == 'recording') { continue; }
		var end = take.startTime + (take.duration || 0);
		if (t >= take.startTime - (6 * tpp) && t <= end + (6 * tpp)) {
			var mode = 'move';
			if (take.duration) {
				if (Math.abs(x - (take.startTime / duration) * rect.width) < 8) { mode = 'trim-start'; }
				else if (Math.abs(x - (end / duration) * rect.width) < 8) { mode = 'trim-end'; }
			}
			return { ch: ch, take: take, mode: mode, tpp: tpp, x: clientX, t: t,
				startTime: take.startTime, startDur: take.duration || 0, startOffset: take.offset || 0 };
		}
	}
	return null;
}

function studioRemoveTake(ch, take) {
	var media = mixer[ch] && mixer[ch].media;
	if (!media || !media.out) { return; }
	if (take.track) {
		if (!take.track.paused) { try { take.track.pause(); } catch (e) {} }
		if (take.track.parentNode) { take.track.parentNode.removeChild(take.track); }
	}
	media.out = media.out.filter(function (t) { return t !== take; });
	studioReindexTakes(ch);
	if (studioSelectedTake && studioSelectedTake.take === take) { studioSelectedTake = null; }
	studioDrawChannel(ch);
	studioSaver();
	studioTakesChanged();
}

function studioReindexTakes(ch) {
	var media = mixer[ch] && mixer[ch].media;
	if (!media || !media.out) { return; }
	// element ids must match the array positions the server stores files by
	media.out.forEach(function (t, i) { if (t && t.track) { t.track.id = 'studio_channel_' + ch + '_' + i; } });
}

// Razor: cut a clip in two at timeline position t. Both halves share the source;
// the right half is a new in-point into it.
function studioSplitTake(ch, take, t) {
	var media = mixer[ch] && mixer[ch].media;
	if (!media || !media.out) { return null; }
	var index = media.out.indexOf(take);
	if (index == -1) { return null; }
	var end = take.startTime + (take.duration || 0);
	if (t <= take.startTime + 0.02 || t >= end - 0.02) { return null; }

	var right = {
		uuid: take.uuid || null,
		startTime: t,
		offset: (take.offset || 0) + (t - take.startTime),
		duration: end - t,
		status: 'stop',
		src: take.src,
		encoding: take.encoding
	};
	// A razor cut ends the looper behaviour: both halves become ordinary clips.
	take.loop = false;
	right.loop = false;
	// A saved clip already has a server file, so both halves reference it. An
	// unsaved clip has to carry its blob so both halves get uploaded.
	if (!take.uuid) { right.data = take.data; }

	var el = document.createElement('video');
	el.className = 'studio_video';
	el.style.display = 'none';
	el.preload = 'auto';
	if (take.src) { el.src = take.src; }
	$('#studio_track_container').append(el);
	right.track = el;

	take.duration = t - take.startTime;
	media.out.splice(index + 1, 0, right);
	studioReindexTakes(ch);
	studioTakesChanged();
	return right;
}

$(document).on('pointerdown', '.track', function (e) {
	var hit = studioCanvasHit(this, e.originalEvent.clientX);
	if (!hit) {
		studioSelectedTake = null;
		studioDrawChannel(studioCanvasChannel(this));
		return;
	}
	studioSelectedTake = { ch: hit.ch, take: hit.take };
	studioTakeDrag = hit;
	studioDrawChannel(hit.ch);
});

$(document).on('pointermove', function (e) {
	if (!studioTakeDrag) { return; }
	var d = studioTakeDrag;
	var take = d.take;
	var dt = (e.originalEvent.clientX - d.x) * d.tpp;
	var targets = studioSnapTargets(d.ch, take);
	var threshold = d.tpp * 7;

	if (d.mode == 'move') {
		take.startTime = Math.max(0, studioSnap(d.startTime + dt, targets, threshold));
	}
	else if (d.mode == 'trim-end') {
		var srcDur = Infinity;
		if (take.buffer && isFinite(take.buffer.duration)) { srcDur = take.buffer.duration; }
		else if (take.track && isFinite(take.track.duration)) { srcDur = take.track.duration; }
		var maxDur = isFinite(srcDur) ? (srcDur - (take.offset || 0)) : Infinity;
		var end = studioSnap(d.startTime + d.startDur + dt, targets, threshold);
		take.duration = Math.max(0.05, Math.min(maxDur, end - take.startTime));
	}
	else if (d.mode == 'trim-start') {
		var newStart = Math.min(d.startTime + d.startDur - 0.05, d.startTime + dt);
		newStart = Math.max(0, studioSnap(newStart, targets, threshold));
		var delta = newStart - d.startTime;
		if (d.startOffset + delta < 0) { newStart = d.startTime - d.startOffset; delta = newStart - d.startTime; }
		take.startTime = newStart;
		take.offset = d.startOffset + delta;
		take.duration = Math.max(0.05, d.startDur - delta);
	}
	mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + (take.duration || 0));
	studioDrawChannel(d.ch);
	e.preventDefault();
});

$(document).on('pointerup', function () {
	if (!studioTakeDrag) { return; }
	var ch = studioTakeDrag.ch;
	studioTakeDrag = null;
	studioDrawChannel(ch);
	studioSaver();
	studioTakesChanged();
});

// double-click = razor cut at the clicked point
$(document).on('dblclick', '.track', function (e) {
	var hit = studioCanvasHit(this, e.originalEvent.clientX);
	if (!hit) { return; }
	studioSelectedTake = { ch: hit.ch, take: hit.take };
	studioSplitTake(hit.ch, hit.take, hit.t);
	studioDrawChannel(hit.ch);
	studioSaver();
});

$(document).on('keydown', function (e) {
	if (!studioSelectedTake) { return; }
	var tag = (e.target.tagName || '').toLowerCase();
	if (tag == 'input' || tag == 'textarea') { return; }
	if (e.key == 'Delete' || e.key == 'Backspace') {
		studioRemoveTake(studioSelectedTake.ch, studioSelectedTake.take);
		e.preventDefault();
	}
	else if (e.key == 's' || e.key == 'S') {
		var ch = studioSelectedTake.ch;
		studioSplitTake(ch, studioSelectedTake.take, mixer['time']['position']);
		studioDrawChannel(ch);
		studioSaver();
		e.preventDefault();
	}
});

// ---- pedal / channel selection ---------------------------------------------

$(document).on('click', '.channel', function (e) {
	if ($(e.target).is('input, button, img, canvas, video, .armed')) { return; }
	$('.channel').removeClass('selected_channel');
	$(this).addClass('selected_channel');
	var ch = ($(this).attr('class') || '').match(/channel_(\d+)/);
	if (ch) { studioSelectedChannel = ch[1]; }
});

$(document).on('click', '.channel_fx_pedal', function () {
	var name = $(this).attr('hint');
	if (name) { studioRevealPedal(name); }
});

// Bring an inserted pedal's controls into view: open the pedalboard, scroll it
// to the pedal and flag it, so a channel badge leads you to its settings.
function studioRevealPedal(name) {
	var pedal = $('#pedal_' + name);
	if (!pedal.length) { return; }
	var board = $('#pedalboard');
	if (!board.is(':visible')) {
		board.show();
		var z = numeral($('#studio_viewer').closest('.wind').css('z-index')).value() || 0;
		board.css({ 'z-index': (z + 100) });
	}
	var left = pedal.position().left + board.scrollLeft() - 40;
	board.stop().animate({ scrollLeft: Math.max(0, left) }, 200);
	pedal.addClass('pedal_revealed');
	clearTimeout(studioRevealPedal.timer);
	studioRevealPedal.timer = setTimeout(function () { pedal.removeClass('pedal_revealed'); }, 1600);
}

$(document).on('click', '#studio_new', function() {
	$('#studio').attr('uuid','').attr('name','');
	studioInit({ uuid: 'new', settings: [{ 'setting': 'last_song', 'value': 'new' }] });
	$('#studio_song_select').val('none');
});

$(document).on('click', '#pedalboard_hamburger', function() {
	var pd = $('#pedalboard');

	if (pd.is(':visible')) {
		pd.hide();
	}
	else {
		pd.show();
		// keep the tray above the mixer (the old code did string maths on the
		// window's z-index, which produced values like "auto10")
		var z = numeral($('#studio_viewer').closest('.wind').css('z-index')).value() || 0;
		pd.css({ 'z-index': (z + 100) });
	}
});

$(document).on('click', '#studio_toggle', function() {
	studioInit();
});

function studioInit(data) {
	if (!data) {
		data = {};
	}
	var jdata = JSON.stringify(data);
	var url = '/manager/studio';
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, data: jdata },
		success: function(response) {
			windowMaker(response.html);
			var studio_defaults = response.settings || {};
			mixer = {
				time: {
					duration: 0, status: 'stop', position: 0, marks: [], interval: 0, startTime: 0,
					loop: 'off', metronome: 'no', bpm: 120, sig: '4/4', display: 'time', beat: 0, bar: 0,
					lastMetronome: null, loop_region: null, punch_in: null, pending_takes: null,
					// seeded from the app settings, then kept per song
					loop_bars: studio_defaults['loop_bars'] || 4,
					snap: studio_defaults['snap'] || 'bar',
					count_in: (studio_defaults['count_in'] === undefined ? '' : studio_defaults['count_in']),
					monitor: studio_defaults['monitor'] || 'no'
				},
				buttons: { record: { obg: '', bg: 'red', interval: '' }, stop: { obg: '', bg: 'lightgreen', interval: '' }, play: { obg: '', bg: 'yellow', interval: '' } },
				settings: response.settings,
				automations: {}
			};
			// fresh channel graphs, but keep the shared AudioContext
			studioFlushSources();
			studioAudio = { ctx: studioAudio.ctx, master: studioAudio.master, masterAnalyser: studioAudio.masterAnalyser, channels: {}, sources: [], lookahead: studioAudio.lookahead || 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
			studioSelectedTake = null;
			studioTakeDrag = null;
			studioSongCache = null;
			$('#studio_track_container').html('');

			var pd = $('#pedalboard');
			if (!$('#soundroom_sidebar_container').is(':visible')) {

				var width = $('#soundroom_sidebar_container').width();
				width = (width + 30) + 'px';
				$('#studio').find('.to_sound').each(function(i,v) {
					var channel = $(v).attr('channel') + 1;
					$('#browser').append($(v).html());


					$(v).remove();
					$('.cord[channel="' + channel + '"]').draggable({
						start: function(p,ui) {
							$('.jack').show();
							
						},
						drag: function(p,ui) {

						},
						stop: function(p,ui) {
							$('.jack').hide();
						}
					});
				});
			}

			var channel_count = numeral(response.settings['channel_count']).value() || 4;
			for (var ch = 1; ch <= channel_count; ch++) {
				studioChannelEngine(ch);
				studioApplyChannel(ch);
				studioDrawChannel(ch);
			}
			studioApplyPedals();
			studioUpdateFxBadges();
			studioApplyCapture();
			studioApplyMonitor();
			studioUpdateLatencyInfo();

			// pedals are dragged from the pedalboard onto a channel strip
			$('.pedal_background').draggable({ helper: 'clone', revert: 'invalid', scroll: false, zIndex: 60000 });
			$('.channel').droppable({
				accept: '.pedal_background',
				tolerance: 'pointer',
				drop: function(event, ui) {
					var name = ui.draggable.attr('hint');
					var m = ($(this).attr('class') || '').match(/channel_(\d+)/);
					if (!name || !m) { return; }
					var ch = m[1];
					var c = studioAudio.channels[ch];
					studioSetInsert(ch, name, !(c && c.insertByName[name]));
					studioSaver();
				}
			});

			studioRetriever();
			studioUpdateKnobHints();
			if ($('#studio').attr('uuid')) {
				if (!data['uuid']) {
					data['uuid'] = $('#studio').attr('uuid');
				}
				if (data['uuid'] != 'new') {
					studioLoad(data['uuid']);
				}
					
			}
		}, error: function (response) {  }
	});
	
}

$(document).on('click', '.studio_close_button', function() {
	studioSelectedTake = null;
	studioTakeDrag = null;
	$('#soundroom_sidebar_container').html('').hide();
	$('.cord').remove();
});



// ---- knobs ------------------------------------------------------------------
// A knob is dragged up/down, or rolled, to change its value. Its hidden
// <input class="knob_control"> stays in the DOM as the value store - the song
// saver, the channel and pedal appliers, and the tooltips all read it - but it
// is never shown: the old click-to-reveal slider was laid out below the pedal's
// full-width artwork, so it was hidden under the pedal.
var studioKnobDrag = null;

function studioKnobInput(knob) {
	return $('.knob_control[control="' + knob.attr('control') + '"][channel="' + knob.attr('channel') + '"]');
}

function studioKnobReadout(knob, value) {
	var el = $('#studio_knob_readout');
	if (!el.length) { el = $('<div id="studio_knob_readout"></div>').appendTo('body'); }
	var at = knob.offset() || { left: 0, top: 0 };
	el.text(Math.round(value)).css({ display: 'block', left: at.left + 'px', top: (at.top - 24) + 'px' });
	clearTimeout(studioKnobReadout.timer);
	studioKnobReadout.timer = setTimeout(function () { el.hide(); }, 1000);
}

// Set the input, apply it (its `change` handler rotates the knob and pushes the
// value into the audio graph) and show the value.
function studioKnobSet(knob, value) {
	var input = studioKnobInput(knob);
	if (!input.length) { return; }
	value = Math.max(0, Math.min(100, value));
	input.val(value);
	input.trigger('change');
	studioKnobReadout(knob, value);
}

$(document).on('pointerdown', '.knob', function (e) {
	if (e.originalEvent.button) { return; }
	var knob = $(this);
	var input = studioKnobInput(knob);
	if (!input.length) { return; }
	studioKnobDrag = { knob: knob, y: e.originalEvent.clientY, value: studioKnobNumber(input.val(), 0) };
	knob.addClass('knob_active');
	e.preventDefault();
});

$(document).on('pointermove', function (e) {
	if (!studioKnobDrag) { return; }
	var y = e.originalEvent.clientY;
	var dy = studioKnobDrag.y - y;
	if (!dy) { return; }
	studioKnobDrag.y = y;
	studioKnobDrag.value = Math.max(0, Math.min(100, studioKnobDrag.value + (dy * 0.7)));
	studioKnobSet(studioKnobDrag.knob, studioKnobDrag.value);
	e.preventDefault();
});

$(document).on('pointerup pointercancel', function () {
	if (!studioKnobDrag) { return; }
	studioKnobDrag.knob.removeClass('knob_active');
	studioKnobDrag = null;
});

// A wheel event, normalised to the old positive-up wheelDelta scale.
function studioWheelDelta(event) {
	var d = ('deltaY' in event) ? event.deltaY : (-event.wheelDelta);
	if (event.deltaMode === 1) { d *= 16; }
	else if (event.deltaMode === 2) { d *= 100; }
	return -d;
}

// Bound natively and non-passively so preventDefault actually stops the
// pedalboard scrolling under a knob; a delegated jQuery listener on document is
// passive in Chrome and cannot cancel the scroll.
function studioWheelHandler(event) {
	var target = event.target;
	if (!target || !target.closest) { return; }

	var knob = target.closest('.knob');
	if (knob) {
		var input = studioKnobInput($(knob));
		if (input.length) {
			studioKnobSet($(knob), studioKnobNumber(input.val(), 0) + (studioWheelDelta(event) / 30));
			event.preventDefault();
		}
		return;
	}

	var vol = target.closest('.channel_volume');
	if (vol) {
		$(vol).val(numeral($(vol).val()).value() + (studioWheelDelta(event) / 30));
		studioSaver();
		event.preventDefault();
		return;
	}

	var jog = target.closest('#studio_jog_wheel');
	if (jog) {
		var diff = studioWheelDelta(event) / 30;
		studio_jw_deg = (studio_jw_deg + diff);
		$(jog).css({ 'rotate': studio_jw_deg + 'deg' });
		mixer['time']['position'] = mixer['time']['position'] + diff / 10;
		studioTime('scroll');
		event.preventDefault();
	}
}

if ('onwheel' in document) { document.addEventListener('wheel', studioWheelHandler, { passive: false }); }
else { document.addEventListener('mousewheel', studioWheelHandler, { passive: false }); }

$(document).on('change mousemove touchmove','.knob_control',function() {
	var input = $(this);
	var channel = input.attr('channel');

	var current_value = input.val();
	var control = input.attr('control');
	var knob = $('.knob[control="' + control + '"][channel="' + channel + '"]');
	var direction = knob.attr('direction');
	var flip = numeral(knob.attr('flip')).value() || 0;
	var range = numeral(knob.attr('range')).value() || .85;
	var step = numeral(input.attr('step')).value();

	var transform_value = (flip + numeral((360 / 100) * (current_value * range)).value());
	if (direction == 'counter') {
		transform_value = (flip - numeral((360 / 100) * (current_value * range)).value());
	}
	knob.css({ 'transform': 'rotate(' + transform_value + 'deg)' });
	if (/^[0-9]+$/.test(channel)) { studioApplyChannel(channel); }
	else { studioApplyPedals(); }
	studioUpdateKnobHints();
	studioSaver();
});

$(document).on('click', '.button_control', function() {
	var b = $(this);
	var control = b.attr('control');
	var colour = b.attr('colour');
	var status = b.attr('status');
	if (status == 'depressed') {
		b.attr('status', 'pressed');
		b.attr('src', jawnosStudioButtonIcon('pressed', colour));
	}
	else {
		b.attr('status', 'depressed');
		b.attr('src', jawnosStudioButtonIcon('depressed', colour));
	}
	studioSaver();
});

// (channel fader and jog wheel wheels are handled by studioWheelHandler)

$(document).on('change', '.channel_volume', function() {
	studioSaver();
});

$(document).on('click', '#studio_loop', function() {
	var sl = $(this);
	var loop = sl.attr('enabled');

	if (sl.attr('enabled') == 'ongoing') {
		loop = 'off';
		sl.attr('enabled', loop);
		sl.css({'background-color': 'rgb(211, 211, 211)' });
	}
	else if (sl.attr('enabled') == 'on') {
		loop = 'ongoing';
		sl.attr('enabled', loop);
		sl.css({'background-color': 'yellow' });
	}
	else {
		loop = 'on';
		sl.attr('obg', sl.css('background-color'));
		sl.attr('enabled', loop);
		sl.css({'background-color': 'red' });
	}
	mixer['time']['loop'] = loop
	studioSaver();
});

// The song lives in memory as well as in localStorage. studioSaver runs on
// every knob move, and a synchronous localStorage write per move janks the
// drag; so the write is deferred a moment while the in-memory copy stays
// authoritative for studioRetriever, which reads it right after a save.
var studioSongCache = null;
var studioSongWrite = 0;

function studioSongStore(song) {
	studioSongCache = song;
	clearTimeout(studioSongWrite);
	studioSongWrite = setTimeout(function () {
		try { localStorage.setItem('studio', JSON.stringify(song)); } catch (e) {}
	}, 250);
}

// A song loaded from or saved to the server wants the disk copy right away.
function studioSongSet(song) {
	studioSongCache = song;
	clearTimeout(studioSongWrite);
	try { localStorage.setItem('studio', JSON.stringify(song)); } catch (e) {}
}

function studioSaver() {
	var song = {};
	var name = $('#studio').attr('name');
	var uuid = $('#studio').attr('uuid');

	$('.knob_control, .channel_volume').each(function(i,v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		var value = $(v).val();
		if (control == 'pan') {
			value = (value - 0) / (100 - 0) * ( 1 - -1) + -1;
		}
		if (song[channel] == undefined) { song[channel] = {}; }
		if (!song[channel]['plugs']) { song[channel]['plugs'] = { input: {}, output: {} }; }
		song[channel][control] = value;
	});
	$('.armed').each(function(i,v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		if (song[channel] == undefined) { song[channel] = {}; }
		song[channel][control] = { state: $(v).attr('state'), text: $(v).text() };
	});
	$('.studio_channel_information').each(function(inf,sci) {
		var text = $(sci).text();
		if (isJson(text)) {
			var info = JSON.parse(text);
			if (song[info['channel']] == undefined) { song[info['channel']] = {}; }
			if (!song[info['channel']]['plugs']) { song[info['channel']]['plugs'] = { input: {}, output: {} }; }
			song[info['channel']]['plugs'][info['direction']] = info;
		}
	});

	// per-channel insert rack (which pedals are in the chain, in order)
	$.each(studioAudio.channels, function(ch, c) {
		if (song[ch] == undefined) { song[ch] = {}; }
		song[ch]['fx'] = c.inserts.map(function(ins) { return ins.name; });
	});

	// recorded takes: metadata only, the audio blobs are uploaded by studioSave
	$.each(mixer, function(i,v) {
		if (!/^[0-9]+$/.test(i) || !mixer[i].media || !mixer[i].media.out) { return; }
		if (song[i] == undefined) { song[i] = {}; }
		song[i]['mixer'] = { out: [] };
		mixer[i].media.out.forEach(function(take, ir) {
			if (!take) { return; }
			song[i]['mixer'].out[ir] = {
				uuid: take.uuid, startTime: take.startTime, offset: take.offset || 0,
				duration: take.duration, encoding: take.encoding, src: take.src,
				loop: take.loop ? 1 : 0
			};
		});
	});

	var sl = $('#studio_loop').attr('enabled');
	var video_toggle = $('#studio_video_toggle').attr('toggled');
	song['admin'] = { time: mixer['time'], name: name, uuid: uuid, loop: sl, video_toggle: video_toggle,
		metronome: mixer['time']['metronome'], bpm: mixer['time']['bpm'], sig: mixer['time']['sig'] };
	studioSongStore(song);
	return song;
}

function studioRetriever() {
	var song = studioSongCache || JSON.parse(localStorage.getItem('studio') || '{}');

	$.each(song, function(i,v) {
		if (i == 'admin') {
			$.each(v, function(n,w) { mixer['admin'] = mixer['admin'] || {}; mixer['admin'][n] = w; });
			return;
		}
		if (!/^[0-9]+$/.test(i)) {
			// a pedal's knobs live under its own name
			$.each(v, function(n,w) {
				if (n == 'armed' || n == 'plugs' || n == 'mixer' || n == 'fx') { return; }
				$('[channel="' + i + '"][control="' + n + '"]').val(w);
			});
			return;
		}

		if (!mixer[i]) { mixer[i] = {}; }
		if (!mixer[i].armed) { mixer[i].armed = { state: 'off', text: 'O' }; }
		$.each(v, function(n,w) {
			if (n == 'plugs' || n == 'mixer' || n == 'fx') { return; }
			mixer[i][n] = w;
			if (n == 'armed') {
				$('[channel="' + i + '"][control="armed"]').attr('state', w.state).text(w.text);
				if (w.state == 'rec') { studioInputStreamGrabber(i, 'rec'); }
				return;
			}
			if (n == 'pan') { w = (w - -1) / (1 - -1) * (100 - 0) + 0; }
			$('[channel="' + i + '"][control="' + n + '"]').val(w);
		});

		// rebuild this channel's insert rack
		var c = studioChannelEngine(i);
		if (c) {
			c.inserts.slice().forEach(function(ins) { studioSetInsert(i, ins.name, false); });
			(v['fx'] || []).forEach(function(name) { studioSetInsert(i, name, true); });
		}
		studioApplyChannel(i);
	});

	studioApplyPedals();

	var met = $('#studio_metronome');
	if (mixer['time'] && mixer['time']['metronome'] == 'yes') {
		met.attr('armed', 'yes');
		if (met.attr('obg') != 'red') { met.attr('obg', met.css('background-color')); }
		met.css({ 'background-color': 'red' });
	} else {
		met.attr('armed', 'no');
		met.css({ 'background-color': met.attr('obg') || 'rgb(211, 211, 211)' });
	}
	if (mixer['time']) {
		if (mixer['time']['bpm']) { $('#studio_bpm').val(mixer['time']['bpm']); }
		if (mixer['time']['sig']) { $('#studio_signature').val(mixer['time']['sig']); }
		if (mixer['time']['loop']) { mixer['time']['loop'] = mixer['time']['loop']; }
	}

	mixer['settings'] = mixer['settings'] || {};
	mixer['settings']['channel_count'] = $('#studio_viewer').attr('channel_count');
	studioUpdateKnobHints();
	return song;
}

var studio_jw_deg =  0;
var studio_last = 'out';
$(document).on('touchmove mousemove', '#studio_jog_wheel', function(e) {
	e.preventDefault();			e.preventDefault();
	var j = $(this);
	var jc = j.closest('.jog_wheel_frame').find('.jog_wheel_centre');
	if (e.which === 1 || e.originalEvent.type == 'touchmove') {
		var x = e.originalEvent.clientX;
		var y = e.originalEvent.clientY;
		if (e.originalEvent.targetTouches) {
			x = e.originalEvent.targetTouches[0].clientX;
			y = e.originalEvent.targetTouches[0].clientY;
		}
		var middle_x = numeral(jc.offset().left + (jc.width() / 2)).value();
		var middle_y = numeral(jc.offset().top + (jc.height() / 2)).value();
		var deltaX = middle_x - x;
		var deltaY = middle_y - y;
		var rad = Math.atan2(deltaY, deltaX); 
		var deg = rad * (180 / Math.PI) - 90;
		var diff = 0;
		if (studio_last == 'in') {
			diff = (deg - studio_jw_deg);
		}
		studio_jw_deg = (studio_jw_deg + diff);
		j.css({'rotate': studio_jw_deg + 'deg' });
		studio_last = 'in';
		mixer['time']['position'] = mixer['time']['position'] + diff / 10;
		studioTime('scroll');
	}
});
$(document).on('mouseout touchend mouseup', '#studio_jog_wheel', function() {
	studio_last = 'out';
});

// (the jog wheel's wheel is handled by studioWheelHandler)

$(document).on('click', '#studio_video_toggle', function() {
	var toggle = $(this).attr('toggled');

	if (toggle == 'on') {
		toggle = 'off';
	}
	else {
		toggle = 'on';
	}
	$(this).attr('toggled', toggle);
	studioSaver();
});

$(document).on('click', '#studio_record', function() {
	if (mixer['time']['status'] != 'record' && mixer['time']['status'] != 'play') {
		studioRecord();
		mixer['time']['status'] = 'record';
	}
});

$(document).on('click', '.armed',function() {
	var armed = $(this);
	var state = armed.attr('state');
	var channel = armed.attr('channel');
	if (state == 'off') {
		armed.attr('state', 'rec');
		armed.text('R');
	}
	else if (state == 'rec') {
		armed.attr('state', 'play');
		armed.text('P');
	}
	else if (state == 'play') {
		armed.attr('state', 'loop');
		armed.text('L');
	}
	else {
		armed.attr('state', 'off');
		armed.text('O');
	}
	studioSaver();
	state = armed.attr('state');
	// playback reads the armed state from mixer, so keep it in step with the
	// button instead of waiting for the next load
	if (!mixer[channel]) { mixer[channel] = {}; }
	mixer[channel].armed = { state: state, text: armed.text() };
	studioInputStreamGrabber(channel,state);
	studioDrawTracks();
});

$(document).on('click', '.studio_jack', function() {
	var j = $(this);
	var channel = j.attr('channel');
	channelSelect(channel,'input');
});

$(document).on('click', '.studio_cord', function() {
	var j = $(this);
	var channel = j.attr('channel');
	channelSelect(channel,'output');
});

async function channelSelect(channel,direction) {
	var sis = $('#studio_plug_select_container');
	if ($('#studio_plug_select[channel="' + channel + '"][direction="' + direction + '"]').is(':visible')) {
		sis.hide();
	} else {
		var m = mouse_position();
		var x = m.x;
		var y = m.y;

		var constraints = await constraintMaker({ video: true, audio: true });
		var options = { 'surfaceSwitching': 'include', 'audio': true, 'video': { 'displaySurface': 'monitor' }};
		var screenShare = !!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia);
		console.log(screenShare);
		console.log(constraints);
		var eligibleApps = [ 
			{ app: 'music', id: 'video', av: 'av' },
			{ app: 'marker', id: 'whiteboard', av: 'v' },
			{ app: 'synth', id: 'synthesizer', direction: 'input', av: 'a' }
		];

		var information = {};
		var sci = $('.studio_channel_information[direction="' + direction + '"][channel="' + channel + '"]');
		if (isJson(sci.text())) {
			information = JSON.parse(sci.text());
		}

		var data = { 
			channel: channel, 
			constraints: JSON.stringify(constraints),
			screenShare: screenShare,
			mouse: m,
			apps: JSON.stringify(eligibleApps),
			direction: direction,
			information: information
		};
		console.log(data);	
		$.ajax({
			url: '/manager/studio/plug/select',
			type: 'GET',
			data: data,
			success: function(response) {
				sis.html(response.html).show();
				sis.css({ 'left': (x + 20), 'top': y, 'right': '', 'bottom': '', 'width': '', 'height': '' });
				var width = sis.width();
				if (numeral(sis.css('right')).value() < 0 || sis.width() < 200) {
					sis.css({ 'right': (($(window).width() - x) + 20), 'left': '' });
				}
				if (numeral(sis.css('bottom')).value() < 0) {
					sis.css({ 'bottom': (($(window).height() - y) + 20), 'top': '' });
				}

				appointment_chron();
			}
		});
	}
}

$(document).on('click', '.close_plug_select', function() {
	var sis = $('#studio_plug_select_container');
	sis.hide();
});

$(document).on('click', '.studio_plug_selection', function() {
	var sis = $(this);
	var channel = sis.attr('channel');
	var direction = sis.attr('direction');
	var id = sis.attr('sid');
	var type = sis.attr('type');
	var av = sis.attr('av');
	var app = sis.attr('app');
	$('.studio_plug_selection[direction="' + direction + '"][channel="' + channel + '"]').removeClass('active_background');
	var data = {
		channel: channel,
		direction: direction,
		id: id,
		type: type,
		av: av,
		app: app
	}
	console.log(data);
	var jinfo = JSON.stringify(data);


	$('.studio_channel_information[direction="' + direction + '"][channel="' + channel + '"]').text(jinfo);
	var chosen = $('.studio_plug_selection[direction="' + direction + '"][channel="' + channel + '"][type="' + type + '"][sid="' + id + '"][av="' + av + '"][app="' + app + '"]');
	console.log('length ' + chosen.length);
	chosen.addClass('active_background');
	studioInputStreamGrabber(channel,'off')
	studioSaver();
	studioRetriever();
});

async function studioInputStreamGrabber(channel,state) {
	var ch = channel;
	if (!mixer[ch]) { mixer[ch] = {}; }
	if (!mixer[ch].media) { mixer[ch].media = {}; }
	if (!mixer[ch].media.out) { mixer[ch].media.out = []; }
	if (!mixer[ch].media.rec) { mixer[ch].media.rec = []; }

	// An armed channel keeps its input open for rec *and* loop: loop is the
	// looper state, so it has to be able to capture the sample it repeats.
	if (state != 'rec' && state != 'loop') {
		if (mixer[ch].media.inRaw) {
			mixer[ch].media.inRaw.getTracks().forEach(function(track) { track.stop(); });
		}
		mixer[ch].media.inRaw = undefined;
		mixer[ch].media.in = null;
		mixer[ch].media.active = false;
		studioDetachInput(ch);
		clearInterval(mixer[ch].media.in_analyzer_timeout);
		$('#studio_video_monitor_' + ch).hide();
		return;
	}

	if (mixer[ch].media.active) { return; }

	// If the channel has an input plug selected, honour its audio/video kind, but
	// default to audio only: the camera is requested only when the plug is a
	// video source ('av' = a camera or video app, 'v' = the marker). Nothing
	// chosen means no camera.
	var info = $('.studio_channel_information[direction="input"][channel="' + ch + '"]');
	var plug = isJson(info.text()) ? JSON.parse(info.text()) : {};
	var video = (plug['av'] == 'av' || plug['av'] == 'v');

	var audio = {
		echoCancellation: false,  // Disables echo suppression
		noiseSuppression: false,  // Disables background noise dampening
		autoGainControl: false   // Prevents the browser from auto-adjusting volume
	};
	var sample_rate = studioSampleRate();
	if (sample_rate > 0) { audio.sampleRate = sample_rate; }
	var channels = studioSettingNumber('audio_channels', 0);
	if (channels > 0) { audio.channelCount = channels; }

	var constraints = { audio: audio };
	if (video) {
		// 320p up to the device maximum, with an optional frame-rate cap
		var height = studioSettingNumber('video_height', 0);
		var fps = studioSettingNumber('video_fps', 0);
		if (height > 0 || fps > 0) {
			constraints['video'] = {};
			if (height > 0) { constraints['video'].height = { ideal: Math.round(height) }; }
			if (fps > 0) { constraints['video'].frameRate = { ideal: Math.round(fps) }; }
		}
		else { constraints['video'] = true; }
	}

	var stream;
	try {
		stream = await navigator.mediaDevices.getUserMedia(constraints);
	} catch (e) {
		console.log('studio: could not open input for channel ' + ch, e);
		mixer[ch].media.active = false;
		return;
	}

	mixer[ch].media.inRaw = stream;
	mixer[ch].media.active = true;

	// The browser's own latency report for this input; it feeds the record
	// offset so overdubs land on the grid without a manual trim.
	var in_track = stream.getAudioTracks()[0];
	if (in_track && in_track.getSettings) {
		var in_latency = numeral(in_track.getSettings().latency).value();
		if (in_latency > 0) { mixer[ch].media.latency = in_latency; }
	}
	studioUpdateLatencyInfo();

	// Push the raw input through the channel's tone stack + pedals and take the
	// processed result as our recording source.
	var processed = studioAttachInput(ch, stream);
	var combined = new MediaStream();
	if (processed) { combined.addTrack(processed.getAudioTracks()[0]); }
	if (stream.getVideoTracks()[0]) { combined.addTrack(stream.getVideoTracks()[0]); }
	mixer[ch].media.in = combined;
	mixer[ch].media.video = !!stream.getVideoTracks()[0];

	clearInterval(mixer[ch].media.in_analyzer_timeout);
	mixer[ch].media.in_analyzer_timeout = setInterval(function() {
		// metres are only worth drawing when they can be seen
		if (document.hidden) { return; }
		studioDrawChannel(ch);
		studioDrawMetre(ch);
	}, 40);

	var monitor = document.getElementById('studio_video_monitor_' + ch);
	if (monitor) {
		monitor.srcObject = combined;
		monitor.muted = true;
		if (mixer[ch].media.video) { $(monitor).show(); }
	}
	return combined;
}

function studioStartTake(ch, looping, at) {
	var media = mixer[ch] && mixer[ch].media;
	if (!media || !media.in) {
		console.log('studio: channel ' + ch + ' is armed to record but has no input');
		return;
	}
	if (!media.out) { media.out = []; }
	if (!media.rec) { media.rec = []; }
	var ir = media.out.length;

	var el = document.createElement('video');
	el.className = 'studio_video';
	el.id = 'studio_channel_' + ch + '_' + ir;
	el.style.display = 'none';
	el.preload = 'auto';
	$('#studio_track_container').append(el);

	// Latency skew pulls a fresh take earlier so it lines up with what was
	// already playing. Negative positions are kept on purpose: clamping to zero
	// is what used to leave every overdub recorded from the top late by the
	// monitoring latency. `at` is the punch-in point when a count-in ran.
	var from = (at === undefined || at === null) ? mixer['time']['position'] : at;
	var latency = studioRecordOffset(ch);
	var take = { startTime: from - latency, latency: latency, offset: 0, duration: 0, status: 'recording', track: el, loop: !!looping, region: looping ? studioLoopRegion() : null };
	media.out[ir] = take;

	var mime = studioPickMime(!!media.video);
	var options = {};
	if (mime) { options.mimeType = mime; }
	var kbps = studioSettingNumber('audio_kbps', 256);
	if (kbps > 0) { options.audioBitsPerSecond = Math.max(6, Math.min(510, Math.round(kbps))) * 1000; }
	var mbps = studioSettingNumber('video_mbps', 0);
	if (media.video && mbps > 0) { options.videoBitsPerSecond = Math.round(mbps * 1000) * 1000; }
	var recorder;
	try {
		recorder = new MediaRecorder(media.in, options);
	} catch (e) {
		console.log('studio: MediaRecorder could not start', e);
		return;
	}
	recorder.ondataavailable = function(event) {
		if (!event.data || !event.data.size) { return; }
		take.data = event.data;
		take.encoding = event.data.type;
		take.status = 'stop';
		if (take.src) { try { URL.revokeObjectURL(take.src); } catch (e) {} }
		take.src = URL.createObjectURL(event.data);
		take.track.src = take.src;
		studioTakeRequestBuffer(take);
	};
	media.rec[ir] = recorder;
	recorder.start();
	console.log('studio: recording channel ' + ch + ' take ' + ir + ' at ' + take.startTime.toFixed(3) + 's');
}

function studioStopTake(ch, ir) {
	var media = mixer[ch] && mixer[ch].media;
	if (!media) { return; }
	var take = media.out && media.out[ir];
	var recorder = media.rec && media.rec[ir];
	if (recorder && recorder.state && recorder.state != 'inactive') { recorder.stop(); }
	if (take && take.status == 'recording') {
		take.status = 'stop';
		if (take.loop) {
			// repeats are grid-locked, so they never drift off the beat
			take.duration = studioLoopTakeDuration(take);
		}
		else {
			take.duration = Math.max(0, mixer['time']['position'] - take.startTime);
		}
		mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + take.duration);
	}
	if (media.rec) { media.rec[ir] = null; }
}

// Start the takes held back by a count-in, once the transport reaches the
// punch-in point. The takes are anchored to that point, not to the tick that
// notices it, so a loop still starts exactly on the bar line.
function studioStartPendingTakes() {
	var punch = mixer['time']['punch_in'];
	if (punch === undefined || punch === null) { return; }
	if (mixer['time']['position'] < punch) { return; }
	var pending = mixer['time']['pending_takes'] || [];
	mixer['time']['punch_in'] = null;
	mixer['time']['pending_takes'] = null;
	$.each(pending, function (n, a) {
		if (!mixer[a.ch]) { mixer[a.ch] = {}; }
		if (!mixer[a.ch].media) { mixer[a.ch].media = {}; }
		studioStartTake(a.ch, a.loop, punch);
	});
}

async function studioRecord() {
	if (mixer['time']['status'] == 'record') { return; }

	var song = studioSaver();
	var takes = [];
	var loop_armed = false;
	$.each(song, function(i,v) {
		var arm = v['armed'] && v['armed']['state'];
		if (!/^[0-9]+$/.test(i) || (arm != 'rec' && arm != 'loop')) { return; }
		if (arm == 'loop') { loop_armed = true; }
		takes.push({ ch: i, loop: arm == 'loop' });
	});

	// Where recording begins. Loop takes reserve a region: it starts on the
	// grid the Start on setting asks for (bar, beat, or the playhead itself)
	// and runs for the configured number of bars, so the phrase and its repeats
	// stay on the beat grid.
	var unit = studioSnapUnit();
	var punch = mixer['time']['position'];
	if (unit > 0) { punch = Math.floor(punch / unit) * unit; }
	if (loop_armed) {
		var bars = studioLoopBars();
		if (bars > 0) { mixer['time']['loop_region'] = { start: punch, bars: bars }; }
		else { mixer['time']['loop_region'] = null; }
	}

	mixer['time']['status'] = 'record';
	mixer['time']['punch_in'] = null;
	mixer['time']['pending_takes'] = null;
	mixer['time']['position'] = punch;

	// A count-in runs the transport up to the punch-in point with clicks; the
	// takes are held back until it gets there.
	var count_in = studioCountInBeats() * studioBeatSeconds();
	if (count_in > 0) {
		mixer['time']['position'] = punch - count_in;
		mixer['time']['punch_in'] = punch;
		mixer['time']['pending_takes'] = takes;
	}
	studioTime('start');

	if (count_in <= 0) {
		$.each(takes, function(n, a) {
			if (!mixer[a.ch]) { mixer[a.ch] = {}; }
			if (!mixer[a.ch].media) { mixer[a.ch].media = {}; }
			studioStartTake(a.ch, a.loop, punch);
		});
	}
	studioSyncTakes();
}

$(document).on('click', '#studio_play', function() {
	if (mixer['time']['status'] != 'record' && mixer['time']['status'] != 'play') {
		studioPlay('play');
		mixer['time']['status'] = 'play';
	}
});

async function studioPlay(mode) {
	mixer['time']['status'] = (mode == 'rec') ? 'record' : 'play';
	if (mode != 'rec') { studioTime('start'); }
	studioSyncTakes();
}

$(document).on('click', '#studio_stop', function() {
	studioStop();
	mixer['time']['status'] = 'stop';
});

async function studioStop() {
	var wasRecording = (mixer['time']['status'] == 'record');
	// a stop during the count-in cancels the take that never started
	mixer['time']['punch_in'] = null;
	mixer['time']['pending_takes'] = null;
	studioFlushSources();
	studioAudio.playSeg = null;
	studioAudio.schedSeg = null;
	studioAudio.clickSeg = null;

	$.each(mixer, function(i,v) {
		if (!/^[0-9]+$/.test(i) || !mixer[i].media) { return; }
		if (wasRecording && mixer[i].media.rec) {
			$.each(mixer[i].media.rec, function(ir) { studioStopTake(i, ir); });
		}
		if (mixer[i].media.out) {
			mixer[i].media.out.forEach(function(take) {
				if (take && take.track && !take.track.paused) { take.track.pause(); }
			});
		}
	});

	if (mixer['time']['status'] == 'stop') { mixer['time']['position'] = 0; }
	studioTime('stop');
	mixer['time']['status'] = 'stop';
}

function studioTime(command) {
	var svm = document.getElementById('studio_video_monitor');
	if (svm) { $(svm).show(); }

	if (command == 'start') {
		mixer['time']['lastMetronome'] = null;
		mixer['time']['startTime'] = Date.now() - (mixer['time']['position'] * 1000);
		// the transport runs on the AudioContext clock; takes and clicks are
		// placed a little ahead of now so timer jitter never reaches the ear
		studioClockStart(mixer['time']['position']);
		clearInterval(mixer['time']['interval']);
		mixer['time']['interval'] = setInterval(studioTransportTick, 25);
		studioTransportTick();
	}
	else if (command == 'stop') {
		clearInterval(mixer['time']['interval']);
		mixer['time']['interval'] = 0;
		studioTimeDisplay();
	}
	else {
		studioTimeDisplay();
		studioDrawTracks();
	}

	if (!mixer['time']['status']) { mixer['time']['status'] = 'stop'; }
	var button = $('#studio_' + mixer['time']['status'] );

	$.each(mixer['buttons'], function(i,v) {
		clearInterval(v['interval']);
		$('#studio_' + i).css({'background-color': v.obg });
	});
	mixer['buttons'][mixer['time']['status']]['interval'] = setInterval(function() {
		button.css({'background-color': mixer['buttons'][mixer['time']['status']]['bg'] });
		var obg = mixer['buttons'][mixer['time']['status']]['obg'];

		setTimeout(function() {
			button.css({'background-color': obg });

		},500);
	},1000);
}

// Loop takes finish themselves at the end of their region — a hair late, so
// the phrase's tail (which the player heard and answered late) is still
// captured — then start repeating on the spot. When nothing else is still
// recording, the transport drops out of record and keeps playing the loop.
function studioLoopPunchOut() {
	var pos = mixer['time']['position'];
	var stopped = false;
	var pending = false;
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m.media || !m.media.out) { return; }
		m.media.out.forEach(function (take, ir) {
			if (!take || take.status != 'recording') { return; }
			if (!take.region || !(take.region.end > 0) || pos < take.region.end + (take.latency || 0)) {
				pending = true;
				return;
			}
			studioStopTake(ch, ir);
			stopped = true;
		});
	});
	if (!stopped || pending || mixer['time']['status'] != 'record') { return; }
	mixer['time']['status'] = 'play';
	// the record transport ran straight through; re-anchor it on the play
	// timeline so the committed region now repeats
	studioClockStart(mixer['time']['position']);
	studioTime('play');
}

function studioTransportTick() {
	var status = mixer['time']['status'];

	if (status == 'play' || status == 'record') {
		studioClockAdvance();
		if (mixer['time']['status'] == 'stop') {
			studioTimeDisplay();
			studioDrawTracks();
			return;
		}
		// everything that will be heard in the next lookahead window is placed
		// on the audio clock here, so the click and the takes share one clock
		studioScheduleTick();
	}

	var end = mixer['time']['duration'] || 0;
	if (mixer['time']['status'] == 'record') {
		if (mixer['time']['position'] > end) {
			mixer['time']['duration'] = mixer['time']['position'];
			$('#studio_time_duration').html(numeral(mixer['time']['duration']).format('00.000'));
		}
		studioLoopPunchOut();
		studioStartPendingTakes();
	}

	studioTimeDisplay();
	studioSyncTakes();
	studioDrawTracks();
}

function studioTimeDisplay() {
	var bpm = studioKnobNumber(mixer['time']['bpm'], 120) || 120;
	var asdf = bpm / 60;
	var time = mixer['time']['position'];
	var tick = Math.floor(time * asdf);
	if (!mixer['time']['sig']) {
		mixer['time']['sig'] = $('#studio_signature').val() || '4/4';
	}
	var tsig = String(mixer['time']['sig']).split('/');
	var beats = studioKnobNumber(tsig[0], 4) || 4;
	mixer['time']['beat'] = tick;
	mixer['time']['bar'] = Math.floor(tick / beats);
	var beat = mixer['time']['beat'] - (mixer['time']['bar'] * beats) + 1;

	if (mixer['time']['display'] == 'beats') {
		$('#studio_time_display').html(numeral(mixer['time']['position']).format('00.000'));
	} else {
		$('#studio_time_display').html(mixer['time']['bar'] + ':' + beat);
	}
	return {
		beat: tick,
		bar: mixer['time']['bar'],
		signature: tsig
	};
}

$(document).on('click', '#studio_time_display', function() {
	if (mixer['time']['display'] == 'beats') {
		mixer['time']['display'] = 'time';
	} else {
		mixer['time']['display'] = 'beats';
	}
});

$(document).on('click', '#studio_metronome', function() {
	var met = $(this);
	if (met.attr('armed') == 'yes') {
		met.attr('armed','no');
		met.css({'background-color': 'rgb(211, 211, 211)' });
	}
	else {
		met.attr('armed', 'yes');
		met.attr('obg', met.css('background-color'));
		met.css({'background-color': 'red'});
	}
	mixer['time']['metronome'] = met.attr('armed');
});

$(document).on('change', '#studio_bpm', function() {
	var bpm = $(this).val();
	if (bpm > 240) {
		bpm = 240;
		$(this).val(bpm);
	} else if (bpm < 30) {
		bpm = 30;
		$(this).val(bpm);
	}
	mixer['time']['bpm'] = bpm;
});

$(document).on('click', '#studio_bpm', function() {
	var timestamp = Date.now();
	var lastClick = numeral($(this).attr('last_click')).value();
	var diff = numeral(timestamp - lastClick).value() / 1000;
	var bpm = 60 / diff;
	bpm = bpm.toFixed(2);
	$(this).attr('last_click', timestamp);

	if (bpm > 30 && bpm < 240) {

		$('#studio_bpm').val(bpm).trigger('change');
	}
});

$(document).on('change', '#studio_signature', function() {
	var sig = $(this).val();
	if (!sig || sig == "") {
		sig = '4/4';
	}
	var tsig = sig.split('/');
	if (!tsig[1]) {
		sig = tsig[0] + '/4';
	}

	$(this).val(sig);
	mixer['time']['sig'] = sig;
});

$(document).on('click', '#studio_save', function() {
	studioSave();
});




function studioSave() {
	var app = 'studio';
	var now = Date.now();
	var name = $('#studio').attr('name');
	var uuid = $('#studio').attr('uuid');
	if (!name) {
		$('#studio_name').attr('type','text').focus();
		return;
	}

	var song = studioSaver();
	var formData = new FormData();
	formData.append('app', name);
	formData.append('name', name);
	formData.append('duration', mixer['time']['duration']);
	formData.append('timestamp', now);
	formData.append('type', 'studio');
	formData.append('uuid', uuid);

	// Only freshly recorded takes (those without a server uuid yet) are
	// uploaded, so re-saving a loaded song never duplicates its files.
	var uploads = 0;
	$.each(mixer, function(i,v) {
		if (!/^[0-9]+$/.test(i) || !mixer[i].media || !mixer[i].media.out) { return; }
		mixer[i].media.out.forEach(function(take, ir) {
			if (take && take.data && take.data.size && !take.uuid) {
				formData.append('blob', take.data, app + '_' + now + '_' + i + '_' + ir + '.webm');
				uploads++;
			}
		});
	});
	console.log('studio: saving ' + uploads + ' take(s)');

	formData.append('studio', JSON.stringify(song));
	$.ajax({
		url: '/manager/studio/save',
		type: 'POST',
		data: formData,
		success: function (response) {
			$('#studio').attr('uuid', response.uuid);
			$('#studio').attr('name', response.app);
			// adopt the uuids the server assigned to the takes we just uploaded
			$.each(response.studio || {}, function(i, v) {
				if (!/^[0-9]+$/.test(i) || !v.mixer || !v.mixer.out) { return; }
				if (!mixer[i] || !mixer[i].media || !mixer[i].media.out) { return; }
				v.mixer.out.forEach(function(take, ir) {
					if (take && take.uuid && mixer[i].media.out[ir]) {
						mixer[i].media.out[ir].uuid = take.uuid;
					}
				});
			});
			studioSongSet(response.studio);
			continent_record({'uuid':response['uuid'], 'app':response['app'],'timestamp':response['timestamp']});
			$('#studio_song_select').replaceWith(response.song_select);
			appointment_chron();
		},
		cache: false,
		contentType: false,
		processData: false
	});
}

$(document).on('click', '#studio_delete', function() {
	var a = $(this);
	var uuid = mixer['admin']['uuid'];
	var app = mixer['admin']['name'];
	var armed = a.attr('armed');
	console.log(uuid);
	if (armed == 'yes') {
		console.log(app + ' ' + uuid);
		$.ajax({
			url: '/manager/studio/delete',
			type: 'POST',
			data: { uuid: uuid, app: app },
			success: function(response) {
				studioInit();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change', '#studio_song_select', function() {
	var uuid = $(this).val();
	if (uuid != 'none') {
		studioLoad(uuid);
	}
});
function studioLoad(uuid) {
	var buttons = mixer['buttons'];
	studioStop();
	$.ajax({ 
		url: '/manager/studio/load',
		type: 'GET',
		data: { uuid: uuid },
		success: function(response) {
			var admin = response.studio['admin'] || {};
			$('#studio_song_select').val(response['uuid']);
			mixer['time'] = admin['time'] || mixer['time'];
			mixer['time']['metronome'] = admin['metronome'] || 'no';
			mixer['time']['bpm'] = admin['bpm'] || 120;
			mixer['time']['sig'] = admin['sig'] || '4/4';
			mixer['time']['status'] = 'stop';
			$('#studio_signature').val(mixer['time']['sig']);
			$('#studio_bpm').val(mixer['time']['bpm']);
			mixer['admin'] = mixer['admin'] || {};
			mixer['admin']['video_toggle'] = admin['video_toggle'];
			$('#studio_video_toggle').attr('toggled', admin['video_toggle']);
			$('.studio_config[setting="record_offset"]').val(mixer['time']['record_offset'] || '');
			$('.studio_config[setting="crossfade"]').val(mixer['time']['crossfade'] || '');
			$('.studio_config[setting="loop_bars"]').val(mixer['time']['loop_bars'] === undefined ? 4 : mixer['time']['loop_bars']);
			$('.studio_config[setting="count_in"]').val(mixer['time']['count_in'] || '');
			$('.studio_config[setting="snap"]').val(mixer['time']['snap'] || 'bar');
			$('.studio_config[setting="monitor"]').val(mixer['time']['monitor'] || 'no');
			studioApplyMonitor();
			studioUpdateLatencyInfo();
			if (mixer['time']['loop'] == 'on') {
				$('#studio_loop').attr('enabled','on').attr('obg', 'rgb(211, 211, 211)').css({'background-color':'red'});
			}
			else if (mixer['time']['loop'] == 'ongoing') {
				$('#studio_loop').attr('enabled','ongoing').attr('obg', 'rgb(211, 211, 211)').css({'background-color':'yellow'});
			}
			else {
				$('#studio_loop').attr('enabled', 'off').css({'background-color':'rgb(211, 211, 211)'});
			}
			$('#studio').attr('name', response['app']);
			$('#studio').attr('uuid', response['uuid']);

			mixer['time']['duration'] = studioKnobNumber(response.song && response.song.duration, 0) || 0;

			// Rebuild each channel's takes from the saved metadata so they play
			// back and can be re-saved.
			$.each(response.studio, function(i,v) {
				if (!/^[0-9]+$/.test(i) || !v['mixer'] || !v['mixer']['out']) { return; }
				if (!mixer[i]) { mixer[i] = {}; }
				if (!mixer[i].media) { mixer[i].media = {}; }
				mixer[i].media.out = [];
				mixer[i].media.rec = [];
				$.each(v['mixer']['out'], function(ir, vr) {
					if (!vr) { return; }
					var id = 'studio_channel_' + i + '_' + ir;
					$('#' + id).remove();
					var el = document.createElement('video');
					el.className = 'studio_video';
					el.id = id;
					el.style.display = 'none';
					el.preload = 'auto';
					if (vr['src']) { el.src = vr['src']; }
					$('#studio_track_container').append(el);
					var startTime = studioKnobNumber(vr['startTime'], 0);
					var duration = studioKnobNumber(vr['duration'], 0);
					mixer[i].media.out[ir] = {
						uuid: vr['uuid'], startTime: startTime, offset: studioKnobNumber(vr['offset'], 0),
						duration: duration, encoding: vr['encoding'], src: vr['src'], status: 'stop', track: el,
						loop: vr['loop'] ? true : false
					};
					studioTakeRequestBuffer(mixer[i].media.out[ir]);
					mixer['time']['duration'] = Math.max(mixer['time']['duration'], startTime + duration);
				});
			});

			studioSongSet(response.studio);
			studioRetriever();
			mixer['buttons'] = buttons;
			studioTimeDisplay();
			studioDrawTracks();
		}
	});
}

function studioImport(files) {
	// Bring audio/video files in as takes on the selected channel.
	var ch = studioSelectedChannel;
	if (!mixer[ch]) { mixer[ch] = {}; }
	if (!mixer[ch].media) { mixer[ch].media = {}; }
	if (!mixer[ch].media.out) { mixer[ch].media.out = []; }
	$.each(files, function(i, file) {
		var ir = mixer[ch].media.out.length;
		var id = 'studio_channel_' + ch + '_' + ir;
		var el = document.createElement('video');
		el.className = 'studio_video';
		el.id = id;
		el.style.display = 'none';
		el.preload = 'auto';
		el.src = URL.createObjectURL(file);
		$('#studio_track_container').append(el);
		var take = { uuid: null, startTime: mixer['time']['position'] || 0, offset: 0, duration: 0, status: 'stop', track: el, data: file, encoding: file.type };
		el.addEventListener('loadedmetadata', function() {
			take.duration = el.duration || 0;
			mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + take.duration);
			studioDrawTracks();
		});
		mixer[ch].media.out[ir] = take;
		studioTakeRequestBuffer(take);
	});
	studioDrawTracks();
	studioTakesChanged();
}

$(document).on('change', '#studio_name', function() {
	$('#studio').attr('name', $(this).val());
	$('#studio_name').hide();
});

$(document).on('blur', '#studio_name', function() {
	$('#studio_name').hide();
});

$(document).on('click', '#studio_mark', function() {
	var seen = undefined;
	for (n = 0; n <= mixer['time']['marks'].length; n++) {
		if (mixer['time']['position'] == mixer['time']['marks'][n]) {
			seen = n;
		}
	}
	if (seen == undefined) {
		mixer['time']['marks'].push(mixer['time']['position']);
		mixer['time']['marks'] = mixer['time']['marks'].sort(function(a,b) {
			return a - b;
		});
	}
	else {
		mixer['time']['marks'].splice(seen,1);
	}
});

$(document).on('click', '#studio_prev, #studio_next', function() {
	var potentialPosition = 0;
	if ($(this).hasClass('prev')) {
		for (var n = 0; n <= mixer['time']['marks'].length; n++) {
			if (mixer['time']['position'] > mixer['time']['marks'][n]) {
				potentialPosition = mixer['time']['marks'][n];
			}
		}
	}
	else {
		potentialPosition = mixer['time']['duration'];
		for (var n = mixer['time']['marks'].length; n >= 0; n--) {
			if (mixer['time']['position'] < mixer['time']['marks'][n]) {
				potentialPosition = mixer['time']['marks'][n];
			}
		}
	}
	mixer['time']['position'] = potentialPosition;
	studioTimeDisplay()
});

$(document).on('click', '#studio_config_toggle', function() {
	var config = $('#studio_config');
	var controls = $('#studio_controls');
	var mixer = $('#studio_mixer');
	if (config.is(':visible')) {
		config.hide();
		controls.show();
		mixer.show();
	} else {
		config.show();
		controls.hide();
		mixer.hide();
		studioUpdateLatencyInfo();
	}
});

$(document).on('change', '.studio_config', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var restart = $(this).attr('restart');
	if (setting == 'record_offset') {
		mixer['time']['record_offset'] = value;
		studioSaver();
		studioUpdateLatencyInfo();
		return;
	}
	if (setting == 'crossfade') {
		mixer['time']['crossfade'] = value;
		studioSaver();
		studioDrawTracks();
		studioTakesChanged();
		return;
	}
	if (setting == 'loop_bars') {
		mixer['time']['loop_bars'] = value;
		// no reserved bars: loop takes still snap their length to whole bars
		if (!(studioKnobNumber(value, 0) > 0)) { mixer['time']['loop_region'] = null; }
		studioSaver();
		studioDrawTracks();
		return;
	}
	if (setting == 'count_in') {
		mixer['time']['count_in'] = value;
		studioSaver();
		return;
	}
	if (setting == 'snap') {
		mixer['time']['snap'] = value;
		studioSaver();
		studioDrawTracks();
		return;
	}
	if (setting == 'sample_rate') {
		// the audio context is built with one fixed rate, so it has to be rebuilt
		mixer['settings'] = mixer['settings'] || {};
		mixer['settings'][setting] = value;
		studioFlushSources();
		if (studioAudio.ctx) { try { studioAudio.ctx.close(); } catch (e) {} }
		studioAudio = { ctx: null, master: null, masterAnalyser: null, channels: {}, sources: [], lookahead: 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
		setTimeout(function() {
			studioInit({ 'settings': [{ 'setting': setting, 'value': value }] });
		}, 500);
		return;
	}
	if (setting == 'video_height' || setting == 'video_fps' || setting == 'video_mbps' ||
		setting == 'audio_kbps' || setting == 'audio_channels') {
		mixer['settings'] = mixer['settings'] || {};
		mixer['settings'][setting] = value;
		if (String(value).length > 0) { studioSaveSettings([{ 'setting': setting, 'value': value }]); }
		studioApplyCapture();
		return;
	}
	if (setting == 'monitor') {
		mixer['time']['monitor'] = value;
		studioApplyMonitor();
		studioSaver();
		return;
	}
	if (restart == 'yes') {
		setTimeout(function() {
			studioInit({ 'settings': [{ 'setting': setting, 'value': value }] });
		},500);
	} else {
		mixer['settings'][setting] = value;
		studioRetriever();
	}
});
