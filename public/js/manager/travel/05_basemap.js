// ---- the house's own street map: OpenMapTiles from a PMTiles archive ----
// The fourth long-press answer draws real streets instead of the measured
// pictures. The vectors are the house's own archive: scripts/osm_basemap.pl
// builds OpenMapTiles-schema PMTiles from an OpenStreetMap extract and stages
// it in basemaps/ (z0-z14, a build artifact); GET /manager/travel/basemap
// serves it by byte range, which is exactly how a PMTiles reader asks for it.
// MapLibre GL draws those vectors and PMTiles is the reader, both installed
// locally by scripts/fetch_basemap_libs.sh into public/js/basemap/ (gitignored)
// and injected the first time this view opens. There is no CDN fallback and no
// third-party origin: a manager page carries the house's session.
//
// The house's CSP has no `worker-src blob:`, and MapLibre's ordinary build
// starts its worker from a blob: URL, which 'self' does not cover. So the
// loader prefers the CSP build (maplibre-gl-csp.js, whose worker is the
// same-origin maplibre-gl-csp-worker.js) and falls back to maplibre-gl.js only
// when that pair is not installed. The policy itself is not widened.
//
// The archive carries no glyph atlas, and the style may not fetch fonts from a
// third-party server, so place names are drawn as DOM markers over the map
// rather than as a symbol layer: text that needs nothing installed.
//
// The style below is hand-written for the OpenMapTiles layers this archive
// actually holds: landcover and landuse, water and waterway, transportation
// (a casing under each class's fill, widths growing with zoom), buildings as a
// flat fill, and the `place` layer for labels.

var travelBasemapState = null;
var travelBasemapLoading = false;
var travelBasemapCss = false;
var travelBasemapProtocol = false;

function travelBasemapOpen(lat, lon) {
	// one layer at a time: opening this closes the other two
	if (typeof travelNear3dClose === 'function') { travelNear3dClose(); }
	if (typeof travelGlobeClose === 'function') { travelGlobeClose(); }
	if (travelBasemapState) { travelBasemapClose(); }
	$('#travel_basemap').css('display', 'flex');
	travelBasemapNote(jawnosT('Opening the house\'s street map…'));
	var a = parseFloat(lat), b = parseFloat(lon);
	$('#travel_basemap_title').text(jawnosT('House street map')
		+ ((isFinite(a) && isFinite(b)) ? ' · ' + a.toFixed(5) + ', ' + b.toFixed(5) : ''));
	if (window.maplibregl && window.pmtiles) { travelBasemapStart(lat, lon); return; }
	if (travelBasemapLoading) { return; }
	travelBasemapLoading = true;
	travelBasemapLoad(function(ok) {
		travelBasemapLoading = false;
		// the person may have closed the layer while the libraries were in flight
		if (!$('#travel_basemap').is(':visible')) { return; }
		if (!ok) {
			travelBasemapNote(jawnosT('The house\'s street map is not installed - run scripts/fetch_basemap_libs.sh'));
			return;
		}
		travelBasemapStart(lat, lon);
	});
}

function travelBasemapNote(text) {
	var note = $('#travel_basemap_note');
	if (text) { note.text(text).css('display', 'flex'); }
	else { note.text('').hide(); }
}

// The local build only, the same rule the globe follows. The stylesheet is
// added once; the scripts are added once each and reused on every later open.
function travelBasemapLoad(done) {
	if (!travelBasemapCss) {
		travelBasemapCss = true;
		var link = document.createElement('link');
		link.rel = 'stylesheet';
		link.href = '/js/basemap/maplibre-gl.css';
		document.head.appendChild(link);
	}
	travelBasemapScript('/js/basemap/pmtiles.js', function() {
		if (!window.pmtiles) { done(false); return; }
		// the CSP build first: its worker is a file on this origin
		travelBasemapScript('/js/basemap/maplibre-gl-csp.js', function() {
			if (window.maplibregl) {
				try { maplibregl.setWorkerUrl('/js/basemap/maplibre-gl-csp-worker.js'); } catch (e) {}
				done(true);
				return;
			}
			// the plain build (a blob: worker, which the house policy may refuse)
			travelBasemapScript('/js/basemap/maplibre-gl.js', function() {
				done(!!window.maplibregl);
			});
		});
	});
}

