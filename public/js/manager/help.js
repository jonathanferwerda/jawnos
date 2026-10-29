// The Help app. A window that explains JawnOS in plain language, and a Guide
// that can operate the screen for the person:
//
//   - the start menu's Help icon, and appWindowOpener('help'), open it;
//   - F1 opens the topic for the window you are focused on (or for whatever
//     control you are hovering, when it declares a `help="topic"` attribute);
	// the question-mark button in a window's title bar opens the Guide's associate
	// with that window's context (which app, which view), so it can answer about
	// what is on screen and drive the window for the person.
//   - the Guide: ask it a question and it becomes a chat; ask it to DO
//     something and it drives the screen - opening apps, searching, showing
//     photos - one whitelisted action at a time, reporting each step.
//
// The topic registry lives server-side (help.pl); the model turn is a plain
// whole-answer call (subs::evaluation_model_call); the actions are executed
// here, client-side, from a fixed vocabulary. Nothing the model says can reach
// the server as a command - it can only pick a verb we already allow.

var jawnos_help_topic_current = null;
var jawnos_help_source = null;

// Open the Help window, optionally on a topic.
function helpOpener(topic) {
	var timestamp = Date.now();
	jawnos_help_topic_current = topic || null;
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

function helpContextNow() {
	var src = jawnos_help_source;
	if (!src || !src.title) {
		var top = (typeof topWindow === 'function') ? topWindow() : null;
		if (top && top !== 'help') { src = helpSourceFrom(top); }
	}
	return src || {};
}

function helpRefreshContext() {
	var el = $('#help_context');
	if (!el.length) { return; }
	var src = helpContextNow();
	if (src && src.title) {
		el.text('— looking at ' + src.title + (src.view ? (' · ' + src.view) : ''));
	} else {
		el.text('');
	}
}

// ---- the browse view ------------------------------------------------------

// Swap the rail list and the topic pane in place, keeping the search box, the
// composer and the scroll position.
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
		rail.scrollTop(search ? 0 : rail_scroll);
		body.scrollTop(search ? 0 : body_scroll);
		jawnos_help_topic_current = topic || null;
		var def = $r.find('#help_question').attr('data-default') || '';
		if (def) { $('#help_question').attr('placeholder', 'Ask the guide — or tell it what you want to do…').val(def); }
		helpRefreshContext();
	});
}

// ---- the chat view --------------------------------------------------------

var jawnos_help_chat = [];
// the appointment the guide last staged (create), so a later promote can save it
var jawnos_help_last_staged = null;

function helpChatLog() { return $('.wind[app="help"] .help_chat_log'); }

function helpShowChat(on) {
	var win = $('.wind[app="help"]');
	win.find('.help_shell').toggle(!on);
	win.find('.help_chat_log').toggle(!!on);
	win.find('#help_topics_back').toggle(!!on);
	win.find('#help_ask').text(on ? 'Send' : 'Guide me');
}

// One chat bubble. role: 'user' (right, green), 'guide' (left, blue) or 'step'
// (a small, centred line reporting an action the guide took).
function helpChatAdd(role, text) {
	var log = helpChatLog();
	if (!log.length) { return; }
	var safe = $('<div>').text(text == null ? '' : String(text)).html().replace(/\n/g, '<br>');
	if (role === 'step') {
		log.append($('<div style="text-align:center;margin:6px 0;"><span style="font-size:12px;opacity:.6;font-style:italic;">' + safe + '</span></div>'));
	}
	else {
		var mine = (role === 'user');
		var bubble = '<span style="display:inline-block;max-width:82%;overflow-wrap:break-word;border-radius:10px;padding:7px 11px;'
			+ (mine ? 'background:var(--chat-bubble-me);' : 'background:var(--chat-bubble-them);') + '">' + safe + '</span>';
		log.append($('<div style="display:flex;margin:5px 0;' + (mine ? 'justify-content:flex-end;' : 'justify-content:flex-start;') + '">' + bubble + '</div>'));
	}
	log.scrollTop(log[0].scrollHeight);
}

function helpChatEnter() { helpShowChat(true); }

function helpTopicsBack() {
	helpShowChat(false);
	helpBody(jawnos_help_topic_current);
}

// ---- the welcome tour ------------------------------------------------------
// The first load of a new install opens Help and walks through the desktop.
// Take the tour replays the same sequence at any time. The walkthrough is
// scripted, not a model turn: each step is a Guide bubble and, where it helps,
// a button that drives the real control through helpDoAction. The install flag
// is server-side (see help::welcome_mark), so the tour is offered once per
// install rather than once per browser.
var jawnos_help_tour_index = 0;

function jawnosHelpTourText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

var jawnos_help_tour_steps = [
	{
		text: 'Welcome to JawnOS. I am the Guide. Everything here opens in a window: drag it by its title bar, pull an edge to resize it, and use the title bar buttons to minimise, maximise or close it. I will walk you through the main parts in a few steps; you can stop whenever you like.'
	},
	{
		text: 'The start menu is the round button at the corner of the desk. It opens on your recent apps, with a category rail and a search box. Its other pages show what is running, upcoming and expiring, and the water-drop tab is System: this machine\'s battery, CPU and memory, every other machine in the house, and the parking lot of saved sessions. A new install starts there.',
		verb: 'Show the System page',
		run: function (done) {
			localStorage.setItem('start_menu_menu', 'view');
			if (typeof startMenuToggle === 'function') {
				$('#start_menu').attr('toggled', 'closed');
				startMenuToggle({ source: 'tour' });
			}
			done('Opened the start menu on the System page.');
		}
	},
	{
		text: 'The dock is the bar along an edge of the desk, and its icons are its pseudonyms: each can be given a name, icon, colour, place and speech. Pin the apps you reach for most so they stay one press away.'
	},
	{
		text: 'Configure is the wrench on the start menu. Under Misc → Appearance holds the theme gallery (paint, icons, material, font and corner), the colour schemes, the font, the corner and the lock screensaver. Under App, each app has a card for its colour, budgets, goals and notifications. Under Dev are the machines of the house: Scan finds them, and each row carries its privilege, lease, Migrate and Go. The Pseud tab is where the dock pseudonyms are edited.',
		verb: 'Open Configure',
		action: { action: 'open_app', app: 'configure' }
	},
	{
		text: 'I am in the box at the foot of this window. Ask me a question about a topic, or tell me to do something: I can search your records, play media, translate a page, and open or drive the apps. With the Confirmation Requirement on I stage each change first, so nothing is written until you say yes. Press Converse to keep the microphone open, or the question mark in any window\'s title bar to ask about that window.'
	},
	{
		text: 'That is the tour. Open Help again from the start menu, or press F1 while another window is in front. Press Take the tour whenever you want to hear this again.'
	}
];

