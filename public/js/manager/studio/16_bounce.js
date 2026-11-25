// ===========================================================================
// Bounce: print a take, or a selected span, through the channel's Out pedals
// ===========================================================================
// The per-take and per-selection bounce live here. A bounced take is marked
// `printed` and plays through the channel fader without its Out chain a second
// time, so the printed audio is what the person hears and the pedals stop
// costing CPU on that take.
//
// Rendering is an OfflineAudioContext, the same graph the export builds: the
// channel's takes feed the channel's Out chain and the chain's tail goes to the
// destination. Nothing on the live transport changes; the take that is replaced
// keeps its slot on the timeline, it just carries wet audio now.

function studioBounceNumber(value, fallback) {
	var n = parseFloat(value);
	return isFinite(n) ? n : fallback;
}

function studioBounceText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// The selection bar is the timeline's own status line; the mix exporter has the
// other live one. Write the first that is on the page.
function studioBounceStatus(text) {
	var el = $('#studio_selection_label');
	if (!el.length) { el = $('#studio_export_state'); }
	if (el.length) { el.text(text || ''); }
}

function studioBounceRate() {
	var rate = 44100;
	try {
		var live = studioAudio.ctx || studioContext();
		if (live && live.sampleRate > 0) { rate = live.sampleRate; }
	}
	catch (e) {}
	return rate;
}

// The channel's output pedals on the offline context, exactly as the live
// channel built them: same names, same control values, same footswitches. An
// empty chain is the plain wire input -> output.
function studioBounceChain(off, c) {
	var input = off.createGain();
	var node = input;
	((c && c.outInserts) || []).forEach(function (ins) {
		if (!ins || !ins.name) { return; }
		var built = studioInsert(off, ins.name);
		if (!built || !built.input || !built.output) { return; }
		var values = ins.values || {};
		Object.keys(values).forEach(function (control) {
			if (built.set) { built.set(control, values[control]); }
		});
		if (built.setBypass) { built.setBypass(!!ins.bypassed); }
		node.connect(built.input);
		node = built.output;
	});
	return { input: input, output: node };
}

// A take's audio as an AudioBuffer. The export's decoder is the one place that
// already knows how to turn a take's blob or URL into samples, so reuse it and
// fall back to a plain fetch + decodeAudioData when the export part is absent.
async function studioBounceDecode(take) {
	if (!take) { return null; }
	if (take.buffer) { return take.buffer; }
	if (typeof studioExportTakeBuffer === 'function') {
		try {
			var decoder = new OfflineAudioContext(2, 1, studioBounceRate());
			return await studioExportTakeBuffer(decoder, take);
		}
		catch (e) { return null; }
	}
	if (!take.src) { return null; }
	try {
		var response = await fetch(take.src);
		var bytes = await response.arrayBuffer();
		var ctx = new OfflineAudioContext(2, 1, studioBounceRate());
		return await ctx.decodeAudioData(bytes);
	}
	catch (e) { return null; }
}

// Lay one take into the render, clipped to [start, end] and placed relative to
// start. A looping take repeats from its in-point on the take's own cycle, the
// same wrap the transport makes. A printed take is already wet, so it goes to
// `destination` directly instead of back through the chain.
function studioBounceSchedule(off, destination, take, buffer, start, end) {
	if (!buffer) { return; }
	var offset = Math.max(0, studioBounceNumber(take.offset, 0));
	var span = studioBounceNumber(take.duration, 0);
	if (!(span > 0)) { span = Math.max(0, (buffer.duration || 0) - offset); }
	if (!(span > 0)) { return; }
	var ts = Math.max(0, studioBounceNumber(take.startTime, 0));
	var at = ts;
	// Start at the cycle that contains the selection, not at the take's first
	// play, so a sample armed long before the range does not cost a loop per
	// second of empty timeline.
	if (take.loop && at < start) {
		var skip = Math.floor((start - ts) / span);
		if (skip > 0) { at = ts + (skip * span); }
	}
	for (var n = 0; n < 4096 && at < end; n++) {
		var a = Math.max(at, start);
		var b = Math.min(at + span, end);
		if (b > a) {
			var bufferOffset = offset + (a - at);
			if (bufferOffset < (buffer.duration || 0)) {
				var src = off.createBufferSource();
				src.buffer = buffer;
				src.connect(destination);
				src.start(a - start, bufferOffset, b - a);
			}
		}
		if (!take.loop) { break; }
		at += span;
	}
}

