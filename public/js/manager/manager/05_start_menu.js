$(document).on('click', '.manager_search_result', function() {
	jawnosSearchOpen($(this).attr('app'));
});


$(document).on('click', '.search_toggle', function(i,e) {
	// on a side dock the input rides hidden: the first press calls it out, and
	// only a press with the input showing runs the search itself. A button that
	// rides the taskbar has its input in sight already, so it just searches.
	if (typeof jawnosSideDock == 'function' && jawnosSideDock() && $(this).closest('#pseudonym_home').length > 0 && !jawnosSideSearchVisible()) {
		jawnosSideSearchShow(1);
		return;
	}
	// The magnifier opens the Search app: one window with the Apps, Web and AI
	// contexts, remembering the last tab. The dock's box stays where it is and
	// keeps its own dropdown while typing; this press hands the query over.
	var search = $('#search').val() || '';
	localStorage.setItem('lastSearchTime', Date.now());
	localStorage.setItem('search', search);
	$('#search_results').html('').hide();
	if (typeof window.jawnosSearchAppOpen === 'function') {
		window.jawnosSearchAppOpen(search);
	}
});

$(document).on('click', '.search_engine_grabber', function() {

	var name = $(this).attr('name');
	var timestamp = Date.now();
	var search = $(this).attr('search') || $('#search').val();
	var website = $(this).attr('url') + search;
	var view = $(this).attr('view');
	$.ajax({
		url: '/manager/search_engine_grabber',
		type: 'GET',
		data: { app: name, search: search, view: view, website: website, timestamp: timestamp },
		success: function(response) {
			centreViewWriter(response);
			
		}
	});
});

$(document).on('click', '.torch_toggle', function() {
	var torch = localStorage.getItem('torch_status') || 'off';
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/torch',
		type: 'GET',
		data: { torch: torch, timestamp: timestamp },
		success: function(response) {

			localStorage.setItem('torch_status', response);
		}
	});
});




$(document).on('click','.file_toggle',function() {
	var detail = $(this).closest('.appointment_detail');
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app');
	var file = $(this).attr('file');
	var timestamp = $(this).attr('timestamp');

	$.ajax({
		url:'/manager/file_open',
		type:'GET',
		data: { file: file, timestamp: timestamp, app: app },
		success: function(response) {

			detail.find('.detail_image').attr('src', response.filepath);

		}
	});
});

$(document).on('click', '.share', function() {
	var image = $(this);
	var src = image.attr('file');
	var type = image.attr('type');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/share',
		type: 'GET',
		data: { src: src, type: type, timestamp: timestamp },
		success: function(response) {
		}
	});
});



$(document).on('click', '.fuck_you', function() {
	fuck_you();
});

var fucks = Date.now();
function fuck_you() {
	var timestamp = Date.now();
	if (timestamp < (fucks + 1000)) {
		return;
	}
	fucks = Date.now();
	var bt = $('#browser_toggle');
	$('#search').val('');
	$.each(['#left_view','.wind', '.cord', '.manager_search_result'],function(i,v) {
		$(v).remove();
	});
	$.each(['#configure_balloon','#mail_sidebar_container', '#soundroom_sidebar_container', '#grapple', '#search_results'],function(i,v) {
		$(v).hide();
	});
	$('.typewriter').remove();
	$.each(heartbeat, function(i,v) {
		clearInterval(heartbeat[i]);
	});
	websocketStop();
	mailWebSocketStop();
	inputClose();
	jpStop();
	twirlRunning = false;
	startMenuCloser(0);
	$('#taskbar_windows').html('');
	$('#time_machine').val('');
	$('#timeshift').val('');
	jawnosAlertClose();
	$('.dot').hide();
	$('.window_icon').remove();
	localStorage.setItem('timeshift', '0');
	localStorage.setItem('time_machine','');
	sessionStorage.setItem('window_storage', '{}');
	var timestamp = Date.now();
	$.each(locationWatchers, function(i,v) {
	//	continent_cancel(i);
	});
	$.ajax({
		url: '/manager/fuck_you',
		type: 'POST',
		data: { timestamp: timestamp }
	});
}

$(document).on('click', '#start_menu_toggle', function() {
	startMenuToggle();
});

$(document).on('click', '.start_menu_menu', function() {
	var menu = $(this).attr('menu');
	localStorage.setItem('start_menu_menu', menu);
	$('#start_menu').attr('toggled', 'closed');
	startMenuToggle({ source: 'menu' });
});

