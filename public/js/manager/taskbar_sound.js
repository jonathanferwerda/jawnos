// The taskbar's volume widget. It is core, not part of the Sound app's lazy
// chunk: the volume must be readable before the Sound window is ever opened.
// The reading is the same /manager/sound_status the app uses, polled twice a
// minute while the taskbar is on screen.
//
// A press hangs the shared taskbar panel under the widget: the default output
// and input each get a slider and a mute button, and every device is listed so
// it can be made the default. A wheel notch over the widget moves the default
// output by five points, painted at once and posted once the scroll settles.
// The footer's button is the way into the Sound app.
var jawnosSoundTaskbarData = null;
var jawnosSoundTaskbarPanelStale = false;
var jawnosSoundTaskbarWheelTimer = null;
var jawnosSoundTaskbarWheelVolume = null;
var jawnosSoundTaskbarWheelId = null;
var jawnosSoundTaskbarWheelDelay = 250;

function jawnosSoundTaskbarPercent(value) {
	var pct = parseFloat(value);
	if (isNaN(pct)) { pct = 0; }
	return Math.max(0, Math.min(100, Math.round(pct)));
}

function jawnosSoundTaskbarSelected(kind) {
	var status = jawnosSoundTaskbarData;
	if (!status) { return null; }
	return kind == 'input' ? (status.input || null) : (status.output || null);
}

// The one line of feedback the panel owns. It is cleared by a rebuild, so a
// successful action never leaves an old error behind.
function jawnosSoundTaskbarNote(text) {
	$('#taskbar_sound_panel [data-sound-note]').text(text || '');
}

function jawnosSoundTaskbarFail(text) {
	jawnosSoundTaskbarNote(text);
}

// Paint the widget and the open panel from a (possibly optimistic) status.
// Kept as one path so the wheel, a slider drag and a server reply look alike.
function jawnosSoundTaskbarOptimistic(kind, volume) {
	var status = jawnosSoundTaskbarData;
	var device = jawnosSoundTaskbarSelected(kind);
	if (!status || !device) { return; }
	device.volume = volume;
	jawnosSoundTaskbarRender(status);
	$('#taskbar_sound_panel [data-sound-volume="' + kind + '"]').val(volume);
	$('#taskbar_sound_panel [data-sound-value="' + kind + '"]').text(volume + '%');
}

function jawnosSoundTaskbarBindWheel() {
	var widget = $('#taskbar_sound');
	if (!widget.length || widget.data('jawnos_sound_wheel')) { return; }
	widget.data('jawnos_sound_wheel', 1);
	// A native element listener is not passive, so preventDefault really stops
	// the page scrolling under the scroll-to-adjust gesture.
	widget.on('wheel', function(e) {
		if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
		var original = e.originalEvent || e;
		var delta = original.deltaY;
		if (delta === undefined) { delta = e.deltaY; }
		delta = parseFloat(delta) || 0;
		if (!delta) { return; }
		if (!jawnosSoundTaskbarWheelAdjust(delta)) { return; }
		if (e.preventDefault) { e.preventDefault(); }
		return false;
	});
}

// One notch is five points, down is quieter. A fast scroll coalesces into the
// last value; the cached status is moved at once so the bar follows the wheel.
function jawnosSoundTaskbarWheelAdjust(delta) {
	var output = jawnosSoundTaskbarSelected('output');
	if (!output || output.id === undefined || output.id === null || output.id === '') { return false; }
	var id = String(output.id);
	var base = jawnosSoundTaskbarWheelVolume;
	if (base === null || base === undefined || jawnosSoundTaskbarWheelId !== id) {
		base = jawnosSoundTaskbarPercent(output.volume);
	}
	var volume = jawnosSoundTaskbarPercent(base + (delta > 0 ? -5 : 5));
	jawnosSoundTaskbarWheelId = id;
	jawnosSoundTaskbarWheelVolume = volume;
	jawnosSoundTaskbarOptimistic('output', volume);
	if (jawnosSoundTaskbarWheelTimer) { clearTimeout(jawnosSoundTaskbarWheelTimer); }
	jawnosSoundTaskbarWheelTimer = setTimeout(function() {
		jawnosSoundTaskbarWheelTimer = null;
		var send_id = jawnosSoundTaskbarWheelId;
		var send_volume = jawnosSoundTaskbarWheelVolume;
		jawnosSoundTaskbarWheelVolume = null;
		jawnosSoundTaskbarPostVolume('output', send_id, send_volume, function(ok) {
			if (!ok) { return; }
			// The post's answer is enough for the widget; the poller owns the
			// longer-lived truth, so ask it once the scroll has settled.
			jawnosSoundTaskbarLoad();
		});
	}, jawnosSoundTaskbarWheelDelay);
	return true;
}

