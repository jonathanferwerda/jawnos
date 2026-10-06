var cx_uuid = '';
var original_title;
$(document).ready(function() {
	storeInitializer();
});

function storeOpener() {
	var url = '/manager/store';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
			storeInitializer();
			var q = localStorage.getItem('quote');
			if (isJson(q)) {
				q = JSON.parse(q);
				console.log(q);
				if (q['item']) {
					storeItem(q['item'],q);
				}
			}
		}, error: function (response) { }
	});
}

function storeInitializer() {
	$('#right_ribbon').show();
	$('#bottom_ribbon').show();
	var search = localStorage.getItem('store_search');
	$('#store_search').val(search);
	cx_uuid = localStorage.getItem('cx_uuid');
	if (cx_uuid) {
		customerGrabber(cx_uuid);
	}
	$('.store_item_type').each(function(i,v) {
		var type = $(v).attr('type');
		var status = localStorage.getItem('sit_' + type);
		$(v).attr('status', status);
	});
	storeItemTypeGrabber();
	var category = localStorage.getItem('store_category')
	if (category != '') {
		storeCategoryOpener(category);
	}
	if (search) {
		storeSearch();
	}
	original_title = $('title').text();
}

$(document).on('click', '.store_item_type', function() {
	var sit = $(this);
	var type = $(this).attr('type');
	var status = $(this).attr('status');
	storeItemTypeGrabber();
	if (status == 'on') {
		status = 'off';	
	}
	else {
		status = 'on';
	}
	sit.attr('status', status);
	localStorage.setItem('sit_' + type, status);
	var opened = 'no';
	$('.store_category').each(function(i,v) {
		if ($(v).attr('status') == 'open') {
			opened = 'yes';
		}
	});
	if (opened == 'yes') {
		storeCategoryOpener($('.store_category[status=open]').attr('category'));
	}
	else {
		storeSearch();
	}
});

function storeCategoryOpener(category) {
	$.ajax({
		url: '/store/category_grabber',
		type: 'GET',
		data: { category: category, types: storeItemTypeGrabber() },
		success: function(response) {
			$('#items_view').html(response.content);
			$('.store_subcategories[category="' + category + '"]').html(response.subcategories).show();
			$('.store_category[category="' + category + '"]').attr('status', 'open');
		}
	});
}

$(document).on('click', '.store_category', function() {
	var cat = $(this);
	var category = cat.attr('category');
	var status = cat.attr('status');
	$('.store_subcategory').attr('status', 'closed');
	$('.store_category').attr('status', 'closed');
	if (status == 'closed') {
		cat.attr('status','open');
		localStorage.setItem('store_category', category);
		storeCategoryOpener(category)
	}
	else {
		cat.attr('status', 'closed');
		localStorage.removeItem('store_category');
		$('.store_subcategories[category="' + category + '"]').html('').hide();
	}
});

function storeItemTypeGrabber() {
	var types = [];

	$('.store_item_type').each(function(i,v) {
		if ($(v).attr('status') == 'on') {
			types.push($(v).attr('type'));
		}
	});

	return JSON.stringify(types);
}

$(document).on('click', '.store_subcategory', function() {
	var sub = $(this);
	var category = sub.attr('category');
	var subcategory = sub.attr('subcategory');
	var status = sub.attr('status');
	var count = sub.attr('count');
	$('.store_subcategory').attr('status', 'closed');
	$('.store_category').attr('status', 'closed');
	if (status == 'closed') {
		$.ajax({
			url: '/store/category_grabber',
			type: 'GET',
			data: { category: category, subcategory: subcategory, count: count, types: storeItemTypeGrabber() },
			success: function(response) {

				$('#items_view').html(response.content);
			//	$('.store_subcategories[category="' + category + '"]').html(response.subcategories).show();
				sub.attr('status', 'open');
				$('.store_subcategories[category="' + category + '"][subcategory="' + subcategory +'"]').html(response.subcategories).show();
			}
		});
	}
	else {
		sub.attr('status', 'closed');
	}
});

