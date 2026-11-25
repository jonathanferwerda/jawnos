// ---- the House patch -------------------------------------------------------
// The Channel input panel is also the surface for the sources a track cannot
// own. The guitar is Input 1/2, already a track input; the voice and the deck
// are peer sources of the house plan and have no track take of their own.
//
// The plan is one document for the whole house (docs/studio-audio-roadmap.md
// §8). This section reads it from GET /manager/sound/plan and lists every
// source with its kind, the machine that binds it and whether it is bound,
// silent or pending. For each routed source it is the monitor and mute, the
// source's own effect chain, and the Record house mix control for the bus take.
//
// A monitor move is a live fader: POST /manager/sound/param with target=patch
// and the route's index, the same command the Sound matrix sends. Mute and the
// effect chain are plan facts, so they are saved through POST
// /manager/sound/plan and the engine applies the plan.
var studioHouseInsertNames = ['tone', 'distortion', 'delay', 'compressor', 'reverb', 'flanger', 'fuzz', 'amp', 'limiter', 'autotune', 'equalizer', 'maximizer', 'tremolo', 'stereo_panner', 'phaser'];
var studioHouse = {
	audio: null,
	plan: { sources: [], buses: [], sinks: [], routes: [] },
	states: {},
	timers: {},
	take: { bus: '', seconds: 600, timer: 0, recording: false, note: '' }
};

