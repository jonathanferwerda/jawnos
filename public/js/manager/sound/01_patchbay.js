// ---- the house patchbay -----------------------------------------------------
// The plan is one document for the whole house (docs/studio-audio-roadmap.md
// §8). The page edits it in memory and saves it whole; the engine on the
// machine that holds the interface compiles it. A node this machine cannot
// bind (a peer, a zone) stays in the plan and simply contributes nothing here.

var soundPlan = { sources: [], buses: [], sinks: [], routes: [] };
var soundAudio = null;
var soundPatchFaderTimers = {};
var soundPatchFaderErrorShown = false;

function soundPatchNodeIds() {
	var ids = [];
	$.each(['sources', 'buses', 'sinks'], function(i, kind) {
		$.each(soundPlan[kind] || [], function(j, node) {
			if (node && node.id && $.inArray(node.id, ids) < 0) { ids.push(node.id); }
		});
	});
	return ids;
}

function soundPatchNote(text) { $('#sound_patch_note').text(text || ''); }
// The picker's choices come from the manager as `devices` (ALSA cards, then
// PipeWire and null) and `engine_device` (the saved choice). The running
// engine's backend/device is `engine`; a difference means the engine still
// has the old device and Apply will restart it.
function soundPatchDeviceValue(choice) {
	return (choice && choice.backend ? choice.backend : '') + '|'
		+ (choice && choice.device ? choice.device : '');
}

function soundPatchDeviceRender() {
	var select = $('#sound_engine_device');
	if (!select.length) { return; }
	var devices = (soundAudio && soundAudio.devices) || [];
	var saved = (soundAudio && soundAudio.engine_device) || {};
	var running = (soundAudio && soundAudio.engine) || {};
	select.empty();
	$.each(devices, function(i, device) {
		var value = device.id || (device.backend + '|' + device.device);
		select.append($('<option></option>').attr('value', value)
			.text(device.name || device.id || device.device));
	});
	var chosen = saved.backend ? soundPatchDeviceValue(saved)
		: (running.backend ? soundPatchDeviceValue(running) : '');
	if (chosen) { select.val(chosen); }
	var note = '';
	if (running.backend && saved.backend
		&& (running.backend !== saved.backend || running.device !== saved.device)) {
		note = jawnosT('The engine is on') + ' ' + (running.device || running.backend)
			+ '; ' + jawnosT('apply to switch');
	}
	$('#sound_engine_device_note').text(note);
}

function soundPatchDeviceApply() {
	var value = $('#sound_engine_device').val() || '';
	var parts = value.split('|');
	if (parts.length != 2 || !parts[0] || !parts[1]) { return; }
	$.ajax({
		url: '/manager/sound/device',
		type: 'POST',
		data: { backend: parts[0], device: parts[1] },
		success: function(result) {
			result = result || {};
			if (!result.ok) {
				soundPatchNote(result.error || jawnosT('The engine device could not be saved'));
				return;
			}
			soundPatchNote(jawnosT('Device saved; the engine is restarting'));
			setTimeout(soundPatchLoad, 1500);
		},
		error: function() { soundPatchNote(jawnosT('The engine device could not be saved')); }
	});
}


// The uplink is one house-wide address, empty for off. The engine's own status
// says whether an uplink is configured (`uplink.state`) and how the patch treats
// a peer (`peer`: off, pending or capturing); the saved address is what the
// field shows, so a value that has not reached the engine reads back too.
function soundPatchUplinkRender() {
	var field = $('#sound_uplink');
	if (!field.length) { return; }
	if (!field.is(':focus')) {
		field.val((soundAudio && soundAudio.uplink) || '');
	}
	var engine = (soundAudio && soundAudio.engine) || {};
	var uplink = engine.uplink || {};
	var state;
	if (!soundAudio || !soundAudio.uplink) {
		state = jawnosT('off');
	}
	else if (!soundAudio.engine_available) {
		state = jawnosT('The engine is not running on this machine');
	}
	else {
		state = uplink.state || jawnosT('waiting');
	}
	if (engine.peer) {
		state += ' \u00b7 ' + jawnosT('peer') + ' ' + engine.peer;
	}
	$('#sound_uplink_state').text(state);
}

