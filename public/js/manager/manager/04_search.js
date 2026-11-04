$(document).on('click', '.renew_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	var warranty = $('#ticket_warranty').val();
	$.ajax({
		url: '/manager/renew_ticket',
		data: { timestamp: timestamp, uuid: uuid, warranty: warranty },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			},1000);
		}
	});
});

$(document).on('click', '.reinstate_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	
	$.ajax({
		url: '/manager/reinstate_ticket',
		data: { timestamp: timestamp, uuid: uuid },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			},1000);
		}

	});

});

$(document).on('change', '#ticket_network_device', function() {
	var t = $(this);
	var ip = t.find('option[value="' + t.val() + '"]').attr('ip');
	$('#ticket_network_ip').text(ip);
	$('#ticket_network_meta').text(t.find('option:selected').text());
});


var searchingTimeout;
var lastSearchTime;
var jawnosSearchApps = null;
var jawnosSearchVersion = '';
var jawnosSearchLoading = null;
var jawnosSearchChecking = false;
var jawnosSearchSelected = -1;
var jawnosSearchEnterConsumed = false;

// The searchable app list. Every keystroke is filtered here, so the box never
// waits on a request. A force fetch replaces the list; otherwise the copy the
// page already has is good until the version check says it is not.
function jawnosSearchIndex(force) {
	if (jawnosSearchApps && !force) { return $.Deferred().resolve(jawnosSearchApps).promise(); }
	if (jawnosSearchLoading) { return jawnosSearchLoading; }
	jawnosSearchLoading = $.ajax({ url: '/manager/search_index', type: 'GET', dataType: 'json', cache: false, timeout: 20000 })
		.then(function (response) {
			jawnosSearchApps = (response && response.apps) ? response.apps : [];
			jawnosSearchVersion = (response && response.version) || '';
			jawnosSearchLoading = null;
			return jawnosSearchApps;
		}, function () {
			jawnosSearchLoading = null;
			return jawnosSearchApps || [];
		});
	return jawnosSearchLoading;
}

// Take the list again after a change and redraw the open dropdown, keeping the
// row the person had walked to when it survived the change.
function jawnosSearchRefresh() {
	return jawnosSearchIndex(true).then(function () {
		var current = $('#search').val();
		if (!current || !$('#search_results').is(':visible')) { return; }
		var selected_app = $('#manager_search_results .manager_search_result.search_selected').attr('app');
		jawnosSearchRender(current);
		if (selected_app) {
			var keep = $('#manager_search_results .manager_search_result').filter(function () {
				return $(this).attr('app') === selected_app;
			});
			if (keep.length) {
				jawnosSearchSelected = parseInt(keep.attr('index'), 10);
				keep.addClass('search_selected');
			}
		}
	});
}

// The cheap question: has any setting the list draws (or a deleted app) moved?
// The full list only crosses the wire when the answer is yes.
function jawnosSearchCheck() {
	if (!jawnosSearchApps || jawnosSearchChecking) { return; }
	jawnosSearchChecking = true;
	var xhr = $.ajax({ url: '/manager/search_index', type: 'GET', dataType: 'json', cache: false, data: { check: 1 } });
	xhr.done(function (response) {
		if (response && response.version && response.version !== jawnosSearchVersion) {
			jawnosSearchRefresh();
		}
	});
	xhr.always(function () { jawnosSearchChecking = false; });
}

// Warm the list while the manager settles, so the first keypress has it. Then
// watch for changes: on the box being focused, on returning to the tab, and
// every two seconds while the dropdown is open, so a deleted app leaves the
// list and a changed pos or main image lands without a reload.
$(function () {
	var warm = function () { jawnosSearchIndex(); };
	if (window.requestIdleCallback) { requestIdleCallback(warm, { timeout: 4000 }); }
	else { setTimeout(warm, 1500); }
	$(document).on('focusin', '#search', jawnosSearchCheck);
	$(window).on('focus', jawnosSearchCheck);
	if (document.addEventListener) {
		document.addEventListener('visibilitychange', function () {
			if (!document.hidden) { jawnosSearchCheck(); }
		});
	}
	setInterval(function () {
		if ($('#search_results').is(':visible') && $('#search').val()) { jawnosSearchCheck(); }
	}, 2000);
});

