
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

// A one-line excerpt of an observation: whitespace folded, newlines turned into
// separators, and cut to a readable length. A step and a subagent's child steps
// read at the same size, so both use it.
function codingChatBrief(text, limit) {
	var out = String(text == null ? '' : text).replace(/\s+\n/g, '\n').replace(/\n+/g, ' · ');
	var max = limit || 240;
	if (out.length > max) { out = out.slice(0, max) + '…'; }
	return out;
}

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

// A delegated step: what the agent handed to a subagent and what came back. The
// line stays a small toggle so the chat still reads as one column; opening it
// shows the child steps and the final answer (or the error). Every piece of
// content is set with .text().
function codingChatSubagentShow(mount, sub) {
	var log = codingChatPanel(mount).find('.coding_chat_log');
	if (!log.length || !sub || typeof sub !== 'object') { return; }
	var task = $.trim(String(sub.task == null ? '' : sub.task));
	if (task.length > 60) { task = task.slice(0, 60) + '…'; }
	var toggle = $('<span class="coding_chat_subagent_toggle" style="cursor:pointer;font-size:11px;opacity:.6;margin-left:6px;"></span>')
		.text(codingT('subagent') + ': ' + task);
	var box = $('<div class="coding_chat_subagent" style="display:none;overflow-wrap:break-word;font-size:12px;opacity:.8;max-height:220px;overflow:auto;border-left:2px solid var(--line);padding:2px 6px;margin:3px 0 6px;"></div>');
	var children = Array.isArray(sub.steps) ? sub.steps : [];
	children.forEach(function (child) {
		var a = (child && child.action) || {};
		var obs = codingChatBrief(child && child.observation);
		box.append($('<div style="margin:1px 0;"></div>').text(codingChatLine(a) + (obs ? (' → ' + obs) : '')));
	});
	var end = String(sub.error || sub.final || '');
	if (end) {
		box.append($('<div style="margin:3px 0 0;opacity:.75;font-style:italic;"></div>').text(end));
	}
	log.append(toggle).append(box);
}

$(document).on('click', '.coding_chat_subagent_toggle', function () {
	$(this).next('.coding_chat_subagent').toggle();
});

