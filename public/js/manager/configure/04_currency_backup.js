// ---- currency amounts -------------------------------------------------------
// Every amount rendered through configure/currency_amount carries its value in
// the house currency and a picker of the currencies the rate snapshot carries.
// A change converts that one amount in place; inside a balance series it also
// redoes the pace line and the "showing" note, using the translated templates
// stored on those elements. No round trip, and the chart's SVG never redraws
// because a line's shape does not depend on the unit it is counted in.
function jawnosCurrencyValue(value) {
	if (!isFinite(value)) { return ''; }
	var abs = Math.abs(value);
	return (abs > 0 && abs < 0.1) ? value.toFixed(4) : value.toFixed(2);
}
function jawnosCurrencyApply(select) {
	var picker = $(select);
	var option = select.options[select.selectedIndex];
	var rate = option ? parseFloat(option.getAttribute('data-rate')) : NaN;
	var amount = picker.closest('.currency_amount');
	var base = parseFloat(amount.attr('data-base-amount'));
	if (!isFinite(rate) || !isFinite(base)) { return; }
	var code = option.getAttribute('value') || select.value || '';
	amount.find('.currency_value').text(jawnosCurrencyValue(base * rate));
	var series = picker.closest('.balance_series');
	if (!series.length) { return; }
	series.find('.balance_rate').each(function () {
		var line = $(this);
		var perDay = parseFloat(line.attr('data-base-per-day'));
		var template = line.attr('data-template') || '';
		if (!isFinite(perDay) || template.indexOf('{0}') < 0) { return; }
		var money = jawnosCurrencyValue(Math.abs(perDay * rate)) + ' ' + code;
		var span = line.attr('data-span') || '';
		line.text(template.replace('{0}', money) + (span ? ' · ' + span : ''));
	});
	// The projected spend carries the same base-currency burn, so it follows the
	// picker too. The runway is a duration, not an amount, and stays put.
	series.find('.balance_expense').each(function () {
		var line = $(this);
		var perDay = parseFloat(line.attr('data-base-per-day'));
		var template = line.attr('data-template') || '';
		if (!isFinite(perDay) || template.indexOf('{0}') < 0) { return; }
		var money = function (span) { return jawnosCurrencyValue(Math.abs(perDay * span * rate)) + ' ' + code; };
		line.text(template.replace('{0}', money(1)).replace('{1}', money(7)).replace('{2}', money(30)));
	});
	series.find('.balance_hour_peak').each(function () {
		var line = $(this);
		var amount = parseFloat(line.attr('data-base-amount'));
		var template = line.attr('data-template') || '';
		if (!isFinite(amount) || template.indexOf('{1}') < 0) { return; }
		// the hour is a clock reading and does not change with the currency
		var hour = line.attr('data-hour') || '';
		line.text(template.replace('{0}', hour).replace('{1}', jawnosCurrencyValue(Math.abs(amount * rate)) + ' ' + code));
	});
	// An hour's detail line is rendered with the panel, one per hour, so a
	// currency change rebuilds it from the same attributes: only the money
	// moves, the hour and the share stay as printed.
	series.find('.balance_hour_detail').each(function () {
		var line = $(this);
		var template = line.attr('data-template') || '';
		var spend = parseFloat(line.attr('data-base-amount'));
		if (template.indexOf('{1}') < 0) { return; }
		var money = isFinite(spend) ? (jawnosCurrencyValue(Math.abs(spend * rate)) + ' ' + code) : '';
		line.text(template
			.replace('{0}', line.attr('data-hour') || '')
			.replace('{1}', money)
			.replace('{2}', line.attr('data-share') || '')
			.replace('{3}', line.attr('data-tokens') || '')
			.replace('{4}', line.attr('data-calls') || ''));
	});
	series.find('.balance_currency_note').each(function () {
		var note = $(this);
		var template = note.attr('data-template') || '';
		if (template.indexOf('{0}') < 0) { return; }
		// The provider's own figure needs no conversion note; the picker already
		// says which currency it is.
		if (code === (amount.attr('data-source') || '')) { note.hide().text(''); return; }
		note.show().text(template.replace('{0}', code));
	});
}
$(document).on('change', '.currency_picker', function () {
	jawnosCurrencyApply(this);
});
$(document).on('change', '.balance_provider', function () {
	var chart = $(this).closest('.balance_chart');
	var provider = $(this).val() || '';
	chart.find('.balance_series').each(function () {
		$(this).css('display', ($(this).attr('data-provider') || '') === provider ? '' : 'none');
	});
});

