// The Weather app: the page is a shell; this asks the manager for one
// coordinate. The coordinate is the selected house device's latest real GPS
// fix, or the browser's own location when the person asks for it. Nothing here
// writes a location record.

$(document).on('click', '#weather_toggle', function() {
	weatherMaker();
});

var weatherLastLocation = null;
var weatherHistoryData = null;
var weatherAccuracyData = null;
var weatherHistoryLoaded = false;
var weatherAccuracyLoaded = false;
var weatherLoading = false;

$(document).on('click', '.weather_tab', function() {
	weatherShowTab($(this).attr('data-tab'));
});
$(document).on('change', '#weather_history_source, #weather_history_range', function() {
	weatherHistoryLoad();
});
$(document).on('click', '#weather_history_backfill', function() {
	weatherHistoryBackfill();
});
$(document).on('change', '#weather_accuracy_source, #weather_accuracy_range', function() {
	weatherAccuracyLoad(true);
});
$(document).on('change', '#weather_accuracy_lead', function() {
	if (weatherAccuracyData) { weatherAccuracyDetailRender(weatherAccuracyData); }
});

function weatherMaker(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/weather',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			if (!response) { return; }
			windowMaker(response);
			weatherBind();
			weatherLoad();
		}
	});
}

function weatherBind() {
	var $w = $('.wind[app="weather"]');
	if (!$w.length || $w.data('weather_bound')) { return; }
	$w.data('weather_bound', 1);
	weatherDeleteState();
	$w.on('change', '#weather_device', function() {
		$w.find('#weather_lat').val('');
		$w.find('#weather_lon').val('');
		$w.find('#weather_source').val('');
		weatherHistoryLoaded = false;
		weatherAccuracyLoaded = false;
		weatherDeleteState();
		// The Automations tab is scoped to this picker: a new place has its own
		// list, so reload rather than keep the previous place's rules on screen.
		if (typeof weatherAutomationLoad === 'function' && weatherAutomationLoaded) { weatherAutomationLoad(); }
		weatherLoad(true);
	});
	$w.on('click', '#weather_location_delete', function() {
		weatherLocationDelete($w.find('#weather_device').val(), this, '#weather_status');
	});
	$w.on('click', '#weather_location_anchor', function() {
		weatherLocationAnchor($w.find('#weather_device').val(), this, '#weather_status');
	});
	$w.on('click', '#weather_refresh', function() { weatherLoad(true); });
	$w.on('click', '#weather_browser', function() { weatherBrowser(); });
	$w.on('click', '#weather_check_here', function() { weatherCheckHere(); });
	$w.on('click', '#weather_daily .weather_day_toggle', function() { weatherDayToggle(this); });
	$w.on('keydown', '#weather_daily .weather_day_toggle', function(e) {
		if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar') {
			e.preventDefault();
			weatherDayToggle(this);
		}
	});
}

// Delete a saved place, twice: the first press asks, the second removes it. A
// rule that named it keeps the key, and the Automations tab calls it a deleted
// place rather than quietly widening to anywhere.
function weatherLocationDeleteConfirm(button, action) {
	var $b = $(button);
	if ($b.data('weather_delete_confirm')) {
		clearTimeout($b.data('weather_delete_timer'));
		$b.removeData('weather_delete_confirm').text(jawnosT('Delete'));
		action();
		return;
	}
	$b.data('weather_delete_confirm', 1).text(jawnosT('Delete?'));
	$b.data('weather_delete_timer', setTimeout(function() {
		$b.removeData('weather_delete_confirm').text(jawnosT('Delete'));
	}, 5000));
}

