var mao = {};
var misses = {};
var music_muted = false;
// Play/pause glyphs follow the selected icon set; the music window stashes the
// resolved paths on #play_logo (see apps/music/music.html.ep).
function jawnosPlayIcon() { var s = $('#play_logo').attr('play_icon'); return s || '/icons/play.jpg'; }
function jawnosPauseIcon() { var s = $('#play_logo').attr('pause_icon'); return s || '/icons/pause.jpg'; }
// Play, and tell the truth if the browser refuses it (an unmuted autoplay with no
// gesture): leave the button on play rather than showing a track that is not
// running. WebKit in particular refuses unmuted autoplay without a gesture.
function musicPlay() {
	if (!tree || !tree.sound) { return null; }
	var p = null;
	try { p = tree.sound.play(); } catch (e) { return null; }
	if (p && p.catch) {
		p.catch(function () {
			if (tree && tree.sound) { tree.sound.state = 0; }
			$('#play_logo').attr('src', jawnosPlayIcon());
		});
	}
	return p;
}

// The local element is this machine's own output: audible whenever the 'me'
// output is on (which is also the default when the setting has no 'me' key at
// all), silent when it is explicitly off. The volume is deliberately dropped
// for the audio-autoplay handshake and for each track change, so every path
// that starts or resumes playback has to restore it through here - the one that
// forgot played the track muted (tapping a paused picture, or re-opening the
// app on a track that was already loaded).
function musicLocalVolume() {
	if (music_muted || mao['me'] == 'off') { return 0; }
	return master_volume;
}
// The local output's L/centre/R choice. A stereo splitter and merger make the
// silent side truly silent, which a pan would not: a pan at the hard left still
// feeds the right channel some of the left one.
function musicLocalChannelApply() {
	if (!musicVisual || !musicVisual.localLeft || !musicVisual.localRight) { return; }
	var channel = musicOutputChannel(mao['me']);
	var left = (channel == 'right') ? 0 : 1;
	var right = (channel == 'left') ? 0 : 1;
	try { musicVisual.localLeft.gain.value = left; } catch (e) {}
	try { musicVisual.localRight.gain.value = right; } catch (e) {}
}
// The remote stream follows the sender's own volume and mute, but not the
// 'me' output choice: turning the local speaker off must leave the other room
// playing.
function musicRemoteVolume() {
	if (music_muted) { return 0; }
	// With a system mixer wired the app level lives in musicSystemLevel and the
	// graph stays at full gain; the remote must hear that level too, not 1.
	return musicSystemWired ? musicSystemLevel : master_volume;
}
var musicGraphTrying = false;
function musicVolumeApply() {
	if (!tree || !tree.sound) { return; }
	musicLocalChannelApply();
	// Silence the local output with a gain, not with a 0 volume on the element:
	// WebKit carries the element's volume onto its Pulse stream and remembers it
	// for the role, so a track played with `me` off came back muted (or at 1%)
	// on a later play. Build the graph when it can carry the zero.
	if (!musicGraphTrying && musicLocalVolume() <= 0
		&& !(musicVisual && musicVisual.localGain && musicVisual.el === tree.sound)) {
		musicGraphTrying = true;
		try { musicAudioGraph(); } catch (e) {}
		musicGraphTrying = false;
	}
	// Once the shared graph actually carries this element, the element is a
	// pass-through and the local gain is the level. That split is what lets the
	// remote tap be taken after its own remote gain (sender volume, not 'me'
	// off), and it keeps WebKit from remembering a muted/low element as the
	// volume for every later track. Before the source is connected (a parked
	// graph, a page with no gesture yet) the element itself has to carry it.
	if (musicVisual && musicVisual.localGain && musicVisual.el === tree.sound) {
		tree.sound.volume = 1;
		tree.sound.muted = false;
		try { musicVisual.localGain.gain.value = musicLocalVolume(); } catch (e) {}
		try { if (musicVisual.remoteGain) { musicVisual.remoteGain.gain.value = musicRemoteVolume(); } } catch (e) {}
	}
	else {
		tree.sound.volume = musicLocalVolume();
		// The element's own mute is the same switch as the mute button. Every resume
		// path runs through here, so this is also where the autoplay handshake's
		// muted element is lifted: a restore starts muted because only a muted
		// element may autoplay, and leaving that on made a resume (the picture, or a
		// blocked autoplay on open) play silently.
		tree.sound.muted = music_muted;
	}
	// the ahead chain carries the remote's level when it is the tap's source
	try { if (musicAhead.chain) { musicAhead.chain.out.gain.value = musicRemoteVolume(); } } catch (e) {}
}

// ---- the remote audio stream ------------------------------------------------
//
// The remote outputs used to receive a whole file and start `play` at a guessed
// offset. They now get the sound the player is actually making, in 20 ms chunks:
// an AudioWorklet taps the shared graph just before the local gain, the chunks
// ride a websocket to this machine's manager, and the manager forwards them to
// each enabled remote, where `pacat` writes them to PulseAudio. Every remote is
// therefore sample-locked to every other one. A remote hears what it is sent a
// measured moment late; for a video, the ahead tap sends the sound that much
// early so the remote's own buffer spends the lead (see musicAhead).
var musicStream = {
	ws: null, active: false, paused: false, ready: {}, failed: {}, latency: 0, latencies: {},
	file: '', type: '', reconnect: 0, attached: false, gap: 0, codec: 'pcm',
	retry: {}, retryTimers: {}, reportTimer: 0, blackTimer: 0
};
var musicStreamTap = { node: null, sink: null, loading: null, ready: false };
var musicOpus = { recorder: null, dest: null, chain: Promise.resolve(), active: false, gen: 0, source: '' };
var music_stream_codec = 'pcm';
// Counters for the sync report. They ride the same websocket as the audio, so
// a stream that is failing tells the manager what it dropped and why.
var musicSyncStats = { received: 0, stale: 0, sockdrop: 0, offline: 0, paused: 0, sent: 0, sentBytes: 0 };
var musicVideoStats = { waits: 0, stalled_ms: 0, black_runs: 0, black_ms: 0, black_max_ms: 0,
	in_black: 0, black_at: 0, waitAt: 0, canvas: null };

function musicStreamSupported() {
	var Ctor = window.AudioContext || window.webkitAudioContext;
	return !!(Ctor && location.protocol == 'https:' && (window.AudioWorkletNode || window.MediaRecorder));
}

// An output is on for any of its three states. 'on' is the older spelling of
// stereo and is kept so rows written before the L/R controls still play.
function musicOutputOn(value) {
	return value == 'on' || value == 'stereo' || value == 'left' || value == 'right';
}
function musicOutputChannel(value) {
	if (value == 'left' || value == 'right') { return value; }
	if (value == 'on' || value == 'stereo') { return 'stereo'; }
	return '';
}

// The output keys the configuration panel stores (a fqdn or an ip). 'me' and
// 'srv' are local outputs, not peers.
function musicStreamOutputs() {
	var outs = [];
	$.each(mao, function(k, v) {
		// a key with a dot is a peer; the loopback key is this machine's own
		// stale self row, never a speaker to send a copy of the stream to
		if (k && k != '127.0.0.1' && k.indexOf('.') >= 0 && musicOutputOn(v)) { outs.push(k); }
	});
	return outs;
}

// Which side each remote output should play. A remote that only receives one
// channel still gets the full stereo stream; its own player silences the side
// it was not given.
function musicStreamChannels() {
	var channels = {};
	$.each(musicStreamOutputs(), function(i, key) {
		channels[key] = musicOutputChannel(mao[key]) || 'stereo';
	});
	return channels;
}

function musicStreamSendJson(obj) {
	if (musicStream.ws && musicStream.ws.readyState == 1) {
		try { musicStream.ws.send(JSON.stringify(obj)); return true; } catch (e) {}
	}
	return false;
}

// Once the browser has created the playback stream for this start, ask the
// manager to lift a level PulseAudio's stream-restore may have left on it. The
// stream is a pass-through (the graph or the system mixer is the level), so it
// belongs at 100% and unmuted. A short wait lets the sink input appear first.
function musicStreamHealthPing() {
	clearTimeout(musicStream.health);
	musicStream.health = setTimeout(function() {
		// Only ask for full scale when the element is not carrying the level
		// itself; otherwise WebKit has mapped the slider onto the stream and
		// raising it here would play louder than the slider says.
		var full = (musicVisual && tree && tree.sound && musicVisual.el === tree.sound)
			|| (musicSystemWired && musicLocalVolume() > 0);
		$.ajax({
			url: '/manager/music/stream_health?full=' + (full ? '1' : '0'),
			type: 'GET',
			dataType: 'json',
			success: function(d) {
				// the sink reports the graph's real output buffer; prefer the
				// larger of that and what the context says it has
				var l = d ? parseFloat(d.latency) : NaN;
				if (isFinite(l) && l > 0) { musicVisual.graphLatency = l; }
			},
			error: function() { /* a machine without pactl keeps the browser level */ }
		});
	}, 300);
}

function musicStreamHello() {
	var song = (tree && tree.songs && tree.songs[0]) ? tree.songs[0] : {};
	return {
		type: 'hello',
		outputs: musicStreamOutputs(),
		channels: musicStreamChannels(),
		file: song.file || musicStream.file || '',
		music_data: song,
		rate: (musicVisual.ctx ? musicVisual.ctx.sampleRate : 48000) || 48000,
		channels: 2,
		seek: (tree && tree.sound ? (tree.sound.currentTime || 0) : 0),
		codec: musicStream.codec,
		timestamp: Date.now()
	};
}

function musicStreamTapActive(on, reset) {
	if (!musicStreamTap.node) { return; }
	try { musicStreamTap.node.port.postMessage({ active: !!on, reset: !!reset }); } catch (e) {}
}

// Build (once per page) the worklet tap. It hangs off the limiter in parallel
// with the local gain, so the remote gets full-level, normalised audio while
// this machine can still be muted; its own output is routed through a zero gain
// so the graph pulls it without making a second sound.
function musicStreamTapAttach() {
	if (musicStreamTap.ready) { return Promise.resolve(true); }
	if (musicStreamTap.loading) { return musicStreamTap.loading; }
	musicStreamTap.loading = new Promise(function(resolve) {
		var graph = null;
		try { graph = musicAudioGraph(); } catch (e) {}
		var ctx = musicVisual.ctx;
		if (!graph || !ctx || !ctx.audioWorklet || !ctx.audioWorklet.addModule) {
			musicStreamTap.loading = null;
			resolve(false);
			return;
		}
		ctx.audioWorklet.addModule('/js/music_stream_worklet.js').then(function() {
			try {
				var node = new AudioWorkletNode(ctx, 'music-stream-tap', {
					numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [2]
				});
				var sink = ctx.createGain();
				sink.gain.value = 0;
				node.connect(sink);
				sink.connect(ctx.destination);
				musicStreamTapSource(musicAhead.ready ? 'ahead' : 'local');
				node.port.onmessage = function(e) {
					if (!musicStream.active) { return; }
					var d = e.data || {};
					var pcm = d.pcm;
					if (!pcm) { return; }
					musicSyncStats.received++;
					// A busy main thread (a high-quality video decoding) lets the
					// worklet's queue grow; sending it afterwards would put a second
					// of audio into pacat and leave the remote a second behind. Drop
					// the stale frames and tell the remote to drop its buffer once.
					var age = musicVisual.ctx ? ((musicVisual.ctx.currentTime - (d.t || 0)) * 1000) : 0;
					if (age > 150) {
						musicSyncStats.stale++;
						if (!musicStream.gap) {
							musicStream.gap = 1;
							if (music_stream_codec == 'pcm') { musicStreamSendJson({ type: 'control', action: 'flush' }); }
						}
						return;
					}
					if (musicStream.gap && age < 60) { musicStream.gap = 0; }
					if (musicStream.paused) { musicSyncStats.paused++; return; }
					if (musicStream.ws && musicStream.ws.readyState == 1) {
						if (musicStream.ws.bufferedAmount < 32768) {
							try { musicStream.ws.send(pcm.buffer); } catch (err) { musicSyncStats.sockdrop++; return; }
							musicSyncStats.sent++;
							musicSyncStats.sentBytes += pcm.byteLength || 0;
						}
						else { musicSyncStats.sockdrop++; }
					}
					else { musicSyncStats.offline++; }
				};
				musicStreamTap.node = node;
				musicStreamTap.sink = sink;
				musicStreamTap.ready = true;
				musicStreamTap.loading = null;
				resolve(true);
			}
			catch (e) { musicStreamTap.loading = null; resolve(false); }
		}).catch(function() { musicStreamTap.loading = null; resolve(false); });
	});
	return musicStreamTap.loading;
}

function musicStreamConnect() {
	if (!musicStream.active) { return; }
	if (musicStream.ws && (musicStream.ws.readyState == 0 || musicStream.ws.readyState == 1)) { return; }
	var scheme = (location.protocol == 'https:') ? 'wss://' : 'ws://';
	var ws;
	try { ws = new WebSocket(scheme + location.host + '/manager/music/stream?browser=1'); }
	catch (e) { return; }
	musicStream.ws = ws;
	ws.onopen = function() {
		musicStream.reconnect = 0;
		// a fresh connection measures a fresh pipeline; do not keep an old max.
		// Opus has its own encoder/decoder buffer, so start near its real range
		// rather than the PCM default while the pings settle.
		musicStream.latency = (musicStream.codec == 'opus') ? 300 : 0;
		musicStream.latencies = {};
		musicStream.ready = {};
		musicStream.failed = {};
		musicStreamRetryClear();
		musicStreamSendJson(musicStreamHello());
		if (musicStream.codec != 'opus') { musicStreamTapActive(true, true); }
		else {
			// do not wait forever on an unreachable output; start for the ones
			// that answered, and a later one will be marked closed
			setTimeout(function() {
				if (musicStream.ws !== ws || !musicStream.active || musicStream.codec != 'opus' || musicOpus.recorder) { return; }
				for (var k in musicStream.ready) {
					if (musicStream.ready[k]) { musicOpusRecord(); return; }
				}
			}, 2000);
		}
	};
	ws.onmessage = function(e) {
		if (typeof e.data != 'string') { return; }
		var d;
		try { d = JSON.parse(e.data); } catch (err) { return; }
		if (d.type == 'ready') {
			if (d.ok === 0) {
				musicStreamOutputLost(d.key);
			}
			else {
				musicStream.ready[d.key] = 1;
				delete musicStream.failed[d.key];
				musicStreamOutputReady(d.key);
			}
			musicStreamMaybeRecord();
		}
		else if (d.type == 'latency') {
			musicStream.ready[d.key] = 1;
			musicStream.latencies[d.key] = d.ms || 0;
			if (d.ms > musicStream.latency) { musicStream.latency = d.ms; }
			musicStreamOutputReady(d.key);
			musicAheadRetarget();
		}
		else if (d.type == 'closed' || d.type == 'error' || d.type == 'stopped') {
			// a lost output is reopened; it used to stay silent for the rest of
			// the track because only hello/outputs opens a peer connection
			musicStreamOutputLost(d.key);
			musicAheadRetarget();
			musicStreamMaybeRecord();
		}
	};
	ws.onerror = function() {};
	ws.onclose = function() {
		if (musicStream.ws === ws) { musicStream.ws = null; }
		// the next connection gets a fresh recorder and WebM header
		if (musicStream.codec == 'opus') { musicOpusStopRecorder(); }
		if (!musicStream.active || musicStream.paused) { return; }
		if (musicStream.reconnect < 3) {
			musicStream.reconnect++;
			setTimeout(function() { musicStreamConnect(); }, 1000);
		}
		else {
			musicStream.active = false;
			musicStreamTapActive(false, true);
			musicSyncWatchStop();
		}
	};
}

// A remote output that dropped is reopened instead of staying silent for the
// rest of the track. The manager only opens a peer connection on hello/outputs,
// so a fresh outputs message is what asks it to try again. Backoff keeps a
// speaker that is switched off from being hammered.
function musicStreamOutputStillOn(key) {
	return !!key && $.inArray(key, musicStreamOutputs()) >= 0;
}
function musicStreamRetryClear() {
	for (var k in musicStream.retryTimers) { clearTimeout(musicStream.retryTimers[k]); }
	musicStream.retryTimers = {};
	musicStream.retry = {};
}
function musicStreamReopen(key) {
	if (!musicStream.active || musicStream.paused) { return; }
	if (!musicStreamOutputStillOn(key)) { return; }
	musicStreamSendJson({ type: 'outputs', outputs: musicStreamOutputs(), channels: musicStreamChannels() });
}
function musicStreamOutputLost(key) {
	if (!key) { return; }
	delete musicStream.ready[key];
	delete musicStream.latencies[key];
	musicStream.failed[key] = 1;
	if (!musicStreamOutputStillOn(key)) { return; }
	var n = musicStream.retry[key] || 0;
	musicStream.retry[key] = Math.min(8, n + 1);
	// keep trying every 30 s while the stream runs: a machine that reboots or
	// wakes should come back without the listener toggling its output again
	var wait = Math.min(30000, 1000 * Math.pow(2, Math.min(n, 5)));
	clearTimeout(musicStream.retryTimers[key]);
	musicStream.retryTimers[key] = setTimeout(function() {
		delete musicStream.retryTimers[key];
		musicStreamReopen(key);
	}, wait);
}
function musicStreamOutputReady(key) {
	delete musicStream.retry[key];
	if (musicStream.retryTimers[key]) { clearTimeout(musicStream.retryTimers[key]); delete musicStream.retryTimers[key]; }
}

// ---- the sync watch ---------------------------------------------------------
// The stream reports what it sent, what it had to drop, and what the picture is
// doing. It is diagnostic only: nothing here changes playback.
function musicVideoWatch(el) {
	if (!el || el._syncWatch) { return; }
	el._syncWatch = 1;
	el.addEventListener('waiting', function() {
		if (!musicVideoStats.waitAt) { musicVideoStats.waitAt = Date.now(); }
		musicVideoStats.waits++;
		// the picture has stopped; letting the audio-only tap run on would put
		// it ahead by the length of every stall
		musicAheadPause();
	});
	var settled = function() {
		if (musicVideoStats.waitAt) {
			musicVideoStats.stalled_ms += Date.now() - musicVideoStats.waitAt;
			musicVideoStats.waitAt = 0;
		}
		// the picture is moving again; realign the ahead tap to it
		musicAheadResume();
	};
	el.addEventListener('playing', settled);
	el.addEventListener('canplay', settled);
	el.addEventListener('seeked', settled);
}
// Sample the picture twice a second. A run of near-black while the picture is
// on screen is the blackout being reported; counting it is what lets a trace
// separate a decoder stall from a dark scene.
function musicSyncBlackTick() {
	var v = tree && tree.sound;
	var now = Date.now();
	if (!v || !v.tagName || v.tagName.toLowerCase() != 'video' || v.paused || v.ended
		|| !tree.songs || !tree.songs[0] || tree.songs[0].type != 'video'
		|| v.readyState < 2 || !v.videoWidth || !v.offsetWidth || !v.offsetHeight) {
		musicVideoStats.in_black = 0;
		return;
	}
	var c = musicVideoStats.canvas;
	if (!c) { c = musicVideoStats.canvas = document.createElement('canvas'); c.width = 32; c.height = 18; }
	var g = c.getContext('2d', { willReadFrequently: true });
	var dark = false;
	try {
		g.drawImage(v, 0, 0, c.width, c.height);
		var d = g.getImageData(0, 0, c.width, c.height).data;
		var sum = 0;
		for (var i = 0; i < d.length; i += 4) { sum += d[i] + d[i + 1] + d[i + 2]; }
		dark = (sum / (d.length / 4)) < 2;
	}
	catch (e) { return; }
	if (dark) {
		if (!musicVideoStats.in_black) {
			musicVideoStats.in_black = 1;
			musicVideoStats.black_at = now;
			musicVideoStats.black_runs++;
		}
		return;
	}
	if (musicVideoStats.in_black) {
		var run = now - (musicVideoStats.black_at || now);
		musicVideoStats.black_ms += run;
		if (run > musicVideoStats.black_max_ms) { musicVideoStats.black_max_ms = run; }
		musicVideoStats.in_black = 0;
	}
}
function musicSyncReport() {
	if (!musicStream.active) { return; }
	var v = tree && tree.sound;
	var q = null;
	try { q = (v && v.getVideoPlaybackQuality) ? v.getVideoPlaybackQuality() : null; } catch (e) {}
	musicStreamSendJson({
		type: 'sync_report',
		t: Date.now(),
		codec: musicStream.codec,
		paused: musicStream.paused ? 1 : 0,
		ws: musicStream.ws ? musicStream.ws.readyState : -1,
		buffered: musicStream.ws ? (musicStream.ws.bufferedAmount || 0) : 0,
		outputs: musicStreamOutputs(),
		ready: musicStream.ready,
		failed: musicStream.failed,
		latencies: musicStream.latencies,
		retry: musicStream.retry,
		received: musicSyncStats.received,
		stale: musicSyncStats.stale,
		sockdrop: musicSyncStats.sockdrop,
		offline: musicSyncStats.offline,
		paused_frames: musicSyncStats.paused,
		sent: musicSyncStats.sent,
		sent_kb: Math.round(musicSyncStats.sentBytes / 1024),
		audio_state: (musicVisual.ctx ? musicVisual.ctx.state : ''),
		graph_ms: Math.round((musicVisual.graphLatency || 0) * 1000),
		ahead: {
			on: musicAhead.ready ? 1 : 0,
			failed: musicAhead.failed ? 1 : 0,
			lead_ms: Math.round((musicAhead.target || 0) * 1000),
			err_ms: Math.round((musicAhead.err || 0) * 1000),
			offset_ms: (music_sync_offset || 0),
			rate: musicAhead.rate || 1,
			seeks: musicAhead.seekCount || 0,
			src_ms: musicAhead.el ? Math.round((musicAhead.el.currentTime || 0) * 1000) : 0,
			el_ready: musicAhead.el ? musicAhead.el.readyState : -1,
			seeking: (musicAhead.el && musicAhead.el.seeking) ? 1 : 0,
			el_paused: (musicAhead.el && musicAhead.el.paused) ? 1 : 0,
			seekable: (musicAhead.el && musicAhead.el.seekable) ? musicAhead.el.seekable.length : 0,
			opus_src: (musicOpus.source || '')
		},
		video: v ? {
			ct: Math.round((v.currentTime || 0) * 100) / 100,
			paused: v.paused ? 1 : 0,
			seeking: v.seeking ? 1 : 0,
			ready: v.readyState,
			dropped: q ? q.droppedVideoFrames : 0,
			frames: q ? q.totalVideoFrames : 0,
			waits: musicVideoStats.waits,
			stalled_ms: musicVideoStats.stalled_ms,
			black_runs: musicVideoStats.black_runs,
			black_ms: musicVideoStats.black_ms,
			black_max_ms: musicVideoStats.black_max_ms
		} : null
	});
}
function musicSyncWatchStart() {
	if (musicStream.reportTimer) { return; }
	musicStream.reportTimer = setInterval(musicSyncReport, 2000);
	musicStream.blackTimer = setInterval(musicSyncBlackTick, 500);
	musicVideoWatch(tree && tree.sound);
}
function musicSyncWatchStop() {
	if (musicStream.reportTimer) { clearInterval(musicStream.reportTimer); musicStream.reportTimer = 0; }
	if (musicStream.blackTimer) { clearInterval(musicStream.blackTimer); musicStream.blackTimer = 0; }
	if (musicVideoStats.in_black) {
		var run = Date.now() - (musicVideoStats.black_at || Date.now());
		musicVideoStats.black_ms += run;
		if (run > musicVideoStats.black_max_ms) { musicVideoStats.black_max_ms = run; }
		musicVideoStats.in_black = 0;
	}
}

