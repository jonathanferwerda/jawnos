$(document).on('click', '.network_wifi_connect', function() {
	var row = $(this).closest('.network_wifi_row');
	var button = $(this);
	var ssid = row.attr('data-ssid') || '';
	var iface = $('#network_wifi_hint').attr('data-iface') || '';
	var passphrase = row.find('.network_wifi_pass').val() || '';
	var message = row.find('.network_wifi_msg').text(networkT('Working…'));
	button.prop('disabled', true);
	networkPost('wifi_connect', { interface: iface, ssid: ssid, passphrase: passphrase }, function(response) {
		button.prop('disabled', false);
		if (response.ok) {
			message.text(networkT('Connected to {0}.', ssid));
			networkRefreshAll();
		}
		else {
			message.text(response.error || networkT('Could not connect.'));
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
	if (!confirm(networkT('Forget this network?'))) { return; }
	networkPost('wifi_disconnect', { forget: '1', ssid: ssid }, function() {
		networkRefreshAll();
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

$(document).on('click', '.network_android_connect', function() {
	var row = $(this).closest('.network_wifi_row');
	var ssid = row.attr('data-ssid') || '';
	var passphrase = row.find('.network_android_pass').val() || '';
	var message = row.find('.network_wifi_msg').text(networkT('Working…'));
	var answer = networkAndroidCall('connect', [ ssid, passphrase ]);
	if (!answer) { message.text(networkT('The phone did not answer.')); return; }
	if (answer.ok) {
		message.text(answer.message || networkT('Connected to {0}.', ssid));
		networkRenderAndroid();
		return;
	}
	if (answer.mode === 'settings') { networkAndroidCall('openSettings', [ 'wifi' ]); }
	message.text(answer.message || networkT('Could not connect.'));
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