function studioHouseT(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function studioHouseNote(text) {
	$('#studio_house_patch_note').text(text || '');
}

function studioHouseTakeNote(text) {
	studioHouse.take.note = text || '';
	$('#studio_house_patch .studio_house_take_status').text(studioHouse.take.note);
}

function studioHouseEffectName(name) {
	name = String(name || '');
	return studioHouseInsertNames.indexOf(name) >= 0 ? name : '';
}

// The engine's name is the plan's, but one effect reads as its UI name; keep
// the wire name in the select's value and show this in the chain.
function studioHouseEffectLabel(name) {
	if (name === 'autotune') { return studioHouseT('JawnPitch'); }
	return name;
}

function studioHouseSource(id) {
	var found = null;
	$.each(studioHouse.plan.sources || [], function (i, source) {
		if (source && source.id === id) { found = source; return false; }
	});
	return found;
}

// Every route that leaves this source. A source normally feeds one bus, but a
// plan may send it to two; monitor/mute act on all of them so the source is
// never half muted.
function studioHouseRouteIndexes(plan, id) {
	var indexes = [];
	$.each((plan && plan.routes) || [], function (i, route) {
		if (route && route.from === id) { indexes.push(i); }
	});
	return indexes;
}

function studioHouseOnThisMachine(source, audio) {
	var machine = String((source && source.machine) || '');
	var host = String((audio && audio.machine) || '');
	if (!machine || !host) { return true; }
	return machine.toLowerCase() === host.toLowerCase();
}

// The engine's live line for one source, from the patch's `source_effects`.
// A source gain and mute are engine state rather than plan facts, so this is
// where the page reads back what the audio thread actually has.
function studioHouseSourceEffects(source, audio) {
	var id = (source && source.id) || '';
	var engine = (audio && audio.engine) || {};
	var found = null;
	$.each(engine.source_effects || [], function (i, row) {
		if (row && row.id === id) { found = row; return false; }
	});
	return found;
}

// The source's own trim, before its inserts. The plan carries the saved value;
// the live move writes both the plan and the engine, so the plan is the
// readback that survives a stale status poll.
function studioHouseSourceGain(source) {
	return (source && typeof source.gain === 'number') ? source.gain : 1;
}

// A source's footswitch is live engine state, not a plan field. A muted source
// still keeps its trim, so unmuting restores exactly what was set.
function studioHouseSourceMuted(source, audio) {
	var effects = studioHouseSourceEffects(source, audio);
	return !!(effects && effects.mute);
}

function studioHouseSourceIndex(id) {
	var index = -1;
	$.each(studioHouse.plan.sources || [], function (i, source) {
		if (source && source.id === id) { index = i; return false; }
	});
	return index;
}

// What the engine says about one source. `silent` is the patchbay's own word
// for a routed node this machine cannot bind; a peer and a handset carry their
// own pending/capturing state; an `input` is bound when the patch reports it in
// `inputs`. The bus take's status line drops the patch fields, so during a take
// the last patching answer keeps the labels instead of blanking them.
function studioHouseSourceState(source, audio) {
	var id = (source && source.id) || '';
	if (!audio || !audio.manage || !audio.engine_available) { return 'pending'; }
	var engine = audio.engine || {};
	if (!engine.state) { return 'pending'; }
	if (engine.state !== 'patching' && engine.state !== 'recording') { return 'pending'; }

	if ($.inArray(id, engine.silent || []) >= 0) {
		studioHouse.states[id] = 'silent';
		return 'silent';
	}
	if (engine.state === 'recording' && !engine.inputs && !engine.silent) {
		return studioHouse.states[id] || 'bound';
	}
	if (!studioHouseOnThisMachine(source, audio)) { return 'pending'; }

	var kind = (source && source.kind) || '';
	var state = 'bound';
	if (kind === 'input') {
		state = 'pending';
		$.each(engine.inputs || [], function (i, row) {
			if (row && row.id === id) { state = 'bound'; return false; }
		});
	}
	else if (kind === 'peer') {
		state = engine.peer === 'capturing' ? 'bound'
			: (engine.peer === 'pending' ? 'pending' : 'silent');
	}
	else if (kind === 'handset') {
		state = engine.handset === 'capturing' ? 'bound'
			: (engine.handset === 'pending' ? 'pending' : 'silent');
	}
	studioHouse.states[id] = state;
	return state;
}

function studioHouseEngineNote(audio) {
	if (!audio || !audio.manage) { return studioHouseT('The house mixer is not managed on this machine.'); }
	if (!audio.engine_available) { return studioHouseT('The engine is not running on this machine.'); }
	var engine = audio.engine || {};
	if (!engine.state || (engine.state !== 'patching' && engine.state !== 'recording')) {
		return studioHouseT('The plan is saved; the engine is not running it.');
	}
	return '';
}

// The panel arrives before the plan does, so fill the section once it is in the
// DOM. `x`/`y` are the press that opened the panel; the finished rows change its
// height, so it is clamped again after the render.
function studioHouseFill(panel, x, y) {
	var section = panel ? panel.find('#studio_house_patch') : $();
	if (!section.length) { return; }
	if (panel.find('#studio_plug_select').attr('direction') !== 'input') {
		section.hide();
		return;
	}
	section.data('studio_house_at', { x: x, y: y });
	studioHouseLoad();
}

function studioHouseLoad() {
	if (!$('#studio_house_patch').length) { return; }
	$.ajax({
		url: '/manager/sound/plan',
		type: 'GET',
		cache: false,
		success: function (audio) {
			studioHouseRender(audio || {});
			studioHouseTakeProbe();
		},
		error: function () { studioHouseNote(studioHouseT('The house patch could not be read')); }
	});
}

// A page that opens the picker while a house mix already records still offers
// Stop. One status answer arms the buttons; it never reports a finished take
// that was not started here.
function studioHouseTakeProbe() {
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'status' },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true || data.state !== 'recording' || !data.bus) { return; }
			studioHouse.take.recording = true;
			studioHouse.take.bus = data.bus;
			studioHouseTakeNote(studioHouseT('Recording') + ': ' + data.bus);
			studioHouseRender(studioHouse.audio || {});
			studioHouseTakePollStart();
		}
	});
}