function jawnosSoundTaskbarRender(status) {
	jawnosSoundTaskbarData = status;
	var widget = $('#taskbar_sound');
	if (!widget.length) { return; }
	jawnosSoundTaskbarBindWheel();
	var output = status && status.output;
	if (!status || !status.ok || !output) {
		widget.attr('hidden', 'hidden').hide();
		jawnosSoundTaskbarPanelSync();
		return;
	}
	var pct = jawnosSoundTaskbarPercent(output.volume);
	var muted = output.muted ? 1 : 0;
	widget.attr('state', muted ? 'muted' : 'on').attr('level', pct);
	widget.find('.taskbar_sound_waves i').each(function(index) {
		$(this).toggleClass('on', !muted && pct > (index + 1) * 18);
	});
	widget.find('.taskbar_sound_text').text(muted ? jawnosT('sound_muted') : pct + '%');
	var title = jawnosT('sound') + ' — ' + (muted ? jawnosT('sound_muted') : pct + '%');
	if (output.name) { title += ' — ' + output.name; }
	widget.attr('title', title).removeAttr('hidden').show();
	jawnosSoundTaskbarPanelSync();
}

function jawnosSoundTaskbarLoad() {
	if (!$('#taskbar_sound').length) { return; }
	if (typeof document !== 'undefined' && document.hidden) { return; }
	$.ajax({
		url: '/manager/sound_status',
		type: 'GET',
		cache: false,
		success: function(status) { jawnosSoundTaskbarRender(status); },
		error: function() {
			$('#taskbar_sound').attr('hidden', 'hidden').hide();
			jawnosSoundTaskbarNote(jawnosT('Sound is not available'));
		}
	});
}

function jawnosSoundTaskbarVolumeSection(kind, heading, device) {
	var section = $('<div class="taskbar_panel_section"></div>').attr('data-sound-section', kind);
	section.append($('<h4></h4>').text(heading));
	var row = $('<div class="taskbar_panel_row"></div>');
	var pct = jawnosSoundTaskbarPercent(device.volume);
	var muted = device.muted ? 1 : 0;
	var slider = $('<input type="range" min="0" max="100" step="1">')
		.attr('data-sound-volume', kind)
		.attr('aria-label', heading)
		.val(pct);
	var value = $('<span class="taskbar_panel_value"></span>')
		.attr('data-sound-value', kind)
		.text(pct + '%');
	var mute = $('<button type="button"></button>')
		.attr('data-sound-mute', kind)
		.attr('aria-pressed', muted ? 'true' : 'false')
		.text(muted ? jawnosT('sound_muted') : jawnosT('sound_mute'));
	if (muted) { mute.addClass('taskbar_panel_active'); }
	row.append(slider).append(value).append(mute);
	section.append(row);
	return section;
}

