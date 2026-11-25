# tests-for: public/js/manager/studio/04_knobs.js public/js/manager/studio/10_master.js
# covers:    Putting a control back to its default: a double-clicked knob on the
#            board, a unit's Defaults button on the mastering rack, and a
#            double-clicked master control. The default is the insert's own
#            builder value (ins.defaults) so a model index and a delay time land
#            where a fresh insert starts, with the plain 0..100 fallbacks only
#            when no insert record exists. Structure only: the delegated
#            handlers, the resolution order and the path through studioKnobSet /
#            studioMasterSet are pinned; nothing here inspects a pixel.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root  = repo_root();
my $knobs = read_file("$root/public/js/manager/studio/04_knobs.js");
my $master = read_file("$root/public/js/manager/studio/10_master.js");

# --- the knob's double-click -------------------------------------------------
like($knobs, qr/\$\(document\)\.on\('dblclick', '\.knob'/, 'a dblclick handler is delegated to .knob');
like($knobs, qr/e\.preventDefault\(\);\s*\n\te\.stopPropagation\(\);/, 'the knob double-click is swallowed');
like($knobs, qr/#studio_pedalboard_tiles[^\n]*\.length[^\n]*return;/, 'the hidden tile library is ignored');
like($knobs, qr/studioKnobInput\(knob\)/, 'the handler resolves the value store');
like($knobs, qr/studioKnobSet\(knob, studioKnobDefault\(knob, input\)\)/,
	'the knob goes back through studioKnobSet');

# --- the knob's default resolution order -------------------------------------
like($knobs, qr/function studioKnobDefault\(knob, input\)/, 'the default has its own resolver');
like($knobs, qr/knob\.closest\('\.studio_rack_tile'\)/, 'a rack tile is checked first');
like($knobs, qr/tile\.attr\('channel'\)/, 'the tile names the track channel');
like($knobs, qr/tile\.attr\('insert'\)/, 'the tile names the insert');
like($knobs, qr/tile\.attr\('chain'\) === 'out'/, 'the tile names the chain');
like($knobs, qr/c\.outInsertByName\[name\]/, 'an out-chain insert is found by name');
like($knobs, qr/c\.insertByName\[name\]/, 'an in-chain insert is found by name');
like($knobs, qr/ins\.defaults\[input\.attr\('control'\)\] !== undefined/, 'the builder default wins');
like($knobs, qr/return ins\.defaults\[input\.attr\('control'\)\];/, 'the builder default is returned');
like($knobs, qr/input\.attr\('data-default'\)/, 'a data-default is the next source');
like($knobs, qr/preset !== undefined && preset !== ''/, 'an empty data-default is skipped');
like($knobs, qr/return 50;/, 'the strip fallback is the middle of 0..100');
like($knobs, qr/a model index or a delay time/,
	'the comment says why the builder default is not a guessed 50');

# --- the mastering rack's Defaults button ------------------------------------
like($master, qr/function studioMasterDefault\(ins, input\)/, 'a master control has a resolver');
like($master, qr/ins\.defaults\[control\] !== undefined/, 'the insert default wins on the rack');
like($master, qr/return input\.is\('select'\) \? 0 : 50;/, 'select falls to 0, range to 50');
like($master, qr/function studioMasterResetControls\(name\)/, 'one unit resets as a whole');
like($master, qr/\.studio_master_effect\[effect="' \+ name \+ '"\]/, 'the reset targets one effect block');
like($master, qr/find\('\.studio_master_control'\)/, 'every control in the block is reset');
like($master, qr/studioMasterSet\(name, input\.attr\('control'\), studioMasterDefault\(ins, input\)\)/,
	'each control goes back through studioMasterSet');
like($master, qr/\$\(document\)\.on\('click', '\.studio_master_defaults'/, 'the Defaults button is delegated');
like($master, qr/studioMasterResetControls\(block\.attr\('effect'\)\)/, 'the button resets its own unit');

# --- a master control's double-click -----------------------------------------
like($master, qr/\$\(document\)\.on\('dblclick', '\.studio_master_control'/,
	'a dblclick handler is delegated to the master controls');
like($master, qr/function studioMasterDefault/, 'the double-click shares the resolver');
like($master, qr/\$\(document\)\.on\('dblclick', '\.studio_master_control'[\s\S]*?studioMasterSet\(name, input\.attr\('control'\), studioMasterDefault\(ins, input\)\)/,
	'a double-clicked master control goes back through studioMasterSet');
my ($reset) = $master =~ /(function studioMasterResetControls\(name\)[\s\S]*?\n\})/;
unlike($reset // '', qr/setBypass|studioMasterToggle/, 'the reset leaves the footswitch alone');

done_testing();
