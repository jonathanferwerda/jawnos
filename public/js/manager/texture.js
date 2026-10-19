// The desk's material. One misc setting is seeded into jawnos_bar_settings by
// the layout and written onto <body data-texture>. universal.css reads that
// attribute for every button and hinted image; the functions here paint the
// same materials on the canvas clothesline, which CSS cannot reach.
//
// A material only ever layers over a control's own colour, so an active green
// or a destroy red keeps its meaning underneath. Plain is the desk exactly as
// it looked before the materials existed (the clothesline's original frosted
// pill); round is the solid rounded pill that used to be called plain.

var jawnosTextureNames = [ 'classic', 'round', 'sandglass', 'glass', 'paper', 'fabric', 'wood', 'metal' ];
// 'plain' was the solid rounded pill's old internal name: read it as round so a
// desk that had chosen it keeps the same look now that Plain means the original.
function jawnosTextureName(value) {
	if (value === 'plain') { return 'round'; }
	return value;
}
var jawnosTextureCurrent = (typeof jawnos_bar_settings != 'undefined' && jawnos_bar_settings && jawnos_bar_settings.texture) || 'sandglass';
jawnosTextureCurrent = jawnosTextureName(jawnosTextureCurrent);
if (jawnosTextureNames.indexOf(jawnosTextureCurrent) < 0) { jawnosTextureCurrent = 'sandglass'; }

function jawnosTextureApply(value) {
	value = jawnosTextureName(value);
	if (!value || jawnosTextureNames.indexOf(value) < 0) { value = 'sandglass'; }
	jawnosTextureCurrent = value;
	if (typeof jawnos_bar_settings != 'undefined' && jawnos_bar_settings) { jawnos_bar_settings.texture = value; }
	if (document.body) { document.body.setAttribute('data-texture', value); }
	// the clothesline is canvas, not CSS: repaint it with the new material
	if (typeof clotheslineHanger == 'function' && typeof wardrobe != 'undefined' && wardrobe && wardrobe.length
		&& typeof hangingClothes != 'undefined' && hangingClothes == 0) {
		clotheslineHanger(wardrobe);
	}
}
if (document.body) { document.body.setAttribute('data-texture', jawnosTextureCurrent); }

function jawnosTextureDark() {
	var ink = (typeof jawnosInk == 'function') ? jawnosInk() : '#000000';
	return (typeof jawnosContrastInk == 'function') ? jawnosContrastInk(ink) === '#000000' : false;
}