$(document).on('click', '.localstorage_delete', function() {
	var key = $(this).attr('key');
	localStorage.removeItem(key);
	$('.system_localstorage[key="' + key + '"]').remove();
});

$(document).on('click', '#appointment_list_grabber', function() {

	var b = $(this);
	var text = jawnosConfigureLabel(b);
	b.text('* ' + text);
	var c = $('#configure_appointment_list');
	$.ajax({
		url: '/manager/configure/appointment_list',
		type:'GET',
		success:function(response) {
			$('#configure_appointment_list').html(response);
			if (jawnosConfigureShow('appointment_list_grabber', $('#configure_appointment_list'))) {
				b.text(text);
				b.attr('status', 'active');
			}
		},
	});
});

$(document).on('click', '.appointment_configuration_grabber', function() {
	var t = $(this);
	var app = t.attr('app');
	var parent = t.closest('.wind');
	var display = $('.appointment_display[app="' + app + '"]');
	if (display.is(':visible')) {
		display.hide();
		t.attr('status', 'active');
		appActSync($(display).closest('.wind'));
	}
	else {
		appActExclusive(app, 'appointment_configuration_grabber');
		configurationGrabber({ app: app, display: display });
		t.attr('status', 'active');
	}
});

function configurationGrabber(data) {
	var app = data['app'];
	var display = data['display'];
	if (!display) {
		display = $('.appointment_display[app="' + app + '"]');
	}
	var setting = data['setting'] || [];
	var jSetting = JSON.stringify(setting);
	var focused = selectorMaker($(document).find(':focus')[0]);
	var elementCount = $(display).length;
	var config = 0;
	if (display.closest('.wind').attr('app') == 'configure') {
		config = 1;
	}
	var visible = [];
	$('.app_configure_input[app="' + app + '"]').each(function(i,v) {
	  if ($(v).is(':visible')) {
			visible.push($(v).attr('setting'));
		 }
	});

	$.ajax({
		url: '/manager/configure/appointment_display',
		type: 'GET',
		data: { app: app, config: config, setting: jSetting },
		success: function(response) {

			if (setting.length > 0) {
				$.each(setting, function(i,v) {
					var container = $(response).find('.configuration_ability_container[setting="' + v + '"]').html();
					$('.configuration_ability_container[setting="' + v + '"]').html(container);
				});
			} else {
				display.html(response).show();
			}
			// the panel is drawn: tell the server it is open, now, so the beat
			// has no panel news to carry
			appActSync($(display).closest('.wind'));
			$.each(visible, function(i,v) {
				$('.app_configure_input[app="' + app + '"][setting="' + v + '"]').show().closest('.configuration_ability_container').addClass('open');
			});
			if ($(display).length == elementCount) {
				$(focused).focus();
			}
			else {
				if (elementCount > $(display).length) {
					if (!$(focused).is('select') && $(focused).attr('type') != 'checkbox') {
						$(focused).focus();
						$(document).find(':focus').next();
					}
				}
				else {
					if (!$(focused).is('select') && $(focused).attr('type') != 'checkbox') {
						$(focused).focus();
						$(document).find(':focus').prev();
					}
				}
			}
		}
	});
}

function configurationReloader(app,timeout) {
	if (timeout == undefined) {
		timeout = 50;
	}
	setTimeout(function() {
		var window = $('.wind[app="' + app + '"]');
		var display = window.find('.appointment_display');
		configurationGrabber({ app: app, display: display });
	}, timeout);
}

$(document).on('click', '#backup_now', function() {
	var credential = $('#credential').val();
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/backup_now',
		type: 'GET',
		data: { task: 'backup', timestamp: timestamp, credential: credential },
		success: function(response) {

		}
	});
});

$(document).on('keyup', '.ticket_input', function() {
	var input = $(this);
	var timestamp = Date.now();
	var input_number = input.attr('data-input_number');
	var form = input.closest('.ticket_form');
	if (input_number < 8 && input.val().length > 0) {
		if (input.val().length > 1) {

		}
		else {
			input_number++;
			$('#ticket_number_' + input_number).focus();
		}
	}
	if ( input_number == 8) {
		var numerics = numericals();
		var formData = new FormData(document.getElementById('signatorial_upload'));
		formData.delete('timestamp');
		formData.append('timestamp', timestamp);
		formData.append('numerics', numerics);

		var m =	$('#signatorial_upload_input');
		if (m[0]['files'].length == 0) {
			formData.delete('fileupload');
		}
		$.ajax({
			url: '/manager/configure/password_update',
			type: 'POST',
			data: formData,
			success: function(response) {
				m = undefined;
				formData.delete('fileupload');
				$('#signatorial_upload').remove();
				$('#signatorial_upload_container').html(sig_h);
			},
			cache: false,
			contentType: false,
			processData: false
		});
	}
});
var sig_h;
$(document).on('click', '#signatorial_upload_button', function() {
	var m =	$('#signatorial_upload_input');
	sig_h = $('#signatorial_upload_container').html();
	m.trigger('click');
});


