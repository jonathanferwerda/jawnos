# tests-for: public/js/manager/studio.js public/js/manager/studio/05_inputs.js public/js/manager/studio/09_pedals.js public/js/manager/studio/01_transport.js public/js/manager/studio/04_knobs.js templates/studio/plug_selection.html.ep templates/studio/style.html.ep lib/JawnOS/Controller/manager_misc9.pm t/350-studio-routing.t
# covers:    Studio's routing around a recording. The drum machine is an input
#            app: it patches through a channel's tone stack and In pedals and is
#            detached like the synth. Every channel carries an output chain after
#            the take (playBus -> outIn -> out inserts -> playPan/destination),
#            the rack chooses In or Out and the palette follows, and the song keeps
#            both chains plus the selected one. An output may name another channel,
#            so one track's post-pedal signal feeds another's input chain; the two
#            jacks remember and highlight the same edge. Mute and solo gate the
#            playback bus only, and the song keeps them too. Output inserts never
#            reach the native engine.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $js       = read_file("$root/public/js/manager/studio.js");
my $inputs   = read_file("$root/public/js/manager/studio/05_inputs.js");
my $rack     = read_file("$root/public/js/manager/studio/09_pedals.js");
my $transport = read_file("$root/public/js/manager/studio/01_transport.js");
my $knobs    = read_file("$root/public/js/manager/studio/04_knobs.js");
my $picker   = read_file("$root/templates/studio/plug_selection.html.ep");
my $misc9    = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $style    = read_file("$root/templates/studio/style.html.ep");

# The parts are one concatenated bundle, and the functions are top-level, so a
# body runs from its opening line to the closing brace in column one.
sub body {
	my ($src, $name) = @_;
	my ($b) = $src =~ /^(?:async )?function \Q$name\E\([^)]*\) \{(.*?)^\}/ms;
	return defined $b ? $b : '';
}

# --- the drum machine as a channel input ------------------------------------
like($inputs, qr/\{ app: 'drums', id: 'drums', direction: 'input', av: 'a' \}/,
	'the Drums app is an eligible input, so the plug popup lists it');

my $grab = body($inputs, 'studioInputStreamGrabber');
ok(length $grab, 'the input grabber is one function');
like($grab, qr/if \(studioInputIsApp\(plug\)\) \{ return studioAttachAppInput\(ch, plug\); \}/,
	'the grabber hands every app to the app attach path');
like($grab, qr/channel_plug\['type'\] === 'channel'/, 'a channel send needs no device to open');
like($grab, qr/mixer\[ch\]\.media\.in = \(routed && routed\.recDest\) \? routed\.recDest\.stream : null;/,
	'the take records the destination input chain');
my $start = body($inputs, 'studioStartTake');
like($start, qr/routed_plug\['type'\] === 'channel'/, 'an armed channel send has an input');
like($start, qr/media\.in = routed_channel\.recDest\.stream;/, 'and records its own recDest stream');

my $app = body($inputs, 'studioAttachAppInput');
ok(length $app, 'the app attach path is one function');
like($app, qr/studioAttachDrums\(ch\)/, 'it attaches the drum bus to the channel');
like($app, qr/mixer\[ch\]\.media\.active = true;/, 'a successful attach marks the input active');
like($app, qr/mixer\[ch\]\.media\.in = stream;/, 'the take records the channel’s processed app stream');
like($app, qr/mixer\[ch\]\.media\.video = false;/, 'the drums and synth have no picture');
like($app, qr/\}, 40\);/, 'and the same 40ms meter/redraw interval the synth path uses');

my $drums = body($js, 'studioAttachDrums');
ok(length $drums, 'studioAttachDrums is in the engine');
like($drums, qr/studioDrumsBus\(\);/, 'it brings the drum bus up');
like($drums, qr/if \(!studioDrums\.out\) \{ return null; \}/, 'and refuses without the bus output');
like($drums, qr/if \(c\.source\) \{ try \{ c\.source\.disconnect\(\); \} catch \(e\) \{\} c\.source = null; \}/,
	'an existing device input is disconnected first');
