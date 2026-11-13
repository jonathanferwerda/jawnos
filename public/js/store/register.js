// ---- the Store cash register ------------------------------------------------
// A walk-in customer is an order with no account. Open orders live on the
// manager (one per customer at the counter) and this file is only the till:
// tabs, the running lines, the payment panel and the receipt. Every write is a
// POST to the Store's own routes; no order is an appointment until it is paid.
//
// The money functions are mirrored in Perl (JawnOS::Domain::Store), which
// recomputes the total and the change when the sale is recorded. This copy is
// what the person at the counter sees while typing, so it must agree to the
// cent with lib/JawnOS/Domain/Store.pm.

var storeRegisterData = {
	orders: [],
	active: '',
	tax: 1,
	payment: 'cash',
	received: 0,
	last: null,
	receipt_html: '',
	search_timer: null
};

function storeRegisterT(text) {
	var args = Array.prototype.slice.call(arguments);
	if (typeof jawnosT === 'function') {
		return jawnosT.apply(null, args);
	}
	return String(text).replace(/\{(\d+)\}/g, function(m, i) {
		return args[(+i) + 1] !== undefined ? args[(+i) + 1] : m;
	});
}

function storeRegisterMoney(value) {
	var n = (typeof numeral === 'function') ? numeral(value).value() : parseFloat(value);
	return isNaN(n) || n === null ? 0 : Math.round(n * 100) / 100;
}

function storeRegisterActive() {
	for (var i = 0; i < storeRegisterData.orders.length; i++) {
		if (storeRegisterData.orders[i].id === storeRegisterData.active) {
			return storeRegisterData.orders[i];
		}
	}
	return null;
}

// The same sum the server does: each line's unit price times its units, tax on
// the subtotal, both kept in cents.
function storeRegisterTotals(order) {
	var items = (order && order.items) ? order.items : [];
	var subtotal = 0;
	var quantity = 0;
	$.each(items, function(i, line) {
		var price = storeRegisterMoney(line.price);
		var qty = storeRegisterMoney(line.quantity);
		if (qty <= 0) { qty = 1; }
		subtotal += price * qty;
		quantity += qty;
	});
	subtotal = Math.round(subtotal * 100) / 100;
	var rate = storeRegisterMoney(storeRegisterData.tax);
	if (rate <= 0) { rate = 1; }
	var total = Math.round(subtotal * rate * 100) / 100;
	return {
		subtotal: subtotal,
		tax: Math.round((total - subtotal) * 100) / 100,
		total: total,
		quantity: quantity,
		count: items.length
	};
}

// Cash received less the total, in cents. Exact and overpaid are named so the
// till can show "Change $6.50" or refuse a short cash payment.
function storeRegisterChange(total, received) {
	var t = storeRegisterMoney(total);
	var r = storeRegisterMoney(received);
	var cents = Math.round(r * 100) - Math.round(t * 100);
	var change = cents / 100;
	return {
		total: t,
		received: r,
		change: change,
		short: cents < 0,
		exact: cents === 0,
		overpaid: cents > 0
	};
}

// The notes and coins that make up the change, largest first.
function storeRegisterBreakdown(change) {
	var cents = Math.round(storeRegisterMoney(change) * 100);
	if (cents < 0) { cents = 0; }
	var denominations = [100, 50, 20, 10, 5, 2, 1, 0.25, 0.10, 0.05, 0.01];
	var parts = [];
	$.each(denominations, function(i, amount) {
		var unit = Math.round(amount * 100);
		var count = Math.floor(cents / unit);
		if (count > 0) {
			parts.push({ amount: amount, count: count });
			cents -= count * unit;
		}
	});
	return parts;
}

function storeRegisterStatus(text) {
	var status = $('#store_register_status');
	if (status.length) {
		status.text(text || '').toggle(!!(text && text.length));
	}
}

