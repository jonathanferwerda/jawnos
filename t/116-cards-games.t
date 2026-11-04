# tests-for: public/js/manager/manager/12_cards.js templates/cards.html.ep templates/cards/style.html.ep templates/cards/chooser.html.ep templates/cards/tarot.html.ep templates/cards/solitaire.html.ep templates/cards/mahjong.html.ep templates/cards/blackjack.html.ep
# covers:    The Cards app's four decks. The template offers the choice
#            (tarot, solitaire, mahjong, blackjack), the tarot spread is three
#            pictures side by side, and the solitaire, mahjong and blackjack
#            rule functions are loaded in a bare JS context and played out
#            here: deal three, the casino scores, runs, foundations, the
#            turtle's five layers and free-tile rule, and a blackjack shoe
#            dealt from a known order.

use strict;
use warnings;

use FindBin;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Test::More;

my $root = "$FindBin::Bin/..";

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
plan skip_all => 'node is needed to play the card rules' unless $node && -x $node;

my @pages = (
	[ 'templates/cards.html.ep', qr/id="cards"/, 'the page has the table root' ],
	[ 'templates/cards.html.ep', qr/data-variant="<%= \$known %>"/, 'and remembers the chosen deck' ],
	[ 'templates/cards/chooser.html.ep', qr/data-variant="<%= \$deck->\{'key'\} %>"/, 'the chooser offers each deck' ],
	[ 'templates/cards/tarot.html.ep', qr/id="deck_spread"/, 'the tarot pane has a three-card row' ],
	[ 'templates/cards/tarot.html.ep', qr/id="deck_history"/, 'and keeps the history rail' ],
	[ 'templates/cards/solitaire.html.ep', qr/data-bank/, 'the solitaire pane carries the bank in' ],
	[ 'templates/cards/solitaire.html.ep', qr/id="sol_stock"/, 'and has a stock to deal from' ],
	[ 'templates/cards/mahjong.html.ep', qr/id="mj_board"/, 'the mahjong pane has a board' ],
	[ 'templates/cards/blackjack.html.ep', qr/id="bj_dealer"/, 'the blackjack pane has a dealer hand' ],
	[ 'templates/cards/blackjack.html.ep', qr/id="bj_hit"/, 'and the player actions' ],
);
foreach my $page (@pages) {
	my ($file, $pattern, $label) = @{$page};
	my $src = read_file("$root/$file");
	like($src, $pattern, $label);
}

# The rules are plain functions at the top of 12_cards.js. Load the file in a
# bare context: nothing top-level may need the DOM or jQuery for this to work.
my $js = read_file("$root/public/js/manager/manager/12_cards.js");
my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
print $fh <<'JS';
var fs = require('fs'), vm = require('vm'), path = process.argv[2];
var src = fs.readFileSync(path, 'utf8');
var ctx = { console: console, Math: Math, JSON: JSON, Date: Date,
	setTimeout: function () {}, clearTimeout: function () {},
	setInterval: function () { return 0; }, clearInterval: function () {},
	window: {}, document: undefined };
vm.createContext(ctx);
vm.runInContext(src, ctx);
var fail = 0;
function ok(cond, label) { console.log((cond ? 'ok   ' : 'FAIL ') + label); if (!cond) { fail++; } }
function eq(a, b, label) { ok(a === b, label + ' (' + a + ' === ' + b + ')'); }
function card(r, s, up) { return { r: r, s: s, up: up !== false }; }
function blank() {
	return { stock: [], waste: [], foundations: [ [], [], [], [] ],
		tableau: [ [], [], [], [], [], [], [] ],
		moves: 0, passes: 0, bank: 0, selected: null, undo: [], won: false };
}

// ---- solitaire deal ----
var deal = ctx.solitaireDeal(function () { return 0.5; });
var total = deal.stock.length, down = 0, up = 0, shape = true;
for (var col = 0; col < 7; col++) {
	if (deal.tableau[col].length !== col + 1) { shape = false; }
	total += deal.tableau[col].length;
	for (var i = 0; i < deal.tableau[col].length; i++) {
		if (deal.tableau[col][i].up) { up++; if (i !== deal.tableau[col].length - 1) { shape = false; } }
		else { down++; }
	}
}
ok(shape, 'the deal is seven columns of one more card, only the last face up');
eq(total, 52, 'all fifty-two cards are dealt');
eq(up, 7, 'seven cards start face up');
eq(down, 21, 'and twenty-one face down');
eq(deal.stock.length, 24, 'the stock keeps twenty-four');

