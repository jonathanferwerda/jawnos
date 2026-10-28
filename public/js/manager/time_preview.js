// Live readings under the appointment's own fields: ago, duration, schedule and
// warranty. The same server reader the time machine uses turns the words into a
// moment or a length, and the line under each input says what will be saved.
//
// A keystroke asks for a fast read (the parsers only). If the words need the
// Guide, a second read is made once typing pauses, so a name or an event fills
// in without waiting for a blur. Blurring asks for the deep read at once.
var jawnosTimePreviewTimers = {};
var jawnosTimePreviewDeep = {};
var jawnosTimePreviewSeq = {};

function jawnosTimePreviewFields(appointment) {
	var app = appointment.attr('app') || '';
	return {
		app: app,
		timestamp: Date.now(),
		time_machine: $('#time_machine').val() || localStorage.getItem('time_machine') || '',
		timeshift: (localStorage.getItem('timeshift') || '') + (localStorage.getItem('timeshift_scope') || ''),
		ago: appointment.find('.ago').val() || '',
		duration: appointment.find('.duration').val() || '',
		schedule: appointment.find('.schedule').val() || '',
		warranty: appointment.find('.warranty').val() || '',
		transaction: appointment.find('.app_details').is(':visible') ? 1 : 0,
		deep: 0
	};
}

function jawnosTimePreviewPaint(appointment, response) {
	if (!response) { return; }
	var put = function(selector, part) {
		var text = (part && part.text) ? part.text : '';
		appointment.find(selector).text(text);
	};
	put('.ago_preview', response.ago);
	put('.duration_preview', response.duration);
	put('.schedule_preview', response.schedule);
	put('.warranty_preview', response.warranty);
}

function jawnosTimePreviewRequest(appointment, deep) {
	if (!appointment || !appointment.length) { return; }
	var app = appointment.attr('app') || '';
	var data = jawnosTimePreviewFields(appointment);
	data.deep = deep ? 1 : 0;
	jawnosTimePreviewSeq[app] = (jawnosTimePreviewSeq[app] || 0) + 1;
	var mine = jawnosTimePreviewSeq[app];
	$.ajax({
		url: '/manager/time_preview',
		type: 'GET',
		data: data,
		dataType: 'json',
		success: function(response) {
			if (mine !== jawnosTimePreviewSeq[app]) { return; }
			jawnosTimePreviewPaint(appointment, response);
			if (deep) { return; }
			// a fast read that could not understand the words gets one deep read
			// when the typing stops, so a Guide phrase resolves in place
			var needs = (response.ago && !response.ago.read)
				|| (response.warranty && !response.warranty.read)
				|| (response.schedule && !response.schedule.read);
			if (needs) {
				clearTimeout(jawnosTimePreviewDeep[app]);
				jawnosTimePreviewDeep[app] = setTimeout(function() {
					jawnosTimePreviewRequest(appointment, true);
				}, 1200);
			}
		}
	});
}

function jawnosTimePreviewPaintApp(app) {
	var appointment = $('.appointment[app="' + app + '"]').first();
	if (appointment.length) { jawnosTimePreviewRequest(appointment, false); }
}

$(document).on('input', '.appointment .ago, .appointment .duration, .appointment .warranty, .appointment .schedule', function() {
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app') || '';
	clearTimeout(jawnosTimePreviewTimers[app]);
	clearTimeout(jawnosTimePreviewDeep[app]);
	jawnosTimePreviewTimers[app] = setTimeout(function() {
		jawnosTimePreviewRequest(appointment, false);
	}, 350);
});

$(document).on('change', '.appointment .ago, .appointment .duration, .appointment .warranty, .appointment .schedule', function() {
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app') || '';
	clearTimeout(jawnosTimePreviewTimers[app]);
	clearTimeout(jawnosTimePreviewDeep[app]);
	jawnosTimePreviewRequest(appointment, true);
});

// The transaction pane opening can change the default warranty it will save,
// so the reading is asked again when the coin is pressed.
$(document).on('click', '.appointment .reset', function() {
	var appointment = $(this).closest('.appointment');
	setTimeout(function() { jawnosTimePreviewRequest(appointment, false); }, 50);
});

function jawnosTimePreviewObserve() {
	$('.appointment').each(function() {
		var appointment = $(this);
		if (appointment.attr('time_preview_seen')) { return; }
		appointment.attr('time_preview_seen', 'yes');
		jawnosTimePreviewRequest(appointment, false);
	});
}

$(function() {
	jawnosTimePreviewObserve();
	if (window.MutationObserver) {
		var observer = new MutationObserver(function(mutations) {
			var found = false;
			mutations.forEach(function(mutation) {
				$(mutation.addedNodes).each(function() {
					if ($(this).is('.appointment') || $(this).find('.appointment').length) { found = true; }
				});
			});
			if (found) { setTimeout(jawnosTimePreviewObserve, 60); }
		});
		observer.observe(document.body, { childList: true, subtree: true });
	}
});
