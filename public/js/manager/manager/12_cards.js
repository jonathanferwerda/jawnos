// The Cards app: four decks on one table.
//
// Tarot is the old deck of Jawn, drawn from the person's own days. Solitaire is
// Klondike with a three-card deal, the house's felt table and a bank that carries
// across rounds. Mahjong is a multi-layer turtle of paired tiles. Blackjack is
// the casino table with chips and a running bank.
//
// The rules live in plain functions so they can be checked without a browser
// (t/116-cards-games.t); the event handlers at the bottom only wire them to the
// page. Every handler is delegated, because the app's window is rebuilt from an
// AJAX reply on each open.

var SOL_RANKS = [ '', 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K' ];
var SOL_SUITS = [ '\u2660', '\u2665', '\u2666', '\u2663' ];
var SOL_DRAW = 3;
var MAHJONG_ROWS = [ 12, 8, 10, 12, 12, 10, 8, 12 ];
var MAHJONG_LAYERS = [
	{ x: 0, y: 0, cols: 12, rows: 8, counts: MAHJONG_ROWS },
	{ x: 3, y: 1, cols: 6, rows: 6, counts: [ 6, 6, 6, 6, 6, 6 ] },
	{ x: 4, y: 2, cols: 4, rows: 4, counts: [ 4, 4, 4, 4 ] },
	{ x: 4, y: 3, cols: 3, rows: 2, counts: [ 3, 3 ] },
	{ x: 5, y: 3, cols: 2, rows: 1, counts: [ 2 ] }
];

var solitaireState = null;
var solitaireStatusDefault = '';
var solitaireStatusTimer = null;
var solitaireSaveTimer = null;
var solitaireDrag = null;
var solitaireSuppressClick = false;
var mahjongState = null;
var mahjongBannerDefault = '';
var blackjackState = null;
var blackjackSaveTimer = null;

// ---- shared helpers --------------------------------------------------------

function cardsRoot() {
	return document.getElementById('cards');
}

function cardsEscape(text) {
	return String(text === undefined || text === null ? '' : text)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function cardsCardUrl(name) {
	// Card files carry spaces ("the fool.png"); a path segment is encoded so the
	// request is the same on every engine.
	return '/images/cards/' + encodeURIComponent(String(name || ''));
}

function cardsShowSpread(names) {
	if (!names || !names.length) { return; }
	var html = '';
	for (var i = 0; i < names.length; i++) {
		html += '<img class="deck_spread_card" src="' + cardsCardUrl(names[i]) + '" alt="' + cardsEscape(names[i]) + '">';
	}
	$('#deck_spread').html(html).show();
	$('#deck_card').hide();
}

function cardsShowSingle(src, title) {
	$('#deck_spread').hide();
	if (src) { $('#deck_card').attr('src', src).show(); }
	if (title) { $('#card_title').html(cardsEscape(title)).show(); }
	$('#card_description').hide();
}

// ---- choosing a deck -------------------------------------------------------

var CARDS_VARIANTS = [ 'tarot', 'solitaire', 'mahjong', 'blackjack' ];

function cardsShowVariant(variant, save) {
	var root = cardsRoot();
	if (!root) { return; }
	var known = (CARDS_VARIANTS.indexOf(variant) >= 0) ? variant : '';
	root.setAttribute('data-variant', known);
	$('.cards_variant', root).each(function() {
		$(this).toggleClass('active', $(this).attr('data-variant') === known);
	});
	$('#cards_tarot', root).toggleClass('active', known === 'tarot');
	$('#cards_solitaire', root).toggleClass('active', known === 'solitaire');
	$('#cards_mahjong', root).toggleClass('active', known === 'mahjong');
	$('#cards_blackjack', root).toggleClass('active', known === 'blackjack');
	$('#cards_chooser', root).toggleClass('open', !known);
	if (save && typeof settingSetter === 'function') {
		settingSetter({ app: 'cards', setting: 'variant', value: known });
	}
	if (known === 'solitaire') { solitaireEnsure(); }
	else if (known === 'mahjong') { mahjongEnsure(); }
	else if (known === 'blackjack') { blackjackEnsure(); }
	else if (known === 'tarot') { cardPicker(); }
}

function cardsInit() {
	var root = cardsRoot();
	if (!root) { return; }
	var variant = root.getAttribute('data-variant') || '';
	if (variant === 'solitaire') { solitaireEnsure(); }
	else if (variant === 'mahjong') { mahjongEnsure(); }
	else if (variant === 'blackjack') { blackjackEnsure(); }
	else if (variant === 'tarot') { cardPicker(); }
}

// ---- playing cards ---------------------------------------------------------

function solitaireColor(card) {
	return (card.s === 1 || card.s === 2) ? 'red' : 'black';
}

function solitaireCardHtml(card, extra) {
	if (!card.up) {
		return '<div class="sol_card down ' + (extra || '') + '"></div>';
	}
	var suit = SOL_SUITS[card.s];
	var red = solitaireColor(card) === 'red' ? ' red' : '';
	var rank = SOL_RANKS[card.r];
	var centre = (card.r >= 11) ? rank : suit;
	return '<div class="sol_card up' + red + ' ' + (extra || '') + '">'
		+ '<span class="sol_corner tl"><b>' + rank + '</b><i>' + suit + '</i></span>'
		+ '<span class="sol_pip">' + centre + '</span>'
		+ '<span class="sol_corner br"><b>' + rank + '</b><i>' + suit + '</i></span>'
		+ '</div>';
}

// ---- solitaire: the rules --------------------------------------------------

function solitaireDeck() {
	var deck = [];
	for (var s = 0; s < 4; s++) {
		for (var r = 1; r <= 13; r++) {
			deck.push({ r: r, s: s, up: false });
		}
	}
	return deck;
}

function solitaireShuffle(list, rnd) {
	var random = rnd || Math.random;
	for (var i = list.length - 1; i > 0; i--) {
		var j = Math.floor(random() * (i + 1));
		var swap = list[i];
		list[i] = list[j];
		list[j] = swap;
	}
	return list;
}

// Seven columns, one more card each, the last card of each column face up.
function solitaireDeal(rnd) {
	var deck = solitaireShuffle(solitaireDeck(), rnd);
	var state = {
		stock: [],
		waste: [],
		foundations: [ [], [], [], [] ],
		tableau: [ [], [], [], [], [], [], [] ],
		moves: 0,
		passes: 0,
		bank: 0,
		selected: null,
		undo: [],
		won: false,
		startedAt: 0,
		timer: null
	};
	for (var col = 0; col < 7; col++) {
		for (var row = 0; row <= col; row++) {
			var card = deck.pop();
			card.up = (row === col);
			state.tableau[col].push(card);
		}
	}
	state.stock = deck;
	return state;
}

// A movable run is face up, descending by one, with alternating colours.
function solitaireRunOk(cards) {
	if (!cards || !cards.length) { return false; }
	for (var i = 0; i < cards.length; i++) {
		if (!cards[i].up) { return false; }
	}
	for (var j = 1; j < cards.length; j++) {
		if (cards[j].r !== cards[j - 1].r - 1) { return false; }
		if (solitaireColor(cards[j]) === solitaireColor(cards[j - 1])) { return false; }
	}
	return true;
}

function solitaireCanTableau(run, destTop) {
	if (!run || !run.length) { return false; }
	if (!destTop) { return run[0].r === 13; }
	return run[0].r + 1 === destTop.r && solitaireColor(run[0]) !== solitaireColor(destTop);
}

function solitaireCanFoundation(card, pile) {
	if (!card) { return false; }
	if (!pile || !pile.length) { return card.r === 1; }
	var top = pile[pile.length - 1];
	return top.s === card.s && top.r + 1 === card.r;
}

function solitaireWon(state) {
	for (var s = 0; s < 4; s++) {
		if (state.foundations[s].length !== 13) { return false; }
	}
	return true;
}

function solitaireSnapshot(state) {
	return JSON.stringify({
		stock: state.stock,
		waste: state.waste,
		foundations: state.foundations,
		tableau: state.tableau,
		moves: state.moves,
		passes: state.passes,
		bank: state.bank,
		won: state.won
	});
}

function solitairePushUndo(state) {
	state.undo.push(solitaireSnapshot(state));
	if (state.undo.length > 60) { state.undo.shift(); }
}

function solitaireUndo(state) {
	if (!state.undo.length) { return false; }
	var saved = JSON.parse(state.undo.pop());
	state.stock = saved.stock;
	state.waste = saved.waste;
	state.foundations = saved.foundations;
	state.tableau = saved.tableau;
	state.moves = saved.moves;
	state.passes = saved.passes;
	state.bank = saved.bank;
	state.won = saved.won;
	state.selected = null;
	return true;
}

// The stock deals three face up; an empty stock turns the waste back over.
function solitaireDraw(state) {
	solitairePushUndo(state);
	if (!state.stock.length) {
		if (!state.waste.length) {
			state.undo.pop();
			return false;
		}
		var turned = state.waste.slice().reverse();
		for (var t = 0; t < turned.length; t++) { turned[t].up = false; }
		state.stock = turned;
		state.waste = [];
		state.passes++;
		state.bank -= 20;
	}
	else {
		for (var i = 0; i < SOL_DRAW && state.stock.length; i++) {
			var card = state.stock.pop();
			card.up = true;
			state.waste.push(card);
		}
	}
	state.selected = null;
	state.moves++;
	return true;
}

// Move the current selection to a tableau column or a foundation. Returns the
// score delta, or null when the move is not allowed.
function solitaireApply(state, target) {
	var sel = state.selected;
	if (!sel) { return null; }
	var take = null;
	var delta = 0;
	if (sel.zone === 'waste') {
		if (!state.waste.length) { return null; }
		take = { zone: 'waste', cards: [ state.waste[state.waste.length - 1] ] };
	}
	else if (sel.zone === 'tableau') {
		var from = state.tableau[sel.col];
		var run = from.slice(sel.idx);
		if (!solitaireRunOk(run)) { return null; }
		take = { zone: 'tableau', col: sel.col, cards: run };
	}
	else if (sel.zone === 'foundation') {
		var pile = state.foundations[sel.suit];
		if (!pile.length) { return null; }
		take = { zone: 'foundation', suit: sel.suit, cards: [ pile[pile.length - 1] ] };
	}
	if (!take) { return null; }

	if (target.zone === 'foundation') {
		if (take.cards.length !== 1) { return null; }
		if (!solitaireCanFoundation(take.cards[0], state.foundations[target.suit])) { return null; }
		delta = (take.zone === 'waste' || take.zone === 'tableau') ? 10 : 0;
	}
	else if (target.zone === 'tableau') {
		var dest = state.tableau[target.col];
		if (take.zone === 'tableau' && take.col === target.col) { return null; }
		if (!solitaireCanTableau(take.cards, dest.length ? dest[dest.length - 1] : null)) { return null; }
		delta = (take.zone === 'waste') ? 5 : (take.zone === 'foundation' ? -15 : 0);
	}
	else {
		return null;
	}

	solitairePushUndo(state);
	if (take.zone === 'waste') {
		state.waste.pop();
	}
	else if (take.zone === 'tableau') {
		state.tableau[take.col].splice(sel.idx);
	}
	else {
		state.foundations[take.suit].pop();
	}

	if (target.zone === 'foundation') {
		state.foundations[target.suit].push(take.cards[0]);
	}
	else {
		state.tableau[target.col] = state.tableau[target.col].concat(take.cards);
	}

	if (take.zone === 'tableau') {
		var rest = state.tableau[take.col];
		if (rest.length && !rest[rest.length - 1].up) {
			rest[rest.length - 1].up = true;
			delta += 5;
		}
	}

	state.bank += delta;
	state.moves++;
	state.selected = null;
	return delta;
}

// Could this selection land there? A throwaway copy answers without touching
// the real table, which the drag highlight uses on every pointer move.
function solitaireCanDrop(state, from, target) {
	// Only the layout is copied: the undo stack can hold sixty snapshots and
	// this runs on every pointer move while a card is in the air.
	var copy = JSON.parse(JSON.stringify({
		stock: state.stock,
		waste: state.waste,
		foundations: state.foundations,
		tableau: state.tableau,
		moves: 0,
		passes: 0,
		bank: state.bank,
		selected: from,
		undo: [],
		won: false
	}));
	return solitaireApply(copy, target) !== null;
}

// Double-click sends a single card to the foundation that will take it.
function solitaireSendToFoundation(state, from) {
	var card = null;
	if (from.zone === 'waste' && state.waste.length) { card = state.waste[state.waste.length - 1]; }
	else if (from.zone === 'tableau') {
		var pile = state.tableau[from.col];
		if (pile.length && from.idx === pile.length - 1) { card = pile[pile.length - 1]; }
	}
	if (!card) { return false; }
	for (var s = 0; s < 4; s++) {
		if (solitaireCanFoundation(card, state.foundations[s])) {
			state.selected = from.zone === 'waste' ? { zone: 'waste' } : { zone: 'tableau', col: from.col, idx: from.idx };
			return solitaireApply(state, { zone: 'foundation', suit: s }) !== null;
		}
	}
	return false;
}

// A card can go up without hurting the table when the opposite colour, one rank
// lower, is no longer available in the stock, the waste or the face-up tableau.
function solitaireSafeToFoundation(state, card) {
	if (!card || card.r <= 1) { return true; }
	var want = solitaireColor(card) === 'red' ? 'black' : 'red';
	var lower = card.r - 1;
	var matches = function(c) { return c && c.up && c.r === lower && solitaireColor(c) === want; };
	if (state.waste.some(matches)) { return false; }
	if (state.stock.some(matches)) { return false; }
	for (var col = 0; col < state.tableau.length; col++) {
		if (state.tableau[col].some(matches)) { return false; }
	}
	return true;
}

function solitaireAutoFinish(state) {
	var moved = 0;
	for (var guard = 0; guard < 200; guard++) {
		var did = false;
		if (state.waste.length) {
			var wasteCard = state.waste[state.waste.length - 1];
			for (var s = 0; s < 4 && !did; s++) {
				if (solitaireCanFoundation(wasteCard, state.foundations[s]) && solitaireSafeToFoundation(state, wasteCard)) {
					state.selected = { zone: 'waste' };
					did = solitaireApply(state, { zone: 'foundation', suit: s }) !== null;
				}
			}
		}
		for (var col = 0; col < 7 && !did; col++) {
			var pile = state.tableau[col];
			if (!pile.length) { continue; }
			var top = pile[pile.length - 1];
			for (var f = 0; f < 4 && !did; f++) {
				if (solitaireCanFoundation(top, state.foundations[f]) && solitaireSafeToFoundation(state, top)) {
					state.selected = { zone: 'tableau', col: col, idx: pile.length - 1 };
					did = solitaireApply(state, { zone: 'foundation', suit: f }) !== null;
				}
			}
		}
		if (!did) { break; }
		moved++;
	}
	return moved;
}

// ---- solitaire: the table --------------------------------------------------

function solitaireStatus(text) {
	var $status = $('#cards_solitaire #sol_status');
	if (!$status.length) { return; }
	$status.text(text);
	clearTimeout(solitaireStatusTimer);
	solitaireStatusTimer = setTimeout(function() {
		$('#cards_solitaire #sol_status').text(solitaireStatusDefault);
	}, 2200);
}

function solitaireSaveBank() {
	clearTimeout(solitaireSaveTimer);
	solitaireSaveTimer = setTimeout(function() {
		if (!solitaireState || typeof settingSetter !== 'function') { return; }
		settingSetter({ app: 'cards', setting: 'solitaire_bank', value: Math.round(solitaireState.bank) });
	}, 800);
}

function solitaireRender(state) {
	if (!state || !$('#cards_solitaire').length) { return; }
	$('#sol_bank').text(Math.round(state.bank));
	$('#sol_moves').text(state.moves);

	var $stock = $('#sol_stock').empty();
	if (state.stock.length) {
		$stock.append(solitaireCardHtml({ up: false, r: 0, s: 0 }))
			.append('<span class="sol_count">' + state.stock.length + '</span>');
	}
	else {
		$stock.append('<div class="sol_recycle">' + (state.waste.length ? '\u21bb' : '\u2014') + '</div>');
	}

	var $waste = $('#sol_waste').empty();
	if (!state.waste.length) {
		$waste.append('<div class="sol_slot">' + (window.jawnosT ? jawnosT('Waste') : 'Waste') + '</div>');
	}
	else {
		var shown = state.waste.slice(-SOL_DRAW);
		for (var w = 0; w < shown.length; w++) {
			var style = 'left:calc(var(--card-w) * ' + (w * 0.1).toFixed(2) + ');';
			var selected = (state.selected && state.selected.zone === 'waste' && w === shown.length - 1) ? ' sel' : '';
			$waste.append(solitaireCardHtml(shown[w], selected).replace('class="sol_card', 'data-zone="waste" style="' + style + '" class="sol_card'));
		}
	}

	for (var s = 0; s < 4; s++) {
		var $foundation = $('.sol_foundation[data-suit="' + s + '"]');
		$foundation.find('.sol_card').remove();
		var pile = state.foundations[s];
		if (pile.length) {
			$foundation.find('.sol_slot').hide();
			var selectedTop = (state.selected && state.selected.zone === 'foundation' && state.selected.suit === s) ? ' sel' : '';
			$foundation.append(solitaireCardHtml(pile[pile.length - 1], selectedTop).replace('class="sol_card', 'data-zone="foundation" data-suit="' + s + '" class="sol_card'));
		}
		else {
			$foundation.find('.sol_slot').show().text(SOL_SUITS[s]);
		}
	}

	for (var col = 0; col < 7; col++) {
		var $column = $('.sol_column[data-col="' + col + '"]');
		$column.find('.sol_card').remove();
		var cards = state.tableau[col];
		$column.find('.sol_slot').css('display', cards.length ? 'none' : 'flex');
		for (var i = 0; i < cards.length; i++) {
			var inRun = state.selected && state.selected.zone === 'tableau'
				&& state.selected.col === col && i >= state.selected.idx;
			var attrs = 'data-zone="tableau" data-col="' + col + '" data-idx="' + i + '"';
			$column.append(solitaireCardHtml(cards[i], inRun ? 'sel' : '').replace('class="sol_card', attrs + ' class="sol_card'));
		}
	}

	if (state.won) { solitaireShowWin(state); }
	else { $('#sol_win').removeClass('show'); }
}

function solitaireShowWin(state) {
	var $win = $('#sol_win');
	if (!$win.length) { return; }
	$('#sol_win_note').text((window.jawnosT ? jawnosT('A clear table in') : 'A clear table in') + ' '
		+ state.moves + ' ' + (window.jawnosT ? jawnosT('moves.') : 'moves.'));
	$win.addClass('show');
}

function solitaireCheckWin(state) {
	if (state.won || !solitaireWon(state)) { return; }
	state.won = true;
	state.bank += 500;
	solitaireStopClock(state);
	solitaireSaveBank();
	solitaireShowWin(state);
}

function solitaireTick() {
	if (!solitaireState || !solitaireState.startedAt) { return; }
	var seconds = Math.floor((Date.now() - solitaireState.startedAt) / 1000);
	var mins = Math.floor(seconds / 60);
	var secs = seconds % 60;
	$('#sol_time').text(mins + ':' + (secs < 10 ? '0' : '') + secs);
}

function solitaireStartClock(state) {
	if (state.timer) { clearInterval(state.timer); }
	state.startedAt = Date.now();
	state.timer = setInterval(solitaireTick, 1000);
	solitaireTick();
}

function solitaireStopClock(state) {
	if (state && state.timer) { clearInterval(state.timer); state.timer = null; }
}

function solitaireNewDeal(bank) {
	var state = solitaireDeal();
	state.bank = bank;
	solitaireStartClock(state);
	return state;
}

function solitaireEnsure() {
	var $root = $('#cards_solitaire');
	if (!$root.length) { return; }
	if (!solitaireState) {
		var bank = parseFloat($root.attr('data-bank'));
		if (isNaN(bank)) { bank = 0; }
		solitaireState = solitaireNewDeal(bank);
	}
	else if (!solitaireState.timer && !solitaireState.won) {
		solitaireStartClock(solitaireState);
	}
	solitaireStatusDefault = $('#sol_status').text();
	solitaireRender(solitaireState);
}

// One place for "do the move, redraw, remember the bank, look for a win".
function solitaireAction(mutate) {
	if (!solitaireState) { return; }
	var before = solitaireState.won;
	mutate(solitaireState);
	solitaireRender(solitaireState);
	if (!before) { solitaireCheckWin(solitaireState); }
	solitaireSaveBank();
}

// ---- solitaire: drag and drop ---------------------------------------------

function solitaireFromElement($el) {
	var zone = $el.attr('data-zone');
	if (zone === 'waste') { return { zone: 'waste' }; }
	if (zone === 'tableau') {
		return { zone: 'tableau', col: parseInt($el.attr('data-col'), 10), idx: parseInt($el.attr('data-idx'), 10) };
	}
	if (zone === 'foundation') {
		return { zone: 'foundation', suit: parseInt($el.attr('data-suit'), 10) };
	}
	return null;
}

function solitaireRunFor(state, from) {
	if (!state || !from) { return null; }
	if (from.zone === 'waste') {
		return state.waste.length ? [ state.waste[state.waste.length - 1] ] : null;
	}
	if (from.zone === 'tableau') {
		var pile = state.tableau[from.col];
		if (!pile || from.idx < 0 || from.idx >= pile.length) { return null; }
		return pile.slice(from.idx);
	}
	if (from.zone === 'foundation') {
		var found = state.foundations[from.suit];
		return found.length ? [ found[found.length - 1] ] : null;
	}
	return null;
}

function solitaireGhost(run) {
	var $ghost = $('<div class="sol_drag_ghost"></div>');
	for (var i = 0; i < run.length; i++) {
		var $card = $(solitaireCardHtml(run[i]));
		$card.css('top', 'calc(var(--card-h) * ' + (i * 0.22).toFixed(2) + ')');
		$ghost.append($card);
	}
	$ghost.css({ width: 'var(--card-w)', height: 'calc(var(--card-h) + var(--card-h) * ' + (Math.max(0, run.length - 1) * 0.22).toFixed(2) + ')' });
	return $ghost;
}

function solitaireDropTarget(x, y) {
	var el = document.elementFromPoint(x, y);
	if (!el) { return null; }
	var $target = $(el).closest('.sol_column, .sol_foundation');
	if (!$target.length) { return null; }
	if ($target.hasClass('sol_column')) {
		return { zone: 'tableau', col: parseInt($target.attr('data-col'), 10) };
	}
	return { zone: 'foundation', suit: parseInt($target.attr('data-suit'), 10) };
}

function solitaireDropAt(from, x, y) {
	if (!solitaireState) { return; }
	var target = solitaireDropTarget(x, y);
	if (!target) { return; }
	var landed = false;
	solitaireAction(function(state) {
		state.selected = from;
		landed = solitaireApply(state, target) !== null;
		if (!landed) { state.selected = null; }
	});
	if (!landed) {
		solitaireStatus(window.jawnosT ? jawnosT('That card will not go there.') : 'That card will not go there.');
	}
}

function solitaireHighlight(x, y) {
	$('.sol_column, .sol_foundation').removeClass('drop_ok drop_no');
	if (!solitaireState || !solitaireDrag || !solitaireDrag.from) { return; }
	var target = solitaireDropTarget(x, y);
	if (!target) { return; }
	var ok = solitaireCanDrop(solitaireState, solitaireDrag.from, target);
	var $el = (target.zone === 'tableau')
		? $('.sol_column[data-col="' + target.col + '"]')
		: $('.sol_foundation[data-suit="' + target.suit + '"]');
	$el.addClass(ok ? 'drop_ok' : 'drop_no');
}

// ---- mahjong: the rules ----------------------------------------------------

function mahjongFaces() {
	var faces = [];
	var numerals = [ '\u4e00', '\u4e8c', '\u4e09', '\u56db', '\u4e94', '\u516d', '\u4e03', '\u516b', '\u4e5d' ];
	var i;
	for (i = 0; i < 9; i++) { faces.push({ key: 'c' + (i + 1), glyph: numerals[i], label: '\u842c', cls: 'mj_char' }); }
	for (i = 0; i < 9; i++) { faces.push({ key: 'b' + (i + 1), glyph: numerals[i], label: '\u689d', cls: 'mj_bam' }); }
	for (i = 0; i < 9; i++) { faces.push({ key: 'd' + (i + 1), glyph: numerals[i], label: '\u7b52', cls: 'mj_dot' }); }
	var winds = [ '\u6771', '\u5357', '\u897f', '\u5317' ];
	for (i = 0; i < 4; i++) { faces.push({ key: 'w' + i, glyph: winds[i], label: '', cls: 'mj_wind' }); }
	var dragons = [ '\u4e2d', '\u767c', '\u767d' ];
	for (i = 0; i < 3; i++) { faces.push({ key: 'g' + i, glyph: dragons[i], label: '', cls: 'mj_dragon' }); }
	faces.push({ key: 'f0', glyph: '\u6885', label: '\u82b1', cls: 'mj_flower' });
	faces.push({ key: 'f1', glyph: '\u862d', label: '\u82b1', cls: 'mj_flower' });
	return faces;
}

function mahjongShuffle(list, rnd) {
	return solitaireShuffle(list, rnd);
}

// The turtle is five layers deep: 84 / 36 / 16 / 6 / 2 tiles, 144 in all. Every
// layer is a centred block so an upper tile sits over the one below it.
function mahjongPositions() {
	var positions = [];
	for (var layer = 0; layer < MAHJONG_LAYERS.length; layer++) {
		var spec = MAHJONG_LAYERS[layer];
		for (var row = 0; row < spec.rows; row++) {
			var count = spec.counts[row];
			var offset = spec.x + Math.floor((spec.cols - count) / 2);
			for (var col = 0; col < count; col++) {
				positions.push({ layer: layer, x: offset + col, y: spec.y + row });
			}
		}
	}
	return positions;
}

function mahjongDeal(rnd) {
	var faces = mahjongFaces();
	var deck = [];
	for (var i = 0; i < faces.length; i++) {
		for (var copy = 0; copy < 4; copy++) {
			deck.push({ key: faces[i].key, glyph: faces[i].glyph, label: faces[i].label, cls: faces[i].cls });
		}
	}
	mahjongShuffle(deck, rnd);
	var positions = mahjongPositions();
	var tiles = [];
	for (var p = 0; p < positions.length; p++) {
		var face = deck[p];
		tiles.push({
			id: p + 1,
			key: face.key,
			glyph: face.glyph,
			label: face.label,
			cls: face.cls,
			layer: positions[p].layer,
			x: positions[p].x,
			y: positions[p].y,
			removed: false
		});
	}
	return tiles;
}

// A tile is free when nothing is stacked over it and a neighbour is missing on
// at least one side of its row. Nothing sits on a lower layer unless it shares
// the same x/y, which is how the turtle's layers are built.
function mahjongCovered(tiles, index) {
	var tile = tiles[index];
	if (!tile) { return true; }
	for (var i = 0; i < tiles.length; i++) {
		var other = tiles[i];
		if (other.removed || other.layer <= tile.layer) { continue; }
		if (other.x === tile.x && other.y === tile.y) { return true; }
	}
	return false;
}

function mahjongFreeAt(tiles, index) {
	var tile = tiles[index];
	if (!tile || tile.removed) { return false; }
	if (mahjongCovered(tiles, index)) { return false; }
	var left = false;
	var right = false;
	for (var i = 0; i < tiles.length; i++) {
		var other = tiles[i];
		if (other.removed || other.layer !== tile.layer || other.y !== tile.y) { continue; }
		if (other.x === tile.x - 1) { left = true; }
		if (other.x === tile.x + 1) { right = true; }
	}
	return !left || !right;
}

function mahjongHasMove(tiles) {
	var seen = {};
	for (var i = 0; i < tiles.length; i++) {
		if (tiles[i].removed || !mahjongFreeAt(tiles, i)) { continue; }
		if (seen[tiles[i].key] !== undefined) { return true; }
		seen[tiles[i].key] = i;
	}
	return false;
}

function mahjongShuffleRemaining(tiles, rnd) {
	var faces = [];
	var slots = [];
	for (var i = 0; i < tiles.length; i++) {
		if (tiles[i].removed) { continue; }
		faces.push({ key: tiles[i].key, glyph: tiles[i].glyph, label: tiles[i].label, cls: tiles[i].cls });
		slots.push(i);
	}
	mahjongShuffle(faces, rnd);
	for (var j = 0; j < slots.length; j++) {
		var tile = tiles[slots[j]];
		var face = faces[j];
		tile.key = face.key;
		tile.glyph = face.glyph;
		tile.label = face.label;
		tile.cls = face.cls;
	}
	return tiles;
}

// ---- mahjong: the table ----------------------------------------------------

function mahjongTilesLeft(tiles) {
	var left = 0;
	for (var i = 0; i < tiles.length; i++) {
		if (!tiles[i].removed) { left++; }
	}
	return left;
}

function mahjongBanner(text) {
	var $banner = $('#mj_banner');
	if (!$banner.length) { return; }
	$banner.text(text);
	if (text !== mahjongBannerDefault) {
		setTimeout(function() { $('#mj_banner').text(mahjongBannerDefault); }, 2600);
	}
}

function mahjongRender() {
	var state = mahjongState;
	if (!state || !$('#cards_mahjong').length) { return; }
	var $board = $('#mj_board').empty();
	for (var i = 0; i < state.tiles.length; i++) {
		var tile = state.tiles[i];
		var free = mahjongFreeAt(state.tiles, i);
		var cls = 'mj_tile ' + tile.cls;
		if (!free) { cls += ' blocked'; }
		else { cls += ' free'; }
		if (tile.removed) { cls += ' gone'; }
		if (state.selected === i) { cls += ' sel'; }
		var left = (tile.x + tile.layer * 0.16).toFixed(2);
		var top = (tile.y - tile.layer * 0.16).toFixed(2);
		var $tile = $('<button type="button" class="' + cls + '" data-idx="' + i + '" data-layer="' + tile.layer + '"></button>');
		$tile.css({
			left: 'calc((var(--mj-tw) + var(--mj-gap)) * ' + left + ')',
			top: 'calc(var(--mj-pad) + (var(--mj-th) + var(--mj-gap)) * ' + top + ')',
			'z-index': tile.layer * 1000 + tile.y * 10 + tile.x
		});
		$tile.append($('<span class="mj_glyph"></span>').text(tile.glyph));
		if (tile.label) { $tile.append($('<span class="mj_label"></span>').text(tile.label)); }
		$board.append($tile);
	}
	$('#mj_left').text(mahjongTilesLeft(state.tiles));
	$('#mj_moves').text(state.moves);
}

function mahjongTick() {
	if (!mahjongState || !mahjongState.startedAt) { return; }
	var seconds = Math.floor((Date.now() - mahjongState.startedAt) / 1000);
	var mins = Math.floor(seconds / 60);
	var secs = seconds % 60;
	$('#mj_time').text(mins + ':' + (secs < 10 ? '0' : '') + secs);
}

function mahjongStartClock() {
	if (!mahjongState || mahjongState.startedAt || mahjongState.won) { return; }
	mahjongState.startedAt = Date.now();
	if (mahjongState.timer) { clearInterval(mahjongState.timer); }
	mahjongState.timer = setInterval(mahjongTick, 1000);
	mahjongTick();
}

function mahjongStopClock() {
	if (!mahjongState) { return; }
	if (mahjongState.timer) { clearInterval(mahjongState.timer); }
	mahjongState.timer = null;
}

function mahjongCheck() {
	var state = mahjongState;
	if (!state) { return; }
	if (mahjongTilesLeft(state.tiles) === 0) {
		state.won = true;
		mahjongStopClock();
		$('#mj_win_note').text((window.jawnosT ? jawnosT('Cleared in') : 'Cleared in') + ' '
			+ state.moves + ' ' + (window.jawnosT ? jawnosT('moves.') : 'moves.'));
		$('#mj_win').addClass('show');
		return;
	}
	if (!mahjongHasMove(state.tiles)) {
		mahjongBanner(window.jawnosT ? jawnosT('No free pair left - shuffling the rest.') : 'No free pair left - shuffling the rest.');
		setTimeout(function() {
			if (mahjongState !== state) { return; }
			mahjongShuffleRemaining(state.tiles);
			state.moves++;
			state.selected = null;
			mahjongRender();
		}, 900);
	}
}

function mahjongClick(index) {
	var state = mahjongState;
	if (!state || state.lock || state.won) { return; }
	var tile = state.tiles[index];
	if (!tile || tile.removed) { return; }
	mahjongStartClock();
	if (!mahjongFreeAt(state.tiles, index)) {
		mahjongBanner(window.jawnosT ? jawnosT('That tile is blocked.') : 'That tile is blocked.');
		$('.mj_tile[data-idx="' + index + '"]').addClass('shake');
		setTimeout(function() { $('.mj_tile[data-idx="' + index + '"]').removeClass('shake'); }, 320);
		return;
	}
	if (state.selected === index) {
		state.selected = null;
		mahjongRender();
		return;
	}
	if (state.selected === null) {
		state.selected = index;
		mahjongRender();
		return;
	}
	var first = state.tiles[state.selected];
	if (first && first.key === tile.key) {
		var other = state.selected;
		state.selected = null;
		state.lock = true;
		state.tiles[other].removed = true;
		tile.removed = true;
		state.moves++;
		$('.mj_tile[data-idx="' + other + '"], .mj_tile[data-idx="' + index + '"]').addClass('gone');
		setTimeout(function() {
			if (mahjongState !== state) { return; }
			state.lock = false;
			mahjongRender();
			mahjongCheck();
		}, 240);
		return;
	}
	state.selected = index;
	mahjongRender();
}

function mahjongNewGame() {
	if (!$('#cards_mahjong').length) { return; }
	mahjongStopClock();
	$('#mj_win').removeClass('show');
	mahjongState = {
		tiles: mahjongDeal(),
		selected: null,
		moves: 0,
		startedAt: 0,
		timer: null,
		lock: false,
		won: false
	};
	$('#mj_time').text('0:00');
	mahjongBannerDefault = $('#mj_banner').text();
	mahjongRender();
}

function mahjongEnsure() {
	if (!$('#cards_mahjong').length) { return; }
	if (!mahjongState) { mahjongNewGame(); return; }
	mahjongRender();
}

// ---- blackjack: the rules --------------------------------------------------

var BJ_BANK_START = 500;
var BJ_MIN_BET = 5;
var BJ_DECKS = 6;

function blackjackShoe(rnd) {
	var shoe = [];
	for (var d = 0; d < BJ_DECKS; d++) {
		for (var s = 0; s < 4; s++) {
			for (var r = 1; r <= 13; r++) {
				shoe.push({ r: r, s: s, up: true });
			}
		}
	}
	return solitaireShuffle(shoe, rnd);
}

// Aces count eleven until that would bust; the returned soft flag says whether
// one is still counted as eleven.
function blackjackValue(hand, onlyUp) {
	var total = 0;
	var aces = 0;
	for (var i = 0; i < hand.length; i++) {
		var card = hand[i];
		if (!card || (onlyUp && !card.up)) { continue; }
		if (card.r === 1) { total += 11; aces++; }
		else if (card.r >= 11) { total += 10; }
		else { total += card.r; }
	}
	while (total > 21 && aces > 0) { total -= 10; aces--; }
	return { total: total, soft: aces > 0 };
}

function blackjackDraw(state, up) {
	if (!state.shoe.length) { state.shoe = blackjackShoe(); }
	var card = state.shoe.pop();
	card.up = (up !== false);
	return card;
}

function blackjackNewState(bank) {
	return {
		shoe: blackjackShoe(),
		player: [],
		dealer: [],
		bet: 10,
		stake: 10,
		bank: (typeof bank === 'number' && !isNaN(bank)) ? bank : BJ_BANK_START,
		phase: 'bet',
		doubled: false,
		message: ''
	};
}

function blackjackNaturals(state) {
	var p = blackjackValue(state.player).total;
	var d = blackjackValue(state.dealer).total;
	var stake = state.stake;
	if (p === 21 && d === 21) {
		state.bank += stake;
		state.phase = 'done';
		state.message = 'Push. Both have blackjack.';
		return true;
	}
	if (p === 21) {
		state.bank += Math.round(stake * 2.5);
		state.phase = 'done';
		state.message = 'Blackjack!';
		return true;
	}
	if (d === 21) {
		state.phase = 'done';
		state.message = 'Dealer blackjack.';
		return true;
	}
	return false;
}

function blackjackStartHand(state) {
	if (!state || state.phase === 'player') { return false; }
	var stake = Number(state.bet) || BJ_MIN_BET;
	if (state.bank < stake) {
		state.message = 'Not enough in the bank for that bet.';
		return false;
	}
	if (!state.shoe.length) { state.shoe = blackjackShoe(); }
	state.stake = stake;
	state.player = [];
	state.dealer = [];
	state.doubled = false;
	state.message = '';
	state.phase = 'player';
	state.bank -= stake;
	// Player, dealer up, player, dealer hole: the usual order, so the hole card
	// is the last card of the dealer's hand.
	state.player.push(blackjackDraw(state, true));
	state.dealer.push(blackjackDraw(state, true));
	state.player.push(blackjackDraw(state, true));
	state.dealer.push(blackjackDraw(state, false));
	if (blackjackNaturals(state)) { return true; }
	return true;
}

function blackjackDealerPlay(state) {
	for (var i = 0; i < state.dealer.length; i++) { state.dealer[i].up = true; }
	while (blackjackValue(state.dealer).total < 17) {
		state.dealer.push(blackjackDraw(state, true));
	}
	var player = blackjackValue(state.player).total;
	var dealer = blackjackValue(state.dealer).total;
	if (dealer > 21 || player > dealer) {
		state.bank += state.stake * 2;
		state.message = dealer > 21 ? 'Dealer busts. You win.' : 'You win.';
	}
	else if (player === dealer) {
		state.bank += state.stake;
		state.message = 'Push.';
	}
	else {
		state.message = 'Dealer wins.';
	}
	state.phase = 'done';
}

function blackjackHit(state) {
	if (!state || state.phase !== 'player') { return false; }
	state.player.push(blackjackDraw(state, true));
	if (blackjackValue(state.player).total > 21) {
		state.phase = 'done';
		state.message = 'Bust.';
	}
	return true;
}

function blackjackStand(state) {
	if (!state || state.phase !== 'player') { return false; }
	blackjackDealerPlay(state);
	return true;
}

function blackjackDouble(state) {
	if (!state || state.phase !== 'player' || state.player.length !== 2) { return false; }
	if (state.bank < state.stake) {
		state.message = 'Not enough in the bank to double.';
		return false;
	}
	state.bank -= state.stake;
	state.stake = state.stake * 2;
	state.doubled = true;
	state.player.push(blackjackDraw(state, true));
	if (blackjackValue(state.player).total > 21) {
		state.phase = 'done';
		state.message = 'Bust.';
		return true;
	}
	blackjackDealerPlay(state);
	return true;
}

// ---- blackjack: the table --------------------------------------------------

function blackjackSaveBank() {
	clearTimeout(blackjackSaveTimer);
	blackjackSaveTimer = setTimeout(function() {
		if (!blackjackState || typeof settingSetter !== 'function') { return; }
		settingSetter({ app: 'cards', setting: 'blackjack_bank', value: Math.round(blackjackState.bank) });
	}, 800);
}

function blackjackRender() {
	var state = blackjackState;
	if (!state || !$('#cards_blackjack').length) { return; }
	var $dealer = $('#bj_dealer').empty();
	for (var d = 0; d < state.dealer.length; d++) {
		$dealer.append(solitaireCardHtml(state.dealer[d]));
	}
	var $player = $('#bj_player').empty();
	for (var p = 0; p < state.player.length; p++) {
		$player.append(solitaireCardHtml(state.player[p]));
	}
	var dealerView = blackjackValue(state.dealer, true);
	var playerView = blackjackValue(state.player);
	var soft = (window.jawnosT ? jawnosT('soft') : 'soft');
	$('#bj_dealer_total').text(state.dealer.length ? String(dealerView.total) + (dealerView.soft ? ' ' + soft : '') : '');
	$('#bj_player_total').text(state.player.length ? String(playerView.total) + (playerView.soft ? ' ' + soft : '') : '');
	$('#bj_bank').text(Math.round(state.bank));
	$('#bj_bet').text(state.phase === 'player' ? state.stake : state.bet);
	$('#bj_bet').closest('.bj_stat').toggleClass('disabled', state.phase === 'player');
	var playing = (state.phase === 'player');
	$('#bj_deal').prop('disabled', playing);
	$('#bj_hit').prop('disabled', !playing);
	$('#bj_stand').prop('disabled', !playing);
	$('#bj_double').prop('disabled', !playing || state.player.length !== 2 || state.bank < state.stake);
	$('.bj_chip').prop('disabled', playing);
	var message = state.message || (playing ? 'Hit or stand.' : 'Place your bet and deal.');
	if (state.phase === 'done' && state.bank < BJ_MIN_BET) {
		message += ' Out of chips - reset the bank.';
	}
	$('#bj_message').text(message);
}

function blackjackNewBank(bank) {
	blackjackState = blackjackNewState(bank);
	blackjackRender();
	blackjackSaveBank();
}

function blackjackEnsure() {
	if (!$('#cards_blackjack').length) { return; }
	if (!blackjackState) {
		var bank = parseFloat($('#cards_blackjack').attr('data-bank'));
		if (isNaN(bank)) { bank = BJ_BANK_START; }
		blackjackNewBank(bank);
		return;
	}
	blackjackRender();
}

// ---- tarot: the deck picker ------------------------------------------------

var cardsInterval = null;

function cardPicker(newCard) {
	if (!$('#deck_card').length) { return; }
	$('.card_description_icon').hide();
	$.ajax({
		url: '/manager/card_picker',
		type: 'GET',
		data: { timestamp: timestamp, new_card: newCard },
		success: function(response) {
			if (response.cards && response.cards.length) {
				cardsShowSpread(response.cards);
			}
			else if (response.stream) {
				cardsShowSingle(response.stream, null);
				$('#deck_card').css('height', 'auto');
			}
			else {
				cardsShowSingle(cardsCardUrl(response.filename), null);
			}
			if (response.title) { $('#card_title').html(cardsEscape(response.title)).show(); }
			else { $('#card_title').text(window.jawnosT ? jawnosT('Deck of cards') : 'Deck of cards').show(); }
			$('#card_description').text(response.description || '').hide();
			$('#deck_history').html($(response.html).find('#deck_history').html());
			if (typeof appointment_chron === 'function') { appointment_chron(); }
		}
	});
}

// ---- bindings --------------------------------------------------------------

if (typeof jQuery !== 'undefined') {
	$(document).on('click', '#cards_toggle', function() {
		$.ajax({
			url: '/manager/cards',
			type: 'GET',
			data: { timestamp: timestamp },
			success: function(response) {
				windowMaker(response);
				setTimeout(cardsInit, 200);
			}
		});
	});

	$(document).on('click', '#cards .cards_variant', function() {
		cardsShowVariant($(this).attr('data-variant'), true);
	});

	$(document).on('click', '#cards .cards_choice', function() {
		cardsShowVariant($(this).attr('data-variant'), true);
	});

	$(document).on('click', '#cards .cards_brand', function() {
		cardsShowVariant('', true);
	});

	$(document).on('click', '#cards .cards_mode', function() {
		var mode = $(this).attr('mode');
		$('#cards .cards_mode').attr('status', 'disabled');
		$(this).attr('status', 'enabled');
		if (typeof settingSetter === 'function') {
			settingSetter({ app: 'cards', setting: 'mode', value: mode });
		}
		clearInterval(cardsInterval);
		if (mode === 'cycle') {
			cardPicker();
			cardsInterval = setInterval(function() {
				if ($('#cards .cards_mode[mode="cycle"]').attr('status') === 'enabled' && $('#deck_card').is(':visible')) {
					cardPicker('new');
				}
				else {
					clearInterval(cardsInterval);
				}
			}, 180000);
		}
		else {
			cardPicker();
		}
	});

	$(document).on('click', '#deck_card', function() {
		cardPicker('new');
	});

	$(document).on('click', '#cards_deal', function() {
		cardPicker('new');
	});

	$(document).on('click', '#cards #deck_spread img', function() {
		cardPicker('new');
	});

	$(document).on('click', '#cards .history_draw', function(e) {
		e.stopPropagation();
		var draw = $(this);
		var names = draw.attr('data-cards');
		var title = draw.attr('data-title') || '';
		if (names) {
			cardsShowSpread(names.split('|'));
			$('#card_title').html(cardsEscape(title)).show();
			$('#card_description').hide();
		}
		else {
			cardsShowSingle(draw.attr('data-src'), title);
		}
	});

	$(document).on('click', '#cards #card_title', function() {
		$('#card_description').show();
		$('#card_title').hide();
	});

	$(document).on('click', '#cards #card_description', function() {
		$('#card_title').show();
		$('#card_description').hide();
	});

	$(document).on('click', '#cards .card_description_icon', function(e) {
		e.stopPropagation();
		var rn = $(this).closest('.history_draw').attr('rn');
		var description = $('.card_history_description[rn="' + rn + '"]').html();
		if (description) {
			$('#card_description').html(description).show();
			$('#card_title').hide();
		}
	});

	// ---- solitaire ----

	$(document).on('click', '#cards_solitaire #sol_stock', function() {
		solitaireAction(function(state) { solitaireDraw(state); });
	});

	$(document).on('click', '#cards_solitaire .sol_card, #cards_solitaire .sol_foundation, #cards_solitaire .sol_column', function(e) {
		if (!solitaireState || solitaireSuppressClick) { return; }
		// A card also matches its column/foundation through the delegated
		// selector; only the innermost match should act on the click.
		if (!$(this).is('.sol_card') && $(e.target).closest('.sol_card').length) { return; }
		var state = solitaireState;
		var $this = $(this);
		var zone = $this.attr('data-zone');
		if (!zone) { return; }

		if (zone === 'waste') {
			if (state.selected && state.selected.zone === 'waste') {
				state.selected = null;
				solitaireRender(state);
			}
			else {
				state.selected = { zone: 'waste' };
				solitaireRender(state);
			}
			return;
		}

		if (zone === 'foundation') {
			var suit = parseInt($this.attr('data-suit'), 10);
			if (state.selected) {
				var landed = false;
				solitaireAction(function(s) { landed = solitaireApply(s, { zone: 'foundation', suit: suit }) !== null; });
				if (!landed) { solitaireStatus(window.jawnosT ? jawnosT('That card will not go there.') : 'That card will not go there.'); }
			}
			else if (state.foundations[suit].length) {
				state.selected = { zone: 'foundation', suit: suit };
				solitaireRender(state);
			}
			return;
		}

		if (zone === 'tableau') {
			var col = parseInt($this.attr('data-col'), 10);
			var idx = $this.attr('data-idx');
			var isCard = idx !== undefined;
			idx = isCard ? parseInt(idx, 10) : state.tableau[col].length - 1;

			if (state.selected) {
				if (state.selected.zone === 'tableau' && state.selected.col === col && isCard) {
					state.selected = { zone: 'tableau', col: col, idx: idx };
					solitaireRender(state);
					return;
				}
				var moved = false;
				solitaireAction(function(s) { moved = solitaireApply(s, { zone: 'tableau', col: col }) !== null; });
				if (moved) { return; }
			}

			if (isCard) {
				var run = state.tableau[col].slice(idx);
				if (solitaireRunOk(run)) {
					state.selected = { zone: 'tableau', col: col, idx: idx };
					solitaireRender(state);
				}
				else {
					solitaireStatus(window.jawnosT ? jawnosT('Only a descending, alternating run moves together.') : 'Only a descending, alternating run moves together.');
				}
			}
			return;
		}
	});

	$(document).on('dblclick', '#cards_solitaire .sol_card', function(e) {
		e.stopPropagation();
		if (!solitaireState) { return; }
		var zone = $(this).attr('data-zone');
		var from = null;
		if (zone === 'waste') { from = { zone: 'waste' }; }
		else if (zone === 'tableau') {
			from = { zone: 'tableau', col: parseInt($(this).attr('data-col'), 10), idx: parseInt($(this).attr('data-idx'), 10) };
		}
		if (!from) { return; }
		var sent = false;
		solitaireAction(function(state) { sent = solitaireSendToFoundation(state, from); });
		if (!sent) { solitaireStatus(window.jawnosT ? jawnosT('No foundation takes that card yet.') : 'No foundation takes that card yet.'); }
	});

	$(document).on('pointerdown', '#cards_solitaire .sol_card', function(e) {
		if (!solitaireState || e.button !== 0) { return; }
		var from = solitaireFromElement($(this));
		if (!from || (from.zone !== 'waste' && from.zone !== 'tableau')) { return; }
		var run = solitaireRunFor(solitaireState, from);
		if (!run || !solitaireRunOk(run)) { return; }
		solitaireDrag = { from: from, x: e.clientX, y: e.clientY, started: false, ghost: null, run: run };
	});

	$(document).on('pointermove', function(e) {
		if (!solitaireDrag) { return; }
		if (!solitaireDrag.started) {
			if (Math.abs(e.clientX - solitaireDrag.x) < 6 && Math.abs(e.clientY - solitaireDrag.y) < 6) { return; }
			solitaireDrag.started = true;
			solitaireDrag.ghost = solitaireGhost(solitaireDrag.run);
			$('#cards').append(solitaireDrag.ghost);
			$(document.body).addClass('cards_dragging');
		}
		solitaireDrag.ghost.css({ left: (e.clientX + 12) + 'px', top: (e.clientY + 10) + 'px' });
		solitaireHighlight(e.clientX, e.clientY);
		if (e.preventDefault) { e.preventDefault(); }
	});

	$(document).on('pointerup', function(e) {
		if (!solitaireDrag) { return; }
		var drag = solitaireDrag;
		solitaireDrag = null;
		$(document.body).removeClass('cards_dragging');
		$('.sol_column, .sol_foundation').removeClass('drop_ok drop_no');
		if (!drag.ghost) { return; }
		drag.ghost.remove();
		solitaireSuppressClick = true;
		setTimeout(function() { solitaireSuppressClick = false; }, 60);
		solitaireDropAt(drag.from, e.clientX, e.clientY);
	});

	$(document).on('click', '#cards_solitaire #sol_new', function() {
		if (!solitaireState) { return; }
		solitaireState = solitaireNewDeal(solitaireState.bank);
		$('#sol_win').removeClass('show');
		solitaireRender(solitaireState);
	});

	$(document).on('click', '#cards_solitaire #sol_again', function() {
		$('#cards_solitaire #sol_new').trigger('click');
	});

	$(document).on('click', '#cards_solitaire #sol_undo', function() {
		if (!solitaireState) { return; }
		if (solitaireUndo(solitaireState)) {
			$('#sol_win').removeClass('show');
			solitaireRender(solitaireState);
			solitaireSaveBank();
		}
	});

	$(document).on('click', '#cards_solitaire #sol_auto', function() {
		if (!solitaireState) { return; }
		var moved = 0;
		solitaireAction(function(state) { moved = solitaireAutoFinish(state); });
		solitaireStatus((window.jawnosT ? jawnosT('Sent') : 'Sent') + ' ' + moved + ' ' + (window.jawnosT ? jawnosT('cards up.') : 'cards up.'));
	});

	$(document).on('click', '#cards_solitaire #sol_reset', function() {
		if (!solitaireState) { return; }
		var ask = window.jawnosT ? jawnosT('Reset the bank to zero?') : 'Reset the bank to zero?';
		if (window.confirm && !window.confirm(ask)) { return; }
		solitaireState.bank = 0;
		solitaireRender(solitaireState);
		solitaireSaveBank();
	});

	// ---- mahjong ----

	$(document).on('click', '#cards_mahjong .mj_tile', function() {
		mahjongClick(parseInt($(this).attr('data-idx'), 10));
	});

	$(document).on('click', '#cards_mahjong #mj_new', function() {
		mahjongNewGame();
	});

	$(document).on('click', '#cards_mahjong #mj_again', function() {
		mahjongNewGame();
	});

	$(document).on('click', '#cards_mahjong #mj_shuffle', function() {
		if (!mahjongState || mahjongState.won) { return; }
		mahjongShuffleRemaining(mahjongState.tiles);
		mahjongState.selected = null;
		mahjongState.moves++;
		mahjongState.lock = false;
		mahjongRender();
		mahjongCheck();
	});

	// ---- blackjack ----

	$(document).on('click', '#cards_blackjack #bj_deal', function() {
		if (!blackjackState) { return; }
		if (blackjackStartHand(blackjackState)) {
			blackjackRender();
			blackjackSaveBank();
		}
		else {
			blackjackRender();
		}
	});

	$(document).on('click', '#cards_blackjack #bj_hit', function() {
		if (!blackjackState) { return; }
		blackjackHit(blackjackState);
		blackjackRender();
	});

	$(document).on('click', '#cards_blackjack #bj_stand', function() {
		if (!blackjackState) { return; }
		blackjackStand(blackjackState);
		blackjackRender();
		blackjackSaveBank();
	});

	$(document).on('click', '#cards_blackjack #bj_double', function() {
		if (!blackjackState) { return; }
		blackjackDouble(blackjackState);
		blackjackRender();
		blackjackSaveBank();
	});

	$(document).on('click', '#cards_blackjack .bj_chip', function() {
		if (!blackjackState || blackjackState.phase === 'player') { return; }
		blackjackState.bet = parseInt($(this).attr('data-bet'), 10);
		blackjackState.message = '';
		blackjackRender();
	});

	$(document).on('click', '#cards_blackjack #bj_reset', function() {
		if (!blackjackState) { return; }
		var ask = window.jawnosT ? jawnosT('Reset the bank to 500?') : 'Reset the bank to 500?';
		if (window.confirm && !window.confirm(ask)) { return; }
		blackjackNewBank(BJ_BANK_START);
	});

	// An app window opened directly (not through the start menu) still needs its
	// table laid out; the toggle path calls the same init after its AJAX reply.
	$(function() {
		if ($('#cards').length) { cardsInit(); }
	});
}
