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
		success: function (response) { windowMaker(response); }
	});
});

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
// number - either way it is the person's, so the conversation never splits.
$(document).on('click', '#chat_friends .chat_friend', function () {
	var uuid = $(this).attr('uuid') || '';
	var phone = $(this).attr('phone') || '';
	localStorage.setItem('mail_contact', uuid);
	localStorage.setItem('mail_phone', phone);
	if (uuid) {
		settingSetter({ 'app': 'mail', 'setting': 'subsection', 'value': 'tickets' });
	} else if (phone) {
		settingSetter({ 'app': 'mail', 'setting': 'subsection', 'value': 'sms' });
	}
	setTimeout(function () { mailMaker(); }, 50);
});
