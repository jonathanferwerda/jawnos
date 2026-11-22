// ---- the home-plate flag map ------------------------------------------------
// One canvas per panel: an app's Home Plate, or one device's plate in Me. The
// flag on the toolbar can be dragged onto the map or pressed then clicked; the
// flag on the map drags the whole area flag. Double-click places the active
// shape (or a circle), double-click on a shape removes it, and the flag's menu
// deletes or duplicates the flag. A pattern flag holds cached branches from an
// OSM brand lookup, plus any branch placed by hand.

var homePlateEditors = {};
var homePlateGroundCache = null;

function homePlateT(text) {
	return (typeof window.jawnosT === 'function') ? window.jawnosT(text) : text;
}

function homePlateMetres(a, b) {
	if (typeof jawnosMarkerMetres === 'function') { return jawnosMarkerMetres(a, b); }
	var mid = ((a.lat + b.lat) / 2) * Math.PI / 180;
	var dLat = (a.lat - b.lat) * 111194.9;
	var dLon = (a.lon - b.lon) * 111194.9 * Math.cos(mid);
	return Math.sqrt((dLat * dLat) + (dLon * dLon));
}

function homePlateLocal(lat0, lon0, lat, lon) {
	var mid = ((lat0 + lat) / 2) * Math.PI / 180;
	return { x: (lon - lon0) * 111194.9 * Math.cos(mid), y: (lat - lat0) * 111194.9 };
}

function homePlateSegment(px, py, ax, ay, bx, by) {
	var dx = bx - ax, dy = by - ay;
	var len2 = (dx * dx) + (dy * dy);
	var t = len2 > 0 ? (((px - ax) * dx) + ((py - ay) * dy)) / len2 : 0;
	t = Math.max(0, Math.min(1, t));
	var x = ax + (t * dx), y = ay + (t * dy);
	return Math.sqrt(((px - x) * (px - x)) + ((py - y) * (py - y)));
}

function homePlateAreaAnchor(area) {
	if (!area) { return null; }
	var shape = area.shape || '';
	if (shape === 'circle' && isFinite(+area.lat) && isFinite(+area.lon)) {
		return { lat: +area.lat, lon: +area.lon };
	}
	if (shape === 'box' && area.nw && area.se) {
		return { lat: (+area.nw.lat + +area.se.lat) / 2, lon: (+area.nw.lon + +area.se.lon) / 2 };
	}
	if ((shape === 'path' || shape === 'polygon') && area.points && area.points.length) {
		return { lat: +area.points[0].lat, lon: +area.points[0].lon };
	}
	if (isFinite(+area.lat) && isFinite(+area.lon)) { return { lat: +area.lat, lon: +area.lon }; }
	return null;
}

function homePlateAreaReach(area) {
	if (!area) { return 0; }
	var shape = area.shape || '';
	if (shape === 'circle') { return +area.radius_m || 200; }
	if (shape === 'path') { return (+area.width_m || 30) / 2; }
	if (shape === 'box' && area.nw && area.se) { return homePlateMetres(area.nw, area.se) / 2; }
	if (shape === 'polygon' && area.points && area.points.length) {
		var minLat = +area.points[0].lat, maxLat = minLat;
		var minLon = +area.points[0].lon, maxLon = minLon;
		$.each(area.points, function(i, p) {
			minLat = Math.min(minLat, +p.lat); maxLat = Math.max(maxLat, +p.lat);
			minLon = Math.min(minLon, +p.lon); maxLon = Math.max(maxLon, +p.lon);
		});
		return homePlateMetres({ lat: minLat, lon: minLon }, { lat: maxLat, lon: maxLon }) / 2;
	}
	return 0;
}

function homePlateAreaWidth(area) {
	if (!area) { return 0; }
	if ((area.shape || '') === 'circle') { return +area.radius_m || 200; }
	if ((area.shape || '') === 'path') { return +area.width_m || 30; }
	return 0;
}

function homePlateAreaEntries(plate) {
	var out = [];
	if (!plate) { return out; }
	$.each(plate.areas || [], function(i, area) {
		if (area && typeof area === 'object') { out.push({ plate: plate, area: area, index: i }); }
	});
	$.each(plate.branches || [], function(i, branch) {
		$.each((branch && branch.areas) || [], function(j, area) {
			if (area && typeof area === 'object') { out.push({ plate: plate, branch: branch, area: area, index: j }); }
		});
	});
	if (!out.length && (plate.kind || '') !== 'pattern' && isFinite(+plate.latitude) && isFinite(+plate.longitude)) {
		var radius = +plate.radius_m || ((+plate.distance || 0.2) * 1000) || 200;
		out.push({ plate: plate, area: { shape: 'circle', lat: +plate.latitude, lon: +plate.longitude, radius_m: radius }, index: 0, synthetic: true });
	}
	return out;
}

function homePlateAreas(plate) {
	return $.map(homePlateAreaEntries(plate), function(entry) { return entry.area; });
}

function homePlateAnchor(plate) {
	if (!plate) { return null; }
	if ((plate.kind || '') === 'pattern' && plate.match && plate.match.region
		&& isFinite(+plate.match.region.lat) && isFinite(+plate.match.region.lon)) {
		return { lat: +plate.match.region.lat, lon: +plate.match.region.lon };
	}
	var entries = homePlateAreaEntries(plate);
	if (entries.length) { return homePlateAreaAnchor(entries[0].area); }
	if (isFinite(+plate.latitude) && isFinite(+plate.longitude)) { return { lat: +plate.latitude, lon: +plate.longitude }; }
	return null;
}

function homePlateMirror(plate) {
	if (!plate) { return; }
	plate.kind = plate.kind || 'area';
	var entries = homePlateAreaEntries(plate);
	if (!entries.length) {
		// No ground left: clear the mirrored point as well, or the server would
		// read a legacy circle back out of it.
		delete plate.latitude;
		delete plate.longitude;
		delete plate.distance;
		return;
	}
	var anchor = homePlateAreaAnchor(entries[0].area);
	if (anchor) {
		plate.latitude = +(+anchor.lat).toFixed(7);
		plate.longitude = +(+anchor.lon).toFixed(7);
	}
	var reach = 0;
	$.each(entries, function(i, entry) { reach = Math.max(reach, homePlateAreaReach(entry.area)); });
	if (reach > 0) { plate.distance = (reach / 1000).toFixed(3); }
}

