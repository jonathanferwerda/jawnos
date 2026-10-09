var timestamp = Date.now();
var calculateInterval = 0;
var pseudonyms = {};
var pseudonymIntervals = Date.now() - 4000;
var keyboardIntervals = Date.now() - 5000;
var pseudonymHiderTimeout;
var pseudonymHIntervals = 4000;
var pseudonymHideWait = 5000;
// how much of a tucked dock stays on screen - the strip the mouse rests on to
// call the icons back. The bottom dock keeps its top strip (the search); the
// top one keeps its bottom strip, which is the search too, pushed below the
// row by the CSS. With the search away, only a sliver of the pill stays - just
// enough to hover and call the dock out.
var pseudonymDockReach = 47;
var pseudonymDockSliver = 15;
// The strip a tucked row dock keeps: the search's own row while the input rides
// the dock, the sliver otherwise.
function pseudonymDockStrip() {
	var search_in_dock = $('#search_entanglement').closest('#pseudonym_home').length > 0;
	return search_in_dock ? pseudonymDockReach : pseudonymDockSliver;
}
// how much of a tucked side dock stays on screen - the strip the pointer rests
// on to call the pill back - and the state its slide answers to
var pseudonymSideReach = 20;
var pseudonymSideTucked = 0;
var pseudonymSideLayout = null;

