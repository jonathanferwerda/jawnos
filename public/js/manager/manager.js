var nfc = {
	scanning: false,
	writing: false,
	abort: new AbortController(),
	initialized: false
};
var assistant = {};
if (typeof jawnNfcAvailable === 'function' && jawnNfcAvailable()) {
	nfc['ndef'] = jawnNfcMake();
	nfcInitializer();
}
else { nfc['ndef'] = undefined; }

// The app's own camera (window.JawnCamera): mark the document so the native
// camera/video buttons render (appointment_wrapper keys its CSS off this class).
// Done at load, not on ready: a browser never sets it, and later-inserted
// appointment markup still inherits the rule.
if (typeof jawnCameraAvailable === 'function' && jawnCameraAvailable()) {
	document.documentElement.classList.add('jawn-app');
}

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
// the menu's html per tab, so reopening a tab does not fetch (and re-stamp) it
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

// Pressing a control in the associate's header must never begin a drag: the
// header is the drag handle, and a press that started one swallowed the click
// (the close button dragged instead of closing).
$(document).on('mousedown pointerdown touchstart', '.assistant_header .assistant_close, .assistant_header .assistant_config, .assistant_header .assistant_new, .assistant_header .assistant_anchor', function (e) {
	e.stopPropagation();
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

// Its own tick for deletes: deleting is worth asking about even when the person has
// turned the save-confirmation off, so it keeps a separate switch.
$(document).on('change', '.assistant_confirm_delete', function() {
	var on = $(this).is(':checked');
	$('.assistant_confirm_delete').prop('checked', on);
	settingSetter({ app: '__president', setting: 'guide_confirm_delete', device: 'all', value: on ? 'on' : 'off' });
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
function assistantConfirmDeleteRequired() {
	var box = $('.assistant_confirm_delete');
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

// A stored duration is a negative accrual in ms (a start/stop pair writes
// start - stop); show the length it stands for rather than the raw sign.
function assistantStagedDuration(ms) {
	var n = Math.abs(parseInt(ms, 10)) || 0;
	if (!n) { return ''; }
	var mins = Math.round(n / 60000);
	if (mins < 60) { return mins + ' min'; }
	var h = Math.floor(mins / 60), m = mins % 60;
	return h + 'h' + (m ? (' ' + m + 'm') : '');
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
		var item = $('<div class="assistant_staged_row" style="display:flex;align-items:center;gap:6px;padding:7px 2px;border-bottom:1px solid var(--line);"></div>')
			.attr('uuid', row.uuid)
			.attr('staged_title', row.title || row.app || '');
		var text = $('<div style="flex:1;min-width:0;overflow-wrap:break-word;"></div>');
		var kind = row.kind || 'create';
		var prefix = kind === 'update' ? 'Change: ' : (kind === 'delete' ? 'Delete: ' : '');
		text.append($('<div></div>').text(prefix + (row.title || '(an appointment)')));
		var meta = (kind === 'update' ? 'change — ' : (kind === 'delete' ? 'delete — ' : '')) + assistantStagedWhen(row) + (row.app ? ' — ' + row.app : '');
		if (kind === 'create' && row.type && row.type !== 'usual') { meta += ' · ' + row.type; }
		var lasted = assistantStagedDuration(row.duration);
		if (lasted) { meta += ' · lasts ' + lasted; }
		text.append($('<div class="chat_meta"></div>').text(meta));
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
		if (r.kind === 'update') { assistantChatAdd(panel, 'step', 'Changed: ' + (r.summary || title) + '.'); }
		else if (r.kind === 'delete') { assistantChatAdd(panel, 'step', 'Deleted: ' + (r.summary || title) + '.'); }
		else { assistantChatAdd(panel, 'step', 'Saved the staged “' + title + '”.'); }
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
		var bubble = '<span class="chat_bubble" style="display:inline-block;max-width:84%;overflow-wrap:break-word;border-radius:10px;padding:6px 10px;'
			+ (mine ? 'background:#cdeccd;' : 'background:#cfe3f5;') + '">' + safe + '</span>';
		log.append($('<div style="display:flex;margin:4px 0;' + (mine ? 'justify-content:flex-end;' : 'justify-content:flex-start;') + '">' + bubble + '</div>'));
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

// ---- floating panels remember where they were -------------------------------
// The Guide's associate, the Coding agents and the Agents list float over the
// whole screen and drag by their header. A panel that has been moved keeps its
// place in the app's window_places store - the one the windows use, so it rides
// the debrief and comes back after a restart, not only a refresh. A panel never
// moved has no place stored and keeps the spot its opener chooses: the
// associate's corner, the coding panel's right/bottom default, the list's anchor
// to its button.
function jawnosPanelPosSave(key, panel) {
	if (!key || !panel || !panel.length) { return; }
	var left = parseFloat(panel.css('left')), top = parseFloat(panel.css('top'));
	if (isNaN(left) || isNaN(top)) { return; }
	jawnosPanelSpotSet(key, JSON.stringify({ left: Math.round(left), top: Math.round(top) }));
}
function jawnosPanelPosRestore(key, panel) {
	if (!key || !panel || !panel.length) { return false; }
	var raw = (typeof jawnosPanelSpotGet === 'function') ? jawnosPanelSpotGet(key) : null;
	if (!raw) { return false; }
	var s = null;
	try { s = JSON.parse(raw); } catch (e) { return false; }
	if (!s || typeof s.left !== 'number' || typeof s.top !== 'number') { return false; }
	// keep it on screen if the window has since shrunk; a hidden panel has no box
	// to measure, and a zero width simply leaves the stored spot alone
	var w = panel.outerWidth() || 0, h = panel.outerHeight() || 0;
	var bar = (typeof jawnosTaskbarHeight === 'function') ? jawnosTaskbarHeight() : 0;
	var left = Math.max(0, Math.min(s.left, $(window).width() - w));
	var top = Math.max(0, Math.min(s.top, $(window).height() - h - bar));
	panel.css({ left: left + 'px', top: top + 'px', right: 'auto', bottom: 'auto' });
	return true;
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
		if (!jawnosPanelPosRestore('guide:' + (panel.attr('conversation') || 'assistant'), panel)) {
			var w = panel.outerWidth(), h = panel.outerHeight();
			var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
			var left = Math.max(6, Math.min($(window).width() - w - 16, $(window).width() - w - 16));
			var top = Math.max(6, Math.min($(window).height() - h - 70, $(window).height() - h - bar - 6));
			panel.css({ left: left + 'px', top: top + 'px', right: '', bottom: '' });
		}
		panel.css('visibility', '');
	}
	panel.css('z-index', ++jawnos_assistant_top);
	jawnos_assistant_last = panel;
	return panel;
}

function assistantOpen() { return assistantOpenPanel(assistantPanel()); }

// Open a fresh Guide associate scoped to one app: its conversation is kept under
// the app's own name (app_<name>), so the thread comes back next time the ? is
// pressed in that window, and each turn expires on the app's warranty.
function assistantAppOpen(app) {
	var name = 'app_' + (app || 'window');
	return assistantOpenConversation(name, (app || 'Window'));
}

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
	// "bye jawn" ends a conversation; there is no wake phrase to open one - an
	// empty Ask opens the mic and keeps listening between answers.
	if (typeof helpConversationBye === 'function' && helpConversationBye(q)) {
		input.val('');
		assistantButtonLabel(panel);
		if (assistantTalking(panel)) { assistantConversationEnd(panel); }
		return;
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
	else { b.text('Converse').css({ 'border-color': 'var(--line)', 'color': '' }).attr('hint', 'Start a spoken conversation: the mic opens again after each answer, so you can just keep talking — say “bye jawn” or press End to stop'); }
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

// the panel's own last words, so a conversation's mic can tell the speaker from
// the person
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

// What the assistant was dragged onto, spelled out for the guide: the element,
// any hint or id it carries, and the app or window it lives in.
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
// thread. Spawned panels are taken away by their close; the taskbar's own stays.
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
	if (!panel.length) { return panel; }
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
			// a few pixels of travel before a drag begins (with the touch threshold in
			// touch-threshold.js), so a tap never moves the panel
			distance: 8,
			cancel: '.assistant_anchor, .assistant_new, .assistant_close, .assistant_config, .assistant_confirm, .assistant_confirm_delete, .assistant_staged_open, input, button, label, textarea',
			drag: function (e, ui) {
				// keep the panel on screen and clear of the taskbar, wherever it is dragged
				var w = $(this).outerWidth(), h = $(this).outerHeight();
				var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
				ui.position.left = Math.max(0, Math.min(ui.position.left, $(window).width() - w));
				ui.position.top = Math.max(panelTopLimit(), Math.min(ui.position.top, $(window).height() - h - bar));
			},
			stop: function () {
				// the clothesline holds the top back on every device
				var p = $(this);
				var top = parseFloat(p.css('top'));
				if (!isNaN(top) && top < panelTopLimit()) { p.css({ 'top': panelTopLimit() + 'px' }); }
				jawnosPanelPosSave('guide:' + (p.attr('conversation') || 'assistant'), p);
			}
		});
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
			// the button is both a tap (open the associate) and a drag (drop it on a
			// picture): a little travel before a drag begins keeps a tap a tap (with the
			// touch threshold in touch-threshold.js)
			distance: 10,
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

// ---- Web NFC over the app's native bridge -----------------------------
// Chrome for Android ships NDEFReader; a plain WebView does not, so the app
// injects window.JawnNFC (JawnNfcBridge, its NfcAdapter reader-mode bridge) and
// jawnNfcAdapter() presents the same NDEFReader surface over it. The scan and
// write call sites below are then identical either way.
function jawnNfcAvailable() {
	if ('NDEFReader' in window) return true;
	return !!(window.JawnNFC && window.JawnNFC.available() === 'yes');
}
function jawnNfcMake() {
	// The app's own bridge (window.JawnNFC, Android reader mode) is preferred:
	// a Chromium WebView now exposes NDEFReader too, but the app cannot grant
	// the WebView's Web NFC the way it grants its bridge, so prefer the one we
	// drive. Chrome has no window.JawnNFC, so there the native NDEFReader wins.
	if (window.JawnNFC && window.JawnNFC.available() === 'yes') return jawnNfcAdapter();
	if ('NDEFReader' in window) return new NDEFReader();
	return jawnNfcAdapter();
}
function jawnNfcBase64ToBytes(b64) {
	var bin = atob(b64 || '');
	var out = new Uint8Array(bin.length);
	for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
	return out;
}
function jawnNfcBytesToBase64(bytes) {
	var b = new Uint8Array(bytes || []);
	var bin = '';
	for (var i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
	return btoa(bin);
}
function jawnNfcAdapter() {
	var handlers = { reading: [], readingerror: [] };
	var pendingWrite = null;
	function dispatch(type, ev) {
		$.each(handlers[type] || [], function(i, cb) { try { cb(ev); } catch (e) {} });
	}
	// the app calls this from the native side with the tag it saw
	window.__jawnNfcEvent = function(type, payload) {
		payload = payload || {};
		if (type === 'reading') {
			var records = $.map(payload.records || [], function(r) {
				return { recordType: r.recordType, mediaType: r.mediaType, encoding: r.encoding, data: jawnNfcBase64ToBytes(r.data) };
			});
			dispatch('reading', { message: { records: records }, serialNumber: payload.serial });
		}
		else if (type === 'readingerror') { dispatch('readingerror', {}); }
		else if (type === 'write') {
			var w = pendingWrite;
			pendingWrite = null;
			if (w) { payload.ok ? w.resolve() : w.reject(new Error(payload.error || 'write failed')); }
		}
	};
	return {
		addEventListener: function(type, cb) { if (handlers[type]) handlers[type].push(cb); },
		scan: function(options) {
			options = options || {};
			var signal = options.signal;
			var result = window.JawnNFC.startScan();
			return new Promise(function(resolve, reject) {
				if (result !== 'ok') { reject(new Error('nfc scan: ' + result)); return; }
				if (signal) {
					var stop = function() { window.JawnNFC.stopScan(); };
					if (signal.aborted) { stop(); reject(new DOMException('AbortError', 'AbortError')); return; }
					signal.addEventListener('abort', stop);
				}
				resolve();
			});
		},
		write: function(message) {
			var records = $.map(message.records || [], function(r) {
				return { recordType: r.recordType, mediaType: r.mediaType, encoding: r.encoding, data: jawnNfcBytesToBase64(r.data) };
			});
			return new Promise(function(resolve, reject) {
				pendingWrite = { resolve: resolve, reject: reject };
				var result = window.JawnNFC.write(JSON.stringify({ records: records }));
				if (result !== 'ok') { pendingWrite = null; reject(new Error('nfc write: ' + result)); }
			});
		}
	};
}

// ---- the app's own camera (window.JawnCamera) ------------------------
// The app opens the OS camera or the OS video recorder; it hands the file
// back as base64 over window.__jawnCameraResult, which is posted to the
// ordinary upload route - the route files an image/video and creates the
// appointment for the app, exactly as the termux camera path does.
function jawnCameraAvailable() {
	return !!(window.JawnCamera && window.JawnCamera.available && window.JawnCamera.available() === 'yes');
}
function jawnCameraUpload(result) {
	var pending = window.__jawnCameraPending || {};
	window.__jawnCameraPending = null;
	var status = pending.status;
	var setStatus = function (text) { if (status) { $(status).text(text); } };
	if (!result || !result.ok || !result.data) {
		setStatus(result && result.error && result.error !== 'cancelled' ? ('Capture failed: ' + result.error) : '');
		return;
	}
	var kind = result.kind === 'video' ? 'video' : 'image';
	var ext = kind === 'video' ? '.mp4' : '.jpg';
	var bin = atob(result.data);
	var bytes = new Uint8Array(bin.length);
	for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
	var blob = new Blob([bytes], { type: result.mime || (kind === 'video' ? 'video/mp4' : 'image/jpeg') });
	var formData = new FormData();
	formData.append('app', pending.app || '');
	formData.append('timestamp', Date.now());
	formData.append('type', kind);
	formData.append('blob', blob, (pending.app || 'capture') + ext);
	$.ajax({
		url: '/manager/upload_file',
		type: 'POST',
		data: formData,
		success: function(response) {
			setStatus('Saved.');
			continent_record({ uuid: response.uuid, app: response.app, timestamp: response.timestamp });
			if (pending.app === 'camera' && typeof jawnCameraAppPool === 'function') { jawnCameraAppPool(); }
		},
		error: function() { setStatus('Upload failed.'); },
		cache: false,
		contentType: false,
		processData: false
	});
}
// the app calls this from the native side with the file it captured
window.__jawnCameraResult = function(result) { jawnCameraUpload(result); };

// ---- the app's launch extras (window.__jawnLaunchExtras) --------------
// The system's sms send and dial intents open the app with jawn_sms_number /
// jawn_sms_body / jawn_dial_number extras; the native side hands them here once
// the page is up. A share-to-sms opens that number's conversation with the body
// prefilled; a dial intent opens the Phone app with the number on the pad.
window.__jawnLaunchExtras = function(extras) {
	extras = extras || {};
	var run = function() {
		if (extras.sms_number) { jawnLaunchSms(extras.sms_number, extras.sms_body || ''); }
		else if (extras.dial_number) { jawnLaunchDial(extras.dial_number); }
	};
	var tries = 0;
	var ready = function() { return typeof windowMaker === 'function' && window.jQuery; };
	if (ready()) { run(); return; }
	var t = setInterval(function() {
		tries++;
		if (ready() || tries > 120) { clearInterval(t); if (tries <= 120) { run(); } }
	}, 500);
};
function jawnLaunchSms(number, body) {
	localStorage.setItem('mail_contact', '');
	localStorage.setItem('mail_phone', number);
	$.ajax({
		url: '/manager/chat',
		type: 'GET',
		data: {
			timestamp: Date.now(),
			window_maker: 'yes',
			phone: number,
			incoming_data: JSON.stringify({ settings: [{ setting: 'subsection', value: 'sms' }] })
		},
		success: function(response) {
			windowMaker(response);
			var w = $('.wind[app="chat"]');
			if (body) { w.find('#message').val(body); }
			w.find('#mail_transport').val('sms');
			if (typeof chatTransportOptions === 'function') { chatTransportOptions(); }
			if (typeof mailWebSocketStart === 'function') { mailWebSocketStart(); }
			if (typeof mailScrollBottom === 'function') { mailScrollBottom('load'); }
		}
	});
}
function jawnLaunchDial(number) {
	$.ajax({
		url: '/manager/phone',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function(response) {
			windowMaker(response);
			setTimeout(function() {
				var w = $('.wind[app="phone"]');
				if (typeof jawnPhoneApp !== 'undefined' && jawnPhoneApp) { jawnPhoneApp.number = number; }
				w.find('#phone_app_display').text(number);
				w.find('.phone_app_tab[pane="dial"]').trigger('click');
			}, 500);
		}
	});
}
$(document).on('click', '.native_capture, .native_video', function() {
	if (!jawnCameraAvailable()) { return; }
	var b = $(this);
	var app = b.attr('app') || b.closest('.appointment').attr('app');
	window.__jawnCameraPending = { app: app };
	if (b.hasClass('native_video')) { window.JawnCamera.video(); }
	else { window.JawnCamera.photo(b.attr('capture') || '0'); }
});

// ---- the house's phone facts (window.JawnPhone) -------------------------
// A call arrives when no page is open, so what the native half needs is handed
// to it and kept: the desk's blacklist (the CallScreeningService turns a listed
// caller away before the phone rings) and the house's numbers by name (the
// in-call screen names the caller). The calls it refused are picked up here and
// filed, so an ignored call still shows in the log. Refreshed on load and every
// few minutes; a browser has no window.JawnPhone and nothing happens.
function jawnPhoneSync() {
	if (!window.JawnPhone) { return; }
	if (typeof window.JawnPhone.setFacts === 'function') {
		$.ajax({
			url: '/manager/phone/sync',
			type: 'GET',
			data: { timestamp: Date.now() },
			success: function(response) {
				try {
					window.JawnPhone.setFacts(JSON.stringify({
						blocked: (response && response.blocked) || [],
						names: (response && response.names) || {},
						avatars: (response && response.avatars) || {}
					}));
				} catch (e) { }
			}
		});
	}
	if (typeof window.JawnPhone.takeBlockedCalls === 'function') {
		var calls = [];
		try { calls = JSON.parse(window.JawnPhone.takeBlockedCalls()) || []; } catch (e) { calls = []; }
		$.each(calls, function(i, c) {
			$.ajax({
				url: '/manager/phone/call',
				type: 'POST',
				data: { event: 'ignore', number: (c && c.number) || '', timestamp: (c && c.at) || Date.now() }
			});
		});
	}
	// the app's own record of the calls it saw (jawnPhoneAppFileCalls, phone.js):
	// a call taken with no page up leaves one, and this is where it is filed
	if (typeof jawnPhoneAppFileCalls === 'function') { jawnPhoneAppFileCalls(); }
}
if (window.JawnPhone) {
	jawnPhoneSync();
	setInterval(jawnPhoneSync, 300000);
}

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
					if (response && response.crest_uuid && typeof peopleCrestOpen === 'function') {
						peopleCrestOpen(response.crest_uuid);
					}
					setTimeout(function() {
						$('.nfc_read_status').text('');
					},10000);
				//	alert('reading tag ' + jr);
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
//	focused_input.css({'background-image': '' });
//	focused_input.trigger('change');
	focused_input = $(this);
//	focused_input.addClass('focused_input');

	if ($('#numberpad').is(':visible') || $('#keyboard').is(':visible')) {
		focused_input.blur();
	}
});
$(document).on('click', 'textarea',function() {
	focused_input = $(this);

	if ($('#numberpad').is(':visible') || $('#keyboard').is(':visible')) {
		focused_input.blur();
	}
});

$(document).on('click', '.app_act', function() {
	clearTimeout(searchTimeout);
});
var searchTimeout;

$(document).on('dblclick', 'input', function(i,e) {
	var s = $('#search');
	var search = s.val();
	if (search == '') {
		clipboardGetter(s);
	}
	else {
		clipboardSetter(search);
	}

	s.val('');
});

async function clipboardGetter(s) {
	$.ajax({
		url: '/manager/clipboard_getter',
		type: 'GET',
		success: function(response) {
			s.val(response);
		}
	});
}

$(document).on('click', '.clip', function() {
	clipboardSetter(clip);
});

function clipboardSetter(clip) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/clipboard_setter',
		type: 'POST',
		data: { timestamp: timestamp, clipboard: clip },
		success: function(response) {

		}
	});
}

