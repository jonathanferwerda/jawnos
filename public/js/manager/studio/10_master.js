// ===========================================================================
// The master rack
// ===========================================================================
// The mastering chain is fixed: it sits on the mixer's bus, after every channel
// sum and before the destination, and each effect is switched in place with its
// own footswitch. The graph is built once with studioContext(), so a toggle
// only sets a bypass - nothing is rewired and nothing clicks.
//
// The order is the contract's table (docs/studio-effects.md) and does not
// change per song; the song's admin stores the on/off state and the controls.

// The rack holds the contract's five engine inserts plus the browser-only
// Stereo Widener; a native take builds the five it can and leaves that slot
// out (engine/src/effect.rs).
var studioMasterOrder = [ 'master_comp', 'master_eq', 'master_stereowidener', 'master_reverb', 'master_maximizer', 'master_limiter' ];

function studioMasterNames() {
	var names = [];
	(window.jawnos_studio_master || []).forEach(function (effect) {
		if (effect && effect['name']) { names.push(effect['name']); }
	});
	return names.length ? names : studioMasterOrder.slice();
}

function studioMasterChain(ctx) {
	var chain = { input: ctx.createGain(), output: ctx.createGain(), inserts: [], insertByName: {} };
	var node = chain.input;
	studioMasterNames().forEach(function (name) {
		var ins = studioInsert(ctx, name);
		chain.inserts.push(ins);
		chain.insertByName[name] = ins;
		node.connect(ins.input);
		node = ins.output;
	});
	node.connect(chain.output);
	// Off until the song asks for it: a new window sounds like it did before.
	chain.inserts.forEach(function (ins) { if (ins.setBypass) { ins.setBypass(true); } });
	return chain;
}

function studioMasterFind(name) {
	var chain = studioAudio.masterChain;
	return chain ? (chain.insertByName[name] || null) : null;
}

// Push an insert's values and footswitch back onto the on-screen rack.
function studioMasterRender() {
	var chain = studioAudio.masterChain;
	if (!chain) { return; }
	chain.inserts.forEach(function (ins) {
		var block = $('.studio_master_effect[effect="' + ins.name + '"]');
		if (!block.length) { return; }
		block.toggleClass('studio_master_on', !ins.bypassed);
		block.find('.studio_master_toggle').attr('aria-pressed', ins.bypassed ? 'false' : 'true');
		block.find('.studio_master_control').each(function () {
			var el = $(this);
			var value = ins.values[el.attr('control')];
			if (value === undefined) { return; }
			if (el.is('select')) {
				el.val(String(Math.round(studioEffectClamp(value, 0, el.find('option').length - 1))));
			}
			else {
				el.val(value);
			}
			if (el.closest('.studio_master_band').length) { studioMasterBandReadout(el); }
		});
	});
	studioMasterMeterStart();
}

// ---- the graphic EQ's fader readouts ---------------------------------------
// The contract's slider is 0..100 and the master EQ's faders are -12..+12 dB
// (docs/studio-effects.md, "Master rack"), so each fader shows the dB it asks
// for. The generic loop only moves the input; this keeps the label with it.
function studioMasterBandDb(value) {
	var n = studioEffectNumber(value);
	if (n === null) { return ''; }
	var db = (studioEffectClamp(n, 0, 100) - 50) * 0.24;
	var rounded = Math.round(db * 10) / 10;
	if (Math.abs(rounded - Math.round(rounded)) < 0.05) { rounded = Math.round(rounded); }
	return (rounded > 0 ? '+' : '') + rounded;
}

function studioMasterBandReadout(input) {
	var el = $(input);
	var label = el.closest('.studio_master_band').find('.studio_master_band_db');
	if (label.length) { label.text(studioMasterBandDb(el.val())); }
}

// ---- the rack's output meter -----------------------------------------------
// The mixer already feeds the destination through studioAudio.masterAnalyser,
// so the rack's twelve LEDs read that same analyser. The loop starts with the
// first render and stops itself when the context is gone; it paints at about
// 20 frames a second and only while the rack is on screen, so a hidden studio
// costs one idle frame at a time.
var studioMasterMeterFrame = 0;
var studioMasterMeterLast = 0;
var studioMasterMeterData = null;