$(document).on('change', '#signatorial_upload_input', function() {
	var m =	$('#signatorial_upload_input');
	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('#ticket_number_0').focus();
	}
});

var mug_h;
$(document).on('click', '.mugshot_upload_button', function() {
	var device = $(this).attr('device');
	var m = $('.mugshot_upload_input[device="' + device + '"]');
	mug_h = $('.mugshot_upload_container[device="' + device + '"]').html();
	m.trigger('click');
});

$(document).on('change', '.mugshot_upload_input', function() {
	var device = $(this).attr('device');
	var m =	$('.mugshot_upload_input[device="' + device + '"]');

	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('.mugshot_upload[device="' + device + '"]').trigger('submit');
	}
});



$(document).on('submit', ".mugshot_upload", function(e) {
	var device = $(this).attr('device');
  e.preventDefault();
	var mui =	$('.mugshot_upload_input[device="' + device + '"]');
  var formData = new FormData(this);
	formData.delete('timestamp');
	formData.append('timestamp', Date.now());
	formData.append('device', device);
  $.ajax({
      url: '/manager/configure/mugshot_upload',
      type: 'POST',
      data: formData,
      success: function (response) {
				$('.mugshot_upload_button[device="' + device + '"]').attr('src', response);
				mug_h = undefined;
				formData.delete('fileupload');
				$('.mugshot_upload[device="' + device + '"]').remove();
				$('.main_upload_container[device="' + device + '"]').html(mug_h);
      },
      cache: false,
      contentType: false,
      processData: false
  });
});

var logo_h;
$(document).on('click', '.logo_upload_button', function() {
	var device = $(this).attr('device');
	var m = $('.logo_upload_input[device="' + device + '"]');
	mug_h = $('.logo_upload_container[device="' + device + '"]').html();
	m.trigger('click');
});

$(document).on('change', '.logo_upload_input', function() {
	var device = $(this).attr('device');
	var m =	$('.logo_upload_input[device="' + device + '"]');

	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('.logo_upload[device="' + device + '"]').trigger('submit');
	}
});



$(document).on('submit', ".logo_upload", function(e) {
	var device = $(this).attr('device');
  e.preventDefault();
	var mui =	$('.logo_upload_input[device="' + device + '"]');
  var formData = new FormData(this);
	formData.delete('timestamp');
	formData.append('timestamp', Date.now());
	formData.append('device', device);
  $.ajax({
      url: '/manager/configure/logo_upload',
      type: 'POST',
      data: formData,
      success: function (response) {
				$('.logo_upload_button[device="' + device + '"]').attr('src', response);
				logo_h = undefined;
				formData.delete('fileupload');
				$('.logo_upload[device="' + device + '"]').remove();
				$('.logo_upload_container[device="' + device + '"]').html(logo_h);
      },
      cache: false,
      contentType: false,
      processData: false
  });
});

$(document).on('click','#sms_list_check',function() {
	var phone = $(this).attr('phone');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/sms_list_check',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
		}
	});
});


$(document).on('click', '.restore_database', function() {
	var b = $(this);
	var text = b.text();
	b.text('* ' + text);
	var filename = b.attr('filename');
	$.ajax({ 
		url: '/manager/configure/restore_now',
		type: 'POST',
		data: { filename: filename },
		success: function(response) {
			response = JSON.parse(response);
			$('#manager_file').text(response.disposition);
			var disposition = 'F';
			if (response.status == 'fail') {
				b.text('N ' + text);
			}
			else {
				b.text('Y ' + text);
			}

			localStorage.removeItem('manager_search_cache');
			setTimeout(function() {
				b.text(text);
			},1500);
		},
		error: function(response) { console.log(response); }
	});
});

$(document).on('click','.merge_database', function() { 
	var b = $(this);
	var text = b.text();
	b.text('* ' + text);
	var filename = b.attr('filename');
	var action = b.attr('action');
	$.ajax({ 
		url: '/manager/configure/merge_database',
		type: 'POST',
		data: { action: action, filename: filename },
		success: function(response) {
			response = JSON.parse(response);
			$('#manager_file').text(response.disposition);
			localStorage.removeItem('manager_search_cache');
			if (response.status == 'fail') {
				b.text('N ' + text);
			}
			else {
				b.text('Y ' + text);
			}
			localStorage.removeItem('manager_search_cache');
			setTimeout(function() {
				b.text(text);
			},1500);
		},
		error: function(response) { console.log(response); }
	});
});


