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
