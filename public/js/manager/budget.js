
var budgetConfigTimeout;
var timeStops = [];
$(document).on('click', '#budget, #budget_refresh', function() {
	budgetInit()
});

function budgetInit(data) {
	if (typeof data == 'undefined') { data = {}; }
	var new_settings = data['new_settings'] || {};
	var jnew_settings = JSON.stringify(new_settings);
	var adata = deloreanBringer();
	adata['new_settings'] = jnew_settings;
	var settingsVisibility = $('#budget_settings').is(':visible');
	$.ajax({
		url: '/manager/budget',
		type: 'GET',
		data: adata,
		success: function(response) {
			windowMaker(response.html);
			var jdata = JSON.stringify(response);
			$('#budget_json_data').text(jdata);
			if (settingsVisibility) {
				$('#budget_settings').show();
			}
			console.log(response);
			budgetAccountCanvasWriter(response);
		}
	});
}

function budgetAccountCanvasWriter(response) {
	if (response.accounts) {
		var id = 'budget_account_canvas';
		var g = document.getElementById(id);
		var ctx = g.getContext('2d');
		var highest = {};
		var lowest = {};
		var increments = numeral($('.budget_config[config="increments"]').val()).value();
		var allotment = (numeral(response.end).value() - numeral(response.start).value()) / numeral(increments).value();
		timeStops = [{}];
		for (var i = 0; i < increments; i++) {
			timeStops[i] = { uuid: crypto.randomUUID() };
			if (i > 0) {
				timeStops[i]['start'] = (timeStops[ i - 1 ]['end']);
			}
			else {
				timeStops[i]['start'] = numeral(response['start']).value();
			}
			timeStops[i]['end'] = (timeStops[i]['start'] + allotment);
		}

		$.each(timeStops, function(ii,tt) {
			$.each(response.accounts, function(i,v) {
				if (ii == 0 && response.accounts[i]['starting_balance']) {
					timeStops[ii]['total'] = response.accounts[i]['starting_balance'];
				}
				if (v.journals) {
					var lastva;	
					$.each(v.journals, function(ia,va) {
						if (va.timestamp >= tt.start && va.timestamp <= tt.end) {
							lastva = va;
						}
					});
					if (lastva) {
						timeStops[ii][i] = lastva['amount'];
					} else if (ii > 0) {
						timeStops[ii][i] = timeStops[ii - 1][i];
					}
					else {
						timeStops[ii][i] = response.accounts[i]['starting_balance'];
					}
					if (timeStops[ii][i]) {
						timeStops[ii]['total'] = (numeral(timeStops[ii]['total'] || 0).value() + numeral(timeStops[ii][i]).value());
						if (!highest[i] || timeStops[ii][i] > highest[i]) {
							highest[i] = timeStops[ii][i];
						}
						if (!lowest[i] || timeStops[ii][i] < lowest[i]) {
							lowest[i] = timeStops[ii][i];
						}
						if (!highest['total'] || timeStops[ii]['total'] > highest['total']) {
							highest['total'] = timeStops[ii]['total'];
						}
						if (!lowest['total'] || timeStops[ii]['total'] < lowest['total']) {
							lowest['total'] = timeStops[ii]['total'];
						}
					}
				}
			});
		});


		var wind = $('.wind[app="budget"]');
		g.width = wind.width();

		ctx.beginPath();
		ctx.fillStyle = 'black';
		ctx.strokeStyle = 'black';
		ctx.globalAlpha = 1;	
		ctx.font = "400 10px Arial";
		if (highest['total'] && lowest['total']) {
			$('#' + id).show();

			var max = highest['total'] * 1.1;
			if (lowest['total'] < 0) {
				max = highest['total'] + Math.abs(lowest['total']);
			}
			var min = g.height * .9;

			var colWidth = g.width / increments + 1;
			$.each(highest, function(i,v) {
				if (!response['accounts'][i]) { response['accounts'][i] = {}; }
				if (response['accounts'][i]['settings']) {
					ctx.strokeStyle = response['accounts'][i]['settings']['colour'] || 'black';
				} else {
					ctx.strokeStyle = 'black';
				}
				ctx.beginPath();
				ctx.moveTo(0,0);
				$.each(timeStops, function(ii,ts) {
					if (response.accounts[i]['graphable'] != 'no') {
						var point = numeral(ts[i]).value();
						if (lowest[i] < 0) {
							point = point + Math.abs(lowest['total']);
						}
						var x = g.width * (ii / increments);
						var y = min - (min * point / max);
						ctx.lineTo(x, y);
						ts['point'] = {};
						ts['point']['x'] = x;
						ts['point']['y'] = y;
						ts['point']['point'] = point;
						ctx.stroke();
					}
				});
			});

		}
	}
	console.log(timeStops);
}