function jawnosSearchPlain(s) {
	return (s || '').toLowerCase().replace(/_/g, ' ').replace(/\s+/g, ' ').trim();
}

function jawnosSearchClicks() {
	var stored = {};
	try { stored = JSON.parse(localStorage.getItem('jawnos_search_clicks') || '{}') || {}; }
	catch (e) { stored = {}; }
	return stored;
}

// Enter belongs to a chosen result for exactly one press: the input also wears
// timed_input, whose own Enter adds/opens the typed name, and that must not
// fire on the same key. Typing again clears the choice (and the claim).
function jawnosSearchTakeEnter() {
	if (!jawnosSearchEnterConsumed) { return false; }
	jawnosSearchEnterConsumed = false;
	return true;
}

// The list puts what was opened from it most recently at the top, so the app a
// person reaches for keeps coming back under the box.
function jawnosSearchRecordClick(app) {
	var clicks = jawnosSearchClicks();
	// names may be any printable string, so prefix the key: an app called
	// "__proto__" must be stored as an ordinary entry, not as the object's prototype
	clicks['a:' + app] = Date.now();
	var keys = Object.keys(clicks);
	if (keys.length > 200) {
		keys.sort(function (a, b) { return clicks[a] - clicks[b]; });
		keys.slice(0, keys.length - 200).forEach(function (k) { delete clicks[k]; });
	}
	try { localStorage.setItem('jawnos_search_clicks', JSON.stringify(clicks)); } catch (e) {}
}

function jawnosSearchMatches(query) {
	var raw = jawnosSearchPlain(query);
	if (!raw || !jawnosSearchApps) { return []; }
	var words = raw.split(' ');
	var clicks = jawnosSearchClicks();
	var matches = [];
	jawnosSearchApps.forEach(function (app) {
		var name = jawnosSearchPlain(app.app);
		var label = jawnosSearchPlain(app.name);
		var haystack = name + ' ' + label;
		for (var i = 0; i < words.length; i++) {
			if (haystack.indexOf(words[i]) < 0) { return; }
		}
		// an exact name beats a prefix, which beats a name the words appear in
		var exact = (name === raw || label === raw) ? 0 : 1;
		var prefix = (name.indexOf(raw) === 0 || label.indexOf(raw) === 0) ? 0 : 1;
		var click_key = 'a:' + app.app;
		var clicked = Object.prototype.hasOwnProperty.call(clicks, click_key) ? clicks[click_key] : 0;
		matches.push({ app: app, rank: exact * 2 + prefix, clicked: clicked });
	});
	matches.sort(function (a, b) {
		if (a.rank != b.rank) { return a.rank - b.rank; }
		if (!!a.clicked != !!b.clicked) { return a.clicked ? -1 : 1; }
		if (a.clicked != b.clicked) { return b.clicked - a.clicked; }
		return jawnosSearchPlain(a.app.name).localeCompare(jawnosSearchPlain(b.app.name));
	});
	return matches.slice(0, 10);
}