$(document).on('click','#new_database', function() {
	var timestamp = Date.now();
	var president = $('#president').val();
	var credential = $('#credential').val();
	$.ajax({
		url: '/manager/configure/new_database',
		type: 'POST',
		data: { timestamp: timestamp, president: president, credential: credential },
		success: function(response) {
			$('#manager_file').text(response);
		}
	});
});

$(document).on('click', '.vacuum_app', function() {
	var app = $(this).attr('app');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/vacuum_app',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			jawnosAlert(response);
		}
	});
});

// Deleting a whole app takes every record, setting and piece of stock with it and
// rides to every machine. It lives here, not in the appointment editor, and the
// person has to type the app's own name before it runs.
$(document).on('click', '.delete_whole_app', function() {
	var app = $(this).attr('app');
	var typed = prompt('Delete the app "' + app + '"?\n\nThis removes every record, setting and piece of stock in it, and the deletion is copied to every machine.\n\nType the app\'s name to confirm:');
	if (typed === null) { return; }
	var normal = typed.trim().toLowerCase().replace(/\s+/g, '_');
	if (normal !== app) {
		jawnosAlert('The name did not match. Nothing was deleted.');
		return;
	}
	$.ajax({
		url: '/manager/delete_whole_app',
		type: 'POST',
		data: { app: app, confirm_name: app, timestamp: Date.now(), server_time: Date.now() },
		success: function() {
			$('.app_block[app="' + app + '"]').remove();
			$('.appointment_configuration_cell[app="' + app + '"]').remove();
			$('.wind[app="' + app + '"]').remove();
		},
		error: function(xhr) {
			jawnosAlert(xhr && xhr.status == 403 ? 'That is a house app and cannot be deleted.' : 'Could not delete the app.');
		}
	});
});

$(document).on('click', '.app_configure_toggle', function() {
	var app = $(this).attr('app');
	var setting = $(this).attr('setting');
	var input = $('.app_configure_input[app="' + app + '"][setting="' + setting + '"]');
	var container = $(this).closest('.configuration_ability_container');
	if (input.is(':visible')) {
		input.hide();
		container.removeClass('open');
	}
	else {
		input.show();
		container.addClass('open');
	}
});

$(document).on('click', '#vacuum_app_confirm', function() {
	var app = $(this).attr('app');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/vacuum_app_confirm',
		type: 'POST',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			jawnosAlert(response);
			$('.appointment_configuration_cell[app="' + app + '"]').remove();
			$('.wind[app="' + app + '"]').remove();
		}
	});
});

$(document).on('click', '.adopt_app', function() {
	var app = $(this).attr('app');
	var scope = localStorage.getItem('scope');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/adopt_app',
		data: { app: app, timestamp: timestamp, scope: scope },
		success: function(response) {
			jawnosAlert(response);
		}
	});
});

$(document).on('click', '.adopt_file', function() {
	var file = $(this);
	var adopted = file.attr('adopted');
	if (adopted == 'yes') {
		adopted = 'no';
	}
	else {
		adopted = 'yes';
	}
	file.attr('adopted', adopted);
});

$(document).on('click', '#adopt_app_confirm', function() {
	var files = [];
	var app = $(this).attr('app');
	var timestamp = Date.now();
	$('.adopt_file[adopted="yes"').each(function(i,v) {
		var timestamp = $(v).attr('timestamp');
		var file = $(v).attr('file');
		var app = $(v).attr('app');
		var type = $(v).attr('type');
		files.push({ app: app, type: type, file: file, timestamp: timestamp });
	});
	var jfiles = JSON.stringify(files);
	$.ajax({
		url: '/manager/configure/adopt_app_confirm',
		type: 'POST',
		data: { app: app, timestamp, timestamp, files: jfiles },
		success: function(response) {
			jawnosAlertClose();
		}
	});
});

$(document).on('click', '#database_doctor', function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/database_doctor',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			jawnosAlert(response.html);
		}
	});
});

$(document).on('click', '#database_doctor_confirm', function() {
	var timestamp = Date.now();
	var auuid = $('#alert').attr('uuid');
	$.ajax({
		url: '/manager/configure/database_doctor_confirm',
		type: 'POST',
		data: { timestamp: timestamp, auuid: auuid },
		success: function(response) {
		}
	});
});

