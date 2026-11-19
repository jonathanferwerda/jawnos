// Studio layout: the compact per-track panel, the four hide toggles, floating
// panels and the dynamic track list. The channel state itself still lives in
// mixer[] and studioAudio.channels[]; these helpers only move the existing
// controls around and call the same apply functions.

var STUDIO_MAX_TRACKS = 32;
var studioPanelDrag = null;
var studioPanelResize = null;
var studioLayoutQuiet = false;

function studioLayoutText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// ---- panels ----------------------------------------------------------------

var studioPanelSelectors = {
	synth: '#studio_synth',
	drums: '#studio_drums',
	mixer: '#studio_mixer',
	transport: '#studio_transport_panel',
	tracks: '#studio_tracks_panel'
};

var studioHideSettings = {
	synth: 'hide_synth',
	drums: 'hide_drums',
	mixer: 'hide_channel_strips',
	transport: 'hide_transport',
	tracks: 'hide_tracks'
};

function studioPanelElement(name) {
	var selector = studioPanelSelectors[name];
	return selector ? $(selector) : $();
}

// ---- hide / show -----------------------------------------------------------

function studioUpdateHideButton(name, hidden) {
	$('.studio_hide_toggle[data-panel="' + name + '"]').each(function () {
		var button = $(this);
		button.attr('aria-pressed', hidden ? 'true' : 'false');
		var label = hidden ? button.attr('data-show-label') : button.attr('data-hide-label');
		if (label) { button.text(studioLayoutText(label)); }
	});
}

function studioSetPanelHidden(name, hidden, persist) {
	hidden = !!hidden;
	if (name == 'synth') {
		$('.studio_synth_body').toggle(!hidden);
		$('#studio_synth_hide').toggle(!hidden);
		$('#studio_synth_show').toggle(hidden);
	}
	else if (studioPanelSelectors[name]) {
		studioPanelElement(name).toggle(!hidden);
	}
	studioUpdateHideButton(name, hidden);
	// a hidden panel leaves its row, so the rows below take the space
	studioManualReflow();
	// a hidden or floated drums panel hands its arranged column back to the
	// timeline and the synth (see .studio_drums_open in style.html.ep)
	if (typeof studioDrumsGridState === 'function') { studioDrumsGridState(); }
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	mixer.settings[studioHideSettings[name]] = hidden ? 'yes' : 'no';
	if (persist) {
		studioSaveSettings([{ setting: studioHideSettings[name], value: hidden ? 'yes' : 'no' }]);
	}
}

function studioApplyHideSettings() {
	$.each(studioHideSettings, function (name, setting) {
		var raw = (mixer && mixer.settings) ? mixer.settings[setting] : undefined;
		studioSetPanelHidden(name, String(raw) == 'yes', false);
	});
}

// ---- packing panels --------------------------------------------------------
//
// The four docked panels share one grid and no panel owns a cell. Its place is
// its persisted order (the grid's auto-placement order) and its width is the
// number of columns it spans. Dropping a docked panel onto another inserts it
// before that panel, and the ones after it reflow into the gaps. A floated panel
// leaves the grid but keeps its order and span, so Dock puts it back in place.

// The drum machine is a fifth panel. It has no entry in the Arrange preset
// below for the same reason the synth has none: arranged mode places panels by
// the stylesheet's named areas, and the drums column exists only while the
// panel is docked and visible. In manual packing it falls last until moved.
var studioPanelNames = ['synth', 'drums', 'tracks', 'mixer', 'transport'];
var studioPanelOrder = studioPanelNames.slice();
var studioPanelSpan = { synth: 1, drums: 1, tracks: 1, mixer: 1, transport: 1 };
var STUDIO_PANEL_MIN_SPAN = 1;
var STUDIO_PANEL_MAX_SPAN = 2;
var STUDIO_PANEL_MIN_WIDTH = 180;

// ---- the Arrange preset ----------------------------------------------------
//
// A DAW reads top to bottom: the transport keeps its own height across the
// top, the timeline takes the flexible middle with the synth beside it, and
// the console gets a compact band at the foot with the master strip at its far
// right. A narrow window stacks the same areas in one column. The arrangement
// is a mode on the grid (the stylesheet's named areas, see style.html.ep); the
// order/span values below are the manual packing it falls back to the moment
// the person moves a panel.
var studioArrangeWide = {
	order: ['transport', 'tracks', 'synth', 'mixer'],
	span: { transport: 2, tracks: 2, synth: 1, mixer: 1 }
};
var studioArrangeCompact = {
	order: ['transport', 'tracks', 'mixer', 'synth'],
	span: { transport: 2, tracks: 2, mixer: 2, synth: 2 }
};

function studioIsNarrow() {
	var width = $('#studio').width() || $(window).width() || 0;
	return !!(width && width < 720);
}

function studioArrangePreset() {
	return studioIsNarrow() ? studioArrangeCompact : studioArrangeWide;
}

// Arrange is a mode on the grid itself: the stylesheet's named areas replace
// the manual order/span placement. The manual values stay on the panels (and
// in the saved settings) for the moment the mode ends, so leaving it never
// loses the packing the person had.
function studioSetArranged(on, persist) {
	var grid = $('#studio_grid');
	if (!grid.length) { return; }
	grid.toggleClass('studio_arranged', !!on);
	grid.toggleClass('studio_arranged_compact', !!on && studioIsNarrow());
	// Arrange places panels by the stylesheet's areas, so they must be direct
	// children; leaving it rebuilds the manual rows.
	if (on) { studioManualUnwrap(); }
	else { studioManualReflow(); }
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	mixer.settings['studio_panel_arranged'] = on ? 'yes' : 'no';
	if (persist !== false) {
		studioSaveSettings([{ setting: 'studio_panel_arranged', value: on ? 'yes' : 'no' }]);
	}
}

// A manual gesture takes the window out of the arranged grid and back to the
// packing rules it was using before. Idempotent, so every entry point can call
// it: a drag, float, Dock, Narrow/Wide or a dropped panel order.
function studioExitArrange(persist) {
	if (!$('#studio_grid').hasClass('studio_arranged')) { return; }
	studioSetArranged(false, persist !== false);
}