// Every listed device is a row; the default carries the badge and the accent
// edge, and a press on any other row hands it the default.
function jawnosSoundTaskbarDeviceList(kind, devices) {
	var scroll = $('<div class="taskbar_panel_scroll"></div>');
	var count = 0;
	$.each(devices || [], function(i, device) {
		device = device || {};
		if (device.id === undefined || device.id === null || device.id === '') { return; }
		var id = String(device.id);
		count++;
		var row = $('<div class="taskbar_panel_device"></div>')
			.attr('data-kind', kind)
			.attr('data-id', id);
		if (device.default) { row.attr('data-default', '1'); }
		row.append($('<span class="taskbar_panel_label"></span>').text(device.name || id));
		row.append($('<span class="taskbar_panel_value"></span>').text(jawnosSoundTaskbarPercent(device.volume) + '%'));
		if (device.default) {
			row.append($('<span class="taskbar_panel_badge"></span>').text(jawnosT('Default')));
		}
		scroll.append(row);
	});
	return count ? scroll : null;
}

function jawnosSoundTaskbarPanelFooter() {
	var footer = $('<div class="taskbar_panel_footer"></div>');
	footer.append($('<button type="button" class="taskbar_panel_open"></button>')
		.attr('data-app', 'sound')
		.text(jawnosT('Open Sound')));
	return footer;
}

function jawnosSoundTaskbarPanelBuild(panel) {
	panel.empty();
	var status = jawnosSoundTaskbarData;
	var footer = jawnosSoundTaskbarPanelFooter();
	var note = $('<p class="taskbar_panel_note"></p>').attr('data-sound-note', '1');
	if (!status || !status.ok) {
		// Mark the panel so the next poll rebuilds it in place.
		jawnosSoundTaskbarPanelStale = true;
		panel.append($('<p class="taskbar_panel_empty"></p>').text(jawnosT('Sound is not available')));
		panel.append(note).append(footer);
		return;
	}
	jawnosSoundTaskbarPanelStale = false;

	var output = status.output || null;
	if (output) {
		panel.append(jawnosSoundTaskbarVolumeSection('output', jawnosT('Output'), output));
	}
	else {
		var out_section = $('<div class="taskbar_panel_section"></div>');
		out_section.append($('<h4></h4>').text(jawnosT('Output')));
		out_section.append($('<p class="taskbar_panel_empty"></p>').text(jawnosT('No output device')));
		panel.append(out_section);
	}
	var outputs = jawnosSoundTaskbarDeviceList('output', status.outputs);
	if (outputs) { panel.append(outputs); }

	var input = status.input || null;
	var input_supported = !!status.input_supported;
	if (input_supported && input) {
		panel.append(jawnosSoundTaskbarVolumeSection('input', jawnosT('Input'), input));
	}
	else {
		var in_section = $('<div class="taskbar_panel_section"></div>');
		in_section.append($('<h4></h4>').text(jawnosT('Input')));
		in_section.append($('<p class="taskbar_panel_empty"></p>').text(input_supported
			? jawnosT('No input device')
			: jawnosT('Input volume is not available on this machine')));
		panel.append(in_section);
	}
	var inputs = jawnosSoundTaskbarDeviceList('input', status.inputs);
	if (inputs) { panel.append(inputs); }

	panel.append(note).append(footer);
}

function jawnosSoundTaskbarPanelRefresh() {
	if (typeof jawnosTaskbarPanelIsOpen !== 'function' || !jawnosTaskbarPanelIsOpen('taskbar_sound_panel')) { return; }
	var panel = $('#taskbar_sound_panel');
	if (!panel.length) { return; }
	jawnosSoundTaskbarPanelBuild(panel);
}

// A panel opened before the first reading fills itself in when that reading
// lands; a rebuild after every action keeps the default badges honest.
function jawnosSoundTaskbarPanelSync() {
	if (!jawnosSoundTaskbarPanelStale) { return; }
	if (typeof jawnosTaskbarPanelIsOpen !== 'function' || !jawnosTaskbarPanelIsOpen('taskbar_sound_panel')) { return; }
	jawnosSoundTaskbarPanelStale = false;
	jawnosSoundTaskbarPanelRefresh();
}

