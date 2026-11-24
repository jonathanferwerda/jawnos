// The radar panel in the Weather app's History tab. It is the same canvas map
// Travel draws (window.jawnosMap): the Travel provider is the base, and the
// weather layers are painted over it by the engine's onDraw hook. Every layer is
// keyless, so a new house has a radar before it has signed up for anything.
//   precipitation - RainViewer's radar tiles (the newest past frame)
//   clouds, temperature, snow, smoke - NASA GIBS daily layers
//   magnetic - NOAA's OVATION aurora grid, sampled into one alpha pixel a degree
//   winds - Open-Meteo arrows on a small grid over the view
// The provider picker mirrors the Travel one; the house vector basemap is left
// out because this app does not load MapLibre or the PMTiles reader.

var weatherRadarMap = null;
var weatherRadarStarted = false;
var weatherRadarContinent = null;
var weatherRadarCentered = false;
var weatherRadarLayers = { precipitation: true };
var weatherRadarFrames = null;
var weatherRadarFramesAt = 0;
var weatherRadarAurora = null;
var weatherRadarAuroraAt = 0;
var weatherRadarWind = null;
var weatherRadarWindAt = 0;
var weatherRadarWindKey = '';
var weatherRadarWindTimer = null;
var weatherRadarTileCache = {};
var weatherRadarTileCount = 0;
var weatherRadarObserver = null;

function weatherRadarGibs(layer, level) {
	return 'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/' + layer
		+ '/default/GoogleMapsCompatible_Level' + level + '/{z}/{y}/{x}.png';
}

var WEATHER_RADAR_LAYERS = {
	snow:          { url: weatherRadarGibs('MODIS_Terra_NDSI_Snow_Cover', 8), maxZ: 6, opacity: 0.6 },
	temperature:   { url: weatherRadarGibs('MODIS_Terra_Land_Surface_Temp_Day', 7), maxZ: 7, opacity: 0.55 },
	smoke:         { url: weatherRadarGibs('MODIS_Terra_Aerosol', 6), maxZ: 6, opacity: 0.65 },
	clouds:        { url: weatherRadarGibs('MODIS_Terra_Cloud_Fraction_Day', 6), maxZ: 6, opacity: 0.55 },
	precipitation: { radar: true, maxZ: 12, opacity: 0.85 },
	magnetic:      { aurora: true },
	winds:         { wind: true }
};

function weatherRadarStart() {
	var $w = $('.wind[app="weather"]').last();
	if (!$w.length || !window.jawnosMap) { return; }
	var canvas = document.getElementById('weather_radar_canvas');
	if (!canvas) { return; }
	if (!weatherRadarMap || weatherRadarMap.canvas !== canvas) {
		weatherRadarMap = window.jawnosMap.create('weather_radar_canvas', {
			lat: (weatherLastLocation && weatherLastLocation.lat !== undefined) ? Number(weatherLastLocation.lat) : 43,
			lon: (weatherLastLocation && weatherLastLocation.lon !== undefined) ? Number(weatherLastLocation.lon) : -81.94,
			z: 8,
			width: function() { return $('#weather_radar_canvas').parent().width() || 340; },
			height: function() { return 340; }
		});
		weatherRadarMap.onDraw(weatherRadarDrawOverlays);
		weatherRadarMap.onChange(weatherRadarMoved);
		weatherRadarCentered = false;
		if (!weatherRadarStarted) {
			weatherRadarStarted = true;
			$(window).on('resize.weatherRadar', function() { if (weatherRadarMap) { weatherRadarMap.draw(); } });
			// An app window is a DOM box, not a browser window: it can be resized
			// without a resize event, which would leave the canvas at its old size.
			if (window.ResizeObserver && canvas.parentNode) {
				weatherRadarObserver = new ResizeObserver(function() { weatherRadarSafeDraw(); });
				weatherRadarObserver.observe(canvas.parentNode);
			}
		}
		weatherRadarBasemapLoad($w);
	}
	weatherRadarRecenter(weatherLastLocation && weatherLastLocation.lat, weatherLastLocation && weatherLastLocation.lon);
	if (weatherRadarLayers.precipitation) { weatherRadarFramesLoad(false); }
	if (weatherRadarLayers.magnetic) { weatherRadarAuroraLoad(false); }
	if (weatherRadarLayers.winds) { weatherRadarWindLoad(false); }
	weatherRadarLegend();
}

