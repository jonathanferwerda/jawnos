// The two bars at the edges of the manager: the dock (the pseudonym row, and
// the search when it rides there) and the taskbar (the open windows - the list
// the start menu used to carry at its foot - and the clock). Which edge each
// one lives on - bottom, top or hidden - is a per-device misc setting the
// layout seeds into jawnos_bar_settings, and the search's home is its own
// setting. This file turns those settings into the attributes and the few
// custom properties the CSS and the other scripts read, and hands the other
// scripts the offsets their own maths needs.

var jawnos_bar_settings = (typeof jawnos_bar_settings != 'undefined' && jawnos_bar_settings) ? jawnos_bar_settings : {};
// A settings number whose 0 is meaningful (a border width): parseInt(...) || default
// would turn a stored 0 back into the default, so read it explicitly.
function jawnosBarSettingNumber(key, fallback) {
	var raw = jawnos_bar_settings[key];
	if (raw === undefined || raw === null || raw === '') { return fallback; }
	var v = parseInt(raw, 10);
	return isNaN(v) ? fallback : v;
}
var jawnosBars = {
	dock: jawnos_bar_settings['dock_position'] || 'bottom',
	taskbar: jawnos_bar_settings['taskbar_position'] || 'bottom',
	search: jawnos_bar_settings['search_placement'] || 'dock',
	start_side: jawnos_bar_settings['start_button_side'] || 'right',
	icons: jawnos_bar_settings['dock_icons'] || 'shown',
	height: parseInt(jawnos_bar_settings['taskbar_height']) || 44,
	// the window title bar's own thickness, and the frame every window wears
	navbar: parseInt(jawnos_bar_settings['navbar_height']) || 36,
	border: jawnosBarSettingNumber('window_border', 3),
	// the frame's colour: blank means follow the theme (the ring's own --line)
	border_colour: jawnos_bar_settings['window_border_colour'] || '',
	// the bar's furniture in order (drag/drop edit mode writes it), and whether
	// the bar tucks itself away when idle
	order: jawnosTaskbarOrderSetting(jawnos_bar_settings['taskbar_order']),
	autohide: jawnos_bar_settings['taskbar_autohide'] || 'off'
};

// The order rides as JSON. The layout embeds it as a real array; an older or
// hand-set value may still be a string. Either way a bad value falls back to the
// default (null) so the bar is never left empty.
function jawnosTaskbarOrderSetting(value) {
	if (Array.isArray(value)) { return value.length ? value : null; }
	return jawnosTaskbarParseOrder(value);
}

// A string form of the order setting, if that is what came through.
function jawnosTaskbarParseOrder(text) {
	if (!text || typeof text != 'string') { return null; }
	try {
		var parsed = JSON.parse(text);
		return (Array.isArray(parsed) && parsed.length) ? parsed : null;
	}
	catch (e) { return null; }
}

