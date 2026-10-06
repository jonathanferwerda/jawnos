
var originalTransactionAutofills = {};


$(document).on('change', '.purchase_input', function() {
	var input = $(this);
	var pd = input.closest('.purchase_details');

	var ad = pd.closest('.app_details');
	var movement = ad.find('.movement').val();
	var timestamp = Date.now();
	var container = input.closest('.appointment');
	var app = container.attr('app');
	if (!originalTransactionAutofills[app]) { originalTransactionAutofills[app] = { 'model': {}, 'option': {} }; }
	var name = input.attr('name');
	var value = input.val();
	var length = value.length;
	var attribute = input.attr('attribute');
	if (!$(this).is('select') && $(this).attr('type') != 'checkbox') {
		if (1) {
			$.ajax({
				url: '/manager/transaction/autofill',
				type: 'GET',
				data: { attribute: attribute, name: name, timestamp: timestamp, app: app, value: value, movement: movement },
				success: function(response) {
					if (response.unformatted) {
						if (response.formatted) {
							input.val(response.formatted);
							transactionStorageSaver(app);
						}
						if (name == 'item') {
							var pu = pd.find('.purchase_input[name="unit"]');
							var pa = pu.find('.purhcase_autofilled');
							pa.remove();
							pu.prepend('<option class="purhcase_autofilled" value="' + response.unformatted + '">' + response.formatted + '</option>');
						}
						if (name == 'quantity' && response.unit) {
							pd.find('.purchase_input[attribute="unit"]').val(response.unit);
						}
						var ti = pd.find('.transaction_information[app="' + app + '"]');
						if (name == 'vendor' && response.informations.length > 0) {
							var informations = response.informations || [];
							var htmls = [];
							var seen_htmls = [];
							pd.find('.purchase_input[attribute="information"]').each(function(i,v) {
								var okay = $.grep(seen_htmls, function(t,i) { return i == $(v).attr('uuid') });

								if (okay.length == 0) {
									seen_htmls.push($(v).attr('uuid'));
									htmls.push('<option value="' + $(v).attr('uuid') + '">' + $(v).html() + '</option>');
								}
							});
							$.each(informations,function(i,v) {
								var vj = JSON.parse(v.data);
								var okay = $.grep(seen_htmls, function(t,i) { return i == v.uuid });
								if (okay.length == 0) {
									htmls.push('<option value="' + v.uuid + '">' + vj.id + ' - ' + numeral(vj.numbers.total).format('$0.00') + '</option>');
									seen_htmls.push(v.uuid);
								}
							});
							ti.html(htmls.join(''));
							ti.show();
						}
						else if (name == 'vendor' && response.informations == 0) {
							ti.html('').hide();
							ti.val('');
							container.find('.transaction_information').val(undefined).html('').hide();
						}
					}
					else {
					//	container.find('.transaction_information').val(undefined).html('').hide();
					}

					var amsc = $('.appointment_model_selector_container[attribute="' + name + '"]');
					if (response.models && response.unformatted != '') {

						if (amsc.html().match('[a-zA-Z]') && !originalTransactionAutofills[app]['model'][name]) {
							originalTransactionAutofills[app]['model'][name] = amsc.html();
						}
						amsc.html(response.models);
					}
					else {
						amsc.html(originalTransactionAutofills[app]['model'][name]);
					}
					var asoc = pd.find('.appointment_option_selector_container[attribute="' + name + '"]');
					if (response.options && response.unformatted != '') {

						if (amsc.html().match('[a-zA-Z]') && !originalTransactionAutofills[app]['option'][name]) {
							originalTransactionAutofills[app]['option'][name] = amsc.html();
						}
						asoc.html(response.options);
					}
					else {
						asoc.html(originalTransactionAutofills[app]['option'][name]);
					}
				}
			});
		}
	}
	else {
		if (input.attr('type') == 'checkbox') {
			if (input.prop('checked') == true) {
				value = 'on';
			}
			else {
				value = 'off';
			}
		}
		settingSetter({ 'app': app, 'setting': name, 'value': value });
	}
});

