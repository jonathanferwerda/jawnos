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
	var hasPhone = (localStorage.getItem('mail_phone') || '') != '';
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
	if (sel.val() == 'sms') {
		var first = sel.find('option[value="sms"]').first();
		if (first.length) { sel.find('option').prop('selected', false); first.prop('selected', true); }
	}
	sel.find('option[value="sms"]').prop('disabled', !hasPhone);
	if (!hasPhone && sel.val() == 'sms') { sel.val('chat'); }
	updateChatSmsCount();
	if (onLora) { setTimeout(chatLoraRefresh, 200); }
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
			chatDressMessages();
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
$(document).on('change', '#mail_transport', updateChatSmsCount);

// ---- LoRaWAN ---------------------------------------------------------------
var chatLoraLoaded = false;
function chatLoraSetStatus(label, state) {
	$('#chat_lora_state').text(label || 'checking').attr('data-state', state || 'unknown');
}

function chatLoraFill(s) {
	if (!s || typeof s !== 'object') { return; }
	$('#lorawan_enabled').prop('checked', s.enabled == 'on');
	$('#lorawan_band').val(s.band || 'EU433');
	$('#lorawan_subband').val(s.subband || 1);
	$('#lorawan_join_eui').val(s.join_eui || '');
	$('#lorawan_dev_eui').val(s.dev_eui || '');
	$('#lorawan_fport').val(s.fport || 1);
	$('#lorawan_confirmed').prop('checked', s.confirmed == 'on');
	if (s.webhook_url) { $('#lorawan_webhook').val(s.webhook_url); }
	$('#lorawan_app_key').attr('placeholder', s.has_app_key ? 'saved - leave blank to keep' : '32 hex');
	chatLoraLoaded = true;
}

function chatLoraRefresh() {
	if (!$('#chat_lora_panel').length) { return; }
	if (!chatLoraLoaded) {
		$.get('/manager/lorawan/settings', function (r) {
			if (r && r.ok) { chatLoraFill(r); }
		});
	}
	$.get('/manager/lorawan/status', function (r) {
		if (!r) { chatLoraSetStatus('no deck', 'off'); return; }
		var res = r.result || (r.devices && r.devices[0] && r.devices[0].result) || null;
		if (!res) {
			chatLoraSetStatus('no deck', 'off');
			$('#lorawan_status').text(r.error || 'No LoRa-capable T-Deck is online.');
			return;
		}
		var joined = res.joined == 'yes';
		var enabled = res.enabled == 'on';
		chatLoraSetStatus(joined ? 'joined' : (enabled ? 'not joined' : 'off'), joined ? 'on' : (enabled ? 'unknown' : 'off'));
		var bits = [];
		if (res.band) { bits.push(res.band); }
		if (res.max_payload) { bits.push('max ' + res.max_payload + ' bytes'); }
		if (res.error) { bits.push(res.error); }
		if (res.rssi) { bits.push('RSSI ' + res.rssi + ' dBm'); }
		$('#lorawan_status').text(bits.join(' · '));
	});
}

$(document).on('click', '#lorawan_save', function () {
	chatLoraSetStatus('saving', 'unknown');
	var data = {
		enabled: $('#lorawan_enabled').is(':checked') ? 'on' : '',
		band: $('#lorawan_band').val() || 'EU433',
		subband: $('#lorawan_subband').val() || 1,
		join_eui: $('#lorawan_join_eui').val() || '',
		dev_eui: $('#lorawan_dev_eui').val() || '',
		app_key: $('#lorawan_app_key').val() || '',
		fport: $('#lorawan_fport').val() || 1,
		confirmed: $('#lorawan_confirmed').is(':checked') ? 'on' : ''
	};
	$.post('/manager/lorawan/settings', data, function (r) {
		if (!r || !r.ok) {
			$('#lorawan_status').text((r && r.error) || 'Could not save the LoRaWAN settings.');
			chatLoraSetStatus('error', 'off');
			return;
		}
		chatLoraFill(r.settings || {});
		$('#lorawan_app_key').val('');
		if (r.push && !r.push.ok) {
			$('#lorawan_status').text((r.push.error || 'No T-Deck answered.') + ' The settings are saved here.');
		}
		else {
			$('#lorawan_status').text('Saved and sent to the deck.');
		}
		chatLoraRefresh();
	}).fail(function () {
		$('#lorawan_status').text('Could not reach the manager.');
		chatLoraSetStatus('error', 'off');
	});
});

$(document).on('click', '#lorawan_join', function () {
	chatLoraSetStatus('joining', 'unknown');
	$('#lorawan_status').text('Joining the network…');
	$.post('/manager/lorawan/join', {}, function (r) {
		if (!r || !r.ok) {
			$('#lorawan_status').text((r && r.error) || 'The deck could not join.');
			chatLoraSetStatus('not joined', 'off');
			return;
		}
		$('#lorawan_status').text('Joined.');
		chatLoraRefresh();
	});
});

$(document).on('click', '#lorawan_test', function () {
	$('#lorawan_status').text('Sending a test uplink…');
	$.post('/manager/lorawan/send', { message: 'JawnOS LoRa test' }, function (r) {
		if (!r || !r.ok) {
			$('#lorawan_status').text((r && r.error) || 'The deck could not send.');
			return;
		}
		$('#lorawan_status').text('Test sent.');
	});
});

$(document).on('click', '#lorawan_copy_webhook', function () {
	var text = $('#lorawan_webhook').val() || '';
	if (!text) { return; }
	if (navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(text);
	}
	else {
		$('#lorawan_webhook').trigger('select');
		document.execCommand('copy');
	}
});

// Live envelopes are rendered by the shared server template, which does not
// know a window is Chat. Dress any old-style message that lands in the chat
// shell: strip the mailbox floats and give it the same bubble classes the
// initial render already wears.
function chatDressMessages(root) {
	var scope = $(root || '.chat_shell');
	scope.find('.mailbox_message').each(function () {
		var b = $(this);
		if (b.hasClass('chat_bubble')) { return; }
		var inner = b.children('span').first();
		if (!inner.length) { return; }
		var outgoing = ((inner.attr('style') || '').indexOf('float:right') >= 0);
		b.addClass('chat_bubble ' + (outgoing ? 'chat_out' : 'chat_in')).removeAttr('style');
		inner.removeAttr('style').addClass('chat_bubble_inner');
		inner.find('.time').removeAttr('style').addClass('chat_time');
		inner.find('b').removeAttr('style').addClass('chat_sender');
		inner.find('.mailbox_message_contents').removeAttr('style').addClass('chat_text');
	});
}

$(function () {
	if ($('.chat_shell').length) {
		chatDressMessages();
		if (localStorage.getItem('mail_sidebar') == 'off') {
			$('#mail_sidebar').hide();
			$('#conversation').show();
		}
	}
});
