// The Market app: the shopping side of the warehouse. A vendors dropdown scopes
// the list, the Shopping List tab holds what to buy (each row a need/want dial,
// Enter adds an item), and the Shopping tab reads the same list through a
// needs/wants/all filter. The server pushes marketReload() on every change.
var marketTab = 'list';
var marketFilter = 'all';
var marketVendor = '';
var marketList = '';

$(document).on('click', '.market_toggle', function() {
	marketOpener();
});

function marketOpener() {
	marketTab = 'list';
	marketFilter = 'all';
	marketVendor = '';
	// the list a person last shopped is the one they come back to
	try { marketList = localStorage.getItem('marketListChoice') || ''; } catch (e) { marketList = ''; }
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/market/refresh',
		type: 'POST',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response.window);
			// at a shop the applicable list (or the only one) opens ready
			var nearby = $('#market_nearby .market_nearby_list');
			if (nearby.length === 1) {
				marketList = nearby.attr('list');
				try { localStorage.setItem('marketListChoice', marketList); } catch (e) {}
			}
			marketApply();
		}
	});
}

// The server pushes this the moment the list changes, so an open Market window
// stays live instead of waiting for a reopen.
function marketReload() {
	var w = $('.wind[app="market"]');
	if (!w.length) { return; }
	$.get('/manager/market', { timestamp: Date.now() }, function(response) {
		var fresh = $('<div></div>').append(response.html || '').find('#market_body');
		if (!fresh.length) { return; }
		w.find('#market_body').replaceWith(fresh);
		marketApply();
	}, 'json');
}

// Show the active tab, recall the vendor and filter, and hide rows the vendor or
// the needs/wants filter excludes.
function marketApply() {
	var body = $('#market_body');
	if (!body.length) { return; }
	body.find('#market_list_panel').toggle(marketTab === 'list');
	body.find('#market_shopping').toggle(marketTab === 'shopping');
	body.find('#market_vendor').val(marketVendor);
	body.find('#market_filter').val(marketFilter);
	body.find('#market_list').val(marketList);
	body.find('.market_row').each(function() {
		var r = $(this);
		var vendor_ok = (marketVendor === '') || (r.attr('data-vendor') === marketVendor);
		var list_ok = (marketList === '') || (r.attr('data-list') === marketList);
		var kind_ok = true;
		if (r.closest('#market_shopping_rows').length) {
			kind_ok = (marketFilter === 'all') || (r.attr('data-kind') === marketFilter);
		}
		r.toggle(vendor_ok && list_ok && kind_ok);
	});
	body.find('#market_cart_count').text(body.find('#market_list_rows .market_row[data-cart="1"]').length);
}

// Enter always adds an item (no shift-for-newline here), like Notes.
$(document).on('keydown', '#market_item_input', function(e) {
	if (e.key === 'Enter') {
		e.preventDefault();
		marketAdd();
	}
});

$(document).on('click', '#market_item_add', function() {
	marketAdd();
});

function marketAdd() {
	var input = $('#market_item_input');
	var text = input.val();
	if (text === undefined || text.replace(/\s/g, '') === '') { return; }
	$.post('/manager/market/item_add', { text: text, vendor: marketVendor, list: marketList, timestamp: Date.now() }, function() {
		input.val('');
	});
}

$(document).on('change', '.market_kind', function() {
	$.post('/manager/market/item_kind', { uuid: $(this).attr('uuid'), kind: $(this).val(), timestamp: Date.now() });
});

$(document).on('click', '.market_delete', function() {
	$.post('/manager/market/item_delete', { uuid: $(this).attr('uuid'), timestamp: Date.now() });
});

// The tick and the cart, and the two ways out: Checkout turns the cart into
// purchases, Cancel empties it back onto the list.
$(document).on('click', '.market_pick', function() {
	var r = $(this).closest('.market_row');
	$.post('/manager/market/item_flag', { uuid: $(this).attr('uuid'), flag: 'pick', on: (r.attr('data-picked') === '1' ? 0 : 1), timestamp: Date.now() });
});

$(document).on('click', '.market_cart', function() {
	var r = $(this).closest('.market_row');
	$.post('/manager/market/item_flag', { uuid: $(this).attr('uuid'), flag: 'cart', on: (r.attr('data-cart') === '1' ? 0 : 1), timestamp: Date.now() });
});

$(document).on('click', '#market_cancel', function() {
	$.post('/manager/market/cancel', { timestamp: Date.now() });
});

$(document).on('click', '#market_checkout', function() {
	$.post('/manager/market/checkout', { vendor: marketVendor, list: marketList, timestamp: Date.now() }, function(response) {
		if (response && response.transaction) { marketCheckoutOpen(response.transaction); }
	}, 'json');
});

