/* [[js-split]]
   studio.js is part 1. The rest live in studio/ in name order:
     01_transport.js  - input detach, take node/mime, transport helpers, waveform, audio-clock scheduler
     02_canvas.js  - take sync, video preview, waveform canvas drawing
     03_editing.js  - record offset, loop regions, take editing, pointer/selection handlers
     04_knobs.js  - studioInit, knobs and wheel, song save/retrieve
     05_inputs.js  - jog wheel, record/arm/jack/cord, channel select, input grabber, take start/stop
     06_controls.js  - play/stop/time, loop punch-out, transport tick, save/load/import, name/mark/config
     07_layout.js  - per-track panels, hide toggles, floating panels, add/delete tracks, automation
     08_effects.js  - the insert builders (the browser side of docs/studio-effects.md)
     09_pedals.js  - the per-track rack: palette, order, footswitch, remove
     10_master.js  - the mastering chain after the mix, its UI and its song state
     11_drums.js  - the drum machine: voices, one-bar chart, keys, MIDI, routing
     12_export.js - render each track through its output chain and attach it to the song
     13_strip.js  - the channel strip's mute and solo buttons
     14_audio_file.js - encode an AudioBuffer as a 16-bit WAV blob
     12_tuner.js  - the chromatic tuner on Jtune: listening, pitch, note, arrows
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var mixer = {};
var studio;

// Button artwork follows the selected icon set; the studio window publishes a
// server-resolved map (see studio/studio.html.ep), falling back to the PNG.
function jawnosStudioButtonIcon(state, colour) {
	var map = (window.jawnos_studio_button_icons || {})[state];
	if (map && map[colour]) { return map[colour]; }
	return '/images/studio/button_' + state + '_' + colour + '.png';
}

// ===========================================================================
// Audio engine
// ===========================================================================
// A single AudioContext drives the whole studio. Each channel owns one
// persistent graph that survives record/play cycles:
//
//   live input -> trim -> bass -> mid -> treble -> [inserts] -> recGain -> recDest
//                                                              -> recAnalyser
//   take -> playGain -> playBus -> playPan -> master -> speakers
//
// Audio takes are decoded to AudioBuffers and scheduled on the AudioContext's
// own clock (see the scheduler further down), so they sit exactly under the
// metronome. Only video and undecodable takes still ride a hidden media element.
//
// Takes are captured *after* the inserts, so pedals are printed into the
// recording (a guitar tracks through its pedals). Playback runs through the
// channel volume/pan only, so nothing is processed twice. The live input is
// never routed to the speakers, which keeps monitoring from feeding back.
//
// A take recorded on a channel armed to L is a looping sample: while the
// transport runs it wraps back to its in-point every time its own length
// elapses, until it is snipped on the waveform canvas. Recording locks to the
// Start on setting (bar, beat, or free wheeling), runs for the configured
// number of bars, then punches out and repeats on the spot, and it can be
// preceded by a count-in of the configured number of beats (the signature's
// beats per bar by default), which clicks even when the metronome is off.
//
// The live input can be monitored through the pedals into the speakers when the
// song asks for it (headphones only — an open mic plus speakers will howl).

var studioAudio = { ctx: null, master: null, masterAnalyser: null, masterChain: null, channels: {}, sources: [], lookahead: 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
var studioSelectedChannel = 1;

function studioContext() {
	if (!studioAudio.ctx) {
		var Ctor = window.AudioContext || window.webkitAudioContext;
		if (!Ctor) { return null; }
		var hint = studioLatencyHint();
		var options = { latencyHint: hint };
		var rate = studioSampleRate();
		if (rate > 0) { options.sampleRate = rate; }
		var ctx;
		try { ctx = new Ctor(options); }
		catch (e) { ctx = new Ctor({ latencyHint: hint }); }
		studioAudio.ctx = ctx;
		studioAudio.master = ctx.createGain();
		studioAudio.masterAnalyser = ctx.createAnalyser();
		studioAudio.masterAnalyser.fftSize = 2048;
		// The mastering rack sits on the mixer's bus: after every channel sum,
		// before the analyser that feeds the destination. It is a fixed chain
		// with its own footswitches, so a bypass never rewires the window.
		var rack = null;
		try { rack = studioMasterChain(ctx); } catch (e) { rack = null; }
		studioAudio.masterChain = rack;
		if (rack) {
			studioAudio.master.connect(rack.input);
			rack.output.connect(studioAudio.masterAnalyser);
		}
		else {
			studioAudio.master.connect(studioAudio.masterAnalyser);
		}
		studioAudio.masterAnalyser.connect(ctx.destination);
		if (!studioAudio.sources) { studioAudio.sources = []; }
	}
	if (studioAudio.ctx.state == 'suspended') { studioAudio.ctx.resume(); }
	return studioAudio.ctx;
}

function studioKnobNumber(value, fallback) {
	var n = numeral(value).value();
	return (n === null || n === undefined || isNaN(n)) ? fallback : n;
}

// The channel fader is nominally 0..100, but the template ships value="1", so
// treat values at or below 1 as an already-normalised fraction.
function studioVolumeFraction(value) {
	var v = studioKnobNumber(value, 1);
	if (v > 1) { v = v / 100; }
	return Math.max(0, Math.min(1, v));
}

// Capture/encode preferences (video size, bit rates, sample rate, channels)
// live in the app settings rather than the song, so they apply to whatever is
// recorded next.
function studioSettingNumber(setting, fallback) {
	var raw = mixer['settings'] ? mixer['settings'][setting] : undefined;
	if (raw === undefined || raw === null || String(raw).length == 0) { return fallback; }
	var n = studioKnobNumber(raw, fallback);
	return (n === null || n === undefined || isNaN(n)) ? fallback : n;
}

// 0 means "whatever the device does".
function studioSampleRate() {
	var rate = studioSettingNumber('sample_rate', 0);
	return rate >= 8000 ? Math.round(rate) : 0;
}

// How small an audio buffer to ask the browser for. The named hints map straight
// through; a bare number is a target in seconds, and the browser may quietly give
// a larger one - too small a buffer crackles. Fixed when the AudioContext is
// built, so changing it rebuilds the studio window.
function studioLatencyHint() {
	var raw = mixer['settings'] ? mixer['settings']['latency_hint'] : undefined;
	if (raw === undefined || raw === null || String(raw).length == 0) { return 'interactive'; }
	var s = String(raw);
	if (s == 'interactive' || s == 'balanced' || s == 'playback') { return s; }
	var n = numeral(s).value();
	return (n > 0) ? n : 'interactive';
}

// The buffer hint and the sample rate are fixed when the AudioContext is built,
// so a change to either tears the window down and brings it back up.
function studioRebuildWindow(setting, value) {
	studioFlushSources();
	if (studioAudio.ctx) { try { studioAudio.ctx.close(); } catch (e) {} }
	studioAudio = { ctx: null, master: null, masterAnalyser: null, masterChain: null, channels: {}, sources: [], lookahead: 0.12, chunk: 1.0, playSeg: null, schedSeg: null, clickSeg: null };
	setTimeout(function () {
		studioInit({ settings: [{ setting: setting, value: value }] });
	}, 500);
}

// ---- effect factories ------------------------------------------------------
// The builders live in studio/08_effects.js; this is the dispatcher the rest of
// the window calls. Every contract name resolves to a builder there, and an
// unknown name is a plain pass-through so a stale song still loads.
function studioInsert(ctx, name) {
	var build = studioEffectBuilder(name);
	if (build) { return build(ctx, name); }
	var input = ctx.createGain();
	var output = ctx.createGain();
	input.connect(output);
	return {
		name: name, input: input, output: output, bypassed: false, values: {},
		set: function (control, value) { this.values[control] = value; },
		setBypass: function (on) { this.bypassed = !!on; }
	};
}

function studioChannelEngine(ch) {
	var ctx = studioContext();
	if (!ctx) { return null; }
	if (studioAudio.channels[ch]) { return studioAudio.channels[ch]; }
	var c = {
		trim: ctx.createGain(),
		bass: ctx.createBiquadFilter(),
		mid: ctx.createBiquadFilter(),
		treble: ctx.createBiquadFilter(),
		recGain: ctx.createGain(),
		recAnalyser: ctx.createAnalyser(),
		meterAnalyser: ctx.createAnalyser(),
		recDest: ctx.createMediaStreamDestination(),
		playBus: ctx.createGain(),
		outIn: ctx.createGain(),
		playPan: ctx.createStereoPanner(),
		monGain: ctx.createGain(),
		inserts: [],
		insertByName: {},
		outInserts: [],
		outInsertByName: {},
		rackChain: ((mixer[ch] || {}).fx_chain === 'out') ? 'out' : 'in',
		source: null
	};
	c.bass.type = 'lowshelf'; c.bass.frequency.value = 220;
	c.mid.type = 'peaking'; c.mid.frequency.value = 1000; c.mid.Q.value = 1;
	c.treble.type = 'highshelf'; c.treble.frequency.value = 3500;
	c.recAnalyser.fftSize = 2048;
	c.recData = new Float32Array(c.recAnalyser.fftSize);
	c.meterAnalyser.fftSize = 1024;
	c.meterAnalyser.smoothingTimeConstant = 0.6;
	c.meterData = new Float32Array(c.meterAnalyser.fftSize);
	// the recorded stream follows the configured channel count
	try { c.recDest.channelCount = studioSettingNumber('audio_channels', 2) || 2; } catch (e) {}
	c.trim.connect(c.bass).connect(c.mid).connect(c.treble);
	c.recGain.connect(c.recAnalyser);
	c.recGain.connect(c.recDest);
	c.recGain.connect(c.meterAnalyser);
	// takes play through the channel fader, then the output chain (the pedals
	// after the take), then the pan into the master bus. A new channel's chain
	// is empty, so the rebuild below is the wire outIn -> playPan and a take
	// plays exactly as it was recorded.
	c.playBus.connect(c.outIn);
	studioAudio.channels[ch] = c;
	studioRebuildOutputs(ch);
	c.playPan.connect(studioAudio.master);
	c.playPan.connect(c.meterAnalyser);
	// live monitoring taps the same post-pedal signal the recorder gets, so you
	// hear exactly what is being captured; it is muted until the song asks
	c.monGain.gain.value = 0;
	// One input on a stereo bus is played in both ears. Without this an input
	// captured as two channels with only one carrying signal (the UM2's mono
	// instrument input, a webcam's mono microphone) reaches one ear alone.
	c.monGain.channelCount = 2;
	c.monGain.channelCountMode = 'explicit';
	c.monGain.channelInterpretation = 'speakers';
	c.recGain.connect(c.monGain);
	c.monGain.connect(studioAudio.master);
	return c;
}

function studioRebuildInserts(ch) {
	var c = studioAudio.channels[ch];
	if (!c) { return; }
	try { c.trim.disconnect(); } catch (e) {}
	try { c.treble.disconnect(); } catch (e) {}
	// Every insert's output is one edge in the old order. Drop all of them before
	// wiring the new order, or a reorder leaves the old edges in place as well.
	c.inserts.forEach(function (insert) {
		if (insert.output) { try { insert.output.disconnect(); } catch (e) {} }
	});
	c.trim.connect(c.bass);
	var node = c.treble;
	c.inserts.forEach(function (insert) {
		node.connect(insert.input);
		node = insert.output;
	});
	node.connect(c.recGain);
}

// The output chain sits after the take, between the playback bus and the pan:
// playBus -> outIn -> [inserts in order] -> playPan -> master. An empty chain
// is a wire, so a clean take plays exactly as recorded.
function studioRebuildOutputs(ch) {
	var c = studioAudio.channels[ch];
	if (!c || !c.outIn) { return; }
	try { c.outIn.disconnect(); } catch (e) {}
	c.outInserts.forEach(function (insert) {
		if (insert.output) { try { insert.output.disconnect(); } catch (e) {} }
	});
	var node = c.outIn;
	c.outInserts.forEach(function (insert) {
		node.connect(insert.input);
		node = insert.output;
	});
	node.connect(c.playPan);
}

// The rack shows one chain at a time. Which one is the channel's own view and
// is saved with the song, so a reload shows the rack that was left open.
function studioChannelChain(ch) {
	var c = studioAudio.channels[ch];
	return (c && c.rackChain === 'out') ? 'out' : 'in';
}

function studioSetChannelChain(ch, chain) {
	var c = studioChannelEngine(ch);
	if (!c) { return; }
	c.rackChain = (chain === 'out') ? 'out' : 'in';
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].fx_chain = c.rackChain;
}

function studioApplyPedals() {
	// The shelf's pedals are global: a knob on the artwork pushes its value to
	// every insert of that kind, however it was named when it was added (the
	// shelf says reverb2, the palette says reverb). Both of a channel's chains
	// hear it: In prints into the take, Out is heard on playback.
	$('.knob_control, .studio_pedal_model').not('#studio_pedalboard_tiles *').each(function (i, v) {
		var channel = $(v).attr('channel');
		var control = $(v).attr('control');
		if (!channel || !control || /^[0-9]+$/.test(channel)) { return; }
		var kind = studioEffectKind(channel);
		$.each(studioAudio.channels, function (ch, c) {
			$.each([c.insertByName, c.outInsertByName], function (j, map) {
				$.each(map, function (name, ins) {
					if (studioEffectKind(name) === kind) { ins.set(control, $(v).val()); }
				});
			});
		});
	});
}

function studioSetInsert(ch, name, on, chain) {
	var c = studioChannelEngine(ch);
	if (!c) { return; }
	// `chain` is 'in' (before the take, so the recording is wet) unless the
	// caller asks for 'out' (after the take, browser playback only).
	var out = (chain === 'out');
	var list = out ? c.outInserts : c.inserts;
	var byName = out ? c.outInsertByName : c.insertByName;
	var at = -1;
	list.forEach(function (ins, i) { if (ins.name == name) { at = i; } });
	if (on && at == -1) {
		var ins = studioInsert(studioContext(), name);
		list.push(ins);
		byName[name] = ins;
	}
	else if (!on && at != -1) {
		var gone = list.splice(at, 1)[0];
		// A removed insert may still feed the next node or the bus; drop every
		// edge out of it before it leaves the graph.
		if (gone && gone.output) { try { gone.output.disconnect(); } catch (e) {} }
		if (gone && gone.destroy) { try { gone.destroy(); } catch (e) {} }
		delete byName[name];
	}
	studioApplyPedals();
	if (out) { studioRebuildOutputs(ch); } else { studioRebuildInserts(ch); }
	studioUpdateFxBadges();
	// keep every rack view and every pedal lamp in step with the engine
	if (typeof studioRackRender === 'function') { studioRackRender(ch); }
	if (typeof studioUpdatePedalLamps === 'function') { studioUpdatePedalLamps(); }
}

function studioApplyChannel(ch) {
	var c = studioChannelEngine(ch);
	if (!c) { return; }
	var raw = function (control, fallback) {
		return studioKnobNumber($('.knob_control[channel="' + ch + '"][control="' + control + '"]').val(), fallback);
	};
	c.trim.gain.value = raw('gain', 50) / 50;
	c.bass.gain.value = (raw('bass', 50) - 50) / 50 * 12;
	c.mid.gain.value = (raw('mid', 50) - 50) / 50 * 12;
	c.treble.gain.value = (raw('treble', 50) - 50) / 50 * 12;
}

// Feed a live MediaStream (mic / camera / screen) into a channel and return its
// processed recording stream. A capture from a real input device is narrowed to
// the interface channel the picker names (Input 1 or Input 2) and played as one
// signal in both ears; a screen share keeps its own stereo pair.
function studioAttachInput(ch, stream) {
	var ctx = studioContext();
	var c = studioChannelEngine(ch);
	if (!ctx || !c) { return null; }
	if (c.source) { try { c.source.disconnect(); } catch (e) {} c.source = null; }
	if (c.inputSource) { try { c.inputSource.disconnect(); } catch (e) {} c.inputSource = null; }
	if (c.inputSplitter) { try { c.inputSplitter.disconnect(); } catch (e) {} c.inputSplitter = null; }
	var source = ctx.createMediaStreamSource(stream);
	c.inputSource = source;
	var plug = (typeof studioChannelInput === 'function') ? studioChannelInput(ch) : null;
	var track = stream.getAudioTracks()[0];
	var channels = 0;
	try { if (track && track.getSettings) { channels = Number(track.getSettings().channelCount) || 0; } } catch (e) {}
	// A camera or an interface is a single source with one signal per input; a
	// screen share is a stereo mix and is left alone.
	if (plug && plug['type'] === 'usermedia' && channels > 1) {
		var pick = (typeof studioInputListenChannel === 'function') ? studioInputListenChannel(plug) : 0;
		var splitter = ctx.createChannelSplitter(2);
		var mono = ctx.createGain();
		mono.channelCount = 1;
		mono.channelCountMode = 'explicit';
		source.connect(splitter);
		splitter.connect(mono, Math.min(1, Math.max(0, pick)), 0);
		c.inputSplitter = splitter;
		c.source = mono;
	}
	else {
		c.source = source;
	}
	c.source.connect(c.trim);
	studioApplyChannel(ch);
	studioRebuildInserts(ch);
	// a device input supersedes the drums on this channel, so their own
	// recorder tap may follow the selection again
	if (typeof studioDrumsRouteSelection === 'function') { studioDrumsRouteSelection(); }
	return c.recDest.stream;
}

// Feed the JawnOS synth engine into a channel the way a live input is fed, so it
// records through the channel's tone stack and pedals and can be monitored. The
// engine rides the studio's own context and stays audible on its own, so it can
// be played before anything is armed; the tap is a per-channel gain, so stopping
// it never silences the synth's own output.
function studioAttachSynth(ch) {
	var ctx = studioContext();
	var c = studioChannelEngine(ch);
	if (!ctx || !c || !window.jawnosSynth || typeof jawnosSynth.outputNode !== 'function') { return null; }
	if (jawnosSynth.context() !== ctx) { jawnosSynth.attach(ctx, ctx.destination); }
	var node = jawnosSynth.outputNode();
	if (!node) { return null; }
	if (c.source) { try { c.source.disconnect(); } catch (e) {} c.source = null; }
	if (c.synthTap) {
		try { c.synthTap.node.disconnect(c.synthTap.gain); } catch (e) {}
		try { c.synthTap.gain.disconnect(); } catch (e) {}
	}
	var tap = ctx.createGain();
	tap.gain.value = 1;
	node.connect(tap);
	tap.connect(c.trim);
	c.synthTap = { node: node, gain: tap };
	studioApplyChannel(ch);
	studioRebuildInserts(ch);
	// a drums channel is no longer the one being taken
	if (typeof studioDrumsRouteSelection === 'function') { studioDrumsRouteSelection(); }
	return c.recDest.stream;
}

// Feed the drum machine into a channel the way a live input is fed. The kit's
// bus keeps its direct feed to the master, so it is audible on its own before
// it is patched anywhere; this adds the wet path through the channel's tone
// stack, input pedals and fader, so a browser take prints the processed drums
// and Monitor hears that same path. The tap is a per-channel gain, so detaching
// never silences the kit's own output.
function studioAttachDrums(ch) {
	var ctx = studioContext();
	var c = studioChannelEngine(ch);
	if (!ctx || !c || typeof studioDrums === 'undefined' || typeof studioDrumsBus !== 'function') { return null; }
	studioDrumsBus();
	if (!studioDrums.out) { return null; }
	if (c.source) { try { c.source.disconnect(); } catch (e) {} c.source = null; }
	if (c.synthTap) {
		try { c.synthTap.node.disconnect(c.synthTap.gain); } catch (e) {}
		try { c.synthTap.gain.disconnect(); } catch (e) {}
		c.synthTap = null;
	}
	if (c.drumTap) {
		try { c.drumTap.node.disconnect(c.drumTap.gain); } catch (e) {}
		try { c.drumTap.gain.disconnect(); } catch (e) {}
		c.drumTap = null;
	}
	var tap = ctx.createGain();
	tap.gain.value = 1;
	studioDrums.out.connect(tap);
	tap.connect(c.trim);
	c.drumTap = { node: studioDrums.out, gain: tap };
	studioApplyChannel(ch);
	studioRebuildInserts(ch);
	// The drums' own recorder tap follows the selected channel; its owner skips
	// that tap while this channel's input is the drums, so the take is not
	// printed twice.
	if (typeof studioDrumsRouteSelection === 'function') { studioDrumsRouteSelection(); }
	return c.recDest.stream;
}

// Push a capture-quality change (channel count) onto the live channels.
function studioApplyCapture() {
	var chans = studioSettingNumber('audio_channels', 2) || 2;
	$.each(studioAudio.channels, function (ch, c) {
		if (!c.recDest) { return; }
		try { c.recDest.channelCount = chans; } catch (e) {}
	});
}

// Live monitoring: the processed input only reaches the speakers when the song
// asks for it, because an open mic plus speakers howls. `from_user` is the
// person pressing Monitor (or changing its setting), not the page loading a
// song: only then may the engine's Listen be started or stopped.
//
// Monitor hears only the end of the chain the track's input feeds. No input is
// silence; an app already on this page is the browser's post-FX tap; a real
// audio device is the engine's own Listen when a native engine owns the
// interface, because the engine can open it, and the browser tap otherwise.
// One track is monitored at a time.
//
// The app channel Monitor attached while its track was unarmed, so turning
// Monitor off or moving it can detach that graph again.
var studioMonitorAppChannel = null;
// The device Monitor opened in the browser when the engine was not the monitor.
var studioMonitorDeviceChannel = null;
// A device Monitor starts the engine's Listen. If that cannot start (the engine
// is not running on this machine), the browser capture is the monitor instead,
// so a guitar is never silent just because the engine is absent.
var studioMonitorEngineFailed = false;
function studioMonitorEngineFallback() {
	if (studioMonitorEngineFailed) { return; }
	studioMonitorEngineFailed = true;
	if (typeof studioListenShowError === 'function' && typeof studioListenText === 'function') {
		studioListenShowError(studioListenText('the engine is not running; monitoring through the browser input'));
	}
	studioApplyMonitor(false, true);
}
function studioApplyMonitor(from_user, force_tap_device) {
	var active = (typeof studioMonitoredChannel === 'function') ? studioMonitoredChannel() : null;
	var backend = (typeof studioAudioBackend === 'function') ? studioAudioBackend() : 'browser';
	var nativeish = backend !== 'browser';
	var input = (active !== null && typeof studioChannelInput === 'function')
		? studioChannelInput(active) : null;
	var app = !!(input && typeof studioInputIsApp === 'function' && studioInputIsApp(input));
	var device = !!(input && typeof studioInputIsDevice === 'function' && studioInputIsDevice(input));
	var listen_channel = (device && typeof studioInputListenChannel === 'function')
		? studioInputListenChannel(input) : 0;
	// The engine's Listen names one of its two interface inputs; a device past
	// them has no Listen, so its browser tap stays the only path. A device is
	// only routed there while the engine says it is available and its last
	// attempt did not fail; otherwise the browser tap is the monitor.
	var engine = !!(device && nativeish && listen_channel <= 1 && !studioMonitorEngineFailed
		&& (typeof studioEngineAvailable === 'undefined' || studioEngineAvailable !== false));
	// An unarmed app track has no graph yet. Monitor builds one for the track it
	// hears and removes it when it lets go; an armed track's input belongs to
	// the arm button. Only an app is ever attached here: a device is the engine's
	// Listen and never opens the browser capture from Monitor.
	var previous_app = studioMonitorAppChannel;
	studioMonitorAppChannel = (app && active !== null
		&& typeof studioMonitorAttachApp === 'function'
		&& studioMonitorAttachApp(active)) ? String(active) : null;
	if (previous_app !== null && previous_app !== studioMonitorAppChannel
		&& typeof studioMonitorDetachApp === 'function') {
		studioMonitorDetachApp(previous_app);
	}
	// A device heard through the browser needs its capture open. Only a person's
	// press (or the engine's own refusal) opens one; a restored Monitor waits for
	// a gesture rather than asking for the microphone on page load.
	if (from_user || force_tap_device) {
		var previous_device = studioMonitorDeviceChannel;
		studioMonitorDeviceChannel = (!engine && device && active !== null
			&& typeof studioMonitorAttachDevice === 'function'
			&& studioMonitorAttachDevice(active)) ? String(active) : null;
		if (previous_device !== null && previous_device !== studioMonitorDeviceChannel
			&& typeof studioMonitorDetachDevice === 'function') {
			studioMonitorDetachDevice(previous_device);
		}
	}
	$.each(studioAudio.channels, function (ch, c) {
		if (!c.monGain) { return; }
		var on = active !== null && String(ch) === String(active);
		// The tap is the monitor for an app input and for every browser-only
		// path; a device the engine is actually listening to keeps it muted. A
		// restored Monitor (not from the person) stays on the tap until the
		// engine's Listen is running, so reloading a song is never silent. A
		// confirmed Listen keeps the tap off even if a later status poll fails:
		// the same input must never be played twice at two latencies.
		var engine_path = !!(device && nativeish && listen_channel <= 1);
		var listening = (engine && (studioListenActive || from_user))
			|| (engine_path && studioEngineListening);
		var tap = on && !!input && (app || !listening);
		c.monGain.gain.value = tap ? 1 : 0;
	});
	if (from_user && !studioEngineRecording && typeof studioListenStart === 'function') {
		if (engine) {
			// Stop the browser capture before the engine opens the input, so the
			// two never overlap even for one buffer.
			if (typeof studioInputReleaseForMonitor === 'function') { studioInputReleaseForMonitor(); }
			if (!studioListenActive) { studioListenStart(false, listen_channel, active, true); }
			else if (typeof studioListenChannel !== 'undefined' && studioListenChannel !== null
				&& Number(studioListenChannel) !== listen_channel) {
				// A different track (or a different input) is the monitor now: the
				// engine allows one Listen, so stop the old input and start the new.
				studioListenStop(listen_channel, active);
			}
		}
		else if (studioListenActive) { studioListenStop(); }
	}
	if (typeof studioMonitorButtonRender === 'function') { studioMonitorButtonRender(); }
}

// Persist an app-wide preference (capture quality) without rebuilding the
// window: the studio endpoint stores settings and hands back markup we ignore.
function studioSaveSettings(settings) {
	$.ajax({
		url: '/manager/studio',
		type: 'GET',
		data: { timestamp: Date.now(), data: JSON.stringify({ settings: settings }) }
	});
}

// What the browser reports about the round trip, so the record offset can be
// sanity-checked instead of guessed at.
function studioUpdateLatencyInfo() {
	var el = $('#studio_latency_info');
	if (!el.length) { return; }
	var ctx = studioAudio.ctx;
	if (!ctx) { el.text('engine idle'); return; }
	var ch = studioSelectedChannel;
	var m = mixer[ch] && mixer[ch].media;
	var base = ctx.baseLatency || 0;
	var out = ctx.outputLatency || 0;
	var parts = ['output ' + Math.round((base + out) * 1000) + ' ms (' + studioAudioLabel('base') + ' ' + Math.round(base * 1000) + ' · ' + studioAudioLabel('out') + ' ' + Math.round(out * 1000) + ')'];
	if (ctx.sampleRate) { parts.push(studioAudioLabel('rate') + ' ' + ctx.sampleRate + ' Hz'); }
	if (m && m.latency > 0) { parts.push('input ' + Math.round(m.latency * 1000) + ' ms'); }
	parts.push('offset ' + Math.round(studioRecordOffset(ch) * 1000) + ' ms');
	parts.push('hint ' + studioLatencyHint());
	el.text(parts.join(' · '));
}

// A translated word for the latency readout; translate.js may not be loaded in
// every shell, so fall back to the English text.
function studioAudioLabel(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// One plain object describing what the browser actually gave this studio, so
// the WebAudio path can be measured before a native engine replaces it. Read
// only: it never builds a context or changes the graph.
function studioAudioReport() {
	var ctx = studioAudio.ctx || null;
	var probe = studioAudio.probe || null;
	var delay = (studioAudio.recorderStartDelayMs === undefined) ? null : studioAudio.recorderStartDelayMs;
	return {
		userAgent: (typeof navigator !== 'undefined') ? navigator.userAgent : null,
		state: ctx ? ctx.state : null,
		sampleRate: ctx ? ctx.sampleRate : null,
		sampleRateAsked: studioSampleRate(),
		latencyHintAsked: studioLatencyHint(),
		baseLatency: (ctx && typeof ctx.baseLatency === 'number') ? ctx.baseLatency : null,
		outputLatency: (ctx && typeof ctx.outputLatency === 'number') ? ctx.outputLatency : null,
		roundTrip: probe ? {
			seconds: probe.seconds,
			ms: probe.ms,
			measured: 'output + air + input',
			echoes: probe.echoes,
			of: probe.of,
			at: probe.at
		} : null,
		recorderStartDelayMs: delay,
		capturedAt: new Date().toISOString()
	};
}
window.studioAudioReport = studioAudioReport;

// ---- round-trip latency meter ----------------------------------------------
// Plays a few clicks out of the speakers and times the echo on the microphone
// on the AudioContext clock. What it reports is the monitoring round trip -
// output + air + input - which is the number that decides whether playing along
// through the app feels late. Speakers, not headphones, and a quiet room.

var studioLatencyProbeSource = [
	"class StudioLatencyProbe extends AudioWorkletProcessor {",
	"  constructor() {",
	"    super();",
	"    this.phase = 'idle'; this.after = 0; this.threshold = 0.05; this.fired = false;",
	"    this.port.onmessage = (e) => {",
	"      const d = e.data || {};",
	"      if (d.phase === 'ambient' || d.phase === 'idle') { this.phase = d.phase; }",
	"      else if (d.phase === 'arm') { this.phase = 'arm'; this.after = d.after || 0; this.threshold = d.threshold || 0.05; this.fired = false; }",
	"    };",
	"  }",
	"  process(inputs) {",
	"    const ch = inputs[0] && inputs[0][0];",
	"    if (ch) {",
	"      let peak = 0, at = 0;",
	"      for (let i = 0; i < ch.length; i++) { const v = ch[i] < 0 ? -ch[i] : ch[i]; if (v > peak) { peak = v; at = i; } }",
	"      if (this.phase === 'ambient') { this.port.postMessage({ level: peak, ambient: 1 }); }",
	"      else if (this.phase === 'arm' && !this.fired && peak > this.threshold && currentTime >= this.after) {",
	"        this.fired = true;",
	"        this.port.postMessage({ hit: currentTime + at / sampleRate });",
	"      }",
	"    }",
	"    return true;",
	"  }",
	"}",
	"registerProcessor('studio-latency-probe', StudioLatencyProbe);"
].join('\n');

var studioLatencyProbeLoaded = false;

function studioSleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

// A short broadband click (a decaying noise burst) with a sharp onset.
function studioLatencyClick(ctx) {
	var rate = ctx.sampleRate;
	var len = Math.max(1, Math.floor(rate * 0.004));
	var buf = ctx.createBuffer(1, len, rate);
	var d = buf.getChannelData(0);
	for (var i = 0; i < len; i++) { d[i] = (Math.random() * 2 - 1) * Math.pow(1 - (i / len), 2); }
	return buf;
}

async function studioLatencyMeter() {
	var out = $('#studio_latency_result');
	var ctx = studioContext();
	if (!ctx) { return; }
	if (!ctx.audioWorklet) { out.text('this browser cannot measure'); return; }
	out.text('measuring\u2026');

	var stream;
	try {
		stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
	} catch (e) {
		out.text('microphone refused');
		return;
	}

	try {
		if (!studioLatencyProbeLoaded) {
			var url = URL.createObjectURL(new Blob([studioLatencyProbeSource], { type: 'application/javascript' }));
			await ctx.audioWorklet.addModule(url);
			URL.revokeObjectURL(url);
			studioLatencyProbeLoaded = true;
		}
	} catch (e) {
		out.text('probe failed to load');
		stream.getTracks().forEach(function (t) { t.stop(); });
		return;
	}

	var source = ctx.createMediaStreamSource(stream);
	var node = new AudioWorkletNode(ctx, 'studio-latency-probe');
	var sink = ctx.createGain();
	sink.gain.value = 0;
	source.connect(node);
	node.connect(sink).connect(ctx.destination);

	var ambient = 0;
	var hits = [];
	node.port.onmessage = function (e) {
		var d = e.data || {};
		if (d.ambient && d.level > ambient) { ambient = d.level; }
		if (d.hit !== undefined) { hits.push(d.hit); }
	};

	// learn the room noise, so the echo threshold sits above it
	node.port.postMessage({ phase: 'ambient' });
	await studioSleep(500);
	node.port.postMessage({ phase: 'idle' });

	var threshold = Math.max(0.05, ambient * 4);
	var click = studioLatencyClick(ctx);
	var delays = [];

	for (var n = 0; n < 3; n++) {
		var when = ctx.currentTime + 0.25;
		node.port.postMessage({ phase: 'arm', after: when, threshold: threshold });
		var src = ctx.createBufferSource();
		src.buffer = click;
		var gain = ctx.createGain();
		gain.gain.value = 0.6;
		src.connect(gain).connect(ctx.destination);
		src.start(when);
		var seen = hits.length;
		await studioSleep(500);
		if (hits.length > seen) { delays.push(hits[hits.length - 1] - when); }
	}

	source.disconnect();
	node.disconnect();
	sink.disconnect();
	stream.getTracks().forEach(function (t) { t.stop(); });

	if (!delays.length) {
		out.text('no echo heard \u2014 use speakers, not headphones, and stay quiet');
		return;
	}
	delays.sort(function (a, b) { return a - b; });
	var median = delays[Math.floor(delays.length / 2)];
	studioAudio.probe = {
		seconds: median,
		ms: Math.round(median * 1000),
		echoes: delays.length,
		of: 3,
		at: new Date().toISOString()
	};
	out.text(Math.round(median * 1000) + ' ms (' + delays.length + '/3 echoes)');
	console.log(JSON.stringify(studioAudioReport()));
}


// ---- the backend picker ----------------------------------------------------
// Four names, matching the select beside the meter and the route's own list.
// `javascript` stays in the page, so its number is the browser probe; the native
// names are measured by the engine behind POST /manager/studio/latency.
var studioLatencyBackends = [ 'javascript', 'alsa', 'pipewire', 'jack' ];

function studioLatencyMeasure() {
	var out = $('#studio_latency_result');
	if (!out.length) { return; }
	var backend = $('#studio_latency_backend').val() || 'javascript';
	if (studioLatencyBackends.indexOf(backend) < 0) { backend = 'javascript'; }
	if (backend === 'javascript') { return studioLatencyMeter(); }

	out.text(studioAudioLabel('measuring') + '\u2026');
	$.ajax({
		url: '/manager/studio/latency',
		type: 'POST',
		data: { backend: backend },
		dataType: 'json',
		success: function (data) {
			if (data && data.ok === true && typeof data.ms === 'number') {
				out.text(backend + ' ' + data.ms + ' ms' + (data.device ? ' (' + data.device + ')' : ''));
				return;
			}
			out.text(backend + ': ' + ((data && data.error) ? data.error : studioAudioLabel('the audio engine did not answer')));
		},
		error: function (xhr) {
			var data = xhr && xhr.responseJSON;
			out.text(backend + ': ' + ((data && data.error) ? data.error : studioAudioLabel('the audio engine did not answer')));
		}
	});
}

// ---- the engine take panel -------------------------------------------------
// The panel beside the latency readout speaks to the native engine through
// POST /manager/studio/take; the WebAudio graph above is not involved. A take
// is armed with a length and a track plan, read back with `status` every 750 ms
// while it records, and each strip's gain/pan slider sends one `param`.
// A number the engine did not report is shown as an em dash, never guessed.

var studioEngineTimer = 0;
// True while an engine take is recording. The rack knobs post to the engine
// only while it is the path that is playing; the browser graph stays the path
// when this is false and live listening is off.
var studioEngineRecording = false;
// The engine's configured capture width, from the last status reply. The Input
// pickers offer that many channels; two until the engine answers, which is the
// contract's fallback. Never invent a second key for it.
var studioEngineDeviceChannels = 2;
// The plan the running take armed, so a strip can say which input and width it
// recorded even when the engine's status does not echo them back.
var studioEnginePlanArmed = null;
// The live input the running take last reported. It can become true mid-take
// (the transport's Monitor button arms it with a gain param), so the button
// reads this rather than the saved setting while the take records.
var studioEngineMonitorArmed = false;
// The monitor bus gain the engine last reported, 0 to 4. `monitor_input` stays
// true when the gain is 0, so the pressed state needs both to say silence.
var studioEngineMonitorLevel = 1;

function studioEngineAnswer(data) {
	if (!data || typeof data !== 'object') {
		return { ok: false, error: studioAudioLabel('the audio engine did not answer') };
	}
	return data;
}

function studioEngineShowError(text) {
	var el = $('#studio_engine_error');
	if (el.length) { el.text(text || ''); }
}

function studioEngineFailed(xhr) {
	var data = xhr && xhr.responseJSON;
	studioEnginePollStop();
	studioEngineRecording = false;
	studioEngineShowError((data && data.error) ? data.error : studioAudioLabel('the audio engine did not answer'));
}

function studioEnginePollStart() {
	if (studioEngineTimer) { return; }
	studioEngineTimer = setInterval(studioEngineStatus, 750);
}

function studioEnginePollStop() {
	if (studioEngineTimer) { clearInterval(studioEngineTimer); studioEngineTimer = 0; }
}

// ---- one Input/Source pair per engine track ---------------------------------
// The Tracks count decides how many rows there are; each row picks the
// interface channel the engine track records and whether it reads one channel
// or the stereo pair. The rows keep a hidden #studio_engine_inputs carrying the
// comma list other code still reads, so the old path is never surprised.

function studioEngineInputRow(index, channels) {
	var row = $('<div class="studio_engine_input_row"></div>').attr('data-track', index).attr('channels', channels)
		.css({ margin: '2px 0' });
	var input = $('<select class="studio_engine_input_pick"></select>').attr('data-track', index)
		.attr('hint', studioAudioLabel('Which interface channel this engine track records'));
	for (var n = 1; n <= channels; n++) {
		input.append($('<option></option>').val(n - 1).text(studioAudioLabel('Input') + ' ' + n));
	}
	var source = $('<select class="studio_engine_source_pick"></select>').attr('data-track', index)
		.attr('hint', studioAudioLabel('Mono records one channel; stereo reads the pair at half each'));
	source.append($('<option value="1"></option>').text(studioAudioLabel('Mono')));
	source.append($('<option value="2"></option>').text(studioAudioLabel('Stereo')));
	row.append($('<span></span>').text(studioAudioLabel('Track') + ' ' + (index + 1)).css({ 'margin-right': '6px' }));
	row.append(input);
	row.append($('<label></label>').css({ 'margin-left': '8px' }).append($('<span></span>').text(studioAudioLabel('Source') + ' ')).append(source));
	return row;
}

// A stereo row claims input and input+1, so the last channel cannot be one.
// The engine refuses it too; the UI simply never offers it.
function studioEngineSourceSync(row) {
	if (!row || !row.length) { return; }
	var input = parseInt(row.find('.studio_engine_input_pick').val(), 10);
	var source = row.find('.studio_engine_source_pick');
	var pairs = source.find('option[value="2"]');
	var last = isNaN(input) ? false : (input >= studioEngineDeviceChannels - 1);
	pairs.prop('disabled', last);
	if (last && source.val() === '2') { source.val('1'); }
}

// Keep the hidden comma list in step with the pickers. The plan and any code
// that still reads #studio_engine_inputs see the same number for a track.
function studioEngineInputSync() {
	var inputs = [];
	$('#studio_engine_inputs_rows .studio_engine_input_row').each(function () {
		var value = parseInt($(this).find('.studio_engine_input_pick').val(), 10);
		inputs.push(isNaN(value) ? 0 : value);
	});
	$('#studio_engine_inputs').val(inputs.join(','));
}

function studioEngineInputRows() {
	var box = $('#studio_engine_inputs_rows');
	if (!box.length) { return; }
	var count = parseInt($('#studio_engine_tracks').val(), 10);
	if (!(count >= 1)) { count = 1; }
	if (count > 8) { count = 8; }
	box.children('.studio_engine_input_row').slice(count).remove();
	for (var i = 0; i < count; i++) {
		var row = box.children('.studio_engine_input_row').eq(i);
		// Rebuild only a row whose channel list changed: a count change or a
		// device_channels refresh keeps every choice the person already made.
		if (!row.length || parseInt(row.attr('channels'), 10) !== studioEngineDeviceChannels) {
			var previous = row.length ? {
				input: row.find('.studio_engine_input_pick').val(),
				source: row.find('.studio_engine_source_pick').val()
			} : null;
			var fresh = studioEngineInputRow(i, studioEngineDeviceChannels);
			if (row.length) { row.replaceWith(fresh); } else { box.append(fresh); }
			row = fresh;
			// A channel that no longer exists falls back to the first input.
			if (previous && previous.input !== null) { row.find('.studio_engine_input_pick').val(previous.input); }
			if (previous && previous.source !== null) { row.find('.studio_engine_source_pick').val(previous.source); }
			if (row.find('.studio_engine_input_pick').val() === null) { row.find('.studio_engine_input_pick').val(0); }
		}
		row.attr('data-track', i);
		studioEngineSourceSync(row);
	}
	studioEngineInputSync();
}

// The engine puts one track's fields at the top level and adds a `tracks` array
// only when a take has more than one, so a one-track take still gets a row.
function studioEngineStrips(data) {
	if (Array.isArray(data.tracks) && data.tracks.length) { return data.tracks; }
	if (typeof data.frames === 'number' || typeof data.dropped === 'number') { return [ data ]; }
	return [];
}

function studioEngineNumber(value) {
	return (typeof value === 'number' && isFinite(value)) ? String(value) : '\u2014';
}

function studioEngineRow(index) {
	var row = $('<div class="studio_engine_strip"></div>').attr('data-track', index).css({ margin: '2px 0' });
	var slider = { width: '80px', 'vertical-align': 'middle' };
	row.append($('<span class="studio_engine_state"></span>').css({ 'margin-right': '8px' }));
	row.append($('<span class="studio_engine_frames"></span>').css({ 'margin-right': '8px' }));
	row.append($('<span class="studio_engine_dropped"></span>').css({ 'margin-right': '8px' }));
	row.append($('<span class="studio_engine_track_input"></span>').css({ 'margin-right': '8px' }));
	row.append($('<label></label>').append($('<span></span>').text(studioAudioLabel('Gain') + ' ')).append(
		$('<input type="range" class="studio_engine_gain" min="0" max="4" step="0.01">')
			.attr('data-track', index).css(slider)
	));
	row.append($('<label></label>').css({ 'margin-left': '8px' }).append($('<span></span>').text(studioAudioLabel('Pan') + ' ')).append(
		$('<input type="range" class="studio_engine_pan" min="-1" max="1" step="0.01">')
			.attr('data-track', index).css(slider)
	));
	return row;
}

// A strip says which input and width it recorded, e.g. `in 1 · mono`. The
// take line reports each track's input, but its `channels` is the take's
// granted capture width, not one track's source; the width is ours to remember
// from the plan this page armed.
function studioEngineTrackSummary(track, index) {
	var armed = (studioEnginePlanArmed && studioEnginePlanArmed[index]) ? studioEnginePlanArmed[index] : null;
	var input = (typeof track.input === 'number') ? track.input : (armed ? armed.input : null);
	if (typeof input !== 'number' || isNaN(input)) { return ''; }
	var channels = (armed && armed.channels === 2) ? 2 : 1;
	return studioAudioLabel('in') + ' ' + (input + 1) + ' \u00b7 ' + (channels === 2 ? studioAudioLabel('stereo') : studioAudioLabel('mono'));
}

function studioEngineRender(data) {
	var box = $('#studio_engine_strips');
	if (!box.length) { return; }
	var strips = studioEngineStrips(data);
	var state = (typeof data.state === 'string') ? data.state : '';
	studioEngineMonitorArmed = (data.monitor_input === true);
	if (typeof data.monitor_gain === 'number' && isFinite(data.monitor_gain)) {
		studioEngineMonitorLevel = data.monitor_gain;
	}
	// A take can arm its live input after it started, so the transport's
	// pressed state follows the engine's report, not the saved setting.
	if (typeof studioMonitorButtonRender === 'function') { studioMonitorButtonRender(); }

	// The monitor ring's dropped frames are a measurement, not an error: a
	// small readout beside the strips, never a pedal lamp.
	var monitor = (typeof data.monitor_dropped === 'number' && isFinite(data.monitor_dropped)) ? data.monitor_dropped : null;
	$('#studio_engine_monitor').text(monitor === null ? '' : studioAudioLabel('monitor dropped') + ' ' + monitor);

	box.children('.studio_engine_strip').slice(strips.length).remove();

	for (var i = 0; i < strips.length; i++) {
		var track = strips[i] || {};
		var row = box.children('.studio_engine_strip').eq(i);
		if (!row.length) { row = studioEngineRow(i); box.append(row); }
		row.attr('data-track', i);
		row.find('.studio_engine_state').text(state || '\u2014');
		row.find('.studio_engine_frames').text(studioAudioLabel('frames') + ' ' + studioEngineNumber(track.frames));
		row.find('.studio_engine_dropped').text(studioAudioLabel('dropped') + ' ' + studioEngineNumber(track.dropped));
		row.find('.studio_engine_track_input').text(studioEngineTrackSummary(track, i));
		var gain = row.find('.studio_engine_gain').show();
		var pan = row.find('.studio_engine_pan').show();
		// A slider being dragged keeps its own position until it is let go.
		if (!gain.is(':focus') && typeof track.gain === 'number') { gain.val(track.gain); }
		if (!pan.is(':focus') && typeof track.pan === 'number') { pan.val(track.pan); }
	}

	if (!strips.length) {
		// Idle, or a take that has not reported a track yet: the state alone.
		var only = box.children('.studio_engine_strip').eq(0);
		if (!only.length) { only = studioEngineRow(0); box.append(only); }
		only.find('.studio_engine_state').text(state || '\u2014');
		only.find('.studio_engine_frames').text('');
		only.find('.studio_engine_dropped').text('');
		only.find('.studio_engine_track_input').text('');
		only.find('.studio_engine_gain, .studio_engine_pan').hide();
	}
}

function studioEngineStatus() {
	if (!$('#studio_engine_panel').length) { studioEnginePollStop(); return; }
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'status' },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			studioEngineInstalled = (data.installed === 1 || data.ok === true);
			// The socket may be down while the binary is staged; Monitor reads this
			// to choose the engine's Listen or the browser capture.
			studioEngineAvailable = (data.available === 1);
			if (typeof studioAudioBackendReset === 'function') { studioAudioBackendReset(); }
			if (data.ok !== true) {
				studioEnginePollStop();
				// The socket is gone, so a confirmed Listen cannot still be playing.
				studioEngineListening = false;
				// The frames we last drew belong to a take we can no longer read.
				jQuery('#studio_engine_strips').empty();
				jQuery('#studio_engine_monitor').text('');
				studioEngineShowError(data.error || studioAudioLabel('the audio engine did not answer'));
				// A dead socket means Monitor must return to the browser tap.
				if (typeof studioApplyMonitor === 'function') { studioApplyMonitor(); }
				return;
			}
			if (typeof data.device_channels === 'number' && data.device_channels >= 1) {
				studioEngineDeviceChannels = Math.floor(data.device_channels);
			}
			// The engine's capture width is known only once it answers; build
			// the Input pickers from it, keeping any choice already made.
			studioEngineInputRows();
			if (typeof data.error === 'string' && data.error.length) { studioEngineShowError(data.error); }
			studioEngineRecording = (data.state === 'recording');
			studioEngineRender(data);
			if (typeof studioApplyMonitor === 'function') { studioApplyMonitor(); }
			if (studioEngineRecording) { studioEnginePollStart(); }
			else { studioEnginePollStop(); }
		},
		error: studioEngineFailed
	});
}

// The engine take arms each track's own rack now, not one global chain:
// channel `ch` is engine track `ch-1`, its input comes from that track's Input
// picker (defaulting to the track's own number), its width from its Source
// picker, and only the enabled (unbypassed) inserts travel. The array is the
// engine's own per-track plan shape.
function studioEngineInputList() {
	var text = String($('#studio_engine_inputs').val() || '').replace(/^\s+|\s+$/g, '');
	if (!text.length) { return []; }
	return text.split(',').map(function (part) {
		part = part.replace(/^\s+|\s+$/g, '');
		// A valid channel goes as a number; a typo stays a string so the route
		// refuses it instead of silently recording the wrong input.
		return /^\+?\d+$/.test(part) ? parseInt(part, 10) : part;
	});
}

// 1 reads one channel; 2 reads the pair input/input+1, summed at half each
// before the strip. A row that cannot be stereo (the last input) is Mono here.
function studioEngineSourceList() {
	var out = [];
	$('#studio_engine_inputs_rows .studio_engine_input_row').each(function () {
		var value = parseInt($(this).find('.studio_engine_source_pick').val(), 10);
		out.push(value === 2 ? 2 : 1);
	});
	return out;
}

function studioEngineTrackPlan() {
	var count = parseInt($('#studio_engine_tracks').val(), 10);
	if (!(count >= 1)) { count = 1; }
	studioEngineInputSync();
	var inputs = studioEngineInputList();
	var sources = studioEngineSourceList();
	var plan = [];
	for (var index = 0; index < count; index++) {
		var channel = studioAudio.channels[index + 1];
		var inserts = [];
		if (channel && channel.inserts) {
			channel.inserts.forEach(function (ins) {
				if (!ins || ins.bypassed) { return; }
				// The Stereo Widener is a browser-only insert: the native engine has
				// no such effect, so sending its name refuses the whole take.
				if (studioEffectKind(ins.name) === 'stereowidener') { return; }
				inserts.push(studioEffectKind(ins.name));
			});
		}
		plan.push({
			input: (index < inputs.length ? inputs[index] : index),
			channels: (index < sources.length ? sources[index] : 1),
			inserts: inserts
		});
	}
	return plan;
}

// The enabled master effects the page has now; the engine builds them in the
// contract's order whatever order this list is in. A master switched on after
// the take started is not in that take's rack (see the engine's `master` note).
function studioEngineMasterList() {
	var records = (typeof studioMasterSave === 'function') ? studioMasterSave() : [];
	// Before the browser graph exists, the song's admin still holds the rack's
	// on/off state, so a take can arm what the song says was on.
	if (!records.length && mixer['admin'] && mixer['admin']['master']) {
		records = mixer['admin']['master'];
	}
	return records.filter(function (record) {
		// The Stereo Widener is a browser-only master effect: the native engine
		// cannot build it, so an enabled slot is left out rather than refusing
		// the take.
		return record && record['on']
			&& studioEffectKind(record['name']) !== 'stereowidener';
	}).map(function (record) {
		return record['name'];
	});
}

function studioEngineStart() {
	studioEngineShowError('');
	var plan = studioEngineTrackPlan();
	var master = studioEngineMasterList();
	// A monitored track (or the config panel's Monitor setting) also sends the
	// live input to the take's monitor.
	var monitor = (typeof studioMonitoredChannel === 'function' && studioMonitoredChannel() !== null)
		|| (mixer['time'] && mixer['time']['monitor'] == 'yes');
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: {
			action: 'start',
			seconds: $('#studio_engine_seconds').val(),
			// The scalar fields stay for an older route; a route that knows
			// tracks_json ignores them and uses each track's own chain.
			tracks: $('#studio_engine_tracks').val(),
			inputs: $('#studio_engine_inputs').val(),
			inserts: $('#studio_engine_inserts').val(),
			tracks_json: JSON.stringify(plan),
			master_json: JSON.stringify(master),
			monitor_input: monitor ? 'true' : 'false',
			monitor_gain: '1'
		},
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioEnginePollStop();
				studioEngineRecording = false;
				studioEngineShowError(data.error || studioAudioLabel('the audio engine did not answer'));
				return;
			}
			if (typeof data.device_channels === 'number' && data.device_channels >= 1) {
				studioEngineDeviceChannels = Math.floor(data.device_channels);
			}
			// Remember what this take armed so its strips can name the input
			// and width even when the status line does not echo them.
			studioEnginePlanArmed = plan;
			studioEngineRecording = true;
			studioEngineInputRows();
			studioEngineRender(data);
			studioEnginePollStart();
			studioEngineStatus();
		},
		error: studioEngineFailed
	});
}

function studioEngineStop() {
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'stop' },
		dataType: 'json',
		success: function (data) {
			studioEnginePollStop();
			studioEngineRecording = false;
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioEngineShowError(data.error || studioAudioLabel('the audio engine did not answer'));
				return;
			}
			if (typeof data.error === 'string' && data.error.length) { studioEngineShowError(data.error); }
			studioEngineRender(data);
		},
		error: studioEngineFailed
	});
}

function studioEngineParam(track, name, value) {
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'param', track: track, name: name, value: value },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true) {
				studioEngineShowError(data.error || studioAudioLabel('the audio engine did not answer'));
			}
		},
		error: studioEngineFailed
	});
}

// While an engine take records, the transport's Monitor button trims the live
// input on the monitor bus: 1 restores it, 0 silences it. It is a param
// addressed to `input`, not to a track, and the take keeps recording either
// way. With no engine take running the browser path uses the setting alone.
function studioEngineMonitorGain(value) {
	$.ajax({
		url: '/manager/studio/take',
		type: 'POST',
		data: { action: 'param', target: 'input', name: 'gain', value: value },
		dataType: 'json',
		success: function (data) {
			data = studioEngineAnswer(data);
			if (data.ok !== true && data.error) { studioEngineShowError(data.error); }
		},
		error: studioEngineFailed
	});
}
