var mixer = {};
var studio;

// Button artwork follows the selected icon set; the studio window publishes a
// server-resolved map (see studio/studio.html.ep), falling back to the PNG.
function jawnosStudioButtonIcon(state, colour) {
	var map = (window.jawnos_studio_button_icons || {})[state];
	if (map && map[colour]) { return map[colour]; }
	return '/images/studio/button_' + state + '_' + colour + '.png';
}

$(document).on('click', '#studio_new', function() {
	$('#studio').attr('uuid','').attr('name','');
	studioInit({ uuid: 'new', settings: [{ 'setting': 'last_song', 'value': 'new' }] });
	$('#studio_song_select').val('none');
});

$(document).on('click', '#pedalboard_hamburger', function() {
	var pd = $('#pedalboard');
	var z = $('#studio_viewer').closest('.wind').css('z-index');

	if (pd.is(':visible')) {
		pd.hide();
	}
	else {
		pd.show();
		pd.css({ 'z-index': (z + 10) });
	}
});

$(document).on('click', '#studio_toggle', function() {
	studioInit();
});

function studioInit(data) {
	if (!data) {
		data = {};
	}
	var jdata = JSON.stringify(data);
	var url = '/manager/studio';
	var timestamp = Date.now();
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp, data: jdata },
		success: function(response) {
			windowMaker(response.html);
			mixer = {
				time: { duration: 0, status: 'stop', position: 0, marks: [], interval: 0, startTime: 0 },
				buttons: { record: { obg: '', bg: 'red', interval: '' }, stop: { obg: '', bg: 'lightgreen', interval: '' }, play: { obg: '', bg: 'yellow', interval: '' } },
				settings: response.settings,
				automations: {}
			};
			$('#studio_track_container').html('');

			var pd = $('#pedalboard');
			if (!$('#soundroom_sidebar_container').is(':visible')) {

				var width = $('#soundroom_sidebar_container').width();
				width = (width + 30) + 'px';
				$('#studio').find('.to_sound').each(function(i,v) {
					var channel = $(v).attr('channel') + 1;
					$('#browser').append($(v).html());


					$(v).remove();
					$('.cord[channel="' + channel + '"]').draggable({
						start: function(p,ui) {
							$('.jack').show();
							
						},
						drag: function(p,ui) {

						},
						stop: function(p,ui) {
							$('.jack').hide();
						}
					});
				});
			}
			studioRetriever();
			if ($('#studio').attr('uuid')) {
				if (!data['uuid']) {
					data['uuid'] = $('#studio').attr('uuid');
				}
				if (data['uuid'] != 'new') {
					studioLoad(data['uuid']);
				}
					
			}
		}, error: function (response) {  }
	});
	
}

$(document).on('click', '.studio_close_button', function() {
	$('#soundroom_sidebar_container').html('').hide();
	$('.cord').remove();
});



$(document).on('click','.knob',function() {
	var knob = $(this);
	var control = knob.attr('control');
	var channel = knob.attr('channel');
	var input = $('.knob_control[control="' + control + '"][channel="' + channel + '"]');
	var current_value = input.val();
	var vis = input.is(':visible');
	if (vis) {
		input.hide();
		$('.knob[channel="' + channel + '"]').show();
	}
	else {
		input.show();
		$('.knob[channel="' + channel + '"]').hide();
		$('.knob[control="' + control + '"][channel="' + channel + '"]').show();
	}
	studioSaver();
});

$(document).on('mousewheel', '.knob', function(e) {
	var mvmt = numeral(e.originalEvent.wheelDelta).value();

	mvmt = numeral(mvmt / 30).value() ;

	var knob = $(this);
	var control = knob.attr('control');
	var channel = knob.attr('channel');
	var input = $('.knob_control[control="' + control + '"][channel="' + channel + '"]');
	var current_value = input.val();
	input.val((numeral(current_value).value() + mvmt) );
	input.trigger('change');
	studioSaver();
});

$(document).on('change mousemove touchmove','.knob_control',function() {
	var input = $(this);
	var channel = input.attr('channel');

	var current_value = input.val();
	var control = input.attr('control');
	var knob = $('.knob[control="' + control + '"][channel="' + channel + '"]');
	var direction = knob.attr('direction');
	var flip = numeral(knob.attr('flip')).value() || 0;
	var range = numeral(knob.attr('range')).value() || .85;
	var step = numeral(input.attr('step')).value();

	var transform_value = (flip + numeral((360 / 100) * (current_value * range)).value());
	if (direction == 'counter') {
		transform_value = (flip - numeral((360 / 100) * (current_value * range)).value());
	}
	knob.css({ 'transform': 'rotate(' + transform_value + 'deg)' });
	studioSaver();
});

$(document).on('click', '.button_control', function() {
	var b = $(this);
	var control = b.attr('control');
	var colour = b.attr('colour');
	var status = b.attr('status');
	if (status == 'depressed') {
		b.attr('status', 'pressed');
		b.attr('src', jawnosStudioButtonIcon('pressed', colour));
	}
	else {
		b.attr('status', 'depressed');
		b.attr('src', jawnosStudioButtonIcon('depressed', colour));
	}
	studioSaver();
});

$(document).on('mousewheel', '.channel_volume', function(e) {
	var vol = $(this);
	var mvmt = numeral(e.originalEvent.wheelDelta).value() / 30;
	var newVol = (numeral(vol.val()).value() + mvmt);
	vol.val(newVol);
	studioSaver();
});

$(document).on('change', '.channel_volume', function() {
	studioSaver();
});

