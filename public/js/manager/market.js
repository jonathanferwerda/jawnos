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

// Scan a barcode. The app's own bridge (window.JawnScan) is the fast path on a
// phone - it calls back through window.jawnScanResult(code), the way the other
// bridges report; a browser uses the BarcodeDetector over the camera; failing
// both, a code is typed. The server resolves it and names it in our terms.
$(document).on('click', '#market_scan', function() { marketScan(); });

window.jawnScanResult = function(code) { if (code) { marketBarcode(code); } };

function marketScan() {
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
	marketReceiptPanel('<div style="padding:12px;font-size:17px;">Reading the receipt...</div>');
	$.post('/manager/market/receipt', { feed: feed, vendor: marketVendor, list: marketList, timestamp: Date.now() }, function(response) {
		marketReceiptShow(response);
	}, 'json').fail(function() { marketReceiptShow({ error: 'the scan could not be read' }); });
});

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
	var h = '<div style="padding:10px;">'
		+ '<b style="font-size:18px;">Read a receipt</b>'
		+ '<div style="margin-top:8px;">'
		+ '<button class="market_receipt_go" feed="adf">Scan (ADF)</button> '
		+ '<button class="market_receipt_go" feed="flatbed">Scan (flatbed)</button> '
		+ '<button class="market_receipt_go" feed="">Photo / file</button> '
		+ '<button id="market_receipt_close">Cancel</button>'
		+ '</div>'
		+ '<div style="margin-top:8px;font-size:14px;opacity:.7;">The ADF takes the whole receipt in one pass; a long receipt is two flatbed pages.</div>'
		+ '</div>';
	marketReceiptPanel(h);
}

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
