// The Sound app: the machine's output and input devices, the default speaker
// and microphone, and the volume and mute of the default output. The server's
// device ids are the controllable devices; the browser's enumerateDevices()
// labels name the speaker and microphone this browser actually uses, which is
// the same source the keyboard's walkboy panel reads its A.V. list from.
//
// The taskbar widget is core (taskbar_sound.js); this file is the lazy chunk
// the window loads. The walkboy panel stays the media picker for now.
var soundTimer = null;
var soundStatusData = null;
var soundBrowserLabels = { output: '', input: '' };

$(document).on('click', '#sound_toggle, .sound_toggle', function() {
	soundOpener();
});

function soundOpener(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/sound',
		type: 'GET',
		data: { timestamp: timestamp, user_agent: navigator.userAgent },
		success: function(response) {
			if (!response) { return; }
			windowMaker(response.window || response);
			soundBind();
			soundBrowserRefresh().then(soundLoad);
		}
	});
}

function soundNote(text) {
	$('#sound_note').text(text || '');
}

function soundSelected(kind) {
	if (!soundStatusData) { return null; }
	return kind == 'input' ? (soundStatusData.input || null) : (soundStatusData.output || null);
}

function soundRows(list, kind) {
	var box = $('<div class="sound_devices"></div>').attr('id', 'sound_' + kind + '_list');
	if (!list || !list.length) {
		var empty = $('<p class="sound_empty"></p>');
		empty.text(jawnosT(kind == 'input' ? 'sound_not_available' : 'sound_no_devices'));
		box.append(empty);
		return box;
	}
	$.each(list, function(i, device) {
		device = device || {};
		var row = $('<div class="sound_device"></div>');
		row.attr('data-kind', kind).attr('data-id', device.id || '');
		if (device.default) { row.attr('data-default', '1'); }
		row.append($('<span class="sound_device_name"></span>').text(device.name || device.id || ''));
		row.append($('<span class="sound_device_level"></span>').text((parseInt(device.volume, 10) || 0) + '%'));
		if (device.default) {
			row.append($('<span class="sound_badge"></span>').text(jawnosT('sound_default')));
		}
		else {
			var button = $('<button type="button" class="sound_default"></button>');
			button.attr('data-kind', kind).attr('data-id', device.id || '');
			button.text(jawnosT('sound_set_default'));
			row.append(button);
		}
		box.append(row);
	});
	return box;
}

function soundBrowserRefresh() {
	if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
		soundBrowserLabels = { output: '', input: '' };
		return Promise.resolve();
	}
	return navigator.mediaDevices.enumerateDevices().then(function(list) {
		var first = function(kind) {
			for (var i = 0; i < list.length; i++) {
				if (list[i].kind == kind && list[i].label) { return list[i].label; }
			}
			return '';
		};
		soundBrowserLabels = { output: first('audiooutput'), input: first('audioinput') };
	}).catch(function() {
		soundBrowserLabels = { output: '', input: '' };
	});
}

// The browser's own inputs and outputs, the list the old Walkboy panel drew:
// what a recording or a call captures and plays through (jp.js reads these
// picks through jawnosDevicePickGet). A press toggles one device per kind.
function soundMediaRender() {
	var box = $('#sound_media_list');
	if (!box.length) { return; }
	if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
		box.html('<p class="sound_empty">' + jawnosT('sound_not_available') + '</p>');
		return;
	}
	navigator.mediaDevices.enumerateDevices().then(function(list) {
		var icons = { audioinput: 'microphone', videoinput: 'camera back', audiooutput: 'speaker' };
		box.empty();
		var count = 0;
		$.each(list, function(i, device) {
			if (!device || !device.deviceId || device.deviceId == 'default') { return; }
			var kind = device.kind || '';
			if (!icons[kind]) { return; }
			var picked = jawnosDevicePickGet(kind, device.deviceId) == 'on' ? 'on' : 'off';
			var row = $('<div class="sound_device sound_media_row"></div>');
			row.append($('<img class="medium_thumb media_picker">').attr({
				device_id: device.deviceId, kind: kind, type: icons[kind], status: picked,
				src: '/images/decipherable/' + icons[kind] + '.png'
			}));
			row.append($('<span class="sound_device_name"></span>').text(device.label || (kind + ' ' + (i + 1))));
			box.append(row);
			count++;
		});
		if (!count) { box.html('<p class="sound_empty">' + jawnosT('sound_not_available') + '</p>'); }
	}).catch(function() {
		box.html('<p class="sound_empty">' + jawnosT('sound_not_available') + '</p>');
	});
}

