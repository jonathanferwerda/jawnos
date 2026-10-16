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
