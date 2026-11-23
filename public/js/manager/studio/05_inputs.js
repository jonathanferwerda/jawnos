var studio_jw_deg =  0;
var studio_last = 'out';
$(document).on('touchmove mousemove', '#studio_jog_wheel', function(e) {
	e.preventDefault();			e.preventDefault();
	// a recording owns the playhead, so the wheel neither turns nor seeks
	if (!studioCanSeek()) { studio_last = 'out'; return; }
	var j = $(this);
	var jc = j.closest('.jog_wheel_frame').find('.jog_wheel_centre');
	if (e.which === 1 || e.originalEvent.type == 'touchmove') {
		var x = e.originalEvent.clientX;
		var y = e.originalEvent.clientY;
		if (e.originalEvent.targetTouches) {
			x = e.originalEvent.targetTouches[0].clientX;
			y = e.originalEvent.targetTouches[0].clientY;
		}
		var middle_x = numeral(jc.offset().left + (jc.width() / 2)).value();
		var middle_y = numeral(jc.offset().top + (jc.height() / 2)).value();
		var deltaX = middle_x - x;
		var deltaY = middle_y - y;
		var rad = Math.atan2(deltaY, deltaX); 
		var deg = rad * (180 / Math.PI) - 90;
		var diff = 0;
		if (studio_last == 'in') {
			diff = (deg - studio_jw_deg);
		}
		studio_jw_deg = (studio_jw_deg + diff);
		j.css({'rotate': studio_jw_deg + 'deg' });
		studio_last = 'in';
		mixer['time']['position'] = mixer['time']['position'] + diff / 10;
		studioTime('scroll');
	}
});
$(document).on('mouseout touchend mouseup', '#studio_jog_wheel', function() {
	studio_last = 'out';
});

// (the jog wheel's wheel is handled by studioWheelHandler)

$(document).on('click', '#studio_video_toggle', function() {
	var toggle = $(this).attr('toggled');

	if (toggle == 'on') {
		toggle = 'off';
	}
	else {
		toggle = 'on';
	}
	$(this).attr('toggled', toggle);
	studioSaver();
});

$(document).on('click', '#studio_record', function() {
	if (mixer['time']['status'] != 'record' && mixer['time']['status'] != 'play') {
		studioRecord();
		mixer['time']['status'] = 'record';
	}
});

$(document).on('click', '.armed',function() {
	var armed = $(this);
	var state = armed.attr('state');
	var channel = armed.attr('channel');
	if (state == 'off') {
		armed.attr('state', 'rec');
		armed.text('R');
	}
	else if (state == 'rec') {
		armed.attr('state', 'play');
		armed.text('P');
	}
	else if (state == 'play') {
		armed.attr('state', 'loop');
		armed.text('L');
	}
	else {
		armed.attr('state', 'off');
		armed.text('O');
	}
	studioSaver();
	state = armed.attr('state');
	// playback reads the armed state from mixer, so keep it in step with the
	// button instead of waiting for the next load
	if (!mixer[channel]) { mixer[channel] = {}; }
	mixer[channel].armed = { state: state, text: armed.text() };
	studioInputStreamGrabber(channel,state);
	// A monitored app keeps its graph when the arm button leaves it unarmed;
	// this only re-applies the choice, so it never starts a take.
	if (typeof studioApplyMonitor === 'function') { studioApplyMonitor(); }
	studioDrawTracks();
});

$(document).on('click', '.studio_jack', function() {
	var j = $(this);
	var channel = j.attr('channel');
	channelSelect(channel,'input');
});

$(document).on('click', '.studio_cord', function() {
	var j = $(this);
	var channel = j.attr('channel');
	channelSelect(channel,'output');
});

// The channel's Screen Share plug gains the desktop app's screen and window
// list. A plain browser has no bridge and keeps getDisplayMedia's own picker.
function studioScreenSourceFill(panel, information) {
	if (!panel || !panel.length) { return null; }
	var row = panel.find('.studio_plug_selection[type="screen_share"]').first();
	if (!row.length) { return null; }
	if (typeof JawnScreen === 'undefined' || !JawnScreen.available()) { return null; }
	var select = $('<select class="studio_screen_source"></select>')
		.attr('hint', studioAudioLabel('Which screen or window to share'));
	// The plug list is a table: the chosen source sits in its own row so the
	// markup stays valid.
	var holder = $('<tr class="studio_screen_source_row"></tr>')
		.append($('<td colspan="2"></td>')
			.css({ padding: '4px 0 4px 24px' })
			.append(select));
	row.after(holder);
	return JawnScreen.refresh().then(function (rows) {
		var groups = {};
		(rows || []).forEach(function (source) {
			var word = (source.kind === 'window') ? 'Windows' : 'Screens';
			if (!groups[word]) {
				groups[word] = $('<optgroup></optgroup>')
					.attr('label', studioAudioLabel(word));
				select.append(groups[word]);
			}
			groups[word].append($('<option></option>')
				.val(source.id)
				.text(source.label || source.name || source.id));
		});
		if (!rows || !rows.length) {
			select.append($('<option></option>').val('')
				.text(studioAudioLabel('Entire screen')));
		}
		if (information && information.type === 'screen_share' && information.screen) {
			select.val(String(information.screen));
		}
	});
}

