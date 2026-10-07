
$(document).on('click', '#editor_toggle', function() {
	editorMaker();
});

var grapple_key_index;
var original_grapple_position;
function editorMaker(source) {
	var url = '/manager/editor';
	var scope = localStorage.getItem('scope');
	var timestamp = timestamp;
	var uuid = localStorage.getItem('article_uuid');
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, scope: scope, article_uuid: uuid },
		success: function(response) {
			windowMaker(response);
			editorInit(source);
		},
		error: function (response) {}
	});
}

function editorInit(source) {
	$('#editor_content_parent').html($('#editor_content_parent').text());
	if (original_key_position == undefined) {
		original_grapple_position = {
			top: $('#grapple').css('top'),
			left: $('#grapple').css('left')
		};
	}
	$('#grapple').show();

	$('#grapple').draggable({
		start: function(p) {
			var capable_of = $('#grapple').attr('capable_of');
			grapple_key_index = $('#grapple').css('z-index');

			if (capable_of == 'h1' || capable_of == 'h2' || capable_of == 'h3' || capable_of == 'h4') {
				grappleDropper('.name_text');
			}
			else if (capable_of == 'p') {
				grappleDropper('.notespace');
			}
			else if (capable_of == 'img') {
				grappleDropper('img');
			}
			else if (capable_of == 'canvas') {
				grappleDropper('canvas');
			}
			else if (capable_of == 'video') {
				grappleDropper('video');
			}
			else if (capable_of == 'audio') {
				grappleDropper('audio');
			}
			else if (capable_of == 'a') {
				grappleDropper('a');
			}
			else if (capable_of == 'iframe') {
				grappleDropper('iframe')
			}
		},
		drag: function(p) {


		},
		stop: function(p) {
			$('.grapple_capable').each(function(i,v) {
				$(v).removeClass('grapple_capable');
				if ($(v).hasClass('ui-droppable')) {
				//	$(v).droppable('disable');
				}
			});
		}
	});
	if (source == 'new') {
		$('#editor_content_parent').html('<div id="editor_content_area"></div>');
	}
}

function grappleDropper(type) {
	$(type).addClass('grapple_capable');
	$(type).droppable({
		drop: function(ui,event) {
			var node = $(this);
			var node_id = node.attr('id');
			if (node_id == '' || node_id == undefined) {
				node_id = 'temporary_node_id';
				node.attr('id', node_id);
			}
			if (type == 'canvas') {
				var canvas = document.getElementById(node_id);
				if (!$(canvas).hasClass('background')) {
					var img = canvas.toDataURL('image/png');
					$('.grapple_active').attr('id', 'temporary_grapple_node_id');
					var grapple_canvas = document.getElementById('temporary_grapple_node_id');
					var ctx = grapple_canvas.getContext('2d');
					var image = new Image();
					var ratio = canvas.height / canvas.width;
					grapple_canvas.width = 1366 || 0;
					grapple_canvas.height = ratio * canvas.width || 0;
					image.onload=function(){
						ctx.drawImage(image,0,0,grapple_canvas.width,grapple_canvas.height);
					};
					image.src = img;

					$('.grapple_active').attr('src', src);
					$('.grapple_active').css({'max-height': '100%', 'max-width':'100%' });
					$('.grapple_active').removeClass('medium_thumb');

					$('#temporary_grapple_node_id').attr('id', 'editor_canvas' + Date.now() / 23);
				}
			}
			else if (type == 'img') {
				var canvas = document.createElement('canvas');
				var image = document.getElementById(node_id);

				var ratio = image.height / image.width;
				canvas.width = image.width || 0;
				canvas.height = ratio * canvas.width || 0;
				canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
				var src = canvas.toDataURL('image/png');
				$('.grapple_active').attr('src', src);
				$('.grapple_active').css({'max-height': '100%', 'max-width':'100%' });
				$('.grapple_active').removeClass('medium_thumb');
			}
			else if (type == "video" || type == "audio") {
				var n = document.getElementById(node_id);
				var content = n.src.split('/');
				var src = n.src;
				var seen_it = 0;
				for (var i = 0; i < content.length; i++) {
					var q = content[i].split('\?');
					if (q.length > 1 && seen_it == 0) {
						seen_it = i;
					}
				};
				if (seen_it == 1) {
					var d = content.splice(seen_it);
					var src = d.join('/');
					src = '/' + src;
				}

				
				$('.grapple_active').attr('src', src);
				$('.grapple_active').attr('controls', true);
			}
			else {
				$('.grapple_active').html(node.html());
			}
			if (node_id == 'temporary_node_id') {
				node.attr('id', undefined);
			}
		}
	});
}

