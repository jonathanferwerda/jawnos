# tests-for: public/js/manager/studio/04_knobs.js public/js/manager/studio/07_layout.js templates/studio/markup.html.ep templates/studio/style.html.ep t/348-studio-track-colour.t
# covers:    A track's persisted colour: the swatch in the row, the style hook
#            that dresses the panel edge, the random theme-family generator
#            (jawnosHslToHex guarded, dark/light lightness), reading and
#            applying one, the assignment on a new track, save and restore of
#            `colour`, and the initial paint that colours server-rendered rows.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $layout = read_file("$root/public/js/manager/studio/07_layout.js");
my $knobs  = read_file("$root/public/js/manager/studio/04_knobs.js");

# --- the swatch lives in every track's first line ---------------------------
like($markup, qr/type="color"[^>]*class="studio_track_colour[^"]*"/,
	'the track carries a colour input');
like($markup, qr/class="studio_track_colour[^"]*"[^>]*channel="<%=\s*\$ch\s*%>"/,
	'the swatch is addressed by its channel');
like($markup, qr/class="studio_track_colour[^"]*"[\s\S]{0,160}?control="colour"/,
	'the swatch names its control');
like($markup, qr/class="studio_track_colour[^"]*"[\s\S]{0,160}?value="#3b7ddd"/,
	'the server-rendered swatch has a starting colour');
like($markup, qr/class="studio_track_colour[^"]*"[\s\S]{0,160}?hint=/,
	'the swatch explains itself');
my ($first_line) = $markup =~ /<div class="studio_track_line">(.*?)<\/div>/s;
like($first_line || '', qr/class="studio_track_colour/,
	'the swatch sits in the row\'s first line');

# --- the style hook dresses the panel edge ----------------------------------
like($style, qr/\.studio_track_colour\s*\{[^}]*flex:\s*0 0 18px/s,
	'the swatch is laid out as an 18px control');
like($style, qr/\.studio_track\[data-colour\]\s+\.studio_track_panel\s*\{[^}]*--studio-track-colour/s,
	'a coloured row reads its custom property on the panel');

