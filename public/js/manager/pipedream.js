/* [[js-split]]
   pipedream.js is part 1. The rest live in pipedream/ in name order:
     01_pipedream_flow.js  - screen check, ticker, pagehide/visibility/key bindings
     02_pipedream_ui.js    - pipedreamInit: canvas, drawing, hand, controls and the flow
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// Pipedream: the plumbing game. A source on the left edge pushes liquid into a
// grid; the player lays straight, elbow, tee and cross pieces from a hand, turns
// them, and tries to reach every drain on the right edge before a pipe pours
// into an empty cell. The rules are plain functions at the top of this file so
// the puzzle can be played in a bare JS context (t/350-pipedream.t); every DOM
// and jQuery touch lives inside pipedreamInit(), which the template calls.
//
// State shape (plain data, no DOM):
// {
//   cols, rows, seed, level,
//   cells:   rows x cols -> null | { kind, rot, fixed, hand, sides? },
//            source and drain pieces carry a fixed side list; placed pieces
//            carry the hand index they came from.
//   source:  { x, y },
//   drains:  [ { x, y } ],             reached: [ bool ] one per drain
//   hand:    [ { kind, used } ],       a finite hand, stable indices
//   solution:[ { x, y, kind, rot } ],  the deal's guaranteed route
//   order:   [ { x, y, hand } ],       placement history for undo
//   wet:     rows x cols booleans,     liquid has entered the cell
//   frontier:[ { x, y } ],             cells whose outlets step next
//   won, spilled, spillAt, steps, moves
// }
//
// Side numbers are 0=N, 1=E, 2=S, 3=W. A piece may be entered only through one
// of its own outlets, and that outlet must meet the opposite outlet on the
// neighbour. An outlet that meets nothing is an open end and spills. The drain
// swallows liquid, so reaching every drain is the win; a spill is the loss.

var PD_DIRS = [ [ 0, -1 ], [ 1, 0 ], [ 0, 1 ], [ -1, 0 ] ];
var PD_OPPOSITE = [ 2, 3, 0, 1 ];
var PD_BASE = { straight: [ 0, 2 ], elbow: [ 0, 1 ], tee: [ 0, 1, 2 ], cross: [ 0, 1, 2, 3 ] };

// A small seeded PRNG (mulberry32), never Math.random: the same seed deals the
// same board and the same hand, which is what the test checks.
function pipedreamRng(seed) {
	var a = (Number(seed) >>> 0) || 1;
	return function () {
		a = (a + 0x6D2B79F5) | 0;
		var t = Math.imul(a ^ (a >>> 15), 1 | a);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

function pipedreamShuffle(list, rnd) {
	for (var i = list.length - 1; i > 0; i--) {
		var j = Math.floor(rnd() * (i + 1));
		var swap = list[i];
		list[i] = list[j];
		list[j] = swap;
	}
	return list;
}

function pipedreamPieceSides(piece) {
	if (!piece) { return []; }
	if (piece.sides && piece.sides.length) { return piece.sides.slice(); }
	var base = PD_BASE[piece.kind] || [];
	var rot = Number(piece.rot) || 0;
	rot = ((rot % 4) + 4) % 4;
	var out = [];
	for (var i = 0; i < base.length; i++) { out.push((base[i] + rot) % 4); }
	out.sort(function (a, b) { return a - b; });
	return out;
}

// Each level buys a bigger table and more plumbing: one more column than the
// level before, an extra row every other level, another drain now and then, and
// a few more decoy pieces in the hand. Level 1 is six by six - about a quarter
// more cells than the old six by five board.
function pipedreamBoardForLevel(level) {
	level = Math.floor(Number(level) || 1);
	if (level < 1) { level = 1; }
	var cols = 6 + (level - 1);
	var rows = 6 + Math.floor((level - 1) / 2);
	if (cols > 12) { cols = 12; }
	if (rows > 10) { rows = 10; }
	var drains = 2 + Math.floor((level - 1) / 2);
	if (drains > rows - 1) { drains = rows - 1; }
	if (drains > 4) { drains = 4; }
	if (drains < 1) { drains = 1; }
	var decoys = 1 + Math.floor((level - 1) / 2);
	return { cols: cols, rows: rows, drains: drains, decoys: decoys };
}

function pipedreamCellKey(x, y) { return x + ',' + y; }

function pipedreamSideFrom(cx, cy, nx, ny) {
	if (nx === cx + 1 && ny === cy) { return 1; }
	if (nx === cx - 1 && ny === cy) { return 3; }
	if (nx === cx && ny === cy + 1) { return 2; }
	if (nx === cx && ny === cy - 1) { return 0; }
	return -1;
}

// The piece and rotation whose outlets are exactly this side set. Around four
// sides every pair is opposite or adjacent, every triple is a tee and the whole
// set is a cross, so a shape always exists.
function pipedreamShapeForSides(sides) {
	if (!sides || sides.length < 2) { return null; }
	var kinds = [ 'straight', 'elbow', 'tee', 'cross' ];
	for (var k = 0; k < kinds.length; k++) {
		var kind = kinds[k];
		var base = PD_BASE[kind];
		if (base.length !== sides.length) { continue; }
		for (var rot = 0; rot < 4; rot++) {
			var got = [];
			for (var i = 0; i < base.length; i++) { got.push((base[i] + rot) % 4); }
			got.sort(function (a, b) { return a - b; });
			var same = true;
			for (var j = 0; j < got.length; j++) {
				if (got[j] !== sides[j]) { same = false; break; }
			}
			if (same) { return { kind: kind, rot: rot }; }
		}
	}
	return null;
}

// Build the deal's guaranteed route. It is a random tree: a seeded growth from
// the cell east of the source that stops once it touches the west side of every
// drain, then has its dead ends pruned away so every cell that remains is a
// real connection. Each cell's outlets become a piece. Because the tree is
// connected and has no open ends, the water reaches every drain when the route
// is laid; the caller turns the route into the hand.
function pipedreamBuildRoute(cols, rows, sy, drainRows, rnd) {
	var placeable = {};
	var x, y;
	for (y = 0; y < rows; y++) {
		for (x = 0; x < cols - 1; x++) {
			if (x === 0 && y === sy) { continue; }
			placeable[pipedreamCellKey(x, y)] = true;
		}
	}

	var required = {};
	required[pipedreamCellKey(1, sy)] = true;
	for (var d = 0; d < drainRows.length; d++) {
		required[pipedreamCellKey(cols - 2, drainRows[d])] = true;
	}

	var inTree = {};
	var neighbors = {}; // key -> { side: true } to the cells it pipes toward
	var queued = {};
	var frontier = [];

	function addCell(cx, cy) {
		var key = pipedreamCellKey(cx, cy);
		if (inTree[key]) { return; }
		inTree[key] = true;
		neighbors[key] = {};
		var dirs = [ [ cx + 1, cy ], [ cx - 1, cy ], [ cx, cy + 1 ], [ cx, cy - 1 ] ];
		for (var i = 0; i < dirs.length; i++) {
			var nk = pipedreamCellKey(dirs[i][0], dirs[i][1]);
			if (placeable[nk] && !inTree[nk] && !queued[nk]) {
				queued[nk] = true;
				frontier.push(nk);
			}
		}
	}

	function connect(aKey, bKey) {
		var a = aKey.split(',');
		var b = bKey.split(',');
		var side = pipedreamSideFrom(parseInt(a[0], 10), parseInt(a[1], 10),
			parseInt(b[0], 10), parseInt(b[1], 10));
		if (side < 0) { return false; }
		neighbors[aKey][side] = true;
		neighbors[bKey][PD_OPPOSITE[side]] = true;
		return true;
	}

	function treeSides(key) {
		var out = [];
		var n = neighbors[key] || {};
		for (var s = 0; s < 4; s++) { if (n[s]) { out.push(s); } }
		return out;
	}

	function allRequiredIn() {
		for (var key in required) { if (!inTree[key]) { return false; } }
		return true;
	}

	addCell(1, sy);
	var guard = cols * rows * 8;
	while (!allRequiredIn() && frontier.length && guard-- > 0) {
		var pick = Math.floor(rnd() * frontier.length);
		var key = frontier[pick];
		frontier[pick] = frontier[frontier.length - 1];
		frontier.pop();
		queued[key] = false;
		if (inTree[key]) { continue; }
		var parts = key.split(',');
		var cx = parseInt(parts[0], 10);
		var cy = parseInt(parts[1], 10);
		var joined = [];
		var dirs = [ [ cx + 1, cy ], [ cx - 1, cy ], [ cx, cy + 1 ], [ cx, cy - 1 ] ];
		for (var i = 0; i < dirs.length; i++) {
			var nk = pipedreamCellKey(dirs[i][0], dirs[i][1]);
			if (inTree[nk]) { joined.push(nk); }
		}
		if (!joined.length) { continue; }
		var parent = joined[Math.floor(rnd() * joined.length)];
		addCell(cx, cy);
		connect(key, parent);
	}

	// Prune every dead end that is not the source's cell or a drain's cell: a
	// one-outlet cell cannot be built from the hand's pieces and leads nowhere.
	var pruned = true;
	while (pruned) {
		pruned = false;
		for (var k in inTree) {
			if (required[k]) { continue; }
			var sidesHere = treeSides(k);
			if (sidesHere.length > 1) { continue; }
			var pp = k.split(',');
			var px = parseInt(pp[0], 10);
			var py = parseInt(pp[1], 10);
			for (var s = 0; s < sidesHere.length; s++) {
				var dir = PD_DIRS[sidesHere[s]];
				var nb = pipedreamCellKey(px + dir[0], py + dir[1]);
				if (neighbors[nb]) { delete neighbors[nb][PD_OPPOSITE[sidesHere[s]]]; }
			}
			delete inTree[k];
			delete neighbors[k];
			pruned = true;
		}
	}

	// Turn the route into pieces. The first cell pipes west into the source and
	// the cell in front of each drain pipes east into it.
	var route = [];
	for (var key2 in inTree) {
		var q = key2.split(',');
		var qx = parseInt(q[0], 10);
		var qy = parseInt(q[1], 10);
		var sides = treeSides(key2);
		if (qx === 1 && qy === sy) { sides.push(3); }
		for (var r = 0; r < drainRows.length; r++) {
			if (qx === cols - 2 && qy === drainRows[r]) { sides.push(1); }
		}
		sides.sort(function (a, b) { return a - b; });
		var uniq = [];
		for (var z = 0; z < sides.length; z++) {
			if (uniq[uniq.length - 1] !== sides[z]) { uniq.push(sides[z]); }
		}
		var shape = pipedreamShapeForSides(uniq);
		if (!shape) { return null; }
		route.push({ x: qx, y: qy, kind: shape.kind, rot: shape.rot });
	}
	return route;
}

// Deal a fresh board: a random source row, random drain rows and a random route
// from pipedreamBuildRoute. The hand is that route's pieces plus a straight and
// an elbow spare and the level's decoys, shuffled by the seed.
function pipedreamNewState(cols, rows, seed, level) {
	level = Math.floor(Number(level) || 1);
	if (level < 1) { level = 1; }
	cols = Math.floor(Number(cols) || 6);
	rows = Math.floor(Number(rows) || 6);
	if (cols < 4) { cols = 4; }
	if (rows < 3) { rows = 3; }
	seed = Math.floor(Math.abs(Number(seed) || 1)) || 1;

	var rnd = pipedreamRng(seed);
	var sy = Math.floor(rnd() * rows);
	if (sy > rows - 1) { sy = rows - 1; }

	var drainsWanted = 2 + Math.floor((level - 1) / 2);
	if (drainsWanted > rows - 1) { drainsWanted = rows - 1; }
	if (drainsWanted > 4) { drainsWanted = 4; }
	if (drainsWanted < 1) { drainsWanted = 1; }
	var rowsPool = [];
	for (var ry = 0; ry < rows; ry++) { rowsPool.push(ry); }
	pipedreamShuffle(rowsPool, rnd);
	var drainRows = rowsPool.slice(0, drainsWanted).sort(function (a, b) { return a - b; });

	var state = {
		cols: cols,
		rows: rows,
		seed: seed,
		level: level,
		cells: [],
		wet: [],
		frontier: [],
		source: { x: 0, y: sy },
		drains: [],
		reached: [],
		hand: [],
		solution: [],
		order: [],
		won: false,
		spilled: false,
		spillAt: null,
		steps: 0,
		moves: 0
	};
	for (var yy = 0; yy < rows; yy++) {
		state.cells.push([]);
		state.wet.push([]);
		for (var xx = 0; xx < cols; xx++) {
			state.cells[yy].push(null);
			state.wet[yy].push(false);
		}
	}

	// The source enters from the left edge and pushes east.
	state.cells[sy][0] = { kind: 'source', rot: 0, fixed: true, sides: [ 1 ] };
	for (var dd = 0; dd < drainRows.length; dd++) {
		state.drains.push({ x: cols - 1, y: drainRows[dd] });
		state.cells[drainRows[dd]][cols - 1] = { kind: 'drain', rot: 0, fixed: true, sides: [ 3 ] };
		state.reached.push(false);
	}

	var route = null;
	for (var attempt = 0; attempt < 4 && !route; attempt++) {
		route = pipedreamBuildRoute(cols, rows, sy, drainRows, rnd);
	}
	route = route || [];
	state.solution = route.map(function (c) {
		return { x: c.x, y: c.y, kind: c.kind, rot: c.rot };
	});

	var hand = route.map(function (c) { return { kind: c.kind, used: false }; });
	// Always leave a straight and an elbow spare; the level adds more decoys.
	hand.push({ kind: 'straight', used: false });
	hand.push({ kind: 'elbow', used: false });
	var decoys = 1 + Math.floor((level - 1) / 2);
	var pool = [ 'straight', 'elbow', 'tee' ];
	for (var dc = 0; dc < decoys; dc++) {
		hand.push({ kind: pool[Math.floor(rnd() * pool.length)], used: false });
	}
	state.hand = pipedreamShuffle(hand, rnd);

	pipedreamResetFlow(state);
	return state;
}

// The route the deal was built from. The UI does not draw it; the test and a
// future hint control can.
function pipedreamSolution(state) {
	if (!state || !state.solution) { return []; }
	return state.solution.map(function (c) {
		return { x: c.x, y: c.y, kind: c.kind, rot: c.rot };
	});
}

function pipedreamResetFlow(state) {
	if (!state) { return; }
	for (var y = 0; y < state.rows; y++) {
		for (var x = 0; x < state.cols; x++) { state.wet[y][x] = false; }
	}
	state.wet[state.source.y][state.source.x] = true;
	state.frontier = [ { x: state.source.x, y: state.source.y } ];
	for (var d = 0; d < state.reached.length; d++) { state.reached[d] = false; }
	state.won = false;
	state.spilled = false;
	state.spillAt = null;
	state.steps = 0;
}

// Advance every liquid front by one cell. A cell's outlet either meets the
// opposite outlet of a pipe (liquid enters), meets a drain (that drain drinks),
// or meets nothing (spill). A spill in the same step as the final drain is still
// a win: the water reached its destination.
function pipedreamStep(state) {
	if (!state || state.won || state.spilled) { return state; }
	var layer = state.frontier || [];
	var next = [];
	var spill = null;

	for (var i = 0; i < layer.length; i++) {
		var cx = layer[i].x;
		var cy = layer[i].y;
		var piece = state.cells[cy] && state.cells[cy][cx];
		if (!piece) { continue; }
		var sides = pipedreamPieceSides(piece);
		for (var s = 0; s < sides.length; s++) {
			var side = sides[s];
			var dir = PD_DIRS[side];
			var nx = cx + dir[0];
			var ny = cy + dir[1];
			if (nx < 0 || nx >= state.cols || ny < 0 || ny >= state.rows) {
				if (!spill) { spill = { x: cx, y: cy, side: side, nx: nx, ny: ny }; }
				continue;
			}
			var other = state.cells[ny][nx];
			var want = PD_OPPOSITE[side];
			if (!other) {
				if (!spill) { spill = { x: cx, y: cy, side: side, nx: nx, ny: ny }; }
				continue;
			}
			if (pipedreamPieceSides(other).indexOf(want) < 0) {
				if (!spill) { spill = { x: cx, y: cy, side: side, nx: nx, ny: ny }; }
				continue;
			}
			if (other.kind === 'drain') {
				for (var d = 0; d < state.drains.length; d++) {
					if (state.drains[d].x === nx && state.drains[d].y === ny) {
						state.reached[d] = true;
						state.wet[ny][nx] = true;
						break;
					}
				}
				continue;
			}
			if (other.kind === 'source') { continue; }
			if (!state.wet[ny][nx]) {
				state.wet[ny][nx] = true;
				next.push({ x: nx, y: ny });
			}
		}
	}

	state.frontier = next;
	state.steps++;

	var all = state.reached.length > 0;
	for (var r = 0; r < state.reached.length; r++) {
		if (!state.reached[r]) { all = false; break; }
	}
	if (all) {
		state.won = true;
		state.spilled = false;
		state.spillAt = null;
	}
	else if (spill) {
		state.spilled = true;
		state.spillAt = spill;
		state.frontier = [];
	}
	return state;
}

function pipedreamWon(state) {
	return !!state && !!state.won;
}

function pipedreamLost(state) {
	return !!state && !!state.spilled && !state.won;
}

// Place hand[pieceIndex] on an empty cell. Occupied cells (including the fixed
// source and drains) refuse the piece, and a used piece cannot be placed again.
function pipedreamPlace(state, x, y, pieceIndex, rot) {
	if (!state) { return false; }
	x = Math.floor(Number(x));
	y = Math.floor(Number(y));
	if (x < 0 || y < 0 || x >= state.cols || y >= state.rows) { return false; }
	if (state.cells[y][x]) { return false; }
	var idx = Math.floor(Number(pieceIndex));
	if (idx < 0 || idx >= state.hand.length) { return false; }
	var piece = state.hand[idx];
	if (!piece || piece.used) { return false; }
	var r = Math.floor(Number(rot) || 0);
	r = ((r % 4) + 4) % 4;
	piece.used = true;
	state.cells[y][x] = { kind: piece.kind, rot: r, fixed: false, hand: idx };
	state.order.push({ x: x, y: y, hand: idx });
	state.moves++;
	pipedreamResetFlow(state);
	return true;
}

function pipedreamRotate(state, x, y) {
	if (!state) { return false; }
	x = Math.floor(Number(x));
	y = Math.floor(Number(y));
	if (x < 0 || y < 0 || x >= state.cols || y >= state.rows) { return false; }
	var piece = state.cells[y][x];
	if (!piece || piece.fixed) { return false; }
	piece.rot = ((piece.rot || 0) + 1) % 4;
	pipedreamResetFlow(state);
	return true;
}

// Lift the most recently placed piece and return it to the hand.
function pipedreamUndo(state) {
	if (!state || !state.order || !state.order.length) { return false; }
	var last = state.order.pop();
	state.cells[last.y][last.x] = null;
	if (state.hand[last.hand]) { state.hand[last.hand].used = false; }
	state.moves = Math.max(0, state.moves - 1);
	pipedreamResetFlow(state);
	return true;
}
