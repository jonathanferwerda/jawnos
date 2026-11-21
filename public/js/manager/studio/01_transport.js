$(document).on('click', '#studio_latency_measure', function () { studioLatencyMeter(); });

function studioDetachInput(ch) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	if (c.source) { try { c.source.disconnect(); } catch (e) {} c.source = null; }
	if (c.inputSource) { try { c.inputSource.disconnect(); } catch (e) {} c.inputSource = null; }
	if (c.inputSplitter) { try { c.inputSplitter.disconnect(); } catch (e) {} c.inputSplitter = null; }
	if (c.synthTap) {
		try { c.synthTap.node.disconnect(c.synthTap.gain); } catch (e) {}
		try { c.synthTap.gain.disconnect(); } catch (e) {}
		c.synthTap = null;
	}
	if (c.drumTap) {
		try { c.drumTap.node.disconnect(c.drumTap.gain); } catch (e) {}
		try { c.drumTap.gain.disconnect(); } catch (e) {}
		c.drumTap = null;
	}
	// The drums' own recorder tap follows the selected channel; tell it that this
	// channel no longer takes them.
	if (typeof studioDrumsRouteSelection === 'function') { studioDrumsRouteSelection(); }
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

// A retime must not cut the takes. Clicks are tagged where every scheduled
// source is parked, so this drops only them while studioFlushSources keeps its
// whole-list meaning for stop, seek and a take edit.
function studioFlushClicks() {
	var list = studioAudio.sources || [];
	var keep = [];
	list.forEach(function (entry) {
		if (!entry || entry.kind !== 'click') { keep.push(entry); return; }
		try { entry.src.stop(0); } catch (e) {}
		try { entry.src.disconnect(); } catch (e) {}
		if (entry.gain) { try { entry.gain.disconnect(); } catch (e) {} }
	});
	studioAudio.sources = keep;
}

// A seek is allowed only while the transport is stopped or playing. While a
// take records, moving the playhead would re-anchor the clock under the
// recording, so every seek entry point asks this first.
function studioCanSeek() {
	var status = mixer && mixer['time'] ? mixer['time']['status'] : 'stop';
	return status == 'stop' || status == 'play';
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
	studioAudio.clickKey = studioClickKey();
	studioScheduleTick();
}

// Park a scheduled source so it can be flushed on a stop, seek or wrap. A
// click is tagged so a settings change can retime the metronome without
// touching the take sources.
function studioTrackSource(src, gain, kind) {
	var entry = { src: src, gain: gain, kind: kind || 'take' };
	src.onended = function () {
		var list = studioAudio.sources;
		var at = list.indexOf(entry);
		if (at != -1) { list.splice(at, 1); }
		try { src.disconnect(); } catch (e) {}
		if (gain) { try { gain.disconnect(); } catch (e) {} }
	};
	studioAudio.sources.push(entry);
}

// ---- engine transport -------------------------------------------------------
//
// When the house engine is live, it owns the transport clock and the
// metronome: one absolute bar phase for the browser playhead and the browser
// takes. The page still schedules take audio on its own AudioContext, but it
// re-anchors that segment from the engine's position, so both read one clock
// and one click. An engine take owns the output for itself, so the transport
// waits for it; a dead or refusing engine falls back to the browser clock and
// click, and no second click is ever scheduled.

var studioEngineTransportTimer = 0;
var studioEngineTransportDrift = 0.05;
// True while the takes are being staged for a first start. A second Play while
// that upload runs must not start a second staging or a second transport.
var studioEngineTransportStarting = false;

function studioEngineTransportReady() {
	if (typeof studioEngineAvailable === 'undefined' || !studioEngineAvailable) { return false; }
	if (typeof studioEngineRecording !== 'undefined' && studioEngineRecording) { return false; }
	if (mixer['time'] && mixer['time']['engine_take']) { return false; }
	// A browser recording keeps the browser clock and its count-in click: the
	// engine is not in that capture path, and its transport cannot represent a
	// negative count-in position. An engine take brings its own engine click.
	if (mixer['time'] && mixer['time']['status'] == 'record') { return false; }
	return true;
}

