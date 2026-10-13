// The continent background: a pan-able map of every measured map we have, with the
// places the continent knows, the home plates we have measured, the appointments
// the current time range holds (each at its latest fix, so tapping one opens its
// appointment window) and - front and centre - the machine's current position (the
// row the writers keep rewriting with type 'temporary'). The map is drawn by
// jawnosMap (public/js/manager/mapengine.js); its data comes from
// /manager/travel/continent (maps + places + appointments + home plates + current
// position + the chosen provider). When the engine is unavailable it falls back to
// the old fitted graticule of places.

var jawnosContinentMap;
var jawnosContinentAt = 0;
var jawnosContinentRefetch = 30000;
var jawnosContinentHere = null;   // the last known current position
var jawnosContinentRange = '';    // the time range the points were fetched for

function continentPrinter(appts, sort) {
	var places = appts['__continent'] || [];

	// no engine in the bundle? the fitted plot still tells the story
	if (!window.jawnosMap) {
		continentPlot(appts, sort);
		return;
	}

	if (!jawnosContinentMap) {
		jawnosContinentMap = window.jawnosMap.create('continent', {
			z: 13,
			width: function() { return $(window).width(); },
			height: function() { return $(window).height(); }
		});
		jawnosContinentMap.onMarkerClick(jawnosContinentMarkerTapped);
		jawnosContinentMap.onChange(jawnosContinentListHide);
	}
	var engine = jawnosContinentMap;
	var canvas = document.getElementById('continent');
	$(canvas).show();

	// whatever the payload already carries, drawn at once while the fetch is out
	if (places.length) {
		engine.setPoints(continentPoints(places));
	}
	engine.draw();

	// (re)fetch the atlas when the time range changes, or at most every
	// jawnosContinentRefetch ms - graphicalize runs on every poll, the maps and the
	// places do not
	var specs = appts['__specs'] || {};
	var range = (specs['start'] || '') + '-' + (specs['end'] || '');
	var now = Date.now();
	if (range === jawnosContinentRange && (now - jawnosContinentAt) < jawnosContinentRefetch) { return; }
	jawnosContinentAt = now;
	jawnosContinentRange = range;
	$.ajax({
		url: '/manager/travel/continent',
		type: 'GET',
		data: { start: specs['start'], end: specs['end'] },
		success: function(response) {
			engine.setProvider(response['provider'] || 'none', response['custom_url'] || '');
			engine.setMaps(response['maps'] || []);
			// the plain places first, then what answers a tap: the home plates
			// (grouped where several share a spot) and the appointments in scope
			var points = continentPoints(response['points'] || []).concat(continentTappables(response));
			engine.setPoints(points.length ? points : continentPoints(places));

			var here = response['here'];
			if (here && here['latitude']) {
				jawnosContinentHere = { lat: parseFloat(here['latitude']), lon: parseFloat(here['longitude']) };
				engine.setPosition({ lat: jawnosContinentHere.lat, lon: jawnosContinentHere.lon, label: here['label'] || 'You are here' });
			}
			else {
				engine.setPosition(null);
			}
			// frame the current position (with the maps around it) - the whole point of
			// the background is to show where you are in relation to the maps we have
			if (!engine.__framed) {
				if (here && here['latitude']) { engine.focusOn(parseFloat(here['latitude']), parseFloat(here['longitude'])); }
				else { engine.fitToMaps(); }
				engine.__framed = true;
			}
			engine.draw();
		}
	});
}

// The now button (and a double-click on the background) returns the timeline to the
// present; on the continent it also centres back on where you are.
function jawnosContinentRecentre() {
	if (!jawnosContinentMap) { return; }
	if (jawnosContinentHere) { jawnosContinentMap.focusOn(jawnosContinentHere.lat, jawnosContinentHere.lon); }
	else if (jawnosContinentMap.fitToMaps) { jawnosContinentMap.fitToMaps(); }
	jawnosContinentMap.draw();
}
$(document).on('click', '.now', function() { jawnosContinentRecentre(); });
$(document).on('dblclick', '#continent', function() { jawnosContinentRecentre(); });

function continentPoints(places) {
	var out = [];
	$.each(places, function(i, v) {
		var lat = parseFloat(v['latitude']);
		var lon = parseFloat(v['longitude']);
		if (!isFinite(lat) || !isFinite(lon)) { return; }
		out.push({ lat: lat, lon: lon, label: v['name'] || v['app'] || '', colour: v['colour'] });
	});
	return out;
}

