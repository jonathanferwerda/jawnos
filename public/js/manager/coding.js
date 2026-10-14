// The Coding agent's chatbox, mounted by the apps that want it (the terminal and
// the IDE today). It is the same self-healing agent the Guide's Coding toggle
// drives: the words go to /manager/coding/heal, which reads and writes the repo,
// checks the change, and ships it. Each mount keeps its own conversation name, so
// the terminal and the editor remember their own threads.

function codingChatPanel(mount) { return $('#coding_chat_' + mount); }

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
			+ (mine ? 'background:#cdeccd;' : 'background:#cfe3f5;') + '">' + safe + '</span>';
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

function codingChatSend(mount) {
	var panel = codingChatPanel(mount);
	var input = panel.find('.coding_chat_input');
	var task = $.trim(input.val() || '');
	if (!task) { return; }
	input.val('');
	codingChatAdd(mount, 'user', task);
	codingChatAdd(mount, 'step', 'Coding — reading and changing the repo…');
	$.ajax({
		url: '/manager/coding/heal',
		type: 'POST',
		dataType: 'json',
		data: { task: task, conversation: panel.attr('conversation') || mount },
		success: function (r) {
			if (!r || r.error) { codingChatAdd(mount, 'guide', (r && r.error) || 'The coding agent failed.'); return; }
			(r.steps || []).forEach(function (s) {
				var a = s.action || {};
				var obs = String(s.observation == null ? '' : s.observation).replace(/\s+\n/g, '\n').replace(/\n+/g, ' · ');
				if (obs.length > 240) { obs = obs.slice(0, 240) + '…'; }
				codingChatAdd(mount, 'step', codingChatLine(a) + (obs ? (' → ' + obs) : ''));
			});
			if (r.final) { codingChatAdd(mount, 'guide', r.final); }
			else { codingChatAdd(mount, 'guide', 'Done — now at version ' + (r.version || '?') + '.'); }
			if (r.title) { var tpanel = codingChatPanel(mount); tpanel.data('title', r.title); if (tpanel.attr('spawned')) { codingChatTitleShow(tpanel); } }
			codingFixesFetch(mount);
		},
		error: function () { codingChatAdd(mount, 'guide', 'The coding agent could not be reached.'); }
	});
}

$(document).on('click', '.coding_chat_toggle', function () { codingChatToggle($(this).attr('mount')); });
$(document).on('click', '.coding_chat_close', function () {
	var panel = $(this).closest('.coding_chat');
	// a spawned agent was made on a whim: closing it takes it away, while a
	// mounted one stays put for its toolbar button to bring back
	if (panel.attr('spawned')) { panel.remove(); }
	else { panel.hide(); }
});
$(document).on('click', '.coding_chat_send', function () { codingChatSend($(this).closest('.coding_chat').attr('mount')); });
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

// ---- the error watch's staging area -----------------------------------------
// The fixes button swaps the chat for what the error watch has caught: each row
// is an error seen in the tree's own log, with the fix the Coding agent staged
// for it. Apply writes that proposal, checks it compiles, and gives it the same
// finishing routine the chat gives a change (bump, commit, push); the restart
// link is the word that puts it live. Nothing is written before Apply.

function codingFixesPanel(mount) { return codingChatPanel(mount).find('.coding_fixes_panel'); }

function codingFixesShow(mount, show) {
	var panel = codingChatPanel(mount);
	panel.find('.coding_fixes_panel').css('display', show ? 'flex' : 'none');
	panel.find('.coding_chat_log').css('display', show ? 'none' : '');
	panel.find('.coding_chat_composer').css('display', show ? 'none' : 'flex');
	if (show) { codingFixesFetch(mount); }
}

function codingFixesState(f) {
	if (f.status === 'proposed') { return 'fix staged — press Apply'; }
	if (f.status === 'failed') { return 'no fix proposed'; }
	return 'waiting for the agent';
}

