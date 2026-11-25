function studioRecordOffset(ch) {
	var raw = mixer['time']['record_offset'];
	if (raw !== undefined && raw !== null && String(raw).length > 0) {
		var n = numeral(raw).value();
		if (n !== null && n !== undefined && !isNaN(n)) { return n / 1000; }
	}
	// A native engine's patch-cable loopback measures the device's whole round
	// trip, output plus capture. When it owns the interface that one number is
	// the take's offset; adding the browser's separate guesses on top would
	// count the output twice. With no measurement, fall back to the context and
	// the input track's own report.
	var backend = (typeof studioAudioBackend === 'function') ? studioAudioBackend() : 'browser';
	if (backend !== 'browser' && studioAudio.engineLatency > 0) { return studioAudio.engineLatency; }
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
// tempo change keeps it musical. A region set by the Select tool carries an
// explicit end in seconds instead, because a dragged span need not land on a
// bar line; that end wins over the bar arithmetic.
function studioLoopRegion() {
	var r = mixer['time'] && mixer['time']['loop_region'];
	if (!r) { return null; }
	var start = studioKnobNumber(r.start, 0);
	var end = studioKnobNumber(r.end, 0);
	if (end > start) { return { start: r.start, bars: r.bars, end: r.end }; }
	if (!(r.bars > 0)) { return null; }
	var bar = studioBarSeconds();
	return { start: r.start, bars: r.bars, end: r.start + (r.bars * bar) };
}

// Commit an explicit span (seconds) as the repeated region. The bar count is
// kept as a hint for the take-length snap, but the end is what the transport
// and the canvas honour. Selecting a range is a transport edit, so the loop
// button lights as ongoing and the song remembers both.
function studioSetLoopRange(start, end) {
	var from = studioKnobNumber(start, 0);
	var to = studioKnobNumber(end, 0);
	from = Math.max(0, from);
	if (!(to > from)) { return false; }
	mixer['time']['loop_region'] = {
		start: from,
		end: to,
		bars: Math.max(1, Math.round((to - from) / studioBarSeconds()))
	};
	mixer['time']['loop'] = 'ongoing';
	$('#studio_loop').attr('enabled', 'ongoing').attr('obg', 'rgb(211, 211, 211)').css({ 'background-color': 'red' });
	studioSaver();
	studioDrawTracks();
	return true;
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

// Cut a note list at a beat. A note that spans the cut becomes two: the left
// keeps its attack and stops on the cut, the right starts on the cut with what
// duration was left.
function studioNoteSplit(notes, at) {
	var left = [], right = [];
	(notes || []).forEach(function (note) {
		if (!note) { return; }
		var t = Number(note.t) || 0;
		var d = Math.max(0, Number(note.d) || 0);
		var copy = function (t2, d2) { return { n: note.n, t: t2, d: Math.max(0.015625, d2), v: note.v }; };
		if (t >= at - 1e-9) { right.push(copy(t - at, d)); }
		else if (t + d > at + 1e-9) {
			left.push(copy(t, at - t));
			right.push(copy(0, t + d - at));
		}
		else { left.push(copy(t, d)); }
	});
	return { left: left, right: right };
}

// Razor: cut a clip in two at timeline position t. Both halves share the source;
// the right half is a new in-point into it. A note clip instead cuts its notes
// at the split beat, and each half is rendered from its own notes.
function studioSplitTake(ch, take, t) {
	var media = mixer[ch] && mixer[ch].media;
	if (!media || !media.out) { return null; }
	var index = media.out.indexOf(take);
	if (index == -1) { return null; }
	var end = take.startTime + (take.duration || 0);
	if (t <= take.startTime + 0.02 || t >= end - 0.02) { return null; }

	var noteSplit = !!take.note_clip;
	var bpm = studioKnobNumber(mixer['time'] && mixer['time']['bpm'], 120) || 120;
	var beat = 60 / bpm;
	var splitBeat = noteSplit ? Math.max(0, (t - take.startTime) / beat) : 0;
	var halves = noteSplit ? studioNoteSplit(take.notes || [], splitBeat) : null;

	var right = {
		uuid: take.uuid || null,
		startTime: t,
		offset: (take.offset || 0) + (t - take.startTime),
		duration: end - t,
		status: 'stop',
		src: take.src,
		encoding: take.encoding
	};
	// A printed take already carries its Out pedals in its audio, and both
	// halves index the same printed buffer, so the right half must not run the
	// chain a second time on playback.
	if (!noteSplit && take.printed) { right.printed = true; }
	if (!noteSplit && take.buffer) { right.buffer = take.buffer; }
	// A razor cut ends the looper behaviour: both halves become ordinary clips.
	take.loop = false;
	right.loop = false;
	// A saved clip already has a server file, so both halves reference it. An
	// unsaved clip has to carry its blob so both halves get uploaded.
	if (!noteSplit && !take.uuid) { right.data = take.data; }
	// Both note halves get their own length and a fresh engine id; their notes
	// are cut at the split beat and re-rendered below.
	if (noteSplit) {
		right.uuid = null;
		right.src = null;
		delete right.data;
		right.encoding = 'audio/wav';
		right.note_clip = 1;
		right.notes = halves.right;
		right.patch = take.patch || null;
		right.beats = Math.max(0, studioNoteClipBeats(take) - splitBeat);
		right.duration = right.beats * beat;
		right.clip_id = studioNoteClipId();
	}

	var el = document.createElement('video');
	el.className = 'studio_video';
	el.style.display = 'none';
	el.preload = 'auto';
	if (take.src) { el.src = take.src; }
	$('#studio_track_container').append(el);
	right.track = el;

	if (noteSplit) {
		take.notes = halves.left;
		take.beats = splitBeat;
		take.duration = splitBeat * beat;
		take.clip_id = studioNoteClipId();
		take.note_clip = 1;
	}
	else {
		take.duration = t - take.startTime;
	}
	media.out.splice(index + 1, 0, right);
	studioReindexTakes(ch);
	if (noteSplit) {
		studioNoteClipRerender(ch, take);
		studioNoteClipRerender(ch, right);
	}
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

// ---- the saved synth loop library ------------------------------------------
//
// A synth loop is the sequencer grid plus the patch it played. The panel
// publishes the saved list and the song setting keeps it, exactly as the drum
// loops do; the track menu can then place one as an editable note clip.

function studioSynthLoopLibrary() {
	var library = window.jawnos_studio_synth_loops;
	if (!library || typeof library.length !== 'number') {
		library = [];
		window.jawnos_studio_synth_loops = library;
	}
	return library;
}

function studioSynthLoopPersist() {
	studioSaveSettings([{ setting: 'synth_loops', value: JSON.stringify(studioSynthLoopLibrary()) }]);
}

function studioSynthLoopOptions() {
	var select = $('#studio_synth_loops');
	if (!select.length) { return; }
	var chosen = select.val();
	select.empty();
	select.append($('<option></option>').attr('value', '').text(studioLayoutText('No saved loop')));
	studioSynthLoopLibrary().forEach(function (item, index) {
		if (!item || !item.name) { return; }
		select.append($('<option></option>').attr('value', String(index)).text(item.name));
	});
	if (chosen !== null && chosen !== undefined && select.find('option[value="' + chosen + '"]').length) {
		select.val(chosen);
	}
}

function studioSynthChosenLoop() {
	var select = $('#studio_synth_loops');
	if (!select.length) { return null; }
	var index = parseInt(select.val(), 10);
	var library = studioSynthLoopLibrary();
	if (!(index >= 0) || !library[index]) { return null; }
	return library[index];
}

// The sequencer grid in beats: step n is n/rate seconds from the loop start,
// each lit cell is its row above the root, and the grid's own steps/rate give
// the clip length. The gate is the sequencer's own 0.6 of a step.
function studioSynthSeqNotes(seq, bpm) {
	var beat = 60 / (studioKnobNumber(bpm, 120) || 120);
	var rate = Math.max(0.5, studioKnobNumber(seq.rate, 8) || 8);
	var steps = Math.max(1, Math.round(studioKnobNumber(seq.steps, 16) || 16));
	var rows = Math.max(1, Math.round(studioKnobNumber(seq.rows, 13) || 13));
	var root = Math.round(studioKnobNumber(seq.root, 60) || 60);
	var cells = seq.cells || {};
	var stepSeconds = 1 / rate;
	var gateSeconds = 0.6 / rate;
	var notes = [];
	for (var row = 0; row < rows; row++) {
		for (var step = 0; step < steps; step++) {
			if (!cells[row + ':' + step]) { continue; }
			notes.push({
				n: root + row,
				t: (step * stepSeconds) / beat,
				d: gateSeconds / beat,
				v: 0.85
			});
		}
	}
	notes.sort(function (a, b) { return (a.t - b.t) || (a.n - b.n); });
	return { notes: notes, beats: (steps * stepSeconds) / beat };
}

// Save the current grid and patch under a name; editing the sequencer afterwards
// cannot change the saved loop.
function studioSynthSaveLoop() {
	var synth = window.jawnosSynth;
	if (!synth || !synth.seq || typeof synth.seq.get !== 'function') { return false; }
	var name = String($('#studio_synth_save_name').val() || '').trim();
	if (!name) { return false; }
	var seq = synth.seq.get();
	var bpm = studioKnobNumber(mixer['time'] && mixer['time']['bpm'], 120) || 120;
	var grid = studioSynthSeqNotes(seq, bpm);
	var library = studioSynthLoopLibrary();
	library.push({
		name: name,
		patch: (typeof synth.getPatch === 'function') ? synth.getPatch() : null,
		notes: grid.notes,
		beats: grid.beats,
		seq: seq
	});
	studioSynthLoopPersist();
	studioSynthLoopOptions();
	$('#studio_synth_loops').val(String(library.length - 1));
	return true;
}

// Load a saved grid back into the sequencer and its rate/steps selects, then
// ask the panel to rebuild the cells.
function studioSynthLoadLoop() {
	var item = studioSynthChosenLoop();
	var synth = window.jawnosSynth;
	if (!item || !synth || !synth.seq) { return false; }
	var seq = item.seq || {};
	if (typeof synth.seq.set === 'function') {
		synth.seq.set({ rate: seq.rate, steps: seq.steps, root: seq.root });
	}
	if (typeof synth.seq.setCells === 'function') { synth.seq.setCells(seq.cells || {}); }
	var grid = (typeof synth.seq.get === 'function') ? synth.seq.get() : {};
	$('.synth_seq_rate').val(String(grid.rate));
	$('.synth_seq_steps').val(String(grid.steps));
	$(document).trigger('jawnos_synth_panel');
	return true;
}

function studioSynthDeleteLoop() {
	var select = $('#studio_synth_loops');
	var index = parseInt(select.val(), 10);
	var library = studioSynthLoopLibrary();
	if (!(index >= 0) || !library[index]) { return false; }
	library.splice(index, 1);
	studioSynthLoopPersist();
	studioSynthLoopOptions();
	return true;
}

$(document).on('click', '#studio_synth_save_loop', function (e) {
	e.preventDefault();
	studioSynthSaveLoop();
});

$(document).on('click', '#studio_synth_load_loop', function (e) {
	e.preventDefault();
	studioSynthLoadLoop();
});

$(document).on('click', '#studio_synth_delete_loop', function (e) {
	e.preventDefault();
	studioSynthDeleteLoop();
});

// The panel may be inserted after this file runs, so the list is filled on the
// same event that rebuilds its sequencer grid.
$(document).on('jawnos_synth_panel', function () { studioSynthLoopOptions(); });
$(function () { studioSynthLoopOptions(); });

// A saved synth loop becomes an editable note clip at the clicked time: the
// notes and patch are the source of truth, and the rendered WAV is its cache.
function studioSynthInsertLoop(ch, at, item) {
	ch = String(ch);
	if (!item || !item.name) { return null; }
	var m = mixer[ch];
	if (!m) { return null; }
	if (!m.media) { m.media = {}; }
	if (!m.media.out) { m.media.out = []; }
	var el = document.createElement('video');
	el.className = 'studio_video';
	el.style.display = 'none';
	el.preload = 'auto';
	$('#studio_track_container').append(el);
	var patch = item.patch ? JSON.parse(JSON.stringify(item.patch)) : null;
	if (!patch && window.jawnosSynth && typeof window.jawnosSynth.getPatch === 'function') {
		patch = window.jawnosSynth.getPatch();
	}
	var take = {
		uuid: null,
		startTime: Math.max(0, at || 0),
		offset: 0,
		duration: 0,
		status: 'stop',
		note_clip: 1,
		notes: JSON.parse(JSON.stringify(item.notes || [])),
		patch: patch,
		beats: Number(item.beats) || 0,
		clip_id: studioNoteClipId(),
		loop: true,
		encoding: 'audio/wav',
		track: el
	};
	take.duration = studioNoteClipSeconds(take);
	m.media.out.push(take);
	studioReindexTakes(ch);
	mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + take.duration);
	studioNoteClipLoad(take).then(function () { studioDrawChannel(ch); });
	studioSelectedTake = { ch: ch, take: take };
	studioSaver();
	studioDrawChannel(ch);
	studioTakesChanged();
	return take;
}

// The synth loop section of a loop track's menu, beside the drum loops.
function studioSynthLoopMenuRows(menu) {
	$('<div class="studio_menu_head"></div>').text(studioLayoutText('Add synth loop')).appendTo(menu);
	var library = studioSynthLoopLibrary();
	if (!library.length) {
		$('<button type="button" class="studio_menu_row" disabled></button>')
			.text(studioLayoutText('No saved loops'))
			.appendTo(menu);
		return;
	}
	library.forEach(function (item, index) {
		if (!item || !item.name) { return; }
		$('<button type="button" class="studio_menu_row studio_synth_loop_row"></button>')
			.attr('data-synth-loop', index)
			.text(item.name)
			.appendTo(menu);
	});
}

// What a copy keeps: everything needed to place the clip again on any track.
// A saved clip points at its file by uuid; an unsaved one carries its blob. A
// note clip's notes travel instead of its rendered cache.
function studioClipSnapshot(take) {
	if (!take) { return null; }
	return {
		src: take.src,
		uuid: take.uuid || null,
		data: take.data,
		buffer: take.buffer,
		offset: take.offset || 0,
		duration: take.duration || 0,
		encoding: take.encoding,
		loop: !!take.loop,
		printed: !!take.printed,
		note_clip: take.note_clip ? 1 : 0,
		notes: take.notes ? JSON.parse(JSON.stringify(take.notes)) : null,
		patch: take.patch ? JSON.parse(JSON.stringify(take.patch)) : null,
		beats: take.beats || 0
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
	// A note-backed clip opens its notes in the sixth panel; an ordinary audio
	// take has none, so there is no row to offer.
	if (hit.take.note_clip || hit.take.notes) {
		studioClipMenuRow(menu, 'notes', studioLayoutText('Notes'), false);
	}
	$('<div class="studio_menu_head"></div>').text(studioLayoutText('Take')).appendTo(menu);
	studioClipMenuRow(menu, 'delete', studioLayoutText('Delete'), false);
	studioClipMenuRow(menu, 'bounce', studioLayoutText('Bounce'), false);
	// Only a loop track takes a drum or synth loop; another track keeps the clip
	// menu.
	var loopTrack = mixer[hit.ch] && mixer[hit.ch].armed && mixer[hit.ch].armed.state == 'loop';
	if (loopTrack) {
		studioLoopMenuRows(menu);
		studioSynthLoopMenuRows(menu);
	}
	$('body').append(menu);
	var margin = 6;
	var left = Math.min(px, $(window).width() - menu.outerWidth() - margin);
	var top = Math.min(py, $(window).height() - menu.outerHeight() - margin);
	menu.css({ left: Math.max(margin, left), top: Math.max(margin, top) });
}

// A loop track with no take under the pointer still gets a menu: it offers the
// saved drum and synth loops and nothing else.
function studioLoopMenu(ch, at, px, py) {
	$('.studio_menu').remove();
	studioClipMenuTarget = { ch: ch, take: null, t: at };
	var menu = $('<div class="studio_menu studio_clip_menu studio_drum_loop_menu"></div>').attr('data-channel', ch);
	studioLoopMenuRows(menu);
	studioSynthLoopMenuRows(menu);
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
		uuid: clip.note_clip ? null : (clip.uuid || null),
		startTime: Math.max(0, t),
		offset: clip.offset || 0,
		duration: clip.duration || 0,
		status: 'stop',
		src: clip.note_clip ? null : clip.src,
		encoding: clip.encoding,
		loop: false
	};
	// A copied note clip carries its notes and patch, gets a fresh engine id and
	// is rendered from them; its rendered blob is never copied.
	if (clip.note_clip) {
		pasted.note_clip = 1;
		pasted.notes = clip.notes ? JSON.parse(JSON.stringify(clip.notes)) : [];
		pasted.patch = clip.patch ? JSON.parse(JSON.stringify(clip.patch)) : null;
		pasted.beats = clip.beats || 0;
		pasted.clip_id = studioNoteClipId();
		pasted.duration = studioNoteClipSeconds(pasted) || pasted.duration;
	}
	// A copied printed take is already wet, so it keeps that flag and its
	// rendered buffer; otherwise the copy would run the Out chain again.
	if (!clip.note_clip && clip.printed) { pasted.printed = true; }
	if (!clip.note_clip && clip.buffer) { pasted.buffer = clip.buffer; }
	// A saved clip already has a server file; an unsaved one must carry its blob
	// so the pasted copy gets uploaded too. A note clip carries neither.
	if (!clip.note_clip) {
		if (!clip.uuid) { pasted.data = clip.data; }
	}

	var el = document.createElement('video');
	el.className = 'studio_video';
	el.style.display = 'none';
	el.preload = 'auto';
	if (clip.src) { el.src = clip.src; }
	$('#studio_track_container').append(el);
	pasted.track = el;

	m.media.out.push(pasted);
	studioReindexTakes(ch);
	if (pasted.note_clip) { studioNoteClipRerender(ch, pasted); }
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
	var synthLoop = row.attr('data-synth-loop');
	var hit = studioClipMenuTarget;
	if (loop !== undefined) {
		$('.studio_menu').remove();
		studioClipMenuTarget = null;
		if (!hit || typeof studioDrumsInsertLoop !== 'function') { return; }
		var item = studioDrumsLoopLibrary()[parseInt(loop, 10)];
		if (item) { studioDrumsInsertLoop(hit.ch, hit.t, item); }
		return;
	}
	if (synthLoop !== undefined) {
		$('.studio_menu').remove();
		studioClipMenuTarget = null;
		if (!hit) { return; }
		var synthItem = studioSynthLoopLibrary()[parseInt(synthLoop, 10)];
		if (synthItem) { studioSynthInsertLoop(hit.ch, hit.t, synthItem); }
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
	else if (command == 'notes') {
		if (typeof window.studioNotesOpen === 'function') { window.studioNotesOpen(hit.ch, hit.take); }
	}
	else if (command == 'delete') {
		studioRemoveTake(hit.ch, hit.take);
	}
	else if (command == 'bounce') {
		// A printed take is ordinary audio: its notes no longer edit it.
		var bounced = studioBounceTake(hit.ch, hit.take);
		if (bounced && typeof bounced.then === 'function') {
			bounced.then(function (ok) {
				if (!ok) { return; }
				delete hit.take.note_clip;
				delete hit.take.notes;
				studioSaver();
			});
		}
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

$(document).on('click', '.channel_fx_pedal, .channel_fx_text', function () {
	var holder = $(this).closest('.channel_fx');
	if (holder.attr('channel')) { studioSelectedChannel = holder.attr('channel'); }
	var name = $(this).attr('hint');
	if (name) { studioRevealPedal(name); }
});

// Bring an inserted pedal's row into view: open the pedalboard on the chain that
// holds it, scroll the rack to it and flag it, so a channel badge leads you to
// its controls. A palette effect can be the same kind under another name
// (reverb vs reverb2), so a miss falls back to the row of that kind.
function studioRevealPedal(name) {
	var ch = studioPaletteChannel();
	var c = studioAudio.channels[ch];
	if (c) {
		var chain = c.insertByName[name] ? 'in' : (c.outInsertByName[name] ? 'out' : studioChannelChain(ch));
		studioSetChannelChain(ch, chain);
	}
	studioPedalboardOpen(true);
	var row = $('#studio_pedalboard_rack .studio_rack_tile[insert="' + name + '"]');
	if (!row.length) {
		row = $('#studio_pedalboard_rack .studio_rack_tile').filter(function () {
			return studioEffectKind($(this).attr('insert')) === studioEffectKind(name);
		}).first();
	}
	if (!row.length) { return; }
	var rack = $('#studio_pedalboard_rack');
	var top = row.position().top + rack.scrollTop() - 8;
	rack.stop().animate({ scrollTop: Math.max(0, top) }, 200);
	row.addClass('pedal_revealed');
	clearTimeout(studioRevealPedal.timer);
	studioRevealPedal.timer = setTimeout(function () { row.removeClass('pedal_revealed'); }, 1600);
}

$(document).on('click', '#studio_new', function() {
	$('#studio').attr('uuid','').attr('name','');
	studioInit({ uuid: 'new', settings: [ { 'setting': 'last_song', 'value': 'new' }, { 'setting': 'channel_count', 'value': '1' } ] });
	$('#studio_song_select').val('none');
});

// One path for the Pedals button, the transport's old burger, the FX button and
// a channel badge: the sheet's visibility and its button stay in step. The
// sheet carries the selected track's chain, so it is drawn as it opens.
function studioPedalboardOpen(show) {
	var board = $('#pedalboard');
	if (show === undefined) { show = !board.is(':visible'); }
	show = !!show;
	if (show) { board.show(); }
	else { board.hide(); }
	$('#studio_pedals').attr('aria-pressed', show ? 'true' : 'false');
	if (show && typeof studioRackRender === 'function') { studioRackRender(studioPaletteChannel()); }
	return show;
}

$(document).on('click', '#studio_pedals, #pedalboard_hamburger', function () {
	studioPedalboardOpen();
});

$(document).on('click', '#studio_toggle', function() {
	studioInit();
});