function studioApplyArrange(persist) {
	var preset = studioArrangePreset();
	studioPanelOrder = preset.order.slice();
	// the preset's literal order predates the drum panel; when the window
	// falls back to manual packing the drums sit beside the synth, where
	// Arrange shows them
	if (studioPanelOrder.indexOf('drums') < 0) {
		var at = studioPanelOrder.indexOf('synth');
		studioPanelOrder.splice(at < 0 ? studioPanelOrder.length : at + 1, 0, 'drums');
	}
	$.each(studioPanelNames, function (i, name) {
		studioPanelSpan[name] = preset.span[name] || STUDIO_PANEL_MIN_SPAN;
		// Arrange is a clean preset: a height a person dragged is forgotten here.
		if (persist) { studioPersistPanelHeight(name, 0); }
		if (mixer && mixer.settings) { delete mixer.settings['studio_panel_height_' + name]; }
		studioPanelElement(name).css('height', '');
		// the preset also forgets a width the person dragged
		if (persist) { studioPersistPanelWidth(name, 0); }
		if (mixer && mixer.settings) { delete mixer.settings['studio_panel_width_' + name]; }
		studioPanelElement(name).css({ width: '', flex: '' });
		// Arrange brings a floated panel home before it applies the preset.
		if (studioPanelElement(name).hasClass('studio_panel_floating')) {
			studioDockPanel(name, false);
		}
	});
	studioApplyPanelOrder();
	$.each(studioPanelNames, function (i, name) { studioApplyPanelSpan(name); });
	studioSetArranged(true, persist);
	if (persist) { studioPersistPanelOrder(); }
}

$(document).on('click', '#studio_arrange', function () { studioApplyArrange(true); });

// The compact areas follow the Studio window, not the desk: the app is a
// floating window, so the desk's viewport width says nothing about it.
$(window).on('resize', function () {
	if ($('#studio_grid').hasClass('studio_arranged')) {
		$('#studio_grid').toggleClass('studio_arranged_compact', studioIsNarrow());
	}
});

function studioPanelOrderIndex(name) {
	for (var i = 0; i < studioPanelOrder.length; i++) {
		if (studioPanelOrder[i] == name) { return i; }
	}
	return studioPanelOrder.length;
}

function studioPanelSpanValue(name) {
	var span = parseInt(studioPanelSpan[name], 10);
	return (span == STUDIO_PANEL_MAX_SPAN) ? STUDIO_PANEL_MAX_SPAN : STUDIO_PANEL_MIN_SPAN;
}

// `order` is how the grid's auto-placement sees a panel; the DOM itself is left
// alone, so docking a float does not have to shuffle its neighbours' nodes.
function studioApplyPanelOrder() {
	$.each(studioPanelNames, function (i, name) {
		var panel = studioPanelElement(name);
		if (!panel.length) { return; }
		var index = studioPanelOrderIndex(name);
		panel.attr('data-studio-order', index).css('order', index);
	});
}

function studioApplyPanelSpan(name) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var span = studioPanelSpanValue(name);
	panel.attr('data-studio-span', span).css('grid-column', 'span ' + span);
	var wide = span > STUDIO_PANEL_MIN_SPAN;
	$('.studio_span_toggle[data-panel="' + name + '"]').each(function () {
		var button = $(this);
		button.attr('aria-pressed', wide ? 'true' : 'false');
		button.text(studioLayoutText(wide ? 'Narrow' : 'Wide'));
	});
}

// A docked panel's height is its own choice, saved like its position. The
// stylesheet's arranged heights are the default until a person drags the grip.
function studioApplyPanelHeight(name) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var raw = (mixer && mixer.settings) ? mixer.settings['studio_panel_height_' + name] : undefined;
	var h = parseInt(raw, 10);
	if (h > 0 && !panel.hasClass('studio_panel_floating')) { panel.css('height', h + 'px'); }
	else { panel.css('height', ''); }
	// a saved height fixes its row; the others share what is left
	studioReflowRowHeights();
}

function studioApplyPanelHeights() {
	$.each(studioPanelSelectors, function (name) { studioApplyPanelHeight(name); });
}

function studioPersistPanelHeight(name, h) {
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	var key = 'studio_panel_height_' + name;
	if (h > 0) {
		mixer.settings[key] = String(h);
		studioSaveSettings([{ setting: key, value: String(h) }]);
	}
	else {
		delete mixer.settings[key];
		studioSaveSettings([{ setting: key, value: '' }]);
	}
}

// A docked panel's width is its own choice too. The stylesheet's content
// widths (300px for the synth, 360px for the drums) are the default until a
// person drags the right edge; the tracks panel then takes whatever is left.
function studioApplyPanelWidth(name) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var raw = (mixer && mixer.settings) ? mixer.settings['studio_panel_width_' + name] : undefined;
	var w = parseInt(raw, 10);
	if (w > 0 && !panel.hasClass('studio_panel_floating')) {
		panel.css({ width: w + 'px', flex: '0 0 auto' });
	}
	else {
		panel.css({ width: '', flex: '' });
	}
}

function studioApplyPanelWidths() {
	$.each(studioPanelSelectors, function (name) { studioApplyPanelWidth(name); });
}

function studioPersistPanelWidth(name, w) {
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	var key = 'studio_panel_width_' + name;
	if (w > 0) {
		mixer.settings[key] = String(w);
		studioSaveSettings([{ setting: key, value: String(w) }]);
	}
	else {
		delete mixer.settings[key];
		studioSaveSettings([{ setting: key, value: '' }]);
	}
}

// ---- the manual row flow ---------------------------------------------------
//
// In manual packing the grid is a column of flex rows. Each row is exactly as
// tall as its tallest panel and a row whose panels all have a saved height is
// fixed; every other row is `1 1 0`, so when a panel is made shorter its row
// shrinks and the rows below grow into the freed height. The reverse happens
// when it grows. The rows are rebuilt only when the order, a span, a hide, a
// dock or Arrange changes; a height drag just re-measures the row, so the
// pointer never fights a re-parented panel.

function studioPanelNameForElement(element) {
	var found = '';
	$.each(studioPanelSelectors, function (name) {
		if (studioPanelElement(name)[0] === element) { found = name; }
	});
	return found;
}

