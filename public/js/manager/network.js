/* [[js-split]]
   network.js is part 1. The rest live in network/ in name order:
     01_wifi_vpn_android.js - Wi-Fi connect and forget, VPN controls, Android actions and the poll
     02_tabs_bluetooth_remote.js - the tabs, their remembered choice, and the Bluetooth lists and actions
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// network.js - the Network app: interfaces, Wi-Fi, VPN, the mesh and the phone.
//
// The server does the Linux work through scripts/jawnos_network.pl; this file
// reads its JSON. When the Android app exposes window.JawnNetwork, the Android
// section calls it directly and the Linux paths stay untouched.

var network_poll_timer = null;
var network_last_wifi = null;
var network_last_scan = null;
var network_last_connected = null;

function networkT(text) {
	var args = Array.prototype.slice.call(arguments);
	if (typeof jawnosT === 'function') { return jawnosT.apply(null, args); }
	var value = text;
	for (var i = 1; i < args.length; i++) {
		value = value.split('{' + (i - 1) + '}').join(args[i]);
	}
	return value;
}

function networkLabel(name, fallback) {
	var value = $('#network_app').attr('data-' + name);
	return (value && value.length) ? value : networkT(fallback);
}

function networkBytes(value) {
	var n = Number(value);
	if (!isFinite(n) || n < 0) { return '—'; }
	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
	var i = 0;
	while (n >= 1024 && i < units.length - 1) { n = n / 1024; i++; }
	return (i ? n.toFixed(1) : n.toFixed(0)) + ' ' + units[i];
}

function networkAddressCell(addresses) {
	var cell = $('<td>').addClass('network_mono');
	if (!addresses || !addresses.length) { cell.text('—'); return cell; }
	for (var i = 0; i < addresses.length; i++) {
		var address = addresses[i] || {};
		var text = address.address || '';
		if (address.prefix !== undefined && address.prefix !== '') { text += '/' + address.prefix; }
		cell.append($('<div>').text(text));
	}
	return cell;
}

function networkGet(path, data, done) {
	$.ajax({
		url: '/manager/network/' + path,
		type: 'GET',
		dataType: 'json',
		data: data || {}
	}).done(function(response) {
		done((response && typeof response === 'object') ? response : { ok: 0, error: networkT('The answer was unreadable.') });
	}).fail(function(xhr) {
		done({ ok: 0, error: networkT('The request failed.') + ' (' + xhr.status + ')' });
	});
}

function networkPost(path, data, done) {
	$.ajax({
		url: '/manager/network/' + path,
		type: 'POST',
		dataType: 'json',
		data: data || {}
	}).done(function(response) {
		done((response && typeof response === 'object') ? response : { ok: 0, error: networkT('The answer was unreadable.') });
	}).fail(function(xhr) {
		done({ ok: 0, error: networkT('The request failed.') + ' (' + xhr.status + ')' });
	});
}

// ---------------------------------------------------------------- interfaces

function networkRenderInterfaces(list) {
	var body = $('#network_interfaces_body').empty();
	if (!list || !list.length) {
		body.append($('<tr>').append($('<td>').attr('colspan', '7').addClass('network_empty').text(networkT('No interfaces found.'))));
		return;
	}
	for (var i = 0; i < list.length; i++) {
		var iface = list[i] || {};
		var row = $('<tr>');
		var name = $('<td>').addClass('network_mono').text(iface.name || '');
		if (iface.wireless) { name.append($('<span>').addClass('network_pill').css('margin-left', '5px').text(networkT('Wi-Fi'))); }
		row.append(name);
		var state = String(iface.state || 'unknown');
		var state_pill = $('<span>').addClass('network_pill').text(state);
		if (state === 'up') { state_pill.addClass('network_up'); } else { state_pill.addClass('network_down'); }
		var state_cell = $('<td>').append(state_pill);
		if (iface.name) {
			state_cell.append($('<button type="button">').addClass('network_button network_interface_toggle')
				.attr('data-name', iface.name)
				.attr('data-action', state === 'up' ? 'down' : 'up')
				.text(state === 'up' ? networkT('Down') : networkT('Up')));
		}
		row.append(state_cell);
		row.append($('<td>').addClass('network_mono').text(iface.mac || ''));
		row.append(networkAddressCell(iface.ipv4));
		row.append(networkAddressCell(iface.ipv6));
		var method = '—';
		if (iface.method === 'dhcp') { method = networkT('DHCP'); }
		else if (iface.method === 'static') { method = networkT('Static'); }
		row.append($('<td>').text(method));
		row.append($('<td>').addClass('network_mono').text(networkBytes(iface.rx) + ' / ' + networkBytes(iface.tx)));
		body.append(row);
	}
}

// --------------------------------------------------------------------- wi-fi

// The addressing choices that ride with a connect: DHCP by default, or a
// static address with an optional gateway, plus a DNS server either way.
function networkWifiField(label, classes, placeholder) {
	var field = $('<label>').addClass('network_wifi_field');
	field.append($('<span>').text(label));
	field.append($('<input type="text">').addClass(classes)
		.attr('placeholder', placeholder || '')
		.attr('autocomplete', 'off'));
	return field;
}

function networkWifiOptions() {
	var box = $('<div>').addClass('network_wifi_options').attr('hidden', 'hidden');
	var method_row = $('<label>').addClass('network_wifi_field');
	method_row.append($('<span>').text(networkLabel('addressing', 'Addressing')));
	var method = $('<select>').addClass('network_wifi_method');
	method.append($('<option>').attr('value', 'dhcp').text(networkLabel('dhcp', 'DHCP')));
	method.append($('<option>').attr('value', 'static').text(networkLabel('static', 'Static')));
	method_row.append(method);
	box.append(method_row);
	box.append(networkWifiField(networkLabel('ip_address', 'IP address'), 'network_wifi_address', '192.168.1.50')
		.addClass('network_wifi_static').attr('hidden', 'hidden'));
	box.append(networkWifiField(networkLabel('prefix', 'Prefix'), 'network_wifi_prefix', '24')
		.addClass('network_wifi_static').attr('hidden', 'hidden'));
	box.append(networkWifiField(networkLabel('gateway', 'Gateway'), 'network_wifi_gateway', '192.168.1.1')
		.addClass('network_wifi_static').attr('hidden', 'hidden'));
	box.append(networkWifiField(networkLabel('dns', 'DNS server'), 'network_wifi_dns', '1.1.1.1'));
	return box;
}

function networkWifiOptionsData(row) {
	var box = row.find('.network_wifi_options');
	return {
		method: box.find('.network_wifi_method').val() || 'dhcp',
		address: box.find('.network_wifi_address').val() || '',
		prefix: box.find('.network_wifi_prefix').val() || '',
		gateway: box.find('.network_wifi_gateway').val() || '',
		dns: box.find('.network_wifi_dns').val() || ''
	};
}

function networkSignalText(network) {
	var bars = Number(network.bars);
	if (!isFinite(bars)) { bars = Math.round((Number(network.signal) || 0) / 25); }
	bars = Math.max(0, Math.min(4, bars));
	var text = '';
	for (var i = 0; i < bars; i++) { text += '*'; }
	return text || '—';
}

function networkConnectedSsid(wifi) {
	wifi = wifi || network_last_wifi || {};
	var list = wifi.interfaces || [];
	for (var i = 0; i < list.length; i++) {
		var iface = list[i] || {};
		if (String(iface.state || '').toLowerCase() === 'connected' && iface.ssid) { return iface.ssid; }
	}
	return '';
}

// The connected network is the thing the person is most likely to act on, so
// it takes the first row whatever the scan's signal order was.
function networkScanOrder(networks, connected) {
	var ordered = [];
	var first = null;
	for (var i = 0; i < networks.length; i++) {
		var net = networks[i] || {};
		if (!first && connected && net.ssid === connected) { first = net; }
		else { ordered.push(net); }
	}
	if (first) { ordered.unshift(first); }
	return ordered;
}

// The widget is core and the app is the lazy chunk, so the widget owns the
// small shared scan cache. A page without the widget still scans normally.
function networkScanCacheGet(iface) {
	if (typeof jawnosNetworkScanFresh === 'function') { return jawnosNetworkScanFresh(iface, 30000); }
	return null;
}

function networkScanCachePut(iface, networks) {
	if (typeof jawnosNetworkScanRemember === 'function') { jawnosNetworkScanRemember(iface, networks); }
}

function networkRenderWifi(wifi) {
	wifi = wifi || {};
	var interfaces = wifi.interfaces || [];
	var first = interfaces.length ? interfaces[0] : null;
	$('#network_wifi_hint')
		.text(first ? (networkT('Interface') + ': ' + first.name) : networkT('No wireless interface found.'))
		.attr('data-iface', first ? first.name : '');
	var radio = $('#network_radio_toggle');
	if (wifi.can_connect) {
		radio.prop('disabled', false)
			.attr('aria-pressed', wifi.radio_powered ? 'true' : 'false')
			.toggleClass('network_off', !wifi.radio_powered)
			.text(wifi.radio_powered ? networkT('Radio on') : networkT('Radio off'));
	}
	else {
		radio.prop('disabled', true).removeClass('network_off').attr('aria-pressed', 'false').text(networkT('Radio'));
	}
	if (!wifi.can_connect && first) { $('#network_wifi_hint').text(networkT('No Wi-Fi tool is installed (iwctl or nmcli).')); }
	$('#network_wifi_scan').prop('disabled', !first || !wifi.can_connect);
	$('#network_wifi_disconnect').prop('disabled', !first || !wifi.can_connect);
	var wifi_list = $('#network_wifi_list');
	if (!wifi_list.attr('data-ready')) {
		wifi_list.attr('data-ready', '1').empty();
		var opening = networkT('No wireless interface found.');
		if (!wifi.can_connect && first) { opening = networkT('No Wi-Fi tool is installed (iwctl or nmcli).'); }
		else if (wifi.can_connect && first) { opening = networkT('Press Scan to list networks.'); }
		wifi_list.append($('<div>').addClass('network_empty').text(opening));
	}

	// Opening the app should not always wait for a scan: a scan from the widget
	// (or another window) less than thirty seconds old is used as it is. After
	// that, scan once per opening.
	network_last_wifi = wifi;
	var connected = networkConnectedSsid(wifi);
	if (first && !wifi_list.attr('data-autoscan')) {
		wifi_list.attr('data-autoscan', '1');
		var cached = networkScanCacheGet(first.name);
		if (cached) { networkRenderScan(cached.networks || []); }
		else { networkScan(); }
	}
	else if (network_last_scan && connected !== network_last_connected) {
		networkRenderScan(network_last_scan);
	}
	network_last_connected = connected;

	var state_box = $('#network_wifi_state').empty();
	for (var i = 0; i < interfaces.length; i++) {
		var iface = interfaces[i] || {};
		var row = $('<div>').addClass('network_wifi_row');
		row.append($('<span>').addClass('network_wifi_name').text(iface.name || ''));
		row.append($('<span>').addClass('network_pill').text(iface.state || ''));
		row.append($('<span>').text(iface.ssid || ''));
		state_box.append(row);
	}

	var saved_box = $('#network_saved_list');
	var saved = wifi.saved || [];
	// The status poll runs every fifteen seconds. Rebuilding an unchanged list
	// would close an Options panel the person is filling in, so only rebuild
	// when the saved names really changed.
	var saved_signature = saved.join('\u0001');
	if (saved_box.attr('data-saved') !== saved_signature) {
		saved_box.attr('data-saved', saved_signature).empty();
		if (!saved.length) {
			saved_box.append($('<div>').addClass('network_empty').text(networkT('No saved networks.')));
		}
		for (var j = 0; j < saved.length; j++) {
			var saved_row = $('<div>').addClass('network_wifi_row')
			.attr('data-ssid', saved[j])
			.attr('data-saved', '1');
			saved_row.append($('<span>').addClass('network_wifi_name').text(saved[j]));
			saved_row.append($('<button type="button">').addClass('network_button network_wifi_connect').text(networkLabel('connect', 'Connect')));
			saved_row.append($('<button type="button">').addClass('network_button network_wifi_forget')
				.attr('data-ssid', saved[j]).text(networkLabel('forget', 'Forget')));
			saved_row.append($('<button type="button">').addClass('network_button network_wifi_options_toggle')
				.text(networkLabel('options', 'Options')));
			saved_row.append($('<span>').addClass('network_wifi_msg'));
			saved_row.append(networkWifiOptions());
			saved_box.append(saved_row);
		}
	}
}

function networkRenderScan(networks) {
	networks = networks || [];
	network_last_scan = networks;
	var box = $('#network_wifi_list').empty();
	if (!networks.length) {
		box.append($('<div>').addClass('network_empty').text(networkT('No networks found.')));
		return;
	}
	var iface = $('#network_wifi_hint').attr('data-iface') || '';
	var connected = networkConnectedSsid();
	var ordered = networkScanOrder(networks, connected);
	for (var i = 0; i < ordered.length; i++) {
		var net = ordered[i] || {};
		var ssid = net.ssid || '';
		var is_connected = connected && ssid === connected;
		var row = $('<div>').addClass('network_wifi_row')
			.attr('data-ssid', ssid)
			.attr('data-interface', iface)
			.attr('data-secure', net.secure ? '1' : '0');
		row.append($('<span>').addClass('network_wifi_name').text(ssid));
		if (is_connected) {
			row.append($('<span>').addClass('network_pill network_up').text(networkLabel('connected', 'Connected')));
		}
		row.append($('<span>').addClass('network_pill').text(net.secure ? (net.security || networkT('Secured')) : networkT('Open')));
		row.append($('<span>').addClass('network_signal').text(networkSignalText(net)));
		if (is_connected) {
			row.append($('<button type="button">').addClass('network_button network_wifi_row_disconnect')
				.attr('data-interface', iface).text(networkLabel('disconnect', 'Disconnect')));
		}
		else {
			row.append($('<button type="button">').addClass('network_button network_wifi_connect').text(networkLabel('connect', 'Connect')));
			row.append($('<button type="button">').addClass('network_button network_wifi_options_toggle')
				.text(networkLabel('options', 'Options')));
		}
		row.append($('<span>').addClass('network_wifi_msg'));
		if (!is_connected) { row.append(networkWifiOptions()); }
		box.append(row);
	}
}

function networkScan() {
	var iface = $('#network_wifi_hint').attr('data-iface') || '';
	var box = $('#network_wifi_list').empty();
	box.append($('<div>').addClass('network_empty').text(networkT('Scanning…')));
	networkPost('wifi_scan', { interface: iface }, function(response) {
		if (response.ok) {
			var networks = response.networks || [];
			networkScanCachePut(iface, networks);
			networkRenderScan(networks);
			return;
		}
		box.empty().append($('<div>').addClass('network_empty').text(response.error || networkT('The scan failed.')));
	});
}

function networkRefreshAll() {
	if (!$('#network_app').length) { return; }
	networkGet('status', {}, function(data) {
		if (data.error) { $('#network_status_line').text(data.error); }
		else { $('#network_status_line').text(new Date().toLocaleTimeString()); }
		networkRenderManager(data);
		networkRenderInterfaces(data.interfaces || []);
		networkRenderWifi(data.wifi || {});
		networkRenderVpn(data.vpn || {});
		networkRenderAndroid();
	});
}

// The management row: the checkbox, the Apply button and the short note that
// says who is writing the machine's connection. The status answer carries the
// saved config, the manager the helper found, the takeover ledger (an array of
// { unit, enabled } like Power's) and whether a secret can be stored encrypted.
function networkManagerNames(list) {
	var names = [];
	if (!list || !list.length) { return names; }
	for (var i = 0; i < list.length; i++) {
		var item = list[i];
		var name = (typeof item === 'string') ? item : ((item && item.unit) || '');
		if (name && names.indexOf(name) < 0) { names.push(name); }
	}
	return names;
}

function networkRenderManager(data) {
	var config = (data && data.config) || {};
	var manage = !!config.manage;
	$('#network_manage').prop('checked', manage);
	$('#network_apply').prop('disabled', !manage);
	var note = $('#network_manager_note').empty();
	if (!manage) {
		note.text(networkT('JawnOS does not manage networking.'));
		return;
	}
	var manager = (data && data.manager) || {};
	var stack = (typeof manager === 'string') ? manager : (manager.stack || manager.name || '');
	note.append($('<div>').text(stack
		? networkT('JawnOS is applying saved addresses through {0}.', stack)
		: networkT('JawnOS is applying saved addresses.')));
	// The stack itself (iwd, systemd-networkd, NetworkManager) is the one JawnOS
	// drives, not a competitor. Only the legacy daemons are worth naming, and
	// the takeover ledger lists the ones JawnOS stopped.
	var competitors = networkManagerNames(manager.competitors);
	if (competitors.length) {
		note.append($('<div>').text(networkT('{0} is also running.', competitors.join(', '))));
	}
	var stopped = networkManagerNames(data && data.takeover);
	if (stopped.length) {
		note.append($('<div>').text(networkT('JawnOS stopped {0}.', stopped.join(', '))));
	}
	var secrets = (data && data.secrets) || {};
	if (secrets.available !== undefined && !secrets.available) {
		note.append($('<div>').text(networkT('Passphrases cannot be stored encrypted on this machine, so each network asks for its passphrase again.')));
	}
}

// ----------------------------------------------------------------------- VPN

function networkVpnButton(label, classes, attributes) {
	var button = $('<button type="button">').addClass('network_button ' + (classes || '')).text(label);
	if (attributes) {
		for (var key in attributes) {
			if (Object.prototype.hasOwnProperty.call(attributes, key)) { button.attr(key, attributes[key]); }
		}
	}
	return button;
}

function networkVpnUnitCard(kind, label, entry) {
	entry = entry || {};
	var card = $('<div>').addClass('network_vpn_card');
	var info = $('<div>').css({ 'flex': '1 1 160px', 'min-width': '0' });
	info.append($('<h5>').text(label));
	info.append($('<div>').addClass('network_vpn_line network_mono').text(entry.name || ''));
	info.append($('<div>').addClass('network_vpn_line').text(entry.active ? networkT('Running') : networkT('Stopped')));
	card.append(info);
	card.append(networkVpnButton(
		entry.active ? networkT('Stop') : networkT('Start'),
		'network_vpn_unit',
		{ 'data-kind': kind, 'data-name': entry.name || '', 'data-action': entry.active ? 'stop' : 'start' }
	));
	return card;
}

function networkRenderVpn(vpn) {
	vpn = vpn || {};
	var box = $('#network_vpn_content').empty();
	var any = false;

	var tailscale = vpn.tailscale || {};
	if (tailscale.present) {
		any = true;
		var tailscale_card = $('<div>').addClass('network_vpn_card');
		var tailscale_info = $('<div>').css({ 'flex': '1 1 160px', 'min-width': '0' });
		tailscale_info.append($('<h5>').text('Tailscale'));
		tailscale_info.append($('<div>').addClass('network_vpn_line').text(tailscale.running ? networkT('Connected') : networkT('Not running')));
		if (tailscale.ip) { tailscale_info.append($('<div>').addClass('network_vpn_line network_mono').text(tailscale.ip)); }
		if (tailscale.exit_node) {
			tailscale_info.append($('<div>').addClass('network_vpn_line').text(
				networkT('Exit node') + ': ' + (tailscale.exit_node.name || tailscale.exit_node.ip || '')
			));
		}
		tailscale_card.append(tailscale_info);
		tailscale_card.append(networkVpnButton(
			tailscale.running ? networkT('Stop VPN') : networkT('Start VPN'),
			'network_vpn_tailscale',
			{ 'data-state': tailscale.running ? 'down' : 'up' }
		));
		box.append(tailscale_card);
	}

	var wireguard = vpn.wireguard || [];
	for (var i = 0; i < wireguard.length; i++) {
		any = true;
		box.append(networkVpnUnitCard('wg', networkT('WireGuard'), wireguard[i]));
	}
	var openvpn = vpn.openvpn || [];
	for (var j = 0; j < openvpn.length; j++) {
		any = true;
		box.append(networkVpnUnitCard('openvpn', networkT('OpenVPN'), openvpn[j]));
	}
	if (!any) {
		box.append($('<div>').addClass('network_empty').text(networkT('No VPN configured on this machine.')));
	}
}

// ------------------------------------------------------------------- android

function networkAndroidAvailable() {
	return !!(window.JawnNetwork && typeof window.JawnNetwork.status === 'function');
}

function networkAndroidCall(method, args) {
	if (!networkAndroidAvailable() || typeof window.JawnNetwork[method] !== 'function') { return null; }
	try {
		var answer = window.JawnNetwork[method].apply(window.JawnNetwork, args || []);
		if (typeof answer === 'string') { return JSON.parse(answer); }
		return answer || {};
	}
	catch (error) {
		return { error: String(error) };
	}
}

function networkAndroidLine(label, value) {
	var line = $('<div>').addClass('network_vpn_line');
	line.append($('<strong>').text(label + ': '));
	line.append($('<span>').text(value === undefined || value === null || value === '' ? '—' : String(value)));
	return line;
}

function networkRenderAndroid() {
	var section = $('#network_android_section');
	if (!networkAndroidAvailable()) { section.hide(); return; }
	section.show();

	var status = networkAndroidCall('status') || {};
	var vpn = networkAndroidCall('vpn') || {};
	var box = $('#network_android_status').empty();
	if (status.error) {
		box.append($('<div>').addClass('network_empty').text(status.error));
		return;
	}
	var card = $('<div>').addClass('network_android_row');
	var info = $('<div>').css({ 'flex': '1 1 180px', 'min-width': '0' });
	info.append($('<h5>').text('Android'));
	info.append(networkAndroidLine(networkT('State'), status.connected ? networkT('Connected') : networkT('Not connected')));
	if (status.type) { info.append(networkAndroidLine(networkT('Type'), status.type)); }
	if (status.ssid) { info.append(networkAndroidLine('SSID', status.ssid)); }
	if (Array.isArray(status.interfaces) && status.interfaces.length) {
		var names = [];
		for (var i = 0; i < status.interfaces.length; i++) {
			var entry = status.interfaces[i];
			var label = (typeof entry === 'string') ? entry : (entry && (entry.name || entry.interface)) || '';
			if (label) { names.push(label); }
		}
		if (names.length) { info.append(networkAndroidLine(networkT('Interfaces'), names.join(', '))); }
	}
	if (status.signal !== undefined && status.signal !== null) { info.append(networkAndroidLine(networkT('Signal'), status.signal)); }
	if (status.ip) { info.append(networkAndroidLine('IPv4', status.ip)); }
	info.append(networkAndroidLine(networkT('VPN'), vpn.active ? (vpn.name || vpn.type || networkT('Connected')) : networkT('None')));
	card.append(info);
	box.append(card);
}

function networkRenderAndroidNetworks(networks) {
	var box = $('#network_android_networks').empty();
	if (!networks || !networks.length) {
		box.append($('<div>').addClass('network_empty').text(networkT('No networks found.')));
		return;
	}
	for (var i = 0; i < networks.length; i++) {
		var net = networks[i] || {};
		var row = $('<div>').addClass('network_wifi_row')
			.attr('data-ssid', net.ssid || '')
			.attr('data-secure', net.secure ? '1' : '0');
		row.append($('<span>').addClass('network_wifi_name').text(net.ssid || ''));
		row.append($('<span>').addClass('network_pill').text(net.secure ? networkT('Secured') : networkT('Open')));
		row.append($('<span>').addClass('network_signal').text(networkSignalText({ signal: net.signal })));
		row.append($('<button type="button">').addClass('network_button network_android_connect').text(networkLabel('connect', 'Connect')));
		row.append($('<span>').addClass('network_wifi_msg'));
		box.append(row);
	}
}

// ------------------------------------------------------------------ listeners

$(document).on('click', '#network_toggle', function() {
	var open = $('.wind[app="network"]');
	if (open.length) {
		if (typeof topLevelNow === 'function') { topLevelNow(open); }
		return;
	}
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/network',
		type: 'GET',
		data: {
			window_maker: 'yes',
			timestamp: timestamp,
			browser_tab_id: (typeof bti !== 'undefined' ? bti : '')
		},
		success: function(response) {
			if (typeof windowMaker === 'function') { windowMaker(response); }
			networkRefreshAll();
		}
	});
});

$(document).on('click', '#network_refresh', function() {
	networkRefreshAll();
});

$(document).on('click', '.network_interface_toggle', function() {
	var button = $(this);
	var name = button.attr('data-name') || '';
	var action = button.attr('data-action') || '';
	if (!name || !action) { return; }
	button.prop('disabled', true);
	networkPost('interface', { name: name, action: action }, function(response) {
		button.prop('disabled', false);
		if (response.error) { $('#network_status_line').text(response.error); }
		networkRefreshAll();
	});
});

$(document).on('click', '#network_wifi_scan, #network_android_scan', function() {
	if (this.id === 'network_android_scan') {
		var answer = networkAndroidCall('scan');
		if (!answer || answer.error) {
			$('#network_android_networks').empty().append($('<div>').addClass('network_empty').text((answer && answer.error) || networkT('The scan failed.')));
			return;
		}
		networkRenderAndroidNetworks(answer.networks || []);
		return;
	}
	networkScan();
});

$(document).on('click', '#network_radio_toggle', function() {
	if ($(this).prop('disabled')) { return; }
	var state = $(this).attr('aria-pressed') === 'true' ? 'off' : 'on';
	var box = $(this);
	box.prop('disabled', true);
	networkPost('radio', { state: state }, function() {
		box.prop('disabled', false);
		networkRefreshAll();
	});
});

$(document).on('change', '#network_manage', function() {
	var box = $(this);
	var on = box.prop('checked') ? 1 : 0;
	box.prop('disabled', true);
	networkPost('manage', { manage: on }, function(response) {
		box.prop('disabled', false);
		if (response.error || response.ok === 0) {
			box.prop('checked', !on);
			$('#network_status_line').text(response.error || networkT('The setting could not be saved.'));
			return;
		}
		networkRefreshAll();
	});
});

$(document).on('click', '#network_apply', function() {
	var button = $(this);
	if (button.prop('disabled')) { return; }
	button.prop('disabled', true);
	networkPost('apply', {}, function(response) {
		button.prop('disabled', false);
		if (response.error || response.ok === 0) {
			$('#network_status_line').text(response.error || networkT('The saved network could not be applied.'));
		}
		networkRefreshAll();
	});
});

