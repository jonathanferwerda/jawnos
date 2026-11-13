// The Weather sources dialog. A place keeps one choice: Closest (the nearest
// station's barometer, the next nearest station's other readings), a national
// service, Open-Meteo, or one named Weather Underground station. The choice is
// a fact about the place, so the home plate can read the local stations while a
// phone on a trip reads the model.
var weatherSourcesData = null;
var weatherSourcesKeyCleared = false;

$(document).on('click', '#weather_location_sources', function() {
	weatherSourcesOpen();
});
$(document).on('click', '#weather_sources_cancel', function() {
	weatherSourcesClose();
});
$(document).on('click', '#weather_sources_save', function() {
	weatherSourcesSave();
});
$(document).on('change', 'input[name="weather_source_mode"]', function() {
	weatherSourcesMode();
});
$(document).on('click', '.weather_source_use', function() {
	weatherSourcesUseStation($(this).attr('data-station') || '');
});
$(document).on('click', '#weather_sources_key_clear', function() {
	weatherSourcesKeyCleared = true;
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather_sources_key').val('');
	$w.find('#weather_sources_key_state').text(jawnosT('The key will be removed when you save.'));
});

function weatherSourcesOpen() {
	var $w = $('.wind[app="weather"]').last();
	if (!$w.length) { return; }
	if (typeof weatherPickerClose === 'function') { weatherPickerClose(); }
	weatherSourcesData = null;
	weatherSourcesKeyCleared = false;
	$w.find('#weather_sources_status').text('');
	$w.find('#weather_sources_place').text($w.find('#weather_device option:selected').text() || '');
	$w.find('#weather_sources_key').val('');
	$w.find('#weather_sources_nearby').empty();
	$w.find('#weather_sources_picked').empty();
	$w.find('#weather').addClass('weather_sourcing');
	$w.find('#weather_sources_view').addClass('open');
	weatherSourcesLoad();
}

function weatherSourcesClose() {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather').removeClass('weather_sourcing');
	$w.find('#weather_sources_view').removeClass('open');
	$w.find('#weather_sources_status').text('');
}

function weatherSourcesLocation() {
	var $w = $('.wind[app="weather"]').last();
	var lat = $w.find('#weather_lat').val() || '';
	var lon = $w.find('#weather_lon').val() || '';
	// A browser coordinate is its own source: the data route keys it `browser`,
	// not the device still shown in the picker.
	if (lat && lon) { return { location: 'browser', lat: lat, lon: lon }; }
	var value = $w.find('#weather_device').val() || 'me';
	var $opt = $w.find('#weather_device option:selected');
	return { location: value, lat: $opt.attr('data-lat') || '', lon: $opt.attr('data-lon') || '' };
}

function weatherSourcesLoad() {
	var $w = $('.wind[app="weather"]').last();
	var where = weatherSourcesLocation();
	$w.find('#weather_sources_status').text(jawnosT('Loading…'));
	$.ajax({
		url: '/manager/weather/sources',
		type: 'GET',
		data: { location: where.location, lat: where.lat, lon: where.lon },
		dataType: 'json',
		timeout: 20000,
		success: function(response) {
			if (!response || response.error) {
				$w.find('#weather_sources_status').text((response && response.error) || jawnosT('Weather sources are unavailable.'));
				return;
			}
			weatherSourcesRender(response);
		},
		error: function() {
			$w.find('#weather_sources_status').text(jawnosT('Weather sources are unavailable.'));
		}
	});
}

