var global_constraints = { 'video': false, 'audio': false };
var configIntervals = { 'sysEvaluateInterval': '', 'sysEvaluateTimeout' : '' };

async function configureToggle() {
	var cb = $('#configure_balloon');
	if (cb.is(':visible')) {
		cb.hide();
	}
	else if (cb.find('#configure').length > 0) {
		cb.show();
	}
	else {
		var browser_tab_id = sessionStorage.getItem('browser_tab_id');
		var browser_tab = localStorage.getItem('browser_tab');
		$.ajax({
			url: '/manager/configure',
			type: 'GET',
			data: { 
				browser_tab_id: browser_tab_id,
				browser_tab: browser_tab
			},
			success: function(response) {
				//cb.show();
				//cb_check = 1;
				//cb.html(response);
				windowMaker(response);
				initializer();
			
				$('.media_picker').each(function(i,vd) {
					var v = $(vd);
					var type = v.attr('type');
					var kind = v.attr('kind');
					var device_id = v.attr('device_id');
					var mp = localStorage.getItem(type + device_id);
					if (mp == 'on') { v.attr('selected', 'on'); v.css({'background-color': 'green'}); }
				});
			}, error: function(response) { console.log(response); }
			
		});


	}
}

$(document).on('change', '.appointment_setting', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	if ($(this).is('select')) {
		value = JSON.stringify(value);
	}
	else if ($(this).attr('type') == 'checkbox') {
		if ($(this).prop('checked') == true) {
			value = 'on';
		}
		else {
			value == 'off';
		}
	}
	var app = $(this).attr('app') || $(this).closest('.appointment').attr('app') || $(this).closest('.wind').attr('app');
	var setter = { 'app': app, 'setting': setting, 'value': value };
	settingSetter(setter);
});

$(document).on('click', '.permission_asker', function() {
	permissionAsker();
});

async function permissionAsker(kind) {
	if (kind == 'location' || !kind) {

		navigator.geolocation.getCurrentPosition((position) => {

		});
	}
	if (kind == 'media' || !kind) {
		var constraints = await constraintMaker();
		var av = await navigator.mediaDevices.enumerateDevices();
		var avData = JSON.stringify(av);

		$.ajax({
			url: '/manager/configure/permissions',
			type: 'POST',
			data: {
				avData: avData,
				constraints: constraints
			}
		});
	}
	if (kind == 'notifications' || !kind) {
		Notification.requestPermission().then((result) => {

		});
	}
	if ((kind == 'nfc' || !kind) && 'NDEFReader' in window) {
		nfc = {
			scanning: false,
			writing: false,
			abort: new AbortController(),
			initialized: false
		};
		nfc['ndef'] = new NDEFReader();
		nfcInitializer();
		nfcListener();
	}
	if (kind == 'usb' || !kind) {
		navigator.usb.requestDevice({ filters: [] }).then(function(devices) { console.log(devices); });
	}

}


function numericals() {
	numerics = "";
	if ($('#ticket').is(':visible')) {
		numerics = "";
		$('#ticket').find('.ticket_input').each(function() {
			numerics = numerics + $(this).val();
		});
	}
	return numerics;
}

$(document).on('click', '#password_clear', function() {
	$('#credential_insert').val('');
	$('#ticket').find('.ticket_input').each(function() {
		$(this).val('');
	});
});

$(document).on('click','.delete_backup', function() {
	var a = $(this);
	var timestamp = Date.now();
	var filename = a.attr('filename');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		if (filename) {
			$.ajax({
				url: '/manager/configure/delete_backup',
				type: 'POST',
				data: { timestamp: timestamp, filename: filename },
				success:function(response) {
					if (response == 'backup deleted') {
						a.closest('.backup').remove();
					}
				}
			});
		}
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

$(document).on('change', '.pos, .mab', function(e) {
	var d = $(this);
	var setting = d.attr('setting');
	var parent = d.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var a = d.attr('app');
	var o = e.currentTarget.selectedOptions[0];
	o = $(o).val();
	var now = Date.now();
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { timestamp: now, app: a, setting: setting, value: o },
		success: function(response) { display.html(response); }
	});
});
$(document).on('change', '.configure_checkbox', function(e) {
	var d = $(this);
	var parent = d.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var a = d.attr('app');
	var now = Date.now();
	var setting = d.attr('setting');
	if (d.is(':checked')) { value = "checked"; } else { value = "unchecked"; }
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: a, timestamp: timestamp, setting: setting, value: value },
		success: function(response) { 
			display.html(response); 
			localStorage.removeItem('manager_search_cache');
		}
	});
});
$(document).on('change', '.configure_input', function(e) {
	var e = $(this);
	url = '/manager/configure';
	var setting = e.attr('setting');
	var app = e.attr('app');
	var button = $('.app_configure_toggle[setting="' + setting + '"][app="' + app + '"]');
	var value = e.val();
	if (e.attr('type') == 'checkbox') {
		value = e.prop('checked') ? 'on' : 'off';
	}
	var parent = e.closest('.appointment_configuration_cell');
	var display = parent.find('.appointment_display');
	var timestamp = Date.now();
	if (e.attr('multiple')) {
		value = JSON.stringify(value);
	}
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: app, timestamp: timestamp, setting: setting, value: value },
		success: function(response) {
			display.html(response);
			localStorage.removeItem('manager_search_cache');
			button.html('<b>' + button.attr('formatted_setting') + ':</b> ' + value.slice(0,20));
			configurationGrabber({ app: app, setting: [setting] });
		}
	});
});

