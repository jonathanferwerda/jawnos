# tests-for: public/js/manager/studio/12_export.js public/js/manager/studio/14_audio_file.js lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm templates/studio/markup.html.ep t/351-studio-export.t
# covers:    Studio's track exporter: the Configure controls, the route row and
#            its action, the three formats and the bit-rate clamp, the
#            output-chain and master render (played out in node against the
#            real client file), the WAV upload, the appointment `file` record
#            typed audio and named after the track, and ffmpeg's list argv.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

# FindBin, not RepoSource or Probe: the pre-push guard materialises a new test
# into a scratch directory, so nothing here may depend on the working directory.
my $root = "$FindBin::Bin/..";

my $markup = read_file("$root/templates/studio/markup.html.ep");
my $export = read_file("$root/public/js/manager/studio/12_export.js");
my $wav    = read_file("$root/public/js/manager/studio/14_audio_file.js");
my $code   = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");

# --- the Configure controls --------------------------------------------------
like($markup, qr/id="studio_export_format"/, 'the export format picker is in Configure');
for my $format (qw(wav mp3 flac)) {
	like($markup, qr/<option value="\Q$format\E"/, "the format picker offers $format");
}
like($markup, qr/id="studio_export_bitrate"/, 'the export bit rate picker is in Configure');
for my $rate (qw(128 192 256 320)) {
	like($markup, qr/<option value="\Q$rate\E"/, "the bit rate picker offers $rate");
}
like($markup, qr/type="checkbox" id="studio_export_master"/,
	'the mastering-rack switch is a checkbox');
like($markup, qr/id="studio_export_tracks"/, 'the Export tracks button is in Configure');
like($markup, qr/id="studio_export_state"[^>]*aria-live="polite"/,
	'the export status is a live region');

# --- the route is registered and its action exists ---------------------------
my $route_text = join '', map { read_file($_) } sort glob("$root/lib/JawnOS/Routes/*.pm");
like(
	$route_text,
	qr/\[\s*44032\s*,\s*'post'\s*,\s*'\/manager\/studio\/export'\s*,\s*'action_44032'\s*\]/,
	'POST /manager/studio/export is registered with its action'
);

require "$root/lib/JawnOS/Controller/manager_misc9.pm";
ok(Manager->can('action_44032'), 'the controller defines action_44032');
ok(Manager->can('studio_export_command'), 'the encoder command has its own helper');
ok(Manager->can('studio_export_path'), 'the destination path has its own helper');
ok(Manager->can('studio_export_append'), 'the appointment-file record has its own helper');

# --- format and bit rate -----------------------------------------------------
is(Manager::studio_export_format('mp3'), 'mp3', 'mp3 is a format');
is(Manager::studio_export_format(' FLAC '), 'flac', 'the format is trimmed and lowercased');
is(Manager::studio_export_format('ogg'), undef, 'a word outside wav/mp3/flac is refused');
ok(!defined Manager::studio_export_format(undef), 'a missing format is refused');

is(Manager::studio_export_bitrate('128'), 128, 'a chosen bit rate is kept');
is(Manager::studio_export_bitrate('64'), 64, 'the low edge is kept');
is(Manager::studio_export_bitrate('10'), 64, 'a bit rate below 64 is clamped');
is(Manager::studio_export_bitrate('999'), 320, 'a bit rate above 320 is clamped');
is(Manager::studio_export_bitrate('192.4'), 192, 'a fractional bit rate is rounded');
is(Manager::studio_export_bitrate('fast'), 192, 'a malformed bit rate falls back to 192');
is(Manager::studio_export_bitrate(undef), 192, 'a missing bit rate falls back to 192');

# --- the encoder command is a list, never a shell string ---------------------
my @mp3 = Manager::studio_export_command('/tmp/in file.wav', '/tmp/out.mp3', 'mp3', 192);
is($mp3[0], 'ffmpeg', 'the encoder is ffmpeg');
ok(grep { $_ eq '-nostdin' } @mp3, 'the encoder never reads stdin');
is($mp3[-1], '/tmp/out.mp3', 'the output path is its own argv entry and comes last');