// The engine always runs its click-only output; the gain is zero while the
// metronome is off, so the transport still has a clock but no sound.
function studioEngineTransportFields(pos) {
	var bpm = studioKnobNumber(mixer['time']['bpm'], 120) || 120;
	var beats = studioKnobNumber(String(mixer['time']['sig'] || '4/4').split('/')[0], 4) || 4;
	var volume = studioKnobNumber($('.knob_control[channel="metronome"][control="volume"]').val(), 50);
	if (!isFinite(volume)) { volume = 50; }
	var gain = (mixer['time']['metronome'] == 'yes') ? (volume / 100) : 0;
	var loop = studioEngineTransportLoop();
	return {
		position: Math.max(0, pos || 0),
		bpm: bpm,
		beats_per_bar: beats,
		gain: Math.max(0, Math.min(1, gain)),
		loop_start: loop.start,
		loop_end: loop.end
	};
}

// A committed loop follows the same region the browser segment uses. The
// engine wraps its position at loop_end and re-reads the absolute bar grid
// from loop_start. `record` never wraps, and `loop on` plays the song once.
function studioEngineTransportLoop() {
	if (mixer['time']['status'] == 'record' || mixer['time']['loop'] != 'ongoing') {
		return { start: 0, end: 0 };
	}
	var region = studioLoopRegion();
	if (region && region.end > region.start) { return { start: region.start, end: region.end }; }
	var duration = mixer['time']['duration'] || 0;
	if (duration > 0) { return { start: 0, end: duration }; }
	return { start: 0, end: 0 };
}

// Build the engine's clip plan from the armed takes. Each clip carries the
// same timeline start, in-point, length and crossfade the browser scheduler
// would use, plus the channel fader and pan folded into its strip. A take the
// engine cannot take (a video, or one with no length) is counted as `blocked`:
// the caller then keeps the whole mix in the browser rather than losing it.
function studioEngineClipPlan() {
	var clips = [];
	var blocked = 0;
	var anySolo = studioAnySolo();
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m.media || !m.media.out) { return; }
		var armed = m.armed && (m.armed.state == 'rec' || m.armed.state == 'play' || m.armed.state == 'loop');
		if (!armed) { return; }
		var ordered = studioChannelTakes(ch);
		var silent = m.mute || (anySolo && !m.solo);
		var gain = studioVolumeFraction($('.channel_volume[channel="' + ch + '"]').val()) * (silent ? 0 : 1);
		var pan = (studioKnobNumber($('.knob_control[channel="' + ch + '"][control="pan"]').val(), 50) - 50) / 50;
		ordered.forEach(function (take, i) {
			if (!take || take.status == 'recording') { return; }
			if (take.encoding && take.encoding.indexOf('video') !== -1) { blocked++; return; }
			var dom = take.duration || (take.buffer && take.buffer.duration) || 0;
			if (!(dom > 0)) { blocked++; return; }
			var prev = ordered[i - 1];
			var next = ordered[i + 1];
			var xf = studioCrossfade();
			var fIn = 0, fOut = 0;
			if (prev) {
				var fi = Math.min(xf, prev.duration || 0, dom) / 2;
				if (fi > 0 && prev.src !== take.src && Math.abs(take.startTime - (prev.startTime + (prev.duration || 0))) <= fi * 2) { fIn = fi; }
			}
			if (next && !take.loop) {
				var fo = Math.min(xf, dom, next.duration || 0) / 2;
				if (fo > 0 && next.src !== take.src && Math.abs(next.startTime - (take.startTime + dom)) <= fo * 2) { fOut = fo; }
			}
			clips.push({
				take: take,
				start: take.startTime,
				offset: take.offset || 0,
				duration: dom,
				gain: gain,
				pan: pan,
				loop: !!take.loop,
				fade_in: fIn,
				fade_out: fOut
			});
		});
	});
	return { clips: clips, blocked: blocked };
}

