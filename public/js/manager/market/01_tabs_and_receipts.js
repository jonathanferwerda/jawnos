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

function marketReceiptScanFeed(feed, scan_id) {
	scan_id = String(scan_id || (Date.now() + String(Math.floor(Math.random() * 1000000))));
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
}

$(document).on('click', '.market_receipt_go', function() {
	var feed = $(this).attr('feed');
	if (!feed) { $('#market_receipt_file').trigger('click'); return; }
	marketReceiptScanFeed(feed);
});

// The printer saw a receipt in its ADF. Any open Market window hears this; the
// first to claim the scan id runs it and the rest stand down, so two windows do
// not pull the same paper twice. The notice (notification_sender) is what opens
// Market when it is not already up.
window.marketReceiptAdf = function(opts) {
	opts = opts || {};
	if (!$('#market_body').length) { return; }
	var scan_id = String(opts.scan_id || (Date.now() + String(Math.floor(Math.random() * 1000000))));
	$.post('/manager/market/receipt/adf/claim', { scan_id: scan_id, timestamp: Date.now() }, function(r) {
		if (!r || !r.go) { return; }
		marketReceiptScanFeed('adf', scan_id);
	}, 'json');
};

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
