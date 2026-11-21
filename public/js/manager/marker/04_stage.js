// ---- the stage: paper size, rulers, status bar, brush cursor ------------
// Marker's board is a document of a chosen size, and the stage around it is
// chrome: the rulers say where you are in document pixels, the status bar says
// what pixel and what percentage the cursor is over, and the cursor itself is
// a ring the size of the brush instead of the hidden system pointer.

// The standard papers, in screen pixels (96 to the inch), so a stroke keeps a
// sensible width on any of them. "Screen" is the old behaviour: a board the
// size of the window, with no paper edge.
var markerSizes = [
	{ name: 'Letter', w: 816, h: 1056, label: '8.5 by 11 inches' },
	{ name: 'Legal', w: 816, h: 1344, label: '8.5 by 14 inches' },
	{ name: 'Poster', w: 1056, h: 1632, label: '11 by 17 inches' },
	{ name: 'Flyer', w: 528, h: 816, label: 'A5, 5.8 by 8.3 inches' },
	{ name: 'CD cover', w: 480, h: 480, label: 'a CD jewel case cover' },
	{ name: 'DVD cover', w: 510, h: 718, label: 'a DVD case cover' },
	{ name: 'Business card', w: 336, h: 192, label: '3.5 by 2 inches' },
	{ name: 'Screen', w: 0, h: 0, label: 'the board you have now' }
];

function markerSizeByName(name) {
	for (var i = 0; i < markerSizes.length; i++) {
		if (markerSizes[i].name == name) { return markerSizes[i]; }
	}
	return markerSizes[0];
}

// The paper a drawing is on is remembered, so reopening Marker shows the same
// sheet rather than a board the size of whatever window opened it.
function markerDocRemember(name, w, h) {
	try {
		localStorage.setItem('marker_doc', JSON.stringify({ name: name || '', w: w, h: h }));
	} catch (err) {}
}

function markerDocRemembered() {
	var raw = localStorage.getItem('marker_doc');
	if (!raw) { return undefined; }
	var doc = undefined;
	try { doc = JSON.parse(raw); } catch (err) { return undefined; }
	if (!doc || !doc.w || !doc.h) { return undefined; }
	return doc;
}

function markerDocName() {
	var doc = markerDocRemembered();
	return doc && doc.name ? doc.name : '';
}

// A new drawing at a chosen size: one fresh layer on the new paper, the view
// fitted to it, and the history forgotten. This is what Init asks for.
function markerDocNew(name, w, h) {
	var viewport = document.getElementById('marker_viewport');
	if (!w || !h) {
		w = viewport && viewport.clientWidth ? viewport.clientWidth : 816;
		h = viewport && viewport.clientHeight ? viewport.clientHeight : 1056;
		name = name || 'Screen';
	}
	var layer = markerNewLayer('Layer 1');
	layer.canvas.width = Math.max(1, Math.round(w));
	layer.canvas.height = Math.max(1, Math.round(h));
	markerLayers = [layer];
	markerLayerActive = 0;
	markerLayerCounter = 1;
	markerHistoryClear();
	markerLastPoint = undefined;
	markerPreview = undefined;
	markerSessionUuid = undefined;
	markerSessionName = undefined;
	markerDocRemember(name, layer.canvas.width, layer.canvas.height);
	markerViewFit();
	markerLayerList();
	markerCompose();
	markerStageRefresh();
	// a new sheet is not the working copy of the old one
	markerAutosaveDirty = true;
	markerAutosaveNow();
}

// ---- the rulers ---------------------------------------------------------

var markerRulerMemory = {};

function markerRulerCanvas(canvas) {
	if (!canvas) { return undefined; }
	var dpr = window.devicePixelRatio || 1;
	var width = Math.max(1, Math.round(canvas.clientWidth || 0));
	var height = Math.max(1, Math.round(canvas.clientHeight || 0));
	if (canvas.width != Math.round(width * dpr) || canvas.height != Math.round(height * dpr)) {
		canvas.width = Math.round(width * dpr);
		canvas.height = Math.round(height * dpr);
	}
	var ctx = canvas.getContext('2d');
	ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	return { ctx: ctx, width: width, height: height };
}