// Opus is a container stream: the first blob carries the WebM header, so the
// recorder may only start once every enabled output's ffmpeg is up. Otherwise
// the header reaches some remotes and not others, and those decoders fail on
// headerless clusters.
function musicStreamMaybeRecord() {
	if (musicStream.codec != 'opus' || musicOpus.recorder) { return; }
	var outs = musicStreamOutputs();
	for (var i = 0; i < outs.length; i++) {
		if (!musicStream.ready[outs[i]] && !musicStream.failed[outs[i]]) { return; }
	}
	var any = false;
	for (var j = 0; j < outs.length; j++) { if (musicStream.ready[outs[j]]) { any = true; break; } }
	if (any) { musicOpusRecord(); }
}

function musicStreamStart(file, seek) {
	if (!musicStreamSupported()) {
		console.warn('music: this browser cannot tap the player for remote audio');
		return false;
	}
	if (!musicStreamOutputs().length) { return false; }
	var opus = (music_stream_codec == 'opus');
	if (!opus && !window.AudioWorkletNode) { opus = true; }
	if (opus && !window.MediaRecorder) { opus = false; }
	musicStream.active = true;
	musicStream.paused = false;
	musicStream.attached = false;
	musicStream.gap = 0;
	musicStream.codec = opus ? 'opus' : 'pcm';
	musicStream.latency = opus ? 300 : 0;
	musicStream.latencies = {};
	musicStream.ready = {};
	musicStream.failed = {};
	musicStreamRetryClear();
	musicSyncStats = { received: 0, stale: 0, sockdrop: 0, offline: 0, paused: 0, sent: 0, sentBytes: 0 };
	musicVideoStats.waits = 0;
	musicVideoStats.stalled_ms = 0;
	musicVideoStats.black_runs = 0;
	musicVideoStats.black_ms = 0;
	musicVideoStats.black_max_ms = 0;
	musicVideoStats.in_black = 0;
	musicVideoStats.waitAt = 0;
	musicSyncWatchStart();
	musicStream.file = file || (tree.songs[0] ? tree.songs[0].file : '');
	musicStream.type = (tree.songs[0] && tree.songs[0].type) || '';
	var attach = opus ? Promise.resolve(musicOpusAttach()) : musicStreamTapAttach();
	attach.then(function(ok) {
		if (!musicStream.active) { return; }
		// the audio context may still be suspended on the first play; onplaying
		// calls back in once it is running
		if (!ok) { return; }
		musicStream.attached = true;
		musicStreamConnect();
		if (!opus) { musicStreamTapActive(true, true); }
		musicAheadStart();
	});
	return true;
}

// ---- Opus ---------------------------------------------------------------
// MediaRecorder produces a live WebM/Opus stream from the same limiter tap.
// It is one recorder per websocket connection: a reconnect gets a fresh
// recorder so the remote's new ffmpeg sees a WebM header first. A pause keeps
// the recorder alive and simply stops sending, so resuming needs no new header.
function musicOpusAttach() {
	if (musicOpus.active) { return true; }
	var graph = null;
	try { graph = musicAudioGraph(); } catch (e) {}
	var ctx = musicVisual.ctx;
	if (!graph || !ctx || !window.MediaRecorder || !musicVisual.limiter) { return false; }
	var dest = ctx.createMediaStreamDestination();
	musicOpus.dest = dest;
	musicOpusSource();
	musicOpus.active = true;
	return true;
}

function musicOpusRecord() {
	if (!musicOpus.dest || musicOpus.recorder) { return; }
	musicOpusStopRecorder();
	musicOpus.gen++;
	var gen = musicOpus.gen;
	var mime = '';
	try {
		if (MediaRecorder.isTypeSupported('audio/webm;codecs=opus')) { mime = 'audio/webm;codecs=opus'; }
		else if (MediaRecorder.isTypeSupported('audio/webm')) { mime = 'audio/webm'; }
	}
	catch (e) {}
	var rec;
	try {
		rec = new MediaRecorder(musicOpus.dest.stream, mime ? { mimeType: mime, audioBitsPerSecond: 128000 } : {});
	}
	catch (e) { return; }
	rec.ondataavailable = function(e) {
		if (!e.data || !e.data.size) { return; }
		if (gen !== musicOpus.gen) { return; }
		// Blob -> ArrayBuffer is async; chain it so WebM clusters stay in order
		musicOpus.chain = musicOpus.chain.then(function() {
			return e.data.arrayBuffer();
		}).then(function(buf) {
			// a stopped recorder's final blob must not land in a new stream
			if (gen !== musicOpus.gen) { return; }
			if (!musicStream.active || musicStream.paused) { return; }
			if (musicStream.ws && musicStream.ws.readyState == 1) {
				// never drop an Opus cluster: a missing one breaks the decoder
				try { musicStream.ws.send(buf); } catch (err) {}
			}
		}).catch(function() {});
	};
	try { rec.start(100); } catch (e) { return; }
	musicOpus.recorder = rec;
}

function musicOpusStopRecorder() {
	musicOpus.gen++;
	if (!musicOpus.recorder) { return; }
	try { musicOpus.recorder.stop(); } catch (e) {}
	musicOpus.recorder = null;
}

function musicOpusStop() {
	musicOpusStopRecorder();
	if (musicOpus.dest) {
		try { musicOpus.dest.disconnect(); } catch (e) {}
		musicOpus.dest = null;
	}
	musicOpus.active = false;
	musicOpus.source = '';
	musicOpus.chain = Promise.resolve();
}

// A codec or output change during Opus needs a new WebM header for every
// decoder, so the whole stream is restarted rather than patched.
function musicStreamRestart() {
	if (!musicStream.active) { return; }
	var playing = (tree.sound.state == 1);
	var file = (tree.songs[0] ? tree.songs[0].file : musicStream.file);
	var seek = tree.sound.currentTime;
	musicStreamStop();
	if (playing) { musicStreamStart(file, seek); }
}

function musicStreamStop() {
	if (musicStream.ws) {
		musicStreamSendJson({ type: 'control', action: 'stop' });
		try { musicStream.ws.close(); } catch (e) {}
		musicStream.ws = null;
	}
	musicStream.active = false;
	musicStream.paused = false;
	musicStream.reconnect = 0;
	musicStream.ready = {};
	musicStream.failed = {};
	musicStream.latency = 0;
	musicStream.latencies = {};
	musicStream.attached = false;
	musicStream.gap = 0;
	musicStreamTapActive(false, true);
	musicAheadStop();
	clearTimeout(musicAhead.retryTimer);
	musicAhead.retryTimer = 0;
	musicOpusStop();
	musicSyncWatchStop();
	musicStreamRetryClear();
}

function musicStreamControl(action, extra) {
	if (!musicStream.active) { return; }
	var d = extra || {};
	d.type = 'control';
	d.action = action;
	if (d.seek === undefined) { d.seek = tree.sound.currentTime; }
	if (!d.file) { d.file = (tree.songs[0] ? tree.songs[0].file : musicStream.file); }
	if (!d.music_data && tree.songs[0] && (action == 'track' || action == 'seek')) { d.music_data = tree.songs[0]; }
	musicStreamSendJson(d);
	if (action == 'pause') {
		musicStream.paused = true;
		musicAheadPause();
		if (musicStream.codec != 'opus') { musicStreamTapActive(false); }
	}
	if (action == 'resume') {
		musicStream.paused = false;
		if (musicStream.codec != 'opus') { musicStreamTapActive(true); }
		musicAheadResume();
	}
}

function musicStreamOutputsChanged() {
	if (!musicStream.active) { return; }
	var outs = musicStreamOutputs();
	if (!outs.length) { musicStreamStop(); return; }
	musicStreamSendJson({ type: 'outputs', outputs: outs, channels: musicStreamChannels() });
	// a fresh outputs message is also the retry path for a dropped output
	musicStreamRetryClear();
	musicAheadRetarget();
}

// ---- the ahead tap ----------------------------------------------------------
// A remote hears what it is sent L milliseconds late. Delaying the picture is
// one way to line that up; a cheaper one is to send the sound L early. A second,
// audio-only element reads the same file just ahead of the player, through its
// own copy of the processing chain, and the remote's buffer spends the lead. The
// picture is never delayed, so there is no second video decoder and no blackout.
var musicAhead = {
	el: null, source: null, chain: null, src: '', ready: false, starting: false,
	failed: false, gen: 0, timer: 0, retryTimer: 0, target: 0, err: 0,
	seekAt: 0, seekCount: 0, rate: 1, hold: false
};

// The lead to give the remote, from the measured latency of every output that
// answered. The slowest decides, as the picture delay did; the trim moves the
// remote's sound later (positive) or earlier (negative).
function musicStreamLead() {
	var max = 0;
	var outs = musicStreamOutputs();
	for (var i = 0; i < outs.length; i++) {
		var k = outs[i];
		if (!musicStream.ready[k]) { continue; }
		var ms = musicStream.latencies[k] || 0;
		if (ms > max) { max = ms; }
	}
	return Math.max(0, (max - (music_sync_offset || 0)) / 1000);
}

function musicAheadWanted() {
	return !!(musicStream.active && !musicStream.paused && musicStreamOutputs().length
		&& tree && tree.songs && tree.songs[0] && tree.songs[0].type == 'video'
		&& tree.sound && !tree.sound.paused && !tree.sound.ended);
}

// The processing chain for the ahead element. It is the same shape as this
// machine's chain, so normalization, the equalizer, the limiter and the remote
// volume all still apply; only the source is different.
function musicAheadChain() {
	var ctx = musicVisual.ctx;
	if (!ctx) { return null; }
	if (musicAhead.chain) { return musicAhead.chain; }
	var c = {
		compressor: ctx.createDynamicsCompressor(),
		leveler: ctx.createGain(),
		makeup: ctx.createGain(),
		eqFilters: [],
		eqBass: ctx.createBiquadFilter(),
		limiter: ctx.createDynamicsCompressor(),
		out: ctx.createGain(),
		sink: ctx.createGain()
	};
	c.sink.gain.value = 0;
	c.out.gain.value = musicRemoteVolume();
	var prev = c.makeup;
	for (var i = 0; i < music_eq_freqs.length; i++) {
		var f = ctx.createBiquadFilter();
		f.type = 'peaking';
		f.frequency.value = music_eq_freqs[i];
		f.Q.value = 1.1;
		f.gain.value = 0;
		prev.connect(f);
		prev = f;
		c.eqFilters.push(f);
	}
	c.eqBass.type = 'lowshelf';
	c.eqBass.frequency.value = 90;
	c.eqBass.gain.value = 0;
	prev.connect(c.eqBass);
	c.eqBass.connect(c.limiter);
	c.compressor.connect(c.leveler);
	c.leveler.connect(c.makeup);
	c.limiter.connect(c.out);
	// pull the chain even when no tap is attached yet
	c.out.connect(c.sink);
	c.sink.connect(ctx.destination);
	musicAhead.chain = c;
	musicAheadApply();
	return c;
}
function musicAheadApply() {
	var c = musicAhead.chain;
	if (!c) { return; }
	musicEqualizerApply(c);
	musicNormalizeParams(c);
	musicBaselineApply(c);
	try { c.out.gain.value = musicRemoteVolume(); } catch (e) {}
}

// Which source feeds the remote tap (PCM) or the recorder (Opus). The ahead
// chain replaces this machine's remote gain only while it is actually ready.
function musicStreamTapSource(want) {
	var node = musicStreamTap.node;
	if (!node) { return; }
	try { if (musicVisual.remoteGain) { musicVisual.remoteGain.disconnect(node); } } catch (e) {}
	try { if (musicVisual.limiter) { musicVisual.limiter.disconnect(node); } } catch (e) {}
	try { if (musicAhead.chain) { musicAhead.chain.out.disconnect(node); } } catch (e) {}
	if (want == 'ahead' && musicAhead.ready && musicAhead.chain) { musicAhead.chain.out.connect(node); return; }
	if (musicVisual.remoteGain) { musicVisual.remoteGain.connect(node); }
	else if (musicVisual.limiter) { musicVisual.limiter.connect(node); }
}
function musicOpusSource() {
	var dest = musicOpus.dest;
	if (!dest) { return; }
	try { if (musicVisual.remoteGain) { musicVisual.remoteGain.disconnect(dest); } } catch (e) {}
	try { if (musicVisual.limiter) { musicVisual.limiter.disconnect(dest); } } catch (e) {}
	try { if (musicAhead.chain) { musicAhead.chain.out.disconnect(dest); } } catch (e) {}
	if (musicAhead.ready && musicAhead.chain) { musicAhead.chain.out.connect(dest); musicOpus.source = 'ahead'; return; }
	if (musicVisual.remoteGain) { musicVisual.remoteGain.connect(dest); }
	else if (musicVisual.limiter) { musicVisual.limiter.connect(dest); }
	musicOpus.source = 'local';
}

function musicAheadStop() {
	musicAhead.gen++;
	musicAhead.ready = false;
	musicAhead.starting = false;
	musicAhead.hold = false;
	musicAhead.src = '';
	clearInterval(musicAhead.timer);
	musicAhead.timer = 0;
	if (musicAhead.el) {
		try { musicAhead.el.pause(); } catch (e) {}
		try { musicAhead.el.removeAttribute('src'); musicAhead.el.load(); } catch (e) {}
	}
	musicStreamTapSource('local');
	musicOpusSource();
}
function musicAheadForget() {
	clearTimeout(musicAhead.retryTimer);
	musicAhead.retryTimer = 0;
	musicAheadStop();
	if (musicAhead.source) { try { musicAhead.source.disconnect(); } catch (e) {} }
	if (musicAhead.chain) {
		try { musicAhead.chain.out.disconnect(); } catch (e) {}
		try { musicAhead.chain.sink.disconnect(); } catch (e) {}
	}
	if (musicAhead.el && musicAhead.el.parentNode) { musicAhead.el.parentNode.removeChild(musicAhead.el); }
	musicAhead.el = null;
	musicAhead.source = null;
	musicAhead.chain = null;
}

// Put the ahead element at the player's position plus the lead, and keep it
// there. A small error is trimmed with the playback rate; a large one is a real
// jump and is seeked, but at most once every four seconds. The old picture clone
// learned this the hard way: chasing a seek every tick, or seeking again while
// one is still in flight, is what makes the sound jump and crackle.
function musicAheadLead(hard) {
	var el = musicAhead.el, main = tree && tree.sound;
	if (!el || !main || !musicAhead.ready) { return; }
	// the ahead element can reach the end L before the picture does; its last L
	// seconds are already in the remote's buffer, so do not seek it back to life
	if (el.ended) { el.playbackRate = 1; return; }
	var want = (main.currentTime || 0) + musicAhead.target;
	var dur = main.duration || 0;
	if (dur > 0) { want = Math.min(want, Math.max(0, dur - 0.05)); }
	var err = want - (el.currentTime || 0);
	musicAhead.err = err;
	if (!hard && el.seeking) { return; }
	var now = Date.now();
	// a real jump is rare; the old clone found 2 s a safer line than 0.5 s,
	// because anything smaller is better ridden out with the playback rate
	if (hard || (Math.abs(err) > 2.0 && now - (musicAhead.seekAt || 0) > 5000)) {
		musicAhead.seekAt = now;
		musicAhead.seekCount++;
		try { el.currentTime = Math.max(0, want); } catch (e) {}
		el.playbackRate = 1;
		musicAhead.rate = 1;
		return;
	}
	var rate = 1;
	// the same tiers the picture clone used: a large error is corrected in a few
	// seconds, not by emptying the decoder
	if (err > 0.4) { rate = 1.2; }
	else if (err > 0.05) { rate = 1.1; }
	else if (err < -0.4) { rate = 0.82; }
	else if (err < -0.05) { rate = 0.92; }
	try { el.playbackRate = rate; } catch (e) {}
	musicAhead.rate = rate;
}

function musicAheadStart() {
	if (!musicStream.active || !tree || !tree.songs || !tree.songs[0] || tree.songs[0].type != 'video') {
		if (musicAhead.ready || musicAhead.starting) { musicAheadStop(); }
		return;
	}
	// a pause keeps the loaded element; the resume hard-seeks it
	if (musicStream.paused || !tree.sound || tree.sound.paused || tree.sound.ended) { return; }
	// a video that is waiting right now must not let the audio-only tap run on
	musicAhead.hold = !!musicVideoStats.waitAt;
	var main = tree.sound;
	var src = main.currentSrc || main.src;
	if (!src) { return; }
	// The lead comes from the first pings. Starting before it is known would
	// send the opening at the wrong place and then jump; wait for the number.
	var lead = musicStreamLead();
	if (lead <= 0.001) { return; }
	if (musicAhead.el && musicAhead.src == src && musicAhead.ready) {
		musicAhead.target = lead;
		musicAheadLead(false);
		return;
	}
	if (musicAhead.starting) { return; }
	var ctx = musicVisual.ctx;
	if (!ctx) { return; }
	var chain = musicAheadChain();
	if (!chain) { return; }
	var el = musicAhead.el;
	if (!el) {
		el = musicAhead.el = document.createElement('audio');
		el.preload = 'auto';
		el.autoplay = false;
		// a trim of a few percent must not change the pitch
		try { el.preservesPitch = true; el.mozPreservesPitch = true; el.webkitPreservesPitch = true; } catch (e) {}
		el.setAttribute('aria-hidden', 'true');
		el.style.cssText = 'position:fixed;left:-4px;top:-4px;width:2px;height:2px;opacity:0.01;pointer-events:none;z-index:-1;';
		document.body.appendChild(el);
		try { musicAhead.source = ctx.createMediaElementSource(el); }
		catch (e) { musicAhead.failed = true; musicAheadForget(); return; }
		try { musicAhead.source.connect(chain.compressor); }
		catch (e) { musicAhead.failed = true; musicAheadForget(); return; }
	}
	var gen = ++musicAhead.gen;
	musicAhead.starting = true;
	musicAhead.ready = false;
	musicAhead.failed = false;
	musicAhead.src = src;
	musicAhead.target = lead;
	var url = src + (src.indexOf('?') >= 0 ? '&' : '?') + 'clone=1';
	var done = false;
	var ready = function() {
		if (done || gen !== musicAhead.gen || el.src !== url) { return; }
		done = true;
		musicAhead.starting = false;
		musicAhead.ready = true;
		musicAheadLead(true);
		musicStreamTapSource('ahead');
		musicOpusSource();
		// the live tap had already sent the moment the ahead element replaces;
		// PCM drops it so the remote starts at the new place instead of playing
		// the old buffer and then jumping
		if (musicStream.codec == 'pcm') {
			musicStreamTapActive(true, true);
			musicStreamSendJson({ type: 'control', action: 'flush' });
		}
		if (!musicStream.active || !tree.songs || !tree.songs[0] || tree.songs[0].type != 'video') { musicAheadStop(); return; }
		if (musicStream.paused || (tree.sound && tree.sound.paused) || musicAhead.hold) { return; }
		var p = null;
		try { p = el.play(); } catch (e) {}
		if (p && p.catch) { p.catch(function() { if (gen === musicAhead.gen) { musicAheadFailed(); } }); }
	};
	el.onerror = function() { if (gen === musicAhead.gen && el.src === url) { musicAheadFailed(); } };
	el.onloadedmetadata = ready;
	el.oncanplay = ready;
	// a source that never answers must not leave the live tap switched off;
	// one retry is scheduled so a slow load is not permanent
	setTimeout(function() { if (gen === musicAhead.gen && !musicAhead.ready) { musicAheadFailed(); } }, 5000);
	el.src = url;
	clearInterval(musicAhead.timer);
	musicAhead.timer = setInterval(musicAheadTick, 500);
}

