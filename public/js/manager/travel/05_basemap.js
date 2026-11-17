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
var travelBasemapProtocolHost = null;   // which maplibregl got the pmtiles protocol
var travelBasemapRan = {};              // script src -> already executed

function travelBasemapOpen(lat, lon) {
	// one layer at a time: opening this closes the other two
	if (typeof travelNear3dClose === 'function') { travelNear3dClose(); }
	if (typeof travelGlobeClose === 'function') { travelGlobeClose(); }
	if (typeof travelWorldClose === 'function') { travelWorldClose(); }
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
			travelBasemapNote(jawnosT('The house\'s street map is not installed - run scripts/fetch_basemap_libs.sh'), 'basemap');
			return;
		}
		travelBasemapStart(lat, lon);
	});
}

function travelBasemapNote(text, lib) {
	var note = $('#travel_basemap_note');
	if (text) {
		note.empty().css('display', 'flex').append($('<span>').text(text));
		if (lib) { travelLibInstallButton(note, lib); }
	}
	else { note.empty().hide(); }
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
	// Once per page. Appending the tag again re-executes the library, which
	// replaces window.maplibregl with a fresh instance whose protocol registry is
	// empty - and a later register() would then be skipped as "already done",
	// leaving a map that asks for pmtiles:// and gets nothing back.
	if (travelBasemapRan[src]) { done(); return; }
	travelBasemapRan[src] = true;
	var script = document.createElement('script');
	script.src = src;
	script.onload = function() { done(); };
	script.onerror = function() {
		// let a later open try again rather than pin the failure
		travelBasemapRan[src] = false;
		if (script.parentNode) { script.parentNode.removeChild(script); }
		done();
	};
	document.head.appendChild(script);
}

// A PMTiles reader is one protocol for the whole page: MapLibre throws on a
// second addProtocol for the same scheme. The pool is one worker because the
// house box has other work to do and one archive needs no more. The flag
// remembers WHICH MapLibre instance it was registered on, so a library that was
// replaced under us gets the protocol again instead of silently losing it.
function travelBasemapRegister() {
	if (travelBasemapProtocol && travelBasemapProtocolHost === window.maplibregl) { return; }
	travelBasemapProtocol = true;
	travelBasemapProtocolHost = window.maplibregl;
	try { maplibregl.setWorkerCount(1); } catch (e) {}
	var protocol = new pmtiles.Protocol();
	maplibregl.addProtocol('pmtiles', protocol.tile);
}

// Widths in pixels at z14; shallower zooms narrow them so the whole county
// still reads as a road network rather than a tangle of ribbons.
function travelBasemapWidth(base) {
	return ['interpolate', ['linear'], ['zoom'], 6, base * 0.25, 10, base * 0.5, 14, base];
}

// The archive's own header says how deep it was built. osm_basemap.pl cuts the
// extract at whatever zoom it is given - 14 when this view was written, 17 for
// the newer builds - so the deepest zoom is read from the staged archive rather
// than pinned here, and a rebuilt archive needs no code change. The read is one
// small range request; 14 is the fallback for an archive that cannot be read at
// all, which is the shallowest range the builder has ever produced.
var TRAVEL_BASEMAP_DEFAULT_MAXZOOM = 14;

// done(maxZoom, read): the second argument says whether the archive actually
// answered. The long-press view only wants the number; the map engine also
// needs to know a missing or unreadable archive, so it can fall back to a
// raster provider instead of drawing an empty box.
function travelBasemapMaxZoom(url, done) {
	var settled = false;
	var read = false;
	var finish = function(z) {
		if (settled) { return; }
		settled = true;
		var n = parseInt(z, 10);
		if (!(isFinite(n) && n > 0)) { read = false; }
		done(isFinite(n) && n > 0 ? n : TRAVEL_BASEMAP_DEFAULT_MAXZOOM, read);
	};
	var archive;
	try { archive = new pmtiles.PMTiles(url); } catch (e) { finish(0); return; }
	// a header read that hangs must not leave the stage blank for ever
	var timer = setTimeout(function() { finish(0); }, 8000);
	try {
		archive.getHeader().then(function(header) {
			clearTimeout(timer);
			read = !!(header && header.maxZoom);
			finish(header && header.maxZoom);
		}, function() {
			clearTimeout(timer);
			finish(0);
		});
	} catch (e) {
		clearTimeout(timer);
		finish(0);
	}
}