var text_editor = {};
var keysPressed = {};
var appSwitcherSelected = 0;
// The dock at the bottom of the screen: one centred row of pseudonyms. Icons that
// are switched off hide, and the rest share the row, shrinking below their full
// size when there are too many to fit, so the dock never runs off the screen.
function pseudonymFreeSpaceFinder(type) {
	var w = $(window).width();
	var h = $(window).height();
	var icons = $('#pseudonym_bar .pseudonym.bar').toArray();
	var visible = [];

	// 60px is the comfortable size; past that the icons share what the screen
	// has, down to a floor so they stay recognisable
	var full = 60;
	var floor = 14;
	var gap = 4;
	var home_chrome = 68; // #pseudonym_home padding + border
	var home = $('#pseudonym_home');
	var search_in_dock = $('#search_entanglement').closest('#pseudonym_home').length > 0;
	var dock_top = (typeof jawnosDockTop == 'function') && jawnosDockTop();
	var dock_side = (typeof jawnosSideDock == 'function') && jawnosSideDock();
	var dock_left = (typeof jawnosDockLeft == 'function') && jawnosDockLeft();
	var dock_edge = (typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0;
	var icons_hidden = (typeof jawnosDockIconsHidden == 'function') && jawnosDockIconsHidden();
	var count = Math.max(1, visible.length);

	$.each(icons, function(i,el) {
		var icon = $(el);
		var toggle = icon.attr('toggle');
		if (!icons_hidden && jawnosDockIconGet(toggle) == 'on') {
			icon.show();
			visible.push(el);
		}
		else {
			icon.hide();
		}
	});
	// the dock keeps at least the remote control in it
	if (!icons_hidden && visible.length == 0 && icons.length > 0) {
		jawnosDockIconSet('remote_control', 'on');
		$.each(icons, function(i,el) {
			if ($(el).attr('toggle') == 'remote_control') {
				$(el).show();
				visible.push(el);
			}
		});
	}
	count = Math.max(1, visible.length);

	// the search's own button: it rides with the input while the search sits in
	// the dock's row, and keeps the foot of the stack on a side dock, where the
	// input panel stays hidden until the button calls it out
	if (search_in_dock && dock_side) {
		if ($('#search_toggle').closest('#search_entanglement').length > 0) { $('#search_toggle').appendTo('#pseudonym_home'); }
	}
	else if (!$('#search_toggle').closest('#search_entanglement').length) {
		$('#search_toggle').insertAfter($('#search'));
	}

	if (dock_side) {
		// a side dock stacks its icons: the search button takes a slot at the foot
		// of the stack, and the whole pill is centred between the bars. The stack
		// rides the home's own edge, so it slides out of sight with the home when
		// the dock tucks - only the width and height are the finder's to set, and
		// the edge offsets belong to pseudonymSideSettle() and its reveal
		var edge_top = (typeof jawnosTaskbarEdge == 'function') ? jawnosTaskbarEdge('top') : 0;
		// with the icons switched off only the search takes a slot; nothing at all
		// still holds one, so the pill keeps a shape to tuck from
		var drawn = visible.length;
		var slots = Math.max(1, drawn + (search_in_dock ? 1 : 0));
		var room = h - edge_top - dock_edge - 26;
		var size = Math.floor((room - (gap * (slots - 1))) / slots);
		size = Math.max(floor, Math.min(full, size));
		var stack = (size * slots) + (gap * (slots - 1));
		var start = edge_top + Math.round((h - edge_top - dock_edge - (stack + 26)) / 2) + 13;
		// the pill hugs the edge it lives on, so its own geometry is known here
		// rather than measured - a measurement taken mid-slide would read the
		// tuck, not the layout. The revealed layout it leaves behind is what
		// pseudonymSideSlide() applies the tuck on top of. Its chrome is the 2px
		// border and the 11px padding the side dock wears.
		var home_w = size + 26;
		var home_h = stack + 26;
		var icon_left = dock_left ? 13 : (w - 13 - size);

		$.each(visible, function(i,el) {
			$(el).css({
				'width': size,
				'height': size,
				'left': icon_left,
				'top': start + Math.round(i * (size + gap))
			});
		});
		if (search_in_dock) {
			$('#search_toggle').css({
				'position': 'fixed',
				'width': size,
				'height': size,
				'top': start + Math.round(drawn * (size + gap))
			});
			// the panel waits beside the pill, wherever the pill has slid to
			$('#search_entanglement').css({
				'top': '50%',
				'width': Math.min(320, w - size - 68) + 'px'
			});
		}
		home.css({
			'width': home_w + 'px',
			'height': home_h + 'px',
			'top': (start - 13) + 'px',
			'bottom': 'auto'
		});
		pseudonymSideLayout = {
			left: dock_left,
			search_in_dock: search_in_dock,
			icon_left: icon_left,
			home_w: home_w
		};
		pseudonymSideSlide();
	}
	else {
		// a row dock owns its own edges: the side slide has nothing to hold
		pseudonymSideLayout = null;
		pseudonymSideTucked = 0;
		var lane = Math.min(w - 8, 720) - home_chrome;
		var size = Math.floor((lane - (gap * (count - 1))) / count);
		size = Math.max(floor, Math.min(full, size));
		var total = (size * count) + (gap * (count - 1));
		var start = Math.round((w - total) / 2);
		// a dock on the top edge hangs its row from its own top - riding down with
		// the home when the search strip calls it - and the bottom one keeps its
		// 15px from the edge, raised over the taskbar when the two share the bottom
		var dock_row_top = Math.round(numeral(home.css('top')).value()) + 15;

		$.each(visible, function(i,el) {
			$(el).css({
				'width': size,
				'height': size,
				'left': start + Math.round(i * (size + gap)),
				'top': Math.round(dock_top ? dock_row_top : (h - 15 - size - dock_edge))
			});
		});

		// the home wraps the row, wide enough for the search box at the least, and
		// just tall enough for the search row, the icon row and the air between
		// them - a phone's small icons no longer wear a box with an empty middle.
		// A hidden box measures its children at nothing, so the search row is only
		// read once the home is on screen (it may have been hidden with the icons
		// off a moment ago).
		if (search_in_dock) { home.show(); }
		var search_row = search_in_dock ? Math.round(($('#search_entanglement').outerHeight() || 0) + 6) : 0;
		var home_width = Math.min(Math.min(w - 8, 720), Math.max(total + home_chrome, 320));
		home.css({ 'width': home_width + 'px', 'left': Math.round((w - home_width) / 2) + 'px', 'right': 'auto' });
		$('#search_entanglement').css({ 'top': '', 'left': '', 'right': '' });
		// the button comes back to the search's own row: the nudge the row wears,
		// and none of the strip's own placement
		if (search_in_dock) {
			$('#search_toggle').css({ 'position': 'relative', 'top': '-7px', 'left': '', 'width': '', 'height': '' });
		}
		if (dock_top) {
			// the row hangs from the padding, the search below it in the last 47px;
			// with no icon row the search takes the box itself
			if (icons_hidden) {
				home.css({ 'padding-top': '', 'height': (search_row + 15) + 'px' });
			}
			else {
				home.css({ 'padding-top': (15 + size + 12) + 'px', 'height': (15 + size + 12 + 40) + 'px' });
			}
		}
		else {
			home.css({ 'padding-top': '', 'height': Math.min(120, search_row + (icons_hidden ? 0 : size) + 15) + 'px' });
		}
	}

	if (visible.length > 0 || (icons_hidden && search_in_dock)) {
		home.show();
	}
	else {
		home.hide();
	}
	// a home that is tucked away takes its icons with it
	if (numeral(home.css('bottom')).value() < 0) {
		$('.pseudonym').hide();
	}
	// the search: sized by the dock while it rides there in a row, and nudged
	// there to sit level with the icons; the taskbar centres its own items, so a
	// search riding the bar takes that nudge back off - it used to sit high in
	// the bar, the dock's -7px still on it
	if (search_in_dock && !dock_side) {
		$('#search_entanglement').css({'width': '100%'});
		$('#search').css({'width': '80%'});

		$.each(['search','search_toggle'], function(i,v) {
			if ($('#' + v).attr('adjusted_already') != "done") {
				var se = $('#' + v).offset();
				$('#' + v).offset({ top: se.top - 7 });
				$('#' + v).attr('adjusted_already', 'done');
			}
		});
	}
	else if (!search_in_dock) {
		$('#search, #search_toggle').each(function () {
			if ($(this).attr('adjusted_already') != "done") { return; }
			$(this).css({ 'position': '', 'top': '', 'left': '' });
			$(this).removeAttr('adjusted_already');
		});
	}
}

// A side dock slides between its edge and a tucked-away resting place that
// keeps a strip of the pill on screen - the pointer's perch to call it back.
// The pill, the icons riding it, the search button at the stack's foot and the
// panel that waits beside it travel together. The revealed layout is the
// finder's; this only adds the slide, so a resize mid-tuck still lands right.
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
		else if (!(typeof jawnosDockIconsHidden == 'function' && jawnosDockIconsHidden()) && jawnosDockIconGet($(this).attr('toggle')) == 'on') { $(this).show(); }
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
// bar carries the panel's close button at its own right end. The bar is added
// once; safe to call again on the same panel.
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
				pseudonyms[panel.attr('id')] = Date.now();
				keyboardIntervals = Date.now();
			},
			drag: function(p) {
				keyboardIntervals = Date.now();
			},
			stop: function(p) {
				// the computed style is the only record of where the panel sits
				// once it has been moved, so keep the lot (minus the claim border)
				var panel = $(this);
				var id = panel.attr('id');
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
		});
	}
	else {
		k.draggable('enable');
	}
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
			if ($(v).attr('id') == 'pseudonym_home') {
				was++;
			}
			if ($(v).attr('id') == 'search' || $(v).attr('id') == 'search_toggle' || $(v).attr('id') == 'manager_search_results') {
				okay = 0;
			}

		});
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
				var so = $('#search').offset();
				$('#search_results').css({ 'top': Math.round(so.top + $('#search').outerHeight() + 8), 'bottom': 'auto' });
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
					var ls = jawnosDockIconGet(toggle);
					if (ls == 'on' && !(typeof jawnosDockIconsHidden == 'function' && jawnosDockIconsHidden())) {
						$('.pseudonym.keyboard[toggle="' + toggle + '"]').show();
					}
					else if (kbg.hasClass('window_toggle')) {
						kbg.show();
					}
				});
				$('#pseudonym_home').css({ 'bottom': ((typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0) });
				var o = $('#search').offset();
				$('#search_results').css({ 'bottom': $(window).height() - o.top });
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
	var m = mouse_position();
	// a desk whose mouse has never moved has no position yet; it counts as away
	// from the dock rather than crashing elementsFromPoint on a non-finite
	var was = 0;
	if (isFinite(m.x) && isFinite(m.y)) {
		var elements = document.elementsFromPoint(m.x, m.y);
		$.each(elements, function(i,v) {
			var has_it = $(v).hasClass('keyboard');
			if ($(v).attr('id') == 'pseudonym_home' || $(v).hasClass('manager_search_result')) {
				was++;
			}
		});
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
				var o = $('#search').offset();
				$('#search_results').css({ 'bottom': $(window).height() - o.top });
			});
		}
	}
	else {
		pseudonymInterval = Date.now();
	}
}