// Checkout leaves the money side to a person: open the list's category with its
// expense transaction filled from the cart, so the amounts (and the quantity and
// packaging) can be checked and saved by hand. The stored run is re-stamped just
// before the retrieve: opening the movement runs the form's own saver, which
// would otherwise see an empty form and drop it.
function marketCheckoutOpen(t) {
	if (!t || !t.app) { return; }
	var app = t.app;
	var stored = t.storage ? JSON.stringify(t.storage) : '';
	if (stored) { localStorage.setItem('transactionSaver_' + app, stored); }
	appointmentGrabber(app, Date.now());
	var tries = 0;
	var iv = setInterval(function() {
		var w = $('.appointment[app="' + app + '"]');
		if (!w.length) { if (++tries > 20) { clearInterval(iv); } return; }
		clearInterval(iv);
		// reset opens the form; a form already open must not be toggled shut
		if (!w.find('.app_details').first().is(':visible')) {
			w.find('.app_act.reset[app="' + app + '"]').first().trigger('click');
		}
		setTimeout(function() {
			var m = w.find('.app_details .movement');
			if (m.length) { m.val('expense').trigger('change'); }
			var fill = function() {
				if (stored) { localStorage.setItem('transactionSaver_' + app, stored); }
				if (t.account) { w.find('.app_details .account').val(t.account); }
				if (typeof transactionStorageRetriever === 'function') { transactionStorageRetriever(app); }
			};
			setTimeout(fill, 800);
			setTimeout(fill, 1600);
		}, 500);
	}, 300);
}

var marketScanSession = null;      // the session this machine owns
var marketScanPollTimer = null;
var marketScanRapid = false;       // re-open the local scanner after each read
var marketScanHouseDevices = [];   // the camera tabs the house offered last time

$(document).on('click', '#market_scan', function() { marketScan(); });

// The phone (or the local bridge) hands a code here. A session on this machine
// collects it; a phone's session forwards it to the machine that started it.
window.jawnScanResult = function(code) {
	if (window.marketPhoneSession) { marketPhoneResult(code); return; }
	if (!code) { return; }
	marketBarcode(code);
	if (marketScanRapid && window.JawnScan && typeof window.JawnScan.scan === 'function') {
		setTimeout(function() { if (marketScanRapid) { window.JawnScan.scan(); } }, 450);
	}
};

// Record one code in the active session; the server resolves it and keeps it for
// the Done press. With no session, the old one-shot add still works.
function marketBarcode(code) {
	if (marketScanSession && marketScanSession.uuid) {
		$.post('/manager/market/scan/collect', { session: marketScanSession.uuid, barcode: code, timestamp: Date.now() }, function(response) {
			if (response && response.item) { marketScanSessionRefresh(); }
		}, 'json');
		return;
	}
	$.post('/manager/market/scan', { barcode: code, list: marketList, vendor: marketVendor, timestamp: Date.now() });
}

// The phone side of a session: post the code to our own server (which forwards
// it to the peer that owns the session), then re-open the scanner for the next.
function marketPhoneResult(code) {
	if (!window.marketPhoneSession) { return; }
	if (!code) {
		$.post('/manager/market/scan/collect', { session: window.marketPhoneSession, origin_machine: window.marketPhoneOrigin, device_id: window.marketPhoneDeviceId || '', stop: 1, timestamp: Date.now() });
		window.marketPhoneSession = '';
		window.marketPhoneRapid = false;
		return;
	}
	$.post('/manager/market/scan/collect', { session: window.marketPhoneSession, origin_machine: window.marketPhoneOrigin, device_id: window.marketPhoneDeviceId || '', barcode: code, timestamp: Date.now() }, function() {
		if (window.marketPhoneRapid) {
			setTimeout(function() {
				if (!window.marketPhoneRapid) { return; }
				if (window.JawnScan && typeof window.JawnScan.scan === 'function') { window.JawnScan.scan(); }
				else { window.marketPhoneCamera({ session: window.marketPhoneSession, origin_machine: window.marketPhoneOrigin, rapid: true }); }
			}, 450);
		}
	});
}

window.marketScanArrived = function() {
	var b = $('#market_scan');
	if (!b.length) { return; }
	b.css('background-color', 'green');
	setTimeout(function() { b.css('background-color', ''); }, 1200);
};

// Scan a barcode. The machine remembers the device it used last (a phone, say)
// and starts there at once; with no memory it offers this machine and the house.
function marketScan() {
	$.get('/manager/market/cameras', {
		timestamp: Date.now(),
		browser_tab_id: sessionStorage.getItem('browser_tab_id') || ''
	}, function(response) {
		var devices = (response && response.devices) || [];
		marketScanHouseDevices = devices;
		var remembered = null;
		try { remembered = JSON.parse(localStorage.getItem('marketScanDevice') || 'null'); } catch (e) { remembered = null; }
		if (remembered && remembered.kind === 'local') { marketScanBegin({ kind: 'local', label: 'this machine' }); return; }
		if (remembered && remembered.kind === 'remote') {
			var pick = null;
			devices.forEach(function(d) { if (d.machine === remembered.machine) { pick = d; } });
			if (pick) { marketScanBegin({ kind: 'remote', machine: pick.machine, browser_tab_id: pick.browser_tab_id, label: pick.label }); return; }
		}
		marketScanChooser(devices);
	}, 'json').fail(function() { marketScanChooser([]); });
}

