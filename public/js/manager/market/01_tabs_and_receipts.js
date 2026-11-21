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

// The printer saw a receipt in its ADF. The notice reaches every device so the
// whole house can see it, but only the machine the job was delegated to takes
// the paper; the scan id's claim then keeps two windows on that machine from
// pulling it twice.
window.marketReceiptAdf = function(opts) {
	opts = opts || {};
	if (!$('#market_body').length) { return; }
	if (opts.owner && typeof signatorial !== 'undefined' && String(opts.owner) !== String(signatorial)) { return; }
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
		var code = r.find('.market_receipt_tax').val() || '';
		var codes = (code && code !== 'none') ? [code] : [];
		var known = r.find('.market_receipt_tax_known').val() === '1';
		lines.push({
			include: 1,
			item: r.find('.market_receipt_item').val(),
			description: r.attr('data-description'),
			code: r.attr('data-code'),
			marker: r.attr('data-marker') || '',
			qty: r.find('.market_receipt_qty').val(),
			price: r.find('.market_receipt_price').val(),
			tax_codes: codes,
			tax_known: known ? 1 : 0
		});
	});
	if (!lines.length) { marketReceiptPanel(); return; }
	var panel = $('#market_receipt_panel');
	var rdate = $('#market_receipt_date').val() || '';
	var rtime = $('#market_receipt_time').val() || '';
	$.post('/manager/market/receipt/apply', {
		lines: JSON.stringify(lines),
		vendor: marketVendor || panel.attr('data-vendor') || '', list: marketList,
		total: $('#market_receipt_total').val() || '',
		date: rdate,
		time: rtime,
		receipt_timestamp: marketReceiptMoment(rdate, rtime),
		category: $('#market_receipt_category').val() || '',
		payment_method: $('#market_receipt_payment').val() || '',
		payment_ref: $('#market_receipt_payment_ref').val() || '',
		account: $('#market_receipt_account').val() || '',
		subtotal: $('#market_receipt_subtotal').val() || '',
		tax_total: $('#market_receipt_tax_total').val() || '',
		taxes: $('#market_receipt_taxes').val() || '[]',
		tax_legend: $('#market_receipt_tax_legend').val() || '[]',
		tax_included: $('#market_receipt_tax_included').val() || '0',
		files: panel.attr('data-files') || '[]',
		timestamp: Date.now()
	}, function() { marketReceiptPanel(); });
});

// The printed date and time are the person's local time, and the box is UTC, so
// the moment is resolved here (the browser's zone) and sent as an epoch. A bare
// date is local midnight, not the UTC midnight Date would pick for it alone.
function marketReceiptMoment(date, time) {
	date = (date || '').trim();
	if (!date) { return ''; }
	var t = (time || '').trim();
	var m = t.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?$/i);
	if (m) {
		var h = parseInt(m[1], 10), mi = parseInt(m[2], 10), se = parseInt(m[3] || 0, 10);
		var ap = (m[4] || '').toLowerCase();
		if (ap === 'pm' && h < 12) { h += 12; }
		if (ap === 'am' && h === 12) { h = 0; }
		t = (h < 10 ? '0' : '') + h + ':' + (mi < 10 ? '0' : '') + mi + ':' + (se < 10 ? '0' : '') + se;
	}
	else { t = '00:00:00'; }
	var ms = new Date(date + 'T' + t).getTime();
	return isNaN(ms) ? '' : ms;
}

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

// The × on a kept receipt throws it away: the house row loses it on every device
// and the pages this machine keeps go with it. A receipt already copied onto a
// saved transaction stays there, because that copy is the app's own file.
$(document).on('click', '.market_receipt_drop', function() {
	var row = $(this).closest('.market_receipt_row');
	var uuid = row.attr('data-uuid') || '';
	if (!uuid) { row.remove(); return; }
	jawnosConfirm(jawnosT('Throw this receipt away? The pages this machine keeps go with it.'), function() {
		$.post('/manager/market/receipt/remove', { uuid: uuid, timestamp: Date.now() }, function(r) {
			if (r && r.ok) { row.remove(); }
		}, 'json');
	});
});

