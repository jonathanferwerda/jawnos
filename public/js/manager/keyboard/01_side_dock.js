function pseudonymSideSlide() {
	if (!pseudonymSideLayout) { return; }
	var L = pseudonymSideLayout;
	var offset = pseudonymSideTucked ? Math.max(0, L.home_w - pseudonymSideReach) : 0;
	var slide = L.left ? -offset : offset;
	if (L.left) {
		$('#pseudonym_home').css({ 'left': -offset + 'px', 'right': 'auto' });
	}
	else {
		$('#pseudonym_home').css({ 'right': -offset + 'px', 'left': 'auto' });
	}
	$('#pseudonym_bar .pseudonym.bar').css({ 'left': (L.icon_left + slide) + 'px' });
	// the tiles slip away with the pill: only the strip stays, and a sliver of
	// tiles along it would be litter. The dock's own on/off rule decides which
	// ones come back, so a switched-off icon stays off.
	$('#pseudonym_bar .pseudonym.bar').each(function () {
		if (pseudonymSideTucked) { $(this).hide(); }
		else if (!(typeof jawnosDockIconsHidden == 'function' && jawnosDockIconsHidden())
			&& ((typeof jawnosDockFaceAlwaysOn == 'function' && jawnosDockFaceAlwaysOn(this)) || jawnosDockIconState($(this).attr('toggle')) == 'on')) { $(this).show(); }
	});
	if (L.search_in_dock) {
		$('#search_toggle').css({ 'left': (L.icon_left + slide) + 'px' });
		if (pseudonymSideTucked) { $('#search_toggle').hide(); }
		else { $('#search_toggle').show(); }
		if (L.left) {
			$('#search_entanglement').css({ 'left': (L.home_w + 8 + slide) + 'px', 'right': 'auto' });
		}
		else {
			$('#search_entanglement').css({ 'right': (L.home_w + 8 - slide) + 'px', 'left': 'auto' });
		}
	}
}

// Tuck a side dock away, or call it back out. An open search keeps the pill
// with it - the panel hangs beside the pill, and tucking the pill out from
// under an input being typed in would send the words away with it.
function pseudonymSideSettle(tucked) {
	if (typeof jawnosSideDock != 'function' || !jawnosSideDock()) { return 0; }
	if (tucked && typeof jawnosSideSearchVisible == 'function' && jawnosSideSearchVisible()) { tucked = 0; }
	// an empty pill has no faces to tuck; keeping it out leaves its menu reachable
	if (tucked && $('#pseudonym_home').hasClass('dock_empty')) { tucked = 0; }
	pseudonymSideTucked = tucked ? 1 : 0;
	pseudonymSideSlide();
	return 1;
}

// the dock is sized for whichever edge it lives on, so a new screen shape
// means new sizes
$(window).on('resize', function() {
	pseudonymFreeSpaceFinder();
});

$(document).on('click', '.keyboard.bc,.keyboard_tab', function(i) {
	// the bar across the top is a handle, not a claim button
	if ($(i.target).closest('.keyboard_drag_bar').length > 0) { return; }
	var keyboard = $(this);
	var id = i.target.id;
	if ($(this).hasClass('keyboard_tab')) {
		keyboard = $(this).closest('.keyboard');
		var id = keyboard.attr('id');
	}
	keyboardDragEnabler(keyboard,id);
});

// the bar's own X sends the panel away; the pseudonym that called it brings it
// back, and it is the only other way to drag it that goes with it
$(document).on('click', '.keyboard_closer', function(e) {
	e.stopPropagation();
	$(this).closest('.keyboard').hide();
});

function keyboardDragEnabler(k,id,state) {

	if (k.attr('id') != id) { return; }

	if (k.attr('claimed') == 'yes' && state != 'on') {
		k.attr('claimed','no');
	}
	else {
		k.attr('claimed', 'yes');
	}
	keyboardDragBarMaker(k);
}

