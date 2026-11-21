// ===========================================================================
// The per-track board
// ===========================================================================
// Every channel owns an ordered list of inserts in studioAudio.channels[ch],
// and this part is the UI over that list. The pedalboard is the one FX surface:
// its Add list puts the chosen effect into the chain, and the sheet draws the
// selected track's chain as the stompbox tiles it holds, in signal order. Drag
// a tile to reorder it, press its lamp or stomp to bypass it, and use the small
// tools on the tile for Up, Down and X. A track's panel never lists effects, so
// choosing one can never cramp its FX/Monitor/Auto/Delete row. The song keeps
// the order and the on/off state in the channel's `fx` records (see
// studioSaver / studioRetriever).
//
// A channel has two chains: In is before the recording (the take is wet) and
// Out is after it (the take stays clean). The board shows one at a time; every
// action below works on the chain the board shows.

// The chain a tile is being dragged from, held only for the duration of a drop.
var studioRackDragChain = null;

function studioRackFind(ch, name, chain) {
	var c = studioAudio.channels[ch];
	if (!c) { return null; }
	chain = chain || studioChannelChain(ch);
	var map = (chain === 'out') ? c.outInsertByName : c.insertByName;
	return map[name] || null;
}

// A tile with no library entry (an old song's name, or a future effect) is
// drawn from the contract instead, so it still has knobs and a stomp.
function studioRackFallbackTile(ins) {
	var spec = studioEffectSpec(ins.name);
	var tile = $('<span class="pedal pedal_graphic studio_rack_tile"></span>');
	$('<span class="studio_pedal_led" role="button" aria-pressed="false"></span>')
		.attr('hint', studioLayoutText('Turn this pedal on or off for this track')).appendTo(tile);
	$('<span class="pedal_body" aria-hidden="true"></span>').appendTo(tile);
	$('<b class="pedal_title"></b>')
		.text(studioLayoutText(spec && spec['label'] ? spec['label'] : ins.name)).appendTo(tile);
	var controls = $('<span class="pedal_controls"></span>');
	$.each((spec && spec['controls']) || [], function (i, control) {
		var label = $('<label class="pedal_select_row"></label>');
		$('<span class="pedal_knob_label"></span>')
			.text(studioLayoutText(control['label'] || control['control'])).appendTo(label);
		var input;
		if (control['options']) {
			input = $('<select class="studio_pedal_model pedal_select"></select>');
			$.each(control['options'], function (index, option) {
				$('<option></option>').attr('value', index).text(studioLayoutText(option)).appendTo(input);
			});
		}
		else {
			input = $('<input type="range" min="0" max="100" class="knob_control" style="display:none;">');
		}
		input.attr('control', control['control']).attr('channel', ins.name).appendTo(label);
		label.appendTo(controls);
	});
	controls.appendTo(tile);
	$('<button class="studio_pedal_foot hover" aria-pressed="false"></button>')
		.attr('hint', studioLayoutText('Bypass this effect without removing it')).text(studioLayoutText('On')).appendTo(tile);
	return tile;
}

// One insert as the stompbox the chain holds. The library above supplies the
// artwork, knobs, button and tuner display; the clone carries this insert's
// name so its controls and its X act on the effect in this chain.
function studioRackTile(ch, ins, chain) {
	var kind = studioEffectKind(ins.name);
	var source = $('#studio_pedalboard_tiles .pedal').filter(function () {
		return studioEffectKind($(this).attr('data-effect')) === kind;
	}).first();
	var tile = source.length ? source.clone() : studioRackFallbackTile(ins);
	tile.removeAttr('id').find('[id]').removeAttr('id');
	tile.addClass('studio_rack_tile')
		.attr('channel', ch).attr('insert', ins.name).attr('chain', chain || 'in')
		.attr('data-effect', ins.name);
	// The controls belong to this insert, not to the library's macro name.
	tile.find('[channel]').attr('channel', ins.name);
	tile.find('[effect]').attr('effect', ins.name);
	// The insert's own values are the ones the knobs and dropdowns show. A fresh
	// insert takes the tile's defaults, exactly as the old shelf did on entry.
	tile.find('.knob_control, .studio_pedal_model').each(function () {
		var control = $(this).attr('control');
		var value = (ins.values && ins.values[control] !== undefined) ? ins.values[control] : $(this).val();
		$(this).val(value);
		if ((!ins.values || ins.values[control] === undefined) && value !== undefined) {
			ins.set(control, value);
		}
	});
	if (ins.bypassed) { tile.addClass('studio_rack_off'); }
	// Small tools on the frame: touch order and removal without leaving the board.
	var tools = $('#studio_board_tool_template').first().clone();
	tools.removeAttr('id').removeAttr('style').removeAttr('aria-hidden');
	if (tools.length) { tools.appendTo(tile); }
	return tile;
}

