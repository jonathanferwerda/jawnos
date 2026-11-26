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

// A finger has to hold a tile before a reorder starts, so a quick swipe can
// travel along the board instead of picking up a pedal. A mouse is unaffected:
// a trusted press puts the drag back to instant. Touch Punch turns the touch
// into a mouse drag and cancels the browser's own scroll, so the swipe below
// moves the board by hand until a press becomes a reorder.
function studioBoardPressMode(touch) {
	var rack = $('#studio_pedalboard_rack');
	if (!rack.length || typeof rack.sortable !== 'function' || !rack.hasClass('ui-sortable')) { return; }
	rack.sortable('option', { delay: touch ? 250 : 0, distance: touch ? 8 : 0 });
}

document.addEventListener('touchstart', function (event) {
	if (event.target && event.target.closest && event.target.closest('#studio_pedalboard_rack')) {
		studioBoardPressMode(true);
	}
}, { capture: true, passive: true });

document.addEventListener('mousedown', function (event) {
	// Touch Punch's own mousedown is untrusted; only a real mouse resets it.
	if (event.isTrusted === false) { return; }
	if (event.target && event.target.closest && event.target.closest('#studio_pedalboard_rack')) {
		studioBoardPressMode(false);
	}
}, { capture: true });

var studioBoardSwipe = null;

document.addEventListener('touchstart', function (event) {
	studioBoardSwipe = null;
	if (!event.target || !event.target.closest || event.touches.length !== 1) { return; }
	var rack = event.target.closest('#studio_pedalboard_rack');
	if (!rack) { return; }
	// A touch on a knob, a list or the footswitch belongs to that control. The
	// browser may adjust a touch's target to a nearby control, so the test uses
	// the point itself: the artwork under the finger is the board's.
	var under = document.elementFromPoint
		? document.elementFromPoint(event.touches[0].clientX, event.touches[0].clientY)
		: event.target;
	if (under && under.closest && under.closest('.knob, .knob_control, .pedal_knob, .pedal_select_row, .studio_pedal_foot, .studio_pedal_led, .studio_board_tools, select, option, input, button')) { return; }
	studioBoardSwipe = {
		rack: rack,
		x: event.touches[0].clientX,
		y: event.touches[0].clientY,
		left: rack.scrollLeft,
		moved: false
	};
}, { capture: true, passive: true });

document.addEventListener('touchmove', function (event) {
	var swipe = studioBoardSwipe;
	if (!swipe || !event.touches.length) { return; }
	// A held press has become a reorder: the tile follows the finger, not the board.
	var sortable = $(swipe.rack).data('ui-sortable');
	if (sortable && sortable._mouseStarted) { studioBoardSwipe = null; return; }
	var dx = event.touches[0].clientX - swipe.x;
	var dy = event.touches[0].clientY - swipe.y;
	if (!swipe.moved) {
		if (Math.abs(dx) < 6) { return; }
		if (Math.abs(dy) > Math.abs(dx)) { return; }
		swipe.moved = true;
		// Cancel the pending press, so a long swipe cannot turn into a drag when
		// the hold's timer would otherwise fire.
		$(document).trigger($.Event('mouseup'));
	}
	swipe.rack.scrollLeft = swipe.left - dx;
	event.preventDefault();
}, { passive: false });

document.addEventListener('touchend', function () { studioBoardSwipe = null; }, { passive: true });
document.addEventListener('touchcancel', function () { studioBoardSwipe = null; }, { passive: true });

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
		// A Sync field shows `off` as its placeholder, not as its value: a field
		// whose value is `off` filters its datalist down to the one matching row.
		// Left empty, the field shows every division as soon as it is pressed.
		if (String(control) === 'sync'
			&& (value === undefined || value === null || String(value) === ''
				|| String(value).toLowerCase() === 'off')) {
			value = '';
			$(this).attr('placeholder', 'off');
		}
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
	// The graph carries only enabled inserts, so the new bypass state is wired in
	// or out of the chain here. Bypassing the only pedal leaves a plain wire, which
	// is what the engine does with the same insert.
	if (chain === 'out') { studioRebuildOutputs(ch); }
	else { studioRebuildInserts(ch); }
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

// ---- the pedal menu --------------------------------------------------------
//
// The small X is easy to miss on a crowded board, and a touch pad has no hover.
// A right-click on a tile offers the same two moves in one readable menu: the
// footswitch's On/Off and Remove. It acts on the tile's own chain, like every
// other board action, and never on the chain the board happens to show.
var studioPedalMenuTarget = null;