// ---- canvas material tiles ------------------------------------------------
var jawnosTextureTiles = {};
function jawnosTextureTile(kind, dark) {
	var key = kind + (dark ? ':dark' : ':light');
	if (jawnosTextureTiles[key]) { return jawnosTextureTiles[key]; }
	var c = document.createElement('canvas');
	var x;
	var img;
	var i;
	if (kind === 'sandglass') {
		c.width = c.height = 48;
		x = c.getContext('2d');
		img = x.createImageData(48, 48);
		for (i = 0; i < img.data.length; i += 4) {
			var v = 150 + Math.floor(Math.random() * 70) - 35;
			img.data[i] = img.data[i + 1] = img.data[i + 2] = v;
			img.data[i + 3] = 14;
		}
		x.putImageData(img, 0, 0);
	}
	else if (kind === 'glass') {
		// a repeating specular band: the printers have no single bounding box to
		// build a shape-wide gloss from, so a small lit tile carries the shine onto
		// dots, bands and rings
		c.width = c.height = 32;
		x = c.getContext('2d');
		var glass = x.createLinearGradient(0, 0, 0, 32);
		glass.addColorStop(0, 'rgba(255,255,255,0.24)');
		glass.addColorStop(0.18, 'rgba(255,255,255,0.07)');
		glass.addColorStop(0.5, 'rgba(255,255,255,0)');
		glass.addColorStop(0.72, 'rgba(255,255,255,0.10)');
		glass.addColorStop(1, 'rgba(0,0,0,0.16)');
		x.fillStyle = glass;
		x.fillRect(0, 0, 32, 32);
	}
	else if (kind === 'paper') {
		c.width = 64; c.height = 32;
		x = c.getContext('2d');
		img = x.createImageData(64, 32);
		for (i = 0; i < img.data.length; i += 4) {
			var w = 145 + Math.floor(Math.random() * 60) - 30;
			img.data[i] = Math.min(255, w + 8);
			img.data[i + 1] = w;
			img.data[i + 2] = Math.max(0, w - 12);
			img.data[i + 3] = dark ? 16 : 14;
		}
		x.putImageData(img, 0, 0);
		// short fibres, not a regular hatch: paper is matte and irregular
		for (var f = 0; f < 26; f++) {
			var fx = Math.random() * 64;
			var fy = Math.random() * 32;
			var fl = 2 + Math.random() * 9;
			x.strokeStyle = dark ? 'rgba(255,240,215,0.14)' : 'rgba(120,95,60,0.11)';
			x.lineWidth = 0.7;
			x.beginPath();
			x.moveTo(fx, fy);
			x.lineTo(fx + fl, fy + (Math.random() * 1.6 - 0.8));
			x.stroke();
		}
		for (var pl = 0; pl < 6; pl++) {
			var ply = Math.random() * 32;
			x.fillStyle = dark ? 'rgba(255,240,215,0.07)' : 'rgba(120,95,60,0.05)';
			x.fillRect(0, ply, 64, 1);
		}
	}
	else if (kind === 'fabric') {
		c.width = c.height = 16;
		x = c.getContext('2d');
		var thread = dark ? 'rgba(255,255,255,0.09)' : 'rgba(0,0,0,0.06)';
		var shade = dark ? 'rgba(0,0,0,0.15)' : 'rgba(255,255,255,0.18)';
		for (var yy = 0; yy < 16; yy += 4) {
			for (var xx = 0; xx < 16; xx += 4) {
				var over = (((xx + yy) / 4) % 2 === 0);
				x.fillStyle = over ? thread : shade;
				if (over) { x.fillRect(xx, yy, 3, 1); }
				else { x.fillRect(xx, yy, 1, 3); }
			}
		}
	}
	else if (kind === 'wood') {
		c.width = 64; c.height = 24;
		x = c.getContext('2d');
		x.lineWidth = 1;
		for (var y = 0; y < 24; y += 2) {
			var a = 0.10 + Math.random() * 0.08;
			x.strokeStyle = dark ? 'rgba(255,235,210,' + a + ')' : 'rgba(96,64,32,' + (a * 0.8) + ')';
			x.beginPath();
			for (var wx = 0; wx <= 64; wx += 4) {
				var wave = Math.sin((wx + y * 3) * 0.09) * 0.8 + Math.sin((wx + y) * 0.03) * 1.2;
				if (wx === 0) { x.moveTo(wx, y + wave); }
				else { x.lineTo(wx, y + wave); }
			}
			x.stroke();
		}
		for (var band = 0; band < 2; band++) {
			var by = 4 + Math.random() * 16;
			x.strokeStyle = dark ? 'rgba(0,0,0,0.12)' : 'rgba(80,50,24,0.10)';
			x.beginPath();
			for (var bx = 0; bx <= 64; bx += 4) {
				var bw = Math.sin((bx + by * 3) * 0.09) * 1.2;
				if (bx === 0) { x.moveTo(bx, by + bw); }
				else { x.lineTo(bx, by + bw); }
			}
			x.stroke();
		}
	}
	else if (kind === 'metal') {
		c.width = c.height = 32;
		x = c.getContext('2d');
		for (var my = 0; my < 32; my++) {
			var ma = 0.05 + Math.random() * 0.09;
			x.fillStyle = dark ? 'rgba(255,255,255,' + ma + ')' : 'rgba(0,0,0,' + (ma * 0.8) + ')';
			x.fillRect(0, my, 32, 1);
		}
		x.fillStyle = dark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.12)';
		for (var sy = 0; sy < 32; sy += 3) { x.fillRect(0, sy, 32, 1); }
	}
	else {
		return null;
	}
	jawnosTextureTiles[key] = c;
	return c;
}

function jawnosTextureGrain(ctx, kind, dark) {
	// the pill's own sheen already carries the gloss
	if (kind === 'glass') { return; }
	var tile = jawnosTextureTile(kind, dark);
	if (!tile) { return; }
	var pattern = ctx.createPattern(tile, 'repeat');
	if (pattern) { ctx.fillStyle = pattern; ctx.fill(); }
}

// The printers paint arbitrary paths, not the clothesline's pills: these
// helpers lay the same material over the app colour that path already wears.
function jawnosTexturePattern(ctx, kind, dark) {
	var tile = jawnosTextureTile(kind, dark);
	return tile ? ctx.createPattern(tile, 'repeat') : null;
}