function studioHouseSourceRow(source, audio) {
	var row = $('<div class="studio_house_source"></div>').attr('data-source', source.id || '');
	var head = $('<div class="studio_house_source_head"></div>');
	head.append($('<span class="studio_house_source_name"></span>').text(source.label || source.id || ''));
	var facts = [source.kind || ''];
	if (source.machine && !studioHouseOnThisMachine(source, audio)) { facts.push(source.machine); }
	else { facts.push(studioHouseT('this machine')); }
	head.append($('<span class="studio_house_source_kind"></span>').text(facts.join(' \u00b7 ')));
	var state = studioHouseSourceState(source, audio);
	head.append($('<span class="studio_house_source_state studio_house_state_' + state + '"></span>')
		.text(studioHouseT(state)));
	row.append(head);

	var indexes = studioHouseRouteIndexes(studioHouse.plan, source.id);
	if (!indexes.length) {
		row.append($('<p class="studio_house_no_route"></p>')
			.text(studioHouseT('Not routed into a bus, so the house mix cannot monitor it.')));
	}
	else {
		// The source's own trim is the monitor level; it runs before the
		// inserts, so a quieter source also drives the pedals less. The plan's
		// route gain stays the Sound matrix's mix fader.
		var gain = studioHouseSourceGain(source);
		var muted = studioHouseSourceMuted(source, audio);

		var monitor = $('<label class="studio_house_monitor"></label>')
			.attr('hint', studioHouseT('How loud this source sits in the house mix'));
		monitor.append($('<span></span>').text(studioHouseT('Monitor')));
		monitor.append($('<input type="range" min="0" max="4" step="0.01" class="studio_house_gain">')
			.val(gain)
			.attr('data-source', source.id || '')
			.prop('disabled', muted));
		monitor.append($('<span class="studio_house_monitor_value"></span>')
			.text(Math.round(gain * 100) + '%'));
		row.append(monitor);

		var mute = $('<label class="studio_house_mute_label"></label>')
			.attr('hint', studioHouseT('Mute this source in the house mix'));
		mute.append($('<input type="checkbox" class="studio_house_mute">')
			.attr('data-source', source.id || '')
			.prop('checked', muted));
		mute.append($('<span></span>').text(studioHouseT('Mute')));
		row.append(mute);
	}

	row.append(studioHouseInsertChain(source));
	return row;
}

function studioHouseInsertChain(source) {
	var chain = $('<div class="studio_house_inserts"></div>');
	chain.append($('<span class="studio_house_inserts_head"></span>').text(studioHouseT('Effects')));
	var inserts = source.inserts || [];
	if (!inserts.length) {
		chain.append($('<span class="studio_house_no_inserts"></span>').text(studioHouseT('none')));
	}
	$.each(inserts, function (index, insert) {
		var item = $('<span class="studio_house_insert"></span>');
		item.append($('<input type="checkbox" class="studio_house_insert_bypass">')
			.attr('data-source', source.id || '')
			.attr('data-index', index)
			.attr('hint', studioHouseT('Bypass this effect without removing it'))
			.prop('checked', !!insert.bypass));
		item.append($('<span class="studio_house_insert_name"></span>')
			.text(studioHouseEffectLabel(insert.name)));
		item.append($('<button type="button" class="studio_house_insert_remove"></button>')
			.text('\u00d7')
			.attr('data-source', source.id || '')
			.attr('data-index', index)
			.attr('hint', studioHouseT('Remove this effect from the chain')));
		chain.append(item);
	});

	var select = $('<select class="studio_house_insert_select"></select>')
		.attr('hint', studioHouseT('Choose an effect to add to this source\'s chain'));
	$.each(studioHouseInsertNames, function (i, name) {
		select.append($('<option></option>').attr('value', name).text(studioHouseEffectLabel(name)));
	});
	var add = $('<button type="button" class="studio_house_insert_add"></button>')
		.text(studioHouseT('Add'))
		.attr('data-source', source.id || '')
		.attr('hint', studioHouseT('Add the chosen effect to this source\'s chain'));
	chain.append(select).append(add);
	return chain;
}

function studioHouseTakeBus(plan) {
	var ids = $.map((plan && plan.buses) || [], function (bus) { return bus && bus.id; });
	if ($.inArray('mix', ids) >= 0) { return 'mix'; }
	if ($.inArray('house', ids) >= 0) { return 'house'; }
	return ids.length ? ids[0] : '';
}

