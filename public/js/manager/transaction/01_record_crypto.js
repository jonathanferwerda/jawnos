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
	// The same picker is the source of an expense and of a transfer; name it
	// for the movement so a transfer reads From -> To.
	var ad = $(this).closest('.app_details');
	txAccountLabel(ad, movement);
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
	var transfer_amount = iq.find('.transfer_amount').val();
	var transfer_aux = iq.find('.transfer_aux').val();
	var to_account = iq.find('.to_account').val();

	// A transfer carries its figure in transfer_amount, not in the line amount
	// and total an expense uses, so the old check rejected every transfer with
	// the amount-or-total message. Each movement is now asked for what it has.
	var t = function(text) { return (typeof jawnosT === 'function') ? jawnosT(text) : text; };
	if (movement == 'transfer') {
		if (!(numeral(transfer_amount).value() > 0)) {
			alert(t('Enter the amount to transfer.'));
			iq.find('.transfer_amount').focus();
			return;
		}
		if (!to_account || to_account === account) {
			alert(t('Choose a different account to receive the transfer.'));
			iq.find('.to_account').focus();
			return;
		}
	}
	else {
		var sum_total = numeral(iq.find('.transaction_total[attribute="total"]').text()).value();
		if ($.trim(total || '') === '' && $.trim(amount || '') === '' && sum_total === 0) {
			alert(t('Enter the amount or the total before saving.'));
			return;
		}
	}

	var unit = iq.find('.unit').val() || 1;

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