var storeSearchInterval;
$(document).on('keyup click', '#store_search', function() {
	storeSearch();
});

function storeSearch() {
	if ($('#store_search').is(':visible')) {
		var search = $('#store_search').val();
		var timestamp = Date.now();
		clearTimeout(storeSearchInterval);
		storeSearchInterval = setTimeout(function() {

			if (search.length >= 2) {
				localStorage.setItem('store_search', search);
				$.ajax({
					url: '/store/search',
					type: 'POST',
					data: { search: search, timestamp: timestamp, types: storeItemTypeGrabber() },
					success: function(response) {
						$('#items_view').html(response.content);
					}
				});
			}
			else {
				$('#items_view').html('');
				localStorage.removeItem('store_search');
			}
		},500);
	}
}

$(document).on('click', '.store_item', function() {
	var s = $(this);
	if (!quote) {
		quote = { info: {}, model: [], options: {} };
	}
	var item = s.attr('item');
	storeItem(item,quote);
});

function storeItem(item,quote) {
	var manufacturer = $('#item_manufacturer_select').val();
	var jQuote = JSON.stringify(quote);
	$.ajax({
		url: '/store/item',
		type: 'GET',
		data: { item: item, manufacturer: manufacturer, quote: jQuote },
		success: function(response) {
			$('#item_view').html(response.template);
			$('#item_view').show();
			$('#item_manufacturer_select').val(manufacturer);
			$('#specs').html(response.settings.specs);
			$('#specs_toggle').show();
			if (cx_uuid != '') {
				$('.save_quote').attr('cx', cx_uuid).show();
			}
			if (quote.item) {
				populateQuote(quote);
			}
			else {
				saveQuote();
			}
			if (response.settings) {
				$('#item_view').css({ 'background-color': response.settings.colour });
			}
			else {
				setTimeout(function() {
					$('#item_view').hide();
				},2000);
			}
		}
	});
}

$(document).on('change', '#item_manufacturer_select', function() {
	var item = $(this).closest('.item').attr('item');
	storeItem(item,saveQuote());
});

$(document).on('mousewheel touchmove', '#item_view', function(e) {
	var sq = $(this).find('.save_quote');
	var cq = $(this).find('.store_item_cancel_button');
	//clearTimeout(itScroll);
	itScroll = setTimeout(function() {
		var newY = $('#item_view').scrollTop();
		$('#price_information').css({'bottom': 20 - newY });
		sq.css({'top': newY });
		cq.css({'top': newY });
	},100);

});

function populateQuote(quote) {
	$('.item_model').attr('select', 'off');
	$('.item_option').attr('select', 'off');
	$('.item').find('.store_movement').val(quote['movement']);
	var model = $('.item_model[uuid="' + quote.model.uuid + '"');
	model.attr('select', 'on');
	model.attr('price', numeral(quote.model.price).value());
	model.attr('discount', numeral(quote.model.discount).value());
	model.find('.quantity').val(quote.model.quantity);
	model.find('.unit').val(quote.model.unit);
	console.log(quote.model);
	if (quote.model['description']) {
		model.find('.description').html(quote.model['description']);
	}
	$('.price_display[uuid="' + model.uuid + '"]').text(numeral(model.price).format('$0.00'));
	$.each(quote.options, function(i,v) {
		$.each(v, function(o,option) {
			var optional = $('.item_option[uuid="' + option.uuid + '"]');
			optional.attr('select','on');
			optional.attr('price', option.price);
			optional.attr('discount', option.discount);
			$('.price_display[uuid="' + option.uuid + '"]').text(numeral(option.price).format('$0.00'));
			optional.find('.quantity').val(option.quantity || 1);
			optional.find('.unit').val(option.unit || 1);
			if (option['description']) {
				optional.find('.option_description').html(option['description']);
			}
		});
	});
	saveQuote();
}

$(document).on('change', '.store_movement', function() {
	var value = $(this).val();
	$('.store_movement').val(value);
	settingSetter({ 'app': 'store', 'setting': 'store_movement', 'value': value });
});

