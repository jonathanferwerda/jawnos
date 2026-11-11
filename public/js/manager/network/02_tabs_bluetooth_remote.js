// network/02_tabs_bluetooth_remote.js - the Network app's tabs and Bluetooth
// tab. The tab choice is remembered per browser, and the Bluetooth lists are
// filled from /manager/network/bluetooth/status. Remote Machines is rendered by
// the template from the same remote_machine_lister the Controller keyboard uses.

var network_tab_storage = 'network_tab';

function networkTabValid(tab) {
	return tab === 'network' || tab === 'bluetooth' || tab === 'remote' || tab === 'controller';
}

function networkTabShow(tab, remember) {
	if (!networkTabValid(tab)) { tab = 'network'; }
	$('.network_tab_panel').each(function() {
		var is_tab = $(this).attr('data-network-panel') === tab;
		$(this).prop('hidden', !is_tab);
	});
	$('.network_tab').each(function() {
		var is_tab = $(this).attr('data-network-tab') === tab;
		$(this).toggleClass('is-active', is_tab).attr('aria-selected', is_tab ? 'true' : 'false');
	});
	if (remember) {
		try { localStorage.setItem(network_tab_storage, tab); } catch (error) { /* private mode */ }
	}
	if (tab === 'bluetooth') { networkBluetoothRefresh(); }
	// The Controller's anchor detail is fed by the heartbeat. Paint the saved
	// picture first, then keep it live while the tab is open; the global beat is
	// slower than the Controller's own.
	if (tab === 'controller') {
		networkControllerSnapshotApply();
		networkControllerBeatStart();
		if (typeof stayingAliveNow == 'function') { stayingAliveNow('server'); }
	}
	else { networkControllerBeatStop(); }
}

// The Controller's saved first paint, and the faster beat that keeps it live.
// The server caches the anchors' last full beat, so opening the tab shows the
// windows, roster and track instead of waiting for the next socket beat.
var networkControllerBeatTimer = null;

function networkControllerSnapshotApply() {
	if (typeof stayingAliveOne !== 'function') { return; }
	$.getJSON('/manager/controller/snapshot', function (r) {
		var beats = (r && r.beats) || {};
		Object.keys(beats).forEach(function (app) {
			if (!beats[app]) { return; }
			// A live beat may have painted first; never overwrite it with the cache.
			if ($('.neighbours[app="' + app + '"] .neighbour').length) { return; }
			stayingAliveOne(beats[app]);
		});
	});
}

function networkControllerBeatStart() {
	networkControllerBeatStop();
	networkControllerBeatTimer = setInterval(function () {
		if (document.hidden) { return; }
		if (typeof stayingAliveNow == 'function' && typeof jawnosControllerVisible == 'function' && jawnosControllerVisible()) {
			stayingAliveNow('server');
		}
	}, 5000);
}

function networkControllerBeatStop() {
	if (networkControllerBeatTimer) { clearInterval(networkControllerBeatTimer); networkControllerBeatTimer = null; }
}

function networkBluetoothError(text) {
	$('#network_bluetooth_error').text(text || '');
}

function networkBluetoothButton(action, label, address) {
	return $('<button type="button">')
		.addClass('network_button network_bluetooth_action')
		.attr('data-action', action)
		.attr('data-address', address)
		.text(label);
}

function networkBluetoothRow(device) {
	device = device || {};
	var address = device.address || '';
	var row = $('<div>').addClass('network_wifi_row network_bluetooth_row').attr('data-address', address);
	row.append($('<span>').addClass('network_wifi_name').text(device.name || address || ''));
	row.append($('<span>').addClass('network_bt_addr').text(address));
	if (device.icon) { row.append($('<span>').addClass('network_pill').text(device.icon)); }
	if (device.connected) {
		row.append($('<span>').addClass('network_pill network_up').text(networkT('Connected')));
		row.append(networkBluetoothButton('disconnect', networkLabel('disconnect', 'Disconnect'), address));
	}
	else {
		row.append(networkBluetoothButton('connect', networkLabel('connect', 'Connect'), address));
	}
	if (!device.paired) {
		row.append(networkBluetoothButton('pair', networkLabel('pair', 'Pair'), address));
	}
	if (!device.trusted) {
		row.append(networkBluetoothButton('trust', networkLabel('trust', 'Trust'), address));
	}
	if (device.paired || device.trusted) {
		row.append(networkBluetoothButton('remove', networkLabel('forget', 'Forget'), address));
	}
	return row;
}

