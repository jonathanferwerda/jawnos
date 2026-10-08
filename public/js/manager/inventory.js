var inventoryStatus = {
	loading: false
};


$(document).on('change', '.statistic_display', function() {
	var s = $(this);
	var app = s.closest('.appointment').attr('app');
	var val = s.val();
	settingSetter({ 'app': app, 'setting': 's_display', 'value': val });
	inventoryDetails(app);
});

$(document).on('change', '.statistic_calc', function() {
	var s = $(this);
	var app = s.closest('.appointment').attr('app');
	var val = s.val();
	settingSetter({ 'app': app, 'setting': 's_calc', 'value': val });
	inventoryDetails(app);
});

$(document).on('click', '.statistic_lock', function() {
	var s = $(this);
	var app = s.attr('app');
	var lock = s.attr('locked');
	if (lock == 'on') {
		lock = 'off';
		s.removeClass('selected');
	}
	else {
		lock = 'on';
		s.addClass('selected');
	}
	s.attr('locked', lock);


	if (app == 'budget') {
		budgetInit({ new_settings: { 's_lock': lock } });
	}
	else {
		settingSetter({ 'app': app, 'setting': 's_lock', 'value': lock });
		inventoryDetails(app);
	}
});

$(document).on('change', '.statistic_visual', function() {
	var s = $(this);
	var app = s.closest('.appointment').attr('app');
	var val = s.val();
	settingSetter({ 'app': app, 'setting': 's_visual', 'value': val });
	inventoryDetails(app);
});

$(document).on('change','.statistic_scope_count', function() {
	var s = $(this);
	var val = s.val();
	var ir = s.closest('.appointment');
	var app = ir.attr('app');
	settingSetter({ 'app': app, 'setting': 's_scope_count', 'value': val });
	// a page is a page of these periods, so ask for the first one again
	settingSetter({ 'app': app, 'setting': 's_scope_page', 'value': 0 });
	ir.attr('scope_page', 0);
	inventoryDetails(app);
});

$(document).on('change','.statistic_movement', function() {
	var s = $(this);
	var app = s.closest('.appointment').attr('app');
	var sval = s.val();
	var val = JSON.stringify(sval);
	settingSetter({ 'app': app, 'setting': 's_movement', 'value': val });
	inventoryDetails(app);
});

function inventoryDetails(app) {
	var ir = $('.appointment[app="' + app + '"]');
	var iq = ir.find('.inventory_details');
	if (!iq.is(':visible')) {
		iq.html('<h1>Loading</h1>');
	}
	if (inventoryStatus.loading == true) {
	//	return;
	}
	inventoryStatus.loading = true;

	var sscv = ir.find('.statistic_scope_count').val();
	var sm = ir.find('.statistic_movement');
	var sdv = ir.find('.statistic_display').val();
	var sv = ir.find('.statistic_visual').val();
	var sc = ir.find('.statistic_calc').val();
	var sdl = ir.find('.statistic_lock').attr('locked');
	var smv = sm.val();
	var jsmv = JSON.stringify(smv);
	var smsT = sm.scrollTop();
	var s_scroll = iq.find('.statistic_graphs').scrollTop();
	var s_scroll_left = iq.find('.statistic_graphs').scrollLeft();
	$.ajax({
		url: '/manager/inventory/details',
		type: 'GET',
		data: { timestamp: timestamp, app: app, scope_count: sscv, calc: sc, lock: sdl, display: sdv, visual: sv, movement: jsmv, s_scroll: s_scroll, page_scope: ir.attr('page_scope') },
		success: function(response) {
			// the request is done the moment the answer lands: clearing the flag here
			// keeps a draw that throws from leaving every page control silently deaf,
			// which is how a page with no data used to wedge the button and the swipes
			inventoryStatus.loading = false;
			if (iq.is(':visible')) {
				var new_s_scroll = iq.find('.statistic_graphs').scrollTop();

				iq.html(response.content);

				appointment_chron();
				scrollerFinder(iq);
				ir.find('.statistic_scope_count').val(sscv || response.settings.s_scope_count);
				ir.find('.statistic_display').val(sdv || response.settings.s_display);
				ir.attr('scope_page', response.scope_page || 0);
				ir.attr('scope_page_max', response.scope_page_max || 24);
				ir.find('.statistic_lock').attr('locked', response.settings.s_lock);
				if (response.settings.s_lock == 'on') {
					ir.find('.statistic_lock').addClass('selected');
				}
				else {
					ir.find('.statistic_lock').removeClass('selected');
				}
				ir.find('.statistic_movement').scrollTop(smsT);
				ir.find('.statistic_movement').val(smv || response.settings.s_movement);
				ir.find('.statistic_calc').val(sc || response.settings.s_calc);
				statisticGrapher(response);
				if (new_s_scroll != 0 && new_s_scroll != response.settings.s_scroll) {
					new_s_scroll = response.settings.s_scroll;
				}
				iq.find('.statistic_graphs').scrollTop(new_s_scroll);
				iq.find('.statistic_graphs').scrollLeft(s_scroll_left);

				appointment_chron();
			}
		}
	});
}