$(document).on('click', '#studio_loop', function() {
	var sl = $(this);
	var loop = sl.attr('enabled');

	if (sl.attr('enabled') == 'ongoing') {
		loop = 'off';
		sl.attr('enabled', loop);
		sl.css({'background-color': 'rgb(211, 211, 211)' });
	}
	else if (sl.attr('enabled') == 'on') {
		loop = 'ongoing';
		sl.attr('enabled', loop);
		sl.css({'background-color': 'yellow' });
	}
	else {
		loop = 'on';
		sl.attr('obg', sl.css('background-color'));
		sl.attr('enabled', loop);
		sl.css({'background-color': 'red' });
	}
	mixer['time']['loop'] = loop
	studioSaver();
});

function studioSaver() {
	var studio = {};
	var name = $('#studio').attr('name');
	var uuid = $('#studio').attr('uuid');
	$('.knob_control, .channel_volume').each(function(i,v) {

		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		var value = $(v).val();

		if (control == 'pan') {
			value = (value - 0) / (100 - 0) * ( 1 - -1) + -1;
		}

		if (studio[channel] == undefined) {
			studio[channel] = {};
		}
		if (!studio[channel]['plugs']) {
			studio[channel]['plugs'] = {
				input: {},
				output: {}
			};
		}
		studio[channel][control] = value;
		if (mixer[channel]) {
			mixer[channel][control] = value;
		}
	});
	$('.armed').each(function(i,v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		var state = $(v).attr('state');
		var text = $(v).text();
		studio[channel][control] = { state: state, text: text };
	});
	$('.studio_channel_information').each(function(inf,sci) {
		var text = $(sci).text();
		if (isJson(text)) {
			var info = JSON.parse(text);
			studio[info['channel']]['plugs'][info['direction']] = info;
		}
	});

	var sl = $('#studio_loop').attr('enabled');
	var video_toggle = $('#studio_video_toggle').attr('toggled');
	studio['admin'] = { time: mixer['time'], name: name, uuid: uuid, loop: sl, video_toggle: video_toggle };
	var jstudio = JSON.stringify(studio);
	localStorage.setItem('studio', jstudio);
	return studio;
}

function studioRetriever() {
	var studio = localStorage.getItem('studio') || "{}";
	studio = JSON.parse(studio);
	$.each(studio, function(i,v) {
		if (!mixer[i]) { mixer[i] = {}; }
		$.each(studio[i], function(n,w) {
			mixer[i][n] = w;
			$.each(mixer[i], function(ir,vr) {
				studio[i]['mixer'] = vr;
			});
			if (n == 'armed') {
				$('[channel="' + i + '"][control="' + n + '"]').attr('state', w.state);
				$('[channel="' + i + '"][control="' + n + '"]').text(w.text);
				if (w.state == 'rec') {
		//			mixer['admin']['video_toggle'] = 'on';
					studioInputStreamGrabber(i,w.state);
				}
			}
			else {

				if (n == 'pan') {
					w = (w - -1) / (1 - -1) * ( 100 - 0) + 0;
				}
				if (n == 'gain' && !w) {
					w = 10;
				}
				$('[channel="' + i + '"][control="' + n + '"]').val(w).trigger('change');
			}
		});
	});
	studio['admin']['metronome'] = mixer['time']['metronome'];
	studio['admin']['channel_count'] = $('#studio_viewer').attr('channel_count');
	mixer['settings']['channel_count'] = studio['admin']['channel_count'];
	var met = $('#studio_metronome');
	if (mixer['time']['metronome'] == 'yes') {
		met.attr('armed', 'yes');
		if (met.attr('obg') != 'red') {
			met.attr('obg', met.css('background-color'));
		}
		met.css({'background-color': 'red'});
	} else {
		met.attr('armed','no');
		met.css({'background-color': met.attr('obg')});
	}
	var bpm = $('#studio_bpm').val();
	if (mixer['time']['bpm']) {
		studio['admin']['bpm'] = mixer['time']['bpm'];
	} else {
		studio['admin']['bpm'] = bpm;
		mixer['time']['bpm'] = bpm;
	}
	$('#studio_bpm').val(studio['admin']['bpm']);
	var sig = $('#studio_sig').val();
	if (mixer['time']['sig']) {
		studio['admin']['sig'] = mixer['time']['sig'];
	} else {
		studio['admin']['sig'] = sig;
		mixer['time']['sig'] = sig;
	}
	$('#studio_sig').val(studio['admin']['bpm']);


	mixer['time']['loop'] = studio['admin']['loop'];
	studio['admin']['settings'] = mixer['settings'];
	return studio;
}

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

$(document).on('mousewheel', '#studio_jog_wheel', function(e) {
	var j = $(this);
	var mvmt = numeral(e.originalEvent.wheelDelta).value();

	var diff = numeral(mvmt / 30).value() ;
	studio_jw_deg = (studio_jw_deg + diff);
	j.css({'rotate': studio_jw_deg + 'deg' });
	mixer['time']['position'] = mixer['time']['position'] + diff / 10;
	studioTime('scroll');
});

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
	studioInputStreamGrabber(channel,state);
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
	if (mixer[channel]['media'] && state == 'rec') {
		if (mixer[channel]['media']['in']) {
			if (mixer[channel]['media']['in']['active'] == true) {
				return;
			}
		}
	}
	type = 'usermedia';
	var monitor_id = 'studio_video_monitor_' + channel;
	var inputStream;
	var video = true;

