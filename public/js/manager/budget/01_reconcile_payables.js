$(document).on('click', '.budget_light', function() {
	var bl = $(this);
	var circumstance = bl.attr('circumstance');
	var app = bl.attr('app');
	budgetLight(app,circumstance);

});

// The app's ci setting says whether its budget light was left open, and the
// server renders it on the panel. Reopening a closed window brings the light
// back just as it was left; closing it cleared ci, so a closed light stays shut.
function budgetLightRestore(app) {
	var blci = $('.budget_current_information[app="' + app + '"]');
	var circumstance = blci.attr('circumstance') || '';
	if (circumstance) { budgetLight(app, circumstance, 'open'); }
}

function budgetLightStopTimer(app) {
	if (budgetLightIntervals[app]) {
		clearInterval(budgetLightIntervals[app]);
		delete budgetLightIntervals[app];
	}
}

// The panel says whether it is live, so the browser side does not have to read
// the header (which can lag a write).
function budgetLightRunning(blci) {
	var panel = blci.find('[data-budget-running]');
	return panel.length ? panel.attr('data-budget-running') == '1' : false;
}

// An open duration light is a live meter. While the app has a session running,
// re-read the panel so the time it shows grows with the session instead of
// standing at the value from when it was opened (the watcher only passes every
// twenty minutes, and a start or a stop is otherwise the only redraw).
function budgetLightRefresh(app, circumstance, blci) {
	if (!blci.is(':visible') || blci.attr('circumstance') != circumstance) {
		budgetLightStopTimer(app);
		return;
	}
	if (!budgetLightRunning(blci)) {
		budgetLightStopTimer(app);
		return;
	}
	if (blci.data('budget_light_refreshing')) { return; }
	blci.data('budget_light_refreshing', true);
	$.ajax({
		url: '/manager/budget/current_information',
		type: 'GET',
		data: { timestamp: Date.now(), app: app, circumstance: circumstance },
		success: function(response) {
			if (blci.is(':visible') && blci.attr('circumstance') == circumstance) {
				blci.html(response);
				appointment_chron();
				if (!budgetLightRunning(blci)) { budgetLightStopTimer(app); }
			}
		},
		complete: function() {
			blci.data('budget_light_refreshing', false);
		}
	});
}

function budgetLight(app,circumstance,status) {
	var blci = $('.budget_current_information[app="' + app + '"]');
	var wind = blci.closest('.wind');
	var header;
	if ((blci.is(':visible') && status != 'open') && blci.attr('circumstance') == circumstance) {
		budgetLightStopTimer(app);
		blci.hide();
		blci.attr('status', 'closed');
		circumstance = undefined;
		blci.attr('circumstance', undefined);
		header = blci.html();

//		cacheSet({ 'app': app, 'context': 'header' }, { 'timestamp': timestamp, 'header': header });
	}
	else {
		budgetLightStopTimer(app);
		$.ajax({
			url: '/manager/budget/current_information',
			type: 'GET',
			data: { timestamp: timestamp, app: app, circumstance: circumstance },
			success: function(response) {
				blci.html(response).show();
				blci.attr('circumstance', circumstance);
				blci.attr('status', 'open');
				appointment_chron();
				header = blci.html();
//				cacheSet({ 'app': app, 'context': 'header' }, { 'timestamp': timestamp, 'header': header });
				// only a duration budget grows on its own; the others read counts or
				// money that a running session does not change
				budgetLightStopTimer(app);
				if (circumstance == 'duration' && budgetLightRunning(blci)) {
					budgetLightIntervals[app] = setInterval(function() {
						budgetLightRefresh(app, circumstance, blci);
					}, budgetLightIntervalMs);
				}
			}
		});
	}

	settingSetter({ 'app': app, 'setting': 'ci', 'value': circumstance });

	wind.attr('current_information', circumstance);
}

$(document).on('click', '#budget_display_save', function() {
	var name = $('#budget_display_name').val();
	var type = $('#budget_display_name').attr('display_type');
	if (!name) {
		
//		return;
	}

	var data = [ 'start_time', 'end_time' ];
	$('.budget_config').each(function(i,v) {
		data.push($(v).attr('config'));
	});
	data = JSON.stringify(data);
	$.ajax({
		url: '/manager/budget/display/save',
		type: 'POST',
		data: { name: name, timestamp: timestamp, data: data, type: type },
		success: function(response) {
		}
	});
});

