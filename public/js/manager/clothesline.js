var clothesLineHeight = 40;
var clothesLinePos = {
	x: 0, 
	y: 0, 
	minHeight: 0, 
	maxHeight: 0, 
	lastBX: undefined, 
	lastX: undefined, 
	moving: Date.now() - 300, 
	startMove: undefined,
	exists: 0,
	bordersize: 5
};
var wardrobe = [];
var hangingClothes = 0;
function clotheslineHanger(clothes) {

	if (hangingClothes == 0) {
		hangingClothes = 1;
		wardrobe = clothes;
		var maxWidth = 140;
		var totalWidth = maxWidth * clothes.length;
		var layout = localStorage.getItem('layout');
		var canvas = document.getElementById(layout);
		ctx = canvas.getContext('2d');
		ctx.strokeStyle = 'black';
		ctx.lineWidth = clothesLinePos['bordersize'];
		ctx.beginPath();

		var minHeight = headerHeight;
		var maxHeight = minHeight + (clothesLineHeight);
		clothesLinePos['minHeight'] = minHeight;
		clothesLinePos['maxHeight'] = maxHeight;
		if (clothes.length > 0) {
			clothesLinePos['exists'] = 1;
			ctx.clearRect(0,minHeight,canvas.width,clothesLineHeight);
			ctx.moveTo(0,minHeight);
			ctx.lineTo(canvas.width, minHeight);
			ctx.moveTo(0,minHeight + clothesLineHeight);
			ctx.lineTo(canvas.width,minHeight + clothesLineHeight);
			ctx.stroke();
		}

		ctx.font = "400 20px Times New Roman";

		$.each(clothes, function(i,v) {

			v['type'] = 'clothes';
			var clothingDrive = [];
			$.each(appPosition, function(ie,ve) {
				if (v['app'] == ve[4]['app'] && v['type'] == 'clothes') {
					clothingDrive.push(ie);
				}
			});
			$.each(clothingDrive.reverse(), function(ie,ve) {
				appPosition.splice(ve,1);
			});
			var startW = (i * maxWidth) + clothesLinePos['x'];
			var endW = startW + maxWidth;

			ctx.fillStyle = v.colour || 'yellow';
			ctx.strokeRect(startW,minHeight,maxWidth,clothesLineHeight);
			ctx.fillRect(startW,minHeight,maxWidth,clothesLineHeight);
			ctx.fill();
			ctx.fillStyle = 'black';
			var textMeasure = ctx.measureText(v.formatted_name).width;
			var textPos = ((maxWidth - textMeasure) / 2) + startW;
			ctx.fillText(v.formatted_name,  textPos ,  maxHeight - (clothesLineHeight / 3));
			ctx.fill();
			ctx.stroke();

			appPosition.push([startW , minHeight , endW, maxHeight, v]);
		});
		hangingClothes = 0;
	}
}


$(document).on('touchmove', '.background', function(m) {
	var w = $(this);
	var id = $(this).attr('id');
	clothesLinePos['moveTimeout'] = timestamp;
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	if (m.originalEvent.targetTouches) {
		x = m.originalEvent.targetTouches[0].clientX;
		y = m.originalEvent.targetTouches[0].clientY;
	}
	x = numeral(x - w.offset().left).value();
	y = numeral(y - w.offset().top).value();
	if ((y <= clothesLinePos['maxHeight'] && y >= clothesLinePos['minHeight']) && (clothesLinePos['startMove'] == undefined || clothesLinePos['startMove'] == 'clothesline')) {
		if (clothesLinePos['lastX'] == undefined) {
			clothesLinePos['lastX'] = x;
		}
		if (clothesLinePos['startMove'] == undefined) {
			clothesLinePos['startMove'] = 'clothesline';
		}
		var mouseDiff = x - clothesLinePos['lastX'];
		clothesLinePos['lastX'] = x;
		clothesLinePos['x'] += mouseDiff;
		clothesLinePos['y'] = y;
		if (clothesLinePos['startMove'] == 'clothesline') {
			clotheslineScroller(x,y,(mouseDiff * .4));
		}
	}
	else if ((y >= clothesLinePos['maxHeight'] && (id == 'timeline' || id == 'clockface')) && ( clothesLinePos['startMove'] == undefined || clothesLinePos['startMove'] == 'canvas')) {
		clothesLinePos['moving'] = Date.now();
		if (clothesLinePos['lastBX'] == undefined) {
				clothesLinePos['lastBX'] = x;
		}
		var mouseDiff = (x - clothesLinePos['lastBX']);
		clothesLinePos['lastBX'] = x;
		if (clothesLinePos['startMove'] == undefined) {
			clothesLinePos['startMove'] = 'canvas';
		}
		if (clothesLinePos['startMove'] == 'canvas') {

			if (id == 'timeline') {
				timelineScroller({ mousediff: mouseDiff });
			}
			else if (id == 'clockface') {
				clockfaceScroller({ mousediff: diff });
			}
		}
	}

});
$(document).on('mouseout touchend mouseup', '.background', function() {
	if (clothesLinePos['lastBX']) {
	//	calculator();
	}
	clothesLinePos['lastX'] = undefined;
	clothesLinePos['lastBX'] = undefined;
	clothesLinePos['startMove'] = undefined;
	//clothesLinePos['velocities'] = [];
});