$(document).on('click', '.app_measure_configuration_adder', function() {
	var app = $(this).attr('app');
	var amc = $(this);
	var button = $('.app_configure_toggle[setting="measures"][app="' + app + '"]');
	var appmc = amc.closest('.app_measures_configurator');
	$.ajax({
		url: '/manager/configure/app_measure_configuration_adder',
		type: 'POST',
		data: { app: app },
		success: function(response) {
			button.html('<b>' + button.attr('formatted_setting') + ':</b> ' + response.header.slice(0,20));
			var ta = appmc.find('.configure_input[setting="app_measures"]');
			appmc.html(response.config);
			$('.re_measures[app="' + app + '"]').html(response.app_measure);
			configurationGrabber({ app: app, setting: ['measures'] });
		}
	});
});

$(document).on('click', '.app_measure_configuration_name', function() {
	var name = $(this).attr('name');
	var container = $(this).closest('.app_measures_configurator');
	var app = container.attr('app');
	var name_change = container.find('.app_measure_configuration[setting="measure"][oldvalue="' + name +'"]');
	if (name_change.is(':visible')) {
		name_change.hide();
	}
	else {
		name_change.show();
	}
	configurationGrabber({ app: app, setting: ['measures'] });
});

$(document).on('change', '.app_measure_configuration', function() {
	var amc = $(this);

	var app = amc.closest('.appointment').attr('app');
	var amcc = amc.closest('.app_measure_configuration_container');
	var appmc = amc.closest('.app_measures_configurator');
	var measure = amcc.attr('measure');
	var oldvalue = amc.attr('oldvalue');
	var setting = amc.attr('setting');
	var value = amc.val();
	var timestamp = Date.now();
	var button = $('.app_configure_toggle[setting="measures"][app="' + app + '"]');

	$.ajax({
		url: '/manager/configure/app_measure_configurator',
		type: 'POST',
		data: { app: app, setting: setting, value: value, measure: measure, oldvalue: oldvalue },
		success: function(response) {
			button.html('<b>' + button.attr('formatted_setting') + ':</b> ' + response.header.slice(0,20));
			var ta = appmc.find('.configure_input[setting="app_measures"]');
			ta.val(response.header);
			appmc.html(response.config);

			$('.re_measures[app="' + app + '"]').html(response.app_measure);
			configurationGrabber({ app: app, setting: ['measures'] });
		}
	});
});

$(document).on('change', '.app_measure_configuration_matcher', function() {
	var amcm = $(this);
	var amcmc = amcm.closest('.app_measure_configuration_matcher_container');
	var amcc = amcm.closest('.app_measure_configuration_container');
	var app = amcc.attr('app');
	var measure = amcc.attr('measure');
	var uuid = amcmc.attr('uuid');
	var value = amcm.val();
	var setting = amcm.attr('setting');
	var data = { app: app, measure: measure, uuid: uuid, setting: setting, value: value };
	$.ajax({
		url: '/manager/configuration/app_measure_configuration_matcher',
		type: 'POST',
		data: data,
		success: function(response) {
			amcmc.attr('uuid',  response.uuid);
			configurationGrabber({ app: app, setting: ['measures'] });
		}
	});

});

