/* [[js-split]]
   budget.js is part 1. The rest live in budget/ in name order:
     01_reconcile_payables.js - display save delete - bank import and reconcile - payables - journal rebuild
     02_runway.js             - the Runway chart and its period detail
   The appointment view's budget light is core (public/js/manager/budget_light.js),
   not part of this lazy chunk: a view opens it without the Budget app.
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */

var budgetConfigTimeout;
var timeStops = [];
$(document).on('click', '#budget, #budget_refresh', function() {
	budgetInit()
});

function budgetInit(data) {
	if (typeof data == 'undefined') { data = {}; }
	var new_settings = data['new_settings'] || {};
	var jnew_settings = JSON.stringify(new_settings);
	var adata = deloreanBringer();
	adata['new_settings'] = jnew_settings;
	// a click on a chart names the window outright, so the press opens the period
	// it pointed at without rewriting the scope the person set
	if (data.display) { adata['display'] = data.display; }
	if (data.period && data.period.start && data.period.end) {
		adata['period_start'] = Math.round(data.period.start);
		adata['period_end'] = Math.round(data.period.end);
	}
	var settingsVisibility = $('#budget_settings').is(':visible');
	$.ajax({
		url: '/manager/budget',
		type: 'GET',
		data: adata,
		success: function(response) {
			windowMaker(response.html);
			var jdata = JSON.stringify(response);
			$('#budget_json_data').text(jdata);
			if (settingsVisibility) {
				$('#budget_settings').show();
			}
			budgetAccountCanvasWriter(response);
			budgetRunwayWriter(response);
		}
	});
}

// ---------------------------------------------------------------------------
// The statement's balance chart
//
// The old chart drew its lines straight onto a 150-pixel buffer stretched to the
// window, in black, with no axis, and never cleared itself, so every redraw ran
// on top of the last one. It is drawn on the theme's own paper now: the ink, the
// grid and the money labels come from the theme, each account keeps its colour,
// and the chart is rebuilt from its data on every pass. A click opens the period
// under the pointer, which the hover was only describing.
// ---------------------------------------------------------------------------

var budgetChartPad = { left: 62, right: 14, top: 14, bottom: 24 };
var budgetChartResponse = null;
var budgetChartHover = -1;

function budgetChartInk() {
	var css = window.getComputedStyle(document.body);
	var read = function(name, fallback) {
		var value = css.getPropertyValue(name);
		return (value && value.trim().length) ? value.trim() : fallback;
	};
	return {
		ink: read('--ink', '#111417'),
		muted: read('--ink-muted', '#61666d'),
		line: read('--line', '#d7d9de'),
		panel: read('--panel', '#ffffff'),
		accent: read('--accent', '#3b7ddd'),
		good: read('--runway-good', '#2f7d4f'),
		bad: read('--runway-bad', '#b3453f')
	};
}

// Size the drawing buffer to the screen's own pixels and hand back a context
// already scaled to CSS pixels, so a line is crisp on a retina panel instead of
// a stretched blur. The canvas must be visible: a hidden element measures zero.
function budgetChartPaper(canvas) {
	var wide = Math.round($(canvas).width());
	var tall = Math.round(numeral($(canvas).css('height')).value());
	if (!wide || !tall) { return null; }
	var thick = window.devicePixelRatio || 1;
	canvas.width = Math.round(wide * thick);
	canvas.height = Math.round(tall * thick);
	var ctx = canvas.getContext('2d');
	ctx.setTransform(thick, 0, 0, thick, 0, 0);
	ctx.clearRect(0, 0, wide, tall);
	return { ctx: ctx, wide: wide, tall: tall };
}

// A short figure for an axis, where cents are noise.
function budgetMoney(value) {
	var v = numeral(value).value() || 0;
	var sign = v < 0 ? '-' : '';
	var abs = Math.abs(v);
	if (abs >= 1000000) { return sign + '$' + (abs / 1000000).toFixed(abs >= 10000000 ? 0 : 1) + 'M'; }
	if (abs >= 1000) { return sign + '$' + (abs / 1000).toFixed(abs >= 10000 ? 0 : 1) + 'k'; }
	// below ten dollars the cents are the reading, not noise
	if (abs > 0 && abs < 10) { return sign + '$' + abs.toFixed(2); }
	return sign + '$' + Math.round(abs);
}

function budgetMoneyFull(value) {
	return numeral(value || 0).format('$0.00');
}