$(document).on('mousewheel', '.background', function(e) {
	clothesLinePos['moving'] = Date.now();
	var w = $(this);
	var id = $(this).attr('id');
	var mvmt = numeral(e.originalEvent.wheelDelta).value();

	var diff = -1 * (numeral(mvmt / 5).value());
	var m = mouse_position();
	var x = m.x;
	var y = m.y;

	if (y <= clothesLinePos['maxHeight'] && y >= clothesLinePos['minHeight']) {
		if (clothesLinePos['startMove'] == undefined) {
			clothesLinePos['startMove'] = 'clothesline';
		}
		if (clothesLinePos['startMove'] == 'clothesline') {
			var source;
 			if (Math.abs(e.deltaY) > 4 && Math.abs(e.deltaX) === 0) {
				source = 'mousewheel';
			}

			clotheslineScroller(x,y,(diff * .4), source);
		}
	}
	else if (y >= clothesLinePos['maxHeight'] && (id == 'timeline' || id == 'clockface')) {
		if (clothesLinePos['startMove'] == undefined) {
			clothesLinePos['startMove'] = 'canvas';
		}
		if (clothesLinePos['startMove'] == 'canvas') {
			if (id == 'timeline') {
				timelineScroller({ mousediff: diff });
			}
			else if (id == 'clockface') {
				clockfaceScroller({ mousediff: diff });
			}
		}
	}
	clothesLinePos['startMove'] = undefined;
});

function clotheslineScroller(x,y,diff,source) {
	if (y >= clothesLinePos['minHeight'] && y <= clothesLinePos['maxHeight']) {
		clothesLinePos['x'] = clothesLinePos['x'] + diff;
		clotheslineHanger(wardrobe);
		if (source != 'smoothScroll' && source != 'mousewheel') {
			clearInterval(clothesLinePos['smoothScrolling']);
			clothesLinePos['smoothScrolling'] = setInterval(function() {
				if (Math.abs(diff) > 0.09) {
					diff = diff * .97;
					clotheslineScroller(x,y,diff,'smoothScroll')
				}
				else { clearInterval(clothesLinePos['smoothScrolling']); }
			},5);
		}
	}
}


function clockfaceScroller(data) {
	if (data.mousediff < 0) {
		localStorage.setItem('scrollPositioner', 	localStorage.getItem('scrollPositioner') * 1.05);
	}
	else {
		localStorage.setItem('scrollPositioner', 	localStorage.getItem('scrollPositioner') * .95);
	}
	graphicalize(response);
}

