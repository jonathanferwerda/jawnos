function travelMapRender(response) {
	if (!window.jawnosMap) { return; }
	travelProviderFill();
	var engine = travelMapEngine();
	if (!engine) { return; }
	travelMapsRestore();
	engine.setProvider($('.travel_provider').val() || 'none', $('#travel_custom_url').val(), travelProviderKeys());
	travelAllMaps = response['all_maps'] || [];
	var shownMaps = $.grep(travelAllMaps, function(m) { return m['guessed'] || travelHiddenMaps.indexOf(m['uuid']) < 0; });
	engine.setMaps(shownMaps);

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
		if (bounds) { engine.fitBounds(bounds); travelFramed = true; travelViewPersist(); }
	}

	var points = [];
	var places = [];
	var fixesByApp = {};
	$.each(response['near'] || [], function(i, point) {
		if (!point || !point['latitude'] || !point['longitude']) { return; }
		// only an actual fix or place row; a home-plate record, a viewer's own
		// bookkeeping row and the transient position are not marks on the map
		var kind = point['type'] || '';
		if (kind !== '' && kind !== 'app') { return; }
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
		// every fix that names an appointment, in time order: a track is a session,
		// not an app's whole history. Two devices can file fixes under the same
		// appointment (one stays home while the other walks), so the house names the
		// device that was actually with the person: the carrier. Its fixes make the
		// track; a device left at home is skipped, so its jitter cannot zigzag it.
		var stamp = parseFloat(point['timestamp']) || 0;
		if (point['app'] && point['appointment_uuid'] && stamp) {
			if (point['carrier'] === 0) { return; }
			var fixKey = point['appointment_uuid'];
			// older data carries no carrier: fall back to one run per device
			if (point['carrier'] !== 1) { fixKey += '|' + (point['signatorial'] || ''); }
			(fixesByApp[fixKey] = fixesByApp[fixKey] || []).push({ lat: lat, lon: lon, t: stamp, colour: colour });
		}
	});
	travelBasePoints = points;
	travelPlaceGroups = jawnosMarkerGroups(places, 50, '#2f6f9f');
	travelPointsDraw();

	// a line joins the fixes that share an appointment's uuid, in the order they
	// were taken, so a line is one session. Repeated points are skipped and a run
	// that never leaves one spot is jitter, not a track.
	var lines = [];
	$.each(fixesByApp, function(session, list) {
		list.sort(function(a, b) { return a.t - b.t; });
		var run = [];
		var push = function() {
			if (run.length < 2) { return; }
			var span = 0;
			for (var i = 1; i < run.length; i++) {
				if (typeof jawnosMarkerMetres === 'function') { span = Math.max(span, jawnosMarkerMetres(run[0], run[i])); }
			}
			if (span < 50) { return; }
			lines.push({ colour: run[0].colour || '#a0503f', points: run });
		};
		$.each(list, function(i, fix) {
			var last = run.length ? run[run.length - 1] : null;
			if (last && fix.lat === last.lat && fix.lon === last.lon) { return; }
			run.push({ lat: fix.lat, lon: fix.lon });
		});
		push();
	});
	engine.setLines(lines);

	var pos = response['position'];
	var hasPos = pos && pos['latitude'];
	engine.setPosition(hasPos ? { lat: parseFloat(pos['latitude']), lon: parseFloat(pos['longitude']), label: pos['label'] || 'You are here' } : null);
	// what the house photographed around here: a bar along the top
	if (hasPos) {
		travelNearFetch(parseFloat(pos['latitude']), parseFloat(pos['longitude']), engine.viewBounds(), 'travel_near', null, false);
	}
	else { $('#travel_near').hide(); }

	// frame the current position (with the maps around it) the first time; after
	// that leave the view where the user panned it
	if (!travelFramed) {
		if (hasPos) { engine.focusOn(parseFloat(pos['latitude']), parseFloat(pos['longitude'])); }
		else if ((response['all_maps'] || []).length) { engine.fitToMaps(); }
		travelFramed = true;
	}
	travelPlatesLoad();
	engine.draw();
}

// the home plates on screen sit above the places, with a house glyph
function travelPointsDraw() {
	if (!travelMap) { return; }
	var plats = $.map(travelPlateList || [], function(p) {
		var lat = +p.latitude, lon = +p.longitude;
		if (!isFinite(lat) || !isFinite(lon)) { return null; }
		return { lat: lat, lon: lon, app: p.app, name: p.name || p.app, colour: '#6f4f9f' };
	});
	var plates = jawnosMarkerGroups(plats, 12, '#6f4f9f');
	$.each(plates, function(i, g) { g.home = 1; });
	travelMap.setPoints(travelBasePoints.concat(travelPlaceGroups).concat(plates));
}

// fetched for the ground on screen, cached by the view, so panning into a place
// only asks for the plates there
function travelPlatesLoad() {
	if (!travelMap) { return; }
	var b = travelMap.viewBounds();
	if (!b || !b.nw || !b.se) { return; }
	var key = [b.nw.lat, b.nw.lon, b.se.lat, b.se.lon].map(function(v) { return (+v).toFixed(3); }).join(',');
	if (travelPlatesCache[key]) { travelPlateList = travelPlatesCache[key]; travelPointsDraw(); return; }
	$.ajax({
		url: '/manager/home_plates',
		type: 'GET',
		data: { nw_lat: b.nw.lat, nw_lon: b.nw.lon, se_lat: b.se.lat, se_lon: b.se.lon },
		success: function(r) {
			var list = (r && r.plates) || [];
			if (Object.keys(travelPlatesCache).length > 40) { travelPlatesCache = {}; }
			travelPlatesCache[key] = list;
			travelPlateList = list;
			travelPointsDraw();
		}
	});
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
	var map = travelAnchorMap || $('#travel_maps_button').attr('anchor') || '';
	var tdata = { map: map, uuid: data['uuid'], time_scope: time_scope, timestamp: ts, settings: jsettings };
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
				var detail = a.closest('.appointment_detail');
				$('.appointment_distance_container[uuid="' + response.uuid + '"]').remove();
				// the Dist map keeps its own copy of the fixes; drop the deleted one so
				// a map opened afterwards does not draw a point that is gone
				var data = detail.find('.appointment_distance_data');
				if (data.length) {
					var parsed = {};
					try { parsed = JSON.parse(data.text() || '{}') || {}; } catch (e) { parsed = {}; }
					if (parsed.points) {
						parsed.points = $.grep(parsed.points, function(p) { return p.uuid != response.uuid; });
						data.text(JSON.stringify(parsed));
					}
				}
				var panel = detail.find('.appointment_distance_panel');
				if (panel.length && panel.find('.appointment_dist_view').val() != 'fixes') { appointmentDistShow(panel); }
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

