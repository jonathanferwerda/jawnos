var clothesLineHeight = 40;
var clothesLinePos = {
	x: 0, 
	y: 0, 
	minHeight: 0, 
	maxHeight: 0, 
	lastBX: undefined, 
	lastX: undefined, 
	moving: Date.now() - 300, 
	startMove: undefined,
	exists: 0,
	bordersize: 5,
	// whether the wheel at hand belongs to a trackpad. Seeded from the last
	// session and settled by wheelKind() below; while it is set, the press-and-
	// drag grab stands down, since a swipe already moves the canvas.
	trackpad: localStorage.getItem('trackpad') == 'yes'
};
var wardrobe = [];
var hangingClothes = 0;

// The timeline is at rest when nothing has moved it for a settle and no grab is
// in hand. The settle is short on purpose: the poll's corrections only need the
// gesture to be over before they land, and a shorter one lets the view answer
// the server sooner after a touch. A finger resting on the canvas counts as
// motion (the touchstart below), so the settle only has to cover the gap
// between events.
var clothesLineRest = 150;
function clothesLineAtRest() {
	return clothesLinePos['moving'] + clothesLineRest < Date.now() && clothesLinePos['lastBX'] == undefined;
}

// What the keyboard's config keeps per device, seeded into keyboard_sensitivity
// by the layout: a swipe is damped to this much of the finger travel, and the
// clothesline's drag to that much of its own. The fallbacks are what the two
// were before either could be set.
function keyboardSensitivity(setting, fallback) {
	var set = (typeof keyboard_sensitivity != 'undefined') ? numeral(keyboard_sensitivity[setting]).value() : NaN;
	return (isFinite(set) && set > 0) ? set : fallback;
}
var trackpadSensitivity = keyboardSensitivity('trackpad', .02);
var clotheslineSensitivity = keyboardSensitivity('clothesline', .4);
function clotheslineHanger(clothes) {

	if (hangingClothes == 0) {
		hangingClothes = 1;
		// a missing list must not throw here - the caller dies with it and then
		// nothing else on the canvas gets printed either
		if (!clothes) { clothes = []; }
		wardrobe = clothes;
		var maxWidth = 140;
		var totalWidth = maxWidth * clothes.length;
		var layout = localStorage.getItem('layout');
		var canvas = layout ? document.getElementById(layout) : undefined;
		if (!canvas) { hangingClothes = 0; return; }
		ctx = canvas.getContext('2d');
		// the rail hangs over whatever is behind it - a background picture, a
		// window - so the themed ink is laid over a contrasting halo instead of
		// being trusted to show up on its own. Only worth it over a picture: on the
		// page itself the halo reads as a white (or black) fringe around the rail.
		// (Guard the helper: a browser holding an older universal.js must not lose
		// the whole clothesline.)
		var ink = jawnosInk();
		var halo = undefined;
		if (localStorage.getItem('background_images') == 'on' && typeof jawnosInkHalo == 'function') {
			halo = jawnosInkHalo(ink);
		}
		if (halo) {
			ctx.strokeStyle = halo;
			ctx.lineWidth = clothesLinePos['bordersize'] + 3;
		}
		else {
			ctx.strokeStyle = ink;
			ctx.lineWidth = clothesLinePos['bordersize'];
		}
		ctx.beginPath();

		var minHeight = headerHeight;
		var maxHeight = minHeight + (clothesLineHeight);
		clothesLinePos['minHeight'] = minHeight;
		clothesLinePos['maxHeight'] = maxHeight;
		if (clothes.length > 0) {
			clothesLinePos['exists'] = 1;
			ctx.clearRect(0,minHeight,canvas.width,clothesLineHeight);
			ctx.moveTo(0,minHeight);
			ctx.lineTo(canvas.width, minHeight);
			ctx.moveTo(0,minHeight + clothesLineHeight);
			ctx.lineTo(canvas.width, minHeight + clothesLineHeight);
			ctx.stroke();
			ctx.strokeStyle = ink;
			ctx.lineWidth = clothesLinePos['bordersize'];
			ctx.stroke();
		}

		ctx.strokeStyle = ink;
		ctx.lineWidth = clothesLinePos['bordersize'];
		ctx.font = "400 20px Times New Roman";

		$.each(clothes, function(i,v) {

			v['type'] = 'clothes';
			var clothingDrive = [];
			$.each(appPosition, function(ie,ve) {
				if (v['app'] == ve[4]['app'] && v['type'] == 'clothes') {
					clothingDrive.push(ie);
				}
			});
			$.each(clothingDrive.reverse(), function(ie,ve) {
				appPosition.splice(ve,1);
			});
			var startW = (i * maxWidth) + clothesLinePos['x'];
			var endW = startW + maxWidth;

			ctx.fillStyle = v.colour || 'yellow';
			ctx.strokeRect(startW,minHeight,maxWidth,clothesLineHeight);
			ctx.fillRect(startW,minHeight,maxWidth,clothesLineHeight);
			ctx.fill();
			// outlined, so the name reads over any garment colour or picture
			var textMeasure = ctx.measureText(v.formatted_name).width;
			var textPos = ((maxWidth - textMeasure) / 2) + startW;
			if (halo) {
				ctx.lineWidth = 3;
				ctx.strokeStyle = halo;
				ctx.strokeText(v.formatted_name, textPos, maxHeight - (clothesLineHeight / 3));
			}
			ctx.fillStyle = ink;
			ctx.fillText(v.formatted_name,  textPos ,  maxHeight - (clothesLineHeight / 3));
			ctx.lineWidth = clothesLinePos['bordersize'];
			ctx.fill();
			ctx.stroke();

			appPosition.push([startW , minHeight , endW, maxHeight, v]);
		});
		hangingClothes = 0;
	}
}


