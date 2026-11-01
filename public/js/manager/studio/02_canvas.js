function studioSyncTakes() {
	var pos = mixer['time']['position'];
	studioApplyPlaybackMix();
	$.each(mixer, function (ch, m) {
		if (!/^[0-9]+$/.test(ch) || !m.media || !m.media.out) { return; }
		var armed = m.armed && (m.armed.state == 'rec' || m.armed.state == 'play' || m.armed.state == 'loop');
		if (!armed) { return; }

		var xf = studioCrossfade();
		var ordered = studioChannelTakes(ch);
		ordered.forEach(function (take, i) {
			// audio takes are placed by the scheduler on the audio clock; only
			// video / undecodable takes ride a media element
			if (studioTakeUsesBuffer(take)) { return; }
			var el = take.track;
			if (!el || !el.src) { return; }
			var offset = take.offset || 0;
			var start = take.startTime;
			var dur = take.duration || 0;
			var end = start + dur;
			var looping = !!(take.loop && dur > 0);
			var prev = ordered[i - 1];
			var next = ordered[i + 1];

			var fIn = 0, fOut = 0;
			if (prev) {
				var fi = Math.min(xf, prev.duration || 0, dur) / 2;
				if (fi > 0 && prev.src !== take.src && Math.abs(start - (prev.startTime + (prev.duration || 0))) <= fi * 2) { fIn = fi; }
			}
			if (next && !looping) {
				var fo = Math.min(xf, dur, next.duration || 0) / 2;
				if (fo > 0 && next.src !== take.src && Math.abs(next.startTime - end) <= fo * 2) { fOut = fo; }
			}

			var winStart = start - fIn;
			var winEnd = looping ? Infinity : end + fOut;
			var routed = !!studioTakeNode(ch, take);
			if (!routed) { el.volume = studioVolumeFraction($('.channel_volume[channel="' + ch + '"]').val()); }

			studioSetTakeLoop(el, looping ? offset : 0, looping ? offset + dur : 0);

			if (pos < winStart || pos >= winEnd) {
				if (!el.paused) { try { el.pause(); } catch (e) {} }
				var reset = offset - fIn;
				if (reset < 0) { reset = 0; }
				if (el.currentTime != reset) { try { el.currentTime = reset; } catch (e) {} }
				if (take.playGain) { take.playGain.gain.value = 0; }
				el.playbackRate = 1;
				return;
			}

			var g = 1;
			if (fIn > 0) { g *= Math.max(0, Math.min(1, (pos - winStart) / (2 * fIn))); }
			if (fOut > 0) { g *= Math.max(0, Math.min(1, (winEnd - pos) / (2 * fOut))); }
			if (take.playGain) { take.playGain.gain.value = g; }

			var elapsed = pos - start;
			if (elapsed < 0) { elapsed = 0; }
			var target = elapsed + offset;
			if (looping) { target = offset + (elapsed % dur); }
			if (target < 0) { target = 0; }
			if (mixer['time']['status'] == 'scroll') { try { el.currentTime = target; } catch (e) {} el.playbackRate = 1; return; }
			if (el.paused) {
				// Never start past the end of the file: the element would silently
				// seek back to the top, which sounds like a blip of the take's start.
				if (isFinite(el.duration) && el.duration > 0 && target >= el.duration - 0.005) {
					if (take.playGain) { take.playGain.gain.value = 0; }
					return;
				}
				el.playbackRate = 1;
				try { el.currentTime = target; } catch (e) {}
				var p = el.play();
				if (p && p.catch) { p.catch(function () {}); }
			}
			else {
				studioSyncTakeClock(take, el, target, looping ? dur : 0);
				if (looping && !('loopStart' in el) && el.currentTime >= offset + dur - 0.005) {
					// no loop points to lean on: wrap the take by hand
					try { el.currentTime = target; } catch (e) {}
				}
			}
		});
	});
	studioVideoPreview(pos);
}

// Mirror the clip currently under the playhead to the main video monitor, so you
// can see what you're cutting (the selected channel wins).
function studioVideoPreview(pos) {
	var monitor = document.getElementById('studio_video_monitor');
	if (!monitor) { return; }
	var status = mixer['time']['status'];
	if (status != 'play' && status != 'record' && status != 'scroll') { return; }
	var channels = Object.keys(mixer).filter(function (k) { return /^[0-9]+$/.test(k); });
	channels.sort(function (a, b) {
		return (b == studioSelectedChannel ? 1 : 0) - (a == studioSelectedChannel ? 1 : 0);
	});
	var found = null;
	for (var i = 0; i < channels.length && !found; i++) {
		var takes = (mixer[channels[i]].media && mixer[channels[i]].media.out) || [];
		for (var n = 0; n < takes.length; n++) {
			var take = takes[n];
			if (!take || !take.src || take.status == 'recording') { continue; }
			if (take.encoding && take.encoding.indexOf('video') === -1) { continue; }
			if (pos >= take.startTime && pos < take.startTime + (take.duration || 0)) { found = take; break; }
		}
	}
	if (!found) { return; }
	if (monitor.getAttribute('data-take-src') != found.src) {
		monitor.setAttribute('data-take-src', found.src);
		monitor.src = found.src;
		monitor.muted = true;
	}
	var t = pos - found.startTime + (found.offset || 0);
	if (Math.abs((monitor.currentTime || 0) - t) > 0.2) {
		try { monitor.currentTime = t; } catch (e) {}
	}
	monitor.style.display = '';
}

