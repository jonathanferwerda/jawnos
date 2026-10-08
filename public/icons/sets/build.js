#!/usr/bin/env node
// JawnOS pseudonym icon-set generator.
//
//   node public/icons/sets/build.js
//
// Writes public/icons/sets/<style>/<icon>.svg for every pseudonym button icon.
// Each set is the same glyph library rendered in a different visual style, so
// the whole button row can be reskinned from the configure screen.
//
// Glyph convention (all on a 24x24 grid, scaled into a 512 master):
//   {G} -> the glyph colour for the style
//   {D} -> a contrasting "detail" colour for the style

const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const SIZE = 512;

const hsl = (h, s, l) => {
	h = ((h % 360) + 360) % 360;
	return 'hsl(' + Math.round(h) + ',' + Math.round(s * 100) + '%,' + Math.round(l * 100) + '%)';
};

// --- glyphs --------------------------------------------------------------------
const GLYPHS = {
	frog: '<circle cx="12" cy="13.5" r="6.5" fill="{G}"/><circle cx="8.8" cy="9.6" r="2.7" fill="{G}"/><circle cx="15.2" cy="9.6" r="2.7" fill="{G}"/><circle cx="8.8" cy="9.6" r="1.1" fill="{D}"/><circle cx="15.2" cy="9.6" r="1.1" fill="{D}"/><path d="M8.5 15.5q3.5 2.6 7 0" fill="none" stroke="{D}" stroke-width="1.3" stroke-linecap="round"/>',
	sun: '<circle cx="12" cy="12" r="5" fill="{G}"/><g stroke="{G}" stroke-width="1.8" stroke-linecap="round"><path d="M12 2v2.4M12 19.6V22M2 12h2.4M19.6 12H22M5 5l1.7 1.7M17.3 17.3 19 19M19 5l-1.7 1.7M6.7 17.3 5 19"/></g>',
	headphones: '<path d="M4 14v-2a8 8 0 0 1 16 0v2" fill="none" stroke="{G}" stroke-width="2.2" stroke-linecap="round"/><rect x="3" y="13" width="4.6" height="7" rx="2.2" fill="{G}"/><rect x="16.4" y="13" width="4.6" height="7" rx="2.2" fill="{G}"/>',
	keyboard: '<rect x="2.5" y="7" width="19" height="10.5" rx="2" fill="{G}"/><g fill="{D}"><rect x="5" y="9.3" width="2" height="1.8" rx="0.5"/><rect x="8.4" y="9.3" width="2" height="1.8" rx="0.5"/><rect x="11.8" y="9.3" width="2" height="1.8" rx="0.5"/><rect x="15.2" y="9.3" width="2" height="1.8" rx="0.5"/><rect x="6.5" y="13" width="11" height="2" rx="0.6"/></g>',
	calculator: '<rect x="5" y="2.5" width="14" height="19" rx="2.4" fill="{G}"/><rect x="7.5" y="5" width="9" height="3.2" rx="0.8" fill="{D}"/><g fill="{D}"><circle cx="8.6" cy="12" r="1.1"/><circle cx="12" cy="12" r="1.1"/><circle cx="15.4" cy="12" r="1.1"/><circle cx="8.6" cy="15.6" r="1.1"/><circle cx="12" cy="15.6" r="1.1"/><circle cx="15.4" cy="15.6" r="1.1"/><circle cx="8.6" cy="19" r="1.1"/><circle cx="12" cy="19" r="1.1"/><circle cx="15.4" cy="19" r="1.1"/></g>',
	bell: '<path d="M12 2.5A1.6 1.6 0 0 1 13.6 4.1v.5A6 6 0 0 1 17.8 10.3v3.2l1.6 2.5H4.6l1.6-2.5v-3.2A6 6 0 0 1 10.4 4.6v-.5A1.6 1.6 0 0 1 12 2.5z" fill="{G}"/><path d="M9.8 18.2a2.2 2.2 0 0 0 4.4 0z" fill="{G}"/>',
	terminal: '<rect x="2.5" y="4" width="19" height="15" rx="2" fill="{G}"/><path d="M6 9l3 2.5L6 14" fill="none" stroke="{D}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><path d="M11.5 14.2h5" fill="none" stroke="{D}" stroke-width="1.5" stroke-linecap="round"/>',
	heart: '<path d="M12 20.5C5.5 16 3 12.8 3 9.4A4.6 4.6 0 0 1 7.6 5c1.8 0 3.3 1 4.4 2.6C13.1 6 14.6 5 16.4 5A4.6 4.6 0 0 1 21 9.4c0 3.4-2.5 6.6-9 11.1z" fill="{G}"/>',
	record: '<circle cx="12" cy="12" r="8.5" fill="{G}"/><circle cx="12" cy="12" r="3.2" fill="{D}"/>',
	pencil: '<path d="M4.5 19.5l.9-3.6L15.6 5.7a1.7 1.7 0 0 1 2.4 0l.3.3a1.7 1.7 0 0 1 0 2.4L8.1 18.6z" fill="{G}"/><path d="M5.4 15.9 8.4 18.6 4.5 19.5z" fill="{D}"/>',
	play: '<path d="M7 4.5 19.5 12 7 19.5z" fill="{G}"/>',
	prev: '<path d="M6 5h2.4v14H6z" fill="{G}"/><path d="M19.5 5v14L9 12z" fill="{G}"/>',
	next: '<path d="M18 5h-2.4v14H18z" fill="{G}"/><path d="M4.5 5 15 12 4.5 19z" fill="{G}"/>',
	stop: '<rect x="5" y="5" width="14" height="14" rx="2.4" fill="{G}"/>',
	president: '<path d="M12 2.5 14.9 9l7 .6-5.3 4.6 1.6 6.9L12 17.6 5.8 21.1l1.6-6.9L2.1 9.6 9.1 9z" fill="{G}"/>',
	mailbox: '<path d="M4 10h16v9.5H4z" fill="{G}"/><path d="M3 10 12 3.5 21 10z" fill="{G}"/><rect x="10.6" y="12.4" width="2.8" height="4.4" rx="1.4" fill="{D}"/><path d="M19.5 5.5v3.5" fill="none" stroke="{G}" stroke-width="1.4" stroke-linecap="round"/><path d="M19.5 4.5h3v3h-3z" fill="{G}"/>',
	check: '<circle cx="12" cy="12" r="9" fill="{G}"/><path d="M8 12.2 11 15.2 16.3 9.2" fill="none" stroke="{D}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
	camera: '<path d="M17 10.5V7c0-.55-.45-1-1-1H4c-.55 0-1 .45-1 1v10c0 .55.45 1 1 1h12c.55 0 1-.45 1-1v-3.5l4 4v-11l-4 4z" fill="{G}"/>',
	eye: '<path d="M12 5.5C6.5 5.5 2.7 9.6 1.5 12c1.2 2.4 5 6.5 10.5 6.5S21.3 14.4 22.5 12C21.3 9.6 17.5 5.5 12 5.5z" fill="{G}"/><circle cx="12" cy="12" r="3.4" fill="{D}"/><circle cx="12" cy="12" r="1.4" fill="{G}"/>',
	marker: '<rect x="9" y="3.5" width="6" height="8.5" rx="1.4" fill="{G}"/><path d="M9 12h6l-1.2 3.4a1.6 1.6 0 0 1-1.5 1h-.6a1.6 1.6 0 0 1-1.5-1z" fill="{G}"/><rect x="4.5" y="19" width="15" height="1.8" rx="0.9" fill="{D}"/>',
	monitor: '<rect x="3" y="4.5" width="18" height="12" rx="2" fill="{G}"/><rect x="5.2" y="6.8" width="13.6" height="8.2" rx="1" fill="{D}"/><rect x="11" y="16.5" width="2" height="2.6" fill="{G}"/><rect x="8" y="19.1" width="8" height="1.8" rx="0.9" fill="{G}"/>',
	mic: '<rect x="9" y="3" width="6" height="11" rx="3" fill="{G}"/><path d="M6.5 11.5a5.5 5.5 0 0 0 11 0" fill="none" stroke="{G}" stroke-width="1.9" stroke-linecap="round"/><rect x="11" y="16.4" width="2" height="3.2" fill="{G}"/><rect x="8.5" y="19.4" width="7" height="1.8" rx="0.9" fill="{G}"/>',
	renew: '<path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3" fill="none" stroke="{G}" stroke-width="2.2" stroke-linecap="round"/><path d="M20 3.5v5h-5z" fill="{G}"/>',
	x: '<circle cx="12" cy="12" r="9" fill="{G}"/><path d="M8.5 8.5 15.5 15.5M15.5 8.5 8.5 15.5" fill="none" stroke="{D}" stroke-width="2.2" stroke-linecap="round"/>',
	telephone: '<path d="M7.5 3.5 10 8l-2 2c1 2.2 2.8 4 5 5l2-2 4.5 2.5-1.2 3A2.4 2.4 0 0 1 15.9 20 16 16 0 0 1 4 8.1a2.4 2.4 0 0 1 1.5-2.4z" fill="{G}"/>',
	hourglass: '<path d="M6 2.5h12v4l-4 5.5 4 5.5v4H6v-4l4-5.5-4-5.5z" fill="{G}"/>',
	receipt: '<path d="M3 22l1.5-1.5L6 22l1.5-1.5L9 22l1.5-1.5L12 22l1.5-1.5L15 22l1.5-1.5L18 22l1.5-1.5L21 22V2l-1.5 1.5L18 2l-1.5 1.5L15 2l-1.5 1.5L12 2l-1.5 1.5L9 2 7.5 3.5 6 2 4.5 3.5 3 2z" fill="{G}"/><g stroke="{D}" stroke-width="1.3" stroke-linecap="round"><path d="M6.5 8h11M6.5 11.5h11M6.5 15h7"/></g>',
	cake: '<path d="M4 20.5v-5.5h16v5.5z" fill="{G}"/><path d="M4 15c0-1.5 1.2-2.6 2.7-2.6 1 0 1.9.6 2.4 1.5.5-.9 1.4-1.5 2.4-1.5s1.9.6 2.4 1.5c.5-.9 1.4-1.5 2.4-1.5C19.8 12.4 21 13.5 21 15" fill="none" stroke="{G}" stroke-width="1.8" stroke-linejoin="round"/><rect x="11.3" y="5.5" width="1.5" height="5.5" rx="0.7" fill="{G}"/><circle cx="12" cy="5" r="1.3" fill="{D}"/>',
	box: '<path d="M3.5 8 12 4l8.5 4v8L12 20 3.5 16z" fill="{G}"/><path d="M3.5 8 12 12l8.5-4M12 12v8" fill="none" stroke="{D}" stroke-width="1.4" stroke-linejoin="round"/>',
	upload: '<path d="M12 3 18 9.6h-3.6V14.4H9.6V9.6H6z" fill="{G}"/><path d="M4 15.8v3.2a1.5 1.5 0 0 0 1.5 1.5h13a1.5 1.5 0 0 0 1.5-1.5v-3.2" fill="none" stroke="{G}" stroke-width="1.9" stroke-linecap="round"/>',
	badge: '<circle cx="12" cy="8.8" r="5.2" fill="{G}"/><path d="M9.2 13 7.6 21l4.4-2.3L16.4 21 14.8 13z" fill="{D}"/>',
	key: '<circle cx="8" cy="8" r="4.5" fill="{G}"/><circle cx="8" cy="8" r="1.6" fill="{D}"/><path d="M11.2 11.2 20 20M16.5 16.5l2-2M18.6 18.6l1.6-1.6" fill="none" stroke="{G}" stroke-width="2.2" stroke-linecap="round"/>',
	diskette: '<rect x="4" y="4" width="16" height="16" rx="2" fill="{G}"/><rect x="8.8" y="4" width="6.4" height="6.4" fill="{D}"/><rect x="7" y="13" width="10" height="7" rx="1" fill="{D}"/>',
	image: '<rect x="3" y="4.5" width="18" height="15" rx="2.2" fill="{G}"/><circle cx="8.2" cy="9.6" r="1.8" fill="{D}"/><path d="M4 18.2 9.2 12l3.2 3.6L15 13l5 5.2z" fill="{D}"/>',
	exit: '<path d="M10.5 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20h4" fill="none" stroke="{G}" stroke-width="1.9" stroke-linecap="round"/><path d="M9.5 12H20" fill="none" stroke="{G}" stroke-width="1.9" stroke-linecap="round"/><path d="M16 8.5 19.5 12 16 15.5" fill="none" stroke="{G}" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>',
	sliders: '<g stroke="{D}" stroke-width="1.6" stroke-linecap="round"><path d="M7 4v16M12 4v16M17 4v16"/></g><circle cx="7" cy="9" r="2.4" fill="{G}"/><circle cx="12" cy="15" r="2.4" fill="{G}"/><circle cx="17" cy="7" r="2.4" fill="{G}"/>',
	dollar: '<circle cx="12" cy="12" r="9" fill="{G}"/><path d="M12 5.6v12.8" fill="none" stroke="{D}" stroke-width="1.5" stroke-linecap="round"/><path d="M14.8 9c-.6-.8-1.6-1.3-2.7-1.2-1.6.1-2.7 1-2.7 2.3 0 1.5 1.5 2 3.3 2.4 1.8.4 3.2 1 3.2 2.6 0 1.5-1.4 2.4-3.1 2.4-1.4 0-2.6-.6-3.2-1.6" fill="none" stroke="{D}" stroke-width="1.5" stroke-linecap="round"/>',
	pause: '<rect x="6" y="5" width="4.2" height="14" rx="1.4" fill="{G}"/><rect x="13.8" y="5" width="4.2" height="14" rx="1.4" fill="{G}"/>',
	detour: '<path d="M4 18c0-6 4-9 10-9" fill="none" stroke="{G}" stroke-width="2.2" stroke-linecap="round"/><path d="M11.5 5 17 9l-5.5 4z" fill="{G}"/>',
	code: '<path d="M9 7 4 12l5 5" fill="none" stroke="{G}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M15 7l5 5-5 5" fill="none" stroke="{G}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M13.4 5.5 10.6 18.5" fill="none" stroke="{G}" stroke-width="2" stroke-linecap="round"/>',
	phone_sms: '<rect x="3.5" y="2.5" width="9" height="19" rx="2.4" fill="{G}"/><rect x="5.3" y="5" width="5.4" height="9" rx="0.8" fill="{D}"/><path d="M13 9.5h8A1.6 1.6 0 0 1 22.6 11.1v4.3A1.6 1.6 0 0 1 21 17h-1.4v2.6L16.4 17H13a1.6 1.6 0 0 1-1.6-1.6v-4.3A1.6 1.6 0 0 1 13 9.5z" fill="{D}"/>',
	envelope: '<rect x="3" y="5.5" width="18" height="13" rx="2.4" fill="{G}"/><path d="M4.4 7.5 12 13l7.6-5.5" fill="none" stroke="{D}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>',
	scanner: '<rect x="3" y="3.5" width="18" height="6" rx="1.6" fill="{G}"/><rect x="3" y="12.5" width="18" height="6.5" rx="1.6" fill="{G}"/><path d="M6.5 6.5h11" fill="none" stroke="{D}" stroke-width="1.4" stroke-linecap="round"/><path d="M6.5 15.7h11" fill="none" stroke="{D}" stroke-width="1.4" stroke-linecap="round"/>',
	feeder: '<rect x="3.5" y="3" width="12" height="16" rx="1.6" fill="{G}"/><path d="M7 7h8M7 10.5h8M7 14h5" fill="none" stroke="{D}" stroke-width="1.3" stroke-linecap="round"/><path d="M18 11v8M15 16l3 3 3-3" fill="none" stroke="{G}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
	scraper: '<rect x="10.5" y="3" width="3" height="12" rx="1.2" fill="{G}"/><rect x="5" y="14.5" width="14" height="2.6" rx="1.2" fill="{G}"/><g stroke="{G}" stroke-width="1.6" stroke-linecap="round"><path d="M6.5 17.2v4M12 17.2v4M17.5 17.2v4"/></g>',
	wrench: '<path d="M22.7 19l-9.1-9.1c.9-2.3.4-5-1.5-6.9-2-2-5-2.4-7.4-1.3L9 6 6 9 1.6 4.7C.4 7.1.9 10.1 2.9 12.1c1.9 1.9 4.6 2.4 6.9 1.5l9.1 9.1c.4.4 1 .4 1.4 0l2.3-2.3c.4-.4.4-1 0-1.4z" fill="{G}"/>',
	globe: '<circle cx="12" cy="12" r="9" fill="{G}"/><g fill="none" stroke="{D}" stroke-width="1"><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3.4 9.2h17.2M3.4 14.8h17.2"/></g>',
	cursor: '<path d="M5 3l14 8-6 1.4L11.4 19z" fill="{G}" stroke="{D}" stroke-width="1" stroke-linejoin="round"/>',
	eyepointer: '<path d="M3.5 3 15 9.4l-4.7 1.1-1.8 5z" fill="{G}"/><path d="M14 15.2c2.4 0 4.4 1.8 5.4 3.8-.9 2-2.9 3.8-5.4 3.8s-4.5-1.8-5.4-3.8c1-2 2.9-3.8 5.4-3.8z" fill="{D}"/>',
	ruler: '<path d="M3.6 16.4 16.4 3.6l4 4L7.6 20.4z" fill="{G}"/><g stroke="{D}" stroke-width="0.9"><path d="M7.2 13.2l2 2M10.2 10.2l2 2M13.2 7.2l2 2"/></g>',
	gear: '<g fill="{G}"><circle cx="12" cy="12" r="4.4"/><rect x="11" y="1.6" width="2" height="3.6" rx="1"/><rect x="11" y="1.6" width="2" height="3.6" rx="1" transform="rotate(45 12 12)"/><rect x="11" y="1.6" width="2" height="3.6" rx="1" transform="rotate(90 12 12)"/><rect x="11" y="1.6" width="2" height="3.6" rx="1" transform="rotate(135 12 12)"/><rect x="11" y="1.6" width="2" height="3.6" rx="1" transform="rotate(180 12 12)"/><rect x="11" y="1.6" width="2" height="3.6" rx="1" transform="rotate(225 12 12)"/><rect x="11" y="1.6" width="2" height="3.6" rx="1" transform="rotate(270 12 12)"/><rect x="11" y="1.6" width="2" height="3.6" rx="1" transform="rotate(315 12 12)"/></g><circle cx="12" cy="12" r="1.8" fill="{D}"/>',
	spreadsheet: '<rect x="3" y="4" width="18" height="16" rx="2" fill="{G}"/><g stroke="{D}" stroke-width="1.2"><path d="M3 9h18M3 14.5h18M9 4v16M15 4v16"/></g>',
	list: '<g fill="{G}"><circle cx="5" cy="7" r="1.6"/><circle cx="5" cy="12" r="1.6"/><circle cx="5" cy="17" r="1.6"/></g><g stroke="{G}" stroke-width="2" stroke-linecap="round"><path d="M9 7h10M9 12h10M9 17h10"/></g>',
	book: '<path d="M11.4 6.4C9.4 5 6.6 4.4 3.5 4.9v12.3c3.1-.5 5.9.1 7.9 1.5z" fill="{G}"/><path d="M12.6 6.4c2-1.4 4.8-2 7.9-1.5v12.3c-3.1-.5-5.9.1-7.9 1.5z" fill="{G}"/>',
	photo_camera: '<rect x="2.5" y="6" width="19" height="13" rx="2.4" fill="{G}"/><path d="M8.5 6l1.2-2h4.6L15.5 6z" fill="{G}"/><circle cx="12" cy="12.5" r="4" fill="{D}"/><circle cx="12" cy="12.5" r="1.8" fill="{G}"/>',
	photo_camera_front: '<rect x="2.5" y="6" width="19" height="13" rx="2.4" fill="{G}"/><path d="M8.5 6l1.2-2h4.6L15.5 6z" fill="{G}"/><circle cx="12" cy="10.6" r="2.2" fill="{D}"/><path d="M7.6 17.6c0-2.5 2-4.1 4.4-4.1s4.4 1.6 4.4 4.1z" fill="{D}"/>',
	lock: '<rect x="4.5" y="10" width="15" height="10.5" rx="2.2" fill="{G}"/><path d="M8 10V7.4a4 4 0 0 1 8 0V10" fill="none" stroke="{G}" stroke-width="2"/><circle cx="12" cy="15" r="1.6" fill="{D}"/>',
	unlock: '<rect x="4.5" y="11" width="15" height="9.5" rx="2.2" fill="{G}"/><path d="M8 11V7.4a4 4 0 0 1 7.4-2.1" fill="none" stroke="{G}" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="15.7" r="1.6" fill="{D}"/>',
	pillow: '<path d="M4 8.5C4 6.6 6.6 4 8.5 4h7C17.4 4 20 6.6 20 8.5v7c0 1.9-2.6 4.5-4.5 4.5h-7C6.6 20 4 17.4 4 15.5z" fill="{G}"/><path d="M8.5 8.5c1.6 1.6 5.4 1.6 7 0M8.5 15.5c1.6-1.6 5.4-1.6 7 0" fill="none" stroke="{D}" stroke-width="1.4" stroke-linecap="round"/>',
	disc: '<circle cx="12" cy="12" r="9" fill="{G}"/><circle cx="12" cy="12" r="2.2" fill="{D}"/><path d="M12 3a9 9 0 0 1 8.6 6.4" fill="none" stroke="{D}" stroke-width="1.7" stroke-linecap="round"/>',
	info: '<circle cx="12" cy="12" r="9" fill="{G}"/><circle cx="12" cy="7.6" r="1.4" fill="{D}"/><rect x="10.9" y="10.2" width="2.2" height="7" rx="1.1" fill="{D}"/>',
	shuffle: '<path d="M10.59 9.17 5.41 4 4 5.41l5.17 5.17 1.42-1.41zM14.5 4l2.04 2.04L4 18.59 5.41 20 17.96 7.46 20 9.5V4h-5.5zm.33 9.41-1.41 1.41 3.13 3.13L14.5 20H20v-5.5l-2.04 2.04-3.13-3.13z" fill="{G}"/>',
	repeat: '<path d="M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z" fill="{G}"/>',
	fullscreen: '<path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z" fill="{G}"/>',
	plus: '<g fill="{G}"><rect x="11" y="4" width="2" height="16" rx="1"/><rect x="4" y="11" width="16" height="2" rx="1"/></g>',
	marker_start: '<path d="M5 4h2v16H5z" fill="{G}"/><path d="M9.5 12 18 5.5v13z" fill="{G}"/>',
	marker_end: '<path d="M17 4h2v16h-2z" fill="{G}"/><path d="M14.5 12 6 5.5v13z" fill="{G}"/>',
	jog_wheel: '<circle cx="12" cy="12" r="9" fill="{G}"/><circle cx="12" cy="12" r="2.4" fill="{D}"/><g stroke="{D}" stroke-width="1.3" stroke-linecap="round"><path d="M12 3.6v2.2M12 18.2v2.2M3.6 12h2.2M18.2 12h2.2M6.1 6.1l1.6 1.6M16.3 16.3l1.6 1.6M17.9 6.1l-1.6 1.6M7.7 16.3l-1.6 1.6"/></g>',
	button_on: '<rect x="3" y="6" width="18" height="12" rx="3" fill="{G}"/><rect x="6.5" y="9.5" width="11" height="5" rx="1.6" fill="{D}"/>',
	button_off: '<rect x="3" y="6" width="18" height="12" rx="3" fill="{G}"/><circle cx="12" cy="12" r="3.2" fill="{D}"/>',
	metronome: '<path d="M10 3h4l4 18H6z" fill="{G}"/><path d="M12 5.5 6.8 20" fill="none" stroke="{D}" stroke-width="1.4" stroke-linecap="round"/><rect x="8.5" y="2" width="7" height="2.2" rx="1.1" fill="{G}"/>',
	wand: '<path d="M4.3 19.7 15.4 8.6l1.4 1.4L5.7 21.1z" fill="{G}"/><path d="M18.4 3.2l.8 2.1 2.1.8-2.1.8-.8 2.1-.8-2.1-2.1-.8 2.1-.8z" fill="{D}"/><path d="M13.2 3.6l.5 1.4 1.4.5-1.4.5-.5 1.4-.5-1.4-1.4-.5 1.4-.5z" fill="{D}"/>',
	live: '<circle cx="12" cy="12" r="8.4" fill="none" stroke="{G}" stroke-width="2"/><circle cx="12" cy="12" r="3.6" fill="{G}"/>',
	bird: '<path d="M20.5 6.6c-.7.3-1.4.5-2.2.6.8-.5 1.4-1.2 1.7-2.1-.7.4-1.6.8-2.4.9a3.7 3.7 0 0 0-6.4 3.4A10.5 10.5 0 0 1 3.6 5.1a3.7 3.7 0 0 0 1.1 5c-.6 0-1.2-.2-1.7-.5a3.7 3.7 0 0 0 3 3.6c-.5.2-1.1.2-1.7.1a3.7 3.7 0 0 0 3.5 2.6A7.5 7.5 0 0 1 2.5 17.4a10.5 10.5 0 0 0 16.2-8.8c.7-.5 1.3-1.2 1.8-2z" fill="{G}"/>',
	power: '<path d="M12 3.2v8.4" fill="none" stroke="{G}" stroke-width="2.3" stroke-linecap="round"/><path d="M7.7 6.6a7 7 0 1 0 8.6 0" fill="none" stroke="{G}" stroke-width="2.3" stroke-linecap="round"/>',
	bullseye: '<circle cx="12" cy="12" r="9" fill="{G}"/><circle cx="12" cy="12" r="5.4" fill="{D}"/><circle cx="12" cy="12" r="2" fill="{G}"/>',
	knob: '<circle cx="12" cy="12" r="8.8" fill="{G}"/><circle cx="12" cy="12" r="2.6" fill="{D}"/><rect x="11.1" y="2.4" width="1.8" height="4.8" rx="0.9" fill="{D}"/>',
	pedal: '<rect x="3.5" y="2.5" width="17" height="19" rx="2.8" fill="{G}"/><circle cx="12" cy="8.6" r="3" fill="{D}"/><rect x="6" y="14.2" width="12" height="4.6" rx="1.5" fill="{D}"/>',
	cord: '<path d="M6 5.5c4 0 4.5 6 8 8.5s4 2 4 2" fill="none" stroke="{G}" stroke-width="2.2" stroke-linecap="round"/><circle cx="5" cy="5.5" r="2.6" fill="{G}"/><rect x="17.2" y="15.2" width="4" height="3.2" rx="1.2" fill="{G}"/>',
	jack: '<circle cx="12" cy="12" r="8.6" fill="{G}"/><circle cx="12" cy="12" r="4.2" fill="{D}"/><rect x="10.9" y="9" width="2.2" height="6" rx="1.1" fill="{G}"/>',
	fader: '<rect x="9.6" y="2.8" width="4.8" height="18.4" rx="2.4" fill="{G}"/><rect x="6.4" y="9.6" width="11.2" height="4.4" rx="1.5" fill="{D}"/>',
	groove: '<rect x="10.3" y="2.5" width="3.4" height="19" rx="1.7" fill="{G}"/><g stroke="{D}" stroke-width="1.1" stroke-linecap="round"><path d="M5.6 6h2.4M5.6 10h2.4M5.6 14h2.4M5.6 18h2.4M16 6h2.4M16 10h2.4M16 14h2.4M16 18h2.4"/></g>',
	led: '<circle cx="12" cy="12" r="5" fill="{D}"/><circle cx="12" cy="12" r="8.6" fill="none" stroke="{G}" stroke-width="1.6"/>',
	solo: '<circle cx="12" cy="12" r="8.8" fill="{G}"/><path d="M12 6.6l1.7 3.8 4.1.4-3 2.7.9 4-3.7-2-3.7 2 .9-4-3-2.7 4.1-.4z" fill="{D}"/>',
	mute: '<path d="M4 9h3.5L12 5.2v13.6L7.5 15H4z" fill="{G}"/><g stroke="{D}" stroke-width="1.8" stroke-linecap="round"><path d="M15.5 9.5l5 5M20.5 9.5l-5 5"/></g>',
	plugged_in: '<rect x="3" y="9.4" width="7" height="5.2" rx="1.6" fill="{G}"/><rect x="10" y="10.7" width="4.4" height="2.6" fill="{D}"/><circle cx="18.4" cy="12" r="3.6" fill="{G}"/><circle cx="18.4" cy="12" r="1.5" fill="{D}"/>',
	down: '<path d="M20 12l-1.41-1.41L13 16.17V4h-2v12.17l-5.58-5.59L4 12l8 8 8-8z" fill="{G}"/>',
	explosion: '<path d="M12 1.8l2.5 7.7 7.7 2.5-7.7 2.5L12 22.2l-2.5-7.7L1.8 12l7.7-2.5z" fill="{G}"/><circle cx="12" cy="12" r="2.4" fill="{D}"/>',
	crown: '<path d="M3 8.2l4.2 3.6L12 5l4.8 6.8L21 8.2V19a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 5 19z" fill="{G}"/>',
	download: '<path d="M11 3h2v8h3l-4 4-4-4h3z" fill="{G}"/><path d="M4 15v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3h-2v3H6v-3z" fill="{G}"/>',
	share: '<circle cx="18" cy="5" r="2.6" fill="{G}"/><circle cx="6" cy="12" r="2.6" fill="{G}"/><circle cx="18" cy="19" r="2.6" fill="{G}"/><path d="M8.3 10.7l7.4-4.3M8.3 13.3l7.4 4.3" stroke="{G}" stroke-width="1.6"/>',
	palette: '<path d="M12 3a9 9 0 0 0 0 18c1.1 0 2-.9 2-2 0-.5-.2-1-.5-1.3-.3-.4-.5-.8-.5-1.2 0-1 .8-1.8 1.8-1.8H16a5 5 0 0 0 5-5c0-3.9-4-6.7-9-6.7z" fill="{G}"/><g fill="{D}"><circle cx="7.5" cy="11" r="1.3"/><circle cx="10.5" cy="7.5" r="1.3"/><circle cx="15" cy="7.8" r="1.3"/></g>',
	contrast: '<circle cx="12" cy="12" r="9" fill="{G}"/><path d="M12 3a9 9 0 0 0 0 18z" fill="{D}"/>',
	brightness: '<circle cx="12" cy="12" r="4.6" fill="{G}"/><g stroke="{G}" stroke-width="1.7" stroke-linecap="round"><path d="M12 2v2.4M12 19.6V22M2 12h2.4M19.6 12H22M5 5l1.7 1.7M17.3 17.3 19 19M19 5l-1.7 1.7M6.7 17.3 5 19"/></g>',
	blur: '<circle cx="12" cy="12" r="7.6" fill="{G}" opacity="0.55"/><circle cx="12" cy="12" r="4" fill="{D}"/>',
	sharpen: '<path d="M12 2.5 21 20H3z" fill="{G}"/><path d="M12 8 17 18H7z" fill="{D}"/>',
	crop: '<path d="M6 2v14a2 2 0 0 0 2 2h14" fill="none" stroke="{G}" stroke-width="2"/><path d="M2 6h14a2 2 0 0 1 2 2v14" fill="none" stroke="{G}" stroke-width="2"/>',
	fill: '<path d="M5 11 11 5l7 7-6 6a2 2 0 0 1-2.8 0L5 13.8a2 2 0 0 1 0-2.8z" fill="{G}"/><path d="M19 14s2 2.2 2 3.6a2 2 0 1 1-4 0C17 16.2 19 14 19 14z" fill="{D}"/>',
	duplicate: '<rect x="8" y="8" width="13" height="13" rx="2" fill="{D}"/><rect x="3" y="3" width="13" height="13" rx="2" fill="{G}"/>',
	// the search button (search_button) reads as a magnifying glass
	magnifier: '<circle cx="10.3" cy="10.3" r="6.2" fill="{D}" opacity="0.45"/><circle cx="10.3" cy="10.3" r="6.2" fill="none" stroke="{G}" stroke-width="2.2"/><path d="M7.4 8.7a3.6 3.6 0 0 1 1.8-1.7" fill="none" stroke="{D}" stroke-width="1.2" stroke-linecap="round"/><path d="M15 15 20.6 20.6" fill="none" stroke="{G}" stroke-width="2.9" stroke-linecap="round"/>',
	// the device lister's neighbour button starts an ssh tunnel, so it gets an
	// arch with the road running in
	tunnel: '<path d="M2.6 20.4v-6.6a9.4 9.4 0 0 1 18.8 0v6.6z" fill="{G}"/><path d="M7.9 20.4v-6a4.1 4.1 0 0 1 8.2 0v6z" fill="{D}"/><path d="M12 15.4v5" fill="none" stroke="{G}" stroke-width="1.1" stroke-dasharray="1.6 1.4" stroke-linecap="round"/>',
	backspace: '<path d="M9 5h11a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-6-7z" fill="{G}"/><path d="M11.5 9.5l5 5M16.5 9.5l-5 5" stroke="{D}" stroke-width="1.7" stroke-linecap="round"/>',
	thumbsdown: '<g transform="rotate(180 12 12)"><path d="M1 21h4V9H1v12zm22-11c0-1.1-.9-2-2-2h-6.31l.95-4.57.03-.32c0-.41-.17-.79-.44-1.06L14.17 1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73V10z" fill="{G}"/></g>',
	eat: '<g fill="{G}"><rect x="5" y="2" width="1.4" height="9"/><rect x="8" y="2" width="1.4" height="9"/><rect x="11" y="2" width="1.4" height="9"/><path d="M5 11h7.4c0 2-1.5 3.4-3.7 3.4V22H7.7v-7.6C5.5 14.4 5 12.8 5 11z"/></g><path d="M16.5 2c1.6 1.2 2.6 3.2 2.6 6 0 2-1 3.3-2.6 4V22h-1.6V2z" fill="{D}"/>',
	pin: '<path d="M12 2a7 7 0 0 0-7 7c0 5 7 13 7 13s7-8 7-13a7 7 0 0 0-7-7z" fill="{G}"/><circle cx="12" cy="9" r="2.6" fill="{D}"/>',
	server: '<rect x="3" y="3.5" width="18" height="7" rx="2" fill="{G}"/><rect x="3" y="13.5" width="18" height="7" rx="2" fill="{G}"/><circle cx="7" cy="7" r="1.3" fill="{D}"/><circle cx="7" cy="17" r="1.3" fill="{D}"/>',
	title: '<rect x="3" y="4" width="18" height="4" rx="1.3" fill="{G}"/><rect x="3" y="11" width="12" height="3" rx="1.2" fill="{D}"/><rect x="3" y="17" width="15" height="3" rx="1.2" fill="{D}"/>',
	vacuum: '<circle cx="12" cy="15" r="6" fill="{G}"/><circle cx="12" cy="15" r="2.4" fill="{D}"/><path d="M12 9V4a2 2 0 0 1 4 0v2" fill="none" stroke="{G}" stroke-width="1.8" stroke-linecap="round"/>',
	doctor: '<circle cx="12" cy="7" r="4" fill="{G}"/><path d="M4.5 21c0-4.2 3.4-7 7.5-7s7.5 2.8 7.5 7z" fill="{G}"/><path d="M11 13.5h2v2h2v2h-2v2h-2v-2H9v-2h2z" fill="{D}"/>',
	clothesline: '<path d="M3 7c4 3 14 3 18 0" fill="none" stroke="{G}" stroke-width="1.6"/><g fill="{G}"><rect x="5.5" y="8" width="4" height="6" rx="0.8"/><rect x="14.5" y="8" width="4" height="6" rx="0.8"/></g><path d="M4 4v15M20 4v15" stroke="{D}" stroke-width="1.6" stroke-linecap="round"/>',
	gift: '<rect x="3.5" y="9.5" width="17" height="11.5" rx="1.6" fill="{G}"/><rect x="2.5" y="6.5" width="19" height="4" rx="1.4" fill="{D}"/><rect x="10.6" y="6.5" width="2.8" height="14.5" fill="{D}"/><path d="M12 6.5C12 4 10.5 3 9 3.7 7.6 4.4 8 6.5 12 6.5zM12 6.5c0-2.5 1.5-3.5 3-2.8C16.4 4.4 16 6.5 12 6.5z" fill="{G}"/>',
	welcome: '<path d="M8.5 11.5V5a1.6 1.6 0 0 1 3.2 0v5.4M11.7 10V3.6a1.6 1.6 0 0 1 3.2 0V10M14.9 10.2V5.2a1.6 1.6 0 0 1 3.2 0v8.3c0 4-2.6 7.5-6.6 7.5-3 0-5-1.6-6.2-4.3L3.6 12.5a1.6 1.6 0 0 1 2.6-1.8l2.3 2.6" fill="none" stroke="{G}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
	wallet: '<path d="M3 6.5A2.5 2.5 0 0 1 5.5 4h10A2.5 2.5 0 0 1 18 6.5V7H5.5A2.5 2.5 0 0 0 3 9.5z" fill="{D}"/><rect x="3" y="7.5" width="18" height="11.5" rx="2.4" fill="{G}"/><rect x="14" y="11.5" width="5" height="3.8" rx="1.6" fill="{D}"/>',
	bolt: '<path d="M13 2 4.5 13H11l-1 9 8.5-11H12z" fill="{G}"/>',
	tag: '<path d="M3 11.5V4.5A1.5 1.5 0 0 1 4.5 3h7l9.5 9.5a2 2 0 0 1 0 2.8l-6.7 6.7a2 2 0 0 1-2.8 0z" fill="{G}"/><circle cx="8" cy="8" r="1.8" fill="{D}"/>',
	users: '<g fill="{G}"><circle cx="9" cy="8" r="3.4"/><path d="M2.5 19.5c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6z"/></g><g fill="{D}"><circle cx="17.2" cy="9.2" r="2.6"/><path d="M14.9 14.6c3.2 0 5.6 2 5.6 4.9h-3.9c0-1.9-.7-3.6-1.7-4.9z"/></g>',
	building: '<rect x="4" y="3" width="10" height="18" rx="1.4" fill="{G}"/><rect x="14.5" y="9" width="5.5" height="12" rx="1.2" fill="{D}"/><g fill="{D}"><rect x="6.4" y="6" width="2" height="2"/><rect x="9.6" y="6" width="2" height="2"/><rect x="6.4" y="10" width="2" height="2"/><rect x="9.6" y="10" width="2" height="2"/><rect x="6.4" y="14" width="2" height="2"/><rect x="9.6" y="14" width="2" height="2"/></g>',
	bulb: '<path d="M12 2a6.5 6.5 0 0 0-3.8 11.8c.5.4.8 1 .8 1.6v.6h6v-.6c0-.6.3-1.2.8-1.6A6.5 6.5 0 0 0 12 2z" fill="{G}"/><rect x="9.2" y="17.4" width="5.6" height="1.8" rx="0.9" fill="{D}"/><rect x="10" y="20" width="4" height="1.6" rx="0.8" fill="{D}"/>',
	clipboard: '<rect x="5" y="4" width="14" height="17" rx="2.2" fill="{G}"/><rect x="9" y="2.4" width="6" height="3.2" rx="1.2" fill="{D}"/><g stroke="{D}" stroke-width="1.4" stroke-linecap="round"><path d="M8.5 10h7M8.5 13.5h7M8.5 17h4"/></g>',
	thought: '<path d="M4.5 4.5h13A2.5 2.5 0 0 1 20 7v6a2.5 2.5 0 0 1-2.5 2.5h-3.8l-3.2 2.9v-2.9H4.5A2.5 2.5 0 0 1 2 13V7A2.5 2.5 0 0 1 4.5 4.5z" fill="{G}"/><circle cx="6.4" cy="18.6" r="1.6" fill="{G}"/><circle cx="3.9" cy="21.2" r="1" fill="{G}"/>',
	film: '<rect x="2.5" y="4.5" width="19" height="15" rx="2" fill="{G}"/><g fill="{D}"><rect x="4.4" y="6.4" width="2.6" height="2.6"/><rect x="4.4" y="10.7" width="2.6" height="2.6"/><rect x="4.4" y="15" width="2.6" height="2.6"/><rect x="17" y="6.4" width="2.6" height="2.6"/><rect x="17" y="10.7" width="2.6" height="2.6"/><rect x="17" y="15" width="2.6" height="2.6"/></g><path d="M10.2 9.4 15.4 12l-5.2 2.6z" fill="{D}"/>',
	toggle_on: '<rect x="2.5" y="7" width="19" height="10" rx="5" fill="{G}"/><circle cx="16.5" cy="12" r="3.4" fill="{D}"/>',
	toggle_off: '<rect x="2.5" y="7" width="19" height="10" rx="5" fill="{G}"/><circle cx="7.5" cy="12" r="3.4" fill="{D}"/>',
	burger: '<g stroke="{G}" stroke-width="2.2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></g>',
	trash: '<path d="M6 6h12v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2z" fill="{G}"/><rect x="4" y="4" width="16" height="2.6" rx="1.3" fill="{G}"/><rect x="9.5" y="2.5" width="5" height="2.2" rx="1" fill="{G}"/><g stroke="{D}" stroke-width="1.4" stroke-linecap="round"><path d="M10 10.5v7M14 10.5v7"/></g>',
	note: '<path d="M5 3.5h14a2 2 0 0 1 2 2V15l-6 6H5a2 2 0 0 1-2-2V5.5a2 2 0 0 1 2-2z" fill="{G}"/><path d="M15 21v-4a2 2 0 0 1 2-2h4z" fill="{D}"/><g stroke="{D}" stroke-width="1.4" stroke-linecap="round"><path d="M7 8h10M7 11.5h10M7 15h5"/></g>',
	// --- app / start-menu glyphs ---
	apps: '<g fill="{G}"><rect x="3" y="3" width="7.6" height="7.6" rx="1.6"/><rect x="13.4" y="3" width="7.6" height="7.6" rx="1.6"/><rect x="3" y="13.4" width="7.6" height="7.6" rx="1.6"/><rect x="13.4" y="13.4" width="7.6" height="7.6" rx="1.6"/></g>',
	clock: '<path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z" fill="{G}"/>',
	up: '<path d="M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z" fill="{G}"/>',
	pulse: '<path d="M16 6l2.29 2.29-4.88 4.88-4-4L2 16.59 3.41 18l6-6 4 4 6.3-6.29L22 12V6z" fill="{G}"/>',
	folder: '<path d="M3 7a2 2 0 0 1 2-2h3.2l2 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" fill="{G}"/>',
	chart: '<g fill="{G}"><rect x="3.5" y="12" width="3.6" height="8" rx="1.2"/><rect x="10.2" y="6" width="3.6" height="14" rx="1.2"/><rect x="16.9" y="9" width="3.6" height="11" rx="1.2"/></g>',
	aeroplane: '<path d="M21 16v-2l-8-5V3.5a1.5 1.5 0 0 0-3 0V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5z" fill="{G}"/>',
	chat: '<path d="M11 8.5h7A2.5 2.5 0 0 1 20.5 11v4A2.5 2.5 0 0 1 18 17.5h-1.2v3l-3.2-3H11A2.5 2.5 0 0 1 8.5 15v-4A2.5 2.5 0 0 1 11 8.5z" fill="{D}"/><path d="M6 3.5h8A2.5 2.5 0 0 1 16.5 6v4A2.5 2.5 0 0 1 14 12.5h-4.6L6.2 15.5v-3H6A2.5 2.5 0 0 1 3.5 10V6A2.5 2.5 0 0 1 6 3.5z" fill="{G}"/>',
	music: '<g fill="{G}"><circle cx="6.6" cy="17.4" r="2.7"/><circle cx="17.4" cy="15.4" r="2.7"/><rect x="7.8" y="4.2" width="1.8" height="13.2"/><rect x="18.6" y="2.2" width="1.8" height="13.2"/><rect x="7.8" y="4.2" width="12.6" height="2.3" rx="1.1"/></g>',
	microchip: '<g fill="{G}"><rect x="9.5" y="3" width="1.6" height="3"/><rect x="12.9" y="3" width="1.6" height="3"/><rect x="9.5" y="18" width="1.6" height="3"/><rect x="12.9" y="18" width="1.6" height="3"/><rect x="3" y="9.5" width="3" height="1.6"/><rect x="3" y="12.9" width="3" height="1.6"/><rect x="18" y="9.5" width="3" height="1.6"/><rect x="18" y="12.9" width="3" height="1.6"/><rect x="6" y="6" width="12" height="12" rx="2.4"/></g><rect x="9.4" y="9.4" width="5.2" height="5.2" rx="1.2" fill="{D}"/>',
	ticket: '<rect x="2.5" y="6.5" width="19" height="11" rx="2" fill="{G}"/><path d="M8.5 7.2v9.6" fill="none" stroke="{D}" stroke-width="0.6" stroke-dasharray="1.1 1.1"/>',
	cards: '<rect x="9.5" y="3.5" width="9.5" height="14.5" rx="2" fill="{D}"/><rect x="5" y="6" width="9.5" height="14.5" rx="2" fill="{G}"/>',
	piano: '<rect x="3" y="5" width="18" height="14" rx="2" fill="{G}"/><g stroke="{D}" stroke-width="0.6"><path d="M7.5 5v14M12 5v14M16.5 5v14"/></g><g fill="{D}"><rect x="6.1" y="5" width="2.3" height="8.6"/><rect x="10.6" y="5" width="2.3" height="8.6"/><rect x="15.1" y="5" width="2.3" height="8.6"/></g>',
	tetris: '<g fill="{G}"><rect x="3" y="3" width="6" height="6" rx="1"/><rect x="9" y="3" width="6" height="6" rx="1"/><rect x="9" y="9" width="6" height="6" rx="1"/><rect x="15" y="9" width="6" height="6" rx="1"/></g>',
	thumbsup: '<path d="M1 21h4V9H1v12zm22-11c0-1.1-.9-2-2-2h-6.31l.95-4.57.03-.32c0-.41-.17-.79-.44-1.06L14.17 1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73V10z" fill="{G}"/>',
	person: '<circle cx="12" cy="7.6" r="4.1" fill="{G}"/><path d="M4 20.5c0-4.2 3.6-6.9 8-6.9s8 2.7 8 6.9z" fill="{G}"/><path d="M12 13.6l1.7 2.3-1.7 4.6-1.7-4.6z" fill="{D}"/>',
	warehouse: '<path d="M3 20V9.6L12 4l9 5.6V20z" fill="{G}"/><rect x="9.4" y="13.6" width="5.2" height="6.4" fill="{D}"/>',
	shop: '<path d="M20 4H4v2h16V4zm1 10v-2l-1-5H4l-1 5v2h1v6h10v-6h4v6h2v-6h1zm-9 4H6v-4h6v4z" fill="{G}"/>',
	house: '<path d="M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z" fill="{G}"/>',
	calendar: '<path d="M17 12h-5v5h5v-5zM16 1v2H8V1H6v2H5c-1.11 0-1.99.9-1.99 2L3 19c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2h-1V1h-2zm3 18H5V8h14v11z" fill="{G}"/>',
	blocked: '<path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zM4 12c0-4.42 3.58-8 8-8 1.85 0 3.55.63 4.9 1.69L5.69 16.9C4.63 15.55 4 13.85 4 12zm8 8c-1.85 0-3.55-.63-4.9-1.69L18.31 7.1C19.37 8.45 20 10.15 20 12c0 4.42-3.58 8-8 8z" fill="{G}"/>',
	moon: '<path d="M20.2 14.8A8.6 8.6 0 1 1 9.2 3.8a6.9 6.9 0 0 0 11 11z" fill="{G}"/>',
};

