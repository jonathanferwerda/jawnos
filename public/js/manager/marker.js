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
	markerLayerCounter++;
	var layer = {
		uuid: markerUuid(),
		name: name || ('Layer ' + markerLayerCounter),
		visible: true,
		canvas: document.createElement('canvas'),
		ctx: null
	};
	layer.canvas.width = canvas ? canvas.width : 300;
	layer.canvas.height = canvas ? canvas.height : 150;
	layer.ctx = layer.canvas.getContext('2d');
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
	var size = markerDocSize();
	whiteboard_ctx.save();
	whiteboard_ctx.setTransform(1, 0, 0, 1, 0, 0);
	whiteboard_ctx.globalAlpha = 1;
	whiteboard_ctx.globalCompositeOperation = 'source-over';
	whiteboard_ctx.clearRect(0, 0, canvas.width, canvas.height);
	whiteboard_ctx.setTransform(markerView.scale, 0, 0, markerView.scale, markerView.x, markerView.y);
	for (var i = 0; i < markerLayers.length; i++) {
		if (markerLayers[i].visible) { whiteboard_ctx.drawImage(markerLayers[i].canvas, 0, 0); }
	}
	if (markerPreview) {
		markerDrawSegment(whiteboard_ctx, markerPreview.from, markerPreview.to, markerPreview.pressure);
	}
	// show where the paper ends when the view is not the whole document
	if (size.w && (markerView.scale != 1 || markerView.x > 0 || markerView.y > 0)) {
		whiteboard_ctx.setTransform(1, 0, 0, 1, 0, 0);
		whiteboard_ctx.globalCompositeOperation = 'source-over';
		whiteboard_ctx.globalAlpha = 1;
		whiteboard_ctx.strokeStyle = 'rgba(0,0,0,0.35)';
		whiteboard_ctx.lineWidth = 1;
		whiteboard_ctx.strokeRect(markerView.x + 0.5, markerView.y + 0.5, size.w * markerView.scale - 1, size.h * markerView.scale - 1);
	}
	whiteboard_ctx.restore();
	markerThumbSoon();
}

// stamping fires many times per frame, so coalesce the repaints - strokes stay
// live, but the composite only happens once per animation frame
function markerComposeSoon() {
	if (markerComposePending) { return; }
	markerComposePending = true;
	requestAnimationFrame(function() {
		markerComposePending = false;
		markerCompose();
	});
}