// A take's audio as an AudioBuffer, decoded once and kept. The engine needs a
// file, and this is the one decode the browser already knows how to do.
function studioEngineClipBuffer(take) {
	if (take.buffer) { return Promise.resolve(take.buffer); }
	var ctx = studioAudio.ctx || studioContext();
	if (!ctx) { return Promise.reject(new Error('no audio context')); }
	return studioTakeArrayBuffer(take).then(function (ab) {
		return new Promise(function (resolve, reject) { ctx.decodeAudioData(ab, resolve, reject); });
	}).then(function (audio) {
		take.buffer = audio;
		if (!(take.duration > 0)) { take.duration = audio.duration || 0; }
		return audio;
	});
}

// Stage one take as a WAV the engine can read, once. The absolute path is kept
// on the take, so a later play sends the same file rather than uploading it
// again. A failed stage is remembered so the caller can fall back cleanly.
function studioEngineClipStage(take) {
	if (take.engine_file) { return Promise.resolve(take.engine_file); }
	if (take.engine_staging) { return take.engine_staging; }
	if (!take.engine_key) {
		// A saved take keeps one file across reloads; an unsaved one gets a
		// fresh name so a re-recording never reuses stale audio.
		take.engine_key = take.uuid ? String(take.uuid) : ('clip_' + Date.now() + '_' + Math.floor(Math.random() * 1e9).toString(36));
	}
	var key = take.engine_key;
	take.engine_staging = studioEngineClipBuffer(take).then(function (buffer) {
		var wav = studioBufferToWav(buffer);
		var data = new FormData();
		data.append('key', key);
		data.append('clip', wav, key + '.wav');
		return new Promise(function (resolve, reject) {
			$.ajax({
				url: '/manager/studio/clip',
				type: 'POST',
				data: data,
				processData: false,
				contentType: false,
				dataType: 'json',
				success: function (answer) {
					if (answer && answer.ok === true && answer.file) {
						take.engine_file = answer.file;
						resolve(answer.file);
					}
					else { reject(new Error((answer && answer.error) || 'the take was refused')); }
				},
				error: function (xhr) {
					var answer = xhr && xhr.responseJSON;
					reject(new Error((answer && answer.error) || 'the take could not be staged'));
				}
			});
		});
	}).catch(function (error) {
		delete take.engine_staging;
		take.engine_failed = true;
		throw error;
	}).then(function (file) {
		delete take.engine_staging;
		return file;
	});
	return take.engine_staging;
}

// Stage every clip's file. A failure rejects the whole set: the caller then
// keeps the browser's audio rather than playing a partial mix.
function studioEngineClipStageAll(plan) {
	var jobs = plan.clips.map(function (clip) {
		return studioEngineClipStage(clip.take).then(function (file) {
			clip.file = file;
			return clip;
		});
	});
	return Promise.all(jobs).then(function (staged) {
		return staged.map(function (clip) {
			return {
				file: clip.file,
				start: clip.start,
				offset: clip.offset,
				duration: clip.duration,
				gain: clip.gain,
				pan: clip.pan,
				loop: clip.loop,
				fade_in: clip.fade_in,
				fade_out: clip.fade_out
			};
		});
	});
}

function studioEngineTransportPost(action, fields, done) {
	var data = $.extend({ action: action }, fields || {});
	$.ajax({
		url: '/manager/studio/transport',
		type: 'POST',
		data: data,
		dataType: 'json',
		success: function (answer) {
			if (done) { done(studioEngineAnswer(answer)); }
		},
		error: function (xhr) {
			var answer = xhr && xhr.responseJSON;
			if (done) { done({ ok: false, error: (answer && answer.error) ? answer.error : studioAudioLabel('the audio engine did not answer') }); }
		}
	});
}

