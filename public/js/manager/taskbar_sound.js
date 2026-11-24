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
// A wheel notch is about 100 deltaY; a trackpad sends many smaller events, so
// the points are accumulated instead of moving on every event. Half the old
// five-points-a-notch rate, which felt too fast on a trackpad.
var jawnosSoundTaskbarWheelRate = 2.5;
var jawnosSoundTaskbarWheelDelay = 250;
var jawnosSoundTaskbarWheelAccum = {};
var jawnosSoundTaskbarWheelVolume = {};
var jawnosSoundTaskbarWheelTimer = {};
// The Music transport in the panel. The machine list and the remembered remote
// target are read once and refreshed when the panel opens; the remote player's
// state is polled only while the panel is on screen.
var jawnosSoundTaskbarMusic = { machines: [], widget_target: '', state: null, loaded: 0 };

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
	// The volume reads out in a house notice while it moves, the way a desktop
	// shows its own on-screen display. The key keeps one card, updated in place.
	if (typeof jawnosNotice === 'function') {
		jawnosNotice({
			key: 'volume',
			title: jawnosT('Volume'),
			message: (kind == 'input' ? jawnosT('Input') : jawnosT('Output')) + ': ' + volume + '%',
			app: 'sound',
			ttl: 1200
		});
	}
}

function jawnosSoundTaskbarBindWheel() {
	var widget = $('#taskbar_sound');
	if (!widget.length || widget.data('jawnos_sound_wheel')) { return; }
	widget.data('jawnos_sound_wheel', 1);
	widget.on('wheel', function(e) { return jawnosSoundTaskbarWheelEvent(e, 'output'); });
}

// One wheel handler for the widget and for the panel's sliders. Returning false
// keeps the page from scrolling under the gesture.
function jawnosSoundTaskbarWheelEvent(e, kind) {
	if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
	var original = e.originalEvent || e;
	var delta = (original.deltaY !== undefined) ? original.deltaY : e.deltaY;
	delta = parseFloat(delta) || 0;
	// Firefox reports lines, not pixels: three lines is about one notch.
	if (original.deltaMode === 1) { delta *= 33; }
	else if (original.deltaMode === 2) { delta *= 100; }
	if (!delta) { return; }
	if (!jawnosSoundTaskbarWheelAdjust(kind || 'output', delta)) { return; }
	if (e.preventDefault) { e.preventDefault(); }
	return false;
}