$(document).on('change', '.volume_control', function(e) {

	var control = $(this);
	var stream = control.attr('stream');
	var volume = control.val();
	var max_volume = control.attr('max');

	var total_width = control.width();
  var current_location = e.offsetX;

	control.val(volume);
	var timestamp = Date.now();
	var device = localStorage.getItem('volume_control_device');
	var data = { stream: stream, volume: volume, max: max_volume, device: device };
	$.ajax({
		url: '/manager/volume_control',
		type: 'GET',
		data: data,
		success: function(response) {
		 volumeChecker();
		}
	});

});

function volumeChecker() {
	var device = localStorage.getItem('volume_control_device');
	$.ajax({
		url: '/manager/volume_control',
		type: 'GET',
		data: { device: device },
		success: function(response) {
			var writer = '';
			$.each(response.volumes, function(i,v) {
				writer += '<b>' + v['stream'] + '</b><input type="range" style="width:60%;" class="volume_control" stream="' + v['stream'] + '" value="' + v['volume'] + '" max="' + v['max_volume'] + '"><br>';
			});
			$('#device_volume_control').html(writer);

			$.each(response.remote_machines, function(i,rm) {
				$('#device_volume_control').prepend('<span class="volume_control_device hover" device="' + rm.uuid + '"><b>' + rm.fqdn + '</b></span><br>');
			});

			$('#device_volume_control').prepend('<span class="volume_control_device hover" device="local"><b>Local</b></span><br>');
			$('.volume_control_device[device="' + device + '"]').addClass('selected');
		}
	});
}

$(document).on('click', '.volume_control_device', function() {
	$('.volume_control_device').removeClass('selected');
	$(this).addClass('selected');
	var device = $('.volume_control_device.selected').attr('device');
	localStorage.setItem('volume_control_device', device);
	volumeChecker();
});


$(document).on('click', '#cards_toggle', function() {
	$.ajax({
		url: '/manager/cards',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
			setTimeout(function() {
				cardPicker();
			},1500);
		}
	});
});

var cardsInterval;
$(document).on('click', '.cards_mode', function() {
	var cc = $(this);
	var mode = cc.attr('mode');
	var status = cc.attr('status');
	$('.cards_mode').each(function(i,v) { $(v).attr('status', 'disabled'); });
	settingSetter({ 'app': 'cards', 'setting': 'mode', 'value': mode });
	setTimeout(function() {
		if (mode == 'cycle') {
			cardPicker();
			clearInterval(cardsInterval);
			cardsInterval = setInterval(function() {
				if ($('.cards_mode[mode=cycle]').attr('status') == 'enabled' && $('#deck_card').is(':visible')) {
					cardPicker('new');
				}
				else {
					clearInterval(cardsInterval);
				}
			}, 180000);
			cc.attr('status', 'enabled');
		}
		else {
			cardPicker();
			cc.attr('status', 'enabled');
		}
	},500);
});

$(document).on('click', '#deck_card', function() {
	cardPicker('new');
});

function cardPicker(new_card) {
	$('.card_description_icon').hide();
	$.ajax({
		url: '/manager/card_picker',
		type: 'GET',
		data: { timestamp: timestamp, new_card: new_card },
		success: function(response) {

			if (response.stream) {
				$('#deck_card').attr('src', response.stream);
				$('#deck_card').css({ 'height': '33%' });
				$('#deck_history').html($(response.html).find('#deck_history').html());
			}
			else {
				$('#deck_card').attr('src', '/images/cards/' + response.filename);
				$('#deck_card').css({ 'height': '80%' });
				$('#deck_history').html($(response.html).find('#deck_history').html());
			}
			
			$('#card_title').html(response.title).show();

			$('#card_description').text(response.description).hide();
			appointment_chron();
		}
	});
}

$(document).on('click', '.card.history', function() {
	var title = $(this).attr('title');
	var rn = $(this).attr('rn');
	var description = $('.card_history_description[rn="' + rn + '"]').html();
	$('#deck_card').attr('src', $(this).attr('src'));
	$('#card_title').html(title).show();
	$('#card_description').html(description).hide();
});

$(document).on('click', '#card_title,.card_description_icon', function() {
	$('#card_description').show();
	$('#card_title').hide();
});

$(document).on('click', '#card_description', function() {
	$('#card_title').show();
	$('#card_description').hide();
});

var key_index;
var original_key_position;
$(document).on('click', '#ticketmaker', function() {
	boxOffice();
});

$(document).on('change', '#box_office_view', function() {
	var view = $(this).val();
	settingSetter({ 'app': 'misc', 'setting': 'box_office_view', 'value': view });
	boxOffice();
});

function boxOffice() {
	var view = $('#box_office_view').val();
	$.ajax({
		url: '/manager/box_office',
		type: 'GET',
		data: { timestamp: timestamp, view: view },
		success: function(response) {
			boxOfficeMaker(response);
		}
	});
}

// Ticket requests raise a dot on the start menu's Tickets icon until the box
// office is opened, exactly as a letter rings the envelope.
function ticketDotSet(message) {
	localStorage.setItem('ticket_waiting', message || 'Ticket request');
	ticketDotPaint();
}

function ticketDotPaint() {
	var icon = $('#ticketmaker');
	if (!icon.length) { return; }
	if (localStorage.getItem('ticket_waiting')) { icon.attr('waiting', 'yes'); }
	else { icon.removeAttr('waiting'); }
}

function ticketDotClear() {
	localStorage.removeItem('ticket_waiting');
	$('#ticketmaker').removeAttr('waiting');
}

function ticketArrival(data) {
	ticketDotSet(data ? data['message'] : '');
}

$(document).on('click', '.ticket_approve', function() {
	var b = $(this);
	var row = b.closest('.ticket_request');
	var ticket = b.attr('ticket');
	$.ajax({
		url: '/manager/box_office/approve',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			ticket: ticket,
			privilege: row.find('.ticket_request_privilege').val(),
			warranty: row.find('.ticket_request_warranty').val()
		},
		success: function(response) {
			b.css({ 'background-color': 'green' });
			setTimeout(function() { boxOffice(); }, 400);
		},
		error: function(response) {
			b.css({ 'background-color': 'red' });
		}
	});
});

$(document).on('click', '.ticket_decline', function() {
	var ticket = $(this).attr('ticket');
	$.ajax({
		url: '/manager/box_office/decline',
		type: 'POST',
		data: { timestamp: Date.now(), ticket: ticket },
		success: function(response) { boxOffice(); }
	});
});

$(document).on('click', '.ticket_blacklist', function() {
	var ticket = $(this).attr('ticket');
	$.ajax({
		url: '/manager/box_office/blacklist',
		type: 'POST',
		data: { timestamp: Date.now(), ticket: ticket },
		success: function(response) { boxOffice(); }
	});
});

$(document).on('click', '.ticket_blacklist_remove', function() {
	var stamp = $(this).attr('stamp');
	$.ajax({
		url: '/manager/box_office/blacklist/remove',
		type: 'POST',
		data: { timestamp: Date.now(), stamp: stamp },
		success: function(response) { boxOffice(); }
	});
});

// The blocked numbers: the desk's blacklist seen as calls. Block adds one by
// hand (the same list the Phone app's Block button writes to), Remove takes an
// entry off, and the whole list is handed to the phone on the next jawnPhoneSync.
// Blocking is a lasting rule, so it takes two presses like every other one here.
$(document).on('click', '#blocked_number_add_button', function() {
	var b = $(this);
	if (b.attr('armed') !== 'yes') {
		if (!$('#blocked_number_input').val()) { $('#blocked_number_status').text('Enter a number.'); return; }
		b.attr('armed', 'yes');
		var bg = b.css('background-color');
		b.css({ 'background-color': 'red' });
		$('#blocked_number_status').text('Press again to block');
		setTimeout(function() { b.css({ 'background-color': bg }); b.attr('armed', 'no'); }, 2000);
		return;
	}
	b.attr('armed', 'no');
	b.css({ 'background-color': '' });
	var number = $('#blocked_number_input').val();
	$.ajax({
		url: '/manager/box_office/blacklist/number',
		type: 'POST',
		data: { timestamp: Date.now(), number: number, note: $('#blocked_number_note').val() },
		success: function(response) {
			if (response && response.ok) { jawnPhoneSync(); boxOffice(); }
			else { $('#blocked_number_status').text('Enter a number.'); }
		}
	});
});

$(document).on('click', '.blocked_number_remove', function() {
	var stamp = $(this).attr('stamp');
	$.ajax({
		url: '/manager/box_office/blacklist/remove',
		type: 'POST',
		data: { timestamp: Date.now(), stamp: stamp },
		success: function(response) { jawnPhoneSync(); boxOffice(); }
	});
});

$(document).on('click', '#ticket_policy_save', function() {
	$.ajax({
		url: '/manager/box_office/policy',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			issue_guest_on_request: $('#ticket_policy_auto').is(':checked') ? 'on' : 'off',
			guest_warranty: $('#ticket_policy_warranty').val()
		},
		success: function(response) { boxOffice(); }
	});
});

$(document).on('change', '.ticket_privilege_change', function() {
	var s = $(this);
	$.ajax({
		url: '/manager/ticket_privilege',
		type: 'POST',
		data: { timestamp: Date.now(), uuid: s.attr('uuid'), privilege: s.val() },
		success: function(response) { s.css({ 'background-color': 'lightgreen' }); }
	});
});

function boxOfficeMaker(response) {
	if (response) {
		windowMaker(response);
		$('#box_office').show();
		ticketDotClear();
		if (original_key_position == undefined) {
			original_key_position = {
				top: $('#ticket_sales').css('top'),
				left: $('#ticket_sales').css('left')
			};
		}
		$('#ticket_sales').show();
		$('#ticket_sales').draggable({
			start: function(p) {

				$('.unlock').show();
				key_index = $('#ticket_sales').css('z-index');

			},
			drag: function(p) {


			},
			stop: function(p) {

				$('.unlock').hide();

			}
		});
	}
}



$(document).on('click', '.box_office_close_button', function() { 
	$('#ticket_sales').hide();

	$('#ticket_sales').css(original_key_position);
});

function qrcode_generator(app) {
	var timestamp = Date.now();
	var nic = $('#ticket_network_device').val();
	var name = $('#ticket_name').val();
	var warranty = $('#ticket_warranty').val();
	var privilege = $('#ticket_privilege').val();
	var project = $('#ticket_project').val();
	var debriefer = JSON.stringify(localStorage);

	$.ajax({
		url: '/manager/qrcode_generator',
		type: 'GET',
		data: { timestamp: timestamp, nic: nic, debriefer:debriefer, name: name, warranty: warranty, privilege: privilege, app: app, project: project },
		success: function(response) {
			if (response) {
				ticket_list();
			}
		}
	});
}