function studioScreenSourceValue(panel) {
	var select = panel ? panel.find('.studio_screen_source').first() : $();
	if (!select.length) { return { id: '', name: '' }; }
	var option = select.find('option:selected');
	return { id: select.val() || '', name: option.text() || '' };
}

// The input picker also names which of this machine's capture sources the
// channel's input uses. The plan is the source of truth: the picker opens on
// the saved node, and choosing another saves it on the plan's input source for
// that device channel, so the engine - not the browser - captures it.
$(document).on('change', '.studio_input_node', function() {
	var select = $(this);
	var input = Number(select.attr('input'));
	if (!isFinite(input) || input < 0) { input = 0; }
	var option = select.find('option:selected');
	var name = option.text() || '';
	var note = select.closest('td').find('.studio_input_node_note');
	$.ajax({
		url: '/manager/studio/input/node',
		type: 'POST',
		data: { channel: Math.floor(input), node: select.val() || '' },
		success: function(result) {
			result = result || {};
			if (result.ok) {
				note.text(select.val()
					? jawnosT('The input source is saved') + ': ' + name
					: jawnosT('The input source is saved'));
			}
			else {
				note.text(result.error || jawnosT('The input source could not be saved'));
			}
		},
		error: function() { note.text(jawnosT('The input source could not be saved')); }
	});
});

// What a channel's input jack is connected to, as the chooser stored it. An
// empty or unreadable plug means no input is chosen.
function studioChannelInput(ch) {
	var info = $('.studio_channel_information[direction="input"][channel="' + ch + '"]');
	if (!isJson(info.text())) { return null; }
	var plug;
	try { plug = JSON.parse(info.text()); }
	catch (e) { return null; }
	if (!plug || (!plug['type'] && !plug['app'])) { return null; }
	return plug;
}

// The saved plug on either jack.
function studioPlugInfo(ch, direction) {
	var info = $('.studio_channel_information[direction="' + direction + '"][channel="' + ch + '"]');
	if (!isJson(info.text())) { return null; }
	var plug;
	try { plug = JSON.parse(info.text()); }
	catch (e) { return null; }
	if (!plug || (!plug['type'] && !plug['app'])) { return null; }
	return plug;
}

function studioPlugSetInfo(ch, direction, plug) {
	$('.studio_channel_information[direction="' + direction + '"][channel="' + ch + '"]')
		.text(plug ? JSON.stringify(plug) : '');
}

// Mark the row the saved plug names and set the device's Input 1/Input 2 picker
// to the number the plug carries. Reopening a jack therefore shows the same
// choice it showed when it was made.
function studioPlugSelectHighlight(panel, information) {
	if (!panel || !panel.length || !information) { return; }
	var type = information['type'] || (information['app'] ? 'app' : '');
	if (!type) { return; }
	var rows = panel.find('.studio_plug_selection');
	var chosen = $();
	if (type === 'app') {
		chosen = rows.filter(function () {
			return $(this).attr('type') === 'app' && String($(this).attr('app')) === String(information['app'] || '');
		});
	}
	else if (type === 'channel') {
		var channel_sid = (information['sid'] !== undefined && information['sid'] !== '')
			? information['sid'] : information['id'];
		chosen = rows.filter(function () {
			return $(this).attr('type') === 'channel' && String($(this).attr('sid')) === String(channel_sid || '');
		});
	}
	else if (type === 'screen_share') {
		chosen = rows.filter('[type="screen_share"]');
	}
	else if (type === 'usermedia') {
		var id = information['id'] || '';
		var av = information['av'] || 'a';
		chosen = rows.filter(function () {
			var row = $(this);
			if (row.attr('type') !== 'usermedia' || String(row.attr('av')) !== String(av)) { return false; }
			if (!id) { return true; }
			return String(row.attr('sid')) === String(id);
		}).first();
	}
	rows.removeClass('studio_plug_active active_background');
	if (!chosen.length) { return; }
	chosen.addClass('studio_plug_active');
	if (type === 'usermedia' && information['av'] === 'a') {
		var input = Number(information['input']) || 0;
		if (input < 0) { input = 0; }
		if (input > 1) { input = 1; }
		chosen.find('.studio_input_channel').val(String(input));
	}
}

function studioPlugSelectNote(text) {
	var panel = $('#studio_plug_select');
	if (!panel.length) { return; }
	panel.find('.studio_plug_note').remove();
	$('<div class="studio_plug_note"></div>').text(studioAudioLabel(text)).appendTo(panel);
}

