// The Camera app. In the app it drives window.JawnCamera (the OS camera and its
// video recorder); in the desktop's embedded view - and any browser - it falls
// back to the machine's own webcam through getUserMedia. Either way the capture
// is posted to the ordinary upload route under the 'camera' app.
var jawnCameraApp = { stream: null, rec: null, chunks: [], source: 'auto', devices: [] };

function jawnCameraAppSourceLoad() {
	var saved = '';
	try { saved = localStorage.getItem('jawnos:camera_source') || ''; } catch (e) {}
	if (saved) { jawnCameraApp.source = saved; }
}
function jawnCameraAppSourceSave(value) {
	jawnCameraApp.source = value || 'auto';
	try { localStorage.setItem('jawnos:camera_source', jawnCameraApp.source); } catch (e) {}
	renderCameraSource();
}
// Front/back names are all a browser gives us before permission; the label and
// facingMode are best-effort hints, and every real device is listed by id too.
function cameraSourceLabel(device, i) {
	var label = (device.label || '').replace(/\s+/g, ' ').trim();
	if (!label) { label = 'Camera ' + (i + 1); }
	return label;
}
function renderCameraSource() {
	var row = $('#camera_app .camera_app_source_row');
	if (!row.length) { return; }
	var sel = row.find('.camera_app_source');
	var chosen = jawnCameraApp.source || 'auto';
	var opts = [];
	$.each([['auto', 'camera_auto'], ['front', 'camera_front'], ['back', 'camera_back']], function (i, pair) {
		opts.push($('<option>').val(pair[0]).text(cameraT(pair[1])).prop('outerHTML'));
	});
	$.each(jawnCameraApp.devices, function (i, d) {
		opts.push($('<option>').val(d.deviceId).text(cameraSourceLabel(d, i)).prop('outerHTML'));
	});
	sel.html(opts.join(''));
	sel.val(chosen);
	if ((sel.val() || '') !== chosen) { sel.val('auto'); jawnCameraApp.source = 'auto'; }
}
function jawnCameraAppRefreshSources() {
	if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) { return Promise.resolve(); }
	return navigator.mediaDevices.enumerateDevices().then(function (list) {
		jawnCameraApp.devices = $.grep(list || [], function (d) { return d.kind == 'videoinput'; });
		renderCameraSource();
	});
}
function jawnCameraAppConstraints() {
	var source = jawnCameraApp.source || 'auto';
	if (source == 'front') { return { video: { facingMode: 'user' }, audio: true }; }
	if (source == 'back') { return { video: { facingMode: { ideal: 'environment' } }, audio: true }; }
	if (source && source != 'auto') { return { video: { deviceId: { exact: source } }, audio: true }; }
	return { video: true, audio: true };
}
function jawnCameraAppStreamStop() {
	if (jawnCameraApp.stream) {
		jawnCameraApp.stream.getTracks().forEach(function (t) { try { t.stop(); } catch (e) {} });
		jawnCameraApp.stream = null;
	}
	var v = document.querySelector('#camera_app .camera_app_preview');
	if (v) { try { v.srcObject = null; } catch (e) {} v.style.display = 'none'; }
}

function jawnCameraAppNative() {
	return !!(window.JawnCamera && window.JawnCamera.available && window.JawnCamera.available() === 'yes');
}
function jawnCameraAppWebcam() {
	return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
}
function jawnCameraAppStatus(text) {
	$('#camera_app .camera_app_status').text(text);
}
function cameraT(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

$(document).ready(function () {
	jawnCameraAppSourceLoad();
	// the panel's buttons render for whichever camera this machine has
	if (jawnCameraAppNative()) { document.documentElement.classList.add('camera-native'); }
	else if (jawnCameraAppWebcam()) { document.documentElement.classList.add('camera-webcam'); }
	if (jawnCameraAppWebcam()) {
		jawnCameraAppRefreshSources();
		// a phone only learns its front/back at first permission, so ask once and
		// then fill the picker with the real names
		if (typeof navigator.mediaDevices.addEventListener == 'function') {
			navigator.mediaDevices.addEventListener('devicechange', function () { jawnCameraAppRefreshSources(); });
		}
	}
});

$(document).on('click', '#camera_toggle', function () {
	$.ajax({
		url: '/manager/camera',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) { windowMaker(response); jawnCameraAppPool(); jawnCameraAppRefreshSources(); }
	});
});