// The dropdown hugs the search box: same width, just above or below it. It is
// pulled out to the body because a transformed ancestor (an auto-hidden
// taskbar, a sliding dock) turns position:fixed into a child of that bar, which
// is what put the list off the top of the screen.
function jawnosSearchResultsPlace() {
	var box = $('#search_results');
	var input = $('#search');
	if (!box.length || !input.length || !box.is(':visible')) { return; }
	var rect = input[0].getBoundingClientRect();
	var vw = window.innerWidth || $(window).width();
	var vh = window.innerHeight || $(window).height();
	// The visible page, not the layout viewport: a phone's or tablet's platform
	// keyboard shrinks the visual viewport without changing window.innerHeight,
	// so a list measured against the latter is drawn under the keys. JawnOS's own
	// keyboard is a fixed element in the page instead, so its top comes from its
	// height rather than its (still transformed) edge.
	var view_top = 0;
	var view_bottom = vh;
	if (window.visualViewport && window.visualViewport.height) {
		view_top = Math.max(0, window.visualViewport.offsetTop || 0);
		view_bottom = Math.min(view_bottom, view_top + window.visualViewport.height);
	}
	var kb = $('#jawn_soft_keyboard');
	if (kb.length && kb.is(':visible')) {
		// the keyboard measured its own top edge for the lift; use that edge, not
		// its layout height, so the list sits on what the person sees
		var kb_lift = 0;
		try {
			kb_lift = parseFloat(window.getComputedStyle(document.body).getPropertyValue('--soft_kb_h')) || 0;
		} catch (err) { kb_lift = 0; }
		if (!(kb_lift > 0)) { kb_lift = kb.outerHeight() || 0; }
		var kb_top = vh - kb_lift;
		if (kb_top > 0 && kb_top < view_bottom) { view_bottom = kb_top; }
	}
	var gap = 6;
	var width = Math.max(0, rect.width);
	var left = Math.max(4, Math.min(rect.left, vw - width - 4));
	var content = $('#manager_search_results').outerHeight() || 0;
	// A box that rides the dock's foot can itself be behind the platform
	// keyboard. There is no room beside it then, so the list hooks onto the
	// keyboard's top edge instead of running under it.
	var input_visible = rect.top < view_bottom;
	var below = view_bottom - rect.bottom - gap;
	var above = (input_visible ? rect.top : view_bottom) - view_top - gap;
	// below is the natural side; go above only when it has more room
	var place_below = input_visible && (below >= Math.min(content, 80) || below >= above);
	var height = Math.max(0, Math.min(content, place_below ? below : above));
	var drop = {
		'position': 'fixed',
		'left': left,
		'width': width,
		'height': height,
		'right': 'auto',
		// the keyboard sits at 40002: it always paints over the list
		'z-index': 40001,
		'border-width': '3px',
		'text-align': 'center'
	};
	if (place_below) {
		drop['top'] = rect.bottom + gap;
		drop['bottom'] = 'auto';
	}
	else {
		drop['bottom'] = vh - (input_visible ? rect.top : view_bottom) + gap;
		drop['top'] = 'auto';
	}
	box.css(drop);
}

// The platform keyboard slides in and out without a window resize, so the list
// has to follow the visual viewport as well.
function jawnosSearchResultsReposition() {
	if ($('#search_results').is(':visible')) { jawnosSearchResultsPlace(); }
}

$(window).on('resize orientationchange', jawnosSearchResultsReposition);
if (window.visualViewport) {
	window.visualViewport.addEventListener('resize', jawnosSearchResultsReposition);
	window.visualViewport.addEventListener('scroll', jawnosSearchResultsReposition);
}

// The details list's Dur column ticks while a session is open: the row carries
// its start, stop and duration, and the same two-unit shape duration_sayer
// gives is rebuilt here (1h 5s, 59m 59s, 1d 1m). The short form is not fixed to
// one denomination: it turns over to days once there is a whole day, then to
// months and years, carrying the next smaller unit beside it.
function jawnosDurationText(seconds, mode) {
	seconds = Math.max(0, Math.floor(Number(seconds) || 0));
	var h = Math.floor(seconds / 3600);
	var m = Math.floor((seconds % 3600) / 60);
	var s = seconds % 60;
	if (mode == 'hours') {
		return h + 'h' + (m ? ' ' + m + 'm' : '');
	}
	if (mode == 'minutes') {
		return Math.floor(seconds / 60) + 'm' + (s ? ' ' + s + 's' : '');
	}
	var days = seconds / 86400;
	var month_days = 30.4375;
	var months = Math.floor((days + 0.5) / month_days);
	if (h < 24) {
		var parts = [];
		if (h) { parts.push(h + 'h'); }
		if (m) { parts.push(m + 'm'); }
		if (s) { parts.push(s + 's'); }
		return parts.length ? parts.slice(0, 2).join(' ') : '0s';
	}
	if (months < 1) {
		var dd = Math.floor(seconds / 86400);
		var dh = Math.floor((seconds % 86400) / 3600);
		var dm = Math.floor((seconds % 3600) / 60);
		var bits = [ dd + 'd' ];
		if (dh) { bits.push(dh + 'h'); }
		if (dm) { bits.push(dm + 'm'); }
		return bits.slice(0, 2).join(' ');
	}
	var years = Math.floor(months / 12);
	var leftover_months = months % 12;
	var leftover_days = Math.max(0, Math.floor(days - months * month_days));
	var units = [];
	if (years > 0) { units.push(years + 'y'); }
	if (leftover_months > 0) { units.push(leftover_months + 'M'); }
	if (leftover_days > 0) { units.push(leftover_days + 'd'); }
	return units.length ? units.join(' ') : '0s';
}