$(document).on('touchmove', '.background', function(m) {
	var w = $(this);
	var id = $(this).attr('id');
	clothesLinePos['moveTimeout'] = timestamp;
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	if (m.originalEvent.targetTouches) {
		x = m.originalEvent.targetTouches[0].clientX;
		y = m.originalEvent.targetTouches[0].clientY;
	}
	x = numeral(x - w.offset().left).value();
	y = numeral(y - w.offset().top).value();
	if ((y <= clothesLinePos['maxHeight'] && y >= clothesLinePos['minHeight']) && (clothesLinePos['startMove'] == undefined || clothesLinePos['startMove'] == 'clothesline')) {
		if (clothesLinePos['lastX'] == undefined) {
			clothesLinePos['lastX'] = x;
		}
		if (clothesLinePos['startMove'] == undefined) {
			clothesLinePos['startMove'] = 'clothesline';
		}
		var mouseDiff = x - clothesLinePos['lastX'];
		clothesLinePos['lastX'] = x;
		clothesLinePos['x'] += mouseDiff;
		clothesLinePos['y'] = y;
		if (clothesLinePos['startMove'] == 'clothesline') {
			clotheslineScroller(x,y,(mouseDiff * clotheslineSensitivity));
		}
	}
	else if ((y >= clothesLinePos['maxHeight'] && (id == 'timeline' || id == 'clockface')) && ( clothesLinePos['startMove'] == undefined || clothesLinePos['startMove'] == 'canvas')) {
		clothesLinePos['moving'] = Date.now();
		if (clothesLinePos['lastBX'] == undefined) {
				clothesLinePos['lastBX'] = x;
		}
		var mouseDiff = (x - clothesLinePos['lastBX']);
		clothesLinePos['lastBX'] = x;
		if (clothesLinePos['startMove'] == undefined) {
			clothesLinePos['startMove'] = 'canvas';
		}
		if (clothesLinePos['startMove'] == 'canvas') {

			if (id == 'timeline') {
				timelineScroller({ mousediff: mouseDiff });
			}
			else if (id == 'clockface') {
				clockfaceScroller({ mousediff: diff });
			}
		}
	}

});

// A finger down is not rest, whatever it does next: without this, a finger that
// never moves is invisible to the guard, and the server's slide could set the
// view going under it. The mouse's own press marks the same state in the
// mousedown below.
$(document).on('touchstart', '.background', function (m) {
	var w = $(this);
	if (w.attr('id') != 'timeline') { return; }
	var touch = (m.originalEvent.touches && m.originalEvent.touches[0]) || m.originalEvent;
	if (!touch) { return; }
	var y = numeral(touch.clientY - w.offset().top).value();
	if (y < clothesLinePos['maxHeight']) { return; }
	clothesLinePos['moving'] = Date.now();
});

