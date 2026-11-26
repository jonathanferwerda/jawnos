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
			// The previous open's transport timers and take blobs belong to a window
			// that is being replaced. Release them before `mixer` is reassigned, or the
			// interval ids become unreachable and tick forever.
			if (typeof studioTeardown === 'function') { studioTeardown(); }
			var studio_defaults = response.settings || {};
			mixer = {
				time: {
					duration: STUDIO_NEW_SONG_SECONDS, status: 'stop', position: 0, marks: [], interval: 0, startTime: 0,
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
				automations: {},
				monitor: {}
			};
			// fresh channel graphs, but keep the shared AudioContext and its master rack
			studioFlushSources();
			studioAudio = { ctx: studioAudio.ctx, master: studioAudio.master, masterAnalyser: studioAudio.masterAnalyser, masterChain: studioAudio.masterChain, channels: {}, sources: [], lookahead: studioAudio.lookahead || 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
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

			var channel_count = numeral(response.settings['channel_count']).value() || 1;
			channel_count = Math.max(1, Math.min(32, channel_count));
			for (var ch = 1; ch <= channel_count; ch++) {
				studioChannelEngine(ch);
				studioApplyChannel(ch);
				studioDrawChannel(ch);
			}
			studioApplyPedals();
			studioUpdateFxBadges();
			studioRackRenderAll();
			studioMasterApply();
			studioApplyCapture();
			// the strips paint their mute and solo state now that the window is up
			if (typeof studioStripMuteSoloRender === 'function') { studioStripMuteSoloRender(); }
			studioApplyLayoutSettings();
			// the follow lock is a view preference, so a rebuilt window restores it
			if (typeof studioFollowSync === 'function') { studioFollowSync(); }
			studioApplyMonitor();
			// Ask the engine on the first frame: Monitor needs to know whether the
			// engine is there before the person presses it, not only after Configure
			// has been opened once.
			if (typeof studioEngineStatus === 'function') { studioEngineStatus(); }
			// the engine take's per-track Input/Source pickers come from the markup
			// the window just inserted; two channels until a status reply says more
			studioEngineInputRows();
			studioUpdateLatencyInfo();

			// a new window or song stops whatever the previous one was listening to
			if (typeof studioTunerStop === 'function') { studioTunerStop(); }
			// repaint the lamps now that the window is on the page
			if (typeof studioUpdatePedalLamps === 'function') { studioUpdatePedalLamps(); }

			studioRetriever();
			// the drum panel reads its state from the song (restored above) and
			// builds its voices once the window is on the page
			if (typeof studioDrumsInit === 'function') { studioDrumsInit(); }
			// The transport's Engine/Browser badge and the output's name come from
			// the same Sound plan; neither waits for Configure to be opened.
			if (typeof studioOutputLoad === 'function') { studioOutputLoad(); }
			if (typeof studioAudioPathRender === 'function') { studioAudioPathRender(); }
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

// The value a knob holds, printed above it. A knob is a picture of a rotation, so
// the number is what tells a chain reloaded from the song where each control was
// left; the label is made on the first paint and kept beside its knob.
function studioKnobValue(knob, value) {
	var label = knob.closest('.pedal_knob').length
		? knob.parent().children('.knob_value').first()
		: knob.nextAll('.knob_value').first();
	if (!label.length) {
		label = $('<b class="knob_value" aria-hidden="true"></b>');
		if (knob.closest('.pedal_knob').length) {
			label.prependTo(knob.parent());
		}
		else {
			// the artwork tiles lay their knobs out in percents of the pedal
			var style = knob[0].style;
			label.css({
				left: style.left || '0px',
				width: style.width || '0px',
				top: 'calc(' + (style.top || '0px') + ' - 15px)'
			});
			label.insertAfter(knob);
		}
	}
	label.text(Math.round(value));
}

// Paint one knob from its input: the picture's angle and, on a pedal, the value
// above it. `scope` is the tile being built: a board tile is cloned out of the
// library and is not in the document yet when its saved values are applied, and
// a knob that was never painted is why a reloaded chain looked all zeroes.
function studioKnobPaint(input, scope) {
	var channel = input.attr('channel');
	var control = input.attr('control');
	if (!channel || !control) { return; }
	var value = studioKnobNumber(input.val(), 0);
	var root = (scope && $(scope).length) ? $(scope) : $(document);
	root.find('.knob[control="' + control + '"][channel="' + channel + '"]').each(function () {
		var knob = $(this);
		var flip = numeral(knob.attr('flip')).value() || 0;
		var range = numeral(knob.attr('range')).value() || .85;
		var turn = numeral((360 / 100) * (value * range)).value();
		var angle = (knob.attr('direction') == 'counter') ? (flip - turn) : (flip + turn);
		knob.css({ transform: 'rotate(' + angle + 'deg)' });
		if (knob.closest('.pedal').length) { studioKnobValue(knob, value); }
	});
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

// Where a knob goes back to when it is double-clicked. On a rack tile the live
// insert knows: its builder's own starting value is the default. A guessed 50
// is wrong for a model index or a delay time, so the reset uses the insert's
// own builder value. Outside a rack the knob's own `data-default` is next, and
// a strip control that has neither is a 0..100 trim/eq/pan that starts mid-way.
function studioKnobDefault(knob, input) {
	var tile = knob.closest('.studio_rack_tile');
	if (tile.length) {
		var ch = tile.attr('channel');
		var name = tile.attr('insert');
		var c = studioAudio.channels[ch];
		if (c && name) {
			var ins = (tile.attr('chain') === 'out') ? c.outInsertByName[name] : c.insertByName[name];
			if (ins && ins.defaults && ins.defaults[input.attr('control')] !== undefined) {
				return ins.defaults[input.attr('control')];
			}
		}
	}
	var preset = input.attr('data-default');
	if (preset !== undefined && preset !== '') { return studioKnobNumber(preset, 50); }
	return 50;
}

// A double-click puts a knob back to its default. The press is swallowed so the
// second half of it cannot also reach the pedal tile under the knob.
$(document).on('dblclick', '.knob', function (e) {
	if ($(this).closest('#studio_pedalboard_tiles').length) { return; }
	var knob = $(this);
	var input = studioKnobInput(knob);
	if (!input.length) { return; }
	e.preventDefault();
	e.stopPropagation();
	studioKnobSet(knob, studioKnobDefault(knob, input));
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
		studioChannelVolumeSet($(vol).attr('channel'), numeral($(vol).val()).value() + (studioWheelDelta(event) / 30));
		event.preventDefault();
		return;
	}

	var jog = target.closest('#studio_jog_wheel');
	if (jog) {
		// while a take records the playhead stays where the take put it
		if (!studioCanSeek()) { event.preventDefault(); return; }
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
	var control = input.attr('control');

	studioKnobPaint(input);
	if (/^[0-9]+$/.test(channel)) { studioApplyChannel(channel); }
	else { studioApplyPedals(); }
	// Pan is part of the engine clip plan; other knobs are not, so only a pan
	// change on a running engine posts a replacement plan.
	if (control == 'pan' && typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); }
	studioUpdateKnobHints();
	studioSaver();
});

$(document).on('click', '.button_control', function(e) {
	var b = $(this);
	var tile = b.closest('.pedal');
	// The tuner's pink switch is its power, not an effect's bypass; stop the
	// click so the tile's own handler cannot toggle it a second time.
	if (tile.length && tile.attr('data-tuner') === 'yes') {
		e.stopPropagation();
		if (typeof studioTunerToggle === 'function') { studioTunerToggle(tile.attr('chain')); }
		return;
	}
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
	// A shelf pedal's artwork button is its footswitch too: it switches the
	// effect on the selected track, exactly as the pedal's lamp does.
	if (tile.length && tile.attr('data-tuner') !== 'yes' && typeof studioTogglePedal === 'function') {
		var effect = tile.attr('data-effect');
		if (effect) { studioTogglePedal(tile.attr('channel') || studioPaletteChannel(), effect, tile.attr('chain')); }
	}
	studioSaver();
});

// (channel fader and jog wheel wheels are handled by studioWheelHandler)

// One track volume, two controls: the slider under the track and the fader in
// the console strip. Either one writes both, the song and the playback gain, so
// they can never disagree.
function studioChannelVolumeSet(ch, value) {
	if (!ch) { return; }
	value = Math.max(0, Math.min(100, studioKnobNumber(value, 1)));
	$('.channel_volume[channel="' + ch + '"]').val(value);
	var c = studioAudio.channels[ch];
	if (c && (c.playBus || c.printBus)) { try { studioChannelFader(ch, value); } catch (e) {} }
	// the fader is one factor of the mix, not the whole of it: a muted or
	// solo-silenced channel stays silent while its fader moves
	studioApplyPlaybackMix();
	// The engine folds the fader into each clip's strip, so a running engine
	// needs the new plan; the browser path is unchanged when it is not.
	if (typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched()) { studioTakesChanged(); }
	studioSaver();
}

$(document).on('input change', '.channel_volume', function() {
	studioChannelVolumeSet($(this).attr('channel'), $(this).val());
});

// A track's colour is live: it redraws that canvas and the song keeps it. The
// swatch is not a channel control, so it has its own small handler and never
// runs through the knob/fader appliers above.
$(document).on('input change', '.studio_track_colour', function() {
	var input = $(this);
	var channel = input.attr('channel');
	if (!/^[0-9]+$/.test(channel)) { return; }
	studioApplyTrackColour(channel, input.val());
	studioSaver();
});

// The selection handler skips inputs so a fader drag does not reselect; picking
// a colour still means picking that track, so the swatch selects it here.
$(document).on('click', '.studio_track_colour', function() {
	var channel = $(this).attr('channel');
	if (!/^[0-9]+$/.test(channel)) { return; }
	$('.channel, .studio_track_panel').removeClass('selected_channel');
	$('.studio_track_panel[channel="' + channel + '"]').addClass('selected_channel');
	$('#studio_mixer_strips .channel_' + channel).addClass('selected_channel');
	studioSelectedChannel = channel;
});

$(document).on('click', '#studio_loop', function() {
	var sl = $(this);
	var loop = sl.attr('enabled');

	if (sl.attr('enabled') == 'ongoing') {
		loop = 'off';
		sl.attr('enabled', loop);
		sl.css({'background-color': 'var(--panel-2)' });
	}
	else if (sl.attr('enabled') == 'on') {
		loop = 'ongoing';
		sl.attr('enabled', loop);
		sl.css({'background-color': 'var(--accent-soft, var(--accent))' });
	}
	else {
		loop = 'on';
		sl.attr('enabled', loop);
		sl.css({'background-color': 'var(--runway-bad, #b3453f)' });
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
	// Adding a track clones markup and resets its controls; those changes are not
	// a user edit, so do not write a half-built song over the live one.
	if (typeof studioLayoutQuiet != 'undefined' && studioLayoutQuiet) {
		return studioSongCache || {};
	}
	var song = {};
	var name = $('#studio').attr('name');
	var uuid = $('#studio').attr('uuid');

	$('.knob_control, .channel_volume, .studio_pedal_model').not('#studio_pedalboard_tiles *').each(function(i,v) {
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
	$('.studio_track_name').each(function(i,v) {
		var channel = $(v).attr('channel');
		if (!/^[0-9]+$/.test(channel)) { return; }
		if (song[channel] == undefined) { song[channel] = {}; }
		song[channel]['name'] = $(v).val();
	});
	$('.studio_track_automation').each(function(i,v) {
		var channel = $(v).attr('channel');
		if (!/^[0-9]+$/.test(channel)) { return; }
		if (song[channel] == undefined) { song[channel] = {}; }
		song[channel]['automation_view'] = $(v).attr('aria-pressed') == 'true' ? 1 : 0;
	});
	// The per-track Monitor choice is the song's too; the button records it.
	$('.studio_track_monitor').each(function(i,v) {
		var channel = $(v).attr('channel');
		if (!/^[0-9]+$/.test(channel)) { return; }
		if (song[channel] == undefined) { song[channel] = {}; }
		song[channel]['monitor'] = $(v).attr('aria-pressed') == 'true' ? 'yes' : 'no';
	});
	// A track's colour is part of the song like its name. It gets its own pass
	// rather than joining the knob/fader selector, so it never reaches the
	// channel appliers: it dresses the row and the canvas, not the audio graph.
	$('.studio_track_colour').each(function(i,v) {
		var channel = $(v).attr('channel');
		if (!/^[0-9]+$/.test(channel)) { return; }
		if (song[channel] == undefined) { song[channel] = {}; }
		song[channel]['colour'] = $(v).val();
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

	// per-channel insert rack: the chain in order, each insert's footswitch and
	// the values its controls hold. The order and the on/off state are the song's;
	// the old shape (an array of names) still loads via studioRetriever.
	// A track's own row height is part of the song, like its name.
	$('#studio_viewer .studio_track').each(function () {
		var ch = $(this).attr('data-channel');
		if (!/^[0-9]+$/.test(ch)) { return; }
		// a hidden tracks panel measures zero: keep the height the song already has
		var h = Math.round(this.getBoundingClientRect().height);
		if (h < 64) { return; }
		if (song[ch] == undefined) { song[ch] = {}; }
		song[ch]['track_height'] = h;
	});

	$.each(studioAudio.channels, function(ch, c) {
		if (song[ch] == undefined) { song[ch] = {}; }
		song[ch]['fx'] = c.inserts.map(function(ins) {
			var controls = {};
			$.each(ins.values || {}, function(control, value) { controls[control] = value; });
			return { name: ins.name, on: !ins.bypassed, controls: controls };
		});
		// The output chain plays after the take and never touches it; the selected
		// chain is the rack's own view. Both are the song's, in the same shape as
		// the input chain, so a reload shows the same two racks.
		song[ch]['fx_out'] = c.outInserts.map(function(ins) {
			var controls = {};
			$.each(ins.values || {}, function(control, value) { controls[control] = value; });
			return { name: ins.name, on: !ins.bypassed, controls: controls };
		});
		song[ch]['fx_chain'] = (c.rackChain === 'out') ? 'out' : 'in';
	});

	// Mute and solo are the song's mix state too.
	$.each(mixer, function(ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m) { return; }
		if (song[ch] == undefined) { song[ch] = {}; }
		song[ch]['mute'] = m.mute ? 1 : 0;
		song[ch]['solo'] = m.solo ? 1 : 0;
	});

	// recorded takes: metadata only, the audio blobs are uploaded by studioSave
	$.each(mixer, function(i,v) {
		if (!/^[0-9]+$/.test(i) || !mixer[i].media || !mixer[i].media.out) { return; }
		if (song[i] == undefined) { song[i] = {}; }
		song[i]['mixer'] = { out: [] };
		mixer[i].media.out.forEach(function(take, ir) {
			if (!take) { return; }
			// A note clip's notes are the source of truth and its WAV is only a
			// browser cache, so it keeps no uuid and no stale blob URL. A real
			// take keeps its file and may still carry notes for a later edit.
			song[i]['mixer'].out[ir] = {
				uuid: take.note_clip ? null : take.uuid, startTime: take.startTime, offset: take.offset || 0,
				duration: take.duration, encoding: take.encoding, src: take.note_clip ? null : take.src,
				loop: take.loop ? 1 : 0,
				// A bounced take already carries its Out pedals; the reloaded
				// take must keep skipping them on playback and export.
				printed: take.printed ? 1 : 0,
				note_clip: take.note_clip ? 1 : 0,
				notes: take.notes || null,
				patch: take.patch || null,
				beats: take.beats || 0,
				clip_id: take.clip_id || null
			};
		});
	});

	var sl = $('#studio_loop').attr('enabled');
	var video_toggle = $('#studio_video_toggle').attr('toggled');
	var tracks = [];
	$('#studio_viewer .studio_track').each(function() { tracks.push($(this).attr('data-channel')); });
	song['admin'] = { time: mixer['time'], name: name, uuid: uuid, loop: sl, video_toggle: video_toggle,
		metronome: mixer['time']['metronome'], bpm: mixer['time']['bpm'], sig: mixer['time']['sig'],
		tracks: tracks, master: studioMasterSave(), drums: studioDrumsSave(),
		settings: { channel_count: String(tracks.length || 1) } };
	studioSongStore(song);
	return song;
}

function studioRetriever() {
	var song = studioSongCache || JSON.parse(localStorage.getItem('studio') || '{}');
	var rack_restore = [];
	// A saved song may carry more tracks than the window currently shows, but a
	// new song (no uuid) must not inherit the previous song's rows from the cache.
	var current_uuid = String($('#studio').attr('uuid') || '');
	var saved_uuid = (song['admin'] && song['admin']['uuid']) ? String(song['admin']['uuid']) : '';
	if (current_uuid && (!saved_uuid || saved_uuid == current_uuid)) {
		studioEnsureTracksForSong(song);
	}

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
			if (n == 'plugs') {
				// The jacks are part of the song. Restore each direction before the
				// channel is wired, so the picker reopens on the same row and an
				// output send points at the channel it names.
				var plugs = (w && typeof w == 'object') ? w : {};
				$.each(['input', 'output'], function (_, dir) {
					var info = plugs[dir];
					var target = $('.studio_channel_information[direction="' + dir + '"][channel="' + i + '"]');
					if (info && typeof info == 'object' && (info['type'] || info['app'])) {
						if (!info['channel']) { info['channel'] = i; }
						if (!info['direction']) { info['direction'] = dir; }
						target.text(JSON.stringify(info));
					}
					else { target.text(''); }
				});
				return;
			}
			if (n == 'mixer' || n == 'fx' || n == 'fx_out' || n == 'fx_chain') { return; }
			if (n == 'monitor') {
				if (!mixer.monitor) { mixer.monitor = {}; }
				mixer.monitor[i] = (w == 'yes' || w == 1 || w == '1' || w === true) ? 1 : 0;
				return;
			}
			if (n == 'mute' || n == 'solo') {
				mixer[i][n] = (w == 1 || w == '1' || w === true);
				return;
			}
			mixer[i][n] = w;
			if (n == 'name') {
				$('.studio_track_name[channel="' + i + '"]').val(w);
			}
			if (n == 'colour') {
				// the swatch and the row's custom property, not a channel control
				studioApplyTrackColour(i, w);
				return;
			}
			if (n == 'automation_view') {
				var on = (w == 1 || w == '1' || w === true);
				$('.studio_track_automation[channel="' + i + '"]').attr('aria-pressed', on ? 'true' : 'false');
				$('#studio_track_row_' + i).toggleClass('studio_track_automation_on', on);
			}
			if (n == 'armed') {
				$('[channel="' + i + '"][control="armed"]').attr('state', w.state).text(w.text);
				if (w.state == 'rec') { studioInputStreamGrabber(i, 'rec'); }
				return;
			}
			if (n == 'track_height') {
				var h = Math.max(64, Math.min(280, parseInt(w, 10) || 90));
				var row = $('#studio_track_row_' + i);
				if (row.length) { row.css('height', h + 'px'); }
				mixer[i]['track_height'] = h;
				return;
			}
			if (n == 'pan') { w = (w - -1) / (1 - -1) * (100 - 0) + 0; }
			$('[channel="' + i + '"][control="' + n + '"]').val(w);
		});

		// rebuild this channel's two insert racks
		var c = studioChannelEngine(i);
		if (c) {
			// the selected chain is a view, not audio; an older song starts on In
			studioSetChannelChain(i, (v['fx_chain'] == 'out') ? 'out' : 'in');
			c.inserts.slice().forEach(function(ins) { studioSetInsert(i, ins.name, false); });
			c.outInserts.slice().forEach(function(ins) { studioSetInsert(i, ins.name, false, 'out'); });
			(v['fx'] || []).forEach(function(entry) {
				// An old song stored just the pedal names; a new one stores a record
				// per insert (name, footswitch, controls), in chain order.
				var name = (typeof entry === 'string') ? entry : (entry && entry.name);
				if (!name) { return; }
				// Jtune is a real listen-only insert now, so it restores with the
				// chain; the pass-through is what keeps it silent.
				studioSetInsert(i, name, true);
				if (entry && typeof entry === 'object') {
					rack_restore.push({ ch: i, name: name, record: entry });
				}
			});
			// An older song has no fx_out: the clear above is the whole output
			// chain, so its takes still play exactly as they were recorded.
			(v['fx_out'] || []).forEach(function(entry) {
				var name = (typeof entry === 'string') ? entry : (entry && entry.name);
				if (!name || name === 'Jtune') { return; }
				studioSetInsert(i, name, true, 'out');
				if (entry && typeof entry === 'object') {
					rack_restore.push({ ch: i, name: name, record: entry, chain: 'out' });
				}
			});
		}
		studioApplyChannel(i);
	});

	// The saved Monitor choice is restored after every row, so the buttons and
	// the one active stream agree before the rest of the song is rebuilt.
	if (typeof studioMonitorButtonRender === 'function') { studioMonitorButtonRender(); }
	if (typeof studioApplyMonitor === 'function') { studioApplyMonitor(true); }

	// Every row ends up with a colour: the song's where it carried one, a fresh
	// theme-family one for a row the server rendered without one. The canvases
	// then paint with it on this first frame.
	studioApplyTrackColours();

	// The restored jacks now name their destinations; rebuild every output so a
	// channel send feeds the channel it was saved against, not the master.
	$.each(studioAudio.channels, function (ch2) {
		if (typeof studioRebuildOutputs === 'function') { studioRebuildOutputs(ch2); }
	});

	studioApplyPedals();
	// A rack's own values win over the shelf's global pedals, so they are pushed
	// in last: the shelf is a macro, the stored rack is the song. Each record is
	// applied to the chain it was saved from.
	rack_restore.forEach(function(item) {
		var ins = studioRackFind(item.ch, item.name, item.chain || 'in');
		if (!ins) { return; }
		$.each(item.record.controls || {}, function(control, value) { ins.set(control, value); });
		if (ins.setBypass) { ins.setBypass(item.record.on === false); }
	});
	// A restored footswitch is a graph fact: the audio chain carries only the
	// enabled inserts, so rewire both chains now that every bypass is known.
	$.each(studioAudio.channels, function (ch2) {
		if (typeof studioRebuildInserts === 'function') { studioRebuildInserts(ch2); }
		if (typeof studioRebuildOutputs === 'function') { studioRebuildOutputs(ch2); }
	});
	studioRackRenderAll();
	var master_records = mixer['admin'] && mixer['admin']['master'];
	if (master_records && master_records.length) {
		studioMasterRestore(master_records);
	}
	else {
		// An older song has no master rack: start from every effect off rather
		// than inherit the previous song's switches.
		studioMasterRestore(studioMasterNames().map(function(name) {
			return { name: name, on: false };
		}));
	}

	// The drum chart, keys, loop, mutes and MIDI input are the song's too; a
	// cleared chart is valid and restores as silence.
	studioDrumsRestore(mixer['admin'] && mixer['admin']['drums']);

	var met = $('#studio_metronome');
	if (mixer['time'] && mixer['time']['metronome'] == 'yes') {
		met.attr('armed', 'yes');
		met.css({ 'background-color': 'var(--runway-bad, #b3453f)' });
	} else {
		met.attr('armed', 'no');
		met.css({ 'background-color': 'var(--panel-2)' });
	}
	if (mixer['time']) {
		if (mixer['time']['bpm']) { $('#studio_bpm').val(mixer['time']['bpm']); }
		if (mixer['time']['sig']) { $('#studio_signature').val(mixer['time']['sig']); }
		if (mixer['time']['loop']) { mixer['time']['loop'] = mixer['time']['loop']; }
	}

	mixer['settings'] = mixer['settings'] || {};
	mixer['settings']['channel_count'] = $('#studio_viewer').attr('channel_count');
	studioUpdateKnobHints();
	// the restored mute/solo state owns the playback bus and the dimming; the
	// strip paints its own buttons from mixer on this event
	$(document).trigger('studio:mute-solo');
	studioApplyMuteSolo();

	// A saved app input has no arm click on load; build its live path now, then
	// re-apply the Monitor split because attaching forces the app live.
	if (typeof studioAttachSavedAppInputs === 'function') { studioAttachSavedAppInputs(); }
	if (typeof studioApplyMonitor === 'function') { studioApplyMonitor(false); }
	return song;
}

