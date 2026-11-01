var att_h;
$(document).on('click', '.attribute_upload_button', function() {
	var att = $(this).attr('att');
	var uuid = $(this).attr('uuid');
	var m = $('.attribute_upload_input[uuid="' + uuid + '"][att="' + att + '"]');
	att_h = $('.attribute_upload_container[att="' + att + '"][uuid="' + uuid + '"]').html();
	m.trigger('click');
});

$(document).on('change', '.attribute_upload_input', function() {
	var att = $(this).attr('att');
	var uuid = $(this).attr('uuid');
	var m =	$('.attribute_upload_input[uuid="' + uuid + '"][att="' + att + '"]');
	if (m[0]['files'].length > 0) {
		$('.attribute_upload[uuid="' + uuid + '"][att="' + att + '"]').trigger('submit');
	}
});

$(document).on('submit', ".attribute_upload", function(e) {
	var att = $(this).attr('att');
	var uuid = $(this).attr('uuid');
	var app = $(this).attr('app');
  e.preventDefault();
	var mui =	$('.attribute_upload_input[uuid="' + uuid + '"][att="' + att + '"]');
  var formData = new FormData(this);
	formData.delete('timestamp');
	formData.append('timestamp', Date.now());
	formData.append('attribute', att);
	formData.append('uuid', uuid);
	formData.append('app', app);
  $.ajax({
      url: '/manager/configure/attribute_upload',
      type: 'POST',
      data: formData,
      success: function (response) {
				$('.attribute_upload_button[att="' + att + '"][uuid="' + uuid + '"]').attr('src', response);
				att_h = undefined;
				formData.delete('fileupload');
				$('.attribute_upload[att="' + att + '"][uuid="' + uuid + '"]').remove();
				$('.attribute_upload_container[att="' + att + '"][uuid="' + uuid + '"]').html(att_h);
				configurationReloader(app);
				openAttributeReopener(app);
      },
      cache: false,
      contentType: false,
      processData: false
  });
});

$(document).on('click', '.attribute_copy', function() {
	var a = $(this);
	var attribute = a.closest('.attribute');
	var uuid = attribute.attr('uuid');
	var att = attribute.attr('att');
	var app = attribute.attr('app');
	
	var acsc = attribute.find('.attribute_copy_selection_container');
	var aca = attribute.find('.attribute_copy_app');
	if (aca.is(':visible')) {

		acsc.hide();
	}
	else {

		acsc.show();
	}
});

$(document).on('click', '.attribute_copy_app_save', function() {
	var a = $(this);
	var attribute = a.closest('.attribute');

	var uuid = attribute.attr('uuid');
	var att = attribute.attr('att');
	var aca = attribute.find('.attribute_copy_app')
	var app = aca.val();
	var wind = $('.wind[app="' + app + '"]');
	var pre_app = attribute.attr('app');
	$.ajax({
		url: '/manager/configure/attribute_copy',
		type: 'POST',
		data: { uuid: uuid, att: att, app: app, pre_app: pre_app },
		success: function(response) {
			var t = $(response.template).find('.attribute[uuid="' + response.attribute.uuid + '"]').html();

			var st = $('.appointment_contents[app="' + response.attribute.app + '"]').scrollTop();
			var existing = wind.find('.attribute[uuid="' + response.attribute.uuid + '"]');
			if (existing.length > 0) {
				existing.html(t);
			}
			else {
				wind.find('.' + att + '_list.' + att + '_attributes').replaceWith(response.template);
			}
			$('.appointment_contents[app="' + response.attribute.app + '"]').scrollTop(st);

			openAttributeReopener(response.attribute.app);
			aca.val('').hide();

			a.addClass('superactive');
			setTimeout(function() {
				a.removeClass('superactive');
				a.hide();				
			},2000);
		}
	});
});


$(document).on('change', '.appointment_model_migration', function() {
	var att = $(this).attr('att');
	var matt = $(this).val();
	var attribute = $(this).closest('.attribute');
	var app = attribute.attr('app');
	var uuid = attribute.attr('uuid');
	$.ajax({
		url: '/manager/store/appointment_model_migration',
		type: 'POST',
		data: { att: att, matt: matt, uuid: uuid, app: app },
		success: function(response) {
			var parent = attribute.closest('.appointment');
			var container = parent.find('.re_register');
			container.html(response.html);
			openAttributeReopener(app);
		}
	});
});