function studioRackRender(ch) {
	var holder = $('#studio_pedalboard_rack');
	var header = $('#studio_pedalboard_chain');
	var c = studioAudio.channels[ch];
	if (!holder.length || !c) { return; }
	// One sheet, one chain: a render for a track that is not selected would put
	// the wrong inserts under the Add bar, so it is skipped.
	if (String(ch) !== String(studioPaletteChannel())) { return; }
	var chain = studioChannelChain(ch);
	// every board action reads this attribute to find its channel
	holder.attr('channel', ch);
	header.attr('channel', ch).empty();
	holder.empty();
	// In is before the recording, so its pedals print into the take; Out is
	// after it, so the take stays clean. One switch chooses what the board shows
	// and what the palette adds to.
	var toggle = $('<span class="studio_chain_toggle"></span>');
	$.each([['in', 'In', 'Before the recording'], ['out', 'Out', 'After the recording']], function (i, choice) {
		$('<button class="studio_chain_choice hover"></button>')
			.attr('chain', choice[0])
			.attr('aria-pressed', chain === choice[0] ? 'true' : 'false')
			.attr('hint', studioLayoutText(choice[2]))
			.text(studioLayoutText(choice[1]))
			.appendTo(toggle);
	});
	header.append(toggle);
	var list = (chain === 'out') ? c.outInserts : c.inserts;
	list.forEach(function (ins) { holder.append(studioRackTile(ch, ins, chain)); });
	if (!list.length) {
		holder.append($('<span class="studio_board_empty"></span>')
			.text(studioLayoutText('Add an effect to this chain')));
	}
	if (holder.children('.studio_rack_tile').length && typeof holder.sortable === 'function' && !holder.hasClass('ui-sortable')) {
		// jQuery UI sortable is the house drag helper (the taskbar uses it too).
		// Its default cancel list keeps the knobs, dropdowns and stomp usable. A
		// finished drag settles on `update`; `stop` is the fallback for a drop that
		// changed nothing. Either way the tile's place is written to the chain and
		// the board is drawn again from that model.
		var dropped = false;
		var settle = function (event, ui) {
			var holder = ui.item.closest('.studio_channel_rack');
			// the channel and chain come from the tile itself, not this render's
			// closure: the tile knows where the drop put it
			var to = String(holder.attr('channel') || ui.item.attr('channel') || '');
			var from = String(ui.item.attr('channel') || to);
			var name = ui.item.attr('insert');
			var chain = String(ui.item.attr('chain') || '');
			if (!name || !to) { return; }
			// Let sortable finish its own stop before the board is rebuilt; the drop
			// position is already known, so the work is deferred, not lost.
			setTimeout(function () {
				studioRackDragChain = chain || studioChannelChain(from);
				if (from !== to) { studioRackMoveInsert(from, to, name); } else { studioRackReorder(to); }
				studioRackDragChain = null;
			}, 0);
		};
		holder.sortable({
			items: '> .studio_rack_tile',
			axis: 'x',
			tolerance: 'pointer',
			// Every tile lives on the one board, so a drop lands in the same chain;
			// the settle handler still tolerates a tile that says it came from elsewhere.
			connectWith: '.studio_channel_rack',
			placeholder: 'studio_rack_placeholder',
			forcePlaceholderSize: true,
			// the clone rides the body, above every panel and the pedal sheet
			helper: 'clone',
			appendTo: 'body',
			zIndex: 90000,
			// Knobs, dropdowns, the lamp and the stomp stay clickable; the artwork is
			// the handle, as it was on the shelf.
			cancel: '.knob, .knob_control, .pedal_knob, .pedal_select_row, .studio_pedal_foot, .studio_pedal_led, .studio_board_tools, select, option, input, button',
			cursor: 'var(--jawnos-cursor-grabbing, grabbing)',
			update: function (event, ui) {
				dropped = true;
				settle(event, ui);
			},
			stop: function (event, ui) {
				if (!dropped) { settle(event, ui); }
				dropped = false;
			}
		});
	}
}