function homePlateAreaContains(area, lat, lon) {
	if (!area) { return false; }
	var shape = area.shape || '';
	if (shape === 'circle') {
		return homePlateMetres({ lat: +area.lat, lon: +area.lon }, { lat: lat, lon: lon }) <= (+area.radius_m || 200);
	}
	if (shape === 'box' && area.nw && area.se) {
		var nlat = +area.nw.lat, slat = +area.se.lat, nlon = +area.nw.lon, slon = +area.se.lon;
		return lat <= Math.max(nlat, slat) && lat >= Math.min(nlat, slat)
			&& lon >= Math.min(nlon, slon) && lon <= Math.max(nlon, slon);
	}
	var points = area.points || [];
	if (shape === 'path' && points.length) {
		var half = (+area.width_m || 30) / 2;
		var lat0 = +points[0].lat, lon0 = +points[0].lon;
		var p = homePlateLocal(lat0, lon0, lat, lon);
		if (points.length === 1) { return Math.sqrt((p.x * p.x) + (p.y * p.y)) <= half; }
		for (var i = 1; i < points.length; i++) {
			var a = homePlateLocal(lat0, lon0, +points[i - 1].lat, +points[i - 1].lon);
			var b = homePlateLocal(lat0, lon0, +points[i].lat, +points[i].lon);
			if (homePlateSegment(p.x, p.y, a.x, a.y, b.x, b.y) <= half) { return true; }
		}
		return false;
	}
	if (shape === 'polygon' && points.length >= 3) {
		var lat1 = +points[0].lat, lon1 = +points[0].lon;
		var q = homePlateLocal(lat1, lon1, lat, lon);
		var inside = false;
		for (var k = 0, j = points.length - 1; k < points.length; j = k++) {
			var c = homePlateLocal(lat1, lon1, +points[k].lat, +points[k].lon);
			var d = homePlateLocal(lat1, lon1, +points[j].lat, +points[j].lon);
			if (((c.y > q.y) !== (d.y > q.y)) && (q.x < ((d.x - c.x) * (q.y - c.y) / (d.y - c.y)) + c.x)) { inside = !inside; }
		}
		return inside;
	}
	return false;
}

function homePlateAreaAt(st, lat, lon) {
	var plate = homePlateSelectedPlate(st);
	if (!plate) { return null; }
	var entries = homePlateAreaEntries(plate);
	for (var i = 0; i < entries.length; i++) {
		if (homePlateAreaContains(entries[i].area, lat, lon)) { return entries[i]; }
	}
	return null;
}

function homePlateTranslateArea(area, dlat, dlon) {
	if (!area) { return; }
	var shape = area.shape || '';
	if (shape === 'circle') { area.lat = +area.lat + dlat; area.lon = +area.lon + dlon; return; }
	if (shape === 'box' && area.nw && area.se) {
		area.nw.lat = +area.nw.lat + dlat; area.nw.lon = +area.nw.lon + dlon;
		area.se.lat = +area.se.lat + dlat; area.se.lon = +area.se.lon + dlon;
		return;
	}
	$.each(area.points || [], function(i, p) { p.lat = +p.lat + dlat; p.lon = +p.lon + dlon; });
}

function homePlateTranslate(plate, dlat, dlon) {
	if (!plate) { return; }
	$.each(plate.areas || [], function(i, area) { homePlateTranslateArea(area, dlat, dlon); });
	$.each(plate.branches || [], function(i, branch) {
		if (!branch) { return; }
		if (isFinite(+branch.latitude)) { branch.latitude = +branch.latitude + dlat; }
		if (isFinite(+branch.longitude)) { branch.longitude = +branch.longitude + dlon; }
		$.each(branch.areas || [], function(j, area) { homePlateTranslateArea(area, dlat, dlon); });
	});
	if (!(plate.areas || []).length && isFinite(+plate.latitude)) {
		plate.latitude = +plate.latitude + dlat;
		plate.longitude = +plate.longitude + dlon;
	}
	homePlateMirror(plate);
}

function homePlateKey($editor) {
	return $editor.attr('editor') || (($editor.attr('app') || '') + '_' + ($editor.attr('device') || 'app'));
}

function homePlateReadData($editor) {
	var raw = $editor.find('script.home_plate_data').first().text() || '{}';
	try { return JSON.parse(raw) || {}; } catch (e) { return {}; }
}

function homePlateState($editor) {
	var key = homePlateKey($editor);
	var data = homePlateReadData($editor);
	var st = homePlateEditors[key];
	if (!st) {
		st = {
			key: key, editor: $editor,
			app: data.app || $editor.attr('app') || '',
			device: data.device || $editor.attr('device') || '',
			base: (data.base && typeof data.base === 'object') ? data.base : {},
			flags: (data.flags && data.flags.length) ? data.flags : [],
			selected: '', area: null, tool: '', pending: null, trace: null,
			flagArmed: false, branchArmed: false, map: null, width: 200, dirty: false,
			ground: null, branchResults: null, basemapAsked: false, basemapPending: false
		};
		homePlateEditors[key] = st;
	}
	else {
		st.editor = $editor;
	}
	return st;
}

function homePlateForApp(app) {
	var found = null;
	$.each(homePlateEditors, function(k, st) {
		if (st.app === app && !st.device) { found = st; return false; }
	});
	return found;
}

function homePlateFlagFor(st, uuid) {
	var found = null;
	$.each(st.flags || [], function(i, flag) {
		if ((flag.uuid || '') === uuid) { found = flag; return false; }
	});
	return found;
}

function homePlateSelectedPlate(st) {
	if (!st) { return null; }
	return st.selected ? homePlateFlagFor(st, st.selected) : st.base;
}

function homePlateClickEditor(el) {
	return $(el).closest('.home_plate_editor');
}

function homePlateStatus(st, text) {
	if (st && st.editor) { st.editor.find('.home_plate_editor_status').first().text(text || ''); }
}

function homePlateMapStatus(st, text) {
	if (st && st.editor) { st.editor.find('.home_plate_map_status').first().text(text || ''); }
}

function homePlatePatternStatus(st, text) {
	if (st && st.editor) { st.editor.find('.home_plate_pattern_status').first().text(text || ''); }
}

function homePlateInitAll(root) {
	var $root = root ? $(root) : $(document);
	var $editors = $root.find('.home_plate_editor');
	if ($root.is('.home_plate_editor')) { $editors = $editors.add($root); }
	$editors.each(function() {
		var $editor = $(this);
		if (!$editor.is(':visible') || !$editor.find('.home_plate_map_wrap').width()) { return; }
		var st = homePlateEditors[homePlateKey($editor)];
		if (st && st.map && st.map.canvas !== $editor.find('canvas.home_plate_map')[0]) {
			homePlateReload($editor);
			return;
		}
		homePlateInit($editor);
	});
}