$(document).on('change', '.transaction_information', function() {
	var app = $(this).attr('app');
	var appt = $(this).closest('.appointment');
	var window_app = appt.attr('app');
	var pd = $(this).closest('.purchase_details');
	var uuid = $(this).val();
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/transaction/information',
		type: 'GET',
		data: { app: app, timestamp: timestamp, uuid: uuid },
		success: function(response) {

			pd.find('.transaction_information_viewer[app="' + app + '"]').html(response.html).show().val(uuid);
			if (response.transaction) {

				$.each(response.autofillers, function(i,v) {
					pd.find('.purchase_input[attribute="' + v + '"]').val(response.transaction.data['formatted_' + v]).trigger('change');
				});
					pd.find('.purchase_config[attribute="has_totes"]').attr('enabled', 'on');
				pd.find('.purchase_input[attribute="amount"]').val(response.transaction.data.numbers.price);
				if (response.transaction.data.numbers.tax) {
					pd.find('.purchase_config[attribute="has_tax"]').attr('enabled', 'on');
					pd.find('.purchase_input[attribute="tax"]').val(response.transaction.data.numbers.tax);
				}
				else {
					pd.find('.purchase_config[attribute="has_tax"]').attr('enabled', 'off');
				}

				pd.find('.purchase_input[attribute="aux"]').val(response.transaction.data.numbers.aux);
				pd.find('.purchase_input[attribute="total"]').val(response.transaction.data.numbers.balance).trigger('change');
				setTimeout(function() {
					pd.find('.transaction_information').val(uuid);
					pd.find('.purchase_input[attribute="model"]').val(response.transaction.data.model.uuid);
					pd.find('.appointment_model_quantity').val(response.transaction.data.model.quantity);
					pd.find('.appointment_model_unit').val(response.transaction.data.model.unit);
					$.each(response.transaction.data.options, function(i,v) {
						$.each(v, function(ir,vr) {
							var ao = pd.find('.appointment_option[uuid="' + vr.uuid + '"]');
							ao.attr('select','on');
							ao.find('.appointment_option_quantity').val(vr.quantity);
							ao.find('.appointment_option_unit').val(vr.unit);
						});
					});
				},200);
				transactionStorageSaver(window_app);
			}


		}
	});

});

$(document).on('change', '.purchase_input', function() {
	var e = $(this);
	var iq = $(this).closest('.app_details');
	var app = iq.attr('app');
	iq = e.closest('.purchase_details');
	var quantity_in = iq.find('.quantity');
	var quantity = numeral(quantity_in.val() || 1).value();
	var multiplier = 1;
	var totes = iq.find('.purchase_config[config="totes"]').attr('enabled');
	var tax = iq.find('.purchase_config[config="tax"]').attr('enabled');
	var original_me_tax = me_tax;
	if (totes != 'on') {
		if (quantity_in.attr('previously')) {
			var previously = numeral(quantity_in.attr('previously')).value();
			if (quantity < previously) {
				multiplier = quantity / previously;
			}
			else {
				multiplier = quantity;
			}
		}
		else {
			multiplier = quantity;
		}
	}
	if (tax != 'on') {
		me_tax = 1;
	}
	var vendor = iq.find('.vendor').val();
	var ago = iq.find('.ago').val();

	var account = iq.find('.account').val();
	var amount_in = iq.find('.amount');
	var amount = numeral(amount_in.val()).value();

	var tax_in = iq.find('.tax');
	var tax = numeral(tax_in.val()).value();

	var aux_in = iq.find('.aux');
	var aux = numeral(aux_in.val()).value();

	var total_in = iq.find('.total');
	var total = numeral(total_in.val()).value();
	$.each([total_in, amount_in, quantity_in, tax_in, aux_in], function(i,v) {
		var previously = $(v).val();
		$(v).attr('previously', previously);
	});
	var timestamp = Date.now();
	if (e.hasClass('total')) {
		total = total * multiplier;
		total_in.val(numeral(total).format('0.00'));
		amount = total / me_tax;
		amount_in.val(numeral(amount).format('0.00'));
		tax = ((amount * me_tax) - amount);
		tax_in.val(numeral(tax).format('0.00'));
		aux = total - tax - amount;
	}
	else if (e.hasClass('aux')) {
		//$('.amount').val(numeral(total - aux - tax).format('0.00'));
		total_in.val(numeral(amount + aux + tax).format('0.00'));
	}
	else if (e.hasClass('tax')) {
		amount_in.val(numeral((total - aux - tax)).format('0.00'))
	}
	else if (e.hasClass('amount')) {
		amount = amount * multiplier;
		amount_in.val(numeral(amount).format('0.00'));
		total = amount * me_tax;
		total_in.val(numeral(total).format('0.00'));
		tax = ((amount * me_tax) - amount);
		tax_in.val(numeral(tax).format('0.00'));
	}
	else if (e.hasClass('quantity')) {
		amount = amount * multiplier;
		amount_in.val(numeral(amount).format('0.00'));
		total = amount * me_tax;
		total_in.val(numeral(total).format('0.00'));
		tax = ((amount * me_tax) - amount);
		tax_in.val(numeral(tax).format('0.00'));
	}
	else {
		amount = amount * multiplier;
		amount_in.val(numeral(amount).format('0.00'));
		total = amount * me_tax;
		total_in.val(numeral(total).format('0.00'));
		tax = ((amount * me_tax) - amount);
		tax_in.val(numeral(tax).format('0.00'));
	}
	me_tax = original_me_tax;
	transactionStorageSaver(app);

});

