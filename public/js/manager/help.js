// The Help app. Opens a window that explains apps, features, functions and
// devices in plain language, and ties the desktop's hover hints into it:
//
//   - the start menu's Help icon, and appWindowOpener('help'), open it;
//   - F1 opens the topic for the window you are focused on (or for whatever
//     control you are hovering, when it declares a `help="topic"` attribute);
//   - the question-mark button in a window's title bar opens that window's app;
//   - clicking a topic link or searching swaps the contents in place.
//
// The topic registry lives server-side (help.pl); this file is only the client.

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
		}
	});
}

// Swap the Help window's contents without rebuilding (or re-raising) the window.
// `topic` shows a topic; `search` shows results; neither shows the index.
function helpBody(topic, search) {
	var win = $('.wind[app="help"] .window_contents');
	if (!win.length) { return; }
	$.get('/manager/help/body', { topic: topic || '', search: search || '' }, function (r) {
		win.html(typeof r === 'string' ? r : r.html);
		var box = win.find('#help_search');
		if (box.length) {
			box.val(search || '');
			box.focus();
			try { box[0].setSelectionRange(box.val().length, box.val().length); } catch (e) {}
		}
	});
}

// What F1 answers: a hovered control's topic if the pointer named one, else the
// app of the window on top. Pressing F1 while Help itself is focused just opens
// the index rather than a topic about Help.
function helpOpenContext() {
	var topic = window.jawnos_help_topic;
	if (!topic) {
		var top = (typeof topWindow === 'function') ? topWindow() : null;
		if (top && top !== 'help') { topic = top; }
	}
	helpOpener(topic);
}

$(document).on('click', '#help_toggle', function () {
	helpOpener();
});

$(document).on('click', '.help_button', function (e) {
	e.stopPropagation();
	helpOpener($(this).attr('app'));
});

$(document).on('click', '.help_topic_link', function () {
	helpBody($(this).attr('topic'));
});

$(document).on('click', '.help_open_app', function () {
	var app = $(this).attr('app');
	if (app && typeof appWindowOpener === 'function') { appWindowOpener(app, Date.now(), {}); }
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
