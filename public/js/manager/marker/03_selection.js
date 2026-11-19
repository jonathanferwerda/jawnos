// ---- selection, move, clipboard and effects -----------------------------
// A selection is a document-sized alpha mask plus the outline the marching
// ants follow. A rectangle and a lasso therefore share one code path: the
// mask says which pixels are in, the outline only says how to draw the edge.
// The pixels themselves never leave their layer until the selection is moved:
// a move lifts them onto a floating canvas, drawn as a preview on the overlay,
// and drops them back on release. Clipboard and effects work through the same
// mask.

var markerSelection = {
	active: false,
	tool: 'rect',
	bounds: { x: 0, y: 0, w: 0, h: 0 },
	mask: undefined,
	mask_ctx: undefined,
	outline: undefined,
	floating: undefined,
	drag: undefined,
	preview: undefined
};

var markerSelectionOverlay = { canvas: undefined, ctx: undefined, width: 0, height: 0 };
var markerSelectionAntsPhase = 0;
var markerSelectionAntsFrame = undefined;
// the in-page clipboard: a canvas, so copy and paste never need a permission
var markerClip;
var markerClipMask;
var markerClipOutline;

// ---- small lookups -----------------------------------------------------

function markerSelectionTool() {
	if (typeof localStorage === 'undefined') { return ''; }
	var tool = localStorage.getItem('marker_tool');
	if (tool == 'select' || tool == 'lasso' || tool == 'move') { return tool; }
	return '';
}

function markerSelectionDocument() {
	if (typeof markerLayers === 'undefined' || !markerLayers.length) { return undefined; }
	if (typeof markerDocSize !== 'function') { return undefined; }
	var size = markerDocSize();
	if (!size || !size.w || !size.h) { return undefined; }
	return size;
}

function markerSelectionLayer() {
	if (typeof markerActiveLayer !== 'function') { return undefined; }
	var layer = markerActiveLayer();
	if (!layer || !layer.canvas || !layer.canvas.width || !layer.canvas.height) { return undefined; }
	return layer;
}

function markerSelectionClamp(value, low, high) {
	if (value < low) { return low; }
	if (value > high) { return high; }
	return value;
}

// ---- the overlay -------------------------------------------------------

// 04_stage.js resizes the overlay canvas before calling this, so the cache is
// refreshed here and the ants are repainted for the new size
function markerSelectionOverlaySize() {
	var canvas = document.getElementById('marker_selection_overlay');
	if (!canvas) {
		markerSelectionOverlay.canvas = undefined;
		markerSelectionOverlay.ctx = undefined;
		markerSelectionOverlay.width = 0;
		markerSelectionOverlay.height = 0;
		return;
	}
	markerSelectionOverlay.canvas = canvas;
	markerSelectionOverlay.ctx = canvas.getContext('2d');
	markerSelectionOverlay.width = canvas.width;
	markerSelectionOverlay.height = canvas.height;
	markerSelectionRedraw();
}

function markerSelectionStageVisible() {
	if (document.hidden) { return false; }
	if (typeof $ === 'undefined') { return false; }
	var canvas = $('#whiteboard');
	return canvas.length > 0 && canvas.is(':visible');
}

// the ants only march around a real selection; a drag's preview is repainted
// from the pointer events themselves
function markerSelectionAntsWanted() {
	return markerSelection.active ? true : false;
}

function markerSelectionAntsStart() {
	if (markerSelectionAntsFrame) { return; }
	if (!markerSelectionAntsWanted()) { return; }
	markerSelectionAntsFrame = requestAnimationFrame(markerSelectionAntsTick);
}

function markerSelectionAntsStop() {
	if (markerSelectionAntsFrame) { cancelAnimationFrame(markerSelectionAntsFrame); }
	markerSelectionAntsFrame = undefined;
}

// the loop exists only while there is a selection to march around, and it
// parks itself while the Marker window is hidden - the next redraw or
// visibility change starts it again when the window comes back
function markerSelectionAntsTick() {
	markerSelectionAntsFrame = undefined;
	if (!markerSelectionAntsWanted()) { return; }
	if (!markerSelectionStageVisible()) { return; }
	markerSelectionAntsPhase = (markerSelectionAntsPhase + 1) % 8;
	// schedule before painting: a redraw asks for the loop, and the frame it
	// would otherwise start here would be a second, duplicate one
	markerSelectionAntsFrame = requestAnimationFrame(markerSelectionAntsTick);
	markerSelectionRedraw();
}

