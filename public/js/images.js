var slideshow;
var interval;
var gallery;
var image_number = 0;
var images = [];
var imageWindows = [];
var galleryThumbnails = {};
var gallerySearchTimeout;
var imageViewerRunning = 0;
var galleryTargetUuid = '';
$(document).on('click', '#main_image', function(e) {
	clearTimeout(gallery);
	$('#image_toggle').css({ 'background-color': 'lightgray' });
	windowSaver();
});

var doubleClicked = false;
$(document).on('click', '#image_toggle', function() {
	var t = $('#image_toggle');
	var gone = 0;
  if (doubleClicked) {
		dblClicker();
		gone = 1;
  }
  doubleClicked = true;
  setTimeout(() => {
		doubleClicked = false;
		if (gone == 0) {
			imageViewer({ 'view': 'load' });
			if (t.css('background-color') == "rgb(173, 216, 230)" ) {
				slideshowSetter();
			}
		}
  }, 100);
});

function imageViewer(data) {
	if (typeof data == 'undefined') { data = { count: image_number }; }
	console.log(data);
	var files = data['files'];
	var apps = data['apps'];
	var view = data['view'];
	var count = numeral(data['count']).value();
	var loadImages = data['loadImages'];
	var new_settings = data['new_settings'] || {};
	var file_uuid = data['file_uuid'];
	new_settings = JSON.stringify(new_settings);
	if (images.length == 0) {
		loadImages = 1;
	}
	var source = data['source'];
	if (!apps) {
		apps = JSON.stringify(openApps());
	}
	var shuffle = data['shuffle'] || localStorage.getItem('image_shuffle');
	var repeat = data['repeat'] || localStorage.getItem('image_repeat');
	if (files) {
		files = JSON.stringify(files);
	}

	var window_id;
//	if (!$('#main_image').is(':visible') || images.length == 0) {
		var combo_unlock = $('#gallery').attr('unlock');
		var search = $('#gallery_search').val();
		$.ajax({
			url: '/manager/gallery',
			type: 'GET',
			data: { 
				timestamp: timestamp, 
				files: files, 
				apps: apps, 
				shuffle: shuffle, 
				view: view, 
				unlock: combo_unlock,
				count: count, 
				loadImages: loadImages, 
				search: search, 
				source: source,
				file_uuid: file_uuid,
				'new_settings': new_settings
			},
			success: function(response) {
				window_id = windowMaker(response.window);

				if (response.view == 'photo') {
					if (loadImages != 0 && response.images && response.images.length > 0) {
						images = response.images;
					}
					if (galleryTargetUuid != '') {
						var chosen = -1;
						for (var n = 0; n < images.length; n++) {
							if (images[n] && images[n]['uuid'] == galleryTargetUuid) { chosen = n; break; }
						}
						if (chosen > -1) {
							image_number = chosen;
							galleryTargetUuid = '';
							galleryImageDisplayer();
						}
					}
					else if (loadImages == 0) {
						image_number = count;
						galleryImageDisplayer();
					}
					$('#gallery_home').hide();
					$('.image_shuffle').attr('enabled', shuffle);
					$('.image_repeat').attr('enabled', repeat);
					$('#main_image').height('').width('');
					$('#main_video').height('').width('');
					var ih = $('#main_image').height();
					var iw = $('#main_image').width();
					var ip = (ih / iw);
					var vh = $('#main_video').height();
					var vw = $('#main_video').width();
					var vp = (vh / vw);

					$('#main_image').css({ 'width': '100%' });
					var iw = $('#main_image').width();
					$('#main_image').height(iw * ip);
					$('#main_video').css({ 'width': '100%' });
				//	var vw = $('#main_video').width();
				//	$('#main_video').height(vw * vp);




				}
				else if (view == 'album') {
					var loadedImg = $('.gallery_home_preview[count="' + count + '"]');
					if (loadedImg.is(':visible')) {
						setTimeout(function() {
							$('#gallery_album').scrollTop(loadedImg.offset().top - loadedImg.height());
						},500);
					}

				}
				else if (view == 'home') {
					if (source == 'search') {
						$('#gallery_search').focus();
					}
				}
			}
		});
	/*}
	else {

		image_number++;
		if (image_number > images.length) {
			image_number = 0;
		}
		galleryImageDisplayer();
	}*/
}

// Whether the gallery also looks in the archive for photos whose local copy
// has gone. 'load' is the view that only carries settings, so the listing the
// window is on is not disturbed.
$(document).on('click', '.gallery_archive_toggle', function () {
	var b = $(this);
	var status = (b.attr('status') == 'on') ? 'off' : 'on';
	var new_settings = {};
	new_settings['archive'] = status;
	imageViewer({
		view: 'load',
		apps: $('#gallery').attr('apps'),
		loadImages: 1,
		new_settings: new_settings
	});
});

