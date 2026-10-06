#!/usr/bin/env node
// JawnOS icon generator.
//
// Writes SVG masters into this folder and renders PNGs straight into public/,
// replacing the old hand-drawn icons at the same paths (drop-in).
//
//   node public/icons/src/build.js
//
// Glyphs are drawn on a 24x24 grid (like most icon sets) and scaled into place
// so the whole set stays geometrically consistent. Each icon is a macOS-style
// rounded square with a subtle vertical gradient and a white glyph.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const DIR = __dirname;
const PUBLIC = path.resolve(DIR, '..', '..');
const SIZE = 256;

// --- palette (muted / grey-based; base and a lighter top for the gradient) ---
const PALETTE = {
	blue:   ['#5E7291', '#7E92B1'],
	indigo: ['#6A6E92', '#8A8EB1'],
	purple: ['#7A6E92', '#9A8EB1'],
	pink:   ['#93707D', '#B1909C'],
	red:    ['#946E6E', '#B38E8E'],
	orange: ['#94795F', '#B3997F'],
	yellow: ['#8F8A5F', '#ADA87F'],
	green:  ['#6B8268', '#8BA288'],
	teal:   ['#5F807E', '#7FA09E'],
	slate:  ['#707A86', '#909AA6'],
};

// --- glyphs on a 24x24 grid -----------------------------------------------------
const GLYPHS = {
	folder: '<path d="M3 7a2 2 0 0 1 2-2h3.2l2 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
	chart: '<rect x="3.5" y="12" width="3.6" height="8" rx="1.2"/><rect x="10.2" y="6" width="3.6" height="14" rx="1.2"/><rect x="16.9" y="9" width="3.6" height="11" rx="1.2"/>',
	aeroplane: '<path d="M21 16v-2l-8-5V3.5a1.5 1.5 0 0 0-3 0V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5z"/>',
	chat: '<path d="M11 8.5h7A2.5 2.5 0 0 1 20.5 11v4A2.5 2.5 0 0 1 18 17.5h-1.2v3l-3.2-3H11A2.5 2.5 0 0 1 8.5 15v-4A2.5 2.5 0 0 1 11 8.5z" fill="#000000" fill-opacity="0.18"/><path d="M6 3.5h8A2.5 2.5 0 0 1 16.5 6v4A2.5 2.5 0 0 1 14 12.5h-4.6L6.2 15.5v-3H6A2.5 2.5 0 0 1 3.5 10V6A2.5 2.5 0 0 1 6 3.5z"/>',
	envelope: '<rect x="3" y="5.5" width="18" height="13" rx="2.4"/><path d="M4.4 7.5 12 13l7.6-5.5" fill="none" stroke="#000000" stroke-opacity="0.15" stroke-width="0.4" stroke-linecap="round" stroke-linejoin="round"/>',
	music: '<circle cx="6.6" cy="17.4" r="2.7"/><circle cx="17.4" cy="15.4" r="2.7"/><rect x="7.8" y="4.2" width="1.8" height="13.2"/><rect x="18.6" y="2.2" width="1.8" height="13.2"/><rect x="7.8" y="4.2" width="12.6" height="2.3" rx="1.1"/>',
	microchip: '<rect x="9.5" y="3" width="1.6" height="3"/><rect x="12.9" y="3" width="1.6" height="3"/><rect x="9.5" y="18" width="1.6" height="3"/><rect x="12.9" y="18" width="1.6" height="3"/><rect x="3" y="9.5" width="3" height="1.6"/><rect x="3" y="12.9" width="3" height="1.6"/><rect x="18" y="9.5" width="3" height="1.6"/><rect x="18" y="12.9" width="3" height="1.6"/><rect x="6" y="6" width="12" height="12" rx="2.4"/><rect x="9.4" y="9.4" width="5.2" height="5.2" rx="1.2" fill="#000000" fill-opacity="0.16"/>',
	ticket: '<rect x="2.5" y="6.5" width="19" height="11" rx="2"/><path d="M8.5 7.2v9.6" fill="none" stroke="#000000" stroke-opacity="0.18" stroke-width="0.5" stroke-dasharray="1.1 1.1"/>',
	cards: '<rect x="9.5" y="3.5" width="9.5" height="14.5" rx="2" fill="#000000" fill-opacity="0.18"/><rect x="5" y="6" width="9.5" height="14.5" rx="2"/>',
	globe: '<circle cx="12" cy="12" r="9"/><g fill="none" stroke="#000000" stroke-opacity="0.18" stroke-width="0.7"><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3.4 9.2h17.2M3.4 14.8h17.2"/></g>',
	diskette: '<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="8.8" y="4" width="6.4" height="6.4" fill="#000000" fill-opacity="0.18"/><rect x="7" y="13" width="10" height="7" rx="1" fill="#000000" fill-opacity="0.18"/>',
	shield: '<path d="M12 2.5 20 5.6v5.9c0 4.6-3.2 8.6-8 10.1-4.8-1.5-8-5.5-8-10.1V5.6z"/><path d="M8.3 11.8l2.6 2.6 4.8-5" fill="none" stroke="#000000" stroke-opacity="0.18" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>',
	code: '<path d="M9 7 4 12l5 5" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M15 7l5 5-5 5" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M13.4 5.5 10.6 18.5" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round"/>',
	monitor: '<rect x="3" y="4.5" width="18" height="12" rx="2"/><rect x="11" y="16.5" width="2" height="2.6"/><rect x="8" y="19.1" width="8" height="1.8" rx="0.9"/>',
	upload: '<path d="M12 3 18 9.6h-3.6V14.4H9.6V9.6H6z"/><path d="M4 15.8v3.2a1.5 1.5 0 0 0 1.5 1.5h13a1.5 1.5 0 0 0 1.5-1.5v-3.2" fill="none" stroke="#ffffff" stroke-width="1.9" stroke-linecap="round"/>',
	image: '<rect x="3" y="4.5" width="18" height="15" rx="2.2"/><circle cx="8.2" cy="9.6" r="1.8" fill="#000000" fill-opacity="0.18"/><path d="M4 18.2 9.2 12l3.2 3.6L15 13l5 5.2z" fill="#000000" fill-opacity="0.18"/>',
	piano: '<rect x="3" y="5" width="18" height="14" rx="2"/><g stroke="#000000" stroke-opacity="0.12" stroke-width="0.5"><path d="M7.5 5v14M12 5v14M16.5 5v14"/></g><g fill="#000000" fill-opacity="0.18"><rect x="6.1" y="5" width="2.3" height="8.6"/><rect x="10.6" y="5" width="2.3" height="8.6"/><rect x="15.1" y="5" width="2.3" height="8.6"/></g>',
	pencil: '<path d="M4.5 19.5l.9-3.6L15.6 5.7a1.7 1.7 0 0 1 2.4 0l.3.3a1.7 1.7 0 0 1 0 2.4L8.1 18.6z"/><path d="M5.4 15.9 8.4 18.6 4.5 19.5z" fill="#000000" fill-opacity="0.18"/>',
	marker: '<rect x="9" y="3.5" width="6" height="8.5" rx="1.4"/><path d="M9 12h6l-1.2 3.4a1.6 1.6 0 0 1-1.5 1h-.6a1.6 1.6 0 0 1-1.5-1z"/><rect x="4.5" y="19" width="15" height="1.8" rx="0.9" fill="#000000" fill-opacity="0.18"/>',
	stop: '<path d="M8.2 2.5h7.6l5.7 5.7v7.6l-5.7 5.7H8.2l-5.7-5.7V8.2z"/><path d="M9 5h6l4 4v6l-4 4H9l-4-4V9z" fill="none" stroke="#000000" stroke-opacity="0.18" stroke-width="0.8"/>',
	tetris: '<rect x="3" y="3" width="6" height="6" rx="1"/><rect x="9" y="3" width="6" height="6" rx="1"/><rect x="9" y="9" width="6" height="6" rx="1"/><rect x="15" y="9" width="6" height="6" rx="1"/>',
	sliders: '<g stroke="#000000" stroke-opacity="0.18" stroke-width="1.4" stroke-linecap="round"><path d="M7 4v16M12 4v16M17 4v16"/></g><circle cx="7" cy="9" r="2.4"/><circle cx="12" cy="15" r="2.4"/><circle cx="17" cy="7" r="2.4"/>',
	book: '<path d="M11.4 6.4C9.4 5 6.6 4.4 3.5 4.9v12.3c3.1-.5 5.9.1 7.9 1.5z"/><path d="M12.6 6.4c2-1.4 4.8-2 7.9-1.5v12.3c-3.1-.5-5.9.1-7.9 1.5z"/>',
	mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M6.5 11.5a5.5 5.5 0 0 0 11 0" fill="none" stroke="#ffffff" stroke-width="1.8" stroke-linecap="round"/><rect x="11" y="16.4" width="2" height="3.2"/><rect x="8.5" y="19.4" width="7" height="1.8" rx="0.9"/>',
	moon: '<path d="M20.2 14.8A8.6 8.6 0 1 1 9.2 3.8a6.9 6.9 0 0 0 11 11z"/>',
	bubble: '<path d="M4 4.5h16A2.5 2.5 0 0 1 22.5 7v8A2.5 2.5 0 0 1 20 17.5h-8.6L6.5 21.5v-4H4A2.5 2.5 0 0 1 1.5 15V7A2.5 2.5 0 0 1 4 4.5z"/><g fill="#000000" fill-opacity="0.18"><circle cx="8" cy="11" r="1.15"/><circle cx="12" cy="11" r="1.15"/><circle cx="16" cy="11" r="1.15"/></g>',
	thumbsup: '<path d="M1 21h4V9H1v12zm22-11c0-1.1-.9-2-2-2h-6.31l.95-4.57.03-.32c0-.41-.17-.79-.44-1.06L14.17 1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73V10z"/>',
	ruler: '<path d="M3.6 16.4 16.4 3.6l4 4L7.6 20.4z"/><g stroke="#000000" stroke-opacity="0.18" stroke-width="0.7"><path d="M7.2 13.2l2 2M10.2 10.2l2 2M13.2 7.2l2 2"/></g>',
	person: '<circle cx="12" cy="7.6" r="4.1"/><path d="M4 20.5c0-4.2 3.6-6.9 8-6.9s8 2.7 8 6.9z"/><path d="M12 13.6l1.7 2.3-1.7 4.6-1.7-4.6z" fill="#000000" fill-opacity="0.18"/>',
	warehouse: '<path d="M3 20V9.6L12 4l9 5.6V20z"/><rect x="9.4" y="13.6" width="5.2" height="6.4" fill="#000000" fill-opacity="0.18"/>',
	exit: '<path d="M10.5 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20h4" fill="none" stroke="#ffffff" stroke-width="1.9" stroke-linecap="round"/><path d="M9.5 12H20" fill="none" stroke="#ffffff" stroke-width="1.9" stroke-linecap="round"/><path d="M16 8.5 19.5 12 16 15.5" fill="none" stroke="#ffffff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>',
};

