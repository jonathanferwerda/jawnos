/* [[js-split]]
   pipedream.js is part 1. The rest live in pipedream/ in name order:
     01_pipedream_flow.js  - screen check, ticker, pagehide/visibility/key bindings
     02_pipedream_ui.js    - pipedreamInit: canvas, drawing, hand, controls and the flow
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// Pipedream: the plumbing game. A source on the left edge pushes liquid into a
// grid; the player lays straight, elbow and tee pieces from a hand, turns them,
// and tries to reach every drain on the right edge before a pipe pours into an
// empty cell. The rules are plain functions at the top of this file so the
// puzzle can be played in a bare JS context (t/350-pipedream.t); every DOM and
// jQuery touch lives inside pipedreamInit(), which the template calls.
//
// State shape (plain data, no DOM):
// {
//   cols, rows, seed,
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
var PD_BASE = { straight: [ 0, 2 ], elbow: [ 0, 1 ], tee: [ 0, 1, 2 ] };

// A small seeded PRNG (mulberry32), never Math.random: the same seed deals the
// same hand and the same route, which is what the test checks.
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

// The board is generated around one guaranteed route: a trunk east from the
// source, a tee at the junction, and two branches to the two right-edge drains.
// The hand is that route's pieces plus two spare pieces, shuffled by the seed.
function pipedreamNewState(cols, rows, seed) {
	cols = Math.floor(Number(cols) || 6);
	rows = Math.floor(Number(rows) || 5);
	if (cols < 4) { cols = 4; }
	if (rows < 3) { rows = 3; }
	seed = Math.floor(Math.abs(Number(seed) || 1)) || 1;

	var sy = Math.floor(rows / 2);
	var state = {
		cols: cols,
		rows: rows,
		seed: seed,
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
	for (var y = 0; y < rows; y++) {
		state.cells.push([]);
		state.wet.push([]);
		for (var x = 0; x < cols; x++) {
			state.cells[y].push(null);
			state.wet[y].push(false);
		}
	}

	// The source enters from the left edge and pushes east.
	state.cells[sy][0] = { kind: 'source', rot: 0, fixed: true, sides: [ 1 ] };
	if (rows >= 3) {
		state.drains.push({ x: cols - 1, y: sy - 1 });
		state.drains.push({ x: cols - 1, y: sy + 1 });
	}
	else {
		state.drains.push({ x: cols - 1, y: sy });
	}
	for (var d = 0; d < state.drains.length; d++) {
		var drain = state.drains[d];
		state.cells[drain.y][drain.x] = { kind: 'drain', rot: 0, fixed: true, sides: [ 3 ] };
		state.reached.push(false);
	}

	var route = [];
	if (state.drains.length >= 2) {
		var span = Math.max(1, cols - 3);
		var jx = 2 + (seed % span);
		if (jx > cols - 2) { jx = cols - 2; }
		// Trunk: straights east-west, then a tee opening west, north and south.
		for (x = 1; x < jx; x++) { route.push({ x: x, y: sy, kind: 'straight', rot: 1 }); }
		route.push({ x: jx, y: sy, kind: 'tee', rot: 2 });
		// Upper branch: out of the tee, north then east to the top drain.
		route.push({ x: jx, y: sy - 1, kind: 'elbow', rot: 1 });
		for (x = jx + 1; x <= cols - 2; x++) { route.push({ x: x, y: sy - 1, kind: 'straight', rot: 1 }); }
		// Lower branch: out of the tee, south then east to the bottom drain.
		route.push({ x: jx, y: sy + 1, kind: 'elbow', rot: 0 });
		for (x = jx + 1; x <= cols - 2; x++) { route.push({ x: x, y: sy + 1, kind: 'straight', rot: 1 }); }
	}
	else {
		for (x = 1; x <= cols - 2; x++) { route.push({ x: x, y: sy, kind: 'straight', rot: 1 }); }
	}

	state.solution = route.map(function (c) {
		return { x: c.x, y: c.y, kind: c.kind, rot: c.rot };
	});

	var hand = route.map(function (c) { return { kind: c.kind, used: false }; });
	hand.push({ kind: 'straight', used: false });
	hand.push({ kind: 'elbow', used: false });
	state.hand = pipedreamShuffle(hand, pipedreamRng(seed));

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
