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

// The per-take overview is a few thousand buckets for the whole file. At a deep
// zoom that is coarser than a pixel column, so the lane reads the decoded
// buffer for the visible columns instead; the work is capped because only a
// short window ever needs it. The take's own in-point and length bound the
// read, so a trimmed or split clip draws its own samples.
var STUDIO_FINE_PEAK_SAMPLES = 600000;
var studioFinePeakBudget = 0;
var studioFinePeakAt = 0;

function studioFinePeaks(take, tw, b0, b1) {
	var buffer = take && take.buffer;
	if (!buffer || !buffer.length || !(tw > 0) || !(b1 > b0)) { return null; }
	var duration = take.duration || 0;
	if (!(duration > 0)) { return null; }
	var offset = Math.max(0, take.offset || 0);
	var rate = buffer.sampleRate || 44100;
	var left = buffer.getChannelData(0);
	var right = (buffer.numberOfChannels > 1) ? buffer.getChannelData(1) : left;
	var len = buffer.length;
	var n = b1 - b0;
	var peaksL = new Float32Array(n);
	var peaksR = new Float32Array(n);
	for (var j = 0; j < n; j++) {
		var b = b0 + j;
		// the column's source-time window; one sample at the least, so a thin
		// column never reads as silence
		var t0 = offset + (b / tw) * duration;
		var t1 = offset + ((b + 1) / tw) * duration;
		var i0 = Math.max(0, Math.floor(t0 * rate));
		var i1 = Math.min(len, Math.ceil(t1 * rate));
		if (i1 <= i0) { i1 = Math.min(len, i0 + 1); }
		var ml = 0, mr = 0;
		for (var i = i0; i < i1; i++) {
			var l = Math.abs(left[i]);
			if (l > ml) { ml = l; }
			var r = Math.abs(right[i]);
			if (r > mr) { mr = r; }
		}
		peaksL[j] = ml;
		peaksR[j] = mr;
	}
	return { L: peaksL, R: peaksR };
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

	var m = mixer[ch] || {};
	// a track's colour dresses its clips, so the lane and the panel edge agree
	var colour = (typeof studioTrackColour === 'function') ? studioTrackColour(ch) : '#145abe';
	var fill = (typeof studioColourRgba === 'function') ? studioColourRgba(colour, 0.5) : 'rgba(20,90,190,0.5)';
	var ghost = (typeof studioColourRgba === 'function') ? studioColourRgba(colour, 0.16) : 'rgba(20,90,190,0.16)';

	// The lane draws the recorded takes' own waveforms below; the live input
	// meter belongs in the track panel's metre, not across the whole timeline.

	// the loop region: reserved bars, or what arming L would reserve now
	var region = studioVisibleRegion();
	var region_x = 0, region_w = 0;
	if (region && region.end > region.start) {
		region_x = studioTimelineXAt(canvas, region.start);
		region_w = Math.max(2, studioTimelineWidth(canvas, region.end - region.start));
		ctx.fillStyle = 'rgba(255,255,255,0.22)';
		ctx.fillRect(region_x, 0, region_w, h);
	}

	if (m.media && m.media.out) {
		var orderedDraw = studioChannelTakes(ch, true);
		var xfDraw = studioCrossfade();
		orderedDraw.forEach(function (take, tIndex) {
			if (!take) { return; }
			if (take.status == 'recording') { studioCaptureLivePeaks(ch, take); }
			studioEnsureWaveform(ch, take);
			var x = studioTimelineXAt(canvas, take.startTime);
			var tw = Math.max(2, studioTimelineWidth(canvas, take.duration || 0));
			var selected = studioSelectedTake && studioSelectedTake.take === take;
			var isVideo = take.encoding && take.encoding.indexOf('video') !== -1;
			ctx.fillStyle = take.status == 'recording' ? 'rgba(220,0,0,0.55)' : (isVideo ? 'rgba(120,60,190,0.5)' : fill);
			ctx.fillRect(x, 3, tw, h - 6);

			// a looping take repeats across the rest of the song: ghost those passes
			if (take.loop && take.duration > 0) {
				ctx.save();
				ctx.fillStyle = ghost;
				for (var gx = x + tw; gx < w; gx += tw) { ctx.fillRect(gx, 3, tw, h - 6); }
				ctx.restore();
			}

			// The two halves are the stereo view: L above the centre line, R below,
			// so a pan reads at a glance and a mono take is two matching halves.
			// Live recording peaks arrive from the input analysers each tick; the
			// decoded take replaces them when the recorder stops.
			var wave = studioTakeWaveform(take);
			if (wave) {
				var band = (h - 6) / 2;
				var midL = 3 + band / 2;
				var midR = 3 + band + band / 2;
				var amp = (band / 2) * 0.9;
				var view = studioTimelineView();
				// only the peaks the window can show: a zoomed take is many lanes wide
				var b0 = Math.max(0, Math.floor(-x));
				var b1 = Math.min(tw, Math.ceil(w - x));
				// A deeply zoomed clip reads the decoded buffer for its visible
				// columns; the whole-song overview would be a stair-step there.
				// The overview spans the whole file, so its bucket width is the
				// source duration, not the clip's trimmed length.
				var fine = null;
				if (!take.livePeaks && take.buffer && b1 > b0) {
					var sourceSpan = (take.buffer.duration > 0) ? take.buffer.duration : (take.duration || 0);
					var bucket = sourceSpan / Math.max(1, wave.L.length);
					var secPerPx = view.span / Math.max(1, w);
					var rate = take.buffer.sampleRate || 44100;
					var samples = view.span * rate;
					var now = (window.performance && window.performance.now) ? window.performance.now() : Date.now();
					if (!(now - studioFinePeakAt < 20)) { studioFinePeakBudget = 1200000; studioFinePeakAt = now; }
					if (bucket > secPerPx * 4 && samples <= STUDIO_FINE_PEAK_SAMPLES && samples <= studioFinePeakBudget) {
						fine = studioFinePeaks(take, tw, b0, b1);
						studioFinePeakBudget -= samples;
					}
				}
				// The overview covers the whole file; a trimmed or split clip draws
				// only its own in-point and length from it.
				var first = 0, count = wave.L.length;
				if (!take.livePeaks && !fine && take.buffer && take.buffer.duration > 0) {
					var srcDur = take.buffer.duration;
					var takeOff = Math.max(0, take.offset || 0);
					var takeDur = (take.duration > 0) ? take.duration : srcDur;
					if (takeOff > 1e-4 || takeDur < srcDur - 1e-4) {
						first = Math.max(0, Math.floor((takeOff / srcDur) * wave.L.length));
						var last = Math.min(wave.L.length, Math.ceil(((takeOff + takeDur) / srcDur) * wave.L.length));
						count = Math.max(1, last - first);
					}
				}
				ctx.save();
				ctx.beginPath();
				ctx.rect(x, 3, tw, h - 6);
				ctx.clip();
				ctx.strokeStyle = 'rgba(255,255,255,0.85)';
				ctx.lineWidth = 1;
				ctx.beginPath();
				for (var b = b0; b < b1; b++) {
					var lAmp;
					if (fine) { lAmp = fine.L[b - b0] * amp; }
					else {
						var idx = Math.min(count - 1, Math.floor((b / tw) * count)) + first;
						lAmp = wave.L[Math.min(wave.L.length - 1, idx)] * amp;
					}
					ctx.moveTo(x + b, midL - lAmp);
					ctx.lineTo(x + b, midL + lAmp);
				}
				ctx.stroke();
				ctx.beginPath();
				for (var br = b0; br < b1; br++) {
					var rAmp;
					if (fine) { rAmp = fine.R[br - b0] * amp; }
					else {
						var idxR = Math.min(count - 1, Math.floor((br / tw) * count)) + first;
						rAmp = wave.R[Math.min(wave.R.length - 1, idxR)] * amp;
					}
					ctx.moveTo(x + br, midR - rAmp);
					ctx.lineTo(x + br, midR + rAmp);
				}
				ctx.stroke();
				// the divide keeps both channels legible when one is near silence
				ctx.strokeStyle = 'rgba(0,0,0,0.28)';
				ctx.beginPath();
				ctx.moveTo(x, h / 2);
				ctx.lineTo(x + tw, h / 2);
				ctx.stroke();
				ctx.restore();
			}

			// crossfade shading at the junctions
			if (xfDraw > 0 && take.duration) {
				var endT = take.startTime + take.duration;
				var prev = orderedDraw[tIndex - 1];
				var next = orderedDraw[tIndex + 1];
				var shade = function (from, to) {
					var fx = studioTimelineXAt(canvas, from);
					var tx = studioTimelineXAt(canvas, to);
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

			ctx.strokeStyle = selected ? colour : '#04325f';
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

	// a cross-track drag tints the lane the take would land in
	if (typeof studioTakeDrag !== 'undefined' && studioTakeDrag && studioTakeDrag.mode == 'move' && studioTakeDrag.over == ch) {
		ctx.fillStyle = (typeof studioColourRgba === 'function') ? studioColourRgba(colour, 0.12) : 'rgba(20,90,190,0.12)';
		ctx.fillRect(0, 0, w, h);
	}

	if (mixer['time']['position'] > 0) {
		// the playhead only shows while it is inside the visible window
		var px = studioTimelineXAt(canvas, mixer['time']['position']);
		if (px >= 0 && px <= w) {
			ctx.strokeStyle = 'black';
			ctx.lineWidth = 2;
			ctx.beginPath();
			ctx.moveTo(px, 0);
			ctx.lineTo(px, h);
			ctx.stroke();
		}
	}
}

function studioDrawMetre(ch) {
	var co = studioAudio.channels[ch];
	if (!co) { return; }
	// The strip's ten LEDs follow the channel meter: the live input while it is
	// heard, the playback bus while a take plays.
	if (co.meterAnalyser && co.meterData) {
		co.meterAnalyser.getFloatTimeDomainData(co.meterData);
		var msum = 0;
		for (var m = 0; m < co.meterData.length; m++) { msum += co.meterData[m] * co.meterData[m]; }
		var mlevel = Math.min(1, Math.sqrt(msum / co.meterData.length) * 3);
		var lit = Math.round(mlevel * 10);
		$('.studio_strip_meter[channel="' + ch + '"] .studio_strip_led').each(function () {
			var index = parseInt($(this).attr('data-led'), 10) || 0;
			$(this).toggleClass('lit', index < lit);
		});
	}
	var canvas = document.getElementById('channel_volume_metre_' + ch);
	if (!canvas || !co.source) { return; }
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

// ---- the timeline ruler -----------------------------------------------------

// A new song opens as a two minute project. Recording past its end grows the
// song (see studioTransportTick), so the timeline extends from this floor
// instead of starting at zero and following the playhead from the first tick.
var STUDIO_NEW_SONG_SECONDS = 120;

// The ruler (and every lane's time axis) always has a scale: the two minute
// floor stands in for a duration a legacy song never stored.
function studioTimelineDuration() {
	var duration = mixer['time'] && mixer['time']['duration'];
	return (duration > 0) ? duration : STUDIO_NEW_SONG_SECONDS;
}

// ---- the visible window -----------------------------------------------------
// The lanes and the ruler can show less than the whole song. One zoom factor
// (1..32) and the second the window starts on describe it; every time/pixel
// mapping reads the view, so a clip, a tick and a click agree at any zoom.
var studioTimelineZoom = 1;
var studioTimelineStart = 0;
// The deepest zoom keeps a quarter second on screen, whatever the song's
// length, so a 1/64 note is still wide enough to edit; the hard ceiling stops
// a very long song from asking for a sub-pixel window.
var STUDIO_TIMELINE_MIN_SPAN = 0.25;
var STUDIO_TIMELINE_ZOOM_MAX = 1024;

function studioTimelineZoomCeiling(duration) {
	duration = duration || studioTimelineDuration();
	var bySpan = Math.ceil(duration / STUDIO_TIMELINE_MIN_SPAN);
	return Math.max(32, Math.min(STUDIO_TIMELINE_ZOOM_MAX, bySpan));
}

function studioTimelineView() {
	var duration = studioTimelineDuration();
	var ceiling = studioTimelineZoomCeiling(duration);
	var zoom = studioTimelineZoom || 1;
	if (!(zoom >= 1)) { zoom = 1; }
	if (zoom > ceiling) { zoom = ceiling; }
	// The clamped value is the one the next step must start from, so a shorter
	// song cannot leave a deeper zoom waiting to snap back when it grows again.
	studioTimelineZoom = zoom;
	var span = duration / zoom;
	// a shorter song (or a take that shrank it) can leave the window past the end
	var start = Math.max(0, Math.min(studioTimelineStart || 0, duration - span));
	return { start: start, span: span, end: start + span, duration: duration, zoom: zoom };
}

// Put the window back inside the song. Clamping here means a duration change
// cannot leave the stored start out of range for the next zoom step.
function studioTimelineSetStart(seconds) {
	var view = studioTimelineView();
	studioTimelineStart = Math.max(0, Math.min(seconds || 0, view.duration - view.span));
	return studioTimelineStart;
}

// A new song starts on the whole timeline.
function studioTimelineReset() {
	studioTimelineZoom = 1;
	studioTimelineStart = 0;
}

// The visible window on the whole song's own scale: the zoom stretches it wide
// and the start shifts it left. Lanes and the ruler are the whole song's width,
// so this rect is all the geometry a click needs.
function studioTimelineWindowRect(canvas) {
	var rect = canvas.getBoundingClientRect();
	var view = studioTimelineView();
	var width = rect.width * (view.duration / view.span);
	return { left: rect.left - ((view.start / view.span) * rect.width), width: width };
}

// The song time under a canvas x: the window rect carries the view, so one
// multiplication reads the visible window out of the song's own scale.
function studioTimelineTimeAt(canvas, clientX) {
	var rect = studioTimelineWindowRect(canvas);
	if (!rect.width) { return studioTimelineView().start; }
	return ((clientX - rect.left) / rect.width) * studioTimelineDuration();
}

// The inverse: a song time back to a lane x. It is the same window, so it can
// measure straight from the view's start and span.
function studioTimelineXAt(canvas, seconds) {
	var rect = canvas.getBoundingClientRect();
	var view = studioTimelineView();
	if (!rect.width || !view.span) { return 0; }
	return (((seconds || 0) - view.start) / view.span) * rect.width;
}

// A duration as lane pixels: the inverse above measures from the window's
// start, this one measures a length.
function studioTimelineWidth(canvas, seconds) {
	var rect = canvas.getBoundingClientRect();
	var view = studioTimelineView();
	if (!rect.width || !view.span) { return 0; }
	return ((seconds || 0) / view.span) * rect.width;
}

// Seek from any transport state. A playing transport measures its position on
// the audio clock, so a seek re-anchors that clock instead of waiting for the
// tick to overwrite it; the status itself is left alone (a seek is not a play
// and not a stop).
function studioSeek(t) {
	if (!studioCanSeek()) { return false; }
	var duration = studioTimelineDuration();
	if (!(t >= 0)) { t = 0; }
	t = Math.min(t, duration);
	mixer['time']['position'] = t;
	if (mixer['time']['status'] == 'play' && typeof studioClockStart === 'function') {
		studioClockStart(t);
	}
	// A seek moves the cursor, so a locked view follows it even while stopped.
	if (typeof studioFollowCenter === 'function') { studioFollowCenter(); }
	if (typeof studioTimeDisplay === 'function') { studioTimeDisplay(); }
	studioDrawTracks();
	return true;
}

// The finest note grid that still leaves six pixels between ticks: 1/64,
// 1/32, 1/16 or 1/8 of a beat. A beat is a quarter note here, so 1/16 of a
// beat is the 1/64 note the deep zoom exists for.
function studioBeatSubdivision(canvas, view) {
	var beat = studioBeatSeconds();
	var divisions = [1 / 16, 1 / 8, 1 / 4, 1 / 2];
	for (var d = 0; d < divisions.length; d++) {
		var step = beat * divisions[d];
		if (studioTimelineWidth(canvas, step) >= 6) {
			return { step: step, label: '1/' + Math.round(4 / divisions[d]) };
		}
	}
	return null;
}

// Ticks and labels over the timeline. The display button swaps plain seconds
// for bar:beat, so the ruler reads the same way the transport does: 'beats'
// means seconds here too.
function studioDrawRuler() {
	var canvas = document.getElementById('studio_ruler_canvas');
	if (!canvas) { return; }
	studioFitCanvas(canvas);
	var ctx = canvas.getContext('2d');
	if (!ctx) { return; }
	var w = canvas.width, h = canvas.height;
	ctx.clearRect(0, 0, w, h);

	var view = studioTimelineView();
	var style = window.getComputedStyle ? window.getComputedStyle(canvas) : null;
	var themed = function (name, fallback) {
		var value = style ? String(style.getPropertyValue(name) || '').trim() : '';
		return value || fallback;
	};
	var ink = themed('--ink', '#d9dde4');
	var line = themed('--line', 'rgba(128,128,128,0.45)');
	var accent = themed('--accent', '#145abe');

	ctx.font = '9px sans-serif';
	ctx.textBaseline = 'top';
	ctx.lineWidth = 1;

	if (mixer['time'] && mixer['time']['display'] == 'beats') {
		// seconds: the coarsest step that still leaves room for its label
		var ladder = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600];
		var step = ladder[ladder.length - 1];
		for (var s = 0; s < ladder.length; s++) {
			if ((ladder[s] / view.span) * w >= 46) { step = ladder[s]; break; }
		}
		var minor = step / 5;
		// the window is absolute time, so the labels are too
		for (var mi = Math.ceil(view.start / minor); mi * minor <= view.end + 1e-9; mi++) {
			var mx = studioTimelineXAt(canvas, mi * minor);
			var major = (mi % 5) === 0;
			ctx.strokeStyle = line;
			ctx.beginPath();
			ctx.moveTo(mx + 0.5, major ? h - 10 : h - 5);
			ctx.lineTo(mx + 0.5, h);
			ctx.stroke();
			if (major && mx < w - 12) {
				ctx.fillStyle = ink;
				ctx.fillText(String(Math.round(mi * minor * 1000) / 1000), mx + 3, 2);
			}
		}
	}
	else {
		// bars and beats: bar lines taller and labelled, beats shorter
		var bar = studioBarSeconds();
		var beat = studioBeatSeconds();
		var pxBar = studioTimelineWidth(canvas, bar);
		var pxBeat = studioTimelineWidth(canvas, beat);
		var every = 1;
		var spans = [2, 4, 8, 16, 32, 64];
		for (var e = 0; e < spans.length && (pxBar * every) < 46; e++) { every = spans[e]; }
		// The note grid: the finest subdivision that still reads, so a deep
		// zoom shows 1/64 ticks and its name at the right edge.
		var grid = studioBeatSubdivision(canvas, view);
		if (grid) {
			for (var si = Math.ceil(view.start / grid.step); si * grid.step <= view.end + 1e-9; si++) {
				var beats = (si * grid.step) / beat;
				if (Math.abs(beats - Math.round(beats)) < 1e-6) { continue; }
				var sx = studioTimelineXAt(canvas, si * grid.step);
				ctx.strokeStyle = line;
				ctx.beginPath();
				ctx.moveTo(sx + 0.5, h - 3);
				ctx.lineTo(sx + 0.5, h);
				ctx.stroke();
			}
			if (studioTimelineWidth(canvas, grid.step) >= 18) {
				ctx.fillStyle = ink;
				ctx.textAlign = 'right';
				ctx.fillText(grid.label, w - 4, 2);
				ctx.textAlign = 'left';
			}
		}
		if (pxBeat >= 5) {
			for (var bi = Math.ceil(view.start / beat); bi * beat <= view.end + 1e-9; bi++) {
				var bx = studioTimelineXAt(canvas, bi * beat);
				ctx.strokeStyle = line;
				ctx.beginPath();
				ctx.moveTo(bx + 0.5, h - 5);
				ctx.lineTo(bx + 0.5, h);
				ctx.stroke();
			}
		}
		for (var ni = Math.ceil(view.start / bar); ni * bar <= view.end + 1e-9; ni++) {
			var barx = studioTimelineXAt(canvas, ni * bar);
			ctx.strokeStyle = line;
			ctx.beginPath();
			ctx.moveTo(barx + 0.5, h - 10);
			ctx.lineTo(barx + 0.5, h);
			ctx.stroke();
			// the transport numbers its first bar 0, so the ruler does too
			if ((ni % every) === 0 && barx < w - 10) {
				ctx.fillStyle = ink;
				ctx.fillText(String(ni), barx + 3, 2);
			}
		}
	}

	var position = (mixer['time'] && mixer['time']['position']) || 0;
	var px = studioTimelineXAt(canvas, position);
	if (px >= 0 && px <= w) {
		ctx.strokeStyle = accent;
		ctx.lineWidth = 2;
		ctx.beginPath();
		ctx.moveTo(px, 0);
		ctx.lineTo(px, h);
		ctx.stroke();
		ctx.fillStyle = accent;
		ctx.beginPath();
		ctx.moveTo(px - 4, 0);
		ctx.lineTo(px + 4, 0);
		ctx.lineTo(px, 5);
		ctx.closePath();
		ctx.fill();
	}
}

// A delegated handler: the ruler is markup the window can rebuild under us.
$(document).on('click', '#studio_ruler_canvas', function (e) {
	// the ruler is the whole song's scale; the window rect maps the click through
	// the zoomed window and studioSeek then clamps to the whole duration
	var rect = studioTimelineWindowRect(this);
	if (!rect.width) { return; }
	studioSeek(((e.clientX - rect.left) / rect.width) * studioTimelineDuration());
});

// ---- painting only what the viewer can show ---------------------------------
// The transport tick calls studioDrawTracks every 25 ms. A lane is a canvas and
// a strip carries ten LEDs, so painting all 32 tracks is main-thread work on a
// 25 ms budget even when the frame is minimized, Configure covers the viewer,
// or a lane has scrolled out of the viewer. The tick, the audio scheduling and
// the analysers keep running: only this paint stops.

// windows.js minimizes the frame by hiding it (view=minimized), so the
// window's own :visible test is the first gate.
function studioWindowVisible() {
	var studio = $('#studio');
	if (!studio.length || !studio.is(':visible')) { return false; }
	var wind = studio.closest('.wind');
	return !wind.length || wind.is(':visible');
}

function studioViewerVisible() {
	if (document.hidden) { return false; }
	if (!studioWindowVisible()) { return false; }
	// Configure is a full-window sheet: .studio_config_open hides the viewer
	// under it, so there is nothing below the sheet to keep up to date.
	if ($('#studio_config').is(':visible')) { return false; }
	return $('#studio_viewer').is(':visible');
}

// A lane's box in the viewer's own scrolling coordinates, measured once per
// layout change instead of once per lane per tick. The key moves when a lane is
// added or resized, the window resizes, or the scroll extent changes, so the
// cache never outlives the layout it describes.
var studioLaneRectsCache = null;
var studioLaneRectsKey = '';

function studioLaneRects(viewer) {
	var rows = viewer.getElementsByClassName('studio_track');
	var key = rows.length + ':' + viewer.clientWidth + 'x' + viewer.clientHeight + ':' + viewer.scrollHeight;
	if (studioLaneRectsCache && studioLaneRectsKey === key) { return studioLaneRectsCache; }
	var box = viewer.getBoundingClientRect();
	var list = [];
	var tallest = 0;
	for (var i = 0; i < rows.length; i++) {
		var ch = rows[i].getAttribute('data-channel') || '';
		if (!/^[0-9]+$/.test(ch)) { continue; }
		var rect = rows[i].getBoundingClientRect();
		list.push({ ch: ch, top: rect.top - box.top + viewer.scrollTop, height: rect.height });
		if (rect.height > tallest) { tallest = rect.height; }
	}
	studioLaneRectsCache = { list: list, overscan: tallest || 1 };
	studioLaneRectsKey = key;
	return studioLaneRectsCache;
}

// The same for the mixer strips, which scroll both ways and can be hidden with
// their panel; an offscreen strip's LEDs are not worth toggling either.
var studioStripRectsCache = null;
var studioStripRectsKey = '';

function studioStripRects(container) {
	var strips = container.getElementsByClassName('channel');
	var key = strips.length + ':' + container.clientWidth + 'x' + container.clientHeight
		+ ':' + container.scrollWidth + 'x' + container.scrollHeight;
	if (studioStripRectsCache && studioStripRectsKey === key) { return studioStripRectsCache; }
	var box = container.getBoundingClientRect();
	var list = [];
	var widest = 0;
	for (var i = 0; i < strips.length; i++) {
		var match = /(?:^|\s)channel_([0-9]+)(?:\s|$)/.exec(strips[i].className || '');
		if (!match) { continue; }
		var rect = strips[i].getBoundingClientRect();
		list.push({
			ch: match[1],
			left: rect.left - box.left + container.scrollLeft,
			top: rect.top - box.top + container.scrollTop,
			width: rect.width,
			height: rect.height
		});
		if (rect.width > widest) { widest = rect.width; }
	}
	studioStripRectsCache = { list: list, overscan: widest || 1 };
	studioStripRectsKey = key;
	return studioStripRectsCache;
}

// One snapshot per paint: the scrollers' positions and sizes plus the cached
// boxes, so the 25 ms path reads no lane rectangle at all.
function studioPaintViewport() {
	var viewer = document.getElementById('studio_viewer');
	if (!viewer) { return null; }
	var container = document.getElementById('studio_mixer_strips');
	var strips = (container && $(container).is(':visible')) ? studioStripRects(container) : null;
	return {
		lanes: studioLaneRects(viewer),
		scrollTop: viewer.scrollTop,
		height: viewer.clientHeight,
		strips: strips,
		stripLeft: container ? container.scrollLeft : 0,
		stripTop: container ? container.scrollTop : 0,
		stripWidth: container ? container.clientWidth : 0,
		stripHeight: container ? container.clientHeight : 0
	};
}

function studioLaneVisible(view, ch) {
	if (!view || !view.lanes) { return false; }
	var lanes = view.lanes.list;
	var over = view.lanes.overscan;
	for (var i = 0; i < lanes.length; i++) {
		if (lanes[i].ch !== ch) { continue; }
		return lanes[i].top + lanes[i].height + over > view.scrollTop
			&& lanes[i].top - over < view.scrollTop + view.height;
	}
	return false;
}

function studioStripVisible(view, ch) {
	if (!view || !view.strips) { return false; }
	var strips = view.strips.list;
	var over = view.strips.overscan;
	for (var i = 0; i < strips.length; i++) {
		if (strips[i].ch !== ch) { continue; }
		return strips[i].top + strips[i].height + over > view.stripTop
			&& strips[i].top - over < view.stripTop + view.stripHeight
			&& strips[i].left + strips[i].width + over > view.stripLeft
			&& strips[i].left - over < view.stripLeft + view.stripWidth;
	}
	return false;
}

// A lane scrolled into view is blank until the next tick paints it, and while
// the transport is stopped there is no next tick. One rAF after a scroll or
// resize repaints what the viewer now shows; nothing is queued while the
// window is hidden, because there is no on-screen lane to bring up to date.
var studioRedrawQueued = false;

function studioQueueRedraw() {
	if (studioRedrawQueued || !studioViewerVisible()) { return; }
	studioRedrawQueued = true;
	var run = function () {
		studioRedrawQueued = false;
		if (!studioViewerVisible()) { return; }
		studioDrawTracks();
	};
	if (window.requestAnimationFrame) { window.requestAnimationFrame(run); }
	else { window.setTimeout(run, 16); }
}

// Scroll does not bubble, so this is bound in the capture phase; the viewer and
// the mixer strips are the only scrollers a paint depends on.
document.addEventListener('scroll', function (event) {
	var target = event.target;
	if (!target || (target.id !== 'studio_viewer' && target.id !== 'studio_mixer_strips')) { return; }
	if (!studioViewerVisible()) { return; }
	studioQueueRedraw();
}, { capture: true, passive: true });

window.addEventListener('resize', function () {
	if (!studioViewerVisible()) { return; }
	studioQueueRedraw();
});

function studioDrawTracks() {
	if (!studioViewerVisible()) { return; }
	studioDrawRuler();
	// The ruler is above the viewer, so it is painted whole; only the lanes the
	// viewer can show, and the strips the mixer can show, are worth a canvas.
	var view = studioPaintViewport();
	$.each(mixer, function (ch) {
		if (!/^[0-9]+$/.test(ch)) { return; }
		if (studioLaneVisible(view, ch)) { studioDrawChannel(ch); }
		if (studioStripVisible(view, ch)) { studioDrawMetre(ch); }
	});
}

// ---- zooming the timeline ---------------------------------------------------
// Ctrl+wheel (a trackpad pinch arrives the same way in Chromium) narrows the
// window to less of the song; a plain wheel is still the panel's vertical
// scroll. The zoom is anchored: the time under the pointer stays under it.

// The lane under the pointer, or the ruler itself. Every lane shares the
// ruler's horizontal scale, so any lane can measure a point in the viewer.
function studioTimelineCanvasFor(target) {
	if (!target || !target.closest) { return null; }
	var ruler = target.closest('#studio_ruler_canvas');
	if (ruler) { return ruler; }
	if (!target.closest('#studio_viewer')) { return null; }
	return target.closest('canvas.track') || document.querySelector('#studio_viewer canvas.track');
}

// Zoom by `factor` about the canvas point, keeping that point's time fixed. A
// locked view running the transport re-centers on the playhead instead: there
// the playhead is the anchor the person asked to follow.
function studioTimelineZoomAt(canvas, clientX, factor) {
	var view = studioTimelineView();
	var time = studioTimelineTimeAt(canvas, clientX);
	var rect = canvas.getBoundingClientRect();
	var ceiling = studioTimelineZoomCeiling(view.duration);
	studioTimelineZoom = Math.max(1, Math.min(ceiling, view.zoom * factor));
	// the point's fraction of the window is unchanged; only its span is narrower
	var frac = rect.width ? (clientX - rect.left) / rect.width : 0.5;
	studioTimelineSetStart(time - (frac * (view.duration / studioTimelineZoom)));
	if (typeof studioFollowView === 'function') { studioFollowView(); }
	studioDrawTracks();
}

function studioTimelineWheel(event) {
	var canvas = studioTimelineCanvasFor(event.target);
	if (!canvas) { return; }
	studioTimelineZoomAt(canvas, event.clientX, Math.exp(-event.deltaY * 0.0015));
	event.preventDefault();
}

// A pinch arrives as gesture events on some platforms and as a ctrl+wheel on
// Chromium; whichever arrives first owns the zoom, so the other cannot apply
// the same pinch twice.
var studioTimelineGestureActive = false;
var studioTimelineGestureScale = 1;

// Bound natively in the capture phase and non-passively: the WebUI's own
// ctrl+wheel handling must not run before the timeline has taken the event, and
// only a listener that is not passive can cancel the page zoom.
document.addEventListener('wheel', function (event) {
	if (!event.ctrlKey && !event.metaKey) { return; }
	if (studioTimelineGestureActive) { return; }
	if (!studioTimelineCanvasFor(event.target)) { return; }
	studioTimelineWheel(event);
}, { capture: true, passive: false });

document.addEventListener('gesturestart', function (event) {
	if (!studioTimelineCanvasFor(event.target)) { return; }
	studioTimelineGestureActive = true;
	studioTimelineGestureScale = 1;
	event.preventDefault();
}, { capture: true, passive: false });

// event.scale is cumulative since the gesture began, so only the change since
// the last event is this step's factor; the centre stays where it started.
document.addEventListener('gesturechange', function (event) {
	if (!studioTimelineGestureActive) { return; }
	var canvas = studioTimelineCanvasFor(event.target);
	if (!canvas) { return; }
	var scale = event.scale || 1;
	var factor = scale / (studioTimelineGestureScale || 1);
	studioTimelineGestureScale = scale;
	if (factor !== 1) { studioTimelineZoomAt(canvas, event.clientX, factor); }
	event.preventDefault();
}, { capture: true, passive: false });

document.addEventListener('gestureend', function () {
	studioTimelineGestureActive = false;
	studioTimelineGestureScale = 1;
}, { capture: true, passive: false });

function studioUpdateFxBadges() {
	$.each(studioAudio.channels, function (ch, c) {
		var holder = $('.channel_fx[channel="' + ch + '"]');
		holder.empty();
		c.inserts.forEach(function (ins) {
			// The pedal artwork is handed over once by the template, keyed by the
			// pedal's own name; match the effect kind so an alias (reverb2 for
			// reverb) finds the same picture.
			var kind = studioEffectKind(ins.name);
			var src = '';
			$.each(window.jawnos_studio_pedal_art || {}, function (pedal, url) {
				if (studioEffectKind(pedal) === kind) { src = url; return false; }
			});
			if (src) {
				$('<img class="channel_fx_pedal">').attr('src', src).attr('hint', ins.name)
					.toggleClass('studio_fx_bypassed', !!ins.bypassed).appendTo(holder);
				return;
			}
			// An effect with no artwork is a text tile, so the badge still names it.
			var spec = studioEffectSpec(ins.name);
			$('<span class="channel_fx_text"></span>')
				.attr('hint', ins.name)
				.text(spec && spec['label'] ? studioLayoutText(spec['label']) : ins.name)
				.toggleClass('studio_fx_bypassed', !!ins.bypassed)
				.appendTo(holder);
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
		var shown = (control === 'semitones' && typeof studioKnobDisplay === 'function')
			? studioKnobDisplay(knob, input.val())
			: value;
		knob.attr('hint', String(control).replace(/_/g, ' ') + ': ' + shown);
	});
}

// ---- take editing on the canvas --------------------------------------------

// How far to pull a freshly recorded take back in time to cancel the round
// trip. An explicit record_offset (ms) in the song admin wins; otherwise use
// the AudioContext's reported output latency plus whatever the input stream
// reports for itself, since the browser's output figure on its own is often an
// under-estimate of what the player actually hears and plays against.