// A channel send is one edge written on both jacks: the source's output names
// the destination, and the destination's input names the source. Choosing it
// from either picker therefore means exactly the same thing.
function studioPlugSendSet(source, dest) {
	source = String(source);
	dest = String(dest);
	if (!source || !dest || source === dest) { return false; }
	if (typeof studioChannelOutputCycle === 'function' && studioChannelOutputCycle(source, dest)) { return false; }
	studioPlugSendClearFrom(source);
	studioPlugSendClearInto(dest);
	studioPlugSetInfo(source, 'output', {
		channel: source, direction: 'output', id: dest, sid: dest, type: 'channel', av: 'a', app: ''
	});
	studioPlugSetInfo(dest, 'input', {
		channel: dest, direction: 'input', id: source, sid: source, type: 'channel', av: 'a', app: ''
	});
	// The destination now takes the send, not its old device or app. Release
	// that capture before the new edge becomes its input.
	if (typeof studioInputStreamGrabber === 'function') { studioInputStreamGrabber(dest, 'off'); }
	if (typeof studioChannelEngine === 'function') {
		studioChannelEngine(source);
		studioChannelEngine(dest);
	}
	if (typeof studioRebuildOutputs === 'function') { studioRebuildOutputs(source); }
	return true;
}

// Drop a source's old send, including the destination's mirrored input, before
// the source is given another output.
function studioPlugSendClearFrom(source) {
	if (typeof studioChannelOutputInfo !== 'function') { return; }
	var old = studioChannelOutputInfo(source);
	if (!old || old['type'] !== 'channel' || !old['sid']) { return; }
	var dest = String(old['sid']);
	var input = studioPlugInfo(dest, 'input');
	if (input && input['type'] === 'channel' && String(input['sid']) === String(source)) {
		studioPlugSetInfo(dest, 'input', null);
		if (typeof studioInputStreamGrabber === 'function') { studioInputStreamGrabber(dest, 'off'); }
	}
}

// Drop any incoming send into a destination before the destination is given a
// device or app input of its own.
function studioPlugSendClearInto(dest) {
	if (typeof studioChannelOutputInfo !== 'function') { return; }
	$.each(studioAudio.channels, function (src) {
		if (String(src) === String(dest)) { return; }
		var out = studioChannelOutputInfo(src);
		if (out && out['type'] === 'channel' && String(out['sid']) === String(dest)) {
			studioPlugSetInfo(src, 'output', null);
			if (typeof studioRebuildOutputs === 'function') { studioRebuildOutputs(src); }
		}
	});
}

// Marker, Music, Synth and Drums already play in this page, so their post-FX
// signal is the browser's tap, never a microphone.
function studioInputIsApp(plug) {
	if (!plug) { return false; }
	return ['marker', 'music', 'synth', 'drums'].indexOf(String(plug['app'] || '')) !== -1;
}

// A real audio device is the input the engine's own Listen can open. A camera
// or a screen share has no engine channel, so it stays on the browser tap.
function studioInputIsDevice(plug) {
	return !!(plug && plug['type'] == 'usermedia' && plug['av'] == 'a');
}

// The engine's Listen channel for a real input: Input 1 is 0 and Input 2 is 1,
// matching the device's number in the plug list. Older songs stored no number,
// so the first input is the fallback.
function studioInputListenChannel(plug) {
	var n = plug ? Number(plug['input']) : 0;
	if (!isFinite(n) || n < 0) { return 0; }
	n = Math.floor(n);
	// The interface has two inputs; an older saved plug stored a device index,
	// so anything past the second input is Input 2 rather than a third channel.
	return n > 1 ? 1 : n;
}

async function channelSelect(channel,direction) {
	var sis = $('#studio_plug_select_container');
	if ($('#studio_plug_select[channel="' + channel + '"][direction="' + direction + '"]').is(':visible')) {
		sis.hide();
	} else {
		var m = mouse_position();
		var x = m.x;
		var y = m.y;

		var constraints = await constraintMaker({ video: true, audio: true });
		var options = { 'surfaceSwitching': 'include', 'audio': true, 'video': { 'displaySurface': 'monitor' }};
		var screenShare = !!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia);
		console.log(screenShare);
		console.log(constraints);
		var eligibleApps = [ 
			{ app: 'music', id: 'video', av: 'av' },
			{ app: 'marker', id: 'whiteboard', av: 'v' },
			{ app: 'synth', id: 'synthesizer', direction: 'input', av: 'a' },
			{ app: 'drums', id: 'drums', direction: 'input', av: 'a' }
		];

		var information = {};
		var sci = $('.studio_channel_information[direction="' + direction + '"][channel="' + channel + '"]');
		if (isJson(sci.text())) {
			information = JSON.parse(sci.text());
		}

		// Every other track is a possible channel send, whichever way this jack
		// faces: an output can name a destination, an input can name a source.
		var other_channels = [];
		if (typeof studioTrackNumbers === 'function') {
			other_channels = studioTrackNumbers().filter(function (n) {
				return String(n) !== String(channel);
			}).map(String);
		}

		var data = { 
			channel: channel, 
			constraints: JSON.stringify(constraints),
			screenShare: screenShare,
			mouse: m,
			apps: JSON.stringify(eligibleApps),
			channels: JSON.stringify(other_channels),
			direction: direction,
			information: information
		};
		console.log(data);	
		$.ajax({
			url: '/manager/studio/plug/select',
			type: 'GET',
			data: data,
			success: function(response) {
				sis.html(response.html).show();
				// The screen-share row is part of the panel's height: add it
				// before measuring so the clamp sees the box that is drawn.
				studioScreenSourceFill(sis, information);
				// The jack reopens on the row it was left on, not an unmarked list.
				studioPlugSelectHighlight(sis, information);
				// Measure the finished panel, then clamp it to the window. It is
				// position:fixed, so left/top are viewport coordinates; when the
				// panel is wider or taller than the window it pins to the 8px
				// margin and the stylesheet's overflow does the scrolling.
				sis.css({ 'width': '', 'height': '' });
				var width = sis.outerWidth();
				var height = sis.outerHeight();
				sis.css({
					'left': Math.max(8, Math.min(x + 20, $(window).width() - width - 8)),
					'top': Math.max(8, Math.min(y, $(window).height() - height - 8)),
					'right': '',
					'bottom': ''
				});

				appointment_chron();
			}
		});
	}
}

