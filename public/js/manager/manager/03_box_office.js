async function clipboardGetter(s) {
	$.ajax({
		url: '/manager/clipboard_getter',
		type: 'GET',
		success: function(response) {
			s.val(response);
		}
	});
}

$(document).on('click', '.clip', function() {
	clipboardSetter($(this).text());
});

function clipboardSetter(clip) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/clipboard_setter',
		type: 'POST',
		data: { timestamp: timestamp, clipboard: clip },
		success: function(response) {

		}
	});
}

$(document).on('change', '.volume_control', function(e) {

	var control = $(this);
	var stream = control.attr('stream');
	var volume = control.val();
	var max_volume = control.attr('max');

	var total_width = control.width();
  var current_location = e.offsetX;

	control.val(volume);
	var timestamp = Date.now();
	var device = localStorage.getItem('volume_control_device');
	var data = { stream: stream, volume: volume, max: max_volume, device: device };
	$.ajax({
		url: '/manager/volume_control',
		type: 'GET',
		data: data,
		success: function(response) {
		 volumeChecker();
		}
	});

});

function volumeChecker() {
	var device = localStorage.getItem('volume_control_device');
	$.ajax({
		url: '/manager/volume_control',
		type: 'GET',
		data: { device: device },
		success: function(response) {
			var writer = '';
			$.each(response.volumes, function(i,v) {
				writer += '<b>' + v['stream'] + '</b><input type="range" style="width:60%;" class="volume_control" stream="' + v['stream'] + '" value="' + v['volume'] + '" max="' + v['max_volume'] + '"><br>';
			});
			$('#device_volume_control').html(writer);

			$.each(response.remote_machines, function(i,rm) {
				$('#device_volume_control').prepend('<span class="volume_control_device hover" device="' + rm.uuid + '"><b>' + rm.fqdn + '</b></span><br>');
			});

			$('#device_volume_control').prepend('<span class="volume_control_device hover" device="local"><b>Local</b></span><br>');
			$('.volume_control_device[device="' + device + '"]').addClass('selected');
		}
	});
}

$(document).on('click', '.volume_control_device', function() {
	$('.volume_control_device').removeClass('selected');
	$(this).addClass('selected');
	var device = $('.volume_control_device.selected').attr('device');
	localStorage.setItem('volume_control_device', device);
	volumeChecker();
});


$(document).on('click', '#ticketmaker', function() {
	boxOffice();
});

// The two views are tabs now. The value still lives in #box_office_view (a
// hidden input) so boxOffice() and the server keep reading one place.
$(document).on('click', '.bo_tab', function() {
	var view = $(this).attr('view');
	if (!view || view === $('#box_office_view').val()) { return; }
	$('#box_office_view').val(view);
	settingSetter({ 'app': 'misc', 'setting': 'box_office_view', 'value': view });
	boxOffice();
});

function boxOffice() {
	var view = $('#box_office_view').val();
	$.ajax({
		url: '/manager/box_office',
		type: 'GET',
		data: { timestamp: timestamp, view: view },
		success: function(response) {
			boxOfficeMaker(response);
		}
	});
}

// Ticket requests raise a dot on the start menu's Tickets icon until the box
// office is opened, exactly as a letter rings the envelope.
function ticketDotSet(message) {
	localStorage.setItem('ticket_waiting', message || 'Pass request');
	ticketDotPaint();
}

function ticketDotPaint() {
	var icon = $('#ticketmaker');
	if (!icon.length) { return; }
	if (localStorage.getItem('ticket_waiting')) { icon.attr('waiting', 'yes'); }
	else { icon.removeAttr('waiting'); }
}

function ticketDotClear() {
	localStorage.removeItem('ticket_waiting');
	$('#ticketmaker').removeAttr('waiting');
}

function ticketArrival(data) {
	ticketDotSet(data ? data['message'] : '');
}