$(document).on('keyup click', '.purchase_input', function() {
	var me = $(this);
	var value = me.val();
	var attribute = me.attr('attribute');
	var ad = me.closest('.app_details');
	var pd = me.closest('.purchase_details');
	var app = ad.attr('app');
	if (!me.is('select') && me.attr('type') != 'checkbox') { 
		$.ajax({
			url: '/manager/transaction/autocomplete',
			type: 'GET',
			data: { attribute: attribute, value: value, app: app },
			success: function(response) {
				var offset = me.offset();
				var random = Math.random();
				var now = Date.now();
				var width = me.width();
				var html = '';
				$.each(response, function(i,v) {
					if (v.unformatted != '') {
						html += '<div class="autocomplete_item hover" style="height:30px;" uuid="' + random + '" formatted="' + v.formatted + '" value="' + v.unformatted + '">' + v.formatted + '</div>';
					}
				});
				var ac = ad.find('.transaction_autocomplete');
				ac.html(html).show();
				ac.attr('attribute', attribute);
				ac.attr('timestamp', now);
				ac.height(30 * response.length);
				ac.css({ 'top': offset.top - ac.height() - 3, 'left': offset.left, 'width': width });
				me.attr('temp_uuid', random);
			}
		});
	}
});

$(document).on('blur', '.purchase_input', function() {
	setTimeout(function() {
		var now = Date.now();
		var ac = $('.transaction_autocomplete');
		$.each(ac, function(i,v) {
			if ($(v).attr('timestamp') < now - 300) {
				$(v).html('').hide();
			}
		});
	},500);
});

$(document).on('click', '.autocomplete_item', function() {

	var item = $(this);
	var uuid = item.attr('uuid');
	var ad = item.closest('.app_details');
	var ac = ad.find('.transaction_autocomplete');
	var attribute = ac.attr('attribute');
	var input = ad.find('.purchase_input[temp_uuid="' + uuid + '"]');
	input.val(item.attr('formatted')).trigger('change');
	$('.transaction_autocomplete').html('').hide();
});

function transactionStorageSaver(app) {
	var appt = $('.appointment[app="' + app + '"]');
	var movement = appt.find('.movement.app_setting[attribute="movement"]').val();
	var uuid = appt.find('.app_details').attr('uuid');
	var vendor = appt.find('.vendor.purchase_input').val();
	var information = appt.find('.transaction_information.purchase_input').val();
	var storage = localStorage.getItem('transactionSaver_' + app);
	var worth_it = 0;
	storage = {};
	if (!storage[movement]) {
		storage[movement] = {};
		storage[movement]['totals'] = { uuid: uuid, vendor: vendor, information: information };
	}
	$('.purchase_details[app="' + app + '"]').each(function(i,v) {
		var uuid = $(v).attr('uuid');
		if (!storage[movement][uuid]) {
			storage[movement][uuid] = {};
		}
		$(v).find('.purchase_input,.purchase_config').each(function(ir,vr) {
			var attribute = $(vr).attr('attribute');
			if (!storage[movement][uuid][attribute]) {
				
			}
			if ($(vr).attr('type') == 'checkbox') {
				if ($(vr).prop('checked')) {
					storage[movement][uuid][attribute] = 'on';	
				}
				else {
					storage[movement][uuid][attribute] = 'off';
				}
			}
			else {
				storage[movement][uuid][attribute] = $(vr).val() || $(vr).attr('enabled');
			}
			if (attribute == 'amount' || attribute == 'aux' || attribute == 'tax' || attribute == 'total') {
				storage[movement]['totals'][attribute] = numeral(storage[movement]['totals'][attribute]).value() + numeral(storage[movement][uuid][attribute]).value();
			}
		});




	});
	$('.transaction_total').each( function(i,v) {
		var att = $(v).attr('attribute');
		if (numeral(storage[movement]['totals'][att]).value() != 0) {
			worth_it = 1;
		}
		$(v).text(numeral(storage[movement]['totals'][att]).format('0.00'));
	});
	var jStorage = JSON.stringify(storage);
	if (worth_it == 1) {
		localStorage.setItem('transactionSaver_' + app, jStorage);
	}
	else {
		localStorage.removeItem('transactionSaver_' + app);
	}
	return storage;
}