function marketScanHere() {
	if (window.JawnScan && typeof window.JawnScan.scan === 'function') {
		marketScanRapid = true;
		window.JawnScan.scan();
		return;
	}
	if ('BarcodeDetector' in window && navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
		marketScanRapid = true;
		marketScanCamera();
		return;
	}
	marketBarcodePrompt();
}

// A code typed by hand, in the app rather than the browser's own prompt (which
// wears the page URL and looks nothing like the rest of the house).
function marketBarcodePrompt() {
	marketReceiptPanel('<div style="padding:18px;max-width:560px;margin:0 auto;">'
		+ '<div style="font-size:22px;font-weight:700;">A code</div>'
		+ '<div style="margin-top:12px;display:flex;gap:8px;">'
		+ '<input id="market_barcode_typed" type="text" placeholder="Barcode / product code" style="flex:1 1 auto;font-size:18px;padding:6px;">'
		+ '<button id="market_barcode_typed_go" style="font-size:17px;padding:8px 14px;">Add</button>'
		+ '</div>'
		+ '<div style="margin-top:12px;"><button id="market_scan_chooser_close" style="font-size:15px;">Cancel</button></div>'
		+ '</div>');
	$('#market_barcode_typed').focus();
}

$(document).on('keydown', '#market_barcode_typed', function(e) {
	if (e.key === 'Enter') { e.preventDefault(); $('#market_barcode_typed_go').trigger('click'); }
});

$(document).on('click', '#market_barcode_typed_go', function() {
	var code = $('#market_barcode_typed').val();
	if (code) { marketBarcode(code); }
	if (marketScanSession) { marketScanSessionShow(marketScanSession); }
	else { marketReceiptPanel(); }
});

function marketScanChooser(devices) {
	var h = '<div style="padding:18px;max-width:560px;margin:0 auto;">'
		+ '<div style="font-size:22px;font-weight:700;margin-bottom:12px;">Scan a barcode</div>'
		+ '<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">'
		+ '<select id="market_scan_device" style="font-size:17px;padding:6px;flex:1 1 220px;"><option value="local">This machine</option>';
	devices.forEach(function(d) {
		h += '<option value="' + marketEsc(d.browser_tab_id) + '" data-machine="' + marketEsc(d.machine || '') + '">' + marketEsc(d.label) + '</option>';
	});
	h += '</select> <button id="market_scan_remote_go" style="font-size:17px;padding:8px 14px;">Start scanning</button>'
		+ '</div>'
		+ '<div style="margin-top:14px;"><button id="market_scan_chooser_close" style="font-size:15px;">Cancel</button></div>'
		+ '<div style="margin-top:10px;font-size:14px;opacity:.65;">The chosen device opens its own scanner and the reads collect here; Done puts them on the list.</div>'
		+ '</div>';
	marketReceiptPanel(h);
}

$(document).on('click', '#market_scan_chooser_close', function() {
	if (marketScanSession) { marketScanSessionShow(marketScanSession); }
	else { marketReceiptPanel(); }
});

$(document).on('click', '#market_scan_remote_go', function() {
	var selected = $('#market_scan_device option:selected');
	var value = selected.val();
	var device;
	if (value === 'local') { device = { kind: 'local', label: 'this machine' }; }
	else { device = { kind: 'remote', machine: selected.attr('data-machine') || '', browser_tab_id: value, label: selected.text() }; }
	marketReceiptPanel();
	marketScanBegin(device);
});

// Start a session: the server tells a remote device to begin, and a local one is
// opened here; either way the session page lists what was read.
function marketScanBegin(device) {
	marketScanSession = null;
	localStorage.setItem('marketScanDevice', JSON.stringify(device));
	marketReceiptPanel('<div style="padding:18px;font-size:18px;">Starting the scanner...</div>');
	$.post('/manager/market/scan/session/start', {
		device: JSON.stringify(device), list: marketList, vendor: marketVendor, timestamp: Date.now()
	}, function(response) {
		if (!response || !response.session) {
			marketReceiptPanel('<div style="padding:18px;">The scan could not start. <button id="market_receipt_close">Close</button></div>');
			return;
		}
		marketScanSession = response.session;
		marketScanSessionShow(response.session);
		marketScanSessionPoll(response.session.uuid);
		// a computer with a webcam is read by zbar on the server, so the session
		// page itself is the live view; otherwise open the browser's own scanner
		if (device.kind === 'local' && !response.session.camera) { marketScanHere(); }
	}, 'json');
}

