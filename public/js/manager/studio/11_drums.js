// ===========================================================================
// The drum machine
// ===========================================================================
//
// Eight voices over a chart of `lengthSteps` sixteenth notes. Every voice is
// synthesised: there are no samples and no files. The one-shots are rendered
// once into AudioBuffers with an OfflineAudioContext, so a step allocates only
// a source and its gain — never a buffer, an oscillator or a filter.
//
// A kit is the same eight rows heard through a different set of shapes: the
// acoustic specs are the base and a kit only overrides the voices it changes.
// Changing the kit clears the rendered buffers and builds the new set.
//
// A step is a velocity, not a flag: 0 is off and 1..100 is how hard the beat is
// struck. A plain click places one at 70, Shift-click places a full 100, and a
// right-click on a placed beat opens its velocity menu. The step's opacity
// follows the velocity through the --drums-velocity custom property.
//
// The chart follows the Studio transport: it starts with play or record, takes
// its tempo from mixer.time.bpm, and loops the chart while Loop is on. A bar is
// sixteen steps and a beat is four, so the length controls grow or trim the
// chart by those amounts. Steps are placed on the AudioContext clock with a
// 25ms timer and a 100ms lookahead, so timer jitter never reaches the ear.
//
// `admin.drums` in the song is the whole state: the length, steps, keys, loop,
// the kit, the per-voice mutes and the chosen MIDI input. A cleared chart (a
// row of zeroes, however long) is a valid chart.
//
// Saved patterns live in the `drum_loops` app setting and are published as
// window.jawnos_studio_drum_loops. A saved loop can be put back on the panel,
// or rendered offline onto a loop track from the track's context menu.
//
// Routing: the drum bus feeds studioAudio.master, which is the input of the
// mastering rack, so the drums are heard through the master chain like every
// channel. A second tap feeds the selected channel's recDest, so the browser's
// MediaRecorder take captures the drums (see studioStartTake). The native engine
// take cannot record them yet: engine/src/ has no drum voice and the engine
// cannot read this bus, so only the browser path records drums. Say so in the
// panel and the help; never imply the engine take has them.

var studioDrums = {
	ctx: null,
	out: null,
	rec: null,
	routedDest: null,
	buffers: {},
	buildState: 'idle',
	buildGen: 0,
	builtKit: '',
	steps: {},
	keys: {},
	muted: {},
	loop: true,
	lengthSteps: 16,
	kit: 'acoustic',
	loaded: false,
	timer: 0,
	running: false,
	done: false,
	nextTime: 0,
	step: 0,
	anchor: 0,
	stepDur: 0.125,
	sources: [],
	learn: null,
	focus: false,
	midi: null,
	midiInput: ''
};

function studioDrumsText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function studioDrumsVoices() {
	var table = window.jawnos_studio_drums;
	return (table && table.length) ? table : [];
}

function studioDrumsVoiceNames() {
	return studioDrumsVoices().map(function (v) { return v.name; });
}

// The kit table is data too (perl/gb/05_abilities_and_studio.pl): `name` is the
// wire name saved in the song, `label` is the word people read.
function studioDrumsKits() {
	var table = window.jawnos_studio_drum_kits;
	return (table && table.length) ? table : [];
}

function studioDrumsKitNames() {
	return studioDrumsKits().map(function (k) { return k.name; });
}

// A saved song may name a kit this build does not have; it opens on Acoustic
// rather than on silence.
function studioDrumsKitName(name) {
	name = String(name || '');
	return (studioDrumsKitNames().indexOf(name) >= 0) ? name : 'acoustic';
}

function studioDrumsVoiceLabel(name) {
	var label = name;
	studioDrumsVoices().forEach(function (v) {
		if (v.name === name) { label = studioDrumsText(v.label || name); }
	});
	return label;
}

function studioDrumsDefaults() {
	studioDrums.steps = {};
	studioDrums.keys = {};
	studioDrums.muted = {};
	studioDrums.lengthSteps = 16;
	studioDrumsVoices().forEach(function (v) {
		studioDrums.steps[v.name] = studioDrumsZeroRow(studioDrums.lengthSteps);
		studioDrums.keys[v.name] = String(v.key || '');
		studioDrums.muted[v.name] = false;
	});
	studioDrums.loop = true;
	studioDrums.kit = 'acoustic';
	studioDrums.loaded = true;
}

// The chart length is a sixteenth-note count: one bar is sixteen and one beat
// is four. Four is the shortest loop and eight bars (128) the longest; a value
// that is not a multiple of four is rounded to one.
function studioDrumsNormaliseLength(value, fallback) {
	var n = parseInt(value, 10);
	if (!(n > 0)) { n = fallback || 16; }
	n = Math.round(n / 4) * 4;
	return Math.max(4, Math.min(128, n));
}

function studioDrumsZeroRow(length) {
	var row = [];
	for (var i = 0; i < length; i++) { row.push(0); }
	return row;
}

// Grow or trim every row to the chart length. Added steps are zeroes; a
// shortened chart drops the steps past the new end.
function studioDrumsSetLength(length) {
	length = studioDrumsNormaliseLength(length, studioDrums.lengthSteps);
	if (length === studioDrums.lengthSteps) { return false; }
	studioDrums.lengthSteps = length;
	studioDrumsVoices().forEach(function (v) {
		var row = (studioDrums.steps[v.name] || []).slice(0, length);
		while (row.length < length) { row.push(0); }
		studioDrums.steps[v.name] = row;
	});
	return true;
}

function studioDrumsChangeLength(delta) {
	if (!studioDrumsSetLength(studioDrums.lengthSteps + delta)) { return; }
	studioDrumsRender();
	studioSaver();
}

function studioDrumsSave() {
	var steps = {}, voices = {}, keys = {};
	studioDrumsVoices().forEach(function (v) {
		steps[v.name] = (studioDrums.steps[v.name] || []).slice(0, studioDrums.lengthSteps);
		voices[v.name] = { mute: studioDrums.muted[v.name] ? 1 : 0 };
		if (studioDrums.keys[v.name]) { keys[v.name] = studioDrums.keys[v.name]; }
	});
	return { steps: steps, keys: keys, loop: studioDrums.loop ? 1 : 0, voices: voices, midi: studioDrums.midiInput || '', kit: studioDrums.kit, length: studioDrums.lengthSteps };
}

function studioDrumsRestore(data) {
	studioDrumsDefaults();
	if (data && typeof data === 'object') {
		// A legacy song has no length; it opens as one bar of sixteen.
		studioDrums.lengthSteps = studioDrumsNormaliseLength(data.length);
		var saved = data.steps || {};
		studioDrumsVoices().forEach(function (v) {
			var row = saved[v.name] || [];
			var steps = studioDrumsZeroRow(studioDrums.lengthSteps);
			for (var i = 0; i < studioDrums.lengthSteps && i < row.length; i++) {
				var value = parseInt(row[i], 10);
				// Older songs saved a flag, not a velocity: 1 was a beat and 2 an
				// accent. Read them as 70 and 100; a newer 1..100 is already a
				// percent, and anything else is an empty step.
				if (!(value > 0)) { value = 0; }
				else if (value === 1) { value = 70; }
				else if (value === 2) { value = 100; }
				else { value = Math.min(100, value); }
				steps[i] = value;
			}
			studioDrums.steps[v.name] = steps;
		});
		var savedKeys = data.keys || {};
		Object.keys(savedKeys).forEach(function (voice) {
			var key = String(savedKeys[voice] || '').toLowerCase();
			if (key.length === 1 && studioDrums.steps[voice]) { studioDrums.keys[voice] = key; }
		});
		var muted = data.voices || {};
		Object.keys(muted).forEach(function (voice) {
			if (studioDrums.steps[voice] === undefined) { return; }
			var record = muted[voice];
			studioDrums.muted[voice] = !!(record && (record.mute == 1 || record.mute === true));
		});
		studioDrums.loop = !(data.loop == 0 || data.loop === false || data.loop === '0');
		studioDrums.kit = studioDrumsKitName(data.kit);
		if (data.midi) { studioDrums.midiInput = String(data.midi); }
	}
	studioDrums.loaded = true;
	// The buffers are the previous song's kit until they are built again.
	if (studioDrums.ctx && studioDrums.builtKit !== studioDrums.kit) {
		studioDrums.buffers = {};
		studioDrumsBuild(studioDrums.ctx);
	}
	if ($('#studio_drums').length) { studioDrumsRender(); }
}

