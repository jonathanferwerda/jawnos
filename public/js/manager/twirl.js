var twirlRunning = false;
var twirlKeysBound = false;
var twirlControls = null;
var twirlHeld = {};
var twirlDas = null;
var twirlRepeat = null;
var twirlDasDelay = 150;   // pause after first move before auto-repeat begins
var twirlRepeatDelay = 50; // gap between repeated moves while a key is held

function twirlKeyCommand(code) {
	if (code == 37) { return 'left'; }
	if (code == 39) { return 'right'; }
	if (code == 40) { return 'down'; }
	if (code == 38) { return 'rotate'; }
	if (code == 32) { return 'drop'; }
	return null;
}

function twirlStartRepeat() {
	if (twirlDas) { clearTimeout(twirlDas); twirlDas = null; }
	if (twirlRepeat) { clearInterval(twirlRepeat); twirlRepeat = null; }
	twirlDas = setTimeout(function () {
		twirlDas = null;
		twirlRepeat = setInterval(twirlRepeatStep, twirlRepeatDelay);
	}, twirlDasDelay);
}

function twirlStopRepeat() {
	if (twirlDas) { clearTimeout(twirlDas); twirlDas = null; }
	if (twirlRepeat) { clearInterval(twirlRepeat); twirlRepeat = null; }
}

function twirlRepeatStep() {
	if (!twirlControls) { return; }
	if (twirlHeld['left']) { twirlControls.action('left'); }
	else if (twirlHeld['right']) { twirlControls.action('right'); }
	else if (twirlHeld['down']) { twirlControls.action('down'); }
	else {
		clearInterval(twirlRepeat);
		twirlRepeat = null;
	}
}