function studioPedalMenuRow(menu, command, label) {
	$('<button type="button" class="studio_menu_row"></button>')
		.attr('data-command', command)
		.text(label)
		.appendTo(menu);
}

function studioPedalMenu(t, px, py) {
	$('.studio_menu').remove();
	studioPedalMenuTarget = { ch: t.ch, name: t.name, chain: t.chain };
	var spec = (typeof studioEffectSpec === 'function') ? studioEffectSpec(t.name) : null;
	var title = (spec && spec['label']) ? spec['label'] : t.name;
	var menu = $('<div class="studio_menu studio_pedal_menu"></div>');
	$('<div class="studio_menu_head"></div>').text(studioLayoutText(title)).appendTo(menu);
	studioPedalMenuRow(menu, 'bypass', studioLayoutText(t.ins.bypassed ? 'Turn on' : 'Turn off'));
	studioPedalMenuRow(menu, 'remove', studioLayoutText('Remove'));
	$('body').append(menu);
	var margin = 6;
	var left = Math.min(px, $(window).width() - menu.outerWidth() - margin);
	var top = Math.min(py, $(window).height() - menu.outerHeight() - margin);
	menu.css({ left: Math.max(margin, left), top: Math.max(margin, top) });
}

// A controller's board is read-only (the remote vocabulary has no pedal move),
// so it leaves the browser's own menu alone rather than offering a dead Remove.
$(document).on('contextmenu', '#studio_pedalboard_rack .studio_rack_tile', function (e) {
	if (typeof studioRemoteTarget !== 'undefined' && studioRemoteTarget) { return; }
	e.preventDefault();
	var t = studioTileTarget(this);
	if (!t || !t.ins) { return; }
	studioPedalMenu(t, e.clientX, e.clientY);
});