// How tall the taskbar stands while it is up; the CSS gives it one height.
function jawnosTaskbarHeight() {
	var bar = $('#taskbar');
	return (bar.length && bar.is(':visible')) ? bar.outerHeight() : 0;
}
// What the taskbar takes from the edge named, when it lives on that edge.
function jawnosTaskbarEdge(edge) {
	return (jawnosBars.taskbar == edge) ? jawnosTaskbarHeight() : 0;
}
// The window title bar's thickness: the CSS variable the navbar scales against
// and every open window's per-window geometry reads. A slider previews it live.
function jawnosWindowNavbarApply(px) {
	var v = parseInt(px, 10);
	if (isNaN(v)) { return; }
	jawnosBars.navbar = Math.max(28, v);
	document.documentElement.style.setProperty('--navbar_h', jawnosBars.navbar + 'px');
}
// The frame every window wears - the .wind::after ring, matched by the title
// bar's own edge. A slider previews it live; 0 is a bare window.
function jawnosWindowBorderApply(px) {
	var v = parseInt(px, 10);
	if (isNaN(v)) { return; }
	jawnosBars.border = Math.max(0, v);
	document.documentElement.style.setProperty('--window_border', jawnosBars.border + 'px');
}
// The colour of that frame, independent of the theme's chrome. A blank value
// leaves the property unset, so the ring and the title bar fall back to --line
// (the theme). Anything else rides the root as --window_border_colour.
function jawnosWindowBorderColourApply(colour) {
	colour = colour || '';
	jawnosBars.border_colour = colour;
	var root = document.documentElement.style;
	if (colour) { root.setProperty('--window_border_colour', colour); }
	else { root.removeProperty('--window_border_colour'); }
}
function jawnosDockTop() {
	return jawnosBars.dock == 'top';
}
function jawnosDockHidden() {
	return jawnosBars.dock == 'hidden';
}
// A dock on a side edge stacks its icons, with the search panel hidden beside
// it until the button at the foot of the stack calls it out.
function jawnosSideDock() {
	return jawnosBars.dock == 'left' || jawnosBars.dock == 'right';
}
function jawnosDockLeft() {
	return jawnosBars.dock == 'left';
}
// The dock's icons switched permanently off: the pill keeps whatever else it
// carries - the search, or nothing at all - but the icon row never shows.
function jawnosDockIconsHidden() {
	return jawnosBars.icons == 'hidden';
}
// What a window in a half or maximized state leaves at the foot for the dock:
// the strip a bottom dock keeps on screen while it is tucked - the search while
// the input rides the dock, otherwise the sliver the pointer rests on to call the
// icons back. A window that reached the foot would bury that strip under its own
// backing, and its own foot controls (the music player's transport row, say)
// under the dock. Nothing for any other edge, or a hidden dock.
function jawnosDockWindowReserve() {
	if (jawnosBars.dock == 'hidden' || jawnosSideDock() || jawnosDockTop()) { return 0; }
	return (typeof pseudonymDockStrip == 'function') ? pseudonymDockStrip() : 0;
}
function jawnosSideSearchVisible() {
	return $('#pseudonym_home').hasClass('search_open');
}
function jawnosSideSearchShow(show) {
	var home = $('#pseudonym_home');
	// only a panel that lives in the dock has anything to open: with the search
	// riding the taskbar the input is already out, so the button just searches
	if (!home.length || !$('#search_entanglement').closest('#pseudonym_home').length) { return; }
	if (show) {
		home.addClass('search_open');
		// the pill may be tucked away; the search rides beside it, so it has to
		// be out for the input to have somewhere to slide from
		if (typeof pseudonymSideSettle == 'function') { pseudonymSideSettle(0); }
		if (!$('#search').is(':focus')) { $('#search').focus(); }
	}
	else {
		home.removeClass('search_open');
	}
}
// The dock hangs at the very top of the page - below only a top taskbar, which
// headerHeight carries - and clears the taskbar when the two share the bottom
// one.
function jawnosDockTopOffset() {
	return (typeof headerHeight != 'undefined') ? headerHeight : 0;
}
function jawnosDockBottomOffset() {
	return jawnosTaskbarEdge('bottom');
}

