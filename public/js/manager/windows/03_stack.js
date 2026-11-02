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
		// the top of the pile is the front window - the one wearing the highest
		// z-index, which is the last in the order below
		var front = order[order.length - 1];
		var rest = order.filter(function (el) { return el !== front; });
		if (raise) {
			// a press that is not the pile's walk - a tap on a window's body, or the
			// end of a drag - lifts that window to the top of the pile and leaves the
			// rest in order, rather than the walk's front-to-foot rotation
			order = order.filter(function (el) { return el !== target; }).concat([target]);
		} else if (target === front) {
			// a tap on the top of the pile walks it down to the bottom of the stack
			order = [front].concat(rest);
		} else {
			// a tap lower down lifts it to the top of the pile and drops the old
			// top to the bottom of the stack
			order = [front].concat(rest.filter(function (el) { return el !== target; }), [target]);
		}
		// z climbs with the order, so the last in the order is the front
		$(order).each(function (slot) { $(this).css({ 'z-index': top_level_now + slot + 1 }); });
		top_level_now = top_level_now + order.length;
	}

	// re-cascade the pile by that order: a closed window leaves no gap. Step each
	// window down by the height of the bar above it - not one measured step for
	// the whole pile - so the bars sit flush even when their heights differ (a
	// single step against a bar of another height leaves a gap, or an overlap).
	// Then pull it up by the bar's own border, so this bar's foot and the next
	// window's frame land on one another and read as a single line, not two.
	var y = windowTopLimit();
	$(order).each(function () {
		var win = $(this);
		win.css({ 'top': y });
		var bar = win.find('.top_navbar');
		var border = parseFloat(bar.css('border-top-width')) || 0;
		y = y + (bar.outerHeight() || 40) - border;
	});

	// raise the new front through topLevelNow so its frame ring and the taskbar
	// pins follow the order
	if (app) { topLevelNow($(order[order.length - 1])); }
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

function closeWindow(timestamp) {

	var win = $('#window_' + timestamp);
	win.find('.window_script').remove();
	var app = win.attr('app');
	if (app == 'twirl') {
		twirlRunning = false;
	}
	if (app == 'mailbox' && typeof mailSocketClose == 'function') { mailSocketClose(); }
	// closing the app closes its padlock in this tab as well as on the server
	if ((app == 'gallery' || app == 'music' || app == 'folders') && typeof jawnosMediaLockdown === 'function') {
		jawnosMediaLockdown(app, true);
	}
	$('#window_' + timestamp ).remove();
	$('#window_icon_' + timestamp).remove();
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
		}
	});
	windowSaver();
	startMenuDisplayer();
	windowBackgroundAdjuster();
	// a phone layers its windows on one another, so the layers left behind
	// want re-parking against the smaller count
	if (windowPhoneChecker()) { windowStacker(); }
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
	topLevelNow($(this));
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
	topLevelNow(win);
});

function windowIsFront(win) {
	var z = parseInt(win.css('z-index'), 10) || 0;
	var front = true;
	$('.wind').filter(':visible').each(function() {
		if (this !== win[0] && (parseInt($(this).css('z-index'), 10) || 0) > z) {
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

function topWindow(apper) {
	var windows = [];
	var zindex = 0;
	$('.wind').each(function(i,v) {
		var app = $(v).attr('app');
		if (app != apper && $(v).css('z-index') > zindex && $(v).is(':visible')) {
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
		var top = w.offset().top;
		var left = w.offset().left;
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

function windowBackgroundAdjuster(data) {
	if (!data) { data = {}; }
	var background_set = $('#background, #desk_layer');
	background_set.css({ 'width': '100%', 'left': '0px' });
	$('.background').css({ 'width': '100%', 'left': '0px' });
	var leftFree = 1;
	var rightFree = 1;
	if ($('.wind[view="left"]:visible').length > 0) {
		leftFree = 0;
	}
	if ($('.wind[view="right"]:visible').length > 0) {
		rightFree = 0;
	}
	if (leftFree != rightFree) {
		var half = $(window).width() / 2;
		var layout = localStorage.getItem('layout');
		if (leftFree == 1) {
			$('#background').css({ 'width': half, 'left': '0%', 'position': 'fixed' });
			$('#desk_layer').css({ 'width': half, 'left': '0%', 'position': 'fixed' });
			$('#' + layout).css({ 'width': half, 'left': '0%', 'position': 'fixed' });
		}
		else if (rightFree == 1) {
			$('#background').css({ 'width': half, 'left': half, 'position': 'fixed' });
			$('#desk_layer').css({ 'width': half, 'left': half, 'position': 'fixed' });
			$('#' + layout).css({ 'width': half, 'left': half, 'position': 'fixed' });
		}
	}
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

