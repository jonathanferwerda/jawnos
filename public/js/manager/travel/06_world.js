// ---- the virtual world: A-Frame, built from the house's own ground ----
// The measured maps lie on the ground, the archive's buildings stand up, its
// woodland grows trees, its water and roads are drawn, the places and plates are
// marked, and the pictures taken here hang where they were taken, facing the way
// the phone was facing.
//
// A-Frame is injected on demand from /js/aframe/aframe.min.js (gitignored,
// installed by scripts/fetch_aframe.sh). It bundles its own three.js and its own
// CSS, so the world runs in a same-origin iframe: nothing it registers can touch
// the panel's globals, and the manager's policy still governs what it loads.
//
// The geometry comes from the archive the house street map already reads. A
// hidden MapLibre map is opened at the pressed ground and its loaded tiles are
// queried; querySourceFeatures hands back lon/lat polygons, so nothing here
// decodes a vector tile. Everything is then placed in local metres around the
// press - x east, z south - the same frame the 3D model uses.
//
// There is no elevation in the archive, so the ground is flat. A valley or a
// hill would need a terrain file the house does not stage; inventing one would
// break the rule that a guess never passes for measured ground.

var travelWorldState = null;
var travelWorldLoading = false;

function travelWorldNote(text) {
	var note = $('#travel_world_note');
	if (text) { note.text(text).css('display', 'flex'); }
	else { note.text('').hide(); }
}

function travelWorldOpen(lat, lon) {
	// one layer at a time: opening this closes the other views
	if (typeof travelNear3dClose === 'function') { travelNear3dClose(); }
	if (typeof travelGlobeClose === 'function') { travelGlobeClose(); }
	if (typeof travelBasemapClose === 'function') { travelBasemapClose(); }
	if (travelWorldState) { travelWorldClose(); }
	$('#travel_world').css('display', 'flex');
	travelWorldNote(jawnosT('Building the virtual world…'));
	var a = parseFloat(lat), b = parseFloat(lon);
	$('#travel_world_title').text(jawnosT('Virtual world')
		+ ((isFinite(a) && isFinite(b)) ? ' · ' + a.toFixed(5) + ', ' + b.toFixed(5) : ''));
	if (window.maplibregl && window.pmtiles) { travelWorldStart(lat, lon); return; }
	if (travelWorldLoading) { return; }
	travelWorldLoading = true;
	travelBasemapLoad(function(ok) {
		travelWorldLoading = false;
		if (!$('#travel_world').is(':visible')) { return; }
		if (!ok) {
			travelWorldNote(jawnosT('The house\'s street map is not installed - run scripts/fetch_basemap_libs.sh'));
			return;
		}
		travelWorldStart(lat, lon);
	});
}

function travelWorldStart(lat, lon) {
	var stage = document.getElementById('travel_world_stage');
	if (!stage) { return; }
	if (travelWorldState) { travelWorldClose(); }
	var centre = (typeof travelNear3dCentre === 'function')
		? travelNear3dCentre(lat, lon)
		: { lat: parseFloat(lat) || 0, lon: parseFloat(lon) || 0 };

	travelBasemapRegister();

	// the sampler is a real box behind the frame: MapLibre needs a laid-out
	// container to fetch its tiles, and nothing of it is ever shown
	var sampler = document.createElement('div');
	sampler.id = 'travel_world_sampler';
	sampler.style.cssText = 'position:absolute;inset:0;opacity:0;pointer-events:none;z-index:0;';
	stage.appendChild(sampler);

	var st = { map: null, sampler: sampler, frame: null, listener: null, centre: centre, timer: null };
	travelWorldState = st;

	travelBasemapMaxZoom('/manager/travel/basemap', function(maxzoom) {
		if (travelWorldState !== st) { return; }
		st.maxzoom = maxzoom;
		var map;
		try {
			map = new maplibregl.Map({
				container: sampler,
				style: travelBasemapStyle(maxzoom),
				center: [centre.lon, centre.lat],
				zoom: Math.min(16, maxzoom || 16),
				maxZoom: maxzoom,
				interactive: false,
				attributionControl: false
			});
		} catch (e) {
			travelWorldNote(jawnosT('This browser cannot draw the map here.'));
			return;
		}
		st.map = map;
		var built = false;
		var build = function() {
			if (built || travelWorldState !== st) { return; }
			built = true;
			if (st.timer) { clearTimeout(st.timer); st.timer = null; }
			travelWorldAssemble(st);
		};
		map.on('idle', build);
		map.on('error', function(e) {
			try { console.error('Travel world:', (e && e.error) || e); } catch (err) {}
		});
		// a house with no archive never reaches idle with data; say so instead of
		// waiting forever
		st.timer = setTimeout(build, 12000);
	});
}