// Bring the photo on screen home when it is one the archive is holding.
// Nothing to do for a photo that is already here.
$(document).on('click', '.image_fetch_home', function () {
	var item = images[image_number] || {};
	if (!item['remote_uuid'] || !item['f']) { return; }
	$.ajax({
		url: '/manager/folders/archive/fetch',
		type: 'POST',
		data: { path: item['f'], remote_uuid: item['remote_uuid'] }
	});
});

function imageDiscover() {

	image_number = numeral(image_number).value();
	if (image_number > (images.length - 1)) {
		image_number = 0;
	}
	galleryImageDisplayer();
	var image = images[image_number]['file'];
	if (image.match('png$|jpg$|bmp$')) {
		var mi = $('#main_image');
		setTimeout(function() {
			if (mi.width() < 200) {
				mi.attr('src', image);
				mi.css({'width':'100%'});
				sessionStorage.setItem('preload_gallery', response);
			}
		},200);
	}
}

$(document).on('keyup', '#gallery_search', function(e) {
	if (e.keyCode == 13) {
		images = [];
		imageViewer({ 'view': 'home', 'source': 'search' });
	}
});

$(document).on('click', '.image_control', function() {
	clearInterval(gallery);
	var control = $(this);
	var direction = control.attr('direction');
	galleryImageControl(direction);
});

function galleryImageControl(direction) {
	if (direction == 'prev') {
		if (image_number == 0) {
			image_number = images.length - 1;
		}
		else {
			image_number--;
		}
	}
	else if (direction == 'next') {
		if (image_number == images.length - 1) {
			image_number = 0;
		}
		else {
			image_number++
		}
	}
	settingSetter({ 'app': 'gallery', 'setting': 'count', 'value': image_number });
	galleryImageDisplayer();
}

$(document).on('click', '.image_renew', function() {
	images = [];
	imageViewer();
	
});

function dblClicker() {
	clearInterval(gallery);
	var t = $('#image_toggle');
	if (t.css('background-color') == "rgb(173, 216, 230)" ) {
		t.css({ 'background-color': 'lightgray' });
	}
	else {
		t.css({ 'background-color': 'lightblue' });
		if (images.length > 1) {
			slideshowSetter();
		}
	}
}

$(document).on('click', '#main_image', function(e) {
	if (image_number == images.length) {
		image_number = 0;
	}
	else {
		image_number++
	}
	galleryImageDisplayer();

});

function galleryImageDisplayer() {
	console.log(images);
	image_number = numeral(image_number).value();
	console.log(image_number);
	if (!images[image_number]) {
		console.log('gallery image not loaded for index ' + image_number);
		return;
	}
	var image = images[image_number]['file'];
	if (!image) {
		console.log('gallery image has no file url', images[image_number]);
		return;
	}
	if (images[image_number]['type'] == 'video' || images[image_number]['file'].match('\.webm$|\.mp4$')) {
		$('#main_image').hide();
		$('#main_video').show();
		var mi = $('#main_video');
		mi.attr('src', image);

		mi.show();


		$('.gallery.file_information_grabber').attr('file', images[image_number]['f']);
		$('.gallery.file_information_grabber').attr('app_uuid', images[image_number]['app_uuid']);
		$('.gallery.file_information_grabber').attr('file_uuid', images[image_number]['uuid']);
		$('.gallery.file_information_grabber').attr('app', images[image_number]['app']);
		$('.gallery.main_image_selector').hide();
 		$('.gallery_home_album').attr('app', images[image_number]['app']);

	}
	else {
		var mi = $('#main_image');
		mi.attr('src', image);

		var vi = document.getElementById('main_image');

		mi.show();

		$('#main_video').hide();
		if ($('#main_video').attr('src')) {
			var mv = document.getElementById('main_video');
			mv.pause();
		}
		$('.gallery.main_image_selector').show();
 		$('.gallery_home_album').attr('app', images[image_number]['app']);
		$('.gallery.main_image_selector').attr('file', images[image_number]['f']);
		$('.gallery.main_image_selector').attr('app', images[image_number]['app']);
		$('.gallery.file_information_grabber').attr('file', images[image_number]['f']);
		$('.gallery.file_information_grabber').attr('app', images[image_number]['app']);
		$('.gallery.file_information_grabber').attr('app_uuid', images[image_number]['app_uuid']);
		$('.gallery.file_information_grabber').attr('file_uuid', images[image_number]['uuid']);
	}
}

