# tests-for: public/js/manager/studio/09_pedals.js public/js/manager/studio/04_knobs.js public/js/manager/studio/08_effects.js public/js/manager/studio/06_controls.js public/js/manager/studio.js
# covers:    A board change is heard immediately, not on the next pedal switch or
#            Monitor press. Rack knobs, dropdowns and typed fields edit their own
#            insert through studioInsertControl (which posts the live engine
#            param); the Up/Down tools re-arm the Listen like a drag does; a newly
#            armed take starts from the page's knob values; the Distorjawn
#            `gain`/`drive` rename reaches the engine under the contract's name;
#            Chromatic is a real scale on both pitch pedals; the board's pedal
#            size is clamped, persisted and applied; and the artwork footswitch
#            is painted from its insert instead of being treated as a parameter.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use JSON::PP qw(decode_json);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $knobs  = read_file("$root/public/js/manager/studio/04_knobs.js");
my $fx     = read_file("$root/public/js/manager/studio/08_effects.js");
my $rack   = read_file("$root/public/js/manager/studio/09_pedals.js");
my $controls = read_file("$root/public/js/manager/studio/06_controls.js");
my $studio_js = read_file("$root/public/js/manager/studio.js");
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");

# --- a knob on a rack tile edits and posts its own insert -------------------
# A rack tile's input is the insert's control; the hidden library tile and the
# channel strip are macros and keep the old paths.
like($knobs, qr/var tile = input\.closest\('\.studio_rack_tile'\);/,
	'a knob change looks for the rack tile it lives in');