function inventoryDetailsUpdater() {
	$('.inventory_details').each(function(i,v) {
		var id = $(v);
		if (id.is(':visible')) {
			var app = id.closest('.appointment').attr('app');
			inventoryDetails(app);
		}
	});
}

// Sideways scrolling over a graph walks the rows along the timeline, one page
// of periods per gesture, which is how the history past the scope count is
// reached.  A trackpad sends sideways deltas of its own, a wheel mouse has
// none so it holds ctrl, and a finger swipes the graph.  The canvases are
// redrawn inside the details content, so the listeners are put back after
// every render.
var statistic_page_delta = 0;

function scrollerFinder(container) {
	container.find('.statistic_graph').each(function() {
		if (this.statistic_scroller) { return; }
		this.statistic_scroller = 1;
		this.addEventListener('wheel', statisticPageWheel, { passive: false });
		this.addEventListener('touchstart', statisticPageTouchStart, { passive: true });
		this.addEventListener('touchmove', statisticPageTouchMove, { passive: true });
	});
}

function statisticPageWheel(e) {
	var delta = e.deltaX || (e.shiftKey ? e.deltaY : 0);
	if (e.ctrlKey && !delta) {
		// a wheel mouse has no sideways motion, so ctrl and the wheel walk the
		// periods.  A trackpad pinch also sets ctrl, but its deltas are small
		// and fractional, so those stay with the browser's zoom
		if (e.deltaMode == 0 && Math.abs(e.deltaY) < 12) { return; }
		delta = e.deltaY;
	}
	if (!delta) { return; }
	var ir = $(this).closest('.appointment');
	if (ir.find('.statistic_visual').val() != 'historical') { return; }
	e.preventDefault();
	if (inventoryStatus.loading) { statistic_page_delta = 0; return; }
	statistic_page_delta = statistic_page_delta + delta;
	if (Math.abs(statistic_page_delta) < 60) { return; }
	// the older periods sit to the right, so scrolling that way walks back
	var step = statistic_page_delta > 0 ? 1 : -1;
	statistic_page_delta = 0;
	statisticPageStep(ir, step, $(this).attr('scope'));
}

function statisticPageTouchStart(e) {
	if (e.touches.length != 1) { this.statistic_touch = null; return; }
	var touch = e.touches[0];
	this.statistic_touch = { x: touch.clientX, y: touch.clientY };
}

function statisticPageTouchMove(e) {
	var start = this.statistic_touch;
	if (!start || e.touches.length != 1) { this.statistic_touch = null; return; }
	var touch = e.touches[0];
	var x = touch.clientX - start.x;
	var y = touch.clientY - start.y;
	if (Math.abs(x) < 50 || Math.abs(x) < Math.abs(y)) { return; }
	// one page per swipe: the start is cleared so the rest of the drag is quiet
	this.statistic_touch = null;
	var ir = $(this).closest('.appointment');
	if (ir.find('.statistic_visual').val() != 'historical') { return; }
	// dragging the graph to the left brings the older periods in from the right
	statisticPageStep(ir, x < 0 ? 1 : -1, $(this).attr('scope'));
}

// one page of periods along the timeline, clamped to what the scope allows;
// the canvas the gesture landed on names the unit the button speaks in
function statisticPageStep(ir, step, scope) {
	if (inventoryStatus.loading) { return; }
	var page = numeral(ir.attr('scope_page')).value() || 0;
	var max = numeral(ir.attr('scope_page_max')).value() || 24;
	var next = page + step;
	if (next > max) { next = max; }
	if (next < -max) { next = -max; }
	if (next == page) { return; }
	var app = ir.attr('app');
	ir.attr('scope_page', next);
	var writes = [ settingSetter({ 'app': app, 'setting': 's_scope_page', 'value': next }) ];
	if (scope) {
		ir.attr('page_scope', scope);
		// kept so a reload after the walk still says which unit the page is in
		writes.push(settingSetter({ 'app': app, 'setting': 's_page_scope', 'value': scope }));
	}
	// the page is only persisted by the setters and the render reads it back out
	// of the settings, so the fetch waits for the writes: fired together, the
	// render could return the page the walk just left and put the button back
	Promise.all(writes).then(function() {
		inventoryDetails(app);
	});
}