$(document).on('click', '.jonathan, .start_menu_list', function() {
	// the toggle answers for itself in its own handler; closing here too would
	// undo what that handler has just opened
	if ($(this).closest('#start_menu_toggle').length) { return; }
	// a start-menu row opening an appointment beats while the window comes up
	if ($(this).hasClass('start_menu_list') && typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse($(this)); }
	if ($('#start_menu').is(':visible')) {
		startMenuToggle();
	}
});

function startMenuToggle(data) {
	if (typeof data == 'undefined') { data = {}; }
	var source = data['source'];
	var st = $('#start_menu_toggle');
	var start_menu = $('#start_menu');
	var menu = localStorage.getItem('start_menu_menu') || '';
	clearTimeout(startMenuTimeout);
	if ((st.attr('toggled') == 'open' || start_menu.is(':visible')) && !source) {
		startMenuCloser(0);
		st.attr('toggled', 'closed');
		if (focused_input.is(':visible')) {
		//	focused_input.focus();
		}
	}
	else {
		// The menu's html is kept per tab: reopening a tab puts the same markup back
		// instead of fetching again. Every fetch re-stamps every icon with the moment
		// it ran, so a fresh fetch pulled every picture over again on every open - the
		// flash. A press on a tab (source 'menu') is the refresh, and always fetches.
		if (!source && startMenuHtml[menu]) {
			startMenuRender(startMenuHtml[menu], st);
			return;
		}
		$.ajax({
			url: '/manager/start_menu',
			type: 'GET',
			data: { menu: menu },
			success: function(response) {
				if (response.html) {
					// The server resolves an empty menu to this install's default
					// (the System page on a first run, the app list afterwards), so
					// the cache and the saved choice follow what was actually drawn.
					var shown = response.menu || menu || '';
					if (shown && !localStorage.getItem('start_menu_menu')) {
						localStorage.setItem('start_menu_menu', shown);
					}
					startMenuHtml[shown] = response.html;
					startMenuRender(response.html, st);
				}
			}
		});
	}
}

// Swap a menu's markup in - fresh from the server or out of the per-tab cache -
// and put the corner back together. The search may be riding the menu's corner,
// so it is held aside over the swap: replaceWith would take it down with the old
// markup, and with it whatever was typed. There is no timer on the menu: it
// stands until something else is pressed.
function startMenuRender(html, st) {
	var search = $('#search_entanglement').closest('#start_menu').length ? $('#search_entanglement').detach() : null;
	$('#start_menu').replaceWith(html);
	$('#start_menu').show();
	if (search) { $('#start_menu').append(search); }
	if (typeof jawnosSearchPlace == 'function') { jawnosSearchPlace(); }
	// the menu hangs from the button that opened it
	jawnosStartMenuPlace();
	startMenuListify();
	assistantIconInitializer();
	taskbarDisplayer();
	if (typeof mailDotPaint == 'function') { mailDotPaint(); }
	if (typeof ticketDotPaint == 'function') { ticketDotPaint(); }
	st.attr('toggled', 'open');
}

// The recent list has changed under the menu; the kept markup carries the old
// one, so it is dropped and fetched again when it is next wanted.
function startMenuHtmlFlush() {
	startMenuHtml = {};
}

// A press anywhere but the menu - or the button that opens it - puts the menu
// away.
$(document).on('click', function (e) {
	var menu = $('#start_menu');
	if (!menu.is(':visible')) { return; }
	if ($(e.target).closest('#start_menu, #start_menu_toggle').length > 0) { return; }
	$('#start_menu_toggle').attr('toggled', 'closed');
	startMenuCloser(0);
});

// The app menu ships as a wall of icons separated by <br>. Turn it into a list:
// each icon keeps its id and classes (the click handlers hang off those) and gains
// a text label from its hint, and the breaks in between go away. The rows are kept
// in alphabetical order and read icon first, so the icons line up in a column
// against the left edge. Safe to call again on the same markup.
// The built-in icons the start menu draws, keyed by the app they open. A
// private app is not drawn at all; the server sends its key in hidden_apps, and
// the icon is removed before the rows are assembled (so the recents list cannot
// put it back). A custom app is not in this grid, and its running rows are
// filtered server-side.
var startMenuIconApps = {
	internet_toggle: 'internet', search_app_toggle: 'search', folders_toggle: 'folders',
	budget: 'budget', travel_toggle: 'travel', relational_toggle: 'relational', people_toggle: 'people',
	mailbox_toggle: 'mailbox', email_toggle: 'email', chat_toggle: 'chat', music_toggle: 'music',
	embedded_toggle: 'embedded', ticketmaker: 'box_office', cards_toggle: 'cards', web_toggle: 'web',
	backup_now: 'backup', security_toggle: 'security', terminal_toggle: 'terminal', network_toggle: 'network',
	ide_toggle: 'ide', image_toggle: 'gallery', camera_toggle: 'camera', phone_toggle: 'phone',
	synth_toggle: 'synth', editor_toggle: 'editor', marker_toggle: 'marker', notes_toggle: 'notes',
	clock_toggle: 'clock', home_toggle: 'home', store_toggle: 'store', process_monitor_toggle: 'process_monitor'
};