// a document path in screen coordinates, through the same view the layers use
function markerSelectionScreenPath(ctx) {
	var outline = markerSelection.outline;
	var bounds = markerSelection.bounds;
	ctx.beginPath();
	if (outline && outline.type == 'poly' && outline.points && outline.points.length > 1) {
		for (var i = 0; i < outline.points.length; i++) {
			var point = markerDocToScreen(outline.points[i].x, outline.points[i].y);
			if (i == 0) { ctx.moveTo(point.x, point.y); }
			else { ctx.lineTo(point.x, point.y); }
		}
		ctx.closePath();
		return true;
	}
	if (!bounds.w || !bounds.h) { return false; }
	var from = markerDocToScreen(bounds.x, bounds.y);
	var to = markerDocToScreen(bounds.x + bounds.w, bounds.y + bounds.h);
	ctx.rect(from.x, from.y, to.x - from.x, to.y - from.y);
	return true;
}

function markerSelectionPreviewPath(ctx) {
	var preview = markerSelection.preview;
	if (!preview) { return false; }
	ctx.beginPath();
	if (preview.type == 'poly' && preview.points && preview.points.length > 1) {
		for (var i = 0; i < preview.points.length; i++) {
			var point = markerDocToScreen(preview.points[i].x, preview.points[i].y);
			if (i == 0) { ctx.moveTo(point.x, point.y); }
			else { ctx.lineTo(point.x, point.y); }
		}
		return true;
	}
	var from = markerDocToScreen(preview.x, preview.y);
	var to = markerDocToScreen(preview.x + preview.w, preview.y + preview.h);
	ctx.rect(from.x, from.y, to.x - from.x, to.y - from.y);
	return true;
}

// white under a black dash so the ants read on paper and on dark art alike
function markerSelectionAntsStroke(ctx) {
	ctx.save();
	ctx.lineWidth = 1;
	ctx.strokeStyle = 'rgba(255,255,255,0.9)';
	ctx.setLineDash([]);
	ctx.stroke();
	ctx.strokeStyle = 'rgba(0,0,0,0.9)';
	ctx.setLineDash([4, 4]);
	ctx.lineDashOffset = -markerSelectionAntsPhase;
	ctx.stroke();
	ctx.restore();
}

function markerSelectionFloatingDraw(ctx) {
	var floating = markerSelection.floating;
	if (!floating || typeof markerView === 'undefined') { return; }
	ctx.save();
	ctx.setTransform(markerView.scale, 0, 0, markerView.scale, markerView.x, markerView.y);
	ctx.drawImage(floating.canvas, floating.x, floating.y);
	ctx.restore();
}

function markerSelectionRedraw() {
	var canvas = document.getElementById('marker_selection_overlay');
	if (!canvas) { return; }
	var ctx = canvas.getContext('2d');
	markerSelectionOverlay.canvas = canvas;
	markerSelectionOverlay.ctx = ctx;
	markerSelectionOverlay.width = canvas.width;
	markerSelectionOverlay.height = canvas.height;
	ctx.setTransform(1, 0, 0, 1, 0, 0);
	ctx.globalAlpha = 1;
	ctx.globalCompositeOperation = 'source-over';
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	markerSelectionFloatingDraw(ctx);
	ctx.setTransform(1, 0, 0, 1, 0, 0);
	if (markerSelection.drag && markerSelection.preview) {
		if (markerSelectionPreviewPath(ctx)) { markerSelectionAntsStroke(ctx); }
	}
	else if (markerSelection.active && markerSelectionScreenPath(ctx)) {
		markerSelectionAntsStroke(ctx);
	}
	// a window that was hidden when the selection was made (or when the ants
	// parked) gets its loop back as soon as anything repaints the overlay
	if (markerSelectionAntsWanted() && markerSelectionStageVisible()) { markerSelectionAntsStart(); }
}

// ---- geometry and the mask --------------------------------------------

function markerSelectionRectOf(from, to, size) {
	var x0 = markerSelectionClamp(Math.min(from.x, to.x), 0, size.w);
	var y0 = markerSelectionClamp(Math.min(from.y, to.y), 0, size.h);
	var x1 = markerSelectionClamp(Math.max(from.x, to.x), 0, size.w);
	var y1 = markerSelectionClamp(Math.max(from.y, to.y), 0, size.h);
	var x = Math.floor(x0);
	var y = Math.floor(y0);
	var w = Math.ceil(x1) - x;
	var h = Math.ceil(y1) - y;
	if (w > size.w - x) { w = size.w - x; }
	if (h > size.h - y) { h = size.h - y; }
	if (w < 0) { w = 0; }
	if (h < 0) { h = 0; }
	return { x: x, y: y, w: w, h: h };
}