// ---- the panel ------------------------------------------------------------

function studioDrumsRender() {
	$('#studio_drums_loop').prop('checked', !!studioDrums.loop);
	$('#studio_drums_kit').val(studioDrums.kit);
	$('#studio_drums .studio_drums_row').each(function () {
		var row = $(this);
		var voice = row.attr('data-voice');
		var key = studioDrums.keys[voice] || '';
		row.find('.studio_drums_key')
			.text(key ? key.toUpperCase() : '\u2014')
			.attr('title', key ? key.toUpperCase() : studioDrumsText('No key'));
		row.find('.studio_drums_lamp')
			.attr('aria-pressed', studioDrums.muted[voice] ? 'false' : 'true')
			.attr('title', studioDrums.muted[voice] ? studioDrumsText('Muted') : studioDrumsText('Audible'));
		studioDrumsRenderSteps(voice);
	});
	studioDrumsRenderLength();
	studioDrumsFocusState();
}

// The template carries the full 128-step head and rows once; the chart length
// decides which steps are shown. The head and every row share one inline grid,
// so the columns line up whatever the length is.
function studioDrumsRenderLength() {
	var length = studioDrums.lengthSteps;
	var bars = Math.floor(length / 16);
	var beats = (length % 16) / 4;
	var text = '';
	if (bars) { text = bars + ' ' + (bars === 1 ? 'bar' : 'bars'); }
	if (beats) { text += (text ? ' ' : '') + beats + ' ' + (beats === 1 ? 'beat' : 'beats'); }
	$('#studio_drums_length_readout').text(studioDrumsText(text));
	var columns = '72px 24px 14px repeat(' + length + ', minmax(12px, 1fr))';
	$('#studio_drums .studio_drums_head, #studio_drums .studio_drums_row').css('grid-template-columns', columns);
	$('#studio_drums .studio_drums_step, #studio_drums .studio_drums_count').each(function () {
		var step = parseInt($(this).attr('data-step'), 10) || 0;
		$(this).css('display', step < length ? '' : 'none');
	});
}

function studioDrumsRenderSteps(voice) {
	var row = studioDrums.steps[voice] || [];
	var label = studioDrumsVoiceLabel(voice);
	$('#studio_drums .studio_drums_step[data-voice="' + voice + '"]').each(function () {
		var step = parseInt($(this).attr('data-step'), 10) || 0;
		var value = parseInt(row[step], 10) || 0;
		if (value < 0) { value = 0; }
		var el = $(this);
		el.attr('aria-pressed', value ? 'true' : 'false')
			.attr('data-accent', value >= 100 ? 'yes' : 'no')
			.attr('data-velocity', value ? String(value) : '');
		// A placed beat fades with its velocity and says how hard it is; an empty
		// one carries neither, so the rule's own default applies.
		if (value) {
			el.attr('title', label + ' ' + value + '%');
			this.style.setProperty('--drums-velocity', String(value / 100));
		}
		else {
			el.removeAttr('title');
			this.style.removeProperty('--drums-velocity');
		}
	});
}

function studioDrumsFocusState() {
	var el = $('#studio_drums_key_state');
	if (!el.length) { return; }
	var text;
	if (studioDrums.learn) {
		text = studioDrumsText('Press a key for this drum, Escape cancels');
	}
	else if (studioDrumsTyping()) {
		text = studioDrumsText('Typing: drum keys are paused');
	}
	else if (typeof studioSelectedTake !== 'undefined' && studioSelectedTake) {
		// the take editor owns S (split) while a take is selected, so the drum
		// keys stand down rather than playing and splitting at once
		text = studioDrumsText('A take is selected: drum keys paused');
	}
	else if (!studioDrums.focus) {
		text = studioDrumsText('Click Studio to play the drum keys');
	}
	else {
		text = studioDrumsText('Keys live');
	}
	el.text(text);
}

// Typing in a name or a tempo field must never fire a drum. The key map is
// also paused until the Studio window is the one the person last touched.
function studioDrumsTyping() {
	var el = document.activeElement;
	if (!el) { return false; }
	var tag = String(el.tagName || '').toLowerCase();
	if (tag === 'input' || tag === 'textarea' || tag === 'select') { return true; }
	return !!el.isContentEditable;
}

// The drums are one of the interior panel windows now, so the panel stack and
// its taskbar own their state. This keeps the call sites in the drum code
// honest: a minimized or raised drums window refreshes the taskbar.
function studioDrumsGridState() {
	if (typeof studioPanelTaskbarRefresh === 'function') { studioPanelTaskbarRefresh(); }
}

// ---- the bus --------------------------------------------------------------

function studioDrumsBus() {
	var ctx = studioContext();
	if (!ctx) { return null; }
	if (studioDrums.ctx !== ctx) {
		studioDrums.ctx = ctx;
		studioDrums.out = null;
		studioDrums.direct = null;
		studioDrums.rec = null;
		studioDrums.routedDest = null;
		studioDrums.buffers = {};
	}
	if (!studioDrums.out) {
		// The kit bus is heard through the master chain when no channel is
		// monitoring it. direct is the clean comparison: a monitored app
		// channel mutes it so the channel input pedals are heard alone.
		studioDrums.out = ctx.createGain();
		studioDrums.out.gain.value = 0.9;
		studioDrums.direct = ctx.createGain();
		studioDrums.direct.gain.value = 1;
		studioDrums.out.connect(studioDrums.direct);
		studioDrums.direct.connect(studioAudio.master);
		studioDrums.rec = ctx.createGain();
		studioDrums.rec.gain.value = 0.9;
		studioDrumsBuild(ctx);
	}
	studioDrumsRouteSelection();
	studioDrumsPatchDirect();
	return ctx;
}

// The recording tap follows the selected track: that is the channel whose take
// the drums print to, and the channel the person arms. Re-evaluated on every
// input change (05_inputs calls it after a plug changes), never duplicated.
//
// A channel whose input plug is the drums already carries them through its own
// input chain into the same recDest, so the direct tap is disconnected then;
// the take would otherwise record the kit twice. Changing the plug away
// reconnects it. routedDest still names the channel the drums serve, which is
// how an empty armed track finds the drums as a recording source.
function studioDrumsRouteSelection() {
	var ctx = studioDrums.ctx;
	if (!ctx || !studioDrums.rec) { return; }
	var ch = parseInt(studioSelectedChannel, 10) || 1;
	var c = studioAudio.channels[ch];
	if (!c && typeof studioChannelEngine === 'function') { c = studioChannelEngine(ch); }
	if (!c || !c.recDest) { return; }
	var info = $('.studio_channel_information[direction="input"][channel="' + ch + '"]').text();
	var plug = isJson(info) ? JSON.parse(info) : {};
	try { studioDrums.rec.disconnect(); } catch (e) {}
	if (plug['app'] !== 'drums') { studioDrums.rec.connect(c.recDest); }
	studioDrums.routedDest = c.recDest;
}

// The kit's own dry feed is off while any channel has the kit as its input:
// that channel's live path (fader, Out chain, output cord) is the kit's sound.
// With no drum input the direct feed returns.
function studioDrumsPatchDirect() {
	if (!studioDrums || !studioDrums.direct) { return; }
	var patched = false;
	$.each(studioAudio.channels || {}, function (ch) {
		var plug = (typeof studioChannelInput === 'function') ? studioChannelInput(ch) : null;
		if (plug && String(plug['app'] || '') === 'drums') { patched = true; }
	});
	studioDrums.direct.gain.value = patched ? 0 : 1;
}