$(document).on('click', '.web_measure_delete', function() {
	var a = $(this);
	var app = a.attr('app');
	var measure = a.attr('measure');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/web/measure/delete',
			type: 'POST',
			data: { app: app, measure: measure },
			success: function(response) {
				a.closest('tr').remove();
			configurationGrabber({ app: app, setting: ['measures','web'] });
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

$(document).on('change', '.packaging_config', function() {
	var uuid = $(this).closest('.packaging_config_container').attr('uuid');
	var name = $(this).attr('name');
	var value = $(this).val();
	var app = $(this).closest('.appointment').attr('app');
	var timestamp = Date.now();
	var selector = selectorMaker(this);
	$.ajax({
		url: '/manager/configure/packaging/save',
		type: 'POST',
		data: { app: app, name: name, uuid: uuid, value: value, timestamp: timestamp },
		success: function(response) {
			$('.app_packaging_configurator[app="' + app + '"]').html(response.html);
			$(selector).focus();
			configurationGrabber({ app: app, setting: ['packaging'] });
		}
	});
});

$(document).on('click', '.delete_packaging', function() {
	var uuid = $(this).attr('uuid');
	var app = $(this).closest('.appointment').attr('app');
	$.ajax({
		url: '/manager/configure/packaging/delete',
		type: 'POST',
		data: { app: app, uuid: uuid },
		success: function(response) {
			$('.app_packaging_configurator[app="' + app + '"]').html(response.html);
			configurationGrabber({ app: app, setting: ['packaging'] });
		}
	});
});

$(document).on('click', '#device_lister, .device_scan', function() {
	var b = $(this);
	var load_type = b.attr('load_type');
	var text = b.text();
	var host = $('.ping_host').val();
	if (b.hasClass('ping_scan')) {
		host = b.attr('ip_address');
	}
	b.text('* ' + text);
	var c = $('#device_list');
	if (c.is(':visible') && load_type == 'list') {
		b.text('Dev');
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		var timestamp = Date.now();
		var ping = $('#ping_results').html();
		$.ajax({
			url: '/manager/configure/device_lister',
			type: 'GET',
			data: { timestamp: timestamp, load_type: load_type, host: host },
			success: function(response) {
				$('#device_list').html(response).show();

				$('#ping_results').html(ping);
				b.attr('status', 'active');
				b.text(text);
				$('.remote_restore_list').each(function(i,v) {
					var r = $(v);
					if (r.html() != '' && r.html() != undefined) {
						if (eval(JSON.parse(r.html() || '[]'))) {
							var neighbour = JSON.parse(r.html() || '[]');
							$(v).html('');
							$.each(neighbour, function(i,val) {
								if (val['archive'] != 'archive') {
									if (neighbour['verified'] == true) {
										$(v).append('<button class="neighbour_filepicker" filename="' + val['filename'] + '">Connected' + val['filename'] + '</button>');
										$(v).append('<button class="neighbour_filepicker" filename="' + val['filename'] + '">Connect</button>');
									}
									else {
										$(v).append('<button class="neighbour_filepicker" filename="' + val['filename'] + '">' + val['filename'] + '</button>');
									}
								}
							});
						}
					}
				});
			}
		});
	}
});

$(document).on('click', '#tunnel_lister', function() {
	var b = $(this);
	var timestamp = Date.now();
	var c = $('#tunnel_list');

	if (c.is(':visible')) {
		b.text('Tun');
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		b.text('* Tun');
		b.text('Tun');
		c.show();
		tunnelLister('open');
		b.attr('status', 'active');	
	}
});

function tunnelLister(b) {
	//if (b == 'open' || $('#tunnel_list').is(':visible')) {
		$.ajax({
			url: '/manager/configure/tunnel/list',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				$('#tunnel_list').html(response.html);

			}
		});
	//}
}

$(document).on('click', '#pseudonym_setting_lister', function() {
	var timestamp = Date.now();
	var b = $(this);
	var c = $('#pseudonym_list');
	if (c.is(':visible')) {
		b.text('Pseud');
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		b.text('* Pseud');
		$.ajax({
			url: '/manager/configure/pseudonym_list',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				c.html(response);
				b.text('Pseud');
				c.show();
				b.attr('status', 'active');
			}
		});
	}
});

$(document).on('change', '.pseudonym_setting', function() {
	var b = $(this);
	var timestamp = Date.now();
	var setting = b.attr('setting');
	var value = b.val();
	var name = b.closest('tr').attr('pseudonym_name');
	var p = 
	$.ajax({
		url: '/manager/configure/pseudonym_setter',
		type: 'POST',
		data: { setting: setting, value: value, name: name, timestamp: timestamp },
		success: function(response) {
			$('#pseudonym_list').html(response);
			if (setting == 'status') {
				var p = $('.pseudonym.keyboard[toggle="' + name + '"');
				localStorage.setItem('pseudonym_keyboard_' + name, value);
				if (value == 'on') {
					p.show();
				}
				else if (value == 'button') {

				}
				else if (value == 'off') {
					p.hide();
				}
			}
		}
	});
});

$(document).on('click', '.pseudonym_icon_set', function() {
	var set = $(this);
	var name = set.attr('name');
	if ($('#whiteboard').is(':visible')) {
		$('#alert_message').html('Are you sure you want to change the pseudonym: ' + name + '\'s icon?<br><br>' +
			'<button pseudonym_name="' + name + '" id="pseudonym_icon_change_submit">Submit</button><button id="alert_cancel">Cancel</button>'
		);
		$('#alert').show();
	}
});

$(document).on('click', '#pseudonym_icon_change_submit',function() {
	var submit = $(this);
	var timestamp = Date.now();
	if ($('#whiteboard').is(':visible')) {
		var canvas = document.getElementById('whiteboard');
		var img = canvas.toDataURL('image/png');
		var name = submit.attr('pseudonym_name');
		var prev_img = $('.pseudonym_icon_set[name="' + name + '"]').attr('src');
		$.ajax({
			url: '/manager/configure/pseudonym_icon_changer',
			type: 'POST',
			data: { timestamp: timestamp, image: img, name: name },
			success: function(response) {
				$('#pseudonym_list').html(response.list);
				$('[name="' + name + '"][src="' + prev_img + '"]').attr('src',img);
				$('#alert').hide();
			}
		});
	}
});

$(document).on('click', '.pseudonym_defaulter', function() {
	var name = $(this).attr('name');
	var prev_img = $('.pseudonym_icon_set[name="' + name + '"]').attr('src');
	$.ajax({
		url: '/manager/configure/pseudonym_defaulter',
		type: 'GET',
		data: { name: name },
		success: function(response) {
			$('#pseudonym_list').html(response);
			var now_img = $('.pseudonym_icon_set[name="' + name + '"]').attr('src');
			$('[name="' + name + '"][src="' + prev_img + '"]').attr('src',now_img);
		}
	});
});

$(document).on('click', '#store_setting_lister', function() {
	var timestamp = Date.now();
	var b = $(this);
	var c = $('#store_list');
	if (c.is(':visible')) {
		b.text('Store');
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		b.text('* Store');
		$.ajax({
			url: '/manager/configure/store_list',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				c.html(response);
				b.text('Store');
				c.show();
				b.attr('status', 'active');
			}
		});
	}
});


