var marker = {
	selected_marker_colour: 'black',
	selected_marker_size: 20,
	selected_marker_transparency: 1,
	selected_marker_colour_uuid: undefined
};
$(document).on('click change', '.marker_colour', function() {
	var uuid = $(this).attr('uuid');
	marker.selected_marker_colour = $(this).val();
	marker.selected_marker_colour_uuid = uuid;
	console.log('new colour ' + marker.selected_marker_colour);
	$('.marker_colour').each(function(i,v) { $(v).attr('status', 'inactive') });
	$('.marker_colour[uuid="' + uuid + '"]').attr('status', 'active');
	markerColourSaver()
});
var whiteboard_ctx;
function markerInit(whiteboard) {

	if (whiteboard == undefined) {
		whiteboard = 'whiteboard';
	}
	var marker_tool = localStorage.getItem('marker_tool') || 'marker';
	var mt = $('.marker_tool[tool="' + marker_tool + '"]')
	mt.addClass('selected');
	var canvas = document.getElementById('whiteboard');
	var win = $('#whiteboard').closest('.wind');
	canvas.height = win.height() - win.find('.top_navbar').height();
	canvas.width = win.width() - win.find('#marker_toolbox').width();
	whiteboard_ctx = canvas.getContext('2d');
	clearInterval(markerVideoInterval);
//	portfolioMaker();
	var mouseInterval;
	$(document).on('click mousemove touchmove', '#whiteboard', function(m) {
		var w = $(this);
		m.preventDefault();			m.preventDefault();
		mouse = m;

		var marker_tool = localStorage.getItem('marker_tool');
		var marker_transparency = $('#marker_transparency').val() || 1;
		marker.selected_marker_transparency = marker_transparency;
		marker.selected_marker_size = $('#marker_size').val();
	//	selected_marker_colour = $('#marker_colour').val();

		var x = m.originalEvent.clientX;
		var y = m.originalEvent.clientY;
		if (m.originalEvent.targetTouches) {
			x = m.originalEvent.targetTouches[0].clientX;
			y = m.originalEvent.targetTouches[0].clientY;
		}
		x = numeral(x - w.offset().left).value();
		y = numeral(y - w.offset().top).value();

		var timestamp = Date.now();
		whiteboard_ctx.beginPath();
		whiteboard_ctx.globalAlpha = marker_transparency;
		var leftButtonDown = false;

		if (m.which === 1 || m.originalEvent.type == 'touchmove') {
		//	marker.push({ 'x': x, 'y': y, 'tool': marker_tool, 'colour': marker_colour, 'transparency': marker_transparency, 'size': marker_size, timestamp: timestamp });
			if (marker_tool == 'marker') {
				whiteboard_ctx.fillStyle = marker.selected_marker_colour;
				whiteboard_ctx.moveTo(x,y);
				whiteboard_ctx.arc(x,y, marker.selected_marker_size, 0, (Math.PI*2), true);
				whiteboard_ctx.fill();
			}
			else if (marker_tool == 'kb') {
				whiteboard_ctx.moveTo(x,y);
				localStorage.setItem('whiteboard_position', '{ "x": "' + x + '", "y": "' + y + '"}');
				var wb = $('#whiteboard').offset();
				$('#pointer').css({ 'top': y + wb['top'] - 12, 'left': x + wb['left'] });
			}
			else if (marker_tool == 'eraser') {
				whiteboard_ctx.moveTo(x,y);
				whiteboard_ctx.clearRect(x,y, marker.selected_marker_size, marker.selected_marker_size);
			}
			else if (marker_tool == 'sample') {


				const imgData = whiteboard_ctx.getImageData(x, y, 1, 1);

				// 4. Access the RGBA channels from the flat data array
				const r = imgData.data[0].toString(16).padStart(2, '0');
				const g = imgData.data[1].toString(16).padStart(2, '0');
				const b = imgData.data[2].toString(16).padStart(2, '0');
				var colour = '#' + r + g + b;
				$('.marker_colour[uuid="' + marker.selected_marker_colour_uuid + '"]').val(colour);
				marker.selected_marker_colour = colour;

			}
		}
	});
}

$(document).on('click', '.marker_stylus_toggle', function() {
	var toggle = $(this).attr('toggle');
	if (toggle == 'on') {
		toggle = 'off';
	} else {
		toggle = 'on';
	}
	$(this).attr('toggle', toggle);
	settingSetter({ 'app': 'marker', 'setting': 'stylus_toggle', 'value': toggle });
});