$(document).on('click', '.close_plug_select', function() {
	var sis = $('#studio_plug_select_container');
	sis.hide();
});

$(document).on('change', '.studio_screen_source', function() {
	var panel = $(this).closest('#studio_plug_select');
	var channel = panel.attr('channel');
	var info = $('.studio_channel_information[direction="input"][channel="' + channel + '"]');
	if (!isJson(info.text())) { return; }
	var data = JSON.parse(info.text());
	if (data.type != 'screen_share') { return; }
	var source = studioScreenSourceValue(panel);
	data.screen = source.id;
	data.screen_name = source.name;
	info.text(JSON.stringify(data));
	studioSaver();
});

// A device row carries its own Input 1/Input 2 picker. Clicking the picker must
// not choose the row (that would save the channel before it is changed), and
// changing it on an already chosen device updates the channel the engine uses.
$(document).on('click', '.studio_input_channel', function(event) {
	event.stopPropagation();
});

$(document).on('change', '.studio_input_channel', function() {
	var select = $(this);
	var channel = select.closest('.studio_plug_selection').attr('channel');
	var info = $('.studio_channel_information[direction="input"][channel="' + channel + '"]');
	if (!isJson(info.text())) { return; }
	var data = JSON.parse(info.text());
	if (!(data.type == 'usermedia' && data.av == 'a')) { return; }
	var input = Number(select.val()) || 0;
	if (input < 0) { input = 0; }
	if (input > 1) { input = 1; }
	data.input = input;
	info.text(JSON.stringify(data));
	studioSaver();
});

$(document).on('click', '.studio_plug_selection', function() {
	var sis = $(this);
	var channel = sis.attr('channel');
	var direction = sis.attr('direction');
	var id = String(sis.attr('sid') || '');
	var type = sis.attr('type');
	var av = sis.attr('av');
	var app = sis.attr('app');
	var screen = (type == 'screen_share')
		? studioScreenSourceValue(sis.closest('#studio_plug_select')) : { id: '', name: '' };
	$('.studio_plug_selection[direction="' + direction + '"][channel="' + channel + '"]').removeClass('studio_plug_active active_background');
	// A channel row is one edge between two channels, not a device plug. The
	// output picker names the destination; the input picker names the source.
	if (type === 'channel') {
		var source = (direction === 'output') ? String(channel) : id;
		var dest = (direction === 'output') ? id : String(channel);
		if (!studioPlugSendSet(source, dest)) {
			studioPlugSelectNote('That route would feed a channel back into itself');
			return;
		}
		studioSaver();
		studioRetriever();
		return;
	}
	// Choosing a real input or output ends any channel send on that jack, so a
	// device and a send can never feed the same chain together.
	if (direction == 'input') { studioPlugSendClearInto(channel); }
	else if (direction == 'output') { studioPlugSendClearFrom(channel); }
	// The row's own picker names which interface input the channel takes: the
	// UM2's Input 1 is channel 0 and Input 2 is channel 1. Keep that number with
	// the plug so Monitor can start the engine on the same input without the
	// list being open.
	var input = 0;
	if (direction == 'input' && type == 'usermedia' && av == 'a') {
		input = Number(sis.find('.studio_input_channel').val()) || 0;
		if (input < 0) { input = 0; }
		if (input > 1) { input = 1; }
	}
	var data = {
		channel: channel,
		direction: direction,
		id: id,
		type: type,
		av: av,
		app: app
	}
	if (direction == 'input' && type == 'usermedia' && av == 'a') { data.input = input; }
	if (screen.id) { data.screen = screen.id; }
	if (screen.name) { data.screen_name = screen.name; }
	var jinfo = JSON.stringify(data);

	$('.studio_channel_information[direction="' + direction + '"][channel="' + channel + '"]').text(jinfo);
	var chosen = $('.studio_plug_selection[direction="' + direction + '"][channel="' + channel + '"][type="' + type + '"][sid="' + id + '"][av="' + av + '"][app="' + app + '"]');
	chosen.addClass('studio_plug_active');
	if (direction == 'output' && typeof studioRebuildOutputs === 'function') { studioRebuildOutputs(channel); }
	studioInputStreamGrabber(channel,'off')
	studioSaver();
	studioRetriever();
});

// A native engine opens a real device itself. While it monitors that device,
// the browser capture is released so one input is not opened twice; a track
// armed to record reopens it when the monitor stops. An app input never starts
// the engine, so its browser graph stays connected and is the monitor.
var studioMonitorInputReleased = false;