my ($in_at) = grep { $mp3[$_] eq '-i' } 0 .. $#mp3;
is($mp3[$in_at + 1], '/tmp/in file.wav', 'the input path is the separate -i argument');
my ($bitrate_at) = grep { $mp3[$_] eq '-b:a' } 0 .. $#mp3;
is($mp3[$bitrate_at + 1], '192k', 'mp3 carries the chosen bit rate');
ok((grep { $_ eq 'libmp3lame' } @mp3), 'mp3 is libmp3lame');

ok(!(grep { defined $_ && m{[;&|`\$\<\>]} } @mp3),
	'no command element carries a shell operator');
my @spaced = Manager::studio_export_command('/tmp/in file.wav', '/tmp/out file.mp3', 'mp3', 128);
is($spaced[-1], '/tmp/out file.mp3',
	'a space in a path stays one argv entry, not two commands');
ok(!(grep { defined $_ && /(?:^|\s)(?:sh|bash)\s+-c/ } @mp3),
	'the command never opens a shell');
unlike($code, qr/\bsystem\s*\(\s*"|`\s*ffmpeg|ffmpeg[^']*&/,
	'the controller builds no shell command string');

my @wav = Manager::studio_export_command('/tmp/in.wav', '/tmp/out.wav', 'wav', 320);
ok((grep { $_ eq 'pcm_s16le' } @wav), 'wav is plain PCM');
ok(!(grep { $_ eq '-b:a' } @wav), 'wav ignores the bit rate');

my @flac = Manager::studio_export_command('/tmp/in.wav', '/tmp/out.flac', 'flac', 256);
ok((grep { $_ eq 'flac' } @flac), 'flac names its codec');
my ($flac_at) = grep { $flac[$_] eq '-b:a' } 0 .. $#flac;
is($flac[$flac_at + 1], '256k', 'flac carries the chosen bit rate');

# --- the file name stays one component under the studio folder ---------------
my $dir = tempdir(CLEANUP => 1);
my $first = Manager::studio_export_path($dir, 'Bass', 'mp3');
like($first, qr/\Q$dir\E\/Bass\.mp3$/, 'the track name becomes the file name');
open(my $touch, '>', $first) or die "$first: $!";
close $touch;
my $second = Manager::studio_export_path($dir, 'Bass', 'mp3');
like($second, qr/Bass-2\.mp3$/, 'a second export of the same track gets a suffix');

my $spaced = Manager::studio_export_path($dir, 'two words', 'wav');
like($spaced, qr/two%20words\.wav$/, 'a space is percent-encoded, not left as a separator');

my $evil = Manager::studio_export_path($dir, '../../../etc/passwd', 'wav');
like($evil, qr/^\Q$dir\E\//, 'a traversal attempt still lands under the studio folder');
unlike($evil, qr{\.\./}, 'no slash survives the name');

my $empty = Manager::studio_export_path($dir, '', 'wav');
like($empty, qr/Track\.wav$/, 'a nameless track is still a file');

# --- the appointment file record --------------------------------------------
my $files = [];
Manager::studio_export_append($files, '/rec/studio/Bass.mp3', 'abcdefghijklmnop');
is(scalar @{$files}, 1, 'one file record is appended');
is($files->[0]{'type'}, 'audio', 'the exported track is typed audio');
is($files->[0]{'f'}, '/rec/studio/Bass.mp3', 'the record carries the written path');
is($files->[0]{'uuid'}, 'abcdefghijklmnop', 'and its own uuid');
Manager::studio_export_append($files, '/rec/studio/Bass-2.mp3', 'qrstuvwxyzabcdef');
is(scalar @{$files}, 2, 'a second export joins the existing list');
is($files->[0]{'type'}, 'audio', 'the first record is kept');

# --- the controller wires the route to those pieces -------------------------
like($code,
	qr/db_select\('appointments', undef, \{ uuid => \$uuid, type => 'studio' \}\)/,
	'the song row is validated before the upload is stored');
like($code, qr/system\(\@command\)/, 'the encoder runs from a list');
like($code, qr/\$command\[0\] = \$encoder/, 'the resolved encoder is the one that runs');
like($code, qr/studio_export_append\(\$files, \$path/, 'the written path joins the song file list');
like($code, qr/type => 'audio'/, 'the appended record is typed audio');
like($code, qr/file => encode_json\(\$files\), server_time => &subs::rightNow\(\)/,
	'the file update stamps server_time so the encrypter sees the song');
like($code, qr/sub action_44032 \{[\s\S]*?file => encode_json\(\$files\), server_time => &subs::rightNow\(\)[\s\S]*?&subs::file_encrypter\(\{ app => 'studio' \}\)/,
	'the written file is stamped and then sealed on the studio path');
like($code, qr/studio_export_path\(\$folder, \$track, \$format\)/,
	'the track name and format name the file');
like($code, qr/subs::path_name/, 'the name becomes a path component through path_name');
like($code, qr/studio_export_ffmpeg/, 'a missing encoder is refused cleanly');

# --- the client renders through the real track ---------------------------------
like($export, qr/new OfflineAudioContext\(2,/, 'each track renders in a stereo OfflineAudioContext');
like($export, qr/studioBufferToWav\(rendered\)/, 'the rendered buffer becomes a WAV');
like($export, qr/c\.outInserts\) \|\| \[\]/, 'a song without an output chain passes through');
like($export, qr/studioMasterChain\(off\)/, 'the mastering rack is built on the offline context');
like($export, qr/studioMasterSave\(\)/, 'the rack comes from the song, not a second copy');
like($export, qr/decodeAudioData/, 'a take without a buffer is decoded from its source');
like($export, qr/indexOf\('video'\)/, 'a video encoding is skipped');
like($export, qr/fetch\('\/manager\/studio\/export'/, 'the WAV is posted to the export route');
like($export, qr/form\.append\('audio', wav, trackName \+ '\.wav'\)/,
	'the upload is named after the track');
like($export, qr/#studio_export_state/, 'progress is written to the live status');
like($export, qr/\(i \+ 1\) \+ ' of '/, 'the status names the track and its place in the queue');

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to render the export path', 1 unless $node && -x $node;

	my $harness = <<'NODE';
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');
const results = [];
function check(ok, name, detail) {
	results.push({ ok: !!ok, name: name, detail: detail === undefined ? '' : String(detail) });
}

// --- a jQuery-lite over a fake Configure ------------------------------------
const ui = {
	'#studio': { uuid: 'song-1', name: 'Song One' },
	'#studio_export_format': 'mp3',
	'#studio_export_bitrate': '192',
	'#studio_export_master': false,
	'#studio_export_state': ''
};
const cache = {};
const stateTexts = [];
let connections = [];
const calls = {
	contexts: [], inserts: [], sources: [], wavs: [], forms: [], fetches: [],
	masterBuilt: 0, lastMaster: null
};

function element(sel) {
	if (cache[sel]) { return cache[sel]; }
	const el = {
		length: 1,
		_value: ui[sel],
		attr: function (name) {
			const song = ui['#studio'] || {};
			return song[name];
		},
		val: function (value) {
			if (value !== undefined) { this._value = value; return this; }
			return this._value === undefined ? '' : this._value;
		},
		prop: function (name) {
			if (sel === '#studio_export_master') { return !!ui['#studio_export_master']; }
			return undefined;
		},
		is: function () { return !!ui['#studio_export_master']; },
		text: function (text) {
			if (text !== undefined) {
				this._value = String(text);
				stateTexts.push(this._value);
				return this;
			}
			return this._value === undefined ? '' : this._value;
		}
	};
	cache[sel] = el;
	return el;
}

function $(sel) {
	if (typeof sel !== 'string') {
		return { on: function () { return this; } };
	}
	return element(sel);
}
$.each = function (obj, fn) {
	Object.keys(obj || {}).forEach(function (key) { fn(key, obj[key]); });
};

function node(kind) {
	return {
		kind: kind,
		connect: function (target) {
			connections.push({ from: this, to: target });
			return target;
		}
	};
}

function OfflineAudioContext(channels, frames, rate) {
	this.numberOfChannels = channels;
	this.length = frames;
	this.sampleRate = rate;
	this.destination = node('destination');
	this.gains = [];
	this.panners = [];
	calls.contexts.push(this);
}
OfflineAudioContext.prototype.createGain = function () {
	const gain = node('gain');
	gain.gain = { value: 1 };
	this.gains.push(gain);
	return gain;
};
OfflineAudioContext.prototype.createStereoPanner = function () {
	const pan = node('pan');
	pan.pan = { value: 0 };
	this.panners.push(pan);
	return pan;
};
OfflineAudioContext.prototype.createBufferSource = function () {
	const ctx = this;
	const source = node('source');
	source.start = function (when, offset, duration) {
		calls.sources.push({ ctx: ctx, when: when, offset: offset, duration: duration });
	};
	return source;
};
OfflineAudioContext.prototype.decodeAudioData = async function () {
	return { duration: 1, decoded: true };
};
OfflineAudioContext.prototype.startRendering = async function () {
	return { rendered: true, from: this };
};

function studioInsert(off, name) {
	const ins = {
		name: name,
		input: node('insert-in'),
		output: node('insert-out'),
		values: {},
		bypassed: false,
		set: function (control, value) { this.values[control] = value; },
		setBypass: function (on) { this.bypassed = !!on; }
	};
	calls.inserts.push(ins);
	return ins;
}

function masterInsert(name) {
	return {
		name: name,
		input: node('master-in'),
		output: node('master-out'),
		values: {},
		bypassed: true,
		_set: false,
		set: function (control, value) { this.values[control] = value; },
		setBypass: function (on) { this.bypassed = !!on; this._set = true; }
	};
}

function studioMasterChain(off) {
	calls.masterBuilt++;
	const comp = masterInsert('master_comp');
	const eq = masterInsert('master_eq');
	calls.lastMaster = {
		input: node('master-input'),
		output: node('master-output'),
		inserts: [comp, eq],
		insertByName: { master_comp: comp, master_eq: eq },
		comp: comp,
		eq: eq
	};
	return calls.lastMaster;
}

function studioMasterSave() {
	return [
		{ name: 'master_comp', on: true, controls: { thresh: '-12' } },
		{ name: 'master_eq', on: false, controls: { low: '3' } }
	];
}

function studioBufferToWav(buffer) {
	calls.wavs.push(buffer);
	return { wav: true, type: 'audio/wav' };
}

function studioVolumeFraction(value) {
	const n = parseFloat(value);
	if (isNaN(n)) { return 1; }
	return Math.max(0, Math.min(1, n > 1 ? n / 100 : n));
}

function studioKnobNumber(value, fallback) {
	const n = parseFloat(value);
	return isNaN(n) ? fallback : n;
}

function studioContext() {
	return { sampleRate: 48000 };
}

function FormData() { this.entries = []; }
FormData.prototype.append = function (key, value, filename) {
	this.entries.push([key, value, filename]);
};

async function fetch(url, options) {
	calls.fetches.push(url);
	if (options && options.method === 'POST') {
		const fields = {};
		options.body.entries.forEach(function (entry) {
			fields[entry[0]] = entry[1];
			if (entry[2] !== undefined) { fields[entry[0] + '__filename'] = entry[2]; }
		});
		calls.forms.push(fields);
		if (ui.__serverError) {
			const sentence = ui.__serverError;
			return { ok: false, status: 500, json: async function () { return { ok: 0, error: sentence }; } };
		}
		return { ok: true, status: 200, json: async function () {
			return { ok: 1, file: '/out', name: 'x', format: 'mp3' };
		} };
	}
	return { ok: true, status: 200, arrayBuffer: async function () { return new ArrayBuffer(8); } };
}

const sandbox = {
	document: {},
	mixer: {},
	OfflineAudioContext: OfflineAudioContext,
	FormData: FormData,
	fetch: fetch,
	studioContext: studioContext,
	studioInsert: studioInsert,
	studioMasterChain: studioMasterChain,
	studioMasterSave: studioMasterSave,
	studioBufferToWav: studioBufferToWav,
	studioVolumeFraction: studioVolumeFraction,
	studioKnobNumber: studioKnobNumber,
	'$': $
};

vm.runInNewContext(
	source + '\n;globalThis.__studioExport = {'
		+ ' tracks: studioExportTracks,'
		+ ' channels: studioExportChannels,'
		+ ' duration: studioExportDuration,'
		+ ' schedule: studioExportSchedule,'
		+ ' format: studioExportFormat,'
		+ ' bitrate: studioExportBitrate'
		+ ' };',
	sandbox,
	{ filename: '12_export.js' }
);
const api = sandbox.__studioExport;

function reset() {
	Object.keys(cache).forEach(function (key) { delete cache[key]; });
	stateTexts.length = 0;
	connections = [];
	calls.contexts.length = 0;
	calls.inserts.length = 0;
	calls.sources.length = 0;
	calls.wavs.length = 0;
	calls.forms.length = 0;
	calls.fetches.length = 0;
	calls.masterBuilt = 0;
	calls.lastMaster = null;
	ui.__serverError = null;
	ui['#studio_export_state'] = '';
}

function buffer(duration) { return { duration: duration }; }

function scenarioOne() {
	ui['#studio'] = { uuid: 'song-1', name: 'Song One' };
	ui['#studio_export_format'] = 'mp3';
	ui['#studio_export_bitrate'] = '192';
	ui['#studio_export_master'] = false;
	ui['#studio_export_state'] = '';
	ui['.studio_track_name[channel="1"]'] = 'Bass';
	ui['.studio_track_name[channel="2"]'] = 'Drums';
	ui['.channel_volume[channel="1"]'] = '50';
	ui['.channel_volume[channel="2"]'] = '100';
	ui['.knob_control[channel="1"][control="pan"]'] = '50';
	ui['.knob_control[channel="2"][control="pan"]'] = '100';
	reset();
	sandbox.mixer = {
		time: { duration: 0 },
		'1': {
			media: { out: [
				{ startTime: 0, duration: 2, offset: 0.5, buffer: buffer(5) },
				{ startTime: 2, duration: 2, offset: 0, buffer: buffer(2) },
				{ startTime: 0, duration: 9, status: 'recording', buffer: buffer(9) },
				{ startTime: 0, duration: 9, encoding: 'video/webm', buffer: buffer(9) }
			] },
			outInserts: [ { name: 'reverb', values: { mix: '30', model: '2' }, bypassed: false } ]
		},
		'2': { media: { out: [ { startTime: 0, duration: 1, src: '/take-b.wav' } ] } }
	};
}

function scenarioTwo() {
	ui['#studio'] = { uuid: 'song-1', name: 'Song One' };
	ui['#studio_export_master'] = true;
	ui['.studio_track_name[channel="1"]'] = 'Bass';
	ui['.channel_volume[channel="1"]'] = '100';
	ui['.knob_control[channel="1"][control="pan"]'] = '50';
	reset();
	sandbox.mixer = {
		time: { duration: 0 },
		'1': { media: { out: [ { startTime: 0, duration: 1, buffer: buffer(1) } ] } }
	};
}

(async function () {
	// --- one render per track, through the track's own chain ----------------
	scenarioOne();
	await api.tracks();

	check(calls.contexts.length === 2, 'one OfflineAudioContext per track with takes', calls.contexts.length);
	check(calls.contexts[0] && calls.contexts[0].numberOfChannels === 2, 'the render is stereo');
	check(calls.contexts[0] && calls.contexts[0].sampleRate === 48000, 'the live sample rate is used');
	check(calls.contexts[0] && calls.contexts[0].length === 192000,
		'the render length is the last take end (4s at 48k)', calls.contexts[0] && calls.contexts[0].length);
	check(calls.contexts[1] && calls.contexts[1].length === 48000,
		'a short track renders only its own length', calls.contexts[1] && calls.contexts[1].length);

	check(calls.inserts.length === 1, 'the output chain is built once for the one track that has one');
	const ins = calls.inserts[0];
	check(ins && ins.name === 'reverb', 'the chain insert is the song\'s effect');
	check(ins && ins.values.mix === '30' && ins.values.model === '2', 'every stored value is applied');
	check(ins && ins.bypassed === false, 'the stored footswitch is applied');
	check(connections.some(function (c) { return ins && c.to === ins.input; }),
		'the chain feeds the insert');
	check(connections.some(function (c) { return ins && c.from === ins.output && c.to.kind === 'gain'; }),
		'the insert output reaches the fader');
	check(calls.contexts[1] && calls.contexts[1].gains.length === 2,
		'a track without outInserts is a pass-through, not a broken graph');

	check(calls.contexts[0].gains[1].gain.value === 0.5, 'the channel fader is applied as a fraction');
	check(calls.contexts[0].panners[0].pan.value === 0, 'pan 50 is centre');
	check(calls.contexts[1].panners[0].pan.value === 1, 'pan 100 is hard right');

	const ctx0 = calls.contexts[0];
	const started = calls.sources.filter(function (s) { return s.ctx === ctx0; });
	check(started.length === 2, 'a recording and a video take are not scheduled', started.length);
	check(started[0] && started[0].when === 0 && started[0].offset === 0.5 && started[0].duration === 2,
		'a take plays at its song position and its own offset');
	check(started[1] && started[1].when === 2 && started[1].offset === 0 && started[1].duration === 2,
		'the next take keeps its position');
	check(calls.fetches.indexOf('/take-b.wav') !== -1, 'a take without a buffer is fetched');
	check(calls.sources.filter(function (s) { return s.ctx === calls.contexts[1]; }).length === 1,
		'the decoded take is scheduled');

	check(calls.wavs.length === 2, 'each track is encoded as a WAV', calls.wavs.length);
	check(calls.wavs[0] && calls.wavs[0].rendered === true, 'the WAV is made from the rendered buffer');

	check(calls.forms.length === 2, 'one upload per track', calls.forms.length);
	const form = calls.forms[0] || {};
	check(form.uuid === 'song-1', 'the upload names the saved song');
	check(form.name === 'Bass', 'the upload is named after the track');
	check(form.format === 'mp3', 'the chosen format is sent');
	check(form.bitrate === '192', 'the chosen bit rate is sent');
	check(form.master === '0', 'the master switch is sent as off');
	check(form.audio__filename === 'Bass.wav', 'the WAV upload is named after the track');
	check((calls.forms[1] || {}).name === 'Drums', 'the second track keeps its own name');
	check((calls.forms[1] || {}).audio__filename === 'Drums.wav', 'and its own file name');

	check(stateTexts[0] === 'Bass (1 of 2)\u2026', 'progress names the track and its place', stateTexts[0]);
	check(stateTexts[1] === 'Drums (2 of 2)\u2026', 'the next track takes the next place', stateTexts[1]);
	check(stateTexts[stateTexts.length - 1] === '2 tracks attached.',
		'the last line says how many files were attached', stateTexts[stateTexts.length - 1]);

	// --- the mastering rack --------------------------------------------------
	scenarioTwo();
	await api.tracks();

	check(calls.masterBuilt === 1, 'the master rack is built on the offline context');
	const master = calls.lastMaster || {};
	check(master.comp && master.comp.values.thresh === '-12', 'the rack\'s controls are restored');
	check(master.comp && master.comp._set && master.comp.bypassed === false, 'an effect that is on stays on');
	check(master.eq && master.eq.bypassed === true, 'an effect that is off stays bypassed');
	check(connections.some(function (c) { return c.from.kind === 'pan' && c.to === master.input; }),
		'the channel output enters the master rack');
	check(connections.some(function (c) { return c.from === master.output && c.to.kind === 'destination'; }),
		'the master rack reaches the destination');
	check((calls.forms[0] || {}).master === '1', 'the master switch is sent as on');

	// --- an unsaved song cannot be filed ------------------------------------
	scenarioOne();
	ui['#studio'] = { uuid: '', name: '' };
	reset();
	await api.tracks();
	check(calls.contexts.length === 0, 'an unsaved song renders nothing', calls.contexts.length);
	check(stateTexts[stateTexts.length - 1] === 'Save the song before exporting its tracks.',
		'the status says the song must be saved first', stateTexts[stateTexts.length - 1]);

	// --- a server refusal is shown, not hidden ------------------------------
	scenarioTwo();
	ui['#studio_export_master'] = false;
	reset();
	ui.__serverError = 'the audio encoder is not installed';
	await api.tracks();
	const refused = stateTexts[stateTexts.length - 1] || '';
	check(/^0 of 1 tracks attached\./.test(refused), 'a failure still reports the count', refused);
	check(refused.indexOf('the audio encoder is not installed') !== -1, 'the server error is shown', refused);

	// --- a looping take wraps to the song end ------------------------------
	reset();
	const loopCtx = new OfflineAudioContext(2, 100, 44100);
	api.schedule(loopCtx, node('dest'),
		{ startTime: 0, duration: 1, loop: true, offset: 0.25 }, buffer(2), 3.5);
	const wraps = calls.sources;
	check(wraps.length === 4, 'a one-second loop fills three and a half seconds', wraps.length);
	check(wraps.map(function (s) { return s.when; }).join(',') === '0,1,2,3',
		'the loop wraps on its own length', wraps.map(function (s) { return s.when; }).join(','));
	check(wraps.every(function (s) { return s.offset === 0.25; }),
		'each wrap returns to the take in-point');
	check(wraps[wraps.length - 1].duration === 0.5, 'the last pass is cut at the song end');

	// --- the length and the pickers ----------------------------------------
	check(api.duration([ { startTime: 0, duration: 2 }, { startTime: 5, duration: 1 } ], 4) === 6,
		'the last take end wins when it is later than the song');
	check(api.duration([], 0) === 0.1, 'an empty render is still one tenth of a second');

	ui['#studio_export_format'] = 'FLAC';
	reset();
	check(api.format() === 'flac', 'the format is read case-insensitively');
	ui['#studio_export_format'] = 'ogg';
	reset();
	check(api.format() === 'wav', 'an unknown format falls back to wav');

	ui['#studio_export_bitrate'] = '500';
	reset();
	check(api.bitrate() === 320, 'the bit rate is clamped at 320');
	ui['#studio_export_bitrate'] = '1';
	reset();
	check(api.bitrate() === 64, 'the bit rate is clamped at 64');
	ui['#studio_export_bitrate'] = 'fast';
	reset();
	check(api.bitrate() === 192, 'a malformed bit rate falls back to 192');

	const failed = results.filter(function (row) { return !row.ok; });
	results.forEach(function (row) {
		console.log((row.ok ? 'PASS ' : 'FAIL ') + row.name + (row.ok ? '' : ' :: ' + row.detail));
	});
	if (!results.length) { console.log('FAIL the harness ran no checks'); }
	process.exit(0);
})().catch(function (error) {
	console.log('FAIL the harness ran :: ' + (error && error.stack ? error.stack : error));
	process.exit(0);
});
NODE

	my $dir = tempdir(CLEANUP => 1);
	my $harness_path = "$dir/export-harness.js";
	write_file($harness_path, $harness);

	open(my $pipe, '-|', $node, $harness_path, "$root/public/js/manager/studio/12_export.js")
		or die "node: $!";
	my @lines = <$pipe>;
	close $pipe;

	my @checks = grep { /^(?:PASS|FAIL) / } @lines;
	ok(scalar(@checks) > 0, 'the node harness reported its checks')
		or diag(join '', @lines);
	for my $line (@checks) {
		chomp $line;
		my ($verdict, $name, $detail) = $line =~ /^(PASS|FAIL) (.+?)(?: :: (.*))?\z/;
		ok(($verdict // '') eq 'PASS', $name // $line) or diag($detail // '');
	}
}

done_testing();