like($knobs, qr/if \(tile\.length\) \{[\s\S]{0,320}?studioInsertControl\(tile\.attr\('channel'\), tile\.attr\('insert'\), control, input\.val\(\), tile\.attr\('chain'\)\);/,
	'a rack knob routes through studioInsertControl, live');
like($knobs, qr/else if \(\/\^\[0-9\]\+\$\/\.test\(channel\)\) \{ studioApplyChannel\(channel\); \}/,
	'a channel-strip knob still applies the strip');
like($knobs, qr/else \{ studioApplyPedals\(\); \}/,
	'a hidden library knob still moves the global macro');
like($knobs, qr/studioKnobPaint\(input\);[\s\S]{0,520}?studioInsertControl\(/,
	'the picture is painted before the insert is edited');

# --- a rack dropdown or typed field is an insert control too ----------------
like($rack, qr/\$\(document\)\.on\('change', '\.studio_pedal_model, \.studio_pedal_text'/,
	'the model dropdown and the typed sync field share one handler');

my ($fields) = $rack =~ /(\$\(document\)\.on\('change', '\.studio_pedal_model, \.studio_pedal_text'[\s\S]*?\n\}\);)/;
ok(defined $fields, 'the dropdown/typed handler is one block');
like($fields // '', qr/if \(tile\.length\) \{[\s\S]{0,260}?studioInsertControl\(tile\.attr\('channel'\), tile\.attr\('insert'\), input\.attr\('control'\), input\.val\(\), tile\.attr\('chain'\)\);/,
	'a change inside the rack reaches the engine through studioInsertControl');
like($fields // '', qr/studioApplyPedals\(\);[\s\S]*?studioRackRenderAll\(\);/,
	'a change outside the rack still runs the macro over every insert');
like($fields // '', qr/studioSaver\(\);/,
	'the outside-rack path still saves the song');

# --- the sync field lists every division when it is opened ------------------
# A datalist filters by the field's own value, so a field reading 1/8t hid the
# longer spans. Opening it clears the value (without committing it) and leaving
# an abandoned edit puts the old value back.
like($controls, qr/\$\(document\)\.on\('pointerdown focus', '\.studio_pedal_text'/,
	'a sync field is emptied when it is opened');
like($controls, qr/input\.attr\('data-sync-open', '1'\)\.attr\('data-sync-value', String\(input\.val\(\) \|\| ''\)\)/,
	'and the value it showed is remembered');
like($controls, qr/on\('blur', '\.studio_pedal_text'/,
	'closing the field settles the choice');
like($controls, qr/if \(!valid\) \{ input\.val\(previous\); return; \}/,
	'an abandoned edit puts the old division back');

# --- the Up/Down tools re-arm the Listen ------------------------------------
my ($move) = $rack =~ /^function studioRackMove\(ch, name, delta, chain\) \{(.*?)^\}/ms;
ok(defined $move, 'studioRackMove is one function');
like($move // '', qr/studioSaver\(\);\s*studioListenRearm\(ch, chain\);/,
	'moving a pedal with the buttons re-arms a listening engine, like a drag');
like($rack, qr/function studioRackReorder\(ch\)[\s\S]{0,1600}?studioListenRearm\(ch, chain\);/,
	'the drag path re-arms too, so the buttons match it');

# --- a new take starts from the page's values -------------------------------
like($fx, qr/^function studioEnginePushInsertValues\(ch\) \{/m,
	'one helper pushes the In chain current values');
my ($push) = $fx =~ /^function studioEnginePushInsertValues\(ch\) \{(.*?)^\}/ms;
ok(defined $push, 'the push is a single function');
like($push // '', qr/\(c\.inserts \|\| \[\]\)\.forEach/,
	'it walks the channel In inserts only');
like($push // '', qr/studioEffectBrowserOnly\(ins\.name\)/,
	'a browser-only insert is skipped: it has no engine slot');
like($push // '', qr/studioEffectTyped\(kind, control\)/,
	'the sync string is never posted as a value');
like($push // '', qr/studioTempoResolveValue\(kind, values\['sync'\], studioTempoBpm\(\)\)/,
	'a synced control is sent as its resolved natural value');
like($push // '', qr/studioEffectNatural\(kind, control, value\)/,
	'and falls back to the manual knob in natural units');
like($push // '', qr/studioEngineInsertParamNatural\(ch, ins\.name, control, natural\);/,
	'the natural value uses the natural post');
like($push // '', qr/studioEngineInsertParam\(ch, ins\.name, control, value\);/,
	'every other control uses the mapped post');
like($push // '', qr/typeof studioAudio !== 'undefined'/,
	'an absent audio graph is a safe no-op');
like($controls, qr/studioEnginePushInsertValues\(\(ch === undefined \|\| ch === null \|\| ch === ''\) \? studioSelectedChannel : ch\);/,
	'a started Listen pushes the selected track\'s values after it is armed');
like($studio_js, qr/studioEngineRecording = true;[\s\S]{0,600}?studioEnginePushInsertValues\(ch\)/,
	'a started engine take pushes each armed channel\'s values');

# --- a pedalboard save picks up the house's merged library ------------------
like($studio_js, qr/var saved_boards = false;/,
	'a settings save knows whether it touched the pedalboard library');
like($studio_js, qr/if \(entry && entry\.setting === 'pedalboards'\) \{ saved_boards = true; \}/,
	'only a pedalboards save refreshes the list');
like($studio_js, qr/window\.jawnos_studio_pedalboards = library;/,
	'the merged house library replaces the page\'s array');
like($studio_js, qr/var chosen_name = select\.find\('option:selected'\)\.text\(\);/,
	'the selected board is remembered by name, not index');
like($studio_js, qr/if \(\$\(this\)\.text\(\) === chosen_name\) \{ select\.val\(\$\(this\)\.val\(\)\); return false; \}/,
	'and is restored by name after the merged order changes');
like($fx, qr/if \(!studioEngineIsPath\(\)\) \{ return; \}/,
	'the post helper drops everything while the engine is not the path');

# --- a Listen and a take are different engine addresses ---------------------
# The engine answers a take's knob by track and a listen's knob by
# `target: "listen"`; sending a listen a take address is refused with "no take
# is running", which is what made a monitor ignore a knob until a re-arm.
like($fx, qr/^function studioEngineParamSession\(\) \{/m,
	'one helper names the running engine session');
like($fx, qr/if \(typeof studioEngineRecording !== 'undefined' && studioEngineRecording\) \{ return 'take'; \}/,
	'a recording take is addressed as a take');
like($fx, qr/if \(typeof studioListenActive !== 'undefined' && studioListenActive\) \{ return 'listen'; \}/,
	'a live Listen is addressed as a listen');
like($fx, qr/^function studioEngineParamAddress\(track, name, value\) \{/m,
	'one builder writes the address and the debounce key');
like($fx, qr/\{ action: 'param', target: 'listen', name: name, value: value \}, key: 'listen:' \+ name \}/,
	'a listen param carries the listen target and no track');
like($fx, qr/studioEngineParamAddress\(track, name, studioEffectNatural\(kind, control, value\)\)/,
	'a mapped insert param goes through the session address');
like($fx, qr/studioEngineParamAddress\(track, name, value\)/,
	'and so does a natural tempo value');
like($fx, qr/typeof studioUsbListening !== 'undefined' && studioUsbListening/,
	'a direct-USB monitor does not post into the engine socket');
like($fx, qr/typeof studioNativeListening !== 'undefined' && studioNativeListening/,
	'and neither does the native bridge');

# --- Distorjawn's old gain knob still drives the native pedal ---------------
like($fx, qr/'distortion\.gain': 'drive'/,
	'the renamed control is mapped for the engine');
like($fx, qr/function studioEffectControlName\(kind, control\)/,
	'one resolver owns the rename');
my ($param) = $fx =~ /^function studioEngineInsertParam\(ch, insertName, control, value\) \{(.*?)^\}/ms;
ok(defined $param, 'the mapped post is one function');
like($param // '', qr/control = studioEffectControlName\(kind, control\);/,
	'the param path renames gain to drive before it posts');
like($param // '', qr/var name = kind \+ '\.' \+ control;/,
	'so the wire name is distortion.drive');
like($fx, qr/fx\.setters\['drive'\] = drive;/,
	'the contract setter is drive');
like($fx, qr/fx\.setters\['gain'\] = function \(v\) \{[\s\S]{0,120}?fx\.values\['drive'\] = v;[\s\S]{0,40}?drive\(v\);/,
	'the legacy gain setter keeps old songs audible and mirrors the contract value');

# --- Chromatic is a real scale on both pitch pedals -------------------------
my $chromatic = () = $studio =~ /qw\(Major Minor Chromatic Pentatonic\)/g;
is($chromatic, 2, 'autotune and harmonizer both offer Chromatic in the effects table');
like($fx, qr/\[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11\], \/\/ Chromatic/,
	'the browser scale table carries the twelve-tone Chromatic row');
like($fx, qr/'autotune\.scale': 3/, 'autotune scale is a four-option index');
like($fx, qr/'harmonizer\.scale': 3/, 'harmonizer scale is a four-option index');

my ($autotune) = $fx =~ /^function studioAutotuneTarget\(hz, key, scale\) \{(.*?)^\}/ms;
ok(defined $autotune, 'studioAutotuneTarget is one function');
like($autotune // '', qr/var tones = studioAutotuneScales\[scale\] \|\| studioAutotuneScales\[0\];/,
	'autotune reads the selected scale');
like($autotune // '', qr/for \(var n = base - 1; n <= base \+ 1; n\+\+\)/,
	'it snaps to the nearest tone in that scale, which for Chromatic is the nearest semitone');

my ($harmonizer) = $fx =~ /^function studioHarmonizerTarget\(hz, key, scale, degree\) \{(.*?)^\}/ms;
ok(defined $harmonizer, 'studioHarmonizerTarget is one function');
like($harmonizer // '', qr/var tones = studioAutotuneScales\[scale\] \|\| studioAutotuneScales\[0\];/,
	'the harmonizer reads the same scale table');
like($harmonizer // '', qr/var raw = bestIndex \+ steps;/,
	'it moves whole scale indices, so Chromatic is whole semitones');
like($harmonizer // '', qr/var octave = Math\.floor\(raw \/ tones\.length\);/,
	'and wraps the index into the scale across octaves');

# The source shape above is the contract; this runs the same functions so the
# claim is behavioural. Node is the browser's language and may be absent on a
# server, so the check skips rather than fails there (t/159 does the same).
SKIP: {
	my $node = qx{command -v node 2>/dev/null};
	chomp $node;
	skip 'node is not installed', 6 unless $node;

	my ($number) = $fx =~ /(function studioEffectNumber\(value\) \{.*?\n\})/s;
	my ($clamp)  = $fx =~ /(function studioEffectClamp\(value, low, high\) \{.*?\n\})/s;
	my ($scales) = $fx =~ /(var studioAutotuneScales = \[.*?\n\];)/s;
	my ($target) = $fx =~ /(function studioAutotuneTarget\(hz, key, scale\) \{.*?\n\})/s;
	my ($harm)   = $fx =~ /(function studioHarmonizerTarget\(hz, key, scale, degree\) \{.*?\n\})/s;
	ok($number && $clamp && $scales && $target && $harm, 'the scale functions are extractable');

	my ($fh, $script) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print {$fh} join("\n", $number, $clamp, $scales, $target, $harm, <<'JS');
var probe = 415.3046975; // G#4, a semitone between two tones of C major
console.log(JSON.stringify({
	autotuneChromatic: studioAutotuneTarget(probe, 0, 2),
	autotuneMajor: studioAutotuneTarget(probe, 0, 0),
	harmonizerChromatic: studioHarmonizerTarget(probe, 0, 2, 5),
	harmonizerMajor: studioHarmonizerTarget(probe, 0, 0, 5)
}));
JS
	close $fh;

	my $out = qx{$node $script 2>&1};
	my $got = eval { decode_json($out) };
	ok(ref $got eq 'HASH', 'the browser scale functions run');
	if (ref $got eq 'HASH') {
		is(sprintf('%.2f', $got->{autotuneChromatic} // 0), '415.30',
			'Chromatic keeps the autotuned note on its own semitone');
		is(sprintf('%.2f', $got->{autotuneMajor} // 0), '392.00',
			'while C major pulls the same note down to a scale tone (G)');
		is(sprintf('%.2f', $got->{harmonizerChromatic} // 0), '466.16',
			'Chromatic harmony is two semitones up from G#4 (A#4)');
		is(sprintf('%.2f', $got->{harmonizerMajor} // 0), '493.88',
			'while the major scale snaps first, so the harmony is B4');
	}
	else {
		skip 'the scale functions did not run', 4;
	}
}

# --- the board's pedal size -------------------------------------------------
for my $name (qw(studioBoardZoomValue studioBoardZoomApply studioBoardZoom)) {
	like($rack, qr/^function \Q$name\E\(/m, "$name exists");
}
like($rack, qr/var studioBoardZoomMin = 0\.75;/, 'the small end is clamped at 0.75');
like($rack, qr/var studioBoardZoomMax = 1\.6;/, 'the large end is clamped at 1.6');
like($rack, qr/var studioBoardZoomStep = 0\.15;/, 'and a press moves one 0.15 step');
like($rack, qr/Math\.max\(studioBoardZoomMin, Math\.min\(studioBoardZoomMax, z\)\)/,
	'every apply clamps into the range');
like($rack, qr/board\.attr\('data-zoom', z\);/, 'the board carries the value as data-zoom');
like($rack, qr/setProperty\('--studio-pedal-zoom', String\(z\)\);/,
	'and as the custom property the stylesheet reads');
like($rack, qr/#studio_pedalboard_zoom_out/, 'the smaller button is bound');
like($rack, qr/#studio_pedalboard_zoom_in/, 'the bigger button is bound');
like($rack, qr/\.prop\('disabled', z <= studioBoardZoomMin\)/, 'Smaller disables at the floor');
like($rack, qr/\.prop\('disabled', z >= studioBoardZoomMax\)/, 'Bigger disables at the ceiling');
like($rack, qr/studioSaveSettings\(\[\{ setting: 'pedal_zoom', value: String\(z\) \}\]\);/,
	'the chosen size is persisted as the pedal_zoom setting');
like($rack, qr/function studioBoardZoom\(delta\) \{\s*\n\s*if \(!\$\('#pedalboard'\)\.length\) \{ return studioBoardZoomValue\(\); \}/,
	'a missing board is a safe no-op');
like($rack, qr/\$\(function \(\) \{[\s\S]{0,160}?studioBoardZoomApply\(studioBoardZoomValue\(\)\);/,
	'document ready settles the buttons and the saved size');

# --- the artwork footswitch -------------------------------------------------
# A tile's stomp is an image now: its state, src and aria must follow the
# insert, and the text fallback only belongs to a real button.
like($rack, qr/tile\.find\('\.studio_pedal_foot'\)\s*\n?\s*\.attr\('aria-pressed', on \? 'true' : 'false'\)/,
	'a freshly drawn tile paints the foot from its insert');
like($rack, qr/state: on \? 'pressed' : 'depressed',/,
	'the stomp image swaps its pressed/depressed state');
like($rack, qr/src: jawnosStudioButtonIcon\(on \? 'pressed' : 'depressed', foot\.attr\('colour'\) \|\| 'ruby_red'\)/,
	'and its artwork for the insert state');
my $text_fallbacks = () = $rack =~ /if \(foot\.is\('button'\)\) \{ foot\.text\(studioLayoutText\(on \? 'On' : 'Off'\)\); return; \}/g;
is($text_fallbacks, 2, 'On/Off text survives only on a button, in both painters');
like($rack, qr/button_control studio_pedal_foot studio_pedal_stomp/,
	'the fallback tile builds the same artwork switch');
like($rack, qr/\.attr\('src', jawnosStudioButtonIcon\('depressed', 'ruby_red'\)\)/,
	'with a dark artwork image to start');
like($rack, qr/\$\(document\)\.on\('click', '\.studio_rack_led, #pedalboard \.studio_pedal_led, #pedalboard \.studio_pedal_foot'/,
	'the pedal handler still owns a press on the foot');
like($rack, qr/\$\(document\)\.on\('keydown', '#pedalboard \.studio_pedal_foot'/,
	'the artwork stomp keeps Enter and Space working as a button did');
like($knobs, qr/if \(b\.hasClass\('studio_pedal_stomp'\) \|\| b\.hasClass\('studio_pedal_foot'\)\) \{ return; \}/,
	'the shared button_control handler leaves the stomp alone');
like($knobs, qr/tile\.attr\('data-tuner'\) === 'yes'[\s\S]{0,160}?studioTunerToggle/,
	'Jtune pink button still toggles the tuner');

done_testing();
