$(document).on('click', '.warehouse_toggle', function() {
	warehouseInitializer();
	console.log('warehouse init');
});

function warehouseInitializer() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/warehouse',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response.window);
		}
	});
}

$(document).on('change', '.warehouse_config', async function() {
	var c = $(this);
	await warehouseConfigSetter(c);
	warehouseListingReload();
});

function warehouseListingReload(search) {
	$.ajax({
		url: '/manager/warehouse/listing',
		type: 'GET',
		data: { search: search || '', timestamp: Date.now() },
		success: function(response) {
			$('#warehouse_results').html(response.html);
		}
	});
}

var warehouseSearchInterval;
$(document).on('keyup click', '#warehouse_search', function() {
	var search = $(this).val();
	clearTimeout(warehouseSearchInterval);
	warehouseSearchInterval = setTimeout(function() {
		warehouseListingReload(search);
	}, 300);
});

$(document).on('click', '.warehouse_journal', function(e) {
	e.stopPropagation();
	var img = $(this);
	var host = img.closest('.warehouse_item, .warehouse_account, .warehouse_search_item');
	if (host.next('.warehouse_journal_panel').length) {
		host.next('.warehouse_journal_panel').remove();
		return;
	}
	$.ajax({
		url: '/manager/warehouse/journal',
		type: 'GET',
		data: { item: img.attr('item'), timestamp: Date.now() },
		success: function(response) {
			host.after(response.html);
		}
	});
});

$(document).on('click', '.warehouse_journal_close', function(e) {
	e.stopPropagation();
	$(this).closest('.warehouse_journal_panel').remove();
});

$(document).on('click', '.warehouse_journal_source_toggle', function(e) {
	e.stopPropagation();
	var img = $(this);
	var panel = img.closest('.warehouse_journal_source_block').find('.warehouse_journal_source_panel');
	if (panel.children().length) {
		panel.empty();
		return;
	}
	$.ajax({
		url: '/manager/warehouse/journal',
		type: 'GET',
		data: { source_uuid: img.attr('source_uuid'), timestamp: Date.now() },
		success: function(response) {
			panel.html(response.html);
		}
	});
});

async function warehouseConfigSetter(c) {
	var config = c.attr('config');
	var value = c.val();
	console.log(value);
	if (c.attr('type') == 'checkbox') {
		if (c.prop('checked') == true) {
			value = 'on';
		} else {
			value = 'off';
		}
	}
	if (typeof value == 'object') {
		value = JSON.stringify(value);
	}
	console.log(value);
	await settingSetter({ 'app': 'warehouse', 'setting': config, 'value': value });
}

// Stock in: what arrived without a purchase. The quantity accepts the same
// "12" or "355mL" shape as an appointment, so a gift and a bought pack are
// counted in one language.
function warehouseStockLabels() {
	var t = function(s) { return (typeof jawnosT === 'function') ? jawnosT(s) : s; };
	return { title: t('Stock in'), item: t('Item'), quantity: t('Quantity (12 or 355mL)'), place: t('Place'), reason: t('Reason'), add: t('Add'), cancel: t('Cancel'), noplace: t('Add a place first.') };
}

$(document).on('click', '#warehouse_stock_in', function() {
	$('#warehouse_stock_prompt').remove();
	var L = warehouseStockLabels();
	var places = $('#warehouse_place option').filter(function() { return this.value !== 'all'; }).map(function() {
		return { value: this.value, label: $(this).text() };
	}).get();
	var items = [];
	$('.warehouse_item[item]').each(function() {
		var v = $(this).attr('item');
		if (v && items.indexOf(v) === -1) { items.push(v); }
	});
	var datalist = '<datalist id="warehouse_stock_items">' + items.map(function(v) { return '<option value="' + $('<div></div>').text(v).html() + '"></option>'; }).join('') + '</datalist>';
	var place_options = places.map(function(p) { return '<option value="' + $('<div></div>').text(p.value).html() + '">' + $('<div></div>').text(p.label).html() + '</option>'; }).join('');
	var reasons = [ ['gift', 'Gift'], ['found', 'Found'], ['transfer', 'Transferred in'], ['other', 'Other'] ].map(function(r) {
		return '<option value="' + r[0] + '">' + ((typeof jawnosT === 'function') ? jawnosT(r[1]) : r[1]) + '</option>';
	}).join('');
	var box = $('<div id="warehouse_stock_prompt" style="position:fixed;z-index:100000;left:50%;top:35%;transform:translate(-50%,-50%);background:var(--panel);border:2px solid var(--line);border-radius:8px;padding:14px;font-size:17px;min-width:340px;box-shadow:0 8px 30px rgba(0,0,0,.35);">'
		+ '<div style="font-weight:700;margin-bottom:8px;">' + L.title + '</div>'
		+ datalist
		+ '<input id="warehouse_stock_item" list="warehouse_stock_items" type="text" placeholder="' + L.item + '" style="width:100%;font-size:17px;padding:4px;">'
		+ '<div style="margin-top:8px;display:flex;gap:6px;">'
		+ '<input id="warehouse_stock_quantity" type="text" placeholder="' + L.quantity + '" style="flex:1;font-size:17px;padding:4px;">'
		+ '<select id="warehouse_stock_place" style="flex:1;">' + (place_options || '<option value="">' + L.noplace + '</option>') + '</select>'
		+ '</div>'
		+ '<div style="margin-top:8px;"><select id="warehouse_stock_reason" style="width:100%;">' + reasons + '</select></div>'
		+ '<div style="margin-top:10px;"><button id="warehouse_stock_add">' + L.add + '</button> <button id="warehouse_stock_cancel">' + L.cancel + '</button></div>'
		+ '</div>');
	$('body').append(box);
	$('#warehouse_stock_item').focus();
});

$(document).on('click', '#warehouse_stock_cancel', function() {
	$('#warehouse_stock_prompt').remove();
});

$(document).on('keydown', '#warehouse_stock_item, #warehouse_stock_quantity', function(e) {
	if (e.key === 'Enter') { e.preventDefault(); $('#warehouse_stock_add').trigger('click'); }
});

$(document).on('click', '#warehouse_stock_add', function() {
	var box = $('#warehouse_stock_prompt');
	var item = $('#warehouse_stock_item').val() || '';
	var quantity = $('#warehouse_stock_quantity').val() || '';
	var place = $('#warehouse_stock_place').val() || '';
	var reason = $('#warehouse_stock_reason').val() || 'gift';
	if (item.replace(/\s/g, '') === '') { $('#warehouse_stock_item').focus(); return; }
	if (!place) { $('#warehouse_stock_place').focus(); return; }
	if (quantity.replace(/\s/g, '') === '') { $('#warehouse_stock_quantity').focus(); return; }
	$.post('/manager/warehouse/stock_in', {
		item: item, quantity: quantity, place: place, reason: reason, timestamp: Date.now()
	}, function(response) {
		if (!response || !response.ok) { alert((response && response.error) || 'Could not add stock'); return; }
		box.remove();
		warehouseListingReload($('#warehouse_search').val() || '');
	}, 'json');
});