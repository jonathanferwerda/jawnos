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
		log.append($('<div style="text-align:center;margin:5px 0;"><span style="font-size:12px;opacity:.6;font-style:italic;">' + safe + '</span></div>'));
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
		},
		error: function () { codingChatAdd(mount, 'guide', 'The coding agent could not be reached.'); }
	});
}

$(document).on('click', '.coding_chat_toggle', function () { codingChatToggle($(this).attr('mount')); });
$(document).on('click', '.coding_chat_close', function () { $(this).closest('.coding_chat').hide(); });
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
