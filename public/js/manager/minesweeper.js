// Minesweeper: the field is laid on the first reveal, so the first click is
// always safe and opens a pocket; the clock is the page's own, the play
// appointment belongs to game_session.js.
//
// The rules are plain data and plain functions, so a test can load this file in
// a bare context with no document and play the field out.
//
// State shape:
//   {
//     cols, rows, mines,        // the field's shape and mine count
//     seed,                     // the seeded xorshift state; placement reads it
//     placed,                   // false until the first reveal lays the mines
//     cells: [ { mine, adj, revealed, flagged }, ... ],   // row-major, y*cols+x
//     revealed,                 // how many non-mine cells are open
//     flags,                    // how many cells are flagged
//     status: 'ready' | 'playing' | 'won' | 'lost',
//     exploded                  // index of the mine that ended the game, or -1
//   }
function minesweeperNewState(cols, rows, mines, seed) {
	cols = Math.floor(cols || 0);
	rows = Math.floor(rows || 0);
	if (!(cols > 0)) { cols = 9; }
	if (!(rows > 0)) { rows = 9; }
	cols = Math.max(2, Math.min(40, cols));
	rows = Math.max(2, Math.min(40, rows));
	var total = cols * rows;
	mines = Math.floor(mines || 0);
	if (!(mines > 0)) { mines = 10; }
	mines = Math.max(1, Math.min(total - 1, mines));
	if (seed === undefined || seed === null) {
		seed = (((Date.now() & 0x7fffffff) ^ Math.floor(Math.random() * 0x7fffffff)) >>> 0);
	}
	seed = seed >>> 0;
	if (!seed) { seed = 0x9e3779b9; }
	var cells = new Array(total);
	for (var i = 0; i < total; i++) {
		cells[i] = { mine: false, adj: 0, revealed: false, flagged: false };
	}
	return {
		cols: cols,
		rows: rows,
		mines: mines,
		seed: seed,
		placed: false,
		cells: cells,
		revealed: 0,
		flags: 0,
		status: 'ready',
		exploded: -1
	};
}

function minesweeperCell(state, x, y) {
	if (!state) { return null; }
	x = Math.floor(x);
	y = Math.floor(y);
	if (x < 0 || y < 0 || x >= state.cols || y >= state.rows) { return null; }
	return state.cells[y * state.cols + x];
}

// A tiny xorshift32. The state carries the word, so the same seed and the same
// first click lay the same field twice.
function minesweeperRand(state) {
	var x = state.seed >>> 0;
	x ^= x << 13; x >>>= 0;
	x ^= x >>> 17;
	x ^= x << 5; x >>>= 0;
	if (!x) { x = 0x9e3779b9; }
	state.seed = x;
	return x / 4294967296;
}

// Lay the mines after the first click. The clicked square and its eight
// neighbours are left out when the field is big enough, which is what makes a
// first click open a zero region rather than a field of numbers. A field too
// small for that still protects the clicked square.
function minesweeperPlaceMines(state, safeX, safeY) {
	var total = state.cols * state.rows;
	var pool = [];
	var x, y, i;
	if (total - 9 >= state.mines) {
		for (y = 0; y < state.rows; y++) {
			for (x = 0; x < state.cols; x++) {
				if (Math.abs(x - safeX) <= 1 && Math.abs(y - safeY) <= 1) { continue; }
				pool.push(y * state.cols + x);
			}
		}
	}
	else {
		for (i = 0; i < total; i++) {
			if (i !== safeY * state.cols + safeX) { pool.push(i); }
		}
	}
	for (i = pool.length - 1; i > 0; i--) {
		var j = Math.floor(minesweeperRand(state) * (i + 1));
		var swap = pool[i];
		pool[i] = pool[j];
		pool[j] = swap;
	}
	for (i = 0; i < state.mines; i++) {
		state.cells[pool[i]].mine = true;
	}
	for (y = 0; y < state.rows; y++) {
		for (x = 0; x < state.cols; x++) {
			var cell = state.cells[y * state.cols + x];
			if (cell.mine) { continue; }
			var count = 0;
			for (var dy = -1; dy <= 1; dy++) {
				for (var dx = -1; dx <= 1; dx++) {
					if (!dx && !dy) { continue; }
					var nx = x + dx, ny = y + dy;
					if (nx < 0 || ny < 0 || nx >= state.cols || ny >= state.rows) { continue; }
					if (state.cells[ny * state.cols + nx].mine) { count++; }
				}
			}
			cell.adj = count;
		}
	}
	state.placed = true;
	state.status = 'playing';
}

