// ---- the Apps pill ----------------------------------------------------------
// One live mixer for everything the machine carries: the house channels, the
// JawnOS app levels, every playback stream (a browser window, a player, another
// program) and every recording stream. The sound system names a browser by the
// media it is playing, so per-tab control is not offered; the note beside
// Playing now says so. The section refreshes every two seconds only while it is
// the visible pill, and a slider posts once it is released.

var soundAppsTimer = null;
var soundAppsLevelStops = ['passive', 'sound', 'quiet', 'mute', 'silence'];

function soundAppsClamp(value) {
	var level = parseInt(value, 10);
	if (isNaN(level)) { return 0; }
	return Math.max(0, Math.min(100, level));
}

function soundAppsChannelLabel(name) {
	var labels = { music: 'Music', phone: 'Phone', alarm: 'Alarm' };
	return jawnosT(labels[name] || name || '');
}

function soundAppsLevelFromSlider(value) {
	var index = Math.round(soundAppsClamp(value) / 25);
	if (index < 0) { index = 0; }
	if (index > soundAppsLevelStops.length - 1) { index = soundAppsLevelStops.length - 1; }
	return soundAppsLevelStops[index];
}

function soundAppsSliderFromLevel(level) {
	var index = $.inArray(level, soundAppsLevelStops);
	return (index < 0 ? 0 : index) * 25;
}

function soundAppsRow(kind, key, title, detail, volume, muted, options) {
	options = options || {};
	var row = $('<div class="sound_apps_row"></div>').attr('data-kind', kind).attr('data-key', key);
	if (options.name) { row.attr('data-name', options.name); }
	if (options.id !== undefined && options.id !== null) { row.attr('data-id', String(options.id)); }
	if (muted !== undefined && muted !== null) { row.attr('data-muted', muted ? '1' : '0'); }

	var head = $('<div class="sound_apps_head"></div>');
	head.append($('<span class="sound_apps_name"></span>').text(title || ''));
	if (detail) { head.append($('<span class="sound_apps_detail"></span>').text(detail)); }
	row.append(head);

	var control = $('<div class="sound_control"></div>');
	var label = $('<label></label>');
	label.append($('<span></span>').text(jawnosT('sound_volume')));
	var range = $('<input type="range" min="0" max="100" step="1">').val(soundAppsClamp(volume));
	if (options.level) { range.attr('step', '25'); }
	label.append(range);
	var readout = $('<span class="sound_apps_value"></span>');
	readout.text(options.level ? jawnosSoundLevelLabel(options.level) : (soundAppsClamp(volume) + '%'));
	label.append(readout);
	control.append(label);

	if (muted !== undefined && muted !== null) {
		var button = $('<button type="button" class="sound_apps_mute"></button>');
		button.attr('data-muted', muted ? '1' : '0');
		button.text(jawnosT(muted ? 'sound_muted' : 'sound_mute'));
		control.append(button);
	}
	row.append(control);
	return row;
}

// A keyed fill: the row set is rebuilt only when a stream starts, ends or gains
// a detail line, so polling never replaces the slider under a moving finger.
function soundAppsFill(box, rows) {
	if (!box || !box.length) { return; }
	var signature = $.map(rows, function(row) {
		return row.key + ':' + row.row.find('.sound_apps_detail').length
			+ ':' + row.row.find('.sound_apps_mute').length;
	}).join('\u0001');
	if (box.attr('data-keys') !== signature) {
		box.empty().attr('data-keys', signature);
		$.each(rows, function(i, row) { box.append(row.row); });
		return;
	}
	$.each(rows, function(i, row) {
		var old = box.children('.sound_apps_row').filter(function() {
			return $(this).attr('data-key') === row.key;
		}).first();
		if (!old.length) { box.append(row.row); return; }
		old.attr('data-muted', row.row.attr('data-muted') || '');
		old.find('.sound_apps_name').first().text(row.row.find('.sound_apps_name').first().text());
		old.find('.sound_apps_detail').first().text(row.row.find('.sound_apps_detail').first().text());
		old.find('.sound_apps_value').first().text(row.row.find('.sound_apps_value').first().text());
		var oldRange = old.find('input[type=range]').first();
		if (oldRange.length && !oldRange.is(':focus')) {
			oldRange.val(row.row.find('input[type=range]').first().val());
		}
		var oldMute = old.find('.sound_apps_mute').first();
		var newMute = row.row.find('.sound_apps_mute').first();
		if (oldMute.length && newMute.length) {
			oldMute.attr('data-muted', newMute.attr('data-muted')).text(newMute.text());
		}
	});
}

function soundAppsGroup(box, rows, emptyText) {
	if (!box || !box.length) { return; }
	if (!rows.length) {
		box.empty().attr('data-keys', '');
		box.append($('<p class="sound_empty"></p>').text(jawnosT(emptyText)));
		return;
	}
	soundAppsFill(box, rows);
}

