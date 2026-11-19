// ===========================================================================
// Track export
// ===========================================================================
// Every track is rendered through its own output chain in an OfflineAudioContext,
// encoded as a WAV in the browser, and posted to the manager, which transcodes it
// and files it on the song as an audio appointment file. The song must already be
// saved: the file joins an existing appointment, it never makes one.
//
// The render is deliberately the same graph the window plays - the channel's
// output inserts, then its fader and pan, then optionally the mastering rack -
// so an export sounds like the track does. The live transport is not touched:
// each track gets its own offline context and the window stays usable while the
// tracks run one at a time.

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

function studioExportTrackName(channel) {
	var value = $('.studio_track_name[channel="' + channel + '"]').val();
	if (value === undefined || value === null) { return 'Track ' + channel; }
	value = String(value).replace(/^\s+|\s+$/g, '');
	return value.length ? value : ('Track ' + channel);
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

// Build one track's offline graph and return the context, its take input, and
// the length the takes are laid out against.
function studioExportOffline(channel, c, takes, includeMaster) {
	var rate = 44100;
	try {
		var live = studioContext();
		if (live && live.sampleRate > 0) { rate = live.sampleRate; }
	}
	catch (e) {}
	var songEnd = studioExportDuration(takes, (mixer && mixer['time']) ? mixer['time']['duration'] : 0);
	var frames = Math.max(1, Math.ceil(songEnd * rate));
	var off = new OfflineAudioContext(2, frames, rate);
	var chain = studioExportInsertChain(off, c);

	var volume = off.createGain();
	volume.gain.value = (typeof studioVolumeFraction === 'function')
		? studioVolumeFraction($('.channel_volume[channel="' + channel + '"]').val())
		: 1;
	var panValue = (studioExportNumber($('.knob_control[channel="' + channel + '"][control="pan"]').val(), 50) - 50) / 50;
	var pan = off.createStereoPanner ? off.createStereoPanner() : null;
	if (pan) { pan.pan.value = Math.max(-1, Math.min(1, panValue)); }

	chain.output.connect(volume);
	var tail = volume;
	if (pan) { volume.connect(pan); tail = pan; }

	if (includeMaster) {
		var master = studioMasterChain(off);
		studioExportMasterRestore(master);
		tail.connect(master.input);
		master.output.connect(off.destination);
	}
	else {
		tail.connect(off.destination);
	}
	return { ctx: off, input: chain.input, duration: songEnd, rate: rate };
}

async function studioExportOne(entry, uuid, trackName, format, bitrate, includeMaster) {
	var offline = studioExportOffline(entry.channel, entry.c, entry.takes, includeMaster);
	for (var i = 0; i < entry.takes.length; i++) {
		var take = entry.takes[i];
		if (!take || take.status == 'recording') { continue; }
		if (studioExportTakeIsVideo(take)) { continue; }
		var buffer = await studioExportTakeBuffer(offline.ctx, take);
		if (!buffer) { continue; }
		studioExportSchedule(offline.ctx, offline.input, take, buffer, offline.duration);
	}

	var rendered = await offline.ctx.startRendering();
	var wav = studioBufferToWav(rendered);

	var form = new FormData();
	form.append('uuid', uuid);
	form.append('name', trackName);
	form.append('format', format);
	form.append('bitrate', String(bitrate));
	form.append('master', includeMaster ? '1' : '0');
	form.append('audio', wav, trackName + '.wav');

	var response = await fetch('/manager/studio/export', { method: 'POST', body: form });
	var answer = null;
	try { answer = await response.json(); }
	catch (e) { answer = null; }
	if (!response.ok || !answer || answer.ok !== 1) {
		throw new Error((answer && answer.error) || ('the server answered ' + (response.status || '?')));
	}
	return answer;
}

// Render every track, one at a time, and attach each file to the song. The
// state line names the track and its place in the queue; the last line says how
// many files were attached, or carries the server's own sentence on a failure.
async function studioExportTracks() {
	if (studioExportRunning) { return; }
	studioExportRunning = true;
	try {
		var song = $('#studio');
		var uuid = song.attr('uuid');
		var name = song.attr('name');
		if (!uuid || !name) {
			studioExportState(studioExportText('Save the song before exporting its tracks.'));
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

		var attached = 0;
		var failures = [];
		for (var i = 0; i < channels.length; i++) {
			var entry = channels[i];
			var trackName = studioExportTrackName(entry.channel);
			studioExportState(trackName + ' (' + (i + 1) + ' of ' + channels.length + ')\u2026');
			try {
				await studioExportOne(entry, uuid, trackName, format, bitrate, includeMaster);
				attached++;
			}
			catch (error) {
				failures.push(trackName + ': ' + ((error && error.message) ? error.message : studioExportText('export failed')));
			}
		}

		if (failures.length) {
			studioExportState(attached + ' ' + studioExportText('of ' + channels.length + ' tracks attached.') + ' ' + failures.join('; '));
		}
		else {
			studioExportState(attached + ' ' + studioExportText(attached === 1 ? 'track attached.' : 'tracks attached.'));
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