function musicAheadTick() {
	if (!musicAheadWanted() || !musicAhead.ready || !musicAhead.el) { return; }
	if (musicAhead.hold) { return; }
	if (musicAhead.el.ended) { return; }
	if (musicAhead.el.paused) {
		var p = null;
		try { p = musicAhead.el.play(); } catch (e) {}
		if (p && p.catch) { p.catch(function() { musicAheadFailed(); }); }
	}
	musicAheadLead(false);
}
function musicAheadFailed() {
	musicAhead.failed = true;
	musicAheadStop();
	if (!musicStream.active) { return; }
	clearTimeout(musicAhead.retryTimer);
	musicAhead.retryTimer = setTimeout(function() {
		musicAhead.retryTimer = 0;
		if (musicStream.active && !musicAhead.ready) { musicAheadStart(); }
	}, 10000);
}
function musicAheadRetarget() {
	if (!musicStream.active) { if (musicAhead.ready) { musicAheadStop(); } return; }
	if (!tree || !tree.songs || !tree.songs[0] || tree.songs[0].type != 'video') {
		if (musicAhead.ready) { musicAheadStop(); }
		return;
	}
	// a pause keeps the element loaded, so resuming needs no second load
	if (musicStream.paused || (tree.sound && tree.sound.paused)) {
		var paused_lead = musicStreamLead();
		if (paused_lead > 0.001) { musicAhead.target = paused_lead; }
		musicAheadPause();
		return;
	}
	var lead = musicStreamLead();
	if (lead <= 0.001) { return; }
	if (!musicAhead.ready) {
		// a trim or a new measurement may land while the element is loading;
		// the ready handler reads this target, so keep it current
		musicAhead.target = lead;
		if (!musicAhead.starting) { musicAheadStart(); }
		return;
	}
	musicAhead.target = lead;
	musicAheadLead(false);
}
function musicAheadPause() {
	musicAhead.hold = true;
	if (musicAhead.el) { try { musicAhead.el.pause(); } catch (e) {} }
}
function musicAheadResume() {
	musicAhead.hold = false;
	if (!musicAheadWanted()) { return; }
	if (musicAhead.ready) {
		musicAheadLead(true);
		var p = null;
		try { p = musicAhead.el.play(); } catch (e) {}
		if (p && p.catch) { p.catch(function() {}); }
		return;
	}
	musicAheadStart();
}
function musicAheadSeek() {
	if (!musicAhead.ready) { return; }
	musicAheadLead(true);
}

// ---- the equalizer ----------------------------------------------------------
// Ten peaking bands across the audible range plus a low shelf for the bass
// boost. The filters sit in the shared graph after the leveller and before the
// limiter, so the local sound and the remote stream hear the same curve. The
// state is one `music` setting, so it follows the machine like normalization
// and survives a reload. Flat means no graph is built for it on its own.
var music_eq_freqs = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
var music_eq_presets = {
	flat:      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
	rock:      [6, 4, 2, -1, -2, -1, 1, 3, 4, 5],
	pop:       [-1, 1, 3, 4, 2, -1, -1, 1, 2, 2],
	jazz:      [4, 3, 1, 2, -1, -1, 0, 1, 2, 3],
	classical: [4, 3, 2, 1, 0, -1, -1, 0, 1, 2],
	vocal:     [-3, -2, 0, 2, 4, 4, 3, 1, 0, -2],
	bass:      [8, 7, 5, 3, 0, 0, 0, 0, 0, 0]
};
var music_equalizer = { bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], bass: 0, preset: 'flat' };
var music_eq_save_timer = 0;
var music_eq_drag = null;
var music_audio_loading = false;
var music_sync_offset = 0;
var music_sync_save_timer = 0;

function musicEqualizerClampBand(v) {
	v = parseFloat(v);
	if (isNaN(v)) { return 0; }
	v = Math.round(v * 2) / 2;
	return Math.max(-12, Math.min(12, v));
}
function musicEqualizerClampBass(v) {
	v = parseFloat(v);
	if (isNaN(v)) { return 0; }
	return Math.max(0, Math.min(12, Math.round(v * 2) / 2));
}
function musicEqualizerLoad() {
	var el = document.getElementById('music_equalizer_data');
	if (!el) { return; }
	var bands = (el.getAttribute('bands') || '').split(',');
	for (var i = 0; i < music_eq_freqs.length; i++) {
		music_equalizer.bands[i] = musicEqualizerClampBand(bands[i]);
	}
	music_equalizer.bass = musicEqualizerClampBass(el.getAttribute('bass'));
	music_equalizer.preset = el.getAttribute('preset') || 'flat';
	musicEqualizerPaint();
}
function musicEqualizerDirty() {
	if (music_equalizer.bass > 0) { return true; }
	for (var i = 0; i < music_equalizer.bands.length; i++) {
		if (Math.abs(music_equalizer.bands[i]) > 0.001) { return true; }
	}
	return false;
}
function musicEqualizerSave() {
	clearTimeout(music_eq_save_timer);
	music_eq_save_timer = setTimeout(function() {
		settingSetter({
			app: 'music',
			setting: 'equalizer',
			value: JSON.stringify({ bands: music_equalizer.bands, bass: music_equalizer.bass, preset: music_equalizer.preset })
		});
	}, 250);
}
function musicEqualizerApply(chain) {
	var g = chain || musicVisual;
	var ctx = musicVisual && musicVisual.ctx;
	var now = ctx ? ctx.currentTime : 0;
	if (g && g.eqFilters) {
		for (var i = 0; i < g.eqFilters.length && i < music_equalizer.bands.length; i++) {
			try { g.eqFilters[i].gain.setTargetAtTime(music_equalizer.bands[i], now, 0.02); }
			catch (e) { try { g.eqFilters[i].gain.value = music_equalizer.bands[i]; } catch (e2) {} }
		}
	}
	if (g && g.eqBass) {
		try { g.eqBass.gain.setTargetAtTime(music_equalizer.bass, now, 0.02); }
		catch (e) { try { g.eqBass.gain.value = music_equalizer.bass; } catch (e2) {} }
	}
	// a boosted band should be peak-guarded even when normalization is off
	if (g && g.limiter) { musicNormalizeParams(chain); }
	if (!chain) {
		musicEqualizerPaint();
		if (musicAhead.chain) { musicEqualizerApply(musicAhead.chain); }
	}
}
// Paint every band from its dB value: the knob sits at the value, the fill runs
// from the centre line to it. The value is also the slider's ARIA state.
function musicEqualizerPaint() {
	$('#music_eq_presets .music_eq_preset').each(function() {
		$(this).attr('state', $(this).attr('data-preset') == music_equalizer.preset ? 'on' : 'off');
	});
	$('#music_eq_bands .music_eq_band').each(function() {
		var band = parseInt($(this).attr('data-band'), 10);
		var v = music_equalizer.bands[band] || 0;
		var p = (v + 12) / 24;
		var fill = $(this).find('.music_eq_fill');
		if (v >= 0) {
			fill.css({ bottom: '50%', height: ((p - 0.5) * 100).toFixed(2) + '%' });
		}
		else {
			fill.css({ bottom: (p * 100).toFixed(2) + '%', height: ((0.5 - p) * 100).toFixed(2) + '%' });
		}
		$(this).find('.music_eq_knob').css({ top: ((1 - p) * 100).toFixed(2) + '%' });
		$(this).find('.music_eq_value').text((v > 0 ? '+' : '') + v);
		$(this).attr('aria-valuenow', v);
	});
	$('#music_eq_bass').val(music_equalizer.bass);
	$('#music_eq_bass_value').text(music_equalizer.bass + ' dB');
}
function musicEqualizerChanged(preset) {
	music_equalizer.preset = preset || 'custom';
	// A non-flat curve needs the shared graph; flat leaves it alone (and does not
	// build one just to multiply the sound by nothing).
	if (musicEqualizerDirty() && !(musicVisual && musicVisual.limiter)) {
		try { musicAudioGraph(); } catch (e) {}
	}
	musicEqualizerApply();
	musicEqualizerSave();
}
function musicEqualizerBand(band, value) {
	band = parseInt(band, 10);
	if (isNaN(band) || band < 0 || band >= music_eq_freqs.length) { return; }
	music_equalizer.bands[band] = musicEqualizerClampBand(value);
	musicEqualizerChanged();
}
function musicEqualizerBandFromEvent(e, track) {
	if (!track || !track.length) { return 0; }
	var r = track[0].getBoundingClientRect();
	if (!r.height) { return 0; }
	var y = (e.clientY - r.top) / r.height;
	y = Math.max(0, Math.min(1, y));
	return (0.5 - y) * 24;
}

// A band takes a drag up/down, a wheel notch, an arrow key or a double click
// (back to 0). The whole band is the target, not only the thin track.
$(document).on('pointerdown', '.music_eq_band', function(e) {
	music_eq_drag = $(this).attr('data-band');
	try { this.focus(); } catch (err) {}
	musicEqualizerBand(music_eq_drag, musicEqualizerBandFromEvent(e, $(this).find('.music_eq_track')));
	e.preventDefault();
});
$(document).on('pointermove', function(e) {
	if (music_eq_drag === null) { return; }
	var t = $('.music_eq_band[data-band="' + music_eq_drag + '"] .music_eq_track');
	musicEqualizerBand(music_eq_drag, musicEqualizerBandFromEvent(e, t));
});
$(document).on('pointerup pointercancel', function() { music_eq_drag = null; });
$(document).on('wheel', '.music_eq_band', function(e) {
	var ev = e.originalEvent || e;
	var d = ev.deltaY || 0;
	if (!d) { return; }
	e.preventDefault();
	e.stopPropagation();
	var band = parseInt($(this).attr('data-band'), 10);
	musicEqualizerBand(band, (music_equalizer.bands[band] || 0) + (d < 0 ? 1 : -1));
});
$(document).on('dblclick', '.music_eq_band', function() {
	musicEqualizerBand($(this).attr('data-band'), 0);
});
$(document).on('keydown', '.music_eq_band', function(e) {
	var band = parseInt($(this).attr('data-band'), 10);
	var v = music_equalizer.bands[band] || 0;
	if (e.key == 'ArrowUp' || e.key == 'ArrowRight') { v += 1; }
	else if (e.key == 'ArrowDown' || e.key == 'ArrowLeft') { v -= 1; }
	else if (e.key == 'Home') { v = 0; }
	else { return; }
	e.preventDefault();
	musicEqualizerBand(band, v);
});
$(document).on('click', '.music_eq_preset', function() {
	var name = $(this).attr('data-preset');
	var preset = music_eq_presets[name];
	if (!preset) { return; }
	music_equalizer.bands = preset.slice();
	if (name == 'flat') { music_equalizer.bass = 0; }
	musicEqualizerChanged(name);
});
$(document).on('input', '#music_eq_bass', function() {
	music_equalizer.bass = musicEqualizerClampBass(this.value);
	musicEqualizerChanged();
});

// The configuration and Audio drawers float over the whole screen and are
// dragged by the bar across their top, the way the Guide's associate is dragged
// by its header. The bar's own controls are left alone, a few pixels of travel
// are needed before a drag begins, and a sheet that has been moved keeps its
// spot in the same window_places store the Guide uses, so it comes back after a
// restart. A sheet never moved opens against the Music window's top-right.
function musicConfigKey(panel) {
	return 'music:' + (panel.attr('id') == 'music_audio_panel' ? 'audio' : 'configuration');
}
// A sheet never moved opens against the Music window's top-right. When the
// other sheet is already open, put this one beside it rather than over it, so
// both can be read at once; if the screen has no room for two, stagger it a
// little so both bars stay in reach.
function musicConfigPlace(panel) {
	if (!panel.length) { return; }
	var key = musicConfigKey(panel);
	if (typeof jawnosPanelPosRestore == 'function' && jawnosPanelPosRestore(key, panel)) { return; }
	var win = panel.closest('.wind');
	var vw = $(window).width(), vh = $(window).height();
	var w = panel.outerWidth() || 360, h = panel.outerHeight();
	var left = vw - w - 16;
	var top = 90;
	if (win.length) {
		var r = win[0].getBoundingClientRect();
		left = r.right - w - 16;
		top = r.top + 90;
	}
	var other = (panel.attr('id') == 'music_audio_panel') ? $('#music_configuration') : $('#music_audio_panel');
	if (other.length && other.is(':visible')) {
		var o = other[0].getBoundingClientRect();
		var gap = 12;
		var clear = (left + w + gap <= o.left || left >= o.right + gap || top + h + gap <= o.top || top >= o.bottom + gap);
		if (!clear) {
			// beside it: to its left first, then its right
			var spots = [o.left - w - gap, o.right + gap];
			var beside = null;
			for (var i = 0; i < spots.length; i++) {
				if (spots[i] >= 0 && spots[i] + w <= vw) { beside = spots[i]; break; }
			}
			if (beside !== null) {
				left = beside;
				top = Math.max(0, Math.min(top, vh - h));
			}
			else {
				// no room for both across the screen: stagger, keeping both bars clear
				left = Math.max(0, Math.min(o.left + 42, vw - w));
				top = Math.max(0, Math.min(o.top + 52, vh - h));
			}
		}
	}
	panel.css({
		left: Math.max(0, Math.min(left, vw - w)) + 'px',
		top: Math.max(0, Math.min(top, vh - h)) + 'px',
		right: 'auto',
		bottom: 'auto'
	});
}
function musicConfigFront(panel) {
	$('#music_configuration, #music_audio_panel').not(panel).css('z-index', 900000);
	panel.css('z-index', 900001);
}
// The window paints its own title bar above its contents, so a sheet left in
// the content slides under it. Move the sheet onto the window's frame: it is
// still the window's child (removed and minimised with it) but sits above the
// bar and is free to cross the whole screen.
function musicConfigFloat(panel) {
	var win = panel.closest('.wind');
	if (!win.length) { return; }
	panel.attr('music_window', win.attr('id'));
	if (panel.parent()[0] !== win[0]) { win.append(panel); }
	// above the title bar (top_level_now + 2) and below the window's frame ring
	panel.css('z-index', 900000);
	if (typeof topLevelNow == 'function') { topLevelNow(win); }
}
function musicConfigShow(panel) {
	if (!panel.length || panel.is(':visible')) { return; }
	musicConfigFloat(panel);
	musicConfigFront(panel);
	// measure behind visibility, not display: none - a hidden element has no box
	panel.css({ visibility: 'hidden', display: 'flex' });
	musicConfigPlace(panel);
	panel.css('visibility', '');
}
// whichever sheet is touched comes to the front of the pair
$(document).on('mousedown touchstart', '.music_cfg_drawer', function () {
	musicConfigFront($(this));
});
function musicConfigDraggable() {
	$('#music_configuration, #music_audio_panel').filter(':not([cfg_drag_armed])').each(function () {
		var panel = $(this);
		panel.attr('cfg_drag_armed', '1');
		panel.draggable({
			handle: '.music_cfg_bar',
			// a tap on the bar must not move the sheet
			distance: 8,
			cancel: 'button, input, select, textarea, label, a',
			start: function () {
				// the sheet rides above every other window while it is being moved
				var win = $(this).closest('.wind');
				if (win.length && typeof topLevelNow == 'function') { topLevelNow(win); }
				musicConfigFront($(this));
			},
			drag: function (e, ui) {
				// keep the whole sheet on the screen, wherever it is dragged
				var w = $(this).outerWidth(), h = $(this).outerHeight();
				ui.position.left = Math.max(0, Math.min(ui.position.left, $(window).width() - w));
				ui.position.top = Math.max(0, Math.min(ui.position.top, $(window).height() - h));
			},
			stop: function () {
				if (typeof jawnosPanelPosSave == 'function') { jawnosPanelPosSave(musicConfigKey($(this)), $(this)); }
			}
		});
	});
}

// Is the window wearing the phone's own draw? The template says so on #music
// (see apps/music/music.html.ep): the shelves are one-line strips and the list
// runs from under them to the player, all of it inline. The desktop's geometry
// must not be laid over that, so the saved shelf sizes and the shelf drag
// handles stand down - and because the mark is the markup's, the two can never
// disagree about which draw is showing.
function musicPhoneLayout() {
	return $('#music').attr('phone_layout') == 'yes';
}
// A phone's WebView is paused by the app when its activity goes to the
// background (the screen turning off, the app being switched away from), and
// that pause takes the player's timers - and the next track - with it. The
// Android app exposes window.JawnMedia.playing(); saying a track is playing
// keeps the WebView alive. The short delay lets a track change (pause then
// play on the next source) pass without standing the keepalive down between
// tracks; a real stop still releases it a few seconds later.
var musicKeepaliveTimer;
function musicKeepalive(playing) {
	clearTimeout(musicKeepaliveTimer);
	var media = window.JawnMedia;
	if (!media || typeof media.playing != 'function') { return; }
	try {
		if (playing) { media.playing(true); }
		else { musicKeepaliveTimer = setTimeout(function () { try { media.playing(false); } catch (e) {} }, 5000); }
	}
	catch (e) { /* the bridge is a nicety, never a reason to stop the player */ }
}
// Closing the window takes the <video> element with it, which ends playback
// without an onpause; release the keepalive so a backgrounded app can sleep
// again. Minimising or hiding the window leaves it alone.
$(document).on('click touchend', '.close_button[app="music"]', function() {
	musicKeepalive(false);
	// Closing the window gives the AudioContext (and so its Pulse stream) back
	// to the browser. The leaked streams were the unused ones treeMaker made on
	// every re-render, not this graph; see treeMaker.
	musicAudioClose();
	document.querySelectorAll('[data-jawnos-seek-preview]').forEach(function(n) { n.remove(); });
});
$(window).on('pagehide', function(e) {
	musicKeepalive(false);
	// a real unload/reload releases the context and its Pulse stream; a page
	// parked in the back/forward cache (a phone putting the app away) keeps it,
	// so background playback is not cut off
	if (!e.originalEvent || !e.originalEvent.persisted) { musicAudioClose(); }
});
// The rendered window contents are cached server-side and reused on the next
// open; key that cache to the code revision, so a template change (which ships
// with a version bump) is never served stale - the tools toggle went missing
// this way once already.
var lastMusicRawHtml, lastMusicCacheHtml;
// The window is cached server-side and replayed on the next open, so strip the
// player-specific parts before storing it: the playing row, the inline player
// snapshot, the media source and the title. They all come back from the live
// player cache on restore - a frozen copy made the browser load the old source
// first and showed a stale row until the restore caught up. Nothing is sent
// unless the stored shell actually changed.
function musicContentCache(html) {
	if (html == lastMusicRawHtml) { return; }
	lastMusicRawHtml = html;
	// innerHTML never runs scripts; $('<div/>').html(html) would execute the
	// window's inline <script> a second time
	var doc = document.implementation.createHTMLDocument('music_cache');
	doc.body.innerHTML = html;
	var shell = $(doc.body);
	shell.find('.playing').removeClass('playing holla');
	shell.find('#music_player_data').empty();
	shell.find('video.media_out').removeAttr('src');
	shell.find('#video_subtitles').removeAttr('src');
	// the visualiser is live state too: the canvas and the video it is played
	// into are rebuilt by music.js, so the shell stores them bare
	shell.find('.media_visualizer, .media_visual_media').removeAttr('style').removeAttr('width').removeAttr('height').removeAttr('src');
	shell.find('[id$="_full_title"]').text('');
	shell.find('#play_logo').each(function() { var el = $(this), p = el.attr('play_icon'); if (p) { el.attr('src', p); } });
	shell = shell.html();
	if (shell == lastMusicCacheHtml) { return; }
	lastMusicCacheHtml = shell;
	cacheSet({ 'app': 'music', 'context': 'content', 'subcontext': (typeof jawnos_version != 'undefined' ? jawnos_version : '') }, { contents: shell });
}
// The mute button carries both glyphs; which one shows follows the same rule as
// the volume itself: muted when the user muted it or the machine's own output is
// switched off in the configuration panel.
function updateMusicMuteIcon() {
	var button = $('#music_mute');
	if (!button.length) { return; }
	var muted = (music_muted || mao['me'] == 'off');
	button.attr('src', muted ? button.attr('mute_icon') : button.attr('speaker_icon'));
	button.attr('muted', muted ? 'yes' : 'no');
}
$(document).on('ready', function() { 
	treeMaker();
});
$(document).on('click', '#music_toggle', function() {
	musicToggle();
});