// A mouse drag on the canvas below the clothesline is a grab: it slides the
// timeline and glides, exactly like a touch drag. The wheel is not a grab - it
// stays a regular scroll.
$(document).on('mousedown', '.background', function(m) {
	var w = $(this);
	if (w.attr('id') != 'timeline' || m.which != 1) { return; }
	// a trackpad moves the canvas with its swipe, so once one has been seen the
	// press-and-drag grab would only be in the way
	if (clothesLinePos['trackpad']) { return; }
	var y = numeral(m.clientY - w.offset().top).value();
	if (y < clothesLinePos['maxHeight']) { return; }
	clothesLinePos['moving'] = Date.now();
	clothesLinePos['mouseDrag'] = 1;
	clothesLinePos['dragged'] = 0;
	clothesLinePos['lastBX'] = numeral(m.clientX - w.offset().left).value();
});

$(document).on('mousemove', '.background', function(m) {
	if (!clothesLinePos['mouseDrag'] || clothesLinePos['lastBX'] == undefined) { return; }
	var w = $(this);
	var x = numeral(m.clientX - w.offset().left).value();
	var mouseDiff = (x - clothesLinePos['lastBX']);
	clothesLinePos['lastBX'] = x;
	clothesLinePos['moving'] = Date.now();
	if (Math.abs(mouseDiff) > 1) { clothesLinePos['dragged'] = 1; }
	timelineScroller({ mousediff: mouseDiff });
});

$(document).on('mouseout touchend mouseup', '.background', function() {
	if (clothesLinePos['lastBX']) {
	//	calculator();
	}
	clothesLinePos['lastX'] = undefined;
	clothesLinePos['lastBX'] = undefined;
	clothesLinePos['startMove'] = undefined;
	clothesLinePos['mouseDrag'] = 0;
	//clothesLinePos['velocities'] = [];
});

// A wheel is a `wheel` event in every engine that has one; `mousewheel` is only
// for an engine too old for it. Binding both would double up where one gesture
// is dispatched under both names, so let the engine pick.
var wheelEvent = ('onwheel' in document) ? 'wheel' : 'mousewheel';

$(document).on(wheelEvent, '.background', function(e) {
	clothesLinePos['moving'] = Date.now();
	var w = $(this);
	var id = $(this).attr('id');
	var o = e.originalEvent || e;

	// the browser's own pixels. jQuery copies neither deltaX/deltaY nor
	// wheelDelta onto its event object, so they are read from the original
	// event; an engine with only the legacy wheelDelta (a notch was 120 of
	// them, and moved the timeline 24 pixels) is converted to the same pixels.
	var deltaX = wheelNumber(o.deltaX);
	var deltaY = wheelNumber(o.deltaY);
	var wheelDelta = wheelNumber(o.wheelDelta);
	var wheelDeltaX = wheelNumber(o.wheelDeltaX);

	// the wheel says which device it came from, and only says it once in a while:
	// keep the answer for the session, and let the grab above read it
	var kind = wheelKind(deltaX, deltaY, wheelNumber(o.deltaMode));
	if (kind) {
		clothesLinePos['trackpad'] = (kind == 'trackpad') ? 1 : 0;
		localStorage.setItem('trackpad', clothesLinePos['trackpad'] ? 'yes' : 'no');
	}

	if (!deltaX && !deltaY && !wheelDelta && !wheelDeltaX) { return; }
	if (!wheelDelta) {
		wheelDelta = -5 * (Math.abs(deltaX) > Math.abs(deltaY) ? deltaX : deltaY);
	}
	if (!deltaX && !deltaY && (wheelDelta || wheelDeltaX)) {
		deltaX = -1 * (numeral(wheelDeltaX / 5).value());
		deltaY = -1 * (numeral(wheelDelta / 5).value());
	}

	var diff = -1 * (numeral(wheelDelta / 5).value());
	var x = (o.clientX != undefined) ? numeral(o.clientX).value() : mouse_position().x;
	var y = (o.clientY != undefined) ? numeral(o.clientY).value() : mouse_position().y;

	if (y <= clothesLinePos['maxHeight'] && y >= clothesLinePos['minHeight']) {
		if (clothesLinePos['startMove'] == undefined) {
			clothesLinePos['startMove'] = 'clothesline';
		}
		if (clothesLinePos['startMove'] == 'clothesline') {
			var source;
 			if (Math.abs(deltaY) > 4 && deltaX === 0) {
				source = 'mousewheel';
			}

			clotheslineScroller(x,y,(diff * clotheslineSensitivity), source);
		}
	}
	else if (y >= clothesLinePos['maxHeight'] && (id == 'timeline' || id == 'clockface')) {
		if (clothesLinePos['startMove'] == undefined) {
			clothesLinePos['startMove'] = 'canvas';
		}
		if (clothesLinePos['startMove'] == 'canvas') {
			if (id == 'timeline') {
				var motion = timelineWheelMotion(deltaX, deltaY);
				if (motion.glide) { timelineFling(motion.mousediff); }
				timelineScroller({ mousediff: motion.mousediff, source: motion.glide ? 'wheel' : 'mousewheel' });
			}
			else if (id == 'clockface') {
				clockfaceScroller({ mousediff: diff });
			}
		}
	}
	clothesLinePos['startMove'] = undefined;
});

