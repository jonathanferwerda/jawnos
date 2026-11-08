// ---------------------------------------------------------------- the tile
//
// The windows without a place of their own are the tiles the manager may move.
// A pin keeps a window where it is, a drag gives it the person's own place, and
// a maximized window fills the desk, so none of those take a slot (windowIsTiled
// in the index says which). On a desk the tile is a cascade; find-space mode
// asks every tiled window to look for the first clear title-bar slot instead,
// so an anchored window never hides one.

function windowTiledWindows() {
	return $('.wind').filter(function() {
		return windowIsTiled(this);
	});
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

// The slots find-space mode hands out: top to bottom, then left to right. The
// whole frame has to clear an obstacle (an anchored or dragged window), and the
// title bar has to clear every bar already placed, so each bar stays visible.
// No sizes change: a window keeps its width and height and only its place moves.
function windowFindSpacePositions(windows, obstacles, view, startTop, bottomClearance, stepX) {
	var positions = [];
	var placed = [];
	var floor = view.height - (bottomClearance || 0);
	stepX = stepX || 50;
	for (var i = 0; i < windows.length; i++) {
		var w = windows[i];
		var bar = w.bar || 40;
		var width = w.width || 0;
		var maxLeft = Math.max(0, view.width - Math.min(width, view.width));
		var maxTop = Math.max(startTop, floor - bar);
		var spot = null;
		for (var top = startTop; top <= maxTop && !spot; top += bar) {
			for (var left = 0; left <= maxLeft; left += stepX) {
				var frame = { left: left, top: top, width: width, height: w.height || 0 };
				var bar_rect = { left: left, top: top, width: width, height: bar };
				if (windowRectHits(frame, obstacles)) { continue; }
				if (windowRectHits(bar_rect, placed)) { continue; }
				spot = { left: left, top: top };
				placed.push(bar_rect);
				break;
			}
		}
		if (!spot) {
			// No clear slot: fall back to the plain cascade, keeping the bar on
			// the desk where the desk is deep enough for it.
			spot = {
				left: Math.min(i * stepX, maxLeft),
				top: Math.min(startTop + i * bar, maxTop)
			};
			placed.push({ left: spot.left, top: spot.top, width: width, height: bar });
		}
		positions.push(spot);
	}
	return positions;
}

// Anchored windows and windows the person dragged out of the tile hold their
// space; the tile flows around them.
function windowFindSpaceObstacles() {
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

function windowFindSpaceArrange() {
	if (windowPhoneChecker()) { return; }
	var windows = windowTiledWindows().filter(':visible');
	var specs = [];
	var targets = [];
	windows.each(function() {
		var win = $(this);
		var bar = win.find('.top_navbar').first();
		specs.push({ width: win.width(), height: win.height(), bar: bar.outerHeight() || 40 });
		targets.push(win);
	});
	var positions = windowFindSpacePositions(specs, windowFindSpaceObstacles(), windowViewport(),
		windowTopLimit(), windowBottomClearance(), 50);
	for (var i = 0; i < targets.length; i++) {
		targets[i].css({ 'left': positions[i].left, 'top': positions[i].top });
		windowFit(targets[i]);
	}
}

// Back to the usual desk tile: each window a title bar below and a step across
// from the one before.
function windowTileArrange() {
	if (windowPhoneChecker()) { return; }
	var left = 0;
	var top = windowTopLimit();
	windowTiledWindows().filter(':visible').each(function() {
		var win = $(this);
		var bar = win.find('.top_navbar').first();
		var step = bar.outerHeight() || 40;
		var advance = step - (parseFloat(bar.css('border-top-width')) || 0);
		win.css({ 'left': left, 'top': top });
		windowFit(win);
		left += 50;
		top += advance;
	});
}

var windowFindSpaceMode = false;

function windowFindSpaceActive() {
	return windowFindSpaceMode;
}

// A title-bar double-press is the whole switch: find-space lays the tile around
// the places that are already held, and the second press cascades it again.
function windowFindSpaceToggle() {
	windowFindSpaceMode = !windowFindSpaceMode;
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
	return windowFindSpaceMode;
}

// A window that joined, left or changed its held place is an obstacle the tile
// has to flow around again. Outside find-space mode there is nothing to do.
function windowFindSpaceRefresh() {
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
}
