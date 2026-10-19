// The clockface: concentric rings for the scopes - hour outermost, then day,
// week, month, year - one dot per occurrence around its ring at the minute its
// percent works out to, labels radiating outward where they fit, and ordinary
// clock hands over the middle showing the actual time. The mousewheel zoom
// (scrollPositioner, turned by clothesline.js) scales the whole face.

var ap;

function appointmentEventMaker(appts,sort) {
	var appointment_events = { hour: [], day: [], week: [], month: [], year: [], decade: [], century: [], millenium: [], age: [] };
	var scopes = ['hour', 'day', 'week', 'month', 'year', 'decade', 'century', 'millenium', 'age'];
	$('#clockface').show();
	$.each(appts, function(i,v) {
		if ( i.match(/^__/) ) { return true; }
		$.each(['list','transactions'],function(n,val) {
			$.each(v[val] || [],function(numero,value) {
				$.each(scopes, function(si,scope) {
					if (value[scope + '_percent'] == undefined || value[scope + '_percent'] === '') { return true; }
					appointment_events[scope].push({
						'minute': numeral(60 * (value[scope + '_percent'])).format('0'),
						'timestamp': value['timestamp'],
						'value': value,
						'size': (v[val] || []).length,
						'colour': v['setting'] ? jawnosApptColour(v['setting']) : undefined,
						'name': v['name'] || v['formatted_name'],
						'formatted_name': v['formatted_name']
					});
				});
			});
		});
	});
	return appointment_events;
}

var lastY;
$(document).ready(function() {
	localStorage.setItem('scrollPositioner', .4);
});

