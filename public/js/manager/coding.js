/* [[js-split]] parts: 01_fixes.js 02_panels.js 03_reload.js 04_fixed.js [[/js-split]] */
// The Coding agent's chatbox, mounted by the apps that want it (the terminal and
// the IDE today). It is the same self-healing agent the Guide's Coding toggle
// drives: the words go to /manager/coding/heal, which reads and writes the repo,
// checks the change, and ships it. Each mount keeps its own conversation name, so
// the terminal and the editor remember their own threads.

function codingChatPanel(mount) { return $('#coding_chat_' + mount); }

// New panel text goes through the interface translator; a page without
// translate.js simply shows the English.
function codingT(text) {
	return (typeof jawnosT === 'function') ? jawnosT.apply(null, arguments) : text;
}

function codingChatLine(a) {
	// a one-line label for a step, matching the Guide's wording
	var act = (a && a.action) || '';
	if (act === 'write') { return 'Wrote ' + (a.path || '?'); }
	if (act === 'read') { return 'Read ' + (a.path || '?'); }
	if (act === 'list') { return 'Listed ' + (a.path || '.'); }
	if (act === 'run') { return 'Ran ' + (a.command || ''); }
	if (act === 'bump') { return 'Bumped the version'; }
	if (act === 'commit') { return 'Committed'; }
	if (act === 'push') { return 'Pushed to GitHub'; }
	if (act === 'restart') { return 'Restarting'; }
	return act || 'Step';
}

function codingChatAdd(mount, role, text) {
	var log = codingChatPanel(mount).find('.coding_chat_log');
	if (!log.length) { return; }
	var safe = $('<div>').text(text == null ? '' : String(text)).html().replace(/\n/g, '<br>');
	if (role === 'step') {
		log.append($('<div style="text-align:center;margin:5px 0;"><span class="chat_step">' + safe + '</span></div>'));
	}
	else {
		var mine = (role === 'user');
		var bubble = '<span style="display:inline-block;max-width:88%;overflow-wrap:break-word;border-radius:10px;padding:6px 10px;'
			+ (mine ? 'background:var(--chat-bubble-me);' : 'background:var(--chat-bubble-them);') + '">' + safe + '</span>';
		log.append($('<div style="display:flex;margin:4px 0;' + (mine ? 'justify-content:flex-end;' : 'justify-content:flex-start;') + '">' + bubble + '</div>'));
	}
	log.scrollTop(log[0].scrollHeight);
}

function codingChatToggle(mount) {
	var panel = codingChatPanel(mount);
	if (!panel.length) { return; }
	panel.css('display', panel.is(':visible') ? 'none' : 'flex');
	var input = panel.find('.coding_chat_input');
	if (panel.is(':visible') && input.length) { input.focus(); }
	if (panel.is(':visible')) { codingFixesFetch(mount); codingChatRestoreScroll(mount); }
}

// Draw the run's steps that have not been drawn yet. Callers pass only the steps
// after coding_steps_shown, so a restored log cannot be repeated.
function codingChatStepsShow(mount, steps) {
	(steps || []).forEach(function (s) {
		var a = s.action || {};
		var obs = String(s.observation == null ? '' : s.observation).replace(/\s+\n/g, '\n').replace(/\n+/g, ' · ');
		if (obs.length > 240) { obs = obs.slice(0, 240) + '…'; }
		codingChatAdd(mount, 'step', codingChatLine(a) + (obs ? (' → ' + obs) : ''));
	});
}

// The stop control follows the run: it is only there while one is going.
function codingChatRunning(panel) {
	if (!panel || !panel.length) { return; }
	panel.find('.coding_chat_stop').css('display', panel.data('coding_running') ? '' : 'none');
}

