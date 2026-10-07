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
//   take element -> takeGain -> takePan -> master -> speakers
//
// Takes are captured *after* the inserts, so pedals are printed into the
// recording (a guitar tracks through its pedals). Playback runs through the
// channel volume/pan only, so nothing is processed twice. The live input is
// never routed to the speakers, which keeps monitoring from feeding back.

var studioAudio = { ctx: null, master: null, masterAnalyser: null, channels: {} };
var studioSelectedChannel = 1;

function studioContext() {
	if (!studioAudio.ctx) {
		var Ctor = window.AudioContext || window.webkitAudioContext;
		if (!Ctor) { return null; }
		var ctx = new Ctor({ latencyHint: 'interactive' });
		studioAudio.ctx = ctx;
		studioAudio.master = ctx.createGain();
		studioAudio.masterAnalyser = ctx.createAnalyser();
		studioAudio.masterAnalyser.fftSize = 2048;
		studioAudio.master.connect(studioAudio.masterAnalyser);
		studioAudio.masterAnalyser.connect(ctx.destination);
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
		inserts: [],
		insertByName: {},
		source: null
	};
	c.bass.type = 'lowshelf'; c.bass.frequency.value = 220;
	c.mid.type = 'peaking'; c.mid.frequency.value = 1000; c.mid.Q.value = 1;
	c.treble.type = 'highshelf'; c.treble.frequency.value = 3500;
	c.recAnalyser.fftSize = 2048;
	c.recData = new Float32Array(c.recAnalyser.fftSize);
	c.trim.connect(c.bass).connect(c.mid).connect(c.treble);
	c.recGain.connect(c.recAnalyser);
	c.recGain.connect(c.recDest);
	// takes play through the channel fader + pan into the master bus
	c.playBus.connect(c.playPan).connect(studioAudio.master);
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

// Keep every take aligned to the transport. A take maps timeline position to
// its own source time as  source = (position - startTime) + offset, where
// `offset` is the in-point after any left trim or split. Where a clip meets a
// neighbour (butted or overlapping) each side ramps over half the crossfade
// length into the other's territory, so the two gains sum to about one.
function studioSyncTakes() {
	var pos = mixer['time']['position'];
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m.media || !m.media.out) { return; }
		var armed = m.armed && (m.armed.state == 'rec' || m.armed.state == 'play' || m.armed.state == 'loop');
		if (!armed) { return; }

		var c = studioAudio.channels[ch];
		if (c) {
			c.playBus.gain.value = studioVolumeFraction($('.channel_volume[channel="' + ch + '"]').val());
			c.playPan.pan.value = (studioKnobNumber($('.knob_control[channel="' + ch + '"][control="pan"]').val(), 50) - 50) / 50;
		}

		var xf = studioCrossfade();
		var ordered = studioChannelTakes(ch);
		ordered.forEach(function (take, i) {
			var el = take.track;
			if (!el || !el.src) { return; }
			var offset = take.offset || 0;
			var start = take.startTime;
			var end = start + (take.duration || 0);
			var prev = ordered[i - 1];
			var next = ordered[i + 1];

			var fIn = 0, fOut = 0;
			if (prev) {
				var fi = Math.min(xf, prev.duration || 0, take.duration || 0) / 2;
				if (fi > 0 && prev.src !== take.src && Math.abs(start - (prev.startTime + (prev.duration || 0))) <= fi * 2) { fIn = fi; }
			}
			if (next) {
				var fo = Math.min(xf, take.duration || 0, next.duration || 0) / 2;
				if (fo > 0 && next.src !== take.src && Math.abs(next.startTime - end) <= fo * 2) { fOut = fo; }
			}

			var winStart = start - fIn;
			var winEnd = end + fOut;
			var routed = !!studioTakeNode(ch, take);
			if (!routed) { el.volume = studioVolumeFraction($('.channel_volume[channel="' + ch + '"]').val()); }

			if (pos < winStart || pos >= winEnd) {
				if (!el.paused) { try { el.pause(); } catch (e) {} }
				var reset = offset - fIn;
				if (reset < 0) { reset = 0; }
				if (el.currentTime != reset) { try { el.currentTime = reset; } catch (e) {} }
				if (take.playGain) { take.playGain.gain.value = 0; }
				return;
			}

			var g = 1;
			if (fIn > 0) { g *= Math.max(0, Math.min(1, (pos - winStart) / (2 * fIn))); }
			if (fOut > 0) { g *= Math.max(0, Math.min(1, (winEnd - pos) / (2 * fOut))); }
			if (take.playGain) { take.playGain.gain.value = g; }

			var target = pos - start + offset;
			if (target < 0) { target = 0; }
			if (mixer['time']['status'] == 'scroll') { try { el.currentTime = target; } catch (e) {} return; }
			if (el.paused) {
				try { el.currentTime = target; } catch (e) {}
				var p = el.play();
				if (p && p.catch) { p.catch(function () {}); }
			}
			else if (Math.abs(el.currentTime - target) > 0.3) {
				try { el.currentTime = target; } catch (e) {}
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
		});
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

// How far to pull a freshly recorded take back in time to cancel input latency.
// An explicit record_offset (ms) in the song admin wins; otherwise use the
// AudioContext's reported latencies.
function studioRecordOffset() {
	var raw = mixer['time']['record_offset'];
	if (raw !== undefined && raw !== null && String(raw).length > 0) {
		var n = numeral(raw).value();
		if (n !== null && n !== undefined && !isNaN(n)) { return n / 1000; }
	}
	var ctx = studioAudio.ctx;
	if (!ctx) { return 0; }
	return (ctx.baseLatency || 0) + (ctx.outputLatency || 0);
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
	// A saved clip already has a server file, so both halves reference it. An
	// unsaved clip has to carry its blob so both halves get uploaded.
	if (!take.uuid) { right.data = take.data; }

	var el = document.createElement('video');
	el.className = 'studio_video';
	el.style.display = 'none';
	if (take.src) { el.src = take.src; }
	$('#studio_track_container').append(el);
	right.track = el;

	take.duration = t - take.startTime;
	media.out.splice(index + 1, 0, right);
	studioReindexTakes(ch);
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
		var maxDur = (take.track && isFinite(take.track.duration)) ? (take.track.duration - (take.offset || 0)) : Infinity;
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

$(document).on('click', '.pedal_background', function () {
	var name = $(this).attr('hint');
	if (!name) { return; }
	var ch = studioSelectedChannel;
	var c = studioAudio.channels[ch];
	var on = !(c && c.insertByName[name]);
	studioSetInsert(ch, name, on);
	$(this).css({ opacity: on ? 1 : 0.45 });
	studioSaver();
});

$(document).on('click', '#studio_new', function() {
	$('#studio').attr('uuid','').attr('name','');
	studioInit({ uuid: 'new', settings: [{ 'setting': 'last_song', 'value': 'new' }] });
	$('#studio_song_select').val('none');
});

$(document).on('click', '#pedalboard_hamburger', function() {
	var pd = $('#pedalboard');
	var z = $('#studio_viewer').closest('.wind').css('z-index');

	if (pd.is(':visible')) {
		pd.hide();
	}
	else {
		pd.show();
		pd.css({ 'z-index': (z + 10) });
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
			mixer = {
				time: { duration: 0, status: 'stop', position: 0, marks: [], interval: 0, startTime: 0, loop: 'off', metronome: 'no', bpm: 120, sig: '4/4', display: 'time', beat: 0, bar: 0, lastMetronome: 0 },
				buttons: { record: { obg: '', bg: 'red', interval: '' }, stop: { obg: '', bg: 'lightgreen', interval: '' }, play: { obg: '', bg: 'yellow', interval: '' } },
				settings: response.settings,
				automations: {}
			};
			// fresh channel graphs, but keep the shared AudioContext
			studioAudio = { ctx: studioAudio.ctx, master: studioAudio.master, masterAnalyser: studioAudio.masterAnalyser, channels: {} };
			studioSelectedTake = null;
			studioTakeDrag = null;
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



$(document).on('click','.knob',function() {
	var knob = $(this);
	var control = knob.attr('control');
	var channel = knob.attr('channel');
	var input = $('.knob_control[control="' + control + '"][channel="' + channel + '"]');
	var current_value = input.val();
	var vis = input.is(':visible');
	if (vis) {
		input.hide();
		$('.knob[channel="' + channel + '"]').show();
	}
	else {
		input.show();
		$('.knob[channel="' + channel + '"]').hide();
		$('.knob[control="' + control + '"][channel="' + channel + '"]').show();
	}
	studioSaver();
});

$(document).on('mousewheel', '.knob', function(e) {
	var mvmt = numeral(e.originalEvent.wheelDelta).value();

	mvmt = numeral(mvmt / 30).value() ;

	var knob = $(this);
	var control = knob.attr('control');
	var channel = knob.attr('channel');
	var input = $('.knob_control[control="' + control + '"][channel="' + channel + '"]');
	var current_value = input.val();
	input.val((numeral(current_value).value() + mvmt) );
	input.trigger('change');
	studioSaver();
});

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

$(document).on('mousewheel', '.channel_volume', function(e) {
	var vol = $(this);
	var mvmt = numeral(e.originalEvent.wheelDelta).value() / 30;
	var newVol = (numeral(vol.val()).value() + mvmt);
	vol.val(newVol);
	studioSaver();
});

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
				duration: take.duration, encoding: take.encoding, src: take.src
			};
		});
	});

	var sl = $('#studio_loop').attr('enabled');
	var video_toggle = $('#studio_video_toggle').attr('toggled');
	song['admin'] = { time: mixer['time'], name: name, uuid: uuid, loop: sl, video_toggle: video_toggle,
		metronome: mixer['time']['metronome'], bpm: mixer['time']['bpm'], sig: mixer['time']['sig'] };
	localStorage.setItem('studio', JSON.stringify(song));
	return song;
}

