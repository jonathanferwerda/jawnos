function windowMinimizer(timestamp,app) {
	var win = $('#window_' + timestamp);
	if (app) {
		win = $('.wind[app="' + app + '"]');
	}
	if (win.is(':visible')) {
		// the effect owns the hide while it plays, so the size the taskbar keeps is
		// read while the window still has one (a 50% width reads as 50 on a hidden
		// element, which is not the size to come back to); with effects off the
		// hide happens here, as it always did
		var effecting = (typeof jawnosWindowMinimizeOut == 'function') && jawnosWindowMinimizeOut(win);
		if (!effecting) { win.hide(); }
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
		if (typeof jawnosWindowRestoreIn == 'function') { jawnosWindowRestoreIn(win); }
	}
	windowDimensionSetter(win);
	// the window that steps forward or away from the front owns the keyboard cue
	if (typeof jawnosWindowFocusApply == 'function') { jawnosWindowFocusApply(); }
}

// The box the half snap takes: from the header's own line to the foot the desk
// leaves free, half the screen wide, on the named side. windowHalfski applies
// it and the drag preview draws it, so the highlight is exactly where the
// window will land.
function windowHalfRect(side) {
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
	// the foot also stops on the dock's own top edge. A see-through dock that keeps
	// the search elsewhere leaves no strip, so nothing is added for it and the
	// half runs under its faces.
	var foot = $(window).height() - windowBottomClearance();
	var search_in_dock = $('#search_entanglement').closest('#pseudonym_home').length > 0;
	var dock_on_bottom = (typeof jawnosDockTop == 'function' && !jawnosDockTop())
		&& (typeof jawnosSideDock == 'function' && !jawnosSideDock())
		&& (typeof jawnosDockHidden == 'function' && !jawnosDockHidden());
	if (search_in_dock && dock_on_bottom) {
		var dock = $('#pseudonym_home');
		if (dock.length) { foot = Math.min(foot, dock.offset().top); }
	}
	var right = (side == 'right');
	return {
		side: right ? 'right' : 'left',
		left: right ? (ww / 2) : 0,
		top: ok,
		width: ww / 2,
		height: foot - ok
	};
}

// The band at either edge that owns a drop as the half snap. It is a short
// reach in from the edge itself - not a share of the desk - so a window moved
// toward a side to sit nearer it is not snapped in half by accident. The
// highlight (windows.js windowTiledPreview), the drop (windowHalfski) and the
// drag stop all ask this, so what is drawn is what happens.
var JAWNOS_HALF_EDGE = 32;

function windowHalfEdgeAt(x) {
	if (typeof x != 'number' || !isFinite(x)) { return ''; }
	var ww = $(window).width();
	if (!ww) { return ''; }
	if (x <= JAWNOS_HALF_EDGE) { return 'left'; }
	if (x >= ww - JAWNOS_HALF_EDGE) { return 'right'; }
	return '';
}

function windowHalfski(win,side) {

	var mouse = { x: null, y: null };
	if (!side) {
		mouse = mouse_position();
	}
	if (!windowPhoneChecker()) {
		var to = side || windowHalfEdgeAt(mouse.x);
		if (to) {
			var box = windowHalfRect(to);
			// The frame the hand let go of, measured before the box changes: the
			// half grows out of this rectangle rather than resizing in place.
			var before = null;
			var el = win[0];
			if (el && el.getBoundingClientRect) {
				var measured = el.getBoundingClientRect();
				if (measured && measured.width && measured.height) { before = measured; }
			}
			win.css({
				'position':'fixed',
				'height': box.height,
				'width': '50%',
				'left': (to == 'right') ? '50%' : '0%',
				'top': box.top
			});
			windowDimensionSetter(win);
			// The CSS box above is already the final half; the motion is a
			// transform only, so free_dimensions and the half highlight see it.
			if (typeof jawnosWindowHalfSnap == 'function') { jawnosWindowHalfSnap(win, before); }
			return;
		}
		windowDimensionSetter(win);
	}
}

