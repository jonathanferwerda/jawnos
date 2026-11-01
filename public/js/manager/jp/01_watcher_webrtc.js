function jpWatcher() {
	var returner = {};

	$.each(me['out'], function(i,v) {

		var id = $(v).attr('id');
		var video = document.getElementById(id);
		if ($(video).is('video')) {
			var canvas = document.createElement('canvas');
			var ratio = video.videoWidth / video.videoHeight;
			canvas.width = 640 || 0;
			canvas.height = ratio * canvas.width || 0;
			canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);

			var image = canvas.toDataURL('image/png');
			returner[i] = { 'image': image, 'ratio': ratio, 'width': canvas.width, 'height': canvas.height };
		}
	});
	$.each(us['out'], function(i,v) {
		var id = $(v).attr('id');
		var video = document.getElementById(id);
		if ($(video).is('video')) {
			var canvas = document.createElement('canvas');

			var ratio = video.videoWidth / video.videoHeight;
			canvas.width = 640 || 0;
			canvas.height = ratio * canvas.width || 0;
			canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);

			var image = canvas.toDataURL('image/png');
			returner[i] = { 'image': image, 'ratio': ratio, 'width': canvas.width, 'height': canvas.height };
		}
	});
	if ($('#whiteboard').is(':visible')) {
		var canvas = document.getElementById('whiteboard');
		var vcanvas = document.createElement('canvas');
		var ratio = canvas.width / canvas.height;
		vcanvas.width = 640 || 0;
		vcanvas.height = ratio * vcanvas.width;
		vcanvas.getContext('2d').drawImage(canvas, 0, 0, vcanvas.width, vcanvas.height);
		var image = vcanvas.toDataURL('image/png');
		returner['we'] = { 'image': image, 'ratio': ratio, 'width': canvas.width, 'height': canvas.height };
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