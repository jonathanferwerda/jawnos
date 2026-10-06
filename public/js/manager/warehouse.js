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

$(document).on('change', '.warehouse_config', function() {
	var c = $(this);
	warehouseConfigSetter(c);
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