function helpTourReset() {
	jawnos_help_tour_index = 0;
	var log = helpChatLog();
	if (log.length) { log.empty(); }
	// the tour is scripted; drop any model thread so the two do not mix
	jawnos_help_chat = [];
}

function helpTourShowStep() {
	var log = helpChatLog();
	if (!log.length) { return; }
	log.find('.help_tour_controls').remove();
	var step = jawnos_help_tour_steps[jawnos_help_tour_index];
	if (!step) { return; }
	helpChatAdd('guide', jawnosHelpTourText(step.text));
	var controls = $('<div class="help_tour_controls" style="display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;margin:8px 0 6px;"></div>');
	log.append(controls);
	if (step.verb) {
		var act = $('<button class="button hover" style="padding:5px 12px;border-radius:8px;border:2px solid var(--line);cursor:pointer;font-weight:bold;"></button>')
			.text(jawnosHelpTourText(step.verb));
		act.on('click', function () {
			var done = function (obs) { helpChatAdd('step', jawnosHelpTourText(obs || 'Done.')); };
			if (step.action && typeof helpDoAction === 'function') { helpDoAction(step.action, done); }
			else if (typeof step.run === 'function') { step.run(done); }
		});
		controls.append(act);
	}
	var last = (jawnos_help_tour_index >= jawnos_help_tour_steps.length - 1);
	var next = $('<button class="button hover" style="padding:5px 12px;border-radius:8px;border:2px solid var(--line);cursor:pointer;font-weight:bold;"></button>')
		.text(last ? jawnosHelpTourText('Finish') : jawnosHelpTourText('Next'));
	next.on('click', function () {
		if (last) {
			log.find('.help_tour_controls').remove();
			helpChatAdd('step', jawnosHelpTourText('The tour is finished. Press Take the tour any time to see it again.'));
			return;
		}
		jawnos_help_tour_index++;
		helpTourShowStep();
	});
	controls.append(next);
	log.scrollTop(log[0].scrollHeight);
}

function helpTourStart() {
	// The button lives in the window, and the first-run check waits for the
	// window it already asked for; this only ever runs on a window that is up.
	if (!$('.wind[app="help"]').length) { return; }
	// The tour is about to be shown, so this install has now met it. Marking
	// before the first bubble would spend the first run on a window that never
	// arrived; marking here means a failed open leaves the tour to try again.
	helpTourMarkSeen();
	jawnos_help_topic_current = 'welcome';
	helpShowChat(true);
	helpTourReset();
	helpTourShowStep();
}

function helpTourMarkSeen() {
	if (window.__jawnosWelcomeMarked) { return; }
	window.__jawnosWelcomeMarked = true;
	$.post('/manager/help/welcome', { seen: 1 });
}

// One question to the server on the manager's first load: has this install met
// the tour? The absence of the row is the first run, and helpTourStart marks it
// once the window is actually on screen.
function helpFirstRunCheck() {
	if (window.__jawnosWelcomeChecked) { return; }
	window.__jawnosWelcomeChecked = true;
	$.get('/manager/help/welcome', function (r) {
		if (!r || !r.first_run) { return; }
		// keep this browser's start menu on the System page the first run chose
		if (!localStorage.getItem('start_menu_menu')) { localStorage.setItem('start_menu_menu', 'view'); }
		if ($('.wind[app="help"]').length) { helpTourStart(); return; }
		helpOpener('welcome');
		// A cold worker can take a moment to render the window. Wait for the one
		// that was asked for rather than opening a second; a window that never
		// arrives leaves the flag unspent, so the next load offers the tour again.
		var tries = 0;
		var wait = function () {
			if ($('.wind[app="help"]').length) { helpTourStart(); return; }
			if (tries++ < 20) { setTimeout(wait, 250); }
		};
		setTimeout(wait, 400);
	});
}

// A guide answer, with a small good/or-not pair under it: the person's verdict
// on the reply is the one bit of feedback we keep. It names the question it is
// answering so the record reads on its own.
function helpGuideAnswer(text) {
	helpChatAdd('guide', text);
	var log = helpChatLog();
	if (!log.length) { return; }
	var q = '';
	for (var i = jawnos_help_chat.length - 1; i >= 0; i--) {
		if (jawnos_help_chat[i].role === 'user') { q = jawnos_help_chat[i].content; break; }
	}
	var bar = $('<div style="display:flex;gap:8px;justify-content:flex-start;margin:-2px 0 8px 4px;">'
		+ '<span class="hover" style="cursor:pointer;opacity:.55;font-size:13px;" hint="This answer was good">👍</span>'
		+ '<span class="hover" style="cursor:pointer;opacity:.55;font-size:13px;" hint="This answer was not good">👎</span></div>');
	bar.find('span').first().attr('verdict', 'good');
	bar.find('span').last().attr('verdict', 'bad');
	bar.attr('data-q', q).attr('data-a', text);
	log.append(bar);
	log.scrollTop(log[0].scrollHeight);
	// in a conversation the guide listens again the moment it has answered
	if (jawnos_help_talking) { helpConversationListen(); }
}

$(document).on('click', '.help_chat_log span[verdict]', function () {
	var v = ($(this).attr('verdict') === 'good') ? 1 : 0;
	var bar = $(this).parent();
	$.post('/manager/help/feedback', {
		good: v, question: bar.attr('data-q') || '', answer: bar.attr('data-a') || '', topic: jawnos_help_topic_current || ''
	});
	bar.html('<span style="font-size:12px;opacity:.6;">Thanks — noted.</span>');
});

// ---- the guide that acts --------------------------------------------------

