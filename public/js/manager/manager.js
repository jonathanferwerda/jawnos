var nfc = {
	scanning: false,
	writing: false,
	abort: new AbortController(),
	initialized: false,
	lastWrite: 0,
	lastReadKey: '',
	lastReadAt: 0
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
	// the words under the record controls are anchored on the view, so the open
	// windows must be asked again now that the centre has moved
	if (typeof jawnosTimePreviewRefreshAll == 'function') { jawnosTimePreviewRefreshAll(); }
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
			+ (mine ? 'background:var(--chat-bubble-me);' : 'background:var(--chat-bubble-them);') + '">' + safe + '</span>';
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
		+ '<span class="chat_bubble" style="display:inline-block;max-width:84%;overflow-wrap:break-word;border-radius:10px;padding:6px 10px;background:var(--chat-bubble-them);">'
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
function assistantAppOpen(app, question) {
	var name = 'app_' + (app || 'window');
	return assistantOpenConversation(name, (app || 'Window'), question);
}

// Open an associate with a question already asked. Used when a schedule needs
// clarifying: the appointment or bill is made, and the Associate is handed the
// token and the question so it can finish the repeats.
function assistantAskFresh(app, question) {
	if (typeof assistantAppOpen !== 'function') { return null; }
	return assistantAppOpen(app, question);
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
	var data = {
		transcript: JSON.stringify(assistantThread(panel)),
		context: JSON.stringify(ctx),
		topic: panel.data('topic') || '',
		model: assistantModel(panel)
	};
	// page mode: hand the guide the visible form it was attached to, so it can
	// read a value and fill the field in one turn
	if (typeof pageAgentMode === 'function' && pageAgentMode(panel)) {
		data.page = JSON.stringify(pageAgentSnapshot(panel));
	}
	$.ajax({
		url: '/manager/help/act',
		type: 'POST',
		dataType: 'json',
		data: data,
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
			jawnos_page_agent_panel = panel;
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
	// a new conversation reads the room afresh
	if (typeof jawnRoomReset === 'function') { jawnRoomReset(); }
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
			+ '<span style="display:inline-block;max-width:84%;border-radius:10px;padding:5px;background:var(--chat-bubble-me);">'
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
	clone.removeData('page_app');
	clone.removeData('page_window');
	clone.removeData('page_on');
	clone.find('.assistant_page_badge').hide();
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
function assistantOpenConversation(name, title, question) {
	var existing = $('.assistant_view[conversation="' + name + '"]');
	if (existing.length) {
		var open = assistantOpenPanel(existing.first());
		if (question) {
			open.find('.assistant_question').val(question);
			if (typeof assistantAsk === 'function') { assistantAsk(open); }
		}
		return open;
	}
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
		if (!transcript.length) { assistantChatAdd(panel, 'step', 'Nothing was said here yet.'); }
		else {
			var shown = 0;
			transcript.forEach(function (m) {
				var role = m.role || 'user';
				var content = String(m.content || '');
				if (role === 'user') { assistantChatAdd(panel, 'user', content); shown++; }
				else if (role === 'assistant' && !/^\s*\{/.test(content)) { assistantChatAdd(panel, 'guide', content); shown++; }
			});
			if (!shown) { assistantChatAdd(panel, 'step', 'Nothing was said here yet.'); }
		}
		log.scrollTop(log[0] ? log[0].scrollHeight : 0);
		if (question) {
			panel.find('.assistant_question').val(question);
			if (typeof assistantAsk === 'function') { assistantAsk(panel); }
		}
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
			// A second write while one waits for a tag replaces the first, so the
			// first promise must settle instead of hanging the caller's state.
			if (pendingWrite) {
				var stale = pendingWrite;
				pendingWrite = null;
				try { stale.reject(new DOMException('superseded', 'AbortError')); } catch (e) {}
			}
			return new Promise(function(resolve, reject) {
				pendingWrite = { resolve: resolve, reject: reject };
				var result = window.JawnNFC.write(JSON.stringify({ records: records }));
				if (result !== 'ok') { pendingWrite = null; reject(new Error('nfc write: ' + result)); }
			});
		},
		// Tell the app to drop a write nobody is waiting for any more; otherwise
		// the next unrelated tag tapped would silently be overwritten.
		cancelWrite: function() {
			if (pendingWrite) {
				var w = pendingWrite;
				pendingWrite = null;
				try { w.reject(new DOMException('aborted', 'AbortError')); } catch (e) {}
			}
			if (window.JawnNFC && typeof window.JawnNFC.cancelWrite === 'function') {
				try { window.JawnNFC.cancelWrite(); } catch (e) {}
			}
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
			// A tag seen while a write is armed belongs to that write, and a tag
			// reported just after a successful write is the same tag being read
			// back - neither is a tap, so neither may start or stop an app.
			if (nfc['writing']) { return; }
			if (nfc['lastWrite'] && Date.now() - nfc['lastWrite'] < 2500) { return; }

			var md = [];
			$.each(message.records || [], function(i,record) {
				if (record.recordType === "text" || record.recordType === "url") {
					// 6. Decode the binary DataView payload into a string
					try {
						const textDecoder = new TextDecoder(record.encoding || "utf-8");
						md.push({'text': textDecoder.decode(record.data) });
					} catch (e) {}
				}
				if (record.mediaType === "application/json") {
					try {
						const decoder = new TextDecoder();
						md.push(JSON.parse(decoder.decode(record.data)));
					} catch (e) {}
				}
			});
			if (!md.length) { return; }

			var jmessage = JSON.stringify(md);
			// Reader mode can report one presence twice (and a second reader
			// object would double every tap); one tap must act only once.
			var readKey = (serialNumber || '') + '|' + jmessage;
			if (nfc['lastReadKey'] === readKey && Date.now() - (nfc['lastReadAt'] || 0) < 1500) { return; }
			nfc['lastReadKey'] = readKey;
			nfc['lastReadAt'] = Date.now();

			var timestamp = Date.now();
			var lastWrite = nfc['lastWrite'];

			$.ajax({
				url: '/manager/nfc/read',
				type: 'POST',
				data: { message: jmessage, serial: serialNumber, last_write: lastWrite, timestamp: timestamp, benign: nfc['benign'] },
				success: function(response) {
					var jr = JSON.stringify(response);

					$('.nfc_read_status').text(response.status);
					if (response && response.construct_app && typeof peopleConstructOpen === 'function') {
						peopleConstructOpen(response.construct_app);
					}
					else if (response && response.crest_uuid && typeof peopleCrestOpen === 'function') {
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
	if (!nfc['ndef'] || nfc.scanning || nfc.writing) { return; }
	if (nfc.scanFailedAt && Date.now() - nfc.scanFailedAt < 2000) { return; }
	nfc.scanning = true;
	nfc['abort'] = new AbortController();
	try {
		await nfc['ndef'].scan({ signal: nfc['abort'].signal });
	}
	catch (error) {
		// A refused scan (permission, a second tab, the reader still busy)
		// must not wedge the reader: drop the flag and retry once after a
		// beat, never in a tight loop on every mouse event.
		nfc.scanning = false;
		nfc.scanFailedAt = Date.now();
		if (!nfc.scanRetry) {
			nfc.scanRetry = setTimeout(function() {
				nfc.scanRetry = null;
				nfcListener();
			}, 2000);
		}
	}
}

// Show a write's progress on its own tag card, so a failed or still-waiting
// write is visible instead of leaving the button lit and the reader disarmed.
function nfcText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}
function nfcWriteStatus(a, text, kind) {
	if (!a || !a.length) { return; }
	var row = a.closest('.nfc_settings');
	if (!row.length) { return; }
	row.find('.nfc_write_status').text(text || '').removeClass('on error').addClass(kind || '');
}

var nfcWriteTimer = null;
var nfcWriteSession = 0;

async function nfcWriter(msg,a) {
	if (device != 'mobile') { return; }
	if (!nfc['ndef'] || typeof nfc['ndef'].write !== 'function') {
		nfcWriteStatus(a, nfcText('No NFC reader here.'), 'error');
		return;
	}
	if (nfc.writing) { return; }

	// The tag carries only the row uuid's first 12 characters. The old write
	// embedded the whole settings row (control, taps, serials - hundreds of
	// bytes), which no longer fit a 144-byte NTAG213 once the tap count grew;
	// that is why a write would fail and only succeed on re-scan or on a
	// larger tag.
	var tag = String(msg.uuid || '').slice(0, 12);
	if (!tag.length) { return; }
	var encoder = new TextEncoder();
	var session = ++nfcWriteSession;
	nfc.writing = true;
	a.addClass('active_background');
	nfcWriteStatus(a, nfcText('Hold the tag to the phone…'), '');

	var expiry = new Promise(function(resolve, reject) {
		clearTimeout(nfcWriteTimer);
		nfcWriteTimer = setTimeout(function() {
			reject(new Error('timeout'));
		}, 25000);
	});

	try {
		// Web NFC's write must begin inside the click's gesture, so it is
		// called before any network round trip.
		await Promise.race([
			nfc['ndef'].write({
				records: [{
					recordType: 'mime',
					mediaType: 'application/json',
					data: encoder.encode(JSON.stringify({ tag: tag }))
				}]
			}),
			expiry
		]);
		nfc['lastWrite'] = Date.now();
		nfcWriteStatus(a, nfcText('Tag saved.'), 'on');
		// Stamp the write on the server after the tag itself is written; the
		// tag needs nothing from this round trip.
		$.ajax({ url: '/manager/nfc/write', type: 'POST', data: { uuid: msg.uuid, app: msg.app, type: msg.type } });
	}
	catch (error) {
		try { if (nfc['ndef'].cancelWrite) { nfc['ndef'].cancelWrite(); } } catch (e) {}
		if (error && error.message === 'timeout') {
			nfcWriteStatus(a, nfcText('No tag found. Hold the tag to the phone and try again.'), 'error');
		}
		else if (!error || error.name !== 'AbortError') {
			nfcWriteStatus(a, nfcText('Could not write the tag. Hold it still and try again.'), 'error');
		}
	}
	finally {
		clearTimeout(nfcWriteTimer);
		nfcWriteTimer = null;
		if (session == nfcWriteSession) {
			nfc.writing = false;
			a.removeClass('active_background');
			nfcListener();
		}
	}
}


$(document).on('click', 'input',function() {

	focused_input.removeClass('focused_input');
//	focused_input.css({'background-image': '' });
//	focused_input.trigger('change');
	focused_input = $(this);
//	focused_input.addClass('focused_input');

	if ($('#numberpad').is(':visible')) {
		focused_input.blur();
	}
});
$(document).on('click', 'textarea',function() {
	focused_input = $(this);

	if ($('#numberpad').is(':visible')) {
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
	clipboardSetter($(this).text());
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

$(document).on('click', '#ticketmaker', function() {
	boxOffice();
});

// The two views are tabs now. The value still lives in #box_office_view (a
// hidden input) so boxOffice() and the server keep reading one place.
$(document).on('click', '.bo_tab', function() {
	var view = $(this).attr('view');
	if (!view || view === $('#box_office_view').val()) { return; }
	$('#box_office_view').val(view);
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
	localStorage.setItem('ticket_waiting', message || 'Pass request');
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
	}
}



$(document).on('click', '.box_office_close_button', function() { 
	$('#ticket_sales').hide();
});

$(document).on('click', '#ticket_issue', function() {
	qrcode_generator();
});

function qrcode_generator(app) {
	var timestamp = Date.now();
	var button = $('#ticket_issue');
	var status = $('#ticket_issue_status');
	var nic = $('#ticket_network_device').val();
	var name = $('#ticket_name').val();
	var warranty = $('#ticket_warranty').val();
	var privilege = $('#ticket_privilege').val();
	var project = $('#ticket_project').val();
	var chosen_app = app || $('#ticket_app').val();
	var debriefer = JSON.stringify(localStorage);

	if (!chosen_app) {
		status.text(jawnosT('Choose an app first.'));
		return;
	}
	if (button.length) { button.prop('disabled', true).text(jawnosT('Issuing…')); }
	status.text('');

	$.ajax({
		url: '/manager/qrcode_generator',
		type: 'GET',
		data: { timestamp: timestamp, nic: nic, debriefer: debriefer, name: name, warranty: warranty, privilege: privilege, app: chosen_app, project: project },
		success: function(response) {
			if (response && !response.error && response.uuid) {
				var who = response.name || name || 'visitor';
				status.empty().text(jawnosT('Pass issued for') + ' ' + who + ' (' + chosen_app + '). ');
				if (response.url) {
					$('<a>').attr({ href: response.url, target: '_blank', rel: 'noopener' }).text(jawnosT('Open')).appendTo(status);
				}
				ticket_list();
			}
			else {
				status.text(jawnosT('The pass could not be issued.'));
			}
		},
		error: function() {
			status.text(jawnosT('The pass could not be issued.'));
		},
		complete: function() {
			if (button.length) { button.prop('disabled', false).text(jawnosT('Issue pass')); }
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
			bo_ticket_count();
		}
	});
}

// The Tickets tab and the card's own count both read the rows on the page.
function bo_ticket_count() {
	$('#bo_ticket_count').text($('#ticket_list_body .ticket_holder').length);
}

// Copying the link matters: the link is the credential and retyping it from
// the row is how the old desk made people share a secret badly.
function bo_copy_text(text, button) {
	var done = function() {
		var old = button.text();
		button.text(jawnosT('Copied'));
		setTimeout(function() { button.text(old); }, 1500);
	};
	var fallback = function() {
		var ta = $('<textarea>').val(text).css({ position: 'fixed', opacity: 0, top: 0, left: 0 });
		$('body').append(ta);
		ta[0].select();
		try { document.execCommand('copy'); done(); } catch (e) { /* the browser refused both */ }
		ta.remove();
	};
	if (navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(text).then(done, fallback);
	}
	else { fallback(); }
}

$(document).on('click', '.bo_copy_link', function() {
	var b = $(this);
	bo_copy_text(b.attr('data-url') || '', b);
});

$(document).on('click', '.ticket', function(e) {
	// a ticket's duration is a reading, not the card's resize handle
	if ($(e.target).closest('.jawnos_duration').length) { return; }
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
				bo_ticket_count();
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
	$('#ticket_network_meta').text(t.find('option:selected').text());
});


var searchingTimeout;
var lastSearchTime;
var jawnosSearchApps = null;
var jawnosSearchVersion = '';
var jawnosSearchLoading = null;
var jawnosSearchChecking = false;
var jawnosSearchSelected = -1;
var jawnosSearchEnterConsumed = false;

// The searchable app list. Every keystroke is filtered here, so the box never
// waits on a request. A force fetch replaces the list; otherwise the copy the
// page already has is good until the version check says it is not.
function jawnosSearchIndex(force) {
	if (jawnosSearchApps && !force) { return $.Deferred().resolve(jawnosSearchApps).promise(); }
	if (jawnosSearchLoading) { return jawnosSearchLoading; }
	jawnosSearchLoading = $.ajax({ url: '/manager/search_index', type: 'GET', dataType: 'json', cache: false })
		.then(function (response) {
			jawnosSearchApps = (response && response.apps) ? response.apps : [];
			jawnosSearchVersion = (response && response.version) || '';
			jawnosSearchLoading = null;
			return jawnosSearchApps;
		}, function () {
			jawnosSearchLoading = null;
			return jawnosSearchApps || [];
		});
	return jawnosSearchLoading;
}

// Take the list again after a change and redraw the open dropdown, keeping the
// row the person had walked to when it survived the change.
function jawnosSearchRefresh() {
	return jawnosSearchIndex(true).then(function () {
		var current = $('#search').val();
		if (!current || !$('#search_results').is(':visible')) { return; }
		var selected_app = $('#manager_search_results .manager_search_result.search_selected').attr('app');
		jawnosSearchRender(current);
		if (selected_app) {
			var keep = $('#manager_search_results .manager_search_result').filter(function () {
				return $(this).attr('app') === selected_app;
			});
			if (keep.length) {
				jawnosSearchSelected = parseInt(keep.attr('index'), 10);
				keep.addClass('search_selected');
			}
		}
	});
}

// The cheap question: has any setting the list draws (or a deleted app) moved?
// The full list only crosses the wire when the answer is yes.
function jawnosSearchCheck() {
	if (!jawnosSearchApps || jawnosSearchChecking) { return; }
	jawnosSearchChecking = true;
	var xhr = $.ajax({ url: '/manager/search_index', type: 'GET', dataType: 'json', cache: false, data: { check: 1 } });
	xhr.done(function (response) {
		if (response && response.version && response.version !== jawnosSearchVersion) {
			jawnosSearchRefresh();
		}
	});
	xhr.always(function () { jawnosSearchChecking = false; });
}

// Warm the list while the manager settles, so the first keypress has it. Then
// watch for changes: on the box being focused, on returning to the tab, and
// every two seconds while the dropdown is open, so a deleted app leaves the
// list and a changed pos or main image lands without a reload.
$(function () {
	var warm = function () { jawnosSearchIndex(); };
	if (window.requestIdleCallback) { requestIdleCallback(warm, { timeout: 4000 }); }
	else { setTimeout(warm, 1500); }
	$(document).on('focusin', '#search', jawnosSearchCheck);
	$(window).on('focus', jawnosSearchCheck);
	if (document.addEventListener) {
		document.addEventListener('visibilitychange', function () {
			if (!document.hidden) { jawnosSearchCheck(); }
		});
	}
	setInterval(function () {
		if ($('#search_results').is(':visible') && $('#search').val()) { jawnosSearchCheck(); }
	}, 2000);
});

function jawnosSearchPlain(s) {
	return (s || '').toLowerCase().replace(/_/g, ' ').replace(/\s+/g, ' ').trim();
}

function jawnosSearchClicks() {
	var stored = {};
	try { stored = JSON.parse(localStorage.getItem('jawnos_search_clicks') || '{}') || {}; }
	catch (e) { stored = {}; }
	return stored;
}

// Enter belongs to a chosen result for exactly one press: the input also wears
// timed_input, whose own Enter adds/opens the typed name, and that must not
// fire on the same key. Typing again clears the choice (and the claim).
function jawnosSearchTakeEnter() {
	if (!jawnosSearchEnterConsumed) { return false; }
	jawnosSearchEnterConsumed = false;
	return true;
}

// The list puts what was opened from it most recently at the top, so the app a
// person reaches for keeps coming back under the box.
function jawnosSearchRecordClick(app) {
	var clicks = jawnosSearchClicks();
	// names may be any printable string, so prefix the key: an app called
	// "__proto__" must be stored as an ordinary entry, not as the object's prototype
	clicks['a:' + app] = Date.now();
	var keys = Object.keys(clicks);
	if (keys.length > 200) {
		keys.sort(function (a, b) { return clicks[a] - clicks[b]; });
		keys.slice(0, keys.length - 200).forEach(function (k) { delete clicks[k]; });
	}
	try { localStorage.setItem('jawnos_search_clicks', JSON.stringify(clicks)); } catch (e) {}
}

function jawnosSearchMatches(query) {
	var raw = jawnosSearchPlain(query);
	if (!raw || !jawnosSearchApps) { return []; }
	var words = raw.split(' ');
	var clicks = jawnosSearchClicks();
	var matches = [];
	jawnosSearchApps.forEach(function (app) {
		var name = jawnosSearchPlain(app.app);
		var label = jawnosSearchPlain(app.name);
		var haystack = name + ' ' + label;
		for (var i = 0; i < words.length; i++) {
			if (haystack.indexOf(words[i]) < 0) { return; }
		}
		// an exact name beats a prefix, which beats a name the words appear in
		var exact = (name === raw || label === raw) ? 0 : 1;
		var prefix = (name.indexOf(raw) === 0 || label.indexOf(raw) === 0) ? 0 : 1;
		var click_key = 'a:' + app.app;
		var clicked = Object.prototype.hasOwnProperty.call(clicks, click_key) ? clicks[click_key] : 0;
		matches.push({ app: app, rank: exact * 2 + prefix, clicked: clicked });
	});
	matches.sort(function (a, b) {
		if (a.rank != b.rank) { return a.rank - b.rank; }
		if (!!a.clicked != !!b.clicked) { return a.clicked ? -1 : 1; }
		if (a.clicked != b.clicked) { return b.clicked - a.clicked; }
		return jawnosSearchPlain(a.app.name).localeCompare(jawnosSearchPlain(b.app.name));
	});
	return matches.slice(0, 10);
}

// The dropdown hugs the search box: same width, just above or below it. It is
// pulled out to the body because a transformed ancestor (an auto-hidden
// taskbar, a sliding dock) turns position:fixed into a child of that bar, which
// is what put the list off the top of the screen.
function jawnosSearchResultsPlace() {
	var box = $('#search_results');
	var input = $('#search');
	if (!box.length || !input.length || !box.is(':visible')) { return; }
	var rect = input[0].getBoundingClientRect();
	var vw = window.innerWidth || $(window).width();
	var vh = window.innerHeight || $(window).height();
	// while the on-screen keyboard is up, the keys are the floor of the visible
	// page: the list may not run over them
	var bound = vh;
	var kb = $('#jawn_soft_keyboard');
	if (kb.length && kb.is(':visible')) {
		// measured from its height, not its top edge: the dock slides up, and
		// while it rises its transformed box still starts off the screen
		var kb_top = vh - (kb.outerHeight() || 0);
		if (kb_top > 0 && kb_top < bound) { bound = kb_top; }
	}
	var gap = 6;
	var width = Math.max(0, rect.width);
	var left = Math.max(4, Math.min(rect.left, vw - width - 4));
	var content = $('#manager_search_results').outerHeight() || 0;
	var below = bound - rect.bottom - gap;
	var above = rect.top - gap;
	// below is the natural side; go above only when it has more room
	var place_below = below >= Math.min(content, 80) || below >= above;
	var height = Math.max(0, Math.min(content, place_below ? below : above));
	var drop = {
		'position': 'fixed',
		'left': left,
		'width': width,
		'height': height,
		'right': 'auto',
		// the keyboard sits at 40002: it always paints over the list
		'z-index': 40001,
		'border-width': '3px',
		'text-align': 'center'
	};
	if (place_below) {
		drop['top'] = rect.bottom + gap;
		drop['bottom'] = 'auto';
	}
	else {
		drop['bottom'] = vh - rect.top + gap;
		drop['top'] = 'auto';
	}
	box.css(drop);
}

$(window).on('resize', function () {
	if ($('#search_results').is(':visible')) { jawnosSearchResultsPlace(); }
});

// The details list's Dur column ticks while a session is open: the row carries
// its start, stop and duration, and the same two-unit shape duration_sayer
// gives is rebuilt here (1h 5s, 59m 59s, 1d 1m). The short form is not fixed to
// one denomination: it turns over to days once there is a whole day, then to
// months and years, carrying the next smaller unit beside it.
function jawnosDurationText(seconds, mode) {
	seconds = Math.max(0, Math.floor(Number(seconds) || 0));
	var h = Math.floor(seconds / 3600);
	var m = Math.floor((seconds % 3600) / 60);
	var s = seconds % 60;
	if (mode == 'hours') {
		return h + 'h' + (m ? ' ' + m + 'm' : '');
	}
	if (mode == 'minutes') {
		return Math.floor(seconds / 60) + 'm' + (s ? ' ' + s + 's' : '');
	}
	var days = seconds / 86400;
	var month_days = 30.4375;
	var months = Math.floor((days + 0.5) / month_days);
	if (h < 24) {
		var parts = [];
		if (h) { parts.push(h + 'h'); }
		if (m) { parts.push(m + 'm'); }
		if (s) { parts.push(s + 's'); }
		return parts.length ? parts.slice(0, 2).join(' ') : '0s';
	}
	if (months < 1) {
		var dd = Math.floor(seconds / 86400);
		var dh = Math.floor((seconds % 86400) / 3600);
		var dm = Math.floor((seconds % 3600) / 60);
		var bits = [ dd + 'd' ];
		if (dh) { bits.push(dh + 'h'); }
		if (dm) { bits.push(dm + 'm'); }
		return bits.slice(0, 2).join(' ');
	}
	var years = Math.floor(months / 12);
	var leftover_months = months % 12;
	var leftover_days = Math.max(0, Math.floor(days - months * month_days));
	var units = [];
	if (years > 0) { units.push(years + 'y'); }
	if (leftover_months > 0) { units.push(leftover_months + 'M'); }
	if (leftover_days > 0) { units.push(leftover_days + 'd'); }
	return units.length ? units.join(' ') : '0s';
}

// The span a duration element stands for: an open session grows from its start,
// a closed row keeps the duration the server worked out (falling back to its own
// start and stop), and a plain readout carries its own `duration`. `sign` keeps
// a shortfall reading as a shortfall.
function jawnosDurationSpan(cell, now) {
	now = now || Date.now();
	var ms;
	var sign = cell.attr('sign') == '-' ? '-' : '';
	if (cell.hasClass('appointment_detail_duration')) {
		var type = cell.attr('appt_type') || '';
		var start = Number(cell.attr('timestamp')) || 0;
		var stop = Number(cell.attr('stop_timestamp')) || 0;
		if (!stop && (type == 'start' || type == 'record')) {
			if (!start || start > now) { return null; }
			ms = now - start;
		}
		else {
			ms = Math.abs(Number(cell.attr('duration')) || 0);
			if (!ms && stop && start) { ms = Math.abs(stop - start); }
			if (!ms) { return null; }
		}
		sign = '';
	}
	else {
		ms = Math.abs(Number(cell.attr('duration')) || 0);
		if (!ms) { return null; }
	}
	return { ms: ms, sign: sign };
}

function jawnosDurationTick() {
	// A hidden page cannot paint a duration, and a locked phone was paying for
	// this walk every second in the background. appointment_chron repaints on
	// the way back in.
	if (document.hidden) { return; }
	var now = Date.now();
	$('.appointment_detail_duration, .jawnos_duration').each(function () {
		var cell = $(this);
		var span = jawnosDurationSpan(cell, now);
		if (!span) { return; }
		var display = cell.closest('.wind').attr('app') || '';
		var mode = durationDisplaySaved(display) || 'dynamic';
		var text = span.sign + jawnosDurationText(span.ms / 1000, mode);
		if (cell.text() !== text) { cell.text(text); }
	});
}

$(function () {
	// the one shared second tick (universal.js) paints the duration readouts
	// beside the appointment clocks instead of a second interval walking them
	if (typeof jawnos_tick_register === 'function') {
		jawnos_tick_register('duration', jawnosDurationTick);
	}
	jawnosDurationTick();
});

function jawnosSearchRender(query) {
	var box = $('#search_results');
	if (!box.length) { return; }
	jawnosSearchEnterConsumed = false;
	var matches = jawnosSearchMatches(query);
	jawnosSearchSelected = -1;
	if (matches.length == 0) {
		box.html('').hide();
		return;
	}
	var list = $('<div id="manager_search_results"></div>');
	matches.forEach(function (match, i) {
		var row = $('<div class="hover manager_search_result"></div>').attr('app', match.app.app).attr('index', i);
		row.append($('<img class="manager_search_icon" alt="">').attr('src', match.app.icon || ''));
		row.append($('<span class="manager_search_label"></span>').text(match.app.name || match.app.app));
		list.append(row);
	});
	// leave any transformed bar behind so the fixed coordinates are the viewport's
	if (box.parent()[0] !== document.body) { box.appendTo(document.body); }
	box.html(list).show();
	jawnosSearchResultsPlace();
}

function jawnosSearchMove(direction) {
	var rows = $('#manager_search_results .manager_search_result');
	if (!rows.length) { return; }
	if (jawnosSearchSelected < 0) {
		jawnosSearchSelected = direction > 0 ? 0 : rows.length - 1;
	}
	else {
		jawnosSearchSelected = (jawnosSearchSelected + direction + rows.length) % rows.length;
	}
	rows.removeClass('search_selected');
	var chosen = rows.eq(jawnosSearchSelected).addClass('search_selected');
	var box = $('#search_results');
	if (chosen.length && box.length) {
		var row_top = chosen.position().top + box.scrollTop();
		var row_bottom = row_top + chosen.outerHeight();
		if (row_top < box.scrollTop()) { box.scrollTop(row_top); }
		else if (row_bottom > box.scrollTop() + box.height()) { box.scrollTop(row_bottom - box.height()); }
	}
}

// A built-in app opens through the same toggle the menu uses; anything else is
// an appointment and opens through its centre view.
function jawnosSearchOpen(app) {
	if (!app) { return; }
	jawnosSearchRecordClick(app);
	$('#search_results').hide();
	$('#start_menu').hide();
	if (typeof pseudonymHomeHider == 'function') { pseudonymHomeHider(pseudonymHIntervals); }
	// the common apps have a direct opener, so the real app opens even on a
	// layout where the menu's own button is not in the document
	var openers = { music: 'musicToggle', help: 'helpOpener', mailbox: 'mailMaker' };
	if (Object.prototype.hasOwnProperty.call(openers, app) && typeof window[openers[app]] == 'function') {
		window[openers[app]]();
		return;
	}
	var special = {
		configure: '#main_logo.configuration',
		budget: '#budget',
		box_office: '#ticketmaker',
		gallery: '#image_toggle',
		market: '.market_toggle',
		warehouse: '.warehouse_toggle',
		process_monitor: '.process_monitor_toggle',
		measures: '.measures_toggle'
	};
	var special_toggle = Object.prototype.hasOwnProperty.call(special, app) ? special[app] : '';
	var toggle = special_toggle ? $(special_toggle) : $(document.getElementById(app + '_toggle'));
	if (toggle.length) { toggle.trigger('click'); return; }
	if (typeof appointmentGrabber == 'function') { appointmentGrabber(app, Date.now()); }
}

$(document).on('keyup click', '#search', function(e) {
	var search = $(this).val();
	var timestamp = Date.now();
	lastSearchTime = timestamp;
	clearTimeout(searchingTimeout);
	searchingTimeout = setTimeout(function() {
		$('#search').val('');
		$('#search_results').hide();
		jawnosSearchSelected = -1;
	}, 5000 * 60);
	// the arrow keys, Enter and Escape belong to the keydown handler; keyup for
	// them must not redraw the list and drop the selection it just made
	if (e.type == 'keyup') {
		if (e.keyCode == 13) {
			// a chosen result owns this Enter; the timed_input add/reset must not run
			if (jawnosSearchTakeEnter()) {
				e.preventDefault();
				e.stopImmediatePropagation();
			}
			return;
		}
		if (e.keyCode == 38 || e.keyCode == 40 || e.keyCode == 27) { return; }
		// typing again makes the next Enter the box's own
		jawnosSearchEnterConsumed = false;
	}
	if (!search) {
		$('#search_results').hide();
		jawnosSearchSelected = -1;
		return;
	}
	jawnosSearchIndex().then(function () {
		if ($('#search').val() == search) { jawnosSearchRender(search); }
	});
});

$(document).on('keydown', '#search', function(e) {
	var code = e.keyCode || e.which;
	var box = $('#search_results');
	var shown = box.is(':visible');
	if (code == 40 || code == 38) {
		if (!shown) { jawnosSearchRender($(this).val()); shown = box.is(':visible'); }
		if (!shown) { return; }
		e.preventDefault();
		jawnosSearchMove(code == 40 ? 1 : -1);
	}
	else if (code == 13) {
		// Enter only belongs to the list once a result has been chosen with the
		// arrows; otherwise the box keeps its own Enter (the add/reset)
		if (!shown || jawnosSearchSelected < 0) { return; }
		var rows = $('#manager_search_results .manager_search_result');
		if (!rows.length) { return; }
		e.preventDefault();
		jawnosSearchEnterConsumed = true;
		jawnosSearchOpen(rows.eq(jawnosSearchSelected).attr('app'));
	}
	else if (code == 27) {
		if (shown) {
			e.preventDefault();
			box.hide();
			jawnosSearchSelected = -1;
		}
	}
});

$(document).on('mouseenter', '.manager_search_result', function() {
	var i = parseInt($(this).attr('index'), 10);
	if (isNaN(i)) { return; }
	jawnosSearchSelected = i;
	$('#manager_search_results .manager_search_result').removeClass('search_selected');
	$(this).addClass('search_selected');
});

$(document).on('click', '.manager_search_result', function() {
	jawnosSearchOpen($(this).attr('app'));
});


$(document).on('click', '.search_toggle', function(i,e) {
	// on a side dock the input rides hidden: the first press calls it out, and
	// only a press with the input showing runs the search itself. A button that
	// rides the taskbar has its input in sight already, so it just searches.
	if (typeof jawnosSideDock == 'function' && jawnosSideDock() && $(this).closest('#pseudonym_home').length > 0 && !jawnosSideSearchVisible()) {
		jawnosSideSearchShow(1);
		return;
	}
	// The magnifier opens the Search app: one window with the Apps, Web and AI
	// contexts, remembering the last tab. The dock's box stays where it is and
	// keeps its own dropdown while typing; this press hands the query over.
	var search = $('#search').val() || '';
	localStorage.setItem('lastSearchTime', Date.now());
	localStorage.setItem('search', search);
	$('#search_results').html('').hide();
	if (typeof window.jawnosSearchAppOpen === 'function') {
		window.jawnosSearchAppOpen(search);
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
	jawnosAlertClose();
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
	var menu = localStorage.getItem('start_menu_menu') || '';
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
					// The server resolves an empty menu to this install's default
					// (the System page on a first run, the app list afterwards), so
					// the cache and the saved choice follow what was actually drawn.
					var shown = response.menu || menu || '';
					if (shown && !localStorage.getItem('start_menu_menu')) {
						localStorage.setItem('start_menu_menu', shown);
					}
					startMenuHtml[shown] = response.html;
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
// The built-in icons the start menu draws, keyed by the app they open. A
// private app is not drawn at all; the server sends its key in hidden_apps, and
// the icon is removed before the rows are assembled (so the recents list cannot
// put it back). A custom app is not in this grid, and its running rows are
// filtered server-side.
var startMenuIconApps = {
	internet_toggle: 'internet', search_app_toggle: 'search', folders_toggle: 'folders',
	budget: 'budget', travel_toggle: 'travel', relational_toggle: 'relational', people_toggle: 'people',
	mailbox_toggle: 'mailbox', email_toggle: 'email', chat_toggle: 'chat', music_toggle: 'music',
	embedded_toggle: 'embedded', ticketmaker: 'box_office', cards_toggle: 'cards', web_toggle: 'web',
	backup_now: 'backup', security_toggle: 'security', terminal_toggle: 'terminal', network_toggle: 'network',
	ide_toggle: 'ide', image_toggle: 'gallery', camera_toggle: 'camera', phone_toggle: 'phone',
	synth_toggle: 'synth', editor_toggle: 'editor', marker_toggle: 'marker', notes_toggle: 'notes',
	clock_toggle: 'clock', home_toggle: 'home', store_toggle: 'store', process_monitor_toggle: 'process_monitor'
};

function startMenuHidePrivate(main) {
	var hidden = (main.attr('hidden_apps') || '').split('|');
	if (!hidden.length || (hidden.length == 1 && !hidden[0])) { return; }
	$.each(startMenuIconApps, function (id, app) {
		if ($.inArray(app, hidden) < 0) { return; }
		main.find('#' + id).each(function () {
			var img = $(this);
			var row = img.closest('.start_menu_item');
			if (row.length) { row.remove(); return; }
			var parent = img.parent();
			img.remove();
			if (parent.length && !parent.children().length && !parent.text().replace(/\s+/g, '').length) { parent.remove(); }
		});
	});
}

function startMenuListify() {
	var main = $('.start_menu_main_display');
	if (main.length == 0) { return; }
	startMenuHidePrivate(main);
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
		// a chosen search result owns this Enter; typing again clears the choice
		if ($(this).is('#search') && typeof jawnosSearchTakeEnter == 'function' && jawnosSearchTakeEnter()) { return; }
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

// ---- appointment distance: the fixes list or a Travel basemap ----
// The Dist section is one panel. Its picker swaps the list of fixes for a canvas
// map drawn by jawnosMap, and offers only the basemaps the house can actually
// draw: the free services, or a keyed one whose key is already saved in Travel.
function appointmentDistKeys(panel) {
	var keys = {};
	panel.find('.appointment_map_key').each(function() {
		var provider = $(this).attr('provider');
		var value = $(this).val();
		if (provider && value) { keys[provider] = value; }
	});
	return keys;
}

function appointmentDistFill(detail) {
	var panel = $(detail).find('.appointment_distance_panel');
	if (!panel.length || !window.jawnosMap) { return; }
	var sel = panel.find('.appointment_dist_view');
	if (!sel.length || sel.attr('filled') == 'yes') { return; }
	sel.attr('filled', 'yes');
	var keys = appointmentDistKeys(panel);
	var providers = window.jawnosMap.providers || {};
	var group = $('<optgroup></optgroup>').attr('label', jawnosT('Map'));
	var added = 0;
	for (var key in providers) {
		var p = providers[key] || {};
		var kind = p.group || 'url';
		if (kind === 'free' || (kind === 'key' && keys[key])) {
			$('<option></option>').attr('value', key).text(jawnosT(p.name || key)).appendTo(group);
			added++;
		}
	}
	if (added) { sel.append(group); }
}

function appointmentDistShow(panel) {
	if (!panel || !panel.length) { return; }
	var kind = panel.find('.appointment_dist_view').val() || 'fixes';
	panel.find('.appointment_distance_fixes').toggle(kind === 'fixes');
	panel.find('.appointment_distance_map').toggle(kind !== 'fixes');
	if (kind !== 'fixes') { appointmentDistMap(panel, kind); }
}

function appointmentDistMap(panel, provider) {
	var canvas = panel.find('.appointment_dist_canvas')[0];
	if (!canvas || !window.jawnosMap) { return; }
	var data = {};
	try { data = JSON.parse(panel.find('.appointment_distance_data').text() || '{}') || {}; }
	catch (e) { data = {}; }
	var engine = panel.data('appointmentDistMap');
	if (!engine || engine.canvas !== canvas) {
		engine = window.jawnosMap.create(canvas.id, {
			z: 15,
			width: function() { return $(canvas).parent().width() || 480; },
			height: function() { return $(canvas).parent().height() || 320; }
		});
		panel.data('appointmentDistMap', engine);
	}
	engine.setProvider(provider, '', appointmentDistKeys(panel));
	var points = [];
	var fixes = data.points || [];
	var home = data.home || {};
	var fixPoints = [];
	fixes.forEach(function(p) {
		if (!p || !p.latitude || !p.longitude) { return; }
		fixPoints.push({ lat: +p.latitude, lon: +p.longitude, t: +p.timestamp || 0, colour: '#a0503f' });
	});
	fixPoints.sort(function(a, b) { return a.t - b.t; });
	// a line through the run of fixes, the same track Travel draws
	engine.setLines(fixPoints.length > 1 ? [{ colour: '#a0503f', points: fixPoints.map(function(p) { return { lat: p.lat, lon: p.lon }; }) }] : []);
	fixPoints.forEach(function(p) { points.push({ lat: p.lat, lon: p.lon, colour: '#a0503f' }); });
	if (home.latitude && home.longitude) {
		points.push({ lat: home.latitude, lon: home.longitude, colour: '#6f4f9f', label: jawnosT('Home') });
	}
	engine.setPoints(points);
	// frame the fixes themselves, so a home plate far away cannot shrink them to a
	// dot; the home point still rides on the map when it is in view
	var frame = fixPoints.length ? fixPoints : (home.latitude && home.longitude ? [{ lat: home.latitude, lon: home.longitude }] : []);
	if (frame.length) {
		var lats = frame.map(function(p) { return p.lat; });
		var lons = frame.map(function(p) { return p.lon; });
		var minLat = Math.min.apply(null, lats), maxLat = Math.max.apply(null, lats);
		var minLon = Math.min.apply(null, lons), maxLon = Math.max.apply(null, lons);
		if (Math.max(maxLat - minLat, maxLon - minLon) < 0.002) {
			var lat = (minLat + maxLat) / 2, lon = (minLon + maxLon) / 2;
			engine.fitBounds({ nw: { lat: lat + 0.001, lon: lon - 0.001 }, se: { lat: lat - 0.001, lon: lon + 0.001 } }, 1);
		}
		else {
			engine.fitBounds({ nw: { lat: maxLat, lon: minLon }, se: { lat: minLat, lon: maxLon } }, 1.25);
		}
	}
	engine.draw();
}

$(document).on('change', '.appointment_dist_view', function() {
	appointmentDistShow($(this).closest('.appointment_distance_panel'));
});

$(document).on('click', '.appointment_list_toggle', function() {
	var list = $(this).attr('list');
	var detail = $(this).closest('.appointment_detail');
	var l = detail.find('.appointment_list[list="' + list + '"]');
	if (l.is(':visible')) {
		l.hide();
	}
	else {
		l.show();
		if (list == 'distance') {
			appointmentDistFill(detail);
			appointmentDistShow(l.filter('.appointment_distance_panel'));
		}
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

// Autostop on a running appointment: ticked means the home plate stops it when
// left, unticked leaves it running for a hand stop. The box is put back the way
// it was when the write is refused, so the bar never lies about the session.
$(document).on('change', '.appointment_autostop', function() {
	var a = $(this);
	var app = a.attr('app');
	var uuid = a.attr('uuid');
	var value = a.prop('checked') ? 'on' : 'off';
	a.prop('disabled', true);
	$.ajax({
		url: '/manager/appointment/autostop',
		type: 'POST',
		data: { app: app, uuid: uuid, value: value },
		success: function(response) {
			a.prop('disabled', false);
			if (!response || !response.autostop) {
				a.prop('checked', !a.prop('checked'));
				return;
			}
			a.prop('checked', response.autostop != 'off');
			a.closest('.appointment_autostop_bar').attr('autostop', response.autostop);
		},
		error: function() {
			a.prop('disabled', false);
			a.prop('checked', !a.prop('checked'));
		}
	});
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

// The title in a window's bar is a label, not a source: clicking it raises the
// window (the .top_navbar handler), but it does not pour the app's name into
// the focused input. An appointment's own .name_text still does.
$(document).on('click', '.name_text', function(){
	if ($(this).closest('.top_navbar').length) { return; }
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

// The media machine choice is a preference of this person at this screen, like
// the keyboard's own device picks; remembering it in `me` makes the next
// appointment open on the same machine.
$(document).on('change', '.media_machine', function() {
	var sel = $(this);
	var group = sel.attr('group') || '';
	if (!group) { return; }
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: 'me', setting: 'media_machine_' + group, value: sel.val() || '', timestamp: Date.now() }
	});
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
			// a long note also goes to the server, so a crash or another device
			// keeps it; the ago and duration stay in this browser only
			if (v == 'notes' && typeof jawnosAppDraftSend === 'function') {
				jawnosAppDraftSend(appointment, typed);
			}
		});
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

	// The desk has no appointment view to keep current: its clock runs on a
	// one-second tick of its own and its clothesline is read once a minute (both
	// in desk.js), so the whole appointment_viewer round trip is skipped.
	if (localStorage.getItem('layout') == 'desk') {
		if (typeof windowBackgroundAdjuster == 'function') { windowBackgroundAdjuster({ caller: 'calculator' }); }
		if (typeof deskShow == 'function') { deskShow(); }
		return;
	}

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
								jawnosAlert(response.confirmation);
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
			jawnosAlertClose();
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
	clothesLineHeight = (clotheslineEnabled && respons.clothesline.length) ? clothesLineBaseHeight : 0;
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
	$.each(['leaderboard', 'clockface', 'timeline', 'calendar', 'continent', 'narrator', 'desk'], function(i,v) {
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
	// the desk is a wallpaper plus a layer of items, not a canvas printer; the
	// layer loads the listing the first time it is shown and after any change
	if (layout == 'desk') {
		if (typeof deskShow == 'function') { deskShow(); }
	}
	else if (typeof deskHide == 'function') {
		deskHide();
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
	// the rail's band is only known once it has hung, so the desk's icons take
	// their place under it after it does
	if (layout == 'desk' && typeof deskPosition == 'function') { deskPosition(); }
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

	var chapter = localStorage.getItem('handbook_chapter') || 'today';
	if (chapter == 'undefined' || chapter == 'null') { chapter = 'today'; }
	var url = '/manager/handbook/' + chapter;
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
	if (chapter) { localStorage.setItem('handbook_chapter', chapter); }
	if (page) { localStorage.setItem('handbook_page', page); }
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

// --- Handbook: Today -------------------------------------------------------
// The daily page carries its own day in a `day` param. Typing is read by the
// same resolver the clock uses (today, yesterday, jul 16, 2025-10-21), and the
// whole window is re-rendered in place, so its size and place are kept.
function handbookTodayGo(day) {
	localStorage.setItem('handbook_chapter', 'today');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/handbook/today',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, day: day },
		success: function(response) {
			windowMaker(response);
		}
	});
}

$(document).on('click', '.handbook_today_arrow', function() {
	handbookTodayGo($(this).attr('day'));
});

$(document).on('click', '#handbook_today_reset', function() {
	handbookTodayGo('today');
});

$(document).on('focus', '#handbook_today_date', function() {
	try { this.select(); } catch (e) {}
});

$(document).on('keydown keypress keyup', '#handbook_today_date', function(e) {
	e.stopPropagation();
	if (e.type != 'keydown') { return; }
	if (e.keyCode == 13) {
		e.preventDefault();
		handbookTodayGo($(this).val() || 'today');
	}
});

$(document).on('click', '.handbook_today_open_app', function(e) {
	e.stopPropagation();
	// a duration chip in the row is a reading that turns on its own click, not a
	// way to open the appointment it sits beside
	if ($(e.target).closest('.jawnos_duration').length) { return; }
	var app = $(this).attr('app');
	if (app) { appointmentGrabber(app); }
});

$(document).on('click', '.handbook_today_budget', function() {
	if (typeof budgetInit == 'function') { budgetInit(); }
});

$(document).on('click', '.handbook_today_relational', function() {
	if (typeof relationalOpener == 'function') { relationalOpener(); }
});

$(document).on('click', '.handbook_today_people_open', function() {
	if (typeof peopleOpener == 'function') { peopleOpener(); }
});

// The journal writes into the notes store tagged for the Handbook. The Guide's
// plant action reads those entries and writes ideas/plans/dreams as appointments
// on their future days, so they appear when the daily page is turned to them.
function handbookTodayT(text, value) {
	if (typeof jawnosT == 'function') { return jawnosT.apply(null, arguments); }
	return (value === undefined) ? text : text.replace('{0}', value);
}

function handbookJournalStatus(text, is_error) {
	$('#handbook_today_journal_status').text(text || '').toggleClass('error', !!is_error);
}

function handbookJournalSave(reload) {
	var text = $('#handbook_today_journal_text').val();
	var day = $('#handbook_today_date').val() || 'today';
	if (!text || !text.replace(/\s/g, '')) {
		handbookJournalStatus(handbookTodayT('Write something first.'), true);
		return $.Deferred().resolve(false).promise();
	}
	handbookJournalStatus(handbookTodayT('Saving...'));
	return $.ajax({
		url: '/manager/handbook/journal',
		type: 'POST',
		data: { text: text, day: day },
		dataType: 'json'
	}).done(function(response) {
		if (response && response.ok) {
			handbookJournalStatus(handbookTodayT('Saved.'));
			$('#handbook_today_journal_text').val('');
			if (reload !== false) { handbookTodayGo(day); }
		}
		else { handbookJournalStatus((response && response.error) || handbookTodayT('Could not save.'), true); }
	}).fail(function() {
		handbookJournalStatus(handbookTodayT('Could not save.'), true);
	});
}

function handbookPlant() {
	var text = $('#handbook_today_journal_text').val() || '';
	var day = $('#handbook_today_date').val() || 'today';
	// save first, so the Guide reads the entry that was just typed; then plant
	if (text && text.replace(/\s/g, '')) {
		handbookJournalSave(false).done(function(response) {
			if (response && response.ok) { handbookPlantNow(day); }
		});
	}
	else { handbookPlantNow(day); }
}

function handbookPlantNow(day) {
	var button = $('#handbook_today_plant');
	button.prop('disabled', true);
	handbookJournalStatus(handbookTodayT('Reading the journal...'));
	$('#handbook_today_planted_result').empty();
	$.ajax({
		url: '/manager/handbook/plant',
		type: 'POST',
		data: { day: day },
		dataType: 'json',
		timeout: 180000
	}).done(function(response) {
		if (!response || !response.ok) {
			handbookJournalStatus((response && response.error) || handbookTodayT('The Guide could not read the journal.'), true);
			return;
		}
		var items = response.planted || [];
		if (!items.length) {
			handbookJournalStatus(response.skipped ? handbookTodayT('Nothing new was planted.') : handbookTodayT('Nothing pointed forward yet.'));
			return;
		}
		$('#handbook_today_journal_text').val('');
		handbookJournalStatus(handbookTodayT('Planted {0} entries.', items.length));
		var html = '<div class="handbook_today_planted_list"><b>' + handbookTodayT('Planted across time') + '</b><ul>';
		$.each(items, function(i, item) {
			var title = $('<div>').text(item.title || '').html();
			var kind = $('<div>').text(item.kind || '').html();
			var when = $('<div>').text(item.day || '').html();
			html += '<li><a href="#" class="handbook_today_planted_jump" day="' + when + '">' + title + '</a> <span class="handbook_today_planted_when">' + kind + ' &middot; ' + when + '</span></li>';
		});
		html += '</ul></div>';
		$('#handbook_today_planted_result').html(html);
	}).fail(function() {
		handbookJournalStatus(handbookTodayT('The Guide could not read the journal.'), true);
	}).always(function() {
		button.prop('disabled', false);
	});
}

$(document).on('click', '#handbook_today_journal_save', function() {
	handbookJournalSave(true);
});

$(document).on('click', '#handbook_today_plant', function() {
	handbookPlant();
});

$(document).on('click', '.handbook_today_planted_jump', function(e) {
	e.preventDefault();
	handbookTodayGo($(this).attr('day'));
});

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
		topLevelNow(win);
	}
	else {
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
	var type = details.attr('type');
	// the media group's video/audio/screen buttons are record presses: the button
	// names the source, the row is a type=record like any other (so it moves
	// stock, stops, and edits the same way). A plain record press reads the
	// record row's machine too, so the dropdown governs every way of recording.
	var recorder = '';
	var media_group = details.attr('media_group') || '';
	if (media_group == 'record' && (type == 'video' || type == 'audio' || type == 'screen')) {
		recorder = type;
		type = 'record';
	}
	else if (!media_group && type == 'record') {
		media_group = 'record';
	}
	var media_machine = media_group ? container.find('.media_machine[group="' + media_group + '"]').first() : $();
	var remote_uuid = media_machine.length ? (media_machine.val() || '') : '';
	var remote_signatorial = media_machine.length ? (media_machine.find('option:selected').attr('data-signatorial') || '') : '';
	var digits = details.attr('digits');
	var item = form.find('.item').val();
	var amount = form.find('.amount').val();
	var ago = $('#ago').val() || container.find('.ago').val();
	var duration = container.find('.duration').val();
	var schedule = container.find('.schedule').val();
	var quantity = container.find('.main_input.quantity').val();
	var notes = container.find('.text_editor').html();
	var now = Date.now();
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
		remote_uuid: remote_uuid,
		remote_signatorial: remote_signatorial,
		recorder: recorder,
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
				if (response && response.schedule_ask && typeof assistantAskFresh === 'function') {
					assistantAskFresh(app, response.schedule_ask);
				}
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
	// the note has been filed on the appointment: the draft it grew from is done
	if (typeof jawnosAppDraftSend === 'function') { jawnosAppDraftSend(app, ''); }
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

// ---------------------------------------------------------------- app back
// A launched single-app view (JawnAppActivity) asks this before leaving the
// app: the app's own view history answers first, so Back walks a Gallery photo
// to its album to the albums page instead of jumping straight to Home. An app
// with no handler falls through to the WebView's history and then the activity.
var jawnosBackHandlers = {};
function jawnosRegisterBack(app, handler) {
	if (app && typeof handler === 'function') { jawnosBackHandlers[app] = handler; }
}
function jawnosAppBack(app) {
	var handler = jawnosBackHandlers[app];
	if (typeof handler !== 'function') { return false; }
	try { return handler() === true; } catch (e) { return false; }
}
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
	// Only the controls this form actually rendered are written. An absent
	// control used to ride into the POST as '' (jQuery serialises undefined to
	// key=), which blanked good columns; the `sent` list lets the route tell
	// "unchanged" from "the person cleared this field".
	var payload = { app: app, uuid: uuid, sent: [] };
	var control = function (name) {
		return ea.find('input[attribute="' + name + '"], select[attribute="' + name + '"], textarea[attribute="' + name + '"]').first();
	};
	var put = function (name) {
		var f = control(name);
		if (!f.length) { return; }
		var v = (f.attr('type') == 'checkbox') ? (f.prop('checked') ? 'on' : 'off') : f.val();
		payload[name] = (v === undefined || v === null) ? '' : v;
		payload.sent.push(name);
	};
	var put_attr = function (name, attr) {
		var f = control(name);
		if (!f.length) { return; }
		var v = f.attr(attr);
		payload[name] = (v === undefined || v === null) ? '' : v;
		payload.sent.push(name);
	};
	put('duration');
	var name_input = ea.find('[attribute="app"]').first();
	if (name_input.length) { payload.app_name = name_input.val() || ''; payload.sent.push('app_name'); }
	put('account');
	put('project');
	put('start_notes');
	put('notes');
	put('end_notes');
	put('movement');
	put('amount');
	put('tax');
	put('aux');
	put('aux_description');
	put('total');
	put('vendor');
	put('unit');
	put('quantity');
	put('item');
	put('state');
	put_attr('timestamp', 'timestamp');
	put_attr('warranty', 'timestamp');
	$.each({ tax: 'has_tax', totes: 'has_totes' }, function (config, name) {
		var c = ea.find('.purchase_config[config="' + config + '"]');
		if (!c.length) { return; }
		payload[name] = c.attr('enabled') || 'off';
		payload.sent.push(name);
	});
	payload.sent = payload.sent.join(',');
	$.ajax({
		url: '/manager/edit_app',
		type: 'POST',
		data: payload,
		success: function(response) {
			edit.removeClass('medium_thumb');
			edit.addClass('large_thumb');
			setTimeout(function() {
				edit.removeClass('large_thumb');
				edit.addClass('medium_thumb');
			}, 2000);
		},
		error: function(xhr) {
			if (xhr && xhr.status == 409) { alert('That name is already in use.'); }
		},
	});
});

$(document).on('click', '.edit_app_clone', function() {
	var b = $(this);
	var app = b.attr('app');
	var ea = b.closest('.appointment_edit_area');
	var status = ea.find('.edit_app_status');
	var name = $.trim(ea.find('[attribute="clone_name"]').val() || '');
	if (!name) { status.text('Type a name for the clone.'); return; }
	status.text('Cloning...');
	$.ajax({
		url: '/manager/clone_app',
		type: 'POST',
		data: { app: app, new: name, timestamp: Date.now() },
		success: function(response) {
			if (response && response.ok) { status.text('Cloned to ' + response.app + '.'); }
			else { status.text((response && response.error) || 'Could not clone.'); }
		},
		error: function(xhr) { status.text(xhr && xhr.status == 409 ? 'That name is already in use.' : 'Could not clone.'); }
	});
});

$(document).on('click', '.edit_app_delete', function() {
	var b = $(this);
	var app = b.attr('app');
	var uuid = b.attr('uuid');
	// This editor edits one record, so its trash deletes that record and only it.
	// Deleting a whole app lives in Configure -> the app's card, where the name
	// has to be typed first.
	if (!confirm('Delete this record?')) { return; }
	if (!confirm('Delete it for good? This is copied to every machine.')) { return; }
	var ea = b.closest('.appointment_edit_area');
	var status = ea.find('.edit_app_status');
	status.text('Deleting...');
	$.ajax({
		url: '/manager/delete_app',
		type: 'POST',
		data: { app: app, uuid: uuid, timestamp: b.attr('timestamp'), type: b.attr('type'), server_time: Date.now() },
		success: function() {
			ea.html('').hide();
		},
		error: function() { status.text('Could not delete.'); }
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
				jawnosAlert('It didn\'t work! Try again!');
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

$(document).on('click', '.enabler', function() {
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

function jawnosRemoteHint(text) {
	var b = $('#remote_control_go');
	if (b.length) { b.attr('hint', text); }
	if (typeof jawnosUpdateNote === 'function') { jawnosUpdateNote(text); }
}

function jawnosRemoteManagerWindow(url, uuid, name, device, manager) {
	if (!url) { return; }
	url = jawnosRemoteUrl(url, manager);
	var device_uuid = device || '';
	if (!device_uuid) {
		try { device_uuid = localStorage.getItem('device_uuid') || ''; } catch (e) { device_uuid = ''; }
	}
	if (!window.JawnDesktop) {
		jawnosRemoteHint((typeof jawnosT === 'function') ? jawnosT('Open this in the JawnOS app') : 'Open this in the JawnOS app');
		return;
	}
	jawnosDesktopCall('open_manager', { url: url, manager: manager || url, device_uuid: device_uuid, name: name || '' }).catch(function (err) {
		// The desktop app owns this window. Never fall back to window.open:
		// WebKit hands that to the default browser, which produced a second
		// tab (often the local Gate) beside the JawnOS window.
		jawnosRemoteHint((typeof jawnosT === 'function') ? jawnosT('The JawnOS window could not be opened') : 'The JawnOS window could not be opened');
	});
}

function jawnosRemoteManagerOpen(uuid, manager) {
	if (!uuid && !manager) { return; }
	var data = {
		timestamp: Date.now(),
		// The desktop bridge is what opens a real JawnOS window; when it is
		// missing the page can only explain that the app is required.
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
			if (!r) { return; }
			if (r.need_approval) {
				jawnosGoPrompt(r, uuid, manager);
				return;
			}
			// In the app a ticket is what signs the peer window in. When the
			// mint failed (a peer restarting) opening the bare manager would
			// only show that machine's Gate; say so and let the person retry.
			if (r.ticket_failed) {
				jawnosRemoteHint((typeof jawnosT === 'function') ? jawnosT('That machine is not ready to sign you in. Try again in a moment.') : 'That machine is not ready to sign you in. Try again in a moment.');
				return;
			}
			if (r.manager) {
				var target = jawnosRemoteUrl(r.ticket_url || r.manager, r.manager || manager);
				jawnosRemoteManagerWindow(target, r.uuid || uuid, r.name, r.device_uuid, r.manager);
			}
		},
		fail: function (xhr) {
			// The app gate answers a session that has not signed the installed
			// app with the app-required page. The app can sign itself in and
			// retry; a browser has no key, so it still gets the plain window.
			if (xhr && xhr.responseText && xhr.responseText.indexOf('JawnOS app required') >= 0
				&& typeof jawnAppLogin === 'function') {
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
				jawnosRemoteManagerWindow(jawnosRemoteUrl(manager, manager), uuid);
			}
			else {
				jawnosRemoteHint((typeof jawnosT === 'function') ? jawnosT('That machine has no reachable address') : 'That machine has no reachable address');
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
		position: 'fixed', zIndex: 2147483000, left: '50%', top: '50%', transform: 'translate(-50%,-50%)',
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
	jawnosRemoteManagerOpen(b.attr('uuid'), b.attr('manager'));
});

// Go links filed in remote_machines.buttons before the button existed still
// open the machine's window rather than a tab.
$(document).on('click', '.remote_machine_buttons a[target="_blank"]', function (e) {
	if (e.ctrlKey || e.metaKey || e.shiftKey || e.which === 2) { return; }
	var href = $(this).attr('href') || '';
	if (href.indexOf('/manager') < 0) { return; }
	e.preventDefault();
	jawnosRemoteManagerOpen('', href);
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
