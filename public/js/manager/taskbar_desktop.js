// The taskbar's Desktop widget: the show-desktop button. A press puts every
// open window away and a second press brings back exactly the windows it put
// away - a window the person had already minimised stays minimised, and a
// window closed in the meantime is simply forgotten. The window list on the
// bar keeps every tile, so a window can still be reached while the desk is bare.
//
// The widget is core, like the other taskbar widgets: it has no app chunk and
// nothing to poll. It leans on windowMinimizer(), the same answer the title
// bar's minimise button gives, so the saved size and the tile state stay right.

// The windows this widget put away, by desk and by timestamp. A second press on
// that desk restores these and nothing else; a desk keeps its own list.
var jawnosDesktopTaskbarHidden = {};

function jawnosDesktopTaskbarBucket() {
	var ws = (typeof jawnosWorkspaceActiveId == 'function') ? jawnosWorkspaceActiveId() : 'ws-main';
	if (!jawnosDesktopTaskbarHidden[ws]) { jawnosDesktopTaskbarHidden[ws] = []; }
	return jawnosDesktopTaskbarHidden[ws];
}

// A window's timestamp is the id the window maker gave it. A window without the
// attribute falls back to that id, so even an older one goes away.
function jawnosDesktopTaskbarStamp(win) {
	var ts = win.attr('timestamp');
	if (ts) { return String(ts); }
	var id = win.attr('id') || '';
	return id.indexOf('window_') == 0 ? id.slice('window_'.length) : '';
}

function jawnosDesktopTaskbarWindows() {
	return $('.wind').filter(function() { return $(this).is(':visible'); });
}

// Paint the widget from the desk it can see: pressed while no window is up, and
// its title names the press that follows.
function jawnosDesktopTaskbarSync() {
	// Every bar carries a copy of the widget, and a copy has no id: paint them
	// all so a press on an added bar's copy reads the same state.
	var widgets = $('.taskbar_widget[widget="desktop"]');
	if (!widgets.length) { return; }
	var bare = jawnosDesktopTaskbarWindows().length == 0;
	widgets.each(function () {
		var widget = $(this);
		widget.attr('state', bare ? 'desktop' : 'windows')
			.attr('aria-pressed', bare ? 'true' : 'false')
			.attr('title', bare ? jawnosT('Show windows') : jawnosT('Show desktop'));
		widget.find('.taskbar_desktop_text').text(jawnosT('Desktop'));
		widget.removeAttr('hidden').show();
	});
}

// Every visible window goes away, remembering the ones this widget put away. A
// window the person had already hidden is not added, so their own minimise
// stands.
function jawnosDesktopTaskbarHide() {
	var bucket = jawnosDesktopTaskbarBucket();
	var seen = {};
	bucket.forEach(function(ts) { seen[ts] = 1; });
	jawnosDesktopTaskbarWindows().each(function() {
		var ts = jawnosDesktopTaskbarStamp($(this));
		if (!ts || seen[ts]) { return; }
		seen[ts] = 1;
		bucket.push(ts);
		if (typeof windowMinimizer == 'function') { windowMinimizer(ts); }
	});
}

// Bring back only the windows this widget put away. A window closed since then
// has no element and is dropped; one the person has already restored is left
// where it is.
function jawnosDesktopTaskbarShow() {
	var ws = (typeof jawnosWorkspaceActiveId == 'function') ? jawnosWorkspaceActiveId() : 'ws-main';
	var timestamps = jawnosDesktopTaskbarHidden[ws] || [];
	jawnosDesktopTaskbarHidden[ws] = [];
	timestamps.forEach(function(ts) {
		var win = $('#window_' + ts);
		if (!win.length || win.is(':visible')) { return; }
		if (typeof windowMinimizer == 'function') { windowMinimizer(ts); }
	});
}

function jawnosDesktopTaskbarToggle() {
	if (jawnosDesktopTaskbarWindows().length) { jawnosDesktopTaskbarHide(); }
	else { jawnosDesktopTaskbarShow(); }
	jawnosDesktopTaskbarSync();
}

$(document).on('click', '.taskbar_widget[widget="desktop"]', function() {
	if (typeof jawnosTaskbarEditing == 'function' && jawnosTaskbarEditing()) { return; }
	jawnosDesktopTaskbarToggle();
});

// A bar drawn after a reload carries the widget before any window settles, so
// the first paint reads the desk once more.
$(function() {
	if (typeof jawnosDesktopTaskbarSync == 'function') { jawnosDesktopTaskbarSync(); }
});