function transactionStorageRetriever(app) {
	var appt = $('.appointment[app="' + app + '"]');
	var movement = appt.find('.movement.app_setting[attribute="movement"]').val();
	var storage = localStorage.getItem('transactionSaver_' + app);
	var storage = eval(JSON.parse(storage) || {});
	var uuid = appt.find('.app_details').attr('uuid');
	if (storage[movement]) {
		if (storage[movement]['totals']['uuid']) {
			appt.find('.vendor.purchase_input').val(storage[movement]['totals']['vendor']);
			uuid = storage[movement]['totals']['uuid'];
			appt.find('.app_details').attr('uuid', uuid);
			appt.find('.purchase_details').attr('uuid', uuid);
		}

		$.each(storage[movement], function(i,v) {
			if (i != 'totals') {
				if (uuid != i) {
					appt.find('.add_transaction_item').trigger('click');
					var count = appt.find('.purchase_details').length;
					$(appt.find('.purchase_details')[count - 1]).attr('uuid', i);
					$(appt.find('.purchase_details')[count - 1]).find('.remove_transaction_item').attr('uuid', i );
				}
				$.each(storage[movement][i], function(ir,vr) {
					var input = $('.purchase_details[app="' + app + '"][uuid="' + i + '"]').find('[attribute="' + ir + '"]');
					if (input.attr('type') == 'checkbox') {
						if (vr == 'on') {
							input.val('on').prop('checked', true);
						}
						else {
							input.val('off').prop('checked', false);
						}
					}
					else {
						input.val(vr);
					}
				});
			}
		});
	}
	appt.find('.purchase_input[attribute="vendor"]').trigger('change');

	transactionStorageSaver(app);
}


function transactionStorageDeleter(app) {
	var appt = $('.appointment[app="' + app + '"]');
	appt.find('.purchase_input').each(function(i,v) {
		if (!$(v).is('select')) {
			if ($(v).attr('attribute') == 'quantity') {
				$(v).val(1);
			}
			else {
				$(v).val('');
			}
		}
	});
	appt.find('.transaction_information').html('').val('').hide();
	appt.find('.transaction_information_viewer').html('').hide();
	appt.find('.appointment_model_selector_container').each(function(i,v) { $(v).html('').hide(); });
	appt.find('.appointment_option_selector_container').each(function(i,v) { $(v).html('').hide(); });
	var pd = appt.find('.purchase_details');
	var length = pd.length;
	for (var n = 1; n <= length; n++) {
		$(pd[n]).remove();
	}
	var storage = localStorage.removeItem('transactionSaver_' + app);
}

