// ===========================================================================
// The per-track rack
// ===========================================================================
// Every channel owns an ordered list of inserts in studioAudio.channels[ch],
// and this part is the UI over that list: the palette adds one, the rack shows
// the chain in order, drag or the arrows reorder it, the footswitch bypasses an
// insert in place, and X removes it. The song keeps the order and the on/off
// state in the channel's `fx` records (see studioSaver / studioRetriever).

function studioRackFind(ch, name) {
	var c = studioAudio.channels[ch];
	if (!c) { return null; }
	return c.insertByName[name] || null;
}

// The row template's labels are static markup so the help topic can name them;
// only the effect's own name and controls are built here.
function studioRackRow(ch, ins) {
	var row = $('#studio_rack_template .studio_rack_row').first().clone();
	var spec = studioEffectSpec(ins.name);
	row.attr('channel', ch).attr('insert', ins.name);
	row.find('.studio_rack_name').text(studioLayoutText(spec && spec['label'] ? spec['label'] : ins.name));
	if (ins.bypassed) {
		row.addClass('studio_rack_off');
		row.find('.studio_rack_bypass').text(studioLayoutText('Off')).attr('aria-pressed', 'true');
	}
	else {
		row.find('.studio_rack_bypass').text(studioLayoutText('On')).attr('aria-pressed', 'false');
	}

	var controls = row.find('.studio_rack_controls');
	if (spec && spec['controls']) {
		spec['controls'].forEach(function (control) {
			var wrap = $('<span class="studio_rack_control"></span>');
			var label = $('<label></label>').text(studioLayoutText(control['label'] || control['control']));
			var value = ins.values[control['control']];
			if (value === undefined) { value = 50; }
			var input;
			if (control['options']) {
				input = $('<select class="studio_insert_control studio_insert_select"></select>');
				control['options'].forEach(function (option, index) {
					$('<option></option>').attr('value', index).text(studioLayoutText(option)).appendTo(input);
				});
				// the dropdowns hold a whole number (a model, a cabinet, a key)
				input.val(String(Math.round(studioEffectClamp(value, 0, control['options'].length - 1))));
			}
			else {
				input = $('<input type="range" min="0" max="100" class="studio_insert_control">');
				input.val(value);
			}
			input.attr('control', control['control']);
			label.append(input);
			wrap.append(label);
			controls.append(wrap);
		});
	}
	return row;
}

function studioRackRender(ch) {
	var holder = $('.studio_channel_rack[channel="' + ch + '"]');
	var c = studioAudio.channels[ch];
	if (!holder.length || !c) { return; }
	holder.empty();
	c.inserts.forEach(function (ins) { holder.append(studioRackRow(ch, ins)); });
	if (holder.children().length && typeof holder.sortable === 'function' && !holder.hasClass('ui-sortable')) {
		// jQuery UI sortable is the house drag helper (the taskbar uses it too).
		// Its default cancel list keeps the sliders and buttons usable.
		holder.sortable({
			items: '> .studio_rack_row',
			axis: 'y',
			tolerance: 'pointer',
			update: function () { studioRackReorder(ch); }
		});
	}
}

function studioRackRenderAll() {
	$.each(studioAudio.channels, function (ch) { studioRackRender(ch); });
	studioPaletteLabel();
}

function studioRackReorder(ch) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	var order = [];
	$('.studio_channel_rack[channel="' + ch + '"] .studio_rack_row').each(function () {
		order.push($(this).attr('insert'));
	});
	var next = [];
	order.forEach(function (name) {
		var ins = c.insertByName[name];
		if (ins && next.indexOf(ins) === -1) { next.push(ins); }
	});
	// An insert the DOM does not know about (a race while rendering) keeps its
	// place at the end rather than falling out of the chain.
	c.inserts.forEach(function (ins) { if (next.indexOf(ins) === -1) { next.push(ins); } });
	c.inserts = next;
	studioRebuildInserts(ch);
	studioSaver();
}

function studioRackMove(ch, name, delta) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	var ins = c.insertByName[name];
	var at = c.inserts.indexOf(ins);
	if (at < 0) { return; }
	var to = at + delta;
	if (to < 0 || to >= c.inserts.length) { return; }
	c.inserts.splice(at, 1);
	c.inserts.splice(to, 0, ins);
	studioRebuildInserts(ch);
	studioRackRender(ch);
	studioSaver();
}

// The footswitch: bypass in place, never remove (contract rule 5).
function studioSetInsertBypass(ch, name, on) {
	var ins = studioRackFind(ch, name);
	if (!ins) { return; }
	if (ins.setBypass) { ins.setBypass(on); }
	else { ins.bypassed = !!on; }
	studioUpdateFxBadges();
	studioRackRender(ch);
	studioSaver();
}

function studioInsertControl(ch, name, control, value) {
	var ins = studioRackFind(ch, name);
	if (!ins) { return; }
	ins.set(control, value);
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
	el.text(studioLayoutText('Track') + ' ' + studioPaletteChannel());
}

function studioPaletteAdd() {
	var name = $('#studio_palette_effect').val();
	if (!name) { return; }
	var ch = studioPaletteChannel();
	if (studioRackFind(ch, name)) {
		// Already in the chain: open the rack rather than adding a second copy.
		$('#studio_track_row_' + ch).addClass('studio_fx_open');
		studioRackRender(ch);
		return;
	}
	studioSetInsert(ch, name, true);
	studioSaver();
}

$(document).on('click', '#studio_palette_add', function () { studioPaletteAdd(); });

// The palette follows the selected strip or track panel. The selection handler
// itself is in 03_editing.js; this runs after it in bundle order.
$(document).on('click', '.channel, .studio_track_panel', function () { studioPaletteLabel(); });

// ---- rack actions ----------------------------------------------------------

$(document).on('click', '.studio_rack_bypass', function () {
	var row = $(this).closest('.studio_rack_row');
	var ins = studioRackFind(row.attr('channel'), row.attr('insert'));
	if (!ins) { return; }
	studioSetInsertBypass(row.attr('channel'), row.attr('insert'), !ins.bypassed);
});

$(document).on('click', '.studio_rack_up', function () {
	var row = $(this).closest('.studio_rack_row');
	studioRackMove(row.attr('channel'), row.attr('insert'), -1);
});

$(document).on('click', '.studio_rack_down', function () {
	var row = $(this).closest('.studio_rack_row');
	studioRackMove(row.attr('channel'), row.attr('insert'), 1);
});

$(document).on('click', '.studio_rack_remove', function () {
	var row = $(this).closest('.studio_rack_row');
	var ch = row.attr('channel'), name = row.attr('insert');
	studioSetInsert(ch, name, false);
	studioSaver();
});

$(document).on('input change', '.studio_insert_control', function () {
	var input = $(this);
	var row = input.closest('.studio_rack_row');
	studioInsertControl(row.attr('channel'), row.attr('insert'), input.attr('control'), input.val());
});

// A text badge has no artwork to reveal on the shelf, so it opens the rack.
$(document).on('click', '.channel_fx_text', function () {
	var ch = $(this).closest('.channel_fx').attr('channel');
	if (!ch) { return; }
	studioSelectedChannel = ch;
	$('#studio_track_row_' + ch).addClass('studio_fx_open');
	studioRackRender(ch);
	studioPaletteLabel();
});

// The shelf's reverb model dropdown is a macro over every reverb in the racks.
$(document).on('change', '.studio_pedal_model', function () {
	studioApplyPedals();
	studioRackRenderAll();
	studioSaver();
});