// The half snap grows out of the frame the window was dropped with. The CSS box
// is already the half, so a transform maps that half back onto the release
// rectangle and settles to identity: the window travels and stretches from
// where the hand let go instead of resizing where it stood. Only transform
// animates and the layout box is never written, so free_dimensions keeps the
// exact pre-snap width/height the drag-out restores, and the final box is the
// half to the pixel.
function jawnosWindowHalfSnap(win, before) {
	if (!win || !win.length || !before || !(before.width > 0) || !(before.height > 0)) { return false; }
	// the off level and a reduced-motion desk get the half with no motion at all
	if (typeof jawnosWindowEmergeLevel == 'function') {
		if (jawnosWindowEmergeLevel() == 'off') { return false; }
	}
	else if (typeof jawnosWindowEffectsOn == 'function' && !jawnosWindowEffectsOn()) {
		return false;
	}
	if (typeof jawnosWindowEmergeReduced == 'function' && jawnosWindowEmergeReduced()) { return false; }
	var el = win[0];
	if (!el || typeof el.animate != 'function' || !el.getBoundingClientRect) {
		if (typeof jawnosWindowEffect == 'function') { jawnosWindowEffect(win, 'stretch'); }
		return false;
	}
	// a wobble transform would be inside the measured box; the snap replaces it
	if (typeof jawnosWindowEffectCancel == 'function') { jawnosWindowEffectCancel(el); }
	var after = el.getBoundingClientRect();
	if (!after || !after.width || !after.height) { return false; }
	// the rect is display-zoomed; a transform is written in the root's units
	var zoom = (typeof jawnosWindowEmergeZoom == 'function') ? jawnosWindowEmergeZoom(null, after) : 1;
	if (!(zoom > 0)) { zoom = 1; }
	var sx = before.width / after.width;
	var sy = before.height / after.height;
	var dx = (before.left - after.left) / zoom;
	var dy = (before.top - after.top) / zoom;
	if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5
		&& Math.abs(sx - 1) < 0.005 && Math.abs(sy - 1) < 0.005) { return false; }
	var level = (typeof jawnosWindowEmergeLevel == 'function') ? jawnosWindowEmergeLevel() : 'medium';
	var shape = (typeof jawnosWindowEmergeShape != 'undefined' && jawnosWindowEmergeShape[level])
		? jawnosWindowEmergeShape[level] : { retarget: 220 };
	var duration = Math.max(120, Math.round(shape.retarget || 220));
	el.style.transformOrigin = '0 0';
	el.jawnosHalfSnapOrigin = true;
	var anim = el.animate([
		{ transform: 'translate(' + jawnosHalfRound(dx) + 'px, ' + jawnosHalfRound(dy) + 'px) scale(' + jawnosHalfRound(sx) + ', ' + jawnosHalfRound(sy) + ')' },
		{ transform: 'translate(0px, 0px) scale(1, 1)' }
	], {
		duration: duration,
		easing: 'cubic-bezier(.2,.85,.25,1)',
		fill: 'both'
	});
	// the emerge teardown owns the one-shot animation slot, so a drag or a
	// minimize cancels this the same way it cancels a window still pouring out
	el.jawnosEmergeWindowAnim = anim;
	var finish = function () {
		if (el.jawnosHalfSnapOrigin) {
			el.style.transformOrigin = '';
			el.jawnosHalfSnapOrigin = false;
		}
	};
	anim.onfinish = finish;
	anim.oncancel = finish;
	return true;
}

function jawnosHalfRound(value) {
	return Math.round(value * 1000) / 1000;
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
	var box = windowMaxRect();
	win.css({ 
		'position':'fixed', 
		'height': box.height, 
		'width': box.width,
		'left': box.left,
		'top': box.top
	});
	$('#window_contents_' + timestamp ).css({ 'width': '100%' });
	windowDimensionSetter($('#window_' + timestamp ));
	if (typeof jawnosWindowEffect == 'function') { jawnosWindowEffect(win, 'stretch'); }
}

