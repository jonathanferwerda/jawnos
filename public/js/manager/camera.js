// The Camera app: a start-menu icon (and a taskbar pin) whose panel drives the
// app's own camera (window.JawnCamera). The file comes back through
// manager.js's window.__jawnCameraResult, which posts it to the upload route
// under the 'camera' app.
$(document).on('click', '#camera_toggle', function () {
	$.ajax({
		url: '/manager/camera',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) { windowMaker(response); }
	});
});

$(document).on('click', '.camera_app_photo, .camera_app_video', function () {
	var available = window.JawnCamera && window.JawnCamera.available && window.JawnCamera.available() === 'yes';
	if (!available) {
		$('#camera_app .camera_app_status').text('The camera is only in the app.');
		return;
	}
	var b = $(this);
	$('#camera_app .camera_app_status').text('Opening the camera...');
	// manager.js reads this when the capture comes back
	window.__jawnCameraPending = { app: 'camera', status: '#camera_app .camera_app_status' };
	if (b.hasClass('camera_app_video')) { window.JawnCamera.video(); }
	else { window.JawnCamera.photo(b.attr('capture') || '0'); }
});