$(document).on('mouseenter', '.video_preview_thumb[isa="img"]', function() {
	var img = $(this);
	var uuid = img.attr('file_uuid');
	var brother = img.attr('brother');
	if (img.attr('type') == 'video' && img.attr('isa') == 'img') {
		if (!galleryThumbnails[uuid]) { galleryThumbnails[uuid] = { 'viewing': 0 }; }
		var id = img.attr('id');
		var vid = $('video[file_uuid="' + uuid + '"][brother="' + brother + '"]');
		vid.width(img.width());

		var v = document.getElementById(vid.attr('id'));
		v.src = vid.attr('potential_src');
	//	v.onload=function(){
			img.hide();
			vid.show();
			v.play();
			v.loop = true;
			v.muted = true;
	//	}
		galleryThumbnails[uuid]['element'] = vid;
		clearInterval(galleryThumbnails[uuid]['interval']);
		galleryThumbnails[uuid]['interval'] = setInterval(function() {
			var duration = numeral(Math.abs(vid.attr('duration'))).value();
			if (img.attr('start_time')) {
				duration = (duration - numeral(Math.abs(img.attr('start_time'))).value());
			}
			if (img.attr('end_time')) {
				duration = numeral(Math.abs(img.attr('end_time'))).value() - numeral(Math.abs(img.attr('start_time'))).value();
			}
			var mouse = mouse_position();
			var elements = document.elementsFromPoint(mouse.x, mouse.y);
			var seen = 0;
			$.each(elements, function(i,v) {
				if ($(v).attr('id') == vid.attr('id')) {
					seen = 1;

				}
			});
			if (seen == 1) {
				if (duration > 20) {
					if ( galleryThumbnails[uuid]['viewing'] >= .9 ) {
						galleryThumbnails[uuid]['viewing'] = 0;
					} else {
						galleryThumbnails[uuid]['viewing'] = galleryThumbnails[uuid]['viewing'] + .1;
					}
					var currentTime;
					if (img.attr('end_time')) {
						currentTime = (numeral(img.attr('start_time')).value()  + (duration * galleryThumbnails[uuid]['viewing']) + 10);
					}
					else if (img.attr('start_time')) {
						currentTime = (numeral(img.attr('start_time')).value()  + (duration * galleryThumbnails[uuid]['viewing']) + 5);
					}
					else {
						currentTime = duration * galleryThumbnails[uuid]['viewing'];
					}
					v.currentTime = currentTime;
				}
			}
			else {
				clearInterval(galleryThumbnails[uuid]['interval']);
				galleryThumbnails[uuid]['element'].trigger('mouseleave');
			}
		},2000);
	}
});

$(document).on('mouseleave', '.video_preview_thumb[isa="video"]', function() {
	var uuid = $(this).attr('file_uuid');
	var brother = $(this).attr('brother');
	clearInterval(galleryThumbnails[uuid]['interval']);
	$(this).hide();
	var id = $(this).attr('id');
	$(this).attr('src', '');
	var clone = $(this).clone();
	$(clone).attr('id', id + 'e');
	$(this).after(clone);
	$('img[file_uuid="' + uuid + '"][brother="' + brother + '"]').show();
	var v = document.getElementById(id);
	v.pause();
	v.remove();
	v.src = undefined;
});

$(document).on('dblclick', '#main_image', function(){
	var id = $(this).attr('id');
	fullScreenGallery(id);
});

var fullScreen = {}
function fullScreenGallery(id) {
	var node = $('#' + id);
	var parent = node.parent();
	if (node.attr('fullscreen') == "yes") {
		node.attr('fullscreen', 'no');
		document.getElementById(id).style = fullScreen[id];
		$.each(fullScreen[id], function(i,v) {
		//	node.css(i,v)
		});
	}
	else {
		node.attr('fullscreen', 'yes');
		fullScreen[id] = document.getElementById(id).style;
		node.css({
			'position': 'fixed',
			'left': '0px',
			'top': '0px',
			'width': '100%',
			'height': '100%',
			'background-color': 'black',
			'z-index': 90000
		});
	}
}

var galleryPos = { active: true, time: Date.now(), totalX: 0, totalY: 0, lastX: 0, lastY: 0, startMove: undefined };