$(document).on('change', '.device_purpose', function() {
	var purpose = $(this);
	var new_purpose = purpose.val();
	var timestamp = Date.now();
	var device = purpose.closest('.device');
	var ip = purpose.closest('.remote_machine').attr('ip');
	var mac = purpose.closest('.remote_machine').attr('mac');
	var uuid = device.attr('uuid');
	var network_interface = purpose.closest('.network_interface');
	$.ajax({
		url: '/manager/configure/device_purpose',
		type: 'POST',
		data: {
			timestamp: timestamp,
			uuid: uuid,
			ip: ip,
			mac: mac,
			purpose: new_purpose
		},
		success: function(response) {

		}
	});

});

$(document).on('click', '.ping', function() {
	var ping = $(this);
	var ipC = ping.prev();
	var host = ipC.val();
	var timestamp = Date.now();
	ping.text('pinging');
	$.ajax({
		url: '/manager/configure/ping',
		type: 'GET',
		data: {
			host: host,
			timestamp: timestamp
		},
		success: function(response) {
			$('#ping_results').html(response);
			ping.text('ping');
		}
	});
});

$(document).on('click', '.neighbour_disconnect', function() {
	var rd = $(this);
	var ip = rd.attr('ip');
	var signatorial = rd.attr('signatorial');
	var timestamp = Date.now();
	
	if (rd.attr('armed') == 'yes') {

		$.ajax({
			url: '/manager/configure/remote_device_disconnect',
			type: 'POST',
			data: { ip: ip, timestamp: timestamp, signatorial: signatorial },
			success: function(response) {
				rd.closest('.remote_machine_buttons').html('');
			}
		});
	}
	else {
		rd.attr('armed', 'yes');
		var bgcolor = rd.css('background-color');
		rd.css({'background-color': 'red' });
		setTimeout(function() {
			rd.css({'background-color': bgcolor });
			rd.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click', '.neighbour_tunnel', function() {
	var nt = $(this);
	var ssh_port = nt.attr('ssh_port');
	var ip = nt.attr('ip');
	var signatorial = nt.attr('signatorial');
	var uuid = nt.attr('uuid');
	var status = nt.attr('status');
	var nic = nt.attr('nic');
	$.ajax({
		url: '/manager/configure/remote_machine/tunnel/toggle',
		type: 'POST',
		data: { 
			ssh_port: ssh_port,
			ip: ip,
			signatorial: signatorial,
			uuid: uuid,
			status: status,
			nic: nic
		},
		success: function(response) {
			nt.attr('status', response.tunnel);

		}
	});


});

$(document).on('click', '.neighbour_refresh', function() {
	var bti = $(this).attr('bti');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/remote_refresh',
		type: 'GET',
		data: { 'bti': bti, 'timestamp': timestamp },
		success: function(response) {

		}
	});
});

$(document).on('click', '.teletype_backup', function() {
	var ip = $(this).attr('ip');
	var mac = $(this).attr('mac');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/embedded/teletype_backup',
		type: 'GET',
		data: { ip: ip, mac: mac, timestamp: timestamp },
		success: function(response) {

		}
	});
});

