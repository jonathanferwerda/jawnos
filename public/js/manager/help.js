// The Help app. Opens a window that explains apps, features, functions and
// devices in plain language, and wires four things together:
//
//   - the start menu's Help icon, and appWindowOpener('help'), open it;
//   - F1 opens the topic for the window you are focused on (or for whatever
//     control you are hovering, when it declares a `help="topic"` attribute);
//   - the question-mark button in a window's title bar opens that window's app;
//   - a Guide: pick a model and it walks you through the topic step by step,
//     using the window you came from as context.
//
// The topic registry lives server-side (help.pl); the model call is the same
// whole-answer helper the evaluation uses.

// The topic currently shown, and the window the reader came from — both feed
// the guide's context.
var jawnos_help_topic_current = null;
var jawnos_help_source = null;

// Open the Help window, optionally on a topic. Uses the standard window path so
// it behaves like every other app (stacking, remembering, restoring).
function helpOpener(topic) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/help',
		type: 'GET',
		data: { topic: topic || '', timestamp: timestamp, user_agent: navigator.userAgent },
		success: function (response) {
			windowMaker(response);
			setTimeout(helpRefreshContext, 300);
		}
	});
}

// Describe the window the reader came from, so the guide knows what "this" is.
function helpSourceFrom(app) {
	var ctx = { app: app || null };
	if (app) {
		var w = $('.wind[app="' + app + '"]');
		if (w.length) {
			ctx.title = $.trim(w.find('.name_text').first().text()) || app;
			var view = w.find('.selected, .active').first();
			if (view.length) { ctx.view = $.trim(view.text()); }
			var appt = w.find('.appointment').first();
			if (appt.length) { ctx.appointment = appt.attr('app'); }
		}
	}
	return ctx;
}

// Paint the guide's context line. Prefers the explicit source (the window the
// reader came from); falls back to the focused window.
function helpRefreshContext() {
	var el = $('#help_context');
	if (!el.length) { return; }
	var src = jawnos_help_source;
	if (!src || !src.title) {
		var top = (typeof topWindow === 'function') ? topWindow() : null;
		if (top && top !== 'help') { src = helpSourceFrom(top); }
	}
	if (src && src.title) {
		var line = 'looking at ' + src.title + (src.view ? (' · ' + src.view) : '');
		el.text('— ' + line);
	} else {
		el.text('');
	}
}

// Swap the rail list and the topic pane in place. The search box and the guide
// panel are left alone, so neither a search nor a scroll is thrown away.
function helpBody(topic, search) {
	var win = $('.wind[app="help"]');
	if (!win.length) { return; }
	var rail = win.find('.help_rail_list');
	var body = win.find('.help_body');
	var rail_scroll = rail.length ? rail.scrollTop() : 0;
	var body_scroll = body.length ? body.scrollTop() : 0;
	$.get('/manager/help/body', { topic: topic || '', search: search || '' }, function (r) {
		var $r = $('<div>').html(typeof r === 'string' ? r : r.html);
		var new_rail = $r.find('.help_rail_list');
		var new_body = $r.find('.help_body');
		if (new_rail.length) { rail.html(new_rail.html()); }
		if (new_body.length) { body.html(new_body.html()); }
		// keep the reader where they were, unless the list itself changed
		rail.scrollTop(search ? 0 : rail_scroll);
		body.scrollTop(search ? 0 : body_scroll);
		jawnos_help_topic_current = topic || null;
		// a new topic may carry its own opening question for the guide
		var def = $r.find('#help_question').attr('data-default') || '';
		if (def) { $('#help_question').val(def); }
		helpRefreshContext();
	});
}

// What F1 answers: a hovered control's topic if the pointer named one, else the
// app of the window on top. Pressing F1 while Help itself is focused just opens
// the index rather than a topic about Help.
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

// ---- the guide ------------------------------------------------------------

function helpFormatAnswer(text) {
	var safe = $('<div>').text(text || '').html();
	safe = safe.replace(/\n{2,}/g, '</p><p>').replace(/\n/g, '<br>');
	return '<p style="margin:0 0 10px;">' + safe + '</p>';
}

function helpAsk() {
	var model = $('#help_model').val();
	var question = $.trim($('#help_question').val() || '');
	var answer = $('#help_answer');
	if (!model) {
		answer.html('<i>Choose a model in the row above first — the guide needs one to think with.</i>');
		return;
	}
	if (!question) { question = 'Walk me through this step by step.'; }
	var ctx = jawnos_help_source;
	if (!ctx || !ctx.title) {
		var top = (typeof topWindow === 'function') ? topWindow() : null;
		if (top && top !== 'help') { ctx = helpSourceFrom(top); }
	}
	answer.html('<i>Thinking…</i>');
	$.ajax({
		url: '/manager/help/ask',
		type: 'POST',
		data: {
			topic: jawnos_help_topic_current || '',
			question: question,
			context: JSON.stringify(ctx || {}),
			model: model
		},
		success: function (r) {
			if (r && r.error) { answer.html('<i>' + $('<div>').text(r.error).html() + '</i>'); return; }
			answer.html(helpFormatAnswer(r && r.answer));
		},
		error: function () { answer.html('<i>The guide could not be reached. Is a model running?</i>'); }
	});
}

// ---- wiring ---------------------------------------------------------------

$(document).on('click', '#help_toggle', function () {
	jawnos_help_source = null;
	helpOpener();
});

$(document).on('click', '.help_button', function (e) {
	e.stopPropagation();
	var app = $(this).attr('app');
	jawnos_help_source = helpSourceFrom(app);
	helpOpener(app);
});

$(document).on('click', '.help_topic_link', function () {
	helpBody($(this).attr('topic'));
});

$(document).on('click', '.help_open_app', function () {
	var app = $(this).attr('app');
	if (app && typeof appWindowOpener === 'function') { appWindowOpener(app, Date.now(), {}); }
});

$(document).on('click', '#help_ask', function () { helpAsk(); });

// Enter in the question box sends; Shift+Enter makes a newline.
$(document).on('keydown', '#help_question', function (e) {
	if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); helpAsk(); }
});

$(document).on('change', '#help_model', function () {
	var v = $(this).val();
	if (v) { settingSetter({ app: 'mail', setting: 'help_assistant', value: v }); }
});

var help_search_timer = null;
$(document).on('input', '#help_search', function () {
	var q = $(this).val();
	clearTimeout(help_search_timer);
	help_search_timer = setTimeout(function () { helpBody(null, q); }, 250);
});

// Remember what the pointer is over, so F1 can answer for it. universal.js does
// the label; here we only keep the topic id.
$(document).on('mouseenter', '[help]', function () {
	window.jawnos_help_topic = $(this).attr('help');
});
$(document).on('mouseleave', '[help]', function () {
	if (window.jawnos_help_topic === $(this).attr('help')) { window.jawnos_help_topic = null; }
});

$(document).on('keydown', function (e) {
	if (e.key === 'F1') { e.preventDefault(); helpOpenContext(); }
});