function studioRackRenderAll() {
	// the sheet carries one chain at a time, so only the selected track draws
	studioRackRender(studioPaletteChannel());
	studioPaletteLabel();
	studioUpdatePedalLamps();
}

// Move one insert from one channel's chain to another, keeping the order the
// dropped row landed in. The row's chain travels with it, so a drop between
// tracks stays in the same chain. The source's audio chain is rebuilt without
// it and the destination's with it; the song's fx order follows.
function studioRackMoveInsert(from, to, name) {
	var src = studioAudio.channels[from];
	var dst = studioAudio.channels[to];
	if (!src || !dst) { return; }
	var chain = (studioRackDragChain === 'out') ? 'out' : 'in';
	var out = chain === 'out';
	var srcMap = out ? src.outInsertByName : src.insertByName;
	var dstMap = out ? dst.outInsertByName : dst.insertByName;
	var ins = srcMap[name];
	if (!ins) { return; }
	delete srcMap[name];
	if (out) { src.outInserts = src.outInserts.filter(function (x) { return x !== ins; }); }
	else { src.inserts = src.inserts.filter(function (x) { return x !== ins; }); }
	if (out) { dst.outInserts.push(ins); }
	else { dst.inserts.push(ins); }
	dstMap[name] = ins;
	var order = [];
	$('#studio_pedalboard_rack .studio_rack_tile').each(function () {
		order.push($(this).attr('insert'));
	});
	var next = [];
	order.forEach(function (n) {
		var x = dstMap[n];
		if (x && next.indexOf(x) === -1) { next.push(x); }
	});
	var dstList = out ? dst.outInserts : dst.inserts;
	dstList.forEach(function (x) { if (next.indexOf(x) === -1) { next.push(x); } });
	if (out) { dst.outInserts = next; } else { dst.inserts = next; }
	// the moved insert's edges belong to its old channel's graph
	if (ins.output) { try { ins.output.disconnect(); } catch (e) {} }
	studioRebuildInserts(from);
	studioRebuildInserts(to);
	studioRebuildOutputs(from);
	studioRebuildOutputs(to);
	studioRackRender(from);
	studioRackRender(to);
	studioUpdateFxBadges();
	studioSaver();
}

function studioRackReorder(ch) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	var chain = studioChannelChain(ch);
	var out = chain === 'out';
	var map = out ? c.outInsertByName : c.insertByName;
	var list = out ? c.outInserts : c.inserts;
	var order = [];
	$('#studio_pedalboard_rack .studio_rack_tile').each(function () {
		order.push($(this).attr('insert'));
	});
	var next = [];
	order.forEach(function (name) {
		var ins = map[name];
		if (ins && next.indexOf(ins) === -1) { next.push(ins); }
	});
	// An insert the DOM does not know about (a race while rendering) keeps its
	// place at the end rather than falling out of the chain.
	list.forEach(function (ins) { if (next.indexOf(ins) === -1) { next.push(ins); } });
	if (out) { c.outInserts = next; studioRebuildOutputs(ch); }
	else { c.inserts = next; studioRebuildInserts(ch); }
	// The drag only moved DOM nodes; redraw the rows from the chain now, then
	// paint their lamps (and let a listening tuner follow its insert).
	studioRackRender(ch);
	studioUpdatePedalLamps();
	studioSaver();
}

function studioRackMove(ch, name, delta) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	var chain = studioChannelChain(ch);
	var out = chain === 'out';
	var map = out ? c.outInsertByName : c.insertByName;
	var list = out ? c.outInserts : c.inserts;
	var ins = map[name];
	var at = list.indexOf(ins);
	if (at < 0) { return; }
	var to = at + delta;
	if (to < 0 || to >= list.length) { return; }
	list.splice(at, 1);
	list.splice(to, 0, ins);
	if (out) { studioRebuildOutputs(ch); } else { studioRebuildInserts(ch); }
	studioRackRender(ch);
	studioSaver();
}