like($drums, qr/if \(c\.synthTap\) \{[\s\S]*?c\.synthTap = null;/, 'so is a synth tap');
like($drums, qr/if \(c\.drumTap\) \{[\s\S]*?c\.drumTap\.node\.disconnect\(c\.drumTap\.gain\)[\s\S]*?c\.drumTap\.gain\.disconnect\(\)[\s\S]*?c\.drumTap = null;/,
	'and a previous drum tap is disconnected, never stacked');
like($drums, qr/studioDrums\.out\.connect\(tap\);/, 'the bus feeds a gain tap');
like($drums, qr/tap\.connect\(c\.trim\);/, 'the tap enters the channel’s tone stack');
like($drums, qr/tap\.connect\(c\.live\);/, 'and the channel live path (fader, Out pedals, output cord)');
like($drums, qr/c\.live\.gain\.value = 1;/, 'the kit is live through the channel output');
like($drums, qr/c\.drumTap = \{ node: studioDrums\.out, gain: tap \};/, 'the tap is kept for detaching');
like($drums, qr/studioApplyChannel\(ch\);[\s\S]*studioRebuildInserts\(ch\);/, 'the channel and its In chain are applied');
like($drums, qr/if \(typeof studioDrumsRouteSelection === 'function'\) \{ studioDrumsRouteSelection\(\); \}/,
	'the drums’ own recorder tap is told the channel changed');
like($drums, qr/return c\.recDest\.stream;/, 'and the processed take stream is returned');
like($js, qr/\/\/ Feed the drum machine into a channel[\s\S]*?its own dry feed is muted/i,
	'the comment records that the kit dry feed is muted while patched');

my $detach = body($transport, 'studioDetachInput');
ok(length $detach, 'studioDetachInput is in the transport part');
like($detach, qr/if \(c\.drumTap\) \{[\s\S]*?c\.drumTap\.node\.disconnect\(c\.drumTap\.gain\)[\s\S]*?c\.drumTap = null;/,
	'a detached input clears the drum tap like the synth tap');
like($detach, qr/studioDrumsRouteSelection\(\)/, 'and hands the drum tap back to the selection');
like(body($js, 'studioAttachInput'), qr/studioDrumsRouteSelection\(\)/,
	'a device input replacing the drums also re-routes their own tap');
like(body($js, 'studioAttachSynth'), qr/studioDrumsRouteSelection\(\)/,
	'and so does a synth attach');

# --- the output chain, before and after the recording -----------------------
my $engine = body($js, 'studioChannelEngine');
ok(length $engine, 'the channel engine is one function');
like($engine, qr/outIn: ctx\.createGain\(\),/, 'a channel owns an outIn gain');
like($engine, qr/printBus: ctx\.createGain\(\),/, 'and a dry bus for a printed take');
like($engine, qr/outInserts: \[\],/, 'and an empty output chain');
like($engine, qr/outInsertByName: \{\},/, 'with a name index');
like($engine, qr/c\.playBus\.connect\(c\.outIn\);/, 'playback leaves the fader into the output chain');
like($engine, qr/studioRebuildOutputs\(ch\);/, 'track creation wires the empty chain through the same rebuild');
like($engine, qr/c\.playPan\.connect\(studioAudio\.master\);/, 'and the pan reaches the master');
like($engine, qr/rackChain:/, 'the channel remembers which chain the rack shows');

my $out = body($js, 'studioRebuildOutputs');
ok(length $out, 'studioRebuildOutputs rewires one channel’s output chain');
like($out, qr/c\.outIn\.disconnect\(\)/, 'it starts from the chain input');
like($out, qr/c\.outInserts\.forEach\(function \(insert\) \{[\s\S]*?node\.connect\(insert\.input\);[\s\S]*?node = insert\.output;/,
	'each output insert is wired after the one before it');
like($out, qr/var target = studioChannelOutputTarget\(ch\);/, 'the last node reads the output jack');
like($out, qr/dest = studioAudio\.channels\[target\] \|\| studioChannelEngine\(target\);/, 'a channel destination is brought up if needed');
like($out, qr/var sink = \(dest && dest\.trim\) \? dest\.trim : c\.playPan;/,
	'a channel send or the pan is the chain\'s sink');
like($out, qr/node\.connect\(sink\);/, 'the last node feeds that sink');
like($out, qr/if \(c\.printBus\) \{ c\.printBus\.connect\(sink\); \}/,
	'a printed take reaches the same sink without the chain');

my $output_info = body($js, 'studioChannelOutputInfo');
like($output_info, qr/studio_channel_information\[direction="output"\]/, 'the output jack is read from the channel');
my $output_target = body($js, 'studioChannelOutputTarget');
like($output_target, qr/plug\['type'\] === 'channel'/, 'a channel output yields its destination');
my $cycle = body($js, 'studioChannelOutputCycle');
like($cycle, qr/if \(at === source\) \{ return true; \}/, 'a route back to the source is a cycle');
like($cycle, qr/if \(seen\[at\]\) \{ return true; \}/, 'a repeated edge is a cycle too');

# --- channel sends from either jack -----------------------------------------
like($inputs, qr/channels: JSON.stringify\(other_channels\)/, 'the picker is told every other track');
like($inputs, qr/studioTrackNumbers\(\)\.filter\(function \(n\)/,
	'a channel list excludes the channel whose jack opened');
my $highlight = body($inputs, 'studioPlugSelectHighlight');
like($highlight, qr/studio_plug_active/, 'the saved row wears the stable selection class');
like($highlight, qr/if \(type === 'app'\)/, 'an app row is matched by app');
like($highlight, qr/if \(type === 'channel'\)/, 'a channel row is matched by its number');
like($highlight, qr/chosen\.find\('\.studio_input_channel'\)\.val/, 'the device row restores its Input 1/Input 2 picker');
my $send = body($inputs, 'studioPlugSendSet');
like($send, qr/studioChannelOutputCycle\(source, dest\)/, 'a send refuses a feedback loop');
like($send, qr/studioPlugSetInfo\(source, 'output',/, 'the source output names the destination');
like($send, qr/sid: dest/, 'the saved edge carries the row sid used for its highlight');
like($send, qr/sid: source/, 'and the destination input carries the source sid');
like($send, qr/studioPlugSetInfo\(dest, 'input',/, 'the destination input names the source');
like($send, qr/studioInputStreamGrabber\(dest, 'off'\)/, 'the old destination capture is released');
like($send, qr/studioRebuildOutputs\(source\)/, 'the source output chain is rebuilt');
like($inputs, qr/type === 'channel'\) \{\n\t\tvar source = \(direction === 'output'\)/, 'a channel row becomes an edge from either jack');
like($inputs, qr/studioPlugSendClearInto\(channel\)/, 'choosing a real input ends an incoming send');
like($inputs, qr/studioPlugSendClearFrom\(channel\)/, 'choosing a real output ends an outgoing send');
my $clear_from = body($inputs, 'studioPlugSendClearFrom');
like($clear_from, qr/studioInputStreamGrabber\(dest, 'off'\)/, 'the old destination input is released too');
like($inputs, qr/chosen\.addClass\('studio_plug_active'\)/, 'a chosen row takes the stable class');
unlike($inputs, qr/addClass\('active_background'\)/, 'no picker row uses the flashing alarm class');
like($picker, qr/type="channel"/, 'the picker renders a row per other channel');
like($picker, qr/Take another channel\\'s output as this channel\\'s input/, 'the input row says what it does');
like($picker, qr/Send this channel\\'s output to another channel/, 'the output row says what it does');
like($style, qr/\.studio_plug_selection\.studio_plug_active\s*\{[^}]*background:/s,
	'a chosen row keeps a stable theme background');
like($style, qr/\.studio_plug_selection\.studio_plug_active\s*\{[^}]*outline:\s*2px solid var\(--accent\)/s,
	'and a border highlight around the whole row');
like($style, qr/#studio_plug_select_container\s*\{[^}]*max-height:\s*min\(60vh,\s*480px\)/s,
	'the plug list is capped at a readable height');
like($style, qr/#studio_plug_select_container\s*\{[^}]*max-width:\s*min\(520px,/s,
	'and a readable width, so it cannot take half the screen');
like($style, qr/#studio_plug_select table\s*\{[^}]*table-layout:\s*fixed/s,
	'the list table fits the capped box instead of widening it');
like($misc9, qr/decode_json \$c->param\('channels'\)/, 'the controller accepts the channel list');
like($misc9, qr/channels => \$channels,/, 'and hands it to the picker');

like($knobs, qr/if \(n == 'plugs'\)/, 'the song restores both jacks');
like($knobs, qr/studio_channel_information\[direction="' \+\s*dir\s*\+ '"\]\[channel="' \+\s*i\s*\+ '"\]/,
	'each saved plug lands on its own channel and direction');
like($knobs, qr/studioRebuildOutputs\(ch2\)/, 'every restored output is re-routed after the song loads');
like($js, qr/\/\/ The output chain sits after the take[\s\S]*?is a wire/,
	'an empty output chain is documented as a wire');

my $set = body($js, 'studioSetInsert');
ok(length $set, 'studioSetInsert is the one insert entry point');
like($js, qr/function studioSetInsert\(ch, name, on, chain\)/, 'it takes an optional chain');
like($set, qr/var out = \(chain === 'out'\);/, 'Out is the only alternative to the default In');
like($set, qr/var list = out \? c\.outInserts : c\.inserts;/, 'the chain chooses the list');
like($set, qr/var byName = out \? c\.outInsertByName : c\.insertByName;/, 'and its name index');
like($set, qr/if \(out\) \{ studioRebuildOutputs\(ch\); \} else \{ studioRebuildInserts\(ch\); \}/,
	'only the changed chain is rebuilt');
unlike($set, qr/studioEngineInsertParam/, 'adding or removing an insert never addresses the engine');

# --- the rack: In and Out ---------------------------------------------------
my $render = body($rack, 'studioRackRender');
ok(length $render, 'the rack is one render function');
like($render, qr/studio_chain_toggle/, 'the rack opens with the chain switch');
like($render, qr/studio_chain_choice/, 'holding the two choices');
like($render, qr/attr\('aria-pressed', chain === choice\[0\] \? 'true' : 'false'\)/,
	'each choice says which chain is showing');
like($render, qr/\['in', 'In', 'Before the recording'\], \['out', 'Out', 'After the recording'\]/,
	'In is before the take and Out after it');
like($render, qr/var chain = studioChannelChain\(ch\);/, 'the render reads the channel’s selected chain');
like($render, qr/var list = \(chain === 'out'\) \? c\.outInserts : c\.inserts;/, 'and renders that chain');
like($render, qr/studioRackTile\(ch, ins, chain\)/, 'each tile carries its chain');
like($rack, qr/\.attr\('channel', ch\)\.attr\('insert', ins\.name\)\.attr\('chain', chain \|\| 'in'\)/,
	'the tile’s chain travels with it');
like($render, qr/studioRackDragChain = chain \|\| studioChannelChain\(from\);/,
	'a drop reads the dragged tile’s chain');
like($rack, qr/var chain = \(studioRackDragChain === 'out'\) \? 'out' : 'in';/,
	'moving a tile between tracks keeps it in the same chain');
like($render, qr/if \(from !== to\) \{ studioRackMoveInsert\(from, to, name\); \} else \{ studioRackReorder\(to\); \}/,
	'a same-rack drop reorders, another track moves');

like($rack, qr/function studioRackFind\(ch, name, chain\)/, 'studioRackFind is chain-aware');
like($rack, qr/var map = \(chain === 'out'\) \? c\.outInsertByName : c\.insertByName;/,
	'and looks the name up in the chosen chain');
like($rack, qr/var ins = studioRackFind\(ch, name, chain\);\n\tif \(!ins\) \{/,
	'the bypass follows the chain the rack shows');

my $reorder = body($rack, 'studioRackReorder');
like($reorder, qr/var chain = studioChannelChain\(ch\);/, 'a reorder operates on the selected chain');
like($reorder, qr/if \(out\) \{ c\.outInserts = next; studioRebuildOutputs\(ch\); \}/,
	'and rebuilds that chain’s graph');
like($reorder, qr/studioRebuildInserts\(ch\); \}[\s\S]*?studioRackRender\(ch\);/, 'then redraws the rack from the rebuilt chain');
like($render, qr/^\t\t\tupdate: function \(event, ui\) \{/m, 'the sortable settles a drop on update');
like($render, qr/studioRackReorder\(to\);/, 'the drop reorders the chain it was drawn for');
my $move = body($rack, 'studioRackMove');
like($move, qr/var list = out \? c\.outInserts : c\.inserts;/, 'Up and Down move within the selected chain');
like($move, qr/if \(out\) \{ studioRebuildOutputs\(ch\); \} else \{ studioRebuildInserts\(ch\); \}/,
	'and rebuild the chain they moved');

like($rack, qr/studioSetChannelChain\(ch, \$\(this\)\.attr\('chain'\)\);/, 'clicking a choice selects that chain');
like($rack, qr/\.studio_chain_choice/, 'the choice buttons are wired');
like($rack, qr/studioSetInsert\(ch, name, true, chain\);/, 'the palette’s Add uses the selected chain');
like($rack, qr/studioLayoutText\('Track'\) \+ ' ' \+ ch \+ ' · ' \+ studioLayoutText\(chain === 'out' \? 'Out' : 'In'\)/,
	'the palette label names the track and the chain');
like($rack, qr/studioSetInsert\(ch, name, false, 'out'\);/, 'X removes an Out insert from the Out chain');
like($rack, qr/if \(chain !== 'out'\) \{ studioEngineInsertParam\(ch, name, control, value\); \}/,
	'an output insert’s knob never reaches the native engine');
my $plan = body($js, 'studioEngineTrackPlan');
like($plan, qr/channel\.inserts\.forEach/, 'the engine take plan reads only the input chain');
unlike($plan, qr/outInserts/, 'and never the output chain');
like($plan, qr/if \(studioEffectKind\(ins\.name\) === 'stereowidener'\) \{ return; \}/,
	'an enabled Stereo Widener is left out of the engine track plan');
like($plan, qr/inserts\.push\(studioEffectKind\(ins\.name\)\);/, 'every other insert still reaches the take');
like($plan, qr/var from = studioEngineTrackSend\(index \+ 1\);/, 'the take plan asks whether the channel has a send');
like($plan, qr/entry\.from = from;/, 'a send travels as `from` instead of an interface input');
unlike($plan, qr/outInserts/, 'the Out chain is still browser playback only');
like($js, qr/function studioEngineTrackSend\(ch\)/, 'the plan reads the destination input jack');
like($js, qr/studioPlugInfo\(ch, 'input'\)/, 'through the same saved plug the two jacks share');
like($js, qr/return source - 1;/, 'the engine track is the 0-based channel number');
my $master = body($js, 'studioEngineMasterList');
like($master, qr/return record && record\['on'\]\n\t\t\t&& studioEffectKind\(record\['name'\]\) !== 'stereowidener';/,
	'and the master list drops the browser-only Stereo Widener, named directly or as master_stereowidener');
like($master, qr/\.map\(function \(record\) \{\n\t\treturn record\['name'\];/,
	'while every other enabled master effect still reaches the take');
like($js, qr/\$\.each\(\[c\.insertByName, c\.outInsertByName\], function \(j, map\) \{/,
	'a pedal macro pushes into both chains');

# --- the song keeps both chains and the selected one ------------------------
like($knobs, qr/song\[ch\]\['fx'\] = c\.inserts\.map\(function\(ins\) \{/,
	'fx stays the input chain, so older songs still read it');
like($knobs, qr/song\[ch\]\['fx_out'\] = c\.outInserts\.map\(function\(ins\) \{/,
	'fx_out saves the output chain in the same shape');
like($knobs, qr/return \{ name: ins\.name, on: !ins\.bypassed, controls: controls \};/,
	'each output record carries its name, footswitch and controls');
like($knobs, qr/song\[ch\]\['fx_chain'\] = \(c\.rackChain === 'out'\) \? 'out' : 'in';/,
	'fx_chain saves which rack was showing');

like($knobs, qr/c\.outInserts\.slice\(\)\.forEach\(function\(ins\) \{ studioSetInsert\(i, ins\.name, false, 'out'\); \}\);/,
	'restoring clears the output chain first, so an older song’s is empty');
like($knobs, qr/\(v\['fx_out'\] \|\| \[\]\)\.forEach\(function\(entry\) \{/,
	'a song with no fx_out simply has no output inserts');
like($knobs, qr/studioSetInsert\(i, name, true, 'out'\);/, 'the saved output order is rebuilt in Out');
like($knobs, qr/studioSetChannelChain\(i, \(v\['fx_chain'\] == 'out'\) \? 'out' : 'in'\);/,
	'the selected chain is restored, defaulting to In');
like($knobs, qr/var ins = studioRackFind\(item\.ch, item\.name, item\.chain \|\| 'in'\);/,
	'each stored record’s values land in the chain it came from');
like($knobs, qr/rack_restore\.push\(\{ ch: i, name: name, record: entry, chain: 'out' \}\);/,
	'an output record waits for its own control values');

# --- mute and solo ----------------------------------------------------------
like($transport, qr/function studioApplyMuteSolo\(\)/, 'studioApplyMuteSolo is one function');
my $mute = body($transport, 'studioApplyMuteSolo');
like($mute, qr/var anySolo = studioAnySolo\(\);/, 'it asks whether any channel is soloed');
like($mute, qr/var dimmed = anySolo && !m\.solo;/, 'a non-solo channel is dimmed while another is soloed');
like($mute, qr/\$\('#studio_track_row_' \+ ch\)\.toggleClass\('studio_solo_muted', !!dimmed\);/, 'the track row dims');
like($mute, qr/\$\('\.channel_' \+ ch\)\.toggleClass\('studio_solo_muted', !!dimmed\);/, 'and the channel strip');
like($mute, qr/studioApplyPlaybackMix\(\);/, 'and the mix is applied at once');

my $mix = body($transport, 'studioApplyPlaybackMix');
like($mix, qr/var silent = m\.mute \|\| \(anySolo && !m\.solo\);/, 'the fader gain carries the mute/solo factor');
like($mix, qr/studioVolumeFraction\([\s\S]*?\) \* \(silent \? 0 : 1\);/,
	'so the bus gain is the fader times the mute factor');
unlike($mute, qr/monGain/, 'mute and solo never touch the monitor tap');
unlike($mute, qr/recGain/, 'nor the recorded input');

like($knobs, qr/song\[ch\]\['mute'\] = m\.mute \? 1 : 0;/, 'the song keeps mute');
like($knobs, qr/song\[ch\]\['solo'\] = m\.solo \? 1 : 0;/, 'and solo');
like($knobs, qr/if \(n == 'mute' \|\| n == 'solo'\) \{[\s\S]*?mixer\[i\]\[n\] = \(w == 1 \|\| w == '1' \|\| w === true\);/,
	'restoring reads them back as booleans');
like($knobs, qr/\$\(document\)\.trigger\('studio:mute-solo'\);[\s\S]*?studioApplyMuteSolo\(\);/,
	'and repaints the strips and the mix');

# --- the scripts still parse -----------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	for my $file ("$root/public/js/manager/studio.js",
	              "$root/public/js/manager/studio/01_transport.js",
	              "$root/public/js/manager/studio/04_knobs.js",
	              "$root/public/js/manager/studio/05_inputs.js",
	              "$root/public/js/manager/studio/09_pedals.js") {
		my $out = `$node --check "$file" 2>&1`;
		my $status = $?;
		diag($out) if $status != 0;
		is($status, 0, "node --check accepts $file");
	}
}
else {
	diag('node is not installed; the syntax check is skipped');
}

done_testing();
