// The taskbar's network widget. It reads the same /manager/network/status the
// Network app uses and shows one of three things: the connected Wi-Fi network
// with its signal bars, a wired link, or Disconnected. A second request reads
// /manager/network/bluetooth/status and adds a Bluetooth glyph plus the
// connected device's name, so the bar can say what it is connected to before
// any app opens. The network status answer keeps its pinned shape; Bluetooth
// is a separate call.
var jawnosNetworkTaskbarData = null;
var jawnosNetworkTaskbarBluetoothData = null;

function jawnosNetworkTaskbarBars(item) {
	if (!item) { return 0; }
	var bars = parseInt(item.bars, 10);
	if (!isNaN(bars)) { return Math.max(0, Math.min(4, bars)); }
	var quality = parseFloat(item.quality);
	if (isNaN(quality)) { return 0; }
	if (quality >= 75) { return 4; }
	if (quality >= 50) { return 3; }
	if (quality >= 25) { return 2; }
	return quality > 0 ? 1 : 0;
}

function jawnosNetworkTaskbarWired(status) {
	var list = (status && status.interfaces) || [];
	for (var i = 0; i < list.length; i++) {
		var iface = list[i] || {};
		var name = String(iface.name || '');
		if (iface.wireless) { continue; }
		if (String(iface.state || '').toLowerCase() != 'up') { continue; }
		if (/^(?:lo|tailscale|tun|tap|docker|veth|br-|virbr)/i.test(name)) { continue; }
		return iface;
	}
	return null;
}

function jawnosNetworkTaskbarBluetoothConnected() {
	var data = jawnosNetworkTaskbarBluetoothData || {};
	if (!data.ok) { return null; }
	var list = data.connected || [];
	for (var i = 0; i < list.length; i++) {
		var item = list[i] || {};
		if (item.name || item.address) { return item; }
	}
	return null;
}

function jawnosNetworkTaskbarPaint() {
	var widget = $('#taskbar_network');
	if (!widget.length) { return; }
	var status = jawnosNetworkTaskbarData;
	var wifi = (status && status.wifi) || {};
	var wireless = wifi.interfaces || [];
	var connected = null;
	for (var i = 0; i < wireless.length; i++) {
		var item = wireless[i] || {};
		if (String(item.state || '').toLowerCase() == 'connected' && item.ssid) { connected = item; break; }
	}
	var kind = 'offline';
	var bars = 0;
	var text = jawnosT('Disconnected');
	var title = jawnosT('Network') + ' — ' + text;
	if (connected) {
		kind = 'wifi';
		bars = jawnosNetworkTaskbarBars(connected);
		text = connected.ssid || jawnosT('Wi-Fi');
		title = jawnosT('Network') + ' — ' + text;
		if (connected.rssi !== undefined && connected.rssi !== null) {
			title += ' (' + Math.round(connected.rssi) + ' dBm)';
		}
	}
	else {
		var wired = jawnosNetworkTaskbarWired(status);
		if (wired) {
			kind = 'ethernet';
			text = jawnosT('Ethernet');
			title = jawnosT('Network') + ' — ' + text;
		}
		else if (wifi.present && !wifi.radio_powered) {
			text = jawnosT('Wi-Fi off');
			title = jawnosT('Network') + ' — ' + text;
		}
	}
	var bluetooth = jawnosNetworkTaskbarBluetoothConnected();
	var bluetooth_name = bluetooth ? (bluetooth.name || bluetooth.address || '') : '';
	if (bluetooth_name) {
		text += ' · ' + bluetooth_name;
		title += ' · ' + jawnosT('Bluetooth') + ': ' + bluetooth_name;
	}
	widget.attr('kind', kind).attr('bars', bars).attr('bluetooth', bluetooth_name ? 'on' : 'off').attr('title', title);
	widget.find('.taskbar_network_bars i').each(function(index) {
		$(this).toggleClass('on', index < bars);
	});
	widget.find('.taskbar_network_text').text(text);
	widget.find('.taskbar_network_bluetooth').attr('title', bluetooth_name ? jawnosT('Bluetooth') + ': ' + bluetooth_name : jawnosT('Bluetooth'));
	widget.removeAttr('hidden').show();
}

function jawnosNetworkTaskbarRender(status) {
	jawnosNetworkTaskbarData = status;
	jawnosNetworkTaskbarPaint();
}

function jawnosNetworkTaskbarBluetooth(bluetooth) {
	jawnosNetworkTaskbarBluetoothData = bluetooth;
	jawnosNetworkTaskbarPaint();
}

function jawnosNetworkTaskbarLoad() {
	if (!$('#taskbar_network').length) { return; }
	if (typeof document !== 'undefined' && document.hidden) { return; }
	$.ajax({
		url: '/manager/network/status',
		type: 'GET',
		cache: false,
		success: function(status) { jawnosNetworkTaskbarRender(status); },
		error: function() {
			jawnosNetworkTaskbarRender(null);
		}
	});
	$.ajax({
		url: '/manager/network/bluetooth/status',
		type: 'GET',
		cache: false,
		success: function(bluetooth) { jawnosNetworkTaskbarBluetooth(bluetooth); },
		error: function() {
			jawnosNetworkTaskbarBluetooth({ ok: 0 });
		}
	});
}

$(document).on('click', '#taskbar_network', function() {
	if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
	if (typeof appWindowOpener === 'function') {
		appWindowOpener('network', Date.now(), { visible: 'yes' });
	}
});

$(function() {
	setTimeout(jawnosNetworkTaskbarLoad, 1800);
	setInterval(jawnosNetworkTaskbarLoad, 60000);
});