function jawnCameraAppStreamStart() {
	if (jawnCameraApp.stream) { return Promise.resolve(jawnCameraApp.stream); }
	return navigator.mediaDevices.getUserMedia(jawnCameraAppConstraints()).then(function (stream) {
		jawnCameraApp.stream = stream;
		var v = document.querySelector('#camera_app .camera_app_preview');
		if (v) { v.srcObject = stream; v.style.display = 'inline-block'; if (v.play) { v.play(); } }
		// permission just revealed the real device names
		jawnCameraAppRefreshSources();
		return stream;
	}).catch(function (err) {
		// a remembered device that is gone must not lock the Camera app out
		if (jawnCameraApp.source && jawnCameraApp.source != 'auto' && jawnCameraApp.source != 'front' && jawnCameraApp.source != 'back') {
			jawnCameraAppSourceSave('auto');
			return navigator.mediaDevices.getUserMedia(jawnCameraAppConstraints()).then(function (stream) {
				jawnCameraApp.stream = stream;
				var v = document.querySelector('#camera_app .camera_app_preview');
				if (v) { v.srcObject = stream; v.style.display = 'inline-block'; if (v.play) { v.play(); } }
				return stream;
			});
		}
		throw err;
	});
}

$(document).on('change', '#camera_app .camera_app_source', function () {
	jawnCameraAppSourceSave($(this).val());
	if (jawnCameraApp.stream) {
		jawnCameraAppStreamStop();
		jawnCameraAppStatus(cameraT('Switching camera...'));
		jawnCameraAppStreamStart().then(function () { jawnCameraAppStatus(''); })
			.catch(function () { jawnCameraAppStatus(cameraT('Could not reach that camera.')); });
	}
});

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
			jawnCameraAppPool();
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
		// open the OS camera in image mode; the user picks front/back in its UI
		window.JawnCamera.photo();
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

// --- Unclaimed media pool -------------------------------------------------
// A capture taken in the Camera app itself, or media an agent generated without
// an appointment, lands here with a week's warranty to be claimed onto an
// appointment. Select items (or select all), then either drop them onto the
// drop zone or type an appointment name and file them.
var jawnCameraUnclaimed = { items: [], selected: {}, target: null };

function jawnCameraAppPool() {
	if (!$('#camera_app .camera_unclaimed').length) { return; }
	$.ajax({
		url: '/manager/unclaimed',
		type: 'GET',
		data: { timestamp: Date.now() },
		success: function (res) {
			jawnCameraUnclaimed.items = (res && res.items) || [];
			jawnCameraUnclaimed.selected = {};
			jawnCameraUnclaimed.target = null;
			jawnCameraUnclaimedRender();
		},
		error: function () { $('#camera_app .camera_unclaimed_status').text('Could not load unclaimed media.'); }
	});
}

function jawnCameraUnclaimedRemaining(ms) {
	var left = Number(ms || 0) - Date.now();
	if (left <= 0) { return 'expired'; }
	var m = Math.floor(left / 60000);
	var h = Math.floor(m / 60);
	var d = Math.floor(h / 24);
	if (d > 0) { return d + 'd ' + (h % 24) + 'h left'; }
	if (h > 0) { return h + 'h ' + (m % 60) + 'm left'; }
	return m + 'm left';
}

function jawnCameraUnclaimedSrc(item, thumb) {
	return '/file_open?appt_uuid=' + encodeURIComponent(item.appt_uuid) +
		'&file_uuid=' + encodeURIComponent(item.file_uuid) +
		'&app=camera&timestamp=' + encodeURIComponent(item.server_time || '') +
		(thumb ? '&thumb=ya' : '');
}

function jawnCameraUnclaimedMedia(item) {
	if (item.type === 'image') {
		return $('<img class="camera_unclaimed_thumb" loading="lazy">').attr('src', jawnCameraUnclaimedSrc(item, true));
	}
	if (item.type === 'video') {
		var img = $('<img class="camera_unclaimed_thumb" loading="lazy">').attr('src', jawnCameraUnclaimedSrc(item, true));
		return $('<div class="camera_unclaimed_media"></div>').append(img).append('<span class="camera_unclaimed_play">▶</span>');
	}
	if (item.type === 'audio') {
		return $('<img class="camera_unclaimed_thumb camera_unclaimed_icon">').attr('src', '/images/make believe/music.png');
	}
	return $('<img class="camera_unclaimed_thumb camera_unclaimed_icon">').attr('src', '/images/decipherable/file.png');
}