function networkBluetoothRenderList(selector, devices, emptyText) {
	var box = $(selector).empty();
	if (!devices || !devices.length) {
		box.append($('<div>').addClass('network_empty').text(emptyText));
		return;
	}
	for (var i = 0; i < devices.length; i++) {
		box.append(networkBluetoothRow(devices[i]));
	}
}

function networkRenderBluetooth(data) {
	data = data || {};
	var power = $('#network_bluetooth_power');
	if (!data.ok) {
		networkBluetoothError(data.error || networkT('The Bluetooth status could not be read.'));
		$('#network_bluetooth_status').text('');
		power.prop('disabled', true).attr('aria-pressed', 'false');
		networkBluetoothRenderList('#network_bluetooth_connected', [], networkT('No Bluetooth device is connected.'));
		networkBluetoothRenderList('#network_bluetooth_paired', [], networkT('No paired Bluetooth devices.'));
		networkBluetoothRenderList('#network_bluetooth_found', [], networkT('Press Scan to list Bluetooth devices.'));
		return;
	}
	networkBluetoothError('');
	var adapter = data.adapter || {};
	var present = !!adapter.present;
	var powered = !!adapter.powered;
	if (!present) {
		$('#network_bluetooth_status').text(networkT('No Bluetooth adapter found.'));
	}
	else {
		var name = adapter.name || adapter.address || '';
		$('#network_bluetooth_status').text(
			networkT('Adapter') + ': ' + name + ' — ' + (powered ? networkT('Powered') : networkT('Off'))
		);
	}
	power.prop('disabled', !present)
		.attr('aria-pressed', powered ? 'true' : 'false')
		.toggleClass('network_off', present && !powered)
		.attr('title', powered ? networkT('Turn the adapter off') : networkT('Turn the adapter on'))
		.text(powered ? networkT('Adapter on') : networkT('Adapter off'));
	$('#network_bluetooth_scan').prop('disabled', !present || !powered);
	networkBluetoothRenderList('#network_bluetooth_connected', data.connected || [],
		networkT('No Bluetooth device is connected.'));
	networkBluetoothRenderList('#network_bluetooth_paired', data.paired || [],
		networkT('No paired Bluetooth devices.'));
	networkBluetoothRenderList('#network_bluetooth_found', data.found || [],
		networkT('Press Scan to list Bluetooth devices.'));
}

function networkBluetoothRefresh() {
	if (!$('#network_app').length || !$('#network_panel_bluetooth').length) { return; }
	networkGet('bluetooth/status', {}, function(data) { networkRenderBluetooth(data); });
}

function networkBluetoothMaybeRefresh() {
	if (!$('#network_app').length || !$('#network_panel_bluetooth').length) { return; }
	if ($('#network_panel_bluetooth').prop('hidden')) { return; }
	networkBluetoothRefresh();
}

$(document).on('click', '.network_tab', function() {
	var tab = $(this).attr('data-network-tab') || 'network';
	networkTabShow(tab, true);
});

$(document).on('click', '#network_bluetooth_power', function() {
	if ($(this).prop('disabled')) { return; }
	var state = $(this).attr('aria-pressed') === 'true' ? 'off' : 'on';
	var button = $(this);
	button.prop('disabled', true);
	networkPost('bluetooth/action', { action: 'power', state: state }, function(response) {
		button.prop('disabled', false);
		if (!response.ok) { networkBluetoothError(response.error || networkT('The adapter could not be changed.')); }
		networkBluetoothRefresh();
	});
});

