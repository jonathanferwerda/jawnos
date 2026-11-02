
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
