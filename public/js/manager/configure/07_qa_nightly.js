// ---- QA nightly (Configure -> Plat -> QA) ----------------------------------
// The house runs its QA suite from one machine a night. The select names that
// machine; the card below asks the chosen machine whether it can actually run
// the suite (a checkout, perl and prove, a private namespace, and the artefact
// toolchain) and offers Install for whatever is missing. The install is run on
// the target through the app's existing peer-verified remote-command rail, and
// its progress is read back from the same readiness payload while it runs.
function qaT(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function qaTarget() {
	var pick = $('#qa_nightly_device');
	return pick.length ? (pick.val() || '') : '';
}

function qaRender(r) {
	var box = $('#qa_readiness');
	var status = $('#qa_install_status');
	if (!r || !r.ok) {
		box.text((r && r.error) ? r.error : qaT('No answer from that machine.'));
		$('#qa_install').hide();
		return;
	}
	var missing = r.missing || [];
	var lines = [];
	if (r.hostname) { lines.push(r.hostname); }
	if (r.ready) {
		lines.push(qaT('configure.qa_ready') + (missing.length ? ' — ' + qaT('configure.qa_missing') + ': ' + missing.join(', ') : ''));
	}
	else {
		lines.push(qaT('configure.qa_not_ready') + ' — ' + qaT('configure.qa_missing') + ': ' + (missing.join(', ') || '?'));
	}
	box.text(lines.join(' · '));
	// the button is offered only when there is something to install
	$('#qa_install').toggle(missing.length > 0);
	// the button's label is rendered by subs::lang in the template; put it back
	// after a run rather than replacing it with an untranslated JS string
	var label = $('#qa_install').data('label');
	if (!label) { label = $('#qa_install').text(); $('#qa_install').data('label', label); }
	$('#qa_install').text(label);
	var inst = r.install || {};
	if (inst.state === 'running') {
		var steps = inst.steps || [];
		status.text(qaT('Installing…') + ' ' + (inst.step || 0) + '/' + steps.length + (inst.log ? '\n' + inst.log : ''));
		qaPollSoon();
	}
	else if (inst.state === 'failed' || inst.state === 'done') {
		status.text((inst.log || '') + (inst.missing && inst.missing.length ? '\n' + qaT('configure.qa_missing') + ': ' + inst.missing.join(', ') : ''));
	}
	else if (inst.state === 'ready') {
		status.text('');
	}
}

function qaRefresh() {
	$.getJSON('/manager/configure/qa_device_ready', { target: qaTarget() })
		.done(qaRender)
		.fail(function() { qaRender({ ok: 0, error: qaT('No answer from that machine.') }); });
}

// ---- the nightly schedule (three times, the timer's own schedule, Run now) ---
// The fields hold the house setting; the line under each one is the OnCalendar
// the systemd timer really has, read from the chosen machine, so a field that
// has drifted from the unit is visible instead of silent.
var QA_RUN_LABELS = { suite: 'configure.qa_suite_time', ux: 'configure.qa_ux_time', coding: 'configure.qa_coding_time' };

function qaScheduleRender(r) {
	var anyRunning = false;
	if (!r || !r.ok) {
		$('#qa_schedule_status').text((r && r.error) ? r.error : qaT('No answer from that machine.'));
		return anyRunning;
	}
	(r.runs || []).forEach(function(run) {
		var field = $('#qa_' + run.key + '_time');
		// never overwrite what a person is typing
		if (field.length && document.activeElement !== field[0] && run.time) {
			field.val(run.time);
		}
		var effective = run.oncalendar
			? qaT('configure.qa_effective') + ' ' + run.oncalendar
			: qaT('Not installed');
		if (run.drift) { effective += ' — ' + qaT('the saved time and the timer disagree; save the time to retime it'); }
		$('#qa_' + run.key + '_effective').text(effective);
		var state = '';
		if (run.state === 'running') { state = qaT('Running…'); anyRunning = true; }
		else if (run.state === 'failed') { state = qaT('Failed'); }
		$('#qa_' + run.key + '_state').text(state);
	});
	return anyRunning;
}

function qaScheduleRefresh(done) {
	$.getJSON('/manager/configure/qa_schedule', { target: qaTarget() })
		.done(function(r) {
			var running = qaScheduleRender(r);
			if (typeof done === 'function') { done(running); }
		})
		.fail(function() { qaScheduleRender({ ok: 0, error: qaT('No answer from that machine.') }); });
}

// Poll while a run is going. A oneshot finishes on its own, so the poll stops
// as soon as nothing is running (or after about four minutes of asking).
var qaRunPoll = null;
var qaRunPolls = 0;
function qaRunPollStart() {
	if (qaRunPoll) { return; }
	qaRunPolls = 0;
	qaRunPoll = setInterval(function() {
		qaRunPolls++;
		qaScheduleRefresh(function(running) {
			if (!running || qaRunPolls > 60) { clearInterval(qaRunPoll); qaRunPoll = null; }
		});
	}, 4000);
}

function qaRetimeText(res) {
	var retime = (res && res.retime) ? res.retime : {};
	var rows = retime.rows || [];
	var parts = [];
	rows.forEach(function(row) {
		var label = qaT(QA_RUN_LABELS[row.key] || row.key);
		if (row.state === 'retimed') { parts.push(label + ': ' + qaT('retimed')); }
		else if (row.state === 'planned') { parts.push(label + ': ' + qaT('planned')); }
		else if (row.state === 'not-installed') { parts.push(label + ': ' + qaT('timer not installed there')); }
		else { parts.push(label + ': ' + (row.error || qaT('failed'))); }
	});
	if (!rows.length) {
		parts.push(retime.error || (res && res.retime_ok ? qaT('retimed') : qaT('Could not retime the timers.')));
	}
	return parts.join('\n');
}

var qaPollTimer = null;
function qaPollSoon() {
	if (qaPollTimer) { return; }
	qaPollTimer = setTimeout(function() {
		qaPollTimer = null;
		// one poll follows the install; the readiness payload stops it when the
		// target reports done or failed
		$.getJSON('/manager/configure/qa_device_ready', { target: qaTarget() }, qaRender)
			.fail(function() { qaPollTimer = null; });
	}, 3000);
}

$(document).on('change', '#qa_nightly_device', function() {
	var sig = $(this).val() || '';
	$('#qa_install_status').text('');
	$.post('/manager/configure/qa_device_target', { signatorial: sig }, function(res) {
		if (!res || !res.ok) {
			$('#qa_readiness').text((res && res.error) || qaT('That device cannot run the nightly.'));
			return;
		}
		qaRefresh();
	}).fail(function() {
		$('#qa_readiness').text(qaT('Could not save the choice.'));
	});
});

$(document).on('change', '#qa_note_limit', function() {
	var select = $(this);
	var box = $('#qa_note_limit_status');
	var n = parseInt(select.val(), 10);
	box.text('');
	// The server clamps 1..25 and answers with what it stored; put that back on
	// the select so the panel never shows a number the house did not keep.
	$.post('/manager/configure/qa_device_target', { field: 'note_limit', note_limit: n }, function(res) {
		if (!res || !res.ok) {
			box.text((res && res.error) || qaT('Could not save the number.'));
			return;
		}
		select.val(res.note_limit);
		box.text(qaT('Saved.'));
		setTimeout(function() { box.text(''); }, 2000);
	}).fail(function() {
		box.text(qaT('Could not save the number.'));
	});
});

$(document).on('click', '#qa_schedule_save', function() {
	var button = $(this);
	var status = $('#qa_schedule_status');
	button.prop('disabled', true);
	status.text(qaT('Saving…'));
	$.post('/manager/configure/qa_schedule_save', {
		signatorial: qaTarget(),
		suite_time: $('#qa_suite_time').val(),
		ux_time: $('#qa_ux_time').val(),
		coding_time: $('#qa_coding_time').val()
	}, function(res) {
		button.prop('disabled', false);
		if (!res || !res.ok) {
			// a refused save (bad time, ineligible device) says which, and changes
			// nothing - do not pretend it was kept
			status.text((res && res.error) || qaT('The times were not saved.'));
			return;
		}
		var lines = [ qaT('Saved.') ];
		lines.push(qaRetimeText(res));
		// the settings may be saved while the retime failed: say both, never one
		if (res.retime_ok === 0) { lines.push(qaT('The times are saved but the timers were not retimed.')); }
		status.text(lines.join('\n'));
		qaScheduleRefresh();
	}).fail(function() {
		button.prop('disabled', false);
		status.text(qaT('The times could not be saved.'));
	});
});

$(document).on('click', '.qa_run_now', function() {
	var button = $(this);
	var run = button.data('run');
	var status = $('#qa_schedule_status');
	button.prop('disabled', true);
	status.text(qaT('Starting…'));
	$.post('/manager/configure/qa_run', { signatorial: qaTarget(), run: run }, function(res) {
		button.prop('disabled', false);
		if (!res || !res.ok) {
			status.text((res && res.error) || qaT('The run was refused.'));
			qaScheduleRefresh();
			return;
		}
		status.text(qaT('Started.') + (res.state ? ' (' + res.state + ')' : ''));
		qaScheduleRefresh();
		qaRunPollStart();
	}).fail(function() {
		button.prop('disabled', false);
		status.text(qaT('The run could not be started.'));
	});
});

$(document).on('click', '#qa_refresh', function() {
	$('#qa_readiness').text(qaT('configure.qa_checking'));
	$('#qa_install_status').text('');
	qaRefresh();
});

$(document).on('click', '#qa_install', function() {
	var button = $(this);
	var label = button.data('label') || button.text();
	button.data('label', label);
	button.prop('disabled', true).text(qaT('Installing…'));
	$('#qa_install_status').text(qaT('Installing…'));
	$.post('/manager/configure/qa_device_install', { signatorial: qaTarget() }, function(res) {
		if (res && res.ok === 0) {
			$('#qa_install_status').text((res.error || qaT('The install was refused.')));
			button.prop('disabled', false).text(label);
			return;
		}
		// a dry-run or an already-ready machine answers at once; otherwise the
		// target is running the steps and the poll picks them up
		qaRefresh();
	}).fail(function() {
		$('#qa_install_status').text(qaT('The install could not be started.'));
		button.prop('disabled', false).text(label);
	});
});

// Opening the QA tab (or returning to a Plat window left on it) asks the
// chosen machine fresh, rather than showing a stale answer from the last visit.
$(document).on('click', '#plat_setting_list .cfg_tab_toggle[tab="plat_qa"]', function() {
	qaRefresh();
	qaScheduleRefresh();
});
$(function() {
	if ($('#plat_qa').length && $('#plat_qa').is(':visible')) { qaRefresh(); qaScheduleRefresh(); }
});