function studioMasterMeterPaint(analyser) {
	var size = analyser.fftSize || 2048;
	if (!studioMasterMeterData || studioMasterMeterData.length !== size) {
		studioMasterMeterData = new Float32Array(size);
	}
	analyser.getFloatTimeDomainData(studioMasterMeterData);
	var sum = 0;
	for (var i = 0; i < size; i++) { sum += studioMasterMeterData[i] * studioMasterMeterData[i]; }
	var level = Math.min(1, Math.sqrt(sum / size) * 3);
	var lit = Math.round(level * 12);
	$('#studio_master_meter .studio_master_led').each(function () {
		var index = parseInt($(this).attr('data-led'), 10) || 0;
		$(this).toggleClass('lit', index < lit);
	});
}

function studioMasterMeterStep(now) {
	studioMasterMeterFrame = 0;
	var analyser = studioAudio && studioAudio.masterAnalyser;
	if (!analyser || typeof analyser.getFloatTimeDomainData !== 'function') { return; }
	var stamp = (typeof now === 'number') ? now : Date.now();
	if (!studioMasterMeterLast || (stamp - studioMasterMeterLast) >= 50) {
		studioMasterMeterLast = stamp;
		if ($('#studio_master_meter').is(':visible')) { studioMasterMeterPaint(analyser); }
	}
	if (window.requestAnimationFrame) { studioMasterMeterFrame = window.requestAnimationFrame(studioMasterMeterStep); }
}

function studioMasterMeterStart() {
	if (studioMasterMeterFrame || typeof window.requestAnimationFrame !== 'function') { return; }
	studioMasterMeterFrame = window.requestAnimationFrame(studioMasterMeterStep);
}

// Read the rack as the window shows it, then push it into the graph.
function studioMasterApply() {
	var chain = studioAudio.masterChain;
	if (!chain) { return; }
	$('.studio_master_effect').each(function () {
		var block = $(this);
		var ins = studioMasterFind(block.attr('effect'));
		if (!ins) { return; }
		block.find('.studio_master_control').each(function () {
			ins.set($(this).attr('control'), $(this).val());
		});
		var on = block.find('.studio_master_toggle').attr('aria-pressed') === 'true';
		if (ins.setBypass) { ins.setBypass(!on); }
	});
	studioMasterRender();
}

function studioMasterSet(name, control, value) {
	var ins = studioMasterFind(name);
	if (!ins) { return; }
	ins.set(control, value);
	studioMasterRender();
	studioSaver();
	// The engine transport owns the clip mix: a knob is a value-only plan
	// update, never the take's param path. Both paths stay separate.
	if (mixer['time'] && mixer['time']['engine_transport']) {
		studioEngineMasterValuesChanged();
		return;
	}
	// A master knob is its own address: `master_comp.thresh`, not a track.
	studioEngineMasterParam(name, control, value);
}

function studioMasterToggle(name, on) {
	var ins = studioMasterFind(name);
	if (!ins) { return; }
	if (ins.setBypass) { ins.setBypass(!on); }
	studioMasterRender();
	studioSaver();
	// A mastering insert on or off changes the rack the clip mix runs through.
	// The engine transport learns it from the replacement plan (which carries
	// the knob values too); the take's own bypass path is left alone so the two
	// never race.
	if (typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); return; }
	// The engine keeps the insert in the rack and flips its bypass between
	// blocks; an effect that was off when the take began has no slot yet.
	studioEngineMasterBypass(name, !on);
}

// The engine's implementation name for a master prefix: `master_comp` is the
// `compressor` the shared units table names, so studioEffectNatural reads the
// canonical spelling.
function studioEngineMasterKind(name) {
	var kind = studioEffectKind(name);
	if (kind.indexOf('master_') === 0) { kind = kind.slice(7); }
	return kind;
}

