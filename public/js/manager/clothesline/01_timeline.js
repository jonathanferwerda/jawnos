var timelineFetched = { start: undefined, end: undefined };
function timelineFetchedSet(appts) {
	if (!appts || !appts['__specs']) { return; }
	timelineFetched = {
		start: numeral(appts['__specs']['start']).value(),
		end: numeral(appts['__specs']['end']).value()
	};
}

// Place every row against the view as it now stands. A drag moves the window,
// so the percents the server computed for its own centre no longer say where a
// row belongs; this is also what lets a row fetched mid-drag land in the window
// the drag has since reached.
function timelinePositions(appts) {
	if (!appts || !appts['__specs']) { return; }
	var scope = localStorage.getItem('scope');
	var start = numeral(appts['__specs']['start']).value();
	var centre = numeral(appts['__specs']['timestamp']).value();
	var total = centre - start;
	if (!total) { return; }
	$.each(appts, function(i,ve) {
		if (i.match('__') || !ve || !ve['list']) { return true; }
		$.each(ve['list'], function(ie,v) {
			if (!v) { return true; }
			v[scope + '_percent'] = (v['timestamp'] - start) / total;
			if (v['duration']) {
				v[scope + '_start_percent'] = (v['timestamp'] - v['duration'] - start) / total;
				if (v['type'] == 'start' && v['timestamp'] < centre) {
					var dur = (centre - v['timestamp']) * -1;
					if (v['duration'] > dur) { v['duration'] = dur; }
				}
			}
			ve['placement_number'] = undefined;
		});
	});
}

// The poll refuses while the view is moving, and a drag only slides the rows it
// already has - a window it has not reached yet has nothing to slide in. So
// while a gesture is going, ask for the window the drag has reached (at most a
// few times a second, and only once the view nears what the payload covers) and
// fold the answer into the payload being drawn.
var timelinePrefetchWait = 400;
var timelinePrefetchAt = 0;
var timelinePrefetchBusy = 0;
function timelinePrefetch(sdiff) {
	if (timelinePrefetchBusy || typeof deloreanBringer != 'function' || typeof graphicalize != 'function') { return; }
	if (!response || !response.appts || !response.appts['__specs']) { return; }
	var now = Date.now();
	if (now - timelinePrefetchAt < timelinePrefetchWait) { return; }
	var specs = response.appts['__specs'];
	var start = numeral(specs['start']).value();
	var centre = numeral(specs['timestamp']).value();
	var end = centre + (centre - start);
	var margin = (end - start) * .25;
	if (timelineFetched['start'] != undefined) {
		// a forward move only needs the right edge checked (the left is behind
		// it), and a backward move only the left; both edges are no rows' land,
		// since nothing behind the view's left edge is fetched but carry-over rows
		if (sdiff < 0 && end <= timelineFetched['end'] - margin) { return; }
		if (sdiff > 0 && start >= timelineFetched['start'] + margin) { return; }
		if (!sdiff && start >= timelineFetched['start'] + margin && end <= timelineFetched['end'] - margin) { return; }
	}
	timelinePrefetchAt = now;
	timelinePrefetchBusy = 1;
	var data = deloreanBringer();
	// force the full pass: the echoing markers describe the window that was on
	// screen a moment ago, not the one the drag has reached
	delete data['stats'];
	$.ajax({
		url: '/manager/appointment_viewer',
		type: 'GET',
		data: data,
		success: function(respons) {
			timelinePrefetchBusy = 0;
			timelineMerge(respons);
		},
		error: function() {
			timelinePrefetchBusy = 0;
		}
	});
}

// A row is the same row by its uuid; the per-appointment query carries none (it
// reads only the columns the timeline draws), so fall back to the moment and
// kind, which identify one event of an app. The duration is left out on purpose:
// a still-running start's duration is rewritten as the view moves.
function timelineRowKey(row) {
	return row['uuid'] ? ('uuid:' + row['uuid']) : ['row', row['app'], row['timestamp'], row['type']].join('|');
}