function studioManualUnwrap() {
	var grid = $('#studio_grid');
	if (!grid.length) { return; }
	grid.children('.studio_grid_row').each(function () {
		var row = $(this);
		row.children('div').each(function () { grid.append(this); });
		row.remove();
	});
}

// The width a panel contributes when the rows are packed: its saved width, or
// the stylesheet's content width. The tracks panel (and the console) are the
// flexible ones, so their default is a floor, not a size.
function studioPackWidth(name) {
	var raw = (mixer && mixer.settings) ? mixer.settings['studio_panel_width_' + name] : undefined;
	var w = parseInt(raw, 10);
	if (w > 0) { return w; }
	if (name === 'synth') { return 300; }
	if (name === 'drums') { return 360; }
	return 280;
}

function studioManualReflow() {
	var grid = $('#studio_grid');
	if (!grid.length) { return; }
	if (grid.hasClass('studio_arranged')) { studioManualUnwrap(); return; }
	// lift every panel out of its row before regrouping; a hidden one stays a
	// direct child (display:none takes no space) and rejoins on Show
	studioManualUnwrap();
	var order = studioPanelNames.slice().sort(function (a, b) {
		return studioPanelOrderIndex(a) - studioPanelOrderIndex(b);
	});
	// A row holds as many span-one panels as its width allows, so the tracks
	// panel can sit beside the instruments and grow into the rest of the line.
	// A two-column panel always owns its row.
	var available = Math.max(240, (grid[0].clientWidth || 0) - 8);
	var rows = [], row = null;
	$.each(order, function (i, name) {
		var panel = studioPanelElement(name);
		if (!panel.length || panel.hasClass('studio_panel_floating') || !panel.is(':visible')) { return; }
		var span = Math.min(STUDIO_PANEL_MAX_SPAN, studioPanelSpanValue(name));
		var w = (span >= STUDIO_PANEL_MAX_SPAN) ? available : studioPackWidth(name);
		if (!row || span >= STUDIO_PANEL_MAX_SPAN || (row.items > 0 && row.width + 6 + w > available)) {
			row = { items: 0, width: 0, element: $('<div class="studio_grid_row"></div>') };
			rows.push(row);
		}
		panel.attr('data-studio-name', name);
		row.element.append(panel);
		row.width += (row.items ? 6 : 0) + w;
		row.items += 1;
	});
	$.each(rows, function (i, r) { grid.append(r.element); });
	studioApplyPanelWidths();
	studioReflowRowHeights();
}

// A row's height is the tallest saved height among its panels; a row with none
// is flexible, and a transport row keeps only its content height.
function studioRowFixedHeight(row) {
	var fixed = 0;
	row.children('div').each(function () {
		var name = $(this).attr('data-studio-name') || studioPanelNameForElement(this);
		var raw = (mixer && mixer.settings) ? mixer.settings['studio_panel_height_' + name] : undefined;
		var h = parseInt(raw, 10);
		if (!(h > 0)) {
			var inline = this.style ? parseFloat(this.style.height) : 0;
			if (inline > 0) { h = inline; }
		}
		if (h > fixed) { fixed = h; }
	});
	return fixed;
}

function studioReflowRowHeights() {
	$('#studio_grid .studio_grid_row').each(function () {
		var row = $(this);
		var h = studioRowFixedHeight(row);
		if (h > 0) {
			// a panel the person made short keeps its exact row, even below the
			// 120px floor the flexible rows use
			row.css({ 'flex': '0 0 ' + h + 'px', 'min-height': '0' });
		}
		else if (row.children('#studio_transport_panel').length) {
			row.css({ 'flex': '0 0 auto', 'min-height': '0' });
		}
		else {
			row.css({ 'flex': '1 1 0', 'min-height': '120px' });
		}
	});
}

function studioSnapPanelWidth(panel, w) {
	var sizes = studioPanelNeighbourSizes(panel);
	var row = panel.closest('.studio_grid_row');
	var max = row.length ? row[0].clientWidth : ($('#studio_grid')[0] ? $('#studio_grid')[0].clientWidth : w);
	return Math.max(STUDIO_PANEL_MIN_WIDTH, Math.min(max || w, studioSnapTo(w, sizes.widths)));
}

// Snap a drag to the 8px grid and, within 8px, to a neighbour's edge/size.
function studioSnapTo(value, candidates) {
	var best = Math.round(value / 8) * 8;
	var best_d = 8.01;
	(candidates || []).forEach(function (c) {
		if (!isFinite(c)) { return; }
		var d = Math.abs(c - value);
		if (d <= 8 && d < best_d) { best = c; best_d = d; }
	});
	return Math.round(best);
}

function studioPanelNeighbourSizes(panel) {
	var widths = [], heights = [];
	$('[data-studio-name], .studio_panel_floating').not(panel).each(function () {
		var r = this.getBoundingClientRect();
		if (r.width < 1 || r.height < 1) { return; }
		widths.push(Math.round(r.width));
		heights.push(Math.round(r.height));
	});
	return { widths: widths, heights: heights };
}

function studioSnapPanelHeight(panel, h) {
	var sizes = studioPanelNeighbourSizes(panel);
	var content = panel && panel[0] ? panel[0].scrollHeight : 0;
	if (content) { sizes.heights.push(content); }
	// the limit is the whole dock, not the row the panel now sits in, or a
	// taller panel could never grow past its current row
	var dock = panel && panel.closest('#studio_grid, #studio').length ? panel.closest('#studio_grid, #studio')[0] : null;
	var limit = dock ? dock.clientHeight : h;
	return Math.max(64, Math.min(limit || h, studioSnapTo(h, sizes.heights)));
}

function studioSnapPanelPosition(panel, left, top) {
	var base = $('#studio')[0].getBoundingClientRect();
	var xs = [], ys = [];
	$('[data-studio-name], .studio_panel_floating').not(panel).each(function () {
		var r = this.getBoundingClientRect();
		if (r.width < 1 || r.height < 1) { return; }
		xs.push(r.left - base.left, r.right - base.left);
		ys.push(r.top - base.top, r.bottom - base.top);
	});
	return { left: studioSnapTo(left, xs), top: studioSnapTo(top, ys) };
}

