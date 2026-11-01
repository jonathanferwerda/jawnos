$(document).on('click', '#studio_latency_measure', function () { studioLatencyMeter(); });

function studioDetachInput(ch) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	if (c.source) { try { c.source.disconnect(); } catch (e) {} c.source = null; }
	if (c.synthTap) {
		try { c.synthTap.node.disconnect(c.synthTap.gain); } catch (e) {}
		try { c.synthTap.gain.disconnect(); } catch (e) {}
		c.synthTap = null;
	}
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
