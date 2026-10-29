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
var travelAllMaps = [];      // the last atlas answer, so a checkbox redraws without asking again
var travelHiddenMaps = [];   // measured maps the person has switched off
var travelAnchorMap;         // the map distances are measured from (the remembered current_map)
var travelViewSave;          // debounce for remembering the pan and zoom

function travelViewPersist() {
	if (!travelMap) { return; }
	var v = travelMap.view();
	settingSetter({ 'app': 'travel', 'setting': 'map_view', 'value': JSON.stringify({ lat: v.lat, lon: v.lon, z: v.z }) });
}

function travelMapEngine() {
	var canvas = document.getElementById('travel_campus');
	if (!canvas || !window.jawnosMap) { return null; }
	if (travelMap && travelMap.canvas === canvas) { return travelMap; }
	// where the map was left last time, so opening Travel returns to that ground
	var saved = {};
	try { saved = JSON.parse(canvas.getAttribute('view') || '{}') || {}; } catch (e) { saved = {}; }
	// a fresh canvas (the window was reopened) needs a fresh engine
	travelMap = window.jawnosMap.create('travel_campus', {
		lat: saved.lat,
		lon: saved.lon,
		z: (typeof saved.z === 'number') ? saved.z : 16,
		width: function() { return $('#travel_campus').parent().width() || 640; },
		height: function() { return Math.max(240, Math.round($(window).height() * 0.6)); }
	});
	// a tap on a place opens its appointment window; a numbered one unfolds its list
	travelMap.onMarkerClick(function(pt, sx, sy) { jawnosMarkerTapped(pt, sx, sy, travelMap.canvas); });
	// a still long press opens the street view of that ground
	travelMap.onLongPress(function(lat, lon) { travelStreetOpen(lat, lon); });
	// a right-click on a guessed gap offers to drop it (so the hat may fill that
	// ground afresh); anywhere else the engine leaves the event alone
	travelMap.onMapContext(function(m, sx, sy) {
		if (!m || !m.guess) { return 0; }
		jawnosGuessMenu(m, sx, sy, travelMap.canvas);
		return 1;
	});
	travelMap.onChange(jawnosMarkerListHide);
	// remember the pan and zoom (after the move settles) so the next open starts here
	travelMap.onChange(function() {
		clearTimeout(travelViewSave);
		travelViewSave = setTimeout(travelViewPersist, 700);
	});
	// with the hat on, a pause in the pan asks for the empty ground on screen to
	// be guessed (the server decides what is empty; a guess only ever shows where
	// nothing is mapped)
	travelMap.onChange(function() {
		if ($('#travel_guess_gap').attr('status') != 'enabled') { return; }
		clearTimeout(travelGuessTimer);
		travelGuessTimer = setTimeout(function() { travelGuessCheck(); }, 2500);
	});
	travelFramed = (typeof saved.lat === 'number' && typeof saved.lon === 'number' && typeof saved.z === 'number');
	return travelMap;
}

// ---- nearby media: pictures and videos taken while the house was here ----
var travelNearCache = {};
var travelNearLists = {};

function travelNearOpen(container, index) {
	var items = travelNearLists[container] || [];
	if (!items.length || typeof imageViewer !== 'function') { return; }
	// the Gallery's own file list shape, so its window opens on these photos and
	// its arrows step through the same set
	var files = items.map(function(it) {
		return { f: it.f, app: it.app, app_uuid: it.app_uuid, type: it.type, uuid: it.uuid, server_time: it.server_time, timestamp: it.timestamp, info: it.info || {} };
	});
	imageViewer({ files: files, target: files[index] ? files[index].f : undefined });
}

function travelNearRender(container, items) {
	travelNearLists[container] = items;
	var box = $('#' + container);
	var strip = box.find('.travel_near_strip');
	strip.empty();
	if (!items.length) { box.hide(); return; }
	$.each(items, function(i, it) {
		$('<img>').addClass('travel_near_thumb').attr('src', it.thumb_url).attr('alt', it.label || '').attr('title', it.label || '')
			.css({ width: '52px', height: '52px', objectFit: 'cover', borderRadius: '5px', marginRight: '3px', cursor: 'pointer', verticalAlign: 'middle', background: '#222' })
			.on('click', function() { travelNearOpen(container, i); })
			.appendTo(strip);
	});
	box.show();
}