$(document).on('click', '#marker_colour_add', function() {
	var uuid = crypto.randomUUID();
	var new_colour = marker.selected_marker_colour;
	$('#marker_kit').append('<input uuid="' + uuid + '" type="color" style="width:45%;" class="marker_colour" value="' + new_colour + '" />' +
		'<button class="marker_colour_remove" uuid="' + uuid + '">-</button>');
	marker.selected_marker_colour_uuid = uuid;
	marker.selected_marker_colour = $('.marker_colour[uuid="' + uuid + '"]').val();
	$('.marker_colour').each(function(i,v) { $(v).attr('status', 'inactive') });
	$('.marker_colour[uuid="' + uuid + '"]').attr('status', 'active');
	markerColourSaver()
});

$(document).on('click', '.marker_colour_remove', function() {
	var uuid = $(this).attr('uuid');
	if ($('.marker_colour').length > 0) {
		$(this).next().remove();
		$('.marker_colour[uuid="' + uuid + '"]').remove();
		$('.marker_colour_remove[uuid="' + uuid + '"]').remove();
		$('.marker_colour').each(function(i,v) { $(v).attr('status', 'inactive') });
		var last = $('.marker_colour').last();
		last.attr('status', 'active');
		marker.selected_marker_colour = last.val();
		marker.selected_marker_colour_uuid = last.attr('uuid');
	}
	markerColourSaver();
});

function markerColourSaver() {
	var colours = [];
	$('.marker_colour').each(function(i,v) {
		var uuid = $(v).attr('uuid');
		var colour = $(v).val();
		colours.push({ uuid: uuid, colour: colour });
	});
	var jColours = JSON.stringify(colours);
	settingSetter({ 'app': 'marker', 'setting': 'colours', 'value': jColours });
	return colours;
}

$(document).on('click', '.marker_tool', function() {
	var t = $(this);
	var tool = t.attr('tool');
	var marker_tool = localStorage.getItem('marker_tool');
	$('.marker_tool').removeClass('selected');

	t.addClass('selected');
	localStorage.setItem('marker_tool',tool);
});

var record_marker;
$(document).on('click', '.record_marker', function() {
	jpCanvas();
	
});


var play_marker;
$(document).on('click', '.play_marker', function() {
	var p = $(this);
	var c = p.closest('.marker_toolbox').find('.flipbook_interval').val();
	clearInterval(play_marker);
	var movement = p.attr('movement');
	if (play_marker) {
		clearInterval(play_marker);
		play_marker = undefined;
	}
	else {
		play_marker = setInterval(function() {
			$('.flipbook[movement="' + movement + '"]').trigger('click');
		},c);
	}
});

function markerInfoGrabber() {
	var marker = {
		tool: localStorage.getItem('marker_tool'),
		transparency: $('#marker_transparency').val() || 1,
		colour: $('#marker_colour').val() || 'navy',
		size: $('#marker_size').val(),
		flipbook_interval: $('#flipbook_interval').val()
	};
	return marker;
}

$(document).on('click', '.save_marker', function() {
	var timestamp = Date.now();
	var canvas = document.getElementById('whiteboard');
	var img = canvas.toDataURL('image/png');
	var paper = 'paper_' + timestamp;
	var p = $('#' + paper);
	var marker = markerInfoGrabber();
	app = topWindow('marker');
	$.ajax({
		url: '/manager/marker/save',
		type: 'POST',
		data: {
			timestamp: timestamp,
			paper: paper,
			img: img,
			marker: JSON.stringify(marker),
			browser_tab_id: bti,
			app: app
		},
		success: function(portfolio) {
			portfolioMaker(JSON.parse(portfolio || []));
		}
	});

	say_it('saved!');
});

$(document).on('click', '.paper', function() {
	var canvas = document.getElementById("whiteboard");
	var ctx = canvas.getContext('2d');
	ctx.globalAlpha = $('#marker_transparency').val();
	var image = new Image();
	image.onload=function(){
		ctx.drawImage(image,0,0,canvas.width,canvas.height);
	};
	image.src = $(this).attr('src');
});

function portfolioMaker(portfolio) {
	page_number = (Number(page_number) + 1);
	$('#portfolio').html('');
	$.each(portfolio,function(i,v) {
		var p = JSON.parse(v.file);
		$.each(p, function(ir,vr) {
			console.log(vr);
			if (vr['type'] == 'image') {
				var phtml = '<button class="marker_delete" uuid="' + v['uuid'] + '" server_time="' + v['server_time'] + '" timestamp="' + v['timestamp'] + '" paper="' + v['paper'] + '" id="' + v['paper'] + '_delete">D</button> \
					<img class="paper" timestamp="' + v['timestamp'] + '" id="' + v['uuid'] + '" src="/file_open?app=' + v['app'] + '&file=' + vr['f'] + '&timestamp=' + vr['server_time'] + '" style="width:40px;height:60px"></img>';
				$('#portfolio').append(phtml);
			}
		});
	});

	if (portfolio) {
		portfolio = portfolio.sort(function(a, b) {
		  return b['timestamp'] - a['timestamp'];
		});
	}
}

