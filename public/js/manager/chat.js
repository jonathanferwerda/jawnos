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

// A friend opens their one conversation; the dropdown names how the next
// message travels. The thread is the ticket when they hold one, else the phone
// number - only the road taken is sent to the reader, so a ticket-holder's
// thread is their ticket (and the sms history filed under their number re-keys
// onto it) instead of the phone thread shadowing it.
$(document).on('click', '#chat_friends .chat_friend', function () {
	var uuid = $(this).attr('uuid') || '';
	var phone = $(this).attr('phone') || '';
	chatScrollSave();
	chatRailAutoClose();
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

// ---- the on-screen keyboard ------------------------------------------------
// The phone's own keyboard resizes the viewport, which reshapes the window
// under the person. This keyboard lives inside the composer, so the window
// keeps its shape; the message list gives up the room instead. It is off until
// the keyboard button is pressed, so a hardware keyboard and the native one
// still work where they are wanted.
function chatSoftOn() {
	return localStorage.getItem('chat_soft_keyboard') == 'on';
}

function chatSoftApply() {
	if (!$('.chat_shell #message').length) { return; }
	if (chatSoftOn()) { $('#message').attr('inputmode', 'none'); }
	else { $('#message').removeAttr('inputmode'); chatSoftHide(); }
}

function chatSoftShow() {
	if (!chatSoftOn() || !$('#chat_soft_keyboard').length) { return; }
	$('#message').attr('inputmode', 'none');
	$('#chat_soft_keyboard').prop('hidden', false).attr('aria-hidden', 'false');
	$('#chat_soft_toggle').addClass('active').attr('aria-expanded', 'true');
	if (typeof chatKeepPinned === 'function') { chatKeepPinned(); }
}

function chatSoftHide() {
	$('#chat_soft_keyboard').prop('hidden', true).attr('aria-hidden', 'true');
	$('#chat_soft_toggle').removeClass('active').attr('aria-expanded', 'false');
}

var chatSoftShift = false;
function chatSoftShiftSet(on) {
	chatSoftShift = !!on;
	$('.chat_shell .chat_soft_letter').each(function () {
		var k = $(this).attr('data-soft_key') || '';
		$(this).text(chatSoftShift ? k.toUpperCase() : k);
	});
	$('.chat_shell .chat_soft_key[data-soft_key="shift"]').toggleClass('active', chatSoftShift);
}

function chatSoftInsert(text) {
	var ta = document.getElementById('message');
	if (!ta) { return; }
	var start = (ta.selectionStart == null) ? ta.value.length : ta.selectionStart;
	var end = (ta.selectionEnd == null) ? start : ta.selectionEnd;
	ta.value = ta.value.slice(0, start) + text + ta.value.slice(end);
	var pos = start + text.length;
	ta.selectionStart = ta.selectionEnd = pos;
	ta.focus();
	$(ta).trigger('input');
}

function chatSoftBackspace() {
	var ta = document.getElementById('message');
	if (!ta) { return; }
	var start = (ta.selectionStart == null) ? ta.value.length : ta.selectionStart;
	var end = (ta.selectionEnd == null) ? start : ta.selectionEnd;
	if (start == end) {
		if (start == 0) { return; }
		// remove a whole code point, so one press does not leave half an emoji
		var code = ta.value.charCodeAt(start - 1);
		if (code >= 0xDC00 && code <= 0xDFFF && start >= 2) {
			var high = ta.value.charCodeAt(start - 2);
			start = (high >= 0xD800 && high <= 0xDBFF) ? start - 2 : start - 1;
		}
		else { start--; }
	}
	ta.value = ta.value.slice(0, start) + ta.value.slice(end);
	ta.selectionStart = ta.selectionEnd = start;
	ta.focus();
	$(ta).trigger('input');
}

$(document).on('mousedown', '.chat_shell .chat_soft_key', function (e) {
	// keep the caret in the message while a key is pressed on a desk
	e.preventDefault();
});

$(document).on('click', '.chat_shell .chat_soft_key', function () {
	var k = $(this).attr('data-soft_key') || '';
	if (k == 'shift') { chatSoftShiftSet(!chatSoftShift); return; }
	if (k == 'backspace') { chatSoftBackspace(); return; }
	if (k == 'space') { chatSoftInsert(' '); return; }
	if (k == 'enter') { chatSoftInsert('\n'); return; }
	if (k == 'hide') { chatSoftHide(); return; }
	chatSoftInsert(chatSoftShift ? k.toUpperCase() : k);
	if (chatSoftShift) { chatSoftShiftSet(false); }
});

$(document).on('click', '#chat_soft_toggle', function () {
	if (chatSoftOn()) {
		localStorage.setItem('chat_soft_keyboard', 'off');
		$('#message').removeAttr('inputmode');
		chatSoftHide();
		// hand the field back to the platform so its keyboard opens
		if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); }
		setTimeout(function () { $('#message').focus(); }, 60);
		return;
	}
	localStorage.setItem('chat_soft_keyboard', 'on');
	// drop a native keyboard that is already up, then focus with none
	if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); }
	chatSoftShiftSet(false);
	setTimeout(function () { $('#message').attr('inputmode', 'none').focus(); chatSoftShow(); }, 80);
});