// ---- runs and landings ----
ok(ctx.solitaireRunOk([ card(9, 0), card(8, 1), card(7, 0) ]), 'descending alternating cards form a run');
ok(!ctx.solitaireRunOk([ card(9, 1), card(8, 2) ]), 'two reds do not form a run');
ok(!ctx.solitaireRunOk([ card(8, 0), card(9, 1) ]), 'ascending is not a run');
ok(!ctx.solitaireRunOk([ card(9, 0, false), card(8, 1) ]), 'a face-down card is not movable');
ok(ctx.solitaireCanTableau([ card(13, 0) ], null), 'a king takes an empty column');
ok(!ctx.solitaireCanTableau([ card(12, 0) ], null), 'a queen does not');
ok(ctx.solitaireCanTableau([ card(5, 0) ], card(6, 1)), 'a black five lands on a red six');
ok(!ctx.solitaireCanTableau([ card(5, 1) ], card(6, 2)), 'a red five does not');
ok(ctx.solitaireCanFoundation(card(1, 0), []), 'an ace starts a foundation');
ok(!ctx.solitaireCanFoundation(card(2, 0), []), 'anything else does not');
ok(ctx.solitaireCanFoundation(card(2, 0), [ card(1, 0) ]), 'the same suit goes up by one');
ok(!ctx.solitaireCanFoundation(card(2, 1), [ card(1, 0) ]), 'a different suit is refused');

// ---- deal three ----
var draw = blank();
for (var d = 1; d <= 10; d++) { draw.stock.push(card(d, 0)); }
eq(draw.stock.length, 10, 'ten cards in the stock');
ctx.solitaireDraw(draw);
eq(draw.waste.length, 3, 'the stock deals three');
eq(draw.stock.length, 7, 'and keeps the rest');
eq(draw.waste[2].up, true, 'the waste shows its cards');
eq(ctx.SOL_DRAW, 3, 'the deal size is three');

var recycle = blank();
recycle.waste = [ card(1, 0, true), card(2, 0, true), card(3, 0, true) ];
recycle.stock = [];
recycle.bank = 100;
ctx.solitaireDraw(recycle);
eq(recycle.stock.length, 3, 'an empty stock turns the waste over');
eq(recycle.waste.length, 0, 'and empties the waste');
eq(recycle.passes, 1, 'counting the pass');
eq(recycle.bank, 80, 'and charging the pass');

// ---- the casino scores ----
var s = blank();
s.waste = [ card(7, 0) ];
s.tableau[3] = [ card(8, 1) ];
s.selected = { zone: 'waste' };
eq(ctx.solitaireApply(s, { zone: 'tableau', col: 3 }), 5, 'waste to tableau pays five');
eq(s.tableau[3].length, 2, 'and the card lands');
eq(s.waste.length, 0, 'leaving the waste');

s = blank();
s.waste = [ card(1, 0) ];
s.selected = { zone: 'waste' };
eq(ctx.solitaireApply(s, { zone: 'foundation', suit: 0 }), 10, 'waste to the foundation pays ten');
eq(s.foundations[0].length, 1, 'and it lands there');

s = blank();
s.tableau[0] = [ card(1, 0) ];
s.selected = { zone: 'tableau', col: 0, idx: 0 };
eq(ctx.solitaireApply(s, { zone: 'foundation', suit: 0 }), 10, 'tableau to the foundation pays ten');

s = blank();
s.foundations[0] = [ card(1, 0) ];
s.tableau[1] = [ card(2, 1) ];
s.selected = { zone: 'foundation', suit: 0 };
eq(ctx.solitaireApply(s, { zone: 'tableau', col: 1 }), -15, 'foundation back to the table costs fifteen');
eq(s.foundations[0].length, 0, 'and the foundation empties');