$(document).on('touchmove mousewheel', '#main_image, #main_video', function(m) {
	var w = $(this);
	var timestamp = Date.now();
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	if (m.originalEvent.targetTouches) {
		x = m.originalEvent.targetTouches[0].clientX;
		y = m.originalEvent.targetTouches[0].clientY;
	}
	x = numeral(x - w.offset().left).value();
	y = numeral(y - w.offset().top).value();

	if (galleryPos['totalX'] != 0 && (galleryPos['active'] == true || galleryPos['time'] < timestamp - 50)) {
		galleryPos['time'] = Date.now();
		galleryPos['active'] = false;
		if (galleryPos['totalX'] > 50) {
			galleryImageControl('next');
			galleryPos['totalX'] = 0;
		}
		else if (galleryPos['totalX'] < -50) {
			galleryImageControl('prev');
			galleryPos['totalX'] = 0;
		}
	}
	if (m.type == 'mousewheel') {
		if (Math.abs(m.originalEvent.deltaX) > Math.abs(m.originalEvent.deltaY)) {
			var mvmt = numeral(m.originalEvent.wheelDelta).value();
			var diff = -1 * (numeral(mvmt / 5).value());
			galleryPos['totalX'] = (diff + galleryPos['totalX']);
		}
		else {
		//	$('#main_image').css({ 'zoom': m.originalEvent.deltaX });
			$('#main_image').height(($('#main_image').height() + m.originalEvent.deltaY * -1)).width(($('#main_image').width() + m.originalEvent.deltaY * -1));
			$('#main_video').height(($('#main_video').height() + m.originalEvent.deltaY * -1)).width(($('#main_video').width() + m.originalEvent.deltaY * -1));
		}
	}
	else {
		var temp = (x - galleryPos['lastX']);
		galleryPos['totalX'] = (temp + galleryPos['totalX']);
		galleryPos['lastX'] = x;
		galleryPos['lastY'] = y;
	}
});

$(document).on('mouseout touchend mouseup', '#main_image, #main_video', function() {
	galleryPos['lastX'] = 0;
	galleryPos['lastY'] = 0;
	galleryPos['totalX'] = 0;
	galleryPos['active'] = true;
});

$(document).on('click', '.gallery_home_toggle', function() {
	$('#main_image').hide(); $('#main_video').hide();
	$('#gallery_search').val('');
	images = [];
	image_number = 0;
	imageViewer({ 'view': 'home' });
});

$(document).on('click', '.gallery_home_preview', function(e) {
	if (e.originalEvent.ctrlKey == false) {
		var app = $(this).attr('app');
		var file_uuid = $(this).attr('file_uuid');
		galleryReload['lastThumb'] = $(this).offset().top;
		var count = $(this).attr('count');
		var apps = JSON.stringify([ app ]);
		if (galleryReload['lastViewApp'] != app) {
			image_number = 0;
		}
		galleryReload['lastViewApp'] = app;
		galleryTargetUuid = file_uuid || '';
		imageViewer({ 'apps': apps, 'view': 'photo','count': count, 'loadImages': 1, file_uuid: file_uuid });
	}

});

$(document).on('click', '.gallery_lock', function() {
	var view = $('#gallery').attr('view');
	if (!$('#gallery').attr('unlock')) {

		imageViewer({ 'view':'padlock' });
	}
	else {
		settingSetter({ 'app': 'gallery', 'setting': 'combo_unlock', value: '' });
		imageViewer({ 'view': view });
	}
});

$(document).on('click', '#gallery_cancel_padlock', function() {
	imageViewer({ 'view': 'home' });
});

$(document).on('click', '.gallery_home_album', function() {
	var app = $(this).attr('app');
	var apps = JSON.stringify([ app ]);
	var count = 0;
	if (galleryReload['lastApp'] == app ) {
		count = image_number;
	}
	else {
		image_number = 0;
	}
	galleryReload['lastApp'] = app;
	imageViewer({ 'apps': apps, 'view': 'album', 'count': count });
});

$(document).on('click', '.gallery_scroll_direction', function() {
	var direction = $(this).attr('direction');
	if (direction == 'asc') {
		direction = 'desc';
	}
	else {
		direction = 'asc';
	}
	images = images.reverse();
	image_number = images.length - image_number;

	var view = $('#gallery').attr('view');
	var apps = $('#gallery').attr('apps');
	imageViewer({ 'apps':apps, 'view': view, new_settings: { 'scroll_direction': direction } });

});

var galleryReload = { reload: 0, position: 1, lastScroll: 0, lastThumb: 0, lastApp: '' };

$(document).on('mousewheel touchmove', '#gallery_album', function(m) {

	galleryScrollLoader();

});