function ticket_list() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/box_office',
		type: 'GET',
		data: { timestamp: timestamp, source: 'list' },
		success:function(response) {

			var tl = $(response).find('#ticket_list').html();

			$('#ticket_list').html(tl);
		}
	});
}

$(document).on('click', '.ticket', function() {
	var t = $(this);
	var width = t.width();
	if (width < 200) {
		$(this).css({'width': '200px', 'height': '200px' });
	}
	else {
		t.css({'width': '40px', 'height': '40px' });
	}
});

$(document).on('click', '.delete_ticket', function() {
	var a = $(this);
	var timestamp = Date.now();
	var uuid = a.attr('uuid');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/delete_ticket',
			data: { timestamp: timestamp, uuid: uuid },
			success: function(response) {

				$('.ticket_holder[uuid="' + response['uuid'] + '"]').remove();
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

$(document).on('click', '.suspend_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	$.ajax({
		url: '/manager/suspend_ticket',
		data: { uuid: uuid, timestamp: timestamp },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			}, 1000);
		}
	});
});

$(document).on('click', '.renew_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	var warranty = $('#ticket_warranty').val();
	$.ajax({
		url: '/manager/renew_ticket',
		data: { timestamp: timestamp, uuid: uuid, warranty: warranty },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			},1000);
		}
	});
});

$(document).on('click', '.reinstate_ticket', function() {
	var t = $(this);
	var timestamp = Date.now();
	var uuid = t.attr('uuid');
	
	$.ajax({
		url: '/manager/reinstate_ticket',
		data: { timestamp: timestamp, uuid: uuid },
		success: function(response) {

			ticket_list();
			t.css({ 'background-color': 'green' });
			setTimeout(function() {
				t.css({ 'background-color': 'grey' });
			},1000);
		}

	});

});

$(document).on('change', '#ticket_network_device', function() {
	var t = $(this);
	var ip = t.find('option[value="' + t.val() + '"]').attr('ip');
	$('#ticket_network_ip').text(ip);

});


var searchingTimeout;
var lastSearchTime;
$(document).on('keyup click', '#search', function(e) {
	lastSearchTime = Date.now();
	var timestamp = lastSearchTime;
	var search = $(this).val();
	clearTimeout(searchingTimeout);
	searchingTimeout = setTimeout(function() {
		clearTimeout(searchingTimeout);
		$('#search').val('');
	},5000 * 60);
	if (e.keyCode != 13) {
		$.ajax({
			url: '/manager/keyup_search',
			type: 'GET',
			data: { search: search, timestamp: timestamp },
			success: function(response) {
				if (response.timestamp == lastSearchTime) {
					var o = $('#search').offset();
					var h = $('#search').height();
					if (response.count > 0) {
						$('#search_results').html(response.results).show();;
					}
					else {
						$('#search_results').html('').hide();
					}
					var height = $('#manager_search_results').height();
					// the results keep a readable width and stay on screen, however
					// narrow the box that called them is
					var drop_w = Math.min(Math.max($('#search').width(), 260), $(window).width() - 16);
					var drop_left = Math.max(8, Math.min(o.left, $(window).width() - drop_w - 8));
					// the dropdown hangs from the search's own edge: above the box when
					// it rides the bottom half, below when it rides the top
					var drop = { 'position':'fixed', height: height, 'border': 'solid', 'border-width': '3px', 'text-align': 'center', 'left': drop_left, 'width': drop_w };
					if ((o.top + (h / 2)) < ($(window).height() / 2)) {
						drop['top'] = o.top + h + 6;
						drop['bottom'] = 'auto';
					}
					else {
						drop['bottom'] = $(window).height() + $(document).scrollTop() - o.top;
						drop['top'] = 'auto';
					}
					$('#search_results').css(drop);
				}
			}
		});
	}
});

$(document).on('click','.manager_search_result', function() {
	var app = $(this).text();
	var timestamp = Date.now();
	appointmentGrabber(app,timestamp);
	$('#search_results').hide();
	$('#start_menu').hide();
	pseudonymHomeHider(pseudonymHIntervals);
});


$(document).on('click', '.search_toggle', function(i,e) {
	// on a side dock the input rides hidden: the first press calls it out, and
	// only a press with the input showing runs the search itself. A button that
	// rides the taskbar has its input in sight already, so it just searches.
	if (typeof jawnosSideDock == 'function' && jawnosSideDock() && $(this).closest('#pseudonym_home').length > 0 && !jawnosSideSearchVisible()) {
		jawnosSideSearchShow(1);
		return;
	}
	$('body').css({ 'cursor': 'progress' });
	clearTimeout(searchTimeout);
	var search = $('#search').val();
	var timestamp = Date.now();
	localStorage.setItem('lastSearchTime',timestamp);
	localStorage.setItem('search', search);
	$('#search_results').html('').hide();
	var chosen_appts = [];
	$('.appointments').each(function(i,val) {
		chosen_appts.push($(this).attr('app'));
	});
	if (search) {
		searchTimeout = setTimeout(function() {
			if ($('#search').val() == search) {
				$.ajax({
					url: '/manager/search',
					data: { search: search, timestamp: timestamp, chosen_appts: chosen_appts },
					success: function(response) {
						var res = $(response);

						var lastSearchTime = localStorage.getItem('lastSearchTime');
					//	if (res.find('.appointment').attr('timestamp') == lastSearchTime) {
							windowMaker(response);
							appointment_chron();
							$('body').css({ 'cursor': 'auto' });
					//	}
					}
				});
			}
		},1300);
	}
	else {
		$('.wind[title=search]').remove();
	}
});

$(document).on('click', '.search_engine_grabber', function() {

	var name = $(this).attr('name');
	var timestamp = Date.now();
	var search = $(this).attr('search') || $('#search').val();
	var website = $(this).attr('url') + search;
	var view = $(this).attr('view');
	$.ajax({
		url: '/manager/search_engine_grabber',
		type: 'GET',
		data: { app: name, search: search, view: view, website: website, timestamp: timestamp },
		success: function(response) {
			centreViewWriter(response);
			
		}
	});
});

$(document).on('click', '.torch_toggle', function() {
	var torch = localStorage.getItem('torch_status') || 'off';
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/torch',
		type: 'GET',
		data: { torch: torch, timestamp: timestamp },
		success: function(response) {

			localStorage.setItem('torch_status', response);
		}
	});
});




$(document).on('click','.file_toggle',function() {
	var detail = $(this).closest('.appointment_detail');
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app');
	var file = $(this).attr('file');
	var timestamp = $(this).attr('timestamp');

	$.ajax({
		url:'/manager/file_open',
		type:'GET',
		data: { file: file, timestamp: timestamp, app: app },
		success: function(response) {

			detail.find('.detail_image').attr('src', response.filepath);

		}
	});
});

$(document).on('click', '.share', function() {
	var image = $(this);
	var src = image.attr('file');
	var type = image.attr('type');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/share',
		type: 'GET',
		data: { src: src, type: type, timestamp: timestamp },
		success: function(response) {
		}
	});
});



$(document).on('click', '.fuck_you', function() {
	fuck_you();
});

var fucks = Date.now();
function fuck_you() {
	var timestamp = Date.now();
	if (timestamp < (fucks + 1000)) {
		return;
	}
	fucks = Date.now();
	var bt = $('#browser_toggle');
	$('#search').val('');
	$.each(['#left_view','.wind', '.cord', '.manager_search_result'],function(i,v) {
		$(v).remove();
	});
	$.each(['#configure_balloon','#mail_sidebar_container', '#soundroom_sidebar_container', '#grapple', '#search_results'],function(i,v) {
		$(v).hide();
	});
	$('.typewriter').remove();
	$.each(heartbeat, function(i,v) {
		clearInterval(heartbeat[i]);
	});
	websocketStop();
	mailWebSocketStop();
	inputClose();
	jpStop();
	twirlRunning = false;
	startMenuCloser(0);
	$('#taskbar_windows').html('');
	$('#time_machine').val('');
	$('#timeshift').val('');
	$('#alert').html('').hide();
	$('.dot').hide();
	$('.window_icon').remove();
	localStorage.setItem('timeshift', '0');
	localStorage.setItem('time_machine','');
	sessionStorage.setItem('window_storage', '{}');
	var timestamp = Date.now();
	$.each(locationWatchers, function(i,v) {
	//	continent_cancel(i);
	});
	$.ajax({
		url: '/manager/fuck_you',
		type: 'POST',
		data: { timestamp: timestamp }
	});
}

$(document).on('click', '#start_menu_toggle', function() {
	startMenuToggle();
});

$(document).on('click', '.start_menu_menu', function() {
	var menu = $(this).attr('menu');
	localStorage.setItem('start_menu_menu', menu);
	$('#start_menu').attr('toggled', 'closed');
	startMenuToggle({ source: 'menu' });
});

$(document).on('click', '.jonathan, .start_menu_list', function() {
	// the toggle answers for itself in its own handler; closing here too would
	// undo what that handler has just opened
	if ($(this).closest('#start_menu_toggle').length) { return; }
	// a start-menu row opening an appointment beats while the window comes up
	if ($(this).hasClass('start_menu_list') && typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse($(this)); }
	if ($('#start_menu').is(':visible')) {
		startMenuToggle();
	}
});

function startMenuToggle(data) {
	if (typeof data == 'undefined') { data = {}; }
	var source = data['source'];
	var st = $('#start_menu_toggle');
	var start_menu = $('#start_menu');
	var menu = localStorage.getItem('start_menu_menu');
	clearTimeout(startMenuTimeout);
	if ((st.attr('toggled') == 'open' || start_menu.is(':visible')) && !source) {
		startMenuCloser(0);
		st.attr('toggled', 'closed');
		if (focused_input.is(':visible')) {
		//	focused_input.focus();
		}
	}
	else {
		// The menu's html is kept per tab: reopening a tab puts the same markup back
		// instead of fetching again. Every fetch re-stamps every icon with the moment
		// it ran, so a fresh fetch pulled every picture over again on every open - the
		// flash. A press on a tab (source 'menu') is the refresh, and always fetches.
		if (!source && startMenuHtml[menu]) {
			startMenuRender(startMenuHtml[menu], st);
			return;
		}
		$.ajax({
			url: '/manager/start_menu',
			type: 'GET',
			data: { menu: menu },
			success: function(response) {
				if (response.html) {
					startMenuHtml[menu] = response.html;
					startMenuRender(response.html, st);
				}
			}
		});
	}
}

// Swap a menu's markup in - fresh from the server or out of the per-tab cache -
// and put the corner back together. The search may be riding the menu's corner,
// so it is held aside over the swap: replaceWith would take it down with the old
// markup, and with it whatever was typed. There is no timer on the menu: it
// stands until something else is pressed.
function startMenuRender(html, st) {
	var search = $('#search_entanglement').closest('#start_menu').length ? $('#search_entanglement').detach() : null;
	$('#start_menu').replaceWith(html);
	$('#start_menu').show();
	if (search) { $('#start_menu').append(search); }
	if (typeof jawnosSearchPlace == 'function') { jawnosSearchPlace(); }
	// the menu hangs from the button that opened it
	jawnosStartMenuPlace();
	startMenuListify();
	assistantIconInitializer();
	taskbarDisplayer();
	if (typeof mailDotPaint == 'function') { mailDotPaint(); }
	if (typeof ticketDotPaint == 'function') { ticketDotPaint(); }
	st.attr('toggled', 'open');
}

// The recent list has changed under the menu; the kept markup carries the old
// one, so it is dropped and fetched again when it is next wanted.
function startMenuHtmlFlush() {
	startMenuHtml = {};
}

// A press anywhere but the menu - or the button that opens it - puts the menu
// away.
$(document).on('click', function (e) {
	var menu = $('#start_menu');
	if (!menu.is(':visible')) { return; }
	if ($(e.target).closest('#start_menu, #start_menu_toggle').length > 0) { return; }
	$('#start_menu_toggle').attr('toggled', 'closed');
	startMenuCloser(0);
});

// The app menu ships as a wall of icons separated by <br>. Turn it into a list:
// each icon keeps its id and classes (the click handlers hang off those) and gains
// a text label from its hint, and the breaks in between go away. The rows are kept
// in alphabetical order and read icon first, so the icons line up in a column
// against the left edge. Safe to call again on the same markup.
function startMenuListify() {
	var main = $('.start_menu_main_display');
	if (main.length == 0) { return; }
	main.find('br').remove();
	main.find('img').each(function () {
		var img = $(this);
		if (img.closest('.start_menu_item').length > 0) { return; }
		// the leave and site-type buttons are absolutely placed in the top corner;
		// wrapping them in a row would move them
		if (/position\s*:\s*absolute/i.test(img.attr('style') || '')) { return; }
		var label = img.attr('hint') || '';
		// start_menu_list is what the other menus use for a row that closes the menu
		var item = $('<span class="start_menu_item start_menu_list"></span>');
		// The row goes at the top level of the list even when the template wrapped the
		// icon in something else (the tickets button sits in a bare <span>). Left in
		// that wrapper it is not a child of the list, so the sort never sees it and it
		// ends up stranded above the rows that were sorted.
		main.append(item);
		// icon first so it sits on the left, name beside it
		item.append(img);
		if (label) {
			item.append($('<span class="start_menu_item_text"></span>').text(label));
		}
		// the X takes the app back off the recent list; startMenuView() shows
		// it only over the recents, and the row press steps aside for it
		item.append('<span class="start_menu_recent_clear" hint="Forget">✕</span>');
	});
	startMenuSort(main);
	startMenuView();
}

function startMenuSort(main) {
	var items = main.children('.start_menu_item').get();
	if (items.length < 2) { return; }
	items.sort(function (a, b) {
		var at = ($(a).text() || '').trim().toLowerCase();
		var bt = ($(b).text() || '').trim().toLowerCase();
		if (at == bt) { return 0; }
		return at < bt ? -1 : 1;
	});
	$(items).appendTo(main);
}
// the name is part of the button: pressing it presses the icon next to it
$(document).on('click', '.start_menu_item_text', function () {
	$(this).siblings('img').trigger('click');
});

// and so is the padding around them: a tap anywhere on the row opens the app,
// rather than landing on the gap and only closing the menu
$(document).on('click', '.start_menu_item', function (e) {
	if ($(e.target).closest('.start_menu_recent_clear').length > 0) { return; }
	// the row beats while the app it opens loads
	if (typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse($(this)); }
	startMenuUseRecord($(this));
	if ((e.target.tagName || '').toUpperCase() == 'IMG') { return; }
	if ($(e.target).hasClass('start_menu_item_text')) { return; }
	$(this).find('img').first().trigger('click');
});

// What the app menu remembers: the apps opened from it, freshest first, kept
// in the president's cache and riding on the list as its recent attribute -
// the list IS the recent list, and the shelf rail is how everything else is
// reached. A press writes the app back, through the server and into the
// attribute so the view agrees without waiting. Which shelf is showing lives
// on the rail button itself, so a fresh menu - fetched on every open - always
// starts on the recents.
function startMenuRowKey(item) {
	var img = item.find('img').first();
	return img.attr('id') || img.attr('hint') || ($.trim(item.text()) || '');
}

function startMenuRowCategory(item) {
	return item.find('img').first().attr('category') || '';
}

function startMenuRecent() {
	var said = $('.start_menu_main_display').attr('recent') || '';
	return said.length ? said.split(',') : [];
}

function startMenuUseRecord(item) {
	var key = startMenuRowKey(item);
	if (!key) { return; }
	var recent = $.grep(startMenuRecent(), function (k) { return k !== key; });
	recent.unshift(key);
	$('.start_menu_main_display').attr('recent', recent.join(','));
	startMenuHtmlFlush();
	$.ajax({ url: '/manager/start_menu/used', type: 'POST', data: { used: key } });
}

