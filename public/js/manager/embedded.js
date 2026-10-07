var edt = 'watch';
var edt_diagrams = { components: [], file: {} };
$(document).ready(function() {
	edt = localStorage.getItem('embedded_device_type') || 'watch';
});
$(document).on('change', '#embedded_device_picker', function() {
	var timestamp = Date.now();
	edt = $(this).val();
	var chip_id = $('#embedded_device_chip_id').val();
	localStorage.setItem('embedded_device_type', edt);
	localStorage.setItem('embedded_chip_id', chip_id);
	embeddedDevicesOpener();
});

$(document).on('change', '#embedded_device_chip_id', function() {
	var chip_id = $(this).val();
	localStorage.setItem('embedded_chip_id', chip_id);
	var edt = $('#embedded_device_picker').val();
	localStorage.setItem('embedded_device_type', edt);
	embeddedDevicesOpener();
});

$(document).on('click', '#embedded_toggle', function() {
	embeddedDevicesOpener();
});

function embeddedDevicesOpener() {
	var timestamp = Date.now();
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var view = localStorage.getItem('embedded_view');
	$.ajax({
		url: '/manager/embedded',
		type: 'GET',
		data: { 
			timestamp: timestamp,
			edt: edt,
			chip_id: chip_id,
			view: view,
		},
		success: function(response) {
			windowMaker(response.html);
			localStorage.setItem('embedded_chip_id', response.chip_id);
			localStorage.setItem('embedded_device_type', response.edt);
		}
	});
}

$(document).on('click', '.embedded_detail', function() {
	var numero = $(this).attr('numero');
	var form = $(this).attr('form');
	var pin = $(this).attr('pin');
	embeddedDetailGrabber({ numero: numero, form: form, pin: pin });
});

function embeddedDetailGrabber(data) {
	var timestamp = Date.now();
	var numero = data['numero'];
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var view = localStorage.getItem('embedded_view');
	var form = data['form'];
	var pin = data['pin'];
	$.ajax({
		url: '/manager/embedded/pin_grabber',
		type: 'GET',
		data: { 
			numero: numero, 
			edt: edt, 
			chip_id: chip_id, 
			view: view, 
			form: form,
			timestamp: timestamp,
			pin: pin
		},
		success: function(response) {
			$('#embedded').append(response.html);
		}
	});




}

$(document).on('change', '#embedded_view', function() {
	var view = $(this).val();
	localStorage.setItem('embedded_view', view);
	embeddedDevicesOpener();
});

$(document).on('click', '.watch_component', function() {
	var b = $(this);
	var numero = b.attr('numero');
	var component = b.attr('component');
	var conf = $('#watch_configure_' + component + '_' + numero);

	if (conf.is(':visible')) {
		conf.hide();

	}
	else {
		conf.show();
		var input = $('#watch_input_' + component + '_' + numero);
		input.focus();
	}
});

$(document).on('click', '#watch_set_proxy', function() {
	var timestamp = Date.now();
	var scope = $('#watch_scope').val();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var continent = continent_record({app:edt,timestamp:timestamp,purpose:'proxy_set',scope:scope,chip_id:chip_id});
	var scope = $('#watch_scope').val();

});

function setProxy(timestamp,uuid) {
	var scope = $('#watch_scope').val();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	$.ajax({
		url: '/manager/watch/set_proxy',
		data: { timestamp: timestamp, uuid: uuid, scope: scope, edt: edt, chip_id: chip_id },
		success: function(response) {
			mapCampus(timestamp,response,'embedded_campus');
			var w = $('#watch_set_proxy');
			w.addClass('active');
			setTimeout(function() {
				w.removeClass('active');
			},1000);
		}
	});
}

$(document).on('change', '#watch_scope', function() {
	var scope = $(this).val();
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	$.ajax({
		url: '/manager/setting_setter',
		type: 'POST',
		data: { app: 'watch', setting: 'watch_scope', value: scope, timestamp: timestamp, edt: edt, chip_id: chip_id },
		success:function(response) {
		}
	});
});


