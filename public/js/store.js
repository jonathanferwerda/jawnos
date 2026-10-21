var cx_uuid = '';
var original_title;
var quote = { info: {}, model: [], options: {} };
var storeState = {
	category: null,
	subcategory: null,
	types: {},
	sort: 'name',
	search: '',
	request: 0
};

$(document).ready(function() {
	storeInitializer();
});

// Translate a generated label without inventing a second English copy in the JS.
function storeT(text) {
	var args = Array.prototype.slice.call(arguments);
	if (typeof jawnosT === 'function') {
		return jawnosT.apply(null, args);
	}
	return String(text).replace(/\{(\d+)\}/g, function(m, i) {
		return args[(+i) + 1] !== undefined ? args[(+i) + 1] : m;
	});
}

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
				if (q && q['item']) {
					storeItem(q['item'],q);
				}
			}
		}, error: function (response) { }
	});
}

function storeInitializer() {
	$('#right_ribbon').show();
	$('#bottom_ribbon').show();
	var search = localStorage.getItem('store_search') || '';
	$('#store_search').val(search);
	storeState.search = search;
	$('#store_search').off('.store').on('input.store search.store keyup.store', function() {
		storeSearch();
	});
	cx_uuid = localStorage.getItem('cx_uuid') || '';
	if (cx_uuid) {
		customerGrabber(cx_uuid);
	}

	// One chip per type, remembered as a filter rather than re-queried.
	storeState.types = {};
	$('.store_item_type').each(function(i,v) {
		var type = $(v).attr('data-type');
		var status = localStorage.getItem('sit_' + type);
		status = (status === 'on') ? 'on' : 'off';
		$(v).attr('status', status);
		storeState.types[type] = (status === 'on');
	});

	var sort = localStorage.getItem('store_sort');
	if (sort) {
		storeState.sort = sort;
		$('#store_sort').val(sort);
	}

	storeState.category = localStorage.getItem('store_category') || null;
	// A shelf that has since emptied is no longer in the rail; do not open a dead
	// category just because an old visit remembered it.
	if (storeState.category && !$('.store_category').filter(function() {
		return $(this).attr('category') === storeState.category;
	}).length) {
		storeState.category = null;
		localStorage.removeItem('store_category');
	}
	if (search.length >= 2) {
		storeSearch(true);
	}
	else if (storeState.category) {
		storeCategoryOpener(storeState.category);
	}
	else {
		// Open the fullest shelf so the middle of the window is never a blank room.
		var best = null;
		var best_count = -1;
		$('.store_category').each(function() {
			var n = parseInt($(this).find('.store_category_count').text(), 10) || 0;
			if (n > best_count) {
				best_count = n;
				best = $(this);
			}
		});
		if (best) {
			storeCategoryOpener(best.attr('category'));
		}
		else {
			storeShowPrompt();
		}
	}
	original_title = $('title').text();
}

function storeTotalItems() {
	var total = 0;
	$('.store_category_count').each(function() {
		total += parseInt($(this).text(), 10) || 0;
	});
	return total;
}

function storeShowPrompt() {
	$('#store_browse_prompt').show();
	$('#store_items_grid').empty();
	var total = storeTotalItems();
	$('#store_result_count').text(storeT(total === 1 ? '{0} item' : '{0} items', total));
}

function storeCategoryOpener(category, keep_search) {
	if (!category) {
		storeCloseCategory();
		return;
	}
	storeHideDetail();
	if (!keep_search && $('#store_search').val()) {
		$('#store_search').val('');
		localStorage.removeItem('store_search');
		storeState.search = '';
	}
	storeState.category = category;
	storeState.subcategory = null;
	localStorage.setItem('store_category', category);
	$('.store_category').attr('status', 'closed').filter(function() {
		return $(this).attr('category') === category;
	}).attr('status', 'open');
	$('#store_subcategory_bar').hide().empty();
	$('#store_browse_prompt').hide();
	$('#items_view').attr('aria-busy', 'true');
	var request = ++storeState.request;
	$.ajax({
		url: '/store/category_grabber',
		type: 'GET',
		data: { category: category, timestamp: Date.now() },
		success: function(response) {
			if (request != storeState.request) { return; }
			$('#items_view').removeAttr('aria-busy');
			$('#store_items_grid').html(response.content);
			$('#store_browse_prompt').hide();
			$('#items_view').scrollTop(0);
			storeRenderSubcategories(category, response.subcategories || []);
			storeApplyFilters();
		}
	});
}