function weatherLocationDelete(uuid, button, statusSelector) {
	var $w = $('.wind[app="weather"]').last();
	uuid = uuid || '';
	statusSelector = statusSelector || '#weather_status';
	if (uuid.indexOf('loc:') !== 0) {
		$w.find(statusSelector).text(jawnosT('Choose a saved place to delete.'));
		return;
	}
	weatherLocationDeleteConfirm(button, function() {
		$.ajax({
			url: '/manager/weather/location/delete',
			type: 'POST',
			data: { uuid: uuid.slice(4) },
			dataType: 'json',
			success: function(response) {
				if (!response || response.error) {
					$w.find(statusSelector).text((response && response.error) || jawnosT('The location was not deleted.'));
					return;
				}
				if (typeof weatherLocationOptions === 'function') {
					weatherLocationOptions($w, response.locations || [], response.labels || {});
				}
				// The home plate's entry sits above the Places group; deleting the
				// place it names must take that entry too, or the picker keeps a
				// value the route can no longer resolve.
				var $home = $w.find('#weather_device option[data-home="1"]');
				if ($home.length && $home.val() === uuid) { $home.remove(); }
				if (typeof weatherAutomationLoad === 'function' && $w.find('#weather_automation_list').length) {
					weatherAutomationLoad();
				}
				if (!($w.find('#weather_device').val() || '')) {
					$w.find('#weather_device option').first().prop('selected', true);
					weatherLoad(true);
				}
				weatherDeleteState();
				var n = response.deleted_readings || 0;
				$w.find(statusSelector).text(n
					? jawnosT('Location and its readings deleted.')
					: jawnosT('Location deleted.'));
			},
			error: function() {
				$w.find(statusSelector).text(jawnosT('The location was not deleted.'));
			}
		});
	});
}

// Anchor keeps the place recording after the phone leaves. It is a fact on the
// place record, so the scheduled pass reads it even when no device is there.
function weatherLocationAnchor(uuid, button, statusSelector) {
	var $w = $('.wind[app="weather"]').last();
	uuid = uuid || '';
	statusSelector = statusSelector || '#weather_status';
	if (uuid.indexOf('loc:') !== 0) {
		$w.find(statusSelector).text(jawnosT('Choose a place to anchor.'));
		return;
	}
	var $opt = $w.find('#weather_device option:selected');
	var anchor = $opt.attr('data-anchor') === '1' ? 0 : 1;
	$.ajax({
		url: '/manager/weather/location/anchor',
		type: 'POST',
		data: { uuid: uuid.slice(4), anchor: anchor },
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				$w.find(statusSelector).text((response && response.error) || jawnosT('The place was not anchored.'));
				return;
			}
			$opt.attr('data-anchor', response.anchor ? 1 : 0);
			weatherDeleteState();
			$w.find(statusSelector).text(response.anchor
				? jawnosT('Recording here even when you leave.')
				: jawnosT('Only checked when you ask.'));
		},
		error: function() {
			$w.find(statusSelector).text(jawnosT('The place was not anchored.'));
		}
	});
}

function weatherDeleteState() {
	var $w = $('.wind[app="weather"]').last();
	var value = $w.find('#weather_device').val() || '';
	$w.find('#weather_location_delete').prop('disabled', value.indexOf('loc:') !== 0);
	$w.find('#weather_location_sources').prop('disabled', !value.length);
	var $opt = $w.find('#weather_device option:selected');
	var home = $opt.attr('data-home') === '1';
	var anchor = $opt.attr('data-anchor') === '1';
	$w.find('#weather_location_anchor')
		.prop('disabled', home || value.indexOf('loc:') !== 0)
		.text(home ? jawnosT('Always checked') : (anchor ? jawnosT('Anchored') : jawnosT('Anchor')));
	$w.find('#weather_automation_location, #weather_measure_location').each(function() {
		var id = $(this).attr('id');
		var chosen = $(this).val() || '';
		$w.find('.weather_location_delete[data-target="' + id + '"]').prop('disabled', chosen.indexOf('loc:') !== 0);
	});
}

function weatherLoad(force) {
	var $w = $('.wind[app="weather"]');
	if (!$w.length) { return; }
	// A refresh and the window manager can both ask at once; the second is the
	// same reading, so let the first finish. A stuck request times out.
	if (weatherLoading) { return; }
	weatherLoading = true;
	var data = {
		device: $w.find('#weather_device').val() || 'me',
		timestamp: Date.now()
	};
	if (force) { data.force = 1; }
	var lat = $w.find('#weather_lat').val();
	var lon = $w.find('#weather_lon').val();
	if (lat && lon) {
		data.lat = lat;
		data.lon = lon;
		data.source = $w.find('#weather_source').val() || 'Browser location';
	}
	$w.find('#weather_status').text(jawnosT('Loading…'));
	$w.find('#weather_error').hide();
	$.ajax({
		url: '/manager/weather/data',
		type: 'GET',
		data: data,
		dataType: 'json',
		timeout: 20000,
		success: function(response) { weatherLoading = false; weatherRender(response); },
		error: function() { weatherLoading = false; weatherError(jawnosT('Weather is unavailable right now.')); }
	});
}