// A handful of round steps between the low and the high, so an axis reads
// $0 / $500 / $1,000 rather than whatever two extremes happened to be.
function budgetTicks(low, high, want) {
	var range = high - low;
	if (!(range > 0)) { return [low]; }
	var rough = range / Math.max(2, want || 4);
	var power = Math.pow(10, Math.floor(Math.log(rough) / Math.LN10));
	var step = power;
	$.each([1, 2, 2.5, 5, 10], function(i, multiple) {
		if (power * multiple >= rough) { step = power * multiple; return false; }
	});
	var ticks = [];
	for (var v = Math.ceil(low / step) * step; v <= high + step * 0.0001; v += step) {
		ticks.push(v);
	}
	return ticks.length ? ticks : [low, high];
}

function budgetChartLabel(timestamp, span) {
	var d = new Date(numeral(timestamp).value());
	if (!(d.getTime())) { return ''; }
	if (span > 0 && span < 2 * 86400000) {
		return d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
	}
	if (span > 0 && span < 400 * 86400000) {
		return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
	}
	return d.toLocaleDateString(undefined, { month: 'short', year: 'numeric' });
}

// The pointer in the canvas's own pixels, and on the screen for a fixed tip.
function budgetChartPointer(canvas, event) {
	var box = canvas.getBoundingClientRect();
	var original = event.originalEvent || event;
	var touch = (original.targetTouches && original.targetTouches.length) ? original.targetTouches[0] : original;
	return {
		x: touch.clientX - box.left,
		y: touch.clientY - box.top,
		clientX: touch.clientX,
		clientY: touch.clientY
	};
}

// Which bucket the pointer is over, for a chart whose stops share one width.
function budgetChartIndex(canvas, event, count) {
	var point = budgetChartPointer(canvas, event);
	var plot = Math.max(10, Math.round($(canvas).width()) - budgetChartPad.left - budgetChartPad.right);
	var index = Math.floor(((point.x - budgetChartPad.left) / plot) * count);
	if (index < 0) { index = 0; }
	if (index >= count) { index = count - 1; }
	return { index: index, point: point };
}

// Keep a tip inside the window, on whichever side of the pointer has room.
function budgetTipShow(selector, html, point) {
	var tip = $(selector);
	tip.html(html).show();
	var wide = tip.outerWidth();
	var tall = tip.outerHeight();
	var left = point.clientX + 16;
	var top = point.clientY + 12;
	if (left + wide > $(window).width() - 8) { left = point.clientX - wide - 16; }
	if (top + tall > $(window).height() - 8) { top = $(window).height() - tall - 8; }
	if (left < 8) { left = 8; }
	if (top < 8) { top = 8; }
	tip.css({ left: left, top: top });
}

