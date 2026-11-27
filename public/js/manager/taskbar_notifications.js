// The taskbar's notifications widget: a bell that carries how many notices
// arrived since the list was last opened. A press hangs the shared taskbar
// panel under it with the newest notices and a search box; the footer opens
// the Notifications app. The reading is a small JSON route, so the widget does
// not pull the whole list into the page on every poll.
// The "seen" mark is one value for the house, not one per browser: a notice
// read on the phone is read on the laptop too. The server keeps it on the
// house row and every machine's status poll reads it back.
var jawnosNotificationsTaskbarData = { notifications: [], seen: 0 };
var jawnosNotificationsTaskbarSeeded = false;

// A house that has never opened the list has no mark yet. Start it at now, so
// the history that predates the bell is not counted as a hundred unread
// notices; the first load then writes that moment to the house row.
function jawnosNotificationsTaskbarSeen() {
	var seen = parseInt(jawnosNotificationsTaskbarData.seen, 10) || 0;
	return seen > 0 ? seen : Date.now();
}

function jawnosNotificationsTaskbarMarkSeen(seen) {
	var at = parseInt(seen, 10) || Date.now();
	if (at > (parseInt(jawnosNotificationsTaskbarData.seen, 10) || 0)) {
		jawnosNotificationsTaskbarData.seen = at;
	}
	// The route answers with the house's mark: another machine may have seen
	// more than this one, and that later moment wins.
	$.ajax({
		url: '/manager/notifications/seen',
		type: 'POST',
		data: { seen: at },
		success: function(response) {
			var stored = parseInt(response && response.seen, 10) || 0;
			if (stored > 0) {
				jawnosNotificationsTaskbarData.seen = stored;
				jawnosNotificationsTaskbarPaint();
			}
		}
	});
}

// The first machine to open the bell establishes the house mark, so the notices
// that predate it are history rather than a badge that never clears.
function jawnosNotificationsTaskbarSeed() {
	if (jawnosNotificationsTaskbarSeeded) { return; }
	jawnosNotificationsTaskbarSeeded = true;
	jawnosNotificationsTaskbarMarkSeen(Date.now());
}

function jawnosNotificationsTaskbarUnread() {
	var list = (jawnosNotificationsTaskbarData && jawnosNotificationsTaskbarData.notifications) || [];
	var seen = jawnosNotificationsTaskbarSeen();
	var count = 0;
	for (var i = 0; i < list.length; i++) {
		if ((parseInt(list[i].timestamp, 10) || 0) > seen) { count++; }
	}
	return count;
}

