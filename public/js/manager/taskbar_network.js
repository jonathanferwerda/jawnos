// The taskbar's network widget. It reads the same /manager/network/status the
// Network app uses and shows one of three things: the connected Wi-Fi network
// with its signal bars, a wired link, or Disconnected. A second request reads
// /manager/network/bluetooth/status and adds a Bluetooth glyph plus the
// connected device's name, so the bar can say what it is connected to before
// any app opens. The network status answer keeps its pinned shape; Bluetooth
// is a separate call.
//
// Clicking the widget opens a panel hung under it (taskbar_panel.js owns the
// frame). The panel is a quick glance and a short reach: scan for and join a
// Wi-Fi network, see what Bluetooth is connected, and start or stop a VPN. Its
// contents are rebuilt on every open from the cached status; a write asks for
// the status again instead of trusting its own answer, because the write
// returns only {ok, message}.
var jawnosNetworkTaskbarData = null;
var jawnosNetworkTaskbarBluetoothData = null;
var jawnosNetworkTaskbarScanToken = 0;

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

// The interface a scan or a join should name. The app uses the first wireless
// interface too; the server validates the name it is given.
function jawnosNetworkTaskbarWifiInterface(status) {
	var wifi = (status && status.wifi) || {};
	var list = wifi.interfaces || [];
	for (var i = 0; i < list.length; i++) {
		var iface = list[i] || {};
		if (iface.name) { return iface; }
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
	if (typeof jawnosTaskbarPanelIsOpen === 'function' && jawnosTaskbarPanelIsOpen('taskbar_network_panel')) {
		var panel = $('#taskbar_network_panel');
		jawnosNetworkTaskbarPanelWifiState(panel);
		jawnosNetworkTaskbarPanelVpn(panel);
	}
}

function jawnosNetworkTaskbarBluetooth(bluetooth) {
	jawnosNetworkTaskbarBluetoothData = bluetooth;
	jawnosNetworkTaskbarPaint();
	if (typeof jawnosTaskbarPanelIsOpen === 'function' && jawnosTaskbarPanelIsOpen('taskbar_network_panel')) {
		jawnosNetworkTaskbarPanelBluetooth($('#taskbar_network_panel'));
	}
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

// ------------------------------------------------------------------ panel

function jawnosNetworkTaskbarPanelSection(panel, name) {
	return $('<div></div>').addClass('taskbar_panel_section taskbar_network_panel_' + name).appendTo(panel);
}

function jawnosNetworkTaskbarPanelBars(bars) {
	var box = $('<span></span>').addClass('taskbar_panel_bars');
	for (var i = 0; i < 4; i++) {
		box.append($('<i></i>').toggleClass('on', i < bars));
	}
	return box;
}

// The state line and the saved list are the two parts that a status reload can
// change without disturbing the scan answer the person is looking at.
function jawnosNetworkTaskbarPanelWifiState(panel) {
	if (!panel || !panel.length) { return; }
	var box = panel.find('.taskbar_network_panel_wifi_state').empty();
	var status = jawnosNetworkTaskbarData;
	var wifi = (status && status.wifi) || {};
	var list = wifi.interfaces || [];
	var connected = null;
	for (var i = 0; i < list.length; i++) {
		var item = list[i] || {};
		if (String(item.state || '').toLowerCase() == 'connected' && item.ssid) { connected = item; break; }
	}
	var row = $('<div></div>').addClass('taskbar_panel_row');
	if (connected) {
		row.append($('<span></span>').addClass('taskbar_panel_label').text(connected.ssid || jawnosT('Wi-Fi')));
		row.append(jawnosNetworkTaskbarPanelBars(jawnosNetworkTaskbarBars(connected)));
	}
	else {
		var text = (wifi.present && !wifi.radio_powered) ? jawnosT('Wi-Fi off') : jawnosT('Disconnected');
		row.append($('<span></span>').addClass('taskbar_panel_label').text(text));
	}
	box.append(row);

	var iface = jawnosNetworkTaskbarWifiInterface(status);
	var networks = panel.find('.taskbar_network_panel_networks');
	var scanning = networks.attr('data-scanning') == '1';
	panel.find('.taskbar_network_panel_scan').prop('disabled', !iface || scanning);
	var note = panel.find('.taskbar_network_panel_wifi_note');
	// nmcli can scan, but only iwd carries a passphrase here. Say so once, and
	// leave the row's buttons off, rather than offering a join that cannot run.
	if (iface && !wifi.iwd && !scanning) { note.text(jawnosT('Wi-Fi connect needs iwd.')); }
	jawnosNetworkTaskbarPanelSaved(panel, wifi, iface);
	// One scan per opening: a fresh list is unscanned, and the first answer
	// marks it so the status poll that follows does not scan again.
	if (iface && !networks.attr('data-scanned') && !scanning) {
		jawnosNetworkTaskbarPanelScan(panel);
	}
}

// Saved networks are plain names; a join needs no passphrase. Keep the list
// short because the scan answer is the main thing in this section.
function jawnosNetworkTaskbarPanelSaved(panel, wifi, iface) {
	var box = panel.find('.taskbar_network_panel_saved').empty();
	if (!wifi.iwd || !iface) { return; }
	var saved = wifi.saved || [];
	if (!saved.length) { return; }
	box.append($('<div></div>').addClass('taskbar_panel_note').text(jawnosT('Saved networks')));
	var scroll = $('<div></div>').addClass('taskbar_panel_scroll').appendTo(box);
	for (var i = 0; i < saved.length && i < 6; i++) {
		var ssid = String(saved[i] || '');
		if (!ssid) { continue; }
		var row = $('<div></div>').addClass('taskbar_panel_row taskbar_network_panel_network')
			.attr('data-ssid', ssid)
			.attr('data-interface', iface.name);
		row.append($('<span></span>').addClass('taskbar_panel_label').text(ssid));
		row.append($('<button type="button"></button>').addClass('taskbar_network_panel_connect').text(jawnosT('Connect')));
		scroll.append(row);
	}
}

function jawnosNetworkTaskbarPanelNetworks(panel, networks, iface) {
	var list = panel.find('.taskbar_network_panel_networks');
	var wifi = (jawnosNetworkTaskbarData && jawnosNetworkTaskbarData.wifi) || {};
	var can_connect = !!(wifi.iwd && iface);
	if (!networks || !networks.length) {
		list.append($('<div></div>').addClass('taskbar_panel_empty').text(jawnosT('No networks found.')));
		return;
	}
	for (var i = 0; i < networks.length; i++) {
		var net = networks[i] || {};
		var ssid = String(net.ssid || '');
		if (!ssid) { continue; }
		var row = $('<div></div>').addClass('taskbar_panel_row taskbar_network_panel_network')
			.attr('data-ssid', ssid)
			.attr('data-interface', iface ? iface.name : '');
		row.append($('<span></span>').addClass('taskbar_panel_label').text(ssid));
		if (net.secure) {
			row.append($('<span></span>').addClass('taskbar_panel_badge').text(net.security || jawnosT('Secured')));
		}
		row.append(jawnosNetworkTaskbarPanelBars(jawnosNetworkTaskbarBars(net)));
		if (can_connect) {
			if (net.secure) {
				row.append($('<input type="password">').addClass('taskbar_panel_pass')
					.attr('placeholder', jawnosT('Passphrase'))
					.attr('aria-label', jawnosT('Passphrase'))
					.attr('autocomplete', 'off'));
			}
			row.append($('<button type="button"></button>').addClass('taskbar_network_panel_connect').text(jawnosT('Connect')));
		}
		list.append(row);
	}
}

function jawnosNetworkTaskbarPanelScan(panel) {
	if (!panel || !panel.length) { return; }
	var iface = jawnosNetworkTaskbarWifiInterface(jawnosNetworkTaskbarData);
	var list = panel.find('.taskbar_network_panel_networks');
	var button = panel.find('.taskbar_network_panel_scan');
	if (!iface) {
		list.empty().append($('<div></div>').addClass('taskbar_panel_empty').text(jawnosT('No wireless interface found.')));
		return;
	}
	// A slow scan can outlive the panel it was started from. The token makes a
	// late answer from an earlier opening harmless.
	var token = ++jawnosNetworkTaskbarScanToken;
	list.attr('data-scanning', '1').empty().append($('<div></div>').addClass('taskbar_panel_empty').text(jawnosT('Scanning…')));
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/network/wifi_scan',
		type: 'POST',
		dataType: 'json',
		data: { interface: iface.name }
	}).done(function(response) {
		if (token !== jawnosNetworkTaskbarScanToken) { return; }
		list.removeAttr('data-scanning').attr('data-scanned', '1').empty();
		if (!response || !response.ok) {
			list.append($('<div></div>').addClass('taskbar_panel_empty').text((response && response.error) || jawnosT('The scan failed.')));
		}
		else {
			jawnosNetworkTaskbarPanelNetworks(panel, response.networks || [], iface);
		}
		button.prop('disabled', false);
	}).fail(function(xhr) {
		if (token !== jawnosNetworkTaskbarScanToken) { return; }
		list.removeAttr('data-scanning').attr('data-scanned', '1').empty()
			.append($('<div></div>').addClass('taskbar_panel_empty').text(jawnosT('The scan failed.') + ' (' + xhr.status + ')'));
		button.prop('disabled', false);
	});
}

