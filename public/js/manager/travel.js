var campusProxy = {};

var mapData = {};
$(document).on('click', '#travel_toggle', function() {
	travelToggle();
});

function travelToggle() {
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = timestamp; 
	}
	var url = '/manager/travel';
	$.ajax({
		url: url,
		type: 'GET',
		data: { window_maker: 'yes', timestamp: ts },
		success: function(response) {
			windowMaker(response);

			travelViewer({ timestamp: ts });
		}, error: function (response) {  }
	});
}


// The travel map is drawn by jawnosMap (public/js/manager/mapengine.js): a pan-able
// viewport that shows every measured map we have, each placed by the georeference it
// carries (its home_plate pixel and scale bar), over an optional tile layer from a
// chosen provider, with the continent points and the machine's current position on
// top. Drag to pan; wheel or pinch to zoom.
var travelMap;
var travelFramed = false;
var travelPendingMap;   // the map the picker just chose, to be framed once its atlas arrives

function travelMapEngine() {
	var canvas = document.getElementById('travel_campus');
	if (!canvas || !window.jawnosMap) { return null; }
	if (travelMap && travelMap.canvas === canvas) { return travelMap; }
	// a fresh canvas (the window was reopened) needs a fresh engine
	travelMap = window.jawnosMap.create('travel_campus', {
		z: 16,
		width: function() { return $('#travel_campus').parent().width() || 640; },
		height: function() { return Math.max(240, Math.round($(window).height() * 0.6)); }
	});
	// a tap on a place opens its appointment window; a numbered one unfolds its list
	travelMap.onMarkerClick(function(pt, sx, sy) { jawnosMarkerTapped(pt, sx, sy, travelMap.canvas); });
	// a right-click on a guessed gap offers to drop it (so the hat may fill that
	// ground afresh); anywhere else the engine leaves the event alone
	travelMap.onMapContext(function(m, sx, sy) {
		if (!m || !m.guess) { return 0; }
		jawnosGuessMenu(m, sx, sy, travelMap.canvas);
		return 1;
	});
	travelMap.onChange(jawnosMarkerListHide);
	// with the hat on, a pause in the pan asks for the empty ground on screen to
	// be guessed (the server decides what is empty; a guess only ever shows where
	// nothing is mapped)
	travelMap.onChange(function() {
		if ($('#travel_guess_gap').attr('status') != 'enabled') { return; }
		clearTimeout(travelGuessTimer);
		travelGuessTimer = setTimeout(function() { travelGuessCheck(); }, 2500);
	});
	travelFramed = false;
	return travelMap;
}

// Fill the provider picker from the engine's own table, so the two cannot drift.
function travelProviderFill() {
	var sel = $('.travel_provider');
	if (!sel.length || sel.attr('filled') == 'yes' || !window.jawnosMap) { return; }
	sel.attr('filled', 'yes');
	var engines = window.jawnosMap.providers;
	for (var key in engines) {
		$('<option></option>').attr('value', key).text(engines[key].name).appendTo(sel);
	}
	sel.val(sel.attr('provider') || 'none');
}

