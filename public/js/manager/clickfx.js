// The little effects that answer a press: a clicked canvas item (a timeline dot
// and its words, a clockface dot and label, a clothesline garment) is magnified
// for a moment, and a button that opens a window wears a loading pulse while the
// server answers. Both are shared, so every printer and every press surface gets
// the same manners.

// Magnify the canvas rectangle [left, top, right, bottom] for `seconds`. The
// pixels are captured once, drawn scaled about the centre on each frame, and put
// back at the end - so nothing leaks into the rest of the drawing and the item
// settles exactly as it was. `thickness` draws a border of that width while it
// grows (the clothesline's thicker edge).
function jawnosClickMagnify(canvas, rect, seconds, thickness) {
	if (!canvas || !rect) { return; }
	var ctx = canvas.getContext('2d');
	if (!ctx) { return; }
	var l = Math.min(rect[0], rect[2]), r = Math.max(rect[0], rect[2]);
	var t = Math.min(rect[1], rect[3]), b = Math.max(rect[1], rect[3]);
	var w0 = r - l, h0 = b - t;
	if (w0 <= 0 || h0 <= 0) { return; }
	// pad the captured region so the magnified copy (up to 10% larger) stays
	// inside it; the final putImageData then restores every changed pixel
	var pad = Math.ceil(Math.max(16, w0 * 0.08));
	var x = Math.max(0, Math.floor(l - pad));
	var y = Math.max(0, Math.floor(t - pad));
	var w = Math.min(canvas.width - x, Math.ceil(w0 + pad * 2));
	var h = Math.min(canvas.height - y, Math.ceil(h0 + pad * 2));
	if (w <= 2 || h <= 2) { return; }
	var shot;
	try { shot = ctx.getImageData(x, y, w, h); }
	catch (e) { return; }
	var off = document.createElement('canvas');
	off.width = w; off.height = h;
	off.getContext('2d').putImageData(shot, 0, 0);
	var ink = (typeof jawnosInk == 'function') ? jawnosInk() : '#000';
	var start = performance.now();
	var ms = Math.max(140, seconds * 1000);
	var cx = x + w / 2, cy = y + h / 2;
	function frame(now) {
		var p = Math.min(1, (now - start) / ms);
		// restore, then lay the magnified copy over it
		ctx.putImageData(shot, x, y);
		var scale = 1 + 0.10 * Math.sin(Math.PI * p);
		ctx.save();
		ctx.translate(cx, cy);
		ctx.scale(scale, scale);
		ctx.drawImage(off, -w / 2, -h / 2, w, h);
		ctx.restore();
		if (thickness) {
			ctx.save();
			ctx.strokeStyle = ink;
			ctx.lineWidth = thickness;
			ctx.beginPath();
			roundRectPath(ctx, l, t, w0, h0, 10);
			ctx.stroke();
			ctx.restore();
		}
		if (p < 1) { requestAnimationFrame(frame); }
		else { ctx.putImageData(shot, x, y); }
	}
	requestAnimationFrame(frame);
}

// A rounded-rectangle path (older browsers have no ctx.roundRect).
function roundRectPath(ctx, x, y, w, h, r) {
	r = Math.min(r, w / 2, h / 2);
	ctx.moveTo(x + r, y);
	ctx.arcTo(x + w, y, x + w, y + h, r);
	ctx.arcTo(x + w, y + h, x, y + h, r);
	ctx.arcTo(x, y + h, x, y, r);
	ctx.arcTo(x, y, x + w, y, r);
	ctx.closePath();
}

// The loading pulse: a soft ring that beats while a press is being answered. It
// clears itself, so callers only ever add it.
function jawnosLoadingPulse(el) {
	var target = (el && el.jquery) ? el : $(el);
	if (!target.length) { return; }
	target.addClass('jawnos_loading');
	clearTimeout(target.data('jawnos_loading_timer'));
	var timer = setTimeout(function () {
		target.removeClass('jawnos_loading');
	}, 1600);
	target.data('jawnos_loading_timer', timer);
}
