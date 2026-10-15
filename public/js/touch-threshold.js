/* A threshold for jQuery UI Touch Punch (loaded right after it).
 *
 * Stock Touch Punch calls any touchmove a drag: its _touchMove sets _touchMoved on
 * the very first move, and _touchEnd then withholds the synthetic click it fires in
 * place of the one it preventDefault'd. A finger almost always moves a pixel or two
 * while tapping, so nearly every tap lost its click - the buttons stopped answering.
 *
 * This keeps the same shim but only counts movement past a small threshold as a
 * drag: a tap (a few stray pixels) still registers as a click, and only a real drag
 * (past the threshold) moves the element and suppresses the click.
 */
(function ($) {
	if (!$ || !$.ui || !$.ui.mouse || !('ontouchend' in document)) { return; }
	var proto = $.ui.mouse.prototype;
	var THRESHOLD = 12;   // px a finger must travel before it counts as a drag
	var origin = null;

	var realStart = proto._touchStart;
	proto._touchStart = function (event) {
		var t = event.originalEvent.changedTouches && event.originalEvent.changedTouches[0];
		origin = t ? { x: t.clientX, y: t.clientY } : null;
		if (realStart) { realStart.call(this, event); }
	};

	var realMove = proto._touchMove;
	proto._touchMove = function (event) {
		// below the threshold the finger is still tapping: hold the page still and
		// do not let the drag begin. Past it, hand the move to Touch Punch as usual.
		if (origin && !this._touchMoved) {
			var t = event.originalEvent.changedTouches && event.originalEvent.changedTouches[0];
			if (t) {
				var dx = t.clientX - origin.x, dy = t.clientY - origin.y;
				if ((dx * dx + dy * dy) < (THRESHOLD * THRESHOLD)) {
					event.preventDefault();
					return;
				}
			}
		}
		if (realMove) { realMove.call(this, event); }
	};

	var realEnd = proto._touchEnd;
	proto._touchEnd = function (event) {
		origin = null;
		if (realEnd) { realEnd.call(this, event); }
	};
})(jQuery);
