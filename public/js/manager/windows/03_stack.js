// Phones cascade their windows: windowReorganizer parks each one a title bar
// below the last, so the bars step down the screen and the window in front sits
// at the foot of the cascade. "Top of the pile" means by z-index, not height: the
// front window is the one wearing the highest z, and its bar is the lowest. That
// gives two jobs. Closing a window should close the gap - the bars below step up
// into its place - and a tap on a title bar should walk the pile: the top of the
// pile (the front window) drops to the bottom of the stack, and a window tapped
// lower down rises to the top of the pile. A tap on a window's body, and the end
// of a drag, restack too - they lift that window to the top of the pile - so no
// window is left lying over the others' bars, swallowing their taps. Desks place
// windows by hand wherever they like, so none of this applies there and it is a
// no-op.
function windowStacker(app, raise) {
	if (!windowPhoneChecker()) { return; }
	var visible = $('.wind').filter(':visible');
	if (visible.length == 0) { return; }

	// the pile by z-index - the back (lowest z) first, so the top of the pile
	// (the front window, highest z) is last. z is the pile's own order: a window
	// dragged about on screen keeps its place in it, where sorting by height would
	// mistake a window merely dragged low for the one in front.
	var order = visible.sort(function (a, b) {
		var za = parseInt($(a).css('z-index'), 10) || 0;
		var zb = parseInt($(b).css('z-index'), 10) || 0;
		if (za !== zb) { return za - zb; }
		return (parseFloat($(a).css('top')) || 0) - (parseFloat($(b).css('top')) || 0);
	}).toArray();

	if (app) {
		var target = $('.wind[app="' + app + '"]').get(0);
		if (!target || order.length < 2) { return; }
		// the walk stays inside the deck the press was made in, and brings that
		// deck forward; the other decks keep their own order
		var deck = windowDeckOf(target);
		var inside = order.filter(function (el) { return windowDeckOf(el) === deck; });
		var front = inside[inside.length - 1];
		if (raise) {
			// a press that is not the walk - a tap on a window's body, or the end of
			// a drag - lifts that window to the top of its deck and leaves the rest
			inside = inside.filter(function (el) { return el !== target; }).concat([target]);
		} else if (target === front) {
			// a tap on the top of the deck walks it down to the bottom of that deck
			inside = [front].concat(inside.filter(function (el) { return el !== front; }));
		} else {
			// a tap lower down lifts it to the top of the deck and drops the old top
			inside = [front].concat(inside.filter(function (el) { return el !== target && el !== front; }), [target]);
		}
		order = order.filter(function (el) { return windowDeckOf(el) !== deck; }).concat(inside);
		windowDeckTouch[deck] = Date.now();
	}

	// decks from the back to the front, each in its own order, so a walk cannot
	// pull one deck's windows through another's
	var decks = [];
	$(order).each(function () { var d = windowDeckOf(this); if (decks.indexOf(d) < 0) { decks.push(d); } });
	decks.sort(function (a, b) {
		var ta = windowDeckTouch[a] || (1000 + a), tb = windowDeckTouch[b] || (1000 + b);
		if (ta !== tb) { return ta - tb; }
		return a - b;
	});
	var stacked = [];
	decks.forEach(function (d) {
		$(order).each(function () { if (windowDeckOf(this) === d) { stacked.push(this); } });
	});
	var changed = false;
	$(stacked).each(function (i) {
		if ((parseInt($(this).css('z-index'), 10) || 0) !== (top_level_now + i + 1)) { changed = true; }
	});
	// a re-cascade that changes no order must not touch z (or the frame ring and
	// the taskbar pins churn on every restore timer)
	if (changed) {
		$(stacked).each(function (slot) { $(this).css({ 'z-index': top_level_now + slot + 1 }); });
		top_level_now = top_level_now + stacked.length;
	}
	order = stacked;

	// re-cascade each deck from the desk's top: a closed window leaves no gap,
	// and a fresh deck starts over the first one. Step each window down by the
	// height of the bar above it - measured, not a fixed step - so the bars sit
	// flush even when their heights differ; then pull it up by the bar's own
	// border, so this bar's foot and the next window's frame read as one line.
	var y = {};
	decks.forEach(function (d) { y[d] = windowTopLimit(); });
	$(order).each(function () {
		var win = $(this);
		var d = windowDeckOf(this);
		win.css({ 'top': y[d] });
		var bar = win.find('.top_navbar');
		var border = parseFloat(bar.css('border-top-width')) || 0;
		y[d] = y[d] + (bar.outerHeight() || 40) - border;
	});

	// raise the new front through topLevelNow so its frame ring and the taskbar
	// pins follow the order
	if (app) { topLevelNow($(order[order.length - 1])); }
}
// A phone's cascade is a deck. A deck holds until its next window would show
// less than a third of itself; the window after that starts a fresh cascade over
// the top of the last one, on the same x. The deck is a number on the window,
// the deck worked in most recently is the front one, and a walk stays inside the
// deck it was made in and brings that deck forward.
var windowDeckTouch = {};
// The deck each app was last placed in. A re-render that replaces the window's
// node drops its attributes, and this is what keeps that window in the deck it
// was in rather than dropping it to the first one.
var windowDeckByApp = {};