function travelMapRender(response) {
	if (!window.jawnosMap) { return; }
	travelProviderFill();
	var engine = travelMapEngine();
	if (!engine) { return; }
	engine.setProvider($('.travel_provider').val() || 'none', $('#travel_custom_url').val());
	engine.setMaps(response['all_maps'] || []);

	// a guessed gap is a kept picture, not a picker entry: the newest one is named
	// on the status line (and that is where it is deleted from)
	var newest;
	$.each(response['all_maps'] || [], function(i, m) { if (m['guessed']) { newest = m; } });
	if (newest && !/\S/.test($('#travel_guess_status').text())) {
		travelGuessStatus('last guess: ' + (newest['name'] || ''), newest['uuid']);
	}

	// the picker's choice brings that measured map into the centre of the view
	if (travelPendingMap) {
		var chosen;
		$.each(response['all_maps'] || [], function(i, m) {
			if (m['uuid'] == travelPendingMap) { chosen = m; }
		});
		travelPendingMap = undefined;
		var bounds = chosen ? window.jawnosMap.mapBounds(chosen) : null;
		if (bounds) { engine.fitBounds(bounds); travelFramed = true; }
	}

	var points = [];
	var places = [];
	$.each(response['near'] || [], function(i, point) {
		if (!point || !point['latitude'] || !point['longitude']) { return; }
		if (point['settings'] && point['settings']['visible'] && point['settings']['visible'] != 'checked') { return; }
		var lat = parseFloat(point['latitude']);
		var lon = parseFloat(point['longitude']);
		var colour = (point['settings'] && point['settings']['colour']) || undefined;
		if (point['settings']) {
			// a place the continent knows: tappable, and grouped when several share
			// one spot, so the tap opens the app it means (or unfolds them)
			places.push({ app: point['app'], name: point['name'] || point['settings']['name'] || point['app'], colour: colour, lat: lat, lon: lon });
		}
		else {
			points.push({ lat: lat, lon: lon, label: point['app'] || '', colour: colour });
		}
	});
	engine.setPoints(points.concat(jawnosMarkerGroups(places, 50, '#2f6f9f')));

	var pos = response['position'];
	var hasPos = pos && pos['latitude'];
	engine.setPosition(hasPos ? { lat: parseFloat(pos['latitude']), lon: parseFloat(pos['longitude']), label: pos['label'] || 'You are here' } : null);

	// frame the current position (with the maps around it) the first time; after
	// that leave the view where the user panned it
	if (!travelFramed) {
		if (hasPos) { engine.focusOn(parseFloat(pos['latitude']), parseFloat(pos['longitude'])); }
		else if ((response['all_maps'] || []).length) { engine.fitToMaps(); }
		travelFramed = true;
	}
	engine.draw();
}

function travelViewer(data) {
	if (!data) { data = {}; }
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = data['timestamp']; 
	}
	var jsettings;
	if (data['settings']) {
		jsettings = JSON.stringify(data['settings']);
		console.log(data['settings']);
		console.log(jsettings);
	}
	var time_scope = localStorage.getItem('scope');
	var sel = $('.travel_map_selector').find('option[selected]');
	var map = sel.val();
	var tdata = { map: map, uuid: data['uuid'], time_scope: time_scope, timestamp: ts, settings: jsettings };
	console.log(tdata);
	$.ajax({
		url: '/manager/travel/viewer',
		type: 'GET',
		data: tdata,
		success: function(response) {
			if (response && response['error']) { console.log(response['error']); return; }
			console.log(response);
			mapData = response;
			$('#travel_campus').show();
			$('#travel_proxy_view').html(response['html']);
			travelMapRender(response);
			$('#travel_start_time').attr('timestamp', response['start_time']);
			$('#travel_end_time').attr('timestamp', response['end_time']);
			$('#travel_appt').val(response['settings']['search']);
			appointment_chron();
		}
	});
}

$(document).on('click', '#travel_update', function() {
	var ts = Date.now();
	if ($('.now').attr('presence') == 'not') {
		ts = timestamp; 
	}
	travelViewer({ timestamp: ts });
});

$(document).on('click', '#travel_home_plate', function() {
	var t = $(this);
	var status = 'enabled';
	if (t.attr('status') == 'enabled') {
		status = 'disabled';
	}
	else {
		status = 'enabled';
	}
	t.attr('status',status);
	settingSetter({ 'app': 'travel', 'setting': 'home_plate_enabled', 'value': t.attr('status') });
	travelViewer({ settings: { 'home_plate_enabled': t.attr('status') } });
});


// The page has one location source: the app's own GPS service. A WebView or
// browser geolocation answer carries no provider, so a Wi-Fi/cell guess looks
// exactly like a fix - which is what put the person in places they had never
// been. Desktops have no GPS; they fall through to the anyway route, which can
// ask a deck or teletype with a real one.
$(document).ready(function () {
	if (window.JawnLocation && typeof window.JawnLocation.start === 'function') {
		// The service is the only place source; start it with the view so a real
		// fix is ready before the first appointment or navigation request. The
		// notification's Stop button turns it off again.
		try { window.JawnLocation.start(); } catch (e) {}
	}
});

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

// The start menu's navigation button: ask for a fix now, with no appointment
// behind it, and let the site-type picture follow the answer. A computer with
// no GPS of its own first asks the phone or deck on this LAN; when none answers
// it falls back to the same browser path an appointment start takes.
function navigationNowApply(response) {
	if (!response) { return; }
	var icon = $('#site_type_toggle');
	if (response['site_icon'] && icon.length) {
		icon.attr('src', response['site_icon']);
	}
	var source = response['site_source'];
	if (source == 'manual' || source == 'lost') {
		icon.css({ 'border-style': 'solid', 'border-color': (source == 'manual' ? 'red' : 'black'), 'border-width': '8px' });
	}
	else if (source) {
		icon.css({ 'border-style': '', 'border-color': '', 'border-width': '' });
	}
	startMenuHtmlFlush();
}

