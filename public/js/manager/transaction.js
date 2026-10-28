
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
					var scope = pd.length ? pd : ad;
					if (!originalTransactionAutofills[app]) { originalTransactionAutofills[app] = { 'model': {}, 'option': {} }; }
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
						var ti = scope.find('.transaction_information[app="' + app + '"]');
						if (name == 'vendor' && response.informations.length > 0) {
							var informations = response.informations || [];
							var htmls = [];
							var seen_htmls = [];
							scope.find('.purchase_input[attribute="information"]').each(function(i,v) {
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
							ad.find('.tx_invoice_row').show();
						}
						else if (name == 'vendor' && response.informations == 0) {
							ti.html('').hide();
							ti.val('');
							ad.find('.tx_invoice_row').hide();
						}
					}
					else {
					//	container.find('.transaction_information').val(undefined).html('').hide();
					}

					var amsc = scope.find('.appointment_model_selector_container[attribute="' + name + '"]');
					var line_key = (pd.attr('uuid') || ad.attr('uuid')) + '|' + name;
					if (response.models && response.unformatted != '') {

						if (amsc.html().match('[a-zA-Z]') && !originalTransactionAutofills[app]['model'][line_key]) {
							originalTransactionAutofills[app]['model'][line_key] = amsc.html();
						}
						amsc.html(response.models);
					}
					else {
						amsc.html(originalTransactionAutofills[app]['model'][line_key]);
					}
					var asoc = scope.find('.appointment_option_selector_container[attribute="' + name + '"]');
					if (response.options && response.unformatted != '') {

						if (amsc.html().match('[a-zA-Z]') && !originalTransactionAutofills[app]['option'][line_key]) {
							originalTransactionAutofills[app]['option'][line_key] = amsc.html();
						}
						asoc.html(response.options);
					}
					else {
						asoc.html(originalTransactionAutofills[app]['option'][line_key]);
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
	txTenderChange(iq.closest('.app_details'));
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
				// the list is fixed to the viewport, so measure the input the same
				// way; above the field normally, below it when there is no room
				var rect = me[0].getBoundingClientRect();
				var list_top = rect.top - ac.height() - 3;
				if (list_top < 8) { list_top = rect.bottom + 3; }
				ac.css({ 'top': list_top, 'left': rect.left, 'width': width });
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
		// cash handed over and the change given back: not part of the ledger, but
		// kept with the transaction so a cash drawer can be checked against it
		var tendered = appt.find('.tx_tendered').val() || '';
		var change = appt.find('.tx_change').text() || '';
		storage[movement]['totals']['tendered'] = tendered;
		storage[movement]['totals']['change'] = (change == '\u2014' ? '' : change);
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

// Cash handled over the counter is not a ledger figure - the transaction is the
// total that left the account - but it is worth keeping beside the record so a
// drawer can be counted. The fields appear only for a cash account.
function txTenderPaint(ad) {
	if (!ad || !ad.length) { return; }
	var movement = ad.find('.movement').val();
	var opt = ad.find('.account option:selected');
	var label = ((opt.attr('data-payment') || '') + ' ' + (opt.text() || '')).toLowerCase();
	var cash = (movement == 'expense' || movement == 'income') && label.indexOf('cash') !== -1;
	ad.find('.tx_tender').toggleClass('tx_tender_on', cash);
	txTenderChange(ad);
}

function txTenderChange(ad) {
	if (!ad || !ad.length) { return; }
	var paid = numeral(ad.find('.tx_tendered').val()).value();
	var total = 0;
	ad.find('.purchase_details .total').each(function() { total += numeral($(this).val()).value(); });
	var change = paid - total;
	var out = ad.find('.tx_change');
	if (!paid || !total) { out.text('').removeClass('tx_short'); return; }
	out.text(numeral(change).format('0.00')).toggleClass('tx_short', change < 0);
}

$(document).on('input change', '.tx_tendered', function() {
	var ad = $(this).closest('.app_details');
	txTenderChange(ad);
	transactionStorageSaver(ad.attr('app'));
});

$(document).on('change', '.app_details .account', function() {
	txTenderPaint($(this).closest('.app_details'));
});

$(document).on('change', '.app_details .movement', function() {
	txTenderPaint($(this).closest('.app_details'));
});

$(function() {
	$('.app_details').each(function() {
		var ad = $(this);
		txTenderPaint(ad);
		var movement = ad.find('.movement').val();
		if (movement == 'transfer' || movement == 'inventory') {
			ad.closest('.appointment').find('.tx_add_row, .tx_summary').hide();
		}
	});
});

function transactionStorageRetriever(app) {
	var appt = $('.appointment[app="' + app + '"]');
	var movement = appt.find('.movement.app_setting[attribute="movement"]').val();
	var storage;
	try { storage = JSON.parse(localStorage.getItem('transactionSaver_' + app)) || {}; }
	catch (e) { storage = {}; }
	if (storage[movement]) {
		// the stored items, in the order they were written
		var items = [];
		$.each(storage[movement], function(i,v) {
			if (i != 'totals') { items.push({ uuid: i, fields: v }); }
		});
		// one block per stored item, in place: a block already carrying the
		// item's uuid is filled where it stands, a spare block is re-purposed,
		// and only a genuinely missing block is added. A second tap on the
		// history button replaces what it brought instead of stacking another
		// copy of it.
		var container = appt.find('.transaction_movement_container[app="' + app + '"]');
		var available = [];
		container.find('.purchase_details').each(function(n,v) { available.push($(v)); });
		$.each(items, function(i,item) {
			var block;
			for (var n = 0; n < available.length; n++) {
				if (available[n].attr('uuid') == item.uuid) { block = available.splice(n,1)[0]; break; }
			}
			if (!block && available.length > 0) {
				block = available.shift();
			}
			if (!block) {
				appt.find('.add_transaction_item').trigger('click');
				block = container.find('.purchase_details').last();
			}
			block.attr('uuid', item.uuid);
			block.find('.remove_transaction_item').attr('uuid', item.uuid);
			block.find('.purchase_input').each(function(n,v) {
				if (!$(v).is('select') && $(v).attr('type') != 'checkbox') {
					$(v).val($(v).attr('attribute') == 'quantity' ? 1 : '');
				}
			});
			$.each(item.fields, function(ir,vr) {
				if (vr == 'undefined' || vr == 'null') { return true; }
				var input = block.find('[attribute="' + ir + '"]');
				if (input.attr('type') == 'checkbox') {
					input.val(vr).prop('checked', vr == 'on');
				}
				else {
					input.val(vr);
				}
			});
		});
		// whatever block is left unclaimed belongs to no stored item
		$.each(available, function(i,v) { v.remove(); });
		if (items.length > 0) {
			// the form answers to its first block's name, and the add button
			// clones that block
			appt.find('.app_details').attr('uuid', items[0].uuid);
		}
		var totals = storage[movement]['totals'] || {};
		if (totals['uuid']) {
			appt.find('.vendor.purchase_input').val(totals['vendor']);
		}
		if (totals['tendered']) { appt.find('.tx_tendered').val(totals['tendered']); }
		txTenderPaint(appt.find('.app_details'));
	}
	// the vendor's change brings the open invoices for that vendor back into
	// the picker; when the stored transaction had one chosen, choose it again
	// (the picker's own change would overwrite the retrieved amounts with the
	// invoice's current numbers, so only the pick is restored)
	var information = storage[movement] ? (storage[movement]['totals'] || {})['information'] : undefined;
	appt.find('.purchase_input[attribute="vendor"]').trigger('change');
	if (information && information != 'undefined' && information != 'none' && information != 'null') {
		setTimeout(function() {
			var select = appt.find('.transaction_information');
			if (select.find('option[value="' + information + '"]').length > 0) {
				select.val(information).show();
			}
		}, 400);
	}

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
	appt.find('.tx_tendered').val('');
	appt.find('.tx_change').text('').removeClass('tx_short');
	// Only the transaction form's own pickers are reset here. The appointment
	// details list carries model/option selectors of its own; clearing those made
	// the model dropdown vanish until the next refresh (the GPS fix), which is the
	// "wait for the GPS to get the dropdown back" the user saw.
	appt.find('.purchase_details').find('.appointment_model_selector_container').each(function(i,v) { $(v).html('').hide(); });
	appt.find('.purchase_details').find('.appointment_option_selector_container').each(function(i,v) { $(v).html('').hide(); });
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
	pdhtml.addClass('tx_added_line');
	pdhtml.find('.purchase_input').each(function(i,v) {
		if (!$(v).is('select')) {
			$(v).val('');
		}
	});
	var remove_label = (typeof jawnosT === 'function') ? jawnosT('Remove') : 'Remove';
	pdhtml.append('<button type="button" class="remove_transaction_item tx_remove" uuid="' + uuid + '" app="' + app + '">' + remove_label + '</button>');
	$(this).closest('.app_details').find('.transaction_movement_container').append(pdhtml);
	pdhtml.find('.item').focus();

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
			// an app with no earlier transaction has nothing to bring back
			if (response.data) {
				localStorage.setItem('transactionSaver_' + app, response.data);
			}
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

// A packaging named while filling a transaction: create the unit, select it here,
// and record it on the item so a restock plan knows the pack size.
$(document).on('click', '.add_packaging_measure', function(e) {
	e.preventDefault();
	var btn = $(this);
	var pd = btn.closest('.purchase_details');
	var select = btn.closest('.appointment_model_selector_container').find('select[attribute="unit"]');
	if (!select.length) { return; }
	$('#app_packaging_prompt').remove();
	var box = $('<div id="app_packaging_prompt" style="position:fixed;z-index:100000;left:50%;top:35%;transform:translate(-50%,-50%);background:var(--panel);border:2px solid var(--line);border-radius:8px;padding:14px;font-size:17px;min-width:280px;box-shadow:0 8px 30px rgba(0,0,0,.35);">'
		+ '<div style="font-weight:700;margin-bottom:8px;">New packaging</div>'
		+ '<input id="app_packaging_name" type="text" placeholder="loaf, bag of 6..." style="width:100%;font-size:17px;padding:4px;">'
		+ '<div style="margin-top:8px;">holds <input id="app_packaging_each" type="text" value="1" style="width:60px;font-size:17px;"> each</div>'
		+ '<div style="margin-top:10px;"><button id="app_packaging_ok">Add</button> <button id="app_packaging_cancel">Cancel</button></div>'
		+ '</div>');
	box.data('select', select).data('pd', pd);
	$('body').append(box);
	$('#app_packaging_name').focus();
});

$(document).on('click', '#app_packaging_cancel', function() {
	$('#app_packaging_prompt').remove();
});

$(document).on('keydown', '#app_packaging_name, #app_packaging_each', function(e) {
	if (e.key === 'Enter') { e.preventDefault(); $('#app_packaging_ok').trigger('click'); }
});

$(document).on('click', '#app_packaging_ok', function() {
	var box = $('#app_packaging_prompt');
	var name = $('#app_packaging_name').val() || '';
	if (name.replace(/\s/g, '') === '') { $('#app_packaging_name').focus(); return; }
	var each = $('#app_packaging_each').val() || '1';
	var select = box.data('select');
	var pd = box.data('pd');
	var app = pd.closest('.appointment').attr('app');
	var item = pd.find('input[attribute="item"]').val() || '';
	$.post('/manager/market/packaging_add', { name: name, each: each, item: item, timestamp: Date.now() }, function(response) {
		box.remove();
		if (!response || !response.unit) { return; }
		if (!select.find('option[value="' + response.unit + '"]').length) {
			select.append($('<option></option>').attr('value', response.unit).text(response.name));
		}
		select.val(response.unit).trigger('change');
		if (typeof transactionStorageSaver === 'function') { transactionStorageSaver(app); }
	}, 'json');
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
	var appointment = $(this).closest('.appointment');
	appointment.find('.tx_add_row, .tx_summary').toggle(!(movement == 'transfer' || movement == 'inventory'));
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
	var appointment = iq.closest('.appointment');
	var app = iq.attr('app');
	var ago = appointment.find('.ago').val();
	var warranty = appointment.find('.warranty').val();
	var schedule = appointment.find('.schedule').val();
	var duration = appointment.find('.duration').val() || '';
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
	var record_vendor = iq.find('.record_vendor').prop('checked') ? 'on' : 'off';
	var tax = iq.find('.tax').val();
	var has_tax = iq.find('.purchase_config[config="tax"]').attr('enabled');
	var has_totes = iq.find('.purchase_config[config="totes"]').attr('enabled');
	var aux = iq.find('.aux').val();
	var aux_description = iq.find('.aux_description').val();
	var item = iq.find('.item').val();
	var model = iq.find('.model').val();
	var total = iq.find('.total').val();

	var sum_total = numeral(iq.find('.transaction_total[attribute="total"]').text()).value();
	if ($.trim(total || '') === '' && $.trim(amount || '') === '' && sum_total === 0) {
		alert((typeof jawnosT === 'function') ? jawnosT('Enter the amount or the total before saving.') : 'Enter the amount or the total before saving.');
		return;
	}

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
		aux_description: aux_description,
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
				if (response && response.error) { alert(response.error); return; }
				centreViewWriter(response['cv']);
				continent_record({'uuid':response['uuid'], 'app':response['app'],'purpose':'app','timestamp':response['timestamp'],'navigation':navigation});
				appointment_chron();
				appClearer(app);
				transactionStorageDeleter(app);
			}
		});
	}
});