// --- pseudonym icon name -> glyph ---------------------------------------------
const ICONS = {
	'Froggoli': 'frog',
	'Mr. Sun': 'sun',
	'headphones': 'headphones',
	'keyboard': 'keyboard',
	'calculator': 'calculator',
	'bell': 'bell',
	'windows': 'terminal',
	'heart': 'heart',
	'record': 'record',
	'love letter': 'pencil',
	'play': 'play',
	'prev': 'prev',
	'next': 'next',
	'stop': 'stop',
	'Mr. President': 'president',
	'mailbox': 'mailbox',
	'usual_button': 'check',
	'camera': 'camera',
	'eye': 'eye',
	'marker': 'marker',
	'monitor': 'monitor',
	'microphone': 'mic',
	'renew': 'renew',
	'cancel_button': 'x',
	'telephone line': 'telephone',
	'delay_button': 'hourglass',
	'register': 'receipt',
	'cake': 'cake',
	'inventory': 'box',
	'upload': 'upload',
	'badge': 'badge',
	'key': 'key',
	'diskette': 'diskette',
	'gallery': 'image',
	'exit': 'exit',
	'mixer': 'sliders',
	'cash': 'dollar',
	'pause': 'pause',
	'detour': 'detour',
	'code': 'code',
	'phone_sms': 'phone_sms',
	'envelope': 'envelope',
	'flatbed': 'scanner',
	'feeder': 'feeder',
	'scraper': 'scraper',
	'wrench': 'wrench',
	'web_button': 'globe',
	'pointer': 'cursor',
	'eyepointer': 'eyepointer',
	'measures': 'ruler',
	'checkmark': 'check',
	'gear': 'gear',
	'spreadsheet': 'spreadsheet',
	'list': 'list',
	'wiki': 'book',
	'camera_back': 'photo_camera',
	'camera_front': 'photo_camera_front',
	'public': 'globe',
	'enc_button': 'lock',
	'on': 'toggle_on',
	'off': 'toggle_off',
	'burger': 'burger',
	'edit': 'pencil',
	'trash': 'trash',
	'note': 'note',
	// --- app / start-menu icons (named by the source file's basename) ---
	'logo3': 'apps',
	'new sun': 'clock',
	'road ahead': 'up',
	'nonsense': 'hourglass',
	'water': 'pulse',
	'folder': 'folder',
	'chart': 'chart',
	'aeroplane': 'aeroplane',
	'strawbeery': 'chat',
	'music': 'music',
	'microchip': 'microchip',
	'ticket': 'ticket',
	'cards': 'cards',
	'piano': 'piano',
	'stop sign': 'stop',
	'tetris': 'tetris',
	'handbook': 'book',
	'speech to text': 'mic',
	'nightlight': 'moon',
	'good': 'thumbsup',
	'vendor': 'person',
	'manufacturer': 'warehouse',
	'shop': 'shop',
	'home': 'house',
	'appts': 'calendar',
	'ne pas': 'blocked',
	'up': 'up',
	'padlock unlock': 'unlock',
	'Pillow': 'pillow',
	'cdrom': 'disc',
	'information': 'info',
	'shuffle': 'shuffle',
	'repeat': 'repeat',
	'green screen': 'fullscreen',
	'back': 'prev',
	'forward': 'next',
	'plus': 'plus',
	'start': 'marker_start',
	'end': 'marker_end',
	'jog wheel': 'jog_wheel',
	'ruler': 'ruler',
	'button_pressed_ruby_red': 'button_on',
	'button_depressed_ruby_red': 'button_off',
	'left arrow': 'prev',
	'right arrow': 'next',
	'file': 'note',
	'metronome': 'metronome',
	'automate everything': 'wand',
	'now': 'live',
	'the bird': 'bird',
	'logo2': 'power',
	'bullseye': 'bullseye',
	'padlock': 'lock',
	// --- studio instrument / control artwork ---
	'jtune': 'pedal',
	'compressionX': 'pedal',
	'distorjawn': 'pedal',
	'delayed': 'pedal',
	'reverb2': 'pedal',
	'cord': 'cord',
	'jack': 'jack',
	'slider': 'groove',
	'slider2': 'groove',
	'led_brass': 'led',
	'led_bronze': 'led',
	'led_silver': 'led',
	'solo': 'solo',
	'mute': 'mute',
	'plugged_in': 'plugged_in',
	'mark': 'marker',
	'jog wheel tye dye': 'jog_wheel',
	'down': 'down',
	'explosion': 'explosion',
	'crown': 'crown',
	'add': 'plus',
	'view': 'eye',
	'I': 'info',
	'padlock dial': 'lock',
	'padlock lock': 'lock',
	'supplier': 'person',
	'adopt': 'download',
	'black level': 'contrast',
	'christmas': 'gift',
	'clothesline': 'clothesline',
	'contrast': 'contrast',
	'crop': 'crop',
	'doctor': 'doctor',
	'download': 'download',
	'duplicate': 'duplicate',
	'eat': 'eat',
	'fill': 'fill',
	'gps': 'pin',
	'search_button': 'magnifier',
	'tunnel': 'tunnel',
	'palette': 'palette',
	'server': 'server',
	'share': 'share',
	'sharpen': 'sharpen',
	'title': 'title',
	'vacuum': 'vacuum',
	'WelcomeLogo': 'welcome',
	'backspace': 'backspace',
	'bad': 'thumbsdown',
	'blur': 'blur',
	'brightness': 'brightness',
	// --- pos / placeholder types (main_icon_maker fallbacks) ---
	'account': 'wallet',
	'action': 'bolt',
	'category': 'tag',
	'subcategory': 'tag',
	'club': 'users',
	'community': 'users',
	'team': 'users',
	'corporation': 'building',
	'government': 'building',
	'institution': 'building',
	'customer': 'person',
	'person': 'person',
	'equipment': 'wrench',
	'event': 'calendar',
	'feel': 'heart',
	'idea': 'bulb',
	'media': 'image',
	'model': 'box',
	'product': 'box',
	'thing': 'box',
	'option': 'sliders',
	'place': 'pin',
	'project': 'clipboard',
	'service': 'headphones',
	'thought': 'thought',
	'video': 'film',
	'knob_aqua_logo': 'knob',
	'knob_blue': 'knob',
	'knob_cyan': 'knob',
	'knob_fire_j': 'knob',
	'knob_green': 'knob',
	'knob_green_rounded': 'knob',
	'knob_grey_plain': 'knob',
	'knob_navy': 'knob',
	'knob_orange_grower': 'knob',
	'knob_orange': 'knob',
	'knob_pink': 'knob',
	'knob_red_numbered': 'knob',
	'knob_red': 'knob',
	'knob_star_trek': 'knob',
	'knob_teal_rounded': 'knob',
	'knob_white': 'knob',
	'knob_yellow': 'knob',
};