function navigationNowLocal() {
	continent_record({
		app: 'me',
		purpose: 'navigation',
		navigation: 'once',
		complete: navigationNowApply
	});
}

function navigationNow() {
	$.ajax({
		url: '/manager/navigation/nearby',
		type: 'POST',
		data: { timestamp: Date.now() },
		success: function(response) {
			if (response && response['latitude']) {
				navigationNowApply(response);
				return;
			}
			navigationNowLocal();
		},
		error: navigationNowLocal
	});
}

$(document).on('click', '#navigation_now', function(e) {
	e.preventDefault();
	e.stopPropagation();
	navigationNow();
});

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

$(document).on('click', '.delete_location', function() {
	var a = $(this);
	var uuid = a.attr('uuid');
	var server_time = a.attr('server_time');
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/continent/delete',
			type: 'POST',
			data: { uuid: uuid, server_time: server_time },
			success:function(response) {

				$('.appointment_distance_container[uuid="' + response.uuid + '"]').remove();
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

$(document).on('change', '.travel_map_selector', function() {
	var uuid = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'current_map', 'value': uuid });

	var s = $('.travel_map_selector').find('option[selected]').removeAttr('selected');

	$('.travel_map_selector').find('option[value="' + uuid + '"]').attr('selected', 'yes');

	// choosing a map brings it into view once the viewer answers with its bounds
	travelPendingMap = uuid;
	setTimeout(function() {
		var timestamp = Date.now();
		travelViewer({ timestamp: timestamp });
	},200);
});


$(document).on('click', '.delete_travel_map', function() {
	var a = $(this);
	var sel = $('.travel_map_selector').find('option[selected]');
	var uuid = sel.attr('value');
	var app_uuid = sel.attr('app_uuid');
	var app = sel.attr('app');
	if (a.attr('armed') == 'yes') {
		var obg = a.attr('obg');
		a.css({'background-color': obg });

		$.ajax({
			url: '/manager/travel/delete_map',
			type: 'POST',
			data: { file_uuid: uuid, app_uuid: app_uuid, app: app },
			success: function(response) {
				travelToggle();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.attr('obg', bgcolor);
		a.css({'background-color': 'red' });
		setTimeout(function() {
			a.css({'background-color': bgcolor });
			a.attr('armed', 'no');
		},2000);
	}
});

$(document).on('change', '.travel_provider', function() {
	var value = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'map_provider', 'value': value });
	if (travelMap) { travelMap.setProvider(value, $('#travel_custom_url').val()); }
});

$(document).on('change', '#travel_custom_url', function() {
	var value = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'map_custom_url', 'value': value });
	if (travelMap) { travelMap.setProvider($('.travel_provider').val() || 'none', value); }
});

$(document).on('click', '#travel_config_toggle', function() {

	var tc = $('#travel_config');
	var status = tc.attr('status');
	if (status == 'visible') {
		status = 'hidden';
		tc.hide();
	} else {
		status = 'visible';
		// the toolbar is a flex row; .show() would restore the default block display
		tc.css('display', 'flex');
	}
	tc.attr('status', status);
	settingSetter({ 'app': 'travel', 'setting': 'config_visible', 'value': status });
});

$(document).on('click', '.travel_now', function() {
	settingDeleter({ 'app': 'travel', 'setting': 'start_time' });
	settingDeleter({ 'app': 'travel', 'setting': 'end_time' });
	settingDeleter({ 'app': 'travel', 'setting': 'appt' });
	var settings = {
		start_time: null,
		end_time: null,
		appt: null
	};
	var timestamp = Date.now();
	travelViewer({ timestamp: timestamp, settings: settings });
});

// The hat is a toggle: with it on, the map asks the server to guess the empty
// ground in what you are looking at (the Plat models draw it, and every measured
// map is drawn over it, so it only shows where nothing is known); with it off,
// the blanks stay blank. A pause in the pan does the asking, and the guess lands
// framed where it lies.
var travelGuessBusy = 0;
var travelGuessAt = 0;
var travelGuessTimer = null;