function weatherRadarRecenter(lat, lon) {
	if (!weatherRadarMap) { return; }
	var la = Number(lat), lo = Number(lon);
	if (!isFinite(la) || !isFinite(lo)) { return; }
	weatherRadarMap.center(la, lo);
	weatherRadarMap.setPosition({ lat: la, lon: lo, label: jawnosT('Weather here') });
	// The first time the tab opens, frame the place rather than whatever zoom
	// the freshly built engine happened to start with.
	if (!weatherRadarCentered) {
		weatherRadarMap.setZoom(8);
		weatherRadarCentered = true;
	}
	weatherRadarMap.draw();
}

function weatherRadarDraw() {
	if (weatherRadarMap) { weatherRadarMap.draw(); }
}

function weatherRadarSafeDraw() {
	if (weatherRadarMap) { weatherRadarMap.draw(); }
}

function weatherRadarMoved() {
	if (!weatherRadarMap || !weatherRadarLayers.winds) { return; }
	if (weatherRadarWindTimer) { clearTimeout(weatherRadarWindTimer); }
	weatherRadarWindTimer = setTimeout(function() { weatherRadarWindLoad(false); }, 450);
}

// ---- the map under the layers ------------------------------------------------

function weatherRadarBasemapLoad($w) {
	$.ajax({
		url: '/manager/travel/continent',
		type: 'GET',
		dataType: 'json',
		success: function(response) {
			weatherRadarContinent = response || {};
			weatherRadarBasemapFill($w, weatherRadarContinent);
		},
		error: function() {
			weatherRadarContinent = {};
			weatherRadarBasemapFill($w, {});
		}
	});
}

function weatherRadarBasemapFill($w, data) {
	var select = $w.find('#weather_radar_basemap');
	if (!select.length || !window.jawnosMap) { return; }
	var fallback = '';
	if (select.attr('filled') !== 'yes') {
		var labels = { free: 'Built in - no key needed', key: 'Needs your key', url: 'Needs a tile URL' };
		var holders = {};
		var engines = window.jawnosMap.providers;
		for (var key in engines) {
			var p = engines[key];
			if (!p || p.group === 'house') { continue; }
			if (p.group === 'none' || !p.group) {
				$('<option></option>').attr('value', key).text(jawnosT(p.name)).appendTo(select);
				continue;
			}
			if (!holders[p.group]) {
				holders[p.group] = $('<optgroup></optgroup>').attr('label', jawnosT(labels[p.group] || p.group)).appendTo(select);
			}
			$('<option></option>').attr('value', key).text(jawnosT(p.name)).appendTo(holders[p.group]);
		}
		select.attr('filled', 'yes');
		var provider = (data && data.provider) || 'none';
		if (provider === 'house') {
			// Travel can draw its own PMTiles archive; this panel does not load
			// MapLibre, so the saved house map falls back to a tile service.
			provider = 'osm';
			fallback = jawnosT('The house street map is not drawn here; showing OpenStreetMap.');
		}
		if (!engines[provider]) { provider = 'none'; }
		select.val(provider);
	}
	weatherRadarApplyProvider($w, data || weatherRadarContinent || {});
	if (fallback) { $w.find('#weather_radar_status').text(fallback); }
}

function weatherRadarApplyProvider($w, data) {
	if (!weatherRadarMap) { return; }
	var key = $w.find('#weather_radar_basemap').val() || 'none';
	data = data || {};
	weatherRadarMap.setProvider(key, data.custom_url || '', data.keys || {});
	var p = window.jawnosMap.providers[key] || {};
	var needs = p.needs;
	var note = '';
	if (needs === 'key' && !(data.keys && data.keys[key])) {
		note = jawnosT('Set this service\'s key under Configure \u2192 Plat \u2192 Maps.');
	}
	else if (needs === 'url' && !(data.custom_url || '')) {
		note = jawnosT('Paste the service\'s tile URL under Configure \u2192 Plat \u2192 Maps.');
	}
	$w.find('#weather_radar_status').text(note);
}

// ---- tile layers ------------------------------------------------------------

function weatherRadarTileLat(y, n) {
	return Math.atan(Math.sinh(Math.PI * (1 - 2 * y / n))) * 180 / Math.PI;
}