function markerSelectionBoundsOf(points) {
	var size = markerSelectionDocument();
	if (!size || !points || !points.length) { return undefined; }
	var min_x = points[0].x, min_y = points[0].y;
	var max_x = points[0].x, max_y = points[0].y;
	for (var i = 1; i < points.length; i++) {
		if (points[i].x < min_x) { min_x = points[i].x; }
		if (points[i].y < min_y) { min_y = points[i].y; }
		if (points[i].x > max_x) { max_x = points[i].x; }
		if (points[i].y > max_y) { max_y = points[i].y; }
	}
	min_x = markerSelectionClamp(min_x, 0, size.w);
	min_y = markerSelectionClamp(min_y, 0, size.h);
	max_x = markerSelectionClamp(max_x, 0, size.w);
	max_y = markerSelectionClamp(max_y, 0, size.h);
	var x = Math.floor(min_x);
	var y = Math.floor(min_y);
	var w = Math.ceil(max_x) - x;
	var h = Math.ceil(max_y) - y;
	if (w > size.w - x) { w = size.w - x; }
	if (h > size.h - y) { h = size.h - y; }
	if (w < 1 || h < 1) { return undefined; }
	return { x: x, y: y, w: w, h: h };
}

function markerSelectionMaskMake(size) {
	var mask = document.createElement('canvas');
	mask.width = Math.max(1, Math.round(size.w));
	mask.height = Math.max(1, Math.round(size.h));
	return mask;
}

function markerSelectionMaskFillRect(rect) {
	var size = markerSelectionDocument();
	if (!size) { return false; }
	var mask = markerSelectionMaskMake(size);
	var ctx = mask.getContext('2d');
	ctx.fillStyle = '#ffffff';
	ctx.fillRect(rect.x, rect.y, rect.w, rect.h);
	markerSelection.mask = mask;
	markerSelection.mask_ctx = ctx;
	return true;
}

function markerSelectionMaskFillPoly(points) {
	var size = markerSelectionDocument();
	if (!size) { return false; }
	var mask = markerSelectionMaskMake(size);
	var ctx = mask.getContext('2d');
	ctx.beginPath();
	for (var i = 0; i < points.length; i++) {
		if (i == 0) { ctx.moveTo(points[i].x, points[i].y); }
		else { ctx.lineTo(points[i].x, points[i].y); }
	}
	ctx.closePath();
	ctx.fillStyle = '#ffffff';
	ctx.fill();
	markerSelection.mask = mask;
	markerSelection.mask_ctx = ctx;
	return true;
}

function markerSelectionUseRect(rect) {
	if (!rect || rect.w < 1 || rect.h < 1) { return false; }
	if (!markerSelectionMaskFillRect(rect)) { return false; }
	markerSelection.active = true;
	markerSelection.tool = 'rect';
	markerSelection.bounds = { x: rect.x, y: rect.y, w: rect.w, h: rect.h };
	markerSelection.outline = { type: 'rect' };
	markerSelection.floating = undefined;
	markerSelection.drag = undefined;
	markerSelection.preview = undefined;
	markerSelectionAntsStart();
	markerSelectionRedraw();
	return true;
}

function markerSelectionUseLasso(points) {
	if (!points || points.length < 3) { return false; }
	var bounds = markerSelectionBoundsOf(points);
	if (!bounds) { return false; }
	if (!markerSelectionMaskFillPoly(points)) { return false; }
	var kept = [];
	for (var i = 0; i < points.length; i++) {
		kept.push({ x: points[i].x, y: points[i].y });
	}
	markerSelection.active = true;
	markerSelection.tool = 'lasso';
	markerSelection.bounds = bounds;
	markerSelection.outline = { type: 'poly', points: kept };
	markerSelection.floating = undefined;
	markerSelection.drag = undefined;
	markerSelection.preview = undefined;
	markerSelectionAntsStart();
	markerSelectionRedraw();
	return true;
}

function markerSelectionMaskAlpha(x, y) {
	var mask = markerSelection.mask;
	if (!mask) { return 0; }
	if (x < 0 || y < 0 || x >= mask.width || y >= mask.height) { return 0; }
	var ctx = markerSelection.mask_ctx;
	if (!ctx) {
		ctx = mask.getContext('2d');
		markerSelection.mask_ctx = ctx;
	}
	return ctx.getImageData(x, y, 1, 1).data[3];
}

function markerSelectionInside(pos) {
	if (!markerSelection.active) { return false; }
	var bounds = markerSelection.bounds;
	if (pos.x < bounds.x || pos.y < bounds.y || pos.x > bounds.x + bounds.w || pos.y > bounds.y + bounds.h) { return false; }
	return markerSelectionMaskAlpha(Math.floor(pos.x), Math.floor(pos.y)) > 0;
}

// the selection's bounds intersected with a layer, in whole pixels
function markerSelectionClipRect(layer) {
	if (!layer) { layer = markerSelectionLayer(); }
	if (!layer) { return undefined; }
	var bounds = markerSelection.bounds;
	var x = Math.floor(bounds.x);
	var y = Math.floor(bounds.y);
	var right = Math.ceil(bounds.x + bounds.w);
	var bottom = Math.ceil(bounds.y + bounds.h);
	if (x < 0) { x = 0; }
	if (y < 0) { y = 0; }
	if (right > layer.canvas.width) { right = layer.canvas.width; }
	if (bottom > layer.canvas.height) { bottom = layer.canvas.height; }
	var w = right - x;
	var h = bottom - y;
	if (w < 1 || h < 1) { return undefined; }
	return { x: x, y: y, w: w, h: h };
}

