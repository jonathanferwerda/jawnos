function windowMinimizer(timestamp,app) {
	var win = $('#window_' + timestamp);
	if (app) {
		win = $('.wind[app="' + app + '"]');
	}
	if (win.is(':visible')) { 
		win.hide();
		win.attr('view', 'minimized');
		var tnh = win.height();
		var tnw = win.width();

		jawnosWindowSizeSet(timestamp, 'h', tnh);
		jawnosWindowSizeSet(timestamp, 'w', tnw);

	} else { 
		$('#window_contents_' + timestamp).show();
		if (windowPhoneChecker()) { 
			$('#window_contents_' + timestamp).css({'overflow': 'scroll'});
		}

		var tnh = jawnosWindowSizeGet(timestamp, 'h');
		var tnw = jawnosWindowSizeGet(timestamp, 'w');
		$('#window_' + timestamp).css({'height': tnh, 'width': tnw });
	}
	windowDimensionSetter(win);
	// the window that steps forward or away from the front owns the keyboard cue
	if (typeof jawnosWindowFocusApply == 'function') { jawnosWindowFocusApply(); }
}

function windowHalfski(win,side) {

	var mouse = { x: null, y: null };
	if (!side) {
		mouse = mouse_position();
	}
	if (!windowPhoneChecker()) {
		// the top sits flush under a taskbar on the top edge - headerHeight is the
		// bar's own height - so the titlebar is not tucked under the bar. (The old
		// reservedSpots['header'] + 2 left a 2px overlap.)
		var ok = (typeof headerHeight != 'undefined') ? headerHeight : (reservedSpots['header'] || 0);
		var ww = $(window).width();
		// The half window reaches the foot of the screen, stopping only for what
		// holds the bottom edge: a bottom taskbar, and the strip a bottom dock keeps
		// on screen while it is tucked (windowBottomClearance carries both). That
		// leaves the dock's reach on screen instead of burying it - and the window's
		// own foot controls, which sit at its very bottom, clear the dock instead of
		// hiding under it. While the search rides the dock its panel may be out, so
		// the foot also stops on the dock's own top edge.
		var foot = $(window).height() - windowBottomClearance();
		var search_in_dock = $('#search_entanglement').closest('#pseudonym_home').length > 0;
		var dock_on_bottom = (typeof jawnosDockTop == 'function' && !jawnosDockTop())
			&& (typeof jawnosSideDock == 'function' && !jawnosSideDock())
			&& (typeof jawnosDockHidden == 'function' && !jawnosDockHidden());
		if (search_in_dock && dock_on_bottom) {
			var dock = $('#pseudonym_home');
			if (dock.length) { foot = Math.min(foot, dock.offset().top); }
		}
		var height = foot - ok;
		if (mouse.x > (ww - (ww / 10)) || side == 'right') {

			win.css({ 
				'position':'fixed', 
				'height': height, 
				'width': '50%',
				'left': '50%',
				'top': ok
			});
		}
		else if (mouse.x < (ww / 10) || side == 'left') {
			win.css({ 
				'position':'fixed', 
				'height': height, 
				'width': '50%',
				'left': '0%',
				'top': ok
			});
		}
		windowDimensionSetter(win);
	}
}

$(document).on('click', '.maximize_button', function() {
	var timestamp = $(this).closest('.wind').attr('timestamp');
	var app = $(this).closest('.wind').attr('app');
	windowMaximizer(timestamp,app);
});

function windowMaximizer(timestamp, app) {
	var win = $('#window_' + timestamp );
	$('#window_' + timestamp + '_restore').show();
	$('#window_' + timestamp + '_maximize').hide();
	// A maximized window fills the space between the top limit and the foot
	// clearance - a bottom taskbar and the strip a bottom dock keeps on screen - so
	// no band of desktop shows beneath it and its own foot controls clear the dock.
	// The old fixed percentages left that band (and overran the foot on a short
	// screen). The phone keeps its own shorter face.
	var hidden = (typeof jawnosDockIconsHidden == 'function') && jawnosDockIconsHidden();
	if (windowPhoneChecker()) {
		var tall = hidden ? Math.max(200, $(window).height() - windowTopLimit() - windowBottomClearance() - 6) + 'px' : null;
		win.css({ 
			'position':'fixed', 
			'height': tall || '80%', 
			'width': '98%',
			'left': '0px',
			'top': windowTopLimit()
		});
	}
	else {
		win.css({ 
			'position':'fixed', 
			'height': Math.max(200, $(window).height() - windowTopLimit() - windowBottomClearance()) + 'px', 
			'width': '100%',
			'left': '0px',
			'top': windowTopLimit()
		});
	}
	$('#window_contents_' + timestamp ).css({ 'width': '100%' });
	windowDimensionSetter($('#window_' + timestamp ));
}