// The master rack as engine control values: every slot's footswitch, plus the
// knobs of the slots that are on. The browser holds the contract's 0..100
// sliders; studioEffectNatural turns each into the unit the engine's mixer
// takes. A value-only transport update carries this whole list, so a dropped
// update cannot leave one knob stale, and a footswitch moved mid-song is heard
// on the next block because the slot is still in the rack.
function studioEngineMasterValues() {
	var records = (typeof studioMasterSave === 'function') ? studioMasterSave() : [];
	if (!records.length && mixer['admin'] && mixer['admin']['master']) {
		records = mixer['admin']['master'];
	}
	var values = [];
	var seen = {};
	records.forEach(function (record) {
		if (!record || !record['name']) { return; }
		var kind = studioEngineMasterKind(record['name']);
		// The Stereo Widener is browser only, exactly as the take plan leaves it.
		if (kind === 'stereowidener') { return; }
		seen[record['name']] = true;
		values.push({
			name: record['name'],
			control: 'bypass',
			value: record['on'] ? 0 : 1
		});
		if (!record['on']) { return; }
		$.each(record['controls'] || {}, function (control, value) {
			if (studioEffectNumber(value) === null) { return; }
			values.push({
				name: record['name'],
				control: control,
				value: studioEffectNatural(kind, control, value)
			});
		});
	});
	// A slot the song never saved a record for is off, not left running with the
	// insert's defaults: the rack is always the five, and silence about a slot
	// must not arm it.
	(typeof studioEngineMasterList === 'function' ? studioEngineMasterList() : []).forEach(function (name) {
		if (seen[name]) { return; }
		values.push({ name: name, control: 'bypass', value: 1 });
	});
	return values;
}

// The pending master-values post. A drag on a knob produces several moves; one
// short debounce collapses them into a single value-only plan update.
var studioEngineMasterTimer = 0;

function studioEngineMasterValuesChanged() {
	if (!mixer['time'] || !mixer['time']['engine_transport']) { return; }
	// The first plan is still staging and its own `start` carries the current
	// values, so a knob moved now needs no extra post.
	if (studioEngineTransportStarting) { return; }
	if (studioEngineMasterTimer) { clearTimeout(studioEngineMasterTimer); }
	studioEngineMasterTimer = setTimeout(function () {
		studioEngineMasterTimer = 0;
		studioEngineMasterValuesPost();
	}, 120);
}

function studioEngineMasterValuesPost() {
	if (!mixer['time'] || !mixer['time']['engine_transport']) { return; }
	var values = studioEngineMasterValues();
	if (!values.length) { return; }
	studioEngineTransportPost('update', { master_values_json: JSON.stringify(values) }, function (data) {
		if (!data || data.ok !== true) {
			// A refusal leaves the engine's rack as it was; the browser graph keeps
			// its own value and the next knob move tries again.
			console.log('studio: engine master value update refused, keeping the current rack', (data && data.error) || '');
		}
	});
}

// The song's admin carries the master rack: one record per effect, in chain
// order, with its footswitch and every control it has.
function studioMasterSave() {
	var chain = studioAudio.masterChain;
	if (!chain) { return []; }
	return chain.inserts.map(function (ins) {
		var controls = {};
		$.each(ins.values || {}, function (control, value) { controls[control] = value; });
		return { name: ins.name, on: !ins.bypassed, controls: controls };
	});
}

function studioMasterRestore(records) {
	if (!records || !records.length) { return; }
	records.forEach(function (record) {
		var ins = studioMasterFind(record['name']);
		if (!ins) { return; }
		$.each(record['controls'] || {}, function (control, value) { ins.set(control, value); });
		if (ins.setBypass) { ins.setBypass(record['on'] !== true); }
	});
	studioMasterRender();
}

$(document).on('click', '.studio_master_toggle', function () {
	var button = $(this);
	var block = button.closest('.studio_master_effect');
	var on = button.attr('aria-pressed') !== 'true';
	button.attr('aria-pressed', on ? 'true' : 'false');
	studioMasterToggle(block.attr('effect'), on);
});

$(document).on('input change', '.studio_master_control', function () {
	var input = $(this);
	var block = input.closest('.studio_master_effect');
	studioMasterSet(block.attr('effect'), input.attr('control'), input.val());
});