// The index's step renderer, with the reasoning (and any delegated work) drawn
// underneath each step.
codingChatStepsShow = function (mount, steps) {
	(steps || []).forEach(function (s) {
		var a = s.action || {};
		var obs = codingChatBrief(s.observation);
		codingChatAdd(mount, 'step', codingChatLine(a) + (obs ? (' → ' + obs) : ''));
		codingChatThoughtShow(mount, s.reasoning);
		if (s.subagent && typeof s.subagent === 'object') { codingChatSubagentShow(mount, s.subagent); }
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
	else if (state === 'subagents') {
		var total = parseInt(c.total, 10) || 0;
		var done = parseInt(c.done, 10) || 0;
		text = codingT('subagents_running') + (total ? ' ' + done + '/' + total : '');
	}
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

// The partial model output of the turn in flight: its reasoning, dim and
// pre-wrapped, above the raw partial answer in a monospace-ish block. Either
// half may be absent; with neither (or once the run has settled) the block comes
// away. It sits at the very foot of the log, below the Thinking/Running line.
function codingChatLive(mount, current) {
	var log = codingChatPanel(mount).find('.coding_chat_log');
	if (!log.length) { return; }
	var c = (current && typeof current === 'object') ? current : {};
	var why = (typeof c.live_reasoning === 'string') ? c.live_reasoning : '';
	var said = (typeof c.live_text === 'string') ? c.live_text : '';
	var block = log.find('.coding_chat_live').first();
	if (!why && !said) { block.remove(); return; }
	if (!block.length) {
		block = $('<div class="coding_chat_live" style="margin:4px 0 0;"></div>');
		block.append($('<div class="coding_chat_live_reasoning" style="white-space:pre-wrap;overflow-wrap:break-word;font-size:12px;opacity:.6;max-height:160px;overflow:auto;border-left:2px solid var(--line);padding:2px 6px;margin:0 0 3px;"></div>'));
		block.append($('<div class="coding_chat_live_text" style="white-space:pre-wrap;overflow-wrap:break-word;font-family:monospace;font-size:12px;max-height:120px;overflow:auto;background:rgba(0,0,0,.05);border-radius:5px;padding:3px 6px;"></div>'));
		log.append(block);
	}
	var whyEl = block.find('.coding_chat_live_reasoning').first();
	var saidEl = block.find('.coding_chat_live_text').first();
	if (whyEl.text() !== why) { whyEl.text(why); }
	if (saidEl.text() !== said) { saidEl.text(said); }
	whyEl.css('display', why ? '' : 'none');
	saidEl.css('display', said ? '' : 'none');
	// a step appended below it leaves the live block above: bring it back down
	if (block.next().length) { log.append(block); }
	var node = log[0];
	if (node && (node.scrollHeight - node.scrollTop - node.clientHeight) < 60) { node.scrollTop = node.scrollHeight; }
}

// The children a batch of subagents has already finished, under the live line: the
// task each was given and what it said back, so a run that spends a while
// delegating shows its work as it lands rather than only a count. One block per
// panel, its rows rebuilt when the list moves, and taken away the moment the batch
// is over (or no child has finished yet). The server has already trimmed both
// strings, so nothing here truncates them again.
function codingChatSubagents(mount, current) {
	var log = codingChatPanel(mount).find('.coding_chat_log');
	if (!log.length) { return; }
	var c = (current && typeof current === 'object') ? current : {};
	var kids = (c.state === 'subagents' && Array.isArray(c.children)) ? c.children : [];
	var block = log.find('.coding_chat_subagents').first();
	if (!kids.length) { block.remove(); return; }
	if (!block.length) {
		block = $('<div class="coding_chat_subagents" style="margin:4px 0 0;font-size:12px;opacity:.7;"></div>');
		log.append(block);
	}
	// a cheap signature: rebuild the handful of rows only when the list has moved
	var first = kids[0] || {};
	var last = kids[kids.length - 1] || {};
	var sig = kids.length + ':' + String(first.task == null ? '' : first.task) + ':'
		+ String(last.said == null ? '' : last.said) + ':' + String(last.ok == null ? '' : last.ok);
	if (block.data('coding_subagents_sig') !== sig) {
		block.data('coding_subagents_sig', sig);
		block.find('.coding_chat_subagent_row').remove();
		kids.forEach(function (child) {
			var kid = (child && typeof child === 'object') ? child : {};
			var row = $('<div class="coding_chat_subagent_row" style="overflow-wrap:break-word;margin:1px 0;"></div>');
			row.append($('<span class="coding_chat_subagent_task"></span>').text(String(kid.task == null ? '' : kid.task)));
			row.append($('<span class="coding_chat_subagent_arrow" style="opacity:.5;"></span>').text(' → '));
			// a child that failed says so in colour; the word itself is the server's
			row.append($('<span class="coding_chat_subagent_said"></span>')
				.text(String(kid.said == null ? '' : kid.said))
				.css('color', (kid.ok === 0 || kid.ok === '0') ? '#c33' : ''));
			block.append(row);
		});
	}
	// a step appended below it leaves the block above: bring it back down
	if (block.next().length) { log.append(block); }
	var node = log[0];
	if (node && (node.scrollHeight - node.scrollTop - node.clientHeight) < 60) { node.scrollTop = node.scrollHeight; }
}

// The index draws a snapshot's steps; read the same snapshot's live state after
// it, and let a settled run (or a panel a newer run has taken) keep no line.
var codingChatPollApplyCore = codingChatPollApply;
codingChatPollApply = function (mount, run, r) {
	var again = codingChatPollApplyCore(mount, run, r);
	var panel = codingChatPanel(mount);
	if (!panel.length) { return again; }
	var owner = parseInt(panel.data('coding_run'), 10) || 0;
	if (owner && run && owner !== run) {
		// a snapshot for a run the panel has left: keep a review the newer run
		// drew, drop the one that belonged to the old
		var stale = panel.find('.coding_chat_review');
		if (stale.length && (parseInt(stale.data('coding_review_run'), 10) || 0) !== owner) { stale.remove(); }
		return again;
	}
	var state = (r && r.state) || 'none';
	var current = again ? (r && r.current) : null;
	codingChatNow(mount, current);
	codingChatLive(mount, current);
	codingChatSubagents(mount, current);
	if (state === 'awaiting_approval') {
		// the run has stopped mid-flow and is waiting for a word: the review
		// stays up, and polling keeps going so an approve or a reject is seen
		// land without the panel needing any state of its own
		codingChatReviewShow(mount, run || owner, r);
		panel.data('coding_running', 1);
		codingChatRunning(panel);
		return true;
	}
	// the run moved on (or settled): the offer to commit is not this run's any more
	codingChatReviewClear(mount);
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
	// every explicit start begins a new chain, and a response already in flight
	// belongs to the chain it was sent under: without the stamp the push listener
	// starting a poll would leave the old one to arm a second chain beside it
	var gen = (parseInt(panel.data('coding_poll_gen'), 10) || 0) + 1;
	panel.data('coding_poll_gen', gen);
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
				// a newer chain owns the panel now: it has the timer, this one stops
				if ((parseInt(now.data('coding_poll_gen'), 10) || 0) !== gen) { return; }
				if (again) { now.data('coding_poll_timer', setTimeout(tick, 1000)); }
				else { now.removeData('coding_poll_timer'); }
			},
			error: function () {
				var now = codingChatPanel(mount);
				if (!now.length) { return; }
				if (now.data('coding_run') && now.data('coding_run') !== run) { return; }
				// a late failure from a replaced chain must not tear down the live one
				if ((parseInt(now.data('coding_poll_gen'), 10) || 0) !== gen) { return; }
				codingChatAdd(mount, 'guide', 'The coding agent could not be reached.');
				now.data('coding_running', 0);
				codingChatRunning(now);
				codingChatNow(mount, null);
				codingChatLive(mount, null);
				codingChatSubagents(mount, null);
				now.removeData('coding_poll_timer');
			}
		});
	};
	panel.data('coding_poll_timer', setTimeout(tick, 0));
};