// A keyboard panel is moved by the thin bar across its top, so the body stays
// free for tapping buttons and typing: a drag only ever starts on the bar. The
// bar carries the panel's close button at its own right end. The panel is sized
// by its edge or corner, and both its place and its size are kept. The bar is
// added once; safe to call again on the same panel.
function keyboardDragBarMaker(k) {
	k = $(k);
	if (k.length == 0) { return; }
	if (k.children('.keyboard_drag_bar').length == 0) {
		k.prepend('<div class="keyboard_drag_bar"><span class="keyboard_closer hover" hint="Close">✕</span></div>');
	}
	if (!k.hasClass('ui-draggable')) {
		k.draggable({
			handle: '.keyboard_drag_bar',
			cancel: '.keyboard_closer',
			start: function(p) {
				var panel = $(this);
				// the panel now owns its spot, so a reshaped screen must not move it
				panel.removeAttr('default_placed');
				pseudonyms[panel.attr('id')] = Date.now();
				keyboardIntervals = Date.now();
			},
			drag: function(p, ui) {
				keyboardIntervals = Date.now();
				// a floating panel stops at the clothesline, like a window does, and
				// stays on the screen on every other edge
				if ($(this).css('position') == 'fixed') {
					var panel = $(this);
					var width = panel.outerWidth();
					var height = panel.outerHeight();
					var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
					var vw = $(window).width();
					var vh = $(window).height();
					ui.position.top = Math.max(panelTopLimit(), Math.min(ui.position.top, vh - height - bar));
					ui.position.left = Math.max(0, Math.min(ui.position.left, vw - width));
				}
			},
			stop: function(p) {
				keyboardPanelSave($(this));
			}
		});
	}
	else {
		k.draggable('enable');
	}
	if ($.fn.resizable && !k.hasClass('ui-resizable')) {
		k.resizable({
			handles: 'e, s, se',
			minWidth: 220,
			minHeight: 120,
			start: function() {
				var panel = $(this);
				if (panel.css('right') != 'auto' || panel.css('bottom') != 'auto') {
					var rect = panel[0].getBoundingClientRect();
					panel.css({ 'left': rect.left + 'px', 'top': rect.top + 'px', 'right': 'auto', 'bottom': 'auto' });
				}
			},
			stop: function() { keyboardPanelSave($(this)); }
		});
	}
}

// The whole style dump the panel wears, kept as its place: a resized panel's
// width and height ride in the same dump as the spot its drag bar leaves.
function keyboardPanelSave(panel) {
	if (!panel || !panel.length) { return; }
	var id = panel.attr('id');
	if (!id) { return; }
	panel.removeAttr('default_placed');
	// the computed style is the only record of where the panel sits
	// once it has been moved, so keep the lot (minus the claim border)
	if (panel.css('position') == 'fixed') {
		var top = parseFloat(panel.css('top'));
		if (!isNaN(top) && top < panelTopLimit()) {
			panel.css({ 'top': panelTopLimit() + 'px' });
		}
		var left = parseFloat(panel.css('left'));
		var width = panel.outerWidth();
		if (!isNaN(left) && left > $(window).width() - width) {
			panel.css({ 'left': Math.max(0, $(window).width() - width) + 'px' });
		}
	}
	var css = {};
	var style = panel[0].style;
	$.each(style, function(i,v) {
		if (!v.match('border-left')) {
			css[v] = panel.css(v);
		}
	});
	var jcss = JSON.stringify(css);
	jawnosWindowStyleSet(id, jcss);
	jawnosWindowPlaceSet(id, jcss);
}

// Whether a hit-tested element belongs to the pseudonym dock. A tucked dock
// rides its bars and keys outside #pseudonym_home's own box, so an id-only test
// misses them and the dock slid away from under the pointer.
function jawnosDockElement(el) {
	el = $(el);
	return el.attr('id') == 'pseudonym_home'
		|| el.hasClass('pseudonym')
		|| el.hasClass('keyboard')
		|| el.hasClass('window_toggle')
		|| el.hasClass('manager_search_result')
		|| el.closest('#pseudonym_home').length > 0;
}

