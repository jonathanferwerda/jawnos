/* [[js-split]]
   manager.js is part 1. The rest live in manager/ in name order:
     01_assistant_conversation.js - the associate as a conversationalist: converse, ask, end, spawn, initializer
     02_web_nfc.js                - Web NFC, the app camera, launch extras and phone facts
     03_box_office.js             - the clipboard, card picker and box-office ticket list
     04_search.js                 - ticket renewal and the search index/builders
     05_start_menu.js             - search results and toggle, the start menu and htop viewer
     06_appointment_distance.js   - the main image selector, appointment distance and detail controls
     07_timeshift.js              - the timeshift viewer, now resetter, notes/time inputs, delorean and calculator
     08_handbook.js               - web delete, graphicalize and the Handbook Today page
     09_app_back.js               - openApps, project accounts, manager reset and the app-back stack
     10_appointment_edit.js       - the appointment edit form and details/measures grabbers
     11_lock_session.js          - lock session, leave, the remote manager windows and the cache
     12_cards.js                 - the Cards app: deck chooser, solitaire, mahjong, tarot picker
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
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
// The appointment window's reverse/forward walkman: by default it moves only
// the app whose record it sits under - the app's details are read at that
// moment while the house's time machine stays where it is. The walkman's
// Configure tick (Appt walkman controls global time) brings back the older
// behaviour of carrying the whole view there.
function jawnosApptWalkmanGlobal() {
	return (typeof jawnos_bar_settings != 'undefined') && jawnos_bar_settings['appt_walkman_global'] === 'checked';
}
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
				j.attr('timestamp',response.new_timestamp);
				j.closest('.walkman_controls').find('.time_jump').attr('timestamp',response.new_timestamp);
				if (jawnosApptWalkmanGlobal()) {
					$('#time_machine').val(response.date);
					localStorage.setItem('time_machine',response.date);
					appointmentDetailsGrabber(j);
				}
				else {
					// the app alone reads its details at that moment; no clock moves
					appointmentDetailsGrabber(j, undefined, response.date);
				}
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
		var approve = '<span class="assistant_staged_approve hover" hint="Approve and save this staged appointment" title="Save it" style="cursor:var(--jawnos-cursor-pointer, pointer);font-size:15px;opacity:.75;">👍</span>';
		var del = '<img class="tiny_thumb assistant_staged_delete hover" hint="Delete this staged appointment" title="Delete it" style="cursor:var(--jawnos-cursor-pointer, pointer);padding:2px;" src="' + trash + '">';
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
	var spot = { left: Math.round(left), top: Math.round(top) };
	// The size is kept with the place: a panel resized by hand opens at that
	// size next time, on this device. Only an inline size counts - a panel that
	// has merely been dragged keeps its own default, which lets a content-sized
	// list grow and the keyboard keep each page's own height.
	var inline = panel[0].style;
	var width = parseFloat(panel.css('width')), height = parseFloat(panel.css('height'));
	if (inline.width && isFinite(width) && width > 0) { spot.width = Math.round(width); }
	if (inline.height && isFinite(height) && height > 0) { spot.height = Math.round(height); }
	jawnosPanelSpotSet(key, JSON.stringify(spot));
}
function jawnosPanelPosRestore(key, panel) {
	if (!key || !panel || !panel.length) { return false; }
	var raw = (typeof jawnosPanelSpotGet === 'function') ? jawnosPanelSpotGet(key) : null;
	if (!raw) { return false; }
	var s = null;
	try { s = JSON.parse(raw); } catch (e) { return false; }
	if (!s || typeof s.left !== 'number' || typeof s.top !== 'number') { return false; }
	var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
	// a panel is held under the same ceiling its drag obeys, so a place saved on a
	// larger screen cannot put its header behind a top taskbar or the clothesline
	var limit = (typeof panelTopLimit == 'function') ? panelTopLimit() : 0;
	// apply a remembered size before measuring, so the place is clamped against
	// the box the panel will really wear
	var saved_w = 0, saved_h = 0;
	if (typeof s.width === 'number' && s.width > 0) {
		saved_w = Math.min(s.width, Math.max(160, $(window).width() - 8));
		panel.css('width', saved_w + 'px');
	}
	if (typeof s.height === 'number' && s.height > 0) {
		saved_h = Math.min(s.height, Math.max(120, $(window).height() - limit - bar - 8));
		panel.css('height', saved_h + 'px');
	}
	// keep it on screen if the window has since shrunk; a hidden panel has no box
	// to measure, and a zero width simply leaves the stored spot alone
	var w = saved_w || panel.outerWidth() || 0, h = saved_h || panel.outerHeight() || 0;
	var left = Math.max(0, Math.min(s.left, $(window).width() - w));
	var top = Math.max(limit, Math.min(s.top, $(window).height() - h - bar));
	panel.css({ left: left + 'px', top: top + 'px', right: 'auto', bottom: 'auto' });
	return true;
}

// A right/bottom anchored panel gets a left/top before it is resized, so the
// widget can grow it without the two anchors stretching the box.
function jawnosPanelAnchor(panel) {
	if (!panel || !panel.length) { return; }
	if (panel.css('right') == 'auto' && panel.css('bottom') == 'auto') { return; }
	var rect = panel[0].getBoundingClientRect();
	panel.css({ left: rect.left + 'px', top: rect.top + 'px', right: 'auto', bottom: 'auto' });
}

// A chat panel is sized by its edge or corner. The stop clamps it on screen
// (a corner can reach past the desk) and keeps the size beside its place.
function jawnosPanelResizable(panel, keyOf) {
	if (!panel || !panel.length || !$.fn.resizable || panel.hasClass('ui-resizable')) { return; }
	panel.resizable({
		handles: 'e, s, se',
		minWidth: 240,
		minHeight: 180,
		start: function () { jawnosPanelAnchor($(this)); },
		stop: function () {
			var p = $(this);
			var w = p.outerWidth(), h = p.outerHeight();
			var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
			var limit = (typeof panelTopLimit == 'function') ? panelTopLimit() : 0;
			var left = parseFloat(p.css('left')) || 0;
			var top = parseFloat(p.css('top')) || 0;
			left = Math.max(0, Math.min(left, Math.max(0, $(window).width() - w)));
			var highest = Math.max(limit, $(window).height() - h - bar);
			top = Math.max(limit, Math.min(top, highest));
			p.css({ left: left + 'px', top: top + 'px', right: 'auto', bottom: 'auto' });
			jawnosPanelPosSave((typeof keyOf == 'function') ? keyOf(p) : keyOf, p);
		}
	});
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
		var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
		// The header is the panel's only handle and wears its close, so the panel
		// starts under the ceiling a window and a keyboard panel obey (the taskbar
		// when it rides the top edge, and the clothesline) and is capped to the
		// room left below it. A short screen shortens the chat; it never hides the
		// way to move or close the panel.
		var limit = (typeof panelTopLimit == 'function') ? panelTopLimit() : 0;
		panel.css('max-height', Math.max(180, $(window).height() - limit - bar - 16) + 'px');
		if (!jawnosPanelPosRestore('guide:' + (panel.attr('conversation') || 'assistant'), panel)) {
			var w = panel.outerWidth(), h = panel.outerHeight();
			var left = Math.max(6, Math.min($(window).width() - w - 16, $(window).width() - w - 16));
			var top = Math.max(limit, Math.min($(window).height() - h - 70, Math.max(limit, $(window).height() - h - bar - 6)));
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

