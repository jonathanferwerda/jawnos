// ===========================================================================
// Mix export
// ===========================================================================
// The whole song is rendered once in an OfflineAudioContext through the same
// graph the window plays - every channel's output inserts, then its fader and
// pan, summed onto one bus, then optionally the mastering rack - encoded as a
// WAV in the browser, and posted to the manager, which transcodes it and files
// it on the song as an audio appointment file. The song must already be saved:
// the file joins an existing appointment, it never makes one.
//
// The live transport is not touched: the mix gets its own offline context and
// the window stays usable while it renders.

var studioExportRunning = false;

function studioExportText(text) {
	var translated = (typeof jawnosT === 'function') ? jawnosT(text) : text;
	return (translated === undefined || translated === null) ? text : translated;
}

function studioExportState(text) {
	var el = $('#studio_export_state');
	if (el && el.length) { el.text(text || ''); }
}

function studioExportNumber(value, fallback) {
	var number = parseFloat(value);
	return isFinite(number) ? number : fallback;
}

function studioExportFormat() {
	var format = String($('#studio_export_format').val() || 'wav').toLowerCase();
	return (format === 'wav' || format === 'mp3' || format === 'flac') ? format : 'wav';
}

function studioExportBitrate() {
	var number = Math.round(studioExportNumber($('#studio_export_bitrate').val(), 192));
	return Math.max(64, Math.min(320, number));
}

function studioExportMasterWanted() {
	var box = $('#studio_export_master');
	if (box && box.length && box.prop) { return !!box.prop('checked'); }
	return false;
}


// Every numeric mixer channel that carries at least one take, in channel order.
// A channel with no takes has nothing to render and is left out.
function studioExportChannels() {
	var out = [];
	Object.keys(mixer || {}).forEach(function (key) {
		if (!/^[0-9]+$/.test(key)) { return; }
		var c = mixer[key] || {};
		var takes = (typeof studioChannelTakes === 'function')
			? studioChannelTakes(key)
			: (((c.media && c.media.out) || []).slice());
		takes = (takes || []).filter(function (take) {
			return take && take.status != 'recording' && !studioExportTakeIsVideo(take);
		});
		if (!takes.length) { return; }
		out.push({ channel: key, c: c, takes: takes });
	});
	return out;
}

// The render is as long as the last take ends, or the song's own length when
// that is longer. Ten milliseconds is the floor so an OfflineAudioContext is
// never asked for zero frames.
function studioExportDuration(takes, songDuration) {
	var end = 0;
	(takes || []).forEach(function (take) {
		if (!take) { return; }
		var start = studioExportNumber(take.startTime, 0);
		var span = studioExportNumber(take.duration, 0);
		if (!(span > 0) && take.buffer && take.buffer.duration > 0) {
			span = take.buffer.duration - studioExportNumber(take.offset, 0);
		}
		if (!(span > 0)) { return; }
		var stop = Math.max(0, start) + span;
		if (stop > end) { end = stop; }
	});
	var song = studioExportNumber(songDuration, 0);
	if (song > end) { end = song; }
	return Math.max(0.1, end);
}

function studioExportTakeIsVideo(take) {
	return !!(take && take.encoding && String(take.encoding).indexOf('video') !== -1);
}

async function studioExportTakeBuffer(off, take) {
	if (take.buffer) { return take.buffer; }
	if (!take.src) { return null; }
	try {
		var response = await fetch(take.src);
		var bytes = await response.arrayBuffer();
		return await off.decodeAudioData(bytes);
	}
	catch (e) {
		return null;
	}
}

// One take as simple buffer plays: at its song position, from its own offset,
// for its own length. A looping take wraps back to its in-point until the song
// ends. Crossfades are not applied: an export is the printed track, not the
// seam-faded preview.
function studioExportSchedule(off, destination, take, buffer, songEnd) {
	if (!buffer) { return; }
	var offset = Math.max(0, studioExportNumber(take.offset, 0));
	var span = studioExportNumber(take.duration, 0);
	if (!(span > 0)) { span = Math.max(0, (buffer.duration || 0) - offset); }
	if (!(span > 0)) { return; }
	var at = Math.max(0, studioExportNumber(take.startTime, 0));
	for (var n = 0; n < 4096; n++) {
		if (!(at < songEnd)) { break; }
		var play = Math.min(span, songEnd - at);
		if (!(play > 0)) { break; }
		var source = off.createBufferSource();
		source.buffer = buffer;
		source.connect(destination);
		if (source.start) { source.start(at, offset, play); }
		if (!take.loop) { break; }
		at += span;
	}
}

// The channel's output pedals, built on the offline context exactly as the live
// channel built them: same names, same values, same footswitches. A song saved
// before the output chain existed has no `outInserts`, so the chain is a plain
// pass-through.
function studioExportInsertChain(off, c) {
	var input = off.createGain();
	var node = input;
	((c && c.outInserts) || []).forEach(function (ins) {
		if (!ins || !ins.name) { return; }
		var built = studioInsert(off, ins.name);
		if (!built || !built.input || !built.output) { return; }
		var values = ins.values || {};
		Object.keys(values).forEach(function (control) {
			if (built.set) { built.set(control, values[control]); }
		});
		if (built.setBypass) { built.setBypass(!!ins.bypassed); }
		node.connect(built.input);
		node = built.output;
	});
	return { input: input, output: node };
}

