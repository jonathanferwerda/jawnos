

$(document).on('click', '#security_toggle', function() {

	var url = '/manager/security';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response.html)
		}, error: function (response) { 
			padlockReset();
		}
	});
});

$(document).on('click', '#padlock_delete', function() {
	var a = $(this);

	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/security/padlock/delete',
			type: 'POST',
			success: function() {
				$('#padlock_delete').hide();
				$('#lock_session').hide();
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

$(document).on('change', '#padlock_contexts', function() {
	var contexts = $(this).val();
	contexts = JSON.stringify(contexts); 
	settingSetter({ 'app': '__president', 'setting': 'padlock_contexts', 'value': contexts });
});


$(document).on('click', '.padlock_jog_wheel',function(e) {
	var timestamp = Date.now();


	if (padlock_numbers.digits.length == 3 ) {
		var combo = JSON.stringify(padlock_numbers.digits);
		var pulled = JSON.stringify(padlock_numbers.pulled);

		padlock_numbers.pulled = [];
		$.ajax({
			url: '/manager/security/padlock',
			type: 'POST',
			data: { timestamp: timestamp, combo: combo, pulled: pulled },
			success: function(response) {

				if (response.status == 'saved') {
					$('.padlock_lock').hide();
					$('.padlock_unlock').show();
					$('.padlock_light').addClass('superactive');
					$('#lock_session').show();
					$('#padlock_delete').show();
					setTimeout(function() {
						$('.padlock_light').removeClass('superactive');
						$('.padlock_light.yellow').hide();
					},5000);
				}
			}
		});
	}
});


$(document).on('click', '.security_view_select', function() {
	var view = $(this).attr('view');
	settingSetter({
		'app': '__president',
		'setting': 'security_view',
		'value': view
	});
	$('.security_view').hide();
	$('.security_view[view="' + view + '"]').show();
	$('.security_view_select').css({ 'background-color': 'lightgray' });
	$('.security_view_select[view="' + view +'"]').css({ 'background-color': 'lightgreen' });


	var url = '/manager/security';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { timestamp: timestamp, security_view: view },
		success: function(response) {
			$('#security').html(response.html);
			appointment_chron();
		}, error: function (response) { 
			padlockReset();
		}
	});
});

$(document).on('click', '.neighbour_link_updater', function() {
	var nlu = $(this);
	var nl = nlu.closest('.neighbour_link');
	var uuid = nl.attr('uuid');
	var nlus = $('.neighbour_link_updater_selection[uuid="' + uuid + '"]');
	if (nlus.is(':visible')) {
		nlus.hide();
	}
	else {
		nlus.show();
	}
});

$(document).on('click', '.neighbour_link_privilege_change', function() {
	var privilege = $(this).attr('privilege');
	var nl = $(this).closest('.neighbour_link_updater_selection');
	var uuid = nl.attr('uuid');
	$.ajax({
		url: '/manager/security/neighbour_link_privilege',
		type: 'POST',
		data: { uuid: uuid, privilege: privilege },
		success: function(response) {
			$('#security').html(response);
			appointment_chron();
		}
	});
});


$(document).on('click', '.neighbour_link_credential', function() {
	var nlr = $(this).closest('.neighbour_link_request');
	var privilege = $(this).attr('privilege');
	var credential = nlr.attr('credential');
	var remote_address = nlr.attr('remote_address');
	var local_address = nlr.attr('local_address');
	var my_name = nlr.attr('my_name');
	$.ajax({
		url: '/manager/security/neighbour_link_assign',
		type: 'POST',
		data: {
			privilege: privilege,
			remote_address: remote_address,
			local_address: local_address,
			my_name: my_name,
			credential: credential
		},
		success: function(response) {
			$('#alert').html('').hide();
		}
	});
});

$(document).on('click', '.neighbour_link_delete', function() {
	var uuid = $(this).closest('.neighbour_link').attr('uuid');
	$.ajax({
		url: '/manager/security/neighbour_link_delete',
		type: 'POST',
		data: { uuid: uuid },
		success: function(response) {
			$('#security').html(response);
			appointment_chron();
		}
	});
});

$(document).on('click', '.signatorial_selection', function() {
	var sig = $(this);
	var file = sig.attr('file');
	$.ajax({
		url: '/manager/security/signatorial/selection',
		type: 'POST',
		data: { file: file },
		success: function(response) {
			$('#security').replaceWith(response.html);
		}
	});



});