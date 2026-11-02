// Words that are mostly the reply the machine just spoke are the speaker's,
// not the person's: a conversation's mic reopens while Piper may still be
// talking, so without this the guide transcribes itself. A genuine trailing
// run (three or more words that are not in the reply) is kept - that is the
// person speaking over the tail.
function jawnEchoCheck(text, mine) {
	var out = { echo: false, text: text };
	if (!mine || !text) { return out; }
	var clean = function (s) { return String(s).toLowerCase().replace(/[^a-z0-9' ]+/g, ' ').split(/\s+/).filter(Boolean); };
	var words = clean(text);
	if (words.length < 3) { return out; }
	var mine_set = {};
	clean(mine).forEach(function (w) { mine_set[w] = 1; });
	var hits = 0;
	words.forEach(function (w) { if (mine_set[w]) { hits++; } });
	if ((hits / words.length) < 0.75) { return out; }
	var trailing = 0;
	for (var i = words.length - 1; i >= 0; i--) { if (!mine_set[words[i]]) { trailing++; } else { break; } }
	if (trailing >= 3) { out.text = words.slice(words.length - trailing).join(' '); return out; }
	out.echo = true;
	return out;
}

function jawnClipSend(blob, opts) {
	opts = opts || {};
	// diagnosing a clip that arrives empty: the same switch the room reader uses
	try {
		if (localStorage.getItem('jawn_room_debug') == 'on') {
			console.log('[clip] from=' + (jawn_clip.last_from || 'media') + ' type=' + (blob ? blob.type : 'none')
				+ ' size=' + (blob ? blob.size : 0) + ' chunks=' + ((jawn_clip.chunks || []).length));
		}
	} catch (e) {}
	if (!blob || !blob.size) { if (opts.status) { opts.status('I did not catch any audio.'); } if (opts.onFail) { opts.onFail('empty'); } return; }
	if (opts.status) { opts.status('Transcribing…'); }
	$.ajax({
		url: '/manager/help/listen',
		type: 'POST',
		data: blob,
		processData: false,
		contentType: 'application/octet-stream',
		success: function (r) {
			if (!r || r.error || !r.text) { if (opts.status) { opts.status((r && r.error) || 'I could not make out any words.'); } if (opts.onFail) { opts.onFail('unreadable'); } return; }
			if (opts.selfWords) {
				var verdict = jawnEchoCheck(r.text, opts.selfWords);
				if (verdict.echo) { if (opts.onEcho) { opts.onEcho(); } return; }
				r = { text: verdict.text };
			}
			if (opts.onText) { opts.onText(r.text); }
		},
		error: function () { if (opts.status) { opts.status('I could not transcribe that.'); } if (opts.onFail) { opts.onFail('network'); } }
	});
}

function helpListenToggle(onText) {
	if (jawnClipListening()) { jawnClipStop(); return; }
	helpShowChat(true);
	jawnClipListen({
		talking: jawnos_help_talking,
		owner: '#help',
		selfWords: jawnos_help_talking ? helpLastWords() : '',
		onEcho: function () { if (jawnos_help_talking) { helpConversationListen(); } },
		onText: onText || function (text) { $('#help_question').val(text); },
		status: function (msg) { helpChatAdd('step', msg); },
		onFail: function (reason) { if (jawnos_help_talking && reason !== 'microphone' && reason !== 'no microphone') { helpConversationListen(); } },
		onstart: function () { $('#help_ask').text('Stop'); },
		onend: function () { $('#help_ask').text('Send'); }
	});
}

// ---- conversation mode ----------------------------------------------------
// The guide as a conversationalist: once the mic is open, it comes back after
// each answer and each utterance is the next turn of the same thread, until
// "bye jawn" (or the End button) closes it. No wake phrase gates it - pressing
// Converse (or an empty Send) simply starts listening.
var jawnos_help_talking = false;
var jawnos_help_converse_timer = null;

function helpConversationBye(q) {
	return /^(?:bye|goodbye|good ?night|that'?s all|that is all|we'?re done)[,!. ]+jawn\b/i.test(q || '');
}

// the on-device listener's entry point
function jawnConversationWake() { helpConversationOn(); helpConversationListen(); }
function jawnConversationEnd() { helpConversationEnd(); }

function helpConversationOn() {
	if (jawnos_help_talking) { return; }
	jawnos_help_talking = true;
	// a new conversation reads the room afresh
	if (typeof jawnRoomReset === 'function') { jawnRoomReset(); }
	$('#help_converse').text('End').css({ 'border-color': '#e23b3b', 'color': '#e23b3b' }).attr('hint', 'End the conversation');
	helpChatAdd('step', 'Conversation on — I will keep listening after each answer. Press End or say “bye jawn” to stop.');
}

function helpConversationEnd() {
	if (!jawnos_help_talking) { return; }
	jawnos_help_talking = false;
	if (jawnos_help_converse_timer) { clearTimeout(jawnos_help_converse_timer); jawnos_help_converse_timer = null; }
	if (jawnClipListening()) { jawnClipStop(true); }
	$('#help_converse').text('Converse').css({ 'border-color': 'var(--line)', 'color': '' })
		.attr('hint', 'Start a spoken conversation: the mic opens again after each answer, so you can just keep talking — press End when you are done, or say “bye jawn”');
	helpChatAdd('guide', 'Alright — I will be here.');
}

// the help guide's own last words, so a conversation's mic can tell the speaker
// from the person
function helpLastWords() {
	for (var i = jawnos_help_chat.length - 1; i >= 0; i--) {
		var m = jawnos_help_chat[i] || {};
		if ((m.role || '') === 'assistant' && m.content && !/^\s*\{/.test(m.content)) { return m.content; }
	}
	return '';
}

function helpConversationListen() {
	if (!jawnos_help_talking) { return; }
	if (jawnos_help_converse_timer) { clearTimeout(jawnos_help_converse_timer); }
	jawnos_help_converse_timer = setTimeout(function () {
		jawnos_help_converse_timer = null;
		if (!jawnos_help_talking) { return; }
		helpListenToggle(function (text) {
			if (!jawnos_help_talking) { return; }
			var q = $.trim(text || '');
			if (!q) { helpConversationListen(); return; }
			if (helpConversationBye(q)) { helpConversationEnd(); return; }
			helpShowChat(true);
			jawnos_help_chat.push({ role: 'user', content: q });
			helpChatAdd('user', q);
			if (jawnos_help_coding) { helpCodingRun(q); return; }
			helpAgentStep(0);
		});
	}, 350);
}

$(document).on('click', '#help_converse', function () {
	if (jawnos_help_talking) { helpConversationEnd(); }
	else { helpConversationOn(); helpConversationListen(); }
});

// ---- the coding agent ----------------------------------------------------
// When the Coding box is ticked the composer drives the self-healing agent
// behind /manager/coding/heal instead of the screen guide: one bounded run that
// edits the repo, checks it, and ships it, reported step by step.
var jawnos_help_coding = false;

function helpCodingRun(task) {
	helpChatAdd('step', 'Coding — reading and changing the repo…');
	$.ajax({
		url: '/manager/coding/heal',
		type: 'POST',
		dataType: 'json',
		data: { task: task, conversation: 'help' },
		success: function (r) {
			if (!r || r.error) { helpChatAdd('guide', (r && r.error) || 'The coding agent failed.'); return; }
			(r.steps || []).forEach(function (s) {
				var a = s.action || {};
				var obs = String(s.observation == null ? '' : s.observation).replace(/\s+\n/g, '\n').replace(/\n+/g, ' · ');
				if (obs.length > 240) { obs = obs.slice(0, 240) + '…'; }
				helpChatAdd('step', helpCodingLine(a) + (obs ? (' → ' + obs) : ''));
			});
			if (r.final) { helpChatAdd('guide', r.final); }
			else { helpChatAdd('guide', 'Done — now at version ' + (r.version || '?') + '.'); }
		},
		error: function () { helpChatAdd('guide', 'The coding agent could not be reached.'); }
	});
}

function helpCodingLine(a) {
	if (a.action === 'write') { return 'Wrote ' + (a.path || '?'); }
	if (a.action === 'read') { return 'Read ' + (a.path || '?'); }
	if (a.action === 'list') { return 'Listed ' + (a.path || '.'); }
	if (a.action === 'run') { return 'Ran ' + (a.command || ''); }
	if (a.action === 'bump') { return 'Bumped the version'; }
	if (a.action === 'commit') { return 'Committed'; }
	if (a.action === 'push') { return 'Pushed to GitHub'; }
	if (a.action === 'restart') { return 'Restarting'; }
	return (a.action || 'Step');
}

// A model's working, folded away above the answer it produced. It is model
// scratch, not conversation content, so it is never pushed into
// jawnos_help_chat - a later turn must not read its own reasoning back.
function helpChatThinking(text) {
	var log = helpChatLog();
	if (!log.length) { return; }
	var label = (typeof jawnosT === 'function') ? jawnosT('thinking') : 'thinking';
	var block = $('<div style="margin:4px 0 2px;"></div>');
	var body = $('<div class="help_chat_thought" style="display:none;white-space:pre-wrap;overflow:auto;max-height:200px;font-size:12px;opacity:.65;border-left:2px solid var(--border-color, #888);padding-left:8px;margin-top:4px;"></div>')
		.text(text == null ? '' : String(text));
	var toggle = $('<span class="help_chat_thought_toggle" style="font-size:12px;opacity:.6;cursor:pointer;user-select:none;"></span>')
		.text(label);
	block.append(toggle).append(body);
	log.append(block);
	log.scrollTop(log[0].scrollHeight);
}

$(document).on('click', '.help_chat_thought_toggle', function () {
	$(this).siblings('.help_chat_thought').first().toggle();
});

function helpAgentStep(n) {
	if (n >= 6) {
		helpChatAdd('step', 'Stopping after several steps.');
		helpChatAdd('guide', 'I did not finish that in a few steps — here is where I got to. Try naming the app, or ask me a question about it.');
		return;
	}
	$.ajax({
		url: '/manager/help/act',
		type: 'POST',
		dataType: 'json',
		data: {
			transcript: JSON.stringify(jawnos_help_chat),
			context: JSON.stringify(helpContextNow()),
			topic: jawnos_help_topic_current || '',
			model: $('#help_model').val()
		},
		success: function (r) {
			if (r && r.error) { helpChatAdd('step', r.error); return; }
			if (r && r.thinking) { helpChatThinking(r.thinking); }
			var a = (r && r.action) || {};
			if (a.action === 'say' || a.action === 'ask' || a.action === 'done') {
				var text = a.text || '';
				jawnos_help_chat.push({ role: 'assistant', content: text });
				helpGuideAnswer(text);
				return;
			}
			helpChatAdd('step', helpActionLabel(a));
			jawnos_help_chat.push({ role: 'assistant', content: JSON.stringify(a) });
			if (typeof jawnos_page_agent_panel !== 'undefined') { jawnos_page_agent_panel = null; }
			helpDoAction(a, function (obs, friendly) {
				jawnos_help_chat.push({ role: 'tool', content: obs });
				if (friendly) {
					jawnos_help_chat.push({ role: 'assistant', content: friendly });
					helpGuideAnswer(friendly);
					return;
				}
				helpAgentStep(n + 1);
			});
		},
		error: function () { helpChatAdd('step', 'The guide could not be reached.'); }
	});
}

// ---- F1 and context --------------------------------------------------------

function helpOpenContext() {
	var topic = window.jawnos_help_topic;
	var source_app = null;
	if (!topic) {
		var top = (typeof topWindow === 'function') ? topWindow() : null;
		if (top && top !== 'help') { topic = top; source_app = top; }
	}
	jawnos_help_source = source_app ? helpSourceFrom(source_app) : null;
	helpOpener(topic);
}

// ---- wiring ---------------------------------------------------------------

$(document).on('click', '#help_toggle', function () {
	jawnos_help_source = null;
	helpOpener();
});

$(document).on('click', '#help_tour', function () {
	helpTourStart();
});

$(document).on('click', '.help_button', function (e) {
	e.stopPropagation();
	var app = $(this).attr('app');
	jawnos_help_source = helpSourceFrom(app);
	assistantAppOpen(app);
});

$(document).on('click', '.help_topic_link', function () {
	helpShowChat(false);
	helpBody($(this).attr('topic'));
});

$(document).on('click', '.help_open_app', function () {
	var app = $(this).attr('app');
	if (app && typeof appWindowOpener === 'function') { appWindowOpener(app, Date.now(), {}); }
});

// A live doc's runnable example: open Configure and press the tab the example
// names. Opening the window is appWindowOpener's job and the tab is the same
// .configure_toggle button a person would press, so this adds no second way to
// open an app or a panel.
$(document).on('click', '.help_example_configure', function () {
	var tab = $(this).attr('configure');
	if (!tab || !/^[a-z][a-z0-9_]*$/.test(tab)) { return; }
	var press = function () {
		var target = $('#' + tab + '.configure_toggle');
		if (!target.length) { return false; }
		target.trigger('click');
		return true;
	};
	if (typeof appWindowOpener !== 'function') { press(); return; }
	// Opening (or re-raising) the window and then pressing the real tab keeps
	// this on the same path a person uses; the tab is not there until the
	// window's own load lands, so wait for it.
	appWindowOpener('configure', Date.now(), {});
	var tries = 0;
	var wait = setInterval(function () {
		tries++;
		if (press() || tries >= 60) { clearInterval(wait); }
	}, 125);
});

$(document).on('click', '#help_ask', function () { helpAsk(); });
$(document).on('click', '#help_topics_back', function () { helpTopicsBack(); });

$(document).on('keydown', '#help_question', function (e) {
	if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); helpAsk(); }
});

$(document).on('change', '#help_model', function () {
	var v = $(this).val();
	if (v) { settingSetter({ app: 'mail', setting: 'help_assistant', value: v }); $('.assistant_model').text(v); }
});

$(document).on('change', '#help_coding', function () {
	jawnos_help_coding = $(this).is(':checked');
	$('#help_question').attr('placeholder', jawnos_help_coding
		? 'Tell the Coding agent what to change or fix…'
		: 'Ask the guide — or tell it what you want to do…');
});

var help_search_timer = null;
$(document).on('input', '#help_search', function () {
	var q = $(this).val();
	clearTimeout(help_search_timer);
	help_search_timer = setTimeout(function () { helpBody(null, q); }, 250);
});

$(document).on('mouseenter', '[help]', function () {
	window.jawnos_help_topic = $(this).attr('help');
});
$(document).on('mouseleave', '[help]', function () {
	if (window.jawnos_help_topic === $(this).attr('help')) { window.jawnos_help_topic = null; }
});

$(document).on('keydown', function (e) {
	if (e.key === 'F1') { e.preventDefault(); helpOpenContext(); }
});

// The manager has loaded and put its windows back; ask once whether this install
// has seen the welcome tour. The delay lets a restored conversation settle so
// the tour does not race the startup windows.
$(document).ready(function () {
	setTimeout(helpFirstRunCheck, 1200);
});
