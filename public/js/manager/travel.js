/* [[js-split]]
   travel.js is part 1. The rest live in travel/ in name order:
     01_map_render_points.js - map render, plates, viewer, GPS and navigation
     02_maps_config_guess.js - delete map, providers, config, guess and site type
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
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
var travelBasePoints = [];   // the places and fixes the last render produced
var travelPlaceGroups = [];
var travelPlateList = [];    // home plates in the current view (lazy-loaded)
var travelPlatesCache = {};
var travelPlatesTimer;

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
	// a single tap asks for the pictures taken on the ground the map is showing
	travelMap.onMapClick(function(lat, lon) { travelNearShow(lat, lon); });
	// a still long press offers a small street-view preview of that ground
	travelMap.onLongPress(function(lat, lon, sx, sy) { travelStreetPreview(lat, lon, sx, sy); });
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
	// home plates are fetched for the ground on screen, after the view settles
	travelMap.onChange(function() {
		clearTimeout(travelPlatesTimer);
		travelPlatesTimer = setTimeout(travelPlatesLoad, 500);
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
var travelNearScopes = {};   // container -> the point and view bounds its set came from
var travelNearPreviewMax = 20;   // previews in the strip; Gallery still opens the whole set

function travelNearOpen(container, index) {
	var items = travelNearLists[container] || [];
	if (!items.length || typeof imageViewer !== 'function') { return; }
	var scope = travelNearScopes[container] || {};
	var near = { lat: scope.lat, lon: scope.lon };
	if (scope.bounds && scope.bounds.nw && scope.bounds.se) {
		near.nw_lat = scope.bounds.nw.lat; near.nw_lon = scope.bounds.nw.lon;
		near.se_lat = scope.bounds.se.lat; near.se_lon = scope.bounds.se.lon;
	}
	// the Gallery filters to the same ground server-side and pages through it, so
	// a view holding hundreds of pictures opens without a huge URL
	imageViewer({ near: near, target: items[index] ? items[index].f : undefined });
}

function travelNearRender(container, items, show_empty) {
	travelNearLists[container] = items;
	var box = $('#' + container);
	var strip = box.find('.travel_near_strip');
	strip.empty();
	var label = box.find('.travel_near_label');
	if (label.length) {
		label.text(items.length ? jawnosT('Nearby: {0}', items.length) : jawnosT('Nearby'));
		label.css({ cursor: items.length ? 'pointer' : 'default', textDecoration: items.length ? 'underline' : 'none' })
			.off('click').on('click', function() { if (items.length) { travelNearOpen(container, 0); } });
	}
	if (!items.length) {
		if (!show_empty) { box.hide(); return; }
		strip.html('<span style="font-size:11px;opacity:.7;">' + jawnosT('No pictures taken in this view') + '</span>');
		box.show();
		return;
	}
	var shown = items.slice(0, travelNearPreviewMax);
	$.each(shown, function(i, it) {
		$('<img>').addClass('travel_near_thumb').attr('src', it.thumb_url).attr('alt', it.label || '').attr('title', it.label || '')
			.css({ width: '52px', height: '52px', objectFit: 'cover', borderRadius: '5px', marginRight: '3px', cursor: 'pointer', verticalAlign: 'middle', background: '#222' })
			.on('click', function() { travelNearOpen(container, i); })
			.appendTo(strip);
	});
	if (items.length > shown.length) {
		$('<span></span>').addClass('travel_near_more').text(jawnosT('+{0} more', items.length - shown.length))
			.css({ fontSize: '11px', opacity: '.8', cursor: 'pointer', marginLeft: '6px', verticalAlign: 'middle' })
			.on('click', function() { travelNearOpen(container, 0); })
			.appendTo(strip);
	}
	box.show();
}

function travelNearGallery(container, items) {
	travelNearLists[container] = items;
	var grid = $('#' + container);
	grid.empty();
	if (!items.length) { grid.hide(); return; }
	var shown = items.slice(0, travelNearPreviewMax);
	$.each(shown, function(i, it) {
		$('<img>').addClass('travel_near_grid_thumb').attr('src', it.thumb_url).attr('alt', it.label || '').attr('title', it.label || '')
			.css({ width: '100%', height: '96px', objectFit: 'cover', borderRadius: '5px', cursor: 'pointer', background: '#222' })
			.on('click', function() { travelNearOpen(container, i); })
			.appendTo(grid);
	});
	if (items.length > shown.length) {
		$('<div></div>').addClass('travel_near_grid_more').text(jawnosT('+{0} more', items.length - shown.length))
			.css({ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '96px', borderRadius: '5px', cursor: 'pointer', background: '#222', color: '#ddd', fontSize: '12px' })
			.on('click', function() { travelNearOpen(container, 0); })
			.appendTo(grid);
	}
	grid.css('display', 'grid');
}

// The search area is the ground the map is showing, not a fixed circle: only the
// pictures taken inside the current view come back. The route returns the whole
// set (the Gallery opens all of them) and the strip previews the first 20.
function travelNearFetch(lat, lon, bounds, strip_id, gallery_id, show_empty, cb) {
	var data = { lat: lat, lon: lon, limit: 1000 };
	var bkey = '';
	if (bounds && bounds.nw && bounds.se) {
		data.nw_lat = bounds.nw.lat; data.nw_lon = bounds.nw.lon;
		data.se_lat = bounds.se.lat; data.se_lon = bounds.se.lon;
		bkey = [bounds.nw.lat, bounds.nw.lon, bounds.se.lat, bounds.se.lon].map(function(v) { return (+v).toFixed(4); }).join(',');
	}
	var key = lat.toFixed(4) + ',' + lon.toFixed(4) + '|' + bkey;
	var finish = function(items) {
		if (strip_id) { travelNearScopes[strip_id] = { lat: lat, lon: lon, bounds: bounds }; travelNearRender(strip_id, items, show_empty); }
		if (gallery_id) { travelNearScopes[gallery_id] = { lat: lat, lon: lon, bounds: bounds }; travelNearGallery(gallery_id, items); }
		if (cb) { cb(items); }
	};
	if (travelNearCache[key]) { finish(travelNearCache[key]); return; }
	$.ajax({
		url: '/manager/travel/nearby',
		type: 'GET',
		data: data,
		success: function(r) {
			var items = (r && r.items) || [];
			travelNearCache[key] = items;
			finish(items);
		},
		error: function() { finish([]); }
	});
}

// a single tap asks for the pictures taken on the ground the map is showing
function travelNearShow(lat, lon) {
	$('#travel_street_preview').hide();
	var bounds = travelMap ? travelMap.viewBounds() : null;
	travelNearFetch(lat, lon, bounds, 'travel_near', null, true);
}

// ---- street view: a long press shows a small preview; pressing it opens the view ----
var travelStreetPreviewAt = null;

function travelStreetPreviewPlace(card, sx, sy) {
	var t = $('#travel'), c = $('#travel_campus');
	if (!t.length || !c.length) { return; }
	var tr = t[0].getBoundingClientRect(), cr = c[0].getBoundingClientRect();
	var x = cr.left - tr.left + sx, y = cr.top - tr.top + sy;
	var w = card.outerWidth() || 210, h = card.outerHeight() || 150;
	x = Math.max(6, Math.min(t.width() - w - 6, x - w / 2));
	y = Math.max(6, Math.min(t.height() - h - 6, y - h - 10));
	card.css({ left: x, top: y });
}

function travelStreetPreview(lat, lon, sx, sy) {
	travelStreetPreviewAt = { lat: lat, lon: lon };
	var card = $('#travel_street_preview');
	$('#travel_street_preview_img').removeAttr('src').hide();
	$('#travel_street_preview_text').text(jawnosT('Street view · loading…'));
	travelStreetPreviewPlace(card, sx || 40, sy || 40);
	card.show();
	var mp = ($('#travel_mapillary_token').val() || '').trim();
	var g = ($('#travel_google_token').val() || '').trim();
	$('#travel_plate_form').hide();
	$('#travel_plate_app').val('');
	$('#travel_plate_apps').hide().empty();
	$('#travel_plate_status').text('');
	if (!mp && !g) {
		$('#travel_street_preview_text').text(jawnosT('Set a Mapillary or Google Street View key in Configure → Plat → Maps'));
		return;
	}
	travelStreetLookup(lat, lon, function(photo) {
		if (!travelStreetPreviewAt || travelStreetPreviewAt.lat != lat || travelStreetPreviewAt.lon != lon) { return; }
		if (!photo || !(photo.thumb_1024_url || photo.thumb_2048_url)) {
			$('#travel_street_preview_text').text(jawnosT('No street view here'));
			return;
		}
		$('#travel_street_preview_img').attr('src', photo.thumb_1024_url || photo.thumb_2048_url).show();
		$('#travel_street_preview_text').text(jawnosT('Street view · press to open'));
	});
}

$(document).on('click', '#travel_street_preview', function(e) {
	if ($(e.target).hasClass('travel_street_preview_close')) { return; }
	if ($(e.target).closest('#travel_plate_form, #travel_plate_open').length) { return; }
	var p = travelStreetPreviewAt;
	$(this).hide();
	if (p) { travelStreetOpen(p.lat, p.lon); }
});

$(document).on('click', '#travel_street_preview_close', function(e) {
	e.stopPropagation();
	travelStreetPreviewAt = null;
	$('#travel_street_preview').hide();
});

// ---- a plate set from the map: an app search, a radius, and an action ----
$(document).on('click', '#travel_plate_open', function(e) {
	e.stopPropagation();
	$('#travel_plate_form').toggle();
});

$(document).on('click', '#travel_plate_form', function(e) { e.stopPropagation(); });

var travelPlateSearch;
$(document).on('input', '#travel_plate_app', function() {
	var q = $.trim($(this).val());
	clearTimeout(travelPlateSearch);
	travelPlateSearch = setTimeout(function() {
		$.getJSON('/manager/apps/search', { q: q }, function(r) {
			var list = (r && r.apps) || [];
			var box = $('#travel_plate_apps').empty();
			if (!list.length) { box.hide(); return; }
			$.each(list, function(i, a) {
				$('<div></div>').text(a.name).attr('data-app', a.app)
					.css({ padding: '3px 6px', cursor: 'pointer', fontSize: '11px', color: '#ddd' })
					.on('click', function(e) {
						e.stopPropagation();
						$('#travel_plate_app').val(a.app);
						box.hide();
					})
					.appendTo(box);
			});
			box.show();
		});
	}, 200);
});

$(document).on('click', '#travel_plate_save', function(e) {
	e.stopPropagation();
	var p = travelStreetPreviewAt;
	if (!p) { return; }
	var app = $.trim($('#travel_plate_app').val());
	var radius = parseFloat($('#travel_plate_radius').val()) || 200;
	var action = $('#travel_plate_action').val() || 'start';
	var status = $('#travel_plate_status');
	if (!app) { status.text(jawnosT('choose an app')); return; }
	status.text(jawnosT('saving…'));
	$.ajax({
		url: '/manager/travel/plate',
		type: 'POST',
		data: { app: app, latitude: p.lat, longitude: p.lon, radius: radius, action: action },
		success: function(r) {
			if (!r || r.error) { status.text((r && r.error) || jawnosT('could not save')); return; }
			status.text(jawnosT('saved for {0}', r.name || app));
			$('#travel_plate_form').hide();
		},
		error: function() { status.text(jawnosT('could not save')); }
	});
});

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

// The nearest Mapillary photo, by its radius search: the API picks the best image
// within 50 m (proximity, recency, and 360 preference). It comes back as a plain
// image URL, so it draws without the WebGL panorama.
function travelStreetNearest(lat, lon, token, done) {
	$.ajax({
		url: 'https://graph.mapillary.com/images',
		data: { access_token: token, fields: 'id,thumb_2048_url,thumb_1024_url', lat: lat, lng: lon, radius: 50, limit: 1 },
		dataType: 'json',
		timeout: 8000,
		success: function(r) {
			var first = (r && r.data && r.data[0]) || null;
			done(first || null);
		},
		error: function() { done(null, 'error'); }
	});
}

// Google's Street View Static API: the same idea, a still image, no WebGL. The
// metadata call answers whether Google has a photo of that ground at all.
function travelStreetGoogle(lat, lon, token, done) {
	var loc = (+lat).toFixed(6) + ',' + (+lon).toFixed(6);
	$.ajax({
		url: 'https://maps.googleapis.com/maps/api/streetview/metadata',
		data: { location: loc, key: token },
		dataType: 'json',
		timeout: 8000,
		success: function(r) {
			if (!r || r.status !== 'OK') { done(null); return; }
			var key = encodeURIComponent(token);
			var still = 'https://maps.googleapis.com/maps/api/streetview?size=640x480&location=' + loc + '&key=' + key;
			done({ id: '', google: 1, thumb_1024_url: still, thumb_2048_url: still });
		},
		error: function() { done(null); }
	});
}

// Mapillary first, then Google when its key is saved.
function travelStreetLookup(lat, lon, done) {
	var mp = ($('#travel_mapillary_token').val() || '').trim();
	var g = ($('#travel_google_token').val() || '').trim();
	var tryGoogle = function() {
		if (!g) { done(null); return; }
		travelStreetGoogle(lat, lon, g, done);
	};
	if (!mp) { tryGoogle(); return; }
	travelStreetNearest(lat, lon, mp, function(photo) {
		if (photo) { done(photo); return; }
		tryGoogle();
	});
}

function travelStreetOpen(lat, lon) {
	var x = (lon + 180) / 360;
	var s = Math.sin(lat * Math.PI / 180);
	var y = 0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI);
	var embed = 'https://www.mapillary.com/embed?map_style=Mapillary%20streets'
		+ '&x=' + x.toFixed(7) + '&y=' + y.toFixed(7) + '&z=18';
	var token = ($('#travel_mapillary_token').val() || '').trim();
	var google = ($('#travel_google_token').val() || '').trim();
	var note = $('#travel_street_note');
	$('#travel_street_preview').hide();
	$('#travel_street_title').text(jawnosT('Street view') + ' · ' + lat.toFixed(5) + ', ' + lon.toFixed(5));
	$('#travel_street_photo').hide().removeAttr('src');
	$('#travel_street_frame').hide().attr('src', 'about:blank');
	$('#travel_street_gallery').hide().empty();
	$('#travel_street_photos').hide();
	$('#travel_street_pano').hide();
	$('#travel_street_credit').text('');
	$('#travel_street').css('display', 'flex');
	note.hide().text('');
	var nearBounds = travelMap ? travelMap.viewBounds() : null;
	travelNearFetch(lat, lon, nearBounds, 'travel_street_near', 'travel_street_gallery', false);

	var showGallery = function() {
		$('#travel_street_photo').hide();
		$('#travel_street_frame').hide();
		$('#travel_street_gallery').css('display', 'grid');
		$('#travel_street_photos').hide();
	};
	if (!token && !google) {
		note.text(jawnosT('No street view key — the pictures below were taken by the house near here. A Mapillary or Google Street View key (Configure → Plat → Maps) adds the street-level photo.')).show();
		showGallery();
		return;
	}
	travelStreetLookup(lat, lon, function(photo) {
		if (!photo) {
			note.text(jawnosT(token ? 'No street-level photo near here.' : 'No Google Street View photo near here.')).show();
			if (token) { $('#travel_street_pano').attr('embed', embed).show(); }
			showGallery();
			return;
		}
		var src = photo.thumb_2048_url || photo.thumb_1024_url || '';
		if (!src) { showGallery(); return; }
		$('#travel_street_photo').attr('src', src).show();
		$('#travel_street_gallery').hide();
		$('#travel_street_photos').show();
		$('#travel_street_credit').text(photo.google ? jawnosT('© Google') : jawnosT('© Mapillary contributors, CC BY-SA'));
		if (!photo.google) { $('#travel_street_pano').attr('embed', embed + '&image_key=' + encodeURIComponent(photo.id)).show(); }
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