// The tappable markers: every home plate (several in the same spot collapse to one
// marker wearing their count, carrying the plates themselves so the tap can unfold
// them), and every appointment the view's time range holds, at its latest recorded
// fix. A tap opens the appointment window for the app.
function continentTappables(response) {
	var markers = [];
	var clusters = [];
	$.each(response['home_plates'] || [], function(i, v) {
		var lat = parseFloat(v['latitude']);
		var lon = parseFloat(v['longitude']);
		if (!isFinite(lat) || !isFinite(lon)) { return; }
		var plate = { app: v['app'], name: v['name'] || v['app'], colour: v['colour'], lat: lat, lon: lon };
		for (var c = 0; c < clusters.length; c++) {
			if (continentMetres(clusters[c], plate) <= 50) {
				var n = clusters[c].plates.length;
				clusters[c].lat = ((clusters[c].lat * n) + lat) / (n + 1);
				clusters[c].lon = ((clusters[c].lon * n) + lon) / (n + 1);
				clusters[c].plates.push(plate);
				return;
			}
		}
		clusters.push({ lat: lat, lon: lon, plates: [plate] });
	});
	$.each(clusters, function(i, cluster) {
		markers.push({
			lat: cluster.lat,
			lon: cluster.lon,
			kind: 'home_plate',
			count: cluster.plates.length,
			plates: cluster.plates,
			app: cluster.plates.length == 1 ? cluster.plates[0].app : '',
			label: cluster.plates.length == 1 ? cluster.plates[0].name : '',
			colour: cluster.plates[0].colour || '#6f4f9f'
		});
	});
	$.each(response['appointments'] || [], function(i, v) {
		var lat = parseFloat(v['latitude']);
		var lon = parseFloat(v['longitude']);
		if (!isFinite(lat) || !isFinite(lon)) { return; }
		markers.push({ lat: lat, lon: lon, kind: 'appointment', app: v['app'], label: v['name'] || v['app'], colour: v['colour'] || '#a0503f' });
	});
	return markers;
}

// How far apart two markers are, in metres (the equirectangular approximation is
// plenty at the scale one spot is judged at).
function continentMetres(a, b) {
	var mid = (a.lat + b.lat) / 2 * Math.PI / 180;
	var dLat = (a.lat - b.lat) * 111194.9;
	var dLon = (a.lon - b.lon) * 111194.9 * Math.cos(mid);
	return Math.sqrt((dLat * dLat) + (dLon * dLon));
}

// A tap on the map: a single home plate or an appointment opens its appointment
// window; a group unfolds into the list of what shares the spot.
function jawnosContinentMarkerTapped(pt, sx, sy) {
	if (pt.plates && pt.plates.length > 1) {
		jawnosContinentList(pt, sx, sy);
		return;
	}
	var app = pt.app || (pt.plates && pt.plates.length ? pt.plates[0].app : '');
	if (app) { appointmentGrabber(app, Date.now()); }
}

// The little list a grouped marker unfolds: each plate by name, a tap on a name
// opens that app's appointment window.
function jawnosContinentList(pt, sx, sy) {
	jawnosContinentListHide();
	var canvas = document.getElementById('continent');
	if (!canvas) { return; }
	var rect = canvas.getBoundingClientRect();
	var list = $('<div id="continent_marker_list"></div>').css({
		position: 'fixed',
		left: Math.max(4, Math.min(rect.left + sx + 12, $(window).width() - 190)) + 'px',
		top: Math.max(4, Math.min(rect.top + sy + 12, $(window).height() - 190)) + 'px',
		'z-index': 9000,
		'background-color': 'var(--panel)',
		border: '2px solid var(--line)',
		'border-radius': '8px',
		padding: '4px 8px',
		'max-height': '34vh',
		'overflow-y': 'auto',
		'box-shadow': '0 6px 18px rgba(0,0,0,.35)',
		'font-size': '13px',
		'min-width': '130px'
	});
	$('<b></b>').text(pt.plates.length + ' places').appendTo(list);
	$.each(pt.plates, function(i, plate) {
		$('<span class="continent_marker_item"></span>')
			.attr('app', plate.app)
			.css({ display: 'block', padding: '3px 4px', cursor: 'pointer' })
			.text(plate.name)
			.appendTo(list);
	});
	list.appendTo('body');
}

function jawnosContinentListHide() {
	$('#continent_marker_list').remove();
}
$(document).on('click', '.continent_marker_item', function() {
	var app = $(this).attr('app');
	jawnosContinentListHide();
	if (app) { appointmentGrabber(app, Date.now()); }
});
$(document).on('mousedown touchstart', function(e) {
	if ($(e.target).closest('#continent_marker_list').length == 0) { jawnosContinentListHide(); }
});