// pick the step between labelled ticks so a label never crowds its neighbour
function markerRulerStep(scale) {
	var steps = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000];
	for (var i = 0; i < steps.length; i++) {
		if (steps[i] * scale >= 46) { return steps[i]; }
	}
	return steps[steps.length - 1];
}

function markerRulerTick(doc, step, minor) {
	return Math.abs(doc % step) < 0.001 || Math.abs(Math.abs(doc % step) - step) < 0.001;
}

var markerRulerSoonTimeout;
function markerRulersSoon() {
	if (markerRulerSoonTimeout) { return; }
	markerRulerSoonTimeout = setTimeout(function() {
		markerRulerSoonTimeout = undefined;
		markerRulersDraw();
	}, 60);
}

function markerRulersDraw() {
	var size = markerDocSize();
	var step = markerRulerStep(markerView.scale);
	var minor = step % 5 == 0 ? step / 5 : step / 2;
	// the ticks wear the desk's ink, so a dark theme's light text has light ticks
	var ink = 'rgba(0,0,0,0.6)';
	try {
		var themed = (getComputedStyle(document.body).getPropertyValue('--ink') || '').trim();
		if (themed) { ink = themed; }
	} catch (err) {}

	var top = markerRulerCanvas(document.getElementById('marker_ruler_top'));
	if (top && size.w) {
		var ctx = top.ctx;
		ctx.clearRect(0, 0, top.width, top.height);
		// the paper's own span is shaded so the edge of the sheet is obvious
		ctx.fillStyle = 'rgba(0,0,0,0.07)';
		ctx.fillRect(markerView.x, 0, size.w * markerView.scale, top.height);
		ctx.font = '9px sans-serif';
		ctx.textBaseline = 'top';
		ctx.fillStyle = ink;
		ctx.strokeStyle = ink;
		ctx.beginPath();
		var start = Math.max(0, Math.floor((-markerView.x) / markerView.scale / minor) * minor);
		var end = (top.width - markerView.x) / markerView.scale;
		for (var x = start; x <= end; x += minor) {
			var sx = Math.round(x * markerView.scale + markerView.x) + 0.5;
			if (sx < 0 || sx > top.width) { continue; }
			var major = markerRulerTick(x, step, minor);
			ctx.moveTo(sx, major ? 8 : 17);
			ctx.lineTo(sx, top.height);
			if (major) { ctx.fillText(String(Math.round(x)), sx + 2, 1); }
		}
		ctx.stroke();
	}

	var left = markerRulerCanvas(document.getElementById('marker_ruler_left'));
	if (left && size.h) {
		var ctx = left.ctx;
		ctx.clearRect(0, 0, left.width, left.height);
		ctx.fillStyle = 'rgba(0,0,0,0.07)';
		ctx.fillRect(0, markerView.y, left.width, size.h * markerView.scale);
		ctx.font = '9px sans-serif';
		ctx.fillStyle = ink;
		ctx.strokeStyle = ink;
		ctx.beginPath();
		var start_y = Math.max(0, Math.floor((-markerView.y) / markerView.scale / minor) * minor);
		var end_y = (left.height - markerView.y) / markerView.scale;
		for (var y = start_y; y <= end_y; y += minor) {
			var sy = Math.round(y * markerView.scale + markerView.y) + 0.5;
			if (sy < 0 || sy > left.height) { continue; }
			var major_y = markerRulerTick(y, step, minor);
			ctx.moveTo(major_y ? left.width - 8 : left.width - 17, sy);
			ctx.lineTo(left.width, sy);
			if (major_y) {
				ctx.save();
				ctx.translate(1, sy + 2);
				ctx.rotate(-Math.PI / 2);
				ctx.textBaseline = 'top';
				ctx.fillText(String(Math.round(y)), 0, 0);
				ctx.restore();
			}
		}
		ctx.stroke();
	}
}

// ---- the status bar ----------------------------------------------------