// The X on a recent item forgets the app: it must not open it, so the press
// is stopped here, the list is rewritten without the key and the view shows
// the row gone.
$(document).on('click', '.start_menu_recent_clear', function (e) {
	e.stopPropagation();
	startMenuForget(startMenuRowKey($(this).closest('.start_menu_item')));
});

function startMenuForget(key) {
	if (!key) { return; }
	var recent = $.grep(startMenuRecent(), function (k) { return k !== key; });
	$('.start_menu_main_display').attr('recent', recent.join(','));
	startMenuHtmlFlush();
	$.ajax({ url: '/manager/start_menu/forget', type: 'POST', data: { forget: key } });
	startMenuView();
}

// The shelf showing narrows the list to its own, kept alphabetical; otherwise
// the list is the recents, freshest first, and the note stands in their place
// until a press has filled it.
function startMenuView() {
	var main = $('.start_menu_main_display');
	if (main.length == 0) { return; }
	var rows = main.children('.start_menu_item');
	if (rows.length == 0) { return; }
	var category = $('.start_menu_category.selected').attr('category') || '';
	rows.show();
	if (category) {
		startMenuSort(main);
		rows.each(function () {
			if (startMenuRowCategory($(this)) !== category) { $(this).hide(); }
		});
	}
	else {
		var rank = new Map();
		$.each(startMenuRecent(), function (i, key) {
			if (!rank.has(key)) { rank.set(key, i); }
		});
		var order = [];
		rows.each(function () {
			if (rank.has(startMenuRowKey($(this)))) { order.push(this); }
			else { $(this).hide(); }
		});
		order.sort(function (a, b) { return rank.get(startMenuRowKey($(a))) - rank.get(startMenuRowKey($(b))); });
		$(order).appendTo(main);
	}
	var shown = rows.filter(function () { return $(this).css('display') != 'none'; }).length;
	main.find('.start_menu_empty').toggle(!category && shown == 0);
	rows.find('.start_menu_recent_clear').toggle(!category);
}

// A press on a shelf shows it, a press on the shelf showing brings the
// recents back; the button wears the choice, and the next open - a fresh
// menu with no shelf marked - lands on the recents again.
$(document).on('click', '.start_menu_category', function () {
	var showing = $(this).hasClass('selected');
	$('.start_menu_category').removeClass('selected');
	if (!showing) { $(this).addClass('selected'); }
	startMenuView();
});

// the menu ships inside the page as well as over the socket, so do it once at load
$(function () { startMenuListify(); });

function startMenuCloser(wait) {
	clearTimeout(startMenuTimeout);
	startMenuTimeout = setTimeout(function() {
		var start_menu = $('#start_menu');
		if ($('#start_menu').is(':visible')) {
			var m = mouse_position();
			var left = start_menu.offset().left;
			var top = start_menu.offset().top;
			var height = start_menu.height();
			var width = start_menu.width();
			if (wait == 0 || !((m.x > left && m.x < (left + width)) && (m.y > top && m.y < (top + height)))) {
				var st = $('#start_menu_toggle');
				st.attr('toggled', 'closed');
				start_menu.hide();
			}
			else {
				startMenuCloser(7000);
			}
		}
	},wait);
}

// The System card is live while it is on screen: a phone plugged in a moment
// ago must show its new state without waiting for the next utility push. Poll
// it on a short timer - the server's levels loop takes the same cue and runs
// quick passes - and skip the swap when the markup has not changed, so the
// card does not flicker every few seconds.
var htopViewerTimer = null;
var htopViewerBusy = false;
function htopViewer() {
	var card = $('#htop_viewer');
	if (document.hidden || !card.length || !card.is(':visible') || !$('#start_menu').is(':visible')) {
		htopViewerSchedule();
		return;
	}
	if (htopViewerBusy) { return; }
	htopViewerBusy = true;
	$.ajax({
		url: '/manager/start_menu/htop_viewer',
		type: 'GET',
		success: function(response) {
			var live = $('#htop_viewer');
			if (live.length && response && response.html && live[0].outerHTML !== response.html) {
				live.replaceWith(response.html);
				appointment_chron();
			}
		},
		complete: function() {
			htopViewerBusy = false;
			htopViewerSchedule();
		}
	});
}

function htopViewerSchedule() {
	clearTimeout(htopViewerTimer);
	htopViewerTimer = setTimeout(function() { htopViewer(); }, 8000);
}

$(function() { htopViewerSchedule(); });

$(document).on('click', '#browser_toggle', function() {
	var bt = $(this);
	if ($('#browser').is(':visible')) {
		$('#browser').hide();
		bt.css({'border-color': 'black' });
	} else {
		$('#browser').show();
		bt.css({'border-color': 'yellow' });
	}
});


$(document).on('click', '.main_image_selector', function() {
	var file = $(this).attr('file');
	var app = $(this).attr('app');
	var selected = $(this).attr('main_image');
	var mis = $('.main_image_selector');
	mis.attr('main_image', 'no');
	mis.css({'border-color': 'black','border-width':'3px'});

	if (selected == 'yes') {
		settingDeleter({ 'app': app, 'setting': 'main_image' });
	}
	else {
		settingSetter({ 'app': app, 'setting': 'main_image', 'value': file });
		$(this).css({'border-color':'orange','border-width':'6px'});
		$(this).attr('main_image', 'yes');
	}
});

var cb_check = 0;
$(document).on('click', '.configuration', function() {
	configureToggle()
});

$(document).on('click','.purchase', function() {
	var iq = $(this).closest('.appointment').find('.purchase_details');
	if (iq.is(':hidden')) { 
		iq.show(); 
		timestampDater();
    iq.find('.date').val(moment(Date.now()).format('M/D/YYYY'));
	}
	else { iq.hide(); }
});
$(document).on('click','.inventory', function() {
	var iq = $(this).closest('.appointment').find('.inventory_details');
	var app = $(this).closest('.appointment').attr('app');
	if (iq.is(':hidden')) {
		appActExclusive(app, 'inventory');
		iq.show();
		inventoryDetails(app);
	}
	else {
		iq.hide(); 
	}
});


var backy_color = 0;
$(document).on('keyup', '.timed_input', function(e) {
	if (e.keyCode == 13) {
		var url;
		var i = $(this);

		var id = i.attr('id');
		var messaging = i.attr('messaging');
		var value = i.val();
		var timestamp = Date.now();
		var time_machine = localStorage.getItem('time_machine');
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var project = localStorage.getItem('project');
		var data;
		var type = 'POST';
		var timeout = 3000;

		if (i.hasClass('add_something') || i.hasClass('.time_machine')) {
			clearTimeout(searchTimeout);
			setTimeout(function() {
				$('#search_results').html('').hide();
			},700);
			i.addClass('active');
			url = '/manager/reset';
			var entry = 'add';
			data = { app: value, timeshift: timeshift, timestamp: timestamp, type: entry, movement: 'expense', time_machine: time_machine, project: project };
			timeout = 1000;
		}
		else if (i.hasClass('name_change')) {
			url = '/manager/configure';
			var setting = i.attr('setting');
			var app = i.attr('app');
			var name = i.val();
			data = { app: app, timestamp: timestamp, type: setting, setting: setting, value: value };
		}
		else if (i.hasClass('appointment_search')) {
			url = '/manager/appointment_details',
			type = 'GET';
			data = { app: value, timeshift: timeshift, timestamp: timestamp, type: "search", time_machine: time_machine,  scope: scope };	
		}
		if (url) {
			$.ajax({
				url: url,
				type: type,
				data: data,
				success: function(response) {
					if (response && response.conflict) {
						// the new name is a name the house already knows: the panel
						// picks which value keeps the name, setting by setting
						nameConflictPanel(response);
						return;
					}
					if (i.hasClass('add_something') || url == '/manager/configure') {
						$('#start_menu').hide();
						i.removeClass('active');
						centreViewWriter(response.cv);
				//		configureDisplay();
						appointment_chron();
					//	$('#search').val('');
						if ($('.now').attr('presence') != 'not' && response['added'] == 'yes') {
								continent_record({'uuid':response['uuid'],'purpose': 'app','app':response['app'],'timestamp':response['timestamp']});
							}
					}
					i.css({ "background-color": "yellow" });
					clearTimeout(backy_color);
					backy_color = setTimeout(function() {
						i.css({ "background-color": "" });
					},950);
				}
			});
		}
	}
});

$(document).on('click','.voice_prompt',function() {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/voice_prompt',
		data: { timestamp: timestamp, repeater: 'no' },
		success: function(res) {


		},
		error: function(err) { console.log("adder error",err); }
	});
});

$(document).on('dblclick', '.voice_prompt', function() {

	$.ajax({
		url: '/manager/voice_prompt',
		data: { timestamp: timestamp, repeater: 'yes' },
		success: function(res) {

		},
		error: function(err) { console.log("adder error",err); }
	});
});

function said_it(text) {
	if (focused_input.not(':visible')) {
		focused_input = $('#search');
	}


	if (text) {
		if (focused_input.attr('id') == 'search' || typeof focused_input == "undefined") {
			$('#search').val(text);
			$('#search').trigger(jQuery.Event('keyup', { keyCode: 13 }));
		}
		else {
			var pretext = focused_input.val();
			if (pretext) {
				pretext += '. ';
			}
			focused_input.val(pretext + text);
			focused_input.trigger('keyup');
		//	focused_input.trigger(jQuery.Event('keyup', { keyCode: 13 }));
		}
	}

}

$(document).on('click', '.appointment_list_toggle', function() {
	var list = $(this).attr('list');
	var l = $(this).closest('.appointment_detail').find('.appointment_list[list="' + list + '"]');
	if (l.is(':visible')) {
		l.hide();
	}
	else {
		l.show();
	}

});
$(document).on('click', '.delete_duty', function() {
	var a = $(this);
	var duuid = a.attr('duuid');
	var server_time = a.attr('server_time');
	var app = a.closest('.appointment').attr('app');
	var app_uuid = a.closest('.appointment_detail').attr('uuid');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/delete_duty',
			type: 'POST',
			data: { duuid: duuid, server_time: server_time, app: app, app_uuid: app_uuid },
			success:function(response) {

				$('.appointment_duty_container[duuid="' + response.duuid + '"]').remove();
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

$(document).on('click', '.download', function() {
	var d = $(this);
	var file = d.attr('file');
	var uuid = d.attr('uuid');
	var app = d.attr('app');
	var server_time = d.attr('server_time');
	var timestamp = d.attr('timestamp');
	var uri = encodeURIComponent(app);
	window.location='/manager/download_file?app=' + uri + '&uuid=' + uuid + '&timestamp=' + timestamp + '&server_time=' + server_time + '&file=' + file;
});

$(document).on('click', '.take_picture', function() {
	var d = $(this).closest('.appointment_detail');
	var app = d.attr('app');
	var uuid = d.attr('uuid');
	var camera = $(this).attr('camera');
	var container = d.closest('.appointment');
	var timestamp = Date.now();
	var ago = container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	$.ajax({
		url: '/manager/take_picture',
		type: 'POST',
		data: { app: app, uuid: uuid, camera: camera, timestamp: timestamp, ago: ago, time_machine: time_machine, timeshift: timeshift },
		success: function(response) {

		}
	});
});

$(document).on('click', '.scan_document', function() {
	var d = $(this).closest('.appointment_detail');
	var container = d.closest('.appointment');
	var app = d.attr('app');
	var uuid = d.attr('uuid');
	var feed = $(this).attr('feed');
	var timestamp = Date.now();
	var ago = container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	$.ajax({
		url: '/manager/scan_document',
		type: 'POST',
		data: { app: app, uuid: uuid, feed: feed, timestamp: timestamp, ago: ago, time_machine: time_machine, timeshift: timeshift },
		success: function(response) {

		}
	});
});

var m;
var main_h;
$(document).on('click', '.upload_file, #upload', function(e) {
	var b = $(this);
	var m =	$('#main_upload_input');

	var app = undefined;
	var uuid = undefined;
	var source = 'main_upload';
	
	if (b.hasClass('app_upload')) {
		app = b.closest('.appointment_detail').attr('app');
		uuid = b.closest('.appointment_detail').attr('uuid');
		source = 'app_upload';
	}
	m.attr('app', app);
	m.attr('uuid', uuid);
	m.attr('source', source);
	main_h = $('#main_upload_container').html();
	m.trigger('click');
});

$(document).on('change', '#main_upload_input', function() {
	var m =	$('#main_upload_input');
	
//	m.trigger('click');

	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('#main_upload').trigger('submit');
	}
});

$(document).on('submit', "#main_upload", function(e) {
  e.preventDefault();
	var mui =	$('#main_upload_input');
  var formData = new FormData(this);
	formData.delete('timestamp');
	formData.append('timestamp', timestamp);
	var apper = $('.wind[app="' + topWindow() + '"]');
	var navigation = $(apper).attr('navigation');
	app = $(apper).attr('app') || $('#search').val();
	formData.delete('app');
	formData.delete('uuid');
	var source = mui.attr('source');
	if (source == 'app_upload') {
		app = mui.attr('app');
		var uuid = mui.attr('uuid');
		formData.append('uuid', uuid);
	}

	formData.append('app', app);
	formData.append('source', source);
  $.ajax({
      url: '/manager/upload_file',
      type: 'POST',
      data: formData,
      success: function (response) {
				m = undefined;
				formData.delete('fileupload');
				$('#main_upload').remove();
				$('#main_upload_container').html(main_h);
				appClearer(app);
				continent_record({'uuid':response['uuid'],'purpose':'app','app':response['app'],'timestamp':response['timestamp'],'navigation':navigation});
      },
      cache: false,
      contentType: false,
      processData: false
  });
});

$(document).on('click', '.name_text', function(){
	var text = $(this).text();
	focused_input.val(text);
});

$(document).on('click','.app_act, .save_appointment',function() {
	var b = $(this);
	var app = b.attr('app') || b.closest('.appointment').attr('app');
	var originalColour = b.css('background-color');
	b.css({'background-color': 'blue'});
	setTimeout(function() { b.css({'background-color': originalColour }); },750);
//	cacheDelete({ app: app, context: 'template' });
});

// the appointment's three group buttons each open the buttons they carry
// beneath them; opening one folds the others away, so the row under the
// groups always answers the button just pressed
$(document).on('click', '.group_toggle', function() {
	var group = $(this).attr('group');
	var appointment = $(this).closest('.appointment');
	var contents = appointment.find('.' + group + '_group_contents');
	var open = contents.is(':visible');
	appointment.find('.group_contents').hide();
	if (!open) { contents.show(); }
});

$(document).on('click','#calculate_it', function() {
	clearInterval(calculateInterval);
	calculator();
});

$(document).on('click, change', '#update_frequency', function() {
	var f = $(this).val();
	localStorage.setItem('update_frequency', f);
	initializer()
});




$(document).on('click', '#timeshift_viewer', function() {
	var time_machine = $('#timeshift_viewer').text() + ' ' + $('#time_machine').val();
	$('#time_machine').val(time_machine);
	localStorage.setItem('time_machine',time_machine);
});

// Back to the present: the now button and a double-click on the canvas both
// come through here. Any glide or pending flick is stopped first - it would
// write the time machine back the moment it landed and undo this.
function nowResetter() {
	cancelAnimationFrame(clothesLinePos['timelineSmoothScrolling']);
	clothesLinePos['timelineSmoothScrolling'] = undefined;
	if (clothesLinePos['fling']) {
		clearTimeout(clothesLinePos['fling']['settle']);
		clothesLinePos['fling'] = undefined;
	}
	// and stand the drag state down, or calculator() sees the view as just moved
	// and declines to fetch the present back
	clothesLinePos['moving'] = 0;
	clothesLinePos['lastBX'] = undefined;
	clothesLinePos['mouseDrag'] = 0;
	clothesLinePos['startMove'] = undefined;
	$('#time_machine').val('');
	$('#timeshift').val('');
	localStorage.setItem('timeshift', '0');
	localStorage.setItem('time_machine','');
	localStorage.setItem('timeshift', '');
	timestamp = Date.now();
	initializer();
	debrief_setter();
	calculator();
}

$(document).on('click','.now',function() {
	nowResetter();
});



var note_typing_timeout;
$(document).on('keyup', '.notes, .ago, .duration', function() {
	var i = $(this);
	var app = i.closest('.appointment');
	var appointment = app.attr('app');
	clearTimeout(note_typing_timeout);
	note_typing_timeout = setTimeout(function() {
		$.each(['notes','ago','duration'], function(io,v) {
			var input = app.find('.' + v);
			var typed = input.val();
			if (input.hasClass('text_editor') && input.hasClass(v)) {
				typed = input.html();
			}
			if (typed && typed != '' && typed != '<br>') {
				jawnosAppFieldSet(appointment, v, typed);
			}
			else {
				jawnosAppFieldRemove(appointment, v);
			}
			input.trigger('change');
		});
		i.css({ "background-color": "yellow" });
		clearTimeout(backy_color);
		backy_color = setTimeout(function() {
			i.css({ "background-color": "" });
		},750);
	},200);
});


$(document).on('focus, click', 'input.time', function() {
	$(this).addClass('editing');
});

$(document).on('change, focusout', 'input.time', function() {
	var input = $(this);
	var time = input.val();
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/ago',
		type: 'GET',
		data: { ago: time },
		success: function(response) {
			input.attr('timestamp', response);
			input.removeClass('editing');
			if (input.attr('setting') && input.attr('app')) {
				settingSetter({'app': input.attr('app'), 'setting': input.attr('setting'), value: response });
			}
		}
	});
});




