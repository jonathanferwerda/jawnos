// The desk background: a painted wallpaper on #desk (the canvas the clothesline
// hangs from, because a layout's rail is drawn on the layout's own canvas) and
// #desk_layer over it, holding the same .folders_file items the Folders window
// uses. Folders.js owns selection, keyboard, drag and drop and the context menu;
// this file owns the picture, the loading and the showing/hiding.

var desk_visible = false;
var desk_xhr = undefined;
var desk_paint_key = '';

function deskRefreshIfVisible() {
	if (!desk_visible) { return; }
	deskLoad();
}

function deskShow() {
	$('#desk_layer').addClass('active');
	deskPosition();
	deskPrinter();
	if (!desk_visible) {
		desk_visible = true;
		deskLoad();
	}
}

// The icons start under whatever the desk reserves above them: a top taskbar,
// and the clothesline's own band.
function deskPosition() {
	var top = (typeof windowTopLimit == 'function') ? windowTopLimit() : 0;
	$('#desk_layer').css({ 'top': (top + 8) + 'px' });
}

function deskHide() {
	desk_visible = false;
	$('#desk_layer').removeClass('active');
}

function deskLoad() {
	if (desk_xhr && desk_xhr.readyState && desk_xhr.readyState != 4) { desk_xhr.abort(); }
	desk_xhr = $.ajax({
		url: '/manager/folders/desk',
		type: 'GET',
		data: {
			unlock: $('#folders').attr('unlock') || '',
			device_uuid: (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : ''
		},
		success: function(response) {
			desk.folder = (response && response.folder) || '';
			desk.files = (response && response.files) || [];
			desk.apps = (response && response.apps) || [];
			desk.disk = (response && response.disk) || {};
			desk.selected = [];
			desk.app = undefined;
			desk.path = undefined;
			desk.type = undefined;
			desk.anchor = undefined;
			deskRender();
		}
	});
}

function deskRender() {
	var layer = $('#desk_layer');
	if (!layer.length) { return; }
	layer.empty();
	deskPosition();
	// pinned apps first: they are the fixed furniture of the desk, the files
	// behind them are what changes
	$.each(desk.apps || [], function (i, a) { layer.append(deskAppItem(a)); });
	$.each(desk.files || [], function (i, f) {
		var item = $('<div class="folders_file desk_file" tabindex="-1" role="option" aria-selected="false"></div>')
			.attr({ path: f['path'], type: f['type'], 'data-name': f['name'] });
		$('<span class="folders_thumb"></span>')
			.append($('<img draggable="false" alt="">').attr('src', f['icon'] || ''))
			.appendTo(item);
		$('<span class="folders_label"></span>').text(f['name'] || '').attr('title', f['name'] || '').appendTo(item);
		layer.append(item);
	});
	if (!(desk.apps || []).length && !(desk.files || []).length) {
		$('<div class="desk_empty"></div>').text(jawnosT('Your desktop is empty')).appendTo(layer);
	}
	foldersDraggable();
	foldersSelectionSync('desk');
}

function deskAppItem(a) {
	var item = $('<div class="folders_file desk_file desk_app" tabindex="-1" role="option" aria-selected="false"></div>')
		.attr({ app: a['app'], 'data-name': a['name'] });
	$('<span class="folders_thumb"></span>')
		.append($('<img draggable="false" alt="">').attr('src', a['icon'] || ''))
		.appendTo(item);
	$('<span class="folders_label"></span>').text(a['name'] || '').attr('title', a['name'] || '').appendTo(item);
	$('<span class="desk_shortcut_mark" aria-hidden="true">↗</span>').appendTo(item);
	return item;
}

// ---- pinned apps -----------------------------------------------------------
// The window restorer's own opener understands every built-in app, including
// the ones with no button in the document, so a shortcut uses it first.
function deskOpenApp(app) {
	if (!app) { return; }
	if (typeof appWindowOpener == 'function') { appWindowOpener(app, Date.now()); }
	else if (typeof jawnosSearchOpen == 'function') { jawnosSearchOpen(app); }
}

function deskAppPicker() {
	$.ajax({
		url: '/manager/folders/desk/apps',
		type: 'GET',
		success: function(response) {
			if (response && response['dialog']) {
				var box = $(response['dialog']).attr('state_surface', 'desk');
				$('#dialog_boxes').append(box);
				if (typeof appointment_chron == 'function') { appointment_chron(); }
			}
		}
	});
}

function deskPinsSaveList(list) {
	$.ajax({
		url: '/manager/folders/desk/apps',
		type: 'POST',
		data: { apps: JSON.stringify(list || []) },
		success: function(response) {
			if (response && response['ok']) { deskLoad(); }
		}
	});
}

function deskUnpinApp(app) {
	var list = [];
	$.each(desk.apps || [], function (i, a) {
		if (a['app'] != app) { list.push(a['app']); }
	});
	deskPinsSaveList(list);
}

// A right-click on a shortcut is its own small menu: open it, or take it off
// the desk. File items keep the full Folders menu.
function deskAppMenuRow(command, label, icon) {
	var row = $('<div class="folders_context_selection hover_showing"></div>').attr('command', command);
	if (icon) { $('<img class="miniscule_thumb" alt="">').attr('src', icon).appendTo(row); }
	$('<span style="vertical-align:top;"></span>').text(label).appendTo(row);
	return row;
}
$(document).on('contextmenu', '.desk_app', function(e) {
	e.preventDefault();
	var item = $(this);
	var app = item.attr('app');
	desk.app = app;
	desk.path = undefined;
	desk.type = undefined;
	$('#desk_layer .folders_file').removeClass('selected');
	item.addClass('selected');
	foldersSelectionSync('desk');
	var menu = $('<div class="folders_context" surface="desk"></div>')
		.css({ position: 'fixed', width: 220, background: 'var(--panel-2)' });
	menu.append(deskAppMenuRow('open_app', jawnosT('Open'), item.find('img').attr('src')));
	menu.append(deskAppMenuRow('unpin_app', jawnosT('Unpin from the desk'), '/images/decipherable/off.png'));
	$('body').append(menu);
	var margin = 6;
	var left = Math.min(e.clientX, $(window).width() - menu.outerWidth() - margin);
	var top = Math.min(e.clientY, $(window).height() - menu.outerHeight() - margin);
	menu.css({ left: Math.max(margin, left), top: Math.max(margin, top) });
});

// ---- the wallpaper ---------------------------------------------------------
function deskStyleValue(name, fallback) {
	var value = '';
	try { value = getComputedStyle(document.documentElement).getPropertyValue(name) || ''; }
	catch (e) { value = ''; }
	value = String(value).replace(/^\s+|\s+$/g, '');
	return value || fallback;
}

function deskPrinter() {
	var canvas = document.getElementById('desk');
	if (!canvas) { return; }
	$('#desk').show();
	var width = $(window).width();
	var height = $(window).height();
	if (!width || !height) { return; }
	var dark = $('body').hasClass('dark_theme');
	var panel = deskStyleValue('--panel', dark ? '#1e1e1e' : '#ffffff');
	var panel2 = deskStyleValue('--panel-2', dark ? '#262626' : '#f0f0f0');
	var ink = deskStyleValue('--ink', dark ? '#d4d4d4' : '#000000');
	var accent = '';
	try { accent = getComputedStyle(canvas).getPropertyValue('--desk-accent') || ''; }
	catch (e) { accent = ''; }
	accent = String(accent).replace(/^\s+|\s+$/g, '') || (dark ? '#6ea8fe' : '#2f6feb');
	var base = panel;
	try {
		var body_bg = $('body').css('background-color');
		if (body_bg && body_bg != 'rgba(0, 0, 0, 0)' && body_bg != 'transparent') { base = body_bg; }
	}
	catch (e) { /* the theme's panel is enough */ }

	var key = [ width, height, base, panel2, ink, accent, dark ? 'dark' : 'light',
		(localStorage.getItem('background_images') == 'on') ? 'pictures' : 'paint' ].join('|');
	if (key == desk_paint_key) { return; }
	desk_paint_key = key;

	canvas.width = width;
	canvas.height = height;
	var ctx = canvas.getContext('2d');
	ctx.clearRect(0, 0, width, height);
	// with the Background setting on, the picture is painted on #background
	// underneath; leave this canvas clear so that picture is what shows, and
	// let the clothesline draw its rail over it
	if (localStorage.getItem('background_images') == 'on') { return; }

	// the theme's own colour, warmed towards its second panel step at the top
	ctx.fillStyle = base;
	ctx.fillRect(0, 0, width, height);
	var wash = ctx.createLinearGradient(0, 0, width * 0.3, height);
	wash.addColorStop(0, panel2);
	wash.addColorStop(1, base);
	ctx.globalAlpha = 0.55;
	ctx.fillStyle = wash;
	ctx.fillRect(0, 0, width, height);
	ctx.globalAlpha = 1;

	// one broad glow in the accent, up and to the right, and a fainter one low
	// and left: enough colour to read as a wallpaper, never enough to fight an
	// icon's label
	var glow = ctx.createRadialGradient(width * 0.82, height * 0.14, 0, width * 0.82, height * 0.14, Math.max(width, height) * 0.55);
	glow.addColorStop(0, accent);
	glow.addColorStop(1, 'rgba(0,0,0,0)');
	ctx.globalAlpha = dark ? 0.30 : 0.20;
	ctx.fillStyle = glow;
	ctx.fillRect(0, 0, width, height);

	var low = ctx.createRadialGradient(width * 0.10, height * 0.92, 0, width * 0.10, height * 0.92, Math.max(width, height) * 0.45);
	low.addColorStop(0, accent);
	low.addColorStop(1, 'rgba(0,0,0,0)');
	ctx.globalAlpha = dark ? 0.14 : 0.08;
	ctx.fillStyle = low;
	ctx.fillRect(0, 0, width, height);

	// a quiet dot grid keeps the empty desk from reading as a flat sheet
	ctx.globalAlpha = dark ? 0.07 : 0.045;
	ctx.fillStyle = ink;
	var step = 28;
	for (var y = 20; y < height; y += step) {
		for (var x = 20; x < width; x += step) {
			ctx.fillRect(x, y, 1.2, 1.2);
		}
	}
	ctx.globalAlpha = 1;

	// a vignette closes the picture and settles the edges under the bars
	var vignette = ctx.createRadialGradient(width * 0.5, height * 0.45, Math.min(width, height) * 0.28, width * 0.5, height * 0.45, Math.max(width, height) * 0.78);
	vignette.addColorStop(0, 'rgba(0,0,0,0)');
	vignette.addColorStop(1, dark ? 'rgba(0,0,0,0.34)' : 'rgba(0,0,0,0.10)');
	ctx.fillStyle = vignette;
	ctx.fillRect(0, 0, width, height);
}

$(window).on('resize', function() {
	if (desk_visible) { deskPrinter(); }
});
