# tests-for: templates/studio/style.html.ep templates/studio/markup.html.ep public/js/manager/studio/06_controls.js perl/gb/05_abilities_and_studio.pl perl/help/topics_apps.pl t/446-studio-shell.t
# covers:    The Studio shell: Configure covers the whole window, the pedalboard's
#            +/- size buttons and saved zoom, every pedal's artwork footswitch,
#            the Distorjawn Drive knob, the Chromatic scale, and the help words
#            that describe them.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $style  = read_file("$root/templates/studio/style.html.ep");
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $js     = read_file("$root/public/js/manager/studio/06_controls.js");
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $help   = read_file("$root/perl/help/topics_apps.pl");

# --- Configure is the whole window -----------------------------------------
like($style, qr/#studio_config\s*\{[^}]*position:\s*absolute/s,
	'Configure is an absolute sheet');
like($style, qr/#studio_config\s*\{[^}]*inset:\s*0/s,
	'it covers the whole Studio window');
like($style, qr/#studio_config\s*\{[^}]*z-index:\s*80000/s,
	'above every panel');
like($style, qr/#studio_config\s*\{[^}]*width:\s*auto/s,
	'its width comes from the inset, not a flex row');
like($style, qr/#studio_config\s*\{[^}]*height:\s*auto/s,
	'and so does its height');
like($style, qr/#studio_config\s*\{[^}]*overflow-y:\s*auto/s,
	'its own content still scrolls');
like($style, qr/#studio_config\s*\{[^}]*padding:\s*4px\s+10px/s,
	'the sheet is a child of #studio, below the window title bar');
for my $sel (qw(#studio_layout_bar #studio_viewer #studio_grid #pedalboard)) {
	like($style, qr/#studio\.studio_config_open \Q$sel\E[\s\S]{0,200}?display:\s*none\s*!important/,
		"the open state hides $sel");
}

# Opening Configure closes the docked pedalboard first.
like($js, qr/function studioConfigShow\(\)[\s\S]{0,500}?studioPedalboardOpen\(false\);/,
	'the config sheet closes the pedalboard as it opens');
like($js, qr/studioMonitorProbeStop\(\);/, 'and keeps the monitor stop on the hide path');

# --- pedal size: +/- beside Close, saved ----------------------------------
like($markup, qr/id="studio_pedalboard_zoom_out"/, 'the board has a smaller-pedals button');
like($markup, qr/id="studio_pedalboard_zoom_in"/, 'and a bigger-pedals button');
like($markup, qr/Smaller pedals/, 'the smaller button says what it does');
like($markup, qr/Bigger pedals/, 'the bigger button says what it does');
like($markup, qr/id="studio_pedalboard_zoom_out"[\s\S]{0,400}?id="studio_pedalboard_zoom_in"[\s\S]{0,400}?id="studio_pedalboard_close"/,
	'the two size buttons sit immediately before Close');
like($markup, qr/\$settings->\{'pedal_zoom'\}/, 'the zoom is read from the saved setting');
like($markup, qr/\$pedal_zoom = 1 unless/, 'an unset or bad value falls back to 1');
like($markup, qr/\$pedal_zoom = 0\.75 if \$pedal_zoom < 0\.75;/,
	'the value is clamped no lower than 0.75');
like($markup, qr/\$pedal_zoom = 1\.6 if \$pedal_zoom > 1\.6;/,
	'and no higher than 1.6');
like($markup, qr/\$pedal_zoom \+= 0;/, 'the emitted value is a number');
like($markup, qr/data-zoom="<%= \$pedal_zoom %>"/, 'the board carries the value as data-zoom');
like($markup, qr/--studio-pedal-zoom: <%= \$pedal_zoom %>/,
	'and as the inline CSS custom property');

# The CSS scales the pedals and the sheet's own bounds with that property.
like($style, qr/#studio_pedalboard_rack \.pedal\s*\{[^}]*zoom:\s*var\(--studio-pedal-zoom,\s*1\)/s,
	'the rack pedals zoom with the setting');
like($style, qr/\.studio_rack_placeholder\s*\{[^}]*zoom:\s*var\(--studio-pedal-zoom,\s*1\)/s,
	'and the drag placeholder scales the same way');
like($style, qr/#studio_pedalboard_rack\s*\{[^}]*max-height:\s*min\(calc\(240px \* var\(--studio-pedal-zoom,\s*1\)\),\s*70vh\)/s,
	'the rack max-height scales with the pedals');
like($style, qr/#pedalboard\s*\{[^}]*max-height:\s*min\(calc\(344px \* var\(--studio-pedal-zoom,\s*1\)\),\s*80vh\)/s,
	'and so does the whole sheet');

# --- the drawn stomp plate on every pedal ----------------------------------
like($markup, qr/<button type="button" class="studio_pedal_foot studio_pedal_stomp"/,
	'a pedal footswitch is a drawn button');
like($markup, qr/studio_pedal_stomp[^>]*control="stomp"/, 'it names the stomp control');
like($markup, qr/studio_pedal_stomp[^>]*effect="<%= \$p->\{'name'\} %>"/,
	'the shelf loop names its own pedal');
like($markup, qr/studio_pedal_stomp[^>]*effect="<%= \$name %>"/,
	'the drawn palette loop names its own pedal');
my @stomp = $markup =~ /studio_pedal_stomp/g;
is(scalar @stomp, 2, 'both the shelf and the drawn palette loops carry the switch');
like($markup, qr/hint="[^"]*">(?:<span aria-hidden="true"><\/span>){4}/,
	'the switch is a plate with four grip lines');
