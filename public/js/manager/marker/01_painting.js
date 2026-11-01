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
	jawnosWhiteboardSet('{ "x": "' + pos.x + '", "y": "' + pos.y + '"}');
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