s = blank();
var s = blank();
s.tableau[0] = [ card(9, 0, false), card(8, 1) ];
s.tableau[1] = [ card(9, 3) ];
s.selected = { zone: 'tableau', col: 0, idx: 1 };
eq(ctx.solitaireApply(s, { zone: 'tableau', col: 1 }), 5, 'turning the next card over pays five');
eq(s.tableau[0][0].up, true, 'and the card is now face up');

s = blank();
s.waste = [ card(5, 0) ];
s.selected = { zone: 'waste' };
eq(ctx.solitaireApply(s, { zone: 'tableau', col: 3 }), null, 'a five cannot land on an empty column');

s = blank();
s.tableau[0] = [ card(1, 0) ];
s.selected = { zone: 'tableau', col: 0, idx: 0 };
ctx.solitaireApply(s, { zone: 'foundation', suit: 0 });
ok(!s.won, 'one pile is not a win');
eq(s.undo.length, 1, 'the move is on the undo stack');
ctx.solitaireUndo(s);
eq(s.foundations[0].length, 0, 'undo takes the card back');
eq(s.bank, 0, 'and the score with it');

// ---- mahjong ----
var tiles = ctx.mahjongDeal();
eq(tiles.length, 144, 'the turtle is one hundred and forty-four tiles');
var layerCounts = {};
for (var tl = 0; tl < tiles.length; tl++) {
	layerCounts[tiles[tl].layer] = (layerCounts[tiles[tl].layer] || 0) + 1;
}
eq(JSON.stringify([ 0, 1, 2, 3, 4 ].map(function (l) { return layerCounts[l]; })),
	JSON.stringify([ 84, 36, 16, 6, 2 ]), 'in five layers');
var counts = {}, faces_ok = true;
for (var t = 0; t < tiles.length; t++) {
	counts[tiles[t].key] = (counts[tiles[t].key] || 0) + 1;
}
for (var key in counts) { if (counts[key] !== 4) { faces_ok = false; } }
ok(faces_ok, 'every face appears four times');

var row = [
	{ layer: 0, x: 0, y: 0, removed: false, key: 'a' },
	{ layer: 0, x: 1, y: 0, removed: false, key: 'b' },
	{ layer: 0, x: 2, y: 0, removed: false, key: 'a' },
	{ layer: 1, x: 0, y: 0, removed: false, key: 'a' }
];
ok(!ctx.mahjongFreeAt(row, 0), 'a tile with another layer over it is not free');
ok(ctx.mahjongFreeAt(row, 2), 'the outer end of the bottom row is free');
row[3].removed = true;
ok(ctx.mahjongFreeAt(row, 0), 'removing the tile above frees the one underneath');
ok(!ctx.mahjongFreeAt(row, 1), 'a tile with both neighbours is blocked');
var pair = [
	{ layer: 0, x: 0, y: 0, removed: false, key: 'a' },
	{ layer: 2, x: 5, y: 3, removed: false, key: 'a' }
];
ok(ctx.mahjongHasMove(pair), 'two free tiles of one face are a move');
var lone = [ { layer: 0, x: 0, y: 0, removed: false, key: 'a' } ];
ok(!ctx.mahjongHasMove(lone), 'a lone tile has no move');

var live = tiles.filter(function (tile) { return !tile.removed; });
var removedTile = tiles[0];
removedTile.removed = true;
var want = tiles.filter(function (tile) { return !tile.removed; })
	.map(function (tile) { return tile.key; }).sort().join(',');
ctx.mahjongShuffleRemaining(tiles);
eq(tiles[0].removed, true, 'a shuffle leaves the removed tiles alone');
var after = tiles.filter(function (tile) { return !tile.removed; })
	.map(function (tile) { return tile.key; }).sort().join(',');
eq(after, want, 'and keeps exactly the faces that were still on the table');

