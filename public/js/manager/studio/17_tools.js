// ===========================================================================
// Timeline tools: cursor, cross-lane select, and cut
// ===========================================================================
// The tool buttons live on the Tracks title bar. Select draws a time range over
// one or more lanes and offers Loop, Bounce and Export for it; Cut splits a take
// at the pointer. Cursor leaves the existing move/trim editing alone.

// The chosen tool. Cursor is the default so a song opened before this part
// loaded still edits the way it always did.
var studioTool = 'cursor';

// The last Select drag, or null. `channels` is channel -> true; `all` says the
// drag started on the ruler, which selects every lane that has one.
var studioSelection = null;

// In-flight drags. Only one of the two is ever non-null: the tool decides
// which of the capture-phase handlers claims the pointer.
var studioSelectDrag = null;
var studioCutDrag = null;
var studioSelectionDrawQueued = false;
var studioSelectionExporting = false;

function studioToolText(text) {
	var translated = (typeof jawnosT === 'function') ? jawnosT(text) : text;
	return (translated === undefined || translated === null) ? text : translated;
}

// ---- tool state -------------------------------------------------------------

// Select and Cut change the cursor over the lanes and the ruler (the CSS owns
// the actual cursor); Cursor leaves the lane pointer to the editing code.
function studioToolSet(tool) {
	tool = String(tool || 'cursor');
	if (tool !== 'cursor' && tool !== 'select' && tool !== 'cut') { tool = 'cursor'; }
	studioTool = tool;
	$('.studio_tool').each(function () {
		var mine = String($(this).attr('data-tool') || '');
		$(this).attr('aria-pressed', mine === tool ? 'true' : 'false');
	});
	var surfaces = [document.getElementById('studio_viewer'), document.getElementById('studio_ruler')];
	surfaces.forEach(function (el) {
		if (!el || !el.classList) { return; }
		el.classList.toggle('studio_tool_select', tool === 'select');
		el.classList.toggle('studio_tool_cut', tool === 'cut');
	});
	if (tool !== 'cut') { studioCutDrag = null; }
}

$(document).on('click', '.studio_tool', function () {
	studioToolSet($(this).attr('data-tool'));
});

// ---- the selection model ----------------------------------------------------

function studioSelectionChannels(sel) {
	var s = sel || studioSelection;
	if (!s || !s.channels) { return []; }
	return Object.keys(s.channels).filter(function (ch) {
		return /^[0-9]+$/.test(ch) && s.channels[ch];
	}).sort(function (a, b) { return (a - 0) - (b - 0); });
}

function studioToolTime(seconds) {
	var s = Math.max(0, (seconds || 0) - 0);
	var m = Math.floor(s / 60);
	var rest = s - (m * 60);
	return m + ':' + (rest < 10 ? '0' : '') + rest.toFixed(1);
}

function studioSelectionLabel(sel) {
	var s = sel || studioSelection;
	if (!s) { return ''; }
	var count = studioSelectionChannels(s).length;
	return studioToolText('Selection') + ' ' + studioToolTime(s.start) + ' \u2013 ' + studioToolTime(s.end)
		+ ' \u00b7 ' + count + ' ' + studioToolText(count === 1 ? 'track' : 'tracks');
}

function studioSelectionStatus(text) {
	var el = document.getElementById('studio_selection_label');
	if (el) { el.textContent = text || ''; }
}

function studioSelectionBarShow(show) {
	var bar = document.getElementById('studio_selection_bar');
	if (!bar) { return; }
	bar.style.display = show ? '' : 'none';
}

function studioSelectionClear() {
	studioSelection = null;
	studioSelectDrag = null;
	studioCutDrag = null;
	studioSelectionBarShow(false);
	studioSelectionStatus('');
	var overlay = document.getElementById('studio_selection_overlay');
	if (overlay) { overlay.innerHTML = ''; }
	var ruler = document.getElementById('studio_ruler_selection');
	if (ruler) { ruler.style.display = 'none'; }
}