// ---- crypto wallet amounts -------------------------------------------------
// A wallet account is read in its own coin. The server owns the conversion; this
// only shows what the typed native amount is worth before the transaction is
// saved, using the same cached rate snapshot the server writes with.
var jawnosCryptoRates = null;
var jawnosCryptoBase = '';

function jawnosCryptoLoadRates(done) {
	if (jawnosCryptoRates) { if (done) { done(); } return; }
	$.getJSON('/manager/crypto/rates', function(r) {
		jawnosCryptoRates = (r && r.rates) || {};
		jawnosCryptoBase = (r && r.base) || '';
		if (done) { done(); }
	}).fail(function() {
		jawnosCryptoRates = {};
		if (done) { done(); }
	});
}

function jawnosCryptoPaint(scope) {
	if (!scope || !scope.length) { return; }
	var opt = scope.find('.account').find('option:selected');
	var asset = opt.attr('data-asset') || '';
	var hint = scope.find('.crypto_hint');
	if (!asset) {
		hint.hide().attr('data-asset', '');
		return;
	}
	hint.show().attr('data-asset', asset);
	hint.find('.crypto_asset_name').text(asset);
	jawnosCryptoLoadRates(function() {
		var rate = jawnosCryptoRates ? jawnosCryptoRates[asset] : null;
		var total = numeral(scope.find('.total').val()).value();
		var text = rate
			? numeral(total * rate).format('$0,0.00') + ' at ' + numeral(rate).format('$0,0.00')
			: 'rate not loaded';
		hint.find('.crypto_fiat').text(text);
	});
}

function jawnosCryptoPaintAll() {
	$('.app_details').each(function() {
		if ($(this).find('.crypto_hint:visible').length) { jawnosCryptoPaint($(this)); }
	});
}

$(document).on('change', '.app_details .account', function() {
	jawnosCryptoPaint($(this).closest('.app_details'));
});

$(document).on('input change', '.app_details .total, .app_details .amount', function() {
	var scope = $(this).closest('.app_details');
	if (scope.find('.crypto_hint').is(':visible')) { jawnosCryptoPaint(scope); }
});

// The appointment window is drawn after the click that opens it, so a short
// guarded pass keeps the native amount and its value in step without a loop on
// an idle screen.
$(function() {
	jawnosCryptoPaintAll();
	setInterval(function() {
		if (document.hidden) { return; }
		if ($('.app_details .crypto_hint:visible').length) { jawnosCryptoPaintAll(); }
	}, 4000);
});