// The clock headerPrinter draws: the taskbar owns it while the bar is up.
function jawnosClockInTaskbar() {
	var bar = $('#taskbar');
	return bar.length > 0 && bar.is(':visible');
}
// The clock's text: a phone's bar is narrow, so there the day of the week goes,
// the year shortens to two figures, and the date sits over the time; a desk
// keeps the one long line headerPrinter builds. The hour answers to the clock
// format setting - 24 by default, 12 for a 2:45pm face.
function jawnosClockText(timestamp) {
	var date = new Date(timestamp);
	var pad = function (n) { return (n < 10 ? '0' : '') + n; };
	// the zone is a setting: blank means the machine's own clock, otherwise a
	// named IANA zone Intl knows. Either way the parts come from Intl, so a
	// zone change shows at once without a page reload.
	var zone = (typeof jawnos_clock_timezone != 'undefined' && jawnos_clock_timezone && jawnos_clock_timezone != 'local') ? jawnos_clock_timezone : undefined;
	var parts = null;
	try {
		var fmt = new Intl.DateTimeFormat('en-US', {
			timeZone: zone, hour12: false,
			weekday: 'short', year: 'numeric', month: '2-digit', day: '2-digit',
			hour: '2-digit', minute: '2-digit', second: '2-digit'
		});
		parts = {};
		fmt.formatToParts(date).forEach(function (p) { parts[p.type] = p.value; });
	}
	catch (e) { parts = null; }
	// an engine without the named zone (or Intl at all) falls back to local
	if (!parts || !parts.hour) {
		parts = {
			weekday: dayProcessor(date.getDay()),
			year: String(date.getFullYear()),
			month: pad(date.getMonth() + 1),
			day: pad(date.getDate()),
			hour: pad(date.getHours()),
			minute: pad(date.getMinutes()),
			second: pad(date.getSeconds())
		};
	}
	var hours = parseInt(parts.hour, 10);
	if (hours == 24) { hours = 0; }
	var time;
	if (typeof jawnos_clock_format != 'undefined' && jawnos_clock_format == '12') {
		var meridiem = hours < 12 ? 'am' : 'pm';
		var face = hours % 12;
		if (face == 0) { face = 12; }
		time = face + ':' + parts.minute + ':' + parts.second + meridiem;
	}
	else {
		time = pad(hours) + ':' + parts.minute + ':' + parts.second;
	}
	var date_text = parts.month + '/' + parts.day + '/';
	if (windowPhoneChecker()) {
		return date_text + String(parts.year).slice(-2) + '<br>' + time;
	}
	return parts.weekday + ' ' + date_text + parts.year + ' ' + time;
}
// Whether the clock's face is off the present. The face is the view's centre,
// which the time machine or a timeshift moves; while either is set, the face
// wears another time and is not now. Staleness is deliberately not counted: a
// poll that has only fallen behind leaves the face where it was, so this reads
// the travel settings and never the wall clock. (A '0s' time machine is the
// present itself, and graphicalize clears it.)
function jawnosClockAstray() {
	var time_machine = localStorage.getItem('time_machine');
	if (time_machine && time_machine != '0s' && time_machine != 'in 0s' && time_machine.toLowerCase() != 'now') { return true; }
	var timeshift = parseFloat(localStorage.getItem('timeshift'));
	return isFinite(timeshift) && timeshift != 0;
}
// Light the clock's plate while the view is carried off the present - down the
// time machine or under a timeshift - so its face cannot be read as the present.
function jawnosClockAstrayApply() {
	$('#taskbar_clock').attr('astray', jawnosClockAstray() ? 'yes' : 'no');
}
// The clock is redrawn from the last timestamp it was given, so a change to its
// format shows at once rather than at the next view refresh. The astray flag
// rides along: every travel change rides a fresh render in through here anyway.
var jawnosClockStamp = null;
function jawnosClockShow(timestamp) {
	if (timestamp !== undefined && timestamp !== null) { jawnosClockStamp = timestamp; }
	if (jawnosClockStamp === null) { return; }
	// a poll must not clobber the time machine while it is being typed into
	if (jawnosClockEditing()) { jawnosClockAstrayApply(); return; }
	$('#taskbar_clock').html(jawnosClockText(jawnosClockStamp));
	jawnosClockAstrayApply();
}

