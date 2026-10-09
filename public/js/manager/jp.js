
$.each(['me','us','we','them'],function(i,v) {
	window[v] = {
		'aud': {},
		'in': {},
		'rec': {},
		'src': {},
		'analyzer': {},
		'osc': {},
		'buffer': {},
		'data': {},
		'ctx': {},
		'mix': {},
		'pc': {},
		'out': {},
		'timestamp': {},
		'id': {},
		'type': {},
		'uuid': {},
		'app': {}
	};
});


async function jpCanvas(app) {
	var whiteboard = document.getElementById('whiteboard');
	var apper = $('.wind')[$('.wind').length - 1];
	app = ($(apper).attr('app') || $('#search').val());
	var wb = $(whiteboard);
	if (wb.attr('status') == 'recording') {
		wb.attr('status', 'stopped');
		jpStop(app,'marker');
	}
	else {
		wb.attr('status', 'recording');
		var timestamp = Date.now();
		var marker = markerInfoGrabber();
		var formData = new FormData();
		var type = 'video';
		formData.delete('timestamp');
		formData.append('timestamp', timestamp);

		formData.delete('app');
		formData.append('app', app);
		we['in'][app] = whiteboard.captureStream(marker['flipbook_interval']);
		const options = {
			mimeType: 'video/webm;codecs=opus', // Standard high-quality web codec
			audioBitsPerSecond: 256000          // Force 128 kbps (or use 256000 for 256 kbps)
		};
		we['rec'][app] = new MediaRecorder(we['in'][app],options);
		we['timestamp'][app] = Date.now();
		we['rec'][app].start();
		$('#marker_record').attr('src', '/images/make believe/stop.png');
		$('#marker_pause').attr('app', app);
		$('#marker_pause').show();
		we['rec'][app].ondataavailable = (event) => { 
			var data = event.data;
			data.type = 'track';
			var ext = 'webm';
			if (type == 'audio') {
				ext = 'weba';
			}
			var formData = new FormData();
			var duration = (Date.now() - we['timestamp'][app]) * -1;
			formData.append('app', app);
			formData.append('duration', duration);
			formData.append('timestamp', timestamp);
			formData.append('type', type);
			formData.append('blob', data, app + '.' + ext);

			$('#marker_record').attr('src', '/images/make believe/record.png');
			$('#marker_pause').hide();
			$('#marker_pause').removeAttr('app');
			$.ajax({
				url: '/manager/upload_file',
				type: 'POST',
				data: formData,
				success: function (response) {
					continent_record({'uuid':response['uuid'], 'app':response['app'],'timestamp':response['timestamp']});
				},
				cache: false,
				contentType: false,
				processData: false
			});
		};
	}
};