function travelBasemapScript(src, done) {
	var script = document.createElement('script');
	script.src = src;
	script.onload = function() { done(); };
	script.onerror = function() {
		if (script.parentNode) { script.parentNode.removeChild(script); }
		done();
	};
	document.head.appendChild(script);
}

// A PMTiles reader is one protocol for the whole page: MapLibre throws on a
// second addProtocol for the same scheme. The pool is one worker because the
// house box has other work to do and one archive needs no more.
function travelBasemapRegister() {
	if (travelBasemapProtocol) { return; }
	travelBasemapProtocol = true;
	try { maplibregl.setWorkerCount(1); } catch (e) {}
	var protocol = new pmtiles.Protocol();
	maplibregl.addProtocol('pmtiles', protocol.tile);
}

// Widths in pixels at z14; shallower zooms narrow them so the whole county
// still reads as a road network rather than a tangle of ribbons.
function travelBasemapWidth(base) {
	return ['interpolate', ['linear'], ['zoom'], 6, base * 0.25, 10, base * 0.5, 14, base];
}

function travelBasemapStyle() {
	var road = function(id, classes, colour, width, dashed) {
		var paint = { 'line-color': colour, 'line-width': travelBasemapWidth(width) };
		if (dashed) { paint['line-dasharray'] = [2, 1.5]; }
		return {
			id: id, type: 'line', source: 'basemap', 'source-layer': 'transportation',
			filter: ['all',
				['==', ['geometry-type'], 'LineString'],
				['in', ['get', 'class'], ['literal', classes]],
				['!=', ['get', 'brunnel'], 'tunnel']],
			layout: { 'line-cap': 'round', 'line-join': 'round' },
			paint: paint
		};
	};
	var casing = function(id, classes, colour, width) {
		return {
			id: id, type: 'line', source: 'basemap', 'source-layer': 'transportation',
			filter: ['all',
				['==', ['geometry-type'], 'LineString'],
				['in', ['get', 'class'], ['literal', classes]]],
			layout: { 'line-cap': 'round', 'line-join': 'round' },
			paint: { 'line-color': colour, 'line-width': travelBasemapWidth(width) }
		};
	};

	return {
		version: 8,
		name: 'House street map',
		// no glyphs and no sprite: labels are DOM text and nothing here is a
		// third-party fetch
		sources: {
			basemap: {
				type: 'vector',
				// relative to the page origin, so the archive comes from this house
				url: 'pmtiles:///manager/travel/basemap',
				// the archive osm_basemap.pl builds is z0-z14; deeper zooms overzoom
				// z14 rather than asking for tiles it never made
				maxzoom: 14
			}
		},
		layers: [
			{ id: 'background', type: 'background',
				paint: { 'background-color': '#f6f3ec' } },
			{ id: 'landcover', type: 'fill', source: 'basemap', 'source-layer': 'landcover',
				paint: { 'fill-color': ['match', ['get', 'class'],
					['wood', 'forest'], '#d8e6c8',
					['grass', 'meadow'], '#e2ecd5',
					['farmland'], '#eef1d8',
					['sand'], '#f2e7cf',
					['ice', 'glacier'], '#eef3f6',
					'#e9e6dd'], 'fill-opacity': 0.85 } },
			{ id: 'landuse', type: 'fill', source: 'basemap', 'source-layer': 'landuse',
				paint: { 'fill-color': ['match', ['get', 'class'],
					['residential', 'suburb', 'neighbourhood', 'quarter'], '#ece8df',
					['industrial', 'commercial', 'retail', 'railway'], '#e5e1e6',
					['park', 'forest', 'wood', 'grass', 'recreation_ground', 'garden'], '#d9e7c8',
					['farmland', 'meadow', 'orchard', 'vineyard', 'allotments'], '#eaf0d5',
					['cemetery'], '#dde4d6',
					'#f0ede6'], 'fill-opacity': 0.9 } },
			{ id: 'park', type: 'fill', source: 'basemap', 'source-layer': 'park',
				paint: { 'fill-color': '#cfe3bc', 'fill-opacity': 0.8 } },
			{ id: 'water', type: 'fill', source: 'basemap', 'source-layer': 'water',
				paint: { 'fill-color': '#aac9dd' } },
			{ id: 'waterway', type: 'line', source: 'basemap', 'source-layer': 'waterway',
				layout: { 'line-cap': 'round', 'line-join': 'round' },
				paint: { 'line-color': '#aac9dd', 'line-width': ['interpolate', ['linear'], ['zoom'],
					8, 0.6, 12, 1.2, 14, 2] } },
			{ id: 'building', type: 'fill', source: 'basemap', 'source-layer': 'building',
				minzoom: 13,
				paint: { 'fill-color': '#ded6c8', 'fill-opacity': 0.9 } },

			// road casings first, then the fills: the casing is the outline a
			// road wears, so it is drawn a little wider and underneath
			casing('road-motorway-casing', ['motorway'], '#d9a55f', 8.5),
			casing('road-trunk-casing', ['trunk'], '#dbb97a', 7.5),
			casing('road-primary-casing', ['primary'], '#d9c9a8', 6.2),
			casing('road-secondary-casing', ['secondary'], '#d3cbbb', 5.2),
			casing('road-tertiary-casing', ['tertiary'], '#d8d2c6', 4.4),
			casing('road-minor-casing', ['minor', 'street', 'residential', 'unclassified', 'living_street'], '#dcd6ca', 3.4),

			road('road-motorway', ['motorway'], '#f6c98b', 5.5),
			road('road-trunk', ['trunk'], '#f8d79b', 4.7),
			road('road-primary', ['primary'], '#fbe4b4', 3.8),
			road('road-secondary', ['secondary'], '#fdf1d8', 3.1),
			road('road-tertiary', ['tertiary'], '#ffffff', 2.5),
			road('road-minor', ['minor', 'street', 'residential', 'unclassified', 'living_street'], '#ffffff', 1.8),
			road('road-service', ['service'], '#ffffff', 1.2),
			road('road-track', ['track'], '#e3d8c0', 1.1),
			road('road-path', ['path', 'footway', 'pedestrian', 'steps', 'cycleway', 'bridleway'], '#c2ac8b', 0.9, true),
			{ id: 'rail', type: 'line', source: 'basemap', 'source-layer': 'transportation',
				filter: ['all',
					['==', ['geometry-type'], 'LineString'],
					['==', ['get', 'class'], 'rail']],
				paint: { 'line-color': '#b3ada3',
					'line-width': travelBasemapWidth(1.2),
					'line-dasharray': [3, 2] } }
		]
	};
}