// ---- canvas -----------------------------------------------------------------

function studioFitCanvas(canvas) {
	if (!canvas) { return; }
	var w = canvas.clientWidth || canvas.width || 300;
	var h = canvas.clientHeight || canvas.height || 60;
	if (canvas.width != w) { canvas.width = w; }
	if (canvas.height != h) { canvas.height = h; }
}

function studioDrawChannel(ch) {
	var canvas = document.getElementById('track_view_' + ch);
	if (!canvas) { return; }
	studioFitCanvas(canvas);
	var ctx = canvas.getContext('2d');
	var w = canvas.width, h = canvas.height;
	ctx.clearRect(0, 0, w, h);
	ctx.fillStyle = 'rgba(255,255,255,0.18)';
	ctx.fillRect(0, 0, w, h);

	var duration = mixer['time']['duration'] > 0 ? mixer['time']['duration'] : 1;
	var m = mixer[ch] || {};
	var co = studioAudio.channels[ch];

	if (co && co.source) {
		co.recAnalyser.getFloatTimeDomainData(co.recData);
		ctx.strokeStyle = '#0a8a3a';
		ctx.lineWidth = 1;
		ctx.beginPath();
		for (var i = 0; i < w; i++) {
			var v = co.recData[Math.floor(i / w * co.recData.length)] || 0;
			var y = (h / 2) + (v * h * 0.45);
			if (i === 0) { ctx.moveTo(i, y); } else { ctx.lineTo(i, y); }
		}
		ctx.stroke();
	}

	// the loop region: reserved bars, or what arming L would reserve now
	var region = studioVisibleRegion();
	var region_x = 0, region_w = 0;
	if (region && region.end > region.start) {
		region_x = (region.start / duration) * w;
		region_w = Math.max(2, ((region.end - region.start) / duration) * w);
		ctx.fillStyle = 'rgba(255,255,255,0.22)';
		ctx.fillRect(region_x, 0, region_w, h);
	}

	if (m.media && m.media.out) {
		var orderedDraw = studioChannelTakes(ch, true);
		var xfDraw = studioCrossfade();
		orderedDraw.forEach(function (take, tIndex) {
			if (!take) { return; }
			studioEnsureWaveform(ch, take);
			var x = (take.startTime / duration) * w;
			var tw = Math.max(2, ((take.duration || 0) / duration) * w);
			var selected = studioSelectedTake && studioSelectedTake.take === take;
			var isVideo = take.encoding && take.encoding.indexOf('video') !== -1;
			ctx.fillStyle = take.status == 'recording' ? 'rgba(220,0,0,0.55)' : (isVideo ? 'rgba(120,60,190,0.5)' : 'rgba(20,90,190,0.5)');
			ctx.fillRect(x, 3, tw, h - 6);

			// a looping take repeats across the rest of the song: ghost those passes
			if (take.loop && take.duration > 0) {
				ctx.save();
				ctx.globalAlpha = 0.16;
				ctx.fillStyle = '#145abe';
				for (var gx = x + tw; gx < w; gx += tw) { ctx.fillRect(gx, 3, tw, h - 6); }
				ctx.restore();
			}

			// waveform peaks
			if (take.waveform && take.waveform.length) {
				var peaks = take.waveform;
				var mid = h / 2;
				ctx.save();
				ctx.beginPath();
				ctx.rect(x, 3, tw, h - 6);
				ctx.clip();
				ctx.strokeStyle = 'rgba(255,255,255,0.85)';
				ctx.lineWidth = 1;
				ctx.beginPath();
				for (var b = 0; b < tw; b++) {
					var idx = Math.min(peaks.length - 1, Math.floor((b / tw) * peaks.length));
					var amp = peaks[idx] * (h * 0.42);
					ctx.moveTo(x + b, mid - amp);
					ctx.lineTo(x + b, mid + amp);
				}
				ctx.stroke();
				ctx.restore();
			}

			// crossfade shading at the junctions
			if (xfDraw > 0 && take.duration) {
				var endT = take.startTime + take.duration;
				var prev = orderedDraw[tIndex - 1];
				var next = orderedDraw[tIndex + 1];
				var shade = function (from, to) {
					var fx = (from / duration) * w;
					var tx = (to / duration) * w;
					ctx.fillStyle = 'rgba(255,220,40,0.30)';
					ctx.fillRect(fx, 3, Math.max(1, tx - fx), h - 6);
				};
				if (prev && prev.src !== take.src) {
					var fi = Math.min(xfDraw, prev.duration || 0, take.duration) / 2;
					if (fi > 0 && Math.abs(take.startTime - (prev.startTime + (prev.duration || 0))) <= fi * 2) { shade(take.startTime - fi, take.startTime + fi); }
				}
				if (next && next.src !== take.src) {
					var fo = Math.min(xfDraw, take.duration, next.duration || 0) / 2;
					if (fo > 0 && Math.abs(next.startTime - endT) <= fo * 2) { shade(endT - fo, endT + fo); }
				}
			}

			ctx.strokeStyle = selected ? '#ffd21e' : '#04325f';
			ctx.lineWidth = selected ? 3 : 1;
			ctx.strokeRect(x, 3, tw, h - 6);
			// grab handles
			ctx.fillStyle = '#04325f';
			ctx.fillRect(x, 3, 3, h - 6);
			ctx.fillRect(x + tw - 3, 3, 3, h - 6);
			// a paler bar marks a trimmed/split in-point
			if (take.offset > 0 && tw > 6) {
				ctx.fillStyle = '#ffe9a8';
				ctx.fillRect(x + 3, 3, 3, h - 6);
			}
			// a dashed edge + arrow marks a looping sample
			if (take.loop && take.duration > 0) {
				ctx.save();
				ctx.strokeStyle = 'rgba(255,255,255,0.9)';
				ctx.setLineDash([4, 3]);
				ctx.strokeRect(x + 1.5, 4.5, Math.max(1, tw - 3), h - 9);
				ctx.restore();
				ctx.fillStyle = '#ffffff';
				ctx.font = '10px sans-serif';
				ctx.fillText('\u21bb', x + 6, 14);
			}
		});
	}

	if (region && region.end > region.start) {
		ctx.save();
		ctx.strokeStyle = 'rgba(255,255,255,0.9)';
		ctx.setLineDash([5, 4]);
		ctx.lineWidth = 1;
		ctx.strokeRect(region_x + 0.5, 0.5, Math.max(1, region_w - 1), h - 1);
		ctx.restore();
		ctx.fillStyle = '#04325f';
		ctx.font = '10px sans-serif';
		ctx.fillText(studioBarLabel(region.start) + ' \u2192 ' + studioBarLabel(region.end) + (region.tentative ? ' loop' : ' (loop)'), region_x + 4, h - 3);
	}

	if (mixer['time']['position'] > 0) {
		var px = (mixer['time']['position'] / duration) * w;
		ctx.strokeStyle = 'black';
		ctx.lineWidth = 2;
		ctx.beginPath();
		ctx.moveTo(px, 0);
		ctx.lineTo(px, h);
		ctx.stroke();
	}
}

