$(document).on('change', '#studio_latency_backend', function () { studioLatencyMeasure(); });

// The engine take panel beside the latency readout: two buttons and one knob
// per strip. The functions live in studio.js; these bind them to the markup.
$(document).on('click', '#studio_engine_start', function () { studioEngineStart(); });
$(document).on('click', '#studio_engine_stop', function () { studioEngineStop(); });
$(document).on('change', '#studio_engine_tracks', function () { studioEngineInputRows(); });
$(document).on('change', '.studio_engine_input_pick, .studio_engine_source_pick', function () {
	studioEngineInputSync();
	studioEngineSourceSync($(this).closest('.studio_engine_input_row'));
});
$(document).on('change', '.studio_engine_gain, .studio_engine_pan', function () {
	var name = $(this).hasClass('studio_engine_gain') ? 'gain' : 'pan';
	studioEngineParam($(this).attr('data-track'), name, $(this).val());
});

// The Listen control in the same panel: live monitoring, not a recording. The
// engine allows one capture at a time, so listening and a take exclude each
// other; its gain is a `param` addressed to `listen`.
$(document).on('click', '#studio_listen_toggle', function () { studioListenToggle(); });
$(document).on('change', '#studio_listen_input', function () {
	if (studioListenActive) { studioListenStart(); }
});
$(document).on('change', '#studio_listen_gain', function () { studioListenParam($(this).val()); });

