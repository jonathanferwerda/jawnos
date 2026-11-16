window.jawnosMap = (function () {
	'use strict';

	var TILE = 256;

	// A provider is just an XYZ template plus its zoom range and credit. Add any
	// service that speaks {z}/{x}/{y} (ArcGIS image servers use {z}/{y}/{x}).
	// `group` is the picker block: free (no key), key (paste the service's key,
	// and {key} in the template is filled from it), url (paste a whole URL).
	// `needs` says which of those two boxes the picker should show.
	// Google and Apple have no keyless tile endpoint — Google Maps needs the
	// Maps Tiles API (a key plus a session token, so not a plain template) — so
	// they are not in this table; use another service, or a keyed URL you hold.
	var providers = {
		none:  { name: 'None (offline maps only)', url: null, group: 'none' },
		osm:   { name: 'OpenStreetMap', url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', max: 19, credit: '© OpenStreetMap contributors', group: 'free' },
		topo:  { name: 'OpenTopoMap',   url: 'https://a.tile.opentopomap.org/{z}/{x}/{y}.png', max: 17, credit: '© OpenTopoMap (CC-BY-SA)', group: 'free' },
		osm_hot: { name: 'OSM Humanitarian', url: 'https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png', max: 19, credit: '© OpenStreetMap contributors, HOT', group: 'free' },
		cyclosm: { name: 'CyclOSM', url: 'https://a.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png', max: 19, credit: '© OpenStreetMap contributors, CyclOSM', group: 'free' },
		esri:  { name: 'Esri Imagery',  url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', max: 19, credit: 'Esri, Maxar, Earthstar Geographics', group: 'free' },
		esri_street: { name: 'Esri Streets', url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}', max: 19, credit: 'Esri', group: 'free' },
		esri_topo: { name: 'Esri Topo', url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}', max: 19, credit: 'Esri', group: 'free' },
		esri_light: { name: 'Esri Light', url: 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}', max: 16, credit: 'Esri', group: 'free' },
		esri_natgeo: { name: 'Esri NatGeo', url: 'https://server.arcgisonline.com/ArcGIS/rest/services/NatGeo_World_Map/MapServer/tile/{z}/{y}/{x}', max: 16, credit: 'Esri, National Geographic', group: 'free' },
		// keyed services: pick one, set its key once under Configure -> Plat -> Maps,
		// and the URL is made here — no need to assemble a template by hand
		carto: { name: 'Carto Light', url: 'https://basemaps.cartocdn.com/rastertiles/light_all/{z}/{x}/{y}.png?key={key}', max: 20, credit: '© OpenStreetMap, © CARTO', group: 'key', needs: 'key' },
		maptiler: { name: 'MapTiler', url: 'https://api.maptiler.com/maps/streets-v2/{z}/{x}/{y}.png?key={key}', max: 20, credit: '© MapTiler © OpenStreetMap', group: 'key', needs: 'key' },
		mapbox: { name: 'Mapbox', url: 'https://api.mapbox.com/styles/v1/mapbox/streets-v12/tiles/256/{z}/{x}/{y}?access_token={key}', max: 20, credit: '© Mapbox © OpenStreetMap', group: 'key', needs: 'key' },
		stadia: { name: 'Stadia Maps', url: 'https://tiles.stadiamaps.com/tiles/alidade_smooth/{z}/{x}/{y}.png?api_key={key}', max: 20, credit: '© Stadia Maps © OpenStreetMap', group: 'key', needs: 'key' },
		thunderforest: { name: 'Thunderforest', url: 'https://tile.thunderforest.com/cycle/{z}/{x}/{y}.png?apikey={key}', max: 22, credit: '© Thunderforest © OpenStreetMap', group: 'key', needs: 'key' },
		// Lambton (or any county) GIS: paste the service's tile template here. Most
		// ArcGIS REST services are .../MapServer/tile/{z}/{y}/{x} — note y before x.
		lambton: { name: 'Lambton / county GIS', url: null, max: 19, group: 'url', needs: 'url' },
		// any other service: paste its {z}/{x}/{y} template into the box next to this picker
		custom: { name: 'Custom URL', url: null, group: 'url', needs: 'url' },
		// The house's own vector basemap. `vector` says there is no tile template:
		// MapLibre draws the staged PMTiles archive in a layer behind this canvas
		// (see create()'s `vector` option), and the archive's header sets its
		// deepest zoom. It has a picker group of its own so it reads as the house's
		// map rather than as one more public street service.
		house: { name: 'House street map', url: null, max: 17, credit: '© OpenStreetMap contributors', group: 'house', vector: true }
	};

	// Web Mercator, in tiles and in world pixels at a given zoom.
	function lonToX(lon, z) { return (lon + 180) / 360 * Math.pow(2, z); }
	function latToY(lat, z) { var s = Math.sin(lat * Math.PI / 180); return (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * Math.pow(2, z); }
	function xToLon(x, z) { return x / Math.pow(2, z) * 360 - 180; }
	function yToLat(y, z) { var n = Math.PI - 2 * Math.PI * y / Math.pow(2, z); return 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n))); }
	function worldPx(lat, lon, z) { return [lonToX(lon, z) * TILE, latToY(lat, z) * TILE]; }
	function geoAt(wx, wy, z) { return { lat: yToLat(wy / TILE, z), lon: xToLon(wx / TILE, z) }; }
	// A longitude is only meaningful inside one turn of the globe. Panning and
	// fitting used to let the view's centre drift past ±180 (the tile layer wraps,
	// so the view still looked right), and that unbounded number was then saved as
	// the remembered centre: on the next open every measured map and marker was
	// projected a whole turn away and the map looked empty. Keep it in range
	// wherever the centre is set, and normalise an older saved value on the way in.
	function normLon(lon) {
		if (!isFinite(lon)) { return lon; }
		return ((((lon + 180) % 360) + 360) % 360) - 180;
	}

	// The ground bounds of a measured map: the latitude/longitude of its top-left
	// and bottom-right image pixels, from its home_plate and scale bar. North-up,
	// which is how the maps are drawn / measured.
	function mapBounds(map) {
		var p = map.home_plate || {};
		var s = map.scale || {};
		var first = s.first || {}, last = s.last || {};
		var lat0 = parseFloat(p.latitude), lon0 = parseFloat(p.longitude);
		var w = parseFloat(p.width), h = parseFloat(p.height);
		var legend = parseFloat(s.legend);
		if (!isFinite(lat0) || !isFinite(lon0) || !(w > 0) || !(h > 0) || !(legend > 0)) { return null; }
		// the scale bar was recorded in its own pixel space; bring it into the home
		// plate's before measuring (they usually match, but not always)
		var sdx = (parseFloat(s.width) > 0) ? w / parseFloat(s.width) : 1;
		var sdy = (parseFloat(s.height) > 0) ? h / parseFloat(s.height) : 1;
		var dx = (parseFloat(last.x) - parseFloat(first.x)) * sdx;
		var dy = (parseFloat(last.y) - parseFloat(first.y)) * sdy;
		var bar = Math.sqrt((dx * dx) + (dy * dy)); // the bar's pixel length
		if (!(bar > 0)) { return null; }
		var ppm = bar / legend; // image px per metre
		var mpd = 6372800 * Math.PI / 180;
		var mpdLon = mpd * Math.cos(lat0 * Math.PI / 180);
		function at(px, py) { return { lat: lat0 + ((parseFloat(p.y) - py) / ppm) / mpd, lon: lon0 + ((px - parseFloat(p.x)) / ppm) / mpdLon }; }
		return { nw: at(0, 0), se: at(w, h) };
	}

	function create(canvasId, opts) {
		opts = opts || {};
		var canvas = document.getElementById(canvasId);
		var ctx = canvas.getContext('2d');
		// own the touch gestures: without this the page would scroll/zoom instead
		try { canvas.style.touchAction = 'none'; } catch (e) {}
		// no text selection or callout on a long press: that press is the map's
		try { canvas.style.webkitTouchCallout = 'none'; canvas.style.userSelect = 'none'; } catch (e) {}
		var providerKey = opts.provider || 'none';
		var customUrl = opts.customUrl || '';
		var apiKeys = opts.keys || {};   // provider key -> the service's key
		var ZMIN = 2, ZMAX = 21;
		// The house's own vector basemap is drawn by MapLibre behind the canvas.
		// `vector` holds that second renderer (null until the chosen provider is
		// the house map), and `rasterKey` is the last raster provider chosen: the
		// map it falls back to while the vector layer loads, or when the libraries
		// or the archive are not installed. `opts.vector` supplies the loader and
		// style from the page (the Travel chunk's own, so there is one loader).
		var vector = { map: null, box: null, at: null, w: 0, h: 0, loading: false, failed: false, maxZoom: 0, token: 0 };
		var rasterKey = providers[providerKey] && providers[providerKey].vector ? 'osm' : providerKey;
		var statusNote = '';
		var destroyed = false;

		function isVectorKey(key) { return !!(providers[key] && providers[key].vector); }
		function vectorReady() { return isVectorKey(providerKey) && !!vector.map; }
		// The raster provider to draw from: the chosen one, unless the chosen one is
		// the house map and its layer is not up yet (then the previous raster, so the
		// first frames are a map rather than blank ground).
		function rasterFallback() {
			if (rasterKey && providers[rasterKey] && !providers[rasterKey].vector && rasterKey !== 'none') { return rasterKey; }
			return 'osm';
		}
		function effectiveKey() {
			if (isVectorKey(providerKey) && !vector.map) { return rasterFallback(); }
			return providerKey;
		}
		function setStatus(text) {
			statusNote = text || '';
			if (typeof opts.onStatus === 'function') { try { opts.onStatus(statusNote); } catch (e) {} }
		}
		// The deepest tile zoom the selected service actually serves; a service with
		// no stated ceiling (a pasted URL, or the offline maps only) keeps ZMAX.
		function providerMaxZ() {
			var p = providers[effectiveKey()];
			// the vector archive's ceiling is read from its header once it is
			// open; until then the provider row's conservative z17 is used. The
			// camera runs one zoom shallower than the engine, so the engine may go
			// one step past the archive's deepest zoom - that step is what asks for
			// the archive's deepest tiles at all.
			if (isVectorKey(providerKey) && vector.map) { return Math.max(ZMIN, Math.min(ZMAX, (vector.maxZoom || (p && p.max) || ZMAX) + 1)); }
			var m = (p && p.max) ? +p.max : ZMAX;
			return Math.max(ZMIN, Math.min(ZMAX, m));
		}
		function clampZ(z) { return Math.max(ZMIN, Math.min(providerMaxZ(), z)); }
		// The chosen service may stop before the engine's own ceiling (Esri Light
		// ends at 16, OpenTopoMap at 17): the initial zoom is held to it too.
		var view = {
			lat: (typeof opts.lat === 'number') ? opts.lat : 43.0,
			lon: (typeof opts.lon === 'number') ? normLon(opts.lon) : -81.94,
			z: clampZ((typeof opts.z === 'number') ? opts.z : 14)
		};
		var maps = [];        // measured maps, each with a georeference
		var points = [];      // { lat, lon, label, colour }
		var lines = [];       // runs of fixes: { colour, points: [{lat,lon}] }
		var here = null;      // the current position { lat, lon, accuracy }
		var tileCache = {};   // url -> Image (loaded) or true (loading) or null (failed)
		var tileCount = 0;    // loaded tiles held; the cache is dropped past a cap
		var imageCache = {};  // map file url -> loaded Image, so a refresh reuses it
		var changing = [];    // callbacks fired after a pan/zoom
		var drawHooks = [];   // callbacks fired after every draw (overlays on the same canvas)
		var markerHandler = null; // called with a tapped marker (a point carrying an app)
		var contextHandler = null; // called with the map under a right-click; 1 = it was handled
		var longPressHandler = null; // called with (lat, lon, sx, sy) after a still press
		var clickHandler = null; // called with the ground under a plain tap (lat, lon, sx, sy)

		function size() {
			var pw = typeof opts.width === 'function' ? opts.width() : opts.width;
			var ph = typeof opts.height === 'function' ? opts.height() : opts.height;
			var w = pw || (canvas.parentNode ? canvas.parentNode.clientWidth : 0) || 640;
			var h = ph || (canvas.parentNode ? canvas.parentNode.clientHeight : 0) || 420;
			if (canvas.width !== w) { canvas.width = w; }
			if (canvas.height !== h) { canvas.height = h; }
			return { w: w, h: h };
		}

		function originFor(v, w, h) {
			var c = worldPx(v.lat, v.lon, v.z);
			return { x: c[0] - w / 2, y: c[1] - h / 2 };
		}
		function screenFor(lat, lon, o, z) {
			var p = worldPx(lat, lon, z);
			return [p[0] - o.x, p[1] - o.y];
		}

		// Frame a latitude/longitude box: centre on it and pick the zoom whose 256px
		// tiles hold each span in the viewport (Mercator stretches latitude by
		// 1/cos(lat), so its degrees read bigger). margin > 1 backs off a little.
		function fitBox(minLat, maxLat, minLon, maxLon, margin) {
			var lat = (minLat + maxLat) / 2, lon = normLon((minLon + maxLon) / 2);
			var dim = size();
			var spanLon = Math.max(maxLon - minLon, 0.0005);
			var spanLat = Math.max(maxLat - minLat, 0.0005);
			var zLon = Math.log2((dim.w * 360) / (256 * spanLon));
			var zLat = Math.log2((dim.h * 360 * Math.cos(lat * Math.PI / 180)) / (256 * spanLat));
			var z = Math.min(zLon, zLat) - Math.log2(margin || 1.3);
			view = { lat: lat, lon: lon, z: clampZ(z) };
			draw();
		}

		function tileUrl(z, x, y) {
			var key = effectiveKey();
			if (key === 'none') { return null; } // offline: the measured maps only
			var p = providers[key];
			// a provider with no baked-in URL (Lambton, or Custom) draws from the paste box
			var tpl = (p && p.url) ? p.url : customUrl;
			if (!tpl) { return null; }
			// a keyed service draws nothing until its key is given
			if (tpl.indexOf('{key}') >= 0) {
				var apiKey = apiKeys[key] || '';
				if (!apiKey) { return null; }
				tpl = tpl.replace(/\{key\}/g, encodeURIComponent(apiKey));
			}
			return tpl.replace(/\{z\}/g, z).replace(/\{x\}/g, x).replace(/\{y\}/g, y);
		}

		function drawTiles(o, w, h) {
			if (!tileUrl(view.z | 0, 0, 0)) { return; }
			var z = Math.max(0, Math.round(view.z));
			var scale = Math.pow(2, view.z - z);
			var ts = TILE * scale;
			var x0 = Math.floor(o.x / ts), x1 = Math.floor((o.x + w) / ts);
			var y0 = Math.floor(o.y / ts), y1 = Math.floor((o.y + h) / ts);
			var n = Math.pow(2, z);
			for (var ty = y0; ty <= y1; ty++) {
				if (ty < 0 || ty >= n) { continue; }
				for (var tx = x0; tx <= x1; tx++) {
					// wrap x around the globe
					var wx = ((tx % n) + n) % n;
					var url = tileUrl(z, wx, ty);
					if (!url) { continue; }
					var sx = tx * ts - o.x, sy = ty * ts - o.y;
					var img = tileCache[url];
					if (img === true || img === null) { continue; } // in flight, or failed
					if (!img) {
						// one loader, keyed on the final URL, so the coords in url and in
						// the request are the same tile (ArcGIS is {z}/{y}/{x}, not {z}/{x}/{y})
						tileCache[url] = true;
						(function (u) {
							var im = new Image();
							im.onload = function () {
								// bound what a long pan can hold; a dropped cache just re-fetches
								if (tileCount > 600) { tileCache = {}; tileCount = 0; }
								tileCache[u] = im; tileCount++; draw();
							};
							im.onerror = function () { tileCache[u] = null; };
							im.src = u;
						})(url);
						continue;
					}
					ctx.drawImage(img, sx, sy, ts, ts);
				}
			}
		}

		function drawMaps(o, w, h, z) {
			for (var i = 0; i < maps.length; i++) {
				var m = maps[i];
				if (!m.image || !m.bounds) { continue; }
				var nw = screenFor(m.bounds.nw.lat, m.bounds.nw.lon, o, z);
				var se = screenFor(m.bounds.se.lat, m.bounds.se.lon, o, z);
				var left = Math.min(nw[0], se[0]), top = Math.min(nw[1], se[1]);
				var right = Math.max(nw[0], se[0]), bottom = Math.max(nw[1], se[1]);
				if (right < 0 || bottom < 0 || left > w || top > h) { continue; } // off-screen
				var iw = m.image.width, ih = m.image.height;
				var kx = iw > 0 ? (right - left) / iw : 1;
				var ky = ih > 0 ? (bottom - top) / ih : 1;
				ctx.save();
				ctx.globalAlpha = 0.92;
				if (m.rotate) {
					// a screenshot taken off north-up lands tilted; straighten it about its
					// home plate (a length - the scale bar - is rotation-invariant, so the
					// georeference still holds after the turn)
					var hp = m.home_plate || {};
					var hx = parseFloat(hp.x) || 0, hy = parseFloat(hp.y) || 0;
					ctx.translate(left + hx * kx, top + hy * ky);
					ctx.rotate(m.rotate * Math.PI / 180);
					try { ctx.drawImage(m.image, -hx * kx, -hy * ky, iw * kx, ih * ky); } catch (e) {}
				}
				else {
					try { ctx.drawImage(m.image, left, top, right - left, bottom - top); } catch (e) {}
				}
				ctx.restore();
				if (m.guess) {
					// a guessed map is imagination bridging measured ones: a dashed border
					// so it never passes for ground we actually measured
					ctx.save();
					ctx.setLineDash([10, 7]);
					ctx.strokeStyle = 'rgba(160,80,63,0.95)';
					ctx.lineWidth = 3;
					ctx.strokeRect(left + 1.5, top + 1.5, (right - left) - 3, (bottom - top) - 3);
					ctx.restore();
				}
				else {
					ctx.strokeStyle = 'rgba(0,0,0,0.5)';
					ctx.strokeRect(left, top, right - left, bottom - top);
				}
				ctx.font = '12px Arial';
				ctx.fillStyle = 'rgba(255,255,255,0.85)';
				ctx.fillRect(left, top, Math.max(60, ctx.measureText(m.name || '').width + 10), 16);
				ctx.fillStyle = '#000';
				ctx.fillText(m.name || '', left + 4, top + 12);
			}
		}

		function dot(x, y, r, colour) {
			ctx.beginPath();
			ctx.arc(x, y, r, 0, Math.PI * 2);
			ctx.fillStyle = colour || '#111';
			ctx.fill();
			ctx.lineWidth = 2;
			ctx.strokeStyle = '#fff';
			ctx.stroke();
		}

		function drawHome(x, y, colour) {
			ctx.save();
			ctx.fillStyle = colour || '#6f4f9f';
			ctx.strokeStyle = '#fff';
			ctx.lineWidth = 1.5;
			ctx.beginPath();
			ctx.moveTo(x - 8, y);
			ctx.lineTo(x, y - 8);
			ctx.lineTo(x + 8, y);
			ctx.closePath();
			ctx.fill();
			ctx.stroke();
			ctx.fillRect(x - 6, y, 12, 8);
			ctx.strokeRect(x - 6, y, 12, 8);
			ctx.restore();
		}

		function drawMarkers(o, w, h, z) {
			// a dense set of places (the continent knows every app) turns into a cloud of
			// labels that bury the map; keep the dots, drop the labels, and shrink them
			var many = points.length > 40;
			var r = many ? 3 : 5;
			ctx.font = '13px Arial';
			for (var i = 0; i < points.length; i++) {
				var pt = points[i];
				var s = screenFor(pt.lat, pt.lon, o, z);
				if (s[0] < -20 || s[1] < -20 || s[0] > w + 20 || s[1] > h + 20) { continue; }
				if (pt.home) {
					drawHome(s[0], s[1], pt.colour);
				}
				else if (pt.count > 1) {
					// a group in one spot: a bigger disc wearing the count, so the map
					// stays readable and the tap can unfold what is under it
					ctx.beginPath();
					ctx.arc(s[0], s[1], 11, 0, Math.PI * 2);
					ctx.fillStyle = pt.colour || '#2f6f9f';
					ctx.fill();
					ctx.lineWidth = 2;
					ctx.strokeStyle = '#fff';
					ctx.stroke();
					ctx.save();
					ctx.fillStyle = '#fff';
					ctx.font = 'bold 12px Arial';
					ctx.textAlign = 'center';
					ctx.textBaseline = 'middle';
					ctx.fillText(String(pt.count), s[0], s[1]);
					ctx.restore();
				}
				else {
					dot(s[0], s[1], r, pt.colour || '#2f6f9f');
				}
				// what can be opened keeps its name even in a crowd
				if (pt.label && (!many || pt.app || pt.plates)) { ctx.fillStyle = '#000'; ctx.fillText(pt.label, s[0] + 8, s[1] - 6); }
			}
			if (here) {
				var h2 = screenFor(here.lat, here.lon, o, z);
				ctx.save();
				ctx.beginPath();
				ctx.arc(h2[0], h2[1], 9, 0, Math.PI * 2);
				ctx.fillStyle = 'rgba(203,50,50,0.9)';
				ctx.fill();
				ctx.lineWidth = 3;
				ctx.strokeStyle = '#fff';
				ctx.stroke();
				ctx.fillStyle = '#000';
				ctx.fillText(here.label || 'You are here', h2[0] + 12, h2[1] + 4);
				ctx.restore();
			}
		}

		function drawLines(o, w, h, z) {
			if (!lines.length) { return; }
			ctx.save();
			ctx.lineJoin = 'round';
			ctx.lineCap = 'round';
			ctx.lineWidth = 2;
			ctx.globalAlpha = 0.75;
			for (var i = 0; i < lines.length; i++) {
				var line = lines[i];
				var pts = (line && line.points) || [];
				if (pts.length < 2) { continue; }
				ctx.strokeStyle = line.colour || '#a0503f';
				ctx.beginPath();
				for (var j = 0; j < pts.length; j++) {
					var s = screenFor(pts[j].lat, pts[j].lon, o, z);
					if (j === 0) { ctx.moveTo(s[0], s[1]); } else { ctx.lineTo(s[0], s[1]); }
				}
				ctx.stroke();
			}
			ctx.restore();
		}

		// ---- the house's vector basemap, behind this canvas ----

		function vectorDispose() {
			vector.token++;
			if (vector.box && vector.box.parentNode) { vector.box.parentNode.removeChild(vector.box); }
			if (vector.map) {
				// remove() stops the render loop, frees the GL context, drops the
				// worker and unbinds every listener it added
				try { vector.map.remove(); } catch (e) {}
			}
			vector.map = null; vector.box = null; vector.at = null;
			vector.w = 0; vector.h = 0; vector.loading = false; vector.maxZoom = 0;
			// the canvas was lifted above the backdrop; put it back as found
			try { canvas.style.position = ''; canvas.style.zIndex = ''; } catch (e) {}
		}

		function vectorFail(text) {
			vector.failed = true;
			vector.loading = false;
			setStatus(text || '');
		}

		// Same box as the canvas, immediately before it in the DOM and with every
		// pointer event passing through: the engine keeps the gestures.
		function vectorBuild() {
			var v = opts.vector;
			if (!v || typeof v.style !== 'function' || !canvas.parentNode) { return false; }
			var parent = canvas.parentNode;
			// the layer is absolutely positioned over the canvas, so the parent
			// must be a containing block (the Travel window already is)
			try {
				if (window.getComputedStyle && window.getComputedStyle(parent).position === 'static') {
					parent.style.position = 'relative';
				}
			} catch (e) {}
			var dim = size();
			var box = document.createElement('div');
			box.className = 'jawnos_basemap_layer';
			box.style.cssText = 'position:absolute;z-index:0;pointer-events:none;overflow:hidden;';
			parent.insertBefore(box, canvas);
			// a positioned box paints over in-flow content; the canvas is lifted
			// one layer so the plates and pins still draw on top of the basemap
			canvas.style.position = 'relative';
			canvas.style.zIndex = '1';
			// Size the box BEFORE the map exists. MapLibre 4.7 built in a
			// zero-size container never recovers: the style never finishes loading,
			// no source is added, no error fires, and a later resize() leaves it
			// wedged with a correctly sized canvas over nothing. Measured live.
			vector.box = box;
			vectorPosition(dim);
			var map;
			try {
				map = new window.maplibregl.Map({
					container: box,
					style: v.style(vector.maxZoom),
					center: [normLon(view.lon), view.lat],
					// MapLibre's world is 512 * 2^z pixels and this engine's is 256 * 2^z,
					// so one zoom shallower is the same ground scale. Vector tiles
					// re-rasterise at the size they are drawn, so the ground reads at the
					// same detail either way, and the backdrop stays exactly the canvas
					// box - a doubled one wedged the laptop's renderer.
					zoom: view.z - 1,
					// the archive's deepest zoom, not the engine's: a z17 build is
					// drawn at z17 and goes no deeper
					maxZoom: vector.maxZoom,
					// this is a backdrop, not a second map to learn: the engine
					// owns pan, zoom and every click
					interactive: false,
					attributionControl: false,
					pitchWithRotate: false,
					dragRotate: false
				});
			} catch (e) {
				if (box.parentNode) { box.parentNode.removeChild(box); }
				try { canvas.style.position = ''; canvas.style.zIndex = ''; } catch (e2) {}
				return false;
			}
			vector.map = map;
			vector.at = null;
			// the map may have measured the box before its first layout; one more
			// pass keeps the canvas and the backdrop the same size
			vectorPosition(dim);
			return true;
		}

		function vectorPosition(dim) {
			if (!vector.box) { return; }
			var s = vector.box.style;
			s.left = (canvas.offsetLeft || 0) + 'px';
			s.top = (canvas.offsetTop || 0) + 'px';
			// Exactly the canvas box, never larger. An earlier version built the
			// backdrop at twice this and scaled it by half to line MapLibre's
			// 512-pixel world up with this engine's 256-pixel one; on a laptop's
			// window at device pixel ratio 2 that is tens of millions of pixels a
			// frame, and in software GL it wedged the shared renderer so hard the
			// whole panel stopped answering. The camera is driven one zoom shallower
			// instead (see vectorBuild/vectorSync): vector tiles re-rasterise at the
			// size they are drawn, so the ground reads at the same detail for the
			// same number of pixels on screen.
			s.width = dim.w + 'px';
			s.height = dim.h + 'px';
			s.transformOrigin = '0 0';
			// the canvas may also be scaled by the page (Travel's is width:100%),
			// and the backdrop takes that same scale so the two line up exactly
			var vw = canvas.offsetWidth || 0, vh = canvas.offsetHeight || 0;
			var sx = (vw > 0 && dim.w > 0) ? vw / dim.w : 1;
			var sy = (vh > 0 && dim.h > 0) ? vh / dim.h : 1;
			s.transform = (sx !== 1 || sy !== 1) ? 'scale(' + sx + ',' + sy + ')' : '';
			if (vector.map && (vector.w !== dim.w || vector.h !== dim.h)) {
				vector.w = dim.w; vector.h = dim.h;
				try { vector.map.resize(); } catch (e) {}
			}
		}

		// The engine is the single owner of the view: every draw pushes its centre
		// and (fractional) zoom at MapLibre, which draws the ground underneath.
		function vectorSync(dim) {
			if (!vector.map) { return; }
			vectorPosition(dim);
			var at = { lat: view.lat, lon: normLon(view.lon), z: view.z };
			if (vector.at && vector.at.lat === at.lat && vector.at.lon === at.lon
				&& Math.abs(vector.at.z - at.z) < 0.0001) { return; }
			vector.at = at;
			try { vector.map.jumpTo({ center: [at.lon, at.lat], zoom: at.z - 1 }); } catch (e) {}
		}

		// Load the libraries and the archive header, then build the layer. The
		// page's own loader does the fetching and registering, so the long-press
		// view and this provider share one installed copy.
		function vectorEnsure() {
			if (vector.map || vector.loading || vector.failed || !isVectorKey(providerKey)) { return; }
			var v = opts.vector;
			if (!v || typeof v.load !== 'function') {
				vectorFail('The house\'s street map is not installed - run scripts/fetch_basemap_libs.sh');
				return;
			}
			vector.loading = true;
			var token = ++vector.token;
			var withLibraries = function () {
				if (token !== vector.token || !isVectorKey(providerKey)) { return; }
				try { if (typeof v.register === 'function') { v.register(); } } catch (e) {}
				var readMax = (typeof v.maxZoom === 'function') ? v.maxZoom : function (u, done) { done(0, true); };
				readMax(v.url || '/manager/travel/basemap', function (maxzoom, archived) {
					if (token !== vector.token || !isVectorKey(providerKey)) { return; }
					// an archive that cannot be read has no header to say how deep it
					// goes, and the layer would be a blank box
					if (archived === false) {
						vectorFail('The house has no street map archive yet - run perl scripts/osm_basemap.pl --all');
						draw();
						return;
					}
					vector.maxZoom = parseInt(maxzoom, 10) || (providers.house.max || ZMAX);
					if (!vectorBuild()) {
						vectorFail('This browser cannot draw the map here.');
						draw();
						return;
					}
					// the archive decides how deep the view may go
					view.z = clampZ(view.z);
					setStatus('');
					draw();
				});
			};
			// The long-press view may already have installed the pair. Loading it
			// again would re-execute MapLibre, and the fresh build would not have
			// the PMTiles protocol (its registration is once per page).
			if (window.maplibregl && window.pmtiles) { vector.loading = false; withLibraries(); return; }
			v.load(function (ok) {
				if (token !== vector.token || !isVectorKey(providerKey)) { return; }
				vector.loading = false;
				if (!ok || !window.maplibregl) {
					vectorFail('The house\'s street map is not installed - run scripts/fetch_basemap_libs.sh');
					draw();
					return;
				}
				withLibraries();
			});
		}

		function draw() {
			if (destroyed) { return; }
			var dim = size();
			var o = originFor(view, dim.w, dim.h);
			if (isVectorKey(providerKey)) { vectorEnsure(); }
			var vectorOn = vectorReady();
			ctx.clearRect(0, 0, dim.w, dim.h);
			// the vector layer is the background: leave the canvas transparent so
			// MapLibre shows through, and fetch no raster tile at all
			if (!vectorOn) {
				ctx.fillStyle = '#e9edf1';
				ctx.fillRect(0, 0, dim.w, dim.h);
				drawTiles(o, dim.w, dim.h);
			}
			else { vectorSync(dim); }
			drawMaps(o, dim.w, dim.h, view.z);
			drawLines(o, dim.w, dim.h, view.z);
			drawMarkers(o, dim.w, dim.h, view.z);
			var p = providers[vectorOn ? providerKey : effectiveKey()];
			var credit = (p && (p.url || p.vector)) ? p.credit : ((p && p.needs === 'url') ? 'Custom tile service' : null);
			if (credit) {
				ctx.font = '11px Arial';
				ctx.textAlign = 'right';
				ctx.fillStyle = 'rgba(0,0,0,0.6)';
				ctx.fillText(credit, dim.w - 6, dim.h - 6);
				ctx.textAlign = 'left';
			}
			// the page may paint its own furniture on this canvas (a header, the
			// clothesline rail): the clear above wiped it, so let it come back on top
			for (var i = 0; i < drawHooks.length; i++) {
				try { drawHooks[i](); } catch (e) {}
			}
		}

		// ---- interaction ----

		// Which tappable marker sits under a screen point: only points that carry an
		// app (or a list of them, a grouped marker) answer - the plain places are
		// drawn for context and do nothing. The nearest within arm's reach wins.
		function markerAt(sx, sy) {
			var dim = size();
			var o = originFor(view, dim.w, dim.h);
			var best = null, bestD = Infinity;
			for (var i = 0; i < points.length; i++) {
				var pt = points[i];
				if (!pt.app && !(pt.list && pt.list.length)) { continue; }
				var s = screenFor(pt.lat, pt.lon, o, view.z);
				var reach = (pt.count > 1) ? 26 : 16;
				var d = Math.sqrt(((s[0] - sx) * (s[0] - sx)) + ((s[1] - sy) * (s[1] - sy)));
				if (d <= reach && d < bestD) { bestD = d; best = pt; }
			}
			return best;
		}

		// Which map sits under a screen point, front to back - the draw order, so the
		// finest (or last-drawn) map wins. Null when none does.
		function mapAt(sx, sy) {
			var dim = size();
			var o = originFor(view, dim.w, dim.h);
			for (var i = maps.length - 1; i >= 0; i--) {
				var m = maps[i];
				if (!m.image || !m.bounds) { continue; }
				var nw = screenFor(m.bounds.nw.lat, m.bounds.nw.lon, o, view.z);
				var se = screenFor(m.bounds.se.lat, m.bounds.se.lon, o, view.z);
				var left = Math.min(nw[0], se[0]), top = Math.min(nw[1], se[1]);
				var right = Math.max(nw[0], se[0]), bottom = Math.max(nw[1], se[1]);
				if (sx >= left && sx <= right && sy >= top && sy <= bottom) { return m; }
			}
			return null;
		}

		function panBy(dx, dy) {
			var c = worldPx(view.lat, view.lon, view.z);
			var g = geoAt(c[0] - dx, c[1] - dy, view.z);
			view.lat = Math.max(-85, Math.min(85, g.lat));
			view.lon = normLon(g.lon);
			draw();
		}
		// zoom by dz, keeping the ground under screen point (sx,sy) pinned there
		function zoomAt(dz, sx, sy) {
			var dim = size();
			var o = originFor(view, dim.w, dim.h);
			var anchor = geoAt(o.x + sx, o.y + sy, view.z);
			var nz = clampZ(view.z + dz);
			if (nz === view.z) { return; }
			var aw = worldPx(anchor.lat, anchor.lon, nz);
			var c = geoAt(aw[0] - sx + dim.w / 2, aw[1] - sy + dim.h / 2, nz);
			view.lat = Math.max(-85, Math.min(85, c.lat));
			view.lon = normLon(c.lon);
			view.z = nz;
			draw();
			fire();
		}
		function zoomBy(dz) { view.z = clampZ(view.z + dz); draw(); fire(); }
		function fire() { for (var i = 0; i < changing.length; i++) { changing[i](view); } }

		// A page may keep a band at the top of the canvas for its own furniture (the
		// manager's clothesline rail): a gesture that starts inside it belongs to that
		// furniture, not to the map.
		function inBand(clientY) {
			if (typeof opts.ignoreTop !== 'function') { return false; }
			var band = opts.ignoreTop() || 0;
			if (!(band > 0)) { return false; }
			var r = canvas.getBoundingClientRect();
			return (clientY - r.top) < band;
		}

		// A flick glides: the release velocity carries the pan on, easing out, so a
		// throw of the map has weight instead of stopping dead - but the weight is
		// spent quickly (half a second or so), not a long coast.
		var glideFrame = null;
		function stopGlide() { if (glideFrame) { cancelAnimationFrame(glideFrame); glideFrame = null; } }
		function glide(vx, vy) {
			stopGlide();
			vx = Math.max(-55, Math.min(55, vx));
			vy = Math.max(-55, Math.min(55, vy));
			var step = function () {
				vx *= 0.86; vy *= 0.86;
				if (Math.abs(vx) < 0.4 && Math.abs(vy) < 0.4) { glideFrame = null; fire(); return; }
				panBy(vx, vy);
				glideFrame = requestAnimationFrame(step);
			};
			glideFrame = requestAnimationFrame(step);
		}
		function release(vx, vy, moved) {
			if (moved && (Math.abs(vx) > 1 || Math.abs(vy) > 1)) { glide(vx, vy); }
			else { fire(); }
		}

		// A long press asks the page for the ground under the finger (a street view,
		// a pin, a note): the press must stay still, and a press that fired keeps the
		// release from also being read as a tap or a zoom.
		var pressTimer = null, press = null, pressFired = false;
		var clickTimer = null;   // a touch tap waits to see whether a second one arrives
		function pressCancel() {
			if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; }
			press = null;
		}
		function pressStart(sx, sy) {
			pressCancel();
			pressFired = false;
			press = { x: sx, y: sy };
			pressTimer = setTimeout(function () {
				pressTimer = null;
				var p = press;
				press = null;
				pressFired = true;
				suppressClick = true;
				if (!p || !longPressHandler) { return; }
				var dim = size();
				var o = originFor(view, dim.w, dim.h);
				var g = geoAt(o.x + p.x, o.y + p.y, view.z);
				try { longPressHandler(g.lat, g.lon, p.x, p.y); } catch (e) {}
			}, 600);
		}
		function pressMove(sx, sy) {
			if (!pressTimer || !press) { return; }
			if (Math.abs(sx - press.x) > 8 || Math.abs(sy - press.y) > 8) { pressCancel(); }
		}

		// mouse: press-and-drag pans (a flick glides on release), a wheel zooms. A
		// trackpad's two-finger scroll pans too, and its pinch (ctrl+wheel) zooms. A
		// click that did not drag is a tap, and may open a marker's window.
		var drag = null;
		var suppressClick = false;
		var lastTouch = 0;
		canvas.addEventListener('mousedown', function (e) {
			if (inBand(e.clientY)) { return; }
			stopGlide();
			if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
			drag = { x: e.clientX, y: e.clientY, moved: 0, vx: 0, vy: 0 };
			suppressClick = false;
			if (e.button === 0) { pressStart(e.offsetX, e.offsetY); }
			e.preventDefault();
		});
		window.addEventListener('mousemove', function (e) {
			if (!drag) { return; }
			var dx = e.clientX - drag.x, dy = e.clientY - drag.y;
			if (dx || dy) { drag.moved = 1; }
			var r = canvas.getBoundingClientRect();
			pressMove(e.clientX - r.left, e.clientY - r.top);
			// the flick, damped, so the release can carry it on
			drag.vx = (drag.vx * 0.7) + (dx * 0.3);
			drag.vy = (drag.vy * 0.7) + (dy * 0.3);
			panBy(dx, dy);
			drag.x = e.clientX; drag.y = e.clientY;
		});
		window.addEventListener('mouseup', function () {
			if (!drag) { return; }
			pressCancel();
			var moved = drag.moved, vx = drag.vx, vy = drag.vy;
			suppressClick = (moved || pressFired) ? true : false;
			drag = null;
			release(vx, vy, moved);
		});
		canvas.addEventListener('mousemove', function (e) {
			if (drag) { return; }
			var pt = markerHandler ? markerAt(e.offsetX, e.offsetY) : null;
			canvas.style.cursor = pt ? 'pointer' : '';
		});

		canvas.addEventListener('click', function (e) {
			if (suppressClick) { suppressClick = false; return; }
			if (Date.now() - lastTouch < 500) { return; } // the touch tap already answered
			var pt = markerHandler ? markerAt(e.offsetX, e.offsetY) : null;
			if (pt) { markerHandler(pt, e.offsetX, e.offsetY); return; }
			fireMapClick(e.offsetX, e.offsetY);
		});

		// A plain tap asks the page for the ground under it (the pictures taken
		// there); a marker still wins, and a touch tap waits a moment so a
		// double-tap can still be read as a zoom.
		function fireMapClick(sx, sy) {
			if (!clickHandler) { return; }
			var dim = size();
			var o = originFor(view, dim.w, dim.h);
			var g = geoAt(o.x + sx, o.y + sy, view.z);
			try { clickHandler(g.lat, g.lon, sx, sy); } catch (e) {}
		}

		// A right-click on a map: the topmost one under the point goes to the page,
		// which decides (a guessed gap offers to be dropped). Only when the page says
		// it handled it is the event consumed - everywhere else the desktop's own
		// menus still open over the map.
		canvas.addEventListener('contextmenu', function (e) {
			// a touch long press raises the browser's own menu before ours fires;
			// swallow it and let the press through (a mouse right-click has no press)
			if (pressTimer || pressFired) { e.preventDefault(); return; }
			if (inBand(e.clientY)) { return; }
			if (!contextHandler) { return; }
			var r = canvas.getBoundingClientRect();
			var pt = mapAt(e.clientX - r.left, e.clientY - r.top);
			if (!pt) { return; }
			if (contextHandler(pt, e.clientX - r.left, e.clientY - r.top)) {
				e.preventDefault();
				e.stopPropagation();
			}
		});

		canvas.addEventListener('wheel', function (e) {
			if (inBand(e.clientY)) { return; }
			e.preventDefault();
			var dy = e.deltaY || 0;
			if (!dy) { return; } // a sideways-only scroll does nothing
			// the zoom follows the wheel's own size: a mouse notch (~100px) is a gentle
			// step, while a trackpad's many small deltas crawl - the old fixed step let
			// a trackpad flick race through the zooms
			if (e.deltaMode === 1) { dy *= 16; }
			else if (e.deltaMode === 2) { dy *= 100; }
			var dz = Math.max(-0.3, Math.min(0.3, -dy * 0.0015));
			if (!dz) { return; }
			stopGlide();
			zoomAt(dz, e.offsetX, e.offsetY);
		}, { passive: false });

		// touch: one finger pans, two fingers pinch, a double-tap zooms in
		var touch = null;   // one-finger drag
		var pinch = null;   // two-finger pinch
		var lastTap = 0, tapAt = null;
		function touchMid(t) {
			return { x: (t[0].clientX + t[1].clientX) / 2, y: (t[0].clientY + t[1].clientY) / 2,
				d: Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY) };
		}
		canvas.addEventListener('touchstart', function (e) {
			if (inBand(e.touches[0].clientY)) { return; }
			stopGlide();
			if (e.touches.length >= 2) {
				pinch = touchMid(e.touches); touch = null;
			}
			else {
				touch = { x: e.touches[0].clientX, y: e.touches[0].clientY, moved: 0, vx: 0, vy: 0 };
				if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
				var tr = canvas.getBoundingClientRect();
				pressStart(e.touches[0].clientX - tr.left, e.touches[0].clientY - tr.top);
			}
		}, { passive: true });
		canvas.addEventListener('touchmove', function (e) {
			if (e.touches.length >= 2) {
				if (!pinch) { return; }
				var m = touchMid(e.touches);
				if (m.d > 0 && pinch.d > 0) {
					var r = canvas.getBoundingClientRect();
					panBy(m.x - pinch.x, m.y - pinch.y);
					zoomAt(Math.log(m.d / pinch.d) / Math.LN2, m.x - r.left, m.y - r.top);
				}
				pinch = m;
				e.preventDefault();
			}
			else if (touch) {
				var t0 = e.touches[0];
				var dx = t0.clientX - touch.x, dy = t0.clientY - touch.y;
				touch.vx = (touch.vx * 0.7) + (dx * 0.3);
				touch.vy = (touch.vy * 0.7) + (dy * 0.3);
				var mr = canvas.getBoundingClientRect();
				pressMove(t0.clientX - mr.left, t0.clientY - mr.top);
				panBy(dx, dy);
				touch.x = t0.clientX; touch.y = t0.clientY; touch.moved = 1;
				e.preventDefault();
			}
		}, { passive: false });
		canvas.addEventListener('touchend', function (e) {
			if (e.touches.length > 0) { return; }
			lastTouch = Date.now();
			var fired = pressFired;
			pressCancel();
			var tapped = false;
			// a tap that lands on a marker opens it at once; anywhere else, two
			// quick taps with no drag between zoom in one step
			if (touch && !touch.moved && !fired) {
				var r = canvas.getBoundingClientRect();
				var pt = markerHandler ? markerAt(touch.x - r.left, touch.y - r.top) : null;
				if (pt) {
					markerHandler(pt, touch.x - r.left, touch.y - r.top);
					tapAt = null; lastTap = 0; tapped = true;
				}
				else {
					var now = Date.now();
					if (tapAt && now - lastTap < 300) {
						if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
						zoomAt(1, touch.x - r.left, touch.y - r.top);
						tapAt = null;
					}
					else {
						tapAt = { x: touch.x, y: touch.y };
						if (clickTimer) { clearTimeout(clickTimer); }
						var sx = touch.x - r.left, sy = touch.y - r.top;
						clickTimer = setTimeout(function() {
							clickTimer = null;
							fireMapClick(sx, sy);
						}, 300);
					}
					lastTap = now;
				}
			}
			var moved = touch ? touch.moved : 0, vx = touch ? touch.vx : 0, vy = touch ? touch.vy : 0;
			touch = null; pinch = null;
			pressFired = false;
			// a marker tap already answered: firing here would hide the list it
			// just unfolded
			if (!tapped) { release(vx, vy, moved); }
		});

		var api = {
			providers: providers,
			canvas: canvas,
			draw: draw,
			zoom: zoomBy,
			setZoom: function (z) { view.z = clampZ(z); draw(); },
			center: function (lat, lon) { view.lat = lat; view.lon = normLon(lon); draw(); },
			setProvider: function (key, url, keys) {
				var nextUrl = (url === undefined || url === null) ? customUrl : url;
				var nextKeys = (keys && typeof keys === 'object') ? keys : apiKeys;
				if (key === providerKey && nextUrl === customUrl && JSON.stringify(nextKeys) === JSON.stringify(apiKeys)) {
					// a render after a failed vector start re-states why it fell back
					if (isVectorKey(providerKey)) { setStatus(statusNote); }
					return;
				}
				// switching away from the house map lets go of its GL context, its
				// worker, its listeners and its box; the raster path is then exactly
				// what every other provider already had
				if (isVectorKey(providerKey) && key !== providerKey) { vectorDispose(); }
				if (!isVectorKey(key)) { rasterKey = key; }
				// choosing the house map afresh is also a retry: libraries or an
				// archive installed since the last look may be there now
				if (isVectorKey(key)) { vector.failed = false; setStatus(''); }
				providerKey = key;
				customUrl = nextUrl;
				apiKeys = nextKeys;
				// a service with a lower ceiling than the last one cannot be drawn past
				// its deepest tile, so the view backs up to the new limit
				view.z = clampZ(view.z);
				tileCache = {};
				tileCount = 0;
				draw();
			},
			// Drop the backdrop renderer; a page closing its window (or replacing
			// this canvas) calls this so no MapLibre map outlives its stage. A late
			// image load or timer must not put a layer back on a torn-down engine.
			destroy: function () { destroyed = true; vectorDispose(); setStatus(''); },
			setMaps: function (list) {
				maps = [];
				(list || []).forEach(function (m) {
					var b = mapBounds(m);
					if (!b) { return; }
					var entry = { name: m.name, file: m.file, uuid: m.uuid, bounds: b, home_plate: m.home_plate, rotate: parseFloat(m.rotate) || 0, guess: m.guessed ? 1 : 0 };
					// how much ground the map covers, so the draw can put the finest
					// (smallest footprint) on top: panning into a neighbourhood must not
					// leave the town-wide map covering the detailed one
					entry.span = Math.max(Math.abs(b.nw.lat - b.se.lat), Math.abs(b.se.lon - b.nw.lon));
					maps.push(entry);
					if (imageCache[m.file]) {
						entry.image = imageCache[m.file];
					}
					else {
						(function (e) {
							var im = new Image();
							im.onload = function () { e.image = im; imageCache[e.file] = im; draw(); };
							im.src = e.file;
						})(entry);
					}
				});
				maps.sort(function (a, b) {
					// a guess lies under every measured map (it may only show where
					// nothing is known); among each kind the finest stays on top
					if (a.guess != b.guess) { return a.guess ? -1 : 1; }
					return b.span - a.span;
				});
				draw();
			},
			setPoints: function (list) { points = list || []; draw(); },
			setLines: function (list) { lines = list || []; draw(); },
			setPosition: function (pos) { here = pos || null; draw(); },
			maps: function () { return maps; },
			lines: function () { return lines; },
			points: function () { return points; },
			// Frame the measured maps (their home plates), else keep the centre.
			fitToMaps: function () {
				var lats = [], lons = [];
				maps.forEach(function (m) { lats.push(m.bounds.nw.lat, m.bounds.se.lat); lons.push(m.bounds.nw.lon, m.bounds.se.lon); });
				if (here) { lats.push(here.lat); lons.push(here.lon); }
				if (!lats.length) { return; }
				fitBox(Math.min.apply(null, lats), Math.max.apply(null, lats), Math.min.apply(null, lons), Math.max.apply(null, lons), 1.3);
			},
			// Frame a ground box ({ nw, se }) - a measured map's own bounds, from
			// jawnosMap.mapBounds(m) - so choosing it brings it into view.
			fitBounds: function (bounds, margin) {
				if (!bounds || !bounds.nw || !bounds.se) { return; }
				fitBox(bounds.se.lat, bounds.nw.lat, bounds.nw.lon, bounds.se.lon, margin || 1.15);
			},
			// The ground the viewport is showing, as a { nw, se } box - the map's
			// view, so a guess can be asked for exactly what is on screen.
			viewBounds: function () {
				var dim = size();
				var o = originFor(view, dim.w, dim.h);
				return { nw: geoAt(o.x, o.y, view.z), se: geoAt(o.x + dim.w, o.y + dim.h, view.z) };
			},
			// Frame a point: the tightest measured map that covers it (so the local map
			// is legible), but never closer than minSpan degrees, else just minSpan.
			focusOn: function (lat, lon, minSpan) {
				minSpan = minSpan || 0.02; // ~2 km of latitude
				var bestSpan = Infinity;
				maps.forEach(function (m) {
					var b = m.bounds;
					if (lat >= b.se.lat && lat <= b.nw.lat && lon >= b.nw.lon && lon <= b.se.lon) {
						var span = Math.max(b.nw.lat - b.se.lat, b.se.lon - b.nw.lon);
						if (span < bestSpan) { bestSpan = span; }
					}
				});
				var span = Math.max(bestSpan === Infinity ? 0 : bestSpan, minSpan);
				var h = span / 2;
				fitBox(lat - h, lat + h, lon - h, lon + h, 1.15);
			},
			onMarkerClick: function (fn) { markerHandler = fn; },
			onMapClick: function (fn) { clickHandler = fn; },
			onLongPress: function (fn) { longPressHandler = fn; },
			onMapContext: function (fn) { contextHandler = fn; },
			onDraw: function (fn) { drawHooks.push(fn); },
			onChange: function (fn) { changing.push(fn); },
			// A page that paints its own furniture (a flag, a crosshair) needs the
			// same projection the engine uses for its markers.
			project: function (lat, lon) {
				var dim = size();
				var o = originFor(view, dim.w, dim.h);
				return screenFor(lat, lon, o, view.z);
			},
			view: function () { return { lat: view.lat, lon: normLon(view.lon), z: view.z }; }
		};
		return api;
	}

	return { create: create, providers: providers, mapBounds: mapBounds };
})();
