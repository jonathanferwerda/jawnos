async function studioStop() {
	var wasRecording = (mixer['time']['status'] == 'record');
	// a stop during the count-in cancels the take that never started
	mixer['time']['punch_in'] = null;
	mixer['time']['pending_takes'] = null;
	studioFlushSources();
	studioAudio.playSeg = null;
	studioAudio.schedSeg = null;
	studioAudio.clickSeg = null;

	$.each(mixer, function(i,v) {
		if (!/^[0-9]+$/.test(i) || !mixer[i].media) { return; }
		if (wasRecording && mixer[i].media.rec) {
			$.each(mixer[i].media.rec, function(ir) { studioStopTake(i, ir); });
		}
		if (mixer[i].media.out) {
			mixer[i].media.out.forEach(function(take) {
				if (take && take.track && !take.track.paused) { take.track.pause(); }
			});
		}
	});

	if (mixer['time']['status'] == 'stop') { mixer['time']['position'] = 0; }
	studioTime('stop');
	mixer['time']['status'] = 'stop';
}

function studioTime(command) {
	var svm = document.getElementById('studio_video_monitor');
	if (svm) { $(svm).show(); }

	if (command == 'start') {
		mixer['time']['lastMetronome'] = null;
		mixer['time']['startTime'] = Date.now() - (mixer['time']['position'] * 1000);
		// the transport runs on the AudioContext clock; takes and clicks are
		// placed a little ahead of now so timer jitter never reaches the ear
		studioClockStart(mixer['time']['position']);
		clearInterval(mixer['time']['interval']);
		mixer['time']['interval'] = setInterval(studioTransportTick, 25);
		studioTransportTick();
	}
	else if (command == 'stop') {
		clearInterval(mixer['time']['interval']);
		mixer['time']['interval'] = 0;
		studioTimeDisplay();
	}
	else {
		studioTimeDisplay();
		studioDrawTracks();
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

// Loop takes finish themselves at the end of their region — a hair late, so
// the phrase's tail (which the player heard and answered late) is still
// captured — then start repeating on the spot. When nothing else is still
// recording, the transport drops out of record and keeps playing the loop.
function studioLoopPunchOut() {
	var pos = mixer['time']['position'];
	var stopped = false;
	var pending = false;
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m.media || !m.media.out) { return; }
		m.media.out.forEach(function (take, ir) {
			if (!take || take.status != 'recording') { return; }
			if (!take.region || !(take.region.end > 0) || pos < take.region.end + (take.latency || 0)) {
				pending = true;
				return;
			}
			studioStopTake(ch, ir);
			stopped = true;
		});
	});
	if (!stopped || pending || mixer['time']['status'] != 'record') { return; }
	mixer['time']['status'] = 'play';
	// the record transport ran straight through; re-anchor it on the play
	// timeline so the committed region now repeats
	studioClockStart(mixer['time']['position']);
	studioTime('play');
}

function studioTransportTick() {
	var status = mixer['time']['status'];

	if (status == 'play' || status == 'record') {
		studioClockAdvance();
		if (mixer['time']['status'] == 'stop') {
			studioTimeDisplay();
			studioDrawTracks();
			return;
		}
		// everything that will be heard in the next lookahead window is placed
		// on the audio clock here, so the click and the takes share one clock
		studioScheduleTick();
	}

	var end = mixer['time']['duration'] || 0;
	if (mixer['time']['status'] == 'record') {
		if (mixer['time']['position'] > end) {
			mixer['time']['duration'] = mixer['time']['position'];
			$('#studio_time_duration').html(numeral(mixer['time']['duration']).format('00.000'));
		}
		studioLoopPunchOut();
		studioStartPendingTakes();
	}

	studioTimeDisplay();
	studioSyncTakes();
	studioDrawTracks();
}

