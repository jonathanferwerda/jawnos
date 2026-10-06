var openAttributes = {};
$(document).on('click', '.attribute_header', function() {
	var a = $(this);
	var att = a.attr('att');

	var uuid = a.attr('uuid');
	var contents = $('.attribute_contents[att="' + att + '"][uuid="' + uuid + '"]');
	var app = contents.attr('app');
	var container = $('.attribute[uuid="' + uuid + '"][att="' + att + '"]');
	var state;
	if (contents.is(':visible')) {
		contents.hide();
		state = 'closed';
	}
	else {
		contents.show();
		state = 'open';
	}
	if (!openAttributes[app]) { openAttributes[app] = {}; }
	openAttributes[app][uuid] = state;
});

function openAttributeReopener(app) {
	if (openAttributes[app]) {
		$('.appointment[app="' + app + '"]').find('.attribute_contents').each(function(i,v) {
			var uuid = $(v).attr('uuid');

			if (openAttributes[app][uuid] == 'open') {
				$(v).show();
			}
			else if (uuid != 'new') {
				$(v).hide();
			}
		
		});
	}
}

$(document).on('change', '.att', function() {
	var att = $(this).closest('.attribute');
	var attribute = att.attr('att');
	var wind = att.closest('.appointment');
	var app = att.attr('app');
	var uuid = att.attr('uuid') || 'new';
	var name = att.find('.name').val();
	var cost = att.find('.cost').val();
	var markup = att.find('.markup').val();
	var price = att.find('.price').val();
	var discount = att.find('.discount').val();
	var description = att.find('.description').val();
	var delay_start = att.find('.delay_start').val();
	var delay_stop = att.find('.delay_stop').val();
	var manufacturer = att.find('.manufacturer').val() || wind.find('.appointment_setting[setting="manufacturer"]').val();
	var def = att.find('.def').prop('checked');
	var def_month = JSON.stringify(att.find('.def_month').val());
	var def_day = JSON.stringify(att.find('.def_day').val());
	var def_hour = JSON.stringify(att.find('.def_hour').val());
	var def_wday = JSON.stringify(att.find('.def_wday').val());
	if (def == true) { 
		def = 'on'; 
		$('.attribute[app="' + app + '"]').each(function(i,v) {
			if ($(v).attr('uuid') != uuid) {
				$(v).find('.def').prop('checked', false);
			}
		});
	}

	var save_app = att.find('.save_app').prop('checked');
	if (save_app == true) { save_app = 'on'; }
	var quantity = att.find('.quantity').val();
	var unit = att.find('.unit').val();

	var category = wind.find('.configure_input[setting="category"]').val();

	var characteristics = "";
	var timestamp = Date.now();

	var scrolls = {};
	$.each(['.def_day','.def_hour','.def_wday','.def_month'], function(i,v) {
		scrolls[v] = att.find(v).scrollTop();
	});


	$.ajax({ 
		url: '/manager/store/' + attribute + '/save',
		type: 'POST',
		data: {
			uuid: uuid,
			name: name,
			cost: cost,
			price: price,
			markup: markup,
			discount: discount,
			app: app,
			description: description,
			characteristics: characteristics,
			manufacturer: manufacturer,
			timestamp: timestamp,
			def: def,
			def_month: def_month,
			def_day: def_day,
			def_wday: def_wday,
			def_hour: def_hour,
			save_app: save_app,
			quantity: quantity,
			unit: unit,
			manufacturer: manufacturer,
			delay_start: delay_start,
			delay_stop: delay_stop
		},
		success: function(response) {
			if (uuid == 'new') {
				wind.find('.' + attribute + '_list').replaceWith(response.template);
			}
			else {
			//	configurationReloader(app);

				var t = $(response.template).find('.attribute[uuid="' + uuid + '"]').html();

				var st = $('.appointment_contents[app="' + app + '"]').scrollTop();
				wind.find('.attribute[uuid="' + uuid + '"]').html(t);
				$('.appointment_contents[app="' + app + '"]').scrollTop(st);

				openAttributeReopener(app);
			}
			var att = wind.find('.attribute[uuid="' + uuid + '"]');
			$.each(scrolls, function(i,v) {
				att.find(i).scrollTop(v);
			});
		}
	});
});

$(document).on('change', '.option_category_picker', function() {
	
});

