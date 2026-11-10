// The timeline: one row per app, a dot per occurrence placed by its percent
// with the pseudonym's icon in its middle, money beside the dot, and the span
// from the start percent to the percent drawn as a faded band behind it. A
// percent runs over the scope either side of now: 1 is the rail, 2 is a scope
// ahead, 0 a scope behind, so now hangs mid-canvas with the future to its
// right. Rows begin under the header and the clothesline, and the canvas
// grows to hold every app.

var appPosition = [];

// The vertical rail the rows hang from, in a mid-tone of the theme's own colour
// so it belongs to the scheme (the themed ink is black on a light desk, which
// drew a hard black bar). Over a background picture that colour can vanish, so
// the contrasting halo is laid underneath it first. The clothesline clears its
// own band after the timeline has drawn, so it calls this too - for the band it
// just emptied - to keep the rail running right up to the taskbar.
function jawnosTimelineRail(ctx, fromY, toY) {
	var ink = jawnosInk();
	var rail = (typeof jawnosPrinterLine == 'function') ? jawnosPrinterLine() : ink;
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;
	ctx.save();
	ctx.lineCap = 'round';
	ctx.beginPath();
	ctx.moveTo(ctx.canvas.width / 2, fromY);
	ctx.lineTo(ctx.canvas.width / 2, toY);
	if (halo) {
		ctx.strokeStyle = halo;
		ctx.lineWidth = 12;
		ctx.stroke();
	}
	ctx.strokeStyle = rail;
	ctx.lineWidth = 8;
	ctx.stroke();
	ctx.restore();
}