// --- icons: key -> glyph, colour and the public path it replaces -----------------
const ICONS = {
	folder:       { g: 'folder',    c: 'blue',   out: 'images/decipherable/folder.png' },
	chart:        { g: 'chart',     c: 'orange', out: 'images/decipherable/chart.png' },
	aeroplane:    { g: 'aeroplane', c: 'teal',   out: 'images/decipherable/aeroplane.png' },
	relational:   { g: 'chat',      c: 'pink',   out: 'images/make believe/strawbeery.png' },
	envelope:     { g: 'envelope',  c: 'indigo', out: 'images/decipherable/envelope.png' },
	music:        { g: 'music',     c: 'purple', out: 'images/make believe/music.png' },
	microchip:    { g: 'microchip', c: 'green',  out: 'images/decipherable/microchip.png' },
	ticket:       { g: 'ticket',    c: 'yellow', out: 'images/decipherable/ticket.png' },
	cards:        { g: 'cards',     c: 'red',    out: 'images/decipherable/cards.png' },
	web:          { g: 'globe',     c: 'blue',   out: 'images/make believe/web_button.png' },
	diskette:     { g: 'diskette',  c: 'slate',  out: 'images/decipherable/diskette.png' },
	security:     { g: 'shield',    c: 'red',    out: 'images/make believe/badge.png' },
	code:         { g: 'code',      c: 'slate',  out: 'images/decipherable/code.png' },
	ide:          { g: 'monitor',   c: 'blue',   out: 'images/make believe/monitor.png' },
	upload:       { g: 'upload',    c: 'green',  out: 'images/make believe/up.png' },
	gallery:      { g: 'image',     c: 'pink',   out: 'images/decipherable/gallery.png' },
	piano:        { g: 'piano',     c: 'purple', out: 'images/decipherable/piano.png' },
	editor:       { g: 'pencil',    c: 'indigo', out: 'images/decipherable/love letter.png' },
	marker:       { g: 'marker',    c: 'orange', out: 'images/decipherable/marker.png' },
	stop:         { g: 'stop',      c: 'red',    out: 'images/decipherable/stop sign.png' },
	tetris:       { g: 'tetris',    c: 'indigo', out: 'images/decipherable/tetris.png' },
	mixer:        { g: 'sliders',   c: 'teal',   out: 'images/decipherable/mixer.png' },
	handbook:     { g: 'book',      c: 'slate',  out: 'images/decipherable/handbook.png' },
	microphone:   { g: 'mic',       c: 'purple', out: 'images/decipherable/speech to text.png' },
	nightlight:   { g: 'moon',      c: 'indigo', out: 'images/decipherable/nightlight.png' },
	sms:          { g: 'bubble',    c: 'teal',   out: 'images/make believe/phone_sms.png' },
	good:         { g: 'thumbsup',  c: 'green',  out: 'images/make believe/good.png' },
	measures:     { g: 'ruler',     c: 'yellow', out: 'images/decipherable/measures.png' },
	vendor:       { g: 'person',    c: 'orange', out: 'icons/pos/vendor.png' },
	manufacturer: { g: 'warehouse', c: 'slate',  out: 'icons/pos/manufacturer.png' },
	exit:         { g: 'exit',      c: 'red',    out: 'images/decipherable/exit.png' },
};