// --- styles --------------------------------------------------------------------
// Each style: render(hue, innerGlyphMarkup) -> full <svg> string.
// `inner` already has {G}/{D} resolved to the style's glyph/detail colours.
const wrapAt = (inner, scale) => '<g transform="translate(' + (256 - 12 * scale) + ',' + (256 - 12 * scale) + ') scale(' + scale + ')">' + inner + '</g>';
const wrap = inner => wrapAt(inner, 11);
// paint an offset translucent silhouette first, then the glyph, for a cheap
// drop shadow that needs no filters (the loud sets lean on big glyphs)
function glyphWithShadow(inner, scale, g, d, shadow, dx, dy) {
	return '<g transform="translate(' + dx + ',' + dy + ')">' + wrapAt(sub(inner, shadow, shadow), scale) + '</g>'
		+ wrapAt(sub(inner, g, d), scale);
}
// a point at radius r from the tile centre, deg degrees clockwise from the top
function polar(r, deg) {
	const a = deg * Math.PI / 180;
	return (256 + r * Math.sin(a)).toFixed(1) + ' ' + (256 - r * Math.cos(a)).toFixed(1);
}

function frame(fill, opts) {
	opts = opts || {};
	const stroke = opts.stroke ? ' stroke="' + opts.stroke + '" stroke-width="' + (opts.sw || 4) + '"' : '';
	const rx = opts.rx == null ? 96 : opts.rx;
	const inset = opts.inset == null ? 48 : opts.inset;
	const w = 512 - inset * 2;
	return '<rect x="' + inset + '" y="' + inset + '" width="' + w + '" height="' + w + '" rx="' + rx + '" fill="' + fill + '"' + stroke + '/>';
}

