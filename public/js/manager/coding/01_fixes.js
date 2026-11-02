
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
