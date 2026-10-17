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
	$.post('/manager/market/checkout', { vendor: marketVendor, list: marketList, timestamp: Date.now() }, function(response) {
		if (response && response.transaction) { marketCheckoutOpen(response.transaction); }
	}, 'json');
});

// Checkout leaves the money side to a person: open the list's category with its
// expense transaction filled from the cart, so the amounts can be checked and
// saved by hand.
function marketCheckoutOpen(t) {
	if (!t || !t.app) { return; }
	var app = t.app;
	if (t.storage) { localStorage.setItem('transactionSaver_' + app, JSON.stringify(t.storage)); }
	appointmentGrabber(app, Date.now());
	var tries = 0;
	var iv = setInterval(function() {
		var w = $('.appointment[app="' + app + '"]');
		if (!w.length) { if (++tries > 20) { clearInterval(iv); } return; }
		clearInterval(iv);
		w.find('.app_act.reset[app="' + app + '"]').first().trigger('click');
		setTimeout(function() {
			var m = w.find('.app_details .movement');
			if (m.length) { m.val('expense').trigger('change'); }
			setTimeout(function() {
				if (t.account) { w.find('.app_details .account').val(t.account); }
				if (typeof transactionStorageRetriever === 'function') { transactionStorageRetriever(app); }
			}, 800);
		}, 500);
	}, 300);
}

$(document).on('click', '#market_scan', function() { marketScan(); });

window.jawnScanResult = function(code) {
	if (!code) { return; }
	marketBarcode(code, window.marketPhoneScanOrigin || '');
	window.marketPhoneScanOrigin = '';
};

// The code is resolved by the house; origin_tab names the tab that asked another
// device for the scan, so its Market can be told the item arrived.
function marketBarcode(code, origin_tab) {
	$.post('/manager/market/scan', { barcode: code, list: marketList, vendor: marketVendor, origin_tab: origin_tab || '', timestamp: Date.now() });
}

window.marketScanArrived = function() {
	var b = $('#market_scan');
	if (!b.length) { return; }
	b.css('background-color', 'green');
	setTimeout(function() { b.css('background-color', ''); }, 1200);
};

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
	marketReceiptPanel();
});

function marketScanChooser(devices) {
	var h = '<div style="padding:18px;max-width:560px;margin:0 auto;">'
		+ '<div style="font-size:22px;font-weight:700;margin-bottom:12px;">Scan a barcode</div>'
		+ '<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">'
		+ '<button id="market_scan_here" style="font-size:17px;padding:8px 14px;">Scan here</button>'
		+ '<select id="market_scan_device" style="font-size:17px;padding:6px;flex:1 1 180px;"><option value="">A device in the house...</option>';
	devices.forEach(function(d) {
		h += '<option value="' + marketEsc(d.browser_tab_id) + '">' + marketEsc(d.label) + '</option>';
	});
	h += '</select> <button id="market_scan_remote_go" style="font-size:17px;padding:8px 14px;">Scan from device</button>'
		+ '</div>'
		+ '<div style="margin-top:14px;"><button id="market_scan_chooser_close" style="font-size:15px;">Cancel</button></div>'
		+ '<div style="margin-top:10px;font-size:14px;opacity:.65;">The device opens its own camera and sends the code back here.</div>'
		+ '</div>';
	marketReceiptPanel(h);
}

$(document).on('click', '#market_scan_here', function() { marketReceiptPanel(); marketScanHere(); });

$(document).on('click', '#market_scan_chooser_close', function() { marketReceiptPanel(); });

$(document).on('click', '#market_scan_remote_go', function() {
	var bti = $('#market_scan_device').val();
	if (!bti) { return; }
	$.post('/manager/market/scan/remote', {
		browser_tab_id: bti,
		origin_tab: sessionStorage.getItem('browser_tab_id') || '',
		list: marketList, vendor: marketVendor, timestamp: Date.now()
	}, function() {
		marketReceiptPanel('<div style="padding:10px;font-size:17px;">Scanning on the device... <button id="market_scan_chooser_close">Close</button></div>');
	});
});

// The other tab opens its camera over the whole screen (replacing #everything),
// reads the first barcode or QR code it sees, restores the page, and posts the
// code. The lookup and the list are the house's, so the computer's Market refreshes.
window.marketPhoneCamera = function(opts) {
	opts = opts || {};
	window.marketPhoneScanOrigin = opts.origin_tab || '';
	// the phone's own scanner (the Google code scanner behind JawnScan) is the
	// scanner, opened as if the phone had pressed Scan itself; it covers the
	// screen and hands the code back through jawnScanResult
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
		if (code) {
			marketBarcode(code, opts.origin_tab || '');
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
		if (!detector) { stop(); marketBarcodePrompt(); return; }
		video.play();
		var iv = setInterval(function() {
			detector.detect(video).then(function(codes) {
				if (codes && codes.length && codes[0].rawValue) { var code = codes[0].rawValue; stop(); marketBarcode(code); }
			}).catch(function() {});
		}, 400);
		setTimeout(stop, 30000);
	}).catch(function() {
		marketBarcodePrompt();
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
		+ '<b>' + marketEsc(response.vendor || 'Receipt') + '</b>'
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
		h += '<input class="market_receipt_item" type="text" value="' + marketEsc(l.item) + '" style="width:40%;"> ';
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
