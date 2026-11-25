# tests-for: public/js/manager/studio.js public/js/manager/studio/02_canvas.js public/js/manager/studio/04_knobs.js public/js/manager/studio/06_controls.js public/js/manager/studio/07_layout.js public/js/manager/studio/08_effects.js public/js/manager/studio/09_pedals.js public/js/manager/studio/10_master.js templates/studio/markup.html.ep templates/studio/style.html.ep perl/gb/05_abilities_and_studio.pl perl/help/topics_apps.pl t/345-studio-effects.t
# covers:    The browser side of docs/studio-effects.md: every contract name is in
#            the palette and built by studioInsert, reverb has its five models on
#            a dropdown, a track's rack is ordered/bypassed/removed rather than
#            added and dropped, and the master rack is a fixed chain between the
#            mixer bus and the destination, saved with the song's admin.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $js     = read_file("$root/public/js/manager/studio.js");
my $canvas = read_file("$root/public/js/manager/studio/02_canvas.js");
my $knobs  = read_file("$root/public/js/manager/studio/04_knobs.js");
my $controls_js = read_file("$root/public/js/manager/studio/06_controls.js");
my $layout = read_file("$root/public/js/manager/studio/07_layout.js");
my $fx     = read_file("$root/public/js/manager/studio/08_effects.js");
my $rack   = read_file("$root/public/js/manager/studio/09_pedals.js");
my $master = read_file("$root/public/js/manager/studio/10_master.js");
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $help   = read_file("$root/perl/help/topics_apps.pl");

# The contract's channel insert names (docs/studio-effects.md, "Insert kinds").
my @contract = qw(reverb flanger fuzz amp limiter tremolo autotune equalizer tone distortion delay compressor stereowidener stereo_panner);

