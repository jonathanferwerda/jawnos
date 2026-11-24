// ---- Plat -> Weather --------------------------------------------------------
// The radar archive and model forecast are house settings, so every machine
// reads one answer. The archive itself is recorded on each computer or server.
$(document).on('change', '.weather_setting', function() {
	var el = $(this);
	var value = el.attr('type') === 'checkbox' ? (el.prop('checked') ? 'on' : 'off') : el.val();
	var status = $('#weather_radar_setting_status');
	status.text(jawnosT('Saving…'));
	$.post('/manager/setting_setter', {
		app: 'weather',
		setting: el.attr('setting'),
		value: value,
		device: 'all',
		timestamp: Date.now()
	}, function(r) {
		if (r && r.ok === 0) { status.text((r && r.error) || jawnosT('Could not save.')); return; }
		status.text(jawnosT('Saved.'));
	}, 'json').fail(function() { status.text(jawnosT('Could not save.')); });
});

$(document).on('click', '#weather_radar_status_refresh', function() {
	var button = $(this);
	var status = $('#weather_radar_archive_status');
	button.prop('disabled', true);
	status.text(jawnosT('Reading…'));
	$.get('/manager/weather/radar_frames', function(r) {
		button.prop('disabled', false);
		var frames = ((r && r.frames) || []).length;
		var mb = (((r && r.bytes) || 0) / 1048576).toFixed(1);
		var text = frames
			? frames + ' ' + jawnosT('frames') + ', ' + mb + ' MB'
			: jawnosT('No frames recorded yet.');
		if (r && r.at) { text += ' · ' + jawnosT('updated') + ' ' + new Date(r.at).toLocaleString(); }
		if (r && r.recorder === 0) { text += ' · ' + jawnosT('this handheld reads live radar; a computer keeps the archive'); }
		status.text(text);
	}, 'json').fail(function() {
		button.prop('disabled', false);
		status.text(jawnosT('Could not read the archive.'));
	});
});