$(document).on('click', '.cancel_transaction', function() {
	var a = $(this);
	var app = a.attr('app');
	var fapp = a.closest('.appointment').attr('formatted_name');

	if (a.attr('armed') == 'yes') {
		transactionStorageDeleter(app);
		var obg = a.attr('obg');
		a.css({'background-color': obg });
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});


$(document).on('click', '.add_transaction_item', function() {
	var ad = $(this).closest('.app_details');
	var app = ad.attr('app');
	var original_uuid = ad.attr('uuid');
	var pd = $(this).closest('.app_details').find('.purchase_details[uuid="' + original_uuid + '"]');
	var pdhtml = pd.clone();
	var uuid = Math.random();
	pdhtml.attr('uuid', uuid);
	pdhtml.find('.purchase_input').each(function(i,v) {
		if (!$(v).is('select')) {
			$(v).val('');
		}
	});
	pdhtml.append('<img src="/icons/trash.png" class="little_thumb remove_transaction_item" uuid="' + uuid + '" app="' + app + '">');
	$(this).closest('.app_details').find('.transaction_movement_container').append(pdhtml);

});

$(document).on('click', '.remove_transaction_item', function() {
		var b = $(this);

	if (b.attr('armed') == 'yes') {
		var uuid = b.attr('uuid');
		var app = b.attr('app');
		$('.appointment[app="' + app + '"]').find('.purchase_details[uuid="' + uuid + '"]').remove();
		transactionStorageSaver(app);
	}
	else {
		b.attr('armed', 'yes');
		var bgcolor = b.css('background-color');
		b.css({'background-color': 'red' });
		setTimeout(function() {
			b.css({'background-color': bgcolor });
			b.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('click', '.transaction_history_retriever', function() {
	var thr = $(this);
	var app = thr.attr('app');
	var timestamp = thr.attr('timestamp') || Date.now();
	$.ajax({
		url: '/manager/transaction/history_retriever',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			thr.attr('timestamp',response.timestamp);
			var history = JSON.parse(response.data);
			localStorage.setItem('transactionSaver_' + app, response.data);
			transactionStorageRetriever(app);
		}
	});
});

$(document).on('keyup','.vendor',function() {
	var e = $(this);
	var span = e.next();
	span.children().each(function(i,v) {
		var text = v.text();
		if (text.match(/^(val)/)) { }
	});
	var text = e.val();
});

$(document).on('click', '.plusminus', function() {
	var iq = $(this).closest('.purchase_details');
	var app = iq.attr('app');
	$.each(['amount','tax','aux','total'], function(i,v) {
		var a = iq.find('.' + v).val();
		var b = a * -1;
		iq.find('.' + v).val(b);
	});
	transactionStorageSaver(app);
});

$(document).on('click', '.purchase_config', function() {
	var con = $(this);

	var config = con.attr('config');
	var pd = con.closest('.purchase_details');
	var app = pd.attr('app');
	var enabled = con.attr('enabled');
	if (enabled == 'on') {
		con.attr('enabled', 'off');
		con.css({ 'background-color':'lightgrey'});
	}
	else {
		con.css({ 'background-color':'lightgreen'});
		con.attr('enabled', 'on');
	}
	var new_enabled = con.attr('enabled');

	if (!con.closest('.appointment_edit_area')) {
		settingSetter({ 'app': app, 'setting': config, 'value': new_enabled });		
	}
	var total = pd.find('.purchase_input[attribute="total"]');
	var quantity = pd.find('.purchase_input[attribute="quantity"]');
	var new_total = total.val();
	if (config == 'tax') {
		if (new_enabled == 'on') {
			if (pd.find('.purchase_config[config="totes"]').attr('enabled') == 'on') {
				var new_total = numeral(total.val()).value() / numeral(quantity.val()).value();
				total.trigger('change');
			}
			else {

				var new_total = numeral(total.val()).value() * numeral(quantity.val()).value();
				quantity.trigger('change');
			}

		}
		else {
			if (pd.find('.purchase_config[config="totes"]').attr('enabled') == 'on') {
				var new_total = numeral(total.val()).value() / numeral(quantity.val()).value();
				total.trigger('change');
			}
			else {

				var new_total = numeral(total.val()).value() * numeral(quantity.val()).value();
				quantity.trigger('change');
			}
			total.trigger('change');
		}
	}
	if (config == 'totes') {
		var subtotal = pd.find('.purchase_input[attribute="amount"]');
		if (new_enabled == 'on') {
			new_total = numeral(total.val()).value() / numeral(quantity.val()).value();
			total.val(new_total);
			total.trigger('change');
		}
		else {
			new_total = numeral(total.val()).value() * numeral(quantity.val()).value();
			total.val(new_total);
			quantity.trigger('change');
		}
	}

	transactionStorageSaver(app);
});

$(document).on('change', '.transaction.movement', function() {

	var app = $(this).closest('.app_details').attr('app');
	var movement = $(this).val();
	if (movement == 'transfer') {
		$('.transferable_transaction').show();
		$('.purchase_details').hide();
		$('.inventory_transaction').hide();
	}
	else if (movement == 'inventory') {
		$('.transferable_transaction').hide();
		$('.purchase_details').hide();
		$('.inventory_transaction').show();
	}
	else {
		$('.transferable_transaction').hide();
		$('.purchase_details').show();
		$('.inventory_transaction').hide();
	}

	$.ajax({
		url: '/manager/transaction/movement',
		type: 'GET',
		data: {
			app: app,
			movement: movement
		},
		success: function(response) {
			$('.transaction_movement_container[app="' + app + '"]').html(response.html);
			transactionStorageRetriever(app);
		}
	});



});

$(document).on('change', '.app_setting', function() {
	var app = $(this).attr('app') || $(this).closest('.app_details').attr('app') || $(this).closest('.appointment').attr('app') || $(this).closest('.wind').attr('app');
	var setting = $(this).attr('attribute');
	var value = $(this).val();
	settingSetter({ 'app': app, 'setting': setting, 'value': value });
});



$(document).on('focus','.purchase_input', function() {
	if ($(this).val() == '0.00') {
		$(this).val('');
	}
});

$(document).on('click', '.record_purchase', function() {
	var timestamp = Date.now();
	var time_machine = localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');


	var iq = $(this).closest('.app_details');
	var app = iq.attr('app');
	var ago = iq.find('.ago').val();
	var warranty = iq.find('.warranty').val();
	var schedule = iq.find('.schedule').val();
	var duration = iq.find('.duration').val() || '';
	var navigation = iq.closest('.appointment').attr('navigation');
	var transaction_information = iq.find('.transaction_information').val();

	var account = iq.find('.account').val();
	var project = iq.find('.project').val();
	var notes = iq.find('.notes').val();
	var movement = iq.find('.movement').val();
	var currency = iq.find('.currency').val();

	var amount = iq.find('.amount').val();
	var quantity = iq.find('.quantity').val() || 1;
	var state = iq.find('.state').val();
	var manufacturer = iq.find('.manufacturer').val();
	var vendor = iq.find('.vendor').val();
	var record_vendor = iq.find('.record_vendor').val();
	if (record_vendor == true) {
		record_vendor = 'on';
	}
	var tax = iq.find('.tax').val();
	var has_tax = iq.find('.purchase_config[config="tax"]').attr('enabled');
	var has_totes = iq.find('.purchase_config[config="totes"]').attr('enabled');
	var aux = iq.find('.aux').val();
	var item = iq.find('.item').val();
	var model = iq.find('.model').val();
	var total = iq.find('.total').val();

	var unit = iq.find('.unit').val() || 1;

	var transfer_amount = iq.find('.transfer_amount').val();
	var transfer_aux = iq.find('.transfer_aux').val();
	var to_account = iq.find('.to_account').val();

	var data = { 
		ago: ago,
		duration: duration,
		warranty: warranty,
		schedule: schedule,
		timestamp: timestamp,
		currency: currency,
		app: app,
		notes: notes,
		account: account,
		project: project,
		movement: movement,
		time_machine: time_machine,
		timeshift: timeshift,
		amount: amount,
		item: item,
		state: state,
		model: model,
		tax: tax,
		aux: aux,
		total: total,
		manufacturer: manufacturer,
		vendor: vendor,
		record_vendor: record_vendor, 
		quantity: quantity,
		unit: unit,
		transfer_amount: transfer_amount,
		to_account: to_account,
		has_tax: has_tax,
		has_totes: has_totes,
		transaction_information: transaction_information
	};
	data['transactions'] = JSON.stringify(transactionStorageSaver(app));
	if (1 == 1) {
		$.ajax({
			url: '/manager/transaction/record',
			type: 'POST',
			data: data,
			success: function(response) {
				centreViewWriter(response['cv']);
				continent_record({'uuid':response['uuid'], 'app':response['app'],'purpose':'app','timestamp':response['timestamp'],'navigation':navigation});
				appointment_chron();
				appClearer(app);
				transactionStorageDeleter(app);
			}
		});
	}
});