function galleryScrollLoader() {
	var nc = $('#gallery_album');
	var scroll = nc.scrollTop();
	var height = nc.height();
	var cheight = $('#gallery').height();
	var lastImg =	$($('.gallery_home_preview')[$('.gallery_home_preview').length - 1]);
	var firstImg = $($('.gallery_home_preview')[0]);
	var lTop = lastImg.offset().top;


	var lHeight = lastImg.height();
	var calcHeight = (lTop - lHeight - height);

	var direction = 0;
	if (calcHeight < 0) {
		direction = 'bottom';
	}
	else if ((scroll < 10 && firstImg.attr('count') != 0 )) {
		direction = 'top';
	}

	if ( direction != 0 ) {
		if (galleryReload['reload'] == 0) {
			galleryReload['reload'] = 1;
			var apps = $('#gallery').attr('apps');
			var count = lastImg.attr('count');
			var first_count = firstImg.attr('count');
			var count_timestamp = lastImg.attr('timestamp');
			var combo_unlock = $('#gallery').attr('unlock');
			var search = $('#gallery_search').val();
			var data = { direction: direction, first_count: first_count, count: count, apps: apps, last_count_timestamp: count_timestamp, unlock: combo_unlock, search: search };
			$.ajax({
				url: '/manager/gallery/scroll',
				type: 'GET',
				data: data,
				success: function(response) {

					if (direction == 'bottom') {
						$('#gallery_album').append(response.html);
					}
					else {
						var top = firstImg.offset().top;
						var oldScroll = $('#gallery_album').scrollTop();
						$('#gallery_album').prepend(response.html);
						var new_top = firstImg.offset().top;
						$('#gallery_album').scrollTop(oldScroll + new_top - top);
					}
					galleryReload['reload'] = 0;
					galleryReload['position']++;
				}
			});
		}
	}
}



$(document).on('click', '.image_shuffle', function() {
	var is = localStorage.getItem('image_shuffle');
	if (is == 'on') {
		is = 'off';
	}
	else {
		is = 'on';
	}
	localStorage.setItem('image_shuffle', is);
	$('.image_shuffle').attr('enabled', is);
	images = [];
	image_number = 0;
	var apps = $('#gallery').attr('apps');
	imageViewer({ 'view': 'photo', loadImages: 1, apps: apps });
});

$(document).on('click', '.image_repeat', function() {
	var is = localStorage.getItem('image_repeat');
	if (is == 'on') {
		is = 'off';
	}
	else {
		is = 'on';
	}
	localStorage.setItem('image_repeat', is);
	$('.image_repeat').attr('enabled', is);
});

function slideshowSetter() {
	clearInterval(gallery);
	gallery = setInterval(function() {
		clearInterval(gallery);
		if ($('#gallery').attr('view') == 'photo') {
			$('#blackground').show();
			var image = images[image_number]['file'];
			galleryImageDisplayer();
			image_number++;
			if (image_number >= images.length) {
				var repeat = localStorage.getItem('image_repeat');
				if (repeat == 'on') {
					image_number = 0;
				}
			}
			var w = $('#main_image').closest('.wind').attr('id')
			if ($('#main_image').length == 0) {
				clearInterval(gallery);
			}
			windowSaver();
		}
	}, 2400);
}

$(document).on('click', '.gallery_home_preview', function(e) {
	if (e.originalEvent.ctrlKey == true) {
		var ig = $(this);
		fileInformationGrabber(ig);
	}
});
$(document).on('click', '.file_information_grabber', function(e) {

	var ig = $(this);
	fileInformationGrabber(ig);

});

function fileInformationGrabber(ig) {
	var file = ig.attr('file');
	var app = ig.attr('app');
	var mouse = JSON.stringify(mouse_position());
	var app_uuid = ig.attr('app_uuid');
	var file_uuid = ig.attr('file_uuid');
	var scope = localStorage.getItem('scope');
	$.ajax({
		url: '/manager/file/information',
		type: 'GET',
		data: { file: file, app: app, mouse: mouse, app_uuid: app_uuid, file_uuid: file_uuid, scope: scope, timestamp: timestamp },
		success: function(response) {
			ig.closest('.wind').append(response.html);
			var info = $('#file_information_' + response.uuid);
			if ((numeral(info.css('left')).value() + info.width()) > $(window).width()) {
				var new_left = ($(window).width() - info.width() - 5);

				info.css({'left': new_left + 'px'});
			}
			else if (numeral(info.css('left')).value() < 0) {
				info.css({'left': '5px'});
			}
			if ((numeral(info.css('top')).value() + info.height()) > $(window).height()) {
				var new_top = ($(window).height() - info.height() - 5);
				info.css({'top': new_top + 'px' });
			}
			appointment_chron();

		}
	});
}


$(document).on('change', '.image_function_selection', function() {
	var a = $(this);
	var func = a.val();
	var file_uuid = a.attr('uuid');
	var app = a.closest('.detail_area').attr('app');
	var app_uuid = a.closest('.appointment_detail').attr('uuid');
	$.ajax({
		url: '/manager/configure/image_function',
		type: 'POST',
		data: { file_uuid: file_uuid, app: app, app_uuid: app_uuid, func: func },
		success: function(response) {
			appointmentDetailGrabber(app,app_uuid)
		}
	});
});