// The box a maximized window takes: from the top limit to the foot clearance - a
// bottom taskbar and the strip a bottom dock keeps on screen - so no band of
// desktop shows beneath it and its own foot controls clear the dock. A
// see-through dock that keeps the search elsewhere leaves no strip, so the
// window runs to the foot of the screen under it. The old fixed percentages left
// that band (and overran the foot on a short screen). The phone keeps its own
// shorter face: a share of the desk unless its icon row is hidden, when the foot
// is measured. windowMaximizer applies this box and a bar change re-fits with it,
// so the two can never disagree.
function windowMaxRect() {
	var top = windowTopLimit();
	if (windowPhoneChecker()) {
		var hidden = (typeof jawnosDockIconsHidden == 'function') && jawnosDockIconsHidden();
		var tall = hidden ? Math.max(200, $(window).height() - top - windowBottomClearance() - 6) : null;
		return { left: '0px', top: top, width: '98%', height: tall ? tall + 'px' : '80%' };
	}
	return {
		left: '0px',
		top: top,
		width: '100%',
		height: Math.max(200, $(window).height() - top - windowBottomClearance()) + 'px'
	};
}
// The foot a window owns can move without the window being touched: the dock's
// Transparent row, the search moving in or out of the dock, the taskbar's height
// or edge. A half or maximized window is re-fitted through the same helpers that
// placed it, so its foot follows the new clearance instead of keeping the screen
// the desk had when it was snapped. A window whose foot is already right is left
// alone, and a window filling the whole glass keeps its own box.
function jawnosWindowFootApply() {
	$('.wind').each(function () {
		var win = $(this);
		var view = win.attr('view');
		if (view != 'max' && view != 'left' && view != 'right') { return; }
		if (!win.is(':visible') || win.hasClass('window_full_viewport')) { return; }
		var wanted = (view == 'max') ? windowMaxRect().height : windowHalfRect(view).height;
		var current = (win[0] && win[0].style) ? win[0].style.height : '';
		var a = parseFloat(wanted);
		var b = parseFloat(current);
		if (isFinite(a) && isFinite(b) && Math.abs(a - b) < 0.5) { return; }
		if (view == 'max') { windowMaximizer(win.attr('timestamp'), win.attr('app')); }
		else { windowHalfski(win, view); }
	});
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
	if (typeof jawnosWindowEffect == 'function') { jawnosWindowEffect(win, 'in'); }
}

// ---------------------------------------------------------------- the whole glass
//
// A window can be given the whole screen, over the dock and the taskbar, with
// its own title bar put away. The button lives beside the pin, in the title
// bar; because that bar is hidden while the window fills the screen, the way
// back waits in the very top right corner and shows itself when the pointer
// reaches it. The box the window leaves is kept on the element, so leaving
// puts it back exactly where it was, whether it had been tiled or maximised.
function jawnosWindowFullViewportBox(win) {
	return {
		left: win.css('left'),
		top: win.css('top'),
		width: win.css('width'),
		height: win.css('height')
	};
}

function windowFullViewportEnter(win) {
	win = $(win);
	if (!win.length || win.hasClass('window_full_viewport')) { return; }
	// A launcher shell already fills the glass; the control is hidden there and
	// a script or a queued press must not put it back over the app.
	if (typeof jawnosLauncherShell == 'function' && jawnosLauncherShell()) { return; }
	win.data('window-full-viewport-box', jawnosWindowFullViewportBox(win));
	win.addClass('window_full_viewport');
	if (typeof jawnosWindowEffect == 'function') { jawnosWindowEffect(win, 'stretch'); }
}

function windowFullViewportLeave(win) {
	win = $(win);
	if (!win.length || !win.hasClass('window_full_viewport')) { return; }
	var box = win.data('window-full-viewport-box');
	win.removeClass('window_full_viewport').removeData('window-full-viewport-box');
	if (box) {
		win.css({ 'position': 'fixed', 'left': box.left, 'top': box.top, 'width': box.width, 'height': box.height });
		windowDimensionSetter(win);
	}
	if (typeof jawnosWindowEffect == 'function') { jawnosWindowEffect(win, 'stretch'); }
}

$(document).on('click', '.fullview_button', function(e) {
	e.preventDefault();
	e.stopPropagation();
	windowFullViewportEnter($(this).closest('.wind'));
});

$(document).on('click', '.fullview_exit_button', function(e) {
	e.preventDefault();
	e.stopPropagation();
	windowFullViewportLeave($(this).closest('.wind'));
});