$(document).on('click', '#watch_list_proxy', function() {
	var timestamp = Date.now();
	var scope = $('#watch_scope').val();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	if ($('#watch_proxy_view').html() != '') {
		$('#watch_proxy_view').html('');
		$('#embedded_campus').hide()
	}
	else {
		var continent = continent_record({app:edt,timestamp:timestamp,purpose:'proxy_load',scope:scope, chip_id:chip_id});
		$('#embedded_campus').show();
	}
});

var campusProxy = {};
function listProxy(timestamp,uuid) {
	var scope = $('#watch_scope').val();
	var window_width = $('#watch_scope').closest('.wind').width();
	var window_height = $('#watch_scope').closest('.wind').width();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	$.ajax({
		url: '/manager/watch/list_proxy',
		data: { timestamp: timestamp, uuid: uuid, scope: scope, width: window_width, height: window_height, edt: edt, chip_id: chip_id },
		success: function(response) {
			$('#watch_proxy_view').html(response['html']);

			mapCampus(timestamp,response,'embedded_campus');
		}
	});
}



$(document).on('click', '.watch_proxy_load', function() {
	var proxy = $(this).closest('.proxy');
	var uuid = proxy.attr('uuid');
	var timestamp = $(this).closest('.wind').attr('timestamp');
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	$.ajax({
		url: '/manager/watch/proxy_load',
		type: 'POST',
		data: { timestamp: timestamp, uuid: uuid, edt: edt, chip_id: chip_id },
		success: function(response) {
			var h = $(response).find('#watch_buttons').html();
			$('#watch_buttons').html(h);
		}
	});
});

$(document).on('click', '.watch_proxy_here', function() {
	var proxy = $(this).closest('.proxy');
	var uuid = proxy.attr('uuid');
	var timestamp = Date.now();
	var continent = continent_record({app:'watch',timestamp:timestamp});
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	setTimeout(function() {
		$.ajax({
			url: '/manager/watch/proxy_here',
			type: 'POST',
			data: { timestamp: timestamp, uuid: uuid, edt: edt, chip_id: chip_id },
			success: function(response) {
			}
		});
	}, 5000);
});

$(document).on('click', '.watch_proxy_delete', function() {
	var proxy = $(this).closest('.proxy');
	var uuid = proxy.attr('uuid');
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	$.ajax({
		url: '/manager/watch/delete_proxy',
		type: 'POST',
		data: { uuid: uuid, edt: edt, chip_id: chip_id },
		success: function(response) {
			$('.proxy[uuid="' + response + '"]').remove();
		}
	});
});

$(document).on('click', '.watch_proxy_save', function() {
	var proxy = $(this).closest('.proxy');
	var uuid = proxy.attr('uuid');
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/watch/proxy_save',
		type: 'POST',
		data: { uuid: uuid, timestamp: timestamp, edt: edt, chip_id: chip_id },
		success: function(response) {
		}
	});
});

$(document).on('click', '.embedded_jobs', function() {
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var ip = $(this).attr('ip');
	var mac = $(this).attr('mac');
	var timestamp = Date.now();
	var ejr = $('#embedded_jobs_results');
	if (ejr.is(':visible')) {
		ejr.hide();
	}
	else {
		$.ajax({
			url: '/manager/embedded/jobs',
			type: 'GET',
			data: { edt: edt , chip_id: chip_id, ip: ip, mac: mac, timestamp: timestamp },
			success: function(response) {
				$('#embedded_jobs_results').html(response.html).show();
				appointment_chron();
			}
		});
	}
});