function homePlateReload($editor) {
	if (!$editor || !$editor.length) { return; }
	var key = homePlateKey($editor);
	var data = homePlateReadData($editor);
	var st = homePlateEditors[key];
	if (!st) { return homePlateInit($editor); }
	st.editor = $editor;
	st.base = (data.base && typeof data.base === 'object') ? data.base : {};
	st.flags = (data.flags && data.flags.length) ? data.flags : [];
	if (st.selected && !homePlateFlagFor(st, st.selected)) { st.selected = ''; st.area = null; }
	var canvas = $editor.find('canvas.home_plate_map')[0];
	if (st.map && st.map.canvas !== canvas) {
		if (typeof st.map.destroy === 'function') { try { st.map.destroy(); } catch (e) {} }
		st.map = null;
	}
	homePlateInit($editor);
	homePlateBuildSelector(st);
	homePlateBuildFlag(st);
	homePlateSummaries(st);
	homePlatePatternPanel(st);
	if (st.map) { st.map.draw(); }
}

// The Travel basemap loader is in the lazy travel chunk, and a Configure page
// never opens Travel. On a fresh session the loader is absent, the house
// provider has no ground, and the canvas stays blank - the session where the
// map did appear had already opened Travel. Ask for the chunk, then build with
// the vector block; if it does not arrive, build anyway and let
// homePlateLoadGround fall back to a tile provider.
function homePlateBasemapReady() {
	return typeof window.travelBasemapLoad === 'function' && typeof window.travelBasemapStyle === 'function';
}

function homePlateInit($editor) {
	if (!$editor || !$editor.length) { return; }
	var st = homePlateState($editor);
	var canvas = $editor.find('canvas.home_plate_map')[0];
	if (!canvas || !window.jawnosMap) { return; }
	if (st.map && st.map.canvas === canvas) { return; }
	if (st.map && typeof st.map.destroy === 'function') { try { st.map.destroy(); } catch (e) {} }
	var anchor = homePlateAnchor(homePlateSelectedPlate(st));
	var start = anchor || homePlateHere() || { lat: 43.0, lon: -81.94 };
	if (!homePlateBasemapReady()) {
		if (st.basemapPending) { return; }
		if (!st.basemapAsked && typeof window.jawnosLoadApp === 'function') {
			st.basemapAsked = true;
			st.basemapPending = true;
			var built = false;
			var build = function() {
				if (built) { return; }
				built = true;
				st.basemapPending = false;
				homePlateInit($editor);
			};
			homePlateMapStatus(st, homePlateT('Loading the map...'));
			window.jawnosLoadApp('travel', build);
			setTimeout(build, 10000);
			return;
		}
	}
	// Travel draws its ground with the house's own vector basemap, and the engine
	// only paints that layer when create() is handed the loader. Without it the
	// `house` provider has no ground and the canvas stays blank, so pass the same
	// vector block Travel passes. A page without the loader falls back to a tile
	// provider instead of an empty map (see homePlateLoadGround).
	var mapOpts = {
		lat: start.lat, lon: start.lon, z: 16,
		width: function() { return $editor.find('.home_plate_map_wrap').width() || 640; },
		height: function() { return 360; }
	};
	if (typeof window.travelBasemapLoad === 'function' && typeof window.travelBasemapStyle === 'function') {
		mapOpts.vector = {
			load: function(done) { window.travelBasemapLoad(done); },
			register: function() { if (typeof window.travelBasemapRegister === 'function') { window.travelBasemapRegister(); } },
			maxZoom: function(url, done) { if (typeof window.travelBasemapMaxZoom === 'function') { window.travelBasemapMaxZoom(url, done); } },
			style: function(maxzoom) { return window.travelBasemapStyle(maxzoom); },
			url: '/manager/travel/basemap'
		};
	}
	st.map = window.jawnosMap.create(canvas.id, mapOpts);
	st.map.onDraw(function() { homePlateDraw(st); });
	st.map.onMapClick(function(lat, lon) { homePlateMapClick(st, lat, lon); });
	st.map.onMapDoubleClick(function(lat, lon) { homePlateMapDouble(st, lat, lon); });
	st.editor = $editor;
	homePlateLoadGround(st);
	homePlateBuildSelector(st);
	homePlateBuildFlag(st);
	homePlateSummaries(st);
	homePlatePatternPanel(st);
	st.map.draw();
}

function homePlateHere() {
	var here = homePlateGroundCache && homePlateGroundCache.here;
	if (here && isFinite(+here.latitude) && isFinite(+here.longitude)) {
		return { lat: +here.latitude, lon: +here.longitude };
	}
	if (here && isFinite(+here.lat) && isFinite(+here.lon)) { return { lat: +here.lat, lon: +here.lon }; }
	return null;
}

function homePlateLoadGround(st) {
	var apply = function(g) {
		if (!st.map) { return; }
		st.ground = g || {};
		var provider = (g && g.provider) || 'osm';
		if (provider === 'none' || provider === 'custom' || provider === 'lambton') { provider = 'osm'; }
		if (provider === 'house' && typeof window.travelBasemapLoad !== 'function') { provider = 'osm'; }
		st.map.setProvider(provider, (g && g.custom_url) || '', (g && g.keys) || {});
		st.map.setMaps((g && g.maps) || []);
		homePlateBuildProvider(st);
		homePlateMapStatus(st, '');
		var anchor = homePlateAnchor(homePlateSelectedPlate(st));
		if (anchor) { st.map.focusOn(anchor.lat, anchor.lon, 0.006); }
		st.map.draw();
	};
	if (homePlateGroundCache) { apply(homePlateGroundCache); return; }
	$.ajax({ url: '/manager/travel/continent', type: 'GET', dataType: 'json' })
		.done(function(g) { homePlateGroundCache = g || {}; apply(homePlateGroundCache); })
		.fail(function() { homePlateGroundCache = {}; apply(homePlateGroundCache); });
}

function homePlateBuildProvider(st) {
	var sel = st.editor.find('.home_plate_provider').first();
	if (!sel.length || !window.jawnosMap) { return; }
	var providers = window.jawnosMap.providers || {};
	var labels = { free: 'Free', key: 'Needs a key', url: 'Needs a URL', house: 'House map', none: 'None' };
	var groups = {};
	sel.empty();
	$.each(providers, function(k, p) {
		if (k === 'custom' || k === 'lambton') { return; }
		if (k === 'house' && typeof window.travelBasemapLoad !== 'function') { return; }
		var group = p.group || 'free';
		if (!groups[group]) { groups[group] = $('<optgroup>').attr('label', labels[group] || group).appendTo(sel); }
		$('<option>').val(k).text(p.name || k).appendTo(groups[group]);
	});
	var current = (st.ground && st.ground.provider) || 'osm';
	if (!providers[current] || current === 'custom' || current === 'lambton') { current = 'osm'; }
	if (current === 'house' && typeof window.travelBasemapLoad !== 'function') { current = 'osm'; }
	sel.val(current);
}

