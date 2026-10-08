// The month grid: seven columns, a row per week, weekday labels, day numbers,
// today ringed in ink, and a coloured dot per app with something on that day.
// The month shown is the month of the payload timestamp.

function calendarPrinter(appts,sort) {
	var canvas = document.getElementById('calendar');
	canvas.width = $(window).width();
	canvas.height = $(window).height();
	ctx = canvas.getContext('2d');
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	headerPrinter(ctx,appts,'Calendar');

	var ink = jawnosInk();
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;
	var ts = numeral(appts['__specs'] ? appts['__specs']['timestamp'] : undefined).value();
	if (!isFinite(ts) || ts <= 0) { ts = Date.now(); }
	var now = new Date(ts);
	var year = now.getFullYear();
	var month = now.getMonth();
	var today = new Date();
	var isThisMonth = today.getFullYear() == year && today.getMonth() == month;

	var firstDay = new Date(year, month, 1).getDay();
	var daysInMonth = new Date(year, month + 1, 0).getDate();
	var weeks = Math.ceil((firstDay + daysInMonth) / 7);

	var monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
		'July', 'August', 'September', 'October', 'November', 'December'];
	var weekNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

	// which apps have something on which day of the month
	var spots = {};
	$.each(appts, function(i,v) {
		if ( i.match(/^__/) ) { return true; }
		$.each(v['list'] || [], function(n,l) {
			var t = numeral(l['timestamp']).value();
			if (!isFinite(t) || t <= 0) { return true; }
			var d = new Date(t);
			if (d.getFullYear() != year || d.getMonth() != month) { return true; }
			var day = d.getDate();
			if (!spots[day]) { spots[day] = []; }
			var colour = (v['setting'] && v['setting']['colour']) || ink;
			if (spots[day].indexOf(colour) == -1) { spots[day].push(colour); }
		});
	});

	// geometry: the grid is centred and sized for the window
	var gridTop = headerHeight + clothesLineHeight + 46;
	var cell = Math.floor(Math.min(canvas.width - 48, 1000) / 7);
	var gridWidth = cell * 7;
	var left = Math.round((canvas.width - gridWidth) / 2);
	var rowHeight = Math.floor(Math.min((canvas.height - gridTop - 24) / weeks, cell * 0.82));
	rowHeight = Math.max(rowHeight, 30);

	// the month, named, and the weekday labels
	jawnosPrinterText(ctx, monthNames[month] + ' ' + year, canvas.width / 2, headerHeight + clothesLineHeight + 20,
		{ font: '600 22px Arial', align: 'center', colour: ink, halo: halo });
	for (var c = 0; c < 7; c++) {
		jawnosPrinterText(ctx, weekNames[c], left + c * cell + (cell / 2), gridTop - 18,
			{ font: '600 15px Arial', align: 'center', colour: ink, halo: halo, alpha: 0.75 });
	}

	// the grid
	ctx.save();
	ctx.strokeStyle = ink;
	ctx.lineWidth = 1;
	ctx.globalAlpha = 0.25;
	for (var r = 0; r <= weeks; r++) {
		ctx.beginPath();
		ctx.moveTo(left, gridTop + r * rowHeight);
		ctx.lineTo(left + gridWidth, gridTop + r * rowHeight);
		ctx.stroke();
	}
	for (var c2 = 0; c2 <= 7; c2++) {
		ctx.beginPath();
		ctx.moveTo(left + c2 * cell, gridTop);
		ctx.lineTo(left + c2 * cell, gridTop + weeks * rowHeight);
		ctx.stroke();
	}
	ctx.restore();

	for (var day = 1; day <= daysInMonth; day++) {
		var slot = firstDay + day - 1;
		var cx = left + (slot % 7) * cell;
		var cy = gridTop + Math.floor(slot / 7) * rowHeight;
		var dow = slot % 7;

		// weekends get a whisper of shade
		if (dow == 0 || dow == 6) {
			ctx.save();
			ctx.globalAlpha = 0.05;
			ctx.fillStyle = ink;
			ctx.fillRect(cx, cy, cell, rowHeight);
			ctx.restore();
		}
		// today gets a ring
		if (isThisMonth && today.getDate() == day) {
			ctx.save();
			ctx.globalAlpha = 0.12;
			ctx.fillStyle = ink;
			ctx.fillRect(cx, cy, cell, rowHeight);
			ctx.globalAlpha = 0.8;
			ctx.strokeStyle = ink;
			ctx.lineWidth = 2;
			ctx.strokeRect(cx + 1, cy + 1, cell - 2, rowHeight - 2);
			ctx.restore();
		}

		jawnosPrinterText(ctx, day, cx + 8, cy + 14, { font: '400 17px Arial', colour: ink, halo: halo });

		// a dot per app that has something on the day
		var colours = spots[day] || [];
		var dx = cx + 11;
		var dy = cy + rowHeight - 10;
		$.each(colours.slice(0, 8), function(i2,colour) {
			ctx.save();
			ctx.fillStyle = colour;
			ctx.beginPath();
			ctx.arc(dx, dy, 4, 0, (Math.PI * 2));
			ctx.fill();
			ctx.strokeStyle = ink;
			ctx.lineWidth = 1;
			ctx.stroke();
			ctx.restore();
			dx += 11;
			if (dx > cx + cell - 10) { dx = cx + 11; dy -= 10; }
		});
	}
}