function studioPersistPanelPosition(name, value) {
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	var setting = 'studio_panel_position_' + name;
	var text = JSON.stringify(value);
	mixer.settings[setting] = text;
	studioSaveSettings([{ setting: setting, value: text }]);
}

function studioPanelSize(panel) {
	return {
		width: parseFloat(panel.css('width')) || panel.outerWidth() || 240,
		height: parseFloat(panel.css('height')) || panel.outerHeight() || 160
	};
}

function studioPanelBox(panel) {
	var size = studioPanelSize(panel);
	return {
		left: parseFloat(panel.css('left')) || 0,
		top: parseFloat(panel.css('top')) || 0,
		width: size.width,
		height: size.height
	};
}

// A float keeps the order and span it came from, so a reload followed by Dock
// does not silently send a reordered panel back to its default place.
function studioFloatState(name, panel) {
	var state = studioPanelBox(panel);
	state.order = studioPanelOrderIndex(name);
	state.span = studioPanelSpanValue(name);
	return state;
}

function studioClampPanelBox(panel, left, top, width, height) {
	var studio = $('#studio')[0];
	if (!studio) { return { left: left, top: top, width: width, height: height }; }
	var rect = studio.getBoundingClientRect();
	var minWidth = 180;
	var minHeight = 120;
	width = Math.max(minWidth, Math.min(width || minWidth, Math.max(minWidth, rect.width)));
	height = Math.max(minHeight, Math.min(height || minHeight, Math.max(minHeight, rect.height)));
	var maxLeft = Math.max(0, rect.width - width);
	var maxTop = Math.max(0, rect.height - height);
	return {
		left: Math.max(0, Math.min(left, maxLeft)),
		top: Math.max(0, Math.min(top, maxTop)),
		width: width,
		height: height
	};
}

function studioClampPanelPosition(panel, left, top) {
	var size = studioPanelSize(panel);
	var box = studioClampPanelBox(panel, left, top, size.width, size.height);
	return { left: box.left, top: box.top };
}

function studioFloatPanel(name, position, persist) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return panel; }
	if (!panel.hasClass('studio_panel_floating')) {
		var rect = panel[0].getBoundingClientRect();
		var studioRect = $('#studio')[0].getBoundingClientRect();
		panel.addClass('studio_panel_floating');
		// A panel floated at the window's full width has nowhere to move
		// sideways; keep it narrower than the desk so both axes are free.
		var width = Math.min(rect.width > 20 ? rect.width : 320, Math.max(180, studioRect.width * 0.7));
		var height = rect.height > 20 ? rect.height : 200;
		var box = studioClampPanelBox(panel,
			Math.max(0, rect.left - studioRect.left),
			Math.max(0, rect.top - studioRect.top),
			width, height);
		panel.css({
			left: box.left + 'px',
			top: box.top + 'px',
			width: box.width + 'px',
			height: box.height + 'px'
		});
		$('#studio').append(panel);
		// it left its row: the panels below close the gap
		studioManualReflow();
	}
	if (position && typeof position.left == 'number' && typeof position.top == 'number') {
		var current = studioPanelSize(panel);
		var placed = studioClampPanelBox(panel, position.left, position.top,
			typeof position.width == 'number' ? position.width : current.width,
			typeof position.height == 'number' ? position.height : current.height);
		panel.css({
			left: placed.left + 'px',
			top: placed.top + 'px',
			width: placed.width + 'px',
			height: placed.height + 'px'
		});
	}
	if (typeof studioDrumsGridState === 'function') { studioDrumsGridState(); }
	if (persist) {
		studioPersistPanelPosition(name, studioFloatState(name, panel));
	}
	return panel;
}

function studioDockPanel(name, persist) {
	var panel = studioPanelElement(name);
	if (!panel.length || !panel.hasClass('studio_panel_floating')) { return; }
	panel.removeClass('studio_panel_floating studio_panel_dragging studio_panel_resizing')
		.css({ left: '', top: '', width: '', height: '', position: '', flex: '' });
	studioApplyPanelHeight(name);
	studioApplyPanelWidth(name);
	// back into the grid; the row flow puts it in its place from the saved order
	$('#studio_grid').append(panel);
	studioApplyPanelOrder();
	studioApplyPanelSpan(name);
	studioManualReflow();
	if (typeof studioDrumsGridState === 'function') { studioDrumsGridState(); }
	if (persist !== false) {
		studioPersistPanelPosition(name, {
			docked: true,
			order: studioPanelOrderIndex(name),
			span: studioPanelSpanValue(name)
		});
	}
}

function studioApplyPanelPositions() {
	var saved = {};
	var any_saved = false;
	var arranged = String((mixer && mixer.settings) ? mixer.settings['studio_panel_arranged'] : '') == 'yes';
	$.each(studioPanelSelectors, function (name) {
		var raw = (mixer && mixer.settings) ? mixer.settings['studio_panel_position_' + name] : undefined;
		if (!raw) { return; }
		var position = null;
		try { position = JSON.parse(raw); } catch (e) { return; }
		if (!position) { return; }
		saved[name] = position;
		any_saved = true;
		if (typeof position.span == 'number') { studioPanelSpan[name] = position.span; }
	});

	// A first open has no saved arrangement, so the DAW-informed preset is what
	// it starts from. Once anything is saved the user's own packing wins.
	if (!any_saved) {
		studioApplyArrange(true);
		return;
	}

	// Rebuild the shared order from whatever each panel saved, keeping the
	// default order for a panel that has never been moved (and as the tie-break).
	var defaultIndex = {};
	$.each(studioPanelNames, function (i, name) { defaultIndex[name] = i; });
	studioPanelOrder = studioPanelNames.slice().sort(function (a, b) {
		var oa = (saved[a] && typeof saved[a].order == 'number') ? saved[a].order : defaultIndex[a];
		var ob = (saved[b] && typeof saved[b].order == 'number') ? saved[b].order : defaultIndex[b];
		return (oa - ob) || (defaultIndex[a] - defaultIndex[b]);
	});

	studioApplyPanelOrder();
	$.each(studioPanelNames, function (i, name) { studioApplyPanelSpan(name); });
	$.each(studioPanelNames, function (i, name) {
		var position = saved[name];
		if (!position) { return; }
		if (position.docked) { studioDockPanel(name, false); }
		else if (typeof position.left == 'number' && typeof position.top == 'number') {
			studioFloatPanel(name, position, false);
		}
	});

	// A saved float is manual packing; otherwise the remembered mode decides.
	if (arranged && !$('.studio_panel_floating').length) { studioSetArranged(true, false); }
	else { studioSetArranged(false, false); }
}

