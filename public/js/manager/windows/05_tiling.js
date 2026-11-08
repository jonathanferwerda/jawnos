// ---------------------------------------------------------------- the tile
//
// Every window that is not anchored is a tile member (windowIsTiled in the
// index says which). The tile is a stack: the most recently raised window sits
// at the top with its title bar at the top, and the windows behind it sit lower
// with their title bars at the foot, so every name stays visible. When the
// stack reaches the foot of the desk, a second stack starts to the right and
// finds room; stacks may overlap. If even that runs out, the windows that have
// waited longest since they were last raised stay hidden.

function windowTiledWindows() {
	var tiled = $('.wind').filter(function() {
		return windowIsTiled(this);
	});
	tiled.sort(function(a, b) {
		var la = parseInt($(a).attr('last_top'), 10) || 0;
		var lb = parseInt($(b).attr('last_top'), 10) || 0;
		if (la !== lb) { return lb - la; }
		return (parseInt($(b).css('z-index'), 10) || 0) - (parseInt($(a).css('z-index'), 10) || 0);
	});
	return tiled;
}

// A window the person has minimised is out of the stack until it comes back.
// A window hidden only because the stacks were full is still active: it is
// listed by the taskbar and comes back when a place opens.
function windowTileActive(win) {
	win = $(win);
	if (!windowIsTiled(win)) { return false; }
	if (win.attr('view') == 'minimized') { return false; }
	if (win.attr('visible') == 'no') { return false; }
	return true;
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

// How far the next stack steps across: enough of the title bar to read, while
// the stacks still overlap rather than shrinking a window.
function windowTileStackStep(view) {
	return Math.max(80, Math.min(360, Math.round(view.width * 0.22)));
}

function windowTileStackLeft(obstacles, view, from, top, height, width) {
	var maxLeft = Math.max(0, view.width - (width || 0));
	if (from > maxLeft) { return -1; }
	for (var left = Math.max(0, from); left <= maxLeft; left += 50) {
		if (!windowRectHits({ left: left, top: top, width: width || 0, height: height || 0 }, obstacles)) {
			return left;
		}
	}
	return -1;
}

// The stack places. windows is most-recent first. Each stack front shows its
// title bar at the top and its whole frame; each window behind it puts its title
// bar at the foot, one bar lower than the one before, so the names stay in a
// readable column. A full stack starts another one to its right. Windows left
// over when no stack can start are returned as hidden.
function windowTileStacks(windows, obstacles, view, startTop, bottomClearance, stackStep) {
	var bar = (windows.length && windows[0].bar) || 40;
	var floor = view.height - (bottomClearance || 0);
	var stacks = [];
	var hidden = [];
	var index = 0;
	var previousLeft = 0;
	while (index < windows.length) {
		var first = windows[index];
		var firstW = first.width || 0;
		var firstH = Math.min(first.height || bar, Math.max(bar, floor - startTop));
		var from = stacks.length ? previousLeft + stackStep : 0;
		var left = windowTileStackLeft(obstacles || [], view, from, startTop, Math.max(0, floor - startTop), firstW);
		if (left < 0) { break; }
		var items = [{ index: index, left: left, top: startTop, width: firstW, height: firstH, bar_top: true }];
		var cursor = startTop + firstH;
		index++;
		while (index < windows.length && cursor + bar <= floor) {
			var w = windows[index];
			var h = w.height || bar;
			items.push({ index: index, left: left, top: cursor + bar - h, width: w.width || 0, height: h, bar_top: false });
			cursor += bar;
			index++;
		}
		stacks.push({ left: left, items: items });
		previousLeft = left;
	}
	while (index < windows.length) { hidden.push(index); index++; }
	return { stacks: stacks, hidden: hidden };
}

// Anchored windows are the only windows with a place of their own; find-space
// mode makes the next stack step around them.
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

// The width and height a window had before the stack laid it out. Widths are
// never changed by the stack; this is what restores a window after a resize.
function windowTileStoredSize(win) {
	if (!win.attr('tile_w') || !win.attr('tile_h')) {
		win.attr('tile_w', Math.round(win.width()) || 480);
		win.attr('tile_h', Math.round(win.height()) || 640);
	}
	return { width: parseFloat(win.attr('tile_w')) || 480, height: parseFloat(win.attr('tile_h')) || 640 };
}

function windowTileRememberSize(win) {
	win = $(win);
	if (!windowIsTiled(win)) { return; }
	win.attr('tile_w', Math.round(win.width())).attr('tile_h', Math.round(win.height()));
}

function windowArrangeTile(avoidAnchors) {
	if (windowPhoneChecker()) { return; }
	var active = windowTiledWindows().filter(function() {
		return windowTileActive(this);
	});
	var specs = [];
	var targets = [];
	active.each(function() {
		var win = $(this);
		var size = windowTileStoredSize(win);
		var bar = win.find('.top_navbar').first();
		specs.push({ width: size.width, height: size.height, bar: bar.outerHeight() || 40 });
		targets.push(win);
	});
	var view = windowViewport();
	var layout = windowTileStacks(specs, avoidAnchors ? windowAnchoredRects() : [],
		view, windowTopLimit(), windowBottomClearance(), windowTileStackStep(view));
	var placed = {};
	for (var s = 0; s < layout.stacks.length; s++) {
		var stack = layout.stacks[s];
		for (var i = 0; i < stack.items.length; i++) {
			var spot = stack.items[i];
			var win = targets[spot.index];
			placed[spot.index] = 1;
			win.show();
			win.removeClass('tile_rail tile_focus');
			if (spot.bar_top) { win.removeClass('tile_bar_bottom'); }
			else { win.addClass('tile_bar_bottom'); }
			win.css({ left: spot.left, top: spot.top, width: spot.width, height: spot.height });
		}
	}
	for (var h = 0; h < layout.hidden.length; h++) {
		var hidden = targets[layout.hidden[h]];
		hidden.hide();
		hidden.removeClass('tile_bar_bottom');
	}
}

function windowTileArrange() {
	windowArrangeTile(false);
}

function windowFindSpaceArrange() {
	windowArrangeTile(true);
}

// A press raises the window (topLevelNow did) and lays the stack out again, so
// that window becomes the front of the first stack with its whole frame shown.
function windowTileClick(win) {
	if (!win || !$(win).length) { return; }
	if (!windowIsTiled(win)) { return; }
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
}

// Pinning takes a window out of the stack; its title bar goes back to the top
// of its own frame.
function windowTileRelease(win) {
	$(win).removeClass('tile_rail').removeClass('tile_focus').removeClass('tile_bar_bottom');
}

var windowFindSpaceMode = false;

function windowFindSpaceActive() {
	return windowFindSpaceMode;
}

// A title-bar double-press is the whole switch: find-space makes the next stack
// step around the places that are already held, and the second press lets the
// stacks use the whole desk again.
function windowFindSpaceToggle() {
	windowFindSpaceMode = !windowFindSpaceMode;
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
	return windowFindSpaceMode;
}

// A window that joined, left or changed its held place moves an obstacle the
// stack has to flow around again.
function windowTileRefresh() {
	if (windowPhoneChecker()) { return; }
	if (windowFindSpaceMode) { windowFindSpaceArrange(); }
	else { windowTileArrange(); }
}