function jawnosSoundTaskbarPostVolume(kind, id, volume, done) {
	if (id === undefined || id === null || id === '') { if (done) { done(false); } return; }
	jawnosSoundTaskbarNote('');
	$.ajax({
		url: '/manager/sound/volume',
		type: 'POST',
		data: { kind: kind, id: id, volume: volume },
		success: function(status) {
			jawnosSoundTaskbarRender(status);
			jawnosSoundTaskbarPanelRefresh();
			if (done) { done(true); }
		},
		error: function() {
			jawnosSoundTaskbarFail(jawnosT('Could not change the volume.'));
			// Put the controls back where the server says they are.
			jawnosSoundTaskbarLoad();
			if (done) { done(false); }
		}
	});
}

function jawnosSoundTaskbarSetMute(kind, id, mute) {
	jawnosSoundTaskbarNote('');
	$.ajax({
		url: '/manager/sound/mute',
		type: 'POST',
		data: { kind: kind, id: id, mute: mute },
		success: function(status) {
			jawnosSoundTaskbarRender(status);
			jawnosSoundTaskbarPanelRefresh();
		},
		error: function() {
			jawnosSoundTaskbarFail(jawnosT('Could not change mute.'));
			jawnosSoundTaskbarLoad();
		}
	});
}

function jawnosSoundTaskbarSetDefault(kind, id) {
	jawnosSoundTaskbarNote('');
	$.ajax({
		url: '/manager/sound/default',
		type: 'POST',
		data: { kind: kind, id: id },
		success: function(status) {
			jawnosSoundTaskbarRender(status);
			jawnosSoundTaskbarPanelRefresh();
		},
		error: function() {
			jawnosSoundTaskbarFail(jawnosT('Could not switch the device.'));
			jawnosSoundTaskbarLoad();
		}
	});
}

$(document).on('click', '#taskbar_sound', function() {
	if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
	if (typeof jawnosTaskbarPanelToggle === 'function') {
		var open = typeof jawnosTaskbarPanelIsOpen === 'function' && jawnosTaskbarPanelIsOpen('taskbar_sound_panel');
		if (!open && (!jawnosSoundTaskbarData || !jawnosSoundTaskbarData.ok)) { jawnosSoundTaskbarLoad(); }
		jawnosTaskbarPanelToggle('taskbar_sound_panel', '#taskbar_sound', jawnosSoundTaskbarPanelBuild);
		return;
	}
	// The frame is core, but a partial bundle should still reach the app.
	if (typeof appWindowOpener === 'function') {
		appWindowOpener('sound', Date.now(), { visible: 'yes' });
	}
});

$(document).on('input', '#taskbar_sound_panel [data-sound-volume]', function() {
	var kind = $(this).attr('data-sound-volume');
	var volume = jawnosSoundTaskbarPercent($(this).val());
	$('#taskbar_sound_panel [data-sound-value="' + kind + '"]').text(volume + '%');
	jawnosSoundTaskbarOptimistic(kind, volume);
});

$(document).on('change', '#taskbar_sound_panel [data-sound-volume]', function() {
	var kind = $(this).attr('data-sound-volume');
	var device = jawnosSoundTaskbarSelected(kind);
	if (!device) { return; }
	jawnosSoundTaskbarPostVolume(kind, device.id, jawnosSoundTaskbarPercent($(this).val()));
});

$(document).on('click', '#taskbar_sound_panel [data-sound-mute]', function() {
	var kind = $(this).attr('data-sound-mute');
	var device = jawnosSoundTaskbarSelected(kind);
	if (!device) { return; }
	jawnosSoundTaskbarSetMute(kind, device.id, device.muted ? 0 : 1);
});

$(document).on('click', '#taskbar_sound_panel .taskbar_panel_device', function() {
	var kind = $(this).attr('data-kind');
	var id = $(this).attr('data-id');
	if (!id || $(this).attr('data-default') == '1') { return; }
	jawnosSoundTaskbarSetDefault(kind, id);
});

$(function() {
	setTimeout(jawnosSoundTaskbarLoad, 1600);
	setInterval(jawnosSoundTaskbarLoad, 45000);
});