function studioTimeDisplay() {
	var bpm = studioKnobNumber(mixer['time']['bpm'], 120) || 120;
	var asdf = bpm / 60;
	var time = mixer['time']['position'];
	var tick = Math.floor(time * asdf);
	if (!mixer['time']['sig']) {
		mixer['time']['sig'] = $('#studio_signature').val() || '4/4';
	}
	var tsig = String(mixer['time']['sig']).split('/');
	var beats = studioKnobNumber(tsig[0], 4) || 4;
	mixer['time']['beat'] = tick;
	mixer['time']['bar'] = Math.floor(tick / beats);
	var beat = mixer['time']['beat'] - (mixer['time']['bar'] * beats) + 1;

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
	if (!name) {
		$('#studio_name').attr('type','text').focus();
		return;
	}

	var song = studioSaver();
	var formData = new FormData();
	formData.append('app', name);
	formData.append('name', name);
	formData.append('duration', mixer['time']['duration']);
	formData.append('timestamp', now);
	formData.append('type', 'studio');
	formData.append('uuid', uuid);

	// Only freshly recorded takes (those without a server uuid yet) are
	// uploaded, so re-saving a loaded song never duplicates its files.
	var uploads = 0;
	$.each(mixer, function(i,v) {
		if (!/^[0-9]+$/.test(i) || !mixer[i].media || !mixer[i].media.out) { return; }
		mixer[i].media.out.forEach(function(take, ir) {
			if (take && take.data && take.data.size && !take.uuid) {
				formData.append('blob', take.data, app + '_' + now + '_' + i + '_' + ir + '.webm');
				uploads++;
			}
		});
	});
	console.log('studio: saving ' + uploads + ' take(s)');

	formData.append('studio', JSON.stringify(song));
	$.ajax({
		url: '/manager/studio/save',
		type: 'POST',
		data: formData,
		success: function (response) {
			$('#studio').attr('uuid', response.uuid);
			$('#studio').attr('name', response.app);
			// adopt the uuids the server assigned to the takes we just uploaded
			$.each(response.studio || {}, function(i, v) {
				if (!/^[0-9]+$/.test(i) || !v.mixer || !v.mixer.out) { return; }
				if (!mixer[i] || !mixer[i].media || !mixer[i].media.out) { return; }
				v.mixer.out.forEach(function(take, ir) {
					if (take && take.uuid && mixer[i].media.out[ir]) {
						mixer[i].media.out[ir].uuid = take.uuid;
					}
				});
			});
			studioSongSet(response.studio);
			continent_record({'uuid':response['uuid'], 'app':response['app'],'timestamp':response['timestamp']});
			$('#studio_song_select').replaceWith(response.song_select);
			appointment_chron();
		},
		cache: false,
		contentType: false,
		processData: false
	});
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
			var admin = response.studio['admin'] || {};
			$('#studio_song_select').val(response['uuid']);
			mixer['time'] = admin['time'] || mixer['time'];
			mixer['time']['metronome'] = admin['metronome'] || 'no';
			mixer['time']['bpm'] = admin['bpm'] || 120;
			mixer['time']['sig'] = admin['sig'] || '4/4';
			mixer['time']['status'] = 'stop';
			$('#studio_signature').val(mixer['time']['sig']);
			$('#studio_bpm').val(mixer['time']['bpm']);
			mixer['admin'] = mixer['admin'] || {};
			mixer['admin']['video_toggle'] = admin['video_toggle'];
			$('#studio_video_toggle').attr('toggled', admin['video_toggle']);
			$('.studio_config[setting="record_offset"]').val(mixer['time']['record_offset'] || '');
			$('.studio_config[setting="crossfade"]').val(mixer['time']['crossfade'] || '');
			$('.studio_config[setting="loop_bars"]').val(mixer['time']['loop_bars'] === undefined ? 4 : mixer['time']['loop_bars']);
			$('.studio_config[setting="count_in"]').val(mixer['time']['count_in'] || '');
			$('.studio_config[setting="snap"]').val(mixer['time']['snap'] || 'bar');
			$('.studio_config[setting="monitor"]').val(mixer['time']['monitor'] || 'no');
			studioApplyMonitor();
			studioUpdateLatencyInfo();
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

			mixer['time']['duration'] = studioKnobNumber(response.song && response.song.duration, 0) || 0;

			// Rebuild each channel's takes from the saved metadata so they play
			// back and can be re-saved.
			$.each(response.studio, function(i,v) {
				if (!/^[0-9]+$/.test(i) || !v['mixer'] || !v['mixer']['out']) { return; }
				if (!mixer[i]) { mixer[i] = {}; }
				if (!mixer[i].media) { mixer[i].media = {}; }
				mixer[i].media.out = [];
				mixer[i].media.rec = [];
				$.each(v['mixer']['out'], function(ir, vr) {
					if (!vr) { return; }
					var id = 'studio_channel_' + i + '_' + ir;
					$('#' + id).remove();
					var el = document.createElement('video');
					el.className = 'studio_video';
					el.id = id;
					el.style.display = 'none';
					el.preload = 'auto';
					if (vr['src']) { el.src = vr['src']; }
					$('#studio_track_container').append(el);
					var startTime = studioKnobNumber(vr['startTime'], 0);
					var duration = studioKnobNumber(vr['duration'], 0);
					mixer[i].media.out[ir] = {
						uuid: vr['uuid'], startTime: startTime, offset: studioKnobNumber(vr['offset'], 0),
						duration: duration, encoding: vr['encoding'], src: vr['src'], status: 'stop', track: el,
						loop: vr['loop'] ? true : false
					};
					studioTakeRequestBuffer(mixer[i].media.out[ir]);
					mixer['time']['duration'] = Math.max(mixer['time']['duration'], startTime + duration);
				});
			});

			studioSongSet(response.studio);
			studioRetriever();
			mixer['buttons'] = buttons;
			studioTimeDisplay();
			studioDrawTracks();
		}
	});
}