$(document).on('click', '.remote_rsync', function() {
	var r = $(this);
	var ip = r.attr('ip');
	var ssh_port = r.attr('ssh_port');
	var remote_device = r.attr('device');
	var hostname = r.attr('hostname');
	var direction = r.attr('direction');
	var uuid = r.attr('uuid');
	var signatorial = r.attr('signatorial');
	var home = r.attr('home');
	$.ajax({
		url: '/manager/configure/remote_rsync',
		type: 'POST',
		data: { 
			timestamp: timestamp, 
			ip: ip, 
			direction: direction, 
			ssh_port: ssh_port, 
			home: home,
			signatorial: signatorial,
			uuid: uuid
		 },
		success: function(response) {
			r.closest('.network_interface').prepend('<br>Me: ' + response);
		}
	});
});

$(document).on('click', '.remote_upgrade_clear', function() {
	settingSetter({ 'app': '__president', 'setting': 'remote_upgrade', 'value': 'inactive' });
});

$(document).on('click', '.remote_upgrade', function() {
	var r = $(this);
	var ip = r.attr('ip');
	var ssh_port = r.attr('ssh_port');
	var remote_device = r.attr('device');
	var hostname = r.attr('hostname');
	var device = r.closest('.device');
	var database = r.attr('database');
	var signatorial = r.attr('signatorial');
	var uuid = r.attr('uuid');
	var gimme = $('.gimme_input[name="gimme"][signatorial="' + signatorial + '"][uuid="' + uuid + '"]').val();
	$.ajax({
		url: '/manager/configure/remote_upgrade',
		type: 'POST',
		data: { 
			timestamp: timestamp, 
			ip: ip, 
			ssh_port: ssh_port, 
			device: remote_device, 
			hostname: hostname,
			database: database,
			signatorial: signatorial,
			uuid: uuid,
			gimme: gimme
		},
		success: function(response) {
			$('.gimme_input[name="gimme"][signatorial="' + signatorial + '"][uuid="' + uuid + '"]').val('');
			r.closest('.network_interface').append('<br>Me: ' + response);
		}
	});
});

$(document).on('change', '.remote_machine_input', function() {
	var input = $(this);
	var timestamp = Date.now();
	var signatorial = input.attr('signatorial');
	var uuid = input.attr('uuid');
	var ip = input.attr('ip');
	var value = input.val();
	var name = input.attr('name');

	$.ajax({
		url: '/manager/configure/remote_machine_input',
		type: 'POST',
		data: { 
			timestamp: timestamp,
			signatorial: signatorial,
			ip: ip,
			value: value,
			uuid: uuid,
			name: name
		},
		success: function(response) {
			input.css({ 'background-color': 'lightgreen' });
			setTimeout(function() {
				input.css({ 'background-color': 'white' });
			},2000);
		}
	});
});

$(document).on('click', '.remote_device_locker', function() {
	var locker = $(this);
	var timestamp = Date.now();
	var uuid = locker.attr('uuid');
	var ip = locker.attr('ip');
	var status = locker.attr('status');
	var nic = locker.attr('nic');
	$.ajax({
		url: '/manager/configure/remote_device_locker',
		type: 'POST',
		data: { uuid: uuid, ip: ip, status: status, nic: nic, timestamp: timestamp },
		success: function(response) {
			locker.attr('status', response.locked);
			if (response.locked == 'yes') {
				locker.attr('src', '/images/jbuttons/padlock lock.png');
				locker.css({ 'background-color': 'red' });
			}
			else {
				locker.attr('src', '/images/jbuttons/padlock unlock.png');
				locker.css({ 'background-color': 'lightgreen' });
			}
		}
	});
});

$(document).on('click', '.neighbour_filepicker', function() {
	var chosen = $(this);
	var filename = chosen.attr('filename');
	var manager = chosen.closest('.remote_restore_list').attr('manager');
	var tunnel = chosen.closest('.remote_machine').attr('tunnel');
	var timestamp = chosen.closest('.device').attr('timestamp');
	var ip = chosen.closest('.remote_machine').attr('ip');
	var port = chosen.closest('.remote_machine').attr('port');
	var signatorial = chosen.closest('.remote_machine').attr('signatorial');
	var nic = chosen.closest('.network_interface').attr('nic');
	var uuid = chosen.closest('.device').attr('uuid');
	var websockets = [];
	$.each(ws, function(i,v) { websockets.push(i) });
	var json_websockets = JSON.stringify(websockets);
	chosen.closest('.device').find('.device_president').val(filename).trigger('change');
	$.ajax({
		url: '/manager/configure/remote_device_connect',
		type: 'GET',
		data: { 
			manager: manager,
			filename: filename,
			timestamp: timestamp,
			signatorial: signatorial,
			port: port,
			ip: ip,
			websockets: 
			json_websockets,
			nic: nic,
			uuid: uuid,
			tunnel: tunnel
		},
		success: function(update) {

			chosen.text(update['status']);
			if (update['body']['authentication'] == 'approved') {
				chosen.closest('.remote_machine').find('.remote_machine_buttons').html(update['button'])
				var sw = chosen.closest('.device').find('.machine_name');
				chosen.closest('.remote_machine').find('.device_purpose').val(update['body']['device']);
//				sw.val(update['body']['me'][update['body'][device]]['my_name']).trigger('change');
				if (update['colour']) {
					sw.css({'background-color': update['colour'] });
				}
				setTimeout(function() {
					sw.css({'background-color': 'white' });
				},500);
			}
		},
		error: function(e) { console.log(e); }
	});
});