// ---- blackjack ----
eq(ctx.blackjackShoe().length, 312, 'the shoe holds six decks');
eq(ctx.blackjackValue([ card(1, 0), card(13, 0) ]).total, 21, 'an ace and a face are twenty-one');
eq(ctx.blackjackValue([ card(1, 0), card(1, 1), card(9, 0) ]).total, 21, 'two aces soften to twenty-one');
eq(ctx.blackjackValue([ card(10, 0), card(9, 0), card(5, 0) ]).total, 24, 'a hard hand busts over twenty-one');
eq(ctx.blackjackValue([ card(10, 0, true), card(1, 0, false) ], true).total, 10,
	'a hole card is left out of the visible total');

// The shoe is popped, so the deal order is reversed and any later draws sit
// in front of it. Deal order is dealer, player, dealer, player.
function bjShoe(dealOrder, draws) {
	var shoe = dealOrder.slice().reverse();
	if (draws) {
		for (var i = draws.length - 1; i >= 0; i--) { shoe.unshift(draws[i]); }
	}
	return shoe;
}

var bj = ctx.blackjackNewState(100);
bj.bet = 10;
bj.shoe = bjShoe([ card(9, 0), card(1, 0), card(7, 2), card(13, 1) ]);
ctx.blackjackStartHand(bj);
eq(bj.bank, 115, 'a natural pays three to two after the stake comes out');
eq(bj.phase, 'done', 'and the hand is over');
eq(bj.message, 'Blackjack!', 'with the blackjack message');

bj = ctx.blackjackNewState(100);
bj.bet = 10;
bj.shoe = bjShoe([ card(10, 3), card(10, 0), card(9, 3), card(9, 1) ]);
ctx.blackjackStartHand(bj);
eq(bj.bank, 90, 'the stake leaves the bank at the deal');
ctx.blackjackStand(bj);
eq(bj.bank, 100, 'a push returns the stake');
eq(bj.message, 'Push.', 'and says so');

bj = ctx.blackjackNewState(100);
bj.bet = 10;
bj.shoe = bjShoe([ card(10, 1), card(10, 0), card(5, 3), card(8, 2) ], [ card(2, 0) ]);
ctx.blackjackStartHand(bj);
ctx.blackjackStand(bj);
eq(bj.bank, 110, 'the dealer draws to seventeen and loses');
eq(ctx.blackjackValue(bj.dealer).total, 17, 'the dealer stopped on seventeen');

bj = ctx.blackjackNewState(100);
bj.bet = 10;
bj.shoe = bjShoe([ card(1, 1), card(10, 0), card(6, 3), card(9, 2) ]);
var shoeBefore = bj.shoe.length;
ctx.blackjackStartHand(bj);
ctx.blackjackStand(bj);
eq(bj.shoe.length, shoeBefore - 4, 'a soft seventeen draws nothing');
eq(ctx.blackjackValue(bj.dealer).total, 17, 'the soft seventeen stands');
eq(bj.bank, 110, 'and the player wins with nineteen');

bj = ctx.blackjackNewState(100);
bj.bet = 10;
bj.shoe = bjShoe([ card(10, 1), card(10, 0), card(10, 2), card(6, 3) ], [ card(10, 3) ]);
ctx.blackjackStartHand(bj);
ctx.blackjackHit(bj);
eq(bj.phase, 'done', 'a bust ends the hand at once');
eq(bj.bank, 90, 'and the stake is gone');
eq(bj.message, 'Bust.', 'with the bust message');

bj = ctx.blackjackNewState(100);
bj.bet = 10;
bj.shoe = bjShoe([ card(10, 1), card(5, 0), card(6, 2), card(6, 3) ], [ card(10, 2), card(2, 0) ]);
ctx.blackjackStartHand(bj);
ctx.blackjackDouble(bj);
eq(bj.doubled, true, 'double marks the hand');
eq(bj.bet, 20, 'and doubles the stake');
eq(bj.bank, 120, 'a winning double pays both stakes back');
eq(bj.phase, 'done', 'the dealer plays out after a double');

process.exit(fail ? 1 : 0);
JS
close $fh;

my $out = `$node "$harness" "$root/public/js/manager/manager/12_cards.js" 2>&1`;
my $rc = $? >> 8;
diag($out) if $rc;
is($rc, 0, 'the solitaire and mahjong rules play out');

done_testing();