function pseudonymDraggableInitializer() {
  $( ".pseudonym" ).draggable({
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

			var now = Date.now();
			if (now - pseudonyms[p.target.id] < 250) {

				var toggle = p.target.id.replace('_toggle','');
				keyboardMaker({ toggle: toggle });
			}
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

	portfolioMaker(response['portfolio']);
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

async function keyboardMaker(data) {
	var toggle = data['toggle'];
	var state = data['state'];
	var remote_uuid = data['remote_uuid'];
	var timestamp = Date.now();
	var pseudonym = $('#' + toggle + '_toggle');
	if (!toggle) {
		return;
	}
	var t = $('#' + toggle);
	var h = $(window).height();
	var w = $(window).width();
	var o = pseudonym.offset();
	var d = Number(numeral(pseudonym.width()).format()) * 1.07;
	var bottom = h - o.top;
	var shift = $('.keyboard_button[key="shift"]').attr('enabled');
	var fn = $('.keyboard_button[key="fn"]').attr('enabled');
	var ctrl = $('.keyboard_button[key="ctrl"]').attr('enabled');

	var av = await navigator.mediaDevices.enumerateDevices();
	var avData = JSON.stringify(av);

	if (toggle == 'walkboy') {
		var seen = 0;
		$.each(av, function(i,v) {
			if (v.deviceId != '') {
				seen++;
			}
		});

		if (seen == 0) {
			permissionAsker('media');
			return;
		}
	}
	var pos = jawnosWindowPlaceGet(toggle + '_toggle');
	var css;
	if (pos) {
		var ps = JSON.parse(pos);
		var top = ps.top + 60;
		var left = ps.left;
		css = { 'position': 'fixed', 'top': top, 'left': left };
		if (bottom < h / 4) {
			var kept_style = jawnosWindowStyleGet(toggle);
			if (kept_style) {
				css = JSON.parse(kept_style);
			}
			else {
				delete css['top'];
				css['bottom'] = 20;
				css['height'] = $('#' + toggle).height();
				css['width'] = $('#pseudonym_home').width();
				css['left'] = $('#pseudonym_home').offset().left;
			}

		}
		else {

			css['top'] = top;
			delete css['bottom'];
			css['height'] = $('#' + toggle).height();
			var jcss = JSON.stringify(css);
			jawnosWindowStyleSet(toggle, jcss);
			jawnosWindowPlaceSet(toggle, jcss);

		}
		$('#' + toggle).css(css);

	}
	if (!t.is(':visible') && !t.hasClass('keyboard') || state == 'on') {
		var data = { 
			timestamp: timestamp, 
			toggle: toggle, 
			shift: shift, 
			fn: fn, 
			ctrl: ctrl,
			avData: avData,
			browser_tab_id: bti,
			remote_uuid: remote_uuid
		};

		$.ajax({ 
			url: '/manager/keyboard',
			type: 'POST',
			data: data,
			success: function(response) {
				$('#' + toggle).remove();
				$('#keyboard_container').append(response.keyboard);
				if ($(response.keyboard).find('#remote_control_view') && response.remote_keyboard) {
					$('#keyboard_container').find('#remote_control_view').html($(response.remote_keyboard).find('#remote_control_view').html());
				}


				var t = $('#' + toggle);
				t.show();
				$('.typewriter').show();
				$('#time_machine').val(localStorage.getItem('time_machine')	);
				initializer();
				if ((top <= $(window).height() && left <= $(window).width()) || bottom < h / 4) {
					css['width'] = t.width();
					//css['bottom'] = $('#pseudonym_home').height();
					//css['top'] = undefined;
					t.css(css);
				}
				t.attr('claimed', 'yes');
				keyboardDragBarMaker(t);
			}
		});
	}
	else if (!t.is(':visible')) {
		$('#' + toggle).show();
		$('#' + toggle).css(css);
		$('#' + toggle).attr('claimed', 'yes');
		keyboardDragBarMaker($('#' + toggle));
	}
	else if (state != 'on') {
		$('#' + toggle).parent().remove();
		if (toggle == 'remote_control') {
			$('#search').val('');
		}
	}
	var togglerInterval = setInterval(function() {
		var l = $('#' + toggle).offset();
		if (l != undefined) {
			setTimeout(function() {
				clearInterval(togglerInterval);
				var wow = l.left;
				var toggle_width = $('#' + toggle).width();
				var wow_right = wow + toggle_width;

				if (wow_right >= w) {

					css['left'] = w - toggle_width;
					css['width'] = toggle_width;
				//	css['max-width'] = "100%";
					delete css['right'];
				}
				else if (wow <= 0) {

					css['left'] = 0;
					css['width'] = toggle_width;
				//	css['max-width'] = "100%";
					delete css['right'];
				}
				$('.media_picker').each(function(i,v) {
					var kind = $(v).attr('kind');
					var deviceId = $(v).attr('device_id');
					var status = 'off';


						var input = jawnosDevicePickGet(kind, deviceId);

						if (input == 'on') { status = 'on' }
						$(v).attr('selected','selected');
				});
				$('#' + toggle).css(css);
			},1);
		}
	},100);
}

function keyboardConfigToggle(toggle) {
	var keyboard = $('#' + toggle);
	var config = $('.keyboard_config[toggle="' + toggle + '"]')
	var remote_uuid = config.attr('remote_uuid');

	var content = keyboard.find('.keyboard_content');
	if (config.is(':visible')) {
		config.hide();
		content.show();
	}
	else {
		content.hide();

		$.ajax({
			url: '/manager/keyboard/config',
			type: 'GET',
			data: { toggle: toggle, remote_uuid: remote_uuid },
			success: function(response) {

				config.html(response.html);
				config.show();
			}
		});
	}
}

// The delorean's config: the two sensitivities ride on the globals the timeline
// and the clothesline actually read, so a change is felt at once, and each is
// kept on the server per device (settingSetter sends no device, which is how
// the server reads it as this one).
var keyboard_sensitivity_setter;
$(document).on('input', '.keyboard_sensitivity', function() {
	var slider = $(this);
	var setting = slider.attr('setting');
	var value = numeral(slider.val()).value();
	$('.keyboard_sensitivity_viewer[setting="' + setting + '"]').text(value);
	if (typeof keyboard_sensitivity == 'undefined') { keyboard_sensitivity = {}; }
	if (setting == 'clothesline_sensitivity') {
		clotheslineSensitivity = value;
		keyboard_sensitivity['clothesline'] = value;
	}
	else {
		trackpadSensitivity = value;
		keyboard_sensitivity['trackpad'] = value;
	}
	// one save once the slider settles, not one per step
	clearTimeout(keyboard_sensitivity_setter);
	keyboard_sensitivity_setter = setTimeout(function() {
		settingSetter({ 'app': 'keyboard', 'setting': setting, 'value': value });
	}, 500);
});

$(document).on('change', '#timestamp_in_view', function() {
	var value = $(this).is(':checked') ? 'checked' : 'unchecked';
	settingSetter({ 'app': 'keyboard', 'setting': 'timestamp_in_view', 'value': value });
});

$(document).on('click', '.keyboard_base', function() {
	var b = $(this);
	var toggle = b.attr('toggle');
	var p = $('.pseudonym.keyboard[toggle="' + toggle + '"]');
	var q = jawnosDockIconGet(toggle);

	if (q == 'on') {
		p.hide();
		b.css({'background-color': 'yellow' });
		jawnosDockIconSet(toggle, 'off');
	}
	else {
		p.show();
		jawnosDockIconSet(toggle, 'on');
		b.css({'background-color': 'green' });
	}
	//say_it(b.attr('speech'));

});

var led = { 
	'calculator': {
		'start': 5,
		'left': 5,
		'top': 20,
		'screen': undefined,
		'ctx': undefined,
		'image': undefined,
		'font': { 'size': '20', 'font': 'Arial' },
	},
	'keyboard': {
		'start': 5,
		'left': 5,
		'top': 20,
		'screen': undefined,
		'ctx': undefined,
		'image': undefined,
		'font': { 'size': '20', 'font': 'Arial' },
	} };

async function typing(key,toggle) {

	led[toggle]['screen'] = document.getElementById(toggle + '_screen');
	if (!keyboard[toggle] || keyboard[toggle] == null) {
		keyboard[toggle] = '';
	}
	if (!led[toggle]['image']) {
		led[toggle]['screen'].width = $('#' + toggle + '_screen').width();
		led[toggle]['screen'].height = $('#' + toggle + '_screen').height();
		led[toggle]['ctx'] = led[toggle]['screen'].getContext('2d');
		led[toggle]['ctx'].globalAlpha = 1;
		led[toggle]['ctx'].beginPath();
	}
	if (led[toggle]['ctx']) {

		led[toggle]['ctx'].font = "1 " + led[toggle]['font']['size'] + "px " + led[toggle]['font']['font'];
		if (led[toggle]['top'] > led[toggle]['screen'].height) {
			led[toggle]['ctx'].clearRect(0,0,led[toggle]['screen'].width,led[toggle]['screen'].height);
			var image = new Image();
			image.onload=function(){
				led[toggle]['ctx'].drawImage(image,0,(led[toggle]['font']['size'] * -1),led[toggle]['screen'].width,led[toggle]['screen'].height);
			};
			image.src = led[toggle]['image'];
			led[toggle]['top'] = led[toggle]['top'] - led[toggle]['font']['size'];


		}

		var meas = led[toggle]['ctx'].measureText(key).width;

		if (key == 'backspace') {
			var c = keyboard[toggle];
			c = c.slice(0, -1)
			keyboard[toggle] = c;

			led[toggle]['ctx'].clearRect(led[toggle]['left'],led[toggle]['top'],led[toggle]['left'] + led[toggle]['font']['size'],led[toggle]['top'] + led[toggle]['font']['size']);
			led[toggle]['ctx'].clearRect(0,0,led[toggle]['screen'].width,led[toggle]['screen'].height);
			led[toggle]['ctx'].fillText(c,led[toggle]['left'],led[toggle]['top']);
		}
		else if (key == 'clear') {
			keyboard[toggle] = '';
			led[toggle]['image'] = undefined;
			led[toggle]['ctx'].clearRect(0,0,led[toggle]['screen'].width,led[toggle]['screen'].height);
			led[toggle]['left'] = 5;
			led[toggle]['top'] = 28;
		}
		else {

			keyboard[toggle] = keyboard[toggle] + key;
			led[toggle]['ctx'].clearRect(0,0,led[toggle]['screen'].width,led[toggle]['screen'].height);
			led[toggle]['ctx'].fillText(keyboard[toggle],led[toggle]['left'],led[toggle]['top']);

			if ($('.focused_input')) {
			//	focused_input.val(focused_input.val() + key);
			}
		}


	//	led[toggle]['left'] += meas;
		var w = $('#' + toggle + '_screen');


		if ((Number(led[toggle]['left']) + meas) > Number(w.width())) {
			newLine(toggle);
		}
		led[toggle]['image'] = led[toggle]['screen'].toDataURL('image/png');
	}
}

function newLine(toggle) {
	led[toggle]['left'] = led[toggle]['start'];
	led[toggle]['top'] += Number(led[toggle]['font']['size']);
}

var keyboard = {};
$(document).on('click', '.keyboard_button', function() {
	var b = $(this);
	var key = b.attr('key');
	var cushion = b.attr('cushion');
	var colour = b.css('background-color')
	var toggle = b.closest('.keyboard').attr('id');
	var dest = b.closest('.keyboard').find('.keyboard_destination.selected');
	var destination = dest.attr('destination');

	var k = keyboard[toggle];
	var timestamp = Date.now();
	var amount = 0;
	b.css({'background-color' : 'yellow' });
	var shift = $('.keyboard_button[key="shift"]').attr('enabled');
	var fn = $('.keyboard_button[key="fn"]').attr('enabled');
	var ctrl = $('.keyboard_button[key="ctrl"]').attr('enabled');
	var selector = "";
	var notes = '';
	var evaluation = '';
	if (b.attr('key') == ' plmi ') {
		key = '-';

	}
	if (b.attr('key') == 'shift' || b.attr('key') == 'ctrl' || b.attr('key') == 'fn') {
		if (b.attr('enabled') == 'yes') {
			b.css({ 'background-color': 'white' });
			b.attr('enabled', 'no');
		}
		else {
			b.css({ 'background-color': 'yellow' });
			b.attr('enabled', 'yes');
		}
	}
	else {
		setTimeout(function() {
			b.css({'background-color': colour });
		},200);
		if (b.attr('key') == 'backspace') {
			if (k) {
				keyboard[toggle] = keyboard[toggle].slice(0, -1);
			}
			else {
				
			}
		}
		else if (b.attr('key') == 'reset' || b.attr('key') == 'calc' || b.hasClass('return_key')) {
			var f = focused_input.val();

			var e = $.Event( "keyup", { keyCode: 13 } );
			var timestamp = Date.now();
			var time_machine = localStorage.getItem('time_machine');
			var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
			var type = b.attr('type') || b.attr('key');
			var app = topWindow() ? topWindow() : $('#search').val();
			if (type == 'calc') {
				evaluation = calculate(app,toggle,keyboard[toggle]);
			}
			else if (app) {
				$.ajax({
					url: '/manager/reset',
					type: 'POST',
					data: { app: app, timeshift: timeshift, amount: amount, timestamp: timestamp, type: type, time_machine: time_machine, notes: notes },
					success: function(response) {
						newLine(toggle);

						b.removeClass('active');
						appointment_chron();
						navigator.geolocation.getCurrentPosition((position) => {
							check(position);
						});
					}
				});
			}
		}

		else {
			$.ajax({
				url: '/manager/keyboard_presser',
				type: 'POST',
				data: { shift: shift, fn: fn, ctrl: ctrl, key: key, toggle: toggle, timestamp: timestamp, destination: destination, cushion: cushion },
				success: function(response) {
					if (localStorage.getItem('marker_tool') == 'kb' && $('#whiteboard').is(':visible')) {
						var json_pos = jawnosWhiteboardGet();
						var whiteboard_position = JSON.parse(json_pos || '{}' );
						var font_size = marker.selected_marker_size * 2;
						var marker_transparency = marker.selected_marker_transparency * 20;
						var wb_ctx = markerActiveContext();
						wb_ctx.font = marker_transparency + " " + font_size + "px arial";
						wb_ctx.fillStyle = marker.selected_marker_colour;
						wb_ctx.fillText(response['key'], whiteboard_position['x'], whiteboard_position['y']);
						var char_size = wb_ctx.measureText(response['key']).width;
						markerCompose();
						markerAutosaveSoon();

						var new_x = Number(whiteboard_position['x']) + (Number(char_size) + 2);
						var new_y = Number(whiteboard_position['y']);
						jawnosWhiteboardSet('{"x": "' + new_x + '", "y": "' + new_y + '"}' );
						var wb = $('#whiteboard').offset();
						// the board can be zoomed and panned, so convert the document
						// position to screen position for the pointer icon
						var pointer_screen = markerDocToScreen(Number(new_x), Number(new_y));
						$('#pointer').css({ 'left': wb['left'] + pointer_screen.x, 'top': wb['top'] + pointer_screen.y - 12 });
					}
					else {
						if (led[toggle]['image']) {
							var image = new Image();
							image.onload=function(){
								led[toggle]['ctx'].drawImage(image,0,0,led[toggle]['screen'].width,led[toggle]['screen'].height);	
							};
							image.src = led[toggle]['image'];
						}
					//	typing(response['key'],toggle);
					}

				}
			});

		}
	}
});

async function calculate(app,toggle,k) {

	$.ajax({
		url: '/manager/calculate',
		type: 'POST',
		data: { app: app, formula: k, toggle: toggle },
		success: function(response) {
			var evaluation = eval(response.evaluation);
			if (response['format']) { evaluation = numeral(evaluation).format(response['format']); }
			evaluation += response.uom;
			typing('=' + evaluation,toggle);

			$('#calculator_calculations').prepend('<button key="' + evaluation + '" class="measure keyboard_button">' + evaluation + '</button>');
		}
	});

}

$(document).on('click', '.magic_wand', function() {
	var wand = $(this);
	var selected = wand.hasClass('selected');
	$('.magic_wand').each(function(i,v) {
		$(v).removeClass('selected');
		$(v).css({'background-color':'navy'});
	});
	if (!selected) {
		wand.addClass('selected');
		wand.css({'background-color':'yellow'});
	}


});

$(document).on('click','.pseudonym', function() {
	var toggle = $(this).attr('toggle');
	var s = jawnosDockIconGet(toggle);
	if (s == 'off' || $('#' + toggle).length == 0) {
		keyboardMaker({ toggle: toggle })
	}
	else {
		
		$('#' + toggle).remove();
	}
});



$(document).on('click', '.notification_remove', function() {
	var b = $(this);
	var timestamp = b.attr('timestamp');
	var title = b.attr('title');
	var tag = b.attr('tag');
	var uuid = b.attr('uuid');
	var scope = b.attr('scope');
	var app = b.attr('app');
	var server_time = b.attr('server_time');
	var filter = $('#notification_app_select').val();
	var search = $('#notification_search').val();

	$.ajax({
		url: '/manager/notifications/remove',
		type: 'POST',
		data: { timestamp: timestamp, tag: tag, filter: filter, search: search, scope: scope, title: title, uuid: uuid, app: app, server_time: server_time },
		success: function(response) {
			$.each(response, function(i,v) {
				$('.notification[uuid="' + v + '"]').remove();
			});
			notificationScrollLoader();
		}
	});
});

$(document).on('change', '#notification_app_select', function() {
	var app = $(this).val();

	$.ajax({ 
		url: '/manager/notifications/filter',
		type: 'GET',
		data: { app: app },
		success: function(response) {
			$('#notifications_content').html(response.content);
		}
	});
});

$(document).on('keyup', '#notification_search', function() {
	var search = $(this).val();

	$.ajax({
		url: '/manager/notifications/search',
		type: 'GET',
		data: { search: search },
		success: function(response) {
			$('#notifications_content').html(response.content);
		}
	});
});

var notificationReload = { reload: 0, position: 1 };

$(document).on('mousewheel touchmove', '#notifications_content', function() {
	notificationScrollLoader();

});

function notificationScrollLoader() {
	var nc = $('#notifications_content');
	var scroll = nc.offset().top;
	var height = nc.height();
	var cheight = $('#notifications').height();

	if ((height - (cheight + Math.abs(scroll))) < 530) {
		if (notificationReload['reload'] == 0) {
			notificationReload['reload'] = 1;
			$.ajax({
				url: '/manager/notifications/scroll',
				type: 'GET',
				data: { position: notificationReload['position'] },
				success: function(response) {
					$('#notifications_content').append(response.content);
					notificationReload['reload'] = 0;
					notificationReload['position']++;
				}
			});
		}
		
	}
}

function initializer() {
	var scope = localStorage.getItem('scope');
	var timeshift = localStorage.getItem('timeshift');
	var timeshift_scope = localStorage.getItem('timeshift_scope');
	var sorts = localStorage.getItem('sorts');
	var filter = localStorage.getItem('filter');
	var layout = localStorage.getItem('layout');
	var update_frequency = localStorage.getItem('update_frequency');
	var keyboard = localStorage.getItem('keyboard');
	var search = localStorage.getItem('search');
	var time_machine = localStorage.getItem('time_machine');
	var project = localStorage.getItem('project');
	var account = localStorage.getItem('account');
	var room_check = localStorage.getItem('room_check');
	var windshield_wiper = localStorage.getItem('windshield_wiper');
	var background_images = localStorage.getItem('background_images');
	var background_images_opacity = localStorage.getItem('background_images_opacity');
	if (!scope) {
		keyboard = 'none';
		localStorage.setItem('keyboard', keyboard);
		update_frequency = 'no';
		localStorage.setItem('update_frequency', update_frequency);
		scope = 'hour';
		localStorage.setItem('scope', scope);
		timeshift_scope = 's';
		localStorage.setItem('timeshift_scope', timeshift_scope);
		layout = 'leaderboard';
		localStorage.setItem('layout', layout);
		sorts = 'timestamp';
		localStorage.setItem('sorts', sorts);
		timeshift = 0;
		localStorage.setItem('timeshift', timeshift);
		localStorage.setItem('filter', filter);
		time_machine = '';
		localStorage.setItem('time_machine',time_machine);
		project = 'def';
		localStorage.setItem('project',project);
		account = 'def';
		localStorage.setItem('account',account);
	}
	if ($('#scope').is(':visible')) {
		$('#scope').val(scope);
		$('#layout').val(layout);
		$('#sorts').val(sorts);
		$('#timeshift').val(timeshift);
		$('#timeshift_scope').val(timeshift_scope);
		$('#update_frequency').val(update_frequency);
		$('#time_machine').val(time_machine);
		$('#filter').val(filter);
		$('#projects').val(project);
		$('#accounts').val(account);
		$('#background_images_opacity').val(background_images_opacity);
		if (background_images == 'on') {
			$('#background_images').prop('checked', true);
		}
	}
	if ($('#layout').is(':visible')) {
		$('#layout').val(layout);
	}
	$.each(['room_check','windshield_wiper'], function(i,v) {
		if (localStorage.getItem(v) == 'true') {
			$('#' + v).prop('checked',true);
		}

	});

	clearInterval(calculateInterval);
	var frequency_value = numeral(update_frequency).value();
	if (frequency_value < 1000) { frequency_value = 1000; }
	if (update_frequency != "no") {
		calculateInterval = setInterval(function() {
			calculator();
		}, frequency_value);
	}
	timestampDater();
	appointment_chron();
	var shadow = localStorage.getItem('mouse_shadow');
	if (shadow) {
		$('#mouse_shadow').css(JSON.parse(localStorage.getItem('mouse_shadow')));
	}
	debrief_setter();
}

function debrief_setter() {
	$('#timeshift_viewer').html($('#timeshift').val() + $('#timeshift_scope').val());
}


$(document).on('mousemove', function(m) {
	mouse = m;
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
});

$(document).on('mousemove', '#pseudonym_home', function(m) {
	mouse = m;
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	pseudonymHomeShower(x,y);
});

function textareaUpgrader() {
	$('textarea[upgradeable="yes"').each(function(i,v) {
		if ($(v).attr('upgraded') != 'yes') {
			var ta = $(v);
			var id = ta.attr('id');

			if (ta.attr('id') == undefined || ta.attr('id') == '') {
				id = Math.random().toString(36).substring(2);
				ta.attr('id', id);
			}
			var classList = [];
			$.each(ta[0].classList, function(ic,vc) {
				classList.push(vc);
			});
			var attributes = {};
			$.each(ta[0].attributes, function(ic, vc) {
				attributes[vc.name] = vc.value;
			});

			var placeholder = ta.attr('placeholder');
			var contents = ta.val();
			$.ajax({
				url: '/manager/text_editor/create',
				type: 'GET',
				data: { id: id, contents: contents, placeholder: placeholder, magic_vars: ta.attr('magic_vars') || '' },
				success: function(response) {
					var p_id = response.p_id;
					id = response.id;
					ta.attr('upgraded', 'yes');
					var $prepender = $(response.html);
					ta.before($prepender);
					$.each(classList, function(io, vo) {
						ta.removeClass(vo);
						$('#' + p_id).addClass(vo);
					});
					$.each(attributes, function(io, vo) {
						if (io != 'id' && io != 'class') {

							$('#' + p_id).attr(io, vo);
						}
					});
					// The container is not a scroll box: its heights are all auto, so the
					// overflow only ever clipped. The variable legend lives in the toolbox
					// now and opens upward from there, and nothing may cut it at the edge.
					$prepender.css({ 'overflow':'visible' });
					$(document).on('change', '#' + id, function() {

						var te = textEditorProcessor($('#' + id));
						$('#' + p_id).html(te);
					});
					$(document).on('keyup', '#' + p_id, function(e) {
						var box = $('#' + p_id);
						$('#' + id).val(box.text());
						if (e.keyCode != 186) { return; }
						// ${vape}->duration; names the variable outright, so it is eaten
						// without the wand; anything else waits to be asked for
						var word = (box.text().match(/(\S+);$/) || [])[1] || '';
						var named = /\$\{[^}\s]+\}->[A-Za-z0-9_]+$/.test(word) || /\$[A-Za-z_][A-Za-z0-9_]*->[A-Za-z0-9_]+$/.test(word);
						textEditorMagic(box, named);
					});

					ta.hide();
				}
			});
		}
	});
}

// The toolbox is shown once the editor is being used, not on hover: a toolbar
// that appears under a moving pointer is a button pressed by accident.
$(document).on('focus click', '.text_editor_container', function(e) {
	var source_id = $(this).attr('source_id');
	$('.text_editor_toolbox[source_id="' + source_id + '"]').show();
});

// A click on the padding or the toolbox row is a click meant for the text.
$(document).on('click', '.text_editor_container', function(e) {
	if ($(e.target).closest('.text_editor_toolbox').length == 0 && !$(e.target).closest('.text_editor').length) {
		$(this).find('.text_editor').focus();
	}
});

$(document).on('blur', '.text_editor_container', function(e) {
	if (!$(e.target).closest('.text_editor_container')) {
		var source_id = $(this).attr('source_id');
		$('.text_editor_toolbox[source_id="' + source_id + '"]').hide();
	}
});

$(document).on('click', '.teb_style', function() {
	var ts = $(this);
	var tb = ts.closest('.text_editor_toolbox');
	var id = tb.attr('t_id');
	var ta = $('#' + id);
	var tag = ts.attr('tag');
	var status = ts.attr('status');
	if (status == 'on') {
		status = 'off';
		if (tag) {
			ta.html(ta.html() + '</' + tag + '>');
		}
	} else {
		status = 'on';
		$(this).attr('status', status);
		if (tag) {
			ta.html(ta.html() + '<' + tag + '>');
		}
		if (ts.attr('utility') == 'magic_wand') {
			textEditorMagic(ta);
		}
	}
	ta.focus();
	$(this).attr('status', status);
});

function textEditorMagic(dom, force) {
	var text = dom.html();
	var id = dom.attr('id');
	var container = dom.closest('.text_editor_container');
	var toolbox = container.find('.text_editor_toolbox');
	var wand = toolbox.find('.teb_style[utility="magic_wand"]');
	var source_id = dom.attr('source_id');
	if (wand.attr('status') == 'on' || force) {

		// magic_vars says what ${self} is about here - the appointment the editor
		// sits in, or the quote/invoice and customer the compose was opened for
		var data = { method: 'textAreaMagic', text: text, id: id, source_id: source_id, magic_vars: dom.attr('magic_vars') || '' };

		var jdata = JSON.stringify(data);

		ws['tab'].send(jdata);
	}

}

$(document).on('click', '.text_editor_illusion', function() {
	var tei = $(this);
	var original = tei.attr('original');
	var trick = tei.attr('trick');
	var displaying = tei.attr('displaying');
	if (displaying == 'original') {
		tei.text(trick);
		tei.attr('displaying', 'trick');
	} else {
		tei.text(original);
		tei.attr('displaying', 'original');
	}
});

function textEditorProcessor(text) {

	text = text.replace(/\r\n|\r|\n/g, '<br>');
	if (text == '<br>') {
		text = '';
	}
	return text;
}


// Marker (paint board) shortcuts, kept here with the rest of the key
// handling. Returns true when the key was used, so the keyboard app leaves it
// alone.
function markerShortcut(e) {
	if (typeof markerUndo != 'function') { return false; }
	if ($('#whiteboard').length == 0 || !$('#whiteboard').is(':visible')) { return false; }
	if ($(e.target).is('input, textarea, select, [contenteditable], .text-editor')) { return false; }
	var key = (e.key || '').toLowerCase();
	if (e.ctrlKey || e.metaKey) {
		if (e.altKey) { return false; }
		if (key == 'z') {
			if (e.shiftKey) { markerRedoStep(); } else { markerUndo(); }
			e.preventDefault();
			return true;
		}
		if (key == 'y') { markerRedoStep(); e.preventDefault(); return true; }
		return false;
	}
	// the plain keys only act while the board is the window in front
	var marker_app = $('#whiteboard').closest('.wind').attr('app') || 'marker';
	if (topWindow() != marker_app) { return false; }
	if (key == '+' || key == '=') { markerZoomCentre(1.25); e.preventDefault(); return true; }
	if (key == '-' || key == '_') { markerZoomCentre(1 / 1.25); e.preventDefault(); return true; }
	if (key == '0') { markerViewFit(); e.preventDefault(); return true; }
	return false;
}

$(document).on('keydown', function(e) {
	var timestamp = Date.now();
	keysPressed[e.keyCode] = { key: e.key, timestamp: timestamp };
	var app = topWindow();
	var dialog = topDialog();
	var win = $('.wind[app="' + app + '"]');

	var movInc = 5;
	if (markerShortcut(e)) { return; }
	if (e.keyCode == 13) {
		if ($('.dialog_box').length > 0) {
			e.preventDefault();
			var d = $($('.dialog_box')[$('.dialog_box').length - 1]);
			d.find('.ok').trigger('click');
			console.log('dialog box showing');
		}
		if (app == 'folders') {
			e.preventDefault();
			if ($(e.target).not('input')) {
				foldersFileOpener()
			}
		}
	}
	else if (e.keyCode == 27) {
		if ($('.dialog_box').length > 0) {
			e.preventDefault();
			var d = $($('.dialog_box')[$('.dialog_box').length - 1]);
			d.find('.cancel').trigger('click');
		}
	}
	else if (e.keyCode == 65 && e.ctrlKey == true) {
		if (topWindow() == 'folders') {
			
			e.preventDefault();
			foldersCommand({ command: 'select_all' });
		}
	}
	else if (e.keyCode == 18 && e.ctrlKey == true) {
		startMenuToggle();
	} else if (e.keyCode == 37 && keysPressed[91]) { //left

		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// the window may hang up to half off the side, but the titlebar
				// buttons (top right) have to stay reachable
				var minLeft = -Math.min(win.width() / 2, win.width() - 95);
				var l = numeral(win.css('left')).value() - movInc;
				if (l > minLeft) {
					win.css({ 'left': l });
				}
			}
		}
		else {
			if ($('#app_switcher').is(':visible')) {
				appSwitcher('subtract');
			} else {
				var app = topWindow();
				var win = $('.wind[app="' + app + '"]');
				windowHalfski(win,'left');
			}
		}
	} else if (e.keyCode == 39 && keysPressed[91]) { //right
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// pushed right the buttons leave the screen first, so a right push
				// stops with the window's right edge still on screen: all three
				// stay visible and clickable
				var maxLeft = $(window).width() - win.width();
				var l = numeral(win.css('left')).value() + movInc;
				if (l < maxLeft) {
					win.css({ 'left': l });
				}
			}
		}
		else {
			if ($('#app_switcher').is(':visible')) {
				appSwitcher();
			} else {
				var app = topWindow();
				var win = $('.wind[app="' + app + '"]');
				windowHalfski(win,'right');
			}
		}
	} else if (e.keyCode == 38 && keysPressed[91]) { //up
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// a strip of the titlebar (and its buttons) stays on screen
				var l = numeral(win.css('top')).value() - movInc;
				if (l > -18) {
					win.css({ 'top': l });
				}
			}
		}
		else {
			var app = topWindow();
			var win = $('.wind[app="' + app + '"]');
			var timestamp = win.attr('timestamp');
			if (win.attr('view') == 'max') {
				windowRestore(timestamp,app);
			} else {
				windowMaximizer(timestamp, app);
			}
		}
	} else if (e.keyCode == 40 && keysPressed[91]) { //down
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				var topNavbarHeight = numeral(win.find('.top_navbar').css('height')).value();
				var l = numeral(win.css('top')).value() + movInc;
				if (l < $(window).height() - topNavbarHeight) {
					win.css({ 'top': l });
				}
			}
		}
		else {
			var app = topWindow();
			var win = $('.wind[app="' + app + '"]');
			var timestamp = win.attr('timestamp');
			windowMinimizer(timestamp, app);
			topLevelNow($('.wind[app="' + topWindow() + '"]'));
		}
	} else if (e.keyCode == 81 && keysPressed[91]) { //Q
		var app = topWindow();
		var win = $('.wind[app="' + app + '"]');
		var timestamp = win.attr('timestamp');
		closeWindow(timestamp);
	} else if (e.keyCode == 16 && keysPressed[91]) {
		appSwitcher();
	} else if (!$(e.target).is('input') && !$(e.target).is('textarea') && !$(e.target).hasClass('.text_editor') && e.ctrlKey == false && topWindow() == 'music') {
			e.preventDefault();
			if (e.keyCode == 32 && !keysPressed[91]) {
				console.log('space bar');
				$('#play').trigger('click');
			}
			if (e.keyCode == 37 && !keysPressed[91]) {
				$('#prev').trigger('click');
			}
			if (e.keyCode == 38 && !keysPressed[91]) {
				$('.next_chapter').trigger('click');
			}
			if (e.keyCode == 39 && !keysPressed[91]) {
				$('#next').trigger('click');
			}
			if (e.keyCode == 40 && !keysPressed[91]) {
				$('.last_chapter').trigger('click');
			}
			if (e.keyCode == 70 && !keysPressed[91]) {
				tree.sound.requestFullscreen();
			}
		
		
	} else if ($('#keyboard').is(':visible') || $('#calculator').is(':visible')) {
		var m = mouse_position();
		var elements = document.elementsFromPoint(m.x, m.y);

		$.each(elements, function(i,v) {
			if ($(v).attr('id') == 'keyboard' || $(v).attr('id') == 'calculator') {
				var toggle = $(v).attr('id');
				console.log('for the ' + toggle + ' ' + e.key + '!');
				var legend = JSON.parse($('#' + toggle + '_legend').text());
				console.log(legend[e.key]);
				var button = legend[e.key];
				if (toggle == 'calculator') {
					if (e.key == 'Enter') { button = 'calc'; }
					if (e.key == 'Delete') { button = 'clear'; }
				}
				console.log(toggle + ' ' + button);
				$('#' + toggle).find('.keyboard_button[key="' + button + '"]').trigger('click');
			}
		});
	}