function studioDrumsBuild(ctx) {
	var Ctor = window.OfflineAudioContext || window.webkitOfflineAudioContext;
	var voices = studioDrumsVoices();
	if (!Ctor || !voices.length) { studioDrums.buildState = 'unsupported'; return; }
	// Two fast kit changes must not let an older, slower render write over the
	// newer buffers: only the newest build may land.
	var token = ++studioDrums.buildGen;
	var kit = studioDrums.kit;
	studioDrums.buildState = 'building';
	var rate = ctx.sampleRate || 44100;
	var pending = voices.length;
	var finish = function (voice, buffer) {
		if (token !== studioDrums.buildGen) { return; }
		if (buffer) { studioDrums.buffers[voice] = buffer; }
		pending--;
		if (pending <= 0) {
			studioDrums.builtKit = kit;
			studioDrums.buildState = 'ready';
		}
	};
	voices.forEach(function (v) {
		var spec = studioDrumsVoiceSpec(kit, v.name);
		var off;
		try { off = new Ctor(1, Math.ceil(rate * (spec.length || 0.6)), rate); }
		catch (e) { finish(v.name, null); return; }
		studioDrumsRenderVoice(off, kit, v.name);
		var rendering;
		try { rendering = off.startRendering(); }
		catch (e) { finish(v.name, null); return; }
		if (rendering && rendering.then) {
			rendering.then(function (buffer) { finish(v.name, buffer); })
				.catch(function () { finish(v.name, null); });
		}
		else {
			off.oncomplete = function (event) { finish(v.name, event.renderedBuffer); };
		}
	});
}

function studioDrumsNoiseBuffer(off, seconds) {
	var rate = off.sampleRate || 44100;
	var buffer = off.createBuffer(1, Math.ceil(rate * seconds), rate);
	var data = buffer.getChannelData(0);
	for (var i = 0; i < data.length; i++) { data[i] = Math.random() * 2 - 1; }
	return buffer;
}

// A voice is a shape, not a sample: one or two pitched sweeps plus a filtered
// noise wash. Everything below is rendered once, offline. These eight are the
// acoustic base; a kit overrides only the voices it changes.
function studioDrumsBaseSpec(name) {
	switch (name) {
		case 'kick':
			return { length: 0.55,
				tones: [{ type: 'sine', from: 150, to: 45, dur: 0.18, gain: 1.0, env: 0.45 }],
				noise: [{ filter: 'highpass', freq: 3000, dur: 0.012, gain: 0.25 }] };
		case 'snare':
			return { length: 0.35,
				tones: [{ type: 'triangle', from: 190, to: 160, dur: 0.12, gain: 0.45, env: 0.16 }],
				noise: [{ filter: 'bandpass', freq: 1800, q: 0.8, dur: 0.18, gain: 0.9 }] };
		case 'closed_hat':
			return { length: 0.15, noise: [{ filter: 'highpass', freq: 7500, dur: 0.055, gain: 0.6 }] };
		case 'open_hat':
			return { length: 0.45, noise: [{ filter: 'highpass', freq: 6500, dur: 0.32, gain: 0.55 }] };
		case 'clap':
			return studioDrumsClapSpec(1200, 1.2, 0.6, 0.12);
		case 'low_tom':
			return { length: 0.45, tones: [{ type: 'sine', from: 130, to: 75, dur: 0.22, gain: 0.9, env: 0.35 }] };
		case 'high_tom':
			return { length: 0.35, tones: [{ type: 'sine', from: 220, to: 130, dur: 0.18, gain: 0.85, env: 0.28 }] };
		case 'rim':
			return { length: 0.12,
				tones: [{ type: 'square', from: 900, to: 700, dur: 0.02, gain: 0.3, env: 0.05 }],
				noise: [{ filter: 'bandpass', freq: 2500, q: 1.4, dur: 0.02, gain: 0.4 }] };
	}
	return { length: 0.2, noise: [{ filter: 'highpass', freq: 2000, dur: 0.05, gain: 0.4 }] };
}

// A clap is the same four-burst shape in every kit; a kit only names its
// colour (frequency and resonance) and how long the last burst rings.
function studioDrumsClapSpec(freq, q, gain, tail) {
	var burst = function (at, dur, level) {
		return { filter: 'bandpass', freq: freq, q: q, at: at, dur: dur, gain: level };
	};
	return { length: tail + 0.2, noise: [
		burst(0, 0.02, gain),
		burst(0.011, 0.02, gain),
		burst(0.022, 0.02, gain),
		burst(0.03, tail, gain * 0.66)
	] };
}

