// ---------------------------------------------------------------------------
// The Runway chart
//
// Drawn on the same paper as the statement chart (budget.js owns budgetChartPaper
// and the money helpers). Two things share the x axis: the balance line on top,
// past solid and the projection dashed, and a strip of net bars underneath, so a
// loss-making period reads as a fall without having to hover it. The floor line
// is the money the accounts are set to keep; where the projection crosses it is
// the runway, and that date is marked on the chart.
//
// Everything the panel shows comes from the response the route already rendered
// (data.runway), so a period can be opened without another round trip.
// ---------------------------------------------------------------------------

var budgetRunwayData = null;
var budgetRunwaySelected = -1;
var budgetRunwayHover = -1;
var budgetRunwayLayout = null;
var budgetChartResizeTimer;

function budgetRunwayWriter(response) {
	var g = document.getElementById('budget_runway_canvas');
	if (!g || !g.getContext) { return; }
	if (!response || !response.runway || !response.runway.buckets || !response.runway.buckets.length) {
		budgetRunwayData = null;
		return;
	}
	budgetRunwayData = response.runway;
	budgetRunwaySelected = -1;
	budgetRunwayHover = -1;
	budgetRunwayPaint();
	$('#budget_runway_detail').hide().empty();
}

function budgetRunwayValue(bucket) {
	if (bucket.kind == 'past') { return numeral(bucket.balance).value() || 0; }
	return numeral(bucket.projected_balance).value() || 0;
}

function budgetRunwayNet(bucket) {
	if (bucket.kind == 'past') { return numeral(bucket.actual_net).value() || 0; }
	return numeral(bucket.projected_net).value() || 0;
}