function weatherBrowser() {
	var $w = $('.wind[app="weather"]');
	if (!navigator.geolocation) {
		weatherError(jawnosT('This browser cannot report a location.'));
		return;
	}
	$w.find('#weather_status').text(jawnosT('Asking this browser…'));
	navigator.geolocation.getCurrentPosition(function(pos) {
		$w.find('#weather_lat').val(pos.coords.latitude);
		$w.find('#weather_lon').val(pos.coords.longitude);
		$w.find('#weather_source').val(jawnosT('Browser location'));
		weatherLoad(true);
	}, function() {
		weatherError(jawnosT('This browser did not share a location.'));
	}, { enableHighAccuracy: true, timeout: 15000, maximumAge: 60000 });
}

// The hourly pass keeps the home plate, not the phone. Away from every saved
// place the page offers one check at the fix instead of quietly saving the
// drive as a place; the reading is kept and the new place joins the picker.
function weatherCheckHere() {
	var $w = $('.wind[app="weather"]').last();
	if (!$w.length) { return; }
	var value = $w.find('#weather_device').val() || 'me';
	var lat = $w.find('#weather_lat').val();
	var lon = $w.find('#weather_lon').val();
	var browser = !!(lat && lon);
	if (!browser) {
		var $opt = $w.find('#weather_device option:selected');
		lat = $opt.attr('data-lat') || '';
		lon = $opt.attr('data-lon') || '';
	}
	if (!lat || !lon) {
		$w.find('#weather_status').text(jawnosT('No location to check.'));
		return;
	}
	// A browser coordinate is this machine's place even when the picker still
	// shows a saved place; a picked device keeps its own key.
	var location = browser ? '' : (value.indexOf('loc:') === 0 ? value : (value === 'me' ? '' : 'dev:' + value));
	$w.find('#weather_status').text(jawnosT('Checking…'));
	$.ajax({
		url: '/manager/weather/observe',
		type: 'POST',
		data: { lat: lat, lon: lon, location: location },
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				$w.find('#weather_status').text((response && response.error) || jawnosT('The weather could not be checked.'));
				return;
			}
			if (response.locations && typeof weatherLocationOptions === 'function') {
				weatherLocationOptions($w, response.locations, response.labels || {});
				if (response.place_key) { $w.find('#weather_device').val(response.place_key); }
			}
			$w.find('#weather_check_here').hide();
			$w.find('#weather_status').text(jawnosT('Reading kept.'));
			weatherLoad(true);
		},
		error: function() {
			$w.find('#weather_status').text(jawnosT('The weather could not be checked.'));
		}
	});
}

// The provider names the place it read for. Put that name in the picker so the
// house reads places, not devices: a saved place the person named keeps its
// name, while a group shown as "This device" becomes its city once we know it.
function weatherPlaceLabel(data) {
	var $w = $('.wind[app="weather"]').last();
	if (!data || !data.location_name) { return; }
	var $option = $w.find('#weather_device option:selected');
	if (!$option.length) { return; }
	var value = $option.val() || '';
	if (value.indexOf('loc:') === 0) { return; }
	var seen = $option.attr('data-seen') || '';
	$option.text(data.location_name + (seen ? ' — ' + seen : ''));
}

function weatherPlaceText(data) {
	var source = data.source || '';
	if (data.provider === 'closest' && data.pws) {
		var station = (data.pws.other && data.pws.other.name) || (data.pws.barometer && data.pws.barometer.name) || '';
		if (station) {
			return source && source !== station ? station + ' · ' + source : station;
		}
	}
	var place = data.location_name || '';
	return source ? (place ? (place + ' · ' + source) : source) : place;
}