// Each kit is a set of overrides on the acoustic base: only the voices that give
// it its character are listed, so a kick, snare and hat say most of it and a
// voice left out stays familiar. The names match perl/gb/05_abilities_and_studio.pl.
var studioDrumsKitSpecs = {
	// Tighter and brighter: a short synthetic kick, dry snare, glassy hats.
	electronic: {
		kick: { length: 0.32,
			tones: [{ type: 'sine', from: 180, to: 60, dur: 0.10, gain: 1.0, env: 0.22 }],
			noise: [{ filter: 'highpass', freq: 5000, dur: 0.008, gain: 0.18 }] },
		snare: { length: 0.22,
			tones: [{ type: 'triangle', from: 240, to: 200, dur: 0.07, gain: 0.35, env: 0.09 }],
			noise: [{ filter: 'bandpass', freq: 2600, q: 1.1, dur: 0.10, gain: 0.85 }] },
		closed_hat: { length: 0.10, noise: [{ filter: 'highpass', freq: 9000, dur: 0.035, gain: 0.55 }] },
		open_hat: { length: 0.28, noise: [{ filter: 'highpass', freq: 8500, dur: 0.20, gain: 0.5 }] },
		clap: studioDrumsClapSpec(1800, 1.5, 0.55, 0.07),
		low_tom: { length: 0.28, tones: [{ type: 'sine', from: 180, to: 110, dur: 0.12, gain: 0.8, env: 0.18 }] },
		high_tom: { length: 0.22, tones: [{ type: 'sine', from: 320, to: 200, dur: 0.10, gain: 0.75, env: 0.14 }] },
		rim: { length: 0.08,
			tones: [{ type: 'square', from: 1200, to: 1000, dur: 0.012, gain: 0.28, env: 0.03 }],
			noise: [{ filter: 'bandpass', freq: 3500, q: 1.6, dur: 0.015, gain: 0.35 }] }
	},
	// A hard kick with a click, tight hats and a gritty snare.
	techno: {
		kick: { length: 0.50,
			tones: [{ type: 'sine', from: 170, to: 38, dur: 0.14, gain: 1.15, env: 0.34 }],
			noise: [{ filter: 'highpass', freq: 2200, dur: 0.02, gain: 0.35 }] },
		snare: { length: 0.30,
			tones: [{ type: 'triangle', from: 210, to: 150, dur: 0.10, gain: 0.5, env: 0.13 }],
			noise: [{ filter: 'bandpass', freq: 1500, q: 0.6, dur: 0.14, gain: 0.95 }] },
		closed_hat: { length: 0.09, noise: [{ filter: 'highpass', freq: 8500, dur: 0.025, gain: 0.5 }] },
		open_hat: { length: 0.35, noise: [{ filter: 'highpass', freq: 6000, dur: 0.22, gain: 0.45 }] },
		clap: studioDrumsClapSpec(1000, 1.0, 0.6, 0.10),
		low_tom: { length: 0.40, tones: [{ type: 'sine', from: 120, to: 65, dur: 0.20, gain: 0.95, env: 0.30 }] },
		high_tom: { length: 0.30, tones: [{ type: 'sine', from: 200, to: 120, dur: 0.16, gain: 0.9, env: 0.24 }] },
		rim: { length: 0.10,
			tones: [{ type: 'square', from: 800, to: 600, dur: 0.015, gain: 0.32, env: 0.035 }],
			noise: [{ filter: 'bandpass', freq: 2200, q: 1.2, dur: 0.018, gain: 0.45 }] }
	},
	// Urban: a long sub under the kick, a snappy snare and clap.
	beats: {
		kick: { length: 0.80,
			tones: [{ type: 'sine', from: 110, to: 32, dur: 0.40, gain: 1.2, env: 0.60 }],
			noise: [{ filter: 'highpass', freq: 2500, dur: 0.015, gain: 0.3 }] },
		snare: { length: 0.30,
			tones: [{ type: 'triangle', from: 210, to: 180, dur: 0.08, gain: 0.4, env: 0.12 }],
			noise: [{ filter: 'bandpass', freq: 2200, q: 0.7, dur: 0.12, gain: 1.0 }] },
		closed_hat: { length: 0.12, noise: [{ filter: 'highpass', freq: 8000, dur: 0.04, gain: 0.5 }] },
		open_hat: { length: 0.40, noise: [{ filter: 'highpass', freq: 7000, dur: 0.26, gain: 0.45 }] },
		clap: studioDrumsClapSpec(1500, 1.4, 0.7, 0.08),
		low_tom: { length: 0.60, tones: [{ type: 'sine', from: 100, to: 55, dur: 0.32, gain: 1.0, env: 0.50 }] },
		high_tom: { length: 0.40, tones: [{ type: 'sine', from: 180, to: 110, dur: 0.22, gain: 0.9, env: 0.32 }] },
		rim: { length: 0.10,
			tones: [{ type: 'square', from: 1000, to: 800, dur: 0.015, gain: 0.3, env: 0.035 }],
			noise: [{ filter: 'bandpass', freq: 3000, q: 1.3, dur: 0.018, gain: 0.4 }] }
	},
	// Hand percussion: higher toms and rim, shaker-like hats.
	latin: {
		kick: { length: 0.30,
			tones: [{ type: 'sine', from: 200, to: 90, dur: 0.10, gain: 0.8, env: 0.20 }],
			noise: [{ filter: 'highpass', freq: 3500, dur: 0.008, gain: 0.15 }] },
		snare: { length: 0.18,
			tones: [{ type: 'triangle', from: 300, to: 260, dur: 0.06, gain: 0.25, env: 0.07 }],
			noise: [{ filter: 'bandpass', freq: 3000, q: 1.8, dur: 0.06, gain: 0.55 }] },
		closed_hat: { length: 0.18, noise: [{ filter: 'highpass', freq: 9000, dur: 0.10, gain: 0.28 }] },
		open_hat: { length: 0.50, noise: [{ filter: 'highpass', freq: 8500, dur: 0.40, gain: 0.22 }] },
		clap: studioDrumsClapSpec(2200, 2.2, 0.55, 0.06),
		low_tom: { length: 0.35, tones: [{ type: 'sine', from: 240, to: 150, dur: 0.18, gain: 0.75, env: 0.22 }] },
		high_tom: { length: 0.25, tones: [{ type: 'sine', from: 360, to: 240, dur: 0.12, gain: 0.7, env: 0.16 }] },
		rim: { length: 0.14,
			tones: [{ type: 'square', from: 1400, to: 1100, dur: 0.02, gain: 0.35, env: 0.04 }],
			noise: [{ filter: 'bandpass', freq: 3200, q: 2.0, dur: 0.025, gain: 0.5 }] }
	},
	// Bright and resonant, with a ringing snare.
	pearl: {
		kick: { length: 0.50,
			tones: [{ type: 'sine', from: 160, to: 52, dur: 0.16, gain: 1.0, env: 0.42 }],
			noise: [{ filter: 'highpass', freq: 3800, dur: 0.015, gain: 0.3 }] },
		snare: { length: 0.40,
			tones: [{ type: 'triangle', from: 210, to: 180, dur: 0.14, gain: 0.5, env: 0.20 }],
			noise: [{ filter: 'bandpass', freq: 2400, q: 0.9, dur: 0.22, gain: 1.0 }] },
		closed_hat: { length: 0.16, noise: [{ filter: 'highpass', freq: 8000, dur: 0.06, gain: 0.62 }] },
		open_hat: { length: 0.50, noise: [{ filter: 'highpass', freq: 7500, dur: 0.36, gain: 0.55 }] },
		clap: studioDrumsClapSpec(1400, 1.1, 0.6, 0.12),
		low_tom: { length: 0.50, tones: [{ type: 'sine', from: 150, to: 85, dur: 0.26, gain: 0.9, env: 0.40 }] },
		high_tom: { length: 0.40, tones: [{ type: 'sine', from: 260, to: 150, dur: 0.20, gain: 0.85, env: 0.32 }] },
		rim: { length: 0.13,
			tones: [{ type: 'square', from: 1000, to: 800, dur: 0.022, gain: 0.32, env: 0.045 }],
			noise: [{ filter: 'bandpass', freq: 2800, q: 1.5, dur: 0.022, gain: 0.45 }] }
	},
	// Punchy and deep: a short low kick and a deep snare.
	tama: {
		kick: { length: 0.42,
			tones: [{ type: 'sine', from: 140, to: 40, dur: 0.12, gain: 1.1, env: 0.26 }],
			noise: [{ filter: 'highpass', freq: 2000, dur: 0.018, gain: 0.3 }] },
		snare: { length: 0.30,
			tones: [{ type: 'triangle', from: 175, to: 145, dur: 0.09, gain: 0.5, env: 0.10 }],
			noise: [{ filter: 'bandpass', freq: 1600, q: 0.7, dur: 0.13, gain: 1.0 }] },
		closed_hat: { length: 0.12, noise: [{ filter: 'highpass', freq: 7000, dur: 0.04, gain: 0.55 }] },
		open_hat: { length: 0.40, noise: [{ filter: 'highpass', freq: 6200, dur: 0.26, gain: 0.5 }] },
		clap: studioDrumsClapSpec(1100, 1.0, 0.6, 0.11),
		low_tom: { length: 0.48, tones: [{ type: 'sine', from: 115, to: 62, dur: 0.24, gain: 0.95, env: 0.34 }] },
		high_tom: { length: 0.36, tones: [{ type: 'sine', from: 195, to: 110, dur: 0.18, gain: 0.9, env: 0.26 }] },
		rim: { length: 0.12,
			tones: [{ type: 'square', from: 850, to: 650, dur: 0.02, gain: 0.32, env: 0.04 }],
			noise: [{ filter: 'bandpass', freq: 2300, q: 1.3, dur: 0.02, gain: 0.45 }] }
	},
	// Warm and round: a softer click and darker, longer tails.
	gretsch: {
		kick: { length: 0.60,
			tones: [{ type: 'sine', from: 130, to: 42, dur: 0.22, gain: 0.95, env: 0.50 }],
			noise: [{ filter: 'highpass', freq: 1800, dur: 0.01, gain: 0.18 }] },
		snare: { length: 0.38,
			tones: [{ type: 'triangle', from: 165, to: 145, dur: 0.14, gain: 0.42, env: 0.20 }],
			noise: [{ filter: 'bandpass', freq: 1400, q: 0.6, dur: 0.20, gain: 0.8 }] },
		closed_hat: { length: 0.14, noise: [{ filter: 'highpass', freq: 6200, dur: 0.05, gain: 0.5 }] },
		open_hat: { length: 0.48, noise: [{ filter: 'highpass', freq: 5600, dur: 0.34, gain: 0.48 }] },
		clap: studioDrumsClapSpec(1000, 0.9, 0.55, 0.13),
		low_tom: { length: 0.52, tones: [{ type: 'sine', from: 115, to: 68, dur: 0.28, gain: 0.85, env: 0.42 }] },
		high_tom: { length: 0.42, tones: [{ type: 'sine', from: 200, to: 120, dur: 0.22, gain: 0.8, env: 0.34 }] },
		rim: { length: 0.13,
			tones: [{ type: 'square', from: 780, to: 620, dur: 0.022, gain: 0.28, env: 0.045 }],
			noise: [{ filter: 'bandpass', freq: 2000, q: 1.1, dur: 0.024, gain: 0.36 }] }
	},
	// A long sub kick, a snappy snare and metallic hats.
	'808': {
		kick: { length: 1.20,
			tones: [{ type: 'sine', from: 90, to: 28, dur: 0.70, gain: 1.2, env: 0.90 }],
			noise: [{ filter: 'highpass', freq: 4000, dur: 0.008, gain: 0.12 }] },
		snare: { length: 0.28,
			tones: [{ type: 'triangle', from: 230, to: 200, dur: 0.05, gain: 0.4, env: 0.07 }],
			noise: [{ filter: 'bandpass', freq: 2800, q: 1.2, dur: 0.10, gain: 1.0 }] },
		closed_hat: { length: 0.20, noise: [{ filter: 'highpass', freq: 10000, dur: 0.05, gain: 0.5 }] },
		open_hat: { length: 0.60, noise: [{ filter: 'highpass', freq: 9500, dur: 0.38, gain: 0.45 }] },
		clap: studioDrumsClapSpec(1900, 1.6, 0.55, 0.09),
		low_tom: { length: 0.80, tones: [{ type: 'sine', from: 95, to: 40, dur: 0.45, gain: 0.95, env: 0.60 }] },
		high_tom: { length: 0.50, tones: [{ type: 'sine', from: 180, to: 90, dur: 0.28, gain: 0.85, env: 0.40 }] },
		rim: { length: 0.10,
			tones: [{ type: 'square', from: 1600, to: 1300, dur: 0.015, gain: 0.3, env: 0.035 }],
			noise: [{ filter: 'bandpass', freq: 4000, q: 1.7, dur: 0.015, gain: 0.4 }] }
	},
	// Aggressive: a clicky, fast kick for a double-kick feel, a big snare and
	// cutting hats.
	metal: {
		kick: { length: 0.30,
			tones: [{ type: 'sine', from: 190, to: 55, dur: 0.07, gain: 1.1, env: 0.16 }],
			noise: [{ filter: 'highpass', freq: 5000, dur: 0.02, gain: 0.45 }] },
		snare: { length: 0.45,
			tones: [{ type: 'triangle', from: 260, to: 210, dur: 0.12, gain: 0.55, env: 0.18 }],
			noise: [{ filter: 'bandpass', freq: 3300, q: 0.6, dur: 0.25, gain: 1.05 }] },
		closed_hat: { length: 0.10, noise: [{ filter: 'highpass', freq: 9500, dur: 0.03, gain: 0.55 }] },
		open_hat: { length: 0.30, noise: [{ filter: 'highpass', freq: 9000, dur: 0.18, gain: 0.5 }] },
		clap: studioDrumsClapSpec(2400, 1.6, 0.6, 0.10),
		low_tom: { length: 0.30, tones: [{ type: 'sine', from: 150, to: 80, dur: 0.14, gain: 0.9, env: 0.20 }] },
		high_tom: { length: 0.24, tones: [{ type: 'sine', from: 270, to: 150, dur: 0.10, gain: 0.85, env: 0.14 }] },
		rim: { length: 0.10,
			tones: [{ type: 'square', from: 1400, to: 1100, dur: 0.015, gain: 0.34, env: 0.03 }],
			noise: [{ filter: 'bandpass', freq: 3800, q: 1.8, dur: 0.015, gain: 0.5 }] }
	}
};