// the page button is the way back to now, however far a scroll or a swipe has
// walked: stepping back by the page it is showing lands on zero
$(document).on('click', '.statistic_page', function() {
	var ir = $(this).closest('.appointment');
	statisticPageStep(ir, -(numeral(ir.attr('scope_page')).value() || 0));
});
var ctx;
// a compact date for a window's own start, which is what the historical
// charts label their points with: the row names (3la, nex) say nothing about
// when the window is
function chartDate(date, scope) {
	var pad = function(value) { return (value < 10 ? '0' : '') + value; };
	var day = (date.getMonth() + 1) + '/' + date.getDate();
	if (scope == 'minute' || scope == 'hour') {
		return day + ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes());
	}
	if (scope == 'month') {
		return date.getFullYear() + '-' + pad(date.getMonth() + 1);
	}
	if (scope == 'year') {
		return '' + date.getFullYear();
	}
	return day;
}

function statisticGrapher(data,canvasId,mark) {

	var wind = $('.wind[app="' + data.app + '"]');
	var wind_id = wind.attr('id');
	var win = document.getElementById(wind_id);
	$.each(data.time_lengths, function(itl, tl) {
		var time_widths = data.scopes.length;
		if (data.time_widths.length > 0) {
			time_widths = data.time_widths[itl] + 2;
		}
		var id = canvasId || data.app + '_' + tl + '_statistic_graph';
		var g = document.getElementById(id);
		// what the mouse reads back: the points the line runs through, kept in
		// the drawing's own coordinates, and the display they are measured in
		g.statistic_points = [];
		g.statistic_display = data.settings.s_display;
		// draw at the size the canvas is shown at, at the device's own resolution:
		// the backing store used to stay at the default 300x150 and the browser
		// stretched it to the stylesheet's 250px, which softened the line and the
		// text without changing any of the coordinates
		var thick = window.devicePixelRatio || 1;
		// the popup's canvas is a small box inside its own parent, not a graph
		// that spans the window and scrolls sideways, so it is drawn at the size
		// it is shown at - the window's width put it far past its parent's edge
		var wide = canvasId ? $(g).width() : wind.width();
		var tall = numeral($(g).css('height')).value() || 250;
		$(g).attr({ width: Math.round(wide * thick), height: Math.round(tall * thick) });
		ctx = g.getContext('2d');
		ctx.setTransform(thick, 0, 0, thick, 0, 0);
		ctx.clearRect(0, 0, wide, tall);
		ctx.beginPath();
		ctx.fillStyle = data.settings.colour || 'black';
		ctx.strokeStyle = 'black';
		ctx.globalAlpha = 1;	
		ctx.font = "400 10px Arial";
		var threshold;
		// a page whose periods hold nothing carries no highest or lowest at all:
		// there is no axis to draw against, which is an empty chart, not an error
		if (data.highest && data.lowest && data.highest[tl]) {
			var lowest = numeral(data.lowest[tl][data.settings.s_display]).value();
			var highest = numeral(data.highest[tl][data.settings.s_display]).value();

			// the axis runs from a little under the lowest value to a little over
			// the highest, so the lowest number sits near the floor instead of
			// floating wherever zero leaves it
			var spread = (highest - lowest) || Math.abs(highest) || 1;
			var roof = highest + spread * .1;
			var floor = lowest - spread * .1;
			var min = tall - 12;
			var y_for = function(point) {
				return min - (min * ((point - floor) / (roof - floor)));
			};

			var colWidth = wide / time_widths + 1; 
			var label_edge = -100;
			var marks = [];
			$.each(data.scopes, function(n,ts) {
				if (data[ts] && (ts != 'average' && ts != 'total')) {
					if (typeof data[ts][tl] == 'object') {
						if (data[ts][tl][data.settings.s_display]) {
							var point = numeral(data[ts][tl][data.settings.s_display]).value();
							var x = wide * (n / time_widths);
							var y = y_for(point);
							ctx.lineTo(x, y);
							if (mark && numeral(data[ts][tl]['start_timestamp']).value() == mark) {
								marks.push([x, y]);
							}

							var text = data[ts][tl][data.settings.s_display];
							if (data.settings.s_display == 'duration') {
								text = data[ts][tl]['formatted_duration'];
							}
							g.statistic_points.push({
								x: x,
								y: y,
								ts: ts,
								scope: tl,
								text: text,
								start: numeral(data[ts][tl]['start_timestamp']).value(),
								end: numeral(data[ts][tl]['end_timestamp']).value()
							});
							var text_x = (x - ctx.measureText(text).width);
							if (text_x < 0) {
								text_x = x;
							}
							ctx.fillText(text,text_x, y - 4);
							ctx.save('a');
							ctx.fillStyle = 'black';
							ctx.strokeStyle = 'black';

							ctx.font = "400 10px Arial";
							var under = ts;
							if (data.settings.s_visual == 'historical') {
								under = ts.substr(0,3);
								if (data[ts][tl]['start_timestamp']) {
									under = chartDate(new Date(numeral(data[ts][tl]['start_timestamp']).value()), tl);
								}
							}
							// the points are closer together than the labels are wide, so
							// only the labels with room under them are written
							if (label_edge < x - ctx.measureText(under).width / 2) {
								ctx.fillText(under, x - 5, tall - 3);
								label_edge = x + ctx.measureText(under).width / 2 + 4;
							}
							ctx.restore('a');
							if (data[ts][tl]['budget']) {
								threshold = data[ts][tl]['budget']['threshold'];
							}
						}
					}
				}
			});
			ctx.stroke();
			// the window that was clicked, so the popup shows which point it is
			$.each(marks, function(i, spot) {
				ctx.beginPath();
				ctx.strokeStyle = 'red';
				ctx.lineWidth = 2;
				ctx.arc(spot[0], spot[1], 4, 0, Math.PI * 2);
				ctx.stroke();
			});
			ctx.beginPath();
			ctx.save('b');
				

			if (data.autocalc && data['budget_status'][tl]) {
				ctx.fillStyle = 'blue';
				ctx.strokeStyle = data['budget_status'][tl][data.settings.s_display]['colour'] || 'blue';
				ctx.lineWidth = 4;
				ctx.moveTo(0, y_for(data.autocalc[tl]['result']));
				ctx.lineTo(wide, y_for(data.autocalc[tl]['result']));
				ctx.stroke();
			}

			ctx.beginPath();
			ctx.lineWidth = 2;
			ctx.strokeStyle = 'black';
			ctx.moveTo(0, y_for(threshold));
			ctx.lineTo(wide, y_for(threshold));
			ctx.stroke();
			ctx.restore('b');
			ctx.beginPath();
		//	ctx.fill();
		}
		else {
			//$('#' + id + '_span').remove();
		}
	});
}