function weatherRender(data) {
	var $w = $('.wind[app="weather"]');
	if (!data || data.error) {
		weatherError((data && data.error) || jawnosT('Weather is unavailable right now.'));
		return;
	}
	$w.find('#weather_error').hide();
	var cur = data.current || {};
	if (data.lat !== undefined && data.lon !== undefined) {
		weatherLastLocation = { lat: data.lat, lon: data.lon, city: data.location_name || '', region: data.location_region || data.region || '', location: data.source_location || '' };
	}
	$w.find('#weather_place').text(weatherPlaceText(data));
	$w.find('#weather_check_here').toggle(!!data.needs_place);
	weatherPlaceLabel(data);
	$w.find('#weather_temp').text(weatherTemp(cur.temperature));
	$w.find('#weather_cond').text(cur.condition || '');
	$w.find('#weather_glyph').text(cur.glyph || '🌡️');
	var stats = [];
	function add(label, value) {
		if (value === undefined || value === null || value === '') { return; }
		stats.push('<div class="weather_stat"><b>' + weatherEsc(jawnosT(label)) + '</b>' + weatherEsc(value) + '</div>');
	}
	add('Feels like', weatherTemp(cur.feels_like));
	if (cur.high !== undefined && cur.high !== null && cur.low !== undefined && cur.low !== null) {
		add('High / low', weatherTemp(cur.high) + ' / ' + weatherTemp(cur.low));
	}
	if (cur.wind_speed !== undefined && cur.wind_speed !== null) {
		add('Wind', weatherNum(cur.wind_speed) + ' ' + (cur.wind_unit || 'km/h') + (cur.wind_direction ? ' ' + cur.wind_direction : ''));
	}
	if (cur.wind_gust !== undefined && cur.wind_gust !== null) {
		add('Gusts', weatherNum(cur.wind_gust) + ' ' + (cur.wind_unit || 'km/h'));
	}
	if (cur.humidity !== undefined && cur.humidity !== null) {
		add('Humidity', weatherNum(cur.humidity) + '%');
	}
	if (cur.pressure !== undefined && cur.pressure !== null) {
		add('Pressure', weatherNum(cur.pressure) + ' ' + (cur.pressure_unit || ''));
	}
	if (cur.dew_point !== undefined && cur.dew_point !== null) {
		add('Dew point', weatherTemp(cur.dew_point));
	}
	if (cur.visibility !== undefined && cur.visibility !== null) {
		add('Visibility', weatherNum(cur.visibility) + ' km');
	}
	if (cur.uv !== undefined && cur.uv !== null && cur.uv !== '') {
		add('UV', cur.uv);
	}
	add('Observed', weatherObserved(cur));
	$w.find('#weather_stats').html(stats.join(''));
	weatherSourceDetail(data);
	weatherAlerts(data.alerts || []);
	weatherHours(data.hourly || []);
	weatherDays(data.daily || [], data.hourly || []);
	var status = data.provider_label || '';
	if (data.forecast_provider_label) {
		status += ' · ' + jawnosT('Forecast from') + ' ' + data.forecast_provider_label;
		if (data.provider === 'closest' && data.location_name) { status += ' (' + data.location_name + ')'; }
	}
	if (data.location_distance_km) { status += ' · ' + Math.round(data.location_distance_km) + ' km'; }
	status += ' · ' + jawnosT('Updated') + ' ' + weatherTime(data.fetched_at || Date.now());
	if (data.hourly_provider) { status += ' · ' + jawnosT('Hourly from') + ' ' + (data.hourly_provider_label || data.hourly_provider); }
	if (data.daily_provider) { status += ' · ' + jawnosT('Later days from') + ' ' + (data.daily_provider_label || data.daily_provider); }
	$w.find('#weather_status').text(status);
}

function weatherSourceDetail(data) {
	var $w = $('.wind[app="weather"]').last();
	var parts = [];
	function line(label, station) {
		if (!station) { return; }
		var bits = [];
		if (station.name) { bits.push(station.name); }
		if (station.id && station.id !== station.name) { bits.push(station.id); }
		if (station.distance_km !== undefined && station.distance_km !== null) {
			bits.push(weatherNum(station.distance_km) + ' km');
		}
		parts.push('<span><b>' + weatherEsc(jawnosT(label)) + ':</b> ' + weatherEsc(bits.join(' · ')) + '</span>');
	}
	if (data.pws) {
		line('Barometer', data.pws.barometer);
		line('Other readings', data.pws.other);
	}
	if (data.source_note) {
		parts.push('<span>' + weatherEsc(data.source_note) + '</span>');
	}
	$w.find('#weather_source_detail').html(parts.join('')).toggle(parts.length > 0);
}

