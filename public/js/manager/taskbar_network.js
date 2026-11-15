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
var jawnosNetworkTaskbarLastScan = null;
var jawnosNetworkTaskbarLastConnected = null;

// The widget is core and the Network app is the lazy chunk, so this small
// shared record is how the app can open on the widget's last scan. It keeps
// the raw list and the time it was taken; thirty seconds is the app's age.
window.jawnosNetworkScanCache = window.jawnosNetworkScanCache || { at: 0, interface: '', networks: [] };

function jawnosNetworkScanRemember(interface_name, networks) {
	window.jawnosNetworkScanCache = {
		at: Date.now(),
		interface: String(interface_name || ''),
		networks: networks ? networks.slice() : []
	};
}

function jawnosNetworkScanFresh(interface_name, max_age) {
	var cache = window.jawnosNetworkScanCache || {};
	var age = Number(max_age) > 0 ? Number(max_age) : 30000;
	if (!cache.at || (Date.now() - cache.at) > age) { return null; }
	if (interface_name && cache.interface !== String(interface_name)) { return null; }
	return cache;
}

function jawnosNetworkTaskbarConnectedSsid(status) {
	var wifi = (status && status.wifi) || {};
	var list = wifi.interfaces || [];
	for (var i = 0; i < list.length; i++) {
		var item = list[i] || {};
		if (String(item.state || '').toLowerCase() == 'connected' && item.ssid) { return String(item.ssid); }
	}
	return '';
}

// The connected network is the row a person is most likely to act on, so it
// takes the first place whatever the scan's signal order was.
function jawnosNetworkTaskbarOrder(networks, connected) {
	var ordered = [];
	var first = null;
	for (var i = 0; i < networks.length; i++) {
		var net = networks[i] || {};
		if (!first && connected && String(net.ssid || '') === connected) { first = net; }
		else { ordered.push(net); }
	}
	if (first) { ordered.unshift(first); }
	return ordered;
}

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