function weatherRadarLatTileY(lat, n) {
	var s = Math.sin(lat * Math.PI / 180);
	return (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * n;
}

function weatherRadarImage(url) {
	if (!url) { return null; }
	var image = weatherRadarTileCache[url];
	if (image !== undefined) { return image; }
	if (weatherRadarTileCount > 240) {
		weatherRadarTileCache = {};
		weatherRadarTileCount = 0;
	}
	image = new Image();
	weatherRadarTileCache[url] = image;
	weatherRadarTileCount++;
	image.onload = function() { weatherRadarSafeDraw(); };
	image.onerror = function() { weatherRadarTileCache[url] = null; };
	image.src = url;
	return image;
}

function weatherRadarRadarUrl(z, x, y) {
	if (!weatherRadarFrames) { return ''; }
	return weatherRadarFrames.host + weatherRadarFrames.path + '/256/' + z + '/' + x + '/' + y + '/2/1_1.png';
}

function weatherRadarDrawTileLayer(ctx, map, spec) {
	var view = map.view();
	var z = Math.min(Math.round(view.z), spec.maxZ || 12);
	var n = Math.pow(2, z);
	var bounds = map.viewBounds();
	var latNorth = Math.max(-85.0511, Math.min(85.0511, bounds.nw.lat));
	var latSouth = Math.max(-85.0511, Math.min(85.0511, bounds.se.lat));
	var y0 = Math.floor(weatherRadarLatTileY(latNorth, n));
	var y1 = Math.floor(weatherRadarLatTileY(latSouth, n));
	var lonWest = bounds.nw.lon;
	var lonEast = bounds.se.lon;
	if (lonEast < lonWest) { lonEast += 360; }
	var x0 = Math.floor((lonWest + 180) / 360 * n);
	var x1 = Math.floor((lonEast + 180) / 360 * n);
	if ((x1 - x0 + 1) * (y1 - y0 + 1) > 400) { return; }
	for (var ty = y0; ty <= y1; ty++) {
		if (ty < 0 || ty >= n) { continue; }
		for (var tx = x0; tx <= x1; tx++) {
			var wx = ((tx % n) + n) % n;
			var url = spec.radar ? weatherRadarRadarUrl(z, wx, ty)
				: spec.url.replace('{z}', z).replace('{x}', wx).replace('{y}', ty);
			var image = weatherRadarImage(url);
			if (!image || !image.complete || !image.naturalWidth) { continue; }
			var lonW = tx / n * 360 - 180;
			var lonE = (tx + 1) / n * 360 - 180;
			var north = weatherRadarTileLat(ty, n);
			var south = weatherRadarTileLat(ty + 1, n);
			var topLeft = map.project(north, lonW);
			var bottomRight = map.project(south, lonE);
			ctx.save();
			ctx.globalAlpha = spec.opacity || 0.7;
			try { ctx.drawImage(image, topLeft[0], topLeft[1], bottomRight[0] - topLeft[0], bottomRight[1] - topLeft[1]); } catch (e) {}
			ctx.restore();
		}
	}
}

function weatherRadarFramesLoad(force) {
	if (!weatherRadarLayers.precipitation) { return; }
	var now = Date.now();
	if (!force && weatherRadarFrames && now - weatherRadarFramesAt < 10 * 60 * 1000) { return; }
	$.ajax({
		url: 'https://api.rainviewer.com/public/weather-maps.json',
		type: 'GET',
		dataType: 'json',
		timeout: 15000,
		success: function(response) {
			var past = (response && response.radar && response.radar.past) || [];
			var latest = past.length ? past[past.length - 1] : null;
			if (!latest || !latest.path) {
				weatherRadarLegend(jawnosT('Rain radar is unavailable right now.'));
				return;
			}
			weatherRadarFrames = {
				host: response.host || 'https://tilecache.rainviewer.com',
				path: latest.path,
				time: latest.time
			};
			weatherRadarFramesAt = now;
			weatherRadarLegend();
			weatherRadarSafeDraw();
		},
		error: function() {
			weatherRadarLegend(jawnosT('Rain radar is unavailable right now.'));
		}
	});
}

// ---- the aurora grid --------------------------------------------------------

function weatherRadarAuroraLoad(force) {
	if (!weatherRadarLayers.magnetic) { return; }
	if (!force && weatherRadarAurora && Date.now() - weatherRadarAuroraAt < 30 * 60 * 1000) { return; }
	$.ajax({
		url: 'https://services.swpc.noaa.gov/json/ovation_aurora_latest.json',
		type: 'GET',
		dataType: 'json',
		timeout: 20000,
		success: function(response) {
			weatherRadarAuroraBuild(response);
			weatherRadarAuroraAt = Date.now();
			weatherRadarLegend();
			weatherRadarSafeDraw();
		},
		error: function() {
			weatherRadarLegend(jawnosT('The aurora forecast is unavailable right now.'));
		}
	});
}

function weatherRadarAuroraBuild(response) {
	var coords = (response && response.coordinates) || [];
	if (!coords.length) { return; }
	var canvas = document.createElement('canvas');
	canvas.width = 360;
	canvas.height = 181;
	var ctx = canvas.getContext('2d');
	var image = ctx.createImageData(360, 181);
	for (var i = 0; i < coords.length; i++) {
		var point = coords[i] || [];
		var lon = Number(point[0]);
		var lat = Number(point[1]);
		var value = Number(point[2]);
		if (!(value > 0) || !isFinite(lon) || !isFinite(lat)) { continue; }
		var px = ((Math.floor(lon) % 360) + 360) % 360;
		var py = 90 - Math.round(lat);
		if (py < 0 || py > 180) { continue; }
		var at = (py * 360 + px) * 4;
		image.data[at] = 70;
		image.data[at + 1] = 235;
		image.data[at + 2] = 140;
		image.data[at + 3] = Math.max(0, Math.min(210, Math.round(value * 3.5)));
	}
	ctx.putImageData(image, 0, 0);
	weatherRadarAurora = canvas;
}

function weatherRadarDrawAurora(ctx, map) {
	var image = weatherRadarAurora;
	if (!image) { return; }
	var height = map.canvas.height;
	var left = map.project(0, -180)[0];
	var right = map.project(0, 180)[0];
	if (!(right > left)) { return; }
	var northLimit = 85.0511;
	for (var i = 0; i < 180; i++) {
		var latA = Math.max(-northLimit, Math.min(northLimit, -90 + i));
		var latB = Math.max(-northLimit, Math.min(northLimit, -89 + i));
		if (latB === latA) { continue; }
		var top = map.project(latB, 0)[1];
		var bottom = map.project(latA, 0)[1];
		if (bottom < 0 || top > height) { continue; }
		ctx.save();
		ctx.globalAlpha = 0.8;
		try { ctx.drawImage(image, 0, 90 - latB, 360, 1, left, top, right - left, bottom - top); } catch (e) {}
		ctx.restore();
	}
}

// ---- wind arrows ------------------------------------------------------------

function weatherRadarWindLoad(force) {
	if (!weatherRadarLayers.winds || !weatherRadarMap) { return; }
	var bounds = weatherRadarMap.viewBounds();
	var latNorth = Math.min(80, bounds.nw.lat);
	var latSouth = Math.max(-80, bounds.se.lat);
	var lonWest = bounds.nw.lon;
	var lonEast = bounds.se.lon;
	if (lonEast < lonWest) { lonEast += 360; }
	if (!(latNorth > latSouth)) { return; }
	var columns = 7, rows = 5, points = [];
	for (var r = 0; r < rows; r++) {
		for (var c = 0; c < columns; c++) {
			var lat = latSouth + (latNorth - latSouth) * (r + 0.5) / rows;
			var lon = lonWest + (lonEast - lonWest) * (c + 0.5) / columns;
			lon = ((lon + 180) % 360 + 360) % 360 - 180;
			points.push({ lat: lat, lon: lon });
		}
	}
	var key = points.map(function(p) { return p.lat.toFixed(2) + ',' + p.lon.toFixed(2); }).join(';');
	if (!force && key === weatherRadarWindKey && Date.now() - weatherRadarWindAt < 10 * 60 * 1000) { return; }
	weatherRadarWindKey = key;
	var lats = points.map(function(p) { return p.lat.toFixed(3); }).join(',');
	var lons = points.map(function(p) { return p.lon.toFixed(3); }).join(',');
	$.ajax({
		url: 'https://api.open-meteo.com/v1/forecast?latitude=' + lats + '&longitude=' + lons
			+ '&current=wind_speed_10m,wind_direction_10m',
		type: 'GET',
		dataType: 'json',
		timeout: 15000,
		success: function(response) {
			var list = response instanceof Array ? response : [response];
			var out = [];
			for (var i = 0; i < list.length && i < points.length; i++) {
				var current = list[i] && list[i].current;
				if (!current) { continue; }
				out.push({
					lat: points[i].lat,
					lon: points[i].lon,
					speed: Number(current.wind_speed_10m),
					direction: Number(current.wind_direction_10m)
				});
			}
			weatherRadarWind = { points: out, at: Date.now() };
			weatherRadarWindAt = Date.now();
			weatherRadarLegend();
			weatherRadarSafeDraw();
		},
		error: function() {
			weatherRadarLegend(jawnosT('The wind arrows are unavailable right now.'));
		}
	});
}

function weatherRadarDrawWinds(ctx, map) {
	if (!weatherRadarWind) { return; }
	var width = map.canvas.width, height = map.canvas.height;
	for (var i = 0; i < weatherRadarWind.points.length; i++) {
		var point = weatherRadarWind.points[i];
		var screen = map.project(point.lat, point.lon);
		if (screen[0] < -20 || screen[0] > width + 20 || screen[1] < -20 || screen[1] > height + 20) { continue; }
		var speed = isFinite(point.speed) ? point.speed : 0;
		var theta = ((isFinite(point.direction) ? point.direction : 0) + 180) * Math.PI / 180;
		var dx = Math.sin(theta), dy = Math.cos(theta);
		var length = 8 + Math.min(60, speed) * 0.32;
		var x1 = screen[0] - dx * length / 2, y1 = screen[1] - dy * length / 2;
		var x2 = screen[0] + dx * length / 2, y2 = screen[1] + dy * length / 2;
		var hue = 210 - Math.min(80, speed) * 1.6;
		ctx.save();
		ctx.strokeStyle = 'hsla(' + hue + ',85%,38%,0.92)';
		ctx.fillStyle = ctx.strokeStyle;
		ctx.lineWidth = 1.6;
		ctx.beginPath();
		ctx.moveTo(x1, y1);
		ctx.lineTo(x2, y2);
		ctx.stroke();
		ctx.beginPath();
		ctx.moveTo(x2, y2);
		ctx.lineTo(x2 - dx * 5 - dy * 3.2, y2 - dy * 5 + dx * 3.2);
		ctx.lineTo(x2 - dx * 5 + dy * 3.2, y2 - dy * 5 - dx * 3.2);
		ctx.closePath();
		ctx.fill();
		ctx.restore();
	}
}

// ---- the draw hook ----------------------------------------------------------

function weatherRadarDrawOverlays() {
	if (!weatherRadarMap) { return; }
	var ctx = weatherRadarMap.canvas.getContext('2d');
	var order = ['snow', 'temperature', 'smoke', 'clouds', 'precipitation'];
	for (var i = 0; i < order.length; i++) {
		var name = order[i];
		if (!weatherRadarLayers[name]) { continue; }
		var spec = WEATHER_RADAR_LAYERS[name];
		if (spec.radar && !weatherRadarFrames) { continue; }
		weatherRadarDrawTileLayer(ctx, weatherRadarMap, spec);
	}
	if (weatherRadarLayers.magnetic) { weatherRadarDrawAurora(ctx, weatherRadarMap); }
	if (weatherRadarLayers.winds) { weatherRadarDrawWinds(ctx, weatherRadarMap); }
}

// ---- the switches -----------------------------------------------------------

$(document).on('change', '#weather_radar_layers input', function() {
	var name = $(this).attr('data-layer') || '';
	weatherRadarLayers[name] = this.checked;
	if (this.checked) {
		if (name === 'precipitation') { weatherRadarFramesLoad(false); }
		if (name === 'magnetic') { weatherRadarAuroraLoad(false); }
		if (name === 'winds') { weatherRadarWindLoad(false); }
	}
	weatherRadarLegend();
	weatherRadarDraw();
});

$(document).on('change', '#weather_radar_basemap', function() {
	var $w = $('.wind[app="weather"]').last();
	weatherRadarApplyProvider($w, weatherRadarContinent || {});
});

function weatherRadarLegend(message) {
	var $w = $('.wind[app="weather"]').last();
	var bits = [];
	if (message) { bits.push(message); }
	else {
		if (weatherRadarLayers.precipitation) {
			bits.push(weatherRadarFrames ? jawnosT('Radar {0}', weatherTime(weatherRadarFrames.time * 1000)) : jawnosT('Loading radar\u2026'));
		}
		if (weatherRadarLayers.clouds) { bits.push(jawnosT('Cloud fraction')); }
		if (weatherRadarLayers.temperature) { bits.push(jawnosT('Land surface temperature')); }
		if (weatherRadarLayers.snow) { bits.push(jawnosT('Snow cover')); }
		if (weatherRadarLayers.smoke) { bits.push(jawnosT('Aerosol (smoke and haze)')); }
		if (weatherRadarLayers.magnetic) { bits.push(jawnosT('Aurora probability')); }
		if (weatherRadarLayers.winds) { bits.push(jawnosT('Wind arrows')); }
	}
	$w.find('#weather_radar_legend').text(bits.join(' \u00b7 '));
}