$(document).on('click', '#network_bluetooth_scan', function() {
	if ($(this).prop('disabled')) { return; }
	var button = $(this);
	button.prop('disabled', true);
	networkPost('bluetooth/scan', { state: 'on' }, function(response) {
		button.prop('disabled', false);
		if (!response.ok) { networkBluetoothError(response.error || networkT('The scan failed.')); }
		networkBluetoothRefresh();
	});
});

$(document).on('click', '.network_bluetooth_action', function() {
	var action = $(this).attr('data-action') || '';
	var address = $(this).attr('data-address') || '';
	if (!action || !address) { return; }
	var button = $(this);
	var send = function() {
		button.prop('disabled', true);
		networkPost('bluetooth/action', { action: action, address: address }, function(response) {
			button.prop('disabled', false);
			if (!response.ok) { networkBluetoothError(response.error || networkT('The Bluetooth action failed.')); }
			else { networkBluetoothError(''); }
			networkBluetoothRefresh();
		});
	};
	if (action === 'remove') {
		jawnosConfirm(networkT('Forget this Bluetooth device?'), send);
		return;
	}
	send();
});

$(document).on('click', '#network_refresh', function() {
	networkBluetoothMaybeRefresh();
});


// ---- the Remote Machines accordion -----------------------------------------
// One shared panel is moved under the machine it belongs to. The row is the
// picker, so the hidden select only feeds the existing command, input and VPN
// scripts; there is no second machine list on screen. A second press closes it.
function networkRemoteControlClose() {
	var panel = $('#remote_control');
	if (!panel.length) { return; }
	panel.attr('hidden', true).appendTo('#network_remote_section .network_section_body');
	$('.network_remote_panel_row').attr('hidden', true);
	$('.network_remote_toggle').attr('aria-expanded', 'false');
}

function networkRemoteControlOpen(button) {
	var btn = $(button);
	var uuid = btn.attr('machine') || '';
	var row = btn.closest('tr');
	var slot_row = row.next('.network_remote_panel_row');
	var slot = slot_row.find('.network_remote_panel_slot').first();
	var panel = $('#remote_control');
	if (!uuid || !slot.length || !panel.length) { return; }
	if (btn.attr('aria-expanded') === 'true') { networkRemoteControlClose(); return; }
	networkRemoteControlClose();
	var select = panel.find('#remote_control_machine_select');
	select.val(uuid);
	var opt = select.find('option').filter(function () { return this.value === uuid; }).first();
	var edge = opt.attr('data-edge') || 'right';
	panel.find('#remote_input_controls').attr('remote_uuid', uuid).attr('data-edge', edge);
	panel.find('#remote_input_edge').val(edge);
	panel.find('#remote_control_name').text(opt.text() || uuid);
	panel.removeAttr('hidden');
	slot.append(panel);
	slot_row.removeAttr('hidden');
	btn.attr('aria-expanded', 'true');
	if (typeof settingSetter == 'function') {
		settingSetter({ app: 'me', setting: 'remote_control_machine', value: uuid });
	}
	// tell the remote-input scripts which machine is picked, then let the VPN
	// button decide whether this machine is one of the tailnet's exit nodes
	select.trigger('change');
	if (typeof jawnosRemoteInputInit === 'function') { jawnosRemoteInputInit(); }
	if (typeof jawnosVpnRefresh === 'function') { jawnosVpnRefresh(); }
}

$(document).on('click', '.network_remote_toggle', function (e) {
	e.preventDefault();
	networkRemoteControlOpen(this);
});

$(document).ready(function() {
	if (!$('#network_app').length) { return; }
	var tab = 'network';
	try { tab = localStorage.getItem(network_tab_storage) || 'network'; } catch (error) { tab = 'network'; }
	networkTabShow(networkTabValid(tab) ? tab : 'network', false);
});

setInterval(function() {
	networkBluetoothMaybeRefresh();
}, 15000);