// A window can be smaller than the desk it was floated on; pull a saved panel
// back so at least its own box stays inside the Studio window.
$(window).on('resize', function () {
	$('.studio_panel_floating').each(function () {
		var panel = $(this);
		var box = studioPanelBox(panel);
		var position = studioClampPanelPosition(panel, box.left, box.top);
		var fitted = studioClampPanelBox(panel, position.left, position.top, box.width, box.height);
		panel.css({
			left: fitted.left + 'px',
			top: fitted.top + 'px',
			width: fitted.width + 'px',
			height: fitted.height + 'px'
		});
	});
});

function studioApplyLayoutSettings() {
	// Positions first: a panel that is about to be hidden has no size to measure.
	studioApplyPanelPositions();
	studioApplyPanelHeights();
	studioApplyPanelWidths();
	studioApplyHideSettings();
	// the manual rows are rebuilt from the restored order, spans and heights
	studioManualReflow();
	if (typeof studioDrumsGridState === 'function') { studioDrumsGridState(); }
	studioUpdateTrackCount();
}

// ---- drag, resize and the docked grid --------------------------------------

// The docked panel under the pointer, if any. Used on pointerup: a docked panel
// dropped on another inserts itself before that panel; dropped anywhere else it
// stays a float.
function studioDockedPanelUnder(name, original) {
	if (!original) { return null; }
	var target = null;
	var x = original.clientX;
	var y = original.clientY;
	$.each(studioPanelSelectors, function (other) {
		if (other == name) { return; }
		var panel = studioPanelElement(other);
		if (!panel.length || panel.hasClass('studio_panel_floating') || !panel.is(':visible')) { return; }
		var rect = panel[0].getBoundingClientRect();
		if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
			target = other;
			return false;
		}
	});
	return target;
}

// Insert a dropped panel before the one it landed on and let the rest reflow.
// The saved order is the whole arrangement, not just the moved panel's place.
function studioReorderDockedPanel(name, target) {
	studioExitArrange(true);
	var from = studioPanelOrderIndex(name);
	studioPanelOrder.splice(from, 1);
	var to = studioPanelOrderIndex(target);
	studioPanelOrder.splice(to, 0, name);
	studioDockPanel(name, false);
	studioApplyPanelOrder();
	studioManualReflow();
	studioPersistPanelOrder();
}

// Persist order and span for every panel. A floated panel keeps its box, and its
// saved order/span so Dock returns it to the packed place it left.
function studioPersistPanelOrder() {
	$.each(studioPanelNames, function (i, name) {
		var panel = studioPanelElement(name);
		if (!panel.length) { return; }
		var value = panel.hasClass('studio_panel_floating')
			? studioFloatState(name, panel)
			: { docked: true, order: studioPanelOrderIndex(name), span: studioPanelSpanValue(name) };
		studioPersistPanelPosition(name, value);
	});
}

// A pointer drag moves a floating panel; pressing the handle on a docked panel
// detaches it at its current place first, so the drag begins where you grabbed.
$(document).on('pointerdown', '.studio_drag_handle', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var name = $(this).attr('data-studio-drag');
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var wasFloating = panel.hasClass('studio_panel_floating');
	// Grabbing a panel is a manual action: the arranged areas let go first, so
	// the drag begins from the panel's packing place.
	studioExitArrange(true);
	studioFloatPanel(name);
	var rect = panel[0].getBoundingClientRect();
	studioPanelDrag = {
		name: name,
		panel: panel,
		wasFloating: wasFloating,
		dx: e.originalEvent.clientX - rect.left,
		dy: e.originalEvent.clientY - rect.top
	};
	panel.addClass('studio_panel_dragging');
	try { this.setPointerCapture(e.originalEvent.pointerId); } catch (err) {}
	e.preventDefault();
});

$(document).on('pointerdown', '.studio_resize_handle', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var name = $(this).attr('data-studio-resize');
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var floating = panel.hasClass('studio_panel_floating');
	studioExitArrange(true);
	var rect = panel[0].getBoundingClientRect();
	studioPanelResize = {
		name: name,
		panel: panel,
		floating: floating,
		x: e.originalEvent.clientX,
		y: e.originalEvent.clientY,
		left: parseFloat(panel.css('left')) || 0,
		top: parseFloat(panel.css('top')) || 0,
		width: rect.width,
		height: rect.height,
		startH: rect.height
	};
	panel.addClass('studio_panel_resizing');
	try { this.setPointerCapture(e.originalEvent.pointerId); } catch (err) {}
	e.preventDefault();
	e.stopPropagation();
});

$(document).on('pointermove', function (e) {
	var original = e.originalEvent || {};
	if (studioPanelResize) {
		if (!studioPanelResize.floating) {
			var h = studioSnapPanelHeight(studioPanelResize.panel,
				studioPanelResize.startH + (original.clientY - studioPanelResize.y));
			studioPanelResize.panel.css({ height: h + 'px' });
			// the row follows the grip and every row below reflows into the rest
			studioReflowRowHeights();
			e.preventDefault();
			return;
		}
		var sizes = studioPanelNeighbourSizes(studioPanelResize.panel);
		var w = studioSnapTo(studioPanelResize.width + (original.clientX - studioPanelResize.x), sizes.widths);
		var hh = studioSnapTo(studioPanelResize.height + (original.clientY - studioPanelResize.y), sizes.heights);
		var box = studioClampPanelBox(studioPanelResize.panel,
			studioPanelResize.left, studioPanelResize.top, w, hh);
		studioPanelResize.panel.css({
			left: box.left + 'px',
			top: box.top + 'px',
			width: box.width + 'px',
			height: box.height + 'px'
		});
		e.preventDefault();
		return;
	}
	if (!studioPanelDrag) { return; }
	var studioRect = $('#studio')[0].getBoundingClientRect();
	var left = original.clientX - studioRect.left - studioPanelDrag.dx;
	var top = original.clientY - studioRect.top - studioPanelDrag.dy;
	var snapped = studioSnapPanelPosition(studioPanelDrag.panel, left, top);
	var clamped = studioClampPanelPosition(studioPanelDrag.panel, snapped.left, snapped.top);
	studioPanelDrag.panel.css({ left: clamped.left + 'px', top: clamped.top + 'px' });
	e.preventDefault();
});