function codingFixesRender(mount, data) {
	var rows = codingFixesPanel(mount).find('.coding_fixes_rows').empty();
	var fixes = (data && data.fixes) || [];
	codingChatPanel(mount).find('.coding_fixes_count').text(fixes.length);
	if (!fixes.length) {
		rows.append($('<div style="opacity:.6;"></div>').text(data && data.watching
			? 'Nothing caught yet — errors in the tree\'s log show up here.'
			: 'The error watch is off (Configure → Plat → Watch errors).'));
		return;
	}
	fixes.forEach(function (f) {
		var row = $('<div style="border:1px solid var(--line);border-radius:8px;padding:6px 8px;margin:0 0 8px;"></div>');
		row.append($('<div style="display:flex;gap:6px;align-items:baseline;"></div>')
			.append($('<b style="flex:1;overflow-wrap:break-word;"></b>').text(f.signature || '(error)'))
			.append($('<span style="white-space:nowrap;opacity:.6;"></span>').text(codingFixesState(f))));
		row.append($('<div style="opacity:.55;margin:2px 0 4px;"></div>').text(
			(f.source === 'js' ? 'browser' : (f.source || '?') + ' log') + ' · seen ' + (f.tally || 1) + '×' + (f.model ? ' · ' + f.model : '')));
		if (f.sample) {
			row.append($('<div class="chat_sample" style="font-family:monospace;background:rgba(0,0,0,.05);border-radius:5px;padding:4px 6px;margin:0 0 4px;max-height:90px;overflow:auto;white-space:pre-wrap;overflow-wrap:break-word;"></div>').text(String(f.sample).slice(0, 600)));
		}
		if (f.summary) {
			row.append($('<div style="margin:0 0 4px;"></div>').text('→ ' + String(f.summary).slice(0, 600)));
		}
		if (f.files && f.files.length) {
			row.append($('<div style="opacity:.7;margin:0 0 4px;overflow-wrap:break-word;"></div>').text('files: ' + f.files.map(function (x) { return x.path; }).join(', ')));
		}
		var result = $('<div style="margin:2px 0 0;"></div>');
		row.append(result);
		if (f.status === 'failed' || f.status === 'new') {
			var retry = $('<button class="button" style="padding:4px 10px;border-radius:7px;border:2px solid var(--line);cursor:pointer;margin-right:6px;">Retry</button>');
			retry.on('click', function () {
				result.text('back in the queue — the agent picks it up on a later pass');
				$.post('/manager/coding/fixes_retry', { uuid: f.uuid }, function () { setTimeout(function () { codingFixesFetch(mount); }, 1200); });
			});
			row.append(retry);
		}
		if (f.status === 'proposed') {
			var apply = $('<button class="button" style="padding:4px 10px;border-radius:7px;border:2px solid var(--line);cursor:pointer;font-weight:bold;margin-right:6px;">Apply</button>');
			apply.on('click', function () { codingFixesApply(mount, f, row, result); });
			row.append(apply);
		}
		var forget = $('<button class="button" style="padding:4px 10px;border-radius:7px;border:2px solid var(--line);cursor:pointer;">Forget</button>');
		forget.on('click', function () {
			$.post('/manager/coding/fixes_discard', { uuid: f.uuid }, function () { row.remove(); codingFixesFetch(mount); });
		});
		row.append(forget);
		rows.append(row);
	});
}

function codingFixesFetch(mount) {
	$.ajax({
		url: '/manager/coding/fixes',
		type: 'GET',
		dataType: 'json',
		cache: false,
		success: function (data) {
			codingChatPanel(mount).find('.coding_fixes_count').text((data && data.fixes ? data.fixes.length : 0));
			if (codingFixesPanel(mount).is(':visible')) { codingFixesRender(mount, data); }
		}
	});
}

function codingFixesApply(mount, f, row, result) {
	result.text('applying — writing, checking, committing…');
	$.ajax({
		url: '/manager/coding/fixes_apply',
		type: 'POST',
		dataType: 'json',
		data: { uuid: f.uuid },
		success: function (r) {
			if (!r || r.error) {
				result.text((r && r.error) || 'apply failed');
				if (r && r.checks) {
					result.append($('<div style="font-family:monospace;font-size:11px;white-space:pre-wrap;"></div>').text(r.checks.map(function (c) { return c.path + ': ' + c.output; }).join('\n').slice(0, 800)));
				}
				return;
			}
			row.find('button').remove();
			result.text('applied as v' + (r.version || '?') + ' — committed and pushed; press restart to go live.');
		},
		error: function () { result.text('apply could not be reached'); }
	});
}

$(document).on('click', '.coding_fixes_toggle', function () {
	codingFixesShow($(this).closest('.coding_chat').attr('mount'), true);
});
$(document).on('click', '.coding_fixes_back', function () {
	codingFixesShow($(this).closest('.coding_chat').attr('mount'), false);
});
$(document).on('click', '.coding_fixes_clear', function () {
	var mount = $(this).closest('.coding_chat').attr('mount');
	$.post('/manager/coding/fixes_clear', {}, function () { codingFixesFetch(mount); });
});
$(document).on('click', '.coding_fixes_restart', function () {
	var el = $(this);
	el.text('restarting…');
	$.post('/manager/coding/restart', {}, function () { el.text('restart asked'); });
});

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
		cancel: '.coding_chat_new, .coding_chat_close, .coding_chat_forget, .coding_fixes_toggle, input, button, textarea',
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
			var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
			ui.position.left = Math.max(0, Math.min(ui.position.left, $(window).width() - w));
			ui.position.top = Math.max(0, Math.min(ui.position.top, $(window).height() - h - bar));
		},
		stop: function () {
			var p = $(this);
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
		codingChatDraggable(panel);
	});
}