function homePlateFlagLabel(flag) {
	if (!flag) { return homePlateT('Flag'); }
	if (flag.name) { return flag.name; }
	var bits = [];
	if ((flag.kind || '') === 'pattern') { bits.push(homePlateT('pattern')); }
	var entries = homePlateAreaEntries(flag);
	if (entries.length) { bits.push(entries.length + ' ' + homePlateT(entries.length === 1 ? 'area' : 'areas')); }
	if (flag.action) { bits.push(flag.action); }
	if (!bits.length) { bits.push((flag.uuid || '').slice(0, 8)); }
	return bits.join(' · ');
}

function homePlateBuildSelector(st) {
	var sel = st.editor.find('.home_plate_flag_select').first();
	if (!sel.length) { return; }
	sel.empty();
	$('<option>').val('').text(homePlateT('Default place')).appendTo(sel);
	$.each(st.flags || [], function(i, flag) {
		$('<option>').val(flag.uuid || '').text(homePlateFlagLabel(flag)).appendTo(sel);
	});
	sel.val(st.selected || '');
}

function homePlateBuildFlag(st) {
	var marker = st.editor.find('.home_plate_flag_marker').first();
	if (!marker.length) { return; }
	var anchor = homePlateAnchor(homePlateSelectedPlate(st));
	if (!anchor || !st.map) { marker.css('display', 'none'); return; }
	marker.css('display', 'block');
	homePlatePlaceFlag(st);
}

function homePlatePlaceFlag(st) {
	if (!st || !st.map) { return; }
	var marker = st.editor.find('.home_plate_flag_marker').first();
	var anchor = homePlateAnchor(homePlateSelectedPlate(st));
	if (!marker.length || !anchor) { if (marker.length) { marker.css('display', 'none'); } return; }
	var s = st.map.project(anchor.lat, anchor.lon);
	marker.css({ display: 'block', left: s[0] + 'px', top: s[1] + 'px' });
}

function homePlateSummary(plate) {
	if (!plate) { return homePlateT('No area yet'); }
	if ((plate.kind || '') === 'pattern') {
		var branches = (plate.branches || []).length;
		return homePlateT('pattern') + ' · ' + branches + ' ' + homePlateT(branches === 1 ? 'branch' : 'branches');
	}
	var entries = homePlateAreaEntries(plate);
	if (!entries.length) { return homePlateT('No area yet'); }
	var circles = 0, boxes = 0, paths = 0, polygons = 0, radius = 0, width = 0;
	$.each(entries, function(i, entry) {
		var shape = entry.area.shape || '';
		if (shape === 'circle') { circles++; radius = Math.max(radius, +entry.area.radius_m || 200); }
		else if (shape === 'box') { boxes++; }
		else if (shape === 'path') { paths++; width = Math.max(width, +entry.area.width_m || 30); }
		else if (shape === 'polygon') { polygons++; }
	});
	var bits = [];
	if (circles) { bits.push(homePlateT('circle') + ' ' + radius + ' m'); }
	if (paths) { bits.push(homePlateT('path') + ' ' + width + ' m'); }
	if (polygons) { bits.push(homePlateT('polygon')); }
	if (boxes) { bits.push(homePlateT('box')); }
	return entries.length + ' ' + homePlateT(entries.length === 1 ? 'area' : 'areas') + (bits.length ? ' · ' + bits.join(' · ') : '');
}

function homePlateSummaries(st) {
	if (!st || !st.editor) { return; }
	var $root = st.editor.closest('.home_plate_configuration');
	if (!$root.length) { $root = st.editor; }
	$root.find('.home_plate_summary').each(function() {
		var key = $(this).attr('summary');
		var plate = (key === 'base') ? st.base : homePlateFlagFor(st, key);
		$(this).text(homePlateSummary(plate));
	});
}

function homePlatePatternPanel(st) {
	var panel = st.editor.find('.home_plate_pattern_panel').first();
	if (!panel.length) { return; }
	var plate = homePlateSelectedPlate(st);
	var shown = plate && (plate.kind || '') === 'pattern';
	panel.css('display', shown ? 'block' : 'none');
	if (!shown) { return; }
	plate.match = plate.match || {};
	plate.match.region = plate.match.region || { lat: 0, lon: 0, radius_m: 50000 };
	panel.find('.home_plate_brand').val(plate.match.brand || '');
	panel.find('.home_plate_pattern_radius').val(Math.round((+plate.match.region.radius_m || 50000) / 1000));
	homePlateRenderBranches(st, plate);
	if (st.branchResults) { homePlateRenderBranchResults(st); }
}

function homePlateRenderBranches(st, plate) {
	var list = st.editor.find('.home_plate_branch_list').first();
	if (!list.length) { return; }
	list.empty();
	$.each(plate.branches || [], function(i, b) {
		var row = $('<div>').css({ fontSize: '12px', marginTop: '2px' });
		$('<span>').text((b.name || homePlateT('Branch')) + ' (' + (+b.latitude).toFixed(5) + ', ' + (+b.longitude).toFixed(5) + ')').appendTo(row);
		$('<button type="button" class="home_plate_branch_delete"></button>')
			.attr('branch', i).text(homePlateT('Delete')).css({ marginLeft: '6px' }).appendTo(row);
		row.appendTo(list);
	});
	if (!(plate.branches || []).length) {
		list.append($('<div>').css({ fontSize: '12px', opacity: '.7' }).text(homePlateT('No branches yet.')));
	}
}

function homePlateRenderBranchResults(st) {
	var list = st.editor.find('.home_plate_branch_list').first();
	if (!list.length) { return; }
	var results = st.branchResults || [];
	if (!results.length) {
		list.append($('<div>').css({ fontSize: '12px', opacity: '.7' }).text(homePlateT('No branches found.')));
		return;
	}
	var box = $('<div>').css({ marginTop: '4px' });
	$.each(results, function(i, b) {
		var row = $('<label>').css({ display: 'block', fontSize: '12px' });
		$('<input type="checkbox">').attr('value', i).prop('checked', true).appendTo(row);
		row.append(document.createTextNode(' ' + (b.name || b.brand || '') + ' (' + (+b.lat).toFixed(5) + ', ' + (+b.lon).toFixed(5) + ')'));
		row.appendTo(box);
	});
	$('<button type="button" class="home_plate_add_checked"></button>').text(homePlateT('Add checked branches')).appendTo(box);
	box.appendTo(list);
}

