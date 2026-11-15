// ---- the cart -------------------------------------------------------------
// A quote is built from one or more lines. The item page is the line editor;
// the cart holds the lines and turns them into a quote. An invoice is a
// snapshot of the quote, so the cart keeps the quote after issuing one and the
// next change is made here and issued again.
var storeCart = { uuid: '', id: '', lines: [], editing: -1, movement: '' };

function storeCartLoad() {
	try {
		var raw = localStorage.getItem('store_cart');
		var c = raw ? JSON.parse(raw) : null;
		if (c && c.lines && typeof c.lines.length === 'number') {
			storeCart = c;
			storeCart.lines = storeCart.lines || [];
			storeCart.editing = -1;
		}
	}
	catch (e) { storeCart = { uuid: '', id: '', lines: [], editing: -1, movement: '' }; }
}

function storeCartStoreLocal() {
	localStorage.setItem('store_cart', JSON.stringify({
		uuid: storeCart.uuid,
		id: storeCart.id,
		lines: storeCart.lines,
		movement: storeCart.movement
	}));
}

function storeCartMoney(value) { return numeral(value || 0).format('$0.00'); }
function storeCartNumber(value) { return numeral(value || 0).value() || 0; }
function storeCartLineName(line) {
	var m = line && line.model ? line.model : {};
	return m.name || (line ? line.item : '') || '';
}

function storeCartTotals() {
	var subtotal = 0, cost = 0, discount = 0, count = 0;
	$.each(storeCart.lines, function(i, line) {
		var m = line.model || {};
		var q = storeCartNumber(m.quantity || 1);
		subtotal += storeCartNumber(m.price) * q;
		cost += storeCartNumber(m.cost) * q;
		discount += storeCartNumber(m.discount) * q;
		count += q;
		$.each(line.options || {}, function(category, options) {
			$.each(options || [], function(n, o) {
				var oq = storeCartNumber(o.quantity || 1);
				subtotal += storeCartNumber(o.price) * oq;
				cost += storeCartNumber(o.cost) * oq;
				discount += storeCartNumber(o.discount) * oq;
				count += oq;
			});
		});
	});
	var tax = subtotal * (sales_tax || 1) - subtotal;
	return {
		subtotal: subtotal,
		cost: cost,
		discount: discount,
		tax: tax,
		total: subtotal * (sales_tax || 1),
		count: count
	};
}

function storeCartRender() {
	var box = $('#store_cart_lines').empty();
	var t = storeCartTotals();
	$('#store_cart_count').text(storeCart.lines.length);
	$('#store_cart_quote_id').text(storeCart.id || '');
	if (storeCart.lines.length === 0) {
		box.append($('<p class="store_cart_empty"></p>').text(storeT('The cart is empty. Open an item and add it.')));
	}
	$.each(storeCart.lines, function(i, line) {
		var m = line.model || {};
		var q = storeCartNumber(m.quantity || 1);
		var row = $('<div class="store_cart_line"></div>').attr('data-line', i);
		row.append($('<span class="store_cart_line_name"></span>').text(storeCartLineName(line)));
		row.append($('<span class="store_cart_line_qty"></span>').text('\u00d7' + q));
		row.append($('<span class="store_cart_line_total"></span>').text(storeCartMoney(storeCartNumber(m.price) * q)));
		row.append($('<button type="button" class="store_text_button store_cart_line_edit"></button>').text(storeT('Edit')));
		row.append($('<button type="button" class="store_text_button store_cart_line_remove"></button>').text(storeT('Remove')));
		box.append(row);
	});
	$('#store_cart_subtotal').text(storeCartMoney(t.subtotal));
	$('#store_cart_tax').text(storeCartMoney(t.tax));
	$('#store_cart_total').text(storeCartMoney(t.total));
	$('#store_cart_invoice').toggle(!!storeCart.uuid);
}

function storeCartShow(open) {
	$('#store_cart_panel').attr('data-open', open ? 'yes' : 'no').toggle(open);
	if (open) { storeCartRender(); }
}

function storeCartAlert(text) {
	var box = $('#store_cart_status');
	box.text(text).show();
	clearTimeout(storeCartAlert.timer);
	storeCartAlert.timer = setTimeout(function() { box.fadeOut(4000); }, 6000);
}

function storeCartCurrentLine() {
	var q = saveQuote();
	return {
		item: q.item || '',
		model: q.model || {},
		options: q.options || {},
		custom: q.custom || {}
	};
}

function storeCartAdd() {
	var line = storeCartCurrentLine();
	if (!line.item) {
		storeCartAlert(storeT('Open an item first.'));
		return;
	}
	// A line is being edited only while its own item is still the one open. A
	// different item is a new line, not a replacement.
	if (storeCart.editing >= 0 && storeCart.editing < storeCart.lines.length
		&& storeCart.lines[storeCart.editing].item !== line.item) {
		storeCart.editing = -1;
	}
	if (storeCart.editing >= 0 && storeCart.editing < storeCart.lines.length) {
		storeCart.lines[storeCart.editing] = line;
	}
	else {
		storeCart.lines.push(line);
	}
	storeCart.editing = -1;
	storeCart.movement = $('.store_movement').first().val() || storeCart.movement;
	storeCartStoreLocal();
	storeCartShow(true);
	storeCartRender();
}

function storeCartEditLine(i) {
	var line = storeCart.lines[i];
	if (!line) { return; }
	storeCart.editing = i;
	storeCartStoreLocal();
	quote = { info: {}, model: line.model || {}, options: line.options || {}, custom: line.custom || {}, item: line.item || '' };
	storeItem(line.item, quote);
	storeCartShow(false);
}