// Where the pointer is, kept on every move. The hider runs from a timer, and
// mouse_position() reads window.event, which is not set outside an event, so it
// could hand back an older point and tuck the dock while the pointer was
// resting on it.
var pseudonymPointerX = null;
var pseudonymPointerY = null;
$(document).on('mousemove', function (e) {
	pseudonymPointerX = e.clientX;
	pseudonymPointerY = e.clientY;
});

// Is the point over the dock in either of its places? The home's box covers the
// showing row and the tucked strip that stays on screen, while the faces cover
// a row that overhangs the box. The strip is checked on its own as well, so the
// point that called the row out is still the dock's after the row has moved up
// under the pointer.
function pseudonymDockPointOnDock(x, y) {
	if (!isFinite(x) || !isFinite(y)) { return false; }
	var inside = function (el) {
		if (!el || !el.getBoundingClientRect) { return false; }
		var r = el.getBoundingClientRect();
		if (!(r.width > 0 && r.height > 0)) { return false; }
		return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
	};
	if (inside(document.getElementById('pseudonym_home'))) { return true; }
	var on_face = false;
	$('#pseudonym_home').find('.pseudonym, #search_entanglement').each(function () {
		if (inside(this)) { on_face = true; return false; }
	});
	if (on_face) { return true; }
	var strip = (typeof pseudonymDockStrip == 'function') ? pseudonymDockStrip() : 0;
	if (!(strip > 0)) { return false; }
	var vw = $(window).width();
	var vh = $(window).height();
	if (typeof jawnosDockTop == 'function' && jawnosDockTop()) { return y >= 0 && y <= strip; }
	if (typeof jawnosSideDock == 'function' && jawnosSideDock()) {
		if (typeof jawnosDockLeft == 'function' && jawnosDockLeft()) { return x >= 0 && x <= strip; }
		return x >= vw - strip && x <= vw;
	}
	return y >= vh - strip && y <= vh;
}

