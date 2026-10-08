var headerHeight = 50;
function headerPrinter(ctx,appts,title) {
	var canvas = document.getElementById(title.toLowerCase());
	$('#' + title.toLowerCase()).show();
	var scope = localStorage.getItem('scope');

	var formatted_time = fixedTimeString(numeral(appts['__specs']['timestamp']).value());
	var header = format_name(scope) + '<br>' + formatted_time;
	if (!windowPhoneChecker()) {
		header = header + ' ' + appts['__specs']['birthday'];
	}
	$('#header').html(header);

	// the divider under the header text - a moveTo alone never drew a line
	ctx.save();
	ctx.strokeStyle = 'yellow';
	ctx.lineWidth = 10;
	ctx.beginPath();
	ctx.moveTo(0, headerHeight);
	ctx.lineTo(canvas ? canvas.width : $(window).width(), headerHeight);
	reservedSpots['header'] = headerHeight - 4;
	ctx.stroke();
	ctx.restore();
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
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;
	var font = '600 20px Arial';
	ctx.font = font;

	// the left columns set the start of the time column, so long names do not
	// shove it into the numbers
	var nameWidth = 0;
	$.each(appt_store, function(i,v) {
		nameWidth = Math.max(nameWidth, ctx.measureText('' + v['shorthand_name']).width);
	});
	var timeX = 16 + nameWidth + 16;
	var rightLimit = canvas.width - 56;
	var presently = Date.now();
	var nowWatch = 0;

	$.each(appt_store, function(i,v) {
		var rowY = top + (i * lineHeight);
		var colour = v.setting.colour || ink;
		var status = v.setting.status;
		var rowTop = rowY - (lineHeight * 0.55);
		var rowHeight = lineHeight * 1.1;

		// the row: loud while recording, faint otherwise, ticked with the colour
		ctx.save();
		if (status == 'record' || status == 'start') {
			ctx.globalAlpha = 0.85;
			ctx.fillStyle = colour;
			ctx.fillRect(6, rowTop, rightLimit - 6, rowHeight);
		}
		else if (status == 'pause') {
			ctx.globalAlpha = 0.3;
			ctx.fillStyle = colour;
			ctx.fillRect(40, rowTop, rightLimit - 46, rowHeight);
		}
		else {
			ctx.globalAlpha = 0.05;
			ctx.fillStyle = ink;
			ctx.fillRect(6, rowTop, rightLimit - 6, rowHeight);
		}
		ctx.globalAlpha = 0.9;
		ctx.fillStyle = colour;
		ctx.fillRect(6, rowTop, 4, rowHeight);
		ctx.restore();

		// the left columns
		jawnosPrinterText(ctx, v['shorthand_name'], 16, rowY, { font: font, colour: ink, halo: halo });
		jawnosPrinterText(ctx, v['just_time'], timeX, rowY, { font: font, colour: ink, halo: halo });

		// the right columns, each honest about its own width: money first, then
		// duration, since, occurrences
		var columns = [];
		if (v[scope + '_percent'] != undefined && v[scope + '_percent'] !== '') { columns.push(numeral(v[scope + '_percent']).format('0%')); }
		if (v[scope + '_total']) { columns.push('$' + v[scope + '_total']); }
		if (v[scope + '_tax']) { columns.push('$' + v[scope + '_tax']); }
		if (v[scope + '_amount']) { columns.push('$' + v[scope + '_amount']); }
		columns.push(v[scope + '_formatted_duration']);
		columns.push(v['formatted_since']);
		if (v[scope + '_occurrences']) { columns.push(v[scope + '_occurrences']); }

		var cx = rightLimit;
		$.each(columns, function(ci,text) {
			if (text == undefined || text == '') { return true; }
			var w = ctx.measureText('' + text).width;
			jawnosPrinterText(ctx, text, cx - w, rowY, { font: font, colour: ink, halo: halo });
			cx = cx - w - 16;
		});

		// ring the first row whose moment has passed - the board's "you are here"
		if (!nowWatch && v['timestamp'] && v['timestamp'] < presently) {
			nowWatch = 1;
			ctx.save();
			ctx.strokeStyle = colour;
			ctx.lineWidth = 3;
			ctx.beginPath();
			ctx.arc(canvas.width - 26, rowY, 10, 0, (Math.PI * 2));
			ctx.stroke();
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
	var scroll = $(document).scrollTop();
	var x = e.clientX - numeral($(this).css('left')).value();
	var y = (e.clientY + scroll);


	var printer = localStorage.getItem('layout');
	var app_clicked = 0;
	ctx.save('click');
	ctx.moveTo(0,0);
	clearInterval(clothesLinePos['smoothScrolling']);
	clearInterval(clothesLinePos['timelineSmoothScrolling']);
	$.each(appPosition, function(i,o) {
		if (o[0] < x && o[2] > x &&
					o[1] < y && o[3] > y) {
			app_clicked = 1;
			var app = JSON.stringify(o[4]);
			var timestamp = Date.now();
			var canvas = document.getElementById(printer);
			var ctx = canvas.getContext('2d');
			ctx.fillStyle = jawnosInk();
			ctx.strokeStyle = jawnosInk();
			ctx.globalAlpha = 1;

			// at the point
			var count = 0;

			var move = setInterval(function(resp) {

				ctx.arc(x, y, 0, count, (Math.PI*2), true);
				ctx.stroke();
			//	ctx.fill();


				if (count > 45) {
					ctx.restore('click');
					clearInterval(move);
				}
				count++;
			},13);
			var sapp = JSON.stringify({ 'name': o[4]['name'] });
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
	$('#now_toggle').trigger('click');
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
