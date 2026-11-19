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
		// the point is taken after the pan, so the readout follows the new view
		markerStatusMoved(markerPointerEvent(e));
		return;
	}
	// the status bar, the brush ring and the ruler ticks follow every move;
	// 04_stage.js gates the readout by frame
	var point = markerPointerEvent(e);
	markerStatusMoved(point);
	// only the pointer that started the stroke may add to it - a palm or a
	// second finger dragging past must not paint
	if (markerStroke.drawing && (markerStroke.pointer_id == undefined || e.pointerId == markerStroke.pointer_id)) {
		// a stylus reports several points between two frames: drawing all of them
		// keeps the line smooth, and markerPointerMove already batches the repaint
		var moves = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
		if (!moves || moves.length == 0) { moves = [e]; }
		for (var i = 0; i < moves.length; i++) {
			markerPointerMove(markerPointerEvent(moves[i]));
		}
	}
	else if (!markerStroke.drawing && localStorage.getItem('marker_tool') == 'kb') { markerKeyboardPointer(point); }
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
	// nothing is being drawn, so neither the ring nor the readout follows the
	// pointer off the canvas
	if (markerStroke.drawing) { return; }
	if (typeof markerSelection !== 'undefined' && markerSelection.drag) { return; }
	markerBrushCursorHide();
	markerStatusPointer(undefined);
}

// the input dropped the pointer (a pen out of range, the window going away):
// finish the stroke as an up would, then let the ring go with it
function markerPointerCancel(e) {
	markerPointerUp(e);
	if (markerStroke.drawing) { return; }
	if (typeof markerSelection !== 'undefined' && markerSelection.drag) { return; }
	markerBrushCursorHide();
	markerStatusPointer(undefined);
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
	canvas.addEventListener('pointercancel', markerPointerCancel);
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
		// the selection, the cached canvas box and the ring belong to the canvas
		// that went away with the old window
		if (typeof markerSelectionReset === 'function') { markerSelectionReset(); }
		markerCanvasBoxForget();
	}
	// the visible canvas follows the window (and the rails); the layers are the
	// document and keep their own size, so resizing or zooming never resamples
	// the art
	markerToolboxApply();
	markerWheelModeApply();
	markerZoomDisplay();
	// the stage sizes the rulers and the overlay, applies the rails and installs
	// the resize observer and the slider readouts
	markerStageInit();
	markerCanvasResize();
	if (markerLayers.length == 0) {
		markerLayers.push(markerFirstLayer());
		markerLayerActive = 0;
	}
	markerLastPoint = undefined;
	markerPreview = undefined;
	// the brush sliders are read once here, so a pointer move never reads them
	markerSettingsLoad();
	var doc = markerDocSize();
	if (canvas.width > 0 && (doc.w != canvas.width || doc.h != canvas.height)) { markerViewFit(); }
	markerToolSetup();
	markerBindCanvas(canvas);
	markerLayerList();
	markerCompose();
	markerStageRefresh();
	// last: a restored session's layer sizes become the document, and its
	// callback in marker.js refreshes the stage again once they have
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
		// the swatch and its button share a cell, so remove the cell rather than
		// whichever element happens to follow the button
		var cell = $(this).closest('.marker_colour_cell');
		if (cell.length > 0) { cell.remove(); }
		$('.marker_colour[uuid="' + uuid + '"]').remove();
		$('.marker_colour_remove[uuid="' + uuid + '"]').remove();
		$('.marker_colour').each(function(i,v) { $(v).attr('status', 'inactive') });
		var last = $('.marker_colour').last();
		if (last.length > 0) {
			last.attr('status', 'active');
			marker.selected_marker_colour = last.val();
			marker.selected_marker_colour_uuid = last.attr('uuid');
		}
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
	if (['pencil','brush','spray','blur','fill','kb','sample','select','lasso','move'].indexOf(tool) == -1) { tool = 'pencil'; }
	localStorage.setItem('marker_tool', tool);
	localStorage.setItem('marker_erase', erase ? 'on' : 'off');
	$('.marker_tool[tool]').removeClass('selected');
	$('.marker_tool[tool="' + tool + '"]').addClass('selected');
	// a selection tool has no brush to ring; a brush's ring comes back on the
	// next move over the canvas
	if (tool == 'select' || tool == 'lasso' || tool == 'move') { markerBrushCursorHide(); }
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
	var tool = $(this).attr('tool');
	if (!tool) { return; }
	localStorage.setItem('marker_tool', tool);
	// the highlights and the brush ring follow the click at once
	markerToolSetup();
});

$(document).on('click', '.marker_erase_toggle', function() {
	var erase = !(localStorage.getItem('marker_erase') == 'on');
	localStorage.setItem('marker_erase', erase ? 'on' : 'off');
	markerToolEraseDisplay(erase);
});

// ---- layer panel -------------------------------------------------------

$(document).on('click', '.marker_layer_row', function() {
	var index = numeral($(this).attr('index')).value();
	markerLayerActive = index;
	markerLayerList();
	if (typeof markerStatusRefresh === 'function') { markerStatusRefresh(); }
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
	jawnosPrompt('Layer name', layer.name, function (name) {
		if (name) {
			layer.name = name;
			markerLayerList();
			if (typeof markerStatusRefresh === 'function') { markerStatusRefresh(); }
		}
	});
});