function timelinePrinter(appts,sort,offset) {
	appPosition = [];
	var scope = localStorage.getItem('scope');
	var canvas = document.getElementById('timeline');

	$('#timeline').show();
	canvas.width = $('#background').width();

	var rowHeight = 40;
	// the span's band is tall enough for the appointment's own name (20px type)
	// to sit inside it, rather than the name overflowing a thin line
	var bandHeight = 28;
	// the occurrence mark is the same one the other printers draw: the app's
	// colour in a disc with a thin ink edge. The pseudonym's plate sits in its
	// middle, zoomed until it nearly fills the disc: the plate is a square, so
	// its corners are rounded to a circle just inside the ink edge, and the
	// appointment's colour still shows as a thin rim. The edge's inner radius is
	// 17 (dotRadius less half the ring), so the clip sits at 16.
	var dotRadius = 18;
	var dotRing = 2;   // the ink edge around the disc
	var dotHalo = 8;   // the theme's halo behind it, when the theme has one
	var dotIcon = 36;  // the plate, zoomed from 28 so the glyph reads at a glance
	var dotIconClip = 16; // the circle the plate's corners are rounded to
	var pad = 26;
	var top = headerHeight + clothesLineHeight + 26;
	var rows = 0;
	$.each(appts, function(i,v) {
		if ( i.match(/^__/) ) { return true; }
		if ( !v.setting || !v.list || v.list.length == 0 ) { return true; }
		rows++;
	});
	var needed = top + (rows * rowHeight) + pad;
	if (needed > $(window).height()) {
		$('#timeline').height(needed);
		canvas.height = needed;
	}
	else {
		canvas.height = $(window).height();
		$('#timeline').height(canvas.height);
	}
	ctx = canvas.getContext('2d');
	ctx.clearRect(0,clothesLineHeight,canvas.width,canvas.height);
	ctx.beginPath();
	headerPrinter(ctx,appts,'Timeline');

	var ink = jawnosInk();
	var darkTheme = (typeof jawnosTextureDark == 'function') ? jawnosTextureDark() : false;
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;

	// the rail the rows are hung from runs from the top of the clothesline - the
	// taskbar's own edge when one is worn at the top - down to the canvas's foot
	jawnosTimelineRail(ctx, headerHeight, canvas.height);

	var placement_number = 0;
	var textPrinter = [];
	// a dot pinned to an edge belongs flush with it: the scale's ends are half a
	// dot wide - the widest ring it wears - so the whole circle stays visible
	var dotEdge = dotRadius + (halo ? dotHalo : dotRing) / 2;
	var column = canvas.width - dotEdge * 2;
	// a ghost carries no percent of its own: it is placed from its moment the way
	// an edge-pinned row is, clamped to the same 0..2 a true percent runs over
	var ghostPct = function(l) {
		var pct = parseFloat(l[scope + '_percent']);
		if ( !isFinite(pct) && isFinite(l['timestamp']) ) {
			pct = (l['timestamp'] - appts['__specs']['start']) / (appts['__specs']['timestamp'] - appts['__specs']['start']);
		}
		if ( !isFinite(pct) ) { pct = 0; }
		return Math.min(Math.max(pct, 0), 2);
	};

	$.each(appts, function(i,v) {
		if ( i.match(/^__/) ) { return true; }
		if ( !v.setting || !v.list || v.list.length == 0 ) { return true; }
		var colour = jawnosApptColour(v.setting) || ink;
		var rowY;
		if (v['placement_number']) {
			rowY = v['placement_number'];
		}
		else {
			rowY = top + (placement_number * rowHeight);
			placement_number++;
			v['placement_number'] = rowY;
		}
		var named = false;
		// the line answers to a click where it is actually drawn - the band, the dot
		// and the words beside it - the way a leaderboard row does. It used to be cut
		// down to the dot and the text, which left the appointment's own band
		// unclickable; the whole width of the canvas is just as wrong the other way,
		// so the row's extent is measured while it is drawn.
		var rowLeft;
		var rowRight;
		// the box the press grows: the dots and the words drawn beside them, but
		// never the duration band. A band can reach the rail, making the row
		// hundreds of pixels wide, and a uniform scale of a box that wide reads as
		// a horizontal stretch that drags the icon and the name off the edge; the
		// item itself (the dot, its icon and its label) is compact, so it grows
		// the way a garment does
		var magLeft;
		var magRight;

		$.each(v.list, function(n,l) {
			if ( !l ) { return true; }
			// the window itself has no percent for a row it fetched beyond an edge,
			// and such a row belongs stuck against that edge: the one just past the
			// right edge has always stuck there, and the one carrying a still-
			// running appointment now sticks to the left, its band reaching in to
			// the rail
			var pct = parseFloat(l[scope + '_percent']);
			if ( !isFinite(pct) && isFinite(l['timestamp']) ) {
				pct = (l['timestamp'] - appts['__specs']['start']) / (appts['__specs']['timestamp'] - appts['__specs']['start']);
			}
			if ( !isFinite(pct) ) { pct = 0; }
			pct = Math.min(Math.max(pct, 0), 2);
			var x = dotEdge + (column * pct / 2);
			rowLeft = (rowLeft == undefined) ? (x - dotRadius) : Math.min(rowLeft, x - dotRadius);
			rowRight = (rowRight == undefined) ? (x + dotRadius) : Math.max(rowRight, x + dotRadius);
			magLeft = (magLeft == undefined) ? (x - dotEdge) : Math.min(magLeft, x - dotEdge);
			magRight = (magRight == undefined) ? (x + dotEdge) : Math.max(magRight, x + dotEdge);

			var startX;
			var startPct = parseFloat(l[scope + '_start_percent']);
			if ( !isFinite(startPct) && l['duration'] && isFinite(l['timestamp']) ) {
				startPct = (l['timestamp'] - l['duration'] - appts['__specs']['start']) / (appts['__specs']['timestamp'] - appts['__specs']['start']);
			}
			if ( isFinite(startPct) ) {
				startPct = Math.min(Math.max(startPct, 0), 2);
				startX = dotEdge + (column * startPct / 2);
				// the band is a bandHeight-wide stroke with round caps, so it reaches
				// half that past each of its ends - back from the dot for an ordinary
				// row, and ahead of it to the rail for one that is still running
				rowLeft = Math.min(rowLeft, Math.min(startX, x) - (bandHeight / 2));
				rowRight = Math.max(rowRight, Math.max(startX, x) + (bandHeight / 2));
				ctx.save();
				ctx.globalAlpha = 0.3;
				ctx.lineCap = 'round';
				ctx.beginPath();
				ctx.moveTo(startX, rowY);
				ctx.lineTo(x, rowY);
				if (typeof jawnosTextureStroke == 'function') { jawnosTextureStroke(ctx, colour, darkTheme, bandHeight); }
				else { ctx.lineWidth = bandHeight; ctx.strokeStyle = colour; ctx.stroke(); }
				ctx.restore();
			}

			// the dot: halo, the appointment's own colour in a disc, a thin ink
			// edge - the same mark the other printers draw - and the span's start
			// cap. The pseudonym's plate goes in its middle afterwards.
			ctx.save();
			if (halo) {
				ctx.strokeStyle = halo;
				ctx.lineWidth = dotHalo;
				ctx.beginPath();
				ctx.arc(x, rowY, dotRadius, 0, (Math.PI * 2));
				ctx.stroke();
			}
			if (typeof jawnosTextureFillCircle == 'function') { jawnosTextureFillCircle(ctx, x, rowY, dotRadius, colour, darkTheme); }
			else { ctx.fillStyle = colour; ctx.beginPath(); ctx.arc(x, rowY, dotRadius, 0, (Math.PI * 2)); ctx.fill(); }
			ctx.strokeStyle = ink;
			ctx.lineWidth = dotRing;
			ctx.beginPath();
			ctx.arc(x, rowY, dotRadius, 0, (Math.PI * 2));
			ctx.stroke();
			if (startX != undefined) {
				// the span's start wears the same small mark, so both ends of the
				// band read as the timeline's own dots rather than two vocabularies
				if (typeof jawnosTextureFillCircle == 'function') { jawnosTextureFillCircle(ctx, startX, rowY, 5, colour, darkTheme); }
				else { ctx.fillStyle = colour; ctx.beginPath(); ctx.arc(startX, rowY, 5, 0, (Math.PI * 2)); ctx.fill(); }
				ctx.strokeStyle = ink;
				ctx.lineWidth = 1.5;
				ctx.beginPath();
				ctx.arc(startX, rowY, 5, 0, (Math.PI * 2));
				ctx.stroke();
			}
			ctx.restore();

			// the pseudonym's own plate, centred in the dot and zoomed to fill it.
			// It draws when the image loads, so it lands on top of the disc above;
			// the round clip cuts its corners inside the ink edge, leaving the
			// appointment's colour as a thin rim.
			pseudoGenerator(appts,l['type'], x - (dotIcon / 2), rowY - (dotIcon / 2), dotIcon, dotIconClip);

			var labelX = x + 20;
			var labelEnd = labelX;
			var nameOnThisDot = false;
			if (!named) {
				named = true;
				nameOnThisDot = true;
				ctx.font = "400 20px Arial";
				textPrinter.push({ text: l['formatted_name'], x: labelX, y: rowY, font: "400 20px Arial" });
				labelEnd = labelX + ctx.measureText('' + l['formatted_name']).width;
			}
			if (l['total'] || l['amount']) {
				var amount = '$' + (l['total'] ? l['total'] : l['amount']);
				var amountX = nameOnThisDot ? labelEnd + 10 : labelX;
				textPrinter.push({ text: amount, x: amountX, y: rowY + 2, font: "400 14px Arial" });
				ctx.font = "400 14px Arial";
				labelEnd = amountX + ctx.measureText(amount).width;
			}
			rowRight = Math.max(rowRight, labelEnd);
			magRight = Math.max(magRight, labelEnd);
		});
		// the ghosts: what the habit predicts but nobody has made, on the row at the
		// place their moment works out to, faded, and pushed into nothing - a ghost
		// answers no press and adds nothing to the extent the row is measured by
		$.each(v.ghosts || [], function(g,gh) {
			if ( !gh || !isFinite(gh['timestamp']) ) { return true; }
			var gx = dotEdge + (column * ghostPct(gh) / 2);
			ctx.save();
			ctx.globalAlpha = 0.3;
			var gStartPct = parseFloat(gh[scope + '_start_percent']);
			if ( !isFinite(gStartPct) && gh['duration'] ) {
				gStartPct = (gh['timestamp'] - gh['duration'] - appts['__specs']['start']) / (appts['__specs']['timestamp'] - appts['__specs']['start']);
			}
			if ( isFinite(gStartPct) ) {
				gStartPct = Math.min(Math.max(gStartPct, 0), 2);
				var gStartX = dotEdge + (column * gStartPct / 2);
				ctx.lineCap = 'round';
				ctx.beginPath();
				ctx.moveTo(gStartX, rowY);
				ctx.lineTo(gx, rowY);
				if (typeof jawnosTextureStroke == 'function') { jawnosTextureStroke(ctx, colour, darkTheme, bandHeight); }
				else { ctx.lineWidth = bandHeight; ctx.strokeStyle = colour; ctx.stroke(); }
			}
			if (halo) {
				ctx.strokeStyle = halo;
				ctx.lineWidth = dotHalo;
				ctx.beginPath();
				ctx.arc(gx, rowY, dotRadius, 0, (Math.PI * 2));
				ctx.stroke();
			}
			if (typeof jawnosTextureFillCircle == 'function') { jawnosTextureFillCircle(ctx, gx, rowY, dotRadius, colour, darkTheme); }
			else { ctx.fillStyle = colour; ctx.beginPath(); ctx.arc(gx, rowY, dotRadius, 0, (Math.PI * 2)); ctx.fill(); }
			ctx.strokeStyle = ink;
			ctx.lineWidth = dotRing;
			ctx.beginPath();
			ctx.arc(gx, rowY, dotRadius, 0, (Math.PI * 2));
			ctx.stroke();
			ctx.restore();
		});
		// a row with nothing drawn has nothing to answer for
		if (rowLeft == undefined) { return true; }
		// the entry carries its own magnify box: the click answers over the whole
		// row, but only the compact item grows
		appPosition.push([rowLeft, rowY - dotRadius, rowRight, rowY + dotRadius, v, [magLeft, rowY - dotEdge, magRight, rowY + dotEdge]]);
	});

	$.each(textPrinter, function(i,t) {
		jawnosPrinterText(ctx, t.text, t.x, t.y, { font: t.font, colour: ink, halo: halo });
	});
}