function timelineScroller(data) {
	var wp = 0;
	var span = response.appts['__specs']['end'] - response.appts['__specs']['start'];
	var ww = $('#background').width();

		
	if (data.mousediff) {
		wp = data.mousediff / ww;
	}
	else if (data.diff) {
		wp = (data.diff) / span;
	}

	var sdiff = span * wp;
	if (data['sdiff']) {
		sdiff = data['sdiff'];
	}
	else {
		data['sdiff'] = sdiff;
	}

	var scope = localStorage.getItem('scope');
	var period = response.appts['__specs']['period'];
	response.appts['__specs']['end'] = response.appts['__specs']['end'] - sdiff;
	response.appts['__specs']['start'] = response.appts['__specs']['start'] - sdiff;
	response.appts['__specs']['timestamp'] = (numeral(response.appts['__specs']['timestamp']).value() - sdiff);

	var ts = quality_inventory(numeral(response.appts['__specs']['timestamp']).value() );
	if (!$('#time_machine').is(':focus') && data.mousediff) {
		$('#time_machine').val(ts)
		localStorage.setItem('time_machine', ts);
	}
//	timestamp = response.appts['__specs']['timestamp'];
	$.each(response.appts, function(i,ve) {

		if (!i.match('__')) {
			$.each(ve['list'], function(ie,v) {
				var point = v['timestamp'] - response.appts['__specs']['start'];
				var total = response.appts['__specs']['timestamp'] - response.appts['__specs']['start'];
				var percent = point / total;
				v[scope + '_percent'] = percent;
				if (v['duration']) {
					point = v['timestamp'] - v['duration'] - response.appts['__specs']['start'];
					percent = point / total;
					v[scope + '_start_percent'] = percent;
					if (v['type'] == 'start' && v['timestamp'] < response.appts['__specs']['timestamp']) {
						var dur = (response['appts']['__specs']['timestamp'] - v['timestamp']) * -1;
						if (v['duration'] > dur) { v['duration'] = dur; }
					}
				}
				ve['placement_number'] = undefined;
			});
		}
	});
	graphicalize(response);
	if (data['source'] != 'smoothScroll' && 1 == 0) {
		clearInterval(clothesLinePos['timelineSmoothScrolling']);
		clothesLinePos['timelineSmoothScrolling'] = setInterval(function() {


			if (Math.abs(data['sdiff']) > 10000) {
				console.log(data['sdiff']);
				if (Math.abs(data['sdiff']) > 50000) {
					data['sdiff'] = data['sdiff'] * .8;
				}
				else {
					data['sdiff'] = data['sdiff'] * .95;
				}
				timelineScroller({ sdiff: data['sdiff'] });
			}
			else { clearInterval(clothesLinePos['timelineSmoothScrolling']); }


		},5);
	}

}

$(document).on('click', '.clothesline', function() {
	var timestamp = Date.now();
	var app = $(this).attr('app');
	$.ajax({
		url: '/manager/clothesline',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});

$(document).on('change', '.clothes', function() {
	var timestamp = Date.now();
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var app = $(this).attr('app');

	var data = { timestamp: timestamp, setting: setting, value: value, app: app };
	if ($(this).is('select[multiple]')) {
		data['value'] = JSON.stringify(value);
		data['is_json'] = 'yes';
	}
	$.ajax({
		url: '/manager/clothesline',
		type: 'POST',
		data: data,
		success: function(response) {
		}
	});
});

$(document).on('click', '.clothes_picker', function() {
	var shirt = $(this);
	var app = shirt.attr('app');
	var td = shirt.attr('td');
	if (shirt.attr('re') == 'all') {
		if (shirt.attr('wearing') == 'on') {		
			$('.clothes_picker[app="' + app + '"][td="' + td + '"]').attr('wearing', 'off');
		}
		else {
			$('.clothes_picker[app="' + app + '"][td="' + td + '"]').attr('wearing', 'on');
		}
	}
	else {
		if (shirt.attr('wearing') == 'on') {
			shirt.attr('wearing', 'off');
		}
		else {
			shirt.attr('wearing', 'on');
		}
	}
	var time_plinko = {};
	$('.clothes_picker[wearing="on"]').each(function(i,v) {
		var td = $(v).attr('td');
		var re = $(v).attr('re');

		if (!time_plinko[td]) { time_plinko[td] = []; }
		time_plinko[td].push(re);
	});

	var setting = 'time_plinko';
	var value = JSON.stringify(time_plinko);
	$.ajax({
		url: '/manager/clothesline',
		type: 'POST',
		data: { setting: setting, value: value, app: app, timestamp: timestamp, is_json: 'yes' },
		success: function(response) {
		}
	});
});