function musicToggle(files, same_order) {
	var url = '/manager/music';
	var timestamp = Date.now();
	var jmiss = JSON.stringify(misses);
	if ($('#music').length == 0 || files ) {
		var jfiles;
		if (files) {
			jfiles = JSON.stringify(files);
		}
		$.ajax({
			url: url,
			type: 'GET',
			data: { window_maker: 'yes', timestamp: timestamp, misses: jmiss, files: jfiles, same_order: same_order ? 1 : 0 },
			success: function(response) {

				var window_id = windowMaker(response);

				// a handed-over list (the guide's play, a folder's play) skips the
				// saved track's restore: musicInit('files') brings the volume, mute
				// and layout back but leaves the player to the list about to start
				musicInit(files ? 'files' : undefined);
				if (files) {
					mediaMaker();
				}
			}, error: function (response) {  }
		});
	}
	else {
		var music_window = $('#music').closest('.wind').attr('id');
		$('#' + music_window).show();
		$('.little_window[app="music"]').hide()
		topLevelNow($('#' + music_window));
		musicInit();
	}
}

async function musicInit(method) {
	treeMaker();
	// the drawers ship with their bars, so arm their drag once the window is up
	musicConfigDraggable();
	// the equalizer's saved curve and the panel's sliders
	musicEqualizerLoad();
	// The Audio drawer is fetched from this machine and is also where the saved
	// curve lives; fetch it once per opened window so a saved EQ is applied even
	// if the drawer is never opened.
	if (!$('#music_audio_panel').children().length) { musicAudioPanelLoad(false); }
	if (method != 'search') {
		// a restored window comes back with the setting the server last saved;
		// a search re-render keeps the value already running in this page
		var normalize_attr = $('#music').attr('normalize');
		if (normalize_attr) { music_normalize = normalize_attr; }
		var codec_attr = $('#music').attr('stream_codec');
		if (codec_attr) { music_stream_codec = codec_attr; }
		// not a silent start: restore the machine's own output level, or a track
		// that is already loaded plays back at the audio-handshake volume when the
		// app is re-opened
		musicVolumeApply();
		// a one-sided local output is a graph choice; a restored window must wear
		// it as soon as its context can run
		if (musicOutputChannel(mao['me']) == 'left' || musicOutputChannel(mao['me']) == 'right') {
			try { musicAudioGraph(); } catch (e) {}
		}
		// The bar follows the machine's own volume when the system exposes one (the
		// Master mixer on a desk, the music channel on Android). Ask once before the
		// player cache is read, so a saved app level is not laid over it, then keep
		// it in step while the window is up.
		try { await musicSystemVolumePoll(true); } catch (e) {}
		musicSystemVolumeWatch();
	}
	// The window contents can be served from the server-side cache, which freezes
	// the player snapshot that was inlined when it was written. Trusting that copy
	// restored the first track at 0:00 after a refresh, so fetch the live player
	// cache before restoring. (The old $().load() here was async, so the read on
	// the next line always saw the frozen copy.)
	var jpd = $('#music_player_data').text();
	if (method != 'search') {
		try {
			var fresh = await $.ajax({ url: '/manager/cache_get?app=music&context=player&json=yes', dataType: 'text' });
			if (isJson(fresh)) { jpd = fresh; $('#music_player_data').text(jpd); }
		}
		catch (e) { /* keep the inlined copy if the fetch fails */ }
	}
	if (isJson(jpd) && method != 'search' && jpd.trim() != 'null') {

		var pd = JSON.parse(jpd);
		// the level and mute the player was last left at; a cached near-zero is the
		// old autoplay-handshake value, so it is ignored. With the bar wired to the
		// system mixer the element itself stays at full gain - the system channel is
		// the level - so a saved app volume would otherwise attenuate twice.
		if (!musicSystemWired && pd.volume && pd.volume >= 0.05) { master_volume = pd.volume; }
		if (musicSystemWired) { master_volume = 1; }
		if (!music_normalize && pd.normalize) { music_normalize = pd.normalize; }
		music_muted = !!pd.muted;
		$('#music_volume').val(musicVolumeLevel());
		updateMusicMuteIcon();
		musicVolumeApply();
		musicNormalizeApply();
		$('#video').attr('theatre_mode', pd.theatre_mode);
		$('#video').attr('type', pd.type);
		// the drawing the player was left on; musicVisualApply below puts it back
		musicVisual.mode = pd.visualization || 'none';

		// pick the saved track first, so thisTrack slices tree.songs and mediaMaker
		// then loads THAT track - mediaMaker reads tree.songs[0] and ignores the file
		// it is handed, so running it before this loaded the first track instead.
		// A window opened on a handed-over list (the guide's play, a folder's play)
		// must NOT bring the saved track back: the caller is about to start the list,
		// and the restore used to override it - that is how "watch Star Trek" played
		// whatever was last on. Volume, mute, theatre and layout still come back;
		// only the track does not.
		if (method != 'files') {
			$('.music_file').removeClass('playing');
			var mf = pd.file ? $('.music_file[file="' + pd.file + '"]') : $();
			mf.addClass('playing');
			var playing = $('.playing');
			tree.current_track = playing.attr('number');
			thisTrack(playing.closest('.track_item'));
			$('#video_full_title').text(playing.find('.full_title').text());

			// only a saved track is restored: a first-ever open (no player cache) must
			// not start playing on its own
			if (pd.file) {
				mediaMaker({ file: pd.file, currentTime: pd.currentTime, method: 'restore', timestamp: Date.now(), state: pd.state, });
				if (method != 'search') {
					tree.sound.currentTime = pd.currentTime;
				}
				tree.sound.state = pd.state;
			}
		}
		$('#music_player_data').text(jpd);

		tree.sound.textTracks[0].mode = $('#video_subtitle_toggle').attr('status');

		if ($('#video').attr('type') == 'audio') {
			$('#video').hide();
		}
		if (pd.state == 0 && method != 'search' && method != 'files') {
			tree.sound.pause();
		}
		if (pd.resizes && !musicPhoneLayout()) {
			$('#music_albums').height(pd.resizes.music_albums.height);
			$('#music_albums').scrollTop(pd.resizes.music_albums.scrollTop);
			$('#music_artists').height(pd.resizes.music_artists.height);
			$('#music_albums').scrollTop(pd.resizes.music_albums.scrollTop);
			$('#music_files').css({ 'top': ($('#music_albums').height() + 100) + 'px' });
			var i = $('#interface').height();
			var mc = $('#music').find('.media_controls').height();
			var mm = $('#music_albums').height();
			$('#music_files').height($('#music').height() - (mm + mc + i));
		}
		playerCacheSaver();
		musicVisualApply();
	}
	// a window with no player cache still wears the setting from its markup
	musicNormalizeApply();


	$('.file_duration').each(function(i,v) {
		$(v).text(numeral($(v).text()).format('00:00:00'));
	});
	$('#video').trigger('mouseenter');
	setTimeout(function() {
		if ($('#video').attr('type') != 'video') {	
			$('#video').hide();
		}
	},200);

	if (!musicPhoneLayout()) {
		$('#music_artists, #music_albums').resizable({
			start: function(p) {
			},
			resize: function(p,j) {
				if (p.target.id == 'music_artists') {
					$('#music_albums').height(j.size.height);
				}
				else if (p.target.id == 'music_albums') {
					$('#music_artists').height(j.size.height);
				}
				var newTop = ($('#music_albums').height() + 100) + 'px';
				$('#music_files').css({ 'top': newTop });
				var i = $('#interface').height();
				var mc = $('#music').find('.media_controls').height();
				var mm = $('#music_albums').height();
				$('#music_files').height($('#music').height() - (mm + mc + i));	
			},
			stop: function(p) { 
			}
		});
	}
	var mc = $('#music_configuration');
	if (mc.is(':visible')) { musicConfigFloat(mc); }
}
function playerCacheSaver(type) {
	var timestamp = Date.now();
	var jpd;
	if (timestamp - tree.lastCache >= 5000) {
		var unlocked = 0;
		if ($('#music').attr('unlock')) { unlocked = 1; }
		var playerData = { 
			number: tree.current_track, 
			'currentTime': tree.sound.currentTime, 
			file: (tree.songs[0] ? tree.songs[0].file : ''), 
			volume: master_volume, 
			muted: music_muted, 
			state: tree.sound.state, 
			theatre_mode: $('#video').attr('theatre_mode'), 
			unlocked: unlocked,
			resizes: {
				music_albums: { bottom: $('#music_albums').css('top'), height: $('#music_albums').height() },
				music_artists: { bottom: $('#music_artists').css('top'), height: $('#music_albums').height() },
				music_files: { top: $('#music_files').css('top'), height: $('#music_files').height() }
			},
			type: $('#video').attr('type'),
			visualization: musicVisual.mode,
			normalize: music_normalize,
			method: 'playerCache',
			subtitle_mode: tree.sound.textTracks[0].mode
		};
		jpd = JSON.stringify(playerData);


		if (type == 'ajax' || ws['music'].readyState != 1) {
			cacheSet({ 'app': 'music', 'context': 'player'}, playerData);
			musicContentCache($('#music').parent().html());
		}
		else {
			ws['music'].send(jpd);
		}
		$('#music_player_data').text(jpd);
		tree.lastCache = timestamp;
	}
	return jpd;
}

function treeMaker() {
	tree = {
		files: $('#files').find('.file'),
		songs: [],
		past_songs: [],
		all_songs: [],
		seek: 0,
		song_id: 0,
		current_track: 0,
		sound: document.getElementById('video'),
		lastCache: 0
	};
	for (n = 0; n <= tree.files.length - 1; n++) {
		if (tree.files[n].textContent !== undefined) {
			var info;
			if (isJson($('.file_json[file_uuid="' + $(tree.files[n]).attr('file_uuid') + '"]').text())) {
				info = JSON.parse($('.file_json[file_uuid="' + $(tree.files[n]).attr('file_uuid') + '"]').text());
			}
			var data = { 
				encodedFile: encodeURI(tree.files[n].textContent), 
				file: tree.files[n].textContent, 
				type: $(tree.files[n]).attr('type'), 
				app: $(tree.files[n]).attr('app'),
				remote_uuid: $(tree.files[n]).attr('remote_uuid'),
				computer_name: $(tree.files[n]).attr('computer_name'),
				colour: $(tree.files[n]).attr('colour'),
				info: info,
			};
			tree.songs.push(data);
			tree.all_songs.push(data);
		}
	}
	$('.file_duration').each(function(i,v) {
		if ($(v).attr('initialized') != 'yes') {
			$(v).text(numeral($(v).text()).format('00:00:00'));
			$(v).attr('initialized', 'yes');
		}
	});
}
treeMaker();


var musicSearchTimeout;
$(document).on('keyup', '#music_search', function(e) {
	if (e.keyCode == 13) {
		$('.music_album').attr('active', 'no');
		$('.music_artist').attr('active', 'no');
		searchMusic();
	}
});


var interval;
function mediaMaker(data) {
	if (typeof data != 'object') { data = {}; }
	var time = data['time'];
	var timestamp = data['timestamp'] || Date.now();
	var method = data['method'];
	var file = data['file'] || (tree.songs[0] ? tree.songs[0].file : undefined);
	var uri_track = encodeURIComponent(file);
	if (mao['srv'] == 'on') {
		$.ajax({
			url: '/play?track=' + uri_track,
			success: function(response) {}
		});
	}
	if (1 == 1) {
		var id = 'video';
		var vid = $('#' + id);
		var window_id;

		if (file) {
			var url = '/play?track=' + uri_track;

			tree.sound = document.getElementById('video');
			if (data['state'] != 0) {
				$('#play_logo').attr('src', jawnosPauseIcon());
			}
			// 'benign' leaves the media untouched (a search re-render must not restart
			// the track). 'restore' is the page-load path: it loads the saved track and
			// resumes when the player was left playing, overriding any stale src the
			// served window carried, but does not re-announce it remotely.
			if (method != 'benign') {

				if (tree.songs[0].type == 'audio') {
					$('#music_library').show();
					$('#video').hide();
					$('#video').attr('type', 'audio');
					$('#album_cover').show();
				}
				else {
					$('#video').attr('type', 'video').show();

					$('#album_cover').hide();
				}

				tree.current_track = tree.past_songs.length + 1;

				if (data['state'] != 0) {
					tree.sound.state = 1;
				}
				else {
					tree.sound.state = 0;
				}
				tree.sound.saved_volume = master_volume;
				// Set the final level once. WebKit maps the element's volume and
				// muted flag onto its Pulse stream and does not reliably take a later
				// change back: a transient mute or near-zero volume for the autoplay
				// handshake left streams at 1% or muted with the button off. When the
				// shared graph carries the element, this keeps the element at full
				// gain and puts the real level in the graph, where WebKit cannot see
				// (or remember) it. If the browser refuses an unmuted autoplay the
				// track simply waits for a press, which is better than playing
				// silently.
				musicVolumeApply();

				if (tree.songs[0].remote_uuid) {
					url += '&remote_uuid=' + tree.songs[0].remote_uuid;
				}

				tree.sound.src = url
				if (method != 'benign') { musicBaselineReset(); musicBaselineStart(); }
				var st_url = url + '&subtitle=yes';
				document.getElementById('video_subtitles').src = st_url;
				document.getElementById('video_subtitles').addEventListener('error', function() {
					this.removeAttribute('src');
				});
				tree.sound.video = true;
				tree.sound.html5 = true;
				tree.sound.playbackRate = 1;
				tree.sound.currentTime = time || 0;
				tree.sound.queued = 0;
				tree.sound.sync_cursor = null;
				tree.sound.sync_wall = 0;
				// the seek bar is only redrawn by the playing interval, which does not run
				// while paused, so a paused restore would otherwise leave it sitting at 0
				// even though the track is at its saved position
				tree.sound.onloadedmetadata = function() {
					var m = $('#video').attr('miss');
					var bar = m ? $('#' + m + '_position') : $();
					if (bar.length && tree.sound.duration) {
						bar.val(tree.sound.currentTime / tree.sound.duration * 100);
					}
				};
				if (data['state'] != 0) {
					// no mute/volume trick here: WebKit would carry it onto the stream
					musicPlay();
				}
				if (method != 'restore') {
					remoteTrackToggle({
						file: file,
						toggle: 'on',
						seek: tree.sound.currentTime
					});
				}
			}
			if ($('#video').attr('theatre_mode') == 'on') {
				theatreModeOn();
			}
			else {
				theatreModeOff();
			}
			tree.sound.onplaying = function() {
				tree.sound.state = 1;
				tree.sound.sync_cursor = null;
				tree.sound.sync_wall = 0;
				musicKeepalive(true);
				musicVolumeApply();
				// a stream left at a remembered low/muted level by Pulse is put right
				// once the browser has actually created this start's sink input
				musicStreamHealthPing();
				// a stream started before the audio context was running retries
				// here, and a paused stream resumes
			if (musicStream.active) {
				if (!musicStream.attached) { musicStreamStart(file, tree.sound.currentTime); }
				else if (musicStream.paused) { musicStreamControl('resume'); }
				else { musicAheadStart(); }
			}
				// a context suspended by a call or the app going away is resumed here;
				// a graph deferred while it was stopped is finished once it runs
				musicAudioResume();
				var local_side = musicOutputChannel(mao['me']);
				if ((music_normalize && music_normalize != 'off') || local_side == 'left' || local_side == 'right' || musicEqualizerDirty()) { musicAudioGraph(); }
				musicBaselineStart();
				var total = tree.sound.duration;
				$('#progress_bar').attr('max', total);
					var endsong = tree.sound.duration;
					$('#total').text(endsong);


					
					var app = tree.songs[0].app;
					
					if (method != 'benign' && method != 'restore') {
						playing_now();
					}
					else {
						var playing = $('.playing');
						var current_track = playing.attr('number');
						treeMaker();
						thisTrack(playing.closest('.track_item'));
						tree.current_track = current_track;
						playing_now('update');
					}
					vidControls['video'] = [];
					if (tree.songs[0].info.chapters) {

						$.each(tree.songs[0].info.chapters, function(i,v) {
							vidControls['video'].push(v.start_time);
						});
					}

					tree['music_data'] = musicAppointmentWriter('start');
					if ($('#video').attr('theatre_mode') == 'on') {
						theatreModeOn();
					}
					else {
						theatreModeOff();
					}
					clearInterval(interval);
					interval = setInterval(function(){
						// subtitles are there when the track has a usable source, not when its
						// cues happen to be parsed: after a search re-render the cues arrive a
						// beat later, and the button used to be hidden in that beat and the
						// mode forced off
						var subtitle_track = document.getElementById('video_subtitles');
						var subtitle_text = tree.sound.textTracks && tree.sound.textTracks[0];
						var subtitle_cues = subtitle_text && subtitle_text.cues;
						var subtitle_ready = !!(subtitle_track && subtitle_track.getAttribute('src') && (subtitle_track.readyState < 2 || (subtitle_cues && subtitle_cues.length)));
						if (subtitle_ready && subtitle_text) {
							$('#video_subtitle_toggle').show();
							subtitle_text.mode = $('#video_subtitle_toggle').attr('status') == 'showing' ? 'showing' : 'hidden';
						}
						else {
							$('#video_subtitle_toggle').hide();
							if (subtitle_text) { subtitle_text.mode = 'hidden'; }
						}
						// A seek is where the media clock and the wall clock disagree: the
						// interval can be late without the track having jumped, and the
						// hidden <progress> value is not a reliable previous position. Compare
						// how far the track moved with how long it actually took.
						var cursor = tree.sound.currentTime;
						var now_ms = Date.now();
						var last_cursor = tree.sound.sync_cursor;
						var last_wall = tree.sound.sync_wall;
						tree.sound.sync_cursor = cursor;
						tree.sound.sync_wall = now_ms;
						if (tree.songs[0] && last_cursor != null && last_wall) {
							var moved = cursor - last_cursor;
							var elapsed = (now_ms - last_wall) / 1000;
							if (Math.abs(moved - elapsed) > 2) {
								remoteTrackToggle({
									file: tree.songs[0].file,
									toggle: 'seek',
									seek: cursor
								});
							}
						}
						$('#progress_bar').attr('value', cursor);
						$('#cursor').text(cursor);
						$('#total_progress').text(numeral(tree.sound.duration).format('00:00:00'));
						$('#elapsed_progress').text(numeral(tree.sound.currentTime).format('00:00:00'));
						playerCacheSaver();

					}, 1000);
					
					$('#play_logo').attr('src', jawnosPauseIcon());
					
				};
				tree.sound.onpause = function() {
					clearInterval(interval);
					tree.sound.state = 0;
					musicKeepalive(false);
					musicStreamControl('pause');

					$('#play_logo').attr('src', jawnosPlayIcon());

				};
				tree.sound.onerror = function() {
					musicKeepalive(false);
					musicStreamStop();
					nextTrack();
				};
				tree.sound.onended = function() {
					clearInterval(interval);
					musicStreamStop();
					$('#progress_bar').attr('value', 0).attr('max', 0);
					$('#total_progress').text(0);
					$('#elapsed_progress').text(0);
					$('#' + id).hide();
		
					tree.past_songs.push(tree.songs.shift());
					if (tree.songs.length == 0 ) {
						if ($('.music_repeat').attr('enabled') == 'on') {
							for (var n = 0; n < tree.all_songs.length; n++ ) {
								tree.songs.push(tree.all_songs[n]);
							}
							tree.past_songs = [];
						}
						else {
							tree.sound.pause();
							$('.playing').removeClass('playing');
							musicAppointmentWriter('stop','no');
							musicKeepalive(false);
							return;
						}
					}
					mediaMaker();
				};
		}
	}
	playerCacheSaver();
	var html = $('#music').parent().html();
	musicContentCache(html);
}

// The remote outputs follow the live stream now. `toggle` keeps its old shape
// so the call sites did not all have to move: on starts (or re-anchors) the
// stream, seek sends a position, off stops when no output is left lit.
function remoteTrackToggle(data) {
	var toggle = data['toggle'];
	var file = data['file'] || (tree.songs[0] ? tree.songs[0].file : '');
	var seek = (data['seek'] === undefined) ? tree.sound.currentTime : data['seek'];
	if (!musicStreamOutputs().length) {
		musicStreamStop();
		return;
	}
	if (toggle == 'off') {
		musicStreamStop();
		return;
	}
	if (toggle == 'seek') {
		if (musicStream.active) {
			musicStreamTapActive(true, true);
			musicStreamControl('seek', { seek: seek, file: file, music_data: data['music_data'] || tree.songs[0] });
			musicAheadSeek();
		}
		return;
	}
	if (toggle == 'on' || toggle == 'track') {
		if (!musicStream.active) {
			musicStreamStart(file, seek);
		}
		else {
			// a track change pauses the old element first; the new one is a
			// continuation of the same stream, so lift the pause and re-anchor
			musicStream.paused = false;
			musicStreamControl('track', { seek: seek, file: file, music_data: data['music_data'] || tree.songs[0] });
			musicStreamControl('resume');
			musicStreamTapActive(true, true);
			musicAheadStart();
		}
	}
}


