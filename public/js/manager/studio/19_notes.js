// ===========================================================================
// The note editor: a piano roll over one note clip
// ===========================================================================
//
// A note clip is an ordinary take carrying { note_clip, notes, beats, patch }.
// Each note is { n, t, d, v }: `n` is MIDI 0..127, `t` and `d` are BEATS from
// the clip start, and `v` is a velocity 0..1. Beats (not seconds) are the unit,
// so a tempo change restretches the clip without touching a note; the clip's
// length is `take.beats` and a loop repeats it every `beats`.
//
// The panel is the sixth interior Studio window. Its geometry and the take that
// is open come from the integrator (`studioNotesOpen(ch, take)`); this file only
// draws and edits. Everything it writes is `take.notes` and `take.beats`, then
// `studioSaver()`, then (debounced) `studioNoteClipRerender(ch, take)` so the
// clip's audio cache follows the notes.
//
// Mouse: drag a block to change time + pitch, drag its right edge to change the
// duration, click empty grid to add one, right-click a block for velocity or
// Delete. Snap is a division of a beat; Off means free placement and a quarter
// beat is the minimum step. Delete/Backspace remove the selected note, Escape
// cancels a drag. Auditioning goes through window.jawnosSynth when it is loaded.
//
// The grid keeps device pixels sharp with a devicePixelRatio transform and
// redraws on a ResizeObserver (or the window resize when the observer is not
// available). The piano keys, the grid and the velocity lane share one mapping.

var STUDIO_NOTES_ROW = 12;              // CSS px per semitone
var STUDIO_NOTES_MIN_PPB = 8;
var STUDIO_NOTES_MAX_PPB = 320;
var STUDIO_NOTES_MENU_ID = 'studio_notes_velocity';

var studioNotesState = {
	ch: null,
	take: null,
	notes: [],
	ppb: 48,             // pixels per beat
	snap: 0.0625,        // beats; 0 means Off
	beatsPerBar: 4,
	topNote: 84,         // the highest MIDI note drawn at the top row
	leftBeat: 0,         // the beat at the left edge
	selected: -1,
	drag: null,
	lastVelocity: 0.8,
	focus: false,
	menuIndex: -1,
	rerenderTimer: null,
	observer: null,
	gates: {}
};

function studioNotesText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function studioNotesPanel() {
	return document.getElementById('studio_notes');
}

function studioNotesGrid() {
	return document.getElementById('studio_notes_grid');
}

function studioNotesClamp(value, lo, hi) {
	value = Number(value);
	if (!isFinite(value)) { return lo; }
	return Math.max(lo, Math.min(hi, value));
}

// ---- tempo and length ------------------------------------------------------

function studioNotesBpm() {
	var bpm = 120;
	if (typeof mixer !== 'undefined' && mixer && mixer['time']) {
		if (typeof studioKnobNumber === 'function') { bpm = studioKnobNumber(mixer['time']['bpm'], 120); }
		else { bpm = parseFloat(mixer['time']['bpm']); }
	}
	return (bpm > 0) ? bpm : 120;
}

function studioNotesBeatsPerBar() {
	var sig = '4/4';
	if (typeof mixer !== 'undefined' && mixer && mixer['time'] && mixer['time']['sig']) {
		sig = String(mixer['time']['sig']);
	}
	var beats = (typeof studioKnobNumber === 'function')
		? studioKnobNumber(sig.split('/')[0], 4)
		: parseInt(sig.split('/')[0], 10);
	return (beats > 0) ? beats : 4;
}

// One bar in seconds is the shared helper when it is loaded, otherwise the
// tempo alone. This is only for the readout; all editing is in beats.
function studioNotesClipSeconds() {
	var st = studioNotesState;
	if (!st.take) { return 0; }
	var beats = Number(st.take.beats) || 0;
	if (typeof studioBarSeconds === 'function') {
		return beats / st.beatsPerBar * studioBarSeconds();
	}
	return beats * 60 / studioNotesBpm();
}

function studioNotesNoteName(n) {
	var names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
	n = Math.round(studioNotesClamp(n, 0, 127));
	return names[n % 12] + (Math.floor(n / 12) - 1);
}

function studioNotesIsBlack(n) {
	var pc = ((Math.round(n) % 12) + 12) % 12;
	return pc === 1 || pc === 3 || pc === 6 || pc === 8 || pc === 10;
}

// ---- the take's own numbers ------------------------------------------------

// A clip needs a length before a note can be kept inside it. `beats` wins when
// it is already a positive number; otherwise the notes decide (at least four
// beats). A note that already reaches past the loop grows the loop to hold it,
// because this is the one place the clip's length is derived rather than edited.
function studioNotesEnsureBeats(take) {
	if (!take) { return 0; }
	var beats = Number(take.beats);
	if (!(beats > 0)) { beats = 0; }
	var maxEnd = 0;
	(take.notes || []).forEach(function (note) {
		var end = (Number(note.t) || 0) + (Number(note.d) || 0);
		if (end > maxEnd) { maxEnd = end; }
	});
	if (!(beats > 0)) { beats = Math.max(4, Math.ceil(maxEnd)); }
	if (maxEnd > beats) { beats = Math.ceil(maxEnd * 4) / 4; }
	take.beats = Math.round(beats * 10000) / 10000;
	return take.beats;
}

// The minimum note length a snap step allows. Off still needs a floor, so a
// resize can never produce a zero-length note.
function studioNotesStep() {
	var snap = Number(studioNotesState.snap) || 0;
	return (snap > 0) ? snap : 0.25;
}