function storeRegisterOpen(cx) {
	var shell = $('#register_app');
	if (shell.children().length) {
		shell.addClass('open');
		storeRegisterRefresh();
		return;
	}
	var customer = (typeof cx === 'string') ? cx : (typeof cx_uuid === 'string' ? cx_uuid : '');
	$.ajax({
		url: '/manager/store/register',
		type: 'GET',
		data: { cx: customer, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.content) { return; }
			shell.html(response.content).addClass('open');
			storeRegisterData.last = storeRegisterLastReceipt();
			storeRegisterRefresh();
		}
	});
}

function storeRegisterClose() {
	$('#register_app').removeClass('open');
	storeRegisterStatus('');
}

function storeRegisterLastReceipt() {
	try {
		var saved = JSON.parse(localStorage.getItem('store_register_last_receipt') || 'null');
		return (saved && saved.uuid) ? saved : null;
	} catch (e) { return null; }
}

function storeRegisterRefresh(active) {
	$.getJSON('/manager/store/register/state', { timestamp: Date.now() }, function(r) {
		if (!r || !r.ok) { return; }
		var was_active = storeRegisterData.active;
		storeRegisterData.orders = r.orders || [];
		storeRegisterData.tax = storeRegisterMoney(r.tax) || 1;
		if (active && storeRegisterOrderById(active)) {
			storeRegisterData.active = active;
		}
		if (!storeRegisterOrderById(storeRegisterData.active)) {
			storeRegisterData.active = storeRegisterData.orders.length ? storeRegisterData.orders[0].id : '';
		}
		if (!storeRegisterData.orders.length) {
			storeRegisterNew(false);
			return;
		}
		if (storeRegisterData.active !== was_active) {
			storeRegisterData.received = 0;
			storeRegisterData.payment = 'cash';
		}
		storeRegisterRender();
	});
}

function storeRegisterOrderById(id) {
	for (var i = 0; i < storeRegisterData.orders.length; i++) {
		if (storeRegisterData.orders[i].id === id) { return storeRegisterData.orders[i]; }
	}
	return null;
}

function storeRegisterNew(withRefresh) {
	if (storeRegisterData.creating) { return; }
	storeRegisterData.creating = true;
	storeRegisterData.received = 0;
	storeRegisterData.payment = 'cash';
	storeRegisterPost('/manager/store/register/order', {
		cx: (typeof cx_uuid === 'string') ? cx_uuid : ''
	}, function(r) {
		storeRegisterData.creating = false;
		if (r && r.order) {
			storeRegisterApply(r);
		}
		else if (withRefresh !== false) {
			storeRegisterRefresh();
		}
	});
}

function storeRegisterApply(r) {
	if (!r || !r.order) { storeRegisterRefresh(); return; }
	var order = r.order;
	var replaced = false;
	for (var i = 0; i < storeRegisterData.orders.length; i++) {
		if (storeRegisterData.orders[i].id === order.id) {
			storeRegisterData.orders[i] = order;
			replaced = true;
			break;
		}
	}
	if (!replaced) { storeRegisterData.orders.push(order); }
	storeRegisterData.active = order.id;
	storeRegisterRender();
}

function storeRegisterPost(url, data, done) {
	data = data || {};
	data.timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'POST',
		data: data,
		dataType: 'json'
	}).done(function(r) {
		if (!r || !r.ok) {
			storeRegisterStatus((r && r.error) ? r.error : storeRegisterT('That did not work.'));
			if (r && r.change) {
				storeRegisterShowChange(r.change);
			}
			return;
		}
		storeRegisterStatus('');
		if (typeof done === 'function') { done(r); }
	}).fail(function() {
		storeRegisterData.creating = false;
		storeRegisterStatus(storeRegisterT('That did not work.'));
	});
}

function storeRegisterRender() {
	storeRegisterRenderTabs();
	storeRegisterRenderOrder();
	storeRegisterRenderPay();
	var last = storeRegisterData.last || storeRegisterLastReceipt();
	$('#store_register_last_receipt').toggle(!!last);
	storeRegisterStatus('');
}