/*
	if (mixer['admin']['video_toggle'] == 'on') {
		video = true;
	}
*/
	console.log(state);
	if (state != 'rec') {
		mixer[channel]['media']['inRaw'].getTracks().forEach(function(track) {
			track.stop();
		});
		mixer[channel]['media']['in'] = { active: false };
		mixer[channel]['media']['inRaw'] = undefined;
		clearInterval(mixer[channel]['media']['in_analyzer_timeout']);
		$('#' + monitor_id).hide();
		return;
	}
	mixer[channel]['media']['in'] = { active: true };
	var constraints = { 
		audio: {
			echoCancellation: false,  // Disables echo suppression
			noiseSuppression: false,  // Disables background noise dampening
			autoGainControl: false,   // Prevents the browser from auto-adjusting volume
			sampleRate: 44100,        // Requests 48 kHz studio quality
			channelCount: 2           // Requests stereo sound
		}
	};


	if (Object.keys(mixer[channel]['plugs']['input']).length > 0) {
		if (type == 'app') {

		} else if (type == 'usermedia') {

		} else if (type == 'screen_share') {

		} else {
			constraints['video'] = true;
		}

	}
	else {
		constraints['video'] = true;
		inputStream = await navigator.mediaDevices.getUserMedia(constraints);
	}
	var studio = studioRetriever();
	console.log('preinputstream');
	if (inputStream) {
		console.log('postinputstream');
		// 2. Set up an Audio Context to intercept the hardware signal
		const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
		const source = audioCtx.createMediaStreamSource(inputStream);
		const destination = audioCtx.createMediaStreamDestination();

		// 3. Create a Splitter to isolate the UR22 channels and a Merger to combine them
		const splitter = audioCtx.createChannelSplitter(2);
		const merger = audioCtx.createChannelMerger(2);


		source.connect(splitter);

		// 4. THE FIX: Grab Channel 0 (Input 1 / Left) and plug it into BOTH Left and Right channels
		splitter.connect(merger, 0, 0); // Hardware Left Input -> Stereo Left Output
		splitter.connect(merger, 0, 1); // Hardware Left Input -> Stereo Right Output (Forces both ears)
		var masterStream = new MediaStream();
		merger.connect(destination);
		const fixedAudioTrack = destination.stream.getAudioTracks()[0];
		masterStream.addTrack(fixedAudioTrack);
		if (video == true) {
			const rawVideoTrack = inputStream.getVideoTracks()[0];
			masterStream.addTrack(rawVideoTrack);
		}
		if(!mixer[channel]['media']) { mixer[channel]['media'] = {}; }
		mixer[channel]['media']['in'] = masterStream;
		mixer[channel]['media']['inRaw'] = inputStream;
		i = channel;
		var count = 0;
		if (!mixer[i]['media']['rec']) {
			mixer[i]['media']['rec'] = [];
			mixer[i]['media']['rec'][count] = { ready: 'ready' };
		}
		else {
			for (var n = 0; n < mixer[i]['media']['rec'].length; n++) { 
				if (mixer[i]['media']['rec'][n]) {
					if (mixer[i]['media']['rec'][n]['ready']) {
						count = n;
						break;
					}
				}
			}

			mixer[i]['media']['rec'][count] = { ready: 'ready' };

		}
		console.log(mixer[i]['media']['rec']);
		console.log(i + ' ' + count);
		if (!mixer[i]['media']['out']) { mixer[i]['media']['out'] = []; }
		mixer[i]['media']['out'][count] = {};
		if (!mixer[i]['media']['actx']) { mixer[i]['media']['actx'] = []; }
		mixer[i]['media']['actx'][count] = {};
		mixer[i]['media']['actx'][count]['ctx'] = { 'state': 'uninitialized', pcmData: [] }; 
		mixer[i]['media']['actx'][count]['ctx'] = new AudioContext();
		var c = mixer[i]['media']['actx'][count]['ctx'];
		mixer[i]['media']['actx'][count]['track'] = c.createMediaStreamSource(destination.stream);
//		mixer[i]['media']['actx'][ir]['track'].connect(c.destination);
		mixer[i]['media']['actx'][count]['panner'] = new StereoPannerNode(c, { pan: mixer[i]['pan']});
		mixer[i]['media']['actx'][count]['gain'] = mixer[i]['media']['actx'][count]['ctx'].createGain();
		mixer[i]['media']['actx'][count]['gain'].gain = mixer[i]['gain'] / 10;

		mixer[i]['media']['actx'][count]['analyser'] = c.createAnalyser();
		mixer[i]['media']['actx'][count]['track'].connect(mixer[i]['media']['actx'][count]['gain'] ).connect(mixer[i]['media']['actx'][count]['analyser']).connect(mixer[i]['media']['actx'][count]['panner']);
		const pcmData = new Float32Array(mixer[i]['media']['actx'][count]['analyser'].fftSize);
		mixer[i]['media']['actx'][count]['pcmData'] = pcmData;

		var canvas = document.getElementById('track_view_' + i);
		var metreCanvas = document.getElementById('channel_volume_metre_' + i);
		var mctx = metreCanvas.getContext('2d');
		var ctx = canvas.getContext('2d');
		clearInterval(mixer[channel]['media']['in_analyzer_timeout']);
		mixer[i]['media']['in_analyzer_timeout'] = setInterval(function() {
				var vr = mixer[i]['media']['in'];

				if (mixer[i]['media']['in'].active == true) {
					let sum = 0.0;
					if (eval(typeof mixer[i]['media']['actx'][count]['analyser'].getFloatTimeDomainData == 'function')) {
						mixer[i]['media']['actx'][count]['analyser'].getFloatTimeDomainData(mixer[i]['media']['actx'][count]['pcmData']);
						for (const amplitude of mixer[i]['media']['actx'][count]['pcmData']) {
							sum += amplitude * amplitude;
						}
						var metreValue = Math.sqrt(sum / mixer[i]['media']['actx'][count]['pcmData'].length) * 3;
						mctx.beginPath();

						mctx.clearRect(0,0,metreCanvas.width,metreCanvas.height);
						mctx.fill();
						mixer[i]['media']['actx'][count]['lastClear'] = Date.now();

						mctx.fillStyle = "green";
						mctx.fillRect(0, Math.abs((metreValue * metreCanvas.height) - metreCanvas.height), metreCanvas.width,  metreCanvas.height);
						mctx.fill();
					}
				}

		},1);

		var monitor_id = 'studio_video_monitor_' + channel;
		$('#' + monitor_id).show();
		var v = document.getElementById(monitor_id);
		v.srcObject = mixer[channel]['media']['in'];
		v.muted = true;
		return masterStream;
	}

}