// Accept a finished drag. A span too short to hear is a click, so it clears
// rather than leaving an invisible selection behind.
function studioSelectionSet(sel) {
	if (!sel || !(sel.end - sel.start > 0.01)) { studioSelectionClear(); return; }
	studioSelection = sel;
	studioSelectionBarShow(true);
	studioSelectionStatus(studioSelectionLabel(sel));
	studioSelectionDraw();
}

// ---- geometry ---------------------------------------------------------------

// Every channel with a lane, in the row order the viewer shows them.
function studioToolLaneOrder() {
	var viewer = document.getElementById('studio_viewer');
	var out = [];
	if (!viewer) { return out; }
	var rows = viewer.getElementsByClassName('studio_track');
	for (var i = 0; i < rows.length; i++) {
		var ch = rows[i].getAttribute('data-channel') || '';
		if (!/^[0-9]+$/.test(ch)) { continue; }
		if (!rows[i].querySelector('canvas.track')) { continue; }
		out.push(ch);
	}
	return out;
}

function studioToolLaneCanvas(target) {
	if (!target || !target.closest) { return null; }
	var canvas = target.closest('canvas.track');
	if (!canvas) { return null; }
	var viewer = document.getElementById('studio_viewer');
	return (viewer && viewer.contains(canvas)) ? canvas : null;
}

function studioToolRulerCanvas(target) {
	if (!target || !target.closest) { return null; }
	return target.closest('#studio_ruler_canvas');
}

// The lane under a viewport point, for a drag that leaves the lane it began on.
function studioToolLaneAt(clientX, clientY) {
	if (!document.elementFromPoint) { return null; }
	var under = document.elementFromPoint(clientX, clientY);
	if (!under || !under.closest) { return null; }
	var canvas = under.closest('canvas.track');
	if (!canvas) { return null; }
	var viewer = document.getElementById('studio_viewer');
	return (viewer && viewer.contains(canvas)) ? canvas : null;
}

// A lane and the ruler share the timeline's own scale. The ruler maps a click
// through the zoomed window rect; a lane uses the editing code's helper.
function studioToolRulerTime(canvas, clientX) {
	var rect = studioTimelineWindowRect(canvas);
	if (!rect.width) { return 0; }
	var duration = studioTimelineDuration();
	var t = ((clientX - rect.left) / rect.width) * duration;
	return Math.max(0, Math.min(duration, t));
}

function studioToolTimeAt(canvas, clientX, isRuler) {
	if (isRuler) { return studioToolRulerTime(canvas, clientX); }
	return studioCanvasTime(canvas, clientX);
}

// The grid a recording locks to, applied to a selection edge. Off/free leaves
// the pointer exactly where it is.
function studioToolSnap(seconds) {
	var unit = (typeof studioSnapUnit === 'function') ? studioSnapUnit() : 0;
	if (!(unit > 0)) { return seconds; }
	return Math.round(seconds / unit) * unit;
}

// Build the model from a drag: the earlier edge is the start, and the lanes
// between the lane the drag began on and the lane under the pointer are all
// selected. A drag from the ruler selects every lane that has one.
function studioToolSelectionFromDrag(drag) {
	var start = Math.min(drag.start, drag.end);
	var end = Math.max(drag.start, drag.end);
	var picked = {};
	if (drag.ruler) {
		studioToolLaneOrder().forEach(function (ch) { picked[ch] = true; });
	}
	else {
		var order = studioToolLaneOrder();
		var from = order.indexOf(String(drag.laneStart));
		var to = order.indexOf(String(drag.laneEnd));
		if (from < 0 && to < 0 && drag.laneStart) {
			// the lane vanished under the drag (a row was removed); keep that one
			picked[String(drag.laneStart)] = true;
		}
		else {
			if (from < 0) { from = to; }
			if (to < 0) { to = from; }
			var lo = Math.min(from, to);
			var hi = Math.max(from, to);
			for (var i = lo; i <= hi && i < order.length; i++) {
				if (i >= 0) { picked[order[i]] = true; }
			}
		}
	}
	return { start: start, end: end, channels: picked, all: !!drag.ruler };
}