// A kit is the acoustic spec with its overrides laid on top. A voice the kit
// leaves alone keeps the base shape; a voice it names takes the kit's tone and
// noise whole.
function studioDrumsVoiceSpec(kit, name) {
	var base = studioDrumsBaseSpec(name);
	var table = studioDrumsKitSpecs[kit];
	var change = table && table[name];
	if (!change) { return base; }
	var spec = { length: change.length || base.length };
	if (change.tones) { spec.tones = change.tones; }
	else if (base.tones) { spec.tones = base.tones; }
	if (change.noise) { spec.noise = change.noise; }
	else if (base.noise) { spec.noise = base.noise; }
	return spec;
}

function studioDrumsEnvelope(off, dur, peak, at) {
	var gain = off.createGain();
	var start = at || 0;
	gain.gain.setValueAtTime(0.0001, start);
	gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, peak), start + 0.003);
	gain.gain.exponentialRampToValueAtTime(0.0001, start + Math.max(0.004, dur));
	return gain;
}

function studioDrumsRenderVoice(off, kit, name) {
	var spec = studioDrumsVoiceSpec(kit, name);
	var noise = (spec.noise && spec.noise.length) ? studioDrumsNoiseBuffer(off, spec.length || 0.6) : null;
	(spec.tones || []).forEach(function (tone) {
		var at = tone.at || 0;
		var osc = off.createOscillator();
		var env = studioDrumsEnvelope(off, tone.env || tone.dur, tone.gain || 0.8, at);
		osc.type = tone.type || 'sine';
		osc.frequency.setValueAtTime(tone.from, at);
		osc.frequency.exponentialRampToValueAtTime(Math.max(20, tone.to), at + tone.dur);
		osc.connect(env);
		env.connect(off.destination);
		osc.start(at);
		osc.stop(at + Math.max(tone.dur, tone.env || 0) + 0.02);
	});
	(spec.noise || []).forEach(function (burst) {
		var at = burst.at || 0;
		var src = off.createBufferSource();
		var filter = off.createBiquadFilter();
		var env = studioDrumsEnvelope(off, burst.dur, burst.gain || 0.5, at);
		src.buffer = noise;
		filter.type = burst.filter || 'highpass';
		filter.frequency.value = burst.freq || 2000;
		if (burst.q) { filter.Q.value = burst.q; }
		src.connect(filter);
		filter.connect(env);
		env.connect(off.destination);
		src.start(at, 0, Math.min(burst.dur + 0.02, (spec.length || 0.6)));
	});
}

// ---- playing --------------------------------------------------------------

function studioDrumsPlay(voice, when, velocity) {
	var ctx = studioDrums.ctx;
	var buffer = studioDrums.buffers[voice];
	if (!ctx || !buffer || !studioDrums.out) { return; }
	var src = ctx.createBufferSource();
	var gain = ctx.createGain();
	src.buffer = buffer;
	gain.gain.value = Math.max(0.1, Math.min(1, velocity || 1));
	src.connect(gain);
	gain.connect(studioDrums.out);
	if (studioDrums.rec) { gain.connect(studioDrums.rec); }
	var at = when || ctx.currentTime;
	src.start(at);
	studioDrums.sources.push(src);
	src.onended = function () {
		var at_index = studioDrums.sources.indexOf(src);
		if (at_index >= 0) { studioDrums.sources.splice(at_index, 1); }
		try { gain.disconnect(); } catch (e) {}
	};
}

function studioDrumsStopSources() {
	studioDrums.sources.slice().forEach(function (src) {
		try { src.stop(); } catch (e) {}
	});
	studioDrums.sources = [];
}

function studioDrumsRecording() {
	if (!mixer || !mixer['time']) { return false; }
	if (mixer['time']['status'] === 'record') { return true; }
	var armed = false;
	$.each(mixer, function (ch, record) {
		if (!/^[0-9]+$/.test(ch) || !record || !record.armed) { return; }
		if (record.armed.state === 'rec') { armed = true; }
	});
	return armed;
}

function studioDrumsCurrentStep() {
	if (!studioDrums.running || !studioDrums.stepDur) { return 0; }
	var steps = studioDrums.lengthSteps || 16;
	var elapsed = (studioDrums.ctx.currentTime - studioDrums.anchor) / studioDrums.stepDur;
	var step = Math.floor(elapsed) % steps;
	return (step + steps) % steps;
}

// A mapped key, a MIDI note, the voice's own name button, a step or the velocity
// menu: one entry point, so recording and auditioning cannot disagree. The
// velocity is a percent (1..100); the play path takes the 0..1 fraction.
function studioDrumsTrigger(voice, velocity, record) {
	var ctx = studioDrumsBus();
	if (!ctx || !studioDrums.steps[voice]) { return; }
	var percent = Math.max(1, Math.min(100, Math.round(velocity || 0)));
	var step = studioDrumsCurrentStep();
	studioDrumsPlay(voice, ctx.currentTime + 0.008, percent / 100);
	if (record !== false && studioDrumsRecording()) {
		studioDrums.steps[voice][step] = percent;
		studioDrumsRenderSteps(voice);
		studioSaver();
	}
	studioDrumsHighlightStep(studioDrums.running ? step : -1);
}

// ---- the scheduler --------------------------------------------------------

function studioDrumsTransport(on) {
	if (on) {
		var ctx = studioDrumsBus();
		if (!ctx) { return; }
		studioDrums.running = true;
		studioDrums.done = false;
		studioDrums.step = 0;
		studioDrums.anchor = ctx.currentTime + 0.05;
		studioDrums.nextTime = studioDrums.anchor;
		if (!studioDrums.timer) { studioDrums.timer = setInterval(studioDrumsSchedule, 25); }
		studioDrumsSchedule();
		return;
	}
	studioDrums.running = false;
	studioDrums.done = false;
	studioDrums.nextTime = 0;
	studioDrums.step = 0;
	if (studioDrums.timer) { clearInterval(studioDrums.timer); studioDrums.timer = 0; }
	studioDrumsStopSources();
	studioDrumsHighlightStep(-1);
}

