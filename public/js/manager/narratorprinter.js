function narratorPrinter(appts) {
	appPosition = [];
	var presentLine = 0;
	var indent = 30;
	var position = 90 + clothesLineHeight;
	var scope = localStorage.getItem('scope');
	var canvas = document.getElementById('narrator');
	canvas.width = $('#background').width();


	var temp_height = (canvas.height * .13) + clothesLineHeight;
	$.each(appts,function(i,v) {
		if (!v.list) { return true; }
		temp_height = (temp_height + (numeral(100)).value());
	});

	if (temp_height > $(window).height()) {
		$('#narrator').height(temp_height);
		canvas.height = temp_height;
	}
	else {
		$('#narrator').height($(window).height());
		canvas.height = $(window).height();
	}

	ctx = canvas.getContext('2d');
	ctx.beginPath();
	headerPrinter(ctx,appts,'Narrator');

	ctx.font = "400 26px arial";
	var narration = [];
	$.each(appts, function(i,v) {
		if (typeof appts[i]['list'] !== undefined) {
			$.each(v['list'], function(item,value) {
				narration.push({ app: i, type: value['type'], server_time: value['server_time'], timestamp: value['timestamp'], text: appts[i]['formatted_name']});
			});
		}
	});
	narration.sort(function(a,b) {
		if (a['timestamp'] < b['timestamp']) { return -1 };
		if (a['timestamp'] > b['timestamp']) { return 1 }
		return 0;
	});

	$.each(narration, function(i,v) {
		if (presentLine == 0 && v.timestamp > appts['__specs']['timestamp']) {
				position = position + 10;
				ctx.moveTo(0, position);
				ctx.lineTo(canvas.width, position);
				presentLine = 1;
		}


		var textWidth = ctx.measureText(v['text']).width;
		var text = v['text'];
		pseudoGenerator(appts,v['type'],0, position + 5);

		var words = text.split(' ');
		var master_copy = text.split(' ');
		var page_width = canvas.width - indent;
		var current_line = '';
		$.each(words, function(n,word) {
			var current_width = ctx.measureText(current_line + ' ' + word).width + 30;
			var words_left = words.slice(n).join(' ');
			if (ctx.measureText(current_line + ' ' + words_left).width + 30 < page_width) {
				position = position + indent;
				ctx.fillText(current_line + ' ' + words_left, indent, position);
				appPosition.push([0 , position, indent + ctx.measureText(current_line + ' ' + words_left).width, position + 20, appts[v['app']]]);
				return false;
			}
			else {
				if (current_width > page_width) {
					position = position + indent;
					ctx.fillText(current_line, indent, position);
					appPosition.push([0 , position, indent + ctx.measureText(current_line).width, position + 20, appts[v['app']]]);
					current_line = word;
					if (words.length == n + 1) {
						position = position + indent;
						ctx.fillText(current_line, indent, position);
						appPosition.push([0 , position, indent + ctx.measureText(current_line).width, position + 20, appts[v['app']]]);
					}
				}
				else {
					current_line += ' ' + word;
				}
			}
		});
	});
	ctx.stroke();
	ctx.fill();
}