// ---- drawing ----------------------------------------------------------------

function studioSelectionDrawRuler() {
	var box = document.getElementById('studio_ruler_selection');
	if (!box) { return; }
	var sel = studioSelection;
	var ruler = document.getElementById('studio_ruler');
	var canvas = document.getElementById('studio_ruler_canvas');
	if (!sel || !ruler || !canvas) { box.style.display = 'none'; return; }
	var rr = ruler.getBoundingClientRect();
	var cr = canvas.getBoundingClientRect();
	var width = cr.width || canvas.clientWidth || 0;
	if (!width) { box.style.display = 'none'; return; }
	var x1 = Math.max(0, Math.min(width, studioTimelineXAt(canvas, sel.start)));
	var x2 = Math.max(0, Math.min(width, studioTimelineXAt(canvas, sel.end)));
	box.style.display = '';
	box.style.left = ((cr.left - rr.left) + Math.min(x1, x2)) + 'px';
	box.style.width = Math.max(1, Math.abs(x2 - x1)) + 'px';
}

function studioSelectionDrawLanes() {
	var overlay = document.getElementById('studio_selection_overlay');
	if (!overlay) { return; }
	overlay.innerHTML = '';
	var sel = studioSelection;
	if (!sel) { return; }
	var viewer = document.getElementById('studio_viewer');
	if (!viewer) { return; }
	var ob = overlay.getBoundingClientRect();
	var vb = viewer.getBoundingClientRect();
	studioSelectionChannels(sel).forEach(function (ch) {
		var row = viewer.querySelector('.studio_track[data-channel="' + ch + '"]');
		if (!row) { return; }
		var canvas = row.querySelector('canvas.track');
		if (!canvas) { return; }
		var cr = canvas.getBoundingClientRect();
		if (!cr.width) { return; }
		var x1 = Math.max(0, Math.min(cr.width, studioTimelineXAt(canvas, sel.start)));
		var x2 = Math.max(0, Math.min(cr.width, studioTimelineXAt(canvas, sel.end)));
		var left = Math.min(x1, x2);
		var width = Math.abs(x2 - x1);
		if (!(width >= 1)) { return; }
		var top = Math.max(cr.top, vb.top) - ob.top;
		var bottom = Math.min(cr.bottom, vb.bottom) - ob.top;
		if (!(bottom > top)) { return; }
		var lane = document.createElement('div');
		lane.className = 'studio_selection_lane';
		lane.style.left = ((cr.left - ob.left) + left) + 'px';
		lane.style.top = top + 'px';
		lane.style.width = width + 'px';
		lane.style.height = (bottom - top) + 'px';
		overlay.appendChild(lane);
	});
}

function studioSelectionDraw() {
	studioSelectionDrawRuler();
	studioSelectionDrawLanes();
}

// The overlay is a screen-space layer, so a scroll or a resize moves the lanes
// under it. One rAF after either keeps it lined up with the canvas painting.
function studioSelectionQueueDraw() {
	if (!studioSelection || studioSelectionDrawQueued) { return; }
	studioSelectionDrawQueued = true;
	var run = function () {
		studioSelectionDrawQueued = false;
		if (studioSelection) { studioSelectionDraw(); }
	};
	if (window.requestAnimationFrame) { window.requestAnimationFrame(run); }
	else { window.setTimeout(run, 16); }
}

document.addEventListener('scroll', function (event) {
	if (!event.target || event.target.id !== 'studio_viewer') { return; }
	studioSelectionQueueDraw();
}, true);

window.addEventListener('resize', function () {
	studioSelectionQueueDraw();
});

// ---- the Select tool --------------------------------------------------------
// Captured on the document so the lane's own move/trim handler never sees the
// press. A pointer that is not over a lane or the ruler falls through.