function clotheslineScroller(x,y,diff,source) {
	if (y >= clothesLinePos['minHeight'] && y <= clothesLinePos['maxHeight']) {
		clothesLinePos['x'] = clothesLinePos['x'] + diff;
		clotheslineHanger(wardrobe);
		if (source != 'smoothScroll' && source != 'mousewheel') {
			// Glide to a stop on requestAnimationFrame instead of a 5ms interval: rAF
			// is capped at the screen refresh rate and pauses while the tab is hidden.
			// Keep the old timer's reach -- it moved `diff` and then decayed it by .97
			// every 5ms, so a flick travels 0.97/0.03 (~32x) its distance -- and only
			// spread that over however many frames the screen actually gives us.
			cancelAnimationFrame(clothesLinePos['smoothScrolling']);
			var last = undefined;
			var reach = .97 / .03;
			var glide = function(now) {
				if (Math.abs(diff) <= 0.09) {
					clothesLinePos['smoothScrolling'] = undefined;
					return;
				}
				if (last == undefined) { last = now; }
				var decay = Math.pow(.97, (now - last) / 5);
				last = now;
				var step = diff * reach * (1 - decay);
				diff = diff * decay;
				clothesLinePos['smoothScrolling'] = requestAnimationFrame(glide);
				clotheslineScroller(x,y,step,'smoothScroll');
			};
			clothesLinePos['smoothScrolling'] = requestAnimationFrame(glide);
		}
	}
}


function clockfaceScroller(data) {
	if (data.mousediff < 0) {
		localStorage.setItem('scrollPositioner', 	localStorage.getItem('scrollPositioner') * 1.05);
	}
	else {
		localStorage.setItem('scrollPositioner', 	localStorage.getItem('scrollPositioner') * .95);
	}
	graphicalize(response);
}

// How a wheel event moves the timeline: horizontal is a trackpad swipe that
// grabs the canvas, so it glides; anything vertical - a wheel, or a trackpad
// pushed up and down - is a plain scroll, and does not. Vertical keeps the
// direction the wheel has always had here: a notch that would walk a page up
// walks the timeline forward, as it does over the clothesline and the
// clockface. The deltas are the browser's own pixels.
//
// A trackpad's deltas are fine-grained and arrive in floods, and the flick it
// leaves behind carries well past the fingers, so a swipe is damped to a
// twentieth of the finger travel. Everything that follows - the move and the
// glide it is armed with - scales with trackpadSensitivity (above), which the
// keyboard's config sets. A positive deltaX - a scroll to the right in the
// DOM's own terms - walks the timeline back, the same way dragging the canvas
// to the right does.
function timelineWheelMotion(deltaX, deltaY) {
	if (Math.abs(deltaX) > Math.abs(deltaY)) {
		return { mousediff: trackpadSensitivity * (numeral(deltaX).value()), glide: 1 };
	}
	return { mousediff: numeral(deltaY).value(), glide: 0 };
}

// a number from an event field; a missing one is zero and never a NaN
function wheelNumber(v) {
	var n = numeral(v).value();
	return isFinite(n) ? n : 0;
}

// The browser will not say whether a wheel came from a trackpad or a mouse:
// PointerEvent.pointerType answers 'mouse' for both, and matchMedia only tells
// coarse from fine. The stream itself does say it. A mouse sends one coarse,
// whole-numbered notch at a time - tens of pixels straight down, and no
// sideways part - while a trackpad sends fine, often fractional pixels in
// floods, and only a trackpad leans sideways. An event only one of them could
// have produced settles the question; a slow, whole, small, vertical step is
// read as the trackpad, since a mouse has no notch that small.
function wheelKind(deltaX, deltaY, deltaMode) {
	if (!deltaX && !deltaY) { return undefined; }
	if (deltaX !== 0) { return 'trackpad'; }
	if (deltaMode !== 0) { return 'mouse'; }
	if (!Number.isInteger(deltaY)) { return 'trackpad'; }
	return Math.abs(deltaY) >= 40 ? 'mouse' : 'trackpad';
}