// The clock doubles as a time machine: click it and type a time - "-3h", "jul
// 16", "last dec 25", "dec 25 2025 at 7:04pm" - and Enter carries the view
// there, exactly as the keyboard's #time_machine does. Escape or a click away
// leaves the view where it was, and an empty entry is "now".
function jawnosClockEditing() {
	return $('#taskbar_clock').hasClass('editing');
}
function jawnosClockEditStart() {
	var clock = $('#taskbar_clock');
	if (!clock.length || jawnosClockEditing()) { return; }
	if (typeof jawnosTaskbarEditing == 'function' && jawnosTaskbarEditing()) { return; }
	var current = '';
	try { current = localStorage.getItem('time_machine') || ''; } catch (e) { current = ''; }
	clock.data('clock_html', clock.html());
	clock.addClass('editing');
	clock.html('<input type="text" class="taskbar_clock_input" placeholder="Time machine">');
	var input = clock.find('.taskbar_clock_input');
	input.val(current).focus();
	try { input[0].select(); } catch (e) {}
}
function jawnosClockEditEnd(commit) {
	var clock = $('#taskbar_clock');
	if (!jawnosClockEditing()) { return; }
	var input = clock.find('.taskbar_clock_input');
	var value = input.length ? (input.val() || '') : '';
	var saved = clock.data('clock_html');
	clock.removeClass('editing').removeData('clock_html');
	clock.html(saved === undefined ? '' : saved);
	value = value.replace(/^\s+|\s+$/g, '');
	if (commit) {
		try { localStorage.setItem('time_machine', value); } catch (e) {}
		$('#time_machine').val(value);
		jawnosClockAstrayApply();
		// one fetch, the same the poll makes: the view slides to the new centre
		if (typeof calculator == 'function') { calculator(); }
	}
	else {
		jawnosClockAstrayApply();
	}
}
$(document).on('click', '#taskbar_clock', function (e) {
	if ($(e.target).is('.taskbar_clock_input')) { return; }
	jawnosClockEditStart();
});
$(document).on('keydown keypress keyup', '.taskbar_clock_input', function (e) {
	// keep the typed keys away from the app's own shortcut handlers
	e.stopPropagation();
	if (e.type != 'keydown') { return; }
	if (e.keyCode == 13) { e.preventDefault(); jawnosClockEditEnd(true); }
	else if (e.keyCode == 27) { e.preventDefault(); jawnosClockEditEnd(false); }
});
$(document).on('focusout', '.taskbar_clock_input', function () {
	jawnosClockEditEnd(true);
});

// The search's own home: the taskbar's right end, the start menu's corner
// beside the leave, now and bird buttons, or the dock's row. One writer, so the
// menu's own re-renders can call it again after they have swapped the corner
// buttons out from under it.
function jawnosSearchPlace() {
	var search = $('#search_entanglement');
	if (!search.length) { return; }
	// the menu's own chrome answers to where the search lives: the search's row
	// is reserved at its top only while the menu is the search's home
	if ($('#start_menu').length) {
		if (jawnosBars.search == 'start_menu') { $('#start_menu').addClass('search_home'); }
		else { $('#start_menu').removeClass('search_home'); }
	}
	if (jawnosBars.search == 'taskbar') {
		if (!search.closest('#taskbar').length) { search.prependTo('#taskbar'); }
	}
	else if (jawnosBars.search == 'start_menu') {
		if (!search.closest('#start_menu').length) { search.appendTo('#start_menu'); }
	}
	else if (!search.closest('#pseudonym_home').length) {
		search.prependTo('#pseudonym_home');
	}
}