function markerSelectionRectRecord(layer, rect) {
	return { kind: 'rect', layers: [{
		uuid: layer.uuid,
		x: rect.x,
		y: rect.y,
		w: rect.w,
		h: rect.h,
		data: layer.ctx.getImageData(rect.x, rect.y, rect.w, rect.h)
	}] };
}

function markerSelectionOutlineCopy(outline) {
	if (outline && outline.type == 'poly' && outline.points) {
		var points = [];
		for (var i = 0; i < outline.points.length; i++) {
			points.push({ x: outline.points[i].x, y: outline.points[i].y });
		}
		return { type: 'poly', points: points };
	}
	return { type: 'rect' };
}

function markerSelectionOutlineRelative(bounds) {
	var outline = markerSelection.outline;
	if (outline && outline.type == 'poly' && outline.points) {
		var points = [];
		for (var i = 0; i < outline.points.length; i++) {
			points.push({ x: outline.points[i].x - bounds.x, y: outline.points[i].y - bounds.y });
		}
		return { type: 'poly', points: points };
	}
	return { type: 'rect' };
}

function markerSelectionOutlineAt(outline, x, y) {
	if (outline && outline.type == 'poly' && outline.points) {
		var points = [];
		for (var i = 0; i < outline.points.length; i++) {
			points.push({ x: outline.points[i].x + x, y: outline.points[i].y + y });
		}
		return { type: 'poly', points: points };
	}
	return { type: 'rect' };
}

// the mask follows the floating pixels: redrawing the silhouette at its new
// place, rather than translating the old mask, keeps its edge from spreading
function markerSelectionMaskFromFloating() {
	var floating = markerSelection.floating;
	var size = markerSelectionDocument();
	if (!floating || !size) { return false; }
	var width = Math.max(1, Math.round(size.w));
	var height = Math.max(1, Math.round(size.h));
	var mask = markerSelection.mask;
	if (!mask || mask.width != width || mask.height != height) {
		mask = markerSelectionMaskMake(size);
		markerSelection.mask = mask;
		markerSelection.mask_ctx = mask.getContext('2d');
	}
	var ctx = markerSelection.mask_ctx;
	if (!ctx) {
		ctx = mask.getContext('2d');
		markerSelection.mask_ctx = ctx;
	}
	ctx.setTransform(1, 0, 0, 1, 0, 0);
	ctx.globalAlpha = 1;
	ctx.globalCompositeOperation = 'source-over';
	ctx.clearRect(0, 0, mask.width, mask.height);
	if (floating.mask) { ctx.drawImage(floating.mask, floating.x, floating.y); }
	return true;
}

function markerSelectionBoundsFromFloating(dx, dy) {
	var floating = markerSelection.floating;
	if (!floating) { return; }
	markerSelection.bounds = { x: floating.x, y: floating.y, w: floating.canvas.width, h: floating.canvas.height };
	var outline = markerSelection.outline;
	if (outline && outline.type == 'poly' && outline.points && dx != undefined) {
		var points = [];
		for (var i = 0; i < outline.points.length; i++) {
			points.push({ x: outline.points[i].x + dx, y: outline.points[i].y + dy });
		}
		markerSelection.outline = { type: 'poly', points: points };
	}
	markerSelectionMaskFromFloating();
}

// ---- lifting, dropping and the floating selection ----------------------

// the selected pixels leave the layer for a floating canvas; the record is
// made before they go so undo can put them back
function markerSelectionLift() {
	var layer = markerSelectionLayer();
	if (!layer || !markerSelection.active || !markerSelection.mask) { return false; }
	var clip = markerSelectionClipRect(layer);
	if (!clip) { return false; }
	var mask = markerSelection.mask;
	var floating = document.createElement('canvas');
	floating.width = clip.w;
	floating.height = clip.h;
	var ctx = floating.getContext('2d');
	ctx.drawImage(layer.canvas, clip.x, clip.y, clip.w, clip.h, 0, 0, clip.w, clip.h);
	ctx.globalCompositeOperation = 'destination-in';
	ctx.drawImage(mask, clip.x, clip.y, clip.w, clip.h, 0, 0, clip.w, clip.h);
	ctx.globalCompositeOperation = 'source-over';
	var silhouette = document.createElement('canvas');
	silhouette.width = clip.w;
	silhouette.height = clip.h;
	var sctx = silhouette.getContext('2d');
	sctx.drawImage(mask, clip.x, clip.y, clip.w, clip.h, 0, 0, clip.w, clip.h);
	markerHistoryPush(markerSelectionRectRecord(layer, clip));
	layer.ctx.save();
	layer.ctx.globalCompositeOperation = 'destination-out';
	layer.ctx.drawImage(mask, 0, 0);
	layer.ctx.restore();
	markerLayerDirty(layer.uuid);
	markerSelection.floating = {
		canvas: floating,
		ctx: ctx,
		mask: silhouette,
		mask_ctx: sctx,
		x: clip.x,
		y: clip.y,
		origin: { x: clip.x, y: clip.y },
		layer: layer.uuid,
		lifted: true
	};
	markerSelection.bounds = { x: clip.x, y: clip.y, w: clip.w, h: clip.h };
	markerSelection.outline = markerSelectionOutlineCopy(markerSelection.outline);
	markerCompose();
	// the float sits exactly where the hole is, so paint it now rather than
	// waiting for the next pointer move
	markerSelectionRedraw();
	return true;
}