$(document).on('click', '#specs_toggle', function() {
	if ($('#specs_balloon').is(':visible')) { 
		$('#specs_balloon').hide();
	}
	else {
		$('#specs_balloon').show();
	}
});
$(document).on('click', '.item_image_thumb', function() {
	var t = $(this);
	var st = $('.item').parent().scrollTop();

	if (t.attr('type') == 'image') {
		if ($('#store_main_image').attr('src') == t.attr('pre_src')) {
			$('.item').parent().scrollTop(st - $('#store_main_image').height());
			$('#store_main_image').attr('src','').hide();
		}
		else {
			var ps = $('#store_main_image').attr('src');
			$('#store_main_image').attr('src', t.attr('pre_src')).show();
			$('#store_main_video').hide();
			if (ps == '') {
				$('.item').parent().scrollTop(st - $('#store_main_image').height());
			}
		}
	}
	else if (t.attr('type') == 'video') {
		if ($('#store_main_video').attr('src') == t.attr('pre_src')) {
			$('.item').parent().scrollTop(st - $('#store_main_video').height());
			$('#store_main_video').attr('src','').hide();
		}
		else {
			var ps = $('#store_main_video').attr('src');
			$('#store_main_video').attr('src', t.attr('pre_src')).show();
			$('#store_main_image').hide();
			if (ps == '') {
				$('.item').parent().scrollTop(st - $('#store_main_video').height());
			}
		}
	}
});

$(document).on('click', '.store_item_cancel_button', function() {
	$('#item_view').hide();
	$('#specs_toggle, #specs_balloon').hide();
	localStorage.removeItem('quote');
});

$(document).on('click', '.save_quote', function() {
	var i = $(this).closest('.item');
	storeWriter();
});

var quote = { info: {}, model: [], options: {} };
function saveQuote() {
	var timestamp = Date.now();
	quote['item'] = $('#item').attr('item');
	quote['uuid'] = $('#item').attr('uuid') || 'new';
	quote['id'] = $('.item').attr('quote_id');
	quote['movement'] = $('.item').find('.store_movement').val();
	quote['timestamp'] = timestamp;
	$('.item_model[select="on"]').each(function(i,v) {
		var model = $(v);
		var uuid = model.attr('uuid');
		var price = model.attr('price');
		var cost = model.attr('cost');
		var discount = model.attr('discount');
		var name = model.attr('name');
		var quantity = model.find('.quantity').val();
		var unit = model.find('.unit').val();
		var description = model.find('.model_description').html();
		console.log(description);
		var tax = price * sales_tax - price;
		quote['model'] = { 
			timestamp: timestamp, 
			uuid: uuid, 
			name: name, 
			price: price, 
			quantity: quantity, 
			unit: unit, 
			discount: discount, 
			cost: cost, 
			tax: tax, 
			tax_rate: sales_tax,
			description: description
		};
	});
	$('.item_option[select="on"]').each(function(i,v) {
		var option = $(v);
		var uuid = $(v).attr('uuid');
		var category = $(v).attr('option_category');
		if (quote['options'][category] == undefined) {
			quote['options'][category] = [];
		}

		$.each(quote['options'][category], function(n,va) {
			console.log(va);
			console.log(uuid);
			if (va) {
				if (va.uuid == uuid) {
					quote['options'][category].splice(n,1);
				}
				else {

				}
			} else { console.log('missing'); console.log(va); }
		});

		var uuid = option.attr('uuid');
		var price = option.attr('price');
		var cost = option.attr('cost');
		var discount = option.attr('discount');
		var name = option.attr('name');
		var category = option.attr('option_category');
		var quantity = option.find('.quantity').val();
		var description = option.find('.option_description').html();
		var unit = option.find('.unit').val();
		var tax = price * sales_tax - price;
		var seen_it = 0;
		var data = { 
			uuid: uuid, 
			category: category, 
			cost: cost, 
			price: price, 
			description: description, 
			quantity: quantity, 
			unit: unit, 
			discount: discount, 
			name: name, 
			timestamp: timestamp, 
			tax: tax, 
			tax_rate: sales_tax 
		};
		quote['options'][category].push(data);


	});
	quote['numbers'] = doTheMath();
	localStorage.setItem('quote', JSON.stringify(quote));
	return quote;
}