function homePlateDraw(st) {
	if (!st || !st.map) { return; }
	var ctx = st.map.canvas.getContext('2d');
	$.each(st.flags || [], function(i, flag) {
		if (flag.uuid && flag.uuid === st.selected) { return; }
		homePlateDrawPlate(st, ctx, flag, { stroke: 'rgba(90,90,90,0.45)', fill: 'rgba(90,90,90,0.08)', line: 1 });
	});
	if (st.selected) {
		homePlateDrawPlate(st, ctx, st.base, { stroke: 'rgba(111,127,143,0.7)', fill: 'rgba(111,127,143,0.10)', line: 1, dash: [4, 4] });
	}
	else {
		homePlateDrawPlate(st, ctx, st.base, { stroke: '#6f7f8f', fill: 'rgba(111,127,143,0.14)', line: 2, dash: [5, 4] }, true);
	}
	var selected = homePlateSelectedPlate(st);
	if (selected && st.selected) {
		homePlateDrawPlate(st, ctx, selected, { stroke: '#c0392b', fill: 'rgba(192,57,43,0.14)', line: 2 }, true);
	}
	if (st.pending && st.pending.points) { homePlateDrawLine(st, ctx, st.pending.points, '#c0392b'); }
	if (st.trace && st.trace.points) { homePlateDrawLine(st, ctx, st.trace.points, '#2f6f9f'); }
	homePlatePlaceFlag(st);
}

function homePlateDrawPlate(st, ctx, plate, opts, highlight) {
	var entries = homePlateAreaEntries(plate);
	$.each(entries, function(i, entry) {
		var o = opts;
		if (highlight && st.area === i) { o = $.extend({}, opts, { stroke: '#f39c12', line: 3 }); }
		jawnosPlateAreaDraw(ctx, st.map, entry.area, o);
	});
}

function homePlateDrawLine(st, ctx, points, colour) {
	if (!points || points.length < 2) { return; }
	ctx.save();
	ctx.strokeStyle = colour;
	ctx.lineWidth = 2;
	ctx.setLineDash([6, 4]);
	ctx.beginPath();
	$.each(points, function(i, p) {
		var s = st.map.project(+p.lat, +p.lon);
		if (i === 0) { ctx.moveTo(s[0], s[1]); } else { ctx.lineTo(s[0], s[1]); }
	});
	ctx.stroke();
	ctx.restore();
}

function homePlateMapClick(st, lat, lon) {
	if (!st || !st.map) { return; }
	if (st.flagArmed) { st.flagArmed = false; homePlateNewFlag(st, lat, lon); return; }
	if (st.branchArmed) { st.branchArmed = false; homePlateAddBranch(st, lat, lon); return; }
	var hit = homePlateAreaAt(st, lat, lon);
	if (hit) { st.area = hit.index; homePlateSyncWidth(st); st.map.draw(); }
}

function homePlateMapDouble(st, lat, lon) {
	if (!st || !st.map) { return; }
	if (st.flagArmed) { st.flagArmed = false; homePlateNewFlag(st, lat, lon); return; }
	if (st.branchArmed) { st.branchArmed = false; homePlateAddBranch(st, lat, lon); return; }
	if (st.tool === 'trace') {
		st.trace = st.trace || { points: [] };
		st.trace.points.push({ lat: lat, lon: lon });
		homePlateMapStatus(st, homePlateT('Double-click all the way along the water, then Finish.'));
		st.map.draw();
		return;
	}
	if (st.tool === 'circle') {
		homePlateAddArea(st, { shape: 'circle', lat: lat, lon: lon, radius_m: st.width || 200 });
		return;
	}
	if (st.tool === 'box') {
		if (!st.pending || st.pending.shape !== 'box' || !st.pending.start) {
			st.pending = { shape: 'box', start: { lat: lat, lon: lon } };
			homePlateMapStatus(st, homePlateT('Double-click the opposite corner.'));
		}
		else {
			var a = st.pending.start;
			homePlateAddArea(st, {
				shape: 'box',
				nw: { lat: Math.max(a.lat, lat), lon: Math.min(a.lon, lon) },
				se: { lat: Math.min(a.lat, lat), lon: Math.max(a.lon, lon) }
			});
			st.pending = null;
			homePlateMapStatus(st, '');
		}
		st.map.draw();
		return;
	}
	if (st.tool === 'path' || st.tool === 'polygon') {
		st.pending = st.pending || { shape: st.tool, points: [] };
		st.pending.points.push({ lat: lat, lon: lon });
		homePlateMapStatus(st, homePlateT('Double-click each point, then Finish.'));
		st.map.draw();
		return;
	}
	var hit = homePlateAreaAt(st, lat, lon);
	if (hit) { homePlateRemoveArea(st, hit); return; }
	homePlateAddArea(st, { shape: 'circle', lat: lat, lon: lon, radius_m: st.width || 200 });
}

function homePlateAddArea(st, area) {
	var plate = homePlateSelectedPlate(st);
	if (!plate) { homePlateStatus(st, homePlateT('Add or select a flag first.')); return; }
	plate.areas = plate.areas || [];
	plate.areas.push(area);
	st.area = plate.areas.length - 1;
	homePlateMirror(plate);
	st.dirty = true;
	homePlateSyncWidth(st);
	homePlateSummaries(st);
	homePlateBuildFlag(st);
	if (st.map) { st.map.draw(); }
}

function homePlateRemoveArea(st, hit) {
	if (!hit || !hit.plate) { return; }
	if (hit.branch) {
		hit.branch.areas = hit.branch.areas || [];
		hit.branch.areas.splice(hit.index, 1);
	}
	else {
		hit.plate.areas = hit.plate.areas || [];
		hit.plate.areas.splice(hit.index, 1);
	}
	st.area = null;
	homePlateMirror(hit.plate);
	st.dirty = true;
	homePlateSummaries(st);
	homePlateBuildFlag(st);
	homePlatePatternPanel(st);
	if (st.map) { st.map.draw(); }
}

function homePlateSyncWidth(st) {
	var plate = homePlateSelectedPlate(st);
	var input = st.editor.find('.home_plate_width').first();
	if (!input.length) { return; }
	var entries = homePlateAreaEntries(plate);
	if (st.area !== null && entries[st.area]) {
		var width = homePlateAreaWidth(entries[st.area].area);
		if (width) { input.val(width); st.width = width; }
	}
	else if (!input.val()) { input.val(st.width || 200); }
}

function homePlateFinish(st) {
	if (!st) { return; }
	if (st.trace && st.trace.points && st.trace.points.length >= 2) {
		var traced = null;
		if (typeof window.homePlateTraceWater === 'function' && st.map) {
			traced = window.homePlateTraceWater({ canvas: st.map.canvas, map: st.map, points: st.trace.points, widthMetres: st.width || 30 });
		}
		if (traced && traced.ok && traced.areas && traced.areas.length) {
			$.each(traced.areas, function(i, area) { homePlateAddArea(st, area); });
			homePlateStatus(st, homePlateT('The water was traced. Save the plate to keep it.'));
		}
		else {
			homePlateAddArea(st, { shape: 'path', points: st.trace.points.slice(), width_m: st.width || 30 });
			homePlateStatus(st, homePlateT('The water could not be read; the line is kept as a corridor.'));
		}
		st.trace = null;
		st.tool = '';
		homePlateToolbarState(st);
		if (st.map) { st.map.draw(); }
		return;
	}
	if (st.pending && st.pending.shape === 'path' && st.pending.points.length >= 2) {
		homePlateAddArea(st, { shape: 'path', points: st.pending.points.slice(), width_m: st.width || 30 });
		st.pending = null;
		st.tool = '';
		homePlateToolbarState(st);
		return;
	}
	if (st.pending && st.pending.shape === 'polygon' && st.pending.points.length >= 3) {
		homePlateAddArea(st, { shape: 'polygon', points: st.pending.points.slice() });
		st.pending = null;
		st.tool = '';
		homePlateToolbarState(st);
		return;
	}
	homePlateMapStatus(st, homePlateT('Nothing to finish yet.'));
}