// Start the engine clock at a position, or seek the one already running.
// Suppressing the browser click starts before the request answers; a refusal
// clears the flag and re-anchors the browser click immediately.
function studioEngineTransportStart(pos) {
	if (!studioEngineTransportReady()) {
		mixer['time']['engine_transport'] = false;
		return;
	}
	if (studioEngineTransportStarting) { return; }
	var fields = studioEngineTransportFields(pos);
	// A running engine only needs the new position; tempo and loop ride a
	// retune `start` from studioEngineTransportSync. Its clips are fixed for
	// the life of the transport, so the page never re-sends them.
	if (mixer['time']['engine_transport']) {
		studioEngineTransportPost('seek', { position: fields.position }, studioEngineTransportAnswer);
		return;
	}
	var plan = studioEngineClipPlan();
	if (plan.blocked > 0) {
		// A video take (or one with no length yet) cannot be rendered by the
		// engine. Keep the whole mix in the browser rather than muting it.
		mixer['time']['engine_transport'] = false;
		return;
	}
	// The engine owns the takes only after every file is staged. The flag goes
	// up first so the browser scheduler does not start a second copy, and a
	// staging refusal drops it again for a clean fallback.
	studioEngineTransportStarting = true;
	mixer['time']['engine_transport'] = true;
	studioEngineClipStageAll(plan).then(function (clips) {
		studioEngineTransportStarting = false;
		if (!mixer['time']['engine_transport']) { return; }
		// The upload took time, so start from where the playhead is now rather
		// than where it was when Play was pressed.
		var ctx = studioAudio.ctx;
		var seg = studioAudio.playSeg;
		var now = (ctx && seg) ? (seg.pos0 + (ctx.currentTime - seg.ctx0)) : (mixer['time']['position'] || 0);
		var fields = studioEngineTransportFields(now);
		// The plan rides as one JSON string: jQuery's own array encoding is not
		// the shape the route reads.
		fields.clips_json = JSON.stringify(clips);
		studioEngineTransportPost('start', fields, studioEngineTransportAnswer);
	}).catch(function (error) {
		studioEngineTransportStarting = false;
		console.log('studio: engine clip staging failed, keeping browser audio', error);
		studioEngineTransportDrop();
	});
}

function studioEngineTransportAnswer(data) {
	if (!data || data.ok !== true) {
		console.log('studio: engine transport refused, using the browser clock', (data && data.error) || '');
		studioEngineTransportDrop();
		return;
	}
	// The engine now owns the take audio: drop anything the browser had queued
	// for this pass so the two never sound together.
	studioFlushSources();
	studioEngineTransportPollStart();
	if (data.transport) { studioEngineTransportApply(data.transport); }
}

// The engine path refused or went away: hand the clock and click back to the
// browser. A fire-and-forget stop is safe even when no transport was started;
// it never touches a take, and it prevents an engine clock we can no longer
// read from playing a second click beside the browser's.
function studioEngineTransportDrop() {
	studioEngineTransportStarting = false;
	mixer['time']['engine_transport'] = false;
	studioEngineTransportPollStop();
	// Hand both clocks and the take audio back: re-anchor the scheduler at the
	// playhead so a take already in progress starts mid-clip rather than
	// staying silent until the next pass.
	if (typeof studioTakesChanged === 'function') { studioTakesChanged(); }
	if (typeof studioClickReanchor === 'function') { studioClickReanchor(); }
	studioEngineTransportPost('stop', {}, function () {});
}

function studioEngineTransportSync() {
	if (!mixer['time']['engine_transport']) { return; }
	// A first start is still staging its clips; its own `start` will carry the
	// current tempo and loop, so a retune now would race the initial `start`.
	if (studioEngineTransportStarting) { return; }
	var ctx = studioAudio.ctx;
	var seg = studioAudio.playSeg;
	var pos = (ctx && seg) ? (seg.pos0 + (ctx.currentTime - seg.ctx0)) : (mixer['time']['position'] || 0);
	var fields = studioEngineTransportFields(pos);
	// A start on a running transport retunes, re-loops and seeks in place: the
	// engine never closes the device, so a knob does not make a gap.
	studioEngineTransportPost('start', fields, function (data) {
		if (!data || data.ok !== true) {
			studioEngineTransportDrop();
		}
	});
}

