$(document).ready(function() {
	localStorage.setItem('browser_tab_id', bti);
	warrantyChron();
	$('video,audio').each(function(i,v) {
		if ($(v).closest('.article').length > 0) {
			var src = $(v).attr('src');
			var article_uuid = $(v).closest('.article').attr('uuid');
			src = src + '&browser_tab_id=' + bti + '&uuid=' + article_uuid;
			$(v).attr('src', src);
		}
		else { console.log('not an article'); }
	});
});

var warranty_chron;

function warrantyChron() {
	clearInterval(warranty_chron);
	warranty_chron = setInterval(function() {
		var wTimestamp = Date.now();
		$('.article').each(function(i,v) {
			if ($(v).attr('warranty') < wTimestamp) {
				$(v).remove();
			}
		});
	},1000);
}



$(document).on('click', 'img.editor_content_component', function() {
	var img = $(this);
	var width = img.width();

	var height = img.height();
	var ratio = width / height;
	var m = 2;
	if (img.hasClass('bigger')) {
		var nw = width / m;
		var nh = (width * ratio) / m;
		img.width(nw);
		img.height(nw);
		img.removeClass('bigger');
	}
	else {
		var nw = width * m;
		var nh = (width * ratio) * m;
		img.width(nw);
	//	img.height(nw);
		img.addClass('bigger');
	}
});

$(document).on('click', '#ticket_request', function() {

	$.ajax({
		url: '/box_office/ticket_request',
		type: 'GET',
		data: { call: 'form' },
		success: function(response) {

			$('#ticket_request_viewer').html(response.content).show();
		}
	});
});

$(document).on('change', '.ticket_request_allocater', function() {
	var privilege = $(this).val();
	var team = $('#ticket_request_team').val();
	var club = $('#ticket_request_club').val();
	var community = $('#ticket_request_community').val();
	$.ajax({
		url: '/box_office/ticket_request',
		type: 'GET',
		data: { call: 'privilege', privilege: privilege, team: team, club: club, community: community },
		success: function(response) {
			$('#ticket_request_role_container').html(response.content).show();
		}
	});
});

// The desk answers while the page stands: the waiting tab asks again every few
// seconds until its ticket is granted, and then walks itself through the gate.
// Thirty minutes of asking is enough for one evening's request.
var ticketRequestTimer;
var ticketRequestChecks = 0;
function ticketRequestCheck() {
	ticketRequestChecks++;
	if (ticketRequestChecks > 450) { clearInterval(ticketRequestTimer); return; }
	var browser_tab_id = sessionStorage.getItem('browser_tab_id') || bti;
	$.ajax({
		url: '/box_office/ticket_request',
		type: 'GET',
		data: { call: 'check', browser_tab_id: browser_tab_id, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (response && response.status == 'approved' && response.url) {
				clearInterval(ticketRequestTimer);
				window.location = response.url;
			}
		}
	});
}

$(document).on('click', '#ticket_request_submit', function() {
	var consent = $('#ticket_request_consent');
	if (consent.length && !consent.prop('checked')) {
		if (!$('.ticket_request_error').length) {
			consent.closest('p').after('<p class="ticket_request_error" style="color:#a00;font-weight:bold;"></p>');
			$('.ticket_request_error').text(jawnosT('home.consent_required'));
		}
		return;
	}
	var form = [];
	var timestamp = Date.now();
	$('.ticket_request_input').each(function(i,v) {
		var name = $(v).attr('name');
		var value = $(v).is('[type=checkbox]') ? ($(v).prop('checked') ? 'on' : 'off') : $(v).val();
		form[name] = value;
	});

	var formData = JSON.stringify(form);
	var browser_tab_id = sessionStorage.getItem('browser_tab_id') || bti;
	$.ajax({
		url: '/box_office/ticket_request',
		type: 'POST',
		data: { call: 'submit', data: formData, timestamp: timestamp, browser_tab_id: browser_tab_id },
		dataType: 'json',
		success: function(response) {
			$('#ticket_request_viewer').html(response.html || '');
			if (response.status == 'approved' && response.url) {
				window.location = response.url;
			}
			else if (response.status == 'pending') {
				clearInterval(ticketRequestTimer);
				ticketRequestTimer = setInterval(ticketRequestCheck, 4000);
			}
		}
	});
});

$(document).on('click', '#ticket_request_cancel', function() {
	clearInterval(ticketRequestTimer);
	$('#ticket_request_viewer').hide();
});
