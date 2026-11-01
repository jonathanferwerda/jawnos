var statistic_hour_labels = ['12a','1a','2a','3a','4a','5a','6a','7a','8a','9a','10a','11a','12p','1p','2p','3p','4p','5p','6p','7p','8p','9p','10p','11p'];
function statisticPie(data, unit, mode) {
	var g = document.getElementById(data.app + '_pie_graph');
	if (!g || !g.getContext) { return; }
	var thick = window.devicePixelRatio || 1;
	var wide = $(g).width() || 300;
	var tall = numeral($(g).css('height')).value() || 200;
	$(g).attr({ width: Math.round(wide * thick), height: Math.round(tall * thick) });
	var ctx = g.getContext('2d');
	ctx.setTransform(thick, 0, 0, thick, 0, 0);
	ctx.clearRect(0, 0, wide, tall);
	var slices = [];
	var fixed = false;
	if (mode == 'hour') {
		var hp = data.hour_profile || [];
		for (var h = 0; h < 24; h++) { slices.push({ ts: statistic_hour_labels[h], value: numeral(hp[h]).value() || 0 }); }
		fixed = true;
	}
	else if (mode == 'weekday') {
		var wp = data.weekday_profile || [];
		var names = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
		for (var d = 0; d < 7; d++) { slices.push({ ts: names[d], value: numeral(wp[d]).value() || 0 }); }
		fixed = true;
	}
	else {
		slices = statisticSeries(data, unit);
	}
	slices = slices.filter(function(p) { return p.value > 0; });
	if (!slices.length) { return; }
	// a period share is gathered to the biggest few so the wheel stays readable;
	// an hour or weekday wheel keeps every slice it has
	if (!fixed) {
		slices.sort(function(a, b) { return b.value - a.value; });
		var top = slices.slice(0, 9);
		var rest = 0;
		for (var i = 9; i < slices.length; i++) { rest += slices[i].value; }
		if (rest > 0) { top.push({ ts: 'other', value: rest }); }
		slices = top;
	}
	var total = 0;
	slices.forEach(function(p) { total += p.value; });
	var palette = ['#4a90d9','#e06666','#93c47d','#f6b26b','#8e7cc3','#76a5af','#c27ba0','#ffd966','#a2c4c9','#b6d7a8','#dd7e6b'];
	var rad = Math.min(tall, wide * .5) / 2 - 6;
	var cx = rad + 8;
	var cy = tall / 2;
	var ang = -Math.PI / 2;
	slices.forEach(function(p, i) {
		var slice = (p.value / total) * Math.PI * 2;
		ctx.beginPath();
		ctx.moveTo(cx, cy);
		ctx.arc(cx, cy, rad, ang, ang + slice);
		ctx.closePath();
		ctx.fillStyle = palette[i % palette.length];
		ctx.fill();
		ctx.strokeStyle = '#fff';
		ctx.lineWidth = 1;
		ctx.stroke();
		ang += slice;
	});
	ctx.font = '400 10px Arial';
	var lx = rad * 2 + 18;
	var ly = 12;
	slices.forEach(function(p, i) {
		if (ly > tall - 2) { return; }
		ctx.fillStyle = palette[i % palette.length];
		ctx.fillRect(lx, ly - 8, 9, 9);
		ctx.fillStyle = 'black';
		ctx.fillText(p.ts + ' ' + Math.round(100 * p.value / total) + '%', lx + 13, ly);
		ly += 13;
	});
}