// The bus take's click is the transport's own grid, monitor-only: the engine
// renders it on the patch's output after the bus is tapped. It is built even
// when the browser metronome is off, because it is the one click the performer
// hears while the house mix records.
function studioHouseClick() {
	if (!mixer['time']) { return null; }
	var bpm = studioKnobNumber(mixer['time']['bpm'], 120) || 120;
	var beats = studioKnobNumber(String(mixer['time']['sig'] || '4/4').split('/')[0], 4) || 4;
	var volume = studioKnobNumber($('.knob_control[channel="metronome"][control="volume"]').val(), 50);
	if (!isFinite(volume)) { volume = 50; }
	return {
		bpm: bpm,
		beats_per_bar: beats,
		gain: Math.max(0, Math.min(1, volume / 100))
	};
}

function studioHouseTakeSection() {
	var box = $('<div class="studio_house_take"></div>');
	box.append($('<span class="studio_house_take_head"></span>').text(studioHouseT('Record house mix')));
	var buses = (studioHouse.plan.buses || []);
	if (!buses.length) {
		box.append($('<span class="studio_house_take_note"></span>')
			.text(studioHouseT('The plan has no bus to record.')));
		return box;
	}

	var select = $('<select class="studio_house_take_bus"></select>')
		.attr('hint', studioHouseT('Choose which bus the house mix records'));
	$.each(buses, function (i, bus) {
		select.append($('<option></option>').attr('value', bus.id).text(bus.label || bus.id));
	});
	var preferred = studioHouse.take.bus || studioHouseTakeBus(studioHouse.plan);
	if (preferred) { select.val(preferred); }

	var seconds = $('<input type="number" min="1" step="1" class="studio_house_take_seconds">')
		.val(studioHouse.take.seconds || 600)
		.attr('aria-label', studioHouseT('How long the house mix runs, in seconds'))
		.attr('hint', studioHouseT('How long the house mix runs, in seconds'));

	var start = $('<button type="button" class="studio_house_take_start"></button>')
		.text(studioHouseT('Record house mix'))
		.prop('disabled', !!studioHouse.take.recording);
	var stop = $('<button type="button" class="studio_house_take_stop"></button>')
		.text(studioHouseT('Stop the house mix recording'))
		.prop('disabled', !studioHouse.take.recording);

	box.append(select).append(seconds).append(start).append(stop);
	var status = $('<span class="studio_house_take_status"></span>')
		.text(studioHouse.take.note || '');
	box.append(status);
	return box;
}

function studioHouseRender(audio) {
	audio = audio || {};
	studioHouse.audio = audio;
	studioHouse.plan = audio.plan || { sources: [], buses: [], sinks: [], routes: [] };
	var box = $('#studio_house_patch .studio_house_patch_sources');
	if (!box.length) { return; }
	box.empty();

	var sources = studioHouse.plan.sources || [];
	if (!sources.length) {
		box.append($('<p class="studio_empty"></p>')
			.text(studioHouseT('The Sound plan has no sources yet.')));
	}
	$.each(sources, function (i, source) {
		if (!source) { return; }
		box.append(studioHouseSourceRow(source, audio));
	});

	$('#studio_house_patch .studio_house_patch_take').empty()
		.append(studioHouseTakeSection());
	$('#studio_house_patch_engine').text(studioHouseEngineNote(audio));

	var section = $('#studio_house_patch');
	var at = section.data('studio_house_at');
	if (at && typeof studioPlugClamp === 'function') {
		studioPlugClamp($('#studio_plug_select_container'), at.x, at.y);
	}
}