$(document).on('click', '#misc_setting', function() {
	var b = $(this);
	if (!$('#misc_setting_list').is(':visible')) {
		var timestamp = Date.now();
		$.ajax({
			url: '/manager/configure/misc_setting_list',
			type:'GET',
			data: { timestamp: timestamp },
			success: function(response){
				$('#misc_setting_list').html(response).show();
				b.attr('status', 'active');
			}
		});
	}
	else {
		$('#misc_setting_list').hide();
		b.attr('status', 'inactive');
	}
});

$(document).on('change','.misc_setting', function() {
	var timestamp = Date.now();
	var set = $(this);
	var setting = set.attr('setting');
	var object = set.attr('object');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="misc"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.misc_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/misc_setting',
		type: 'POST',
		data: { timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
			$.each(response, function(i,v) {
				if (v.setting == 'manager_background_colour' && dev == v.device) {
					$('body').css({'background-color':v.value});
					if (typeof jawnosApplyInk == 'function') { jawnosApplyInk(); }
				}
				if (v.setting == 'configure_background_colour' && dev == v.device) {
					$('#configure').css({'background-color': v.value});
				}
				if (v.setting == 'title_font' && dev == v.device) {
					$('.title_font').css({'font-family': v.value});
				}
				if ($('#' + object)) {
					$('#' + object).css({'background-color': value});
				}
				if ($('.' + object).length > 0) {
					$('.' + object).css({'background-color': value});
				}
				$('.misc_setting[device="' + v.device + '"][setting="' + v.setting + '"]').val(v.value);
			});
		}

	});

});

$(document).on('change','.sys_setting', function() {
	var timestamp = Date.now();
	var set = $(this);
	var setting = set.attr('setting');
	var object = set.attr('object');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="sys"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.misc_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/sys_setting',
		type: 'POST',
		data: { timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
		}
	});
});

$(document).on('change', '.utility_controller', function() {
	var b = $(this);
	var control = b.attr('control');
	var device = b.attr('device');
	var setting = b.attr('setting');
	var value = b.val();

	if (b.attr('type') == 'checkbox') {
		if (b.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}
	$.ajax({
		url: '/manager/configure/utility_controller/save',
		type: 'POST',
		data: { control: control, device: device, value: value, setting: setting },
		success: function(response) {
			$('#utility_controls_container').html(response.html);
		}
	});
});

function utilityControllerReloader() {
	$.ajax({
		url: '/manager/configure/utility_controller',
		type: 'GET',
		data: {  },
		success: function(response) {
			$('#utility_controls_container').html(response.html);
			appointment_chron();
		}
	});
}


$(document).on('change', '.device_domain', function() {
	var b = $(this);
	var timestamp = b.attr('timestamp');
	var domain = b.val();
	var device = b.attr('device');
	var address = b.attr('address');
	var uuid = b.attr('uuid');
	$.ajax({
		url: '/manager/configure/device_domain_updater',
		type: 'POST',
		data: { 
			device: device,
			domain: domain,
			timestamp: timestamp, 
			uuid: uuid
		}
	});
});

$(document).on('click','.delete_device', function() {
	var a = $(this);
	var device = a.attr('device');
	var timestamp = a.attr('timestamp');
	var uuid = a.attr('uuid');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/configure/device_deleter',
			type: 'POST',
			data: { device: device, timestamp: timestamp, uuid: uuid },
			success:function(response) {
				$('.device[uuid="' + uuid + '"]').remove();
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

$(document).on('click', '.delete_neighbour_device', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var rm = a.closest('.remote_machine');
	var rm_uuid = a.attr('rm_uuid');
	var device = a.closest('.device');
	var device_uuid = device.attr('uuid');

	if (a.attr('armed') == 'yes') {
		a.attr('armed','pending');
		$.ajax({ 
			url: '/manager/configure/device/neighbour_delete',
			data: { device_uuid: device_uuid, uuid: uuid, rm_uuid: rm_uuid },
			type: 'POST',
			success: function(response) {
				rm.remove();
				a.css({'background-color': 'lightgreen' });
				setTimeout(function() {
					a.attr('armed', 'no');
					var obg = a.attr('obg');
					a.css({'background-color': obg });
				},2000);
			}
		});
	}
	else if (a.attr('armed') != 'pending') {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'orange' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click','#stop_all', function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/stop_all_appointments',
		type:'POST',
		data: { timestamp: timestamp },
		success:function(response) {

		}
	});
});

$(document).on('click', '#me_settings', function() {
	var timestamp = Date.now();
	var b = $(this);
	var ml = $('#me_setting_list');
	if (!ml.is(':visible')) {
		$.ajax({
			url: '/manager/configure/me_settings',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				ml.html(response).show();
				b.attr('status', 'active');
			}
		});
	}
	else {
		ml.hide();
		b.attr('status', 'inactive');
	}
});

$(document).on('change', '.me_setting', function() {
	var set = $(this);
	var timestamp = Date.now();
	var setting = set.attr('setting');
	var dev = set.attr('device');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off'
		}
	}
	var anchor = $('.anchor_all_settings[setting_type="me"]');
	var anchor_check = anchor.is(':checked');
	if (anchor_check == true) {
		anchor.prop('checked', false);
		$('.me_setting[setting="' + setting + '"]').each(function(i,v) {
			if ($(v).attr('device') != dev) {
				if ($(v).attr('type') == 'checkbox') {
					$(v).prop('checked', set.prop('checked'));
				}
				$(v).val(value)
				$(v).trigger('change');
			}
		});
		setTimeout(function() {
			anchor.prop('checked', true);
		},1000);
	}
	$.ajax({
		url: '/manager/configure/me_setting',
		type: 'POST',
		data: { 
			timestamp: timestamp, 
			setting: setting, 
			value: value, 
			device: dev,
			timestamp: timestamp
		},
		success: function(response) {
			if (response.setting == 'my_name') {
				my_name = response['value'];
			}
		}
	});
});

