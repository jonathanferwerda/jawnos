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
			var studio_defaults = response.settings || {};
			mixer = {
				time: {
					duration: 0, status: 'stop', position: 0, marks: [], interval: 0, startTime: 0,
					loop: 'off', metronome: 'no', bpm: 120, sig: '4/4', display: 'time', beat: 0, bar: 0,
					lastMetronome: null, loop_region: null, punch_in: null, pending_takes: null,
					// seeded from the app settings, then kept per song
					loop_bars: studio_defaults['loop_bars'] || 4,
					snap: studio_defaults['snap'] || 'bar',
					count_in: (studio_defaults['count_in'] === undefined ? '' : studio_defaults['count_in']),
					monitor: studio_defaults['monitor'] || 'no'
				},
				buttons: { record: { obg: '', bg: 'red', interval: '' }, stop: { obg: '', bg: 'lightgreen', interval: '' }, play: { obg: '', bg: 'yellow', interval: '' } },
				settings: response.settings,
				automations: {}
			};
			// fresh channel graphs, but keep the shared AudioContext
			studioFlushSources();
			studioAudio = { ctx: studioAudio.ctx, master: studioAudio.master, masterAnalyser: studioAudio.masterAnalyser, channels: {}, sources: [], lookahead: studioAudio.lookahead || 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
			studioSelectedTake = null;
			studioTakeDrag = null;
			studioSongCache = null;
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

			var channel_count = numeral(response.settings['channel_count']).value() || 4;
			for (var ch = 1; ch <= channel_count; ch++) {
				studioChannelEngine(ch);
				studioApplyChannel(ch);
				studioDrawChannel(ch);
			}
			studioApplyPedals();
			studioUpdateFxBadges();
			studioApplyCapture();
			// the always-visible synth panel builds its own grid/presets/keys
			$(document).trigger('jawnos_synth_panel');
			studioApplyMonitor();
			studioUpdateLatencyInfo();

			// pedals are dragged from the pedalboard onto a channel strip
			$('.pedal_background').draggable({ helper: 'clone', revert: 'invalid', scroll: false, zIndex: 60000 });
			$('.channel').droppable({
				accept: '.pedal_background',
				tolerance: 'pointer',
				drop: function(event, ui) {
					var name = ui.draggable.attr('hint');
					var m = ($(this).attr('class') || '').match(/channel_(\d+)/);
					if (!name || !m) { return; }
					var ch = m[1];
					var c = studioAudio.channels[ch];
					studioSetInsert(ch, name, !(c && c.insertByName[name]));
					studioSaver();
				}
			});

			studioRetriever();
			studioUpdateKnobHints();
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
	studioSelectedTake = null;
	studioTakeDrag = null;
	$('#soundroom_sidebar_container').html('').hide();
	$('.cord').remove();
});



// ---- knobs ------------------------------------------------------------------
// A knob is dragged up/down, or rolled, to change its value. Its hidden
// <input class="knob_control"> stays in the DOM as the value store - the song
// saver, the channel and pedal appliers, and the tooltips all read it - but it
// is never shown: the old click-to-reveal slider was laid out below the pedal's
// full-width artwork, so it was hidden under the pedal.
var studioKnobDrag = null;

function studioKnobInput(knob) {
	return $('.knob_control[control="' + knob.attr('control') + '"][channel="' + knob.attr('channel') + '"]');
}

function studioKnobReadout(knob, value) {
	var el = $('#studio_knob_readout');
	if (!el.length) { el = $('<div id="studio_knob_readout"></div>').appendTo('body'); }
	var at = knob.offset() || { left: 0, top: 0 };
	el.text(Math.round(value)).css({ display: 'block', left: at.left + 'px', top: (at.top - 24) + 'px' });
	clearTimeout(studioKnobReadout.timer);
	studioKnobReadout.timer = setTimeout(function () { el.hide(); }, 1000);
}

// Set the input, apply it (its `change` handler rotates the knob and pushes the
// value into the audio graph) and show the value.
function studioKnobSet(knob, value) {
	var input = studioKnobInput(knob);
	if (!input.length) { return; }
	value = Math.max(0, Math.min(100, value));
	input.val(value);
	input.trigger('change');
	studioKnobReadout(knob, value);
}

$(document).on('pointerdown', '.knob', function (e) {
	if (e.originalEvent.button) { return; }
	var knob = $(this);
	var input = studioKnobInput(knob);
	if (!input.length) { return; }
	studioKnobDrag = { knob: knob, y: e.originalEvent.clientY, value: studioKnobNumber(input.val(), 0) };
	knob.addClass('knob_active');
	e.preventDefault();
});

