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
	var app = s.closest('.appointment').attr('app');
	settingSetter({ 'app': app, 'setting': 's_scope_count', 'value': val });
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
	$.ajax({
		url: '/manager/inventory/details',
		type: 'GET',
		data: { timestamp: timestamp, app: app, scope_count: sscv, calc: sc, lock: sdl, display: sdv, visual: sv, movement: jsmv, s_scroll: s_scroll },
		success: function(response) {
			if (iq.is(':visible')) {
				var new_s_scroll = iq.find('.statistic_graphs').scrollTop();

				iq.html(response.content);

				appointment_chron();
				ir.find('.statistic_scope_count').val(sscv || response.settings.s_scope_count);
				ir.find('.statistic_display').val(sdv || response.settings.s_display);
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

				appointment_chron();
				inventoryStatus.loading = false;
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
		// draw at the size the canvas is shown at, at the device's own resolution:
		// the backing store used to stay at the default 300x150 and the browser
		// stretched it to the stylesheet's 250px, which softened the line and the
		// text without changing any of the coordinates
		var thick = window.devicePixelRatio || 1;
		var wide = wind.width();
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
		if (data.highest[tl]) {
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