$(document).on('click', '.home_plate_record', function() {
	var device = $(this).attr('device');
	var timestamp = Date.now();
	continent_record({device: device, app:'me', timestamp:timestamp,purpose:'home_plate'});
});

$(document).on('click', '#restore_list', function() {
	var c = $('#backup_list');
	var b = $(this);
	var text = b.text();
	b.text('* ' + text);
	if (c.is(':visible')) {
		b.text('Enc');
		c.hide();
		b.attr('status', 'inactive');
	} 
	else {
		var president = $('#president').val();
		$.ajax({
			url: '/manager/configure/restore_list',
			type: 'GET',
			data: { 'president': president },
			success:function(response) {
				c.html(response).show();
				b.text(text);
				b.attr('status', 'active');
			}
		});
	}
});

$(document).on('click', '#system_setting_lister', function() {
	var c = $('#system_list');
	var b = $(this);
	var text = b.text();
	var local_storage = JSON.stringify(localStorage);
	b.text('* ' + text);
	if (c.is(':visible')) {
		b.text('Sys');
		c.hide();
		b.attr('status', 'inactive');
	}
	else {
		$.ajax({
			url: '/manager/configure/system_list',
			type: 'GET',
			data: { local_storage: local_storage },
			success: function(response) {
				c.html(response).show();
				b.text(text);
				b.attr('status', 'active');
			}
		});
	}
});

$(document).on('click', '.localstorage_delete', function() {
	var key = $(this).attr('key');
	localStorage.removeItem(key);
	$('.system_localstorage[key="' + key + '"]').remove();
});

$(document).on('click', '#appointment_list_grabber', function() {

	var b = $(this);
	var text = b.text();
	b.text('* ' + text);
	var c = $('#configure_appointment_list');
	if (c.is(':visible')) {
		b.text('Appts');
		c.hide();
		b.attr('status', 'inactive');
	} else {
		$.ajax({
			url: '/manager/configure/appointment_list',
			type:'GET',
			success:function(response) {
				$('#configure_appointment_list').html(response).show();
				b.text(text);
				b.attr('status', 'active');
			},
		});
	}
});

$(document).on('click', '.appointment_configuration_grabber', function() {
	var t = $(this);
	var app = t.attr('app');
	var parent = t.closest('.wind');
	var display = $('.appointment_display[app="' + app + '"]');
	if (display.is(':visible')) {
		display.hide();
		t.attr('status', 'active');
	}
	else {
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
			$.each(visible, function(i,v) {
				$('.app_configure_input[app="' + app + '"][setting="' + v + '"]').show();
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
			$('#alert').html(response).show();
		}
	});
});