// Fold a fetched payload into the one being drawn. Only rows (and the setting
// of an app not already held) are taken: the specs stay the drag's own, since
// they carry where the view is and the pixel-per-time scale the drag reads.
function timelineMerge(respons) {
	if (!respons || typeof respons !== 'object' || !respons.appts || !respons.appts['__specs']) { return; }
	if (!response || !response.appts || !response.appts['__specs']) { return; }
	var specs = respons.appts['__specs'];
	var merged = false;
	$.each(respons.appts, function(app, ve) {
		if (app.match(/^__/) || !ve || !ve['list']) { return true; }
		var held = response.appts[app];
		if (!held || !held['list']) {
			response.appts[app] = ve;
			merged = true;
			return true;
		}
		var seen = {};
		$.each(held['list'], function(i,row) {
			if (row) { seen[timelineRowKey(row)] = 1; }
		});
		$.each(ve['list'], function(i,row) {
			if (!row) { return true; }
			var key = timelineRowKey(row);
			if (seen[key]) { return true; }
			seen[key] = 1;
			held['list'].push(row);
			merged = true;
		});
		// the list is read in time order (the label rides the first dot)
		held['list'].sort(function(a,b) { return (a['timestamp'] || 0) - (b['timestamp'] || 0); });
	});
	// the window just fetched is part of what the payload now covers
	var start = numeral(specs['start']).value();
	var end = numeral(specs['end']).value();
	if (timelineFetched['start'] == undefined || start < timelineFetched['start']) { timelineFetched['start'] = start; }
	if (timelineFetched['end'] == undefined || end > timelineFetched['end']) { timelineFetched['end'] = end; }
	if (!merged) { return; }
	timelinePositions(response.appts);
	graphicalize();
}

// A gesture's last window is worth one fetch even when the poll is slow (or
// turned off): wait for the settle calculator() itself waits for, then let it
// decide. Re-armed while a glide or a held grab is still moving the view.
var timelineSettleAt;
function timelineSettleFetch() {
	clearTimeout(timelineSettleAt);
	timelineSettleAt = setTimeout(function() {
		timelineSettleAt = undefined;
		if (!clothesLineAtRest()) { timelineSettleFetch(); return; }
		if (typeof calculator == 'function') { calculator(); }
	}, clothesLineRest + 40);
}

function timelineScroller(data) {
	var wp = 0;
	var span = response.appts['__specs']['end'] - response.appts['__specs']['start'];
	var ww = $('#background').width();

		
	if (data.mousediff) {
		wp = data.mousediff / ww;
	}
	else if (data.diff) {
		wp = (data.diff) / span;
	}

	var sdiff = span * wp;
	if (data['sdiff']) {
		sdiff = data['sdiff'];
	}
	else {
		data['sdiff'] = sdiff;
	}

	var period = response.appts['__specs']['period'];
	// the centre the time machine alone stands for. The separate timeshift is not
	// folded into it: the drag below writes this back into #time_machine, and
	// anchoring the string on the final centre would count the timeshift again on
	// every poll, so each slide marched the view further back than the last.
	var tm_timestamp = response.appts['__specs']['time_machine_timestamp'] || response.appts['__specs']['timestamp'];
	response.appts['__specs']['end'] = response.appts['__specs']['end'] - sdiff;
	response.appts['__specs']['start'] = response.appts['__specs']['start'] - sdiff;
	response.appts['__specs']['timestamp'] = (numeral(response.appts['__specs']['timestamp']).value() - sdiff);
	response.appts['__specs']['time_machine_timestamp'] = (numeral(tm_timestamp).value() - sdiff);
	// the edge the fetch reached to travels with the view, or the prune would
	// drop the rows that were fetched to stick to it
	if (response.appts['__specs']['fetch_start'] != undefined) {
		response.appts['__specs']['fetch_start'] = numeral(response.appts['__specs']['fetch_start']).value() - sdiff;
	}

	var ts = quality_inventory(numeral(response.appts['__specs']['time_machine_timestamp']).value() );
	if (!$('#time_machine').is(':focus') && (data.mousediff || data['source'] == 'smoothScroll')) {
		$('#time_machine').val(ts)
		localStorage.setItem('time_machine', ts);
	}
	// a slide leaves the view on one moment, so the clock stands still there
	response.appts['__specs']['time_machine_stationary'] = 1;
//	timestamp = response.appts['__specs']['timestamp'];
	timelinePositions(response.appts);
	graphicalize(response);
	if (data['source'] == 'wheel') {
		// a wheel stream carries its own momentum: the fling that follows the
		// stream is the glide, and a new event means the fingers took over.
		// A plain wheel and the server's slide are not glided - they go exactly
		// where they are put.
		cancelAnimationFrame(clothesLinePos['timelineSmoothScrolling']);
	}
	else if (data['source'] != 'smoothScroll' && data['source'] != 'mousewheel' && data['source'] != 'slide') {
		timelineGlide(sdiff);
	}
	// while the gesture is going (a grab, its glide, or the wheel's stream) the
	// view is moving too fast for the poll to help; fill it as it goes
	if (data['source'] != 'slide' && (data['mousediff'] || data['source'] == 'smoothScroll' || data['source'] == 'wheel' || data['source'] == 'mousewheel')) {
		timelinePrefetch(sdiff);
	}

}