function marketScanSessionShow(s) {
	var h = '<div style="padding:10px;font-size:18px;">';
	h += '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">'
		+ '<b id="market_scan_session_heading"></b>'
		+ '<span id="market_scan_session_count" style="opacity:.6;font-size:14px;">' + (s.count || 0) + '</span>'
		+ '<span style="flex:1 1 auto;"></span>'
		+ '<button id="market_scan_session_done">Done</button>'
		+ '<button id="market_scan_session_cancel">Cancel</button>'
		+ '</div>';
	h += '<div id="market_scan_session_devices" style="margin-top:4px;font-size:14px;"></div>';
	// the picker stays here even after a device is chosen, so a second input can
	// join the run (a phone beside the webcam) or the machine can be switched
	h += '<div style="margin-top:6px;display:flex;gap:6px;align-items:center;">'
		+ '<select id="market_scan_session_device" style="font-size:15px;flex:1 1 200px;">' + marketScanDeviceOptions() + '</select>'
		+ '<button id="market_scan_session_device_add" style="font-size:15px;">Add input</button>'
		+ '</div>';
	h += '<div id="market_scan_session_note" style="font-size:14px;opacity:.65;margin-top:4px;"></div>';
	h += '<div id="market_scan_session_items" style="margin-top:8px;">';
	(s.items || []).forEach(function(it) { h += marketScanItemRow(it); });
	h += '</div></div>';
	marketReceiptPanel(h);
	marketScanSessionDevicesShow(s);
	marketScanDevicesLoad(function() {
		var sel = $('#market_scan_session_device');
		if (!sel.length) { return; }
		var current = sel.val();
		sel.html(marketScanDeviceOptions());
		if (current && sel.find('option[value="' + current + '"]').length) { sel.val(current); }
	});
}

function marketScanDeviceOptions() {
	var h = '<option value="">Add another input...</option>';
	h += '<option value="local">This machine</option>';
	(marketScanHouseDevices || []).forEach(function(d) {
		h += '<option value="' + marketEsc(d.browser_tab_id) + '" data-machine="' + marketEsc(d.machine || '') + '">' + marketEsc(d.label) + '</option>';
	});
	return h;
}

// The house camera list, for a session page opened without it (a reload, or a
// remembered device that started straight away).
function marketScanDevicesLoad(done) {
	if ((marketScanHouseDevices || []).length) { if (done) { done(); } return; }
	$.get('/manager/market/cameras', {
		timestamp: Date.now(),
		browser_tab_id: sessionStorage.getItem('browser_tab_id') || ''
	}, function(response) {
		marketScanHouseDevices = (response && response.devices) || [];
		if (done) { done(); }
	}, 'json').fail(function() { if (done) { done(); } });
}

// The inputs on this run: one chip each, with a way to stop just that one.
function marketScanSessionDevicesShow(s) {
	var devs = (s && s.devices) || [];
	var box = $('#market_scan_session_devices');
	if (!box.length) { return; }
	if (!devs.length) {
		box.html('<span style="opacity:.6;">No input is scanning - add one below.</span>');
	}
	else {
		var h = '<span style="opacity:.65;">Scanning:</span> ';
		devs.forEach(function(d) {
			h += '<span style="display:inline-block;border:1px solid var(--line);border-radius:10px;padding:1px 6px;margin:2px 4px 2px 0;">'
				+ marketEsc(d.label || 'Device')
				+ ' <button class="market_scan_device_remove" data-id="' + marketEsc(d.id || '') + '" style="font-size:12px;padding:0 4px;" title="Stop this input">x</button></span>';
		});
		box.html(h);
	}
	var heading = 'Scanning';
	if (devs.length === 1) { heading = 'Scanning on ' + (devs[0].label || 'this machine'); }
	else if (devs.length > 1) { heading = 'Scanning on ' + devs.length + ' inputs'; }
	$('#market_scan_session_heading').text(heading);
	$('#market_scan_session_note').text((s && s.camera ? 'The webcam is reading as you go; ' : '')
		+ 'Scan as many as you like; Done puts them on the list, Cancel throws them away.');
}

$(document).on('click', '#market_scan_session_device_add', function() {
	var selected = $('#market_scan_session_device option:selected');
	var value = selected.val();
	if (!value) { return; }
	var device;
	if (value === 'local') { device = { kind: 'local', label: 'this machine' }; }
	else { device = { kind: 'remote', machine: selected.attr('data-machine') || '', browser_tab_id: value, label: selected.text() }; }
	$.post('/manager/market/scan/session/device/add', { device: JSON.stringify(device), timestamp: Date.now() }, function(response) {
		if (!response || !response.session) { return; }
		marketScanSession = response.session;
		marketScanSessionDevicesShow(response.session);
		$('#market_scan_session_device').val('');
		if (value === 'local' && !response.session.camera) { marketScanHere(); }
	}, 'json');
});

$(document).on('click', '.market_scan_device_remove', function() {
	var id = $(this).attr('data-id') || '';
	if (!id) { return; }
	$.post('/manager/market/scan/session/device/remove', { id: id, timestamp: Date.now() }, function(response) {
		if (!response || !response.session) { return; }
		marketScanSession = response.session;
		marketScanSessionDevicesShow(response.session);
	}, 'json');
});