$(document).on('click', '.app_configure_toggle', function() {
	var app = $(this).attr('app');
	var setting = $(this).attr('setting');
	var input = $('.app_configure_input[app="' + app + '"][setting="' + setting + '"]');
	if (input.is(':visible')) {
		input.hide();
	}
	else {
		input.show();
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
			$('#alert').html(response).show();
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
			$('#alert').html(response).show();
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
			$('#alert').html('').hide();
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
			$('#alert').html(response.html).show();
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

$(document).on('click', '#database_vacuum', function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/configure/database_vacuum',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});


$(document).on('click', '#database_vacuum_confirm', function() {
	var timestamp = Date.now();
	var checkboxes = $('#alert').find('.database_vacuum_checkbox');
	var checked = [];
	checkboxes.each(function(i,v) {
		if ($(v).prop('checked') == true) {
			checked.push($(v).attr('app'));
		}
	});

	checked = JSON.stringify(checked);
	$.ajax({
		url: '/manager/configure/database_vacuum_confirm',
		type: 'POST',
		data: { timestamp: timestamp, checkboxes: checked },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});

$(document).on('click', '#database_uuid_cleaner', function() {
	$.ajax({
		url: '/manager/configure/database_uuid_cleaner',
		type: 'POST',
		data: {},
		success: function(response) {

		}
	});
});

$(document).on('click','.create_environment_qr', function() {
	var pos = $(this).attr('pos');
	var app = $(this).attr('app');
	$.ajax({
		url: '/manager/configure/environment/qr',
		type: 'POST',
		data: { pos: pos, app: app },
		success: function(response) {
		}
	});
});

$(document).on('click', '.appointment_distance', function() {
	var a = $(this);
	var app = a.attr('app');
	var app_uuid = a.attr('app_uuid');
	var uuid = a.attr('uuid');
	if (a.attr('armed') == 'yes') {
		a.attr('armed','pending');
		$.ajax({ 
			url: '/manager/configure/home_plate/save',
			data: { app: app, app_uuid: app_uuid, uuid: uuid },
			type: 'POST',
			success: function(response) {
				a.css({'background-color': 'lightgreen' });
				setTimeout(function() {
					a.attr('armed', 'no');
					var obg = a.attr('obg');
					a.css({'background-color': obg });
				},2000);
			}
		});
	}
	else if (a.attr('armed') != 'pending') {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'orange' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change', '.manual_home_plate', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var device = $(this).attr('device');
	var app = $(this).attr('app');

	$.ajax({
		url: '/manager/configure/home_plate/manual',
		type: 'POST',
		data: { app: app, device: device, value: value, setting: setting },
		success: function(response) {
		}
	});
});

$(document).on('click', '.home_plate_setting_save', function() {
	var uuid = $(this).attr('uuid');
	var app = $(this).attr('app');
	var hpSettings = { uuid: uuid };
	$('.home_plate_setting[uuid="' + uuid + '"').each(function(i,v) {
		var setting = $(v).attr('setting');
		var value = $(v).val();
		if ($(v).attr('type') == 'checkbox') {
			if ($(v).prop('checked') == true) {
				value = 'on';
			}
			else {
				value = 'off';
			}
		}
		hpSettings[setting] = value;
	});
	console.log(hpSettings);

	$.ajax({ 
		url: '/manager/configure/home_plate/settings',
		type: 'POST',
		data: {
			home_plate: JSON.stringify(hpSettings),
			timestamp: timestamp,
			app: app
		},
		success: function(response) {
			console.log(response);
			$('.home_plate_configuration[app="' + app + '"]').html(response.html);
		}
	});
});

$(document).on('change', '.home_plate_setting[setting="self"]', function() {
	var check = $(this);
	var uuid = check.attr('uuid');
	var appSetting = $('.home_plate_setting[setting="app"][uuid="' + uuid + '"]');
	if (check.prop('checked') == true) {
		appSetting.hide();
	} else {
		appSetting.show();
	}
});

$(document).on('click', '.home_plate_setting_deleter', function() {
	var app = $(this).attr('app');
	var uuid = $(this).attr('uuid');
	var a = $(this);
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/configure/home_plate/settings/delete',
			type: 'POST',
			data: { uuid: uuid, app: app },
			success: function(response) {
				console.log(response);
				$('.home_plate_setting_container[uuid="' + uuid + '"]').remove();
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

$(document).on('change', '.nfc_setting', function() {
	var b = $(this);
	var nsettings = $(this).closest('.nfc_settings');
	var app = nsettings.attr('app');
	var setting = b.attr('setting');
	var value = b.val();
	var uuid = nsettings.attr('uuid');
	$.ajax({
		url: '/manager/configure/nfc/setting',
		type: 'POST',
		data: { app: app, setting: setting, value: value, uuid: uuid },
		success: function(response) {
			configurationReloader(app);
		}
	});
});

$(document).on('click', '.nfc_appt_writer', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var app = a.attr('app');
	var msg = { uuid: uuid, app: app, type: 'app' };
	
	nfcWriter(msg,a);

});

$(document).on('click', '.nfc_deleter', function() {
	var a = $(this);

	var armed = a.attr('armed');

	if (armed == 'yes') {
		var uuid = a.attr('uuid');
		var app = a.attr('app');
		$.ajax({
			url: '/manager/configure/nfc/delete',
			type: 'POST',
			data: { app: app, uuid: uuid },
			success:function(response) {
				$('.nfc_settings[app="' + response.app + '"][uuid="' + response.uuid + '"]').remove();
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