document.addEventListener('pointerdown', function (event) {
	if (studioTool !== 'select') { return; }
	if (event.button !== undefined && event.button !== 0) { return; }
	var rulerCanvas = studioToolRulerCanvas(event.target);
	var laneCanvas = rulerCanvas ? null : studioToolLaneCanvas(event.target);
	var canvas = rulerCanvas || laneCanvas;
	if (!canvas) { return; }
	event.preventDefault();
	event.stopPropagation();
	var t = studioToolSnap(studioToolTimeAt(canvas, event.clientX, !!rulerCanvas));
	var lane = laneCanvas ? studioCanvasChannel(laneCanvas) : null;
	studioSelectDrag = {
		canvas: canvas,
		ruler: !!rulerCanvas,
		laneStart: lane,
		laneEnd: lane,
		start: t,
		end: t,
		x: event.clientX
	};
	studioSelection = null;
	studioSelectionBarShow(false);
	studioSelectionDraw();
}, true);

document.addEventListener('pointermove', function (event) {
	if (!studioSelectDrag) { return; }
	event.preventDefault();
	var drag = studioSelectDrag;
	drag.x = event.clientX;
	drag.end = studioToolSnap(studioToolTimeAt(drag.canvas, event.clientX, drag.ruler));
	if (!drag.ruler) {
		var laneCanvas = studioToolLaneAt(event.clientX, event.clientY);
		var lane = laneCanvas ? studioCanvasChannel(laneCanvas) : null;
		if (lane) { drag.laneEnd = lane; }
	}
	studioSelection = studioToolSelectionFromDrag(drag);
	studioSelectionDraw();
}, true);

document.addEventListener('pointerup', function (event) {
	if (!studioSelectDrag) { return; }
	var drag = studioSelectDrag;
	studioSelectDrag = null;
	event.preventDefault();
	event.stopPropagation();
	if (!(Math.abs(drag.end - drag.start) > 0.01)) { studioSelectionClear(); return; }
	studioSelectionSet(studioToolSelectionFromDrag(drag));
}, true);

document.addEventListener('pointercancel', function () {
	if (studioSelectDrag) { studioSelectDrag = null; studioSelectionClear(); }
	if (studioCutDrag) { studioCutDrag = null; }
}, true);

// A press with Select selected is a drag, never a seek or a clip selection: the
// click and double-click the browser makes afterwards are swallowed here.
document.addEventListener('click', function (event) {
	if (studioTool !== 'select') { return; }
	if (!studioToolRulerCanvas(event.target) && !studioToolLaneCanvas(event.target)) { return; }
	event.preventDefault();
	event.stopPropagation();
}, true);

document.addEventListener('dblclick', function (event) {
	if (studioTool !== 'select') { return; }
	if (!studioToolRulerCanvas(event.target) && !studioToolLaneCanvas(event.target)) { return; }
	event.preventDefault();
	event.stopPropagation();
}, true);

document.addEventListener('keydown', function (event) {
	if (event.key === 'Escape' && studioSelection) { studioSelectionClear(); }
}, true);

// ---- the Cut tool -----------------------------------------------------------
// A press on a lane is a razor: the take under the pointer is split at that
// time. A vertical drag cuts every lane it crosses at the same time.

document.addEventListener('pointerdown', function (event) {
	if (studioTool !== 'cut') { return; }
	if (event.button !== undefined && event.button !== 0) { return; }
	var canvas = studioToolLaneCanvas(event.target);
	if (!canvas) { return; }
	event.preventDefault();
	event.stopPropagation();
	studioCutDrag = { x: event.clientX, canvas: canvas, lanes: [canvas] };
}, true);

document.addEventListener('pointermove', function (event) {
	if (!studioCutDrag) { return; }
	event.preventDefault();
	var canvas = studioToolLaneAt(event.clientX, event.clientY);
	if (canvas && studioCutDrag.lanes.indexOf(canvas) === -1) { studioCutDrag.lanes.push(canvas); }
}, true);

