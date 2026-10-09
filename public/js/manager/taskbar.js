// The two bars at the edges of the manager: the dock (the pseudonym row, and
// the search when it rides there) and the taskbar (the open windows - the list
// the start menu used to carry at its foot - and the clock). Which edge each
// one lives on - bottom, top or hidden - is a per-device misc setting the
// layout seeds into jawnos_bar_settings, and the search's home is its own
// setting. This file turns those settings into the attributes and the few
// custom properties the CSS and the other scripts read, and hands the other
// scripts the offsets their own maths needs.

var jawnos_bar_settings = (typeof jawnos_bar_settings != 'undefined' && jawnos_bar_settings) ? jawnos_bar_settings : {};
var jawnosBars = {
	dock: jawnos_bar_settings['dock_position'] || 'bottom',
	taskbar: jawnos_bar_settings['taskbar_position'] || 'bottom',
	search: jawnos_bar_settings['search_placement'] || 'dock',
	start_side: jawnos_bar_settings['start_button_side'] || 'right',
	icons: jawnos_bar_settings['dock_icons'] || 'shown'
};

// How tall the taskbar stands while it is up; the CSS gives it one height.
function jawnosTaskbarHeight() {
	var bar = $('#taskbar');
	return (bar.length && bar.is(':visible')) ? bar.outerHeight() : 0;
}
// What the taskbar takes from the edge named, when it lives on that edge.
function jawnosTaskbarEdge(edge) {
	return (jawnosBars.taskbar == edge) ? jawnosTaskbarHeight() : 0;
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
// What a window in a half or maximized state leaves at the foot for the dock.
// While the icons are on, nothing: those states measured themselves against the
// search strip, and the dock is the user's to call out over the window's own
// foot, as it always was. With the icons off, whatever the dock still keeps on
// screen - the search's strip, or nothing at all.
function jawnosDockWindowReserve() {
	if (!jawnosDockIconsHidden()) { return 0; }
	if (jawnosBars.dock == 'hidden' || jawnosSideDock() || jawnosDockTop()) { return 0; }
	var search_in_dock = $('#search_entanglement').closest('#pseudonym_home').length > 0;
	return search_in_dock ? ((typeof pseudonymDockReach != 'undefined') ? pseudonymDockReach : 47) : 0;
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
	var hours = date.getHours();
	var time;
	if (typeof jawnos_clock_format != 'undefined' && jawnos_clock_format == '12') {
		var meridiem = hours < 12 ? 'am' : 'pm';
		hours = hours % 12;
		if (hours == 0) { hours = 12; }
		time = hours + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds()) + meridiem;
	}
	else {
		time = pad(hours) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
	}
	var date_text = pad(date.getMonth() + 1) + '/' + pad(date.getDate()) + '/';
	if (windowPhoneChecker()) {
		return date_text + String(date.getFullYear()).slice(-2) + '<br>' + time;
	}
	return dayProcessor(date.getDay()) + ' ' + date_text + date.getFullYear() + ' ' + time;
}
// The clock is redrawn from the last timestamp it was given, so a change to its
// format shows at once rather than at the next view refresh.
var jawnosClockStamp = null;
function jawnosClockShow(timestamp) {
	if (timestamp !== undefined && timestamp !== null) { jawnosClockStamp = timestamp; }
	if (jawnosClockStamp === null) { return; }
	$('#taskbar_clock').html(jawnosClockText(jawnosClockStamp));
}

// The search's own home: the taskbar's right end, the start menu's corner
// beside the leave, now and bird buttons, or the dock's row. One writer, so the
// menu's own re-renders can call it again after they have swapped the corner
// buttons out from under it.
function jawnosSearchPlace() {
	var search = $('#search_entanglement');
	if (!search.length) { return; }
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
	root.setProperty('--taskbar_top_h', jawnosTaskbarEdge('top') + 'px');
	root.setProperty('--taskbar_bottom_h', jawnosTaskbarEdge('bottom') + 'px');
	root.setProperty('--dock_top_h', jawnosDockTopOffset() + 'px');

	// the search rides in the dock, the taskbar or the start menu, wherever the
	// setting says
	jawnosSearchPlace();

	// the icons take their end after the search has taken its place, so a start
	// button set to the left leads the bar with nothing before it
	jawnosTaskbarIconsSideApply();

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
}

// The start button (and the lock beside it) answers to its own setting: on the
// right end it stands after the clock, at the very end of the bar, and on the
// left it leads the bar.
function jawnosTaskbarIconsSideApply() {
	var icons = $('#taskbar_icons');
	if (!icons.length || !$('#taskbar').length) { return; }
	if (jawnosBars.start_side == 'left') {
		icons.prependTo('#taskbar');
	}
	else {
		icons.appendTo('#taskbar');
	}
}

// the cancel beside a side dock's input sends the panel away
$(document).on('click', '#search_cancel', function () {
	jawnosSideSearchShow(0);
});

$(document).ready(function () {
	jawnosBarsApply();
});

// the configure panel writes the setting away as it changes; the bars follow
// here at once, so the screen shows what was picked
$(document).on('change', '.misc_setting', function () {
	var setting = $(this).attr('setting');
	if (setting == 'dock_position') { jawnosBars.dock = $(this).val(); }
	else if (setting == 'taskbar_position') { jawnosBars.taskbar = $(this).val(); }
	else if (setting == 'search_placement') { jawnosBars.search = $(this).val(); }
	else if (setting == 'start_button_side') { jawnosBars.start_side = $(this).val(); }
	else if (setting == 'dock_icons') { jawnosBars.icons = $(this).val(); }
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