function marketScanItemRow(it) {
	var name = it.formatted || it.item || it.code;
	var h = '<div class="market_scan_item" data-code="' + marketEsc(it.code) + '" style="border-bottom:1px solid var(--line);padding:5px;font-size:17px;">'
		+ '<b>' + marketEsc(name) + '</b>';
	if (it.raw_formatted && it.raw_formatted.toLowerCase() !== String(name).toLowerCase()) {
		h += ' <span style="font-size:13px;opacity:.55;">' + marketEsc(it.raw_formatted) + '</span>';
	}
	h += ' <span style="font-size:13px;opacity:.5;float:right;">' + marketEsc(it.code) + '</span></div>';
	return h;
}

function marketScanSessionRefresh() {
	if (!marketScanSession || !marketScanSession.uuid) { return; }
	$.get('/manager/market/scan/session', { timestamp: Date.now() }, function(s) {
		if (!s || s.uuid !== marketScanSession.uuid) { return; }
		marketScanSession = s;
		var box = $('#market_scan_session_items');
		if (!box.length) { clearInterval(marketScanPollTimer); return; }
		if (s.status === 'cancelled') {
			clearInterval(marketScanPollTimer);
			marketScanRapid = false;
			marketReceiptPanel('<div style="padding:18px;font-size:18px;">Scan stopped. <button id="market_receipt_close">Close</button></div>');
			return;
		}
		if (s.status === 'done') { clearInterval(marketScanPollTimer); marketReceiptPanel(); return; }
		box.empty();
		(s.items || []).forEach(function(it) { box.append(marketScanItemRow(it)); });
		$('#market_scan_session_count').text(s.count || 0);
		marketScanSessionDevicesShow(s);
	}, 'json');
}

function marketScanSessionPoll(uuid) {
	if (marketScanPollTimer) { clearInterval(marketScanPollTimer); }
	marketScanPollTimer = setInterval(marketScanSessionRefresh, 1000);
}

$(document).on('click', '#market_scan_session_done', function() {
	clearInterval(marketScanPollTimer);
	marketScanRapid = false;
	$.post('/manager/market/scan/session/done', { timestamp: Date.now() }, function() {
		marketScanSession = null;
		marketReceiptPanel();
	});
});

$(document).on('click', '#market_scan_session_cancel', function() {
	clearInterval(marketScanPollTimer);
	marketScanRapid = false;
	$.post('/manager/market/scan/session/cancel', { timestamp: Date.now() }, function() {
		marketScanSession = null;
		marketReceiptPanel();
	});
});

// The phone side of a scan session: the Google scanner (via JawnScan) opens as
// if the phone had pressed Scan, each read goes back to the machine that started
// the session, and the scanner re-opens for the next one until the person backs
// out or the computer cancels.
window.marketPhoneCamera = function(opts) {
	opts = opts || {};
	window.marketPhoneSession = opts.session || '';
	window.marketPhoneOrigin = opts.origin_machine || '';
	window.marketPhoneDeviceId = opts.device_id || '';
	window.marketPhoneRapid = !!opts.rapid;
	if (window.JawnScan && typeof window.JawnScan.scan === 'function') {
		window.JawnScan.scan();
		return;
	}
	if (document.getElementById('market_phone_camera')) { return; }
	var everything = $('#everything');
	everything.hide();
	$('<div id="market_phone_camera" style="position:fixed;left:0;top:0;width:100%;height:100%;z-index:99999;background:#000;">'
		+ '<video id="market_phone_video" playsinline muted style="width:100%;height:100%;object-fit:cover;"></video>'
		+ '<button id="market_phone_cancel" style="position:absolute;top:12px;right:12px;font-size:18px;">Cancel</button>'
		+ '<div id="market_phone_hint" style="position:absolute;bottom:24px;left:0;width:100%;text-align:center;color:#fff;font-size:18px;">Point at the barcode</div>'
		+ '</div>').appendTo('body');
	var done = false;
	var stream = null;
	var iv = null;
	var finish = function(code) {
		if (done) { return; }
		done = true;
		if (iv) { clearInterval(iv); }
		if (stream) { stream.getTracks().forEach(function(t) { t.stop(); }); }
		$('#market_phone_camera').remove();
		everything.show();
		marketPhoneResult(code || '');
	};
	$('#market_phone_cancel').on('click', function() { finish(''); });
	if (!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)) {
		$('#market_phone_hint').text('This browser cannot open the camera.');
		return;
	}
	navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } }).then(function(s) {
		stream = s;
		var v = document.getElementById('market_phone_video');
		v.srcObject = s;
		v.play();
		var detector = null;
		try { detector = ('BarcodeDetector' in window) ? new BarcodeDetector() : null; } catch (e) { detector = null; }
		if (!detector) {
			// no in-browser reader: hand it to the app's own scanner
			finish('');
			if (window.JawnScan && typeof window.JawnScan.scan === 'function') { window.JawnScan.scan(); }
			else { window.alert('This browser cannot read barcodes.'); }
			return;
		}
		iv = setInterval(function() {
			detector.detect(v).then(function(codes) {
				if (codes && codes.length && codes[0].rawValue) { finish(codes[0].rawValue); }
			}).catch(function() {});
		}, 400);
		setTimeout(function() { if (!done) { finish(''); } }, 30000);
	}).catch(function() {
		$('#market_phone_hint').text('The camera could not be opened.');
	});
};