$(document).on('click mousemove touchmove', '#budget_account_canvas, #budget_account_information', function(m) {
	var bai = $('#budget_account_information');
	if (m.type == 'click' && $('#budget_account_information').is(':visible')) {
		bai.hide();
	}
	if (m.target.id == 'budget_account_canvas') {
		var data = JSON.parse($('#budget_json_data').text());
		var x = m.originalEvent.clientX;
		var y = m.originalEvent.clientY;
		if (m.originalEvent.targetTouches) {
			x = m.originalEvent.targetTouches[0].clientX;
			y = m.originalEvent.targetTouches[0].clientY;
		}
		x = numeral(x - w.offset().left).value();
		y = numeral(y - w.offset().top).value();
		var hovering;
		$.each(timeStops, function(i,t) {
			if (x > t.point.x) {
				hovering = t;
			}
			if (x < t.point.x) {
				return;
			}
		});
		if (hovering['uuid'] != bai.attr('uuid')) {
			var html = '<span style="padding:1px;";><div class="time" timestamp="' + hovering.end + '"></div>';
			var minimum = 0;
			$.each(hovering, function(i,v) {
				if (data['accounts'][i]) {
					var colour;
					if (data['accounts'][i]['settings']) {
						colour = data['accounts'][i]['settings']['colour'];
						minimum = minimum + numeral(data['accounts'][i]['settings']['minimum']).value();
					}
					var nhtml = '<div><b style="color:' + colour + ';">' + format_name(i) + ':</b> ' + numeral(v).format('$0.00') + '</div>';
					html += nhtml;
				}
			});
			console.log( numeral(minimum).value());
			html += '<div><b>' + format_name('available') + ':</b> ' + numeral(numeral(hovering['total']).value() + numeral(minimum * -1).value()).format('$0.00') + '</div>';
			html += '<div><b><u>' + format_name('total') + ':</u></b> ' + numeral(hovering['total']).format('$0.00') + '</div></span>';

			bai.html(html).show();
			bai.css({ 'left': (x + 20), 'top': y, 'right': '' });
			if (numeral(bai.css('right')).value() < 0 || bai.width() < 130) {
				bai.css({ 'right': (($(window).width() - x) + 20), 'left': '' });
			}
			bai.attr('uuid', hovering['uuid']);
			appointment_chron();
		}
	}
});

$(document).on('mouseleave', '#budget_account_canvas', function(m) {
	if (m.relatedTarget.id != 'budget_account_information') {
	//	$('#budget_account_information').hide();
	}
});

$(document).on('click', '.budget_account', function() {
	var ba = $(this);
	var i = ba.attr('account');
	var data = JSON.parse($('#budget_json_data').text());
	if (!data.accounts[i]) {
		data.accounts[i] = {'graphable': 'yes' };
	}
	if (data.accounts[i]['graphable'] == 'no') {
		data.accounts[i]['graphable'] = 'yes';
		ba.css({ 'color': ba.attr('colour') });
	} else {
		data.accounts[i]['graphable'] = 'no';
		ba.css({ 'color': 'lightgrey' });
	}
	var jdata = JSON.stringify(data);
	$('#budget_json_data').text(jdata);
	budgetAccountCanvasWriter(data);
});

$(document).on('click', '#budget_settings_toggle', function() {
	var bs = $('#budget_settings');
	var visible = bs.is(':visible');
	if ( visible ) {
		bs.hide();
	}
	else {
		bs.show();
	}
});

$(document).on('change', '.budget_config', function() {
	clearTimeout(budgetConfigTimeout);
	var setting = $(this).val();
	var wait_time = 1000;
	var config = $(this).attr('config');
	if ($(this).attr('multiple') == "multiple") {
		setting = JSON.stringify(setting);
	}
	var delorean = deloreanBringer();
	delorean[config] = setting;
	var new_settings = {};
	$('#budget_display').val('');
	if ($(this).attr('id') != 'budget_display') {
		var display = $('#budget_display').attr('budget_display');
		display = display + '_display';
		new_settings[display] = '';
	}

	new_settings[config] = setting;
	if (config == 'scope') {
		new_settings['start_time'] = '';
		new_settings['end_time'] = '';
		wait_time += 200;
	}
	budgetInit({ 'new_settings': new_settings });

});

$(document).on('change', '.budget_time', function() {
	var setting = $(this).attr('setting');


	var value = $('.budget_time[setting="' + setting + '"]').val();
//	settingSetter({ 'app': 'budget', 'setting': setting, 'value': value });
	var new_settings = {};
	new_settings[setting] = value;	

	budgetInit({ 'new_settings': new_settings });


});