function helpActionLabel(a) {
	if (a.action === 'find') { return 'Searching for “' + (a.query || '') + '”…'; }
	if (a.action === 'lookup') { return 'Looking up “' + (a.query || '') + '” in your records…'; }
	if (a.action === 'open_app') { return 'Opening ' + (a.app || 'the app') + '…'; }
	if (a.action === 'play_music') { return 'Looking for “' + (a.query || '') + '” to play…'; }
	if (a.action === 'show_place') { return 'Finding ' + (a.place || 'the place') + ' on the map…'; }
	if (a.action === 'where_when') { return 'Looking up where you were…'; }
	if (a.action === 'measure') { return 'Measuring…'; }
	if (a.action === 'remote') { return 'Telling ' + (a.machine || 'the machine') + '…'; }
	if (a.action === 'update') { return 'Changing “' + (a.app || a.title || 'the appointment') + '”…'; }
	if (a.action === 'schedule') { return 'Working out the schedule…'; }
	if (a.action === 'page') {
		var op = String(a.do || a.operation || 'read').toLowerCase();
		if (op === 'fill') { return 'Filling in the page…'; }
		if (op === 'press' || op === 'click') { return 'Pressing “' + (a.target || a.field || 'the button') + '”…'; }
		return 'Reading the page…';
	}
	if (a.action === 'undo') { return 'Putting the last change back…'; }
	if (a.action === 'stop') { return 'Stopping ' + (a.app || 'the appointment') + '…'; }
	if (a.action === 'delete') { return 'Finding the ' + (a.app || 'appointment') + ' to delete…'; }
	var bits = [];
	if (a.app) { bits.push(a.app); }
	if (a.search) { bits.push('“' + a.search + '”'); }
	return 'Opening Gallery' + (bits.length ? ' — ' + bits.join(' ') : '') + '…';
}

// Execute one whitelisted action. Only ever calls known client functions; a
// model cannot reach past this switch. Reports back through cb(observation).
// Turn the person's words for a time ("in 3 hours", a date string, a raw ms)
// into a timestamp the stage route can store.
function helpResolveWhen(when) {
	if (when == null || when === '') { return Date.now(); }
	var s = String(when).trim().toLowerCase();
	if (/^\d{10,}$/.test(s)) { return parseInt(s, 10); }
	var m = /^in\s+(\d+)\s*(minute|min|hour|hr|day|week)s?$/.exec(s);
	if (m) {
		var n = parseInt(m[1], 10), u = m[2];
		var mult = (u.indexOf('min') === 0) ? 60000 : ((u.indexOf('hour') === 0 || u === 'hr') ? 3600000 : (u.indexOf('day') === 0 ? 86400000 : 604800000));
		return Date.now() + n * mult;
	}
	if (s === 'now') { return Date.now(); }
	var d = Date.parse(when);
	return isNaN(d) ? Date.now() : d;
}

