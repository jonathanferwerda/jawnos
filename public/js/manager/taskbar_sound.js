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
var jawnosSoundTaskbarMusic = { machines: [], widget_target: '', state: null, loaded: 0, volume_timer: 0, queue: null, queue_target: '', queue_at: 0, outputs: null, outputs_target: '', devices: null, devices_target: '', devices_at: 0 };

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
			if (jawnosSoundTaskbarMusic.queue_target !== jawnosSoundTaskbarMusicTarget()) {
				jawnosSoundTaskbarMusic.queue = null;
			}
			jawnosSoundTaskbarPanelRefresh();
			jawnosSoundTaskbarMusicQueueLoad(1);
			jawnosSoundTaskbarMusicOutputsLoad(1);
			jawnosSoundTaskbarMusicDevicesLoad(1);
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
			jawnosSoundTaskbarMusicQueueLoad();
			// a Bluetooth pair or a plug appears and disappears; a slow re-read
			// keeps the device list honest without polling the sound server
			if (Date.now() - (jawnosSoundTaskbarMusic.devices_at || 0) > 30000) {
				jawnosSoundTaskbarMusicDevicesLoad();
			}
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
// The same controls live in the taskbar panel and in Sound's Remote pill, so
// one repaint serves every mounted copy.
function jawnosSoundTaskbarMusicRepaint() {
	var sections = $('[data-music-section]');
	if (!sections.length) { return; }
	var state = jawnosSoundTaskbarMusicState();
	var playing = state && state.playing ? 1 : 0;
	var remote = !!jawnosSoundTaskbarMusicTarget();
	sections.each(function() {
		var section = $(this);
		section.find('[data-music-role="playpause"] img')
			.attr('src', jawnosSoundTaskbarMusicIcon(playing))
			.attr('hint', playing ? jawnosT('Pause') : jawnosT('Play'));
		section.find('[data-music-role="playpause"]').attr('aria-label', playing ? jawnosT('Pause') : jawnosT('Play'));
		var now = (state && (state.title || state.file)) ? (state.title || '') : '';
		section.find('[data-music-role="now"]').text(now);
		// The volume row belongs to a peer's Music app; this machine's own level
		// is the house and device sliders.
		section.find('[data-music-volume]').closest('.taskbar_panel_row').toggle(remote);
		// the output belongs to the controlled machine; this machine's own
		// outputs are the house and device sliders above
		section.find('[data-music-output]').closest('.taskbar_panel_row').toggle(remote);
		// a device list needs a backend that can choose one; a phone's bridge
		// carries no such list, so the row stays away
		var devices = jawnosSoundTaskbarMusic.devices;
		var devices_ready = !!(devices && jawnosSoundTaskbarMusic.devices_target === jawnosSoundTaskbarMusicTarget()
			&& (devices.backend == 'pactl' || devices.backend == 'wpctl')
			&& devices.outputs && devices.outputs.length);
		section.find('[data-music-device]').closest('.taskbar_panel_row').toggle(remote && devices_ready);
		if (remote && state) {
			var pct = Math.round((state.muted ? 0 : (parseFloat(state.volume) || 0)) * 100);
			var slider = section.find('[data-music-volume]');
			// a slider under the person's finger must not be pulled back by a poll
			if (document.activeElement !== slider[0]) { slider.val(pct); }
			section.find('[data-music-volume-value]').text(pct + '%');
		}
		jawnosSoundTaskbarMusicPickerPaint(section);
	});
	jawnosSoundTaskbarMusicQueueCurrent();
}
// A machine that joined after the copy was built belongs in the picker, and one
// that left should stop showing. Rebuilding only when the roster changes keeps
// a poll from closing a picker someone has open.
function jawnosSoundTaskbarMusicPickerPaint(section) {
	var picker = section.find('[data-music-target]');
	if (!picker.length) { return; }
	var machines = jawnosSoundTaskbarMusic.machines || [];
	var signature = $.map(machines, function(machine) { return (machine && machine.uuid) ? machine.uuid : ''; }).join(',');
	if (picker.data('roster') !== signature) {
		picker.empty();
		picker.append($('<option value=""></option>').text(jawnosT('This machine')));
		$.each(machines, function(i, machine) {
			if (!machine || !machine.uuid) { return; }
			picker.append($('<option></option>').attr('value', machine.uuid).text(machine.label || machine.uuid));
		});
		picker.data('roster', signature);
	}
	var target = jawnosSoundTaskbarMusicTarget();
	// a remembered machine that has gone offline still shows as the choice; a
	// press says it is not reachable instead of silently aiming elsewhere
	if (target && picker.find('option[value="' + target + '"]').length === 0) {
		picker.append($('<option></option>').attr('value', target).text(target));
	}
	if (document.activeElement !== picker[0]) { picker.val(target); }
}
// The machine being controlled has its own outputs (its speaker, the server,
// and every peer it can stream to). Read them from that machine, never from
// this one, and show the one it says it is playing through.
function jawnosSoundTaskbarMusicOutputsLoad(force) {
	var target = jawnosSoundTaskbarMusicTarget();
	if (!target) {
		jawnosSoundTaskbarMusic.outputs = null;
		jawnosSoundTaskbarMusic.outputs_target = '';
		jawnosSoundTaskbarMusicOutputsPaint();
		return;
	}
	if (!force && jawnosSoundTaskbarMusic.outputs_target === target && jawnosSoundTaskbarMusic.outputs) {
		jawnosSoundTaskbarMusicOutputsPaint();
		return;
	}
	$.ajax({
		url: '/music/remote_outputs',
		type: 'GET',
		dataType: 'json',
		cache: false,
		data: { target: target },
		success: function(r) {
			if (!r || !r.ok || jawnosSoundTaskbarMusicTarget() !== target) { return; }
			jawnosSoundTaskbarMusic.outputs = r;
			jawnosSoundTaskbarMusic.outputs_target = target;
			jawnosSoundTaskbarMusicOutputsPaint();
		}
	});
}
function jawnosSoundTaskbarMusicOutputsPaint() {
	var picker = $('[data-music-output]');
	if (!picker.length) { return; }
	var target = jawnosSoundTaskbarMusicTarget();
	var data = jawnosSoundTaskbarMusic.outputs;
	if (!target || !data || jawnosSoundTaskbarMusic.outputs_target !== target || !data.outputs || !data.outputs.length) {
		picker.empty();
		return;
	}
	var signature = $.map(data.outputs, function(output) { return output.key; }).join(',');
	if (picker.data('roster') !== signature) {
		picker.empty();
		$.each(data.outputs, function(i, output) {
			if (!output || !output.key) { return; }
			picker.append($('<option></option>').attr('value', output.key).text(output.label || output.key));
		});
		picker.data('roster', signature);
	}
	if (document.activeElement !== picker[0]) { picker.val(data.current || ''); }
}
// The physical output behind the controlled machine's own speaker: its sound
// card, headphone jack or Bluetooth sink. This is the Sound app's default
// output, read from and written on that machine.
function jawnosSoundTaskbarMusicDevicesLoad(force) {
	var target = jawnosSoundTaskbarMusicTarget();
	if (!target) {
		jawnosSoundTaskbarMusic.devices = null;
		jawnosSoundTaskbarMusic.devices_target = '';
		jawnosSoundTaskbarMusic.devices_at = 0;
		jawnosSoundTaskbarMusicDevicesPaint();
		return;
	}
	if (!force && jawnosSoundTaskbarMusic.devices_target === target && jawnosSoundTaskbarMusic.devices
		&& (Date.now() - (jawnosSoundTaskbarMusic.devices_at || 0)) < 30000) {
		jawnosSoundTaskbarMusicDevicesPaint();
		return;
	}
	$.ajax({
		url: '/music/remote_devices',
		type: 'GET',
		dataType: 'json',
		cache: false,
		data: { target: target },
		success: function(r) {
			if (!r || !r.ok || jawnosSoundTaskbarMusicTarget() !== target) { return; }
			jawnosSoundTaskbarMusic.devices = r;
			jawnosSoundTaskbarMusic.devices_target = target;
			jawnosSoundTaskbarMusic.devices_at = Date.now();
			jawnosSoundTaskbarMusicDevicesPaint();
		}
	});
}
function jawnosSoundTaskbarMusicDevicesPaint() {
	var picker = $('[data-music-device]');
	if (!picker.length) { return; }
	var target = jawnosSoundTaskbarMusicTarget();
	var data = jawnosSoundTaskbarMusic.devices;
	var row = picker.closest('.taskbar_panel_row');
	if (!target || !data || jawnosSoundTaskbarMusic.devices_target !== target
		|| (data.backend != 'pactl' && data.backend != 'wpctl')
		|| !data.outputs || !data.outputs.length) {
		picker.empty();
		row.hide();
		return;
	}
	row.show();
	var signature = $.map(data.outputs, function(device) { return device.id; }).join('\u001f');
	if (picker.data('roster') !== signature) {
		picker.empty();
		$.each(data.outputs, function(i, device) {
			if (!device || !device.id) { return; }
			picker.append($('<option></option>').attr('value', device.id).text(device.label || device.id));
		});
		picker.data('roster', signature);
	}
	if (document.activeElement !== picker[0]) { picker.val(data.current || ''); }
}
// A drag is a lot of events; one POST per settle keeps the peer's player from
// being re-tuned on every pixel while still feeling immediate.
function jawnosSoundTaskbarMusicVolumeSend(level) {
	var target = jawnosSoundTaskbarMusicTarget();
	if (!target) { return; }
	if (jawnosSoundTaskbarMusic.state) {
		jawnosSoundTaskbarMusic.state.volume = level;
		if (level > 0) { jawnosSoundTaskbarMusic.state.muted = 0; }
	}
	clearTimeout(jawnosSoundTaskbarMusic.volume_timer);
	jawnosSoundTaskbarMusic.volume_timer = setTimeout(function() {
		$.ajax({
			url: '/music/transport',
			type: 'POST',
			dataType: 'json',
			data: { target: target, action: 'volume', value: level },
			success: function(r) {
				if (r && r.ok) { setTimeout(jawnosSoundTaskbarMusicStateLoad, 250); }
				else { jawnosSoundTaskbarFail((r && r.error) || jawnosT('Could not control that machine.')); }
			},
			error: function() { jawnosSoundTaskbarFail(jawnosT('Could not control that machine.')); }
		});
	}, 180);
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
// Everything below the heading: the transport, the machine picker, the peer
// volume and the now-playing line. Sound's Remote pill mounts the same block.
function jawnosSoundTaskbarMusicBuild(section) {
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
	row.append($('<select class="taskbar_music_select" data-music-target hint="The Music app this widget controls"></select>')
		.attr('aria-label', jawnosT('The Music app this widget controls')));
	section.append(row);
	var outputs = $('<div class="taskbar_panel_row taskbar_music_outputs"></div>');
	outputs.append($('<span class="taskbar_music_output_label"></span>').text(jawnosT('Output')));
	outputs.append($('<select class="taskbar_music_select" data-music-output hint="The output the controlled machine plays through"></select>')
		.attr('aria-label', jawnosT('The output the controlled machine plays through')));
	section.append(outputs);
	var devices = $('<div class="taskbar_panel_row taskbar_music_devices"></div>');
	devices.append($('<span class="taskbar_music_output_label"></span>').text(jawnosT('Device')));
	devices.append($('<select class="taskbar_music_select" data-music-device hint="The speaker, headphones or Bluetooth device the controlled machine plays through"></select>')
		.attr('aria-label', jawnosT('The speaker, headphones or Bluetooth device the controlled machine plays through')));
	section.append(devices);
	var volume = $('<div class="taskbar_panel_row taskbar_music_volume"></div>');
	volume.append($('<input type="range" class="taskbar_sound_slider" min="0" max="100" step="1" hint="The volume of the Music app this widget controls">')
		.attr('data-music-volume', '')
		.attr('aria-label', jawnosT('The volume of the Music app this widget controls')));
	volume.append($('<span class="taskbar_panel_value"></span>').attr('data-music-volume-value', ''));
	section.append(volume);
	section.append($('<div class="taskbar_music_now" data-music-role="now"></div>'));
	jawnosSoundTaskbarMusicPickerPaint(section);
	return section;
}
function jawnosSoundTaskbarMusicSection() {
	var section = $('<div class="taskbar_panel_section"></div>')
		.attr('data-sound-section', 'music')
		.attr('data-music-section', '');
	section.append($('<h4></h4>').text(jawnosT('Music')));
	jawnosSoundTaskbarMusicBuild(section);
	jawnosSoundTaskbarMusicRepaint();
	return section;
}
// Sound's Remote pill mounts the same block into its own body once, when the
// window opens; the shares target, state and handlers make the two copies act
// as one.
function jawnosSoundTaskbarMusicMount(target) {
	var box = $(target);
	if (!box.length || box.data('music_mounted')) { return; }
	box.data('music_mounted', 1);
	jawnosSoundTaskbarMusicBuild(box);
	box.append($('<div class="sound_remote_tracks" data-remote-tracks></div>'));
	jawnosSoundTaskbarMusicLoad();
	jawnosSoundTaskbarMusicStateLoad();
	jawnosSoundTaskbarMusicQueueLoad(1);
	jawnosSoundTaskbarMusicOutputsLoad(1);
	jawnosSoundTaskbarMusicDevicesLoad(1);
}
// A short list of the controlled machine's own queue, so the Sound window can
// switch tracks without opening that machine's Music window.
function jawnosSoundTaskbarMusicQueueLoad(force) {
	var target = jawnosSoundTaskbarMusicTarget();
	var box = $('[data-remote-tracks]');
	if (!target || !box.length) {
		jawnosSoundTaskbarMusic.queue = null;
		jawnosSoundTaskbarMusic.queue_target = '';
		jawnosSoundTaskbarMusicQueuePaint();
		return;
	}
	var now = Date.now();
	if (!force && jawnosSoundTaskbarMusic.queue_target === target
		&& (now - (jawnosSoundTaskbarMusic.queue_at || 0)) < 30000) { return; }
	$.ajax({
		url: '/music/remote_queue',
		type: 'GET',
		dataType: 'json',
		cache: false,
		data: { target: target },
		success: function(r) {
			if (!r || !r.ok || jawnosSoundTaskbarMusicTarget() !== target) { return; }
			jawnosSoundTaskbarMusic.queue = r;
			jawnosSoundTaskbarMusic.queue_target = target;
			jawnosSoundTaskbarMusic.queue_at = Date.now();
			jawnosSoundTaskbarMusicQueuePaint();
		}
	});
}
function jawnosSoundTaskbarMusicQueuePaint() {
	var box = $('[data-remote-tracks]');
	if (!box.length) { return; }
	var q = jawnosSoundTaskbarMusic.queue;
	box.empty();
	if (!q || !q.songs || !q.songs.length) {
		box.append($('<p class="sound_remote_track_note"></p>').text(jawnosT('No list from that machine.')));
		return;
	}
	$.each(q.songs, function(i, song) {
		if (!song || !song.file) { return; }
		var row = $('<button type="button" class="sound_remote_track"></button>')
			.attr('data-remote-track', song.file)
			.attr('title', song.title || song.file);
		row.append($('<span class="sound_remote_track_title"></span>').text(song.title || ''));
		if (song.album) { row.append($('<span class="sound_remote_track_album"></span>').text(song.album)); }
		box.append(row);
	});
	if (q.total > q.count) {
		box.append($('<p class="sound_remote_track_note"></p>')
			.text(jawnosT('Showing') + ' ' + q.count + ' ' + jawnosT('of') + ' ' + q.total));
	}
	jawnosSoundTaskbarMusicQueueCurrent();
}
function jawnosSoundTaskbarMusicQueueCurrent() {
	var current = (jawnosSoundTaskbarMusic.state && jawnosSoundTaskbarMusic.state.file) || '';
	$('[data-remote-track]').each(function() {
		$(this).toggleClass('is-current', !!current && $(this).attr('data-remote-track') === current);
	});
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

// These three are the house and device levels. They bind a slider that names
// its device: the Music section's peer volume wears the same slider style but no
// data-sound-volume, and an unnamed kind used to fall through to this machine's
// output, so dragging the peer's bar moved the local volume and posted it.
$(document).on('wheel', '.taskbar_sound_slider[data-sound-volume]', function(e) {
	return jawnosSoundTaskbarWheelEvent(e, $(this).attr('data-sound-volume'));
});

$(document).on('input', '.taskbar_sound_slider[data-sound-volume]', function() {
	var kind = $(this).attr('data-sound-volume');
	var volume = jawnosSoundTaskbarPercent($(this).val());
	$('#taskbar_sound_panel [data-sound-value="' + kind + '"]').text(volume + '%');
	jawnosSoundTaskbarOptimistic(kind, volume);
});

$(document).on('change', '.taskbar_sound_slider[data-sound-volume]', function() {
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

$(document).on('click', '[data-music-section] [data-music-action]', function(e) {
	e.stopPropagation();
	jawnosSoundTaskbarMusicTransport($(this).attr('data-music-action'));
});
$(document).on('input', '[data-music-section] [data-music-volume]', function() {
	var pct = Math.round(parseFloat(this.value) || 0);
	$(this).closest('.taskbar_panel_row').find('[data-music-volume-value]').text(pct + '%');
	jawnosSoundTaskbarMusicVolumeSend(pct / 100);
});

$(document).on('click', '[data-remote-track]', function(e) {
	e.stopPropagation();
	var file = $(this).attr('data-remote-track');
	var target = jawnosSoundTaskbarMusicTarget();
	if (!file || !target) { return; }
	// One file: the host keeps its own queue, the tracks already played included,
	// and starts this row in it.
	$('[data-remote-track]').removeClass('is-current');
	$(this).addClass('is-current');
	$.ajax({
		url: '/music/transport',
		type: 'POST',
		dataType: 'json',
		data: { target: target, action: 'play_track', file: file },
		success: function(r) {
			if (r && r.ok) {
				setTimeout(jawnosSoundTaskbarMusicStateLoad, 400);
				setTimeout(function() { jawnosSoundTaskbarMusicQueueLoad(1); }, 1200);
			}
			else { jawnosSoundTaskbarFail((r && r.error) || jawnosT('Could not control that machine.')); }
		},
		error: function() { jawnosSoundTaskbarFail(jawnosT('Could not control that machine.')); }
	});
});

$(document).on('change', '[data-music-section] [data-music-target]', function() {
	var target = $(this).val() || '';
	jawnosSoundTaskbarMusic.widget_target = target;
	jawnosSoundTaskbarMusic.state = null;
	jawnosSoundTaskbarMusic.outputs = null;
	jawnosSoundTaskbarMusic.outputs_target = '';
	jawnosSoundTaskbarMusic.devices = null;
	jawnosSoundTaskbarMusic.devices_target = '';
	jawnosSoundTaskbarMusic.devices_at = 0;
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
			jawnosSoundTaskbarMusicQueueLoad(1);
			jawnosSoundTaskbarMusicOutputsLoad(1);
			jawnosSoundTaskbarMusicDevicesLoad(1);
		},
		error: function() {
			jawnosSoundTaskbarFail(jawnosT('Could not remember that machine.'));
			jawnosSoundTaskbarMusicLoad();
		}
	});
});

$(document).on('change', '[data-music-section] [data-music-output]', function() {
	var output = $(this).val() || '';
	var target = jawnosSoundTaskbarMusicTarget();
	if (!output || !target) { return; }
	$.ajax({
		url: '/music/remote_output',
		type: 'POST',
		dataType: 'json',
		data: { target: target, output: output },
		success: function(r) {
			if (!r || !r.ok) {
				jawnosSoundTaskbarFail((r && r.error) || jawnosT('Could not control that machine.'));
				jawnosSoundTaskbarMusicOutputsLoad(1);
				return;
			}
			if (jawnosSoundTaskbarMusic.outputs) { jawnosSoundTaskbarMusic.outputs.current = output; }
			jawnosSoundTaskbarMusicOutputsPaint();
			setTimeout(function() { jawnosSoundTaskbarMusicOutputsLoad(1); }, 600);
		},
		error: function() {
			jawnosSoundTaskbarFail(jawnosT('Could not control that machine.'));
			jawnosSoundTaskbarMusicOutputsLoad(1);
		}
	});
});

$(document).on('change', '[data-music-section] [data-music-device]', function() {
	var id = $(this).val() || '';
	var target = jawnosSoundTaskbarMusicTarget();
	if (!id || !target) { return; }
	$.ajax({
		url: '/music/remote_device',
		type: 'POST',
		dataType: 'json',
		data: { target: target, id: id },
		success: function(r) {
			if (!r || !r.ok) {
				jawnosSoundTaskbarFail((r && r.error) || jawnosT('Could not control that machine.'));
				jawnosSoundTaskbarMusicDevicesLoad(1);
				return;
			}
			if (jawnosSoundTaskbarMusic.devices) { jawnosSoundTaskbarMusic.devices.current = id; }
			jawnosSoundTaskbarMusicDevicesPaint();
			setTimeout(function() { jawnosSoundTaskbarMusicDevicesLoad(1); }, 900);
		},
		error: function() {
			jawnosSoundTaskbarFail(jawnosT('Could not control that machine.'));
			jawnosSoundTaskbarMusicDevicesLoad(1);
		}
	});
});

$(function() {
	setTimeout(jawnosSoundTaskbarLoad, 1600);
	setInterval(jawnosSoundTaskbarLoad, 45000);
	setTimeout(jawnosSoundTaskbarMusicLoad, 1900);
	// Only a panel that is on screen pays for the remote player's state.
	setInterval(function() {
		if ((typeof jawnosTaskbarPanelIsOpen === 'function' && jawnosTaskbarPanelIsOpen('taskbar_sound_panel'))
			|| $('#sound_section_remote.is-active').length) {
			jawnosSoundTaskbarMusicStateLoad();
		}
	}, 5000);
});
