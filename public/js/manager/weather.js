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
	$w.on('change', '#weather_device', function() {
		$w.find('#weather_lat').val('');
		$w.find('#weather_lon').val('');
		$w.find('#weather_source').val('');
		weatherLoad(true);
	});
	$w.on('click', '#weather_refresh', function() { weatherLoad(true); });
	$w.on('click', '#weather_browser', function() { weatherBrowser(); });
}

function weatherLoad(force) {
	var $w = $('.wind[app="weather"]');
	if (!$w.length) { return; }
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
		success: function(response) { weatherRender(response); },
		error: function() { weatherError(jawnosT('Weather is unavailable right now.')); }
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

function weatherRender(data) {
	var $w = $('.wind[app="weather"]');
	if (!data || data.error) {
		weatherError((data && data.error) || jawnosT('Weather is unavailable right now.'));
		return;
	}
	$w.find('#weather_error').hide();
	var cur = data.current || {};
	if (data.lat !== undefined && data.lon !== undefined) {
		weatherLastLocation = { lat: data.lat, lon: data.lon, city: data.location_name || '', region: data.location_region || data.region || '' };
	}
	var place = data.location_name || '';
	if (data.source) { place = place ? (place + ' · ' + data.source) : data.source; }
	$w.find('#weather_place').text(place);
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
	weatherAlerts(data.alerts || []);
	weatherHours(data.hourly || []);
	weatherDays(data.daily || []);
	var status = data.provider_label || '';
	if (data.location_distance_km) { status += ' · ' + Math.round(data.location_distance_km) + ' km'; }
	status += ' · ' + jawnosT('Updated') + ' ' + weatherTime(data.fetched_at || Date.now());
	if (data.hourly_provider) { status += ' · ' + jawnosT('Hourly from') + ' ' + (data.hourly_provider_label || data.hourly_provider); }
	$w.find('#weather_status').text(status);
}

function weatherAlerts(alerts) {
	var $w = $('.wind[app="weather"]');
	var html = '';
	for (var i = 0; i < alerts.length; i++) {
		var a = alerts[i] || {};
		html += '<div class="weather_alert"><b>' + weatherEsc(a.title || 'Weather alert') + '</b>' + weatherEsc(a.text || '') + '</div>';
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

function weatherDays(days) {
	var $w = $('.wind[app="weather"]');
	var html = '';
	for (var i = 0; i < days.length && i < 7; i++) {
		var d = days[i] || {};
		var label = d.label || (d.date ? weatherDayLabel(d.date) : '');
		var temps = (d.high !== undefined && d.high !== null ? weatherTemp(d.high) : '—')
			+ (d.low !== undefined && d.low !== null ? ' / ' + weatherTemp(d.low) : '');
		var text = d.condition || d.text || '';
		if (d.precip_prob !== undefined && d.precip_prob !== null) { text += (text ? ' · ' : '') + weatherNum(d.precip_prob) + '%'; }
		html += '<div class="weather_day">'
			+ '<div>' + weatherEsc(label) + '</div>'
			+ '<div class="weather_day_glyph">' + weatherEsc(d.glyph || '•') + '</div>'
			+ '<div class="weather_day_temps">' + weatherEsc(temps) + '</div>'
			+ '<div class="weather_day_text">' + weatherEsc(text) + '</div>'
			+ '</div>';
	}
	$w.find('#weather_daily').html(html);
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

function weatherDayLabel(date) {
	var d = new Date(String(date) + 'T12:00:00');
	if (isNaN(d.getTime())) { return date; }
	return d.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
}

function weatherEsc(s) {
	return $('<div>').text(s === undefined || s === null ? '' : String(s)).html();
}
