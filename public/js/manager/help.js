// The Help app. A window that explains JawnOS in plain language, and a Guide
// that can operate the screen for the person:
//
//   - the start menu's Help icon, and appWindowOpener('help'), open it;
//   - F1 opens the topic for the window you are focused on (or for whatever
//     control you are hovering, when it declares a `help="topic"` attribute);
//   - the question-mark button in a window's title bar opens that window's app;
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
			+ (mine ? 'background:#cdeccd;' : 'background:#cfe3f5;') + '">' + safe + '</span>';
		log.append($('<div style="display:flex;margin:5px 0;' + (mine ? 'justify-content:flex-end;' : 'justify-content:flex-start;') + '">' + bubble + '</div>'));
	}
	log.scrollTop(log[0].scrollHeight);
}

function helpChatEnter() { helpShowChat(true); }

function helpTopicsBack() {
	helpShowChat(false);
	helpBody(jawnos_help_topic_current);
}

// ---- the guide that acts --------------------------------------------------

function helpActionLabel(a) {
	if (a.action === 'find') { return 'Searching for “' + (a.query || '') + '”…'; }
	if (a.action === 'open_app') { return 'Opening ' + (a.app || 'the app') + '…'; }
	if (a.action === 'play_music') { return 'Looking for “' + (a.query || '') + '” to play…'; }
	if (a.action === 'show_place') { return 'Finding ' + (a.place || 'the place') + ' on the map…'; }
	if (a.action === 'where_when') { return 'Looking up where you were…'; }
	if (a.action === 'measure') { return 'Measuring…'; }
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
		if (a.app && typeof appWindowOpener === 'function') { appWindowOpener(a.app, Date.now(), {}); }
		return cb('Opened the ' + (a.app || '') + ' window.', 'Done — I opened ' + (a.app || 'the app') + '.');
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
			names = (names || []).filter(function (n) { return n && n.length; });
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
		else if (a.app) { show([a.app], null); }
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
	if (a.action === 'create') {
		var when = helpResolveWhen(a.when);
		$.post('/manager/help/stage', { app: a.app || '', title: a.title || '', notes: a.notes || '', timestamp: when }, function (r) {
			if (!r || !r.staged) { cb('I could not stage that.'); return; }
			jawnos_help_last_staged = r.staged;
			var when_text = r.timestamp ? (' for ' + new Date(parseInt(r.timestamp, 10)).toLocaleString()) : '';
			cb('Staged a "' + (a.title || a.app || '') + '" appointment' + when_text + '. It is NOT saved yet.',
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
	if (a.action === 'play_music') {
		helpPlayMusic(a.query || '', cb);
		return;
	}
	cb(a.text || '');
}

// Play music by artist or track: ask the server (which runs the music app's own
// search) for the file, then open the music app on it. The music app does the
// playing; the guide only has to name the track.
function helpPlayMusic(query, cb) {
	var q = $.trim(query || '');
	if (!q) { cb('I did not catch what to play.'); return; }
	$.get('/manager/help/music', { q: q }, function (r) {
		if (!r || !r.found) { cb('I searched the library for “' + q + '” but found nothing to play.'); return; }
		if (typeof musicToggle === 'function') { musicToggle([r.file]); }
		else { cb('The music app is not available here.'); return; }
		cb('Playing ' + r.title + '.', 'Now playing ' + r.title + '.');
	}).fail(function () { cb('I could not reach the music library.'); });
}

function helpAsk() {
	var model = $('#help_model').val();
	var q = $.trim($('#help_question').val() || '');
	if (!model) {
		helpShowChat(true);
		helpChatAdd('step', 'Choose a model in the row above first — the guide needs one to think with.');
		return;
	}
	if (!q) { return; }
	$('#help_question').val('');
	helpShowChat(true);
	jawnos_help_chat.push({ role: 'user', content: q });
	helpChatAdd('user', q);
	helpAgentStep(0);
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
				helpChatAdd('guide', text);
				return;
			}
			helpChatAdd('step', helpActionLabel(a));
			jawnos_help_chat.push({ role: 'assistant', content: JSON.stringify(a) });
			helpDoAction(a, function (obs, friendly) {
				jawnos_help_chat.push({ role: 'tool', content: obs });
				if (friendly) {
					jawnos_help_chat.push({ role: 'assistant', content: friendly });
					helpChatAdd('guide', friendly);
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

$(document).on('click', '.help_button', function (e) {
	e.stopPropagation();
	var app = $(this).attr('app');
	jawnos_help_source = helpSourceFrom(app);
	helpOpener(app);
});

$(document).on('click', '.help_topic_link', function () {
	helpShowChat(false);
	helpBody($(this).attr('topic'));
});

$(document).on('click', '.help_open_app', function () {
	var app = $(this).attr('app');
	if (app && typeof appWindowOpener === 'function') { appWindowOpener(app, Date.now(), {}); }
});

$(document).on('click', '#help_ask', function () { helpAsk(); });
$(document).on('click', '#help_topics_back', function () { helpTopicsBack(); });

$(document).on('keydown', '#help_question', function (e) {
	if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); helpAsk(); }
});

$(document).on('change', '#help_model', function () {
	var v = $(this).val();
	if (v) { settingSetter({ app: 'mail', setting: 'help_assistant', value: v }); $('#assistant_model').text(v); }
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
