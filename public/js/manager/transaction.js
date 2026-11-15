/* [[js-split]]
   transaction.js is part 1. The rest live in transaction/ in name order:
     01_record_crypto.js - cancel add remove items - history - packaging - record purchase - crypto wallet rates
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */

var originalTransactionAutofills = {};

// An expense is money out, so it is written with a negative sign; a refund is
// the exception. A positive figure typed into an expense line is read as an
// outlay and turned negative before the form does its arithmetic on it. The
// Refund button marks a line, and a line brought back from history carries the
// mark its stored sign implies, so a refund keeps its positive figure.
$(document).on('change', '.purchase_details .amount, .purchase_details .tax, .purchase_details .aux, .purchase_details .total', function() {
	var input = $(this);
	var line = input.closest('.purchase_details');
	var ad = line.closest('.app_details');
	if (ad.find('.movement').val() != 'expense') { return; }
	if (line.attr('refund') == 'on') { return; }
	if ($.trim(input.val() || '') === '') { return; }
	var value = numeral(input.val()).value();
	if (value > 0) { input.val(numeral(-value).format('0.00')); }
});

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
	// The tax selection and the exemption ID are the line's own snapshot, not an
	// app setting: this handler writes settings and autofills names, neither of
	// which applies here. The arithmetic handler below still sees the change.
	if (attribute == 'taxes' || attribute == 'tax_exemption') { return; }
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

// The rate a line charges: the selected catalog entries added together, or the
// old single multiplier when the line has selected none (an old draft, or a
// house that never wrote a catalog). jawnos_tax_catalog is the layout's list.
function transactionTaxRate(line) {
	var catalog = (typeof jawnos_tax_catalog !== 'undefined' && jawnos_tax_catalog) ? jawnos_tax_catalog : [];
	var selected = line.find('.purchase_input[attribute="taxes"]').val();
	if (!$.isArray(selected)) { selected = (selected === null || selected === undefined || selected === '') ? [] : [selected]; }
	var percent = 0;
	var found = 0;
	$.each(selected, function(i, code) {
		$.each(catalog, function(ci, entry) {
			if (entry && String(entry.code) === String(code)) {
				percent += numeral(entry.rate).value();
				found++;
			}
		});
	});
	if (!found) { return (typeof me_tax !== 'undefined' && me_tax) ? numeral(me_tax).value() : 1; }
	return 1 + (percent / 100);
}

// The Amount field is gross when "Price includes tax" is on and net when it is
// off, so the button's label decides the arithmetic. On a gross amount the tax
// is the portion inside it; on a net amount it is added.
function transactionTaxApply(amount, rate, inclusive, aux) {
	if (!(rate > 0)) { rate = 1; }
	if (inclusive) {
		var gross_tax = amount - (amount / rate);
		return { tax: gross_tax, total: amount + aux };
	}
	var net_tax = amount * (rate - 1);
	return { tax: net_tax, total: amount + net_tax + aux };
}

// Recompute a line from its Amount field and its own rate, used when the rate
// changes without an amount edit. The Amount is left as the person typed it.
function transactionTaxRecalculate(line, rate) {
	if (rate === undefined) { rate = transactionTaxRate(line); }
	var inclusive = (line.find('.purchase_config[config="tax"]').attr('enabled') == 'on');
	var amount = numeral(line.find('.purchase_input[attribute="amount"]').val()).value();
	var aux = numeral(line.find('.purchase_input[attribute="aux"]').val()).value();
	var figures = transactionTaxApply(amount, rate, inclusive, aux);
	line.find('.purchase_input[attribute="tax"]').val(numeral(figures.tax).format('0.00'));
	line.find('.purchase_input[attribute="total"]').val(numeral(figures.total).format('0.00'));
}

// The exemption belongs to the vendor, so the ID field is shown only while that
// vendor is exempt.
function taxExemptionPaint(line, exempt, id) {
	var field = line.find('.tx_tax_exempt');
	if (!field.length) { return; }
	field.attr('tax_exempt', exempt ? 'on' : 'off');
	var input = line.find('.purchase_input[attribute="tax_exemption"]');
	if (exempt) { input.val(id || ''); field.show(); }
	else { input.val(''); field.hide(); }
}

