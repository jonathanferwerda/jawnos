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
	chain = (chain === 'out') ? 'out' : ((chain === 'in') ? 'in' : studioChannelChain(ch));
	var map = (chain === 'out') ? c.outInsertByName : c.insertByName;
	return map[name] || null;
}

// Every action on the board resolves its insert from the tile it was pressed on:
// that tile's channel, chain and insert name. Never the selected channel, and
// never a chain that can flip while the click is in flight, so a tile can only
// ever act on the insert it draws.
function studioTileTarget(row) {
	var tile = $(row).closest('.studio_rack_tile');
	if (!tile.length) { return null; }
	var ch = tile.attr('channel');
	var name = tile.attr('insert');
	if (!ch || !name) { return null; }
	var chain = (tile.attr('chain') === 'out') ? 'out' : 'in';
	return { ch: ch, name: name, chain: chain, ins: studioRackFind(ch, name, chain) };
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
		if (control['typed']) {
			// A typed control is the tempo sync field: a visible text entry over a
			// datalist of the common divisions, so a division the list omits can
			// still be typed. The id is per insert; this tile is not cloned.
			var safe = String(ins.name).replace(/[^A-Za-z0-9_-]/g, '_') + '_' + String(control['control']).replace(/[^A-Za-z0-9_-]/g, '_');
			var listId = 'studio_tempo_fb_' + safe;
			input = $('<input type="text" class="studio_pedal_text pedal_text">').attr('list', listId);
			var datalist = $('<datalist></datalist>').attr('id', listId);
			$.each(control['options'] || [], function (index, option) {
				$('<option></option>').attr('value', option).appendTo(datalist);
			});
			datalist.appendTo(label);
		}
		else if (control['options']) {
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
	$('<button type="button" class="studio_pedal_foot hover" aria-pressed="false"></button>')
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
	// A cloned typed control lost its datalist id with the clone's other ids.
	// Give each tile its own, named after the insert, so two synced pedals on one
	// board cannot point at the same list.
	var listSeq = 0;
	tile.find('.studio_pedal_text').each(function () {
		var input = $(this);
		var list = input.closest('label').find('datalist').first();
		if (!list.length) { return; }
		var safe = String(ins.name).replace(/[^A-Za-z0-9_-]/g, '_');
		var id = 'studio_tempo_tile_' + ch + '_' + safe + '_' + (listSeq++);
		list.attr('id', id);
		input.attr('list', id);
	});
	tile.addClass('studio_rack_tile')
		.attr('channel', ch).attr('insert', ins.name).attr('chain', chain || 'in')
		.attr('data-effect', ins.name);
	// The controls belong to this insert, not to the library's macro name.
	tile.find('[channel]').attr('channel', ins.name);
	tile.find('[effect]').attr('effect', ins.name);
	// The insert's own values are the ones the knobs and dropdowns show. A fresh
	// insert takes the tile's defaults, exactly as the old shelf did on entry.
	tile.find('.knob_control, .studio_pedal_model, .studio_pedal_text').each(function () {
		var control = $(this).attr('control');
		var value = (ins.values && ins.values[control] !== undefined) ? ins.values[control] : $(this).val();
		$(this).val(value);
		if ((!ins.values || ins.values[control] === undefined) && value !== undefined) {
			ins.set(control, value);
		}
		// The picture and the value above it follow the input: a tile built from a
		// saved song must show where its knobs were left, not sit at zero.
		if ($(this).hasClass('knob_control') && typeof studioKnobPaint === 'function') {
			studioKnobPaint($(this), tile);
		}
	});
	var on = !ins.bypassed;
	if (!on) { tile.addClass('studio_rack_off'); }
	// The tile is born in step with its insert: the foot says On or Off and the
	// lamp reads the same state before any later paint runs. Opening the board
	// draws tiles without a lamp pass, so a bypassed insert must not show "On".
	tile.find('.studio_pedal_foot')
		.attr('aria-pressed', on ? 'true' : 'false')
		.text(studioLayoutText(on ? 'On' : 'Off'));
	if (tile.attr('data-tuner') === 'yes') {
		// Jtune's lamp is the tuner's light, not an effect lamp: paint it from the
		// tuner, so opening the board never shows a stale colour.
		if (typeof studioTunerPaintLamp === 'function') { studioTunerPaintLamp(tile); }
	}
	else {
		var lampLabel = studioPedalLampLabel(on);
		tile.find('.studio_pedal_led').attr({
			'aria-pressed': on ? 'true' : 'false',
			title: lampLabel,
			hint: lampLabel
		});
	}
	// A synced time control is resolved against the song's BPM as the tile is
	// drawn, so a restored song and a new insert sound the same before a knob
	// moves. An Out insert is browser playback only and is not posted.
	if (typeof studioTempoSyncApply === 'function') { studioTempoSyncApply(ins, ch, chain !== 'out'); }
	// Small tools on the frame: touch order and removal without leaving the board.
	var tools = $('#studio_board_tool_template').first().clone();
	tools.removeAttr('id').removeAttr('style').removeAttr('aria-hidden');
	// The template already marks them type=button; set it again so a clone can
	// never become a form submit in some other embedding.
	tools.find('button').attr('type', 'button');
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
			// No `axis`: jQuery UI writes only the axis it is not locked out of, so a
			// horizontal-only sort never sets the clone's `top` and the picture rides
			// the top of the page instead of the cursor. The row is one line, so the
			// pointer's vertical travel changes nothing about where the drop lands.
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
	// A song restore sets each insert's `sync` string before this draw; resolve
	// every synced insert now, not on the next knob move.
	if (typeof studioTempoSyncAll === 'function') { studioTempoSyncAll(); }
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
	studioListenRearm(from, chain);
	studioListenRearm(to, chain);
	if (out && typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); }
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
	studioListenRearm(ch, chain);
	if (out && typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); }
}