function storeCloseCategory() {
	storeState.category = null;
	storeState.subcategory = null;
	localStorage.removeItem('store_category');
	$('.store_category').attr('status', 'closed');
	$('#store_subcategory_bar').hide().empty();
	storeShowPrompt();
}

function storeRenderSubcategories(category, subs) {
	var bar = $('#store_subcategory_bar').empty();
	if (!subs || subs.length === 0) {
		bar.hide();
		return;
	}
	var all = $('<button type="button" class="store_chip store_subcategory" data-subcategory="" status="on"></button>').text(storeT('All'));
	bar.append(all);
	$.each(subs, function(i, sub) {
		var chip = $('<button type="button" class="store_chip store_subcategory" status="closed"></button>')
			.attr({ 'data-subcategory': sub.name, 'subcategory': sub.name, 'category': category });
		chip.append($('<span>').text(sub.label || sub.name));
		chip.append($('<span class="store_chip_count">').text(sub.count));
		bar.append(chip);
	});
	bar.show();
}

// Everything the browse pane shows is already in the DOM: filtering and sorting
// are local, so a tap never waits for a round trip and the result count is exact.
function storeApplyFilters() {
	var cards = $('#store_items_grid .store_item');
	if (cards.length === 0) {
		storeUpdateCount(0, 0);
		return;
	}
	$('#store_items_grid .store_filter_empty').remove();

	var type_filter = [];
	$.each(storeState.types, function(type, on) {
		if (on) { type_filter.push(type); }
	});
	var sub = storeState.subcategory;
	var counts = {};
	cards.each(function() {
		var card = $(this);
		var type = card.attr('data-type') || 'product';
		counts[type] = (counts[type] || 0) + 1;
		var show = true;
		if (type_filter.length && type_filter.indexOf(type) < 0) { show = false; }
		if (sub && card.attr('data-subcategory') !== sub) { show = false; }
		card.toggle(show);
	});

	var sorted = cards.get();
	sorted.sort(function(a, b) {
		var an = $(a).attr('data-name') || '';
		var bn = $(b).attr('data-name') || '';
		if (storeState.sort === 'price_asc' || storeState.sort === 'price_desc') {
			var ap = parseFloat($(a).attr('data-price')) || 0;
			var bp = parseFloat($(b).attr('data-price')) || 0;
			if (ap !== bp) { return storeState.sort === 'price_asc' ? ap - bp : bp - ap; }
		}
		return an.localeCompare(bn);
	});
	$('#store_items_grid').append(sorted);

	$('.store_item_type').each(function() {
		var chip = $(this);
		var type = chip.attr('data-type');
		var n = counts[type] || 0;
		chip.find('.store_chip_count').text(n);
		chip.prop('disabled', n === 0 && !storeState.types[type]);
	});

	var visible = cards.filter(':visible').length;
	storeUpdateCount(visible, cards.length);
	if (visible === 0) {
		var empty = $('<div class="store_empty_state store_empty_inline store_filter_empty"></div>');
		empty.append($('<h3>').text(storeT('Nothing matches these filters')));
		empty.append($('<p>').text(storeT('Clear a type or subcategory, or try another search.')));
		$('#store_items_grid').append(empty);
	}
}

function storeUpdateCount(visible, total) {
	if (storeState.search) {
		$('#store_result_count').text(storeT(visible === 1 ? '{0} result' : '{0} results', visible));
	}
	else if (visible === total) {
		$('#store_result_count').text(storeT(total === 1 ? '{0} item' : '{0} items', total));
	}
	else {
		$('#store_result_count').text(storeT('{0} of {1} items', visible, total));
	}
}

$(document).on('click', '.store_category', function() {
	var category = $(this).attr('category');
	var status = $(this).attr('status');
	if (status === 'open') {
		storeCloseCategory();
	}
	else {
		storeCategoryOpener(category);
	}
});