// The clothesline's glide, measured in time instead of pixels: a flick carries
// about 32x its distance, spread over however many frames the screen actually
// gives us, and it pauses with the tab. Each step lands like an input event
// would, so the time machine field keeps up and the next poll does not snap the
// view back mid-flight.
function timelineGlide(diff) {
	var span = response.appts['__specs']['end'] - response.appts['__specs']['start'];
	var ww = $('#background').width();
	cancelAnimationFrame(clothesLinePos['timelineSmoothScrolling']);
	var last = undefined;
	var reach = .97 / .03;
	var glideDiff = diff;
	var stopAt = (span / ww) * .09;
	var glide = function(now) {
		if (Math.abs(glideDiff) <= stopAt) {
			clothesLinePos['timelineSmoothScrolling'] = undefined;
			// the glide has carried the view somewhere new; settle it even if the
			// poll's next tick is a way off
			timelineSettleFetch();
			return;
		}
		if (last == undefined) { last = now; }
		var decay = Math.pow(.97, (now - last) / 5);
		last = now;
		var step = glideDiff * reach * (1 - decay);
		glideDiff = glideDiff * decay;
		clothesLinePos['moving'] = Date.now();
		clothesLinePos['timelineSmoothScrolling'] = requestAnimationFrame(glide);
		timelineScroller({ sdiff: step, source: 'smoothScroll' });
	};
	clothesLinePos['timelineSmoothScrolling'] = requestAnimationFrame(glide);
}

// A trackpad swipe arrives as a stream of small wheel events, and the last of
// them are often tiny as the fingers slow - which is why swiping only glided
// while the fingers were still moving. Keep the movement of the last fraction
// of a second instead, and when the stream has been quiet for a moment, glide
// from that velocity - one frame of it, the same starting point a touch flick
// gets from its last movement.
function timelineFling(diff) {
	var fling = clothesLinePos['fling'] = clothesLinePos['fling'] || { samples: [], settle: undefined };
	var now = Date.now();
	fling['samples'].push([now, diff]);
	while (fling['samples'].length > 1 && now - fling['samples'][0][0] > 160) { fling['samples'].shift(); }
	clearTimeout(fling['settle']);
	fling['settle'] = setTimeout(function() {
		fling['settle'] = undefined;
		var kept = fling['samples'];
		fling['samples'] = [];
		var moved = 0;
		$.each(kept, function(i,s) { moved += s[1]; });
		var elapsed = kept[kept.length - 1][0] - kept[0][0];
		// the samples arrive already damped by the swipe's sensitivity, so a
		// still finger is a hundredth of a pixel, not two
		if (Math.abs(moved) < 0.2 || elapsed <= 0) { return; }
		// the samples are pixels of finger travel; the glide moves in time, so one
		// frame of the swipe has to cross the same bridge a wheel event does
		var span = response.appts['__specs']['end'] - response.appts['__specs']['start'];
		var ww = $('#background').width();
		if (!ww) { return; }
		timelineGlide(((moved / elapsed) * 16) * (span / ww));
	}, 80);
}