function helpDoAction(a, cb) {
	a = a || {};
	if (a.action === 'open_app') {
		var open = function () {
			if (a.app && typeof appWindowOpener === 'function') { appWindowOpener(a.app, Date.now(), {}); }
			cb('Opened the ' + (a.app || '') + ' window.', 'Done — I opened ' + (a.app || 'the app') + '.');
		};
		if (!a.app) { open(); return; }
		// a thing the person hid is not opened here unless its padlock is open at home
		$.get('/manager/help/permitted', { app: a.app }, function (r) {
			if (r && r.permitted === 0) { cb('That app is hidden here, so I left it shut.', 'That one is hidden here — I left it shut.'); return; }
			open();
		}).fail(open);
		return;
	}
	if (a.action === 'open_gallery') {
		var show = function (apps, search_term) {
			var waits = [];
			if (apps && apps.length) {
				// scoping to apps shows their albums; the app name is the reliable key,
				// because a free-text search is literal and would miss e.g. "george
				// michael" against an app actually called george_michael
				waits.push(settingSetter({ app: 'gallery', setting: 'apps', value: JSON.stringify(apps) }));
				waits.push(settingSetter({ app: 'gallery', setting: 'search', value: '' }));
			}
			else if (search_term) {
				waits.push(settingSetter({ app: 'gallery', setting: 'search', value: search_term }));
			}
			$.when.apply($, waits).always(function () {
				if (typeof appWindowOpener === 'function') { appWindowOpener('gallery', Date.now(), {}); }
				var what = (apps && apps.length) ? ('the “' + apps.join('” and “') + '” photos') : (search_term ? ('what I found for “' + search_term + '”') : 'the Gallery');
				cb('Opened Gallery to ' + what + '. The person can see them now.', 'Done — here are ' + what + '.');
			});
		};
		// resolve plain names (one or several) to real app names first, so the
		// person's own words find the apps that exist
		var resolve = function (names, done) {
			names = (names || []).map(function (n) {
				// the model sometimes sends {name:...} objects where the schema says
				// plain strings; take the name out, or “friends” becomes the literal
				// “[object Object]” and the gallery opens on nothing
				return (n && typeof n === 'object') ? (n.name || n.app || '') : n;
			}).filter(function (n) { return n && n.length; });
			if (!names.length) { done([]); return; }
			var found = [], pending = names.length;
			names.forEach(function (n) {
				$.get('/manager/help/find', { q: n }, function (r) {
					if (r.apps && r.apps.length) { found.push(r.apps[0].app); }
					if (--pending === 0) { done(found); }
				}).fail(function () { if (--pending === 0) { done(found); } });
			});
		};
		if (a.apps && a.apps.length) { show(a.apps, null); }
		else if (a.app) {
			// an explicit app still has to be permitted here (not hidden, or at home unlocked)
			$.get('/manager/help/permitted', { app: a.app }, function (r) {
				if (r && r.permitted === 0) { cb('That is hidden here, so I left it shut.', 'That one is hidden here — I left it shut.'); return; }
				show([a.app], null);
			}).fail(function () { show([a.app], null); });
		}
		else if (a.names && a.names.length) { resolve(a.names, function (found) { found.length ? show(found, null) : show(null, a.names.join(' ')); }); }
		else if (a.search) { resolve([a.search], function (found) { found.length ? show(found, null) : show(null, a.search); }); }
		else { show(null, null); }
		return;
	}
	if (a.action === 'find') {
		$.get('/manager/help/find', { q: a.query || '' }, function (r) {
			var apps = (r.apps || []).map(function (x) { return x.app + ' (' + x.count + ')'; }).join(', ');
			var files = (r.files || []).slice(0, 8).join(', ');
			cb('Found ' + (r.count || 0) + ' record(s)' + (apps ? (' in apps: ' + apps) : '') + (files ? ('; files: ' + files) : '') + '.');
		}).fail(function () { cb('The search failed.'); });
		return;
	}
	if (a.action === 'lookup') {
		$.get('/manager/help/lookup', { q: a.query || '' }, function (r) {
			if (!r || r.ok === 0) { cb((r && r.error) || 'I could not look that up.'); return; }
			var rows = (r.rows || []).slice(0, 8);
			if (!rows.length) { cb('I found nothing in your records for “' + (a.query || '') + '”.'); return; }
			var bits = rows.map(function (x) { return (x.source || 'record') + (x.app ? (' “' + x.app + '”') : '') + ': ' + (x.text || ''); });
			cb('Records: ' + bits.join(' | ') + '.');
		}).fail(function () { cb('I could not look that up.'); });
		return;
	}
	if (a.action === 'create') {
		// the server reads the time the same way the clock does - dates, relative
		// phrases and the guide's own fallback - so the raw words go across, not a
		// client-side guess
		$.post('/manager/help/stage', { app: a.app || '', app_uuid: a.app_uuid || '', title: a.title || '', notes: a.notes || '', timestamp: a.when || '', type: a.type || '', duration: a.duration || '' }, function (r) {
			if (r && r.ask) { cb(r.ask, r.ask); return; }
			if (!r || !r.staged) { cb('I could not stage that.'); return; }
			var when_text = r.timestamp ? (' for ' + new Date(parseInt(r.timestamp, 10)).toLocaleString()) : '';
			var who = a.title || a.app || '';
			// The Confirmation Requirement tick: off means the proposal is saved
			// the moment it is made, so promote it here instead of asking
			if (typeof assistantConfirmRequired === 'function' && !assistantConfirmRequired()) {
				$.post('/manager/help/promote', { uuid: r.staged }, function (p) {
					if (p && p.error) { cb('I could not save that: ' + p.error); return; }
					cb('Saved a "' + who + '" appointment' + when_text + '.', 'Done - it is saved.');
				}).fail(function () { cb('I staged it but could not save it.'); });
				return;
			}
			jawnos_help_last_staged = r.staged;
			cb('Staged a "' + who + '" appointment' + when_text + '. It is NOT saved yet.',
				'I have staged it - say yes and I will save it.');
		}).fail(function () { cb('I could not stage that.'); });
		return;
	}
	if (a.action === 'promote') {
		if (!jawnos_help_last_staged) { cb('There is nothing staged to save.'); return; }
		var id = jawnos_help_last_staged;
		$.post('/manager/help/promote', { uuid: id }, function (r) {
			jawnos_help_last_staged = null;
			if (r && r.error) { cb('I could not save that: ' + r.error); return; }
			if (r && r.kind === 'update') {
				cb('Done - ' + (r.summary || 'I made the change') + '. Say "undo that" to put it back.', 'Done - ' + (r.summary || 'I made the change') + '.');
				return;
			}
			cb('Saved it as a real appointment.', 'Done - it is saved.');
		}).fail(function () { cb('I could not save that.'); });
		return;
	}
	if (a.action === 'discard') {
		if (!jawnos_help_last_staged) { cb('There is nothing staged to drop.'); return; }
		var drop = jawnos_help_last_staged;
		$.post('/manager/help/discard', { uuid: drop }, function () {
			jawnos_help_last_staged = null;
			cb('Dropped the staged appointment.', 'Done - I threw it away.');
		}).fail(function () { cb('I could not drop that.'); });
		return;
	}
	if (a.action === 'schedule') {
		// a schedule the Guide could not read on the first pass: the appointment or
		// bill is already made and the token names it, so this only writes repeats
		$.post('/manager/help/schedule', { token: a.token || '', text: a.text || '' }, function (r) {
			if (!r || r.error) { cb((r && r.error) || 'I could not apply that schedule.', 'I could not apply that schedule.'); return; }
			if (r.ask) { cb(r.ask, r.ask); return; }
			var summary = r.summary || ('scheduled ' + (r.count || 0) + ' more');
			cb(summary + '.', 'Done - ' + summary + '.');
		}).fail(function () { cb('I could not apply that schedule.'); });
		return;
	}
	if (a.action === 'update') {
		// a change to an appointment that already exists: the server resolves the
		// appointment and the fields, and stages the change as a proposal
		$.post('/manager/help/update', { app: a.app || '', app_uuid: a.app_uuid || '', title: a.title || '', delay: a.delay || '', when: a.when || '', duration: a.duration || '', notes: a.notes || '' }, function (r) {
			if (r && r.ask) { cb(r.ask, r.ask); return; }
			if (!r || r.error) { cb('I could not change that: ' + ((r && r.error) || 'no such appointment') + '.', 'I could not make that change.'); return; }
			var what = r.summary || ('change ' + (r.app || a.app || 'the appointment'));
			if (typeof assistantConfirmRequired === 'function' && !assistantConfirmRequired()) {
				$.post('/manager/help/promote', { uuid: r.staged }, function (p) {
					if (p && p.error) { cb('I could not change that: ' + p.error); return; }
					cb('Done - ' + what + '. Say "undo that" to put it back.', 'Done - ' + what + '.');
				}).fail(function () { cb('I staged the change but could not save it.'); });
				return;
			}
			jawnos_help_last_staged = r.staged;
			cb('I will ' + what + '. It is NOT changed yet.', 'I have staged it - say yes and I will change it.');
		}).fail(function () { cb('I could not change that.'); });
		return;
	}
	if (a.action === 'undo') {
		$.post('/manager/help/undo', {}, function (r) {
			if (!r || !r.ok) { cb((r && r.error) || 'There is nothing to undo.', 'There is nothing to undo.'); return; }
			cb('Put it back - ' + (r.summary || 'the last change was undone') + '.', 'Done - I put it back.');
		}).fail(function () { cb('I could not undo that.'); });
		return;
	}
	if (a.action === 'stop') {
		// a stop acts at once (not staged): the server stops what the app has running
		$.post('/manager/help/stop', { app: a.app || '', app_uuid: a.app_uuid || '', when: a.when || '', title: a.title || '' }, function (r) {
			if (r && r.ask) { cb(r.ask, r.ask); return; }
			if (!r || !r.ok) { cb((r && r.error) || 'There was nothing running to stop.', 'There is nothing running to stop.'); return; }
			cb('Done - ' + (r.summary || 'stopped it') + '. Say "undo that" to put it back.', 'Done - ' + (r.summary || 'stopped it') + '.');
		}).fail(function () { cb('I could not stop that.'); });
		return;
	}
	if (a.action === 'delete') {
		$.post('/manager/help/delete', { app: a.app || '', app_uuid: a.app_uuid || '', title: a.title || '', when: a.when || '', which: a.which || '' }, function (r) {
			if (r && r.ask) { cb(r.ask, r.ask); return; }
			if (!r || r.error) { cb('I could not find that appointment: ' + ((r && r.error) || 'not found') + '.', 'I could not find that one.'); return; }
			var what = r.summary || ('delete the ' + (r.app || a.app || '') + ' appointment');
			if (typeof assistantConfirmDeleteRequired === 'function' ? !assistantConfirmDeleteRequired() : (typeof assistantConfirmRequired === 'function' && !assistantConfirmRequired())) {
				$.post('/manager/help/promote', { uuid: r.staged }, function (p) {
					if (p && p.error) { cb('I could not delete that: ' + p.error); return; }
					cb('Done - ' + what + '.', 'Done - ' + what + '.');
				}).fail(function () { cb('I staged the delete but could not carry it out.'); });
				return;
			}
			jawnos_help_last_staged = r.staged;
			cb('I will ' + what + '. It is NOT deleted yet.', 'I have staged it - say yes and I will delete it.');
		}).fail(function () { cb('I could not do that.'); });
		return;
	}
	if (a.action === 'generate') {
		var kind = (a.kind === 'audio' || a.kind === 'video') ? a.kind : 'image';
		$.post('/manager/help/generate', { kind: kind, prompt: a.prompt || '', app: a.app || '' }, function (r) {
			if (!r || !r.ok) { cb((r && r.error) || 'I could not make that.', 'I could not make that.'); return; }
			var where = r.unclaimed ? '; it waits in the Camera pool to be filed' : (' onto “' + (r.app || 'the appointment') + '”');
			cb('Made ' + kind + ' with ' + (r.model || 'the agent') + where + '.', 'Done - I made it.');
		}).fail(function () { cb('I could not make that.', 'I could not make that.'); });
		return;
	}
	if (a.action === 'show_place') {
		$.get('/manager/help/place', { q: a.place || '' }, function (r) {
			if (!r || r.error || !r.latitude) { cb((r && r.error) || ('I have no place called “' + (a.place || '') + '” measured yet.')); return; }
			var lat = parseFloat(r.latitude), lon = parseFloat(r.longitude);
			if (!$('#travel_campus').length && typeof appWindowOpener === 'function') { appWindowOpener('travel', Date.now(), {}); }
			var tries = 0;
			var centre = function () {
				var engine = (typeof travelMapEngine === 'function') ? travelMapEngine() : null;
				// the viewer frames itself once, on its first render; wait for that so our
				// focus is the one that sticks rather than being overwritten a beat later
				var framed = (typeof travelFramed === 'undefined') ? true : travelFramed;
				if (engine && framed) {
					var place_point = function () {
						engine.setPoints([{ lat: lat, lon: lon, label: r.place || a.place || '', colour: '#e23b3b' }]);
						engine.focusOn(lat, lon);
						engine.draw();
					};
					place_point();
					setTimeout(place_point, 900);
					var extra = (r.count > 1) ? (' — the middle of ' + r.count + ' places named for it') : '';
					cb('Centred the map on ' + (r.place || a.place) + extra + '.', 'Here is ' + (r.place || a.place) + ' on the map.');
					return;
				}
				if (++tries < 40) { setTimeout(centre, 250); }
				else { cb('I opened Travel but the map was not ready to centre.'); }
			};
			setTimeout(centre, 300);
		}).fail(function () { cb('I could not look that place up.'); });
		return;
	}
	if (a.action === 'where_when') {
		$.get('/manager/help/where', { when: a.when || '' }, function (r) {
			if (!r || r.error) { cb((r && r.error) || 'I could not read that time.'); return; }
			if (!r.found) { cb('I have no place fix recorded for ' + (a.when || 'that time') + '.'); return; }
			var text = 'The nearest fix before then was at ' + r.at + (r.place ? (', by ' + r.place) : '') + ' (' + r.latitude + ', ' + r.longitude + ').';
			cb(text, text);
		}).fail(function () { cb('I could not look that up.'); });
		return;
	}
	if (a.action === 'measure') {
		$.get('/manager/help/measure', { measure: a.measure || '', period: a.period || 'month', target: a.target || '' }, function (r) {
			if (!r || r.error) { cb((r && r.error) || 'I could not measure that.'); return; }
			cb(r.text || 'I measured nothing.', r.text || '');
		}).fail(function () { cb('I could not measure that.'); });
		return;
	}
	if (a.action === 'translate') {
		if (!a.text) { cb('I did not catch what to translate.'); return; }
		$.post('/manager/translate', { to: a.to || '', from: a.from || '', text: a.text, model: a.model || '' }, function (r) {
			if (!r || !r.ok) { cb((r && r.error) || 'I could not translate that.'); return; }
			var t = r.translation || '';
			cb('Translated into ' + (r.to.native || r.to.name) + ': ' + t, t);
		}).fail(function () { cb('I could not translate that.'); });
		return;
	}
	if (a.action === 'translate_page') {
		if (typeof jawnosTranslatePage !== 'function') { cb('The translator is not loaded in this window.'); return; }
		cb('Translating this window into ' + (a.to || 'the chosen language') + '…');
		var root = document.querySelector('.wind[app="help"]') || document.body;
		jawnosTranslatePage(a.to || '', function (r) {
			if (!r || !r.ok) { cb((r && r.error) || 'I could not translate this window.'); return; }
			var n = (r.translated || 0) + (r.cached || 0);
			cb('Translated the visible interface into ' + (r.to.native || r.to.name) + ' (' + n + ' strings).', 'Done - this window is in ' + (r.to.native || r.to.name) + '.');
		}, function (r) {
			cb((r && r.error) || 'I could not translate this window.');
		}, root, a.model || '');
		return;
	}
	if (a.action === 'translate_languages') {
		$.get('/manager/translate/languages', function (r) {
			if (!r || !r.languages) { cb('I could not read the language list.'); return; }
			var names = r.languages.map(function (l) { return l.native + ' (' + l.name + ')'; }).join(', ');
			cb('The translation engine offers ' + r.languages.length + ' languages: ' + names + '.', 'I can translate into ' + r.languages.length + ' languages; ask for one by name.');
		}).fail(function () { cb('I could not read the language list.'); });
		return;
	}
	if (a.action === 'play_music') {
		helpPlayMusic(a.query || '', cb, a.shuffle);
		return;
	}
	if (a.action === 'page') {
		if (typeof pageAgentDo !== 'function') { cb('The page agent is not loaded in this window.'); return; }
		pageAgentDo(a, cb);
		return;
	}
	if (a.action === 'remote') {
		// the model sometimes labels the instruction "command" rather than "text"
		var machine = a.machine || a.target || '';
		var what = a.text || a.command || '';
		if (!machine || !what) { cb('I need both a machine and what to do there.'); return; }
		$.post('/manager/remote_command/send', { machine: machine, text: what }, function (r) {
			// a login page (or any non-JSON body) means the machine answered nothing
			if (!r || typeof r !== 'object' || r.ok === 0 || r.error) { cb((r && r.error) || ('I could not reach ' + machine + '.')); return; }
			cb('On ' + machine + ': ' + (r.observation || 'done') + '.', 'On ' + machine + ' — ' + (r.observation || 'done') + '.');
		}).fail(function () { cb('I could not reach ' + machine + '.'); });
		return;
	}
	// a runtime (learned) verb, or anything the browser has no local effect for:
	// the server runs it through its primitive executor and reports back
	$.post('/manager/help/verb', { action: JSON.stringify(a) }, function (r) {
		if (!r || r.ok === 0 || r.error) { cb((r && r.error) || 'That command did not run.'); return; }
		cb(r.observation || 'done');
	}).fail(function () { cb('That command did not run.'); });
}