function clockfacePrinter(appts) {
	appPosition = [];
	var canvas = document.getElementById('clockface');
	canvas.width = $('#background').width();
	canvas.height = $(window).height();
	ctx = canvas.getContext('2d');
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	headerPrinter(ctx,appts,'Clockface');

	var ink = jawnosInk();
	var darkTheme = (typeof jawnosTextureDark == 'function') ? jawnosTextureDark() : false;
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;
	var appointment_events = appointmentEventMaker(appts,'size');
	// the scope in view owns the only window the payload gives a percent against
	var scope = localStorage.getItem('scope');

	// the wheel zoom, sane and centred on the default
	var zoom = numeral(localStorage.getItem('scrollPositioner')).value() / 0.4;
	if (!isFinite(zoom) || zoom <= 0) { zoom = 1; }
	zoom = Math.min(Math.max(zoom, 0.6), 1.5);

	var top = headerHeight + clothesLineHeight + 20;
	var cx = canvas.width / 2;
	var availH = canvas.height - top - 24;
	var cy = top + (availH / 2);
	var R = Math.min((canvas.width / 2) - 70, (availH / 2) - 26) * zoom;
	if (R < 60) { R = 60; }

	var rings = [
		{ scope: 'hour', r: R },
		{ scope: 'day', r: R * 0.80 },
		{ scope: 'week', r: R * 0.63 },
		{ scope: 'month', r: R * 0.48 },
		{ scope: 'year', r: R * 0.34 }
	];

	// the rings, their ticks, and the hour numbers just inside the outer one
	$.each(rings, function(ri,ring) {
		ctx.save();
		ctx.strokeStyle = ink;
		ctx.globalAlpha = 0.25;
		ctx.lineWidth = 1.5;
		ctx.beginPath();
		ctx.arc(cx, cy, ring.r, 0, (Math.PI * 2));
		ctx.stroke();
		for (var t = 0; t < 60; t++) {
			var a = (t / 60) * Math.PI * 2;
			var major = (t % 5) == 0;
			ctx.globalAlpha = major ? 0.5 : 0.22;
			ctx.lineWidth = major ? 2 : 1;
			ctx.beginPath();
			ctx.moveTo(cx + Math.sin(a) * (ring.r - (major ? 11 : 6)), cy - Math.cos(a) * (ring.r - (major ? 11 : 6)));
			ctx.lineTo(cx + Math.sin(a) * ring.r, cy - Math.cos(a) * ring.r);
			ctx.stroke();
		}
		ctx.restore();

		// the ring's name at twelve o'clock
		jawnosPrinterText(ctx, ring.scope, cx, cy - ring.r + 14, { font: '600 11px Arial', align: 'center', colour: ink, halo: halo, alpha: 0.6 });

		if (ri == 0) {
			for (var h = 1; h <= 12; h++) {
				var ha = (h / 12) * Math.PI * 2;
				jawnosPrinterText(ctx, h, cx + Math.sin(ha) * (ring.r - 30), cy - Math.cos(ha) * (ring.r - 30),
					{ font: '600 20px Arial', align: 'center', colour: ink, halo: halo });
			}
		}
	});

	// the occurrences, by minute around their ring
	var placed = [];
	$.each(rings, function(ri,ring) {
		var events = (appointment_events[ring.scope] || []).slice().sort(function(a, b) {
			return numeral(a['minute']).value() - numeral(b['minute']).value();
		});
		$.each(events, function(ei,e) {
			var pct = numeral(e['minute']).value() / 60;
			var a = pct * Math.PI * 2;
			var rr = ring.r + ((ei % 3) * 9);
			var dx = cx + Math.sin(a) * rr;
			var dy = cy - Math.cos(a) * rr;

			ctx.save();
			if (halo) {
				ctx.strokeStyle = halo;
				ctx.lineWidth = 4;
				ctx.beginPath();
				ctx.arc(dx, dy, 6, 0, (Math.PI * 2));
				ctx.stroke();
			}
			if (typeof jawnosTextureFillCircle == 'function') { jawnosTextureFillCircle(ctx, dx, dy, 6, e['colour'] || ink, darkTheme); }
			else { ctx.fillStyle = e['colour'] || ink; ctx.beginPath(); ctx.arc(dx, dy, 6, 0, (Math.PI * 2)); ctx.fill(); }
			ctx.strokeStyle = ink;
			ctx.lineWidth = 1.5;
			ctx.beginPath();
			ctx.arc(dx, dy, 6, 0, (Math.PI * 2));
			ctx.stroke();
			ctx.restore();

			// the dot answers a press (and the label widens the hit below)
			var hit = [dx - 9, dy - 9, dx + 9, dy + 9, e];
			appPosition.push(hit);

			// the label radiates outward on the open side, if it fits alone
			var text = e['formatted_name'] || e['name'];
			if (!text) { return true; }
			ctx.font = '400 13px Arial';
			var tw = ctx.measureText(text).width;
			var align = Math.sin(a) >= 0 ? 'left' : 'right';
			var lx = cx + Math.sin(a) * (rr + 18);
			var ly = cy - Math.cos(a) * (rr + 18);
			var box = align == 'left' ? [lx, ly - 8, lx + tw, ly + 8] : [lx - tw, ly - 8, lx, ly + 8];
			if (box[0] < 2 || box[2] > canvas.width - 2 || box[1] < top - 4 || box[3] > canvas.height - 2) { return true; }
			var clash = false;
			$.each(placed, function(pi,pb) {
				if (box[0] < pb[2] && box[2] > pb[0] && box[1] < pb[3] && box[3] > pb[1]) { clash = true; }
			});
			if (clash) { return true; }
			placed.push(box);
			hit[0] = Math.min(hit[0], box[0]);
			hit[1] = Math.min(hit[1], box[1]);
			hit[2] = Math.max(hit[2], box[2]);
			hit[3] = Math.max(hit[3], box[3]);
			jawnosPrinterText(ctx, text, lx, ly, { font: '400 13px Arial', align: align, colour: ink, halo: halo });
		});
	});

	// the ghosts: the occurrences a habit predicts. A ghost carries no percent of
	// its own and the payload knows only the scope in view's window, so it goes on
	// that scope's ring by the same fallback the timeline uses - faded, and pushed
	// nowhere, so a ghost never answers a press
	var ghostRing = $.grep(rings, function(n,ri) { return n['scope'] == scope; })[0] || rings[0];
	$.each(appts, function(i,v) {
		if ( i.match(/^__/) ) { return true; }
		if ( !v['ghosts'] || !v['ghosts'].length ) { return true; }
		var colour = jawnosApptColour(v['setting']) || ink;
		$.each(v['ghosts'], function(gi,gh) {
			if ( !gh || !isFinite(gh['timestamp']) ) { return true; }
			var pct = parseFloat(gh[scope + '_percent']);
			if ( !isFinite(pct) ) {
				pct = (gh['timestamp'] - appts['__specs']['start']) / (appts['__specs']['timestamp'] - appts['__specs']['start']);
			}
			if ( !isFinite(pct) ) { pct = 0; }
			pct = Math.min(Math.max(pct, 0), 2);
			var ga = pct * Math.PI * 2;
			var grr = ghostRing.r + ((gi % 3) * 9);
			var gx = cx + Math.sin(ga) * grr;
			var gy = cy - Math.cos(ga) * grr;

			ctx.save();
			ctx.globalAlpha = 0.3;
			if (halo) {
				ctx.strokeStyle = halo;
				ctx.lineWidth = 4;
				ctx.beginPath();
				ctx.arc(gx, gy, 6, 0, (Math.PI * 2));
				ctx.stroke();
			}
			if (typeof jawnosTextureFillCircle == 'function') { jawnosTextureFillCircle(ctx, gx, gy, 6, colour, darkTheme); }
			else { ctx.fillStyle = colour; ctx.beginPath(); ctx.arc(gx, gy, 6, 0, (Math.PI * 2)); ctx.fill(); }
			ctx.strokeStyle = ink;
			ctx.lineWidth = 1.5;
			ctx.beginPath();
			ctx.arc(gx, gy, 6, 0, (Math.PI * 2));
			ctx.stroke();
			ctx.restore();
		});
	});

	// the hands, reading the actual time
	var d = new Date();
	var hourAngle = (((d.getHours() % 12) + (d.getMinutes() / 60)) / 12) * Math.PI * 2;
	var minuteAngle = (d.getMinutes() / 60) * Math.PI * 2;
	ctx.save();
	ctx.strokeStyle = ink;
	ctx.lineCap = 'round';
	ctx.globalAlpha = 0.85;
	ctx.lineWidth = 5;
	ctx.beginPath();
	ctx.moveTo(cx, cy);
	ctx.lineTo(cx + Math.sin(hourAngle) * (R * 0.20), cy - Math.cos(hourAngle) * (R * 0.20));
	ctx.stroke();
	ctx.lineWidth = 3;
	ctx.beginPath();
	ctx.moveTo(cx, cy);
	ctx.lineTo(cx + Math.sin(minuteAngle) * (R * 0.29), cy - Math.cos(minuteAngle) * (R * 0.29));
	ctx.stroke();
	ctx.fillStyle = ink;
	ctx.beginPath();
	ctx.arc(cx, cy, 5, 0, (Math.PI * 2));
	ctx.fill();
	ctx.restore();
}
