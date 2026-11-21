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
		});
	});
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
	// A master knob is its own address: `master_comp.thresh`, not a track.
	studioEngineMasterParam(name, control, value);
	studioMasterRender();
	studioSaver();
}

function studioMasterToggle(name, on) {
	var ins = studioMasterFind(name);
	if (!ins) { return; }
	if (ins.setBypass) { ins.setBypass(!on); }
	// The engine keeps the insert in the rack and flips its bypass between
	// blocks; an effect that was off when the take began has no slot yet.
	studioEngineMasterBypass(name, !on);
	studioMasterRender();
	studioSaver();
	// A mastering insert on or off changes the rack the clip mix runs through,
	// so a running engine needs the replacement plan; the browser is unchanged.
	if (typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); }
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
