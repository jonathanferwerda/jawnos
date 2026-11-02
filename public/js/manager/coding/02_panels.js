
// ---- moving the panel, and having more than one -------------------------------
// The header is the handle, exactly as the Guide associate's bar is its handle,
// and the panel is kept on screen and clear of the taskbar. The + in the header
// spawns another agent: a clone with its own mount and conversation, so several
// can be open at once, each remembering its own thread.

var jawnos_coding_agents = 0;
var jawnos_coding_top = 50000;

function codingChatDraggable(panel) {
	if (!panel.length || !$.fn.draggable) { return; }
	panel.draggable({
		revert: 'false',
		handle: '.coding_chat_header',
		cancel: '.coding_chat_new, .coding_chat_close, .coding_chat_stop, .coding_chat_forget, .coding_fixes_toggle, input, button, textarea',
		start: function () {
			// the panel starts anchored right/bottom; give the drag left/top to
			// move, from where it currently sits, so nothing jumps
			var p = $(this);
			var pos = p.position();
			p.css({ right: 'auto', bottom: 'auto', left: pos.left + 'px', top: pos.top + 'px' });
		},
		drag: function (e, ui) {
			// the panel floats over the whole screen, so the screen is what it is
			// kept on - and clear of the taskbar wherever that sits (the same rule
			// the Guide associate's window follows)
			var p = $(this);
			var w = p.outerWidth(), h = p.outerHeight();
			var bar = (typeof jawnosTaskbarHeight === 'function') ? jawnosTaskbarHeight() : 0;
			ui.position.left = Math.max(0, Math.min(ui.position.left, $(window).width() - w));
			ui.position.top = Math.max(panelTopLimit(), Math.min(ui.position.top, $(window).height() - h - bar));
		},
		stop: function () {
			var p = $(this);
			// the clothesline holds the top back on every device
			var top = parseFloat(p.css('top'));
			if (!isNaN(top) && top < panelTopLimit()) { p.css({ 'top': panelTopLimit() + 'px' }); }
			jawnosPanelPosSave('coding:' + (p.attr('conversation') || p.attr('mount')), p);
		}
	});
}

// A panel belongs to its app's window but lives over the whole screen: on the way
// in it is lifted out of the window to the body and positioned against the
// viewport, so it can be dragged anywhere and never clips at the window's edge.
// source_window remembers where it came from - the observer takes the panel away
// when that window is closed.
function codingChatFloat(panel) {
	if (panel.attr('screen_floating')) { return; }
	panel.attr('screen_floating', '1');
	var source = panel.closest('.wind');
	if (source.length && source.attr('id')) { panel.attr('source_window', source.attr('id')); }
	panel.detach().appendTo(document.body);
	panel.css({ position: 'fixed' });
}

function codingChatReap() {
	$('.coding_chat[source_window]').each(function () {
		var id = $(this).attr('source_window');
		if (id && !$('#' + id).length) { $(this).remove(); }
	});
}

// Panels arrive with their app (the window content is fetched), so arm whatever
// is present now and whatever the observer sees appear - the same pattern the
// multiselect upgrade uses. drag_armed keeps it to once per panel.
function codingChatArmAll(root) {
	$(root || document).find('.coding_chat:not([drag_armed])').each(function () {
		var panel = $(this);
		panel.attr('drag_armed', '1');
		codingChatFloat(panel);
		jawnosPanelPosRestore('coding:' + (panel.attr('conversation') || panel.attr('mount')), panel);
		codingChatRestore(panel);
		codingChatReattach(panel);
		codingChatDraggable(panel);
	});
}

