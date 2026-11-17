// The Notifications app: the house's own list, with the search and app filter
// the keyboard's notifications panel already uses. Both read the same server
// helper and the same search/filter endpoints, so a search typed in one is the
// search the other shows.
function notificationsOpener(timestamp, done) {
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
			if (typeof done === 'function') { done(); }
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

// --- Views ---------------------------------------------------------------
// Main holds the list the app has always shown; Appointments configures which
// appointments announce notifications. Switching is a class/attribute change,
// never a page load, so an open window keeps its scroll and its search.
function notificationsAppShowView(view) {
	if (view !== 'appointments') { view = 'main'; }
	$('[data-notifications-view-panel]').each(function() {
		var mine = $(this).attr('data-notifications-view-panel') === view;
		$(this).prop('hidden', !mine);
	});
	$('.notifications_app_tab').each(function() {
		var mine = $(this).attr('data-notifications-view') === view;
		$(this).toggleClass('is-active', mine).attr('aria-selected', mine ? 'true' : 'false');
	});
}

$(document).on('click', '.notifications_app_tab', function() {
	notificationsAppShowView($(this).attr('data-notifications-view') || 'main');
});

// --- Appointments view ---------------------------------------------------
// The template embeds formatted name -> app for the candidates the backend
// allows; a typed name resolves through it, and anything else is refused here.
function notificationsAppApptLookup(name) {
	var map = window.jawnos_notification_appt_by_name || {};
	name = $.trim(name || '');
	if (!name) { return null; }
	if (Object.prototype.hasOwnProperty.call(map, name)) { return map[name]; }
	var lower = name.toLowerCase();
	for (var key in map) {
		if (Object.prototype.hasOwnProperty.call(map, key) && key.toLowerCase() === lower) { return map[key]; }
	}
	return null;
}

function notificationsAppApptNote(text) {
	$('#notifications_app_appt_note').text(text || '');
}

function notificationsAppApptRefresh() {
	if (typeof notificationsOpener !== 'function') { return; }
	// The refreshed window is drawn with Main selected; draw the person's own view
	// again once new markup is in, so adding or turning off does not move them.
	notificationsOpener(Date.now(), function() { notificationsAppShowView('appointments'); });
}

function notificationsAppApptTurnOn() {
	var input = $('#notifications_app_appt_add');
	var name = $.trim(input.val() || '');
	if (!name) {
		notificationsAppApptNote('');
		return;
	}
	var app = notificationsAppApptLookup(name);
	if (!app) {
		notificationsAppApptNote(jawnosT('Choose an appointment from the list.'));
		return;
	}
	notificationsAppApptNote('');
	Promise.resolve(settingSetter({ app: app, setting: 'notification', value: 'on' }))
		.then(function() {
			input.val('');
			notificationsAppApptRefresh();
		}, function() {
			notificationsAppApptNote(jawnosT('That could not be saved.'));
		});
}

$(document).on('change', '#notifications_app_appt_add', function() {
	notificationsAppApptTurnOn();
});

$(document).on('keydown', '#notifications_app_appt_add', function(event) {
	if (event.key === 'Enter' || event.keyCode === 13) {
		event.preventDefault();
		notificationsAppApptTurnOn();
	}
});

$(document).on('click', '.notifications_app_appt_off', function() {
	var button = $(this);
	var app = button.attr('data-app');
	if (!app || button.prop('disabled')) { return; }
	button.prop('disabled', true);
	notificationsAppApptNote('');
	Promise.resolve(settingSetter({ app: app, setting: 'notification', value: 'off' }))
		.then(function() {
			notificationsAppApptRefresh();
		}, function() {
			button.prop('disabled', false);
			notificationsAppApptNote(jawnosT('That could not be saved.'));
		});
});