$(document).on('dblclick', '#timeshift', function() {
	var e = $(this);
	var scope = e.val();
	e.val(0);
	localStorage.setItem('timeshift', 0);
	debrief_setter();
});

var timeshift_timeout;
$(document).on('input', '#timeshift', function() {
	var timeshift = $(this).val();
	localStorage.setItem('timeshift', timeshift);
	if ($('.appointment_details').is(':visible') ) {
		$('.appointment_details').each(function(i,v) { 
			$(v).closest('.appointment').find('.det').trigger('dblClick');
		});
	}
	debrief_setter();
	clearTimeout(timeshift_timeout);
	setTimeout(function() {
		calculator();
	},10);
});

$(document).on('change', '#timeshift_scope', function() {
	var timeshift = $(this).val();
	localStorage.setItem('timeshift_scope', timeshift);
	var scope = 12;
	if (timeshift == 'h' ||timeshift == 'm'||timeshift == 's') { scope = 60 }
	if (timeshift == 'y') { scope = 20 }
	$('#timeshift_max').attr('max', scope );
	debrief_setter();
});

$(document).on('change', '#scope', function () {
	var scope = $(this).val();
	localStorage.setItem('scope', scope);
	debrief_setter();
});

$(document).on('change', '#filter', function () { 
	var filter = $(this).val();
	localStorage.setItem('filter', filter);
	debrief_setter()
});

$(document).on('change', '#layout', function() {
	var layout = $(this).val();
	localStorage.setItem('layout', layout);
	debrief_setter();
});

$(document).on('change', '#projects', function() {
	var project = $(this).val();
	localStorage.setItem('project', project);
	debrief_setter();
});

$(document).on('change', '#accounts', function() {
	var account = $(this).val();
	localStorage.setItem('account',account);

	debrief_setter();
});
$(document).on('change', '#background_images', function() {
	var bgi = localStorage.getItem('background_images');
	if (bgi == 'on') {
		bgi = 'off';
	}
	else {
		bgi = 'on';
	}
	localStorage.setItem('background_images', bgi);
	debrief_setter();
});
$(document).on('change', '#background_images_opacity', function() {
	var bgi = $(this).val();
	localStorage.setItem('background_images_opacity', bgi);
	$('#background').css({ 'opacity': bgi });
	debrief_setter();
});

$(document).on('change', '#sorts', function() {
	var sorts = $(this).val();
	localStorage.setItem('sorts', sorts);
	debrief_setter();
});

$(document).on('click','#appt_view_toggle', function() {
	var view = $(this);
	if (sessionStorage.getItem('appt_view_toggle') == 'on') {
		sessionStorage.setItem('appt_view_toggle', 'off')
		localStorage.setItem('appt_view_toggle', 'off');
		view.css({ 'background-color': '' });
	}
	else {
		view.css({ 'background-color': 'green' });
		sessionStorage.setItem('appt_view_toggle', 'on');
		localStorage.setItem('appt_view_toggle', 'on');
	}

});
var appts = {};
var response = {};
function deloreanBringer() {
	var now = Date.now();
	var readable = moment(now).format();
	var appts = []
	$('.appointment').each(function(n,v) {
		var v = $(this);
		if (v.is(':visible')){ appts.push(v.attr('app')); }
	});
	
	var appointments = JSON.stringify(appts);
	if (appts.length == 0 || sessionStorage.getItem('appt_view_toggle') != 'on') {
		appointments = [];
	}
	var timeshift = localStorage.getItem('timeshift');
	var timeshift_scope = localStorage.getItem('timeshift_scope');
	timeshift = timeshift + timeshift_scope;
	var scope = localStorage.getItem('scope');
	var sorts = localStorage.getItem('sorts');
	var layout = localStorage.getItem('layout');
	var filter = localStorage.getItem('filter');
	var project = localStorage.getItem('project');
	var account = localStorage.getItem('account');
	var background_images = localStorage.getItem('background_images');
	var background_images_opacity = localStorage.getItem('background_images_opacity');
	var time_machine = localStorage.getItem('time_machine');
	var appt_view_toggle = sessionStorage.getItem('appt_view_toggle') || localStorage.getItem('appt_view_toggle');
	return { 
		timestamp: now, 
		readable: readable,
		appts: appointments,
		scope: scope,
		sorts: sorts,
		layout: layout,
		filter: filter,
		timeshift: timeshift,
		time_machine: time_machine,
		account: account,
		project: project,
		appt_view_toggle: appt_view_toggle,
		background_images: background_images,
		background_images_opacity: background_images_opacity,
		now: now
	};
}
function calculator() {
	var now = Date.now();

	if (!jawn_resting() && clothesLineAtRest()) {
		var data = deloreanBringer();
		windowBackgroundAdjuster({ caller: 'calculator' });
		// While the view is fresh, echo the markers of what we are showing so an
		// unchanged second can be answered "nothing new" - the server then skips the
		// whole per-app build. Past 35s (or before the first render) we send none,
		// which forces the full pass: the safety net against anything the markers
		// missed, and it is what resets the 35s clock.
		if (appts['__specs'] && appts['__specs']['stats'] && (now - 35000) <= appts['__specs']['server_time']) {
			data['stats'] = JSON.stringify({
				appts: appts['__specs']['stats']['appts'],
				settings: appts['__specs']['stats']['settings']
			});
		}

		$.ajax({
			url:'/manager/appointment_viewer',
			type:'GET',
			data: data,
			success: function(respons){
				// A lapsed session - a stale cookie, or the cookieless first request a
				// webview sends as it wakes - is answered with the Gate page at HTTP 200,
				// not JSON. This handler used to trust it: appts became undefined and
				// response a string, so the poll threw and the pan (timelineScroller)
				// threw, freezing the timeline while the last-drawn hits still took taps.
				// Accept only a real reply. The full payload nests its specs as
				// respons.appts.__specs; the 'nothing new' short-circuit
				// ({ updateable: 'no', __specs: ... }) puts them at the top and carries no
				// appts. Either shape is real; the Gate page (a string) is not. Never
				// reload from here; the server answers a gated XHR with JSON 401 instead.
				if (!respons || typeof respons !== 'object'
					|| !(respons['__specs'] || (respons.appts && respons.appts['__specs']))) {
					return;
				}
				if (respons.updateable != 'no') {
					if (clothesLineAtRest()) {
						appts = respons.appts;
					//	appts = { ...appts, ...response.appts };
						var pseudonyms = respons.pseudonyms;
						$('.time_jump').each(function(i,v) {
							$(v).attr('timestamp',respons.timestamp);
						});
						var ts = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');

						graphicalize(respons);
					//	inventoryDetailsUpdater();
					}
				}
				else {
					// nothing new was fetched: the view slides to the centre the server
					// names - exactly, and only from rest. The flick's ~32x reach belongs
					// to a gesture and not to a correction: added here it flew past the
					// target, and the next poll flew the whole error again, 32x larger,
					// until the dates left the calendar behind.
					if (clothesLineAtRest()) {
						timestamp = respons['__specs']['timestamp'];
						timelineScroller({ diff: (response.appts['__specs']['timestamp'] - respons['__specs']['timestamp']), source: 'slide' });
						response['__specs'] = respons['__specs'];
					}
				}
			}
		});
	}
}

$(document).on('click', '#web_toggle,.web_toggle', function() {
	var timestamp = Date.now();

	$.ajax({
		url: '/manager/web',
		type: 'GET',
		data: { timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
		}
	});


});

$(document).on('click', '.web', function() {
	var app = $(this).attr('app');
	var website = $(this).attr('web');
	var uuid = $(this).attr('uuid');
	var ts = timestamp;
	if (uuid) {
		ts = $(this).closest('.wind').attr('timestamp');
	}
	var user_agent =   navigator.userAgent; 
	$.ajax({
		url: '/manager/website_get',
		data: { app: app, website: website, timestamp: ts, user_agent: user_agent, uuid: uuid },
		success: function(response) {
			var ls = localStorage;
			var ss = sessionStorage;
			if (!uuid) {
			//	$('#browser').append(response.window);
				var window_id = windowMaker(response.window);
			}
			ts = $('.wind[app="web"]').attr('timestamp');
			uuid = response.uuid;
			$('#browser_' + ts).remove();
			$('<iframe>', {
				src: '/manager/browser?internal_url=' + response.internal_url + '&timestamp=' + ts + '&app=' + app + '&uuid=' + uuid,
				id:  'browser_' + ts,
				frameborder: 0,
				scrolling: 'yes',
				style: "width:100%;height:calc(100% - 50px);position:absolute;top:90px;"
			}).appendTo('#window_contents_' + ts);
			$('#browser_' + ts).css({'background-color': 'white'}).addClass('web_browser_iframe').show();
			$('#website_title').text(response.app);
			$('#website_time').attr('timestamp', response.timestamp);
			$('#web').hide();
			$('#web_measure_toggle').attr('uuid', uuid).attr('app', app).show();
			appointment_chron();


			$('#browser_' + ts).on('load', function() {
				$(this).contents().find('body').on('mousemove', function(event) {
					var bs = $('#browser_' + ts);
					if (bs.hasClass('measure_selector_enabled')) {
						var selector = selectorMaker(event.target);
						var t = bs.find(selector).html();
					}
				});
				$(this).contents().find('body').on('click', function(event) {
					if ($('#browser_' + ts).hasClass('measure_selector_enabled')) {
						var selector = selectorMaker(event.target);
						if (!selector) {
							selector = $(event.target).prop('tagName').toLowerCase();
						}
						var text = $(event.target).text();
						// the selector can match many nodes; this says which one was clicked
						var index = $(this).find(selector).index(event.target);

						var measure = $('#web_measure_selector').val();
						$.ajax({ 
							url: '/manager/web/measure/set',
							type: 'post',
							data: { app: app, uuid: uuid, selector: selector, index: index, measure: measure, text: text },
							success: function(response) {
								$('#alert').html(response.confirmation).show();
							}
		
						});
					}
				});
			});
			var ls2 = localStorage;
			var ss2 = sessionStorage;
			$.each(ls2, function(i,v) {
				if (!ls[i]) {
					localStorage.removeItem(i);
					console.log('Removed ' + i);
				}
			});
			$.each(ss2, function(i,v) {
				if (!ss[i]) {
					sessionStorage.removeItem(i);
					console.log('Removed ' + i);
				}
			});
			if (!ls2['time_machine']) {
				localStorage.setItem('timestamp', '');
			}
			if (!ls2['timeshift']) {
				localStorage.setItem('timeshift', 0);
			}
		}
	});
});

$(document).on('click', '.web_measure_candidate', function() {
	$('.web_measure_candidate').removeClass('selected');
	$(this).addClass('selected');
	$(this).find('.web_measure_candidate_mark').html('&#9679;');
	$('.web_measure_candidate').not(this).find('.web_measure_candidate_mark').html('&#9675;');
});

$(document).on('click', '#web_measure_confirm_save', function() {

	var chosen = $('.web_measure_candidate.selected').first();
	if (!chosen.length) {
		return;
	}
	$.ajax({
		url: '/manager/web/measure/submit',
		type: 'POST',
		data: {
			app: chosen.attr('app'),
			measure: chosen.attr('measure'),
			spec: chosen.attr('spec')
		},
		success: function(response) {
			$('#alert').hide();
		}
	});
});


$(document).on('click', '#web_measure_toggle', function() {
	var t = $(this);
	var app = t.attr('app');
	var uuid = t.attr('uuid');
	var tog = t.attr('toggle');
	var timestamp = $('#website_time').attr('timestamp');
	var wms = $('#web_measure_selector')
	wms.html('')
	wms.hide();
	if (tog == 'on') {
		tog = 'off';
		t.css({'background-color': ''});
		$('#window_content_' + timestamp).removeClass('web_measurable');
		$('.web_browser_iframe').removeClass('measure_selector_enabled');
	}
	else {
		tog = 'on';
		$.ajax({
			url: '/manager/web/measure/toggle',
			type: 'GET',
			data: { app: app, uuid: uuid },
			success: function(response) {
				t.css({'background-color': 'yellow'});
				$('#window_content_' + timestamp).addClass('web_measurable');
				var count = 0;

				$.each(response.measures, function(i,v) {
					var h = '<option value="' + i + '">' + v.formatted + '</option>';
					if (count == 0) {
						h = '<option selected value="' + i + '">' + v.formatted + '</option>';
					}
					$('#web_measure_selector').append(h).show();
					if (count == 0) {
						$('#web_measure_selector').val(i);
					}
					count++;
				});
				if (count > 0) {
					$('.web_browser_iframe').addClass('measure_selector_enabled');
				}

			}
		});
	}
	t.attr('toggle', tog);
});