$(document).on('pointerup pointercancel', function (e) {
	if (studioPanelResize) {
		var resize = studioPanelResize;
		studioPanelResize = null;
		resize.panel.removeClass('studio_panel_resizing');
		if (resize.floating) {
			studioPersistPanelPosition(resize.name, studioFloatState(resize.name, resize.panel));
		}
		else {
			studioPersistPanelHeight(resize.name, Math.round(resize.panel[0].getBoundingClientRect().height));
			studioReflowRowHeights();
		}
		return;
	}
	if (!studioPanelDrag) { return; }
	var drag = studioPanelDrag;
	studioPanelDrag = null;
	drag.panel.removeClass('studio_panel_dragging');
	if (!drag.wasFloating && e.type == 'pointerup') {
		var target = studioDockedPanelUnder(drag.name, e.originalEvent);
		if (target) { studioReorderDockedPanel(drag.name, target); return; }
	}
	studioPersistPanelPosition(drag.name, studioFloatState(drag.name, drag.panel));
});

// ---- width grip -------------------------------------------------------------

// The right edge sets a docked panel's width. The width snaps to the 8px grid
// and to a neighbour's width, and the panel keeps it; the tracks panel (or any
// panel the person has not sized) takes the rest of its row. The drag leaves
// Arrange, because a width is manual packing.
var studioWidthResize = null;

$(document).on('pointerdown', '.studio_width_handle', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var name = $(this).attr('data-studio-width');
	var panel = studioPanelElement(name);
	if (!panel.length || panel.hasClass('studio_panel_floating')) { return; }
	studioExitArrange(true);
	var rect = panel[0].getBoundingClientRect();
	studioWidthResize = {
		name: name,
		panel: panel,
		x: e.originalEvent.clientX,
		startW: rect.width
	};
	panel.addClass('studio_panel_resizing');
	try { this.setPointerCapture(e.originalEvent.pointerId); } catch (err) {}
	e.preventDefault();
	e.stopPropagation();
});

$(document).on('pointermove', function (e) {
	if (!studioWidthResize) { return; }
	var w = studioSnapPanelWidth(studioWidthResize.panel,
		studioWidthResize.startW + (e.originalEvent.clientX - studioWidthResize.x));
	studioWidthResize.panel.css({ width: w + 'px', flex: '0 0 auto' });
	e.preventDefault();
});

$(document).on('pointerup pointercancel', function () {
	if (!studioWidthResize) { return; }
	var resize = studioWidthResize;
	studioWidthResize = null;
	resize.panel.removeClass('studio_panel_resizing');
	studioPersistPanelWidth(resize.name, Math.round(resize.panel[0].getBoundingClientRect().width));
});

// ---- track row height ------------------------------------------------------

// A track keeps a default row height; its bottom edge drags it taller or
// shorter. The height belongs to the song (studioSaver writes track_height),
// the timeline scrolls, and the automation lane keeps its own height.
var studioTrackResize = null;

function studioTrackHeightClamp(h) {
	var panel = $('#studio_tracks_panel');
	var limit = panel.length ? panel[0].clientHeight - 48 : 280;
	if (!limit || limit < 64) { limit = 280; }
	return Math.max(64, Math.min(Math.min(280, limit), Math.round(h)));
}

$(document).on('pointerdown', '.studio_track_resize', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var row = $(this).closest('.studio_track');
	if (!row.length) { return; }
	studioTrackResize = {
		row: row,
		channel: String(row.attr('data-channel') || ''),
		y: e.originalEvent.clientY,
		startH: row[0].getBoundingClientRect().height
	};
	row.addClass('studio_track_resizing');
	try { this.setPointerCapture(e.originalEvent.pointerId); } catch (err) {}
	e.preventDefault();
	e.stopPropagation();
});

$(document).on('pointermove', function (e) {
	if (!studioTrackResize) { return; }
	var h = studioTrackHeightClamp(studioTrackResize.startH + ((e.originalEvent || {}).clientY - studioTrackResize.y));
	studioTrackResize.row.css('height', h + 'px');
	e.preventDefault();
});

$(document).on('pointerup pointercancel', function () {
	if (!studioTrackResize) { return; }
	var ch = studioTrackResize.channel;
	studioTrackResize.row.removeClass('studio_track_resizing');
	studioTrackResize = null;
	if (typeof studioDrawChannel === 'function' && ch) { studioDrawChannel(ch); }
	studioSaver();
});

$(document).on('click', '.studio_hide_toggle', function () {
	var name = $(this).attr('data-panel');
	var hidden = $(this).attr('aria-pressed') == 'true';
	studioSetPanelHidden(name, !hidden, true);
});

$(document).on('click', '.studio_float_toggle', function () {
	var name = $(this).attr('data-panel');
	var panel = studioPanelElement(name);
	studioExitArrange(true);
	if (panel.hasClass('studio_panel_floating')) { studioDockPanel(name); }
	else { studioFloatPanel(name, null, true); }
});

// The width control cycles a docked panel between one and two columns. A float is
// sized by its own box, so the control is hidden while it floats.
$(document).on('click', '.studio_span_toggle', function () {
	var name = $(this).attr('data-panel');
	var panel = studioPanelElement(name);
	if (!panel.length || panel.hasClass('studio_panel_floating')) { return; }
	studioExitArrange(true);
	studioPanelSpan[name] = (studioPanelSpanValue(name) >= STUDIO_PANEL_MAX_SPAN)
		? STUDIO_PANEL_MIN_SPAN : STUDIO_PANEL_MAX_SPAN;
	studioApplyPanelSpan(name);
	studioManualReflow();
	studioPersistPanelPosition(name, {
		docked: true,
		order: studioPanelOrderIndex(name),
		span: studioPanelSpanValue(name)
	});
});

