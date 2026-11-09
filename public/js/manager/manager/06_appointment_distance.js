$(document).on('click', '.main_image_selector', function() {
	var file = $(this).attr('file');
	var app = $(this).attr('app');
	var selected = $(this).attr('main_image');
	var mis = $('.main_image_selector');
	mis.attr('main_image', 'no');
	mis.css({'border-color': 'black','border-width':'3px'});

	if (selected == 'yes') {
		settingDeleter({ 'app': app, 'setting': 'main_image' });
	}
	else {
		settingSetter({ 'app': app, 'setting': 'main_image', 'value': file });
		$(this).css({'border-color':'orange','border-width':'6px'});
		$(this).attr('main_image', 'yes');
	}
});

var cb_check = 0;
$(document).on('click', '.configuration', function() {
	configureToggle()
});

$(document).on('click','.purchase', function() {
	var iq = $(this).closest('.appointment').find('.purchase_details');
	if (iq.is(':hidden')) { 
		iq.show(); 
		timestampDater();
    iq.find('.date').val(moment(Date.now()).format('M/D/YYYY'));
	}
	else { iq.hide(); }
});
$(document).on('click','.inventory', function() {
	var iq = $(this).closest('.appointment').find('.inventory_details');
	var app = $(this).closest('.appointment').attr('app');
	if (iq.is(':hidden')) {
		appActExclusive(app, 'inventory');
		iq.show();
		inventoryDetails(app);
	}
	else {
		iq.hide();
	}
	appActSync(app);
});


var backy_color = 0;
$(document).on('keyup', '.timed_input', function(e) {
	if (e.keyCode == 13) {
		// a chosen search result owns this Enter; typing again clears the choice
		if ($(this).is('#search') && typeof jawnosSearchTakeEnter == 'function' && jawnosSearchTakeEnter()) { return; }
		var url;
		var i = $(this);

		var id = i.attr('id');
		var messaging = i.attr('messaging');
		var value = i.val();
		var timestamp = Date.now();
		var time_machine = localStorage.getItem('time_machine');
		var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
		var project = localStorage.getItem('project');
		var data;
		var type = 'POST';
		var timeout = 3000;

		if (i.hasClass('add_something') || i.hasClass('.time_machine')) {
			clearTimeout(searchTimeout);
			setTimeout(function() {
				$('#search_results').html('').hide();
			},700);
			i.addClass('active');
			url = '/manager/reset';
			var entry = 'add';
			// This caller reads the redrawn window out of the reply (`response.cv`),
			// so it asks for the synchronous centre-view render. The start/stop press
			// does not, and takes the instant header reply instead.
			data = { app: value, timeshift: timeshift, timestamp: timestamp, type: entry, movement: 'expense', time_machine: time_machine, project: project, cv: 'yes' };
			timeout = 1000;
		}
		else if (i.hasClass('name_change')) {
			url = '/manager/configure';
			var setting = i.attr('setting');
			var app = i.attr('app');
			var name = i.val();
			data = { app: app, timestamp: timestamp, type: setting, setting: setting, value: value };
		}
		else if (i.hasClass('appointment_search')) {
			url = '/manager/appointment_details',
			type = 'GET';
			data = { app: value, timeshift: timeshift, timestamp: timestamp, type: "search", time_machine: time_machine,  scope: scope };	
		}
		if (url) {
			$.ajax({
				url: url,
				type: type,
				data: data,
				success: function(response) {
					if (response && response.conflict) {
						// the new name is a name the house already knows: the panel
						// picks which value keeps the name, setting by setting
						nameConflictPanel(response);
						return;
					}
					if (i.hasClass('add_something') || url == '/manager/configure') {
						$('#start_menu').hide();
						i.removeClass('active');
						centreViewWriter(response.cv);
				//		configureDisplay();
						appointment_chron();
					//	$('#search').val('');
						if ($('.now').attr('presence') != 'not' && response['added'] == 'yes') {
								continent_record({'uuid':response['uuid'],'purpose': 'app','app':response['app'],'timestamp':response['timestamp']});
							}
					}
					i.css({ "background-color": "yellow" });
					clearTimeout(backy_color);
					backy_color = setTimeout(function() {
						i.css({ "background-color": "" });
					},950);
				}
			});
		}
	}
});