function budgetRunwayPaint() {
	var data = budgetRunwayData;
	var g = document.getElementById('budget_runway_canvas');
	if (!data || !g || !g.getContext) { return; }
	var buckets = data.buckets || [];
	var count = buckets.length;
	if (!count) { return; }

	var paper = budgetChartPaper(g);
	if (!paper) { return; }
	var ctx = paper.ctx;
	var wide = paper.wide;
	var tall = paper.tall;
	var ink = budgetChartInk();
	var padLeft = budgetChartPad.left;
	var padRight = budgetChartPad.right;
	var padTop = 14;
	var padBottom = 24;
	var plotW = Math.max(10, wide - padLeft - padRight);
	var plotH = Math.max(10, tall - padTop - padBottom);
	var stripH = Math.max(26, plotH * 0.28);
	var gap = 14;
	var lineH = Math.max(20, plotH - stripH - gap);
	var stripTop = padTop + lineH + gap;
	var step = plotW / count;

	var reserve = numeral(data.reserve).value() || 0;
	var low = Math.min(reserve, 0);
	var high = 0;
	var barMax = 0;
	$.each(buckets, function(i, bucket) {
		var value = budgetRunwayValue(bucket);
		if (value < low) { low = value; }
		if (value > high) { high = value; }
		var net = Math.abs(budgetRunwayNet(bucket));
		if (net > barMax) { barMax = net; }
	});
	if (high <= low) { high = low + 1; }
	var range = high - low;

	var xOf = function(index) { return padLeft + step * (index + 0.5); };
	var yOf = function(value) { return padTop + lineH - ((value - low) / range) * lineH; };
	var barBase = stripTop + stripH / 2;
	var barScale = barMax > 0 ? (stripH / 2 - 2) / barMax : 0;

	budgetRunwayLayout = { left: padLeft, plotW: plotW, count: count, step: step, xOf: xOf, yOf: yOf, now: data.now };

	ctx.font = '400 10px Arial, sans-serif';
	ctx.textBaseline = 'middle';

	// the tint the projection lives on, so past and future are told apart at a
	// glance rather than by following the dashes
	var current = buckets[data.current_index] || buckets[0];
	var currentSpan = (current.end || 0) - (current.start || 0);
	var nowShare = currentSpan > 0 ? ((data.now - current.start) / currentSpan) : 1;
	nowShare = Math.max(0, Math.min(1, nowShare));
	var nowX = padLeft + step * data.current_index + step * nowShare;
	ctx.save();
	ctx.fillStyle = ink.line;
	ctx.globalAlpha = 0.16;
	ctx.fillRect(nowX, padTop, wide - padRight - nowX, plotH);
	ctx.restore();

	// money grid
	$.each(budgetTicks(low, high, 4), function(i, value) {
		var gy = Math.round(yOf(value)) + 0.5;
		ctx.strokeStyle = ink.line;
		ctx.globalAlpha = 0.6;
		ctx.beginPath();
		ctx.moveTo(padLeft, gy);
		ctx.lineTo(wide - padRight, gy);
		ctx.stroke();
		ctx.globalAlpha = 1;
		ctx.fillStyle = ink.muted;
		ctx.textAlign = 'right';
		ctx.fillText(budgetMoney(value), padLeft - 8, gy);
	});

	// the net strip's own zero
	ctx.strokeStyle = ink.line;
	ctx.globalAlpha = 0.8;
	ctx.beginPath();
	ctx.moveTo(padLeft, Math.round(barBase) + 0.5);
	ctx.lineTo(wide - padRight, Math.round(barBase) + 0.5);
	ctx.stroke();
	ctx.globalAlpha = 1;

	// period labels
	var every = Math.max(1, Math.ceil(count / Math.max(2, Math.floor(plotW / 74))));
	ctx.fillStyle = ink.muted;
	ctx.textAlign = 'center';
	ctx.textBaseline = 'top';
	for (var label = 0; label < count; label += every) {
		ctx.fillText(buckets[label].short || '', xOf(label), padTop + plotH + 7);
	}

	// the selected period's band
	if (budgetRunwaySelected >= 0 && budgetRunwaySelected < count) {
		ctx.save();
		ctx.fillStyle = ink.accent;
		ctx.globalAlpha = 0.12;
		ctx.fillRect(padLeft + step * budgetRunwaySelected, padTop, step, plotH);
		ctx.restore();
	}

	// the net bars: a loss below the line, a gain above it
	$.each(buckets, function(i, bucket) {
		var net = budgetRunwayNet(bucket);
		if (!net || !barScale) { return; }
		var height = Math.abs(net) * barScale;
		var width = Math.max(2, step * 0.56);
		var left = xOf(i) - width / 2;
		var top = net < 0 ? barBase : barBase - height;
		ctx.save();
		ctx.globalAlpha = bucket.kind == 'past' ? 0.85 : 0.45;
		ctx.fillStyle = net < 0 ? ink.bad : ink.good;
		ctx.fillRect(left, top, width, height);
		ctx.restore();
	});

	// the floor and the zero line
	if (reserve !== 0 || low < 0) {
		ctx.save();
		ctx.strokeStyle = ink.bad;
		ctx.globalAlpha = 0.65;
		ctx.setLineDash([4, 4]);
		ctx.beginPath();
		ctx.moveTo(padLeft, Math.round(yOf(reserve)) + 0.5);
		ctx.lineTo(wide - padRight, Math.round(yOf(reserve)) + 0.5);
		ctx.stroke();
		ctx.restore();
		ctx.fillStyle = ink.bad;
		ctx.globalAlpha = 0.8;
		ctx.textAlign = 'right';
		ctx.fillText(jawnosT('floor'), wide - padRight - 2, yOf(reserve) - 8);
		ctx.globalAlpha = 1;
	}

	// the balance: solid through what happened, dashed from where the person is
	var pastPoints = [];
	for (var i = 0; i < data.current_index; i++) {
		pastPoints.push([xOf(i), yOf(numeral(buckets[i].balance).value() || 0)]);
	}
	var nowY = yOf(numeral(data.balance).value() || 0);
	pastPoints.push([nowX, nowY]);
	var futurePoints = [[nowX, nowY]];
	for (var j = data.current_index; j < count; j++) {
		futurePoints.push([xOf(j), yOf(budgetRunwayValue(buckets[j]))]);
	}

	ctx.lineJoin = 'round';
	ctx.lineCap = 'round';
	var stroke = function(points, colour, width, dashed, alpha) {
		if (points.length < 2) { return; }
		ctx.save();
		ctx.globalAlpha = alpha || 1;
		ctx.strokeStyle = colour;
		ctx.lineWidth = width;
		ctx.setLineDash(dashed ? [6, 4] : []);
		ctx.beginPath();
		$.each(points, function(i, point) {
			if (i === 0) { ctx.moveTo(point[0], point[1]); }
			else { ctx.lineTo(point[0], point[1]); }
		});
		ctx.stroke();
		ctx.restore();
	};
	stroke(futurePoints, ink.accent, 2.2, true, 0.85);
	stroke(pastPoints, ink.accent, 2.4, false, 1);

	// the point the person is standing on
	ctx.save();
	ctx.fillStyle = ink.panel;
	ctx.strokeStyle = ink.accent;
	ctx.lineWidth = 2;
	ctx.beginPath();
	ctx.arc(nowX, nowY, 3.4, 0, Math.PI * 2);
	ctx.fill();
	ctx.stroke();
	ctx.restore();

	// where the projection crosses the floor
	var runwayAt = numeral(data.runway_at).value();
	if (runwayAt) {
		var runwayX = nowX;
		if (runwayAt > nowX) {
			var found = data.current_index;
			for (var k = data.current_index; k < count; k++) {
				if (data.buckets[k].end >= runwayAt) { found = k; break; }
			}
			var bucket = buckets[found];
			var fraction = (bucket.end > bucket.start) ? (runwayAt - bucket.start) / (bucket.end - bucket.start) : 0;
			runwayX = xOf(found) - step / 2 + step * Math.max(0, Math.min(1, fraction));
		}
		ctx.save();
		ctx.strokeStyle = ink.bad;
		ctx.globalAlpha = 0.8;
		ctx.setLineDash([2, 3]);
		ctx.beginPath();
		ctx.moveTo(runwayX, padTop);
		ctx.lineTo(runwayX, padTop + plotH);
		ctx.stroke();
		ctx.restore();
		ctx.save();
		ctx.fillStyle = ink.bad;
		ctx.beginPath();
		ctx.arc(runwayX, yOf(reserve), 4, 0, Math.PI * 2);
		ctx.fill();
		ctx.restore();
		ctx.fillStyle = ink.bad;
		ctx.globalAlpha = 0.9;
		ctx.textAlign = runwayX > wide - padRight - 90 ? 'right' : 'left';
		ctx.textBaseline = 'bottom';
		ctx.fillText(jawnosT('runs out'), runwayX + (runwayX > wide - padRight - 90 ? -6 : 6), padTop + 12);
		ctx.globalAlpha = 1;
	}

	// the line that marks now
	ctx.strokeStyle = ink.muted;
	ctx.globalAlpha = 0.35;
	ctx.beginPath();
	ctx.moveTo(nowX, padTop);
	ctx.lineTo(nowX, padTop + plotH);
	ctx.stroke();
	ctx.globalAlpha = 1;
}