function windowRestore(timestamp,app) {
	var win = $('#window_' + timestamp + '');


	$('#window_' + timestamp + '_maximize').show(); 
	$('#window_' + timestamp + '_restore').hide(); 
	if (windowPhoneChecker()) {
		win.css({ 'position':'fixed', 'height': '500px', 'width': '98%' });
	} else {
		if (win.attr('free_dimensions')) {
			var d = JSON.parse(win.attr('free_dimensions'));
			win.css({ 'position':'fixed', 'height': d.height, 'width': d.width, 'top': d.top, 'left': d.left });
		} else {
			win.css({ 'position':'fixed', 'height': '500px', 'width': '450px' });
		}
	}
	windowDimensionSetter(win);
}

function windowRestorer(timestamp,app) {
	var win = $('#window_' + timestamp);
	if (app) {
		win = $('.wind[app="' + app + '"]');
	}
	if (!win.is(':visible')) {
		if (win.length == 0) {
			if ($('.wind[app="' + app + '"]').length == 0) {
				appointmentGrabber(app);
			//	$('#window_icon_' + timestamp).remove();
			}
			else {
				win.show();
			}
		}
		else {
			win.show();
		}
		win.attr('visible', 'yes');
	}
	else {
		win.hide();
		win.attr('visible', 'no');
	}
	windowDimensionSetter(win);
	if (typeof jawnosWindowFocusApply == 'function') { jawnosWindowFocusApply(); }

}

var reservedSpots = {};

// Move mode: a window put into it is dragged from anywhere on it (not just its
// navbar) for one move, or until it is turned off again from the window's menu.
// Only one window moves at a time.
var jawnos_move_app = null;
function jawnosWindowMoveMode(app) {
	if (jawnos_move_app && jawnos_move_app != app) { jawnosWindowMoveModeOff(jawnos_move_app); }
	if (jawnos_move_app == app) { jawnosWindowMoveModeOff(app); return; }
	var win = $('.wind[app="' + app + '"]');
	if (!win.length) { return; }
	jawnos_move_app = app;
	windowDraggable(win);
	if (win.hasClass('ui-draggable')) { win.draggable('option', 'handle', false); }
	win.addClass('window_move_mode');
	win.off('dragstop.jawnos_move').on('dragstop.jawnos_move', function () { jawnosWindowMoveModeOff(app); });
}
function jawnosWindowMoveModeOff(app) {
	var win = $('.wind[app="' + app + '"]');
	win.removeClass('window_move_mode');
	if (win.hasClass('ui-draggable')) { win.draggable('option', 'handle', '.top_navbar'); }
	win.off('dragstop.jawnos_move');
	if (jawnos_move_app == app) { jawnos_move_app = null; }
}