function studioImport(files) {
	// Bring audio/video files in as takes on the selected channel.
	var ch = studioSelectedChannel;
	if (!mixer[ch]) { mixer[ch] = {}; }
	if (!mixer[ch].media) { mixer[ch].media = {}; }
	if (!mixer[ch].media.out) { mixer[ch].media.out = []; }
	$.each(files, function(i, file) {
		var ir = mixer[ch].media.out.length;
		var id = 'studio_channel_' + ch + '_' + ir;
		var el = document.createElement('video');
		el.className = 'studio_video';
		el.id = id;
		el.style.display = 'none';
		el.preload = 'auto';
		el.src = URL.createObjectURL(file);
		$('#studio_track_container').append(el);
		var take = { uuid: null, startTime: mixer['time']['position'] || 0, offset: 0, duration: 0, status: 'stop', track: el, data: file, encoding: file.type };
		el.addEventListener('loadedmetadata', function() {
			take.duration = el.duration || 0;
			mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + take.duration);
			studioDrawTracks();
		});
		mixer[ch].media.out[ir] = take;
		studioTakeRequestBuffer(take);
	});
	studioDrawTracks();
	studioTakesChanged();
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

$(document).on('click', '#studio_config_toggle, .studio_config_toggle_close', function() {
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
		studioUpdateLatencyInfo();
	}
});

$(document).on('change', '.studio_config', function() {
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var restart = $(this).attr('restart');
	if (setting == 'record_offset') {
		mixer['time']['record_offset'] = value;
		studioSaver();
		studioUpdateLatencyInfo();
		return;
	}
	if (setting == 'crossfade') {
		mixer['time']['crossfade'] = value;
		studioSaver();
		studioDrawTracks();
		studioTakesChanged();
		return;
	}
	if (setting == 'loop_bars') {
		mixer['time']['loop_bars'] = value;
		// no reserved bars: loop takes still snap their length to whole bars
		if (!(studioKnobNumber(value, 0) > 0)) { mixer['time']['loop_region'] = null; }
		studioSaver();
		studioDrawTracks();
		return;
	}
	if (setting == 'count_in') {
		mixer['time']['count_in'] = value;
		studioSaver();
		return;
	}
	if (setting == 'snap') {
		mixer['time']['snap'] = value;
		studioSaver();
		studioDrawTracks();
		return;
	}
	if (setting == 'sample_rate') {
		// the audio context is built with one fixed rate, so it has to be rebuilt
		mixer['settings'] = mixer['settings'] || {};
		mixer['settings'][setting] = value;
		studioRebuildWindow(setting, value);
		return;
	}
	if (setting == 'latency_hint') {
		// the buffer hint is fixed when the AudioContext is built, so rebuild
		mixer['settings'] = mixer['settings'] || {};
		mixer['settings'][setting] = value;
		if (String(value).length > 0) { studioSaveSettings([{ 'setting': setting, 'value': value }]); }
		studioRebuildWindow(setting, value);
		return;
	}
	if (setting == 'video_height' || setting == 'video_fps' || setting == 'video_mbps' ||
		setting == 'audio_kbps' || setting == 'audio_channels') {
		mixer['settings'] = mixer['settings'] || {};
		mixer['settings'][setting] = value;
		if (String(value).length > 0) { studioSaveSettings([{ 'setting': setting, 'value': value }]); }
		studioApplyCapture();
		return;
	}
	if (setting == 'monitor') {
		mixer['time']['monitor'] = value;
		studioApplyMonitor();
		studioSaver();
		return;
	}
	if (restart == 'yes') {
		setTimeout(function() {
			studioInit({ 'settings': [{ 'setting': setting, 'value': value }] });
		},500);
	} else {
		mixer['settings'][setting] = value;
		studioRetriever();
	}
});

// A junderground room can broadcast the studio: the master mix as one stream,
// and every live channel's recorded signal as its own, so a listener can hear
// the parts separately (the same signal the recorder gets, post-pedal).
window.jawnosMediaSources = window.jawnosMediaSources || {};

window.jawnosMediaSources.studio = function () {
	var ctx = studioContext();
	if (!ctx) { return null; }
	if (!studioAudio.broadcastDest) {
		studioAudio.broadcastDest = ctx.createMediaStreamDestination();
		studioAudio.master.connect(studioAudio.broadcastDest);
	}
	return studioAudio.broadcastDest.stream;
};

window.jawnosMediaSources.studioChannels = function () {
	var out = [];
	Object.keys(studioAudio.channels).sort(function (a, b) { return Number(a) - Number(b); }).forEach(function (ch) {
		var c = studioAudio.channels[ch];
		if (!c || !c.recDest || !c.recDest.stream) { return; }
		out.push({ id: 'studio_' + ch, label: 'Studio ' + ch, kind: 'audio', stream: c.recDest.stream });
	});
	return out;
};