$(document).on('focus click', '.chat_shell #message', function () {
	if (chatSoftOn()) { chatSoftShow(); }
});

$(document).on('click', '.chat_shell #send_it', function () {
	// sending must not put the on-screen keyboard away
	if (!chatSoftOn()) { return; }
	setTimeout(function () { $('#message').focus(); chatSoftShow(); }, 0);
});

$(document).on('blur', '.chat_shell #message', function () {
	if (!chatSoftOn()) { return; }
	setTimeout(function () {
		if (!$(document.activeElement).closest('.chat_soft_keyboard').length) { chatSoftHide(); }
	}, 250);
});

$(document).on('input keyup', '#message', updateChatSmsCount);
$(document).on('change', '#mail_transport', function () {
	chatRememberMethod($(this).val());
	updateChatSmsCount();
	chatMethodLabel($(this), $('.mail_subsection.active').attr('section') == 'tickets' || $('.mail_subsection.active').attr('section') == 'sms');
});

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

// ---- landing on the newest message ---------------------------------------
// The window is inserted before the browser has laid out its messages, so one
// scrollTop at insert time can land short; a few passes settle it on the last
// bubble. The socket also replaces messages as they arrive, so the thread stays
// pinned briefly while those replacements grow the list.
var chatAutoScrollUntil = 0;
// Whether the person is reading the foot of the thread. Typing grows the
// composer, which takes height from the messages, and the keyboard shrinks the
// whole window; both used to leave the newest bubbles below the fold. Only a
// real scroll gesture moves the flag, so a resize that drags the scroll position
// around is never mistaken for someone reading history.
var chatPinnedToBottom = true;

function chatPinBottomGo() {
	var box = document.getElementById('mailbox');
	if (!box) { return; }
	box.scrollTop = box.scrollHeight;
	chatPinnedToBottom = true;
}

function chatPinnedNow() {
	var box = document.getElementById('mailbox');
	if (!box) { return false; }
	return (box.scrollHeight - box.scrollTop - box.clientHeight) < 60;
}

function chatScrollBottom() {
	if (!$('#mail').hasClass('chat_shell')) { return; }
	chatAutoScrollUntil = Date.now() + 3000;
	var go = function () {
		if (!$('#mail').hasClass('chat_shell')) { return; }
		chatPinBottomGo();
	};
	go();
	if (window.requestAnimationFrame) {
		requestAnimationFrame(function () { requestAnimationFrame(go); });
	}
	setTimeout(go, 80);
	setTimeout(go, 240);
	setTimeout(go, 600);
}

// A live message keeps a pinned thread at its foot.
function chatKeepPinned() {
	if (!$('#mail').hasClass('chat_shell')) { return; }
	if (chatPinnedToBottom) { chatPinBottomGo(); }
}

// A real scroll gesture means the person is reading, so stop pinning.
// Evaluating after the gesture (rather than on every scroll event) keeps the
// browser's own scroll clamping during a keyboard resize out of the decision.
var chatPinGestureTimer;
$(document).on('wheel touchmove', '.chat_shell #mailbox', function () {
	chatAutoScrollUntil = 0;
	clearTimeout(chatPinGestureTimer);
	chatPinGestureTimer = setTimeout(function () { chatPinnedToBottom = chatPinnedNow(); }, 220);
});
$(document).on('touchend mouseup', '.chat_shell #mailbox', function () {
	clearTimeout(chatPinGestureTimer);
	chatPinnedToBottom = chatPinnedNow();
});

// Both the composer (the textarea growing) and the message box (the keyboard
// shrinking the window) change size without a render. Follow either, and keep a
// pinned thread at the foot.
var chatPinObserver;
function chatObservePin() {
	if (chatPinObserver) { chatPinObserver.disconnect(); chatPinObserver = null; }
	if (!window.ResizeObserver || !$('#mail').hasClass('chat_shell')) { return; }
	var box = document.getElementById('mailbox');
	var composer = document.getElementById('just_hit_send');
	if (!box) { return; }
	chatPinObserver = new ResizeObserver(function () {
		if (chatPinnedToBottom) { chatPinBottomGo(); }
	});
	chatPinObserver.observe(box);
	if (composer) { chatPinObserver.observe(composer); }
}