function windowDraggable(win) {
	if (!win.hasClass('ui-draggable')) {

		// where the pointer went down: a click on the title bar also starts and
		// stops a drag, and only a real move takes the window out of the tile
		var dragFrom = null;

		win.draggable({
			cancel: 'input,textarea,button,select,option,.save_appointment,.app_act,.edit_app,.delete_app,.delete_location,.minimize_button,.restore_button,.maximize_button,.close_button',
			handle: '.top_navbar',
			start: function(p,ui) {
				dragFrom = { x: p.pageX, y: p.pageY };
				windows[p.target.id] = Date.now();
				if (win.attr('view') == 'max' && win.attr('free_dimensions')) {
					var d = JSON.parse(win.attr('free_dimensions'));
					var top = win.css('top');
					var mouse = mouse_position();
					var left = (mouse.x - (numeral(d.width).value() / 2));
					win.css({'position': 'fixed', 'height': d.height, 'width': d.width });
					ui.position.left = left;
					win.find('.maximize_button').show();
					win.find('.restore_button').hide();
					windowDimensionSetter(win);
				}
			},
			// Marker's own drawing of a window's place is in its app chunk, which may
			// not have been loaded: with no Marker window open there is no marker to
			// move. Calling it unguarded threw out of jQuery UI's drag callback, and
			// the exception stopped the window being moved at all.
			drag: function(p,ui) {
				if (typeof markerDragger === 'function') { markerDragger(p.target.id,'drag'); }
			},
			stop: function(p,ui) {
				var d = mouse_position();
				var data = JSON.stringify(d);
				var now = Date.now();
				var halfski = windowHalfski(win);
				$('#marker_targeting').hide();
				if (halfski == 'ya') {

				}
				else if (d.y < windowTopLimit() + 10) {
					var ok = windowTopLimit();
					var point = document.elementFromPoint(d.x, d.y) || 'null';
					var pd = $('#' + p.target.id).closest('.wind');
					
					pd.css({ 'top': ok });
				}
				else if (now - windows[p.target.id] < 250) {
					var point = document.elementFromPoint(d.x, d.y) || 'null';

					var wc = $('#window_contents_' + timestamp);
					wc.show();

					var tnh = jawnosWindowSizeGet(timestamp, 'h');
					var tnw = jawnosWindowSizeGet(timestamp, 'w');

					$('#window_' + timestamp).css({'height': tnh, 'width': tnw });
				}
				if (typeof markerDragger === 'function') { markerDragger(p.target.id,'stop'); }
				windowDimensionSetter($('#' + p.target.id));
				// A window dragged by hand has left the stack: the tile closes the slot it
				// held, and the window floats where it was put. A click on the title bar
				// also starts and stops a drag without moving the pointer, and that keeps
				// the window in the tile.
				var moved = dragFrom && (Math.abs(p.pageX - dragFrom.x) > 4 || Math.abs(p.pageY - dragFrom.y) > 4);
				if (!windowPhoneChecker() && moved && typeof windowTiledLeave === 'function') {
					windowTiledLeave(win, true);
				}
				// a phone's pile is a cascade; a drag would leave the window over the
				// others' bars and swallow their taps, so restack it - to the top of
				// the pile - the moment the drag ends
				if (windowPhoneChecker()) { windowStacker(win.attr('app'), true); }
				dragFrom = null;
			}
		});
		// a phone keeps its windows the width of the screen: vertical only
		if (windowPhoneChecker()) { win.draggable('option', 'axis', 'y'); }
		setTimeout(function () {
			win.removeClass('active');
		},50);
	}
}

// ---------------------------------------------------------------- a window's place
//
// The pin in the title bar is the whole choice. Pinned, a window keeps the size
// and position it was pinned at; unpinned, it has no place of its own and
// cascades in like a window that has never been opened. A window is only saved
// while it is pinned - dragging an unpinned one is just moving it about.
function windowPlaceIsLocked(win) {
	return $(win).find('.place_button').attr('status') == 'on';
}

// The saved place travels with the screen it was saved on. A window pinned to
// the right of a 1920 desk opens off the right of a 1366 one unless it is
// rescaled, so the place is scaled to this screen and the edge it sits nearest
// is the edge it keeps (a window pinned to the right stays flush right).
function windowPlaceRestore(win) {
	win = $(win);
	if (win.attr('pre_dimensioned') != 1) { return; }
	var saved_w = parseFloat(win.attr('place_vw')) || 0;
	var saved_h = parseFloat(win.attr('place_vh')) || 0;
	var now_w = $(window).width() || 0;
	var now_h = $(window).height() || 0;
	// a place saved before the screen was recorded is used as it stands: windowFit
	// below still keeps it on the screen
	if (!saved_w || !saved_h || !now_w || !now_h) { return; }
	if (Math.abs(saved_w - now_w) < 8 && Math.abs(saved_h - now_h) < 8) { return; }
	var scale = Math.min(now_w / saved_w, now_h / saved_h);
	if (!isFinite(scale) || scale <= 0) { return; }
	var left = parseFloat(win.css('left')) || 0;
	var top = parseFloat(win.css('top')) || 0;
	var width = parseFloat(win.css('width')) || 0;
	var height = parseFloat(win.css('height')) || 0;
	if (!width || !height) { return; }
	var from_right = saved_w - (left + width);
	var from_bottom = saved_h - (top + height);
	var new_w = Math.max(240, Math.round(width * scale));
	var new_h = Math.max(160, Math.round(height * scale));
	var new_left = (from_right < left) ? (now_w - from_right - new_w) : (left * scale);
	var new_top = (from_bottom < top) ? (now_h - from_bottom - new_h) : (top * scale);
	win.css({
		'width': new_w + 'px',
		'height': new_h + 'px',
		'left': Math.max(0, Math.round(new_left)) + 'px',
		'top': Math.max(0, Math.round(new_top)) + 'px'
	});
	// The window is pinned, so the fit that follows would save this screen's
	// rescaled size over the place the person actually pinned - a place opened
	// once on a small screen would shrink for good. The save is held off until
	// the window has settled; only a move or resize after that is a new place.
	win.attr('place_restoring', '1');
	setTimeout(function() { win.removeAttr('place_restoring'); }, 900);
}