// ---- appointment distance: the fixes list or a Travel basemap ----
// The Dist section is one panel. Its picker swaps the list of fixes for a canvas
// map drawn by jawnosMap, and offers only the basemaps the house can actually
// draw: the free services, or a keyed one whose key is already saved in Travel.
function appointmentDistKeys(panel) {
	var keys = {};
	panel.find('.appointment_map_key').each(function() {
		var provider = $(this).attr('provider');
		var value = $(this).val();
		if (provider && value) { keys[provider] = value; }
	});
	return keys;
}

function appointmentDistFill(detail) {
	var panel = $(detail).find('.appointment_distance_panel');
	if (!panel.length || !window.jawnosMap) { return; }
	var sel = panel.find('.appointment_dist_view');
	if (!sel.length || sel.attr('filled') == 'yes') { return; }
	sel.attr('filled', 'yes');
	var keys = appointmentDistKeys(panel);
	var providers = window.jawnosMap.providers || {};
	var group = $('<optgroup></optgroup>').attr('label', jawnosT('Map'));
	var added = 0;
	for (var key in providers) {
		var p = providers[key] || {};
		var kind = p.group || 'url';
		if (kind === 'free' || (kind === 'key' && keys[key])) {
			$('<option></option>').attr('value', key).text(jawnosT(p.name || key)).appendTo(group);
			added++;
		}
	}
	if (added) { sel.append(group); }
}

function appointmentDistShow(panel) {
	if (!panel || !panel.length) { return; }
	var kind = panel.find('.appointment_dist_view').val() || 'fixes';
	panel.find('.appointment_distance_fixes').toggle(kind === 'fixes');
	panel.find('.appointment_distance_map').toggle(kind !== 'fixes');
	if (kind !== 'fixes') { appointmentDistMap(panel, kind); }
}