async function studioRecord() {
	mixer['time']['status'] = 'record';
	var studio = studioRetriever();
	studioTime('start');
	$.each(studio, function(i,v) {
		if (v.armed) {
			if (v.armed.state == 'rec') {
				if (!mixer[i]['media']) { mixer[i]['media'] = {}; }
				var rec = { startTime: mixer['time']['position'] };
				const options = {
					mimeType: 'video/webm;codecs=opus', // Standard high-quality web codec
					audioBitsPerSecond: 256000          // Force 128 kbps (or use 256000 for 256 kbps)
				};
				rec['track'] = new MediaRecorder(mixer[i]['media']['in'], options);
				var count = 0;
				for (var n = 0; n <= mixer[i]['media']['rec'].length; n++) { 
					if (mixer[i]['media']['rec'][n]) {
						if (mixer[i]['media']['rec'][n]['ready'] == 'ready') {
							mixer[i]['media']['rec'][n] = rec;
							count = n;
							break;
						}
					}
				}
				console.log('recording ' + i + ' ' + count);


				if (mixer['admin']['video_toggle'] == 'on') {

					var v = document.getElementById('studio_video_monitor');
					v.srcObject = rec['track'].stream;
					v.muted = true;
				} else {

				}
				var trackContainer = $('#studio_track_container');
				trackContainer.append('<video class="studio_video" startTime="' + mixer['time']['position'] + '" channel="' + i + '" id="studio_channel_' + i + '_' + count + '"></video>');
				mixer[i]['media']['out'][count]['track'] = document.getElementById('studio_channel_' + i + '_' + count);

				rec['track'].audioBitsPerSecond = 192000
				mixer[i]['media']['rec'][count]['track'].ondataavailable = (event) => { 
					var data = event.data;
					if (!mixer[i]['media']['aud']) { mixer[i]['media']['aud'] = []; }
					if (!mixer[i]['media']['aud'][count]) { mixer[i]['media']['aud'][count] = {}; }
					mixer[i]['media']['out'][count]['data'] = data;
					mixer[i]['media']['out'][count]['encoding'] = data['type'];
					mixer[i]['media']['out'][count]['size'] = data['size'];
					mixer[i]['media']['aud'][count]['track'] = new Audio;
					var audioUrl = URL.createObjectURL(data);
					mixer[i]['media']['out'][count]['track'].src = audioUrl;
					mixer[i]['media']['out'][count]['status'] = 'stop';

					console.log('appending ' + audioUrl);


				};

				mixer[i]['media']['rec'][count]['track'].start();
				mixer[i]['media']['rec'][count]['track'].onstart = (event) => {
					var now = Date.now();
					mixer['time']['position'] = ((now - mixer['time']['startTime']) / 1000);
					mixer[i]['media']['out'][count]['startTime'] = mixer['time']['position'];
				};
				mixer[i]['media']['out'][count]['startTime'] = mixer['time']['position'];//  - (mixer[i]['media']['actx'][count]['ctx'].outputLatency + mixer[i]['media']['actx'][count]['ctx'].baseLatency);
				mixer[i]['media']['rec'][count]['track'].onstart = (event) => {

				};
				
			}
		}
	});
	studioPlay('rec');
}

$(document).on('click', '#studio_play', function() {
	if (mixer['time']['status'] != 'record' && mixer['time']['status'] != 'play') {
		studioPlay('play');
		mixer['time']['status'] = 'play';
	}
});

async function studioPlay(mode) {
	var playTracks = [];

	if (mode != 'rec') {
		studioTime('start');
	}
	var studio = studioRetriever();
	$.each(studio, function(i,v) {
		if (v.armed) {
			if ((v.armed.state == 'rec' && mode == 'play') || v.armed.state == 'play') {

				if (mixer[i]['media']) { 
					if (mixer[i]['media']['out']) {
						$.each(mixer[i]['media']['out'],function(ir,vr) {
							vr['track'].currentTime = mixer['time']['position'];
							//vr['track'].play();
							vr['track'].volume = (studio[i]['volume'] / 100);
						});
					}
				}
			}
		}
	});
}

$(document).on('click', '#studio_stop', function() {
	studioStop();
	mixer['time']['status'] = 'stop';
});