$(document).on('click', '.studio_dock', function () {
	studioExitArrange(true);
	studioDockPanel($(this).attr('data-panel'));
});

// The synth keeps its own Hide/Show buttons; they also remember the choice.
$(document).on('click', '#studio_synth_hide', function () { studioSetPanelHidden('synth', true, true); });
$(document).on('click', '#studio_synth_show', function () { studioSetPanelHidden('synth', false, true); });

$(document).on('click', '#studio_pedalboard_close', function () {
	studioPedalboardOpen(false);
});

// ---- the dynamic track list ------------------------------------------------

// Binding the pedal drop on a strip or a per-track panel. The channel number is
// the class suffix on a strip and the channel attribute on a track panel. The
// whole tile is draggable, artwork or drawn, so the drop reads its effect name.
function studioBindChannelDrop(node) {
	node.droppable({
		accept: '.pedal',
		tolerance: 'pointer',
		drop: function (event, ui) {
			var name = ui.draggable.attr('data-effect') || ui.draggable.attr('hint');
			var m = (String($(this).attr('class')) || '').match(/channel_(\d+)/);
			var ch = m ? m[1] : $(this).attr('channel');
			if (!name || !ch) { return; }
			var channel = studioAudio.channels[ch];
			studioSelectedChannel = ch;
			studioSetInsert(ch, name, !(channel && channel.insertByName[name]));
			studioPaletteLabel();
			studioSaver();
		}
	});
}

function studioTrackNumbers() {
	var numbers = [];
	$('#studio_viewer .studio_track').each(function () {
		var n = parseInt($(this).attr('data-channel'), 10);
		if (n > 0) { numbers.push(n); }
	});
	numbers.sort(function (a, b) { return a - b; });
	return numbers;
}

function studioNextTrackNumber() {
	for (var n = 1; n <= STUDIO_MAX_TRACKS; n++) {
		if (!document.getElementById('studio_track_row_' + n)) { return n; }
	}
	return 0;
}

function studioUpdateTrackCount() {
	var count = studioTrackNumbers().length;
	$('#studio_viewer').attr('channel_count', count);
	$('#studio_track_count').text(count + ' / ' + STUDIO_MAX_TRACKS);
}

function studioSaveTrackCount() {
	var count = studioTrackNumbers().length;
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	mixer.settings['channel_count'] = String(count);
	studioSaveSettings([{ setting: 'channel_count', value: String(count) }]);
	studioUpdateTrackCount();
}

// Rewrite the channel number a cloned row or strip carries.
function studioRewireChannel(node, from, to) {
	from = String(from);
	to = String(to);
	if (from == to) { return node; }
	var classRe = new RegExp('_' + from + '\\b', 'g');
	var idRe = new RegExp('_' + from + '$');
	node.find('[channel]').addBack('[channel]').each(function () {
		if (String($(this).attr('channel')) == from) { $(this).attr('channel', to); }
	});
	node.find('[data-channel]').addBack('[data-channel]').each(function () {
		if (String($(this).attr('data-channel')) == from) { $(this).attr('data-channel', to); }
	});
	node.find('[id]').addBack('[id]').each(function () {
		if (this.id) { this.id = this.id.replace(idRe, '_' + to); }
	});
	node.find('[class]').addBack('[class]').each(function () {
		this.className = String(this.className).replace(classRe, '_' + to);
	});
	return node;
}

function studioResetChannelMarkup(node, ch) {
	node.find('.armed').attr('state', 'off').text('O');
	node.find('.channel_volume').val(1);
	node.find('.channel_fx').empty().removeClass('studio_fx_open');
	node.find('.studio_channel_rack').empty();
	node.find('.studio_channel_information').text('');
	node.find('.knob_control').val(50);
	node.find('.knob').css('transform', '');
	node.find('.studio_track_name').val(studioLayoutText('Track') + ' ' + ch);
	node.find('.studio_track_automation').attr('aria-pressed', 'false');
	node.removeClass('selected_channel studio_track_automation_on studio_fx_open');
	node.find('.selected_channel').removeClass('selected_channel');
	node.find('canvas').each(function () { this.width = 0; this.height = 0; });
	var resetVideo = function () {
		this.removeAttribute('src');
		this.srcObject = null;
		this.style.display = 'none';
	};
	node.filter('video').each(resetVideo);
	node.find('video').each(resetVideo);
}

function studioCreateTrack(ch) {
	ch = parseInt(ch, 10);
	if (!(ch > 0 && ch <= STUDIO_MAX_TRACKS)) { return null; }
	if (document.getElementById('studio_track_row_' + ch)) { return ch; }
	var rowTemplate = $('#studio_viewer .studio_track').first();
	var stripTemplate = $('#studio_mixer_strips .channel').first();
	if (!rowTemplate.length || !stripTemplate.length) { return null; }
	var from = parseInt(rowTemplate.attr('data-channel'), 10) || 1;
	var stripFrom = parseInt((String(stripTemplate.attr('class')).match(/channel_(\d+)/) || [])[1], 10) || from;

	var wasQuiet = studioLayoutQuiet;
	studioLayoutQuiet = true;
	var row = studioRewireChannel(rowTemplate.clone(), from, ch);
	var strip = studioRewireChannel(stripTemplate.clone(), stripFrom, ch);
	studioResetChannelMarkup(row, ch);
	studioResetChannelMarkup(strip, ch);
	var monitorTemplate = $('#studio_video_monitors video').first();
	var monitor = $();
	if (monitorTemplate.length) {
		var monitorFrom = parseInt((String(monitorTemplate.attr('id')).match(/_(\d+)$/) || [])[1], 10) || from;
		monitor = studioRewireChannel(monitorTemplate.clone(), monitorFrom, ch);
		studioResetChannelMarkup(monitor, ch);
		monitor.attr('id', 'studio_video_monitor_' + ch).hide();
	}

	$('#studio_viewer').append(row);
	$('#studio_mixer_strips').append(strip);
	if (monitor.length) { $('#studio_video_monitors').append(monitor); }

	// keep the list in channel order even when a gap is filled
	studioPlaceTrackRow(row, ch, '#studio_viewer');
	studioPlaceTrackRow(strip, ch, '#studio_mixer_strips');
	studioBindChannelDrop(row.find('.studio_track_panel'));
	studioBindChannelDrop(strip);

	if (!mixer[ch]) { mixer[ch] = {}; }
	if (!mixer[ch].media) { mixer[ch].media = { out: [], rec: [] }; }
	if (!mixer[ch].armed) { mixer[ch].armed = { state: 'off', text: 'O' }; }
	studioChannelEngine(ch);
	studioApplyChannel(ch);
	$('.knob_control[channel="' + ch + '"]').trigger('change');
	studioDrawChannel(ch);
	studioLayoutQuiet = wasQuiet;
	studioUpdateTrackCount();
	return ch;
}

