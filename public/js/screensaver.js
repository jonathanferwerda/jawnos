// The padlock screensaver. Two looks, picked in Configure -> Misc:
//
//   cartoon  a side-scrolling cartoon world made from the house's own
//            hand-drawn pictures. It visits four scenes for a minute each -
//            outdoors, a cave, underwater and a house - bouncing along with
//            logo2 or the doctor, zooming in and out, and every so often
//            stepping into the logo's own eyes for a first-person look around.
//   art      the older drifting colour-blobs with the house logo.
//
// The timing (when it appears, how long it waits, and staying away from video)
// lives here too, so every padlock frame behaves the same wherever it is
// included. The server passes the delay and the look on the layer's data
// attributes; see templates/padlock.html.ep.
(function () {
	'use strict';

	var DIRS = {
		make: '/images/make believe/',
		deci: '/images/decipherable/',
		jbutton: '/images/jbuttons/',
		cards: '/images/cards/'
	};

	// The props each world reaches for. Every file is a real picture in
	// public/images; a missing one is simply skipped.
	var SCENES = [
		{
			key: 'outdoors',
			props: [
				['make', 'house.png'], ['make', 'Mr. Sun.png'], ['make', 'new sun.png'],
				['make', 'acorn.png'], ['make', 'clover.png'], ['make', 'poppy.png'],
				['make', 'strawbeery.png'], ['make', 'Squirrelly.png'], ['make', 'Froggoli.png'],
				['make', 'Shrobbes.png'], ['make', 'hobbes.png'], ['make', 'tractor.png'],
				['make', 'road ahead.png'], ['make', 'boot.png'], ['make', 'canary.png'],
				['deci', 'the bird.png'], ['deci', 'church.png'], ['deci', 'stop sign.png'],
				['deci', 'tunnel.png'], ['jbutton', 'home.png'], ['jbutton', 'thejunderground.png']
			]
		},
		{
			key: 'cave',
			props: [
				['make', 'bad.png'], ['make', 'alien.png'], ['make', 'Scarapy.png'],
				['make', 'eye.png'], ['make', 'bullseye.png'], ['make', 'key.png'],
				['make', 'lock.png'], ['make', 'crown.png'], ['make', 'smoke.png'],
				['make', 'explosion.png'], ['make', 'detour.png'], ['make', 'space.png'],
				['make', 'boot.png'], ['make', 'tire.png'], ['make', 'hat.png'],
				['make', 'heart.png'], ['deci', 'tunnel.png'], ['deci', 'wrench.png'],
				['deci', 'server.png'], ['deci', 'microchip.png'], ['cards', 'death.png'],
				['cards', 'the devil.png'], ['cards', 'the tower.png'], ['cards', 'the moon.png'],
				['cards', 'the star.png']
			]
		},
		{
			key: 'underwater',
			props: [
				['make', 'water.png'], ['make', 'Froggoli.png'], ['make', 'canary.png'],
				['make', 'boot.png'], ['make', 'tire.png'], ['make', 'key.png'],
				['make', 'crown.png'], ['make', 'bowl.png'], ['make', 'shoe.png'],
				['make', 'heart.png'], ['deci', 'the bird.png'], ['deci', 'tunnel.png'],
				['deci', 'gift.png'], ['deci', 'ticket.png'], ['deci', 'diskette.png'],
				['deci', 'cdrom.png'], ['deci', 'watch.png'], ['cards', 'ace of cups.png'],
				['cards', 'the moon.png'], ['cards', 'the star.png'], ['cards', 'the world.png'],
				['cards', 'wheel of fortune.png'], ['cards', 'king of cups.png'],
				['cards', 'queen of cups.png']
			]
		},
		{
			key: 'house',
			props: [
				['deci', 'computer.png'], ['deci', 'phone.png'], ['deci', 'piano.png'],
				['deci', 'cake.png'], ['deci', 'gift.png'], ['deci', 'home.png'],
				['deci', 'clothesline.png'], ['deci', 'envelope.png'], ['deci', 'headphones.png'],
				['deci', 'nightlight.png'], ['deci', 'speaker.png'], ['deci', 'watch.png'],
				['deci', 'keyboard.png'], ['deci', 'diskette.png'], ['deci', 'cdrom.png'],
				['deci', 'calculator.png'], ['deci', 'palette.png'], ['deci', 'marker.png'],
				['deci', 'gallery.png'], ['make', 'Pillow.png'], ['make', 'bowl.png'],
				['make', 'burger.png'], ['make', 'eat.png'], ['make', 'hat.png'],
				['make', 'shoe.png'], ['make', 'mailbox.png'], ['make', 'telephone line.png'],
				['make', 'music.png'], ['make', 'heart.png'], ['cards', 'the sun.png'],
				['cards', 'the moon.png'], ['cards', 'the star.png'], ['cards', 'the lovers.png'],
				['cards', 'the magician.png'], ['cards', 'the world.png'], ['jbutton', 'logo1.png'],
				['jbutton', 'logo3.png'], ['jbutton', 'doctor.png']
			]
		}
	];

	var CHARACTERS = [
		['jbutton', 'logo2.png'],
		['jbutton', 'doctor.png']
	];

	var images = {};
	var preloaded = false;

	function path(folder, name) {
		return encodeURI(DIRS[folder] + name);
	}

	function image(folder, name) {
		var key = folder + '|' + name;
		if (images[key]) { return images[key]; }
		var img = new Image();
		img.src = path(folder, name);
		images[key] = img;
		return img;
	}

	function preload() {
		if (preloaded) { return; }
		preloaded = true;
		var i, j, defs;
		for (i = 0; i < SCENES.length; i++) {
			defs = SCENES[i].props;
			for (j = 0; j < defs.length; j++) { image(defs[j][0], defs[j][1]); }
		}
		for (i = 0; i < CHARACTERS.length; i++) { image(CHARACTERS[i][0], CHARACTERS[i][1]); }
	}

	function ready(img) {
		return !!(img && img.complete && img.naturalWidth);
	}

	function wrap(v, m) {
		return ((v % m) + m) % m;
	}

	function clamp(v, lo, hi) {
		return v < lo ? lo : (v > hi ? hi : v);
	}

	// ------------------------------------------------------------------
	// The older drifting-art look.
	// ------------------------------------------------------------------
	function artRenderer(canvas, layer) {
		var ctx = canvas.getContext('2d');
		var logo = new Image();
		var logo_src = layer.getAttribute('data-logo') || '/images/jbuttons/logo1.png';
		// a stored logo is a data URI and can carry line breaks; leave a normal
		// path alone, since its spaces ("make believe") are part of the URL
		if (logo_src.indexOf('data:') === 0) { logo_src = logo_src.replace(/\s+/g, ''); }
		logo.src = logo_src || '/images/jbuttons/logo1.png';

		var w = 1, h = 1;
		var blobs = [];
		var logoEvent = null, nextLogoAt = 0;

		function resize() {
			w = canvas.width = Math.max(1, window.innerWidth);
			h = canvas.height = Math.max(1, window.innerHeight);
		}

		function newArt() {
			var palette = [];
			for (var i = 0; i < 7; i++) {
				palette.push('hsl(' + Math.floor(Math.random() * 360) + ',' + (45 + Math.floor(Math.random() * 40)) + '%,' + (45 + Math.floor(Math.random() * 20)) + '%)');
			}
			blobs = [];
			for (var j = 0; j < 10; j++) {
				blobs.push({
					x: Math.random(), y: Math.random(),
					r: 0.05 + Math.random() * 0.22,
					dx: (Math.random() - 0.5) * 0.02,
					dy: (Math.random() - 0.5) * 0.02,
					c: palette[j % palette.length]
				});
			}
		}

		function startLogo(now) {
			if (!ready(logo)) { return; }
			var size = Math.min(w, h) * (0.10 + Math.random() * 0.16);
			var scale = Math.min(size / logo.naturalWidth, size / logo.naturalHeight);
			var lw = logo.naturalWidth * scale, lh = logo.naturalHeight * scale;
			var margin = Math.min(w, h) * 0.08;
			var roomX = Math.max(1, w - lw - margin * 2);
			var roomY = Math.max(1, h - lh - margin * 2);
			logoEvent = {
				start: now,
				duration: 4200 + Math.random() * 4200,
				x: margin + Math.random() * roomX + lw / 2,
				y: margin + Math.random() * roomY + lh / 2,
				w: lw, h: lh,
				rot: (Math.random() - 0.5) * 0.35
			};
		}

		function drawLogo(now) {
			if (!ready(logo)) { return; }
			if (!logoEvent) {
				if (!nextLogoAt) { nextLogoAt = now + 1000 + Math.random() * 2600; }
				if (now < nextLogoAt) { return; }
				startLogo(now);
				if (!logoEvent) { return; }
			}
			var p = (now - logoEvent.start) / logoEvent.duration;
			if (p >= 1) {
				logoEvent = null;
				nextLogoAt = now + 1800 + Math.random() * 6500;
				return;
			}
			var alpha = 0.9 * (p < 0.25 ? p / 0.25 : (p > 0.75 ? (1 - p) / 0.25 : 1));
			ctx.save();
			ctx.globalAlpha = alpha;
			ctx.shadowColor = 'rgba(255,255,255,0.55)';
			ctx.shadowBlur = 26;
			ctx.translate(logoEvent.x, logoEvent.y);
			ctx.rotate(logoEvent.rot);
			ctx.drawImage(logo, -logoEvent.w / 2, -logoEvent.h / 2, logoEvent.w, logoEvent.h);
			ctx.restore();
		}

		function draw(now, t) {
			ctx.globalCompositeOperation = 'source-over';
			ctx.fillStyle = '#08080d';
			ctx.fillRect(0, 0, w, h);
			ctx.globalCompositeOperation = 'lighter';
			for (var i = 0; i < blobs.length; i++) {
				var b = blobs[i];
				var x = (b.x + Math.sin(t * 0.08 + i) * 0.06 + b.dx * t) % 1;
				var y = (b.y + Math.cos(t * 0.07 + i) * 0.06 + b.dy * t) % 1;
				if (x < 0) { x += 1; }
				if (y < 0) { y += 1; }
				var r = b.r * Math.min(w, h);
				var g = ctx.createRadialGradient(x * w, y * h, 0, x * w, y * h, r);
				g.addColorStop(0, b.c);
				g.addColorStop(1, 'rgba(0,0,0,0)');
				ctx.fillStyle = g;
				ctx.fillRect(0, 0, w, h);
			}
			ctx.globalCompositeOperation = 'source-over';
			ctx.strokeStyle = 'rgba(255,255,255,0.10)';
			ctx.lineWidth = 1;
			for (var k = 0; k < 4; k++) {
				ctx.beginPath();
				ctx.arc(w * (0.2 + k * 0.2), h * 0.5, Math.min(w, h) * (0.2 + 0.1 * Math.sin(t * 0.1 + k)), 0, Math.PI * 2);
				ctx.stroke();
			}
			drawLogo(now);
		}

		function reset() {
			newArt();
			logoEvent = null;
			nextLogoAt = 0;
		}

		return { resize: resize, reset: reset, draw: draw };
	}

	// ------------------------------------------------------------------
	// The cartoon world.
	// ------------------------------------------------------------------
	function cartoonRenderer(canvas) {
		var ctx = canvas.getContext('2d');
		var w = 1, h = 1;
		var scene = -1, defs = [];
		var side = [], three = [];
		var charImg = null;
		var clouds = [], bubbles = [], motes = [], fish = [];

		var SCENE_LEN = 60;      // seconds in each world
		var WORLD_W = 12000;     // side-scroller loop, in pixels
		var THREE_A = 16, THREE_B = 24, THREE_C = 41, THREE_D = 49;

		preload();

		function resize() {
			w = canvas.width = Math.max(1, window.innerWidth);
			h = canvas.height = Math.max(1, window.innerHeight);
			scene = -1; // particles and background are sized to the window
		}

		function chooseCharacter() {
			var c = CHARACTERS[Math.floor(Math.random() * CHARACTERS.length)];
			charImg = image(c[0], c[1]);
		}

		function buildParticles(key) {
			clouds = [];
			bubbles = [];
			motes = [];
			fish = [];
			var i;
			if (key === 'outdoors') {
				for (i = 0; i < 7; i++) {
					clouds.push({ x: Math.random(), y: 0.08 + Math.random() * 0.28, s: 0.5 + Math.random() * 1.1 });
				}
			}
			if (key === 'underwater') {
				for (i = 0; i < 38; i++) {
					bubbles.push({ x: Math.random(), y: Math.random(), r: 0.003 + Math.random() * 0.012, speed: 0.012 + Math.random() * 0.035 });
				}
				for (i = 0; i < 6; i++) {
					fish.push({ x: Math.random(), y: 0.16 + Math.random() * 0.62, s: 0.35 + Math.random() * 0.8, speed: 0.01 + Math.random() * 0.03 });
				}
			}
			if (key === 'cave') {
				for (i = 0; i < 30; i++) {
					motes.push({ x: Math.random(), y: Math.random(), r: 0.001 + Math.random() * 0.003, speed: 0.004 + Math.random() * 0.01 });
				}
			}
		}

		function buildScene(i) {
			scene = i;
			defs = SCENES[i].props;
			side = buildSide(defs);
			three = build3D(defs, SCENES[i].key);
			buildParticles(SCENES[i].key);
		}

		function buildSide(list) {
			var out = [];
			var x = 260;
			while (x < WORLD_W) {
				var d = list[Math.floor(Math.random() * list.length)];
				out.push({
					img: image(d[0], d[1]),
					x: x,
					depth: 0.55 + Math.random() * 0.75,
					size: (0.09 + Math.random() * 0.15) * (d[0] === 'cards' ? 0.85 : 1),
					float: Math.random() < 0.15,
					phase: Math.random() * Math.PI * 2
				});
				x += 150 + Math.random() * 260;
			}
			return out;
		}

		function build3D(list, key) {
			var out = [];
			var i;
			for (i = 0; i < 110; i++) {
				var d = list[Math.floor(Math.random() * list.length)];
				// Ring them around the walk so every direction of the look-around
				// has something to see, not just the strip straight ahead.
				var ang = Math.random() * Math.PI * 2;
				var dist = 5 + Math.random() * 32;
				var x = 12 + Math.cos(ang) * dist + Math.random() * 8;
				var z = Math.sin(ang) * dist;
				if (Math.abs(z) < 2.5) { z += (z < 0 ? -4 : 4); }
				out.push({
					img: image(d[0], d[1]),
					x: x, z: z,
					size: 0.6 + Math.random() * 1.6,
					y: Math.random() < 0.16 ? 0.5 + Math.random() * 1.7 : 0,
					phase: Math.random() * Math.PI * 2
				});
			}
			// a landmark to turn toward once per revolution
			if (key === 'outdoors') {
				out.push({ img: image('make', 'Mr. Sun.png'), x: 55, z: -26, y: 7.5, size: 5, sky: 1 });
				out.push({ img: image('make', 'church.png'), x: 70, z: 24, size: 3.2 });
			}
			else if (key === 'cave') {
				out.push({ img: image('make', 'eye.png'), x: 42, z: 0, y: 2.6, size: 3.6, sky: 1 });
				out.push({ img: image('cards', 'the tower.png'), x: 60, z: -18, size: 2.4 });
			}
			else if (key === 'underwater') {
				out.push({ img: image('cards', 'the moon.png'), x: 58, z: 20, y: 7, size: 4, sky: 1 });
				out.push({ img: image('make', 'crown.png'), x: 35, z: -12, y: 0.6, size: 1.8 });
			}
			else {
				out.push({ img: image('cards', 'the sun.png'), x: 46, z: -14, y: 3.2, size: 2.2, sky: 1 });
				out.push({ img: image('deci', 'piano.png'), x: 32, z: 12, size: 2.0 });
			}
			return out;
		}

		// ---- side-scrolling world ----

		function drawSun(x, y, r) {
			ctx.save();
			ctx.globalAlpha = 0.9;
			ctx.fillStyle = '#ffe86b';
			ctx.beginPath();
			ctx.arc(x, y, r, 0, Math.PI * 2);
			ctx.fill();
			ctx.strokeStyle = 'rgba(255,232,107,0.35)';
			ctx.lineWidth = Math.max(2, r * 0.18);
			for (var i = 0; i < 10; i++) {
				var a = (i / 10) * Math.PI * 2;
				ctx.beginPath();
				ctx.moveTo(x + Math.cos(a) * r * 1.35, y + Math.sin(a) * r * 1.35);
				ctx.lineTo(x + Math.cos(a) * r * 1.75, y + Math.sin(a) * r * 1.75);
				ctx.stroke();
			}
			ctx.restore();
		}

		function drawCloud(x, y, s) {
			ctx.save();
			ctx.globalAlpha = 0.82;
			ctx.fillStyle = '#ffffff';
			ctx.beginPath();
			ctx.arc(x, y, 28 * s, 0, Math.PI * 2);
			ctx.arc(x + 30 * s, y - 10 * s, 36 * s, 0, Math.PI * 2);
			ctx.arc(x + 68 * s, y, 28 * s, 0, Math.PI * 2);
			ctx.arc(x + 34 * s, y + 12 * s, 30 * s, 0, Math.PI * 2);
			ctx.fill();
			ctx.restore();
		}

		function drawHills(camX, colour, amp, base, parallax, phase) {
			ctx.save();
			ctx.fillStyle = colour;
			ctx.beginPath();
			ctx.moveTo(-20, h);
			for (var x = -20; x <= w + 20; x += 18) {
				var p = ((x + camX * parallax) / w) * Math.PI * 4 + phase;
				ctx.lineTo(x, base + Math.sin(p) * amp + Math.sin(p * 0.47 + 1.3) * amp * 0.5);
			}
			ctx.lineTo(w + 20, h);
			ctx.closePath();
			ctx.fill();
			ctx.restore();
		}

		function drawTree(x, ground, scale) {
			ctx.save();
			ctx.fillStyle = '#6b4a2b';
			ctx.fillRect(x - 5 * scale, ground - 95 * scale, 10 * scale, 95 * scale);
			ctx.fillStyle = '#3f8f3f';
			ctx.beginPath();
			ctx.arc(x, ground - 105 * scale, 38 * scale, 0, Math.PI * 2);
			ctx.arc(x - 26 * scale, ground - 86 * scale, 27 * scale, 0, Math.PI * 2);
			ctx.arc(x + 28 * scale, ground - 88 * scale, 29 * scale, 0, Math.PI * 2);
			ctx.fill();
			ctx.restore();
		}

		function drawSideBackground(key, camX, t) {
			var horizon = h * 0.61;
			var ground = h * 0.79;
			var g;
			if (key === 'outdoors') {
				g = ctx.createLinearGradient(0, 0, 0, horizon + h * 0.1);
				g.addColorStop(0, '#7cc8ff');
				g.addColorStop(0.7, '#c9ecff');
				g.addColorStop(1, '#eef9ff');
				ctx.fillStyle = g;
				ctx.fillRect(0, 0, w, horizon + h * 0.1);
				drawSun(w * 0.78 + Math.sin(t * 0.04) * 14, h * 0.16, Math.min(w, h) * 0.075);
				for (var i = 0; i < clouds.length; i++) {
					var cx = wrap(clouds[i].x * (w + 220) - camX * 0.08, w + 220) - 110;
					drawCloud(cx, clouds[i].y * h, clouds[i].s);
				}
				drawHills(camX, '#8fd08a', h * 0.045, horizon - h * 0.02, 0.12, 0.0);
				drawHills(camX, '#6fbb6b', h * 0.06, horizon + h * 0.015, 0.24, 1.7);
				g = ctx.createLinearGradient(0, horizon, 0, h);
				g.addColorStop(0, '#76c45b');
				g.addColorStop(1, '#3d7f2a');
				ctx.fillStyle = g;
				ctx.fillRect(0, horizon, w, h - horizon);
				for (var tr = 0; tr < 6; tr++) {
					var tx = wrap(tr * (w / 5) + 60 - camX * 0.35, w + 260) - 130;
					drawTree(tx, horizon + h * 0.06, 0.55 + (tr % 3) * 0.18);
				}
				ctx.strokeStyle = 'rgba(30,80,25,0.35)';
				ctx.lineWidth = 2;
				for (var gr = 0; gr < 46; gr++) {
					var gx = wrap(gr * 97 - camX * 0.9, w + 40) - 20;
					var gy = ground + Math.sin(gr * 1.7) * h * 0.03;
					ctx.beginPath();
					ctx.moveTo(gx, gy);
					ctx.lineTo(gx + 7, gy - 14 - (gr % 3) * 5);
					ctx.stroke();
				}
			}
			else if (key === 'cave') {
				g = ctx.createLinearGradient(0, 0, 0, h);
				g.addColorStop(0, '#2b2232');
				g.addColorStop(0.55, '#3d2f40');
				g.addColorStop(1, '#1c1522');
				ctx.fillStyle = g;
				ctx.fillRect(0, 0, w, h);
				// ceiling
				ctx.fillStyle = '#3a2e3c';
				ctx.beginPath();
				ctx.moveTo(0, 0);
				for (var cx2 = 0; cx2 <= w; cx2 += 22) {
					ctx.lineTo(cx2, h * 0.08 + Math.sin(cx2 * 0.012 + camX * 0.0008) * h * 0.05 + Math.sin(cx2 * 0.04) * h * 0.02);
				}
				ctx.lineTo(w, 0);
				ctx.closePath();
				ctx.fill();
				for (var st = 0; st < 14; st++) {
					var sx = wrap(st * 130 - camX * 0.55, w + 200) - 100;
					var sl = h * (0.04 + ((st * 37) % 10) / 130);
					ctx.fillStyle = '#2a2030';
					ctx.beginPath();
					ctx.moveTo(sx - 16, h * 0.1);
					ctx.lineTo(sx + 16, h * 0.1);
					ctx.lineTo(sx + 2, h * 0.1 + sl);
					ctx.closePath();
					ctx.fill();
				}
				// floor
				ctx.fillStyle = '#241c2a';
				ctx.beginPath();
				ctx.moveTo(0, h);
				for (var fx = 0; fx <= w; fx += 26) {
					ctx.lineTo(fx, horizon + h * 0.06 + Math.sin(fx * 0.02 + camX * 0.002) * h * 0.025 + Math.sin(fx * 0.06) * h * 0.012);
				}
				ctx.lineTo(w, h);
				ctx.closePath();
				ctx.fill();
				// torches
				for (var to = 0; to < 7; to++) {
					var tx2 = wrap(to * (w / 6) + 90 - camX * 0.45, w + 200) - 100;
					var ty = horizon - h * 0.05;
					var rg = ctx.createRadialGradient(tx2, ty, 0, tx2, ty, Math.min(w, h) * 0.21);
					rg.addColorStop(0, 'rgba(255,180,80,0.58)');
					rg.addColorStop(0.35, 'rgba(255,120,35,0.24)');
					rg.addColorStop(1, 'rgba(255,90,20,0)');
					ctx.fillStyle = rg;
					ctx.fillRect(tx2 - Math.min(w, h) * 0.23, ty - Math.min(w, h) * 0.23, Math.min(w, h) * 0.46, Math.min(w, h) * 0.46);
					ctx.fillStyle = '#ffc35a';
					ctx.beginPath();
					ctx.arc(tx2, ty, 7, 0, Math.PI * 2);
					ctx.fill();
				}
				// a soft ambient so the pictures in the dark are still readable
				var amb = ctx.createRadialGradient(w * 0.5, h * 0.58, 0, w * 0.5, h * 0.58, Math.max(w, h) * 0.55);
				amb.addColorStop(0, 'rgba(150,120,170,0.17)');
				amb.addColorStop(1, 'rgba(0,0,0,0)');
				ctx.fillStyle = amb;
				ctx.fillRect(0, 0, w, h);
				for (var mo = 0; mo < motes.length; mo++) {
					var mx = wrap(motes[mo].x * w + Math.sin(t * 0.2 + mo) * 20, w);
					var my = wrap(motes[mo].y * h - t * motes[mo].speed * h, h);
					ctx.fillStyle = 'rgba(255,190,120,0.28)';
					ctx.beginPath();
					ctx.arc(mx, my, motes[mo].r * Math.min(w, h), 0, Math.PI * 2);
					ctx.fill();
				}
			}
			else if (key === 'underwater') {
				g = ctx.createLinearGradient(0, 0, 0, h);
				g.addColorStop(0, '#0b6ea8');
				g.addColorStop(0.55, '#0a4f7f');
				g.addColorStop(1, '#052c4d');
				ctx.fillStyle = g;
				ctx.fillRect(0, 0, w, h);
				// light shafts
				for (var ray = 0; ray < 7; ray++) {
					var rx = wrap(ray * (w / 6) - camX * 0.15, w + 260) - 130;
					ctx.save();
					ctx.globalAlpha = 0.055 + 0.02 * Math.sin(t * 0.6 + ray);
					ctx.fillStyle = '#bfe9ff';
					ctx.beginPath();
					ctx.moveTo(rx - 22, 0);
					ctx.lineTo(rx + 22, 0);
					ctx.lineTo(rx + 120, h);
					ctx.lineTo(rx - 46, h);
					ctx.closePath();
					ctx.fill();
					ctx.restore();
				}
				// seabed
				g = ctx.createLinearGradient(0, horizon + h * 0.06, 0, h);
				g.addColorStop(0, '#1c5d72');
				g.addColorStop(1, '#0a2e3a');
				ctx.fillStyle = g;
				ctx.beginPath();
				ctx.moveTo(0, h);
				for (var bx = 0; bx <= w; bx += 30) {
					ctx.lineTo(bx, horizon + h * 0.11 + Math.sin(bx * 0.012 + camX * 0.002) * h * 0.025);
				}
				ctx.lineTo(w, h);
				ctx.closePath();
				ctx.fill();
				// seaweed
				for (var sw = 0; sw < 14; sw++) {
					var wx = wrap(sw * (w / 12) + 20 - camX * 0.55, w + 120) - 60;
					var wy = horizon + h * 0.12 + Math.sin(sw * 1.9) * h * 0.03;
					var sway = Math.sin(t * 1.1 + sw) * h * 0.025;
					ctx.strokeStyle = 'rgba(40,150,110,0.65)';
					ctx.lineWidth = Math.max(3, h * 0.006);
					ctx.beginPath();
					ctx.moveTo(wx, wy);
					ctx.quadraticCurveTo(wx + sway, wy - h * 0.08, wx + sway * 1.7, wy - h * 0.16);
					ctx.stroke();
				}
				// fish
				for (var fi = 0; fi < fish.length; fi++) {
					var fx2 = wrap(fish[fi].x * w + t * fish[fi].speed * w, w + 120) - 60;
					var fy2 = fish[fi].y * h + Math.sin(t * 0.8 + fi) * 10;
					var fs = fish[fi].s * Math.min(w, h) * 0.035;
					ctx.fillStyle = 'rgba(120,210,220,0.55)';
					ctx.beginPath();
					ctx.ellipse ? ctx.ellipse(fx2, fy2, fs * 1.6, fs, 0, 0, Math.PI * 2) : ctx.arc(fx2, fy2, fs, 0, Math.PI * 2);
					ctx.fill();
					ctx.beginPath();
					ctx.moveTo(fx2 - fs * 1.5, fy2);
					ctx.lineTo(fx2 - fs * 2.4, fy2 - fs * 0.7);
					ctx.lineTo(fx2 - fs * 2.4, fy2 + fs * 0.7);
					ctx.closePath();
					ctx.fill();
				}
				for (var bu = 0; bu < bubbles.length; bu++) {
					var bxx = wrap(bubbles[bu].x * w + Math.sin(t * 0.7 + bu) * 18, w);
					var byy = wrap(bubbles[bu].y * h - t * bubbles[bu].speed * h, h);
					ctx.strokeStyle = 'rgba(210,245,255,0.42)';
					ctx.lineWidth = 1.5;
					ctx.beginPath();
					ctx.arc(bxx, byy, bubbles[bu].r * Math.min(w, h), 0, Math.PI * 2);
					ctx.stroke();
				}
			}
			else { // house
				ctx.fillStyle = '#d9cdb6';
				ctx.fillRect(0, 0, w, h * 0.8);
				// wallpaper stripes
				var stripe = Math.max(42, w * 0.045);
				for (var sp = -1; sp < w / stripe + 2; sp++) {
					var sx3 = wrap(sp * stripe - camX * 0.18, stripe);
					ctx.fillStyle = (sp % 2) ? 'rgba(180,160,130,0.22)' : 'rgba(255,255,255,0.16)';
					ctx.fillRect(sx3, 0, stripe * 0.5, horizon);
				}
				// floor
				g = ctx.createLinearGradient(0, horizon, 0, h);
				g.addColorStop(0, '#9c6d3f');
				g.addColorStop(1, '#6d4728');
				ctx.fillStyle = g;
				ctx.fillRect(0, horizon, w, h - horizon);
				ctx.strokeStyle = 'rgba(70,42,22,0.35)';
				ctx.lineWidth = 2;
				for (var pk = 0; pk < 12; pk++) {
					var pkx = wrap(pk * 110 - camX * 0.9, w + 120) - 60;
					ctx.beginPath();
					ctx.moveTo(pkx, horizon);
					ctx.lineTo(pkx - 30, h);
					ctx.stroke();
				}
				// baseboard
				ctx.fillStyle = '#7c5636';
				ctx.fillRect(0, horizon - h * 0.02, w, h * 0.025);
				// window
				var winx = w * 0.2 - (camX * 0.1 % w);
				ctx.fillStyle = '#f7f1e4';
				ctx.fillRect(winx - 10, h * 0.14, w * 0.2 + 20, h * 0.26);
				var wg = ctx.createLinearGradient(0, h * 0.14, 0, h * 0.4);
				wg.addColorStop(0, '#122245');
				wg.addColorStop(1, '#35558a');
				ctx.fillStyle = wg;
				ctx.fillRect(winx, h * 0.15, w * 0.2, h * 0.24);
				ctx.strokeStyle = '#f7f1e4';
				ctx.lineWidth = 6;
				ctx.beginPath();
				ctx.moveTo(winx + w * 0.1, h * 0.15);
				ctx.lineTo(winx + w * 0.1, h * 0.39);
				ctx.moveTo(winx, h * 0.27);
				ctx.lineTo(winx + w * 0.2, h * 0.27);
				ctx.stroke();
				ctx.fillStyle = '#ffe9a6';
				ctx.beginPath();
				ctx.arc(winx + w * 0.14, h * 0.21, Math.min(w, h) * 0.018, 0, Math.PI * 2);
				ctx.fill();
				// sofa, lamp, rug
				var sofaX = w * 0.58 - (camX * 0.35 % w);
				var sofaY = horizon + h * 0.02;
				var sofaW = w * 0.16, sofaH = h * 0.12;
				ctx.fillStyle = '#8d3f47';
				ctx.beginPath();
				ctx.moveTo(sofaX, sofaY + sofaH * 0.35);
				ctx.quadraticCurveTo(sofaX, sofaY - h * 0.02, sofaX + sofaW * 0.18, sofaY - h * 0.02);
				ctx.lineTo(sofaX + sofaW * 0.82, sofaY - h * 0.02);
				ctx.quadraticCurveTo(sofaX + sofaW, sofaY - h * 0.02, sofaX + sofaW, sofaY + sofaH * 0.35);
				ctx.lineTo(sofaX + sofaW, sofaY + sofaH);
				ctx.lineTo(sofaX, sofaY + sofaH);
				ctx.closePath();
				ctx.fill();
				ctx.fillStyle = '#a9525b';
				ctx.fillRect(sofaX + sofaW * 0.14, sofaY + sofaH * 0.34, sofaW * 0.72, sofaH * 0.36);
				ctx.fillStyle = '#7a353c';
				ctx.fillRect(sofaX - sofaW * 0.07, sofaY + sofaH * 0.22, sofaW * 0.12, sofaH * 0.78);
				ctx.fillRect(sofaX + sofaW * 0.95, sofaY + sofaH * 0.22, sofaW * 0.12, sofaH * 0.78);
				ctx.fillStyle = '#5d4a33';
				ctx.fillRect(sofaX + sofaW * 0.1, sofaY + sofaH, sofaW * 0.08, h * 0.03);
				ctx.fillRect(sofaX + sofaW * 0.82, sofaY + sofaH, sofaW * 0.08, h * 0.03);
				var lampX = w * 0.86 - (camX * 0.35 % w);
				ctx.fillStyle = '#f6d98b';
				ctx.beginPath();
				ctx.arc(lampX, horizon - h * 0.16, Math.min(w, h) * 0.05, 0, Math.PI * 2);
				ctx.fill();
				var lg = ctx.createRadialGradient(lampX, horizon - h * 0.16, 0, lampX, horizon - h * 0.16, Math.min(w, h) * 0.22);
				lg.addColorStop(0, 'rgba(255,230,150,0.35)');
				lg.addColorStop(1, 'rgba(255,230,150,0)');
				ctx.fillStyle = lg;
				ctx.fillRect(lampX - Math.min(w, h) * 0.22, horizon - h * 0.16 - Math.min(w, h) * 0.22, Math.min(w, h) * 0.44, Math.min(w, h) * 0.44);
				ctx.fillStyle = 'rgba(150,70,60,0.55)';
				ctx.beginPath();
				ctx.ellipse ? ctx.ellipse(w * 0.5, h * 0.9, w * 0.22, h * 0.05, 0, 0, Math.PI * 2) : ctx.arc(w * 0.5, h * 0.9, w * 0.22, 0, Math.PI * 2);
				ctx.fill();
			}
		}

		function drawSideProps(camX, t, part) {
			var charX = w * 0.42;
			var horizon = h * 0.61;
			var groundY = h * 0.79;
			for (var i = 0; i < side.length; i++) {
				var p = side[i];
				if (part === 'back' && p.depth > 1) { continue; }
				if (part === 'front' && p.depth <= 1) { continue; }
				var rel = wrap(p.x - camX, WORLD_W);
				if (rel > WORLD_W / 2) { rel -= WORLD_W; }
				var sx = charX + rel * p.depth;
				if (sx < -w * 0.45 || sx > w * 1.45) { continue; }
				var bottom = horizon + (groundY - horizon) * p.depth;
				var ph = p.size * h * p.depth;
				var img = p.img;
				if (!ready(img)) { continue; }
				var pw = ph * (img.naturalWidth / img.naturalHeight);
				if (p.float) {
					bottom -= ph * 0.5 + Math.sin(t * 1.5 + p.phase) * ph * 0.10;
				}
				else {
					ctx.save();
					ctx.globalAlpha = 0.20;
					ctx.fillStyle = '#000';
					ctx.beginPath();
					ctx.ellipse ? ctx.ellipse(sx, bottom, pw * 0.32, ph * 0.055, 0, 0, Math.PI * 2) : ctx.arc(sx, bottom, pw * 0.3, 0, Math.PI * 2);
					ctx.fill();
					ctx.restore();
				}
				ctx.drawImage(img, sx - pw / 2, bottom - ph, pw, ph);
			}
		}

		function drawCharacter(t) {
			var size = h * 0.165;
			var x = w * 0.42;
			var ground = h * 0.79;
			if (!ready(charImg)) { return; }
			var ar = charImg.naturalWidth / charImg.naturalHeight;
			var bounce = Math.abs(Math.sin(t * 6.4)) * size * 0.14;
			ctx.save();
			ctx.globalAlpha = 0.22;
			ctx.fillStyle = '#000';
			ctx.beginPath();
			ctx.ellipse ? ctx.ellipse(x, ground, size * 0.30, size * 0.06, 0, 0, Math.PI * 2) : ctx.arc(x, ground, size * 0.3, 0, Math.PI * 2);
			ctx.fill();
			ctx.restore();
			ctx.save();
			ctx.translate(x, ground - size + bounce);
			ctx.rotate(Math.sin(t * 6.4) * 0.035);
			ctx.drawImage(charImg, -size * ar / 2, 0, size * ar, size);
			ctx.restore();
		}

		function drawSide(t, sceneT) {
			var camX = (sceneT * 74) % WORLD_W;
			var zoom = 1 + 0.20 * Math.sin(t * 0.30);
			drawSideBackground(SCENES[scene].key, camX, t);
			ctx.save();
			ctx.translate(w / 2, h / 2);
			ctx.scale(zoom, zoom);
			ctx.translate(-w / 2, -h / 2);
			drawSideProps(camX, t, 'back');
			drawCharacter(t);
			drawSideProps(camX, t, 'front');
			ctx.restore();
		}

		// ---- first-person look-around ----

		function threeWindow(sceneT) {
			if (sceneT >= THREE_A && sceneT < THREE_B) { return (sceneT - THREE_A) / (THREE_B - THREE_A); }
			if (sceneT >= THREE_C && sceneT < THREE_D) { return (sceneT - THREE_C) / (THREE_D - THREE_C); }
			return -1;
		}

		function overlayAlpha(sceneT) {
			var marks = [THREE_A, THREE_B, THREE_C, THREE_D];
			var a = 0;
			for (var i = 0; i < marks.length; i++) {
				var m = marks[i];
				if (sceneT >= m - 0.5 && sceneT < m) { a = Math.max(a, (sceneT - (m - 0.5)) / 0.5); }
				if (sceneT >= m && sceneT < m + 0.5) { a = Math.max(a, 1 - (sceneT - m) / 0.5); }
			}
			return a;
		}

		function draw3DBackground(key, yaw, camX, t) {
			var horizon = h * 0.5 + Math.sin(t * 0.9) * h * 0.012;
			var g, i;
			if (key === 'outdoors') {
				g = ctx.createLinearGradient(0, 0, 0, horizon);
				g.addColorStop(0, '#5fb7ee');
				g.addColorStop(1, '#d9f2ff');
				ctx.fillStyle = g;
				ctx.fillRect(0, 0, w, horizon);
				// a wavy horizon of distant hills that turns with the camera
				ctx.fillStyle = '#84c97f';
				ctx.beginPath();
				ctx.moveTo(0, horizon + 2);
				for (var x = 0; x <= w + 16; x += 16) {
					var ph = x * 0.006 + yaw * 2.2;
					ctx.lineTo(x, horizon - h * 0.035 - Math.sin(ph) * h * 0.022 - Math.sin(ph * 2.3) * h * 0.012);
				}
				ctx.lineTo(w, horizon + 2);
				ctx.closePath();
				ctx.fill();
				g = ctx.createLinearGradient(0, horizon, 0, h);
				g.addColorStop(0, '#6cbb53');
				g.addColorStop(1, '#2f6b22');
				ctx.fillStyle = g;
				ctx.fillRect(0, horizon, w, h - horizon);
			}
			else if (key === 'cave') {
				g = ctx.createLinearGradient(0, 0, 0, h);
				g.addColorStop(0, '#140f16');
				g.addColorStop(0.5, '#2a1d2c');
				g.addColorStop(1, '#0c090e');
				ctx.fillStyle = g;
				ctx.fillRect(0, 0, w, h);
				// rotating stalactites
				ctx.fillStyle = '#1d151f';
				for (i = 0; i < 20; i++) {
					var sx = wrap((i * 83 - yaw * w * 0.14), w + 160) - 80;
					var sl = h * (0.05 + ((i * 29) % 9) / 120);
					ctx.beginPath();
					ctx.moveTo(sx - 18, 0);
					ctx.lineTo(sx + 18, 0);
					ctx.lineTo(sx + 2, sl);
					ctx.closePath();
					ctx.fill();
				}
				ctx.fillStyle = '#1e1624';
				ctx.fillRect(0, horizon + h * 0.04, w, h - horizon);
				for (i = 0; i < 5; i++) {
					var gx = wrap((i * (w / 4) + 80 - yaw * w * 0.12), w + 200) - 100;
					var rg = ctx.createRadialGradient(gx, horizon - h * 0.04, 0, gx, horizon - h * 0.04, Math.min(w, h) * 0.18);
					rg.addColorStop(0, 'rgba(255,150,50,0.34)');
					rg.addColorStop(1, 'rgba(255,90,20,0)');
					ctx.fillStyle = rg;
					ctx.fillRect(gx - Math.min(w, h) * 0.2, horizon - h * 0.24, Math.min(w, h) * 0.4, Math.min(w, h) * 0.4);
				}
				var amb = ctx.createRadialGradient(w * 0.5, h * 0.58, 0, w * 0.5, h * 0.58, Math.max(w, h) * 0.55);
				amb.addColorStop(0, 'rgba(150,120,170,0.20)');
				amb.addColorStop(1, 'rgba(0,0,0,0)');
				ctx.fillStyle = amb;
				ctx.fillRect(0, 0, w, h);
			}
			else if (key === 'underwater') {
				g = ctx.createLinearGradient(0, 0, 0, h);
				g.addColorStop(0, '#0c74ae');
				g.addColorStop(0.5, '#0a4a78');
				g.addColorStop(1, '#04243d');
				ctx.fillStyle = g;
				ctx.fillRect(0, 0, w, h);
				for (i = 0; i < 8; i++) {
					var rx = wrap((i * (w / 7) - yaw * w * 0.09), w + 260) - 130;
					ctx.save();
					ctx.globalAlpha = 0.06;
					ctx.fillStyle = '#c8efff';
					ctx.beginPath();
					ctx.moveTo(rx - 26, 0);
					ctx.lineTo(rx + 26, 0);
					ctx.lineTo(rx + 150, h);
					ctx.lineTo(rx - 70, h);
					ctx.closePath();
					ctx.fill();
					ctx.restore();
				}
				g = ctx.createLinearGradient(0, horizon + h * 0.03, 0, h);
				g.addColorStop(0, '#155365');
				g.addColorStop(1, '#072936');
				ctx.fillStyle = g;
				ctx.fillRect(0, horizon + h * 0.03, w, h - horizon);
			}
			else { // house
				ctx.fillStyle = '#d9cdb6';
				ctx.fillRect(0, 0, w, horizon);
				var stripe = Math.max(52, w * 0.05);
				var shift = wrap(yaw * w * 0.45, stripe * 2);
				for (i = -2; i <= w / stripe + 2; i++) {
					var x2 = i * stripe - shift;
					ctx.fillStyle = (i % 2) ? 'rgba(178,157,127,0.24)' : 'rgba(255,255,255,0.20)';
					ctx.fillRect(x2, 0, stripe * 0.5, horizon);
				}
				ctx.fillStyle = 'rgba(255,255,255,0.35)';
				ctx.fillRect(0, horizon - h * 0.14, w, 3);
				g = ctx.createLinearGradient(0, horizon, 0, h);
				g.addColorStop(0, '#9c6d3f');
				g.addColorStop(1, '#5d3c22');
				ctx.fillStyle = g;
				ctx.fillRect(0, horizon, w, h - horizon);
				ctx.strokeStyle = 'rgba(60,36,18,0.36)';
				ctx.lineWidth = 2;
				for (i = -12; i <= 12; i++) {
					var bx = w / 2 + i * w * 0.085 + Math.sin(yaw) * w * 0.1;
					ctx.beginPath();
					ctx.moveTo(bx, horizon);
					ctx.lineTo(bx + (bx - w / 2) * 1.8, h);
					ctx.stroke();
				}
				ctx.fillStyle = '#7c5636';
				ctx.fillRect(0, horizon - 3, w, 6);
			}
			return horizon;
		}

		function draw3D(t, sceneT, u) {
			var key = SCENES[scene].key;
			// A gentle look left and right, twenty degrees each way. A full turn
			// across the same eight seconds was far too fast to watch.
			var yaw = Math.sin(u * Math.PI * 2) * (20 * Math.PI / 180);
			var camX = u * 6;
			var camY = 1.55 + Math.sin(u * Math.PI * 8) * 0.025;
			var horizon = h * 0.5 + Math.sin(t * 0.9) * h * 0.012;
			horizon = draw3DBackground(key, yaw, camX, t);

			var f = h * 0.95;
			var cos = Math.cos(yaw), sin = Math.sin(yaw);
			var list = [];
			var i, p, dx, dz, rz, rx, sx, ground, top, sizePx, pw, ph, alpha;
			for (i = 0; i < three.length; i++) {
				p = three[i];
				dx = p.x - camX;
				dz = p.z;
				rz = dx * cos + dz * sin;
				if (rz < 2.0) { continue; }
				rx = -dx * sin + dz * cos;
				list.push({ p: p, rz: rz, rx: rx });
			}
			list.sort(function (a, b) { return b.rz - a.rz; });
			for (i = 0; i < list.length; i++) {
				p = list[i].p;
				rz = list[i].rz;
				rx = list[i].rx;
				sx = w / 2 + f * rx / rz;
				if (sx < -w * 0.8 || sx > w * 1.8) { continue; }
				if (!ready(p.img)) { continue; }
				ph = f * p.size / rz;
				if (ph < 2 || ph > h * 1.2) { continue; }
				pw = ph * (p.img.naturalWidth / p.img.naturalHeight);
				ground = horizon + f * camY / rz;
				top = ground - ph - f * (p.y || 0) / rz;
				alpha = clamp(1 - (rz - 3) / 75, 0.20, 1);
				if (!p.sky && !p.y) {
					ctx.save();
					ctx.globalAlpha = alpha * 0.22;
					ctx.fillStyle = '#000';
					ctx.beginPath();
					ctx.ellipse ? ctx.ellipse(sx, ground, pw * 0.30, ph * 0.05, 0, 0, Math.PI * 2) : ctx.arc(sx, ground, pw * 0.3, 0, Math.PI * 2);
					ctx.fill();
					ctx.restore();
				}
				ctx.save();
				ctx.globalAlpha = alpha;
				ctx.drawImage(p.img, sx - pw / 2, top, pw, ph);
				ctx.restore();
			}

			// bubbles and motes carry into the first-person view
			if (key === 'underwater') {
				for (i = 0; i < bubbles.length; i++) {
					var bxx = wrap(bubbles[i].x * w + Math.sin(t * 0.7 + i) * 18, w);
					var byy = wrap(bubbles[i].y * h - t * bubbles[i].speed * h, h);
					ctx.strokeStyle = 'rgba(210,245,255,0.35)';
					ctx.lineWidth = 1.5;
					ctx.beginPath();
					ctx.arc(bxx, byy, bubbles[i].r * Math.min(w, h) * 1.5, 0, Math.PI * 2);
					ctx.stroke();
				}
			}
			if (key === 'cave') {
				for (i = 0; i < motes.length; i++) {
					var mx = wrap(motes[i].x * w + Math.sin(t * 0.2 + i) * 20, w);
					var my = wrap(motes[i].y * h - t * motes[i].speed * h, h);
					ctx.fillStyle = 'rgba(255,190,120,0.24)';
					ctx.beginPath();
					ctx.arc(mx, my, motes[i].r * Math.min(w, h), 0, Math.PI * 2);
					ctx.fill();
				}
			}
		}

		function drawVignette() {
			var g = ctx.createRadialGradient(w / 2, h / 2, Math.min(w, h) * 0.30, w / 2, h / 2, Math.max(w, h) * 0.72);
			g.addColorStop(0, 'rgba(0,0,0,0)');
			g.addColorStop(1, 'rgba(0,0,0,0.45)');
			ctx.fillStyle = g;
			ctx.fillRect(0, 0, w, h);
		}

		function draw(now, t) {
			var sceneT = t % SCENE_LEN;
			var idx = Math.floor(t / SCENE_LEN) % SCENES.length;
			if (idx !== scene) { buildScene(idx); }
			var u = threeWindow(sceneT);
			if (u < 0) {
				drawSide(t, sceneT);
			}
			else {
				draw3D(t, sceneT, u);
			}
			drawVignette();
			var fade = overlayAlpha(sceneT);
			if (fade > 0) {
				ctx.fillStyle = 'rgba(0,0,0,' + fade.toFixed(3) + ')';
				ctx.fillRect(0, 0, w, h);
			}
		}

		function reset() {
			chooseCharacter();
			scene = -1;
		}

		return { resize: resize, reset: reset, draw: draw };
	}

	// ------------------------------------------------------------------
	// Timing and visibility: show only while this padlock is on screen, never
	// over a playing video, and wait the delay configured for the context.
	// ------------------------------------------------------------------
	function start(layer) {
		if (layer.__jawnScreensaver) { return; }
		var frame = layer.closest ? layer.closest('.padlock_frame') : null;
		if (!frame) { return; }
		var canvas = layer.querySelector('canvas');
		if (!canvas) { return; }
		layer.__jawnScreensaver = true;

		var style = (layer.getAttribute('data-style') || 'cartoon').toLowerCase();
		var renderer = style === 'art' ? artRenderer(canvas, layer) : cartoonRenderer(canvas);
		var managerDelay = parseInt(layer.getAttribute('data-manager-delay'), 10);
		if (!(managerDelay > 0)) { managerDelay = 120000; }
		var LOCK_DELAY = 15000;

		var timer = null, raf = null, active = false, started = 0, last = 0;
		var shownBefore = null, videoBefore = null;

		function lockedContext() {
			return !!(frame.closest('#locked_screen') || frame.closest('#padlock_frame'));
		}
		function delay() {
			return lockedContext() ? LOCK_DELAY : managerDelay;
		}
		function frameShown() {
			return !!(frame.offsetWidth || frame.offsetHeight || frame.getClientRects().length);
		}
		function videoPlaying() {
			var vids = document.querySelectorAll('video');
			for (var i = 0; i < vids.length; i++) {
				var v = vids[i];
				if (v.paused || v.ended) { continue; }
				if (!(v.offsetWidth || v.offsetHeight || v.getClientRects().length)) { continue; }
				return true;
			}
			return false;
		}
		function show() {
			if (active) { return; }
			if (!document.body.contains(frame) || !frameShown() || videoPlaying()) { return; }
			active = true;
			var oldLayers = document.querySelectorAll('body > .padlock_screensaver');
			for (var oi = 0; oi < oldLayers.length; oi++) {
				if (oldLayers[oi] !== layer) { oldLayers[oi].parentNode.removeChild(oldLayers[oi]); }
			}
			if (layer.parentNode !== document.body) { document.body.appendChild(layer); }
			renderer.resize();
			renderer.reset();
			layer.style.display = 'block';
			started = performance.now();
			last = 0;
			if (raf) { cancelAnimationFrame(raf); }
			// Paint the first frame now, not a frame later: the layer becomes
			// visible in this tick and a slow device should not show a black
			// screen while the first animation frame waits.
			paint(performance.now(), 0);
			raf = requestAnimationFrame(loop);
		}
		function hide() {
			active = false;
			layer.style.display = 'none';
			if (raf) { cancelAnimationFrame(raf); raf = null; }
		}
		function paint(now, t) {
			try { renderer.draw(now, t); }
			catch (e) { if (window.console && console.error) { console.error('screensaver:', e); } }
		}
		function loop(now) {
			if (!active) { return; }
			if (!document.body.contains(frame) || !frameShown() || videoPlaying()) { hide(); return; }
			raf = requestAnimationFrame(loop);
			if (now - last < 33) { return; }
			last = now;
			paint(now, (now - started) / 1000);
		}
		function restart() {
			if (timer) { clearTimeout(timer); }
			timer = null;
			if (!frameShown() || videoPlaying()) { return; }
			timer = setTimeout(show, delay());
		}
		function watch() {
			if (!document.body.contains(frame) || !document.body.contains(layer)) {
				if (timer) { clearTimeout(timer); }
				if (raf) { cancelAnimationFrame(raf); }
				clearInterval(watchTimer);
				EVENTS.forEach(function (ev) { document.removeEventListener(ev, onInput, false); });
				window.removeEventListener('resize', onResize);
				return;
			}
			var shown = frameShown();
			var playing = videoPlaying();
			if (active && (!shown || playing)) { hide(); }
			if (shown && !playing) {
				if (shownBefore !== true || videoBefore === true) { restart(); }
			}
			else if (timer) {
				clearTimeout(timer);
				timer = null;
			}
			shownBefore = shown;
			videoBefore = playing;
		}

		function onInput() {
			if (active) { hide(); }
			restart();
		}
		var EVENTS = ['mousemove', 'mousedown', 'keydown', 'touchstart', 'wheel'];
		EVENTS.forEach(function (ev) {
			document.addEventListener(ev, onInput, { passive: true });
		});
		function onResize() { if (active) { renderer.resize(); } }
		window.addEventListener('resize', onResize);

		var watchTimer = setInterval(watch, 500);
		watch();
	}

	function init() {
		var layers = document.querySelectorAll('.padlock_screensaver');
		for (var i = 0; i < layers.length; i++) { start(layers[i]); }
	}

	var scheduled = null;
	function scheduleInit() {
		if (scheduled) { return; }
		scheduled = setTimeout(function () { scheduled = null; init(); }, 0);
	}

	window.JawnoScreensaverInit = init;
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', scheduleInit);
	}
	else {
		scheduleInit();
	}
	if (window.MutationObserver) {
		new MutationObserver(scheduleInit).observe(document.documentElement, { childList: true, subtree: true });
	}
})();