document.addEventListener('pointerup', function (event) {
	if (!studioCutDrag) { return; }
	var drag = studioCutDrag;
	studioCutDrag = null;
	event.preventDefault();
	event.stopPropagation();
	var touched = [];
	drag.lanes.forEach(function (canvas) {
		var ch = studioCanvasChannel(canvas);
		if (!ch) { return; }
		var hit = (typeof studioCanvasHit === 'function') ? studioCanvasHit(canvas, drag.x) : null;
		if (!hit || !hit.take) { return; }
		var t = hit.t;
		var unit = (typeof studioSnapUnit === 'function') ? studioSnapUnit() : 0;
		if (unit > 0) {
			var snapped = Math.round(t / unit) * unit;
			var end = hit.take.startTime + (hit.take.duration || 0);
			if (snapped > hit.take.startTime + 0.02 && snapped < end - 0.02) { t = snapped; }
		}
		var right = studioSplitTake(ch, hit.take, t);
		if (right && touched.indexOf(ch) === -1) { touched.push(ch); }
	});
	if (!touched.length) { return; }
	touched.forEach(function (ch) {
		if (typeof studioDrawChannel === 'function') { studioDrawChannel(ch); }
	});
	if (typeof studioSaver === 'function') { studioSaver(); }
	if (typeof studioTakesChanged === 'function') { studioTakesChanged(); }
}, true);

// ---- the selection bar's actions -------------------------------------------

function studioSelectionLoop() {
	var sel = studioSelection;
	if (!sel) { return; }
	if (typeof studioSetLoopRange === 'function') {
		studioSetLoopRange(sel.start, sel.end);
		studioSelectionStatus(studioToolText('Looping the selection.'));
		return;
	}
	// Fallback until the transport's own range helper lands: the region the
	// transport already repeats is the same record, in whole bars.
	var bar = (typeof studioBarSeconds === 'function') ? studioBarSeconds() : 2;
	var bars = Math.max(1, Math.round((sel.end - sel.start) / bar));
	if (!mixer['time']) { mixer['time'] = {}; }
	mixer['time']['loop_region'] = { start: sel.start, end: sel.end, bars: bars };
	mixer['time']['loop'] = 'ongoing';
	var loop = $('#studio_loop');
	if (loop && loop.length) {
		loop.attr('enabled', 'ongoing').attr('obg', 'rgb(211, 211, 211)').css('background-color', 'yellow');
	}
	if (typeof studioSaver === 'function') { studioSaver(); }
	if (typeof studioDrawTracks === 'function') { studioDrawTracks(); }
	studioSelectionStatus(studioToolText('Looping the selection.'));
}

function studioSelectionBounce() {
	var sel = studioSelection;
	if (!sel) { return; }
	if (typeof studioBounceSelection === 'function') {
		studioBounceSelection(sel.start, sel.end, sel.channels);
		studioSelectionStatus(studioToolText('Bouncing the selection\u2026'));
		return;
	}
	studioSelectionStatus(studioToolText('The bounce step is not ready yet.'));
}

function studioSelectionMasterWanted() {
	var box = document.getElementById('studio_export_master');
	return !!(box && box.checked);
}

function studioSelectionFormat() {
	if (typeof studioExportFormat === 'function') { return studioExportFormat(); }
	var el = document.getElementById('studio_export_format');
	var format = String((el && el.value) || 'wav').toLowerCase();
	return (format === 'wav' || format === 'mp3' || format === 'flac') ? format : 'wav';
}

function studioSelectionBitrate() {
	if (typeof studioExportBitrate === 'function') { return studioExportBitrate(); }
	var n = parseInt((document.getElementById('studio_export_bitrate') || {}).value, 10);
	if (!isFinite(n)) { n = 192; }
	return Math.max(64, Math.min(320, n));
}