function soundAppsRender(data) {
	data = data || {};
	var channels = data.channels || {};
	var channelRows = [];
	$.each(['music', 'phone', 'alarm'], function(i, name) {
		var channel = channels[name];
		if (!channel) { return; }
		channelRows.push({
			key: 'channel:' + name,
			row: soundAppsRow('channel', 'channel:' + name, soundAppsChannelLabel(name), '',
				channel.volume, channel.muted ? 1 : 0, { name: name })
		});
	});
	soundAppsGroup($('#sound_apps_channels'), channelRows, 'No house channels');

	var appRows = [];
	$.each(data.apps || [], function(i, app) {
		if (!app || !app.name) { return; }
		var level = app.level || 'passive';
		appRows.push({
			key: 'app:' + app.name,
			row: soundAppsRow('app', 'app:' + app.name, app.name, jawnosSoundLevelLabel(level),
				soundAppsSliderFromLevel(level), null, { name: app.name, level: level })
		});
	});
	soundAppsGroup($('#sound_apps_apps'), appRows, 'No apps have a window open on this machine');

	var playbackRows = [];
	$.each(data.playback || [], function(i, stream) {
		if (!stream) { return; }
		var detail = [];
		if (stream.media) { detail.push(stream.media); }
		if (stream.binary && stream.binary != stream.app) { detail.push(stream.binary); }
		if (stream.sink !== undefined && stream.sink !== null && stream.sink !== '') {
			detail.push(jawnosT('sound_output') + ' ' + stream.sink);
		}
		if (stream.corked) { detail.push(jawnosT('Paused')); }
		playbackRows.push({
			key: 'playback:' + stream.id,
			row: soundAppsRow('playback', 'playback:' + stream.id,
				stream.app || stream.binary || ('#' + stream.id), detail.join(' · '),
				stream.volume, stream.mute ? 1 : 0, { id: stream.id })
		});
	});
	soundAppsGroup($('#sound_apps_playback'), playbackRows, 'Nothing is playing');

	var recordingRows = [];
	$.each(data.recording || [], function(i, stream) {
		if (!stream) { return; }
		var detail = [];
		if (stream.media) { detail.push(stream.media); }
		if (stream.binary && stream.binary != stream.app) { detail.push(stream.binary); }
		if (stream.source !== undefined && stream.source !== null && stream.source !== '') {
			detail.push(jawnosT('sound_input') + ' ' + stream.source);
		}
		recordingRows.push({
			key: 'recording:' + stream.id,
			row: soundAppsRow('recording', 'recording:' + stream.id,
				stream.app || stream.binary || ('#' + stream.id), detail.join(' · '),
				stream.volume, stream.mute ? 1 : 0, { id: stream.id })
		});
	});
	soundAppsGroup($('#sound_apps_recording'), recordingRows, 'Nothing is recording');
}

function soundAppsNote(text) {
	var box = $('#sound_apps_note');
	if (box.length) { box.text(text || ''); }
}

function soundAppsSectionActive() {
	var section = $('#sound_section_apps');
	return section.length > 0 && section.hasClass('is-active')
		&& $('.wind[app="sound"]').is(':visible');
}

function soundAppsLoad() {
	if (!soundAppsSectionActive()) { return; }
	$.ajax({
		url: '/manager/sound/apps',
		type: 'GET',
		cache: false,
		success: function(response) {
			soundAppsNote('');
			soundAppsRender(response || {});
		},
		error: function() { soundAppsNote(jawnosT('sound_not_available')); }
	});
}

// The two-second clock belongs to the Apps pill. Leaving the pill or closing
// the window stops it on the next tick, so a hidden section costs no requests.
function soundAppsPoll() {
	if (soundAppsTimer) { clearInterval(soundAppsTimer); soundAppsTimer = null; }
	if (!soundAppsSectionActive()) { return; }
	soundAppsLoad();
	soundAppsTimer = setInterval(function() {
		if (!soundAppsSectionActive()) { soundAppsPoll(); return; }
		soundAppsLoad();
	}, 2000);
}

function soundAppsPost(payload) {
	$.ajax({
		url: '/manager/sound/app',
		type: 'POST',
		data: payload,
		success: function(response) {
			if (response && response.ok === 0) {
				soundAppsNote(response.error || jawnosT('sound_not_available'));
				return;
			}
			soundAppsNote('');
			if (response && (response.channels || response.apps || response.playback || response.recording)) {
				soundAppsRender(response);
			}
			else {
				soundAppsLoad();
			}
		},
		error: function() { soundAppsNote(jawnosT('sound_not_available')); }
	});
}

function soundAppsRowTarget(row) {
	var payload = { kind: row.attr('data-kind') };
	if (row.attr('data-name')) { payload.name = row.attr('data-name'); }
	if (row.attr('data-id') !== undefined) { payload.id = row.attr('data-id'); }
	return payload;
}

$(document).on('click', '.wind[app="sound"] .sound_section_pill', function() {
	setTimeout(soundAppsPoll, 0);
});

$(document).on('input', '#sound_section_apps .sound_apps_row input[type=range]', function() {
	var row = $(this).closest('.sound_apps_row');
	var value = soundAppsClamp($(this).val());
	var readout = row.find('.sound_apps_value').first();
	if (row.attr('data-kind') == 'app') {
		readout.text(jawnosSoundLevelLabel(soundAppsLevelFromSlider(value)));
	}
	else {
		readout.text(value + '%');
	}
});

$(document).on('change', '#sound_section_apps .sound_apps_row input[type=range]', function() {
	var row = $(this).closest('.sound_apps_row');
	var value = soundAppsClamp($(this).val());
	var payload = soundAppsRowTarget(row);
	payload.volume = value;
	if (payload.kind == 'app') { payload.level = soundAppsLevelFromSlider(value); }
	soundAppsPost(payload);
});

$(document).on('click', '#sound_section_apps .sound_apps_mute', function() {
	var row = $(this).closest('.sound_apps_row');
	var payload = soundAppsRowTarget(row);
	payload.muted = row.attr('data-muted') == '1' ? 0 : 1;
	soundAppsPost(payload);
});