function storeCartRemoveLine(i) {
	storeCart.lines.splice(i, 1);
	if (storeCart.editing === i) { storeCart.editing = -1; }
	else if (storeCart.editing > i) { storeCart.editing--; }
	storeCartStoreLocal();
	storeCartRender();
}

function storeCartClear() {
	storeCart = { uuid: '', id: '', lines: [], editing: -1, movement: '' };
	storeCartStoreLocal();
	storeCartRender();
}

function storeCartQuotePayload() {
	var t = storeCartTotals();
	var first = storeCart.lines[0] || { item: '', model: {} };
	return {
		info: {},
		id: storeCart.id || '',
		item: first.item || '',
		model: first.model || {},
		options: first.options || {},
		lines: storeCart.lines,
		movement: storeCart.movement || $('.store_movement').first().val() || 'income',
		numbers: {
			subtotal: t.subtotal,
			cost: t.cost,
			discount: t.discount,
			tax: t.tax,
			total: t.total,
			tax_rate: sales_tax || 1,
			markup: (t.cost > 0 ? (t.subtotal / t.cost - 1) : 1)
		},
		timestamp: Date.now()
	};
}

function storeCartSaveQuote(done) {
	if (!cx_uuid) { storeCartAlert(storeT('Choose a customer first.')); return; }
	if (!storeCart.lines.length) { storeCartAlert(storeT('The cart is empty.')); return; }
	var data = storeCartQuotePayload();
	$.ajax({
		url: '/store/quote/save',
		type: 'POST',
		data: {
			quote: JSON.stringify(data),
			movement: data.movement,
			timestamp: data.timestamp,
			item: data.item,
			uuid: storeCart.uuid || 'new',
			cx: cx_uuid
		},
		success: function(response) {
			if (!response || !response.quote) { return; }
			storeCart.uuid = response.quote.uuid || '';
			storeCart.id = response.quote.id || '';
			storeCartStoreLocal();
			storeCartRender();
			customerList(cx_uuid, 'quotes');
			storeCartAlert(storeT('Quote {0} saved.').replace('{0}', storeCart.id));
			if (done) { done(response.quote); }
		},
		error: function() {
			storeCartAlert(storeT('The quote could not be saved.'));
		}
	});
}

function storeCartInvoice() {
	if (!storeCart.uuid) { storeCartAlert(storeT('Save the quote first.')); return; }
	$.ajax({
		url: '/store/quote/move',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			uuid: storeCart.uuid,
			cx_uuid: cx_uuid,
			action: 'invoice',
			type: 'quote'
		},
		success: function(response) {
			var r = {};
			try { r = JSON.parse(response); } catch (e) { r = response || {}; }
			if (r && r.ok) {
				storeCartAlert(storeT('Invoice {0} created. The quote is still here to revise.').replace('{0}', r.id || ''));
				if ($('#main_viewer').is(':visible') && $('#main_viewer').attr('type') === 'invoice') {
					customerList(cx_uuid, 'invoice');
				}
			}
			else {
				storeCartAlert((r && r.error) || storeT('The invoice could not be created.'));
			}
		},
		error: function() {
			storeCartAlert(storeT('The invoice could not be created.'));
		}
	});
}

function storeCartLoadQuote(uuid) {
	if (!uuid) { return; }
	$.ajax({
		url: '/store/quote/load',
		type: 'GET',
		data: { uuid: uuid, cx_uuid: cx_uuid },
		success: function(response) {
			if (!response || !response.item) { return; }
			var lines = [];
			if (response.lines && response.lines.length) {
				lines = response.lines;
			}
			else {
				lines = [{
					item: response.item,
					model: response.model || {},
					options: response.options || {},
					custom: response.custom || {}
				}];
			}
			storeCart = {
				uuid: uuid,
				id: response.id || '',
				lines: lines,
				editing: -1,
				movement: response.movement || ''
			};
			storeCartStoreLocal();
			$('#main_viewer').html('').hide().attr('type', '');
			storeCartShow(true);
			storeCartRender();
		}
	});
}

// The old save icon calls storeWriter, which now saves the cart; the cart
// script only adds the functions it calls.

$(document).ready(function() {
	storeCartLoad();
	storeCartRender();
});

$(document).on('click', '#store_cart_open', function() { storeCartShow(true); });
$(document).on('click', '#store_cart_close', function() { storeCartShow(false); });
$(document).on('click', '.store_cart_add', function() { storeCartAdd(); });
$(document).on('click', '#store_cart_save', function() { storeCartSaveQuote(); });
$(document).on('click', '#store_cart_invoice', function() { storeCartInvoice(); });
$(document).on('click', '#store_cart_clear', function() {
	if (window.confirm(storeT('Empty the cart?'))) { storeCartClear(); }
});
$(document).on('click', '.store_cart_line_edit', function() {
	storeCartEditLine(parseInt($(this).closest('.store_cart_line').attr('data-line'), 10));
});
$(document).on('click', '.store_cart_line_remove', function() {
	storeCartRemoveLine(parseInt($(this).closest('.store_cart_line').attr('data-line'), 10));
});
$(document).on('click', '.quote_edit', function() {
	storeCartLoadQuote($(this).attr('uuid'));
});
$(document).on('click', '.quote_revise', function() {
	storeCartLoadQuote($(this).attr('source_uuid'));
});