// Play music or an episode by its name: ask the server (which runs the music
// app's own search) for every match, then open the music app on the list - a
// show plays through as a queue of episodes. The music app does the playing;
// the guide only has to name the thing.
function helpPlayMusic(query, cb, shuffle) {
	var q = $.trim(query || '');
	if (!q) { cb('I did not catch what to play.'); return; }
	$.get('/manager/help/music', { q: q, shuffle: shuffle ? 1 : 0 }, function (r) {
		if (!r || !r.found) { cb('I searched the library for “' + q + '” but found nothing to play.'); return; }
		if (typeof musicToggle !== 'function') { cb('The music app is not available here.'); return; }
		// every match rides along, so a show plays as a list of its episodes
		var list = (r.files && r.files.length) ? r.files : [r.file];
		musicToggle(list, r.same_order ? 1 : 0);
		if (list.length > 1) {
			cb('Playing ' + list.length + ' matches.', 'Now playing ' + list.length + ' matches.');
		}
		else {
			cb('Playing ' + r.title + '.', 'Now playing ' + r.title + '.');
		}
	}).fail(function () { cb('I could not reach the music library.'); });
}

// A message set to the Guide from outside this window: a clip the house heard
// and transcribed - from the watch, the t-deck, a board - or anything else
// addressed to the guide. It is put in the composer and asked exactly as if it
// had been typed here, so the Guide answers it in this conversation. The spoken
// half of the answer still goes back to the device (the server sends it), this
// is the Guide's own copy of the exchange.
function helpChatIngest(text) {
	var q = $.trim(text == null ? '' : String(text));
	if (!q) { return; }
	if (!$('.wind[app="help"] #help_question').length) { return; }	// no Guide window open
	$('#help_question').val(q);
	helpAsk();
}