// The status line is the guess's handle: it names the newest guess, and tapping
// it arms (turns red, as the trash buttons do) - a second tap drops that guess.
// A guess is a kept picture rather than a map in the picker, so this is the way
// a bad one goes; panning after it leaves the gap blank for a fresh guess.
function travelGuessStatus(text, uuid) {
	var status = $('#travel_guess_status');
	status.text(text || '');
	if (uuid) {
		status.attr('guess_uuid', uuid).addClass('hover').attr('hint', 'Last guess — tap twice to delete it');
	}
	else {
		status.removeAttr('guess_uuid').removeClass('hover').removeAttr('hint');
	}
}

$(document).on('click', '#travel_guess_status', function() {
	var t = $(this);
	var uuid = t.attr('guess_uuid');
	if (!uuid) { return; }
	if (t.attr('armed') == 'yes') {
		t.attr('armed', 'no').css('color', '');
		$.ajax({
			url: '/manager/travel/delete_map',
			type: 'POST',
			data: { file_uuid: uuid, app_uuid: '', app: 'travel' },
			success: function() {
				travelGuessStatus('');
				travelViewer({ timestamp: Date.now() });
			}
		});
	}
	else {
		t.attr('armed', 'yes').css('color', '#c62828');
		var was = t.text();
		t.text('tap again to delete this guess');
		setTimeout(function() {
			if (t.attr('armed') == 'yes') { t.attr('armed', 'no').css('color', '').text(was); }
		}, 2000);
	}
});

$(document).on('click', '#travel_guess_gap', function() {
	var t = $(this);
	var status = (t.attr('status') == 'enabled') ? 'disabled' : 'enabled';
	t.attr('status', status);
	t.css(status == 'enabled' ? { 'background-color': '#2e7d32', 'border-radius': '6px' } : { 'background-color': '', 'border-radius': '' });
	settingSetter({ 'app': 'travel', 'setting': 'guess_enabled', 'value': status });
	if (status == 'enabled') { travelGuessCheck('yes'); }
	else {
		travelGuessStatus('');
		travelViewer({ timestamp: Date.now() });
	}
});

function travelGuessCheck(force) {
	if (!travelMap || !window.jawnosMap) { return; }
	if ($('#travel_guess_gap').attr('status') != 'enabled') { return; }
	if (travelGuessBusy) { return; }
	var now = Date.now();
	if (!force && (now - travelGuessAt) < 20000) { return; }
	var b = travelMap.viewBounds();
	if (!b || !isFinite(b.nw.lat) || !isFinite(b.se.lat)) { return; }
	travelGuessBusy = 1;
	travelGuessAt = now;
	travelGuessStatus('looking for empty ground…');
	$.ajax({
		url: '/manager/travel/guess_gap',
		type: 'POST',
		data: { minLat: b.se.lat, maxLat: b.nw.lat, minLon: b.nw.lon, maxLon: b.se.lon, timestamp: now },
		success: function(response) {
			travelGuessBusy = 0;
			if (response && response['error']) { travelGuessStatus(response['error']); return; }
			if (response && response['covered']) { travelGuessStatus('all of this view is mapped'); return; }
			travelGuessStatus('guessed ' + response['name'], response['uuid']);
			travelPendingMap = response['uuid'];
			travelViewer({ timestamp: Date.now() });
		},
		error: function() {
			travelGuessBusy = 0;
			travelGuessStatus('the guess could not be made - see Configure, Plat');
		}
	});
}

$(document).on('change', '#travel_search', function() {
	var search = $(this).val();
	settingSetter({'app':'travel','setting':'search', 'value': search });
});

$(document).on('click', '.site_type_manual_changer_toggle', function() {
	if ($('.start_menu_main_display').is(':visible') && $('.site_type_manual_changer_options').length > 0) {
		console.log('showing');
		$('.start_menu_main_display').hide();
		$('.site_type_manual_changer_options').show();
	}
	else {
		console.log('hiding');
		$('.start_menu_main_display').show();
		$('.site_type_manual_changer_options').hide();
	}
});

$(document).on('click', '.site_type_manual_changer', function() {
	var site = $(this).attr('site');
	console.log(site);
	$.ajax({
		url: '/manager/configure/site_type/manual_change',
		type: 'POST',
		data: {
			site: site
		},
		success: function(response) {
			console.log(response);
			startMenuToggle({ source: 'updated' });
		}
	});
});