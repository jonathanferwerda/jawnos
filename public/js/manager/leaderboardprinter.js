// The band above the clothesline is gone - the scope and the desk's birthday
// went with it - so nothing is reserved there unless a taskbar has taken the
// top edge; taskbar.js measures that and writes it back here.
var headerHeight = 0;
function headerPrinter(ctx,appts,title) {
	var canvas = document.getElementById(title.toLowerCase());
	$('#' + title.toLowerCase()).show();

	var formatted_time = fixedTimeString(numeral(appts['__specs']['timestamp']).value());
	// the clock lives in the taskbar while there is one - it reads the raw
	// timestamp so a phone can wear its shorter two-line face - and the header
	// span keeps only the clock's fallback home for when that bar is set away
	var clock_in_bar = (typeof jawnosClockInTaskbar == 'function') && jawnosClockInTaskbar();
	if (typeof jawnosClockShow == 'function') { jawnosClockShow(numeral(appts['__specs']['timestamp']).value()); }
	$('#header').html(clock_in_bar ? '' : formatted_time);

	// the divider under the old header text - a moveTo alone never drew a line -
	// stands only while a top taskbar has lifted the rows down
	if (headerHeight > 0) {
		ctx.save();
		ctx.strokeStyle = 'yellow';
		ctx.lineWidth = 10;
		ctx.beginPath();
		ctx.moveTo(0, headerHeight);
		ctx.lineTo(canvas ? canvas.width : $(window).width(), headerHeight);
		ctx.stroke();
		ctx.restore();
	}
	reservedSpots['header'] = Math.max(0, headerHeight - 4);
}


var appPosition;
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

$(document).on('click', '.background', function (e) {
	// a mouse grab that moved the timeline ends with a click; it is not a
	// selection of whatever the pointer happened to stop on
	if (clothesLinePos['dragged']) {
		clothesLinePos['dragged'] = 0;
		return;
	}
	var scroll = $(document).scrollTop();
	var x = e.clientX - numeral($(this).css('left')).value();
	var y = (e.clientY + scroll);


	var printer = localStorage.getItem('layout');
	var app_clicked = 0;
	// both glides run on requestAnimationFrame now; cancelAnimationFrame is how
	// they stop (clearInterval on a frame handle does nothing)
	cancelAnimationFrame(clothesLinePos['smoothScrolling']);
	cancelAnimationFrame(clothesLinePos['timelineSmoothScrolling']);
	$.each(appPosition, function(i,o) {
		if (o[0] < x && o[2] > x &&
					o[1] < y && o[3] > y) {
			app_clicked = 1;
			var timestamp = Date.now();
			// the press answers on the thing it landed on - the dot and its words, or
			// the clockface dot and label, grow for half a second; a garment wearing
			// a material goes down instead, while plain, round and classic garment
			// tiles still grow and wear a thicker edge. An entry may carry its own
			// magnify box as a sixth element (the timeline's rows do: the whole row
			// answers the click, but only its compact dot-and-words item should grow)
			var magnify_rect = (o.length > 5 && o[5]) ? o[5] : o;
			// the press outline follows a garment's pill shape; the other canvas
			// items keep their gently rounded corners
			var magnify_radius = (o[4] && o[4]['type'] == 'clothes')
				? Math.min(magnify_rect[2] - magnify_rect[0], magnify_rect[3] - magnify_rect[1]) / 2
				: 10;
			// a garment wearing a material goes down like a key: its raised sheen
			// becomes an inset shade while it is pressed. Plain, round and classic
			// keep the original grow-on-press.
			var textured_clothes = (o[4] && o[4]['type'] == 'clothes')
				&& typeof jawnosTextureBare == 'function'
				&& typeof jawnosTextureCurrent != 'undefined'
				&& !jawnosTextureBare(jawnosTextureCurrent);
			if (textured_clothes && typeof jawnosClickPress == 'function') {
				jawnosClickPress(document.getElementById(printer), magnify_rect, 0.35, magnify_radius);
			}
			else if (typeof jawnosClickMagnify == 'function') {
				jawnosClickMagnify(document.getElementById(printer), magnify_rect, 0.5, (o[4] && o[4]['type'] == 'clothes') ? 4 : 0, magnify_radius);
			}
			appointmentGrabber(o[4]['name'],timestamp);
			return false;
		}
	});
	if (app_clicked == 0 && device == 'mobile') {
		var ph = $('#pseudonym_home').offset();
		pseudonymHomeShower(ph.left + 3, ph.top + 3);
	}

	$('.search_results').hide();

});

$(document).on('dblclick', '.background', function() {
	// back to the present, the same thing the now button does
	nowResetter();
});

$(document).on('mousemove', '.background', function(e) {
	var scroll = $(document).scrollTop();
	var x = e.clientX - numeral($(this).css('left')).value();
	var y = (e.clientY + scroll);
	var hovering = 0;
	$.each(appPosition, function(i,o) {
		if (o[0] < x && o[2] > x &&
			o[1] < y && o[3] > y) {
			hovering = 1;
		}
	});
	if (hovering == 1) {
		$('.background').css({'cursor': 'pointer'});
	}
	else {
		$('.background').css({'cursor': 'auto'});
	}
});
