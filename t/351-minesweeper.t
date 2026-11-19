# tests-for: templates/minesweeper.html.ep public/js/manager/minesweeper.js
# covers:    The Minesweeper pane: the template holds the board, the counters
#            and the New game button, and the rule functions are loaded in a
#            bare JS context (no document, no jQuery) and played out here: a
#            seeded first reveal is safe and opens a zero pocket, a mine loses,
#            every safe square wins, and a flag both toggles and refuses to be
#            revealed.

use strict;
use warnings;

use FindBin;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Test::More;

my $root = "$FindBin::Bin/..";

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
plan skip_all => 'node is needed to play the minesweeper rules' unless $node && -x $node;

my $template = read_file("$root/templates/minesweeper.html.ep");
like($template, qr/<div id="minesweeper"/, 'the template has the game root');
like($template, qr/minesweeperInit\(\);/, 'and its script starts the game');
like($template, qr/id="ms_board"/, 'the pane holds a board');
like($template, qr/id="ms_mines"/, 'a mine counter');
like($template, qr/id="ms_time"/, 'a timer');
like($template, qr/id="ms_flag"/, 'a flag mode for touch');
like($template, qr/id="ms_new"/, 'and a New game button');
like($template, qr/&subs::ui\('New game'\)/, 'the new game control is translated');
like($template, qr/#minesweeper \.ms_board/, 'the board style is scoped to the game root');
like($template, qr/#minesweeper \.ms_cell/, 'so is every square');
like($template, qr/\@media \(max-width: 520px\)/, 'the pane has a phone layout');
like($template, qr/touch-action: manipulation/, 'a tap does not zoom the phone page');
unlike($template, qr/<img|<link/, 'the game needs no external asset');

my $js = read_file("$root/public/js/manager/minesweeper.js");
like($js, qr/function minesweeperInit\(\)/, 'the chunk defines the entry point');
like($js, qr/function minesweeperScreen\(\)/, 'and the screen probe the session asks');
like($js, qr/jawnosGameSessionStart\('Minesweeper', minesweeperScreen\)/,
	'the play appointment is named Minesweeper');
like($js, qr/function minesweeperNewState/, 'the rules define a seeded state');
like($js, qr/function minesweeperReveal/, 'a reveal');
like($js, qr/function minesweeperFlag/, 'a flag');
like($js, qr/function minesweeperWon/, 'a win test');
like($js, qr/function minesweeperLost/, 'and a loss test');
unlike($js, qr/\$\(/, 'the script needs no jQuery');

my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
print $fh <<'JS';
var fs = require('fs'), vm = require('vm'), path = process.argv[2];
var src = fs.readFileSync(path, 'utf8');
var ctx = {
	console: console, Math: Math, JSON: JSON, Date: Date,
	setTimeout: function () {}, clearTimeout: function () {},
	setInterval: function () { return 0; }, clearInterval: function () {},
	window: {}, document: undefined
};
vm.createContext(ctx);
vm.runInContext(src, ctx);
var fail = 0;
function ok(cond, label) { console.log((cond ? 'ok   ' : 'FAIL ') + label); if (!cond) { fail++; } }
function eq(a, b, label) { ok(a === b, label + ' (' + a + ' === ' + b + ')'); }

// ---- the rules load with no DOM ----
ok(typeof ctx.document === 'undefined', 'the context has no document');
ok(typeof ctx.minesweeperNewState === 'function', 'the rules load without a document');
ok(typeof ctx.minesweeperInit === 'function', 'and still expose the page entry point');
eq(ctx.minesweeperScreen(), false, 'the screen probe is false without a document');
ctx.minesweeperInit();
ok(true, 'the page entry point no-ops without a document');

// ---- a seeded field, and a safe first reveal that opens a pocket ----
var s = ctx.minesweeperNewState(9, 9, 10, 424242);
eq(s.cols, 9, 'the field has nine columns');
eq(s.rows, 9, 'and nine rows');
eq(s.mines, 10, 'with ten mines');
eq(s.cells.length, 81, 'one cell per square');
eq(s.status, 'ready', 'a fresh field is ready');
eq(s.placed, false, 'and no mine is laid before the first click');

ctx.minesweeperReveal(s, 4, 4);
var first = ctx.minesweeperCell(s, 4, 4);
ok(!!first && !first.mine, 'the first reveal is not a mine');
eq(first.adj, 0, 'and it has no adjacent mines');
ok(first.revealed, 'so it is open');
ok(s.revealed > 1, 'and the reveal opens a zero region');
eq(s.status, 'playing', 'the game is under way');
var pocket = true, laid = 0;
for (var y = 0; y < 9; y++) {
	for (var x = 0; x < 9; x++) {
		var at = ctx.minesweeperCell(s, x, y);
		if (at.mine) { laid++; }
		if (Math.abs(x - 4) <= 1 && Math.abs(y - 4) <= 1 && at.mine) { pocket = false; }
	}
}
eq(laid, 10, 'all ten mines are on the field');
ok(pocket, 'and none sits in the first click\'s pocket');

var again = ctx.minesweeperNewState(9, 9, 10, 424242);
ctx.minesweeperReveal(again, 4, 4);
var same = true;
for (var i = 0; i < 81; i++) {
	if (again.cells[i].mine !== s.cells[i].mine) { same = false; }
}
ok(same, 'the same seed and first click lay the same field');

// ---- a mine loses ----
var bad = ctx.minesweeperNewState(9, 9, 10, 7);
ctx.minesweeperReveal(bad, 0, 0);
var mx = -1, my = -1;
for (var by = 0; by < 9 && mx < 0; by++) {
	for (var bx = 0; bx < 9; bx++) {
		var bc = ctx.minesweeperCell(bad, bx, by);
		if (bc.mine && !bc.revealed) { mx = bx; my = by; break; }
	}
}
ok(mx >= 0, 'a covered mine is on the field');
ctx.minesweeperReveal(bad, mx, my);
ok(ctx.minesweeperLost(bad), 'revealing a mine loses');
ok(!ctx.minesweeperWon(bad), 'and does not win');
eq(bad.exploded, my * 9 + mx, 'the exploded mine is remembered');
ok(ctx.minesweeperCell(bad, mx, my).revealed, 'and the mine is open');

// ---- every safe square wins ----
var good = ctx.minesweeperNewState(9, 9, 10, 31337);
ctx.minesweeperReveal(good, 4, 4);
for (var gy = 0; gy < 9; gy++) {
	for (var gx = 0; gx < 9; gx++) {
		var gc = ctx.minesweeperCell(good, gx, gy);
		if (!gc.mine && !gc.revealed) { ctx.minesweeperReveal(good, gx, gy); }
	}
}
ok(ctx.minesweeperWon(good), 'revealing every safe square wins');
eq(good.revealed, 71, 'all seventy-one safe squares are open');
ok(!ctx.minesweeperLost(good), 'and no mine went off');

// ---- flags toggle and protect a square ----
var f = ctx.minesweeperNewState(9, 9, 10, 99);
var corner = ctx.minesweeperCell(f, 0, 0);
eq(corner.flagged, false, 'a square starts unflagged');
ctx.minesweeperFlag(f, 0, 0);
eq(corner.flagged, true, 'a flag toggles on');
eq(f.flags, 1, 'and the counter follows');
ctx.minesweeperReveal(f, 0, 0);
eq(corner.revealed, false, 'a flagged square cannot be revealed');
eq(f.placed, false, 'so the first reveal has not happened yet');
eq(f.status, 'ready', 'and the game is still ready');
ctx.minesweeperFlag(f, 0, 0);
eq(corner.flagged, false, 'a second flag lifts it');
eq(f.flags, 0, 'and the counter returns');
ctx.minesweeperReveal(f, 0, 0);
ok(corner.revealed, 'the square opens once the flag is lifted');
ctx.minesweeperFlag(f, 0, 0);
eq(corner.flagged, false, 'an open square cannot be flagged');
eq(f.flags, 0, 'and the counter stays at zero');

process.exit(fail ? 1 : 0);
JS
close $fh;

my $out = `$node "$harness" "$root/public/js/manager/minesweeper.js" 2>&1`;
my $rc = $? >> 8;
diag($out) if $rc;
is($rc, 0, 'the minesweeper rules play out with no DOM');

done_testing();