$(document).on('click','.web_delete', function() {
	var b = $(this);
	var app = b.attr('app');
	var uuid = b.attr('uuid');
	var armed = b.attr('armed');


	if (armed == 'yes') {
		b.addClass('superactive');
		$.ajax({
			url: '/manager/web/delete',
			type: 'POST',
			data: { app: app, uuid: uuid },
			success:function(response) {
				$('.web_history[app="' + app + '"][uuid="' + uuid + '"]').remove();
			}
		});
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


var ap;
var clockInterval;

function graphicalize(respons) {
	var ts = Date.now();
	
	// never let a non-payload (the Gate page a lapsed session returns) become the
	// global the poll and the pan read from - see the guard in calculator()
	if (respons && (typeof respons !== 'object' || !respons.appts)) { return; }
	if (!respons) {
		respons = response;
	}
	else {
		// a full payload replaces the one in hand; what it actually covers is
		// what a drag reads to know whether the window it reached was fetched
		if (respons !== response && typeof timelineFetchedSet == 'function') { timelineFetchedSet(respons.appts); }
		response = respons;
	}
	// the rail's band is the configured height, unless the desk wears no rail at
	// all (then the printers below reserve nothing for it)
	clothesLineHeight = (respons.clothesline.length == 0) ? 0 : clothesLineBaseHeight;
	appts = respons.appts;

	timestamp = appts['__specs']['timestamp'];
	if ($('#' + localStorage.getItem('layout')).length == 0) {
		return;
	}
	// a row outside the drawn window is kept out to the fetched edge instead: the
	// server reaches a span past the left edge so a row just behind it can stick
	// there, and carries the row of a still-running appointment however old it
	// is, and those rows are the ones the left edge is holding on to
	var fetch_start = appts['__specs']['fetch_start'];
	if (fetch_start == undefined) { fetch_start = appts['__specs']['start']; }
	var view_start = appts['__specs']['start'];
	$.each(appts, function(i,v) {
		$.each(v['list'], function(am,way) {
			if (way != undefined) {
				// The reach carries two kinds of row from the left that must not be
				// pruned as the view slides: a still-running appointment's row (pure
				// presence - its start may be far older than the reach, and its band is
				// what the left edge holds on to) and one that stopped inside the view
				// (it comes in with the span it ran). fetch_start travels with the view
				// on a slide, but these rows are anchored in time, so the first unchanged
				// poll would otherwise drop the running appointment and delete it.
				var held = way['stop_timestamp']
					? (way['stop_timestamp'] >= view_start)
					: (way['type'] == 'start' || way['type'] == 'record');
				if (held || (way['timestamp'] && way['timestamp'] >= fetch_start && way['timestamp'] <= appts['__specs']['end'])) {
				}
				else {
					appts[i]['list'].splice(am, 1);
					if (appts[i]['list'].length == 0) {
						delete appts[i];
					}
				}
			}
		});

	});
	var diff = Math.abs(timestamp - ts);
	var nowb = $('.now');
	if (diff > 1100) {
		nowb.attr( 'presence', 'not' );
		nowb.css({'background-color': 'red' });
		if (ts != timestamp) {

			nowb.css({'background-color': 'orange' });
		}
	}
	else if (diff <= 1100 && diff >= 500) {
		nowb.css({'background-color': 'yellow' });
		nowb.attr('presence', 'delayed');
	}
	else {
		nowb.attr('presence', 'here');
		nowb.css({'background-color': 'green' });
	}
	var layout = localStorage.getItem('layout');
	var timeshit = localStorage.getItem('timeshift');
	var time_machine = localStorage.getItem('time_machine');
	var background_images = localStorage.getItem('background_images');

	if (time_machine == '0s' || time_machine == 'in 0s') {
		$('#time_machine').val('');
		localStorage.setItem('time_machine', '');
		time_machine = '';
	}
	// the tile carries the time machine's state itself now that the background
	// carries the server's speed (an older universal.js just keeps its icon)
	if (typeof nowIconApply == 'function') { nowIconApply(time_machine != '' ? 'time_machine' : 'here'); }

	//guests.push(appts);
	$.each(['leaderboard', 'clockface', 'timeline', 'calendar', 'continent', 'narrator'], function(i,v) {
		if (v != layout)
			$('#' + v).hide();
	});
	if (layout == 'clockface'){
		clockfacePrinter(appts);
	}
	else if (layout == 'leaderboard') {
		leaderboardPrinter(appts);
	}
	else if (layout == 'calendar') {
		calendarPrinter(appts);
	}
	else if (layout == 'narrator') {
		narratorPrinter(appts);
	}
	else if (layout == 'timeline') {
		timelinePrinter(appts);
	}
	else if (layout == 'continent') {
		continentPrinter(appts);
	}
	if (background_images == 'on') {
		backgroundPrinter(appts,respons);
	}
	else {
		$('#background').hide();
	}
	// The whole payload used to be stringified into sessionStorage here - every
	// app, every appointment, megabytes of it - so the two handlers that read it
	// could fall back on one number, the view's timestamp. That was over quota
	// and failing silently; the timestamp is what they get now.
	sessionStorage.setItem('appts_timestamp', appts['__specs']['timestamp']);

	clotheslineHanger(respons.clothesline);
}

var page_number = 0;
$(document).on('click', '#marker_toggle', function() {
	var timestamp = Date.now();
	var app = topWindow('marker');
	var url = '/manager/marker';
	if ($('#marker_toolbox').length > 0) {
		var mid = $('#marker_toolbox').closest('.wind').attr('id');
		$('#' + mid).show();
		topLevelNow($('#' + mid));
	}
	else {
		$.ajax({
			url: url,
			type: 'GET',
			data: { window_maker: 'yes', app: app, timestamp: timestamp, browser_tab_id: bti },
			success: function(response) {
				windowMaker(response);
				markerInit();
			}, error: function (response) {  }
		});
	}
});

$(document).on('click', '#terminal_toggle', function() {
	terminalOpener({ window_maker: 'yes' });
});

$(document).on('click', '#twirl_toggle', function() {
	twirlRunning = false;
	var url = '/manager/twirl';
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) {  }
	});
});



$(document).on('click', '#home_toggle', function() {
	var url = '/manager/home';

	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response);
		}, error: function (response) { }
	});
});

$(document).on('click', '#store_toggle', function() {
	storeOpener();
});

$(document).on('click', '#handbook_toggle', function() {

	var url = '/manager/handbook/' + localStorage.getItem('handbook_chapter');
	var page = localStorage.getItem('handbook_page');
	var window_saver = sessionStorage.getItem('window_storage');
	var open_windows = JSON.parse(window_saver) || {};
	var timestamp = Date.now();
	$.ajax({
		url: url,
		data: { page: page, windows: window_saver },
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) { 
		}
	});
});

$(document).on('click', '.handbook_link', function() {
	var chapter = $(this).attr('chapter');
	var page = $(this).attr('page');
	var type = $(this).attr('type');
	handbookGrabber(chapter,page,type);
});

function handbookGrabber(chapter,page,type) {
	localStorage.setItem('handbook_page', page);
	var url = '/manager/handbook/' + chapter;
	var window_saver = sessionStorage.getItem('window_storage');
	var open_windows = JSON.parse(window_saver) || {};
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, page: page, type: type, windows: window_saver },
		success: function(response) {
			windowMaker(response)
		}, error: function (response) { 
		}
	});
}

$(document).on('click', '.handbook_setting', function() {
	var a = $(this);
	var app = a.attr('app');
	var setting = a.attr('setting');
	var value = a.attr('value');

	$.ajax({
		url: '/manager/handbook/settings',
		type: 'POST',
		data: { app: app, setting: setting, value: value },
		success: function(response) {
			a.attr('value', response[app]);
		}
	});


});

function openApps() {
	var apps = [];
	$('.appointment').each(function(i,v) {
		  apps.push($(v).attr('app'));
	});
	return apps;
}

$(document).on('click', '.top_navbar, .neighbour_window, .room_appt', function(e) {
	var clicker = $(this);
	var win = clicker.closest('.wind');
	var text = $(this).attr('app');
	if ($(e.target).parent().hasClass('navbar_buttons')) { return false; }
	if (typeof windowStacker === 'function' && typeof windowPhoneChecker === 'function'
		&& windowPhoneChecker() && clicker.hasClass('top_navbar')) {
		// a phone walks its pile on touchend, not here: a title bar that was just
		// dragged has its click swallowed by jQuery UI's drag, so the click cannot
		// be trusted to fire at all. Nothing to do on this one.
		return false;
	}

	var app = JSON.stringify({ name: text });
	var timestamp = Date.now();
	if (text == 'music' ) {
		var music_window = $('#music').closest('.wind').attr('id');
		topLevelNow($('#' + music_window));
	}
	else if (text == 'video') {
		var video_window = $('#video').closest('.wind').attr('id');
		topLevelNow($('#' + video_window));
	}
	else if ( text == 'gallery' ) {
		var wind = win.attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'marker') {
		var wind = $('#marker').closest('.wind').attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'mailbox') {
		var wind = $('#marker').closest('.wind').attr('id');
		topLevelNow($('#' + wind));
	}
	else if (text == 'terminal') {
		var wind = $('#terminal').closest('.wind').attr('id');
		topLevelNow($('#' + wind));
	}
	else {
		var wind = $('#terminal').closest('.wind').attr('id');
		topLevelNow(win);
	}
	if ($('.wind[app="' + text +'"]').length == 0) {
		appointmentGrabber(text,Date.now());
	}

});

// A phone's title-bar tap walks the pile. It is taken on touchend, not click,
// because a window that was just dragged has its click swallowed by jQuery UI's
// drag state - the touch itself always fires, so the walk hangs off that.
$(document).on('touchend', '.top_navbar', function(e) {
	if (typeof windowPhoneChecker != 'function' || !windowPhoneChecker()) { return; }
	if ($(e.target).closest('.navbar_buttons').length) { return; }
	if (typeof windowStacker != 'function') { return; }
	windowStacker($(this).attr('app'));
});

$(document).on('click', '.reset', function() {
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app');
	var details = appointment.find('.app_details');
	if (details.is(':visible')) {
		details.hide();
	}
	else {
		appActExclusive(app, 'reset');
		details.show();
	}

});

function projectAccountGrabber(details) {
	var container = details.closest('.appointment');
	var form = container.find('.app_details');
	former = form;
	var account = form.find('.account').val();
	var project = form.find('.project').val();
	var movement = form.find('.movement').val();
	var current_project = localStorage.getItem('project');

	if (current_project != 'all') {
		project = current_project;
	}
	return { account: account, project: project, movement: movement };
}

var appointmentLockingMechanism;
$(document).on('click', '.appointment_locking_mechanism', function() {
	var alm = $(this);
	var status = alm.attr('status');
	clearInterval(appointmentLockingMechanism);
	if (status == 'on') {
		alm.css({'background-color':'lightgrey'});
	}
	else {
		status = 'on';
		alm.css({'background-color':'red'});
		appointmentLockingMechanism = setTimeout(function() {
			alm.attr('status','off');
			alm.css({ 'background-color': 'lightgrey'});
		},4000);
	}
	alm.attr('status', status);
});

var former;
$(document).on('click', '.save_appointment', function(e) {
	managerReset($(this),e);
});


function managerReset(caller,e) {
	var lockingStatus = 'off';

	var details = caller;
	var pa = projectAccountGrabber(details);
	var app = details.attr('app');
	var container = details.closest('.appointment');
	var form = container.find('.app_details');
	former = form;
	if (container.find('.appointment_locking_mechanism').attr('status') == 'on' || e.ctrlKey == true) {
		lockingStatus = 'on';
	}
	var project = pa['project'];
	var movement = pa['movement'];

	var club = form.find('.club').val();
	var camera = details.attr('camera');
	var feed = details.attr('feed');
	var digits = details.attr('digits');
	var item = form.find('.item').val();
	var amount = form.find('.amount').val();
	var ago = $('#ago').val() || container.find('.ago').val();
	var duration = container.find('.duration').val();
	var schedule = container.find('.schedule').val();
	var quantity = container.find('.main_input.quantity').val();
	var notes = container.find('.text_editor').html();
	var now = Date.now();
	var type = details.attr('type');
	// a stop names the session it closes: the appointment header carries the open
	// session's uuid, so the server stops that row on every machine and not
	// whichever open session each machine happens to hold (which left a stale one
	// behind to be swept up by the next stop)
	var running_uuid = '';
	if (type == 'stop') {
		running_uuid = container.find('.appointment_header_background').attr('running_uuid') || '';
	}
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	var warranty = container.find('.warranty').val();
	var navigation = container.attr('navigation');
	var measure_is_open = false;

	if (container.find('.re_measures').is(':visible')) {
		measure_is_open = true;
	}

	if (type == 'stop') {
		continent_cancel(app);
	}
	var data = { 
		app: app, 
		timestamp: now, 
		uuid: running_uuid,
		type: type, 
		ago: ago,
		duration: duration,
		warranty: warranty,
		project: project,
		amount: amount,
		item: item,
		notes: notes,
		time_machine: time_machine,
		timeshift: timeshift,
		camera: camera,
		feed: feed,
		digits: digits,
		schedule: schedule,
		movement: movement,
		measure_is_open: measure_is_open,
		quantity: quantity,
		lockingStatus: lockingStatus
	};
	$.ajax({
		url: '/manager/reset',
		type: 'POST',
		data: data,
		success: function(response) {
				appClearer(app)
//			centreViewWriter(response);
		//	if ($('.now').attr('presence') != 'not') {

				if (type != 'start' && type != 'record' && navigation != 'resume') {
					navigation = 'once';
				}
				var diff = numeral(timestamp).value - numeral(now).value;
				diff = Math.abs(diff);
			//	if (diff < (1000 * 60)) {
					continent_record({'uuid':response['uuid'], 'app':response['app'],'purpose':'app','timestamp':response['timestamp'],'navigation':navigation});
			//	}
				calculator();
		//	}
		},
		error: function(error) { console.log(error) }
	});
}

function appClearer(app) {
	$('.appointment[app="' + app + '"]').each(function(i,v) {
		var container = $(v);
		jawnosAppFieldRemove(app, 'notes');
		jawnosAppFieldRemove(app, 'ago');
		jawnosAppFieldRemove(app, 'duration');
		container.find('.ago').val('');
		container.find('.duration').val('');
		container.find('.schedule').val('');
		container.find('.text_editor').html('').trigger('change');
	});
}

function centreViewWriter(response) { 
	var res = $(response).find('.appointment');
	var app = $(res).attr('app');

	var appointments = $('body').find('.appointment');
	var matches = 0;
	if (appointments.length > 0) {
		$.each(appointments, function(n,val) {
			if ($(val).attr('app') == app) {
			//	$(val).replaceWith(response).show();
				matches = 1;
				windowMaker(response);
			}
		});
	}
	if (matches == 0) {
		windowMaker(response);
	}
	appointment_chron();
}


function appointmentGrabber(app,timestamp,source) {
	var waiter = 0;
	if (timestamp == '') {
		timestamp = Date.now();
	}
	if (source == 'onchange') {
		waiter = 500;
	}
	var jpR = jpReport(app);
	var appt = JSON.stringify({ app: app, name: app, source: 'grabber', jpReport: jpR });
	setTimeout(function() {
		$.ajax({ 
			url: '/manager/centre_view',
			type: 'GET',
			data: { app: appt, timestamp: timestamp, source: source },
			success: function(response) {
				centreViewWriter(response);
				jpRestore(app,jpR);
				var done = Date.now();
				console.log(app + ' ' + numeral(done - timestamp).value());
			}
		});
	},waiter);
}

var windows = [];
var top_level_now = 100;
var winLine = 0;
var fullXCount = 0;
var fullYCount = 0;


async function random_word(words) {
	var timestamp = Date.now();
	return await $.ajax({
		url: '/manager/random_word',
		type: 'GET',
		data: { 'times': words, 'timestamp': timestamp },
		success: function(response) {
			return response;

		}
	});
}

$(document).on('click', '.measures', function() {
	var a = $(this);
	var timestamp = Date.now();
	var parent = a.closest('.appointment');
	var app = parent.attr('app');
	var container = $('.appointment[app="' + app + '"]').find('.re_measures');
	if (container.is(':visible')) {
		container.hide();
	}
	else {
		appActExclusive(app, 'measures');
		appointmentMeasuresGrabber(a);
		container.show();
	}
});