function budgetAccountCanvasWriter(response) {
	if (!response || !response.accounts) { return; }
	var g = document.getElementById('budget_account_canvas');
	if (!g || !g.getContext) { return; }
	budgetChartResponse = response;

	var increments = Math.round(numeral($('.budget_config[config="increments"]').val()).value() || 30);
	if (!(increments > 0)) { increments = 30; }
	var start = numeral(response.start).value() || 0;
	var end = numeral(response.end).value() || 0;
	var allotment = (end - start) / increments;
	if (!(allotment > 0)) { $(g).hide(); return; }

	timeStops = [];
	for (var i = 0; i < increments; i++) {
		timeStops.push({
			uuid: 'budget-stop-' + i,
			start: start + allotment * i,
			end: start + allotment * (i + 1) - 1,
			series: {}
		});
	}

	var series = [];
	var low = 0;
	var high = 0;
	var any = false;
	$.each(response.accounts, function(name, account) {
		if (!account || name == 'gallery') { return; }
		var journals = account.journals || [];
		// an account the period never touched is not a flat line at zero; it is
		// simply not on this chart
		if (!journals.length && !numeral(account.starting_balance).value()) { return; }
		var value = numeral(account.starting_balance || 0).value() || 0;
		var at = 0;
		var points = [];
		for (var s = 0; s < timeStops.length; s++) {
			while (at < journals.length && numeral(journals[at].timestamp).value() <= timeStops[s].end) {
				value = numeral(journals[at].amount).value() || 0;
				at++;
			}
			points.push(value);
			timeStops[s].series[name] = value;
			if (value < low) { low = value; }
			if (value > high) { high = value; }
			if (value) { any = true; }
		}
		if (journals.length) { any = true; }
		series.push({ name: name, account: account, points: points });
	});
	if (!series.length || !any) { $(g).hide(); return; }

	// the total is the sum of the accounts at each stop, whether or not a line is
	// switched off, so hiding one does not move the headline
	var totals = [];
	for (var s = 0; s < timeStops.length; s++) {
		var sum = 0;
		$.each(series, function(i, row) {
			sum += row.points[s] || 0;
		});
		totals.push(sum);
		timeStops[s].total = sum;
		if (sum < low) { low = sum; }
		if (sum > high) { high = sum; }
	}

	$(g).show();
	var paper = budgetChartPaper(g);
	if (!paper) { return; }
	var ctx = paper.ctx;
	var wide = paper.wide;
	var tall = paper.tall;
	var ink = budgetChartInk();
	var plotW = Math.max(10, wide - budgetChartPad.left - budgetChartPad.right);
	var plotH = Math.max(10, tall - budgetChartPad.top - budgetChartPad.bottom);
	if (low > 0) { low = 0; }
	if (high < low) { high = low + 1; }
	if (high == low) { high = low + 1; }
	var range = high - low;
	var yOf = function(value) { return budgetChartPad.top + plotH - ((value - low) / range) * plotH; };
	var xOf = function(index) { return budgetChartPad.left + (plotW * (index + 0.5)) / increments; };

	ctx.font = '400 10px Arial, sans-serif';
	ctx.textBaseline = 'middle';
	$.each(budgetTicks(low, high, 4), function(i, value) {
		var gy = Math.round(yOf(value)) + 0.5;
		ctx.strokeStyle = ink.line;
		ctx.globalAlpha = 0.6;
		ctx.beginPath();
		ctx.moveTo(budgetChartPad.left, gy);
		ctx.lineTo(wide - budgetChartPad.right, gy);
		ctx.stroke();
		ctx.globalAlpha = 1;
		ctx.fillStyle = ink.muted;
		ctx.textAlign = 'right';
		ctx.fillText(budgetMoney(value), budgetChartPad.left - 8, gy);
	});
	if (low < 0 && high > 0) {
		ctx.strokeStyle = ink.ink;
		ctx.globalAlpha = 0.45;
		ctx.beginPath();
		ctx.moveTo(budgetChartPad.left, Math.round(yOf(0)) + 0.5);
		ctx.lineTo(wide - budgetChartPad.right, Math.round(yOf(0)) + 0.5);
		ctx.stroke();
		ctx.globalAlpha = 1;
	}

	var span = end - start;
	var every = Math.max(1, Math.ceil(increments / Math.max(2, Math.floor(plotW / 90))));
	ctx.fillStyle = ink.muted;
	ctx.textAlign = 'center';
	ctx.textBaseline = 'top';
	for (var label = 0; label < increments; label += every) {
		ctx.fillText(budgetChartLabel(timeStops[label].start, span), xOf(label), budgetChartPad.top + plotH + 7);
	}

	ctx.lineJoin = 'round';
	ctx.lineCap = 'round';
	var draw = function(points, colour, width, alpha) {
		if (!points.length) { return; }
		ctx.save();
		ctx.globalAlpha = alpha || 1;
		ctx.strokeStyle = colour || ink.muted;
		ctx.lineWidth = width;
		ctx.beginPath();
		$.each(points, function(i, value) {
			if (i === 0) { ctx.moveTo(xOf(i), yOf(value)); }
			else { ctx.lineTo(xOf(i), yOf(value)); }
		});
		ctx.stroke();
		ctx.restore();
	};
	$.each(series, function(i, row) {
		if (row.account.graphable == 'no') { return; }
		var colour = (row.account.settings && row.account.settings.colour) ? row.account.settings.colour : ink.muted;
		draw(row.points, colour, 1.4, 0.9);
	});
	if (series.length > 1) { draw(totals, ink.accent, 2.4, 1); }

	for (var mark = 0; mark < increments; mark += Math.max(1, Math.floor(increments / 10))) {
		ctx.fillStyle = ink.accent;
		ctx.beginPath();
		ctx.arc(xOf(mark), yOf(totals[mark]), 2, 0, Math.PI * 2);
		ctx.fill();
	}
}

// An account name is the person's own text, and the tooltip is built as an HTML
// string: escape the name before it joins that string, and keep the money
// formatting untouched.
function budgetTipEscape(value) {
	return $('<div>').text(value == null ? '' : String(value)).html();
}