// The outward address is read from this machine's own interfaces, so it costs
// no network call. A machine behind NAT has none: the row says so and offers
// Look up, the one explicit request that can learn the router's address.
function jawnosNetworkTaskbarPanelPublicIp(panel) {
	var row = panel.find('.taskbar_network_panel_public');
	var value = row.find('.taskbar_panel_ip');
	var button = row.find('.taskbar_network_panel_public_lookup');
	if (!value.length) { return; }
	button.hide().prop('disabled', false);
	value.text(jawnosT('Reading…'));
	$.ajax({ url: '/manager/network/public_ip', type: 'GET', cache: false })
		.done(function(response) {
			if (response && response.ok && response.ip) {
				var title = [];
				if (response.family) { title.push(String(response.family)); }
				if (response.interface) { title.push(String(response.interface)); }
				value.text(String(response.ip)).attr('title', title.join(' · '));
				return;
			}
			value.text(jawnosT('Behind NAT')).removeAttr('title');
			if (response && response.behind_nat) { button.show(); }
		})
		.fail(function() {
			value.text(jawnosT('Unavailable')).removeAttr('title');
		});
}

$(document).on('click', '.taskbar_network_panel_public_lookup', function() {
	var button = $(this);
	var row = button.closest('.taskbar_network_panel_public');
	var value = row.find('.taskbar_panel_ip');
	button.prop('disabled', true).hide();
	value.text(jawnosT('Looking up…'));
	$.ajax({ url: '/manager/network/public_ip_lookup', type: 'POST', dataType: 'json' })
		.done(function(response) {
			button.prop('disabled', false);
			if (response && response.ok && response.ip) {
				value.text(String(response.ip)).attr('title', response.family ? String(response.family) : '');
				return;
			}
			value.text(jawnosT('Unavailable')).removeAttr('title');
			button.show();
		})
		.fail(function() {
			button.prop('disabled', false).show();
			value.text(jawnosT('Unavailable')).removeAttr('title');
		});
});