function studioInputReleaseForMonitor() {
	if (studioMonitorInputReleased) { return; }
	studioMonitorInputReleased = true;
	$.each(studioAudio.channels, function (ch) {
		var m = mixer[ch] && mixer[ch].media;
		if (!m || !m.inRaw) { return; }
		m.inRaw.getTracks().forEach(function (track) { track.stop(); });
		m.inRaw = undefined;
		m.in = null;
		m.active = false;
		studioDetachInput(ch);
		clearInterval(m.in_analyzer_timeout);
	});
}

function studioInputResumeAfterMonitor() {
	if (!studioMonitorInputReleased) { return; }
	studioMonitorInputReleased = false;
	$('.studio_track').each(function () {
		var ch = String($(this).attr('data-channel'));
		var state = $('.studio_track_arm[channel="' + ch + '"]').attr('state');
		if (state === 'rec' || state === 'loop') { studioInputStreamGrabber(ch, state); }
	});
}

// Attach one app input (Marker, Music, Synth or Drums) to a channel and mark
// the media active. This is the only place an app graph is built, so Monitor
// and the arm button share one definition and neither opens a device.
function studioAttachAppInput(ch, plug) {
	ch = String(ch);
	if (!plug || !studioInputIsApp(plug)) { return null; }
	if (!mixer[ch]) { mixer[ch] = {}; }
	if (!mixer[ch].media) { mixer[ch].media = {}; }
	if (!mixer[ch].media.out) { mixer[ch].media.out = []; }
	if (!mixer[ch].media.rec) { mixer[ch].media.rec = []; }
	// Marker and Music are the whiteboard canvas and the player's #video
	// element: capture their own streams instead of opening a device.
	if (plug['app'] == 'marker') {
		var whiteboard = document.getElementById('whiteboard');
		if (!whiteboard || !whiteboard.captureStream) {
			console.log('studio: Marker is not open, so there is no canvas to record');
			mixer[ch].media.active = false;
			return null;
		}
		var markerStream;
		try { markerStream = whiteboard.captureStream(30); }
		catch (e) { markerStream = null; }
		if (!markerStream || !markerStream.getTracks().length) {
			console.log('studio: the Marker canvas has no picture yet');
			mixer[ch].media.active = false;
			return null;
		}
		return studioAttachCapturedStream(ch, markerStream);
	}
	if (plug['app'] == 'music') {
		var player = document.getElementById('video');
		if (!player || !player.captureStream) {
			console.log('studio: Music is not open, so there is no video to record');
			mixer[ch].media.active = false;
			return null;
		}
		var musicStream;
		try { musicStream = player.captureStream(); }
		catch (e) { musicStream = null; }
		if (!musicStream || !musicStream.getTracks().length) {
			console.log('studio: Music has no playing picture to record');
			mixer[ch].media.active = false;
			return null;
		}
		return studioAttachCapturedStream(ch, musicStream);
	}
	// The synth and the drums are app buses with no device behind them: route
	// them through the channel's tone stack and pedals like any other source.
	var stream = (plug['app'] == 'synth') ? studioAttachSynth(ch) : studioAttachDrums(ch);
	if (!stream) { mixer[ch].media.active = false; return null; }
	mixer[ch].media.active = true;
	mixer[ch].media.in = stream;
	mixer[ch].media.video = false;
	clearInterval(mixer[ch].media.in_analyzer_timeout);
	mixer[ch].media.in_analyzer_timeout = setInterval(function() {
		if (document.hidden) { return; }
		studioDrawChannel(ch);
		studioDrawMetre(ch);
	}, 40);
	return stream;
}

