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
// The clip menu's clipboard is a snapshot of a take's source, not the take
// itself, so a cut can take the original away and a paste can still rebuild it.
var studioClipboard = null;
var studioClipMenuTarget = null;

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
	var view = studioTimelineView();
	var x = clientX - rect.left;
	// the take's time and its pixels come from the same visible window, so a
	// zoomed lane still selects, moves and trims the clip under the pointer
	var t = studioTimelineTimeAt(canvas, clientX);
	var tpp = view.span / rect.width;
	var takes = (mixer[ch] && mixer[ch].media && mixer[ch].media.out) || [];
	for (var i = takes.length - 1; i >= 0; i--) {
		var take = takes[i];
		if (!take || take.status == 'recording') { continue; }
		var end = take.startTime + (take.duration || 0);
		if (t >= take.startTime - (6 * tpp) && t <= end + (6 * tpp)) {
			var mode = 'move';
			if (take.duration) {
				if (Math.abs(x - studioTimelineXAt(canvas, take.startTime)) < 8) { mode = 'trim-start'; }
				else if (Math.abs(x - studioTimelineXAt(canvas, end)) < 8) { mode = 'trim-end'; }
			}
			return { ch: ch, take: take, mode: mode, tpp: tpp, x: clientX, t: t,
				startTime: take.startTime, startDur: take.duration || 0, startOffset: take.offset || 0 };
		}
	}
	return null;
}

// A press on empty lane space has no take to measure against, so a loop track
// turns the pointer into a timeline position: the window rect carries the view,
// so the same song-scale multiplication reads the visible window.
function studioCanvasTime(canvas, clientX) {
	var rect = studioTimelineWindowRect(canvas);
	if (!rect.width) { return 0; }
	var duration = studioTimelineDuration();
	var t = ((clientX - rect.left) / rect.width) * duration;
	return Math.max(0, Math.min(duration, t));
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

// ---- the clip menu ----------------------------------------------------------

function studioClipMenuRow(menu, command, label, disabled) {
	$('<button type="button" class="studio_menu_row"></button>')
		.attr('data-command', command)
		.text(label)
		.prop('disabled', !!disabled)
		.appendTo(menu);
}

// The drum loop section of a track menu: one row per saved loop, or a single
// disabled row that says the library is empty. The row's index is looked up in
// the published library when it is clicked.
function studioLoopMenuRows(menu) {
	$('<div class="studio_menu_head"></div>').text(studioLayoutText('Add drum loop')).appendTo(menu);
	var library = (typeof studioDrumsLoopLibrary === 'function') ? studioDrumsLoopLibrary() : [];
	if (!library.length) {
		$('<button type="button" class="studio_menu_row" disabled></button>')
			.text(studioLayoutText('No saved loops'))
			.appendTo(menu);
		return;
	}
	library.forEach(function (item, index) {
		if (!item || !item.name) { return; }
		$('<button type="button" class="studio_menu_row studio_drums_loop_row"></button>')
			.attr('data-loop', index)
			.text(item.name)
			.appendTo(menu);
	});
}

// What a copy keeps: everything needed to place the clip again on any track.
// A saved clip points at its file by uuid; an unsaved one carries its blob.
function studioClipSnapshot(take) {
	if (!take) { return null; }
	return {
		src: take.src,
		uuid: take.uuid || null,
		data: take.data,
		offset: take.offset || 0,
		duration: take.duration || 0,
		encoding: take.encoding,
		loop: !!take.loop
	};
}

function studioClipMenu(hit, px, py) {
	$('.studio_menu').remove();
	studioClipMenuTarget = { ch: hit.ch, take: hit.take, t: hit.t };
	var menu = $('<div class="studio_menu studio_clip_menu"></div>').attr('data-channel', hit.ch);
	$('<div class="studio_menu_head"></div>').text(studioLayoutText('Clip')).appendTo(menu);
	studioClipMenuRow(menu, 'split', studioLayoutText('Split'), false);
	studioClipMenuRow(menu, 'cut', studioLayoutText('Cut'), false);
	studioClipMenuRow(menu, 'copy', studioLayoutText('Copy'), false);
	// Paste needs a snapshot, so it reads disabled until something is copied
	studioClipMenuRow(menu, 'paste', studioLayoutText('Paste'), !studioClipboard);
	// Only a loop track takes a drum loop; another track keeps the clip menu.
	var loopTrack = mixer[hit.ch] && mixer[hit.ch].armed && mixer[hit.ch].armed.state == 'loop';
	if (loopTrack) { studioLoopMenuRows(menu); }
	$('body').append(menu);
	var margin = 6;
	var left = Math.min(px, $(window).width() - menu.outerWidth() - margin);
	var top = Math.min(py, $(window).height() - menu.outerHeight() - margin);
	menu.css({ left: Math.max(margin, left), top: Math.max(margin, top) });
}

// A loop track with no take under the pointer still gets a menu: it offers the
// saved drum loops and nothing else.
function studioLoopMenu(ch, at, px, py) {
	$('.studio_menu').remove();
	studioClipMenuTarget = { ch: ch, take: null, t: at };
	var menu = $('<div class="studio_menu studio_clip_menu studio_drum_loop_menu"></div>').attr('data-channel', ch);
	studioLoopMenuRows(menu);
	$('body').append(menu);
	var margin = 6;
	var left = Math.min(px, $(window).width() - menu.outerWidth() - margin);
	var top = Math.min(py, $(window).height() - menu.outerHeight() - margin);
	menu.css({ left: Math.max(margin, left), top: Math.max(margin, top) });
}

// Build the take beside the split's right half: a hidden media element in the
// track container, then the object in the channel's list. A looping snapshot
// pastes as an ordinary clip.
function studioPasteTake(ch, t) {
	if (!studioClipboard) { return null; }
	var m = mixer[ch];
	if (!m) { return null; }
	if (!m.media) { m.media = {}; }
	if (!m.media.out) { m.media.out = []; }
	var clip = studioClipboard;
	var pasted = {
		uuid: clip.uuid || null,
		startTime: Math.max(0, t),
		offset: clip.offset || 0,
		duration: clip.duration || 0,
		status: 'stop',
		src: clip.src,
		encoding: clip.encoding,
		loop: false
	};
	// A saved clip already has a server file; an unsaved one must carry its blob
	// so the pasted copy gets uploaded too.
	if (!clip.uuid) { pasted.data = clip.data; }

	var el = document.createElement('video');
	el.className = 'studio_video';
	el.style.display = 'none';
	el.preload = 'auto';
	if (clip.src) { el.src = clip.src; }
	$('#studio_track_container').append(el);
	pasted.track = el;

	m.media.out.push(pasted);
	studioReindexTakes(ch);
	mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, pasted.startTime + (pasted.duration || 0));
	studioSelectedTake = { ch: ch, take: pasted };
	studioDrawChannel(ch);
	studioSaver();
	studioTakesChanged();
	return pasted;
}