function appointmentDistMap(panel, provider) {
	var canvas = panel.find('.appointment_dist_canvas')[0];
	if (!canvas || !window.jawnosMap) { return; }
	var data = {};
	try { data = JSON.parse(panel.find('.appointment_distance_data').text() || '{}') || {}; }
	catch (e) { data = {}; }
	var engine = panel.data('appointmentDistMap');
	if (!engine || engine.canvas !== canvas) {
		engine = window.jawnosMap.create(canvas.id, {
			z: 15,
			width: function() { return $(canvas).parent().width() || 480; },
			height: function() { return $(canvas).parent().height() || 320; }
		});
		panel.data('appointmentDistMap', engine);
	}
	engine.setProvider(provider, '', appointmentDistKeys(panel));
	var points = [];
	var fixes = data.points || [];
	var home = data.home || {};
	var carrier = (data.carrier && data.carrier.signatorial) || '';
	var fixPoints = [];
	fixes.forEach(function(p) {
		if (!p || !p.latitude || !p.longitude) { return; }
		fixPoints.push({ lat: +p.latitude, lon: +p.longitude, t: +p.timestamp || 0, dev: p.signatorial || '', colour: '#a0503f' });
	});
	// two devices can file fixes under one appointment (one at home, one driving).
	// The house names the device that was with the person; only its fixes make the
	// line, because the other one just sits there and jitters.
	var linePoints = carrier ? fixPoints.filter(function(p) { return p.dev === carrier; }) : fixPoints;
	var byDev = {};
	linePoints.forEach(function(p) { (byDev[p.dev] = byDev[p.dev] || []).push(p); });
	var lines = [];
	$.each(byDev, function(dev, list) {
		list.sort(function(a, b) { return a.t - b.t; });
		var run = [];
		$.each(list, function(i, p) {
			var last = run.length ? run[run.length - 1] : null;
			if (last && p.lat === last.lat && p.lon === last.lon) { return; }
			run.push(p);
		});
		if (run.length < 2) { return; }
		var span = 0;
		for (var i = 1; i < run.length; i++) {
			if (typeof jawnosMarkerMetres === 'function') { span = Math.max(span, jawnosMarkerMetres(run[0], run[i])); }
		}
		if (span < 50) { return; }
		lines.push({ colour: '#a0503f', points: run.map(function(p) { return { lat: p.lat, lon: p.lon }; }) });
	});
	engine.setLines(lines);
	fixPoints.forEach(function(p) { points.push({ lat: p.lat, lon: p.lon, colour: '#a0503f' }); });
	if (home.latitude && home.longitude) {
		points.push({ lat: home.latitude, lon: home.longitude, colour: '#6f4f9f', label: jawnosT('Home') });
	}
	engine.setPoints(points);
	// frame the fixes themselves, so a home plate far away cannot shrink them to a
	// dot; the home point still rides on the map when it is in view
	var frame = linePoints.length ? linePoints : (fixPoints.length ? fixPoints : (home.latitude && home.longitude ? [{ lat: home.latitude, lon: home.longitude }] : []));
	if (frame.length) {
		var lats = frame.map(function(p) { return p.lat; });
		var lons = frame.map(function(p) { return p.lon; });
		var minLat = Math.min.apply(null, lats), maxLat = Math.max.apply(null, lats);
		var minLon = Math.min.apply(null, lons), maxLon = Math.max.apply(null, lons);
		if (Math.max(maxLat - minLat, maxLon - minLon) < 0.002) {
			var lat = (minLat + maxLat) / 2, lon = (minLon + maxLon) / 2;
			engine.fitBounds({ nw: { lat: lat + 0.001, lon: lon - 0.001 }, se: { lat: lat - 0.001, lon: lon + 0.001 } }, 1);
		}
		else {
			engine.fitBounds({ nw: { lat: maxLat, lon: minLon }, se: { lat: minLat, lon: maxLon } }, 1.25);
		}
	}
	engine.draw();
}

$(document).on('change', '.appointment_dist_view', function() {
	appointmentDistShow($(this).closest('.appointment_distance_panel'));
});

$(document).on('click', '.appointment_list_toggle', function() {
	var list = $(this).attr('list');
	var detail = $(this).closest('.appointment_detail');
	var l = detail.find('.appointment_list[list="' + list + '"]');
	if (l.is(':visible')) {
		l.hide();
	}
	else {
		l.show();
		if (list == 'distance') {
			appointmentDistFill(detail);
			appointmentDistShow(l.filter('.appointment_distance_panel'));
		}
	}
	appActSync($(this).closest('.wind'));

});
$(document).on('click', '.delete_duty', function() {
	var a = $(this);
	var duuid = a.attr('duuid');
	var server_time = a.attr('server_time');
	var app = a.closest('.appointment').attr('app');
	var app_uuid = a.closest('.appointment_detail').attr('uuid');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/delete_duty',
			type: 'POST',
			data: { duuid: duuid, server_time: server_time, app: app, app_uuid: app_uuid },
			success:function(response) {

				$('.appointment_duty_container[duuid="' + response.duuid + '"]').remove();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');			
		},2000);
	}
});

// Autostop on a running appointment: ticked means the home plate stops it when
// left, unticked leaves it running for a hand stop. The box is put back the way
// it was when the write is refused, so the bar never lies about the session.
$(document).on('change', '.appointment_autostop', function() {
	var a = $(this);
	var app = a.attr('app');
	var uuid = a.attr('uuid');
	var value = a.prop('checked') ? 'on' : 'off';
	a.prop('disabled', true);
	$.ajax({
		url: '/manager/appointment/autostop',
		type: 'POST',
		data: { app: app, uuid: uuid, value: value },
		success: function(response) {
			a.prop('disabled', false);
			if (!response || !response.autostop) {
				a.prop('checked', !a.prop('checked'));
				return;
			}
			a.prop('checked', response.autostop != 'off');
			a.closest('.appointment_autostop_bar').attr('autostop', response.autostop);
		},
		error: function() {
			a.prop('disabled', false);
			a.prop('checked', !a.prop('checked'));
		}
	});
});