function codingChatSpawn(mount, wanted) {
	var src = mount ? codingChatPanel(mount) : $('.coding_chat').first();
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

// ---- a reload must not cost the conversation -----------------------------------
// A script change is the one update that cannot land in place, so for it the tab
// reloads (websocket.js asks first). The chat is saved the moment the page goes -
// beforeunload covers every reload, ours or a press of F5 - and put back when the
// panel is built again.

function jawnosCodingChatSave() {
	try {
		var state = {};
		$('.coding_chat').each(function () {
			var panel = $(this);
			var log = panel.find('.coding_chat_log');
			if (!log.length) { return; }
			state[panel.attr('mount')] = {
				log: log.html() || '',
				scroll: log[0] ? log[0].scrollTop : 0,
				draft: panel.find('.coding_chat_input').val() || ''
			};
		});
		sessionStorage.setItem('jawnos_coding_chat_state', JSON.stringify(state));
	} catch (e) { /* losing this is a nicety missed, never an error worth showing */ }
}

function codingChatRestore(panel) {
	if (panel.attr('spawned') || panel.find('.coding_chat_log').html()) { return; }
	var state = null;
	try { state = JSON.parse(sessionStorage.getItem('jawnos_coding_chat_state') || 'null'); } catch (e) { state = null; }
	var mine = state ? state[panel.attr('mount')] : null;
	if (!mine) { return; }
	var log = panel.find('.coding_chat_log');
	if (log.length && mine.log) { log.html(mine.log); }
	var input = panel.find('.coding_chat_input');
	if (input.length && !input.val() && mine.draft) { input.val(mine.draft); }
}

function codingChatRestoreScroll(mount) {
	var state = null;
	try { state = JSON.parse(sessionStorage.getItem('jawnos_coding_chat_state') || 'null'); } catch (e) { state = null; }
	var mine = state ? state[mount] : null;
	if (!mine) { return; }
	var log = codingChatPanel(mount).find('.coding_chat_log');
	if (log.length && log[0] && mine.scroll) { log[0].scrollTop = mine.scroll; }
}

window.addEventListener('beforeunload', function () { jawnosCodingChatSave(); });

// ---- the fixed list, read from Configure -> Plat -------------------------------
// Every error the Coding agent has fixed and shipped, newest first: what it was,
// where it came from, what the fix says, and the version it went out as.

function codingFixedWhen(f) {
	var ms = parseInt(f && f.applied, 10);
	if (!ms || isNaN(ms)) { ms = parseInt(f && f.created, 10); }
	if (!ms || isNaN(ms)) { return ''; }
	var d = new Date(ms);
	return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function codingFixedRender(rows) {
	var box = $('#coding_fixed_list');
	box.empty();
	if (!rows.length) {
		box.append($('<div style="opacity:.6;padding:2px 0;"></div>').text('Nothing yet — a fix lands here once the agent has applied it and the finishing routine (bump, commit, push) has run.'));
		return;
	}
	rows.forEach(function (f) {
		var row = $('<div style="border:1px solid var(--line);border-radius:8px;padding:6px 8px;margin:0 0 8px;"></div>');
		row.append($('<div style="font-weight:bold;overflow-wrap:break-word;"></div>').text(f.signature || '(error)'));
		var bits = [ (f.source === 'js' ? 'browser' : (f.source || '?') + ' log'), 'seen ' + (f.seen || 1) + '×' ];
		if (f.model) { bits.push(f.model); }
		if (f.version) { bits.push('v' + f.version); }
		if (codingFixedWhen(f)) { bits.push(codingFixedWhen(f)); }
		row.append($('<div style="opacity:.55;margin:2px 0 4px;"></div>').text(bits.join(' · ')));
		var story = f.summary || f.sample;
		if (story) { row.append($('<div style="margin:0 0 4px;overflow-wrap:break-word;"></div>').text(String(story).slice(0, 500))); }
		if (f.files && f.files.length) {
			row.append($('<div style="opacity:.7;overflow-wrap:break-word;"></div>').text('files: ' + f.files.join(', ')));
		}
		box.append(row);
	});
}

$(document).on('click', '#coding_fixed_open', function () {
	var box = $('#coding_fixed_list');
	if (box.is(':visible')) { box.hide(); return; }
	box.text('…').show();
	$.get('/manager/coding/fixes_fixed', function (r) { codingFixedRender((r && r.fixed) || []); }).fail(function () { box.text('could not read the fixed list.'); });
});
