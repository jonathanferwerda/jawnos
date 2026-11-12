/* [[js-split]]
   chat.js is part 1. The rest live in chat/ in name order:
     01_lorawan.js - LoRaWAN settings, message dressing, auto-scroll pinning, the rail menu
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
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
			// The start-menu icon opens the panel directly, so it must also start
			// the mail socket (which decrypts the bodies) and dress the thread the
			// same way the friend picker does.
			if (typeof chatDressMessages === 'function') { chatDressMessages(); }
			if (typeof mailWebSocketStart === 'function') { mailWebSocketStart(); }
			if (typeof chatTransportOptions === 'function') { chatTransportOptions(); }
			if (typeof mailScrollBottom === 'function') { mailScrollBottom('load'); }
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
// sms option needs the friend's number. A person may keep more than one line, so
// the server renders sms once per number; the first is their primary number and
// is the road until another is picked.
function chatTransportOptions() {
	var sel = $('#mail_transport');
	var section = $('.mail_subsection.active').attr('section') || '';
	var onPerson = section == 'tickets' || section == 'sms';
	var onLora = section == 'lora';
	var hasPhone = (localStorage.getItem('mail_phone') || '') != '' || sel.find('option[value="sms"]').filter(function () { return (($(this).attr('data-line') || '') != ''); }).length > 0;
	// LoRa is a road only on the LoRa section; a person's thread offers chat and
	// their phone lines, so a text never quietly becomes a radio broadcast.
	sel.find('option[value="lora"]').toggle(onLora);
	sel.toggle(onPerson || onLora);
	if (onLora) {
		sel.val('lora');
	}
	else if (sel.val() == 'lora') {
		sel.val('chat');
	}
	// A person's road is remembered: once sms is picked it is how the thread
	// opens again, until another road is chosen. The thread stays the person's
	// (a ticket-holder keeps their ticket thread) - only the road changes.
	var remembered = onPerson ? chatRememberedMethod() : '';
	if (remembered == 'sms' && !hasPhone) { remembered = ''; }
	if (remembered && sel.find('option[value="' + remembered + '"]').length) { sel.val(remembered); }
	if (sel.val() == 'sms') {
		var first = sel.find('option[value="sms"]').first();
		if (first.length) { sel.find('option').prop('selected', false); first.prop('selected', true); }
	}
	sel.find('option[value="sms"]').prop('disabled', !hasPhone);
	if (!hasPhone && sel.val() == 'sms') { sel.val('chat'); }
	updateChatSmsCount();
	chatMethodLabel(sel, onPerson);
	if (onLora) { setTimeout(chatLoraRefresh, 200); }
}

// The transport belongs to the person, not the window: a phone number is the
// most stable key across the friend row, the ticket and the phone list, with the
// ticket's uuid as the fallback for someone who keeps no number here.
function chatMethodKey() {
	var phone = localStorage.getItem('mail_phone') || '';
	var contact = localStorage.getItem('mail_contact') || '';
	if (phone) { return 'phone:' + phone; }
	if (contact && contact != 'pen' && contact != 'lora') { return 'contact:' + contact; }
	return '';
}

function chatRememberedMethod() {
	var phone = localStorage.getItem('mail_phone') || '';
	var contact = localStorage.getItem('mail_contact') || '';
	if (phone) {
		var by_phone = localStorage.getItem('chat_method_phone:' + phone);
		if (by_phone) { return by_phone; }
	}
	if (contact && contact != 'pen' && contact != 'lora') {
		return localStorage.getItem('chat_method_contact:' + contact) || '';
	}
	return '';
}

function chatRememberMethod(value) {
	if (!value) { return; }
	var phone = localStorage.getItem('mail_phone') || '';
	var contact = localStorage.getItem('mail_contact') || '';
	// the chosen sms line can name the person even when the ticket, not a phone
	// row, opened the thread
	var line = $('#mail_transport option[value="sms"]:selected').attr('data-line') || '';
	if (phone) { localStorage.setItem('chat_method_phone:' + phone, value); }
	if (line) { localStorage.setItem('chat_method_phone:' + line, value); }
	if (contact && contact != 'pen' && contact != 'lora') { localStorage.setItem('chat_method_contact:' + contact, value); }
}

// The subtitle under the name names the road the next message will take - the
// number when it is sms, rather than the section's own name (it used to say
// "Tickets" even when the next text was going by phone).
function chatMethodLabel(sel, onPerson) {
	var label = $('#chat_method_label');
	if (!label.length) { return; }
	var fallback = label.attr('data-label') || label.text();
	var text = fallback;
	if (onPerson && chatMethodKey() && sel && sel.length && sel.is(':visible')) {
		var value = sel.val() || '';
		if (value == 'sms') {
			var line = sel.find('option[value="sms"]:selected').attr('data-line') || localStorage.getItem('mail_phone') || '';
			text = line || sel.find('option[value="sms"]').first().text() || fallback;
		}
		else {
			text = sel.find('option[value="' + value + '"]').text() || fallback;
		}
	}
	label.text(text);
}
$(document).on('click', '.mail_subsection', function () {
	// the old section's place in the rail is saved before the render replaces it
	if (typeof chatScrollSave === 'function') { chatScrollSave(); }
	setTimeout(chatTransportOptions, 50);
});

// A friend - or a recent conversation, which is the same thing with its last
// words under the name - opens their one conversation; the dropdown names how
// the next message travels. The thread is the ticket when they hold one, else
// the phone number - only the road taken is sent to the reader, so a
// ticket-holder's thread is their ticket (and the sms history filed under their
// number re-keys onto it) instead of the phone thread shadowing it. A LoRa row
// opens the LoRa section, which has no phone or ticket of its own.
$(document).on('click', '.chat_shell .chat_friend', function () {
	var uuid = $(this).attr('uuid') || '';
	var phone = $(this).attr('phone') || '';
	var section = $(this).attr('data-section') || (uuid ? 'tickets' : 'sms');
	chatScrollSave();
	chatRailAutoClose();
	localStorage.setItem('mail_contact', uuid);
	localStorage.setItem('mail_phone', phone);
	var data = {
		timestamp: Date.now(),
		window_maker: 'yes',
		incoming_data: JSON.stringify({ settings: [{ setting: 'subsection', value: section }] })
	};
	if (uuid) { data.mail_contact = uuid; }
	else if (phone) { data.phone = phone; }
	$.ajax({
		url: '/manager/chat',
		type: 'GET',
		data: data,
		success: function (response) {
			windowMaker(response);
			chatDressMessages();
			// no ticket: the next message must travel by sms, or it would file on
			// a name that has no ticket thread to read it back from
			if (!uuid && section == 'sms') { $('#mail_transport').val('sms'); }
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

// ---- SMS character counter ------------------------------------------------
// SmsManager.divideMessage() already splits a unicode body correctly; the
// counter just tells the person which alphabet it will use. Unicode bodies
// (emoji, CJK, accented text) are 70 UTF-16 units per segment on most networks,
// GSM-7 bodies 160.
function updateChatSmsCount() {
	var box = $('#chat_sms_count');
	if (!box.length) { return; }
	var msg = $('#message').val() || '';
	var section = $('.mail_subsection.active').attr('section') || '';
	var transport = ($('#mail_transport').length && $('#mail_transport').is(':visible')) ? $('#mail_transport').val() : '';
	if (!msg.length || (transport != 'sms' && section != 'sms')) { box.text(''); return; }
	var unicode = /[^\x00-\x7F]/.test(msg);
	var units = unicode ? msg.length : Array.from(msg).length;
	var per = unicode ? 70 : 160;
	var segments = Math.max(1, Math.ceil(units / per));
	box.text((unicode ? 'Unicode' : 'GSM') + ' · ' + units + '/' + (per * segments) + ' · ' + segments + ' SMS');
}

// ---- emoji -----------------------------------------------------------------
function chatInsertEmoji(emoji) {
	var ta = document.getElementById('message');
	if (!ta) { return; }
	var start = ta.selectionStart || 0;
	var end = ta.selectionEnd || 0;
	ta.value = ta.value.slice(0, start) + emoji + ta.value.slice(end);
	ta.selectionStart = ta.selectionEnd = start + emoji.length;
	ta.focus();
	$(ta).trigger('input');
	updateChatSmsCount();
}

$(document).on('click', '#mail_emoji_toggle', function (e) {
	e.preventDefault();
	var panel = $('#chat_emoji_panel');
	panel.prop('hidden', !panel.prop('hidden'));
});

$(document).on('click', '.chat_emoji', function (e) {
	e.preventDefault();
	chatInsertEmoji($(this).attr('data-emoji') || '');
});

$(document).on('input keyup', '#message', updateChatSmsCount);
$(document).on('change', '#mail_transport', function () {
	chatRememberMethod($(this).val());
	updateChatSmsCount();
	chatMethodLabel($(this), $('.mail_subsection.active').attr('section') == 'tickets' || $('.mail_subsection.active').attr('section') == 'sms');
});