$(document).on('click', '.editor_content_adder', function() {
	var timestamp = Date.now();
	var b = $(this);
	var type = b.attr('content_type');
	var content = '<' + type + ' type="' + type + '" class="editor_content_component grapple_inactive">This is a ' + type + '</' + type + '>';

	if (type == 'a') {
		content = '<' + type + ' type="' + type + '" class="editor_content_component grapple_inactive" href="">' + type + ' type</' + type + '>';
	}
	else if (type == 'img') {
		content = '<' + type + ' type="' + type + '" style="background-color:var(--panel);" class="medium_thumb editor_content_component grapple_inactive" src="/images/make believe/camera.png"></' + type + '>';
	}

	if ($('.grapple_active').length > 0) {
		$('.grapple_active').after(content);
	}
	else {
		$('#editor_content_area').append(content);
	}
});

$(document).on('click', '.editor_content_component', function(e) {
	e.preventDefault();
	var component = $(this);
	var is_active = 0;
	if (component.hasClass('grapple_active')) {
		is_active = 1;		
	}
	$('.editor_content_component').each(function(i,v) {
		$(v).removeClass('grapple_active');
		$(v).addClass('grapple_inactive');
	});
	if (is_active == 1) {
		component.addClass('grapple_inactive');
		component.removeClass('grapple_active');
	}
	else {
		component.addClass('grapple_active');
		component.removeClass('grapple_inactive');
		$('#grapple').attr('capable_of', component.attr('type'));
	}
	
});

$(document).on('dblclick', '.editor_content_component', function(e) {
	$(this).remove();
});

$(document).on('change', '#editor_background_colour', function(e) {
	if ($('.grapple_active').length > 0) {
		$('.grapple_active').css({ 'background-color': $(this).val() });
	}
	else {
		$('#editor_content_area').css({ 'background-color': $(this).val() });
	}
});

$(document).on('change', '#editor_text_colour', function(e) {
	if ($('.grapple_active').length > 0) {
		$('.grapple_active').css({ 'color': $(this).val() });
	}
	else {
		$('#editor_content_area').css({ 'color': $(this).val() });
	}
});

$(document).on('change', '#editor_article_picker', function(e) {
	var b = $(this).val();

	localStorage.setItem('article_uuid', b);
	editorMaker();
});

$(document).on('click', '#editor_save', function() {

	var content = $('#editor_content_parent').html();
	var title = Date.now();
	if ($('#editor_content_area').find('h1')[0]) {
		title = $('#editor_content_area').find('h1')[0].textContent; 
	}
	var image;
	if ($('#editor_content_area').find('img')[0]) {
		image = $('#editor_content_area').find('img')[0].src;
	}
	var teaser;
	if ($('#editor_content_area').find('p')[0]) {
		teaser = $('#editor_content_area').find('p')[0].textContent;
	}
	var category = $('#editor_category_picker').val();
	var text_colour = $('#editor_text_colour').val();
	var background_colour = $('#editor_background_colour').val();
	var uuid = localStorage.getItem('article_uuid');
	var status = $('#editor_status_picker').val();
	var scope = localStorage.getItem('scope');
	var warranty = $('#editor_warranty').val();
	var ts = $('#editor_timestamp').val();
	$.ajax({
		url: '/manager/editor/save',
		type: 'POST',
		data: {
			content: content,
			title: title,
			timestamp: ts,
			category: category,
			text_colour: text_colour,
			background_colour: background_colour,
			article_uuid: uuid,
			status: status,
			scope: scope,
			warranty: warranty,
			image: image,
			teaser: teaser
		},
		success: function(response) {
			localStorage.setItem('article_uuid', response.uuid);
			editorMaker();
		}
	});
});

$(document).on('click', '#editor_delete', function() {
	var a = $(this);
	var uuid = localStorage.getItem('article_uuid');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/editor/delete',
			type: 'POST',
			data: { article_uuid: uuid },
			success:function(response) {
				localStorage.setItem('article_uuid', 'none');
				editorMaker();
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

$(document).on('click', '#editor_new', function() {
	localStorage.setItem('article_uuid', 'none');
	editorMaker('new');

});

$(document).on('click', '.editor_close_button', function() {
	$('#grapple').hide();
	$('#grapple').css(original_grapple_position);
});