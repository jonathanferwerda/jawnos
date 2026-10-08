var mailScroll = { topLoad: 0 };
var emailComposeTimeout;
$(document).on('click', '#mailbox_toggle', function() {
	mailMaker();
});

function mailMaker(incomingData) {
	if (!incomingData) { incomingData = {}; }
	var jData = JSON.stringify(incomingData);
	console.log(jData);
	var url = '/manager/mailbox';
	var timestamp = Date.now();
	var firstMsg = $($('.mailbox_message')[0]);
	if(incomingData['scroll'] == 1) {
		url = '/manager/mail/scroll';
		timestamp = firstMsg.attr('timestamp');
	}

	var picked = localStorage.getItem('mail_picker');
	var contact_uuid = localStorage.getItem('mail_contact');
	var mail_phone = localStorage.getItem('mail_phone');
	var mail_email = localStorage.getItem('mail_email');
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, email: mail_email, phone: mail_phone, mail_contact: contact_uuid, picker: picked, incoming_data: jData },
		success: function(response) {
			if (incomingData['scroll'] != 1) {
				windowMaker(response);
				windowDrawerCloser('mailbox');
				mailWebSocketStart();
				mailScrollBottom('load');
			}
			else {
				var mb = $(response.contents).find('#mailbox');
				var nm = mb.html();
				$('#mailbox').prepend(nm);
				if (response.mail.length == 30) {
					$('#mailbox').scrollTop(firstMsg.position().top + $('#mailbox').height() - firstMsg.height());
				}
			}
			mailScroll = { topLoad: 0 };
			if (localStorage.getItem('mail_sidebar') == 'on' && incomingData['scroll'] != 1) {
				$('#mail_hamburger').trigger('click');
			}
		}, error: function (response) {  }
	});
}

$(document).on('click', '#mail_hamburger', function() {
	var mh = $(this);
	var ml = $('#mail_sidebar');
	var c = $('#conversation');
	var status = 'on';

	if (ml.is(':visible')) {
		ml.hide();
		c.show();
		status = 'off';	
	}
	else {
		ml.show();
		c.hide();
	}
	localStorage.setItem('mail_sidebar', status);
	mailScrollBottom('load');
});



function mail_picker() {
	var picker = {};
	if ($('.mail_picker').is(':visible')) {
		$('.mail_picker').each(function(i,v) {
			picker[$(v).attr('group')] = $(v).val();
		});
		var picked = JSON.stringify(picker);
		localStorage.setItem('mail_picker', picked);
	}
	else if ($('.mail_list_picker').is(':visible')) {
		var uuid = $('.mail_list[chosen="yes"]').attr('uuid');
		$('.mail_list_selection[uuid="' + uuid +'"]').each(function(i,v) {
			picker[$(v).attr('group')] = $(v).attr('sc');
		});
		var picked = JSON.stringify(picker);
		localStorage.setItem('mail_picker', picked);
	}
	else {
		picker = JSON.parse(localStorage.getItem('mail_picker')) || {};
	}
	return picker;
}

$(document).on('click', '#mail_toggle', function() {
	if (!$('#mail').is(':visible')) {
		$(this).css({ 'border': 'solid', 'border-radius': '10px', 'border-color':'red' });
		var timestamp = Date.now();
		var picked = JSON.stringify(mail_picker());
		var cx_uuid = $(this).attr('cx_uuid');
		$.ajax({
			url: '/mail/homepage_form',
			type: 'GET',
			data: {
				timestamp: timestamp, picker: picked, mail_contact: cx_uuid
			},
			success: function(response) {
				$('#mail').html(response).show();
				mailWebSocketStart();
				$('#mail_toggle').css({ 'border': 'none' });
				$('.mail_contact_input').each(function(i,v) {
					var setting = $(v).attr('id');
					var value = localStorage.getItem(setting);
					$(this).val(value);
				});
			}
		});
	}
	else {
		$('#mail').hide();
	}
});


$(document).on('change', '.mail_contact_input', function() {
	var input = $(this);
	var setting = input.attr('id');
	var value = input.val();
	localStorage.setItem(setting,value);
});