const STYLES = {
	// bright, thick black outline, sticker-ish
	cartoon: {
		label: 'Cartoon',
		render: (h, inner) => svgWrap(frame(hsl(h, 0.85, 0.63), { inset: 34, rx: 112, stroke: '#1b1b1b', sw: 16 }) + wrap(sub(inner, '#ffffff', 'rgba(0,0,0,0.35)'))),
	},
	// near-black gradient, soft light glyph
	dark: {
		label: 'Dark',
		render: (h, inner) => {
			const g = hsl(h, 0.22, 0.24), b = hsl(h, 0.2, 0.14);
			const svg = '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="' + g + '"/><stop offset="1" stop-color="' + b + '"/></linearGradient></defs>'
				+ frame('url(#bg)', { stroke: hsl(h, 0.25, 0.38), sw: 5, rx: 96 });
			return svgWrap(svg + wrap(sub(inner, hsl(h, 0.25, 0.9), hsl(h, 0.3, 0.42))));
		},
	},
	// pale background with a thin border, dark glyph
	light: {
		label: 'Light',
		render: (h, inner) => svgWrap(frame(hsl(h, 0.5, 0.96), { stroke: hsl(h, 0.4, 0.74), sw: 6, rx: 96 }) + wrap(sub(inner, hsl(h, 0.45, 0.3), '#ffffff'))),
	},
	// no background at all, just a coloured glyph
	outline: {
		label: 'Outline',
		render: (h, inner) => svgWrap(wrap(sub(inner, hsl(h, 0.6, 0.45), hsl(h, 0.7, 0.72)))),
	},
	// dark panel with a glowing neon glyph
	neon: {
		label: 'Neon',
		render: (h, inner) => {
			const defs = '<defs><filter id="glow" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="7" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>';
			const bg = frame('#0c0f14', { stroke: hsl(h, 1, 0.6), sw: 4, rx: 92 });
			const glyph = '<g filter="url(#glow)">' + wrap(sub(inner, hsl(h, 1, 0.62), hsl(h, 1, 0.34))) + '</g>';
			return svgWrap(defs + bg + glyph);
		},
	},
	// soft pastel background, dark glyph
	pastel: {
		label: 'Pastel',
		render: (h, inner) => svgWrap(frame(hsl(h, 0.6, 0.85), { rx: 104 }) + wrap(sub(inner, hsl(h, 0.35, 0.34), '#ffffff'))),
	},
	// high-contrast black & white
	mono: {
		label: 'Mono',
		render: (h, inner) => svgWrap(frame('#ffffff', { inset: 40, rx: 70, stroke: '#111111', sw: 14 }) + wrap(sub(inner, '#111111', '#ffffff'))),
	},
	// --- the loud ones: full-bleed plates with oversized glyphs ---
	// vintage badge: a sunburst of rays behind a big white glyph
	sunburst: {
		label: 'Sunburst',
		render: (h, inner) => {
			const defs = '<defs>'
				+ '<path id="ray" d="M256 256 L' + polar(480, -7.5) + ' L' + polar(480, 7.5) + ' Z"/>'
				+ '<clipPath id="plate"><rect x="10" y="10" width="492" height="492" rx="128"/></clipPath>'
				+ '<radialGradient id="glow" cx="0.5" cy="0.4" r="0.8">'
				+ '<stop offset="0" stop-color="' + hsl(h, 0.95, 0.6) + '"/>'
				+ '<stop offset="1" stop-color="' + hsl(h + 24, 0.9, 0.44) + '"/>'
				+ '</radialGradient></defs>';
			let rays = '';
			for (let i = 0; i < 18; i++) {
				rays += '<use href="#ray" transform="rotate(' + (i * 20) + ' 256 256)" fill="rgba(255,255,255,0.22)"/>';
			}
			return svgWrap(defs
				+ '<g clip-path="url(#plate)">' + frame('url(#glow)', { inset: 10, rx: 128 }) + rays + '</g>'
				+ frame('none', { inset: 10, rx: 128, stroke: 'rgba(0,0,0,0.22)', sw: 8 })
				+ glyphWithShadow(inner, 15, '#ffffff', 'rgba(0,0,0,0.32)', 'rgba(0,0,0,0.28)', 7, 9));
		},
	},
	// iridescent foil sweeping through the wheel, with a glossy diagonal sheen
	holographic: {
		label: 'Holographic',
		render: (h, inner) => {
			const offs = [0, 0.22, 0.45, 0.68, 1];
			let stops = '';
			for (let i = 0; i < offs.length; i++) {
				stops += '<stop offset="' + offs[i] + '" stop-color="' + hsl(h - 50 + i * 64, 0.95, i % 2 ? 0.72 : 0.56) + '"/>';
			}
			const defs = '<defs>'
				+ '<clipPath id="plate"><rect x="10" y="10" width="492" height="492" rx="128"/></clipPath>'
				+ '<linearGradient id="foil" x1="0" y1="0" x2="1" y2="1">' + stops + '</linearGradient>'
				+ '</defs>';
			const sheen = '<path d="M-60 560 L240 -60 L340 -60 L40 560 Z" fill="rgba(255,255,255,0.30)"/>'
				+ '<path d="M150 560 L420 -60 L455 -60 L185 560 Z" fill="rgba(255,255,255,0.16)"/>';
			return svgWrap(defs
				+ '<g clip-path="url(#plate)">' + frame('url(#foil)', { inset: 10, rx: 128 }) + sheen + '</g>'
				+ frame('none', { inset: 10, rx: 128, stroke: 'rgba(255,255,255,0.55)', sw: 6 })
				+ glyphWithShadow(inner, 15, '#ffffff', 'rgba(30,0,50,0.4)', 'rgba(30,0,50,0.4)', 6, 8));
		},
	},
	// die-cut sticker: white border, saturated core, tossed onto the tile
	sticker: {
		label: 'Sticker',
		render: (h, inner) => {
			const tilt = 'rotate(-3 256 256)';
			const plate = '<g transform="' + tilt + '">'
				+ '<g transform="translate(7,9)">' + frame('rgba(0,0,0,0.20)', { inset: 20, rx: 128 }) + '</g>'
				+ frame('#ffffff', { inset: 20, rx: 128 })
				+ frame(hsl(h, 0.95, 0.58), { inset: 58, rx: 98 })
				+ '</g>';
			return svgWrap(plate
				+ '<g transform="' + tilt + '">' + glyphWithShadow(inner, 14, '#ffffff', 'rgba(0,0,0,0.3)', 'rgba(0,0,0,0.3)', 4, 6) + '</g>');
		},
	},
	// hypnotic tie-dye: wobbling concentric bands, dark glyph riding on top
	psychedelic: {
		label: 'Psychedelic',
		render: (h, inner) => {
			// one wavy ring on a 100px radius, reused scaled and rotated per band
			let ring = '';
			for (let s = 0; s <= 60; s++) {
				const a = s / 60 * Math.PI * 2;
				const r = 100 + 3 * Math.sin(3 * a) + 1.3 * Math.sin(5 * a + 0.8);
				ring += (s ? 'L' : 'M') + (r * Math.cos(a)).toFixed(1) + ' ' + (r * Math.sin(a)).toFixed(1);
			}
			const defs = '<defs>'
				+ '<path id="ring" d="' + ring + ' Z"/>'
				+ '<clipPath id="plate"><rect x="10" y="10" width="492" height="492" rx="128"/></clipPath>'
				+ '</defs>';
			const hues = [0, 72, 144, 216, 288];
			let bands = '';
			for (let i = 0; i < 9; i++) {
				const R = 470 - i * 52;
				bands += '<use href="#ring" transform="translate(256,256) scale(' + (R / 100).toFixed(3) + ') rotate(' + (i * 17) + ')" fill="' + hsl(h + hues[i % hues.length], 0.92, i % 2 ? 0.62 : 0.46) + '"/>';
			}
			return svgWrap(defs
				+ '<g clip-path="url(#plate)">' + bands + '</g>'
				+ frame('none', { inset: 10, rx: 128, stroke: 'rgba(0,0,0,0.18)', sw: 6 })
				+ glyphWithShadow(inner, 14, hsl(h + 200, 0.5, 0.16), hsl(h + 200, 0.45, 0.34), 'rgba(255,255,255,0.55)', 3, 4));
		},
	},
	// stained glass: twelve bright facets with lead lines and a big white glyph
	kaleidoscope: {
		label: 'Kaleidoscope',
		render: (h, inner) => {
			const defs = '<defs>'
				+ '<path id="wedge" d="M256 256 L' + polar(520, -0.7) + ' L' + polar(520, 30.7) + ' Z"/>'
				+ '<path id="lead" d="M256 256 L' + polar(520, 0) + '"/>'
				+ '<clipPath id="plate"><rect x="10" y="10" width="492" height="492" rx="128"/></clipPath>'
				+ '<radialGradient id="shine" cx="0.32" cy="0.26" r="1"><stop offset="0" stop-color="#ffffff" stop-opacity="0.55"/><stop offset="0.6" stop-color="#ffffff" stop-opacity="0"/></radialGradient>'
				+ '</defs>';
			let facets = '';
			for (let i = 0; i < 12; i++) {
				facets += '<use href="#wedge" transform="rotate(' + (i * 30) + ' 256 256)" fill="' + hsl(h + i * 14, 0.92, i % 2 ? 0.48 : 0.64) + '"/>'
					+ '<use href="#lead" transform="rotate(' + (i * 30) + ' 256 256)" stroke="rgba(255,255,255,0.4)" stroke-width="5"/>';
			}
			return svgWrap(defs
				+ '<g clip-path="url(#plate)">' + facets + frame('url(#shine)', { inset: 10, rx: 128 }) + '</g>'
				+ frame('none', { inset: 10, rx: 128, stroke: 'rgba(0,0,0,0.2)', sw: 6 })
				+ glyphWithShadow(inner, 15, '#ffffff', 'rgba(0,0,0,0.3)', 'rgba(0,0,0,0.3)', 6, 8));
		},
	},
	// the dare, at full tilt: clashing rainbow slabs whose bands rotate their
	// palettes, spinning hazard stripes, counter-spinning polka dots, six
	// twinkling sparkles, a pulsing frame, and a gently swaying gradient glyph.
	// Every icon runs on clock speeds seeded from its own hue, so a screen full
	// of these never syncs up. Do not assign this one if you actually have work
	// to do.
	clown: {
		label: 'Clown Barf',
		render: (h, inner) => {
			// per-icon clocks, seeded off the hue, so no two icons in the set share
			// a phase and nothing ever lines up
			const phase = (h % 11) / 10;
			const drift = 14 + (h % 11);
			const spin = 19 + (h % 7);
			const wobble = 3.6 + (h % 9) * 0.35;
			const pulse = 2.4 + (h % 6) * 0.4;
			const wob = (h * 7) % 360;
			// band hues chosen so each one clashes with its neighbours, and every
			// band keeps rotating through its palette at its own pace forever
			const clash = [0, 180, 40, 220, 80, 300];
			let stops = '';
			for (let i = 0; i < clash.length; i++) {
				const cycle = [];
				for (let k = 0; k <= clash.length; k++) {
					cycle.push(hsl(h + clash[(i + k) % clash.length], 1, i % 2 ? 0.55 : 0.67));
				}
				stops += '<stop offset="' + Math.round(i / (clash.length - 1) * 100) + '%" stop-color="' + cycle[0] + '">'
					+ '<animate attributeName="stop-color" values="' + cycle.join(';') + '" dur="' + (drift + i * 1.3).toFixed(1) + 's" repeatCount="indefinite"/>'
					+ '</stop>';
			}
			const defs = '<defs>'
				+ '<clipPath id="plate"><rect x="10" y="10" width="492" height="492" rx="120"/></clipPath>'
				+ '<linearGradient id="slab" x1="0" y1="0" x2="1" y2="1">' + stops + '</linearGradient>'
				+ '<pattern id="hazard" width="76" height="76" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
				+ '<rect width="38" height="76" fill="' + hsl(h + 130, 1, 0.52) + '"><animate attributeName="fill" values="' + [hsl(h + 130, 1, 0.52), hsl(h + 250, 1, 0.52), hsl(h + 10, 1, 0.52), hsl(h + 130, 1, 0.52)].join(';') + '" dur="' + (drift + 2).toFixed(1) + 's" repeatCount="indefinite"/></rect>'
				+ '<rect x="38" width="38" height="76" fill="' + hsl(h + 310, 1, 0.6) + '"><animate attributeName="fill" values="' + [hsl(h + 310, 1, 0.6), hsl(h + 70, 1, 0.6), hsl(h + 190, 1, 0.6), hsl(h + 310, 1, 0.6)].join(';') + '" dur="' + (drift + 3).toFixed(1) + 's" repeatCount="indefinite"/></rect>'
				+ '</pattern>'
				+ '<pattern id="dots" width="88" height="88" patternUnits="userSpaceOnUse">'
				+ '<circle cx="22" cy="22" r="13" fill="' + hsl(h + 200, 1, 0.64) + '"/>'
				+ '<circle cx="66" cy="66" r="13" fill="' + hsl(h + 24, 1, 0.7) + '"/>'
				+ '</pattern>'
				+ '<linearGradient id="glyph" x1="0" y1="0" x2="1" y2="1">'
				+ '<stop offset="0" stop-color="' + hsl(h + 70, 1, 0.78) + '"/>'
				+ '<stop offset="1" stop-color="' + hsl(h + 250, 1, 0.42) + '"/>'
				+ '</linearGradient>'
				+ '</defs>';
			// the stars twinkle on independent clocks, so the set never settles:
			// kt/scale/fade drive each one's private bloom-and-fade cycle and the
			// half-turn snap lands at a different phase for every star
			const sparkle = (x, y, r, fill, dur, kt, scale, fade) => {
				const d = (dur + phase).toFixed(1);
				return '<g transform="translate(' + x + ',' + y + ')">'
					+ '<g><animateTransform attributeName="transform" type="rotate" values="0;0;45;45" keyTimes="0;0.45;0.55;1" dur="' + d + 's" repeatCount="indefinite"/>'
					+ '<g><animateTransform attributeName="transform" type="scale" values="' + scale + '" keyTimes="' + kt + '" dur="' + d + 's" repeatCount="indefinite"/>'
					+ '<path d="M0 ' + (-r) + 'L' + (r * 0.28) + ' ' + (-r * 0.28) + 'L' + r + ' 0L' + (r * 0.28) + ' ' + (r * 0.28) + 'L0 ' + r + 'L' + (-r * 0.28) + ' ' + (r * 0.28) + 'L' + (-r) + ' 0L' + (-r * 0.28) + ' ' + (-r * 0.28) + 'Z" fill="' + fill + '"/>'
					+ '<animate attributeName="opacity" values="' + fade + '" keyTimes="' + kt + '" dur="' + d + 's" repeatCount="indefinite"/>'
					+ '</g></g></g>';
			};
			const twinkles = [
				[ 100, 96, 36, '#ffffff', 2.6, '0;0.15;0.35;1', '0;1;0.85;0', '0;1;0.9;0' ],
				[ 424, 128, 26, hsl(h + 150, 1, 0.72), 3.1, '0;0.45;0.55;1', '0;0;1.05;0', '0;0;1;0' ],
				[ 126, 424, 26, hsl(h + 320, 1, 0.74), 3.6, '0;0.75;0.85;1', '0;0;1;0', '0;0;1;0' ],
				[ 416, 412, 38, hsl(h + 50, 1, 0.68), 4.1, '0;0.3;0.45;1', '0;1;0.8;0', '0;1;0.8;0' ],
				[ 256, 74, 19, '#ffffff', 4.7, '0;0.62;0.68;1', '0;0;1.2;0', '0;0;1;0' ],
				[ 74, 258, 19, hsl(h + 100, 1, 0.76), 5.3, '0;0.2;0.28;1', '0;1;0;0', '0;1;0;0' ],
			];
			const plate = '<g clip-path="url(#plate)">'
				+ frame('url(#slab)', { inset: 10, rx: 120 })
				+ '<g><animateTransform attributeName="transform" type="rotate" from="' + wob + ' 256 256" to="' + (wob + 360) + ' 256 256" dur="' + spin + 's" repeatCount="indefinite"/><rect x="-160" y="-160" width="832" height="832" fill="url(#hazard)" opacity="0.6"/></g>'
				+ '<g><animateTransform attributeName="transform" type="rotate" from="' + (-wob) + ' 256 256" to="' + (-wob - 360) + ' 256 256" dur="' + (spin + 4) + 's" repeatCount="indefinite"/><rect x="-160" y="-160" width="832" height="832" fill="url(#dots)" opacity="0.55"/></g>'
				+ twinkles.map(t => sparkle(...t)).join('')
				+ '</g>';
			const glyph = '<g>'
				+ '<animateTransform attributeName="transform" type="rotate" values="-4.5 256 256;4.5 256 256;-4.5 256 256" dur="' + wobble.toFixed(1) + 's" repeatCount="indefinite"/>'
				+ '<g transform="translate(10,12)">' + wrapAt(sub(inner, '#000000', '#000000'), 15) + '</g>'
				+ '<g transform="translate(5,7)">' + wrapAt(sub(inner, '#ffffff', '#ffffff'), 15) + '</g>'
				+ wrapAt(sub(inner, 'url(#glyph)', 'rgba(0,0,0,0.85)'), 15)
				+ '</g>';
			const border = '<rect x="10" y="10" width="492" height="492" rx="120" fill="none" stroke="#000000" stroke-width="18">'
				+ '<animate attributeName="stroke-width" values="18;10;18" dur="' + pulse.toFixed(1) + 's" repeatCount="indefinite"/>'
				+ '</rect>';
			const ring = '<g><animate attributeName="opacity" values="0.9;0.3;0.9" dur="' + (pulse + 1.1).toFixed(1) + 's" repeatCount="indefinite"/>'
				+ frame('none', { inset: 30, rx: 100, stroke: '#ffffff', sw: 8 })
				+ '</g>';
			return svgWrap(defs + plate + border + ring + glyph);
		},
	},
};