function jawnCameraUnclaimedRender() {
	var pool = $('#camera_app .camera_unclaimed_pool').empty();
	var count = $('#camera_app .camera_unclaimed_count');
	var selAll = $('#camera_app .camera_unclaimed_select_all');
	var selWrap = $('#camera_app .camera_unclaimed_select_all_wrap');
	var status = $('#camera_app .camera_unclaimed_status');

	count.text(jawnCameraUnclaimed.items.length ? '(' + jawnCameraUnclaimed.items.length + ')' : '');
	selWrap.toggle(jawnCameraUnclaimed.items.length > 0);
	selAll.prop('checked', false);
	status.text(jawnCameraUnclaimed.items.length ? '' : 'Nothing is waiting here yet.');

	if (!jawnCameraUnclaimed.items.length) {
		$('#camera_app .camera_unclaimed_claim').hide();
		return;
	}

	$.each(jawnCameraUnclaimed.items, function (i, item) {
		var card = $('<div class="camera_unclaimed_item"></div>')
			.attr('file_uuid', item.file_uuid)
			.attr('title', item.name || item.type);
		var check = $('<input type="checkbox" class="camera_unclaimed_check">').attr('file_uuid', item.file_uuid);
		var media = jawnCameraUnclaimedMedia(item).on('mousedown', function (e) { e.stopPropagation(); });
		var meta = $('<div class="camera_unclaimed_meta">' +
			'<span class="camera_unclaimed_type">' + (item.type || 'file') + '</span>' +
			'<span class="camera_unclaimed_time">' + jawnCameraUnclaimedRemaining(item.warranty) + '</span>' +
			'</div>');
		card.append(check).append(media).append(meta);
		card.on('click', function () { check.prop('checked', !check.prop('checked')).trigger('change'); });
		check.on('change', function () {
			var on = check.prop('checked');
			if (on) { jawnCameraUnclaimed.selected[item.file_uuid] = 1; }
			else { delete jawnCameraUnclaimed.selected[item.file_uuid]; }
			card.toggleClass('selected', on);
			jawnCameraUnclaimedClaimState();
		});
		pool.append(card);
	});
	jawnCameraUnclaimedClaimState();
	jawnCameraUnclaimedArmDrag();
}

function jawnCameraUnclaimedSelectedIds() {
	return $.map(jawnCameraUnclaimed.selected, function (v, k) { return k; });
}

function jawnCameraUnclaimedClaimState() {
	var ids = jawnCameraUnclaimedSelectedIds();
	var claim = $('#camera_app .camera_unclaimed_claim');
	var fileBtn = $('#camera_app .camera_unclaimed_file');
	var notice = $('#camera_app .camera_unclaimed_target');
	claim.toggle(ids.length > 0);
	if (jawnCameraUnclaimed.target) {
		notice.text(jawnCameraUnclaimedSummary() + ' to ' + jawnCameraUnclaimed.target.name);
	} else {
		notice.text('');
	}
	fileBtn.toggle(!!jawnCameraUnclaimed.target && ids.length > 0);
	jawnCameraUnclaimedDropState();
}

function jawnCameraUnclaimedSummary() {
	var counts = { image: 0, video: 0, audio: 0, other: 0 };
	$.each(jawnCameraUnclaimed.items, function (i, item) {
		if (jawnCameraUnclaimed.selected[item.file_uuid]) {
			if (item.type === 'image') { counts.image++; }
			else if (item.type === 'video') { counts.video++; }
			else if (item.type === 'audio') { counts.audio++; }
			else { counts.other++; }
		}
	});
	var parts = [];
	if (counts.image) { parts.push(counts.image + (counts.image === 1 ? ' image' : ' images')); }
	if (counts.video) { parts.push(counts.video + (counts.video === 1 ? ' video' : ' videos')); }
	if (counts.audio) { parts.push(counts.audio + ' audio'); }
	if (counts.other) { parts.push(counts.other + (counts.other === 1 ? ' file' : ' files')); }
	return parts.join(' and ') || 'media';
}