async function studioInputStreamGrabber(channel,state) {
	var ch = channel;
	if (!mixer[ch]) { mixer[ch] = {}; }
	if (!mixer[ch].media) { mixer[ch].media = {}; }
	if (!mixer[ch].media.out) { mixer[ch].media.out = []; }
	if (!mixer[ch].media.rec) { mixer[ch].media.rec = []; }

	// An armed channel keeps its input open for rec *and* loop: loop is the
	// looper state, so it has to be able to capture the sample it repeats.
	if (state != 'rec' && state != 'loop') {
		if (mixer[ch].media.inRaw) {
			mixer[ch].media.inRaw.getTracks().forEach(function(track) { track.stop(); });
		}
		mixer[ch].media.inRaw = undefined;
		mixer[ch].media.in = null;
		mixer[ch].media.active = false;
		studioDetachInput(ch);
		clearInterval(mixer[ch].media.in_analyzer_timeout);
		$('#studio_video_monitor_' + ch).hide();
		return;
	}

	if (mixer[ch].media.active) { return; }

	// A channel send is already wired from the source's output into this
	// channel's tone stack. Nothing opens here; the input chain's own recDest is
	// what a take records, and Monitor hears the same post-pedal signal.
	var channel_plug = studioChannelInput(ch);
	if (channel_plug && channel_plug['type'] === 'channel') {
		var routed = studioChannelEngine(ch);
		mixer[ch].media.active = true;
		mixer[ch].media.video = false;
		mixer[ch].media.in = (routed && routed.recDest) ? routed.recDest.stream : null;
		return mixer[ch].media.in;
	}

	// If the channel has an input plug selected, honour its audio/video kind, but
	// default to audio only: the camera is requested only when the plug is a
	// video source ('av' = a camera or video app, 'v' = the marker). Nothing
	// chosen means no camera.
	var info = $('.studio_channel_information[direction="input"][channel="' + ch + '"]');
	var plug = isJson(info.text()) ? JSON.parse(info.text()) : {};
	var video = (plug['av'] == 'av' || plug['av'] == 'v');
	// The plug list's screen row is a display capture, not a camera: it asks
	// for the chosen screen or window (the desktop app supplies the list)
	// rather than getUserMedia for a video device.
	var screen_share = (plug['type'] == 'screen_share');

	// Marker, Music, Synth and Drums already play on this page. Their graph is
	// built without opening a device; a closed app has nothing to offer.
	if (studioInputIsApp(plug)) { return studioAttachAppInput(ch, plug); }

	var audio = {
		echoCancellation: false,  // Disables echo suppression
		noiseSuppression: false,  // Disables background noise dampening
		autoGainControl: false   // Prevents the browser from auto-adjusting volume
	};
	var sample_rate = studioSampleRate();
	if (sample_rate > 0) { audio.sampleRate = sample_rate; }
	var channels = studioSettingNumber('audio_channels', 0);
	if (channels > 0) { audio.channelCount = channels; }
	// A real input is opened by the device the picker names, camera or
	// microphone. Both interface inputs are captured for an audio device so the
	// channel can take Input 1 or Input 2. A screen share keeps getDisplayMedia's
	// own stream and never a device id.
	if (plug['type'] == 'usermedia') {
		if (plug['id']) { audio.deviceId = { exact: plug['id'] }; }
	}
	if (plug['type'] == 'usermedia' && plug['av'] == 'a') {
		audio.channelCount = Math.max(2, channels || 0);
	}

	var constraints = { audio: audio };
	if (video) {
		// 320p up to the device maximum, with an optional frame-rate cap
		var height = studioSettingNumber('video_height', 0);
		var fps = studioSettingNumber('video_fps', 0);
		if (height > 0 || fps > 0) {
			constraints['video'] = {};
			if (height > 0) { constraints['video'].height = { ideal: Math.round(height) }; }
			if (fps > 0) { constraints['video'].frameRate = { ideal: Math.round(fps) }; }
		}
		else { constraints['video'] = true; }
	}

	var stream;
	try {
		if (screen_share) {
			if (!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia)) {
				console.log('studio: this browser cannot share a screen');
				mixer[ch].media.active = false;
				return;
			}
			stream = (typeof JawnScreen !== 'undefined' && JawnScreen.available())
				? await JawnScreen.capture(plug['screen'] || '', plug['screen_name'] || '')
				: await navigator.mediaDevices.getDisplayMedia({
					video: { displaySurface: 'monitor' },
					audio: true
				});
		}
		else {
			stream = await navigator.mediaDevices.getUserMedia(constraints);
		}
	} catch (e) {
		console.log('studio: could not open input for channel ' + ch, e);
		mixer[ch].media.active = false;
		return;
	}

	return studioAttachCapturedStream(ch, stream);
}

function studioAttachCapturedStream(ch, stream) {
	mixer[ch].media.inRaw = stream;
	mixer[ch].media.active = true;

	// The browser's own latency report for this input; it feeds the record
	// offset so overdubs land on the grid without a manual trim.
	var in_track = stream.getAudioTracks()[0];
	if (in_track && in_track.getSettings) {
		var in_latency = numeral(in_track.getSettings().latency).value();
		if (in_latency > 0) { mixer[ch].media.latency = in_latency; }
	}
	studioUpdateLatencyInfo();

	// Push the raw input through the channel's tone stack + pedals and take the
	// processed result as our recording source. A screen stream may carry no
	// audio on this platform; the channel then records the picture alone.
	var processed = stream.getAudioTracks().length ? studioAttachInput(ch, stream) : null;
	var combined = new MediaStream();
	if (processed && processed.getAudioTracks()[0]) { combined.addTrack(processed.getAudioTracks()[0]); }
	if (stream.getVideoTracks()[0]) { combined.addTrack(stream.getVideoTracks()[0]); }
	mixer[ch].media.in = combined;
	mixer[ch].media.video = !!stream.getVideoTracks()[0];

	clearInterval(mixer[ch].media.in_analyzer_timeout);
	mixer[ch].media.in_analyzer_timeout = setInterval(function() {
		// metres are only worth drawing when they can be seen
		if (document.hidden) { return; }
		studioDrawChannel(ch);
		studioDrawMetre(ch);
	}, 40);

	var monitor = document.getElementById('studio_video_monitor_' + ch);
	if (monitor) {
		monitor.srcObject = combined;
		monitor.muted = true;
		if (mixer[ch].media.video) { $(monitor).show(); }
	}
	return combined;
}

