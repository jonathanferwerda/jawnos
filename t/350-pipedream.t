# tests-for: templates/pipedream.html.ep public/js/manager/pipedream.js
# tests-for: public/js/manager/pipedream/*.js
# covers:    Pipedream, the plumbing game: the page's root and init call, the
#            pure rules loaded in a bare JS context, a seeded deal, the whole
#            guaranteed route played out to a win, a straight beside the source
#            pouring into an empty cell, and the placement/rotation/undo rules.

use strict;
use warnings;

use FindBin;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Test::More;

my $root = "$FindBin::Bin/..";

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
plan skip_all => 'node is needed to play the pipe rules' unless $node && -x $node;

my $template = read_file("$root/templates/pipedream.html.ep");
my @js_files = ($root . '/public/js/manager/pipedream.js');
push @js_files, sort grep { -f } glob("$root/public/js/manager/pipedream/*.js");
my $js = join '', map { read_file($_) } @js_files;

like($template, qr/<div id="pipedream"/, 'the page has the game root');
like($template, qr/#pipedream \.pd_stage/, 'the style is scoped to the root');
like($template, qr/id="pd_board"/, 'and the board canvas');
like($template, qr/pipedreamInit\(\);/, 'and the inline script starts the game');
like($template, qr/jawnosT|subs::ui/, 'the visible words go through the translator');

like($js, qr/function pipedreamInit\(\)/, 'the script defines pipedreamInit');
like($js, qr/function pipedreamScreen\(\)/, 'and pipedreamScreen');
like($js, qr/jawnosGameSessionStart\('Pipedream', pipedreamScreen\)/,
	'the play appointment is named Pipedream');
like($js, qr/function pipedreamNewState\(/, 'the deal is a pure function');
like($js, qr/function pipedreamPlace\(/, 'placement is a pure function');
like($js, qr/function pipedreamRotate\(/, 'rotation is a pure function');
like($js, qr/function pipedreamStep\(/, 'the liquid step is a pure function');
like($js, qr/function pipedreamWon\(/, 'the win test is a pure function');
like($js, qr/function pipedreamLost\(/, 'the loss test is a pure function');
unlike($js, qr/\bMath\.random\s*\(/, 'the deal never uses Math.random');

my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
print $fh <<'JS';
var fs = require('fs'), vm = require('vm'), paths = process.argv.slice(2);
var src = paths.map(function (p) { return fs.readFileSync(p, 'utf8'); }).join('');
var ctx = { console: console, Math: Math, JSON: JSON, Date: Date,
	setTimeout: function () {}, clearTimeout: function () {},
	setInterval: function () { return 0; }, clearInterval: function () {},
	window: {}, document: undefined };
vm.createContext(ctx);
vm.runInContext(src, ctx);

var fail = 0;
function ok(cond, label) { console.log((cond ? 'ok   ' : 'FAIL ') + label); if (!cond) fail++; }
function eq(a, b, label) { ok(a === b, label + ' (' + a + ' === ' + b + ')'); }
function take(state, kind) {
	for (var i = 0; i < state.hand.length; i++) {
		if (!state.hand[i].used && state.hand[i].kind === kind) { return i; }
	}
	return -1;
}

// ---- the rules load with no DOM -------------------------------------------
ok(typeof ctx.pipedreamNewState === 'function', 'the deal is a pure function');
ok(typeof ctx.pipedreamPlace === 'function', 'placement is a pure function');
ok(typeof ctx.pipedreamRotate === 'function', 'rotation is a pure function');
ok(typeof ctx.pipedreamStep === 'function', 'the liquid step is a pure function');
ok(typeof ctx.pipedreamWon === 'function', 'the win test is a pure function');
ok(typeof ctx.pipedreamLost === 'function', 'the loss test is a pure function');
eq(ctx.pipedreamScreen(), false, 'with no DOM the screen check is false');

// ---- the seeded deal -------------------------------------------------------
var state = ctx.pipedreamNewState(6, 5, 424242);
eq(state.cols, 6, 'the board has six columns');
eq(state.rows, 5, 'and five rows');
eq(state.source.x, 0, 'the source is on the left edge');
eq(state.source.y, 2, 'in the middle row');
eq(state.drains.length, 2, 'two drains wait on the right edge');
eq(state.won, false, 'the new deal is not won');
eq(state.spilled, false, 'and has not spilled');
ok(state.hand.length > 0, 'the hand is dealt');

var again = ctx.pipedreamNewState(6, 5, 424242);
eq(JSON.stringify(state.hand), JSON.stringify(again.hand), 'the same seed deals the same hand');
eq(JSON.stringify(state.solution), JSON.stringify(again.solution), 'and the same route');
var other = ctx.pipedreamNewState(6, 5, 424243);
ok(JSON.stringify(state.hand) !== JSON.stringify(other.hand)
	|| JSON.stringify(state.solution) !== JSON.stringify(other.solution),
	'a different seed deals a different puzzle');

// ---- the guaranteed route wins --------------------------------------------
var route = ctx.pipedreamSolution(state);
ok(route.length > 0, 'the deal carries a route');
var placed = 0;
for (var i = 0; i < route.length; i++) {
	var cell = route[i];
	var idx = take(state, cell.kind);
	ok(idx >= 0, 'the hand holds a ' + cell.kind + ' for the route');
	if (idx < 0) { break; }
	var done = ctx.pipedreamPlace(state, cell.x, cell.y, idx, cell.rot);
	ok(done, 'route cell ' + cell.x + ',' + cell.y + ' takes a ' + cell.kind);
	if (done) { placed++; }
}
eq(placed, route.length, 'the whole route is placed');
var guard = 0;
while (!ctx.pipedreamWon(state) && !ctx.pipedreamLost(state) && guard < 40) {
	ctx.pipedreamStep(state);
	guard++;
}
eq(ctx.pipedreamWon(state), true, 'the water reaches every drain');
eq(ctx.pipedreamLost(state), false, 'and nothing spills');
eq(state.reached.filter(function (v) { return !!v; }).length, state.drains.length,
	'each drain has drunk');

// ---- a straight beside the source pours into the empty cell --------------
var leak = ctx.pipedreamNewState(6, 5, 777);
var li = take(leak, 'straight');
ok(li >= 0, 'the leak deal holds a straight');
eq(ctx.pipedreamPlace(leak, 1, 2, li, 1), true, 'a straight sits beside the source');
ctx.pipedreamStep(leak);
eq(ctx.pipedreamLost(leak), false, 'the first step enters the straight');
ctx.pipedreamStep(leak);
eq(ctx.pipedreamLost(leak), true, 'the next step pours into the empty cell');
eq(ctx.pipedreamWon(leak), false, 'and is not a win');
ok(leak.spillAt && leak.spillAt.side === 1, 'the spill leaves the straight eastward');

// ---- placement, rotation and undo ----------------------------------------
var occ = ctx.pipedreamNewState(6, 5, 99);
var a = take(occ, 'straight');
var b = -1;
for (var j = 0; j < occ.hand.length; j++) {
	if (j !== a && !occ.hand[j].used) { b = j; break; }
}
ok(a >= 0 && b >= 0, 'the hand holds two pieces');
eq(ctx.pipedreamPlace(occ, 0, 2, a, 0), false, 'the fixed source refuses a pipe');
eq(occ.hand[a].used, false, 'and the piece stays in the hand');
eq(ctx.pipedreamPlace(occ, 1, 2, a, 1), true, 'an empty cell takes the pipe');
var bUsed = occ.hand[b].used;
eq(ctx.pipedreamPlace(occ, 1, 2, b, 0), false, 'an occupied cell refuses another pipe');
eq(occ.hand[b].used, bUsed, 'and the second piece is not spent');
eq(ctx.pipedreamPlace(occ, 2, 2, a, 0), false, 'a spent piece cannot be placed twice');
eq(ctx.pipedreamRotate(occ, 1, 2), true, 'a placed pipe turns');
eq(ctx.pipedreamRotate(occ, 0, 2), false, 'the fixed source does not turn');
eq(ctx.pipedreamUndo(occ), true, 'the last pipe lifts');
eq(occ.cells[2][1], null, 'and the cell is empty again');
eq(occ.hand[a].used, false, 'with the piece back in the hand');

process.exit(fail ? 1 : 0);
JS
close $fh;

my $js_paths = join ' ', @js_files;
my $out = `$node $harness $js_paths 2>&1`;
my $code = $? >> 8;
print $out;
is($code, 0, 'the pipe rules play out in a bare context');

done_testing();