// Where one master control goes back to: the insert's own builder default when
// it has a record of that control (a model is a list index, so a guessed 50
// would pick the wrong model), else the first option of a select and the middle
// of a range. The footswitch is never touched - a reset restores values only.
function studioMasterDefault(ins, input) {
	var control = input.attr('control');
	if (ins && ins.defaults && ins.defaults[control] !== undefined) { return ins.defaults[control]; }
	return input.is('select') ? 0 : 50;
}

// Reset every control in one unit. Each value goes through studioMasterSet so
// the insert, the graph, the node, the song and the engine all move together.
function studioMasterResetControls(name) {
	var ins = studioMasterFind(name);
	if (!ins) { return; }
	$('.studio_master_effect[effect="' + name + '"]').find('.studio_master_control').each(function () {
		var input = $(this);
		studioMasterSet(name, input.attr('control'), studioMasterDefault(ins, input));
	});
	studioMasterRender();
}

$(document).on('click', '.studio_master_defaults', function (e) {
	e.preventDefault();
	var block = $(this).closest('.studio_master_effect');
	studioMasterResetControls(block.attr('effect'));
});

// A double-click resets the one control under it, the way a double-clicked
// knob does on the board.
$(document).on('dblclick', '.studio_master_control', function (e) {
	var input = $(this);
	var block = input.closest('.studio_master_effect');
	var name = block.attr('effect');
	var ins = studioMasterFind(name);
	if (!ins) { return; }
	e.preventDefault();
	studioMasterSet(name, input.attr('control'), studioMasterDefault(ins, input));
	studioMasterRender();
});

// ===========================================================================
// Mastering automation: a measurement mic on the master
// ===========================================================================
// A browser-only Learn (docs/studio-mastering-automation.md §7.1). The mic
// hears the room while the browser chain plays; the reference is the rack's
// input, before every insert. Ten one-octave bands are measured for ten
// seconds, the difference against a target is clamped to +/- 6 dB and written
// into the rack's own ten-band EQ (`master_eq`), then saved with the song.
//
// The mic is an analyser source and nothing else: it is never connected to the
// destination, so a measurement cannot feed the room. The engine owns the
// transport on a native take and the browser chain is silent then, so Learn
// refuses rather than measuring a dead bus.
//
// The reference is pre-master, so the measured difference must come from a
// neutral EQ. The person's manual curve is captured first, the gains are
// flattened for the run without overwriting the stored values, and the learned
// curve replaces the ten bands when the run ends; Reset puts the manual curve
// back.
var studioMasteringHz = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
var studioMasteringControls = ['b32', 'b64', 'b125', 'b250', 'b500', 'b1k', 'b2k', 'b4k', 'b8k', 'b16k'];
// Flat is the measurement mic's target; House is the gentle downward tilt a
// room hears as balanced. Both are choices, not a truth.
var studioMasteringTargets = {
	flat:  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
	house: [3, 2, 1, 0.5, 0, 0, -0.5, -1, -1.5, -2]
};
var studioMasteringSeconds = 10;
var studioMasteringLimit = 6;          // dB, per band and per Learn
var studioMasteringSampleMs = 100;     // ten samples a second, the whole window
var studioMasteringGateDb = -50;       // a reference band with no programme
var studioMasteringFloorDb = -55;      // the loudest band is still too quiet
var studioMasteringMicFloorDb = -80;   // the mic heard no programme in the band

var studioMasteringState = {
	stream: null, source: null, mic: null, ref: null,
	acc: null, timer: 0, started: 0, running: false, pending: false, manual: null
};

function studioMasteringText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function studioMasteringSay(text) {
	var el = $('#studio_mastering_status');
	if (el.length) { el.text(studioMasteringText(text)); }
}

function studioMasteringTarget() {
	var picked = $('input[name="studio_mastering_target"]:checked').val();
	return (picked === 'flat') ? 'flat' : 'house';
}