function homePlateToolbarState(st) {
	if (!st || !st.editor) { return; }
	st.editor.find('.home_plate_tool').attr('active', 'no');
	if (st.tool) { st.editor.find('.home_plate_tool[data-shape="' + st.tool + '"]').attr('active', 'yes'); }
}

function homePlateSelect(st, uuid) {
	if (!st) { return; }
	st.selected = uuid || '';
	st.area = null;
	st.branchResults = null;
	homePlateBuildSelector(st);
	homePlateBuildFlag(st);
	homePlateSummaries(st);
	homePlatePatternPanel(st);
	homePlateToolbarState(st);
	if (st.map) {
		var anchor = homePlateAnchor(homePlateSelectedPlate(st));
		if (anchor) { st.map.focusOn(anchor.lat, anchor.lon, 0.006); }
		st.map.draw();
	}
}

function homePlateNewFlag(st, lat, lon) {
	if (!st) { return; }
	if (st.app === 'me') { homePlateStatus(st, homePlateT('The Me panel keeps one plate per device.')); return; }
	var uuid = 'hp' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
	var flag = {
		uuid: uuid, timestamp: Date.now(), kind: 'area', placement: 'within',
		action: 'start', device: '', self: 'on', app: st.app,
		areas: [{ shape: 'circle', lat: lat, lon: lon, radius_m: st.width || 200 }]
	};
	homePlateMirror(flag);
	st.flags.push(flag);
	homePlateSelect(st, uuid);
	homePlateStatus(st, homePlateT('Flag added. Save the plate to keep it.'));
}

function homePlateAddPattern(st) {
	if (!st) { return; }
	if (st.app === 'me') { homePlateStatus(st, homePlateT('The Me panel keeps one plate per device.')); return; }
	var view = st.map ? st.map.view() : { lat: 43.0, lon: -81.94 };
	var uuid = 'hp' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
	var flag = {
		uuid: uuid, timestamp: Date.now(), kind: 'pattern', placement: 'within',
		action: 'start', device: '', self: 'on', app: st.app,
		match: { brand: '', region: { lat: view.lat, lon: view.lon, radius_m: 50000 } },
		branches: []
	};
	st.flags.push(flag);
	homePlateSelect(st, uuid);
	homePlateStatus(st, homePlateT('Name the brand, then Find branches.'));
}

function homePlateAddBranch(st, lat, lon) {
	var plate = homePlateSelectedPlate(st);
	if (!plate || (plate.kind || '') !== 'pattern') { return; }
	plate.branches = plate.branches || [];
	plate.branches.push({
		name: homePlateT('Branch'), manual: 1,
		latitude: lat, longitude: lon,
		areas: [{ shape: 'circle', lat: lat, lon: lon, radius_m: 250 }]
	});
	homePlateMirror(plate);
	st.dirty = true;
	homePlateSummaries(st);
	homePlatePatternPanel(st);
	if (st.map) { st.map.draw(); }
}

function homePlateMovePlate(st, plate, oldLat, oldLon, newLat, newLon) {
	if (!plate) { return; }
	if ((plate.kind || '') === 'pattern') {
		plate.match = plate.match || {};
		plate.match.region = plate.match.region || {};
		plate.match.region.lat = +newLat;
		plate.match.region.lon = +newLon;
		plate.latitude = +newLat;
		plate.longitude = +newLon;
	}
	else {
		homePlateTranslate(plate, +newLat - +oldLat, +newLon - +oldLon);
	}
	st.dirty = true;
}

function homePlateFlagMenu(st, clientX, clientY) {
	$('#home_plate_flag_menu').remove();
	var menu = $('<div id="home_plate_flag_menu"></div>').css({
		position: 'fixed',
		left: Math.max(4, Math.min(clientX, $(window).width() - 190)) + 'px',
		top: Math.max(4, Math.min(clientY, $(window).height() - 100)) + 'px',
		zIndex: 9000, background: 'var(--panel)', border: '2px solid var(--line)',
		borderRadius: '8px', padding: '4px', minWidth: '150px',
		boxShadow: '0 6px 18px rgba(0,0,0,.35)', fontSize: '13px'
	}).appendTo('body');
	$('<span class="home_plate_flag_delete"></span>').text(homePlateT('Delete flag'))
		.css({ display: 'block', padding: '4px 6px', cursor: 'var(--jawnos-cursor-pointer, pointer)' }).appendTo(menu);
	$('<span class="home_plate_flag_duplicate"></span>').text(homePlateT('Duplicate flag'))
		.css({ display: 'block', padding: '4px 6px', cursor: 'var(--jawnos-cursor-pointer, pointer)' }).appendTo(menu);
	menu.data('editor', st.key);
}

function homePlateDeleteFlag(st) {
	if (!st) { return; }
	if (!st.selected) {
		delete st.base.areas;
		delete st.base.branches;
		delete st.base.latitude;
		delete st.base.longitude;
		delete st.base.distance;
		st.dirty = true;
		homePlateBuildFlag(st);
		homePlateSummaries(st);
		if (st.map) { st.map.draw(); }
		return;
	}
	var uuid = st.selected;
	$.ajax({
		url: '/manager/configure/home_plate/settings/delete',
		type: 'POST',
		data: { app: st.app, uuid: uuid },
		success: function() {
			st.flags = $.grep(st.flags, function(f) { return (f.uuid || '') !== uuid; });
			var $wrap = st.editor.closest('.home_plate_configuration');
			$wrap.find('.home_plate_setting_container[uuid="' + uuid + '"]').remove();
			homePlateSelect(st, '');
			homePlateStatus(st, homePlateT('The flag was deleted.'));
		}
	});
}