async function studioStop() {
	var playTracks = [];

	if (mixer['time']['status'] == 'stop') {
		mixer['time']['position'] = 0;
	}

	studioTime('stop');

	var studio = studioRetriever();
	$.each(studio, function(i,v) {

		if (v.armed) {
			if (mixer[i]['media']) {
				if (mixer[i]['media']['rec'] && mixer['time']['status'] == 'record') {
					$.each(mixer[i]['media']['rec'], function(ir,vr) {
						if (vr['track'].state == 'recording') {
							vr['track'].stop();
							mixer[i]['media']['in'].getTracks().forEach(function(track) { track.stop(); });
						}
						vr['status'] = 'stop';
						mixer[i]['media']['out'][ir]['status'] = 'stop';
						mixer[i]['media']['out'][ir]['duration'] = mixer['time']['position'] - mixer[i]['media']['out'][ir]['startTime'] ;
					});

				}
				if (mixer[i]['media']['out']) {
					$.each(mixer[i]['media']['out'], function(ir,vr) {

						vr['status'] = 'stop';
						vr['track'].pause();
					//	vr['track'].play();
						if (mixer[i]['media']['actx'][ir]) {
						//	mixer[i]['media']['actx'][ir] = null;
						}
					});
				}

			}
		}
	});
	mixer['time']['status'] = 'stop';
}