function studioRackMove(ch, name, delta, chain) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	chain = (chain === 'out') ? 'out' : ((chain === 'in') ? 'in' : studioChannelChain(ch));
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
	if (out && typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); }
}

// The footswitch: bypass in place, never remove (contract rule 5). The chain is
// the tile's own, so a pedal that also exists in the other chain is never
// switched by a click aimed at this one.
function studioSetInsertBypass(ch, name, on, chain) {
	chain = (chain === 'out') ? 'out' : ((chain === 'in') ? 'in' : studioChannelChain(ch));
	var ins = studioRackFind(ch, name, chain);
	if (!ins) { return false; }
	if (ins.setBypass) { ins.setBypass(on); }
	else { ins.bypassed = !!on; }
	studioUpdateFxBadges();
	studioRackRender(ch);
	studioUpdatePedalLamps();
	studioSaver();
	studioListenRearm(ch, chain);
	if (chain === 'out' && typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); }
	return true;
}

// ---- the lamps -------------------------------------------------------------
//
// Every rack row wears the same lamp: green when the effect is on for the
// selected track, dark red when it is bypassed. The insert is the state; the
// lamp only reads it, so the rack's own footswitch and the lamp can never
// disagree.
function studioPedalInsert(ch, name, chain) {
	// Look in the chain asked for - the tile's, or the one the board shows. A
	// miss may still be the same kind under another name (reverb vs reverb2), but
	// only within that same chain: the other chain is a different insert.
	chain = (chain === 'out') ? 'out' : ((chain === 'in') ? 'in' : studioChannelChain(ch));
	var direct = studioRackFind(ch, name, chain);
	if (direct) { return direct; }
	var c = studioAudio.channels[ch];
	if (!c) { return null; }
	var kind = studioEffectKind(name);
	var found = null;
	var list = (chain === 'out') ? c.outInserts : c.inserts;
	list.forEach(function (ins) {
		if (!found && studioEffectKind(ins.name) === kind) { found = ins; }
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
		// The tile's own channel, so a lamp always reads its insert even if the
		// selection moved while the board was still on screen.
		var ins = studioRackFind(tile.attr('channel') || studioPaletteChannel(), tile.attr('insert'), tile.attr('chain'));
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
function studioTogglePedal(ch, name, chain) {
	chain = (chain === 'out') ? 'out' : ((chain === 'in') ? 'in' : studioChannelChain(ch));
	var ins = studioPedalInsert(ch, name, chain);
	// An absent effect joins the chain the board is showing, not always In.
	if (!ins) { studioSetInsert(ch, name, true, chain); }
	else { studioSetInsertBypass(ch, ins.name, !ins.bypassed, chain); }
	studioUpdatePedalLamps();
	studioSaver();
}

function studioInsertControl(ch, name, control, value, chain) {
	chain = (chain === 'out') ? 'out' : ((chain === 'in') ? 'in' : studioChannelChain(ch));
	var ins = studioRackFind(ch, name, chain);
	if (!ins) { return; }
	ins.set(control, value);
	// A synced time or rate is resolved from the BPM before the engine hears it,
	// and the sync string itself never travels. A manual move of the same control
	// goes through the same resolver, which falls back to the knob when sync is
	// off. An output insert is browser-only, so it never reaches the engine.
	var kind = studioEffectKind(name);
	if (control === 'sync' || studioTempoControls[kind] === control) {
		if (typeof studioTempoSyncApply === 'function') { studioTempoSyncApply(ins, ch, chain !== 'out'); }
	}
	else if (chain !== 'out') { studioEngineInsertParam(ch, name, control, value); }
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
	var t = studioTileTarget(this);
	if (!t || !t.ins) { return; }
	studioSetInsertBypass(t.ch, t.name, !t.ins.bypassed, t.chain);
});

// The lamp toggles the same state as the footswitch: a rack row's lamp is its
// bypass, and a shelf or palette tile's lamp is its insert on the selected
// track (adding it first when the track does not have it yet).
$(document).on('click', '.studio_rack_led, #pedalboard .studio_pedal_led, #pedalboard .studio_pedal_foot', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var target = $(this);
	if (target.closest('.studio_rack_tile').length) {
		var t = studioTileTarget(target);
		if (!t || !t.ins) { return; }
		studioSetInsertBypass(t.ch, t.name, !t.ins.bypassed, t.chain);
		return;
	}
	var tile = target.closest('.pedal');
	if (!tile.length) { return; }
	var name = tile.attr('data-effect') || String(tile.attr('id') || '').replace(/^pedal_/, '');
	if (!name) { return; }
	studioTogglePedal(tile.attr('channel') || studioPaletteChannel(), name, tile.attr('chain'));
});

$(document).on('click', '.studio_rack_up', function () {
	var t = studioTileTarget(this);
	if (t) { studioRackMove(t.ch, t.name, -1, t.chain); }
});

$(document).on('click', '.studio_rack_down', function () {
	var t = studioTileTarget(this);
	if (t) { studioRackMove(t.ch, t.name, 1, t.chain); }
});

$(document).on('click', '.studio_rack_remove', function () {
	var t = studioTileTarget(this);
	if (!t || !t.ins) { return; }
	studioSetInsert(t.ch, t.name, false, t.chain);
	studioSaver();
});

$(document).on('input change', '.studio_insert_control', function () {
	var input = $(this);
	var row = input.closest('.studio_rack_tile');
	studioInsertControl(row.attr('channel'), row.attr('insert'), input.attr('control'), input.val(), row.attr('chain'));
});

// A text badge has no artwork to reveal on the shelf, so it opens the sheet on
// the selected track's chain.
// The shelf's reverb model dropdown is a macro over every reverb in the racks.
$(document).on('change', '.studio_pedal_model', function () {
	studioApplyPedals();
	studioRackRenderAll();
	studioSaver();
});