function studioNotesSnapBeat(beat) {
	var snap = Number(studioNotesState.snap) || 0;
	if (!(snap > 0)) { return beat; }
	return Math.round(beat / snap) * snap;
}

// Every note is kept inside 0 <= t < beats and t + d <= beats. `minDur` lets the
// load path preserve a short note while an edit uses one snap step as its floor.
function studioNotesClampNote(note, beats, minDur) {
	if (!note) { return false; }
	beats = Number(beats) || 0;
	var min = Number(minDur) || 0.015625;
	var pitch = Number(note.n);
	var velocity = Number(note.v);
	note.n = Math.round(studioNotesClamp(isFinite(pitch) ? pitch : 60, 0, 127));
	note.v = isFinite(velocity) ? studioNotesClamp(velocity, 0, 1) : 0.8;
	note.d = Math.max(min, Number(note.d) || min);
	if (note.d > beats) { note.d = beats; }
	note.t = Math.max(0, Math.min(Math.max(0, beats - note.d), Number(note.t) || 0));
	note.d = Math.max(min, Math.min(note.d, beats - note.t));
	return true;
}

// ---- canvas and theme ------------------------------------------------------

function studioNotesFitCanvas(canvas) {
	if (!canvas) { return null; }
	var w = Math.round(canvas.clientWidth || 0);
	var h = Math.round(canvas.clientHeight || 0);
	if (w < 1 || h < 1) { return null; }
	var dpr = window.devicePixelRatio || 1;
	var pw = Math.round(w * dpr);
	var ph = Math.round(h * dpr);
	if (canvas.width !== pw || canvas.height !== ph) {
		canvas.width = pw;
		canvas.height = ph;
	}
	var ctx = canvas.getContext('2d');
	if (!ctx) { return null; }
	ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	return { canvas: canvas, ctx: ctx, w: w, h: h, dpr: dpr };
}

// The desk themes every panel with custom properties; read them once per draw so
// the grid follows a light or dark theme instead of hard-coding one.
function studioNotesTheme() {
	var panel = studioNotesPanel();
	var css = panel ? window.getComputedStyle(panel) : null;
	var value = function (name, fallback) {
		var got = css ? String(css.getPropertyValue(name) || '').trim() : '';
		return got || fallback;
	};
	return {
		panel2: value('--panel-2', '#1b1f27'),
		line: value('--line', '#3a4250'),
		ink: value('--ink', '#e8edf5'),
		accent: value('--accent', '#3f8fe0')
	};
}

function studioNotesMetrics() {
	var fit = studioNotesFitCanvas(studioNotesGrid());
	return fit ? { w: fit.w, h: fit.h } : null;
}

// ---- drawing ---------------------------------------------------------------

function studioNotesDraw() {
	var st = studioNotesState;
	var fit = studioNotesFitCanvas(studioNotesGrid());
	if (!fit) { return; }
	var ctx = fit.ctx, w = fit.w, h = fit.h;
	var theme = studioNotesTheme();
	var take = st.take;
	var beats = take ? (Number(take.beats) || 0) : 0;
	var bpbar = st.beatsPerBar || 4;
	var left = st.leftBeat;
	var right = left + w / st.ppb;

	ctx.clearRect(0, 0, w, h);
	ctx.fillStyle = theme.panel2;
	ctx.fillRect(0, 0, w, h);

	// semitone rows: accidentals are a shade darker, and every octave is ruled
	var rows = Math.ceil(h / STUDIO_NOTES_ROW) + 1;
	for (var i = 0; i < rows; i++) {
		var note = st.topNote - i;
		if (note < 0) { break; }
		var y = i * STUDIO_NOTES_ROW;
		if (studioNotesIsBlack(note)) {
			ctx.globalAlpha = 0.055;
			ctx.fillStyle = theme.ink;
			ctx.fillRect(0, y, w, STUDIO_NOTES_ROW);
			ctx.globalAlpha = 1;
		}
		if (note % 12 === 0) {
			ctx.globalAlpha = 0.28;
			ctx.strokeStyle = theme.line;
			ctx.beginPath();
			ctx.moveTo(0, y + STUDIO_NOTES_ROW - 0.5);
			ctx.lineTo(w, y + STUDIO_NOTES_ROW - 0.5);
			ctx.stroke();
			ctx.globalAlpha = 1;
		}
	}

	// beat and bar rules. Finer lines appear only once there is room for them.
	var step = (st.ppb >= 96) ? 0.25 : ((st.ppb >= 48) ? 0.5 : 1);
	var first = Math.floor(left / step) - 1;
	var last = Math.ceil(right / step) + 1;
	var perBar = Math.max(1, Math.round(bpbar / step));
	for (var k = first; k <= last; k++) {
		var beat = k * step;
		if (beat < 0) { continue; }
		var x = (beat - left) * st.ppb;
		var isBar = (k % perBar) === 0;
		var isBeat = Math.abs(beat - Math.round(beat)) < 1e-6;
		ctx.globalAlpha = isBar ? 0.55 : (isBeat ? 0.30 : 0.14);
		ctx.strokeStyle = theme.line;
		ctx.beginPath();
		ctx.moveTo(x + 0.5, 0);
		ctx.lineTo(x + 0.5, h);
		ctx.stroke();
		ctx.globalAlpha = 1;
		if (isBar) {
			ctx.globalAlpha = 0.6;
			ctx.fillStyle = theme.ink;
			ctx.font = '10px sans-serif';
			ctx.fillText(String(Math.round(beat / bpbar) + 1), x + 3, 11);
			ctx.globalAlpha = 1;
		}
	}

	// A loop repeats the clip every `beats`; draw later passes as ghosts so the
	// editor reads like the clip canvas on the timeline.
	if (take && take.loop && beats > 0) {
		var k0 = Math.max(1, Math.floor(left / beats));
		var k1 = Math.ceil(right / beats);
		for (var pass = k0; pass <= k1; pass++) {
			ctx.save();
			ctx.globalAlpha = 0.18;
			for (var g = 0; g < st.notes.length; g++) {
				studioNotesDrawBlock(ctx, theme, st.notes[g], pass * beats, false, w, h);
			}
			ctx.restore();
			var bx = (pass * beats - left) * st.ppb;
			if (bx >= 0 && bx <= w) {
				ctx.save();
				ctx.globalAlpha = 0.5;
				ctx.strokeStyle = theme.ink;
				ctx.setLineDash([4, 3]);
				ctx.beginPath();
				ctx.moveTo(bx + 0.5, 0);
				ctx.lineTo(bx + 0.5, h);
				ctx.stroke();
				ctx.restore();
			}
		}
	}

	// the clip's own end, where a note may not cross
	if (take && beats > 0) {
		var endX = (beats - left) * st.ppb;
		if (endX >= 0 && endX <= w) {
			ctx.globalAlpha = 0.7;
			ctx.strokeStyle = theme.line;
			ctx.beginPath();
			ctx.moveTo(endX + 0.5, 0);
			ctx.lineTo(endX + 0.5, h);
			ctx.stroke();
			ctx.globalAlpha = 1;
		}
	}

	for (var n = 0; n < st.notes.length; n++) {
		studioNotesDrawBlock(ctx, theme, st.notes[n], 0, n === st.selected, w, h);
	}

	studioNotesDrawPlayhead(ctx, theme, take, w, h);

	studioNotesDrawKeys(theme);
	studioNotesDrawVelocity(theme);
}