function sub(inner, g, d) {
	return inner.split('{G}').join(g).split('{D}').join(d);
}
function svgWrap(body) {
	return '<svg xmlns="http://www.w3.org/2000/svg" width="' + SIZE + '" height="' + SIZE + '" viewBox="0 0 512 512">' + body + '</svg>\n';
}

// --- generate ------------------------------------------------------------------
function hashHue(str) {
	let h = 0;
	for (let i = 0; i < str.length; i++) { h = (h * 31 + str.charCodeAt(i)) % 360; }
	return h;
}

// The transport controls keep fixed hues in every colour set: stop is blue and
// every rewind/forward button shares a green, whatever the set or the name.
const HUE_OVERRIDES = {
	stop: 216,
	'stop sign': 216,
	prev: 148,
	back: 148,
	'left arrow': 148,
	next: 148,
	forward: 148,
	'right arrow': 148,
};
const hueFor = name => (HUE_OVERRIDES[name] != null ? HUE_OVERRIDES[name] : hashHue(name));

const styleKeys = Object.keys(STYLES);
const iconNames = Object.keys(ICONS);
let written = 0;

for (const style of styleKeys) {
	const dir = path.join(DIR, style);
	fs.mkdirSync(dir, { recursive: true });
	for (const name of iconNames) {
		const glyph = GLYPHS[ICONS[name]];
		if (!glyph) { throw new Error('Missing glyph for ' + name); }
		const svg = STYLES[style].render(hueFor(name), glyph);
		fs.writeFileSync(path.join(dir, name + '.svg'), svg);
		written++;
	}
}

console.log('Wrote ' + written + ' icons across ' + styleKeys.length + ' sets (' + styleKeys.join(', ') + ')');