function homePlateDuplicateFlag(st) {
	var plate = homePlateSelectedPlate(st);
	if (!plate || !st.selected) { return; }
	var copy = JSON.parse(JSON.stringify(plate));
	copy.uuid = 'hp' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
	copy.timestamp = Date.now();
	if ((copy.kind || '') === 'pattern') {
		if (copy.match && copy.match.region) { copy.match.region.lat = +copy.match.region.lat + 0.0005; }
	}
	else {
		homePlateTranslate(copy, 0.0005, 0);
	}
	homePlateMirror(copy);
	st.flags.push(copy);
	homePlateSelect(st, copy.uuid);
	homePlateStatus(st, homePlateT('Flag duplicated. Save the plate to keep it.'));
}

function homePlateSave(st) {
	var plate = homePlateSelectedPlate(st);
	if (!plate) { return; }
	homePlateMirror(plate);
	homePlateStatus(st, homePlateT('Saving...'));
	$.ajax({
		url: '/manager/configure/home_plate/shape',
		type: 'POST',
		data: { app: st.app, device: st.device || '', uuid: st.selected || '', plate: JSON.stringify(plate) },
		dataType: 'json',
		success: function(r) {
			if (!r || r.error) {
				homePlateStatus(st, (r && r.error) || homePlateT('The plate was not saved.'));
				return;
			}
			st.dirty = false;
			homePlateStatus(st, homePlateT('Saved.'));
			if (r.base) { st.base = r.base; homePlateBuildFlag(st); homePlateSummaries(st); if (st.map) { st.map.draw(); } }
			var $wrap = st.editor.closest('.home_plate_configuration');
			if (r.html && $wrap.length) {
				$wrap.html(r.html);
				homePlateReload($wrap.find('.home_plate_editor').first());
			}
		},
		error: function() { homePlateStatus(st, homePlateT('The plate was not saved.')); }
	});
}

// The card's own delete handler calls this after the route answers, so the map
// stops drawing a flag the server has just removed.
function homePlateDropFlag(app, uuid) {
	var st = homePlateForApp(app);
	if (!st) { return; }
	st.flags = $.grep(st.flags || [], function(f) { return (f.uuid || '') !== uuid; });
	if (st.selected === uuid) { homePlateSelect(st, ''); }
	else { homePlateBuildSelector(st); homePlateSummaries(st); if (st.map) { st.map.draw(); } }
}

// ---- delegated events ------------------------------------------------------
$(document).on('click', '.home_plate_editor .home_plate_tool', function() {
	var st = homePlateState(homePlateClickEditor(this));
	var shape = $(this).attr('data-shape');
	st.tool = (st.tool === shape) ? '' : shape;
	st.pending = null;
	st.trace = (st.tool === 'trace') ? { points: [] } : null;
	homePlateToolbarState(st);
	homePlateMapStatus(st, st.tool ? homePlateT('Draw on the map, then Finish.') : '');
	if (st.map) { st.map.draw(); }
});

$(document).on('click', '.home_plate_editor .home_plate_flag_tool', function() {
	var st = homePlateState(homePlateClickEditor(this));
	st.flagArmed = true;
	homePlateMapStatus(st, homePlateT('Click the map to place the flag.'));
});

$(document).on('dragstart', '.home_plate_editor .home_plate_flag_tool', function(e) {
	var st = homePlateState(homePlateClickEditor(this));
	try { e.originalEvent.dataTransfer.setData('text/plain', st.key); } catch (err) {}
});

$(document).on('dragover', '.home_plate_editor .home_plate_map_wrap', function(e) { e.preventDefault(); });

$(document).on('drop', '.home_plate_editor .home_plate_map_wrap', function(e) {
	e.preventDefault();
	var st = homePlateState(homePlateClickEditor(this));
	if (!st.map) { return; }
	var rect = st.map.canvas.getBoundingClientRect();
	var g = st.map.unproject(e.originalEvent.clientX - rect.left, e.originalEvent.clientY - rect.top);
	homePlateNewFlag(st, g.lat, g.lon);
});

$(document).on('click', '.home_plate_editor .home_plate_add_flag', function() {
	var st = homePlateState(homePlateClickEditor(this));
	var v = st.map ? st.map.view() : null;
	homePlateNewFlag(st, v ? v.lat : 43.0, v ? v.lon : -81.94);
});

$(document).on('click', '.home_plate_editor .home_plate_add_pattern', function() {
	homePlateAddPattern(homePlateState(homePlateClickEditor(this)));
});

$(document).on('change', '.home_plate_editor .home_plate_flag_select', function() {
	homePlateSelect(homePlateState(homePlateClickEditor(this)), $(this).val() || '');
});

$(document).on('change', '.home_plate_editor .home_plate_provider', function() {
	var st = homePlateState(homePlateClickEditor(this));
	if (!st.map) { return; }
	var g = st.ground || {};
	st.map.setProvider($(this).val() || 'none', g.custom_url || '', g.keys || {});
	st.map.draw();
});

$(document).on('change input', '.home_plate_editor .home_plate_width', function() {
	var st = homePlateState(homePlateClickEditor(this));
	var plate = homePlateSelectedPlate(st);
	var entries = homePlateAreaEntries(plate);
	var value = parseInt($(this).val(), 10) || 0;
	if (value > 0) { st.width = value; }
	if (st.area === null || !entries[st.area]) { return; }
	var area = entries[st.area].area;
	if ((area.shape || '') === 'circle') { area.radius_m = value; }
	else if ((area.shape || '') === 'path') { area.width_m = value; }
	else { return; }
	homePlateMirror(plate);
	st.dirty = true;
	homePlateSummaries(st);
	if (st.map) { st.map.draw(); }
});

$(document).on('click', '.home_plate_editor .home_plate_finish', function() {
	homePlateFinish(homePlateState(homePlateClickEditor(this)));
});

$(document).on('click', '.home_plate_editor .home_plate_shape_delete', function() {
	var st = homePlateState(homePlateClickEditor(this));
	var entries = homePlateAreaEntries(homePlateSelectedPlate(st));
	if (st.area === null || !entries[st.area]) {
		homePlateStatus(st, homePlateT('Select a shape on the map first.'));
		return;
	}
	homePlateRemoveArea(st, entries[st.area]);
});

$(document).on('click', '.home_plate_editor .home_plate_save', function() {
	homePlateSave(homePlateState(homePlateClickEditor(this)));
});

$(document).on('click', '.home_plate_edit', function() {
	var $wrap = $(this).closest('.home_plate_configuration');
	var $editor = $wrap.find('.home_plate_editor').first();
	if (!$editor.length) { return; }
	var st = homePlateState($editor);
	homePlateInit($editor);
	homePlateSelect(st, $(this).attr('uuid') || '');
	if (typeof $editor[0].scrollIntoView === 'function') { $editor[0].scrollIntoView({ behavior: 'smooth', block: 'center' }); }
});