$(document).on('change', '.char', function(e) {
	var timestamp = Date.now();
	var char = $(this);
	var type = char.attr('type');
	var char_input = char.attr('char_input');
	var value = char.val();
	if (char.attr('type') == 'checkbox') {
		if (char.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}

	var ac = char.closest('.attribute_characteristic');
	var att = ac.attr('att');
	var att_uuid = ac.attr('att_uuid');
	var uuid = ac.attr('uuid');
	var container = char.closest('.appointment');
	var app = container.attr('app');
	
	$.ajax({
		url: '/manager/store/attribute_characteristic_setter',
		type: 'POST',
		data: { app: app, timestamp: timestamp, uuid: uuid, att: att, att_uuid: att_uuid, input: char_input, value: value, type: type },
		success: function(response) {
			ac.attr('uuid', response.uuid);

			var t = $(response.template).find('.attribute[uuid="' + att_uuid + '"]').html();
			var st = $('.appointment_contents[app="' + app + '"]').scrollTop();
			container.find('.attribute[uuid="' + att_uuid + '"]').html(t);
			$('.appointment_contents[app="' + app + '"]').scrollTop(st);
			openAttributeReopener(app);
//			configurationReloader(app);
		}
	});
});

$(document).on('click', '.delete_characteristic', function() {
	var a = $(this);
	var attr = $(this).closest('.attribute_characteristic');
	var uuid = attr.attr('uuid');
	var att = attr.attr('att');
	var att_uuid = attr.attr('att_uuid');

	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/store/characteristic_delete',
			type: 'POST',
			data: { uuid: uuid, att: att, att_uuid: att_uuid },
			success: function(response) {
				var ac = $('.attribute_characteristic[uuid="' + response.uuid + '"]');
				ac.next().remove();
				ac.remove();
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

$(document).on('click', '.delete_attribute', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var att = a.attr('att');
	var timestamp = Date.now();
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/store/attribute_delete',
			type: 'POST',
			data: { uuid: uuid, att: att, timestamp: timestamp },
			success: function(response) {
				$('.attribute[uuid="' + uuid + '"]').remove();
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

$(document).on('change', '.appointment_model_selector, .appointment_model_quantity, .appointment_model_unit', function() {
	var cause = 'toggle';
	if ($(this).hasClass('appointment_model_quantity')) {
		cause = 'quantity';
	}
	if ($(this).hasClass('appointment_model_unit')) {
		cause = 'unit';
	}
	if ($(this).hasClass('appointment_model_selector')) {
		cause = 'model';
	}
	var model_dom = $(this).closest('.appointment_model_selector_container').find('.appointment_model_selector');
	var unit_dom = $(this).closest('.appointment_model_selector_container').find('.appointment_model_unit');
	var quantity_dom = $(this).closest('.appointment_model_selector_container').find('.appointment_model_quantity');
	var uuid = model_dom.val();
	var unit = unit_dom.val();
	var source = 'list';
	if (model_dom.hasClass('purchase_input')) {
		source = 'transaction';
	}

	var app = $(this).closest('.appointment').attr('app');
	var appt_uuid = $(this).closest('.appointment_detail').attr('uuid');
	var quantity = quantity_dom.val();
	var timestamp = Date.now();
	var data = { timestamp: timestamp, uuid: uuid, appt_uuid: appt_uuid, app: app, source: source, cause: cause, quantity: quantity, unit: unit };
	$.ajax({
		url: '/manager/store/appointment_model_selector',
		type: 'POST',
		data: data,
		success: function(response) {
		}
	});
});

$(document).on('change', '.appointment_model_packaging', function() {
	var pack = $(this);
	var sp = $(this).find('[uuid="' + pack.val() + '"]');
	var pc = [ 'quantity', 'length', 'width', 'weight', 'each', 'height' ];
	$.each(pc, function(i,v) {
		pack.closest('.appointment_model_selector_container').find('[attribute="' + v + '"]').val(sp.attr(v));
	});
});

$(document).on('click', '.appointment_option', function(e) {
	if ($(e.target).hasClass('appointment_option_quantity') || $(e.target).hasClass('appointment_option_unit') || $(e.target).hasClass('appointment_option_name')) {
		return;
	}
	var uuid = $(this).attr('uuid');
	if ($(this).attr('source') == 'list') {
		appointmentOptionUpdater($(this),'click');
	}
	else {
		if ($(this).attr('select') == 'on') {
			$(this).attr('select', 'off');
		}
		else {
			$(this).attr('select', 'on');
		}
	}
});

function appointmentOptionUpdater(o,source) {
	var ad = o.closest('.appointment_detail');
	var appt_uuid = ad.attr('uuid');
	var uuid = o.attr('uuid');
	var ao = ad.find('.appointment_option[uuid="' + uuid + '"][appt_uuid="' + appt_uuid + '"]');
	var app = ao.closest('.appointment').attr('app');

	var timestamp = Date.now();

	var name = ao.attr('name');
	var quantity = ao.find('.appointment_option_quantity').val() || 1;
	var unit = ao.find('.appointment_option_unit').val();
	var select = ao.attr('select');
	if (source == 'click') {
		if (select == 'on') {
			select = 'off';
		}
		else {
			select = 'on';
		}
	}
	var all_options = [];

	ad.find('.appointment_option', function(i,v) {
		if ($(v).attr('select') == 'on') {
			all_options.push({ uuid: $(v).attr('uuid'), quantity: $(v).find('.appointment_option_quantity').val() });
		}
	});
	all_options = JSON.stringify(all_options);

	$.ajax({
		url: '/manager/store/appointment_option_selector',
		type: 'POST',
		data: { 
			all_options: all_options,
			timestamp: timestamp,
			uuid: uuid,
			app: app,
			appt_uuid: appt_uuid,
			quantity: quantity,
			select: select,
			unit: unit 
		},
		success: function(response) {
			ad.find('.appointment_option[appt_uuid="' + appt_uuid + '"]').attr('select', 'off');
			$.each(response, function(i,v) {
				$('.appointment_option[appt_uuid="' + appt_uuid + '"][uuid="' + v['uuid'] + '"]').attr('select', 'on');
			});
			openAttributeReopener(app);
		}
	});
}

$(document).on('change', '.appointment_option_quantity, .appointment_option_unit', function() {
	var uuid = $(this).attr('uuid');
	appointmentOptionUpdater($(this));
});

$(document).on('change', '.appointment_status_selector', function() {
	var status = $(this).val();
	var app = $(this).attr('app');
	var appt_uuid = $(this).attr('uuid');
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/transaction/status',
		type: 'POST',
		data: { app: app, status: status, appt_uuid: appt_uuid, timestamp: timestamp },
		success: function(response) {
		}
	});
});

$(document).on('change', '.appointment_markup', function() {
	var app = $(this).closest('.appointment').attr('app');
	var value = $(this).val();
	settingSetter({ 'app': app, 'setting': 'markup', 'value': value });
});

$(document).on('change', '.appointment_setting[setting="manufacturer"]', function() {
	var app = $(this).attr('app') || $(this).closest('.appointment').attr('app') || $(this).closest('.wind').attr('app');
	configurationReloader(app);
});

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