$(document).on('click', '.clothesline', function() {
	var timestamp = Date.now();
	var app = $(this).attr('app');
	$.ajax({
		url: '/manager/clothesline',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			jawnosAlert(response.html);
		}
	});
});

$(document).on('change', '.clothes', function() {
	var timestamp = Date.now();
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var app = $(this).attr('app');

	var data = { timestamp: timestamp, setting: setting, value: value, app: app };
	if ($(this).is('select[multiple]')) {
		data['value'] = JSON.stringify(value);
		data['is_json'] = 'yes';
	}
	$.ajax({
		url: '/manager/clothesline',
		type: 'POST',
		data: data,
		success: function(response) {
			clotheslineRefresh();
		}
	});
});

$(document).on('click', '.clothes_picker', function() {
	var shirt = $(this);
	var app = shirt.attr('app');
	var td = shirt.attr('td');
	if (shirt.attr('re') == 'all') {
		if (shirt.attr('wearing') == 'on') {		
			$('.clothes_picker[app="' + app + '"][td="' + td + '"]').attr('wearing', 'off');
		}
		else {
			$('.clothes_picker[app="' + app + '"][td="' + td + '"]').attr('wearing', 'on');
		}
	}
	else {
		if (shirt.attr('wearing') == 'on') {
			shirt.attr('wearing', 'off');
		}
		else {
			shirt.attr('wearing', 'on');
		}
	}
	var time_plinko = {};
	$('.clothes_picker[wearing="on"]').each(function(i,v) {
		var td = $(v).attr('td');
		var re = $(v).attr('re');

		if (!time_plinko[td]) { time_plinko[td] = []; }
		time_plinko[td].push(re);
	});

	var setting = 'time_plinko';
	var value = JSON.stringify(time_plinko);
	$.ajax({
		url: '/manager/clothesline',
		type: 'POST',
		data: { setting: setting, value: value, app: app, timestamp: timestamp, is_json: 'yes' },
		success: function(response) {
			clotheslineRefresh();
		}
	});
});

// ---- the rail's own menu ---------------------------------------------------
// A right-press on a garment is about that pill: open its editor, take it off
// the line, or move it between the anticipatory head and the alphabetical rest.
function clotheslineGemAt(x, y) {
	var found;
	$.each(appPosition, function(i, o) {
		if (!o || !o[4] || o[4]['type'] != 'clothes') { return true; }
		if (o[0] < x && o[2] > x && o[1] < y && o[3] > y) { found = o[4]; return false; }
		return true;
	});
	return found;
}

function clotheslineMenuRow(menu, command, label) {
	$('<div class="clothesline_menu_row"></div>').attr('command', command).text(label).appendTo(menu);
}

function clotheslineMenu(item, px, py) {
	$('.clothesline_menu').remove();
	var menu = $('<div class="clothesline_menu"></div>')
		.attr('app', item['app'])
		.attr('head', item['head'] ? 1 : 0);
	clotheslineMenuRow(menu, 'edit', jawnosT('Edit'));
	clotheslineMenuRow(menu, 'remove', jawnosT('Remove'));
	clotheslineMenuRow(menu, 'bump', jawnosT('Bump'));
	clotheslineMenuRow(menu, 'settings', jawnosT('Settings'));
	$('body').append(menu);
	var margin = 6;
	var left = Math.min(px, $(window).width() - menu.outerWidth() - margin);
	var top = Math.min(py, $(window).height() - menu.outerHeight() - margin);
	menu.css({ left: Math.max(margin, left), top: Math.max(margin, top) });
}