async function studioStop() {
	// The engine owns the transport clock and click while it is on; stopping
	// the browser transport stops the engine's output too.
	if (typeof studioEngineTransportStop === 'function') { studioEngineTransportStop(); }
	var wasRecording = (mixer['time']['status'] == 'record');
	// a stop during the count-in cancels the take that never started
	mixer['time']['punch_in'] = null;
	mixer['time']['pending_takes'] = null;
	mixer['time']['engine_count_in'] = null;
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

function studioTime(command, fromEngine) {
	var svm = document.getElementById('studio_video_monitor');
	if (svm) { $(svm).show(); }

	if (command == 'start') {
		mixer['time']['lastMetronome'] = null;
		mixer['time']['startTime'] = Date.now() - (mixer['time']['position'] * 1000);
		// the transport runs on the AudioContext clock; takes and clicks are
		// placed a little ahead of now so timer jitter never reaches the ear.
		// A count-in asks for the browser segment only; the engine transport
		// starts at the punch-in beat, not at the top of the pre-roll.
		studioClockStart(mixer['time']['position'], fromEngine);
		clearInterval(mixer['time']['interval']);
		mixer['time']['interval'] = setInterval(studioTransportTick, 25);
		studioTransportTick();
		// the drum chart follows the transport; its own lookahead scheduler
		// starts from the same gesture, not from a note per transport tick
		if (typeof studioDrumsTransport === 'function') { studioDrumsTransport(true); }
	}
	else if (command == 'stop') {
		clearInterval(mixer['time']['interval']);
		mixer['time']['interval'] = 0;
		if (typeof studioDrumsTransport === 'function') { studioDrumsTransport(false); }
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

// The transport tick and the button blink both live in mixer, which studioInit
// replaces wholesale. Clear them before that (and on close) or the old ids are
// unreachable and keep a detached button subtree alive at 1 Hz.
function studioReleaseTimers() {
	if (mixer && mixer['time']) { clearInterval(mixer['time']['interval']); mixer['time']['interval'] = 0; }
	if (mixer && mixer['buttons']) {
		$.each(mixer['buttons'], function(i, v) { if (v) { clearInterval(v['interval']); v['interval'] = 0; } });
	}
}

// A take holds a Blob and its object URL; the window's hidden <video> is the
// only other owner. The transport is already stopped when this runs, so an
// element still marked playing is paused first: nothing should outlive the
// close, and revoking under a live element is the one case that would.
function studioReleaseTakes() {
	$.each(mixer, function(ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m || !m.media || !m.media.out) { return; }
		m.media.out.forEach(function(take) {
			if (!take) { return; }
			if (take.track) {
				try { if (!take.track.paused) { take.track.pause(); } } catch (e) {}
				if (take.track.parentNode) { take.track.parentNode.removeChild(take.track); }
			}
			if (take.src) { try { URL.revokeObjectURL(take.src); } catch (e) {} take.src = ''; }
			// studioImport never copies the URL onto take.src; there it lives only on
			// the element, so both owners have to let go.
			if (take.track && take.track.src) { try { URL.revokeObjectURL(take.track.src); } catch (e) {} take.track.src = ''; }
			take.data = null;
		});
		m.media.out = [];
	});
}

// Closing the Studio (or replacing it with another song) ends its transport and
// lets go of every take; the shared AudioContext is deliberately left alone.
function studioTeardown() {
	studioReleaseTimers();
	if (typeof studioEngineTransportStop === 'function') { studioEngineTransportStop(); }
	if (typeof studioFlushSources === 'function') { studioFlushSources(); }
	if (mixer && mixer['time']) { mixer['time']['punch_in'] = null; mixer['time']['pending_takes'] = null; mixer['time']['engine_count_in'] = null; mixer['time']['engine_take'] = false; mixer['time']['engine_transport'] = false; }
	studioAudio.playSeg = null;
	studioAudio.schedSeg = null;
	studioAudio.clickSeg = null;
	studioSelectedTake = null;
	studioTakeDrag = null;
	studioReleaseTakes();
}

if (window.jawnosAppTeardown) { jawnosAppTeardown['studio'] = studioTeardown; }

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
	// A count-in for an engine take ends on the punch-in beat: start the engine
	// transport and the take there, then keep ticking as a play from that point.
	if (typeof studioEngineCountInDue === 'function') { studioEngineCountInDue(); }
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

// The Open sheet: one row per saved studio song. The rows are rebuilt from the
// hidden song select every time the sheet opens, so the select the save
// response replaced is already the current list; the server still owns it.
function studioOpenDialogText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function studioOpenDialogTime(timestamp) {
	var ts = Number(timestamp);
	if (!ts || !isFinite(ts)) { return ''; }
	// A saved timestamp is milliseconds; tolerate a seconds value so an old
	// record still reads as a date.
	if (ts < 1000000000000) { ts = ts * 1000; }
	if (typeof fixedTimeString === 'function') { return fixedTimeString(ts); }
	return new Date(ts).toLocaleString();
}

function studioOpenDialogRows() {
	var list = $('#studio_open_dialog .studio_dialog_list');
	if (!list.length) { return 0; }
	list.empty();
	var rows = 0;
	$('#studio_song_select').find('option').each(function() {
		var option = $(this);
		var uuid = option.val();
		if (!uuid || uuid == 'none') { return; }
		var stamp = option.attr('data-timestamp') || '';
		var row = $('<button type="button"></button>')
			.addClass('studio_open_row hover')
			.attr('data-uuid', uuid);
		$('<span></span>').addClass('studio_open_name')
			.text(option.attr('data-app') || '').appendTo(row);
		$('<span></span>').addClass('studio_open_time')
			.attr('timestamp', stamp).text(studioOpenDialogTime(stamp)).appendTo(row);
		row.appendTo(list);
		rows++;
	});
	if (!rows) {
		$('<p></p>').addClass('studio_dialog_empty')
			.text(studioOpenDialogText('There are no saved studio songs yet.')).appendTo(list);
	}
	return rows;
}

function studioOpenDialogHide() {
	var dialog = $('#studio_open_dialog');
	if (!dialog.length || !dialog.is(':visible')) { return; }
	dialog.hide();
	$('#studio_open').attr('aria-expanded', 'false');
}

function studioOpenDialogShow() {
	var dialog = $('#studio_open_dialog');
	if (!dialog.length) { return; }
	studioOpenDialogRows();
	dialog.show();
	$('#studio_open').attr('aria-expanded', 'true');
	var first = dialog.find('.studio_open_row').first();
	if (first.length) { first.focus(); }
	else { $('#studio_open_close').focus(); }
}

$(document).on('click', '#studio_open', function(e) {
	e.preventDefault();
	studioOpenDialogShow();
});

$(document).on('click', '#studio_open_close', function() {
	studioOpenDialogHide();
});

$(document).on('click', '#studio_open_dialog .studio_open_row', function() {
	var uuid = $(this).attr('data-uuid');
	studioOpenDialogHide();
	if (uuid) { studioLoad(uuid); }
});

$(document).on('keydown', function(e) {
	if (e.key == 'Escape' || e.keyCode == 27) { studioOpenDialogHide(); }
});

// A press anywhere but the sheet itself (or the Open button that opened it)
// dismisses the list; pointerdown fires before the opening click can arrive.
$(document).on('pointerdown', function(e) {
	var dialog = $('#studio_open_dialog');
	if (!dialog.length || !dialog.is(':visible')) { return; }
	if ($(e.target).closest('#studio_open_dialog, #studio_open').length) { return; }
	studioOpenDialogHide();
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
				// A rendered WAV (an exported drum loop, for instance) keeps its
				// extension; the browser recorder's blobs are webm.
				var ext = (take.data.type && take.data.type.indexOf('wav') !== -1) ? '.wav' : '.webm';
				formData.append('blob', take.data, app + '_' + now + '_' + i + '_' + ir + ext);
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
	studioOpenDialogHide();
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
			$('.studio_config[setting="monitor"]').val(studioMonitorOn(studioSelectedChannel) ? 'yes' : 'no');
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
			// a different song opens on its whole timeline, not the old song's zoom
			studioTimelineReset();

			// a loaded song owns its track list; build any rows it needs and drop
			// the ones the previous song left behind
			studioSyncTrackList(response.studio);

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
						loop: vr['loop'] ? true : false,
						printed: vr['printed'] ? true : false
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
	// a recording owns the playhead: marks and the song end are not seekable
	if (!studioCanSeek()) { return; }
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
	var studio = $('#studio');
	var config = $('#studio_config');
	if (config.is(':visible')) {
		config.hide();
		// Removing the class brings the grid back exactly as its own hide
		// toggles left it; nothing here shows a panel the user hid.
		studio.removeClass('studio_config_open');
	} else {
		studio.addClass('studio_config_open');
		config.show();
		studioUpdateLatencyInfo();
		studioEngineStatus();
	}
});

// The Monitor control is per track: each strip hears its own live input. Only
// one track is monitored at a time, because the engine (Oboe or the house
// engine) opens one input stream; pressing another track's Monitor moves it.
function studioMonitorOn(ch) {
	ch = String(ch);
	if (!mixer || !mixer.monitor) { return false; }
	if (studioEngineRecording && String(studioMonitoredChannel()) === ch) {
		return studioEngineMonitorArmed === true && studioEngineMonitorLevel > 0;
	}
	return mixer.monitor[ch] ? true : false;
}

function studioMonitoredChannel() {
	if (!mixer || !mixer.monitor) { return null; }
	var found = null;
	$.each(mixer.monitor, function (ch, on) {
		if (on && found === null) { found = String(ch); }
	});
	return found;
}

function studioSetMonitor(ch, on, from_user) {
	ch = String(ch);
	// Pressing Monitor tries the engine again after an earlier refusal, so the
	// browser fallback is only for this attempt, not the rest of the session.
	studioMonitorEngineFailed = false;
	if (!mixer.monitor) { mixer.monitor = {}; }
	if (on) {
		$.each(mixer.monitor, function (other) { mixer.monitor[other] = 0; });
		mixer.monitor[ch] = 1;
	}
	else { mixer.monitor[ch] = 0; }
	// While an engine take records the same control arms the live input from
	// this moment (1) or silences it (0); the recording so far is unaffected
	// and the take keeps running either way.
	if (studioEngineRecording) {
		studioEngineMonitorArmed = !!on;
		studioEngineMonitorLevel = on ? 1 : 0;
		studioEngineMonitorGain(on ? 1 : 0);
	}
	if (typeof studioApplyMonitor === 'function') { studioApplyMonitor(!!from_user); }
	studioMonitorButtonRender();
	studioSaver();
}

function studioMonitorButtonRender() {
	$('.studio_track_monitor').each(function () {
		var ch = String($(this).attr('channel'));
		var on = studioMonitorOn(ch);
		$(this).attr('aria-pressed', on ? 'true' : 'false')
			.text(on ? studioListenText('Monitor on') : studioListenText('Monitor'));
	});
	$('.studio_config[setting="monitor"]').val(studioMonitorOn(studioSelectedChannel) ? 'yes' : 'no');
}

$(document).on('click', '.studio_track_monitor', function () {
	var ch = String($(this).attr('channel'));
	studioSetMonitor(ch, !studioMonitorOn(ch), true);
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
		studioSetMonitor(studioSelectedChannel, value == 'yes', true);
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

// ---- live listening --------------------------------------------------------
// The Listen toggle starts the engine's monitoring mode and Stop listen ends it.
// A listen is not a take: it carries an input number (0 microphone, 1
// instrument), a gain, and the Inserts box's chain. While it runs, status is
// polled so the row keeps showing the engine's state, input and frame count.

// Which capture path this page has. The app's Oboe stream wins, then the house
// engine's staged binary; the browser microphone is only for a machine with
// neither. A native path never falls back to getUserMedia: a failure is shown,
// not quietly replaced by the browser.
var studioAudioBackendMemo;
var studioEngineInstalled = false;
// Whether the engine's socket is live right now. The browser monitor reads it: a
// device with no engine falls back to the browser capture rather than silence.
var studioEngineAvailable = false;
// A Listen that was confirmed started and not confirmed stopped. The browser tap
// stays muted while this is true even if a status poll fails, so the same input
// is never played twice with a short delay between the copies.
var studioEngineListening = false;

function studioAudioBackend() {
	if (studioAudioBackendMemo !== undefined) { return studioAudioBackendMemo; }
	if (typeof studioNativeAudio === 'function' && studioNativeAudio()) {
		studioAudioBackendMemo = 'oboe';
	}
	else if (studioEngineInstalled) {
		studioAudioBackendMemo = 'engine';
	}
	else {
		studioAudioBackendMemo = 'browser';
	}
	return studioAudioBackendMemo;
}

function studioAudioBackendReset() {
	studioAudioBackendMemo = undefined;
}

// The Android app registers window.JawnAudioOboe: a native duplex stream that
// is the phone's own monitor. When it is there the Listen toggle and the
// transport's Monitor button drive it instead of the house engine's listen;
// the physical volume keys move STREAM_MUSIC and the stream follows it.
var studioNativeBridge;
var studioNativeListening = false;

function studioNativeAudio() {
	if (studioNativeBridge !== undefined) { return studioNativeBridge; }
	studioNativeBridge = null;
	try {
		if (window.JawnAudioOboe && typeof window.JawnAudioOboe.load === 'function') {
			var info = JSON.parse(window.JawnAudioOboe.load());
			if (info && info.ok === 1) { studioNativeBridge = window.JawnAudioOboe; }
		}
	} catch (e) { studioNativeBridge = null; }
	return studioNativeBridge;
}

function studioNativeStatus() {
	var bridge = studioNativeAudio();
	if (!bridge) {
		studioNativeListening = false;
		studioEngineListening = false;
		studioListenPollStop();
		studioListenSetActive(false);
		return;
	}
	var data = {};
	try { data = JSON.parse(bridge.stats()); } catch (e) { data = {}; }
	if (!data || data.ok !== 1) {
		studioNativeListening = false;
		studioEngineListening = false;
		studioListenPollStop();
		studioListenSetActive(false);
		studioListenShowError((data && data.error) || studioListenText('the native audio bridge did not answer'));
		return;
	}
	var on = !!(data.running || data.waiting);
	studioListenSetActive(on);
	if (on && data.running && typeof studioInputReleaseForMonitor === 'function') {
		studioInputReleaseForMonitor();
	}
	if (!on) {
		studioNativeListening = false;
		studioEngineListening = false;
		studioListenPollStop();
		if (typeof studioInputResumeAfterMonitor === 'function') { studioInputResumeAfterMonitor(); }
		if (data.error) { studioListenShowError(data.error); }
		else if (data.microphone === false) { studioListenShowError(studioListenText('the microphone permission is not granted')); }
	}
	studioListenRender({ state: data.state, channel: 0, frames: data.frames, native: data });
}

function studioNativeStart(quiet) {
	var bridge = studioNativeAudio();
	if (!bridge) { return; }
	var rate = (typeof studioSampleRate === 'function') ? studioSampleRate() : 48000;
	if (!(rate > 0)) { rate = 48000; }
	var gain = $('#studio_listen_gain').val() || '0.8';
	var answer = {};
	try {
		answer = JSON.parse(bridge.start(String(rate), '192', String(gain)));
	} catch (e) {
		answer = { ok: 0, error: studioListenText('the native audio bridge did not answer') };
	}
	if (answer && answer.ok !== 1 && answer.waiting) {
		studioNativeListening = true;
		studioListenSetActive(true);
		studioListenRender({ state: 'waiting', channel: 0, frames: 0, native: answer });
		studioListenPollStart();
		return;
	}
	if (!answer || answer.ok !== 1) {
		studioNativeListening = false;
		studioListenSetActive(false);
		if (!(quiet && studioListenNotRunning(answer && answer.error))) {
			studioListenShowError((answer && answer.error) || studioListenText('the native audio bridge did not answer'));
		}
		return;
	}
	studioNativeListening = true;
	studioEngineListening = true;
	studioListenSetActive(true);
	if (typeof studioInputReleaseForMonitor === 'function') { studioInputReleaseForMonitor(); }
	studioListenRender({ state: answer.state, channel: 0, frames: answer.frames, native: answer });
	studioListenPollStart();
}

var studioListenTimer = 0;
var studioListenActive = false;
// The engine input the running Listen names, so Monitor can tell when another
// track (or another input) has become the one to hear.
var studioListenChannel = null;

function studioListenText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function studioListenInputText(channel) {
	return (Number(channel) === 1) ? studioListenText('Instrument') : studioListenText('Microphone');
}

function studioListenSetActive(active) {
	studioListenActive = !!active;
	if (!studioListenActive) { studioListenChannel = null; }
	var button = $('#studio_listen_toggle');
	if (button.length) {
		button.attr('aria-pressed', studioListenActive ? 'true' : 'false');
		button.text(studioListenActive ? studioListenText('Listening') : studioListenText('Listen'));
	}
	// The transport's Monitor button is the same live path; when Listen starts
	// or stops, the button says so too.
	if (typeof studioMonitorButtonRender === 'function') { studioMonitorButtonRender(); }
}

function studioListenRender(data) {
	data = data || {};
	var state = (typeof data.state == 'string' && data.state.length) ? data.state : '\u2014';
	$('#studio_listen_state').text(studioListenText('State') + ' ' + state);
	var channel = (typeof data.channel == 'number') ? data.channel : $('#studio_listen_input').val();
	$('#studio_listen_input_text').text(studioListenText('Input') + ' ' + studioListenInputText(channel));
	var frames = (typeof data.frames == 'number' && isFinite(data.frames))
		? String(data.frames) : '\u2014';
	if (data.native) {
		var native = data.native;
		var facts = [];
		if (native.sharingMode) { facts.push('share ' + native.sharingMode); }
		if (native.performanceMode) { facts.push('perf ' + native.performanceMode); }
		if (native.sampleRate) { facts.push(native.sampleRate + ' Hz'); }
		if (native.framesPerBurst) { facts.push(native.framesPerBurst + ' fr'); }
		if (typeof native.xRunCount == 'number') { facts.push('xrun ' + native.xRunCount); }
		if (typeof native.systemVolume == 'number') {
			facts.push('vol ' + Math.round(native.systemVolume * 100) + '%'
				+ (native.systemVolumeApplied ? ' engine' : ' mixer'));
		}
		facts.push(studioListenText('Frames') + ' ' + frames);
		$('#studio_listen_frames').text(facts.join(' \u00b7 '));
		return;
	}
	$('#studio_listen_frames').text(studioListenText('Frames') + ' ' + frames);
}

function studioListenPollStart() {
	if (studioListenTimer) { return; }
	studioListenTimer = setInterval(studioListenStatus, 750);
}

function studioListenPollStop() {
	if (studioListenTimer) { clearInterval(studioListenTimer); studioListenTimer = 0; }
}

function studioListenStatus() {
	if (studioNativeListening) { studioNativeStatus(); return; }
	if (!$('#studio_listen_toggle').length) { studioListenPollStop(); return; }
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'status' },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioListenPollStop();
				studioListenSetActive(false);
				studioListenShowError(data.error || studioListenText('the audio engine did not answer'));
				return;
			}
			if (data.state === 'listening') {
				studioListenSetActive(true);
				studioListenRender(data);
				studioListenPollStart();
			} else {
				studioListenPollStop();
				studioListenSetActive(false);
				studioListenRender(data);
			}
		},
		error: studioListenFailed
	});
}