function soundPatchUplinkSave() {
	var value = ($('#sound_uplink').val() || '').replace(/^\s+|\s+$/g, '');
	$.ajax({
		url: '/manager/sound/plan',
		type: 'POST',
		data: { uplink: value },
		success: function(result) {
			result = result || {};
			if (!result.ok) {
				soundPatchNote(result.error || jawnosT('The uplink could not be saved'));
				return;
			}
			var applied = result.applied;
			if (applied && applied.ok && !applied.skipped) {
				soundPatchNote(jawnosT('Uplink saved; the engine is restarting'));
				setTimeout(soundPatchLoad, 1500);
			}
			else {
				soundPatchNote(jawnosT('Uplink saved'));
				soundPatchLoad();
			}
		},
		error: function() { soundPatchNote(jawnosT('The uplink could not be saved')); }
	});
}

$(document).on('click', '#sound_uplink_save', function() { soundPatchUplinkSave(); });

function soundPatchSelect(ids, value) {
	var select = $('<select></select>');
	$.each(ids, function(i, id) { select.append($('<option></option>').attr('value', id).text(id)); });
	if (value) { select.val(value); }
	return select;
}

// A live fader trims the running patch without re-arming it. The slider's
// `input` updates the local route at once, then this debounces one POST per
// route+name (120 ms) so a drag is a handful of engine commands, not one per
// pixel. A muted route never posts, and a failure shows at most one note.
function soundPatchFader(routeIndex, name, value) {
	if (!soundAudio || !soundAudio.manage || !soundAudio.engine_available) { return; }
	var key = routeIndex + ':' + name;
	if (soundPatchFaderTimers[key]) { clearTimeout(soundPatchFaderTimers[key]); }
	soundPatchFaderTimers[key] = setTimeout(function() {
		$.ajax({
			url: '/manager/sound/param',
			type: 'POST',
			data: { route: routeIndex, name: name, value: value },
			success: function(result) {
				result = result || {};
				if (result.ok) { soundPatchFaderErrorShown = false; }
				else if (!soundPatchFaderErrorShown) {
					soundPatchFaderErrorShown = true;
					soundPatchNote(result.error || jawnosT('The fader could not be set'));
				}
			},
			error: function() {
				if (!soundPatchFaderErrorShown) {
					soundPatchFaderErrorShown = true;
					soundPatchNote(jawnosT('The fader could not be set'));
				}
			}
		});
	}, 120);
}

function soundPatchNodeRow(kind, node, index, latency) {
	var row = $('<div class="sound_patch_node"></div>');
	row.append($('<span class="sound_patch_node_id"></span>').text(node.label || node.id || ''));
	var facts = (node.kind || '') + (node.channel ? ' ch' + node.channel : '');
	if (node.machine) { facts += ' @ ' + node.machine; }
	if (latency) { facts += ' \u00b7 ' + latency + ' ms'; }
	row.append($('<span class="sound_patch_node_kind"></span>').text(facts));
	// A peer's declared latency is a plan fact, not a live trim: it is held in
	// the node and the next Save plan patches the engine, which reads it then.
	if (kind == 'sources' && (node.kind || '') == 'peer') {
		var peer_latency = $('<input type="number" class="sound_peer_latency" min="0" max="2000" step="1">')
			.val(node.latency_ms == null ? 0 : node.latency_ms)
			.attr('aria-label', jawnosT('Peer latency in milliseconds'))
			.attr('hint', jawnosT('How late this peer\'s audio arrives, in milliseconds: 0 to 2000, and the engine places it that much earlier'));
		peer_latency.on('change', function() {
			var raw = $.trim(peer_latency.val());
			var value = Number(raw);
			if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(raw) || value < 0 || value > 2000) {
				peer_latency.val(node.latency_ms == null ? 0 : node.latency_ms);
				soundPatchNote(jawnosT('A peer\'s latency is a number of milliseconds from 0 to 2000'));
				return;
			}
			node.latency_ms = value;
			soundPatchNote(jawnosT('Held in the plan; it applies when the plan is saved and the engine patches the peer source'));
		});
		var field = $('<label class="sound_patch_node_latency"></label>');
		field.append($('<span></span>').text(jawnosT('Peer latency')));
		field.append(peer_latency);
		field.append($('<span class="sound_patch_node_unit"></span>').text('ms'));
		row.append(field);
	}
	var remove = $('<button type="button"></button>').text(jawnosT('Remove'));
	remove.on('click', function() {
		soundPlan[kind].splice(index, 1);
		soundPlan.routes = $.grep(soundPlan.routes || [], function(route) {
			return route.from != node.id && route.to != node.id;
		});
		soundPatchRender();
	});
	row.append(remove);
	return row;
}