function windowDeckOf(win) {
	win = $(win);
	var deck = parseInt(win.attr('deck'), 10);
	if (!isNaN(deck)) { return deck; }
	var app = win.attr('app') || '';
	if (app && windowDeckByApp[app] !== undefined) { return windowDeckByApp[app]; }
	return 0;
}

function windowDeckFront() {
	var best = null, best_rank = -Infinity;
	$('.wind').filter(':visible').each(function () {
		var deck = windowDeckOf(this);
		var rank = windowDeckTouch[deck] || (1000 + deck);
		if (best === null || rank > best_rank || (rank === best_rank && deck > best)) { best = deck; best_rank = rank; }
	});
	return best === null ? 0 : best;
}

// The deck and the step a window opening now would take. `geom` lets the press
// preview ask before the window exists, and `self` is the window being placed so
// it is not counted in its own deck. A window that has lost its deck attribute
// (a re-render that replaced the node) reads as the first deck, so it still
// takes a step of its own rather than being left out of the count.
function windowPhoneCascadePlace(geom, self, keep) {
	var self_el = self ? $(self)[0] : null;
	var view = windowViewport();
	var step = geom && geom.step ? geom.step : 0;
	if (!(step > 0)) {
		var bar = $('.wind').first().find('.top_navbar');
		step = (bar.outerHeight() || 40) - (parseFloat(bar.css('border-top-width')) || 0);
	}
	if (!(step > 0)) { step = 40; }
	// A phone's deck is a row of bars down the screen: the deck is full when the
	// bars it would add take more than a third of the glass. On an S24 FE that is
	// six windows, which is what a stack there holds.
	var limit = windowStackVisible * view.height;
	var decks = {};
	$('.wind').filter(':visible').each(function () {
		if (self_el && this === self_el) { return; }
		var deck = windowDeckOf(this);
		decks[deck] = (decks[deck] || 0) + 1;
	});
	// a window coming back into a deck it already belonged to stays in it
	var front = (keep !== undefined && keep !== null) ? keep : windowDeckFront();
	var count = decks[front] || 0;
	if (count * step <= limit) { return { deck: front, slot: count, top: windowTopLimit() }; }
	return { deck: front + 1, slot: 0, top: windowTopLimit() };
}

function windowRefresher(app) {
	var json_storage = sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) ? JSON.parse(json_storage) : {};
	var view = $.grep(storage, function(i,v) {
		return app == i;
	});
	if (view[0]) {
		$('.wind[app="' + app + '"]').css({ 'top': view[0].top, 'left': view[0].left, 'height': view[0].height, 'width': view[0].width });
	}
}