function budgetStopTip(index) {
	var stop = timeStops[index];
	var response = budgetChartResponse || {};
	var span = (numeral(response.end).value() || 0) - (numeral(response.start).value() || 0);
	var html = '<div class="budget_tip_when">' + budgetChartLabel(stop.start, span) + '</div>';
	var minimum = 0;
	$.each(stop.series || {}, function(name, value) {
		var account = (response.accounts || {})[name] || {};
		minimum += numeral(account.settings && account.settings.minimum).value() || 0;
		if (account.graphable == 'no') { return; }
		var colour = (account.settings && account.settings.colour) ? account.settings.colour : '';
		html += '<div class="budget_tip_row"><span class="budget_tip_swatch" style="background:' + colour + '"></span>' +
			budgetTipEscape(format_name(name)) + '<b>' + budgetMoneyFull(value) + '</b></div>';
	});
	html += '<div class="budget_tip_row">' + format_name('available') + '<b>' + budgetMoneyFull((numeral(stop.total).value() || 0) - minimum) + '</b></div>';
	html += '<div class="budget_tip_row budget_tip_total">' + format_name('total') + '<b>' + budgetMoneyFull(stop.total) + '</b></div>';
	html += '<div class="budget_tip_hint">' + jawnosT('Click to open this period') + '</div>';
	return html;
}

$(document).on('mousemove touchmove', '#budget_account_canvas', function(event) {
	if (!timeStops.length) { return; }
	var hit = budgetChartIndex(this, event, timeStops.length);
	if (hit.index === budgetChartHover) { return; }
	budgetChartHover = hit.index;
	budgetTipShow('#budget_account_information', budgetStopTip(hit.index), hit.point);
});

$(document).on('mouseleave', '#budget_account_canvas', function() {
	budgetChartHover = -1;
	$('#budget_account_information').hide();
});

// A click names a period: the same chart, redrawn for the stop under the pointer.
$(document).on('click', '#budget_account_canvas', function(event) {
	if (!timeStops.length) { return; }
	var hit = budgetChartIndex(this, event, timeStops.length);
	var stop = timeStops[hit.index];
	if (!stop) { return; }
	$('#budget_account_information').hide();
	budgetInit({ period: { start: Math.round(stop.start), end: Math.round(stop.end) } });
});

$(document).on('click', '.budget_account', function() {
	var ba = $(this);
	var i = ba.attr('account');
	var data = JSON.parse($('#budget_json_data').text());
	if (!data.accounts[i]) {
		data.accounts[i] = {'graphable': 'yes' };
	}
	if (data.accounts[i]['graphable'] == 'no') {
		data.accounts[i]['graphable'] = 'yes';
		ba.css({ 'color': ba.attr('colour') });
	} else {
		data.accounts[i]['graphable'] = 'no';
		ba.css({ 'color': 'lightgrey' });
	}
	var jdata = JSON.stringify(data);
	$('#budget_json_data').text(jdata);
	budgetAccountCanvasWriter(data);
});

$(document).on('click', '#budget_settings_toggle', function() {
	var bs = $('#budget_settings');
	var visible = bs.is(':visible');
	if ( visible ) {
		bs.hide();
	}
	else {
		bs.show();
	}
});

$(document).on('change', '.budget_config', function() {
	clearTimeout(budgetConfigTimeout);
	var setting = $(this).val();
	var wait_time = 1000;
	var config = $(this).attr('config');
	if ($(this).attr('multiple') == "multiple") {
		setting = JSON.stringify(setting);
	}
	var delorean = deloreanBringer();
	delorean[config] = setting;
	var new_settings = {};
	$('#budget_display').val('');
	if ($(this).attr('id') != 'budget_display') {
		var display = $('#budget_display').attr('budget_display');
		display = display + '_display';
		new_settings[display] = '';
	}

	new_settings[config] = setting;
	if (config == 'scope') {
		new_settings['start_time'] = '';
		new_settings['end_time'] = '';
		wait_time += 200;
	}
	budgetInit({ 'new_settings': new_settings });

});

$(document).on('change', '.budget_time', function() {
	var setting = $(this).attr('setting');


	var value = $('.budget_time[setting="' + setting + '"]').val();
//	settingSetter({ 'app': 'budget', 'setting': setting, 'value': value });
	var new_settings = {};
	new_settings[setting] = value;	

	budgetInit({ 'new_settings': new_settings });


});