$(document).on('click', '.download', function() {
	var d = $(this);
	var file = d.attr('file');
	var uuid = d.attr('uuid');
	var app = d.attr('app');
	var server_time = d.attr('server_time');
	var timestamp = d.attr('timestamp');
	var remote = d.attr('remote_uuid') || '';
	var uri = encodeURIComponent(app);
	window.location='/manager/download_file?app=' + uri + '&uuid=' + uuid + '&timestamp=' + timestamp + '&server_time=' + server_time + '&file=' + file + (remote ? '&remote_uuid=' + encodeURIComponent(remote) : '');
});

// Queue one appointment file for the archive. The Folders archive route picks
// the location and the machine; the reply is the same dialog and job the
// Folders app shows, so the bar and Stop work here too.
$(document).on('click', '.archive_file', function() {
	var d = $(this);
	var file = d.attr('file');
	if (!file) { return; }
	$('body').css({ 'cursor': 'var(--jawnos-cursor-progress, progress)' });
	$.ajax({
		url: '/manager/folders/archive',
		type: 'POST',
		data: { folders: JSON.stringify({ selected: [ { path: file, type: 'file' } ], folder: file }) },
		success: function(response) {
			$('body').css({ 'cursor': 'var(--jawnos-cursor-default, auto)' });
			if (!response || !response.dialog) { return; }
			if (typeof foldersJobWatcher === 'function') {
				$('#dialog_boxes').append(response.dialog);
				foldersJobWatcher();
				return;
			}
			var box = $(response.dialog).addClass('appointment_archive_dialog');
			$('#dialog_boxes').append(box);
			appointmentArchiveWatch(box);
		},
		error: function() { $('body').css({ 'cursor': 'var(--jawnos-cursor-default, auto)' }); }
	});
});

// The Folders app's watcher is part of its lazy chunk; an appointment opened on
// its own still needs the job line to move and Stop to work.
function appointmentArchiveWatch(box) {
	var id = box.attr('job');
	if (!id) { return; }
	var timer = setInterval(function() {
		if (!box.closest('body').length || !box.attr('job')) { clearInterval(timer); return; }
		$.ajax({
			url: '/manager/folders/job',
			type: 'GET',
			data: { id: id },
			success: function(job) {
				if (!job || job['status'] != 'ok') {
					box.removeAttr('job').find('.job_progress').text('that job is gone');
					clearInterval(timer);
					return;
				}
				var word = job['progress'] || job['state'];
				if (job['archive']) {
					var a = job['archive'];
					word = (a['state'] || '') + ' ' + (a['percent'] || 0) + '%';
					if (a['file']) { word += ' - ' + a['file']; }
					if (a['resumable']) { word += ' - resumes where it stopped'; }
				}
				if (job['errors'] && job['errors'].length) { word += ' ' + job['errors'].join('; '); }
				var target = box.find('.job_progress .job_line');
				if (target.length) { target.text(word); } else { box.find('.job_progress').text(word); }
				var bar = box.find('.job_progress .job_bar');
				if (bar.length && job['archive']) { bar.show().find('span').css({ 'width': Math.max(0, Math.min(100, job['archive']['percent'] || 0)) + '%' }); }
				if (job['state'] == 'finished' || job['state'] == 'failed') {
					box.removeAttr('job');
					box.find('.job_stop').remove();
					clearInterval(timer);
				}
			}
		});
	}, 1000);
}