// One note block, offset by a loop pass in beats. Velocity sets both the
// opacity and a little of the height, so a soft note reads lighter than a hard
// one without a second colour.
function studioNotesDrawBlock(ctx, theme, note, offset, selected, w, h) {
	var st = studioNotesState;
	var x = ((Number(note.t) || 0) + (offset || 0) - st.leftBeat) * st.ppb;
	var bw = Math.max(3, (Number(note.d) || 0.0625) * st.ppb);
	var y = (st.topNote - (Number(note.n) || 0)) * STUDIO_NOTES_ROW;
	if (x > w || x + bw < 0 || y + STUDIO_NOTES_ROW < 0 || y > h) { return; }
	var v = studioNotesClamp(note.v, 0, 1);
	var inset = (1 - v) * (STUDIO_NOTES_ROW * 0.18);
	ctx.globalAlpha = 0.34 + v * 0.6;
	ctx.fillStyle = theme.accent;
	ctx.fillRect(x + 0.5, y + 1 + inset, Math.max(2, bw - 1), STUDIO_NOTES_ROW - 2 - inset);
	ctx.globalAlpha = 1;
	if (selected) {
		ctx.strokeStyle = theme.ink;
		ctx.lineWidth = 2;
		ctx.strokeRect(x + 1, y + 1.5, Math.max(1, bw - 2), STUDIO_NOTES_ROW - 3);
		ctx.lineWidth = 1;
		if (bw >= 30) {
			ctx.fillStyle = theme.panel2;
			ctx.font = '9px sans-serif';
			ctx.fillText(studioNotesNoteName(note.n), x + 4, y + STUDIO_NOTES_ROW - 4);
		}
	}
}

function studioNotesDrawPlayhead(ctx, theme, take, w, h) {
	if (!take) { return; }
	var pos = 0;
	if (typeof mixer !== 'undefined' && mixer && mixer['time']) {
		pos = Number(mixer['time']['position']) || 0;
	}
	if (!(pos > 0)) { return; }
	var beats = Number(take.beats) || 0;
	if (!(beats > 0)) { return; }
	var rel = pos - (Number(take.startTime) || 0);
	if (rel < 0) { return; }
	if (take.loop) { rel = rel % beats; }
	if (rel < 0 || rel > beats) { return; }
	var x = (rel - studioNotesState.leftBeat) * studioNotesState.ppb;
	if (x < 0 || x > w) { return; }
	ctx.strokeStyle = theme.ink;
	ctx.globalAlpha = 0.9;
	ctx.lineWidth = 2;
	ctx.beginPath();
	ctx.moveTo(x, 0);
	ctx.lineTo(x, h);
	ctx.stroke();
	ctx.lineWidth = 1;
	ctx.globalAlpha = 1;
}