$(document).on('click', '.budget_row', function() {
	var row = $(this);
	var app = row.attr('app');
	var movement = row.attr('movement');
	var status = row.attr('status');
	var rows = $('.budget_detail_row[movement="' + movement + '"][app="' + app + '"]');
	if (status == 'closed') {
		rows.show();
		row.attr('status','open');
	}
	else {
		rows.hide();
		row.attr('status','closed');
	}
});

$(document).on('click', '.budget_app', function() {
	var dr = $(this).closest('.budget_detail_row');
	var timestamp = dr.attr('timestamp');
	var server_time = dr.attr('server_time');
	var app = $(this).attr('app');
	var filter = dr.attr('filter');
	var sorts = localStorage.getItem('sorts');
	var scope = localStorage.getItem('scope');
	appointmentGrabber(app,timestamp);
	var variables = { app: app, filter: filter, sorts: sorts, timeshift: '0d', time_machine: '', timestamp: timestamp, scope: scope };
	var budgetAppAttempts = 0;
	var budgetAppInterval = setInterval(function() {
		budgetAppAttempts++;
		// give up after 10s if the window never appears, so we don't poll forever
		if (budgetAppAttempts > 50) { clearInterval(budgetAppInterval); return; }
		var parent = $('.wind[app="' + app + '"]');
		if (parent.length > 0) {
			var container = parent.find('.re_details');
		
			$.ajax({ 
				url: '/manager/appointment_details',
				type: 'GET',
				data: variables,
				success: function(response) {
					clearInterval(budgetAppInterval);
					container.html(response);
					container.show();
					appointment_chron();
				}
			});
		}
	},200);
});

$(document).on('click', '.budget_invoice', function() {
	var row = $(this);
	var app = row.attr('app');
	var uuid = row.attr('uuid');
	var timestamp = row.attr('timestamp');
	var sorts = localStorage.getItem('sorts');
	var scope = localStorage.getItem('scope');
	appointmentGrabber(app,timestamp);
	var variables = { app: app, uuid: uuid, sorts: sorts, timeshift: '0d', time_machine: '', timestamp: timestamp, scope: scope };
	var budgetInvoiceAttempts = 0;
	var budgetInvoiceInterval = setInterval(function() {
		budgetInvoiceAttempts++;
		// give up after 10s if the window never appears, so we don't poll forever
		if (budgetInvoiceAttempts > 50) { clearInterval(budgetInvoiceInterval); return; }
		var parent = $('.wind[app="' + app + '"]');
		if (parent.length > 0) {
			var container = parent.find('.re_details');
			if (container.length == 0) { return; }
			clearInterval(budgetInvoiceInterval);
			$.ajax({
				url: '/manager/appointment_details',
				type: 'GET',
				data: variables,
				success: function(response) {
					container.html(response);
					container.show();
					appointment_chron();
				}
			});
		}
	},200);
});

$(document).on('click', '.budget_invoice_payments_toggle', function(e) {
	e.stopPropagation();
	var uuid = $(this).attr('uuid');
	$('.budget_invoice_payment_row[uuid="' + uuid + '"]').toggle();
});

$(document).on('click', '.budget_autocalc', function() {
	var button = $(this);
	var app = button.attr('app');
	var circumstance = $(this).attr('circumstance');
	var timestamp = Date.now();
	button.addClass('active');
	var autoCalcInterval;
	var autoCalcTimeout;
	button.addClass('medium_thumb').removeClass('little_thumb');
	autoCalcInterval = setInterval(function() {
		button.addClass('little_thumb').removeClass('medium_thumb');
		clearTimeout(autoCalcTimeout);
		autoCalcTimeout = setTimeout(function() {
			button.addClass('medium_thumb').removeClass('little_thumb');
		},500);
	}, 1000);

	$.ajax({
		url: '/manager/budget/autocalc',
		type: 'GET',
		data: { timestamp: timestamp, app: app, circumstance: circumstance },
		success: function(response) {
			button.addClass('medium_thumb').removeClass('little_thumb');
			clearInterval(autoCalcInterval);

		//	if ($('.wind[app="budget"').is(':visible')) {
				var message = 'These are the autocalcs for ' + response.data.formatted_app + '<br><br>';
				$.each(response, function(i,v) {
					if (i != 'data') {
						message += '<button app="' + response.data.app + '" circumstance="' + response.data.circumstance + '" result="' + v.formatted_result + '" class="budget_autocalc_accept">' + v.formatted_result +'</button><br>';
					}
				});
				message += '<br>';
				jawnosAlert(message);
				$(this).removeClass('active');
		//	}
			if ($('.wind[app="' + app + '"]').is(':visible')) {
				inventoryDetails(app);
			}
		},
		error: function() {
			// stop the pulse if the autocalc request failed
			button.addClass('medium_thumb').removeClass('little_thumb');
			clearInterval(autoCalcInterval);
		}
	});
});