function studioDrumsSchedule() {
	if (!studioDrums.running) { return; }
	var status = mixer && mixer['time'] ? mixer['time']['status'] : 'stop';
	if (status !== 'play' && status !== 'record') { studioDrumsTransport(false); return; }
	var ctx = studioDrumsBus();
	if (!ctx) { return; }
	var bpm = studioKnobNumber(mixer['time']['bpm'], 120) || 120;
	var stepDur = 60 / bpm / 4;
	var steps = studioDrums.lengthSteps || 16;
	studioDrums.stepDur = stepDur;
	var now = ctx.currentTime;
	var guard = 0;
	while (studioDrums.nextTime < now + 0.1 && guard++ < 64) {
		studioDrumsPlayRow(studioDrums.step, studioDrums.nextTime);
		studioDrums.nextTime += stepDur;
		studioDrums.step = (studioDrums.step + 1) % steps;
		if (studioDrums.step === 0 && !studioDrums.loop) { studioDrums.done = true; break; }
	}
	if (studioDrums.done) {
		studioDrums.running = false;
		if (studioDrums.timer) { clearInterval(studioDrums.timer); studioDrums.timer = 0; }
		studioDrumsHighlightStep(-1);
		return;
	}
	var elapsed = (now - studioDrums.anchor) / stepDur;
	studioDrumsHighlightStep(((Math.floor(elapsed) % steps) + steps) % steps);
}

function studioDrumsPlayRow(step, when) {
	studioDrumsVoices().forEach(function (v) {
		if (studioDrums.muted[v.name]) { return; }
		var value = (studioDrums.steps[v.name] || [])[step] || 0;
		if (!value) { return; }
		studioDrumsPlay(v.name, when, value / 100);
	});
}

function studioDrumsHighlightStep(step) {
	var row = $('#studio_drums .studio_drums_row');
	row.find('.studio_drums_step').removeClass('studio_drums_playing');
	if (step >= 0) {
		row.find('.studio_drums_step[data-step="' + step + '"]').addClass('studio_drums_playing');
	}
}

// ---- the key map ----------------------------------------------------------

function studioDrumsVoiceForKey(key) {
	key = String(key || '').toLowerCase();
	var found = '';
	studioDrumsVoices().forEach(function (v) {
		if (studioDrums.keys[v.name] === key) { found = v.name; }
	});
	return found;
}

function studioDrumsVoiceForNote(note) {
	var found = '';
	studioDrumsVoices().forEach(function (v) {
		if (parseInt(v.note, 10) === parseInt(note, 10)) { found = v.name; }
	});
	return found;
}

function studioDrumsAssignKey(voice, key) {
	key = String(key || '').toLowerCase();
	if (key.length !== 1) { return; }
	studioDrumsVoices().forEach(function (v) {
		if (studioDrums.keys[v.name] === key) { delete studioDrums.keys[v.name]; }
	});
	studioDrums.keys[voice] = key;
	studioDrumsRender();
}

$(document).on('click', '.studio_drums_key', function (e) {
	e.preventDefault();
	var voice = $(this).attr('data-voice');
	studioDrums.learn = (studioDrums.learn === voice) ? null : voice;
	$('.studio_drums_key').attr('aria-pressed', 'false');
	if (studioDrums.learn) { $(this).attr('aria-pressed', 'true'); }
	studioDrumsFocusState();
});

$(document).on('click', '.studio_drums_voice', function (e) {
	e.preventDefault();
	studioDrumsTrigger($(this).attr('data-voice'), 80, false);
});

$(document).on('click', '.studio_drums_lamp', function (e) {
	e.preventDefault();
	var voice = $(this).attr('data-voice');
	studioDrums.muted[voice] = !studioDrums.muted[voice];
	studioDrumsRender();
	studioSaver();
});

$(document).on('click', '.studio_drums_step', function (e) {
	e.preventDefault();
	var voice = $(this).attr('data-voice');
	var step = parseInt($(this).attr('data-step'), 10) || 0;
	if (!studioDrums.steps[voice]) { return; }
	var current = studioDrums.steps[voice][step] || 0;
	// A plain click places a beat at 70; Shift places a full accent at 100.
	// Either click removes a beat that is already there.
	studioDrums.steps[voice][step] = current ? 0 : (e.shiftKey ? 100 : 70);
	studioDrumsRenderSteps(voice);
	if (studioDrums.steps[voice][step]) { studioDrumsTrigger(voice, studioDrums.steps[voice][step], false); }
	studioSaver();
});

// ---- a beat's velocity ----------------------------------------------------

function studioDrumsMenuClose() {
	$('#studio_drums_velocity').remove();
}

// The card is placed at the pointer and kept inside the window on every side.
function studioDrumsMenuPlace(menu, x, y) {
	var width = menu.outerWidth() || 148;
	var height = menu.outerHeight() || 60;
	var viewW = window.innerWidth || document.documentElement.clientWidth || 0;
	var viewH = window.innerHeight || document.documentElement.clientHeight || 0;
	var left = Math.max(4, Math.min(x, viewW - width - 4));
	var top = Math.max(4, Math.min(y, viewH - height - 4));
	menu.css({ left: left + 'px', top: top + 'px' });
}

// A placed beat carries a velocity from 10 to 100. The card stays open while
// the person taps it, so a beat can be tuned by ear in one visit.
function studioDrumsVelocityMenu(voice, step, x, y) {
	studioDrumsMenuClose();
	var value = (studioDrums.steps[voice] || [])[step] || 0;
	var menu = $('<div class="studio_menu studio_drums_velocity" id="studio_drums_velocity"></div>')
		.attr('data-voice', voice)
		.attr('data-step', step);
	$('<div class="studio_menu_head"></div>').text(studioDrumsVoiceLabel(voice)).appendTo(menu);
	var row = $('<div class="studio_menu_velocity"></div>').appendTo(menu);
	$('<button type="button" class="hover" data-delta="-10"></button>')
		.attr('aria-label', studioDrumsText('Softer'))
		.attr('title', studioDrumsText('Softer'))
		.text('\u2212')
		.appendTo(row);
	$('<span></span>').attr('data-value', '1').text(String(value)).appendTo(row);
	$('<button type="button" class="hover" data-delta="10"></button>')
		.attr('aria-label', studioDrumsText('Harder'))
		.attr('title', studioDrumsText('Harder'))
		.text('+')
		.appendTo(row);
	$('body').append(menu);
	studioDrumsMenuPlace(menu, x, y);
}

// Right-click opens the menu on a placed beat only; an empty step has no
// velocity, so the browser's own menu stands there.
$(document).on('contextmenu', '.studio_drums_step', function (e) {
	var voice = $(this).attr('data-voice');
	var step = parseInt($(this).attr('data-step'), 10) || 0;
	var value = (studioDrums.steps[voice] || [])[step] || 0;
	if (!value) { return; }
	e.preventDefault();
	studioDrumsVelocityMenu(voice, step, e.clientX, e.clientY);
});

$(document).on('click', '#studio_drums_velocity button', function (e) {
	e.preventDefault();
	var menu = $('#studio_drums_velocity');
	if (!menu.length) { return; }
	var voice = menu.attr('data-voice');
	var step = parseInt(menu.attr('data-step'), 10) || 0;
	var delta = parseInt($(this).attr('data-delta'), 10) || 0;
	if (!studioDrums.steps[voice]) { return; }
	var value = Math.max(10, Math.min(100, (studioDrums.steps[voice][step] || 0) + delta));
	studioDrums.steps[voice][step] = value;
	studioDrumsRenderSteps(voice);
	menu.find('[data-value]').text(String(value));
	studioDrumsTrigger(voice, value, false);
	studioSaver();
});

// The next press elsewhere, Escape, a scroll or a cleared chart closes it.
$(document).on('pointerdown', function (e) {
	if (!$(e.target).closest('#studio_drums_velocity').length) { studioDrumsMenuClose(); }
});

$(document).on('keydown', function (e) {
	if (e.key === 'Escape') { studioDrumsMenuClose(); }
});

document.addEventListener('scroll', studioDrumsMenuClose, true);

$(document).on('change', '#studio_drums_kit', function () {
	studioDrums.kit = studioDrumsKitName($(this).val());
	// The rendered buffers belong to the old kit; build the new set and let the
	// build token drop anything the old render still has in flight.
	studioDrums.buffers = {};
	studioDrums.buildState = 'idle';
	if (studioDrums.ctx) { studioDrumsBuild(studioDrums.ctx); }
	studioDrumsRender();
	studioSaver();
});

