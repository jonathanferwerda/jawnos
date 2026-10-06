
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
	var budgetAppInterval = setInterval(function() {
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
		}
	});
});

$(document).on('click', '.budget_autocalc_accept', function() {
	var app = $(this).attr('app');
	var circumstance = $(this).attr('circumstance');
	var result = $(this).attr('result');
	var b = $('.budget_edit_input[app="' + app + '"][circumstance="' + circumstance + '"]');
	b.val(result);
	b.trigger('focusout');
	$('#alert').hide();
	if ($('.wind[app="' + app + '"]').is(':visible')) {
		inventoryDetails(app);
	}
	$.ajax({
		url: '/manager/budget/edit',
		type: 'POST',
		data: { app: app, value: result, circumstance: circumstance },
		success: function(response) {
		}
	});
});



$(document).on('change, focusout', '.budget_edit_input', function() {
	var input = $(this);
	var app = input.attr('app');
	var value = input.val();
	var circumstance = input.attr('circumstance');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/budget/edit',
		type: 'POST',
		data: { app: app, value: value, circumstance: circumstance },
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