async function jpStart(app,pref,uuid) {
	var timestamp = Date.now();
	// an audio take keeps an audio name through the whole journey - the
	// recorder, the file and the appointment entry - so the server files it
	// as a sound and not as a silent little video
	var type = pref == 'audio' ? 'audio' : 'video';
	var id = app + (pref == 'audio' ? '_snd' : '_cam');
	me['id'][app] = id;
	me['type'][app] = type;
	me['uuid'][app] = uuid;
	me['app'][app] = app;
	if (!me[app]) {
		var constraints = await constraintMaker(pref);
		if (pref == 'audio') {
			constraints['video'] = false;
		}
		if (app) {
			try {
				me['id'][app] = id;
				me['type'][app] = type;
				me['uuid'][app] = uuid;
				if (!me['in'][app]) {
					me['in'][app] = await navigator.mediaDevices.getUserMedia(constraints);

				}
				if (!me['rec'][app] || me['rec'][app].state == "inactive" ) {
					const options = {
						mimeType: type == 'audio' ? 'audio/webm;codecs=opus' : 'video/webm;codecs=opus',
						audioBitsPerSecond: 256000          // Force 128 kbps (or use 256000 for 256 kbps)
					};
					me['rec'][app] = new MediaRecorder(me['in'][app],options);
					me['timestamp'][app] = Date.now();
					me['rec'][app].start();
				}
				me['rec'][app].ondataavailable = (event) => { 
					
					var data = event.data;
					data.type = 'track';
					var json = JSON.stringify(data);
					var formData = new FormData();
					var duration = (Date.now() - me['timestamp'][app]) * -1;
					formData.append('app', app);
					formData.append('duration', duration);
					formData.append('timestamp', me['timestamp'][app]);
					formData.append('type', type);
					formData.append('blob', data, app + (type == 'audio' ? '.weba' : '.webm'));
					formData.append('uuid', uuid);
					$.ajax({
							url: '/manager/upload_file',
							type: 'POST',
							data: formData,
							success: function (response) {
								continent_record({'uuid':response['uuid'], 'app':response['app'],'timestamp':response['timestamp']});
							},
							cache: false,
							contentType: false,
							processData: false
					});

				};

				me['rec'][app].onstop = function(event) {
					if (pref == 'video') {
						$('#' + id).remove();
						$('.appointment[app="' + app + '"]').find('.media_out.vid').html('');
					}
					else {
						$('#' + id).hide();
					}
				};
				var app_vid_html = $('#' + app + '_cam').parent().html();
				if (pref == 'audio') {
					$('#' + id).show();
					me['out'][app] = document.getElementById(id);
					me['out'][app].srcObject = me['rec'][app].stream;
					me['out'][app].muted = true;
				} else {
					var jmiss = JSON.stringify(misses);
					$.ajax({
						url: '/manager/media_window',
						type: 'GET',
						data: { id: id, contents: app_vid_html, timestamp: timestamp, app: app + '_cam', app_name: app, misses: jmiss },
						success: function(response) {

							var vid = $('.appointment[app="' + app + '"]').find('.media_out.vid');
							vid.html(response.html);
							me['out'][app] = document.getElementById(id);
							me['out'][app].srcObject = me['rec'][app].stream;
							me['out'][app].muted = true;

						}
					});
				}

				me['rec'][app].onstart = function(event) {
					me['aud'][app] = new Audio;
					me['aud'][app].srcObject = me['in'][app];
					$('#' + id).show();
					jpScope(app);

				};
			}
			catch(error) { console.log('error',error); }
		}
		else {
			if (!me['in'][app]) {
				me['in'][app] = await navigator.mediaDevices.getUserMedia(constraints);
			}
			jpSmooth('', me['in'][app]);
		}

	}
	else {

	}
}

async function constraintMaker(pref) {

	var constraints = { 'audio': false, 'video': false };
	var isVideo = false;
	var isInitialized = false;
	var hasAudio = false;
	var hasVideo = false;
	var av = await navigator.mediaDevices.enumerateDevices();
	var all = [];
	$.each(av, function(i,v) {
		all.push(v);
		var mic = jawnosDevicePickGet('audioinput', v.deviceId);
		var cam = jawnosDevicePickGet('videoinput', v.deviceId);
		var spkr = jawnosDevicePickGet('audiooutput', v.deviceId);
		if (v.kind == 'audioinput') {

			hasAudio = true;
			if (mic == 'on' && v.deviceId) {
				isInitialized = true;
				constraints['audio'] = { deviceId: { exact: v.deviceId } };
			}
		}
		else if (v.kind == 'videoinput') {
			hasVideo = true;
			if (cam == 'on' && v.deviceId) {

				isInitialized = true;
				constraints['video'] = { 
					deviceId: { 
						exact: v.deviceId 
					},
					width: { ideal: 1280, max:4000 },
					height: { ideal: 720, max:3000 }
				};
				isVideo = true;
			}
		}
	});


	if (isVideo == false || pref == 'audio') {
		constraints['video'] = false;

	//	say_it('ok no vid');
	}
	if (isInitialized == false) {
	//	say_it('ok no init');
		constraints = { 'video': false, 'audio': true };
		if (hasVideo == true || pref != 'audio') {
			constraints['video'] = true;
		}
		var test = await navigator.mediaDevices.getUserMedia(constraints);
		test.onstart = function(event) {
			test.stop();
		};
	}
	// say_it('the end');
	constraints['all'] = all;
	return constraints;
}

