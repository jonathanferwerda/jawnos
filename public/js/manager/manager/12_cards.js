// The Cards app: five decks on one table.
//
// Tarot is the old deck of Jawn, drawn from the person's own days. Solitaire is
// Klondike with a three-card deal, the house's felt table and a bank that carries
// across rounds. Spider is the ten-column patience game, dealt from one, two or
// four suits. Mahjong is a multi-layer turtle of paired tiles. Blackjack is
// the casino table with chips and a running bank.
//
// The rules live in plain functions so they can be checked without a browser
// (t/116-cards-games.t); the event handlers at the bottom only wire them to the
// page. Every handler is delegated, because the app's window is rebuilt from an
// AJAX reply on each open.

var SOL_RANKS = [ '', 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K' ];
var SOL_SUITS = [ '\u2660', '\u2665', '\u2666', '\u2663' ];
var SOL_DRAW = 3;
var SPIDER_COLUMNS = 10;
var SPIDER_FOUNDATIONS = 8;
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
var solitaireLastClick = null;
var solitaireFitObserver = null;
var solitaireResizeBound = false;
var solitairePageHideBound = false;
var solitaireSuppressClick = false;
var spiderState = null;
var spiderStatusDefault = '';
var spiderStatusTimer = null;
var spiderDrag = null;
var spiderFitObserver = null;
var spiderResizeBound = false;
var spiderPageHideBound = false;
var spiderSuppressClick = false;
var mahjongState = null;
var mahjongBannerDefault = '';
var mahjongFitObserver = null;
var mahjongResizeBound = false;
var blackjackState = null;
var blackjackSaveTimer = null;
var blackjackFitObserver = null;
var blackjackResizeBound = false;
var tarotFitObserver = null;
var tarotResizeBound = false;
var cardsMode = '';

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
	tarotFit();
}

function cardsShowSingle(src, title) {
	$('#deck_spread').hide();
	if (src) { $('#deck_card').attr('src', src).show(); }
	if (title) { $('#card_title').html(cardsEscape(title)).show(); }
	$('#card_description').hide();
	tarotFit();
}

// ---- choosing a deck -------------------------------------------------------

var CARDS_VARIANTS = [ 'tarot', 'solitaire', 'spider', 'mahjong', 'blackjack' ];

// The four games save a Games play appointment the way the Controller's
// emulated games do; tarot is a reading, not a game.
var CARDS_GAME_NAMES = { solitaire: 'Solitaire', spider: 'Spider Solitaire', mahjong: 'Mahjong', blackjack: 'Blackjack' };
function cardsGameName(variant) { return CARDS_GAME_NAMES[variant] || ''; }
function cardsGameScreen(id) {
	return function() {
		var pane = document.getElementById(id);
		return !!pane && $(pane).is(':visible');

	};
}

function cardsShowVariant(variant, save) {
	var root = cardsRoot();
	if (!root) { return; }
	var known = (CARDS_VARIANTS.indexOf(variant) >= 0) ? variant : '';
	if (typeof jawnosGameSessionGame === 'function') {
		var running = jawnosGameSessionGame();
		var next = cardsGameName(known);
		// Tarot and the chooser are not play: keep the running session (it pauses
		// when its pane leaves the screen) so coming back resumes the same game.
		// Another game ends this one now, and a session under a minute is dropped.
		if (running && !next) { jawnosGameSessionPause(); }
		else if (running && running !== next) { jawnosGameSessionStop(); }
	}
	root.setAttribute('data-variant', known);
	$('.cards_variant', root).each(function() {
		$(this).toggleClass('active', $(this).attr('data-variant') === known);
	});
	$('#cards_tarot', root).toggleClass('active', known === 'tarot');
	$('#cards_solitaire', root).toggleClass('active', known === 'solitaire');
	$('#cards_spider', root).toggleClass('active', known === 'spider');
	$('#cards_mahjong', root).toggleClass('active', known === 'mahjong');
	$('#cards_blackjack', root).toggleClass('active', known === 'blackjack');
	$('#cards_chooser', root).toggleClass('open', !known);
	if (save && typeof settingSetter === 'function') {
		settingSetter({ app: 'cards', setting: 'variant', value: known });
	}
	if (known === 'solitaire') { solitaireEnsure(); }
	else if (known === 'spider') { spiderEnsure(); }
	else if (known === 'mahjong') { mahjongEnsure(); }
	else if (known === 'blackjack') { blackjackEnsure(); }
	else if (known === 'tarot') { cardPicker(); tarotEnsure(); }
}

function cardsInit() {
	var root = cardsRoot();
	if (!root) { return; }
	var variant = root.getAttribute('data-variant') || '';
	var enabled = $('.cards_mode[status="enabled"]', root).attr('mode');
	cardsMode = enabled || '';
	if (variant === 'solitaire') { solitaireEnsure(); }
	else if (variant === 'spider') { spiderEnsure(); }
	else if (variant === 'mahjong') { mahjongEnsure(); }
	else if (variant === 'blackjack') { blackjackEnsure(); }
	else if (variant === 'tarot') { cardPicker(); tarotEnsure(); }
}

// ---- playing cards ---------------------------------------------------------

function solitaireColor(card) {
	return (card.s === 1 || card.s === 2) ? 'red' : 'black';
}

// A printed deck counts itself: one suit emblem per pip, laid out the way a
// card does it, with the lower half turned over. The corner index says the rank
// and suit twice, so a card stays readable at a glance.
var SOL_PIP_LAYOUT = {
	2: [ [ 50, 20, 0 ], [ 50, 80, 1 ] ],
	3: [ [ 50, 20, 0 ], [ 50, 50, 0 ], [ 50, 80, 1 ] ],
	4: [ [ 30, 20, 0 ], [ 70, 20, 0 ], [ 30, 80, 1 ], [ 70, 80, 1 ] ],
	5: [ [ 30, 20, 0 ], [ 70, 20, 0 ], [ 50, 50, 0 ], [ 30, 80, 1 ], [ 70, 80, 1 ] ],
	6: [ [ 30, 20, 0 ], [ 70, 20, 0 ], [ 30, 50, 0 ], [ 70, 50, 0 ], [ 30, 80, 1 ], [ 70, 80, 1 ] ],
	7: [ [ 30, 20, 0 ], [ 70, 20, 0 ], [ 50, 35, 0 ], [ 30, 50, 0 ], [ 70, 50, 0 ], [ 30, 80, 1 ], [ 70, 80, 1 ] ],
	8: [ [ 30, 20, 0 ], [ 70, 20, 0 ], [ 50, 35, 0 ], [ 30, 50, 0 ], [ 70, 50, 0 ], [ 50, 65, 1 ], [ 30, 80, 1 ], [ 70, 80, 1 ] ],
	9: [ [ 30, 20, 0 ], [ 70, 20, 0 ], [ 30, 40, 0 ], [ 70, 40, 0 ], [ 50, 50, 0 ], [ 30, 60, 1 ], [ 70, 60, 1 ], [ 30, 80, 1 ], [ 70, 80, 1 ] ],
	10: [ [ 30, 20, 0 ], [ 70, 20, 0 ], [ 50, 30, 0 ], [ 30, 40, 0 ], [ 70, 40, 0 ], [ 30, 60, 1 ], [ 70, 60, 1 ], [ 50, 70, 1 ], [ 30, 80, 1 ], [ 70, 80, 1 ] ]
};

