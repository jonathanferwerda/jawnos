// The Notifications app: the house's own list, with the search and app filter
// the keyboard's notifications panel already uses. Both read the same server
// helper and the same search/filter endpoints, so a search typed in one is the
// search the other shows.
function notificationsOpener(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/notifications',
		type: 'GET',
		data: { timestamp: timestamp, user_agent: navigator.userAgent },
		success: function(response) {
			if (!response) { return; }
			windowMaker(response);
			// Reading the list is what clears the taskbar's count.
			if (typeof jawnosNotificationsTaskbarMarkSeen === 'function') { jawnosNotificationsTaskbarMarkSeen(); }
			if (typeof jawnosNotificationsTaskbarPaint === 'function') { jawnosNotificationsTaskbarPaint(); }
		}
	});
}

function notificationsAppReplace(content) {
	$('#notifications_app_list').html(content || '');
	$('#notifications_app_note').text('');
}

function notificationsAppSearch() {
	var search = $('#notifications_app_search').val() || '';
	$.ajax({
		url: '/manager/notifications/search',
		type: 'GET',
		dataType: 'json',
		data: { search: search },
		success: function(response) { notificationsAppReplace(response && response.content); },
		error: function() { $('#notifications_app_note').text(jawnosT('The search failed.')); }
	});
}

function notificationsAppFilter() {
	var app = $('#notifications_app_filter').val() || 'all';
	$.ajax({
		url: '/manager/notifications/filter',
		type: 'GET',
		dataType: 'json',
		data: { app: app },
		success: function(response) { notificationsAppReplace(response && response.content); },
		error: function() { $('#notifications_app_note').text(jawnosT('The filter failed.')); }
	});
}

$(document).on('click', '#notifications_toggle', function() {
	notificationsOpener();
});

$(document).on('keyup', '#notifications_app_search', function() {
	notificationsAppSearch();
});

$(document).on('change', '#notifications_app_filter', function() {
	notificationsAppFilter();
});