function codingChatSend(mount) {
	var panel = codingChatPanel(mount);
	var input = panel.find('.coding_chat_input');
	var task = $.trim(input.val() || '');
	if (!task) { return; }
	input.val('');
	// a new ask is a new run: forget the last one's count and any poller still
	// waiting on it, so its steps never land in the new answer
	var waiting = panel.data('coding_poll_timer');
	if (waiting) { clearTimeout(waiting); }
	panel.removeData('coding_poll_timer');
	panel.data('coding_run', 0);
	panel.data('coding_steps_shown', 0);
	panel.data('coding_queued_shown', 0);
	codingChatAdd(mount, 'user', task);
	codingChatAdd(mount, 'step', 'Coding — reading and changing the repo…');
	panel.data('coding_running', 1);
	codingChatRunning(panel);
	$.ajax({
		url: '/manager/coding/heal',
		type: 'POST',
		dataType: 'json',
		data: { task: task, conversation: panel.attr('conversation') || mount },
		success: function (r) {
			if (!r || r.error) {
				codingChatAdd(mount, 'guide', (r && r.error) || 'The coding agent failed.');
				panel.data('coding_running', 0);
				codingChatRunning(panel);
				return;
			}
			if (r.run) {
				// the run is a background job now: poll it until it settles
				panel.data('coding_run', r.run);
				codingChatPoll(mount, r.run);
				return;
			}
			// defensive: an older server may answer in the request instead of queueing
			codingChatStepsShow(mount, r.steps || []);
			if (r.final) { codingChatAdd(mount, 'guide', r.final); }
			else { codingChatAdd(mount, 'guide', codingT('Done — now at version {0}.', (r.version || '?'))); }
			if (r.title) { panel.data('title', r.title); if (panel.attr('spawned')) { codingChatTitleShow(panel); } }
			codingFixesFetch(mount);
			panel.data('coding_running', 0);
			codingChatRunning(panel);
		},
		error: function () {
			codingChatAdd(mount, 'guide', 'The coding agent could not be reached.');
			panel.data('coding_running', 0);
			codingChatRunning(panel);
		}
	});
}

// Apply one snapshot of a run. Returns true while polling should continue.
function codingChatPollApply(mount, run, r) {
	var panel = codingChatPanel(mount);
	if (!panel.length) { return false; }
	// a send that started a newer run owns the panel now: an answer still in
	// flight for the old one is dropped rather than drawn over it
	if (run && panel.data('coding_run') && panel.data('coding_run') !== run) { return false; }
	if (r.run) { panel.data('coding_run', r.run); }
	else if (run) { panel.data('coding_run', run); }
	var steps = r.steps || [];
	var shown = parseInt(panel.data('coding_steps_shown'), 10) || 0;
	if (shown > steps.length) { shown = 0; }
	if (steps.length > shown) {
		codingChatStepsShow(mount, steps.slice(shown));
		panel.data('coding_steps_shown', steps.length);
	}
	var state = r.state || 'none';
	if (state === 'finished') {
		codingChatAdd(mount, 'guide', r.final || codingT('Done — now at version {0}.', (r.version || '?')));
		if (r.title) { panel.data('title', r.title); if (panel.attr('spawned')) { codingChatTitleShow(panel); } }
		codingFixesFetch(mount);
		panel.data('coding_running', 0);
		codingChatRunning(panel);
		return false;
	}
	if (state === 'failed') {
		codingChatAdd(mount, 'guide', r.error || codingT('The coding run failed.'));
		panel.data('coding_running', 0);
		codingChatRunning(panel);
		return false;
	}
	if (state === 'stale' || state === 'none') {
		codingChatAdd(mount, 'step', codingT('The background coding process is not running; the run was not finished.'));
		panel.data('coding_running', 0);
		codingChatRunning(panel);
		return false;
	}
	if (state === 'queued' && !r.worker && !panel.data('coding_queued_shown')) {
		panel.data('coding_queued_shown', 1);
		codingChatAdd(mount, 'step', codingT('Queued — waiting for the background coding process.'));
	}
	return true;
}

function codingChatPoll(mount, run) {
	var panel = codingChatPanel(mount);
	if (!panel.length) { return; }
	// one poller per panel: a second one would draw every step twice
	var old = panel.data('coding_poll_timer');
	if (old) { clearTimeout(old); }
	var tick = function () {
		var p = codingChatPanel(mount);
		if (!p.length) { return; }
		$.ajax({
			url: '/manager/coding/run',
			type: 'GET',
			dataType: 'json',
			cache: false,
			data: { id: run },
		success: function (r) {
				var again = codingChatPollApply(mount, run, r || {});
				var now = codingChatPanel(mount);
				if (!now.length) { return; }
				if (now.data('coding_run') && now.data('coding_run') !== run) { return; }
				if (again) { now.data('coding_poll_timer', setTimeout(tick, 1500)); }
				else { now.removeData('coding_poll_timer'); }
			},
			error: function () {
				var now = codingChatPanel(mount);
				if (!now.length) { return; }
				if (now.data('coding_run') && now.data('coding_run') !== run) { return; }
				codingChatAdd(mount, 'guide', 'The coding agent could not be reached.');
				now.data('coding_running', 0);
				codingChatRunning(now);
				now.removeData('coding_poll_timer');
			}
		});
	};
	panel.data('coding_poll_timer', setTimeout(tick, 1500));
}