$(document).on('click', '.store_subcategory', function() {
	var chip = $(this);
	var sub = chip.attr('data-subcategory') || '';
	var was_on = chip.attr('status') === 'on';
	$('#store_subcategory_bar .store_subcategory').attr('status', 'closed');
	if (!sub || was_on) {
		storeState.subcategory = null;
		$('#store_subcategory_bar .store_subcategory[data-subcategory=""]').attr('status', 'on');
	}
	else {
		chip.attr('status', 'on');
		storeState.subcategory = sub;
	}
	storeApplyFilters();
});

$(document).on('click', '.store_item_type', function() {
	if ($(this).is(':disabled')) { return; }
	var chip = $(this);
	var type = chip.attr('data-type');
	var on = chip.attr('status') === 'on';
	chip.attr('status', on ? 'off' : 'on');
	storeState.types[type] = !on;
	localStorage.setItem('sit_' + type, on ? 'off' : 'on');
	storeApplyFilters();
});

$(document).on('change', '#store_sort', function() {
	storeState.sort = $(this).val() || 'name';
	localStorage.setItem('store_sort', storeState.sort);
	storeApplyFilters();
});

$(document).on('click', '#store_clear_filters', function() {
	$('#store_search').val('');
	localStorage.removeItem('store_search');
	storeState.search = '';
	storeState.subcategory = null;
	storeState.sort = 'name';
	$('#store_sort').val('name');
	localStorage.removeItem('store_sort');
	$('.store_item_type').each(function() {
		var type = $(this).attr('data-type');
		$(this).attr('status', 'off');
		storeState.types[type] = false;
		localStorage.setItem('sit_' + type, 'off');
	});
	if (storeState.category) {
		storeCategoryOpener(storeState.category);
	}
	else {
		storeCloseCategory();
	}
});

var storeSearchInterval;
function storeSearch(immediate) {
	clearTimeout(storeSearchInterval);
	var run = function() {
		var search = $.trim($('#store_search').val() || '');
		storeState.search = search;
		if (search.length >= 2) {
			localStorage.setItem('store_search', search);
			storeHideDetail();
			$('.store_category').attr('status', 'closed');
			$('#store_subcategory_bar').hide().empty();
			storeState.subcategory = null;
			$('#store_browse_prompt').hide();
			var request = ++storeState.request;
			$.ajax({
				url: '/store/search',
				type: 'POST',
				data: { search: search, timestamp: Date.now() },
				success: function(response) {
					if (request != storeState.request) { return; }
					$('#store_items_grid').html(response.content);
					$('#items_view').scrollTop(0);
					storeApplyFilters();
				}
			});
		}
		else {
			localStorage.removeItem('store_search');
			storeState.search = '';
			if (storeState.category) {
				storeCategoryOpener(storeState.category, true);
			}
			else {
				storeShowPrompt();
			}
		}
	};
	if (immediate) {
		run();
	}
	else {
		storeSearchInterval = setTimeout(run, 250);
	}
}

$(document).on('click', '.store_item', function() {
	var item = $(this).attr('item');
	if (!quote || quote.item !== item) {
		quote = { info: {}, model: [], options: {} };
	}
	storeItem(item, quote);
});

function storeItem(item,quote) {
	if (!quote) { quote = { info: {}, model: [], options: {} }; }
	var manufacturer = $('#item_manufacturer_select').val();
	var jQuote = JSON.stringify(quote);
	$.ajax({
		url: '/store/item',
		type: 'GET',
		data: { item: item, manufacturer: manufacturer, quote: jQuote },
		success: function(response) {
			$('#item_view').html(response.template);
			$('#item_view').prepend($('<button type="button" class="store_text_button store_detail_back"></button>').text(storeT('Back to items')));
			$('#item_view').scrollTop(0);
			$('#main_window').addClass('store_detail_open');
			$('#item_manufacturer_select').val(manufacturer);
			$('#specs').html(response.settings ? response.settings.specs : '');
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
			if (!response.settings) {
				setTimeout(storeCloseDetail, 2000);
			}
		}
	});
}

function storeHideDetail() {
	$('#main_window').removeClass('store_detail_open');
	$('#item_view').empty();
	$('#specs_toggle, #specs_balloon').hide();
}