$(document).on('click', '.market_receipt_readd', function() {
	var row = $(this).closest('.market_receipt_row');
	var rdate = row.attr('data-date') || '';
	var rtime = row.attr('data-time') || '';
	$.post('/manager/market/receipt/apply', {
		lines: row.attr('data-apply'),
		files: row.attr('data-files'),
		total: row.attr('data-total') || '',
		date: rdate,
		time: rtime,
		receipt_timestamp: marketReceiptMoment(rdate, rtime),
		category: row.attr('data-category') || '',
		payment_method: row.attr('data-payment') || '',
		payment_ref: row.attr('data-payment-ref') || '',
		account: row.attr('data-account') || '',
		subtotal: row.attr('data-subtotal') || '',
		tax_total: row.attr('data-tax-total') || '',
		taxes: row.attr('data-taxes') || '[]',
		tax_legend: row.attr('data-tax-legend') || '[]',
		tax_included: row.attr('data-tax-included') || '0',
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
	var catalog = (typeof jawnos_tax_catalog !== 'undefined' && jawnos_tax_catalog) ? jawnos_tax_catalog : [];
	var category_options = (response.categories || []).map(function(c) {
		return '<option value="' + marketEsc(c) + '"></option>';
	}).join('');
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
		+ '<label style="font-size:14px;">time <input id="market_receipt_time" type="text" value="' + marketEsc(response.time || '') + '" style="width:70px;"></label>'
		+ '<label style="font-size:14px;">total <input id="market_receipt_total" type="text" value="' + marketEsc(response.total === null || response.total === undefined ? '' : response.total) + '" style="width:80px;"></label>'
		+ '</div>';
	// The paper's tax facts ride with the confirm so the delta and the kept
	// receipt both carry them, even after the visible total is edited.
	h += '<input id="market_receipt_subtotal" type="hidden" value="' + marketEsc(response.subtotal === null || response.subtotal === undefined ? '' : response.subtotal) + '">'
		+ '<input id="market_receipt_tax_total" type="hidden" value="' + marketEsc(response.tax_total === null || response.tax_total === undefined ? '' : response.tax_total) + '">'
		+ '<input id="market_receipt_taxes" type="hidden" value="' + marketEsc(JSON.stringify(response.taxes || [])) + '">'
		+ '<input id="market_receipt_tax_legend" type="hidden" value="' + marketEsc(JSON.stringify(response.tax_legend || [])) + '">'
		+ '<input id="market_receipt_tax_included" type="hidden" value="' + (response.tax_included ? '1' : '0') + '">';
	h += '<div style="display:flex;gap:8px;align-items:center;margin-top:4px;flex-wrap:wrap;">'
		+ '<label style="font-size:14px;">category <input id="market_receipt_category" list="market_receipt_categories" type="text" value="' + marketEsc(response.category || '') + '" style="width:130px;" placeholder="' + ((typeof jawnosT === 'function') ? jawnosT('Food, Vape, Dinner...') : 'Food, Vape, Dinner...') + '"></label>'
		+ '<datalist id="market_receipt_categories">' + category_options + '</datalist>'
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
		var selected = (l.tax_codes || []).map(String);
		var tax_options = '<option value="">(tax?)</option>'
			+ '<option value="none"' + (l.tax_known && !selected.length ? ' selected' : '') + '>No tax</option>';
		catalog.forEach(function(t) {
			var rate = (t.rate === null || t.rate === undefined) ? '' : ' ' + t.rate + '%';
			tax_options += '<option value="' + marketEsc(t.code) + '"' + (selected.indexOf(String(t.code)) !== -1 ? ' selected' : '') + '>' + marketEsc((t.name || t.code) + rate) + '</option>';
		});
		h += '<div class="market_receipt_line" data-description="' + marketEsc(l.description) + '" data-code="' + marketEsc(l.code || '') + '" data-marker="' + marketEsc(l.tax_marker || '') + '" style="border-bottom:1px solid var(--line);padding:4px;font-size:16px;">';
		h += '<input class="market_receipt_include" type="checkbox" checked style="vertical-align:middle;"> ';
		h += '<input class="market_receipt_item" type="text" value="' + marketEsc(l.item_formatted || l.item) + '" style="width:34%;"> ';
		h += 'x<input class="market_receipt_qty" type="text" value="' + marketEsc(l.qty) + '" style="width:9%;"> ';
		h += '@<input class="market_receipt_price" type="text" value="' + marketEsc(l.price === null || l.price === undefined ? '' : l.price) + '" style="width:14%;"> ';
		h += '<select class="market_receipt_tax" title="' + ((typeof jawnosT === 'function') ? jawnosT('Tax on this line') : 'Tax on this line') + '" style="max-width:34%;">' + tax_options + '</select> ';
		h += '<input class="market_receipt_tax_known" type="hidden" value="' + (l.tax_known ? '1' : '0') + '">';
		if (l.tax_marker) { h += '<span class="market_receipt_marker" style="font-size:12px;opacity:.6;">' + marketEsc(l.tax_marker) + '</span> '; }
		if (l.on_list) { h += '<span style="font-size:13px;opacity:.7;">on list</span> '; }
		else if (l.matched_by) { h += '<span style="font-size:13px;opacity:.7;">' + marketEsc(l.matched_by) + '</span> '; }
		if (l.description && l.description.toLowerCase() !== String(l.item || '').toLowerCase()) {
			h += '<span style="font-size:13px;opacity:.55;">' + marketEsc(l.description) + '</span>';
		}
		h += '</div>';
	});
	h += '<div id="market_receipt_tax_delta" class="market_receipt_tax_delta" style="margin-top:8px;padding:6px;border:1px solid var(--line);border-radius:4px;font-size:14px;"></div>';
	h += '</div></div></div>';
	marketReceiptPanel(h);
	$('#market_receipt_panel').attr('data-files', JSON.stringify(response.files || [])).attr('data-vendor', response.vendor || '')
		.attr('data-subtotal', response.subtotal === null || response.subtotal === undefined ? '' : response.subtotal)
		.attr('data-tax-total', response.tax_total === null || response.tax_total === undefined ? '' : response.tax_total)
		.attr('data-taxes', JSON.stringify(response.taxes || []))
		.attr('data-tax-legend', JSON.stringify(response.tax_legend || []))
		.attr('data-tax-included', response.tax_included ? '1' : '0');
	marketReceiptTaxPaint();
}

function marketReceiptCatalog() {
	return (typeof jawnos_tax_catalog !== 'undefined' && jawnos_tax_catalog) ? jawnos_tax_catalog : [];
}

function marketReceiptRate(code) {
	var catalog = marketReceiptCatalog();
	for (var i = 0; i < catalog.length; i++) {
		if (String(catalog[i].code) === String(code)) { return numeral(catalog[i].rate).value(); }
	}
	return 0;
}

// Which house code a printed tax row names: its rate first, then its label. An
// unmatched row still shows its own receipt figure, but no line can claim it.
function marketReceiptCodeForTax(t) {
	var catalog = marketReceiptCatalog();
	var rate = numeral(t && t.rate).value();
	for (var i = 0; i < catalog.length; i++) {
		if (rate && Math.abs(numeral(catalog[i].rate).value() - rate) < 0.0001) { return String(catalog[i].code); }
	}
	var label = String((t && t.label) || '').toLowerCase();
	for (var j = 0; j < catalog.length; j++) {
		var name = String(catalog[j].name || catalog[j].code || '').toLowerCase();
		var code = String(catalog[j].code || '').toLowerCase();
		if (label && (label.indexOf(name) !== -1 || label.indexOf(code) !== -1)) { return String(catalog[j].code); }
	}
	return '';
}

// The receipt's printed tax against what the chosen per-line codes add up to.
// Only included lines count; a line left on (tax?) is the reason for a delta.
function marketReceiptTaxPaint() {
	var panel = $('#market_receipt_panel');
	var box = $('#market_receipt_tax_delta');
	if (!panel.length || !box.length) { return; }
	var included = $('#market_receipt_tax_included').val() === '1';
	var rawTax = $('#market_receipt_tax_total').val() || '';
	if (rawTax === '') {
		box.html('<div>' + ((typeof jawnosT === 'function') ? jawnosT('The receipt tax total was not read; tick a line to set it.') : 'The receipt tax total was not read; tick a line to set it.') + '</div>').attr('data-ok', '0');
		return;
	}
	var receiptTax = numeral(rawTax).value() || 0;
	var taxes = [];
	try { taxes = JSON.parse($('#market_receipt_taxes').val() || '[]') || []; } catch (e) { taxes = []; }
	var byCode = {};
	var noTax = 0;
	panel.find('.market_receipt_line').each(function() {
		var r = $(this);
		if (!r.find('.market_receipt_include').prop('checked')) { return; }
		var code = r.find('.market_receipt_tax').val() || '';
		var price = numeral(r.find('.market_receipt_price').val()).value() || 0;
		var rate = (code && code !== 'none') ? marketReceiptRate(code) : 0;
		if (!(rate > 0)) { noTax++; return; }
		var amount = included ? (price - price / (1 + rate / 100)) : (price * rate / 100);
		byCode[code] = (byCode[code] || 0) + amount;
	});
	var rows = [];
	var hasAmounts = taxes.length && taxes.every(function(t) { return t && t.amount !== null && t.amount !== undefined && t.amount !== ''; });
	if (hasAmounts) {
		taxes.forEach(function(t) {
			var code = marketReceiptCodeForTax(t);
			rows.push({ label: t.label || ((t.rate || '') + '%'), receipt: numeral(t.amount).value() || 0, lines: code ? (byCode[code] || 0) : 0 });
		});
	}
	else {
		var coded = 0;
		Object.keys(byCode).forEach(function(k) { coded += byCode[k]; });
		rows.push({ label: 'Tax', receipt: receiptTax, lines: coded });
	}
	var html = '';
	var totalDiff = 0;
	rows.forEach(function(row) {
		var diff = Math.round((row.receipt - row.lines) * 100) / 100;
		totalDiff += diff;
		html += '<div>' + marketEsc(row.label) + ': receipt ' + numeral(row.receipt).format('0.00')
			+ ' · lines ' + numeral(row.lines).format('0.00') + ' · '
			+ (Math.abs(diff) < 0.02 ? 'matches' : 'difference ' + numeral(diff).format('0.00')) + '</div>';
	});
	totalDiff = Math.round(totalDiff * 100) / 100;
	var ok = Math.abs(totalDiff) < 0.02;
	html += '<div style="margin-top:4px;font-weight:bold;">' + (ok
		? ((typeof jawnosT === 'function') ? jawnosT('Reconciles') : 'Reconciles')
		: (noTax ? noTax + ' ' + ((typeof jawnosT === 'function') ? jawnosT('line(s) with no tax') : 'line(s) with no tax') + ' · ' : '')
			+ ((typeof jawnosT === 'function') ? jawnosT('difference') : 'difference') + ' ' + numeral(totalDiff).format('0.00')) + '</div>';
	box.html(html).attr('data-ok', ok ? '1' : '0');
}

$(document).on('change', '.market_receipt_tax', function() {
	var r = $(this).closest('.market_receipt_line');
	var code = $(this).val() || '';
	// A blank picker is "not decided yet", not "untaxed": only No tax and a
	// chosen code are an explicit answer worth remembering.
	var known = code !== '';
	r.find('.market_receipt_tax_known').val(known ? '1' : '0');
	if (known) {
		var codes = (code === 'none') ? [] : [code];
		$.post('/manager/market/item_tax', {
			item: r.find('.market_receipt_item').val(),
			tax_known: 1,
			tax_codes: JSON.stringify(codes),
			timestamp: Date.now()
		});
	}
	marketReceiptTaxPaint();
});

$(document).on('input change', '.market_receipt_price, .market_receipt_include', marketReceiptTaxPaint);

function marketEsc(s) {
	return $('<div></div>').text(s === null || s === undefined ? '' : String(s)).html();
}
