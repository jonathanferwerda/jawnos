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
var jawnosTimePreviewBusy = {};

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
		quantity: appointment.find('.quantity').val() || '',
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
	put('.quantity_preview', response.quantity);
}

function jawnosTimePreviewRequest(appointment, deep) {
	if (!appointment || !appointment.length) { return; }
	var app = appointment.attr('app') || '';
	if (jawnosTimePreviewBusy[app]) { return; }
	jawnosTimePreviewBusy[app] = 1;
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
			delete jawnosTimePreviewBusy[app];
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
		},
		error: function() { delete jawnosTimePreviewBusy[app]; }
	});
}

// Where the view stands: the time machine's words and the timeshift. Every
// reading under a field is anchored here, so the open windows have to be asked
// again when it moves - whether the change came from #time_machine, the
// taskbar clock, a timeline drag, a past-life jump or the now button.
function jawnosTimePreviewCentre() {
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine') || '';
	var timeshift = (localStorage.getItem('timeshift') || '') + (localStorage.getItem('timeshift_scope') || '');
	return time_machine + '\u0000' + timeshift;
}
var jawnosTimePreviewCentreAt = null;
function jawnosTimePreviewRefreshAll() {
	$('.appointment').each(function() {
		var appointment = $(this);
		var app = appointment.attr('app') || '';
		// an answer asked for the old centre must not hold the new one back; the
		// sequence check in the request keeps it from painting over the answer
		delete jawnosTimePreviewBusy[app];
		jawnosTimePreviewRequest(appointment, false);
	});
}

// The ago reading has to follow the clock: "10 minutes ago" resolves to a
// different moment every second, and an absolute time counts down to it. While
// a person is editing the ago field, ask the fast parser again each second.
// The same tick watches the view's centre so a time-machine change reaches
// every open window without waiting for the next poll or a keystroke.
setInterval(function() {
	if (document.hidden) { return; }
	var centre = jawnosTimePreviewCentre();
	if (jawnosTimePreviewCentreAt === null) { jawnosTimePreviewCentreAt = centre; }
	else if (centre !== jawnosTimePreviewCentreAt) {
		jawnosTimePreviewCentreAt = centre;
		jawnosTimePreviewRefreshAll();
		return;
	}
	var field = $('.appointment .ago:focus');
	if (!field.length || !$.trim(field.val() || '')) { return; }
	jawnosTimePreviewRequest(field.closest('.appointment'), false);
}, 1000);

function jawnosTimePreviewPaintApp(app) {
	var appointment = $('.appointment[app="' + app + '"]').first();
	if (appointment.length) { jawnosTimePreviewRequest(appointment, false); }
}

$(document).on('input', '.appointment .ago, .appointment .duration, .appointment .warranty, .appointment .schedule, .appointment .quantity', function() {
	var appointment = $(this).closest('.appointment');
	var app = appointment.attr('app') || '';
	clearTimeout(jawnosTimePreviewTimers[app]);
	clearTimeout(jawnosTimePreviewDeep[app]);
	jawnosTimePreviewTimers[app] = setTimeout(function() {
		jawnosTimePreviewRequest(appointment, false);
	}, 350);
});

$(document).on('change', '.appointment .ago, .appointment .duration, .appointment .warranty, .appointment .schedule, .appointment .quantity', function() {
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
