// ---- the clothesline label's type sizes -----------------------------------
// The clothesline measures its names with the same font and spacing the label
// printer uses, so a tile can be exactly as wide as its name needs. Every
// texture prints at one size, and the family is the Misc → Font choice (canvas
// cannot inherit it, so jawnosFont() reads it back off the root).
function jawnosTextureFont(kind) {
	var family = (typeof jawnosFont == 'function') ? jawnosFont() : 'system-ui, sans-serif';
	if (kind === 'classic') { return '400 16px ' + family; }
	if (kind === 'round') { return '600 16px ' + family; }
	return '500 16px ' + family;
}
function jawnosTextureSpacing(kind) {
	kind = kind || jawnosTextureCurrent;
	if (kind === 'round') { return '0.2px'; }
	if (kind === 'classic') { return '0px'; }
	return '0.3px';
}
function jawnosTextureLabelText(text, kind) {
	return '' + text;
}
function jawnosTextureMeasure(ctx, text, kind) {
	kind = kind || jawnosTextureCurrent;
	ctx.save();
	ctx.font = jawnosTextureFont(kind);
	try { ctx.letterSpacing = jawnosTextureSpacing(kind); } catch (e) {}
	var width = ctx.measureText(jawnosTextureLabelText(text, kind)).width;
	ctx.restore();
	return width;
}
// The label's ink leans the way the garment does: black on a pale pane, white
// on a dark one, carried most of the way toward the appointment's own colour.
// The pane picks the base, not the desk's theme, so the name still reads when a
// light desk wears a dark material (or the reverse).
function jawnosTextureTint(base, colour, amount) {
	function channels(hex) {
		var h = ('' + (hex == null ? '' : hex)).replace(/^\s*#/, '').trim();
		if (h.length === 3) { h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]; }
		if (!/^[0-9a-fA-F]{6}$/.test(h)) { return null; }
		var n = parseInt(h, 16);
		return [ (n >> 16) & 255, (n >> 8) & 255, n & 255 ];
	}
	var a = channels(base);
	var b = channels(colour);
	if (!a || !b) { return base; }
	var out = '#';
	for (var i = 0; i < 3; i++) {
		var v = Math.round(a[i] * (1 - amount) + b[i] * amount);
		out += (v < 16 ? '0' : '') + v.toString(16);
	}
	return out;
}

// The label: a plain printed name on Plain; solid and quiet on round; on every
// material the name is larger (Plain's size) and printed in the pane's
// contrasting ink, tinted with the appointment's colour rather than etched in a
// neutral grey.
function jawnosTextureLabel(ctx, text, x, y, w, h, dark, colour) {
	var kind = jawnosTextureCurrent;
	ctx.save();
	ctx.textBaseline = 'middle';
	if (kind === 'classic') {
		// the old label: the name as typed, in the tile's own contrasting ink
		ctx.font = jawnosTextureFont(kind);
		try { ctx.letterSpacing = jawnosTextureSpacing(kind); } catch (e) {}
		ctx.textBaseline = 'alphabetic';
		var classicInk = (typeof jawnosContrastInk == 'function' && colour) ? jawnosContrastInk(colour) : (dark ? '#f0f4f8' : '#161a1e');
		// a dark desk's ink is a softened grey, not pure white
		if (dark && classicInk === '#ffffff' && typeof jawnosInk == 'function') { classicInk = jawnosInk(); }
		var classicMeasure = ctx.measureText(text).width;
		ctx.fillStyle = classicInk;
		ctx.fillText(text, ((w - classicMeasure) / 2) + x, y + (h / 2) + 6);
		ctx.restore();
		return;
	}
	if (kind === 'round') {
		ctx.font = jawnosTextureFont(kind);
		try { ctx.letterSpacing = jawnosTextureSpacing(kind); } catch (e) {}
		var roundMeasure = ctx.measureText(text).width;
		var roundX = ((w - roundMeasure) / 2) + x;
		var roundY = y + (h / 2) + 0.5;
		// round is a solid tile, so the label wears the ink that reads on that
		// colour; the textured panes are neutral and use the theme's ink
		var roundInk = (typeof jawnosContrastInk == 'function' && colour) ? jawnosContrastInk(colour) : (dark ? '#f0f4f8' : '#161a1e');
		// a dark desk's ink is a softened grey, not pure white: a white label on
		// a solid garment was the one place the theme's own grey did not reach
		if (dark && roundInk === '#ffffff' && typeof jawnosInk == 'function') { roundInk = jawnosInk(); }
		var lightInk = (typeof jawnosContrastInk == 'function') ? jawnosContrastInk(roundInk) === '#000000' : dark;
		ctx.fillStyle = lightInk ? 'rgba(0,0,0,0.55)' : 'rgba(255,255,255,0.75)';
		ctx.fillText(text, roundX, roundY + (lightInk ? -1 : 1));
		ctx.fillStyle = roundInk;
		ctx.fillText(text, roundX, roundY);
		ctx.restore();
		return;
	}
	ctx.font = jawnosTextureFont(kind);
	try { ctx.letterSpacing = jawnosTextureSpacing(kind); } catch (e) {}
	var label = jawnosTextureLabelText(text, kind);
	var measure = ctx.measureText(label).width;
	var lx = ((w - measure) / 2) + x;
	var ly = y + (h / 2) + 0.5;
	// every material label is the same size now and wears the appointment's
	// colour, so it reads as that app rather than as neutral engraving. A hair of
	// the pane's opposite tone under it keeps the grain from swallowing the
	// letters.
	var ink = jawnosTextureTint(dark ? '#ffffff' : '#000000', colour, 0.30);
	ctx.fillStyle = dark ? 'rgba(0,0,0,0.55)' : 'rgba(255,255,255,0.85)';
	ctx.fillText(label, lx, ly + (dark ? -1 : 1));
	ctx.fillStyle = ink;
	ctx.fillText(label, lx, ly);
	ctx.restore();
}
