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

// The enabled master rack as engine control values. The browser holds the
// contract's 0..100 sliders; studioEffectNatural turns each into the unit the
// engine's mixer takes. A value-only transport update carries this whole list,
// so a dropped update cannot leave one knob stale.
function studioEngineMasterValues() {
	var records = (typeof studioMasterSave === 'function') ? studioMasterSave() : [];
	if (!records.length && mixer['admin'] && mixer['admin']['master']) {
		records = mixer['admin']['master'];
	}
	var values = [];
	records.forEach(function (record) {
		if (!record || !record['on']) { return; }
		var kind = studioEngineMasterKind(record['name']);
		// The Stereo Widener is browser only, exactly as the take plan leaves it.
		if (kind === 'stereowidener') { return; }
		$.each(record['controls'] || {}, function (control, value) {
			if (studioEffectNumber(value) === null) { return; }
			values.push({
				name: record['name'],
				control: control,
				value: studioEffectNatural(kind, control, value)
			});
		});
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
