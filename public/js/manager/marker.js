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
var markerStroke = { drawing: false, saved: false, spraying: false, x: 0, y: 0, tool: 'pencil', erase: false, size: 20, colour: 'black', alpha: 1 };

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
	whiteboard_ctx.save();
	whiteboard_ctx.globalAlpha = 1;
	whiteboard_ctx.globalCompositeOperation = 'source-over';
	whiteboard_ctx.clearRect(0, 0, canvas.width, canvas.height);
	for (var i = 0; i < markerLayers.length; i++) {
		if (markerLayers[i].visible) { whiteboard_ctx.drawImage(markerLayers[i].canvas, 0, 0); }
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
	var count = Math.max(1, Math.round(markerStroke.size * 0.8));
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
			visited[row + i] = 1;
			var offset = (row + i) * 4;
			data[offset] = fr;
			data[offset + 1] = fg;
			data[offset + 2] = fb;
			data[offset + 3] = fa;
			if (py > 0 && !visited[(py - 1) * w + i] && markerFillMatch(data, ((py - 1) * w + i) * 4, tr, tg, tb, ta, tolerance)) { stack.push((py - 1) * w + i); }
			if (py < h - 1 && !visited[(py + 1) * w + i] && markerFillMatch(data, ((py + 1) * w + i) * 4, tr, tg, tb, ta, tolerance)) { stack.push((py + 1) * w + i); }
		}
	}
	layer.ctx.putImageData(image, 0, 0);
	markerCompose();
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
	var x = e.clientX, y = e.clientY;
	if (e.touches && e.touches.length > 0) { x = e.touches[0].clientX; y = e.touches[0].clientY; }
	else if (e.changedTouches && e.changedTouches.length > 0) { x = e.changedTouches[0].clientX; y = e.changedTouches[0].clientY; }
	x = x - rect.left;
	y = y - rect.top;
	if (rect.width > 0 && rect.width != canvas.width) { x = x * (canvas.width / rect.width); }
	if (rect.height > 0 && rect.height != canvas.height) { y = y * (canvas.height / rect.height); }
	return { x: x, y: y };
}

function markerKeyboardPointer(pos) {
	localStorage.setItem('whiteboard_position', '{ "x": "' + pos.x + '", "y": "' + pos.y + '"}');
	var wb = $('#whiteboard').offset();
	$('#pointer').css({ 'top': pos.y + wb['top'] - 12, 'left': pos.x + wb['left'] });
}

function markerSampleColour(pos) {
	var canvas = document.getElementById('whiteboard');
	var ctx = canvas.getContext('2d');
	var imgData = ctx.getImageData(Math.floor(pos.x), Math.floor(pos.y), 1, 1);
	var r = imgData.data[0].toString(16).padStart(2, '0');
	var g = imgData.data[1].toString(16).padStart(2, '0');
	var b = imgData.data[2].toString(16).padStart(2, '0');
	var colour = '#' + r + g + b;
	$('.marker_colour[uuid="' + marker.selected_marker_colour_uuid + '"]').val(colour);
	marker.selected_marker_colour = colour;
}

function markerPointerDown(pos) {
	markerSettings();
	var tool = markerStroke.tool;
	if (tool == 'kb') { markerKeyboardPointer(pos); return; }
	if (tool == 'sample') { markerSampleColour(pos); return; }
	if (tool == 'fill') { markerFloodFill(pos.x, pos.y); return; }
	var ctx = markerActiveContext();
	ctx.save();
	markerStroke.saved = true;
	ctx.globalAlpha = markerStroke.alpha;
	ctx.lineCap = 'round';
	ctx.lineJoin = 'round';
	ctx.lineWidth = markerStroke.size * 2;
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
	markerStroke.drawing = true;
	markerStroke.x = pos.x;
	markerStroke.y = pos.y;
	if (tool == 'pencil') {
		// a dot, so a single click still leaves a mark
		ctx.beginPath();
		ctx.moveTo(pos.x, pos.y);
		ctx.lineTo(pos.x + 0.01, pos.y);
		ctx.stroke();
	}
	else if (tool == 'brush') {
		var sprite = markerBrushSprite(markerStroke.size, markerStroke.colour, markerStroke.alpha, 0.35);
		ctx.drawImage(sprite, pos.x - sprite.width / 2, pos.y - sprite.height / 2);
	}
	else if (tool == 'spray') {
		markerSprayBurst(ctx, pos.x, pos.y);
		if (!markerStroke.spraying) { markerStroke.spraying = requestAnimationFrame(markerSprayTick); }
	}
	markerComposeSoon();
}

