var nfc = {
	scanning: false,
	writing: false,
	abort: new AbortController(),
	initialized: false
};
var assistant = {};
if ('NDEFReader' in window) {
	nfc['ndef'] = new NDEFReader();
	nfcInitializer();
}
else { nfc['ndef'] = undefined; }

$(document).on('click', '.president_restart_trigger', function() {
	$.ajax({
		url:'/manager/president/restart',
		type: 'POST',
		success: function(response) {
			if (response == 'restarting') {
				if ($(this).attr('restart') == 'yes') {
					setTimeout(function() {

						window.location.reload();
					},3000);
				}
			}
		}
	});
});


if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/service_worker.js')
      .catch(err => console.log('Registration failed:', err));
  });
}


$(document).on('change', '#time_machine',function() {
	var ts = $(this).val();
	localStorage.setItem('time_machine',ts);
});


var focused_input;
var startMenuTimeout;
// the menu's html per tab, so reopening a tab does not fetch and (re-stamp) it
// again - see startMenuToggle()
var startMenuHtml = {};
$(document).on('click', '.time_jump', function() {
	var j = $(this);
	var appointment = j.closest('.appointment');
	var type = j.attr('type');
	var timestamp = j.attr('timestamp') || timestamp;
	var app = j.attr('app');
	var delorean = deloreanBringer();
	var filter = localStorage.getItem('filter');
	$.ajax({
		url: '/manager/time_jump',
		type: 'GET',
		data: { timestamp: timestamp, filter: filter, type: type, app: app, scope: delorean.scope },
		success: function(response) {
			if (response.new_timestamp) {
				$('#time_machine').val(response.date);
				localStorage.setItem('time_machine',response.date);
				j.attr('timestamp',response.new_timestamp);
				j.closest('.walkman_controls').find('.time_jump').attr('timestamp',response.new_timestamp);
				appointmentDetailsGrabber(j);
			}
			else {
				$('.time_jump').attr('timestamp',response.old_timestamp);
			}
		}
	});

});

$(document).ready(function() {
	pseudonymFreeSpaceFinder();
	windowRetriever();
	nfcListener();
	if ($('#search_engines')) {

	}
	focused_input = $('#search');
	initializer();
	calculator();
	boxOfficeMaker();
	assistantInitializer();
});

$(document).on('click', '.assistant_close', function() {
	var panel = $(this).closest('.assistant_view');
	panel.find('.assistant_config_menu').hide();
	// a spawned associate was made on a whim: closing it takes it away, while the
	// one the taskbar button owns stays put to be called back
	if (panel.attr('spawned')) { panel.remove(); }
	else { panel.hide(); }
});

// The configure button in the panel's navbar opens the small configuration menu
// (today just the Confirmation Requirement); anywhere else closes it.
$(document).on('click', '.assistant_config', function(e) {
	e.stopPropagation();
	var panel = $(this).closest('.assistant_view');
	$('.assistant_config_menu').hide();
	panel.find('.assistant_config_menu').toggle();
	if (panel.find('.assistant_config_menu').is(':visible')) { assistantStagedRefreshCount(panel); }
});
$(document).on('click', function(e) {
	if (!$(e.target).closest('.assistant_config, .assistant_config_menu').length) { $('.assistant_config_menu').hide(); }
});

// The Confirmation Requirement, the tick in the panel's header: with it on the
// Guide stages a proposed appointment and waits for a yes; with it off the
// guide saves what it proposes as it makes it (helpDoAction reads this). It is
// one setting, so every open associate's tick follows the press.
$(document).on('change', '.assistant_confirm', function() {
	var on = $(this).is(':checked');
	$('.assistant_confirm').prop('checked', on);
	settingSetter({ app: '__president', setting: 'guide_confirm', device: 'all', value: on ? 'on' : 'off' });
});

// Speak the replies: one setting for every associate, like the Confirm tick.
// With it on, each written answer also goes to the house voice (Piper first,
// see say_it) on this machine - the route re-checks the setting as it speaks.
$(document).on('change', '.assistant_speak', function() {
	var on = $(this).is(':checked');
	$('.assistant_speak').prop('checked', on);
	settingSetter({ app: '__president', setting: 'assistant_speech', device: 'all', value: on ? 'on' : 'off' });
});

function assistantSpeakWanted() {
	return $('.assistant_speak').length && $('.assistant_speak').first().is(':checked');
}