function jawnCameraUnclaimedDropState() {
	var drop = $('#camera_app .camera_unclaimed_drop');
	drop.toggle(!!jawnCameraUnclaimed.target);
	if (jawnCameraUnclaimed.target) {
		$('#camera_app .camera_unclaimed_drop_name').text(jawnCameraUnclaimed.target.name);
	}
}

function jawnCameraUnclaimedSearch() {
	var input = $('#camera_app .camera_unclaimed_search');
	var results = $('#camera_app .camera_unclaimed_results');
	var q = $.trim(input.val());
	if (!q) { results.empty().hide(); return; }
	$.ajax({
		url: '/manager/unclaimed/appointments',
		type: 'GET',
		data: { search: q, timestamp: Date.now() },
		success: function (res) {
			var list = (res && res.appointments) || [];
			results.empty();
			if (!list.length) {
				results.append($('<div class="camera_unclaimed_result" style="opacity:.6;">No appointments match.</div>'));
			} else {
				$.each(list, function (i, a) {
					var row = $('<div class="camera_unclaimed_result"></div>')
						.attr('app', a.app).attr('uuid', a.uuid || '').text(a.name);
					row.on('click', function () {
						jawnCameraUnclaimed.target = { app: a.app, uuid: a.uuid || '', name: a.name };
						results.hide();
						input.val(a.name);
						jawnCameraUnclaimedClaimState();
					});
					results.append(row);
				});
			}
			results.show();
		}
	});
}

function jawnCameraUnclaimedFile() {
	var ids = jawnCameraUnclaimedSelectedIds();
	var target = jawnCameraUnclaimed.target;
	if (!ids.length || !target) { return; }
	var status = $('#camera_app .camera_unclaimed_status');
	status.text('Filing…');
	$.ajax({
		url: '/manager/unclaimed/claim',
		type: 'POST',
		data: { app: target.app, uuid: target.uuid || '', file_uuids: ids.join(','), timestamp: Date.now() },
		success: function (res) {
			if (res && res.ok) {
				status.text('Filed ' + res.claimed + ' item(s) into ' + target.name + '.');
				jawnCameraAppPool();
			} else {
				status.text((res && res.error) || 'Could not file those items.');
			}
		},
		error: function () { status.text('Could not file those items.'); }
	});
}

function jawnCameraUnclaimedArmDrag() {
	if (typeof windowPhoneChecker === 'function' && windowPhoneChecker() === true) { return; }
	$('#camera_app .camera_unclaimed_item').each(function () {
		var card = $(this);
		if (card.hasClass('ui-draggable')) { return; }
		card.draggable({
			appendTo: 'body',
			helper: 'clone',
			revert: 'invalid',
			zIndex: 999999,
			cursorAt: { top: 20, left: 20 },
			cancel: 'input,textarea,button,select,option,video,audio'
		});
	});
	$('#camera_app .camera_unclaimed_drop').each(function () {
		var drop = $(this);
		if (drop.hasClass('ui-droppable')) { return; }
		drop.droppable({
			hoverClass: 'camera_unclaimed_drop_hover',
			drop: function (e, ui) {
				var id = ui.draggable.attr('file_uuid');
				if (id && jawnCameraUnclaimed.target && !jawnCameraUnclaimed.selected[id]) {
					jawnCameraUnclaimed.selected[id] = 1;
				}
				jawnCameraUnclaimedFile();
			}
		});
	});
}

$(document).ready(function () {
	if ($('#camera_app .camera_unclaimed').length) { jawnCameraAppPool(); }
});
$(document).on('input', '#camera_app .camera_unclaimed_search', function () {
	clearTimeout(jawnCameraUnclaimed._t);
	jawnCameraUnclaimed._t = setTimeout(jawnCameraUnclaimedSearch, 180);
});
$(document).on('click', '#camera_app .camera_unclaimed_file', jawnCameraUnclaimedFile);
$(document).on('change', '#camera_app .camera_unclaimed_select_all', function () {
	var on = $(this).prop('checked');
	$('#camera_app .camera_unclaimed_item').each(function () {
		var c = $(this).find('.camera_unclaimed_check');
		if (c.prop('checked') !== on) { c.prop('checked', on).trigger('change'); }
	});
});