function studioBounceTakeOverlaps(take, start, end) {
	if (!take) { return false; }
	var ts = Math.max(0, studioBounceNumber(take.startTime, 0));
	var span = studioBounceNumber(take.duration, 0);
	if (!(span > 0)) {
		span = (take.buffer && take.buffer.duration)
			? Math.max(0, take.buffer.duration - Math.max(0, studioBounceNumber(take.offset, 0)))
			: 0;
	}
	// An unknown length is left in: the decoder will settle it, and skipping
	// the channel on a guess would silently lose audio.
	if (!(span > 0)) { return true; }
	if (take.loop) { return ts < end; }
	return ts < end && (ts + span) > start;
}

// Render [start, end] of one channel's takes through its Out chain. A printed
// take is mixed in dry, because its buffer already has the chain on it.
async function studioBounceSpan(c, takes, start, end) {
	var rate = studioBounceRate();
	var frames = Math.max(1, Math.ceil((end - start) * rate));
	var off = new OfflineAudioContext(2, frames, rate);
	var chain = studioBounceChain(off, c);
	chain.output.connect(off.destination);
	for (var i = 0; i < takes.length; i++) {
		var take = takes[i];
		if (!take || take.status == 'recording') { continue; }
		if (take.encoding && String(take.encoding).indexOf('video') !== -1) { continue; }
		var buffer = await studioBounceDecode(take);
		if (!buffer) { continue; }
		var target = take.printed ? off.destination : chain.input;
		studioBounceSchedule(off, target, take, buffer, start, end);
	}
	return await off.startRendering();
}

// Print one take through its channel's Out chain. The take stays where it is;
// its source is replaced by the rendered WAV and it is marked printed so the
// dry playback path stops applying the pedals to it.
async function studioBounceTake(ch, take) {
	if (!take || take.status == 'recording') { return false; }
	if (take.encoding && String(take.encoding).indexOf('video') !== -1) {
		studioBounceStatus(studioBounceText('A video take has no pedal chain to print.'));
		return false;
	}
	if (take.printed) {
		studioBounceStatus(studioBounceText('This take is already printed through its pedals.'));
		return false;
	}
	var c = studioChannelEngine(ch);
	if (!c || !c.outInserts || !c.outInserts.length) {
		studioBounceStatus(studioBounceText('There is no pedal chain to print on this track.'));
		return false;
	}
	studioBounceStatus(studioBounceText('Printing the pedal chain\u2026'));
	try {
		var buffer = await studioBounceDecode(take);
		if (!buffer) { throw new Error('the take has no audio'); }
		var offset = Math.max(0, studioBounceNumber(take.offset, 0));
		var span = studioBounceNumber(take.duration, 0);
		if (!(span > 0)) { span = Math.max(0, (buffer.duration || 0) - offset); }
		if (!(span > 0)) { throw new Error('the take has no length'); }
		if (!(offset < (buffer.duration || 0))) { throw new Error('the take has no audio'); }

		var rate = studioBounceRate();
		var frames = Math.max(1, Math.ceil(span * rate));
		var off = new OfflineAudioContext(2, frames, rate);
		var chain = studioBounceChain(off, c);
		chain.output.connect(off.destination);
		var src = off.createBufferSource();
		src.buffer = buffer;
		src.connect(chain.input);
		src.start(0, offset, span);
		var rendered = await off.startRendering();
		var data = studioBufferToWav(rendered);

		// Replace in place: the slot, its length and its loop flag stay; the
		// audio is now the printed WAV, so it gets no server uuid and no URL.
		take.offset = 0;
		take.buffer = rendered;
		take.data = data;
		take.src = null;
		take.uuid = null;
		take.encoding = 'audio/wav';
		take.printed = true;
		// The engine and the canvas cache the old audio by file and by waveform;
		// the printed take is a different file, so none of those may survive.
		delete take.engine_file;
		delete take.engine_key;
		delete take.engine_failed;
		delete take.engine_staging;
		take.waveform = null;
		take.waveformL = null;
		take.waveformR = null;
		// The hidden element may still hold the old URL; the scheduler uses the
		// decoded buffer, so dropping the attribute is enough to let it go.
		if (take.track) { try { take.track.removeAttribute('src'); } catch (e) {} }

		studioReindexTakes(ch);
		studioSaver();
		studioTakesChanged();
		studioDrawChannel(ch);
		studioBounceStatus(studioBounceText('Printed the pedal chain into the take.'));
		return true;
	}
	catch (error) {
		studioBounceStatus(studioBounceText('The bounce failed.') + ' ' + ((error && error.message) ? error.message : ''));
		return false;
	}
}

