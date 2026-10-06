$(document).ready(function() {
	$('#president').focus();
	$('#president').trigger('click');
});
var directory;
$(document).on('keyup click', '#president', function() {

	var input = $(this);
	var timestamp = Date.now();

	if (input.val().match('/')) {
		var dir = input.val();

		$.ajax({
			url: '/manager/gate',
			type: 'GET',
			data: { restore_list: dir },
			success: function(response) {
				var r = $(response)[31];
				if (r) {
					$('#results_grabber').html($(r).html());
					directory = dir;
				}
				else {
					directory = undefined;
				}
				var sd = $('.select_database')[0];
				$(sd).trigger('click');
			}

		});
	}
});

var sig_h;
$(document).on('click', '#signatorial_upload_button', function() {
	var m =	$('#signatorial_upload_input');
	sig_h = $('#signatorial_upload_container').html();
	m.trigger('click');
});


$(document).on('change', '#signatorial_upload_input', function() {
	var m =	$('#signatorial_upload_input');

//	m.trigger('click');
	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {

	//	$('#signatorial_upload').trigger('submit');
		$('#ticket_number_1').focus();
	}
});

var m;
$(document).on('keyup', '.ticket_input', function() {
	var input = $(this);
	var input_number = input.attr('data-input_number');
	var timestamp = Date.now();
	var president = $('#president').val();

	if (input_number < 8 && input.val().length > 0) {
		var i = input_number;
		i++
		$('#ticket_number_' + i).focus();

	}
	if ( input_number == 8) {

		var numerics = "";

		$('.ticket_input').each(function() {
			numerics = numerics + $(this).val();
		});
		var backup = $('.select_database.selected').attr('filename');
		var formData = new FormData(document.getElementById('signatorial_upload'));
		var m =	$('#signatorial_upload_input');
		if (m[0]['files'].length == 0) {
			formData.delete('fileupload');
		}
		formData.delete('timestamp');
		formData.append('timestamp', timestamp);
		formData.append('numerics', numerics);
		formData.append('backup', backup);
		formData.append('president', president);
		formData.append('source','gate');
		$.ajax({
			url: '/sesh_check',
			type: 'POST',
			data: formData,
			success: function(response) {
				gateKeeper(response);
				m = undefined;
				formData.delete('fileupload');
				$('#signatorial_upload').remove();
				$('#signatorial_upload_container').html(sig_h);
			},
			cache: false,
			contentType: false,
			processData: false
		});
	}
});

function isJson(str) {
	try {
		JSON.parse(str);
	}
	catch (e) {
		return false;
	}
	return true;
}

function gateKeeper(response) {
	console.log(response);
	$('#message').text(response['message']).show();
	if (response.authentication == 'approved') {
		if (isJson(response.debriefer)) {
			var d = eval(JSON.parse(response.debriefer));
			$.each(d,function(i,v) {
				localStorage.setItem(i,v);
			});
			if(!d.redirector) {
				window.location.reload();
			}
		}

	}
	else if (response.authentication == 'denial') {
		$('html').html(response.denial).css({"height":"100%", "background-color": '#1486ff'});;
	}
}

$(document).on('click','.select_database',function() {
	var s = $(this);
	$('.select_database').removeClass('selected');
	if (s.hasClass('selected')) {
		s.removeClass('selected');
	}
	else {
		s.addClass('selected');
		$('#ticket_number_1').focus();
		$('#president').val(s.attr('filename'));
	}
});

$(document).on('click', '#payment_toggle', function() {
	if ($('#payment_toggle').text() == '...') { return; };
	var amount = $('#payment_amount').val();
	$('#payment_toggle').text('...');
	$.ajax({ 
		url: '/payment',
		type: 'POST',
		data: { amount: amount },
		success:function(response) {

			payment = JSON.parse(response);

			setTimeout(function() {
				var win = window.open(payment.payment_link.url, '_blank');
				if (win) {
					win.focus();
				} else {
					alert('I need to open a new window to let you pay, may I?');
				}
				$('#payment_toggle').text('$');
			},1000);
		}
	});
});

$(document).on('click', '#k', function() {
	var k = $('#keyboard,#numberpad');
	if (k.is(':visible')) {
		k.hide();
	}
	else {
		k.show();
	}
});

var trigger_happy;
$(document).on('click', '.keyboard_button', function() {
	var b = $(this);
	b.css({'background-color' : 'yellow' });
	var selector = "";
	if (b.attr('key') == 'backspace') {
		var c = focused_input.val();
		var l = c.split('');
		for (var s = 0; s = c.length - 1; s++) {
			var t = t + l[s];
			c = t;
		}
		focused_input.val(c);
	}
	else {
		focused_input.val(focused_input.val() + b.attr('key'));
		focused_input.trigger('change');
	}


	setTimeout(function() {
		b.css({'background-color': 'white' });
	},200);
});

var focused_input = $('#president');
$(document).on('click', 'input',function() {
	focused_input = $(this);

});
$(document).on('click', 'textarea',function() {
	focused_input = $(this);

});