$(document).on('contextmenu', '.track', function (e) {
	var hit = studioCanvasHit(this, e.clientX);
	if (!hit) { return; }
	e.preventDefault();
	studioSelectedTake = { ch: hit.ch, take: hit.take };
	studioDrawChannel(hit.ch);
	studioClipMenu(hit, e.clientX, e.clientY);
});

// A loop track that has no take under the pointer is the other place a saved
// drum loop can land. The first handler above has already declined the press
// (no take), so this one owns the menu and its click time.
$(document).on('contextmenu', '.track', function (e) {
	if (studioCanvasHit(this, e.clientX)) { return; }
	var ch = studioCanvasChannel(this);
	var loopTrack = mixer[ch] && mixer[ch].armed && mixer[ch].armed.state == 'loop';
	if (!loopTrack) { return; }
	e.preventDefault();
	studioLoopMenu(ch, studioCanvasTime(this, e.clientX), e.clientX, e.clientY);
});

$(document).on('click', '.studio_clip_menu .studio_menu_row', function (e) {
	e.preventDefault();
	var row = $(this);
	if (row.prop('disabled')) { return; }
	var loop = row.attr('data-loop');
	var hit = studioClipMenuTarget;
	if (loop !== undefined) {
		$('.studio_menu').remove();
		studioClipMenuTarget = null;
		if (!hit || typeof studioDrumsInsertLoop !== 'function') { return; }
		var item = studioDrumsLoopLibrary()[parseInt(loop, 10)];
		if (item) { studioDrumsInsertLoop(hit.ch, hit.t, item); }
		return;
	}
	var command = row.attr('data-command');
	$('.studio_menu').remove();
	studioClipMenuTarget = null;
	if (!hit || !hit.take) { return; }
	if (command == 'split') {
		studioSplitTake(hit.ch, hit.take, hit.t);
		studioDrawChannel(hit.ch);
		studioSaver();
	}
	else if (command == 'copy') {
		studioClipboard = studioClipSnapshot(hit.take);
	}
	else if (command == 'cut') {
		studioClipboard = studioClipSnapshot(hit.take);
		studioRemoveTake(hit.ch, hit.take);
	}
	else if (command == 'paste') {
		studioPasteTake(hit.ch, hit.t);
	}
});

// One menu on screen at a time: the next press elsewhere, Escape, or any scroll
// puts it away (the Clothesline menu's rules).
$(document).on('pointerdown', function (e) {
	if ($(e.target).closest('.studio_menu').length) { return; }
	$('.studio_menu').remove();
	studioClipMenuTarget = null;
});

$(document).on('keydown', function (e) {
	if (e.key == 'Escape' && $('.studio_menu').length) {
		$('.studio_menu').remove();
		studioClipMenuTarget = null;
	}
});

