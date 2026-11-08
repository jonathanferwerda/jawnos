/* [[js-split]]
   embedded.js is part 1. The rest live in embedded/ in name order:
     01_ota_nowme.js - nowMe push - device query - OTA and USB flashing - audio replies - TTY - diagrams
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
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
			// the panel is in the page now, so the scan has somewhere to write
			embeddedWifiScan();
		}
	});
}

// The rendered picker wins over the remembered one: after a redraw the select
// is the device the person is actually looking at.
function embeddedChipId() {
	return $('#embedded_device_chip_id').val() || localStorage.getItem('embedded_chip_id') || '';
}

$(document).on('click', '.embedded_detail', function() {
	var numero = $(this).attr('numero');
	var form = $(this).attr('form');
	var pin = $(this).attr('pin');
	// Put the form in a full-width row under the pin that was pressed, not at
	// the bottom of the panel where it is below the fold and looks like nothing
	// happened.
	embeddedDetailGrabber({ numero: numero, form: form, pin: pin },
		{ target: $(this).closest('tr'), mode: 'after' });
});

// An empty GPIO in a board's GPIO view is a compact +N button. Pressing it
// fetches that one pin's form and replaces the button in place, so the form is
// where the person pressed - the panel no longer draws every empty slot in full.
$(document).on('click', '.watch_empty', function() {
	var b = $(this);
	embeddedDetailGrabber({ numero: b.attr('numero'), pin: b.attr('pin'), component: b.attr('component') },
		{ target: b.closest('.embedded_container'), mode: 'replace' });
});

function embeddedDetailGrabber(data, place) {
	var timestamp = Date.now();
	var numero = data['numero'];
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = localStorage.getItem('embedded_chip_id') || '';
	var view = localStorage.getItem('embedded_view');
	var form = data['form'];
	var pin = data['pin'];
	var component = data['component'] || '';
	$.ajax({
		url: '/manager/embedded/pin_grabber',
		type: 'GET',
		data: { 
			numero: numero, 
			edt: edt, 
			chip_id: chip_id, 
			view: view, 
			form: form,
			component: component,
			timestamp: timestamp,
			pin: pin
		},
		success: function(response) {
			var form = $(response.html);
			if (!form.length) { return; }
			var mode = place && place.mode;
			var target = place && place.target;
			if (mode == 'replace' && target && target.length) {
				target.replaceWith(form);
			}
			else if (mode == 'after' && target && target.length) {
				var row = $('<tr class="embedded_detail_form"><td colspan="4"></td></tr>');
				row.find('td').html(form);
				target.after(row);
			}
			else {
				$('#embedded').append(form);
			}
			var input = form.find('.watch_input').first();
			if (input.length) {
				input.trigger('focus');
				if (input[0].scrollIntoView) { input[0].scrollIntoView({ block: 'nearest' }); }
			}
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

$(document).on('click', '.embedded_usb_provision', function() {
	// A board that is on the desk in its provisioning AP cannot be reached over
	// the LAN. Its USB CDC link can: the manager writes the stored WiFi and role
	// into config.txt, and the board reboots onto the house with its pins set.
	var t = $(this);
	var chip_id = t.attr('chip_id');
	var edt = t.attr('edt') || 'microcontroller';
	var out = $('#embedded_usb_provision_result');
	out.text('Writing the stored WiFi and role over USB...').show();
	$.ajax({
		url: '/manager/embedded/usb_provision',
		type: 'POST',
		data: { chip_id: chip_id, edt: edt },
		success: function(response) {
			if (response && response.ok) {
				out.text('Written to ' + response.port + ' (' + response.bytes + ' bytes); the board is rebooting.').show();
			}
			else {
				out.text('USB restore failed: ' + ((response && response.error) || 'unknown')).show();
			}
		},
		error: function(xhr) {
			out.text('USB restore failed: HTTP ' + xhr.status).show();
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
			// An empty GPIO opened its form from outside the board's button list
			// (the +N button, or a pin on the Pins view). Once it names an app,
			// redraw so the now-wired pin joins its type instead of sitting in a
			// form at the bottom of the panel.
			if (!input.closest('#watch_buttons').length) {
				embeddedDevicesOpener();
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
	var el = this;
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
			// a setting that says what the device should do now (the voice mode)
			// carries push="now_me": the save is written first, then a fresh Now Me
			// is sent so the watch picks it up at once rather than on its next poll
			if ($(el).attr('push')) { embeddedNowMePush(); }
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
// The Networks app already scans the manager's own radio; reuse that answer
// rather than adding a second scan path for the embedded panel.
function embeddedWifiText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}
function embeddedWifiScan() {
	var list = $('#teletype_wifi_ssids');
	if (!list.length || list.children().length) { return; }
	$('#teletype_wifi_result').text(embeddedWifiText('Scanning for networks...'));
	$.ajax({
		url: '/manager/network/wifi_scan',
		type: 'POST',
		dataType: 'json',
		data: {}
	}).done(function(response) {
		var networks = (response && response.networks) || [];
		// A datalist does not open on its own in every engine this desktop runs
		// on, so the scan also draws each network as a button: press one and the
		// name is filled in (and saved) without typing it - which is how a space
		// in a network name gets lost.
		var picks = $('#teletype_wifi_picks').empty();
		var seen = 0;
		for (var i = 0; i < networks.length; i++) {
			var ssid = networks[i] && networks[i].ssid;
			if (!ssid) { continue; }
			list.append($('<option>').attr('value', ssid));
			picks.append($('<button>').addClass('teletype_wifi_pick')
				.attr('data-ssid', ssid)
				.css({ 'margin': '2px 6px 2px 0', 'font-size': '15px' })
				.text(ssid));
			seen++;
		}
		$('#teletype_wifi_result').text(seen
			? seen + ' ' + embeddedWifiText('network(s) found; type a name or pick one')
			: embeddedWifiText('No networks found; type the name instead.'));
	}).fail(function() {
		// A failed scan leaves the stored name typable; saving is never blocked.
		$('#teletype_wifi_result').text(embeddedWifiText('Scan failed; type the name instead.'));
	});
}

$(document).on('click', '#teletype_wifi_scan', function() {
	$('#teletype_wifi_ssids').empty();
	$('#teletype_wifi_picks').empty();
	embeddedWifiScan();
});

// Picking a scanned network fills the name in and saves it, exactly as typing it
// would; the password stays a separate field.
$(document).on('click', '.teletype_wifi_pick', function() {
	var ssid = $(this).attr('data-ssid');
	$('#teletype_wifi_ssid').val(ssid).trigger('change');
	$('#teletype_wifi_result').text(embeddedWifiText('Chosen') + ': ' + ssid);
});

$(document).on('click', '#teletype_wifi_update', function() {
	var timestamp = Date.now();
	var chip_id = embeddedChipId();
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	$.ajax({
		url: '/manager/teletype/wifi_update',
		type: 'POST',
		data: { timestamp: timestamp, edt: edt, chip_id:chip_id },
		success: function(response) {
			var text = (typeof response === 'string') ? response : ((response && response.error) || 'sent');
			$('#teletype_wifi_result').text(text);
		},
		error: function(xhr) {
			var why = (xhr && (xhr.responseText || xhr.statusText)) || '';
			$('#teletype_wifi_result').text(embeddedWifiText('Update failed') + (why ? ': ' + why : ''));
		}
	});
});

$(document).on('click', '#teletype_usb_update', function() {
	var timestamp = Date.now();
	var chip_id = embeddedChipId();
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
	// a password field shows only that it is set; an empty value means "leave it"
	if (/password/.test(field) && !val) { return; }
	var timestamp = Date.now();
	var edt = localStorage.getItem('embedded_device_type') || 'watch';
	var chip_id = embeddedChipId();
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