$(document).on('click', '.appointment_archive_dialog .job_stop', function() {
	// the Folders chunk's own job_stop handler covers this when it is loaded
	if (typeof foldersJobWatcher === 'function') { return; }
	var b = $(this);
	b.closest('.dialog_box').find('.job_progress').text('stopping...');
	$.ajax({ url: '/manager/folders/job/cancel', type: 'POST', data: { id: b.attr('job') } });
});

$(document).on('click', '.take_picture', function() {
	var d = $(this).closest('.appointment_detail');
	var app = d.attr('app');
	var uuid = d.attr('uuid');
	var camera = $(this).attr('camera');
	var container = d.closest('.appointment');
	var timestamp = Date.now();
	var ago = container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	// In the app the OS camera is the viewfinder the person can see. The
	// server-side camera.photo path has none, and its device-bridge call gives up
	// after two seconds while a real capture takes far longer - so the same press
	// behaved differently in the two views. Both templates now use the bridge.
	if (jawnCameraAvailable() && (camera === '0' || camera === '1')) {
		window.__jawnCameraPending = { app: app, uuid: uuid, camera: camera, timestamp: timestamp };
		window.JawnCamera.photo(camera);
		return;
	}
	$.ajax({
		url: '/manager/take_picture',
		type: 'POST',
		data: { app: app, uuid: uuid, camera: camera, timestamp: timestamp, ago: ago, time_machine: time_machine, timeshift: timeshift },
		success: function(response) {

		}
	});
});

$(document).on('click', '.scan_document', function() {
	var d = $(this).closest('.appointment_detail');
	var container = d.closest('.appointment');
	var app = d.attr('app');
	var uuid = d.attr('uuid');
	var feed = $(this).attr('feed');
	var timestamp = Date.now();
	var ago = container.find('.ago').val();
	var time_machine = $('#time_machine').val() || localStorage.getItem('time_machine');
	var timeshift = localStorage.getItem('timeshift') + localStorage.getItem('timeshift_scope');
	$.ajax({
		url: '/manager/scan_document',
		type: 'POST',
		data: { app: app, uuid: uuid, feed: feed, timestamp: timestamp, ago: ago, time_machine: time_machine, timeshift: timeshift },
		success: function(response) {

		}
	});
});

var m;
var main_h;
$(document).on('click', '.upload_file, #upload', function(e) {
	var b = $(this);
	var m =	$('#main_upload_input');

	var app = undefined;
	var uuid = undefined;
	var source = 'main_upload';
	
	if (b.hasClass('app_upload')) {
		app = b.closest('.appointment_detail').attr('app');
		uuid = b.closest('.appointment_detail').attr('uuid');
		source = 'app_upload';
	}
	m.attr('app', app);
	m.attr('uuid', uuid);
	m.attr('source', source);
	main_h = $('#main_upload_container').html();
	m.trigger('click');
});

$(document).on('change', '#main_upload_input', function() {
	var m =	$('#main_upload_input');
	
//	m.trigger('click');

	$.each(m[0]['files'], function(i,v) {

	});
	if (m[0]['files'].length > 0) {
		$('#main_upload').trigger('submit');
	}
});

$(document).on('submit', "#main_upload", function(e) {
  e.preventDefault();
	var mui =	$('#main_upload_input');
  var formData = new FormData(this);
	formData.delete('timestamp');
	formData.append('timestamp', timestamp);
	var apper = $('.wind[app="' + topWindow() + '"]');
	var navigation = $(apper).attr('navigation');
	app = $(apper).attr('app') || $('#search').val();
	formData.delete('app');
	formData.delete('uuid');
	var source = mui.attr('source');
	if (source == 'app_upload') {
		app = mui.attr('app');
		var uuid = mui.attr('uuid');
		formData.append('uuid', uuid);
	}

	formData.append('app', app);
	formData.append('source', source);
  $.ajax({
      url: '/manager/upload_file',
      type: 'POST',
      data: formData,
      success: function (response) {
				m = undefined;
				formData.delete('fileupload');
				$('#main_upload').remove();
				$('#main_upload_container').html(main_h);
				appClearer(app);
				continent_record({'uuid':response['uuid'],'purpose':'app','app':response['app'],'timestamp':response['timestamp'],'navigation':navigation});
      },
      cache: false,
      contentType: false,
      processData: false
  });
});