function studioTime(command) {
	var svm = document.getElementById('studio_video_monitor');
	$('#studio_video_monitor').show();
	if (command == 'start' || command == 'scroll') {
		console.log('this is a ' + command);
		mixer['time']['lastMetronome'] = 0;
		var piano = new AudioContext;
		const gainNode = piano.createGain();
		var metronome = document.getElementById('metronome');
		mixer['metronome']['gain'] = gainNode;
		mixer['metronome']['out'] = metronome;
		mixer['metronome']['ctx'] = piano;


		mixer['time']['startTime'] = Date.now();

		mixer['time']['startTime'] = (mixer['time']['startTime'] - (mixer['time']['position'] * 1000));
		dealWithIt();
		mixer['time']['interval'] = setInterval(function() {
			var s = Date.now();
			dealWithIt();
			var e = Date.now();
			if (e - s > 3) {
				console.log(e - s);
			}
		},1)
		function dealWithIt() {
			var now = Date.now();
			mixer['time']['position'] = ((now - mixer['time']['startTime']) / 1000);
			var tdisplay = studioTimeDisplay();

			if (mixer['time']['status'] == 'record' && mixer['time']['position'] > mixer['time']['duration']) {
				mixer['time']['duration'] = mixer['time']['position'];
				$('#studio_time_duration').html(numeral(mixer['time']['duration']).format('00.000'));
			}
			else if ((mixer['time']['status'] == 'play' || command == 'scroll') && mixer['time']['position'] > mixer['time']['duration']) {
				if (mixer['time']['loop'] == 'on') {
					studioStop();
					clearInterval(mixer['time']['interval']);
					mixer['time']['status'] = 'stop';
					studioStop();
					return;
				}
				else if (mixer['time']['loop'] == 'ongoing') {
					studioStop();
					mixer['time']['position'] = 0;
					studioPlay();
					mixer['time']['status'] = 'play';

				}
				else {

				}
			}
			$.each(mixer, function(i,v) {
				var now = Date.now();
				mixer['time']['position'] = ((now - mixer['time']['startTime']) / 1000);

				if (mixer[i]['media'] && mixer[i]['armed']['state'] != 'off' && document.getElementById('channel_volume_metre_' + i)) {
					var canvas = document.getElementById('track_view_' + i);
					var metreCanvas = document.getElementById('channel_volume_metre_' + i);
					var mctx = metreCanvas.getContext('2d');
					var ctx = canvas.getContext('2d');
					$.each(mixer[i]['media']['out'], function(ir,vr) {

						if (mixer[i]['media']['in'].active == true) {
							let sum = 0.0;
							if (eval(typeof mixer[i]['media']['actx'][ir]['analyser'].getFloatTimeDomainData == 'function')) {
								mixer[i]['media']['actx'][ir]['analyser'].getFloatTimeDomainData(mixer[i]['media']['actx'][ir]['pcmData']);
								for (const amplitude of mixer[i]['media']['actx'][ir]['pcmData']) {
									sum += amplitude * amplitude;
								}
								var metreValue = Math.sqrt(sum / mixer[i]['media']['actx'][ir]['pcmData'].length) * 3;
								mctx.beginPath();
							//	if (mixer[i]['media']['actx'][ir]['lastClear'] + 500 <= now) {
									mctx.clearRect(0,0,metreCanvas.width,metreCanvas.height);
									mctx.fill();
									mixer[i]['media']['actx'][ir]['lastClear'] = now;
							//	}
								mctx.fillStyle = "green";
								mctx.fillRect(0, Math.abs((metreValue * metreCanvas.height) - metreCanvas.height), metreCanvas.width,  metreCanvas.height);
								mctx.fill();
								if (mixer[i]['media']['actx'][ir]['panner']['pan']) {
									mixer[i]['media']['actx'][ir]['panner'].pan.value = mixer[i]['pan'];
								}
								if (mixer[i]['media']['actx'][ir]['gain']) {
							//	  mixer[i]['media']['actx'][ir]['gain'].gain.value = mixer[i]['gain'] / 10; 
								}
							}
						}
						else if (vr['startTime'] <= mixer['time']['position'] && (vr['status'] != 'record' && vr['status'] != 'play')) {
							console.log('play_mode');
							
							if (!mixer[i]['media']['actx'] && vr['status']) { mixer[i]['media']['actx'] = []; }
							if (!mixer[i]['media']['actx'][ir]) { mixer[i]['media']['actx'][ir] = {}; }
							if (!mixer[i]['media']['actx'][ir]['ctx']) { mixer[i]['media']['actx'][ir]['ctx'] = { state: 'uninitialized' }; }
							if (mixer[i]['media']['actx'][ir]['ctx'].state == 'uninitialized') {
								vr['init'] = true;
								mixer[i]['media']['actx'][ir]['ctx'] = new AudioContext();
								var c = mixer[i]['media']['actx'][ir]['ctx'];
								mixer[i]['media']['actx'][ir]['track'] = c.createMediaElementSource(vr['track']);
								mixer[i]['media']['actx'][ir]['track'].connect(c.destination);
								mixer[i]['media']['actx'][ir]['panner'] = new StereoPannerNode(c, { pan: mixer[i]['pan']});
								mixer[i]['media']['actx'][ir]['analyser'] = c.createAnalyser();
								const pcmData = new Float32Array(mixer[i]['media']['actx'][ir]['analyser'].fftSize);
								mixer[i]['media']['actx'][ir]['pcmData'] = pcmData;
						//		mixer[i]['media']['actx'][ir]['track'].connect(mixer[i]['media']['actx'][ir]['gain']).connect(mixer[i]['media']['actx'][ir]['panner']).connect(mixer[i]['media']['actx'][ir]['analyser']).connect(c.destination);
								var now = Date.now();
								mixer['time']['position'] = ((now - mixer['time']['startTime']) / 1000);
								mixer[i]['media']['actx'][ir]['lastClear'] = now;
							}




							console.log('here we are ' + ir);
							if (svm.src != vr['track'].src) {
								svm.src = vr['track'].src;
							}
							console.log('svm ' + vr['track'].src);
							vr['track'].currentTime = mixer['time']['position'] - vr['startTime'] + (mixer[i]['media']['actx'][ir]['ctx'].outputLatency + mixer[i]['media']['actx'][ir]['ctx'].baseLatency);
							svm.currentTime = vr['track'].currentTime;
							if (command != 'scroll') {
								vr['status'] = 'play';
								svm.play();

								vr['track'].play();
							}
							vr['track'].addEventListener('loadedmetadata', function() {
								vr['track'].currentTime = mixer['time']['position'] - vr['startTime'] + (mixer[i]['media']['actx'][ir]['ctx'].outputLatency + mixer[i]['media']['actx'][ir]['ctx'].baseLatency);
							});

						}
					//	else { vr['init'] = false; }

						if (mixer[i]['media']['actx'][ir] && vr['status'] != 'record') {
							if (vr['init'] == true) {
								if (vr['track']) {
									vr['track'].volume = (mixer[i]['volume'] / 100);
									
									if (mixer[i]['media']['actx'][ir]['panner']['pan']) {
										mixer[i]['media']['actx'][ir]['panner'].pan.value = mixer[i]['pan'];
									}
									let sum = 0.0;
									if (typeof mixer[i]['media']['actx'][ir]['analyser'].getFloatTimeDomainData == 'function') {
										mixer[i]['media']['actx'][ir]['analyser'].getFloatTimeDomainData(mixer[i]['media']['actx'][ir]['pcmData']);
										for (const amplitude of mixer[i]['media']['actx'][ir]['pcmData']) {
											sum += amplitude * amplitude;
										}
										var metreValue = Math.sqrt(sum / mixer[i]['media']['actx'][ir]['pcmData'].length) * 3;
										mctx.beginPath();
									//	if (mixer[i]['media']['actx'][ir]['lastClear'] + 500 <= now) {
											mctx.clearRect(0,0,metreCanvas.width,metreCanvas.height);
											mctx.fill();
											mixer[i]['media']['actx'][ir]['lastClear'] = now;
									//	}
										mctx.fillStyle = "green";
										mctx.fillRect(0, Math.abs((metreValue * metreCanvas.height) - metreCanvas.height), metreCanvas.width,  metreCanvas.height);
										mctx.fill();
									}
								}
							}
						}
						else if (mixer[i]['media']['actx'][ir] && vr['status'] == 'record') {
							if (mixer[i]['media']['actx'][ir]['gain']) {
							  mixer[i]['media']['actx'][ir]['gain'].gain.value = mixer[i]['gain'] / 10; 
							}
							if (mixer[i]['media']['actx'][ir]['panner']['pan']) {
								mixer[i]['media']['actx'][ir]['panner'].pan.value = mixer[i]['pan'];
							}
						}
						ctx.beginPath();

						ctx.fillStyle = 'red';
						ctx.fillRect((vr['startTime'] / mixer['time']['duration'] * canvas.width), 0, ((vr['duration'] / mixer['time']['duration'] * canvas.width )), canvas.height);
						ctx.lineWidth = 10;
						var positionLine = (mixer['time']['position'] / mixer['time']['duration'] * canvas.width);
						ctx.moveTo(positionLine, 0);
						ctx.lineTo(positionLine, canvas.height);
						ctx.strokeStyle = 'black';
						ctx.stroke();
						ctx.fill();
					});	
				}
			});

			if (mixer['time']['metronome'] == 'yes' && mixer['time']['bpm']) {

				if (tdisplay['beat'] > mixer['time']['lastMetronome']) {

					if (mixer['time']['lastMetronome']) {
						var oscillator = piano.createOscillator();
						mixer['osc'] = oscillator;
						mixer['piano'] = piano;
						if (tdisplay['beat'] % tdisplay['signature'][0]) {
							oscillator.frequency.value = 900;	
						} else {
							oscillator.frequency.value = 1100;
						}
						oscillator.type = 'triangle';
						oscillator.connect(gainNode);
						gainNode.connect(piano.destination);
						gainNode.gain.value  =  (mixer['metronome']['volume'] || 50) / 100; 
						oscillator.start();
						setTimeout(function() {
							oscillator.stop();
						},20);
					}
					mixer['time']['lastMetronome'] = tdisplay['beat'];
				}
			}

		}

	}
	else if (command == 'stop') {

		clearInterval(mixer['time']['interval']);
		studioTimeDisplay();
		svm.pause();
	}
	else {
		studioTimeDisplay()
	}
	if (command == 'scroll') {
		console.log('stopping scroll');

		clearInterval(mixer['time']['interval']);
		studioTimeDisplay();
		svm.pause();
	}
	if (!mixer['time']['status']) { mixer['time']['status'] = 'stop'; }
	var button = $('#studio_' + mixer['time']['status'] );

	$.each(mixer['buttons'], function(i,v) {
		clearInterval(v['interval']);
		$('#studio_' + i).css({'background-color': v.obg });
	});
	mixer['buttons'][mixer['time']['status']]['interval'] = setInterval(function() {
		button.css({'background-color': mixer['buttons'][mixer['time']['status']]['bg'] });
		var obg = mixer['buttons'][mixer['time']['status']]['obg'];

		setTimeout(function() {
			button.css({'background-color': obg });

		},500);
	},1000);
}

