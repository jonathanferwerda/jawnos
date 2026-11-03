/* [[js-split]]
   transaction.js is part 1. The rest live in transaction/ in name order:
     01_record_crypto.js - cancel add remove items - history - packaging - record purchase - crypto wallet rates
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */

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
	var ad = $(this).closest('.app_details');
	txTenderPaint(ad);
	txTransferPaint(ad);
});

// The same account picker is the source of an expense and of a transfer, so its
// label follows the movement: "Paid from" for a payment, "From" for a move.
function txAccountLabel(ad, movement) {
	var text = (movement == 'transfer') ? 'From' : 'Paid from';
	ad.find('.tx_account_label').text((typeof jawnosT === 'function') ? jawnosT(text) : text);
}

// A transfer reads From -> To: the name beside From follows the paid-from
// picker, and the destination starts on a different account so the default is a
// real move rather than an account paying itself.
function txTransferPaint(ad) {
	if (!ad || !ad.length) { return; }
	var to = ad.find('.to_account');
	if (!to.length) { return; }
	var picked = ad.find('.account option:selected');
	var name = picked.attr('label') || picked.text() || '';
	ad.find('.tx_transfer_from_name').text(name);
	var from = ad.find('.account').val();
	if (to.val() === from) {
		var other = to.find('option').filter(function() { return $(this).val() !== from; }).first();
		if (other.length) { to.val(other.val()); }
	}
}

$(document).on('change', '.app_details .movement', function() {
	txTenderPaint($(this).closest('.app_details'));
});

$(function() {
	$('.app_details').each(function() {
		var ad = $(this);
		txTenderPaint(ad);
		txTransferPaint(ad);
		var movement = ad.find('.movement').val();
		txAccountLabel(ad, movement);
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