$(document).on('click', '.delete_quote', function() {
	var a = $(this);
	var timestamp = Date.now();
	var uuid = a.attr('uuid');
	var server_time = a.closest('.quote').attr('server_time');
	var cx_uuid = a.attr('cx_uuid');
	var type = a.attr('doc_type');
	var armed = a.attr('armed');
	if (armed == 'yes') {
		$.ajax({
			url: '/store/quote/delete',
			type: 'POST',
			data: { server_time: server_time, timestamp: timestamp, uuid: uuid, cx_uuid: cx_uuid, type: type },
			success: function(response) {
				customerList(cx_uuid,type);
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click', '.pi', function() {
	var pi = $(this);
	if (pi.is('input')) {
		return;
	}
	$('.pi').each(function(i,v) {
		if ($(v).is('input')) {
			$(v).hide();
		}
		else {
			$(v).show();
		}
	});
	var edit = $('#' + pi.attr('id') + '_edit');
	edit.val(numeral(pi.text()).value());
	edit.show();
	edit.focus();
	
	pi.hide();
});

$(document).on('change', '.pi', function() {
	var pi = $(this);
	if (!pi.is('input')) {
		return;
	}
	pi.hide();
	var id = pi.attr('id');
	markupCalculator(id);
	id = id.replace('_edit','');
	$('#' + id).show();
});

$(document).on('click', '.quote_move', function() {
	var timestamp = Date.now();
	var uuid = $(this).attr('uuid');
	var cx_uuid = $(this).attr('cx_uuid');
	var action = $(this).attr('action');
	var type = $(this).attr('type');
	$.ajax({
		url: '/store/quote/move',
		type: 'POST',
		data: { timestamp: timestamp, uuid: uuid, cx_uuid: cx_uuid, action: action, type: type },
		success: function(response) {
			customerList(cx_uuid,type);
		}
	});	
});

$(document).on('click', '.print', function() {
	var timestamp = Date.now();
	var type = $(this).attr('type');
	var cx_uuid = $(this).attr('cx_uuid');
	var uuid = $(this).attr('uuid');
	$.ajax({
		url: '/store/print',
		type: 'GET',
		data: { 
			timestamp: timestamp, 
			type: type, 
			uuid: uuid, 
			cx_uuid: cx_uuid 
		},
		success: function(response) {
			$('#printer_view').html(response).show();
			$('#everything').hide();
			if ($('#printer_title').length > 0) {
				$('title').text($('#printer_title').text());
			}
			
		}
	});
});

$(document).on('click', '.email', function() {
	var timestamp = Date.now()
	var type = $(this).attr('type');
	var cx_uuid = $(this).attr('cx_uuid');
	var uuid = $(this).attr('uuid');

	$.ajax({
		url: '/store/email',
		type: 'GET',
		data: {
			timestamp: timestamp,
			type: type,
			uuid: uuid,
			cx_uuid: cx_uuid
		},
		success: function(response) {
			windowDrawerOpener('store', response.html);
		}
	});


});


$(document).on('click', '#printer_view', function() {
	$('#everything').show();
	$('#printer_view').hide();
	$('title').text(original_title);
});


function storeWriter() {
	var store = localStorage.getItem('store') || '{ "items": {}, "total_price": 0 }';
	store = JSON.parse(store);
	var timestamp = Date.now();
	var total_price = 0;
	var q = saveQuote();
	var quote = JSON.stringify(q);
	$.ajax({
		url: '/store/quote/save',
		type: 'POST',
		data: { quote: quote, movement: q['movement'], timestamp: timestamp, item: q.item, uuid: q.uuid, cx: cx_uuid },
		success: function(response) {
			if (!response.error) {
				$('.item').attr('quote_uuid', response['quote']['uuid']);
				$('.item').attr('quote_id', response['quote']['id']);
			}
		}
	});

	localStorage.setItem('store', JSON.stringify(store));
	$('#total_price').text(total_price);
}

$(document).on('click', '.quote_title', function() { 
	var uuid = $(this).attr('uuid');
	$.ajax({
		url: '/store/quote/load',
		type: 'GET',
		data: { uuid: uuid },
		success: function(response) {
			storeItem(response.item,response);
			$('#main_viewer').html('').hide().attr('type', '');
		}
	});


});

$(document).on('click', '.item_model', function(e) {
	if ($(e.target).is('.unit, .quantity, .description, .pricing')) {
		return;
	}
	var model = $(this);
	var timestamp = Date.now();
	var selected = model.attr('select');
	var uuid = model.attr('uuid');
	var price = model.attr('price');
	var cost = model.attr('cost');
	var name = model.attr('name');
	$('.item_model').attr('select', 'off');
	quote['model'] = { timestamp: timestamp, uuid: uuid, price: price, cost: cost, name: name };
	if (selected == 'on') {

	}
	else {
		model.attr('select', 'on');
	}
	saveQuote();
});

$(document).on('change blur focus', '.model_description, .option_description', function() {
	saveQuote();
});

$(document).on('change blur focus', '.pricing', function() {
	var p = $(this);
	var price = p.html();
	var i;
	if (p.closest('.item_model').length > 0) {
		i = p.closest('.item_model');
	} else if (p.closest('.item_option').length > 0) {
		i = p.closest('.item_option');
	}
	if (i.length > 0) {
		price = price.replace(/[^0-9.]/, '');
		var fprice = '$' + numeral(price).format('0.00');
		if (p.hasClass('original_price_display')) {
			i.attr('original_price', price);
			i.attr('price', price);
			i.find('.original_price_display').html(fprice);
			i.find('.price_display').html(fprice);
		} else {
			i.attr('price', price);
			i.attr('original_price', price);
			i.find('.original_price_display').html(fprice);
			i.find('.price_display').html(fprice);
		}

		saveQuote();
	}



});


$(document).on('click', '.item_option', function(e) {
	if ($(e.target).is('.unit, .quantity, .description, .pricing')) {
		return;
	}
	var option = $(this);
	var timestamp = Date.now();
	var category = option.attr('option_category');
	var selected = option.attr('select');

	var option_category = $('.item_option_category[option_category="' + category + '"]');
	var grouping = option_category.attr('grouping') || 1;
	if (quote['options'][category] == undefined) {
		quote['options'][category] = [];
	}
	var selected_options = quote['options'][category].sort((a, b) => numeral(a.timestamp).value() - numeral(b.timestamp).value());;
	if (selected == 'on') {
		option.attr('select', 'off');
		$.each(selected_options, function(i,v) {
			if (v != undefined && option.attr('uuid') == v.uuid) {
				quote['options'][category].splice(i,1);
			}
			
		});
	}
	else {
		option.attr('select', 'on');
		var uuid = option.attr('uuid');
		var price = option.attr('price');
		var cost = option.attr('cost');
		var name = option.attr('name');
		var category = option.attr('option_category');
		var tax = (price * sales_tax) - price;
		quote['options'][category].push({ uuid: uuid, category: category, cost: cost, price: price, name: name, timestamp: timestamp, tax: tax, tax_rate: sales_tax });
	}

	$('.item_option[option_category="' + category + '"]').attr('select', 'off');

	selected_options.splice(0, selected_options.length -  grouping);
	$.each(selected_options, function(i,v) {
		$('.item_option[uuid="' + v.uuid + '"]').attr('select', 'on');
	});
	saveQuote();
});

$(document).on('change', '.quantity, .unit', function() {
	saveQuote();
});

$(document).on('click', '.quantity, .unit', function(e) {
	e.preventDefault();
});

$(document).on('click', '.custom_item_selection_add_toggle', function() {
	var t = $(this);
	var type = t.attr('type');
	var item = t.closest('.item').attr('item');
	var ci = $('.custom_item_selection[type="' + type + '"]');
	if (ci.is(':visible')) {
		ci.hide();
	} else {
		$.ajax({ 
			url: '/manager/store/custom_item/toggle',
			type: 'GET',
			data: { item: item, type: type },
			success: function(response) {
				console.log(response);
				ci.html(response['template']).show();
			}
		});
	}
});

$(document).on('click', '.custom_item_selection_save', function() {
	var form = $(this).closest('.custom_item_selection');
	var item = form.attr('item');
	var type = form.attr('type');
	var data = { item: item, type: type };
	form.find('.custom_item_attribute').each(function(i,v) {
		var val = $(v).val();
		if ($(v).attr('type') == 'checkbox') {
			if ($(v).prop('checked') == true) {
				val = 'on';
			} else {
				val = 'off';
			}
		}
		data[$(v).attr('att')] = val;
	});

	$.ajax({
		url: '/manager/store/custom_item/add',
		type: 'POST',
		data: data,
		success: function(response) {
			console.log(response);
			if (response['name']) {
				if (!quote['custom']) {
					quote['custom'] = { model: [], option: [] };
				}
				quote['custom'][type].push(response);
				storeItem(item,quote);
			}
		}
	});

});

function doTheMath() {
	var total_price = 0;
	var total_cost = 0;
	var total_discount = 0;
	var price = numeral($('.item').attr('price')).value();
	var model_price = numeral($('.item_model[select="on"]').attr('original_price')).value();

	var model_cost = numeral($('.item_model[select="on"]').attr('cost')).value();
	var model_discount = numeral($('.item_model[select="on"]').attr('discount')).value();
	var option_price = 0;
	var option_cost = 0;
	var option_discount = 0;
	var option_quantity = 1;
	$('.item_option[select="on"]').each(function(i,v) {
		option_quantity = numeral($(v).find('.quantity').val() || 1).value();
		option_price += numeral($(v).attr('original_price')).value() * option_quantity;
		option_cost += numeral($(v).attr('cost')).value() * option_quantity;
		option_discount += numeral($(v).attr('discount')).value() * option_quantity;
		option_quantity = 1;
	});
	total_discount = Math.abs(model_discount + option_discount) * -1;
	total_price = model_price + option_price + total_discount;
	total_cost = model_cost + option_cost;

	var markup = (total_price / total_cost - 1);
	if (markup == Infinity) {
		markup = 1;
	}
	var r = {
		subtotal: total_price,
		cost: total_cost,
		markup: markup,
		discount: total_discount,
		tax: (sales_tax * total_price) - total_price,
		total: sales_tax * total_price,
		tax_rate: sales_tax,
	};
	$('.display_price').text(numeral(r.subtotal).format('$0.00'));
	$('.display_cost').text(numeral(r.cost).format('$0.00'));
	$('.display_markup').text(numeral(r.markup).format('0.00%'));
	$('.display_discount').text(numeral(r.discount).format('$0.00'));
	$('.display_tax').text(numeral(r.tax).format('$0.00'));
	$('.display_total').text(numeral(r.total).format('$0.00'));

	return r;
}

function markupCalculator(id) {
	var angle = $('#' + id);
	var formatted_id = id.replace('_edit','');
	var type = angle.attr('angle');
	var value = angle.val();
	var quote = saveQuote();
	if (type == 'markup') {
		$('#' + formatted_id).text(numeral(value).format('0.00%'));
	}
	else {
		$('#' + formatted_id).text(numeral(value).format('$0.00'));
	}
	var r = {

	};
	if (type == 'total') {
		r.total = numeral(value).value();
		r.subtotal = r.total / sales_tax;
		r.tax = ( r.subtotal * sales_tax ) - r.subtotal;
		$('.display_price').text(numeral(r.subtotal).format('$0.00'));
		$('.display_tax').text(numeral(r.tax).format('$0.00'));

	}
	else if (type == 'price') {
		r.subtotal = numeral(value).value();
		r.total = r.subtotal * sales_tax;
		var tax = ( r.subtotal * sales_tax ) - r.subtotal;
		$('.display_total').text(numeral(r.total).format('$0.00'));
		$('.display_tax').text(numeral(r.tax).format('$0.00'));
	}
	else if (type == 'cost') {

	}
	else if (type == 'markup') {

	}
	else if (type == 'discount') {

	}

	var ratio = quote.numbers.subtotal / r.subtotal;
	var discount = 0;
	$('.item_model,.item_option').each(function(i,v) {
		if ($(v).attr('select') == 'on') {
			var percentage = (numeral($(v).attr('price')).value() + numeral($(v).attr('discount')).value()) / quote['numbers']['subtotal'];
			var original_price = numeral($(v).attr('original_price')).value();
			var discounted = numeral($(v).attr('original_discount')).value();
			var new_price = r.subtotal * percentage;

			discounted = (new_price - original_price);
			discount += (new_price - original_price);
			$(v).attr('discount', discounted);
			$(v).attr('price', new_price);
			var uuid = $(v).attr('uuid');
			var opd = $('.original_price_display[uuid="' + uuid + '"]');
			var pd = $('.price_display[uuid="' + uuid + '"]');
			pd.text(numeral(new_price).format('$0.00'));
			if (discounted != 0) {
				opd.show();
				pd.css({ 'color': 'red' });
			}
			else {
				opd.hide();
				pd.css({ 'color': 'black' });
			}
		}

	});



}


$(document).on('keyup click change', '#customer_search', function() {
	var search = $(this).val();
	var movement = $('.store_movement').val();
	$.ajax({
		url: '/manager/store/customer_search',
		type: 'GET',
		data: { search: search, movement: movement },
		success: function(response) {
			if (response.count > 0) {
				$('#customer_search_results').html(response.results).show();;
			}
			else {
				$('#customer_search_results').html('').hide();
			}
		}
	});
});

$(document).on('click', '.cx_result', function() {
	var cx = $(this).attr('cx');
	$('#customer_search_results').hide();
	$('#customer_cancel').show();
	customerGrabber(cx);
});

function customerGrabber(cx) {
	$.ajax({
		url: '/manager/store/customer_load',
		type: 'GET',
		data: { cx: cx },
		success: function(response) {
			$('#customer').html(response.content);
			$('#customer_search').val(response.formatted_name);
			cx_uuid = response.settings.uuid;
			$('.save_quote').attr('cx', cx_uuid).show();
			$('#customer_cancel').show();
			localStorage.setItem('cx_uuid', cx_uuid);
			$('#customer_search_results').hide();
			if ($('#main_viewer').is(':visible')) {
				var list = $('#main_viewer').attr('type');
				customerList(cx_uuid,list);
			}
			$('#customer_search').hide();
			$('.customer_name').text(response.formatted_name).attr('onclick', 'appointmentGrabber(\'' + response.settings.app + '\')');
		}
	});
}

$(document).on('click', '.customer_list', function() {
	var list = $(this).attr('type');
	if ($('#main_viewer').attr('type') == list) {
		$('#main_viewer').html('').hide().attr('type','');
	}
	else {
		customerList(cx_uuid,list);
	}
});

function customerList(cx,list) {
	$.ajax({
		url: '/manager/store/customer_list',
		type: 'GET',
		data: { cx: cx, list: list },
		success: function(response) {
			$('#main_viewer').html(response.content).show().css({ 'background-color': response.settings.colour });
			$('#main_viewer').attr('type', list);
		}
	});
}

$(document).on('click', '.main_viewer_cancel_button', function() {
	$('#main_viewer').html('').hide().attr('type', '');
});

$(document).on('click', '#customer_cancel', function() {
	cx_uuid = '';
	$('#cx').remove();
	$('.save_quote').hide();
	$('#customer_search').val('');
	$('#customer_cancel').hide();
	$('#customer_search').show();
	$('.customer_name').hide().text('');
	$('#main_viewer').html('').hide().attr('type','');
	localStorage.removeItem('cx_uuid');
});

$(document).on('keydown', function(e) {
	if (topWindow() == 'store') {
/*
		if (e.keyCode == 37) {
			galleryImageControl('prev');
		}
		if (e.keyCode == 39) {
			galleryImageControl('next')
		}
*/
	}
});