$(document).on('click', '.place_button', function(e) {
	e.preventDefault();
	e.stopPropagation();
	var button = $(this);
	var win = button.closest('.wind');
	var app = win.attr('app');
	if (!win.length || !app) { return; }
	if (button.attr('status') == 'on') {
		// let it tile again: no place of its own, and the next open cascades it
		button.attr('status', 'off');
		win.attr('pre_dimensioned', 0);
		settingDeleter({ 'app': app, 'setting': 'dimensions' });
		settingSetter({ 'app': app, 'setting': 'place', 'value': 'tile' });
	}
	else {
		// keep it as it sits, on the screen it sits on
		button.attr('status', 'on');
		win.attr('pre_dimensioned', 1);
		windowDimensionSetter(win);
		settingSetter({ 'app': app, 'setting': 'place', 'value': 'lock' });
		// a pinned window has a place of its own, so it leaves the tile: the
		// windows below it close the slot it held
		if (typeof windowTiledLeave === 'function') { windowTiledLeave(win, false); }
	}
});


// ---------------------------------------------------------------- the bar's quiet controls
//
// The app icon in the title bar opens the two controls a window does not need
// in front of it all the time: Help (or the page agent, on Internet) and the
// pin. Six buttons crowded a narrow window and left the name a sliver; with
// them behind the icon the bar shows the name and the four window controls, and
// the name is pushed right only while the two are out.
function navbarReveal(el) {
	var bar = $(el).closest('.top_navbar');
	if (!bar.length) { return false; }
	var open = bar.attr('revealed') == 'yes';
	$('.top_navbar[revealed="yes"]').attr('revealed', 'no');
	bar.attr('revealed', open ? 'no' : 'yes');
	// false keeps the press from reaching the document handler below, which is
	// what closes a revealed bar when the person clicks anywhere else
	return false;
}

// A press anywhere outside the revealed pair (or the icon that opened it) puts
// them away again, the way a menu closes.
$(document).on('click touchend', function(e) {
	if ($('.top_navbar[revealed="yes"]').length == 0) { return; }
	if ($(e.target).closest('.window_icon_holder, .navbar_reveal').length) { return; }
	$('.top_navbar[revealed="yes"]').attr('revealed', 'no');
});

$(document).on('keydown', function(e) {
	if (e.key != 'Escape') { return; }
	$('.top_navbar[revealed="yes"]').attr('revealed', 'no');
});

$(document).on('click touchend', '.close_button', function(e) {
  // Prevent the event from bubbling up to the draggable container
  e.stopPropagation();
  e.preventDefault();
  if (e.type == 'touchend' && typeof jawnosSuppressClick == 'function') {
    // the window leaves the page under the finger; keep the browser's delayed
    // click from landing on whatever sits underneath it. Only a click at the
    // finger is held back, so the next tap elsewhere - a dot on the timeline,
    // say - keeps its click instead of paying for the closed window
    var t = (e.originalEvent && e.originalEvent.changedTouches) ? e.originalEvent.changedTouches[0] : undefined;
    jawnosSuppressClick(t ? t.clientX : undefined, t ? t.clientY : undefined);
  }
  
  // Retrieve the variables from data attributes
  var app = $(this).attr('app');
  var timestamp = $(this).attr('timestamp');
  
  // Execute your functions; a websocket that will not stop is no reason to
  // leave the window open
  try { websocketStop(app); } catch (err) { console.log('close: websocket stop failed', err); }
  closeWindow(timestamp);
});

$(document).on('click touchend', '.restore_button', function(e) {
  // Prevent the event from bubbling up to the draggable container
  e.stopPropagation();
  e.preventDefault();
  
  // Retrieve the variables from data attributes
  var app = $(this).attr('app');
  var timestamp = $(this).attr('timestamp');
  
	windowRestore(timestamp);
});