function studioDrawMetre(ch) {
	var canvas = document.getElementById('channel_volume_metre_' + ch);
	var co = studioAudio.channels[ch];
	if (!canvas || !co || !co.source) { return; }
	studioFitCanvas(canvas);
	var ctx = canvas.getContext('2d');
	var w = canvas.width, h = canvas.height;
	ctx.clearRect(0, 0, w, h);
	co.recAnalyser.getFloatTimeDomainData(co.recData);
	var sum = 0;
	for (var i = 0; i < co.recData.length; i++) { sum += co.recData[i] * co.recData[i]; }
	var level = Math.min(1, Math.sqrt(sum / co.recData.length) * 3);
	ctx.fillStyle = 'green';
	ctx.fillRect(0, h - (level * h), w, level * h);
}

function studioDrawTracks() {
	// the transport keeps running while the tab is hidden, but there is no point
	// repainting canvases nobody can see
	if (document.hidden) { return; }
	$.each(mixer, function (ch) {
		if (!/^[0-9]+$/.test(ch)) { return; }
		studioDrawChannel(ch);
		studioDrawMetre(ch);
	});
}

function studioUpdateFxBadges() {
	$.each(studioAudio.channels, function (ch, c) {
		var holder = $('.channel_fx[channel="' + ch + '"]');
		holder.empty();
		c.inserts.forEach(function (ins) {
			var src = $('.pedal_background[hint="' + ins.name + '"]').attr('src') || '';
			$('<img class="channel_fx_pedal">').attr('src', src).attr('hint', ins.name).appendTo(holder);
		});
	});
}

// Knob hints carry the knob's current value, since the artwork alone can't show it.
function studioUpdateKnobHints() {
	$('.knob').each(function () {
		var knob = $(this);
		var control = knob.attr('control');
		if (!control) { return; }
		var input = $('.knob_control[control="' + control + '"][channel="' + knob.attr('channel') + '"]');
		if (!input.length) { return; }
		var value = numeral(input.val()).value();
		if (value === null || value === undefined || isNaN(value)) { value = input.val(); }
		else if (Math.abs(value - Math.round(value)) < 0.05) { value = Math.round(value); }
		else { value = numeral(value).format('0.0'); }
		knob.attr('hint', String(control).replace(/_/g, ' ') + ': ' + value);
	});
}

// ---- take editing on the canvas --------------------------------------------

// How far to pull a freshly recorded take back in time to cancel the round
// trip. An explicit record_offset (ms) in the song admin wins; otherwise use
// the AudioContext's reported output latency plus whatever the input stream
// reports for itself, since the browser's output figure on its own is often an
// under-estimate of what the player actually hears and plays against.