function weatherSourcesRender(data) {
	var $w = $('.wind[app="weather"]').last();
	weatherSourcesData = data || {};
	var source = weatherSourcesData.source || {};
	var mode = source.mode || 'closest';
	$w.find('input[name="weather_source_mode"][value="' + mode + '"]').prop('checked', true);
	$w.find('#weather_sources_station').val(source.station || '');
	$w.find('#weather_sources_key_state').text(
		weatherSourcesData.key_source === 'setting' ? jawnosT('Key saved')
			: (weatherSourcesData.key_source === 'public' ? jawnosT('Using Weather Underground\'s public key') : jawnosT('No key yet')));
	$w.find('#weather_sources_status').text(weatherSourcesData.note || '');
	weatherSourcesMode();

	var picked = [];
	var closest = weatherSourcesData.closest || null;
	if (closest && closest.barometer) {
		picked.push(weatherSourcesStationLine(jawnosT('Barometer'), closest.barometer));
	}
	if (closest && closest.other) {
		picked.push(weatherSourcesStationLine(jawnosT('Other readings'), closest.other));
	}
	if (!picked.length && weatherSourcesData.has_key && mode === 'closest') {
		picked.push(jawnosT('No local station was found. The usual provider will be used.'));
	}
	$w.find('#weather_sources_picked').html(picked.join('<br>'));

	var nearby = weatherSourcesData.nearest || [];
	var html = '';
	if (nearby.length) {
		html += '<b>' + jawnosT('Nearest stations') + '</b>';
		for (var i = 0; i < nearby.length; i++) {
			var st = nearby[i] || {};
			var parts = [];
			parts.push(weatherEsc(st.name || st.id || ''));
			if (st.id && st.id !== st.name) { parts.push(weatherEsc(st.id)); }
			if (st.distance_km !== undefined && st.distance_km !== null) {
				parts.push(weatherNum(st.distance_km) + ' km');
			}
			var measures = (st.measures || []).join(', ');
			var line = parts.join(' · ');
			if (measures) { line += '<br><span class="weather_muted">' + weatherEsc(jawnosT(measures)) + '</span>'; }
			html += '<div class="weather_source_near">' + line
				+ ' <button type="button" class="weather_source_use" data-station="' + weatherEsc(st.id || '') + '">' + jawnosT('Use') + '</button></div>';
		}
	}
	$w.find('#weather_sources_nearby').html(html);
}

function weatherSourcesStationLine(label, station) {
	var parts = [];
	if (station.name) { parts.push(weatherEsc(station.name)); }
	if (station.id && station.id !== station.name) { parts.push(weatherEsc(station.id)); }
	if (station.distance_km !== undefined && station.distance_km !== null) {
		parts.push(weatherNum(station.distance_km) + ' km');
	}
	return '<b>' + weatherEsc(label) + ':</b> ' + parts.join(' · ');
}

function weatherSourcesMode() {
	var $w = $('.wind[app="weather"]').last();
	var mode = $w.find('input[name="weather_source_mode"]:checked').val() || 'closest';
	$w.find('#weather_sources_station_row').toggle(mode === 'pws');
}

function weatherSourcesUseStation(id) {
	var $w = $('.wind[app="weather"]').last();
	if (!id) { return; }
	$w.find('input[name="weather_source_mode"][value="pws"]').prop('checked', true);
	$w.find('#weather_sources_station').val(id);
	weatherSourcesMode();
	$w.find('#weather_sources_status').text(jawnosT('Press Save to use this station.'));
}

function weatherSourcesSave() {
	var $w = $('.wind[app="weather"]').last();
	var where = weatherSourcesLocation();
	var mode = $w.find('input[name="weather_source_mode"]:checked').val() || 'closest';
	var station = $.trim($w.find('#weather_sources_station').val() || '');
	if (mode === 'pws' && !station) {
		$w.find('#weather_sources_status').text(jawnosT('Choose a station ID.'));
		return;
	}
	var data = {
		location: where.location,
		mode: mode,
		station: station,
		lat: where.lat,
		lon: where.lon,
		force: 1
	};
	var key = $.trim($w.find('#weather_sources_key').val() || '');
	if (key) {
		data.api_key = key;
	}
	else if (weatherSourcesKeyCleared) {
		data.api_key = '';
	}
	$w.find('#weather_sources_status').text(jawnosT('Saving…'));
	$.ajax({
		url: '/manager/weather/sources',
		type: 'POST',
		data: data,
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				$w.find('#weather_sources_status').text((response && response.error) || jawnosT('The sources were not saved.'));
				return;
			}
			weatherSourcesClose();
			$w.find('#weather_status').text(jawnosT('Sources saved.'));
			weatherLoad(true);
		},
		error: function() {
			$w.find('#weather_sources_status').text(jawnosT('The sources were not saved.'));
		}
	});
}