function musicTitleMaker(object) {
	var app = $('.playing').find('.file');
	var album = app.attr('album');
	var artist = app.attr('artist');
	var song = app.attr('song');
	var video = document.getElementById('video');
	var canvas = document.createElement('canvas');
	var image;


	if (object == 'object') {
		var playing;
		if ($('#video').is(':visible') && advertise_watching == 'on') {
			var ratio = video.videoWidth / video.videoHeight;
			canvas.width = 640 || 0;
			canvas.height = ratio * video.videoHeight || 0;
			canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
			image = canvas.toDataURL('image/png');
			playing = app.closest('.track_item').html();
		}
		else {

		}
		return {
			artist: artist,
			album: album,
			song: song,
			image: image,
			width: canvas.width,
			height: canvas.height,
			ratio: ratio,
			playing: playing
		};
	}
	else {
		return (artist || '') + ' - ' + (album || '') + ' - ' + (song || '');
	}
}

$(document).on('click', '#music_list_view', function() {
	if ($('#video').attr('theatre_mode') == 'on') {
		theatreModeOff();
	}
	else {
		theatreModeOn();
	}
});

// Does the player's picture take the bigger of its two styles? The theatre is
// the obvious yes; a full screen is one too - a player that fills the screen
// should not leave its picture in the corner.
function musicPictureBig() {
	if ($('#video').attr('theatre_mode') == 'on') { return true; }
	var v = document.getElementById('video');
	var fs = document.fullscreenElement || document.webkitFullscreenElement;
	return !!(fs && v && (fs == v || fs.contains(v)));
}

// In and out of fullscreen the player's own picture is put back where it
// belongs; the visualiser's picture is placed by its own frame loop.
$(document).on('fullscreenchange webkitfullscreenchange', function() {
	var v = $('#video');
	if (v.length && v.attr('type') == 'video' && v.attr('theatre_mode') != 'on') {
		v.attr('style', v.attr(musicPictureBig() ? 'big_style' : 'thumb_style'));
	}
});

function theatreModeOn() {
	$('#music_library').hide();
	$('#video').show();
	var bs = $('#video').attr('big_style');
	$('#video').attr('style', bs);
	$('#music').css({'background-color':'black'});
	$('#video').attr('theatre_mode', 'on');
	if ($('#video').attr('type') == 'audio') {
		$('#video').hide();
		var src = $('.playing').closest('.track_item').find('.music_file_thumb').attr('src');
		$('#music_album_cover').attr('src', src).show();
	}
	else if ($('#video').attr('src')) {
		$('#video').show();
		// the interface already fades in and out with the theatre controls (see
		// the video include), so the gear only has to stop being hidden here
		$('#interface').hide();
		$('#music_padlock_toggle').hide();
		$('#music_album_cover').hide()
	}
}

function theatreModeOff() {
	$('#music_library').show();
	$('#music').css({'background-color': $('#music').attr('background_colour')});
	if ($('#video').attr('type') == 'video') {
		// the picture goes back to its corner - unless the player itself is
		// filling the screen, where a corner thumbnail is not what is wanted.
		// Clear theatre_mode first: musicPictureBig reads it, and while it was
		// still 'on' the check called the theatre itself big and re-applied
		// big_style, so leaving the theatre never shrank the picture back
		$('#video').attr('theatre_mode', 'off'); 
		var style = $('#video').attr(musicPictureBig() ? 'big_style' : 'thumb_style');
		$('#video').attr('style', style);
	}
	else {
		$('#video').hide();
	}
	$('#interface').show();
	$('#music_padlock_toggle').show();
	$('#music_configuration_toggle').show();
	$('#music_album_cover').hide();
	$('#video').attr('theatre_mode', 'off'); 
}

$(document).on('click', '#video_subtitle_toggle', function() {
	var mode = v.textTracks[0].mode;
	var vst = $(this);
	if (mode == 'showing') {
		v.textTracks[0].mode = 'hidden';
		vst.attr('status', 'hidden');
	}
	else {
		v.textTracks[0].mode = 'showing';
		vst.attr('status', 'showing');
	}
	settingSetter({ 'app': 'music', 'setting': 'subtitles', 'value': v.textTracks[0].mode });
});

function musicAppointmentWriter(type,mute) {
	var app = $('.track_item.playing').find('.file');
	var duration = tree.sound.duration;
	var album = app.attr('album');
	var artist = app.attr('artist');
	var song = app.attr('song');
	// the appointment reads album - artist - track, and a part that is not there
	// is left out rather than written as 'undefined'
	var words = [];
	if (album != undefined && album != '') { words.push(album); }
	if (artist != undefined && artist != '') { words.push(artist); }
	if (song != undefined && song != '') { words.push(song); }
	words = words.join(' - ');
	var filename = app.text();
	var timestamp = Date.now();
	var musicData = { 
		app: musicTitleMaker(),
		timestamp: timestamp,
		type: type, 
		account: 'gallery',
		source: 'music',
		unit: tree.sound.duration + 's',
		file: filename,
		notes: musicTitleMaker(),
		mute: mute,
		words: words,
		duration: '-' + duration + 's',
		source: 'music',
		currentTime: tree.sound.currentTime,
		total_time: duration,
		title: musicTitleMaker('object'),
		interface: $('#interface').html(),

	};
	if (song != undefined && type != 'data_entry') {
		$.ajax({
			url: '/manager/reset',
			type: 'POST',
			data: musicData,
			success:function(response) {
				continent_record(musicTitleMaker(),timestamp);
			}
		});
	}
	return musicData;
}

$(document).on('click', '.music_file_fetch_home', function () {
	var b = $(this);
	$.ajax({
		url: '/manager/folders/archive/fetch',
		type: 'POST',
		data: { path: b.attr('file'), remote_uuid: b.attr('remote_uuid') },
		success: function (response) {
			// dimmed once it is on the queue; the folders app's panel shows it
			if (response && response.status == 'ok') { b.css({ 'opacity': 0.4 }); }
		}
	});
});

$(document).on('click', '#play', function() {
	if (tree.sound.src == '') {
		mediaMaker({ file: tree.songs[0].file });
	}
	else if (tree.sound.paused) {
		musicVolumeApply();
		musicPlay();
		tree.sound.state = 1;
		$('#play_logo').attr('src', jawnosPauseIcon());
		remoteTrackToggle({
			file: tree.songs[0].file,
			toggle: 'on',
			seek: tree.sound.currentTime
		});
	}
	else {
		tree.sound.pause();
		tree.sound.state = 0;
		$('#play_logo').attr('src', jawnosPlayIcon());
		remoteTrackToggle({
			file: tree.songs[0].file,
			toggle: 'off',
			seek: tree.sound.currentTime
		});
	}
	playerCacheSaver();
	var html = $('#music').parent().html();
	musicContentCache(html);
});

$(document).on('click', '#prev', function() {
	prevTrack();
});

function prevTrack() {
	if (tree.past_songs.length > 0) {
		tree.songs.unshift(tree.past_songs.pop());
	}
	mediaMaker()
}

function nextTrack() {
	if (tree.songs.length == 0) {
		if ($('.music_repeat').attr('enabled') == 'on') {
			for (var n = 0; n < tree.all_songs.length; n++ ) {
				tree.songs.push(tree.all_songs[n]);
			}
			tree.past_songs = [];
		}
		else {
			tree.sound.pause();
			$('.playing').removeClass('playing');
		}
	}
	else {
		tree.past_songs.push(tree.songs.shift());
	}
	if (tree.songs.length == 0) {
		tree.sound.pause();
		$('.playing').removeClass('playing');
		musicKeepalive(false);
		return;
	}
	mediaMaker();
}

$(document).on('click', '#next', function() {
	nextTrack();
});

$(document).on('click', '.track_item', function(e) {
	var item = $(this);
	var file = item.attr('file');
	if ($(e.target).hasClass('music_information_toggle')) {
		musicInformation(file);
	}
	else if ($(e.target).closest('.chapter_thumb')) {
		var ch = $(e.target).closest('.chapter_thumb');
		thisTrack(item);
		mediaMaker({ time: ch.attr('start_time') });
	}
	else {
		thisTrack(item);
		mediaMaker();
	}
});

function thisTrack(item) {
	var number = item.attr("number");
	var unformatted_filename = item.find('.file').text();
	var filename = encodeURI(unformatted_filename);
	treeMaker();
	for (var n = 0; n <= tree.all_songs.length; n++) {
		if (tree.all_songs[n]) {
			if (tree.all_songs[n].encodedFile == filename) {
				tree.past_songs = tree.all_songs.slice(0, number - 1);
				tree.songs = tree.all_songs.slice(number - 1);
				return;
			}
		}
	}
}

function musicInformation(file) {
	var td = $('.track_description[file="' + file + '"]');
	if (td.is(':visible')) {
		td.hide();
	}
	else {
		td.show();
	}
}

function musicWindowResizes() {
	var resizes = {
		music_albums: { bottom: $('#music_albums').css('top'), height: $('#music_albums').height(), scrollTop: $('#music_albums').scrollTop() },
		music_artists: { bottom: $('#music_artists').css('top'), height: $('#music_albums').height(), scrollTop: $('#music_artists').scrollTop() },
		music_files: { top: $('#music_files').css('top'), height: $('#music_files').height(), scrollTop: $('#music_files').scrollTop() }
	};
	return resizes;
}

$(document).on('click change', '#progress_bar', function(e) {
  var total_width = $('#progress_bar').width();
  var current_location = e.offsetX;
  var seek_to = (current_location / total_width) * tree.sound.duration;
  // a touch that reports no offset (or a track whose duration is not known yet)
  // used to set currentTime to NaN, which aborts the whole handler
  if (!total_width || !isFinite(seek_to) || !tree.songs[0]) { return; }
  tree.sound.currentTime = seek_to;
	remoteTrackToggle({
		file: tree.songs[0].file,
		toggle: 'seek',
		seek: tree.sound.currentTime
	});
 });

var master_volume = 1;
// Volume normalisation: off, slight, mild or aggressive. The setting is saved
// as the music app's `normalize` setting; the choice builds the shared Web Audio
// graph in musicAudioGraph().
var music_normalize = '';

// The bar and the machine's own mixer. When the system exposes a music/Master
// channel the slider is that channel, and the element stays at full gain so the
// two do not attenuate one another. When no mixer can be read the slider is the
// player's own level, as it was before.
var musicSystemWired = false;
var musicSystemStream = '';
var musicSystemMax = 100;
var musicSystemLevel = 1;
var musicSystemTouchedAt = 0;
var musicSystemSendTimer = null;
var musicSystemInterval = null;

function musicVolumeClamp(level) {
	level = parseFloat(level);
	if (isNaN(level)) { return 0; }
	return Math.max(0, Math.min(1, level));
}
// What the wheel, a finger drag and the slider all read as the current level.
function musicVolumeLevel() {
	return musicSystemWired ? musicSystemLevel : master_volume;
}
function musicSystemVolumePaint(level, user) {
	musicSystemLevel = musicVolumeClamp(level);
	$('#music_volume').val(musicSystemLevel);
	if (user && musicSystemLevel > 0) { music_muted = false; }
	updateMusicMuteIcon();
	musicVolumeApply();
}
function musicSystemVolumeSend(level) {
	if (!musicSystemWired || !musicSystemStream) { return; }
	clearTimeout(musicSystemSendTimer);
	// dragging the slider sends a stream of input events; the last one wins
	musicSystemSendTimer = setTimeout(function() {
		var raw = Math.round(musicVolumeClamp(level) * musicSystemMax);
		$.ajax({
			url: '/manager/volume_control',
			type: 'GET',
			dataType: 'json',
			data: { stream: musicSystemStream, volume: raw, max: musicSystemMax, device: 'local' },
			error: function() { /* a machine without a mixer keeps its own level */ }
		});
	}, 140);
}
// A person (or the remote media control) moved the bar.
function musicVolumeSet(level) {
	level = musicVolumeClamp(level);
	musicSystemTouchedAt = Date.now();
	if (musicSystemWired) {
		musicSystemVolumePaint(level, true);
		musicSystemVolumeSend(level);
		return;
	}
	master_volume = level;
	if (master_volume > 0) { music_muted = false; }
	$('#music_volume').val(master_volume);
	musicVolumeApply();
	updateMusicMuteIcon();
}
// Read the machine's own mixer. The music channel is preferred (Android's
// music stream); a desk's Master is the fallback. Returns the request so the
// first read can be waited on before a saved player level is restored.
function musicSystemVolumePoll(adopt) {
	if (document.hidden) { return null; }
	if (!document.getElementById('music_volume')) { return null; }
	// do not undo a level the person has just set while its write is in flight
	if (!adopt && Date.now() - musicSystemTouchedAt < 2000) { return null; }
	return $.ajax({
		url: '/manager/volume_control',
		type: 'GET',
		dataType: 'json',
		success: function(response) {
			var volumes = (response && response.volumes) || [];
			var pick = null, master = null;
			$.each(volumes, function(i, v) {
				var stream = String(v.stream || '').toLowerCase();
				if (stream == 'music') { pick = v; }
				else if (stream == 'master') { master = v; }
			});
			if (!pick) { pick = master; }
			var max = pick ? parseFloat(pick.max_volume) : 0;
			var raw = pick ? parseFloat(pick.volume) : NaN;
			if (!pick || !max || isNaN(raw)) {
				musicSystemWired = false;
				musicSystemStream = '';
				return;
			}
			var was_wired = musicSystemWired;
			musicSystemWired = true;
			musicSystemStream = pick.stream;
			musicSystemMax = max;
			var level = raw / max;
			// Only touch the player when the level actually moved: an OS mixer read
			// every few seconds must not repaint the bar, the icon and the media
			// element for a level that has not changed.
			if (!adopt && was_wired && Math.abs(level - musicSystemLevel) < 0.001) { return; }
			// the element is only a pass-through while the mixer is the level
			if (adopt || !was_wired) { master_volume = 1; }
			musicSystemVolumePaint(level, false);
		},
		error: function() { /* leave the player level in place */ }
	});
}
function musicSystemVolumeWatch() {
	clearInterval(musicSystemInterval);
	musicSystemInterval = setInterval(function() {
		// no point reading a hidden or background window's mixer; the next open
		// reads it again. On the desk, a window that is not at the front is being
		// read behind whatever the person is using, so leave it alone too.
		if (document.hidden || !$('#music_volume').is(':visible')) { return; }
		if (typeof windowPhoneChecker == 'function' && !windowPhoneChecker()
			&& typeof windowIsFront == 'function' && !windowIsFront($('#music').closest('.wind'))) { return; }
		musicSystemVolumePoll(false);
	}, 5000);
}
// The volume slider sets the level to play back at; mute silences without losing
// it. Both go through musicVolumeApply() so the element and the icon agree.
$(document).on('input', '#music_volume', function() {
	musicVolumeSet(this.value);
});
// A wheel or a two-finger trackpad scroll over either bar moves it: up/forward
// for volume and the seek, down/back the other way. A wheel notch is about
// 100px; a trackpad sends a stream of smaller deltas, so the same arithmetic
// gives a fine nudge there and a whole step on a mouse wheel. The seek bar also
// takes a sideways two-finger swipe, which reads as forward and back.
function musicWheelAmount(e, sideways) {
	var ev = e.originalEvent || e;
	var dx = ev.deltaX || 0;
	var dy = ev.deltaY || 0;
	var amount;
	if (sideways && Math.abs(dx) > Math.abs(dy)) {
		amount = dx;
	}
	else if (ev.deltaY != undefined) {
		amount = -dy;
	}
	else if (ev.wheelDelta != undefined) {
		amount = ev.wheelDelta;
	}
	else { return 0; }
	if (ev.deltaMode == 1) { amount = amount * 16; }
	else if (ev.deltaMode == 2) { amount = amount * 400; }
	return amount / 100;
}
// A trackpad sends a stream of small pixel deltas, while a wheel sends one
// notch (about 100 px). The same per-pixel arithmetic made a two-finger flick
// race through the track (or the volume); fine mode is a fraction of a notch
// per event.
function musicWheelFine(e) {
	var ev = e.originalEvent || e;
	return ev.deltaMode == 0 && Math.abs(ev.deltaY || 0) < 60 && Math.abs(ev.deltaX || 0) < 60;
}
var musicSeekTarget = null;
var musicSeekRaf = 0;
function musicSeekBy(seconds) {
	if (!tree || !tree.sound || !isFinite(tree.sound.duration) || !tree.sound.duration) { return; }
	// a trackpad sends a stream of small deltas: accumulate them and seek once a
	// frame, or a long scroll decodes a frame per event and the picture stutters
	var base = (musicSeekTarget == null) ? (tree.sound.currentTime || 0) : musicSeekTarget;
	musicSeekTarget = Math.max(0, Math.min(tree.sound.duration, base + seconds));
	var to = musicSeekTarget;
	// move the visible bar at once; the playing interval tells a remote output
	// about the jump in its usual drift check
	var m = $('#video').attr('miss');
	if (m) { $('#' + m + '_position').val(to / tree.sound.duration * 100); }
	$('#elapsed_progress').text(numeral(to).format('00:00:00'));
	if (musicSeekRaf) { return; }
	musicSeekRaf = requestAnimationFrame(function() {
		musicSeekRaf = 0;
		var target = musicSeekTarget;
		musicSeekTarget = null;
		if (target != null) { tree.sound.currentTime = target; }
	});
}
$(document).on('wheel', '#music_volume', function(e) {
	var amount = musicWheelAmount(e, false);
	if (!amount) { return; }
	e.preventDefault();
	e.stopPropagation();
	var scale = musicWheelFine(e) ? 0.35 : 1;
	musicVolumeSet(musicVolumeLevel() + amount * 0.04 * scale);
});
$(document).on('wheel', '.music_seek', function(e) {
	var amount = musicWheelAmount(e, true);
	if (!amount || !tree || !tree.sound || !isFinite(tree.sound.duration) || !tree.sound.duration) { return; }
	e.preventDefault();
	e.stopPropagation();
	// one notch is one percent of the track, kept between half a second and
	// fifteen seconds so a song and a long film both feel right
	var step = Math.max(0.5, Math.min(15, tree.sound.duration * 0.01));
	var scale = musicWheelFine(e) ? 0.08 : 1;
	musicSeekBy(amount * step * scale);
});
$(document).on('change', '#music_normalize_select', function() {
	music_normalize = $(this).val() || 'off';
	$('#music').attr('normalize', music_normalize);
	musicNormalizeApply();
	// the graph is captured on this gesture; put the element's level and mute
	// state back in step in case a track change left them at the handshake value
	musicVolumeApply();
	settingSetter({ 'app': 'music', 'setting': 'normalize', 'value': music_normalize });
});
$(document).on('change', '#music_stream_codec', function() {
	music_stream_codec = $(this).val() || 'pcm';
	$('#music').attr('stream_codec', music_stream_codec);
	settingSetter({ 'app': 'music', 'setting': 'stream_codec', 'value': music_stream_codec });
	if (!musicStream.active) { return; }
	musicStreamRestart();
});
$(document).on('click', '#music_mute', function() {
	music_muted = !music_muted;
	musicVolumeApply();
	updateMusicMuteIcon();
});

$(document).on('click', '.music_artist', function(e) {
	if (e.originalEvent.ctrlKey == true) {
		if ($(this).attr('active') == 'yes') {
			$(this).attr('active', 'no');
		}
		else {
			$(this).attr('active', 'yes');
		}
	}
	else {
		if ($(this).attr('active') == 'yes') {
			$('.music_artist').attr('active', 'no');
		}
		else {
			$('.music_artist').attr('active', 'no');
			$(this).attr('active', 'yes');
		}
	}
	searchMusic({ source: 'artist' });
});

$(document).on('click', '.music_album', function(e) {
	if (e.originalEvent.ctrlKey == true) {
		if ($(this).attr('active') == 'yes') {
			$(this).attr('active', 'no');
		}
		else {
			$(this).attr('active', 'yes');
		}
	}
	else {
		if ($(this).attr('active') == 'yes') {
			$('.music_album').attr('active', 'no');
		}
		else {
			$('.music_album').attr('active', 'no');
			$(this).attr('active', 'yes');
		}
	}
	searchMusic({ source: 'album' });
});