function weatherAlerts(alerts) {
	var $w = $('.wind[app="weather"]');
	var html = '';
	for (var i = 0; i < alerts.length; i++) {
		var a = alerts[i] || {};
		var meta = [];
		if (a.region) { meta.push(weatherEsc(a.region)); }
		if (a.issued_at) { meta.push(jawnosT('Issued') + ' ' + weatherTime(a.issued_at)); }
		if (a.expires_at) { meta.push(jawnosT('Ends') + ' ' + weatherTime(a.expires_at)); }
		html += '<div class="weather_alert">'
			+ '<b>' + weatherEsc(a.title || jawnosT('Weather alert')) + '</b>'
			+ (a.text ? '<div class="weather_alert_text">' + weatherEsc(a.text) + '</div>' : '')
			+ (meta.length ? '<div class="weather_alert_meta">' + meta.join(' · ') + '</div>' : '')
			+ (a.url ? '<a class="weather_alert_more" href="' + weatherEsc(a.url) + '" target="_blank" rel="noopener">' + jawnosT('More details') + '</a>' : '')
			+ '</div>';
	}
	$w.find('#weather_alerts').html(html).toggle(!!html);
}

function weatherHours(hours) {
	var $w = $('.wind[app="weather"]');
	var html = '';
	if (!hours.length) {
		$w.find('#weather_hourly').html('<span class="weather_muted">' + weatherEsc(jawnosT('Hourly forecast is unavailable for this location.')) + '</span>');
		return;
	}
	for (var i = 0; i < hours.length && i < 24; i++) {
		var h = hours[i] || {};
		var label = h.time_text ? weatherHourLabel(h.time_text) : weatherTime(h.time);
		html += '<div class="weather_hour">'
			+ '<div>' + weatherEsc(label) + '</div>'
			+ '<div class="weather_hour_glyph">' + weatherEsc(h.glyph || '•') + '</div>'
			+ '<div class="weather_hour_temp">' + weatherTemp(h.temperature) + '</div>'
			+ (h.precip_prob !== undefined && h.precip_prob !== null ? '<div class="weather_hour_precip">' + weatherNum(h.precip_prob) + '%</div>' : '')
			+ '</div>';
	}
	$w.find('#weather_hourly').html(html);
}

function weatherDays(days, hours) {
	var $w = $('.wind[app="weather"]');
	var byDate = weatherHoursByDate(hours || []);
	var html = '';
	for (var i = 0; i < days.length && i < 14; i++) {
		var d = days[i] || {};
		var label = d.date ? weatherDayName(d.date) : (d.label || '');
		var stamp = d.date ? weatherDateStamp(d.date) : '';
		var temps = (d.high !== undefined && d.high !== null ? weatherTemp(d.high) : '—')
			+ (d.low !== undefined && d.low !== null ? ' / ' + weatherTemp(d.low) : '');
		var text = d.condition || d.text || '';
		if (d.precip_prob !== undefined && d.precip_prob !== null) { text += (text ? ' · ' : '') + weatherNum(d.precip_prob) + '%'; }
		var detail = weatherDayDetail(d, (d.date && byDate[d.date]) || []);
		var row = '<div class="weather_day_label"><span>' + weatherEsc(label) + '</span>'
			+ (stamp ? '<span class="weather_day_stamp">' + weatherEsc(stamp) + '</span>' : '') + '</div>'
			+ '<div class="weather_day_glyph">' + weatherEsc(d.glyph || '•') + '</div>'
			+ '<div class="weather_day_temps">' + weatherEsc(temps) + '</div>'
			+ '<div class="weather_day_text">' + weatherEsc(text) + '</div>';
		if (!detail) {
			html += '<div class="weather_day_wrap"><div class="weather_day">' + row + '</div></div>';
			continue;
		}
		var id = 'weather_day_detail_' + i;
		html += '<div class="weather_day_wrap">'
			+ '<div class="weather_day weather_day_toggle" role="button" tabindex="0" aria-expanded="false" aria-controls="' + id + '">' + row + '</div>'
			+ '<div class="weather_day_detail" id="' + id + '">' + detail + '</div>'
			+ '</div>';
	}
	$w.find('#weather_daily').html(html);
}