function markerPointerMove(pos) {
	if (!markerStroke.drawing) { return; }
	markerSettings();
	var ctx = markerActiveContext();
	var tool = markerStroke.tool;
	var x0 = markerStroke.x, y0 = markerStroke.y;
	if (tool == 'pencil') {
		ctx.beginPath();
		ctx.moveTo(x0, y0);
		ctx.lineTo(pos.x, pos.y);
		ctx.stroke();
	}
	else if (tool == 'brush') {
		var sprite = markerBrushSprite(markerStroke.size, markerStroke.colour, markerStroke.alpha, 0.35);
		var distance = Math.sqrt((pos.x - x0) * (pos.x - x0) + (pos.y - y0) * (pos.y - y0));
		var spacing = Math.max(1, markerStroke.size / 4);
		var steps = Math.min(200, Math.floor(distance / spacing) + 1);
		for (var i = 1; i <= steps; i++) {
			var t = i / steps;
			ctx.drawImage(sprite, x0 + (pos.x - x0) * t - sprite.width / 2, y0 + (pos.y - y0) * t - sprite.height / 2);
		}
	}
	else if (tool == 'spray') {
		markerSprayBurst(ctx, pos.x, pos.y);
	}
	markerStroke.x = pos.x;
	markerStroke.y = pos.y;
	markerComposeSoon();
}

function markerEndStroke() {
	if (markerStroke.spraying) { cancelAnimationFrame(markerStroke.spraying); markerStroke.spraying = false; }
	if (!markerStroke.drawing) { return; }
	markerStroke.drawing = false;
	if (markerStroke.saved) {
		markerActiveContext().restore();
		markerStroke.saved = false;
	}
	markerCompose();
}

function markerMouseDown(e) {
	if (e.button !== 0) { return; }
	e.preventDefault();
	markerPointerDown(markerPointerEvent(e));
}

function markerMouseMove(e) {
	window.mouse = e;
	if (markerStroke.drawing) { markerPointerMove(markerPointerEvent(e)); }
	else if (localStorage.getItem('marker_tool') == 'kb') { markerKeyboardPointer(markerPointerEvent(e)); }
}

function markerTouchStart(e) {
	e.preventDefault();
	markerPointerDown(markerPointerEvent(e));
}

function markerTouchMove(e) {
	e.preventDefault();
	markerPointerMove(markerPointerEvent(e));
}

function markerTouchEnd(e) {
	e.preventDefault();
	markerEndStroke();
}

// native listeners (rather than delegated ones) so touch can be non-passive
// and preventDefault actually stops the page scrolling while drawing
function markerBindCanvas(canvas) {
	if (markerBoundCanvas === canvas) { return; }
	markerBoundCanvas = canvas;
	canvas.addEventListener('mousedown', markerMouseDown);
	canvas.addEventListener('mousemove', markerMouseMove);
	canvas.addEventListener('mouseup', markerEndStroke);
	canvas.addEventListener('mouseleave', markerEndStroke);
	canvas.addEventListener('touchstart', markerTouchStart, { passive: false });
	canvas.addEventListener('touchmove', markerTouchMove, { passive: false });
	canvas.addEventListener('touchend', markerTouchEnd, { passive: false });
	canvas.addEventListener('touchcancel', markerTouchEnd, { passive: false });
	canvas.addEventListener('contextmenu', function(e) { e.preventDefault(); });
}

function markerResizeLayers(w, h) {
	for (var i = 0; i < markerLayers.length; i++) {
		markerLayers[i].canvas.width = w;
		markerLayers[i].canvas.height = h;
	}
}

