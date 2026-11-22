/* Away card: start or end a house-wide away period. */
function jawnosAwayStatus(text) {
	var t = (typeof jawnosT === 'function') ? jawnosT : function (s) { return s; };
	$('#me_away_card .away_status').text(t(text));
}
function jawnosAwayReload() {
	$.get('/manager/configure/me_settings', { timestamp: Date.now() }, function (html) {
		var fresh = $('<div>').html(html).find('#me_away_card').first();
		if (fresh.length) { $('#me_away_card').replaceWith(fresh); }
	});
}
function jawnosAwayEpoch(value, end_of_day) {
	if (!value) { return ''; }
	var d = new Date(value + (end_of_day ? 'T23:59:59.999' : 'T00:00:00.000'));
	if (isNaN(d.getTime())) { return ''; }
	// A start date that is today begins now, not at midnight: pressing Start in
	// the evening must not cut today's sessions back to breakfast.
	if (!end_of_day && d.toDateString() === new Date().toDateString()) {
		return Date.now();
	}
	return d.getTime();
}
$(document).on('click', '#me_away_card .away_start', function () {
	var from = jawnosAwayEpoch($('#me_away_card .away_from').val(), false);
	var to = jawnosAwayEpoch($('#me_away_card .away_to').val(), true);
	if (!from) { jawnosAwayStatus('Choose a start date.'); return; }
	if (to && to <= from) { jawnosAwayStatus('The end must be after the start.'); return; }
	jawnosAwayStatus('Saving\u2026');
	$.ajax({
		url: '/manager/vacation/start',
		type: 'POST',
		data: { from: from, to: to, note: $('#me_away_card .away_note').val(), timestamp: Date.now() },
		success: function (response) {
			if (response && response.ok) { jawnosAwayReload(); }
			else { jawnosAwayStatus((response && response.error) || 'Could not save the away period.'); }
		},
		error: function () { jawnosAwayStatus('Could not save the away period.'); }
	});
});
$(document).on('click', '#me_away_card .away_end', function () {
	jawnosAwayStatus('Saving\u2026');
	$.ajax({
		url: '/manager/vacation/end',
		type: 'POST',
		data: { timestamp: Date.now() },
		success: function (response) {
			if (response && response.ok) { jawnosAwayReload(); }
			else { jawnosAwayStatus((response && response.error) || 'Could not end the away period.'); }
		},
		error: function () { jawnosAwayStatus('Could not end the away period.'); }
	});
});

$(document).on('click', '#me_away_card .away_cancel', function () {
	var uuid = $(this).attr('uuid') || '';
	jawnosAwayStatus('Saving\u2026');
	$.ajax({
		url: '/manager/vacation/cancel',
		type: 'POST',
		data: { uuid: uuid, timestamp: Date.now() },
		success: function (response) {
			if (response && response.ok) { jawnosAwayReload(); }
			else { jawnosAwayStatus((response && response.error) || 'Could not cancel the away period.'); }
		},
		error: function () { jawnosAwayStatus('Could not cancel the away period.'); }
	});
});

$(document).on('click', '#me_away_card .away_detect_save', function () {
	var detect = $('#me_away_card .away_detect').is(':checked') ? 'on' : 'off';
	var hours = $('#me_away_card .away_after_hours').val() || '24';
	jawnosAwayStatus('Saving\u2026');
	$.ajax({
		url: '/manager/vacation/detect',
		type: 'POST',
		data: { detect: detect, after_hours: hours, timestamp: Date.now() },
		success: function (response) {
			if (response && response.ok) { jawnosAwayReload(); }
			else { jawnosAwayStatus((response && response.error) || 'Could not save the detector.'); }
		},
		error: function () { jawnosAwayStatus('Could not save the detector.'); }
	});
});

function jawnosAwayProposal(button, accept) {
	var uuid = $(button).attr('uuid') || '';
	jawnosAwayStatus('Saving\u2026');
	$.ajax({
		url: '/manager/vacation/proposal',
		type: 'POST',
		data: { uuid: uuid, accept: accept ? 1 : 0, timestamp: Date.now() },
		success: function (response) {
			if (response && response.ok) { jawnosAwayReload(); }
			else { jawnosAwayStatus((response && response.error) || 'Could not answer the quiet period.'); }
		},
		error: function () { jawnosAwayStatus('Could not answer the quiet period.'); }
	});
}

$(document).on('click', '#me_away_card .away_accept', function () {
	jawnosAwayProposal(this, true);
});

$(document).on('click', '#me_away_card .away_dismiss', function () {
	jawnosAwayProposal(this, false);
});

/* Presence simulation: a board's learned remotes are replayed while an away
   period is active. The remote list belongs to the board, so changing the
   board asks /manager/embedded/remotes for that board's names. */
function jawnosPresenceStatus(text) {
	var t = (typeof jawnosT === 'function') ? jawnosT : function (s) { return s; };
	$('#me_presence_card .presence_status').text(t(text));
}
function jawnosPresenceRemotes(chip_id, keep) {
	var select = $('#me_presence_card .presence_remote');
	var t = (typeof jawnosT === 'function') ? jawnosT : function (s) { return s; };
	select.empty().append($('<option>').val('').text(t('Choose a remote')));
	if (!chip_id) { return; }
	$.ajax({
		url: '/manager/embedded/remotes',
		type: 'GET',
		dataType: 'json',
		data: { edt: 'microcontroller', chip_id: chip_id }
	}).done(function (response) {
		if (!response || !response.ok) { return; }
		var remotes = response.remotes || {};
		var names = Object.keys(remotes).sort();
		for (var i = 0; i < names.length; i++) {
			var option = $('<option>').val(names[i]).text(names[i]);
			if (names[i] === keep) { option.prop('selected', true); }
			select.append(option);
		}
	}).fail(function () {
		jawnosPresenceStatus('Could not read the remotes.');
	});
}
$(document).on('change', '#me_presence_card .presence_board', function () {
	jawnosPresenceRemotes($(this).val(), '');
});
$(document).on('click', '#me_presence_card .presence_save', function () {
	var enabled = $('#me_presence_card .presence_enabled').is(':checked') ? 'yes' : 'no';
	jawnosPresenceStatus('Saving\u2026');
	$.ajax({
		url: '/manager/vacation/presence',
		type: 'POST',
		data: {
			enabled: enabled,
			chip_id: $('#me_presence_card .presence_board').val() || '',
			remote: $('#me_presence_card .presence_remote').val() || '',
			on: $('#me_presence_card .presence_on').val() || '',
			off: $('#me_presence_card .presence_off').val() || '',
			jitter: $('#me_presence_card .presence_jitter').val() || '20',
			timestamp: Date.now()
		},
		success: function (response) {
			if (response && response.ok) { jawnosAwayReload(); }
			else { jawnosPresenceStatus((response && response.error) || 'Could not save presence simulation.'); }
		},
		error: function () { jawnosPresenceStatus('Could not save presence simulation.'); }
	});
});