// The title in a window's bar is a label, not a source: clicking it raises the
// window (the .top_navbar handler), but it does not pour the app's name into
// the focused input. An appointment's own .name_text still does.
$(document).on('click', '.name_text', function(){
	if ($(this).closest('.top_navbar').length) { return; }
	var text = $(this).text();
	focused_input.val(text);
});

$(document).on('click','.app_act, .save_appointment',function() {
	var b = $(this);
	var app = b.attr('app') || b.closest('.appointment').attr('app');
	var originalColour = b.css('background-color');
	b.css({'background-color': 'blue'});
	setTimeout(function() { b.css({'background-color': originalColour }); },750);
//	cacheDelete({ app: app, context: 'template' });
});

// the appointment's three group buttons each open the buttons they carry
// beneath them; opening one folds the others away, so the row under the
// groups always answers the button just pressed
$(document).on('click', '.group_toggle', function() {
	var group = $(this).attr('group');
	var appointment = $(this).closest('.appointment');
	var contents = appointment.find('.' + group + '_group_contents');
	var open = contents.is(':visible');
	appointment.find('.group_contents').hide();
	if (!open) { contents.show(); }
});

// The media machine choice is a preference of this person at this screen, like
// the keyboard's own device picks; remembering it in `me` makes the next
// appointment open on the same machine.
$(document).on('change', '.media_machine', function() {
	var sel = $(this);
	var group = sel.attr('group') || '';
	if (!group) { return; }
	$.ajax({
		url: '/manager/configure',
		type: 'POST',
		data: { app: 'me', setting: 'media_machine_' + group, value: sel.val() || '', timestamp: Date.now() }
	});
});

$(document).on('click','#calculate_it', function() {
	clearInterval(calculateInterval);
	calculator();
});

$(document).on('click, change', '#update_frequency', function() {
	var f = $(this).val();
	localStorage.setItem('update_frequency', f);
	initializer()
});





// Where an appointment happened.
//
// continent_record() is asked for on every start and stop by the appointment
// code, the transaction panel, the phone path and Music - all of it core. It
// used to live in the Travel app's chunk, so with Travel never opened the
// call threw "continent_record is not defined" and the place was simply not
// recorded. The GPS helpers beside it are its only callers, so they moved
// with it; Travel keeps the map and the navigation window.

function jawnGpsFix() {
	if (!window.JawnLocation || typeof window.JawnLocation.latest !== 'function') { return null; }
	var raw = '';
	try { raw = window.JawnLocation.latest(); } catch (e) { return null; }
	if (!raw) { return null; }
	var fix = null;
	try { fix = JSON.parse(raw); } catch (e) { return null; }
	if (!fix || fix.provider !== 'gps' || !fix.latitude || !fix.longitude) { return null; }
	// Age is measured from the fix's own wall-clock time, not the elapsedMs the
	// file carried when it was written: a file written four minutes ago with
	// elapsedMs 0 is a four-minute-old fix, not a fresh one.
	var age;
	if (fix.time) { age = Date.now() - fix.time; }
	else if (typeof fix.elapsedMs === 'number') { age = fix.elapsedMs + (fix.sampled ? Date.now() - fix.sampled : 0); }
	else { age = 0; }
	if (!isFinite(age) || age < 0) { age = 0; }
	fix.age = age;
	return fix;
}