function jpScope(app) {
	var x = 0;
	var canvas = document.getElementById('visualizer_' + app);
	// the visualizer is a decoration, and nothing feeds it an analyzer yet -
	// when there is no canvas or no analyzer to read, there is nothing to draw
	if (!canvas || !me['analyzer'][app] || !me['data'][app]) { return; }
	var ctx = canvas.getContext("2d");

	var sliceWidth = canvas.width / me['buffer'][app];

  ctx.clearRect(0, 0, canvas.width, canvas.height);

  me['analyzer'][app].getByteFrequencyData(me['data'][app]);

	for (var i = 0; i < me['buffer'][app]; i++) {
		var v = me['data'][app][i] / 128.0;
		var y = v * (canvas.height / 2);

		if (i === 0) {
			ctx.moveTo(x, y);
		} else {
			ctx.lineTo(x, y);
		}
		x += sliceWidth;
	}
	ctx.stroke();
  //requestAnimationFrame(jpScope(app));

}

async function jpScreen(app,uuid) {
	var id = app + '_scr';
	var timestamp = Date.now();
	var type = 'screen';
	me['id'][app] = id;
	me['type'][app] = type;
	me['uuid'][app] = uuid;
	me['app'][app] = app;
	try {
		if (app) {

			if (!us['in'][app]) {
				var options = { 'surfaceSwitching': 'include', 'audio': true, 'video': { 'displaySurface': 'monitor' }};
				us['in'][app] = await navigator.mediaDevices.getDisplayMedia(options);
			}
			if (!us['rec'][app] || us['rec'][app].state =="inactive" ) {
				us['rec'][app] = new MediaRecorder(us['in'][app]);
				us['timestamp'][app] = Date.now();
				us['rec'][app].start();
				$('#' + id).show();

			}

			us['rec'][app].ondataavailable = (event) => { 
				event.data.app = app;
				
				var data = event.data;
				data.type = 'screen';

				var json = JSON.stringify(data);

				var formData = new FormData();
				var duration = data.size;
				var duration = (Date.now() - us['timestamp'][app]) * -1;
				formData.append('app', app);
				formData.append('duration', duration);
				formData.append('timestamp', us['timestamp'][app]);
				formData.append('type', 'screen');
				formData.append('blob', data, app + '.webm');
				formData.append('duration', duration);
				formData.append('uuid', uuid);
				$.ajax({
						url: '/manager/upload_file',
						type: 'POST',
						data: formData,
						success: function (response) {
							continent_record({'uuid':response['uuid'], 'app':response['app'],'timestamp':response['timestamp']});
						},
						cache: false,
						contentType: false,
						processData: false
				});
				us['mix'][app] = data;
			};
			us['rec'][app].onstart = function(event) {

			};
			us['rec'][app].onstop = function(event) {
				$('#' + id).remove();
				$('.appointment[app="' + app + '"]').find('.media_out.scr').html('');
			};
			var app_vid_html = $('#' + app + '_scr').parent().html();
			var jmiss = JSON.stringify(misses);
			$.ajax({
				url: '/manager/media_window',
				type: 'GET',
				data: { id:id, contents: app_vid_html, timestamp: timestamp, app: app + '_scr', app_name: app, misses: jmiss },
				success: function(response) {
					if ($('#club_scr').length > 0) {
						us['out'][app] = document.getElementById(id);
						us['out'][app].srcObject = us['rec'][app].stream;

						$('#' + id).css({'width': '100%' });
					}
					else {
						var vid = $('.appointment[app="' + app + '"]').find('.media_out.scr');
						vid.html(response.html);
						us['out'][app] = document.getElementById(id);
						us['out'][app].srcObject = us['rec'][app].stream;
					}

					us['out'][app].muted = true;
				

				}
			});
		}
		else {
			if (!us['in'][app]) {
				var options = { 'surfaceSwitching': 'include', 'audio': true, 'video': { 'displaySurface': 'monitor' }};
				us['in'][app] = await navigator.mediaDevices.getDisplayMedia(options);
			}
			jpSmooth('', us['in'][app]);
		}
	}
	catch (error) { 

	}
}

