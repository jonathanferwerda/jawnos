$(document).on('click', '#relational_toggle', function() {
	twirlRunning = false;
	var url = '/manager/relational';
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			relationalInit(response);
		}, error: function (response) {  }
	});
});


$(document).on('click', '#relational_contents_select', function() {
	var construct = $(this).val();
	$.ajax({
		url: '/manager/relational/select',
		type: 'GET',
		data: { construct: construct, setting: 'construct' },
		success: function(response) {
			relationalInit(response);
		}
	});
});

$(document).on('click', '#relational_category_select', function() {
	var construct = $(this).val();
	$.ajax({
		url: '/manager/relational/select',
		type: 'GET',
		data: { construct: construct, setting: 'category' },
		success: function(response) {
			relationalInit(response);
		}
	});
});


$(document).on('change', '.relational_adder', function() {
	var construct = $(this).attr('construct');
	var addition = $(this).val();
	var input = selectorMaker(this);
	$.ajax({
		url: '/manager/relational/adder',
		type: 'POST',
		data: { construct: construct, addition: addition },
		success: function(response) {


			relationalInit(response);
			$(input).focus();
		}
	});
});

function relationalInit(response) {
	var scrollCon = $('#relational_contents').scrollTop();
	var scrollCat = $('#relational_categories').scrollTop();
	var openTable = [];
	$('#relational_contents').find('table:visible').each(function(i,v) { openTable.push($(v).attr('uuid')); });

	if (typeof response != 'object') {
		$('#relational').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); }  });
		windowMaker(response);
	}
	else if (response['contents']) {
		$('#relational_contents').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); }  });
		$('#relational_contents').replaceWith(response.contents);
	}
	else if (response['bucket']) {
//		$('.bucket[uuid="' + response.bucket_uuid + '"]').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); }  });
		$('.bucket[uuid="' + response.bucket_uuid + '"]').replaceWith(response['bucket']);
	}
	else if (response['category']) {
		$('.relational_space[construct="' + response.sc.sing + '"]').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); }  });
		$('.relational_space[construct="' + response.sc.sing + '"]').html(response['category']);
	}
	else if (response.relationalizer.contents) {
		$('#relational').find('.draggable').each(function(i,v) { if ($(v).hasClass('ui-draggable')) { $(v).draggable('destroy'); } });
		$('#relational').replaceWith(response.relationalizer.contents);
	}

	$('#relational_contents').scrollTop(scrollCon);
	$('#relational_categories').scrollTop(scrollCat);
	$.each(openTable, function(i,v) {
		$('table[uuid="' + v + '"]').show();
	});

	$('#relational').find('.draggable').each(function(i,v) {
		var k = $(this);
		k.draggable({
	//		appendTo: 'body',
	//		containment: 'window',
			scroll: false,
			revert: true,
			helper: 'clone',
			start: function(p) {
				var b = $('#' + p.target.id);
				b.show();
				var z = numeral(b.closest('.wind').css('z-index') + 1000).value();
			//	b.css({'z-index': z});
			},
			drag: function(p) {
			},
			stop: function(p,b) {
				var b = $('#' + p.target.id);
				b.css({'position': 'relative', 'z-index': 'auto'});
				var mouse = mouse_position();
				var elements = [];//document.elementsFromPoint(mouse.x, mouse.y);
				$.each(elements, function(i,v) {
					var bu = $(v);
					if (bu.hasClass('bucket') || bu.hasClass('garbage')) {

					}

				});

			}
		});
	});
	$('#relational').find('.droppable').each(function(i,v) {
		var k = $(v);
		k.droppable({
			drop: function(bu,b) {
				var drag = b.draggable[0];


				b = $(drag);
				bu = k;
				var movement = 'add';
				$('.relational_bucket_table[uuid="' + bu.attr('uuid') + '"]').show();
				var timestamp = Date.now();
				var construct = b.attr('construct');
				var uuid = b.attr('uuid');
				var b_uuid = bu.attr('uuid');
				var b_construct = bu.attr('construct');
				if (bu.hasClass('garbage')) { 
					movement = 'delete';
					b_uuid = b.closest('.bucket').attr('uuid');
					b_construct = b.closest('.bucket').attr('construct');
				}
				$.ajax({
					url: '/manager/relational/sorter',
					type: 'POST',
					data: { 
						timestamp: timestamp,
						uuid: uuid,
						construct: construct,
						b_uuid: b_uuid,
						b_construct: b_construct,
						movement: movement
					},
					success: function(response) {
						relationalInit(response);
					}
				});
			}
		});
	});
}

$(document).on('click', '.relational_bucket_header', function() {
	var uuid = $(this).attr('uuid');
	var table = $('.relational_bucket_table[uuid="' + uuid + '"]');
	if (table.is(':visible')) {
		table.hide();
	}
	else {
		table.show();
	}
});