function twirlGame() {
	var canvas = document.getElementById('twirl');
	if (!canvas || !$('#twirl').is(':visible') || twirlRunning == true) {
		return;
	}
	twirlRunning = true;

	var win = $('#twirl').closest('.wind');
	canvas.height = win.height();
	canvas.width = win.width();
	var twirlctx = canvas.getContext('2d');

	var COLS = 10;
	var ROWS = 20;

	// --- layout (recomputed on resize) ---
	var block;
	var fieldLeft = 20;
	var fieldTop = 35;
	var fieldWidth;
	var fieldHeight;
	var panelLeft;

	function computeLayout() {
		block = Math.floor(Math.min((canvas.width * 0.58) / COLS, (canvas.height - 110) / ROWS));
		block = Math.max(block, 8);
		fieldWidth = block * COLS;
		fieldHeight = block * ROWS;
		panelLeft = fieldLeft + fieldWidth + 30;
	}
	computeLayout();

	// --- tetrominoes ---
	var twirlPieces = [
		{ name: 'straight',   colour: 'red',        pivot: [0,1], matrix: [[1,1,1,1],[0,0,0,0],[0,0,0,0],[0,0,0,0]] },
		{ name: 'cube',       colour: 'blue',       pivot: [0,0], matrix: [[1,1],[1,1]] },
		{ name: 'left_curl',  colour: 'green',      pivot: [1,1], matrix: [[1,0,0],[1,1,1],[0,0,0]] },
		{ name: 'right_curl', colour: 'yellow',     pivot: [1,1], matrix: [[0,0,1],[1,1,1],[0,0,0]] },
		{ name: 'crown',      colour: 'orange',     pivot: [1,1], matrix: [[0,1,0],[1,1,1],[0,0,0]] },
		{ name: 'lstep',      colour: 'lightgreen', pivot: [1,1], matrix: [[0,1,1],[1,1,0],[0,0,0]] },
		{ name: 'rstep',      colour: 'lightblue',  pivot: [1,1], matrix: [[1,1,0],[0,1,1],[0,0,0]] }
	];

	var MAX_SCORES = 5;

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

	var board = [];
	function makeBoard() {
		board = [];
		for (var r = 0; r < ROWS; r++) {
			board.push(new Array(COLS).fill(0));
		}
	}
	makeBoard();

	var twirlSpace = {
		score: 0,
		lines: 0,
		level: 1,
		baseSpeed: 800,
		step: 70,
		minSpeed: 90,
		speed: 800,
		highScore: 0,
		storedHigh: 0,
		initials: '',
		scores: loadScores(),
		paused: false,
		over: false,
		nextPiece: 0,
		current: null
	};

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
		twirlSpace.highScore = twirlSpace.storedHigh;
	}
	syncTopScore();

	var dropper;
	var resizer;

	// --- helpers ---
	function randomPieceIndex() {
		return Math.floor(Math.random() * twirlPieces.length);
	}

	function rotateMatrix(m) {
		var n = m.length;
		var out = [];
		for (var r = 0; r < n; r++) { out.push(new Array(n).fill(0)); }
		for (var r = 0; r < n; r++) {
			for (var c = 0; c < n; c++) {
				out[c][n - 1 - r] = m[r][c];
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

	// Write the current piece into the board, then clear lines and spawn the next.
	function lock() {
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
		var rows = fullRows();
		if (rows.length == 0) {
			spawn();
			draw();
			return;
		}
		clearInterval(dropper);
		flashRows(rows, function () {
			removeRows(rows);
			draw();
			setTimeout(function () {
				if (twirlSpace.over) { return; }
				spawn();
				draw();
				startGravity();
			}, 200);
		});
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

	function flashRows(rows, done) {
		var flashes = 3;
		var toggles = 0;
		var lit = true;
		function paint() {
			draw();
			if (lit) {
				twirlctx.fillStyle = 'white';
				for (var i = 0; i < rows.length; i++) {
					twirlctx.fillRect(fieldLeft, fieldTop + rows[i] * block, fieldWidth, block);
				}
			}
			lit = !lit;
		}
		paint();
		var flasher = setInterval(function () {
			toggles++;
			paint();
			if (toggles >= flashes * 2) {
				clearInterval(flasher);
				done();
			}
		}, 55);
	}

	function updateLevel() {
		var level = Math.floor(twirlSpace.lines / 10) + 1;
		if (level != twirlSpace.level) {
			twirlSpace.level = level;
			twirlSpace.speed = Math.max(twirlSpace.minSpeed, twirlSpace.baseSpeed - (level - 1) * twirlSpace.step);
			startGravity();
		}
	}

	// --- gravity ---
	function startGravity() {
		clearInterval(dropper);
		if (twirlSpace.paused || twirlSpace.over) { return; }
		dropper = setInterval(gravityTick, twirlSpace.speed);
	}

	function gravityTick() {
		if (!$('#twirl').is(':visible')) { stopGame(); return; }
		if (twirlSpace.paused || twirlSpace.over) { return; }
		if (!tryMove(0, 1)) {
			lock();
		}
		else {
			draw();
		}
	}

	function stopGame() {
		clearInterval(dropper);
		clearInterval(resizer);
		twirlStopRepeat();
		twirlHeld = {};
		twirlRunning = false;
	}

	// --- resize ---
	function resize() {
		var w = Math.floor(win.width());
		var h = Math.floor(win.height());
		if (w <= 0 || h <= 0) { return; }
		if (w == canvas.width && h == canvas.height) { return; }
		canvas.width = w;
		canvas.height = h;
		computeLayout();
		draw();
	}

	function watchResize() {
		clearInterval(resizer);
		resizer = setInterval(function () {
			if (!$('#twirl').is(':visible')) { clearInterval(resizer); return; }
			resize();
		}, 250);
	}

	// --- drawing ---
	function drawBackground() {
		twirlctx.fillStyle = '#d8c3a5'; // mortar
		twirlctx.fillRect(0, 0, canvas.width, canvas.height);
		var brickH = Math.max(14, Math.round(block * 0.55));
		var brickW = brickH * 2;
		var gap = 2;
		var shades = ['#b5651d', '#a85a1a', '#c06a22'];
		var row = 0;
		for (var y = 0; y < canvas.height; y += brickH) {
			var offset = (row % 2) ? -brickW / 2 : 0;
			var col = 0;
			for (var x = offset; x < canvas.width; x += brickW) {
				twirlctx.fillStyle = shades[(row + col) % shades.length];
				twirlctx.fillRect(x + gap, y + gap, brickW - gap * 2, brickH - gap * 2);
				col++;
			}
			row++;
		}
	}

	function drawWindow(x, y, w, h) {
		twirlctx.fillStyle = '#f4efe6';
		twirlctx.fillRect(x, y, w, h);
		twirlctx.strokeStyle = '#5b3a1e';
		twirlctx.lineWidth = 5;
		twirlctx.strokeRect(x, y, w, h);
		twirlctx.lineWidth = 2;
		twirlctx.strokeStyle = '#8a6a45';
		twirlctx.strokeRect(x + 5, y + 5, w - 10, h - 10);
		twirlctx.lineWidth = 1;
	}

	function drawBlockPx(px, py, size, colour) {
		var lw = Math.max(1, Math.round(size * 0.06));
		twirlctx.fillStyle = colour;
		twirlctx.fillRect(px, py, size, size);
		twirlctx.strokeStyle = 'black';
		twirlctx.lineWidth = lw;
		twirlctx.strokeRect(px + lw / 2, py + lw / 2, size - lw, size - lw);
		twirlctx.lineWidth = 1;
	}

	function drawCell(c, r, colour) {
		drawBlockPx(fieldLeft + c * block, fieldTop + r * block, block, colour);
	}

	function drawNext(x, y, w, h) {
		var np = twirlPieces[twirlSpace.nextPiece];
		var cells = pieceCells(np.matrix);
		var b = filledBounds(np.matrix);
		twirlctx.strokeStyle = '#8a6a45';
		twirlctx.lineWidth = 1;
		twirlctx.strokeRect(x + 0.5, y + 0.5, w, h);
		var pw = (b.maxC - b.minC + 1) * block;
		var ph = (b.maxR - b.minR + 1) * block;
		var ox = x + (w - pw) / 2 - b.minC * block;
		var oy = y + (h - ph) / 2 - b.minR * block;
		for (var j = 0; j < cells.length; j++) {
			drawBlockPx(ox + cells[j][0] * block, oy + cells[j][1] * block, block, np.colour);
		}
	}

	function drawOverlay(text) {
		twirlctx.fillStyle = 'rgba(0,0,0,0.6)';
		twirlctx.fillRect(fieldLeft, fieldTop, fieldWidth, fieldHeight);
		twirlctx.fillStyle = 'white';
		twirlctx.font = '24px arial';
		twirlctx.fillText(text, fieldLeft + (fieldWidth - twirlctx.measureText(text).width) / 2, fieldTop + fieldHeight / 2);
	}

	function drawGameOver() {
		twirlctx.fillStyle = 'rgba(0,0,0,0.7)';
		twirlctx.fillRect(fieldLeft, fieldTop, fieldWidth, fieldHeight);
		twirlctx.fillStyle = 'white';
		twirlctx.textAlign = 'center';
		var cx = fieldLeft + fieldWidth / 2;
		var cy = fieldTop + fieldHeight / 2;
		twirlctx.font = '24px arial';
		twirlctx.fillText('Game Over', cx, cy - 60);
		twirlctx.font = '18px arial';
		twirlctx.fillText('Score ' + twirlSpace.score, cx, cy - 26);
		twirlctx.font = '16px arial';
		if (twirlSpace.scores.length && twirlSpace.scores[0].score == twirlSpace.score) {
			twirlctx.fillText('New high score!', cx, cy + 4);
		}
		else {
			twirlctx.fillText('Best ' + twirlSpace.storedHigh + (twirlSpace.initials ? ' (' + twirlSpace.initials + ')' : ''), cx, cy + 4);
		}
		twirlctx.fillText('Press Enter to play again', cx, cy + 40);
		twirlctx.fillText('Press C to clear high scores', cx, cy + 64);
		twirlctx.textAlign = 'left';
	}

	function draw() {
		twirlctx.clearRect(0, 0, canvas.width, canvas.height);
		drawBackground();

		// play field
		twirlctx.fillStyle = 'beige';
		twirlctx.fillRect(fieldLeft, fieldTop, fieldWidth, fieldHeight);
		for (var r = 0; r < ROWS; r++) {
			for (var c = 0; c < COLS; c++) {
				if (board[r][c]) { drawCell(c, r, board[r][c]); }
			}
		}
		var p = twirlSpace.current;
		if (p) {
			var cells = pieceCells(p.matrix);
			for (var i = 0; i < cells.length; i++) {
				var x = p.x + cells[i][0];
				var y = p.y + cells[i][1];
				if (y >= 0) { drawCell(x, y, p.colour); }
			}
		}
		twirlctx.strokeStyle = 'black';
		twirlctx.lineWidth = 2;
		twirlctx.strokeRect(fieldLeft - 1, fieldTop - 1, fieldWidth + 2, fieldHeight + 2);
		twirlctx.lineWidth = 1;

		// information window set into the brick wall
		var nextBox = block * 4;
		var winX = panelLeft - 15;
		var winY = fieldTop - 5;
		var winW = nextBox + 30;
		var winH = Math.max(fieldHeight + 10, nextBox + 250 + MAX_SCORES * 22);
		drawWindow(winX, winY, winW, winH);

		twirlctx.fillStyle = 'black';
		twirlctx.font = '22px arial';
		twirlctx.fillText('Next', winX + 15, winY + 30);
		drawNext(winX + 15, winY + 42, nextBox, nextBox);

		var ty = winY + 42 + nextBox + 34;
		twirlctx.fillStyle = 'black';
		twirlctx.font = '16px arial';
		twirlctx.fillText('Score', winX + 15, ty);
		twirlctx.font = '22px arial';
		twirlctx.fillText(twirlSpace.score, winX + 15, ty + 24);

		ty += 60;
		twirlctx.font = '16px arial';
		twirlctx.fillText('Best', winX + 15, ty);
		for (var s = 0; s < MAX_SCORES; s++) {
			var entry = twirlSpace.scores[s];
			if (!entry) { continue; }
			var ry = ty + 22 * (s + 1);
			twirlctx.font = (s == 0 ? 'bold 16px arial' : '16px arial');
			twirlctx.fillText((s + 1) + '. ' + entry.initials, winX + 15, ry);
			twirlctx.textAlign = 'right';
			twirlctx.fillText(entry.score, winX + winW - 15, ry);
			twirlctx.textAlign = 'left';
		}

		ty += 22 * MAX_SCORES + 30;
		twirlctx.font = '16px arial';
		twirlctx.fillText('Level ' + twirlSpace.level, winX + 15, ty);
		twirlctx.fillText('Lines ' + twirlSpace.lines, winX + 15, ty + 24);

		if (twirlSpace.over) {
			drawGameOver();
		}
		else if (twirlSpace.paused) {
			drawOverlay('Paused');
		}
	}

	// --- controls ---
	function action(command) {
		if (twirlSpace.paused || twirlSpace.over || !twirlSpace.current) { return; }
		if (command == 'left') {
			tryMove(-1, 0);
		}
		else if (command == 'right') {
			tryMove(1, 0);
		}
		else if (command == 'down') {
			if (tryMove(0, 1)) {
				twirlSpace.score += 1;
				draw();
			}
			else {
				lock();
			}
			return;
		}
		else if (command == 'rotate') {
			rotate();
		}
		else if (command == 'drop') {
			var dropped = 0;
			while (tryMove(0, 1)) { dropped++; }
			twirlSpace.score += dropped * 2;
			lock();
			return;
		}
		draw();
	}

	function pauseGame() {
		if (twirlSpace.over) { return; }
		twirlSpace.paused = !twirlSpace.paused;
		if (!twirlSpace.paused) { startGravity(); }
		else { clearInterval(dropper); }
		draw();
	}

	// --- high scores ---
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
		if (!confirm('Clear all Twirl high scores?')) { return; }
		twirlSpace.scores = [];
		syncTopScore();
		saveScores();
		draw();
	}

	// --- game over ---
	function gameOver() {
		twirlSpace.over = true;
		clearInterval(dropper);

		if (qualifies(twirlSpace.score)) {
			var initials = prompt('You made the top ' + MAX_SCORES + '!\nScore: ' + twirlSpace.score + '\nEnter your initials (up to 3 letters):', twirlSpace.initials || '');
			insertScore(twirlSpace.score, sanitizeInitials(initials));
		}

		draw();
	}

	// --- lifecycle ---
	function newGame() {
		makeBoard();
		twirlHeld = {};
		twirlSpace.score = 0;
		twirlSpace.lines = 0;
		twirlSpace.level = 1;
		twirlSpace.speed = twirlSpace.baseSpeed;
		twirlSpace.paused = false;
		twirlSpace.over = false;
		twirlSpace.highScore = twirlSpace.storedHigh;
		twirlSpace.nextPiece = randomPieceIndex();
		spawn();
		draw();
		startGravity();
	}

	if (!twirlKeysBound) {
		twirlKeysBound = true;

		function activeGame() {
			return (typeof topWindow === 'function' && topWindow() == 'twirl' && twirlControls);
		}

		$(document).on('keydown', function (e) {
			if (!activeGame()) { return; }
			var cmd = twirlKeyCommand(e.keyCode);
			if (cmd == 'left' || cmd == 'right' || cmd == 'down') {
				e.preventDefault();
				if (!twirlHeld[cmd]) {
					twirlHeld[cmd] = true;
					twirlControls.action(cmd);
					twirlStartRepeat();
				}
			}
			else if (cmd == 'rotate' || cmd == 'drop') {
				e.preventDefault();
				if (!twirlHeld[cmd]) {
					twirlHeld[cmd] = true;
					twirlControls.action(cmd);
				}
			}
			else if (e.keyCode == 27) {
				e.preventDefault();
				twirlControls.pause();
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
			if (cmd) { twirlHeld[cmd] = false; }
			if (!twirlHeld['left'] && !twirlHeld['right'] && !twirlHeld['down']) {
				twirlStopRepeat();
			}
		});

		$(window).on('blur', function () {
			twirlHeld = {};
			twirlStopRepeat();
		});
	}

	twirlControls = {
		action: action,
		pause: pauseGame,
		clearScores: clearScores,
		isOver: function () { return twirlSpace.over; },
		restart: function () { clearInterval(dropper); newGame(); }
	};

	newGame();
	watchResize();
}

twirlGame();
