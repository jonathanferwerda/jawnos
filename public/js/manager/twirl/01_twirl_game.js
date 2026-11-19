// Twirl is a falling-block puzzle in a ten-by-twenty well. The game owns one
// requestAnimationFrame loop: gravity, the held-key repeat and the line-clear
// flash all advance from its clock. The old code drove gravity from a
// setInterval and started another whenever the level changed, so a clear, a
// pause or a closed window could leave a second loop ticking beside the new
// one - the hang. Here the loop notices a removed canvas and tears itself down,
// and the window teardown drops the instance at once.
//
// The wall, the well and the panel do not change between frames, so they are
// painted once into an offscreen canvas; a frame blits that and then draws only
// the board, the falling shape and the numbers. Each colour is a bevelled,
// grained tile with four variants, so a wall of blocks does not look stamped.
//
// The play appointment shares the Gou's pause rules; the key or click that
// moves a piece is the touch that starts and keeps it.
function twirlPlayScreen() {
	return $('#twirl').length > 0 && $('#twirl').is(':visible');
}
function twirlPlayTouch() {
	if (typeof jawnosGameSessionStart === 'function' && twirlPlayScreen()) {
		jawnosGameSessionStart('Twirl', twirlPlayScreen);
	}
}

// The window teardown calls this. The loop would also notice the removed canvas
// on its next frame; this drops the instance the moment the close is asked for,
// so a reopen never races a frame that has not run yet.
function twirlTeardown() {
	if (twirlInstance && typeof twirlInstance.destroy === 'function') {
		twirlInstance.destroy();
	}
	twirlInstance = null;
	twirlControls = null;
	twirlRunning = false;
}

function twirlGame() {
	var canvas = document.getElementById('twirl');
	if (!canvas || !$('#twirl').is(':visible')) {
		return;
	}
	if (typeof jawnosGameSessionStart === 'function') {
		jawnosGameSessionStart('Twirl', twirlPlayScreen);
	}
	// One game per page: a reopened window replaces the old instance instead of
	// leaving its loop running beside the new one.
	twirlTeardown();
	twirlRunning = true;
	var game = twirlGameCreate(canvas);
	if (!game) {
		twirlRunning = false;
		return;
	}
	twirlInstance = game;
}