$(document).on('click', '#budget_display_delete', function() {
	var name = $('#budget_display_name').val();
	var display = $('#budget_display_name').attr('display_type');
	$.ajax({
		url: '/manager/budget/display/delete',
		type: 'POST',
		data: { name: name, display: display },
		success: function(response) {
		}
	
	});

});

// --- Bank statement import and reconciliation ------------------------------
$(document).on('click', '#budget_reconcile_import', function() {
	var button = $(this);
	var account = $('#budget_reconcile_account').val();
	var file = $('#budget_reconcile_file')[0].files[0];
	var message = $('#budget_reconcile_message');
	message.text('');
	if (!account) { message.text(jawnosT('Choose an account first.')); return; }
	if (!file) { message.text(jawnosT('Choose a file to import.')); return; }
	var fd = new FormData();
	fd.append('account', account);
	fd.append('date_order', $('#budget_reconcile_date_order').val());
	fd.append('file', file);
	button.attr('disabled', 'disabled');
	$.ajax({
		url: '/manager/budget/import',
		type: 'POST',
		data: fd,
		processData: false,
		contentType: false,
		success: function(response) {
			button.removeAttr('disabled');
			if (response.error) { message.text(response.error); return; }
			$('#budget_reconcile_area').html(response.html);
			appointment_chron();
		},
		error: function() {
			button.removeAttr('disabled');
			message.text(jawnosT('The file could not be imported.'));
		}
	});
});

// the delta follows the balance the person types, so the statement figure they
// read off the page is what the screen measures against
$(document).on('input change', '#budget_reconcile_ending', function() {
	var delta = $('#budget_reconcile_delta');
	var value = $(this).val().replace(/[^0-9.\-]/g, '');
	var ledger = parseFloat(delta.attr('data-ledger')) || 0;
	if (value === '' || isNaN(parseFloat(value))) { delta.text(''); return; }
	delta.text(numeral(parseFloat(value) - ledger).format('$0.00'));
});

$(document).on('click', '#budget_reconcile_apply', function() {
	var button = $(this);
	var account = button.attr('account');
	var statement_end = button.attr('statement_end');
	var ending = $('#budget_reconcile_ending').val();
	var lines = [];
	$('.budget_reconcile_line').each(function() {
		var row = $(this);
		var take = row.find('.budget_reconcile_take').length ? row.find('.budget_reconcile_take').is(':checked') : true;
		var action = row.attr('matched') === 'yes' ? 'match' : (row.find('.budget_reconcile_action').val() || 'record');
		if (row.attr('covered') === 'yes') { action = 'ignore'; }
		if (!take) { action = 'ignore'; }
		var record_amount = row.attr('record_amount');
		if (typeof record_amount === 'undefined' || record_amount === '') { record_amount = row.attr('amount'); }
		lines.push({
			timestamp: row.attr('timestamp'),
			amount: row.attr('amount'),
			record_amount: record_amount,
			description: row.attr('description'),
			action: action,
			app: row.find('.budget_reconcile_app').val() || '',
			movement: row.find('.budget_reconcile_movement').val() || '',
			vendor: row.attr('vendor') || '',
			item: row.attr('item') || '',
			match_uuid: row.attr('match_uuid') || ''
		});
	});
	button.attr('disabled', 'disabled');
	$.ajax({
		url: '/manager/budget/reconcile',
		type: 'POST',
		data: { account: account, statement_end: statement_end, ending_balance: ending, lines: JSON.stringify(lines) },
		success: function(response) {
			button.removeAttr('disabled');
			var message = jawnosT('Reconciled.') + ' ' + jawnosT('Balance') + ': ' + numeral(response.balance).format('$0.00');
			if ($('#alert').length) { jawnosAlert(message); }
			else { $('#budget_reconcile_message').text(message); }
			budgetInit();
		},
		error: function() {
			button.removeAttr('disabled');
			$('#budget_reconcile_message').text(jawnosT('The reconciliation could not be saved.'));
		}
	});
});

