// ---- the location map -------------------------------------------------------
// Add opens the same canvas map Travel uses, with its provider and measured
// maps. A tap drops the flag; Save stores the coordinate on the Weather app's
// location list, and Cancel returns to the view that was open.
var weatherPickerMap = null;
var weatherPickerPicked = null;

$(document).on('click', '#weather_location_add', function() {
	weatherPickerOpen();
});
$(document).on('click', '#weather_map_cancel', function() {
	weatherPickerClose();
});
$(document).on('click', '#weather_map_save', function() {
	weatherPickerSave();
});

function weatherPickerOpen() {
	var $w = $('.wind[app="weather"]').last();
	if (!$w.length) { return; }
	if (!window.jawnosMap) {
		$w.find('#weather_status').text(jawnosT('The map is unavailable.'));
		return;
	}
	weatherPickerPicked = null;
	$w.find('#weather_map_name').val('');
	$w.find('#weather_map_anchor').prop('checked', false);
	$w.find('#weather_map_save').prop('disabled', true);
	$w.find('#weather_map_status').text('');
	$w.find('#weather').addClass('weather_choosing');
	$w.find('#weather_map_view').addClass('open');
	var start = weatherPickerStart($w);
	setTimeout(function() { weatherPickerBuild($w, start); }, 30);
}

function weatherPickerStart($w) {
	var $option = $w.find('#weather_device option:selected');
	var lat = parseFloat($option.attr('data-lat'));
	var lon = parseFloat($option.attr('data-lon'));
	if (isFinite(lat) && isFinite(lon)) { return { lat: lat, lon: lon }; }
	if (weatherLastLocation && weatherLastLocation.lat !== undefined && weatherLastLocation.lon !== undefined) {
		return { lat: Number(weatherLastLocation.lat), lon: Number(weatherLastLocation.lon) };
	}
	return { lat: 43.0, lon: -81.94 };
}

function weatherPickerBuild($w, start) {
	var canvas = document.getElementById('weather_map_canvas');
	if (!canvas) { return; }
	if (!weatherPickerMap || weatherPickerMap.canvas !== canvas) {
		weatherPickerMap = window.jawnosMap.create('weather_map_canvas', {
			lat: start.lat,
			lon: start.lon,
			z: 12,
			width: function() { return $('#weather_map_canvas').parent().width() || 640; },
			height: function() {
				var h = $('#weather_map_view').height() || 0;
				return Math.max(300, Math.round((h || $(window).height() * 0.55) - 90));
			}
		});
		weatherPickerMap.onMapClick(function(lat, lon) {
			weatherPickerPicked = { lat: lat, lon: lon };
			var $w = $('.wind[app="weather"]').last();
			$w.find('#weather_map_save').prop('disabled', false);
			weatherPickerMap.draw();
		});
		weatherPickerMap.onDraw(weatherPickerFlag);
	}
	$.ajax({
		url: '/manager/travel/continent',
		type: 'GET',
		dataType: 'json',
		success: function(response) {
			response = response || {};
			weatherPickerMap.setProvider(response.provider || 'none', response.custom_url || '', response.keys || {});
			weatherPickerMap.setMaps(response.maps || []);
			weatherPickerMap.focusOn(start.lat, start.lon, 0.05);
			weatherPickerMap.draw();
		},
		error: function() {
			weatherPickerMap.setProvider('none', '', {});
			weatherPickerMap.focusOn(start.lat, start.lon, 0.05);
			weatherPickerMap.draw();
		}
	});
}

function weatherPickerFlag() {
	if (!weatherPickerPicked || !weatherPickerMap || !weatherPickerMap.canvas) { return; }
	var ctx = weatherPickerMap.canvas.getContext('2d');
	var s = weatherPickerMap.project(weatherPickerPicked.lat, weatherPickerPicked.lon);
	ctx.save();
	ctx.strokeStyle = '#c0392b';
	ctx.lineWidth = 2;
	ctx.beginPath();
	ctx.moveTo(s[0], s[1]);
	ctx.lineTo(s[0], s[1] - 30);
	ctx.stroke();
	ctx.beginPath();
	ctx.moveTo(s[0], s[1] - 30);
	ctx.lineTo(s[0] + 18, s[1] - 23);
	ctx.lineTo(s[0], s[1] - 16);
	ctx.closePath();
	ctx.fillStyle = '#c0392b';
	ctx.fill();
	ctx.beginPath();
	ctx.arc(s[0], s[1], 3, 0, Math.PI * 2);
	ctx.fill();
	ctx.restore();
}

function weatherPickerClose() {
	var $w = $('.wind[app="weather"]').last();
	$w.find('#weather').removeClass('weather_choosing');
	$w.find('#weather_map_view').removeClass('open');
	$w.find('#weather_map_status').text('');
	weatherPickerPicked = null;
}

function weatherPickerSave() {
	var $w = $('.wind[app="weather"]').last();
	var button = $w.find('#weather_map_save');
	if (!weatherPickerPicked || button.prop('disabled')) { return; }
	button.prop('disabled', true);
	$w.find('#weather_map_status').text(jawnosT('Saving…'));
	$.ajax({
		url: '/manager/weather/location',
		type: 'POST',
		data: {
			name: $.trim($w.find('#weather_map_name').val() || ''),
			lat: weatherPickerPicked.lat,
			lon: weatherPickerPicked.lon,
			anchor: $w.find('#weather_map_anchor').prop('checked') ? 1 : '',
			timestamp: Date.now()
		},
		dataType: 'json',
		success: function(response) {
			if (!response || response.error) {
				$w.find('#weather_map_status').text((response && response.error) || jawnosT('The location was not saved.'));
				button.prop('disabled', false);
				return;
			}
			weatherLocationOptions($w, response.locations || [], response.labels || {});
			weatherPickerClose();
			$w.find('#weather_status').text(jawnosT('Location saved.'));
		},
		error: function() {
			$w.find('#weather_map_status').text(jawnosT('The location was not saved.'));
			button.prop('disabled', false);
		}
	});
}

function weatherLocationOptions($w, locations, labels) {
	labels = labels || {};
	var select = $w.find('#weather_device');
	var current = select.val();
	var group = select.find('optgroup[data-weather-locations="1"]');
	if (!locations.length) {
		group.remove();
		if (current) { select.val(current); }
		return;
	}
	if (!group.length) {
		group = $('<optgroup>').attr('label', jawnosT('Saved locations')).attr('data-weather-locations', '1').appendTo(select);
	}
	group.empty();
	for (var i = 0; i < locations.length; i++) {
		var loc = locations[i] || {};
		group.append($('<option>')
			.val('loc:' + (loc.uuid || ''))
			.attr('data-lat', loc.lat)
			.attr('data-lon', loc.lon)
			.attr('data-anchor', loc.anchor ? 1 : 0)
			.text(labels[loc.uuid] || loc.name || ''));
	}
	if (current) { select.val(current); }
	if (typeof weatherDeleteState === 'function') { weatherDeleteState(); }
}