function studioRetriever() {
	var song = JSON.parse(localStorage.getItem('studio') || '{}');

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

$(document).on('mousewheel', '#studio_jog_wheel', function(e) {
	var j = $(this);
	var mvmt = numeral(e.originalEvent.wheelDelta).value();

	var diff = numeral(mvmt / 30).value() ;
	studio_jw_deg = (studio_jw_deg + diff);
	j.css({'rotate': studio_jw_deg + 'deg' });
	mixer['time']['position'] = mixer['time']['position'] + diff / 10;
	studioTime('scroll');
});

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
	studioInputStreamGrabber(channel,state);
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

	if (state != 'rec') {
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

	// If the channel has an input plug selected, honour its audio/video kind.
	var info = $('.studio_channel_information[direction="input"][channel="' + ch + '"]');
	var plug = isJson(info.text()) ? JSON.parse(info.text()) : {};
	var video = (plug['av'] != 'a');

	var constraints = {
		audio: {
			echoCancellation: false,  // Disables echo suppression
			noiseSuppression: false,  // Disables background noise dampening
			autoGainControl: false,   // Prevents the browser from auto-adjusting volume
			sampleRate: 44100,
			channelCount: 2
		}
	};
	if (video) { constraints['video'] = true; }

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

function studioStartTake(ch) {
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
	$('#studio_track_container').append(el);

	var take = { startTime: Math.max(0, mixer['time']['position'] - studioRecordOffset()), offset: 0, duration: 0, status: 'recording', track: el };
	media.out[ir] = take;

	var mime = studioPickMime(!!media.video);
	var recorder;
	try {
		recorder = mime ? new MediaRecorder(media.in, { mimeType: mime, audioBitsPerSecond: 256000 }) : new MediaRecorder(media.in);
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
		take.duration = Math.max(0, mixer['time']['position'] - take.startTime);
		mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + take.duration);
	}
	if (media.rec) { media.rec[ir] = null; }
}

async function studioRecord() {
	if (mixer['time']['status'] == 'record') { return; }
	mixer['time']['status'] = 'record';
	studioTime('start');

	var song = studioSaver();
	$.each(song, function(i,v) {
		if (!/^[0-9]+$/.test(i) || !v['armed'] || v['armed']['state'] != 'rec') { return; }
		if (!mixer[i]) { mixer[i] = {}; }
		if (!mixer[i].media) { mixer[i].media = {}; }
		studioStartTake(i);
	});
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
		mixer['time']['lastMetronome'] = 0;
		mixer['time']['startTime'] = Date.now() - (mixer['time']['position'] * 1000);
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

function studioTransportTick() {
	var now = Date.now();
	mixer['time']['position'] = (now - mixer['time']['startTime']) / 1000;
	var status = mixer['time']['status'];
	var end = mixer['time']['duration'] || 0;

	if (status == 'record') {
		if (mixer['time']['position'] > end) {
			mixer['time']['duration'] = mixer['time']['position'];
			$('#studio_time_duration').html(numeral(mixer['time']['duration']).format('00.000'));
		}
	}
	else if (status == 'play' && end > 0 && mixer['time']['position'] >= end) {
		if (mixer['time']['loop'] == 'ongoing') {
			mixer['time']['position'] = 0;
			mixer['time']['startTime'] = Date.now();
		}
		else if (mixer['time']['loop'] == 'on') {
			studioStop();
			return;
		}
	}

	studioTimeDisplay();
	studioSyncTakes();
	studioDrawTracks();
	studioMetronomeTick();
}

function studioMetronomeTick() {
	if (mixer['time']['metronome'] != 'yes' || !mixer['time']['bpm']) { return; }
	var tdisplay = studioTimeDisplay();
	if (tdisplay['beat'] <= mixer['time']['lastMetronome']) { return; }
	if (!mixer['time']['lastMetronome']) { mixer['time']['lastMetronome'] = tdisplay['beat']; return; }
	var ctx = studioContext();
	if (!ctx) { return; }
	var oscillator = ctx.createOscillator();
	var gainNode = ctx.createGain();
	var beats = studioKnobNumber(tdisplay['signature'][0], 4) || 4;
	var accent = (tdisplay['beat'] % beats) ? 0 : 1;
	oscillator.frequency.value = accent ? 1100 : 900;
	oscillator.type = 'triangle';
	gainNode.gain.value = studioKnobNumber($('.knob_control[channel="metronome"][control="volume"]').val(), 50) / 100;
	oscillator.connect(gainNode).connect(ctx.destination);
	oscillator.start();
	setTimeout(function() {
		oscillator.stop();
	},20);
	mixer['time']['lastMetronome'] = tdisplay['beat'];
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
			localStorage.setItem('studio', JSON.stringify(response.studio));
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
					if (vr['src']) { el.src = vr['src']; }
					$('#studio_track_container').append(el);
					var startTime = studioKnobNumber(vr['startTime'], 0);
					var duration = studioKnobNumber(vr['duration'], 0);
					mixer[i].media.out[ir] = {
						uuid: vr['uuid'], startTime: startTime, offset: studioKnobNumber(vr['offset'], 0),
						duration: duration, encoding: vr['encoding'], src: vr['src'], status: 'stop', track: el
					};
					mixer['time']['duration'] = Math.max(mixer['time']['duration'], startTime + duration);
				});
			});

			localStorage.setItem('studio', JSON.stringify(response.studio));
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
		el.src = URL.createObjectURL(file);
		$('#studio_track_container').append(el);
		var take = { uuid: null, startTime: mixer['time']['position'] || 0, offset: 0, duration: 0, status: 'stop', track: el, data: file, encoding: file.type };
		el.addEventListener('loadedmetadata', function() {
			take.duration = el.duration || 0;
			mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + take.duration);
			studioDrawTracks();
		});
		mixer[ch].media.out[ir] = take;
	});
	studioDrawTracks();
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
	}
});

$(document).on('change', '.studio_config', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var restart = $(this).attr('restart');
	if (setting == 'record_offset') {
		mixer['time']['record_offset'] = value;
		studioSaver();
		return;
	}
	if (setting == 'crossfade') {
		mixer['time']['crossfade'] = value;
		studioSaver();
		studioDrawTracks();
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
