// The timeline: one row per app, a dot per occurrence placed by its percent,
// money beside the dot, and the span from the start percent to the percent
// drawn as a faded band behind it. A percent runs over the scope either side
// of now: 1 is the rail, 2 is a scope ahead, 0 a scope behind, so now hangs
// mid-canvas with the future to its right. Rows begin under the header and
// the clothesline, and the canvas grows to hold every app.

var appPosition = [];
function timelinePrinter(appts,sort,offset) {
	appPosition = [];
	var scope = localStorage.getItem('scope');
	var canvas = document.getElementById('timeline');

	$('#timeline').show();
	canvas.width = $('#background').width();

	var rowHeight = 34;
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
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;

	// the yellow rail the rows are hung from
	ctx.save();
	ctx.strokeStyle = 'yellow';
	ctx.lineWidth = 8;
	ctx.lineCap = 'round';
	ctx.beginPath();
	ctx.moveTo(canvas.width / 2, 80);
	ctx.lineTo(canvas.width / 2, canvas.height);
	ctx.stroke();
	ctx.restore();

	var placement_number = 0;
	var textPrinter = [];
	var column = canvas.width - pad * 2;

	$.each(appts, function(i,v) {
		if ( i.match(/^__/) ) { return true; }
		if ( !v.setting || !v.list || v.list.length == 0 ) { return true; }
		var colour = v.setting.colour || ink;
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
		var hit = [canvas.width, rowY - 16, 0, rowY + 16, v];

		$.each(v.list, function(n,l) {
			if ( !l ) { return true; }
			var pct = parseFloat(l[scope + '_percent']);
			if ( !isFinite(pct) ) { pct = 0; }
			pct = Math.min(Math.max(pct, 0), 2);
			var x = pad + (column * pct / 2);

			var startX;
			var startPct = parseFloat(l[scope + '_start_percent']);
			if ( isFinite(startPct) ) {
				startPct = Math.min(Math.max(startPct, 0), 2);
				startX = pad + (column * startPct / 2);
				ctx.save();
				ctx.globalAlpha = 0.3;
				ctx.strokeStyle = colour;
				ctx.lineWidth = 16;
				ctx.lineCap = 'round';
				ctx.beginPath();
				ctx.moveTo(startX, rowY);
				ctx.lineTo(x, rowY);
				ctx.stroke();
				ctx.restore();
			}

			// the pseudonym's own icon, hung to the left of the dot
			if ( x - 44 > 0 ) {
				pseudoGenerator(appts,l['type'], x - 40, rowY - 12, 24);
				if (x - 44 < hit[0]) { hit[0] = x - 44; }
			}

			// the dot: halo, ink disc, coloured ring, and the span's end cap
			ctx.save();
			if (halo) {
				ctx.strokeStyle = halo;
				ctx.lineWidth = 7;
				ctx.beginPath();
				ctx.arc(x, rowY, 9, 0, (Math.PI * 2));
				ctx.stroke();
			}
			ctx.fillStyle = ink;
			ctx.beginPath();
			ctx.arc(x, rowY, 9, 0, (Math.PI * 2));
			ctx.fill();
			ctx.strokeStyle = colour;
			ctx.lineWidth = 4;
			ctx.beginPath();
			ctx.arc(x, rowY, 9, 0, (Math.PI * 2));
			ctx.stroke();
			if (startX != undefined) {
				ctx.lineWidth = 3;
				ctx.beginPath();
				ctx.arc(startX, rowY, 5, 0, (Math.PI * 2));
				ctx.stroke();
			}
			ctx.restore();

			var labelX = x + 16;
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
			if (labelEnd > hit[2]) { hit[2] = labelEnd; }
			if (x - 14 < hit[0]) { hit[0] = x - 14; }
			if (x + 14 > hit[2]) { hit[2] = x + 14; }
		});
		if (hit[0] < 0) { hit[0] = 0; }
		if (hit[2] > canvas.width) { hit[2] = canvas.width; }
		appPosition.push(hit);
	});

	$.each(textPrinter, function(i,t) {
		jawnosPrinterText(ctx, t.text, t.x, t.y, { font: t.font, colour: ink, halo: halo });
	});
}

function pseudoGenerator(appts,type,x,y,size) {
	var pseudonym = $.grep(appts['__specs']['pseudonyms'], function(n, i){ // just use arr
		return n['name'] == type;
	});

	if (pseudonym.length > 0) {
		size = size || 30;
		var img = new Image;
		img.onload = function(){
			ctx.drawImage(img,x,y, size, size);
		};
		img.src = pseudonym[0]['icon'];
	}
}
