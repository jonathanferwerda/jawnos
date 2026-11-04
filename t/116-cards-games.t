# tests-for: public/js/manager/manager/12_cards.js templates/cards.html.ep templates/cards/style.html.ep templates/cards/chooser.html.ep templates/cards/tarot.html.ep templates/cards/solitaire.html.ep templates/cards/mahjong.html.ep
# covers:    The Cards app's three decks. The template offers the choice
#            (tarot, solitaire, mahjong), the tarot spread is three pictures
#            side by side, and the solitaire/mahjong rule functions are loaded
#            in a bare JS context and played out here: deal three, the casino
#            scores, runs, foundations, the turtle's free-tile rule and a
#            shuffle that keeps the same faces.

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
eq(tiles.length, 72, 'the turtle is seventy-two tiles');
eq(ctx.MAHJONG_ROWS.join(','), '6,8,10,12,12,10,8,6', 'in eight rows');
var counts = {}, pairs_ok = true;
for (var t = 0; t < tiles.length; t++) {
	counts[tiles[t].key] = (counts[tiles[t].key] || 0) + 1;
}
for (var key in counts) { if (counts[key] !== 2) { pairs_ok = false; } }
ok(pairs_ok, 'every face appears exactly twice');

var row = [
	{ row: 0, col: 0, removed: false, key: 'a' },
	{ row: 0, col: 1, removed: false, key: 'b' },
	{ row: 0, col: 2, removed: false, key: 'a' }
];
ok(ctx.mahjongFreeAt(row, 0), 'the left end of a row is free');
ok(!ctx.mahjongFreeAt(row, 1), 'a tile with both neighbours is blocked');
ok(ctx.mahjongFreeAt(row, 2), 'the right end of a row is free');
row[2].removed = true;
ok(ctx.mahjongFreeAt(row, 1), 'removing the right tile frees its neighbour');
ok(!ctx.mahjongHasMove(row), 'the ends that remain are not a pair');
var pair = [
	{ row: 0, col: 0, removed: false, key: 'a' },
	{ row: 1, col: 0, removed: false, key: 'a' }
];
ok(ctx.mahjongHasMove(pair), 'two free tiles of one face are a move');
row[0].removed = true;
ok(!ctx.mahjongHasMove(row), 'a lone tile has no move');

var before = tiles.map(function (tile) { return tile.key; }).sort().join(',');
tiles[0].removed = true;
var want = tiles.filter(function (tile) { return !tile.removed; })
	.map(function (tile) { return tile.key; }).sort().join(',');
ctx.mahjongShuffleRemaining(tiles);
eq(tiles[0].removed, true, 'a shuffle leaves the removed tiles alone');
var after = tiles.filter(function (tile) { return !tile.removed; })
	.map(function (tile) { return tile.key; }).sort().join(',');
eq(after, want, 'and keeps exactly the faces that were still on the table');

process.exit(fail ? 1 : 0);
JS
close $fh;

my $out = `$node "$harness" "$root/public/js/manager/manager/12_cards.js" 2>&1`;
my $rc = $? >> 8;
diag($out) if $rc;
is($rc, 0, 'the solitaire and mahjong rules play out');

done_testing();
