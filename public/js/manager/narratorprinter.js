// The narrator: every occurrence, in time order, as a paragraph. Lines wrap to
// the window, each paragraph hangs the app's icon and a colour tick in the
// left margin, and a rule marks the moment the payload was assembled.

function narratorPrinter(appts) {
	appPosition = [];
	var indent = 46;
	var lineHeight = 30;
	var font = '400 22px Arial';
	var top = headerHeight + clothesLineHeight + 30;
	var canvas = document.getElementById('narrator');
	canvas.width = $('#background').width();

	var ink = jawnosInk();
	var darkTheme = (typeof jawnosTextureDark == 'function') ? jawnosTextureDark() : false;
	var halo = typeof jawnosPrinterHalo == 'function' ? jawnosPrinterHalo() : undefined;
	var pageWidth = canvas.width - indent - 24;

	// every occurrence, in time order, and after each app's rows the occurrences a
	// habit predicts - a ghost is written as its own line and flagged so the draw
	// below can fade it, and it is never a press target
	var narration = [];
	$.each(appts, function(i,v) {
		if ( i.match(/^__/) ) { return true; }
		if ( !v['list'] ) { return true; }
		$.each(v['list'], function(item,value) {
			narration.push({ app: i, type: value['type'], server_time: value['server_time'], timestamp: value['timestamp'], text: v['formatted_name'] });
		});
		$.each(v['ghosts'] || [], function(gi,gh) {
			if ( !gh || !isFinite(gh['timestamp']) ) { return true; }
			narration.push({ app: i, type: gh['type'], server_time: gh['server_time'], timestamp: gh['timestamp'], text: gh['formatted_name'], ghost: 1 });
		});
	});
	narration.sort(function(a,b) {
		if (a['timestamp'] < b['timestamp']) { return -1; }
		if (a['timestamp'] > b['timestamp']) { return 1; }
		return 0;
	});

	// lay the paragraphs out first, so the canvas can be sized for all of them
	ctx = canvas.getContext('2d');
	ctx.font = font;
	var now = numeral(appts['__specs'] ? appts['__specs']['timestamp'] : undefined).value();
	if (!isFinite(now) || now <= 0) { now = Date.now(); }
	var y = top;
	var marked = false;
	var rules = [];
	var lines = [];
	$.each(narration, function(i,v) {
		if (!marked && v['timestamp'] > now) {
			marked = true;
			rules.push(y + 12);
			y += 26;
		}
		var words = String(v['text'] == undefined ? '' : v['text']).split(' ');
		var line = '';
		var first = true;
		$.each(words, function(w,word) {
			var attempt = line ? (line + ' ' + word) : word;
			if (line && ctx.measureText(attempt).width > pageWidth) {
				lines.push({ text: line, y: y, first: first, app: v['app'], type: v['type'], ghost: v['ghost'] });
				y += lineHeight;
				first = false;
				line = word;
			}
			else {
				line = attempt;
			}
		});
		if (line) {
			lines.push({ text: line, y: y, first: first, app: v['app'], type: v['type'], ghost: v['ghost'] });
			y += lineHeight;
		}
		y += 10;
	});

	var needed = y + 24;
	if (needed > $(window).height()) {
		$('#narrator').height(needed);
		canvas.height = needed;
	}
	else {
		canvas.height = $(window).height();
		$('#narrator').height(canvas.height);
	}
	ctx = canvas.getContext('2d');
	ctx.clearRect(0, 0, canvas.width, canvas.height);
	headerPrinter(ctx,appts,'Narrator');

	// the "as of" rule
	$.each(rules, function(i,ry) {
		ctx.save();
		ctx.strokeStyle = ink;
		ctx.globalAlpha = 0.5;
		ctx.lineWidth = 1.5;
		ctx.beginPath();
		ctx.moveTo(0, ry);
		ctx.lineTo(canvas.width, ry);
		ctx.stroke();
		ctx.globalAlpha = 0.7;
		ctx.restore();
		jawnosPrinterText(ctx, 'now', canvas.width - 40, ry - 10, { font: '400 13px Arial', colour: ink, halo: halo });
	});

	// the paragraphs
	$.each(lines, function(i,v) {
		var appt = appts[v['app']];
		var colour = (appt && jawnosApptColour(appt['setting'])) || ink;
		// a ghost's paragraph is the only thing that identifies it - there is no
		// label, amount or count riding on a line - so it is written the same way,
		// faded, and pushed nowhere: it answers no press
		if (v['ghost']) {
			ctx.save();
			ctx.globalAlpha = 0.3;
			if (v['first']) {
				if (typeof jawnosTextureFillRect == 'function') { jawnosTextureFillRect(ctx, indent - 14, v['y'] - 10, 4, 20, colour, darkTheme); }
				else { ctx.fillStyle = colour; ctx.fillRect(indent - 14, v['y'] - 10, 4, 20); }
			}
			jawnosPrinterText(ctx, v['text'], indent, v['y'], { font: font, colour: ink, halo: halo });
			ctx.restore();
			return true;
		}
		if (v['first']) {
			pseudoGenerator(appts, v['type'], 8, v['y'] - 11, 22);
			ctx.save();
			if (typeof jawnosTextureFillRect == 'function') { jawnosTextureFillRect(ctx, indent - 14, v['y'] - 10, 4, 20, colour, darkTheme); }
			else { ctx.fillStyle = colour; ctx.fillRect(indent - 14, v['y'] - 10, 4, 20); }
			ctx.restore();
		}
		jawnosPrinterText(ctx, v['text'], indent, v['y'], { font: font, colour: ink, halo: halo });
		ctx.font = font;
		appPosition.push([0, v['y'] - 14, indent + ctx.measureText(v['text']).width, v['y'] + 14, appt]);
	});
}