function startMenuHidePrivate(main) {
	var hidden = (main.attr('hidden_apps') || '').split('|');
	if (!hidden.length || (hidden.length == 1 && !hidden[0])) { return; }
	$.each(startMenuIconApps, function (id, app) {
		if ($.inArray(app, hidden) < 0) { return; }
		main.find('#' + id).each(function () {
			var img = $(this);
			var row = img.closest('.start_menu_item');
			if (row.length) { row.remove(); return; }
			var parent = img.parent();
			img.remove();
			if (parent.length && !parent.children().length && !parent.text().replace(/\s+/g, '').length) { parent.remove(); }
		});
	});
}

function startMenuListify() {
	var main = $('.start_menu_main_display');
	if (main.length == 0) { return; }
	startMenuHidePrivate(main);
	main.find('br').remove();
	main.find('img').each(function () {
		var img = $(this);
		if (img.closest('.start_menu_item').length > 0) { return; }
		// the leave and site-type buttons are absolutely placed in the top corner;
		// wrapping them in a row would move them
		if (/position\s*:\s*absolute/i.test(img.attr('style') || '')) { return; }
		var label = img.attr('hint') || '';
		// start_menu_list is what the other menus use for a row that closes the menu
		var item = $('<span class="start_menu_item start_menu_list"></span>');
		// The row goes at the top level of the list even when the template wrapped the
		// icon in something else (the tickets button sits in a bare <span>). Left in
		// that wrapper it is not a child of the list, so the sort never sees it and it
		// ends up stranded above the rows that were sorted.
		main.append(item);
		// icon first so it sits on the left, name beside it
		item.append(img);
		if (label) {
			item.append($('<span class="start_menu_item_text"></span>').text(label));
		}
		// the X takes the app back off the recent list; startMenuView() shows
		// it only over the recents, and the row press steps aside for it
		item.append('<span class="start_menu_recent_clear" hint="Forget">✕</span>');
	});
	startMenuSort(main);
	startMenuView();
}

function startMenuSort(main) {
	var items = main.children('.start_menu_item').get();
	if (items.length < 2) { return; }
	items.sort(function (a, b) {
		var at = ($(a).text() || '').trim().toLowerCase();
		var bt = ($(b).text() || '').trim().toLowerCase();
		if (at == bt) { return 0; }
		return at < bt ? -1 : 1;
	});
	$(items).appendTo(main);
}
// the name is part of the button: pressing it presses the icon next to it
$(document).on('click', '.start_menu_item_text', function () {
	$(this).siblings('img').trigger('click');
});

// and so is the padding around them: a tap anywhere on the row opens the app,
// rather than landing on the gap and only closing the menu
$(document).on('click', '.start_menu_item', function (e) {
	if ($(e.target).closest('.start_menu_recent_clear').length > 0) { return; }
	// the row beats while the app it opens loads
	if (typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse($(this)); }
	startMenuUseRecord($(this));
	if ((e.target.tagName || '').toUpperCase() == 'IMG') { return; }
	if ($(e.target).hasClass('start_menu_item_text')) { return; }
	$(this).find('img').first().trigger('click');
});

// What the app menu remembers: the apps opened from it, freshest first, kept
// in the president's cache and riding on the list as its recent attribute -
// the list IS the recent list, and the shelf rail is how everything else is
// reached. A press writes the app back, through the server and into the
// attribute so the view agrees without waiting. Which shelf is showing lives
// on the rail button itself, so a fresh menu - fetched on every open - always
// starts on the recents.
function startMenuRowKey(item) {
	var img = item.find('img').first();
	return img.attr('id') || img.attr('hint') || ($.trim(item.text()) || '');
}

function startMenuRowCategory(item) {
	return item.find('img').first().attr('category') || '';
}

function startMenuRecent() {
	var said = $('.start_menu_main_display').attr('recent') || '';
	return said.length ? said.split(',') : [];
}

function startMenuUseRecord(item) {
	var key = startMenuRowKey(item);
	if (!key) { return; }
	var recent = $.grep(startMenuRecent(), function (k) { return k !== key; });
	recent.unshift(key);
	$('.start_menu_main_display').attr('recent', recent.join(','));
	startMenuHtmlFlush();
	$.ajax({ url: '/manager/start_menu/used', type: 'POST', data: { used: key } });
}