$(document).on('change keyup', '.relational_search', function(e) {
	var ss = $(this);
	var search_tool = $(this).attr('search_tool');
	var search = $(this).val();
	if (e.keyCode == 13 || e.type == 'change') {
		$.ajax({ 
			url: '/manager/relational/search',
			type: 'GET',
			data: { search: search, search_tool: search_tool },
			success: function(response) {
				relationalInit(response);
				ss.focus();
			}
		});
	}

});

$(document).on('click', '.relational_autocalc', function() {
	var uuid = $(this).attr('uuid');
	var construct = $(this).attr('construct');
	$.ajax({
		url: '/manager/relational/autocalc',
		type: 'POST',
		data: { uuid: uuid, construct: construct },
		success:function(response) {
			$('#alert').html(response.html).show();
		}
	});


});

$(document).on('click','#relational_autocalc_confirm', function() {
	var timestamp = Date.now();
	
	$('.relational_autocalc_item').each(function(i,v) {
		var uuid = $(v).attr('uuid');
		var b_uuid = $(v).attr('b_uuid');
		var construct = $(v).attr('construct');
		var b_construct = $(v).attr('b_construct');
		var check = $(v).find('.relational_autocalc_checkbox');
		var movement = 'add';
		if (!check.prop('checked')) {
			movement = 'delete';
		}
		$.ajax({
			url: '/manager/relational/sorter',
			type: 'POST',
			data: { 
				timestamp: timestamp,
				uuid: uuid,
				construct: construct,
				b_uuid: b_uuid,
				b_construct: b_construct,
				movement: movement
			},
			success: function(response) {
				$('#alert').html('').hide();
				relationalInit(response);
			}
		});
	});
});

$(document).on('change', '.relational_autocalc_header_checkbox', function() {
	var category = $(this).attr('category');
	if ($(this).prop('checked')) {
		$('.relational_autocalc_checkbox[category="' + category + '"]').prop('checked', true);
	} else {
		$('.relational_autocalc_checkbox[category="' + category + '"]').prop('checked', false);
	}
});

$(document).on('click', '.relational_tree_select', function() {
	var uuid = $(this).attr('uuid');

	$.ajax({
		url: '/manager/relational/tree',
		type: 'GET',
		data: { uuid: uuid },
		success: function(response) {
			$('#relational_tree_container').html(response.html).show();
			$('#relational_matcher').hide();
			relationalTreeInit(response);
		}
	});


});

var d;
function relationalTreeInit(data) {
	d = data;
	console.log(data);
	var container = $('#relational_tree').closest('.window_contents');
	var width = container.width();
	var height = container.height();
	var canvas = document.getElementById('relational_tree');
	canvas.width = width;
	canvas.height = height;
	var ctx = canvas.getContext('2d');
	ctx.beginPath();

	ctx.font = "400 26px Arial";
	ctx.save('original');
	var rotateIncrement = numeral(360 / (Object.keys(data.relationships).length + 1)).value();
	console.log(rotateIncrement + ' ' + Object.keys(data.relationships).length);
	var count = 0;
	$.each(data.relationships, function(i,v) {
		var dist = canvas.width / 6;
		console.log('rotate ' + i +  ' ' + (rotateIncrement * count));
		ctx.save('upright');
		ctx.beginPath();
		ctx.lineWidth = 5;
		ctx.translate(canvas.width / 2, canvas.height / 2);
		ctx.moveTo(0,0);
		ctx.rotate(rotateIncrement * count);
		ctx.lineTo(0,dist);
		ctx.stroke();
		ctx.fill();
		ctx.translate(0,dist);
		ctx.rotate(rotateIncrement * count * -1);
		ctx.fillText(i, 0,0);

		$.each(v, function(ii,vv) {
			ctx.save('gen1');
			ctx.beginPath();
			var dista = canvas.width / 7;
			var rotateIncrementa = numeral(360 / v.length).value();
			ctx.rotate(rotateIncrementa * v.length * i);
			ctx.lineTo(0,dista);
			ctx.stroke();
			ctx.fill();
			ctx.translate(0,dista);
			ctx.rotate(rotateIncrementa * v.length * -1 * i);
			ctx.fillText(vv.formatted_name, 0,0);
			ctx.restore('gen1');
		});
		ctx.restore('upright');
		count++;
	});
	ctx.restore('original');
	ctx.beginPath();
	ctx.fillStyle = data.settings.colour;
	ctx.lineWidth = 5;
	ctx.globalAlpha = 0.4; 
	ctx.arc(canvas.width / 2, canvas.height / 2, 100, (Math.PI * 2),0, true);

	ctx.fill();
	ctx.globalAlpha = 1;
	ctx.fillStyle = 'black';

  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
	ctx.fillText(data.settings.formatted_name, canvas.width / 2, canvas.height / 2);

	ctx.stroke();
}






