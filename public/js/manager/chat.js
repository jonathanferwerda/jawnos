// The Chat app. It is the mailbox's conversation sections as an app of its own -
// sms, the dial, the list, ticket threads and lora - so the panel it opens is the
// shared mailbox render scoped to the chat group (see /manager/chat and
// mail_checker), which is why its sidebar carries only those five. The section
// markup moves out into this app's own template in the commits that follow.
$(document).on('click', '#chat_toggle', function () {
	$.ajax({
		url: '/manager/chat',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) {
			windowMaker(response);
			chatBackRestore();
		}
	});
});

// The in-window chat (an appointment window that swapped to the chat) keeps the
// person's name on the window, so a fresh chat render inside it shows the back
// button again - the window still owes that appointment.
function chatBackRestore() {
	var wind = $('.wind[app="chat"]');
	if (wind.attr('appointment')) { wind.find('.chat_back_to_appointment').show(); }
}

// The dropdown rides the person's thread only: the rooms (dial, list, lora)
// are channels of their own, so there is no transport to choose there, and the
// sms option needs the friend's number.
function chatTransportOptions() {
	var onPerson = $('.mail_subsection.active').attr('section') == 'tickets' || $('.mail_subsection.active').attr('section') == 'sms';
	var hasPhone = (localStorage.getItem('mail_phone') || '') != '';
	$('#mail_transport').toggle(!!onPerson);
	$('#mail_transport option[value="sms"]').prop('disabled', !hasPhone);
	if (!hasPhone && $('#mail_transport').val() == 'sms') { $('#mail_transport').val('chat'); }
}
$(document).on('click', '.mail_subsection', function () { setTimeout(chatTransportOptions, 50); });

// A friend opens their one conversation; the dropdown names how the next
// message travels. The thread is the ticket when they hold one, else the phone
// number - only the road taken is sent to the reader, so a ticket-holder's
// thread is their ticket (and the sms history filed under their number re-keys
// onto it) instead of the phone thread shadowing it.
$(document).on('click', '#chat_friends .chat_friend', function () {
	var uuid = $(this).attr('uuid') || '';
	var phone = $(this).attr('phone') || '';
	localStorage.setItem('mail_contact', uuid);
	localStorage.setItem('mail_phone', phone);
	var data = {
		timestamp: Date.now(),
		window_maker: 'yes',
		incoming_data: JSON.stringify({ settings: [{ setting: 'subsection', value: uuid ? 'tickets' : 'sms' }] })
	};
	if (uuid) { data.mail_contact = uuid; }
	else { data.phone = phone; }
	$.ajax({
		url: '/manager/chat',
		type: 'GET',
		data: data,
		success: function (response) {
			windowMaker(response);
			// no ticket: the next message must travel by sms, or it would file on
			// a name that has no ticket thread to read it back from
			if (!uuid) { $('#mail_transport').val('sms'); }
			chatTransportOptions();
			chatBackRestore();
			mailWebSocketStart();
			mailScrollBottom('load');
			mailDotClear();
		}
	});
});

// The Chat button an appointment wears (in its Connect group): the person the
// appointment belongs to is the conversation, so the window itself becomes the
// chat - its contents swap to the chat render for that person, keyed to their
// ticket when one is open in their name, else their phone. The title bar keeps
// the person's name and colour; the back button beside the menu puts the
// appointment back, and opening the person again also brings it back.
$(document).on('click', '.appointment .chat_launcher', function () {
	var wind = $(this).closest('.wind');
	var person = $(this).closest('.appointment').attr('app');
	var uuid = $(this).attr('uuid') || '';
	var phone = $(this).attr('phone') || '';
	localStorage.setItem('mail_contact', uuid);
	localStorage.setItem('mail_phone', phone);
	var data = {
		timestamp: Date.now(),
		window_maker: 'yes',
		// the section is set on the way in, so the sidebar's active button and the
		// transport dropdown agree with the thread the window opens on
		incoming_data: JSON.stringify({ settings: [{ setting: 'subsection', value: uuid ? 'tickets' : 'sms' }] })
	};
	if (uuid) { data.mail_contact = uuid; }
	else { data.phone = phone; }
	$.ajax({
		url: '/manager/chat',
		type: 'GET',
		data: data,
		success: function (response) {
			var contents = $(response).filter('.wind').find('.window_contents').html();
			wind.find('.window_contents').html(contents);
			// the window remembers whose appointment it was, so the back button
			// knows where to return it
			wind.attr('appointment', person);
			wind.attr('app', 'chat');
			wind.find('.chat_back_to_appointment').show();
			// no ticket: the next message must travel by sms, or it would file on a
			// name that has no ticket thread to read it back from
			if (!uuid) { wind.find('#mail_transport').val('sms'); }
			chatTransportOptions();
			textareaUpgrader();
			mailWebSocketStart();
			mailScrollBottom('load');
			mailDotClear();
		}
	});
});

// The in-window chat's back button: the window owes an appointment, and this
// renders it back into the same window - the chat stays where it was, and the
// window is the person's again.
$(document).on('click', '.chat_back_to_appointment', function () {
	var wind = $(this).closest('.wind');
	var person = wind.attr('appointment') || '';
	if (!person) { return; }
	$.ajax({
		url: '/manager/centre_view',
		type: 'GET',
		data: { app: person, source: 'ws', timestamp: Date.now() },
		success: function (response) {
			var contents = $(response).filter('.wind').find('.window_contents').html();
			wind.find('.window_contents').html(contents);
			wind.attr('app', person);
			wind.removeAttr('appointment');
			textareaUpgrader();
			appointment_chron();
		}
	});
});