// A vendor keeps its exemption on its own app. The four settings arrive one at
// a time from setting_grabber; the last one paints the line, and an exempt
// vendor takes the tax off it so the record matches the paper.
function taxExemptionFetch(line, vendor) {
	if (!line || !line.length) { return; }
	if (!vendor) { taxExemptionPaint(line, false, ''); return; }
	var app = line.closest('.appointment').attr('app');
	var found = { tax_exempt: '', tax_exemption_id: '', tax_codes: '', tax_country: '' };
	var waiting = 4;
	var finish = function() {
		waiting--;
		if (waiting > 0) { return; }
		var exempt = (found.tax_exempt == 'on' || found.tax_exempt == '1' || found.tax_exempt === true);
		taxExemptionPaint(line, exempt, found.tax_exemption_id || '');
		if (exempt) {
			line.find('.purchase_input[attribute="taxes"]').val([]);
			// an exempt vendor charges nothing, even though an empty selection
			// would otherwise fall back to the old single multiplier
			transactionTaxRecalculate(line, 1);
		}
		if (app) { transactionStorageSaver(app); }
	};
	$.each(['tax_exempt', 'tax_exemption_id', 'tax_codes', 'tax_country'], function(i, setting) {
		$.ajax({
			url: '/manager/setting_grabber',
			type: 'GET',
			data: { app: vendor, setting: setting },
			success: function(response) { found[setting] = response; },
			error: function() { found[setting] = ''; },
			complete: finish
		});
	});
}

$(document).on('change', '.purchase_details .vendor', function() {
	taxExemptionFetch($(this).closest('.purchase_details'), $(this).val());
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
	var inclusive = (iq.find('.purchase_config[config="tax"]').attr('enabled') == 'on');
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
	var rate = transactionTaxRate(iq);
	if (!(rate > 0)) { rate = 1; }
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
	var figures;
	if (e.hasClass('total')) {
		total = total * multiplier;
		total_in.val(numeral(total).format('0.00'));
		var taxable = total - aux;
		tax = taxable - (taxable / rate);
		amount = inclusive ? taxable : (taxable / rate);
		amount_in.val(numeral(amount).format('0.00'));
		tax_in.val(numeral(tax).format('0.00'));
	}
	else if (e.hasClass('aux')) {
		total_in.val(numeral(amount + aux + (inclusive ? 0 : tax)).format('0.00'));
	}
	else if (e.hasClass('tax')) {
		// the person's own figure wins and the total stays put, so the amount
		// follows it. A gross amount already contains its tax.
		amount = total - aux - (inclusive ? 0 : tax);
		amount_in.val(numeral(amount).format('0.00'));
	}
	else if (e.hasClass('taxes')) {
		figures = transactionTaxApply(amount, rate, inclusive, aux);
		tax_in.val(numeral(figures.tax).format('0.00'));
		total_in.val(numeral(figures.total).format('0.00'));
	}
	else if (e.hasClass('tax_exemption')) {
		// the exemption ID is recorded beside the line; it changes no amount
	}
	else if (e.hasClass('amount')) {
		amount = amount * multiplier;
		amount_in.val(numeral(amount).format('0.00'));
		figures = transactionTaxApply(amount, rate, inclusive, aux);
		tax_in.val(numeral(figures.tax).format('0.00'));
		total_in.val(numeral(figures.total).format('0.00'));
	}
	else if (e.hasClass('quantity')) {
		amount = amount * multiplier;
		amount_in.val(numeral(amount).format('0.00'));
		figures = transactionTaxApply(amount, rate, inclusive, aux);
		tax_in.val(numeral(figures.tax).format('0.00'));
		total_in.val(numeral(figures.total).format('0.00'));
	}
	else {
		amount = amount * multiplier;
		amount_in.val(numeral(amount).format('0.00'));
		figures = transactionTaxApply(amount, rate, inclusive, aux);
		tax_in.val(numeral(figures.tax).format('0.00'));
		total_in.val(numeral(figures.total).format('0.00'));
	}
	txTenderChange(iq.closest('.app_details'));
	transactionStorageSaver(app);

});