function studioListenShowError(text) {
	text = text || '';
	var el = $('#studio_engine_error');
	if (el.length) { el.text(text); }
	// The Monitor button is in the transport, where the error must be visible
	// even when Configure is closed.
	$('#studio_monitor_note').text(text);
}

// `the audio engine is not running on this machine` is not an error when the
// person merely pressed Monitor: the browser path is the fallback, so a quiet
// start leaves the engine's panel alone.
function studioListenNotRunning(error) {
	return /not running/i.test(String(error || ''));
}

function studioListenFailed(xhr, quiet) {
	var data = xhr && xhr.responseJSON;
	studioListenPollStop();
	studioListenSetActive(false);
	if (typeof studioInputResumeAfterMonitor === 'function') { studioInputResumeAfterMonitor(); }
	var error = (data && data.error) ? data.error : studioListenText('the audio engine did not answer');
	if (!(quiet && studioListenNotRunning(error))) { studioListenShowError(error); }
}

// Live listening is one input, not a take: its pedals are the selected
// track's rack, in order and enabled only. A browser input picker cannot show
// an interface the engine owns (WirePlumber hands it over), so this is the
// path a guitar plugged into the UM2 is heard through.
function studioListenInserts(ch) {
	ch = (ch === undefined || ch === null) ? studioSelectedChannel : ch;
	var c = studioAudio.channels[ch];
	if (!c || !c.inserts) { return ''; }
	return c.inserts.filter(function (ins) {
		// the native engine has no stereo widener: an insert list it cannot
		// build must omit the name rather than refuse the whole take
		return ins && !ins.bypassed && studioEffectBuilder(ins.name)
			&& studioEffectKind(ins.name) !== 'stereowidener';
	}).map(function (ins) { return studioEffectKind(ins.name); }).join(',');
}

