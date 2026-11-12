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
	else if (setting == 'button_border') {
		// every pressed surface, icon and the clothesline scales at once
		jawnosButtonBorderApply(value);
	}
	else if (setting == 'clothesline_height') {
		if (typeof jawnosClotheslineHeightApply == 'function') { jawnosClotheslineHeightApply(value); }
	}
	else if (setting == 'corner_radius') {
		jawnosCornerApply(value, false);
	}
	else if (setting == 'corner_override') {
		jawnosCornerApply(value, true);
	}
}

// A misc colour swatch (the window frame and the button edge): the input event
// previews on the live screen while the change handler writes it away.
function jawnosMiscColourInput(input) {
	var setting = $(input).attr('setting');
	if (setting == 'button_border_colour') { jawnosButtonBorderColourApply(input.value); }
	else { jawnosWindowBorderColourApply(input.value); }
}

// the configure panel writes the setting away as it changes; the bars follow
// here at once, so the screen shows what was picked
$(document).on('change', '.misc_setting', function () {
	var setting = $(this).attr('setting');
	if (setting == 'dock_position') { jawnosBars.dock = $(this).val(); }
	else if (setting == 'taskbar_position') { jawnosBars.taskbar = $(this).val(); }
	else if (setting == 'search_placement') { jawnosBars.search = $(this).val(); }
	else if (setting == 'dock_icons') { jawnosBars.icons = $(this).val(); }
	else if (setting == 'dock_transparent') { jawnosBars.transparent = $(this).val(); }
	else if (setting == 'dock_windows') { jawnosBars.dock_windows = $(this).val(); }
	else if (setting == 'taskbar_height') { jawnosBars.height = parseInt($(this).val()) || 44; }
	else if (setting == 'navbar_height') { jawnosWindowNavbarApply($(this).val()); }
	else if (setting == 'window_border') { jawnosWindowBorderApply($(this).val()); }
	else if (setting == 'button_border') { jawnosButtonBorderApply($(this).val()); }
	else if (setting == 'window_border_colour') { jawnosWindowBorderColourApply($(this).val()); return; }
	else if (setting == 'button_border_colour') { jawnosButtonBorderColourApply($(this).val()); return; }
	else if (setting == 'texture') { if (typeof jawnosTextureApply == 'function') { jawnosTextureApply($(this).val()); } return; }
	else if (setting == 'clothesline_height') { jawnosClotheslineHeightApply($(this).val()); return; }
	else if (setting == 'corner_radius') { jawnosCornerApply($(this).val(), false); return; }
	else if (setting == 'corner_override') { jawnosCornerApply($(this).val(), true); return; }
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
	else if (setting == 'cursor_set' || setting == 'cursor_set_override') {
		// the sheet already carries every set's mapping; move the body's marker.
		// A blank override means Follow theme, so leave the theme's own cursor in
		// place and let the server's push settle the effective value.
		var cursorSet = $(this).val();
		if (typeof jawnosCursorApply == 'function' && (setting == 'cursor_set' || cursorSet)) {
			jawnosCursorApply(cursorSet);
		}
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