// the autocalc popover's older buttons carry only the whole entry; read it back
// into the parts the row editor wants
function budgetSuggestionParts(circumstance, entry) {
	entry = $.trim(entry || '');
	var direction = 'floor';
	if (entry.indexOf('<=') === 0) { direction = 'ceiling'; entry = entry.slice(2); }
	else if (entry.indexOf('>=') === 0) { entry = entry.slice(2); }
	var scope = '';
	var slash = entry.lastIndexOf('/');
	if (slash > -1) { scope = entry.slice(slash + 1); entry = entry.slice(0, slash); }
	// the autocalc names a total's scope by its symbol; the budget wants the unit
	var units = { s: 'second', m: 'minute', h: 'hour', d: 'day', w: 'week', M: 'month', y: 'year' };
	if (units[scope]) { scope = units[scope]; }
	var measure = (circumstance === 'occurences') ? '' : ((circumstance === 'total') ? '$' : circumstance);
	var amount = entry;
	if (measure === '$') { amount = amount.replace(/^\$/, ''); }
	else if (measure !== '' && measure !== 'duration' && amount.slice(-measure.length) === measure) {
		amount = amount.slice(0, -measure.length);
	}
	return { amount: amount, measure: measure, scope: scope, direction: direction };
}

// Set the budget the panel recommends: the entry keeps its scope and direction,
// the entry it replaces is named exactly, and the forms on screen (the Budget
// app's table and Configure's row editor) show the new value.
$(document).on('click', '.budget_autocalc_accept', function() {
	var button = $(this);
	var app = button.attr('app');
	var circumstance = button.attr('circumstance');
	var b = $('.budget_edit_input[app="' + app + '"][circumstance="' + circumstance + '"]');
	var amount, measure, scope, direction, previous, result;
	if (typeof button.attr('amount') === 'undefined') {
		var parts = budgetSuggestionParts(circumstance, button.attr('result'));
		amount = parts.amount;
		measure = parts.measure;
		scope = parts.scope;
		direction = parts.direction;
		previous = b.length ? (b.attr('value') || '') : '';
		result = budgetGoalsEntry(amount, measure, scope, direction);
	}
	else {
		amount = button.attr('amount');
		measure = button.attr('measure') || '';
		scope = button.attr('scope') || '';
		direction = button.attr('direction') || 'floor';
		previous = button.attr('previous') || '';
		result = budgetGoalsEntry(amount, measure, scope, direction);
	}
	b.val(result);
	b.attr('value', result);
	var form = $('.budget_goals[app="' + app + '"][setting="budget"]');
	if (form.length) {
		budgetGoalsRowSet(form, measure, amount, scope, direction);
		var label = $('.app_configure_toggle[setting="budget"][app="' + app + '"]');
		if (label.length) {
			label.find('.ability_label').html('<b>' + label.attr('formatted_setting') + ':</b> ' + budgetGoalsValue(form).slice(0, 20));
		}
	}
	jawnosAlertClose();
	$.ajax({
		url: '/manager/budget/edit',
		type: 'POST',
		data: { app: app, value: result, previous: previous, circumstance: circumstance },
		success: function(response) {
			if ($('.wind[app="' + app + '"]').is(':visible')) {
				inventoryDetails(app);
			}
		}
	});
});



$(document).on('change, focusout', '.budget_edit_input', function() {
	var input = $(this);
	var app = input.attr('app');
	var value = input.val();
	var circumstance = input.attr('circumstance');
	var previous = input.attr('value') || '';
	// change and focusout both fire on a blur; only one of them is a real edit
	if (value === previous) { return; }
	input.attr('value', value);
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/budget/edit',
		type: 'POST',
		data: { app: app, value: value, previous: previous, circumstance: circumstance },
		success: function(response) {
		}
	});
});

