# tests-for: lib/JawnOS/Controller/manager_misc9.pm public/js/manager/studio/07_layout.js public/js/manager/studio/09_pedals.js public/js/manager/studio.js public/js/manager/studio/04_knobs.js templates/studio/markup.html.ep
# covers:    Remote control of the peer's pedalboard. A controller is no longer
#            read-only: the target publishes its selected track's In and Out
#            inserts (name, bypass state, knob values) as `pedals` in its state,
#            the controller draws that chain, and every board action becomes one
#            bounded `pedal` command. The target applies each action through the
#            same local board functions a press runs, so the engine hears a knob
#            live and the song is saved once. A saved pedalboard recalls onto the
#            peer as one `replace`; the controller never writes its own song over
#            the snapshot it put aside.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root    = repo_root();
my $misc9   = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $layout  = read_file("$root/public/js/manager/studio/07_layout.js");
my $pedals  = read_file("$root/public/js/manager/studio/09_pedals.js");
my $studio  = read_file("$root/public/js/manager/studio.js");
my $knobs   = read_file("$root/public/js/manager/studio/04_knobs.js");
my $markup  = read_file("$root/templates/studio/markup.html.ep");

# The parts are one concatenated bundle and these are top-level functions, so a
# body runs from its opening line to the closing brace in column one.
sub body {
	my ($src, $name) = @_;
	my ($b) = $src =~ /^(?:async )?function \Q$name\E\([^)]*\) \{(.*?)^\}/ms;
	return defined $b ? $b : '';
}

# --- the command whitelist and its 400 --------------------------------------
like($misc9, qr/my %studio_remote_command = map \{ \$_ => 1 \} qw\(transport record track mixer master song pedal select\);/,
	'pedal is one of the whitelisted Studio command areas');
like($misc9, qr/unless \(\$studio_remote_command\{\$command\}\)/,
	'the route checks the whitelist before it relays');
like($misc9, qr/'choose a Studio command: transport, record, track, mixer, master, song, pedal or select'/,
	'the 400 text names pedal, so a typo is judgeable');

# --- the target publishes the selected track's board ------------------------
my $state = body($layout, 'studioRemoteStateBuild');
ok(length $state, 'the published state is one builder');
like($state, qr/var pedals = \{ track: 0, chain: 'in', in: \[\], out: \[\] \};/,
	'pedals has the documented empty shape');
like($state, qr/pedals\.track = pedal_ch;/, 'the state names the selected track');
like($state, qr/pedals\.chain = \(typeof studioChannelChain === 'function'\) \? studioChannelChain\(pedal_ch\) : 'in';/,
	'and the chain that track is showing');
like($state, qr/\['in', 'out'\]\.forEach/, 'both chains are walked');
like($state, qr/var list = \(chain === 'out'\) \? strip\.outInserts : strip\.inserts;/,
	'In reads inserts and Out reads outInserts');