// --- Payables ---------------------------------------------------------------
$(document).on('click', '#budget_payable_add', function() {
	var button = $(this);
	var message = $('#budget_payable_message');
	message.text('');
	var data = {
		vendor: $('#budget_payable_vendor').val() || '',
		app: $('#budget_payable_app').val() || '',
		item: $('#budget_payable_item').val() || '',
		total: $('#budget_payable_total').val() || '',
		tax: $('#budget_payable_tax').val() || '',
		date: $('#budget_payable_date').val() || '',
		repeat: ($('#budget_payable_schedule').val() || '').trim() || $('#budget_payable_repeat').val() || 'once'
	};
	if (!data.total) { message.text(jawnosT('A bill needs an amount.')); return; }
	button.attr('disabled', 'disabled');
	$.ajax({
		url: '/manager/budget/payable/add',
		type: 'POST',
		data: data,
		success: function(response) {
			button.removeAttr('disabled');
			if (response.error) { message.text(response.error); return; }
			$('#budget_payable_schedule').val('');
			if (response.ask) {
				message.text(jawnosT('The bill is saved; the Guide needs one thing about the repeat.'));
				if (typeof assistantAskFresh === 'function') { assistantAskFresh('budget', response.ask); }
			}
			budgetInit();
		},
		error: function() {
			button.removeAttr('disabled');
			message.text(jawnosT('The bill could not be saved.'));
		}
	});
});

$(document).on('click', '.budget_payable_pay', function() {
	var button = $(this);
	var row = button.closest('.budget_payable_row');
	var message = $('#budget_payable_message');
	message.text('');
	button.attr('disabled', 'disabled');
	$.ajax({
		url: '/manager/budget/payable/pay',
		type: 'POST',
		data: {
			uuid: button.attr('uuid'),
			account: row.find('.budget_payable_account').val() || '',
			amount: row.find('.budget_payable_amount').val() || ''
		},
		success: function(response) {
			button.removeAttr('disabled');
			if (response.error) { message.text(response.error); return; }
			budgetInit();
		},
		error: function() {
			button.removeAttr('disabled');
			message.text(jawnosT('The payment could not be saved.'));
		}
	});
});

$(document).on('click', '.budget_payable_delete', function() {
	var button = $(this);
	var message = $('#budget_payable_message');
	message.text('');
	if (!confirm(jawnosT('Delete this bill and any payments against it?'))) { return; }
	button.attr('disabled', 'disabled');
	$.ajax({
		url: '/manager/budget/payable/delete',
		type: 'POST',
		data: { uuid: button.attr('uuid') },
		success: function(response) {
			button.removeAttr('disabled');
			if (response.error) { message.text(response.error); return; }
			budgetInit();
		},
		error: function() {
		button.removeAttr('disabled');
		message.text(jawnosT('The bill could not be deleted.'));
	}
});
});


$(document).on('click', '.budget_schedule_toggle, .budget_schedule_delete', function() {
var button = $(this);
var url = button.hasClass('budget_schedule_toggle')
	? '/manager/budget/payable/schedule/toggle'
	: '/manager/budget/payable/schedule/delete';
if (button.hasClass('budget_schedule_delete') && !confirm(jawnosT('Delete this scheduled bill? Bills it already made are kept.'))) { return; }
button.attr('disabled', 'disabled');
$.ajax({
	url: url,
	type: 'POST',
	data: { uuid: button.attr('uuid') },
	success: function(response) {
		button.removeAttr('disabled');
		if (response.error) { alert(response.error); return; }
		budgetInit();
	},
	error: function() {
		button.removeAttr('disabled');
		alert(jawnosT('The schedule could not be saved.'));
	}
});
});

$(document).on('click', '#budget_journal_rebuild', function() {
	var button = $(this);
	button.attr('disabled', 'disabled');
	$.ajax({
		url: '/manager/budget/journal/rebuild',
		type: 'POST',
		success: function(response) {
			button.removeAttr('disabled');
			var message = jawnosT('Journal rebuilt:') + ' ' + (response.entries || 0) + ' ' + jawnosT('entries') + ', ' + (response.lines || 0) + ' ' + jawnosT('lines') + '.';
			if ($('#alert').length) { jawnosAlert(message); }
			else { $('#budget_journal_message').text(message); }
			budgetInit();
		},
		error: function() {
			button.removeAttr('disabled');
			$('#budget_journal_message').text(jawnosT('The journal could not be rebuilt.'));
		}
	});
});