function travelNearGallery(container, items) {
	travelNearLists[container] = items;
	var grid = $('#' + container);
	grid.empty();
	if (!items.length) { grid.hide(); return; }
	$.each(items, function(i, it) {
		$('<img>').addClass('travel_near_grid_thumb').attr('src', it.thumb_url).attr('alt', it.label || '').attr('title', it.label || '')
			.css({ width: '100%', height: '96px', objectFit: 'cover', borderRadius: '5px', cursor: 'pointer', background: '#222' })
			.on('click', function() { travelNearOpen(container, i); })
			.appendTo(grid);
	});
	grid.css('display', 'grid');
}

function travelNearFetch(lat, lon, strip_id, gallery_id) {
	var key = lat.toFixed(4) + ',' + lon.toFixed(4);
	var finish = function(items) {
		if (strip_id) { travelNearRender(strip_id, items); }
		if (gallery_id) { travelNearGallery(gallery_id, items); }
	};
	if (travelNearCache[key]) { finish(travelNearCache[key]); return; }
	$.ajax({
		url: '/manager/travel/nearby',
		type: 'GET',
		data: { lat: lat, lon: lon },
		success: function(r) {
			var items = (r && r.items) || [];
			travelNearCache[key] = items;
			finish(items);
		},
		error: function() { finish([]); }
	});
}

// ---- street view: Mapillary's nearest photo, with the house's own photos near it ----
function travelStreetClose() {
	$('#travel_street').css('display', 'none');
	$('#travel_street_frame').attr('src', 'about:blank');
	$('#travel_street_photo').removeAttr('src');
}

$(document).on('click', '#travel_street_close', travelStreetClose);
$(document).on('keyup', function(e) {
	if (e.key == 'Escape' && $('#travel_street').is(':visible')) { travelStreetClose(); }
});

// The nearest photo in growing rings. It comes back with a plain image URL, so it
// draws without the WebGL panorama that was showing black in the desktop engine.
function travelStreetNearest(lat, lon, token, done) {
	var spans = [0.0005, 0.002, 0.01];
	var i = 0;
	function attempt() {
		if (i >= spans.length) { done(null); return; }
		var d = spans[i++];
		var bbox = (lon - d).toFixed(6) + ',' + (lat - d).toFixed(6) + ',' + (lon + d).toFixed(6) + ',' + (lat + d).toFixed(6);
		$.ajax({
			url: 'https://graph.mapillary.com/images',
			data: { access_token: token, fields: 'id,thumb_2048_url,thumb_1024_url', bbox: bbox, limit: 1 },
			dataType: 'json',
			timeout: 8000,
			success: function(r) {
				var first = (r && r.data && r.data[0]) || null;
				if (first) { done(first); } else { attempt(); }
			},
			error: function() { done(null, 'error'); }
		});
	}
	attempt();
}

function travelStreetOpen(lat, lon) {
	var x = (lon + 180) / 360;
	var s = Math.sin(lat * Math.PI / 180);
	var y = 0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI);
	var embed = 'https://www.mapillary.com/embed?map_style=Mapillary%20streets'
		+ '&x=' + x.toFixed(7) + '&y=' + y.toFixed(7) + '&z=18';
	var token = ($('#travel_mapillary_token').val() || '').trim();
	var note = $('#travel_street_note');
	$('#travel_street_title').text(jawnosT('Street view') + ' · ' + lat.toFixed(5) + ', ' + lon.toFixed(5));
	$('#travel_street_photo').hide().removeAttr('src');
	$('#travel_street_frame').hide().attr('src', 'about:blank');
	$('#travel_street_gallery').hide().empty();
	$('#travel_street_photos').hide();
	$('#travel_street_pano').hide();
	$('#travel_street').css('display', 'flex');
	note.hide().text('');
	travelNearFetch(lat, lon, 'travel_street_near', 'travel_street_gallery');

	var showGallery = function() {
		$('#travel_street_photo').hide();
		$('#travel_street_frame').hide();
		$('#travel_street_gallery').css('display', 'grid');
		$('#travel_street_photos').hide();
	};
	if (!token) {
		note.text(jawnosT('No Mapillary token — the pictures below were taken by the house near here. A free Mapillary token (Configure → Plat → Maps) adds the nearest street-level photo.')).show();
		$('#travel_street_pano').attr('embed', embed).show();
		showGallery();
		return;
	}
	travelStreetNearest(lat, lon, token, function(photo, why) {
		if (!photo) {
			note.text(jawnosT(why === 'error' ? 'Mapillary could not be asked for the nearest photo.' : 'Mapillary returned no street-level photo near here — the token may also lack image access.')).show();
			$('#travel_street_pano').attr('embed', embed).show();
			showGallery();
			return;
		}
		var src = photo.thumb_2048_url || photo.thumb_1024_url || '';
		if (!src) { showGallery(); return; }
		$('#travel_street_photo').attr('src', src).show();
		$('#travel_street_gallery').hide();
		$('#travel_street_photos').show();
		$('#travel_street_pano').attr('embed', embed + '&image_key=' + encodeURIComponent(photo.id)).show();
	});
}

