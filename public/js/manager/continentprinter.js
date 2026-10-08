// The continent: every place in the payload plotted by latitude/longitude,
// auto-fitted to the points (with a floor on the span so one dot is not
// magnified into nonsense) over a faint graticule, with labels where they fit.

function continentPrinter(appts,sort) {
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
