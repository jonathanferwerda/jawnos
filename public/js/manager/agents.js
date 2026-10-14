// ---- the agents list ----------------------------------------------------------
// Every conversation the Coding agent and the Guide's associate have had, in one
// floating list. Open it by double-pressing the Assistant button - the taskbar
// pin, the start menu's copy, or a panel's own corner icon. A row whose panel is
// on screen is active: press it and the panel comes forward. The rest are
// history: press a row and its thread is re-opened with what was said replayed.
// A history row deletes the way this program deletes - the first press arms it
// red for two seconds, and a second press inside that window throws it away.

function jawnosAgentsPanel() {
	var panel = $('#jawnos_agents');
	if (panel.length) { return panel; }
	panel = $('<div id="jawnos_agents" style="position:fixed;left:40px;top:60px;width:340px;max-height:72%;display:none;flex-direction:column;background:var(--panel);border:2px solid var(--line);border-radius:10px;box-shadow:0 10px 30px rgba(0,0,0,.4);overflow:hidden;z-index:995000;">'
		+ '<div class="jawnos_agents_header" hint="Drag here to move the list" style="display:flex;align-items:center;gap:6px;padding:7px 10px;border-bottom:1px solid var(--line);cursor:move;">'
		+ '<span style="flex:1;font-weight:bold;font-size:13px;opacity:.85;">Agents</span>'
		+ '<span class="jawnos_agents_new_guide hover" hint="A new Guide associate, with its own thread" style="cursor:pointer;font-size:12px;opacity:.7;padding:0 3px;">+ guide</span>'
		+ '<span class="jawnos_agents_new_coding hover" hint="A new Coding agent, with its own thread" style="cursor:pointer;font-size:12px;opacity:.7;padding:0 3px;">+ coding</span>'
		+ '<span class="jawnos_agents_close hover" hint="Close" style="cursor:pointer;font-size:14px;opacity:.7;padding:0 4px;">✕</span>'
		+ '</div>'
		+ '<div class="jawnos_agents_rows" style="flex:1;overflow-y:auto;padding:8px 10px;font-size:13px;line-height:1.35;"></div>'
		+ '</div>');
	$(document.body).append(panel);
	panel.draggable({
		revert: 'false',
		handle: '.jawnos_agents_header',
		cancel: '.jawnos_agents_close, .jawnos_agents_new_guide, .jawnos_agents_new_coding, input, button',
		drag: function (e, ui) {
			var w = $(this).outerWidth(), h = $(this).outerHeight();
			var bar = (typeof jawnosTaskbarHeight == 'function') ? jawnosTaskbarHeight() : 0;
			ui.position.left = Math.max(0, Math.min(ui.position.left, $(window).width() - w));
			ui.position.top = Math.max(0, Math.min(ui.position.top, $(window).height() - h - bar));
		}
	});
	return panel;
}

function jawnosAgentsOpen() {
	var panel = jawnosAgentsPanel().css('display', 'flex');
	jawnosAgentsLoad(panel);
}

// Which conversations have a panel on screen right now (a hidden panel counts -
// pressing its row brings it back rather than making another).
function jawnosAgentsOpenPanels() {
	var open = {};
	$('.assistant_view').each(function () {
		var c = $(this).attr('conversation');
		if (c) { open['guide:' + c] = 1; }
	});
	$('.coding_chat').each(function () {
		var c = $(this).attr('conversation') || $(this).attr('mount');
		if (c) { open['coding:' + c] = 1; }
	});
	return open;
}

function jawnosAgentsLoad(panel) {
	var rows = panel.find('.jawnos_agents_rows');
	rows.text('…');
	$.get('/manager/agents/list', function (r) {
		jawnosAgentsRender(panel, (r && r.agents) || []);
	}).fail(function () { rows.text('could not read the agents list.'); });
}