// The span a duration element stands for: an open session grows from its start,
// a closed row keeps the duration the server worked out (falling back to its own
// start and stop), and a plain readout carries its own `duration`. `sign` keeps
// a shortfall reading as a shortfall.
function jawnosDurationSpan(cell, now) {
	now = now || Date.now();
	var ms;
	var sign = cell.attr('sign') == '-' ? '-' : '';
	if (cell.hasClass('appointment_detail_duration')) {
		var type = cell.attr('appt_type') || '';
		var start = Number(cell.attr('timestamp')) || 0;
		var stop = Number(cell.attr('stop_timestamp')) || 0;
		if (!stop && (type == 'start' || type == 'record')) {
			if (!start || start > now) { return null; }
			ms = now - start;
		}
		else {
			ms = Math.abs(Number(cell.attr('duration')) || 0);
			if (!ms && stop && start) { ms = Math.abs(stop - start); }
			if (!ms) { return null; }
		}
		sign = '';
	}
	else {
		ms = Math.abs(Number(cell.attr('duration')) || 0);
		if (!ms) { return null; }
	}
	return { ms: ms, sign: sign };
}

function jawnosDurationTick() {
	// A hidden page cannot paint a duration, and a locked phone was paying for
	// this walk every second in the background. appointment_chron repaints on
	// the way back in.
	if (document.hidden) { return; }
	var now = Date.now();
	$('.appointment_detail_duration, .jawnos_duration').each(function () {
		var cell = $(this);
		var span = jawnosDurationSpan(cell, now);
		if (!span) { return; }
		var display = cell.closest('.wind').attr('app') || '';
		var mode = durationDisplaySaved(display) || 'dynamic';
		var text = span.sign + jawnosDurationText(span.ms / 1000, mode);
		if (cell.text() !== text) { cell.text(text); }
	});
}

$(function () {
	// the one shared second tick (universal.js) paints the duration readouts
	// beside the appointment clocks instead of a second interval walking them
	if (typeof jawnos_tick_register === 'function') {
		jawnos_tick_register('duration', jawnosDurationTick);
	}
	jawnosDurationTick();
});

function jawnosSearchRender(query) {
	var box = $('#search_results');
	if (!box.length) { return; }
	jawnosSearchEnterConsumed = false;
	var matches = jawnosSearchMatches(query);
	jawnosSearchSelected = -1;
	if (matches.length == 0) {
		box.html('').hide();
		return;
	}
	var list = $('<div id="manager_search_results"></div>');
	matches.forEach(function (match, i) {
		var row = $('<div class="hover manager_search_result"></div>').attr('app', match.app.app).attr('index', i);
		row.append($('<img class="manager_search_icon" alt="">').attr('src', match.app.icon || ''));
		row.append($('<span class="manager_search_label"></span>').text(match.app.name || match.app.app));
		list.append(row);
	});
	// leave any transformed bar behind so the fixed coordinates are the viewport's
	if (box.parent()[0] !== document.body) { box.appendTo(document.body); }
	box.html(list).show();
	jawnosSearchResultsPlace();
}

function jawnosSearchMove(direction) {
	var rows = $('#manager_search_results .manager_search_result');
	if (!rows.length) { return; }
	if (jawnosSearchSelected < 0) {
		jawnosSearchSelected = direction > 0 ? 0 : rows.length - 1;
	}
	else {
		jawnosSearchSelected = (jawnosSearchSelected + direction + rows.length) % rows.length;
	}
	rows.removeClass('search_selected');
	var chosen = rows.eq(jawnosSearchSelected).addClass('search_selected');
	var box = $('#search_results');
	if (chosen.length && box.length) {
		var row_top = chosen.position().top + box.scrollTop();
		var row_bottom = row_top + chosen.outerHeight();
		if (row_top < box.scrollTop()) { box.scrollTop(row_top); }
		else if (row_bottom > box.scrollTop() + box.height()) { box.scrollTop(row_bottom - box.height()); }
	}
}