$(document).on('contextmenu', '.background', function(e) {
	var y = numeral(e.clientY + $(document).scrollTop()).value();
	if (y < clothesLinePos['minHeight'] || y > clothesLinePos['maxHeight']) { return; }
	var x = e.clientX - numeral($(this).css('left')).value();
	var item = clotheslineGemAt(x, y);
	if (!item) { return; }
	e.preventDefault();
	clotheslineMenu(item, e.clientX, e.clientY);
});

function clotheslineEdit(app) {
	$.ajax({
		url: '/manager/clothesline',
		type: 'GET',
		data: { app: app, timestamp: Date.now() },
		success: function(response) {
			jawnosAlert(response.html);
		}
	});
}

$(document).on('click', '.clothesline_menu_row', function(e) {
	e.preventDefault();
	var row = $(this);
	var menu = row.closest('.clothesline_menu');
	var app = menu.attr('app');
	var head = menu.attr('head') == '1';
	var command = row.attr('command');
	menu.remove();
	if (command == 'edit') {
		clotheslineEdit(app);
	}
	else if (command == 'remove') {
		clotheslineSet(app, 'hidden', 1);
	}
	else if (command == 'bump') {
		clotheslineSet(app, 'anticipatory', head ? 'exclude' : 'include');
	}
	else if (command == 'settings') {
		clotheslineSettings();
	}
});

// The anticipatory settings: three switches and this week's days, each with the
// pills that populate it. A day the person changes keeps its own list; a reset
// returns it to the learned routine.
function clotheslineSettings() {
	$.ajax({
		url: '/manager/clothesline/settings',
		type: 'GET',
		data: { timestamp: Date.now() },
		success: function(response) {
			jawnosAlert(response.html);
		}
	});
}

function clotheslineDayItem(app, name) {
	var li = $('<li class="clothes_day_item"></li>').attr('app', app);
	$('<span></span>').text(name).appendTo(li);
	$('<button type="button" class="clothes_day_drop"></button>')
		.attr('title', jawnosT('Drop')).text('\u00d7').appendTo(li);
	return li;
}

// A pill added by hand belongs to no wave the routine knows, so it goes in the
// day's own last section, which the card grows only when it needs one.
function clotheslineDayMoreSection(card) {
	var phases = card.find('.clothes_day_phases');
	var more = phases.find('.clothes_day_phase[phase="more"]');
	if (!more.length) {
		more = $('<div class="clothes_day_phase" phase="more"></div>')
			.append($('<h5></h5>').text(jawnosT('Added')))
			.append('<ul class="clothes_day_items"></ul>')
			.appendTo(phases);
	}
	return more.find('.clothes_day_items');
}

// The find box narrows the whole app list to what the letters match, in the
// printed name or the app's own, and leaves out the pills the day already has.
function clotheslineFindMatches(card, text) {
	var list = card.find('.clothes_day_find_list').empty();
	var needle = $.trim(text || '').toLowerCase();
	if (needle.length < 2) { list.hide(); return; }
	var have = {};
	card.find('.clothes_day_phases .clothes_day_item').each(function() {
		have[$(this).attr('app')] = 1;
	});
	var shown = 0;
	$('#clothes_apps option').each(function() {
		var o = $(this);
		var app = o.val();
		if (!app || have[app]) { return true; }
		if (o.text().toLowerCase().indexOf(needle) < 0 && app.toLowerCase().indexOf(needle) < 0) { return true; }
		$('<li class="clothes_day_find_match"></li>').attr('app', app)
			.attr('name', o.text()).text(o.text()).appendTo(list);
		shown++;
		return shown < 12;
	});
	if (shown) { list.show(); } else { list.hide(); }
}

$(document).on('input', '.clothes_day_find', function() {
	clotheslineFindMatches($(this).closest('.clothes_day_card'), this.value);
});