$(document).on('click', '.budget_row', function() {
	var row = $(this);
	var app = row.attr('app');
	var movement = row.attr('movement');
	var status = row.attr('status');
	var rows = $('.budget_detail_row[movement="' + movement + '"][app="' + app + '"]');
	if (status == 'closed') {
		rows.show();
		row.attr('status','open');
	}
	else {
		rows.hide();
		row.attr('status','closed');
	}
});

$(document).on('click', '.budget_app', function() {
	var dr = $(this).closest('.budget_detail_row');
	var timestamp = dr.attr('timestamp');
	var server_time = dr.attr('server_time');
	var app = $(this).attr('app');
	var filter = dr.attr('filter');
	var sorts = localStorage.getItem('sorts');
	var scope = localStorage.getItem('scope');
	appointmentGrabber(app,timestamp);
	var variables = { app: app, filter: filter, sorts: sorts, timeshift: '0d', time_machine: '', timestamp: timestamp, scope: scope };
	var budgetAppAttempts = 0;
	var budgetAppInterval = setInterval(function() {
		budgetAppAttempts++;
		// give up after 10s if the window never appears, so we don't poll forever
		if (budgetAppAttempts > 50) { clearInterval(budgetAppInterval); return; }
		var parent = $('.wind[app="' + app + '"]');
		if (parent.length > 0) {
			var container = parent.find('.re_details');
		
			$.ajax({ 
				url: '/manager/appointment_details',
				type: 'GET',
				data: variables,
				success: function(response) {
					clearInterval(budgetAppInterval);
					container.html(response);
					container.show();
					appointment_chron();
				}
			});
		}
	},200);
});

$(document).on('click', '.budget_invoice', function() {
	var row = $(this);
	var app = row.attr('app');
	var uuid = row.attr('uuid');
	var timestamp = row.attr('timestamp');
	var sorts = localStorage.getItem('sorts');
	var scope = localStorage.getItem('scope');
	appointmentGrabber(app,timestamp);
	var variables = { app: app, uuid: uuid, sorts: sorts, timeshift: '0d', time_machine: '', timestamp: timestamp, scope: scope };
	var budgetInvoiceAttempts = 0;
	var budgetInvoiceInterval = setInterval(function() {
		budgetInvoiceAttempts++;
		// give up after 10s if the window never appears, so we don't poll forever
		if (budgetInvoiceAttempts > 50) { clearInterval(budgetInvoiceInterval); return; }
		var parent = $('.wind[app="' + app + '"]');
		if (parent.length > 0) {
			var container = parent.find('.re_details');
			if (container.length == 0) { return; }
			clearInterval(budgetInvoiceInterval);
			$.ajax({
				url: '/manager/appointment_details',
				type: 'GET',
				data: variables,
				success: function(response) {
					container.html(response);
					container.show();
					appointment_chron();
				}
			});
		}
	},200);
});

$(document).on('click', '.budget_invoice_payments_toggle', function(e) {
	e.stopPropagation();
	var uuid = $(this).attr('uuid');
	$('.budget_invoice_payment_row[uuid="' + uuid + '"]').toggle();
});

$(document).on('click', '.budget_autocalc', function() {
	var button = $(this);
	var app = button.attr('app');
	var circumstance = $(this).attr('circumstance');
	var timestamp = Date.now();
	button.addClass('active');
	var autoCalcInterval;
	var autoCalcTimeout;
	button.addClass('medium_thumb').removeClass('little_thumb');
	autoCalcInterval = setInterval(function() {
		button.addClass('little_thumb').removeClass('medium_thumb');
		clearTimeout(autoCalcTimeout);
		autoCalcTimeout = setTimeout(function() {
			button.addClass('medium_thumb').removeClass('little_thumb');
		},500);
	}, 1000);

	$.ajax({
		url: '/manager/budget/autocalc',
		type: 'GET',
		data: { timestamp: timestamp, app: app, circumstance: circumstance },
		success: function(response) {
			button.addClass('medium_thumb').removeClass('little_thumb');
			clearInterval(autoCalcInterval);

		//	if ($('.wind[app="budget"').is(':visible')) {
				var message = 'These are the autocalcs for ' + response.data.formatted_app + '<br><br>';
				$.each(response, function(i,v) {
					if (i != 'data') {
						message += '<button app="' + response.data.app + '" circumstance="' + response.data.circumstance + '" result="' + v.formatted_result + '" class="budget_autocalc_accept">' + v.formatted_result +'</button><br>';
					}
				});
				message += '<br><button id="alert_cancel">Cancel</button>'
				$('#alert').html(message);
				$('#alert').show();
				$(this).removeClass('active');
		//	}
			if ($('.wind[app="' + app + '"]').is(':visible')) {
				inventoryDetails(app);
			}
		},
		error: function() {
			// stop the pulse if the autocalc request failed
			button.addClass('medium_thumb').removeClass('little_thumb');
			clearInterval(autoCalcInterval);
		}
	});
});