function imageCanvasConverter(data) {

}

$(document).on('click', '.image_function_tool', function() {
	var t = $(this);
	var tool = t.attr('tool');
	var app_uuid = t.attr('app_uuid');
	var file_uuid = t.attr('file_uuid');
	var dimage = $('.detail_image[app_uuid="' + app_uuid + '"][file_uuid="' + file_uuid + '"]');
	$('.image_function_tool[app_uuid="' + app_uuid + '"][file_uuid="' + file_uuid + '"]').removeClass('selected');
	t.addClass('selected');
	var id = dimage.attr('id');
	var style = $('#'+ id).attr('style');
	var canvas = document.getElementById(id + '_canvas');
	if (!$(canvas).attr('tool')) {
		canvas.width = dimage.width();
		canvas.height = dimage.height();
		var cid = canvas.id;
		var iv = document.getElementById(id);

		var image = new Image();
		image.onload=function(){
			canvas.getContext('2d').drawImage(image,0,0,canvas.width, canvas.height);
		};
		image.src = iv.src;
		dimage.hide();
		$(canvas).attr('style', style).attr('tool', tool).addClass('image_function').show();
		image_function_tool = { 'scale': {}, 'home_plate': {} };
	}
	else {
		$(canvas).attr('tool', tool);
		image_function_tool[tool] = {};
		var iv = document.getElementById(id);

		var image = new Image();
		image.onload=function(){
			canvas.getContext('2d').drawImage(image,0,0,canvas.width, canvas.height);
		};
		image.src = iv.src;
	}
});

var image_function_tool = { 'scale': {}, 'home_plate': {} };

$(document).on('mousemove touchmove click', 'canvas.image_function', function(m) {
	var w = $(this);
	var can = $(m.target);
	var file_uuid = can.attr('file_uuid');
	var app_uuid = can.attr('app_uuid');
	var app = can.attr('app');
	var canvas = document.getElementById(can.attr('id'));
	var ctx = canvas.getContext('2d');
	var tool = can.attr('tool');
	var t = $('.image_function_tool[app_uuid="' + app_uuid + '"][file_uuid="' + file_uuid + '"]');
	var id = app_uuid + '_' + file_uuid;
	var cid = can.attr('id');
	var info = $('#' + id + '_info');
	var legend = $('#' + id + '_legend');
	var name = $('#' + id + '_name').val();
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	if (m.originalEvent.targetTouches) {
		x = m.originalEvent.targetTouches[0].clientX;
		y = m.originalEvent.targetTouches[0].clientY;
	}
	x = numeral(x - w.offset().left).value();
	y = numeral(y - w.offset().top).value();

	ctx.beginPath();
	ctx.globalAlpha = 1;
	ctx.fillStyle = 'red';

	if (tool == 'scale') {
		if (!image_function_tool[tool]['first']) {
			if (m.which === 1 || m.originalEvent.type == 'touchmove') {
				image_function_tool[tool]['first'] = { 'x': x, 'y': y };
				ctx.moveTo(x,y);
				ctx.arc(x,y, 5, 0, (Math.PI*2), true);
			}
			info.html(numeral(x).format('0.00') + ' ' + numeral(y).format('0.00'));
		}
		else if (!image_function_tool[tool]['last']) {
			var x_span = numeral(x - image_function_tool[tool]['first']['x']).format('0.000');
			var y_span = numeral(y - image_function_tool[tool]['first']['y']).format('0.000');
			info.html('X: ' + x_span + ' Y: ' + y_span);
			if (m.which === 1 || m.originalEvent.type == 'touchmove') {
				ctx.moveTo(image_function_tool[tool]['first']['x'], image_function_tool[tool]['first']['y']);
				ctx.lineTo(x,y);
				ctx.arc(x,y, 5, 0, (Math.PI*2), true);
				image_function_tool[tool]['last'] = { 'x': x, 'y': y };
				var translate = legend.val();
				var value = { name: name, legend: translate, height: canvas.height, width: canvas.width, first: image_function_tool[tool]['first'], last: image_function_tool[tool]['last'] };
				value = JSON.stringify(value);

				$.ajax({
					url: '/manager/configure/image_function_tool',
					type: 'POST',
					data: { file_uuid: file_uuid, app_uuid: app_uuid, tool: tool, value: value, app: app },
					success:function(response) {
						t.removeClass('selected');
						image_function_tool[tool] = {};
						ctx.fillStyle = 'black';
						ctx.font = "400 24px Arial";
						ctx.fillText(response.legend, (x - (x_span / 2) - (ctx.measureText(response.legend).width / 2)), (y - ( y_span / 2 ) - 10));
					}
				});
			}
		}
		else {
			if (m.which === 1 || m.originalEvent.type == 'touchmove') {
				image_function_tool[tool] = {};
				var iv = document.getElementById(id);

				var image = new Image();
				image.onload=function(){
					canvas.getContext('2d').drawImage(image,0,0,canvas.width, canvas.height);
				};
				image.src = iv.src;
			}
		}
	}
	else if (tool == 'home_plate') {
		if (!image_function_tool[tool]['home_plate']) {
			var translate = legend.val();
			info.html(numeral(x).format('0.00') + ' ' + numeral(y).format('0.00'));
			if (translate) {
				if (m.which === 1 || m.originalEvent.type == 'touchmove') {
					image_function_tool[tool]['home_plate'] = { 'x': x, 'y': y };

					var value = { legend: translate, height: canvas.height, width: canvas.width, x: x, y: y };
					value = JSON.stringify(value);
					$.ajax({
						url: '/manager/configure/image_function_tool',
						type: 'POST',
						data: { name: name, file_uuid: file_uuid, app_uuid: app_uuid, tool: tool, value: value, app: app },
						success:function(response) {
							t.removeClass('selected');
							var img = new Image;
							img.onload = function(){
								ctx.drawImage(img,x - 15,y - 15, 30, 30);
								ctx.fillStyle = 'black';
								ctx.font = "400 24px Arial";
								ctx.fillText(response.formatted_legend, x + 15, y);
							};
							img.src = '/icons/lymeboard/bullseye.png';
						}
					});
				}
			}
		}
		else {
			if (m.which === 1 || m.originalEvent.type == 'touchmove') {
				image_function_tool[tool] = {};
				var iv = document.getElementById(id);

				var image = new Image();
				image.onload=function(){
					canvas.getContext('2d').drawImage(image,0,0,canvas.width, canvas.height);
				};
				image.src = iv.src;
			}
		}
	}
	ctx.fill();
	ctx.stroke();
});

