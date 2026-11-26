// What this machine advertises to the house watcher (jp_data, sent on the
// server heartbeat while Me's advertise_watching is on). A beat is every ten
// seconds, but re-encoding a picture that did not change is wasted work: a
// paused video, an idle whiteboard, a still camera. So each source keeps one
// canvas and its last encoded frame, and the frame is redrawn only when the
// source's own clock moves. JPEG keeps both the encode and the carried bytes
// small; a two-hundred-pixel preview does not need a lossless PNG.
var jp_watch = {};
var JP_WATCH_WIDTH = 480;
var JP_WATCH_QUALITY = 0.7;

// One source's advertisement, drawn into its cached canvas. `at` is the part
// of the source that says the picture changed: a video's own clock while it
// plays, and a constant while it is paused or has no frame yet. `fill` covers
// a source whose own paint is transparent (the whiteboard), so the JPEG has a
// background instead of black. `live` is a source with no clock of its own (the
// whiteboard canvas): it is redrawn every beat while it is on screen.
function jpWatchFrame(source, id, fill, live) {
	if (!source) { return null; }
	var sw = source.videoWidth || source.width || 0;
	var sh = source.videoHeight || source.height || 0;
	if (!sw || !sh) { return null; }
	var cache = jp_watch[id] || (jp_watch[id] = { canvas: document.createElement('canvas'), ctx: null, image: '', key: '', ratio: 0, width: 0, height: 0 });
	var still = !live && ((source.paused === true) || (source.ended === true)
		|| (source.readyState !== undefined && source.readyState < 2));
	// a video with no decoded frame yet has nothing to draw; do not cache a
	// black first picture that would then look unchanged
	if (still && !cache.image && source.readyState !== undefined && source.readyState < 2) { return null; }
	var at = still ? 'still' : (live ? Date.now() : (Math.floor((source.currentTime || 0) * 100) / 100));
	var ratio = sw / sh;
	var cw = Math.min(JP_WATCH_WIDTH, sw);
	var ch = Math.max(1, Math.round(cw / ratio));
	var key = cw + 'x' + ch + '@' + at;
	if (cache.image && cache.key === key) { return cache; }
	var canvas = cache.canvas;
	// assigning width or height clears the canvas and its context state, so
	// only touch them when the shape actually moved
	if (canvas.width !== cw || canvas.height !== ch) {
		canvas.width = cw;
		canvas.height = ch;
		cache.ctx = null;
	}
	var ctx = cache.ctx || (cache.ctx = canvas.getContext('2d'));
	if (fill) {
		ctx.fillStyle = fill;
		ctx.fillRect(0, 0, cw, ch);
	}
	ctx.drawImage(source, 0, 0, cw, ch);
	try {
		cache.image = canvas.toDataURL('image/jpeg', JP_WATCH_QUALITY);
	}
	catch (e) {
		cache.image = '';
	}
	cache.key = key;
	cache.ratio = cw / ch;
	cache.width = cw;
	cache.height = ch;
	return cache;
}

function jpWatcher() {
	var returner = {};
	var add = function(list) {
		$.each(list || [], function(i, v) {
			var id = $(v).attr('id');
			var source = document.getElementById(id);
			if (!source || !$(source).is('video')) { return; }
			var frame = jpWatchFrame(source, id);
			if (frame) {
				returner[i] = { 'image': frame.image, 'ratio': frame.ratio, 'width': frame.width, 'height': frame.height };
			}
		});
	};
	add(me['out']);
	add(us['out']);
	if ($('#whiteboard').is(':visible')) {
		var whiteboard = document.getElementById('whiteboard');
		var frame = jpWatchFrame(whiteboard, 'whiteboard', '#ffffff', true);
		if (frame) {
			returner['we'] = { 'image': frame.image, 'ratio': frame.ratio, 'width': frame.width, 'height': frame.height };
		}
	}
	if (typeof advertise_watching !== 'undefined' && advertise_watching == 'on'
		&& typeof music_remote_watch === 'object' && music_remote_watch && music_remote_watch.image) {
		returner['music_remote'] = {
			image: music_remote_watch.image,
			ratio: music_remote_watch.ratio,
			width: music_remote_watch.width,
			height: music_remote_watch.height
		};
	}
	return returner;
}


let localStream;
let pc1;
let pc2;
var jpSmoothInterval;

function jpSmooth(app,sourceStream) {
    pc1 = new RTCPeerConnection(servers); // eslint-disable-line new-cap
    console.log('Created local peer connection object pc1');
    pc1.onicecandidate = e => onIceCandidate(pc1, e);
    pc2 = new RTCPeerConnection(servers); // eslint-disable-line new-cap
    console.log('Created remote peer connection object pc2');
    pc2.onicecandidate = e => onIceCandidate(pc2, e);
    pc2.ontrack = gotRemoteStream;
    sourceStream.getTracks().forEach(track => pc1.addTrack(track, sourceStream));
    pc1.createOffer().then(gotDescription1).catch(error => console.log(`createOffer failed: ${error}`));
}

function jpViewAdjuster(streams) {
	var container = $('#mailbox_video_container');
	var videos = container.find('video');
	$.each(streams, function(i,v) {
		console.log(streams[i]);
		var id = streams[i].id;
		if ($('#' + id).length == 0) {
			container.append('<video class="jpSmoothStream" id="' + id + '" mute autoplay></video>');
			var audioElement = document.getElementById(id);
			audioElement.muted = true;
			them['in'][id] = streams[i];
		  audioElement.srcObject = them['in'][id];
			them['pc'][id] = pc2;
			videos = container.find('video');
			var width = container.width();
			var height = container.height();
			width = numeral(container.width() / videos.length).value();
			$('#' + id ).width(width);
		}
	});
	clearInterval(jpSmoothInterval);
	jpSmoothInterval = setInterval(function() {
		var streams = $('.jpSmoothStream');
		// nothing left to watch - don't leave a timer running forever
		if (streams.length == 0) { clearInterval(jpSmoothInterval); return; }
		streams.each(function(ir,vr) {
			var id = $(vr).attr('id');
			var v = document.getElementById(id);
			if (them['stats'][id] == v.currentTime) {
				$(vr).remove();
				them['pc'][id].close();
			}
			them['stats'][id] = v.currentTime
		});
	},1000);
}

function gotRemoteStream(e) {
	jpViewAdjuster(e.streams);
}

function gotDescription1(desc) {
  console.log(`Offer from pc1\n${desc.sdp}`);

  pc1.setLocalDescription(desc);
  pc2.setRemoteDescription(desc);
  pc2.createAnswer()
      .then(gotDescription2)
      .catch(error => logError(`createAnswer failed: ${error}`));
}

function gotDescription2(desc) {
  console.log(`Answer from pc2\n${desc.sdp}`);
  pc2.setLocalDescription(desc);
  pc1.setRemoteDescription(desc);
}

function getOtherPc(pc) {
  return (pc === pc1) ? pc2 : pc1;
}

function getName(pc) {
  return (pc === pc1) ? 'pc1' : 'pc2';
}

function onIceCandidate(pc, event) {
  getOtherPc(pc)
      .addIceCandidate(event.candidate)
      .then(() => onAddIceCandidateSuccess(pc), err => onAddIceCandidateError(pc, err));
  console.log(`${getName(pc)} ICE candidate:\n${event.candidate ? event.candidate.candidate : '(null)'}`);
}

function onAddIceCandidateSuccess() {
  console.log('AddIceCandidate success.');
}

function onAddIceCandidateError(error) {
  logError(`Failed to add Ice Candidate: ${error.toString()}`);
}