// One notch is 2.5 points, down is quieter. The accumulator carries the
// fractions between events, so a trackpad moves smoothly and a mouse wheel
// still crosses two or three points a notch while the scroll settles.
function jawnosSoundTaskbarWheelAdjust(kind, delta) {
	var device = jawnosSoundTaskbarSelected(kind);
	if (!device || device.id === undefined || device.id === null || device.id === '') { return false; }
	var id = String(device.id);
	var state = jawnosSoundTaskbarWheelAccum[kind];
	if (!state || state.id !== id) { state = { id: id, points: 0 }; }
	var base = jawnosSoundTaskbarWheelVolume[kind];
	if (base === null || base === undefined) { base = jawnosSoundTaskbarPercent(device.volume); }
	state.points += (-(parseFloat(delta) || 0) / 100) * jawnosSoundTaskbarWheelRate;
	var whole = state.points > 0 ? Math.floor(state.points) : Math.ceil(state.points);
	jawnosSoundTaskbarWheelAccum[kind] = state;
	if (!whole) { return true; }
	state.points -= whole;
	var volume = jawnosSoundTaskbarPercent(base + whole);
	jawnosSoundTaskbarWheelVolume[kind] = volume;
	jawnosSoundTaskbarOptimistic(kind, volume);
	if (jawnosSoundTaskbarWheelTimer[kind]) { clearTimeout(jawnosSoundTaskbarWheelTimer[kind]); }
	jawnosSoundTaskbarWheelTimer[kind] = setTimeout(function() {
		jawnosSoundTaskbarWheelTimer[kind] = null;
		var send_volume = jawnosSoundTaskbarWheelVolume[kind];
		jawnosSoundTaskbarWheelVolume[kind] = null;
		jawnosSoundTaskbarPostVolume(kind, id, send_volume, function(ok) {
			if (!ok) { return; }
			// The post's answer is enough for the controls; the poller owns the
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
	var slider = $('<input type="range" class="taskbar_sound_slider" min="0" max="100" step="1">')
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

// The house level rides at the top of the panel, above the device lists: it is
// the base every app at Passive inherits, and the widget is where it is
// quickest to change.
function jawnosSoundTaskbarLevelLabel(level) {
	var keys = { passive: 'sound_passive', sound: 'sound', quiet: 'sound_quiet', mute: 'sound_mute', silence: 'sound_silence' };
	return jawnosT(keys[level] || 'sound');
}

function jawnosSoundTaskbarLevelSection(status) {
	var section = $('<div class="taskbar_panel_section"></div>').attr('data-sound-section', 'level');
	section.append($('<h4></h4>').text(jawnosT('sound_level')));
	var row = $('<div class="taskbar_panel_row"></div>');
	var select = $('<select data-sound-level></select>').attr('aria-label', jawnosT('sound_level'));
	$.each(['sound', 'quiet', 'mute', 'silence'], function(i, level) {
		select.append($('<option></option>').attr('value', level).text(jawnosSoundTaskbarLevelLabel(level)));
	});
	select.val((status && status.level) || 'sound');
	row.append(select);
	if (status && status.house_level && status.house_level != status.level) {
		row.append($('<span class="taskbar_panel_value"></span>').text(jawnosSoundTaskbarLevelLabel(status.house_level)));
	}
	section.append(row);
	return section;
}

// ---- the Music transport in the panel -------------------------------------
//
// The widget is the quickest way to start Music and to control a machine's
// Music app. The local target is this window's own player (music.js); a remote
// target is relayed to that machine. The widget remembers its remote target
// separately from the Music window's own remote session.
function jawnosSoundTaskbarMusicTarget() {
	return jawnosSoundTaskbarMusic.widget_target || '';
}
function jawnosSoundTaskbarMusicLoad() {
	$.ajax({
		url: '/music/remote_machines',
		type: 'GET',
		dataType: 'json',
		cache: false,
		success: function(r) {
			if (!r || !r.ok) { return; }
			jawnosSoundTaskbarMusic.machines = r.machines || [];
			jawnosSoundTaskbarMusic.widget_target = r.widget_target || '';
			jawnosSoundTaskbarMusic.loaded = 1;
			jawnosSoundTaskbarPanelRefresh();
		}
	});
}
function jawnosSoundTaskbarMusicState() {
	var target = jawnosSoundTaskbarMusicTarget();
	if (!target) {
		return (typeof musicTransportStateLocal == 'function') ? musicTransportStateLocal() : null;
	}
	return jawnosSoundTaskbarMusic.state;
}
function jawnosSoundTaskbarMusicStateLoad() {
	var target = jawnosSoundTaskbarMusicTarget();
	if (!target) {
		jawnosSoundTaskbarMusic.state = null;
		jawnosSoundTaskbarMusicRepaint();
		return;
	}
	if (typeof document !== 'undefined' && document.hidden) { return; }
	$.ajax({
		url: '/music/transport_state',
		type: 'GET',
		dataType: 'json',
		cache: false,
		data: { target: target },
		success: function(r) {
			if (!r || !r.ok || jawnosSoundTaskbarMusicTarget() !== target) { return; }
			jawnosSoundTaskbarMusic.state = r;
			jawnosSoundTaskbarMusicRepaint();
		}
	});
}
// The player's icons follow the selected icon set; the window's own logo
// carries both glyphs, so use them when it is open and the shipped pair when it
// is not.
function jawnosSoundTaskbarMusicIcon(playing) {
	var logo = $('#play_logo');
	var src = playing ? logo.attr('pause_icon') : logo.attr('play_icon');
	if (src) { return src; }
	return playing ? '/icons/pause.jpg' : '/icons/play.jpg';
}
function jawnosSoundTaskbarMusicRepaint() {
	var section = $('#taskbar_sound_panel [data-sound-section="music"]');
	if (!section.length) { return; }
	var state = jawnosSoundTaskbarMusicState();
	var playing = state && state.playing ? 1 : 0;
	section.find('[data-music-role="playpause"] img')
		.attr('src', jawnosSoundTaskbarMusicIcon(playing))
		.attr('hint', playing ? jawnosT('Pause') : jawnosT('Play'));
	section.find('[data-music-role="playpause"]').attr('aria-label', playing ? jawnosT('Pause') : jawnosT('Play'));
	var now = (state && (state.title || state.file)) ? (state.title || '') : '';
	section.find('[data-music-role="now"]').text(now);
}
function jawnosSoundTaskbarMusicTransport(action) {
	var target = jawnosSoundTaskbarMusicTarget();
	if (!target) {
		// Keep the local path here, in the page: music.js already has the player
		// and the one-meaning "open it if it is not open" behaviour.
		if (typeof musicTransportLocal == 'function') { musicTransportLocal(action); }
		setTimeout(jawnosSoundTaskbarMusicRepaint, 150);
		setTimeout(jawnosSoundTaskbarMusicRepaint, 900);
		return;
	}
	var state = jawnosSoundTaskbarMusic.state;
	var send = action;
	if (action == 'toggle') { send = (state && state.playing) ? 'pause' : 'play'; }
	$.ajax({
		url: '/music/transport',
		type: 'POST',
		dataType: 'json',
		data: { target: target, action: send },
		success: function(r) {
			if (r && r.ok) { setTimeout(jawnosSoundTaskbarMusicStateLoad, 250); }
			else { jawnosSoundTaskbarFail((r && r.error) || jawnosT('Could not control that machine.')); }
		},
		error: function() { jawnosSoundTaskbarFail(jawnosT('Could not control that machine.')); }
	});
}
function jawnosSoundTaskbarMusicSection() {
	var section = $('<div class="taskbar_panel_section"></div>').attr('data-sound-section', 'music');
	section.append($('<h4></h4>').text(jawnosT('Music')));
	var transport = $('<div class="taskbar_panel_row taskbar_music_transport"></div>');
	var maker = function(action, icon, label) {
		return $('<button type="button"></button>')
			.attr('data-music-action', action)
			.attr('data-music-role', action == 'toggle' ? 'playpause' : action)
			.attr('aria-label', jawnosT(label))
			.append($('<img alt="">').attr('src', icon).attr('hint', jawnosT(label)));
	};
	var prev_icon = $('#prev_logo').attr('src') || '/icons/prev.jpg';
	var next_icon = $('#next_logo').attr('src') || '/icons/next.jpg';
	transport.append(maker('prev', prev_icon, 'Previous'));
	transport.append(maker('toggle', jawnosSoundTaskbarMusicIcon(false), 'Play'));
	transport.append(maker('next', next_icon, 'Next'));
	section.append(transport);
	var row = $('<div class="taskbar_panel_row"></div>');
	var select = $('<select class="taskbar_music_select" data-music-target></select>')
		.attr('aria-label', jawnosT('The Music app this widget controls'));
	select.append($('<option value=""></option>').text(jawnosT('This machine')));
	var target = jawnosSoundTaskbarMusicTarget();
	var target_listed = false;
	$.each(jawnosSoundTaskbarMusic.machines || [], function(i, machine) {
		if (!machine || !machine.uuid) { return; }
		if (machine.uuid == target) { target_listed = true; }
		select.append($('<option></option>').attr('value', machine.uuid).text(machine.label || machine.uuid));
	});
	// a remembered machine that has gone offline still shows as the choice; the
	// next press says it is not reachable instead of silently aiming elsewhere
	if (target && !target_listed) {
		select.append($('<option></option>').attr('value', target).text(target));
	}
	select.val(target);
	row.append(select);
	section.append(row);
	section.append($('<div class="taskbar_music_now" data-music-role="now"></div>'));
	jawnosSoundTaskbarMusicRepaint();
	return section;
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
	panel.append(jawnosSoundTaskbarLevelSection(status));
	panel.append(jawnosSoundTaskbarMusicSection());
	// the section was built off the document; paint its state once it is in reach
	setTimeout(jawnosSoundTaskbarMusicRepaint, 0);
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

$(document).on('click', '.taskbar_widget[widget="sound"]', function() {
	if (typeof jawnosTaskbarEditing === 'function' && jawnosTaskbarEditing()) { return; }
	if (typeof jawnosTaskbarPanelToggle === 'function') {
		var open = typeof jawnosTaskbarPanelIsOpen === 'function' && jawnosTaskbarPanelIsOpen('taskbar_sound_panel');
		if (!open && (!jawnosSoundTaskbarData || !jawnosSoundTaskbarData.ok)) { jawnosSoundTaskbarLoad(); }
		if (!open) {
			// refresh the peers on every open: a machine that joined since the page
			// loaded belongs in the picker, and one that left should stop showing
			jawnosSoundTaskbarMusicLoad();
			jawnosSoundTaskbarMusicStateLoad();
		}
		jawnosTaskbarPanelToggle('taskbar_sound_panel', $(this), jawnosSoundTaskbarPanelBuild);
		return;
	}
	// The frame is core, but a partial bundle should still reach the app.
	if (typeof appWindowOpener === 'function') {
		appWindowOpener('sound', Date.now(), { visible: 'yes' });
	}
});

$(document).on('wheel', '.taskbar_sound_slider', function(e) {
	return jawnosSoundTaskbarWheelEvent(e, $(this).attr('data-sound-volume'));
});

$(document).on('input', '.taskbar_sound_slider', function() {
	var kind = $(this).attr('data-sound-volume');
	var volume = jawnosSoundTaskbarPercent($(this).val());
	$('#taskbar_sound_panel [data-sound-value="' + kind + '"]').text(volume + '%');
	jawnosSoundTaskbarOptimistic(kind, volume);
});

$(document).on('change', '.taskbar_sound_slider', function() {
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

$(document).on('change', '#taskbar_sound_panel [data-sound-level]', function() {
	var level = $(this).val();
	jawnosSoundTaskbarNote('');
	$.ajax({
		url: '/manager/sound/level',
		type: 'POST',
		data: { level: level },
		success: function(status) {
			jawnosSoundTaskbarRender(status);
			jawnosSoundTaskbarPanelRefresh();
		},
		error: function() {
			jawnosSoundTaskbarFail(jawnosT('Could not change the level.'));
			jawnosSoundTaskbarLoad();
		}
	});
});

$(document).on('click', '#taskbar_sound_panel [data-music-action]', function(e) {
	e.stopPropagation();
	jawnosSoundTaskbarMusicTransport($(this).attr('data-music-action'));
});

$(document).on('change', '#taskbar_sound_panel [data-music-target]', function() {
	var target = $(this).val() || '';
	jawnosSoundTaskbarMusic.widget_target = target;
	jawnosSoundTaskbarMusic.state = null;
	$.ajax({
		url: '/music/remote_target',
		type: 'POST',
		dataType: 'json',
		data: { target: target, scope: 'widget' },
		success: function(r) {
			if (!r || !r.ok) {
				jawnosSoundTaskbarFail((r && r.error) || jawnosT('Could not remember that machine.'));
				jawnosSoundTaskbarMusicLoad();
				return;
			}
			jawnosSoundTaskbarMusicStateLoad();
			jawnosSoundTaskbarMusicRepaint();
		},
		error: function() {
			jawnosSoundTaskbarFail(jawnosT('Could not remember that machine.'));
			jawnosSoundTaskbarMusicLoad();
		}
	});
});

$(function() {
	setTimeout(jawnosSoundTaskbarLoad, 1600);
	setInterval(jawnosSoundTaskbarLoad, 45000);
	setTimeout(jawnosSoundTaskbarMusicLoad, 1900);
	// Only a panel that is on screen pays for the remote player's state.
	setInterval(function() {
		if (typeof jawnosTaskbarPanelIsOpen === 'function' && jawnosTaskbarPanelIsOpen('taskbar_sound_panel')) {
			jawnosSoundTaskbarMusicStateLoad();
		}
	}, 5000);
});