function studioAddTrack() {
	var ch = studioNextTrackNumber();
	if (!ch) { return; }
	if (studioCreateTrack(ch)) {
		studioSaveTrackCount();
		studioSaver();
	}
}

function studioEnsureTracks(count) {
	count = Math.min(Math.max(parseInt(count, 10) || 0, 0), STUDIO_MAX_TRACKS);
	for (var ch = 1; ch <= count; ch++) {
		if (!document.getElementById('studio_track_row_' + ch)) { studioCreateTrack(ch); }
	}
	studioUpdateTrackCount();
}

function studioEnsureTracksForSong(song) {
	var highest = 0;
	$.each(song || {}, function (key) {
		if (/^[0-9]+$/.test(key)) {
			var n = parseInt(key, 10);
			if (n > highest) { highest = n; }
		}
	});
	if (highest) { studioEnsureTracks(highest); }
}

// Move a freshly cloned row or strip into channel order.
function studioPlaceTrackRow(node, ch, container) {
	var placed = false;
	$(container).children().each(function () {
		var other = parseInt($(this).attr('data-channel'), 10);
		if (!other) {
			var m = String($(this).attr('class') || '').match(/channel_(\d+)/);
			other = m ? parseInt(m[1], 10) : 0;
		}
		if (other > ch) { $(this).before(node); placed = true; return false; }
	});
	if (!placed) { $(container).append(node); }
}

// A loaded song owns its track list: build what it needs and drop the rows the
// previous song left behind. Quiet, because this is not a user edit.
function studioSyncTrackList(song) {
	var wanted = {};
	$.each(song || {}, function (key) {
		if (/^[0-9]+$/.test(key)) { wanted[String(key)] = true; }
	});
	if (!Object.keys(wanted).length) { return; }
	studioEnsureTracksForSong(song);
	var wasQuiet = studioLayoutQuiet;
	studioLayoutQuiet = true;
	studioTrackNumbers().forEach(function (ch) {
		if (!wanted[String(ch)]) { studioRemoveTrack(ch, true); }
	});
	studioLayoutQuiet = wasQuiet;
	studioUpdateTrackCount();
}

function studioRemoveTrack(ch, quiet) {
	ch = String(ch);
	if (studioTrackNumbers().length <= 1) {
		$('.studio_track_delete[channel="' + ch + '"]').attr('armed', 'no').css('background-color', '');
		return;
	}
	var media = mixer[ch] && mixer[ch].media;
	if (media && media.rec) {
		$.each(media.rec, function (i, recorder) {
			if (recorder && recorder.state && recorder.state != 'inactive') {
				try { recorder.stop(); } catch (e) {}
			}
		});
	}
	var channel = studioAudio.channels[ch];
	if (channel) {
		['trim', 'bass', 'mid', 'treble', 'recGain', 'recAnalyser', 'recDest', 'playBus', 'playPan', 'monGain'].forEach(function (key) {
			if (channel[key] && channel[key].disconnect) {
				try { channel[key].disconnect(); } catch (e) {}
			}
		});
		(channel.inserts || []).forEach(function (insert) {
			if (insert.destroy) { try { insert.destroy(); } catch (e) {} }
		});
	}
	delete studioAudio.channels[ch];
	delete mixer[ch];
	$('#studio_track_row_' + ch).remove();
	$('#studio_mixer_strips .channel_' + ch).remove();
	$('#studio_video_monitor_' + ch).remove();
	$('#studio_track_container .studio_video[id^="studio_channel_' + ch + '_"]').remove();
	if (String(studioSelectedChannel) == ch) {
		var left = studioTrackNumbers();
		studioSelectedChannel = left.length ? left[0] : 0;
	}
	studioTakesChanged();
	studioUpdateTrackCount();
	if (typeof studioUpdatePedalLamps === 'function') { studioUpdatePedalLamps(); }
	if (!quiet) {
		studioSaveTrackCount();
		studioSaver();
	}
}

$(document).on('click', '#studio_add_track', function () { studioAddTrack(); });

$(document).on('click', '.studio_track_delete', function () {
	var button = $(this);
	if (button.attr('armed') != 'yes') {
		button.attr('armed', 'yes').css({ 'background-color': 'red' });
		clearTimeout(button.data('studioDeleteTimer'));
		button.data('studioDeleteTimer', setTimeout(function () {
			button.attr('armed', 'no').css({ 'background-color': '' });
		}, 2000));
		return;
	}
	studioRemoveTrack(button.attr('channel'));
});

$(document).on('change', '.studio_track_name', function () {
	var ch = $(this).attr('channel');
	if (!/^[0-9]+$/.test(ch)) { return; }
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].name = $(this).val();
	studioSaver();
});

$(document).on('click', '.studio_track_automation', function () {
	var button = $(this);
	var ch = button.attr('channel');
	var on = button.attr('aria-pressed') != 'true';
	button.attr('aria-pressed', on ? 'true' : 'false');
	$('#studio_track_row_' + ch).toggleClass('studio_track_automation_on', on);
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].automation_view = on ? 1 : 0;
	studioSaver();
});

$(document).on('click', '.studio_track_fx', function () {
	var ch = $(this).attr('channel');
	studioSelectedChannel = ch;
	var badge = $('.channel_fx[channel="' + ch + '"]');
	var open = !badge.hasClass('studio_fx_open');
	badge.toggleClass('studio_fx_open', open);
	// FX shows this track's chain in the panel; the shelf stays where it was.
	$('#studio_track_row_' + ch).toggleClass('studio_fx_open', open);
	studioRackRender(ch);
	studioPaletteLabel();
	if (open) { studioPedalboardOpen(true); }
});