$(document).on('pointermove', function (e) {
	if (!studioKnobDrag) { return; }
	var y = e.originalEvent.clientY;
	var dy = studioKnobDrag.y - y;
	if (!dy) { return; }
	studioKnobDrag.y = y;
	studioKnobDrag.value = Math.max(0, Math.min(100, studioKnobDrag.value + (dy * 0.7)));
	studioKnobSet(studioKnobDrag.knob, studioKnobDrag.value);
	e.preventDefault();
});

$(document).on('pointerup pointercancel', function () {
	if (!studioKnobDrag) { return; }
	studioKnobDrag.knob.removeClass('knob_active');
	studioKnobDrag = null;
});

// A wheel event, normalised to the old positive-up wheelDelta scale.
function studioWheelDelta(event) {
	var d = ('deltaY' in event) ? event.deltaY : (-event.wheelDelta);
	if (event.deltaMode === 1) { d *= 16; }
	else if (event.deltaMode === 2) { d *= 100; }
	return -d;
}

// Bound natively and non-passively so preventDefault actually stops the
// pedalboard scrolling under a knob; a delegated jQuery listener on document is
// passive in Chrome and cannot cancel the scroll.
function studioWheelHandler(event) {
	var target = event.target;
	if (!target || !target.closest) { return; }

	var knob = target.closest('.knob');
	if (knob) {
		var input = studioKnobInput($(knob));
		if (input.length) {
			studioKnobSet($(knob), studioKnobNumber(input.val(), 0) + (studioWheelDelta(event) / 30));
			event.preventDefault();
		}
		return;
	}

	var vol = target.closest('.channel_volume');
	if (vol) {
		$(vol).val(numeral($(vol).val()).value() + (studioWheelDelta(event) / 30));
		studioSaver();
		event.preventDefault();
		return;
	}

	var jog = target.closest('#studio_jog_wheel');
	if (jog) {
		var diff = studioWheelDelta(event) / 30;
		studio_jw_deg = (studio_jw_deg + diff);
		$(jog).css({ 'rotate': studio_jw_deg + 'deg' });
		mixer['time']['position'] = mixer['time']['position'] + diff / 10;
		studioTime('scroll');
		event.preventDefault();
	}
}

if ('onwheel' in document) { document.addEventListener('wheel', studioWheelHandler, { passive: false }); }
else { document.addEventListener('mousewheel', studioWheelHandler, { passive: false }); }

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
	if (/^[0-9]+$/.test(channel)) { studioApplyChannel(channel); }
	else { studioApplyPedals(); }
	studioUpdateKnobHints();
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

// (channel fader and jog wheel wheels are handled by studioWheelHandler)

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

// The song lives in memory as well as in localStorage. studioSaver runs on
// every knob move, and a synchronous localStorage write per move janks the
// drag; so the write is deferred a moment while the in-memory copy stays
// authoritative for studioRetriever, which reads it right after a save.
var studioSongCache = null;
var studioSongWrite = 0;

function studioSongStore(song) {
	studioSongCache = song;
	clearTimeout(studioSongWrite);
	studioSongWrite = setTimeout(function () {
		try { localStorage.setItem('studio', JSON.stringify(song)); } catch (e) {}
	}, 250);
}

// A song loaded from or saved to the server wants the disk copy right away.
function studioSongSet(song) {
	studioSongCache = song;
	clearTimeout(studioSongWrite);
	try { localStorage.setItem('studio', JSON.stringify(song)); } catch (e) {}
}