function timelineScroller(data) {
	var wp = 0;
	var span = response.appts['__specs']['end'] - response.appts['__specs']['start'];
	var ww = $('#background').width();

		
	if (data.mousediff) {
		wp = data.mousediff / ww;
	}
	else if (data.diff) {
		wp = (data.diff) / span;
	}

	var sdiff = span * wp;
	if (data['sdiff']) {
		sdiff = data['sdiff'];
	}
	else {
		data['sdiff'] = sdiff;
	}

	var scope = localStorage.getItem('scope');
	var period = response.appts['__specs']['period'];
	// the centre the time machine alone stands for. The separate timeshift is not
	// folded into it: the drag below writes this back into #time_machine, and
	// anchoring the string on the final centre would count the timeshift again on
	// every poll, so each slide marched the view further back than the last.
	var tm_timestamp = response.appts['__specs']['time_machine_timestamp'] || response.appts['__specs']['timestamp'];
	response.appts['__specs']['end'] = response.appts['__specs']['end'] - sdiff;
	response.appts['__specs']['start'] = response.appts['__specs']['start'] - sdiff;
	response.appts['__specs']['timestamp'] = (numeral(response.appts['__specs']['timestamp']).value() - sdiff);
	response.appts['__specs']['time_machine_timestamp'] = (numeral(tm_timestamp).value() - sdiff);
	// the edge the fetch reached to travels with the view, or the prune would
	// drop the rows that were fetched to stick to it
	if (response.appts['__specs']['fetch_start'] != undefined) {
		response.appts['__specs']['fetch_start'] = numeral(response.appts['__specs']['fetch_start']).value() - sdiff;
	}

	var ts = quality_inventory(numeral(response.appts['__specs']['time_machine_timestamp']).value() );
	if (!$('#time_machine').is(':focus') && (data.mousediff || data['source'] == 'smoothScroll')) {
		$('#time_machine').val(ts)
		localStorage.setItem('time_machine', ts);
	}
//	timestamp = response.appts['__specs']['timestamp'];
	$.each(response.appts, function(i,ve) {

		if (!i.match('__')) {
			$.each(ve['list'], function(ie,v) {
				var point = v['timestamp'] - response.appts['__specs']['start'];
				var total = response.appts['__specs']['timestamp'] - response.appts['__specs']['start'];
				var percent = point / total;
				v[scope + '_percent'] = percent;
				if (v['duration']) {
					point = v['timestamp'] - v['duration'] - response.appts['__specs']['start'];
					percent = point / total;
					v[scope + '_start_percent'] = percent;
					if (v['type'] == 'start' && v['timestamp'] < response.appts['__specs']['timestamp']) {
						var dur = (response['appts']['__specs']['timestamp'] - v['timestamp']) * -1;
						if (v['duration'] > dur) { v['duration'] = dur; }
					}
				}
				ve['placement_number'] = undefined;
			});
		}
	});
	graphicalize(response);
	if (data['source'] == 'wheel') {
		// a wheel stream carries its own momentum: the fling that follows the
		// stream is the glide, and a new event means the fingers took over.
		// A plain wheel and the server's slide are not glided - they go exactly
		// where they are put.
		cancelAnimationFrame(clothesLinePos['timelineSmoothScrolling']);
	}
	else if (data['source'] != 'smoothScroll' && data['source'] != 'mousewheel' && data['source'] != 'slide') {
		timelineGlide(sdiff);
	}

}