// The fallback: every place plotted by latitude/longitude, auto-fitted to the points
// (with a floor on the span so one dot is not magnified into nonsense) over a faint
// graticule, with labels where they fit.
function continentPlot(appts, sort) {
	var canvas = document.getElementById('continent');
	canvas.width = $('#background').width();
	canvas.height = $(window).height();
	ctx = canvas.getContext('2d');
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	headerPrinter(ctx,appts,'Continent');

	var ink = jawnosInk();
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;
	var places = appts['__continent'] || [];
	var palette = ['#2f6f9f', '#a0503f', '#3f8f5f', '#8f6f2f', '#6f4f9f', '#9f5f7f'];

	var pad = 44;
	var mapLeft = pad;
	var mapRight = canvas.width - pad;
	var mapTop = headerHeight + clothesLineHeight + 30;
	var mapBottom = canvas.height - 34;

	// fit the points, with a minimum span so single places are not absurd
	var minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
	$.each(places, function(i,v) {
		var lat = parseFloat(v['latitude']);
		var lon = parseFloat(v['longitude']);
		if (!isFinite(lat) || !isFinite(lon)) { return true; }
		minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat);
		minLon = Math.min(minLon, lon); maxLon = Math.max(maxLon, lon);
	});
	if (minLon > maxLon) { minLat = -30; maxLat = 60; minLon = -140; maxLon = 140; }
	var latMid = (minLat + maxLat) / 2;
	var lonMid = (minLon + maxLon) / 2;
	var latSpan = Math.max(maxLat - minLat, 24) * 1.3;
	var lonSpan = Math.max(maxLon - minLon, 36) * 1.3;

	function project(lat, lon) {
		var x = mapLeft + (((lon - (lonMid - lonSpan / 2)) / lonSpan) * (mapRight - mapLeft));
		var y = mapTop + ((1 - ((lat - (latMid - latSpan / 2)) / latSpan)) * (mapBottom - mapTop));
		return [x, y];
	}

	// the graticule
	ctx.save();
	ctx.strokeStyle = ink;
	ctx.globalAlpha = 0.15;
	ctx.lineWidth = 1;
	for (var g = 1; g < 6; g++) {
		ctx.beginPath();
		ctx.moveTo(mapLeft + ((mapRight - mapLeft) * g / 6), mapTop);
		ctx.lineTo(mapLeft + ((mapRight - mapLeft) * g / 6), mapBottom);
		ctx.stroke();
	}
	for (var g2 = 1; g2 < 4; g2++) {
		ctx.beginPath();
		ctx.moveTo(mapLeft, mapTop + ((mapBottom - mapTop) * g2 / 4));
		ctx.lineTo(mapRight, mapTop + ((mapBottom - mapTop) * g2 / 4));
		ctx.stroke();
	}
	ctx.restore();

	// the places, and their names where they do not collide
	var labels = [];
	$.each(places, function(i,v) {
		var lat = parseFloat(v['latitude']);
		var lon = parseFloat(v['longitude']);
		if (!isFinite(lat) || !isFinite(lon)) { return true; }
		var p = project(lat, lon);
		var colour = v['colour'] || palette[i % palette.length];

		ctx.save();
		if (halo) {
			ctx.strokeStyle = halo;
			ctx.lineWidth = 5;
			ctx.beginPath();
			ctx.arc(p[0], p[1], 7, 0, (Math.PI * 2));
			ctx.stroke();
		}
		ctx.fillStyle = colour;
		ctx.beginPath();
		ctx.arc(p[0], p[1], 7, 0, (Math.PI * 2));
		ctx.fill();
		ctx.strokeStyle = ink;
		ctx.lineWidth = 2;
		ctx.beginPath();
		ctx.arc(p[0], p[1], 7, 0, (Math.PI * 2));
		ctx.stroke();
		ctx.restore();

		if (v['name']) {
			var text = format_name(v['name']);
			ctx.font = '400 13px Arial';
			var tw = ctx.measureText(text).width;
			var box = [p[0] + 12, p[1] - 9, p[0] + 12 + tw, p[1] + 9];
			if (box[2] < canvas.width - 4 && box[1] > mapTop - 6) {
				var clash = false;
				$.each(labels, function(li, lb) {
					if (box[0] < lb[2] && box[2] > lb[0] && box[1] < lb[3] && box[3] > lb[1]) { clash = true; }
				});
				if (!clash) {
					labels.push(box);
					jawnosPrinterText(ctx, text, box[0], p[1], { font: '400 13px Arial', colour: ink, halo: halo });
				}
			}
		}
	});

	// how many places are on the map
	jawnosPrinterText(ctx, places.length + (places.length == 1 ? ' place' : ' places'), mapLeft, canvas.height - 14,
		{ font: '400 13px Arial', colour: ink, halo: halo, alpha: 0.7 });
}