function studioSaver() {
	var song = {};
	var name = $('#studio').attr('name');
	var uuid = $('#studio').attr('uuid');

	$('.knob_control, .channel_volume').each(function(i,v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		var value = $(v).val();
		if (control == 'pan') {
			value = (value - 0) / (100 - 0) * ( 1 - -1) + -1;
		}
		if (song[channel] == undefined) { song[channel] = {}; }
		if (!song[channel]['plugs']) { song[channel]['plugs'] = { input: {}, output: {} }; }
		song[channel][control] = value;
	});
	$('.armed').each(function(i,v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		if (song[channel] == undefined) { song[channel] = {}; }
		song[channel][control] = { state: $(v).attr('state'), text: $(v).text() };
	});
	$('.studio_channel_information').each(function(inf,sci) {
		var text = $(sci).text();
		if (isJson(text)) {
			var info = JSON.parse(text);
			if (song[info['channel']] == undefined) { song[info['channel']] = {}; }
			if (!song[info['channel']]['plugs']) { song[info['channel']]['plugs'] = { input: {}, output: {} }; }
			song[info['channel']]['plugs'][info['direction']] = info;
		}
	});

	// per-channel insert rack (which pedals are in the chain, in order)
	$.each(studioAudio.channels, function(ch, c) {
		if (song[ch] == undefined) { song[ch] = {}; }
		song[ch]['fx'] = c.inserts.map(function(ins) { return ins.name; });
	});

	// recorded takes: metadata only, the audio blobs are uploaded by studioSave
	$.each(mixer, function(i,v) {
		if (!/^[0-9]+$/.test(i) || !mixer[i].media || !mixer[i].media.out) { return; }
		if (song[i] == undefined) { song[i] = {}; }
		song[i]['mixer'] = { out: [] };
		mixer[i].media.out.forEach(function(take, ir) {
			if (!take) { return; }
			song[i]['mixer'].out[ir] = {
				uuid: take.uuid, startTime: take.startTime, offset: take.offset || 0,
				duration: take.duration, encoding: take.encoding, src: take.src,
				loop: take.loop ? 1 : 0
			};
		});
	});

	var sl = $('#studio_loop').attr('enabled');
	var video_toggle = $('#studio_video_toggle').attr('toggled');
	song['admin'] = { time: mixer['time'], name: name, uuid: uuid, loop: sl, video_toggle: video_toggle,
		metronome: mixer['time']['metronome'], bpm: mixer['time']['bpm'], sig: mixer['time']['sig'] };
	studioSongStore(song);
	return song;
}

function studioRetriever() {
	var song = studioSongCache || JSON.parse(localStorage.getItem('studio') || '{}');

	$.each(song, function(i,v) {
		if (i == 'admin') {
			$.each(v, function(n,w) { mixer['admin'] = mixer['admin'] || {}; mixer['admin'][n] = w; });
			return;
		}
		if (!/^[0-9]+$/.test(i)) {
			// a pedal's knobs live under its own name
			$.each(v, function(n,w) {
				if (n == 'armed' || n == 'plugs' || n == 'mixer' || n == 'fx') { return; }
				$('[channel="' + i + '"][control="' + n + '"]').val(w);
			});
			return;
		}

		if (!mixer[i]) { mixer[i] = {}; }
		if (!mixer[i].armed) { mixer[i].armed = { state: 'off', text: 'O' }; }
		$.each(v, function(n,w) {
			if (n == 'plugs' || n == 'mixer' || n == 'fx') { return; }
			mixer[i][n] = w;
			if (n == 'armed') {
				$('[channel="' + i + '"][control="armed"]').attr('state', w.state).text(w.text);
				if (w.state == 'rec') { studioInputStreamGrabber(i, 'rec'); }
				return;
			}
			if (n == 'pan') { w = (w - -1) / (1 - -1) * (100 - 0) + 0; }
			$('[channel="' + i + '"][control="' + n + '"]').val(w);
		});

		// rebuild this channel's insert rack
		var c = studioChannelEngine(i);
		if (c) {
			c.inserts.slice().forEach(function(ins) { studioSetInsert(i, ins.name, false); });
			(v['fx'] || []).forEach(function(name) { studioSetInsert(i, name, true); });
		}
		studioApplyChannel(i);
	});

	studioApplyPedals();

	var met = $('#studio_metronome');
	if (mixer['time'] && mixer['time']['metronome'] == 'yes') {
		met.attr('armed', 'yes');
		if (met.attr('obg') != 'red') { met.attr('obg', met.css('background-color')); }
		met.css({ 'background-color': 'red' });
	} else {
		met.attr('armed', 'no');
		met.css({ 'background-color': met.attr('obg') || 'rgb(211, 211, 211)' });
	}
	if (mixer['time']) {
		if (mixer['time']['bpm']) { $('#studio_bpm').val(mixer['time']['bpm']); }
		if (mixer['time']['sig']) { $('#studio_signature').val(mixer['time']['sig']); }
		if (mixer['time']['loop']) { mixer['time']['loop'] = mixer['time']['loop']; }
	}

	mixer['settings'] = mixer['settings'] || {};
	mixer['settings']['channel_count'] = $('#studio_viewer').attr('channel_count');
	studioUpdateKnobHints();
	return song;
}