window.marketPhoneScanStop = function() {
	window.marketPhoneRapid = false;
	window.marketPhoneSession = '';
	window.marketPhoneDeviceId = '';
	// put the app's own scanner sheet away when the page is still running
	if (window.JawnScan && typeof window.JawnScan.close === 'function') {
		try { window.JawnScan.close(); } catch (e) {}
	}
};

function marketScanCamera() {
	navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } }).then(function(stream) {
		var video = document.createElement('video');
		video.setAttribute('playsinline', 'playsinline');
		video.setAttribute('muted', 'muted');
		video.srcObject = stream;
		var done = false;
		var stop = function() { if (!done) { done = true; clearInterval(iv); stream.getTracks().forEach(function(t) { t.stop(); }); } };
		var detector;
		try { detector = new window.BarcodeDetector(); } catch (e) { detector = null; }
		if (!detector) { stop(); marketBarcodePrompt(); return; }
		video.play();
		var iv = setInterval(function() {
			detector.detect(video).then(function(codes) {
				if (codes && codes.length && codes[0].rawValue) {
					var code = codes[0].rawValue;
					stop();
					marketBarcode(code);
					if (marketScanRapid) { setTimeout(marketScanCamera, 400); }
				}
			}).catch(function() {});
		}, 400);
		setTimeout(stop, 30000);
	}).catch(function() {
		marketBarcodePrompt();
	});
}


$(document).on('click', '.market_tab', function() {
	marketTab = $(this).attr('tab');
	marketApply();
});

$(document).on('change', '#market_vendor', function() {
	marketVendor = $(this).val();
	marketApply();
});

$(document).on('change', '#market_list', function() {
	marketList = $(this).val();
	try { localStorage.setItem('marketListChoice', marketList); } catch (e) {}
	marketApply();
});

$(document).on('click', '.market_nearby_list', function() {
	marketList = $(this).attr('list');
	try { localStorage.setItem('marketListChoice', marketList); } catch (e) {}
	marketApply();
});

$(document).on('change', '#market_filter', function() {
	marketFilter = $(this).val();
	marketApply();
});

// Read a receipt. The scanner (the ADF takes the whole receipt in one pass) or a
// photo yields one or more pages; the server reads them with the vision model and
// hands back the lines, shown for a confirm before any of it is written. Adding
// to cart links the lines into the list in the cart, so Checkout still writes the
// purchases - the same two steps as a shopping run.
$(document).on('click', '#market_receipt', function() { marketReceiptChooser(); });

var marketScanCancelling = '';

$(document).on('click', '.market_receipt_go', function() {
	var feed = $(this).attr('feed');
	if (!feed) { $('#market_receipt_file').trigger('click'); return; }
	var scan_id = String(Date.now()) + String(Math.floor(Math.random() * 1000000));
	marketScanCancelling = '';
	marketReceiptPanel('<div style="padding:10px;font-size:20px;">Scanning... '
		+ '<button id="market_scan_cancel" scan_id="' + scan_id + '">Cancel</button>'
		+ '<div id="market_scan_log" style="font-size:19px;opacity:.85;margin-top:8px;min-height:1.4em;"></div>'
		+ '<div id="market_scan_pages" style="margin-top:8px;"></div></div>');
	marketScanPoll(scan_id);
	$.post('/manager/market/receipt', { feed: feed, scan_id: scan_id, vendor: marketVendor, list: marketList, timestamp: Date.now() }, function(response) {
		if (marketScanCancelling === scan_id) { marketScanCancelling = ''; return; }
		marketReceiptShow(response);
	}, 'json').fail(function() {
		if (marketScanCancelling === scan_id) { marketScanCancelling = ''; return; }
		marketReceiptShow({ error: 'the scan could not be read' });
	});
});

$(document).on('click', '#market_scan_cancel', function() {
	var id = $(this).attr('scan_id') || '';
	marketScanCancelling = id;
	if (id) { $.post('/manager/market/receipt/cancel', { scan_id: id, timestamp: Date.now() }); }
	marketReceiptPanel();
});