// dropping the floating selection writes its pixels back into the layer it came
// from. A pasted float (or one dropped somewhere new) gets its own destination
// record, so undo can take those pixels away again.
function markerSelectionAnchor() {
	var floating = markerSelection.floating;
	if (!floating) { return false; }
	markerSelection.floating = undefined;
	var layer = markerLayerByUuid(floating.layer) || markerSelectionLayer();
	if (layer) {
		var x0 = Math.max(0, Math.floor(floating.x));
		var y0 = Math.max(0, Math.floor(floating.y));
		var x1 = Math.min(layer.canvas.width, Math.ceil(floating.x + floating.canvas.width));
		var y1 = Math.min(layer.canvas.height, Math.ceil(floating.y + floating.canvas.height));
		if (x1 > x0 && y1 > y0) {
			var origin = floating.origin;
			var moved = !floating.lifted || !origin || origin.x != floating.x || origin.y != floating.y;
			if (moved) {
				markerHistoryPush(markerSelectionRectRecord(layer, { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }));
			}
			layer.ctx.save();
			layer.ctx.globalCompositeOperation = 'source-over';
			layer.ctx.drawImage(floating.canvas, floating.x, floating.y);
			layer.ctx.restore();
			markerLayerDirty(layer.uuid);
		}
	}
	markerCompose();
	markerAutosaveSoon();
	markerSelectionAntsStart();
	markerSelectionRedraw();
	return true;
}

// ---- erase, copy, cut and paste ---------------------------------------

function markerSelectionErase() {
	if (!markerSelection.active || !markerSelection.mask) { return false; }
	if (markerSelection.floating) {
		// the pixels were already lifted off the layer; dropping the float is
		// the delete, and the lift's own record is what undo puts back
		markerSelection.floating = undefined;
		markerCompose();
		markerAutosaveSoon();
		markerSelectionRedraw();
		return true;
	}
	var layer = markerSelectionLayer();
	if (!layer) { return false; }
	var clip = markerSelectionClipRect(layer);
	if (!clip) { return false; }
	markerHistoryPush(markerSelectionRectRecord(layer, clip));
	layer.ctx.save();
	layer.ctx.globalCompositeOperation = 'destination-out';
	layer.ctx.drawImage(markerSelection.mask, 0, 0);
	layer.ctx.restore();
	markerLayerDirty(layer.uuid);
	markerCompose();
	markerAutosaveSoon();
	markerSelectionAntsStart();
	return true;
}

// copy always reads the masked pixels: from the floating canvas when a move is
// still in the air, otherwise from the active layer
function markerSelectionCopy() {
	if (!markerSelection.active || !markerSelection.mask) { return false; }
	var layer = markerSelectionLayer();
	if (!layer) { return false; }
	var floating = markerSelection.floating;
	var bounds;
	if (floating) {
		bounds = { x: floating.x, y: floating.y, w: floating.canvas.width, h: floating.canvas.height };
	}
	else {
		bounds = markerSelectionClipRect(layer);
		if (!bounds) { return false; }
	}
	var canvas = document.createElement('canvas');
	canvas.width = bounds.w;
	canvas.height = bounds.h;
	var ctx = canvas.getContext('2d');
	if (floating) {
		ctx.drawImage(floating.canvas, 0, 0);
	}
	else {
		ctx.drawImage(layer.canvas, bounds.x, bounds.y, bounds.w, bounds.h, 0, 0, bounds.w, bounds.h);
		ctx.globalCompositeOperation = 'destination-in';
		ctx.drawImage(markerSelection.mask, bounds.x, bounds.y, bounds.w, bounds.h, 0, 0, bounds.w, bounds.h);
		ctx.globalCompositeOperation = 'source-over';
	}
	var silhouette = document.createElement('canvas');
	silhouette.width = bounds.w;
	silhouette.height = bounds.h;
	var sctx = silhouette.getContext('2d');
	if (floating) {
		if (floating.mask) { sctx.drawImage(floating.mask, 0, 0); }
	}
	else {
		sctx.drawImage(markerSelection.mask, bounds.x, bounds.y, bounds.w, bounds.h, 0, 0, bounds.w, bounds.h);
	}
	markerClip = canvas;
	markerClipMask = silhouette;
	markerClipOutline = markerSelectionOutlineRelative(bounds);
	return true;
}

