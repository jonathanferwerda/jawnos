// ---- tabs -------------------------------------------------------------------
function weatherShowTab(name) {
	var $w = $('.wind[app="weather"]').last();
	if (!$w.length) { return; }
	$w.find('.weather_tab').removeClass('active').filter('[data-tab="' + name + '"]').addClass('active');
	$w.find('.weather_panel').hide();
	$w.find('#weather_' + name + '_panel').show();
	if (name === 'history' && !weatherHistoryLoaded) { weatherHistoryLoad(); }
	if (name === 'accuracy' && !weatherAccuracyLoaded) { weatherAccuracyLoad(); }
}

// ---- history ----------------------------------------------------------------
function weatherHistoryLoad(force) {
	var $w = $('.wind[app="weather"]').last();
	if (!$w.length) { return; }
	var range = $w.find('#weather_history_range').val() || '30';
	var source = $w.find('#weather_history_source').val() || '';
	var city = weatherLastLocation ? (weatherLastLocation.city || '') : '';
	var region = weatherLastLocation ? (weatherLastLocation.region || '') : '';
	$w.find('#weather_history_status').text(jawnosT('Loading history…'));
	$.ajax({
		url: '/manager/weather/history',
		type: 'GET',
		data: { range: range, source: source, city: city, region: region, force: force ? 1 : 0 },
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				weatherHistoryError((response && response.error) || jawnosT('History is unavailable.'));
				return;
			}
			weatherHistoryRender(response);
		},
		error: function() { weatherHistoryError(jawnosT('History is unavailable.')); }
	});
}

function weatherHistoryError(message) {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_history_status').text('');
	$w.find('#weather_history_note').text(message || '').addClass('weather_warn');
}

function weatherHistoryRender(data) {
	var $w = $('.wind[app="weather"]').last();
	weatherHistoryLoaded = true;
	weatherHistoryData = data;
	var days = data.days || [];
	weatherHistorySourceOptions($w, '#weather_history_source', data.sources || [], data.source || '');
	var status = days.length + ' ' + jawnosT('days');
	if (data.built_at) { status += ' · ' + jawnosT('Built') + ' ' + weatherTime(data.built_at); }
	$w.find('#weather_history_status').text(status);
	$w.find('#weather_history_note').text(data.note || '').removeClass('weather_warn');
	weatherHistoryChart(days);
	weatherHistoryTable(days);
}

function weatherHistorySourceOptions($w, selector, sources, selected) {
	var select = $w.find(selector).empty();
	sources = sources || [];
	for (var i = 0; i < sources.length; i++) {
		var s = sources[i] || {};
		var label = s.label || s.app || '';
		if (s.city) { label += ' — ' + s.city; }
		if (s.days) { label += ' · ' + s.days + ' ' + jawnosT('days'); }
		select.append($('<option>').val(s.app || '').text(label));
	}
	if (selected) { select.val(selected); }
	if (!select.val() && select.find('option').length) { select.val(select.find('option').first().val()); }
}