function pseudonymHomeShower(x,y,interval) { 
	var was = 0;
	var okay = 1;
	var dock_top = (typeof jawnosDockTop == 'function') && jawnosDockTop();
	var dock_side = (typeof jawnosSideDock == 'function') && jawnosSideDock();
	var elements = document.elementsFromPoint(x, y);

	if (interval) {
		pseudonymHIntervals = interval;
		was++;
		okay = 1;
	}
	else if (!windowPhoneChecker()) {
		pseudonymHIntervals = 100;
	}
	else {
		pseudonymHIntervals = 4000;
	}
	if (!interval) {
		$.each(elements, function(i,v) {
			if (jawnosDockElement(v)) {
				was++;
			}
			if ($(v).attr('id') == 'search' || $(v).attr('id') == 'search_toggle' || $(v).attr('id') == 'manager_search_results') {
				okay = 0;
			}

		});
		if (was == 0 && pseudonymDockPointOnDock(x, y)) { was++; }
	}
	var t = $('#pseudonym_home').offset();

	if (t && okay == 1) {
		var w = $('#pseudonym_home').width();
		var h = $('#pseudonym_home').height();
		var wh = $(window).height();
		if (was > 0) {
			// a side dock slides straight back out over its strip
			if (dock_side) {
				pseudonymSideSettle(0);
				pseudonymIntervals = Date.now();
			}
			// a dock on the top edge answers by slipping its row back down over
			// the search strip; the row rides the home's top, so moving the home
			// is all it takes
			else if (dock_top) {
				$('#pseudonym_home').css({ 'top': jawnosDockTopOffset() });
				pseudonymFreeSpaceFinder();
				// the dropdown follows the box's new edge; the shared placement knows
				// about the keyboard, which a hand-rolled offset here would not
				if (typeof jawnosSearchResultsPlace == 'function') { jawnosSearchResultsPlace(); }
				pseudonymIntervals = Date.now();
			}
			else {
				$('.pseudonym.bar').each(function() {
					var kbg = $(this);
					var bottom = kbg.css('bottom');
					var toggle = kbg.attr('toggle');
					var diff = (0 - (h * .9));
					var d = Number(numeral(bottom).format());
					var diff_body = diff + d;

					var diffplus =  Math.abs( d ) + Math.abs( diff );
					if (diffplus == 80 && bottom != 80) {
						if (was > 0) {
							kbg.css({'bottom': diffplus });

						}
					}
					var ls = (typeof jawnosDockFaceAlwaysOn == 'function' && jawnosDockFaceAlwaysOn(kbg))
						? 'on' : jawnosDockIconState(toggle);
					if (ls == 'on' && !(typeof jawnosDockIconsHidden == 'function' && jawnosDockIconsHidden())) {
						$('.pseudonym.keyboard[toggle="' + toggle + '"]').show();
					}
					else if (kbg.hasClass('window_toggle')) {
						kbg.show();
					}
				});
				$('#pseudonym_home').css({ 'bottom': ((typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0) });
				if (typeof jawnosSearchResultsPlace == 'function') { jawnosSearchResultsPlace(); }
				pseudonymIntervals = Date.now();
			}
		}
		else if (Date.now() >= pseudonymIntervals + pseudonymHIntervals && !interval) {
			pseudonymHomeHider(pseudonymHIntervals);
		}

		pseudonymHiderTimeout = setTimeout(function() {
			console.log('clearing');
			if (Date.now() >= pseudonymIntervals + pseudonymHIntervals) {
				pseudonymHomeHider(pseudonymHIntervals);
			}
		},pseudonymHIntervals)
	}
}


// The top dock's resting place: the home slips up until only its search strip
// stays on screen, and the icon row rides above the visible edge with it. That
// strip is where the mouse rests to call the row back down. Answers 0 for any
// other edge, so the caller knows to size the dock the plain way instead.
function pseudonymHomeTopSettle() {
	if (typeof jawnosDockTop != 'function' || !jawnosDockTop()) { return 0; }
	var home = $('#pseudonym_home');
	// size the box for the top edge first - its height is what the tuck reaches
	// past - then tuck it and let the row ride up with it. The strip it keeps is
	// the search's row, or the sliver when the search rides elsewhere.
	pseudonymFreeSpaceFinder();
	// an empty dock has no row to tuck; leaving it at rest keeps its menu reachable
	if (home.hasClass('dock_empty')) { home.css({ 'top': jawnosDockTopOffset() }); return 1; }
	home.css({ 'top': jawnosDockTopOffset() + Math.min(0, pseudonymDockStrip() - home.outerHeight()) });
	pseudonymFreeSpaceFinder();
	return 1;
}

function pseudonymHomeHider(interval) {
	// both edges tuck away: the bottom slips down keeping the search and a strip
	// beneath it on screen, the top slips up keeping its search strip on screen
	// with the icon row above the visible edge. A hidden dock is already gone.
	if (typeof jawnosDockHidden == 'function' && jawnosDockHidden()) { return; }
	var dock_top = (typeof jawnosDockTop == 'function') && jawnosDockTop();
	var dock_side = (typeof jawnosSideDock == 'function') && jawnosSideDock();
	pseudonymFreeSpaceFinder();
	// an empty dock has nothing to tuck away; leave its background on screen so
	// the menu can put a face back
	if ($('#pseudonym_home').hasClass('dock_empty')) {
		$('#pseudonym_home').css({ 'bottom': ((typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0) });
		return;
	}
	// The pointer hider and the shower share one answer to "is this the dock?"
	// The tracked pointer is the current one; mouse_position() is only the
	// fallback before the first move (it reads window.event).
	var x = pseudonymPointerX;
	var y = pseudonymPointerY;
	if (x === null || y === null) {
		var m = mouse_position();
		x = m.x;
		y = m.y;
	}
	// a desk whose mouse has never moved has no position yet; it counts as away
	// from the dock rather than crashing elementsFromPoint on a non-finite
	var was = 0;
	if (isFinite(x) && isFinite(y)) {
		var elements = document.elementsFromPoint(x, y);
		$.each(elements, function(i,v) {
			if (jawnosDockElement(v)) {
				was++;
			}
		});
		if (was == 0 && pseudonymDockPointOnDock(x, y)) { was++; }
	}

	interval = interval || pseudonymHIntervals;
	if (Date.now() >= pseudonymIntervals + interval && was == 0) {
		if (dock_side) {
			// the pill slips off its own edge, keeping the strip the pointer rests
			// on to call it back
			pseudonymSideSettle(1);
		}
		else if (dock_top) {
			pseudonymHomeTopSettle();
		}
		else {
			// tuck the dock down, but keep the search and a strip beneath it on
			// screen: that strip is where the mouse rests to call the icons back. A
			// taskbar sharing the bottom edge takes its height first, so the strip
			// rests above the bar instead of lying across it.
			var h = $('#pseudonym_home').outerHeight();
			var edge = (typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0;
			var diff = Math.min(0, pseudonymDockStrip() - h) + edge;
			$('#pseudonym_home').css({ 'bottom': diff });
			$('.pseudonym.bar').hide();
			$('.keyboard').each(function() {
				var kbg = $(this);
				var bottom = kbg.css('bottom');
				var d = Number(numeral(bottom).format());
				var diff_body = diff + d;

				if (d == 80) {
					kbg.css({'bottom': diff_body });
				}
			});
			// once for the dock, not once per panel: the shared placement measures the
			// visible page, so the list never lands under a keyboard
			if (typeof jawnosSearchResultsPlace == 'function') { jawnosSearchResultsPlace(); }
		}
	}
	else {
		// the pointer is on the dock: push the hide back instead of hiding
		pseudonymIntervals = Date.now();
	}
}

function pseudonymDraggableInitializer() {
  $( ".pseudonym" ).draggable({
    distance: 4,
    // a click is not a drag: a fingertip or a settling hand moves a pixel or
    // two, and a zero-distance drag swallowed the first press before its click
    start: function(p) {
			var id = p.target.id;
			var timestamp = Date.now();
			pseudonyms[p.target.id] = timestamp;
			pseudonymIntervals = Date.now();
    },
    drag: function(p) {
			pseudonymIntervals = Date.now();
			var d = mouse_position();
			pseudonymIntervals = Date.now();
			pseudonymHomeShower(d.x,d.y,5000);
			console.log('dragging');
    },
    stop: function(p) {
			var d = {
				top: p.originalEvent.target.offsetTop,
				left: p.originalEvent.target.offsetLeft
			}
			var data = JSON.stringify(d);
			jawnosWindowPlaceSet(p.target.id, data);

			pseudonymIntervals = Date.now();

			setTimeout(function() {
				if (Date.now() >= pseudonymIntervals + pseudonymHideWait) {
					pseudonymFreeSpaceFinder();
				}
			}, pseudonymHideWait);
			setTimeout(function() {
				pseudonymHomeHider(pseudonymHIntervals);
			}, pseudonymHIntervals);
    }

  });
}

$(document).ready(function() {
	mouse_position();
	setTimeout(function() {
		pseudonymHomeHider(pseudonymHIntervals);
	}, 10);
	pseudonymDraggableInitializer();
});


$(document).on('click', '.wind,.background', function() {
	$('.keyboard.bc').each(function() {
		var it = $(this);
		var toggle = it.attr('id');
		if (it.is(':visible') && it.attr('claimed') != 'yes') {
			it.hide();
			if (toggle == 'remote_control') {
				$('#search').val('');
			}
		}
	});
});

$(document).on('click','#room_check,#windshield_wiper,#drawing_check', function() {
	var id = $(this).attr('id');
	var value = $(this).prop('checked');
	localStorage.setItem(id,value);

});

$(document).on('click', '.past_life,.life_direction', function() {
	// the view's own timestamp stands in for whatever the pressed line does not
	// carry; the whole payload it used to be fished out of is not kept any more
	var timestamp = $(this).attr('timestamp') || sessionStorage.getItem('appts_timestamp');

	var direction = $(this).attr('direction');
	var room_check = $('#room_check').is(':checked');
	var drawing_check = $('#drawing_check').is(':checked');
	var start_menu = $(this).attr('start_menu');
	$.ajax({
		url: '/manager/past_life_recall',
		type: 'GET',
		data: { timestamp: timestamp, direction: direction, room_check: room_check, drawing_check: drawing_check },
		success:function(response) {
			var json = JSON.stringify(response);
			if (start_menu != 'yes') {
				timestamp = response.timestamp;
				$('#time_machine').val(quality_inventory(response.timestamp));
				localStorage.setItem('time_machine', quality_inventory(response.timestamp));
			}


			$('#life').html(response.appt_count);
			$('#room_name').val(response.room || '');
			$('#room_name').attr('timestamp', response.timestamp);
			$('#room_name').attr('browser_tab_id', response.browser_tab_id);
			$('#playbook').html(response.playbook);
			if (response['portfolio'] && response['portfolio'].length > 0) {
				$.each(response['portfolio'], function(i,v) {
					$('#playbook').append('<img class="medium_thumb" id="' + v.uuid + '_thumb">');
					document.getElementById(v.uuid + '_thumb').src = '/file_open?file=' + v.f + '&server_time=' + v.server_time;
				});

			}
			$('.past_life,.life_direction').attr('timestamp', response.timestamp );
			if ($('#windshield_wiper').is(':checked') || start_menu == 'yes' ){ $('.wind').each(function(i,v) { var ts = $(v).attr('timestamp'); closeWindow(ts)}); }
			if (direction == 'load') {
				manager_play(response);
			}
			windowSaver();
		}
	});
});



$(document).on('click', '.media_picker', function() {
	var mp = $(this);
	var type = mp.attr('type');
	var kind = mp.attr('kind');
	var device_id = mp.attr('device_id');
	var selected = jawnosDevicePickGet(kind, device_id);

	$('.media_picker[kind="' + kind + '"]').each(function(i,v) {
		$(v).attr('status', 'off');
		var d = $(v).attr('device_id');
		jawnosDevicePickSet(kind, d, 'off');

	});
	if (selected == 'off') {
		selected = 'on';
		if (kind == 'speaker') {
			document.getElementById('video').setSinkId(device_id);
		}
	}
	else {
		selected = 'off';
	}
	mp.attr('status',selected);
	jawnosDevicePickSet(kind, device_id, selected);
});


function manager_play(response) {
	windowRetriever(response['json_windows']);
	//bti = response['browser_tab_id'];
	//sessionStorage.setItem('browser_tab_id', bti);
	var timestamp = Date.now();
	var time = timestamp - response.timestamp;

	var zone = quality_inventory(response.timestamp);

	if (typeof portfolioMaker === 'function') { portfolioMaker(response['portfolio']); }
	sessionStorage.setItem('time_machine', zone);
	$('#time_machine').val(zone);	
}

$(document).on('click', '#new_room', function() {
	var app = $('#room_name').text();
	var timestamp = sessionStorage.getItem('appts_timestamp');
	$.ajax({
		url: '/manager/new_room',
		type: 'POST',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			$('#room_name').val(response['room_name']);
			bti = response['browser_tab_id'];
			sessionStorage.setItem('browser_tab_id', bti);
			websocketStop();
			websocketStart();
		}
	});
});

$(document).on('click','#delete room', function(){
	var timestamp = $(this).attr('timestamp');

});

$(document).on('change', '#room_name', function() {
	var room_name = $(this).val();
	var timestamp = $(this).attr('timestamp');
	var browser_tab_id = $(this).attr('browser_tab_id');
	$.ajax({
		url: 'manager/room_namer',
		type: 'POST',
		data: { browser_tab_id: browser_tab_id, timestamp: timestamp, room_name: room_name },
		success: function(response) {
			$('#room_name').val(response['room_name']);
			websocketStop();
			websocketStart();
		}
	});
});