function jawnosBarsApply() {
	var bar = $('#taskbar');
	var dock = $('#pseudonym_home');
	if (!bar.length) { return; }

	bar.attr('position', jawnosBars.taskbar);
	bar.attr('autohide', jawnosBars.autohide);
	if (dock.attr('position') != jawnosBars.dock) {
		// a move between edges drops the tuck the old edge left behind
		dock.attr('position', jawnosBars.dock).css({ top: '', bottom: '', left: '', right: '' });
		if (typeof pseudonymSideTucked != 'undefined') {
			pseudonymSideTucked = 0;
			pseudonymSideLayout = null;
		}
	}
	jawnosTopIconsApply();

	// a taskbar on the top edge pushes the whole page down: the line the printers
	// draw, the clothesline under it and the rows below all measure from
	// headerHeight, so shifting it once moves them together. With no band above
	// the clothesline any more, that offset is the bar's own height.
	if (typeof headerHeight != 'undefined') {
		headerHeight = jawnosTaskbarEdge('top');
	}

	var root = document.documentElement.style;
	// the bar's height is a misc setting: the CSS reads this property for the
	// bar's own height and for everything that sizes itself against it
	root.setProperty('--taskbar_h', Math.max(24, jawnosBars.height) + 'px');
	// the window title bar's height rides the same way: the navbar's own CSS and
	// the per-window geometry window_maker writes both measure against it
	root.setProperty('--navbar_h', Math.max(28, jawnosBars.navbar) + 'px');
	// the window frame's own thickness, read by every window's ring and title bar
	root.setProperty('--window_border', Math.max(0, jawnosBars.border) + 'px');
	// and its colour, unless the theme's --line is asked for (a blank setting)
	jawnosWindowBorderColourApply(jawnosBars.border_colour);
	root.setProperty('--taskbar_top_h', jawnosTaskbarEdge('top') + 'px');
	root.setProperty('--taskbar_bottom_h', jawnosTaskbarEdge('bottom') + 'px');
	root.setProperty('--dock_top_h', jawnosDockTopOffset() + 'px');

	// the search rides in the dock, the taskbar or the start menu, wherever the
	// setting says
	jawnosSearchPlace();

	// then the bar's furniture takes its order: the search, the window list, the
	// clock and the start button are slots the edit mode drags around, and a
	// pinned app or keyboard rides among them
	jawnosTaskbarOrderApply();
	// the slot has moved, so the padlock picks which side of the start button
	// it belongs on now
	jawnosTopIconsSideApply();

	// the top dock rests tucked away - its icons above the visible edge, its
	// search strip on screen - so a fresh layout settles it there; every other
	// edge takes the plain sizing, which the settle runs itself when it takes
	var settled = (typeof pseudonymHomeTopSettle == 'function') && pseudonymHomeTopSettle();
	if (!settled && typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
	if (typeof taskbarDisplayer == 'function') { taskbarDisplayer(); }
	// a menu that is up follows its button when the bars move it
	jawnosStartMenuPlace();
}

// The menu hangs from the button that opens it, wherever the bars have put that
// button: above it when the taskbar is along the bottom, below it in the corner
// or on a top bar, hugging whichever screen edge the button is nearest, and
// never taller than the room between the button and the far edge.
function jawnosStartMenuPlace() {
	var menu = $('#start_menu');
	var toggle = $('#start_menu_toggle');
	if (!menu.length || !toggle.length || !menu.is(':visible') || !toggle.is(':visible')) { return; }
	var t = toggle[0].getBoundingClientRect();
	var w = $(window).width();
	var h = $(window).height();
	var gap = 4;
	var menu_w = Math.min(menu.outerWidth() || 0, w);
	var left = ((t.left + (t.width / 2)) < (w / 2)) ? t.left : (t.right - menu_w);
	// a menu as wide as the screen sits flush to it rather than hanging over
	left = Math.max(0, Math.min(left, w - menu_w));
	var below = (jawnosBars.taskbar != 'bottom');
	var room = below ? (h - t.bottom - gap - 8) : (t.top - gap - 8);
	var place = {
		'left': Math.round(left) + 'px',
		'right': 'auto',
		'max-height': Math.max(160, room) + 'px'
	};
	if (below) {
		place['top'] = Math.round(t.bottom + gap) + 'px';
		place['bottom'] = 'auto';
	}
	else {
		place['bottom'] = Math.round(h - t.top + gap) + 'px';
		place['top'] = 'auto';
	}
	menu.css(place);
}

$(window).on('resize', function () {
	jawnosStartMenuPlace();
	jawnosTopIconsSideApply();
});

// The icons the top-right corner used to wear alone: while the taskbar stands
// they ride inside it at its right end, beside the clock, and with the bar
// hidden the corner takes them back.
function jawnosTopIconsApply() {
	var icons = $('#lock_session, #start_menu_toggle');
	if (!icons.length) { return; }
	if (jawnosBars.taskbar == 'hidden') {
		icons.appendTo('#top_right_buttons');
	}
	else {
		icons.appendTo('#taskbar_icons');
	}
	jawnosTopIconsSideApply();
}

// The padlock sits on the inward side of the start button. In the right-hand
// corner that means the lock first and the start button at the edge; when the
// start button has been dragged to the left half of the bar, the start goes
// first and the lock follows it, so the lock is never the outside button on
// the left. Run after the slot order has been applied, since that is what puts
// #taskbar_icons at its final place on the bar.
function jawnosTopIconsSideApply() {
	var lock = $('#lock_session');
	var start = $('#start_menu_toggle');
	if (!lock.length || !start.length) { return; }
	var parent = start.parent();
	if (!parent.length) { return; }
	var left_side = false;
	if (parent.is('#taskbar_icons')) {
		var r = parent[0].getBoundingClientRect();
		left_side = (r.left + (r.width / 2)) < ($(window).width() / 2);
	}
	if (left_side) { start.after(lock); }
	else { lock.after(start); }
}

// The start button (and the lock beside it) is now just one of the bar's slots:
// where it stands is the order the edit mode drags it into (see taskbar_edit.js),
// so there is no side setting to apply here any more.

// the cancel beside a side dock's input sends the panel away
$(document).on('click', '#search_cancel', function () {
	jawnosSideSearchShow(0);
});

$(document).ready(function () {
	jawnosBarsApply();
});

// A misc slider (the bar heights): the input event previews on the live screen
// while the change handler below writes the setting away on release. The readout
// beside the label is refreshed for every slider that carries one.
function jawnosMiscRangeInput(input) {
	var setting = $(input).attr('setting');
	var value = parseInt(input.value, 10);
	if (isNaN(value)) { return; }
	var readout = document.getElementById(setting + '_value_' + $(input).attr('device'));
	if (readout) { readout.textContent = value; }
	if (setting == 'taskbar_height') {
		// the bar scales at once; the full bars pass runs on release
		document.documentElement.style.setProperty('--taskbar_h', Math.max(24, value) + 'px');
	}
	else if (setting == 'navbar_height') {
		// every window title bar scales at once from the CSS variable
		jawnosWindowNavbarApply(value);
	}
	else if (setting == 'window_border') {
		// every window's frame scales at once from the CSS variable
		jawnosWindowBorderApply(value);
	}
	else if (setting == 'clothesline_height') {
		if (typeof jawnosClotheslineHeightApply == 'function') { jawnosClotheslineHeightApply(value); }
	}
}

// the configure panel writes the setting away as it changes; the bars follow
// here at once, so the screen shows what was picked
$(document).on('change', '.misc_setting', function () {
	var setting = $(this).attr('setting');
	if (setting == 'dock_position') { jawnosBars.dock = $(this).val(); }
	else if (setting == 'taskbar_position') { jawnosBars.taskbar = $(this).val(); }
	else if (setting == 'search_placement') { jawnosBars.search = $(this).val(); }
	else if (setting == 'dock_icons') { jawnosBars.icons = $(this).val(); }
	else if (setting == 'taskbar_height') { jawnosBars.height = parseInt($(this).val()) || 44; }
	else if (setting == 'navbar_height') { jawnosWindowNavbarApply($(this).val()); }
	else if (setting == 'window_border') { jawnosWindowBorderApply($(this).val()); }
	else if (setting == 'window_border_colour') { jawnosWindowBorderColourApply($(this).val()); return; }
	else if (setting == 'clothesline_height') { jawnosClotheslineHeightApply($(this).val()); return; }
	else if (setting == 'start_menu_icon') {
		// the button's own face: ask the server where the path lives in the set
		// that is showing, the same way a set change re-maps every jawnos_icon
		var toggle = $('#start_menu_toggle');
		var value = $(this).val();
		toggle.attr('jawnos_icon', value);
		$.ajax({
			url: '/manager/icons',
			type: 'GET',
			data: { paths: JSON.stringify([value]) },
			success: function (response) {
				if (response.icons && response.icons[value]) { toggle.attr('src', response.icons[value]); }
			}
		});
		return;
	}
	else if (setting == 'icon_set') {
		// every icon in the menu is about to change path; the kept markup is stale
		if (typeof startMenuHtmlFlush == 'function') { startMenuHtmlFlush(); }
		return;
	}
	else if (setting == 'clock_format') {
		jawnos_clock_format = $(this).val();
		jawnosClockShow();
		return;
	}
	else { return; }
	jawnosBarsApply();
});
