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
	$.each(['#configure_balloon','#mail_sidebar_container', '#soundroom_sidebar_container', '#grapple', '#search_results', '#start_menu_search_results'],function(i,v) {
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

$(document).on('click', '#start_menu_toggle', function(e) {
	// a click with no pointer travel is the keyboard's own (detail 0), and opens
	// the menu with the filter - or the selected page tab - already focused
	startMenuToggle({ detail: e.detail });
});

// A start button copied into an added bar has no id; it answers the same menu.
$(document).on('click', '.start_menu_toggle_copy', function(e) {
	e.preventDefault();
	startMenuToggle({ detail: e.detail });
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
	if ($(this).closest('#start_menu_toggle, .start_menu_toggle_copy').length) { return; }
	// a start-menu row opening an appointment beats while the window comes up
	if ($(this).hasClass('start_menu_list') && typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse($(this)); }
	if (jawnosStartMenuOpen()) {
		startMenuToggle();
	}
});

// A machine's card on the System page opens the Assistant's remote_control
// panel on that machine: the picker's value rides the render, and the setting
// is saved so the panel opens on the same peer next time. The card names the
// peer by its signatorial, which the panel resolves like a uuid or an ip.
$(document).on('click', '.remote_control_open', function() {
	var machine = $(this).attr('machine') || '';
	if (jawnosStartMenuOpen()) { startMenuToggle(); }
	if (typeof appWindowOpener === 'function') { appWindowOpener('network', Date.now(), { visible: 'yes' }); }
	// The panel opened with a machine is that row's accordion. A fresh window
	// renders after the opener, so retry once for the tab and the row.
	var open = function () {
		if (typeof networkTabShow === 'function') { networkTabShow('remote', true); }
		if (!machine) { return true; }
		var btn = $('.network_remote_toggle').filter(function () { return $(this).attr('machine') === machine; }).first();
		if (!btn.length) { return false; }
		btn.trigger('click');
		return true;
	};
	if (!open()) { setTimeout(open, 400); }
});

function startMenuToggle(data) {
	if (typeof data == 'undefined') { data = {}; }
	var source = data['source'];
	// a click the keyboard made carries no pointer detail; it opens onto the
	// filter so the person can type straight away
	var keyboard = (data['detail'] === 0);
	var st = $('#start_menu_toggle');
	var start_menu = $('#start_menu');
	var menu = localStorage.getItem('start_menu_menu') || '';
	clearTimeout(startMenuTimeout);
	if (jawnosStartMenuOpen(start_menu) && !source) {
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
			if (keyboard) { startMenuFocusInitial(); }
			return;
		}
		$.ajax({
			url: '/manager/start_menu',
			type: 'GET',
			data: { menu: menu },
			success: function(response) {
				if (response.html) {
					// The server resolves an empty menu to this install's default
					// (the app list, on a new install and afterwards), so the cache
					// and the saved choice follow what was actually drawn.
					var shown = response.menu || menu || '';
					if (shown && !localStorage.getItem('start_menu_menu')) {
						localStorage.setItem('start_menu_menu', shown);
					}
					startMenuHtml[shown] = response.html;
					startMenuRender(response.html, st);
					if (keyboard) { startMenuFocusInitial(); }
				}
			}
		});
	}
}

// Swap a menu's markup in - fresh from the server or out of the per-tab cache -
// and put the corner back together. The search may be riding the menu's header
// slot, so it is held aside over the swap: replaceWith would take it down with
// the old markup, and with it whatever was typed. There is no timer on the
// menu: it stands until something else is pressed.
function startMenuRender(html, st) {
	// Only the first open unfolds. A tab press (a fresh fetch for the same
	// panel) swaps the markup while the menu stands, and replaying the open
	// motion there reads as the whole menu opening again; an open, revealed
	// panel simply takes the new view. A panel caught mid-fold is still on its
	// way out, so that press is a fresh open and does animate.
	var was_open = jawnosStartMenuOpen($('#start_menu'));
	// The swap takes the focused node and the shelf the person had chosen with
	// it; both are read before the old markup goes and put back after the new
	// rows are built. A fresh open starts on All again; a swap while the menu
	// stands keeps the shelf and where the keyboard was.
	var focused = startMenuFocusCapture();
	var kept_category = was_open ? ($('.start_menu_category.selected').attr('category') || $('.start_menu_category[aria-selected="true"]').attr('category') || '') : '';
	var search = $('#search_entanglement').closest('#start_menu').length ? $('#search_entanglement').detach() : null;
	$('#start_menu').replaceWith(html);
	$('#start_menu').show();
	// The house search's dropdown lives on the body; a fresh menu body puts the
	// list away with the page it was drawn over.
	startMenuSearchHide();
	// a fresh body means a fresh filter: the query cannot narrow a list it was
	// not typed against
	startMenuQuery = '';
	$('#start_menu_filter').val('');
	if (search) {
		// the search rides the menu's own header slot, not the panel's foot
		var slot = $('#start_menu .start_menu_search_slot').first();
		if (slot.length) { slot.append(search); } else { $('#start_menu').append(search); }
	}
	if (typeof jawnosSearchPlace == 'function') { jawnosSearchPlace(); }
	// the menu hangs from the button that opened it
	jawnosStartMenuPlace();
	startMenuListify();
	if (kept_category) {
		startMenuSelectCategory(kept_category);
		startMenuView();
	}
	startMenuFocusRestore(focused);
	assistantIconInitializer();
	taskbarDisplayer();
	if (typeof mailDotPaint == 'function') { mailDotPaint(); }
	if (typeof ticketDotPaint == 'function') { ticketDotPaint(); }
	st.attr('toggled', 'open');
	if (!was_open) { jawnosStartMenuUnfold($('#start_menu'), st); }
}

// The recent list has changed under the menu; the kept markup carries the old
// one, so it is dropped and fetched again when it is next wanted.
function startMenuHtmlFlush() {
	startMenuHtml = {};
}

// A press anywhere but the menu - the button that opens it, or the house
// search's own dropdown - puts the menu away.
$(document).on('click', function (e) {
	var menu = $('#start_menu');
	if (!jawnosStartMenuOpen(menu)) { return; }
	if ($(e.target).closest('#start_menu, #start_menu_toggle, .start_menu_toggle_copy, #start_menu_search_results').length > 0) { return; }
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
	embedded_toggle: 'embedded', controllers_toggle: 'controllers', ticketmaker: 'box_office', cards_toggle: 'cards',
	backup_now: 'backup', security_toggle: 'security', terminal_toggle: 'terminal', network_toggle: 'network',
	ide_toggle: 'ide', image_toggle: 'gallery', camera_toggle: 'camera', phone_toggle: 'phone',
	synth_toggle: 'synth', editor_toggle: 'editor', marker_toggle: 'marker', notes_toggle: 'notes',
	clock_toggle: 'clock', home_toggle: 'home', store_toggle: 'store', process_monitor_toggle: 'process_monitor',
	// The launchers below open a window (or a window-shaped panel), so a press
	// needs an app to match its origin to; without an entry the press has no
	// app key and the press-time preview cannot claim the window. stop_all and
	// upload are actions, not apps, and are deliberately absent.
	handbook_toggle: 'handbook', help_toggle: 'help', notifications_toggle: 'notifications',
	power_toggle: 'power', sound_toggle: 'sound', packages_toggle: 'packages',
	keyboard_toggle: 'keyboard', calculator_toggle: 'calculator', weather_toggle: 'weather',
	twirl_toggle: 'twirl', pipedream_toggle: 'pipedream', minesweeper_toggle: 'minesweeper',
	scan_toggle: 'scan', studio_toggle: 'studio'
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
	var forget_label = ($('#start_menu').attr('data-forget-label') || '').trim() || 'Forget';
	main.find('img').each(function () {
		var img = $(this);
		if (img.closest('.start_menu_item').length > 0) { return; }
		// the leave and site-type buttons are absolutely placed in the top corner;
		// wrapping them in a row would move them
		if (/position\s*:\s*absolute/i.test(img.attr('style') || '')) { return; }
		var label = (img.attr('hint') || '').trim();
		var item = $('<div class="start_menu_item"></div>');
		// the row itself is a real button, so tab and Enter land on it; the icon
		// inside keeps every id, class and hint its own handler listens for
		var open = $('<button type="button" class="start_menu_item_open start_menu_list"></button>');
		if (label) { open.attr('aria-label', label); }
		// the name beside the button already reads the app, so the picture is
		// decoration to a screen reader
		img.attr('aria-hidden', 'true');
		open.append(img);
		if (label) {
			open.append($('<span class="start_menu_item_text"></span>').text(label));
		}
		item.append(open);
		// the X takes the app back off the recent list; startMenuView() shows
		// it only over the recents, and it sits apart from the row's own press
		var clear = $('<button type="button" class="start_menu_recent_clear"></button>');
		clear.attr('aria-label', (forget_label + (label ? ' ' + label : '')).trim());
		clear.text('✕');
		item.append(clear);
		// the rows are parked in the All apps group; the view moves the recents out
		var group = main.find('.start_menu_all_group');
		if (group.length) { group.append(item); } else { main.append(item); }
	});
	// lockdown keeps only the Security row and its note standing
	main.find('.start_menu_item').has('#security_toggle').addClass('start_menu_lockdown_keep');
	startMenuSort(main);
	startMenuView();
}

// The label a row reads: its own text when the template drew one, else the
// hint the icon carries. Used by the sort and by the filter.
function startMenuRowLabel(item) {
	var text = item.find('.start_menu_item_text').first().text();
	if (text && text.trim()) { return text.trim(); }
	return (item.find('img').first().attr('hint') || '').trim();
}

function startMenuSort(main) {
	main = (main && main.length) ? main : $('.start_menu_main_display');
	var group = main.find('.start_menu_all_group');
	if (!group.length) { group = main; }
	var items = group.find('.start_menu_item').get();
	if (items.length < 2) { return; }
	items.sort(function (a, b) {
		var at = startMenuRowLabel($(a)).toLowerCase();
		var bt = startMenuRowLabel($(b)).toLowerCase();
		if (at == bt) { return 0; }
		return at < bt ? -1 : 1;
	});
	$(items).appendTo(group);
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
// startMenuView() lifts those into the Recent group. A press writes the app
// back, through the server and into the attribute so the view agrees without
// waiting. The shelf showing lives on the chip itself, and a fresh menu starts
// on All.
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

// The app page opens on the whole catalogue: the recent apps first, freshest
// first, then everything else alphabetically. A shelf narrows the catalogue to
// its own, and the filter narrows it by name; either one drops both group
// labels and the recent X. The open page is the choice, so All is the default.
var startMenuQuery = '';

// What the view means by visible: the rows it hides itself carry display:none,
// and that is what decides both the empty note and the keyboard's walk.
function startMenuShown(node) {
	return node.length > 0 && node.css('display') !== 'none';
}

function startMenuView() {
	var main = $('.start_menu_main_display');
	if (main.length == 0) { return; }
	var recent_group = main.find('.start_menu_recent_group');
	var all_group = main.find('.start_menu_all_group');
	if (!all_group.length) { all_group = main; }
	var rows = main.find('.start_menu_item');
	if (rows.length == 0) {
		main.find('.start_menu_group_label').hide();
		main.find('.start_menu_empty').toggle(true);
		return;
	}
	// every row is parked and sorted in the catalogue; the recents are lifted
	// out of it below
	rows.appendTo(all_group);
	startMenuSort(main);
	var category = $('.start_menu_category.selected').attr('category') || 'all';
	var q = (typeof startMenuQuery == 'string' ? startMenuQuery : '').trim().toLowerCase();
	// only the unfiltered catalogue has a recent section
	var show_recent = (category === 'all' && !q);
	if (show_recent && recent_group.length) {
		var seen = {};
		var moved = 0;
		$.each(startMenuRecent(), function (i, key) {
			if (moved >= 5 || seen[key]) { return; }
			var row = all_group.find('.start_menu_item').filter(function () {
				return startMenuRowKey($(this)) === key;
			}).first();
			if (!row.length) { return; }
			seen[key] = true;
			row.appendTo(recent_group);
			moved++;
		});
	}
	// a row stays when it is in the chosen shelf and its name matches the filter
	rows.each(function () {
		var row = $(this);
		var visible = true;
		if (category !== 'all' && startMenuRowCategory(row) !== category) { visible = false; }
		if (visible && q && startMenuRowLabel(row).toLowerCase().indexOf(q) < 0) { visible = false; }
		row.toggle(visible);
	});
	// the X is the recents' own: a catalogue row or a shelf's rows do not wear it
	recent_group.find('.start_menu_recent_clear').show();
	all_group.find('.start_menu_recent_clear').hide();
	var recent_visible = recent_group.length ? recent_group.find('.start_menu_item').filter(function () { return startMenuShown($(this)); }).length : 0;
	var all_visible = all_group.find('.start_menu_item').filter(function () { return startMenuShown($(this)); }).length;
	recent_group.children('.start_menu_group_label').toggle(show_recent && recent_visible > 0);
	all_group.children('.start_menu_group_label').toggle(show_recent && all_visible > 0);
	main.find('.start_menu_empty').toggle((recent_visible + all_visible) === 0);
}

// The shelf the menu wears: exactly one chip is selected and says so. All is
// always a valid resting place, which is also where a second press on a chosen
// shelf lands.
function startMenuSelectCategory(category) {
	category = category || 'all';
	$('.start_menu_category').each(function () {
		var chip = $(this);
		var on = ((chip.attr('category') || 'all') === category);
		chip.toggleClass('selected', on).attr('aria-selected', on ? 'true' : 'false');
	});
}

// A press on a shelf shows it, a press on the shelf showing brings All back.
$(document).on('click', '.start_menu_category', function () {
	var chip = $(this);
	var category = chip.attr('category') || 'all';
	if (category === 'all') {
		startMenuSelectCategory('all');
	}
	else if (chip.hasClass('selected')) {
		startMenuSelectCategory('all');
	}
	else {
		startMenuSelectCategory(category);
	}
	startMenuView();
});

// The filter narrows the catalogue by name on the Apps page. The bar rides every
// page, and a page that draws no catalogue searches the house instead: the same
// index, ranking and openers as the global #search box, with the results in a
// dropdown beside the bar.
$(document).on('input', '#start_menu_filter', function () {
	var value = $(this).val() || '';
	if ($('.start_menu_main_display').length) {
		startMenuQuery = value;
		startMenuView();
		return;
	}
	startMenuSearchShow(value);
});

// The dropdown the house search draws under the bar. It is made once and kept on
// the body, like #search_results, so a menu re-render cannot take it down
// mid-search and a transformed bar cannot trap it.
function startMenuSearchBox() {
	var box = $('#start_menu_search_results');
	if (box.length) { return box; }
	box = $('<div id="start_menu_search_results" class="start_menu_search_dropdown"></div>');
	box.appendTo(document.body);
	return box;
}

function startMenuSearchHide() {
	$('#start_menu_search_results').hide();
}

// The index warms on load; paint at once when it is here, otherwise wait for it
// and drop a result a later keystroke has replaced.
function startMenuSearchShow(query) {
	var box = startMenuSearchBox();
	query = query || '';
	if (!$.trim(query) || typeof jawnosSearchMatches != 'function') { box.html('').hide(); return; }
	var paint = function () {
		if ($('#start_menu_filter').val() !== query) { return; }
		startMenuSearchPaint(query, box);
	};
	if (typeof jawnosSearchApps != 'undefined' && jawnosSearchApps) { paint(); return; }
	if (typeof jawnosSearchIndex == 'function') { jawnosSearchIndex().then(paint); }
}

function startMenuSearchPaint(query, box) {
	var matches = jawnosSearchMatches(query);
	if (!matches.length) { box.html('').hide(); return; }
	var list = $('<div class="manager_search_results_list"></div>');
	matches.forEach(function (match, i) {
		var row = $('<div class="hover manager_search_result"></div>').attr('app', match.app.app).attr('index', i);
		row.append($('<img class="manager_search_icon" alt="">').attr('src', match.app.icon || ''));
		row.append($('<span class="manager_search_label"></span>').text(jawnosSearchLabel(match)));
		list.append(row);
	});
	box.html(list).show();
	jawnosSearchResultsPlace($('#start_menu_filter'), box);
}

function startMenuSearchMove(direction) {
	var box = $('#start_menu_search_results');
	var rows = box.find('.manager_search_result');
	if (!rows.length) { return; }
	var current = parseInt(box.find('.manager_search_result.search_selected').first().attr('index'), 10);
	if (isNaN(current)) { current = direction > 0 ? -1 : rows.length; }
	var next = (current + direction + rows.length) % rows.length;
	rows.removeClass('search_selected');
	var chosen = rows.eq(next).addClass('search_selected');
	var top = chosen.position().top + box.scrollTop();
	var bottom = top + chosen.outerHeight();
	if (top < box.scrollTop()) { box.scrollTop(top); }
	else if (bottom > box.scrollTop() + box.height()) { box.scrollTop(bottom - box.height()); }
}

// The arrows walk the house search's rows, Enter opens the chosen one, and
// Escape puts the list away before the menu itself; the menu's own keydown
// handler must not see these while the list is up.
$(document).on('keydown', '#start_menu_filter', function (e) {
	if ($('.start_menu_main_display').length) { return; }
	var code = e.keyCode || e.which;
	var box = $('#start_menu_search_results');
	var shown = box.is(':visible');
	if (code == 40 || code == 38) {
		if (!shown) { startMenuSearchShow($(this).val()); shown = box.is(':visible'); }
		if (!shown) { return; }
		e.preventDefault();
		e.stopImmediatePropagation();
		startMenuSearchMove(code == 40 ? 1 : -1);
	}
	else if (code == 13) {
		if (!shown) { return; }
		var row = box.find('.manager_search_result.search_selected').first();
		if (!row.length) { return; }
		e.preventDefault();
		e.stopImmediatePropagation();
		startMenuSearchHide();
		jawnosSearchOpen(row.attr('app'));
	}
	else if (code == 27) {
		if (!shown) { return; }
		e.preventDefault();
		e.stopImmediatePropagation();
		startMenuSearchHide();
	}
});

// A press on a result opens it through the global search's own handler; the
// dropdown goes with the choice.
$(document).on('click', '#start_menu_search_results .manager_search_result', function () {
	startMenuSearchHide();
});

// What to put the keyboard back on after a swap. A menu body is replaced whole,
// so the node the person was standing on leaves with the old markup; the
// identifying bits of it are read before and matched again after.
function startMenuFocusCapture() {
	var menu = $('#start_menu');
	var active = document.activeElement;
	if (!menu.length || !active || !menu[0].contains(active)) { return null; }
	var el = $(active);
	var info = { id: active.id || '', tab: '', category: '', row: '', more: false, foot: '', item: '' };
	if (el.hasClass('start_menu_menu')) { info.tab = el.attr('menu') || ''; }
	else if (el.hasClass('start_menu_category')) { info.category = el.attr('category') || ''; }
	else if (el.hasClass('start_menu_item_open')) { info.row = startMenuRowKey(el.closest('.start_menu_item')); }
	else if (el.hasClass('start_menu_more')) { info.more = true; }
	else if (el.hasClass('start_menu_more_item')) { info.item = (el.find('img[id]').first().attr('id') || ''); }
	else if (el.hasClass('start_menu_leave_button')) { info.foot = 'start_menu_leave_button'; }
	else if (el.hasClass('start_menu_site_button')) { info.foot = 'start_menu_site_button'; }
	return info;
}

function startMenuFocusRestore(info) {
	if (!info) { return; }
	var target = $();
	if (info.category) {
		target = $('.start_menu_category').filter(function () {
			return ($(this).attr('category') || 'all') === info.category;
		}).first();
	}
	else if (info.tab) {
		target = $('.start_menu_menu').filter(function () {
			return ($(this).attr('menu') || '') === info.tab;
		}).first();
	}
	else if (info.row) {
		target = $('.start_menu_item').filter(function () {
			return startMenuRowKey($(this)) === info.row;
		}).first().find('.start_menu_item_open').first();
	}
	else if (info.more) { target = $('.start_menu_more').first(); }
	else if (info.item) {
		target = $('.start_menu_more_item').filter(function () {
			return ($(this).find('img[id]').first().attr('id') || '') === info.item;
		}).first();
	}
	else if (info.foot) { target = $('.' + info.foot).first(); }
	else if (info.id) {
		target = $(document.getElementById(info.id));
	}
	if (target && target.length) { target.first().focus(); }
}

// Opened from the keyboard: the filter is the first thing to type in, unless
// the search has taken its place, in which case the page tab is the landing.
function startMenuFocusInitial() {
	var filter = $('#start_menu_filter');
	if (startMenuShown(filter)) { filter.first().focus(); return; }
	var tab = $('.start_menu_menu[aria-selected="true"]').first();
	if (!tab.length) { tab = $('.start_menu_menu.selected').first(); }
	if (tab.length) { tab.focus(); }
}

function startMenuFocusToggle() {
	var toggle = jawnosStartMenuToggleFor($('#start_menu'));
	if (toggle.length) { toggle.first().focus(); }
}

// ---- the footer -------------------------------------------------------------
// Leave and Site are wrapper buttons around the icon that does the work: a press
// anywhere on the wrapper presses the icon, but a press on the icon itself is
// left alone so it runs once.
$(document).on('click', '.start_menu_foot', function (e) {
	if ($(this).hasClass('start_menu_more')) { return; }
	var img = $(this).find('img').first();
	if (!img.length || e.target === img[0]) { return; }
	img.trigger('click');
});

function startMenuMoreToggle(open) {
	var more = $('#start_menu_more_menu');
	if (!more.length) { return; }
	var want = (typeof open == 'boolean') ? open : !!more.prop('hidden');
	more.prop('hidden', !want);
	$('.start_menu_more').attr('aria-expanded', want ? 'true' : 'false');
}

function startMenuMoreClose() {
	startMenuMoreToggle(false);
}

// More opens over the footer and stays open until something else is pressed.
$(document).on('click', '.start_menu_more', function (e) {
	e.stopPropagation();
	startMenuMoreToggle();
});

// A More item presses its icon and puts the menu away again.
$(document).on('click', '.start_menu_more_item', function (e) {
	var img = $(this).find('img').first();
	if (img.length && e.target !== img[0]) { img.trigger('click'); }
	startMenuMoreClose();
});

// A press anywhere outside More closes it while leaving the menu standing.
$(document).on('click', function (e) {
	var more = $('#start_menu_more_menu');
	if (!more.length || more.prop('hidden')) { return; }
	if ($(e.target).closest('.start_menu_more, #start_menu_more_menu').length) { return; }
	startMenuMoreClose();
});

// ---- the keyboard -----------------------------------------------------------
// Escape shuts More first, then the menu; the arrows walk the page row, the
// category row and the app rows, and Home/End jump to the ends of the app rows.
function startMenuFocusStep(list, current, dir) {
	var items = list.get();
	if (!items.length) { return; }
	var i = $.inArray(current[0], items);
	if (i < 0) { i = 0; }
	i = (i + dir + items.length) % items.length;
	$(items[i]).focus();
}

$(document).on('keydown', function (e) {
	var menu = $('#start_menu');
	if (!jawnosStartMenuOpen(menu)) { return; }
	var target = $(e.target);
	var inside = target.closest('#start_menu').length > 0;
	var on_toggle = target.closest('#start_menu_toggle, .start_menu_toggle_copy').length > 0;
	if (!inside && !on_toggle) { return; }
	var key = e.key || '';
	var code = e.keyCode || 0;
	var escape = (key === 'Escape' || key === 'Esc' || code === 27);
	if (escape) {
		e.preventDefault();
		var more = $('#start_menu_more_menu');
		if (more.length && !more.prop('hidden')) { startMenuMoreClose(); return; }
		$('#start_menu_toggle').attr('toggled', 'closed');
		startMenuCloser(0);
		if (inside) { startMenuFocusToggle(); }
		return;
	}
	if (!inside) { return; }
	// the two horizontal rows step their own tablist
	var chip = target.closest('.start_menu_menu, .start_menu_category');
	if (chip.length) {
		var left = (key === 'ArrowLeft' || code === 37);
		var right = (key === 'ArrowRight' || code === 39);
		if (left || right) {
			e.preventDefault();
			startMenuFocusStep(chip.closest('[role="tablist"]').find('.start_menu_menu, .start_menu_category'), chip, right ? 1 : -1);
			return;
		}
	}
	// the app rows walk the visible list, top to bottom
	var row = target.closest('.start_menu_item_open');
	if (row.length) {
		var rows = $('#start_menu .start_menu_item_open').filter(function () {
			return startMenuShown($(this).closest('.start_menu_item'));
		});
		var step = null;
		if (key === 'ArrowDown' || code === 40) { step = 1; }
		else if (key === 'ArrowUp' || code === 38) { step = -1; }
		else if (key === 'Home') { e.preventDefault(); rows.first().focus(); return; }
		else if (key === 'End') { e.preventDefault(); rows.last().focus(); return; }
		if (step !== null) {
			e.preventDefault();
			var i = rows.index(row);
			var next = Math.max(0, Math.min(rows.length - 1, i + step));
			if (next >= 0 && rows.length) { rows.eq(next).focus(); }
		}
	}
});

// the menu ships inside the page as well as over the socket, so do it once at load
$(function () { startMenuListify(); });

// ---- the panel's own motion -------------------------------------------------
// The menu is placed by taskbar.js and its markup is the server's; the only
// thing added here is the unfold. A desk with the effects off, or one that asked
// for reduced motion, never gets the class - it shows and hides as it always
// did. Every motion is a transform and an opacity on the panel, so nothing in
// the layout or the placement maths sees it.

// Longer than any level's open or fold; a ceiling, not the duration. The class
// must not outlive its animation (a throttled tab may never fire animationend).
var jawnosMenuMotionCeiling = 500;

function jawnosStartMenuMotionOn() {
	return (typeof jawnosWindowMotionAllowed == 'function') && jawnosWindowMotionAllowed();
}

// Open means visible and not already folding: a panel caught mid-fold is on its
// way out, so a press on the toggle is a fresh open, not another close.
function jawnosStartMenuOpen(menu) {
	menu = (menu && menu.length) ? menu : $('#start_menu');
	return menu.is(':visible') && !menu.hasClass('jawnos_menu_fold');
}

// Pure: which way the panel unfolds and from where, in its own box. `below` is
// true when it hangs under its button - a top bar, or the corner above a bottom
// one - so a top bar unfolds downward from the panel's top edge and a bottom bar
// upward from its foot. `x` is the button's centre as a fraction of the panel's
// width; the origin is clamped inside the panel so a button past its edge still
// reads as the corner it came from.
function jawnosStartMenuOrigin(below, x) {
	x = (x === null || x === undefined || !isFinite(x)) ? 0 : x;
	x = Math.max(0, Math.min(1, x));
	return {
		x: Math.round(x * 100),
		y: below ? 0 : 100,
		dy: below ? -6 : 6
	};
}

// The button the panel answered: the primary one when it is on screen, the copy
// an added bar carries otherwise (taskbar.js places the menu from the same pair).
function jawnosStartMenuToggleFor(menu) {
	var toggle = $('#start_menu_toggle').filter(':visible').first();
	if (!toggle.length) { toggle = $('.start_menu_toggle_copy:visible').first(); }
	return toggle;
}

function jawnosStartMenuMotionCancel(menu) {
	var el = menu && menu[0];
	if (!el) { return; }
	if (el.jawnosMenuTimer) { clearTimeout(el.jawnosMenuTimer); el.jawnosMenuTimer = null; }
	menu.removeClass('jawnos_menu_unfold jawnos_menu_fold');
	if (el.inert) { el.inert = false; }
}

// Hang the unfold's origin on the panel itself: which edge faces the button and
// how far across it the button sits. Read from the boxes the placer has just
// written, so it follows a menu that hangs over a bottom bar versus under a top
// one without asking the placer anything.
function jawnosStartMenuOriginApply(menu, toggle) {
	if (!menu.length || !toggle.length) { return; }
	var m = menu[0].getBoundingClientRect();
	var t = toggle[0].getBoundingClientRect();
	if (!(m.width > 0) || !(m.height > 0)) { return; }
	var below = m.top >= (t.top + (t.height / 2));
	var origin = jawnosStartMenuOrigin(below, ((t.left + (t.width / 2)) - m.left) / m.width);
	var style = menu[0].style;
	style.setProperty('--jm-origin-x', origin.x + '%');
	style.setProperty('--jm-origin-y', origin.y + '%');
	style.setProperty('--jm-menu-dy', origin.dy + 'px');
}

// The panel unfolding out of its button. Called after the render has shown and
// placed it, so the first frame is the open size at the open place: the click
// target is there from the first frame, the motion only paints it in.
function jawnosStartMenuUnfold(menu, st) {
	menu = (menu && menu.length) ? menu : $('#start_menu');
	if (!menu.length) { return; }
	jawnosStartMenuMotionCancel(menu);
	if (!jawnosStartMenuMotionOn()) { return; }
	var toggle = (st && st.length) ? st.filter(':visible').first() : $();
	if (!toggle.length) { toggle = jawnosStartMenuToggleFor(menu); }
	jawnosStartMenuOriginApply(menu, toggle);
	var el = menu[0];
	void el.offsetWidth;   // a re-open must start the keyframes again
	menu.addClass('jawnos_menu_unfold');
	el.jawnosMenuTimer = setTimeout(function () {
		el.jawnosMenuTimer = null;
		menu.removeClass('jawnos_menu_unfold');
	}, jawnosMenuMotionCeiling);
}

// The fast reverse. The panel takes no pointer while it leaves, so a press can
// never land on a menu that is already going, and it is hidden at the end - a
// closed menu is as unfocusable as it was before there was any motion.
function jawnosStartMenuFold(menu, st) {
	menu = (menu && menu.length) ? menu : $('#start_menu');
	if (!menu.length) { return; }
	if (!menu.is(':visible')) { jawnosStartMenuMotionCancel(menu); menu.hide(); return; }
	jawnosStartMenuMotionCancel(menu);
	if (!jawnosStartMenuMotionOn()) { menu.hide(); return; }
	var toggle = (st && st.length) ? st.filter(':visible').first() : $();
	if (!toggle.length) { toggle = jawnosStartMenuToggleFor(menu); }
	jawnosStartMenuOriginApply(menu, toggle);
	var el = menu[0];
	var done = false;
	var finish = function () {
		if (done) { return; }
		done = true;
		if (el.jawnosMenuTimer) { clearTimeout(el.jawnosMenuTimer); el.jawnosMenuTimer = null; }
		menu.off('animationend', onend);
		menu.removeClass('jawnos_menu_fold');
		menu.hide();
		el.inert = false;
	};
	var onend = function (ev) {
		// a child's own animation bubbles; only the panel's fold ends the close
		if (ev.target !== el) { return; }
		finish();
	};
	if (el.inert !== undefined) { el.inert = true; }
	menu.addClass('jawnos_menu_fold');
	menu.on('animationend', onend);
	el.jawnosMenuTimer = setTimeout(finish, jawnosMenuMotionCeiling);
}

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
				startMenuSearchHide();
				jawnosStartMenuFold(start_menu, st);
			}
			else {
				startMenuCloser(7000);
			}
		}
	},wait);
}

