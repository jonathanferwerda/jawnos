// jawnosMap: a small, dependency-free canvas map.
//
// A viewport — a centre latitude/longitude and a fractional zoom — drawn bottom
// to top as:
//   * a tile layer from a named provider (any {z}/{x}/{y} service), and
//   * your own measured maps, each placed by the georeference it carries (a
//     home_plate pixel sitting at a latitude/longitude, plus a scale bar giving
//     the ground metres between two pixels). Pan to a new area and whichever of
//     them covers it scrolls into view — that is "load the other maps we have".
//   * markers: the continent points, and the machine's current position.
//
// Drag to pan; a wheel or a pinch zooms (a trackpad's two-finger scroll zooms too),
// and a double-tap zooms in. With no provider chosen it fetches nothing and the
// measured maps are all it needs, so it stays usable offline; the tile layer is the
// online bonus.
//
// Everything is plain JS and jQuery-free; the page's own jQuery is not required.

window.jawnosMap = (function () {
	'use strict';

	var TILE = 256;

	// A provider is just an XYZ template plus its zoom range and credit. Add any
	// service that speaks {z}/{x}/{y} (ArcGIS image servers use {z}/{y}/{x}).
	// Google and Apple have no keyless tile endpoint — wire them through their own
	// SDKs or a keyed URL — so the escape hatch here is "Custom URL" in the UI.
	var providers = {
		none:  { name: 'None (offline maps only)', url: null },
		osm:   { name: 'OpenStreetMap', url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', max: 19, credit: '© OpenStreetMap contributors' },
		topo:  { name: 'OpenTopoMap',   url: 'https://a.tile.opentopomap.org/{z}/{x}/{y}.png', max: 17, credit: '© OpenTopoMap (CC-BY-SA)' },
		carto: { name: 'Carto Light',   url: 'https://a.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png', max: 20, credit: '© OpenStreetMap, © CARTO' },
		esri:  { name: 'Esri Imagery',  url: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', max: 19, credit: 'Esri, Maxar, Earthstar Geographics' },
		// Lambton (or any county) GIS: paste the service's tile template here. Most
		// ArcGIS REST services are .../MapServer/tile/{z}/{y}/{x} — note y before x.
		lambton: { name: 'Lambton GIS', url: null, max: 19, credit: 'County of Lambton' },
		// any other service: paste its {z}/{x}/{y} template into the box next to this picker
		custom: { name: 'Custom URL', url: null }
	};

	// Web Mercator, in tiles and in world pixels at a given zoom.
	function lonToX(lon, z) { return (lon + 180) / 360 * Math.pow(2, z); }
	function latToY(lat, z) { var s = Math.sin(lat * Math.PI / 180); return (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * Math.pow(2, z); }
	function xToLon(x, z) { return x / Math.pow(2, z) * 360 - 180; }
	function yToLat(y, z) { var n = Math.PI - 2 * Math.PI * y / Math.pow(2, z); return 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n))); }
	function worldPx(lat, lon, z) { return [lonToX(lon, z) * TILE, latToY(lat, z) * TILE]; }
	function geoAt(wx, wy, z) { return { lat: yToLat(wy / TILE, z), lon: xToLon(wx / TILE, z) }; }

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
		var view = { lat: opts.lat || 43.0, lon: opts.lon || -81.94, z: opts.z || 14 };
		var maps = [];        // measured maps, each with a georeference
		var points = [];      // { lat, lon, label, colour }
		var here = null;      // the current position { lat, lon, accuracy }
		var providerKey = opts.provider || 'none';
		var customUrl = opts.customUrl || '';
		var tileCache = {};   // url -> Image (loaded) or true (loading) or null (failed)
		var tileCount = 0;    // loaded tiles held; the cache is dropped past a cap
		var imageCache = {};  // map file url -> loaded Image, so a refresh reuses it
		var changing = [];    // callbacks fired after a pan/zoom
		var markerHandler = null; // called with a tapped marker (a point carrying an app)

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
			var lat = (minLat + maxLat) / 2, lon = (minLon + maxLon) / 2;
			var dim = size();
			var spanLon = Math.max(maxLon - minLon, 0.0005);
			var spanLat = Math.max(maxLat - minLat, 0.0005);
			var zLon = Math.log2((dim.w * 360) / (256 * spanLon));
			var zLat = Math.log2((dim.h * 360 * Math.cos(lat * Math.PI / 180)) / (256 * spanLat));
			var z = Math.min(zLon, zLat) - Math.log2(margin || 1.3);
			view = { lat: lat, lon: lon, z: Math.max(2, Math.min(21, z)) };
			draw();
		}

		function tileUrl(z, x, y) {
			if (providerKey === 'none') { return null; } // offline: the measured maps only
			var p = providers[providerKey];
			// a provider with no baked-in URL (Lambton, or Custom) draws from the paste box
			var tpl = (p && p.url) ? p.url : customUrl;
			if (!tpl) { return null; }
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
				ctx.strokeStyle = 'rgba(0,0,0,0.5)';
				ctx.strokeRect(left, top, right - left, bottom - top);
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
				if (pt.count > 1) {
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

		function draw() {
			var dim = size();
			var o = originFor(view, dim.w, dim.h);
			ctx.clearRect(0, 0, dim.w, dim.h);
			ctx.fillStyle = '#e9edf1';
			ctx.fillRect(0, 0, dim.w, dim.h);
			drawTiles(o, dim.w, dim.h);
			drawMaps(o, dim.w, dim.h, view.z);
			drawMarkers(o, dim.w, dim.h, view.z);
			var p = providers[providerKey];
			var credit = (providerKey === 'custom') ? 'Custom URL' : (p && p.credit);
			if (credit) {
				ctx.font = '11px Arial';
				ctx.textAlign = 'right';
				ctx.fillStyle = 'rgba(0,0,0,0.6)';
				ctx.fillText(credit, dim.w - 6, dim.h - 6);
				ctx.textAlign = 'left';
			}
		}

		// ---- interaction ----
		var ZMIN = 2, ZMAX = 21;
		function clampZ(z) { return Math.max(ZMIN, Math.min(ZMAX, z)); }

		// Which tappable marker sits under a screen point: only points that carry an
		// app (or a list of them, a grouped marker) answer - the plain places are
		// drawn for context and do nothing. The nearest within arm's reach wins.
		function markerAt(sx, sy) {
			var dim = size();
			var o = originFor(view, dim.w, dim.h);
			var best = null, bestD = Infinity;
			for (var i = 0; i < points.length; i++) {
				var pt = points[i];
				if (!pt.app && !(pt.plates && pt.plates.length)) { continue; }
				var s = screenFor(pt.lat, pt.lon, o, view.z);
				var reach = (pt.count > 1) ? 20 : 14;
				var d = Math.sqrt(((s[0] - sx) * (s[0] - sx)) + ((s[1] - sy) * (s[1] - sy)));
				if (d <= reach && d < bestD) { bestD = d; best = pt; }
			}
			return best;
		}

		function panBy(dx, dy) {
			var c = worldPx(view.lat, view.lon, view.z);
			var g = geoAt(c[0] - dx, c[1] - dy, view.z);
			view.lat = Math.max(-85, Math.min(85, g.lat));
			view.lon = g.lon;
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
			view.lon = c.lon;
			view.z = nz;
			draw();
		}
		function zoomBy(dz) { view.z = clampZ(view.z + dz); draw(); }
		function fire() { for (var i = 0; i < changing.length; i++) { changing[i](view); } }

		// mouse: press-and-drag pans, a wheel zooms. A trackpad's two-finger scroll
		// pans too, and its pinch (ctrl+wheel) zooms. A click that did not drag is a
		// tap, and may open a marker's window.
		var drag = null;
		var suppressClick = false;
		var lastTouch = 0;
		canvas.addEventListener('mousedown', function (e) { drag = { x: e.clientX, y: e.clientY, moved: 0 }; suppressClick = false; e.preventDefault(); });
		window.addEventListener('mousemove', function (e) {
			if (!drag) { return; }
			if (e.clientX !== drag.x || e.clientY !== drag.y) { drag.moved = 1; }
			panBy(e.clientX - drag.x, e.clientY - drag.y);
			drag.x = e.clientX; drag.y = e.clientY;
		});
		window.addEventListener('mouseup', function () { if (drag) { suppressClick = drag.moved ? true : false; drag = null; fire(); } });
		canvas.addEventListener('click', function (e) {
			if (suppressClick) { suppressClick = false; return; }
			if (Date.now() - lastTouch < 500) { return; } // the touch tap already answered
			if (!markerHandler) { return; }
			var pt = markerAt(e.offsetX, e.offsetY);
			if (pt) { markerHandler(pt, e.offsetX, e.offsetY); }
		});

		canvas.addEventListener('wheel', function (e) {
			e.preventDefault();
			var dy = e.deltaY || 0;
			if (!dy) { return; } // a sideways-only scroll does nothing
			zoomAt(dy < 0 ? 0.4 : -0.4, e.offsetX, e.offsetY);
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
			if (e.touches.length >= 2) {
				pinch = touchMid(e.touches); touch = null;
			}
			else {
				touch = { x: e.touches[0].clientX, y: e.touches[0].clientY, moved: 0 };
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
				panBy(t0.clientX - touch.x, t0.clientY - touch.y);
				touch.x = t0.clientX; touch.y = t0.clientY; touch.moved = 1;
				e.preventDefault();
			}
		}, { passive: false });
		canvas.addEventListener('touchend', function (e) {
			if (e.touches.length > 0) { return; }
			lastTouch = Date.now();
			// a tap that lands on a marker opens it at once; anywhere else, two
			// quick taps with no drag between zoom in one step
			if (touch && !touch.moved) {
				var r = canvas.getBoundingClientRect();
				var pt = markerHandler ? markerAt(touch.x - r.left, touch.y - r.top) : null;
				if (pt) {
					markerHandler(pt, touch.x - r.left, touch.y - r.top);
					tapAt = null; lastTap = 0;
				}
				else {
					var now = Date.now();
					if (tapAt && now - lastTap < 300) { zoomAt(1, touch.x - r.left, touch.y - r.top); tapAt = null; }
					else { tapAt = { x: touch.x, y: touch.y }; }
					lastTap = now;
				}
			}
			touch = null; pinch = null;
			fire();
		});

		var api = {
			providers: providers,
			canvas: canvas,
			draw: draw,
			zoom: zoomBy,
			setZoom: function (z) { view.z = Math.max(2, Math.min(21, z)); draw(); },
			center: function (lat, lon) { view.lat = lat; view.lon = lon; draw(); },
			setProvider: function (key, url) {
				var nextUrl = (url === undefined || url === null) ? customUrl : url;
				if (key === providerKey && nextUrl === customUrl) { return; }
				providerKey = key;
				customUrl = nextUrl;
				tileCache = {};
				tileCount = 0;
				draw();
			},
			setMaps: function (list) {
				maps = [];
				(list || []).forEach(function (m) {
					var b = mapBounds(m);
					if (!b) { return; }
					var entry = { name: m.name, file: m.file, bounds: b, home_plate: m.home_plate, rotate: parseFloat(m.rotate) || 0 };
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
				maps.sort(function (a, b) { return b.span - a.span; });
				draw();
			},
			setPoints: function (list) { points = list || []; draw(); },
			setPosition: function (pos) { here = pos || null; draw(); },
			maps: function () { return maps; },
			// Frame the measured maps (their home plates), else keep the centre.
			fitToMaps: function () {
				var lats = [], lons = [];
				maps.forEach(function (m) { lats.push(m.bounds.nw.lat, m.bounds.se.lat); lons.push(m.bounds.nw.lon, m.bounds.se.lon); });
				if (here) { lats.push(here.lat); lons.push(here.lon); }
				if (!lats.length) { return; }
				fitBox(Math.min.apply(null, lats), Math.max.apply(null, lats), Math.min.apply(null, lons), Math.max.apply(null, lons), 1.3);
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
			onChange: function (fn) { changing.push(fn); },
			view: function () { return view; }
		};
		return api;
	}

	return { create: create, providers: providers, mapBounds: mapBounds };
})();