function jpReport(app) {

	var apps = [];
	var appts = { me: [], us: [], them: [], we: [] };
	$.each(appts, function(s,d) {
		$.each(window[s], function(i,v) {
			var seen = [];
			$.each(v, function(ir,vr) {
				if (app == ir) {
					seen = $.grep(apps, function(irs,vrs) {
						return irs['app'] == ir;
					});
				}
				if (seen == 0) {
					appts[app] = [];
					appts[app].push(s);
					apps.push({ app: window[s]['app'][app], in: window[s]['in'][app], perspective: s, type: window[s]['type'][app], id: window[s]['id'][app], uuid: window[s]['uuid'][app] });
				}
			});
		});
	});
	

	return apps;
}

function jpRestore(app,jpR) {
	var apps = [];
	var appts = { me: [], us: [], them: [], we: [] };
	$.each(jpR, function(s,d) {

		if (d['app'] == app && d['in']) {
			if (d['app'] == app) {
				jpStart(d['app'],d['type'], d['uuid']);
			}
			else if ( s == 'us' ) {
				jpScreen(d['app'],d['uuid']);
			}
		}
	});
}



function jpStop(app,imperative,uuid) {


	if ((imperative == 'video' || imperative == 'audio') || imperative == undefined) {
		try {
			me['in'][app].getTracks().forEach(function(track) {
				track.stop();
			});
			me['in'][app] = undefined;
			me['rec'][app].stop();
	//		me['rec'][app] = undefined;
			me['out'][app] = undefined;
		}
		catch  {
			$.each(me['in'],function(i,v) {
				try {
					me['rec'][i].getTracks().forEach(function(track) {
						track.stop();
					});
				}
				catch {
					me['in'][app] = undefined;
					me['rec'][app] = undefined;
					me['out'][app] = undefined;
				}
			});

		}
	}
	if (imperative == 'screen' || imperative == undefined) {
		try {
			us['in'][app].getTracks().forEach(function(track) {
				track.stop();
			});
			us['in'][app] = undefined;
			us['rec'][app].stop();
			us['rec'][app] = undefined;
			us['out'][app] = undefined;
		}
		catch  {
			$.each(us['in'],function(i,v) {
				try {
					us['rec'][i].getTracks().forEach(function(track) {
						track.stop();
					});
				}
				catch {
					us['in'][app] = undefined;
					us['rec'][app] = undefined;
					us['out'][app] = undefined;
				}
			});

		}
	}
	if (imperative == 'marker' || imperative == undefined) {
		try {
			we['in'][app].getTracks().forEach(function(track) {
				track.stop();
			});
			we['in'][app] = undefined;
			we['rec'][app].stop();
			we['rec'][app] = undefined;
			we['out'][app] = undefined;
		}
		catch  {
			$.each(we['in'],function(i,v) {
				try {
					we['rec'][i].getTracks().forEach(function(track) {
						track.stop();
					});
				}
				catch {
					we['in'][app] = undefined;
					we['rec'][app] = undefined;
					we['out'][app] = undefined;
				}
			});

		}
	}
}

function inputClose(app) {
	var timestamp = Date.now();
	me['in'][app] = null;
	me['out'][app] = null;

}

function jpAppointmentWriter() {

};

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