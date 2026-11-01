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

