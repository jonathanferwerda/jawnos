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
	search: jawnos_bar_settings['search_placement'] || 'dock'
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
// The dock hangs below the header's band when it lives on the top edge, and
// clears the taskbar when the two share the bottom one. headerHeight carries
// the band - and the top taskbar it may have been pushed down by - so it is the
// top offset itself.
function jawnosDockTopOffset() {
	return (typeof headerHeight != 'undefined') ? headerHeight : 50;
}
function jawnosDockBottomOffset() {
	return jawnosTaskbarEdge('bottom');
}

// The clock headerPrinter draws: the taskbar owns it while the bar is up.
function jawnosClockInTaskbar() {
	var bar = $('#taskbar');
	return bar.length > 0 && bar.is(':visible');
}
function jawnosClockShow(text) {
	$('#taskbar_clock').text(text);
}

function jawnosBarsApply() {
	var bar = $('#taskbar');
	var dock = $('#pseudonym_home');
	if (!bar.length) { return; }

	bar.attr('position', jawnosBars.taskbar);
	dock.attr('position', jawnosBars.dock);
	jawnosTopIconsApply();

	// a taskbar on the top edge pushes the whole header band down: the line the
	// printers draw, the clothesline under it and the rows below all measure
	// from headerHeight, so shifting it once moves them together
	if (typeof headerHeight != 'undefined') {
		headerHeight = 50 + jawnosTaskbarEdge('top');
	}

	var root = document.documentElement.style;
	root.setProperty('--taskbar_top_h', jawnosTaskbarEdge('top') + 'px');
	root.setProperty('--taskbar_bottom_h', jawnosTaskbarEdge('bottom') + 'px');
	root.setProperty('--dock_top_h', jawnosDockTopOffset() + 'px');

	// the search rides in the dock or the taskbar, wherever the setting says
	var search = $('#search_entanglement');
	if (search.length) {
		var in_taskbar = search.closest('#taskbar').length > 0;
		if (jawnosBars.search == 'taskbar') {
			if (!in_taskbar) { search.prependTo(bar); }
		}
		else if (in_taskbar || search.closest('#pseudonym_home').length == 0) {
			search.prependTo(dock);
		}
	}

	if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
	if (typeof taskbarDisplayer == 'function') { taskbarDisplayer(); }
}

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
	else { return; }
	jawnosBarsApply();
});
