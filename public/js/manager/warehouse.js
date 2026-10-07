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