$(document).on('change', '.image_name_input', function() {
	var name = $(this).val();
	var file_uuid = $(this).attr('file_uuid');
	var app_uuid = $(this).attr('app_uuid');
	var app = $(this).attr('app');
	$.ajax({
		url: '/manager/configure/image_name',
		type: 'POST',
		data: { name: name, app_uuid: app_uuid, file_uuid: file_uuid, app: app },
		success: function(response) {
		}
	});
});



$(document).on('click', '.palette_toggle', function() {
	var file = $(this).attr('file');
	var palette = $(this).closest('.appointment').find('.palette[file="' + file + '"]');
	if (palette.is(':visible')) {
		palette.hide();
	}
	else {
		palette.show();
	}
});

$(document).on('click', '.detail_image', function() {
	var uuid = $(this).attr('file_uuid');
	var tools = $('.app_file_toolbox[uuid="' + uuid + '"]');
	if (tools.is(':visible')) {
		tools.hide();
	}
	else {
		tools.show();
	}
});


var palette_duties = {};
$(document).on('click', '.palette_duty', function() {
	var app = $(this).closest('.appointment').attr('app');
	var uuid = $(this).closest('.appointment_detail').attr('uuid');
	var file_uuid = $(this).closest('.palette').attr('uuid');
	var id = uuid + '_' + file_uuid;
	var style = $('#'+ id).attr('style');
	var dimage = $('.detail_image[app_uuid="' + uuid + '"][file_uuid="' + file_uuid + '"]');
	var duty = $(this).attr('duty');
	var file = $(this).attr('file');
	var value = $('.palette_input[file="' + file + '"]').val();
	var image = $('.detail_image[file="' + file + '"]');
	var type= $('.detail_image[file="' + file + '"]').attr('type');

	var timestamp = image.attr('timestamp');
	var duty_watch = { duty: duty, value: value };
	if (palette_duties[file] == undefined) {
		palette_duties[file] = [];
	}
	palette_duties[file].push(duty_watch);
	var duties = JSON.stringify(palette_duties[file]);
	if (duty == 'clear') {
		image.attr('src', '/file_open?file=' + file + '&timestamp=' + timestamp);
		palette_duties[file] = [];
		$('.palette_duty[duty="clear"][file="' + file + '"]').hide();
		$('.palette_duty[duty="save"][file="' + file + '"]').hide();
	}
	else if (duty == 'crop') {
		if (cropTool[0]) { cropTool = []; }
		else {
			var canvas = document.getElementById(id + '_canvas');
			canvas.width = dimage.width();
			canvas.height = dimage.height();
			var cid = canvas.id;
			var iv = document.getElementById(id);

			var image = new Image();
			image.onload=function(){
				canvas.getContext('2d').drawImage(image,0,0,canvas.width, canvas.height);
			};
			image.src = iv.src;
			dimage.hide();
			$(canvas).attr('style', style).attr('tool', 'crop').show();
		}
	}
	else {
		$.ajax({ 
			url: '/manager/palette',
			type: 'post',
			data: { uuid: uuid, type: type, duties: duties, duty: duty, value: value, file: file, app: app, timestamp },
			success: function(response) {
				image.attr('src', response['image']);
				if (duty != 'save' && duty != 'clear') {
					$('.palette_duty[duty="clear"][file="' + file + '"]').show();
					$('.palette_duty[duty="save"][file="' + file + '"]').show();
				}
				else {
					palette_duties[file] = [];
				}
			}
		});
	}
});