// Poll for a fix newer than the moment the person pressed. The sample is
// asynchronous; twenty seconds is the same bound the old getCurrentPosition used.
function jawnGpsWait(after, timeout, callback) {
	var started = Date.now();
	var tick = function () {
		var fix = jawnGpsFix();
		// A fix from a second or two before the press is still this place.
		if (fix && fix.time && fix.time >= after - 2000) { callback(fix); return; }
		if (Date.now() - started >= timeout) { callback(null); return; }
		setTimeout(tick, 500);
	};
	tick();
}

function continent_cancel(app) {
	// The GPS service is shared and keeps its own pace; nothing per-app to cancel.
}

function continent_record(setter) {
	var navigation = setter['navigation'];
	if (navigation == 'none') {
		return;
	}
	var app = setter['app'] || 'me';
	var timestamp = setter['timestamp'];
	var purpose = setter['purpose'];
	var scope = setter['scope'];
	var device = setter['device'];
	timestamp = timestamp || Date.now();
	var hostname = $(location)[0]['hostname'];
	var pathname = $(location)[0]['pathname'];
	var protocol = $(location)[0]['protocol'];
	var uuid = setter['uuid'];
	var complete = typeof setter['complete'] == 'function' ? setter['complete'] : null;
	var anyway = function() {
		continent_record_anyway({ app: app, scope: scope, uuid: uuid, purpose: purpose, timestamp: timestamp, device: device }, complete);
	};

	// Ask for a fresh sample now: a start or stop is "where am I as I begin or
	// end this", not the last four-minute beat. The appointment's own route has
	// already run; this attaches the place when the GPS answers. A desktop has
	// no bridge and goes straight to the anyway route (a deck or teletype).
	if (!window.JawnLocation || typeof window.JawnLocation.sample !== 'function') {
		anyway();
		return;
	}
	var askedAt = Date.now();
	try { window.JawnLocation.sample(); } catch (e) {}

	// Wait up to twenty seconds for the sample to land. A cold GPS indoors can
	// take that long; the appointment start or stop has already happened (its
	// route ran), so this attaches the place when the fix answers. A cached fix
	// is only used when no fresh one arrives, and its own timestamp is kept.
	jawnGpsWait(askedAt, 20000, function (fresh) {
		// A fresh fix is what the press asked for. A cached one is only used when
		// the GPS did not answer in time, and its own timestamp is kept - never
		// restamped as today's.
		var fix = fresh || jawnGpsFix();
		if (!fix || fix.age > 15 * 60 * 1000) {
			// Indoors or in a pocket: file the appointment with no place rather
			// than a guess.
			anyway();
			return;
		}

		// A running appointment may ask for fixes faster than the service's
		// resting pace. Retune it; the service keeps the GPS warm and the next
		// fix arrives without a browser timer.
		var pace = 0;
		if (navigation && navigation != 'once') {
			try { pace = numeral(navigation).value(); } catch (e) { pace = 0; }
			if (pace > 0 && window.JawnLocation && typeof window.JawnLocation.startAt === 'function') {
				window.JawnLocation.startAt(String(pace), '0');
			}
		}

		var payload = {
			latitude: fix.latitude,
			longitude: fix.longitude,
			altitude: fix.altitude,
			speed: fix.speed,
			accuracy: fix.accuracy,
			provider: 'gps',
			timestamp: fix.time || Date.now(),
			user_agent: navigator.userAgent,
			hostname: hostname,
			pathname: pathname,
			protocol: protocol,
			purpose: purpose,
			scope: scope,
			app: app,
			device: device,
			uuid: uuid,
			navigation: setter['navigation']
		};
		if (pace > 0) { payload['next_navigation'] = Date.now() + pace; }
		$.ajax({
			url: '/manager/continent/record',
			type: 'POST',
			data: payload,
			success: function(response) {
				if (complete) { complete(response); }
				return response;
			},
		});
	});
}

function continent_record_anyway(data, complete) {
	$.ajax({
		url: '/manager/continent/record_anyway',
		type: 'POST',
		data: data,
		success: function(response) {
			if (typeof complete == 'function') { complete(response); }
		}
	}); 
}