function markerStatusRefresh() {
	var size = markerDocSize();
	var name = markerDocName();
	var size_text = (name ? name + ' \u00b7 ' : '') + size.w + ' \u00d7 ' + size.h;
	$('#marker_status_size').text(size_text);
	$('#marker_doc_line').text(size_text);
	$('#marker_status_zoom').text(Math.round(markerView.scale * 100) + '%');
	var layer = markerActiveLayer();
	$('#marker_status_layer').text(layer ? layer.name : '');
}

function markerStatusPointer(point) {
	if (point == undefined) {
		$('#marker_status_xy').text('0, 0');
		$('#marker_status_xy_percent').text('0%, 0%');
		return;
	}
	var size = markerDocSize();
	$('#marker_status_xy').text(Math.round(point.x) + ', ' + Math.round(point.y));
	var px = size.w ? Math.round(point.x / size.w * 100) : 0;
	var py = size.h ? Math.round(point.y / size.h * 100) : 0;
	px = Math.max(0, Math.min(100, px));
	py = Math.max(0, Math.min(100, py));
	$('#marker_status_xy_percent').text(px + '%, ' + py + '%');
}

// ---- the brush cursor --------------------------------------------------
// A ring the size of the brush, hollow so the pixels under it stay readable,
// with a faint guide on each ruler. `markerWidth` is the stroke width, so the
// ring has the diameter the brush actually paints.

function markerBrushDiameter(pressure) {
	if (pressure == undefined) { pressure = markerStroke.pressure; }
	// the sliders' value is the brush even before the first stroke sets
	// markerStroke.size, so the ring never shows the wrong width
	var size = (marker && marker.selected_marker_size) ? marker.selected_marker_size : markerStroke.size;
	return Math.max(6, size * 2 * (0.3 + 0.7 * pressure) * markerView.scale);
}

// A selection tool has no brush to show, so the ring goes and the canvas wears
// a crosshair (or the move cursor) instead.
function markerToolCursor() {
	marker.current_tool = localStorage.getItem('marker_tool') || 'pencil';
	$('#marker_viewport').attr('data-tool', marker.current_tool);
}

// The nodes a pointer move touches. They are looked up once and written with
// style properties directly: this runs at the stylus's own rate, and a jQuery
// lookup plus a style write per node per event is what made the ring feel like
// it had its own idea of where the mouse was.
var markerCursorNodes = {};
function markerCursorNode(name, id) {
	if (markerCursorNodes[name]) { return markerCursorNodes[name]; }
	var node = document.getElementById(id);
	markerCursorNodes[name] = node;
	return node;
}

function markerCursorForget() {
	markerCursorNodes = {};
}

function markerBrushCursorMove(screen) {
	markerRulerMemory.last_screen = screen;
	var cursor = markerCursorNode('ring', 'marker_brush_cursor');
	var guide_x = markerCursorNode('guide_x', 'marker_cursor_x');
	var guide_y = markerCursorNode('guide_y', 'marker_cursor_y');
	var mark_x = markerCursorNode('ruler_x', 'marker_ruler_cursor_x');
	var mark_y = markerCursorNode('ruler_y', 'marker_ruler_cursor_y');
	if (screen == undefined) {
		if (cursor) { cursor.style.display = 'none'; }
		if (guide_x) { guide_x.style.display = 'none'; }
		if (guide_y) { guide_y.style.display = 'none'; }
		if (mark_x) { mark_x.style.display = 'none'; }
		if (mark_y) { mark_y.style.display = 'none'; }
		markerRulerMemory.cursor_x_screen = undefined;
		markerRulerMemory.cursor_y_screen = undefined;
		return;
	}
	// the guides and the ruler marks are thin lines: a translate, no layout
	if (guide_x) {
		guide_x.style.display = 'block';
		guide_x.style.transform = 'translateX(' + screen.x + 'px)';
	}
	if (guide_y) {
		guide_y.style.display = 'block';
		guide_y.style.transform = 'translateY(' + screen.y + 'px)';
	}
	markerRulerMemory.cursor_x_screen = Math.round(screen.x);
	markerRulerMemory.cursor_y_screen = Math.round(screen.y);
	if (mark_x) {
		mark_x.style.display = 'block';
		mark_x.style.transform = 'translateX(' + ((markerRulerMemory.top_left || 0) + screen.x) + 'px)';
	}
	if (mark_y) {
		mark_y.style.display = 'block';
		mark_y.style.transform = 'translateY(' + ((markerRulerMemory.left_top || 0) + screen.y) + 'px)';
	}
	var tool = marker.current_tool || localStorage.getItem('marker_tool') || 'pencil';
	if (!cursor) { return; }
	if (tool == 'select' || tool == 'lasso' || tool == 'move') {
		cursor.style.display = 'none';
		return;
	}
	var diameter = markerBrushDiameter(markerStroke.pressure);
	cursor.style.width = diameter + 'px';
	cursor.style.height = diameter + 'px';
	cursor.style.display = 'block';
	cursor.style.transform = 'translate(' + (screen.x - diameter / 2) + 'px, ' + (screen.y - diameter / 2) + 'px)';
}