// While a scanner run is in progress, show the scanner's own line and each page
// the moment its file lands. scanimage writes a page only when it is complete,
// so the log is the truly live part and each page pops in as it finishes; the
// poll is short so a page shows the instant it does.
function marketScanPoll(scan_id) {
	var poll = setInterval(function() {
		$.get('/manager/market/receipt/progress', { scan_id: scan_id }, function(p) {
			if (!$('#market_scan_pages').length) { clearInterval(poll); return; }
			$('#market_scan_log').text((p.log || []).slice(-1)[0] || '');
			(p.pages || []).forEach(function(pg) {
				if ($('#market_scan_pages img[data-page="' + pg.page + '"]').length) { return; }
				$('#market_scan_pages').append('<a href="' + pg.url + '" target="_blank"><img data-page="' + pg.page + '" src="' + pg.url + '" style="height:180px;margin-right:6px;border:1px solid var(--line);"></a>');
			});
		}, 'json');
	}, 700);
}

$(document).on('change', '#market_receipt_file', function() {
	var files = this.files;
	if (!files || !files.length) { return; }
	var fd = new FormData();
	fd.append('image', files[0]);
	fd.append('vendor', marketVendor);
	fd.append('list', marketList);
	fd.append('timestamp', Date.now());
	marketReceiptPanel('<div style="padding:12px;font-size:17px;">Reading the receipt...</div>');
	$.ajax({
		url: '/manager/market/receipt', type: 'POST', data: fd, processData: false, contentType: false, dataType: 'json',
		success: function(response) { marketReceiptShow(response); },
		error: function() { marketReceiptShow({ error: 'the photo could not be read' }); }
	});
	this.value = '';
});

$(document).on('click', '#market_receipt_close', function() { marketReceiptPanel(); });

$(document).on('click', '#market_receipt_apply', function() {
	var lines = [];
	$('#market_receipt_panel .market_receipt_line').each(function() {
		var r = $(this);
		if (!r.find('.market_receipt_include').prop('checked')) { return; }
		lines.push({
			include: 1,
			item: r.find('.market_receipt_item').val(),
			description: r.attr('data-description'),
			code: r.attr('data-code'),
			qty: r.find('.market_receipt_qty').val(),
			price: r.find('.market_receipt_price').val()
		});
	});
	if (!lines.length) { marketReceiptPanel(); return; }
	var panel = $('#market_receipt_panel');
	$.post('/manager/market/receipt/apply', {
		lines: JSON.stringify(lines),
		vendor: marketVendor || panel.attr('data-vendor') || '', list: marketList,
		total: $('#market_receipt_total').val() || '',
		date: $('#market_receipt_date').val() || '',
		payment_method: $('#market_receipt_payment').val() || '',
		payment_ref: $('#market_receipt_payment_ref').val() || '',
		account: $('#market_receipt_account').val() || '',
		files: panel.attr('data-files') || '[]',
		timestamp: Date.now()
	}, function() { marketReceiptPanel(); });
});

// undefined hides the panel; a string fills and shows it.
function marketReceiptPanel(html) {
	var panel = $('#market_receipt_panel');
	if (html === undefined) { panel.hide().empty(); return; }
	panel.html(html).show();
}

function marketReceiptChooser() {
	var feeds = marketScanFeeds();
	var h = '<div style="padding:10px;">'
		+ '<b style="font-size:18px;">Read a receipt</b>'
		+ '<div style="margin-top:8px;">';
	if (feeds.indexOf('adf') !== -1) { h += '<button class="market_receipt_go" feed="adf">Scan (ADF)</button> '; }
	if (feeds.indexOf('flatbed') !== -1) { h += '<button class="market_receipt_go" feed="flatbed">Scan (flatbed)</button> '; }
	h += '<button class="market_receipt_go" feed="">Photo / file</button> '
		+ '<button id="market_receipt_close">Cancel</button>'
		+ '</div>'
		+ '<div style="margin-top:8px;font-size:14px;opacity:.7;">'
		+ (feeds.length ? 'The ADF takes the whole receipt in one pass; a long receipt is two flatbed pages.' : 'No scanner on this machine - load a photo or file of the receipt.')
		+ '</div>'
		+ '</div>';
	marketReceiptPanel(h);
}

// The scan feeds this machine offers, written on the body by the server from the
// capability table (a computer has the ADF and the flatbed, a server neither), so
// a machine with no scanner does not offer a scan that would only fail.
function marketScanFeeds() {
	var s = $('#market_body').attr('data-scan') || '';
	return s ? s.split(',') : [];
}

// The kept receipts pane: open and close, and put a whole kept receipt back on
// the list (the same apply the confirm panel uses, so Checkout still writes it).
$(document).on('click', '#market_receipts_open', function() { $('#market_receipts').show(); });

$(document).on('click', '#market_receipts_close', function() { $('#market_receipts').hide(); });