// Open a square and, from every zero, its neighbours too. A flag is never
// opened by the flood.
function minesweeperOpen(state, x, y) {
	var stack = [y * state.cols + x];
	while (stack.length) {
		var i = stack.pop();
		var cell = state.cells[i];
		if (cell.revealed || cell.flagged) { continue; }
		cell.revealed = true;
		if (!cell.mine) { state.revealed++; }
		if (cell.adj !== 0 || cell.mine) { continue; }
		var cx = i % state.cols;
		var cy = (i - cx) / state.cols;
		for (var dy = -1; dy <= 1; dy++) {
			for (var dx = -1; dx <= 1; dx++) {
				if (!dx && !dy) { continue; }
				var nx = cx + dx, ny = cy + dy;
				if (nx < 0 || ny < 0 || nx >= state.cols || ny >= state.rows) { continue; }
				var ni = ny * state.cols + nx;
				if (!state.cells[ni].revealed && !state.cells[ni].flagged) { stack.push(ni); }
			}
		}
	}
}

// Mutates and returns the state. A finished game, an out-of-bounds square, a
// flagged square and an open square are all left alone.
function minesweeperReveal(state, x, y) {
	if (!state || state.status === 'won' || state.status === 'lost') { return state; }
	x = Math.floor(x);
	y = Math.floor(y);
	if (x < 0 || y < 0 || x >= state.cols || y >= state.rows) { return state; }
	var i = y * state.cols + x;
	var cell = state.cells[i];
	if (cell.revealed || cell.flagged) { return state; }
	if (!state.placed) { minesweeperPlaceMines(state, x, y); }
	if (cell.mine) {
		cell.revealed = true;
		state.exploded = i;
		state.status = 'lost';
		return state;
	}
	minesweeperOpen(state, x, y);
	if (state.revealed >= state.cols * state.rows - state.mines) { state.status = 'won'; }
	return state;
}

// Mutates and returns the state. Only a covered square can be flagged, and a
// reveal is refused until the flag is lifted.
function minesweeperFlag(state, x, y) {
	if (!state || state.status === 'won' || state.status === 'lost') { return state; }
	var cell = minesweeperCell(state, x, y);
	if (!cell || cell.revealed) { return state; }
	cell.flagged = !cell.flagged;
	state.flags += cell.flagged ? 1 : -1;
	return state;
}

function minesweeperWon(state) {
	return !!state && state.status === 'won';
}

function minesweeperLost(state) {
	return !!state && state.status === 'lost';
}

// True while the game's pane exists, is laid out and is not hidden. The play
// session asks this before it counts a beat and the ticker asks it before it
// paints.
function minesweeperScreen() {
	if (typeof document === 'undefined' || !document.getElementById) { return false; }
	var root = document.getElementById('minesweeper');
	if (!root) { return false; }
	if (root.getClientRects && root.getClientRects().length === 0) { return false; }
	if (!root.offsetWidth && !root.offsetHeight) { return false; }
	if (typeof window !== 'undefined' && window.getComputedStyle) {
		var style = window.getComputedStyle(root);
		if (style.display === 'none' || style.visibility === 'hidden') { return false; }
	}
	return true;
}