// The key strip is a column of semitone cells; only the C rows carry a name, so
// the octave is readable without a label on every key.
function studioNotesDrawKeys(theme) {
	var fit = studioNotesFitCanvas(document.getElementById('studio_notes_keys'));
	if (!fit) { return; }
	var ctx = fit.ctx, w = fit.w, h = fit.h;
	var st = studioNotesState;
	ctx.clearRect(0, 0, w, h);
	ctx.fillStyle = theme.panel2;
	ctx.fillRect(0, 0, w, h);
	var rows = Math.ceil(h / STUDIO_NOTES_ROW) + 1;
	for (var i = 0; i < rows; i++) {
		var note = st.topNote - i;
		if (note < 0) { break; }
		var y = i * STUDIO_NOTES_ROW;
		var black = studioNotesIsBlack(note);
		ctx.globalAlpha = black ? 0.28 : 0.10;
		ctx.fillStyle = theme.ink;
		ctx.fillRect(0, y, w, STUDIO_NOTES_ROW - 1);
		ctx.globalAlpha = 0.4;
		ctx.strokeStyle = theme.line;
		ctx.beginPath();
		ctx.moveTo(0, y + STUDIO_NOTES_ROW - 0.5);
		ctx.lineTo(w, y + STUDIO_NOTES_ROW - 0.5);
		ctx.stroke();
		ctx.globalAlpha = 1;
		if (note % 12 === 0) {
			ctx.fillStyle = theme.ink;
			ctx.font = '9px sans-serif';
			ctx.textAlign = 'right';
			ctx.fillText(studioNotesNoteName(note), w - 3, y + STUDIO_NOTES_ROW - 2);
			ctx.textAlign = 'left';
		}
	}
}

// A small bar per note under the grid, at the note's own x. It makes the
// dynamics of the clip readable at a glance and gives the readout a picture.
function studioNotesDrawVelocity(theme) {
	var fit = studioNotesFitCanvas(document.getElementById('studio_notes_velocity_canvas'));
	if (!fit) { return; }
	var ctx = fit.ctx, w = fit.w, h = fit.h;
	var st = studioNotesState;
	ctx.clearRect(0, 0, w, h);
	ctx.fillStyle = theme.panel2;
	ctx.fillRect(0, 0, w, h);
	for (var i = 0; i < st.notes.length; i++) {
		var note = st.notes[i];
		var x = ((Number(note.t) || 0) - st.leftBeat) * st.ppb;
		var bw = Math.max(2, (Number(note.d) || 0.0625) * st.ppb);
		if (x > w || x + bw < 0) { continue; }
		var bh = Math.max(2, studioNotesClamp(note.v, 0, 1) * (h - 4));
		ctx.globalAlpha = (i === st.selected) ? 1 : (0.32 + studioNotesClamp(note.v, 0, 1) * 0.5);
		ctx.fillStyle = theme.accent;
		ctx.fillRect(x + 1, h - 2 - bh, Math.max(1, bw - 2), bh);
	}
	ctx.globalAlpha = 1;
}

// ---- readouts --------------------------------------------------------------

function studioNotesReadout() {
	var st = studioNotesState;
	var title = document.getElementById('studio_notes_title');
	var meta = document.getElementById('studio_notes_meta');
	var velocity = document.getElementById('studio_notes_velocity_readout');
	if (title) {
		title.textContent = st.take
			? studioNotesText('Track') + ' ' + (st.ch === null || st.ch === undefined ? '?' : st.ch)
			: studioNotesText('No clip');
	}
	if (meta) {
		if (!st.take) {
			meta.textContent = '';
		}
		else {
			var bars = Math.round((Number(st.take.beats) || 0) / st.beatsPerBar * 100) / 100;
			var patch = st.take.patch || {};
			var name = patch.name || patch.family || '';
			var bits = [
				bars + ' ' + studioNotesText(bars === 1 ? 'bar' : 'bars'),
				Math.round(studioNotesBpm()) + ' BPM'
			];
			if (name) { bits.push(String(name)); }
			var seconds = studioNotesClipSeconds();
			if (seconds > 0) { bits.push(seconds.toFixed(1) + 's'); }
			if (st.take.loop) { bits.push(studioNotesText('Loop')); }
			meta.textContent = bits.join(' \u00b7 ');
		}
	}
	if (velocity) {
		var note = (st.take && st.selected >= 0) ? st.notes[st.selected] : null;
		velocity.textContent = note
			? (Math.round(studioNotesClamp(note.v, 0, 1) * 100) + '% \u00b7 ' + studioNotesNoteName(note.n))
			: '\u2014';
	}
}

// ---- view limits -----------------------------------------------------------

function studioNotesFitNotes() {
	var st = studioNotesState;
	var metrics = studioNotesMetrics();
	var rows = metrics ? Math.max(8, Math.floor(metrics.h / STUDIO_NOTES_ROW)) : 24;
	if (!st.notes.length) {
		st.topNote = 84;
		return;
	}
	var lo = 127, hi = 0;
	st.notes.forEach(function (note) {
		var n = Math.round(studioNotesClamp(note.n, 0, 127));
		if (n < lo) { lo = n; }
		if (n > hi) { hi = n; }
	});
	var centre = Math.round((lo + hi) / 2);
	st.topNote = Math.min(127, Math.max(hi + 1, centre + Math.floor(rows / 2)));
}

function studioNotesClampView() {
	var st = studioNotesState;
	var metrics = studioNotesMetrics();
	var rows = metrics ? Math.max(1, Math.floor(metrics.h / STUDIO_NOTES_ROW)) : 24;
	st.topNote = Math.round(studioNotesClamp(st.topNote, rows - 1, 127));
	var beats = st.take ? (Number(st.take.beats) || 0) : 0;
	var span = metrics ? metrics.w / st.ppb : 0;
	var maxLeft = Math.max(0, beats - span);
	st.leftBeat = Math.max(0, Math.min(maxLeft, st.leftBeat));
	if (!isFinite(st.leftBeat)) { st.leftBeat = 0; }
}