$(document).on('click', '.marker_layer_add', function() {
	markerHistoryPush(markerStructureRecord());
	markerLayers.push(markerNewLayer());
	markerLayerActive = markerLayers.length - 1;
	markerLayerList();
	if (typeof markerStatusRefresh === 'function') { markerStatusRefresh(); }
	markerCompose();
	markerAutosaveSoon();
});

$(document).on('click', '.marker_layer_delete', function() {
	var layer = markerActiveLayer();
	if (markerLayers.length <= 1 || !layer) { return; }
	jawnosConfirm('Delete layer: ' + layer.name + '?', function() {
		markerHistoryPush(markerStructureRecord());
		markerLayers.splice(markerLayerActive, 1);
		markerLayerActive = Math.min(markerLayerActive, markerLayers.length - 1);
		markerLayerList();
		if (typeof markerStatusRefresh === 'function') { markerStatusRefresh(); }
		markerCompose();
		markerAutosaveSoon();
	});
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
	if (typeof markerStatusRefresh === 'function') { markerStatusRefresh(); }
	markerCompose();
	markerAutosaveSoon();
});

// the palette's transforms act on the layer selected in the list above, not on
// the whole drawing - the number box is shared, exactly like the palette's
$(document).on('click', '.marker_transform', function() {
	markerLayerTransform($(this).attr('duty'), $('.marker_transform_input').val());
});

// ---- undo / redo / sessions -------------------------------------------

$(document).on('click', '.marker_undo', function() { markerUndo(); });
$(document).on('click', '.marker_redo', function() { markerRedoStep(); });

$(document).on('click', '.marker_new_board', function() {
	jawnosConfirm('Start a new drawing?', function() {
		markerLayers = [markerNewLayer('Layer 1')];
		markerLayerActive = 0;
		markerSessionUuid = undefined;
		markerSessionName = undefined;
		markerHistoryClear();
		markerLayerList();
		if (typeof markerStatusRefresh === 'function') { markerStatusRefresh(); }
		markerCompose();
		// a new board should not come back from the working copy either
		markerAutosaveDirty = true;
		markerAutosaveNow();
	});
});

$(document).on('click', '.marker_zoom_in', function() { markerZoomCentre(1.25); });
$(document).on('click', '.marker_zoom_out', function() { markerZoomCentre(1 / 1.25); });
$(document).on('click', '.marker_zoom_fit', function() { markerViewFit(); });
$(document).on('click', '#marker_toolbox_hide', function() { markerToolboxToggle(true, 'left'); });
$(document).on('click', '#marker_toolbox_show', function() { markerToolboxToggle(false, 'left'); });
$(document).on('click', '#marker_toolbox_right_hide', function() { markerToolboxToggle(true, 'right'); });
$(document).on('click', '#marker_toolbox_right_show', function() { markerToolboxToggle(false, 'right'); });
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

// the sessions panel is fetched from the server, so wait for its container to
// appear before filling it
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
	var c = p.closest('#marker_toolbox').find('.flipbook_interval').val();
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
	// the saved blob keeps the keys it always had; the two slider numbers come
	// from the cached settings, not from the DOM
	var info = {
		tool: localStorage.getItem('marker_tool'),
		transparency: (marker.selected_marker_transparency == undefined ? 1 : marker.selected_marker_transparency),
		colour: $('.marker_colour').first().val() || 'navy',
		size: marker.selected_marker_size,
		flipbook_interval: $('#flipbook_interval').val()
	};
	return info;
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
	var list = $('#portfolio');
	list.html('');
	if (!portfolio) { portfolio = []; }
	// newest first, so the drawing just saved is the first one in the rail
	portfolio = portfolio.sort(function(a, b) {
		return b['timestamp'] - a['timestamp'];
	});
	$.each(portfolio, function(i, v) {
		var files = [];
		try { files = JSON.parse(v.file) || []; } catch (err) { files = []; }
		$.each(files, function(ir, vr) {
			if (vr['type'] != 'image') { return; }
			// the delete handler and the click-to-load handler both read these
			// attributes, so the button and the picture carry the same ones
			var remove = $('<button class="marker_delete">D</button>');
			remove.attr('app_uuid', v['uuid']).attr('file_uuid', vr['uuid']).attr('app', v['app']).attr('timestamp', v['timestamp']);
			var image = $('<img class="paper">');
			image.attr('app_uuid', v['uuid']).attr('file_uuid', vr['uuid']).attr('app', v['app']).attr('timestamp', v['timestamp']);
			image.attr('src', '/file_open?file=' + encodeURIComponent(vr['f']) + '&timestamp=' + encodeURIComponent(vr['server_time']));
			list.append(remove);
			list.append(image);
		});
	});
	if (list.children().length == 0) { list.html('<i>nothing saved yet</i>'); }
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
						// stop mirroring if the video went away, and don't draw
						// offscreen while the tab is hidden
						if (!document.body.contains(v)) { clearInterval(markerVideoInterval); return; }
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
			jawnosAlert(response.html);
		}
	});
});