$(document).on('click', '#travel_street_pano', function() {
	var url = $(this).attr('embed') || '';
	if (!url) { return; }
	$('#travel_street_photo').hide();
	$('#travel_street_gallery').hide();
	$('#travel_street_frame').attr('src', url).show();
	$(this).hide();
	$('#travel_street_photos').show();
});

$(document).on('click', '#travel_street_photos', function() {
	$('#travel_street_photo').hide();
	$('#travel_street_frame').hide();
	$('#travel_street_gallery').css('display', 'grid');
	$(this).hide();
	$('#travel_street_pano').show();
});

// Fill the provider picker from the engine's own table, so the two cannot drift.
// The services are grouped by what they ask for: the free ones need nothing,
// the keyed ones want a key pasted, the rest want a whole tile URL.
function travelProviderFill() {
	var sel = $('.travel_provider');
	if (!sel.length || sel.attr('filled') == 'yes' || !window.jawnosMap) { return; }
	sel.attr('filled', 'yes');
	var engines = window.jawnosMap.providers;
	var labels = { free: 'Built in — no key needed', key: 'Needs your key', url: 'Needs a tile URL' };
	var holders = {};
	for (var key in engines) {
		var p = engines[key];
		var group = p.group || 'url';
		if (group === 'none') {
			$('<option></option>').attr('value', key).text(jawnosT(p.name)).appendTo(sel);
			continue;
		}
		if (!holders[group]) { holders[group] = $('<optgroup></optgroup>').attr('label', jawnosT(labels[group] || group)).appendTo(sel); }
		$('<option></option>').attr('value', key).text(jawnosT(p.name)).appendTo(holders[group]);
	}
	sel.val(sel.attr('provider') || 'none');
	travelProviderFields();
}

// The keys live in one place, Configure -> Plat -> Maps, and ride into the page as
// hidden inputs so the engine can build a keyed service's URL without a round trip.
function travelProviderKeys() {
var keys = {};
$('.travel_map_key').each(function() { keys[$(this).attr('provider')] = $(this).val(); });
return keys;
}

// Show only the box the chosen service actually needs, and say what the map is
// waiting for when it needs something the house does not have yet.
function travelProviderFields() {
var sel = $('.travel_provider');
var p = (window.jawnosMap && window.jawnosMap.providers) ? window.jawnosMap.providers[sel.val()] : null;
var needs = p && p.needs;
$('#travel_map_url_wrap').toggle(needs === 'url');
var status = $('#travel_map_status');
if (!status.length) { return; }
if (needs === 'key' && !travelProviderKeys()[sel.val()]) { status.text(jawnosT('set this service\'s key in Configure → Plat → Maps')); }
else if (needs === 'url' && !$.trim($('#travel_custom_url').val())) { status.text(jawnosT('paste the service\'s tile URL')); }
else { status.text(''); }
}