# --- the labels and the wire names -----------------------------------------
# autotune is the wire name; people read JawnPitch. Jtune is a tuner, not an
# effect, and is neither an alias nor an insert.
like($studio, qr/autotune => \{ label => 'JawnPitch'/, 'the autotune effect is shown as JawnPitch');
like($studio, qr/name => 'Jtune',[\s\S]*?tuner => 1/, 'the studio data marks Jtune as a tuner');
unlike($studio, qr/autotune => \{ label => 'Autotune'/, 'the old Autotune label is gone');

# --- the palette and the builders agree ------------------------------------
my ($palette) = $studio =~ /palette\s*=>\s*\[\s*qw\(([^)]*)\)\s*\]/s;
ok(defined $palette && length $palette, 'the studio data carries a palette list');
my %palette = map { $_ => 1 } split ' ', ($palette // '');
for my $name (@contract) {
	ok($palette{$name}, "the palette offers the contract effect $name");
	like($fx, qr/\b\Q$name\E\b\s*:\s*'/, "studioInsert's alias table names $name");
}

# The legacy names stay accepted, and reverb2 is the alias of reverb, so old
# songs still load and the legacy pedal name still reaches the same implementation.
like($fx, qr/\breverb2\s*:\s*'reverb'/, 'reverb2 is still an alias of reverb');
like($fx, qr/\bCompressionX\s*:\s*'compressor'/, 'CompressionX still maps to compressor');
like($fx, qr/\bDistorjawn\s*:\s*'distortion'/, 'Distorjawn still maps to distortion');
like($fx, qr/\bDelayed\s*:\s*'delay'/, 'Delayed still maps to delay');
unlike($fx, qr/\bJtune\s*:/, 'Jtune is not in the effect alias table');
like($fx, qr/\bautotune\s*:\s*'autotune'/, 'the wire name autotune is still accepted');
like($js, qr/function studioInsert\(ctx, name\)[\s\S]*?\n\}/,
	'studioInsert() is the one dispatcher');
like($js, qr/var build = studioEffectBuilder\(name\);/, 'studioInsert delegates to the builder table');
like($js, qr/input\.connect\(output\);/, 'an unknown name is a pass-through, not a dead channel');

# Every builder returns the shape the rest of the window calls.
for my $builder (qw(studioEffectReverb studioEffectFlanger studioEffectFuzz studioEffectAmp
                    studioEffectLimiter studioEffectAutotune studioEffectEqualizer
                    studioEffectCompressor studioEffectDistortion studioEffectDelay)) {
	like($fx, qr/^function \Q$builder\E\(ctx, name\)/m, "$builder takes a context and a name");
}
like($fx, qr/fx\.set = function \(control, value\)/, 'the shell defines set(control, value)');
like($fx, qr/fx\.setBypass = function \(on\)/, 'the shell defines setBypass(on)');
like($fx, qr/fx\.bypassed = !!on;/, 'the shell records the bypassed state');
like($fx, qr/fx\.dry\.gain\.value = fx\.bypassed \? 1 : 0;/, 'bypass opens the dry path in place');
like($fx, qr/fx\.wet\.gain\.value = fx\.bypassed \? 0 : 1;/, 'bypass closes the wet path in place');

# --- reverb: five models, one dropdown -------------------------------------
for my $model (qw(Room Spring Plate Hall Cave)) {
	like($fx, qr/name:\s*'\Q$model\E'/, "the reverb shapes carry the $model model");
	like($studio, qr/\b\Q$model\E\b/, "the studio data names the $model model");
}
like($fx, qr/studioReverbModel\(value\)/, 'the model is quantised to a whole number');
like($fx, qr/fx\.setters\['model'\] = function \(v\) \{[\s\S]*?studioReverbImpulse\(ctx, m\)/,
	'set(model) rebuilds the impulse');
like($markup, qr/class="studio_pedal_model pedal_select"/,
	'a choice control is a dropdown on the pedal tile');
like($markup, qr/\@\{\$k->\{'options'\}\}/, 'the dropdown lists the options the contract carries');
like($knobs, qr/studioApplyPedals\(\);[\s\S]*studioRackRenderAll\(\);/,
	'a model change is pushed through the insert setters');
like($rack, qr/'\.studio_pedal_model'/, 'the model dropdown handler is wired to the rack');

# --- the rack: add, order, bypass, remove ----------------------------------
unlike($markup, qr/id="studio_effect_palette"/, 'the old layout-bar effect palette is gone');
like($markup, qr/id="studio_add_track"[\s\S]{0,300}?Add track/, 'Add track sits where the palette was');
like($markup, qr/id="studio_pedalboard_rack" class="studio_channel_rack"/,
	'the pedalboard carries the one chain container');
unlike($markup, qr/studio_track_panel[\s\S]*?studio_channel_rack/,
	'no track panel carries a rack of its own');
like($markup, qr/id="studio_pedalboard_tiles"/, 'the hidden pedal-tile library is in the markup');
like($rack, qr/source\.length \? source\.clone\(\)/, 'the board clones one tile per insert');

like($rack, qr/function studioRackReorder\(ch\)/, 'a dragged order is read back');
like($rack, qr/holder\.sortable\(\{/, 'the rack is a sortable list');
like($rack, qr/function studioRackMove\(ch, name, delta, chain\)/, 'the Up/Down buttons move an insert');
like($rack, qr/function studioSetInsertBypass\(ch, name, on, chain\)/, 'the footswitch has its own path');
like($rack, qr/if \(ins\.setBypass\) \{ ins\.setBypass\(on\); \}/,
	'the footswitch bypasses the insert in place');
like($rack, qr/if \(ins && next\.indexOf\(ins\) === -1\)/,
	'a dragged order only keeps inserts the channel still has');
like($rack, qr/studioSetInsert\(t\.ch, t\.name, false, t\.chain\);/, 'X removes the insert from the tile\'s own chain');

like($rack, qr/'\.studio_rack_bypass'/, 'the rack wires the footswitch');
like($rack, qr/'\.studio_rack_up'/, 'the rack wires Up');
like($rack, qr/'\.studio_rack_down'/, 'the rack wires Down');
like($rack, qr/'\.studio_rack_remove'/, 'the rack wires X');

# --- the song keeps the order and the on/off state -------------------------
like($knobs, qr/song\[ch\]\['fx'\] = c\.inserts\.map\(function\(ins\) \{/,
	'the song stores one record per insert');
like($knobs, qr/return \{ name: ins\.name, on: !ins\.bypassed, controls: controls \};/,
	'each record carries its name, its footswitch and its controls');
like($knobs, qr/\(typeof entry === 'string'\) \? entry : \(entry && entry\.name\)/,
	'an old fx array of names still loads');
like($knobs, qr/rack_restore\.push\(\{ ch: i, name: name, record: entry \}\);/,
	'a restored rack waits for its own control values');
like($knobs, qr/studioSetInsert\(i, name, true\)/, 'the stored order is rebuilt insert by insert');

# Jtune is a listen-only insert: it restores with the chain and is never mapped
# to autotune.
unlike($knobs, qr/if \(name === 'Jtune'\) \{ return; \}/, 'Jtune restores like any insert');
unlike($knobs, qr/typeof entry === 'string' && name === 'Jtune'/, 'there is no Jtune-to-autotune migration');
unlike($knobs, qr/studioSetInsert\(i, 'autotune', true\)/, 'a legacy Jtune is not turned into autotune');
like($markup, qr/<option value="Jtune">/, 'Jtune is offered in the Add dropdown');
like($rack, qr/function studioPaletteAdd\(\)/, 'the Add list has one handler');
like($rack, qr/var name = \$\('#studio_palette_effect'\)\.val\(\);/, 'Add reads the chosen effect');
like($rack, qr/studioRackFind\(ch, name, chain\)/, 'Add refuses a second copy already in the chain');
like($rack, qr/studioSetInsert\(ch, name, true, chain\);/, 'Add puts it in the chain the switch shows');
like($rack, qr/studioPaletteLabel\(\);/, 'the label is refreshed after Add');
like($markup, qr/data-tuner="yes"/, 'the Jtune library tile is marked a tuner');
like($markup, qr/class="studio_tuner" aria-live="polite"/, 'the Jtune tile carries the tuner display');
like($markup, qr/studio_tuner_letter/, 'and the note letter');
like($markup, qr/studio_tuner_cents/, 'and the cents line');
like($rack, qr/studioTunerSync\(\)/, 'one lamp paint keeps the tuner in step with its insert');
unlike($rack, qr/if \(name === 'Jtune'\) \{ return; \}/, 'the tuner toggles like any pedal');
unlike($fx, qr/^\s*Jtune\s*:\s*'/m, 'Jtune has no builder, so the engine plan leaves it out');

# --- the master rack -------------------------------------------------------
my ($master_list) = $studio =~ /master\s*=>\s*\[(.*?)\n\t\]/s;
ok(defined $master_list, 'the studio data carries the master rack');
for my $name (qw(master_comp master_eq master_stereowidener master_reverb master_maximizer master_limiter)) {
	like($master_list // '', qr/name\s*=>\s*'\Q$name\E'/, "the master rack names $name");
	like($fx, qr/\b\Q$name\E\b\s*:\s*'/, "the builder table maps $name to an implementation");
}
like($master, qr/var studioMasterOrder = \[ 'master_comp', 'master_eq', 'master_stereowidener', 'master_reverb', 'master_maximizer', 'master_limiter' \];/,
	'the master chain order is fixed');
like($master, qr/function studioMasterChain\(ctx\)/, 'studioMasterChain builds the fixed chain');
like($master, qr/node\.connect\(ins\.input\);\s*\n\s*node = ins\.output;/,
	'each master insert is wired after the one before it');
like($js, qr/studioAudio\.master\.connect\(rack\.input\);/, 'the mixer bus enters the master rack');
like($js, qr/rack\.output\.connect\(studioAudio\.masterAnalyser\);/, 'the rack feeds the destination through the analyser');
like($js, qr/masterChain: null/, 'the studio audio state owns the master chain');
like($markup, qr/id="studio_master_rack"/, 'the master rack is in the mixer panel');
like($markup, qr/class="studio_master_toggle hover"[^>]*effect="<%= \$m->\{'name'\} %>"/,
	'each master effect has its footswitch');
like($style, qr/\.studio_master_rack \{/, 'the master rack is styled with the mixer');

# off until the song asks for it, and saved in admin
like($master, qr/chain\.inserts\.forEach\(function \(ins\) \{ if \(ins\.setBypass\) \{ ins\.setBypass\(true\); \} \}\);/,
	'every master effect starts bypassed');
like($knobs, qr/tracks: tracks, master: studioMasterSave\(\)/, 'the master rack is saved in admin');
like($knobs, qr/var master_records = mixer\['admin'\] && mixer\['admin'\]\['master'\]/,
	'the master rack is read back from admin');
like($knobs, qr/studioMasterRestore\(master_records\)/,
	'the master rack is restored from admin');
like($master, qr/function studioMasterSave\(\)/, 'studioMasterSave collects the rack');
like($master, qr/function studioMasterRestore\(records\)/, 'studioMasterRestore applies it');

# --- text badges and the rack still reach the track -------------------------
like($canvas, qr/jawnos_studio_pedal_art/,
	'a badge finds artwork from the pedal-art map the template hands over');
like($canvas, qr/studioEffectKind\(pedal\) === kind/,
	'and matches an effect by kind');
like($canvas, qr/channel_fx_text/, 'an effect with no artwork gets a text tile');
like($layout, qr/studioSetInsert\(ch, name, !\(channel && channel\.insertByName\[name\]\)\);/,
	'a dropped effect still adds or removes it');
like($layout, qr/studioSelectedChannel = ch;/, 'FX selects the track the Add list adds to');

# --- the Add list and the rack lamp ------------------------------------------
like($markup, qr/id="studio_palette_effect"/, 'the pedalboard bar carries the Add dropdown');
like($markup, qr/id="studio_palette_add"/, 'and the Add button');
like($markup, qr/id="studio_palette_channel"/, 'and the label naming the track and chain');
like($markup, qr/\@\{\$gb::studio->\{'palette'\}\}/, 'the options come from the palette data');
like($markup, qr/class="studio_pedal_led"/, 'a pedal tile carries the lamp');
unlike($markup, qr/id="studio_pedalboard_pedals"/, 'the old shelf is gone');
like($markup, qr/id="studio_pedalboard_tiles"[\s\S]*class="pedal pedal_graphic"/,
	'the drawn palette tiles live in the hidden library, not on the board');
for my $name (qw(flanger fuzz amp limiter autotune equalizer tone)) {
	like($studio, qr/\b\Q$name\E\s*=>\s*\[ qw\(/, "the palette art names $name's knob colours");
}
like($studio, qr/palette_knob_colours\s*=>\s*\[ qw\(/, 'there is a fallback knob-colour rotation');
like($rack, qr/function studioUpdatePedalLamps\(\)/, 'one function paints every lamp');
like($rack, qr/var on = !!\(ins && !ins\.bypassed\);[\s\S]*tile\.find\('\.studio_pedal_led'\)\.attr\(\{/,
	'a board lamp reads the insert\'s bypass');
like($rack, qr/var ins = studioPedalInsert\(ch, name, chain\);/, 'a tile reads its own chain insert');
like($rack, qr/if \(!ins\) \{ studioSetInsert\(ch, name, true, chain\); \}/,
	'an absent effect joins the chain the board shows');
like($rack, qr/studioSetInsertBypass\(ch, ins\.name, !ins\.bypassed, chain\);/,
	'clicking the lamp bypasses exactly as the rack does, on the same chain');
like($rack, qr/studioUpdatePedalLamps\(\);\n\tstudioSaver\(\);/, 'the footswitch repaints the lamps');
like($rack, qr/#pedalboard \.studio_pedal_led/, 'a pedalboard lamp is clickable');
like($rack, qr/'\.studio_rack_led,/, 'the rack lamps are clickable');
like($knobs, qr/studioTogglePedal\(tile\.attr\('channel'\) \|\| studioPaletteChannel\(\), effect, tile\.attr\('chain'\)\);/,
	'a pedal button toggles the insert its own tile names');
like($style, qr/\.studio_pedal_led\s*\{[^}]*width:\s*14px/s, 'the lamp is 14px wide');
like($style, qr/\.studio_pedal_led\s*\{[^}]*height:\s*14px/s, 'the lamp is 14px tall');
like($style, qr/\.studio_pedal_led\s*\{[^}]*border-radius:\s*50%/s, 'the lamp is round');
like($style, qr/\.studio_pedal_led\[aria-pressed="true"\]\s*\{[^}]*background:\s*#35e05a/s,
	'bright green is the on state');
like($style, qr/\.studio_pedal_led\[aria-pressed="true"\]\s*\{[^}]*box-shadow:\s*0 0 10px #35e05a/s,
	'the on lamp carries a soft glow');
like($style, qr/\.studio_pedal_led\s*\{[^}]*background:\s*#5a1010/s, 'dark red is the off state');
like($style, qr/\.studio_pedal_led\s*\{[^}]*0 0 0 1px rgba\(255, 255, 255, \.3\)/s,
	'the off lamp keeps a pale ring so it stays visible');
like($style, qr/\.studio_rack_tile\.studio_rack_off \.studio_pedal_led\s*\{\s*opacity:\s*1/s,
	'a bypassed tile does not dim its lamp');
like($rack, qr/function studioPedalLampLabel\(on\)/, 'the lamp label names its state');
like($rack, qr/studioLayoutText\(on \? 'On for this track' : 'Off for this track'\)/,
	'the label says On or Off for this track');
like($rack, qr/title: label,[\s\S]*?hint: label/s, 'a tile lamp sets title and hint from its state');
like($markup, qr/class="studio_pedal_led" role="button" aria-pressed="false" title="[^"]*Off for this track/,
	'a tile lamp starts with an Off title');

# --- the board tile is the one pedal -----------------------------------------
like($style, qr/\.studio_rack_tile button\s*\{/, 'a board tile is styled');
like($style, qr/\.studio_board_tools\s*\{/, 'a board tile carries its small tools');
like($style, qr/\.studio_board_empty\s*\{/, 'the empty board has a hint slot');
like($style, qr/\.studio_tuner\s*\{/, 'the tuner display is styled on its tile');
like($style, qr/\.studio_rack_placeholder\s*\{/, 'the drag marker is styled');
like($markup, qr/id="studio_pedalboard_tiles"[\s\S]*id="pedal_/,
	'each pedal has a hidden library tile');
like($markup, qr/%shelf_kind = /, 'the hidden library maps the artwork names to kinds');
like($markup, qr/%shelf_has = /, 'and skips a drawn tile when artwork exists');
unlike($markup, qr/Jtune\s*=>\s*'autotune'/, 'Jtune is not mapped to an audio effect');
like($style, qr/\.pedal_background\s*\{[^}]*object-fit:\s*contain/s, 'the artwork is contained, not cropped');

# --- a board action targets the insert its tile draws ----------------------
# The tile's own channel, chain and insert name are the target, never the
# selected channel or the chain the sheet happens to show. A bypass must also
# stay in that one chain, so a pedal present in both can never be switched by a
# click aimed at the other.
like($rack, qr/function studioTileTarget\(row\)/, 'one resolver reads a tile target');
like($rack, qr/function studioSetInsertBypass\(ch, name, on, chain\)/,
	'the bypass takes the tile chain');
like($rack, qr/var ins = studioRackFind\(ch, name, chain\);\n\tif \(!ins\) \{ return false; \}/,
	'the bypass looks only in that chain and refuses a miss');
unlike($rack, qr/chain = \(chain === 'out'\) \? 'in' : 'out';/,
	'the bypass never flips to the other chain');
like($rack, qr/function studioPedalInsert\(ch, name, chain\)/,
	'the insert lookup takes a chain');
unlike($rack, qr/\[c\.outInserts, c\.inserts\]|\[c\.inserts, c\.outInserts\]/,
	'the insert lookup never searches the other chain');
like($rack, qr/tile\.attr\('channel'\) \|\| studioPaletteChannel\(\), tile\.attr\('insert'\)/,
	'a lamp reads the tile own channel and insert');
like($rack, qr/function studioTogglePedal\(ch, name, chain\)/,
	'the tile toggle takes the chain too');
like($rack, qr/function studioInsertControl\(ch, name, control, value, chain\)/,
	'a typed control takes the tile chain');
like($controls_js, qr/studioInsertControl\(row\.attr\('channel'\), row\.attr\('insert'\), input\.attr\('control'\), input\.val\(\), row\.attr\('chain'\)\);/,
	'a typed tile control edits the chain its tile names');
like($rack, qr/function studioRackMove\(ch, name, delta, chain\)/,
	'Up and Down move within the tile chain');

# A tool is a real button, never a form submit, and sits above the tile face.
like($markup, qr/<button type="button" class="studio_rack_up hover"/, 'Up is an explicit button');
like($markup, qr/<button type="button" class="studio_rack_down hover"/, 'Down is an explicit button');
like($markup, qr/<button type="button" class="studio_rack_remove hover"/, 'X is an explicit button');
like($markup, qr/<button type="button" class="studio_pedal_foot hover"/, 'the footswitch is an explicit button');
like($rack, qr/tools\.find\('button'\)\.attr\('type', 'button'\);/,
	'a cloned tool keeps type=button');
like($style, qr/\.studio_board_tools\s*\{[^}]*z-index:\s*6/s,
	'the tools paint above the title and controls they overlap');

# --- a controller's board says it is read-only -----------------------------
# A remote target intercepts every press inside the sheet; without pedal
# commands in the vocabulary the sheet has to say so instead of going silently
# dead, and the whole board dims when it is not an editing surface.
like($markup, qr/id="studio_pedalboard_remote"/, 'the board carries a read-only notice');
like($markup, qr/Read-only: this Studio is controlling another machine/,
	'and the notice says why the board is read-only');
like($style, qr/\.studio_board_readonly #studio_pedalboard_rack/, 'a read-only board dims its rack');
like($style, qr/\.studio_board_readonly \.studio_pedal_foot/, 'and its controls show they are not available');
like($layout, qr/board\.addClass\('studio_board_readonly'\)\.attr\('aria-disabled', 'true'\);/,
	'the badge marks the board read-only in remote mode');
like($layout, qr/\$\('#studio_pedalboard_remote'\)/, 'and shows the notice');
like($layout, qr/note\.hide\(\);/, 'and hides it when the controller returns to this machine');

# --- the help topic speaks in the pedalboard's words ------------------------
# every new label is in the Studio topic's own controls list, which is what
# scripts/help_audit.pl checks against the on-screen hints
my ($controls) = $help =~ /\$topic\{'studio'\} = \{([\s\S]*?)\n\t\};/;
ok(defined $controls, 'the studio help topic was found');
$controls = '' unless defined $controls;
$controls =~ s/\\'/'/g;
for my $label (
	'The effects in this track\'s chain, in order',
	'Drag to reorder this effect',
	'Bypass this effect without removing it',
	'Move this effect earlier in the chain',
	'Move this effect later in the chain',
	'Remove this effect from the chain',
	'Choose the reverb model',
	'Master effects, after every track',
	'Turn this mastering effect on or off',
	'Arrange the panels',
	'Turn this pedal on or off for this track',
) {
	like($controls // '', qr/\Q$label\E/, "the help topic's controls list names $label");
}
like($help, qr/the Add list at the top of the sheet offers every effect/, 'the help explains adding from the pedalboard');
like($help, qr/Reverb has five models/, 'the help explains the reverb models');
like($help, qr/footswitch bypasses the insert/, 'the help explains bypassing');
like($help, qr/Drag a tile to put it somewhere else/, 'the help explains reordering');
like($help, qr/The master rack is the last of the channel strips, at their far right/,
	'the help puts the master rack at the far right of the strips');
like($help, qr/Every pedal tile on the board wears a small lamp/, 'the help explains the lamp');
like($help, qr/The Jtune pedal is a chromatic tuner, not an audio effect/, 'the help explains Jtune the tuner');
like($help, qr/The song keeps it in the chain like any pedal/, 'the help says the tuner is saved in the chain');
like($help, qr/JawnPitch follows one note at a time/, 'the help names JawnPitch');
like($help, qr/A channel starts with an empty board/, 'the help says a channel starts empty and is filled from Add');

# --- the rack knobs reach the native engine -------------------------------
# docs/studio-effects.md, "The control path": the browser maps 0..100 to the
# effect's own units and posts that, and only while the engine is the path.
like($fx, qr/function studioEffectNatural\(kind, control, value\)/,
	'one function turns a knob into the contract\'s natural units');
like($fx, qr/case 'compressor\.attack':[\s\S]*?return 1 \+ amount \* 199;/,
	'compressor.attack maps to 1..200 ms');
like($fx, qr/case 'compressor\.release':[\s\S]*?return 50 \+ amount \* 950;/,
	'compressor.release maps to 50..1000 ms');
like($fx, qr/case 'limiter\.release':[\s\S]*?return 10 \+ amount \* 490;/,
	'limiter.release maps to 10..500 ms');
like($fx, qr/case 'equalizer\.low':[\s\S]*?return -12 \+ amount \* 24;/,
	'the equalizer bands map to -12..+12 dB');
like($fx, qr/case 'limiter\.ceiling':[\s\S]*?return -24 \+ amount \* 24;/,
	'a limiter ceiling maps to -24..0 dB');
like($fx, qr/studioEffectIndices = \{[\s\S]*?'amp\.cabinet': 3[\s\S]*?'autotune\.key': 11/,
	'whole-number controls travel as their index');
like($fx, qr/function studioEngineInsertParam\(ch, insertName, control, value\)/,
	'a track knob has one engine sender');
like($fx, qr/function studioEngineMasterParam\(insertName, control, value\)/,
	'a master knob has its own sender');
like($fx, qr/target: 'master'/,
	'the master sender addresses target master');
like($fx, qr/studioEffectNatural\(kind, control, value\)/,
	'a sender maps the slider before it posts');
like($fx, qr/\}, 150\);/,
	'a knob POST is debounced like the patchbay faders');
like($fx, qr/function studioEngineIsPath\(\)/,
	'one function decides whether the engine is the path');
like($fx, qr/studioEngineRecording[\s\S]*?studioListenActive/,
	'an engine take or a live listen arms the send');
like($fx, qr/if \(!studioEngineIsPath\(\)\) \{ return; \}/,
	'the browser graph is not double-sent to');
like($rack, qr/studioEngineInsertParam\(ch, name, control, value\);/,
	'a track rack knob posts after it moves');
like($master, qr/studioEngineMasterParam\(name, control, value\);/,
	'a master rack knob posts after it moves');
like($js, qr/var studioEngineRecording = false;/,
	'the engine take panel owns the armed flag');
like($js, qr/studioEngineRecording = \(data\.state === 'recording'\);/,
	'the flag follows the engine status');

# --- the take arms each rack and the master list --------------------------
like($js, qr/function studioEngineTrackPlan\(\)/,
	'the take builds its per-track plan from the racks');
like($js, qr/studioAudio\.channels\[index \+ 1\]/,
	'channel ch is engine track ch-1');
like($js, qr/if \(!ins \|\| ins\.bypassed\) \{ return; \}/,
	'only the enabled inserts are armed');
like($js, qr/inserts\.push\(studioEffectKind\(ins\.name\)\);/,
	'a rack insert travels under its canonical engine name');
like($js, qr/function studioEngineMasterList\(\)/,
	'the take collects the enabled master effects');
like($js, qr/studioMasterSave\(\)/,
	'the list comes from the page\'s own master rack');
like($js, qr/mixer\['admin'\] && mixer\['admin'\]\['master'\]/,
	'the song\'s saved master state is the fallback');
like($js, qr/record\['on'\]/,
	'only a switched-on master effect is sent');
like($js, qr/tracks_json: JSON\.stringify\(plan\)/,
	'the per-track plan travels as tracks_json');
like($js, qr/master_json: JSON\.stringify\(master\)/,
	'the master list travels as master_json');
like($fx, qr/function studioEngineMasterBypass\(insertName, bypassed\)/,
	'a master footswitch has its own sender');
like($fx, qr/name: insertName \+ '\.bypass'/,
	'the bypass is the master_* .bypass pseudo-control');
like($master, qr/studioEngineMasterBypass\(name, !on\);/,
	'the master toggle posts its bypass change');

# --- a drop reorders the chain, then draws it again ------------------------
# The sortable only moves DOM nodes; the order has to reach the model and the
# rows have to be redrawn from it, or the sound and the picture disagree.
my ($reorder) = $rack =~ /^function studioRackReorder\(ch\) \{(.*?)^\}/ms;
ok(defined $reorder, 'the reorder is one function');
like($reorder // '', qr/studioRackRender\(ch\);/, 'a reorder redraws the rack after rebuilding its chain');
like($rack, qr/^\t\t\tupdate: function \(event, ui\) \{/m, 'a completed drop fires update');
like($rack, qr/^\t\t\tstop: function \(event, ui\) \{/m, 'stop is the fallback for a drop that changed nothing');
like($rack, qr/studioRackReorder\(to\);[\s\S]*?studioRackRender\(to\);/, 'the drop redraws from the model');
like($rack, qr/\.attr\('channel', ch\)\.attr\('insert', ins\.name\)\.attr\('chain', chain \|\| 'in'\)/,
	'each tile carries its channel, insert and chain');
like($rack, qr/tile\.find\('\.studio_pedal_foot'\)\s*\n?\s*\.attr\('aria-pressed', on \? 'true' : 'false'\)/,
	'a freshly drawn tile\'s foot already matches its insert');
like($markup, qr/class="knob_control/, 'the library tile carries its controls');

# --- dragging a row reorders the chain, above every panel ------------------
like($rack, qr/zIndex:\s*90000/s, 'a rack drag rides above the pedal sheet too');
like($rack, qr/appendTo:\s*'body'/, 'the rack helper leaves its container');
like($rack, qr/helper:\s*'clone'/, 'the rack drags a clone, so the row stays in place');
like($rack, qr/connectWith:\s*'\.studio_channel_rack'/, 'a rack row can be dropped on another track');
like($rack, qr/placeholder:\s*'studio_rack_placeholder'/, 'a marker shows where the row will land');
like($style, qr/\.studio_rack_placeholder\s*\{[^}]*border:\s*1px dashed var\(--accent\)/s,
	'the marker is a dashed insertion line');
like($rack, qr/function studioRackMoveInsert\(from, to, name\)/, 'one path moves an insert to another track');
like($rack, qr/src\.inserts = src\.inserts\.filter/, 'the source chain loses the insert');
like($rack, qr/dst\.inserts\.push\(ins\)/, 'the destination chain gains it');
like($rack, qr/order\.push\(\$\(this\)\.attr\('insert'\)\)/, 'the dropped position is read from the DOM');
like($rack, qr/studioRebuildInserts\(from\);[\s\S]*?studioRebuildInserts\(to\);/,
	'both audio chains are rebuilt');
like($rack, qr/if \(from !== to\) \{ studioRackMoveInsert\(from, to, name\); \}/,
	'a drop on another track moves rather than reorders');
like($rack, qr/else \{ studioRackReorder\(to\); \}/, 'a drop in the same rack reorders it');
like($rack, qr/studioUpdateFxBadges\(\);[\s\S]*?studioSaver\(\);/,
	'the move repaints the badges and saves the song');

# --- a pedal change on the monitored track re-arms the Listen ---------------
# The engine keeps the strip it was armed with, so the browser has to re-arm it
# when the chain changes; a knob turn is a live param and must not.
like($js, qr/function studioListenRearm\(ch, chain\)/, 'the Listen re-arm helper exists');
like($js, qr/studioListenRearm\(ch, out \? 'out' : 'in'\);/,
	'adding or removing an insert re-arms the Listen');
like($rack, qr/studioSaver\(\);\s*studioListenRearm\(ch, chain\);\s*if \(chain === 'out'/,
	'a stomp re-arms it, on the chain the rack showed');
like($rack, qr/studioSaver\(\);\s*studioListenRearm\(ch, chain\);\s*if \(out &&/,
	'and reordering a rack re-arms it');
like($rack, qr/studioListenRearm\(from, chain\);\s*studioListenRearm\(to, chain\);/,
	'a moved insert re-arms both ends');
like($js, qr/studioListenRearmTimer = setTimeout\(function \(\) \{/,
	'a burst of changes produces one re-arm');
unlike($knobs, qr/studioListenRearm/, 'a knob turn stays a live param and never re-arms');

# --- a pedal knob shows where it was left -----------------------------------
# A knob is a picture of a rotation, so it is painted from its input (the value
# the song saved) instead of sitting at zero, and its value is printed above it.
like($knobs, qr/function studioKnobPaint\(input, scope\)/,
	'one painter draws a knob from its input, wherever that input lives');
like($knobs, qr/function studioKnobValue\(knob, value\)/,
	'and prints the value above the knob');
like($knobs, qr/knob\.nextAll\('\.knob_value'\)\.first\(\)/,
	'the label is found again rather than made twice');
like($rack, qr/studioKnobPaint\(\$\(this\), tile\);/,
	'a board tile paints its restored knobs, so a reload is not all zeroes');
like($style, qr/\.knob_value\s*\{[^}]*position:\s*absolute/s,
	'the value sits above an artwork knob');
like($style, qr/\.pedal_knob \.knob_value\s*\{[^}]*position:\s*static/s,
	'and joins the drawn pedal\'s own column');
unlike($rack, qr/axis:\s*'x'/,
	'the rack sort is not axis-locked: a locked axis leaves the clone\'s top unwritten');

done_testing();