function markerBrushCursorHide() {
	markerBrushCursorMove(undefined);
}

// ---- the paper edge ----------------------------------------------------

function markerPaperEdge() {
	var edge = $('#marker_paper_edge');
	var size = markerDocSize();
	if (edge.length == 0) { return; }
	if (!size.w || !size.h) { edge.hide(); return; }
	edge.css({
		left: markerView.x + 'px',
		top: markerView.y + 'px',
		width: (size.w * markerView.scale) + 'px',
		height: (size.h * markerView.scale) + 'px'
	});
	// a board the size of the window has no edge worth drawing
	var covers = Math.abs(size.w * markerView.scale - $('#marker_viewport').innerWidth()) < 2 &&
		Math.abs(size.h * markerView.scale - $('#marker_viewport').innerHeight()) < 2;
	edge.toggle(!covers);
}

// ---- one entry point for "the view or the document changed" -------------
// Zoom, pan, fit, a resize or a new paper all move the same furniture: the
// rulers, the status bar, the paper edge and the brush ring's size.
function markerViewChanged() {
	markerViewSeq++;
	// a wheel zoom fires many times a second; the rulers are throttled, the
	// cheap DOM furniture is not
	markerRulersSoon();
	markerStatusRefresh();
	markerPaperEdge();
	if (typeof markerSelectionRedraw === 'function') { markerSelectionRedraw(); }
	if (markerRulerMemory.last_screen != undefined) { markerBrushCursorMove(markerRulerMemory.last_screen); }
}

// ---- stage sizing ------------------------------------------------------

// Where the ruler marks sit and how long they are, measured from the rulers
// themselves so a change to the grid cannot leave them pointing at nothing.
function markerRulerMarks() {
	var top = document.getElementById('marker_ruler_top');
	var left = document.getElementById('marker_ruler_left');
	if (top) {
		markerRulerMemory.top_left = top.offsetLeft;
		markerRulerMemory.top_top = top.offsetTop;
		markerRulerMemory.top_height = top.offsetHeight;
	}
	if (left) {
		markerRulerMemory.left_left = left.offsetLeft;
		markerRulerMemory.left_top = left.offsetTop;
		markerRulerMemory.left_width = left.offsetWidth;
	}
	var mark_x = markerCursorNode('ruler_x', 'marker_ruler_cursor_x');
	var mark_y = markerCursorNode('ruler_y', 'marker_ruler_cursor_y');
	if (mark_x && top) { mark_x.style.height = top.offsetHeight + 'px'; }
	if (mark_y && left) { mark_y.style.width = left.offsetWidth + 'px'; }
}

function markerStageResize() {
	var canvas = document.getElementById('whiteboard');
	var overlay = document.getElementById('marker_selection_overlay');
	markerRulerMarks();
	if (overlay && canvas) {
		if (overlay.width != canvas.width || overlay.height != canvas.height) {
			overlay.width = canvas.width;
			overlay.height = canvas.height;
		}
	}
	if (typeof markerSelectionOverlaySize === 'function') { markerSelectionOverlaySize(); }
	markerRulersDraw();
	markerPaperEdge();
	if (typeof markerSelectionRedraw === 'function') { markerSelectionRedraw(); }
}