function soundPatchGroup(kind, title, latency) {
	var box = $('<div class="sound_patch_group"></div>');
	box.append($('<h4></h4>').text(title));
	var list = soundPlan[kind] || [];
	if (!list.length) { box.append($('<p class="sound_empty"></p>').text(jawnosT('none yet'))); }
	$.each(list, function(index, node) {
		box.append(soundPatchNodeRow(kind, node, index,
			kind == 'sinks' && latency ? latency[node.id] : 0));
	});
	return box;
}

function soundPatchRouteRow(route, index, ids) {
	var row = $('<tr></tr>');
	var from = soundPatchSelect(ids, route.from);
	from.on('change', function() { route.from = $(this).val(); });
	var to = soundPatchSelect(ids, route.to);
	to.on('change', function() { route.to = $(this).val(); });
	var gain = $('<input type="range" min="0" max="1" step="0.01">').val(route.gain == null ? 1 : route.gain);
	gain.on('input', function() {
		route.gain = parseFloat(this.value);
		if (!route.mute) { soundPatchFader(index, 'gain', route.gain); }
	});
	var pan = $('<input type="range" min="-1" max="1" step="0.01">').val(route.pan == null ? 0 : route.pan);
	pan.on('input', function() {
		route.pan = parseFloat(this.value);
		if (!route.mute) { soundPatchFader(index, 'pan', route.pan); }
	});
	var mute = $('<input type="checkbox">').prop('checked', !!route.mute);
	mute.on('change', function() { route.mute = this.checked ? 1 : 0; });
	var remove = $('<button type="button"></button>').text(jawnosT('Remove'));
	remove.on('click', function() { soundPlan.routes.splice(index, 1); soundPatchRender(); });
	row.append($('<td></td>').append(from));
	row.append($('<td></td>').append(to));
	row.append($('<td></td>').append(gain));
	row.append($('<td></td>').append(pan));
	row.append($('<td></td>').append(mute));
	row.append($('<td></td>').append(remove));
	return row;
}

function soundPatchRender(audio) {
	if (audio) {
		soundAudio = audio;
		if (audio.plan) { soundPlan = audio.plan; }
		var machine = audio.machine || '';
		$('#sound_source_machine').val(machine);
		$('#sound_sink_machine').val(machine);
	}
	var box = $('#sound_patch_matrix');
	if (!box.length) { return; }
	box.empty();
	var latency = (soundAudio && soundAudio.latency) || {};
	box.append(soundPatchGroup('sources', jawnosT('Sources')));
	box.append(soundPatchGroup('buses', jawnosT('Buses')));
	box.append(soundPatchGroup('sinks', jawnosT('Sinks'), latency));

	var ids = soundPatchNodeIds();
	var table = $('<table class="sound_patch_routes"></table>');
	var head = $('<tr></tr>');
	$.each([jawnosT('From'), jawnosT('To'), jawnosT('Gain'), jawnosT('Pan'), jawnosT('Mute'), ''], function(i, label) {
		head.append($('<th></th>').text(label));
	});
	table.append(head);
	$.each(soundPlan.routes || [], function(index, route) {
		table.append(soundPatchRouteRow(route, index, ids));
	});
	box.append(table);

	$('#sound_route_from').empty();
	$('#sound_route_to').empty();
	$.each(ids, function(i, id) {
		$('#sound_route_from').append($('<option></option>').attr('value', id).text(id));
		$('#sound_route_to').append($('<option></option>').attr('value', id).text(id));
	});

	$('#sound_manage').prop('checked', !!(soundAudio && soundAudio.manage));
	var engine = (soundAudio && soundAudio.engine) || null;
	var state = '';
	if (!soundAudio || !soundAudio.manage) {
		state = jawnosT('The engine does not own this machine');
	}
	else if (!soundAudio.engine_available) {
		state = jawnosT('The engine is not running on this machine');
	}
	else if (engine && engine.state) {
		var stateWord = engine.state;
		if (stateWord == 'patching') { stateWord = jawnosT('patching'); }
		else if (stateWord == 'idle') { stateWord = jawnosT('idle'); }
		else if (stateWord == 'done') { stateWord = jawnosT('done'); }
		state = jawnosT('The engine is') + ' ' + stateWord + ' \u2014 '
			+ (parseInt(engine.frames, 10) || 0) + ' ' + jawnosT('frames');
		if (engine.xruns != null) {
			state += ' \u00b7 ' + (parseInt(engine.xruns, 10) || 0) + ' ' + jawnosT('xruns');
		}
		if (engine.rate != null && engine.period != null) {
			state += ' \u00b7 ' + engine.rate + ' Hz / ' + engine.period;
		}
		else if (engine.rate != null) {
			state += ' \u00b7 ' + engine.rate + ' Hz';
		}
		else if (engine.period != null) {
			state += ' \u00b7 ' + jawnosT('period') + ' ' + engine.period;
		}
		var silent = (engine.silent && engine.silent.length) || 0;
		if (silent) { state += ' \u00b7 ' + silent + ' ' + jawnosT('silent'); }
		if (engine.machine) { state += ' \u00b7 ' + engine.machine; }
		if (engine.backend) {
			state += ' \u00b7 ' + engine.backend + ' ' + (engine.device || '');
		}
	}
	else {
		state = jawnosT('The engine is running, but this plan is not patched');
	}
	$('#sound_engine_state').text(state);
	soundPatchDeviceRender();
	soundPatchUplinkRender();
}