$(document).on('click', '.market_receipt_readd', function() {
	var row = $(this).closest('.market_receipt_row');
	$.post('/manager/market/receipt/apply', {
		lines: row.attr('data-apply'),
		files: row.attr('data-files'),
		total: row.attr('data-total') || '',
		date: row.attr('data-date') || '',
		payment_method: row.attr('data-payment') || '',
		payment_ref: row.attr('data-payment-ref') || '',
		account: row.attr('data-account') || '',
		vendor: marketVendor || row.attr('data-vendor') || '',
		list: marketList,
		timestamp: Date.now()
	}, function() { $('#market_receipts').hide(); });
});

function marketReceiptShow(response) {
	if (!response || response.error) {
		marketReceiptPanel('<div style="padding:10px;font-size:17px;">' + marketEsc((response && response.error) || 'nothing to read') + ' <button id="market_receipt_close">Close</button></div>');
		return;
	}
	var lines = response.lines || [];
	var images = response.images || [];
	var h = '<div style="display:flex;flex-wrap:wrap;gap:10px;align-items:flex-start;padding:6px;font-size:17px;">';
	// the paper, at the full width of its column (click a page to open it full size)
	h += '<div style="flex:1 1 380px;min-width:300px;max-height:78vh;overflow:auto;border:1px solid var(--line);">';
	if (images.length) {
		images.forEach(function(img) {
			h += '<a href="' + img.url + '" target="_blank"><img src="' + img.url + '" style="width:100%;display:block;"></a>';
		});
	}
	else { h += '<div style="padding:10px;font-size:15px;opacity:.7;">The pages are not on disk.</div>'; }
	h += '</div>';
	// what was read, editable, so the date and the tender can be checked against the paper
	h += '<div style="flex:1 1 380px;min-width:300px;">';
	h += '<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">'
		+ '<b>' + marketEsc(response.vendor_formatted || response.vendor || 'Receipt') + '</b>'
		+ '<label style="font-size:14px;">date <input id="market_receipt_date" type="text" value="' + marketEsc(response.date || '') + '" style="width:110px;"></label>'
		+ '<label style="font-size:14px;">total <input id="market_receipt_total" type="text" value="' + marketEsc(response.total === null || response.total === undefined ? '' : response.total) + '" style="width:80px;"></label>'
		+ '</div>';
	h += '<div style="display:flex;gap:8px;align-items:center;margin-top:4px;flex-wrap:wrap;">'
		+ '<label style="font-size:14px;">paid by <input id="market_receipt_payment" type="text" value="' + marketEsc(response.payment_method || '') + '" style="width:110px;"></label>'
		+ '<label style="font-size:14px;">ref <input id="market_receipt_payment_ref" type="text" value="' + marketEsc(response.payment_ref || '') + '" style="width:70px;"></label>'
		+ '<label style="font-size:14px;">account <select id="market_receipt_account"><option value="">(choose)</option>';
	(response.accounts || []).forEach(function(a) {
		h += '<option value="' + marketEsc(a.app) + '"' + (a.app === response.account ? ' selected' : '') + '>' + marketEsc(a.name) + '</option>';
	});
	h += '</select></label></div>';
	h += '<div style="margin-top:8px;"><button id="market_receipt_apply">Add to cart</button> <button id="market_receipt_close">Cancel</button> <span style="font-size:13px;opacity:.6;">tick the lines to keep</span></div>';
	h += '<div style="margin-top:6px;">';
	if (!lines.length) { h += '<div style="padding:8px;font-size:15px;opacity:.7;">No lines were read.</div>'; }
	lines.forEach(function(l) {
		h += '<div class="market_receipt_line" data-description="' + marketEsc(l.description) + '" data-code="' + marketEsc(l.code || '') + '" style="border-bottom:1px solid var(--line);padding:4px;font-size:16px;">';
		h += '<input class="market_receipt_include" type="checkbox" checked style="vertical-align:middle;"> ';
		h += '<input class="market_receipt_item" type="text" value="' + marketEsc(l.item_formatted || l.item) + '" style="width:40%;"> ';
		h += 'x<input class="market_receipt_qty" type="text" value="' + marketEsc(l.qty) + '" style="width:9%;"> ';
		h += '@<input class="market_receipt_price" type="text" value="' + marketEsc(l.price === null || l.price === undefined ? '' : l.price) + '" style="width:14%;"> ';
		if (l.on_list) { h += '<span style="font-size:13px;opacity:.7;">on list</span> '; }
		else if (l.matched_by) { h += '<span style="font-size:13px;opacity:.7;">' + marketEsc(l.matched_by) + '</span> '; }
		if (l.description && l.description.toLowerCase() !== String(l.item || '').toLowerCase()) {
			h += '<span style="font-size:13px;opacity:.55;">' + marketEsc(l.description) + '</span>';
		}
		h += '</div>';
	});
	h += '</div></div></div>';
	marketReceiptPanel(h);
	$('#market_receipt_panel').attr('data-files', JSON.stringify(response.files || [])).attr('data-vendor', response.vendor || '');
}

function marketEsc(s) {
	return $('<div></div>').text(s === null || s === undefined ? '' : String(s)).html();
}