// A day opens when it has more to say than the row: the hours it was read
// for, or the sunrise, sunset, UV and wind the provider sent with the day.
// Clicking the row again hides it.
function weatherDayDetail(day, hours) {
	var stats = [];
	function stat(label, value) {
		if (value === undefined || value === null || value === '') { return; }
		stats.push('<div class="weather_stat"><b>' + weatherEsc(jawnosT(label)) + '</b>' + weatherEsc(value) + '</div>');
	}
	if (day.precip_prob !== undefined && day.precip_prob !== null) {
		stat('Chance of precipitation', weatherNum(day.precip_prob) + '%');
	}
	if (day.wind_speed !== undefined && day.wind_speed !== null) {
		stat('Wind', weatherNum(day.wind_speed) + ' ' + (day.wind_unit || 'km/h') + (day.wind_direction ? ' ' + day.wind_direction : ''));
	}
	if (day.uv !== undefined && day.uv !== null && day.uv !== '') { stat('UV', day.uv); }
	if (day.sunrise) { stat('Sunrise', weatherHourLabel(day.sunrise)); }
	if (day.sunset) { stat('Sunset', weatherHourLabel(day.sunset)); }
	if (!hours.length && !stats.length) { return ''; }
	var html = '';
	var rain = weatherPrecipWindows(hours);
	var trend = weatherTempTrend(hours);
	if (rain || trend) {
		html += '<div class="weather_day_summary">'
			+ (rain ? '<span>' + weatherEsc(rain) + '</span>' : '')
			+ (trend ? '<span>' + weatherEsc(trend) + '</span>' : '')
			+ '</div>';
	}
	var chart = weatherDayChart(hours);
	if (chart) { html += '<div class="weather_day_chart">' + chart + '</div>'; }
	if (hours.length) {
		html += '<div class="weather_day_hours">';
		for (var i = 0; i < hours.length; i++) {
			var h = hours[i] || {};
			var wet = weatherWet(h);
			var time = h.time_text ? weatherHourLabel(h.time_text) : weatherTime(h.time);
			html += '<div class="weather_hour' + (wet ? ' weather_hour_wet' : '') + '">'
				+ '<div>' + weatherEsc(time) + '</div>'
				+ '<div class="weather_hour_glyph">' + weatherEsc(h.glyph || '•') + '</div>'
				+ '<div class="weather_hour_temp">' + weatherTemp(h.temperature) + '</div>'
				+ (h.precip_prob !== undefined && h.precip_prob !== null ? '<div class="weather_hour_precip">' + weatherNum(h.precip_prob) + '%</div>' : '')
				+ '</div>';
		}
		html += '</div>';
	}
	if (stats.length) { html += '<div class="weather_day_meta">' + stats.join('') + '</div>'; }
	return html;
}

// The hourly forecast is one list for the whole fortnight; the day a person
// opened only wants its own hours. The provider's time text is the place's
// local clock, so keep its date rather than the browser's.
function weatherHoursByDate(hours) {
	var by = {};
	for (var i = 0; i < hours.length; i++) {
		var h = hours[i] || {};
		var date = weatherHourDate(h);
		if (!date) { continue; }
		(by[date] || (by[date] = [])).push(h);
	}
	return by;
}

function weatherHourDate(h) {
	var m = String((h && h.time_text) || '').match(/^(\d{4}-\d{2}-\d{2})/);
	if (m) { return m[1]; }
	var ms = h && h.time ? Number(h.time) : 0;
	if (!ms) { return ''; }
	var d = new Date(ms);
	if (isNaN(d.getTime())) { return ''; }
	return d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
}

// Thirty percent is the app's line for "likely": the day summary, the wet
// hour cards and the chart's shading all read it from here.
function weatherWet(h) {
	var p = parseFloat(h && h.precip_prob);
	return !isNaN(p) && p >= 30;
}