function soundRender(status) {
	soundStatusData = status;
	var output = (status && status.output) || null;
	var input = (status && status.input) || null;
	var input_supported = !!(status && status.input_supported);

	$('#sound_output_list').replaceWith(soundRows((status && status.outputs) || [], 'output'));
	$('#sound_input_list').replaceWith(soundRows((status && status.inputs) || [], 'input'));

	$('#sound_browser_output').text(soundBrowserLabels.output || '—');
	$('#sound_browser_input').text(soundBrowserLabels.input || '—');

	if (!status || !status.ok) {
		soundNote(jawnosT('sound_not_available'));
	}
	else if (!output) {
		soundNote(jawnosT('sound_no_devices'));
	}
	else {
		soundNote('');
	}

	var out_volume = output ? Math.max(0, Math.min(100, parseInt(output.volume, 10) || 0)) : 0;
	$('#sound_output_volume').val(out_volume).prop('disabled', !output);
	$('#sound_output_volume_value').text(out_volume + '%');
	var out_mute = $('#sound_output_mute');
	var can_mute = !!(output && status.output_mute);
	out_mute.prop('disabled', !can_mute);
	out_mute.text(output && output.muted ? jawnosT('sound_muted') : jawnosT('sound_mute'));

	var in_volume = input ? Math.max(0, Math.min(100, parseInt(input.volume, 10) || 0)) : 0;
	var in_ok = !!(input && input_supported);
	$('#sound_input_volume').val(in_volume).prop('disabled', !in_ok);
	$('#sound_input_volume_value').text(in_volume + '%');
	var in_mute = $('#sound_input_mute');
	in_mute.prop('disabled', !in_ok || !(status && status.input_mute));
	in_mute.text(input && input.muted ? jawnosT('sound_muted') : jawnosT('sound_mute'));
	$('section[data-kind="input"]').attr('data-unsupported', input_supported ? '0' : '1');
}

function soundLoad() {
	if (!$('.wind[app="sound"]').length) { return; }
	$.ajax({
		url: '/manager/sound_status',
		type: 'GET',
		cache: false,
		success: soundRender,
		error: function() { soundNote(jawnosT('sound_not_available')); }
	});
}

function soundSetVolume(kind, volume) {
	var device = soundSelected(kind);
	if (!device) { return; }
	$.ajax({
		url: '/manager/sound/volume',
		type: 'POST',
		data: { kind: kind, id: device.id, volume: volume },
		success: soundRender
	});
}

function soundToggleMute(kind) {
	var device = soundSelected(kind);
	if (!device) { return; }
	$.ajax({
		url: '/manager/sound/mute',
		type: 'POST',
		data: { kind: kind, id: device.id, mute: device.muted ? 0 : 1 },
		success: soundRender
	});
}

function soundSetDefault(kind, id) {
	$.ajax({
		url: '/manager/sound/default',
		type: 'POST',
		data: { kind: kind, id: id },
		success: soundRender
	});
}

function soundBind() {
	var window_box = $('.wind[app="sound"]');
	if (!window_box.length || window_box.data('sound_bound')) { return; }
	window_box.data('sound_bound', 1);
	window_box.on('input', '#sound_output_volume', function() {
		$('#sound_output_volume_value').text($(this).val() + '%');
	});
	window_box.on('change', '#sound_output_volume', function() {
		soundSetVolume('output', $(this).val());
	});
	window_box.on('input', '#sound_input_volume', function() {
		$('#sound_input_volume_value').text($(this).val() + '%');
	});
	window_box.on('change', '#sound_input_volume', function() {
		soundSetVolume('input', $(this).val());
	});
	window_box.on('click', '#sound_output_mute', function() {
		soundToggleMute('output');
	});
	window_box.on('click', '#sound_input_mute', function() {
		soundToggleMute('input');
	});
	window_box.on('click', '.sound_default', function() {
		soundSetDefault($(this).attr('data-kind'), $(this).attr('data-id'));
	});
	if (soundTimer) { clearInterval(soundTimer); }
	soundTimer = setInterval(function() {
		if (!window_box.length || !window_box.is(':visible')) {
			clearInterval(soundTimer);
			soundTimer = null;
			return;
		}
		soundLoad();
	}, 20000);
}