function codingChatSpawn(mount, wanted) {
	var src = mount ? codingChatPanel(mount) : $('.coding_chat').first();
	// Re-opening a named conversation must not make a second panel when one is
	// already there (two restore passes can race the terminal's first window).
	if (wanted) {
		var already = $('.coding_chat').filter(function () {
			return ($(this).attr('conversation') || $(this).attr('mount')) === wanted;
		});
		if (already.length) {
			already.first().css({ display: 'flex' });
			return already.first();
		}
	}
	if (!src || !src.length) { return $(); }
	var base = $.trim(src.attr('mount') || 'coding');
	var name = wanted || '';
	if (!name) {
		do {
			jawnos_coding_agents += 1;
			name = base + '_agent_' + jawnos_coding_agents;
		} while ($('#coding_chat_' + name).length);
	}
	var clone = src.clone();
	clone.attr('id', 'coding_chat_' + name).attr('mount', name).attr('conversation', name).attr('spawned', '1');
	clone.removeAttr('drag_armed');
	if (src.attr('source_window')) { clone.attr('source_window', src.attr('source_window')); }
	clone.removeClass('ui-draggable ui-draggable-disabled ui-draggable-handle ui-draggable-dragging');
	clone.find('.coding_chat_title').text($.trim(src.find('.coding_chat_title').text() || 'Coding agent') + (wanted ? '' : ' ' + jawnos_coding_agents));
	clone.find('.coding_chat_log, .coding_fixes_rows').empty();
	clone.find('.coding_fixes_count').text('0');
	clone.find('.coding_fixes_panel').css('display', 'none');
	clone.find('.coding_chat_log').css('display', '');
	clone.find('.coding_chat_composer').css('display', 'flex');
	clone.css({ display: 'flex', position: 'fixed', right: 'auto', bottom: 'auto', left: (24 + jawnos_coding_agents * 26) + 'px', top: (40 + jawnos_coding_agents * 26) + 'px' });
	$(document.body).append(clone);
	codingChatArmAll(document.body);
	if (typeof jawnosAgentOpenRemember === 'function') { jawnosAgentOpenRemember('coding:' + name); }
	clone.find('.coding_chat_input').focus();
	if (wanted) { codingChatHydrate(name); }
	else { codingChatAdd(name, 'step', 'A fresh agent — this one keeps its own thread.'); }
	return clone;
}

function codingChatTitleShow(panel) {
	var t = panel.data('title');
	if (t) { panel.find('.coding_chat_title').text(t); }
}