function travelBasemapStart(lat, lon) {
	var stage = document.getElementById('travel_basemap_stage');
	if (!stage) { return; }
	// the note stays in the stage (the template's), so only a previous map box
	// is cleared and the next open can still say what is missing
	var old = document.getElementById('travel_basemap_map');
	if (old && old.parentNode) { old.parentNode.removeChild(old); }
	if (!window.maplibregl || !window.pmtiles) {
		travelBasemapNote(jawnosT('The house\'s street map is not installed - run scripts/fetch_basemap_libs.sh'));
		return;
	}
	if (typeof travelNear3dWebgl === 'function' && !travelNear3dWebgl()) {
		travelBasemapNote(jawnosT('This browser cannot draw the map here.'));
		return;
	}
	travelBasemapRegister();

	var centre = (typeof travelNear3dCentre === 'function')
		? travelNear3dCentre(lat, lon)
		: { lat: parseFloat(lat) || 0, lon: parseFloat(lon) || 0 };
	var box = document.createElement('div');
	box.id = 'travel_basemap_map';
	box.style.cssText = 'position:absolute;inset:0;background:#f6f3ec;';
	stage.appendChild(box);

	var map;
	try {
		map = new maplibregl.Map({
			container: box,
			style: travelBasemapStyle(),
			center: [centre.lon, centre.lat],
			zoom: 15,
			// the archive stops at z14; MapLibre overzooms those tiles instead
			// of asking for ground it never built
			maxZoom: 17,
			attributionControl: false,
			// a small map in a window: the pitch and the compass are noise
			pitchWithRotate: false,
			dragRotate: false
		});
	} catch (e) {
		travelBasemapNote(jawnosT('This browser cannot draw the map here.'));
		box.parentNode.removeChild(box);
		return;
	}
	travelBasemapNote('');

	// an archive that is not staged says how to build it, rather than leaving a
	// blank stage: the 404 comes back through the source's tile requests
	var noArchive = false;
	map.on('error', function(e) {
		if (noArchive) { return; }
		var msg = (e && e.error && e.error.message) || '';
		if (e && e.sourceId === 'basemap' && /404|fetch|No basemap/i.test(msg)) {
			noArchive = true;
			travelBasemapNote(jawnosT('The house has no street map archive yet - run perl scripts/osm_basemap.pl --all'));
		}
	});

	var credit = document.createElement('div');
	credit.textContent = '© OpenStreetMap';
	credit.style.cssText = 'position:absolute;right:4px;bottom:4px;z-index:1;font:10px sans-serif;color:#555;background:rgba(255,255,255,.7);padding:1px 4px;border-radius:3px;pointer-events:none;';
	stage.appendChild(credit);

	var labels = function() { travelBasemapLabels(map); };
	map.on('idle', labels);
	map.on('moveend', labels);

	travelBasemapState = { map: map, box: box, credit: credit, markers: [], labels: labels };
}