$(document).on('click touchend', '.minimize_button', function(e) {
  // Prevent the event from bubbling up to the draggable container
  e.stopPropagation();
  e.preventDefault();
  
  // Retrieve the variables from data attributes
  var app = $(this).attr('app');
  var timestamp = $(this).attr('timestamp');
  
	windowMinimizer(timestamp);
});


// Keep a window on the screen. These used to clamp against $(document) sizes,
// so any tall element that stretched the document let windows grow past the
// viewport. A phone window is always the full width of the screen, pinned
// left; anything overflowing gets its contents scrolled instead of spilled.
//
// The visual viewport is the one to trust for the on-screen keyboard: Android
// shrinks it while the keys are up and grows it back when they go. A window
// clamped for the keyboard remembers the height it wanted, and a later resize
// restores it instead of leaving the window small for the rest of the session.
function windowViewport() {
	var vv = window.visualViewport;
	var width = (vv && vv.width) ? vv.width : $(window).width();
	var height = (vv && vv.height) ? vv.height : $(window).height();
	return { width: Math.round(width), height: Math.round(height) };
}

function windowFit(win) {
	if (win.length == 0) { return; }
	var view = windowViewport();
	var viewW = view.width;
	var viewH = view.height;
	if (windowPhoneChecker()) {
		win.css({ 'left': 0, 'width': viewW });
	}
	var winLeft = Number(numeral(win.css('left')).format()) || 0;
	var winTop = Number(numeral(win.css('top')).format()) || 0;
	if (winLeft + win.width() > viewW) {
		win.width(Math.max(240, viewW - winLeft));
	}
	var wanted = parseFloat(win.attr('fit_height')) || 0;
	if (win.attr('fit_shrunk') == 'yes' && wanted && winTop + wanted <= viewH) {
		// the keyboard is gone (or the screen grew back): return the window to
		// the size it had before the shrink
		win.height(wanted);
		win.removeAttr('fit_shrunk').removeAttr('fit_height');
	}
	if (winTop + win.height() > viewH) {
		if (win.attr('fit_shrunk') != 'yes') {
			win.attr('fit_height', win.height()).attr('fit_shrunk', 'yes');
		}
		win.height(Math.max(240, viewH - winTop));
	}
	win.find('.window_contents').each(function () {
		var el = this;
		var cs = getComputedStyle(el);
		if (cs.overflow != 'visible') { return; }
		if (el.scrollHeight > el.clientHeight + 4 || el.scrollWidth > el.clientWidth + 4) {
			$(el).css('overflow', 'auto');
		}
	});
}

var windowFitTimer;
var windowFitLast = { width: 0, height: 0 };
function windowFitAllSoon() {
	clearTimeout(windowFitTimer);
	windowFitTimer = setTimeout(function () {
		var view = windowViewport();
		// ignore a viewport that moved but did not really change (the browser's
		// collapsing bar nudges it on every scroll)
		if (Math.abs(view.width - windowFitLast.width) < 2 && Math.abs(view.height - windowFitLast.height) < 2) { return; }
		var keyboard = windowPhoneChecker() && view.width === windowFitLast.width && view.height < windowFitLast.height;
		windowFitLast = view;
		// A height-only shrink is the on-screen keyboard. Only the window being
		// typed in needs the room; fitting every window made the whole page
		// rebuild itself under the person each time a field was focused.
		if (keyboard) {
			var active = document.activeElement;
			var holder = active && active.closest ? active.closest('.wind') : null;
			if (holder) { windowFit($(holder)); }
			return;
		}
		$('.wind').each(function () { windowFit($(this)); });
	}, 60);
}
$(window).on('resize orientationchange', windowFitAllSoon);
if (window.visualViewport) { window.visualViewport.addEventListener('resize', windowFitAllSoon); }
$(document).on('resizestop', '.wind', function () {
	// a person's own resize is the new wanted size
	$(this).removeAttr('fit_shrunk').removeAttr('fit_height');
	windowFit($(this));
});

function windowPhoneChecker() {
	if (navigator.userAgent.match('Android') || navigator.userAgent.match('Mobile')) {
		// the short side of the screen decides: a phone is still a phone in
		// landscape, and a tablet does not become one just by being narrow
		if (Math.min(screen.width, screen.height) < 500) {
			return true;
		}
		return false;
	}

	else {
		return false;
	}
}

function windowAligner() {
	
	$('.wind').each(function(i,v) {
		var width = $(this).width();
		$(this).css({'width': '100%' });		
	});
}