# --- the helpers -----------------------------------------------------------
for my $fn (qw(studioRandomTrackColour studioTrackColour studioColourRgba
	studioApplyTrackColour studioApplyTrackColours)) {
	like($layout, qr/function \Q$fn\E\s*\(/, "$fn is declared");
}

# the generator uses the universal HSL helper, but survives its absence
like($layout, qr/typeof jawnosHslToHex !== 'function'/,
	'the generator guards the universal HSL helper');
like($layout, qr/jawnosHslToHex\(h, s, l\)/,
	'the generator makes its colour with jawnosHslToHex');
like($layout, qr/Math\.random\(\) \* 360/,
	'the hue is a random angle');
like($layout, qr/classList\.contains\('dark_theme'\)/,
	'the generator asks the theme whether it is dark');
like($layout, qr/0\.55 \+ Math\.random\(\) \* 0\.15/,
	'saturation stays in the theme family');
like($layout, qr/dark \? 0\.62 \+ Math\.random\(\) \* 0\.10 : 0\.42 \+ Math\.random\(\) \* 0\.10/,
	'lightness is brighter on a dark theme and deeper on a light one');
like($layout, qr/studioTrackHue/,
	'the last hue is remembered so consecutive tracks do not collide');
like($layout, qr/#6ea8ff[\s\S]*?#145abe/,
	'a small palette stands in when the HSL helper is missing');

# reading one: the swatch, then the row property, then a fallback
like($layout, qr/function studioTrackColour\(ch\)[\s\S]*?\.studio_track_colour\[channel="' \+ ch/,
	'studioTrackColour reads the swatch');
like($layout, qr/function studioTrackColour\(ch\)[\s\S]*?getPropertyValue\('--studio-track-colour'\)/,
	'studioTrackColour falls back to the row property');
like($layout, qr/STUDIO_TRACK_COLOUR = '#145abe'/,
	'an uncoloured row has a fixed fallback');
like($layout, qr/STUDIO_TRACK_COLOUR_RE = \/\^#\[0-9a-f\]\{6\}\$\/i/,
	'a stored colour must be a six-digit hex');

# rgba for the canvas fill
like($layout, qr/function studioColourRgba\(colour, alpha\)[\s\S]*?#\(\[0-9a-f\]\{3\}\|\[0-9a-f\]\{6\}\)/,
	'studioColourRgba accepts #rgb and #rrggbb');
like($layout, qr/return 'rgba\(' \+ r \+ ',' \+ g \+ ',' \+ b \+ ',' \+ alpha \+ '\)'/,
	'studioColourRgba builds an rgba() string');
like($layout, qr/function studioColourRgba\(colour, alpha\)[\s\S]*?if \(!m\) \{ return colour; \}/,
	'an unparseable colour is handed back untouched');

# applying one touches the swatch and the row, then the canvas
like($layout, qr/function studioApplyTrackColour\(ch, colour\)[\s\S]*?input\.val\(hex\)/,
	'applying a colour sets the swatch');
like($layout, qr/function studioApplyTrackColour\(ch, colour\)[\s\S]*?\$\(row\)\.attr\('data-colour', hex\)/,
	'applying a colour marks the row');
like($layout, qr/function studioApplyTrackColour\(ch, colour\)[\s\S]*?style\.setProperty\('--studio-track-colour', hex\)/,
	'applying a colour sets the row property');
like($layout, qr/function studioApplyTrackColour\(ch, colour\)[\s\S]*?studioDrawChannel\(ch\)/,
	'applying a colour repaints that channel');

# apply-all assigns to an uncoloured row, then paints
like($layout, qr/function studioApplyTrackColours\(\)[\s\S]*?studioRandomTrackColour\(\)/,
	'a row without a colour gets a random one');
like($layout, qr/function studioApplyTrackColours\(\)[\s\S]*?studioDrawTracks\(\)/,
	'apply-all repaints the tracks');
like($layout, qr/function studioApplyTrackColours\(\)[\s\S]*?typeof studioDrawRuler === 'function'[\s\S]*?studioDrawRuler\(\)/,
	'apply-all repaints the ruler when it exists');

# a new track gets its own colour, and a clone cannot inherit one
like($layout, qr/studioApplyTrackColour\(ch, studioRandomTrackColour\(\)\)/,
	'studioCreateTrack gives the new track its own colour');
like($layout, qr/function studioResetChannelMarkup\(node, ch\)[\s\S]*?node\.removeAttr\('data-colour'\)/,
	'resetting a cloned row drops its inherited colour');
like($layout, qr/function studioResetChannelMarkup\(node, ch\)[\s\S]*?removeProperty\('--studio-track-colour'\)/,
	'resetting a cloned row drops its inherited property');

# --- the song keeps the colour ---------------------------------------------
like($knobs, qr/\$\('\.studio_track_colour'\)\.each\(function\(i,v\)/,
	'the saver walks the colour inputs in its own pass');
like($knobs, qr/\$\('\.studio_track_colour'\)\.each\(function\(i,v\) \{[\s\S]*?song\[channel\]\['colour'\] = \$\(v\)\.val\(\);/,
	'the saver stores colour per channel');
like($knobs, qr/\$\('\.studio_track_colour'\)\.each\(function\(i,v\) \{[\s\S]*?!\/\^\[0-9\]\+\$\/\.test\(channel\)/,
	'the saver skips a non-numeric channel');
unlike($knobs, qr/\$\('\.knob_control, \.channel_volume, \.studio_pedal_model'\)[\s\S]{0,200}?studio_track_colour/,
	'the colour stays out of the channel appliers');

like($knobs, qr/if \(n == 'colour'\) \{[\s\S]*?studioApplyTrackColour\(i, w\);[\s\S]*?return;/,
	'the retriever applies a stored colour and returns early');
like($knobs, qr/studioApplyChannel\(i\);\s*\}\);[\s\S]{0,800}?studioApplyTrackColours\(\);/,
	'the retriever paints every row once the song is restored');
like($knobs, qr/studioApplyMonitor\(true\)[\s\S]{0,400}?studioApplyTrackColours\(\);/,
	'the monitor restore and the colour pass both survive in the retriever');
like($knobs, qr/function studioRetriever\(\)[\s\S]*?return song;/,
	'the retriever still returns the song');

# live editing redraws and saves; the swatch also selects the track
like($knobs, qr/\$\(document\)\.on\('input change', '\.studio_track_colour'/,
	'the swatch is live on input and change');
like($knobs, qr/\$\(document\)\.on\('input change', '\.studio_track_colour'[\s\S]*?studioApplyTrackColour\(channel, input\.val\(\)\);[\s\S]*?studioSaver\(\);/,
	'moving the swatch repaints and saves');
like($knobs, qr/\$\(document\)\.on\('click', '\.studio_track_colour'[\s\S]*?studioSelectedChannel = channel;/,
	'clicking the swatch selects its track');

done_testing();
