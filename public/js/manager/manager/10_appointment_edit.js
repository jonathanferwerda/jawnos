$(document).on('click','.edit_app_submit', function() {
	var edit = $(this);
	var app = edit.attr('app');
	var uuid = edit.attr('uuid');
	var ea = $('.appointment_edit_area[uuid="' + uuid + '"]');
	// Only the controls this form actually rendered are written. An absent
	// control used to ride into the POST as '' (jQuery serialises undefined to
	// key=), which blanked good columns; the `sent` list lets the route tell
	// "unchanged" from "the person cleared this field".
	var payload = { app: app, uuid: uuid, sent: [] };
	var control = function (name) {
		return ea.find('input[attribute="' + name + '"], select[attribute="' + name + '"], textarea[attribute="' + name + '"]').first();
	};
	var put = function (name) {
		var f = control(name);
		if (!f.length) { return; }
		var v = (f.attr('type') == 'checkbox') ? (f.prop('checked') ? 'on' : 'off') : f.val();
		payload[name] = (v === undefined || v === null) ? '' : v;
		payload.sent.push(name);
	};
	var put_attr = function (name, attr) {
		var f = control(name);
		if (!f.length) { return; }
		var v = f.attr(attr);
		payload[name] = (v === undefined || v === null) ? '' : v;
		payload.sent.push(name);
	};
	put('duration');
	var name_input = ea.find('[attribute="app"]').first();
	if (name_input.length) { payload.app_name = name_input.val() || ''; payload.sent.push('app_name'); }
	put('account');
	put('project');
	put('start_notes');
	put('notes');
	put('end_notes');
	put('movement');
	put('amount');
	put('tax');
	put('aux');
	put('aux_description');
	put('total');
	put('vendor');
	put('unit');
	put('quantity');
	put('item');
	put('state');
	put_attr('timestamp', 'timestamp');
	put_attr('warranty', 'timestamp');
	$.each({ tax: 'has_tax', totes: 'has_totes' }, function (config, name) {
		var c = ea.find('.purchase_config[config="' + config + '"]');
		if (!c.length) { return; }
		payload[name] = c.attr('enabled') || 'off';
		payload.sent.push(name);
	});
	payload.sent = payload.sent.join(',');
	$.ajax({
		url: '/manager/edit_app',
		type: 'POST',
		data: payload,
		success: function(response) {
			edit.removeClass('medium_thumb');
			edit.addClass('large_thumb');
			setTimeout(function() {
				edit.removeClass('large_thumb');
				edit.addClass('medium_thumb');
			}, 2000);
		},
		error: function(xhr) {
			if (xhr && xhr.status == 409) { alert('That name is already in use.'); }
		},
	});
});

$(document).on('click', '.edit_app_clone', function() {
	var b = $(this);
	var app = b.attr('app');
	var ea = b.closest('.appointment_edit_area');
	var status = ea.find('.edit_app_status');
	var name = $.trim(ea.find('[attribute="clone_name"]').val() || '');
	if (!name) { status.text('Type a name for the clone.'); return; }
	status.text('Cloning...');
	$.ajax({
		url: '/manager/clone_app',
		type: 'POST',
		data: { app: app, new: name, timestamp: Date.now() },
		success: function(response) {
			if (response && response.ok) { status.text('Cloned to ' + response.app + '.'); }
			else { status.text((response && response.error) || 'Could not clone.'); }
		},
		error: function(xhr) { status.text(xhr && xhr.status == 409 ? 'That name is already in use.' : 'Could not clone.'); }
	});
});

$(document).on('click', '.edit_app_delete', function() {
	var b = $(this);
	var app = b.attr('app');
	var uuid = b.attr('uuid');
	// This editor edits one record, so its trash deletes that record and only it.
	// Deleting a whole app lives in Configure -> the app's card, where the name
	// has to be typed first.
	if (!confirm('Delete this record?')) { return; }
	if (!confirm('Delete it for good? This is copied to every machine.')) { return; }
	var ea = b.closest('.appointment_edit_area');
	var status = ea.find('.edit_app_status');
	status.text('Deleting...');
	$.ajax({
		url: '/manager/delete_app',
		type: 'POST',
		data: { app: app, uuid: uuid, timestamp: b.attr('timestamp'), type: b.attr('type'), server_time: Date.now() },
		success: function() {
			ea.html('').hide();
		},
		error: function() { status.text('Could not delete.'); }
	});
});