$(document).on('click', '.statistic_entry', function(e) {
	var s = $(this);
	// the reading in the cell turns on its own click; the rest of the cell is what
	// opens that period's panel
	if ($(e.target).closest('.jawnos_duration').length) { return; }
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
			var $html = $(response.html);
			var id = $html.attr('id');
			$('.statistic_information_container[app="' + app + '"]').append($html);
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
			// the reading of the period arrives separately: the model can be slow, so
			// the panel is drawn first and the summary fills in when it answers
			var summary = $html.find('.statistic_summary');
			$.ajax({
				url: '/manager/inventory/summary',
				type: 'GET',
				data: { app: app, scope: scope, zone: zone, timestamp: (s.attr('inventory_timestamp') || timestamp), start_timestamp: start_timestamp, end_timestamp: end_timestamp },
				success: function(r) {
					summary.text((r && r.summary) ? r.summary : '');
				},
				error: function() { summary.text(''); }
			});
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

// a report is a headline until it is asked to be more: a tap anywhere on the
// report's header frame - the words or the space around them - opens or folds
// the body beneath it, while a tap inside the open body is left to the body's
// own links
$(document).on('click', '.appointment_evaluation', function(e) {
	if ($(e.target).closest('.evaluation_body').length) { return; }
	$(this).find('.evaluation_body').first().toggle();
});

// an app the report named walks to that appointment like any other name
$(document).on('click', '.evaluation_app_link', function() {
	var link = $(this);
	appointmentGrabber(link.attr('app'), Date.now());
});

$(document).on('change', '.evaluation_cadence', function() {
	var pick = $(this);
	pick.prop('disabled', true);
	$.ajax({
		url: '/manager/inventory/evaluate/nightly',
		type: 'POST',
		data: { app: pick.attr('app'), cadence: pick.val() },
		success: function(response) {
			pick.prop('disabled', false);
			// the cadence that now exists is the truth: paint what the server says
			// rather than what was asked for
			if (response['cadence']) { pick.val(response['cadence']); }
		},
		error: function() {
			pick.prop('disabled', false);
		}
	});
});

$(document).on('change', '.nightly_evaluation_days', function() {
	var pick = $(this);
	var app = pick.attr('app');
	var nights = pick.val() || [];
	var all = $('.nightly_evaluation_days_all[app="' + app + '"]').first();
	// which days it runs (for daily and weekly); every day is All, and no day at
	// all stops the schedule rather than quietly falling back to every night
	all.prop('checked', nights.length === 0 || nights.length === 7);
	settingSetter({ app: app, setting: 'nightly_evaluation_days', value: nights.length ? nights.join(',') : 'none' });
});

$(document).on('change', '.nightly_evaluation_days_all', function() {
	var box = $(this);
	var app = box.attr('app');
	var pick = $('.nightly_evaluation_days[app="' + app + '"]').first();
	// All selects every day; clearing it clears the list and stops the schedule
	// until a day is picked
	if (box.is(':checked')) {
		pick.find('option').prop('selected', true);
		settingSetter({ app: app, setting: 'nightly_evaluation_days', value: '0,1,2,3,4,5,6' });
	}
	else {
		pick.find('option').prop('selected', false);
		settingSetter({ app: app, setting: 'nightly_evaluation_days', value: 'none' });
	}
});

$(document).on('change', '.evaluation_machine', function() {
	var pick = $(this);
	// which machine's queue runs the nights; the other machines follow at boot
	settingSetter({ app: pick.attr('app'), setting: 'evaluation_machine', value: pick.val() });
});

$(document).on('change', '.evaluation_depth', function() {
	var pick = $(this);
	// how much the next run writes: brief (a headline line) or full; the nightly
	// run reads the same setting
	settingSetter({ app: pick.attr('app'), setting: 'evaluation_depth', value: pick.val() });
});

function evaluationStation(b) {
	var timestamp = Date.now();
	var app = b.attr('app');
	var period = b.siblings('.evaluation_period').first().val() || '';
	var text = b.text();
	// the controls may sit in the strip, in the app's configuration, or in the
	// system settings - the report is looked for where the button is
	var zone = b.closest('.appointment_evaluation_zone');
	var report = zone.length ? zone.find('.appointment_evaluation').first() : $();
	if (report.length == 0) { report = b.siblings('.appointment_evaluation').first(); }
	if (report.length == 0) { report = b.parent().find('.appointment_evaluation').first(); }
	if (report.length == 0) { report = b.closest('.appointment').find('.appointment_evaluation').first(); }
	// the controls can live inside the report's accordion; a fresh report must
	// keep them, and a body the person already had open stays open
	var controls = report.find('.evaluation_controls_body').first();
	var was_open = report.find('.evaluation_body').first().is(':visible');
	b.text('* ' + text);
	report.text('The evaluator is reading the numbers...');
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
		data: { timestamp: timestamp, app: app, period: period },
		success: function(response) {
			clearInterval(configIntervals['sysEvaluateInterval']);
			clearTimeout(configIntervals['sysEvaluateTimeout']);
			b.text(text);
			evaluationReportFill(report, response['evaluation_report'] || {}, response['pieces'], controls, was_open);
		},
		error: function() {
			clearInterval(configIntervals['sysEvaluateInterval']);
			clearTimeout(configIntervals['sysEvaluateTimeout']);
			b.text(text);
			evaluationReportFill(report, {}, { headline: 'The evaluation request failed.', chunks: [] }, controls, true);
		}
	});
}

// the model's report lands as text, and stays text - nothing in it may be
// taken for markup. The headline goes up, the chunks go behind it, and only
// the names the server matched come back as links.
function evaluationReportFill(container, r, pieces, controls, open) {
	pieces = pieces || {};
	controls = controls || $();
	container.empty();
var head = $('<b>').addClass('evaluation_headline hover').attr('hint', controls.length ? 'Tap to open the report and its controls' : 'Tap to open the whole report').text(pieces['headline'] || 'Evaluation');
var body = $('<div>').addClass('evaluation_body').css({ 'display':'none', 'white-space':'pre-wrap' });
$.each(pieces['chunks'] || [ { text: r['text'] || 'No report came back.' } ], function(i,chunk) {
	if (chunk['app']) {
		body.append($('<span>').addClass('evaluation_app_link hover').attr({ app: chunk['app'], hint: 'Open ' + chunk['text'] }).css('text-decoration', 'underline').text(chunk['text']));
	}
	else {
		body.append(document.createTextNode(chunk['text'] || ''));
	}
});
var linked = r['linked'] || {};
if (r['model'] || linked['construct']) {
	var foot = $('<i>').css('font-size', '80%');
	if (linked['app'] && linked['construct']) {
		foot.append($('<br>')).append(document.createTextNode('related to ')).append($('<span>').addClass('evaluation_app_link hover').attr({ app: linked['app'], hint: 'Open ' + linked['app'] }).css('text-decoration', 'underline').text(format_name(linked['app']))).append(document.createTextNode(' as ' + linked['construct']));
	}
	if (r['model']) {
		foot.append($('<br>')).append($('<span>').text(r['model']));
	}
	body.append(foot);
	}
	// the run/cadence controls travelled with the old report's body; put them
	// back inside the new one so the accordion is still the controls' home
	if (controls.length) { body.append(controls); }
	container.append(head).append(body);
	if (open) { body.show(); }
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