$(document).on('click', '.email_config_toggle', function() {
	var app = $(this).closest('.wind').attr('app');
	$.ajax({
		url: '/manager/mail/email/configure',
		type: 'GET',
		data: {},
		success: function(response) {
			windowDrawerOpener(app, response.html);
		}
	});
});

$(document).on('click', '.email_config_server_add', function() {
	var app = $(this).closest('.wind').attr('app');
	$.ajax({
		url: '/manager/mail/email/server/add',
		type: 'POST',
		success: function(response) {
			windowDrawerOpener(app, response.html);
		}
	});
});

$(document).on('click', '.email_config_server_delete', function() {
	var a = $(this);
	var uuid = a.attr('uuid');

	var armed = a.attr('armed');
	if (armed == 'yes') {
		$.ajax({
			url: '/manager/mail/email/server/delete',
			type: 'POST',
			data: { uuid: uuid },
			success: function(response) {
				$('.email_server_config[uuid="' + uuid + '"]').remove();
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

$(document).on('click', '.email_config_template_delete', function() {
	var a = $(this);
	var app = a.closest('.wind').attr('app');
	var uuid = a.attr('uuid');
	if (armed == 'yes') {
		$.ajax({
			url: '/manager/mail/email/template/delete',
			type: 'POST',
			data: { uuid: uuid },
			success: function(response) {
				windowDrawerOpener(app, response.html);
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

$(document).on('click','.email_config_folder_view_toggle', function() {
	var uuid = $(this).attr('uuid');
	var folders = $('.email_config_folder_view[uuid="' + uuid + '"]');
	if (folders.is(':visible')) {
		folders.hide();
	}
	else {
		folders.show();
	}
});

$(document).on('change', '.email_server_setting', function() {
	var set = $(this);
	var setting = set.attr('setting');
	var value = set.val();
	if (set.attr('type') == 'checkbox') {
		if (set.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}
	var uuid = set.attr('uuid');
	var subsetting = set.attr('subsetting');
	var folder = set.attr('folder');
	$.ajax({
		url: '/manager/mail/email/configure',
		type: 'POST',
		data: { setting: setting, subsetting: subsetting, folder: folder, value: value, uuid: uuid },
		success: function(response) {
			$('.email_server_setting[uuid="' + uuid + '"], .email_server_settings[uuid="' + uuid + '"]').each(function(i,v) {
				set.attr('uuid', response.uuid);
			});
		}
	});
});

$(document).on('click', '.email_config_screen_toggle', function() {
	var screen = $(this).attr('screen');
	var app = $(this).closest('.wind').attr('app');
	$.ajax({
		url: '/manager/mail/email/configure',
		type: 'GET',
		data: { screen: screen },
		success: function(response) {
			windowDrawerOpener(app, response.html);
		}
	});
});

$(document).on('change', '.email_template_config_select', function() {
	var template = $(this).val();
	var app = $(this).closest('.wind').attr('app');
	$.ajax({
		url: '/manager/mail/email/configure',
		type: 'GET',
		data: { template: template },
		success: function(response) {
			windowDrawerOpener(app, response.html);
		}
	});
});

$(document).on('click', '.email_template_save', function() {
	var app = $(this).closest('.wind').attr('app');
	var etc = $(this).closest('.email_template_configuration');
	var uuid = etc.find('.email_template_config_select').val();
	var name = etc.find('.email_template_field[field="name"]').val();
	var purpose = etc.find('.email_template_field[field="purpose"]').val();
	var body = etc.find('.email_template_field[field="body"]').html();
	var subject = etc.find('.email_template_field[field="subject"]').val();
	var data = {
		uuid: uuid,
		name: name,
		subject: subject,
		body: body,
		purpose: purpose
	};
	$.ajax({
		url: '/manager/mail/email/template/save',
		type: 'POST',
		data: data,
		success: function(response) {
			windowDrawerOpener(app, response.html);
		}
	});
});

$(document).on('change', '.email_template_select', function() {
	var uuid = $(this).val();
	var form = $(this).closest('.email_compose_form');
	$.ajax({
		url: '/manager/mail/email/template',
		type: 'GET',
		data: { uuid: uuid },
		success: function(response) {
			$.each(response, function(i,v) {
				var input = form.find('.email_compose_' + i );
				input.val(v).trigger('change');
				if (input.hasClass('text_editor')) {
					input.html(v).trigger('change');
				}
			});
			// a template is full of names waiting for a document, and this
			// compose knows one: the words become what it says
			var body = form.find('.email_compose_body.text_editor');
			if (body.length && body.attr('magic_vars')) {
				textEditorMagic(body, true);
			}


		}
	});
});

$(document).on('click', '.email_message', function(e) {
	if (!$(e.target).hasClass('email_deleter')) {
		var uuid = $(this).attr('uuid');
		var app = $(this).closest('.wind').attr('app');
		$.ajax({
			url: '/manager/mail/email/read',
			type: 'GET',
			data: { uuid: uuid },
			success: function(response) {
				windowDrawerOpener(app, response.html);
			}
		});
	}
});

$(document).on('click', '#email_receive', function() {
	var b = $(this);
	var button_text = b.text();
	b.text('* ' + button_text);
	$.ajax({
		url: '/manager/mail/email/receive',
		type: 'GET',
		data: {},
		success: function(response) {
			b.text(button_text);
			$('#email_configure').replaceWith(response.html);
		}
	});
});

$(document).on('click', '#email_compose', function() {

	var ec = $(this);
	var app = $(this).closest('.wind').attr('app');
	emailCompose(app);
});

$(document).on('click', '.email_draft_change', function() {
	var app = $(this).closest('.wind').attr('app');
	var direction = $(this).attr('direction');
	emailCompose(app);
});

function emailCompose(app,draft_selection) {
	var email = localStorage.getItem('mail_email');
	$.ajax({
		url: '/manager/mail/email/compose',
		type: 'GET',
		data: { email: email, app: app, draft_selection: draft_selection },
		success: function(response) {
			windowDrawerOpener(app, response.html);
		}
	});
}

$(document).on('click', '.email_discard', function() {
	var dis = $(this);
	var uuid = dis.closest('.email_compose_form').attr('uuid');
	if (uuid) {
		mailDeleteMessage(uuid);
	}
	windowDrawerCloser('mailbox');
});

function mailDeleteMessage(uuid) {
	if (uuid) {
		var msg = { uuid: uuid };
		var m = JSON.stringify({ msg: msg, timestamp:timestamp, type: 'delete' });
		mailws.send(m);
	}
}

$(document).on('keyup, change', '.email_compose_input', function() {
	var input = $(this);
	var app = $(this).closest('.wind').attr('app');
	var form = input.closest('.email_compose_form');
	clearTimeout(emailComposeTimeout);
	emailComposeTimeout = setTimeout(function() {
		var browser_tab_id = sessionStorage.getItem('browser_tab_id') || bti;
		var timestamp = Date.now();
		var uuid = input.closest('.email_compose_form').attr('uuid');
		var message = {
			from: '',
			to: '',
			subject: '',
			body: '',
			timestamp: '',
			sender: ''
		};
		$.each(message, function(i,v) {
			var input = form.find('.email_compose_' + i);
			message[i] = input.val();
			if (input.hasClass('text_editor')) {
				message[i] = input.html()
				input.trigger('change');
			}
			if (input.hasClass('time')) {
				message[i] = input.attr('timestamp');
			}
		});

		var attachments = [];
		form.find('.email_attachment_data').each(function(i,v) {
			var jdata = $(v).text();
			var data = JSON.parse(jdata);
			delete data['html'];
			attachments.push(data);
		});
		message['attachments'] = attachments;
		message['uuid'] = uuid;
		message['app'] = app;
		var m = JSON.stringify({ msg: message, timestamp:timestamp, type: 'compose' });
		$.ajax({
			url: '/manager/mail/email/draft',
			type: 'POST',
			data: { m: m },
			success: function(response) {
			}
		});
	}, 400);
});

$(document).on('click', '.delete_email_attachment', function() {
	var b = $(this);
	var uuid = b.attr('uuid');

	var armed = b.attr('armed');
	if (armed == 'yes') {
		b.addClass('superactive');
		$('.email_attachment[uuid="' + uuid + '"]').remove();
		$('.email_compose_input').trigger('keyup');
		$('.email_attachment_embed[uuid="' + uuid + '"]').remove();
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


var emailAttachmentAdder = {};
$(document).on('click', '.email_attachment_toggle', function() {
	var et = $(this);
	var form = et.closest('.email_compose_form');
	var d = form.find('.email_attachment_dialog');
	var app = et.closest('.wind').attr('app');
	if (!emailAttachmentAdder[app]) {
		emailAttachmentAdder[app] = {};
	}
	var selected = et.hasClass('selected');

	if (selected) {
		et.removeClass('selected');
		clearInterval(emailAttachmentAdder[app]['interval']);
		d.html('').hide();
	} else {
		et.addClass('selected');
//	emailAttachmentAdder[app]['interval'] = setInterval(function() {
		var attachable = [];
		$('[src*="/file_open?"],[src*="/play?"]').each(function(i,v) {
			var tag = $(v).prop('tagName').toLowerCase();
			var app = $(v).attr('app');
			attachable.push({ type: tag, src: $(v).attr('src'), app: app });
		});
		if ($('.wind[app="music"]').length > 0) {
			$.each(tree.all_songs,function(i,v) {
				attachable.push({ type: 'file', src: '/file_open?file=' + v.file });
			});
		}

		$.each(attachable, function(i,v) {
			var html = '';
			if (v['type'] == 'img') {
				html = '<img src="' + v['src'] + '" file="' + v['src'] + '" type="' + v['type'] + '" app="' + v['app'] + '" class="gigantic_thumb email_attachment_potential">';
			}
			else {
				html = '<img src="/images/decipherable/file.png" file="' + v['src'] + '" type="file" app="' + v['app'] + '"class="gigantic_thumb email_attachment_potential">'
			}
			d.append(html);
		});
		d.show();
//	},1000);
	}
});

$(document).on('click', '.email_attachment_potential', function() {
	var b = $(this);
	var form = b.closest('.email_compose_form');
	var src = b.attr('file');
	var app = b.attr('app');
	var type = b.attr('type');
	$.ajax({
		url: '/manager/mail/email/attachment_preparer',
		type: 'GET',
		data: { src: src, app: app, type: type },
		success: function(response) {
			if (form.find('.email_attachment[uuid="' + response.uuid + '"]').length == 0) {
				form.find('.email_attachments').append(response.html);
			}
		}
	});


});

$(document).on('click', '.email_send', function() {
	var form = $(this).closest('.email_compose_form');
	var app = $(this).closest('.wind').attr('app');
	if (form.attr('sending') != 'sending') {
		form.attr('sending', 'sending');
		form.css({
			'pointer-events': 'none',
			'opacity': '0.5',
			'filter': 'grayscale(1)'
		});
		var message = {
			from: '',
			to: '',
			subject: '',
			body: '',
			timestamp: Date.now(),
			sender: ''
		};
		$.each(message, function(i,v) {
			var input = form.find('.email_compose_' + i);
			message[i] = input.val();
			if (input.hasClass('text_editor')) {
				message[i] = input.html();
			}
			if (input.hasClass('time')) {
				message[i] = input.attr('timestamp');
			}
		});


		var attachments = [];
		form.find('.email_attachment_data').each(function(i,v) {
			var jdata = $(v).text();
			var data = JSON.parse(jdata);
			attachments.push(data);
		});
		message['attachments'] = JSON.stringify(attachments);
		message['uuid'] = form.attr('uuid');
		$.ajax({
			url: '/manager/mail/email/send',
			type: 'POST',
			data: message,
			success: function(response) {
				form.css({
					'pointer-events': 'auto',
					'opacity': '1',
					'filter': 'grayscale(0)'
				});
				if (response == 'success') {
					windowDrawerCloser(app);
				}
			}
		});

		console.log(message);
	}

});

$(document).on('click', '#send_it', function() {
	sendIt();
});

$(document).on('keyup', '#message', function(e) {
	if (e.keyCode == 13) {
		sendIt();
	}
});

$(document).on('click', '.mailbox_message', function(e) {
	var b = $(this);
	var armed = b.attr('armed');
	if (e.ctrlKey == true || b.attr('armed')) {
	 mailDeleteMessageArmer(b)
	}
});

$(document).on('click', '.email_deleter', function() {
	var b = $(this);
	var armed = b.attr('armed');
	if (armed == 'yes') {
		b.addClass('superactive');
		var uuid = b.attr('uuid');
		mailDeleteMessage(uuid);
	}
	else {
		b.attr('armed', 'yes');

		var bgcolor = b.css('background-color');
		b.attr('obg', bgcolor);
		b.css({'background-color': 'red' }); 

		setTimeout(function() {
			b.css({'background-color': b.attr('obg') });
			b.attr('armed', 'no');			
		},2000);
	}
	
});

$(document).on('dblclick', '.mailbox_message', function(e) {
	var b = $(this);
	mailDeleteMessageArmer(b);
});

function mailDeleteMessageArmer(b) {
	var armed = b.attr('armed');
	if (armed == 'yes') {
		b.addClass('superactive');
		var uuid = b.attr('uuid');
		mailDeleteMessage(uuid);
	}
	else {
		b.attr('armed', 'yes');
		b.find('span').each(function(i,v) { 
			var bgcolor = $(v).css('background-color');
			$(v).attr('obg', bgcolor);
			$(v).css({'background-color': 'red' }); 
		});
		setTimeout(function() {
			b.find('span').each(function(i,v) { $(v).css({'background-color': $(v).attr('obg') }); });
			b.attr('armed', 'no');			
		},2000);
	}
}

function sendIt() {
	var timestamp = Date.now();
	var msg = $('#message').val();
	var project = $('#mail_project_picker').val() || 'general';
	var picked = JSON.stringify(mail_picker());

	localStorage.getItem('mail_name');
	var mail_contact;
	var phone;
	var email;
	var conversation_uuid;
	if ($('.mail_subsection.active').attr('section') == 'pen') {
		mail_contact = 'pen';
		conversation_uuid = $('.chatbot_configure.selected').attr('uuid');
		picked = {};
	}
	else if ($('.mail_subsection.active').attr('section') == 'sms') {
		phone = localStorage.getItem('mail_phone');
		picked = {};
		mail_contact = undefined;
	}
	else if ($('.mail_subsection.active').attr('section') == 'email') {
		email = localStorage.getItem('mail_email');
		picked = {};
		mail_contact = undefined;
	}
	else if ( $('.mail_subsection.active').attr('section') == 'tickets' ) {
		mail_contact = localStorage.getItem('mail_contact');
		picked = {};
		
	}
	var browser_tab_id = sessionStorage.getItem('browser_tab_id') || bti;
	var m = JSON.stringify({ 
		msg: msg,
		mail_contact: mail_contact,
		phone: phone,
		email: email,
		browser_tab_id: browser_tab_id,
		timestamp:timestamp,
		type: 'message',
		picker: picked,
		conversation_uuid: conversation_uuid
	});
	mailws.send(m);
	$('#message').val('');
	$('#message').trigger('click');

}

var mailws = undefined;
var mailwsInterval;
var last_mail_message = '';

function mailWebSocketStart() {

	var timestamp = Date.now();
	if (typeof mailws == 'object') {
		if (mailws.readyState == 1) {
			return true;
		}
	}
	if (typeof mailws == 'object') {
		if (mailws.readyState != 1) {
			mailWebSocketStop();
		}
	}

	clearInterval(mailwsInterval);
	var browser_tab_id = sessionStorage.getItem('browser_tab_id') || bti;
	var browser_tab = localStorage.getItem('browser_tab') || bt;
	var picked = JSON.stringify(mail_picker());
	var mail_contact = localStorage.getItem('mail_contact');
	var phone;
	if ($('.mail_subsection.active').attr('section') == 'sms') {
		phone = localStorage.getItem('mail_phone');
	}
	var email;
	if ($('.mail_subsection.active').attr('section') == 'email') {
		email = localStorage.getItem('mail_email');
	}
	mailws = new WebSocket(mail_ws_url + '?timestamp=' + timestamp + '&browser_tab=' + browser_tab + '&browser_tab_id=' + browser_tab_id + '&picker=' + picked + '&mail_contact=' + mail_contact + '&phone=' + phone + '&email=' + email);
	console.log('ws+() mail at ' + mail_ws_url + ' ' + mail_contact);
	mailws.onopen = function (event) {
		var sender = JSON.stringify({ type: 'refresher', 'last_message': last_mail_message });
		mailws.send(sender);
		mailwsInterval = setInterval(function() {
			if (mailws.readyState != 1) {
				mailWebSocketStop();
			}
			else {

				var decrypteds = [];
				$('.mailbox_message[decrypted="no"]').each(function(i,v) {
					decrypteds.push($(v).attr('uuid'));
				});

				var sender = JSON.stringify({ 'type': 'heartbeat', 'decrypteds': decrypteds });
				mailws.send(sender);
			}
		},2000);
	};
	mailws.onmessage = function (event) {
		var data = JSON.parse(event.data);
		if (data.type == 'message') {
			var data = JSON.parse(event.data);
			$('#mailbox').append(data.envelope);
			mailScrollBottom();
			last_mail_message = Date.now();
			appointment_chron();
		}
		else if (data.type == 'refresher') {
			$.each(data.messages, function(i,v) {
				$('#mailbox').append(data.envelope);
				mailScrollBottom();
			});
			appointment_chron();
		}
		else if (data.type == 'writing') {
			console.log(data);
			
			if (data['mail_contact'] == 'assistant') {
				$('.assistant_content[uuid="' + data.uuid + '"]').html(data.all_text);
			} else {
				$('.mailbox_message_contents[uuid="' + data.uuid + '"]').html(data.all_text);
				mailScrollBottom();
			}
		}

	};
	mailws.onclose = function (event) {

	}
}

function mailWebSocketStop() {
	if ( mailws ) { mailws.close(); mailws = undefined;	delete mailws; };
		mailWebSocketStart();
}


function mailScrollBottom(type) {
	var lastMsg =	$($('.mailbox_message')[$('.mailbox_message').length - 1]);
	var firstMsg = $($('.mailbox_message')[0]);
	var currentScroll = $('#mailbox').scrollTop();
	if ($('#mailbox').is(':visible') && $('.mailbox_message').length > 0) {
		if (($('#mailbox').height() - lastMsg.position().top) >= -5 || type == 'load') {
			$('#mailbox').scrollTop(lastMsg.position().top + lastMsg.height() + $('#mailbox').scrollTop() + 40000);
		}
	}
}

$(document).on('mousewheel touchmove scroll', '#mailbox', function() {
	var lastMsg =	$($('.mailbox_message')[$('.mailbox_message').length - 1]);
	var firstMsg = $($('.mailbox_message')[0]);
	
	if (firstMsg.position().top > -1 && firstMsg.position().top < 0.1 && mailScroll['topLoad'] == 0) {
		mailScroll['topLoad'] = 1;
		mailMaker({ 'scroll': 1, 'firstTime': firstMsg.attr('timestamp') });
	}
});

$(document).on('click', '.mail_contact', function() {
	var timestamp = Date.now();
	var uuid;
	uuid = $(this).attr('uuid');
	localStorage.setItem('mail_contact', uuid);
	localStorage.removeItem('mail_phone');

	var name = $(this).attr('name');
	var contact_name = $(this).attr('contact_name');

	var picked = JSON.stringify(mail_picker());
	$.ajax({
		url: '/manager/mail/contact',
		type: 'GET',
		data: { timestamp: timestamp, mail_contact: uuid, name: name, uuid: uuid, picker: picked },
		success: function(response) {
			windowMaker(response.html);
			mailWebSocketStop();	
			$('.mail_contact[uuid="' + uuid + '"]').addClass('active');
			mailScrollBottom('load');
		}
	});
});

$(document).on('click', '.mail_phone', function() {
	var timestamp = Date.now();
	var phone = $(this).attr('phone');
	$.ajax({
		url: '/manager/mail/phone',
		type: 'GET',
		data: { phone: phone, timestamp: timestamp },
		success: function(response) {
			windowMaker(response.html);
			localStorage.setItem('mail_phone', phone);
			mailScrollBottom('load');
			mailScroll = { topLoad: 0 };
			mailWebSocketStop();
		}
	});
});

$(document).on('click', '.mail_email', function() {
	var timestamp = Date.now();
	var email = $(this).attr('email');
	$.ajax({
		url: '/manager/mail/email',
		type: 'GET',
		data: { email: email, timestamp: timestamp },
		success: function(response) {
			windowMaker(response.html);
			localStorage.removeItem('mail_phone');
			localStorage.setItem('mail_email', email);
			mailScrollBottom('load');
			mailScroll = { topLoad: 0 };
			mailWebSocketStop();
		}
	});
});

$(document).on('change', '.mail_picker', function() {
	var picker = $(this);
	var val = picker.val();
	var group = picker.attr('group');
	localStorage.removeItem('mail_contact');
	localStorage.removeItem('mail_phone');
	var picked = JSON.stringify(mail_picker());
	$('.mail_contact.active').removeClass('active');
	var timestamp = Date.now();
	var idata = { 'sidebar': 1 };
	var jData = JSON.stringify(idata);
	$.ajax({
		url: '/manager/mail/picker',
		type: 'GET',
		data: { timestamp: timestamp, picker: picked, incoming_data: jData },
		success: function(response) {
			windowMaker(response.html);
			mailWebSocketStop();
			mailScrollBottom('load');
		}
	});
});

$(document).on('click', '#mail_picker_default', function() {
	var lastV;
	$('.mail_picker').each(function(i,v) {
		var value = $(v).find('option[default="yes"]').attr('value');
		$(v).val(value);
		lastV = $(v);
	});
	lastV.trigger('change');
});

$(document).on('dblclick', '#mailbox', function() {
	mailScrollBottom('load');
})

$(document).on('click', '.mail_subsection', function() {
	var section = $(this).attr('section');

	if (section == 'pen') {
		localStorage.setItem('mail_contact', 'pen');
	}
	var sidebar = 0;
	if (section == 'pen') { sidebar = 1; }
	mailMaker({ 'sidebar': sidebar, settings: [{ 'setting': 'subsection', 'value': section }] });

});

$(document).on('click', '.mail_list', function(e) {
	if ($(e.target).hasClass('mail_config_toggle')) {
		return;
	}
	var l = $(this);
	var uuid = l.attr('uuid');
	settingSetter({ 'app': 'mail', 'setting': 'mail_list', 'value': uuid });
	l.attr('chosen', 'yes');
	setTimeout(function() {
		var picked = JSON.stringify(mail_picker());
		var timestamp = Date.now();
		$('.mail_list.active').removeClass('active');
		$.ajax({
			url: '/manager/mail/picker',
			type: 'GET',
			data: { timestamp: timestamp, picker: picked },
			success: function(response) {
				windowMaker(response.html);
				$('.mail_list[uuid="' + uuid + '"]').addClass('active');

				mailWebSocketStop();
				mailScrollBottom('load');
			}
		});
	},250);
});

$(document).on('click', '.mail_config_toggle', function() {
	var uuid = $(this).attr('uuid');
	var container = $('.mail_config_container[uuid="' + uuid + '"]');
	if (!container.parent().is(':visible')) {
		$.ajax({
			url: '/manager/mail/config',
			type: 'GET',
			data: { uuid: uuid },
			success: function(response) {
				container.html(response.html)
				container.parent().show();

			}
		});
	}
	else {
		container.parent().hide();
	}
});

$(document).on('change', '.mail_config', function() {
	var value = $(this).val();
	var setting = $(this).attr('setting');
	var uuid = $(this).closest('.mail_config_container').attr('uuid');

	if ($(this).attr('type') == 'checkbox') {
		value = $(this).prop('checked');
	}



	$.ajax({
		url: '/manager/mail/config',
		type: 'POST',
		data: { setting: setting, value: value, uuid: uuid },
		success: function(response) {
			$.ajax({
				url: '/manager/mail/picker',
				type: 'GET',
				data: { timestamp: timestamp,  },
				success: function(response) {
					windowMaker(response.html);
					$('.mail_list[uuid="' + uuid + '"]').addClass('active');
					var container = $('.mail_config_container[uuid="' + uuid + '"]');
					mailWebSocketStop();
					$.ajax({
						url: '/manager/mail/config',
						type: 'GET',
						data: { uuid: uuid },
						success: function(response) {
							container.html(response.html)
							container.parent().show();

						}
					});
				}
			});
		}
	});
});

$(document).on('click', '.mail_qr_generator', function() {
	var uuid = $(this).attr('uuid');
	$.ajax({
		url: '/manager/mail/qr_generator',
		type: 'GET',
		data: { uuid: uuid },
		success: function(response) {
			$('.mail_qr[uuid="' + uuid + '"]').attr('src', response.qr_image).show();
		}
	});
});

$(document).on('change', '.pen_settings', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var configure = $(this).closest('.chatbot_configure');
	var uuid = configure.attr('uuid');

	console.log(uuid);

	var data = JSON.parse($('#pen_chatbot_data').text());

	if (!data[uuid]) { data[uuid] = {}; }
	data[uuid][setting] = value;
	console.log(data);
	var jdata = JSON.stringify(data);
	mailMaker({ settings: [{'setting': 'chatbot_conversations', value: jdata }, { 'setting': setting, 'value': value }] });
});

$(document).on('change', '.chatbot_conversation_select', function() {
	var configure = $(this).closest('.chatbot_configure');
	var uuid = configure.attr('uuid');
	mailMaker({ settings: [{'setting': 'chatbot_conversation', value: uuid }] });
});

$(document).on('click', '.chatbot_conversation_delete', function() {
	var configure = $(this).closest('.chatbot_configure');
	var uuid = configure.attr('uuid');
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		a.attr('armed','no');
		var obg = a.attr('obg');
		a.css({'background-color': obg});
		var data = JSON.parse($('#pen_chatbot_data').text());
		if (!data[uuid]) { data[uuid] = {}; }
		delete data[uuid];
		console.log(data);
		var jdata = JSON.stringify(data);
		$.ajax({
			url: '/manager/mail/delete_conversation',
			type: 'POST',
			data: { conversation_uuid: uuid },
			success: function(response) {
				mailMaker({ settings: [{'setting': 'chatbot_conversations', value: jdata }] });
			}
		});
	}
	else {
		var obg = a.css('background-color');
		a.attr('obg', obg);
		a.css({'background-color': 'red'});
		a.attr('armed', 'yes');

		setTimeout(function() {
			var bgcolor = a.attr('obg');
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});



$(document).on('click', '#mailbox_audio', function() {
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		jpStop(undefined,'audio');
		a.attr('armed','no');
		var obg = a.attr('obg');
		a.css({'background-color': obg});
	}
	else {
		jpStart(undefined,'audio');
		a.attr('armed','yes');
		var obg = a.css('background-color');
		a.attr('obg', obg);
		a.css({'background-color': 'red'});
	}
});

$(document).on('click', '#mailbox_video', function() {
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		jpStop(undefined,'video');
		a.attr('armed','no');
		var obg = a.attr('obg');
		a.css({'background-color': obg});
	}
	else {
		jpStart(undefined,'video');
		a.attr('armed','yes');
		var obg = a.css('background-color');
		a.attr('obg', obg);
		a.css({'background-color': 'red'});
	}
});

$(document).on('click', '#mailbox_screen', function() {
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		jpStop(undefined,'screen');
		a.attr('armed', 'no');
		var obg = a.attr('obg');
		a.css({'background-color': obg});
	}
	else {
		jpScreen(undefined,'video');
		a.attr('armed','yes');
		var obg = a.css('background-color');
		a.attr('obg', obg);
		a.css({ 'background-color': 'red' });
	}
});


document.addEventListener("visibilitychange", function(e) { 
	if (e.returnValue == true) {
		mailWebSocketStart();
	}
});

$(document).on('click', '#mailbox_lora_toggle', function() {
	var toggled = $(this).attr('toggle');
	if (toggled == 'on') {
		toggled = 'off';
	}
	else {
		toggled = 'on';
	}
	$(this).attr('toggle', toggled);
	settingSetter({ 'app': 'mail', 'setting': 'lora_toggle', 'value': toggled });
});

$(document).on('click', '.delete_mail_conversation', function() {
	var uuid = $(this).attr('uuid');
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/mail/delete_conversation',
			type: 'POST',
			data: { uuid: uuid },
			success: function(response) {
				console.log(response);
				$('.mail_list[uuid="' + uuid + '"]').remove();
				$('.mail_config_container[uuid="' + uuid + '"]').remove();
			}
		});
	}
	else {
		a.attr('armed','yes');
		var obg = a.css('background-color');
		a.attr('obg', obg);
		a.css({ 'background-color': 'red' });
		setTimeout(function() {
			var bgcolor = a.attr('obg');
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}



});