function storeRegisterRenderTabs() {
	var bar = $('#store_register_tabs').empty();
	$.each(storeRegisterData.orders, function(i, order) {
		var tab = $('<button type="button" class="store_register_tab" role="tab"></button>')
			.attr('data-order', order.id)
			.attr('aria-selected', order.id === storeRegisterData.active ? 'true' : 'false')
			.toggleClass('active', order.id === storeRegisterData.active)
			.text(order.label || storeRegisterT('Customer'));
		bar.append(tab);
	});
	if (!storeRegisterData.orders.length) {
		bar.append($('<span class="store_register_tab_empty"></span>').text(storeRegisterT('No open orders')));
	}
}

function storeRegisterRenderOrder() {
	var order = storeRegisterActive();
	var items = $('#store_register_items').empty();
	if (!order) {
		items.append($('<p class="store_register_empty"></p>').text(storeRegisterT('No open orders')));
		$('#store_register_customer_name').text('—');
		$('#store_register_total').text('$0.00');
		$('#store_register_quantity').text('0');
		return;
	}
	$('#store_register_customer_name').text((order.customer && order.customer.name) || storeRegisterT('Customer'));
	$.each(order.items || [], function(i, line) {
		var row = $('<div class="store_register_line"></div>').attr('data-line', line.line);
		row.append($('<div class="store_register_line_name"></div>').text(line.name));
		row.append($('<div class="store_register_line_price"></div>').text(numeral(line.price).format('$0.00')));
		var qty = $('<div class="store_register_qty"></div>');
		qty.append($('<button type="button" class="store_register_qty_button store_register_minus" aria-label="' + storeRegisterT('Remove one') + '">−</button>').attr('data-line', line.line));
		qty.append($('<input type="text" inputmode="decimal" class="store_register_qty_input">')
			.attr('data-line', line.line)
			.val(line.quantity));
		qty.append($('<button type="button" class="store_register_qty_button store_register_plus" aria-label="' + storeRegisterT('Add one') + '">+</button>').attr('data-line', line.line));
		row.append(qty);
		row.append($('<div class="store_register_line_total"></div>').text(numeral(storeRegisterMoney(line.price) * storeRegisterMoney(line.quantity)).format('$0.00')));
		row.append($('<button type="button" class="store_register_remove" aria-label="' + storeRegisterT('Delete') + '">×</button>').attr('data-line', line.line));
		items.append(row);
	});
	if (!(order.items || []).length) {
		items.append($('<p class="store_register_empty"></p>').text(storeRegisterT('Search for an item to add it to this order.')));
	}
	var totals = storeRegisterTotals(order);
	$('#store_register_total').text(numeral(totals.total).format('$0.00'));
	$('#store_register_quantity').text(totals.quantity);
}

function storeRegisterRenderPay() {
	var order = storeRegisterActive();
	var totals = storeRegisterTotals(order);
	var method = storeRegisterData.payment || 'cash';
	$('.store_register_method').each(function() {
		$(this).toggleClass('active', $(this).attr('data-method') === method);
	});
	$('#store_register_cash').toggle(method === 'cash');
	var received = (method === 'cash') ? storeRegisterMoney(storeRegisterData.received) : totals.total;
	var cash = storeRegisterChange(totals.total, received);
	if (!$('#store_register_received').is(':focus')) {
		$('#store_register_received').val(numeral(cash.received).format('0.00'));
	}
	$('#store_register_change').text(numeral(Math.max(cash.change, 0)).format('$0.00'));
	var breakdown = $('#store_register_breakdown').empty();
	$.each(storeRegisterBreakdown(cash.change), function(i, part) {
		breakdown.append($('<span class="store_register_piece"></span>').text(part.count + ' × ' + numeral(part.amount).format('$0.00')));
	});
	var ready = !!order && (order.items || []).length > 0;
	$('#store_register_complete').prop('disabled', !ready || (method === 'cash' && cash.short));
	$('#store_register_void').prop('disabled', !order);
}

function storeRegisterShowChange(change) {
	if (!change) { return; }
	$('#store_register_change').text(numeral(Math.max(change.change, 0)).format('$0.00'));
}