function jawnosNetworkTaskbarPanelBluetooth(panel) {
	if (!panel || !panel.length) { return; }
	var section = panel.find('.taskbar_network_panel_bluetooth').empty();
	section.append($('<h4></h4>').text(jawnosT('Bluetooth')));
	var data = jawnosNetworkTaskbarBluetoothData || {};
	var list = (data.ok && data.connected) || [];
	var any = false;
	for (var i = 0; i < list.length; i++) {
		var item = list[i] || {};
		var name = String(item.name || '');
		var address = String(item.address || '');
		if (!name && !address) { continue; }
		any = true;
		var row = $('<div></div>').addClass('taskbar_panel_row');
		row.append($('<span></span>').addClass('taskbar_panel_label').text(name || address));
		if (name && address) {
			row.append($('<span></span>').addClass('taskbar_panel_badge').text(address));
		}
		section.append(row);
	}
	if (!any) {
		section.append($('<div></div>').addClass('taskbar_panel_empty').text(jawnosT('No Bluetooth devices connected')));
	}
}

function jawnosNetworkTaskbarPanelVpnUnit(section, kind, entry) {
	entry = entry || {};
	var name = String(entry.name || '');
	var row = $('<div></div>').addClass('taskbar_panel_row');
	row.append($('<span></span>').addClass('taskbar_panel_label').text(name));
	row.append($('<span></span>').addClass('taskbar_panel_badge').text(entry.active ? jawnosT('Running') : jawnosT('Stopped')));
	row.append($('<button type="button"></button>')
		.addClass('taskbar_network_panel_vpn_unit')
		.attr('data-kind', kind)
		.attr('data-name', name)
		.attr('data-action', entry.active ? 'stop' : 'start')
		.text(entry.active ? jawnosT('Stop') : jawnosT('Start')));
	section.append(row);
}