// `channel` and `ch` let Monitor name the input and rack the track's own; the
// Configure Listen control leaves both unset and uses its own pickers. `fallback`
// is Monitor's: when the engine cannot start, the browser capture takes over
// instead of a silent monitor.
function studioListenStart(quiet, channel, ch, fallback) {
	studioListenShowError('');
	if (studioNativeAudio()) { studioNativeStart(quiet); return; }
	var listen_channel = (channel === undefined || channel === null)
		? $('#studio_listen_input').val() : String(channel);
	var request = {
		action: 'listen_start',
		channel: listen_channel,
		gain: $('#studio_listen_gain').val(),
		inserts: studioListenInserts(ch)
	};
	// Monitor wants its input alone; the standalone Listen keeps the house mix.
	if (fallback) { request.system = 0; }
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: request,
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioListenSetActive(false);
				if (fallback && typeof studioMonitorEngineFallback === 'function') { studioMonitorEngineFallback(); }
				if (!(quiet && studioListenNotRunning(data.error))) {
					studioListenShowError(data.error || studioListenText('the audio engine did not answer'));
				}
				studioListenRender(data);
				return;
			}
			studioEngineListening = true;
			studioListenSetActive(true);
			studioListenChannel = (typeof data.channel === 'number') ? data.channel : Number(listen_channel);
			if (typeof studioInputReleaseForMonitor === 'function') { studioInputReleaseForMonitor(); }
			studioListenRender(data);
			studioListenPollStart();
		},
		error: function (xhr) {
			studioListenFailed(xhr, quiet);
			if (fallback && typeof studioMonitorEngineFallback === 'function') { studioMonitorEngineFallback(); }
		}
	});
}

