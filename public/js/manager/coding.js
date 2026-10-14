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
	if (panel.is(':visible')) { codingFixesFetch(mount); }
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
			codingFixesFetch(mount);
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
			(f.source || '?') + ' log · seen ' + (f.tally || 1) + '×' + (f.model ? ' · ' + f.model : '')));
		if (f.sample) {
			row.append($('<div style="font-family:monospace;font-size:11px;background:rgba(0,0,0,.05);border-radius:5px;padding:4px 6px;margin:0 0 4px;max-height:90px;overflow:auto;white-space:pre-wrap;overflow-wrap:break-word;"></div>').text(String(f.sample).slice(0, 600)));
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