function studioNotesSetZoom(ppb) {
	var st = studioNotesState;
	var metrics = studioNotesMetrics();
	var centre = metrics ? st.leftBeat + (metrics.w / 2) / st.ppb : st.leftBeat;
	st.ppb = studioNotesClamp(ppb, STUDIO_NOTES_MIN_PPB, STUDIO_NOTES_MAX_PPB);
	if (metrics) { st.leftBeat = Math.max(0, centre - (metrics.w / 2) / st.ppb); }
	studioNotesClampView();
	studioNotesDraw();
}

// ---- pointer geometry ------------------------------------------------------

function studioNotesPointer(e, canvas) {
	var element = canvas || studioNotesGrid();
	var rect = element ? element.getBoundingClientRect() : { left: 0, top: 0 };
	var source = (e && e['originalEvent']) ? e['originalEvent'] : e;
	return {
		x: (Number(source.clientX) || 0) - rect.left,
		y: (Number(source.clientY) || 0) - rect.top
	};
}

function studioNotesHit(x, y) {
	var st = studioNotesState;
	for (var i = st.notes.length - 1; i >= 0; i--) {
		var note = st.notes[i];
		var nx = ((Number(note.t) || 0) - st.leftBeat) * st.ppb;
		var bw = Math.max(3, (Number(note.d) || 0.0625) * st.ppb);
		var ny = (st.topNote - (Number(note.n) || 0)) * STUDIO_NOTES_ROW;
		if (x >= nx - 2 && x <= nx + bw + 2 && y >= ny && y <= ny + STUDIO_NOTES_ROW) {
			var edge = Math.min(8, Math.max(3, bw / 4));
			return {
				index: i,
				note: note,
				mode: (x >= nx + bw - edge) ? 'resize' : 'move'
			};
		}
	}
	return null;
}

// ---- dragging --------------------------------------------------------------

function studioNotesStartDrag(mode, hit, pos, added) {
	var st = studioNotesState;
	var note = hit.note;
	$(document).off('.studioNotesDrag');
	st.selected = hit.index;
	st.drag = {
		mode: mode,
		note: note,
		index: hit.index,
		startX: pos.x,
		startY: pos.y,
		t: Number(note.t) || 0,
		d: Number(note.d) || studioNotesStep(),
		n: Number(note.n) || 60,
		lastAud: null,
		lastPitch: Number(note.n) || 60,
		added: !!added,
		moved: false
	};
	studioNotesAudition(note.n, note.v);
	st.drag.lastAud = note.n;
	$(document).on('pointermove.studioNotesDrag', studioNotesPointerMove);
	$(document).on('pointerup.studioNotesDrag pointercancel.studioNotesDrag', studioNotesPointerUp);
	studioNotesDraw();
	studioNotesReadout();
}

function studioNotesPointerMove(e) {
	var st = studioNotesState;
	var drag = st.drag;
	if (!drag || !st.take) { return; }
	if (e && e.preventDefault) { e.preventDefault(); }
	var pos = studioNotesPointer(e);
	var beats = Number(st.take.beats) || 0;
	var deltaBeats = (pos.x - drag.startX) / st.ppb;
	var minStep = studioNotesStep();
	var changed = false;

	if (drag.mode === 'resize') {
		// The end snaps to the grid, but the loop edge always wins: a note may
		// never grow past take.beats, even when the last step is a fraction.
		var end = studioNotesSnapBeat(drag.t + drag.d + deltaBeats);
		var maxDur = Math.max(0.015625, beats - drag.t);
		var duration = Math.max(minStep, Math.min(maxDur, end - drag.t));
		if (duration !== drag.note.d) {
			drag.note.d = duration;
			changed = true;
		}
	}
	else {
		var wanted = studioNotesSnapBeat(drag.t + deltaBeats);
		var duration2 = Math.max(0.015625, Math.min(Number(drag.note.d) || minStep, beats));
		var t = Math.max(0, Math.min(beats - duration2, wanted));
		var pitch = Math.round(studioNotesClamp(drag.n - Math.round((pos.y - drag.startY) / STUDIO_NOTES_ROW), 0, 127));
		if (t !== drag.note.t || pitch !== drag.note.n) { changed = true; }
		drag.note.t = t;
		drag.note.n = pitch;
		if (pitch !== drag.lastPitch) {
			studioNotesStop(drag.lastAud);
			studioNotesAudition(pitch, drag.note.v);
			drag.lastAud = pitch;
			drag.lastPitch = pitch;
		}
	}

	if (changed) { drag.moved = true; }
	studioNotesDraw();
	studioNotesReadout();
}

function studioNotesEndDrag() {
	$(document).off('.studioNotesDrag');
	studioNotesState.drag = null;
}

function studioNotesPointerUp() {
	var drag = studioNotesState.drag;
	if (!drag) { return; }
	studioNotesStop(drag.lastAud);
	var changed = drag.moved || drag.added;
	studioNotesEndDrag();
	if (changed) { studioNotesCommit(true); }
	else { studioNotesDraw(); studioNotesReadout(); }
}

// Escape puts the note back exactly where it was; an added note is removed
// again, because an add is only real once the press ends.
function studioNotesCancelDrag() {
	var st = studioNotesState;
	var drag = st.drag;
	if (!drag) { return false; }
	drag.note.t = drag.t;
	drag.note.d = drag.d;
	drag.note.n = drag.n;
	if (drag.added) {
		var at = st.notes.indexOf(drag.note);
		if (at >= 0) { st.notes.splice(at, 1); }
		st.selected = -1;
	}
	studioNotesStop(drag.lastAud);
	studioNotesEndDrag();
	studioNotesDraw();
	studioNotesReadout();
	return true;
}