$(document).on('touchmove mouseout hover keydown keyup touchend mousedown mouseup mousewheel', '.app_measure', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var value = mdm.val();
	var unit = mdm.attr('unit');
	var measure = mdm.attr('measure');
	appt.find('.app_measure_display[measure="' + measure + '"]').text(value + unit);


});

$(document).on('change keyup', '.app_measure', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var value = mdm.val();

	if (mdm.attr('multiple')) {
		value = JSON.stringify(value);
	}
	else if (mdm.attr('type') == 'checkbox') {
		if (mdm.prop('checked') == true) {
			value = 'on';
		}
		else {
			value = 'off';
		}
	}



	var measure = mdm.attr('measure');
	appt.find('.app_measure_display[measure="' + measure + '"]').text(value);
	mdm.attr('changed', 'yes');
	$.ajax({
		url: 'manager/app_measures',
		type: 'POST',
		data: { app: app, value: value, measure: measure, just_one: true, setting_only: 'yes', timestamp: timestamp },
		success: function(response) {
		}
	});
});


var amsave;
$(document).on('click', '.app_measure_save', function() {
	var mdm = $(this);
	var appt = mdm.closest('.appointment');
	var app = appt.attr('app');
	var container = mdm.closest('.appointment');
	var ago = $('#ago').val() || container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	appt.find('.app_measure[changed="yes"]').each(function(i,v) {

		var val = $(v).val();
		var measure = $(v).attr('measure');

		$.ajax({
			url: 'manager/app_measures',
			type: 'POST',
			data: { app: app, value: val, measure: measure, just_one: true, timestamp: timestamp, timeshift: timeshift, time_machine: time_machine, ago: ago },
			success: function(response) {
				$(v).attr('changed',undefined);
				mdm.addClass('superactive');
				clearTimeout(amsave);
				amsave = setTimeout(function() {
					mdm.removeClass('superactive');
				},1000);
				appClearer(app);
			}
		});
	});
});