// ---- a run waiting for a word about its commit --------------------------------
// Before the agent commits it stops and shows what it is about to write: the
// files and the diff, with a button either way. The block is one per panel and
// is drawn from the snapshot the poll already carries, so a reload rebuilds it
// from the same state and a run that moves on (or a newer one that owns the
// panel) takes it away.

function codingChatReviewClear(mount) {
	codingChatPanel(mount).find('.coding_chat_review').remove();
}

function codingChatReviewShow(mount, run, r) {
	var panel = codingChatPanel(mount);
	if (!panel.length) { return; }
	var log = panel.find('.coding_chat_log');
	if (!log.length) { return; }
	// a snapshot for an older run must not put its diff on a newer run's panel
	var mine = parseInt(panel.data('coding_run'), 10) || 0;
	var runId = parseInt(run, 10) || mine;
	if (mine && runId && mine !== runId) { return; }
	var pending = (r && r.pending_commit && typeof r.pending_commit === 'object') ? r.pending_commit : null;
	var block = log.find('.coding_chat_review').first();
	if (!pending) { block.remove(); return; }
	var diff = String(pending.diff == null ? '' : pending.diff);
	var files = Array.isArray(pending.files) ? pending.files : [];
	var names = files.map(function (f) { return String(f == null ? '' : f); }).join(' · ');
	if (!block.length) {
		block = $('<div class="coding_chat_review" style="margin:8px 0 0;border-top:1px solid var(--line);padding-top:6px;"></div>');
		block.append($('<div class="coding_chat_review_status" style="font-size:12px;font-weight:bold;margin:0 0 2px;"></div>'));
		block.append($('<div class="coding_chat_review_files" style="font-size:11px;opacity:.6;overflow-wrap:break-word;margin:0 0 4px;"></div>'));
		block.append($('<pre class="coding_chat_review_diff" style="max-height:240px;overflow:auto;white-space:pre-wrap;font-size:12px;background:rgba(0,0,0,.05);border-radius:5px;padding:4px 6px;margin:0 0 6px;"></pre>'));
		var row = $('<div style="display:flex;gap:6px;"></div>');
		row.append($('<button class="coding_chat_approve button" style="padding:4px 10px;border-radius:6px;border:2px solid var(--line);cursor:pointer;font-weight:bold;"></button>').text(codingT('approve')));
		row.append($('<button class="coding_chat_reject button" style="padding:4px 10px;border-radius:6px;border:2px solid var(--line);cursor:pointer;"></button>').text(codingT('reject')));
		block.append(row);
		log.append(block);
	}
	block.data('coding_review_run', runId || 0);
	// a second review in the same run is a new question: the old press would leave
	// both buttons dead under its word, so the review's own stamp starts it over
	var at = (pending.at == null) ? '' : String(pending.at);
	var was = block.data('coding_review_at');
	if (was !== undefined && was !== at) {
		block.removeData('coding_review_answer');
		block.find('.coding_chat_approve, .coding_chat_reject').prop('disabled', false).css('opacity', '');
		block.find('.coding_chat_review_status').first().text(codingT('review_before_commit'));
	}
	block.data('coding_review_at', at);
	// the file line also carries the word that the diff was cut, so a shortened
	// diff is not read as the whole of it
	var bits = [];
	if (names) { bits.push(names); }
	if (pending.truncated) { bits.push(codingT('diff_truncated')); }
	var filesText = bits.join(' · ');
	var filesEl = block.find('.coding_chat_review_files').first();
	if (filesEl.text() !== filesText) { filesEl.text(filesText); }
	var diffEl = block.find('.coding_chat_review_diff').first();
	if (diffEl.text() !== diff) { diffEl.text(diff); }
	// a press already answered keeps its word until the run moves on
	var status = block.find('.coding_chat_review_status').first();
	if (!block.data('coding_review_answer') && status.text() !== codingT('review_before_commit')) {
		status.text(codingT('review_before_commit'));
	}
	// a step appended below it leaves the offer above: bring it back down
	if (block.next().length) { log.append(block); }
	var node = log[0];
	if (node && (node.scrollHeight - node.scrollTop - node.clientHeight) < 60) { node.scrollTop = node.scrollHeight; }
}