// The clothesline's glide, measured in time instead of pixels: a flick carries
// about 32x its distance, spread over however many frames the screen actually
// gives us, and it pauses with the tab. Each step lands like an input event
// would, so the time machine field keeps up and the next poll does not snap the
// view back mid-flight.
function timelineGlide(diff) {
	var span = response.appts['__specs']['end'] - response.appts['__specs']['start'];
	var ww = $('#background').width();
	cancelAnimationFrame(clothesLinePos['timelineSmoothScrolling']);
	var last = undefined;
	var reach = .97 / .03;
	var glideDiff = diff;
	var stopAt = (span / ww) * .09;
	var glide = function(now) {
		if (Math.abs(glideDiff) <= stopAt) {
			clothesLinePos['timelineSmoothScrolling'] = undefined;
			return;
		}
		if (last == undefined) { last = now; }
		var decay = Math.pow(.97, (now - last) / 5);
		last = now;
		var step = glideDiff * reach * (1 - decay);
		glideDiff = glideDiff * decay;
		clothesLinePos['moving'] = Date.now();
		clothesLinePos['timelineSmoothScrolling'] = requestAnimationFrame(glide);
		timelineScroller({ sdiff: step, source: 'smoothScroll' });
	};
	clothesLinePos['timelineSmoothScrolling'] = requestAnimationFrame(glide);
}

// A trackpad swipe arrives as a stream of small wheel events, and the last of
// them are often tiny as the fingers slow - which is why swiping only glided
// while the fingers were still moving. Keep the movement of the last fraction
// of a second instead, and when the stream has been quiet for a moment, glide
// from that velocity - one frame of it, the same starting point a touch flick
// gets from its last movement.
function timelineFling(diff) {
	var fling = clothesLinePos['fling'] = clothesLinePos['fling'] || { samples: [], settle: undefined };
	var now = Date.now();
	fling['samples'].push([now, diff]);
	while (fling['samples'].length > 1 && now - fling['samples'][0][0] > 160) { fling['samples'].shift(); }
	clearTimeout(fling['settle']);
	fling['settle'] = setTimeout(function() {
		fling['settle'] = undefined;
		var kept = fling['samples'];
		fling['samples'] = [];
		var moved = 0;
		$.each(kept, function(i,s) { moved += s[1]; });
		var elapsed = kept[kept.length - 1][0] - kept[0][0];
		// the samples arrive already damped by the swipe's sensitivity, so a
		// still finger is a hundredth of a pixel, not two
		if (Math.abs(moved) < 0.2 || elapsed <= 0) { return; }
		// the samples are pixels of finger travel; the glide moves in time, so one
		// frame of the swipe has to cross the same bridge a wheel event does
		var span = response.appts['__specs']['end'] - response.appts['__specs']['start'];
		var ww = $('#background').width();
		if (!ww) { return; }
		timelineGlide(((moved / elapsed) * 16) * (span / ww));
	}, 80);
}

$(document).on('click', '.clothesline', function() {
	var timestamp = Date.now();
	var app = $(this).attr('app');
	$.ajax({
		url: '/manager/clothesline',
		type: 'GET',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			$('#alert').html(response.html).show();
		}
	});
});

$(document).on('change', '.clothes', function() {
	var timestamp = Date.now();
	var setting = $(this).attr('setting');
	var value = $(this).val();
	var app = $(this).attr('app');

	var data = { timestamp: timestamp, setting: setting, value: value, app: app };
	if ($(this).is('select[multiple]')) {
		data['value'] = JSON.stringify(value);
		data['is_json'] = 'yes';
	}
	$.ajax({
		url: '/manager/clothesline',
		type: 'POST',
		data: data,
		success: function(response) {
		}
	});
});

$(document).on('click', '.clothes_picker', function() {
	var shirt = $(this);
	var app = shirt.attr('app');
	var td = shirt.attr('td');
	if (shirt.attr('re') == 'all') {
		if (shirt.attr('wearing') == 'on') {		
			$('.clothes_picker[app="' + app + '"][td="' + td + '"]').attr('wearing', 'off');
		}
		else {
			$('.clothes_picker[app="' + app + '"][td="' + td + '"]').attr('wearing', 'on');
		}
	}
	else {
		if (shirt.attr('wearing') == 'on') {
			shirt.attr('wearing', 'off');
		}
		else {
			shirt.attr('wearing', 'on');
		}
	}
	var time_plinko = {};
	$('.clothes_picker[wearing="on"]').each(function(i,v) {
		var td = $(v).attr('td');
		var re = $(v).attr('re');

		if (!time_plinko[td]) { time_plinko[td] = []; }
		time_plinko[td].push(re);
	});

	var setting = 'time_plinko';
	var value = JSON.stringify(time_plinko);
	$.ajax({
		url: '/manager/clothesline',
		type: 'POST',
		data: { setting: setting, value: value, app: app, timestamp: timestamp, is_json: 'yes' },
		success: function(response) {
		}
	});
});