function travelBasemapStyle(maxzoom, three_d) {
	// the fallback keeps a direct caller (or a header read that failed) on the
	// shallowest archive the builder makes
	if (!(parseInt(maxzoom, 10) > 0)) { maxzoom = TRAVEL_BASEMAP_DEFAULT_MAXZOOM; }
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

	var style = {
		version: 8,
		name: 'House street map',
		// no glyphs and no sprite: labels are DOM text and nothing here is a
		// third-party fetch
		sources: {
			basemap: {
				type: 'vector',
				// relative to the page origin, so the archive comes from this house
				url: 'pmtiles:///manager/travel/basemap',
				// read from the archive's header, so a z17 build is drawn at z17
				// instead of overzooming a blur of z14 tiles
				maxzoom: maxzoom
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

	// The map engine's backdrop uses this same style, and there it must stay
	// flat: a building standing up under a measured plate would hide the ground
	// the plate is showing. Only the long-press view asks for three_d.
	if (three_d) {
		var at = 0;
		for (var i = 0; i < style.layers.length; i++) {
			if (style.layers[i].id === 'building') { at = i + 1; break; }
		}
		style.layers.splice(at, 0, {
			id: 'building-3d', type: 'fill-extrusion', source: 'basemap', 'source-layer': 'building',
			minzoom: 14,
			paint: {
				// the archive's OpenMapTiles profile writes render_height and
				// render_min_height; a tile without them still gets a low solid
				// rather than a paper cut-out
				'fill-extrusion-height': ['to-number', ['get', 'render_height'], 6],
				'fill-extrusion-base': ['to-number', ['get', 'render_min_height'], 0],
				'fill-extrusion-color': ['interpolate', ['linear'], ['to-number', ['get', 'render_height'], 6],
					0, '#e3dbcd', 8, '#ddd3c2', 20, '#d3c6b1', 60, '#c7b79e'],
				'fill-extrusion-opacity': 0.9
			}
		});
	}
	return style;
}

function travelBasemapStart(lat, lon) {
	var stage = document.getElementById('travel_basemap_stage');
	if (!stage) { return; }
	// the note stays in the stage (the template's), so only a previous map box
	// is cleared and the next open can still say what is missing
	var old = document.getElementById('travel_basemap_map');
	if (old && old.parentNode) { old.parentNode.removeChild(old); }
	if (!window.maplibregl || !window.pmtiles) {
		travelBasemapNote(jawnosT('The house\'s street map is not installed - run scripts/fetch_basemap_libs.sh'), 'basemap');
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

	// the box exists before the header is read, so a close during that read
	// still has a state (and a box) to let go of
	var st = { map: null, box: box, credit: null, markers: [], labels: null, watchdog: null };
	travelBasemapState = st;
	travelBasemapNote(jawnosT('Opening the house\'s street map…'));

	travelBasemapMaxZoom('/manager/travel/basemap', function(maxzoom) {
		// closed, or reopened, while the header was in flight
		if (travelBasemapState !== st) { return; }
		travelBasemapDraw(st, centre, maxzoom);
	});
}

function travelBasemapDraw(st, centre, maxzoom) {
	var box = st.box, stage = box.parentNode;
	var map;
	try {
		map = new maplibregl.Map({
			container: box,
			style: travelBasemapStyle(maxzoom, true),
			center: [centre.lon, centre.lat],
			zoom: Math.min(15, maxzoom),
			// the archive's deepest zoom is the archive's, not this file's: the
			// zoom control stops where the tiles stop
			maxZoom: maxzoom,
			attributionControl: false,
			// the town has height, so the view opens tilted and the buildings
			// stand up; the right button (or two fingers) turns and tilts it
			pitch: 45,
			maxPitch: 60,
			pitchWithRotate: true,
			dragRotate: true,
			touchPitch: true
		});
	} catch (e) {
		travelBasemapNote(jawnosT('This browser cannot draw the map here.'));
		if (box.parentNode) { box.parentNode.removeChild(box); }
		return;
	}
	travelBasemapNote('');

	// A map that errors before it draws never says so by itself: the usual cause
	// is the browser refusing MapLibre's worker (a blob: worker when only the
	// plain build is installed, which the house CSP does not allow) and the
	// stage just stays blank. Name the cause and the fix, and let the note go the
	// moment the map has drawn. The raw error still reaches the console.
	var note = function(text) { travelBasemapNote(text); };
	var noArchive = false, drawn = false, dataSeen = false;
	var failure = function() {
		note(jawnosT('The street map could not start - the browser blocked MapLibre\'s worker or the library is incomplete. Run scripts/fetch_basemap_libs.sh, then open it again.'));
	};
	var stopWatchdog = function() {
		if (st.watchdog) { clearTimeout(st.watchdog); st.watchdog = null; }
	};
	// A worker refused before any error surfaces leaves no event behind, so the
	// stage is given time to draw before the failure is named. Twenty seconds,
	// not eight: a phone on the wireless takes longer than a desktop on the
	// wire, and a false "could not start" is worse than a late one.
	st.watchdog = setTimeout(function() {
		if (!drawn && !noArchive && !dataSeen) { failure(); }
	}, 20000);

	// Any source traffic at all is the worker and the archive answering, so the
	// watchdog stops there rather than waiting for a whole first frame.
	map.on('sourcedata', function() {
		if (dataSeen) { return; }
		dataSeen = true;
		stopWatchdog();
	});

	// The windows on this panel are DOM elements dragged and sized inside the
	// page, so the browser never fires a window resize: a map built before the
	// window is laid out (or one resized after) keeps a stale canvas and shows a
	// blank band. Watch the box itself.
	var resize = function() { try { map.resize(); } catch (e) {} };
	st.resize = resize;
	window.addEventListener('resize', resize);
	if (window.ResizeObserver) {
		st.observer = new ResizeObserver(resize);
		st.observer.observe(box);
	}
	resize();

	map.on('load', function() {
		drawn = true;
		stopWatchdog();
		if (!noArchive) { note(''); }
	});

	// an archive that is not staged says how to build it, rather than leaving a
	// blank stage: the 404 comes back through the source's requests
	map.on('error', function(e) {
		try { console.error('Travel street map:', (e && e.error) || e); } catch (err) {}
		if (noArchive || drawn) { return; }
		var msg = (e && e.error && e.error.message) || '';
		if (e && e.sourceId === 'basemap' && /404|fetch|No basemap/i.test(msg)) {
			noArchive = true;
			stopWatchdog();
			note(jawnosT('The house has no street map archive yet - run perl scripts/osm_basemap.pl --all'));
			return;
		}
		stopWatchdog();
		failure();
	});

	var credit = document.createElement('div');
	credit.textContent = '© OpenStreetMap';
	credit.style.cssText = 'position:absolute;right:4px;bottom:4px;z-index:1;font:10px sans-serif;color:#555;background:rgba(255,255,255,.7);padding:1px 4px;border-radius:3px;pointer-events:none;';
	stage.appendChild(credit);

	var labels = function() { travelBasemapLabels(map); };
	map.on('idle', labels);
	map.on('moveend', labels);

	st.map = map;
	st.credit = credit;
	st.labels = labels;
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
		// the draw watchdog belongs to this open, not to the next one
		if (st.watchdog) { clearTimeout(st.watchdog); st.watchdog = null; }
		if (st.observer) { try { st.observer.disconnect(); } catch (e) {} }
		if (st.resize) { window.removeEventListener('resize', st.resize); }
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