// The footswitch: bypass in place, never remove (contract rule 5).
function studioSetInsertBypass(ch, name, on) {
	var chain = studioChannelChain(ch);
	var ins = studioRackFind(ch, name, chain);
	if (!ins) {
		// A row lamp describes the chain the rack shows even while the rack shows
		// Out, so a pedal the shown chain does not hold is switched where it lives.
		chain = (chain === 'out') ? 'in' : 'out';
		ins = studioRackFind(ch, name, chain);
	}
	if (!ins) { return; }
	if (ins.setBypass) { ins.setBypass(on); }
	else { ins.bypassed = !!on; }
	studioUpdateFxBadges();
	studioRackRender(ch);
	studioUpdatePedalLamps();
	studioSaver();
}

// ---- the lamps -------------------------------------------------------------
//
// Every rack row wears the same lamp: green when the effect is on for the
// selected track, dark red when it is bypassed. The insert is the state; the
// lamp only reads it, so the rack's own footswitch and the lamp can never
// disagree.
function studioPedalInsert(ch, name) {
	// The lamp describes the chain the rack shows; a pedal that only lives in
	// the input chain still reads on, and is switched where it lives.
	var chain = studioChannelChain(ch);
	var direct = studioRackFind(ch, name, chain) || studioRackFind(ch, name, 'in');
	if (direct) { return direct; }
	var c = studioAudio.channels[ch];
	if (!c) { return null; }
	var kind = studioEffectKind(name);
	var found = null;
	var lists = (chain === 'out') ? [c.outInserts, c.inserts] : [c.inserts, c.outInserts];
	lists.forEach(function (list) {
		list.forEach(function (ins) {
			if (!found && studioEffectKind(ins.name) === kind) { found = ins; }
		});
	});
	return found;
}

// The lamp's label says the state in words, not just the colour.
function studioPedalLampLabel(on) {
	return studioLayoutText(on ? 'On for this track' : 'Off for this track');
}

function studioUpdatePedalLamps() {
	// every tile on the board, painted from the insert it stands for
	$('#studio_pedalboard_rack .studio_rack_tile').each(function () {
		var tile = $(this);
		var ins = studioRackFind(studioPaletteChannel(), tile.attr('insert'), tile.attr('chain'));
		var on = !!(ins && !ins.bypassed);
		var label = studioPedalLampLabel(on);
		tile.toggleClass('studio_rack_off', !on);
		if (tile.attr('data-tuner') === 'yes') {
			// Jtune's lamp is the tuner's light (grey off, amber listening, green in tune)
			if (typeof studioTunerPaintLamp === 'function') { studioTunerPaintLamp(tile); }
		}
		else {
			tile.find('.studio_pedal_led').attr({
				'aria-pressed': on ? 'true' : 'false',
				title: label,
				hint: label
			});
		}
		tile.find('.studio_pedal_foot')
			.attr('aria-pressed', on ? 'true' : 'false')
			.text(studioLayoutText(on ? 'On' : 'Off'));
	});
	// the tuner listens only while its insert is on, wherever the board puts it
	if (typeof studioTunerSync === 'function') { studioTunerSync(); }
}

// The lamp is the footswitch: absent means switch it on in this track's rack,
// present means bypass it in place exactly as the rack row does.
function studioTogglePedal(ch, name) {
	var ins = studioPedalInsert(ch, name);
	if (!ins) { studioSetInsert(ch, name, true); }
	else { studioSetInsertBypass(ch, ins.name, !ins.bypassed); }
	studioUpdatePedalLamps();
	studioSaver();
}

function studioInsertControl(ch, name, control, value) {
	var chain = studioChannelChain(ch);
	var ins = studioRackFind(ch, name, chain);
	if (!ins) { return; }
	ins.set(control, value);
	// The engine hears the same knob in the contract's units, but only for the
	// input chain and only while it is the path that is playing (see
	// studioEngineInsertParam). An output insert is browser-only, so it never
	// reaches the engine.
	if (chain !== 'out') { studioEngineInsertParam(ch, name, control, value); }
	studioSaver();
}

// ---- the palette -----------------------------------------------------------

function studioPaletteChannel() {
	var ch = parseInt(studioSelectedChannel, 10);
	return (ch > 0) ? ch : 1;
}

function studioPaletteLabel() {
	var el = $('#studio_palette_channel');
	if (!el.length) { return; }
	var ch = studioPaletteChannel();
	var chain = studioChannelChain(ch);
	// the label names the chain too, because Add follows it
	el.text(studioLayoutText('Track') + ' ' + ch + ' · ' + studioLayoutText(chain === 'out' ? 'Out' : 'In'));
}