// Icons are kept, not re-created per dot: a fresh Image for every draw made
// every reload wait for the icon all over again, so the dots landed first and
// the icons popped in a frame later - the flash. A kept image is already
// decoded and is drawn with the dots on every later pass; only the first time
// an icon appears does it wait for the network, once.
var pseudonymIcons = {};
function pseudoGenerator(appts,type,x,y,size,roundRadius) {
	var pseudonym = $.grep(appts['__specs']['pseudonyms'], function(n, i){ // just use arr
		return n['name'] == type;
	});

	if (pseudonym.length > 0) {
		size = size || 30;
		var src = pseudonym[0]['icon'];
		var icon = pseudonymIcons[src];
		if (!icon) {
			icon = pseudonymIcons[src] = { img: new Image, ready: 0, waiting: [] };
			icon.img.onload = function(){
				icon.ready = 1;
				$.each(icon.waiting, function(i,draw){ draw(); });
				icon.waiting = [];
			};
			icon.img.src = src;
		}
		var draw = function(){
			// a round radius cuts the plate's square corners, so a zoomed plate can
			// fill the disc without its corners poking through the ink edge
			if (roundRadius) {
				ctx.save();
				ctx.beginPath();
				ctx.arc(x + (size / 2), y + (size / 2), roundRadius, 0, (Math.PI * 2));
				ctx.clip();
			}
			ctx.drawImage(icon.img, x, y, size, size);
			if (roundRadius) { ctx.restore(); }
		};
		if (icon.ready) {
			draw();
		}
		else {
			icon.waiting.push(draw);
		}
	}
}
