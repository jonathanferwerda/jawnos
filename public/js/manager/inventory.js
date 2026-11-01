/* [[js-split]]
   inventory.js is part 1. The rest live in inventory/ in name order:
     01_charts_evaluation.js - statistic pie - entries - evaluation station and report - graph hover
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var inventoryStatus = {
	loading: false
};


$(document).on('change', '.statistic_display', function() {
	var s = $(this);
	var app = s.closest('.appointment').attr('app');
	var val = s.val();
	// a measure carries its own calc (steps sum, weight average): apply it to the
	// calc select before the load, so the reading and the select agree
	var calc = s.closest('.appointment').find('.statistic_calc');
	var measures = {};
	try { measures = JSON.parse(calc.attr('data-measure_calc') || '{}'); } catch (e) {}
	if (measures[val] !== undefined) { calc.val(measures[val]); }
	settingSetter({ 'app': app, 'setting': 's_display', 'value': val });
	inventoryDetails(app);
});

$(document).on('change', '.statistic_calc', function() {
	var s = $(this);
	var app = s.closest('.appointment').attr('app');
	var val = s.val();
	// A measure remembers its own reading - steps is summed, weight averaged -
	// so changing the calc while a measure is shown records it for that measure
	// rather than moving the app's one setting. A base reading still sets s_calc.
	var measures = {};
	try { measures = JSON.parse(s.attr('data-measure_calc') || '{}'); } catch (e) {}
	var display = s.closest('.appointment').find('.statistic_display').val();
	if (display && measures[display] !== undefined) {
		settingSetter({ 'app': app, 'setting': 'measure_calc', 'subsetting': display, 'value': val });
	}
	else {
		settingSetter({ 'app': app, 'setting': 's_calc', 'value': val });
	}
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
	// one trend at a time, its unit chosen, rather than a strip of canvases in
	// their own sideways scroll the pointer kept snagging on
	var units = canvasId ? data.time_lengths : [statisticUnit(data)];
	$.each(units, function(u, tl) {
		var itl = $.inArray(tl, data.time_lengths);
		var time_widths = data.scopes.length;
		if (data.time_widths.length > 0 && itl >= 0) {
			time_widths = data.time_widths[itl] + 2;
		}
		var id = canvasId || data.app + '_line_graph';
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
		var wide = $(g).width() || wind.width();
		var tall = numeral($(g).css('height')).value() || 250;
		$(g).attr({ width: Math.round(wide * thick), height: Math.round(tall * thick) });
		ctx = g.getContext('2d');
		ctx.setTransform(thick, 0, 0, thick, 0, 0);
		ctx.clearRect(0, 0, wide, tall);
		ctx.beginPath();
		ctx.fillStyle = data.settings.colour || 'black';
		ctx.strokeStyle = 'black';
		ctx.globalAlpha = 1;	
		// heavier and rounder, with a hint of shadow, so the line reads cleanly
		ctx.font = "600 11px system-ui, Arial";
		ctx.lineWidth = 2.5;
		ctx.lineJoin = 'round';
		ctx.lineCap = 'round';
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
							// time reads left to right: the period list runs future -> past, so
							// the oldest is placed at the left edge and the newest at the right
							var x = wide * ((data.scopes.length - 1 - n) / time_widths);
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
							// a white halo behind the reading and the date, so the text stands
							// off the line however the data crowds it
							ctx.font = "600 11px system-ui, Arial";
							ctx.lineWidth = 3;
							ctx.strokeStyle = 'rgba(255,255,255,.85)';
							ctx.strokeText(text, text_x, y - 5);
							ctx.fillStyle = '#1b1b1b';
							ctx.fillText(text, text_x, y - 5);
							ctx.save('a');
							ctx.strokeStyle = 'black';
							ctx.font = "600 10px system-ui, Arial";
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
								ctx.lineWidth = 3;
								ctx.strokeStyle = 'rgba(255,255,255,.85)';
								ctx.strokeText(under, x - 5, tall - 3);
								ctx.fillStyle = '#333';
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
	if (!canvasId) {
		statisticData[data.app] = data;
		statisticRedrawCharts(data.app);
		// the fresh controls wear the choices already made
		var wind = $('.wind[app="' + data.app + '"]');
		wind.find('.statistic_chart_unit').val(statisticUnit(data));
		wind.find('.statistic_pie_by').val(statistic_pie_by);
	}
}

// the last response per app, so the chart controls can redraw without a reload
var statisticData = {};
var statistic_chart_unit = localStorage.getItem('inventory_chart_unit') || '';
var statistic_pie_by = localStorage.getItem('inventory_pie_by') || 'period';

// the unit the trend and the bars read in: the chosen one, else the unit the page
// was walked in, else days
function statisticUnit(data) {
	if (statistic_chart_unit && $.inArray(statistic_chart_unit, data.time_lengths) >= 0) { return statistic_chart_unit; }
	if (data.page_scope && $.inArray(data.page_scope, data.time_lengths) >= 0) { return data.page_scope; }
	return ($.inArray('day', data.time_lengths) >= 0) ? 'day' : data.time_lengths[0];
}
function statisticRedrawCharts(app) {
	var data = statisticData[app];
	if (!data) { return; }
	// the trend is redrawn by the graph pass; the bar and pie read the same data
	statisticBars(data, statisticUnit(data));
	statisticPie(data, statisticUnit(data), statistic_pie_by);
}
$(document).on('change', '.statistic_chart_unit', function() {
	statistic_chart_unit = $(this).val() || '';
	localStorage.setItem('inventory_chart_unit', statistic_chart_unit);
	var ir = $(this).closest('.appointment');
	ir.find('.statistic_graph').attr('scope', statistic_chart_unit);
	var app = ir.attr('app');
	if (statisticData[app]) {
		statisticGrapher(statisticData[app]);
	}
});
$(document).on('change', '.statistic_pie_by', function() {
	statistic_pie_by = $(this).val() || 'period';
	localStorage.setItem('inventory_pie_by', statistic_pie_by);
	statisticRedrawCharts($(this).closest('.appointment').attr('app'));
});

// the per-period values for one column, oldest first, so a bar or a slice reads
// the way the line now does
function statisticSeries(data, unit) {
	var display = data.settings.s_display;
	var scopes = (data.scopes || []).filter(function(ts) { return ts != 'average' && ts != 'total'; });
	scopes.reverse();
	var out = [];
	scopes.forEach(function(ts) {
		var cell = data[ts] && data[ts][unit];
		if (!cell || typeof cell != 'object') { return; }
		var v = numeral(cell[display]).value();
		if (v === null || isNaN(v)) { return; }
		out.push({ ts: ts, value: v, budget: cell.budget });
	});
	return out;
}

function statisticBars(data, unit) {
	var g = document.getElementById(data.app + '_bars_graph');
	if (!g || !g.getContext) { return; }
	var thick = window.devicePixelRatio || 1;
	var wide = $(g).width() || 600;
	var tall = numeral($(g).css('height')).value() || 160;
	$(g).attr({ width: Math.round(wide * thick), height: Math.round(tall * thick) });
	var ctx = g.getContext('2d');
	ctx.setTransform(thick, 0, 0, thick, 0, 0);
	ctx.clearRect(0, 0, wide, tall);
	var series = statisticSeries(data, unit);
	if (!series.length) { return; }
	var max = 0;
	series.forEach(function(p) { if (p.value > max) { max = p.value; } });
	max = max || 1;
	var base = tall - 14;
	var bw = wide / series.length;
	ctx.font = '400 10px Arial';
	series.forEach(function(p, i) {
		var h = base * (p.value / max);
		var x = i * bw + 1;
		ctx.fillStyle = (p.budget && p.budget.colour) ? p.budget.colour : (data.settings.colour || '#4a90d9');
		ctx.fillRect(x, base - h, Math.max(1, bw - 2), h);
	});
	ctx.strokeStyle = 'rgba(0,0,0,.45)';
	ctx.beginPath(); ctx.moveTo(0, base); ctx.lineTo(wide, base); ctx.stroke();
}

