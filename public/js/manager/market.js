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
	marketList = '';
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/market/refresh',
		type: 'POST',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response.window);
			// at a shop the applicable list (or the only one) opens ready
			var nearby = $('#market_nearby .market_nearby_list');
			if (nearby.length === 1) { marketList = nearby.attr('list'); }
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
	body.find('#market_list').toggle(marketTab === 'list');
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
	$.post('/manager/market/checkout', { vendor: marketVendor, timestamp: Date.now() });
});

$(document).on('click', '#market_scan', function() { marketScan(); });

window.jawnScanResult = function(code) { if (code) { marketBarcode(code); } };

// Scan a barcode. If another tab in the house has a camera, offer to scan from
// it (pointing a phone at a shelf beats a laptop); otherwise scan here.
function marketScan() {
	$.get('/manager/market/cameras', {
		timestamp: Date.now(),
		browser_tab_id: sessionStorage.getItem('browser_tab_id') || ''
	}, function(response) {
		var devices = (response && response.devices) || [];
		if (devices.length) { marketScanChooser(devices); return; }
		marketScanHere();
	}, 'json').fail(function() { marketScanHere(); });
}

function marketScanHere() {
	if (window.JawnScan && typeof window.JawnScan.scan === 'function') {
		window.JawnScan.scan();
		return;
	}
	if ('BarcodeDetector' in window && navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
		marketScanCamera();
		return;
	}
	var typed = prompt('Barcode / product code:');
	if (typed) { marketBarcode(typed); }
}

function marketScanChooser(devices) {
	var h = '<div style="padding:10px;">'
		+ '<b style="font-size:18px;">Scan a barcode</b>'
		+ '<div style="margin-top:8px;">'
		+ '<button id="market_scan_here">Scan here</button> '
		+ '<select id="market_scan_device"><option value="">A device in the house...</option>';
	devices.forEach(function(d) {
		h += '<option value="' + marketEsc(d.browser_tab_id) + '">' + marketEsc(d.label) + '</option>';
	});
	h += '</select> <button id="market_scan_remote_go">Scan from device</button> '
		+ '<button id="market_scan_chooser_close">Cancel</button>'
		+ '</div></div>';
	marketReceiptPanel(h);
}

$(document).on('click', '#market_scan_here', function() { marketReceiptPanel(); marketScanHere(); });

$(document).on('click', '#market_scan_chooser_close', function() { marketReceiptPanel(); });

$(document).on('click', '#market_scan_remote_go', function() {
	var bti = $('#market_scan_device').val();
	if (!bti) { return; }
	$.post('/manager/market/scan/remote', {
		browser_tab_id: bti, list: marketList, vendor: marketVendor, timestamp: Date.now()
	}, function() {
		marketReceiptPanel('<div style="padding:10px;font-size:17px;">Scanning on the device... <button id="market_scan_chooser_close">Close</button></div>');
	});
});

// The other tab opens its camera over the whole screen (replacing #everything),
// reads the first barcode or QR code it sees, restores the page, and posts the
// code. The lookup and the list are the house's, so the computer's Market refreshes.
window.marketPhoneCamera = function(opts) {
	opts = opts || {};
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
		if (code) {
			$.post('/manager/market/scan', { barcode: code, list: opts.list || '', vendor: opts.vendor || '', timestamp: Date.now() });
		}
	};
	$('#market_phone_cancel').on('click', function() { finish(); });
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
			finish();
			if (window.JawnScan && typeof window.JawnScan.scan === 'function') { window.JawnScan.scan(); }
			else { window.alert('This browser cannot read barcodes.'); }
			return;
		}
		iv = setInterval(function() {
			detector.detect(v).then(function(codes) {
				if (codes && codes.length && codes[0].rawValue) { finish(codes[0].rawValue); }
			}).catch(function() {});
		}, 400);
		setTimeout(function() { if (!done) { finish(); } }, 30000);
	}).catch(function() {
		$('#market_phone_hint').text('The camera could not be opened.');
	});
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
		if (!detector) { stop(); return; }
		video.play();
		var iv = setInterval(function() {
			detector.detect(video).then(function(codes) {
				if (codes && codes.length && codes[0].rawValue) { var code = codes[0].rawValue; stop(); marketBarcode(code); }
			}).catch(function() {});
		}, 400);
		setTimeout(stop, 30000);
	}).catch(function() {
		var typed = prompt('Barcode / product code:');
		if (typed) { marketBarcode(typed); }
	});
}