// Both buttons go dead the moment one is pressed: the answer is on its way, and
// a second press would be a second verdict on the same commit.
function codingChatReviewAnswer(block, approved) {
	block.data('coding_review_answer', approved ? 'approved' : 'rejected');
	block.find('.coding_chat_approve, .coding_chat_reject').prop('disabled', true).css('opacity', '.55');
	block.find('.coding_chat_review_status').first()
		.text(codingT(approved ? 'approved_committing' : 'rejected_stopped'));
}

function codingChatReviewUndo(block, why) {
	block.removeData('coding_review_answer');
	block.find('.coding_chat_approve, .coding_chat_reject').prop('disabled', false).css('opacity', '');
	block.find('.coding_chat_review_status').first().text(why ? String(why) : codingT('review_before_commit'));
}

function codingChatReviewPost(button, url, approved) {
	var block = button.closest('.coding_chat_review');
	var panel = button.closest('.coding_chat');
	if (!block.length || !panel.length || block.data('coding_review_answer')) { return; }
	var run = parseInt(block.data('coding_review_run'), 10) || parseInt(panel.data('coding_run'), 10) || 0;
	if (!run) { return; }
	codingChatReviewAnswer(block, approved);
	$.ajax({
		url: url,
		type: 'POST',
		dataType: 'json',
		data: { id: run },
		success: function (r) {
			// ok:1 says the worker has it; an error puts the buttons back
			if (r && r.error) { codingChatReviewUndo(block, r.error); }
		},
		error: function () { codingChatReviewUndo(block); }
	});
}