$(document).on('click', '.ticket_approve', function() {
	var b = $(this);
	var row = b.closest('.ticket_request');
	var ticket = b.attr('ticket');
	$.ajax({
		url: '/manager/box_office/approve',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			ticket: ticket,
			privilege: row.find('.ticket_request_privilege').val(),
			warranty: row.find('.ticket_request_warranty').val()
		},
		success: function(response) {
			b.css({ 'background-color': 'green' });
			setTimeout(function() { boxOffice(); }, 400);
		},
		error: function(response) {
			b.css({ 'background-color': 'red' });
		}
	});
});

$(document).on('click', '.ticket_decline', function() {
	var ticket = $(this).attr('ticket');
	$.ajax({
		url: '/manager/box_office/decline',
		type: 'POST',
		data: { timestamp: Date.now(), ticket: ticket },
		success: function(response) { boxOffice(); }
	});
});

$(document).on('click', '.ticket_blacklist', function() {
	var ticket = $(this).attr('ticket');
	$.ajax({
		url: '/manager/box_office/blacklist',
		type: 'POST',
		data: { timestamp: Date.now(), ticket: ticket },
		success: function(response) { boxOffice(); }
	});
});

$(document).on('click', '.ticket_blacklist_remove', function() {
	var stamp = $(this).attr('stamp');
	$.ajax({
		url: '/manager/box_office/blacklist/remove',
		type: 'POST',
		data: { timestamp: Date.now(), stamp: stamp },
		success: function(response) { boxOffice(); }
	});
});

// The blocked numbers: the desk's blacklist seen as calls. Block adds one by
// hand (the same list the Phone app's Block button writes to), Remove takes an
// entry off, and the whole list is handed to the phone on the next jawnPhoneSync.
// Blocking is a lasting rule, so it takes two presses like every other one here.
$(document).on('click', '#blocked_number_add_button', function() {
	var b = $(this);
	if (b.attr('armed') !== 'yes') {
		if (!$('#blocked_number_input').val()) { $('#blocked_number_status').text('Enter a number.'); return; }
		b.attr('armed', 'yes');
		var bg = b.css('background-color');
		b.css({ 'background-color': 'red' });
		$('#blocked_number_status').text('Press again to block');
		setTimeout(function() { b.css({ 'background-color': bg }); b.attr('armed', 'no'); }, 2000);
		return;
	}
	b.attr('armed', 'no');
	b.css({ 'background-color': '' });
	var number = $('#blocked_number_input').val();
	$.ajax({
		url: '/manager/box_office/blacklist/number',
		type: 'POST',
		data: { timestamp: Date.now(), number: number, note: $('#blocked_number_note').val() },
		success: function(response) {
			if (response && response.ok) { jawnPhoneSync(); boxOffice(); }
			else { $('#blocked_number_status').text('Enter a number.'); }
		}
	});
});

$(document).on('click', '.blocked_number_remove', function() {
	var stamp = $(this).attr('stamp');
	$.ajax({
		url: '/manager/box_office/blacklist/remove',
		type: 'POST',
		data: { timestamp: Date.now(), stamp: stamp },
		success: function(response) { jawnPhoneSync(); boxOffice(); }
	});
});

$(document).on('click', '#ticket_policy_save', function() {
	$.ajax({
		url: '/manager/box_office/policy',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			issue_guest_on_request: $('#ticket_policy_auto').is(':checked') ? 'on' : 'off',
			guest_warranty: $('#ticket_policy_warranty').val()
		},
		success: function(response) { boxOffice(); }
	});
});

$(document).on('change', '.ticket_privilege_change', function() {
	var s = $(this);
	$.ajax({
		url: '/manager/ticket_privilege',
		type: 'POST',
		data: { timestamp: Date.now(), uuid: s.attr('uuid'), privilege: s.val() },
		success: function(response) { s.css({ 'background-color': 'lightgreen' }); }
	});
});

function boxOfficeMaker(response) {
	if (response) {
		windowMaker(response);
		$('#box_office').show();
		ticketDotClear();
	}
}



$(document).on('click', '.box_office_close_button', function() { 
	$('#ticket_sales').hide();
});

