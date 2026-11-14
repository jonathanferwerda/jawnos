$(document).on('click', '.network_wifi_options_toggle', function() {
	var button = $(this);
	var box = button.closest('.network_wifi_row').find('.network_wifi_options');
	var opening = box.prop('hidden');
	box.prop('hidden', !opening);
	button.text(opening ? networkLabel('hide_options', 'Hide options') : networkLabel('options', 'Options'));
});

$(document).on('change', '.network_wifi_method', function() {
	var box = $(this).closest('.network_wifi_options');
	box.find('.network_wifi_static').prop('hidden', $(this).val() !== 'static');
});

function networkWifiJoin(row, button, ssid, passphrase) {
	var iface = row.attr('data-interface') || $('#network_wifi_hint').attr('data-iface') || '';
	if (!iface || !ssid) { return; }
	var message = row.find('.network_wifi_msg').text(networkT('Working…'));
	button.prop('disabled', true);
	var data = $.extend({ interface: iface, ssid: ssid, passphrase: passphrase || '' }, networkWifiOptionsData(row));
	networkPost('wifi_connect', data, function(response) {
		button.prop('disabled', false);
		if (response.ok) {
			message.text(response.message || networkT('Connected to {0}.', ssid));
			networkRefreshAll();
		}
		else {
			message.text(response.error || networkT('Could not connect.'));
		}
	});
}

// A scanned secured network asks for its passphrase in the house dialog, so no
// passphrase field sits in the list. A saved network has its own credential.
$(document).on('click', '.network_wifi_connect', function() {
	var row = $(this).closest('.network_wifi_row');
	var button = $(this);
	var ssid = row.attr('data-ssid') || '';
	if (!ssid) { return; }
	if (row.attr('data-secure') !== '1') {
		networkWifiJoin(row, button, ssid, '');
		return;
	}
	jawnosPasswordPrompt(networkT('Passphrase for {0}', ssid), function(passphrase) {
		passphrase = passphrase || '';
		if (!passphrase.length) {
			row.find('.network_wifi_msg').text(networkT('Enter the passphrase.'));
			return;
		}
		networkWifiJoin(row, button, ssid, passphrase);
	}, { title: networkT('Wi-Fi') });
});

$(document).on('click', '.network_wifi_row_disconnect', function() {
	var row = $(this).closest('.network_wifi_row');
	var button = $(this);
	var iface = row.attr('data-interface') || $('#network_wifi_hint').attr('data-iface') || '';
	if (!iface) { return; }
	var message = row.find('.network_wifi_msg').text(networkT('Working…'));
	button.prop('disabled', true);
	networkPost('wifi_disconnect', { interface: iface }, function(response) {
		button.prop('disabled', false);
		if (response.ok) {
			message.text(networkT('Disconnected.'));
			networkRefreshAll();
		}
		else {
			message.text(response.error || networkT('Could not disconnect.'));
		}
	});
});

$(document).on('click', '#network_wifi_disconnect', function() {
	var iface = $('#network_wifi_hint').attr('data-iface') || '';
	if (!iface) { return; }
	var button = $(this);
	button.prop('disabled', true);
	networkPost('wifi_disconnect', { interface: iface }, function() {
		button.prop('disabled', false);
		networkRefreshAll();
	});
});

$(document).on('click', '.network_wifi_forget', function() {
	var ssid = $(this).attr('data-ssid') || '';
	if (!ssid) { return; }
	jawnosConfirm(networkT('Forget this network?'), function() {
		networkPost('wifi_disconnect', { forget: '1', ssid: ssid }, function() {
			networkRefreshAll();
		});
	});
});

$(document).on('click', '.network_vpn_tailscale', function() {
	var button = $(this);
	var state = button.attr('data-state') === 'down' ? 'down' : 'up';
	button.prop('disabled', true);
	networkPost('vpn', { action: state === 'up' ? 'tailscale_up' : 'tailscale_down' }, function() {
		button.prop('disabled', false);
		networkRefreshAll();
	});
});

$(document).on('click', '.network_vpn_unit', function() {
	var button = $(this);
	var kind = button.attr('data-kind') || '';
	var name = button.attr('data-name') || '';
	var action = button.attr('data-action') === 'stop' ? 'vpn_stop' : 'vpn_start';
	if (!kind || !name) { return; }
	button.prop('disabled', true);
	networkPost('vpn', { action: action, kind: kind, name: name }, function() {
		button.prop('disabled', false);
		networkRefreshAll();
	});
});

$(document).on('click', '#network_open_dev', function() {
	var configure = $('.wind[app="configure"]');
	if (configure.length) {
		if (typeof topLevelNow === 'function') { topLevelNow(configure); }
	}
	else {
		$('.configuration').first().trigger('click');
	}
	var tries = 0;
	var timer = setInterval(function() {
		var dev = $('.wind[app="configure"] #device_lister');
		if (dev.length) {
			clearInterval(timer);
			dev.trigger('click');
		}
		else if (++tries > 40) {
			clearInterval(timer);
		}
	}, 150);
});

function networkAndroidJoin(row, ssid, passphrase) {
	var message = row.find('.network_wifi_msg').text(networkT('Working…'));
	var answer = networkAndroidCall('connect', [ ssid, passphrase || '' ]);
	if (!answer) { message.text(networkT('The phone did not answer.')); return; }
	if (answer.ok) {
		message.text(answer.message || networkT('Connected to {0}.', ssid));
		networkRenderAndroid();
		return;
	}
	if (answer.mode === 'settings') { networkAndroidCall('openSettings', [ 'wifi' ]); }
	message.text(answer.message || networkT('Could not connect.'));
}

$(document).on('click', '.network_android_connect', function() {
	var row = $(this).closest('.network_wifi_row');
	var ssid = row.attr('data-ssid') || '';
	if (!ssid) { return; }
	if (row.attr('data-secure') !== '1') { networkAndroidJoin(row, ssid, ''); return; }
	jawnosPasswordPrompt(networkT('Passphrase for {0}', ssid), function(passphrase) {
		passphrase = passphrase || '';
		if (!passphrase.length) {
			row.find('.network_wifi_msg').text(networkT('Enter the passphrase.'));
			return;
		}
		networkAndroidJoin(row, ssid, passphrase);
	}, { title: networkT('Wi-Fi') });
});

$(document).on('click', '#network_android_disconnect', function() {
	var answer = networkAndroidCall('disconnect');
	var box = $('#network_android_networks').empty();
	if (answer && answer.message) { box.append($('<div>').addClass('network_empty').text(answer.message)); }
	if (!answer || answer.ok) { networkRenderAndroid(); }
});

$(document).on('click', '#network_android_wifi_settings', function() {
	networkAndroidCall('openSettings', [ 'wifi' ]);
});

$(document).on('click', '#network_android_vpn_settings', function() {
	networkAndroidCall('openSettings', [ 'vpn' ]);
});

$(document).ready(function() {
	if ($('#network_app').length) { networkRefreshAll(); }
	if (network_poll_timer) { clearInterval(network_poll_timer); }
	network_poll_timer = setInterval(function() {
		if ($('#network_app').length) { networkRefreshAll(); }
	}, 15000);
});
