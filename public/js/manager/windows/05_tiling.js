// ---------------------------------------------------------------- the tile
//
// Every window that is not anchored is a tile member (windowIsTiled in the
// index says which). The tile is a vertical rail of title bars: each unfocused
// window keeps only its navbar - icon, name and colour - so every window is
// visible and one press away. The focused window (the front one) leaves the
// rail and shows its whole frame beside it. An anchored window keeps the place
// and size it was pinned at, and find-space mode moves the rail clear of it.

function windowTiledWindows() {
	var tiled = $('.wind').filter(function() {
		return windowIsTiled(this);
	});
	// the front window is first, so it is the one shown in full
	tiled.sort(function(a, b) {
		return (parseInt($(b).css('z-index'), 10) || 0) - (parseInt($(a).css('z-index'), 10) || 0);
	});
	return tiled;
}

function windowRectsOverlap(a, b) {
	return a.left < b.left + b.width && b.left < a.left + a.width &&
	       a.top < b.top + b.height && b.top < a.top + a.height;
}

function windowRectHits(rect, list) {
	for (var i = 0; i < list.length; i++) {
		if (windowRectsOverlap(rect, list[i])) { return true; }
	}
	return false;
}

function windowOverlapArea(rect, list) {
	var area = 0;
	for (var i = 0; i < list.length; i++) {
		var other = list[i];
		var wide = Math.min(rect.left + rect.width, other.left + other.width) - Math.max(rect.left, other.left);
		var tall = Math.min(rect.top + rect.height, other.top + other.height) - Math.max(rect.top, other.top);
		if (wide > 0 && tall > 0) { area += wide * tall; }
	}
	return area;
}

// The rail's width: wide enough for the icon and a name, narrow enough to leave
// the focused window the desk.
function windowTileRailWidth(view) {
	return Math.max(160, Math.min(360, Math.round(view.width * 0.30)));
}

// The first left edge whose title-bar strip clears the anchored windows. A rail
// that cannot find a clear strip stays at the left edge; the anchored window
// still takes precedence over it.
function windowTileRailLeft(obstacles, view, railW, top, height) {
	var maxLeft = Math.max(0, view.width - railW);
	for (var left = 0; left <= maxLeft; left += 50) {
		if (!windowRectHits({ left: left, top: top, width: railW, height: height }, obstacles)) {
			return left;
		}
	}
	return 0;
}

// The tile's places. windows is the front-first list; the first becomes the
// focused frame beside the rail, the rest become title-bar rows. Returns
// { focus: {left,top,width,height}, rail: [{left,top,width,height}, ...] }.
function windowTileRailLayout(windows, obstacles, view, startTop, bottomClearance, railW, avoidAnchors) {
	var bar = (windows.length && windows[0].bar) || 40;
	var railCount = Math.max(0, windows.length - 1);
	var top = startTop;
	var floor = view.height - (bottomClearance || 0);
	var rail = [];
	var railGap = 6;
	// a stack runs from under the header to the foot the dock/taskbar leaves;
	// the next title bar starts a second stack instead of falling off the desk
	var rowsPerColumn = Math.max(1, Math.floor((floor - top) / bar));
	var columns = Math.max(1, Math.ceil(railCount / rowsPerColumn));
	var blockW = railCount ? columns * railW + (columns - 1) * railGap : 0;
	var blockH = Math.min(Math.max(0, floor - top), rowsPerColumn * bar);
	var railX = 0;
	if (obstacles && obstacles.length && railCount) {
		railX = windowTileRailLeft(obstacles, view, blockW, top, blockH);
	}
	for (var i = 0; i < railCount; i++) {
		var column = Math.floor(i / rowsPerColumn);
		var row = i % rowsPerColumn;
		rail.push({ left: railX + column * (railW + railGap), top: top + row * bar, width: railW, height: bar });
	}
	var gap = 12;
	var height = Math.max(200, floor - top);
	var walls = (avoidAnchors && obstacles) ? obstacles : [];
	var rightX = railCount ? railX + blockW + gap : 0;
	var leftEnd = railCount ? railX - gap : 0;
	var rightEnd = view.width;
	var leftStart = 0;
	// the focused frame reaches from the rail to the first held place on its
	// side, so an anchored window on the right is as good as one on the left
	for (var w = 0; w < walls.length; w++) {
		var wall = walls[w];
		if (wall.top >= top + height || wall.top + wall.height <= top) { continue; }
		if (wall.left >= rightX) { rightEnd = Math.min(rightEnd, wall.left); }
		if (wall.left + wall.width <= leftEnd) { leftStart = Math.max(leftStart, wall.left + wall.width); }
	}
	var rightW = Math.max(0, rightEnd - rightX);
	var leftW = Math.max(0, leftEnd - leftStart);
	var rightRect = { left: rightX, top: top, width: rightW, height: height };
	var leftRect = { left: leftStart, top: top, width: leftW, height: height };
	var rightOpen = windowOverlapArea(rightRect, walls);
	var leftOpen = windowOverlapArea(leftRect, walls);
	var useRight = rightOpen < leftOpen;
	if (rightOpen === leftOpen) { useRight = rightW >= leftW; }
	if (rightW <= 0 && leftW > 0) { useRight = false; }
	if (leftW <= 0 && rightW > 0) { useRight = true; }
	var focusX = useRight ? rightX : leftStart;
	var focusW = Math.max(0, useRight ? rightW : leftW);
	var front = windows[0] || { width: focusW, height: height };
	var focus = {
		left: focusX,
		top: top,
		width: Math.min(front.width || focusW, focusW),
		height: Math.min(front.height || height, height)
	};
	return { focus: focus, rail: rail };
}