function markerInit(whiteboard) {

	if (whiteboard == undefined) {
		whiteboard = 'whiteboard';
	}
	var canvas = document.getElementById(whiteboard);
	if (!canvas) { return; }
	var win = $(canvas).closest('.wind');
	var width = Math.floor(win.width() - win.find('#marker_toolbox').width());
	var height = Math.floor(win.height() - win.find('.top_navbar').height());
	whiteboard_ctx = canvas.getContext('2d');

	// a different canvas element means a brand new window, so start fresh
	if (markerCanvas !== canvas) {
		markerCanvas = canvas;
		markerLayers = [];
		markerLayerActive = 0;
		markerSprites = {};
	}
	if (width > 0 && height > 0 && (canvas.width !== width || canvas.height !== height)) {
		canvas.width = width;
		canvas.height = height;
		markerResizeLayers(width, height);
	}
	if (markerLayers.length == 0) {
		markerLayers.push(markerNewLayer('Layer 1'));
		markerLayerActive = 0;
	}
	clearInterval(markerVideoInterval);
	markerToolSetup();
	markerBindCanvas(canvas);
	markerLayerList();
	markerCompose();
}

$(document).on('click', '.marker_stylus_toggle', function() {
	var toggle = $(this).attr('toggle');
	if (toggle == 'on') {
		toggle = 'off';
	} else {
		toggle = 'on';
	}
	$(this).attr('toggle', toggle);
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
	layer.visible = !layer.visible;
	markerLayerList();
	markerCompose();
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
	markerLayers.push(markerNewLayer());
	markerLayerActive = markerLayers.length - 1;
	markerLayerList();
	markerCompose();
});

$(document).on('click', '.marker_layer_delete', function() {
	var layer = markerActiveLayer();
	if (markerLayers.length <= 1 || !layer) { return; }
	if (!confirm('Delete layer: ' + layer.name + '?')) { return; }
	markerLayers.splice(markerLayerActive, 1);
	markerLayerActive = Math.min(markerLayerActive, markerLayers.length - 1);
	markerLayerList();
	markerCompose();
});

$(document).on('click', '.marker_layer_up', function() {
	if (markerLayerActive >= markerLayers.length - 1) { return; }
	markerSwapLayers(markerLayerActive, markerLayerActive + 1);
});

$(document).on('click', '.marker_layer_down', function() {
	if (markerLayerActive <= 0) { return; }
	markerSwapLayers(markerLayerActive, markerLayerActive - 1);
});

$(document).on('click', '.marker_layer_front', function() {
	if (markerLayerActive >= markerLayers.length - 1) { return; }
	var layer = markerLayers.splice(markerLayerActive, 1)[0];
	markerLayers.push(layer);
	markerLayerActive = markerLayers.length - 1;
	markerLayerList();
	markerCompose();
});

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
	var img = canvas.toDataURL('image/png');
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
		ctx.save();
		ctx.globalAlpha = numeral($('#marker_transparency').val() || 1).value();
		ctx.drawImage(image,0,0,canvas.width,canvas.height);
		ctx.restore();
		markerCompose();
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
		ctx.save();
		ctx.globalAlpha = numeral($('#marker_transparency').val() || 1).value();
		ctx.drawImage(image,0,0,canvas.width,canvas.height);
		ctx.restore();
		markerCompose();
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
						markerActiveContext().drawImage(v, 0, 0, white['width'], white['height']);
						markerComposeSoon();
					}, 1000 / fps);
				}
				else if (($(v).is('img') && $(v).is(':visible')) && ($(v).attr('id') == 'video' || $(v).hasClass('detail_image') || $(v).attr('id') == 'main_image') ) {
					var image = new Image();
					image.onload=function(){
						markerActiveContext().drawImage(image,0,0,white['width'], white['height']);
						markerCompose();
					};
					image.src = $(v).attr('src');
				}
				else if (($(v).is('canvas')) && !$(v).hasClass('background')) {
					var cid = $(v).attr('id');
					var cv = document.getElementById(cid);
					var img = cv.toDataURL('image/png');
					var image = new Image();
					image.onload=function(){
						markerActiveContext().drawImage(image,0,0,white['width'], white['height']);
						markerCompose();
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