function markerSelectionCut() {
	if (!markerSelection.active) { return false; }
	if (!markerSelectionCopy()) { return false; }
	return markerSelectionErase();
}

function markerSelectionPaste() {
	if (!markerClip || !markerClip.width || !markerClip.height) { return false; }
	var layer = markerSelectionLayer();
	if (!layer || !markerSelectionDocument()) { return false; }
	// a second paste anchors the first float and pastes the same copy again
	if (markerSelection.floating) { markerSelectionAnchor(); }
	var x = markerSelection.active ? Math.round(markerSelection.bounds.x) : 0;
	var y = markerSelection.active ? Math.round(markerSelection.bounds.y) : 0;
	var canvas = document.createElement('canvas');
	canvas.width = markerClip.width;
	canvas.height = markerClip.height;
	var ctx = canvas.getContext('2d');
	ctx.drawImage(markerClip, 0, 0);
	var silhouette = document.createElement('canvas');
	silhouette.width = markerClip.width;
	silhouette.height = markerClip.height;
	var sctx = silhouette.getContext('2d');
	if (markerClipMask) { sctx.drawImage(markerClipMask, 0, 0); }
	else {
		sctx.fillStyle = '#ffffff';
		sctx.fillRect(0, 0, silhouette.width, silhouette.height);
	}
	markerSelection.active = true;
	markerSelection.tool = (markerClipOutline && markerClipOutline.type == 'poly') ? 'lasso' : 'rect';
	markerSelection.bounds = { x: x, y: y, w: canvas.width, h: canvas.height };
	markerSelection.outline = markerSelectionOutlineAt(markerClipOutline, x, y);
	markerSelection.drag = undefined;
	markerSelection.preview = undefined;
	markerSelection.floating = {
		canvas: canvas,
		ctx: ctx,
		mask: silhouette,
		mask_ctx: sctx,
		x: x,
		y: y,
		layer: layer.uuid,
		lifted: false
	};
	markerSelectionMaskFromFloating();
	markerSelectionAntsStart();
	markerSelectionRedraw();
	return true;
}

// ---- effects ----------------------------------------------------------

// the filter runs on a temporary layer holding only the selected pixels, then
// the result is laid back down inside the same mask. Building a layer-shaped
// temporary keeps blur and sharpen's neighbourhoods the size they expect.
function markerSelectionEffect(duty, value) {
	if (!duty) { return false; }
	if (!markerSelection.active || !markerSelection.mask) { return false; }
	var layer = markerSelectionLayer();
	if (!layer) { return false; }
	// work on the layer, not a transient float, so the effect can be undone
	if (markerSelection.floating) { markerSelectionAnchor(); }
	var clip = markerSelectionClipRect(layer);
	if (!clip) { return false; }
	var temp = document.createElement('canvas');
	temp.width = layer.canvas.width;
	temp.height = layer.canvas.height;
	var tctx = temp.getContext('2d');
	tctx.drawImage(layer.canvas, 0, 0);
	tctx.globalCompositeOperation = 'destination-in';
	tctx.drawImage(markerSelection.mask, 0, 0);
	var temp_layer = { canvas: temp, ctx: tctx };
	var record = markerSelectionRectRecord(layer, clip);
	if (!markerLayerFilter(temp_layer, duty, value)) { return false; }
	markerHistoryPush(record);
	layer.ctx.save();
	layer.ctx.globalCompositeOperation = 'destination-out';
	layer.ctx.drawImage(markerSelection.mask, 0, 0);
	layer.ctx.globalCompositeOperation = 'source-over';
	layer.ctx.drawImage(temp, 0, 0);
	layer.ctx.restore();
	markerLayerDirty(layer.uuid);
	markerLayerList();
	markerCompose();
	markerAutosaveSoon();
	return true;
}

// ---- whole-document selection and the rest of the state ----------------

function markerSelectionAll() {
	var size = markerSelectionDocument();
	if (!size) { return false; }
	if (markerSelection.floating) { markerSelectionAnchor(); }
	if (!markerSelectionMaskFillRect({ x: 0, y: 0, w: size.w, h: size.h })) { return false; }
	markerSelection.active = true;
	markerSelection.tool = 'rect';
	markerSelection.bounds = { x: 0, y: 0, w: size.w, h: size.h };
	markerSelection.outline = { type: 'rect' };
	markerSelection.floating = undefined;
	markerSelection.drag = undefined;
	markerSelection.preview = undefined;
	markerSelectionAntsStart();
	markerSelectionRedraw();
	return true;
}

