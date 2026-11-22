/* Away card: keep a budget, routine or notice running while the house is away. */
$(document).on('change', '#me_away_card .away_keep_toggle', function () {
	var box = $(this);
	var app = box.attr('app') || '';
	var kind = box.attr('kind') || '';
	var on = box.is(':checked') ? 'on' : 'off';
	function status(text) {
		var t = (typeof jawnosT === 'function') ? jawnosT : function (s) { return s; };
		$('#me_away_card .away_status').text(t(text));
	}
	function reload() {
		if (typeof jawnosAwayReload === 'function') { jawnosAwayReload(); return; }
		$.get('/manager/configure/me_settings', { timestamp: Date.now() }, function (html) {
			var fresh = $('<div>').html(html).find('#me_away_card').first();
			if (fresh.length) { $('#me_away_card').replaceWith(fresh); }
		});
	}
	$.ajax({
		url: '/manager/vacation/keep',
		type: 'POST',
		data: { app: app, kind: kind, on: on, timestamp: Date.now() },
		success: function (response) {
			if (response && response.ok) { reload(); }
			else {
				status((response && response.error) || 'Could not save the keep list.');
				box.prop('checked', !box.is(':checked'));
			}
		},
		error: function () {
			status('Could not save the keep list.');
			box.prop('checked', !box.is(':checked'));
		}
	});
});