$(document).on('change', '#studio_drums_loop', function () {
	studioDrums.loop = $(this).prop('checked');
	studioSaver();
});

$(document).on('click', '#studio_drums_clear', function (e) {
	e.preventDefault();
	studioDrumsMenuClose();
	studioDrumsVoices().forEach(function (v) {
		studioDrums.steps[v.name] = studioDrumsZeroRow(studioDrums.lengthSteps);
	});
	studioDrumsRender();
	studioSaver();
});

// ---- the chart length -----------------------------------------------------

$(document).on('click', '#studio_drums_bar_add', function (e) {
	e.preventDefault();
	studioDrumsChangeLength(16);
});

$(document).on('click', '#studio_drums_bar_remove', function (e) {
	e.preventDefault();
	studioDrumsChangeLength(-16);
});

$(document).on('click', '#studio_drums_beat_add', function (e) {
	e.preventDefault();
	studioDrumsChangeLength(4);
});

$(document).on('click', '#studio_drums_beat_remove', function (e) {
	e.preventDefault();
	studioDrumsChangeLength(-4);
});

// ---- the saved loop library ----------------------------------------------

// The library is a plain array published by the panel and persisted in the
// drum_loops app setting. It is shared by the panel's list and the track menu.
function studioDrumsLoopLibrary() {
	var library = window.jawnos_studio_drum_loops;
	if (!library || typeof library.length !== 'number') {
		library = [];
		window.jawnos_studio_drum_loops = library;
	}
	return library;
}

function studioDrumsLoopPersist() {
	studioSaveSettings([{ setting: 'drum_loops', value: JSON.stringify(studioDrumsLoopLibrary()) }]);
}

function studioDrumsLoopOptions() {
	var select = $('#studio_drums_loops');
	if (!select.length) { return; }
	var chosen = select.val();
	select.empty();
	select.append($('<option></option>').attr('value', '').text(studioDrumsText('No saved loop')));
	studioDrumsLoopLibrary().forEach(function (item, index) {
		if (!item || !item.name) { return; }
		select.append($('<option></option>').attr('value', String(index)).text(item.name));
	});
	if (chosen !== null && chosen !== undefined && select.find('option[value="' + chosen + '"]').length) {
		select.val(chosen);
	}
}

function studioDrumsChosenLoop() {
	var select = $('#studio_drums_loops');
	if (!select.length) { return null; }
	var index = parseInt(select.val(), 10);
	var library = studioDrumsLoopLibrary();
	if (!(index >= 0) || !library[index]) { return null; }
	return library[index];
}

// A saved loop is the pattern alone: the name, the kit, the length and a deep
// copy of every row. Editing the chart afterwards cannot change it.
function studioDrumsSaveLoop() {
	var name = String($('#studio_drums_save_name').val() || '').trim();
	if (!name) { return false; }
	var steps = {};
	studioDrumsVoices().forEach(function (v) {
		steps[v.name] = (studioDrums.steps[v.name] || []).slice(0, studioDrums.lengthSteps);
	});
	var library = studioDrumsLoopLibrary();
	library.push({ name: name, kit: studioDrums.kit, length: studioDrums.lengthSteps, steps: steps });
	studioDrumsLoopPersist();
	studioDrumsLoopOptions();
	$('#studio_drums_loops').val(String(library.length - 1));
	return true;
}

function studioDrumsLoadLoop() {
	var item = studioDrumsChosenLoop();
	if (!item) { return false; }
	studioDrums.lengthSteps = studioDrumsNormaliseLength(item.length);
	var saved = item.steps || {};
	studioDrumsVoices().forEach(function (v) {
		var row = saved[v.name] || [];
		var steps = studioDrumsZeroRow(studioDrums.lengthSteps);
		for (var i = 0; i < studioDrums.lengthSteps && i < row.length; i++) {
			var value = parseInt(row[i], 10);
			steps[i] = (value > 0) ? Math.min(100, value) : 0;
		}
		studioDrums.steps[v.name] = steps;
	});
	// A loop saved with a kit this build does not have falls back to Acoustic.
	var kit = studioDrumsKitName(item.kit);
	if (kit !== studioDrums.kit) {
		studioDrums.kit = kit;
		studioDrums.buffers = {};
		studioDrums.buildState = 'idle';
		if (studioDrums.ctx) { studioDrumsBuild(studioDrums.ctx); }
	}
	studioDrumsRender();
	studioSaver();
	return true;
}

function studioDrumsDeleteLoop() {
	var select = $('#studio_drums_loops');
	var index = parseInt(select.val(), 10);
	var library = studioDrumsLoopLibrary();
	if (!(index >= 0) || !library[index]) { return false; }
	library.splice(index, 1);
	studioDrumsLoopPersist();
	studioDrumsLoopOptions();
	return true;
}

$(document).on('click', '#studio_drums_save_loop', function (e) {
	e.preventDefault();
	studioDrumsSaveLoop();
});

$(document).on('click', '#studio_drums_load_loop', function (e) {
	e.preventDefault();
	studioDrumsLoadLoop();
});

$(document).on('click', '#studio_drums_delete_loop', function (e) {
	e.preventDefault();
	studioDrumsDeleteLoop();
});

// ---- a saved loop as a take ----------------------------------------------

// The kit buffers an offline render needs. The live kit is kept as rendered;
// another kit is built into a throwaway set, so the panel's kit never changes.
function studioDrumsOfflineBuffers(kit, rate) {
	return new Promise(function (resolve) {
		var voices = studioDrumsVoices();
		if (!voices.length) { resolve({}); return; }
		if (kit === studioDrums.kit) {
			var live = function () {
				if (studioDrums.buildState !== 'ready' || studioDrums.builtKit !== kit) { return false; }
				resolve(studioDrums.buffers || {});
				return true;
			};
			if (live()) { return; }
			if (studioDrums.buildState === 'idle') {
				var ctx = studioContext();
				if (!ctx) { resolve({}); return; }
				studioDrumsBuild(ctx);
			}
			var tries = 0;
			var timer = setInterval(function () {
				tries++;
				if (live() || studioDrums.buildState === 'unsupported' || tries > 400) {
					clearInterval(timer);
					resolve(studioDrums.buffers || {});
				}
			}, 25);
			return;
		}
		var Ctor = window.OfflineAudioContext || window.webkitOfflineAudioContext;
		if (!Ctor) { resolve({}); return; }
		var out = {};
		var pending = voices.length;
		var done = function (name, buffer) {
			if (buffer) { out[name] = buffer; }
			pending--;
			if (pending <= 0) { resolve(out); }
		};
		voices.forEach(function (v) {
			var spec = studioDrumsVoiceSpec(kit, v.name);
			var off;
			try { off = new Ctor(1, Math.ceil(rate * (spec.length || 0.6)), rate); }
			catch (e) { done(v.name, null); return; }
			studioDrumsRenderVoice(off, kit, v.name);
			var rendering;
			try { rendering = off.startRendering(); }
			catch (e) { done(v.name, null); return; }
			if (rendering && rendering.then) {
				rendering.then(function (buffer) { done(v.name, buffer); })
					.catch(function () { done(v.name, null); });
			}
			else {
				off.oncomplete = function (event) { done(v.name, event.renderedBuffer); };
			}
		});
	});
}