function budgetRunwayIndex(canvas, event) {
	var point = budgetChartPointer(canvas, event);
	var layout = budgetRunwayLayout;
	if (!layout) { return { index: 0, point: point }; }
	var index = Math.floor((point.x - layout.left) / layout.step);
	if (index < 0) { index = 0; }
	if (index >= layout.count) { index = layout.count - 1; }
	return { index: index, point: point };
}

function budgetRunwayTip(index) {
	var bucket = budgetRunwayData.buckets[index];
	var kind = bucket.kind == 'past' ? jawnosT('Recorded') : (bucket.kind == 'current' ? jawnosT('This period') : jawnosT('Projected'));
	var html = '<div class="budget_tip_when">' + (bucket.label || '') + ' &middot; ' + kind + '</div>';
	var row = function(label, value, tone) {
		return '<div class="budget_tip_row' + (tone ? ' ' + tone : '') + '">' + label + '<b>' + value + '</b></div>';
	};
	html += row(jawnosT('In'), budgetMoneyFull(bucket.actual_in || 0));
	html += row(jawnosT('Out'), budgetMoneyFull(-(bucket.actual_out || 0)));
	if (bucket.kind != 'past') {
		html += row(jawnosT('Planned'), budgetMoneyFull(bucket.planned_net || 0));
		html += row(jawnosT('Projected balance'), budgetMoneyFull(bucket.projected_balance || 0));
	}
	else {
		html += row(jawnosT('Balance'), budgetMoneyFull(bucket.balance || 0));
	}
	html += '<div class="budget_tip_hint">' + jawnosT('Click for the transactions') + '</div>';
	return html;
}