function twirlGameCreate(canvas) {
	var ctx = canvas.getContext('2d');
	if (!ctx) { return null; }

	var COLS = 10;
	var ROWS = 20;
	var MAX_SCORES = 5;

	var BASE_SPEED = 800;
	var LEVEL_STEP = 70;
	var MIN_SPEED = 90;
	var DAS_DELAY = 150;
	var DAS_REPEAT = 50;
	var SOFT_REPEAT = 50;
	var FLASH_MS = 360;

	var PALETTE = {
		red:        { base: '#c0392b', light: '#ec8a7c', dark: '#731f16' },
		blue:       { base: '#2f6fdb', light: '#86b0f4', dark: '#173f8a' },
		green:      { base: '#2e9e44', light: '#85d99b', dark: '#155a25' },
		yellow:     { base: '#e0b21b', light: '#f8e08a', dark: '#8a6a06' },
		orange:     { base: '#e07b26', light: '#f8bd7d', dark: '#8a470f' },
		lightgreen: { base: '#7fc241', light: '#c2ea94', dark: '#47731d' },
		lightblue:  { base: '#49b6d6', light: '#a6e2f4', dark: '#236b85' }
	};

	var twirlPieces = [
		{ name: 'straight',   colour: 'red',        pivot: [0,1], matrix: [[1,1,1,1],[0,0,0,0],[0,0,0,0],[0,0,0,0]] },
		{ name: 'cube',       colour: 'blue',       pivot: [0,0], matrix: [[1,1],[1,1]] },
		{ name: 'left_curl',  colour: 'green',      pivot: [1,1], matrix: [[1,0,0],[1,1,1],[0,0,0]] },
		{ name: 'right_curl', colour: 'yellow',     pivot: [1,1], matrix: [[0,0,1],[1,1,1],[0,0,0]] },
		{ name: 'crown',      colour: 'orange',     pivot: [1,1], matrix: [[0,1,0],[1,1,1],[0,0,0]] },
		{ name: 'lstep',      colour: 'lightgreen', pivot: [1,1], matrix: [[0,1,1],[1,1,0],[0,0,0]] },
		{ name: 'rstep',      colour: 'lightblue',  pivot: [1,1], matrix: [[1,1,0],[0,1,1],[0,0,0]] }
	];

	// --- geometry, in CSS pixels (the canvas itself is scaled for HiDPI) ---
	var viewW = 0;
	var viewH = 0;
	var scale = 1;
	var block = 24;
	var gap = 24;
	var fieldLeft = 0;
	var fieldTop = 0;
	var fieldWidth = 240;
	var fieldHeight = 480;
	var panelLeft = 0;
	var panelTop = 0;
	var panelWidth = 0;
	var panelHeight = 0;
	var fs = 13;
	var fsBig = 20;
	var fsHead = 21;
	var info = {};

	var bgCanvas = null;
	var sprites = {};

	var board = [];
	var twirlSpace = {
		score: 0,
		lines: 0,
		level: 1,
		speed: BASE_SPEED,
		storedHigh: 0,
		initials: '',
		scores: [],
		paused: false,
		over: false,
		nextPiece: 0,
		current: null
	};

	var held = {};
	var lastDir = null;
	var repeatAt = 0;
	var downAt = 0;
	var acc = 0;
	var lastTime = 0;
	var pausedAt = 0;
	var clearing = null;
	var needsDraw = true;
	var rafId = null;
	var observer = null;
	var fallbackResize = null;
	var destroyed = false;
	var controls = null;
	var instance = null;

	function clock() {
		return (window.performance && performance.now) ? performance.now() : Date.now();
	}

	function twirlSeed(seed) {
		var s = Math.abs(Math.floor(seed)) % 2147483647;
		if (s <= 0) { s += 2147483646; }
		return function () {
			s = (s * 16807) % 2147483647;
			return (s - 1) / 2147483646;
		};
	}

	// --- layout ---------------------------------------------------------------
	function computeLayout() {
		var margin = Math.max(10, Math.min(26, Math.round(Math.min(viewW, viewH) * 0.03)));
		var unitsW = COLS + 1.25 + 6.4;
		block = Math.floor(Math.min((viewW - margin * 2) / unitsW, (viewH - margin * 2) / ROWS));
		block = Math.max(block, 6);

		// The panel's type keeps a floor size on a small window, while the well is
		// free to keep shrinking; the two are centred as one picture.
		var pb = Math.max(block, 16);
		gap = Math.max(10, Math.round(block * 1.25));
		panelWidth = Math.round(pb * 6.4);
		fieldWidth = block * COLS;
		fieldHeight = block * ROWS;

		var fit = viewW - margin * 2;
		if (fieldWidth + gap + panelWidth > fit) {
			block = Math.max(6, Math.floor((fit - gap - panelWidth) / COLS));
			fieldWidth = block * COLS;
			fieldHeight = block * ROWS;
		}

		fs = Math.max(10, Math.round(pb * 0.5));
		fsBig = Math.max(14, Math.round(pb * 0.8));
		fsHead = Math.max(15, Math.round(pb * 0.85));

		var pad = Math.max(9, Math.round(pb * 0.5));
		var rel = {};
		rel.next = pad + Math.round(fsHead * 0.85);
		rel.nextBoxTop = rel.next + Math.round(fs * 0.4);
		rel.nextBox = Math.round(pb * 4);
		rel.scoreLabel = rel.nextBoxTop + rel.nextBox + Math.round(fs * 1.3);
		rel.scoreValue = rel.scoreLabel + Math.round(fsBig * 1.1);
		rel.bestLabel = rel.scoreValue + Math.round(fs * 1.35);
		rel.rowH = Math.max(fs + 2, Math.round(fs * 1.4));
		rel.bestFirst = rel.bestLabel + Math.round(rel.rowH * 0.9);
		rel.bestLast = rel.bestFirst + rel.rowH * (MAX_SCORES - 1);
		rel.level = rel.bestLast + Math.round(rel.rowH * 1.2);
		rel.lines = rel.level + Math.round(fs * 1.4);
		rel.bottom = rel.lines + pad;

		panelHeight = Math.max(fieldHeight, rel.bottom);
		// The well sets the panel's height on a large window. Keep Level and Lines
		// at its foot so the extra depth reads as an empty margin, not as a page
		// that stopped halfway.
		rel.lines = panelHeight - pad;
		rel.level = rel.lines - Math.round(fs * 1.4);
		var boxW = fieldWidth + gap + panelWidth;
		var boxH = panelHeight;
		fieldLeft = Math.max(margin, Math.round((viewW - boxW) / 2));
		panelLeft = fieldLeft + fieldWidth + gap;
		panelTop = Math.max(margin, Math.round((viewH - boxH) / 2));
		fieldTop = panelTop + Math.round((boxH - fieldHeight) / 2);

		info = {
			pad: pad,
			next: panelTop + rel.next,
			nextBoxTop: panelTop + rel.nextBoxTop,
			nextBox: rel.nextBox,
			scoreLabel: panelTop + rel.scoreLabel,
			scoreValue: panelTop + rel.scoreValue,
			bestLabel: panelTop + rel.bestLabel,
			bestFirst: panelTop + rel.bestFirst,
			rowH: rel.rowH,
			level: panelTop + rel.level,
			lines: panelTop + rel.lines
		};
	}

	// --- block texture --------------------------------------------------------
	function makeSprite(colour, variant) {
		var size = block;
		var sprite = document.createElement('canvas');
		sprite.width = Math.max(1, Math.round(size * scale));
		sprite.height = sprite.width;
		var g = sprite.getContext('2d');
		if (!g) { return sprite; }
		g.setTransform(scale, 0, 0, scale, 0, 0);

		var pal = PALETTE[colour] || PALETTE.blue;
		var base = g.createLinearGradient(0, 0, size, size);
		base.addColorStop(0, pal.light);
		base.addColorStop(0.42, pal.base);
		base.addColorStop(1, pal.dark);
		g.fillStyle = base;
		g.fillRect(0, 0, size, size);

		// a soft gloss across the top, the way a polished tile catches light
		var gloss = g.createLinearGradient(0, 0, 0, size * 0.5);
		gloss.addColorStop(0, 'rgba(255,255,255,0.50)');
		gloss.addColorStop(1, 'rgba(255,255,255,0)');
		g.fillStyle = gloss;
		g.fillRect(size * 0.08, size * 0.06, size * 0.84, size * 0.44);

		// lit top and left faces
		var edge = Math.max(1, size * 0.07);
		g.strokeStyle = 'rgba(255,255,255,0.55)';
		g.lineWidth = edge;
		g.beginPath();
		g.moveTo(edge / 2, size - edge / 2);
		g.lineTo(edge / 2, edge / 2);
		g.lineTo(size - edge / 2, edge / 2);
		g.stroke();

		// shadowed bottom and right faces
		g.strokeStyle = 'rgba(0,0,0,0.32)';
		g.beginPath();
		g.moveTo(size - edge / 2, edge / 2);
		g.lineTo(size - edge / 2, size - edge / 2);
		g.lineTo(edge / 2, size - edge / 2);
		g.stroke();

		// grain: a few deterministic flecks, so neighbouring tiles do not match
		if (size >= 10) {
			var rnd = twirlSeed(colour.length * 131 + variant * 977 + Math.round(size));
			for (var i = 0; i < 7; i++) {
				var fx = size * (0.12 + rnd() * 0.76);
				var fy = size * (0.12 + rnd() * 0.76);
				var fw = Math.max(1, size * (0.03 + rnd() * 0.05));
				g.fillStyle = rnd() > 0.5 ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.10)';
				g.fillRect(fx, fy, fw, fw);
			}
		}

		// the dark outline that separates one cell from the next
		var line = Math.max(1, size * 0.055);
		g.strokeStyle = 'rgba(24,14,8,0.85)';
		g.lineWidth = line;
		g.strokeRect(line / 2, line / 2, size - line, size - line);
		return sprite;
	}

	function buildSprites() {
		sprites = {};
		for (var colour in PALETTE) {
			if (!PALETTE.hasOwnProperty(colour)) { continue; }
			var list = [];
			for (var v = 0; v < 4; v++) { list.push(makeSprite(colour, v)); }
			sprites[colour] = list;
		}
	}

	// --- static scene ---------------------------------------------------------
	function drawBrickWall(g) {
		g.fillStyle = '#d8c3a5'; // mortar
		g.fillRect(0, 0, viewW, viewH);
		var brickH = Math.max(14, Math.round(block * 0.55));
		var brickW = brickH * 2;
		var mortar = 2;
		var shades = ['#b5651d', '#a85a1a', '#c06a22', '#ad5f1e'];
		var rnd = twirlSeed(viewW * 7 + viewH * 13 + 41);
		var row = 0;
		for (var y = 0; y < viewH; y += brickH) {
			var offset = (row % 2) ? -brickW / 2 : 0;
			var col = 0;
			for (var x = offset; x < viewW; x += brickW) {
				g.fillStyle = shades[(row * 3 + col * 5) % shades.length];
				g.fillRect(x + mortar, y + mortar, brickW - mortar * 2, brickH - mortar * 2);
				g.fillStyle = 'rgba(255,255,255,0.10)';
				g.fillRect(x + mortar, y + mortar, brickW - mortar * 2, 1.5);
				g.fillStyle = 'rgba(0,0,0,0.14)';
				g.fillRect(x + mortar, y + brickH - mortar - 1.5, brickW - mortar * 2, 1.5);
				// a couple of pits per brick, so the wall reads as fired clay
				for (var k = 0; k < 2; k++) {
					var px = x + mortar + rnd() * Math.max(1, brickW - mortar * 2 - 3);
					var py = y + mortar + rnd() * Math.max(1, brickH - mortar * 2 - 3);
					g.fillStyle = rnd() > 0.4 ? 'rgba(0,0,0,0.10)' : 'rgba(255,240,210,0.10)';
					g.fillRect(px, py, 2, 1.5);
				}
				col++;
			}
			row++;
		}
		var vignette = g.createRadialGradient(viewW / 2, viewH / 2, Math.min(viewW, viewH) * 0.18,
			viewW / 2, viewH / 2, Math.max(viewW, viewH) * 0.72);
		vignette.addColorStop(0, 'rgba(0,0,0,0)');
		vignette.addColorStop(1, 'rgba(42,22,6,0.18)');
		g.fillStyle = vignette;
		g.fillRect(0, 0, viewW, viewH);
	}

	function drawWell(g) {
		var fill = g.createLinearGradient(0, fieldTop, 0, fieldTop + fieldHeight);
		fill.addColorStop(0, '#f6efdf');
		fill.addColorStop(1, '#e7dbc3');
		g.fillStyle = fill;
		g.fillRect(fieldLeft, fieldTop, fieldWidth, fieldHeight);

		g.strokeStyle = 'rgba(90,60,30,0.12)';
		g.lineWidth = 1;
		g.beginPath();
		for (var c = 1; c < COLS; c++) {
			var x = fieldLeft + c * block + 0.5;
			g.moveTo(x, fieldTop);
			g.lineTo(x, fieldTop + fieldHeight);
		}
		for (var r = 1; r < ROWS; r++) {
			var y = fieldTop + r * block + 0.5;
			g.moveTo(fieldLeft, y);
			g.lineTo(fieldLeft + fieldWidth, y);
		}
		g.stroke();

		// the lid's shadow falls into the top of the well
		var shade = g.createLinearGradient(0, fieldTop, 0, fieldTop + block);
		shade.addColorStop(0, 'rgba(0,0,0,0.16)');
		shade.addColorStop(1, 'rgba(0,0,0,0)');
		g.fillStyle = shade;
		g.fillRect(fieldLeft, fieldTop, fieldWidth, block);

		g.strokeStyle = 'rgba(20,12,6,0.55)';
		g.lineWidth = 2;
		g.strokeRect(fieldLeft - 1, fieldTop - 1, fieldWidth + 2, fieldHeight + 2);
	}

	function drawPanel(g) {
		g.fillStyle = '#f4efe6';
		g.fillRect(panelLeft, panelTop, panelWidth, panelHeight);
		g.strokeStyle = '#5b3a1e';
		g.lineWidth = 5;
		g.strokeRect(panelLeft, panelTop, panelWidth, panelHeight);
		g.strokeStyle = '#8a6a45';
		g.lineWidth = 2;
		g.strokeRect(panelLeft + 5, panelTop + 5, panelWidth - 10, panelHeight - 10);
		g.lineWidth = 1;

		// the Next well is sunk into the panel like a small window
		var nx = panelLeft + info.pad;
		var ny = info.nextBoxTop;
		g.fillStyle = 'rgba(90,60,30,0.10)';
		g.fillRect(nx, ny, info.nextBox, info.nextBox);
		g.strokeStyle = 'rgba(90,60,30,0.40)';
		g.strokeRect(nx + 0.5, ny + 0.5, info.nextBox, info.nextBox);
	}

	function buildBackground() {
		bgCanvas = document.createElement('canvas');
		bgCanvas.width = Math.max(1, Math.round(viewW * scale));
		bgCanvas.height = Math.max(1, Math.round(viewH * scale));
		var g = bgCanvas.getContext('2d');
		if (!g) {
			bgCanvas = null;
			return;
		}
		g.setTransform(scale, 0, 0, scale, 0, 0);
		drawBrickWall(g);
		drawWell(g);
		drawPanel(g);
	}

	function drawBlock(c, r, colour) {
		var list = sprites[colour] || sprites.blue;
		if (!list) { return; }
		var sprite = list[(r * 5 + c * 3) % list.length];
		ctx.drawImage(sprite, fieldLeft + c * block, fieldTop + r * block, block, block);
	}

	function drawNext() {
		var np = twirlPieces[twirlSpace.nextPiece];
		var cells = pieceCells(np.matrix);
		var b = filledBounds(np.matrix);
		var pw = (b.maxC - b.minC + 1) * block;
		var ph = (b.maxR - b.minR + 1) * block;
		var ox = panelLeft + info.pad + (info.nextBox - pw) / 2 - b.minC * block;
		var oy = info.nextBoxTop + (info.nextBox - ph) / 2 - b.minR * block;
		var list = sprites[np.colour] || sprites.blue;
		for (var i = 0; i < cells.length; i++) {
			ctx.drawImage(list[i % list.length], ox + cells[i][0] * block, oy + cells[i][1] * block, block, block);
		}
	}

	function drawPanelText() {
		var pad = info.pad;
		var left = panelLeft + pad;
		var right = panelLeft + panelWidth - pad;
		ctx.textAlign = 'left';
		ctx.textBaseline = 'alphabetic';
		ctx.fillStyle = '#2a1a10';

		ctx.font = fsHead + 'px arial';
		ctx.fillText('Next', left, info.next);
		drawNext();

		ctx.font = fs + 'px arial';
		ctx.fillText('Score', left, info.scoreLabel);
		ctx.font = fsBig + 'px arial';
		ctx.fillText(twirlSpace.score, left, info.scoreValue);

		ctx.font = fs + 'px arial';
		ctx.fillText('Best', left, info.bestLabel);
		for (var s = 0; s < MAX_SCORES; s++) {
			var entry = twirlSpace.scores[s];
			if (!entry) { continue; }
			var ry = info.bestFirst + s * info.rowH;
			ctx.font = (s === 0 ? 'bold ' : '') + fs + 'px arial';
			ctx.textAlign = 'left';
			ctx.fillText((s + 1) + '. ' + entry.initials, left, ry);
			ctx.textAlign = 'right';
			ctx.fillText(entry.score, right, ry);
		}
		ctx.textAlign = 'left';
		ctx.font = fs + 'px arial';
		ctx.fillText('Level ' + twirlSpace.level, left, info.level);
		ctx.fillText('Lines ' + twirlSpace.lines, left, info.lines);
	}

	function drawGameOver() {
		var cx = fieldLeft + fieldWidth / 2;
		var cy = fieldTop + fieldHeight / 2;
		var big = Math.max(14, Math.round(block * 0.85));
		var small = Math.max(11, Math.round(block * 0.62));
		ctx.save();
		ctx.fillStyle = 'rgba(0,0,0,0.72)';
		ctx.fillRect(fieldLeft, fieldTop, fieldWidth, fieldHeight);
		ctx.fillStyle = '#fff8ec';
		ctx.textAlign = 'center';
		ctx.textBaseline = 'alphabetic';
		ctx.font = big + 'px arial';
		ctx.fillText('Game Over', cx, cy - big * 2.2);
		ctx.font = small + 'px arial';
		ctx.fillText('Score ' + twirlSpace.score, cx, cy - big * 1.1);
		if (twirlSpace.scores.length && twirlSpace.scores[0].score == twirlSpace.score) {
			ctx.fillText('New high score!', cx, cy);
		}
		else {
			ctx.fillText('Best ' + twirlSpace.storedHigh + (twirlSpace.initials ? ' (' + twirlSpace.initials + ')' : ''), cx, cy);
		}
		ctx.fillText('Press Enter to play again', cx, cy + big * 1.5);
		ctx.fillText('Press C to clear high scores', cx, cy + big * 1.5 + small * 1.5);
		ctx.restore();
	}

	function drawPaused() {
		var cx = fieldLeft + fieldWidth / 2;
		var cy = fieldTop + fieldHeight / 2;
		ctx.save();
		ctx.fillStyle = 'rgba(0,0,0,0.6)';
		ctx.fillRect(fieldLeft, fieldTop, fieldWidth, fieldHeight);
		ctx.fillStyle = '#fff8ec';
		ctx.textAlign = 'center';
		ctx.font = Math.max(16, Math.round(block * 0.95)) + 'px arial';
		ctx.fillText('Paused', cx, cy);
		ctx.restore();
	}

	function render() {
		if (!viewW || !viewH) { return; }
		ctx.setTransform(1, 0, 0, 1, 0, 0);
		ctx.clearRect(0, 0, canvas.width, canvas.height);
		ctx.setTransform(scale, 0, 0, scale, 0, 0);
		if (bgCanvas) {
			ctx.drawImage(bgCanvas, 0, 0, viewW, viewH);
		}
		else {
			ctx.fillStyle = '#d8c3a5';
			ctx.fillRect(0, 0, viewW, viewH);
		}

		var r, c;
		for (r = 0; r < ROWS; r++) {
			for (c = 0; c < COLS; c++) {
				if (board[r][c]) { drawBlock(c, r, board[r][c]); }
			}
		}

		if (clearing) {
			// three quick flashes while the full rows are held in the well
			var t = clock() - clearing.start;
			if (Math.floor(t / 60) % 2 === 0) {
				ctx.fillStyle = 'rgba(255,255,255,0.82)';
				for (var i = 0; i < clearing.rows.length; i++) {
					ctx.fillRect(fieldLeft, fieldTop + clearing.rows[i] * block, fieldWidth, block);
				}
			}
		}
		else if (twirlSpace.current) {
			var p = twirlSpace.current;
			var cells = pieceCells(p.matrix);
			for (var j = 0; j < cells.length; j++) {
				var px = p.x + cells[j][0];
				var py = p.y + cells[j][1];
				if (py >= 0) { drawBlock(px, py, p.colour); }
			}
		}

		drawPanelText();

		if (twirlSpace.over) { drawGameOver(); }
		else if (twirlSpace.paused) { drawPaused(); }
	}

	// --- board helpers --------------------------------------------------------
	function makeBoard() {
		board = [];
		for (var r = 0; r < ROWS; r++) {
			board.push(new Array(COLS).fill(0));
		}
	}

	function sanitizeInitials(text) {
		var cleaned = String(text == null ? '' : text).toUpperCase().replace(/[^A-Z0-9]/g, '').substring(0, 3);
		return cleaned || 'YOU';
	}

	// Load the saved top-5 table, falling back to the old single high score.
	function loadScores() {
		var list = [];
		try {
			var raw = (typeof twirlHighScores !== 'undefined' && twirlHighScores) ? twirlHighScores : '[]';
			var parsed = JSON.parse(raw);
			if (Object.prototype.toString.call(parsed) === '[object Array]') { list = parsed; }
		}
		catch (err) { list = []; }
		list = list.filter(function (e) { return e && typeof e.score == 'number' && e.score > 0; })
			.map(function (e) { return { score: Math.floor(e.score), initials: sanitizeInitials(e.initials) }; })
			.sort(function (a, b) { return b.score - a.score; })
			.slice(0, MAX_SCORES);
		if (list.length == 0) {
			var legacyHigh = parseInt((typeof twirlHighScore !== 'undefined' ? twirlHighScore : 0), 10) || 0;
			var legacyInitials = (typeof twirlHighScoreInitials !== 'undefined' ? twirlHighScoreInitials : '') || '';
			if (legacyHigh > 0) { list.push({ score: legacyHigh, initials: sanitizeInitials(legacyInitials) }); }
		}
		return list;
	}

	// Keep the single "top" fields aligned with the best entry in the table.
	function syncTopScore() {
		if (twirlSpace.scores.length) {
			twirlSpace.storedHigh = twirlSpace.scores[0].score;
			twirlSpace.initials = twirlSpace.scores[0].initials;
		}
		else {
			twirlSpace.storedHigh = 0;
			twirlSpace.initials = '';
		}
	}

	function randomPieceIndex() {
		return Math.floor(Math.random() * twirlPieces.length);
	}

	function rotateMatrix(m) {
		var n = m.length;
		var out = [];
		for (var r = 0; r < n; r++) { out.push(new Array(n).fill(0)); }
		for (var r2 = 0; r2 < n; r2++) {
			for (var c = 0; c < n; c++) {
				out[c][n - 1 - r2] = m[r2][c];
			}
		}
		return out;
	}

	function rotateMatrixLeft(m) {
		var n = m.length;
		var out = [];
		for (var r = 0; r < n; r++) { out.push(new Array(n).fill(0)); }
		for (var r2 = 0; r2 < n; r2++) {
			for (var c = 0; c < n; c++) {
				out[n - 1 - c][r2] = m[r2][c];
			}
		}
		return out;
	}

	function pieceCells(matrix) {
		var cells = [];
		for (var r = 0; r < matrix.length; r++) {
			for (var c = 0; c < matrix[r].length; c++) {
				if (matrix[r][c]) { cells.push([c, r]); }
			}
		}
		return cells;
	}

	function filledBounds(matrix) {
		var cells = pieceCells(matrix);
		var b = { minC: COLS, maxC: 0, minR: ROWS, maxR: 0 };
		for (var i = 0; i < cells.length; i++) {
			b.minC = Math.min(b.minC, cells[i][0]);
			b.maxC = Math.max(b.maxC, cells[i][0]);
			b.minR = Math.min(b.minR, cells[i][1]);
			b.maxR = Math.max(b.maxR, cells[i][1]);
		}
		return b;
	}

	// A position is illegal if a cell is off the sides/bottom or lands on a filled cell.
	function collides(matrix, ox, oy) {
		var cells = pieceCells(matrix);
		for (var i = 0; i < cells.length; i++) {
			var x = ox + cells[i][0];
			var y = oy + cells[i][1];
			if (x < 0 || x >= COLS || y >= ROWS) { return true; }
			if (y >= 0 && board[y][x]) { return true; }
		}
		return false;
	}

	function spawn() {
		var idx = twirlSpace.nextPiece;
		twirlSpace.nextPiece = randomPieceIndex();
		var matrix = twirlPieces[idx].matrix.map(function (row) { return row.slice(); });
		var piece = {
			colour: twirlPieces[idx].colour,
			matrix: matrix,
			pivot: [twirlPieces[idx].pivot[0], twirlPieces[idx].pivot[1]],
			x: Math.floor((COLS - matrix[0].length) / 2),
			y: 0
		};
		if (collides(piece.matrix, piece.x, piece.y)) {
			twirlSpace.current = null;
			gameOver();
			return;
		}
		twirlSpace.current = piece;
	}

	function tryMove(dx, dy) {
		var p = twirlSpace.current;
		if (!p) { return false; }
		if (!collides(p.matrix, p.x + dx, p.y + dy)) {
			p.x += dx;
			p.y += dy;
			return true;
		}
		return false;
	}

	function sameMatrix(a, b) {
		for (var r = 0; r < a.length; r++) {
			for (var c = 0; c < a[r].length; c++) {
				if (a[r][c] != b[r][c]) { return false; }
			}
		}
		return true;
	}

	// Rotate while keeping a fixed pivot cell at the exact same spot, so the piece
	// never drifts sideways (integer maths, no rounding).
	function rotate() {
		var p = twirlSpace.current;
		if (!p) { return; }
		var rotated = rotateMatrix(p.matrix);
		if (sameMatrix(rotated, p.matrix)) { return; }
		var n = p.matrix.length;
		var pr = p.pivot[0], pc = p.pivot[1];
		var npr = pc, npc = n - 1 - pr;
		var nx = p.x + pc - npc;
		var ny = p.y + pr - npr;
		var kicks = [[0,0],[-1,0],[1,0],[-2,0],[2,0],[0,-1],[-1,-1],[1,-1]];
		for (var i = 0; i < kicks.length; i++) {
			if (!collides(rotated, nx + kicks[i][0], ny + kicks[i][1])) {
				p.matrix = rotated;
				p.x = nx + kicks[i][0];
				p.y = ny + kicks[i][1];
				p.pivot = [npr, npc];
				return;
			}
		}
	}

	// The same fixed-pivot turn the other way, for B.
	function rotateCounter() {
		var p = twirlSpace.current;
		if (!p) { return; }
		var rotated = rotateMatrixLeft(p.matrix);
		if (sameMatrix(rotated, p.matrix)) { return; }
		var n = p.matrix.length;
		var pr = p.pivot[0], pc = p.pivot[1];
		var npr = n - 1 - pc, npc = pr;
		var nx = p.x + pc - npc;
		var ny = p.y + pr - npr;
		var kicks = [[0,0],[-1,0],[1,0],[-2,0],[2,0],[0,-1],[-1,-1],[1,-1]];
		for (var i = 0; i < kicks.length; i++) {
			if (!collides(rotated, nx + kicks[i][0], ny + kicks[i][1])) {
				p.matrix = rotated;
				p.x = nx + kicks[i][0];
				p.y = ny + kicks[i][1];
				p.pivot = [npr, npc];
				return;
			}
		}
	}

	function fullRows() {
		var rows = [];
		for (var r = 0; r < ROWS; r++) {
			var full = true;
			for (var c = 0; c < COLS; c++) {
				if (!board[r][c]) { full = false; break; }
			}
			if (full) { rows.push(r); }
		}
		return rows;
	}

	function removeRows(rows) {
		var drop = {};
		for (var i = 0; i < rows.length; i++) { drop[rows[i]] = true; }
		var kept = [];
		for (var r = 0; r < ROWS; r++) {
			if (!drop[r]) { kept.push(board[r]); }
		}
		while (kept.length < ROWS) { kept.unshift(new Array(COLS).fill(0)); }
		board = kept;
		var cleared = rows.length;
		twirlSpace.lines += cleared;
		var table = [0, 100, 300, 500, 800];
		twirlSpace.score += (table[cleared] || 0) * twirlSpace.level;
		updateLevel();
	}

	function updateLevel() {
		var level = Math.floor(twirlSpace.lines / 10) + 1;
		if (level != twirlSpace.level) {
			twirlSpace.level = level;
			twirlSpace.speed = Math.max(MIN_SPEED, BASE_SPEED - (level - 1) * LEVEL_STEP);
		}
	}

	// Write the current piece into the board. Full rows are held for the flash and
	// cleared by finishClear() a few frames later; otherwise the next shape spawns
	// at once, the way the interval version did.
	function lockPiece() {
		var p = twirlSpace.current;
		if (!p) { return; }
		var cells = pieceCells(p.matrix);
		for (var i = 0; i < cells.length; i++) {
			var x = p.x + cells[i][0];
			var y = p.y + cells[i][1];
			if (y >= 0 && y < ROWS && x >= 0 && x < COLS && !board[y][x]) {
				board[y][x] = p.colour;
			}
		}
		twirlSpace.current = null;
		acc = 0;
		var rows = fullRows();
		if (rows.length) {
			var t = clock();
			clearing = { rows: rows, start: t, end: t + FLASH_MS };
		}
		else {
			spawn();
		}
		needsDraw = true;
	}

	function finishClear() {
		if (!clearing) { return; }
		var rows = clearing.rows;
		clearing = null;
		removeRows(rows);
		acc = 0;
		spawn();
		needsDraw = true;
	}

	function softDrop(award) {
		if (!twirlSpace.current) { return false; }
		if (tryMove(0, 1)) {
			if (award) { twirlSpace.score += 1; }
			needsDraw = true;
			return true;
		}
		lockPiece();
		return false;
	}

	function hardDrop() {
		if (!twirlSpace.current) { return; }
		var dropped = 0;
		while (tryMove(0, 1)) { dropped++; }
		twirlSpace.score += dropped * 2;
		lockPiece();
		needsDraw = true;
	}

	// --- controls -------------------------------------------------------------
	function action(command) {
		if (twirlSpace.paused || twirlSpace.over || clearing || !twirlSpace.current) { return; }
		if (command == 'left') {
			tryMove(-1, 0);
		}
		else if (command == 'right') {
			tryMove(1, 0);
		}
		else if (command == 'down') {
			softDrop(true);
			return;
		}
		else if (command == 'rotate') {
			rotate();
		}
		else if (command == 'rotate_left') {
			rotateCounter();
		}
		else if (command == 'drop') {
			hardDrop();
			return;
		}
		needsDraw = true;
	}

	function press(cmd) {
		if (!cmd || held[cmd]) { return; }
		if (twirlSpace.paused || twirlSpace.over) { return; }
		held[cmd] = true;
		var t = clock();
		if (cmd === 'left' || cmd === 'right') {
			lastDir = cmd;
			repeatAt = t + DAS_DELAY;
		}
		else if (cmd === 'down') {
			downAt = t + DAS_DELAY;
		}
		action(cmd);
	}

	function release(cmd) {
		if (!cmd || !held[cmd]) { return; }
		held[cmd] = false;
		if ((cmd === 'left' || cmd === 'right') && lastDir === cmd) {
			lastDir = held.right ? 'right' : (held.left ? 'left' : null);
			if (lastDir) { repeatAt = clock() + DAS_DELAY; }
		}
	}

	function releaseAll() {
		held = {};
		lastDir = null;
	}

	function pauseGame() {
		if (twirlSpace.over) { return; }
		twirlSpace.paused = !twirlSpace.paused;
		held = {};
		lastDir = null;
		if (twirlSpace.paused) {
			pausedAt = clock();
		}
		else {
			var t = clock();
			lastTime = t;
			if (clearing) {
				var shift = t - pausedAt;
				clearing.start += shift;
				clearing.end += shift;
			}
		}
		needsDraw = true;
	}

	// --- one loop ---------------------------------------------------------------
	function step(t, dt) {
		if (twirlSpace.paused || twirlSpace.over) { return; }
		if (clearing) {
			needsDraw = true;
			if (t >= clearing.end) { finishClear(); }
			return;
		}
		if (!twirlSpace.current) { return; }

		if (held.left || held.right) {
			var dir = lastDir || (held.right ? 'right' : 'left');
			if (t >= repeatAt) {
				repeatAt = t + DAS_REPEAT;
				action(dir);
			}
		}

		if (held.down) {
			if (t >= downAt) {
				downAt = t + SOFT_REPEAT;
				softDrop(true);
			}
			return;
		}

		acc += dt;
		var guard = 0;
		while (acc >= twirlSpace.speed && guard < ROWS * 2 && twirlSpace.current && !clearing && !twirlSpace.over) {
			acc -= twirlSpace.speed;
			softDrop(false);
			guard++;
		}
		// a long stall (a dragged window, a throttled tab) must not cascade rows
		if (acc > twirlSpace.speed * 2) { acc = 0; }
	}

	function frame(t) {
		rafId = null;
		if (destroyed) { return; }
		if (!isAttached()) { destroy(); return; }
		if (!isOnScreen()) {
			lastTime = t;
			requestFrame();
			return;
		}
		if (!viewW || !viewH) {
			relayout();
			if (!viewW || !viewH) {
				lastTime = t;
				requestFrame();
				return;
			}
		}
		var dt = t - lastTime;
		if (!(dt >= 0)) { dt = 0; }
		if (dt > 250) { dt = 250; }
		lastTime = t;
		step(t, dt);
		if (needsDraw) {
			needsDraw = false;
			render();
		}
		requestFrame();
	}

	function requestFrame() {
		if (destroyed || rafId != null) { return; }
		if (window.requestAnimationFrame) {
			rafId = window.requestAnimationFrame(frame);
		}
		else {
			rafId = window.setTimeout(function () { frame(clock()); }, 16);
		}
	}

	// --- sizing ---------------------------------------------------------------
	function relayout() {
		if (destroyed) { return; }
		var w = canvas.clientWidth;
		var h = canvas.clientHeight;
		if (!w || !h) { return; }
		var s = Math.min(Math.max(window.devicePixelRatio || 1, 1), 2);
		if (w === viewW && h === viewH && s === scale) { return; }
		viewW = w;
		viewH = h;
		scale = s;
		canvas.width = Math.max(1, Math.round(w * s));
		canvas.height = Math.max(1, Math.round(h * s));
		computeLayout();
		buildSprites();
		buildBackground();
		needsDraw = true;
		render();
	}

	function isAttached() {
		if (!canvas) { return false; }
		if (typeof canvas.isConnected === 'boolean') { return canvas.isConnected; }
		return document.documentElement.contains(canvas);
	}

	function isOnScreen() {
		if (!isAttached()) { return false; }
		if (!canvas.clientWidth || !canvas.clientHeight) { return false; }
		return canvas.getClientRects().length > 0;
	}

	// --- lifecycle ------------------------------------------------------------
	function newGame() {
		makeBoard();
		held = {};
		lastDir = null;
		clearing = null;
		acc = 0;
		twirlSpace.score = 0;
		twirlSpace.lines = 0;
		twirlSpace.level = 1;
		twirlSpace.speed = BASE_SPEED;
		twirlSpace.paused = false;
		twirlSpace.over = false;
		twirlSpace.nextPiece = randomPieceIndex();
		spawn();
		lastTime = clock();
		needsDraw = true;
	}

	function destroy() {
		if (destroyed) { return; }
		destroyed = true;
		if (rafId != null) {
			if (window.cancelAnimationFrame) { window.cancelAnimationFrame(rafId); }
			else { window.clearTimeout(rafId); }
			rafId = null;
		}
		if (observer) {
			try { observer.disconnect(); } catch (err) {}
			observer = null;
		}
		if (fallbackResize) {
			$(window).off('resize', fallbackResize);
			fallbackResize = null;
		}
		held = {};
		clearing = null;
		if (twirlControls === controls) { twirlControls = null; }
		if (twirlInstance === instance) { twirlInstance = null; }
		twirlRunning = false;
	}

	// --- high scores ------------------------------------------------------------
	function saveScores() {
		settingSetter({ app: 'twirl', setting: 'high_scores', value: JSON.stringify(twirlSpace.scores) });
		// Keep the legacy single-score settings in sync for other readers.
		settingSetter({ app: 'twirl', setting: 'high_score', value: twirlSpace.storedHigh });
		settingSetter({ app: 'twirl', setting: 'high_score_initials', value: twirlSpace.initials });
	}

	function qualifies(score) {
		if (score <= 0) { return false; }
		if (twirlSpace.scores.length < MAX_SCORES) { return true; }
		return score > twirlSpace.scores[twirlSpace.scores.length - 1].score;
	}

	function insertScore(score, initials) {
		twirlSpace.scores.push({ score: score, initials: initials });
		twirlSpace.scores.sort(function (a, b) { return b.score - a.score; });
		twirlSpace.scores = twirlSpace.scores.slice(0, MAX_SCORES);
		syncTopScore();
		saveScores();
	}

	function clearScores() {
		jawnosConfirm('Clear all Twirl high scores?', function () {
			twirlSpace.scores = [];
			syncTopScore();
			saveScores();
			needsDraw = true;
		});
	}

	function gameOver() {
		twirlSpace.over = true;
		held = {};
		lastDir = null;
		acc = 0;
		needsDraw = true;

		if (qualifies(twirlSpace.score)) {
			var scored = twirlSpace.score;
			var record = function (initials) {
				insertScore(scored, sanitizeInitials(initials));
				needsDraw = true;
			};
			jawnosPrompt('You made the top ' + MAX_SCORES + '!\nScore: ' + scored + '\nEnter your initials (up to 3 letters):', twirlSpace.initials || '', record, {
				// a cancelled entry still stands as YOU, as the native prompt did
				on_cancel: function () { record(null); }
			});
		}
	}

	// --- start ------------------------------------------------------------------
	twirlSpace.scores = loadScores();
	syncTopScore();
	makeBoard();

	controls = {
		action: action,
		press: press,
		release: release,
		releaseAll: releaseAll,
		pause: pauseGame,
		clearScores: clearScores,
		isOver: function () { return twirlSpace.over; },
		restart: function () { newGame(); }
	};
	instance = { destroy: destroy };
	twirlControls = controls;

	twirlBindKeys();
	newGame();

	if (typeof ResizeObserver === 'function') {
		observer = new ResizeObserver(function () { relayout(); });
		observer.observe(canvas);
	}
	else {
		fallbackResize = function () { relayout(); };
		$(window).on('resize', fallbackResize);
	}

	relayout();
	requestFrame();
	return instance;
}