// The rack's 0..100 fader value for a dB setting, the inverse of
// studioMasterBandDb() above, rounded to the slider's whole step.
function studioMasteringDbToValue(db) {
	return Math.max(0, Math.min(100, Math.round(50 + db * 100 / 24)));
}

function studioMasteringDbText(db) {
	var rounded = Math.round(db * 10) / 10;
	if (Math.abs(rounded) < 0.05) { rounded = 0; }
	return (rounded > 0 ? '+' : '') + rounded;
}

function studioMasteringClamp(value, low, high) {
	return Math.max(low, Math.min(high, value));
}

// ---- the window's state ----------------------------------------------------

function studioMasteringButtons() {
	var learn = $('#studio_mastering_learn');
	if (!learn.length) { return; }
	var running = !!studioMasteringState.running;
	learn.text(studioMasteringText(running ? 'Stop' : 'Learn'));
	learn.attr('aria-pressed', running ? 'true' : 'false');
}

// The mic picker can only name devices after permission, when the labels
// arrive; keep the chosen id across the first enumeration.
function studioMasteringDevices(keep) {
	var select = $('#studio_mastering_mic');
	if (!select.length || !(navigator.mediaDevices && navigator.mediaDevices.enumerateDevices)) { return; }
	var chosen = (keep !== undefined && keep !== null && String(keep).length) ? String(keep) : String(select.val() || '');
	navigator.mediaDevices.enumerateDevices().then(function (list) {
		var inputs = (list || []).filter(function (item) { return item && item.kind === 'audioinput'; });
		select.empty();
		select.append($('<option>').attr('value', '').text(studioMasteringText('Default microphone')));
		var seen = {};
		inputs.forEach(function (item, i) {
			var id = String(item.deviceId || '');
			if (!id || seen[id]) { return; }
			seen[id] = 1;
			var label = item.label || (studioMasteringText('Microphone') + ' ' + (i + 1));
			select.append($('<option>').attr('value', id).text(label));
		});
		if (chosen) { select.val(chosen); }
		if (select.val() !== (chosen || '')) { select.val(''); }
	}).catch(function () { /* a browser that refuses to enumerate keeps the default */ });
}

// ---- measurement -----------------------------------------------------------

// The bin range for one octave band; both analysers share the sample rate, so
// the counts cancel in the mic/reference difference.
function studioMasteringBinRange(bins, rate, low, high) {
	var nyquist = rate / 2;
	var first = Math.max(0, Math.floor(low / nyquist * bins));
	var last = Math.min(bins - 1, Math.ceil(high / nyquist * bins));
	if (last < first) { last = first; }
	return [first, last];
}

function studioMasteringAccumulator(ctx, mic, ref) {
	var bins = mic.frequencyBinCount;
	var ranges = studioMasteringHz.map(function (hz) {
		return studioMasteringBinRange(bins, ctx.sampleRate, hz / Math.SQRT2, hz * Math.SQRT2);
	});
	return {
		bins: bins,
		ranges: ranges,
		micData: new Float32Array(bins),
		refData: new Float32Array(bins),
		micPower: studioMasteringHz.map(function () { return 0; }),
		refPower: studioMasteringHz.map(function () { return 0; }),
		refPeak: studioMasteringHz.map(function () { return 0; }),
		frames: 0
	};
}

// One sample of both streams: the sum of linear power over each band's bins,
// and the band's loudest frame so a band that fell away can be held.
function studioMasteringSample(acc, mic, ref) {
	mic.getFloatFrequencyData(acc.micData);
	ref.getFloatFrequencyData(acc.refData);
	acc.ranges.forEach(function (range, i) {
		var micPower = 0;
		var refPower = 0;
		for (var bin = range[0]; bin <= range[1]; bin++) {
			micPower += Math.pow(10, acc.micData[bin] / 10);
			refPower += Math.pow(10, acc.refData[bin] / 10);
		}
		acc.micPower[i] += micPower;
		acc.refPower[i] += refPower;
		if (refPower > acc.refPeak[i]) { acc.refPeak[i] = refPower; }
	});
	acc.frames++;
}

