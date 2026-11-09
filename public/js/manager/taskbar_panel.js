// One anchored panel, shared by the taskbar's network, sound and power widgets.
// The clock's own menu (#clock_nav) is the model: a fixed-position box that
// stands outside the bar, hung against the widget it belongs to, placed again
// whenever the bars move, and closed by an outside press or Escape. Only one
// widget panel is open at a time.
//
// The widget files build their own contents into the panel and keep their
// pollers; this file owns the frame, the placing and the closing. A footer
// button carrying data-app opens that app and closes the panel.
var jawnosTaskbarPanelOpenId = null;

function jawnosTaskbarPanelEnsure(id) {
	var panel = $('#' + id);
	if (!panel.length) {
		panel = $('<div></div>').attr('id', id).attr('role', 'dialog').addClass('taskbar_panel').appendTo('body');
	}
	return panel;
}

function jawnosTaskbarPanelWidgetId(panel_id) {
	return '#' + String(panel_id || '').replace(/_panel$/, '');
}

// Hang the panel against its widget: below a top bar, above a bottom bar, and
// kept inside the screen on either side. The max-height is the room left
// between the widget and the far screen edge, so a long list scrolls inside.
function jawnosTaskbarPanelPlace(panel, anchor_selector) {
	var bar = $('#taskbar');
	var anchor = $(anchor_selector || jawnosTaskbarPanelWidgetId(panel.attr('id')));
	if (!panel.length || !anchor.length || !panel.is(':visible')) { return; }
	var rect = anchor[0].getBoundingClientRect();
	var width = $(window).width();
	var height = $(window).height();
	var gap = 6;
	var panel_width = Math.min(panel.outerWidth() || 320, width - 8);
	var left = rect.right - panel_width;
	left = Math.max(4, Math.min(left, width - panel_width - 4));
	var below = (bar.attr('position') || (typeof jawnosBars != 'undefined' ? jawnosBars.taskbar : 'bottom')) != 'bottom';
	var room = below ? (height - rect.bottom - gap - 8) : (rect.top - gap - 8);
	room = Math.max(120, room);
	var place = {
		'left': Math.round(left) + 'px',
		'right': 'auto',
		'width': Math.round(panel_width) + 'px',
		'max-height': Math.round(room) + 'px'
	};
	if (below) {
		place['top'] = Math.round(rect.bottom + gap) + 'px';
		place['bottom'] = 'auto';
	}
	else {
		place['bottom'] = Math.round(height - rect.top + gap) + 'px';
		place['top'] = 'auto';
	}
	panel.css(place);
}

function jawnosTaskbarPanelIsOpen(id) {
	return jawnosTaskbarPanelOpenId == id;
}

function jawnosTaskbarPanelOpen(id, anchor_selector, build) {
	jawnosTaskbarPanelClose();
	var panel = jawnosTaskbarPanelEnsure(id);
	if (build) { build(panel); }
	panel.addClass('open').show();
	jawnosTaskbarPanelOpenId = id;
	jawnosTaskbarPanelPlace(panel, anchor_selector);
}

function jawnosTaskbarPanelClose() {
	if (!jawnosTaskbarPanelOpenId) { return; }
	$('#' + jawnosTaskbarPanelOpenId).removeClass('open').hide();
	jawnosTaskbarPanelOpenId = null;
}

function jawnosTaskbarPanelToggle(id, anchor_selector, build) {
	if (jawnosTaskbarPanelIsOpen(id)) { jawnosTaskbarPanelClose(); return; }
	jawnosTaskbarPanelOpen(id, anchor_selector, build);
}

// A panel button that opens the app the widget stands for.
$(document).on('click', '.taskbar_panel_open', function () {
	var app = $(this).attr('data-app') || '';
	if (!app) { return; }
	jawnosTaskbarPanelClose();
	if (typeof appWindowOpener === 'function') {
		appWindowOpener(app, Date.now(), { visible: 'yes' });
	}
});

$(document).on('click', function (e) {
	if (!jawnosTaskbarPanelOpenId) { return; }
	if ($(e.target).closest('.taskbar_panel').length) { return; }
	var widget = jawnosTaskbarPanelWidgetId(jawnosTaskbarPanelOpenId);
	if ($(e.target).closest(widget).length) { return; }
	jawnosTaskbarPanelClose();
});

$(document).on('keydown', function (e) {
	if (e.keyCode == 27) { jawnosTaskbarPanelClose(); }
});

$(window).on('resize', function () {
	if (!jawnosTaskbarPanelOpenId) { return; }
	var panel = $('#' + jawnosTaskbarPanelOpenId);
	jawnosTaskbarPanelPlace(panel, jawnosTaskbarPanelWidgetId(jawnosTaskbarPanelOpenId));
});