function searchMusic(data) {
	if (typeof data != 'object') { data = {}; }
	var searching = data['search'];
	var list = data['list'] || [];
	var same_order = data['same_order'];
	var new_settings = data['new_settings'];
	var source = data['source'];
	var library = data['library'];
	if (new_settings) {
		new_settings = JSON.stringify(new_settings);
	}
	var artist = [];
	$('.music_artist').each(function(i,v) {
		if ($(v).attr('active') == 'yes') {
			artist.push({ 'artist': $(v).attr('artist'), 'path': $(v).attr('path') });
		}
	});
	var album = [];
	$('.music_album').each(function(i,v) {
		if ($(v).attr('active') == 'yes') {
			album.push({ 'album': $(v).attr('album'), 'path': $(v).attr('path') });
		}
	});
	artist = JSON.stringify(artist);
	album = JSON.stringify(album);

	// the shelves are vertical lists on the desktop but sideways-scrolling
	// strips on a phone, so the position to hold across the re-render is on both
	// axes - a selection used to jump the strips back to the start
	var artistScroll = { top: $('#music_artists').scrollTop(), left: $('#music_artists').scrollLeft() };
	var albumScroll = { top: $('#music_albums').scrollTop(), left: $('#music_albums').scrollLeft() };


	var search = searching || $('#music_search').val();
	var unlock = $('#music').attr('unlock');
	$('body').css({ 'cursor': 'progress' });
	// a search swaps the track list; dim it (and drop the pointer) until the reply
	// lands, so the stale rows cannot be clicked in the meantime
	$('#music_files').addClass('music_loading');
	var folders = musicFolderChecker();
	var nowPlaying = {};
	if (tree.sound) {
		if (tree.sound.state == 1) {
			nowPlaying = tree.songs[0];
		}
	}
	var jnowPlaying = JSON.stringify(nowPlaying);
	var jlist = JSON.stringify(list);
	var resizes = musicWindowResizes();
	var jresizes = JSON.stringify(resizes);
	var jmiss = JSON.stringify(misses);
	var theatreMode =	$('#video').attr('theatre_mode');
	$.ajax({
		url: '/music/search',
		type: 'POST',
		data: { 
			search: search, 
			window_maker: 'yes', 
			library: library,
			folders: folders, 
			artist: artist, 
			album: album, 
			unlock: unlock, 
			device_uuid: (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : '',
			browser_tab_id: (typeof jawnosMediaTab === 'function') ? jawnosMediaTab() : '',
			now_playing: jnowPlaying, 
			list: jlist, 
			same_order: same_order, 
			new_settings: new_settings,
			resizes: jresizes,
			misses: jmiss
		},
		success: function(response) {
			clearInterval(vidControls['video_video_interval']);

			var v = document.getElementById('video');
			var timestamp = Date.now();
			var state = v.state;
			// A search only ever changes the library lists (and, on a library
			// switch, the configuration panel). Swapping just those keeps the
			// player and the rest of the window untouched: no flash, and the
			// <video> element is never destroyed, so playback is not interrupted.
			var fragment = $('<div></div>').html(response.html);
			var in_place = fragment.find('#music_files').length > 0 && $('#music_files').length > 0;
			// a full render would tear the <video> down; park a loaded one first
			var keep_video = !!v.src;
			var parking = $('#temporary_workspace');
			if (!parking.length) {
				parking = $('<div style="display:none;"></div>').appendTo('body');
			}

			treeMaker();

			var configOpen = $('#music_configuration').is(':visible');
			if (in_place) {
				// the list elements come back fresh, so musicInit rebuilds their
				// jQuery UI resizable state below
				$('#music_artists').replaceWith(fragment.find('#music_artists'));
				$('#music_albums').replaceWith(fragment.find('#music_albums'));
				$('#music_files').replaceWith(fragment.find('#music_files'));
				var new_music = fragment.find('#music');
				var new_unlock = new_music.attr('unlock');
				if (new_unlock !== undefined) {
					$('#music').attr('unlock', new_unlock);
				}
				// the configuration panel carries the library's own controls and
				// its remote_uuid, so it moves with a library switch
				if (fragment.find('#music_configuration').length) {
					$('#music_configuration').replaceWith(fragment.find('#music_configuration'));
				}
			}
			else {
				if (keep_video) {
					// out of the window before the render...
					parking.append(v);
				}
				windowMaker(response.html);
				if (keep_video) {
					// ...and back into the fresh .media_window, replacing the empty
					// <video> the render produced
					var fresh = $('#music').find('#video');
					if (fresh.length) {
						fresh[0].replaceWith(v);
					}
					else {
						$('#music').find('.media_window').append(v);
					}
				}
			}
			$.each(response.artist, function(i,v) {
				$('.music_artist[artist="' + v.artist + '"][path="' + v.path + '"]').attr('active', 'yes');
			});
			$.each(response.album, function(i,v) {
				$('.music_album[album="' + v.album + '"][path="' + v.path + '"]').attr('active', 'yes');
			});
			
			if (state == 1) {
				var v = document.getElementById('video');
				v.state = 1;
				var playing = $('.playing');
				// the media element is the one that has been playing all along, so
				// its src, position and style need no restore
				$('#video').attr('type', nowPlaying['type']);
				if (nowPlaying['type'] == 'audio') {
					$('#video').hide();
				}
				else {
					$('#video').show();
				}
				tree.current_track = playing.attr('number');
				musicVolumeApply();
				thisTrack(playing.closest('.track_item'));
				mediaMaker({ src: v.src, currentTime: v.currentTime, method: 'benign', timestamp: timestamp });
				var html = $('#music').parent().html();
				musicContentCache(html);
			}
			else {
				$('#video').hide();
			}
			playing_now('update');

			$('#music_albums').scrollTop(albumScroll.top).scrollLeft(albumScroll.left);
			$('#music_artists').scrollTop(artistScroll.top).scrollLeft(artistScroll.left);
			musicInit('search');

			if (configOpen == true) {
				musicConfigShow($('#music_configuration'));
			}
			if (theatreMode == 'on') {
				theatreModeOn();
			}
		},
		complete: function() {
			// however the search ended (even a dropped connection), put the cursor
			// and the track list back
			$('body').css({ 'cursor': 'auto' });
			$('#music_files').removeClass('music_loading');
		}
	});
}

function playing_now(movement) {
	if (movement != 'update') {
		musicAppointmentWriter('stop');
		$('.playing').removeClass('playing');
	}
	$('#track_' + tree.current_track).parent().addClass('playing');
	$('.track_description').each(function() { $(this).hide() });
	$('#track_' + tree.current_track).parent().find('.track_description').show();

	return tree.current_track;

}

function musicFolderChecker() {
	var folders = [];
	$('.music_folder_toggle[status="on"]').each(function(i,v) {
		folders.push($(v).attr('location'));
	});
	return folders;
}

$(document).on('click', '.music_folder_toggle', function() {
	var b = $(this);
	var status = b.attr('status');
	var location = b.attr('location');
	var timestamp = Date.now();
	if (status == 'on') {
		status = 'off';
	}
	else {
		status = 'on';
	}
	$.ajax({
		url: '/music/folder_toggle',
		type: 'POST',
		data: { timestamp: timestamp, location: location, status: status },
		success: function(response) {
			b.attr('status', response);
			if (response == 'on') {
				b.css({'background-color': 'lightblue'});
			}
			else {
				b.css({'background-color': ''});
			}
			searchMusic();
		}
	});
});

$(document).on('click', '.music_archive_toggle', function() {
	var b = $(this);
	var status = b.attr('status');
	if (status == 'on') {
		status = 'off';
	}
	else {
		status = 'on';
	}
	$.ajax({
		url: '/music/archive_toggle',
		type: 'POST',
		data: { timestamp: Date.now(), status: status },
		success: function (response) {
			b.attr('status', response);
			if (response == 'on') {
				b.css({'background-color': 'lightblue'});
			}
			else {
				b.css({'background-color': ''});
			}
			searchMusic();
		}
	});
});

$(document).on('click', '.music_lock', function() {
	if ($('#music').attr('unlock')) {
		$('#music').attr('unlock', undefined);
		tree.sound = undefined;
		$('#music_search').val('');
		$('.music_artist').attr('active', 'no');
		$('.music_album').attr('active', 'no');
		var wt = $('.wind[app="video"]').attr('timestamp');
		closeWindow(wt);
		if (typeof jawnosMediaLockApp === 'function') {
			jawnosMediaLockApp('music', function () { searchMusic(); });
		}
		else { searchMusic(); }
	}
	else if ($('#music').is(':visible')) {
		$('#music').hide();
		$('#music_padlock').show();
		if (typeof padlockAskPhone === 'function') { padlockAskPhone('music'); }
	}
	else {
		$('#music').show();
		$('#music_padlock').hide();
	}
});

$(document).on('click', '#music_cancel_padlock', function() {
	$('#music').show();
	$('#music_padlock').hide();
});

$(document).on('click', '.music_shuffle', function() {
	var shuffle = $(this).attr('enabled');
	if (shuffle == 'on') {
		shuffle = 'off';
	}
	else {
		shuffle = 'on';
	}
	$(this).attr('enabled', shuffle);

	var list = [];
	$.each(tree.files, function(i,v) {
		list.push($(v).text());
	});
	searchMusic({ list: list, same_order: 0, new_settings: { 'shuffle': shuffle } });

});

$(document).on('click', '#music_layout_select', function() {
	var layout = $(this).val();
	var list = [];
	$.each(tree.files, function(i,v) {
		list.push($(v).text());
	});
	searchMusic({ list: list, same_order: 1, new_settings: { 'layout': layout } });

});


$(document).on('change', '#music_library_select', function() {
	var library = $(this).val();
	// clear the artist/album picks: they were folds of the old library, and
	// their stored paths would be scanned (and found empty) at the new one
	$('.music_album').attr('active', 'no');
	$('.music_artist').attr('active', 'no');
	// the choice goes with the search, in one request - written separately it
	// raced the search, and the search could relay to the old machine again
	searchMusic({ library: library });
});

$(document).on('click', '.music_repeat', function() {
	var repeat = $(this).attr('enabled');
	if (repeat == 'on') {
		repeat = 'off';
	}
	else {
		repeat = 'on';
	}
	settingSetter({ app: 'music', setting: 'repeat', value: repeat });
	$(this).attr('enabled', repeat);
});


$(document).on('click', '.music_audio_output_select', function() {
	var output = $(this).val();
	var side = $(this).attr('channel')
		|| ($(this).hasClass('music_output_left') ? 'left'
			: ($(this).hasClass('music_output_right') ? 'right' : 'center'));
	var current = mao[output];
	var state;
	// The centre is stereo. The two sides are one speaker each. Pressing the
	// state that is already on turns that output off; pressing the other side
	// moves it there; pressing centre while a side is on makes it stereo.
	if (side == 'center') {
		state = (musicOutputChannel(current) == 'stereo') ? 'off' : 'on';
	}
	else {
		state = (musicOutputChannel(current) == side) ? 'off' : side;
	}
	var file = (tree && tree.songs && tree.songs[0]) ? tree.songs[0].file : '';
	var seek = (tree && tree.sound) ? tree.sound.currentTime : 0;
	var remote = (output != 'me' && output != 'srv');
	musicOutputPaint(output, state);
	// the server player is a single on/off chip, not a group of three
	if (!$(this).closest('.music_output_group').length) { $(this).attr('state', state == 'on' ? 'on' : 'off'); }
	// the setting is written first, so the stream sees the new output list
	// when it starts or re-announces
	mao[output] = state;
	if (remote) {
		if (musicStream.active) {
			if (musicStream.codec == 'opus') {
				// every decoder needs the new output set's header
				setTimeout(musicStreamRestart, 0);
			}
			else {
				musicStreamOutputsChanged();
			}
		}
		else if (musicOutputOn(state) && tree.sound.state == 1) {
			remoteTrackToggle({ file: file, toggle: 'on', seek: seek });
		}
		else if (!musicStreamOutputs().length) {
			musicStreamStop();
		}
	}
	else {
		// a one-sided local output needs the shared graph even when nothing else
		// (normalisation, a visualiser, a remote tap) has asked for it yet
		if (musicOutputChannel(mao['me']) == 'left' || musicOutputChannel(mao['me']) == 'right') {
			try { musicAudioGraph(); } catch (e) {}
		}
		musicVolumeApply();
		updateMusicMuteIcon();
	}
	$.ajax({
		url: '/music/audio_output_select',
		type: 'POST',
		data: { state: state, output: output },
		success: function(response) {
			mao = response;
			$.each(mao, function(k, v) { musicOutputPaint(k, v); });
			musicVolumeApply();
			updateMusicMuteIcon();
		}
	});
});

// Repaint one output group's three buttons from the state it now wears.
function musicOutputPaint(output, state) {
	var group = $('.music_output_group[value="' + output.replace(/"/g, '\\"') + '"]');
	var channel = musicOutputChannel(state);
	group.find('.music_output_left').attr('state', channel == 'left' ? 'left' : 'off');
	group.find('.music_output_center').attr('state', channel == 'stereo' ? 'on' : 'off');
	group.find('.music_output_right').attr('state', channel == 'right' ? 'right' : 'off');
	group.attr('state', channel || 'off');
}

$(document).on('click', '#music_configuration_close', function(e) {
	e.preventDefault();
	$('#music_configuration').hide();
});

function musicEqualizerFromEqualizer(eq) {
	if (!eq) { return false; }
	var bands = eq.bands || [];
	for (var i = 0; i < music_eq_freqs.length; i++) {
		music_equalizer.bands[i] = musicEqualizerClampBand(bands[i]);
	}
	music_equalizer.bass = musicEqualizerClampBass(eq.bass);
	music_equalizer.preset = eq.preset || 'flat';
	musicEqualizerPaint();
	return true;
}
// The drawer is fetched from this machine, not the library host: its outputs,
// format, sync trim, normalization and equalizer are local settings. The first
// open also gives the equalizer to a page that has not shown the drawer yet, so
// a saved curve is in place before playback starts.
function musicSyncOffsetRead() {
	var el = $('#music_sync_offset');
	if (el.length) {
		var v = parseFloat(el.val());
		if (isFinite(v)) { music_sync_offset = Math.max(-300, Math.min(500, v)); }
		el.val(music_sync_offset);
	}
	$('#music_sync_offset_value').text(music_sync_offset + ' ms');
}
function musicSyncOffsetSave() {
	clearTimeout(music_sync_save_timer);
	music_sync_save_timer = setTimeout(function() {
		settingSetter({ app: 'music', setting: 'sync_offset', value: music_sync_offset });
	}, 250);
}
$(document).on('input', '#music_sync_offset', function() {
	var v = parseFloat(this.value);
	if (isFinite(v)) { music_sync_offset = Math.max(-300, Math.min(500, v)); }
	musicSyncOffsetRead();
	musicAheadRetarget();
	musicSyncOffsetSave();
});

function musicAudioPanelLoad(show) {
	var panel = $('#music_audio_panel');
	if (!panel.length) { return; }
	// the drawer floats over the theatre picture like the configuration sheet
	if (show) { musicConfigShow(panel); }
	if (music_audio_loading) { return; }
	music_audio_loading = true;
	$.ajax({
		url: '/music/audio',
		type: 'GET',
		dataType: 'json',
		cache: false,
		success: function(r) {
			if (!r || !r.html) { return; }
			// the drawer belongs to this machine, including the output list
			if (r.mao) { mao = r.mao; }
			panel.html(r.html);
			if (!musicEqualizerFromEqualizer(r.equalizer)) { musicEqualizerLoad(); }
			musicSyncOffsetRead();
			if (musicEqualizerDirty() && !(musicVisual && musicVisual.limiter)) {
				try { musicAudioGraph(); } catch (e) {}
			}
			musicEqualizerApply();
			$.each(mao, function(k, v) { musicOutputPaint(k, v); });
		},
		error: function() { /* keep whatever the drawer already holds */ },
		complete: function() { music_audio_loading = false; }
	});
}

$(document).on('click', '#music_audio_toggle', function() {
	var panel = $('#music_audio_panel');
	if (panel.is(':visible')) { panel.hide(); return; }
	// the configuration sheet is left alone: both can be open at once
	musicAudioPanelLoad(true);
});

$(document).on('click', '#music_audio_close', function(e) {
	e.preventDefault();
	$('#music_audio_panel').hide();
});

$(document).on('click', '#music_configuration_toggle', function() {
	var mc = $('#music_configuration');
	var remote_uuid = mc.attr('remote_uuid');
	if (mc.is(':visible')) {
		mc.hide();
	}
	else {
		// the Audio sheet is left alone: both can be open at once
		musicConfigShow(mc);
		$.ajax({
			url: '/music/configuration',
			type: 'GET',
			// The drawer is rebuilt from the server on every open. Do not let the
			// browser answer from its cache: after a code sync it kept showing an
			// output list that no longer existed.
			cache: false,
			// name the loaded remote library so the panel can show it as the
			// current selection instead of losing it
			data: { remote_uuid: remote_uuid },
			success: function(response) {
				mc.html(response.html);
				volumeChecker();
			}
		});
	}
});

$(document).on('click', '.all_music', function() {
	var library = $(this).attr('library');
	var enabled = $(this).attr('enabled');
	if (enabled == 'yes') {
		enabled = 'no';
	}
	else {
		enabled = 'yes';
	}
	$(this).attr('enabled', enabled);
	var setting = 'all_' + library;
	var new_settings = {};
	new_settings[setting] = enabled;
	searchMusic({ 'new_settings': new_settings });
});

// ---- the visualiser ---------------------------------------------------------
//
// An audio file has no picture, so the player draws the sound instead - on a
// canvas that is never itself seen: the drawing is handed to a muted video as
// its stream (canvas.captureStream), and that video wears the player's own
// picture styles. The sound's picture therefore reaches the player the way a
// video track's does: the corner thumbnail while the library is up, the whole
// player in the theatre or in fullscreen. The four drawings are the dropdown in
// the tools panel (None leaves the player to its album cover); the choice rides
// in the player cache like theatre_mode.
//
// The sound is tapped with the Web Audio API. An element can only be captured
// once, so the graph is made lazily and then kept for the page: source ->
// normaliser -> makeup gain -> limiter -> analyser -> destination. The element
// still behaves as it normally would, so volume, mute, seeking and src changes
// all still do what they did - what you hear is what is drawn. The normaliser
// and the visualiser share this one graph: a second createMediaElementSource on
// the same element throws, and whichever of the two asked first would take the
// sound with it.

var musicVisual = {
	mode: 'none',
	ctx: null,
	el: null,
	source: null,
	analyser: null,
	compressor: null,
	makeup: null,
	limiter: null,
	leveler: null,
	localGain: null,
	remoteGain: null,
	localSplit: null,
	localLeft: null,
	localRight: null,
	localMerge: null,
	graphLatency: 0,
	eqFilters: null,
	eqBass: null,
	freq: null,
	raf: 0,
	last: 0,
	resumeAt: 0,
	canvas: null,
	feedCanvas: null,
	stream: null,
	painted: null,
	peaks: [],
	dots: [],
	dotW: 0,
	dotH: 0,
	art: null,
	st: null
};

function musicVisualState() {
	if (!musicVisual.st) {
		musicVisual.st = { t: 0, bass: 0.05, mid: 0.05, treble: 0.05, level: 0.05, centroid: 0.1, avg: 0.05, beat: false, lastBeat: -1, hue: 0 };
	}
	return musicVisual.st;
}

// Fullscreen for the player, the way the picture needs it: the whole player
// goes fullscreen, not the <video> element. A fullscreened <video> is the
// browser's own media element, so moving the mouse over it brings the browser's
// controls and never the player's: those are siblings of the element and so
// outside the fullscreen element. Taking the player instead puts #interface and
// the transport (with the dropdown that chooses the visualisation) inside it,
// and the video include's own mousemove handler brings them in and out as it
// does in the theatre. The sound's picture, the visualiser's video, rides along
// the same way.
function musicPlayerFullscreen() {
	var v = document.getElementById('video');
	if (!v) { return; }
	// the button (and F) is a toggle: a second press leaves fullscreen
	var fs = document.fullscreenElement || document.webkitFullscreenElement;
	if (fs) {
		var out = document.exitFullscreen ? document.exitFullscreen()
			: (document.webkitExitFullscreen ? document.webkitExitFullscreen() : null);
		if (out && out.catch) { out.catch(function () {}); }
		return;
	}
	if (v.getAttribute('type') == 'video') {
		$(v).show();
	}
	else {
		$(v).hide();
	}
	var target = document.getElementById('music') || v;
	var p = target.requestFullscreen ? target.requestFullscreen()
		: (target.webkitRequestFullscreen ? target.webkitRequestFullscreen() : null);
	if (p && p.catch) { p.catch(function () {}); }
}

// The stream tap is a per-context worklet node. It is dropped when the window
// parks, and the next stream builds a fresh one in the same context.
function musicStreamTapForget() {
	if (musicStreamTap.node) { try { musicStreamTapSource('local'); } catch (e) {} }
	if (musicStreamTap.node) {
		try { musicStreamTap.node.disconnect(); } catch (e) {}
		musicStreamTap.node = null;
	}
	if (musicStreamTap.sink) {
		try { musicStreamTap.sink.disconnect(); } catch (e) {}
		musicStreamTap.sink = null;
	}
	musicStreamTap.ready = false;
	musicStreamTap.loading = null;
}
// Take the element (and the tap) out of the graph entirely, for a close or a
// real unload.
function musicAudioDetach() {
	if (typeof musicVisual == 'undefined' || !musicVisual) { return; }
	if (musicVisual.source) {
		try { musicVisual.source.disconnect(); } catch (e) {}
		musicVisual.source = null;
	}
	musicVisual.el = null;
	musicStreamTapForget();
}
// Closing the window or leaving the page closes the AudioContext, which is what
// releases its Pulse stream. (The streams that accumulated were the unused
// contexts treeMaker used to make on every re-render; see treeMaker.)
function musicAudioClose() {
	if (typeof musicVisual == 'undefined' || !musicVisual || !musicVisual.ctx) { return; }
	musicStreamStop();
	musicAheadForget();
	musicAudioDetach();
	var ctx = musicVisual.ctx;
	try { ctx.close(); } catch (e) {}
	musicVisual.ctx = null;
	musicVisual.analyser = null;
	musicVisual.compressor = null;
	musicVisual.leveler = null;
	musicVisual.makeup = null;
	musicVisual.limiter = null;
	musicVisual.localGain = null;
	musicVisual.remoteGain = null;
	musicVisual.localSplit = null;
	musicVisual.localLeft = null;
	musicVisual.localRight = null;
	musicVisual.localMerge = null;
	musicVisual.graphLatency = 0;
	musicVisual.eqFilters = null;
	musicVisual.eqBass = null;
}
// Resume the audio context and, once it is running, finish a graph that was
// deferred while it was stopped. Returns the context state after the attempt.
function musicAudioResume() {
	var ctx = musicVisual.ctx;
	if (!ctx) { return null; }
	if (ctx.state == 'suspended' || ctx.state == 'interrupted') {
		var now = Date.now();
		if (now - musicVisual.resumeAt > 300) {
			musicVisual.resumeAt = now;
			var p = null;
			try { p = ctx.resume(); } catch (e) { return ctx.state; }
			// the capture waits for a running context; finish it once resume lands
			if (p && p.then) {
				p.then(function () {
					if (musicVisual.ctx && musicVisual.ctx.state == 'running') {
						musicAudioGraph();
						musicBaselineApply();
						// the first play can build the context before it is running; the
						// stream's tap attach then failed and needs another look
						if (musicStream.active && !musicStream.attached) {
							musicStreamStart(tree.songs[0] ? tree.songs[0].file : '', tree.sound ? tree.sound.currentTime : 0);
						}
					}
				}).catch(function () {});
			}
		}
	}
	return ctx.state;
}
// The player's audio graph: made on first use and kept for the page. An element
// can only be captured once, and the graph has to stay in place or the sound
// goes with it. A re-opened window hands back a fresh element, so only the
// element's source is replaced; the rest of the chain (and the context, and so
// its single Pulse stream) stays.
function musicAudioGraph() {
	var el = document.getElementById('video');
	if (!el) { return null; }
	if (!musicVisual.ctx || musicVisual.ctx.state == 'closed') {
		// the ahead element and its chain belong to the old context
		musicAheadForget();
		var Ctor = window.AudioContext || window.webkitAudioContext;
		if (!Ctor) { return null; }
		// 44.1 kHz: the Termux phones and tablets use an OpenSL sink at 44100, and
		// handing them 48000 made PulseAudio resample and buffer (a high-quality
		// video's 48 kHz audio arrived about a second late). A 48 kHz desk sink
		// resamples the other way, with a far smaller buffer.
		try { musicVisual.ctx = new Ctor({ sampleRate: 44100, latencyHint: 'interactive' }); }
		catch (e) { try { musicVisual.ctx = new Ctor(); } catch (e2) { return null; } }
		musicVisual.graphLatency = 0;
		musicVisual.eqFilters = null;
		musicVisual.eqBass = null;
		musicVisual.source = null;
		musicVisual.el = null;
		musicVisual.analyser = null;
		musicVisual.compressor = null;
		musicVisual.leveler = null;
		musicVisual.makeup = null;
		musicVisual.limiter = null;
		musicVisual.localGain = null;
		musicVisual.remoteGain = null;
		musicVisual.localSplit = null;
		musicVisual.localLeft = null;
		musicVisual.localRight = null;
		musicVisual.localMerge = null;
	}
	// A MediaElementSource takes the element's sound away from the page and into
	// the graph. Capturing while the context is stopped is silence with no direct
	// path back, so the capture waits until the context is actually running; the
	// resume above re-enters here once it is.
	var state = musicAudioResume();
	if (!musicVisual.source && state != 'running') { return null; }
	// Build the chain once per context. A closed window leaves it in place; the
	// next element only needs a new source in front of it.
	if (!musicVisual.limiter) {
		try {
			musicVisual.compressor = musicVisual.ctx.createDynamicsCompressor();
			musicVisual.leveler = musicVisual.ctx.createGain();
			musicVisual.makeup = musicVisual.ctx.createGain();
			musicVisual.limiter = musicVisual.ctx.createDynamicsCompressor();
			musicVisual.analyser = musicVisual.ctx.createAnalyser();
			musicVisual.analyser.fftSize = 2048;
			musicVisual.analyser.smoothingTimeConstant = 0.82;
			// The local output has its own gain. It keeps the element at full
			// level, so the remote tap (taken at the limiter) still hears the
			// track while this machine is muted or `me` is off.
			musicVisual.localGain = musicVisual.ctx.createGain();
			musicVisual.remoteGain = musicVisual.ctx.createGain();
			musicVisual.remoteGain.gain.value = musicRemoteVolume();
			musicVisual.localSplit = musicVisual.ctx.createChannelSplitter(2);
			musicVisual.localLeft = musicVisual.ctx.createGain();
			musicVisual.localRight = musicVisual.ctx.createGain();
			musicVisual.localMerge = musicVisual.ctx.createChannelMerger(2);
			// The equalizer sits after the leveller and before the limiter, so the
			// peak guard still catches a boosted band and the remote tap hears the
			// same curve as this machine. A flat curve is 0 dB on every filter.
			musicVisual.eqFilters = [];
			var eq_prev = musicVisual.makeup;
			for (var eq_i = 0; eq_i < music_eq_freqs.length; eq_i++) {
				var eq_f = musicVisual.ctx.createBiquadFilter();
				eq_f.type = 'peaking';
				eq_f.frequency.value = music_eq_freqs[eq_i];
				eq_f.Q.value = 1.1;
				eq_f.gain.value = 0;
				eq_prev.connect(eq_f);
				eq_prev = eq_f;
				musicVisual.eqFilters.push(eq_f);
			}
			musicVisual.eqBass = musicVisual.ctx.createBiquadFilter();
			musicVisual.eqBass.type = 'lowshelf';
			musicVisual.eqBass.frequency.value = 90;
			musicVisual.eqBass.gain.value = 0;
			eq_prev.connect(musicVisual.eqBass);
			musicVisual.eqBass.connect(musicVisual.limiter);
			musicVisual.compressor.connect(musicVisual.leveler);
			musicVisual.leveler.connect(musicVisual.makeup);
			musicVisual.limiter.connect(musicVisual.localGain);
			musicVisual.limiter.connect(musicVisual.remoteGain);
			musicVisual.localGain.connect(musicVisual.analyser);
			musicVisual.analyser.connect(musicVisual.localSplit);
			musicVisual.localSplit.connect(musicVisual.localLeft, 0);
			musicVisual.localSplit.connect(musicVisual.localRight, 1);
			musicVisual.localLeft.connect(musicVisual.localMerge, 0, 0);
			musicVisual.localRight.connect(musicVisual.localMerge, 0, 1);
			musicVisual.localMerge.connect(musicVisual.ctx.destination);
			musicEqualizerApply();
		}
		catch (e) {
			musicVisual.limiter = null;
			return null;
		}
	}
	if (musicVisual.el !== el || !musicVisual.source) {
		if (state != 'running') { return null; }
		if (musicVisual.source) { try { musicVisual.source.disconnect(); } catch (e) {} }
		musicVisual.source = null;
		try {
			musicVisual.source = musicVisual.ctx.createMediaElementSource(el);
			musicVisual.source.connect(musicVisual.compressor);
		}
		catch (e) {
			musicVisual.source = null;
			return null;
		}
		musicVisual.el = el;
		musicNormalizeParams();
		musicBaselineApply();
		musicVolumeApply();
		if (musicStreamTap.node) { musicStreamTapSource(musicAhead.ready ? 'ahead' : 'local'); }
	}
	// a stream that started before the graph existed (a context resumed on the
	// first play) gets its ahead tap once the chain is here
	if (musicStream.active) { musicAheadStart(); }
	return musicVisual;
}

// ---- whole-track measurement ------------------------------------------------
// The house reference is about -15 dB. The loud material sits at or above it
// (LrgMeal -7.5, Lucerin Blue -13.2) and the shows sit far below (Scrubs -25.8,
// Doctor Who -35.0). A loud track is never turned down; a quiet one is raised.
// Inside the track a slow leveller lifts the quiet passages rather than following
// every line of dialogue, so the gap between dialogue and action closes without
// the pumping a per-second AGC produced.
var musicBaseline = { src: '', mean: null, max: null, gain: 1, failed: false, token: 0 };
var musicBaselineCache = {};
var musicBaselinePending = {};
var musicBaselineSettings = {
	slight:     { target: -15, factor: 0.5,  max: 8 },
	mild:       { target: -15, factor: 0.75, max: 14 },
	aggressive: { target: -15, factor: 1,    max: 18 }
};
// The in-track leveller. `window` is the top slice of the track's range that is
// compressed and `ratio` turns it into a reduction. The makeup equals the
// reduction at the peak, so the action keeps its own level and only the quieter
// dialogue comes up. A very quiet film gets a wider window (see
// musicLevellerWindow): its average is mostly room tone and dialogue, so the
// top slice has to reach further down for the makeup to make it audible.
var musicLevellerSettings = {
	slight:     { window: 6,  ratio: 2.0 },
	mild:       { window: 10, ratio: 2.5 },
	aggressive: { window: 14, ratio: 3.5 }
};
function musicBaselineConf() {
	return musicBaselineSettings[music_normalize] || musicBaselineSettings.mild;
}
function musicLevellerConf() {
	return musicLevellerSettings[music_normalize] || null;
}
function musicLevellerWindow(conf, mean) {
	var base = conf.window;
	if (mean == null) { return base; }
	// 0 at -32 dB, 1 at -38 dB: music and ordinary shows keep the base window,
	// while a film far below the house level widens up to 80% more.
	var quiet = Math.max(0, Math.min(1, (-32 - mean) / 6));
	return base + (base * 0.8) * quiet;
}
function musicLevellerMakeupDb(mean) {
	var conf = musicLevellerConf();
	if (!conf) { return 0; }
	var window = musicLevellerWindow(conf, mean);
	return window * (1 - 1 / conf.ratio);
}
// What the track's average becomes once the leveller has run: the makeup lifts
// every passage while the compressed top slice is pulled back. The track gain is
// chosen from that figure, so the in-track lift is not counted twice.
function musicLevelledMean(mean, max) {
	var conf = musicLevellerConf();
	if (!conf || mean == null) { return mean; }
	var window = musicLevellerWindow(conf, mean);
	if (max == null) { max = mean + window; }
	var crest = Math.max(0.5, max - mean);
	var above = Math.min(1, window / crest);
	var reduction = above * (window / 2) * (1 - 1 / conf.ratio);
	return Math.min(max, mean + musicLevellerMakeupDb(mean) - reduction);
}
function musicBaselineGain(mean, max) {
	var conf = musicBaselineConf();
	var reference = musicLevelledMean(mean, max);
	var db = (conf.target - reference) * conf.factor;
	// boost only: a loud track is never turned down, and a quiet one is raised.
	// A boost that drives a 0 dBFS peak into the limiter is still wanted; the
	// limiter is what keeps it from clipping.
	db = Math.max(0, Math.min(conf.max, db));
	return Math.pow(10, db / 20);
}
function musicBaselineApply(chain) {
	var g = chain || musicVisual;
	if (!g) { return; }
	var ctx = musicVisual && musicVisual.ctx;
	if (ctx && g.makeup) {
		var gain = 1;
		if (music_normalize && music_normalize != 'off' && musicBaseline.mean != null) { gain = musicBaseline.gain; }
		try { g.makeup.gain.setTargetAtTime(gain, ctx.currentTime, 1.2); }
		catch (e) { g.makeup.gain.value = gain; }
	}
	musicLevellerApply(chain);
	if (!chain && musicAhead.chain) { musicBaselineApply(musicAhead.chain); }
}
// The slow compressor that closes the dialogue/action gap. It is transparent
// until the track has been measured, and when the setting is off.
function musicLevellerApply(chain) {
	var g = chain || musicVisual;
	var ctx = musicVisual && musicVisual.ctx;
	if (!g || !ctx || !g.compressor || !g.leveler) { return; }
	var conf = musicLevellerConf();
	var on = !!(conf && music_normalize && music_normalize != 'off' && musicBaseline.max != null);
	var now = ctx.currentTime;
	var ratio = 1, threshold = 0, knee = 0, attack = 0.003, release = 0.25, makeup = 1;
	if (on) {
		ratio = conf.ratio;
		var window = musicLevellerWindow(conf, musicBaseline.mean);
		// the top slice of this track's own range, so the threshold follows the
		// recording rather than a fixed level
		threshold = Math.max(-60, musicBaseline.max - window);
		knee = Math.min(12, window);
		// slow next to a syllable: the gain does not ride the dialogue
		attack = 0.08;
		release = 0.45;
		makeup = Math.pow(10, musicLevellerMakeupDb(musicBaseline.mean) / 20);
	}
	try {
		g.compressor.threshold.setTargetAtTime(threshold, now, 0.05);
		g.compressor.knee.setTargetAtTime(knee, now, 0.05);
		g.compressor.attack.setTargetAtTime(attack, now, 0.05);
		g.compressor.release.setTargetAtTime(release, now, 0.05);
		g.compressor.ratio.setTargetAtTime(ratio, now, 0.05);
		g.leveler.gain.setTargetAtTime(makeup, now, 0.4);
	}
	catch (e) {
		g.compressor.threshold.value = threshold;
		g.compressor.knee.value = knee;
		g.compressor.attack.value = attack;
		g.compressor.release.value = release;
		g.compressor.ratio.value = ratio;
		g.leveler.gain.value = makeup;
	}
}
function musicBaselineReset() {
	musicBaseline.src = '';
	musicBaseline.mean = null;
	musicBaseline.max = null;
	musicBaseline.gain = 1;
	musicBaseline.failed = false;
	musicBaseline.token++;
	musicBaselineApply();
}
// One measurement request per file. A prefetch for the next track and a
// playback that has just reached it share the same request: the second caller
// waits for the answer instead of asking again.
function musicBaselineRequest(song, onDone) {
	if (!song || !song.file) { if (onDone) { onDone(null); } return; }
	var key = song.file;
	if (musicBaselineCache[key]) { if (onDone) { onDone(musicBaselineCache[key]); } return; }
	if (musicBaselinePending[key]) { if (onDone) { musicBaselinePending[key].push(onDone); } return; }
	musicBaselinePending[key] = onDone ? [ onDone ] : [];
	var settle = function(measured) {
		var waiters = musicBaselinePending[key] || [];
		delete musicBaselinePending[key];
		for (var i = 0; i < waiters.length; i++) {
			try { waiters[i](measured); } catch (e) {}
		}
	};
	var url = '/file_open?track=' + encodeURIComponent(song.file) + '&loudness=yes';
	if (song.remote_uuid) { url += '&remote_uuid=' + encodeURIComponent(song.remote_uuid); }
	$.ajax({
		url: url,
		type: 'GET',
		dataType: 'json',
		// a peer that predates the measurement answers with the file itself; the
		// remote case is given a short rope rather than three minutes of tunnel
		timeout: song.remote_uuid ? 30000 : 180000,
		success: function(r) {
			if (r && r.ok && typeof r.mean_volume != 'undefined') {
				var mean = parseFloat(r.mean_volume);
				var max = (r.max_volume == null) ? null : parseFloat(r.max_volume);
				if (!isNaN(mean)) {
					var measured = { mean: mean, max: max };
					musicBaselineCache[key] = measured;
					settle(measured);
					return;
				}
			}
			settle(null);
		},
		error: function() { settle(null); },
		complete: function() { if (musicBaselinePending[key]) { settle(null); } }
	});
}
// Measure the track after this one while this one plays, so the next gain is
// already in hand when the queue reaches it.
function musicBaselinePrefetch() {
	if (!music_normalize || music_normalize == 'off' || !tree || !tree.songs) { return; }
	var next = tree.songs[1];
	if (!next || !next.file) { return; }
	musicBaselineRequest(next, null);
}
function musicBaselineStart() {
	if (!music_normalize || music_normalize == 'off' || !tree || !tree.sound) { return; }
	var song = (tree.songs && tree.songs[0]) ? tree.songs[0] : null;
	if (!song || !song.file) { return; }
	var key = song.file;
	if (musicBaseline.src === key) {
		if (musicBaseline.mean != null) { musicBaseline.gain = musicBaselineGain(musicBaseline.mean, musicBaseline.max); }
		musicBaselineApply();
		musicBaselinePrefetch();
		return;
	}
	musicBaseline.src = key;
	musicBaseline.mean = null;
	musicBaseline.max = null;
	musicBaseline.gain = 1;
	musicBaseline.failed = false;
	musicBaselineApply();
	var token = ++musicBaseline.token;
	musicBaselineRequest(song, function(measured) {
		if (token !== musicBaseline.token) { return; }
		if (!measured) { musicBaseline.failed = true; return; }
		musicBaseline.mean = measured.mean;
		musicBaseline.max = measured.max;
		musicBaseline.gain = musicBaselineGain(measured.mean, measured.max);
		musicBaselineApply();
		musicBaselinePrefetch();
	});
}
function musicNormalizeParams(chain) {
	var g = chain || musicVisual;
	var ctx = musicVisual && musicVisual.ctx;
	if (!ctx || !g.makeup || !g.limiter) { return; }
	var now = ctx.currentTime;
	// The compressor is the in-track leveller and musicLevellerApply() owns it.
	// Here only the peak guard is set: when the normaliser is on, a boost cannot
	// clip; when it is off the limiter is transparent too.
	var limiting = (music_normalize && music_normalize != 'off') || musicEqualizerDirty();
	try {
		g.limiter.threshold.setTargetAtTime(limiting ? -1 : 0, now, 0.02);
		g.limiter.knee.setTargetAtTime(0, now, 0.02);
		g.limiter.attack.setTargetAtTime(0.003, now, 0.02);
		g.limiter.release.setTargetAtTime(limiting ? 0.10 : 0.25, now, 0.02);
	}
	catch (e) {
		g.limiter.threshold.value = limiting ? -1 : 0;
		g.limiter.knee.value = 0;
		g.limiter.attack.value = 0.003;
		g.limiter.release.value = limiting ? 0.10 : 0.25;
	}
	g.limiter.ratio.value = limiting ? 20 : 1;
	if (!chain && musicAhead.chain) { musicNormalizeParams(musicAhead.chain); }
}
// The normaliser is only put in the signal path when it is asked for. Turning it
// on builds the shared graph; turning it off leaves the graph transparent so a
// playing track is not interrupted.
function musicNormalizeApply() {
	var setting = music_normalize || 'off';
	if (setting != 'off') {
		musicAudioGraph();
		musicNormalizeParams();
		musicBaselineStart();
		musicBaselineApply();
	}
	else {
		musicBaselineReset();
		musicNormalizeParams();
	}
}
// A page restored with normalisation on has no user gesture yet, and a browser
// only starts an AudioContext inside (or after) one. The first touch or key that
// reaches the window puts the graph in place and resumes it, so a restored track
// is not left silent by a context that could not start on its own.
$(document).on('pointerdown touchstart keydown', function() {
	if ((music_normalize && music_normalize != 'off') || musicEqualizerDirty()) { musicAudioGraph(); }
	// a stream left muted by an older build or a failed autoplay is put right
	// on the first gesture, when WebKit accepts the change
	if ($('#music').length && tree && tree.sound) { musicVolumeApply(); }
});
// A phone pauses the graph when the app is put away; coming back resumes it.
$(document).on('visibilitychange', function() {
	if (!document.hidden && ((music_normalize && music_normalize != 'off') || musicEqualizerDirty()) && $('#music').length) {
		musicAudioGraph();
		musicVolumeApply();
	}
});

// The visualiser's tap. It shares the normaliser's graph so the drawing follows
// the sound after normalisation, and so neither can capture the element twice.
function musicVisualAnalyser() {
	var g = musicAudioGraph();
	return g ? g.analyser : null;
}

// One moment of the sound: the band levels (0..1), where its weight sits (the
// centroid), a beat, and the smoothed versions the drawings are made from. With
// nothing to hear the levels idle along a slow breath, so a paused player is
// calm rather than dead.
function musicVisualSample(analyser, dt) {
	var st = musicVisualState();
	var bass = 0, mid = 0, treble = 0, level = 0, centroid = st.centroid;
	if (analyser) {
		var f = musicVisual.freq;
		if (!f || f.length != analyser.frequencyBinCount) {
			f = musicVisual.freq = new Uint8Array(analyser.frequencyBinCount);
		}
		analyser.getByteFrequencyData(f);
		var n = f.length;
		var bEnd = Math.max(1, Math.round(n * 0.06));
		var mEnd = Math.max(bEnd + 1, Math.round(n * 0.35));
		var tEnd = Math.max(mEnd + 1, Math.round(n * 0.85));
		var sum = 0, weighted = 0;
		for (var i = 0; i < n; i++) {
			sum += f[i];
			weighted += f[i] * i;
			if (i < bEnd) { bass += f[i]; }
			else if (i < mEnd) { mid += f[i]; }
			else if (i < tEnd) { treble += f[i]; }
		}
		bass = bass / (bEnd * 255);
		mid = mid / ((mEnd - bEnd) * 255);
		treble = treble / ((tEnd - mEnd) * 255);
		level = (bass * 1.35 + mid + treble * 0.75) / 3.1;
		centroid = sum > 0 ? (weighted / sum) / n : 0;
	}
	// the idle breath: a few percent of the scale, so nothing is ever still
	var idle = 0.05 + 0.028 * Math.sin(st.t * 0.8);
	if (level < 0.02) {
		level = idle;
		bass = idle;
		mid = idle * 0.8;
		treble = idle * 0.55;
	}
	var k = Math.min(1, dt * 7);
	st.bass += (bass - st.bass) * k;
	st.mid += (mid - st.mid) * k;
	st.treble += (treble - st.treble) * k;
	st.level += (level - st.level) * k;
	st.centroid += (centroid - st.centroid) * Math.min(1, dt * 2.5);
	// a beat is the bass standing over its own slow average
	st.avg = st.avg * 0.96 + st.bass * 0.04;
	st.beat = !!(st.bass > 0.12 && st.bass > st.avg * 1.3 && (st.t - st.lastBeat) > 0.22);
	if (st.beat) { st.lastBeat = st.t; }
	return st;
}

// The house fit: in the big picture the bitmap follows the canvas' css box, at
// most 2x for a retina screen and 1920 on the long edge - the picture is soft
// shapes, and a 4K screen should not cost 8M pixels a frame. The corner is a
// picture of its own shape, a small 16:9 band, so the thumbnail never inherits
// the shape of the whole player.
function musicVisualFit(canvas, big) {
	var w, h;
	if (big) {
		var cw = canvas.clientWidth || 0;
		var ch = canvas.clientHeight || 0;
		if (cw < 4 || ch < 4) { return false; }
		var scale = Math.min(window.devicePixelRatio || 1, 2);
		var long = Math.max(cw, ch);
		if (long * scale > 1920) { scale = 1920 / long; }
		w = Math.max(4, Math.round(cw * scale));
		h = Math.max(4, Math.round(ch * scale));
	}
	else {
		w = 480;
		h = 270;
	}
	if (canvas.width != w || canvas.height != h) {
		canvas.width = w;
		canvas.height = h;
		musicVisual.dots = [];
		musicVisual.peaks = [];
	}
	return true;
}

// The three pieces the drawing lives between: the player element (its miss names
// the other two), the canvas the drawing goes on, and the video it is played
// into.
function musicVisualElements() {
	var el = document.getElementById('video');
	var miss = el ? (el.getAttribute('miss') || '') : '';
	return {
		el: el,
		miss: miss,
		canvas: (miss && document.getElementById(miss + '_visualizer')) || null,
		feed: (miss && document.getElementById(miss + '_visual_media')) || null
	};
}

// The canvas as a picture: its stream, made once per canvas (a re-render hands
// back a fresh one, and a spent stream with it), given to the muted feed video.
function musicVisualFeed(parts) {
	if (!parts.canvas.captureStream) { return; }
	if (musicVisual.feedCanvas !== parts.canvas) {
		musicVisual.feedCanvas = parts.canvas;
		musicVisual.stream = parts.canvas.captureStream(30);
	}
	if (!musicVisual.stream) { return; }
	if (parts.feed.srcObject !== musicVisual.stream) {
		parts.feed.srcObject = musicVisual.stream;
		parts.feed.muted = true;
	}
	if (parts.feed.paused) {
		var p = parts.feed.play();
		if (p && p.catch) { p.catch(function () {}); }
	}
}

// The picture's dress and place, taken from the player's own two: the corner
// thumbnail while the library is up, the whole player in the theatre - or
// whenever the player itself fills the screen. The canvas wears the same style,
// so its bitmap matches what is on screen.
function musicVisualPlace(parts, big) {
	var style = parts.el.getAttribute(big ? 'big_style' : 'thumb_style') || '';
	var shown = style + 'display:block;';
	if (parts.feed.getAttribute('style') != shown) { parts.feed.setAttribute('style', shown); }
	if (parts.canvas.getAttribute('style') != style) { parts.canvas.setAttribute('style', style); }
}

function musicVisualStop() {
	if (musicVisual.raf) { cancelAnimationFrame(musicVisual.raf); musicVisual.raf = 0; }
	var feed = musicVisualElements().feed;
	if (feed && feed.style.display != 'none') { feed.style.display = 'none'; }
	musicVisual.canvas = null;
	musicVisual.painted = null;
	musicVisual.last = 0;
}

// Put the chosen drawing on the player: there is nothing to open and nothing to
// place here - the loop's first frame feeds the video and dresses it.
function musicVisualApply() {
	var parts = musicVisualElements();
	if (!parts.el || !parts.canvas || !parts.feed || musicVisual.mode == 'none') { musicVisualStop(); return; }
	if (!musicVisual.raf) { musicVisual.raf = requestAnimationFrame(musicVisualFrame); }
}

function musicVisualChoose(mode) {
	musicVisual.mode = mode || 'none';
	musicVisual.painted = null;
	musicVisualApply();
}

$(document).on('change', '.media_visualization', function() {
	musicVisualChoose(this.value);
	// the choice is part of the player cache, so it comes back with the track
	if (typeof tree != 'undefined' && tree && tree.songs && tree.songs.length) {
		tree.lastCache = 0;
		playerCacheSaver();
	}
});

function musicVisualFrame(ts) {
	musicVisual.raf = 0;
	var parts = musicVisualElements();
	if (!parts.el || !parts.canvas || !parts.feed || musicVisual.mode == 'none') {
		musicVisualStop();
		return;
	}
	if (parts.el.getAttribute('type') != 'audio') {
		// a video track brings its own picture: the drawing is put away and the
		// loop waits, so it comes straight back on its own
		musicVisualStop();
		musicVisual.raf = requestAnimationFrame(musicVisualFrame);
		return;
	}
	// a re-render hands back a fresh dropdown at its default; the drawing is the
	// truth, so the control is put back in step
	var select = document.getElementById(parts.miss + '_visualization');
	if (select && select.value != musicVisual.mode) { select.value = musicVisual.mode; }
	var big = musicPictureBig();
	musicVisualFeed(parts);
	musicVisualPlace(parts, big);
	if (!musicVisualFit(parts.canvas, big)) {
		// the player has no box to paint into (mid-resize, collapsed window):
		// there is nothing to paint, but the loop stays on for when it has one
		musicVisual.raf = requestAnimationFrame(musicVisualFrame);
		return;
	}
	musicVisual.canvas = parts.canvas;
	var g = parts.canvas.getContext('2d');
	if (!g) { musicVisualStop(); return; }
	if (musicVisual.painted != musicVisual.mode) {
		musicVisual.painted = musicVisual.mode;
		musicVisual.dots = [];
		musicVisual.peaks = [];
		musicVisual.art = null;
		g.clearRect(0, 0, parts.canvas.width, parts.canvas.height);
	}
	var now = ts / 1000;
	var dt = now - (musicVisual.last || now);
	musicVisual.last = now;
	if (dt <= 0) { dt = 0.001; }
	if (dt > 0.1) { dt = 0.1; }
	var st = musicVisualState();
	st.t += dt;
	musicVisualSample(musicVisualAnalyser(), dt);
	st.hue = (st.hue + dt * (14 + st.level * 160)) % 360;
	var draw = musicVisualDraw[musicVisual.mode];
	if (draw) { draw(g, parts.canvas.width, parts.canvas.height, st, dt); }
	musicVisual.raf = requestAnimationFrame(musicVisualFrame);
}

var musicVisualDraw = {

	// The spectrum: one bar per band, the hue walking with the pitch and a cap
	// that falls back so a hit is read twice.
	equalizer: function(g, w, h, st, dt) {
		var f = musicVisual.freq;
		var bars = Math.max(16, Math.min(110, Math.round(w / 16)));
		var gap = Math.max(1, Math.round(w * 0.003));
		var bw = (w - gap * (bars + 1)) / bars;
		g.fillStyle = '#000';
		g.fillRect(0, 0, w, h);
		if (musicVisual.peaks.length != bars) { musicVisual.peaks = new Array(bars).fill(0); }
		var have = f && f.length > 8;
		var step = have ? (f.length * 0.72) / bars : 0;
		var fall = h * dt;
		for (var i = 0; i < bars; i++) {
			var v = 0;
			if (have) {
				var a = Math.floor(i * step);
				var b = Math.max(a + 1, Math.floor((i + 1) * step));
				for (var k = a; k < b && k < f.length; k++) { if (f[k] > v) { v = f[k]; } }
			}
			v = v / 255;
			// the quiet bands keep a small life of their own
			var mag = Math.pow(Math.max(v, 0.015 + 0.012 * Math.sin(st.t * 1.4 + i * 0.6)), 1.2);
			var bh = Math.max(2, mag * (h - 6) * 0.96);
			var x = gap + i * (bw + gap);
			var hue = (st.hue + (i / bars) * 312) % 360;
			g.fillStyle = 'hsl(' + Math.round(hue) + ',92%,' + (40 + Math.round(mag * 26)) + '%)';
			g.fillRect(x, h - bh, bw, bh);
			musicVisual.peaks[i] = Math.max(musicVisual.peaks[i] - fall * (0.35 + v), bh);
			g.fillStyle = 'hsl(' + Math.round(hue) + ',96%,78%)';
			g.fillRect(x, h - musicVisual.peaks[i] - 3, bw, 3);
		}
	},

	// The dancers: a band of dots carried by the music, each its own colour,
	// with a low-alpha black in place of a clear so they carry tails. Now and
	// then one grows a face and legs - the music is lively; so are they.
	dots: function(g, w, h, st, dt) {
		var size = Math.min(w, h);
		if (musicVisual.dots.length == 0 || musicVisual.dotW != w || musicVisual.dotH != h) {
			musicVisual.dotW = w;
			musicVisual.dotH = h;
			musicVisual.dots = [];
			var count = Math.max(16, Math.min(64, Math.round(w * h / 46000)));
			for (var n = 0; n < count; n++) {
				musicVisual.dots.push({
					x: Math.random() * w,
					y: Math.random() * h,
					a: Math.random() * Math.PI * 2,
					wander: (Math.random() - 0.5) * 2.2,
					v: 0.05 + Math.random() * 0.13,
					r: size * (0.008 + Math.random() * 0.012),
					hue: Math.random() * 360,
					pulse: 0,
					face: false,
					life: 0
				});
			}
		}
		g.fillStyle = 'rgba(0,0,0,0.3)';
		g.fillRect(0, 0, w, h);
		var faces = 0;
		for (var c = 0; c < musicVisual.dots.length; c++) { if (musicVisual.dots[c].face) { faces++; } }
		for (var i = 0; i < musicVisual.dots.length; i++) {
			var d = musicVisual.dots[i];
			d.a += d.wander * dt * (0.5 + st.mid * 2.5);
			var sp = d.v * size * (0.35 + st.level * 2.6) * (1 + st.bass * 1.2);
			d.x += Math.cos(d.a) * sp * dt;
			d.y += Math.sin(d.a) * sp * dt;
			if (d.x < -d.r * 2) { d.x = w + d.r * 2; }
			if (d.x > w + d.r * 2) { d.x = -d.r * 2; }
			if (d.y < -d.r * 2) { d.y = h + d.r * 2; }
			if (d.y > h + d.r * 2) { d.y = -d.r * 2; }
			if (st.beat && d.pulse <= 0 && Math.random() < 0.35) {
				d.pulse = 0.9;
				d.a += (Math.random() - 0.5) * 0.6;
				if (!d.face && faces < 3 && Math.random() < 0.22) {
					d.face = true;
					d.life = 6 + Math.random() * 8;
					faces++;
				}
			}
			if (d.pulse > 0) { d.pulse = Math.max(0, d.pulse - dt * 1.4); }
			if (d.face) {
				d.life -= dt;
				if (d.life <= 0) { d.face = false; }
			}
			var r = d.r * (1 + st.bass * 1.9 + d.pulse * 0.8);
			var hue = (st.hue + d.hue) % 360;
			g.fillStyle = 'hsla(' + Math.round(hue) + ',95%,60%,0.16)';
			g.beginPath();
			g.arc(d.x, d.y, r * 2.6, 0, 6.2832);
			g.fill();
			g.fillStyle = 'hsla(' + Math.round(hue) + ',92%,62%,0.95)';
			g.beginPath();
			g.arc(d.x, d.y, r, 0, 6.2832);
			g.fill();
			if (d.face) { musicVisualDotFace(g, d, r, st); }
		}
	},

	// The tie-dye: soft rings and spiral arms over a slow fade, so the colour
	// builds like ink in water. The bass drives the swirl, the treble the
	// wobble, and the beat makes the whole thing breathe.
	psychedelic: function(g, w, h, st, dt) {
		// the fade is what makes it move: every frame leaves a ghost of itself
		g.globalCompositeOperation = 'source-over';
		g.fillStyle = 'rgba(0,0,0,0.06)';
		g.fillRect(0, 0, w, h);
		g.globalCompositeOperation = 'lighter';
		var cx = w / 2 + Math.sin(st.t * 0.17) * w * 0.13;
		var cy = h / 2 + Math.cos(st.t * 0.12) * h * 0.12;
		var size = Math.max(w, h);
		var spin = st.t * (0.2 + st.level * 1.5);
		var wobble = 0.08 + st.treble * 0.55;
		var arms = 6;
		g.lineCap = 'round';
		for (var arm = 0; arm < arms; arm++) {
			var base = spin + (arm / arms) * Math.PI * 2;
			var first = true;
			g.beginPath();
			for (var a = 0; a <= Math.PI * 3.2; a += 0.16) {
				var f = a / (Math.PI * 3.2);
				var rad = (0.06 + f * 0.54) * size;
				var wave = Math.sin(a * 2.3 + st.t * (0.8 + st.bass * 2.4) + arm) * wobble * rad * 0.35;
				var th = base + a + Math.sin(a * 1.7 + st.t * 0.4) * 0.3;
				var x = cx + Math.cos(th) * (rad + wave);
				var y = cy + Math.sin(th) * (rad + wave) * 0.94;
				if (first) { g.moveTo(x, y); first = false; }
				else { g.lineTo(x, y); }
			}
			var hue = (st.hue + arm * (360 / arms)) % 360;
			g.strokeStyle = 'hsla(' + Math.round(hue) + ',95%,55%,0.3)';
			g.lineWidth = size * (0.035 + st.bass * 0.045);
			g.stroke();
		}
		// rings on the beat, so the whole thing breathes
		var rings = 3;
		for (var r2 = 0; r2 < rings; r2++) {
			var rr = ((st.t * (0.06 + st.level * 0.25) + r2 / rings) % 1) * size * 0.7;
			g.strokeStyle = 'hsla(' + Math.round((st.hue + r2 * 70) % 360) + ',90%,60%,0.22)';
			g.lineWidth = size * 0.012 * (1 + st.bass * 2);
			g.beginPath();
			g.arc(cx, cy, rr, 0, 6.2832);
			g.stroke();
		}
		g.globalCompositeOperation = 'source-over';
	},

	// Modern Art: a stroke for the moment - the colour is where the sound sits
	// (weight low is warm, weight high is cool), the width is the bass, the
	// length the level - and every stroke is answered across the middle, so the
	// picture keeps a composition. The fade is a whisper, so the painting grows
	// rather than flickers.
	modern_art: function(g, w, h, st, dt) {
		var size = Math.max(w, h);
		g.globalCompositeOperation = 'source-over';
		g.fillStyle = 'rgba(0,0,0,0.012)';
		g.fillRect(0, 0, w, h);
		if (!musicVisual.art) {
			musicVisual.art = { x: Math.random() * w, y: Math.random() * h, a: Math.random() * Math.PI * 2, wait: 0 };
		}
		var art = musicVisual.art;
		art.wait -= dt;
		if (art.wait > 0) { return; }
		// a stroke every half second in quiet, ten a second at full tilt
		art.wait = (0.45 - Math.min(0.4, st.level * 0.5)) * (0.5 + Math.random());
		var hue = (st.centroid * 780 + st.hue * 0.2) % 360;
		var lum = 34 + Math.round(Math.min(1, st.level) * 38);
		var width = Math.max(2, size * (0.004 + st.bass * 0.04));
		var len = size * (0.02 + st.level * 0.14);
		art.a += (Math.random() - 0.5) * (0.4 + st.treble * 3);
		var nx = art.x + Math.cos(art.a) * len;
		var ny = art.y + Math.sin(art.a) * len;
		// the brush bends mid-stroke, the way a wrist does
		var mx = (art.x + nx) / 2 + (Math.random() - 0.5) * width * 2.5;
		var my = (art.y + ny) / 2 + (Math.random() - 0.5) * width * 2.5;
		g.strokeStyle = 'hsla(' + Math.round(hue) + ',85%,' + lum + '%,0.8)';
		g.lineWidth = width;
		g.lineCap = 'round';
		g.beginPath();
		g.moveTo(art.x, art.y);
		g.quadraticCurveTo(mx, my, nx, ny);
		g.stroke();
		g.beginPath();
		g.moveTo(w - art.x, art.y);
		g.quadraticCurveTo(w - mx, my, w - nx, ny);
		g.stroke();
		if (st.beat && Math.random() < 0.4) {
			// a bold gesture, the way a wrist makes one
			var bw = size * (0.02 + st.mid * 0.18);
			var bh = size * (0.015 + st.bass * 0.16);
			var bx = Math.random() * (w - bw);
			var by = Math.random() * (h - bh);
			g.fillStyle = 'hsla(' + Math.round((hue + 170) % 360) + ',80%,58%,0.16)';
			g.fillRect(bx, by, bw, bh);
			g.fillRect(w - bx - bw, by, bw, bh);
		}
		art.x = nx;
		art.y = ny;
		// the wrist does not leave the page
		if (art.x < 0 || art.x > w) { art.a = Math.PI - art.a; art.x = Math.max(0, Math.min(w, art.x)); }
		if (art.y < 0 || art.y > h) { art.a = -art.a; art.y = Math.max(0, Math.min(h, art.y)); }
	}
};

// A dot with a face: eyes that look where it is going, a smile that opens with
// the bass, and legs swinging as it goes.
function musicVisualDotFace(g, d, r, st) {
	var dx = Math.cos(d.a);
	var dy = Math.sin(d.a);
	var ex = -dy * r * 0.42;
	var ey = dx * r * 0.42;
	var er = Math.max(1.4, r * 0.24);
	var look = Math.min(1, 0.4 + st.level * 1.6) * r * 0.16;
	g.fillStyle = 'rgba(20,10,30,0.92)';
	g.beginPath(); g.arc(d.x + ex, d.y + ey, er, 0, 6.2832); g.fill();
	g.beginPath(); g.arc(d.x - ex, d.y - ey, er, 0, 6.2832); g.fill();
	g.fillStyle = '#fff';
	g.beginPath(); g.arc(d.x + ex + dx * look, d.y + ey + dy * look, er * 0.42, 0, 6.2832); g.fill();
	g.beginPath(); g.arc(d.x - ex + dx * look, d.y - ey + dy * look, er * 0.42, 0, 6.2832); g.fill();
	var mouth = r * (0.35 + st.bass * 0.45);
	g.strokeStyle = 'rgba(20,10,30,0.92)';
	g.lineWidth = Math.max(1.2, r * 0.14);
	g.beginPath();
	g.arc(d.x + dx * r * 0.15, d.y + dy * r * 0.15, mouth, Math.PI * 0.15, Math.PI * 0.85);
	g.stroke();
	var swing = Math.sin(st.t * 7 + d.hue) * r * 0.5;
	var lx = -dy * r * 0.5;
	var ly = dx * r * 0.5;
	g.beginPath();
	g.moveTo(d.x + lx, d.y + ly);
	g.lineTo(d.x + lx + swing, d.y + ly + r * 0.9);
	g.moveTo(d.x - lx, d.y - ly);
	g.lineTo(d.x - lx - swing, d.y - ly + r * 0.9);
	g.stroke();
	g.lineWidth = 1;
}