// `correction = clamp(target - (mic - reference), -6, +6)`. The reference tap
// is pre-master and the bands were flattened for the run, so the difference
// is the room alone. A band with no programme, or one the mic never heard, is
// held at 0 dB rather than chased with a boost.
function studioMasteringResult(acc, targetName) {
	var target = studioMasteringTargets[targetName] || studioMasteringTargets.house;
	var frames = Math.max(1, acc.frames);
	var bands = [];
	var loudest = -200;
	studioMasteringHz.forEach(function (hz, i) {
		var micDb = 10 * Math.log10(acc.micPower[i] / frames + 1e-12);
		var refDb = 10 * Math.log10(acc.refPower[i] / frames + 1e-12);
		var peakDb = 10 * Math.log10(acc.refPeak[i] + 1e-12);
		if (refDb > loudest) { loudest = refDb; }
		var measured = micDb - refDb;
		var gated = (refDb < studioMasteringGateDb) || (refDb < peakDb - 20) || (micDb < studioMasteringMicFloorDb);
		var correction = gated ? 0 : studioMasteringClamp(target[i] - measured, -studioMasteringLimit, studioMasteringLimit);
		bands.push({ control: studioMasteringControls[i], hz: hz, target: target[i], measured: measured, correction: correction, gated: gated });
	});
	return { bands: bands, quiet: (loudest < studioMasteringFloorDb) };
}

// ---- the bars --------------------------------------------------------------

// A bar grows from the centre line: +12 dB fills the half above it, and the
// correction's own +/- 6 dB is half the plot, so the two are comparable.
function studioMasteringBar(el, db) {
	if (!el.length) { return; }
	var half = 50;
	var range = 12;
	var pct = Math.max(0, Math.min(range, Math.abs(db))) / range * half;
	el.css({ top: (db >= 0 ? (half - pct) : half) + '%', bottom: '', height: pct + '%' });
	el.toggleClass('studio_mastering_neg', db < 0);
}

function studioMasteringMark(el, db) {
	if (!el.length) { return; }
	var pct = 50 - Math.max(-12, Math.min(12, db)) / 12 * 50;
	el.css({ top: pct + '%' });
}

function studioMasteringClear() {
	$('#studio_mastering_bars .studio_mastering_band').each(function () {
		var el = $(this);
		studioMasteringBar(el.find('.studio_mastering_band_before'), 0);
		studioMasteringBar(el.find('.studio_mastering_band_after'), 0);
		el.removeClass('studio_mastering_gated');
		el.find('.studio_mastering_band_db').text('0');
	});
	studioMasteringTargetPaint();
}

// The target is a line, so it is drawn even before a Learn; the bars then
// show what was measured against it.
function studioMasteringTargetPaint() {
	var target = studioMasteringTargets[studioMasteringTarget()] || studioMasteringTargets.house;
	$('#studio_mastering_bars .studio_mastering_band').each(function () {
		var el = $(this);
		var index = studioMasteringControls.indexOf(el.attr('data-control'));
		if (index < 0) { return; }
		studioMasteringMark(el.find('.studio_mastering_band_target'), target[index]);
	});
}

function studioMasteringPaint(result) {
	$('#studio_mastering_bars .studio_mastering_band').each(function () {
		var el = $(this);
		var control = el.attr('data-control');
		var band = null;
		((result && result.bands) || []).forEach(function (b) { if (b.control === control) { band = b; } });
		if (!band) { return; }
		studioMasteringBar(el.find('.studio_mastering_band_before'), band.measured);
		studioMasteringBar(el.find('.studio_mastering_band_after'), band.correction);
		studioMasteringMark(el.find('.studio_mastering_band_target'), band.target);
		el.toggleClass('studio_mastering_gated', !!band.gated);
		el.find('.studio_mastering_band_db').text(studioMasteringDbText(band.correction));
	});
}

// ---- the manual curve ------------------------------------------------------

function studioMasteringManual() {
	var eq = studioMasterFind('master_eq');
	if (!eq) { return null; }
	var values = {};
	studioMasteringControls.forEach(function (control) { values[control] = eq.values[control]; });
	return { values: values, on: !eq.bypassed };
}