function solitairePips(card) {
	var suit = SOL_SUITS[card.s];
	if (card.r === 1) {
		return '<span class="sol_pip ace" aria-hidden="true">' + suit + '</span>';
	}
	if (card.r >= 11) {
		return '<span class="sol_pip face" aria-hidden="true"><b>' + SOL_RANKS[card.r] + '</b><i>' + suit + '</i></span>';
	}
	var layout = SOL_PIP_LAYOUT[card.r] || [];
	var html = '<span class="sol_pips" aria-hidden="true">';
	for (var i = 0; i < layout.length; i++) {
		html += '<i class="sol_pipmark' + (layout[i][2] ? ' flip' : '') + '"'
			+ ' style="left:' + layout[i][0] + '%;top:' + layout[i][1] + '%">' + suit + '</i>';
	}
	return html + '</span>';
}

function solitaireCardHtml(card, extra) {
	if (!card.up) {
		return '<div class="sol_card down ' + (extra || '') + '"></div>';
	}
	var suit = SOL_SUITS[card.s];
	var red = solitaireColor(card) === 'red' ? ' red' : '';
	var rank = SOL_RANKS[card.r];
	return '<div class="sol_card up' + red + ' ' + (extra || '') + '">'
		+ '<span class="sol_corner tl"><b>' + rank + '</b><i>' + suit + '</i></span>'
		+ solitairePips(card)
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

// Double-click sends a single card to its own foundation. The four piles are
// indexed by suit, so a heart always goes to the heart pile even when another
// pile is still empty.
function solitaireSendToFoundation(state, from) {
	var card = null;
	if (from.zone === 'waste' && state.waste.length) { card = state.waste[state.waste.length - 1]; }
	else if (from.zone === 'tableau') {
		var pile = state.tableau[from.col];
		if (pile.length && from.idx === pile.length - 1) { card = pile[pile.length - 1]; }
	}
	if (!card || !card.up) { return false; }
	if (!solitaireCanFoundation(card, state.foundations[card.s])) { return false; }
	state.selected = from.zone === 'waste' ? { zone: 'waste' } : { zone: 'tableau', col: from.col, idx: from.idx };
	return solitaireApply(state, { zone: 'foundation', suit: card.s }) !== null;
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
			if (solitaireCanFoundation(wasteCard, state.foundations[wasteCard.s]) && solitaireSafeToFoundation(state, wasteCard)) {
				state.selected = { zone: 'waste' };
				did = solitaireApply(state, { zone: 'foundation', suit: wasteCard.s }) !== null;
			}
		}
		for (var col = 0; col < 7 && !did; col++) {
			var pile = state.tableau[col];
			if (!pile.length) { continue; }
			var top = pile[pile.length - 1];
			if (solitaireCanFoundation(top, state.foundations[top.s]) && solitaireSafeToFoundation(state, top)) {
				state.selected = { zone: 'tableau', col: col, idx: pile.length - 1 };
				did = solitaireApply(state, { zone: 'foundation', suit: top.s }) !== null;
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
	solitaireFit();
	clearTimeout(solitaireStatusTimer);
	solitaireStatusTimer = setTimeout(function() {
		$('#cards_solitaire #sol_status').text(solitaireStatusDefault);
		solitaireFit();
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
			var style = 'left:calc(var(--card-w) * ' + (w * 0.22).toFixed(2) + ');';
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
	solitaireFit();
}

// Size the table from the window the game is in, not the screen: seven columns
// across, and the fan of the tallest column inside the board's height. The
// arithmetic is separate from the DOM so the rules test can check it.
function solitaireFitPlan(availW, availH, tableau) {
	var cols = 7;
	var gap = Math.max(2, Math.min(13, Math.round(availW * 0.012)));
	var w = Math.floor((availW - gap * (cols - 1)) / cols);
	w = Math.max(24, w);
	var widthW = w;
	var h = w * 1.42;
	var boardGap = Math.max(6, Math.round(h * 0.3));
	var columns = [];
	for (var c = 0; c < tableau.length; c++) {
		var pile = tableau[c] || [];
		var downCount = 0, upCount = 0;
		for (var i = 1; i < pile.length; i++) {
			if (pile[i].up) { upCount++; } else { downCount++; }
		}
		columns.push({ down: downCount, up: upCount });
	}
	// t is how generous the fan is: 0 is the tightest strip that still shows a
	// corner, 1 the comfortable one. Both ends scale with the card.
	function fanAt(t) {
		var down = h * (0.08 + t * 0.16);
		var up = h * (0.24 + t * 0.20);
		var worst = 0;
		for (var c = 0; c < columns.length; c++) {
			var column = h + columns[c].down * down + columns[c].up * up;
			if (column > worst) { worst = column; }
		}
		return { down: down, up: up, total: h + boardGap + worst };
	}
	var plan = fanAt(1);
	if (plan.total > availH) {
		var tight = fanAt(0);
		if (tight.total > availH) {
			// Even the tightest fan is too tall: the cards themselves shrink,
			// but no further than a readable size. If that still overflows, the
			// pane scrolls rather than hiding a card behind an unreadable one.
			var scale = availH / tight.total;
			w = Math.max(Math.min(30, widthW), Math.floor(widthW * scale));
			h = w * 1.42;
			boardGap = Math.max(6, Math.round(h * 0.3));
			plan = fanAt(0);
		}
		else {
			var lo = 0, hi = 1;
			for (var it = 0; it < 16; it++) {
				var mid = (lo + hi) / 2;
				if (fanAt(mid).total <= availH) { lo = mid; }
				else { hi = mid; }
			}
			plan = fanAt(lo);
		}
	}
	return {
		w: Math.round(w),
		h: Math.round(w * 1.42),
		gap: gap,
		boardGap: boardGap,
		down: Math.round(plan.down * 10) / 10,
		up: Math.round(plan.up * 10) / 10,
		total: Math.round(plan.total),
		fits: plan.total <= availH + 0.5
	};
}

function solitaireFit() {
	var pane = document.getElementById('cards_solitaire');
	if (!pane || !solitaireState) { return; }
	var hud = pane.querySelector('.sol_hud');
	if (!hud) { return; }
	// A hidden pane or a minimised window has nothing to fit yet.
	if (pane.clientWidth < 80 || pane.clientHeight < 120) { return; }
	var style = window.getComputedStyle(pane);
	var paddingX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
	var paddingY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
	var gap = parseFloat(style.rowGap);
	if (isNaN(gap)) { gap = 16; }
	var availW = pane.clientWidth - paddingX;
	var availH = pane.clientHeight - paddingY - hud.getBoundingClientRect().height - gap;
	if (availW < 80 || availH < 80) { return; }
	var plan = solitaireFitPlan(availW, availH, solitaireState.tableau);
	pane.style.setProperty('--card-w', plan.w + 'px');
	pane.style.setProperty('--card-h', plan.h + 'px');
	pane.style.setProperty('--sol-gap', plan.gap + 'px');
	pane.style.setProperty('--sol-board-gap', plan.boardGap + 'px');
	pane.style.setProperty('--sol-down', plan.down + 'px');
	pane.style.setProperty('--sol-up', plan.up + 'px');
	// The drag ghost is appended to the app root, not the pane. Carrying only
	// the width there lets the root's own --card-h derive the height, while a
	// blackjack hand still gets its own width and a matching height.
	var root = document.getElementById('cards');
	if (root) { root.style.setProperty('--card-w', plan.w + 'px'); }
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
	// A restored table keeps the time it had played; a fresh deal starts now.
	state.startedAt = state.startedAt || Date.now();
	state.timer = setInterval(solitaireTick, 1000);
	solitaireTick();
}

function solitaireStopClock(state) {
	if (!state) { return; }
	if (state.timer) { clearInterval(state.timer); state.timer = null; }
	state.stoppedAt = Date.now();
}

function solitaireNewDeal(bank) {
	var state = solitaireDeal();
	state.bank = bank;
	solitaireStartClock(state);
	return state;
}

// The table lives in this browser so a refresh, or a Cards window the manager
// restores, resumes the hand instead of dealing over it. Only the bank is a
// server setting; the cards themselves would be a settings write per move.
function solitaireCardOk(card) {
	return !!card && typeof card.r === 'number' && card.r >= 1 && card.r <= 13
		&& typeof card.s === 'number' && card.s >= 0 && card.s <= 3
		&& typeof card.up === 'boolean';
}

// A saved table is only trusted when it is a whole deck: seven columns, four
// foundations and every card exactly once.
function solitaireStateOk(state) {
	if (!state || !Array.isArray(state.stock) || !Array.isArray(state.waste)) { return false; }
	if (!Array.isArray(state.foundations) || state.foundations.length !== 4) { return false; }
	if (!Array.isArray(state.tableau) || state.tableau.length !== 7) { return false; }
	var seen = {};
	var total = 0;
	function pileOk(pile) {
		if (!Array.isArray(pile)) { return false; }
		for (var i = 0; i < pile.length; i++) {
			var card = pile[i];
			if (!solitaireCardOk(card)) { return false; }
			var key = card.s * 13 + card.r;
			if (seen[key]) { return false; }
			seen[key] = 1;
			total++;
		}
		return true;
	}
	if (!pileOk(state.stock) || !pileOk(state.waste)) { return false; }
	for (var f = 0; f < 4; f++) { if (!pileOk(state.foundations[f])) { return false; } }
	for (var c = 0; c < 7; c++) { if (!pileOk(state.tableau[c])) { return false; } }
	return total === 52;
}

function solitaireSaveState() {
	if (!solitaireState || typeof jawnosAppFieldSet !== 'function') { return; }
	var state = solitaireState;
	var end = (state.won && state.stoppedAt) ? state.stoppedAt : Date.now();
	var elapsed = state.startedAt ? Math.max(0, Math.floor((end - state.startedAt) / 1000)) : 0;
	try {
		jawnosAppFieldSet('cards', 'solitaire', JSON.stringify({
			v: 1,
			elapsed: elapsed,
			state: {
				stock: state.stock,
				waste: state.waste,
				foundations: state.foundations,
				tableau: state.tableau,
				moves: state.moves,
				passes: state.passes,
				bank: state.bank,
				won: state.won,
				undo: state.undo
			}
		}));
	}
	catch (e) {
		// a full or unavailable store must not stop the game
	}
}

function solitaireLoadState() {
	if (typeof jawnosAppFieldGet !== 'function') { return null; }
	var raw = null;
	try { raw = jawnosAppFieldGet('cards', 'solitaire'); } catch (e) { return null; }
	if (!raw) { return null; }
	var save = null;
	try { save = JSON.parse(raw); } catch (e) { return null; }
	if (!save || save.v !== 1 || !solitaireStateOk(save.state)) { return null; }
	var s = save.state;
	var elapsed = Number(save.elapsed);
	if (!isFinite(elapsed) || elapsed < 0) { elapsed = 0; }
	return {
		stock: s.stock,
		waste: s.waste,
		foundations: s.foundations,
		tableau: s.tableau,
		moves: Number(s.moves) || 0,
		passes: Number(s.passes) || 0,
		bank: Number(s.bank) || 0,
		selected: null,
		undo: Array.isArray(s.undo) ? s.undo : [],
		won: !!s.won,
		// Resume the clock at the time already played, not the wall time the
		// page spent closed; a finished table holds its final time.
		startedAt: elapsed > 0 ? Date.now() - elapsed * 1000 : 0,
		stoppedAt: s.won ? Date.now() : 0,
		timer: null
	};
}

function solitaireEnsure() {
	var $root = $('#cards_solitaire');
	if (!$root.length) { return; }
	// Opening the deck does not start a play appointment: the person may be
	// looking, or about to switch to another deck. The first touch on the pane
	// starts it (the pointerdown binding at the bottom).
	if (!solitaireState) {
		solitaireState = solitaireLoadState();
		if (!solitaireState) {
			var bank = parseFloat($root.attr('data-bank'));
			if (isNaN(bank)) { bank = 0; }
			solitaireState = solitaireNewDeal(bank);
		}
	}
	if (!solitaireState.won) {
		if (!solitaireState.timer) { solitaireStartClock(solitaireState); }
	}
	else {
		solitaireTick();
	}
	solitaireStatusDefault = $('#sol_status').text();
	solitaireRender(solitaireState);
	solitaireSaveState();
	if (!solitairePageHideBound) {
		solitairePageHideBound = true;
		window.addEventListener('pagehide', solitaireSaveState);
	}
	// The game lives in a window the person can resize; follow its box rather
	// than the screen. ResizeObserver covers the panel's own window drag; the
	// window listener is the fallback for engines without it.
	if (!solitaireResizeBound) {
		solitaireResizeBound = true;
		window.addEventListener('resize', solitaireFit);
	}
	// The window is rebuilt on each open, so re-attach to the pane that is here
	// now rather than the one the first open observed.
	if (typeof ResizeObserver === 'function') {
		var pane = document.getElementById('cards_solitaire');
		if (pane) {
			if (!solitaireFitObserver) {
				solitaireFitObserver = new ResizeObserver(function() { solitaireFit(); });
			}
			solitaireFitObserver.disconnect();
			solitaireFitObserver.observe(pane);
		}
	}
}

// One place for "do the move, redraw, remember the bank, look for a win".
function solitaireAction(mutate) {
	if (!solitaireState) { return; }
	solitaireLastClick = null;
	var before = solitaireState.won;
	mutate(solitaireState);
	solitaireRender(solitaireState);
	if (!before) { solitaireCheckWin(solitaireState); }
	solitaireSaveBank();
	solitaireSaveState();
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

// Where in the card the pointer landed. The ghost keeps that point under the
// pointer, so the card stays where it was grabbed rather than jumping to the
// pointer's bottom-right corner.
function solitaireGrabOffset(rect, x, y) {
	return { x: x - rect.left, y: y - rect.top };
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
	if (solitaireDrag && solitaireDrag.ghost) { solitaireDrag.ghost.removeClass('ok'); }
	if (!solitaireState || !solitaireDrag || !solitaireDrag.from) { return; }
	var target = solitaireDropTarget(x, y);
	if (!target) { return; }
	var ok = solitaireCanDrop(solitaireState, solitaireDrag.from, target);
	var $el = (target.zone === 'tableau')
		? $('.sol_column[data-col="' + target.col + '"]')
		: $('.sol_foundation[data-suit="' + target.suit + '"]');
	$el.addClass(ok ? 'drop_ok' : 'drop_no');
	if (ok && solitaireDrag.ghost) { solitaireDrag.ghost.addClass('ok'); }
}

// ---- spider: the rules -----------------------------------------------------

// Eight sets of A-K split over one, two or four suits. One suit is the easy
// table; two and four mix the deck so a run of one suit is harder to build,
// though a card still lands on any card one rank higher.
function spiderDeck(suits) {
	suits = (suits === 2 || suits === 4) ? suits : 1;
	var copies = 8 / suits;
	var deck = [];
	for (var s = 0; s < suits; s++) {
		for (var copy = 0; copy < copies; copy++) {
			for (var r = 1; r <= 13; r++) { deck.push({ r: r, s: s, up: false }); }
		}
	}
	return deck;
}

function spiderShuffle(list, rnd) {
	return solitaireShuffle(list, rnd);
}

// Ten columns: the first four take six cards, the last six take five, and the
// last card of every column is face up. Fifty cards stay in the stock, dealt
// ten at a time.
function spiderDeal(rnd, suits) {
	suits = (suits === 2 || suits === 4) ? suits : 1;
	var deck = spiderShuffle(spiderDeck(suits), rnd);
	var state = {
		suits: suits,
		stock: [],
		foundations: [],
		tableau: [],
		moves: 0,
		selected: null,
		undo: [],
		won: false,
		startedAt: 0,
		timer: null
	};
	for (var col = 0; col < SPIDER_COLUMNS; col++) {
		state.tableau.push([]);
		var count = col < 4 ? 6 : 5;
		for (var row = 0; row < count; row++) {
			var card = deck.pop();
			card.up = (row === count - 1);
			state.tableau[col].push(card);
		}
	}
	state.stock = deck;
	return state;
}

// A movable run is face up and descends by one in a single suit. Any card may
// land on a card one rank higher, whatever its suit; only a King starts an
// empty column.
function spiderRunOk(cards) {
	if (!cards || !cards.length) { return false; }
	for (var i = 0; i < cards.length; i++) {
		if (!cards[i].up) { return false; }
	}
	for (var j = 1; j < cards.length; j++) {
		if (cards[j].s !== cards[j - 1].s) { return false; }
		if (cards[j].r !== cards[j - 1].r - 1) { return false; }
	}
	return true;
}

function spiderCanTableau(run, destTop) {
	if (!run || !run.length) { return false; }
	if (!destTop) { return run[0].r === 13; }
	return run[0].r + 1 === destTop.r;
}

// A complete run at the top of a column - King down to Ace in one suit - leaves
// the table and counts toward the eight that win.
function spiderComplete(state) {
	var runs = 0;
	for (var col = 0; col < state.tableau.length; col++) {
		var pile = state.tableau[col];
		var start = pile.length - 13;
		if (start < 0) { continue; }
		if (pile[pile.length - 1].r !== 1) { continue; }
		var ok = true;
		for (var i = start; i < pile.length; i++) {
			if (!pile[i].up) { ok = false; break; }
		}
		if (ok) {
			for (var j = start + 1; j < pile.length; j++) {
				if (pile[j].s !== pile[start].s || pile[j].r !== pile[j - 1].r - 1) { ok = false; break; }
			}
		}
		if (!ok || pile[start].r !== 13) { continue; }
		var suit = pile[start].s;
		pile.splice(start, 13);
		state.foundations.push({ s: suit });
		if (pile.length && !pile[pile.length - 1].up) { pile[pile.length - 1].up = true; }
		runs++;
	}
	return runs;
}

function spiderWon(state) {
	return state.foundations.length >= SPIDER_FOUNDATIONS;
}

function spiderSnapshot(state) {
	return JSON.stringify({
		stock: state.stock,
		foundations: state.foundations,
		tableau: state.tableau,
		moves: state.moves
	});
}

function spiderPushUndo(state) {
	state.undo.push(spiderSnapshot(state));
	if (state.undo.length > 100) { state.undo.shift(); }
}

function spiderUndo(state) {
	if (!state.undo.length) { return false; }
	var saved = JSON.parse(state.undo.pop());
	state.stock = saved.stock;
	state.foundations = saved.foundations;
	state.tableau = saved.tableau;
	state.moves = saved.moves;
	state.selected = null;
	state.won = false;
	return true;
}

// Move the selected run to another column. Returns true when it lands; the
// completed runs are lifted and counted at the end of every move.
function spiderApply(state, from, targetCol) {
	if (!from || from.col === undefined) { return false; }
	if (targetCol === undefined || targetCol === from.col) { return false; }
	var pile = state.tableau[from.col];
	if (!pile || from.idx < 0 || from.idx >= pile.length) { return false; }
	var run = pile.slice(from.idx);
	if (!spiderRunOk(run)) { return false; }
	var dest = state.tableau[targetCol];
	if (!dest) { return false; }
	if (!spiderCanTableau(run, dest.length ? dest[dest.length - 1] : null)) { return false; }
	spiderPushUndo(state);
	pile.splice(from.idx);
	for (var i = 0; i < run.length; i++) { dest.push(run[i]); }
	if (pile.length && !pile[pile.length - 1].up) { pile[pile.length - 1].up = true; }
	state.moves++;
	state.selected = null;
	spiderComplete(state);
	return true;
}

// The stock deals a card to each column at once. A column with a gap stops the
// deal: the space has to be filled first.
function spiderDraw(state) {
	if (!state.stock.length) { return false; }
	for (var c = 0; c < SPIDER_COLUMNS; c++) {
		if (!state.tableau[c].length) { return false; }
	}
	spiderPushUndo(state);
	for (var col = 0; col < SPIDER_COLUMNS; col++) {
		var card = state.stock.pop();
		card.up = true;
		state.tableau[col].push(card);
	}
	state.moves++;
	state.selected = null;
	spiderComplete(state);
	return true;
}

// ---- spider: the table -----------------------------------------------------

function spiderStatus(text) {
	var $status = $('#cards_spider #spi_status');
	if (!$status.length) { return; }
	$status.text(text);
	spiderFit();
	clearTimeout(spiderStatusTimer);
	spiderStatusTimer = setTimeout(function() {
		$('#cards_spider #spi_status').text(spiderStatusDefault);
		spiderFit();
	}, 2200);
}

function spiderRender(state) {
	if (!state || !$('#cards_spider').length) { return; }
	$('#spi_runs').text(state.foundations.length);
	$('#spi_moves').text(state.moves);

	var $stock = $('#spi_stock').empty();
	if (state.stock.length) {
		$stock.append(solitaireCardHtml({ up: false, r: 0, s: 0 }))
			.append('<span class="sol_count">' + state.stock.length + '</span>');
	}
	else {
		$stock.append('<div class="sol_recycle">\u2014</div>');
	}

	for (var f = 0; f < SPIDER_FOUNDATIONS; f++) {
		var $foundation = $('.spi_foundation[data-foundation="' + f + '"]');
		$foundation.find('.sol_card').remove();
		var run = state.foundations[f];
		if (run) {
			$foundation.find('.sol_slot').hide();
			$foundation.append(solitaireCardHtml({ r: 13, s: run.s, up: true }));
		}
		else {
			$foundation.find('.sol_slot').show().text(f + 1);
		}
	}

	for (var col = 0; col < SPIDER_COLUMNS; col++) {
		var $column = $('.spi_column[data-col="' + col + '"]');
		$column.find('.sol_card').remove();
		var cards = state.tableau[col];
		$column.find('.sol_slot').css('display', cards.length ? 'none' : 'flex');
		for (var i = 0; i < cards.length; i++) {
			var inRun = state.selected && state.selected.col === col && i >= state.selected.idx;
			var attrs = 'data-zone="tableau" data-col="' + col + '" data-idx="' + i + '"';
			$column.append(solitaireCardHtml(cards[i], inRun ? 'sel' : '').replace('class="sol_card', attrs + ' class="sol_card'));
		}
	}

	if (state.won) { spiderShowWin(state); }
	else { $('#spi_win').removeClass('show'); }
	spiderFit();
}

// Ten columns share the window's width; the board is the stock/foundation row,
// a gap, then the tallest tableau column. The arithmetic is separate from the
// DOM so the rules test can check it.
function spiderFitPlan(availW, availH, tableau) {
	var cols = SPIDER_COLUMNS;
	var gap = Math.max(1, Math.min(10, Math.round(availW * 0.009)));
	var w = Math.floor((availW - gap * (cols - 1)) / cols);
	w = Math.max(18, w);
	var widthW = w;
	var h = w * 1.42;
	var boardGap = Math.max(5, Math.round(h * 0.28));
	var columns = [];
	for (var c = 0; c < tableau.length; c++) {
		var pile = tableau[c] || [];
		var downCount = 0, upCount = 0;
		for (var i = 1; i < pile.length; i++) {
			if (pile[i].up) { upCount++; } else { downCount++; }
		}
		columns.push({ down: downCount, up: upCount });
	}
	function fanAt(t) {
		var down = h * (0.08 + t * 0.16);
		var up = h * (0.24 + t * 0.20);
		var worst = 0;
		for (var c = 0; c < columns.length; c++) {
			var column = h + columns[c].down * down + columns[c].up * up;
			if (column > worst) { worst = column; }
		}
		return { down: down, up: up, total: h + boardGap + worst };
	}
	var plan = fanAt(1);
	if (plan.total > availH) {
		var tight = fanAt(0);
		if (tight.total > availH) {
			var scale = availH / tight.total;
			w = Math.max(Math.min(24, widthW), Math.floor(widthW * scale));
			h = w * 1.42;
			boardGap = Math.max(5, Math.round(h * 0.28));
			plan = fanAt(0);
		}
		else {
			var lo = 0, hi = 1;
			for (var it = 0; it < 16; it++) {
				var mid = (lo + hi) / 2;
				if (fanAt(mid).total <= availH) { lo = mid; }
				else { hi = mid; }
			}
			plan = fanAt(lo);
		}
	}
	return {
		w: Math.round(w),
		h: Math.round(w * 1.42),
		gap: gap,
		boardGap: boardGap,
		down: Math.round(plan.down * 10) / 10,
		up: Math.round(plan.up * 10) / 10,
		total: Math.round(plan.total),
		fits: plan.total <= availH + 0.5
	};
}

function spiderFit() {
	var pane = document.getElementById('cards_spider');
	if (!pane || !spiderState) { return; }
	var hud = pane.querySelector('.sol_hud');
	if (!hud) { return; }
	if (pane.clientWidth < 80 || pane.clientHeight < 120) { return; }
	var style = window.getComputedStyle(pane);
	var paddingX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
	var paddingY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
	var gap = parseFloat(style.rowGap);
	if (isNaN(gap)) { gap = 16; }
	var availW = pane.clientWidth - paddingX;
	var availH = pane.clientHeight - paddingY - hud.getBoundingClientRect().height - gap;
	if (availW < 80 || availH < 80) { return; }
	var plan = spiderFitPlan(availW, availH, spiderState.tableau);
	pane.style.setProperty('--card-w', plan.w + 'px');
	pane.style.setProperty('--card-h', plan.h + 'px');
	pane.style.setProperty('--spi-gap', plan.gap + 'px');
	pane.style.setProperty('--spi-board-gap', plan.boardGap + 'px');
	pane.style.setProperty('--sol-down', plan.down + 'px');
	pane.style.setProperty('--sol-up', plan.up + 'px');
	var root = document.getElementById('cards');
	if (root) { root.style.setProperty('--card-w', plan.w + 'px'); }
}

function spiderShowWin(state) {
	var $win = $('#spi_win');
	if (!$win.length) { return; }
	$('#spi_win_note').text((window.jawnosT ? jawnosT('Eight runs in') : 'Eight runs in') + ' '
		+ state.moves + ' ' + (window.jawnosT ? jawnosT('moves.') : 'moves.'));
	$win.addClass('show');
}

function spiderCheckWin(state) {
	if (state.won || !spiderWon(state)) { return; }
	state.won = true;
	spiderStopClock(state);
	spiderShowWin(state);
}

function spiderTick() {
	if (!spiderState || !spiderState.startedAt) { return; }
	var seconds = Math.floor((Date.now() - spiderState.startedAt) / 1000);
	var mins = Math.floor(seconds / 60);
	var secs = seconds % 60;
	$('#spi_time').text(mins + ':' + (secs < 10 ? '0' : '') + secs);
}

function spiderStartClock(state) {
	if (state.timer) { clearInterval(state.timer); }
	state.startedAt = state.startedAt || Date.now();
	state.timer = setInterval(spiderTick, 1000);
	spiderTick();
}

function spiderStopClock(state) {
	if (!state) { return; }
	if (state.timer) { clearInterval(state.timer); state.timer = null; }
	state.stoppedAt = Date.now();
}

function spiderNewDeal(suits) {
	var state = spiderDeal(undefined, suits);
	spiderStartClock(state);
	return state;
}

// A saved table is only trusted when it is a whole Spider pack: ten columns,
// eight runs at most, and no more copies of a card than the suit count dealt.
function spiderCardOk(card) {
	return !!card && typeof card.r === 'number' && card.r >= 1 && card.r <= 13
		&& typeof card.s === 'number' && card.s >= 0 && card.s <= 3
		&& typeof card.up === 'boolean';
}

function spiderStateOk(state) {
	if (!state || !Array.isArray(state.stock)) { return false; }
	if (!Array.isArray(state.foundations)) { return false; }
	if (!Array.isArray(state.tableau) || state.tableau.length !== SPIDER_COLUMNS) { return false; }
	var suits = state.suits;
	if (suits !== 1 && suits !== 2 && suits !== 4) { return false; }
	var copies = 8 / suits;
	var counts = {};
	var total = 0;
	function add(card) {
		if (!spiderCardOk(card) || card.s >= suits) { return false; }
		var key = card.s * 13 + card.r;
		counts[key] = (counts[key] || 0) + 1;
		if (counts[key] > copies) { return false; }
		total++;
		return true;
	}
	if (state.foundations.length > SPIDER_FOUNDATIONS) { return false; }
	for (var f = 0; f < state.foundations.length; f++) {
		var run = state.foundations[f];
		if (!run || typeof run.s !== 'number' || run.s < 0 || run.s >= suits) { return false; }
		for (var r = 1; r <= 13; r++) {
			var key = run.s * 13 + r;
			counts[key] = (counts[key] || 0) + 1;
			if (counts[key] > copies) { return false; }
		}
		total += 13;
	}
	function pileOk(pile) {
		if (!Array.isArray(pile)) { return false; }
		for (var i = 0; i < pile.length; i++) { if (!add(pile[i])) { return false; } }
		return true;
	}
	if (!pileOk(state.stock)) { return false; }
	for (var c = 0; c < SPIDER_COLUMNS; c++) { if (!pileOk(state.tableau[c])) { return false; } }
	return total === 104;
}

function spiderSaveState() {
	if (!spiderState || typeof jawnosAppFieldSet !== 'function') { return; }
	var state = spiderState;
	var end = (state.won && state.stoppedAt) ? state.stoppedAt : Date.now();
	var elapsed = state.startedAt ? Math.max(0, Math.floor((end - state.startedAt) / 1000)) : 0;
	try {
		jawnosAppFieldSet('cards', 'spider', JSON.stringify({
			v: 1,
			elapsed: elapsed,
			state: {
				suits: state.suits,
				stock: state.stock,
				foundations: state.foundations,
				tableau: state.tableau,
				moves: state.moves,
				won: state.won,
				undo: state.undo
			}
		}));
	}
	catch (e) {
		// a full or unavailable store must not stop the game
	}
}

function spiderLoadState() {
	if (typeof jawnosAppFieldGet !== 'function') { return null; }
	var raw = null;
	try { raw = jawnosAppFieldGet('cards', 'spider'); } catch (e) { return null; }
	if (!raw) { return null; }
	var save = null;
	try { save = JSON.parse(raw); } catch (e) { return null; }
	if (!save || save.v !== 1 || !spiderStateOk(save.state)) { return null; }
	var s = save.state;
	var elapsed = Number(save.elapsed);
	if (!isFinite(elapsed) || elapsed < 0) { elapsed = 0; }
	return {
		suits: s.suits,
		stock: s.stock,
		foundations: s.foundations,
		tableau: s.tableau,
		moves: Number(s.moves) || 0,
		selected: null,
		undo: Array.isArray(s.undo) ? s.undo : [],
		won: !!s.won,
		startedAt: elapsed > 0 ? Date.now() - elapsed * 1000 : 0,
		stoppedAt: s.won ? Date.now() : 0,
		timer: null
	};
}

function spiderEnsure() {
	var $root = $('#cards_spider');
	if (!$root.length) { return; }
	// The first touch starts the play appointment, not the open.
	if (!spiderState) {
		spiderState = spiderLoadState();
		if (!spiderState) { spiderState = spiderNewDeal(1); }
	}
	if (!spiderState.won) {
		if (!spiderState.timer) { spiderStartClock(spiderState); }
	}
	else {
		spiderTick();
	}
	spiderStatusDefault = $('#spi_status').text();
	var $suits = $('#spi_suits');
	if ($suits.length) { $suits.val(String(spiderState.suits)); }
	spiderRender(spiderState);
	spiderSaveState();
	if (!spiderPageHideBound) {
		spiderPageHideBound = true;
		window.addEventListener('pagehide', spiderSaveState);
	}
	if (!spiderResizeBound) {
		spiderResizeBound = true;
		window.addEventListener('resize', spiderFit);
	}
	if (typeof ResizeObserver === 'function') {
		var pane = document.getElementById('cards_spider');
		if (pane) {
			if (!spiderFitObserver) {
				spiderFitObserver = new ResizeObserver(function() { spiderFit(); });
			}
			spiderFitObserver.disconnect();
			spiderFitObserver.observe(pane);
		}
	}
}

function spiderAction(mutate) {
	if (!spiderState) { return; }
	var before = spiderState.won;
	mutate(spiderState);
	spiderRender(spiderState);
	if (!before) { spiderCheckWin(spiderState); }
	spiderSaveState();
}

// ---- spider: drag and drop -------------------------------------------------

function spiderDropTarget(x, y) {
	var el = document.elementFromPoint(x, y);
	if (!el) { return null; }
	var $target = $(el).closest('.spi_column');
	if (!$target.length) { return null; }
	return { col: parseInt($target.attr('data-col'), 10) };
}

function spiderDropAt(from, x, y) {
	if (!spiderState) { return; }
	var target = spiderDropTarget(x, y);
	if (!target) { return; }
	var landed = false;
	spiderAction(function(state) {
		state.selected = from;
		landed = spiderApply(state, from, target.col);
		if (!landed) { state.selected = null; }
	});
	if (!landed) {
		spiderStatus(window.jawnosT ? jawnosT('That run will not go there.') : 'That run will not go there.');
	}
}

function spiderHighlight(x, y) {
	$('.spi_column').removeClass('drop_ok drop_no');
	if (spiderDrag && spiderDrag.ghost) { spiderDrag.ghost.removeClass('ok'); }
	if (!spiderState || !spiderDrag || !spiderDrag.from) { return; }
	var target = spiderDropTarget(x, y);
	if (!target) { return; }
	var run = spiderState.tableau[spiderDrag.from.col].slice(spiderDrag.from.idx);
	var dest = spiderState.tableau[target.col];
	var ok = target.col !== spiderDrag.from.col && spiderRunOk(run)
		&& spiderCanTableau(run, dest.length ? dest[dest.length - 1] : null);
	var $el = $('.spi_column[data-col="' + target.col + '"]');
	$el.addClass(ok ? 'drop_ok' : 'drop_no');
	if (ok && spiderDrag.ghost) { spiderDrag.ghost.addClass('ok'); }
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

// The turtle spans thirteen tile-columns (the twelve of the board plus the
// layered overhang) and eight rows; the plan takes whichever of width and
// height is tighter so the tiles grow with the window instead of topping out
// at a fixed size.
function mahjongFitPlan(availW, availH) {
	var boardW = 13 + 12 * 0.08;
	var boardH = 1.04 + 8 * 1.38;
	var byWidth = availW / boardW;
	var byHeight = availH / boardH;
	var tw = Math.floor(Math.min(byWidth, byHeight));
	tw = Math.max(15, tw);
	return {
		tw: tw,
		th: Math.round(tw * 1.3),
		gap: Math.round(tw * 0.08),
		pad: Math.round(tw * 1.3 * 0.8),
		fits: Math.min(byWidth, byHeight) >= 15
	};
}

function mahjongFit() {
	var pane = document.getElementById('cards_mahjong');
	if (!pane || !mahjongState) { return; }
	if (pane.clientWidth < 80 || pane.clientHeight < 120) { return; }
	var hud = pane.querySelector('.mj_hud');
	var banner = pane.querySelector('.mj_banner');
	if (!hud) { return; }
	var style = window.getComputedStyle(pane);
	var paddingX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
	var paddingY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
	var gap = parseFloat(style.rowGap);
	if (isNaN(gap)) { gap = 12; }
	var fixed = hud.getBoundingClientRect().height + gap * 2;
	if (banner) { fixed += banner.getBoundingClientRect().height; }
	var availW = pane.clientWidth - paddingX;
	var availH = pane.clientHeight - paddingY - fixed;
	if (availW < 80 || availH < 80) { return; }
	var plan = mahjongFitPlan(availW, availH);
	pane.style.setProperty('--mj-tw', plan.tw + 'px');
	pane.style.setProperty('--mj-th', plan.th + 'px');
	pane.style.setProperty('--mj-gap', plan.gap + 'px');
	pane.style.setProperty('--mj-pad', plan.pad + 'px');
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
	mahjongFit();
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
	// The first touch starts the play appointment, not the open.
	if (!mahjongState) { mahjongNewGame(); }
	else { mahjongRender(); }
	if (!mahjongResizeBound) {
		mahjongResizeBound = true;
		window.addEventListener('resize', mahjongFit);
	}
	if (typeof ResizeObserver === 'function') {
		var pane = document.getElementById('cards_mahjong');
		if (pane) {
			if (!mahjongFitObserver) {
				mahjongFitObserver = new ResizeObserver(function() { mahjongFit(); });
			}
			mahjongFitObserver.disconnect();
			mahjongFitObserver.observe(pane);
		}
	}
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

// A hand overlaps its cards by .62, so n cards span 1.24 + .38n card widths
// including the hand's left pad. The plan takes the tighter of that width and
// the height of the two hand rows, so a maximised table grows its cards.
function blackjackFitPlan(availW, availH, maxCards) {
	var n = Math.max(2, maxCards || 2);
	var handW = 1.24 + 0.38 * n;
	var byWidth = availW / handW;
	var byHeight = availH / 2 / 1.42;
	var w = Math.floor(Math.min(byWidth, byHeight));
	w = Math.max(38, w);
	return { w: w, h: Math.round(w * 1.42), fits: Math.min(byWidth, byHeight) >= 38 };
}

function blackjackFit() {
	var pane = document.getElementById('cards_blackjack');
	if (!pane || !blackjackState) { return; }
	if (pane.clientWidth < 80 || pane.clientHeight < 120) { return; }
	var table = pane.querySelector('.bj_table');
	var hud = pane.querySelector('.bj_hud');
	var actions = pane.querySelector('.bj_actions');
	var divider = pane.querySelector('.bj_divider');
	if (!table || !hud || !actions || !divider) { return; }
	var style = window.getComputedStyle(pane);
	var paddingX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
	var paddingY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
	var tableGap = parseFloat(window.getComputedStyle(table).rowGap);
	if (isNaN(tableGap)) { tableGap = 10; }
	var handGap = parseFloat(window.getComputedStyle(pane.querySelector('.bj_dealer')).rowGap);
	if (isNaN(handGap)) { handGap = 8; }
	// Four gaps between the HUD, dealer, divider, player and actions, plus the
	// heading and gap inside each of the two hands.
	var fixed = hud.getBoundingClientRect().height
		+ actions.getBoundingClientRect().height
		+ divider.getBoundingClientRect().height
		+ tableGap * 4 + handGap * 2;
	var headings = pane.querySelectorAll('.bj_dealer h3, .bj_player h3');
	for (var i = 0; i < headings.length; i++) { fixed += headings[i].getBoundingClientRect().height; }
	var availW = pane.clientWidth - paddingX;
	var availH = pane.clientHeight - paddingY - fixed;
	if (availW < 80 || availH < 80) { return; }
	var maxCards = Math.max(blackjackState.dealer.length, blackjackState.player.length, 2);
	var plan = blackjackFitPlan(availW, availH, maxCards);
	pane.style.setProperty('--card-w', plan.w + 'px');
	pane.style.setProperty('--card-h', plan.h + 'px');
	var root = document.getElementById('cards');
	if (root) { root.style.setProperty('--card-w', plan.w + 'px'); }
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
	blackjackFit();
}

function blackjackNewBank(bank) {
	blackjackState = blackjackNewState(bank);
	blackjackRender();
	blackjackSaveBank();
}

function blackjackEnsure() {
	if (!$('#cards_blackjack').length) { return; }
	// The first touch starts the play appointment, not the open.
	if (!blackjackState) {
		var bank = parseFloat($('#cards_blackjack').attr('data-bank'));
		if (isNaN(bank)) { bank = BJ_BANK_START; }
		blackjackNewBank(bank);
	}
	else {
		blackjackRender();
	}
	if (!blackjackResizeBound) {
		blackjackResizeBound = true;
		window.addEventListener('resize', blackjackFit);
	}
	if (typeof ResizeObserver === 'function') {
		var pane = document.getElementById('cards_blackjack');
		if (pane) {
			if (!blackjackFitObserver) {
				blackjackFitObserver = new ResizeObserver(function() { blackjackFit(); });
			}
			blackjackFitObserver.disconnect();
			blackjackFitObserver.observe(pane);
		}
	}
}

// ---- tarot: the picture fills the stage -----------------------------------

// The deck files are only a few hundred pixels wide, so shrinking from their
// own size leaves a maximised window mostly felt. Fit the picture - or the
// three-card spread - to the stage instead, keeping the picture's own shape.
function tarotFitPlan(availW, availH, count, ratio) {
	count = Math.max(1, count || 1);
	ratio = (ratio > 0) ? ratio : 220 / 331;
	var gap = (count > 1) ? Math.max(8, Math.min(22, availW * 0.016)) : 0;
	var maxW = (availW - gap * (count - 1)) / count;
	var w = Math.min(maxW, availH * ratio);
	if (!(w > 0)) { w = 1; }
	w = Math.floor(w);
	return { w: w, h: Math.floor(w / ratio), gap: Math.round(gap) };
}

function tarotSize(img, w, h) {
	// The box is the exact picture size, so the gold hairline and the shadow
	// stay on the card rather than around an empty letterbox.
	img.style.maxWidth = 'none';
	img.style.maxHeight = 'none';
	img.style.width = w + 'px';
	img.style.height = h + 'px';
}

function tarotWatch(img) {
	if (!img || img.complete) { return; }
	$(img).off('load.tarotfit').one('load.tarotfit', tarotFit);
}

function tarotFit() {
	var art = document.querySelector('#cards .tarot_art');
	if (!art) { return; }
	var availW = art.clientWidth;
	var availH = art.clientHeight;
	if (availW < 40 || availH < 60) { return; }
	var spread = document.getElementById('deck_spread');
	var single = document.getElementById('deck_card');
	var ratio = 0;
	if (spread && spread.style.display !== 'none') {
		var cards = spread.querySelectorAll('img');
		if (cards.length) {
			if (cards[0].naturalWidth && cards[0].naturalHeight) {
				ratio = cards[0].naturalWidth / cards[0].naturalHeight;
			}
			var plan = tarotFitPlan(availW, availH, cards.length, ratio);
			$(spread).css('gap', plan.gap + 'px');
			for (var i = 0; i < cards.length; i++) {
				tarotSize(cards[i], plan.w, plan.h);
				tarotWatch(cards[i]);
			}
		}
	}
	if (single && single.style.display !== 'none') {
		if (single.naturalWidth && single.naturalHeight) {
			ratio = single.naturalWidth / single.naturalHeight;
		}
		var one = tarotFitPlan(availW, availH, 1, ratio);
		tarotSize(single, one.w, one.h);
		tarotWatch(single);
	}
}

function tarotEnsure() {
	if (!$('#deck_card').length) { return; }
	if (!tarotResizeBound) {
		tarotResizeBound = true;
		window.addEventListener('resize', tarotFit);
	}
	if (typeof ResizeObserver === 'function') {
		var art = document.querySelector('#cards .tarot_art');
		if (art) {
			if (!tarotFitObserver) {
				tarotFitObserver = new ResizeObserver(function() { tarotFit(); });
			}
			tarotFitObserver.disconnect();
			tarotFitObserver.observe(art);
		}
	}
	tarotFit();
}

// ---- tarot: the deck picker ------------------------------------------------

var cardsInterval = null;

function cardPicker(newCard) {
	if (!$('#deck_card').length) { return; }
	$('.card_description_icon').hide();
	$.ajax({
		url: '/manager/card_picker',
		type: 'GET',
		data: { timestamp: timestamp, new_card: newCard, mode: cardsMode },
		success: function(response) {
			if (response.cards && response.cards.length) {
				cardsShowSpread(response.cards);
			}
			else if (response.stream) {
				cardsShowSingle(response.stream, null);
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

	// The first touch in a game starts its play appointment; later touches keep
	// it alive and the clock pauses it when the game goes quiet.
	$(document).on('pointerdown', '#cards_solitaire, #cards_spider, #cards_mahjong, #cards_blackjack', function() {
		if (typeof jawnosGameSessionStart !== 'function') { return; }
		var variant = (this.id || '').replace(/^cards_/, '');
		var game = cardsGameName(variant);
		if (game) { jawnosGameSessionStart(game, cardsGameScreen(this.id)); }
	});

	$(document).on('click', '#cards .cards_mode', function() {
		var mode = $(this).attr('mode');
		cardsMode = mode;
		$('#cards .cards_mode').attr('status', 'disabled');
		$(this).attr('status', 'enabled');
		if (typeof settingSetter === 'function') {
			settingSetter({ app: 'cards', setting: 'mode', value: mode });
		}
		clearInterval(cardsInterval);
		// Draw in the mode just chosen, so one press shows the day's card (or a
		// free/cycle draw) instead of waiting for a second press.
		if (mode === 'cycle') {
			cardPicker('new');
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
			// The whole deck is a browsing rail, not a draw.
			cardPicker(mode === 'all' ? undefined : 'new');
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

		// A double click is read from the pair of clicks, not the browser's
		// dblclick event: choosing a card redraws the board, so by the time
		// dblclick is dispatched its node is detached and the delegated handler
		// never sees it. The click pair survives the redraw.
		if ($this.is('.sol_card') && (zone === 'waste' || zone === 'tableau')) {
			var from = solitaireFromElement($this);
			var key = (zone === 'tableau') ? 'tableau:' + from.col + ':' + from.idx : 'waste';
			var now = Date.now();
			if (solitaireLastClick && solitaireLastClick.key === key
				&& now - solitaireLastClick.at <= 500
				&& Math.abs(e.clientX - solitaireLastClick.x) <= 8
				&& Math.abs(e.clientY - solitaireLastClick.y) <= 8) {
				solitaireLastClick = null;
				var sent = false;
				solitaireAction(function(s) { sent = solitaireSendToFoundation(s, from); });
				if (sent) { return; }
			}
			else {
				solitaireLastClick = { key: key, at: now, x: e.clientX, y: e.clientY };
			}
		}

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

	$(document).on('pointerdown', '#cards_solitaire .sol_card', function(e) {
		if (!solitaireState || e.button !== 0) { return; }
		var from = solitaireFromElement($(this));
		if (!from || (from.zone !== 'waste' && from.zone !== 'tableau')) { return; }
		var run = solitaireRunFor(solitaireState, from);
		if (!run || !solitaireRunOk(run)) { return; }
		// The waste always moves its top card, even when an under-card's sliver
		// was grabbed; anchor the ghost to the card that will actually move.
		var anchor = this;
		if (from.zone === 'waste') {
			var top = $('#sol_waste .sol_card').last()[0];
			if (top) { anchor = top; }
		}
		var grab = solitaireGrabOffset(anchor.getBoundingClientRect(), e.clientX, e.clientY);
		solitaireDrag = { from: from, x: e.clientX, y: e.clientY, grabX: grab.x, grabY: grab.y, started: false, ghost: null, run: run };
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
		solitaireDrag.ghost.css({ left: (e.clientX - solitaireDrag.grabX) + 'px', top: (e.clientY - solitaireDrag.grabY) + 'px' });
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
		solitaireSaveState();
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
			solitaireSaveState();
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
		jawnosConfirm(ask, function() {
			solitaireState.bank = 0;
			solitaireRender(solitaireState);
			solitaireSaveBank();
			solitaireSaveState();
		});
	});

	// ---- spider ----

	$(document).on('click', '#cards_spider #spi_stock', function() {
		if (!spiderState) { return; }
		if (!spiderState.stock.length) {
			spiderStatus(window.jawnosT ? jawnosT('The stock is empty.') : 'The stock is empty.');
			return;
		}
		var drew = false;
		spiderAction(function(state) { drew = spiderDraw(state); });
		if (!drew) {
			spiderStatus(window.jawnosT ? jawnosT('Fill the empty column before dealing.') : 'Fill the empty column before dealing.');
		}
	});

	$(document).on('click', '#cards_spider .sol_card, #cards_spider .spi_column', function(e) {
		if (!spiderState || spiderSuppressClick) { return; }
		if (!$(this).is('.sol_card') && $(e.target).closest('.sol_card').length) { return; }
		var $this = $(this);
		var col = parseInt($this.attr('data-col'), 10);
		if (isNaN(col)) { return; }
		var idxAttr = $this.attr('data-idx');
		var idx = (idxAttr === undefined) ? undefined : parseInt(idxAttr, 10);
		var state = spiderState;

		if (state.selected) {
			if (idx !== undefined && state.selected.col === col && state.selected.idx === idx) {
				state.selected = null;
				spiderRender(state);
				return;
			}
			var moved = false;
			spiderAction(function(s) { s.selected = state.selected; moved = spiderApply(s, state.selected, col); });
			if (moved) { return; }
		}

		if (idx === undefined) { return; }
		var run = state.tableau[col].slice(idx);
		if (spiderRunOk(run)) {
			state.selected = { col: col, idx: idx };
			spiderRender(state);
		}
		else {
			spiderStatus(window.jawnosT ? jawnosT('Only a same-suit run moves together.') : 'Only a same-suit run moves together.');
		}
	});

	$(document).on('pointerdown', '#cards_spider .sol_card', function(e) {
		if (!spiderState || e.button !== 0) { return; }
		var col = parseInt($(this).attr('data-col'), 10);
		var idx = parseInt($(this).attr('data-idx'), 10);
		if (isNaN(col) || isNaN(idx)) { return; }
		var run = spiderState.tableau[col].slice(idx);
		if (!spiderRunOk(run)) { return; }
		var grab = solitaireGrabOffset(this.getBoundingClientRect(), e.clientX, e.clientY);
		spiderDrag = { from: { col: col, idx: idx }, x: e.clientX, y: e.clientY, grabX: grab.x, grabY: grab.y, started: false, ghost: null, run: run };
	});

	$(document).on('pointermove', function(e) {
		if (!spiderDrag) { return; }
		if (!spiderDrag.started) {
			if (Math.abs(e.clientX - spiderDrag.x) < 6 && Math.abs(e.clientY - spiderDrag.y) < 6) { return; }
			spiderDrag.started = true;
			spiderDrag.ghost = solitaireGhost(spiderDrag.run);
			$('#cards').append(spiderDrag.ghost);
			$(document.body).addClass('cards_dragging');
		}
		spiderDrag.ghost.css({ left: (e.clientX - spiderDrag.grabX) + 'px', top: (e.clientY - spiderDrag.grabY) + 'px' });
		spiderHighlight(e.clientX, e.clientY);
		if (e.preventDefault) { e.preventDefault(); }
	});

	$(document).on('pointerup', function(e) {
		if (!spiderDrag) { return; }
		var drag = spiderDrag;
		spiderDrag = null;
		$(document.body).removeClass('cards_dragging');
		$('.spi_column').removeClass('drop_ok drop_no');
		if (!drag.ghost) { return; }
		drag.ghost.remove();
		spiderSuppressClick = true;
		setTimeout(function() { spiderSuppressClick = false; }, 60);
		spiderDropAt(drag.from, e.clientX, e.clientY);
	});

	$(document).on('click', '#cards_spider #spi_new', function() {
		if (!spiderState) { return; }
		var suits = parseInt($('#spi_suits').val(), 10);
		spiderState = spiderNewDeal(suits);
		$('#spi_win').removeClass('show');
		spiderRender(spiderState);
		spiderSaveState();
	});

	$(document).on('click', '#cards_spider #spi_again', function() {
		$('#cards_spider #spi_new').trigger('click');
	});

	$(document).on('change', '#cards_spider #spi_suits', function() {
		var suits = parseInt($(this).val(), 10);
		spiderState = spiderNewDeal(suits);
		$('#spi_win').removeClass('show');
		spiderRender(spiderState);
		spiderSaveState();
	});

	$(document).on('click', '#cards_spider #spi_undo', function() {
		if (!spiderState) { return; }
		if (spiderUndo(spiderState)) {
			$('#spi_win').removeClass('show');
			spiderRender(spiderState);
			spiderSaveState();
		}
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
		jawnosConfirm(ask, function() {
			blackjackNewBank(BJ_BANK_START);
		});
	});

	// An app window opened directly (not through the start menu) still needs its
	// table laid out; the toggle path calls the same init after its AJAX reply.
	$(function() {
		if ($('#cards').length) { cardsInit(); }
	});
}