function minesweeperInit() {
	if (typeof document === 'undefined' || !document.getElementById) { return; }
	var root = document.getElementById('minesweeper');
	if (!root || root.getAttribute('data-ms-init') === '1') { return; }
	var board = root.querySelector('#ms_board');
	var minesEl = root.querySelector('#ms_mines');
	var timeEl = root.querySelector('#ms_time');
	var flagBtn = root.querySelector('#ms_flag');
	var newBtn = root.querySelector('#ms_new');
	var noteEl = root.querySelector('#ms_note');
	var stage = root.querySelector('.ms_stage');
	if (!board || !minesEl || !timeEl || !flagBtn || !newBtn || !noteEl || !stage) { return; }
	root.setAttribute('data-ms-init', '1');

	function attrInt(name, fallback) {
		var value = parseInt(root.getAttribute(name), 10);
		return value > 0 ? value : fallback;
	}
	var cols = attrInt('data-cols', 9);
	var rows = attrInt('data-rows', 9);
	var mines = attrInt('data-mines', 10);
	var state = null;
	var flagMode = false;
	var cursor = { x: Math.floor(cols / 2), y: Math.floor(rows / 2), on: false };
	var clock = { elapsed: 0, since: 0, running: false, timer: null };

	function msT(text) {
		return (typeof jawnosT === 'function') ? jawnosT(text) : text;
	}

	function say(text) {
		noteEl.textContent = text;
	}

	function clockValue() {
		return clock.elapsed + (clock.running ? Date.now() - clock.since : 0);
	}

	function clockText(value) {
		var total = Math.floor(value / 1000);
		var minutes = Math.floor(total / 60);
		var seconds = total % 60;
		return minutes + ':' + (seconds < 10 ? '0' : '') + seconds;
	}

	function clockPaint() {
		timeEl.textContent = clockText(clockValue());
	}

	function clockPause() {
		if (!clock.running) { return; }
		clock.elapsed += Date.now() - clock.since;
		clock.running = false;
		if (clock.timer) { clearInterval(clock.timer); clock.timer = null; }
		clockPaint();
	}

	function clockStart() {
		if (clock.running || !state || state.status !== 'playing') { return; }
		clock.since = Date.now();
		clock.running = true;
		if (!clock.timer) {
			clock.timer = setInterval(function () {
				// The window can be closed or another app raised without a page
				// event; a ticker whose own root is gone or replaced stops itself.
				if (!alive()) { clockPause(); return; }
				clockPaint();
			}, 250);
		}
		clockPaint();
	}

	function clockReset() {
		clockPause();
		clock.elapsed = 0;
		clock.running = false;
		clock.since = 0;
		clockPaint();
	}

	// The old root of a re-rendered window must stop its clock even though a new
	// #minesweeper now answers the document lookup.
	function alive() {
		if (!minesweeperScreen()) { return false; }
		if (root.isConnected === false) { return false; }
		return document.getElementById('minesweeper') === root;
	}

	function paintHud() {
		var left = state.mines - state.flags;
		if (state.status === 'won') { left = 0; }
		minesEl.textContent = String(left);
		clockPaint();
	}

	function updateFlagButton() {
		flagBtn.setAttribute('aria-pressed', flagMode ? 'true' : 'false');
		if (flagMode) { flagBtn.classList.add('on'); }
		else { flagBtn.classList.remove('on'); }
	}

	function cellLabel(cell, x, y) {
		var what;
		if (cell.revealed) { what = cell.mine ? msT('mine') : (cell.adj > 0 ? String(cell.adj) : msT('empty')); }
		else if (cell.flagged) { what = msT('flagged'); }
		else { what = msT('hidden'); }
		return msT('Row') + ' ' + (y + 1) + ', ' + msT('column') + ' ' + (x + 1) + ': ' + what;
	}

	function render() {
		board.style.setProperty('--ms-cols', String(state.cols));
		board.style.setProperty('--ms-rows', String(state.rows));
		var fragment = document.createDocumentFragment();
		var over = state.status === 'won' || state.status === 'lost';
		for (var y = 0; y < state.rows; y++) {
			for (var x = 0; x < state.cols; x++) {
				var index = y * state.cols + x;
				var cell = state.cells[index];
				var button = document.createElement('button');
				button.type = 'button';
				button.tabIndex = -1;
				button.setAttribute('data-x', x);
				button.setAttribute('data-y', y);
				var classes = 'ms_cell';
				if (cell.revealed) {
					classes += ' open';
					if (cell.mine) {
						classes += ' mine';
						if (index === state.exploded) { classes += ' boom'; }
						button.textContent = '\u2739';
					}
					else if (cell.adj > 0) {
						classes += ' n' + cell.adj;
						button.textContent = String(cell.adj);
					}
				}
				else if (cell.flagged) {
					classes += ' flag';
					button.textContent = '\u2691';
				}
				else if (over && cell.mine) {
					// A lost field shows every mine; a won field flags the rest.
					if (state.status === 'won') { classes += ' flag'; button.textContent = '\u2691'; }
					else { classes += ' mine'; button.textContent = '\u2739'; }
				}
				if (cursor.on && cursor.x === x && cursor.y === y) { classes += ' cursor'; }
				button.className = classes;
				button.setAttribute('aria-label', cellLabel(cell, x, y));
				fragment.appendChild(button);
			}
		}
		board.textContent = '';
		board.appendChild(fragment);
		paintHud();
		fitBoard();
	}

	function fitBoard() {
		if (!state) { return; }
		var gap = 2;
		var room = 20;
		var width = stage.clientWidth - room;
		var height = stage.clientHeight - room;
		if (width <= 0 || height <= 0) { return; }
		var size = Math.floor(Math.min(
			(width - gap * (state.cols - 1)) / state.cols,
			(height - gap * (state.rows - 1)) / state.rows
		));
		if (!isFinite(size) || size <= 0) { return; }
		size = Math.max(22, Math.min(72, size));
		board.style.setProperty('--ms-cell', size + 'px');
		board.style.width = (size * state.cols + gap * (state.cols - 1)) + 'px';
		board.style.height = (size * state.rows + gap * (state.rows - 1)) + 'px';
	}

	function sessionTouch() {
		if (typeof jawnosGameSessionStart === 'function') {
			jawnosGameSessionStart('Minesweeper', minesweeperScreen);
		}
	}

	function ensureFocus() {
		try { root.focus({ preventScroll: true }); }
		catch (error) { try { root.focus(); } catch (ignored) {} }
	}

	function newGame() {
		clockReset();
		cursor = { x: Math.floor(cols / 2), y: Math.floor(rows / 2), on: false };
		var seed = (((Date.now() & 0x7fffffff) ^ Math.floor(Math.random() * 0x7fffffff)) >>> 0);
		state = minesweeperNewState(cols, rows, mines, seed);
		say(msT('Clear the field without hitting a mine.'));
		render();
	}

	function revealAt(x, y) {
		if (!state || state.status === 'won' || state.status === 'lost') { return; }
		var cell = minesweeperCell(state, x, y);
		if (!cell) { return; }
		if (cell.flagged) {
			say(msT('That square is flagged.'));
			return;
		}
		cursor.x = x;
		cursor.y = y;
		minesweeperReveal(state, x, y);
		if (state.status === 'playing') { clockStart(); }
		if (state.status === 'lost') {
			clockPause();
			say(msT('A mine went off.'));
		}
		else if (state.status === 'won') {
			clockPause();
			say(msT('The field is clear.'));
		}
		else if (state.placed) {
			say(msT('Clear the field without hitting a mine.'));
		}
		render();
		sessionTouch();
	}

	function flagAt(x, y) {
		if (!state || state.status === 'won' || state.status === 'lost') { return; }
		var before = state.flags;
		minesweeperFlag(state, x, y);
		if (state.flags !== before) {
			if (state.status === 'playing') { clockStart(); }
			render();
			sessionTouch();
		}
	}

	function cellAt(event) {
		var node = event.target;
		while (node && node !== board) {
			if (node.hasAttribute && node.hasAttribute('data-x') && node.hasAttribute('data-y')) {
				var x = parseInt(node.getAttribute('data-x'), 10);
				var y = parseInt(node.getAttribute('data-y'), 10);
				if (!isNaN(x) && !isNaN(y)) { return { x: x, y: y }; }
			}
			node = node.parentNode;
		}
		return null;
	}

	root.addEventListener('pointerdown', function (event) {
		sessionTouch();
		var control = event.target && event.target.closest ? event.target.closest('.ms_btn') : null;
		if (!control) { ensureFocus(); }
	}, true);
	root.addEventListener('keydown', sessionTouch);

	var rightFlaggedAt = 0;
	board.addEventListener('pointerdown', function (event) {
		// A right press flags at once; the context menu below ignores its own
		// event when this already handled the press.
		if (event.button === 2) {
			event.preventDefault();
			var right = cellAt(event);
			if (right) { rightFlaggedAt = Date.now(); flagAt(right.x, right.y); }
			return;
		}
		if (event.pointerType === 'mouse' && event.button !== 0) { return; }
		var at = cellAt(event);
		if (!at) { return; }
		event.preventDefault();
		ensureFocus();
		if (flagMode) { flagAt(at.x, at.y); }
		else { revealAt(at.x, at.y); }
	});

	board.addEventListener('contextmenu', function (event) {
		event.preventDefault();
		if (Date.now() - rightFlaggedAt < 500) { return; }
		var at = cellAt(event);
		if (at) { flagAt(at.x, at.y); }
	});

	flagBtn.addEventListener('click', function () {
		flagMode = !flagMode;
		updateFlagButton();
		ensureFocus();
		sessionTouch();
	});

	newBtn.addEventListener('click', function () {
		newGame();
		ensureFocus();
		sessionTouch();
	});

	root.addEventListener('keydown', function (event) {
		if (event.target && event.target.closest && event.target.closest('.ms_btn')) { return; }
		var key = event.key;
		if (key === 'n' || key === 'N') {
			event.preventDefault();
			newGame();
			ensureFocus();
			return;
		}
		if (key === 'f' || key === 'F') {
			event.preventDefault();
			cursor.on = true;
			flagAt(cursor.x, cursor.y);
			return;
		}
		var steps = {
			ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1]
		};
		if (steps[key]) {
			event.preventDefault();
			cursor.on = true;
			cursor.x = Math.max(0, Math.min(state.cols - 1, cursor.x + steps[key][0]));
			cursor.y = Math.max(0, Math.min(state.rows - 1, cursor.y + steps[key][1]));
			render();
			return;
		}
		if (key === ' ' || key === 'Enter') {
			event.preventDefault();
			cursor.on = true;
			revealAt(cursor.x, cursor.y);
		}
	});

	if (typeof document !== 'undefined' && document.addEventListener) {
		document.addEventListener('visibilitychange', function () {
			if (document.visibilityState === 'hidden') { clockPause(); }
			else if (state.status === 'playing' && alive()) { clockStart(); }
		});
	}
	if (typeof window !== 'undefined' && window.addEventListener) {
		window.addEventListener('pagehide', function () { clockPause(); });
	}
	if (typeof ResizeObserver === 'function') {
		var observer = new ResizeObserver(function () {
			if (root.isConnected === false) { observer.disconnect(); return; }
			fitBoard();
		});
		observer.observe(stage);
	}
	else if (typeof window !== 'undefined' && window.addEventListener) {
		window.addEventListener('resize', fitBoard);
	}

	updateFlagButton();
	newGame();
}