function markerThumbSoon() {
	if (markerThumbTimeout) { return; }
	markerThumbTimeout = setTimeout(function() {
		markerThumbTimeout = undefined;
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

function markerZoomAt(screen_x, screen_y, factor) {
	var scale = Math.max(0.05, Math.min(16, markerView.scale * factor));
	if (scale == markerView.scale) { return; }
	// keep the document point under the cursor pinned while the scale changes
	markerView.x = screen_x - (screen_x - markerView.x) * (scale / markerView.scale);
	markerView.y = screen_y - (screen_y - markerView.y) * (scale / markerView.scale);
	markerView.scale = scale;
	markerViewClamp();
	markerZoomDisplay();
	markerCompose();
}

function markerZoomCentre(factor) {
	var canvas = document.getElementById('whiteboard');
	if (!canvas) { return; }
	markerZoomAt(canvas.width / 2, canvas.height / 2, factor);
}

function markerViewFit() {
	var canvas = document.getElementById('whiteboard');
	var size = markerDocSize();
	if (!canvas || !size.w || !size.h) { return; }
	var scale = Math.min(canvas.width / size.w, canvas.height / size.h);
	markerView.scale = Math.min(1, scale * 0.98);
	markerView.x = (canvas.width - size.w * markerView.scale) / 2;
	markerView.y = (canvas.height - size.h * markerView.scale) / 2;
	markerZoomDisplay();
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
	var scale = Math.max(0.05, Math.min(16, markerPinch.scale * (distance / markerPinch.distance)));
	// the pinch midpoint drags the document, its spread scales it
	var now_x = mid.x - rect.left, now_y = mid.y - rect.top;
	var was_x = markerPinch.mid.x - rect.left, was_y = markerPinch.mid.y - rect.top;
	markerView.scale = scale;
	markerView.x = now_x - (was_x - markerPinch.x) * (scale / markerPinch.scale);
	markerView.y = now_y - (was_y - markerPinch.y) * (scale / markerPinch.scale);
	markerViewClamp();
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
	if (before && before.image) {
		var layer = markerLayerByUuid(before.uuid);
		if (layer) { layer.ctx.putImageData(before.image, 0, 0); }
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
	markerHistory.push(record);
	if (markerHistory.length > markerHistoryLimit) { markerHistory.shift(); }
	markerRedo = [];
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

// a paint action remembers the pixels it covered: grab the whole layer when it
// starts (one fast copy), then crop to the dirty rectangle when it ends
function markerSnapshotStart() {
	var layer = markerActiveLayer();
	if (!layer) { return; }
	markerStroke.before = {
		uuid: layer.uuid,
		image: layer.ctx.getImageData(0, 0, layer.canvas.width, layer.canvas.height),
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

function markerImageDataCrop(image, width, x, y, w, h) {
	var crop = new ImageData(w, h);
	for (var row = 0; row < h; row++) {
		var from = ((y + row) * width + x) * 4;
		crop.data.set(image.data.subarray(from, from + w * 4), row * w * 4);
	}
	return crop;
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
		layers: [{ uuid: before.uuid, x: x, y: y, w: w, h: h, data: markerImageDataCrop(before.image, before.width, x, y, w, h) }]
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
	if (record.kind == 'rect') {
		var inverse = [];
		$.each(record.layers, function(i, crop) {
			var layer = markerLayerByUuid(crop.uuid);
			if (!layer) { return; }
			var current = layer.ctx.getImageData(crop.x, crop.y, crop.w, crop.h);
			layer.ctx.putImageData(crop.data, crop.x, crop.y);
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
	markerCompose();
}

function markerRedoStep() {
	var record = markerRedo.pop();
	if (!record) { return; }
	var inverse = markerApplyRecord(record);
	if (inverse) { markerHistory.push(inverse); }
	markerLayerList();
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
	var name = prompt('Session name', markerSessionName || ('Session ' + new Date().toLocaleString()));
	if (!name) { return; }
	markerSessionName = name;
	markerSessionUpload({
		name: name,
		session_uuid: markerSessionUuid,
		origin_uuid: markerSessionUuid,
		origin_name: name
	});
}

function markerSessionUpload(options) {
	var layers = [];
	$.each(markerLayers, function(i, layer) {
		layers.push({ name: layer.name, visible: layer.visible, image: layer.canvas.toDataURL('image/png') });
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
		else { alert('This drawing is too big to save as one session (' + Math.round(payload.length / 1048576) + 'MB). Try fewer or flatter layers.'); }
		return;
	}
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
	// a session drawn on a bigger screen than this one gets fitted to view
	if (canvas && (size.w != canvas.width || size.h != canvas.height)) { markerViewFit(); }
	else { markerViewReset(); }
	markerLayerList();
	markerCompose();
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

// ---- autosave ----------------------------------------------------------

var markerAutosaveTimeout;
var markerAutosaveDirty = false;
var markerSessionLoading = false;
var markerAutosaveDelay = 5000;

function markerAutosaveSoon() {
	markerAutosaveDirty = true;
	if (markerAutosaveTimeout) { clearTimeout(markerAutosaveTimeout); }
	markerAutosaveTimeout = setTimeout(markerAutosaveNow, markerAutosaveDelay);
}

function markerAutosaveNow() {
	if (markerAutosaveTimeout) { clearTimeout(markerAutosaveTimeout); }
	markerAutosaveTimeout = undefined;
	if (!markerAutosaveDirty) { return; }
	if (markerSessionLoading) { return; }
	var canvas = document.getElementById('whiteboard');
	if (!canvas || markerLayers.length == 0) { return; }
	markerAutosaveDirty = false;
	markerSessionUpload({
		name: markerSessionName || 'working',
		session_uuid: markerWorkingUuid(),
		working: true,
		origin_uuid: markerSessionUuid,
		origin_name: markerSessionName,
		silent: true
	});
}

// leaving the tab is the moment worth catching, so a save is not waiting on
// the debounce when the page goes away
$(document).on('visibilitychange', function() {
	if (document.hidden) { markerAutosaveNow(); }
});
$(window).on('pagehide', function() { markerAutosaveNow(); });

function markerSessionPanel(sessions) {
	var panel = $('#marker_sessions');
	if (panel.length == 0) { return; }
	if (sessions == undefined) {
		$.ajax({
			url: '/manager/marker/session/list',
			type: 'GET',
			data: { app: '' },
			success: function(response) { markerSessionPanel((response && response.sessions) || []); }
		});
		return;
	}
	panel.html('');
	if (sessions.length == 0) { panel.html('<i>no saved sessions</i>'); return; }
	$.each(sessions, function(i, s) {
		var row = $('<span class="marker_session hover" hint="Load this drawing in the marker"></span>').attr('uuid', s.uuid).attr('app', s.app);
		if (s.thumbnail) { row.append($('<img class="little_thumb">').attr('src', s.thumbnail)); }
		row.append($('<b></b>').text(s.name || 'session'));
		row.append($('<span style="font-size:10px;"></span>').text(' ' + (s.layers || 0) + ' layers '));
		row.append($('<img class="tiny_thumb marker_session_delete hover" hint="Delete">').attr('src', '/images/make believe/cancel_button.png'));
		panel.append(row);
		panel.append('<br>');
	});
}

function markerSessionOpen(session_uuid) {
	markerSessionRestored = true;
	if ($('#whiteboard').length > 0) {
		var wind = $('#whiteboard').closest('.wind');
		if (wind.length > 0) { wind.show(); topLevelNow(wind); }
		markerSessionLoad(session_uuid);
		return;
	}
	$.ajax({
		url: '/manager/marker',
		type: 'GET',
		data: { window_maker: 'yes', app: 'marker', timestamp: Date.now(), browser_tab_id: bti },
		success: function(response) {
			windowMaker(response);
			markerInit();
			markerSessionWait(session_uuid, 0);
		}
	});
}

function markerSessionWait(session_uuid, attempts) {
	if (attempts > 24) { return; }
	if ($('#whiteboard').length > 0 && $('#whiteboard').is(':visible')) {
		markerSessionLoad(session_uuid);
		return;
	}
	setTimeout(function() { markerSessionWait(session_uuid, attempts + 1); }, 250);
}

// ---- brushes -----------------------------------------------------------

function markerRgba(hex, alpha) {
	var h = (hex || '#000000').replace('#', '');
	if (h.length == 3) { h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]; }
	var n = parseInt(h, 16);
	if (isNaN(n)) { n = 0; }
	return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: alpha };
}

function markerRgbaString(hex, alpha) {
	var c = markerRgba(hex, alpha);
	return 'rgba(' + c.r + ',' + c.g + ',' + c.b + ',' + c.a + ')';
}

// a soft round stamp for the paintbrush; cached because building a radial
// gradient per dab is expensive
function markerBrushSprite(size, colour, alpha, hardness) {
	var key = size + '_' + colour + '_' + alpha + '_' + hardness;
	if (markerSprites[key]) { return markerSprites[key]; }
	if (Object.keys(markerSprites).length > 80) { markerSprites = {}; }
	var canvas = document.createElement('canvas');
	var diameter = Math.ceil(size * 2) + 2;
	canvas.width = diameter;
	canvas.height = diameter;
	var ctx = canvas.getContext('2d');
	var centre = diameter / 2;
	var gradient = ctx.createRadialGradient(centre, centre, Math.max(0, size * hardness), centre, centre, size);
	gradient.addColorStop(0, markerRgbaString(colour, alpha));
	gradient.addColorStop(1, markerRgbaString(colour, 0));
	ctx.fillStyle = gradient;
	ctx.fillRect(0, 0, diameter, diameter);
	markerSprites[key] = canvas;
	return canvas;
}

// spray is a scatter of tiny dots; erasing version is the same dots drawn
// with destination-out, which removes alpha instead of adding colour
function markerSprayBurst(ctx, x, y) {
	var count = Math.max(1, Math.round(markerStroke.size * 0.8 * (markerStroke.pressure || 1)));
	ctx.fillStyle = markerRgbaString(markerStroke.colour, markerStroke.alpha * 0.12);
	for (var i = 0; i < count; i++) {
		var angle = Math.random() * Math.PI * 2;
		var radius = markerStroke.size * Math.sqrt(Math.random());
		ctx.fillRect(x + Math.cos(angle) * radius, y + Math.sin(angle) * radius, 1.5, 1.5);
	}
}

function markerSprayTick() {
	if (!markerStroke.drawing || markerStroke.tool != 'spray') {
		markerStroke.spraying = false;
		return;
	}
	markerSprayBurst(markerActiveContext(), markerStroke.x, markerStroke.y);
	markerComposeSoon();
	markerStroke.spraying = requestAnimationFrame(markerSprayTick);
}

// ---- flood fill --------------------------------------------------------

function markerFillMatch(data, offset, r, g, b, a, tolerance) {
	return Math.abs(data[offset] - r) <= tolerance && Math.abs(data[offset + 1] - g) <= tolerance &&
		Math.abs(data[offset + 2] - b) <= tolerance && Math.abs(data[offset + 3] - a) <= tolerance;
}

function markerFloodFill(x, y) {
	var layer = markerActiveLayer();
	if (!layer) { return; }
	var canvas = layer.canvas;
	var w = canvas.width, h = canvas.height;
	x = Math.floor(x);
	y = Math.floor(y);
	if (x < 0 || y < 0 || x >= w || y >= h) { return; }
	var image = layer.ctx.getImageData(0, 0, w, h);
	var data = image.data;
	var start = (y * w + x) * 4;
	var tr = data[start], tg = data[start + 1], tb = data[start + 2], ta = data[start + 3];
	var colour = markerRgba(markerStroke.colour, markerStroke.alpha);
	var fr = colour.r, fg = colour.g, fb = colour.b, fa = Math.round(colour.a * 255);
	if (markerStroke.erase) { fr = 0; fg = 0; fb = 0; fa = 0; }
	if (Math.abs(tr - fr) < 2 && Math.abs(tg - fg) < 2 && Math.abs(tb - fb) < 2 && Math.abs(ta - fa) < 2) { return; }
	var tolerance = 32;
	var visited = new Uint8Array(w * h);
	var min_x = x, min_y = y, max_x = x, max_y = y;
	// the stack holds packed pixel indexes - pushing x and y separately is
	// easy to get backwards when popping
	var stack = [y * w + x];
	while (stack.length > 0) {
		var index = stack.pop();
		if (visited[index]) { continue; }
		var px = index % w, py = Math.floor(index / w);
		var row = py * w;
		var left = px;
		while (left > 0 && !visited[row + left - 1] && markerFillMatch(data, (row + left - 1) * 4, tr, tg, tb, ta, tolerance)) { left--; }
		var right = px;
		while (right < w - 1 && !visited[row + right + 1] && markerFillMatch(data, (row + right + 1) * 4, tr, tg, tb, ta, tolerance)) { right++; }
		for (var i = left; i <= right; i++) {
			if (i < min_x) { min_x = i; }
			if (i > max_x) { max_x = i; }
			visited[row + i] = 1;
			var offset = (row + i) * 4;
			data[offset] = fr;
			data[offset + 1] = fg;
			data[offset + 2] = fb;
			data[offset + 3] = fa;
			if (py > 0 && !visited[(py - 1) * w + i] && markerFillMatch(data, ((py - 1) * w + i) * 4, tr, tg, tb, ta, tolerance)) { stack.push((py - 1) * w + i); }
			if (py < h - 1 && !visited[(py + 1) * w + i] && markerFillMatch(data, ((py + 1) * w + i) * 4, tr, tg, tb, ta, tolerance)) { stack.push((py + 1) * w + i); }
		}
		if (py < min_y) { min_y = py; }
		if (py > max_y) { max_y = py; }
	}
	layer.ctx.putImageData(image, 0, 0);
	markerCompose();
	return { x0: min_x, y0: min_y, x1: max_x + 1, y1: max_y + 1 };
}

// ---- stroke input ------------------------------------------------------

function markerSettings() {
	marker.selected_marker_transparency = numeral($('#marker_transparency').val() || 1).value();
	marker.selected_marker_size = numeral($('#marker_size').val() || 20).value();
	markerStroke.tool = localStorage.getItem('marker_tool') || 'pencil';
	markerStroke.erase = localStorage.getItem('marker_erase') == 'on';
	markerStroke.size = marker.selected_marker_size;
	markerStroke.colour = marker.selected_marker_colour;
	markerStroke.alpha = marker.selected_marker_transparency;
}

function markerPointerEvent(e) {
	var canvas = document.getElementById('whiteboard');
	var rect = canvas.getBoundingClientRect();
	var x = e.clientX - rect.left;
	var y = e.clientY - rect.top;
	if (rect.width > 0 && rect.width != canvas.width) { x = x * (canvas.width / rect.width); }
	if (rect.height > 0 && rect.height != canvas.height) { y = y * (canvas.height / rect.height); }
	// a pen reports how hard it is pressing; the stylus toggle decides whether
	// that changes the brush width
	var pressure = 1;
	if (e.pointerType == 'pen' && $('.marker_stylus_toggle').attr('toggle') == 'on' && e.pressure > 0) {
		pressure = Math.max(0.15, Math.min(1, e.pressure));
	}
	// screen coords are what reads the composite (sampling, pointers); document
	// coords (through the zoom and pan view) are what the layers are drawn in
	return {
		x: (x - markerView.x) / markerView.scale,
		y: (y - markerView.y) / markerView.scale,
		screen: { x: x, y: y },
		pressure: pressure
	};
}

function markerWidth(pressure) {
	if (pressure == undefined) { pressure = 1; }
	return markerStroke.size * 2 * (0.3 + 0.7 * pressure);
}

// apply the current brush to a context (colour, erase, alpha, width)
function markerStrokeSettings(ctx) {
	ctx.globalAlpha = markerStroke.alpha;
	ctx.lineCap = 'round';
	ctx.lineJoin = 'round';
	ctx.lineWidth = markerWidth(markerStroke.pressure);
	if (markerStroke.erase) {
		ctx.globalCompositeOperation = 'destination-out';
		ctx.strokeStyle = markerRgbaString('#000000', 1);
		ctx.fillStyle = markerRgbaString('#000000', 1);
	}
	else {
		ctx.globalCompositeOperation = 'source-over';
		ctx.strokeStyle = markerStroke.colour;
		ctx.fillStyle = markerStroke.colour;
	}
}

// one straight run of the current brush, from a document point to another.
// Used for every stroke segment, and on its own for straight lines (ctrl/
// shift) and their preview, so the line matches the brush exactly.
function markerDrawSegment(ctx, from, to, pressure) {
	if (pressure == undefined) { pressure = markerStroke.pressure; }
	markerStrokeSettings(ctx);
	var tool = markerStroke.tool;
	if (tool == 'pencil') {
		ctx.lineWidth = markerWidth(pressure);
		ctx.beginPath();
		ctx.moveTo(from.x, from.y);
		// nudge a zero length path so a single click still leaves a dot
		ctx.lineTo(to.x + (from.x == to.x && from.y == to.y ? 0.01 : 0), to.y);
		ctx.stroke();
	}
	else if (tool == 'brush') {
		var brush_size = Math.max(1, Math.round(markerStroke.size * (0.3 + 0.7 * pressure)));
		var sprite = markerBrushSprite(brush_size, markerStroke.colour, markerStroke.alpha, 0.35);
		var distance = Math.sqrt((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y));
		var spacing = Math.max(1, markerStroke.size / 4);
		var steps = Math.min(400, Math.floor(distance / spacing) + 1);
		for (var i = 0; i <= steps; i++) {
			var t = steps == 0 ? 0 : i / steps;
			ctx.drawImage(sprite, from.x + (to.x - from.x) * t - sprite.width / 2, from.y + (to.y - from.y) * t - sprite.height / 2);
		}
	}
	else if (tool == 'spray') {
		var spray_distance = Math.sqrt((to.x - from.x) * (to.x - from.x) + (to.y - from.y) * (to.y - from.y));
		var bursts = Math.max(1, Math.min(120, Math.floor(spray_distance / Math.max(2, markerStroke.size / 3)) + 1));
		for (var b = 0; b <= bursts; b++) {
			var bt = bursts == 0 ? 0 : b / bursts;
			markerSprayBurst(ctx, from.x + (to.x - from.x) * bt, from.y + (to.y - from.y) * bt);
		}
	}
	ctx.globalCompositeOperation = 'source-over';
	ctx.globalAlpha = 1;
}

// wheel deltas arrive as pixels, lines or pages depending on the device, so
// everything is converted to pixels first
function markerWheelAmount(value, mode) {
	if (mode == 1) { return value * 16; }
	if (mode == 2) { return value * 400; }
	return value;
}

function markerWheelZoomMode() {
	return localStorage.getItem('marker_wheel_zoom') == 'on';
}

function markerWheelModeApply() {
	var button = $('#marker_wheel_mode');
	if (button.length == 0) { return; }
	if (markerWheelZoomMode()) {
		button.attr('hint', 'Two finger scroll zooms; shift + scroll pans. Click for scroll = pan');
		button.css({'background-color': 'rgba(255,255,255,0.4)', 'border-radius': '7px'});
	}
	else {
		button.attr('hint', 'Two finger scroll pans, ctrl + scroll zooms. Click for scroll = zoom');
		button.css('background-color', '');
	}
}

function markerZoomDisplay() {
	var button = $('#marker_zoom_fit');
	if (button.length == 0) { return; }
	var percent = Math.round(markerView.scale * 100) + '%';
	if (button.text() != percent) { button.text(percent); }
}

function markerWheel(e) {
	e.preventDefault();
	var canvas = document.getElementById('whiteboard');
	var rect = canvas.getBoundingClientRect();
	var delta = markerWheelAmount(e.deltaY, e.deltaMode);
	if (e.ctrlKey || e.metaKey || (markerWheelZoomMode() && !e.shiftKey)) {
		// ctrl + scroll is the zoom everywhere; a trackpad pinch arrives as a
		// ctrl wheel on the platforms that report it at all, and scroll = zoom
		// mode exists for the ones that do not (Linux trackpads never send it)
		var factor = Math.max(0.5, Math.min(2, Math.pow(1.0015, -delta)));
		markerZoomAt(e.clientX - rect.left, e.clientY - rect.top, factor);
		return;
	}
	if (e.shiftKey) { markerView.x -= delta; }
	else {
		markerView.x -= markerWheelAmount(e.deltaX, e.deltaMode);
		markerView.y -= delta;
	}
	markerViewClamp();
	markerCompose();
}

// Safari (and iPadOS) report pinch gestures as their own events with a scale
// relative to the start of the gesture
var markerGestureScale = 1;
function markerGestureStart(e) {
	e.preventDefault();
	markerGestureScale = 1;
}

function markerGestureChange(e) {
	e.preventDefault();
	var canvas = document.getElementById('whiteboard');
	var rect = canvas.getBoundingClientRect();
	var scale = e.scale || 1;
	var factor = scale / markerGestureScale;
	markerGestureScale = scale;
	markerZoomAt(e.clientX - rect.left, e.clientY - rect.top, factor);
}

function markerGestureEnd(e) {
	e.preventDefault();
	markerGestureScale = 1;
}

// ---- toolbox -----------------------------------------------------------

function markerToolboxHidden() {
	return localStorage.getItem('marker_toolbox_hidden') == 'on';
}

function markerToolboxApply() {
	var hidden = markerToolboxHidden();
	$('#marker_toolbox').toggle(!hidden);
	$('#marker_toolbox_show').toggle(hidden);
}

// hiding the toolbox hands its width back to the board, and the layers keep
// their size, so the extra room just shows more space around the drawing
function markerCanvasResize() {
	var canvas = document.getElementById('whiteboard');
	if (!canvas) { return; }
	var win = $(canvas).closest('.wind');
	if (win.length == 0) { return; }
	var toolbox_width = markerToolboxHidden() ? 0 : Math.round($('#marker_toolbox').outerWidth() || 0);
	var width = Math.floor(win.width() - toolbox_width);
	var height = Math.floor(win.height() - win.find('.top_navbar').height());
	if (width > 0 && height > 0 && (canvas.width !== width || canvas.height !== height)) {
		canvas.width = width;
		canvas.height = height;
		markerViewClamp();
		markerCompose();
	}
}

function markerToolboxToggle(hidden) {
	localStorage.setItem('marker_toolbox_hidden', hidden ? 'on' : 'off');
	markerToolboxApply();
	markerCanvasResize();
}

// palm protection: a finger or a resting palm must not draw when a stylus is
// in play. The stylus toggle is the explicit switch, and a pen touching or
// hovering (palms usually land before the nib does) is enough on its own.
function markerPalm(e) {
	if (e.pointerType != 'touch') { return false; }
	if ($('.marker_stylus_toggle').attr('toggle') == 'on') { return true; }
	if (markerPenDown) { return true; }
	if (markerPenSeen && Date.now() - markerPenSeen < 3000) { return true; }
	return false;
}

function markerStylusDisplay() {
	var toggle = $('.marker_stylus_toggle');
	if (toggle.length == 0) { return; }
	if (toggle.attr('toggle') == 'on') {
		toggle.attr('hint', 'Stylus (palm protection on)');
		toggle.css({'background-color': 'rgba(255,255,255,0.4)', 'border-radius': '7px'});
	}
	else {
		toggle.attr('hint', 'Stylus (finger drawing, no palm protection)');
		toggle.css('background-color', '');
	}
}

function markerKeyboardPointer(pos) {
	localStorage.setItem('whiteboard_position', '{ "x": "' + pos.x + '", "y": "' + pos.y + '"}');
	var wb = $('#whiteboard').offset();
	var screen = markerDocToScreen(pos.x, pos.y);
	$('#pointer').css({ 'top': screen.y + wb['top'] - 12, 'left': screen.x + wb['left'] });
}

function markerSampleColour(pos) {
	var canvas = document.getElementById('whiteboard');
	var ctx = canvas.getContext('2d');
	var imgData = ctx.getImageData(Math.floor(pos.screen.x), Math.floor(pos.screen.y), 1, 1);
	var r = imgData.data[0].toString(16).padStart(2, '0');
	var g = imgData.data[1].toString(16).padStart(2, '0');
	var b = imgData.data[2].toString(16).padStart(2, '0');
	var colour = '#' + r + g + b;
	$('.marker_colour[uuid="' + marker.selected_marker_colour_uuid + '"]').val(colour);
	marker.selected_marker_colour = colour;
}

function markerPointerDown(pos, straight_line) {
	markerSettings();
	var tool = markerStroke.tool;
	if (tool == 'kb') { markerKeyboardPointer(pos); return; }
	if (tool == 'sample') { markerSampleColour(pos); return; }
	if (tool == 'fill') {
		markerSnapshotStart();
		var filled = markerFloodFill(pos.x, pos.y);
		if (filled) { markerSnapshotDirty(filled.x0, filled.y0, filled.x1 - filled.x0, filled.y1 - filled.y0); }
		markerSnapshotCommit();
		markerAutosaveSoon();
		return;
	}
	markerStroke.pressure = pos.pressure;
	markerSnapshotStart();
	markerStroke.drawing = true;
	markerStroke.x = pos.x;
	markerStroke.y = pos.y;
	markerStroke.line_from = undefined;
	markerStroke.line_to = undefined;
	var size = markerStroke.size + 2;
	markerSnapshotDirty(pos.x - size, pos.y - size, size * 2, size * 2);
	// ctrl (or shift / cmd) pulls a straight line from the last point, and
	// dragging its far end previews where it will land
	if (straight_line && markerLastPoint && (tool == 'pencil' || tool == 'brush' || tool == 'spray')) {
		markerStroke.line_from = { x: markerLastPoint.x, y: markerLastPoint.y };
		markerStroke.line_to = { x: pos.x, y: pos.y };
		markerPreview = { from: markerStroke.line_from, to: markerStroke.line_to, pressure: pos.pressure };
		markerComposeSoon();
		return;
	}
	markerDrawSegment(markerActiveContext(), { x: pos.x, y: pos.y }, { x: pos.x, y: pos.y }, pos.pressure);
	if (tool == 'spray' && !markerStroke.spraying) { markerStroke.spraying = requestAnimationFrame(markerSprayTick); }
	markerLastPoint = { x: pos.x, y: pos.y };
	markerComposeSoon();
}

function markerPointerMove(pos) {
	if (!markerStroke.drawing) { return; }
	markerSettings();
	var x0 = markerStroke.x, y0 = markerStroke.y;
	var size = markerStroke.size + 2;
	markerStroke.pressure = pos.pressure;
	if (markerStroke.line_from) {
		markerStroke.line_to = { x: pos.x, y: pos.y };
		markerPreview = { from: markerStroke.line_from, to: markerStroke.line_to, pressure: pos.pressure };
		markerComposeSoon();
		return;
	}
	markerDrawSegment(markerActiveContext(), { x: x0, y: y0 }, { x: pos.x, y: pos.y }, pos.pressure);
	markerSnapshotDirty(Math.min(x0, pos.x) - size, Math.min(y0, pos.y) - size, Math.abs(pos.x - x0) + size * 2, Math.abs(pos.y - y0) + size * 2);
	markerStroke.x = pos.x;
	markerStroke.y = pos.y;
	// straight lines start from wherever the brush was last put down
	markerLastPoint = { x: pos.x, y: pos.y };
	markerComposeSoon();
}

function markerEndStroke() {
	if (markerStroke.spraying) { cancelAnimationFrame(markerStroke.spraying); markerStroke.spraying = false; }
	markerStroke.pointer_id = undefined;
	if (!markerStroke.drawing) { markerPreview = undefined; return; }
	markerStroke.drawing = false;
	// commit a straight line now that its far end is known
	if (markerStroke.line_from) {
		var to = markerStroke.line_to || markerStroke.line_from;
		markerDrawSegment(markerActiveContext(), markerStroke.line_from, to, markerStroke.pressure);
		var size = markerStroke.size + 2;
		markerSnapshotDirty(Math.min(markerStroke.line_from.x, to.x) - size, Math.min(markerStroke.line_from.y, to.y) - size,
			Math.abs(to.x - markerStroke.line_from.x) + size * 2, Math.abs(to.y - markerStroke.line_from.y) + size * 2);
		markerLastPoint = { x: to.x, y: to.y };
		markerStroke.line_from = undefined;
		markerStroke.line_to = undefined;
	}
	markerPreview = undefined;
	markerSnapshotCommit();
	markerCompose();
	markerAutosaveSoon();
}

function markerMouseDown(e) {
	if (e.pointerType == 'pen') { markerPenSeen = Date.now(); markerPenDown = true; }
	if (e.pointerType == 'touch') {
		markerTouches[e.pointerId] = { x: e.clientX, y: e.clientY };
		if (Object.keys(markerTouches).length >= 2) {
			// two fingers is always a gesture, even with palm protection on
			markerCancelStroke();
			markerPinch = markerPinchStart();
			return;
		}
	}
	if (e.pointerType == 'mouse' && e.button == 1) {
		e.preventDefault();
		markerPanning = { x: e.clientX, y: e.clientY, view_x: markerView.x, view_y: markerView.y };
		var pan_canvas = document.getElementById('whiteboard');
		if (pan_canvas.setPointerCapture) { try { pan_canvas.setPointerCapture(e.pointerId); } catch (err) {} }
		return;
	}
	if (e.pointerType == 'mouse' && e.button !== 0) { return; }
	if (markerPalm(e)) { return; }
	if (markerStroke.drawing) { return; }
	e.preventDefault();
	var canvas = document.getElementById('whiteboard');
	if (canvas.setPointerCapture) {
		try { canvas.setPointerCapture(e.pointerId); markerPointerCaptured = true; }
		catch (err) { markerPointerCaptured = false; }
	}
	markerStroke.pointer_id = e.pointerId;
	markerPointerDown(markerPointerEvent(e), e.ctrlKey || e.metaKey || e.shiftKey);
}

function markerMouseMove(e) {
	if (e.pointerType == 'pen') { markerPenSeen = Date.now(); }
	window.mouse = e;
	if (e.pointerType == 'touch' && markerTouches[e.pointerId]) {
		markerTouches[e.pointerId] = { x: e.clientX, y: e.clientY };
		if (markerPinch) { markerPinchMove(); return; }
	}
	if (markerPanning) {
		markerView.x = markerPanning.view_x + (e.clientX - markerPanning.x);
		markerView.y = markerPanning.view_y + (e.clientY - markerPanning.y);
		markerViewClamp();
		markerComposeSoon();
		return;
	}
	// only the pointer that started the stroke may add to it - a palm or a
	// second finger dragging past must not paint
	if (markerStroke.drawing && (markerStroke.pointer_id == undefined || e.pointerId == markerStroke.pointer_id)) {
		markerPointerMove(markerPointerEvent(e));
	}
	else if (!markerStroke.drawing && localStorage.getItem('marker_tool') == 'kb') { markerKeyboardPointer(markerPointerEvent(e)); }
}

function markerPointerUp(e) {
	if (e.pointerType == 'pen') { markerPenDown = false; markerPenSeen = Date.now(); }
	if (e.pointerType == 'touch') {
		delete markerTouches[e.pointerId];
		if (Object.keys(markerTouches).length < 2) { markerPinch = undefined; }
	}
	if (markerPanning) { markerPanning = undefined; markerPointerCaptured = false; return; }
	// a second finger lifting must not end the stroke that is being drawn
	if (markerStroke.pointer_id != undefined && e.pointerId != markerStroke.pointer_id) { return; }
	markerStroke.pointer_id = undefined;
	markerPointerCaptured = false;
	markerEndStroke();
}

function markerPointerLeave(e) {
	// a captured stroke keeps drawing outside the canvas; otherwise let go
	if (markerPointerCaptured) { return; }
	if (markerStroke.pointer_id != undefined && e.pointerId != markerStroke.pointer_id) { return; }
	markerEndStroke();
}

// pointer events cover mouse, finger and stylus in one place (and let the pen
// report pressure). touch-action none stops the page scrolling or zooming
// when a stroke starts on the canvas.
function markerBindCanvas(canvas) {
	if (markerBoundCanvas === canvas) { return; }
	markerBoundCanvas = canvas;
	canvas.style.touchAction = 'none';
	canvas.addEventListener('pointerdown', markerMouseDown);
	canvas.addEventListener('pointermove', markerMouseMove);
	canvas.addEventListener('pointerup', markerPointerUp);
	canvas.addEventListener('pointercancel', markerPointerUp);
	canvas.addEventListener('pointerleave', markerPointerLeave);
	canvas.addEventListener('wheel', markerWheel, { passive: false });
	canvas.addEventListener('gesturestart', markerGestureStart, { passive: false });
	canvas.addEventListener('gesturechange', markerGestureChange, { passive: false });
	canvas.addEventListener('gestureend', markerGestureEnd, { passive: false });
	canvas.addEventListener('contextmenu', function(e) { e.preventDefault(); });
}

function markerInit(whiteboard) {

	if (whiteboard == undefined) {
		whiteboard = 'whiteboard';
	}
	var canvas = document.getElementById(whiteboard);
	if (!canvas) { return; }
	whiteboard_ctx = canvas.getContext('2d');

	// a different canvas element means a brand new window, so start fresh
	if (markerCanvas !== canvas) {
		markerCanvas = canvas;
		markerLayers = [];
		markerLayerActive = 0;
		markerSprites = {};
		markerHistoryClear();
		markerSessionUuid = undefined;
		markerSessionName = undefined;
		markerSessionRestored = false;
		markerView = { scale: 1, x: 0, y: 0 };
		markerAutosaveDirty = false;
	}
	// the visible canvas follows the window (and the toolbox); the layers are the
	// document and keep their own size, so resizing or zooming never resamples
	// the art
	markerToolboxApply();
	markerWheelModeApply();
	markerZoomDisplay();
	markerCanvasResize();
	if (markerLayers.length == 0) {
		markerLayers.push(markerNewLayer('Layer 1'));
		markerLayerActive = 0;
	}
	markerLastPoint = undefined;
	markerPreview = undefined;
	var doc = markerDocSize();
	if (canvas.width > 0 && (doc.w != canvas.width || doc.h != canvas.height)) { markerViewFit(); }
	clearInterval(markerVideoInterval);
	markerToolSetup();
	markerBindCanvas(canvas);
	markerLayerList();
	markerCompose();
	markerSessionRestoreLast();
}

$(document).on('click', '.marker_stylus_toggle', function() {
	var toggle = $(this).attr('toggle');
	if (toggle == 'on') {
		toggle = 'off';
	} else {
		toggle = 'on';
	}
	$(this).attr('toggle', toggle);
	markerStylusDisplay();
	settingSetter({ 'app': 'marker', 'setting': 'stylus_toggle', 'value': toggle });
});

$(document).on('click', '#marker_colour_add', function() {
	var uuid = crypto.randomUUID();
	var new_colour = marker.selected_marker_colour;
	$('#marker_kit').append('<input uuid="' + uuid + '" type="color" style="width:45%;" class="marker_colour" value="' + new_colour + '" />' +
		'<button class="marker_colour_remove" uuid="' + uuid + '">-</button>');
	marker.selected_marker_colour_uuid = uuid;
	marker.selected_marker_colour = $('.marker_colour[uuid="' + uuid + '"]').val();
	$('.marker_colour').each(function(i,v) { $(v).attr('status', 'inactive') });
	$('.marker_colour[uuid="' + uuid + '"]').attr('status', 'active');
	markerColourSaver()
});

$(document).on('click', '.marker_colour_remove', function() {
	var uuid = $(this).attr('uuid');
	if ($('.marker_colour').length > 0) {
		$(this).next().remove();
		$('.marker_colour[uuid="' + uuid + '"]').remove();
		$('.marker_colour_remove[uuid="' + uuid + '"]').remove();
		$('.marker_colour').each(function(i,v) { $(v).attr('status', 'inactive') });
		var last = $('.marker_colour').last();
		last.attr('status', 'active');
		marker.selected_marker_colour = last.val();
		marker.selected_marker_colour_uuid = last.attr('uuid');
	}
	markerColourSaver();
});

function markerColourSaver() {
	var colours = [];
	$('.marker_colour').each(function(i,v) {
		var uuid = $(v).attr('uuid');
		var colour = $(v).val();
		colours.push({ uuid: uuid, colour: colour });
	});
	var jColours = JSON.stringify(colours);
	settingSetter({ 'app': 'marker', 'setting': 'colours', 'value': jColours });
	return colours;
}

function markerToolSetup() {
	var tool = localStorage.getItem('marker_tool') || 'pencil';
	var erase = localStorage.getItem('marker_erase') == 'on';
	// the old Marker tool is the pencil, and the old Eraser is the pencil with erase on
	if (tool == 'marker') { tool = 'pencil'; }
	if (tool == 'eraser') { tool = 'pencil'; erase = true; }
	if (['pencil','brush','spray','fill','kb','sample'].indexOf(tool) == -1) { tool = 'pencil'; }
	localStorage.setItem('marker_tool', tool);
	localStorage.setItem('marker_erase', erase ? 'on' : 'off');
	$('.marker_tool[tool]').removeClass('selected');
	$('.marker_tool[tool="' + tool + '"]').addClass('selected');
	markerToolEraseDisplay(erase);
	markerStylusDisplay();
}

function markerToolEraseDisplay(erase) {
	var toggle = $('.marker_erase_toggle');
	toggle.attr('erase', erase ? 'on' : 'off');
	if (erase) {
		toggle.addClass('selected');
		toggle.css('background-color', 'rgba(255,255,255,0.4)');
	}
	else {
		toggle.removeClass('selected');
		toggle.css('background-color', '');
	}
}

$(document).on('click', '.marker_tool', function() {
	var t = $(this);
	var tool = t.attr('tool');
	if (!tool) { return; }
	$('.marker_tool[tool]').removeClass('selected');
	t.addClass('selected');
	localStorage.setItem('marker_tool',tool);
});

$(document).on('click', '.marker_erase_toggle', function() {
	var erase = !(localStorage.getItem('marker_erase') == 'on');
	localStorage.setItem('marker_erase', erase ? 'on' : 'off');
	markerToolEraseDisplay(erase);
});

// ---- layer panel -------------------------------------------------------

$(document).on('click', '#marker_layers_toggle', function() {
	$('#marker_layers').slideToggle(120);
});

$(document).on('click', '.marker_layer_row', function() {
	var index = numeral($(this).attr('index')).value();
	markerLayerActive = index;
	markerLayerList();
});

$(document).on('click', '.marker_layer_eye', function(e) {
	e.stopPropagation();
	var row = $(this).closest('.marker_layer_row');
	var layer = markerLayerByUuid(row.attr('uuid'));
	if (!layer) { return; }
	markerHistoryPush(markerStructureRecord());
	layer.visible = !layer.visible;
	markerLayerList();
	markerCompose();
	markerAutosaveSoon();
});

$(document).on('dblclick', '.marker_layer_name', function(e) {
	e.stopPropagation();
	var row = $(this).closest('.marker_layer_row');
	var layer = markerLayerByUuid(row.attr('uuid'));
	if (!layer) { return; }
	var name = prompt('Layer name', layer.name);
	if (name) { layer.name = name; markerLayerList(); }
});

$(document).on('click', '.marker_layer_add', function() {
	markerHistoryPush(markerStructureRecord());
	markerLayers.push(markerNewLayer());
	markerLayerActive = markerLayers.length - 1;
	markerLayerList();
	markerCompose();
	markerAutosaveSoon();
});

$(document).on('click', '.marker_layer_delete', function() {
	var layer = markerActiveLayer();
	if (markerLayers.length <= 1 || !layer) { return; }
	if (!confirm('Delete layer: ' + layer.name + '?')) { return; }
	markerHistoryPush(markerStructureRecord());
	markerLayers.splice(markerLayerActive, 1);
	markerLayerActive = Math.min(markerLayerActive, markerLayers.length - 1);
	markerLayerList();
	markerCompose();
	markerAutosaveSoon();
});

$(document).on('click', '.marker_layer_up', function() {
	if (markerLayerActive >= markerLayers.length - 1) { return; }
	markerHistoryPush(markerStructureRecord());
	markerSwapLayers(markerLayerActive, markerLayerActive + 1);
});

$(document).on('click', '.marker_layer_down', function() {
	if (markerLayerActive <= 0) { return; }
	markerHistoryPush(markerStructureRecord());
	markerSwapLayers(markerLayerActive, markerLayerActive - 1);
});

$(document).on('click', '.marker_layer_front', function() {
	if (markerLayerActive >= markerLayers.length - 1) { return; }
	markerHistoryPush(markerStructureRecord());
	var layer = markerLayers.splice(markerLayerActive, 1)[0];
	markerLayers.push(layer);
	markerLayerActive = markerLayers.length - 1;
	markerLayerList();
	markerCompose();
	markerAutosaveSoon();
});

// ---- undo / redo / sessions -------------------------------------------

$(document).on('click', '.marker_undo', function() { markerUndo(); });
$(document).on('click', '.marker_redo', function() { markerRedoStep(); });

$(document).on('click', '.marker_new_board', function() {
	if (!confirm('Start a new drawing?')) { return; }
	markerLayers = [markerNewLayer('Layer 1')];
	markerLayerActive = 0;
	markerSessionUuid = undefined;
	markerSessionName = undefined;
	markerHistoryClear();
	markerLayerList();
	markerCompose();
	// a new board should not come back from the working copy either
	markerAutosaveDirty = true;
	markerAutosaveNow();
});

$(document).on('click', '.marker_zoom_in', function() { markerZoomCentre(1.25); });
$(document).on('click', '.marker_zoom_out', function() { markerZoomCentre(1 / 1.25); });
$(document).on('click', '.marker_zoom_fit', function() { markerViewFit(); });
$(document).on('click', '#marker_toolbox_hide', function() { markerToolboxToggle(true); });
$(document).on('click', '#marker_toolbox_show', function() { markerToolboxToggle(false); });
$(document).on('click', '#marker_wheel_mode', function() {
	localStorage.setItem('marker_wheel_zoom', markerWheelZoomMode() ? 'off' : 'on');
	markerWheelModeApply();
});

$(document).on('click', '.marker_session_save', function() { markerSessionSave(); });
$(document).on('click', '.marker_session', function() { markerSessionOpen($(this).attr('uuid')); });

$(document).on('click', '.marker_session_delete', function(e) {
	e.stopPropagation();
	var row = $(this).closest('.marker_session');
	$.ajax({
		url: '/manager/marker/session/delete',
		type: 'POST',
		data: { session_uuid: row.attr('uuid'), app: '' },
		success: function(response) { markerSessionPanel((response && response.sessions) || []); }
	});
});

$(document).on('click', '.keyboard_button[key="sessions"], .return_key[key="sessions"]', function() { markerSessionPanelWait(0); });

// the sessions panel is fetched from the server when its key is pressed, so
// wait for its container to appear before filling it
function markerSessionPanelWait(attempts) {
	if (attempts > 20) { return; }
	if ($('#marker_sessions').length > 0) { markerSessionPanel(); return; }
	setTimeout(function() { markerSessionPanelWait(attempts + 1); }, 250);
}

var record_marker;
$(document).on('click', '.record_marker', function() {
	jpCanvas();
	
});


var play_marker;
$(document).on('click', '.play_marker', function() {
	var p = $(this);
	var c = p.closest('.marker_toolbox').find('.flipbook_interval').val();
	clearInterval(play_marker);
	var movement = p.attr('movement');
	if (play_marker) {
		clearInterval(play_marker);
		play_marker = undefined;
	}
	else {
		play_marker = setInterval(function() {
			$('.flipbook[movement="' + movement + '"]').trigger('click');
		},c);
	}
});

function markerInfoGrabber() {
	var marker = {
		tool: localStorage.getItem('marker_tool'),
		transparency: $('#marker_transparency').val() || 1,
		colour: $('#marker_colour').val() || 'navy',
		size: $('#marker_size').val(),
		flipbook_interval: $('#flipbook_interval').val()
	};
	return marker;
}

$(document).on('click', '.save_marker', function() {
	var timestamp = Date.now();
	var canvas = document.getElementById('whiteboard');
	// save the document, at document resolution - not the zoomed in view
	var img = markerFlatten().toDataURL('image/png');
	var paper = 'paper_' + timestamp;
	var p = $('#' + paper);
	var marker = markerInfoGrabber();
	app = topWindow('marker');
	$.ajax({
		url: '/manager/marker/save',
		type: 'POST',
		data: {
			timestamp: timestamp,
			paper: paper,
			img: img,
			marker: JSON.stringify(marker),
			browser_tab_id: bti,
			app: app
		},
		success: function(portfolio) {
			portfolioMaker(JSON.parse(portfolio || []));
		}
	});

	say_it('saved!');
});

$(document).on('click', '.paper', function() {
	var canvas = document.getElementById("whiteboard");
	var ctx = markerActiveContext();
	var image = new Image();
	image.onload=function(){
		markerHistoryWholeLayer();
		var size = markerDocSize();
		ctx.save();
		ctx.globalAlpha = numeral($('#marker_transparency').val() || 1).value();
		ctx.drawImage(image, 0, 0, size.w || canvas.width, size.h || canvas.height);
		ctx.restore();
		markerCompose();
		markerAutosaveSoon();
	};
	image.src = $(this).attr('src');
});

function portfolioMaker(portfolio) {
	page_number = (Number(page_number) + 1);
	$('#portfolio').html('');
	$.each(portfolio,function(i,v) {
		var p = JSON.parse(v.file);
		$.each(p, function(ir,vr) {
			console.log(vr);
			if (vr['type'] == 'image') {
				var phtml = '<button class="marker_delete" uuid="' + v['uuid'] + '" server_time="' + v['server_time'] + '" timestamp="' + v['timestamp'] + '" paper="' + v['paper'] + '" id="' + v['paper'] + '_delete">D</button> \
					<img class="paper" timestamp="' + v['timestamp'] + '" id="' + v['uuid'] + '" src="/file_open?app=' + v['app'] + '&file=' + vr['f'] + '&timestamp=' + vr['server_time'] + '" style="width:40px;height:60px"></img>';
				$('#portfolio').append(phtml);
			}
		});
	});

	if (portfolio) {
		portfolio = portfolio.sort(function(a, b) {
		  return b['timestamp'] - a['timestamp'];
		});
	}
}

var selected_image = 0;
$(document).on('click', '.flipbook', function() {
	var movement = $(this).attr('movement');
	var canvas = document.getElementById('whiteboard');
	var image = new Image();
	var ctx = markerActiveContext();
	var p = $('.paper');
	var total = p.length;
	if (movement == 'back') {
		if (selected_image <= 0) {
			selected_image = total;
		}
		else {
			selected_image = Number(selected_image) - 1;
		}

	}
	else if (movement == 'forward') {
		if (selected_image >= total) {
			selected_image = 0;
		}
		else {
			selected_image = Number(selected_image) + 1;
		}

	}
	image.onload=function(){
		markerHistoryWholeLayer();
		var size = markerDocSize();
		ctx.save();
		ctx.globalAlpha = numeral($('#marker_transparency').val() || 1).value();
		ctx.drawImage(image, 0, 0, size.w || canvas.width, size.h || canvas.height);
		ctx.restore();
		markerCompose();
		markerAutosaveSoon();
	};
	if (p[selected_image]) {
		image.src = p[selected_image].src;
	}
});

$(document).on('click', '.marker_delete', function() {
	var a = $(this);
	var timestamp = $(this).attr('timestamp');
	var file_uuid = $(this).attr('file_uuid');
	var app_uuid = $(this).attr('app_uuid');
	var app = $(this).attr('app');
	var server_time = a.attr('server_time');
	var armed = a.attr('armed');
	if (armed == 'yes') {
		$.ajax({
			url: '/manager/marker/delete',
			type: 'POST',
			data: { app_uuid: app_uuid, file_uuid: file_uuid, app: app },
			success: function(response) {
				$('.paper[file_uuid="' + file_uuid + '"][app_uuid="' + app_uuid + '"]').remove();
				$('.marker_delete[file_uuid="' + file_uuid + '"][app_uuid="' + app_uuid + '"]').remove();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click','#marker_pause', function() {
	var b = $(this);
	var app = b.attr('app');
	if (we['rec'][app].state == 'recording') {
		we['rec'][app].pause();
		b.attr('src', '/images/make believe/delay_button.png');
	}
	else {
		we['rec'][app].resume();
		b.attr('src', '/images/make believe/pause.png');
	}
});

var markerVideoInterval = null;
function markerDragger(id,status) {
	var wind = $('#' + id);

	if (wind.find('#whiteboard').length >= 1) {
		var canvas = document.getElementById('whiteboard');
		var wb = $('#whiteboard');
		var white = wb.offset();
		white['width'] = wb.width();
		white['height'] = wb.height();
		white['centre'] = [ white['width'] / 2 + white['left'], white['height'] / 2 + white['top'] ];
		if (status == 'drag') {
			$('#marker_targeting').css({ 'left': white['centre'][0], 'top': white['centre'][1], 'position': 'fixed' }).show();
		}
		else if (status == 'stop') {
			var elements = document.elementsFromPoint(white['centre'][0], white['centre'][1]);
			$.each(elements, function(i,v) {
				if (($(v).is('video') && $(v).is(':visible'))  ) {
					var fps = $('#flipbook_interval').val();
					clearInterval(markerVideoInterval);
					v.onpause = function() {
						clearInterval(markerVideoInterval);
					};
					v.onended = function() {
						clearInterval(markerVideoInterval);
					}
					markerVideoInterval = setInterval(function() {
						// stop mirroring if the video or the whiteboard went away, and
						// don't draw offscreen while the tab is hidden
						if (!document.body.contains(v) || !document.body.contains(wb[0])) { clearInterval(markerVideoInterval); return; }
						if (document.hidden) { return; }
						var doc = markerDocSize();
						markerActiveContext().drawImage(v, 0, 0, doc.w, doc.h);
						markerComposeSoon();
					}, 1000 / fps);
				}
				else if (($(v).is('img') && $(v).is(':visible')) && ($(v).attr('id') == 'video' || $(v).hasClass('detail_image') || $(v).attr('id') == 'main_image') ) {
					var image = new Image();
					image.onload=function(){
						markerHistoryWholeLayer();
						var doc = markerDocSize();
						markerActiveContext().drawImage(image, 0, 0, doc.w, doc.h);
						markerCompose();
						markerAutosaveSoon();
					};
					image.src = $(v).attr('src');
				}
				else if (($(v).is('canvas')) && !$(v).hasClass('background')) {
					var cid = $(v).attr('id');
					var cv = document.getElementById(cid);
					var img = cv.toDataURL('image/png');
					var image = new Image();
					image.onload=function(){
						markerHistoryWholeLayer();
						var doc = markerDocSize();
						markerActiveContext().drawImage(image, 0, 0, doc.w, doc.h);
						markerCompose();
						markerAutosaveSoon();
					};
					image.src = img;
				}
				else {
					return true;
				}
			});
			$('#marker_targeting').hide();
		}
	}
}

$(document).on('click', '#marker_gallery', function() {
	var app = topWindow('marker');
	$.ajax({
		url: '/manager/marker/gallery',
		type: 'GET',
		data: { timestamp: timestamp, app: app },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});