$(document).on('click', '#ticket_issue', function() {
	qrcode_generator();
});

function qrcode_generator(app) {
	var timestamp = Date.now();
	var button = $('#ticket_issue');
	var status = $('#ticket_issue_status');
	var nic = $('#ticket_network_device').val();
	var name = $('#ticket_name').val();
	var warranty = $('#ticket_warranty').val();
	var privilege = $('#ticket_privilege').val();
	var project = $('#ticket_project').val();
	var chosen_app = app || $('#ticket_app').val();
	var debriefer = JSON.stringify(localStorage);

	if (!chosen_app) {
		status.text(jawnosT('Choose an app first.'));
		return;
	}
	if (button.length) { button.prop('disabled', true).text(jawnosT('Issuing…')); }
	status.text('');

	$.ajax({
		url: '/manager/qrcode_generator',
		type: 'GET',
		data: { timestamp: timestamp, nic: nic, debriefer: debriefer, name: name, warranty: warranty, privilege: privilege, app: chosen_app, project: project },
		success: function(response) {
			if (response && !response.error && response.uuid) {
				var who = response.name || name || 'visitor';
				status.empty().text(jawnosT('Pass issued for') + ' ' + who + ' (' + chosen_app + '). ');
				if (response.url) {
					$('<a>').attr({ href: response.url, target: '_blank', rel: 'noopener' }).text(jawnosT('Open')).appendTo(status);
				}
				ticket_list();
			}
			else {
				status.text(jawnosT('The pass could not be issued.'));
			}
		},
		error: function() {
			status.text(jawnosT('The pass could not be issued.'));
		},
		complete: function() {
			if (button.length) { button.prop('disabled', false).text(jawnosT('Issue pass')); }
		}
	});
}

function ticket_list() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/box_office',
		type: 'GET',
		data: { timestamp: timestamp, source: 'list' },
		success:function(response) {

			var tl = $(response).find('#ticket_list').html();

			$('#ticket_list').html(tl);
			bo_ticket_count();
		}
	});
}

// The Tickets tab and the card's own count both read the rows on the page.
function bo_ticket_count() {
	$('#bo_ticket_count').text($('#ticket_list_body .ticket_holder').length);
}

// Copying the link matters: the link is the credential and retyping it from
// the row is how the old desk made people share a secret badly.
function bo_copy_text(text, button) {
	var done = function() {
		var old = button.text();
		button.text(jawnosT('Copied'));
		setTimeout(function() { button.text(old); }, 1500);
	};
	var fallback = function() {
		var ta = $('<textarea>').val(text).css({ position: 'fixed', opacity: 0, top: 0, left: 0 });
		$('body').append(ta);
		ta[0].select();
		try { document.execCommand('copy'); done(); } catch (e) { /* the browser refused both */ }
		ta.remove();
	};
	if (navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(text).then(done, fallback);
	}
	else { fallback(); }
}

$(document).on('click', '.bo_copy_link', function() {
	var b = $(this);
	bo_copy_text(b.attr('data-url') || '', b);
});

$(document).on('click', '.ticket', function(e) {
	// a ticket's duration is a reading, not the card's resize handle
	if ($(e.target).closest('.jawnos_duration').length) { return; }
	var t = $(this);
	var width = t.width();
	if (width < 200) {
		$(this).css({'width': '200px', 'height': '200px' });
	}
	else {
		t.css({'width': '40px', 'height': '40px' });
	}
});

$(document).on('click', '.delete_ticket', function() {
	var a = $(this);
	var timestamp = Date.now();
	var uuid = a.attr('uuid');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/delete_ticket',
			data: { timestamp: timestamp, uuid: uuid },
			success: function(response) {

				$('.ticket_holder[uuid="' + response['uuid'] + '"]').remove();
				bo_ticket_count();
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

$(document).on('click', '.suspend_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	$.ajax({
		url: '/manager/suspend_ticket',
		data: { uuid: uuid, timestamp: timestamp },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			}, 1000);
		}
	});
});