function jawnosNetworkTaskbarPanelVpn(panel) {
	if (!panel || !panel.length) { return; }
	var section = panel.find('.taskbar_network_panel_vpn').empty();
	section.append($('<h4></h4>').text(jawnosT('VPN')));
	var vpn = (jawnosNetworkTaskbarData && jawnosNetworkTaskbarData.vpn) || {};
	var any = false;

	var tailscale = vpn.tailscale || {};
	if (tailscale.present) {
		any = true;
		var row = $('<div></div>').addClass('taskbar_panel_row');
		row.append($('<span></span>').addClass('taskbar_panel_label').text('Tailscale'));
		row.append($('<span></span>').addClass('taskbar_panel_badge').text(tailscale.running ? jawnosT('Running') : jawnosT('Stopped')));
		row.append($('<button type="button"></button>')
			.addClass('taskbar_network_panel_vpn_tailscale')
			.attr('data-state', tailscale.running ? 'down' : 'up')
			.text(tailscale.running ? jawnosT('Stop VPN') : jawnosT('Start VPN')));
		section.append(row);
		var detail = [];
		if (tailscale.ip) { detail.push(String(tailscale.ip)); }
		if (tailscale.exit_node) {
			detail.push(jawnosT('Exit node') + ': ' + (tailscale.exit_node.name || tailscale.exit_node.ip || ''));
		}
		if (detail.length) {
			section.append($('<div></div>').addClass('taskbar_panel_note').text(detail.join(' · ')));
		}
	}

	var wireguard = vpn.wireguard || [];
	for (var i = 0; i < wireguard.length; i++) {
		any = true;
		jawnosNetworkTaskbarPanelVpnUnit(section, 'wg', wireguard[i]);
	}
	var openvpn = vpn.openvpn || [];
	for (var j = 0; j < openvpn.length; j++) {
		any = true;
		jawnosNetworkTaskbarPanelVpnUnit(section, 'openvpn', openvpn[j]);
	}

	if (!any) {
		section.append($('<div></div>').addClass('taskbar_panel_empty').text(jawnosT('No VPN configured on this machine.')));
	}
	section.append($('<div></div>').addClass('taskbar_panel_note taskbar_network_panel_vpn_note'));
}

// Rebuilt on every open: the cached status paints the first frame, the auto
// scan fills the list, and the open handler asks for a fresh status after.
function jawnosNetworkTaskbarPanelBuild(panel) {
	if (!panel || !panel.length) { return; }
	panel.empty();

	var wifi = jawnosNetworkTaskbarPanelSection(panel, 'wifi');
	wifi.append($('<h4></h4>').text(jawnosT('Wi-Fi')));
	wifi.append($('<div></div>').addClass('taskbar_network_panel_wifi_state'));
	var public_row = $('<div></div>').addClass('taskbar_panel_row taskbar_network_panel_public');
	public_row.append($('<span></span>').addClass('taskbar_panel_label').text(jawnosT('Public address')));
	public_row.append($('<span></span>').addClass('taskbar_panel_ip').text('—'));
	public_row.append($('<button type="button"></button>').addClass('taskbar_network_panel_public_lookup').text(jawnosT('Look up')).hide());
	wifi.append(public_row);
	var controls = $('<div></div>').addClass('taskbar_panel_row').appendTo(wifi);
	controls.append($('<button type="button"></button>').addClass('taskbar_network_panel_scan').text(jawnosT('Scan')));
	wifi.append($('<div></div>').addClass('taskbar_panel_note taskbar_network_panel_wifi_note'));
	wifi.append($('<div></div>').addClass('taskbar_panel_scroll taskbar_network_panel_networks'));
	wifi.append($('<div></div>').addClass('taskbar_network_panel_saved'));

	jawnosNetworkTaskbarPanelSection(panel, 'bluetooth');
	jawnosNetworkTaskbarPanelSection(panel, 'vpn');

	jawnosNetworkTaskbarPanelWifiState(panel);
	jawnosNetworkTaskbarPanelPublicIp(panel);
	jawnosNetworkTaskbarPanelBluetooth(panel);
	jawnosNetworkTaskbarPanelVpn(panel);

	var footer = $('<div></div>').addClass('taskbar_panel_footer').appendTo(panel);
	footer.append($('<button type="button"></button>').addClass('taskbar_panel_open')
		.attr('data-app', 'network')
		.text(jawnosT('Open Network')));
}