// the autocalc popover's older buttons carry only the whole entry; read it back
// into the parts the row editor wants
function budgetSuggestionParts(circumstance, entry) {
	entry = $.trim(entry || '');
	var direction = 'floor';
	if (entry.indexOf('<=') === 0) { direction = 'ceiling'; entry = entry.slice(2); }
	else if (entry.indexOf('>=') === 0) { entry = entry.slice(2); }
	var scope = '';
	var slash = entry.lastIndexOf('/');
	if (slash > -1) { scope = entry.slice(slash + 1); entry = entry.slice(0, slash); }
	// the autocalc names a total's scope by its symbol; the budget wants the unit
	var units = { s: 'second', m: 'minute', h: 'hour', d: 'day', w: 'week', M: 'month', y: 'year' };
	if (units[scope]) { scope = units[scope]; }
	var measure = (circumstance === 'occurences') ? '' : ((circumstance === 'total') ? '$' : circumstance);
	var amount = entry;
	if (measure === '$') { amount = amount.replace(/^\$/, ''); }
	else if (measure !== '' && measure !== 'duration' && amount.slice(-measure.length) === measure) {
		amount = amount.slice(0, -measure.length);
	}
	return { amount: amount, measure: measure, scope: scope, direction: direction };
}

// Set the budget the panel recommends: the entry keeps its scope and direction,
// the entry it replaces is named exactly, and the forms on screen (the Budget
// app's table and Configure's row editor) show the new value.
$(document).on('click', '.budget_autocalc_accept', function() {
	var button = $(this);
	var app = button.attr('app');
	var circumstance = button.attr('circumstance');
	var b = $('.budget_edit_input[app="' + app + '"][circumstance="' + circumstance + '"]');
	var amount, measure, scope, direction, previous, result;
	if (typeof button.attr('amount') === 'undefined') {
		var parts = budgetSuggestionParts(circumstance, button.attr('result'));
		amount = parts.amount;
		measure = parts.measure;
		scope = parts.scope;
		direction = parts.direction;
		previous = b.length ? (b.attr('value') || '') : '';
		result = budgetGoalsEntry(amount, measure, scope, direction);
	}
	else {
		amount = button.attr('amount');
		measure = button.attr('measure') || '';
		scope = button.attr('scope') || '';
		direction = button.attr('direction') || 'floor';
		previous = button.attr('previous') || '';
		result = budgetGoalsEntry(amount, measure, scope, direction);
	}
	b.val(result);
	b.attr('value', result);
	var form = $('.budget_goals[app="' + app + '"][setting="budget"]');
	if (form.length) {
		budgetGoalsRowSet(form, measure, amount, scope, direction);
		var label = $('.app_configure_toggle[setting="budget"][app="' + app + '"]');
		if (label.length) {
			label.find('.ability_label').html('<b>' + label.attr('formatted_setting') + ':</b> ' + budgetGoalsValue(form).slice(0, 20));
		}
	}
	$('#alert').hide();
	$.ajax({
		url: '/manager/budget/edit',
		type: 'POST',
		data: { app: app, value: result, previous: previous, circumstance: circumstance },
		success: function(response) {
			if ($('.wind[app="' + app + '"]').is(':visible')) {
				inventoryDetails(app);
			}
		}
	});
});



$(document).on('change, focusout', '.budget_edit_input', function() {
	var input = $(this);
	var app = input.attr('app');
	var value = input.val();
	var circumstance = input.attr('circumstance');
	var previous = input.attr('value') || '';
	// change and focusout both fire on a blur; only one of them is a real edit
	if (value === previous) { return; }
	input.attr('value', value);
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/budget/edit',
		type: 'POST',
		data: { app: app, value: value, previous: previous, circumstance: circumstance },
		success: function(response) {
		}
	});
});

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

function budgetLight(app,circumstance,status) {
	var blci = $('.budget_current_information[app="' + app + '"]');
	var wind = blci.closest('.wind');
	var header;
	if ((blci.is(':visible') && status != 'open') && blci.attr('circumstance') == circumstance) {
		blci.hide();
		blci.attr('status', 'closed');
		circumstance = undefined;
		blci.attr('circumstance', undefined);
		header = blci.html();

//		cacheSet({ 'app': app, 'context': 'header' }, { 'timestamp': timestamp, 'header': header });
	}
	else {
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
			if ($('#alert').length) { $('#alert').html(message).show(); }
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
			if ($('#alert').length) { $('#alert').html(message).show(); }
			else { $('#budget_journal_message').text(message); }
			budgetInit();
		},
		error: function() {
			button.removeAttr('disabled');
			$('#budget_journal_message').text(jawnosT('The journal could not be rebuilt.'));
		}
	});
});