function markerSelectionClear() {
	markerSelection.active = false;
	markerSelection.floating = undefined;
	markerSelection.mask = undefined;
	markerSelection.mask_ctx = undefined;
	markerSelection.outline = undefined;
	markerSelection.bounds = { x: 0, y: 0, w: 0, h: 0 };
	markerSelection.drag = undefined;
	markerSelection.preview = undefined;
	markerSelectionAntsStop();
	markerSelectionRedraw();
}

function markerSelectionNone() {
	if (markerSelection.floating) { markerSelectionAnchor(); }
	if (!markerSelection.active) {
		markerSelectionRedraw();
		return false;
	}
	markerSelectionClear();
	return true;
}

// a brand new window or a brand new sheet forgets the old selection entirely
function markerSelectionReset() {
	markerSelection.floating = undefined;
	markerSelectionClear();
	markerSelectionOverlaySize();
}

// a new sheet or a new layer stack makes the old mask meaningless
function markerSelectionSync() {
	if (!markerSelection.active) { return true; }
	var size = markerSelectionDocument();
	var mask = markerSelection.mask;
	if (!size || !mask || mask.width != Math.round(size.w) || mask.height != Math.round(size.h)) {
		markerSelectionClear();
		return false;
	}
	var floating = markerSelection.floating;
	if (floating && !markerLayerByUuid(floating.layer)) {
		markerSelection.floating = undefined;
		markerSelectionRedraw();
	}
	return true;
}

// arrows carry an airborne float (a paste, or a selection lifted by a drag)
// without touching the layer, so nothing is committed until it is dropped
function markerSelectionNudge(dx, dy) {
	if (!dx && !dy) { return false; }
	if (markerSelectionTool() != 'move') { return false; }
	if (!markerSelection.active || !markerSelection.floating) { return false; }
	var floating = markerSelection.floating;
	floating.x += dx;
	floating.y += dy;
	markerSelectionBoundsFromFloating(dx, dy);
	markerSelectionAntsStart();
	markerSelectionRedraw();
	return true;
}

// ---- pointer seams ----------------------------------------------------

function markerSelectionMoveDown(pos) {
	if (!markerSelection.active || !markerSelection.mask) { return true; }
	if (!markerSelectionInside(pos)) { return true; }
	if (!markerSelection.floating) {
		if (!markerSelectionLift()) { return true; }
	}
	var floating = markerSelection.floating;
	markerSelection.drag = {
		type: 'move',
		offset: { x: pos.x - floating.x, y: pos.y - floating.y }
	};
	// pointer moves only reach the brush while a stroke is in progress, so the
	// selection borrows that flag and lets go of it on pointer up
	markerStroke.drawing = true;
	markerSelectionAntsStart();
	return true;
}

function markerSelectionPointerDown(pos, straight_line) {
	var tool = markerSelectionTool();
	if (!tool) { return false; }
	// a stale mask means a new sheet or layer stack; drop it before anything
	// reads it, even if there is nothing to select on any more
	markerSelectionSync();
	// a selection tool owns the pointer even when there is nothing to select on
	if (!markerSelectionDocument() || !markerSelectionLayer()) { return true; }
	if (tool == 'move') { return markerSelectionMoveDown(pos); }
	// a new selection replaces whatever was there, so a float is anchored first
	if (markerSelection.floating) { markerSelectionAnchor(); }
	markerSelectionClear();
	var size = markerSelectionDocument();
	if (!size) { return true; }
	var point = {
		x: markerSelectionClamp(pos.x, 0, size.w),
		y: markerSelectionClamp(pos.y, 0, size.h)
	};
	markerSelection.drag = {
		type: (tool == 'lasso' ? 'poly' : 'rect'),
		start: point,
		last: point,
		points: [point]
	};
	markerSelection.preview = {
		type: markerSelection.drag.type,
		x: point.x,
		y: point.y,
		w: 0,
		h: 0,
		points: markerSelection.drag.points
	};
	markerStroke.drawing = true;
	markerSelectionRedraw();
	return true;
}

function markerSelectionPointerMove(pos) {
	var drag = markerSelection.drag;
	if (!drag) { return false; }
	var size = markerSelectionDocument();
	if (!size) { return true; }
	if (drag.type == 'move') {
		var floating = markerSelection.floating;
		if (!floating) { return true; }
		var x = Math.round(pos.x - drag.offset.x);
		var y = Math.round(pos.y - drag.offset.y);
		if (x == floating.x && y == floating.y) { return true; }
		var dx = x - floating.x;
		var dy = y - floating.y;
		floating.x = x;
		floating.y = y;
		markerSelectionBoundsFromFloating(dx, dy);
		markerSelectionRedraw();
		return true;
	}
	var point = {
		x: markerSelectionClamp(pos.x, 0, size.w),
		y: markerSelectionClamp(pos.y, 0, size.h)
	};
	drag.last = point;
	if (drag.type == 'poly') {
		var previous = drag.points[drag.points.length - 1];
		var step_x = point.x - previous.x;
		var step_y = point.y - previous.y;
		if (step_x * step_x + step_y * step_y >= 1) { drag.points.push(point); }
		markerSelection.preview = { type: 'poly', points: drag.points };
	}
	else {
		var rect = markerSelectionRectOf(drag.start, point, size);
		markerSelection.preview = { type: 'rect', x: rect.x, y: rect.y, w: rect.w, h: rect.h };
	}
	markerSelectionRedraw();
	return true;
}