// Bound once for the page. The handlers read the global twirlControls, so a
// reopened window swaps in fresh state without stacking a second listener.
function twirlBindKeys() {
	if (twirlKeysBound) { return; }
	twirlKeysBound = true;

	function active() {
		return twirlControls && typeof topWindow === 'function' && topWindow() == 'twirl';
	}

	$(document).on('keydown', function (e) {
		if (!active()) { return; }
		twirlPlayTouch();
		var cmd = twirlKeyCommand(e.keyCode);
		if (cmd) {
			e.preventDefault();
			twirlControls.press(cmd);
			return;
		}
		if (e.keyCode == 27) {
			e.preventDefault();
			twirlControls.pause();
			if (typeof jawnosGameSessionPause === 'function') { jawnosGameSessionPause(); }
		}
		else if (e.keyCode == 67) {
			e.preventDefault();
			twirlControls.clearScores();
		}
		else if (e.keyCode == 13 && twirlControls.isOver()) {
			e.preventDefault();
			twirlControls.restart();
		}
	});

	$(document).on('keyup', function (e) {
		var cmd = twirlKeyCommand(e.keyCode);
		if (cmd && twirlControls) { twirlControls.release(cmd); }
	});

	/* A is the left click (the input daemon maps BTN_EAST to BTN_LEFT), so a
	   plain press on the well turns the piece clockwise; B arrives as F13 and
	   turns it back. */
	$(document).on('mousedown', '#twirl', function (e) {
		if (!active() || (e.which && e.which !== 1)) { return; }
		twirlPlayTouch();
		e.preventDefault();
		twirlControls.action('rotate');
	});

	$(window).on('blur', function () {
		if (twirlControls) { twirlControls.releaseAll(); }
	});
}

twirlGame();