// `next_channel`/`ch` let Monitor move the one Listen to another track's input
// after the engine has stopped the old one; the Configure control passes none.
function studioListenStop(next_channel, ch) {
	if (studioNativeListening) {
		var bridge = studioNativeAudio();
		studioNativeListening = false;
		studioEngineListening = false;
		studioListenPollStop();
		studioListenSetActive(false);
		if (typeof studioInputResumeAfterMonitor === 'function') { studioInputResumeAfterMonitor(); }
		if (bridge) { try { bridge.stop(); } catch (e) {} }
		if (next_channel !== undefined) { studioListenStart(false, next_channel, ch, true); }
		return;
	}
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'listen_stop' },
		dataType: 'json',
		success: function (data) {
			studioListenPollStop();
			studioListenSetActive(false);
			if (typeof studioInputResumeAfterMonitor === 'function') { studioInputResumeAfterMonitor(); }
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioListenShowError(data.error || studioListenText('the audio engine did not answer'));
				return;
			}
			studioEngineListening = false;
			studioListenRender(data);
			if (next_channel !== undefined) { studioListenStart(false, next_channel, ch, true); }
		},
		error: studioListenFailed
	});
}

function studioListenToggle() {
	if (studioListenActive) { studioListenStop(); }
	else { studioListenStart(); }
}

function studioListenParam(value) {
	if (!studioListenActive) { return; }
	if (studioNativeListening) {
		var bridge = studioNativeAudio();
		if (bridge) { try { bridge.setGain(value); } catch (e) {} }
		return;
	}
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'param', target: 'listen', name: 'gain', value: value },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioListenShowError(data.error || studioListenText('the audio engine did not answer'));
				return;
			}
			studioListenRender(data);
		},
		error: studioListenFailed
	});
}