// Anchored windows are the only windows with a place of their own; find-space
// mode flows the rail and the focused frame around them.
function windowAnchoredRects() {
	var list = [];
	$('.wind').each(function() {
		var win = $(this);
		if (windowIsTiled(win)) { return; }
		if (!win.is(':visible')) { return; }
		list.push({
			left: Number(numeral(win.css('left')).value()) || 0,
			top: Number(numeral(win.css('top')).value()) || 0,
			width: win.width(),
			height: win.height()
		});
	});
	return list;
}

// A window remembers the size it had before it joined the rail, so focusing it
// again restores the whole frame rather than a title-bar sliver.
function windowTileStoredSize(win) {
	if (!win.attr('tile_w') || !win.attr('tile_h')) {
		win.attr('tile_w', Math.round(win.width()) || 480);
		win.attr('tile_h', Math.round(win.height()) || 640);
	}
	if (!win.attr('tile_left') || !win.attr('tile_top')) {
		win.attr('tile_left', Math.round(parseFloat(win.css('left')) || 0));
		win.attr('tile_top', Math.round(parseFloat(win.css('top')) || 0));
	}
	return { width: parseFloat(win.attr('tile_w')) || 480, height: parseFloat(win.attr('tile_h')) || 640,
		left: parseFloat(win.attr('tile_left')) || 0, top: parseFloat(win.attr('tile_top')) || 0 };
}

function windowTileRememberSize(win) {
	win = $(win);
	if (!windowIsTiled(win) || win.hasClass('tile_rail')) { return; }
	win.attr('tile_w', Math.round(win.width())).attr('tile_h', Math.round(win.height()));
	win.attr('tile_left', Math.round(parseFloat(win.css('left')) || 0))
		.attr('tile_top', Math.round(parseFloat(win.css('top')) || 0));
}

function windowArrangeTile(avoidAnchors) {
	if (windowPhoneChecker()) { return; }
	var windows = windowTiledWindows().filter(':visible');
	if (!windows.length) { return; }
	var specs = [];
	var targets = [];
	windows.each(function() {
		var win = $(this);
		var size = windowTileStoredSize(win);
		var bar = win.find('.top_navbar').first();
		specs.push({ width: size.width, height: size.height, bar: bar.outerHeight() || 40 });
		targets.push(win);
	});
	var view = windowViewport();
	var railW = windowTileRailWidth(view);
	// the rail always steps around a held place so its names stay visible; the
	// focused frame only does so in find-space mode
	var layout = windowTileRailLayout(specs, windowAnchoredRects(),
		view, windowTopLimit(), windowBottomClearance(), railW, avoidAnchors);
	var focus = targets[0];
	focus.removeClass('tile_rail').addClass('tile_focus');
	focus.css({ left: layout.focus.left, top: layout.focus.top, width: layout.focus.width, height: layout.focus.height });
	windowFit(focus);
	for (var i = 1; i < targets.length; i++) {
		var spot = layout.rail[i - 1];
		targets[i].removeClass('tile_focus').addClass('tile_rail');
		targets[i].css({ left: spot.left, top: spot.top, width: spot.width, height: spot.height });
	}
}

function windowTileArrange() {
	windowArrangeTile(false);
}

function windowFindSpaceArrange() {
	windowArrangeTile(true);
}

// A press raises the window (topLevelNow did), and the new front leaves the
// rail for the focused frame.
function windowTileClick(win) {
	if (!win || !$(win).length) { return; }
	if (!windowIsTiled(win)) { return; }
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
}

// Pinning takes a window out of the tile. A rail row comes back at the whole
// size it held before it became a title-bar row; a focused window keeps the
// size it is showing. Either way the stacked title bar returns to the top.
function windowTileRelease(win) {
	win = $(win);
	var size = windowTileStoredSize(win);
	if (win.hasClass('tile_rail')) {
		win.css({ width: size.width, height: size.height, left: size.left, top: size.top });
	}
	win.removeClass('tile_rail').removeClass('tile_focus');
}

var windowFindSpaceMode = false;

function windowFindSpaceActive() {
	return windowFindSpaceMode;
}

// A title-bar double-press is the whole switch: find-space lays the rail
// around the places that are already held, and the second press returns it to
// the left edge.
function windowFindSpaceToggle() {
	windowFindSpaceMode = !windowFindSpaceMode;
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
	return windowFindSpaceMode;
}

// A window that joined, left or changed its held place moves an obstacle the
// rail has to flow around again.
function windowTileRefresh() {
	if (windowPhoneChecker()) { return; }
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
}