// ---- adding, removing, changing ------------------------------------------

function studioNotesAddAt(pos) {
	var st = studioNotesState;
	if (!st.take) { return null; }
	var beats = Number(st.take.beats) || 0;
	if (!(beats > 0)) { return null; }
	var step = studioNotesStep();
	var t = studioNotesSnapBeat(st.leftBeat + pos.x / st.ppb);
	var pitch = Math.round(studioNotesClamp(st.topNote - Math.floor(pos.y / STUDIO_NOTES_ROW), 0, 127));
	var duration = Math.min(step, beats);
	t = Math.max(0, Math.min(beats - duration, t));
	var note = { n: pitch, t: t, d: duration, v: st.lastVelocity };
	st.notes.push(note);
	st.selected = st.notes.length - 1;
	return note;
}

function studioNotesDelete(index) {
	var st = studioNotesState;
	if (!st.take) { return; }
	if (!(index >= 0 && index < st.notes.length)) { return; }
	st.notes.splice(index, 1);
	st.selected = -1;
	studioNotesMenuClose();
	studioNotesCommit(true);
	studioNotesDraw();
	studioNotesReadout();
}

function studioNotesClear() {
	var st = studioNotesState;
	if (!st.take) { return; }
	st.notes.length = 0;
	st.selected = -1;
	studioNotesMenuClose();
	studioNotesCommit(true);
	studioNotesDraw();
	studioNotesReadout();
}

// Everything a change writes lives here: the notes and the length, the song
// save, and a debounced re-render of the clip's audio cache. The debounce keeps
// a drag from rendering once per pointermove; the canvas is already up to date.
function studioNotesCommit(rerender) {
	var st = studioNotesState;
	var take = st.take;
	if (!take) { return; }
	take.notes = st.notes;
	take.beats = studioNotesEnsureBeats(take);
	if (typeof studioSaver === 'function') { studioSaver(); }
	if (!rerender) { return; }
	var hook = (typeof window.studioNoteClipRerender === 'function') ? window.studioNoteClipRerender : null;
	if (!hook) { return; }
	// Capture the pair: a close or a clip switch before the timer fires must not
	// send the old edit to the new take.
	var pendingCh = st.ch;
	var pendingTake = take;
	if (st.rerenderTimer) { clearTimeout(st.rerenderTimer); }
	st.rerenderTimer = setTimeout(function () {
		st.rerenderTimer = null;
		if (typeof window.studioNoteClipRerender === 'function') {
			window.studioNoteClipRerender(pendingCh, pendingTake);
		}
	}, 140);
}

// ---- audition --------------------------------------------------------------

function studioNotesAudition(note, velocity) {
	var synth = window.jawnosSynth;
	if (!synth || typeof synth.noteOn !== 'function') { return; }
	var n = Math.round(studioNotesClamp(note, 0, 127));
	try { synth.noteOn(n, studioNotesClamp(velocity, 0, 1)); } catch (e) { return; }
	var key = 'n' + n;
	if (studioNotesState.gates[key]) { clearTimeout(studioNotesState.gates[key]); }
	studioNotesState.gates[key] = setTimeout(function () {
		studioNotesState.gates[key] = null;
		try { synth.noteOff(n); } catch (e) {}
	}, 220);
}

function studioNotesStop(note) {
	var synth = window.jawnosSynth;
	if (!synth || typeof synth.noteOff !== 'function') { return; }
	var n = Math.round(studioNotesClamp(note, 0, 127));
	var key = 'n' + n;
	if (studioNotesState.gates[key]) {
		clearTimeout(studioNotesState.gates[key]);
		studioNotesState.gates[key] = null;
	}
	try { synth.noteOff(n); } catch (e) {}
}

// ---- the velocity menu -----------------------------------------------------

function studioNotesMenuClose() {
	$('#' + STUDIO_NOTES_MENU_ID).remove();
	studioNotesState.menuIndex = -1;
}

function studioNotesMenuIsOpen() {
	return $('#' + STUDIO_NOTES_MENU_ID).length > 0;
}

function studioNotesMenuPlace(menu, x, y) {
	var width = menu.outerWidth() || 148;
	var height = menu.outerHeight() || 76;
	var viewW = window.innerWidth || document.documentElement.clientWidth || 0;
	var viewH = window.innerHeight || document.documentElement.clientHeight || 0;
	var left = Math.max(4, Math.min(x, viewW - width - 4));
	var top = Math.max(4, Math.min(y, viewH - height - 4));
	menu.css({ left: left + 'px', top: top + 'px' });
}

// The card follows the drums' velocity card: minus, the value, plus, and the
// menu stays open while the person tunes a note by ear. Delete removes it.
function studioNotesVelocityMenu(index, x, y) {
	var st = studioNotesState;
	var note = st.notes[index];
	if (!note) { return; }
	studioNotesMenuClose();
	st.selected = index;
	st.menuIndex = index;
	var value = Math.round(studioNotesClamp(note.v, 0, 1) * 100);
	var menu = $('<div class="studio_menu studio_notes_velocity_menu"></div>')
		.attr('id', STUDIO_NOTES_MENU_ID)
		.attr('data-index', index);
	$('<div class="studio_menu_head"></div>')
		.text(studioNotesNoteName(note.n) + ' \u00b7 ' + studioNotesText('Velocity'))
		.appendTo(menu);
	var row = $('<div class="studio_menu_velocity"></div>').appendTo(menu);
	$('<button type="button" class="hover" data-delta="-10"></button>')
		.attr('aria-label', studioNotesText('Softer'))
		.attr('title', studioNotesText('Softer'))
		.text('\u2212')
		.appendTo(row);
	$('<span></span>').attr('data-value', '1').text(String(value)).appendTo(row);
	$('<button type="button" class="hover" data-delta="10"></button>')
		.attr('aria-label', studioNotesText('Harder'))
		.attr('title', studioNotesText('Harder'))
		.text('+')
		.appendTo(row);
	$('<button type="button" class="studio_menu_row hover" data-action="delete"></button>')
		.text(studioNotesText('Delete note'))
		.appendTo(menu);
	$('body').append(menu);
	studioNotesMenuPlace(menu, x, y);
	studioNotesDraw();
	studioNotesReadout();
}