$(document).on('keydown', '.clothes_day_find', function(e) {
	var card = $(this).closest('.clothes_day_card');
	if (e.key == 'Escape') {
		$(this).val('');
		card.find('.clothes_day_find_list').empty().hide();
	}
	else if (e.key == 'Enter') {
		e.preventDefault();
		card.find('.clothes_day_find_match').first().click();
	}
});

// Where a new pill goes: the routine the picker names. A day with no pills at
// all still has the last section to grow.
function clotheslineDaySection(card, key) {
	var phases = card.find('.clothes_day_phases');
	var found = key ? phases.find('.clothes_day_phase[phase="' + key + '"]') : $();
	if (found.length) { return found.find('.clothes_day_items').first(); }
	if (key == 'more') { return clotheslineDayMoreSection(card); }
	var last = phases.find('.clothes_day_phase').last();
	if (last.length) { return last.find('.clothes_day_items').first(); }
	return clotheslineDayMoreSection(card);
}

$(document).on('click', '.clothes_day_find_match', function(e) {
	e.preventDefault();
	var row = $(this);
	var card = row.closest('.clothes_day_card');
	clotheslineDaySection(card, card.find('.clothes_day_section').val())
		.append(clotheslineDayItem(row.attr('app'), row.attr('name')));
	card.attr('data-touched', '1').removeAttr('data-reset');
	card.find('.clothes_day_find').val('');
	card.find('.clothes_day_find_list').empty().hide();
});

$(document).on('click', '.clothes_day_drop', function() {
	var card = $(this).closest('.clothes_day_card');
	$(this).closest('.clothes_day_item').remove();
	card.attr('data-touched', '1').removeAttr('data-reset');
});

// Reset puts the day back to the routine the line learned, routines and all:
// the card carries that markup hidden, so the sections keep their own names.
$(document).on('click', '.clothes_day_reset', function() {
	var card = $(this).closest('.clothes_day_card');
	var learned = card.find('.clothes_day_learned').html();
	if (typeof learned == 'string') { card.find('.clothes_day_phases').html(learned); }
	card.find('.clothes_day_find_list').empty().hide();
	card.attr('data-touched', '1').attr('data-reset', '1');
});

$(document).on('click', '.clothes_settings_close', function() {
	if (typeof jawnosAlertClose == 'function') { jawnosAlertClose(); }
});

$(document).on('click', '#clothes_settings_save', function() {
	var btn = $(this);
	var days = {};
	$('.clothes_day_card').each(function() {
		var card = $(this);
		if (card.attr('data-touched') != '1') { return; }
		var date = card.attr('date');
		if (card.attr('data-reset') == '1') { days[date] = null; return; }
		// the pills in the order the day shows them, each with the routine it was
		// put in, so the section survives the save
		var apps = [];
		var sections = {};
		card.find('.clothes_day_phases .clothes_day_phase').each(function() {
			var phase = $(this).attr('phase');
			$(this).find('.clothes_day_item').each(function() {
				var app = $(this).attr('app');
				if (!app) { return; }
				apps.push(app);
				sections[app] = phase;
			});
		});
		days[date] = { apps: apps, sections: sections };
	});
	var payload = {
		on: $('#clothes_anticipatory_on').is(':checked') ? 1 : 0,
		next_wave: $('#clothes_anticipatory_next').is(':checked') ? 1 : 0,
		on_reset: $('#clothes_anticipatory_reset').is(':checked') ? 1 : 0,
		days: days
	};
	btn.prop('disabled', true);
	$.ajax({
		url: '/manager/clothesline/settings',
		type: 'POST',
		data: { value: JSON.stringify(payload), timestamp: Date.now() },
		success: function() {
			if (typeof jawnosAlertClose == 'function') { jawnosAlertClose(); }
			clotheslineRefresh();
		},
		complete: function() { btn.prop('disabled', false); }
	});
});