$(document).on('click', '.statistic_entry', function() {
	var s = $(this);
	var ir = s.closest('.appointment');
	var app = ir.attr('app');
	var timestamp = s.attr('timestamp');
	var scope = s.attr('scope');
	var zone = s.attr('zone');
	var mouse = mouse_position();
	var start_timestamp = s.attr('start_timestamp');
	var end_timestamp = s.attr('end_timestamp');
	$.ajax({
		url: '/manager/inventory/information',
		type: 'GET',
		data: { 
			app: app, 
			timestamp: s.attr('inventory_timestamp') || timestamp, 
			scope: scope,
			zone: zone,
			x: mouse['x'], 
			y: mouse['y'],
			start_timestamp: start_timestamp,
			end_timestamp: end_timestamp,
		},
		success: function(response) {
			var id = $(response.html).attr('id');
			$('.statistic_information_container[app="' + app + '"]').append(response.html);
			var info = $('#' + id);
			if ((numeral(info.css('left')).value() + info.width()) > $(window).width()) {
				var new_left = ($(window).width() - info.width() - 5);
				info.css({'left': new_left + 'px'});
			}
			else if (numeral(info.css('left')).value() < 0) {
				info.css({'left': '5px'});
			}
			if ((numeral(info.css('top')).value() + info.height()) > $(window).height()) {
				var new_top = ($(window).height() - info.height() - 5);
				info.css({'top': new_top + 'px' });
			}
			statisticGrapher(response.details,id + '_canvas', numeral(start_timestamp).value());
			appointment_chron();
		}
	});
});

$(document).on('click', '.close_statistic_info', function() {
	$(this).closest('.statistic_info').remove();
});