// The System card is live while it is on screen: a phone plugged in a moment
// ago must show its new state without waiting for the next utility push. Poll
// it on a ten-second timer - long enough that the card is not itself work the
// machine has to do, short enough that a sync's rows and time left read as
// live - and skip the swap when the markup has not changed, so the card does
// not flicker every refresh. The route also tells the server's levels loop the
// card is on screen, so the house pass runs on its quick cadence.
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
	htopViewerTimer = setTimeout(function() { htopViewer(); }, 10000);
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

// A DOS card in the games shelf opens the browser player: a desk and a phone
// have no DOSBox of their own, so the same game runs in js-dos. The row press
// is recorded by the list itself; windowMaker replaces an earlier player
// window rather than stacking a second one.
$(document).on('click', '.dos_game_toggle', function () {
	var id = $(this).attr('data-game');
	if (!id) { return; }
	$.ajax({
		url: '/manager/games/play',
		type: 'GET',
		data: { id: id, timestamp: Date.now() },
		success: function (response) {
			if (typeof windowMaker === 'function') { windowMaker(response); }
		},
		error: function () {
			var said = (typeof jawnosT === 'function') ? jawnosT('The game could not be opened.') : 'The game could not be opened.';
			if (typeof jawnosAlertText === 'function') { jawnosAlertText(said); }
		}
	});
});