$(document).on('click', '#taskbar_network', function() {
	if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
	if (typeof jawnosTaskbarPanelToggle !== 'function') { return; }
	jawnosTaskbarPanelToggle('taskbar_network_panel', '#taskbar_network', jawnosNetworkTaskbarPanelBuild);
	if (typeof jawnosTaskbarPanelIsOpen === 'function' && jawnosTaskbarPanelIsOpen('taskbar_network_panel')) {
		jawnosNetworkTaskbarLoad();
	}
});

$(document).on('click', '.taskbar_network_panel_scan', function() {
	jawnosNetworkTaskbarPanelScan($(this).closest('#taskbar_network_panel'));
});

// One handler for a scanned network and a saved one: the saved row simply has
// no passphrase input, so its value is empty.
$(document).on('click', '.taskbar_network_panel_connect', function() {
	var button = $(this);
	var row = button.closest('.taskbar_network_panel_network');
	var panel = button.closest('#taskbar_network_panel');
	var note = panel.find('.taskbar_network_panel_wifi_note');
	var iface = row.attr('data-interface') || '';
	var ssid = row.attr('data-ssid') || '';
	var passphrase = row.find('.taskbar_panel_pass').val() || '';
	if (!iface || !ssid) { return; }
	button.prop('disabled', true);
	note.text(jawnosT('Connecting…'));
	$.ajax({
		url: '/manager/network/wifi_connect',
		type: 'POST',
		dataType: 'json',
		data: { interface: iface, ssid: ssid, passphrase: passphrase }
	}).done(function(response) {
		if (response && response.ok) {
			note.text(jawnosT('Connected to {0}.', ssid));
			button.prop('disabled', false);
			jawnosNetworkTaskbarLoad();
			return;
		}
		note.text((response && response.error) || jawnosT('Could not connect.'));
		button.prop('disabled', false);
	}).fail(function(xhr) {
		note.text(jawnosT('The request failed.') + ' (' + xhr.status + ')');
		button.prop('disabled', false);
	});
});

function jawnosNetworkTaskbarPanelVpnWrite(button, data) {
	var panel = button.closest('#taskbar_network_panel');
	var note = panel.find('.taskbar_network_panel_vpn_note');
	button.prop('disabled', true);
	note.text('');
	$.ajax({
		url: '/manager/network/vpn',
		type: 'POST',
		dataType: 'json',
		data: data
	}).done(function(response) {
		if (response && response.ok) {
			button.prop('disabled', false);
			jawnosNetworkTaskbarLoad();
			return;
		}
		note.text((response && response.error) || jawnosT('The request failed.'));
		button.prop('disabled', false);
	}).fail(function(xhr) {
		note.text(jawnosT('The request failed.') + ' (' + xhr.status + ')');
		button.prop('disabled', false);
	});
}

$(document).on('click', '.taskbar_network_panel_vpn_tailscale', function() {
	var button = $(this);
	var down = button.attr('data-state') === 'down';
	jawnosNetworkTaskbarPanelVpnWrite(button, { action: down ? 'tailscale_down' : 'tailscale_up' });
});

$(document).on('click', '.taskbar_network_panel_vpn_unit', function() {
	var button = $(this);
	var kind = button.attr('data-kind') || '';
	var name = button.attr('data-name') || '';
	if (!kind || !name) { return; }
	jawnosNetworkTaskbarPanelVpnWrite(button, {
		action: button.attr('data-action') === 'stop' ? 'vpn_stop' : 'vpn_start',
		kind: kind,
		name: name
	});
});

$(function() {
	setTimeout(jawnosNetworkTaskbarLoad, 1800);
	setInterval(jawnosNetworkTaskbarLoad, 60000);
});