function jawnosTextureFill(ctx, colour, dark) {
	ctx.fillStyle = colour;
	ctx.fill();
	if (jawnosTextureBare(jawnosTextureCurrent)) { return; }
	var pattern = jawnosTexturePattern(ctx, jawnosTextureCurrent, dark);
	if (pattern) { ctx.fillStyle = pattern; ctx.fill(); }
}

// Plain and round wear no material on the canvas either: the printers draw
// exactly what they drew before the materials, with no overlay.
function jawnosTextureBare(kind) {
	return kind === 'plain' || kind === 'round' || kind === 'classic';
}

function jawnosTextureStroke(ctx, colour, dark, width) {
	ctx.lineWidth = width;
	ctx.strokeStyle = colour;
	ctx.stroke();
	if (jawnosTextureBare(jawnosTextureCurrent)) { return; }
	var pattern = jawnosTexturePattern(ctx, jawnosTextureCurrent, dark);
	if (pattern) { ctx.strokeStyle = pattern; ctx.stroke(); }
}

function jawnosTextureFillRect(ctx, x, y, w, h, colour, dark) {
	ctx.save();
	ctx.beginPath();
	ctx.rect(x, y, w, h);
	jawnosTextureFill(ctx, colour, dark);
	ctx.restore();
}

function jawnosTextureFillCircle(ctx, x, y, r, colour, dark) {
	ctx.save();
	ctx.beginPath();
	ctx.arc(x, y, r, 0, Math.PI * 2);
	jawnosTextureFill(ctx, colour, dark);
	ctx.restore();
}

function jawnosTextureBase(kind, dark) {
	if (kind === 'sandglass') { return dark ? 'rgba(48,54,62,0.50)' : 'rgba(255,255,255,0.55)'; }
	if (kind === 'glass') { return dark ? 'rgba(190,215,240,0.16)' : 'rgba(255,255,255,0.34)'; }
	if (kind === 'paper') { return dark ? 'rgba(108,96,76,0.66)' : 'rgba(248,242,226,0.88)'; }
	if (kind === 'fabric') { return dark ? 'rgba(66,70,78,0.64)' : 'rgba(240,240,238,0.80)'; }
	if (kind === 'wood') { return dark ? 'rgba(92,62,38,0.70)' : 'rgba(214,184,140,0.80)'; }
	if (kind === 'metal') { return dark ? 'rgba(92,100,110,0.60)' : 'rgba(224,228,232,0.80)'; }
	return 'rgba(0,0,0,0.2)';
}

function jawnosTextureSheen(ctx, kind, dark, x, y, w, h) {
	var g = ctx.createLinearGradient(0, y, 0, y + h);
	if (kind === 'glass') {
		g.addColorStop(0, 'rgba(255,255,255,0.85)');
		g.addColorStop(0.20, 'rgba(255,255,255,0.35)');
		g.addColorStop(0.42, 'rgba(255,255,255,0.02)');
		g.addColorStop(0.52, 'rgba(255,255,255,0)');
		g.addColorStop(0.58, 'rgba(255,255,255,0.16)');
		g.addColorStop(0.66, 'rgba(255,255,255,0)');
		g.addColorStop(1, 'rgba(0,0,0,0.30)');
	}
	else if (kind === 'paper') {
		g.addColorStop(0, dark ? 'rgba(255,240,215,0.10)' : 'rgba(255,255,255,0.25)');
		g.addColorStop(0.55, 'rgba(255,255,255,0)');
		g.addColorStop(1, dark ? 'rgba(0,0,0,0.10)' : 'rgba(0,0,0,0.04)');
	}
	else if (kind === 'fabric') {
		g.addColorStop(0, dark ? 'rgba(255,255,255,0.12)' : 'rgba(255,255,255,0.22)');
		g.addColorStop(0.5, 'rgba(255,255,255,0)');
		g.addColorStop(1, dark ? 'rgba(0,0,0,0.14)' : 'rgba(0,0,0,0.06)');
	}
	else if (kind === 'wood') {
		g.addColorStop(0, dark ? 'rgba(255,225,180,0.12)' : 'rgba(255,240,210,0.30)');
		g.addColorStop(0.55, 'rgba(255,255,255,0)');
		g.addColorStop(1, dark ? 'rgba(0,0,0,0.18)' : 'rgba(0,0,0,0.08)');
	}
	else if (kind === 'metal') {
		g.addColorStop(0, 'rgba(255,255,255,0.38)');
		g.addColorStop(0.30, 'rgba(255,255,255,0.06)');
		g.addColorStop(0.52, 'rgba(0,0,0,0.08)');
		g.addColorStop(0.74, 'rgba(255,255,255,0.14)');
		g.addColorStop(1, 'rgba(0,0,0,0.20)');
	}
	else {
		g.addColorStop(0, dark ? 'rgba(255,255,255,0.16)' : 'rgba(255,255,255,0.65)');
		g.addColorStop(0.48, 'rgba(255,255,255,0.03)');
		g.addColorStop(0.55, 'rgba(255,255,255,0)');
		g.addColorStop(1, dark ? 'rgba(0,0,0,0.16)' : 'rgba(0,0,0,0.05)');
	}
	ctx.fillStyle = g;
	ctx.fill();
	if (kind === 'glass') {
		var side = ctx.createLinearGradient(x, 0, x + w, 0);
		side.addColorStop(0, 'rgba(255,255,255,0.10)');
		side.addColorStop(0.22, 'rgba(255,255,255,0)');
		side.addColorStop(0.78, 'rgba(255,255,255,0)');
		side.addColorStop(1, 'rgba(255,255,255,0.14)');
		ctx.fillStyle = side;
		ctx.fill();
	}
}