function jawnosNotificationsTaskbarWhen(timestamp) {
	var at = parseInt(timestamp, 10) || 0;
	if (!at) { return ''; }
	var when = new Date(at);
	var now = new Date();
	if (when.toDateString() == now.toDateString()) {
		return when.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
	}
	return when.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

function jawnosNotificationsTaskbarPaint() {
	var widget = $('#taskbar_notifications');
	if (!widget.length) { return; }
	var unread = jawnosNotificationsTaskbarUnread();
	widget.attr('unread', unread);
	widget.attr('title', jawnosT('Notifications') + (unread ? ' — ' + unread + ' ' + jawnosT('new') : ''));
	widget.find('.taskbar_notifications_badge').text(unread > 99 ? '99+' : String(unread));
	widget.find('.taskbar_notifications_text').text(unread > 0 ? String(unread) : '');
	widget.removeAttr('hidden').show();
	jawnosNotificationsTaskbarPanelRefresh();
}

function jawnosNotificationsTaskbarLoad() {
	if (!$('#taskbar_notifications').length) { return; }
	if (typeof document !== 'undefined' && document.hidden) { return; }
	$.ajax({
		url: '/manager/notifications/status',
		type: 'GET',
		cache: false,
		success: function(response) {
			jawnosNotificationsTaskbarData = (response && response.notifications) ? response : { notifications: [], seen: 0 };
			if (!(parseInt(jawnosNotificationsTaskbarData.seen, 10) > 0)) { jawnosNotificationsTaskbarSeed(); }
			jawnosNotificationsTaskbarPaint();
		},
		error: function() { jawnosNotificationsTaskbarPaint(); }
	});
}

// ------------------------------------------------------------------ panel

function jawnosNotificationsTaskbarFill(panel) {
	var query = String(panel.find('.taskbar_panel_search').val() || '').toLowerCase();
	var list = panel.find('.taskbar_notifications_panel_list').empty();
	var rows = (jawnosNotificationsTaskbarData.notifications || []).slice(0, 20);
	var shown = 0;
	for (var i = 0; i < rows.length; i++) {
		var notice = rows[i] || {};
		var title = String(notice.title || '');
		var message = String(notice.message || '');
		if (query && (title + ' ' + message).toLowerCase().indexOf(query) < 0) { continue; }
		shown++;
		var row = $('<div class="taskbar_notifications_row" role="button" tabindex="0"></div>')
			.attr('data-app', notice.app || '')
			.attr('data-timestamp', notice.timestamp || '');
		row.append($('<b></b>').text(title || jawnosT('Notifications')));
		if (message) { row.append($('<span class="taskbar_notifications_message"></span>').text(message)); }
		var when = jawnosNotificationsTaskbarWhen(notice.timestamp);
		if (when) { row.append($('<span class="taskbar_notifications_when"></span>').text(when)); }
		list.append(row);
	}
	if (!shown) {
		list.append($('<div class="taskbar_panel_empty"></div>').text(
			query ? jawnosT('No notifications match.') : jawnosT('No notifications')
		));
	}
}

function jawnosNotificationsTaskbarPanelBuild(panel) {
	panel.empty();
	var head = $('<div class="taskbar_panel_section"></div>');
	head.append($('<input type="search">').addClass('taskbar_panel_search')
		.attr('placeholder', jawnosT('Search notifications'))
		.attr('aria-label', jawnosT('Search notifications')));
	panel.append(head);
	panel.append($('<div class="taskbar_panel_scroll taskbar_notifications_panel_list"></div>'));
	var footer = $('<div class="taskbar_panel_footer"></div>');
	footer.append($('<button type="button" class="taskbar_panel_open"></button>')
		.attr('data-app', 'notifications')
		.text(jawnosT('Open Notifications')));
	panel.append(footer);
	jawnosNotificationsTaskbarFill(panel);
}

function jawnosNotificationsTaskbarPanelRefresh() {
	if (typeof jawnosTaskbarPanelIsOpen !== 'function' || !jawnosTaskbarPanelIsOpen('taskbar_notifications_panel')) { return; }
	jawnosNotificationsTaskbarFill($('#taskbar_notifications_panel'));
}

$(document).on('click', '.taskbar_widget[widget="notifications"]', function() {
	if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
	if (typeof jawnosTaskbarPanelToggle !== 'function') { return; }
	var open = typeof jawnosTaskbarPanelIsOpen === 'function' && jawnosTaskbarPanelIsOpen('taskbar_notifications_panel');
	jawnosTaskbarPanelToggle('taskbar_notifications_panel', $(this), jawnosNotificationsTaskbarPanelBuild);
	if (!open) {
		// Opening the list is how the count is cleared; the app marks it too.
		jawnosNotificationsTaskbarMarkSeen();
		jawnosNotificationsTaskbarPaint();
		jawnosNotificationsTaskbarLoad();
	}
});

$(document).on('input', '#taskbar_notifications_panel .taskbar_panel_search', function() {
	jawnosNotificationsTaskbarFill($(this).closest('#taskbar_notifications_panel'));
});

// A row in the panel is a door too: the press closes the panel and opens the
// appointment window the notice names, the same window the app's list opens.
$(document).on('click', '#taskbar_notifications_panel .taskbar_notifications_row', function() {
	jawnosTaskbarPanelClose();
	if (typeof jawnosNotificationOpener === 'function') {
		jawnosNotificationOpener($(this).attr('data-app'), $(this).attr('data-timestamp'));
	}
});

$(function() {
	setTimeout(jawnosNotificationsTaskbarLoad, 2200);
	setInterval(jawnosNotificationsTaskbarLoad, 60000);
});