// A plan fact (mute, an insert, a removal) is saved whole, the same path the
// Sound matrix uses. The answer carries the cleaned plan the engine compiled it
// from, so the section redraws what was actually stored.
function studioHouseSavePlan() {
	$.ajax({
		url: '/manager/sound/plan',
		type: 'POST',
		data: { plan: JSON.stringify(studioHouse.plan) },
		success: function (result) {
			result = result || {};
			if (result.plan) { studioHouse.plan = result.plan; }
			if (studioHouse.audio) { studioHouse.audio.plan = studioHouse.plan; }
			if (!result.ok) {
				studioHouseNote(result.error || studioHouseT('The house patch could not be saved'));
			}
			else {
				var applied = result.applied;
				studioHouseNote(applied && applied.ok && !applied.skipped
					? studioHouseT('Saved; the engine is running the plan')
					: studioHouseT('The house patch is saved'));
			}
			studioHouseRender(studioHouse.audio || {});
		},
		error: function () { studioHouseNote(studioHouseT('The house patch could not be saved')); }
	});
}

// One live source fader, coalesced the way the Sound matrix coalesces a drag.
// The engine clamps the value and refuses a source it does not have, so its
// answer is what the page relays. `gain` and `mute` are both source addresses:
// `gain` is the trim, `mute` is the footswitch, and neither re-patches.
function studioHouseSourceParam(id, name, value) {
	var index = studioHouseSourceIndex(id);
	if (index < 0) { return; }
	var key = 'source:' + name + ':' + index;
	if (studioHouse.timers[key]) { clearTimeout(studioHouse.timers[key]); }
	studioHouse.timers[key] = setTimeout(function () {
		$.ajax({
			url: '/manager/sound/param',
			type: 'POST',
			data: { target: 'patch_source', source: index, name: name, value: value },
			success: function (result) {
				result = result || {};
				if (!result.ok) {
					studioHouseNote(result.error || studioHouseT('The fader could not be set'));
					return;
				}
				// Keep the same document the next redraw reads, so a control
				// does not snap back to a stale status poll.
				var source = studioHouseSource(id);
				var effects = studioHouseSourceEffects(source, studioHouse.audio);
				if (effects) {
					if (name === 'gain') { effects.gain = Number(value); }
					if (name === 'mute') { effects.mute = Number(value) > 0.5; }
				}
			},
			error: function () { studioHouseNote(studioHouseT('The fader could not be set')); }
		});
	}, 120);
}

function studioHouseTakePollStart() {
	if (studioHouse.take.timer) { return; }
	studioHouse.take.timer = setInterval(studioHouseTakePoll, 1000);
}

function studioHouseTakePollStop() {
	if (studioHouse.take.timer) {
		clearInterval(studioHouse.take.timer);
		studioHouse.take.timer = 0;
	}
}

function studioHouseTakePoll() {
	if (!$('#studio_house_patch').length) { studioHouseTakePollStop(); return; }
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'status' },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			var state = data.state || '';
			var bus = data.bus || '';
			if (data.ok !== true || state !== 'recording' || bus !== studioHouse.take.bus) {
				studioHouseTakePollStop();
				studioHouse.take.recording = false;
				studioHouse.take.bus = '';
				studioHouseTakeNote(data.ok === true && state !== 'recording'
					? studioHouseT('The house mix finished') + (data.path ? ': ' + data.path : '')
					: (data.error || ''));
				studioHouseRender(studioHouse.audio || {});
				return;
			}
			studioHouse.take.recording = true;
			studioHouseTakeNote(studioHouseT('Recording') + ': ' + bus
				+ ' \u00b7 ' + (parseInt(data.frames, 10) || 0) + ' ' + studioHouseT('frames'));
		},
		error: function () { studioHouseTakePollStop(); }
	});
}

function studioHouseTakeStart() {
	var bus = $('#studio_house_patch .studio_house_take_bus').val() || '';
	if (!bus) {
		studioHouseTakeNote(studioHouseT('Choose a bus to record.'));
		return;
	}
	studioHouse.take.bus = bus;
	var seconds = $('#studio_house_patch .studio_house_take_seconds').val() || '600';
	studioHouse.take.seconds = Number(seconds) || 600;
	var click = studioHouseClick();
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		dataType: 'json',
		data: {
			action: 'start',
			bus: bus,
			seconds: seconds,
			click_json: click ? JSON.stringify(click) : ''
		},
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioHouseTakeNote(data.error || studioHouseT('The house mix could not start'));
				return;
			}
			studioHouse.take.recording = true;
			studioHouse.take.bus = data.bus || bus;
			studioHouseTakeNote(studioHouseT('Recording') + ': ' + studioHouse.take.bus);
			studioHouseRender(studioHouse.audio || {});
			studioHouseTakePollStart();
		},
		error: function (xhr) {
			var data = xhr && xhr.responseJSON;
			studioHouseTakeNote((data && data.error) || studioHouseT('The house mix could not start'));
		}
	});
}