function jawnosAgentsRender(panel, agents) {
	var rows = panel.find('.jawnos_agents_rows').empty();
	var open = jawnosAgentsOpenPanels();
	if (!agents.length) {
		rows.append($('<div style="opacity:.6;"></div>').text('No conversations yet — ask the Guide\'s associate something, or hand the Coding agent a task.'));
		return;
	}
	// active first, then newest first
	agents.sort(function (a, b) {
		var ao = open['' + a.kind + ':' + a.name] ? 1 : 0;
		var bo = open['' + b.kind + ':' + b.name] ? 1 : 0;
		if (ao !== bo) { return bo - ao; }
		return (b.updated || 0) - (a.updated || 0);
	});
	agents.forEach(function (a) {
		var key = '' + a.kind + ':' + a.name;
		var is_open = !!open[key];
		var row = $('<div class="jawnos_agents_row" style="border:1px solid var(--line);border-radius:8px;padding:6px 8px;margin:0 0 8px;cursor:pointer;"></div>')
			.attr('kind', a.kind).attr('agent_name', a.name);
		row.append($('<div style="display:flex;gap:6px;align-items:baseline;"></div>')
			.append($('<b style="flex:1;overflow-wrap:break-word;"></b>').text(a.title || a.name || '(untitled)'))
			.append($('<span style="white-space:nowrap;opacity:.55;"></span>').text(is_open ? 'open' : 'history')));
		var when = '';
		if (a.updated && typeof moment === 'function') { when = moment(parseInt(a.updated, 10)).fromNow(); }
		row.append($('<div style="opacity:.55;margin:2px 0 3px;"></div>').text(
			(a.kind === 'coding' ? 'coding agent' : 'guide associate') + (a.turns ? ' · ' + a.turns + ' turns' : '') + (when ? ' · ' + when : '')));
		if (a.preview) {
			row.append($('<div style="opacity:.75;overflow-wrap:break-word;"></div>').text(String(a.preview).slice(0, 140)));
		}
		var actions = $('<div style="margin:4px 0 0;"></div>');
		row.append(actions);
		if (is_open) {
			var raise = $('<span class="hover" hint="Bring this agent forward" style="font-size:12px;opacity:.8;text-decoration:underline;">bring forward</span>');
			raise.on('click', function (e) { e.stopPropagation(); jawnosAgentsShow(key); });
			actions.append(raise);
		}
		else {
			var reopen = $('<span class="hover" hint="Re-open this conversation, with what was said" style="font-size:12px;opacity:.8;text-decoration:underline;margin-right:10px;">re-open</span>');
			reopen.on('click', function (e) { e.stopPropagation(); jawnosAgentsShow(key); });
			actions.append(reopen);
			var del = $('<span class="jawnos_agents_delete hover" hint="Throw this history away (press twice)" style="font-size:12px;opacity:.8;color:#c33;cursor:pointer;">delete</span>');
			del.on('click', function (e) {
				e.stopPropagation();
				if (del.attr('armed') === 'yes') {
					$.post('/manager/agents/delete', { kind: a.kind, name: a.name }, function () { jawnosAgentsLoad(panel); });
					return;
				}
				del.attr('armed', 'yes');
				del.css({ 'background-color': 'red', 'color': '#fff', 'padding': '0 4px', 'border-radius': '4px' });
				setTimeout(function () { del.css({ 'background-color': '', 'color': '#c33', 'padding': '', 'border-radius': '' }); del.attr('armed', 'no'); }, 2000);
			});
			actions.append(del);
		}
		row.on('click', function () { jawnosAgentsShow(key); });
		rows.append(row);
	});
}

// Press a row: a panel that is open comes forward; a history row's panel is
// found or made, and its thread fetched and replayed.
function jawnosAgentsShow(key) {
	var bits = key.split(':');
	var kind = bits.shift();
	var name = bits.join(':');
	if (kind === 'guide') { assistantOpenConversation(name); return; }
	if (kind === 'coding' && typeof codingChatOpenConversation === 'function') { codingChatOpenConversation(name); }
}

$(document).on('click', '.jawnos_agents_close', function () { jawnosAgentsPanel().hide(); });
$(document).on('click', '.jawnos_agents_new_guide', function () { assistantSpawn($('.assistant_view').first()); });
$(document).on('click', '.jawnos_agents_new_coding', function () {
	if (typeof codingChatSpawn === 'function') { codingChatSpawn(null, null); }
});
// double-pressing the Assistant button opens the list (a single press still
// opens the associate itself - the list lands over it)
$(document).on('dblclick', '#assistant, .taskbar_pin[sel$="#assistant"], .assistant_anchor', function (e) {
	if (typeof jawnos_assistant_dragging !== 'undefined' && jawnos_assistant_dragging) { return; }
	e.preventDefault();
	jawnosAgentsOpen();
});