// A reload rebuilds the panels: pick the conversation's run back up, replaying
// only the steps the restored log does not already hold.
function codingChatReattach(panel) {
	if (!panel || !panel.length) { return; }
	var mount = panel.attr('mount');
	var conv = panel.attr('conversation') || mount;
	if (!conv) { return; }
	$.ajax({
		url: '/manager/coding/run',
		type: 'GET',
		dataType: 'json',
		cache: false,
		data: { conversation: conv },
		success: function (r) {
			var p = codingChatPanel(mount);
			if (!p.length || !r) { return; }
			var state = r.state || 'none';
			var steps = r.steps || [];
			if (state === 'queued' || state === 'active') {
				var shown = parseInt(p.data('coding_steps_shown'), 10) || 0;
				if (shown > steps.length) { shown = 0; }
				if (steps.length > shown) {
					codingChatStepsShow(mount, steps.slice(shown));
					p.data('coding_steps_shown', steps.length);
				}
				var run = r.run || p.data('coding_run') || 0;
				if (run) {
					p.data('coding_run', run);
					p.data('coding_running', 1);
					codingChatRunning(p);
					codingChatPoll(mount, run);
				}
				return;
			}
			if (state === 'finished' && !p.attr('spawned')) {
				// a fresh window shows the result; a restored log already has it
				var log = p.find('.coding_chat_log');
				if (log.length && !log.html()) {
					codingChatStepsShow(mount, steps);
					p.data('coding_steps_shown', steps.length);
					p.data('coding_run', r.run || 0);
					codingChatAdd(mount, 'guide', r.final || codingT('Done — now at version {0}.', (r.version || '?')));
					if (r.title) { p.data('title', r.title); }
				}
			}
		}
	});
}

$(document).on('click', '.coding_chat_toggle', function () { codingChatToggle($(this).attr('mount')); });
$(document).on('click', '.coding_chat_close', function () {
	var panel = $(this).closest('.coding_chat');
	// a spawned agent was made on a whim: closing it takes it away, while a
	// mounted one stays put for its toolbar button to bring back
	if (panel.attr('spawned')) {
		if (typeof jawnosAgentOpenForget === 'function') { jawnosAgentOpenForget('coding:' + (panel.attr('conversation') || panel.attr('mount'))); }
		panel.remove();
	}
	else { panel.hide(); }
});
$(document).on('click', '.coding_chat_send', function () { codingChatSend($(this).closest('.coding_chat').attr('mount')); });
$(document).on('click', '.coding_chat_stop', function () {
	var panel = $(this).closest('.coding_chat');
	// the run stops after the step it is on, so running stays true until the poll
	// sees it settle - a stop is a request, not an instant
	$.ajax({
		url: '/manager/coding/cancel',
		type: 'POST',
		dataType: 'json',
		data: { run: panel.data('coding_run') || 0, conversation: panel.attr('conversation') || panel.attr('mount') },
		success: function () {},
		error: function () {}
	});
	codingChatAdd(panel.attr('mount'), 'step', codingT('Stopping — it stops after the step it is on.'));
});
$(document).on('click', '.coding_chat_forget', function () {
	var panel = $(this).closest('.coding_chat');
	var mount = panel.attr('mount');
	$.post('/manager/coding/forget', { conversation: panel.attr('conversation') || mount }, function () {
		panel.find('.coding_chat_log').empty();
		codingChatAdd(mount, 'step', 'Conversation forgotten.');
	});
});
$(document).on('keydown', '.coding_chat_input', function (e) {
	if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); codingChatSend($(this).closest('.coding_chat').attr('mount')); }
});