// Cut every take that straddles the range boundary, then drop the takes that
// are wholly inside it, so one new printed take can stand in their place.
function studioBounceClearSpan(ch, start, end) {
	var guard = 0;
	while (guard++ < 64) {
		var hit = null;
		var list = studioChannelTakes(ch);
		for (var i = 0; i < list.length; i++) {
			var take = list[i];
			if (!take || take.status == 'recording') { continue; }
			var a = studioBounceNumber(take.startTime, 0);
			var b = a + studioBounceNumber(take.duration, 0);
			if (a < start - 1e-6 && b > start + 1e-6) { hit = { take: take, at: start }; break; }
			if (a < end - 1e-6 && b > end + 1e-6) { hit = { take: take, at: end }; break; }
		}
		if (!hit) { break; }
		if (!studioSplitTake(ch, hit.take, hit.at)) { break; }
	}
	studioChannelTakes(ch).forEach(function (take) {
		if (!take || take.status == 'recording') { return; }
		var a = studioBounceNumber(take.startTime, 0);
		var b = a + studioBounceNumber(take.duration, 0);
		if (a >= start - 1e-6 && b <= end + 1e-6) { studioRemoveTake(ch, take); }
	});
}

// Print a selected span on every named channel ({ ch: true }), replacing the
// takes it covers with one printed take per channel. The render happens before
// any editing: the render reads the takes as they were, and the edit then
// swaps in its result. Returns how many channels were bounced.
async function studioBounceSelection(start, end, channels) {
	var from = Math.max(0, studioBounceNumber(start, 0));
	var to = studioBounceNumber(end, from);
	if (!(to > from)) { return 0; }
	var map = channels || {};
	var keys = Object.keys(map).filter(function (ch) {
		return /^[0-9]+$/.test(String(ch)) && map[ch];
	});

	// Render first, while every take is still on the timeline.
	var renders = [];
	for (var i = 0; i < keys.length; i++) {
		var ch = keys[i];
		var c = studioChannelEngine(ch);
		if (!c || !c.outInserts || !c.outInserts.length) { continue; }
		var takes = studioChannelTakes(ch).filter(function (take) {
			return take && take.status != 'recording';
		});
		if (!takes.some(function (take) { return studioBounceTakeOverlaps(take, from, to); })) { continue; }
		try {
			var rendered = await studioBounceSpan(c, takes, from, to);
			if (rendered) {
				renders.push({ ch: ch, buffer: rendered, data: studioBufferToWav(rendered) });
			}
		}
		catch (e) { continue; }
	}

	if (!renders.length) {
		studioBounceStatus(studioBounceText('There is no pedal chain to print on this track.'));
		return 0;
	}

	var bounced = 0;
	renders.forEach(function (render) {
		var ch = render.ch;
		var m = mixer[ch];
		if (!m) { return; }
		if (!m.media) { m.media = {}; }
		if (!m.media.out) { m.media.out = []; }

		studioBounceClearSpan(ch, from, to);

		var el = document.createElement('video');
		el.className = 'studio_video';
		el.style.display = 'none';
		el.preload = 'auto';
		$('#studio_track_container').append(el);

		var printed = {
			uuid: null,
			startTime: from,
			offset: 0,
			duration: to - from,
			status: 'stop',
			src: null,
			encoding: 'audio/wav',
			loop: false,
			buffer: render.buffer,
			data: render.data,
			printed: true,
			track: el
		};
		m.media.out.push(printed);
		mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, printed.startTime + printed.duration);
		studioReindexTakes(ch);
		studioDrawChannel(ch);
		bounced++;
	});

	studioSaver();
	studioTakesChanged();
	studioDrawTracks();
	if (bounced) { studioBounceStatus(studioBounceText('Printed the selection through the pedal chains.')); }
	return bounced;
}
