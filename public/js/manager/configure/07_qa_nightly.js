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

// Off is a house-wide stop: the select, the schedule and Run now all stand
// down. Only the state change touches the buttons, so a run's own in-flight
// disable is not undone by a routine refresh.
var qaOffState = false;
function qaApplyOff(off) {
	off = !!off;
	if (off === qaOffState) { return; }
	qaOffState = off;
	$('#qa_schedule_save, .qa_run_now, #qa_install').prop('disabled', off);
}

function qaRender(r) {
	var box = $('#qa_readiness');
	var status = $('#qa_install_status');
	if (!r || !r.ok) {
		box.text((r && r.error) ? r.error : qaT('No answer from that machine.'));
		$('#qa_install').hide();
		return;
	}
	if (r.off) {
		box.text(qaT('Off') + ' — ' + qaT('No nightly runs on any machine.'));
		$('#qa_install').hide();
		qaApplyOff(true);
		return;
	}
	qaApplyOff(false);
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
	if (r.off) {
		['suite', 'ux', 'coding'].forEach(function(run) {
			$('#qa_' + run + '_effective').text(qaT('Off'));
			$('#qa_' + run + '_state').text('');
		});
		qaApplyOff(true);
		return false;
	}
	qaApplyOff(false);
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
		qaScheduleRefresh();
		qaReportsRefresh();
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

$(document).on('change', '#qa_ux_model', function() {
	var input = $(this);
	var box = $('#qa_ux_model_status');
	box.text('');
	// The server keeps the shape and answers with what it stored; a refused
	// value leaves the field showing what the house did not take.
	$.post('/manager/configure/qa_device_target', { field: 'ux_model', ux_model: input.val() }, function(res) {
		if (!res || !res.ok) {
			box.text((res && res.error) || qaT('Could not save the model.'));
			return;
		}
		input.val(res.model || '');
		box.text(qaT('Saved.'));
		setTimeout(function() { box.text(''); }, 2000);
	}).fail(function() {
		box.text(qaT('Could not save the model.'));
	});
});

$(document).on('change', '.qa_coding_lane', function() {
	var box = $('#qa_coding_lanes_status');
	var lanes = $('.qa_coding_lane:checked').map(function() { return this.value; }).get();
	box.text('');
	// The server refuses an empty choice; put the box the person just cleared
	// back rather than leaving the panel showing a set the house did not keep.
	if (!lanes.length) {
		$(this).prop('checked', true);
		box.text(qaT('Choose at least one.'));
		return;
	}
	$.post('/manager/configure/qa_device_target', { field: 'lanes', lanes: lanes.join(',') }, function(res) {
		if (!res || !res.ok) {
			box.text((res && res.error) || qaT('Could not save the choice.'));
			return;
		}
		var kept = res.lanes || [];
		$('.qa_coding_lane').each(function() {
			$(this).prop('checked', kept.indexOf(this.value) >= 0);
		});
		box.text(qaT('Saved.'));
		setTimeout(function() { box.text(''); }, 2000);
	}).fail(function() {
		box.text(qaT('Could not save the choice.'));
	});
});

$(document).on('change', '#qa_warden_report', function() {
	var box = $('#qa_warden_report_status');
	var value = $(this).is(':checked') ? 'on' : 'off';
	box.text('');
	$.post('/manager/configure/qa_device_target', { field: 'warden_report', warden_report: value }, function(res) {
		if (!res || !res.ok) {
			box.text((res && res.error) || qaT('Could not save the choice.'));
			return;
		}
		box.text(qaT('Saved.'));
		setTimeout(function() { box.text(''); }, 2000);
	}).fail(function() {
		box.text(qaT('Could not save the choice.'));
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
	qaReportsRefresh();
	releaseScheduleRefresh();
});
$(function() {
	if ($('#plat_qa').length && $('#plat_qa').is(':visible')) { qaRefresh(); qaScheduleRefresh(); qaReportsRefresh(); releaseScheduleRefresh(); }
});

// ---- release schedule (when working is promoted to main) ---------------------
// The promoter's timer ships weekly; this card rewrites its schedule through a
// drop-in on this machine. A preset sends "weekly at 04:00"; Custom sends the
// phrase itself, so "every third friday of the month" is translated server-side.
function releaseScheduleRender(r) {
	var holds = $('#release_schedule_holds');
	if (!holds.length) { return; }
	if (!r || r.ok === 0) {
		holds.text((r && r.error) ? r.error : qaT('No answer from this machine.'));
		return;
	}
	var cal = r.oncalendar || '';
	holds.text(cal ? qaT('The timer holds') + ' ' + cal + (r.source ? ' (' + r.source + ')' : '') : qaT('Not installed'));

	var setting = r.setting || '';
	var custom = $('#release_schedule_custom');
	var select = $('#release_schedule_select');
	var time = $('#release_schedule_time');
	if (!setting || document.activeElement === custom[0] || document.activeElement === time[0]) { return; }
	var m = setting.match(/(\d{2}):(\d{2}):\d{2}\s*$/);
	if (m) { time.val(m[1] + ':' + m[2]); }
	var kind = 'custom';
	if (/^\*-\*-\* \*:\d{2}:\d{2}$/.test(setting)) { kind = 'hourly'; }
	else if (/^\*-\*-\d{2} \d{2}:\d{2}:\d{2}$/.test(setting)) { kind = 'monthly'; }
	else if (/^[A-Z][a-z]{2} \*-\*-\* \d{2}:\d{2}:\d{2}$/.test(setting)) { kind = 'weekly'; }
	else if (/^\*-\*-\* \d{2}:\d{2}:\d{2}$/.test(setting)) { kind = 'daily'; }
	select.val(kind);
	custom.toggle(kind === 'custom');
	if (kind === 'custom') { custom.val(setting); }
}

function releaseScheduleRefresh() {
	if (!$('#release_schedule_card').length) { return; }
	$.getJSON('/manager/configure/release_schedule')
		.done(releaseScheduleRender)
		.fail(function() { releaseScheduleRender({ ok: 0, error: qaT('No answer from this machine.') }); });
}

$(document).on('change', '#release_schedule_select', function() {
	$('#release_schedule_custom').toggle($(this).val() === 'custom');
});

$(document).on('click', '#release_schedule_save', function() {
	var button = $(this);
	var status = $('#release_schedule_status');
	var kind = $('#release_schedule_select').val();
	var time = $('#release_schedule_time').val() || '04:00';
	var phrase = (kind === 'custom') ? $('#release_schedule_custom').val() : (kind + ' at ' + time);
	if (!phrase || !phrase.replace(/\s+/g, '')) {
		status.text(qaT('Say when to release.'));
		return;
	}
	button.prop('disabled', true);
	status.text(qaT('Saving…'));
	$.post('/manager/configure/release_schedule_save', { phrase: phrase }, function(res) {
		button.prop('disabled', false);
		if (!res || res.ok === 0) {
			status.text((res && res.error) || qaT('The schedule was not saved.'));
			return;
		}
		var lines = [qaT('Saved.')];
		if (res.retime_ok === 0) { lines.push(res.error || qaT('The schedule is saved but the timer was not retimed.')); }
		status.text(lines.join('\n'));
		releaseScheduleRefresh();
	}).fail(function() {
		button.prop('disabled', false);
		status.text(qaT('The schedule could not be saved.'));
	});
});

// ---- nightly reports -------------------------------------------------------
// The last 14 days of the installer-freshness run, as the machine that ran it
// recorded: one accordion per run, a table per section inside. The panel only
// reads -- the run happened on the timer, and the report is a file on that
// machine, which is why every machine asks for it the same way.
function qaReportEscape(value) {
	if (value === null || value === undefined) { return ''; }
	return String(value)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

function qaReportStamp(stamp) {
	var m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(stamp || '');
	if (!m) { return stamp || ''; }
	return m[1] + '-' + m[2] + '-' + m[3] + ' ' + m[4] + ':' + m[5] + ' UTC';
}

function qaReportTone(status) {
	switch (status) {
		case 'current': case 'offered': case 'ok': return 'ok';
		case 'available': return 'note';
		case 'outdated': return 'warn';
		case 'missing': case 'failed': return 'bad';
		default: return 'warn';
	}
}

// cells: strings, or { text, tone } in the last column
function qaReportTable(title, head, rows) {
	if (!rows || !rows.length) { return ''; }
	var html = '<table class="qa_report_table"><caption>' + qaReportEscape(title) + '</caption><thead><tr>';
	head.forEach(function(h) { html += '<th>' + qaReportEscape(h) + '</th>'; });
	html += '</tr></thead><tbody>';
	rows.forEach(function(cells) {
		html += '<tr>';
		cells.forEach(function(cell) {
			var text = (cell && typeof cell === 'object') ? cell.text : cell;
			var tone = (cell && typeof cell === 'object') ? cell.tone : '';
			html += '<td' + (tone ? ' class="qa_report_state qa_report_' + qaReportEscape(tone) + '"' : '') + '>'
				+ qaReportEscape(text) + '</td>';
		});
		html += '</tr>';
	});
	return html + '</tbody></table>';
}

function qaReportRun(entry) {
	var report = entry.report || {};
	var summary = report.summary || {};
	var bits = [];
	if (report.note) { bits.push(report.note); }
	if (summary.missing) { bits.push(summary.missing + ' ' + qaT('missing upstream')); }
	if (summary.android_missing) { bits.push(summary.android_missing + ' ' + qaT('Android components missing')); }
	if (summary.outdated || summary.android_outdated) {
		bits.push((summary.outdated + (summary.android_outdated || 0)) + ' ' + qaT('behind upstream'));
	}
	if (!bits.length && entry.report) { bits.push(qaT('nothing missing upstream')); }
	var tone = qaReportTone(entry.status);
	var title = report.title || entry.kind || '';
	var schedule = report.schedule || '';
	var html = '<details class="qa_report" data-status="' + qaReportEscape(entry.status) + '"'
		+ ' data-schedule="' + qaReportEscape(schedule) + '">'
		+ '<summary><span class="qa_report_stamp">' + qaReportEscape(qaReportStamp(entry.stamp)) + '</span>'
		+ '<span class="qa_report_kind">' + qaReportEscape(title) + '</span>'
		+ (schedule ? '<span class="qa_report_schedule">' + qaReportEscape(schedule) + '</span>' : '')
		+ '<span class="qa_report_state qa_report_' + qaReportEscape(tone) + '">' + qaReportEscape(entry.status) + '</span>'
		+ '<span class="qa_report_bits">' + qaReportEscape(bits.join(' · ')) + '</span></summary>';
	if (!entry.report) {
		html += '<p class="cfg-note">' + qaT('This run wrote no report (it stopped before the check).') + '</p>';
		return html + '</details>';
	}
	// A job that writes its own sections (the weekly build, the emulator run)
	// says what it measured; the installer check has the row shapes below.
	(report.sections || []).forEach(function(section) {
		html += qaReportTable(section.title, section.columns || [], section.rows || []);
	});
	if (report.metrics) {
		var metricRows = Object.keys(report.metrics).sort().map(function(key) {
			return [key, String(report.metrics[key])];
		});
		html += qaReportTable(qaT('Measurements'), [qaT('Metric'), qaT('Value')], metricRows);
	}
	var modules = (report.modules || []).map(function(row) {
		return [row.name, row.installed || '-', row.latest || '-', { text: row.status, tone: qaReportTone(row.status) }];
	});
	html += qaReportTable(qaT('Perl modules (CPAN)'), [qaT('Module'), qaT('Installed'), qaT('Candidate'), qaT('Status')], modules);
	var debian = (report.debian || []).map(function(row) {
		var tone = qaReportTone(row.status);
		return [row.package, row.installed || '-', (row.latest || '-') + (row.suite ? ' (' + row.suite + ')' : ''), { text: row.status, tone: tone }];
	});
	html += qaReportTable(qaT('Debian packages'), [qaT('Package'), qaT('Installed'), qaT('Candidate'), qaT('Status')], debian);
	var arch = (report.arch || []).map(function(row) {
		return [row.package, row.installed || '-', (row.latest || '-') + (row.repo ? ' (' + row.repo + ')' : ''), { text: row.status, tone: qaReportTone(row.status) }];
	});
	html += qaReportTable(qaT('Arch packages'), [qaT('Package'), qaT('Installed'), qaT('Latest'), qaT('Status')], arch);
	var android = (report.android || []).map(function(row) {
		return [row.component, row.installed ? qaT('installed here') : '-', '', { text: row.status, tone: qaReportTone(row.status) }];
	});
	html += qaReportTable(qaT('Android SDK components'), [qaT('Component'), qaT('This machine'), '', qaT('Status')], android);
	var toolchain = (report.toolchain || []).map(function(row) {
		return [row.tool, row.installed || '-', row.latest || '-', { text: row.status, tone: qaReportTone(row.status) }];
	});
	html += qaReportTable(qaT('Android toolchain'), [qaT('Tool'), qaT('Installed'), qaT('Offered'), qaT('Status')], toolchain);
	return html + '</details>';
}

function qaReportsRender(r) {
	var box = $('#qa_reports');
	if (!box.length) { return; }
	if (!r || !r.ok) {
		box.text((r && r.error) ? r.error : qaT('No report from that machine.'));
		return;
	}
	if (r.off) {
		box.text(qaT('Off') + ' — ' + qaT('No nightly runs on any machine.'));
		return;
	}
	var list = r.reports || [];
	if (!list.length) {
		box.text(qaT('No reports yet. The first nightly run writes one.'));
		return;
	}
	box.html(list.map(qaReportRun).join(''));
}

function qaReportsRefresh() {
	var box = $('#qa_reports');
	if (!box.length) { return; }
	$.getJSON('/manager/configure/qa_reports', { target: qaTarget() })
		.done(qaReportsRender)
		.fail(function() { qaReportsRender({ ok: 0, error: qaT('No report from that machine.') }); });
}

$(document).on('click', '#qa_reports_refresh', function() {
	$('#qa_reports').text(qaT('Loading…'));
	qaReportsRefresh();
});
