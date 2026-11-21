// headerPrinter, headerHeight and appPosition are in printer_common.js: the
// desk's background fallback and clothesline need them without loading this
// lazy chunk.
function leaderboardPrinter(appts) {
	appPosition = [];
	var lineHeight = 30;
	var scope = localStorage.getItem('scope');
	var sorts = localStorage.getItem('sorts');
	var filter = scope + '_' + sorts;
	$('#leaderboard').show();
	var canvas = document.getElementById('leaderboard');
	canvas.width = $('#background').width();

	// one row per app that has a value for the current scope+sort, biggest first
	var appt_storage = [];
	$.each(appts, function(appt_n,appt) {
		if (appt_n.match(/^__/)) { return true; }
		if (!appt['setting'] || !appt[filter]) { return true; }
		appt_storage.push(appt);
	});
	var appt_store = appt_storage.sort(function(a, b) { return b[filter] - a[filter]; });

	var top = headerHeight + clothesLineHeight + 26;
	var rowsHeight = top + (appt_store.length * lineHeight) + 40;
	if (rowsHeight > $(window).height()) {
		$('#leaderboard').height(rowsHeight);
		canvas.height = rowsHeight;
	}
	else {
		canvas.height = $(window).height();
		$('#leaderboard').height(canvas.height);
	}
	ctx = canvas.getContext('2d');
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	headerPrinter(ctx,appts,'Leaderboard');

	var ink = jawnosInk();
	var darkTheme = (typeof jawnosTextureDark == 'function') ? jawnosTextureDark() : false;
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;
	var font = '600 20px Arial';
	ctx.font = font;

	// the right columns, each honest about its own width: money first, then
	// duration, since, occurrences. Built here because the name column has to be
	// measured against where they start.
	var rightLimit = canvas.width - 56;
	var rowColumns = function(v) {
		var columns = [];
		if (v[scope + '_percent'] != undefined && v[scope + '_percent'] !== '') { columns.push(numeral(v[scope + '_percent']).format('0%')); }
		if (v[scope + '_total']) { columns.push('$' + v[scope + '_total']); }
		if (v[scope + '_tax']) { columns.push('$' + v[scope + '_tax']); }
		if (v[scope + '_amount']) { columns.push('$' + v[scope + '_amount']); }
		columns.push(v[scope + '_formatted_duration']);
		columns.push(v['formatted_since']);
		if (v[scope + '_occurrences']) { columns.push(v[scope + '_occurrences']); }
		return columns;
	};
	var columnsLeft = function(v) {
		var cx = rightLimit;
		$.each(rowColumns(v), function(ci,text) {
			if (text == undefined || text == '') { return true; }
			cx = cx - ctx.measureText('' + text).width - 16;
		});
		return cx;
	};

	// the left columns set the start of the time column, so long names do not
	// shove it into the numbers. The full name is used while the widest of them
	// still leaves the time column clear of the right-hand columns; otherwise
	// only the shorthand fits.
	var shortWidth = 0;
	var fullWidth = 0;
	var timeWidth = 0;
	var leftEdge = rightLimit;
	$.each(appt_store, function(i,v) {
		shortWidth = Math.max(shortWidth, ctx.measureText('' + v['shorthand_name']).width);
		fullWidth = Math.max(fullWidth, ctx.measureText('' + (v['formatted_name'] || v['shorthand_name'])).width);
		timeWidth = Math.max(timeWidth, ctx.measureText('' + v['just_time']).width);
		leftEdge = Math.min(leftEdge, columnsLeft(v));
	});
	var nameKey = (16 + fullWidth + 16 + timeWidth <= leftEdge) ? 'formatted_name' : 'shorthand_name';
	var nameWidth = (nameKey == 'formatted_name') ? fullWidth : shortWidth;
	var timeX = 16 + nameWidth + 16;
	var presently = Date.now();
	var nowWatch = 0;

	$.each(appt_store, function(i,v) {
		var rowY = top + (i * lineHeight);
		var colour = jawnosApptColour(v.setting) || ink;
		var status = v.setting.status;
		var rowTop = rowY - (lineHeight * 0.55);
		var rowHeight = lineHeight * 1.1;

		// the row: loud while recording, faint otherwise, ticked with the colour
		ctx.save();
		if (status == 'record' || status == 'start') {
			ctx.globalAlpha = 0.85;
			if (typeof jawnosTextureFillRect == 'function') { jawnosTextureFillRect(ctx, 6, rowTop, rightLimit - 6, rowHeight, colour, darkTheme); }
			else { ctx.fillStyle = colour; ctx.fillRect(6, rowTop, rightLimit - 6, rowHeight); }
		}
		else if (status == 'pause') {
			ctx.globalAlpha = 0.3;
			if (typeof jawnosTextureFillRect == 'function') { jawnosTextureFillRect(ctx, 40, rowTop, rightLimit - 46, rowHeight, colour, darkTheme); }
			else { ctx.fillStyle = colour; ctx.fillRect(40, rowTop, rightLimit - 46, rowHeight); }
		}
		else {
			ctx.globalAlpha = 0.05;
			ctx.fillStyle = ink;
			ctx.fillRect(6, rowTop, rightLimit - 6, rowHeight);
		}
		ctx.globalAlpha = 0.9;
		if (typeof jawnosTextureFillRect == 'function') { jawnosTextureFillRect(ctx, 6, rowTop, 4, rowHeight, colour, darkTheme); }
		else { ctx.fillStyle = colour; ctx.fillRect(6, rowTop, 4, rowHeight); }
		ctx.restore();

		// the left columns
		jawnosPrinterText(ctx, (v[nameKey] || v['shorthand_name']), 16, rowY, { font: font, colour: ink, halo: halo });
		jawnosPrinterText(ctx, v['just_time'], timeX, rowY, { font: font, colour: ink, halo: halo });

		// the right columns, laid out from the right
		var columns = rowColumns(v);

		var cx = rightLimit;
		$.each(columns, function(ci,text) {
			if (text == undefined || text == '') { return true; }
			var w = ctx.measureText('' + text).width;
			jawnosPrinterText(ctx, text, cx - w, rowY, { font: font, colour: ink, halo: halo });
			cx = cx - w - 16;
		});

		// the ghosts: what the app is predicted to make, worn on its own row as faded
		// pips after the time - the board has no time axis to place them on - and
		// pushed nowhere, so a ghost is no part of the row's extent
		if (v['ghosts'] && v['ghosts'].length) {
			var pipX = timeX + timeWidth + 12;
			$.each(v['ghosts'].slice(0, 8), function(gi,gh) {
				if ( !gh || !isFinite(gh['timestamp']) ) { return true; }
				ctx.save();
				ctx.globalAlpha = 0.3;
				if (typeof jawnosTextureFillCircle == 'function') { jawnosTextureFillCircle(ctx, pipX, rowY, 4, colour, darkTheme); }
				else { ctx.fillStyle = colour; ctx.beginPath(); ctx.arc(pipX, rowY, 4, 0, (Math.PI * 2)); ctx.fill(); }
				ctx.strokeStyle = ink;
				ctx.lineWidth = 1;
				ctx.stroke();
				ctx.restore();
				pipX += 11;
			});
		}

		// ring the first row whose moment has passed - the board's "you are here"
		if (!nowWatch && v['timestamp'] && v['timestamp'] < presently) {
			nowWatch = 1;
			ctx.save();
			ctx.beginPath();
			ctx.arc(canvas.width - 26, rowY, 10, 0, (Math.PI * 2));
			if (typeof jawnosTextureStroke == 'function') { jawnosTextureStroke(ctx, colour, darkTheme, 3); }
			else { ctx.strokeStyle = colour; ctx.lineWidth = 3; ctx.stroke(); }
			ctx.strokeStyle = ink;
			ctx.lineWidth = 1.5;
			ctx.beginPath();
			ctx.arc(canvas.width - 26, rowY, 10, 0, (Math.PI * 2));
			ctx.stroke();
			ctx.restore();
		}

		appPosition.push([0, rowY - (lineHeight / 2), canvas.width, rowY + (lineHeight / 2), v]);
	});
}