function windowRestorer(timestamp,app) {
	var win = $('#window_' + timestamp);
	if (app) {
		win = $('.wind[app="' + app + '"]');
	}
	if (!win.is(':visible') || (typeof jawnosWindowEffectLeaving == 'function' && jawnosWindowEffectLeaving(win))) {
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
		if (typeof jawnosWindowRestoreIn == 'function') { jawnosWindowRestoreIn(win); }
	}
	else {
		// the taskbar tile's own toggle hides through here too
		if (!(typeof jawnosWindowMinimizeOut == 'function' && jawnosWindowMinimizeOut(win))) { win.hide(); }
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

		// where the pointer went down and the box the window left: a click on the
		// title bar also starts and stops a drag, and only a real move takes the
		// window out of the tile. The box is the stack ground while the window is
		// outside its own place, so dragging back over it can still join. The pile
		// it was picked up from is named here too; the preview and the drop both
		// need it to tell a homecoming from a window that arrived free.
		var dragFrom = null;
		var dragFromTile = null;
		var dragFromStack = null;
		// the windows below it in the same pile: they travel with it, so a pile
		// cannot be cut in half by moving its head
		var dragGroup = [];

		win.draggable({
			cancel: 'input,textarea,button,select,option,.save_appointment,.app_act,.edit_app,.delete_app,.delete_location,.minimize_button,.restore_button,.maximize_button,.close_button',
			handle: '.top_navbar',
			start: function(p,ui) {
				dragFrom = { x: p.pageX, y: p.pageY };
				windowTiledDragging = true;
				dragFromStack = (windowTiledSlot(win) >= 0) ? windowTiledStackId(win) : null;
				dragGroup = [];
				var startSlot = windowTiledSlot(win);
				var startTop = parseFloat(win.css('top')) || 0;
				if (startSlot >= 0) {
					$('.wind').each(function() {
						if (this === win[0]) { return; }
						if (windowTiledStackId(this) !== dragFromStack) { return; }
						// the cascade below the held window is the block, read down the y
						// axis: grabbing the top-most window takes the whole pile with it
						if ((parseFloat($(this).css('top')) || 0) <= startTop) { return; }
						dragGroup.push({ el: this, left: parseFloat($(this).css('left')) || 0, top: parseFloat($(this).css('top')) || 0, width: parseFloat($(this).css('width')) || 0, height: parseFloat($(this).css('height')) || 0 });
					});
					dragGroup.sort(function(a, b) { return a.top - b.top; });
				}
				windows[p.target.id] = Date.now();
				// A window wearing a snapped view is a whole-screen shape; dragging it
				// gives back the size it had before it was snapped, under the pointer,
				// so it can leave the edge at the size the person knew. Dropped on an
				// edge, windowHalfski snaps it again; anywhere else it stays free.
				var snapped = win.attr('view');
				if ((snapped == 'max' || snapped == 'left' || snapped == 'right') && win.attr('free_dimensions')) {
					var d = JSON.parse(win.attr('free_dimensions'));
					var home_left = parseFloat(win.css('left')) || 0;
					var mouse = mouse_position();
					var wide = numeral(d.width).value();
					var left = mouse.x - (wide / 2);
					// keep the first frame on the desk: grabbed near an edge, the
					// centred window would otherwise hang half past it. The pointer
					// stays inside the window either way.
					var view_w = $(window).width();
					left = (wide < view_w) ? Math.max(0, Math.min(view_w - wide, left)) : 0;
					win.css({'position': 'fixed', 'height': d.height, 'width': d.width, 'left': left });
					// The grab offset was measured against the half (or full) width,
					// so a narrower window would trail the pointer by the difference.
					// Move the drag's anchor to the restored width's middle, and the
					// window comes out under the pointer and stays there.
					var inst = win.data('ui-draggable');
					if (inst && inst.offset && inst.offset.click) {
						inst.offset.click.left += home_left - left;
					}
					ui.position.left = left;
					win.find('.maximize_button').show();
					win.find('.restore_button').hide();
					windowDimensionSetter(win);
				}
				if (typeof jawnosWindowWobbleStart == 'function') { jawnosWindowWobbleStart(win, dragGroup); }
				dragFromTile = {
					left: parseFloat(win.css('left')) || 0,
					top: parseFloat(win.css('top')) || 0,
					width: parseFloat(win.css('width')) || 0,
					height: parseFloat(win.css('height')) || 0
				};
			},
			// Marker's own drawing of a window's place is in its app chunk, which may
			// not have been loaded: with no Marker window open there is no marker to
			// move. Calling it unguarded threw out of jQuery UI's drag callback, and
			// the exception stopped the window being moved at all.
			drag: function(p,ui) {
				if (typeof markerDragger === 'function') { markerDragger(p.target.id,'drag'); }
				if (typeof jawnosWindowWobbleMove == 'function') { jawnosWindowWobbleMove(win, p.pageX, p.pageY); }
				// the windows below the held one in its pile move with it, keeping the
				// cascade's own spacing, so the pile travels whole
				if (dragGroup.length && dragFromTile) {
					var dx = (parseFloat(win.css('left')) || 0) - dragFromTile.left;
					var dy = (parseFloat(win.css('top')) || 0) - dragFromTile.top;
					$.each(dragGroup, function(i, g) {
						$(g.el).css({ 'left': g.left + dx, 'top': g.top + dy });
					});
				}
				// show the slot the window would join while it is still in the hand,
				// and close the pile it is leaving at once rather than at the drop
				if (!windowPhoneChecker() && typeof windowTiledPreview === 'function') {
					windowTiledPreview(win, mouse_position(), dragFromTile, dragFromStack, dragGroup);
				}
			},
			stop: function(p,ui) {
				var d = mouse_position();
				var data = JSON.stringify(d);
				var now = Date.now();
				if (typeof jawnosWindowWobbleStop == 'function') { jawnosWindowWobbleStop(win); }
				var halfski = windowHalfski(win);
				$('#marker_targeting').hide();
				if (halfski == 'ya') {

				}
				else if (d.y < windowTopLimit() + 10) {
					var ok = windowTopLimit();
					var point = document.elementFromPoint(d.x, d.y) || 'null';
					var pd = $('#' + p.target.id).closest('.wind');
					var was = parseFloat(pd.css('top'));
					
					pd.css({ 'top': ok });
					// only a drop that really moved up to the line snaps: a click on the
					// title bar, or a release already at the limit, has nothing to land
					if (Math.abs(was - ok) > 0.5 && typeof jawnosWindowEffect == 'function') {
						jawnosWindowEffect(pd, 'snap');
					}
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
				// A window dragged by hand lands in the pile under the pointer (or
				// starts one on a window that is not in a pile), at the slot the held
				// title bar is over; off every pile it floats free. A click on the
				// title bar also starts and stops a drag without moving the pointer,
				// and that keeps the window in the tile where it is. A drag to either
				// edge is the half snap, which owns the window's place and takes it out
				// of the tile; a drag carrying the windows below it is a pile move, so
				// the edge keeps its hands off it.
				var edge = windowHalfEdgeAt(d.x) !== '';
				var moved = dragFrom && (Math.abs(p.pageX - dragFrom.x) > 4 || Math.abs(p.pageY - dragFrom.y) > 4);
				if (!windowPhoneChecker() && moved) {
					if (edge && !dragGroup.length) {
						if (typeof windowTiledLeave === 'function') { windowTiledLeave(win, true); }
					}
					else if (typeof windowTiledJoinOrLeave === 'function') {
						windowTiledJoinOrLeave(win, { x: d.x, y: d.y }, dragFromTile, dragFromStack, dragGroup);
					}
				}
				if (typeof windowTiledPreview === 'function') { windowTiledPreview(win, null, null, dragFromStack, dragGroup); }
				// a phone's pile is a cascade; a drag would leave the window over the
				// others' bars and swallow their taps, so restack it - to the top of
				// the pile - the moment the drag ends
				if (windowPhoneChecker()) { windowStacker(win.attr('app'), true); }
				dragFrom = null;
				dragFromTile = null;
				dragFromStack = null;
				dragGroup = [];
				windowTiledDragging = false;
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

// The pin's other half: a window that joins a pile is anchored no longer. The
// place it kept is dropped the same way the pin button drops it, so the window
// tiles like any other and a reload brings it back into its pile. Shared by the
// button and by a drop, which is the second way a window stops being anchored.
function windowAnchorRelease(win) {
	win = $(win);
	if (win.attr('pre_dimensioned') != 1) { return; }
	win.attr('pre_dimensioned', 0);
	win.find('.place_button').attr('status', 'off');
	var app = win.attr('app');
	if (!app) { return; }
	if (typeof settingDeleter === 'function') { settingDeleter({ 'app': app, 'setting': 'dimensions' }); }
	if (typeof settingSetter === 'function') { settingSetter({ 'app': app, 'setting': 'place', 'value': 'tile' }); }
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
		windowAnchorRelease(win);
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
	if (typeof jawnosWindowEffect == 'function') { jawnosWindowEffect(win, 'lock'); }
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
	// the whole glass already is the viewport, and a clamp here would write a
	// fit_height the way back would inherit
	if (win.hasClass('window_full_viewport')) { return; }
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
	// A window in a pile is not squeezed to fit the desk: the cascade stops short
	// of that, and a pile that would cover it starts a new one
	// (windowTiledCascadeFull). A free or pinned window still fits, and a phone
	// keeps its own fit until its pile decides where a new deck starts.
	var piled = !windowPhoneChecker() && typeof windowTiledSlot == 'function' && windowTiledSlot(win) >= 0;
	if (!piled && winTop + win.height() > viewH) {
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

