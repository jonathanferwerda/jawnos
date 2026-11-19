// ===========================================================================
// The chromatic tuner (Jtune)
// ===========================================================================
// Jtune is not an effect and never joins a rack in the browser graph's sense:
// it is a listen-only pedal. The rack treats it like any insert - it is dragged
// in, ordered and bypassed with Up/Down and the footswitch - but studioInsert
// builds the fallback pass-through for it, so it never colours the sound and the
// native engine's plan (which asks for a builder) leaves it out.
//
// It taps its own insert's input, which is the chain exactly where it sits: put
// it first and it hears the clean input, put it after a pedal and it hears that
// pedal. The switch is the insert's on/off; bypassed, the signal still passes
// and the tuner stops listening. The pink switch and the lamp are the same
// control: the lamp is grey while it is off, amber while it listens, and green
// when the note is inside the tolerance.
//
// The pitch comes from YIN's cumulative-mean-normalized difference, run on a
// half-rate copy of the analyser window. Half the rate halves the lags the
// search walks, and 85ms at 24kHz still holds three periods of a bass's low E,
// so the low notes are as cheap as the high ones.

var studioTunerTolerance = 5;   // cents inside which a note counts as in tune
var studioTunerGate = 0.006;    // RMS below this is silence, not a note
var studioTunerNotes = [ 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' ];
var studioTunerDragAt = 0;      // a drag that just ended must not read as a click

var studioTuner = {
	analyser: null, mute: null, tap: null, channel: 0,
	buffer: null, half: null, bytes: null, diff: null,
	timer: 0, running: false,
	note: null, cents: 0, inTune: false, silent: 0, error: ''
};

// ---- the maths, kept free of the DOM so a test can run it under node -------

// The nearest note to `hz` and the cents between them (A4 is 440).
function studioTunerNote(hz) {
	if (!(hz > 0) || !isFinite(hz)) { return null; }
	var midi = 69 + 12 * Math.log(hz / 440) / Math.LN2;
	var near = Math.round(midi);
	return {
		midi: near,
		name: studioTunerNotes[((near % 12) + 12) % 12],
		octave: Math.floor(near / 12) - 1,
		cents: (midi - near) * 100
	};
}

// YIN: the difference function, its cumulative mean normalization, then the
// first dip under the threshold. The parabolic fit around that dip turns the
// whole-sample lag into a fractional one, which is what makes the cents usable.
function studioTunerPitch(samples, rate) {
	var n = samples ? samples.length : 0;
	if (n < 64 || !(rate > 0)) { return null; }
	var mean = 0, i, v;
	for (i = 0; i < n; i++) { mean += samples[i]; }
	mean /= n;
	var rms = 0;
	for (i = 0; i < n; i++) { v = samples[i] - mean; rms += v * v; }
	rms = Math.sqrt(rms / n);
	if (rms < studioTunerGate) { return null; }

	var minLag = Math.max(2, Math.floor(rate / 1400));
	var maxLag = Math.min(Math.floor(n / 2), Math.floor(rate / 26));
	if (maxLag <= minLag + 2) { return null; }

	var diff = studioTuner.diff;
	if (!diff || diff.length < maxLag + 2) { diff = studioTuner.diff = new Float32Array(maxLag + 2); }
	var running = 0;
	for (var lag = 1; lag <= maxLag + 1; lag++) {
		var sum = 0;
		for (i = 0; i + lag < n; i++) { v = samples[i] - samples[i + lag]; sum += v * v; }
		running += sum;
		diff[lag] = running > 0 ? sum * lag / running : 1;
	}

	var best = -1;
	for (lag = minLag; lag <= maxLag; lag++) {
		if (diff[lag] < 0.14 && diff[lag] < diff[lag - 1] && diff[lag] <= diff[lag + 1]) { best = lag; break; }
	}
	if (best < 0) {
		var low = 1;
		for (lag = minLag; lag <= maxLag; lag++) { if (diff[lag] < low) { low = diff[lag]; best = lag; } }
		if (low > 0.4) { return null; }
	}

	var y1 = diff[best - 1], y2 = diff[best], y3 = diff[best + 1];
	var denom = 2 * (2 * y2 - y1 - y3);
	var shift = denom ? (y3 - y1) / denom : 0;
	if (!isFinite(shift) || Math.abs(shift) > 1) { shift = 0; }
	var hz = rate / (best + shift);
	if (!(hz > 25) || hz > 1400) { return null; }
	return { hz: hz, clarity: 1 - diff[best] };
}

// ---- the tile --------------------------------------------------------------

function studioTunerTile() {
	return $('#pedal_Jtune');
}

// The tuner is a listen-only pedal in the selected track's rack, so its on/off
// is the insert's bypass. These two read that state; the lamp, the switch and
// the display all follow it.
function studioTunerInsert(ch) {
	ch = (ch === undefined || ch === null) ? studioPaletteChannel() : ch;
	return studioRackFind(ch, 'Jtune');
}

function studioTunerOn() {
	var ins = studioTunerInsert();
	return !!(ins && !ins.bypassed);
}

function studioTunerPaintLamp(tile) {
	tile = (tile && tile.length) ? tile : studioTunerTile();
	if (!tile.length) { return; }
	var lamp = tile.find('.studio_pedal_led');
	var on = studioTunerOn();
	var tuned = !!(on && studioTuner.inTune);
	var label = !on
		? studioLayoutText('Start or stop the tuner')
		: studioLayoutText(tuned ? 'In tune' : 'Tuning');
	lamp.attr({ 'aria-pressed': on ? 'true' : 'false', title: label, hint: label });
	lamp.toggleClass('studio_tuner_listening', !!on && !tuned)
		.toggleClass('studio_tuner_tuned', tuned);
}

function studioTunerPaintButton() {
	var b = studioTunerTile().find('.button_control');
	if (!b.length) { return; }
	var pressed = studioTunerOn();
	var colour = b.attr('colour') || 'ruby_red';
	b.attr('status', pressed ? 'pressed' : 'depressed')
		.attr('src', jawnosStudioButtonIcon(pressed ? 'pressed' : 'depressed', colour));
}

function studioTunerDraw() {
	var tile = studioTunerTile();
	if (!tile.length) { return; }
	var on = studioTunerOn();
	var note = studioTuner.note;
	var cents = studioTuner.cents;
	var tuned = !!(on && note && studioTuner.inTune);
	var display = tile.find('.studio_tuner');
	display.toggleClass('studio_tuner_on', on)
		.toggleClass('studio_tuner_off', !on)
		.toggleClass('studio_tuner_tuned', tuned);
	tile.find('.studio_tuner_letter').text(on ? (note ? note.name : '--') : studioLayoutText('TUNE'));
	tile.find('.studio_tuner_octave').text((on && note) ? String(note.octave) : '');
	tile.find('.studio_tuner_up').toggleClass('studio_tuner_arrow_on', !!(on && note && cents < -studioTunerTolerance));
	tile.find('.studio_tuner_down').toggleClass('studio_tuner_arrow_on', !!(on && note && cents > studioTunerTolerance));
	var line = '';
	if (!on) { line = studioLayoutText(studioTuner.error || 'press to tune'); }
	else if (note) { line = (cents > 0 ? '+' : '') + Math.round(cents); }
	else if (studioTuner.error) { line = studioTuner.error; }
	else { line = studioLayoutText('Track') + ' ' + (studioTuner.channel || 1); }
	tile.find('.studio_tuner_cents').text(line);
	studioTunerPaintLamp(tile);
	studioTunerPaintButton();
}

// ---- listening -------------------------------------------------------------
//
// Jtune is a listen-only pedal in the selected track's rack, at the place the
// rack puts it: first in the chain it hears the clean input, and after a pedal
// it hears that pedal. The insert is the fallback pass-through studioInsert
// builds for a name with no builder, so it never colours the sound and the
// native engine's plan leaves it out. Its on/off is the insert's bypass: off,
// the signal still passes and the tuner stops listening.

// Attach, move or detach the analyser to match the selected track's insert.
function studioTunerSync() {
	var ch = studioPaletteChannel();
	var ins = studioRackFind(ch, 'Jtune');
	var on = !!(ins && !ins.bypassed);
	if (!on) {
		if (studioTuner.running) { studioTunerStop(); }
		else { studioTunerDraw(); }
		return;
	}
	if (studioTuner.running && studioTuner.channel === ch && studioTuner.tap === ins.input) {
		studioTunerDraw();
		return;
	}
	studioTunerDetach();
	studioTunerAttach(ch, ins);
}

function studioTunerToggle() {
	var ch = studioPaletteChannel();
	var ins = studioRackFind(ch, 'Jtune');
	if (!ins) { studioSetInsert(ch, 'Jtune', true); }
	else { studioSetInsertBypass(ch, 'Jtune', !ins.bypassed); }
	studioTunerSync();
}

function studioTunerAttach(ch, ins) {
	var ctx = studioContext();
	if (!ctx || !ins || !ins.input) { studioTunerFail('No audio'); return; }
	var analyser = ctx.createAnalyser();
	analyser.fftSize = 4096;
	analyser.smoothingTimeConstant = 0;
	var mute = ctx.createGain();
	mute.gain.value = 0;
	try {
		ins.input.connect(analyser);
		analyser.connect(mute);
		mute.connect(ctx.destination);
	}
	catch (e) { studioTunerFail('No audio'); return; }
	studioTuner.analyser = analyser;
	studioTuner.mute = mute;
	studioTuner.tap = ins.input;
	studioTuner.channel = ch;
	studioTuner.buffer = new Float32Array(analyser.fftSize);
	studioTuner.half = new Float32Array(studioTuner.buffer.length / 2);
	studioTuner.running = true;
	studioTuner.error = '';
	studioTuner.note = null;
	studioTuner.cents = 0;
	studioTuner.inTune = false;
	studioTuner.silent = 0;
	if (ctx.state === 'suspended') { try { ctx.resume(); } catch (e) {} }
	studioTunerRead();
	studioTunerDraw();
}

function studioTunerDetach() {
	clearTimeout(studioTuner.timer);
	studioTuner.timer = 0;
	if (studioTuner.tap && studioTuner.analyser) {
		try { studioTuner.tap.disconnect(studioTuner.analyser); } catch (e) {}
	}
	if (studioTuner.analyser) { try { studioTuner.analyser.disconnect(); } catch (e) {} }
	if (studioTuner.mute) { try { studioTuner.mute.disconnect(); } catch (e) {} }
	studioTuner.analyser = null;
	studioTuner.mute = null;
	studioTuner.tap = null;
	studioTuner.channel = 0;
	studioTuner.running = false;
	studioTuner.note = null;
	studioTuner.cents = 0;
	studioTuner.inTune = false;
	studioTuner.silent = 0;
}

// The selection moved to another track, or its rack changed: follow it.
function studioTunerFollow() {
	studioTunerSync();
}

function studioTunerRead() {
	clearTimeout(studioTuner.timer);
	studioTuner.timer = 0;
	if (!studioTuner.running || !studioTuner.analyser) { return; }
	// the insert can be moved, bypassed or removed under a listening tuner
	var ins = studioTunerInsert(studioTuner.channel);
	if (!ins || ins.bypassed || ins.input !== studioTuner.tap || studioTuner.channel !== studioPaletteChannel()) {
		// the sync's own attach starts the next read (and a stop schedules nothing)
		studioTunerSync();
		return;
	}
	var c = studioAudio.channels[studioTuner.channel];
	if (!c || (!c.source && !c.synthTap)) {
		// the pedal is still on; there is just nothing at its input yet
		studioTuner.error = studioLayoutText('No live input');
		studioTuner.note = null;
		studioTuner.cents = 0;
		studioTuner.inTune = false;
		studioTunerDraw();
		studioTuner.timer = setTimeout(studioTunerRead, 120);
		return;
	}
	studioTuner.error = '';
	var analyser = studioTuner.analyser;
	var buf = studioTuner.buffer;
	if (!buf || buf.length !== analyser.fftSize) { buf = studioTuner.buffer = new Float32Array(analyser.fftSize); }
	if (analyser.getFloatTimeDomainData) {
		analyser.getFloatTimeDomainData(buf);
	}
	else {
		var bytes = studioTuner.bytes;
		if (!bytes || bytes.length !== analyser.fftSize) { bytes = studioTuner.bytes = new Uint8Array(analyser.fftSize); }
		analyser.getByteTimeDomainData(bytes);
		for (var i = 0; i < bytes.length; i++) { buf[i] = (bytes[i] - 128) / 128; }
	}
	var half = studioTuner.half;
	if (!half || half.length !== buf.length / 2) { half = studioTuner.half = new Float32Array(buf.length / 2); }
	for (var j = 0; j < half.length; j++) { half[j] = (buf[2 * j] + buf[2 * j + 1]) / 2; }
	var ctx = studioAudio.ctx;
	var rate = (ctx && ctx.sampleRate ? ctx.sampleRate : 48000) / 2;
	var found = studioTunerPitch(half, rate);
	var note = found ? studioTunerNote(found.hz) : null;
	if (!note) {
		studioTuner.silent++;
		if (studioTuner.silent > 3) { studioTuner.note = null; studioTuner.cents = 0; studioTuner.inTune = false; }
	}
	else {
		studioTuner.silent = 0;
		studioTuner.note = note;
		studioTuner.cents = note.cents;
		studioTuner.inTune = Math.abs(note.cents) <= studioTunerTolerance;
	}
	studioTunerDraw();
	studioTuner.timer = setTimeout(studioTunerRead, 120);
}

function studioTunerFail(message) {
	studioTuner.error = studioLayoutText(message);
	studioTunerDetach();
	studioTunerDraw();
}

function studioTunerStop(keepError) {
	studioTunerDetach();
	if (!keepError) { studioTuner.error = ''; }
	studioTunerDraw();
}

// ---- the switch ------------------------------------------------------------
//
// The whole tile, its pink switch and its lamp all start or stop the tuner.
// The switch and the lamp stop their click here so the tile's handler cannot
// toggle it a second time.

$(document).on('click', '#pedal_Jtune', function (e) {
	if ($(e.target).closest('.button_control, .studio_pedal_led, .studio_pedal_foot').length) { return; }
	// a drag that has just ended (or reverted over the tile) is not a press
	if (studioTunerDragAt && (Date.now() - studioTunerDragAt) < 300) { return; }
	studioTunerToggle();
});