var chatViewportTimer;
function chatViewportChanged() {
	if (!$('#mail').hasClass('chat_shell')) { return; }
	clearTimeout(chatViewportTimer);
	// after the window has taken its new size (windowFit is debounced)
	chatViewportTimer = setTimeout(function () {
		if (chatPinnedToBottom) { chatScrollBottom(); }
	}, 120);
}
window.addEventListener('resize', chatViewportChanged);
if (window.visualViewport) { window.visualViewport.addEventListener('resize', chatViewportChanged); }

// ---- rail: menu, subheadings and remembered scroll ------------------------
// On a phone the rail is a drawer over the conversation. Its default follows
// the container query the stylesheet uses (closed when the shell is narrow,
// open on a desk); the menu's own choice is remembered and wins after that.
function chatRailNarrow() {
	var shell = $('.chat_shell').get(0);
	if (shell) {
		var width = shell.getBoundingClientRect().width;
		if (width) { return width <= 720; }
	}
	return window.matchMedia('(max-width: 760px)').matches;
}

function chatRailApply() {
	var rail = $('#mail_sidebar');
	if (!rail.length || !$('#mail').hasClass('chat_shell')) { return; }
	var pref = localStorage.getItem('mail_sidebar');
	var open = (pref == 'on') ? true : (pref == 'off') ? false : !chatRailNarrow();
	rail.toggle(open);
	$('#conversation').show();
	$('#mail_hamburger').attr('aria-expanded', open ? 'true' : 'false');
	chatGroupsApply();
	if (open) { chatScrollRestore(); }
}

// Picking a conversation on a phone puts the drawer away; picking a section
// keeps it open, because that section's own list lives in the rail.
function chatRailAutoClose() {
	if (!$('#mail').hasClass('chat_shell')) { return; }
	if (chatRailNarrow()) { localStorage.setItem('mail_sidebar', 'off'); }
}

// The rail's position belongs to the section it was showing, so sms -> dial ->
// sms returns to the row the person was looking at. Each list keeps its own
// position too, for the subheadings that hold one.
function chatRailSection() {
	return $('.mail_subsection.active').attr('section') || 'sms';
}

function chatScrollSave() {
	var rail = $('.chat_shell .chat_rail').get(0);
	if (rail) { localStorage.setItem('chat_scroll_rail_' + chatRailSection(), rail.scrollTop); }
	$('.chat_shell .chat_rail [data-chat-scroll]').each(function () {
		localStorage.setItem('chat_scroll_' + $(this).attr('data-chat-scroll'), this.scrollTop);
	});
}

function chatScrollRestore() {
	var rail = $('.chat_shell .chat_rail').get(0);
	if (rail) {
		var top = parseInt(localStorage.getItem('chat_scroll_rail_' + chatRailSection()) || '', 10);
		if (!isNaN(top)) { rail.scrollTop = top; }
	}
	$('.chat_shell .chat_rail [data-chat-scroll]').each(function () {
		var top = parseInt(localStorage.getItem('chat_scroll_' + $(this).attr('data-chat-scroll')) || '', 10);
		if (!isNaN(top)) { this.scrollTop = top; }
	});
}

// A subheading carries data-chat_group and hides the list beside it
// (data-chat_group_body). "off" is remembered so Known can stay folded away.
function chatGroupsApply() {
	$('.chat_shell .chat_rail_subhead').each(function () {
		var key = $(this).attr('data-chat_group') || '';
		var hidden = localStorage.getItem('chat_group_' + key) == 'off';
		$(this).attr('aria-expanded', hidden ? 'false' : 'true');
		$('.chat_shell [data-chat_group_body="' + key + '"]').prop('hidden', hidden);
	});
}

$(document).on('click', '.chat_shell .chat_rail_subhead', function () {
	var key = $(this).attr('data-chat_group') || '';
	var body = $('.chat_shell [data-chat_group_body="' + key + '"]');
	var open = body.prop('hidden');
	body.prop('hidden', !open);
	$(this).attr('aria-expanded', open ? 'true' : 'false');
	localStorage.setItem('chat_group_' + key, open ? 'on' : 'off');
	if (open) { chatScrollRestore(); }
});

var chatScrollTimer;
// scroll events do not bubble, so listen in the capture phase to catch the rail
// (and each list that can scroll inside it) however it was rendered.
document.addEventListener('scroll', function (e) {
	var el = e.target;
	if (!el || !el.closest || !$(el).closest('.chat_shell .chat_rail').length) { return; }
	clearTimeout(chatScrollTimer);
	chatScrollTimer = setTimeout(chatScrollSave, 140);
}, true);

$(function () {
	if ($('.chat_shell').length) {
		chatDressMessages();
		chatRailApply();
		chatTransportOptions();
		chatSoftApply();
		chatScrollBottom();
		chatObservePin();
	}
});
