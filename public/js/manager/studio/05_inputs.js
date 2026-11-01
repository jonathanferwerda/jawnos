var studio_jw_deg =  0;
var studio_last = 'out';
$(document).on('touchmove mousemove', '#studio_jog_wheel', function(e) {
	e.preventDefault();			e.preventDefault();
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
			{ app: 'synth', id: 'synthesizer', direction: 'input', av: 'a' }
		];

		var information = {};
		var sci = $('.studio_channel_information[direction="' + direction + '"][channel="' + channel + '"]');
		if (isJson(sci.text())) {
			information = JSON.parse(sci.text());
		}

		var data = { 
			channel: channel, 
			constraints: JSON.stringify(constraints),
			screenShare: screenShare,
			mouse: m,
			apps: JSON.stringify(eligibleApps),
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
				sis.css({ 'left': (x + 20), 'top': y, 'right': '', 'bottom': '', 'width': '', 'height': '' });
				var width = sis.width();
				if (numeral(sis.css('right')).value() < 0 || sis.width() < 200) {
					sis.css({ 'right': (($(window).width() - x) + 20), 'left': '' });
				}
				if (numeral(sis.css('bottom')).value() < 0) {
					sis.css({ 'bottom': (($(window).height() - y) + 20), 'top': '' });
				}

				appointment_chron();
			}
		});
	}
}

$(document).on('click', '.close_plug_select', function() {
	var sis = $('#studio_plug_select_container');
	sis.hide();
});

$(document).on('click', '.studio_plug_selection', function() {
	var sis = $(this);
	var channel = sis.attr('channel');
	var direction = sis.attr('direction');
	var id = sis.attr('sid');
	var type = sis.attr('type');
	var av = sis.attr('av');
	var app = sis.attr('app');
	$('.studio_plug_selection[direction="' + direction + '"][channel="' + channel + '"]').removeClass('active_background');
	var data = {
		channel: channel,
		direction: direction,
		id: id,
		type: type,
		av: av,
		app: app
	}
	console.log(data);
	var jinfo = JSON.stringify(data);


	$('.studio_channel_information[direction="' + direction + '"][channel="' + channel + '"]').text(jinfo);
	var chosen = $('.studio_plug_selection[direction="' + direction + '"][channel="' + channel + '"][type="' + type + '"][sid="' + id + '"][av="' + av + '"][app="' + app + '"]');
	console.log('length ' + chosen.length);
	chosen.addClass('active_background');
	studioInputStreamGrabber(channel,'off')
	studioSaver();
	studioRetriever();
});

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

	// If the channel has an input plug selected, honour its audio/video kind, but
	// default to audio only: the camera is requested only when the plug is a
	// video source ('av' = a camera or video app, 'v' = the marker). Nothing
	// chosen means no camera.
	var info = $('.studio_channel_information[direction="input"][channel="' + ch + '"]');
	var plug = isJson(info.text()) ? JSON.parse(info.text()) : {};
	var video = (plug['av'] == 'av' || plug['av'] == 'v');

	// The synth is an app input with no device behind it: route the engine into
	// the channel instead of opening a microphone. It records through the tone
	// stack and pedals like any other source.
	if (plug['app'] == 'synth') {
		var synthStream = studioAttachSynth(ch);
		if (!synthStream) { mixer[ch].media.active = false; return; }
		mixer[ch].media.active = true;
		mixer[ch].media.in = synthStream;
		mixer[ch].media.video = false;
		clearInterval(mixer[ch].media.in_analyzer_timeout);
		mixer[ch].media.in_analyzer_timeout = setInterval(function() {
			if (document.hidden) { return; }
			studioDrawChannel(ch);
			studioDrawMetre(ch);
		}, 40);
		return synthStream;
	}

	var audio = {
		echoCancellation: false,  // Disables echo suppression
		noiseSuppression: false,  // Disables background noise dampening
		autoGainControl: false   // Prevents the browser from auto-adjusting volume
	};
	var sample_rate = studioSampleRate();
	if (sample_rate > 0) { audio.sampleRate = sample_rate; }
	var channels = studioSettingNumber('audio_channels', 0);
	if (channels > 0) { audio.channelCount = channels; }

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
		stream = await navigator.mediaDevices.getUserMedia(constraints);
	} catch (e) {
		console.log('studio: could not open input for channel ' + ch, e);
		mixer[ch].media.active = false;
		return;
	}

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
	// processed result as our recording source.
	var processed = studioAttachInput(ch, stream);
	var combined = new MediaStream();
	if (processed) { combined.addTrack(processed.getAudioTracks()[0]); }
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

function studioStartTake(ch, looping, at) {
	var media = mixer[ch] && mixer[ch].media;
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