// Every polygon and line the archive holds, in local metres around the press.
function travelWorldAssemble(st) {
	var map = st.map, centre = st.centre;
	var MPD = 111194.9;
	var cosLat = Math.cos(centre.lat * Math.PI / 180);
	var RADIUS = 190;

	function at(latitude, longitude) {
		return {
			x: (longitude - centre.lon) * MPD * cosLat,
			z: -(latitude - centre.lat) * MPD
		};
	}
	function featureList(layer) {
		try { return map.querySourceFeatures('basemap', { sourceLayer: layer }) || []; }
		catch (e) { return []; }
	}
	function ring(coords, max_points) {
		var pts = [];
		for (var i = 0; i < coords.length && pts.length < (max_points || 48); i++) {
			var c = coords[i];
			if (!c || c.length < 2) { continue; }
			var p = at(+c[1], +c[0]);
			if (!isFinite(p.x) || !isFinite(p.z)) { continue; }
			pts.push([Math.round(p.x * 10) / 10, Math.round(p.z * 10) / 10]);
		}
		if (pts.length > 2) {
			var a = pts[0], b = pts[pts.length - 1];
			if (Math.abs(a[0] - b[0]) < 0.05 && Math.abs(a[1] - b[1]) < 0.05) { pts.pop(); }
		}
		return pts;
	}
	function squareMetres(pts) {
		var sum = 0;
		for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
			sum += (pts[j][0] * pts[i][1]) - (pts[i][0] * pts[j][1]);
		}
		return Math.abs(sum) / 2;
	}
	function centreOf(pts) {
		var sx = 0, sz = 0;
		for (var i = 0; i < pts.length; i++) { sx += pts[i][0]; sz += pts[i][1]; }
		return [sx / pts.length, sz / pts.length];
	}
	function near(pts, radius) {
		var c = centreOf(pts);
		return Math.sqrt(c[0] * c[0] + c[1] * c[1]) <= radius;
	}
	function distance(p) {
		return Math.sqrt(p.x * p.x + p.z * p.z);
	}

	var out = {
		centre: { lat: centre.lat, lon: centre.lon },
		radius: RADIUS,
		maps: [], land: [], buildings: [], water: [], streams: [], roads: [], trees: [],
		places: [], plates: [], photos: []
	};

	// ---- the measured maps, exactly as the 3D model lays them down ----------
	$.each((typeof travelAllMaps !== 'undefined' && travelAllMaps) ? travelAllMaps : [], function(i, m) {
		if (!m || !m['file']) { return; }
		if (!window.jawnosMap || typeof window.jawnosMap.mapBounds !== 'function') { return; }
		var bounds = window.jawnosMap.mapBounds(m);
		if (!bounds) { return; }
		var widthM = (bounds.se.lon - bounds.nw.lon) * MPD * cosLat;
		var heightM = (bounds.nw.lat - bounds.se.lat) * MPD;
		if (!(widthM > 0) || !(heightM > 0)) { return; }
		var mid = at((bounds.nw.lat + bounds.se.lat) / 2, (bounds.nw.lon + bounds.se.lon) / 2);
		var hp = m['home_plate'] || {};
		var hx = parseFloat(hp['x']), hy = parseFloat(hp['y']);
		var hw = parseFloat(hp['width']), hh = parseFloat(hp['height']);
		if (!isFinite(hx)) { hx = 0; }
		if (!isFinite(hy)) { hy = 0; }
		var plateLat = bounds.nw.lat + (bounds.se.lat - bounds.nw.lat) * (hh > 0 ? hy / hh : 0.5);
		var plateLon = bounds.nw.lon + (bounds.se.lon - bounds.nw.lon) * (hw > 0 ? hx / hw : 0.5);
		var plate = at(plateLat, plateLon);
		out.maps.push({
			url: m['file'],
			w: Math.round(widthM * 10) / 10,
			d: Math.round(heightM * 10) / 10,
			x: Math.round((mid.x - plate.x) * 10) / 10,
			z: Math.round((mid.z - plate.z) * 10) / 10,
			px: Math.round(plate.x * 10) / 10,
			pz: Math.round(plate.z * 10) / 10,
			rot: -(parseFloat(m['rotate']) || 0),
			opacity: m['guessed'] ? 0.4 : 1
		});
	});

	// ---- land cover: colour under the town, from the same archive ----------
	var land_colour = {
		wood: '#cfe0bb', forest: '#cfe0bb', scrub: '#d9e6c4', heath: '#d9e6c4',
		grass: '#dfe9cf', meadow: '#dfe9cf', park: '#d2e3bf', garden: '#d2e3bf',
		recreation_ground: '#d2e3bf', national_park: '#d2e3bf',
		farmland: '#eef1d8', orchard: '#eaf0d5', vineyard: '#eaf0d5', allotments: '#eaf0d5',
		cemetery: '#dde4d6', residential: '#e8e4da', suburb: '#e8e4da',
		neighbourhood: '#e8e4da', quarter: '#e8e4da',
		industrial: '#e3dfe4', commercial: '#e3dfe4', retail: '#e3dfe4', railway: '#e3dfe4',
		sand: '#f2e7cf'
	};
	$.each(['landcover', 'landuse', 'park'], function(i, layer) {
		$.each(featureList(layer), function(j, f) {
			if (!f || !f.geometry || f.geometry.type !== 'Polygon') { return; }
			var cls = (f.properties || {})['class'] || '';
			var colour = land_colour[cls];
			if (!colour) { return; }
			var pts = ring(f.geometry.coordinates[0], 40);
			if (pts.length < 3 || !near(pts, RADIUS + 40)) { return; }
			if (squareMetres(pts) < 80) { return; }
			out.land.push({ p: pts, c: colour });
		});
	});
	out.land = out.land.slice(0, 100);

	// ---- buildings ----------------------------------------------------------
	$.each(featureList('building'), function(i, f) {
		if (!f || !f.geometry || f.geometry.type !== 'Polygon') { return; }
		var pts = ring(f.geometry.coordinates[0], 40);
		if (pts.length < 3 || !near(pts, RADIUS + 20)) { return; }
		if (squareMetres(pts) < 4) { return; }
		var h = parseFloat((f.properties || {})['render_height']);
		if (!isFinite(h) || h <= 0) { h = 6; }
		if (h > 120) { h = 120; }
		out.buildings.push({ p: pts, h: Math.round(h * 10) / 10 });
	});
	out.buildings.sort(function(a, b) {
		var ca = centreOf(a.p), cb = centreOf(b.p);
		return (ca[0] * ca[0] + ca[1] * ca[1]) - (cb[0] * cb[0] + cb[1] * cb[1]);
	});
	out.buildings = out.buildings.slice(0, 260);

	// ---- water, and the streams that feed it --------------------------------
	$.each(featureList('water'), function(i, f) {
		if (!f || !f.geometry || f.geometry.type !== 'Polygon') { return; }
		var pts = ring(f.geometry.coordinates[0], 60);
		if (pts.length < 3 || !near(pts, RADIUS + 30)) { return; }
		if (squareMetres(pts) < 20) { return; }
		out.water.push(pts);
	});
	out.water = out.water.slice(0, 40);

	$.each(featureList('waterway'), function(i, f) {
		if (!f || !f.geometry || f.geometry.type !== 'LineString') { return; }
		var line = f.geometry.coordinates || [];
		for (var k = 1; k < line.length && out.streams.length < 60; k++) {
			var a = at(+line[k - 1][1], +line[k - 1][0]);
			var b = at(+line[k][1], +line[k][0]);
			if (distance(a) > RADIUS + 40 && distance(b) > RADIUS + 40) { continue; }
			var len = Math.sqrt(Math.pow(b.x - a.x, 2) + Math.pow(b.z - a.z, 2));
			if (len < 1) { continue; }
			out.streams.push({
				x: Math.round((a.x + b.x) / 2 * 10) / 10,
				z: Math.round((a.z + b.z) / 2 * 10) / 10,
				len: Math.round(len * 10) / 10,
				rot: Math.round(-Math.atan2(b.z - a.z, b.x - a.x) * 180 / Math.PI * 10) / 10,
				w: 3
			});
		}
	});

	// ---- roads: the same classes and widths the street map draws ------------
	var road_colour = {
		motorway: '#f6c98b', trunk: '#f8d79b', primary: '#fbe4b4', secondary: '#fdf1d8',
		tertiary: '#ffffff', minor: '#ffffff', street: '#ffffff', residential: '#ffffff',
		unclassified: '#ffffff', living_street: '#ffffff', service: '#ffffff', track: '#e3d8c0'
	};
	$.each(featureList('transportation'), function(i, f) {
		if (!f || !f.geometry || f.geometry.type !== 'LineString') { return; }
		var cls = (f.properties || {})['class'] || '';
		var colour = road_colour[cls];
		if (!colour) { return; }
		var width = ({ motorway: 8, trunk: 7, primary: 6, secondary: 5, tertiary: 4, minor: 3, street: 3, residential: 3, unclassified: 3, living_street: 2.5, service: 2, track: 1.6 })[cls] || 2;
		var line = f.geometry.coordinates || [];
		for (var k = 1; k < line.length && out.roads.length < 260; k++) {
			var a = at(+line[k - 1][1], +line[k - 1][0]);
			var b = at(+line[k][1], +line[k][0]);
			if (distance(a) > RADIUS + 80 && distance(b) > RADIUS + 80) { continue; }
			var len = Math.sqrt(Math.pow(b.x - a.x, 2) + Math.pow(b.z - a.z, 2));
			if (len < 1) { continue; }
			out.roads.push({
				x: Math.round((a.x + b.x) / 2 * 10) / 10,
				z: Math.round((a.z + b.z) / 2 * 10) / 10,
				len: Math.round(len * 10) / 10,
				rot: Math.round(-Math.atan2(b.z - a.z, b.x - a.x) * 180 / Math.PI * 10) / 10,
				w: width,
				c: colour
			});
		}
	});

	// ---- trees: woodland, parks and grass, scattered inside their shapes ----
	var groves = [];
	$.each(['landcover', 'landuse', 'park'], function(i, layer) {
		$.each(featureList(layer), function(j, f) {
			if (!f || !f.geometry || f.geometry.type !== 'Polygon') { return; }
			var cls = (f.properties || {})['class'] || '';
			if (!/(?:wood|forest|grass|meadow|park|garden|recreation_ground|scrub|heath)/.test(cls)) { return; }
			var pts = ring(f.geometry.coordinates[0], 32);
			if (pts.length < 3 || !near(pts, RADIUS)) { return; }
			var area = squareMetres(pts);
			if (area < 30) { return; }
			groves.push({ p: pts, area: area });
		});
	});
	// a stable scatter: reopening the same ground grows the same trees
	var seed = 20261116;
	function rnd() {
		seed = (seed * 1103515245 + 12345) & 0x7fffffff;
		return seed / 0x7fffffff;
	}
	function inside(pt, poly) {
		var x = pt[0], z = pt[1], hit = false;
		for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
			var xi = poly[i][0], zi = poly[i][1], xj = poly[j][0], zj = poly[j][1];
			if (((zi > z) !== (zj > z)) && (x < (xj - xi) * (z - zi) / (zj - zi) + xi)) { hit = !hit; }
		}
		return hit;
	}
	$.each(groves, function(i, grove) {
		var want = Math.min(14, Math.max(1, Math.round(grove.area / 220)));
		var box = [1e9, 1e9, -1e9, -1e9];
		for (var i2 = 0; i2 < grove.p.length; i2++) {
			box[0] = Math.min(box[0], grove.p[i2][0]); box[2] = Math.max(box[2], grove.p[i2][0]);
			box[1] = Math.min(box[1], grove.p[i2][1]); box[3] = Math.max(box[3], grove.p[i2][1]);
		}
		for (var t = 0; t < want * 4 && out.trees.length < 70; t++) {
			var p = [box[0] + rnd() * (box[2] - box[0]), box[1] + rnd() * (box[3] - box[1])];
			if (!inside(p, grove.p)) { continue; }
			out.trees.push({
				x: Math.round(p[0] * 10) / 10,
				z: Math.round(p[1] * 10) / 10,
				s: Math.round((0.75 + rnd() * 0.7) * 10) / 10
			});
			if (out.trees.length >= 70) { break; }
		}
	});

	// ---- the places the house knows, and its home plates --------------------
	$.each(((typeof mapData !== 'undefined' && mapData && mapData.near) ? mapData.near : []), function(i, p) {
		var plat = parseFloat(p && p['latitude']), plon = parseFloat(p && p['longitude']);
		if (!isFinite(plat) || !isFinite(plon)) { return; }
		var at2 = at(plat, plon);
		if (distance(at2) > RADIUS) { return; }
		out.places.push({
			x: Math.round(at2.x * 10) / 10,
			z: Math.round(at2.z * 10) / 10,
			name: p['name'] || p['app'] || '',
			colour: (p['settings'] && p['settings']['colour']) || p['colour'] || '#2f6f9f'
		});
	});
	out.places = out.places.slice(0, 50);
	$.each((typeof travelPlateList !== 'undefined' && travelPlateList) || [], function(i, p) {
		var plat = parseFloat(p && p['latitude']), plon = parseFloat(p && p['longitude']);
		if (!isFinite(plat) || !isFinite(plon)) { return; }
		var at3 = at(plat, plon);
		if (distance(at3) > RADIUS) { return; }
		out.plates.push({ x: Math.round(at3.x * 10) / 10, z: Math.round(at3.z * 10) / 10 });
	});
	out.plates = out.plates.slice(0, 30);

	// ---- the pictures taken here, each with its fix and its direction -------
	var finish = function() {
		if (travelWorldState !== st) { return; }
		travelWorldFrame(st, out);
	};
	if (!out.buildings.length && !out.water.length && !out.roads.length) {
		travelWorldNote(jawnosT('No street map is staged for this ground - run perl scripts/osm_basemap.pl --all'));
	}
	$.ajax({
		url: '/manager/travel/nearby',
		type: 'GET',
		data: { lat: centre.lat, lon: centre.lon, radius: RADIUS, limit: 200 },
		success: function(r) {
			if (travelWorldState !== st) { return; }
			$.each((r && r['items']) || [], function(i, it) {
				if (!it) { return; }
				var plat = parseFloat(it['latitude']), plon = parseFloat(it['longitude']);
				if (!isFinite(plat) || !isFinite(plon)) { return; }
				var at4 = at(plat, plon);
				if (distance(at4) > RADIUS) { return; }
				var heading = parseFloat(it['heading']);
				out.photos.push({
					url: it['thumb_url'] || '',
					x: Math.round(at4.x * 10) / 10,
					z: Math.round(at4.z * 10) / 10,
					heading: (isFinite(heading) ? heading : null),
					absolute: (it['heading_source'] || '') === 'absolute',
					label: it['label'] || it['app'] || '',
					f: it['f'] || '',
					timestamp: it['timestamp'] || 0
				});
			});
			out.photos = out.photos.slice(0, 40);
			finish();
		},
		error: finish
	});
}

