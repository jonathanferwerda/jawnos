// ---------------------------------------------------------------- the tile
//
// Every window that is not anchored is a tile member (windowIsTiled in the
// index says which), and the tile is one straight vertical column of title
// bars: the front window first, then each one a bar lower. The front window is
// nudged a little to one side so the bars behind it keep a clickable edge. On a
// desk find-space mode moves the whole column into the first place that clears
// the anchored windows; without it the column starts at the left edge.

function windowTiledWindows() {
	var tiled = $('.wind').filter(function() {
		return windowIsTiled(this);
	});
	// the front window is first, so it takes the top of the column
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

// The column: front first, each title bar one bar lower than the last. The first
// (front) window is nudged right when there is room and left otherwise, so the
// bars below it keep an exposed edge. With obstacles (find-space mode) the whole
// column takes the first left edge whose frames clear them, and a nudge that
// would land on one is dropped.
function windowTileColumnPositions(windows, obstacles, view, startTop, stepX, nudge) {
	var positions = [];
	var tops = [];
	var y = startTop;
	for (var i = 0; i < windows.length; i++) {
		tops.push(y);
		y += windows[i].advance || windows[i].bar || 40;
	}
	var maxWidth = 0;
	for (var w = 0; w < windows.length; w++) {
		maxWidth = Math.max(maxWidth, windows[w].width || 0);
	}
	var maxLeft = Math.max(0, view.width - Math.min(maxWidth, view.width));
	stepX = stepX || 50;
	var base = 0;
	if (obstacles && obstacles.length) {
		var found = false;
		for (var left = 0; left <= maxLeft && !found; left += stepX) {
			var clear = true;
			for (var j = 0; j < windows.length; j++) {
				var frame = { left: left, top: tops[j], width: windows[j].width || 0, height: windows[j].height || 0 };
				if (windowRectHits(frame, obstacles)) { clear = false; break; }
			}
			if (clear) { base = left; found = true; }
		}
	}
	var walls = obstacles || [];
	for (var k = 0; k < windows.length; k++) {
		var win = windows[k];
		var spot = { left: base, top: tops[k] };
		if (k === 0 && nudge) {
			var right = base + nudge;
			var left_spot = base - nudge;
			var right_frame = { left: right, top: tops[k], width: win.width || 0, height: win.height || 0 };
			var left_frame = { left: left_spot, top: tops[k], width: win.width || 0, height: win.height || 0 };
			if (right + (win.width || 0) <= view.width && !windowRectHits(right_frame, walls)) {
				spot.left = right;
			}
			else if (left_spot >= 0 && !windowRectHits(left_frame, walls)) {
				spot.left = left_spot;
			}
		}
		positions.push(spot);
	}
	return positions;
}

// Anchored windows are the only windows with a place of their own; the column
// flows around them in find-space mode.
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

function windowArrangeTile(avoidAnchors) {
	if (windowPhoneChecker()) { return; }
	var windows = windowTiledWindows().filter(':visible');
	var specs = [];
	var targets = [];
	windows.each(function() {
		var win = $(this);
		var bar = win.find('.top_navbar').first();
		var step = bar.outerHeight() || 40;
		specs.push({
			width: win.width(),
			height: win.height(),
			bar: step,
			advance: step - (parseFloat(bar.css('border-top-width')) || 0)
		});
		targets.push(win);
	});
	var obstacles = avoidAnchors ? windowAnchoredRects() : [];
	var positions = windowTileColumnPositions(specs, obstacles, windowViewport(), windowTopLimit(), 50, 18);
	for (var i = 0; i < targets.length; i++) {
		targets[i].css({ 'left': positions[i].left, 'top': positions[i].top });
		windowFit(targets[i]);
	}
}

function windowTileArrange() {
	windowArrangeTile(false);
}

function windowFindSpaceArrange() {
	windowArrangeTile(true);
}

// A press raises the window (topLevelNow did) and the new front takes the top
// of the column, with the side nudge that keeps the bars behind it reachable.
function windowTileClick(win) {
	if (!win || !$(win).length) { return; }
	if (!windowIsTiled(win)) { return; }
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
}

var windowFindSpaceMode = false;

function windowFindSpaceActive() {
	return windowFindSpaceMode;
}

// A title-bar double-press is the whole switch: find-space lays the column
// around the places that are already held, and the second press puts it back at
// the left edge.
function windowFindSpaceToggle() {
	windowFindSpaceMode = !windowFindSpaceMode;
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
	return windowFindSpaceMode;
}

// A window that joined, left or changed its held place moves an obstacle the
// column has to flow around again. Outside find-space mode there is nothing to do.
function windowFindSpaceRefresh() {
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
}