var selected_image = 0;
$(document).on('click', '.flipbook', function() {
	var movement = $(this).attr('movement');
	var canvas = document.getElementById('whiteboard');
	var image = new Image();
	var ctx = canvas.getContext('2d');
	var p = $('.paper');
	var total = p.length;
	if (movement == 'back') {
		if (selected_image <= 0) {
			selected_image = total;
		}
		else {
			selected_image = Number(selected_image) - 1;
		}

	}
	else if (movement == 'forward') {
		if (selected_image >= total) {
			selected_image = 0;
		}
		else {
			selected_image = Number(selected_image) + 1;
		}

	}
	ctx.globalAlpha = $('#marker_transparency').val();
	image.onload=function(){
		ctx.drawImage(image,0,0,canvas.width,canvas.height);
	};
	if (p[selected_image]) {
		image.src = p[selected_image].src;
	}
});

$(document).on('click', '.marker_delete', function() {
	var a = $(this);
	var timestamp = $(this).attr('timestamp');
	var file_uuid = $(this).attr('file_uuid');
	var app_uuid = $(this).attr('app_uuid');
	var app = $(this).attr('app');
	var server_time = a.attr('server_time');
	var armed = a.attr('armed');
	if (armed == 'yes') {
		$.ajax({
			url: '/manager/marker/delete',
			type: 'POST',
			data: { app_uuid: app_uuid, file_uuid: file_uuid, app: app },
			success: function(response) {
				$('.paper[file_uuid="' + file_uuid + '"][app_uuid="' + app_uuid + '"]').remove();
				$('.marker_delete[file_uuid="' + file_uuid + '"][app_uuid="' + app_uuid + '"]').remove();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click','#marker_pause', function() {
	var b = $(this);
	var app = b.attr('app');
	if (we['rec'][app].state == 'recording') {
		we['rec'][app].pause();
		b.attr('src', '/images/make believe/delay_button.png');
	}
	else {
		we['rec'][app].resume();
		b.attr('src', '/images/make believe/pause.png');
	}
});

var markerVideoInterval = null;
function markerDragger(id,status) {
	var wind = $('#' + id);

	if (wind.find('#whiteboard').length >= 1) {
		var canvas = document.getElementById('whiteboard');
		var wb = $('#whiteboard');
		var white = wb.offset();
		white['width'] = wb.width();
		white['height'] = wb.height();
		white['centre'] = [ white['width'] / 2 + white['left'], white['height'] / 2 + white['top'] ];
		if (status == 'drag') {
			$('#marker_targeting').css({ 'left': white['centre'][0], 'top': white['centre'][1], 'position': 'fixed' }).show();
		}
		else if (status == 'stop') {
			var elements = document.elementsFromPoint(white['centre'][0], white['centre'][1]);
			$.each(elements, function(i,v) {
				if (($(v).is('video') && $(v).is(':visible'))  ) {
					var fps = $('#flipbook_interval').val();
					clearInterval(markerVideoInterval);
					v.onpause = function() {
						clearInterval(markerVideoInterval);
					};
					v.onended = function() {
						clearInterval(markerVideoInterval);
					}
					markerVideoInterval = setInterval(function() {
						whiteboard_ctx.drawImage(v, 0, 0, white['width'], white['height']);
					}, 1000 / fps);
				}
				else if (($(v).is('img') && $(v).is(':visible')) && ($(v).attr('id') == 'video' || $(v).hasClass('detail_image') || $(v).attr('id') == 'main_image') ) {
					var image = new Image();
					image.onload=function(){
						whiteboard_ctx.drawImage(image,0,0,white['width'], white['height']);
					};
					image.src = $(v).attr('src');
				}
				else if (($(v).is('canvas')) && !$(v).hasClass('background')) {
					var cid = $(v).attr('id');
					var cv = document.getElementById(cid);
					var img = cv.toDataURL('image/png');
					var image = new Image();
					image.onload=function(){
						whiteboard_ctx.drawImage(image,0,0,white['width'], white['height']);
					};
					image.src = img;
				}
				else {
					return true;
				}
			});
			$('#marker_targeting').hide();
		}
	}
}

$(document).on('click', '#marker_gallery', function() {
	var app = topWindow('marker');
	$.ajax({
		url: '/manager/marker/gallery',
		type: 'GET',
		data: { timestamp: timestamp, app: app },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});