function helpAsk() {
	var model = $('#help_model').val();
	var q = $.trim($('#help_question').val() || '');
	if (!model) {
		helpShowChat(true);
		helpChatAdd('step', 'Choose a model in the row above first — the guide needs one to think with.');
		return;
	}
	if (!q) {
		// an empty Send means "listen": record a clip, transcribe it, then ask
		helpListenToggle(function (text) { $('#help_question').val(text); helpAsk(); });
		return;
	}
	// the farewell is read first: "bye jawn" (or the End button) closes a
	// conversation. No wake phrase is needed to speak - opening the mic is the
	// whole of it.
	if (helpConversationBye(q)) { $('#help_question').val(''); if (jawnos_help_talking) { helpConversationEnd(); } return; }
	$('#help_question').val('');
	helpShowChat(true);
	jawnos_help_chat.push({ role: 'user', content: q });
	helpChatAdd('user', q);
	if (jawnos_help_coding) { helpCodingRun(q); return; }
	helpAgentStep(0);
}

// ---- speech in -----------------------------------------------------------
// One recorder, shared by the help window's guide and the associates: record a
// short clip from the browser, post the raw bytes and let the server's whisper
// pipeline turn it into words. In a conversation the clip ends itself once
// speech has been heard and the room falls quiet, so nobody has to press Stop
// between turns.
var jawn_clip = { recorder: null, chunks: [], pcm: [], pcm_rate: 0, listening: false, cb: null, discard: false, meter: null, maxtimer: null, audioctx: null, owner: null };

function jawnClipListening() { return jawn_clip.listening; }

function jawnClipCleanup() {
	if (jawn_clip.meter) { clearInterval(jawn_clip.meter); jawn_clip.meter = null; }
	if (jawn_clip.maxtimer) { clearTimeout(jawn_clip.maxtimer); jawn_clip.maxtimer = null; }
	if (jawn_clip.audioctx) { try { jawn_clip.audioctx.close(); } catch (e) {} jawn_clip.audioctx = null; }
}

// WebKit's MP4/AAC recorder reports support and then produces no data at all, so
// a type that actually writes (webm/ogg first) is preferred over the default.
function jawnClipMime() {
	if (!window.MediaRecorder || !MediaRecorder.isTypeSupported) { return ''; }
	var types = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/ogg', 'audio/mp4'];
	try {
		for (var i = 0; i < types.length; i++) {
			if (MediaRecorder.isTypeSupported(types[i])) { return types[i]; }
		}
	}
	catch (e) { return ''; }
	return '';
}

