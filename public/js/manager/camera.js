// The Camera app. In the app it drives window.JawnCamera (the OS camera and its
// video recorder); in the desktop's embedded view - and any browser - it falls
// back to the machine's own webcam through getUserMedia. Either way the capture
// is posted to the ordinary upload route under the 'camera' app.
var jawnCameraApp = { stream: null, rec: null, chunks: [] };

function jawnCameraAppNative() {
	return !!(window.JawnCamera && window.JawnCamera.available && window.JawnCamera.available() === 'yes');
}
function jawnCameraAppWebcam() {
	return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
}
function jawnCameraAppStatus(text) {
	$('#camera_app .camera_app_status').text(text);
}

$(document).ready(function () {
	// the panel's buttons render for whichever camera this machine has
	if (jawnCameraAppNative()) { document.documentElement.classList.add('camera-native'); }
	else if (jawnCameraAppWebcam()) { document.documentElement.classList.add('camera-webcam'); }
});

$(document).on('click', '#camera_toggle', function () {
	$.ajax({
		url: '/manager/camera',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) { windowMaker(response); }
	});
});

function jawnCameraAppStreamStart() {
	if (jawnCameraApp.stream) { return Promise.resolve(jawnCameraApp.stream); }
	return navigator.mediaDevices.getUserMedia({ video: true, audio: true }).then(function (stream) {
		jawnCameraApp.stream = stream;
		var v = document.querySelector('#camera_app .camera_app_preview');
		if (v) { v.srcObject = stream; v.style.display = 'inline-block'; if (v.play) { v.play(); } }
		return stream;
	});
}

function jawnCameraAppUpload(blob, name, kind) {
	var formData = new FormData();
	formData.append('app', 'camera');
	formData.append('timestamp', Date.now());
	formData.append('type', kind);
	formData.append('blob', blob, name);
	$.ajax({
		url: '/manager/upload_file',
		type: 'POST',
		data: formData,
		success: function (response) {
			jawnCameraAppStatus('Saved.');
			continent_record({ uuid: response.uuid, app: response.app, timestamp: response.timestamp });
		},
		error: function () { jawnCameraAppStatus('Upload failed.'); },
		cache: false,
		contentType: false,
		processData: false
	});
}

// Take a photo: the OS camera in the app, a webcam frame on the desktop.
$(document).on('click', '.camera_app_photo', function () {
	if (jawnCameraAppNative()) {
		window.__jawnCameraPending = { app: 'camera', status: '#camera_app .camera_app_status' };
		window.JawnCamera.photo($(this).attr('capture') || '0');
		return;
	}
	if (!jawnCameraAppWebcam()) { jawnCameraAppStatus('No camera here.'); return; }
	jawnCameraAppStatus('Starting the webcam...');
	jawnCameraAppStreamStart().then(function () {
		var v = document.querySelector('#camera_app .camera_app_preview');
		var canvas = document.createElement('canvas');
		canvas.width = v.videoWidth || 1280;
		canvas.height = v.videoHeight || 720;
		canvas.getContext('2d').drawImage(v, 0, 0, canvas.width, canvas.height);
		canvas.toBlob(function (blob) {
			jawnCameraAppStatus('Saving...');
			jawnCameraAppUpload(blob, 'camera_' + Date.now() + '.jpg', 'image');
		}, 'image/jpeg', 0.92);
	}).catch(function () { jawnCameraAppStatus('Could not reach the webcam.'); });
});

// Record a video: the OS recorder in the app, MediaRecorder on the desktop.
$(document).on('click', '.camera_app_video', function () {
	if (jawnCameraAppNative()) {
		window.__jawnCameraPending = { app: 'camera', status: '#camera_app .camera_app_status' };
		window.JawnCamera.video();
		return;
	}
	if (!jawnCameraAppWebcam()) { jawnCameraAppStatus('No camera here.'); return; }
	if (jawnCameraApp.rec && jawnCameraApp.rec.state === 'recording') {
		jawnCameraApp.rec.stop();
		jawnCameraAppStatus('Saving the video...');
		return;
	}
	jawnCameraAppStreamStart().then(function (stream) {
		jawnCameraApp.chunks = [];
		var mime = (window.MediaRecorder && MediaRecorder.isTypeSupported('video/webm;codecs=vp9,opus'))
			? 'video/webm;codecs=vp9,opus' : 'video/webm';
		try { jawnCameraApp.rec = new MediaRecorder(stream, { mimeType: mime }); }
		catch (e) { jawnCameraAppStatus('Recording is not available here.'); return; }
		jawnCameraApp.rec.ondataavailable = function (e) { if (e.data && e.data.size) { jawnCameraApp.chunks.push(e.data); } };
		jawnCameraApp.rec.onstop = function () {
			var blob = new Blob(jawnCameraApp.chunks, { type: 'video/webm' });
			jawnCameraAppUpload(blob, 'camera_' + Date.now() + '.webm', 'video');
		};
		jawnCameraApp.rec.start();
		jawnCameraAppStatus('Recording... tap Record a video again to stop.');
	}).catch(function () { jawnCameraAppStatus('Could not reach the webcam.'); });
});