$(document).on('click', '.statistic_appointments', function() {
	var s = $(this);
	var ir = s.closest('.appointment');
	var app = ir.attr('app');
	var timestamp = s.attr('timestamp');
	var scope = s.attr('scope');
	var container = ir.find('.re_details');
	var sscv = ir.find('.statistic_scope_count').val();
	var sm = ir.find('.statistic_movement');
	var sdv = ir.find('.statistic_display').val();
	var sdl = ir.find('.statistic_lock').attr('locked');
	var smv = sm.val();
	var jsmv = JSON.stringify(smv);
	var sorts = localStorage.getItem('sorts');
	var variables = { app: app, filter: 'all', sorts: sorts, timeshift: '0d', time_machine: '', timestamp: timestamp, scope: scope };
	$.ajax({ 
		url: '/manager/appointment_details',
		type: 'GET',
		data: variables,
		success: function(response) {
			container.html(response);
			container.show();
			appointment_chron();
			$('.appointment_contents[app="' + app + '"]').scrollTop(0);
		}
	});
});


$(document).on('click', '.system_evaluation', function() {
	var b = $(this);
	evaluationStation(b);
});

function evaluationStation(b) {
	var timestamp = Date.now();
	var app = b.attr('app');
	var text = b.text();
	b.text('* ' + text);
	clearInterval(configIntervals['sysEvaluateInterval']);
	clearTimeout(configIntervals['sysEvaluateTimeout']);
	configIntervals['sysEvaluateInterval'] = setInterval(function() {
		b.text('* * ' + text + ' * *');
		configIntervals['sysEvaluateTimeout'] = setTimeout(function() {
			b.text('* ' + text + ' *');
		},250);
	},500);
	$.ajax({
		url: '/manager/inventory/evaluate',
		type: 'POST',
		data: { timestamp: timestamp, app: app },
		success: function(response) {
			clearInterval(configIntervals['sysEvaluateInterval']);
			clearTimeout(configIntervals['sysEvaluateTimeout']);
			b.text(text);
		}
	});
}

// The graphs answer the mouse: a floating readout follows the pointer over a
// canvas, naming the row and column it is on, the window's own time (the row
// names alone say nothing about when a window is) and the value drawn there.
$(document).on('mousemove touchmove', '.statistic_graph', function(m) {
	var g = this;
	var points = g.statistic_points;
	if (!points || points.length == 0) { return; }
	var info = $(this).closest('.appointment').find('.statistic_graph_information');
	if (info.length == 0) { return; }
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	if (m.originalEvent.targetTouches) {
		x = m.originalEvent.targetTouches[0].clientX;
		y = m.originalEvent.targetTouches[0].clientY;
	}
	// the mouse is in screen pixels and the points are in the drawing's own
	// coordinates, which the stylesheet may have stretched
	var thick = window.devicePixelRatio || 1;
	var rect = g.getBoundingClientRect();
	var local = (x - rect.left) * ((g.width / thick) / (rect.width || 1));
	var hovering;
	$.each(points, function(i,p) {
		if (hovering == undefined || Math.abs(p.x - local) < Math.abs(hovering.x - local)) {
			hovering = p;
		}
	});
	if (info.attr('point') != hovering.ts + '_' + hovering.scope) {
		var value = hovering.text;
		if (g.statistic_display == 'amount' || g.statistic_display == 'total') {
			value = numeral(value).format('$0.00');
		}
		var html = '<span style="padding:1px;">';
		html += '<div><b>' + format_name(hovering.ts) + '</b> ' + format_name(hovering.scope) + '</div>';
		html += '<div class="time" mode="fixed" timestamp="' + hovering.start + '"></div>';
		if (hovering.end) {
			html += '<div class="time" mode="fixed" timestamp="' + (hovering.end - 1000) + '"></div>';
		}
		html += '<div><b>' + format_name(g.statistic_display) + ':</b> ' + value + '</div>';
		html += '</span>';
		info.html(html).attr('point', hovering.ts + '_' + hovering.scope);
		appointment_chron();
	}
	info.show();
	// beside the pointer, flipped to the other side when the screen runs out
	var gap = 16;
	var left = x + gap;
	var top = y + gap;
	if (left + info.outerWidth() > $(window).width()) { left = x - info.outerWidth() - gap; }
	if (left < 0) { left = 4; }
	if (top + info.outerHeight() > $(window).height()) { top = y - info.outerHeight() - gap; }
	if (top < 0) { top = 4; }
	info.css({ 'left': left + 'px', 'top': top + 'px' });
});

$(document).on('mouseleave touchend touchcancel', '.statistic_graph', function() {
	$(this).closest('.appointment').find('.statistic_graph_information').hide();
});