$(document).on('click', '#' + STUDIO_NOTES_MENU_ID + ' button', function (e) {
	e.preventDefault();
	var menu = $('#' + STUDIO_NOTES_MENU_ID);
	if (!menu.length) { return; }
	var index = parseInt(menu.attr('data-index'), 10);
	if ($(this).attr('data-action') === 'delete') {
		studioNotesDelete(index);
		studioNotesMenuClose();
		return;
	}
	var note = studioNotesState.notes[index];
	if (!note) { studioNotesMenuClose(); return; }
	var delta = parseInt($(this).attr('data-delta'), 10) || 0;
	var percent = Math.max(0, Math.min(100, Math.round(studioNotesClamp(note.v, 0, 1) * 100) + delta));
	note.v = percent / 100;
	studioNotesState.lastVelocity = note.v;
	menu.find('[data-value]').text(String(percent));
	studioNotesDraw();
	studioNotesReadout();
	studioNotesAudition(note.n, note.v);
	studioNotesCommit(true);
});

// The next press elsewhere, Escape, or a scroll closes the card.
$(document).on('pointerdown', function (e) {
	if (!$(e.target).closest('#' + STUDIO_NOTES_MENU_ID).length) { studioNotesMenuClose(); }
	studioNotesState.focus = $(e.target).closest('#studio_notes, #' + STUDIO_NOTES_MENU_ID).length > 0;
});

document.addEventListener('scroll', studioNotesMenuClose, true);

// ---- grid events -----------------------------------------------------------

// Right-click on a note opens its velocity card; an empty spot keeps the
// browser's own menu, exactly as an empty drum step does.
$(document).on('contextmenu', '#studio_notes_grid', function (e) {
	var st = studioNotesState;
	if (!st.take) { return; }
	var pos = studioNotesPointer(e, this);
	var hit = studioNotesHit(pos.x, pos.y);
	if (!hit) { studioNotesMenuClose(); return; }
	e.preventDefault();
	studioNotesVelocityMenu(hit.index, e.clientX, e.clientY);
});

$(document).on('pointerdown', '#studio_notes_grid', function (e) {
	var st = studioNotesState;
	if (!st.take) { return; }
	if (e.button !== undefined && e.button !== 0) { return; }
	if (e.preventDefault) { e.preventDefault(); }
	var pos = studioNotesPointer(e, this);
	var hit = studioNotesHit(pos.x, pos.y);
	st.focus = true;
	studioNotesMenuClose();
	if (hit) {
		studioNotesStartDrag(hit.mode, hit, pos, false);
		return;
	}
	var note = studioNotesAddAt(pos);
	if (!note) { return; }
	var added = studioNotesHit(pos.x, pos.y);
	if (!added || added.note !== note) {
		// The new block is under the pointer; if a snap put it elsewhere, start
		// the drag from its real index without inventing a second hit.
		added = { index: st.notes.length - 1, note: note, mode: 'move' };
	}
	studioNotesStartDrag('move', added, pos, true);
});

$(document).on('click', '#studio_notes_zoom_in', function (e) {
	e.preventDefault();
	studioNotesSetZoom(studioNotesState.ppb * 1.25);
});

$(document).on('click', '#studio_notes_zoom_out', function (e) {
	e.preventDefault();
	studioNotesSetZoom(studioNotesState.ppb / 1.25);
});

$(document).on('change', '#studio_notes_snap', function () {
	var snap = parseFloat($(this).val());
	studioNotesState.snap = (snap > 0) ? snap : 0;
	studioNotesDraw();
});

$(document).on('click', '#studio_notes_clear', function (e) {
	e.preventDefault();
	studioNotesClear();
});

$(document).on('click', '.studio_notes_close', function (e) {
	e.preventDefault();
	studioNotesClose();
});

// Delete/Backspace remove the selected note and Escape cancels a drag, but only
// while the panel owns the last press and no text field has focus.
$(document).on('keydown', function (e) {
	var st = studioNotesState;
	if (!st.take || !st.focus) { return; }
	var target = e.target || {};
	var tag = String(target.tagName || '').toLowerCase();
	if (tag === 'input' || tag === 'select' || tag === 'textarea' || target.isContentEditable) { return; }
	if (e.key === 'Escape') {
		if (studioNotesMenuIsOpen()) { studioNotesMenuClose(); e.preventDefault(); return; }
		if (studioNotesCancelDrag()) { e.preventDefault(); }
		return;
	}
	if ((e.key === 'Delete' || e.key === 'Backspace') && st.selected >= 0) {
		e.preventDefault();
		studioNotesDelete(st.selected);
	}
});