// The teardown is everything the close did before there was a motion: the app's
// own shutdown, the window's removal, and the bookkeeping the server and the
// desk keep. closeWindow() plays the level's farewell first and hands it this,
// or runs it at once when the desk wants no motion.
function windowCloseTearDown(timestamp, win, done) {

	win.find('.window_script').remove();
	var app = win.attr('app');
	// the teardown runs once per window (closeWindow guards a second request), so
	// this is the close transition itself, not a re-render
	if (win.length && typeof windowEventSend == 'function') { windowEventSend('close', app, win.attr('id')); }
	if (app == 'twirl') {
		if (typeof twirlTeardown == 'function') { twirlTeardown(); }
		twirlRunning = false;
		if (typeof jawnosGameSessionGame === 'function' && jawnosGameSessionGame() === 'Twirl'
			&& typeof jawnosGameSessionStop === 'function') { jawnosGameSessionStop(); }
	}
	// Pipedream and Minesweeper each own one play session; closing the window is
	// the end of it, not a pause.
	if (app == 'pipedream' || app == 'minesweeper') {
		var own_game = (typeof jawnosGameSessionGame === 'function') ? jawnosGameSessionGame() : '';
		if ((app == 'pipedream' && own_game === 'Pipedream')
			|| (app == 'minesweeper' && own_game === 'Minesweeper')) {
			if (typeof jawnosGameSessionStop === 'function') { jawnosGameSessionStop(); }
		}
	}
	// Closing the card room is the end of its game: the pane being hidden is only
	// a pause. Only the card games are stopped, so closing a background Cards
	// window cannot end a Twirl session.
	if (app == 'cards' && typeof jawnosGameSessionGame === 'function' && typeof jawnosGameSessionStop === 'function') {
		var card_game = jawnosGameSessionGame();
		if (card_game === 'Solitaire' || card_game === 'Spider Solitaire' || card_game === 'Mahjong' || card_game === 'Blackjack') {
			jawnosGameSessionStop();
		}
	}
	if (app == 'mailbox' && typeof mailSocketClose == 'function') { mailSocketClose(); }
	// A Travel map's vector basemap is its own GL renderer and worker; closing
	// the window has to let go of it, or the map outlives the stage it drew on.
	if (app == 'travel' && typeof travelMap !== 'undefined' && travelMap && typeof travelMap.destroy === 'function') {
		try { travelMap.destroy(); } catch (e) {}
		travelMap = null;
	}
	// closing the app closes its padlock in this tab as well as on the server
	if ((app == 'gallery' || app == 'music' || app == 'folders') && typeof jawnosMediaLockdown === 'function') {
		jawnosMediaLockdown(app, true);
	}
	// the tiled windows below close the step this one leaves, the way a phone's
	// pile does; a pinned window has no step to close
	var was_full = win.hasClass('full_app_window');
	if (typeof windowTiledGapClose === 'function') { windowTiledGapClose(win); }
	$('#window_' + timestamp ).remove();
	// closing the last launcher app hands the desk back; without this the body
	// stayed in full-app mode with no window and the taskbar stayed hidden
	if (was_full && !$('.wind.full_app_window').length) { document.body.classList.remove('full_app_mode'); }
	// the pile's front follows its slots, and the closed window no longer has one
	if (typeof windowTiledFront === 'function') { windowTiledFront(); }
	$('#window_icon_' + timestamp).remove();
	// Closing the window that owns the dock puts the keys away with it, rather
	// than leaving them aimed at a field that is no longer on the page.
	if (typeof jawnSoftField !== 'undefined' && jawnSoftField && win.length && $.contains(win[0], jawnSoftField)) {
		if (typeof softKbHide == 'function') { softKbHide(); }
	}
	//pseudonymFreeSpaceFinder();
	$('#little_window_' + timestamp).remove();
	var window_saver = sessionStorage.getItem('window_storage');
	var open_windows = JSON.parse(window_saver) || {};
	delete open_windows[app];
	var new_windows = JSON.stringify(open_windows);
	sessionStorage.setItem('window_storage', new_windows);
	$('#window_script_' + timestamp).remove();
	$('.window_script_' + timestamp).remove();
	$.ajax({
		url: '/manager/window_closer',
		type: 'POST',
		data: { timestamp: timestamp, app: app, browser_tab_id: sessionStorage.getItem('browser_tab_id') || (typeof bti !== 'undefined' ? bti : ''), device_uuid: (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : '' },
		success: function(response) {
			websocketStop(app);
			if (typeof done === 'function') { done(); }
		},
		error: function() {
			// The window is already gone from this page. The saved list is the
			// part that matters for the next open, and windowSaver() wrote it
			// above; leave the page even if the server call failed.
			if (typeof done === 'function') { done(); }
		}
	});
	windowSaver();
	startMenuDisplayer();
	windowBackgroundAdjuster();
	// a phone layers its windows on one another, so the layers left behind
	// want re-parking against the smaller count
	if (windowPhoneChecker()) { windowStacker(); }
}

// A close is a farewell and then the teardown. The motion belongs to the
// effects level; with it off (or reduced motion) nothing is delayed and the
// window goes at once, exactly as before.
function closeWindow(timestamp, done) {
	var win = $('#window_' + timestamp);
	// a close already playing owns this window: a second request must not tear
	// it down twice, so it waits for the first one to finish
	if (win.length && win[0].jawnosCloseToken) {
		if (typeof done == 'function') { (win[0].jawnosCloseWaits = win[0].jawnosCloseWaits || []).push(done); }
		return;
	}
	var tearDown = function() { windowCloseTearDown(timestamp, win, done); };
	// The view it is being closed on is the next press's picture - the jopen, the
	// budget light, the arrangement it was left in. Taken before the farewell, or
	// the copy would wear the closing state.
	if (typeof jawnosEmergePreviewCapture == 'function') { jawnosEmergePreviewCapture(win); }
	// the pile reorients now, not when the farewell ends: the next window is in
	// this one's place while the motion still plays, so a run of closes from the
	// same spot lands on the next window each time
	if (typeof windowTiledCloseSlot == 'function') { windowTiledCloseSlot(win); }
	if (!(typeof jawnosWindowCloseEffect == 'function' && jawnosWindowCloseEffect(win, tearDown))) {
		tearDown();
	}
}

$(document).on('click', '.wind', function(e) {
	var app = $(this).attr('app');
	if (windowPhoneChecker()) {
		if ($(e.target).closest('.top_navbar').length) {
			// a phone's title-bar tap is a stack walk, handled by windowStacker
			// from the .top_navbar handler; do not also touch the pile here
			return;
		}
		// a press on a window's body lifts it to the top of the pile and restacks,
		// so a window dragged over the others' bars cannot pin them and swallow
		// their taps
		windowStacker(app, true);
		return;
	}
	var clicked = $(this);
	// forward is the foot of the pile, so a press anywhere in a tiled window is
	// the same walk a press on its title bar makes; the window already at the foot
	// of the pile does not move
	if (typeof windowTiledPress === 'function') { windowTiledPress(clicked); return; }
	topLevelNow(clicked);
});

// A scroll is a touch on that window. Scrolling a window that is not at the
// front lifts it there, the same way a press does, so the window you are
// reading and scrolling takes the focus - and its taskbar tile - without a
// separate press. The front check keeps a burst of wheel events from restacking
// every tick; the phone's pile walk is left to a tap, which is what it has.
$(document).on('wheel', '.wind', function() {
	if (windowPhoneChecker()) { return; }
	var win = $(this);
	if (windowIsFront(win)) { return; }
	// the tile's depth is its slot order; a wheel does not restack a tiled window
	if (typeof windowTiledSlot === 'function' && windowTiledSlot(win) >= 0) { return; }
	topLevelNow(win);
});

function windowIsFront(win) {
	var z = parseInt(win.css('z-index'), 10) || 0;
	var front = true;
	$('.wind').each(function() {
		if (this !== win[0] && jawnosWindowOnScreen(this) && (parseInt($(this).css('z-index'), 10) || 0) > z) {
			front = false;
			return false;
		}
	});
	return front;
}

function topLevelNow(win) {

	if (win.length > 0) {
		if (win.find('.window_contents')) {
			$('.wind').each(function(i,v) {
				var z = numeral($(v).css('z-index')).value();
				if (z > top_level_now) {
					top_level_now = z;
				}
			});

			var now = Date.now();
			win.find('.window_contents').css({ 'z-index': top_level_now + 1 });
			win.find('.top_navbar').css({ 'z-index': top_level_now + 2 });
			// The frame ring must out-paint both of those whatever they climb to: a
			// restored window can carry a z-index past the ring's own huge default,
			// which would lift the bar over its own frame. Tracking the same base
			// keeps the ring on top; the floor keeps it above every template's
			// in-window z-index in the ordinary case, where it stays the huge value.
			win.css('--frame_z', Math.max(2147483000, top_level_now + 3));
			win.css({ 'z-index': top_level_now + 1 });
			top_level_now = (Number(top_level_now) + 1);
			win.attr('last_top', now);
		}
		else {
			top_level_now = (Number(top_level_now) + 1);
		}
		win.resizable({
			start: function(p) {
			},
			stop: function(p) { 
			}
		});
	}
	// the taskbar's window tiles wear the state: the raised one sinks
	if (typeof jawnosTaskbarPinsRefresh == 'function') { jawnosTaskbarPinsRefresh(); }
	return top_level_now;
}

var everythingMoves = {};
var forbidden = [ 'save_appointment', 'delete_app', 'edit_app_submit', 'task_admin_input', 'task_input', 'delete_task' ];
$(document).on('mousewheel touchmove click keyup change','.wind',function(e) {
	var wind = $(this);
	var app = wind.attr('app');
	var allowed = 1;
	if (!everythingMoves[app]) {
		everythingMoves[app] = { moves: [], lastTimestamp: Date.now(), timeouts: {} };
	}

	//var scroll = wind.scrollTop();
	var offset = wind.offset();
	var movement = e.type;
	var contents = wind.find('.appointment_contents');
	var appt_contents_scroll = contents.scrollTop();
	var appointment = 0;
	if (wind.find('.appointment_contents').length > 0) {
		appointment = 1;
		//scroll = appt_contents_scroll;
	}
	var scrolls = [];
	wind.find('div,span').each(function(i,v) {
   if ($(v).css('overflow') == 'scroll') {

			var sclassList = [];
			$.each($(v)[0].classList, function(i,v) {
				sclassList.push(v);
			});
			var rsclassList = '';
			$.each(sclassList, function(i,v) {
				rsclassList += '.' + v;
			});
			var height = $(v).height();
			var width = $(v).width();

			var scrollTop = $(v).scrollTop();
			var scrollPercent = scrollTop / height;
      scrolls.push({ classList: rsclassList, scrollTop: scrollTop, scrollPercent: scrollPercent });
   }
	});;
	var classList = [];
	$.each(e.target.classList, function(i,v) {
		classList.push(v);
	});
	var attributes = [];
	$.each(e.target.attributes, function(i,v) {
		if (v.name != 'style') {
			attributes.push({ attr: v.name, value: v.value } );
		}
	});
	var value = e.target.value;
	var rattributes = '';
	var rclassList = '';
	$.each(attributes, function(i,v) {
		rattributes += '[' + v['attr'] + '="' + v['value'] + '"]';
	});
	$.each(classList, function(i,v) {
		$.each(forbidden, function(ie,ve) {
			if (v == ve ) {
				allowed = 0;
			}
		});
		rclassList += '.' + v;
	});

	var data = { 
		app: app, 
		attributes: attributes, 
		classList: classList, 
		movement: movement, 
		scrolls: scrolls,
		offset: offset,
		appointment: appointment,
		value: value,
		type: 'move',
		allowed: allowed
	};
	everythingMoves[app].moves.push(data);
	if (ws[app].readyState == 1 && e.isTrigger != 3 && allowed == 1) {
		everythingMoves[app].timeouts[e.type] = setTimeout(function() {
			clearTimeout(everythingMoves[app].timeouts[e.type]);
			data = everythingMoves[app].moves[everythingMoves[app].moves.length - 1];
			everythingMoves[app].moves = [];
			var jdata = JSON.stringify(data);
			//$.each(ws, function(i,v) {
			//	if (i.match(app + '@')) {
			//		ws[i].send(jdata);
			//	}
			//});
			ws[app].send(jdata);
		},10);
	}
	var ac = wind.find('.transaction_autocomplete');
	if (ac.is(':visible')) {
		
	}
});

function selectorMaker(target,censored) {
	var classList = [];
	var allowed = 1;

	if (target != undefined) {
		$.each(target.classList, function(i,v) {
			classList.push(v);
		});
		var attributes = [];
		$.each(target.attributes, function(i,v) {
			if (v.name != 'style') {
				attributes.push({ attr: v.name, value: v.value } );
			}
		});
		var rattributes = '';
		var rclassList = '';
		$.each(attributes, function(i,v) {
			if (v['attr'] != 'class') {
				if (v['value'] != '') {
					rattributes += '[' + v['attr'] + '="' + v['value'] + '"]';
				}
				else {
					rattributes += '[' + v['attr'] + ']';
				}
			}
		});
		$.each(classList, function(i,v) {
			if (censored == 'yes') {
				$.each(forbidden, function(ie,ve) {
					if (v == ve && movement == 'click') {
						allowed = 0;
					}
				});
			}
			rclassList += '.' + v;
		});
	}
	else { return ''; }
	if (allowed == 1) {
		return rclassList + rattributes;
	}
	else {
		return '';
	}
}

function topWindow(apper, screen) {
	var windows = [];
	var zindex = 0;
	$('.wind').each(function(i,v) {
		var app = $(v).attr('app');
		// a window playing its out motion is no longer the front: the next press
		// should raise what remains, not this one on its way out
		if (app != apper && $(v).css('z-index') > zindex
			&& (screen ? screen.onScreen.has(v) : jawnosWindowOnScreen(v))
			&& !(typeof jawnosWindowEffectLeaving == 'function' && jawnosWindowEffectLeaving(v))) {
			zindex = $(v).css('z-index');
			windows.push(app);
		}
	});
	return windows[windows.length - 1];
}

function topDialog() {
	var dialogs = [];
	var zindex = 0;
	$('.dialog_box').each(function(i,v) {

	});

}


$(document).on('resize', '.wind', function() { 
	var w = $(this);
	windowDimensionSetter(w);
});

function windowDimensionSetter(w) {
	var view = w.attr('view');
	if (!windowPhoneChecker() && w.length > 0) {
		var app = w.attr('app');
		var height = w.height();
		var width = w.width();
		// A window's box is its own style position, not offset(): an effect
		// animates a transform, and offset() is the transformed rect - the first
		// frame of the snap's stretch read a half as a narrow, shifted free window,
		// so the half box was saved over free_dimensions. A hidden window has no
		// offset (jQuery returns undefined) and keeps the view it wears.
		var off = w.offset();
		if (!off) { return; }
		var top = parseFloat(w.css('top'));
		var left = parseFloat(w.css('left'));
		if (isNaN(top)) { top = off.top; }
		if (isNaN(left)) { left = off.left; }
		var right = (left + width);
		// The screen the place was saved on travels with it, so the same place can
		// be rescaled onto a smaller or larger one.
		var dimensions = JSON.stringify({ 'width': width, 'height': height, 'top': top, 'left': left,
			'vw': $(window).width(), 'vh': $(window).height() });
		// Only a pinned window remembers where it is. An unpinned one is a window
		// with no place of its own: moving it must not quietly pin it. A pinned
		// window that is being rescaled onto this screen (windowPlaceRestore) is
		// not being moved by the person either.
		if (w.attr('place_restoring') == '1') { return; }
		if (typeof windowPlaceIsLocked === 'function' && windowPlaceIsLocked(w)) {
			settingSetter({ 'app': app, 'setting': 'dimensions', 'value': dimensions });
		}
		if ((width / $(window).width()) > .95) {
			w.attr('view', 'max');
		} else if (left <= 1 && (right <= ($(window).width() / 2 + 5) && right >= ($(window).width() / 2 - 5))) {
			w.attr('view', 'left');
		} else if (right > $(window).width() - 1 && (left >= ($(window).width() / 2 - 5) && left <= ($(window).width() /2 + 5))) {
			w.attr('view', 'right');
		} else { 
			w.attr('view', '');
			w.attr('free_dimensions', dimensions);
		}
	}
	if (w.attr('view') != view) {
		windowBackgroundAdjuster();
	}
}

// jQuery's own :visible predicate, read directly: an element paints when it has
// an offset box or a client rect. Calling it here avoids re-running Sizzle, and
// the windows are position: fixed, so offsetParent cannot stand in for it.
function jawnosWindowOnScreen(el) {
	return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
}

// One pass over the desk for the passes that all need the same answer: which
// windows and dialogs are on screen, which window is in front, and which window
// or dialog is in front. byKey/byApp are the dock face's lookups, built once
// instead of scanned per face; each keeps the first match in document order.
function jawnosWindowsOnScreen() {
	var onScreen = new Set();
	var byKey = new Map();
	var byApp = new Map();
	var top = null, topz = -1;
	var topWindow = null, topWindowZ = -1;
	$('.wind, .dialog_box').each(function() {
		var el = this;
		var dialog = el.classList.contains('dialog_box');
		if (jawnosWindowOnScreen(el)) {
			onScreen.add(el);
			var z = parseInt($(el).css('z-index'), 10) || 0;
			if (z >= topz) { topz = z; top = el; }
			if (!dialog && z >= topWindowZ) { topWindowZ = z; topWindow = el; }
		}
		var id;
		if (dialog) {
			id = el.getAttribute('data-dialog-id');
			if (id !== null && !byKey.has('dialog:' + id)) { byKey.set('dialog:' + id, el); }
		}
		else {
			id = el.getAttribute('data-terminal-id');
			if (id !== null && !byKey.has('terminal:' + id)) { byKey.set('terminal:' + id, el); }
			id = el.getAttribute('data-window-id');
			if (id !== null && !byKey.has('window:' + id)) { byKey.set('window:' + id, el); }
			id = el.getAttribute('app');
			if (id !== null && !byApp.has(id)) { byApp.set(id, el); }
		}
	});
	return { onScreen: onScreen, top: top, topWindow: topWindow, byKey: byKey, byApp: byApp };
}

// Place one background layer, writing only what actually changed. The view
// poll calls the adjuster every few seconds; re-assigning the same width and
// left still marks style dirty, and the next visibility read turns that into a
// full layout of a desk that has not moved.
function windowBackgroundPlace(el, width, left, fixed) {
	if (!el) { return; }
	if (el.style.width !== width) { el.style.width = width; }
	if (el.style.left !== left) { el.style.left = left; }
	if (fixed && el.style.position !== 'fixed') { el.style.position = 'fixed'; }
}

function windowBackgroundAdjuster(data) {
	if (!data) { data = {}; }
	// Ask the edge windows first, and read each one's visibility without Sizzle:
	// the poll runs every few seconds, and the old :visible filter re-asked the
	// engine for layout once per matching window even when nothing sat at an edge.
	var leftFree = 1, rightFree = 1;
	$('.wind[view="left"], .wind[view="right"]').each(function() {
		if (!jawnosWindowOnScreen(this)) { return; }
		if (this.getAttribute('view') === 'left') { leftFree = 0; }
		else { rightFree = 0; }
		if (!leftFree && !rightFree) { return false; }
	});
	var layout = localStorage.getItem('layout') || '';
	var layout_el = layout ? document.getElementById(layout) : null;
	var full = (leftFree == rightFree) ? 1 : 0;
	var half = full ? 0 : ($(window).width() / 2);
	var width = full ? '100%' : (half + 'px');
	var left = full ? '0px' : ((leftFree == 1) ? '0%' : (half + 'px'));
	// Every other printer canvas fills the desk. The layers that give way to a
	// snapped window are placed below - the timeline is the current layout canvas,
	// and it draws at #background's width - so they are left out of this reset;
	// writing them here and putting them back would dirty the desk on every poll.
	var background_el = document.getElementById('background');
	var desk_el = document.getElementById('desk_layer');
	var backgrounds = document.querySelectorAll('.background');
	for (var i = 0; i < backgrounds.length; i++) {
		if (backgrounds[i] === background_el || backgrounds[i] === desk_el || backgrounds[i] === layout_el) { continue; }
		windowBackgroundPlace(backgrounds[i], '100%', '0px', 0);
	}
	windowBackgroundPlace(background_el, width, left, !full);
	windowBackgroundPlace(desk_el, width, left, !full);
	windowBackgroundPlace(layout_el, width, left, !full);
	if (data['caller'] != 'calculator') {
		calculator();
	}
	taskbarDisplayer();
}

function windowDrawerOpener(app,content) {
	var wind = $('.wind[app="' + app + '"]');
	wind.find('.window_drawer_contents').html(content).show();
	wind.find('.window_drawer').show();
	wind.find('.window_contents').hide();
	textareaUpgrader();
}

$(document).on('click', '.window_drawer_closer', function() {
	var wind = $(this).closest('.wind');
	var app = wind.attr('app');
	windowDrawerCloser(app);
});

function windowDrawerCloser(app) {
	var wind = $('.wind[app="' + app + '"]');
	wind.find('.window_drawer').hide();
	wind.find('.window_contents').show();
}

function windowDrawerToggle(app) {

}