window.addEventListener('scroll', function () {
	$('.studio_menu').remove();
	studioClipMenuTarget = null;
}, true);

// Carry a take to another lane: the take object moves, it is never copied.
// Both channels are reindexed because the media element ids follow the array
// positions the server stores files by.
function studioMoveTake(take, from, to) {
	if (!take || !from || !to || from == to) { return false; }
	if (take.status == 'recording') { return false; }
	var media = mixer[from] && mixer[from].media;
	var target = mixer[to] && mixer[to].media;
	if (!media || !media.out || !target) { return false; }
	var index = media.out.indexOf(take);
	if (index == -1) { return false; }
	if (!target.out) { target.out = []; }
	media.out.splice(index, 1);
	target.out.push(take);
	studioReindexTakes(from);
	studioReindexTakes(to);
	if (studioSelectedTake && studioSelectedTake.take === take) { studioSelectedTake = { ch: to, take: take }; }
	return true;
}

$(document).on('pointerdown', '.track', function (e) {
	// only the primary button starts a drag or changes the selection; the
	// right button belongs to the clip menu
	if (e.button !== 0) { return; }
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
		// which lane is under the pointer? a drop there carries the take over
		var under = document.elementFromPoint ? document.elementFromPoint(e.originalEvent.clientX, e.originalEvent.clientY) : null;
		var lane = (under && under.closest) ? under.closest('.track') : null;
		var over = lane ? studioCanvasChannel(lane) : null;
		if (over && !mixer[over]) { over = null; }
		if (over != d.over) {
			var was = d.over;
			d.over = over;
			if (was && was != d.ch) { studioDrawChannel(was); }
			if (over && over != d.ch) { studioDrawChannel(over); }
		}
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
	var d = studioTakeDrag;
	studioTakeDrag = null;
	var from = d.ch;
	var to = d.over;
	// a drop on another lane moves the one take; a recording take stays put
	if (d.mode == 'move' && to && to != from) { studioMoveTake(d.take, from, to); }
	studioDrawChannel(from);
	if (to && to != from) { studioDrawChannel(to); }
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

$(document).on('click', '.channel, .studio_track_panel', function (e) {
	if ($(e.target).is('input, button, img, canvas, video, .armed')) { return; }
	$('.channel, .studio_track_panel').removeClass('selected_channel');
	$(this).addClass('selected_channel');
	var ch = ($(this).attr('class') || '').match(/channel_(\d+)/);
	if (ch) { studioSelectedChannel = ch[1]; }
	else if ($(this).attr('channel')) { studioSelectedChannel = $(this).attr('channel'); }
});

$(document).on('click', '.channel_fx_pedal', function () {
	var name = $(this).attr('hint');
	if (name) { studioRevealPedal(name); }
});

// Bring an inserted pedal's controls into view: open the pedalboard, scroll it
// to the pedal and flag it, so a channel badge leads you to its settings. A
// palette effect can be the same kind under another name (reverb vs reverb2),
// so a miss falls back to the shelf pedal of that kind.
function studioRevealPedal(name) {
	var pedal = $('#pedal_' + name);
	if (!pedal.length) {
		$('#pedalboard .pedal').each(function () {
			var id = String($(this).attr('id') || '').replace(/^pedal_/, '');
			if (studioEffectKind(id) === studioEffectKind(name)) { pedal = $(this); return false; }
		});
	}
	if (!pedal.length) { return; }
	var scroller = $('#studio_pedalboard_pedals');
	studioPedalboardOpen(true);
	var left = pedal.position().left + scroller.scrollLeft() - 40;
	scroller.stop().animate({ scrollLeft: Math.max(0, left) }, 200);
	pedal.addClass('pedal_revealed');
	clearTimeout(studioRevealPedal.timer);
	studioRevealPedal.timer = setTimeout(function () { pedal.removeClass('pedal_revealed'); }, 1600);
}

$(document).on('click', '#studio_new', function() {
	$('#studio').attr('uuid','').attr('name','');
	studioInit({ uuid: 'new', settings: [ { 'setting': 'last_song', 'value': 'new' }, { 'setting': 'channel_count', 'value': '1' } ] });
	$('#studio_song_select').val('none');
});

// One path for the Pedals button, the transport's old burger, the FX button and
// a channel badge: the sheet's visibility and its button stay in step.
function studioPedalboardOpen(show) {
	var board = $('#pedalboard');
	if (show === undefined) { show = !board.is(':visible'); }
	show = !!show;
	if (show) { board.show(); }
	else { board.hide(); }
	$('#studio_pedals').attr('aria-pressed', show ? 'true' : 'false');
	return show;
}

$(document).on('click', '#studio_pedals, #pedalboard_hamburger', function () {
	studioPedalboardOpen();
});

$(document).on('click', '#studio_toggle', function() {
	studioInit();
});