function storeCloseDetail() {
	storeHideDetail();
	localStorage.removeItem('quote');
	quote = { info: {}, model: [], options: {} };
}

$(document).on('click', '.store_detail_back', function() {
	storeHideDetail();
});

$(document).on('change', '#item_manufacturer_select', function() {
	var item = $(this).closest('.item').attr('item');
	storeItem(item,saveQuote());
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
	storeCloseDetail();
});

$(document).on('click', '.save_quote', function() {
	var i = $(this).closest('.item');
	storeWriter();
});

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
		a.css({'background-color': '#d64570' });
		setTimeout(function() {
			a.css({'background-color': '' });
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
	var model_quantity = numeral($('.item_model[select="on"]').find('.quantity').val() || 1).value();
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
	// the model is charged by its quantity as the options are: a quantity that
	// only rode along in the quote used to price as one
	total_discount = Math.abs(model_discount * model_quantity + option_discount) * -1;
	total_price = model_price * model_quantity + option_price + total_discount;
	total_cost = model_cost * model_quantity + option_cost;

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
				pd.attr('data-discounted', 'yes');
			}
			else {
				opd.hide();
				pd.removeAttr('data-discounted');
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
			$('#main_viewer').html(response.content).show();
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

// ---- crypto payment on an invoice ------------------------------------------
// The seller asks for a coin amount to an address, then records what arrived.
// A PAY1Z proof, when given, is verified by the server and countersigned; a
// device with an enrolled fingerprint asks for it before the record is made.
function cryptoPayWallets(scope) {
	try { return JSON.parse(scope.attr('data-wallets') || '[]'); } catch (e) { return []; }
}

function cryptoPayAddress(scope) {
	var opt = scope.find('#crypto_pay_wallet option:selected');
	var address = opt.attr('data-address') || '';
	scope.find('#crypto_pay_address').text(address || '(no address saved)');
	var img = scope.find('#crypto_pay_qr');
	if (address) {
		img.attr('src', '/manager/crypto/qr?text=' + encodeURIComponent(address)).show();
	}
	else {
		img.removeAttr('src').hide();
	}
}

function cryptoPayRefresh(scope) {
	var asset = scope.find('#crypto_pay_asset').val();
	var wallets = cryptoPayWallets(scope).filter(function(w) { return w.asset === asset; });
	var ws = scope.find('#crypto_pay_wallet');
	ws.empty();
	if (!wallets.length) {
		ws.append($('<option>').attr('value', '').text('(no wallet for this coin)'));
		scope.find('#crypto_pay_address').text('');
		scope.find('#crypto_pay_qr').removeAttr('src').hide();
		scope.find('#crypto_pay_fiat').text('no wallet');
		return;
	}
	wallets.forEach(function(w) {
		ws.append($('<option>')
			.attr('value', w.app)
			.attr('data-address', w.address || '')
			.text(w.formatted_name + (w.label ? ' · ' + w.label : '')));
	});
	cryptoPayAddress(scope);
	var balance = numeral(scope.attr('data-balance')).value();
	$.getJSON('/manager/crypto/rates', function(r) {
		var rate = (r && r.rates) ? r.rates[asset] : null;
		if (!rate) { scope.find('#crypto_pay_fiat').text('no rate loaded'); return; }
		scope.find('#crypto_pay_amount').val(numeral(balance / rate).format('0.00000000'));
		scope.find('#crypto_pay_fiat').text('≈ ' + numeral(balance).format('$0.00') + ' at ' + numeral(rate).format('$0,0.00'));
	});
}

$(document).on('click', '.crypto_payment', function() {
	var icon = $(this);
	$.post('/manager/store/crypto_panel', {
		uuid: icon.attr('uuid'), cx_uuid: icon.attr('cx_uuid'), timestamp: Date.now()
	}, function(r) {
		if (!r || !r.ok) { alert((r && r.error) || 'could not open the crypto payment'); return; }
		$('#crypto_pay').remove();
		$('body').append(r.html);
		cryptoPayRefresh($('#crypto_pay'));
	}, 'json');
});

$(document).on('change', '#crypto_pay_asset', function() {
	cryptoPayRefresh($(this).closest('#crypto_pay'));
});

$(document).on('change', '#crypto_pay_wallet', function() {
	cryptoPayAddress($(this).closest('#crypto_pay'));
});

$(document).on('click', '#crypto_pay_close', function() {
	$('#crypto_pay').remove();
});

$(document).on('click', '#crypto_pay_copy', function() {
	var text = $(this).closest('#crypto_pay').find('#crypto_pay_address').text();
	if (!text) { return; }
	var input = $('<input>').val(text).appendTo('body').trigger('select');
	try { document.execCommand('copy'); } catch (e) {}
	input.remove();
});

$(document).on('click', '#crypto_pay_record', function() {
	var scope = $(this).closest('#crypto_pay');
	var status = scope.find('#crypto_pay_status');
	var data = {
		uuid: scope.attr('data-uuid'),
		cx_uuid: scope.attr('data-cx'),
		asset: scope.find('#crypto_pay_asset').val(),
		amount: scope.find('#crypto_pay_amount').val(),
		account: scope.find('#crypto_pay_wallet').val(),
		address: scope.find('#crypto_pay_address').text(),
		txid: scope.find('#crypto_pay_txid').val(),
		proof: scope.find('#crypto_pay_proof').val(),
		timestamp: Date.now()
	};
	function postPayment() {
		status.text('recording…');
		$.post('/manager/store/crypto_payment', data, function(r) {
			if (!r || !r.ok) {
				status.text((r && r.need_biometric)
					? (r.need_other_device ? 'another device must approve — press Verify again' : 'fingerprint confirmation is needed — try again')
					: ((r && r.error) || 'could not record'));
				return;
			}
			var label = r.verified === 'crest'
				? (r.payer_known ? 'attested by a known crest' : 'attested by a new crest')
				: (r.verified === 'crest-unsigned' ? 'proof verified (not countersigned)' : 'recorded (no crest proof)');
			status.text(label + ' · balance ' + numeral(r.balance).format('$0.00'));
			customerList(scope.attr('data-cx'), 'invoice');
			setTimeout(function() { scope.remove(); }, 1400);
		}, 'json').fail(function() { status.text('could not record'); });
	}
	var mode = scope.attr('data-bio') || 'none';
	if (mode === 'self') {
		if (typeof jawnosBiometricVerify !== 'function' || !window.JawnBiometricKey) {
			status.text('This device has no fingerprint key here — record from the phone with the fingerprint.');
			return;
		}
		jawnosBiometricVerify(function(t) { status.text(t); }).then(function(proof) {
			data.bio_nonce = proof.nonce;
			data.bio_signature = proof.signature;
			postPayment();
		}).catch(function(err) {
			status.text((typeof jawnosBiometricError === 'function') ? jawnosBiometricError(err) : 'fingerprint not accepted');
		});
	}
	else if (mode === 'other') {
		status.text('asking another device in the house for a fingerprint…');
		$.post('/manager/crypto/payment_request', data, function(r) {
			if (!r || !r.ok) { status.text((r && r.error) || 'no device could be asked'); return; }
			var id = r.id;
			var started = Date.now();
			var iv = setInterval(function() {
				if (Date.now() - started > 120000) {
					clearInterval(iv);
					status.text('the request expired — try again');
					return;
				}
				$.getJSON('/manager/crypto/payment_request', { id: id }, function(s) {
					if (!s || !s.ok) { return; }
					if (s.approved) {
						clearInterval(iv);
						status.text('approved by ' + (s.by || 'another device') + '…');
						data.payment_request_id = id;
						postPayment();
					}
					else if (s.expired) {
						clearInterval(iv);
						status.text('the request expired — try again');
					}
				});
			}, 1500);
		}, 'json').fail(function() { status.text('no device could be asked'); });
	}
	else {
		postPayment();
	}
});

$(document).on('click', '#crypto_pay_crest_copy', function() {
	var text = $('#crypto_pay_crest').text();
	if (!text) { return; }
	var input = $('<input>').val(text).appendTo('body').trigger('select');
	try { document.execCommand('copy'); } catch (e) {}
	input.remove();
});