function assistantSpeak(text) {
	text = $.trim(text == null ? '' : String(text));
	if (!text || /^\{/.test(text) || !assistantSpeakWanted()) { return null; }
	// the words go to the house voice in a fork of its own; the request comes
	// back with an estimate of how long they take to say, so a conversation can
	// hold its mic until the voice has stopped
	return $.post('/manager/assistant/say', { text: text.slice(0, 800) });
}

function assistantConfirmRequired() {
	var box = $('.assistant_confirm');
	if (box.length) { return box.is(':checked'); }
	return true;
}

// ---- the associate's staged list ----------------------------------------------
// The configure menu's Staged entry swaps the chat for what the Guide is holding
// (staged_appointments, status pending). Each row approves (promote) or deletes
// (discard) its proposal. The chat itself is only hidden, never rebuilt: going
// back finds the conversation exactly as it was left.

function assistantStagedRefreshCount(panel) {
	var at = panel.find('.assistant_staged_count');
	if (!at.length) { return; }
	$.get('/manager/help/staged', function (r) {
		var n = (r && r.staged) ? r.staged.length : 0;
		at.text(n ? ' (' + n + ')' : '');
	});
}

function assistantStagedShow(panel) {
	panel.find('.assistant_chat_log, .assistant_input_row').hide();
	panel.find('.assistant_staged_panel').css('display', 'flex');
	assistantStagedLoad(panel);
}

function assistantStagedHide(panel) {
	panel.find('.assistant_staged_panel').hide();
	panel.find('.assistant_chat_log, .assistant_input_row').show();
}

function assistantStagedWhen(row) {
	var ts = parseInt(row.timestamp, 10);
	if (!ts || isNaN(ts)) { return row.staged_time || ''; }
	var d = new Date(ts);
	return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function assistantStagedLoad(panel) {
	var list = panel.find('.assistant_staged_list');
	if (!list.length) { return; }
	list.text('…');
	$.get('/manager/help/staged', function (r) {
		assistantStagedRender(panel, (r && r.staged) || []);
	}).fail(function () { list.text('I could not read the staged list.'); });
}

function assistantStagedRender(panel, rows) {
	var list = panel.find('.assistant_staged_list');
	list.empty();
	panel.find('.assistant_staged_count').text(rows.length ? ' (' + rows.length + ')' : '');
	if (!rows.length) {
		list.append($('<div style="font-size:12px;opacity:.7;padding:6px 2px;"></div>').text('Nothing is staged.'));
		return;
	}
	rows.forEach(function (row) {
		var item = $('<div class="assistant_staged_row" style="display:flex;align-items:center;gap:6px;padding:7px 2px;border-bottom:1px solid var(--line);."></div>')
			.attr('uuid', row.uuid)
			.attr('staged_title', row.title || row.app || '');
		var text = $('<div style="flex:1;min-width:0;overflow-wrap:break-word;"></div>');
		text.append($('<div></div>').text(row.title || '(an appointment)'));
		text.append($('<div class="chat_meta">"></div>').text(assistantStagedWhen(row) + (row.app ? ' — ' + row.app : '')));
		var trash = $.trim(panel.find('.assistant_trash_icon').text()) || '/icons/trash.png';
		var approve = '<span class="assistant_staged_approve hover" hint="Approve and save this staged appointment" title="Save it" style="cursor:pointer;font-size:15px;opacity:.75;">👍</span>';
		var del = '<img class="tiny_thumb assistant_staged_delete hover" hint="Delete this staged appointment" title="Delete it" style="cursor:pointer;padding:2px;" src="' + trash + '">';
		item.append(text).append(approve).append(del);
		list.append(item);
	});
}

$(document).on('click', '.assistant_staged_open', function (e) {
	e.stopPropagation();
	var panel = $(this).closest('.assistant_view');
	panel.find('.assistant_config_menu').hide();
	assistantStagedShow(panel);
});

$(document).on('click', '.assistant_staged_back', function () { assistantStagedHide($(this).closest('.assistant_view')); });

$(document).on('click', '.assistant_staged_approve', function () {
	var panel = $(this).closest('.assistant_view');
	var row = $(this).closest('.assistant_staged_row');
	var title = row.attr('staged_title') || 'the appointment';
	$.post('/manager/help/promote', { uuid: row.attr('uuid') }, function (r) {
		if (!r || r.error) { assistantChatAdd(panel, 'step', 'I could not save that one.'); return; }
		assistantChatAdd(panel, 'step', 'Saved the staged “' + title + '”.');
		assistantStagedLoad(panel);
	}).fail(function () { assistantChatAdd(panel, 'step', 'I could not save that one.'); });
});

$(document).on('click', '.assistant_staged_delete', function () {
	// the program's delete idiom: the first press arms the button (red for 2 s),
	// the second press within that window does the delete
	var a = $(this);
	var row = a.closest('.assistant_staged_row');
	if (a.attr('armed') == 'yes') {
		var title = row.attr('staged_title') || 'the appointment';
		$.post('/manager/help/discard', { uuid: row.attr('uuid') }, function () {
			assistantChatAdd(a.closest('.assistant_view'), 'step', 'Deleted the staged “' + title + '”.');
			assistantStagedLoad(a.closest('.assistant_view'));
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

// ---- the Guide's associate: a compact chat that lives with the taskbar --------
// Clicking the assistant button opens this; dragging it onto a picture drops
// that picture into the chat. It shares the Guide's bubble format and its
// whitelisted actions, but it is its own little window, not the Help app.

var jawnos_assistant_dragging = false;
var jawnos_assistant_extra = 0;
var jawnos_assistant_last = null;
var jawnos_assistant_top = 990000;
var jawnos_assistant_click_timer = null;

// Which panel a bubble, a drop or the taskbar button aims at: the one it was
// asked from, the last one touched, or the first (the taskbar's own).
function assistantPanel(el) {
	if (el && $(el).closest('.assistant_view').length) { return $(el).closest('.assistant_view'); }
	if (jawnos_assistant_last && jawnos_assistant_last.length) { return jawnos_assistant_last; }
	return $('.assistant_view').first();
}
function assistantConversation(panel) { return panel.attr('conversation') || 'assistant'; }
function assistantThread(panel) {
	if (!panel.data('thread')) { panel.data('thread', []); }
	return panel.data('thread');
}
function assistantLog(panel) { return panel.find('.assistant_chat_log'); }

// Every turn meant to be remembered goes through here, so the thread is saved
// (debounced) as it grows and the agents list can name, list and re-open it.
function assistantRemember(panel, role, content) {
	assistantThread(panel).push({ role: role, content: content });
	clearTimeout(panel.data('save_timer'));
	panel.data('save_timer', setTimeout(function () { assistantThreadSave(panel); }, 900));
}

function assistantThreadSave(panel) {
	// a debounce that outlived its thread sends nothing: an empty save must never
	// wipe what the server remembers (a guard there holds the same line)
	if (!assistantThread(panel).length) { return; }
	$.ajax({
		url: '/manager/agents/save',
		type: 'POST',
		dataType: 'json',
		data: { kind: 'guide', name: assistantConversation(panel), transcript: JSON.stringify(assistantThread(panel)) },
		success: function (r) {
			if (r && r.title) { panel.data('title', r.title); assistantTitleShow(panel); }
		}
	});
}

// A reload can arrive (an update) inside the save debounce: flush whatever is
// still owed as the page goes, or the last turn would be lost from the history.
function assistantThreadFlush() {
	$('.assistant_view').each(function () {
		var panel = $(this);
		clearTimeout(panel.data('save_timer'));
		if (!assistantThread(panel).length) { return; }
		try {
			$.ajax({
				url: '/manager/agents/save',
				type: 'POST',
				async: false,
				dataType: 'json',
				data: { kind: 'guide', name: assistantConversation(panel), transcript: JSON.stringify(assistantThread(panel)) }
			});
		} catch (e) { /* the page is going; a lost save is better than a stuck one */ }
	});
}
window.addEventListener('beforeunload', assistantThreadFlush);

function assistantTitleShow(panel) {
	var t = panel.data('title');
	if (t) { panel.find('.assistant_title').text(t); }
}

function assistantChatAdd(panel, role, text) {
	var log = assistantLog(panel);
	if (!log.length) { return $(); }
	var safe = $('<div>').text(text == null ? '' : String(text)).html().replace(/\n/g, '<br>');
	if (role === 'step') {
		log.append($('<div style="text-align:center;margin:5px 0;"><span class="chat_step">' + safe + '</span></div>'));
	}
	else {
		var mine = (role === 'user');
		var bubble = '<span class="chat_bubble" style="display:inline-block;max-width:84%;overflow-wrap:break-word;border-radius:10px;padding:6px 10px;$' + (mine ? 'background:#cdeccd;' : 'background:#cfe3f5;') + '">' + safe + '</span>';
		log.append($('<div style="display:flex;margin:4px 0;$' + (mine ? 'justify-content:flex-end;' : 'justify-content:flex-start;') + '">' + bubble + '</div>'));
	}
	log.scrollTop(log[0].scrollHeight);
	return log.children().last();
}

// An assistant bubble whose inner .assistant_content the server streams into.
function assistantAnswerBubble(panel) {
	var log = assistantLog(panel);
	if (!log.length) { return $(); }
	var el = $('<div style="display:flex;margin:4px 0;justify-content:flex-start;">'
		+ '<span class="chat_bubble" style="display:inline-block;max-width:84%;overflow-wrap:break-word;border-radius:10px;padding:6px 10px;background:#cfe3f5;">'
		+ '<span class="assistant_content" style="opacity:.7;">…</span></span></div>');
	log.append(el);
	log.scrollTop(log[0].scrollHeight);
	return el.find('.assistant_content');
}

function assistantOpenPanel(panel) {
	if (!panel || !panel.length) { return $(); }
	if (!panel.data('greeted')) {
		panel.data('greeted', 1);
		assistantChatAdd(panel, 'guide', "Hello — I'm the Guide's associate. Ask me something, or drag my button onto a picture and I'll take a look.");
	}
	if (!panel.is(':visible')) {
		// measure behind visibility, not display: none - a hidden element has no
		// box to measure, and the panel would land against a zero width
		panel.css({ visibility: 'hidden', display: 'flex' });
		var w = panel.outerWidth(), h = panel.outerHeight();
		var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
		var left = Math.max(6, Math.min($(window).width() - w - 16, $(window).width() - w - 16));
		var top = Math.max(6, Math.min($(window).height() - h - 70, $(window).height() - h - bar - 6));
		panel.css({ left: left + 'px', top: top + 'px', right: '', bottom: '', visibility: '' });
	}
	panel.css('z-index', ++jawnos_assistant_top);
	jawnos_assistant_last = panel;
	return panel;
}

function assistantOpen() { return assistantOpenPanel(assistantPanel()); }

function assistantModel(panel) {
	var m = $.trim(panel.find('.assistant_model').text() || '');
	if (!m && $('#help_model').length) { m = $('#help_model').val() || ''; }
	return m;
}

// Text turns go to the same guide agent the Help app uses.
function assistantAsk(panel) {
	var input = panel.find('.assistant_question');
	var q = $.trim(input.val() || '');
	if (!q) {
		// an empty Ask is the conversation switch: the mic opens and the panel
		// keeps listening between answers until End (or "bye jawn")
		assistantOpenPanel(panel);
		if (assistantTalking(panel)) { assistantConversationEnd(panel); }
		else { assistantConversationOn(panel); assistantConversationListen(panel); }
		return;
	}
	// "hey jawn"/"jawn do" open a conversation, "bye jawn" ends one
	if (typeof helpConversationBye === 'function' && helpConversationBye(q)) {
		input.val('');
		assistantButtonLabel(panel);
		if (assistantTalking(panel)) { assistantConversationEnd(panel); }
		return;
	}
	var wake_rest = (typeof helpConversationWake === 'function') ? helpConversationWake(q) : null;
	if (wake_rest !== null) {
		assistantOpenPanel(panel);
		assistantConversationOn(panel);
		if (!wake_rest) { input.val(''); assistantButtonLabel(panel); assistantChatAdd(panel, 'step', 'Yes?'); assistantConversationListen(panel); return; }
		q = wake_rest;
	}
	input.val('');
	assistantButtonLabel(panel);
	panel.data('topic', '');
	assistantOpenPanel(panel);
	assistantChatAdd(panel, 'user', q);
	assistantRemember(panel, 'user', q);
	assistantGuideStep(panel, 0);
}

function assistantGuideStep(panel, n) {
	if (n >= 6) {
		assistantChatAdd(panel, 'step', 'Stopping after several steps.');
		assistantChatAdd(panel, 'guide', 'I did not finish that in a few steps — try naming the app, or ask me about it.');
		return;
	}
	var ctx = (typeof helpContextNow === 'function') ? helpContextNow() : {};
	$.ajax({
		url: '/manager/help/act',
		type: 'POST',
		dataType: 'json',
		data: {
			transcript: JSON.stringify(assistantThread(panel)),
			context: JSON.stringify(ctx),
			topic: panel.data('topic') || '',
			model: assistantModel(panel)
		},
		success: function (r) {
			if (r && r.error) { assistantChatAdd(panel, 'step', r.error); return; }
			var a = (r && r.action) || {};
			if (a.action === 'say' || a.action === 'ask' || a.action === 'done') {
				assistantRemember(panel, 'assistant', a.text || '');
				assistantChatAdd(panel, 'guide', a.text || '');
				var spoke = assistantSpeak(a.text);
				if (assistantTalking(panel)) { assistantConversationListen(panel, spoke); }
				return;
			}
			assistantChatAdd(panel, 'step', (typeof helpActionLabel === 'function') ? helpActionLabel(a) : 'Working…');
			assistantRemember(panel, 'assistant', JSON.stringify(a));
			if (typeof helpDoAction !== 'function') { assistantChatAdd(panel, 'step', 'The guide is not available.'); return; }
			helpDoAction(a, function (obs, friendly) {
				assistantRemember(panel, 'tool', obs);
				if (friendly) {
					assistantRemember(panel, 'assistant', friendly);
					assistantChatAdd(panel, 'guide', friendly);
					var spoke = assistantSpeak(friendly);
					if (assistantTalking(panel)) { assistantConversationListen(panel, spoke); }
					return;
				}
				assistantGuideStep(panel, n + 1);
			});
		},
		error: function () { assistantChatAdd(panel, 'step', 'The guide could not be reached.'); }
	});
}

// ---- the associate as a conversationalist ---------------------------------
// The same switch the help window's guide has: with a conversation on, the mic
// opens again after each answer, the clip ends itself once the person stops
// talking, and each utterance is the next turn of this panel's own thread -
// until "bye jawn" or the End button. The button says which it is: with the
// box empty it reads Converse, with words typed it reads Ask, and while a
// conversation runs it reads End.
function assistantTalking(panel) { return panel.attr('talking') === 'yes'; }

function assistantButtonLabel(panel) {
	var b = panel.find('.assistant_send');
	if (!b.length) { return; }
	var q = $.trim(panel.find('.assistant_question').val() || '');
	if (q) { b.text('Ask').css({ 'border-color': 'var(--line)', 'color': '' }).attr('hint', 'Ask, or ask it to do it'); }
	else if (assistantTalking(panel)) { b.text('End').css({ 'border-color': '#e23b3b', 'color': '#e23b3b' }).attr('hint', 'End the conversation'); }
	else { b.text('Converse').css({ 'border-color': 'var(--line)', 'color': '' }).attr('hint', 'Start a spoken conversation: the mic opens again after each answer, so you can just keep talking “bye jawn” or press End to stop'); }
}

function assistantConversationOn(panel) {
	if (assistantTalking(panel)) { return; }
	panel.attr('talking', 'yes');
	assistantButtonLabel(panel);
	assistantChatAdd(panel, 'step', 'Conversation on — I will keep listening after each answer. Press End or say “bye jawn” to stop.');
}

function assistantConversationEnd(panel) {
	if (!assistantTalking(panel)) { return; }
	panel.removeAttr('talking');
	if (typeof jawn_clip !== 'undefined' && jawn_clip.owner && jawn_clip.owner === panel[0]) { jawnClipStop(true); }
	assistantButtonLabel(panel);
	assistantChatAdd(panel, 'guide', 'Alright — I will be here.');
}

function assistantConversationListen(panel, spoken) {
	if (!assistantTalking(panel)) { return; }
	var begin = function () {
		setTimeout(function () {
			if (!assistantTalking(panel)) { return; }
			if (typeof jawnClipListen !== 'function') { return; }
			jawnClipListen({
				talking: true,
				owner: panel[0],
				selfWords: assistantLastWords(panel),
				status: function (msg) { assistantChatAdd(panel, 'step', msg); },
				onText: function (text) { assistantConversationHeard(panel, text); },
				onEcho: function () { assistantConversationListen(panel); },
				onFail: function (reason) {
					if (!assistantTalking(panel)) { return; }
					// a deaf microphone ends it; anything else just listens again
					if (reason === 'microphone' || reason === 'no microphone') { assistantConversationEnd(panel); return; }
					assistantConversationListen(panel);
				}
			});
		}, 350);
	};
	if (spoken && spoken.done) {
		// the reply is being said aloud: hold the mic until the voice is done
		spoken.done(function (r) {
			var secs = parseFloat((r && r.seconds) || 0) || 0;
			setTimeout(function () { if (assistantTalking(panel)) { begin(); } }, Math.min(30000, 1000 * secs));
		});
		spoken.fail(function () { begin(); });
	}
	else { begin(); }
}

// the panel's own last words, so a conversation's mic can tell the speaker from the
// person
function assistantLastWords(panel) {
	var t = (typeof assistantThread === 'function') ? assistantThread(panel) : [];
	for (var i = t.length - 1; i >= 0; i--) {
		var m = t[i] || {};
		if ((m.role || '') === 'assistant' && m.content && !/^\s*\{/.test(m.content)) { return m.content; }
	}
	return '';
}

function assistantConversationHeard(panel, text) {
	if (!assistantTalking(panel)) { return; }
	var q = $.trim(text || '');
	if (!q) { assistantConversationListen(panel); return; }
	if (helpConversationBye(q)) { assistantConversationEnd(panel); return; }
	var rest = (typeof helpConversationWake === 'function') ? helpConversationWake(q) : null;
	if (rest !== null) { q = rest; }
	if (!q) { assistantChatAdd(panel, 'step', 'Yes?'); assistantConversationListen(panel); return; }
	panel.find('.assistant_question').val('');
	assistantButtonLabel(panel);
	assistantOpenPanel(panel);
	assistantChatAdd(panel, 'user', q);
	assistantRemember(panel, 'user', q);
	assistantGuideStep(panel, 0);
}

// A dropped picture (or voice clip) goes to the assistant; its answer streams
// into the chat bubble the same way the mailbox one does.
function assistantDrop(panel, media) {
	media = media || {};
	assistantOpenPanel(panel);
	if (media.image) {
		var log = assistantLog(panel);
		log.append($('<div style="display:flex;margin:4px 0;justify-content:flex-end;">'
			+ '<span style="display:inline-block;max-width:84%;border-radius:10px;padding:5px;background:#cdeccd;">'
			+ '<img style="display:block;max-width:180px;max-height:180px;border-radius:6px;" src="' + media.image + '"></span></div>'));
		log.scrollTop(log[0].scrollHeight);
		assistantRemember(panel, 'user', '(I showed you a picture)');
	}
	else if (media.audio) {
		assistantChatAdd(panel, 'user', '(voice clip)');
		assistantRemember(panel, 'user', '(I played you a voice clip)');
	}
	var content = assistantAnswerBubble(panel);
	$.ajax({
		url: '/manager/assistant',
		type: 'POST',
		data: { image: media.base64, audio: media.audio },
		success: function (response) {
			if (response && response.uuid) { content.attr('uuid', response.uuid); }
			content.text('…');
		},
		error: function () { content.text('I could not reach the assistant.'); }
	});
}

// What the assistant was dragged onto, spelled out for the guide: the element, any
// hint or id it carries, and the app or window it lives in.
function assistantDescribeElement(el) {
	var $e = $(el);
	if (!$e.length || el === document.body || el === document.documentElement) { return ''; }
	var bits = [];
	bits.push((el.tagName || '').toLowerCase());
	if ($e.attr('id')) { bits.push('#' + $e.attr('id')); }
	if (typeof el.className == 'string' && el.className.trim()) { bits.push('.' + el.className.trim().split(/\s+/).slice(0, 3).join('.')); }
	var hint = $e.attr('hint') || $e.attr('title') || $e.attr('aria-label') || $e.attr('placeholder');
	if (hint) { bits.push('(hint: ' + hint + ')'); }
	var label = $.trim($e.closest('label').text());
	if (label) { bits.push('label: "' + label.slice(0, 60) + '"'); }
	var app = $e.closest('[app]').attr('app');
	if (app) { bits.push('app: "' + app + '"'); }
	var win = $.trim($e.closest('.wind').find('.name_text').first().text());
	if (win) { bits.push('window: "' + win + '"'); }
	var text = $.trim($e.text()).slice(0, 80);
	if (text) { bits.push('text: "' + text + '"'); }
	return bits.join(' ');
}

// Dropped onto a control or a window (not a picture): ask the guide about it,
// carrying the thread on so it remembers what came before.
function assistantHelpFor(panel, el) {
	var desc = assistantDescribeElement(el);
	assistantOpenPanel(panel);
	if (!desc) {
		assistantChatAdd(panel, 'step', 'Drop me onto a control or a window and I will explain it.');
		return;
	}
	// the element may name a help topic; hand it over so the guide has the briefing
	panel.data('topic', $(el).closest('[help]').attr('help') || '');
	assistantChatAdd(panel, 'user', 'Help me with: ' + desc);
	assistantRemember(panel, 'user', 'The person dragged me onto this element and wants help using it: ' + desc);
	assistantGuideStep(panel, 0);
}

$(document).on('click', '.assistant_send', function () { assistantAsk($(this).closest('.assistant_view')); });
$(document).on('input', '.assistant_question', function () { if (typeof assistantButtonLabel === 'function') { assistantButtonLabel($(this).closest('.assistant_view')); } });
$(function () { $('.assistant_view').each(function () { assistantButtonLabel($(this)); }); });
$(document).on('keydown', '.assistant_question', function (e) {
	if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); assistantAsk($(this).closest('.assistant_view')); }
});
$(document).on('click', '.assistant_new', function () { assistantSpawn($(this).closest('.assistant_view')); });
$(document).on('mousedown', '.assistant_view', function () { jawnos_assistant_last = $(this); });
$(document).on('click', '#assistant', function () {
	if (jawnos_assistant_dragging) { return; }
	// wait out a second press: a double-press asks for the agents list (agents.js),
	// and only a lone press should open the chat panel itself
	clearTimeout(jawnos_assistant_click_timer);
	jawnos_assistant_click_timer = setTimeout(function () { assistantOpen(); }, 260);
});

// Another associate: a clone of an open one, with its own conversation name and
// thread. Spawned panels are taken away by close; the taskbar's own stays.
function assistantSpawn(source) {
	source = (source && source.length) ? source : $('.assistant_view').first();
	if (!source.length) { return $(); }
	var name;
	do {
		jawnos_assistant_extra += 1;
		name = 'assistant_' + jawnos_assistant_extra;
	} while ($('.assistant_view[conversation="' + name + '"]').length);
	var clone = source.clone();
	clone.attr('id', '').attr('conversation', name).attr('spawned', '1');
	clone.data('thread', []).data('greeted', 0).data('title', '');
	clone.find('.assistant_chat_log').empty();
	clone.find('.assistant_staged_panel').hide();
	clone.find('.assistant_chat_log, .assistant_input_row').show();
	clone.find('.assistant_config_menu').hide();
	clone.find('.assistant_title').text('Guide\'s associate ' + jawnos_assistant_extra);
	clone.removeAttr('drag_armed');
	clone.find('.assistant_anchor').removeAttr('icon_armed').removeClass('ui-draggable ui-draggable-disabled ui-draggable-handle ui-draggable-dragging');
	var off = (jawnos_assistant_extra % 6) * 26;
	clone.css({ display: 'none', right: '', bottom: '', left: Math.max(6, (source.offset().left || 40) + 30 + off) + 'px', top: Math.max(6, (source.offset().top || 40) + 30 + off) + 'px' });
	$(document.body).append(clone);
	assistantInitializer();
	assistantButtonLabel(clone);
	clone.find('.assistant_question').focus();
	assistantChatAdd(clone, 'step', 'A fresh associate — this one keeps its own thread.');
	assistantOpenPanel(clone);
	return clone;
}

// Re-open a conversation from the agents list (or start its panel if none is
// open): the remembered turns are fetched and replayed into the log.
function assistantOpenConversation(name, title) {
	var existing = $('.assistant_view[conversation="' + name + '"]');
	if (existing.length) { return assistantOpenPanel(existing.first()); }
	var panel = assistantSpawn($('.assistant_view').first());
	if (!panel.length) { return $(); }
	panel.attr('conversation', name).data('title', title || '').data('greeted', 1);
	panel.find('.assistant_chat_log').empty();
	panel.data('thread', []);
	assistantTitleShow(panel);
	$.get('/manager/agents/thread', { kind: 'guide', name: name }, function (r) {
		var transcript = (r && r.transcript) || [];
		panel.data('thread', transcript);
		if (r && r.title) { panel.data('title', r.title); assistantTitleShow(panel); }
		var log = assistantLog(panel);
		if (!transcript.length) { assistantChatAdd(panel, 'step', 'Nothing was said here yet.'); return; }
		var shown = 0;
		transcript.forEach(function (m) {
			var role = m.role || 'user';
			var content = String(m.content || '');
			if (role === 'user') { assistantChatAdd(panel, 'user', content); shown++; }
			else if (role === 'assistant' && !/^\s*\{/.test(content)) { assistantChatAdd(panel, 'guide', content); shown++; }
		});
		if (!shown) { assistantChatAdd(panel, 'step', 'Nothing was said here yet.'); }
		log.scrollTop(log[0] ? log[0].scrollHeight : 0);
	});
	return panel;
}

// The window is armed once per panel: it drags by its header, and every panel
// wears the same classes, so one arm covers the ones spawned later too.
function assistantInitializer() {
	$('.assistant_view:not([drag_armed])').each(function () {
		var panel = $(this);
		panel.attr('drag_armed', '1');
		panel.draggable({
			revert: 'false',
			handle: '.assistant_header',
			cancel: '.assistant_anchor, .assistant_new, .assistant_close, .assistant_config, .assistant_confirm, .assistant_staged_open, input, button, label, textarea',
			drag: function (e, ui) {
			// keep the panel on screen and clear of the taskbar, wherever it is dragged
			var w = $(this).outerWidth(), h = $(this).outerHeight();
			var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
			ui.position.left = Math.max(0, Math.min(ui.position.left, $(window).width() - w));
			ui.position.top = Math.max(0, Math.min(ui.position.top, $(window).height() - h - bar));
			}
		});

		assistantIconInitializer();
	});

	assistantIconInitializer();
}

// The assistant's own button rides in the start menu, which the socket fetches
// anew on every open, so the drag is armed once at load for the copy the page
// ships with and again over there after each fetch.
function assistantIconInitializer() {
	// the start-menu button, its taskbar pin, and each panel's own corner icon:
	// drag any of them onto something and the guide looks at whatever is under
	// the pointer (the panels' copies are excluded from the panel-move handle
	// above). Armed once per element - the taskbar re-lays its pins and the
	// start menu refetches, so a fresh copy arrives unarmed.
	$('#assistant:not([icon_armed]), .assistant_anchor:not([icon_armed]), .taskbar_pin[sel$="#assistant"]:not([icon_armed])').each(function () {
		$(this).attr('icon_armed', '1');
		$(this).draggable({
			appendTo: "body",
			helper: "clone",
			revert: "invalid",
			zIndex: 999999,
			cursorAt: { top: 30, left: 30 },
			cancel: '',
			start: function(p,ui) {
				jawnos_assistant_dragging = true;
			},
			drag: function(p,ui) {
				ui.position.left = p.pageX - 30;
				ui.position.top = p.pageY - 30;
			},
			stop: function(p,ui) {
				setTimeout(function () { jawnos_assistant_dragging = false; }, 0);
				$(this).css('opacity', '1');
				
				// 2. Find what the cursor is over - skipping the drag clone and the panel
				// itself, which sit under the pointer and would otherwise answer
				var dropX = p.clientX;
				var dropY = p.clientY;
				var stack = document.elementsFromPoint(dropX, dropY) || [];
				var elementLandedOn = null;
				for (var si = 0; si < stack.length; si++) {
					var cand = stack[si];
					if (cand === document.body || cand === document.documentElement) { continue; }
					if ($(cand).closest('.assistant_view, .ui-draggable-dragging').length) { continue; }
					elementLandedOn = cand;
					break;
				}
				if (!elementLandedOn) { elementLandedOn = stack[stack.length - 1] || document.body; }
				var $target = $(elementLandedOn);
				console.log('Landed on:', elementLandedOn, 'ID:', $target.attr('id'), 'Class:', $target.attr('class'));
				var base64Data;
				// Set a maximum bound for width or height (Qwen handles 400px - 600px beautifully)
				var maxDimension = 600; 
				var image;
				var audio;
				if ($target.is('img')) {
					console.log('this is an image');
					var imgElement = $target[0]; // Get raw DOM element
					
					var origWidth = imgElement.naturalWidth || imgElement.width;
					var origHeight = imgElement.naturalHeight || imgElement.height;
					
					// Calculate new scaled dimensions
					var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
					var newWidth = origWidth * scale;
					var newHeight = origHeight * scale;

					var canvas = document.createElement('canvas');
					canvas.width = newWidth;
					canvas.height = newHeight;
					
					var ctx = canvas.getContext('2d');
					ctx.drawImage(imgElement, 0, 0, newWidth, newHeight);
					image = canvas.toDataURL('image/png');
					base64Data = image.split(',')[1];
					console.log('Downsized Image Base64 ready');

				} else if ($target.is('canvas')) {
					console.log('this is a canvas');
					var canvasElement = $target[0];
					
					var origWidth = canvasElement.width;
					var origHeight = canvasElement.height;
					
					var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
					var newWidth = origWidth * scale;
					var newHeight = origHeight * scale;

					// Create a temporary downsized canvas
					var tempCanvas = document.createElement('canvas');
					tempCanvas.width = newWidth;
					tempCanvas.height = newHeight;
					
					var ctx = tempCanvas.getContext('2d');
					ctx.drawImage(canvasElement, 0, 0, newWidth, newHeight);
					image = tempCanvas.toDataURL('image/png');
					base64Data = image.split(',')[1];
					console.log('Downsized Canvas Base64 ready');

				} else if ($target.is('video')) {
					console.log('this is a video snapshot');
					var videoElement = $target[0];
					
					var origWidth = videoElement.videoWidth || videoElement.width || 600;
					var origHeight = videoElement.videoHeight || videoElement.height || 400;
					
					var scale = Math.min(maxDimension / origWidth, maxDimension / origHeight, 1);
					var newWidth = origWidth * scale;
					var newHeight = origHeight * scale;
					
					var canvas = document.createElement('canvas');
					canvas.width = newWidth;
					canvas.height = newHeight;
					
					var ctx = canvas.getContext('2d');
					ctx.drawImage(videoElement, 0, 0, newWidth, newHeight);
					image = canvas.toDataURL('image/png');
					base64Data = image.split(',')[1];
					console.log('Downsized Video Snapshot Base64 ready');
				} else if ($target.is('audio')) {
					audio = $target.attr('src');
				}
				
				if (image || audio) {
					assistantDrop(assistantPanel(this), { image: image, base64: base64Data, audio: audio });
				}
				else {
					// not a picture: ask the guide about whatever it landed on
					assistantHelpFor(assistantPanel(this), elementLandedOn);
				}

			}
		});
	});
	});
}

// The taskbar rebuilds its pins whenever the order changes, so re-arm the
// assistant's drag each time it lays them out (a pinned assistant is a
// .taskbar_pin with sel="#start_menu #assistant").
$(function () {
	if (typeof jawnosTaskbarOrderApply == 'function') {
		var base = jawnosTaskbarOrderApply;
		jawnosTaskbarOrderApply = function () {
			var r = base.apply(this, arguments);
			assistantIconInitializer();
			return r;
		};
	}
});

$(document).on('click dblclick mouseenter mouseleave keydown keyup change submit focus blur input', function(e) {
	nfcListener();
});

function nfcInitializer() {
	if (nfc['initialized'] == false) {
		nfc['initialized'] = true;
		nfc['ndef'].addEventListener("readingerror", () => {
		});
		nfc['abort'].signal.onabort = function() {
			nfc['scanning'] = false;
		};
		nfc['ndef'].addEventListener("reading", ({ message, serialNumber }) => {

			var md = [];
			$.each(message.records, function(i,record) {
				if (record.recordType === "text" || record.recordType === "url") {
					// 6. Decode the binary DataView payload into a string
					const textDecoder = new TextDecoder(record.encoding || "utf-8");
					const decodedString = textDecoder.decode(record.data);
					md.push({'text': decodedString });
				}
			if (record.mediaType === "application/json") {
					const decoder = new TextDecoder();
					const json = JSON.parse(decoder.decode(record.data));
					md.push(json);
			}
			});

			var jmessage = JSON.stringify(md);
			var timestamp = Date.now();
			var lastWrite = nfc['lastWrite'];

			$.ajax({
				url: '/manager/nfc/read',
				type: 'POST',
				data: { message: jmessage, serial: serialNumber, last_write: lastWrite, timestamp: timestamp, benign: nfc['benign'] },
				success: function(response) {
					var jr = JSON.stringify(response);

					$('.nfc_read_status').text(response.status);
					setTimeout(function() {
						$('.nfc_read_status').text('');
					},10000);
				// alert('reading tag ' + jr);
				}
			});
		});
	}
}

$(document).on('click', '.nfc_benign_reader', function() {
	var nb = $(this);
	var enabled = nb.attr('enabled');
	clearTimeout(nfc['benignTimeout']);
	if (enabled == 'on') {
		nfc['benign'] = 'off';
	}
	else {
		nfc['benign'] = 'on';
		nfc['benignTimeout'] = setTimeout(function() {
			nfc['benign'] = 'off';
			nb.attr('enabled', nfc['benign']);
		},10000);
	}
	nb.attr('enabled', nfc['benign']);
});

async function nfcListener() {
	if (nfc['ndef'] && nfc.scanning == false && nfc.writing == false) {

		try {
			nfc.scanning = true;
			nfc['abort'] = new AbortController();
			nfc['ndef'].scan({ signal: nfc['abort'].signal }).then(() => {
			}).catch(error => console.log(error));
		} catch {
			nfc.scanning = false;
		}
	}
}

async function nfcWriter(msg,a) {
	if (device == 'mobile') {
		if (nfc.scanning == true) {
			nfc.scanning = false;
			nfc.abort.abort();
			nfc['writing'] = true;
			setTimeout(function() {
				nfcWriter(msg,a);
			},1000);
		} else {
			try {
				a.addClass('active_background');
				nfc['writing'] = true;
				nfc.scanning = false;
				const encoder = new TextEncoder();
				$.ajax({
					url: '/manager/nfc/write',
					type: 'POST',
					data: msg,
					success: function(response) {
						msg = encoder.encode(JSON.stringify(response.nfc));
						nfc['ndef'].write({
							records: [{
								recordType: 'mime',
								mediaType: 'application/json',
								data: msg
							}] }).then(() => {
							nfc['lastWrite'] = Date.now();
							nfc['writing'] = false;
							nfc['scanning'] = false;
							a.removeClass('active_background');
						nfcListener();
					});
					}
				});

			} catch (error) {
			}
		}
	}
}


$(document).on('click', 'input',function() {
	focused_input.removeClass('focused_input');
});