function studioEngineTransportStop() {
	studioEngineTransportPollStop();
	var was = !!mixer['time']['engine_transport'];
	mixer['time']['engine_transport'] = false;
	if (!was) { return; }
	studioEngineTransportPost('stop', {}, function () {});
}

function studioEngineTransportPollStart() {
	if (studioEngineTransportTimer) { return; }
	studioEngineTransportTimer = setInterval(studioEngineTransportPoll, 250);
}

function studioEngineTransportPollStop() {
	if (studioEngineTransportTimer) { clearInterval(studioEngineTransportTimer); studioEngineTransportTimer = 0; }
}

function studioEngineTransportPoll() {
	if (!mixer['time']['engine_transport']) { studioEngineTransportPollStop(); return; }
	studioEngineTransportPost('status', {}, function (data) {
		if (!data || data.ok !== true || !data.transport) {
			studioEngineTransportDrop();
			return;
		}
		studioEngineTransportApply(data.transport);
	});
}

// The engine is the clock: update the playhead from it and re-anchor the
// browser segment when the two have drifted past a small threshold. A loop
// wrap is compared on the loop cycle, so a wrap is never read as a drift.
function studioEngineTransportApply(transport) {
	if (!transport || typeof transport.position !== 'number' || !isFinite(transport.position)) { return; }
	if (transport.state && transport.state != 'playing') {
		studioEngineTransportDrop();
		return;
	}
	var pos = Math.max(0, transport.position);
	var ctx = studioAudio.ctx;
	var seg = studioAudio.playSeg;
	var drift = 0;
	if (ctx && seg) {
		drift = (seg.pos0 + (ctx.currentTime - seg.ctx0)) - pos;
	}
	var loopStart = Number(transport.loop_start) || 0;
	var loopEnd = Number(transport.loop_end) || 0;
	var period = (loopEnd > loopStart) ? (loopEnd - loopStart) : 0;
	if (period > 0) {
		drift = ((drift % period) + period) % period;
		if (drift > period / 2) { drift -= period; }
	}
	mixer['time']['position'] = pos;
	if (Math.abs(drift) > studioEngineTransportDrift && typeof studioClockStart === 'function') {
		// Re-anchor the segment (and the takes that have not sounded yet) to
		// the engine position. This never commands the engine again.
		studioClockStart(pos, true);
	}
}