$(document).on('click', '.home_plate_editor .home_plate_find_branches', function() {
	var st = homePlateState(homePlateClickEditor(this));
	var plate = homePlateSelectedPlate(st);
	if (!plate || (plate.kind || '') !== 'pattern') { return; }
	var brand = $.trim(st.editor.find('.home_plate_brand').val() || '');
	if (!brand) { homePlatePatternStatus(st, homePlateT('Type a brand to search for.')); return; }
	var region = plate.match.region || { lat: 0, lon: 0, radius_m: 50000 };
	var km = parseInt(st.editor.find('.home_plate_pattern_radius').val(), 10) || 50;
	region.radius_m = km * 1000;
	plate.match.brand = brand;
	plate.match.region = region;
	homePlatePatternStatus(st, homePlateT('Searching...'));
	$.ajax({
		url: '/manager/travel/branches',
		type: 'POST',
		data: { brand: brand, lat: region.lat, lon: region.lon, radius: region.radius_m },
		dataType: 'json',
		success: function(r) {
			if (!r || r.error) {
				homePlatePatternStatus(st, (r && r.error) || homePlateT('The search did not answer.'));
				return;
			}
			st.branchResults = r.branches || [];
			homePlatePatternStatus(st, st.branchResults.length + ' ' + homePlateT('branches found.'));
			homePlateRenderBranchResults(st);
		},
		error: function() { homePlatePatternStatus(st, homePlateT('The search did not answer.')); }
	});
});

$(document).on('click', '.home_plate_editor .home_plate_add_branch', function() {
	var st = homePlateState(homePlateClickEditor(this));
	var plate = homePlateSelectedPlate(st);
	if (!plate || (plate.kind || '') !== 'pattern') { return; }
	st.branchArmed = true;
	homePlateMapStatus(st, homePlateT('Click the map where the branch is.'));
});

$(document).on('click', '.home_plate_editor .home_plate_add_checked', function() {
	var st = homePlateState(homePlateClickEditor(this));
	var plate = homePlateSelectedPlate(st);
	if (!plate || (plate.kind || '') !== 'pattern') { return; }
	plate.branches = plate.branches || [];
	var added = 0;
	st.editor.find('.home_plate_branch_list input[type="checkbox"]:checked').each(function() {
		var i = parseInt($(this).val(), 10);
		var b = (st.branchResults || [])[i];
		if (!b) { return; }
		var dup = false;
		$.each(plate.branches, function(k, existing) {
			if (homePlateMetres({ lat: +existing.latitude, lon: +existing.longitude }, { lat: +b.lat, lon: +b.lon }) <= 150) {
				dup = true; return false;
			}
		});
		if (dup) { return; }
		plate.branches.push({
			name: b.name || b.brand || homePlateT('Branch'),
			brand: b.brand || plate.match.brand || '',
			latitude: +b.lat, longitude: +b.lon,
			areas: [{ shape: 'circle', lat: +b.lat, lon: +b.lon, radius_m: 250 }]
		});
		added++;
	});
	st.branchResults = null;
	homePlateMirror(plate);
	st.dirty = true;
	homePlateSummaries(st);
	homePlatePatternPanel(st);
	if (st.map) { st.map.draw(); }
	homePlatePatternStatus(st, added + ' ' + homePlateT('branches added.'));
});

$(document).on('click', '.home_plate_editor .home_plate_branch_delete', function() {
	var st = homePlateState(homePlateClickEditor(this));
	var plate = homePlateSelectedPlate(st);
	if (!plate) { return; }
	var i = parseInt($(this).attr('branch'), 10);
	if (isFinite(i)) { plate.branches.splice(i, 1); }
	homePlateMirror(plate);
	st.dirty = true;
	homePlateSummaries(st);
	homePlatePatternPanel(st);
	if (st.map) { st.map.draw(); }
});

$(document).on('contextmenu', '.home_plate_editor .home_plate_flag_marker', function(e) {
	e.preventDefault();
	e.stopPropagation();
	homePlateFlagMenu(homePlateState(homePlateClickEditor(this)), e.clientX, e.clientY);
});

$(document).on('pointerdown', '.home_plate_editor .home_plate_flag_marker', function(e) {
	if (e.button !== undefined && e.button !== 0) { return; }
	var st = homePlateState(homePlateClickEditor(this));
	var plate = homePlateSelectedPlate(st);
	if (!plate || !st.map) { return; }
	e.preventDefault();
	var startX = e.clientX, startY = e.clientY;
	var anchor = homePlateAnchor(plate);
	var moved = false;
	var menuTimer = setTimeout(function() {
		menuTimer = null;
		if (!moved) { homePlateFlagMenu(st, startX, startY); }
	}, 600);
	var move = function(ev) {
		if (!moved && (Math.abs(ev.clientX - startX) > 4 || Math.abs(ev.clientY - startY) > 4)) {
			moved = true;
			if (menuTimer) { clearTimeout(menuTimer); menuTimer = null; }
		}
		if (!moved) { return; }
		var rect = st.map.canvas.getBoundingClientRect();
		var g = st.map.unproject(ev.clientX - rect.left, ev.clientY - rect.top);
		homePlateMovePlate(st, plate, anchor.lat, anchor.lon, g.lat, g.lon);
		anchor = { lat: g.lat, lon: g.lon };
		homePlatePlaceFlag(st);
		st.map.draw();
	};
	var up = function() {
		if (menuTimer) { clearTimeout(menuTimer); menuTimer = null; }
		$(document).off('pointermove', move).off('pointerup', up).off('pointercancel', up);
		if (moved) {
			homePlateMirror(plate);
			homePlateSummaries(st);
			homePlatePatternPanel(st);
		}
	};
	$(document).on('pointermove', move).on('pointerup', up).on('pointercancel', up);
});

$(document).on('click', '#home_plate_flag_menu .home_plate_flag_delete', function() {
	var key = $('#home_plate_flag_menu').data('editor');
	$('#home_plate_flag_menu').remove();
	if (homePlateEditors[key]) { homePlateDeleteFlag(homePlateEditors[key]); }
});

$(document).on('click', '#home_plate_flag_menu .home_plate_flag_duplicate', function() {
	var key = $('#home_plate_flag_menu').data('editor');
	$('#home_plate_flag_menu').remove();
	if (homePlateEditors[key]) { homePlateDuplicateFlag(homePlateEditors[key]); }
});

$(document).on('mousedown touchstart', function(e) {
	if (!$(e.target).closest('#home_plate_flag_menu').length) { $('#home_plate_flag_menu').remove(); }
});

$(function() {
	homePlateInitAll(document);
	$(document).on('toggle', 'details', function() {
		var root = this;
		setTimeout(function() { homePlateInitAll(root); }, 0);
	});
	$(document).on('click', '.home_plate_editor', function() {
		var st = homePlateEditors[homePlateKey($(this))];
		if (!st || !st.map) {
			var editor = this;
			setTimeout(function() { homePlateInitAll(editor); }, 0);
		}
	});
});