function markerSelectionPointerUp() {
	var drag = markerSelection.drag;
	if (!drag) { return false; }
	markerSelection.drag = undefined;
	if (typeof markerStroke !== 'undefined') {
		markerStroke.drawing = false;
		markerStroke.pointer_id = undefined;
	}
	markerSelection.preview = undefined;
	if (drag.type == 'move') {
		markerSelectionAnchor();
		return true;
	}
	var size = markerSelectionDocument();
	if (!size) {
		markerSelectionClear();
		return true;
	}
	if (drag.type == 'poly') {
		if (!markerSelectionUseLasso(drag.points)) { markerSelectionClear(); }
		return true;
	}
	var rect = markerSelectionRectOf(drag.start, drag.last, size);
	if (!markerSelectionUseRect(rect)) { markerSelectionClear(); }
	return true;
}

// ---- wiring -----------------------------------------------------------

$(document).on('click', '.marker_selection_action', function() {
	var act = $(this).attr('act');
	if (act == 'all') { markerSelectionAll(); }
	else if (act == 'none') { markerSelectionNone(); }
	else if (act == 'copy') { markerSelectionCopy(); }
	else if (act == 'cut') { markerSelectionCut(); }
	else if (act == 'paste') { markerSelectionPaste(); }
	else if (act == 'delete') { markerSelectionErase(); }
});

$(document).on('click', '.marker_selection_effect', function() {
	var duty = $(this).attr('duty');
	if (!duty) { return; }
	var defaults = { 'modulate': 120, 'level': 10, 'gaussian-blur': 3, 'sharpen': 2 };
	var fallback = defaults[duty];
	if (fallback == undefined) { fallback = markerTransformDefaults[duty]; }
	var value = markerTransformNumber($('#marker_selection_value').val(), fallback);
	markerSelectionEffect(duty, value);
});

// leaving the move tool settles a float the keyboard may have nudged, so the
// pixels are back on the layer for the next autosave
$(document).on('click', '.marker_tool', function() {
	if ($(this).attr('tool') != 'move' && markerSelection.floating) { markerSelectionAnchor(); }
	if (markerSelectionAntsWanted()) { markerSelectionAntsStart(); }
});

$(document).on('visibilitychange', function() {
	if (!document.hidden && markerSelectionAntsWanted()) { markerSelectionAntsStart(); }
});

function markerSelectionTyping(target) {
	if (!target || typeof $ === 'undefined') { return false; }
	var element = $(target);
	if (element.is('input, textarea, select')) { return true; }
	if (element.is('[contenteditable]')) { return true; }
	return element.closest('[contenteditable]').length > 0;
}

$(document).on('keydown', function(e) {
	if (!markerSelectionStageVisible()) { return; }
	if (markerSelectionTyping(e.target)) { return; }
	var key = e.key || '';
	var command = e.ctrlKey || e.metaKey;
	if (key == 'Escape') {
		if (markerSelectionNone()) { e.preventDefault(); }
		return;
	}
	if (command && !e.altKey) {
		var letter = key.toLowerCase();
		if (letter == 'a') { if (markerSelectionAll()) { e.preventDefault(); } }
		else if (letter == 'c') { if (markerSelectionCopy()) { e.preventDefault(); } }
		else if (letter == 'x') { if (markerSelectionCut()) { e.preventDefault(); } }
		else if (letter == 'v') { if (markerSelectionPaste()) { e.preventDefault(); } }
		return;
	}
	if (command || e.altKey) { return; }
	if (key == 'Delete' || key == 'Backspace') {
		if (markerSelectionErase()) { e.preventDefault(); }
		return;
	}
	var step = e.shiftKey ? 10 : 1;
	if (key == 'ArrowLeft') { if (markerSelectionNudge(-step, 0)) { e.preventDefault(); } }
	else if (key == 'ArrowRight') { if (markerSelectionNudge(step, 0)) { e.preventDefault(); } }
	else if (key == 'ArrowUp') { if (markerSelectionNudge(0, -step)) { e.preventDefault(); } }
	else if (key == 'ArrowDown') { if (markerSelectionNudge(0, step)) { e.preventDefault(); } }
});