// Copy the whole-song render between two times. The dest buffer is made on the
// same context, so the slice keeps the render's rate and channel count.
function studioSelectionSlice(ctx, buffer, start, end) {
	var rate = buffer.sampleRate || 44100;
	var first = Math.max(0, Math.floor((start || 0) * rate));
	var last = Math.min(buffer.length || 0, Math.ceil((end || 0) * rate));
	if (!(last > first)) {
		first = Math.max(0, Math.min(first, (buffer.length || 1) - 1));
		last = Math.min(buffer.length || (first + 1), first + 1);
	}
	var frames = Math.max(1, last - first);
	var channels = Math.max(1, buffer.numberOfChannels || 1);
	var out = ctx.createBuffer(channels, frames, rate);
	for (var c = 0; c < channels; c++) {
		var from = buffer.getChannelData(c);
		var to = out.getChannelData(c);
		to.set(from.subarray(first, first + frames));
	}
	return out;
}

// The selected channels that actually carry a take. A channel with no take is
// left out, the same way a whole-mix export leaves it out.
function studioSelectionEntries(sel) {
	if (typeof studioExportChannels !== 'function') { return []; }
	return studioExportChannels().filter(function (entry) {
		return !!entry && !!entry.channel && !!(sel.channels && sel.channels[entry.channel]);
	});
}

async function studioSelectionExport() {
	var sel = studioSelection;
	if (!sel || studioSelectionExporting) { return; }
	var song = $('#studio');
	var uuid = song.attr('uuid');
	var name = song.attr('name');
	if (!uuid || !name) {
		studioSelectionStatus(studioToolText('Save the song before exporting its selection.'));
		return;
	}
	var entries = studioSelectionEntries(sel);
	if (!entries.length) {
		studioSelectionStatus(studioToolText('There are no takes in the selection to export.'));
		return;
	}
	if (typeof studioExportOffline !== 'function' || typeof studioBufferToWav !== 'function') {
		studioSelectionStatus(studioToolText('The export step is not ready yet.'));
		return;
	}
	studioSelectionExporting = true;
	try {
		studioSelectionStatus(studioToolText('Rendering the selection\u2026'));
		var includeMaster = studioSelectionMasterWanted();
		var offline = studioExportOffline(entries, includeMaster);
		for (var i = 0; i < offline.inputs.length; i++) {
			var input = offline.inputs[i];
			for (var j = 0; j < input.takes.length; j++) {
				var take = input.takes[j];
				if (!take || take.status == 'recording') { continue; }
				if (typeof studioExportTakeIsVideo === 'function' && studioExportTakeIsVideo(take)) { continue; }
				var buffer = await studioExportTakeBuffer(offline.ctx, take);
				if (!buffer) { continue; }
				var destination = (take.printed && input.dry) ? input.dry : input.input;
				studioExportSchedule(offline.ctx, destination, take, buffer, offline.duration);
			}
		}

		var rendered = await offline.ctx.startRendering();
		var sliced = studioSelectionSlice(offline.ctx, rendered, sel.start, sel.end);
		var wav = studioBufferToWav(sliced);

		var form = new FormData();
		form.append('uuid', uuid);
		form.append('name', name + ' selection');
		form.append('format', studioSelectionFormat());
		form.append('bitrate', String(studioSelectionBitrate()));
		form.append('master', includeMaster ? '1' : '0');
		form.append('audio', wav, (name + ' selection') + '.wav');

		var response = await fetch('/manager/studio/export', { method: 'POST', body: form });
		var answer = null;
		try { answer = await response.json(); }
		catch (e) { answer = null; }
		if (!response.ok || !answer || answer.ok !== 1) {
			throw new Error((answer && answer.error) || ('the server answered ' + (response.status || '?')));
		}
		studioSelectionStatus(studioToolText('Selection attached.'));
	}
	catch (error) {
		studioSelectionStatus(studioToolText('The export failed.')
			+ ' ' + ((error && error.message) ? error.message : ''));
	}
	finally {
		studioSelectionExporting = false;
	}
}

$(document).on('click', '#studio_selection_loop', studioSelectionLoop);
$(document).on('click', '#studio_selection_bounce', studioSelectionBounce);
$(document).on('click', '#studio_selection_export', function () { studioSelectionExport(); });
$(document).on('click', '#studio_selection_clear', studioSelectionClear);