// The fallback clip: the samples the room reader already saw, written as a plain
// 16-bit mono WAV that ffmpeg (and so whisper) reads anywhere.
function jawnClipWavBlob(pcm, rate) {
	var n = 0, i, j;
	for (i = 0; i < pcm.length; i++) { n += pcm[i].length; }
	if (!n) { return new Blob([], { type: 'audio/wav' }); }
	rate = rate || 48000;
	var buf = new ArrayBuffer(44 + n * 2);
	var view = new DataView(buf);
	var put = function (off, s) { for (var k = 0; k < s.length; k++) { view.setUint8(off + k, s.charCodeAt(k)); } };
	put(0, 'RIFF');
	view.setUint32(4, 36 + n * 2, true);
	put(8, 'WAVE');
	put(12, 'fmt ');
	view.setUint32(16, 16, true);
	view.setUint16(20, 1, true);   // PCM
	view.setUint16(22, 1, true);   // mono
	view.setUint32(24, rate, true);
	view.setUint32(28, rate * 2, true);
	view.setUint16(32, 2, true);
	view.setUint16(34, 16, true);
	put(36, 'data');
	view.setUint32(40, n * 2, true);
	var off = 44;
	for (i = 0; i < pcm.length; i++) {
		var ch = pcm[i];
		for (j = 0; j < ch.length; j++) {
			var s = Math.max(-1, Math.min(1, ch[j]));
			view.setInt16(off, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
			off += 2;
		}
	}
	return new Blob([buf], { type: 'audio/wav' });
}

// end the clip now, or throw it away (the silence watch and the cap call this)
function jawnClipStop(discard) {
	if (discard) { jawn_clip.discard = true; }
	// Silence the meter and the cap at once, but leave the audio context for
	// onstop: closing it before the recorder stops starves the clip of its last
	// chunk in WebKit, which sends an empty body.
	if (jawn_clip.meter) { clearInterval(jawn_clip.meter); jawn_clip.meter = null; }
	if (jawn_clip.maxtimer) { clearTimeout(jawn_clip.maxtimer); jawn_clip.maxtimer = null; }
	if (jawn_clip.recorder && jawn_clip.recorder.state !== 'inactive') {
		// ask for what is buffered before the stop: an engine that only hands
		// data over on its own schedule still gives the clip a last chunk
		try { if (jawn_clip.recorder.requestData) { jawn_clip.recorder.requestData(); } } catch (e) {}
		jawn_clip.recorder.stop();
	}
	else { jawnClipCleanup(); }
}

// opts: { talking, owner, onText(text), onFail(reason), status(msg), onstart, onend }
function jawnClipListen(opts) {
	opts = opts || {};
	if (jawn_clip.listening) { return false; }
	if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
		if (opts.status) { opts.status('This device has no microphone I can reach.'); }
		if (opts.onFail) { opts.onFail('no microphone'); }
		return false;
	}
	// A level-based end-of-turn reader needs the room as it really is. Auto gain
	// lifts a laptop fan or a steady hiss up to speech level (a floor read at
	// 0.29 with the room at 0.4 is a room compressed nearly to full scale), and
	// noise suppression pumps as it gates. Echo cancellation is kept so the
	// guide's own spoken answer does not loop back as the person's turn.
	var mic = navigator.mediaDevices.getUserMedia({ audio: {
		echoCancellation: true,
		noiseSuppression: false,
		autoGainControl: false
	} }).catch(function () {
		// an engine that refuses the processing hints still gets a plain stream
		return navigator.mediaDevices.getUserMedia({ audio: true });
	});
	mic.then(function (stream) {
		// what the engine actually granted, in the same debug switch the room uses
		try {
			if (localStorage.getItem('jawn_room_debug') == 'on') {
				var mic_track = stream.getAudioTracks ? stream.getAudioTracks()[0] : null;
				var mic_settings = (mic_track && mic_track.getSettings) ? mic_track.getSettings() : {};
				console.log('[mic] ' + JSON.stringify(mic_settings));
			}
		} catch (e) {}
		jawn_clip.chunks = [];
		jawn_clip.pcm = [];
		jawn_clip.pcm_rate = 0;

		// One audio graph serves both readers: an analyser for the room (with a
		// fan's low rumble taken off) and a PCM tap that can stand in for the
		// recorder when the engine writes nothing. The tap is muted, never played.
		var an = null;
		try {
			var ctx = new (window.AudioContext || window.webkitAudioContext)();
			var src = ctx.createMediaStreamSource(stream);
			var hp = ctx.createBiquadFilter();
			hp.type = 'highpass';
			hp.frequency.value = 180;
			src.connect(hp);
			an = ctx.createAnalyser();
			an.fftSize = 1024;
			hp.connect(an);
			var mk = ctx.createScriptProcessor || ctx.createJavaScriptNode;
			if (mk) {
				var pcm_node = mk.call(ctx, 4096, 1, 1);
				jawn_clip.pcm_rate = ctx.sampleRate || 48000;
				pcm_node.onaudioprocess = function (e) {
					if (!jawn_clip.listening || !jawn_clip.pcm) { return; }
					var ch = e.inputBuffer.getChannelData(0);
					try { jawn_clip.pcm.push(ch.slice()); }
					catch (err) {
						var copy = new Float32Array(ch.length);
						copy.set(ch);
						jawn_clip.pcm.push(copy);
					}
				};
				var mute = ctx.createGain();
				mute.gain.value = 0;
				hp.connect(pcm_node);
				pcm_node.connect(mute);
				mute.connect(ctx.destination);
			}
			jawn_clip.audioctx = ctx;
			try { if (ctx.state === 'suspended' && ctx.resume) { ctx.resume(); } } catch (err) {}
		}
		catch (e) { an = null; }

		var mime = jawnClipMime();
		var rec = null;
		try { rec = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream); }
		catch (err) { try { rec = new MediaRecorder(stream); } catch (err2) { rec = null; } }
		if (!rec) {
			jawnClipCleanup();
			stream.getTracks().forEach(function (t) { t.stop(); });
			if (opts.status) { opts.status('I could not start the recorder.'); }
			if (opts.onFail) { opts.onFail('recorder'); }
			return;
		}
		jawn_clip.recorder = rec;
		jawn_clip.listening = true;
		jawn_clip.cb = opts.onText || null;
		jawn_clip.discard = false;
		jawn_clip.owner = opts.owner || null;
		if (opts.onstart) { opts.onstart(); }
		rec.ondataavailable = function (e) { if (e.data && e.data.size) { jawn_clip.chunks.push(e.data); } };
		rec.onstop = function () {
			jawn_clip.listening = false;
			jawn_clip.owner = null;
			var blob = new Blob(jawn_clip.chunks, { type: rec.mimeType || 'audio/webm' });
			var from = 'media';
			var pcm_n = 0, pi;
			if (jawn_clip.pcm) { for (pi = 0; pi < jawn_clip.pcm.length; pi++) { pcm_n += jawn_clip.pcm[pi].length; } }
			// a recorder that wrote nothing (WebKit's MP4/AAC) or only a sliver is
			// replaced by the samples the room reader already had
			if (pcm_n > (jawn_clip.pcm_rate || 48000) * 0.2 && blob.size < 4000) {
				blob = jawnClipWavBlob(jawn_clip.pcm, jawn_clip.pcm_rate);
				from = 'wav';
			}
			jawn_clip.last_from = from;
			jawn_clip.pcm = [];
			jawn_clip.pcm_rate = 0;
			jawnClipCleanup();
			stream.getTracks().forEach(function (t) { t.stop(); });
			if (opts.onend) { opts.onend(); }
			if (jawn_clip.discard) { jawn_clip.discard = false; return; }
			jawnClipSend(blob, opts);
		};
		if (opts.talking) {
			// hands-free: the clip ends by itself once speech has been heard and
			// the room falls quiet. The quiet is the room's own floor, learned by the
			// same reader the keyboard's dictation uses, rather than a fixed number
			// a fan or a steady hiss would sit above forever.
			if (opts.status) { opts.status('Listening…'); }
			if (an) {
				var data = new Uint8Array(an.fftSize);
				// the room reader lives with the keyboard's dictation; a page that
				// has no soft keyboard still ends a turn on the old fixed floor
				var has_room = (typeof jawnRoomThreshold === 'function');
				var threshold = has_room ? jawnRoomThreshold : function (onset) { return onset ? 0.06 : 0.04; };
				var learn = has_room ? jawnRoomLearn : function () {};
				var room_read = has_room ? jawnRoomRead : function () { return 0; };
				var read = has_room ? JAWN_ROOM_READ_FRAMES : 0;
				// the middle of three ticks already waits out a single tap, so one
				// median-loud tick is a voice that held
				var onset_frames = 1;
				var fallback = has_room ? JAWN_ROOM_FALLBACK : 0.02;
				// a conversation waits 1.1s before it lets go, so it can afford to
				// read a drop further under the turn's peak than dictation does; this
				// is the safety net when a fan sits above the floor it was given
				var peak_ratio = 2.5;
				var heard = false, run = 0, quiet_since = 0, peak = 0, win = [], recent = [], tick = 0;
				// diagnosing a room that will not go quiet: set jawn_room_debug=on
				// in the console and the level, floor and thresholds print once a second
				var debug_room = false;
				try { debug_room = (localStorage.getItem('jawn_room_debug') == 'on'); } catch (e) {}
				jawn_clip.meter = setInterval(function () {
					an.getByteTimeDomainData(data);
					var rms = 0;
					for (var i = 0; i < data.length; i++) { var d = (data[i] - 128) / 128; rms += d * d; }
					rms = Math.sqrt(rms / data.length);
					recent.push(rms);
					if (recent.length > 3) { recent.shift(); }
					// the middle of three ticks: a fan's own peaks and a single tap do
					// not read as speech, while a voice holds across the window
					var sorted_recent = recent.slice().sort(function (a, b) { return a - b; });
					var level = (sorted_recent.length >= 3) ? sorted_recent[1] : rms;
					// a turn opens by reading the room; the audio is already being
					// recorded, so speech in this moment is not lost
					if (read > 0) {
						win.push(rms);
						if (--read === 0) {
							// a window that wobbled might be a voice, but a conversation's
							// first window (just after Converse is pressed) is the room, so it
							// may trust its middle reading. A short answer that arrived before
							// the window closed still counts, if it is voice-loud.
							var steady = (room_read(win) != null);
							learn(win, true);
							if (!heard && !steady && Math.max.apply(null, win) > threshold(true)) {
								heard = true;
								run = 0;
								quiet_since = 0;
								peak = Math.max.apply(null, win);
							}
						}
						return;
					}
					var loud = (level > threshold(false));
					var quiet = (level <= threshold(false));
					if (debug_room && ((tick++ % 8) === 0)) {
						console.log('[conversation room] floor=' + (has_room ? (jawnRoom.floor || 0) : 0).toFixed(4)
							+ ' level=' + level.toFixed(4) + ' quiet<' + threshold(false).toFixed(4)
							+ ' onset>' + threshold(true).toFixed(4) + ' heard=' + heard);
					}
					if (!heard) {
						// the median already waits out a single tap or fan peak
						if (!loud) { run = 0; return; }
						if (++run < onset_frames) { return; }
						heard = true;
						run = 0;
						quiet_since = 0;
						peak = rms;
						return;
					}
					if (rms > peak) { peak = rms; }
					// the pause is read against the room and against the turn's own
					// peak, so a room that reads high or low still lets go
					var hushed = (peak > fallback && level * peak_ratio < peak);
					if (!quiet && !hushed) { quiet_since = 0; return; }
					if (!quiet_since) { quiet_since = Date.now(); return; }
					if (Date.now() - quiet_since > 1100) { jawnClipStop(); }
				}, 120);
			}
			// a clip with no analyser still needs its cap
			jawn_clip.maxtimer = setTimeout(function () { jawnClipStop(); }, 30000);
		}
		else if (opts.status) { opts.status('Listening — press Stop when you are done.'); }
		try { rec.start(250); }
		catch (err) {
			// a timeslice makes the chunks arrive while the clip runs; if the
			// engine will not take one, a plain start is still worth trying
			try { rec.start(); }
			catch (err2) {
				jawn_clip.listening = false;
				jawn_clip.recorder = null;
				jawnClipCleanup();
				stream.getTracks().forEach(function (t) { t.stop(); });
				if (opts.status) { opts.status('I could not start the recorder.'); }
				if (opts.onFail) { opts.onFail('recorder'); }
				return;
			}
		}
	}).catch(function () {
		jawn_clip.listening = false;
		if (opts.onend) { opts.onend(); }
		if (opts.status) { opts.status('I could not reach the microphone.'); }
		if (opts.onFail) { opts.onFail('microphone'); }
	});
	return true;
}

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