function soundPatchLoad() {
	if (!$('.wind[app="sound"]').length) { return; }
	$.ajax({
		url: '/manager/sound/plan',
		type: 'GET',
		cache: false,
		success: soundPatchRender,
		error: function() { soundPatchNote(jawnosT('The plan could not be read')); }
	});
}

function soundPatchSave() {
	$.ajax({
		url: '/manager/sound/plan',
		type: 'POST',
		data: { plan: JSON.stringify(soundPlan) },
		success: function(result) {
			result = result || {};
			if (result.plan) { soundPlan = result.plan; }
			soundPatchRender();
			if (!result.ok) {
				soundPatchNote(result.error || jawnosT('The plan could not be saved'));
				return;
			}
			var applied = result.applied;
			if (applied && applied.ok) {
				soundPatchNote(jawnosT('Saved; the engine is running the plan'));
			}
			else if (applied && applied.skipped) {
				soundPatchNote(jawnosT('Saved; the engine does not own this machine'));
			}
			else if (applied && applied.error) {
				soundPatchNote(jawnosT('Saved, but the engine did not apply it:') + ' ' + applied.error);
			}
			else {
				soundPatchNote(jawnosT('Saved'));
			}
			soundPatchLoad();
		},
		error: function() { soundPatchNote(jawnosT('The plan could not be saved')); }
	});
}

function soundPatchManage(on) {
	$.ajax({
		url: '/manager/sound/manage',
		type: 'POST',
		data: { manage: on ? 1 : 0 },
		success: function(result) {
			result = result || {};
			var applied = result.applied;
			var mix = applied && applied.system_mix;
			var note = '';
			if (applied && applied.error) { note = applied.error; }
			else if (mix && mix.error) { note = mix.error; }
			else if (mix && mix.recovered) {
				// The app died mid-mix and the wipe took the record; the switch still
				// handed the machine back. Say so rather than pretend nothing happened.
				note = jawnosT('The switch is off; the mix was still in place without its record, and the machine has its output back');
			}
			soundPatchNote(note);
			soundPatchLoad();
		},
		error: function() { soundPatchNote(jawnosT('The switch could not be saved')); }
	});
}

function soundPatchAddNode(kind, id, node) {
	if (!id) { soundPatchNote(jawnosT('A node needs a name')); return; }
	if ($.inArray(id, soundPatchNodeIds()) >= 0) {
		soundPatchNote(jawnosT('That name is already in the plan'));
		return;
	}
	soundPlan[kind] = soundPlan[kind] || [];
	soundPlan[kind].push(node);
	soundPatchRender();
}