// Set the audible gains without touching the stored values or the song: the
// flattening is part of the measurement, not an edit the person made.
function studioMasteringGains(eq, values) {
	if (!eq) { return; }
	studioMasteringControls.forEach(function (control) {
		var value = (values && values[control] !== undefined) ? values[control] : 50;
		if (eq.setters[control]) { eq.setters[control](studioEffectNumber(value)); }
	});
}

function studioMasteringRestoreManual(manual) {
	if (!manual) { return; }
	studioMasteringControls.forEach(function (control) {
		if (manual.values[control] !== undefined) { studioMasterSet('master_eq', control, manual.values[control]); }
	});
	studioMasterToggle('master_eq', manual.on === true);
}

// ---- start, stop, reset ----------------------------------------------------

function studioMasteringMediaStop() {
	var state = studioMasteringState;
	if (state.timer) { clearInterval(state.timer); state.timer = 0; }
	if (state.stream) {
		state.stream.getTracks().forEach(function (track) { try { track.stop(); } catch (e) {} });
	}
	if (state.source) { try { state.source.disconnect(); } catch (e) {} }
	if (state.mic) { try { state.mic.disconnect(); } catch (e) {} }
	if (state.ref) {
		try { state.ref.disconnect(); } catch (e) {}
		var chain = studioAudio.masterChain;
		if (chain && chain.input) { try { chain.input.disconnect(state.ref); } catch (e) {} }
	}
	state.stream = null;
	state.source = null;
	state.mic = null;
	state.ref = null;
	state.acc = null;
	state.timer = 0;
	state.started = 0;
	state.running = false;
	state.pending = false;
	studioMasteringButtons();
}

function studioMasteringStop() {
	if (!studioMasteringState.running) { return; }
	var manual = studioMasteringState.manual;
	studioMasteringMediaStop();
	studioMasteringGains(studioMasterFind('master_eq'), manual ? manual.values : null);
	studioMasteringSay('Stopped. The master is as it was.');
}

function studioMasteringReset() {
	var manual = studioMasteringState.manual;
	studioMasteringStop();
	studioMasteringMediaStop();
	if (!manual) { studioMasteringSay('Nothing to reset.'); return; }
	studioMasteringRestoreManual(manual);
	studioMasteringState.manual = null;
	studioMasteringClear();
	studioMasteringSay('Reset to the manual curve.');
}

function studioMasteringFinish() {
	var state = studioMasteringState;
	if (!state.running) { return; }
	var result = studioMasteringResult(state.acc, studioMasteringTarget());
	var manual = state.manual;
	var eq = studioMasterFind('master_eq');
	studioMasteringMediaStop();
	if (result.quiet) {
		studioMasteringGains(eq, manual ? manual.values : null);
		studioMasteringSay('The programme was too quiet to learn from. Play the song and try again.');
		return;
	}
	var heard = 0;
	result.bands.forEach(function (band) { if (!band.gated) { heard++; } });
	if (!heard) {
		studioMasteringGains(eq, manual ? manual.values : null);
		studioMasteringSay('The microphone heard nothing. Check the input and try again.');
		return;
	}
	result.bands.forEach(function (band) {
		studioMasterSet('master_eq', band.control, studioMasteringDbToValue(band.correction));
	});
	studioMasterToggle('master_eq', true);
	studioMasteringPaint(result);
	studioMasteringSay('Learned ' + heard + ' of 10 bands against the ' + studioMasteringTarget() + ' target.');
	// The learned bands are part of the song's master record; save it now so
	// the curve outlives the window.
	if (typeof studioSave === 'function') { studioSave(); }
}