$(document).on('click','.app_measure_delete', function() {
	var b = $(this);
	var app = b.closest('.appointment_detail').attr('app');
	var uuid = b.attr('uuid');
	var app_uuid = b.closest('.appointment_detail').attr('uuid');
	var armed = b.attr('armed');


	if (armed == 'yes') {
		b.addClass('superactive');
		$.ajax({
			url: '/manager/app_measure_delete',
			type: 'POST',
			data: { app: app, app_uuid: app_uuid, uuid: uuid },
			success:function(response) {

			}
		});
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

$(document).on('click','.edit_app',function() {

	var edit = $(this);
	var uuid = edit.attr('uuid');
	var app = edit.attr('app');
	var timestamp = edit.attr('timestamp');
	var appointment = edit.closest('.appointment');
	var ea = $('.appointment_edit_area[uuid="' + uuid + '"][app="' + app + '"]');
	if (ea.is(':visible')) {
		ea.hide();
	}
	else {
		$.ajax({
			url: '/manager/edit_app',
			type: 'GET',
			data: { app: app, uuid: uuid, timestamp: timestamp },
			success: function(response) {
				ea.html(response).show();
			}
		});

	}

});
$(document).on('click','.edit_app_submit', function() {
	var edit = $(this);
	var app = edit.attr('app');
	var uuid = edit.attr('uuid');
	var ea = $('.appointment_edit_area[uuid="' + uuid + '"]');
	var app_name = ea.find('[attribute="app"]').val();
	var timestamp = ea.find('[attribute="timestamp"]').attr('timestamp');
	var duration = ea.find('[attribute="duration"]').val();
	var warranty = ea.find('[attribute="warranty"]').attr('timestamp');
	var account = ea.find('[attribute="account"]').val();
	var project = ea.find('[attribute="project"]').val();
	var start_notes = ea.find('[attribute="start_notes"]').val();
	var notes = ea.find('[attribute="notes"]').val();
	var end_notes = ea.find('[attribute="end_notes"]').val();
	var movement = ea.find('[attribute="movement"]').val();
	var amount = ea.find('[attribute="amount"]').val();
	var tax = ea.find('[attribute="tax"]').val();
	var aux = ea.find('[attribute="aux"]').val();
	var total = ea.find('[attribute="total"]').val();
	var vendor = ea.find('[attribute="vendor"]').val();
	var unit = ea.find('[attribute="unit"]').val();
	var quantity = ea.find('[attribute="quantity"]').val();
	var has_tax = ea.find('.purchase_config[config="tax"]').attr('enabled');
	var has_totes = ea.find('.purchase_config[config="totes"]').attr('enabled');
	var item = ea.find('[attribute="item"]').val();
	var model = ea.find('[attribute="model"]').val();
	var state = ea.find('[attribute="state"]').val();
	$.ajax({
		url: '/manager/edit_app',
		type: 'POST',
		data: { 
			app: app,
			app_name: app_name,
			uuid: uuid, 
			timestamp: timestamp, 
			duration: duration, 
			warranty: warranty,
			account: account,
			project: project,
			start_notes: start_notes,
			notes: notes,
			end_notes: end_notes,
			movement: movement,
			amount: amount,
			tax: tax,
			aux: aux,
			total: total,
			vendor: vendor,
			unit: unit,
			quantity: quantity,
			item: item,
			model: model,
			has_tax: has_tax,
			has_totes: has_totes,
			state: state
		},
		success: function(response) {
			edit.removeClass('medium_thumb');
			edit.addClass('large_thumb');
			setTimeout(function() {
				edit.removeClass('large_thumb');
				edit.addClass('medium_thumb');
			}, 2000);
		},
	});
});

$(document).on('click', '.delete_app', function() {
	var a = $(this);
	var app = a.attr('app');
	var formatted_name = a.attr('formatted_name');
	var formatted_time = a.attr('formatted_time');
	var formatted_duration = a.attr('formatted_duration');
	var uuid = a.attr('uuid');
	var app_type = a.attr('app_type');
	var server_time = a.attr('server_time');
	var timestamp = a.attr('timestamp');
	var armed = a.attr('armed');

	if (armed == 'yes') {
		$.ajax({
			url: '/manager/delete_app',
			type: 'POST',
			data: { app: app, uuid: uuid, timestamp: timestamp, type: app_type, server_time: server_time },
			success: function(response) {
				$('.appointment_detail[uuid="' + uuid + '"]').remove();
				if (response.deleter.status == 'start' || response.deleter.status == 'record') {
					continent_cancel(app);
				}
			},
			error: function(err) { 
				$('#alert').html('It didn\'t work! Try again!<br><br><button id="alert_cancel">Cancel</button>');	
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

$(document).on('click', '.delete_file', function() {
	var a = $(this);
	var app_uuid = a.attr('app_uuid');
	var file_uuid = a.attr('file_uuid');
	var app = a.attr('app');
	if (a.attr('armed')) {
		$.ajax({
			url: '/manager/delete_file',
			type: 'POST',
			data: { app_uuid: app_uuid, file_uuid: file_uuid, app: app },
			success: function(response) {
				$.each(images, function(i,v) {
					if (v['app'] == response.app && response.file_uuid == v['uuid']) {
						images.splice(i,1);
						if (image_number == i && ($('#main_video').is(':visible') || $('#main_image').is(':visible'))) {
							galleryImageDisplayer();
						}
					}


				});
				$('[app_uuid="' + response.app_uuid + '"][file_uuid="' + response.file_uuid + '"]').remove();
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

$(document).on('change', '.file_information_updater', function() {
	var a = $(this);
	var value = a.val();
	var f = a.closest('.file_information');
	var attribute = a.attr('attribute');
	var file_uuid = f.attr('file_uuid');
	var app_uuid = f.attr('app_uuid');
	var app = f.attr('app');
	var data = { app: app, file_uuid: file_uuid, app_uuid: app_uuid, attribute: attribute, value: value };
	$.ajax({
		url: '/manager/file/information_updater',
		type: 'POST',
		data: data,
		success: function(response) {
			a.val(response['value']);
		}
	});
});


$(document).on('click', '.close_appointment', function() {
	var t = $(this);
	var p = t.closest('.appointment');
	var w = p.closest('.window_view');
	p.closest('.wind').remove();
	var height = $(window).height(); 
	if (p.find('#mouse_shadow')) { $('#mouse_shadow').css({ 'top': height }); }
	var containers = p.find('.appointment');
	if (containers.length == 1) {
		p.hide();
	}
	var app = t.attr('app');
	websocketStop(app);

	windowSaver();
	$('#' + app).remove();
	$('#' + app).closest('.wind').remove();
	if (w.find('.appointment :visible').length == 0) {
		w.hide();
	}
});

function appointmentMeasuresGrabber(a) {
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_measures');
	$.ajax({
		url: '/manager/appointment_measures',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			container.html(response).show();
		}
	});
}


$(document).on('click', '.det', function() {

	var a = $(this);
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_details');
	// an area showing no appointments is not an open list: treat it as closed, so
	// the tap refetches the current timeframe's appointments instead of just hiding
	// an empty panel
	if (container.is(':visible') && container.find('.appointment_detail').length > 0) {
		container.html('<span class="detail_json" app="' + app + '">{}</span>').hide();
	}
	else {
		appActExclusive(app, 'det');
		appointmentDetailsGrabber(a);
		container.show();
	}
});

$(document).on('click', '.register', function() {
	var a = $(this);
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	var container = parent.find('.re_register');
	if (container.is(':visible')) {
		container.html('').hide();
	}
	else {
		appActExclusive(app, 'register');
		registerGrabber(app);
		container.show();
	}
});

function registerGrabber(app) {
	var container = $('.appointment[app="' + app + '"]').find('.re_register');
	$.ajax({
		url: '/manager/register_grabber',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			container.html(response.html);
			openAttributeReopener(app)
		}
	});
}


var appDetailsScroll = {};

$(document).on('mousewheel touchmove', '.detail_area', function(e) {
	if ($(e.target).is('canvas')) {
		e.preventDefault();e.preventDefault();
	}
	var app = $(this).attr('app');
	var scroll = $(this).offset().top;
	var height = $(this).height();
	var cheight = $(this).closest('.appointment').height();
	if ((height - (cheight + Math.abs(scroll))) < 530) {
		if (appDetailsScroll[app]['reload'] == 0) {
			appDetailsScroll[app]['reload'] = 1;
			
		//	appointmentDetailsGrabber($(this),'scroll');
		}
	}
});

function appointmentDetailsGrabber(a,source) {
	var parent = a.closest('.appointment');
	var app = a.attr('app');
	if ($('.wind[app="' + app + '"]').length > 0) {
		var container = parent.find('.re_details');
		container.html('');
		var timestamp = Date.now();
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var time_machine = localStorage.getItem('time_machine');
		var sorts = localStorage.getItem('sorts');
		var scope = localStorage.getItem('scope');
		var filter = localStorage.getItem('filter');

		if (source == 'scroll') {

		}

		var variables = { sorts: sorts, app: app, filter: filter, time_machine: time_machine, timeshift: timeshift, timestamp: timestamp, scope: scope };
		$.ajax({ 
			url: '/manager/appointment_details',
			type: 'GET',
			data: variables,
			success: function(response) {
				container.html(response);
				container.show();
				appointment_chron();
				appDetailsScroll[app]['reload'] = 0;
			}
		});
	}
}

function appointmentDetailGrabber(app,uuid) {
	if ($('.wind[app="' + app + '"]').length > 0) {
		var timestamp = Date.now();
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var time_machine = localStorage.getItem('time_machine');
		var sorts = localStorage.getItem('sorts');
		var scope = localStorage.getItem('scope');
		var filter = localStorage.getItem('filter');
		var variables = { uuid: uuid, sorts: sorts, app: app, filter: filter, time_machine: time_machine, timeshift: timeshift, timestamp: timestamp, scope: scope };
		var lists = []
		$('.appointment_detail[uuid="' + uuid + '"]').find('.appointment_list').each(function(i,v) {
			if ($(v).is(':visible')) {
				lists.push($(v).attr('list'));
			}
		});
		$.ajax({
			url: '/manager/appointment_details',
			type: 'GET',
			data: variables,
			success: function(response) {
				var selector = '.appointment_detail[uuid="' + uuid + '"][app=\"' + app + '\"]';
				if ($(selector).length > 0) {
					$(selector).html($(response).find(selector).html());
				}
				else {
					$('.detail_area[app="' + app + '"]').append($(response).find(selector).clone());
				}
				appointment_chron();
				var q = $('.appointment_detail[app="' + app + '"]').length;
				$('.detail_quantity[app="' + app + '"]').text(q);
				$.each(lists, function(i,v) {
					$('.appointment_detail[uuid="' + uuid + '"]').find('.appointment_list[list="' + v + '"]').show();
				});
			}
		});
	}
}

function appointmentDetailsUpdater(app) {

	var updates = {};
	var selector1 = '.detail_area';
	if (app) {
		selector1 = '.detail_area[app="' + app + '"]';
	}
	$(selector1).each(function(n,ve) {
		var dapp = $(ve).attr('app');
		if ($('.wind[app="' + dapp + '"]').length > 0) {
			updates[dapp] = {};
			updates[dapp]['details'] = [];
			var data = $('.detail_json[app="' + dapp + '"]').text() || {};
			updates[dapp]['data'] = JSON.parse(data);
			$.ajax({
				url: '/manager/appointment_details',
				type: 'GET',
				data: updates[dapp]['data'],
				success: function(response) {
					var results = $(response).find('.appointment_detail[app="' + dapp + '"]');

					results.each(function(i,v) {
						var uuid = $(v).attr('uuid');
						var last_update = $(v).attr('last_update');
						var selector = '.appointment_detail[app="' + dapp + '"][uuid="' + uuid + '"]';
						var vn = $(selector);
						if (vn.length > 0 && vn.is(':visible')) {
							if ($(v).attr('last_update') > vn.attr('last_update')) {
								vn.replaceWith($(v).clone());
							}
						}
						else {
							$('.detail_area[app="' + dapp + '"]').append($(v).clone());
						}
						var q = results.length;
						$('.detail_quantity[app="' + dapp + '"]').text(q);
					});
				}	
			});
		}
	});
}

$(document).on('click', '.notespace', function() {
	var text = $(this).html();
	text = text.replaceAll('<br>', "\n");
	
	var notes = $(this).closest('.appointment').find('.notes');

	notes.val(text);


});

$(document).on('click', '.notes_toggle', function() {
	var toggle = $(this);
	var timestamp = Date.now();
	var app = toggle.attr('app');
	var app_timestamp = toggle.attr('timestamp');
	var server_time = toggle.attr('server_time');
	var uuid = toggle.attr('uuid');
	var appointment = toggle.closest('.appointment_detail');
	var notespace = appointment.find('.notespace');
	if (notespace.html() == '') {
		$.ajax({
			url: '/manager/note_retriever',
			type: 'GET',
			data: { app_timestamp: app_timestamp, timestamp: timestamp, app: app, server_time: server_time, uuid: uuid },
			success: function(response) {
				notespace.html(response.notes).show();
			}
		});
	}
	else {
		notespace.html('');
		notespace.hide();
	}
});


$(document).on('click', '.leave', function() {
	leave();
});
function leave() {
	var d = JSON.stringify(localStorage);
	jpStop();
	websocketStop();
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/leave',
		type: 'POST',
		data: { timestamp: timestamp, debriefer: d },
		success: function(response) {
			localStorage.clear();
//			$('body').replaceWith(response);
			location.reload();
		},
		error: function(err) { console.log('Error', err); }
	});
}

var lockSessionTap = null;
function jawnLockScreen(scope) {
	$.post('/manager/lock_session', {
		scope: scope || '',
		device_uuid: localStorage.getItem('device_uuid') || ''
	}, function(res) {
		// the reply carries the overlay: the screen that pressed the lock must
		// cover itself now, not wait for a websocket push that a handheld's
		// worker may not be listening for
		if (!res || !res.ok || !res.html) { return; }
		var pf = $('#padlock_frame');
		// the same black screen a refresh shows: without an opaque backdrop the
		// hidden desktop's texture showed through and the lock looked different
		// depending on which path had turned it
		pf.html(res.html).css({ position: 'fixed', 'z-index': 60000, 'background-color': '#101010' }).show();
		$('#everything').hide();
	}, 'json');
}
$(document).on('click', '#lock_session', function() {
	if (lockSessionTap) {
		clearTimeout(lockSessionTap);
		lockSessionTap = null;
		// double tap: lock the whole house
		jawnLockScreen('all');
		return;
	}
	lockSessionTap = setTimeout(function() {
		lockSessionTap = null;
		// single tap: lock this screen
		jawnLockScreen('');
	}, 300);
});

$(document).on('click', '#alert_cancel', function() {
	$('#alert_message').text('');
	$('#alert').html('');
	$('#alert').hide();
	$('#alert').attr('hidden', 'yes');
});

$(document).on('click','.enabler', function() {
	var strawbeery = $(this);
	var appointment = strawbeery.closest('.appointment');
	var app = appointment.attr('app');
	var timestamp = Date.now();
	var setting = strawbeery.attr('type') || 'notification';
	var status = strawbeery.attr('status');
	var on_colour = strawbeery.attr('on_colour');
	var off_colour = strawbeery.attr('off_colour');
	var dim = strawbeery.attr('dim');
	if (status == 'on') {
		strawbeery.css({ 'background-color': off_colour });
		if (dim) { strawbeery.css({ 'border-color': off_colour, 'opacity': '0.45', 'filter': 'grayscale(1)', 'box-shadow': 'none' }); }
		status = 'off';
	}
	else {
		strawbeery.css({ 'background-color': on_colour });
		if (dim) { strawbeery.css({ 'border-color': on_colour, 'opacity': '1', 'filter': 'none', 'box-shadow': '0 0 8px 2px ' + on_colour }); }
		status = 'on';
	}

	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: app, timestamp: timestamp, setting: setting, value: status, source: 'panel' },
		success: function(response) {
			centreViewWriter(response)
		}
	});
});

// A machine's own Manager, in a window of its own, at that machine's origin.
// It is deliberately not framed inside this page: the peer's localStorage and
// cookies then belong to the peer's origin alone (and a framed peer would be
// refused by the app gate, which admits installed apps, not nested browsers).
// The desktop app opens a real window at the peer and lets its app-required
// page sign in with this install's key; a plain browser gets a new tab.
function jawnosDesktopCall(action, args) {
	return new Promise(function (resolve, reject) {
		if (!window.JawnDesktop || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.jawnos) {
			reject({ error: 'unavailable' }); return;
		}
		var id = 'app' + Date.now() + Math.random().toString(36).slice(2);
		var done = false;
		// an older desktop app ignores the action and never replies; do not hang
		var timer = setTimeout(function () {
			if (done) { return; }
			done = true;
			window.__jawnAppResult = null;
			reject({ error: 'timeout' });
		}, 2500);
		window.__jawnAppResult = function (rid, res) {
			if (rid !== id || done) { return; }
			done = true;
			clearTimeout(timer);
			window.__jawnAppResult = null;
			if (res && res.ok) { resolve(res); } else { reject(res || { error: 'failed' }); }
		};
		try {
			window.webkit.messageHandlers.jawnos.postMessage(JSON.stringify({ action: action, id: id, args: args || {} }));
		}
		catch (e) {
			window.__jawnAppResult = null;
			reject({ error: 'unavailable' });
		}
	});
}

// A peer ticket can arrive as a path. Resolve it against the peer's own
// manager, never against this page's origin: the local origin would open this
// house's manager (the local Gate) instead of the peer's.
function jawnosRemoteUrl(url, manager) {
	if (!url) { return ''; }
	if (/^https?:\/\//i.test(url)) { return url; }
	if (manager && /^https?:\/\//i.test(manager)) {
		try { return new URL(url, manager).href; } catch (e) {}
	}
	return url;
}

function jawnosRemoteManagerWindow(url, uuid, name, device, manager) {
	if (!url) { return; }
	url = jawnosRemoteUrl(url, manager);
	var device_uuid = device || '';
	if (!device_uuid) {
		try { device_uuid = localStorage.getItem('device_uuid') || ''; } catch (e) { device_uuid = ''; }
	}
	if (window.JawnDesktop) {
		jawnosDesktopCall('open_manager', { url: url, manager: manager || url, device_uuid: device_uuid, name: name || '' }).catch(function (err) {
			// Only an older desktop app (no open_manager) needs the browser
			// fallback. A refusal from this app must not open a tab at the
			// local manager.
			if (err && err.error === 'unavailable') { window.open(url, '_blank', 'noopener'); }
		});
		return;
	}
	window.open(url, '_blank', 'noopener');
}

function jawnosRemoteManagerOpen(uuid, manager, gesture) {
	if (!uuid && !manager) { return; }
	// window.open() after the ajax reply is no longer inside the click's
	// gesture, so a browser blocks it as a popup. When a click calls us, take
	// the window now and navigate it with the resolved address. The installed
	// desktop app opens through its own bridge and never needs this.
	var preopened = null;
	if (gesture && !window.JawnDesktop) {
		try { preopened = window.open('', '_blank'); } catch (e) { preopened = null; }
	}
	var data = {
		timestamp: Date.now(),
		// The desktop bridge is what opens a real JawnOS window; when it is
		// missing the page can only hand the URL to the default browser.
		desktop: window.JawnDesktop ? 1 : 0,
		bridge: (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.jawnos) ? 1 : 0
	};
	if (uuid) { data.uuid = uuid; }
	else { data.manager = manager; }
	$.ajax({
		url: '/manager/remote_manager',
		type: 'GET',
		data: data,
		dataType: 'json',
		success: function (r) {
			if (!r) { if (preopened) { preopened.close(); } return; }
			if (r.need_approval) {
				if (preopened) { preopened.close(); }
				jawnosGoPrompt(r, uuid, manager);
				return;
			}
			if (r.manager) {
				var target = jawnosRemoteUrl(r.ticket_url || r.manager, r.manager || manager);
				if (preopened) {
					preopened.opener = null;
					preopened.location.href = target;
				}
				else { jawnosRemoteManagerWindow(target, r.uuid || uuid, r.name, r.device_uuid, r.manager); }
			}
			else if (preopened) { preopened.close(); }
		},
		fail: function (xhr) {
			// The app gate answers a session that has not signed the installed
			// app with the app-required page. The app can sign itself in and
			// retry; a browser has no key, so it still gets the plain window.
			if (xhr && xhr.responseText && xhr.responseText.indexOf('JawnOS app required') >= 0
				&& typeof jawnAppLogin === 'function') {
				if (preopened) { preopened.close(); }
				jawnAppLogin(true).then(function () {
					jawnosRemoteManagerOpen(uuid, manager);
				}, function () {
					if (manager) { jawnosRemoteManagerWindow(manager, uuid); }
				});
				return;
			}
			// An old stored Go link can name a machine the roster no longer
			// matches. Open that address when it is a real host; never open this
			// machine's own manager (the tunnel loopback) as if it were a peer.
			if (manager && !/^https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\])(?::|\/|$)/i.test(manager)) {
				var fallback = jawnosRemoteUrl(manager, manager);
				if (preopened) {
					preopened.opener = null;
					preopened.location.href = fallback;
				}
				else { jawnosRemoteManagerWindow(fallback, uuid); }
			}
			else {
				if (preopened) { preopened.close(); }
				else if ($('#remote_control_go').length) {
					$('#remote_control_go').attr('hint', jawnosT('That machine has no reachable address'));
				}
			}
		}
	});
}

// A Go from the installed app asks for a second factor before the peer ticket
// is minted. The server names what this house can provide: this computer's
// reader, the phone's own Keystore print, or another paired device's print.
// The request is short-lived and bound to this session; the approved poll mints
// the ticket and opens the peer exactly as the direct path did.
function jawnosGoPrompt(r, uuid, manager) {
	var t = function (s, v) { return (typeof jawnosT === 'function') ? jawnosT(s, v) : s; };
	var done = false;
	var timer = null;
	var fingerBtn = null;
	var phoneBtn = null;
	var askBtn = null;
	var noBtn = null;
	var box = $('<div>').attr('id', 'jawnos_go_prompt').attr('role', 'dialog').attr('aria-modal', 'true').css({
		position: 'fixed', zIndex: 71000, left: '50%', top: '50%', transform: 'translate(-50%,-50%)',
		width: 'min(92vw,380px)', background: '#161616', color: '#f4f4f4', border: '1px solid #444',
		borderRadius: '14px', padding: '18px', boxShadow: '0 12px 40px rgba(0,0,0,.55)',
		fontFamily: 'sans-serif', textAlign: 'center'
	});
	var title = $('<div>').css({ fontSize: '19px', lineHeight: '1.35', marginBottom: '6px' }).text(t('Open {0}?', r.name || t('the machine')));
	var note = $('<div>').css({ fontSize: '14px', color: '#bbb', marginBottom: '14px', minHeight: '18px' }).text(t('Confirm it is you before this window opens.'));
	var row = $('<div>');
	var btnCss = 'font-size:14px;padding:9px 14px;border-radius:9px;border:1px solid #555;background:#222;color:#f4f4f4;cursor:pointer;margin:0 4px 8px 4px;';
	function addButton(text, css, handler) {
		var b = $('<button type="button">').text(text).css(css).on('click', handler);
		row.append(b);
		return b;
	}
	function enable(on) {
		$(row).find('button').prop('disabled', !on);
	}
	function disable(keep) {
		var keepers = keep || [];
		$(row).find('button').each(function () {
			if (this === noBtn || keepers.indexOf(this) >= 0) { return; }
			$(this).prop('disabled', true);
		});
	}
	if (r.fingerprint) {
		fingerBtn = addButton(t("Use this computer's fingerprint"), btnCss + 'border-color:#2b6;background:#2b6;color:#08110a;font-weight:bold;', function () { startFingerprint(); });
	}
	if (r.phone_fingerprint && window.JawnBiometricKey && typeof jawnosBiometricGo === 'function') {
		phoneBtn = addButton(t("Use this phone's fingerprint"), btnCss + 'border-color:#2b6;background:#2b6;color:#08110a;font-weight:bold;', function () { startPhone(); });
	}
	if (r.devices && r.devices.length) {
		askBtn = addButton(t('Ask another device'), btnCss, function () { startAsk(); });
	}
	noBtn = addButton(t('Not now'), btnCss, function () { close(); });
	box.append(title).append(note).append(row);
	$('body').append(box);

	function close() {
		done = true;
		if (timer) { clearInterval(timer); timer = null; }
		box.remove();
	}
	function wait(text) { note.text(text); }
	function open(res) {
		close();
		var url = (res && res.ticket_url) || r.manager;
		if (!url) { return; }
		jawnosRemoteManagerWindow(url, (res && res.uuid) || r.uuid || uuid, (res && res.name) || r.name,
			(res && res.device_uuid) || r.device_uuid, (res && res.manager) || manager || r.manager);
	}
	function failed() {
		if (done) { return; }
		wait(t('That did not work. Try again.'));
		enable(true);
	}
	function poll() {
		if (done) { return; }
		$.ajax({ url: '/manager/security/go_status', type: 'GET', data: { request_id: r.request_id, timestamp: Date.now() }, dataType: 'json', cache: false })
			.done(function (res) {
				if (done) { return; }
				if (res && res.approved && res.ticket_url) { open(res); return; }
				if (!res || !res.ok) {
					wait(t('That did not work. Try again.'));
					close();
				}
			})
			.fail(function () { failed(); });
	}
	function startFingerprint() {
		disable([askBtn]);
		wait(t('Touch the fingerprint reader now...'));
		$.ajax({ url: '/manager/security/fingerprint_unlock', type: 'POST', data: { purpose: 'go', request_id: r.request_id, timestamp: Date.now() }, dataType: 'json', cache: false })
			.done(function (res) {
				if (res && res.pending && res.token) { pollPrint(res.token, 0); return; }
				failed();
			})
			.fail(function () { failed(); });
	}
	function pollPrint(token, tries) {
		$.ajax({ url: '/manager/security/fingerprint_unlock_status', type: 'GET', data: { token: token, timestamp: Date.now() }, dataType: 'json', cache: false })
			.done(function (res) {
				if (done) { return; }
				if (res && res.pending) {
					if (tries > 30) { wait(t('The reader timed out.')); enable(true); return; }
					setTimeout(function () { pollPrint(token, tries + 1); }, 700);
					return;
				}
				if (res && res.ok) { wait(t('Approved. Opening...')); poll(); return; }
				failed();
			})
			.fail(function () { failed(); });
	}
	function startPhone() {
		disable([askBtn]);
		wait(t('Confirm your fingerprint...'));
		jawnosBiometricGo(r.request_id, r.name, function (s) { wait(s); }).then(function () {
			wait(t('Approved. Opening...'));
			poll();
		}).catch(function (err) {
			if (done) { return; }
			wait((typeof jawnosBiometricError === 'function') ? jawnosBiometricError(err) : t('That did not work. Try again.'));
			enable(true);
		});
	}
	function startAsk() {
		disable([fingerBtn, phoneBtn]);
		wait(t('Waiting for another device...'));
		$.ajax({ url: '/manager/security/go_ask', type: 'POST', data: { request_id: r.request_id, timestamp: Date.now() }, dataType: 'json', cache: false })
			.done(function (res) {
				if (res && res.ok) { wait(t('Waiting for another device...')); return; }
				failed();
			})
			.fail(function () { failed(); });
	}
	// The preferred factor asks first (the laptop's reader, or the phone's own
	// Keystore print); another device stays one tap away, and Not now is always
	// live. A desktop with no reader falls through to asking the house.
	timer = setInterval(poll, 1200);
	if (r.fingerprint) {
		startFingerprint();
	}
	else if (r.phone_fingerprint && window.JawnBiometricKey && typeof jawnosBiometricGo === 'function') {
		startPhone();
	}
	else {
		poll();
	}
}

$(document).on('click', '.remote_manager_open', function (e) {
	// a new tab is still a legitimate way to open it
	if (e.ctrlKey || e.metaKey || e.shiftKey || e.which === 2) { return; }
	e.preventDefault();
	var b = $(this);
	jawnosRemoteManagerOpen(b.attr('uuid'), b.attr('manager'), true);
});

// Go links filed in remote_machines.buttons before the button existed still
// open the machine's window rather than a tab.
$(document).on('click', '.remote_machine_buttons a[target="_blank"]', function (e) {
	if (e.ctrlKey || e.metaKey || e.shiftKey || e.which === 2) { return; }
	var href = $(this).attr('href') || '';
	if (href.indexOf('/manager') < 0) { return; }
	e.preventDefault();
	jawnosRemoteManagerOpen('', href, true);
});

function cacheSet(params,data) {
	var jdata = JSON.stringify(data);
	$.ajax({
		url: '/manager/cache_set',
		type: 'POST',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: params['timestamp'],
			data: jdata
		},
		success: function(response) {}
	});
}

async function cacheGet(params) {

	return $.ajax({
		url: '/manager/cache_get',
		type: 'GET',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: params['timestamp'],
		},
		success: function(response) {
		}
	});
}

function cacheDelete(params) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/cache_delete',
		type: 'POST',
		data: {
			app: params['app'],
			context: params['context'],
			subcontext: params['subcontext'],
			timestamp: timestamp,
		},
		success: function(response) {}
	});
}