$(document).on('click', '.delete_embedded_job', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var appt_uuid = a.attr('appt_uuid');
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var timestamp = Date.now();
	if (a.attr('armed') == 'yes') {	
		$.ajax({
			url: '/manager/embedded/delete_job',
			type: 'POST',
			data: { timestamp: timestamp, edt: edt, chip_id: chip_id, appt_uuid: appt_uuid },
			success: function(response) {
				$('.embedded_job[uuid="' + uuid + '"]').remove();
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


$(document).on('change', '.watch_setting', function() {
	var movement = $(this);
	var setting = movement.attr('setting');
	var numero = movement.attr('numero');
	var component = movement.attr('component');
	var edt = movement.attr('edt') || localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = movement.attr('chip_id') || localStorage.getItem('embedded_chip_id') || '';
	var mov = movement.val();
	if (movement.attr('type') == 'checkbox') {
		if (movement.prop('checked') == true) {
			mov = 1;
		}
		else {
			mov = 0;
		}
	}
	if (movement.attr('max') && movement.attr('min')) {

		var max = movement.attr('max');
		var min = movement.attr('min');
		percentage = ((mov - min) / (max - min)) * 100;
		movement.attr('percentage', percentage);
	}

	var percentage = movement.attr('percentage');
	$.ajax({
		url: '/manager/watch/setting',
		type: 'POST',
		data: { setting: setting, timestamp: timestamp, movement: mov, component: component, numero: numero, edt: edt, chip_id: chip_id, percentage: percentage },
		success: function(response) {
			movement.closest('.embedded_container').html($(response.html).html()).show();
			$('.watch_setting_view[component="' + component + '"][numero="' + numero + '"][setting="' + setting + '"]').text(mov);
			$('.watch_setting[component="' + component + '"][numero="' + numero + '"][setting="' + setting + '"]').val(mov);
		}
	});
});

$(document).on('change', '.watch_input', function() {
	var input = $(this);
	var app = input.val();
	var numero = input.attr('numero');
	var component = input.attr('component');
	var pre_value = input.attr('pre_value');
	var ip = input.attr('ip');
	var edt = input.attr('edt');
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';

	$.ajax({
		url: '/manager/watch/assign',
		type: 'POST',
		data: { timestamp: timestamp, app: app, component: component, numero: numero, edt: edt, ip: ip, pre_value: pre_value, chip_id:chip_id },
		success: function(response) {
			input.attr('pre_value', response.app);
			input.closest('.embedded_container').replaceWith(response.html);
			var button = $('#watch_' + component + '_' + numero);
			if (response.app) {
				button.text(response.formatted_name);
				button.attr('app', response.app);
			}
			else {
				button.text(numero);
				button.attr('app', '');
			}
		}
	});
});

$(document).on('change', '.watch_measures', function() {
	var input = $(this);
	var meas = input.val();
	var edt = input.attr('edt');
	var component = input.attr('component');
	var numero = input.attr('pin');
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	$.ajax({
		url: '/manager/watch/measure',
		type: 'POST',
		data: { measure: meas, edt: edt, component: component, numero: numero, chip_id: chip_id },
		success: function(response) {
			input.closest('.embedded_container').replaceWith(response.html);
		}
	});
});

$(document).on('mouseover mousemove touchmove', 'input.watch_setting[type="range"]', function() {
	var movement = $(this);
	var setting = movement.attr('setting');
	var numero = movement.attr('numero');
	var component = movement.attr('component');
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var mov = movement.val();

	var max = movement.attr('max');
	var min = movement.attr('min');
	var percentage = ((mov - min) / (max - min)) * 100;

	$(this).attr('percentage', percentage);
	$('.watch_setting_view[component="' + component + '"][numero="' + numero + '"][setting="' + setting + '"]').text(mov);
});


$(document).on('click change', '.watch_toggle', function() {
	var b = $(this);
	var app = b.attr('app');
	var component = b.attr('component');
	var state = b.attr('state');
	if (b.is('input')) {
		state = b.val();
	}
	var pin = b.attr('pin');
	var ip = b.attr('ip');
	var timestamp = Date.now();
	var edt = $(this).attr('edt');
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	$.ajax({
		url: '/manager/embedded/toggle',
		type: 'POST',
		data: {
			app: app,
			component: component,
			state: state,
			pin: pin,
			ip: ip,
			timestamp: timestamp,
			edt: edt,
			chip_id: chip_id,
		},
		success: function(response) {
			if (response.formatted_state) {
				b.attr('state', response.state);
				b.text(response.formatted_state);
			}
		}
	});
});

$(document).on('change', '.embedded_setting', function() {	
	var timestamp = Date.now();
	var setting = $(this).attr('setting');
	var chip_id = $(this).attr('chip_id');
	var edt = $(this).attr('edt');
	var value = $(this).val();
	$('#embedded').addClass('disabled');
	if ($(this).attr('type') == 'checkbox') {
		if ($(this).prop('checked') == true) {
			value = 'on';
		} else {
			value = 'off';
		}
	}


	$.ajax({
		url: '/manager/embedded/setting',
		type: 'POST',
		data: { 
			timestamp: timestamp,
			setting: setting,
			value: value,
			edt: edt,
			chip_id: chip_id
		},
		success: function(response) {
			embeddedDevicesOpener()
		}
	});



});


$(document).on('change', '.teletype_appearance', function() {
	var timestamp = Date.now();
	var value = $(this).val();
	var field = $(this).attr('field');
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	$.ajax({
		url: '/manager/teletype/appearance',
		type: 'POST',
		data: {
			timestamp: timestamp,
			field: field,
			value: value, 
			edt: edt,
			chip_id: chip_id
		},
		success: function(response) {
		}
	});
});
$(document).on('click', '#teletype_wifi_update', function() {
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	$.ajax({
		url: '/manager/teletype/wifi_update',
		type: 'POST',
		data: { timestamp: timestamp, edt: edt, chip_id:chip_id },
		success: function(response) {
		}
	});
});

$(document).on('click', '#teletype_usb_update', function() {
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	$.ajax({
		url: '/manager/teletype/wifi_update',
		type: 'GET',
		data: { chip_id: chip_id, timestamp: timestamp, edt: edt },
		success: function(response) {
			var jString = JSON.stringify(response);
			usbSendData(jString);
		}
	});
});

var usb1;
async function usbSendData(string) {
	await navigator.usb.requestDevice({ filters: [] }).then(function(devices) { usb1 = devices });
	await usb1.open();
	await usb1.selectConfiguration(1);
	await usb1.claimInterface(1);
	await usb1.transferOut(0, string);
}


$(document).on('change', '.teletype_wifi_config', function() {
	var field = $(this).attr('field');
	var val = $(this).val();
	var timestamp = Date.now();
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	$.ajax({
		url: '/manager/teletype/wifi_config',
		type: 'POST',
		data: { timestamp: timestamp, field: field, val: val, edt: edt, chip_id: chip_id },
		success: function(response) {
		}
	});
});

$(document).on('click', '.embedded_bt_now_me', function() {
	var timestamp = Date.now();
	var ip = $(this).attr('ip');
	var uuid = $(this).attr('uuid');
	var name = $('#embedded_device_name').val();
	var chip_id = $('#embedded_device_chip_id').val();
	var bt_mac = $(this).attr('bt_mac');
	$.ajax({
		url: '/manager/embedded/bt_now_me',
		type: 'POST',
		data: {
			timestamp: timestamp,
			edt: edt,
			ip: ip,
			chip_id: chip_id,
			name: name,
			uuid: uuid,
			bt_mac: bt_mac
		}
	});
});


$(document).on('click', '.embedded_now_me', function() {
	var timestamp = Date.now();
	var ip = $(this).attr('ip');
	var uuid = $(this).attr('uuid');
	var name = $('#embedded_device_name').val();
	var chip_id = $('#embedded_device_chip_id').val();
	$.ajax({
		url: '/manager/embedded/now_me',
		type: 'POST',
		data: { 
			timestamp: timestamp, 
			edt: edt, 
			ip: ip, 
			chip_id: chip_id, 
			name: name,
			uuid: uuid
		},
		success: function(response) {}
	});
});

$(document).on('click', '.embedded_wigi', function() {
	var ip = $(this).attr('ip');
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	$.ajax({
		url: '/manager/embedded/wigi',
		type: 'GET',
		data: { edt: edt, timestamp: timestamp, ip: ip, chip_id:chip_id },
		success: function(response) {

		}
	});
});

function nowMeSuccess(edt,chip_id) {
	var enm = $('.embedded_now_me');
	var preColour = enm.css('background-color');
	enm.css({'background-color': 'lightgreen'});
	setTimeout(function() {
		enm.css({'background-color': preColour});
	},5000);
}

$(document).on('click', '.embedded_device_query', function() {
	var edt = $(this).attr('edt');
	var chip_id = $(this).attr('chip_id');
	var timestamp = Date.now();
	var info = $('.embedded_device_info[chip_id="' + chip_id + '"]');
	if (info.is(':visible')) {
		info.hide();
	} else {
		$.ajax({
			url: '/manager/embedded/device_query',
			type: 'GET',
			data: { timestamp: timestamp, edt: edt, chip_id: chip_id },
			success: function(response) {
				console.log(response);
				info.html(response.html);
				info.show();
			}
		});
	}
});

$(document).on('click', '.delete_embedded_file', function() {
	var a = $(this);
	var file = $(this).attr('file');
	var edt = $(this).attr('edt');
	var chip_id = $(this).attr('chip_id');
	var timestamp = Date.now();
	var t_uuid = a.closest('tr').attr('t_uuid');
	if (a.attr('armed') == 'yes') {
		a.css({'background-color': bgcolor });
		a.attr('armed', 'no');		
		$.ajax({
			url: '/manager/embedded/files/delete',
			type: 'POST',
			data: { timestamp: timestamp, edt: edt, chip_id: chip_id, file: file },
			success: function(response) {
				$('[t_uuid="' + t_uuid + '"]').remove();
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

$(document).on('click', '#embedded_ota_uploader', function() {
	var a = $(this);
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	if (a.attr('armed') == 'yes') {
		a.css({'background-color': bgcolor });
		a.attr('armed', 'no');		
		$.ajax({
			url: '/manager/embedded/ota_uploader',
			type: 'POST',
			data: { timestamp: timestamp, edt: edt, chip_id: chip_id },
			success: function(response) {
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

// the esp32 boards: first press arms, second press opens the file picker, the
// .bin goes to the manager and the manager pushes it to the board's own /update
$(document).on('click', '#embedded_ota_uploader_wifi', function() {
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		a.css({'background-color': bgcolor });
		a.attr('armed', 'no');
		$('#embedded_ota_file').val('').trigger('click');
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

$(document).on('change', '#embedded_ota_file', function() {
	var file = this.files[0];
	if (!file) {
		return;
	}
	var ip = $('#embedded_ota_uploader_wifi').attr('ip');
	var timestamp = Date.now();
	var data = new FormData();
	data.append('firmware', file);
	data.append('ip', ip);
	data.append('timestamp', timestamp);
	$('#embedded_ota_uploader_wait').show();
	$('#embedded_ota_uploader_fail, #embedded_ota_uploader_success').hide();
	$('#embedded_ota_uploader_percentage').text('0%');
	$.ajax({
		url: '/manager/embedded/ota_uploader_wifi',
		type: 'POST',
		data: data,
		processData: false,
		contentType: false,
		xhr: function() {
			var xhr = new window.XMLHttpRequest();
			xhr.upload.addEventListener('progress', function(e) {
				if (e.lengthComputable) {
					var percent = Math.round(e.loaded / e.total * 100);
					$('#embedded_ota_uploader_percentage').text(percent + '%');
				}
			}, false);
			return xhr;
		},
		success: function(response) {
			$('#embedded_ota_uploader_wait').hide();
			if (response['success'] == 1) {
				$('#embedded_ota_uploader_percentage').text('100%');
				$('#embedded_ota_uploader_success').show();
			}
			else {
				$('#embedded_ota_uploader_percentage').text('');
				$('#embedded_ota_uploader_fail').show();
			}
		},
		error: function() {
			$('#embedded_ota_uploader_wait').hide();
			$('#embedded_ota_uploader_percentage').text('');
			$('#embedded_ota_uploader_fail').show();
		}
	});
});
$(document).on('change', '#teletype_authorization', function() {
	var tauthorization = $(this).val();
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/embedded/tauthorization',
		type: 'POST',
		data: { timestamp: timestamp, tauthorization: tauthorization, edt: edt },
		success: function(response) {
		}
	});
});
$(document).on('click', '#tty_enabled', function() {
	var t = $(this);
	var enabled = t.attr('status');
	var timestamp = Date.now();
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	$.ajax({
		url: '/manager/teletype/enable_tty',
		type: 'POST',
		data: { timestamp: timestamp, enabled: enabled, edt: edt, chip_id: chip_id },
		success: function(response) {
			t.attr('status', response['enabled']);
			if (response['enabled'] == 1) {
				t.text('Disable');
			}
			else {
				t.text('Enable');
			}
		}
	});
});

$(document).on('click', '.embedded_diagram_thumb', function() {
	var uuid = $(this).attr('uuid');
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';

	$.ajax({
		url: '/manager/watch/diagram',
		type: 'GET',
		data: { uuid: uuid, edt: edt, chip_id: chip_id },
		success: function(response) {
			$('#embedded_diagram').html(response.html).show();
			$('#embedded_diagrams_home, #embedded_diagrams_save, #embedded_diagrams_cancel').show();
			$('#embedded_diagrams').hide();
			edtDiagramsReset();
			$('.embedded_diagram_draggable').draggable({
				scroll: false,
				revert: true,
				helper: 'clone',
				start: function(p) {
				},
				stop: function(m,g) {
					var id = m.target.id;
					var uuid = $('#' + id).attr('uuid');
					var w = $('#embedded_diagram_canvas');
					var x = m.originalEvent.clientX;
					var y = m.originalEvent.clientY;
					if (m.originalEvent.targetTouches) {
						x = m.originalEvent.targetTouches[0].clientX;
						y = m.originalEvent.targetTouches[0].clientY;
					}
					x = numeral(x - w.offset().left).value();
					y = numeral(y - w.offset().top).value();
					var xp = x / w.width();
					var yp = y / w.height();
					var canvas = document.getElementById('embedded_diagram_canvas');
					var ctx = canvas.getContext('2d');
					xp = canvas.width * xp - 50;
					yp = canvas.height * yp - 50;
					edtDiagramsComponentPlacer({ 'uuid': uuid, x: xp, y: yp, height: 100, width: 100 });
				}
			});
		}
	});
});

function edtDiagramsComponentPlacer(data) {
	var canvas = document.getElementById('embedded_diagram_canvas');
	var ctx = canvas.getContext('2d');
	var uuid = data['uuid'];
	var xp = data['x'];
	var yp = data['y'];
	var width = data['width'] || 100;
	var height = data['height'] || 100;
	var component = $('.embedded_diagram_component[uuid="' + uuid + '"]');
	var id = component.attr('id');
	var image = $('#' + id).find('.window_icon').attr('src');
	var name = $('#' + id).find('.component_name').text();
	var type = $('#' + id).find('.component_type').text();

	ctx.font = "400 40px Arial";
	ctx.lineWidth = 10;
	ctx.strokeRect(xp, yp, width, height);
	var typeSize = ctx.measureText(type);
	ctx.fillText(type, (xp + (width / 2)) - (typeSize.width / 2), yp + 140);
	var nameSize = ctx.measureText(name);
	ctx.fillText(name, (xp + (width / 2)) - (nameSize.width / 2), yp - 20);
	var img = new Image;
	img.onload = function(){
		ctx.drawImage(img,xp,yp, width, height);
	};
	img.src = image;
	edt_diagrams.components.push({ 'uuid': uuid, x: xp, y: yp, height: height, width: width });
}

$(document).on('click', '#embedded_diagrams_home', function() {
	$('#embedded_diagram,#embedded_diagrams_home,#embedded_diagrams_save,#embedded_diagrams_cancel').hide();
	$('#embedded_diagrams').show();
});

$(document).on('click', '#embedded_diagrams_cancel', function() {
	edtDiagramsReset('reset');
});

function edtDiagramsReset(type) {
	var canvas = document.getElementById('embedded_diagram_canvas');
	var c = $('#embedded_diagram_canvas');
	var i = $('#embedded_diagram_image');

	var info = JSON.parse($('#embedded_diagram_info').text());
	if (type == 'reset') {
		info.components = [];
		edt_diagrams = { components: info.components || [], file: info };
	}
	canvas.width = info.info.width;
	canvas.height = info.info.height;
	c.width(i.width());
	var iv = document.getElementById('embedded_diagram_image');
	var image = new Image();
	image.onload=function(){
		canvas.getContext('2d').drawImage(image,0,0,canvas.width, canvas.height);
		$.each(info.components, function(i,v) {
			edtDiagramsComponentPlacer(v);
		});



	};
	image.src = iv.src;
	i.hide();
	c.show();
}

$(document).on('click', '#embedded_diagrams_save', function() {
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var jedt_diagrams = JSON.stringify(edt_diagrams);
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/watch/diagram',
		type: 'POST',
		data: {
			edt: edt,
			chip_id: chip_id,
			diagram: jedt_diagrams,
			timestamp: timestamp
		},
		success: function(response) {
		}
	});
});


