function jawnosNetworkTaskbarLoad(done) {
	if (!$('#taskbar_network').length) { return; }
	if (typeof document !== 'undefined' && document.hidden) { return; }
	$.ajax({
		url: '/manager/network/status',
		type: 'GET',
		cache: false,
		success: function(status) {
			jawnosNetworkTaskbarRender(status);
			if (typeof done === 'function') { done(status); }
		},
		error: function() {
			jawnosNetworkTaskbarRender(null);
			if (typeof done === 'function') { done(null); }
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
function jawnosNetworkTaskbarPanelField(label, classes, placeholder) {
	var field = $('<label></label>').addClass('taskbar_network_field');
	field.append($('<span></span>').text(label));
	field.append($('<input type="text">').addClass(classes)
		.attr('placeholder', placeholder || '')
		.attr('autocomplete', 'off'));
	return field;
}

// The addressing choices a join carries: DHCP by default, or a static address
// with an optional gateway, plus a DNS server either way.
function jawnosNetworkTaskbarPanelOptions() {
	var box = $('<div></div>').addClass('taskbar_network_options').attr('hidden', 'hidden');
	var method_row = $('<label></label>').addClass('taskbar_network_field');
	method_row.append($('<span></span>').text(jawnosT('Addressing')));
	var method = $('<select></select>').addClass('taskbar_network_method');
	method.append($('<option></option>').attr('value', 'dhcp').text(jawnosT('DHCP')));
	method.append($('<option></option>').attr('value', 'static').text(jawnosT('Static')));
	method_row.append(method);
	box.append(method_row);
	box.append(jawnosNetworkTaskbarPanelField(jawnosT('IP address'), 'taskbar_network_address', '192.168.1.50')
		.addClass('taskbar_network_static').attr('hidden', 'hidden'));
	box.append(jawnosNetworkTaskbarPanelField(jawnosT('Prefix'), 'taskbar_network_prefix', '24')
		.addClass('taskbar_network_static').attr('hidden', 'hidden'));
	box.append(jawnosNetworkTaskbarPanelField(jawnosT('Gateway'), 'taskbar_network_gateway', '192.168.1.1')
		.addClass('taskbar_network_static').attr('hidden', 'hidden'));
	box.append(jawnosNetworkTaskbarPanelField(jawnosT('DNS server'), 'taskbar_network_dns', '1.1.1.1'));
	return box;
}

function jawnosNetworkTaskbarPanelOptionsData(row) {
	var box = row.find('.taskbar_network_options');
	return {
		method: box.find('.taskbar_network_method').val() || 'dhcp',
		address: box.find('.taskbar_network_address').val() || '',
		prefix: box.find('.taskbar_network_prefix').val() || '',
		gateway: box.find('.taskbar_network_gateway').val() || '',
		dns: box.find('.taskbar_network_dns').val() || ''
	};
}

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
	var was_scanned = networks.attr('data-scanned') == '1';
	var connected_ssid = connected ? String(connected.ssid || '') : '';
	panel.find('.taskbar_network_panel_scan').prop('disabled', !iface || scanning);
	var note = panel.find('.taskbar_network_panel_wifi_note');
	// A machine with neither iwctl nor nmcli cannot join a network. Say so
	// once, and leave the row's buttons off rather than offering a join that
	// cannot run.
	if (iface && !wifi.can_connect && !scanning) { note.text(jawnosT('Wi-Fi connect needs iwctl or nmcli.')); }
	jawnosNetworkTaskbarPanelSaved(panel, wifi, iface);
	// One scan per opening: a fresh list is unscanned, and the first answer
	// marks it so the status poll that follows does not scan again. A scan the
	// app or another opening took less than thirty seconds ago is used as it is.
	if (iface && !networks.attr('data-scanned') && !scanning) {
		var cached = jawnosNetworkScanFresh(iface.name, 30000);
		if (cached) {
			networks.attr('data-scanned', '1').empty();
			jawnosNetworkTaskbarPanelNetworks(panel, cached.networks, iface);
		}
		else {
			jawnosNetworkTaskbarPanelScan(panel);
		}
	}
	else if (was_scanned && connected_ssid !== jawnosNetworkTaskbarLastConnected) {
		jawnosNetworkTaskbarPanelRefreshList(panel);
	}
	jawnosNetworkTaskbarLastConnected = connected_ssid;
}

// Saved networks are plain names; a join uses the credential the stack already
// holds. The list is an accordion so the scan answer keeps the room.
function jawnosNetworkTaskbarPanelSaved(panel, wifi, iface) {
	var box = panel.find('.taskbar_network_panel_saved');
	if (!wifi.can_connect || !iface) { box.empty().removeAttr('data-saved'); return; }
	var saved = wifi.saved || [];
	if (!saved.length) { box.empty().removeAttr('data-saved'); return; }
	// The status beat also runs while the panel is open. An unchanged name
	// list keeps its accordion and anything typed into an Options panel.
	var signature = saved.join('\u0001');
	if (box.attr('data-saved') === signature && box.find('.taskbar_network_saved_toggle').length) { return; }
	var open = false;
	var old_body = box.find('.taskbar_network_saved_body');
	if (old_body.length) { open = !old_body.prop('hidden'); }
	box.attr('data-saved', signature).empty();
	var body = $('<div></div>').addClass('taskbar_network_saved_body');
	if (!open) { body.attr('hidden', 'hidden'); }
	var scroll = $('<div></div>').addClass('taskbar_panel_scroll').appendTo(body);
	for (var i = 0; i < saved.length && i < 6; i++) {
		var ssid = String(saved[i] || '');
		if (!ssid) { continue; }
		var row = $('<div></div>').addClass('taskbar_panel_row taskbar_network_panel_network')
			.attr('data-ssid', ssid)
			.attr('data-interface', iface.name)
			.attr('data-saved', '1');
		row.append($('<span></span>').addClass('taskbar_panel_label').text(ssid));
		row.append($('<button type="button"></button>').addClass('taskbar_network_panel_connect').text(jawnosT('Connect')));
		row.append($('<button type="button"></button>').addClass('taskbar_network_options_toggle').text(jawnosT('Options')));
		row.append(jawnosNetworkTaskbarPanelOptions());
		scroll.append(row);
	}
	var toggle = $('<button type="button"></button>').addClass('taskbar_network_saved_toggle')
		.attr('aria-expanded', open ? 'true' : 'false')
		.append($('<span></span>').addClass('taskbar_network_saved_caret').text(open ? '▾' : '▸'))
		.append($('<span></span>').addClass('taskbar_network_saved_label').text(jawnosT('Saved networks')));
	box.append(toggle).append(body);
}

function jawnosNetworkTaskbarPanelNetworks(panel, networks, iface) {
	var list = panel.find('.taskbar_network_panel_networks');
	var wifi = (jawnosNetworkTaskbarData && jawnosNetworkTaskbarData.wifi) || {};
	var can_connect = !!(wifi.can_connect && iface);
	var connected = jawnosNetworkTaskbarConnectedSsid(jawnosNetworkTaskbarData);
	if (!networks || !networks.length) {
		list.append($('<div></div>').addClass('taskbar_panel_empty').text(jawnosT('No networks found.')));
		return;
	}
	jawnosNetworkTaskbarLastScan = { interface: iface ? iface.name : '', networks: networks.slice() };
	var ordered = jawnosNetworkTaskbarOrder(networks, connected);
	for (var i = 0; i < ordered.length; i++) {
		var net = ordered[i] || {};
		var ssid = String(net.ssid || '');
		if (!ssid) { continue; }
		var is_connected = connected && ssid === connected;
		var row = $('<div></div>').addClass('taskbar_panel_row taskbar_network_panel_network')
			.attr('data-ssid', ssid)
			.attr('data-interface', iface ? iface.name : '')
			.attr('data-secure', net.secure ? '1' : '0');
		row.append($('<span></span>').addClass('taskbar_panel_label').text(ssid));
		if (is_connected) {
			row.append($('<span></span>').addClass('taskbar_panel_badge taskbar_panel_up').text(jawnosT('Connected')));
		}
		if (net.secure) {
			row.append($('<span></span>').addClass('taskbar_panel_badge').text(net.security || jawnosT('Secured')));
		}
		row.append(jawnosNetworkTaskbarPanelBars(jawnosNetworkTaskbarBars(net)));
		if (can_connect) {
			if (is_connected) {
				row.append($('<button type="button"></button>').addClass('taskbar_network_panel_disconnect').text(jawnosT('Disconnect')));
			}
			else {
				row.append($('<button type="button"></button>').addClass('taskbar_network_panel_connect').text(jawnosT('Connect')));
				row.append($('<button type="button"></button>').addClass('taskbar_network_options_toggle').text(jawnosT('Options')));
				row.append(jawnosNetworkTaskbarPanelOptions());
			}
		}
		list.append(row);
	}
}

// After a join or a disconnect the status reload has the new answer; putting
// the cached scan back through the renderer moves the connected row and swaps
// its button without a second radio scan.
function jawnosNetworkTaskbarPanelRefreshList(panel) {
	if (!panel || !panel.length) { return; }
	var iface = jawnosNetworkTaskbarWifiInterface(jawnosNetworkTaskbarData);
	if (!iface) { return; }
	var cached = jawnosNetworkScanFresh(iface.name, 30000);
	var networks = cached ? cached.networks : null;
	if (!networks && jawnosNetworkTaskbarLastScan && jawnosNetworkTaskbarLastScan.interface === iface.name) {
		networks = jawnosNetworkTaskbarLastScan.networks;
	}
	if (!networks) { return; }
	panel.find('.taskbar_network_panel_networks').attr('data-scanned', '1').empty();
	jawnosNetworkTaskbarPanelNetworks(panel, networks, iface);
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
			var networks = response.networks || [];
			jawnosNetworkScanRemember(iface.name, networks);
			jawnosNetworkTaskbarPanelNetworks(panel, networks, iface);
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
	// The exit-node switch rides beside Scan. It names the machine carrying the
	// traffic while the route is on, so the button reads "Hub VPN" rather than a
	// bare state, and it is painted from the tailnet status on every open.
	controls.append($('<button type="button"></button>').addClass('taskbar_network_panel_vpn_button').attr('status', 'off').text(jawnosT('VPN')));
	wifi.append($('<div></div>').addClass('taskbar_panel_note taskbar_network_panel_wifi_note'));
	wifi.append($('<div></div>').addClass('taskbar_panel_scroll taskbar_network_panel_networks'));
	wifi.append($('<div></div>').addClass('taskbar_network_panel_saved'));

	jawnosNetworkTaskbarPanelSection(panel, 'bluetooth');
	jawnosNetworkTaskbarPanelSection(panel, 'vpn');

	jawnosNetworkTaskbarPanelWifiState(panel);
	jawnosNetworkTaskbarPanelPublicIp(panel);
	jawnosNetworkTaskbarPanelBluetooth(panel);
	jawnosNetworkTaskbarPanelVpn(panel);
	jawnosNetworkTaskbarVpnRefresh(panel);

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

// ---- the widget's VPN switch ------------------------------------------------
// The same tailnet exit node the Network app's Remote Machines accordion sets,
// offered here beside Scan. The machine carrying the traffic is named on the
// button ("Hub VPN"), and the choice is remembered (vpn_exit) so switching it
// back on uses the same machine. Turning it on with none remembered falls back
// to the first online exit node, the way the accordion does.
function jawnosNetworkVpnPref() {
	try { return localStorage.getItem('vpn_exit') || ''; } catch (e) { return ''; }
}

function jawnosNetworkVpnName(status, ip) {
	var peers = (status && status.peers) || [];
	for (var i = 0; i < peers.length; i++) {
		if (peers[i] && peers[i].ip === ip) { return peers[i].name || ip; }
	}
	return '';
}

function jawnosNetworkTaskbarVpnPaint(panel, status) {
	var b = panel.find('.taskbar_network_panel_vpn_button');
	if (!b.length) { return; }
	var exit = (status && status.exit) || '';
	var nodes = (typeof jawnosVpnNodes == 'function') ? jawnosVpnNodes(status) : [];
	var name = exit ? jawnosNetworkVpnName(status, exit) : '';
	b.attr('status', exit ? 'on' : 'off');
	b.prop('disabled', !exit && !nodes.length);
	b.css({
		'opacity': (exit || nodes.length) ? 1 : 0.45,
		'background-color': exit ? 'var(--jawnos-ok, #4caf50)' : ''
	});
	if (exit) {
		b.text(name ? name + ' ' + jawnosT('VPN') : jawnosT('VPN'));
		b.attr('hint', jawnosT('Turn the VPN off'));
	}
	else {
		b.text(jawnosT('VPN'));
		b.attr('hint', nodes.length
			? jawnosT("Route this device's web traffic through this machine")
			: jawnosT('No exit node is online'));
	}
}

function jawnosNetworkTaskbarVpnRefresh() {
	var panel = $('#taskbar_network_panel');
	if (!panel.length || !panel.find('.taskbar_network_panel_vpn_button').length) { return; }
	if (typeof jawnosVpnStatus != 'function') { return; }
	jawnosVpnStatus(function (status) {
		jawnosNetworkTaskbarVpnPaint(panel, status);
	});
}

function jawnosNetworkTaskbarVpnSet(ip) {
	var panel = $('#taskbar_network_panel');
	var b = panel.find('.taskbar_network_panel_vpn_button');
	if (!b.length) { return; }
	b.prop('disabled', true);
	var finish = function (r) {
		b.prop('disabled', false);
		if (!r || r.ok === false || r.ok === 0) {
			b.attr('hint', (r && r.error) || jawnosT('The VPN could not be changed'));
			return;
		}
		if (ip) { try { localStorage.setItem('vpn_exit', ip); } catch (e) {} }
		jawnosNetworkTaskbarVpnRefresh();
		// The route can take a moment to show in the status, so ask again rather
		// than leaving the button reading "off" after a success.
		setTimeout(jawnosNetworkTaskbarVpnRefresh, 1200);
		// The public address is the proof the route moved; refresh it too.
		if (typeof jawnosPublicIpRefresh == 'function' && $('#local_public_ip').length) {
			setTimeout(function () { jawnosPublicIpRefresh(true); }, 1500);
		}
	};
	if (window.JawnVPN && typeof window.JawnVPN.setExitNode === 'function') {
		try { finish(JSON.parse(window.JawnVPN.setExitNode(ip))); return; } catch (e) { finish({ ok: false, error: '' + e }); return; }
	}
	$.post('/manager/tailnet/exit', { ip: ip }, finish, 'json').fail(function () { finish({ ok: false }); });
}

$(document).on('click', '.taskbar_network_panel_vpn_button', function() {
	var b = $(this);
	if (b.attr('status') === 'on') { jawnosNetworkTaskbarVpnSet(''); return; }
	if (typeof jawnosVpnStatus != 'function') { return; }
	jawnosVpnStatus(function (status) {
		var nodes = (typeof jawnosVpnNodes == 'function') ? jawnosVpnNodes(status) : [];
		if (!nodes.length) { return; }
		var pref = jawnosNetworkVpnPref();
		var pick = '';
		for (var i = 0; i < nodes.length; i++) {
			if (nodes[i].ip === pref) { pick = pref; break; }
		}
		if (!pick) { pick = nodes[0].ip; }
		jawnosNetworkTaskbarVpnSet(pick);
	});
});

$(document).on('click', '.taskbar_network_options_toggle', function() {
	var button = $(this);
	var box = button.closest('.taskbar_network_panel_network').find('.taskbar_network_options');
	var opening = box.prop('hidden');
	box.prop('hidden', !opening);
	button.text(opening ? jawnosT('Hide options') : jawnosT('Options'));
});

$(document).on('change', '.taskbar_network_method', function() {
	var box = $(this).closest('.taskbar_network_options');
	box.find('.taskbar_network_static').prop('hidden', $(this).val() !== 'static');
});

function jawnosNetworkTaskbarPanelJoin(panel, row, button, ssid, passphrase) {
	var note = panel.find('.taskbar_network_panel_wifi_note');
	var iface = row.attr('data-interface') || '';
	button.prop('disabled', true);
	note.text(jawnosT('Connecting…'));
	$.ajax({
		url: '/manager/network/wifi_connect',
		type: 'POST',
		dataType: 'json',
		data: $.extend({ interface: iface, ssid: ssid, passphrase: passphrase || '', secure: (row.attr('data-saved') === '1' || row.attr('data-secure') !== '0' ? 1 : 0) }, jawnosNetworkTaskbarPanelOptionsData(row))
	}).done(function(response) {
		button.prop('disabled', false);
		if (response && response.ok) {
			var text = response.message || jawnosT('Connected to {0}.', ssid);
			if (response.warning) { text += ' ' + jawnosT('The passphrase could not be stored encrypted; the Wi-Fi stack keeps it.'); }
			note.text(text);
			jawnosNetworkTaskbarLoad(function() { jawnosNetworkTaskbarPanelRefreshList(panel); });
			return;
		}
		note.text((response && response.error) || jawnosT('Could not connect.'));
	}).fail(function(xhr) {
		note.text(jawnosT('The request failed.') + ' (' + xhr.status + ')');
		button.prop('disabled', false);
	});
}

$(document).on('click', '.taskbar_network_saved_toggle', function() {
	var button = $(this);
	var body = button.closest('.taskbar_network_panel_saved').find('.taskbar_network_saved_body');
	var opening = body.prop('hidden');
	body.prop('hidden', !opening);
	button.attr('aria-expanded', opening ? 'true' : 'false');
	button.find('.taskbar_network_saved_caret').text(opening ? '▾' : '▸');
});

// A scanned secured network asks in the house password dialog; a saved row
// already has its credential, so it joins directly.
$(document).on('click', '.taskbar_network_panel_connect', function() {
	var button = $(this);
	var row = button.closest('.taskbar_network_panel_network');
	var panel = button.closest('#taskbar_network_panel');
	var note = panel.find('.taskbar_network_panel_wifi_note');
	var ssid = row.attr('data-ssid') || '';
	if (!row.attr('data-interface') || !ssid) { return; }
	if (row.attr('data-secure') !== '1' || row.attr('data-saved') === '1') {
		jawnosNetworkTaskbarPanelJoin(panel, row, button, ssid, '');
		return;
	}
	jawnosPasswordPrompt(jawnosT('Passphrase for {0}', ssid), function(passphrase) {
		passphrase = passphrase || '';
		if (!passphrase.length) {
			note.text(jawnosT('Enter the passphrase.'));
			return;
		}
		jawnosNetworkTaskbarPanelJoin(panel, row, button, ssid, passphrase);
	}, { title: jawnosT('Wi-Fi') });
});

$(document).on('click', '.taskbar_network_panel_disconnect', function() {
	var button = $(this);
	var row = button.closest('.taskbar_network_panel_network');
	var panel = button.closest('#taskbar_network_panel');
	var note = panel.find('.taskbar_network_panel_wifi_note');
	var iface = row.attr('data-interface') || '';
	if (!iface) { return; }
	button.prop('disabled', true);
	note.text(jawnosT('Working…'));
	$.ajax({
		url: '/manager/network/wifi_disconnect',
		type: 'POST',
		dataType: 'json',
		data: { interface: iface }
	}).done(function(response) {
		button.prop('disabled', false);
		if (response && response.ok) {
			note.text(jawnosT('Disconnected.'));
			jawnosNetworkTaskbarLoad(function() { jawnosNetworkTaskbarPanelRefreshList(panel); });
			return;
		}
		note.text((response && response.error) || jawnosT('Could not disconnect.'));
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