function makeSvg(colour, glyph) {
	const [base, light] = PALETTE[colour];
	return `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
\t<defs>
\t\t<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
\t\t\t<stop offset="0" stop-color="${light}"/>
\t\t\t<stop offset="1" stop-color="${base}"/>
\t\t</linearGradient>
\t</defs>
	<rect x="48" y="48" width="416" height="416" rx="102" fill="url(#bg)" stroke="#000000" stroke-opacity="0.18" stroke-width="4"/>
	<g transform="translate(124,124) scale(11)" fill="#ffffff">${glyph}</g>
</svg>
`;
}

const names = Object.keys(ICONS);
const rendered = [];
for (const name of names) {
	const { g, c, out } = ICONS[name];
	fs.writeFileSync(path.join(DIR, name + '.svg'), makeSvg(c, GLYPHS[g]));
	const target = path.join(PUBLIC, out);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	execFileSync('rsvg-convert', ['-w', String(SIZE), '-h', String(SIZE), path.join(DIR, name + '.svg'), '-o', target]);
	rendered.push(target);
}

// contact sheet
let montage = 'montage';
let montageArgs = [];
try { execFileSync('which', ['montage']); } catch (e) { montage = 'magick'; montageArgs = ['montage']; }
execFileSync(montage, [...montageArgs, ...rendered, '-tile', '8x', '-geometry', '110x110+10+10', '-background', '#efe9df', path.join(DIR, 'preview.png')]);

console.log('Wrote ' + names.length + ' icons into public/ + preview.png');
