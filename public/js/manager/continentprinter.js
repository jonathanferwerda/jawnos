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
var jawnosContinentAppts = null;  // the payload, for the header the overlay repaints

// The engine owns the continent canvas, so its clear-and-draw wipes the furniture
// the page paints on the same canvas - the header and the clothesline rail. The
// engine calls this after every draw (a late tile, a pan), so the rail always
// rides over the maps.
function jawnosContinentOverlay() {
	// only the continent layout wears this canvas; a late tile must not paint its
	// furniture over whatever layout took over
	if (typeof localStorage != 'undefined' && localStorage.getItem('layout') != 'continent') { return; }
	var canvas = document.getElementById('continent');
	if (!canvas) { return; }
	if (typeof headerPrinter == 'function' && jawnosContinentAppts) {
		headerPrinter(canvas.getContext('2d'), jawnosContinentAppts, 'Continent');
	}
	if (typeof clotheslineHanger == 'function' && typeof wardrobe != 'undefined' && wardrobe.length) {
		clotheslineHanger(wardrobe);
	}
}

function continentPrinter(appts, sort) {
	// no ghosts here: a ghost carries a moment and a name but no place - the
	// contract gives it no latitude or longitude - and this layout draws only what
	// has been on the ground (the engine's markers, and the __continent places in
	// the fallback below), so there is nothing to hang a prediction on
	var places = appts['__continent'] || [];
	jawnosContinentAppts = appts;

	// no engine in the bundle? the fitted plot still tells the story
	if (!window.jawnosMap) {
		continentPlot(appts, sort);
		return;
	}

	if (!jawnosContinentMap) {
		jawnosContinentMap = window.jawnosMap.create('continent', {
			z: 13,
			width: function() { return $(window).width(); },
			height: function() { return $(window).height(); },
			// the clothesline band belongs to the rail: a drag or scroll there must
			// not also move or zoom the map under it
			ignoreTop: function() { return (typeof clothesLinePos != 'undefined') ? clothesLinePos['maxHeight'] : 0; }
		});
		jawnosContinentMap.onMarkerClick(function(pt, sx, sy) { jawnosMarkerTapped(pt, sx, sy, jawnosContinentMap.canvas); });
		// a right-click on a guessed gap offers to drop it, as the travel map does
		jawnosContinentMap.onMapContext(function(m, sx, sy) {
			if (!m || !m.guess) { return 0; }
			jawnosGuessMenu(m, sx, sy, jawnosContinentMap.canvas);
			return 1;
		});
		jawnosContinentMap.onChange(jawnosMarkerListHide);
		jawnosContinentMap.onDraw(jawnosContinentOverlay);
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

// The tappable markers: every home plate (several in the same spot collapse to
// one marker wearing their count) and every appointment the view's time range
// holds, at its latest recorded fix. A tap opens the appointment window for the
// app; a grouped one unfolds its list.
function continentTappables(response) {
	var plates = [];
	$.each(response['home_plates'] || [], function(i, v) {
		plates.push({ app: v['app'], name: v['name'] || v['app'], colour: v['colour'], lat: parseFloat(v['latitude']), lon: parseFloat(v['longitude']) });
	});
	var appointments = [];
	$.each(response['appointments'] || [], function(i, v) {
		appointments.push({ app: v['app'], name: v['name'] || v['app'], colour: v['colour'], lat: parseFloat(v['latitude']), lon: parseFloat(v['longitude']) });
	});
	return jawnosMarkerGroups(plates, 50, '#6f4f9f').concat(jawnosMarkerGroups(appointments, 50, '#a0503f'));
}

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