function weatherHistoryChart(days) {
	var $w = $('.wind[app="weather"]').last();
	var $chart = $w.find('#weather_history_chart');
	if (!days || days.length < 2) {
		$chart.html('<div class="weather_muted" style="padding:8px;">' + weatherEsc(jawnosT('At least two days are needed to draw the history.')) + '</div>');
		return;
	}
	var values = [];
	for (var i = 0; i < days.length; i++) {
		if (days[i].high !== undefined && days[i].high !== null) { values.push(Number(days[i].high)); }
		if (days[i].low !== undefined && days[i].low !== null) { values.push(Number(days[i].low)); }
	}
	if (!values.length) {
		$chart.html('<div class="weather_muted" style="padding:8px;">' + weatherEsc(jawnosT('No temperature readings in this range.')) + '</div>');
		return;
	}
	var min = Math.min.apply(null, values);
	var max = Math.max.apply(null, values);
	var pad = Math.max(1, (max - min) * 0.1);
	min -= pad;
	max += pad;
	var W = 600, H = 170, L = 34, R = 10, T = 14, B = 24;
	var plotW = W - L - R, plotH = H - T - B;
	function x(i) { return L + (days.length <= 1 ? plotW / 2 : plotW * i / (days.length - 1)); }
	function y(v) { return T + (max - v) / (max - min) * plotH; }
	var high = [], low = [];
	for (var j = 0; j < days.length; j++) {
		if (days[j].high !== undefined && days[j].high !== null) { high.push(x(j) + ',' + y(Number(days[j].high))); }
		if (days[j].low !== undefined && days[j].low !== null) { low.push(x(j) + ',' + y(Number(days[j].low))); }
	}
	var svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + weatherEsc(jawnosT('Daily high and low')) + '">';
	svg += '<line x1="' + L + '" y1="' + T + '" x2="' + L + '" y2="' + (T + plotH) + '" stroke="currentColor" opacity=".22"/>';
	svg += '<line x1="' + L + '" y1="' + T + '" x2="' + (W - R) + '" y2="' + T + '" stroke="currentColor" opacity=".12"/>';
	svg += '<line x1="' + L + '" y1="' + (T + plotH) + '" x2="' + (W - R) + '" y2="' + (T + plotH) + '" stroke="currentColor" opacity=".12"/>';
	svg += '<text x="' + (L - 4) + '" y="' + (y(max) + 4) + '" text-anchor="end" font-size="10" fill="currentColor" opacity=".6">' + Math.round(max) + '°</text>';
	svg += '<text x="' + (L - 4) + '" y="' + (y(min) + 4) + '" text-anchor="end" font-size="10" fill="currentColor" opacity=".6">' + Math.round(min) + '°</text>';
	svg += '<polyline fill="none" stroke="#e0704a" stroke-width="2" points="' + high.join(' ') + '"/>';
	svg += '<polyline fill="none" stroke="#4a90d9" stroke-width="2" points="' + low.join(' ') + '"/>';
	svg += '<text x="' + L + '" y="9" font-size="10" fill="#e0704a">' + jawnosT('High') + '</text>';
	svg += '<text x="' + (L + 34) + '" y="9" font-size="10" fill="#4a90d9">' + jawnosT('Low') + '</text>';
	svg += '<text x="' + L + '" y="' + (H - 5) + '" font-size="10" fill="currentColor" opacity=".6">' + weatherEsc(days[0].date) + '</text>';
	svg += '<text x="' + (W - R) + '" y="' + (H - 5) + '" text-anchor="end" font-size="10" fill="currentColor" opacity=".6">' + weatherEsc(days[days.length - 1].date) + '</text>';
	svg += '</svg>';
	$chart.html(svg);
}

function weatherHistoryTable(days) {
	var $w = $('.wind[app="weather"]').last();
	var $table = $w.find('#weather_history_table');
	if (!days || !days.length) {
		$table.html('<div class="weather_muted" style="padding:8px;">' + weatherEsc(jawnosT('No history yet. Press Backfill history.')) + '</div>');
		return;
	}
	var html = '<table><thead><tr><th>' + jawnosT('Date') + '</th><th>' + jawnosT('High') + '</th><th>' + jawnosT('Low') + '</th><th>' + jawnosT('Mean') + '</th><th>' + jawnosT('Readings') + '</th><th>' + jawnosT('Condition') + '</th><th title="' + weatherEsc(jawnosT('The old app logged the forecast humidity, not an observed humidity.')) + '">' + jawnosT('Forecast humidity') + '</th><th>' + jawnosT('Wind') + '</th></tr></thead><tbody>';
	for (var i = 0; i < days.length; i++) {
		var d = days[i] || {};
		var condition = d.condition || '';
		var detail = (d.conditions || []).map(function(c) { return (c.text || '') + ' (' + (c.count || 0) + ')'; }).join(', ');
		html += '<tr>'
			+ '<td>' + weatherEsc(weatherDayLabel(d.date)) + '</td>'
			+ '<td>' + weatherTemp(d.high) + '</td>'
			+ '<td>' + weatherTemp(d.low) + '</td>'
			+ '<td>' + weatherTemp(d.mean) + '</td>'
			+ '<td>' + weatherEsc(d.count || 0) + '</td>'
			+ '<td title="' + weatherEsc(detail) + '">' + weatherEsc(condition) + '</td>'
			+ '<td>' + (d.humidity_forecast !== undefined && d.humidity_forecast !== null ? weatherNum(d.humidity_forecast) + '%' : '—') + '</td>'
			+ '<td>' + (d.wind !== undefined && d.wind !== null ? weatherNum(d.wind) + ' km/h' : '—') + '</td>'
			+ '</tr>';
	}
	html += '</tbody></table>';
	$table.html(html);
}