// Monitor on a device while the engine is not the monitor opens the browser's
// capture for that input, so the browser tap has a graph to play. An armed
// track's capture belongs to the arm button, so Monitor leaves it alone.
function studioMonitorAttachDevice(ch) {
	ch = String(ch);
	var plug = (typeof studioChannelInput === 'function') ? studioChannelInput(ch) : null;
	if (!plug || typeof studioInputIsDevice !== 'function' || !studioInputIsDevice(plug)) { return false; }
	var state = $('.studio_track_arm[channel="' + ch + '"]').attr('state');
	if (state === 'rec' || state === 'loop') { return true; }
	var m = mixer[ch] && mixer[ch].media;
	if (m && m.active) { return true; }
	studioInputStreamGrabber(ch, 'rec');
	return true;
}

function studioMonitorDetachDevice(ch) {
	ch = String(ch);
	var state = $('.studio_track_arm[channel="' + ch + '"]').attr('state');
	if (state === 'rec' || state === 'loop') { return; }
	var m = mixer[ch] && mixer[ch].media;
	if (!m || !m.active) { return; }
	studioInputStreamGrabber(ch, 'off');
}

// Monitor on an app input builds that app's channel graph even when the track
// is not armed, so its post-pedal tap is audible without starting a take. A
// device input is the engine's Listen, so this never opens the browser's
// capture and never calls getUserMedia. An armed track's graph belongs to the
// arm button, so Monitor leaves it alone.
function studioMonitorAttachApp(ch) {
	ch = String(ch);
	var plug = studioChannelInput(ch);
	if (!plug || !studioInputIsApp(plug)) { return false; }
	var m = mixer[ch] && mixer[ch].media;
	if (m && m.active) { return true; }
	var state = $('.studio_track_arm[channel="' + ch + '"]').attr('state');
	if (state === 'rec' || state === 'loop') { return false; }
	return !!studioAttachAppInput(ch, plug);
}

// Monitor off (or moved) removes only the app graph Monitor built, and only
// while the track is still unarmed. An armed track keeps its input for the take.
function studioMonitorDetachApp(ch) {
	ch = String(ch);
	var m = mixer[ch] && mixer[ch].media;
	if (!m || !m.active) { return; }
	var state = $('.studio_track_arm[channel="' + ch + '"]').attr('state');
	if (state === 'rec' || state === 'loop') { return; }
	var plug = studioChannelInput(ch);
	if (!plug || !studioInputIsApp(plug)) { return; }
	if (m.inRaw) { m.inRaw.getTracks().forEach(function (track) { track.stop(); }); }
	m.inRaw = undefined;
	m.in = null;
	m.active = false;
	studioDetachInput(ch);
	clearInterval(m.in_analyzer_timeout);
	var monitor = document.getElementById('studio_video_monitor_' + ch);
	if (monitor) { monitor.srcObject = null; $(monitor).hide(); }
}

function studioStartTake(ch, looping, at) {
	var media = mixer[ch] && mixer[ch].media;
	if (!media || !media.in) {
		// A channel send feeds this channel's own recDest, so an armed channel can
		// take another channel's output with nothing plugged in.
		var routed_plug = studioChannelInput(ch);
		if (routed_plug && routed_plug['type'] === 'channel') {
			var routed_channel = studioAudio.channels[ch];
			if (media && routed_channel && routed_channel.recDest) {
				media.in = routed_channel.recDest.stream;
			}
		}
	}
	if (!media || !media.in) {
		// The drums feed the selected track's recDest rather than a microphone,
		// so that track can take them with nothing plugged in. Any other empty
		// track still has no input, exactly as before.
		var drums_channel = studioAudio.channels[ch];
		if (media && drums_channel && drums_channel.recDest
			&& typeof studioDrums !== 'undefined' && studioDrums.routedDest === drums_channel.recDest) {
			media.in = drums_channel.recDest.stream;
		}
	}
	if (!media || !media.in) {
		console.log('studio: channel ' + ch + ' is armed to record but has no input');
		return;
	}
	if (!media.out) { media.out = []; }
	if (!media.rec) { media.rec = []; }
	var ir = media.out.length;

	var el = document.createElement('video');
	el.className = 'studio_video';
	el.id = 'studio_channel_' + ch + '_' + ir;
	el.style.display = 'none';
	el.preload = 'auto';
	$('#studio_track_container').append(el);

	// Latency skew pulls a fresh take earlier so it lines up with what was
	// already playing. Negative positions are kept on purpose: clamping to zero
	// is what used to leave every overdub recorded from the top late by the
	// monitoring latency. `at` is the punch-in point when a count-in ran.
	var from = (at === undefined || at === null) ? mixer['time']['position'] : at;
	var latency = studioRecordOffset(ch);
	var take = { startTime: from - latency, latency: latency, offset: 0, duration: 0, status: 'recording', track: el, loop: !!looping, region: looping ? studioLoopRegion() : null };
	media.out[ir] = take;

	var mime = studioPickMime(!!media.video);
	var options = {};
	if (mime) { options.mimeType = mime; }
	var kbps = studioSettingNumber('audio_kbps', 256);
	if (kbps > 0) { options.audioBitsPerSecond = Math.max(6, Math.min(510, Math.round(kbps))) * 1000; }
	var mbps = studioSettingNumber('video_mbps', 0);
	if (media.video && mbps > 0) { options.videoBitsPerSecond = Math.round(mbps * 1000) * 1000; }
	var recorder;
	try {
		recorder = new MediaRecorder(media.in, options);
	} catch (e) {
		console.log('studio: MediaRecorder could not start', e);
		return;
	}
	recorder.ondataavailable = function(event) {
		if (!event.data || !event.data.size) { return; }
		take.data = event.data;
		take.encoding = event.data.type;
		take.status = 'stop';
		if (take.src) { try { URL.revokeObjectURL(take.src); } catch (e) {} }
		take.src = URL.createObjectURL(event.data);
		take.track.src = take.src;
		studioTakeRequestBuffer(take);
	};
	// Measurement only: stamp the request and the recorder's own start so the
	// take (and studioAudioReport) carries how long the browser took to begin.
	var recStartAt = (window.performance && window.performance.now) ? window.performance.now() : Date.now();
	take.recStartAt = recStartAt;
	recorder.onstart = function() {
		var now = (window.performance && window.performance.now) ? window.performance.now() : Date.now();
		take.recorderStartDelayMs = now - recStartAt;
		studioAudio.recorderStartDelayMs = take.recorderStartDelayMs;
	};
	media.rec[ir] = recorder;
	recorder.start();
	console.log('studio: recording channel ' + ch + ' take ' + ir + ' at ' + take.startTime.toFixed(3) + 's');
}