// The mastering rack is the one the window shows: studioMasterSave() is the
// song's own record of it, so the export cannot drift from the mix.
function studioExportMasterRestore(master) {
	if (!master) { return; }
	var records = (typeof studioMasterSave === 'function') ? (studioMasterSave() || []) : [];
	records.forEach(function (record) {
		if (!record || !record.name) { return; }
		var ins = (master.insertByName && master.insertByName[record.name]) ? master.insertByName[record.name] : null;
		if (!ins) { return; }
		$.each(record.controls || {}, function (control, value) {
			if (ins.set) { ins.set(control, value); }
		});
		if (ins.setBypass) { ins.setBypass(record.on !== true); }
	});
}

// Build the whole song's offline graph and return the context, each channel's
// take input, and the length the takes are laid out against. Every channel with
// takes keeps its own output inserts, fader and pan; their tails are summed on
// one bus, which feeds the mastering rack when it is wanted, or the destination.
function studioExportOffline(entries, includeMaster) {
	var rate = 44100;
	try {
		var live = studioContext();
		if (live && live.sampleRate > 0) { rate = live.sampleRate; }
	}
	catch (e) {}

	var takes = [];
	(entries || []).forEach(function (entry) {
		(entry.takes || []).forEach(function (take) { takes.push(take); });
	});
	var songEnd = studioExportDuration(takes, (mixer && mixer['time']) ? mixer['time']['duration'] : 0);
	var frames = Math.max(1, Math.ceil(songEnd * rate));
	var off = new OfflineAudioContext(2, frames, rate);

	var bus = off.destination;
	if (includeMaster) {
		var master = studioMasterChain(off);
		studioExportMasterRestore(master);
		master.output.connect(off.destination);
		bus = master.input;
	}

	var inputs = [];
	(entries || []).forEach(function (entry) {
		var chain = studioExportInsertChain(off, entry.c);

		var volume = off.createGain();
		volume.gain.value = (typeof studioVolumeFraction === 'function')
			? studioVolumeFraction($('.channel_volume[channel="' + entry.channel + '"]').val())
			: 1;
		var panValue = (studioExportNumber($('.knob_control[channel="' + entry.channel + '"][control="pan"]').val(), 50) - 50) / 50;
		var pan = off.createStereoPanner ? off.createStereoPanner() : null;
		if (pan) { pan.pan.value = Math.max(-1, Math.min(1, panValue)); }

		chain.output.connect(volume);
		var tail = volume;
		if (pan) { volume.connect(pan); tail = pan; }
		tail.connect(bus);

		inputs.push({ input: chain.input, takes: entry.takes || [] });
	});

	return { ctx: off, inputs: inputs, duration: songEnd, rate: rate };
}

// Schedule every take of every channel into its channel's input, render the
// song once, encode one WAV, and attach it to the song under the song's name.
async function studioExportMix(entries, uuid, songName, format, bitrate, includeMaster) {
	var offline = studioExportOffline(entries, includeMaster);
	for (var i = 0; i < offline.inputs.length; i++) {
		var input = offline.inputs[i];
		for (var j = 0; j < input.takes.length; j++) {
			var take = input.takes[j];
			if (!take || take.status == 'recording') { continue; }
			if (studioExportTakeIsVideo(take)) { continue; }
			var buffer = await studioExportTakeBuffer(offline.ctx, take);
			if (!buffer) { continue; }
			studioExportSchedule(offline.ctx, input.input, take, buffer, offline.duration);
		}
	}

	var rendered = await offline.ctx.startRendering();
	var wav = studioBufferToWav(rendered);

	var form = new FormData();
	form.append('uuid', uuid);
	form.append('name', songName);
	form.append('format', format);
	form.append('bitrate', String(bitrate));
	form.append('master', includeMaster ? '1' : '0');
	form.append('audio', wav, songName + '.wav');

	var response = await fetch('/manager/studio/export', { method: 'POST', body: form });
	var answer = null;
	try { answer = await response.json(); }
	catch (e) { answer = null; }
	if (!response.ok || !answer || answer.ok !== 1) {
		throw new Error((answer && answer.error) || ('the server answered ' + (response.status || '?')));
	}
	return answer;
}

// Render the whole song once and attach the mixed file to it. The state line
// says the mix is rendering, then names the attached file or carries the
// server's own sentence on a failure.
async function studioExportTracks() {
	if (studioExportRunning) { return; }
	studioExportRunning = true;
	try {
		var song = $('#studio');
		var uuid = song.attr('uuid');
		var name = song.attr('name');
		if (!uuid || !name) {
			studioExportState(studioExportText('Save the song before exporting its mix.'));
			return;
		}

		var format = studioExportFormat();
		var bitrate = studioExportBitrate();
		var includeMaster = studioExportMasterWanted();
		var channels = studioExportChannels();
		if (!channels.length) {
			studioExportState(studioExportText('There are no tracks to export.'));
			return;
		}

		studioExportState(studioExportText('Rendering the mix\u2026'));
		try {
			await studioExportMix(channels, uuid, name, format, bitrate, includeMaster);
			studioExportState(studioExportText('Mix attached.'));
		}
		catch (error) {
			studioExportState(studioExportText('The export failed.') + ' ' + ((error && error.message) ? error.message : ''));
		}
	}
	finally {
		studioExportRunning = false;
	}
}

$(document).on('click', '#studio_export_tracks', function () {
	studioExportTracks().catch(function (error) {
		studioExportState(studioExportText('The export failed.') + ' ' + ((error && error.message) ? error.message : ''));
	});
});