function weatherHistoryBackfill() {
	var $w = $('.wind[app="weather"]').last();
	var button = $w.find('#weather_history_backfill');
	if (button.prop('disabled')) { return; }
	button.prop('disabled', true);
	$w.find('#weather_history_status').text(jawnosT('Backfilling…'));
	$.ajax({
		url: '/manager/weather/backfill',
		type: 'POST',
		data: { timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok) {
				weatherHistoryError((response && response.error) || jawnosT('The backfill failed.'));
				return;
			}
			var n = 0;
			var sources = response.sources || [];
			for (var i = 0; i < sources.length; i++) { n += sources[i].days || 0; }
			$w.find('#weather_history_status').text(jawnosT('Backfilled') + ' ' + n + ' ' + jawnosT('days') + '.');
			weatherHistoryLoaded = false;
			weatherHistoryLoad();
		},
		error: function() { weatherHistoryError(jawnosT('The backfill failed.')); },
		complete: function() { button.prop('disabled', false); }
	});
}

// ---- forecast accuracy ------------------------------------------------------
function weatherAccuracyLoad(force) {
	var $w = $('.wind[app="weather"]').last();
	if (!weatherLastLocation || weatherLastLocation.lat === undefined || weatherLastLocation.lon === undefined) {
		weatherAccuracyError(jawnosT('Load the current weather first so the forecast location is known.'));
		return;
	}
	var range = $w.find('#weather_accuracy_range').val() || '30';
	var source = $w.find('#weather_accuracy_source').val() || '';
	$w.find('#weather_accuracy_status').text(jawnosT('Comparing…'));
	$.ajax({
		url: '/manager/weather/accuracy',
		type: 'GET',
		data: {
			range: range,
			source: source,
			city: weatherLastLocation.city || '',
			region: weatherLastLocation.region || '',
			lat: weatherLastLocation.lat,
			lon: weatherLastLocation.lon
		},
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				weatherAccuracyError((response && response.error) || jawnosT('Accuracy is unavailable.'));
				return;
			}
			weatherAccuracyRender(response);
		},
		error: function() { weatherAccuracyError(jawnosT('Accuracy is unavailable.')); }
	});
}

function weatherAccuracyError(message) {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_accuracy_status').text('');
	$w.find('#weather_accuracy_note').text(message || '').addClass('weather_warn');
	$w.find('#weather_accuracy_summary').empty();
	$w.find('#weather_accuracy_detail').empty();
}

function weatherAccuracyRender(data) {
	var $w = $('.wind[app="weather"]').last();
	weatherAccuracyLoaded = true;
	weatherAccuracyData = data;
	weatherAccuracySourceOptions($w, data.sources || [], data.source || '');
	var status = (data.forecast_days || 0) + ' ' + jawnosT('dates compared');
	$w.find('#weather_accuracy_status').text(status);
	var notes = [];
	if (data.different_city) {
		notes.push(jawnosT('History actuals are for') + ' ' + (data.source_city || data.source_label || '') + '; ' + jawnosT('the forecast is for') + ' ' + (data.forecast_city || '') + '. ' + jawnosT('Choose the matching source for a fair comparison.'));
	}
	if (data.note) { notes.push(data.note); }
	if (!data.forecast_days) {
		notes.push(jawnosT('No forecast snapshots yet. The Weather app records them when it loads; revisit over the next days.'));
	}
	$w.find('#weather_accuracy_note').text(notes.join(' ')).toggleClass('weather_warn', !!data.different_city);
	var rows = data.summary || [];
	var html = '<table><thead><tr><th>' + jawnosT('Lead') + '</th><th>' + jawnosT('Samples') + '</th><th>' + jawnosT('High MAE') + '</th><th>' + jawnosT('Low MAE') + '</th><th>' + jawnosT('Condition match') + '</th></tr></thead><tbody>';
	for (var i = 0; i < rows.length; i++) {
		var r = rows[i] || {};
		html += '<tr>'
			+ '<td>' + weatherEsc(r.lead + ' ' + jawnosT('day')) + '</td>'
			+ '<td>' + weatherEsc(r.count || 0) + '</td>'
			+ '<td>' + (r.mae_high !== undefined && r.mae_high !== null ? weatherNum(r.mae_high) + '°' : '—') + '</td>'
			+ '<td>' + (r.mae_low !== undefined && r.mae_low !== null ? weatherNum(r.mae_low) + '°' : '—') + '</td>'
			+ '<td>' + (r.condition_match !== undefined && r.condition_match !== null ? Math.round(r.condition_match) + '% (' + (r.condition_count || 0) + ')' : '—') + '</td>'
			+ '</tr>';
	}
	html += '</tbody></table>';
	$w.find('#weather_accuracy_summary').html(html);
	weatherAccuracyDetailRender(data);
}