// Begin (or restart) the transport at a transport position, anchored to now.
function studioClockStart(pos, fromEngine) {
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
	studioAudio.clickKey = studioClickKey();
	mixer['time']['position'] = pos;
	if (!fromEngine && typeof studioEngineTransportStart === 'function') { studioEngineTransportStart(pos); }
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

// What a click's timing depends on. The volume knob is deliberately absent:
// turning it down does not retime the beats already in flight.
function studioClickKey() {
	return [
		mixer['time']['bpm'],
		mixer['time']['sig'],
		mixer['time']['metronome'],
		mixer['time']['loop'],
		mixer['time']['status'],
		mixer['time']['punch_in']
	].join('|');
}

// Retime the clicks from the playhead and leave every take source alone. The
// grid stays absolute (k * beat mapped through the segment's p0/ctx0), so a
// beat already behind the clock is skipped by studioScheduleClicks and the
// following beats keep their own places; nothing is moved later to catch up.
function studioClickReanchor() {
	var ctx = studioAudio.ctx;
	var seg = studioAudio.playSeg;
	if (!ctx || !seg) { return; }
	var now = ctx.currentTime;
	var pos = seg.pos0 + (now - seg.ctx0);
	studioFlushClicks();
	studioAudio.clickSeg = studioSegmentCopy(studioSegmentFrom(pos, now));
}

// Place everything that will be heard in the next `lookahead` seconds.
function studioScheduleTick() {
	var ctx = studioAudio.ctx;
	if (!ctx || !studioAudio.schedSeg) { return; }
	// A tempo, signature, metronome, loop or transport change retimes the click
	// from the playhead. Only the click sources are dropped; the takes keep
	// playing, and the burst below can stay long enough to survive a stall.
	var key = studioClickKey();
	if (studioAudio.clickKey !== key) {
		studioAudio.clickKey = key;
		studioClickReanchor();
		// A tempo, signature or loop change retimes the engine too, in place.
		if (typeof studioEngineTransportSync === 'function') { studioEngineTransportSync(); }
	}
	var horizon = ctx.currentTime + (studioAudio.lookahead || 2.0);
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

	// Clicks: committed in bursts as large as the horizon, on the same segment
	// grid as the transport. A normal main-thread stall therefore cannot leave
	// the queue empty, and the settings check above re-anchors only the clicks
	// when the grid itself changes.
	var cguard = 0;
	while (studioAudio.clickSeg && cguard++ < 256) {
		var c = studioAudio.clickSeg;
		if (c.ctx0 > horizon) { break; }
		var span = (c.pos1 === Infinity) ? Infinity : (c.pos1 - c.pos0);
		var step = studioAudio.clickStep || 2.0;
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

// Is any channel soloed? Solo is exclusive-ish: while at least one is, the
// channels that are not are silent.
function studioAnySolo() {
	var solo = false;
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(String(ch)) || !m) { return; }
		if (m.solo) { solo = true; }
	});
	return solo;
}

// The channel fader / pan feed the take bus, so set them once per pass rather
// than per take. Mute and solo gate the same gain: a muted channel is silent,
// and while any channel is soloed every other one is.
function studioApplyPlaybackMix() {
	var anySolo = studioAnySolo();
	$.each(studioAudio.channels, function (ch, c) {
		if (!c) { return; }
		var m = mixer[ch] || {};
		var silent = m.mute || (anySolo && !m.solo);
		c.playBus.gain.value = studioVolumeFraction($('.channel_volume[channel="' + ch + '"]').val()) * (silent ? 0 : 1);
		c.playPan.pan.value = (studioKnobNumber($('.knob_control[channel="' + ch + '"][control="pan"]').val(), 50) - 50) / 50;
	});
}

// Mute and solo are the mix, not the recording: the playback bus is gated, while
// the captured input and the monitor tap stay exactly as they were. The track
// rows and the strips dim when another channel's solo silences them.
function studioApplyMuteSolo() {
	var anySolo = studioAnySolo();
	$.each(mixer, function (ch) {
		if (!/^[0-9]+$/.test(String(ch))) { return; }
		var m = mixer[ch] || {};
		var dimmed = anySolo && !m.solo;
		$('#studio_track_row_' + ch).toggleClass('studio_solo_muted', !!dimmed);
		$('.channel_' + ch).toggleClass('studio_solo_muted', !!dimmed);
	});
	studioApplyPlaybackMix();
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
	// The engine renders the takes while it owns the transport, so the browser
	// must not schedule a second copy under the same clock and click.
	if (mixer['time'] && mixer['time']['engine_transport']) { return; }
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
	// An engine take generates its own click on the device clock, and the
	// engine transport owns the transport's one click; the browser must not
	// add a second one while either is active.
	if (mixer['time'] && (mixer['time']['engine_take'] || mixer['time']['engine_transport'])) { return; }
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
		// A stalled timer can leave this beat behind the clock. Skip that beat
		// alone: the grid is absolute, so the next beat keeps its own place and
		// is never dragged later to catch up.
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
		studioTrackSource(osc, gain, 'click');
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