function markerStageRefresh() {
	markerStageResize();
	markerStatusRefresh();
	markerLayerList();
}

// ---- the rails and their accordions ------------------------------------

function markerGroupState() {
	var raw = localStorage.getItem('marker_groups');
	if (!raw) { return {}; }
	var state = {};
	try { state = JSON.parse(raw); } catch (err) { return {}; }
	return state || {};
}

function markerGroupsApply() {
	var state = markerGroupState();
	$('.marker_group').each(function() {
		var section = $(this);
		var group = section.find('.marker_group_head').attr('group');
		if (!group) { return; }
		var open = state[group];
		if (open == undefined) { open = section.attr('data-open') != 'no'; }
		section.attr('data-open', open ? 'yes' : 'no');
		section.find('.marker_group_body').toggle(!!open);
		section.find('.marker_group_caret').html(open ? '&#9662;' : '&#9656;');
	});
}

function markerRailHidden(rail) {
	return localStorage.getItem('marker_rail_hidden_' + rail) == 'on';
}

function markerRailsApply() {
	var left_hidden = markerRailHidden('left');
	var right_hidden = markerRailHidden('right');
	$('#marker_toolbox').toggle(!left_hidden);
	$('#marker_toolbox_show').toggle(left_hidden);
	$('#marker_toolbox_right').toggle(!right_hidden);
	$('#marker_toolbox_right_show').toggle(right_hidden);
	markerGroupsApply();
}

// ---- dialogs -----------------------------------------------------------

function markerDialogOpen(id) {
	$('.marker_modal').hide();
	$('#' + id).show();
}

function markerDialogClose() {
	$('.marker_modal').hide();
}

function markerSizeDialogOpen() {
	$('#marker_size_landscape').prop('checked', false);
	markerDialogOpen('marker_size_dialog');
}

$(document).on('click', '.marker_init', function() { markerSizeDialogOpen(); });
$(document).on('click', '.marker_tool, .marker_erase_toggle', function() { markerToolCursor(); });

$(document).on('click', '.marker_modal_cancel', function() { markerDialogClose(); });
$(document).on('click', '.marker_modal', function(e) {
	// a click on the dimmed field, not on the card, closes
	if (e.target === this) { markerDialogClose(); }
});

$(document).on('click', '.marker_size_choice', function() {
	var choice = $(this);
	var name = choice.attr('name');
	var w = Number(choice.attr('w')) || 0;
	var h = Number(choice.attr('h')) || 0;
	if (w && h && $('#marker_size_landscape').is(':checked') && w > h) {
		var swap = w;
		w = h;
		h = swap;
		name = name + ' (landscape)';
	}
	markerDialogClose();
	markerDocNew(name, w, h);
});

$(document).on('click', '.marker_group_head', function() {
	var head = $(this);
	var group = head.attr('group');
	if (!group) { return; }
	var section = head.closest('.marker_group');
	var open = section.attr('data-open') != 'yes';
	section.attr('data-open', open ? 'yes' : 'no');
	section.find('.marker_group_body').slideToggle(120);
	head.find('.marker_group_caret').html(open ? '&#9662;' : '&#9656;');
	var state = markerGroupState();
	state[group] = open;
	localStorage.setItem('marker_groups', JSON.stringify(state));
	// the layer thumbnails are only drawn while the list is on screen, so
	// opening the fold fills them in
	if (group == 'layers' && open) {
		setTimeout(function() { if (typeof markerLayerList === 'function') { markerLayerList(); } }, 200);
	}
});

// ---- Save to appointment -----------------------------------------------
// The picker lists recent appointments that are not Marker's own drawings, and
// the save attaches this drawing to the one chosen.

function markerAttachOpen() {
	markerDialogOpen('marker_attach_dialog');
	var list = $('#marker_attach_list');
	list.html('<i>Loading\u2026</i>');
	$.ajax({
		url: '/manager/marker/appointments',
		type: 'GET',
		data: { app: markerApp() },
		success: function(response) {
			var rows = (response && response.appointments) || [];
			list.html('');
			if (rows.length == 0) { list.html('<i>No recent appointments.</i>'); return; }
			$.each(rows, function(i, row) {
				var item = $('<button class="button marker_attach_row hover"></button>').attr('uuid', row.uuid);
				item.append($('<b></b>').text(row.name || row.app || 'appointment'));
				item.append($('<span class="marker_attach_when"></span>').text(' ' + markerAttachWhen(row.timestamp)));
				list.append(item);
			});
		},
		error: function() { list.html('<i>Could not read the appointments.</i>'); }
	});
}