$(document).on('click', function(e) {
	if (!$(e.target).closest('.clothes_day_find_box').length) {
		$('.clothes_day_find_list').empty().hide();
	}
});
$(document).on('click', function() { $('.clothesline_menu').remove(); });
$(document).on('contextmenu', function(e) {
	// the right-press that opens the menu is the same event: only a press away
	// from the rail puts it away
	if (!$(e.target).closest('.background').length) { $('.clothesline_menu').remove(); }
});

function clotheslineSet(app, setting, value) {
	$.ajax({
		url: '/manager/clothesline',
		type: 'POST',
		data: { app: app, setting: setting, value: value, timestamp: Date.now() },
		success: function() { clotheslineRefresh(); }
	});
}

function clotheslineRefresh() {
	$.ajax({
		url: '/manager/clothesline_rail',
		type: 'GET',
		data: { timestamp: Date.now() },
		success: function(response) {
			if (!response || typeof response != 'object') { return; }
			// the reply's day flow feeds the rail's painted band before the hang,
			// so one draw carries both; an older server sends neither and the
			// rail hangs exactly as it did
			if (typeof clotheslineFlowSet == 'function') { clotheslineFlowSet(response['flow_spans'], response['flow_day']); }
			if (response['clothesline']) { clotheslineHanger(response['clothesline']); }
		}
	});
}

// ---- the phrase box: the schedule reader fills it in ------------------------
// The words go to the house's own reader; only a clause it cannot know falls
// back to the Guide. The answer is the cards and the day summary, and the rail
// is refreshed so a newly matching pill appears at once.
function clotheslineScheduleRead(input) {
	var app = input.attr('app');
	var text = $.trim(input.val() || '');
	if (input.attr('data-sent') === text) { return; }
	input.attr('data-sent', text);
	var status = $('.clothes_schedule_status');
	status.removeClass('clothes_schedule_ok').text(jawnosT('Reading the schedule…'));
	$.ajax({
		url: '/manager/clothesline/schedule',
		type: 'POST',
		data: { app: app, text: text, timestamp: Date.now() },
		success: function(response) {
			response = response || {};
			if (response['ask']) {
				status.removeClass('clothes_schedule_ok').text(response['ask']);
			}
			else if (response['message'] !== undefined) {
				status.addClass('clothes_schedule_ok').text(response['message']);
			}
			else {
				status.text(jawnosT('The schedule could not be read.'));
			}
			if (response['cards'] !== undefined) { $('.clothes_schedule_cards').html(response['cards']); }
			if (response['text'] !== undefined) { input.val(response['text']); input.attr('data-sent', response['text']); }
			if (response['ok']) { clotheslineRefresh(); }
		},
		error: function() {
			status.removeClass('clothes_schedule_ok').text(jawnosT('The schedule could not be read.'));
		}
	});
}

$(document).on('keydown', '.clothes_schedule', function(e) {
	if (e.key != 'Enter') { return; }
	e.preventDefault();
	clotheslineScheduleRead($(this));
});

$(document).on('change', '.clothes_schedule', function() {
	clotheslineScheduleRead($(this));
});

// one card's Forget: drop that schedule and redraw the cards in place
$(document).on('click', '.clothes_schedule_forget', function(e) {
	e.preventDefault();
	var app = $(this).attr('app');
	var index = $(this).attr('index');
	$.ajax({
		url: '/manager/clothesline/schedule',
		type: 'POST',
		data: { app: app, forget: 1, index: index, timestamp: Date.now() },
		success: function(response) {
			response = response || {};
			if (response['cards'] !== undefined) { $('.clothes_schedule_cards').html(response['cards']); }
			if (response['text'] !== undefined) {
				$('.clothes_schedule').val(response['text']).attr('data-sent', response['text']);
			}
			$('.clothes_schedule_status').addClass('clothes_schedule_ok').text(response['message'] || '');
			clotheslineRefresh();
		}
	});
});

$(document).on('change', '.clothes_hidden', function() {
	clotheslineSet($(this).attr('app'), 'hidden', $(this).is(':checked') ? 1 : 0);
});