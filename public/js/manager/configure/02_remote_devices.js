$(document).on('click', '#tunnel_lister', function() {
	var b = $(this);
	var timestamp = Date.now();
	var c = $('#tunnel_list');
	b.text('* ' + jawnosConfigureLabel(b));
	c.show();
	tunnelLister('open');
	b.attr('status', 'active');
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
	b.text('* ' + jawnosConfigureLabel(b));
	$.ajax({
		url: '/manager/configure/pseudonym_list',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			c.html(response);
			b.text(jawnosConfigureLabel(b));
			if (jawnosConfigureShow('pseudonym_setting_lister', c)) {
				b.attr('status', 'active');
			}
		}
	});
});

$(document).on('change', '.pseudonym_setting', function() {
	var b = $(this);
	var timestamp = Date.now();
	var setting = b.attr('setting');
	var value = b.val();
	var name = b.closest('[pseudonym_name]').attr('pseudonym_name');
	var p = 
	$.ajax({
		url: '/manager/configure/pseudonym_setter',
		type: 'POST',
		data: { setting: setting, value: value, name: name, timestamp: timestamp },
		success: function(response) {
			$('#pseudonym_list').html(response);
			if (setting == 'status') {
				var p = $('.pseudonym.keyboard[toggle="' + name + '"]');
				jawnosDockIconSet(name, value);
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
		$('#alert').html('');
		$('#alert_message').html('Are you sure you want to change the pseudonym: ' + name + '\'s icon?<br><br>' +
			'<button pseudonym_name="' + name + '" id="pseudonym_icon_change_submit">Submit</button>'
		);
		jawnosAlert();
	}
});

$(document).on('click', '#pseudonym_icon_change_submit',function() {
	var submit = $(this);
	var timestamp = Date.now();
	if ($('#whiteboard').is(':visible')) {
		var canvas = document.getElementById('whiteboard');
		// the marker zooms now, so take the drawing itself, not the zoomed view
		var img;
		if (typeof markerFlatten == 'function' && typeof markerLayers != 'undefined' && markerLayers.length > 0) {
			img = markerFlatten().toDataURL('image/png');
		}
		else {
			img = canvas.toDataURL('image/png');
		}
		var name = submit.attr('pseudonym_name');
		var prev_img = $('.pseudonym_icon_set[name="' + name + '"]').attr('src');
		$.ajax({
			url: '/manager/configure/pseudonym_icon_changer',
			type: 'POST',
			data: { timestamp: timestamp, image: img, name: name },
			success: function(response) {
				$('#pseudonym_list').html(response.list);
				$('[name="' + name + '"][src="' + prev_img + '"]').attr('src',img);
				jawnosAlertClose();
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
	b.text('* ' + jawnosConfigureLabel(b));
	$.ajax({
		url: '/manager/configure/store_list',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			c.html(response);
			b.text(jawnosConfigureLabel(b));
			if (jawnosConfigureShow('store_setting_lister', c)) {
				b.attr('status', 'active');
			}
		}
	});
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
	}).fail(function(e) {
		ping.text('ping');
		$('#ping_results').text('ping failed (' + e.status + ')');
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

// Dev's migration action: ask a linked device to pull the whole house from
// this machine. The server sends the signed pull-now lever; this only starts
// it and follows the donor's own progress.
$(document).on('click', '.remote_migrate', function() {
	var b = $(this);
	var actions = b.closest('.device_actions');
	var sig = b.attr('signatorial');
	b.prop('disabled', true).text('Migrating…');
	$('.migration_status').remove();
	$.post('/manager/configure/migrate', { signatorial: sig, timestamp: Date.now() }, function(res) {
		if (!res || !res.ok) {
			b.prop('disabled', false).text('Migrate');
			actions.append($('<span class="migration_status"></span>').text(' ' + ((res && res.error) || 'failed')));
			return;
		}
		var span = $('<span class="migration_status"></span>').text(' migrating…');
		actions.append(span);
		var poll = function() {
			$.get('/manager/configure/migrate/status', { uuid: res.migration }, function(s) {
				if (!s || !s.ok) { span.text(' migration lost'); b.prop('disabled', false).text('Migrate'); return; }
				var snap = s.snapshot || {};
				var size = snap.size ? ' ' + Math.round(snap.size / 1048576) + 'MB' : '';
				span.text(' ' + (s.migration.state || '') + ' ' + (snap.state || '') + size);
				if (snap.state === 'done' || snap.state === 'failed' || s.migration.state === 'done') {
					b.prop('disabled', false).text('Migrate');
					return;
				}
				setTimeout(poll, 2000);
			}, 'json');
		};
		setTimeout(poll, 2000);
	}, 'json').fail(function() {
		b.prop('disabled', false).text('Migrate');
		actions.append($('<span class="migration_status"> failed</span>'));
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
				input.css({ 'background-color': '' });
			},2000);
		}
	});
});

// A citizen sets what a peer house may do here. The select and the days box are
// one lease: changing either sends both, and days blanks to no expiry.
$(document).on('change', '.remote_machine_grant_scope, .remote_machine_grant_days', function() {
	var field = $(this);
	var row = field.closest('.remote_machine');
	var box = field.closest('.device_grant');
	var scope = row.find('.remote_machine_grant_scope').val();
	var days = row.find('.remote_machine_grant_days').val();
	var uuid = row.find('.remote_machine_grant_scope').attr('uuid') || field.attr('uuid');
	var signatorial = row.find('.remote_machine_grant_scope').attr('signatorial') || field.attr('signatorial');
	$.ajax({
		url: '/manager/configure/remote_machine_grant',
		type: 'POST',
		data: { uuid: uuid, signatorial: signatorial, scope: scope, days: days, timestamp: Date.now() },
		success: function(response) {
			if (response && response.ok) {
				box.attr('grant-scope', response.scope || scope);
				box.attr('grant-expires', response.expires || '');
				box.css({ 'background-color': 'lightgreen' });
				setTimeout(function() { box.css({ 'background-color': '' }); }, 2000);
			} else if (window.console && response && response.error) {
				console.warn('grant: ' + response.error);
			}
		},
		error: function() {
			if (window.console) { console.warn('grant: the house did not answer'); }
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
					sw.css({'background-color': '' });
				},500);
			}
		},
		error: function(e) { console.log(e); }
	});
});


// ---- printers --------------------------------------------------------------
// The Dev panel lists this machine's CUPS queues. Finding printers is explicit:
// the button runs ippfind and adds the missing queues, so a printer that is off
// never slows the rest of the panel. The Store reads the same default.
$(document).on('change', '.default_printer_select', function() {
	var printer = $(this).val();
	$.ajax({
		url: '/manager/configure/printer_default',
		type: 'POST',
		data: { printer: printer, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			$('#printer_status').text(response && response.ok ? 'Saved.' : ((response && response.error) || 'Could not save.'));
		},
		error: function() { $('#printer_status').text('Could not save.'); }
	});
});

$(document).on('click', '.printer_sync', function() {
	var button = $(this);
	if (button.prop('disabled')) { return; }
	button.prop('disabled', true);
	$('#printer_status').text('Looking for printers…');
	$.ajax({
		url: '/manager/configure/printer_sync',
		type: 'POST',
		data: { timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok) {
				$('#printer_status').text((response && response.error) || 'Could not look for printers.');
				return;
			}
			var added = (response.added || []).length;
			var errors = (response.errors || []).length;
			var message = added ? ('Added ' + added + ' printer' + (added === 1 ? '' : 's') + '.') : 'No new printers found.';
			if (errors) { message += ' ' + errors + ' could not be added.'; }
			$('#printer_status').text(message);
			if (added) { setTimeout(function() { deviceLister(); }, 1200); }
		},
		error: function() { $('#printer_status').text('Could not look for printers.'); },
		complete: function() { button.prop('disabled', false); }
	});
});
