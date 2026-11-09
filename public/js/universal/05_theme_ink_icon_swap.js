// ---- theme ink: light text/icons when the background is dark -------------------
function jawnosInk() {
	var c = '';
	try { c = getComputedStyle(document.body).getPropertyValue('--ink'); } catch (e) { c = ''; }
	return (c && c.trim()) || '#000000';
}
// The colour a printer's structural line wears (the timeline's rail, the header's
// divider). The themed ink is right for words, but on a light theme it is pure
// black, and an 8px rail of it reads as a hard black bar lying across the desk.
// The manager colour carries the scheme's hue, so a mid-tone of it belongs to the
// theme on either a light or a dark face; a neutral scheme (Graphite) keeps its
// grey instead of inventing a hue from its meaningless hue angle.
function jawnosPrinterLine() {
	var bg = '';
	try { bg = getComputedStyle(document.body).backgroundColor || ''; } catch (e) { bg = ''; }
	var m = bg.match(/rgba?\(([^)]+)\)/);
	if (m) {
		var parts = m[1].split(',').map(function (x) { return parseFloat(x); });
		// a transparent body has no scheme colour to derive from
		if (parts.length >= 3 && !(parts.length >= 4 && parts[3] === 0)) {
			var hsl = jawnosRgbToHsl(parts[0], parts[1], parts[2]);
			var lum = (0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]) / 255;
			var tint = hsl[1] < 0.08 ? 0 : 0.45;
			return jawnosHslToHex(hsl[0], tint, lum < 0.5 ? 0.62 : 0.45);
		}
	}
	return jawnosInk();
}
// The Misc → Font choice. The layout writes it onto the root as --jawnos-font,
// so the whole shell inherits it; canvas art has no CSS inheritance, so the
// printers read the same value back through here.
function jawnosFont() {
	var f = '';
	try { f = getComputedStyle(document.documentElement).getPropertyValue('--jawnos-font'); } catch (e) { f = ''; }
	return (f && f.trim()) || 'system-ui, sans-serif';
}
// A colour that contrasts with the ink. Canvas art that is drawn over a user's
// background picture cannot trust the themed ink alone (a dark scheme gives
// near-white ink, which vanishes on a light photo), so it gets outlined with
// this instead.
function jawnosInkHalo(ink) {
	var hex = (ink || '#000000').replace('#', '');
	if (hex.length == 3) { hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]; }
	var n = parseInt(hex, 16);
	if (isNaN(n)) { n = 0; }
	var lum = (0.2126 * ((n >> 16) & 255) + 0.7152 * ((n >> 8) & 255) + 0.0722 * (n & 255)) / 255;
	return lum > 0.5 ? 'rgba(0,0,0,0.6)' : 'rgba(255,255,255,0.6)';
}
// Pick black or white for a label sitting on an arbitrary background colour, so
// each item can decide its own text colour from its own fill (a garment tile, a
// coloured chip) rather than trusting the themed ink - a dark theme's near-white
// ink vanishes on a pale garment. WCAG-weighted, the same maths and the same
// ~0.179 tie as subs::contrast_ink, so canvas and templates agree.
function jawnosContrastInk(bg) {
	var hex = ('' + (bg == null ? '' : bg)).replace(/^\s*#/, '').trim();
	if (hex.length == 3) { hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]; }
	if (!/^[0-9a-fA-F]{6}$/.test(hex)) { return '#000000'; }
	var n = parseInt(hex, 16);
	var part = [ (n >> 16) & 255, (n >> 8) & 255, n & 255 ];
	var weight = [ 0.2126, 0.7152, 0.0722 ];
	var lum = 0;
	for (var i = 0; i < 3; i++) {
		var c = part[i] / 255;
		c = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
		lum += c * weight[i];
	}
	return lum < 0.179 ? '#ffffff' : '#000000';
}
// The colour an appointment paints with right now: its own colour on a light
// desktop, and the dark-theme counterpart (settings.dark_colour) while the body
// wears dark_theme. The stored colour is never changed - this only chooses the
// face. Canvas printers call it per draw, so a theme change takes effect on the
// next redraw.
function jawnosApptColour(setting) {
	if (!setting) { return undefined; }
	if (document.body.classList.contains('dark_theme') && setting['dark_colour']) {
		return setting['dark_colour'];
	}
	return setting['colour'];
}
// Repaint the live appointment markup for a changed colour. The server writes
// the two values into the elements as custom properties, so updating them here
// keeps a panel change and a dark-theme switch in step. A window's name span
// carries its app as "'name'" (a legacy quoting quirk), so the app attribute is
// normalised before it is compared.
function jawnosApptNodes(app) {
	var found = $();
	$('[data-appt-tint], [data-appt-ink]').each(function () {
		var a = ('' + ($(this).attr('app') || '')).replace(/^'+|'+$/g, '');
		if (a === app) { found = found.add(this); }
	});
	return found;
}
function jawnosApptColourSet(app, colour, dark) {
	if (!app) { return; }
	var ink = jawnosContrastInk(colour);
	var dark_ink = dark ? jawnosContrastInk(dark) : undefined;
	var nodes = jawnosApptNodes(app);
	nodes.filter('[data-appt-tint]').each(function () {
		if (dark) {
			this.style.setProperty('--appt-dark', dark);
			this.style.setProperty('--appt-dark-ink', dark_ink);
		}
		this.style.backgroundColor = colour;
		this.style.color = ink;
	});
	nodes.filter('[data-appt-ink]').each(function () {
		if (dark) { this.style.setProperty('--appt-dark-ink', dark_ink); }
		this.style.color = ink;
	});
}
function jawnosApptDarkColourSet(app, dark) {
	if (!app || !dark) { return; }
	var dark_ink = jawnosContrastInk(dark);
	jawnosApptNodes(app).each(function () {
		this.style.setProperty('--appt-dark', dark);
		this.style.setProperty('--appt-dark-ink', dark_ink);
	});
}
// Ink for a surface whose colour the caller paints (the sync dot's panel):
// below the same WCAG tie it takes the theme's light ink, otherwise black. On
// a light theme the themed ink is black already, so both branches agree.
function jawnosSurfaceInk(bg) {
	if (jawnosContrastInk(bg) !== '#ffffff') { return '#000000'; }
	// A dark surface wants a light ink. The theme's ink is light only on a dark
	// theme; a light theme's black would vanish here, so fall back to the dark
	// theme's own near-white.
	var ink = jawnosInk();
	return jawnosContrastInk(ink) === '#ffffff' ? ink : '#d4d4d4';
}
// Canvas text for the manager printers. The themed ink alone can vanish over a
// background picture, so when pictures are on the text gets a contrasting SOFT
// SHADOW to sit on. It used to be stroked (ctx.strokeText) instead, which read
// as a hard white/black border around every glyph; the shadow keeps the same
// legibility over a picture without the fringe. Vertical centring is the default
// - the printers reason about marker rows, not baselines.
function jawnosPrinterText(ctx, text, x, y, opts) {
	opts = opts || {};
	ctx.save();
	if (opts.font) { ctx.font = opts.font; }
	if (opts.align) { ctx.textAlign = opts.align; }
	ctx.textBaseline = opts.baseline || 'middle';
	if (opts.alpha != null) { ctx.globalAlpha = opts.alpha; }
	if (opts.halo) {
		ctx.shadowColor = opts.halo;
		ctx.shadowBlur = opts.haloBlur || 4;
	}
	ctx.fillStyle = opts.colour || jawnosInk();
	ctx.fillText('' + text, x, y);
	ctx.restore();
}
// The halo to draw under printer text, or undefined when no picture is up.
function jawnosPrinterHalo() {
	if (localStorage.getItem('background_images') == 'on' && typeof jawnosInkHalo == 'function') {
		return jawnosInkHalo(jawnosInk());
	}
	return undefined;
}
function jawnosRgbToHsl(r, g, b) {
	r /= 255; g /= 255; b /= 255;
	var max = Math.max(r, g, b), min = Math.min(r, g, b);
	var h = 0, s = 0, l = (max + min) / 2, d = max - min;
	if (d) {
		s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
		if (max === r) { h = (g - b) / d + (g < b ? 6 : 0); }
		else if (max === g) { h = (b - r) / d + 2; }
		else { h = (r - g) / d + 4; }
		h *= 60;
	}
	return [h, s, l];
}
function jawnosRgbToHex(r, g, b) {
	var part = function (v) {
		var p = Math.max(0, Math.min(255, Math.round(v))).toString(16);
		return p.length < 2 ? '0' + p : p;
	};
	return '#' + part(r) + part(g) + part(b);
}
function jawnosHslToHex(h, s, l) {
	h = ((h % 360) + 360) % 360;
	var c = (1 - Math.abs(2 * l - 1)) * s;
	var x = c * (1 - Math.abs(((h / 60) % 2) - 1));
	var m = l - c / 2;
	var r = 0, g = 0, b = 0;
	if (h < 60) { r = c; g = x; }
	else if (h < 120) { r = x; g = c; }
	else if (h < 180) { g = c; b = x; }
	else if (h < 240) { g = x; b = c; }
	else if (h < 300) { r = x; b = c; }
	else { r = c; b = x; }
	var part = function (v) { var p = Math.round((v + m) * 255).toString(16); return p.length < 2 ? '0' + p : p; };
	return '#' + part(r) + part(g) + part(b);
}
// Recompute the panel and ink variables from the page background so windows and
// text follow the active colour scheme. configure.js updates the body colour on a
// live scheme change and then calls this, so windows re-theme without a reload.
function jawnosApplyInk(accentOverride, keepExisting) {
	var bg = '';
	try { bg = getComputedStyle(document.body).backgroundColor || ''; } catch (e) { bg = ''; }
	var m = bg.match(/rgba?\(([^)]+)\)/);
	if (!m) { return; }
	var parts = m[1].split(',').map(function (x) { return parseFloat(x); });
	if (parts.length < 3) { return; }
	// a transparent body has no scheme colour to derive from; deriving one from
	// black would flip the ink to white and hide the canvas art
	if (parts.length >= 4 && parts[3] === 0) { return; }
	var r = parts[0], g = parts[1], b = parts[2];
	var lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
	var hsl = jawnosRgbToHsl(r, g, b);
	var tint = hsl[1] < 0.18 ? hsl[1] : 0.18;
	// keep in step with subroutines.pl::theme_panel_css: --line is the chrome
	// border (a shade off --panel), --ink the text (softened from near-white so
	// a dark theme does not glare), and --ink-muted the fainter text/state edge.
	var panel, panel2, ink, ink_muted, line;
	if (lum < 0.5) {
		panel = jawnosHslToHex(hsl[0], tint, 0.16);
		panel2 = jawnosHslToHex(hsl[0], tint, 0.23);
		line = jawnosHslToHex(hsl[0], tint, 0.32);
		ink = '#d4d4d4'; ink_muted = '#8f8f8f';
	}
	else {
		panel = jawnosHslToHex(hsl[0], tint, 0.88);
		panel2 = jawnosHslToHex(hsl[0], tint, 0.80);
		line = jawnosHslToHex(hsl[0], tint, 0.66);
		ink = '#000000'; ink_muted = '#333333';
	}
	// The window surface is its own shade in every scheme: the curated next
	// step of the palette's ramp when the manager colour names a scheme (the
	// manager layout hands that map in), otherwise derived the same way the
	// server's theme_panel_css derives it.
	var bg_hex = jawnosRgbToHex(r, g, b).toLowerCase();
	var window_hex = '';
	if (typeof jawnos_colour_windows != 'undefined' && jawnos_colour_windows) {
		window_hex = jawnos_colour_windows[bg_hex] || '';
	}
	if (!window_hex) {
		window_hex = jawnosHslToHex(hsl[0], tint, lum < 0.5 ? 0.24 : 0.96);
	}
	var style = document.body.style;
	style.setProperty('--panel', panel);
	style.setProperty('--panel-2', panel2);
	style.setProperty('--window', window_hex);
	style.setProperty('--line', line);
	style.setProperty('--ink', ink);
	style.setProperty('--ink-muted', ink_muted);
	// The one loud colour: a theme may name an accent, otherwise the manager hue
	// is pulled to a readable saturation. Keep this in step with
	// subroutines.pl::theme_panel_css so a server-rendered page and a live repaint
	// agree to the hex.
	var accent = '';
	if (accentOverride) {
		var ac = ('' + accentOverride).replace(/^\s*#/, '').trim();
		if (/^[0-9a-fA-F]{6}$/.test(ac)) { accent = '#' + ac.toLowerCase(); }
	}
	else if (keepExisting) {
		// The page was painted by the server with the active bundle's accent;
		// the first run of this function must not overwrite it with a derived
		// one before the person has changed anything.
		var existing = (style.getPropertyValue('--accent') || '').replace(/^\s*#/, '').trim();
		if (/^[0-9a-fA-F]{6}$/.test(existing)) { accent = '#' + existing.toLowerCase(); }
	}
	var accent_h = hsl[0], accent_s = hsl[1], accent_l;
	if (!accent) {
		accent_s = hsl[1] < 0.35 ? 0.58 : (hsl[1] > 0.78 ? 0.78 : hsl[1]);
		if (hsl[1] < 0.12) { accent_s = 0.55; }
		accent_l = lum < 0.5 ? 0.68 : 0.46;
		accent = jawnosHslToHex(accent_h, accent_s, accent_l);
	}
	else {
		var an = parseInt(accent.substring(1), 16);
		var ahsl = jawnosRgbToHsl((an >> 16) & 255, (an >> 8) & 255, an & 255);
		accent_h = ahsl[0]; accent_s = ahsl[1]; accent_l = ahsl[2];
	}
	style.setProperty('--accent', accent);
	style.setProperty('--accent-soft', jawnosHslToHex(accent_h, accent_s, lum < 0.5 ? 0.24 : 0.94));
	style.setProperty('--accent-line', jawnosHslToHex(accent_h, accent_s, lum < 0.5 ? 0.55 : 0.38));
	style.setProperty('--accent-ink', jawnosContrastInk(accent));
	// the icon sets ship a light and a dark cut: when the desktop crosses the
	// light/dark line the buttons on screen have to be asked for again
	var was_dark = document.body.classList.contains('dark_theme');
	var is_dark = lum < 0.5;
	document.body.classList.toggle('dark_theme', is_dark);
	if (was_dark !== is_dark && !window.jawnos_theme_suppress_icon_reload && typeof jawnosReloadIcons === 'function') {
		setTimeout(jawnosReloadIcons, 80);
	}
}
// Paint the manager for a new theme. `appt` marks that a running appointment's
// theme (not the Misc system theme) is in charge, so a later Misc change does
// not paint over it. Deriving the panel/ink variables from the new background
// is the same path a hand-picked manager colour already takes.
function jawnosThemeApply(bg, appt) {
	if (!bg) { return; }
	if (appt) { document.body.setAttribute('data-appt-theme', 'yes'); }
	else { document.body.removeAttribute('data-appt-theme'); }
	document.body.style.backgroundColor = bg;
	// This ad-hoc repaint is not the active theme's signature any more: the next
	// bundle push must be allowed to land rather than comparing against a stale
	// one and becoming a no-op.
	document.body.removeAttribute('data-theme-sig');
	jawnosApplyInk();
}
// The cursor set is CSS-only: the sheet carries every set's role -> image
// mapping, and the body's data-cursor-set picks one. A theme push moves the
// attribute; no stylesheet is rebuilt and no window re-renders.
function jawnosCursorApply(set) {
	if (set) { document.body.setAttribute('data-cursor-set', set); }
	else { document.body.removeAttribute('data-cursor-set'); }
}

// A whole dressing arrives at once: paint, glyphs, cursor, material, face, corner and
// accent. The server sends this over the websocket when a start/stop moves the
// active theme, so the desk changes without a reload. Empty fields mean "leave
// the Misc choice alone", which is what a bare colour-scheme row needs.
function jawnosThemeBundleApply(bundle, appt) {
	if (typeof bundle === 'string') { try { bundle = JSON.parse(bundle); } catch (e) { return; } }
	if (!bundle || typeof bundle !== 'object') { return; }
	if (bundle.appointment != null) { appt = bundle.appointment; }
	// The appointment flag answers on its own: a start/stop on the same theme
	// changes only who owns the desk, not how it is painted.
	if (appt) { document.body.setAttribute('data-appt-theme', 'yes'); }
	else { document.body.removeAttribute('data-appt-theme'); }
	// A signature is the whole dressing in one string. An unchanged push is a
	// no-op: a start or stop that does not move the theme must not reload a
	// single window.
	var sig = ('signature' in bundle) ? ('' + bundle.signature) : '';
	var current = document.body.getAttribute('data-theme-sig') || '';
	if (sig && sig === current) { return; }
	if (bundle.background) {
		document.body.style.backgroundColor = bundle.background;
	}
	if (bundle.font) {
		document.documentElement.style.setProperty('--jawnos-font', bundle.font);
	}
	if (bundle.corner) {
		window.jawnos_theme_corner = bundle.corner;
		document.documentElement.style.setProperty('--jawnos-corner', bundle.corner);
	}
	else {
		// no theme corner: hand the property back to the desk's own value, so a
		// theme that stands down while the page is open lands on the Misc slider
		window.jawnos_theme_corner = '';
		document.documentElement.style.setProperty('--jawnos-corner', 'var(--corner_radius, 12px)');
	}
	// the Misc panel's Corner slider follows whether a theme is in charge: with
	// one, its changes are an override on top of the theme's corner
	if (typeof jawnosBars !== 'undefined' && jawnosBars) { jawnosBars.corner_theme = window.jawnos_theme_corner || ''; }
	if (bundle.texture && typeof jawnosTextureApply === 'function') {
		jawnosTextureApply(bundle.texture);
	}
	// Paint, material and face repaint live through the CSS variables and the
	// dark-theme wash, so no window is re-rendered: an app keeps its playing
	// audio and its place. A window's title bar and drawer wear the app's own
	// colour and --appt-dark, not the theme's, so they follow with no HTML
	// either. The start menu is the one server-rendered dock whose markup bakes
	// its icon paths and theme colours, so jawnosReloadIcons rebuilds that and
	// the taskbar. The early return above filtered an unchanged push, so a start
	// or stop on the same theme still reloads nothing.
	window.jawnos_theme_suppress_icon_reload = true;
	jawnosApplyInk(bundle.accent || '');
	window.jawnos_theme_suppress_icon_reload = false;
	if ('icon_set' in bundle) { document.body.setAttribute('data-icon-set', bundle.icon_set || ''); }
	if ('cursor_set' in bundle) { jawnosCursorApply(bundle.cursor_set || ''); }
	if (typeof jawnosReloadIcons === 'function') { setTimeout(jawnosReloadIcons, 60); }
	if (sig) { document.body.setAttribute('data-theme-sig', sig); }
}
$(function () { jawnosApplyInk('', true); });

// ---- icon set swap: refresh the icons currently on screen ----------------------
// Called over the websocket after the pseudonym icon set changes; swaps the
// icons already on screen and rebuilds the start-menu dock from them. It never
// re-renders a window: an app's contents repaint from the theme's CSS, and a
// re-render would stop Music and lose Configure's place.

// The now button wears the state of the time machine in its tile: the same
// yellow the button's background turns at home, and the same blue it turns
// while the machine is walking. Every icon set keeps the pair beside its plain
// now tile - "now here" and "now time machine" - so each answers the state in
// its own colours; the hand-drawn set, and any set built before the pair
// existed, keep the plain icon. The pair is derived from the plain now tile in
// the button's src, which is what both the template and the set-change reload
// put there.
function nowIconApply(state) {
	var button = $('#now_toggle');
	if (button.length == 0) { return; }
	var src = button.attr('src') || '';
	var match = src.match(/^(.*\/)now( here| time machine)?\.svg$/i);
	if (!match) { return; }
	button.attr('src', match[1] + 'now' + (state == 'time_machine' ? ' time machine' : ' here') + '.svg');
}

// Coalesces the chrome refresh a theme change asks for: the ink pass and the
// bundle can arrive together, and one round of the dock is enough.
var jawnos_icon_redraw_timer = null;

function jawnosReloadIcons() {
	try {
		// The desktop's own buttons were rendered with the old set, and only the
		// server knows where a path lives in the new one, so ask it for those
		// paths again and swap the sources. Icons rendered through icon_path()
		// and icon_for() - the taskbar, the start menu, window titles and the
		// appointment wrapper - carry no jawnos_icon attribute, so their current
		// src is asked for instead: the server re-maps its basename into the cut
		// that is now showing. Without them a light/dark change left those icons
		// on the old cut (the yellow taskbar tiles were the visible case).
		var nodes = $('[jawnos_icon], img[src*="/icons/sets/"], img[src*="/icons/original/"]');
		if (nodes.length > 0) {
			var paths = [];
			nodes.each(function () {
				var p = $(this).attr('jawnos_icon') || $(this).attr('src');
				if (p && paths.indexOf(p) == -1) { paths.push(p); }
			});
			$.ajax({
				url: '/manager/icons',
				type: 'GET',
				data: { paths: JSON.stringify(paths), refresh: 1 },
				success: function (response) {
					nodes.each(function () {
						var p = $(this).attr('jawnos_icon') || $(this).attr('src');
						if (response.icons && response.icons[p]) { $(this).attr('src', response.icons[p]); }
					});
					// that swap put the plain now tile back; let it answer the state
					nowIconApply(localStorage.getItem('time_machine') ? 'time_machine' : 'here');
				}
			});
		}
		// The start menu keeps its markup per tab, so the paths baked into it are
		// stale the moment the cut changes; drop that cache now so reopening a tab
		// cannot put the old cut back.
		if (typeof startMenuHtmlFlush === 'function') { startMenuHtmlFlush(); }
		// The start menu asks the server for its markup and icon paths again,
		// and a prefork worker that rendered an icon within the last second
		// still holds the previous cut in its one-second memo. Wait that out
		// before asking, or a stale worker can put the old cut back. The icons
		// on screen are already correct from the src swap, so the wait is
		// invisible; the taskbar is rebuilt from those same icons below. No
		// window is re-opened here: the desk repaints in place.
		clearTimeout(jawnos_icon_redraw_timer);
		jawnos_icon_redraw_timer = setTimeout(function () {
			// refresh an open start menu (passing `source` skips the close branch)
			if (typeof startMenuToggle === 'function' && $('#start_menu').is(':visible')) {
				startMenuToggle({ source: 'icon_refresh' });
			}
			if (typeof startMenuListify === 'function') { startMenuListify(); }
			if (typeof taskbarDisplayer === 'function') {
				setTimeout(function () { taskbarDisplayer(); }, 1200);
			}
		}, 1200);
	} catch (e) {}
}