// A built-in app opens through the same toggle the menu uses; anything else is
// an appointment and opens through its centre view.
function jawnosSearchOpen(app) {
	if (!app) { return; }
	jawnosSearchRecordClick(app);
	$('#search_results').hide();
	$('#start_menu').hide();
	if (typeof pseudonymHomeHider == 'function') { pseudonymHomeHider(pseudonymHIntervals); }
	// the common apps have a direct opener, so the real app opens even on a
	// layout where the menu's own button is not in the document
	var openers = { music: 'musicToggle', help: 'helpOpener', mailbox: 'mailMaker' };
	if (Object.prototype.hasOwnProperty.call(openers, app) && typeof window[openers[app]] == 'function') {
		window[openers[app]]();
		return;
	}
	var special = {
		configure: '#main_logo.configuration',
		budget: '#budget',
		box_office: '#ticketmaker',
		gallery: '#image_toggle',
		market: '.market_toggle',
		warehouse: '.warehouse_toggle',
		process_monitor: '.process_monitor_toggle',
		measures: '.measures_toggle'
	};
	var special_toggle = Object.prototype.hasOwnProperty.call(special, app) ? special[app] : '';
	var toggle = special_toggle ? $(special_toggle) : $(document.getElementById(app + '_toggle'));
	if (toggle.length) { toggle.trigger('click'); return; }
	if (typeof appointmentGrabber == 'function') { appointmentGrabber(app, Date.now()); }
}

$(document).on('input keyup click', '#search', function(e) {
	var search = $(this).val();
	var timestamp = Date.now();
	lastSearchTime = timestamp;
	clearTimeout(searchingTimeout);
	searchingTimeout = setTimeout(function() {
		$('#search').val('');
		$('#search_results').hide();
		jawnosSearchSelected = -1;
	}, 5000 * 60);
	// the arrow keys, Enter and Escape belong to the keydown handler; keyup for
	// them must not redraw the list and drop the selection it just made
	if (e.type == 'keyup') {
		if (e.keyCode == 13) {
			// a chosen result owns this Enter; the timed_input add/reset must not run
			if (jawnosSearchTakeEnter()) {
				e.preventDefault();
				e.stopImmediatePropagation();
			}
			return;
		}
		if (e.keyCode == 38 || e.keyCode == 40 || e.keyCode == 27) { return; }
		// typing again makes the next Enter the box's own
		jawnosSearchEnterConsumed = false;
	}
	else if (e.type == 'input') {
		// an input method (the Android keyboard, a composition) commits text
		// without a keyup; the list must still follow what the box holds
		jawnosSearchEnterConsumed = false;
	}
	if (!search) {
		$('#search_results').hide();
		jawnosSearchSelected = -1;
		return;
	}
	jawnosSearchIndex().then(function () {
		if ($('#search').val() == search) { jawnosSearchRender(search); }
	});
});

$(document).on('keydown', '#search', function(e) {
	var code = e.keyCode || e.which;
	var box = $('#search_results');
	var shown = box.is(':visible');
	if (code == 40 || code == 38) {
		if (!shown) { jawnosSearchRender($(this).val()); shown = box.is(':visible'); }
		if (!shown) { return; }
		e.preventDefault();
		jawnosSearchMove(code == 40 ? 1 : -1);
	}
	else if (code == 13) {
		// Enter only belongs to the list once a result has been chosen with the
		// arrows; otherwise the box keeps its own Enter (the add/reset)
		if (!shown || jawnosSearchSelected < 0) { return; }
		var rows = $('#manager_search_results .manager_search_result');
		if (!rows.length) { return; }
		e.preventDefault();
		jawnosSearchEnterConsumed = true;
		jawnosSearchOpen(rows.eq(jawnosSearchSelected).attr('app'));
	}
	else if (code == 27) {
		if (shown) {
			e.preventDefault();
			box.hide();
			jawnosSearchSelected = -1;
		}
	}
});

$(document).on('mouseenter', '.manager_search_result', function() {
	var i = parseInt($(this).attr('index'), 10);
	if (isNaN(i)) { return; }
	jawnosSearchSelected = i;
	$('#manager_search_results .manager_search_result').removeClass('search_selected');
	$(this).addClass('search_selected');
});