function marketBarcode(code) {
	$.post('/manager/market/scan', { barcode: code, list: marketList, vendor: marketVendor, timestamp: Date.now() });
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
	marketApply();
});

$(document).on('click', '.market_nearby_list', function() {
	marketList = $(this).attr('list');
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

$(document).on('click', '.market_receipt_go', function() {
	var feed = $(this).attr('feed');
	if (!feed) { $('#market_receipt_file').trigger('click'); return; }
	var scan_id = String(Date.now()) + String(Math.floor(Math.random() * 1000000));
	marketReceiptPanel('<div style="padding:10px;font-size:17px;">Scanning...'
		+ '<div id="market_scan_log" style="font-size:14px;opacity:.7;margin-top:6px;"></div>'
		+ '<div id="market_scan_pages" style="margin-top:8px;"></div></div>');
	marketScanPoll(scan_id);
	$.post('/manager/market/receipt', { feed: feed, scan_id: scan_id, vendor: marketVendor, list: marketList, timestamp: Date.now() }, function(response) {
		marketReceiptShow(response);
	}, 'json').fail(function() { marketReceiptShow({ error: 'the scan could not be read' }); });
});

// While a scanner run is in progress, show the scanner's own line and each page
// as it comes off the feeder. The scan request itself blocks on the scanner, so
// this asks a separate route (another worker answers) until the request returns.
function marketScanPoll(scan_id) {
	var poll = setInterval(function() {
		$.get('/manager/market/receipt/progress', { scan_id: scan_id }, function(p) {
			if (!$('#market_scan_pages').length) { clearInterval(poll); return; }
			$('#market_scan_log').text((p.log || []).join(' | '));
			(p.pages || []).forEach(function(pg) {
				if ($('#market_scan_pages img[data-page="' + pg.page + '"]').length) { return; }
				$('#market_scan_pages').append('<img data-page="' + pg.page + '" src="' + pg.url + '" style="height:96px;margin-right:6px;border:1px solid var(--line);">');
			});
		}, 'json');
	}, 1000);
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
		vendor: marketVendor, list: marketList,
		total: panel.attr('data-total') || '',
		date: panel.attr('data-date') || '',
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
	var h = '<div style="padding:8px;font-size:17px;">';
	h += '<b>' + marketEsc(response.vendor ? response.vendor : 'Receipt') + '</b>';
	if (response.date) { h += ' <span style="opacity:.6;font-size:14px;">' + marketEsc(response.date) + '</span>'; }
	if (response.total) { h += ' <span style="opacity:.6;font-size:14px;">total ' + marketEsc(response.total) + '</span>'; }
	h += '<span style="float:right;"><button id="market_receipt_apply">Add to cart</button> <button id="market_receipt_close">Cancel</button></span>';
	h += '</div>';
	if (!lines.length) { h += '<div style="padding:10px;font-size:16px;opacity:.7;">No lines were read.</div>'; }
	lines.forEach(function(l) {
		h += '<div class="market_receipt_line" data-description="' + marketEsc(l.description) + '" data-code="' + marketEsc(l.code || '') + '" style="border-bottom:1px solid var(--line);padding:5px;font-size:16px;">';
		h += '<input class="market_receipt_include" type="checkbox" checked style="vertical-align:middle;"> ';
		h += '<input class="market_receipt_item" type="text" value="' + marketEsc(l.item) + '" style="width:34%;"> ';
		h += 'x<input class="market_receipt_qty" type="text" value="' + marketEsc(l.qty) + '" style="width:8%;"> ';
		h += '@<input class="market_receipt_price" type="text" value="' + marketEsc(l.price === null || l.price === undefined ? '' : l.price) + '" style="width:12%;"> ';
		if (l.on_list) { h += '<span style="font-size:13px;opacity:.7;">on list</span> '; }
		else if (l.matched_by) { h += '<span style="font-size:13px;opacity:.7;">' + marketEsc(l.matched_by) + '</span> '; }
		if (l.description && l.description.toLowerCase() !== String(l.item || '').toLowerCase()) {
			h += '<span style="font-size:13px;opacity:.55;">' + marketEsc(l.description) + '</span>';
		}
		h += '</div>';
	});
	marketReceiptPanel(h);
	$('#market_receipt_panel').attr('data-total', response.total || '').attr('data-date', response.date || '').attr('data-files', JSON.stringify(response.files || []));
}

function marketEsc(s) {
	return $('<div></div>').text(s === null || s === undefined ? '' : String(s)).html();
}