function studioPaletteAdd() {
	var name = $('#studio_palette_effect').val();
	if (!name) { return; }
	var ch = studioPaletteChannel();
	var chain = studioChannelChain(ch);
	if (studioRackFind(ch, name, chain)) {
		// Already in the chain: open the sheet on it rather than adding a second copy.
		studioPedalboardOpen(true);
		studioRackRender(ch);
		studioPaletteLabel();
		return;
	}
	studioSetInsert(ch, name, true, chain);
	studioSaver();
	studioPaletteLabel();
}

$(document).on('click', '#studio_palette_add', function () { studioPaletteAdd(); });

// The pedalboard follows the selected strip or track panel. The selection handler
// itself is in 03_editing.js; this runs after it in bundle order, so the sheet
// draws the chain of the track that was just chosen. A listening tuner moves its
// tap to the newly selected chain.
$(document).on('click', '.channel, .studio_track_panel', function () {
	studioRackRender(studioPaletteChannel());
	studioPaletteLabel();
	studioUpdatePedalLamps();
	if (typeof studioTunerFollow === 'function') { studioTunerFollow(); }
});

// ---- rack actions ----------------------------------------------------------

// The In/Out switch at the top of a rack: choose the chain the rack shows, so
// every action below (and the palette's Add) works on that chain.
$(document).on('click', '.studio_chain_choice', function () {
	var holder = $('#studio_pedalboard_rack');
	var ch = holder.attr('channel');
	if (!ch) { return; }
	studioSetChannelChain(ch, $(this).attr('chain'));
	studioRackRender(ch);
	studioPaletteLabel();
	studioUpdatePedalLamps();
	studioSaver();
});

$(document).on('click', '.studio_rack_bypass', function () {
	var row = $(this).closest('.studio_rack_tile');
	var ins = studioRackFind(row.attr('channel'), row.attr('insert'), row.attr('chain'));
	if (!ins) { return; }
	studioSetInsertBypass(row.attr('channel'), row.attr('insert'), !ins.bypassed);
});

// The lamp toggles the same state as the footswitch: a rack row's lamp is its
// bypass, and a shelf or palette tile's lamp is its insert on the selected
// track (adding it first when the track does not have it yet).
$(document).on('click', '.studio_rack_led, #pedalboard .studio_pedal_led, #pedalboard .studio_pedal_foot', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var target = $(this);
	var row = target.closest('.studio_rack_tile');
	if (row.length) {
		var ins = studioRackFind(row.attr('channel'), row.attr('insert'), row.attr('chain'));
		if (!ins) { return; }
		studioSetInsertBypass(row.attr('channel'), row.attr('insert'), !ins.bypassed);
		return;
	}
	var tile = target.closest('.pedal');
	if (!tile.length) { return; }
	var name = tile.attr('data-effect') || String(tile.attr('id') || '').replace(/^pedal_/, '');
	if (!name) { return; }
	studioTogglePedal(studioPaletteChannel(), name);
});

$(document).on('click', '.studio_rack_up', function () {
	var row = $(this).closest('.studio_rack_tile');
	studioRackMove(row.attr('channel'), row.attr('insert'), -1);
});

$(document).on('click', '.studio_rack_down', function () {
	var row = $(this).closest('.studio_rack_tile');
	studioRackMove(row.attr('channel'), row.attr('insert'), 1);
});

$(document).on('click', '.studio_rack_remove', function () {
	var row = $(this).closest('.studio_rack_tile');
	var ch = row.attr('channel'), name = row.attr('insert');
	if (row.attr('chain') === 'out') { studioSetInsert(ch, name, false, 'out'); }
	else { studioSetInsert(ch, name, false); }
	studioSaver();
});

$(document).on('input change', '.studio_insert_control', function () {
	var input = $(this);
	var row = input.closest('.studio_rack_tile');
	studioInsertControl(row.attr('channel'), row.attr('insert'), input.attr('control'), input.val());
});

// A text badge has no artwork to reveal on the shelf, so it opens the sheet on
// the selected track's chain.
// The shelf's reverb model dropdown is a macro over every reverb in the racks.
$(document).on('change', '.studio_pedal_model', function () {
	studioApplyPedals();
	studioRackRenderAll();
	studioSaver();
});
