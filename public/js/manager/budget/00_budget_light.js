// The budget light in an appointment's header. Clicking it opens that app's
// budget_current_information panel: the period against its budget, the pace it
// is on, and - when what is counted is over the budget - the Recommended
// button. The wrapper renders that panel empty (templates/appointment_wrapper.html.ep,
// the div.budget_current_information with display:none), so it has to be filled
// from the server the first time the light is opened and again whenever it is
// asked to reopen.
//
// The callers still name this function - public/js/manager/windows.js,
// public/js/manager/windows/01_storage.js,
// public/js/manager/websocket/01_message_handler.js and
// public/js/manager/budget/01_reconcile_payables.js - but the definition had
// gone missing, so the click had nothing to call and the panel came up with no
// view.
function budgetLight(app, circumstance, mode) {
	if (typeof app === 'undefined' || app === null) { return; }
	var blci = $('.budget_current_information[app="' + app + '"]');
	if (!blci.length) { return; }
	var open = blci.is(':visible');
	if (mode === 'close' || (open && mode !== 'open')) {
		blci.attr('circumstance', '');
		blci.hide();
		return;
	}
	blci.attr('circumstance', circumstance || blci.attr('circumstance') || 'open');
	blci.show();
	// A push (a websocket update for a running session) reopens and reloads;
	// a plain click on an already loaded panel just toggled it shut above.
	if (blci.attr('light_loaded') === 'yes' && mode !== 'open') { return; }
	blci.attr('light_loaded', 'yes');
	$.ajax({
		url: '/manager/budget/current_information',
		type: 'GET',
		data: {
			app: app,
			circumstance: blci.attr('circumstance'),
			timestamp: blci.closest('.wind').attr('timestamp') || ''
		},
		success: function(response) {
			var html = response;
			if (html && typeof html === 'object') {
				html = html.content || html.html || html.current_information || '';
			}
			if (typeof html !== 'string' || !html.length) {
				blci.removeAttr('light_loaded');
				return;
			}
			blci.html(html);
		},
		error: function() {
			// Leave the panel empty rather than claiming a figure: the next
			// open tries again.
			blci.removeAttr('light_loaded');
		}
	});
}