// ---- search and add ---------------------------------------------------------
function storeRegisterSearch() {
	clearTimeout(storeRegisterData.search_timer);
	storeRegisterData.search_timer = setTimeout(function() {
		var term = $.trim($('#store_register_search').val() || '');
		var results = $('#store_register_results').empty();
		if (term.length < 2) { return; }
		$.getJSON('/manager/store/register/items', { search: term, timestamp: Date.now() }, function(r) {
			if (!r || !r.ok) { return; }
			if (!r.items.length) {
				results.append($('<p class="store_register_empty"></p>').text(storeRegisterT('Nothing matches that search.')));
				return;
			}
			$.each(r.items, function(i, item) {
				var button = $('<button type="button" class="store_register_result"></button>')
					.attr('data-item', item.app)
					.attr('data-name', item.name)
					.attr('data-price', item.price);
				button.append($('<span class="store_register_result_name"></span>').text(item.name));
				button.append($('<span class="store_register_result_price"></span>').text(numeral(item.price).format('$0.00')));
				results.append(button);
			});
		});
	}, 250);
}

$(document).on('click', '#store_register_open, #store_register_bottom_open', function() {
	storeRegisterOpen();
});

$(document).on('click', '#store_register_close', function() {
	storeRegisterClose();
});

$(document).on('click', '#store_register_new', function() {
	storeRegisterNew();
});

$(document).on('click', '.store_register_tab', function() {
	var id = $(this).attr('data-order');
	if (!id) { return; }
	storeRegisterData.active = id;
	storeRegisterData.received = 0;
	storeRegisterData.payment = 'cash';
	storeRegisterRender();
});

$(document).on('input', '#store_register_search', function() {
	storeRegisterSearch();
});

$(document).on('click', '.store_register_result', function() {
	var button = $(this);
	var order = storeRegisterActive();
	if (!order) { return; }
	storeRegisterPost('/manager/store/register/item', {
		id: order.id,
		item: button.attr('data-item'),
		name: button.attr('data-name'),
		price: button.attr('data-price'),
		quantity: 1
	}, function(r) {
		$('#store_register_results').empty();
		$('#store_register_search').val('');
		storeRegisterApply(r);
	});
});

$(document).on('click', '.store_register_plus', function() {
	var order = storeRegisterActive();
	var line = $(this).attr('data-line');
	var input = $('.store_register_qty_input[data-line="' + line + '"]');
	if (!order) { return; }
	var qty = storeRegisterMoney(input.val()) + 1;
	storeRegisterQuantity(order.id, line, qty);
});

$(document).on('click', '.store_register_minus', function() {
	var order = storeRegisterActive();
	var line = $(this).attr('data-line');
	var input = $('.store_register_qty_input[data-line="' + line + '"]');
	if (!order) { return; }
	var qty = storeRegisterMoney(input.val()) - 1;
	storeRegisterQuantity(order.id, line, qty);
});

$(document).on('change', '.store_register_qty_input', function() {
	var order = storeRegisterActive();
	if (!order) { return; }
	storeRegisterQuantity(order.id, $(this).attr('data-line'), storeRegisterMoney($(this).val()));
});

$(document).on('click', '.store_register_remove', function() {
	var order = storeRegisterActive();
	if (!order) { return; }
	storeRegisterPost('/manager/store/register/remove', {
		id: order.id,
		line: $(this).attr('data-line')
	}, storeRegisterApply);
});

function storeRegisterQuantity(order_id, line, quantity) {
	storeRegisterPost('/manager/store/register/quantity', {
		id: order_id,
		line: line,
		quantity: quantity
	}, storeRegisterApply);
}

// ---- payment ---------------------------------------------------------------
$(document).on('click', '.store_register_method', function() {
	storeRegisterData.payment = $(this).attr('data-method') || 'cash';
	storeRegisterData.received = 0;
	storeRegisterRenderPay();
});

$(document).on('click', '.store_register_denomination', function() {
	var amount = storeRegisterMoney($(this).attr('data-amount'));
	storeRegisterData.received = Math.round((storeRegisterMoney(storeRegisterData.received) + amount) * 100) / 100;
	storeRegisterRenderPay();
});