function studioTimeDisplay() {
	var asdf = mixer['time']['bpm'] / 60;
	var time = mixer['time']['position'];
	if (mixer['piano']) {
		time = (mixer['time']['position'] + mixer['piano'].outputLatency + mixer['piano'].baseLatency )
	}
	var tick = Math.floor(time * asdf);
	if (!mixer['time']['sig']) {
		mixer['time']['sig'] = $('#studio_signature').val();
	}
	var tsig = mixer['time']['sig'].split('/');
	mixer['time']['beat'] = tick;
	mixer['time']['bar'] = Math.floor(tick / tsig[0]);
	var beat = mixer['time']['beat'] - (mixer['time']['bar'] * tsig[0]) + 1;


	if (mixer['time']['display'] == 'beats') {
		$('#studio_time_display').html(numeral(mixer['time']['position']).format('00.000'));
	} else {
		$('#studio_time_display').html(mixer['time']['bar'] + ':' + beat);
	}
	return {
		beat: tick,
		bar: mixer['time']['bar'],
		signature: tsig
	};
}

$(document).on('click', '#studio_time_display', function() {
	if (mixer['time']['display'] == 'beats') {
		mixer['time']['display'] = 'time';
	} else {
		mixer['time']['display'] = 'beats';
	}
});

$(document).on('click', '#studio_metronome', function() {
	var met = $(this);
	if (met.attr('armed') == 'yes') {
		met.attr('armed','no');
		met.css({'background-color': 'rgb(211, 211, 211)' });
	}
	else {
		met.attr('armed', 'yes');
		met.attr('obg', met.css('background-color'));
		met.css({'background-color': 'red'});
	}
	mixer['time']['metronome'] = met.attr('armed');
});

$(document).on('change', '#studio_bpm', function() {
	var bpm = $(this).val();
	if (bpm > 240) {
		bpm = 240;
		$(this).val(bpm);
	} else if (bpm < 30) {
		bpm = 30;
		$(this).val(bpm);
	}
	mixer['time']['bpm'] = bpm;
});

$(document).on('click', '#studio_bpm', function() {
	var timestamp = Date.now();
	var lastClick = numeral($(this).attr('last_click')).value();
	var diff = numeral(timestamp - lastClick).value() / 1000;
	var bpm = 60 / diff;
	bpm = bpm.toFixed(2);
	$(this).attr('last_click', timestamp);

	if (bpm > 30 && bpm < 240) {

		$('#studio_bpm').val(bpm).trigger('change');
	}
});

$(document).on('change', '#studio_signature', function() {
	var sig = $(this).val();
	if (!sig || sig == "") {
		sig = '4/4';
	}
	var tsig = sig.split('/');
	if (!tsig[1]) {
		sig = tsig[0] + '/4';
	}

	$(this).val(sig);
	mixer['time']['sig'] = sig;
});

$(document).on('click', '#studio_save', function() {
	studioSave();
});




function studioSave() {
var app = 'studio';
	var now = Date.now();
	var name = $('#studio').attr('name');
	var uuid = $('#studio').attr('uuid');
	if (name) {

		var formData = new FormData();
		var studio = studioRetriever();
		formData.append('app', name);
		formData.append('name', name);
		formData.append('duration', mixer['time']['duration']);
		formData.append('timestamp', now);
		formData.append('type', 'studio');
		formData.append('uuid', uuid );

		$.each(mixer, function(i,v) {

			if (mixer[i]['media']) {
				$.each(mixer[i]['media']['out'], function(ir,vr) {
					var filename = app + '_' + now + '_' + i + '_' + ir + '.webm';

					if (vr.data && vr.data.size && vr.data.type) {
						formData.append('blob', vr.data, filename);
					}

				});
			}
		});
		var jStudio = JSON.stringify(studio);
		formData.append('studio', jStudio);
		$.ajax({
			url: '/manager/studio/save',
			type: 'POST',
			data: formData,
			success: function (response) {
				$('#studio').attr('uuid', response.uuid);
				$('#studio').attr('name', response.app);
				var studio = JSON.stringify(response.studio);
				localStorage.setItem('studio', studio);
				continent_record({'uuid':response['uuid'], 'app':response['app'],'timestamp':response['timestamp']});
				studioRetriever();
				$('#studio_song_select').replaceWith(response.song_select);
				appointment_chron();
			},
			cache: false,
			contentType: false,
			processData: false
		});
	}
	else {
		$('#studio_name').attr('type','text').focus();
	}
}