// Place names as DOM text: the archive has no glyph atlas and the style has no
// sprite, so a symbol layer would draw nothing at all. The `place` features in
// view are deduplicated by name, best rank first, and capped so a county-wide
// view is not a wall of names.
function travelBasemapLabels(map) {
	var st = travelBasemapState;
	if (!st || st.map !== map) { return; }
	$.each(st.markers, function(i, m) { try { m.remove(); } catch (e) {} });
	st.markers = [];
	if (map.getZoom() < 10) { return; }
	var bounds = map.getBounds();
	var seen = {}, list = [];
	$.each(map.querySourceFeatures('basemap', { sourceLayer: 'place' }), function(i, f) {
		if (!f || !f.geometry || f.geometry.type != 'Point' || !f.properties) { return; }
		var name = f.properties['name:latin'] || f.properties.name;
		if (!name || seen[name]) { return; }
		var lonlat = f.geometry.coordinates;
		if (!bounds.contains([lonlat[0], lonlat[1]])) { return; }
		seen[name] = 1;
		var rank = parseInt(f.properties.rank, 10);
		list.push({ name: name, rank: isFinite(rank) ? rank : 99, lon: lonlat[0], lat: lonlat[1] });
	});
	list.sort(function(a, b) { return a.rank - b.rank; });
	$.each(list.slice(0, 40), function(i, p) {
		var el = document.createElement('div');
		el.textContent = p.name;
		el.style.cssText = 'font:12px sans-serif;color:#303030;text-shadow:0 0 3px #fff,0 0 3px #fff;white-space:nowrap;pointer-events:none;';
		var marker = new maplibregl.Marker({ element: el, anchor: 'center' })
			.setLngLat([p.lon, p.lat]).addTo(map);
		st.markers.push(marker);
	});
}

function travelBasemapClose() {
	var st = travelBasemapState;
	travelBasemapState = null;
	if (st) {
		$.each(st.markers || [], function(i, m) { try { m.remove(); } catch (e) {} });
		if (st.map) {
			// remove() stops the render loop, frees the GL context and drops the
			// worker, so reopening starts clean rather than leaving a second map
			try { st.map.off('idle', st.labels); } catch (e) {}
			try { st.map.off('moveend', st.labels); } catch (e) {}
			try { st.map.remove(); } catch (e) {}
		}
		// only the map's own box and credit go: the stage and its note belong
		// to the template and the next open needs them
		$.each([st.box, st.credit], function(i, node) {
			if (node && node.parentNode) { node.parentNode.removeChild(node); }
		});
	}
	$('#travel_basemap').hide();
	travelBasemapNote('');
}

$(document).on('click', '#travel_basemap_close', function() { travelBasemapClose(); });
$(document).on('keyup', function(e) {
	if (e.key == 'Escape' && $('#travel_basemap').is(':visible')) { travelBasemapClose(); }
});