// Render a saved pattern offline at the transport tempo, then place it on a
// loop track as an ordinary looping take carrying its own WAV blob.
function studioDrumsInsertLoop(ch, at, item) {
	ch = String(ch);
	if (!item || !item.name) { return null; }
	var m = mixer[ch];
	if (!m || !m.media) { return null; }
	var length = studioDrumsNormaliseLength(item.length);
	var bpm = studioKnobNumber(mixer['time'] && mixer['time']['bpm'], 120) || 120;
	var stepDur = 60 / bpm / 4;
	var duration = length * stepDur;
	var ctx = studioContext();
	var rate = (ctx && ctx.sampleRate) || 44100;
	var kit = studioDrumsKitName(item.kit);
	var Ctor = window.OfflineAudioContext || window.webkitOfflineAudioContext;
	if (!Ctor) { return null; }
	return studioDrumsOfflineBuffers(kit, rate).then(function (kitBuffers) {
		var off;
		try { off = new Ctor(2, Math.ceil(rate * duration), rate); }
		catch (e) { return null; }
		var steps = item.steps || {};
		studioDrumsVoices().forEach(function (v) {
			var buffer = kitBuffers[v.name];
			if (!buffer) { return; }
			var row = steps[v.name] || [];
			for (var i = 0; i < length && i < row.length; i++) {
				var value = parseInt(row[i], 10) || 0;
				if (value <= 0) { continue; }
				var src = off.createBufferSource();
				var gain = off.createGain();
				src.buffer = buffer;
				gain.gain.value = Math.min(1, value / 100);
				src.connect(gain);
				gain.connect(off.destination);
				src.start(i * stepDur);
			}
		});
		var rendering;
		try { rendering = off.startRendering(); }
		catch (e) { return null; }
		return new Promise(function (resolve) {
			var finish = function (buffer) {
				resolve(buffer ? studioDrumsLoopTake(ch, at, buffer) : null);
			};
			if (rendering && rendering.then) {
				rendering.then(finish).catch(function () { finish(null); });
			}
			else {
				off.oncomplete = function (event) { finish(event.renderedBuffer); };
			}
		});
	}).catch(function () { return null; });
}

// The take is the same shape a recording produces, so the rest of the timeline
// treats it as any other clip: it draws, loops and uploads through studioSave.
function studioDrumsLoopTake(ch, at, buffer) {
	var m = mixer[ch];
	if (!m || !m.media) { return null; }
	if (!m.media.out) { m.media.out = []; }
	var wav = studioBufferToWav(buffer);
	// A 600-bucket waveform from channel 0, so the clip draws immediately.
	var peaks = new Float32Array(600);
	var data = buffer.getChannelData(0);
	var stride = Math.max(1, Math.floor(data.length / 600));
	for (var b = 0; b < 600; b++) {
		var peak = 0;
		for (var i = b * stride; i < (b + 1) * stride && i < data.length; i++) {
			var v = Math.abs(data[i]);
			if (v > peak) { peak = v; }
		}
		peaks[b] = peak;
	}
	var el = document.createElement('video');
	el.className = 'studio_video';
	el.style.display = 'none';
	el.preload = 'auto';
	var take = {
		uuid: null,
		startTime: at,
		offset: 0,
		duration: buffer.duration,
		status: 'stop',
		buffer: buffer,
		loop: true,
		encoding: 'audio/wav',
		data: wav,
		src: URL.createObjectURL(wav)
	};
	el.src = take.src;
	$('#studio_track_container').append(el);
	take.track = el;
	take.waveform = peaks;
	if (take.src) { studioWaveformCache[take.src] = peaks; }
	m.media.out.push(take);
	studioReindexTakes(ch);
	mixer['time']['duration'] = Math.max(mixer['time']['duration'] || 0, take.startTime + take.duration);
	studioDrawChannel(ch);
	studioSaver();
	studioTakesChanged();
	return take;
}

// The guard that keeps a track name from playing a kick: a mapped key only
// sounds when no text field has focus and Studio was the last window touched.
$(document).on('keydown', function (e) {
	if (e.metaKey || e.ctrlKey || e.altKey) { return; }
	if (!$('#studio').is(':visible') || !$('#studio_drums').length) { return; }
	if (studioDrums.learn) {
		if (e.key === 'Escape') {
			studioDrums.learn = null;
			$('.studio_drums_key').attr('aria-pressed', 'false');
			studioDrumsFocusState();
			e.preventDefault();
			return;
		}
		if (String(e.key || '').length !== 1) { return; }
		studioDrumsAssignKey(studioDrums.learn, e.key);
		studioDrums.learn = null;
		$('.studio_drums_key').attr('aria-pressed', 'false');
		studioDrumsFocusState();
		studioSaver();
		e.preventDefault();
		return;
	}
	if (studioDrumsTyping() || !studioDrums.focus || e.repeat) { return; }
	if (typeof studioSelectedTake !== 'undefined' && studioSelectedTake) { return; }
	var voice = studioDrumsVoiceForKey(e.key);
	if (!voice) { return; }
	studioDrumsTrigger(voice, e.shiftKey ? 100 : 70, true);
	e.preventDefault();
});

// The last pointer press decides which window owns the keys; the panel bar says
// so in words, so a person is never guessing.
$(document).on('pointerdown', function (e) {
	studioDrums.focus = !!$(e.target).closest('#studio').length;
	studioDrumsFocusState();
});

$(document).on('focusin', function (e) {
	if ($(e.target).closest('#studio').length) { studioDrums.focus = true; }
	studioDrumsFocusState();
});

// ---- Web MIDI -------------------------------------------------------------

function studioDrumsMidiProbe() {
	var button = $('#studio_drums_midi');
	var state = $('#studio_drums_midi_state');
	if (!navigator.requestMIDIAccess) {
		button.prop('disabled', true);
		state.text(studioDrumsText('Web MIDI is not available in this browser.'));
		return;
	}
	button.prop('disabled', false);
	if (!state.text()) { state.text(studioDrumsText('MIDI ready')); }
}

function studioDrumsMidiConnect() {
	if (!navigator.requestMIDIAccess) { studioDrumsMidiProbe(); return; }
	var state = $('#studio_drums_midi_state');
	state.text(studioDrumsText('Opening MIDI...'));
	navigator.requestMIDIAccess().then(function (access) {
		studioDrums.midi = access;
		studioDrumsMidiList(access);
		access.onstatechange = function () { studioDrumsMidiList(access); };
	}).catch(function (error) {
		state.text(studioDrumsText('MIDI could not be opened.') + (error && error.message ? ' ' + error.message : ''));
	});
}

function studioDrumsMidiList(access) {
	var select = $('#studio_drums_midi_input');
	var state = $('#studio_drums_midi_state');
	var inputs = [];
	access.inputs.forEach(function (input) { inputs.push(input); });
	select.empty();
	select.append($('<option></option>').attr('value', '').text(studioDrumsText('No MIDI input')));
	inputs.forEach(function (input) {
		select.append($('<option></option>').attr('value', input.id).text(input.name || input.id));
		input.onmidimessage = function (event) { studioDrumsMidiMessage(input, event); };
	});
	if (!studioDrums.midiInput || !inputs.some(function (i) { return i.id === studioDrums.midiInput; })) {
		studioDrums.midiInput = inputs.length ? inputs[0].id : '';
	}
	select.val(studioDrums.midiInput);
	select.prop('disabled', !inputs.length);
	state.text(inputs.length
		? studioDrumsText('MIDI notes play these drums; the accent follows velocity.')
		: studioDrumsText('No MIDI input was found.'));
}

function studioDrumsMidiMessage(input, event) {
	if (input.id !== studioDrums.midiInput) { return; }
	var data = event.data;
	if (!data || data.length < 3) { return; }
	if ((data[0] & 0xf0) !== 0x90 || data[2] === 0) { return; }
	var voice = studioDrumsVoiceForNote(data[1]);
	if (!voice) { return; }
	// A note's velocity is 0..127; a beat is a percent, and 1 is the softest hit.
	studioDrumsTrigger(voice, Math.max(1, Math.round(data[2] / 127 * 100)), true);
}

$(document).on('click', '#studio_drums_midi', function (e) {
	e.preventDefault();
	studioDrumsMidiConnect();
});

$(document).on('change', '#studio_drums_midi_input', function () {
	studioDrums.midiInput = $(this).val() || '';
	studioSaver();
});

// The drum bus follows the selected track, so arming that track captures the
// drums. The selection handlers live in 03_editing.js and 09_pedals.js; this
// one runs after them and only re-routes the recording tap.
$(document).on('click', '.channel, .studio_track_panel', function () {
	studioDrumsRouteSelection();
});

// ---- init -----------------------------------------------------------------

function studioDrumsInit() {
	if (!studioDrumsVoices().length) { return; }
	if (!studioDrums.loaded) { studioDrumsDefaults(); }
	studioDrumsRender();
	studioDrumsLoopOptions();
	studioDrums.focus = !!$('#studio').is(':visible');
	studioDrumsBus();
	studioDrumsMidiProbe();
	studioDrumsGridState();
	studioDrumsFocusState();
}