// A wheel over the grid scrolls the pitch window, or beats with Shift (or a
// horizontal trackpad). It must not scroll the desk behind the panel.
function studioNotesWheel(e) {
	var st = studioNotesState;
	if (!st.take) { return; }
	e.preventDefault();
	var dx = Number(e.deltaX) || 0;
	var dy = Number(e.deltaY) || 0;
	if (e.shiftKey || Math.abs(dx) > Math.abs(dy)) {
		st.leftBeat += (dx || dy) / st.ppb;
	}
	else {
		var steps = Math.round(dy / STUDIO_NOTES_ROW);
		st.topNote -= (steps || (dy > 0 ? 1 : -1));
	}
	studioNotesClampView();
	studioNotesDraw();
}

// ---- size and lifecycle ----------------------------------------------------

function studioNotesBind() {
	var grid = studioNotesGrid();
	if (grid && grid.getAttribute('data-studio-notes-bound') !== '1') {
		grid.setAttribute('data-studio-notes-bound', '1');
		grid.addEventListener('wheel', studioNotesWheel, { passive: false });
	}
	if (studioNotesState.observer) { return; }
	if (typeof ResizeObserver === 'function') {
		studioNotesState.observer = new ResizeObserver(function () {
			studioNotesClampView();
			studioNotesDraw();
		});
		var host = document.getElementById('studio_notes_editor');
		if (host) { studioNotesState.observer.observe(host); }
	}
}

$(window).on('resize', function () {
	if (!studioNotesState.take) { return; }
	studioNotesClampView();
	studioNotesDraw();
});

$(function () {
	studioNotesBind();
	studioNotesDraw();
	studioNotesReadout();
});

// ---- the public surface ----------------------------------------------------

// Open (or restore) the panel on this take. A missing take is the empty state:
// the panel stays usable and says how a note clip is opened.
function studioNotesOpen(ch, take) {
	var st = studioNotesState;
	var panel = studioNotesPanel();
	if (!panel) { return; }
	// A clip switch while a press is still down finishes the old edit first, so
	// the old take keeps the change the person could see.
	if (st.drag) { studioNotesPointerUp(); }
	st.ch = (ch === undefined) ? null : ch;
	st.take = take || null;
	st.notes = (st.take && Array.isArray(st.take.notes)) ? st.take.notes : [];
	if (st.take && !Array.isArray(st.take.notes)) { st.take.notes = st.notes; }
	st.selected = -1;
	st.drag = null;
	st.menuIndex = -1;
	studioNotesMenuClose();
	$(document).off('.studioNotesDrag');
	st.beatsPerBar = studioNotesBeatsPerBar();
	if (st.take) {
		var beats = studioNotesEnsureBeats(st.take);
		for (var i = 0; i < st.notes.length; i++) {
			studioNotesClampNote(st.notes[i], beats, 0.015625);
		}
		st.leftBeat = 0;
		st.topNote = 84;
		studioNotesFitNotes();
	}
	else {
		st.leftBeat = 0;
		st.topNote = 84;
	}

	panel.setAttribute('data-studio-notes-open', st.take ? '1' : '0');
	panel.classList.toggle('studio_notes_empty', !st.take);
	panel.classList.remove('studio_panel_minimized');
	if (typeof studioPanelSetMinimized === 'function') {
		try { studioPanelSetMinimized('notes', false, false); } catch (e) {}
	}
	if (typeof studioPanelRaise === 'function') {
		try { studioPanelRaise('notes'); } catch (e) {}
	}

	studioNotesBind();
	// The panel may be measured only after the integrator's geometry lands, so
	// fit the visible notes on the next frame and draw again then.
	if (typeof window.requestAnimationFrame === 'function') {
		window.requestAnimationFrame(function () {
			if (st.take) {
				var metrics = studioNotesMetrics();
				if (metrics && st.take.beats > 0) {
					st.ppb = studioNotesClamp(metrics.w / st.take.beats, 16, 160);
					studioNotesFitNotes();
				}
			}
			studioNotesClampView();
			studioNotesDraw();
			studioNotesReadout();
		});
	}
	studioNotesClampView();
	studioNotesDraw();
	studioNotesReadout();
}

function studioNotesClose() {
	var st = studioNotesState;
	studioNotesMenuClose();
	if (st.drag) { studioNotesCancelDrag(); }
	$(document).off('.studioNotesDrag');
	st.take = null;
	st.notes = [];
	st.ch = null;
	st.selected = -1;
	st.drag = null;
	st.menuIndex = -1;
	var panel = studioNotesPanel();
	if (panel) {
		panel.setAttribute('data-studio-notes-open', '0');
		panel.classList.add('studio_notes_empty');
		panel.classList.add('studio_panel_minimized');
		if (typeof studioPanelSetMinimized === 'function') {
			try { studioPanelSetMinimized('notes', true, true); } catch (e) {}
		}
	}
	studioNotesDraw();
	studioNotesReadout();
}

// Tempo and length can change under the editor (a tempo edit restretches every
// note clip); re-read them and redraw without writing anything back.
function studioNotesRefresh() {
	var st = studioNotesState;
	st.beatsPerBar = studioNotesBeatsPerBar();
	if (st.take) {
		var beats = studioNotesEnsureBeats(st.take);
		for (var i = 0; i < st.notes.length; i++) {
			studioNotesClampNote(st.notes[i], beats, 0.015625);
		}
	}
	studioNotesClampView();
	studioNotesDraw();
	studioNotesReadout();
}

window.studioNotesOpen = studioNotesOpen;
window.studioNotesClose = studioNotesClose;
window.studioNotesRefresh = studioNotesRefresh;