// When the rain (or snow) is likely: each run of hours at or above thirty
// percent reads as one window, with the peak chance beside it.
function weatherPrecipWindows(hours) {
	var runs = [];
	var run = null;
	for (var i = 0; i < hours.length; i++) {
		var h = hours[i] || {};
		if (weatherWet(h)) {
			var p = parseFloat(h.precip_prob);
			if (!run) { run = { first: h, last: h, max: p }; runs.push(run); }
			else {
				run.last = h;
				if (p > run.max) { run.max = p; }
			}
		} else {
			run = null;
		}
	}
	if (!runs.length) { return ''; }
	var parts = [];
	for (var j = 0; j < runs.length; j++) {
		parts.push(weatherHourLabel(runs[j].first.time_text) + '–' + weatherHourEndLabel(runs[j].last.time_text) + ' · ' + weatherNum(runs[j].max) + '%');
	}
	return jawnosT('Precipitation likely') + ' ' + parts.join(', ');
}

// An hour's reading covers the hour that starts with it, so the window ends
// when the next hour begins.
function weatherHourEndLabel(text) {
	var m = String(text || '').match(/T(\d{2}):(\d{2})/);
	if (!m) { return String(text || ''); }
	var h = (parseInt(m[1], 10) + 1) % 24;
	var suffix = h >= 12 ? 'PM' : 'AM';
	var n = h % 12;
	if (!n) { n = 12; }
	return n + ':' + m[2] + ' ' + suffix;
}

function weatherTempTrend(hours) {
	var low = null;
	var high = null;
	for (var i = 0; i < hours.length; i++) {
		var h = hours[i] || {};
		var t = parseFloat(h.temperature);
		if (isNaN(t)) { continue; }
		if (!low || t < low.t) { low = { t: t, h: h }; }
		if (!high || t > high.t) { high = { t: t, h: h }; }
	}
	if (!low || !high || low.t === high.t) { return ''; }
	return jawnosT('Warmest') + ' ' + weatherHourLabel(high.h.time_text) + ' ' + weatherTemp(high.t)
		+ ' · ' + jawnosT('Coolest') + ' ' + weatherHourLabel(low.h.time_text) + ' ' + weatherTemp(low.t);
}

// A compact line for the day: one point an hour, so the rise and fall reads at
// a glance above the hour cards. Two readings are needed to draw a line.
function weatherDayChart(hours) {
	var values = [];
	for (var i = 0; i < hours.length; i++) {
		var v = parseFloat(hours[i] && hours[i].temperature);
		if (!isNaN(v)) { values.push(v); }
	}
	if (values.length < 2 || hours.length < 2) { return ''; }
	var min = Math.min.apply(null, values);
	var max = Math.max.apply(null, values);
	var pad = Math.max(1, (max - min) * 0.15);
	min -= pad;
	max += pad;
	var W = 600, H = 120, L = 34, R = 10, T = 12, B = 22;
	var plotW = W - L - R, plotH = H - T - B;
	function x(i) { return L + plotW * i / (hours.length - 1); }
	function y(v) { return T + (max - v) / (max - min) * plotH; }
	var points = [];
	var dots = '';
	for (var j = 0; j < hours.length; j++) {
		var t = parseFloat(hours[j] && hours[j].temperature);
		if (isNaN(t)) { continue; }
		var sx = x(j), sy = y(t);
		points.push(sx + ',' + sy);
		dots += '<circle cx="' + sx + '" cy="' + sy + '" r="2" fill="#4a90d9"/>';
	}
	if (points.length < 2) { return ''; }
	var spacing = plotW / (hours.length - 1);
	var wet = '';
	for (var k = 0; k < hours.length; k++) {
		if (!weatherWet(hours[k])) { continue; }
		var left = k === 0 ? L : x(k) - spacing / 2;
		var right = k === hours.length - 1 ? (W - R) : x(k) + spacing / 2;
		wet += '<rect class="weather_day_chart_wet" x="' + left + '" y="' + T + '" width="' + (right - left) + '" height="' + plotH + '"/>';
	}
	var first = weatherHourLabel(hours[0] && hours[0].time_text) || weatherTime(hours[0] && hours[0].time);
	var last = weatherHourLabel(hours[hours.length - 1] && hours[hours.length - 1].time_text) || weatherTime(hours[hours.length - 1] && hours[hours.length - 1].time);
	var svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + weatherEsc(jawnosT('Hourly temperature for the day, shaded where precipitation is likely')) + '">';
	svg += wet;
	svg += '<line x1="' + L + '" y1="' + T + '" x2="' + L + '" y2="' + (T + plotH) + '" stroke="currentColor" opacity=".22"/>';
	svg += '<line x1="' + L + '" y1="' + (T + plotH) + '" x2="' + (W - R) + '" y2="' + (T + plotH) + '" stroke="currentColor" opacity=".12"/>';
	svg += '<text x="' + (L - 4) + '" y="' + (y(max) + 4) + '" text-anchor="end" font-size="10" fill="currentColor" opacity=".6">' + Math.round(max) + '°</text>';
	svg += '<text x="' + (L - 4) + '" y="' + (y(min) + 4) + '" text-anchor="end" font-size="10" fill="currentColor" opacity=".6">' + Math.round(min) + '°</text>';
	svg += '<polyline fill="none" stroke="#4a90d9" stroke-width="2" points="' + points.join(' ') + '"/>';
	svg += dots;
	svg += '<text x="' + L + '" y="' + (H - 4) + '" font-size="10" fill="currentColor" opacity=".6">' + weatherEsc(first) + '</text>';
	svg += '<text x="' + (W - R) + '" y="' + (H - 4) + '" text-anchor="end" font-size="10" fill="currentColor" opacity=".6">' + weatherEsc(last) + '</text>';
	svg += '</svg>';
	return svg;
}