like($state, qr/pedals\[chain\]\.push\(\{[\s\S]{0,120}?name: String\(ins\.name\),[\s\S]{0,80}?bypassed: ins\.bypassed \? 1 : 0,[\s\S]{0,80}?values: \$\.extend\(\{\}, ins\.values \|\| \{\}\)/,
	'each insert travels as name, bypass state and copied values');
like($state, qr/return \{[\s\S]*?tracks: tracks,[\s\S]*?clips: clips,[\s\S]*?master: master,[\s\S]*?pedals: pedals/,
	'and pedals is part of the returned state object');

# --- the controller draws the peer's board ----------------------------------
my $render = body($layout, 'studioRemoteRender');
like($render, qr/if \(typeof studioRemoteBoardApply === 'function'\) \{ studioRemoteBoardApply\(state\.pedals\); \}/,
	'a state poll hands the peer board to the adapter');
like($render, qr/studioRemoteOverlayPaint\(\);/,
	'and the rest of the mirror still follows');

my $board_apply = body($pedals, 'studioRemoteBoardApply');
ok(length $board_apply, 'studioRemoteBoardApply is one function');
like($board_apply, qr/track: studioRemoteWhole\(pedals\.track\),/,
	'it adopts the peer track');
like($board_apply, qr/chain: String\(pedals\.chain \|\| 'in'\) === 'out' \? 'out' : 'in',/,
	'it adopts the peer chain');
like($board_apply, qr/in: studioRemoteBoardCopy\(pedals\.in\),/,
	'it adopts the In inserts');
like($board_apply, qr/out: studioRemoteBoardCopy\(pedals\.out\)/,
	'it adopts the Out inserts');
like($board_apply, qr/var sig = JSON\.stringify\(next\);/,
	'a signature makes an unchanged poll free');
like($board_apply, qr/studioRemoteBoardSig/, 'and the last signature is remembered');
like($board_apply, qr/Date\.now\(\) < studioRemoteBoardHold[\s\S]{0,80}?studioRemoteBoardPending = true/,
	'a press is not repainted under the hand during the hold');

for my $name (qw(studioRemoteBoardChannel studioBoardChannel studioRackChain studioRemoteBoardRender)) {
	like($pedals, qr/^function \Q$name\E\(/m, "$name exists");
}

# --- a pedal command reaches the target side --------------------------------
my $apply_command = body($layout, 'studioRemoteApplyCommand');
like($apply_command, qr/if \(command === 'pedal'\) \{[\s\S]{0,80}?return studioRemotePedalApply\(payload\);/,
	'command pedal is answered by studioRemotePedalApply');

my $apply = body($pedals, 'studioRemotePedalApply');
ok(length $apply, 'studioRemotePedalApply is one function');
like($apply, qr/var ch = studioRemoteWhole\(payload\.track\);/,
	'it reads the target track from the payload');
like($apply, qr/var chain = \(String\(payload\.chain \|\| 'in'\) === 'out'\) \? 'out' : 'in';/,
	'and the chain');
like($apply, qr/var action = String\(payload\.action \|\| ''\)\.toLowerCase\(\);/,
	'and the action name');

for my $field (qw(insert control value on delta order inserts)) {
	like($apply, qr/payload\.\Q$field\E/, "the payload vocabulary carries $field");
}

# An effect name and a control are identifiers, never paths or markup.
like($apply, qr/if \(name && !\/\^\[A-Za-z\]\[A-Za-z0-9_\]\{0,39\}\$\/\.test\(name\)\) \{ return false; \}/,
	'an insert name is a bounded identifier');
like($apply, qr/if \(!name \|\| !\/\^\[a-z\]\[a-z0-9_\]\*\$\/\.test\(control\)\) \{ return false; \}/,
	'a control name is a bounded identifier');

for my $action (qw(set bypass insert remove move order chain replace)) {
	like($apply, qr/action === '\Q$action\E'/, "the target handles the $action action");
}

# The target applies each action through the same local board functions a
# press runs; that is what makes the engine and the song follow a remote edit.
my %applies = (
	studioInsertControl         => qr/studioInsertControl\(ch, name, control, value, chain\);/,
	studioSetInsertBypass       => qr/return studioSetInsertBypass\(ch, name, studioRemoteTruthy\(payload\.on\), chain\);/,
	studioSetInsert_on         => qr/studioSetInsert\(ch, name, true, chain\)/,
	studioSetInsert_off        => qr/studioSetInsert\(ch, name, false, chain\)/,
	studioRackMove              => qr/studioRackMove\(ch, name, delta, chain\);/,
	studioRemotePedalOrderApply => qr/return studioRemotePedalOrderApply\(ch, order, chain\);/,
	studioSetChannelChain       => qr/studioSetChannelChain\(ch, chain\);/,
	studioBoardApplyRecords     => qr/return studioBoardApplyRecords\(ch, chain, clean\);/,
);
for my $call (sort keys %applies) {
	like($apply, $applies{$call}, "$call applies the action locally");
}

# --- the controller sends each local board action as a command --------------
like(body($studio, 'studioSetInsert'),
	qr/if \(on\) \{ studioRemotePedalInsert\(ch, name, chain\); \}\s*\n\s*else \{ studioRemotePedalRemove\(ch, name, chain\); \}/,
	'add and remove are one pedal command each on a controller');
like(body($studio, 'studioSetChannelChain'),
	qr/studioRemotePedalChain\(ch, chain\);/,
	'the In/Out switch is a pedal command on a controller');

my %sends = (
	studioRackMove       => qr/studioRemotePedalMove\(ch, name, delta, chain\);/,
	studioSetInsertBypass => qr/studioRemotePedalBypass\(ch, name, on, chain\);/,
	studioInsertControl  => qr/studioRemotePedalSet\(ch, name, control, value, chain\);/,
	studioRackReorder    => qr/studioRemotePedalOrder\(ch, seq, studioRackChain\(ch\)\);/,
);
for my $fn (sort keys %sends) {
	like(body($pedals, $fn), $sends{$fn}, "$fn routes to the remote command");
}

like(body($pedals, 'studioRackFind'), qr/var c = studioBoardChannel\(ch\);/,
	'find reads the peer board while controlling');
like(body($pedals, 'studioRackRender'), qr/var c = studioBoardChannel\(ch\);/,
	'render reads the peer board while controlling');
like(body($pedals, 'studioRackRender'), qr/var chain = studioRackChain\(ch\);/,
	'and the peer chain');
like(body($pedals, 'studioPaletteChannel'),
	qr/return studioRemoteBoard\.track;/,
	'the palette follows the peer selected track');

my $command = body($pedals, 'studioRemotePedalCommand');
like($command, qr/studioRemoteCommand\('pedal', \$\.extend\(\{ action: action \}, data \|\| \{\}\)\)/,
	'every board action posts through the pedal command');

# --- the controller is editable; only the badge class is read-only ----------
my $read_only = body($pedals, 'studioBoardReadOnly');
like($read_only, qr/^\s*return \$\('#pedalboard'\)\.hasClass\('studio_board_readonly'\);\s*$/m,
	'the guard is only the badge class');
unlike($read_only, qr/studioRemoteTarget/,
	'a controller is no longer read-only');
like(body($pedals, 'studioBoardSave'),
	qr/if \(studioBoardReadOnly\(\)\) \{ return false; \}/,
	'saving a board still refuses a read-only board');
like(body($pedals, 'studioBoardLoad'),
	qr/if \(studioBoardReadOnly\(\)\) \{ return false; \}/,
	'loading a board still refuses a read-only board');

# --- a saved board recalls onto the peer as one replace ----------------------
ok(length body($pedals, 'studioBoardApplyRecords'),
	'studioBoardApplyRecords is the shared apply path');
like(body($pedals, 'studioBoardApplyRecords'),
	qr/list\.slice\(\)\.forEach\(function \(ins\) \{[\s\S]{0,80}?studioSetInsert\(ch, ins\.name, false, chain\);/,
	'it empties the chain in a copied list');
like(body($pedals, 'studioBoardApplyRecords'),
	qr/studioSetInsert\(ch, item\.name, true, chain\);/,
	'then adds each record back');
like(body($pedals, 'studioBoardLoad'),
	qr/if \(typeof studioRemoteTarget !== 'undefined' && studioRemoteTarget\) \{\s*\n\s*studioRemotePedalReplace\(ch, chain, preset\.chain\);/,
	'a controller sends the saved board as a replacement');
like(body($pedals, 'studioBoardLoad'),
	qr/else if \(!studioBoardApplyRecords\(ch, chain, preset\.chain\)\)/,
	'while a local load applies it in this window');
like(body($pedals, 'studioRemotePedalReplace'),
	qr/studioRemotePedalCommand\('replace', \{ track: ch, chain: chain, inserts: ins \}\)/,
	'the replacement carries the records as inserts');

# --- a controller must not overwrite the song it put aside ------------------
my $saver = body($knobs, 'studioSaver');
ok(length $saver, 'studioSaver is one function');
like($saver, qr/if \(typeof studioRemoteTarget !== 'undefined' && studioRemoteTarget\) \{\s*\n\s*return studioSongCache \|\| \{\};/,
	'a controller writes no song of its own');
{
	my $guard   = index($saver, 'studioSongCache || {}');
	my $built   = index($saver, 'var song = {};');
	ok($guard >= 0 && $built >= 0 && $guard < $built,
		'and refuses before it reads a single control');
}

# --- the sheet says where a press goes, and stays editable ------------------
like(body($layout, 'studioRemoteBadge'),
	qr/board\.removeClass\('studio_board_readonly'\)\.removeAttr\('aria-disabled'\);/,
	'the controller badge clears the read-only class');
like(body($layout, 'studioRemoteBadge'),
	qr/note\.text\(studioRemoteText\('Pedal changes are sent to the machine this Studio controls'\)\)\.show\(\);/,
	'and says the press goes to the peer');
like($markup,
	qr/Pedal changes are sent to the machine this Studio controls/,
	'the board notice carries the same words');

# --- the event intercepts let the board through -----------------------------
my $intercept = body($layout, 'studioRemoteInterceptClick');
like($intercept, qr/if \(el\.closest\('\.studio_track_fx'\)\.length\) \{[\s\S]{0,160}?studioRemoteCommand\('track', \{ action: 'select', index: fxch \}\);/,
	'an FX press selects the peer track');
like($intercept, qr/Let the local FX handler open the sheet/,
	'and is not stopped, so the sheet opens');
unlike($intercept, qr/#pedalboard/,
	'the click intercept no longer stops the pedalboard');
like(body($layout, 'studioRemoteInterceptChange'),
	qr/if \(el\.closest\('#pedalboard'\)\.length\) \{ return; \}/,
	'a board knob change is left to the board handlers');
like(body($layout, 'studioRemoteInterceptInput'),
	qr/if \(el\.closest\('#pedalboard'\)\.length\) \{ return; \}/,
	'a board knob drag is left to the board handlers');
like(body($layout, 'studioRemoteInterceptKey'),
	qr/target\.closest\('#pedalboard'\)/,
	'a stomp key press reaches its own handler');

done_testing();