$(document).on('keyup click', '.purchase_input', function() {
	var me = $(this);
	var value = me.val();
	var attribute = me.attr('attribute');
	// the tax selection and its exemption ID are not names to autocomplete
	if (attribute == 'taxes' || attribute == 'tax_exemption') { return; }
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
		// the receipt's own moment travels with the draft, so switching movement or
		// reopening the window keeps the day it was bought on
		storage[movement]['totals']['receipt_timestamp'] = appt.find('.app_details').attr('receipt_timestamp') || '';
		storage[movement]['totals']['receipt_uuid'] = appt.find('.app_details').attr('receipt_uuid') || '';
		storage[movement]['totals']['receipt_when'] = appt.find('.app_details').attr('receipt_when') || '';
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
	// the save route records one exemption for the transaction: the ID beside an
	// exempt vendor, taken from the line that shows it
	var exemption = '';
	$('.purchase_details[app="' + app + '"]').each(function(i, v) {
		var pd = $(v);
		if (pd.find('.tx_tax_exempt').attr('tax_exempt') != 'on') { return; }
		var value = pd.find('.purchase_input[attribute="tax_exemption"]').val() || '';
		if (value.length) { exemption = value; }
	});
	storage[movement]['totals']['tax_exemption'] = exemption;
	var cash_rounding = numeral(appt.find('.tx_rounding').attr('data-rounding')).value() || 0;
	var cash_total = numeral(appt.find('.tx_rounding').attr('data-cash-total')).value() || 0;
	storage[movement]['totals']['rounding'] = cash_rounding;
	if (cash_total) { storage[movement]['totals']['cash_total'] = cash_total; }
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

// A cash sale in the home currency is rounded to the house's cash step (5¢ in
// Canada). The ledger keeps the exact line totals; the rounded total is what
// the person hands over and gets change from, and it is kept with the draft so
// the paper can show it. Another currency is never rounded.
function txCashRounding(ad, total) {
	var cr = (typeof jawnos_cash_rounding !== 'undefined' && jawnos_cash_rounding) ? jawnos_cash_rounding : null;
	if (!cr || !cr.step) { return { step: 0, rounded: total, rounding: 0 }; }
	var currency = (ad.find('.currency').val() || '').toUpperCase();
	if (!currency || currency !== String(cr.home_currency || '').toUpperCase()) {
		return { step: 0, rounded: total, rounding: 0 };
	}
	var rounded = Math.round(total / cr.step) * cr.step;
	rounded = Math.round(rounded * 100) / 100;
	return { step: cr.step, rounded: rounded, rounding: Math.round((rounded - total) * 100) / 100 };
}

function txTenderChange(ad) {
	if (!ad || !ad.length) { return; }
	var paid = numeral(ad.find('.tx_tendered').val()).value();
	var total = 0;
	ad.find('.purchase_details .total').each(function() { total += numeral($(this).val()).value(); });
	var cash = ad.find('.tx_tender_on').length > 0;
	var round = cash ? txCashRounding(ad, total) : { step: 0, rounded: total, rounding: 0 };
	var change = paid - round.rounded;
	var out = ad.find('.tx_change');
	var note = ad.find('.tx_rounding');
	if (note.length) {
		note.text(round.step ? ('Cash total ' + numeral(round.rounded).format('0.00') + ' · rounding ' + numeral(round.rounding).format('0.00')) : '')
			.attr('data-rounding', round.rounding)
			.attr('data-cash-total', round.rounded);
	}
	if (!paid || !total) { out.text('').removeClass('tx_short'); return; }
	out.text(numeral(change).format('0.00')).toggleClass('tx_short', change < 0);
}

// A receipt carries the day and time it was printed. Checkout stamps them on the
// form, and the draft keeps them across a movement switch, so the saved record
// is backdated instead of landing on the moment it was entered.
function txReceiptPaint(ad) {
	if (!ad || !ad.length) { return; }
	var when = ad.attr('receipt_when') || '';
	var label = (typeof jawnosT === 'function') ? jawnosT('Receipt') : 'Receipt';
	ad.find('.tx_receipt_when').text(when ? label + ': ' + when : '').toggle(!!when);
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

$(document).on('change', '.app_details .currency', function() {
	var ad = $(this).closest('.app_details');
	txTenderPaint(ad);
	txTenderChange(ad);
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
			// the stored sign says what the line is: a positive expense total is a
			// refund, so mark it before anything can turn it negative again
			block.attr('refund', numeral(block.find('.total').val()).value() > 0 ? 'on' : 'off');
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
		// the receipt's moment rides on the appointment, not on a line
		var details = appt.find('.app_details');
		if (totals['receipt_timestamp']) { details.attr('receipt_timestamp', totals['receipt_timestamp']); }
		else { details.removeAttr('receipt_timestamp'); }
		if (totals['receipt_when']) { details.attr('receipt_when', totals['receipt_when']); }
		else { details.removeAttr('receipt_when'); }
		if (totals['receipt_uuid']) { details.attr('receipt_uuid', totals['receipt_uuid']); }
		else { details.removeAttr('receipt_uuid'); }
		txReceiptPaint(details);
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
	// a cleared form is not a receipt any more
	appt.find('.app_details').removeAttr('receipt_timestamp').removeAttr('receipt_when').removeAttr('receipt_uuid');
	appt.find('.tx_receipt_when').text('').hide();
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

