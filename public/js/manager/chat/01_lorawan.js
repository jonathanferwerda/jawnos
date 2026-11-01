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
		chatScrollBottom();
		chatObservePin();
	}
});
