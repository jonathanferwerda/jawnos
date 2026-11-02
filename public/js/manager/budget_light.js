// The budget light in an appointment's header, and the panel under it.
//
// This file is CORE, not part of the lazy budget chunk. An appointment view
// renders `.budget_light` and `.budget_current_information` without the Budget
// app ever being opened, so the click binding and budgetLight() have to be here
// when the window is built. In the budget chunk they arrived only after the
// Budget app was opened, and every click before that did nothing - the panel
// stayed empty with no view.
//
// The budget app still owns budgetInit() and the rest of its scripts; only the
// light lives here. Budget/*.js must not define these names again: the bundle
// and every chunk share one global scope, so a later definition would silently
// replace this one. t/63-js-parts.t refuses a duplicate top-level function.

// one interval per app whose open duration light is following a running session
var budgetLightIntervals = {};
var budgetLightIntervalMs = 60000;

$(document).on('click', '.budget_light', function() {
	var bl = $(this);
	var circumstance = bl.attr('circumstance');
	var app = bl.attr('app');
	budgetLight(app,circumstance);
});

// The app's ci setting says whether its budget light was left open, and the
// server renders it on the panel. Reopening a closed window brings the light
// back just as it was left; closing it cleared ci, so a closed light stays shut.
function budgetLightRestore(app) {
	var blci = $('.budget_current_information[app="' + app + '"]');
	var circumstance = blci.attr('circumstance') || '';
	if (circumstance) { budgetLight(app, circumstance, 'open'); }
}

function budgetLightStopTimer(app) {
	if (budgetLightIntervals[app]) {
		clearInterval(budgetLightIntervals[app]);
		delete budgetLightIntervals[app];
	}
}

// The panel says whether it is live, so the browser side does not have to read
// the header (which can lag a write).
function budgetLightRunning(blci) {
	var panel = blci.find('[data-budget-running]');
	return panel.length ? panel.attr('data-budget-running') == '1' : false;
}

// An open duration light is a live meter. While the app has a session running,
// re-read the panel so the time it shows grows with the session instead of
// standing at the value from when it was opened (the watcher only passes every
// twenty minutes, and a start or a stop is otherwise the only redraw).
function budgetLightRefresh(app, circumstance, blci) {
	if (!blci.is(':visible') || blci.attr('circumstance') != circumstance) {
		budgetLightStopTimer(app);
		return;
	}
	if (!budgetLightRunning(blci)) {
		budgetLightStopTimer(app);
		return;
	}
	if (blci.data('budget_light_refreshing')) { return; }
	blci.data('budget_light_refreshing', true);
	$.ajax({
		url: '/manager/budget/current_information',
		type: 'GET',
		data: { timestamp: Date.now(), app: app, circumstance: circumstance },
		success: function(response) {
			if (blci.is(':visible') && blci.attr('circumstance') == circumstance) {
				blci.html(response);
				appointment_chron();
				if (!budgetLightRunning(blci)) { budgetLightStopTimer(app); }
			}
		},
		complete: function() {
			blci.data('budget_light_refreshing', false);
		}
	});
}

function budgetLight(app,circumstance,status) {
	var blci = $('.budget_current_information[app="' + app + '"]');
	var wind = blci.closest('.wind');
	var header;
	if ((blci.is(':visible') && status != 'open') && blci.attr('circumstance') == circumstance) {
		budgetLightStopTimer(app);
		blci.hide();
		blci.attr('status', 'closed');
		circumstance = undefined;
		blci.attr('circumstance', undefined);
		header = blci.html();

//		cacheSet({ 'app': app, 'context': 'header' }, { 'timestamp': timestamp, 'header': header });
	}
	else {
		budgetLightStopTimer(app);
		$.ajax({
			url: '/manager/budget/current_information',
			type: 'GET',
			data: { timestamp: wind.attr('timestamp') || Date.now(), app: app, circumstance: circumstance },
			success: function(response) {
				blci.html(response).show();
				blci.attr('circumstance', circumstance);
				blci.attr('status', 'open');
				appointment_chron();
				header = blci.html();
//				cacheSet({ 'app': app, 'context': 'header' }, { 'timestamp': timestamp, 'header': header });
				// only a duration budget grows on its own; the others read counts or
				// money that a running session does not change
				budgetLightStopTimer(app);
				if (circumstance == 'duration' && budgetLightRunning(blci)) {
					budgetLightIntervals[app] = setInterval(function() {
						budgetLightRefresh(app, circumstance, blci);
					}, budgetLightIntervalMs);
				}
			}
		});
	}

	settingSetter({ 'app': app, 'setting': 'ci', 'value': circumstance });

	wind.attr('current_information', circumstance);
}