// Re-open a thread from the agents list: the remembered turns are fetched and
// replayed into the log (action rows and the tool's observations stay out of it).
function codingChatHydrate(mount) {
	var panel = codingChatPanel(mount);
	if (!panel.length) { return; }
	$.get('/manager/agents/thread', { kind: 'coding', name: mount }, function (r) {
		var transcript = (r && r.transcript) || [];
		if (r && r.title) { panel.data('title', r.title); codingChatTitleShow(panel); }
		var shown = 0;
		transcript.forEach(function (m) {
			var role = m.role || 'user';
			var content = String(m.content || '');
			if (role === 'user') { codingChatAdd(mount, 'user', content); shown++; }
			else if (role === 'assistant' && !/^\s*\{/.test(content) && content !== 'done') { codingChatAdd(mount, 'guide', content); shown++; }
		});
		if (!shown) { codingChatAdd(mount, 'step', 'Nothing has been asked here yet.'); }
	});
}

// Open the conversation `name`: a panel already wearing it comes forward; else
// one is made - a clone of any open coding panel, or (with none on screen) the
// terminal is opened first, since that is where a coding panel lives.
function codingChatOpenConversation(name) {
	var existing = $('.coding_chat').filter(function () { return ($(this).attr('conversation') || $(this).attr('mount')) === name; });
	if (existing.length) {
		var panel = existing.first();
		jawnos_coding_top += 1;
		panel.css({ display: 'flex', 'z-index': jawnos_coding_top });
		panel.find('.coding_chat_input').focus();
		return panel;
	}
	if ($('.coding_chat').length) { return codingChatSpawn(null, name); }
	if (typeof appWindowOpener === 'function') {
		appWindowOpener('terminal', Date.now(), { visible: 'yes' });
		var tries = 0;
		var timer = setInterval(function () {
			tries += 1;
			if ($('.coding_chat').length) { clearInterval(timer); codingChatSpawn(null, name); }
			else if (tries > 40) { clearInterval(timer); }
		}, 250);
	}
	return null;
}

$(document).on('click', '.coding_chat_new', function () {
	codingChatSpawn($(this).closest('.coding_chat').attr('mount'));
});
$(document).on('mousedown', '.coding_chat', function () {
	// clicked or grabbed, the panel comes forward - several agents, one stack
	jawnos_coding_top += 1;
	$(this).css('z-index', jawnos_coding_top);
});

$(document).ready(function () { codingChatArmAll(document); });
new MutationObserver(function () { codingChatReap(); codingChatArmAll(document); }).observe(document.documentElement, { childList: true, subtree: true });

// ---- the run while it is happening ------------------------------------------
// coding.js is the split's index and keeps its first segment, so the live part
// of a run is layered on here: this file loads after the index, and the two
// renderers are replaced by assignment (a second `function` declaration would be
// dead code, and t/63-js-parts.t rejects one). A step's reasoning folds open on
// its own toggle, and the run's current state sits at the foot of the log until
// the run settles.

// One step's reasoning: a small toggle and the block it opens. A step with no
// reasoning draws nothing, and the text is always set with .text(), never .html().
function codingChatThoughtShow(mount, reasoning) {
	var why = (typeof reasoning === 'string') ? $.trim(reasoning) : '';
	if (!why) { return; }
	var log = codingChatPanel(mount).find('.coding_chat_log');
	if (!log.length) { return; }
	log.append($('<span class="coding_chat_thought_toggle" style="cursor:pointer;font-size:11px;opacity:.55;margin-left:6px;"></span>').text(codingT('thinking')));
	log.append($('<div class="coding_chat_thought" style="white-space:pre-wrap;overflow-wrap:break-word;font-size:12px;opacity:.75;max-height:220px;overflow:auto;border-left:2px solid var(--line);padding:2px 6px;margin:3px 0 6px;display:none;"></div>').text(why));
}

$(document).on('click', '.coding_chat_thought_toggle', function () {
	$(this).next('.coding_chat_thought').toggle();
});

// The index's step renderer, with the reasoning drawn underneath each step.
codingChatStepsShow = function (mount, steps) {
	(steps || []).forEach(function (s) {
		var a = s.action || {};
		var obs = String(s.observation == null ? '' : s.observation).replace(/\s+\n/g, '\n').replace(/\n+/g, ' · ');
		if (obs.length > 240) { obs = obs.slice(0, 240) + '…'; }
		codingChatAdd(mount, 'step', codingChatLine(a) + (obs ? (' → ' + obs) : ''));
		codingChatThoughtShow(mount, s.reasoning);
	});
};

// The live line at the foot of the log: what the run is doing now. Created once,
// updated in place, moved back to the end whenever a step is appended, and taken
// away the moment the snapshot carries no current state.
function codingChatNow(mount, current) {
	var panel = codingChatPanel(mount);
	if (!panel.length) { return; }
	var log = panel.find('.coding_chat_log');
	if (!log.length) { return; }
	var c = (current && typeof current === 'object') ? current : {};
	var state = c.state || '';
	var text = '';
	if (state === 'thinking') { text = codingT('Thinking…'); }
	else if (state === 'acting') { text = codingT('Running {0}…', codingChatLine(c.action || {})); }
	var line = log.find('.coding_chat_now').first();
	if (!text) { line.remove(); return; }
	var node = log[0];
	var scroll = false;
	if (!line.length) {
		line = $('<div class="coding_chat_now" style="text-align:center;font-size:12px;opacity:.6;font-style:italic;margin:4px 0;"></div>');
		line.text(text);
		log.append(line);
		scroll = true;
	}
	else {
		if (line.text() !== text) { line.text(text); }
		// a step appended below it leaves the live line above: bring it back down
		if (line.next().length) { log.append(line); }
		if (node) { scroll = (node.scrollHeight - node.scrollTop - node.clientHeight) < 60; }
	}
	if (scroll && node) { node.scrollTop = node.scrollHeight; }
}

// The index draws a snapshot's steps; read the same snapshot's live state after
// it, and let a settled run (or a panel a newer run has taken) keep no line.
var codingChatPollApplyCore = codingChatPollApply;
codingChatPollApply = function (mount, run, r) {
	var again = codingChatPollApplyCore(mount, run, r);
	var panel = codingChatPanel(mount);
	if (!panel.length) { return again; }
	var owner = parseInt(panel.data('coding_run'), 10) || 0;
	if (owner && run && owner !== run) { return again; }
	codingChatNow(mount, again ? (r && r.current) : null);
	return again;
};

// The poll itself, at one second instead of the index's 1.5, with the first look
// immediate: that first look is also what puts the live line up on a reloaded
// panel, because codingChatReattach starts this poll.
codingChatPoll = function (mount, run) {
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
				if (again) { now.data('coding_poll_timer', setTimeout(tick, 1000)); }
				else { now.removeData('coding_poll_timer'); }
			},
			error: function () {
				var now = codingChatPanel(mount);
				if (!now.length) { return; }
				if (now.data('coding_run') && now.data('coding_run') !== run) { return; }
				codingChatAdd(mount, 'guide', 'The coding agent could not be reached.');
				now.data('coding_running', 0);
				codingChatRunning(now);
				codingChatNow(mount, null);
				now.removeData('coding_poll_timer');
			}
		});
	};
	panel.data('coding_poll_timer', setTimeout(tick, 0));
};
