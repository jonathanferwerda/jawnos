/* [[js-split]]
   marker.js is part 1. The rest live in marker/ in name order:
     01_painting.js  - autosave, brushes, flood fill, stroke input, wheel and the toolbox
     02_input_panel.js  - mouse/pointer input, canvas init, layer panel and undo/redo/session actions
     03_selection.js  - the select and move tools, the clipboard and effects on a selection
     04_stage.js  - paper sizes, rulers, the status bar, the brush cursor and the dialogs
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var marker = {
	selected_marker_colour: 'black',
	selected_marker_size: 20,
	selected_marker_transparency: 1,
	selected_marker_colour_uuid: undefined
};
$(document).on('click change', '.marker_colour', function() {
	var uuid = $(this).attr('uuid');
	marker.selected_marker_colour = $(this).val();
	marker.selected_marker_colour_uuid = uuid;
	console.log('new colour ' + marker.selected_marker_colour);
	$('.marker_colour').each(function(i,v) { $(v).attr('status', 'inactive') });
	$('.marker_colour[uuid="' + uuid + '"]').attr('status', 'active');
	markerColourSaver()
});
var whiteboard_ctx;
var markerLayers = [];
var markerLayerActive = 0;
var markerLayerCounter = 0;
var markerCanvas = null;
var markerBoundCanvas = null;
var markerSprites = {};
var markerComposePending = false;
var markerThumbTimeout;
// a stroke touches a small rectangle, so the repaint is that rectangle only;
// markerComposeRect is the union of what is waiting for the next frame, and a
// view change (zoom, pan, resize) invalidates it and forces the whole board
var markerComposeRect = null;
var markerViewSeq = 0;
var markerComposedSeq = -1;
var markerScratchCanvas = null;
var markerStroke = { drawing: false, saved: false, spraying: false, pressure: 1, x: 0, y: 0, tool: 'pencil', erase: false, size: 20, colour: 'black', alpha: 1, pointer_id: undefined, line_from: undefined, line_to: undefined };
var markerPenSeen = 0;
var markerPenDown = false;
var markerTouches = {};
var markerPinch = undefined;
var markerPanning = undefined;
var markerHistory = [];
var markerRedo = [];
var markerHistoryLimit = 40;
var markerSessionUuid;
var markerSessionName;
var markerSessionRestored = false;
var markerPointerCaptured = false;

function markerUuid() {
	if (window.crypto && crypto.randomUUID) { return crypto.randomUUID(); }
	return 'id_' + Date.now() + '_' + Math.floor(Math.random() * 1000000);
}

// ---- layers ------------------------------------------------------------

function markerNewLayer(name) {
	var canvas = document.getElementById('whiteboard');
	var doc = markerLayers.length ? markerDocSize() : undefined;
	markerLayerCounter++;
	var layer = {
		uuid: markerUuid(),
		name: name || ('Layer ' + markerLayerCounter),
		visible: true,
		canvas: document.createElement('canvas'),
		ctx: null
	};
	// a new layer is the document's size, not the window's: every layer is the
	// same sheet, so drawing on a second layer lines up with the first
	layer.canvas.width = (doc && doc.w) || (canvas ? canvas.width : 300);
	layer.canvas.height = (doc && doc.h) || (canvas ? canvas.height : 150);
	layer.ctx = layer.canvas.getContext('2d');
	return layer;
}

// the first layer of a fresh board is the remembered paper, or Letter
function markerFirstLayer() {
	var doc = (typeof markerDocRemembered === 'function') ? markerDocRemembered() : undefined;
	if (!doc) { doc = { w: 816, h: 1056 }; }
	var layer = markerNewLayer('Layer 1');
	layer.canvas.width = doc.w || 816;
	layer.canvas.height = doc.h || 1056;
	return layer;
}

function markerActiveLayer() {
	return markerLayers[markerLayerActive];
}

// every tool draws on the active layer; the visible canvas is only ever a
// composite of the layers, so show/hide, erasing and reordering are all
// non-destructive
function markerActiveContext() {
	var layer = markerActiveLayer();
	return layer ? layer.ctx : whiteboard_ctx;
}

function markerLayerByUuid(uuid) {
	for (var i = 0; i < markerLayers.length; i++) {
		if (markerLayers[i].uuid == uuid) { return markerLayers[i]; }
	}
	return undefined;
}

function markerCompose() {
	var canvas = document.getElementById('whiteboard');
	if (!canvas || !whiteboard_ctx) { return; }
	markerComposeRect = null;
	markerComposedSeq = markerViewSeq;
	var size = markerDocSize();
	var ctx = whiteboard_ctx;
	ctx.save();
	ctx.setTransform(1, 0, 0, 1, 0, 0);
	ctx.globalAlpha = 1;
	ctx.globalCompositeOperation = 'source-over';
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	ctx.setTransform(markerView.scale, 0, 0, markerView.scale, markerView.x, markerView.y);
	markerComposePaper(ctx, size);
	for (var i = 0; i < markerLayers.length; i++) {
		if (markerLayers[i].visible) { ctx.drawImage(markerLayers[i].canvas, 0, 0); }
	}
	if (markerPreview) {
		markerDrawSegment(ctx, markerPreview.from, markerPreview.to, markerPreview.pressure);
	}
	ctx.restore();
	markerThumbSoon();
}

// the sheet itself: the document is a white page, so a stroke drawn on any
// layer sits on paper rather than on the window's own colour
function markerComposePaper(ctx, size) {
	if (!size.w || !size.h) { return; }
	ctx.fillStyle = '#ffffff';
	ctx.fillRect(0, 0, size.w, size.h);
}

// add a document-space rectangle to what the next frame has to repaint
function markerComposeDirtyRect(rect) {
	if (!rect || !rect.w || !rect.h) { return; }
	if (!markerComposeRect) {
		markerComposeRect = { x: rect.x, y: rect.y, w: rect.w, h: rect.h };
		return;
	}
	var current = markerComposeRect;
	var right = Math.max(current.x + current.w, rect.x + rect.w);
	var bottom = Math.max(current.y + current.h, rect.y + rect.h);
	current.x = Math.min(current.x, rect.x);
	current.y = Math.min(current.y, rect.y);
	current.w = right - current.x;
	current.h = bottom - current.y;
}

// The geometry of one incremental repaint: the device-space rectangle to clear
// and the part of it that is over the paper. It is its own function because the
// seam between those two rectangles is exactly what went wrong once - the clear
// reached 2px past the paint, so every patched rectangle left a transparent
// frame, and a stroke left a growing square outline around itself until the
// end-of-stroke repaint wiped it.
function markerRegionBox(rect, size, view, width, height) {
	var box = { sx: 0, sy: 0, ex: 0, ey: 0, fx: 0, fy: 0, fw: 0, fh: 0 };
	if (!size.w || !size.h || !view.scale) { return box; }
	// the slack that picks up the anti-aliased edge of a brush lives in document
	// units, so the cleared box and the painted box stay the same rectangle
	var pad = 2 / view.scale;
	var x0 = Math.max(0, Math.floor(rect.x - pad));
	var y0 = Math.max(0, Math.floor(rect.y - pad));
	var x1 = Math.min(size.w, Math.ceil(rect.x + rect.w + pad));
	var y1 = Math.min(size.h, Math.ceil(rect.y + rect.h + pad));
	if (x1 <= x0 || y1 <= y0) { return box; }
	var sx = Math.max(0, Math.floor(x0 * view.scale + view.x));
	var sy = Math.max(0, Math.floor(y0 * view.scale + view.y));
	var ex = Math.min(width, Math.ceil(x1 * view.scale + view.x));
	var ey = Math.min(height, Math.ceil(y1 * view.scale + view.y));
	if (ex <= sx || ey <= sy) { return box; }
	box.sx = sx;
	box.sy = sy;
	box.ex = ex;
	box.ey = ey;
	// the sheet's own rectangle in device space: the white fill covers the whole
	// cleared area that is over it, so no sliver is left transparent
	var paper_x = Math.floor(view.x);
	var paper_y = Math.floor(view.y);
	var paper_right = Math.ceil(view.x + size.w * view.scale);
	var paper_bottom = Math.ceil(view.y + size.h * view.scale);
	box.fx = Math.max(sx, paper_x);
	box.fy = Math.max(sy, paper_y);
	box.fw = Math.max(0, Math.min(ex, paper_right) - box.fx);
	box.fh = Math.max(0, Math.min(ey, paper_bottom) - box.fy);
	return box;
}

// Only the dirty rectangle of the board is repainted during a stroke: the
// layers are drawn through the same view transform, clipped to the rectangle,
// so the cost follows the brush rather than the size of the sheet. A view
// change bumps markerViewSeq, and the queued rectangle is thrown away with it.
function markerComposeRegion(rect) {
	var canvas = document.getElementById('whiteboard');
	if (!canvas || !whiteboard_ctx) { return; }
	var size = markerDocSize();
	if (!size.w || !size.h) { return; }
	var box = markerRegionBox(rect, size, markerView, canvas.width, canvas.height);
	if (box.ex <= box.sx || box.ey <= box.sy) { return; }
	var ctx = whiteboard_ctx;
	ctx.save();
	ctx.setTransform(1, 0, 0, 1, 0, 0);
	ctx.globalAlpha = 1;
	ctx.globalCompositeOperation = 'source-over';
	ctx.beginPath();
	ctx.rect(box.sx, box.sy, box.ex - box.sx, box.ey - box.sy);
	ctx.clip();
	ctx.clearRect(box.sx, box.sy, box.ex - box.sx, box.ey - box.sy);
	if (box.fw > 0 && box.fh > 0) {
		ctx.fillStyle = '#ffffff';
		ctx.fillRect(box.fx, box.fy, box.fw, box.fh);
	}
	ctx.setTransform(markerView.scale, 0, 0, markerView.scale, markerView.x, markerView.y);
	for (var i = 0; i < markerLayers.length; i++) {
		if (markerLayers[i].visible) { ctx.drawImage(markerLayers[i].canvas, 0, 0); }
	}
	if (markerPreview) {
		markerDrawSegment(ctx, markerPreview.from, markerPreview.to, markerPreview.pressure);
	}
	ctx.restore();
}

// stamping fires many times per frame, so coalesce the repaints - strokes stay
// live, but the composite only happens once per animation frame
function markerComposeSoon(rect) {
	if (rect) { markerComposeDirtyRect(rect); }
	if (markerComposePending) { return; }
	markerComposePending = true;
	requestAnimationFrame(function() {
		markerComposePending = false;
		// a hidden tab has nobody to show it to; the next show repaints whole
		if (document.hidden) { markerComposeRect = null; return; }
		if (markerComposeRect && markerComposedSeq === markerViewSeq) {
			var pending = markerComposeRect;
			markerComposeRect = null;
			markerComposeRegion(pending);
			return;
		}
		markerCompose();
	});
}

$(document).on('visibilitychange', function() {
	if (!document.hidden) { markerCompose(); }
});

function markerThumbSoon() {
	if (markerThumbTimeout) { return; }
	markerThumbTimeout = setTimeout(function() {
		markerThumbTimeout = undefined;
		// no panel on screen means nobody is looking at a thumbnail
		if ($('#marker_layer_list:visible').length == 0) { return; }
		$('#marker_layer_list .marker_layer_row').each(function() {
			var row = $(this);
			var layer = markerLayerByUuid(row.attr('uuid'));
			var thumb = row.find('.marker_layer_thumb')[0];
			if (!layer || !thumb) { return; }
			var ctx = thumb.getContext('2d');
			ctx.clearRect(0, 0, thumb.width, thumb.height);
			ctx.drawImage(layer.canvas, 0, 0, thumb.width, thumb.height);
		});
	}, 500);
}

function markerLayerList() {
	var list = $('#marker_layer_list');
	if (list.length == 0) { return; }
	var eye_icon = window.marker_layer_eye || '/images/make believe/eye.png';
	list.html('');
	// listed top layer first, like Gimp
	for (var i = markerLayers.length - 1; i >= 0; i--) {
		var layer = markerLayers[i];
		var row = $('<div class="marker_layer_row hover"></div>').attr('uuid', layer.uuid).attr('index', i);
		var eye = $('<img class="tiny_thumb marker_layer_eye" hint="Show/hide">').attr('src', eye_icon).attr('visible', layer.visible ? 'on' : 'off');
		eye.css('vertical-align', 'middle');
		if (!layer.visible) { eye.css('opacity', 0.25); }
		var thumb = $('<canvas class="marker_layer_thumb" width="26" height="20"></canvas>');
		thumb.css({'vertical-align': 'middle', 'border': 'solid 1px black'});
		var name = $('<span class="marker_layer_name hover" hint="Double click to rename" style="font-size:11px;vertical-align:middle;"></span>').text(layer.name);
		row.append(eye).append(thumb).append(name);
		if (i == markerLayerActive) {
			row.attr('active', 'yes');
			row.css({'background-color': 'rgba(255,255,255,0.4)', 'font-weight': 'bold'});
		}
		list.append(row);
	}
	markerThumbSoon();
}

function markerSwapLayers(a, b) {
	var swap = markerLayers[a];
	markerLayers[a] = markerLayers[b];
	markerLayers[b] = swap;
	markerLayerActive = b;
	markerLayerList();
	markerCompose();
	markerAutosaveSoon();
}

// ---- view (zoom and pan) -----------------------------------------------
// The layers are the document, at a fixed pixel size; the visible canvas just
// renders them through this view, so zooming and panning never touch the art.
var markerView = { scale: 1, x: 0, y: 0 };
var markerPreview = undefined;
var markerLastPoint = undefined;

function markerDocSize() {
	var layer = markerLayers[0];
	if (!layer) { return { w: 0, h: 0 }; }
	return { w: layer.canvas.width, h: layer.canvas.height };
}

function markerDocToScreen(x, y) {
	return { x: x * markerView.scale + markerView.x, y: y * markerView.scale + markerView.y };
}

// the whole stack at document resolution, ignoring the view - this is what
// gets saved, exported and thumbnailed, so a zoomed in view never leaks into
// a saved file
function markerFlatten() {
	var size = markerDocSize();
	var flat = document.createElement('canvas');
	flat.width = size.w || 1;
	flat.height = size.h || 1;
	var ctx = flat.getContext('2d');
	$.each(markerLayers, function(i, layer) {
		if (layer.visible) { ctx.drawImage(layer.canvas, 0, 0); }
	});
	return flat;
}

// A window outside Marker may take the drawing as a picture: the Store's
// floorplan asks for one when a room is drawn here rather than uploaded. The
// file is loaded only when Marker is opened, so the absence of this function is
// exactly "Marker is not open". It returns '' rather than throwing when there
// is no canvas to flatten.
window.jawnosMarkerSnapshot = function() {
	if (typeof markerFlatten !== 'function') { return ''; }
	try { return markerFlatten().toDataURL('image/png'); } catch (e) { return ''; }
};

function markerZoomAt(screen_x, screen_y, factor) {
	var scale = Math.max(0.02, Math.min(16, markerView.scale * factor));
	if (scale == markerView.scale) { return; }
	// keep the document point under the cursor pinned while the scale changes
	markerView.x = screen_x - (screen_x - markerView.x) * (scale / markerView.scale);
	markerView.y = screen_y - (screen_y - markerView.y) * (scale / markerView.scale);
	markerView.scale = scale;
	markerViewClamp();
	markerZoomDisplay();
	markerViewChanged();
	markerCompose();
}

function markerZoomCentre(factor) {
	var canvas = document.getElementById('whiteboard');
	if (!canvas) { return; }
	markerZoomAt(canvas.width / 2, canvas.height / 2, factor);
}

// Fit shows the whole sheet: a small paper (a business card) is shown larger
// than life, a poster smaller, so the edge of the page is always in view.
function markerViewFit() {
	var canvas = document.getElementById('whiteboard');
	var size = markerDocSize();
	if (!canvas || !size.w || !size.h) { return; }
	var scale = Math.min(canvas.width / size.w, canvas.height / size.h) * 0.96;
	markerView.scale = Math.max(0.02, Math.min(8, scale));
	markerView.x = (canvas.width - size.w * markerView.scale) / 2;
	markerView.y = (canvas.height - size.h * markerView.scale) / 2;
	markerZoomDisplay();
	markerViewChanged();
	markerCompose();
}

function markerViewReset() {
	var canvas = document.getElementById('whiteboard');
	var size = markerDocSize();
	if (!canvas) { return; }
	markerView.scale = 1;
	markerView.x = (canvas.width - size.w) / 2;
	markerView.y = (canvas.height - size.h) / 2;
	markerZoomDisplay();
	markerViewChanged();
	markerCompose();
}

// never let the document wander completely off screen
function markerViewClamp() {
	var canvas = document.getElementById('whiteboard');
	var size = markerDocSize();
	if (!canvas || !size.w) { return; }
	var margin = 60;
	markerView.x = Math.min(canvas.width - margin, Math.max(margin - size.w * markerView.scale, markerView.x));
	markerView.y = Math.min(canvas.height - margin, Math.max(margin - size.h * markerView.scale, markerView.y));
}

function markerPinchStart() {
	var ids = Object.keys(markerTouches);
	if (ids.length < 2) { return undefined; }
	var a = markerTouches[ids[0]], b = markerTouches[ids[1]];
	return {
		distance: Math.max(1, Math.hypot(b.x - a.x, b.y - a.y)),
		mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 },
		scale: markerView.scale,
		x: markerView.x,
		y: markerView.y
	};
}

function markerPinchMove() {
	if (!markerPinch) { return; }
	var ids = Object.keys(markerTouches);
	if (ids.length < 2) { return; }
	var canvas = document.getElementById('whiteboard');
	var rect = canvas.getBoundingClientRect();
	var a = markerTouches[ids[0]], b = markerTouches[ids[1]];
	var distance = Math.max(1, Math.hypot(b.x - a.x, b.y - a.y));
	var mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
	var scale = Math.max(0.02, Math.min(16, markerPinch.scale * (distance / markerPinch.distance)));
	// the pinch midpoint drags the document, its spread scales it
	var now_x = mid.x - rect.left, now_y = mid.y - rect.top;
	var was_x = markerPinch.mid.x - rect.left, was_y = markerPinch.mid.y - rect.top;
	markerView.scale = scale;
	markerView.x = now_x - (was_x - markerPinch.x) * (scale / markerPinch.scale);
	markerView.y = now_y - (was_y - markerPinch.y) * (scale / markerPinch.scale);
	markerViewClamp();
	markerViewChanged();
	markerComposeSoon();
}

// a second finger means a gesture, not a stroke - put the pixels back
function markerCancelStroke() {
	if (!markerStroke.drawing) { return; }
	var before = markerStroke.before;
	markerStroke.drawing = false;
	markerStroke.before = undefined;
	markerStroke.line_from = undefined;
	markerStroke.line_to = undefined;
	markerPreview = undefined;
	if (markerStroke.spraying) { cancelAnimationFrame(markerStroke.spraying); markerStroke.spraying = false; }
	if (before && before.copy) {
		var layer = markerLayerByUuid(before.uuid);
		if (layer) {
			layer.ctx.save();
			layer.ctx.setTransform(1, 0, 0, 1, 0, 0);
			layer.ctx.clearRect(0, 0, layer.canvas.width, layer.canvas.height);
			layer.ctx.drawImage(before.copy, 0, 0);
			layer.ctx.restore();
		}
	}
	markerCompose();
}

// ---- history -----------------------------------------------------------

function markerHistoryClear() {
	markerHistory = [];
	markerRedo = [];
}

function markerHistoryPush(record) {
	if (!record) { return; }
	// an undo record is exactly "these pixels changed": the session upload
	// re-encodes the layers it names and reuses the PNG of the rest, which is
	// what keeps autosave off the tablet's CPU between strokes
	if (record.kind == 'rect' || record.kind == 'layer') {
		$.each(record.layers || [], function(i, snapshot) { markerLayerDirty(snapshot.uuid); });
	}
	markerHistory.push(record);
	if (markerHistory.length > markerHistoryLimit) { markerHistory.shift(); }
	markerRedo = [];
}

// a layer whose pixels changed needs re-encoding before the next save
function markerLayerDirty(uuid) {
	var layer = markerLayerByUuid(uuid);
	if (layer) { layer.sessionDirty = true; }
}

function markerLayerEncoded(layer) {
	if (layer.encoded && !layer.sessionDirty) { return layer.encoded; }
	layer.encoded = layer.canvas.toDataURL('image/png');
	layer.sessionDirty = false;
	return layer.encoded;
}

// structural changes (add/delete/reorder/show-hide) only need the layer
// objects plus their order, names and visibility - the pixels stay where they
// are, including for layers that are temporarily removed
function markerStructureRecord() {
	var structure = [];
	$.each(markerLayers, function(i, layer) {
		structure.push({ layer: layer, name: layer.name, visible: layer.visible });
	});
	return { kind: 'doc', structure: structure, active: markerLayerActive };
}

function markerApplyStructure(record) {
	markerLayers = [];
	$.each(record.structure, function(i, entry) {
		entry.layer.name = entry.name;
		entry.layer.visible = entry.visible;
		markerLayers.push(entry.layer);
	});
	markerLayerActive = Math.min(record.active, markerLayers.length - 1);
	if (markerLayerActive < 0) { markerLayerActive = 0; }
}

// A paint action remembers the pixels it covered. Copying the layer with
// drawImage is a GPU copy; reading it back with getImageData is not, and it
// used to happen on every stroke down. The copy is kept on a scratch canvas and
// only the dirty rectangle is read back, once, when the stroke ends.
function markerSnapshotCanvas(width, height) {
	if (!markerScratchCanvas) { markerScratchCanvas = document.createElement('canvas'); }
	if (markerScratchCanvas.width != width || markerScratchCanvas.height != height) {
		markerScratchCanvas.width = width;
		markerScratchCanvas.height = height;
	}
	return markerScratchCanvas;
}

function markerSnapshotStart() {
	var layer = markerActiveLayer();
	if (!layer) { return; }
	var copy = markerSnapshotCanvas(layer.canvas.width, layer.canvas.height);
	var ctx = copy.getContext('2d');
	ctx.setTransform(1, 0, 0, 1, 0, 0);
	ctx.globalAlpha = 1;
	ctx.globalCompositeOperation = 'source-over';
	ctx.clearRect(0, 0, copy.width, copy.height);
	ctx.drawImage(layer.canvas, 0, 0);
	markerStroke.before = {
		uuid: layer.uuid,
		copy: copy,
		width: layer.canvas.width,
		height: layer.canvas.height,
		rect: undefined
	};
}

function markerSnapshotDirty(x, y, w, h) {
	var before = markerStroke.before;
	if (!before) { return; }
	var rect = before.rect || { x0: x, y0: y, x1: x + w, y1: y + h };
	rect.x0 = Math.min(rect.x0, x);
	rect.y0 = Math.min(rect.y0, y);
	rect.x1 = Math.max(rect.x1, x + w);
	rect.y1 = Math.max(rect.y1, y + h);
	before.rect = rect;
}

function markerSnapshotCommit() {
	var before = markerStroke.before;
	markerStroke.before = undefined;
	if (!before || !before.rect) { return; }
	if (!markerLayerByUuid(before.uuid)) { return; }
	var rect = before.rect;
	var x = Math.max(0, Math.floor(rect.x0));
	var y = Math.max(0, Math.floor(rect.y0));
	var w = Math.min(before.width - x, Math.ceil(rect.x1) - x);
	var h = Math.min(before.height - y, Math.ceil(rect.y1) - y);
	if (w <= 0 || h <= 0) { return; }
	markerHistoryPush({
		kind: 'rect',
		layers: [{ uuid: before.uuid, x: x, y: y, w: w, h: h, data: before.copy.getContext('2d').getImageData(x, y, w, h) }]
	});
}

// whole-layer history, for actions that can touch anywhere (loading a paper,
// dropping an image or a canvas in)
function markerHistoryWholeLayer() {
	var layer = markerActiveLayer();
	if (!layer) { return; }
	markerHistoryPush({
		kind: 'rect',
		layers: [{
			uuid: layer.uuid,
			x: 0,
			y: 0,
			w: layer.canvas.width,
			h: layer.canvas.height,
			data: layer.ctx.getImageData(0, 0, layer.canvas.width, layer.canvas.height)
		}]
	});
}

// apply a record and hand back the record that would undo this application
function markerApplyRecord(record) {
	if (record.kind == 'layer') {
		// a transform record carries the canvas size with the pixels, so undo
		// gives a rotated or cropped layer its old shape back
		var inverse = [];
		$.each(record.layers, function(i, snapshot) {
			var layer = markerLayerByUuid(snapshot.uuid);
			if (!layer) { return; }
			inverse.push({
				uuid: snapshot.uuid,
				width: layer.canvas.width,
				height: layer.canvas.height,
				data: layer.ctx.getImageData(0, 0, layer.canvas.width, layer.canvas.height)
			});
			layer.canvas.width = snapshot.width;
			layer.canvas.height = snapshot.height;
			layer.ctx.putImageData(snapshot.data, 0, 0);
			markerLayerDirty(snapshot.uuid);
		});
		if (inverse.length == 0) { return undefined; }
		return { kind: 'layer', layers: inverse };
	}
	if (record.kind == 'rect') {
		var inverse = [];
		$.each(record.layers, function(i, crop) {
			var layer = markerLayerByUuid(crop.uuid);
			if (!layer) { return; }
			var current = layer.ctx.getImageData(crop.x, crop.y, crop.w, crop.h);
			layer.ctx.putImageData(crop.data, crop.x, crop.y);
			markerLayerDirty(crop.uuid);
			inverse.push({ uuid: crop.uuid, x: crop.x, y: crop.y, w: crop.w, h: crop.h, data: current });
		});
		if (inverse.length == 0) { return undefined; }
		return { kind: 'rect', layers: inverse };
	}
	var current = markerStructureRecord();
	markerApplyStructure(record);
	return current;
}

function markerUndo() {
	var record = markerHistory.pop();
	if (!record) { return; }
	var inverse = markerApplyRecord(record);
	if (inverse) { markerRedo.push(inverse); }
	markerLayerList();
	markerViewClamp();
	markerCompose();
}

function markerRedoStep() {
	var record = markerRedo.pop();
	if (!record) { return; }
	var inverse = markerApplyRecord(record);
	if (inverse) { markerHistory.push(inverse); }
	markerLayerList();
	markerViewClamp();
	markerCompose();
}

// ---- sessions ----------------------------------------------------------

function markerApp() {
	var app = $('#whiteboard').closest('.wind').attr('app');
	if (!app) { app = topWindow('marker'); }
	return app || 'marker';
}

function markerWorkingUuid() {
	return 'working_' + markerApp();
}

function markerSessionSave() {
	var canvas = document.getElementById('whiteboard');
	if (!canvas || markerLayers.length == 0) { return; }
	jawnosPrompt('Session name', markerSessionName || ('Session ' + new Date().toLocaleString()), function (name) {
		if (!name) { return; }
		markerSessionName = name;
		markerSessionUpload({
			name: name,
			session_uuid: markerSessionUuid,
			origin_uuid: markerSessionUuid,
			origin_name: name
		});
	});
}

var markerSessionUploadInFlight = false;
var markerSessionUploadWaiting = null;

function markerSessionUpload(options) {
	// one multi-megabyte save at a time: a second save waits its turn rather
	// than posting the same board alongside the first, and what it says is the
	// newest art, because it builds its layers when it finally leaves
	if (markerSessionUploadInFlight) {
		// a named save is never forgotten for an autosave queuing behind it
		if (!options.silent || !markerSessionUploadWaiting) { markerSessionUploadWaiting = options; }
		return;
	}
	var layers = [];
	$.each(markerLayers, function(i, layer) {
		// only the layers a stroke touched are encoded again; an unchanged layer
		// hands back the PNG it made last time
		layers.push({ name: layer.name, visible: layer.visible, image: markerLayerEncoded(layer) });
	});
	var thumb = document.createElement('canvas');
	thumb.width = 96;
	thumb.height = 64;
	thumb.getContext('2d').drawImage(markerFlatten(), 0, 0, thumb.width, thumb.height);
	var payload = JSON.stringify(layers);
	// the server drops request bodies over MOJO_MAX_MESSAGE_SIZE (16MB) without
	// a useful error, so fail loudly here rather than silently losing the art
	if (payload.length > 12000000) {
		if (options.silent) { say_it('drawing too big to autosave!'); }
		else { jawnosAlertText('This drawing is too big to save as one session (' + Math.round(payload.length / 1048576) + 'MB). Try fewer or flatter layers.'); }
		return;
	}
	markerSessionUploadInFlight = true;
	$.ajax({
		url: '/manager/marker/session/save',
		type: 'POST',
		data: {
			app: markerApp(),
			name: options.name,
			session_uuid: options.session_uuid,
			working: options.working ? 1 : 0,
			origin_uuid: options.origin_uuid || '',
			origin_name: options.origin_name || '',
			layers: payload,
			thumbnail: thumb.toDataURL('image/png'),
			timestamp: Date.now()
		},
		success: function(response) {
			if (options.silent) { return; }
			if (response && response.uuid) { markerSessionUuid = response.uuid; }
			markerSessionPanel(response ? response.sessions : undefined);
			say_it('session saved!');
			// let the working copy remember which named session it came from
			markerAutosaveDirty = true;
			markerAutosaveNow();
		},
		complete: function() {
			markerSessionUploadInFlight = false;
			if (markerSessionUploadWaiting) {
				var next = markerSessionUploadWaiting;
				markerSessionUploadWaiting = null;
				markerSessionUpload(next);
			}
		}
	});
}

function markerSessionApply(layers) {
	markerLayers = layers;
	markerLayerActive = layers.length - 1;
	markerHistoryClear();
	markerLastPoint = undefined;
	markerPreview = undefined;
	markerSessionLoading = false;
	markerAutosaveDirty = false;
	var canvas = document.getElementById('whiteboard');
	var size = markerDocSize();
	// a session is drawn on a sheet, and the sheet it was drawn on is the one it
	// comes back on
	if (size.w && size.h) { markerDocRemember(markerSessionName || '', size.w, size.h); }
	// a session drawn on a bigger screen than this one gets fitted to view
	if (canvas && (size.w != canvas.width || size.h != canvas.height)) { markerViewFit(); }
	else { markerViewReset(); }
	markerLayerList();
	markerCompose();
	markerStageRefresh();
}

function markerSessionLoad(session_uuid, options) {
	options = options || {};
	markerSessionLoading = true;
	$.ajax({
		url: '/manager/marker/session/load',
		type: 'GET',
		data: { session_uuid: session_uuid },
		success: function(session) {
			if (!session || !session.layers || session.layers.length == 0) { markerSessionLoading = false; return; }
			var canvas = document.getElementById('whiteboard');
			if (!canvas || !whiteboard_ctx) { markerSessionLoading = false; return; }
			if (options.working) {
				// a working copy is not a session of its own: remember where it was
				// saved from, so the Session button still updates that session
				markerSessionUuid = session.origin_uuid || undefined;
				markerSessionName = session.origin_name || session.name;
			}
			else {
				markerSessionUuid = session.uuid || session_uuid;
				markerSessionName = session.name;
			}
			var pending = session.layers.length;
			var built = [];
			var done = function() {
				pending--;
				if (pending <= 0) {
					// an automatic restore must not wipe strokes made while it was
					// still loading
					if (options.auto && markerHistory.length > 0) { markerSessionLoading = false; return; }
					markerSessionApply(built);
				}
			};
			$.each(session.layers, function(i, l) {
				var layer = markerNewLayer(l.name);
				layer.visible = l.visible != false;
				built.push(layer);
				var image = new Image();
				image.onload = function() {
					// the document keeps the size it was drawn at, whatever screen
					// it is being loaded on
					layer.canvas.width = image.naturalWidth || canvas.width;
					layer.canvas.height = image.naturalHeight || canvas.height;
					layer.ctx.drawImage(image, 0, 0);
					done();
				};
				image.onerror = done;
				image.src = l.image;
			});
		}
	});
}

// reopen the board in progress, so nothing painted is lost to a refresh -
// the working copy first, then the newest named session. Nothing is restored
// if the board already has work on it.
function markerSessionRestoreLast() {
	if (markerSessionRestored) { return; }
	if (markerHistory.length > 0) { return; }
	markerSessionRestored = true;
	var working = markerWorkingUuid();
	$.ajax({
		url: '/manager/marker/session/load',
		type: 'GET',
		data: { session_uuid: working },
		success: function(session) {
			if (session && session.layers && session.layers.length > 0) {
				markerSessionLoad(working, { working: true, auto: true });
				return;
			}
			$.ajax({
				url: '/manager/marker/session/list',
				type: 'GET',
				data: { app: markerApp() },
				success: function(response) {
					if (response && response.sessions && response.sessions.length > 0) {
						markerSessionLoad(response.sessions[0].uuid, { auto: true });
					}
				}
			});
		}
	});
}