var cropTool = [];

$(document).on('dblclick', 'canvas[tool="crop"]', function() {
	cropTool = [];
});

$(document).on('mouseout touchend mouseup', 'canvas[tool="crop"]', function() {
	cropTool = [];
});

$(document).on('mousemove touchmove click', 'canvas[tool="crop"]', function(m) {
	var ct = $(this);
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	if (m.originalEvent.targetTouches) {
		x = m.originalEvent.targetTouches[0].clientX;
		y = m.originalEvent.targetTouches[0].clientY;
	}
	x = numeral(x - ct.offset().left).value();
	y = numeral(y - ct.offset().top).value();
	if (m.which === 1 || m.originalEvent.type == 'touchmove') {
		var id = $(this).attr('id');
		var canvas = document.getElementById(id);
		var uuid = ct.attr('app_uuid');
		var file_uuid = ct.attr('file_uuid');
		var dimage = $('.detail_image[app_uuid="' + uuid + '"][file_uuid="' + file_uuid + '"]');
		var file = dimage.attr('file');
		var did = dimage.attr('id');
	//	canvas.width = dimage.width();
	//	canvas.height = dimage.height();

		var ctx = canvas.getContext('2d')
		var iv = document.getElementById(did);


		ctx.beginPath();
		if (!cropTool[0]) {

			ctx.arc(x,y, 7, 0, (Math.PI*2), true);

			cropTool[0] = [x, y];
		}
		else {
			cropTool[1] = [ x, y ];
		//	ctx.strokeRect(cropTool[0][0],cropTool[0][1],cropTool[1][0],cropTool[1][1]);
			$('.palette_duty[duty="clear"][file="' + file + '"]').show();
			$('.palette_duty[duty="save"][file="' + file + '"]').show();

			var owidth = dimage.width();
			var oheight = dimage.height();
			dimage.height('');dimage.width('');
			var dwidth = dimage.width();
			var dheight = dimage.height();

			dimage.width(owidth);dimage.height(oheight);


			var geo = numeral((cropTool[1][0] - cropTool[0][0]) / (canvas.width / dwidth)).format('0') + 'x' + numeral((cropTool[1][1] - cropTool[0][1]) / (canvas.height / dheight)).format('0') + '+' 
				+ numeral(cropTool[0][0] / (canvas.width / dwidth)).format('0') + '+' + numeral(cropTool[0][1] / (canvas.height / dheight)).format('0');

			var duty_watch = { duty: 'crop', value: geo };
			if (palette_duties[file] == undefined) {
				palette_duties[file] = [];
			}
			palette_duties[file] = $.grep(palette_duties[file], function(t,i) { return t['duty'] != 'crop' });
			palette_duties[file].push(duty_watch);
		}
		var image = new Image();
		image.onload=function(){
			ctx.drawImage(image,0,0,canvas.width, canvas.height);
			ctx.strokeRect(cropTool[0][0],cropTool[0][1],cropTool[1][0],cropTool[1][1]);
			ctx.stroke();
			ctx.fill();

		};
		ctx.stroke();
		ctx.fill();
		image.src = iv.src;
	}
});

$(document).on('keydown', function(e) {
	if (topWindow() == 'gallery') {
		if (!$(e.target).is('input') && !$(e.target).is('textarea') && e.ctrlKey == false) {
			e.preventDefault();

			if (e.keyCode == 37) {
				galleryImageControl('prev');
			}
			if (e.keyCode == 39) {
				galleryImageControl('next')
			}
			if (e.keyCode == 27) {
				if ($('#main_image').is(':visible') || $('#main_video').is(':visible')) {
					$('.gallery_home_album').trigger('click');
				}
				else if ($('#gallery_album').is(':visible')) {
					$('.gallery_home_toggle').trigger('click');
				}
			}
		}
	}
});