// an appointment's timestamp is epoch seconds, but a Marker save has always
// written milliseconds, so both read the same way here
function markerAttachWhen(timestamp) {
	var value = Number(timestamp);
	if (!value) { return ''; }
	if (value < 100000000000) { value = value * 1000; }
	return new Date(value).toLocaleString();
}

function markerAttachSave(uuid) {
	var img = markerFlatten().toDataURL('image/png');
	var marker = (typeof markerInfoGrabber === 'function') ? markerInfoGrabber() : {};
	$.ajax({
		url: '/manager/marker/save',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			attach_uuid: uuid,
			img: img,
			marker: JSON.stringify(marker),
			browser_tab_id: (typeof bti !== 'undefined') ? bti : '',
			app: topWindow('marker')
		},
		success: function() { say_it('saved to the appointment!'); },
		error: function() { jawnosAlertText('That appointment could not take the drawing.'); }
	});
}

$(document).on('click', '.marker_save_appointment', function() { markerAttachOpen(); });

$(document).on('click', '.marker_attach_row', function() {
	var uuid = $(this).attr('uuid');
	markerDialogClose();
	markerAttachSave(uuid);
});

// ---- the cursor's own numbers ------------------------------------------
// Marker's pointer handlers call this on every move; it is deliberately cheap
// because a stylus reports at the screen's refresh rate.
var markerStatusPending = undefined;
function markerStatusMoved(point) {
	markerBrushCursorMove(point.screen);
	if (markerStatusPending) { markerStatusPending = point; return; }
	markerStatusPending = point;
	requestAnimationFrame(function() {
		var next = markerStatusPending;
		markerStatusPending = undefined;
		markerStatusPointer(next);
	});
}

// ---- init --------------------------------------------------------------

var markerStageObserver;
var markerStageBound = false;
function markerStageInit() {
	markerCursorForget();
	markerToolCursor();
	markerRailsApply();
	markerStageResize();
	// The window is rebuilt on each open, so re-attach to the viewport that is
	// here now. Disconnecting first releases the closed stage: an observer left
	// on the old viewport keeps that subtree alive and, worse, silently stops
	// following the new one on the second open.
	if (window.ResizeObserver) {
		var viewport = document.getElementById('marker_viewport');
		if (viewport) {
			if (!markerStageObserver) {
				markerStageObserver = new ResizeObserver(function() { markerCanvasResize(); });
			}
			markerStageObserver.disconnect();
			markerStageObserver.observe(viewport);
		}
	}
	if (!markerStageBound) {
		markerStageBound = true;
		// the brush sliders announce themselves so the ring can follow a change
		$(document).on('input', '#marker_size, #marker_transparency', function() {
			$('#marker_size_readout').text($('#marker_size').val());
			$('#marker_transparency_readout').text($('#marker_transparency').val());
			// the stroke reads its size and alpha from marker, not from the DOM
			if (typeof markerSettingsLoad === 'function') { markerSettingsLoad(); }
			if (markerRulerMemory.last_screen != undefined) { markerBrushCursorMove(markerRulerMemory.last_screen); }
		});
	}
	$('#marker_size_readout').text($('#marker_size').val());
	$('#marker_transparency_readout').text($('#marker_transparency').val());
	// the sessions panel is fetched on demand; opening Marker is a good moment
	if (typeof markerSessionPanel === 'function' && $('#marker_sessions').length > 0) { markerSessionPanel(); }
}

// Closing the window releases the observer; the next open makes a new one.
function markerStageTeardown() {
	if (markerStageObserver) { markerStageObserver.disconnect(); markerStageObserver = null; }
}

if (window.jawnosAppTeardown) { jawnosAppTeardown['marker'] = markerStageTeardown; }