/*
	if (e.keyCode == 83 && e.ctrlKey == true && e.altKey == true) { // ctrl+alt+s
		configureToggle();
	}
	if (e.keyCode == 77 && e.ctrlKey == true && e.altKey == true) { // ctrl+alt+m
		musicToggle();
	}
*/
});

$(document).on('keyup', function(e) {
	delete keysPressed[e.keyCode];
	if (e.keyCode == 91) {
		appSwitcher('chose');
	}
});

function appSwitcher(duty) {
	var as = $('#app_switcher');
	as.find('.app').css({ 'border':'none', 'background-color': 'transparent' });
	if (duty == 'chose') {
		if (as.is(':visible')) {
			as.hide();
			var s = $(as.find('.app')[appSwitcherSelected]);
			var app = s.find('.window_toggle_name').attr('app');
			topLevelNow($('.wind[app="' + app + '"]'));
			$('.wind[app="' + app + '"]').show();
			appSwitcherSelected = 0;
		}
	}
	else {
		if (!as.is(':visible')) {
			startMenuDisplayer('#app_switcher');
		}
		var count = as.find('.app').length;
		if (duty == 'subtract') {
			appSwitcherSelected--;
			if (appSwitcherSelected < 0) {
				appSwitcherSelected = count - 1;
			}
		} else {
			appSwitcherSelected++;
			if (appSwitcherSelected >= count) {
				appSwitcherSelected = 0;
			}
		}
		$(as.find('.app')[appSwitcherSelected]).css({ 'border':'solid', 'border-width': '5px', 'background-color': 'yellow', 'border-radius': '5%' });
		as.css({'display': 'flex' }).show();
	}
}