$(document).on('click', '.studio_pedal_menu .studio_menu_row', function (e) {
	e.preventDefault();
	var row = $(this);
	var t = studioPedalMenuTarget;
	var command = row.attr('data-command');
	$('.studio_menu').remove();
	studioPedalMenuTarget = null;
	if (!t) { return; }
	var ins = studioRackFind(t.ch, t.name, t.chain);
	if (!ins) { return; }
	if (command === 'remove') {
		studioSetInsert(t.ch, t.name, false, t.chain);
		studioSaver();
	}
	else if (command === 'bypass') {
		studioSetInsertBypass(t.ch, t.name, !ins.bypassed, t.chain);
	}
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

// ---- saved pedalboards -----------------------------------------------------
//
// A saved board is a named copy of the chain the sheet is showing: the inserts
// in order, each with the state of its stomp and its knob values. The page
// publishes the list as an app setting, so a board saved on one track can be
// recalled on another track or in another song. The list is kept newest-used
// first, both when it is read and after every save or load, so the dropdown's
// indices are stable and its order means what it says.

function studioBoardLibrary() {
	var library = window.jawnos_studio_pedalboards;
	if (!library || typeof library.length !== 'number') {
		library = [];
		window.jawnos_studio_pedalboards = library;
	}
	return library;
}

// Keep the array most-recently-used first. The sort is part of the data, not a
// view, so a save and a load write the same order the dropdown draws.
function studioBoardSort(library) {
	library.sort(function (a, b) {
		return (Number(b && b.used) || 0) - (Number(a && a.used) || 0);
	});
	return library;
}

function studioBoardPersist() {
	studioSaveSettings([{ setting: 'pedalboards', value: JSON.stringify(studioBoardLibrary()) }]);
}

// A controller mirrors another machine and has no pedal command in its
// vocabulary, so its board is a read-only view. The badge marks the sheet
// `studio_board_readonly`; that, or an active remote target, refuses a write.
function studioBoardReadOnly() {
	if ($('#pedalboard').hasClass('studio_board_readonly')) { return true; }
	return (typeof studioRemoteTarget !== 'undefined' && studioRemoteTarget) ? true : false;
}

// The inserts of one chain, in signal order, as the plain records a preset
// keeps. The values are copied so a later knob move cannot rewrite a board that
// was already saved.
function studioBoardCapture(ch, chain) {
	var c = studioAudio.channels[ch];
	if (!c) { return []; }
	var list = (chain === 'out') ? c.outInserts : c.inserts;
	var out = [];
	list.forEach(function (ins) {
		var values = $.extend({}, ins.values || {});
		out.push({ name: ins.name, bypass: !!ins.bypassed, values: values });
	});
	return out;
}

// Rebuild the dropdown from the library: the blank prompt first, then the saved
// boards in recent-use order. A selection that still exists is kept.
function studioBoardPresetsRefresh() {
	var select = $('#studio_board_presets');
	if (!select.length) { return; }
	var chosen = select.val();
	var library = studioBoardLibrary();
	select.empty();
	select.append($('<option></option>').attr('value', '').text(studioLayoutText('Saved pedalboards')));
	library.forEach(function (item, index) {
		if (!item || !item.name) { return; }
		select.append($('<option></option>').attr('value', String(index)).text(item.name));
	});
	if (chosen !== null && chosen !== undefined && select.find('option[value="' + chosen + '"]').length) {
		select.val(chosen);
	}
}

// Save the chain the sheet shows under the typed name. The same name replaces
// the old board rather than making a second one, and the save becomes the most
// recently used entry.
function studioBoardSave() {
	if (studioBoardReadOnly()) { return false; }
	var name = String($('#studio_board_save_name').val() || '').trim();
	if (!name) { return false; }
	var ch = studioPaletteChannel();
	var chain = studioChannelChain(ch);
	var library = studioBoardLibrary();
	var preset = null;
	library.forEach(function (item) {
		if (!preset && item && String(item.name) === name) { preset = item; }
	});
	if (!preset) {
		preset = { name: name, chain: [], used: 0 };
		library.push(preset);
	}
	preset.chain = studioBoardCapture(ch, chain);
	preset.used = Date.now();
	studioBoardSort(library);
	studioBoardPersist();
	studioBoardPresetsRefresh();
	$('#studio_board_presets').val(String(library.indexOf(preset)));
	$('#studio_board_save_name').val('');
	return true;
}

// Replace the shown chain with a saved board: empty it, add the saved inserts
// back in order, then put each knob value and stomp state where it was saved.
// A read-only board refuses, so a pedal change never travels to a peer.
function studioBoardLoad(index) {
	if (studioBoardReadOnly()) { return false; }
	var library = studioBoardLibrary();
	var preset = library[index];
	if (!preset || !preset.chain) { return false; }
	var ch = studioPaletteChannel();
	var chain = studioChannelChain(ch);
	var c = studioAudio.channels[ch];
	if (!c) { return false; }
	var out = (chain === 'out');
	var list = out ? c.outInserts : c.inserts;
	list.slice().forEach(function (ins) {
		studioSetInsert(ch, ins.name, false, chain);
	});
	preset.chain.forEach(function (item) {
		if (!item || !item.name) { return; }
		studioSetInsert(ch, item.name, true, chain);
	});
	var byName = out ? c.outInsertByName : c.insertByName;
	preset.chain.forEach(function (item) {
		if (!item || !item.name) { return; }
		var ins = byName[item.name];
		if (!ins) { return; }
		var values = item.values || {};
		Object.keys(values).forEach(function (control) { ins.set(control, values[control]); });
		if (ins.setBypass) { ins.setBypass(!!item.bypass); }
		else { ins.bypassed = !!item.bypass; }
	});
	// The bypass state decides which inserts are wired in, so rebuild once after
	// every saved state is back. The rack is drawn last, after the values are in
	// place: drawing before the restore would leave the tiles on the builder's
	// defaults, and applying those back (studioApplyPedals) would overwrite the
	// board that was just loaded.
	if (out) { studioRebuildOutputs(ch); } else { studioRebuildInserts(ch); }
	studioRackRender(ch);
	studioUpdatePedalLamps();
	studioSaver();
	studioListenRearm(ch, chain);
	if (out && typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); }
	preset.used = Date.now();
	studioBoardSort(library);
	studioBoardPersist();
	studioBoardPresetsRefresh();
	$('#studio_board_presets').val(String(library.indexOf(preset)));
	return true;
}

$(document).on('click', '#studio_board_save', function (e) {
	e.preventDefault();
	studioBoardSave();
});

$(document).on('change', '#studio_board_presets', function () {
	var index = parseInt($(this).val(), 10);
	if (!(index >= 0)) { return; }
	studioBoardLoad(index);
});

// The board's bar is drawn when the sheet opens, and the list is kept apart from
// the tiles, so refresh it after any press that may have opened the board.
$(document).on('click', '.studio_track_fx', function () {
	setTimeout(studioBoardPresetsRefresh, 0);
});

$(function () { studioBoardPresetsRefresh(); });