$(document).on('click', '.store_register_coin', function() {
	var amount = storeRegisterMoney($(this).attr('data-add'));
	storeRegisterData.received = Math.round((storeRegisterMoney(storeRegisterData.received) + amount) * 100) / 100;
	storeRegisterRenderPay();
});

$(document).on('input', '#store_register_received', function() {
	storeRegisterData.received = storeRegisterMoney($(this).val());
	var totals = storeRegisterTotals(storeRegisterActive());
	var cash = storeRegisterChange(totals.total, storeRegisterData.received);
	$('#store_register_change').text(numeral(Math.max(cash.change, 0)).format('$0.00'));
	$('#store_register_complete').prop('disabled', !storeRegisterActive() || cash.short);
});

$(document).on('click', '#store_register_complete', function() {
	var order = storeRegisterActive();
	if (!order) { return; }
	var totals = storeRegisterTotals(order);
	var method = storeRegisterData.payment || 'cash';
	var received = (method === 'cash') ? storeRegisterMoney(storeRegisterData.received) : totals.total;
	if (method === 'cash' && storeRegisterChange(totals.total, received).short) {
		storeRegisterStatus(storeRegisterT('Received is less than the total.'));
		return;
	}
	$(this).prop('disabled', true);
	storeRegisterPost('/manager/store/register/sale', {
		id: order.id,
		payment: method,
		received: received
	}, function(r) {
		storeRegisterData.receipt_html = r.receipt || '';
		if (r.sale && r.sale.uuid) {
			storeRegisterData.last = { uuid: r.sale.uuid, app: r.sale.app || '' };
			localStorage.setItem('store_register_last_receipt', JSON.stringify(storeRegisterData.last));
		}
		$('#store_register_receipt_paper').html(storeRegisterData.receipt_html);
		$('#store_register_receipt').show();
		storeRegisterRefresh();
		storeRegisterRender();
	});
});

$(document).on('click', '#store_register_void', function() {
	var order = storeRegisterActive();
	if (!order) { return; }
	var button = $(this);
	if (button.attr('armed') !== 'yes') {
		button.attr('armed', 'yes').addClass('armed').text(storeRegisterT('Press again to void'));
		setTimeout(function() {
			button.attr('armed', 'no').removeClass('armed').text(storeRegisterT('Void'));
		}, 2500);
		return;
	}
	button.attr('armed', 'no').removeClass('armed').text(storeRegisterT('Void'));
	storeRegisterPost('/manager/store/register/cancel', { id: order.id }, function() {
		storeRegisterRefresh();
	});
});

// ---- receipt ---------------------------------------------------------------
$(document).on('click', '#store_register_receipt_close', function() {
	$('#store_register_receipt').hide();
});

$(document).on('click', '#store_register_print', function() {
	var last = storeRegisterData.last || storeRegisterLastReceipt();
	if (last && last.uuid) {
		$.ajax({
			url: '/manager/store/register/receipt',
			type: 'GET',
			data: { uuid: last.uuid, app: last.app || '', timestamp: Date.now() },
			success: function(html) {
				if (typeof storePrintPrepare === 'function') {
					storePrintPrepare(html, { type: 'sale', uuid: last.uuid, customer_app: last.app || '' });
				} else {
					$('#printer_view').html(html).show();
					$('#everything').hide();
				}
			}
		});
		return;
	}
	if ($('#store_register_receipt_paper').html()) {
		$('#printer_view').html($('#store_register_receipt_paper').html()).show();
		$('#everything').hide();
	}
});

$(document).on('click', '#store_register_last_receipt', function() {
	var last = storeRegisterData.last || storeRegisterLastReceipt();
	if (!last || !last.uuid) { return; }
	$.ajax({
		url: '/manager/store/register/receipt',
		type: 'GET',
		data: { uuid: last.uuid, app: last.app, timestamp: Date.now() },
		dataType: 'html',
		success: function(html) {
			$('#printer_view').html(html).show();
			$('#everything').hide();
		}
	});
});