function weatherDayToggle(row) {
	var $row = $(row);
	var $detail = $row.next('.weather_day_detail');
	if (!$detail.length) { return; }
	var open = !$detail.hasClass('open');
	$detail.toggleClass('open', open);
	$row.attr('aria-expanded', open ? 'true' : 'false');
}

function weatherError(message) {
	var $w = $('.wind[app="weather"]');
	$w.find('#weather_status').text('');
	$w.find('#weather_error').text(message || jawnosT('Weather is unavailable right now.')).show();
}

function weatherTemp(v) {
	if (v === undefined || v === null || v === '') { return '—'; }
	var n = parseFloat(v);
	if (isNaN(n)) { return String(v); }
	return (Math.round(n * 10) / 10) + '°';
}

function weatherNum(v) {
	if (v === undefined || v === null || v === '') { return ''; }
	var n = parseFloat(v);
	if (isNaN(n)) { return String(v); }
	return Math.round(n * 10) / 10;
}

function weatherTime(ms) {
	if (!ms) { return ''; }
	var d = new Date(Number(ms));
	if (isNaN(d.getTime())) { return ''; }
	return d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

function weatherObserved(cur) {
	if (cur && cur.observed_at) { return weatherTime(cur.observed_at); }
	if (cur && cur.observed_text) { return String(cur.observed_text).replace('T', ' ').slice(0, 16); }
	return '';
}

function weatherHourLabel(text) {
	var m = String(text).match(/T(\d{2}):(\d{2})/);
	if (!m) { return text; }
	var h = parseInt(m[1], 10);
	var suffix = h >= 12 ? 'PM' : 'AM';
	h = h % 12;
	if (!h) { h = 12; }
	return h + ':' + m[2] + ' ' + suffix;
}

function weatherDayName(date) {
	var d = new Date(String(date) + 'T12:00:00');
	if (isNaN(d.getTime())) { return String(date); }
	var name = d.toLocaleDateString([], { weekday: 'long' });
	var today = new Date();
	today.setHours(12, 0, 0, 0);
	var days = Math.round((d.getTime() - today.getTime()) / 86400000);
	if (days >= 7) { return jawnosT('Next') + ' ' + name; }
	return name;
}

function weatherDateStamp(date) {
	var parts = String(date).match(/^(\d{4})-(\d{2})-(\d{2})$/);
	if (!parts) { return ''; }
	return parts[2] + '/' + parts[3] + '/' + parts[1];
}

function weatherEsc(s) {
	return $('<div>').text(s === undefined || s === null ? '' : String(s)).html();
}