$(document).on('click', '#studio_delete', function() {
	var a = $(this);
	var uuid = mixer['admin']['uuid'];
	var app = mixer['admin']['name'];
	var armed = a.attr('armed');
	console.log(uuid);
	if (armed == 'yes') {
		console.log(app + ' ' + uuid);
		$.ajax({
			url: '/manager/studio/delete',
			type: 'POST',
			data: { uuid: uuid, app: app },
			success: function(response) {
				studioInit();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

$(document).on('change', '#studio_song_select', function() {
	var uuid = $(this).val();
	if (uuid != 'none') {
		studioLoad(uuid);
	}
});
function studioLoad(uuid) {
	var buttons = mixer['buttons'];
	studioStop();
	$.ajax({ 
		url: '/manager/studio/load',
		type: 'GET',
		data: { uuid: uuid },
		success: function(response) {
			console.log(response);
			$('#studio_song_select').val(response['uuid']);
			mixer['time'] = response.studio['admin']['time'];
			mixer['time']['metronome'] = response.studio['admin']['metronome'];
			mixer['time']['bpm'] = response.studio['admin']['bpm'];
			mixer['time']['sig'] = response.studio['admin']['sig'] || '4/4';
			$('#studio_signature').val(mixer['time']['sig']);
			mixer['time']['status'] = 'stop';
			$('#studio_video_toggle').attr('toggled', mixer['admin']['video_toggle']);
			if (mixer['time']['loop'] == 'on') {
				$('#studio_loop').attr('enabled','on').attr('obg', 'rgb(211, 211, 211)').css({'background-color':'red'});
			}
			else if (mixer['time']['loop'] == 'ongoing') {
				$('#studio_loop').attr('enabled','ongoing').attr('obg', 'rgb(211, 211, 211)').css({'background-color':'yellow'});
			}
			else {
				$('#studio_loop').attr('enabled', 'off').css({'background-color':'rgb(211, 211, 211)'});
			}
			$('#studio').attr('name', response['app']);
			$('#studio').attr('uuid', response['uuid']);
			studioTimeDisplay()
			$.each(response.studio, function(i,v) {
				if (v['mixer']) {
					if (!i.match('[a-zA-Z]')) {
						mixer[i]['media'] = v['mixer'];
					}
					$.each(v['mixer']['out'], function(ir, vr) {
						var trackContainer = $('#studio_track_container');

						trackContainer.append('<video class="studio_video" startTime="' + vr['startTime'] + '" type="' + vr['encoding'] + '" channel="' + i + '" id="studio_channel_' + i + '_' + ir + '"></video>');
						$('#studio_channel_' + i + '_' + ir).attr('src', vr['src']);
						if (!mixer[i]['media']['aud']) { mixer[i]['media']['aud'] = []; }
						if (!mixer[i]['media']['aud'][ir]) { mixer[i]['media']['aud'][ir] = {}; }
						mixer[i]['media']['actx'][ir]['ctx'] = { 'state': 'uninitialized', pcmData: [] } ; 
						mixer[i]['media']['aud'][ir]['track'] = new Audio;

						mixer[i]['media']['out'][ir]['track'] = document.getElementById('studio_channel_' + i + '_' + ir);
					});
				}
			});
			var studio = JSON.stringify(response.studio);
			localStorage.setItem('studio', studio);
			studioRetriever();
			mixer['buttons'] = buttons;
		}
	});
}

function studioImport(files) {





}

$(document).on('change', '#studio_name', function() {
	$('#studio').attr('name', $(this).val());
	$('#studio_name').hide();
});

$(document).on('blur', '#studio_name', function() {
	$('#studio_name').hide();
});

$(document).on('click', '#studio_mark', function() {
	var seen = undefined;
	for (n = 0; n <= mixer['time']['marks'].length; n++) {
		if (mixer['time']['position'] == mixer['time']['marks'][n]) {
			seen = n;
		}
	}
	if (seen == undefined) {
		mixer['time']['marks'].push(mixer['time']['position']);
		mixer['time']['marks'] = mixer['time']['marks'].sort(function(a,b) {
			return a - b;
		});
	}
	else {
		mixer['time']['marks'].splice(seen,1);
	}
});

$(document).on('click', '#studio_prev, #studio_next', function() {
	var potentialPosition = 0;
	if ($(this).hasClass('prev')) {
		for (var n = 0; n <= mixer['time']['marks'].length; n++) {
			if (mixer['time']['position'] > mixer['time']['marks'][n]) {
				potentialPosition = mixer['time']['marks'][n];
			}
		}
	}
	else {
		potentialPosition = mixer['time']['duration'];
		for (var n = mixer['time']['marks'].length; n >= 0; n--) {
			if (mixer['time']['position'] < mixer['time']['marks'][n]) {
				potentialPosition = mixer['time']['marks'][n];
			}
		}
	}
	mixer['time']['position'] = potentialPosition;
	studioTimeDisplay()
});

$(document).on('click', '#studio_config_toggle', function() {
	var config = $('#studio_config');
	var controls = $('#studio_controls');
	var mixer = $('#studio_mixer');
	if (config.is(':visible')) {
		config.hide();
		controls.show();
		mixer.show();
	} else {
		config.show();
		controls.hide();
		mixer.hide();
	}
});

$(document).on('change', '.studio_config', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var restart = $(this).attr('restart');
	if (restart == 'yes') {
		setTimeout(function() {
			studioInit({ 'settings': [{ 'setting': setting, 'value': value }] });
		},500);
	} else {
		mixer['settings'][setting] = value;
		studioRetriever();
	}
});