unlike($markup, qr/studio_pedal_stomp[^>]*\bsrc=/, 'no stomp image is drawn any more');

like($style, qr/\.studio_pedal_foot\s*\{[^}]*left:\s*8%/s,
	'the plate is placed by left, not a translate that a press could replace');
like($style, qr/\.studio_pedal_foot span\s*\{[^}]*height:\s*2px/s,
	'the four grip lines are bars');
unlike($style, qr/\.pedal\.pedal_art::after/, 'no lower-case panel covers the artwork');
like($markup, qr/foreach my \$name \( \@\{\$gb::studio->\{'palette'\}\} \) \{ %>/,
	'every effect is drawn in the theme body');
like($markup, qr/next unless \$p->\{'name'\} eq 'Jtune' \|\| \$p->\{'name'\} eq 'JawnSynth'/,
	'only the tuner and the synth keep their own faces');
like($style, qr/\.pedal_controls\s*\{[^}]*bottom:\s*35%/s,
	'the drawn pedals leave room for the switch');
like($style, qr/\.pedal_knob_label\s*\{[^}]*text-overflow:\s*ellipsis/s,
	'a long knob name ellipsises in its own cell instead of overlapping the next');
like($style, qr/\.pedal_knob\s*\{[^}]*width:\s*36px/s, 'four 36px knob cells fit one row in a tile');
like($style, qr/\.studio_board_readonly \.studio_pedal_foot/, 'a read-only board still marks its switch');

# --- the Distorjawn's knob is Drive ---------------------------------------
like($studio, qr/name => 'Distorjawn',[\s\S]{0,400}?control => 'drive'/,
	'Distorjawn uses the contract drive control');
unlike($studio, qr/name => 'Distorjawn',[\s\S]{0,400}?control => 'gain'/,
	'and no longer the old gain name');
like($studio, qr/# The artwork pedal uses the contract's `drive` control/,
	'the legacy gain alias is explained in a comment');

# --- Chromatic is offered for both scale controls --------------------------
my @chromatic = $studio =~ /options => \[ qw\(Major Minor Chromatic Pentatonic\) \]/g;
is(scalar @chromatic, 2, 'both the autotune and harmonizer scales include Chromatic');
like($studio, qr/autotune => \{ label => 'JawnPitch'[\s\S]{0,600}?options => \[ qw\(Major Minor Chromatic Pentatonic\) \]/,
	'JawnPitch (autotune) offers Chromatic');
like($studio, qr/harmonizer => \{ label => 'Harmonizer'[\s\S]{0,900}?options => \[ qw\(Major Minor Chromatic Pentatonic\) \]/,
	'the Harmonizer offers Chromatic');
like($studio, qr/name => 'harmonizer',[\s\S]{0,900}?selects => \[[\s\S]{0,400}?\{ control => 'scale'/,
	"the Harmonizer's shelf tile carries the scale select");

# --- the help topic says all of it ----------------------------------------
like($help, qr/Configure fills the whole Studio window/,
	'the help says Configure fills the whole window');
like($help, qr/The \+ and .{1,4}buttons beside Close make the pedals bigger or smaller/,
	'the help names the + and - size buttons');
like($help, qr/size is remembered for the next visit/,
	'and says the size is remembered');
like($help, qr/footswitch: a drawn plate with four grip lines/,
	'the help describes the drawn footswitch');
unlike($help, qr/it reads On or Off/, 'and no longer describes a text On/Off swatch');
like($help, qr/Distortion.*?s one knob is Drive/, "the help names Distortion's Drive knob");
like($help, qr/JawnPitch and Harmonizer both offer a Chromatic scale/,
	'the help says both scale controls offer Chromatic');

# --- a saved board can be deleted -------------------------------------------
like($markup, qr/id="studio_board_delete"/, 'the board bar carries a delete control');
like($markup, qr/hint="[^"]*Delete this saved pedalboard/, 'the delete control says what it does');
like($help, qr/Delete this saved pedalboard/, 'the help lists the delete control');
like($help, qr/press Delete board twice/, 'the help explains the two-press delete');
like($help, qr/removal stays in the house list/, 'the help explains the tombstone');

done_testing();
