// ---- home-plate water trace ------------------------------------------------
// The Configure editor asks this for the water under a river centerline drawn
// on the shared map canvas. It reads the tile pixels (only where the provider
// answered with CORS), learns the water colour from the line, grows the water
// region inside a band around the line, and returns the largest boundary as a
// polygon of latitude/longitude points.
//
// The editor falls back to a plain path corridor whenever this returns ok:false,
// so nothing here throws: a canvas that cannot be read is just a refusal.
(function () {
	'use strict';

	var DEFAULT_SAMPLE = 80;   // px each side of the line to search
	var DEFAULT_WIDTH = 30;    // metres, the caller's fallback corridor width
	var COLOUR_DIST = 70;      // RGB euclidean distance from the learned water
	var MIN_AREA = 16;         // fewer matching pixels than this is not water
	var MAX_POINTS = 120;      // the polygon cap after simplification

	function homePlateTraceWater(opts) {
		try {
			return trace(opts || {});
		}
		catch (e) {
			return { ok: false, error: (e && e.message) || 'the water trace failed' };
		}
	}

	function trace(opts) {
		var canvas = opts.canvas;
		var map = opts.map;
		var points = opts.points;
		var sample = number(opts.sample, DEFAULT_SAMPLE);
		var widthMetres = number(opts.widthMetres, DEFAULT_WIDTH);

		if (!canvas || typeof canvas.getContext !== 'function') {
			return { ok: false, error: 'the map canvas is unavailable' };
		}
		if (!map || typeof map.project !== 'function' || typeof map.unproject !== 'function') {
			return { ok: false, error: 'the map is unavailable' };
		}
		if (typeof map.canReadTiles === 'function' && !map.canReadTiles()) {
			return { ok: false, error: 'the map tiles cannot be read (cross-origin)' };
		}
		if (!points || typeof points.length !== 'number' || points.length < 2) {
			return { ok: false, error: 'at least two centerline points are needed' };
		}

		// Project the centerline. None of the engine's screen coordinates are
		// CSS-scaled, so they are canvas pixel coordinates.
		var line = [], ground = [];
		for (var i = 0; i < points.length; i++) {
			var p = points[i] || {};
			var lat = parseFloat(p.lat), lon = parseFloat(p.lon);
			if (!isFinite(lat) || !isFinite(lon)) { continue; }
			var s = map.project(lat, lon);
			if (!s || !isFinite(s[0]) || !isFinite(s[1])) { continue; }
			if (line.length && distance(line[line.length - 1][0], line[line.length - 1][1], s[0], s[1]) < 0.5) { continue; }
			line.push([s[0], s[1]]);
			ground.push({ lat: lat, lon: lon });
		}
		if (line.length < 2) {
			return { ok: false, error: 'the centerline could not be projected' };
		}

		var W = canvas.width | 0, H = canvas.height | 0;
		if (!(W > 0) || !(H > 0)) {
			return { ok: false, error: 'the map canvas has no size' };
		}
		var ctx;
		try { ctx = canvas.getContext('2d'); } catch (e2) { ctx = null; }
		if (!ctx) {
			return { ok: false, error: 'the map canvas cannot be read' };
		}

		// One read for the whole canvas. A tainted canvas throws here, which is
		// exactly the refusal the caller already knows how to fall back from.
		var image;
		try { image = ctx.getImageData(0, 0, W, H); }
		catch (e3) { return { ok: false, error: 'the map canvas cannot be read (cross-origin tiles)' }; }
		var data = image.data;

		// The search band: `sample` px each side, widened when the corridor width
		// at this zoom needs more room than that.
		var band = Math.round(sample);
		var mpp = metresPerPixel(ground, line);
		if (mpp > 0) {
			var half = (widthMetres / 2) / mpp;
			if (isFinite(half) && half > band) { band = Math.ceil(half); }
		}
		band = Math.max(6, Math.min(band, 400));

		var inBand = new Uint8Array(W * H);
		// A narrow ribbon on the line itself: the editor's drawn stroke may be a
		// different colour from the water, and growth is allowed to cross it so a
		// stroke down the middle cannot split the river into two banks.
		var core = new Uint8Array(W * H);
		var coreRadius = Math.min(band, 6);
		for (i = 1; i < line.length; i++) {
			stampTube(inBand, W, H, line[i - 1], line[i], band);
			stampTube(core, W, H, line[i - 1], line[i], coreRadius);
		}
		// round the ends, so the band is a tube around the whole line
		for (i = 0; i < line.length; i++) {
			stampCircle(inBand, W, H, line[i][0], line[i][1], band);
			stampCircle(core, W, H, line[i][0], line[i][1], coreRadius);
		}

		// Prefer samples a little way off the line: the editor's own stroke sits
		// on it, and a blue stroke must not become the water seed. If the river
		// is narrower than that, fall back to the closer offsets.
		var samples = sampleLine(data, W, H, line, band, 6);
		var water = waterColours(samples);
		if (water.length < 8) {
			samples = sampleLine(data, W, H, line, band, 0);
			water = waterColours(samples);
		}
		// Every provider paints water blue/cyan, so those samples are the seed.
		// No water-hued sample means the line is not over water (or a style is
		// unusually desaturated): refuse rather than learn a land colour.
		if (water.length < 8) {
			return { ok: false, error: 'no blue or cyan water was found along the line' };
		}
		var seed = [median(water, 0), median(water, 1), median(water, 2)];

		// Every pixel that is in the band, water-hued, and close to the seed.
		var match = new Uint8Array(W * H);
		var box = boundsOf(inBand, W, H);
		var dist2 = COLOUR_DIST * COLOUR_DIST;
		for (var y = box.miny; y <= box.maxy; y++) {
			var row = y * W;
			for (var x = box.minx; x <= box.maxx; x++) {
				var at = row + x;
				if (!inBand[at]) { continue; }
				var di = at * 4;
				if (data[di + 3] < 8) { continue; }
				var r = data[di], g = data[di + 1], b = data[di + 2];
				if (!isWater(r, g, b)) { continue; }
				var dr = r - seed[0], dg = g - seed[1], db = b - seed[2];
				if ((dr * dr) + (dg * dg) + (db * db) <= dist2) { match[at] = 1; }
			}
		}

		// The largest 4-connected component of that mask.
		var visited = new Uint8Array(W * H);
		var stack = [];
		var best = null, bestArea = 0;
		for (y = box.miny; y <= box.maxy; y++) {
			row = y * W;
			for (x = box.minx; x <= box.maxx; x++) {
				var start = row + x;
				if (!match[start] || visited[start]) { continue; }
				var comp = [];
				stack.length = 0;
				stack.push(start);
				visited[start] = 1;
				while (stack.length) {
					var at2 = stack.pop();
					comp.push(at2);
					var cx = at2 % W, cy = (at2 / W) | 0;
					if (cx > 0) { reachIf(match, core, visited, stack, at2 - 1); }
					if (cx < W - 1) { reachIf(match, core, visited, stack, at2 + 1); }
					if (cy > 0) { reachIf(match, core, visited, stack, at2 - W); }
					if (cy < H - 1) { reachIf(match, core, visited, stack, at2 + W); }
				}
				if (comp.length > bestArea) { bestArea = comp.length; best = comp; }
			}
		}
		if (!best || bestArea < MIN_AREA) {
			return { ok: false, error: 'no water was found along the line' };
		}

		var mask = new Uint8Array(W * H);
		for (i = 0; i < best.length; i++) { mask[best[i]] = 1; }

		var poly = outline(mask, best, W, H);
		if (poly.length < 3) { poly = hull(best, W); }
		if (poly.length < 3) {
			return { ok: false, error: 'the water boundary was too small' };
		}

		var simple = simplifyLoop(poly, 2, MAX_POINTS);
		if (simple.length < 3) {
			return { ok: false, error: 'the water boundary was too small' };
		}

		var out = [], last = null;
		for (i = 0; i < simple.length; i++) {
			var q = map.unproject(simple[i][0], simple[i][1]);
			if (!q || !isFinite(q.lat) || !isFinite(q.lon)) { continue; }
			if (last && Math.abs(q.lat - last.lat) < 1e-12 && Math.abs(q.lon - last.lon) < 1e-12) { continue; }
			out.push({ lat: q.lat, lon: q.lon });
			last = { lat: q.lat, lon: q.lon };
		}
		if (out.length < 3) {
			return { ok: false, error: 'the water boundary was too small' };
		}
		return { ok: true, areas: [ { shape: 'polygon', points: out } ] };
	}

	// ---- small geometry helpers ---------------------------------------------

	function number(value, fallback) {
		var n = parseFloat(value);
		return isFinite(n) && n > 0 ? n : fallback;
	}

	function distance(x1, y1, x2, y2) {
		var dx = x2 - x1, dy = y2 - y1;
		return Math.sqrt((dx * dx) + (dy * dy));
	}

	function metresBetween(lat1, lon1, lat2, lon2) {
		var R = 6371000, rad = Math.PI / 180;
		var dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad;
		var a = (Math.sin(dLat / 2) * Math.sin(dLat / 2)) +
			(Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) * Math.sin(dLon / 2));
		return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
	}

	// Use the longest screen segment to estimate the ground scale (m per px).
	function metresPerPixel(ground, line) {
		var bestLen = 0, best = 0;
		for (var i = 1; i < line.length; i++) {
			var px = distance(line[i - 1][0], line[i - 1][1], line[i][0], line[i][1]);
			if (px < 8 || px <= bestLen) { continue; }
			var m = metresBetween(ground[i - 1].lat, ground[i - 1].lon, ground[i].lat, ground[i].lon);
			if (m > 0) { bestLen = px; best = m / px; }
		}
		return best;
	}

	// The tube of radius r around one segment, clamped to its own x (or y) span;
	// the caps are stamped once per vertex after every segment.
	function stampTube(mask, W, H, a, b, radius) {
		var x1 = a[0], y1 = a[1], x2 = b[0], y2 = b[1];
		var dx = x2 - x1, dy = y2 - y1;
		var len = Math.sqrt((dx * dx) + (dy * dy));
		if (len < 0.5) { return; }
		if (Math.abs(dx) >= Math.abs(dy)) {
			if (!dx) { return; }
			var half = radius * len / Math.abs(dx);
			var minx = Math.max(0, Math.floor(Math.min(x1, x2)));
			var maxx = Math.min(W - 1, Math.ceil(Math.max(x1, x2)));
			for (var x = minx; x <= maxx; x++) {
				var yc = y1 + (((x + 0.5) - x1) * dy / dx);
				var lo = Math.max(0, Math.floor(yc - half));
				var hi = Math.min(H - 1, Math.ceil(yc + half));
				for (var y = lo; y <= hi; y++) { mask[(y * W) + x] = 1; }
			}
		}
		else {
			var halfX = radius * len / Math.abs(dy);
			var miny = Math.max(0, Math.floor(Math.min(y1, y2)));
			var maxy = Math.min(H - 1, Math.ceil(Math.max(y1, y2)));
			for (var yy = miny; yy <= maxy; yy++) {
				var xc = x1 + (((yy + 0.5) - y1) * dx / dy);
				var lx = Math.max(0, Math.floor(xc - halfX));
				var hx = Math.min(W - 1, Math.ceil(xc + halfX));
				for (var xx = lx; xx <= hx; xx++) { mask[(yy * W) + xx] = 1; }
			}
		}
	}

	function stampCircle(mask, W, H, cx, cy, radius) {
		var minx = Math.max(0, Math.floor(cx - radius));
		var maxx = Math.min(W - 1, Math.ceil(cx + radius));
		var miny = Math.max(0, Math.floor(cy - radius));
		var maxy = Math.min(H - 1, Math.ceil(cy + radius));
		var r2 = radius * radius;
		for (var y = miny; y <= maxy; y++) {
			var dy = (y + 0.5) - cy;
			for (var x = minx; x <= maxx; x++) {
				var dx = (x + 0.5) - cx;
				if ((dx * dx) + (dy * dy) <= r2) { mask[(y * W) + x] = 1; }
			}
		}
	}

	// Samples beside the line at several offsets. The near offsets may be the
	// editor's own stroke; the wider ones let a narrow river show its water.
	function sampleLine(data, W, H, line, band, minOffset) {
		var out = [];
		var offsets = [0, -2, 2, -4, 4, -6, 6, -9, 9, -13, 13, -18, 18, -24, 24];
		var budget = 24000;
		for (var i = 1; i < line.length; i++) {
			var x1 = line[i - 1][0], y1 = line[i - 1][1];
			var x2 = line[i][0], y2 = line[i][1];
			var dx = x2 - x1, dy = y2 - y1;
			var len = Math.sqrt((dx * dx) + (dy * dy));
			if (len < 0.5) { continue; }
			var nx = -dy / len, ny = dx / len;
			var steps = Math.max(1, Math.ceil(len / 2));
			for (var k = 0; k <= steps; k++) {
				var t = k / steps;
				var px = x1 + (dx * t), py = y1 + (dy * t);
				for (var o = 0; o < offsets.length; o++) {
					var off = offsets[o];
					if (Math.abs(off) < minOffset || Math.abs(off) > band) { continue; }
					var sx = Math.round(px + (nx * off));
					var sy = Math.round(py + (ny * off));
					if (sx < 0 || sy < 0 || sx >= W || sy >= H) { continue; }
					var di = ((sy * W) + sx) * 4;
					if (data[di + 3] < 8) { continue; }
					out.push(data[di], data[di + 1], data[di + 2]);
					if (out.length >= budget) { return out; }
				}
			}
		}
		return out;
	}

	// Water is blue/cyan in every provider style; the seed makes the colour
	// distance adapt to a light or dark style, this hue band keeps the grown
	// region off green parks, brown ground and red roads.
	function hueSat(r, g, b) {
		var max = Math.max(r, g, b), min = Math.min(r, g, b);
		if (!max) { return { h: 0, s: 0, v: 0 }; }
		var v = max / 255;
		if (max === min) { return { h: 0, s: 0, v: v }; }
		var d = max - min, h;
		if (max === r) { h = ((g - b) / d) % 6; }
		else if (max === g) { h = ((b - r) / d) + 2; }
		else { h = ((r - g) / d) + 4; }
		h *= 60;
		if (h < 0) { h += 360; }
		return { h: h, s: d / max, v: v };
	}

	function isWater(r, g, b) {
		// The engine's empty-canvas fill is a cool grey, not water.
		if (Math.abs(r - 233) <= 3 && Math.abs(g - 237) <= 3 && Math.abs(b - 241) <= 3) { return false; }
		var c = hueSat(r, g, b);
		if (!(c.v > 0.05 && c.s > 0.03 && c.h >= 155 && c.h <= 265)) { return false; }
		// Real water is blue/cyan-dominant: blue at least matches green and is
		// clearly above red, which keeps neutral and warm greys out.
		return b >= (g - 2) && (b - r) >= 6;
	}

	function waterColours(samples) {
		var out = [];
		for (var i = 0; i < samples.length; i += 3) {
			if (isWater(samples[i], samples[i + 1], samples[i + 2])) {
				out.push([samples[i], samples[i + 1], samples[i + 2]]);
			}
		}
		return out;
	}

	function median(list, channel) {
		var values = new Array(list.length);
		for (var i = 0; i < list.length; i++) { values[i] = list[i][channel]; }
		values.sort(function (a, b) { return a - b; });
		return values[values.length >> 1];
	}

	function boundsOf(mask, W, H) {
		var minx = W, maxx = -1, miny = H, maxy = -1;
		for (var y = 0; y < H; y++) {
			var row = y * W;
			for (var x = 0; x < W; x++) {
				if (!mask[row + x]) { continue; }
				if (x < minx) { minx = x; }
				if (x > maxx) { maxx = x; }
				if (y < miny) { miny = y; }
				if (y > maxy) { maxy = y; }
			}
		}
		return { minx: minx, maxx: maxx, miny: miny, maxy: maxy };
	}

	function reachIf(match, core, visited, stack, idx) {
		if ((match[idx] || core[idx]) && !visited[idx]) { visited[idx] = 1; stack.push(idx); }
	}

	// The outline of a component, as grid-corner points in screen space. Every
	// edge between a component pixel and a non-pixel is walked; the loops that
	// close are kept and the largest (the outer boundary) wins.
	function outline(mask, pixels, W, H) {
		var keyW = W + 1;
		var next = {};
		function edge(x1, y1, x2, y2) {
			var a = (y1 * keyW) + x1;
			var b = (y2 * keyW) + x2;
			if (next[a]) { next[a].push(b); }
			else { next[a] = [b]; }
		}
		for (var i = 0; i < pixels.length; i++) {
			var idx = pixels[i];
			var x = idx % W, y = (idx / W) | 0;
			if (y === 0 || !mask[idx - W]) { edge(x, y, x + 1, y); }
			if (x === W - 1 || !mask[idx + 1]) { edge(x + 1, y, x + 1, y + 1); }
			if (y === H - 1 || !mask[idx + W]) { edge(x + 1, y + 1, x, y + 1); }
			if (x === 0 || !mask[idx - 1]) { edge(x, y + 1, x, y); }
		}
		var best = null, bestArea = -1;
		for (var key in next) {
			if (!next[key] || !next[key].length) { continue; }
			var start = +key;
			while (next[key] && next[key].length) {
				var loop = [];
				var cur = start;
				var guard = 0, limit = (pixels.length * 4) + 64;
				while (guard++ < limit) {
					var outs = next[cur];
					if (!outs || !outs.length) { break; }
					var nxt = outs.pop();
					loop.push(cur);
					cur = nxt;
					if (cur === start) { break; }
				}
				if (cur === start && loop.length >= 4) {
					var area = Math.abs(areaOf(loop, keyW)) / 2;
					if (area > bestArea) { bestArea = area; best = loop; }
				}
			}
		}
		if (!best) { return []; }
		var poly = [];
		for (i = 0; i < best.length; i++) {
			var k = best[i];
			poly.push([k % keyW, (k / keyW) | 0]);
		}
		return poly;
	}

	function areaOf(loop, keyW) {
		var sum = 0;
		for (var i = 0; i < loop.length; i++) {
			var p = loop[i], q = loop[(i + 1) % loop.length];
			var px = p % keyW, py = (p / keyW) | 0;
			var qx = q % keyW, qy = (q / keyW) | 0;
			sum += (px * qy) - (qx * py);
		}
		return sum;
	}

	// Fallback only: the component's convex hull, for a mask whose edges did
	// not close into a loop.
	function hull(pixels, W) {
		var pts = [];
		for (var i = 0; i < pixels.length; i++) {
			var idx = pixels[i];
			pts.push([(idx % W) + 0.5, ((idx / W) | 0) + 0.5]);
		}
		if (pts.length < 3) { return pts; }
		pts.sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
		function cross(o, a, b) {
			return ((a[0] - o[0]) * (b[1] - o[1])) - ((a[1] - o[1]) * (b[0] - o[0]));
		}
		var lower = [], upper = [];
		for (i = 0; i < pts.length; i++) {
			while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], pts[i]) <= 0) { lower.pop(); }
			lower.push(pts[i]);
		}
		for (i = pts.length - 1; i >= 0; i--) {
			while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], pts[i]) <= 0) { upper.pop(); }
			upper.push(pts[i]);
		}
		lower.pop(); upper.pop();
		return lower.concat(upper);
	}

	function simplifyLoop(poly, tolerance, cap) {
		var points = poly.slice();
		if (points.length > 1) {
			var first = points[0], last = points[points.length - 1];
			if (first[0] !== last[0] || first[1] !== last[1]) {
				points.push([first[0], first[1]]);
			}
		}
		var tol = tolerance;
		var out = simplify(points, tol);
		while (out.length > cap && tol < 128) {
			tol *= 1.7;
			out = simplify(points, tol);
		}
		if (out.length > cap) {
			var stride = Math.ceil(out.length / cap);
			var thin = [];
			for (var i = 0; i < out.length; i += stride) { thin.push(out[i]); }
			out = thin;
		}
		if (out.length > 1) {
			first = out[0];
			last = out[out.length - 1];
			if (first[0] === last[0] && first[1] === last[1]) { out.pop(); }
		}
		return out;
	}

	function simplify(points, tolerance) {
		if (points.length <= 2) { return points.slice(); }
		var keep = new Uint8Array(points.length);
		keep[0] = 1;
		keep[points.length - 1] = 1;
		var stack = [[0, points.length - 1]];
		while (stack.length) {
			var range = stack.pop();
			var a = range[0], b = range[1];
			var maxD = -1, maxI = -1;
			for (var i = a + 1; i < b; i++) {
				var d = pointSegDist(points[i], points[a], points[b]);
				if (d > maxD) { maxD = d; maxI = i; }
			}
			if (maxD > tolerance && maxI > a && maxI < b) {
				keep[maxI] = 1;
				stack.push([a, maxI]);
				stack.push([maxI, b]);
			}
		}
		var out = [];
		for (i = 0; i < points.length; i++) {
			if (keep[i]) { out.push(points[i]); }
		}
		return out;
	}

	function pointSegDist(p, a, b) {
		var dx = b[0] - a[0], dy = b[1] - a[1];
		var len2 = (dx * dx) + (dy * dy);
		var t = len2 > 0 ? (((p[0] - a[0]) * dx) + ((p[1] - a[1]) * dy)) / len2 : 0;
		if (t < 0) { t = 0; }
		else if (t > 1) { t = 1; }
		var ex = a[0] + (t * dx) - p[0];
		var ey = a[1] + (t * dy) - p[1];
		return Math.sqrt((ex * ex) + (ey * ey));
	}

	window.homePlateTraceWater = homePlateTraceWater;
})();