function jawnosTextureRim(kind, dark) {
	if (kind === 'paper') { return dark ? 'rgba(255,244,224,0.26)' : 'rgba(80,60,35,0.22)'; }
	if (kind === 'wood') { return dark ? 'rgba(255,220,180,0.28)' : 'rgba(90,55,25,0.28)'; }
	if (kind === 'metal') { return dark ? 'rgba(255,255,255,0.45)' : 'rgba(60,70,80,0.30)'; }
	if (kind === 'fabric') { return dark ? 'rgba(255,255,255,0.28)' : 'rgba(0,0,0,0.18)'; }
	if (kind === 'glass') { return dark ? 'rgba(255,255,255,0.62)' : 'rgba(0,0,0,0.24)'; }
	return dark ? 'rgba(255,255,255,0.46)' : 'rgba(0,0,0,0.22)';
}

// A garment's pill: the material's pane, the app colour breathing through it,
// the grain and sheen, the lit rim, and the small colour bead.
function jawnosTexturePill(ctx, x, y, w, h, colour, dark) {
	var kind = jawnosTextureCurrent;
	var radius = h / 2;
	if (kind === 'classic') {
		// the clothesline exactly as it was drawn before the materials: a pane of
		// frosted glass, the app colour breathed through it, grain, sheen and a
		// lit rim, with a bead of the colour set in at the left
		ctx.save();
		ctx.beginPath();
		roundRectPath(ctx, x, y, w, h, radius);
		ctx.shadowColor = 'rgba(0,0,0,0.38)';
		ctx.shadowBlur = 9;
		ctx.shadowOffsetY = 3;
		ctx.fillStyle = dark ? 'rgba(48,54,62,0.50)' : 'rgba(255,255,255,0.55)';
		ctx.fill();
		ctx.shadowColor = 'transparent';
		ctx.shadowBlur = 0;
		ctx.shadowOffsetY = 0;
		ctx.globalAlpha = dark ? 0.12 : 0.08;
		ctx.fillStyle = colour;
		ctx.fill();
		ctx.globalAlpha = 1;
		// the old frosted pane's fine gray grain is the sandglass tile
		jawnosTextureGrain(ctx, 'sandglass', dark);
		jawnosTextureSheen(ctx, 'classic', dark, x, y, w, h);
		var oldRim = ctx.createLinearGradient(0, y, 0, y + h);
		if (dark) {
			oldRim.addColorStop(0, 'rgba(255,255,255,0.46)');
			oldRim.addColorStop(0.5, 'rgba(255,255,255,0.10)');
			oldRim.addColorStop(1, 'rgba(255,255,255,0.18)');
		}
		else {
			oldRim.addColorStop(0, 'rgba(0,0,0,0.24)');
			oldRim.addColorStop(0.5, 'rgba(0,0,0,0.07)');
			oldRim.addColorStop(1, 'rgba(0,0,0,0.14)');
		}
		ctx.beginPath();
		roundRectPath(ctx, x, y, w, h, radius);
		ctx.lineWidth = 1;
		ctx.strokeStyle = oldRim;
		ctx.stroke();
		ctx.restore();

		ctx.save();
		ctx.beginPath();
		ctx.arc(x + 14, y + (h / 2), 2.4, 0, Math.PI * 2);
		ctx.fillStyle = colour;
		ctx.shadowColor = colour;
		ctx.shadowBlur = 6;
		ctx.fill();
		ctx.restore();
		return;
	}
	if (kind === 'round') {
		ctx.save();
		ctx.beginPath();
		roundRectPath(ctx, x, y, w, h, radius);
		ctx.shadowColor = 'rgba(0,0,0,0.38)';
		ctx.shadowBlur = 7;
		ctx.shadowOffsetY = 3;
		ctx.fillStyle = colour;
		ctx.fill();
		ctx.shadowColor = 'transparent';
		ctx.shadowBlur = 0;
		ctx.shadowOffsetY = 0;
		var gloss = ctx.createLinearGradient(0, y, 0, y + h);
		gloss.addColorStop(0, 'rgba(255,255,255,0.36)');
		gloss.addColorStop(0.45, 'rgba(255,255,255,0.06)');
		gloss.addColorStop(0.5, 'rgba(255,255,255,0)');
		gloss.addColorStop(1, 'rgba(0,0,0,0.14)');
		ctx.fillStyle = gloss;
		ctx.fill();
		ctx.beginPath();
		roundRectPath(ctx, x, y, w, h, radius);
		ctx.lineWidth = 1;
		ctx.strokeStyle = dark ? 'rgba(255,255,255,0.30)' : 'rgba(0,0,0,0.22)';
		ctx.stroke();
		ctx.restore();
		return;
	}

	ctx.save();
	ctx.beginPath();
	roundRectPath(ctx, x, y, w, h, radius);
	ctx.shadowColor = kind === 'glass' ? 'rgba(0,0,0,0.50)' : 'rgba(0,0,0,0.38)';
	ctx.shadowBlur = kind === 'glass' ? 12 : 8;
	ctx.shadowOffsetY = 3;
	ctx.fillStyle = jawnosTextureBase(kind, dark);
	ctx.fill();
	ctx.shadowColor = 'transparent';
	ctx.shadowBlur = 0;
	ctx.shadowOffsetY = 0;
	ctx.globalAlpha = kind === 'paper' ? 0.08 : 0.12;
	ctx.fillStyle = colour;
	ctx.fill();
	ctx.globalAlpha = 1;
	jawnosTextureGrain(ctx, kind, dark);
	jawnosTextureSheen(ctx, kind, dark, x, y, w, h);
	ctx.beginPath();
	roundRectPath(ctx, x, y, w, h, radius);
	ctx.lineWidth = 1;
	ctx.strokeStyle = jawnosTextureRim(kind, dark);
	ctx.stroke();
	ctx.restore();

	ctx.save();
	ctx.beginPath();
	ctx.arc(x + 14, y + (h / 2), 2.4, 0, Math.PI * 2);
	ctx.fillStyle = colour;
	ctx.shadowColor = colour;
	ctx.shadowBlur = 6;
	ctx.fill();
	ctx.restore();
}