// The frame: a standalone A-Frame page, same origin, so the panel's policy and
// session still apply and A-Frame's globals stay out of the panel.
function travelWorldFrame(st, data) {
	var stage = document.getElementById('travel_world_stage');
	if (!stage || travelWorldState !== st) { return; }
	var frame = document.createElement('iframe');
	frame.id = 'travel_world_frame';
	frame.title = 'Virtual world';
	frame.style.cssText = 'position:absolute;inset:0;z-index:1;width:100%;height:100%;border:0;background:#0b0d10;';
	frame.src = '/manager/travel/world';
	stage.appendChild(frame);
	st.frame = frame;

	st.listener = function(e) {
		if (e.origin !== location.origin || !e.data || !e.data.type) { return; }
		else if (e.data.type === 'travel_world_ready') {
			travelWorldNote('');
			if (travelWorldState !== st || !frame.contentWindow) { return; }
			frame.contentWindow.postMessage({ type: 'travel_world_build', data: data }, location.origin);
		}
		else if (e.data.type === 'travel_world_missing') {
			travelWorldNote(jawnosT('A-Frame is not installed - run scripts/fetch_aframe.sh, then open the virtual world again.'));
			if (frame.parentNode) { frame.parentNode.removeChild(frame); }
			st.frame = null;
		}
		else if (e.data.type === 'travel_world_error') {
			try { console.error('Travel world:', e.data.message || 'error'); } catch (err) {}
		}
		else if (e.data.type === 'travel_world_photo' && e.data.f && typeof imageViewer === 'function') {
			imageViewer({ near: { lat: st.centre.lat, lon: st.centre.lon, radius: data.radius }, target: e.data.f });
		}
	};
	window.addEventListener('message', st.listener);
}

function travelWorldClose() {
	var st = travelWorldState;
	travelWorldState = null;
	if (st) {
		if (st.timer) { clearTimeout(st.timer); }
		if (st.listener) { window.removeEventListener('message', st.listener); }
		if (st.frame && st.frame.parentNode) { st.frame.parentNode.removeChild(st.frame); }
		if (st.map) { try { st.map.remove(); } catch (e) {} }
		if (st.sampler && st.sampler.parentNode) { st.sampler.parentNode.removeChild(st.sampler); }
	}
	$('#travel_world').hide();
	travelWorldNote('');
}

$(document).on('click', '#travel_world_close', function() { travelWorldClose(); });
$(document).on('keyup', function(e) {
	if (e.key == 'Escape' && $('#travel_world').is(':visible')) { travelWorldClose(); }
});