// The X on a recent item forgets the app: it must not open it, so the press
// is stopped here, the list is rewritten without the key and the view shows
// the row gone.
$(document).on('click', '.start_menu_recent_clear', function (e) {
	e.stopPropagation();
	startMenuForget(startMenuRowKey($(this).closest('.start_menu_item')));
});

function startMenuForget(key) {
	if (!key) { return; }
	var recent = $.grep(startMenuRecent(), function (k) { return k !== key; });
	$('.start_menu_main_display').attr('recent', recent.join(','));
	startMenuHtmlFlush();
	$.ajax({ url: '/manager/start_menu/forget', type: 'POST', data: { forget: key } });
	startMenuView();
}

// The shelf showing narrows the list to its own, kept alphabetical; otherwise
// the list is the recents, freshest first, and the note stands in their place
// until a press has filled it.
function startMenuView() {
	var main = $('.start_menu_main_display');
	if (main.length == 0) { return; }
	var rows = main.children('.start_menu_item');
	if (rows.length == 0) { return; }
	var category = $('.start_menu_category.selected').attr('category') || '';
	rows.show();
	if (category) {
		startMenuSort(main);
		rows.each(function () {
			if (startMenuRowCategory($(this)) !== category) { $(this).hide(); }
		});
	}
	else {
		var rank = new Map();
		$.each(startMenuRecent(), function (i, key) {
			if (!rank.has(key)) { rank.set(key, i); }
		});
		var order = [];
		rows.each(function () {
			if (rank.has(startMenuRowKey($(this)))) { order.push(this); }
			else { $(this).hide(); }
		});
		order.sort(function (a, b) { return rank.get(startMenuRowKey($(a))) - rank.get(startMenuRowKey($(b))); });
		$(order).appendTo(main);
	}
	var shown = rows.filter(function () { return $(this).css('display') != 'none'; }).length;
	main.find('.start_menu_empty').toggle(!category && shown == 0);
	rows.find('.start_menu_recent_clear').toggle(!category);
}

// A press on a shelf shows it, a press on the shelf showing brings the
// recents back; the button wears the choice, and the next open - a fresh
// menu with no shelf marked - lands on the recents again.
$(document).on('click', '.start_menu_category', function () {
	var showing = $(this).hasClass('selected');
	$('.start_menu_category').removeClass('selected');
	if (!showing) { $(this).addClass('selected'); }
	startMenuView();
});

// the menu ships inside the page as well as over the socket, so do it once at load
$(function () { startMenuListify(); });

function startMenuCloser(wait) {
	clearTimeout(startMenuTimeout);
	startMenuTimeout = setTimeout(function() {
		var start_menu = $('#start_menu');
		if ($('#start_menu').is(':visible')) {
			var m = mouse_position();
			var left = start_menu.offset().left;
			var top = start_menu.offset().top;
			var height = start_menu.height();
			var width = start_menu.width();
			if (wait == 0 || !((m.x > left && m.x < (left + width)) && (m.y > top && m.y < (top + height)))) {
				var st = $('#start_menu_toggle');
				st.attr('toggled', 'closed');
				start_menu.hide();
			}
			else {
				startMenuCloser(7000);
			}
		}
	},wait);
}

// The System card is live while it is on screen: a phone plugged in a moment
// ago must show its new state without waiting for the next utility push. Poll
// it on a short timer - the server's levels loop takes the same cue and runs
// quick passes - and skip the swap when the markup has not changed, so the
// card does not flicker every few seconds.
var htopViewerTimer = null;
var htopViewerBusy = false;
function htopViewer() {
	var card = $('#htop_viewer');
	if (document.hidden || !card.length || !card.is(':visible') || !$('#start_menu').is(':visible')) {
		htopViewerSchedule();
		return;
	}
	if (htopViewerBusy) { return; }
	htopViewerBusy = true;
	$.ajax({
		url: '/manager/start_menu/htop_viewer',
		type: 'GET',
		success: function(response) {
			var live = $('#htop_viewer');
			if (live.length && response && response.html && live[0].outerHTML !== response.html) {
				live.replaceWith(response.html);
				appointment_chron();
			}
		},
		complete: function() {
			htopViewerBusy = false;
			htopViewerSchedule();
		}
	});
}

function htopViewerSchedule() {
	clearTimeout(htopViewerTimer);
	htopViewerTimer = setTimeout(function() { htopViewer(); }, 8000);
}

$(function() { htopViewerSchedule(); });

$(document).on('click', '#browser_toggle', function() {
	var bt = $(this);
	if ($('#browser').is(':visible')) {
		$('#browser').hide();
		bt.css({'border-color': 'black' });
	} else {
		$('#browser').show();
		bt.css({'border-color': 'yellow' });
	}
});