function studioHouseTakeStop() {
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'stop' },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioHouseTakeNote(data.error || studioHouseT('The house mix could not stop'));
				return;
			}
			studioHouseTakePollStop();
			studioHouse.take.recording = false;
			studioHouse.take.bus = '';
			studioHouseTakeNote(studioHouseT('The house mix finished') + (data.path ? ': ' + data.path : ''));
			studioHouseRender(studioHouse.audio || {});
		},
		error: function (xhr) {
			var data = xhr && xhr.responseJSON;
			studioHouseTakeNote((data && data.error) || studioHouseT('The house mix could not stop'));
		}
	});
}

$(document).on('input', '.studio_house_gain', function () {
	var slider = $(this);
	var id = slider.attr('data-source') || '';
	var value = Number(slider.val());
	if (!isFinite(value)) { return; }
	slider.closest('.studio_house_monitor').find('.studio_house_monitor_value')
		.text(Math.round(value * 100) + '%');
	var source = studioHouseSource(id);
	if (source) { source.gain = value; }
	studioHouseSourceParam(id, 'gain', value);
});

$(document).on('change', '.studio_house_gain', function () {
	// The live fader has already moved the patch; the plan save makes the
	// position survive a reload.
	studioHouseSavePlan();
});

$(document).on('change', '.studio_house_mute', function () {
	var checkbox = $(this);
	var id = checkbox.attr('data-source') || '';
	var on = this.checked ? 1 : 0;
	var engine = (studioHouse.audio && studioHouse.audio.engine) || {};
	if (engine.state !== 'patching') {
		// A mute is a live engine footswitch, not a plan fact, so there is
		// nothing to save when the mixer is not running.
		this.checked = !this.checked;
		studioHouseNote(studioHouseT('The house mixer is not running, so the mute could not be set.'));
		return;
	}
	studioHouseSourceParam(id, 'mute', on);
});

$(document).on('change', '.studio_house_insert_bypass', function () {
	var id = $(this).attr('data-source') || '';
	var index = Number($(this).attr('data-index'));
	var source = studioHouseSource(id);
	if (!source || !source.inserts || !source.inserts[index]) { return; }
	source.inserts[index].bypass = this.checked ? 1 : 0;
	studioHouseSavePlan();
});

$(document).on('click', '.studio_house_insert_remove', function () {
	var id = $(this).attr('data-source') || '';
	var index = Number($(this).attr('data-index'));
	var source = studioHouseSource(id);
	if (!source || !source.inserts || !source.inserts[index]) { return; }
	source.inserts.splice(index, 1);
	studioHouseSavePlan();
});

$(document).on('click', '.studio_house_insert_add', function () {
	var id = $(this).attr('data-source') || '';
	var source = studioHouseSource(id);
	if (!source) { return; }
	var select = $(this).closest('.studio_house_inserts').find('.studio_house_insert_select');
	var name = studioHouseEffectName(select.val());
	if (!name) { return; }
	if (!source.inserts) { source.inserts = []; }
	source.inserts.push({ name: name, bypass: 0, controls: {} });
	studioHouseSavePlan();
});

$(document).on('change', '.studio_house_take_bus', function () {
	studioHouse.take.bus = $(this).val() || '';
});

$(document).on('change', '.studio_house_take_seconds', function () {
	studioHouse.take.seconds = Number($(this).val()) || 600;
});

$(document).on('click', '.studio_house_take_start', function () { studioHouseTakeStart(); });
$(document).on('click', '.studio_house_take_stop', function () { studioHouseTakeStop(); });