// ---- measured maps: a multi-select of the maps drawn on the canvas ----
function travelMapsRestore() {
var button = $('#travel_maps_button');
if (!button.length || button.attr('ready') == 'yes') { return; }
button.attr('ready', 'yes');
travelHiddenMaps = [];
	var saved = button.attr('hidden_maps');
if (saved) { try { travelHiddenMaps = JSON.parse(saved) || []; } catch (e) { travelHiddenMaps = []; } }
if (!(travelHiddenMaps instanceof Array)) { travelHiddenMaps = []; }
$('.travel_maps_check').each(function() { $(this).prop('checked', travelHiddenMaps.indexOf($(this).val()) < 0); });
travelMapsLabel();
}

function travelMapsLabel() {
var total = $('.travel_maps_row').length;
var shown = $('.travel_maps_check:checked').length;
var text = total && shown === total ? jawnosT('Maps: all') : (shown ? jawnosT('Maps: {0} of {1}', shown, total) : jawnosT('Maps: none'));
$('#travel_maps_button').text(text);
}

// Redraw from the last atlas answer: switching maps off never asks the server again.
function travelMapsApply() {
travelMapsLabel();
settingSetter({ 'app': 'travel', 'setting': 'hidden_maps', 'value': JSON.stringify(travelHiddenMaps) });
if (!travelMap || !travelAllMaps.length) { return; }
var shown = $.grep(travelAllMaps, function(m) { return m['guessed'] || travelHiddenMaps.indexOf(m['uuid']) < 0; });
travelMap.setMaps(shown);
travelMap.draw();
}

$(document).on('click', '#travel_maps_button', function(e) {
e.stopPropagation();
$('#travel_maps_menu').toggle();
});

$(document).on('click', '#travel_maps_menu', function(e) { e.stopPropagation(); });
$(document).on('click', function() { $('#travel_maps_menu').hide(); });

$(document).on('change', '.travel_maps_check', function() {
var uuid = $(this).val();
var i = travelHiddenMaps.indexOf(uuid);
if ($(this).prop('checked')) { if (i >= 0) { travelHiddenMaps.splice(i, 1); } }
else if (i < 0) { travelHiddenMaps.push(uuid); }
travelMapsApply();
});

$(document).on('click', '.travel_maps_all', function(e) {
e.preventDefault();
travelHiddenMaps = [];
$('.travel_maps_check').prop('checked', true);
travelMapsApply();
});

$(document).on('click', '.travel_maps_none', function(e) {
e.preventDefault();
travelHiddenMaps = [];
$('.travel_maps_row').each(function() { travelHiddenMaps.push($(this).attr('uuid')); });
$('.travel_maps_check').prop('checked', false);
travelMapsApply();
});

// a map's name brings it into view (and turns it back on if it was off)
$(document).on('click', '.travel_maps_frame', function() {
var row = $(this).closest('.travel_maps_row');
var uuid = row.attr('uuid');
travelAnchorMap = uuid;
settingSetter({ 'app': 'travel', 'setting': 'current_map', 'value': uuid });
var i = travelHiddenMaps.indexOf(uuid);
if (i >= 0) { travelHiddenMaps.splice(i, 1); row.find('.travel_maps_check').prop('checked', true); travelMapsApply(); }
travelPendingMap = uuid;
$('#travel_maps_menu').hide();
setTimeout(function() { travelViewer({ timestamp: Date.now() }); }, 200);
});

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
	// what the house photographed around where it is now: a bar along the top
	if (hasPos) { travelNearFetch(parseFloat(pos['latitude']), parseFloat(pos['longitude']), 'travel_near', null); }
	else { $('#travel_near').hide(); }

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

$(document).on('click', '.delete_travel_map', function() {
	var a = $(this);
	var row = a.closest('.travel_maps_row');
	var uuid = row.attr('uuid');
	var app_uuid = row.attr('app_uuid');
	var app = row.attr('app');
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
	travelProviderFields();
	if (travelMap) { travelMap.setProvider(value, $('#travel_custom_url').val(), travelProviderKeys()); }
});

$(document).on('change', '#travel_custom_url', function() {
	var value = $(this).val();
	settingSetter({ 'app': 'travel', 'setting': 'map_custom_url', 'value': value });
	travelProviderFields();
	if (travelMap) { travelMap.setProvider($('.travel_provider').val() || 'none', value, travelProviderKeys()); }
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