function budgetRunwaySelect(index) {
	if (!budgetRunwayData) { return; }
	var bucket = budgetRunwayData.buckets[index];
	if (!bucket) { return; }
	budgetRunwaySelected = index;
	budgetRunwayPaint();
	var kind = bucket.kind == 'past' ? jawnosT('Recorded') : (bucket.kind == 'current' ? jawnosT('This period') : jawnosT('Projected'));
	var html = '<div class="runway_detail_head">' +
		'<b>' + (bucket.label || '') + '</b>' +
		'<span class="runway_detail_kind">' + kind + '</span>' +
		'<button type="button" class="runway_close" aria-label="' + jawnosT('Close') + '">&times;</button>' +
		'</div>';
	html += '<div class="runway_detail_totals">';
	html += '<span>' + jawnosT('In') + ' <b>' + budgetMoneyFull(bucket.actual_in || 0) + '</b></span>';
	html += '<span>' + jawnosT('Out') + ' <b>' + budgetMoneyFull(-(bucket.actual_out || 0)) + '</b></span>';
	if (bucket.planned_net) {
		html += '<span>' + jawnosT('Planned') + ' <b>' + budgetMoneyFull(bucket.planned_net) + '</b></span>';
	}
	html += '<span>' + jawnosT('Balance') + ' <b>' + budgetMoneyFull(bucket.kind == 'past' ? bucket.balance : bucket.projected_balance) + '</b></span>';
	html += '</div>';

	var rows = [];
	$.each(bucket.rows || [], function(i, row) { rows.push(row); });
	$.each(bucket.planned_rows || [], function(i, row) { rows.push(row); });
	if (rows.length) {
		html += '<table class="runway_detail_rows"><thead><tr>' +
			'<th>' + jawnosT('When') + '</th><th>' + jawnosT('What') + '</th>' +
			'<th style="text-align:right;">' + jawnosT('Amount') + '</th></tr></thead><tbody>';
		$.each(rows, function(i, row) {
			var what = row.vendor || row.item || format_name(row.app || '');
			if (row.scheduled) { what = jawnosT('Scheduled bill') + (what ? ': ' + format_name(what) : ''); }
			html += '<tr class="runway_detail_row' + (row.total < 0 ? ' runway_detail_out' : '') + '">' +
				'<td><span class="time" timestamp="' + row.timestamp + '"></span></td>' +
				'<td>' + format_name(what) + '</td>' +
				'<td style="text-align:right;">' + budgetMoneyFull(row.total) + '</td></tr>';
		});
		html += '</tbody></table>';
	}
	else {
		html += '<div class="runway_detail_empty">' + jawnosT('Nothing was recorded in this period.') + '</div>';
	}
	var extra = (bucket.actual_count || 0) + (bucket.planned_count || 0) - rows.length;
	if (extra > 0) {
		html += '<div class="runway_detail_more">+' + extra + ' ' + jawnosT('more') + '</div>';
	}
	html += '<div class="runway_detail_actions">' +
		'<button type="button" class="runway_open" start="' + bucket.start + '" end="' + bucket.end + '">' +
		jawnosT('Open this period') + '</button></div>';
	$('#budget_runway_detail').html(html).show();
	appointment_chron();
}

$(document).on('mousemove touchmove', '#budget_runway_canvas', function(event) {
	if (!budgetRunwayData) { return; }
	var hit = budgetRunwayIndex(this, event);
	if (hit.index === budgetRunwayHover) { return; }
	budgetRunwayHover = hit.index;
	budgetTipShow('#budget_runway_tip', budgetRunwayTip(hit.index), hit.point);
});

$(document).on('mouseleave', '#budget_runway_canvas', function() {
	budgetRunwayHover = -1;
	$('#budget_runway_tip').hide();
});

$(document).on('click', '#budget_runway_canvas', function(event) {
	if (!budgetRunwayData) { return; }
	var hit = budgetRunwayIndex(this, event);
	$('#budget_runway_tip').hide();
	budgetRunwaySelect(hit.index);
});

$(document).on('click', '.runway_row', function() {
	var index = parseInt($(this).attr('bucket'), 10);
	if (!isNaN(index)) { budgetRunwaySelect(index); }
});

$(document).on('click', '.runway_unit', function() {
	var unit = $(this).attr('unit');
	if (!unit) { return; }
	var settings = {};
	settings['runway_unit'] = unit;
	budgetInit({ new_settings: settings });
});

$(document).on('click', '.runway_close', function() {
	budgetRunwaySelected = -1;
	$('#budget_runway_detail').hide().empty();
	budgetRunwayPaint();
});

$(document).on('click', '.runway_open', function() {
	var start = Math.round(numeral($(this).attr('start')).value());
	var end = Math.round(numeral($(this).attr('end')).value());
	if (!start || !end) { return; }
	// the Ledger is the view of one period: the transactions the panel has just
	// summarised, at full width, with the app and the account they belong to
	budgetInit({ display: 'statement', period: { start: start, end: end } });
});

// a window resize changes the paper, not the figures: repaint from the response
$(window).on('resize', function() {
	clearTimeout(budgetChartResizeTimer);
	budgetChartResizeTimer = setTimeout(function() {
		if (budgetChartResponse) { budgetAccountCanvasWriter(budgetChartResponse); }
		if (budgetRunwayData) { budgetRunwayPaint(); }
	}, 150);
});