// The label: solid and quiet on round; small uppercase strokes with a recess
// and a catch-light on plain and every material, so it reads as etched rather
// than paint.
function jawnosTextureLabel(ctx, text, x, y, w, h, dark, colour) {
	var kind = jawnosTextureCurrent;
	ctx.save();
	ctx.textBaseline = 'middle';
	if (kind === 'round') {
		ctx.font = '600 15px Arial, Helvetica, sans-serif';
		try { ctx.letterSpacing = '0.2px'; } catch (e) {}
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
	ctx.font = '500 12px Arial, Helvetica, sans-serif';
	try { ctx.letterSpacing = '0.9px'; } catch (e) {}
	var label = ('' + text).toUpperCase();
	var measure = ctx.measureText(label).width;
	var lx = ((w - measure) / 2) + x;
	var ly = y + (h / 2) + 0.5;
	ctx.fillStyle = dark ? 'rgba(0,0,0,0.55)' : 'rgba(255,255,255,0.85)';
	ctx.fillText(label, lx, ly + (dark ? -1 : 1));
	var etched = ctx.createLinearGradient(0, ly - 6, 0, ly + 6);
	if (dark) {
		etched.addColorStop(0, 'rgba(255,255,255,0.90)');
		etched.addColorStop(0.55, 'rgba(232,238,244,0.70)');
		etched.addColorStop(1, 'rgba(255,255,255,0.52)');
	}
	else {
		etched.addColorStop(0, 'rgba(0,0,0,0.88)');
		etched.addColorStop(0.55, 'rgba(28,32,36,0.72)');
		etched.addColorStop(1, 'rgba(0,0,0,0.56)');
	}
	ctx.fillStyle = etched;
	ctx.fillText(label, lx, ly);
	ctx.restore();
}