$(document).on('click', '.delete_app', function() {
	var a = $(this);
	var app = a.attr('app');
	var formatted_name = a.attr('formatted_name');
	var formatted_time = a.attr('formatted_time');
	var formatted_duration = a.attr('formatted_duration');
	var uuid = a.attr('uuid');
	var app_type = a.attr('app_type');
	var server_time = a.attr('server_time');
	var timestamp = a.attr('timestamp');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/delete_app',
			type: 'POST',
			data: { app: app, uuid: uuid, timestamp: timestamp, type: app_type, server_time: server_time },
			success: function(response) {
				$('.appointment_detail[uuid="' + uuid + '"]').remove();
				if (response.deleter.status == 'start' || response.deleter.status == 'record') {
					continent_cancel(app);
				}
			},
			error: function(err) { 
				jawnosAlert('It didn\'t work! Try again!');
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

$(document).on('click', '.delete_file', function() {
	var a = $(this);
	var app_uuid = a.attr('app_uuid');
	var file_uuid = a.attr('file_uuid');
	var app = a.attr('app');
	if (a.attr('armed')) {
		$.ajax({
			url: '/manager/delete_file',
			type: 'POST',
			data: { app_uuid: app_uuid, file_uuid: file_uuid, app: app },
			success: function(response) {
				$.each(images, function(i,v) {
					if (v['app'] == response.app && response.file_uuid == v['uuid']) {
						images.splice(i,1);
						if (image_number == i && ($('#main_video').is(':visible') || $('#main_image').is(':visible'))) {
							galleryImageDisplayer();
						}
					}


				});
				$('[app_uuid="' + response.app_uuid + '"][file_uuid="' + response.file_uuid + '"]').remove();
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

$(document).on('change', '.file_information_updater', function() {
	var a = $(this);
	var value = a.val();
	var f = a.closest('.file_information');
	var attribute = a.attr('attribute');
	var file_uuid = f.attr('file_uuid');
	var app_uuid = f.attr('app_uuid');
	var app = f.attr('app');
	var data = { app: app, file_uuid: file_uuid, app_uuid: app_uuid, attribute: attribute, value: value };
	$.ajax({
		url: '/manager/file/information_updater',
		type: 'POST',
		data: data,
		success: function(response) {
			a.val(response['value']);
		}
	});
});


$(document).on('click', '.close_appointment', function() {
	var t = $(this);
	var p = t.closest('.appointment');
	var w = p.closest('.window_view');
	p.closest('.wind').remove();
	var height = $(window).height(); 
	if (p.find('#mouse_shadow')) { $('#mouse_shadow').css({ 'top': height }); }
	var containers = p.find('.appointment');
	if (containers.length == 1) {
		p.hide();
	}
	var app = t.attr('app');
	websocketStop(app);

	windowSaver();
	$('#' + app).remove();
	$('#' + app).closest('.wind').remove();
	if (w.find('.appointment :visible').length == 0) {
		w.hide();
	}
});

function appointmentMeasuresGrabber(a) {
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_measures');
	$.ajax({
		url: '/manager/appointment_measures',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			container.html(response).show();
		}
	});
}


$(document).on('click', '.det', function() {

	var a = $(this);
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_details');
	// an area showing no appointments is not an open list: treat it as closed, so
	// the tap refetches the current timeframe's appointments instead of just hiding
	// an empty panel
	if (container.is(':visible') && container.find('.appointment_detail').length > 0) {
		container.html('<span class="detail_json" app="' + app + '">{}</span>').hide();
	}
	else {
		appActExclusive(app, 'det');
		appointmentDetailsGrabber(a);
		container.show();
	}
	appActSync(app);
});

$(document).on('click', '.register', function() {
	var a = $(this);
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_register');
	if (container.is(':visible')) {
		container.html('').hide();
	}
	else {
		appActExclusive(app, 'register');
		registerGrabber(app);
		container.show();
	}
	appActSync(app);
});

function registerGrabber(app) {
	var container = $('.appointment[app="' + app + '"]').find('.re_register');
	$.ajax({
		url: '/manager/register_grabber',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			container.html(response.html);
			openAttributeReopener(app)
		}
	});
}


var appDetailsScroll = {};

$(document).on('mousewheel touchmove', '.detail_area', function(e) {
	if ($(e.target).is('canvas')) {
		e.preventDefault();e.preventDefault();
	}
	var app = $(this).attr('app');
	var scroll = $(this).offset().top;
	var height = $(this).height();
	var cheight = $(this).closest('.appointment').height();
	if ((height - (cheight + Math.abs(scroll))) < 530) {
		if (appDetailsScroll[app]['reload'] == 0) {
			appDetailsScroll[app]['reload'] = 1;
			
		//	appointmentDetailsGrabber($(this),'scroll');
		}
	}
});

function appointmentDetailsGrabber(a,source) {
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	if ($('.wind[app="' + app + '"]').length > 0) {
		var container = parent.find('.re_details');
		container.html('');
		var timestamp = Date.now();
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var time_machine = localStorage.getItem('time_machine');
		var sorts = localStorage.getItem('sorts');
		var scope = localStorage.getItem('scope');
		var filter = localStorage.getItem('filter');

		if (source == 'scroll') {

		}

		var variables = { sorts: sorts, app: app, filter: filter, time_machine: time_machine, timeshift: timeshift, timestamp: timestamp, scope: scope };
		$.ajax({ 
			url: '/manager/appointment_details',
			type: 'GET',
			data: variables,
			success: function(response) {
				container.html(response);
				container.show();
				appointment_chron();
				appDetailsScroll[app]['reload'] = 0;
			}
		});
	}
}

function appointmentDetailGrabber(app,uuid) {
	if ($('.wind[app="' + app + '"]').length > 0) {
		var timestamp = Date.now();
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var time_machine = localStorage.getItem('time_machine');
		var sorts = localStorage.getItem('sorts');
		var scope = localStorage.getItem('scope');
		var filter = localStorage.getItem('filter');
		var variables = { uuid: uuid, sorts: sorts, app: app, filter: filter, time_machine: time_machine, timeshift: timeshift, timestamp: timestamp, scope: scope };
		var lists = []
		$('.appointment_detail[uuid="' + uuid + '"]').find('.appointment_list').each(function(i,v) {
			if ($(v).is(':visible')) {
				lists.push($(v).attr('list'));
			}
		});
		$.ajax({
			url: '/manager/appointment_details',
			type: 'GET',
			data: variables,
			success: function(response) {
				var selector = '.appointment_detail[uuid="' + uuid + '"][app=\"' + app + '\"]';
				if ($(selector).length > 0) {
					$(selector).html($(response).find(selector).html());
				}
				else {
					$('.detail_area[app="' + app + '"]').append($(response).find(selector).clone());
				}
				appointment_chron();
				var q = $('.appointment_detail[app="' + app + '"]').length;
				$('.detail_quantity[app="' + app + '"]').text(q);
				$.each(lists, function(i,v) {
					$('.appointment_detail[uuid="' + uuid + '"]').find('.appointment_list[list="' + v + '"]').show();
				});
			}
		});
	}
}

function appointmentDetailsUpdater(app) {

	var updates = {};
	var selector1 = '.detail_area';
	if (app) {
		selector1 = '.detail_area[app="' + app + '"]';
	}
	$(selector1).each(function(n,ve) {
		var dapp = $(ve).attr('app');
		if ($('.wind[app="' + dapp + '"]').length > 0) {
			updates[dapp] = {};
			updates[dapp]['details'] = [];
			var data = $('.detail_json[app="' + dapp + '"]').text() || {};
			updates[dapp]['data'] = JSON.parse(data);
			$.ajax({
				url: '/manager/appointment_details',
				type: 'GET',
				data: updates[dapp]['data'],
				success: function(response) {
					var results = $(response).find('.appointment_detail[app="' + dapp + '"]');

					results.each(function(i,v) {
						var uuid = $(v).attr('uuid');
						var last_update = $(v).attr('last_update');
						var selector = '.appointment_detail[app="' + dapp + '"][uuid="' + uuid + '"]';
						var vn = $(selector);
						if (vn.length > 0 && vn.is(':visible')) {
							if ($(v).attr('last_update') > vn.attr('last_update')) {
								vn.replaceWith($(v).clone());
							}
						}
						else {
							$('.detail_area[app="' + dapp + '"]').append($(v).clone());
						}
						var q = results.length;
						$('.detail_quantity[app="' + dapp + '"]').text(q);
					});
				}	
			});
		}
	});
}

$(document).on('click', '.notespace', function() {
	var text = $(this).html();
	text = text.replaceAll('<br>', "\n");
	
	var notes = $(this).closest('.appointment').find('.notes');

	notes.val(text);


});

$(document).on('click', '.notes_toggle', function() {
	var toggle = $(this);
	var timestamp = Date.now();
	var app = toggle.attr('app');
	var app_timestamp = toggle.attr('timestamp');
	var server_time = toggle.attr('server_time');
	var uuid = toggle.attr('uuid');
	var appointment = toggle.closest('.appointment_detail');
	var notespace = appointment.find('.notespace');
	if (notespace.html() == '') {
		$.ajax({
			url: '/manager/note_retriever',
			type: 'GET',
			data: { app_timestamp: app_timestamp, timestamp: timestamp, app: app, server_time: server_time, uuid: uuid },
			success: function(response) {
				notespace.html(response.notes).show();
			}
		});
	}
	else {
		notespace.html('');
		notespace.hide();
	}
});


$(document).on('click', '.leave', function() {
	leave();
});
function leave() {
	var d = JSON.stringify(localStorage);
	jpStop();
	websocketStop();
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/leave',
		type: 'POST',
		data: { timestamp: timestamp, debriefer: d },
		success: function(response) {
			localStorage.clear();
//			$('body').replaceWith(response);
			location.reload();
		},
		error: function(err) { console.log('Error', err); }
	});
}

var lockSessionTap = null;
function jawnLockScreen(scope) {
	$.post('/manager/lock_session', {
		scope: scope || '',
		device_uuid: localStorage.getItem('device_uuid') || ''
	}, function(res) {
		// the reply carries the overlay: the screen that pressed the lock must
		// cover itself now, not wait for a websocket push that a handheld's
		// worker may not be listening for
		if (!res || !res.ok || !res.html) { return; }
		var pf = $('#padlock_frame');
		// the same black screen a refresh shows: without an opaque backdrop the
		// hidden desktop's texture showed through and the lock looked different
		// depending on which path had turned it
		pf.html(res.html).css({ position: 'fixed', 'z-index': 60000, 'background-color': '#101010' }).show();
		$('#everything').hide();
	}, 'json');
}