function studioMasteringRun(ctx, chain, stream) {
	var state = studioMasteringState;
	// The reference is pre-master, so the measured difference has to come from
	// a neutral EQ. Flatten the audible gains only: the stored values (and the
	// song) still hold the person's manual curve until the learned one lands.
	studioMasteringGains(studioMasterFind('master_eq'), null);
	state.stream = stream;
	state.source = ctx.createMediaStreamSource(stream);
	state.mic = ctx.createAnalyser();
	state.mic.fftSize = 8192;
	state.mic.smoothingTimeConstant = 0;
	// Analyser only: the mic's source is never connected to ctx.destination.
	state.source.connect(state.mic);
	state.ref = ctx.createAnalyser();
	state.ref.fftSize = 8192;
	state.ref.smoothingTimeConstant = 0;
	// The reference is the rack's input, pre-master; a second edge from a gain
	// node does not change the main path's level.
	chain.input.connect(state.ref);
	state.acc = studioMasteringAccumulator(ctx, state.mic, state.ref);
	state.running = true;
	state.started = Date.now();
	studioMasteringClear();
	studioMasteringButtons();
	// The labels become readable once permission is granted; keep the pick.
	studioMasteringDevices($('#studio_mastering_mic').val());
	studioMasteringSay('Listening for ten seconds...');
	state.timer = setInterval(function () {
		studioMasteringSample(state.acc, state.mic, state.ref);
		if (Date.now() - state.started >= studioMasteringSeconds * 1000) { studioMasteringFinish(); }
	}, studioMasteringSampleMs);
}

function studioMasteringLearn() {
	if (studioMasteringState.running) { studioMasteringStop(); return; }
	if (studioMasteringState.pending) { return; }
	var ctx = studioContext();
	var chain = studioAudio.masterChain;
	if (!ctx || !chain) { studioMasteringSay('There is no browser master chain to learn on.'); return; }
	// The engine owns the transport on a native take; the browser chain is
	// silent then, so a measurement would only hear the room's noise.
	var native = (mixer['time'] && mixer['time']['engine_transport'])
		|| (typeof studioEngineTransportStarting !== 'undefined' && studioEngineTransportStarting);
	if (native) {
		studioMasteringSay('The engine owns playback, so the browser master chain is silent. Learn is browser monitoring only; stop the engine transport and try again.');
		return;
	}
	if (!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)) {
		studioMasteringSay('This browser cannot open a microphone.');
		return;
	}
	var eq = studioMasterFind('master_eq');
	var manual = studioMasteringManual();
	if (!eq || !manual) { studioMasteringSay('The master EQ is not in the rack.'); return; }
	studioMasteringState.manual = manual;
	studioMasteringState.pending = true;
	studioMasteringSay('Opening the microphone...');
	var audio = {
		echoCancellation: false,  // Disables echo suppression
		noiseSuppression: false,  // Disables background noise dampening
		autoGainControl: false    // Prevents the browser from auto-adjusting volume
	};
	var rate = studioSampleRate();
	if (rate > 0) { audio.sampleRate = rate; }
	var pick = String($('#studio_mastering_mic').val() || '');
	if (pick) { audio.deviceId = { exact: pick }; }
	navigator.mediaDevices.getUserMedia({ audio: audio, video: false })
		.catch(function (error) {
			// A stale device id is a common refusal; fall back to the default mic.
			if (pick && error && (error.name === 'OverconstrainedError' || error.name === 'NotFoundError')) {
				return navigator.mediaDevices.getUserMedia({ audio: {
					echoCancellation: false, noiseSuppression: false, autoGainControl: false
				}, video: false });
			}
			throw error;
		})
		.then(function (stream) {
			studioMasteringState.pending = false;
			if (!studioMasteringState.manual) {
				stream.getTracks().forEach(function (track) { try { track.stop(); } catch (e) {} });
				return;
			}
			studioMasteringRun(ctx, chain, stream);
		})
		.catch(function (error) {
			studioMasteringState.pending = false;
			console.log('studio: mastering mic refused', error);
			studioMasteringGains(eq, manual.values);
			studioMasteringSay('Could not open a microphone: permission denied or none is connected.');
		});
}

$(document).on('click', '#studio_mastering_learn', function () { studioMasteringLearn(); });
$(document).on('click', '#studio_mastering_reset', function () { studioMasteringReset(); });
$(document).on('change', 'input[name="studio_mastering_target"]', function () { studioMasteringTargetPaint(); });

$(function () {
	studioMasteringDevices();
	studioMasteringButtons();
	studioMasteringTargetPaint();
});