$(document).on('click', '.coding_chat_approve', function () {
	codingChatReviewPost($(this), '/manager/coding/approve', true);
});
$(document).on('click', '.coding_chat_reject', function () {
	codingChatReviewPost($(this), '/manager/coding/reject', false);
});

// A new ask takes the panel back: what the last run was offering to commit is
// not this run's business. An empty send changes nothing. An offer still
// unanswered has to be told so first — the worker is asleep on that review and
// holds the single queue slot, so the new ask would wait behind it for minutes.
var codingChatSendCore = codingChatSend;
codingChatSend = function (mount) {
	var panel = codingChatPanel(mount);
	if ($.trim(panel.find('.coding_chat_input').val() || '')) {
		var block = panel.find('.coding_chat_review').first();
		if (block.length && !block.data('coding_review_answer')) {
			var run = parseInt(block.data('coding_review_run'), 10) || parseInt(panel.data('coding_run'), 10) || 0;
			// fire and forget: the send is the answer, so a failure needs no report
			if (run) {
				$.ajax({
					url: '/manager/coding/reject',
					type: 'POST',
					dataType: 'json',
					data: { id: run }
				});
			}
		}
		codingChatReviewClear(mount);
	}
	return codingChatSendCore(mount);
};

// The index's reattach picks a queued or active run back up; a run waiting for
// its commit is neither, so ask for that one state again and start the poll - the
// snapshot that comes back carries the review panel and its buttons.
var codingChatReattachCore = codingChatReattach;
codingChatReattach = function (panel) {
	if (panel && panel.length) {
		var mount = panel.attr('mount');
		var conv = panel.attr('conversation') || mount;
		if (mount && conv) {
			$.ajax({
				url: '/manager/coding/run',
				type: 'GET',
				dataType: 'json',
				cache: false,
				data: { conversation: conv },
				success: function (r) {
					var p = codingChatPanel(mount);
					if (!p.length || !r || r.state !== 'awaiting_approval') { return; }
					var run = parseInt(r.run, 10) || parseInt(p.data('coding_run'), 10) || 0;
					if (!run) { return; }
					p.data('coding_run', run);
					p.data('coding_running', 1);
					codingChatRunning(p);
					codingChatPoll(mount, run);
				}
			});
		}
	}
	return codingChatReattachCore(panel);
};

// The worker pushes a frame after every state change (a step, a live tick, the
// approval, the verdict). Restart the owning panel's poll at once instead of
// leaving it to its timer; a burst is debounced to one poll, because
// codingChatPoll already clears the timer it replaces.
function jawnosCodingRunPushed(id, conversation) {
	var run = parseInt(id, 10) || 0;
	if (!run) { return; }
	var conv = conversation ? String(conversation) : '';
	$('.coding_chat').each(function () {
		var panel = $(this);
		var mount = panel.attr('mount');
		if (!mount) { return; }
		var mine = parseInt(panel.data('coding_run'), 10) || 0;
		var named = panel.attr('conversation') || mount;
		var byRun = mine && mine === run;
		var byConv = conv && named === conv;
		if (!byRun && !byConv) { return; }
		// a panel with no run id is following nothing, and a settled run has no
		// poller to restart - polling it again would draw its final line twice
		if (!mine || !panel.data('coding_poll_timer')) { return; }
		if (mine !== run) {
			// the conversation has moved on to a newer run: follow it, rather than
			// poll an id the conversation no longer answers for
			if (!byConv) { return; }
			panel.data('coding_run', run);
		}
		var wait = panel.data('coding_push_timer');
		if (wait) { clearTimeout(wait); }
		panel.data('coding_push_timer', setTimeout(function () {
			var p = codingChatPanel(mount);
			if (!p.length) { return; }
			p.removeData('coding_push_timer');
			if ((parseInt(p.data('coding_run'), 10) || 0) !== run) { return; }
			if (!p.data('coding_poll_timer')) { return; }
			codingChatPoll(mount, run);
		}, 120));
	});
}