function weatherAccuracySourceOptions($w, sources, selected) {
	var select = $w.find('#weather_accuracy_source').empty();
	sources = sources || [];
	for (var i = 0; i < sources.length; i++) {
		var s = sources[i] || {};
		var label = s.label || s.app || '';
		if (s.city) { label += ' — ' + s.city; }
		select.append($('<option>').val(s.app || '').text(label));
	}
	if (selected) { select.val(selected); }
	if (!select.val() && select.find('option').length) { select.val(select.find('option').first().val()); }
}

function weatherAccuracyDetailRender(data) {
	var $w = $('.wind[app="weather"]').last();
	var $detail = $w.find('#weather_accuracy_detail');
	var lead = $w.find('#weather_accuracy_lead').val() || '1';
	var rows = (data.detail || []).filter(function(r) { return r.forecasts && r.forecasts[lead]; });
	if (!rows.length) {
		$detail.html('<div class="weather_muted" style="padding:8px;">' + weatherEsc(jawnosT('No forecast snapshot for this lead time yet.')) + '</div>');
		return;
	}
	var html = '<table><thead><tr><th>' + jawnosT('Date') + '</th><th>' + jawnosT('Actual high') + '</th><th>' + jawnosT('Actual low') + '</th><th>' + jawnosT('Actual condition') + '</th><th>' + jawnosT('Forecast high') + '</th><th>' + jawnosT('Forecast low') + '</th><th>' + jawnosT('Forecast condition') + '</th><th>' + jawnosT('High error') + '</th><th>' + jawnosT('Low error') + '</th><th>' + jawnosT('Match') + '</th></tr></thead><tbody>';
	for (var i = 0; i < rows.length; i++) {
		var row = rows[i] || {};
		var a = row.actual || {};
		var f = (row.forecasts || {})[lead] || {};
		var match = f.condition_match === 1
			? '<span class="weather_match">✓</span>'
			: (f.condition_match === 0 ? '<span class="weather_miss">✗</span>' : '—');
		html += '<tr>'
			+ '<td>' + weatherEsc(weatherDayLabel(row.date)) + '</td>'
			+ '<td>' + weatherTemp(a.high) + '</td>'
			+ '<td>' + weatherTemp(a.low) + '</td>'
			+ '<td>' + weatherEsc(a.condition || '') + '</td>'
			+ '<td>' + weatherTemp(f.high) + '</td>'
			+ '<td>' + weatherTemp(f.low) + '</td>'
			+ '<td>' + weatherEsc(f.condition || '') + '</td>'
			+ '<td>' + weatherAccuracySigned(f.high_error) + '</td>'
			+ '<td>' + weatherAccuracySigned(f.low_error) + '</td>'
			+ '<td>' + match + '</td>'
			+ '</tr>';
	}
	html += '</tbody></table>';
	$detail.html(html);
}

function weatherAccuracySigned(value) {
	if (value === undefined || value === null || value === '') { return '—'; }
	var n = parseFloat(value);
	if (isNaN(n)) { return String(value); }
	return (n > 0 ? '+' : '') + (Math.round(n * 10) / 10) + '°';
}