function studioStopTake(ch, ir) {
	var media = mixer[ch] && mixer[ch].media;
	if (!media) { return; }
	var take = media.out && media.out[ir];
	var recorder = media.rec && media.rec[ir];
	if (recorder && recorder.state && recorder.state != 'inactive') { recorder.stop(); }
	if (take && take.status == 'recording') {
		take.status = 'stop';
		if (take.loop) {
			// repeats are grid-locked, so they never drift off the beat
			take.duration = studioLoopTakeDuration(take);
		}
		else {
			take.duration = Math.max(0, mixer['time']['position'] - take.startTime);
		}
		mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + take.duration);
	}
	if (media.rec) { media.rec[ir] = null; }
}

// Start the takes held back by a count-in, once the transport reaches the
// punch-in point. The takes are anchored to that point, not to the tick that
// notices it, so a loop still starts exactly on the bar line.
function studioStartPendingTakes() {
	var punch = mixer['time']['punch_in'];
	if (punch === undefined || punch === null) { return; }
	if (mixer['time']['position'] < punch) { return; }
	var pending = mixer['time']['pending_takes'] || [];
	mixer['time']['punch_in'] = null;
	mixer['time']['pending_takes'] = null;
	$.each(pending, function (n, a) {
		if (!mixer[a.ch]) { mixer[a.ch] = {}; }
		if (!mixer[a.ch].media) { mixer[a.ch].media = {}; }
		studioStartTake(a.ch, a.loop, punch);
	});
}

async function studioRecord() {
	if (mixer['time']['status'] == 'record') { return; }

	var song = studioSaver();
	var takes = [];
	var loop_armed = false;
	$.each(song, function(i,v) {
		var arm = v['armed'] && v['armed']['state'];
		if (!/^[0-9]+$/.test(i) || (arm != 'rec' && arm != 'loop')) { return; }
		if (arm == 'loop') { loop_armed = true; }
		takes.push({ ch: i, loop: arm == 'loop' });
	});

	// Where recording begins. Loop takes reserve a region: it starts on the
	// grid the Start on setting asks for (bar, beat, or the playhead itself)
	// and runs for the configured number of bars, so the phrase and its repeats
	// stay on the beat grid.
	var unit = studioSnapUnit();
	var punch = mixer['time']['position'];
	if (unit > 0) { punch = Math.floor(punch / unit) * unit; }
	if (loop_armed) {
		var bars = studioLoopBars();
		if (bars > 0) { mixer['time']['loop_region'] = { start: punch, bars: bars }; }
		else { mixer['time']['loop_region'] = null; }
	}

	mixer['time']['status'] = 'record';
	mixer['time']['punch_in'] = null;
	mixer['time']['pending_takes'] = null;
	mixer['time']['position'] = punch;

	// A count-in runs the transport up to the punch-in point with clicks; the
	// takes are held back until it gets there.
	var count_in = studioCountInBeats() * studioBeatSeconds();
	if (count_in > 0) {
		mixer['time']['position'] = punch - count_in;
		mixer['time']['punch_in'] = punch;
		mixer['time']['pending_takes'] = takes;
	}
	studioTime('start');

	if (count_in <= 0) {
		$.each(takes, function(n, a) {
			if (!mixer[a.ch]) { mixer[a.ch] = {}; }
			if (!mixer[a.ch].media) { mixer[a.ch].media = {}; }
			studioStartTake(a.ch, a.loop, punch);
		});
	}
	studioSyncTakes();
}

$(document).on('click', '#studio_play', function() {
	if (mixer['time']['status'] != 'record' && mixer['time']['status'] != 'play') {
		studioPlay('play');
		mixer['time']['status'] = 'play';
	}
});

async function studioPlay(mode) {
	mixer['time']['status'] = (mode == 'rec') ? 'record' : 'play';
	if (mode != 'rec') { studioTime('start'); }
	studioSyncTakes();
}

$(document).on('click', '#studio_stop', function() {
	studioStop();
	mixer['time']['status'] = 'stop';
});

