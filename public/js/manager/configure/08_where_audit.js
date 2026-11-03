// The locator audit: run it now, and persist the cadence like any other house
// setting. A run reloads the Sys panel, so the report on screen is the server's
// own render of the cache rather than a second copy built here.
$(document).on('click', '.where_audit_run', function() {
	var b = $(this);
	var text = b.text();
	b.prop('disabled', true).text('... ' + text);
	$.post('/manager/configure/where_audit/run', function() {
		b.prop('disabled', false).text(text);
		// the Sys tab's own handler reloads the panel when the tab is already open
		$('#system_setting_lister').trigger('click');
	}).fail(function() {
		b.prop('disabled', false).text(text);
	});
});

$(document).on('change', '.where_audit_cadence', function() {
	var pick = $(this);
	settingSetter({ app: '__president', setting: 'where_audit_cadence', value: pick.val() });
});
