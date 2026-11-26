# tests-for: public/js/manager/studio/11_drums.js templates/studio/style.html.ep perl/help/topics_apps.pl
# covers:    The drum step grid's arrow keys: Left and Right walk the steps,
#            Up and Down change the voice, Ctrl with Up or Down tunes the beat
#            under the cursor by ten inside 10..100 (and places an empty one at
#            70 first). The cursor is painted on one cell, follows a click, and
#            the arrows belong to the panel only while the drums window is the
#            surface in use. Structure only; pixels are not asserted here.

use strict;
use warnings;

use FindBin;
use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or die "cannot read $path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $root = $FindBin::Bin;
$root =~ s{/t$}{};
my $drums = slurp("$root/public/js/manager/studio/11_drums.js");
my $style = slurp("$root/templates/studio/style.html.ep");
my $help  = slurp("$root/perl/help/topics_apps.pl");

# --- the cursor and its moves ----------------------------------------------
like($drums, qr/function studioDrumsGridVoices\(\)/, 'the grid knows its voices in order');
like($drums, qr/function studioDrumsCursor\(\)/, 'one helper clamps the cursor');
like($drums, qr/studioDrums\.cursor = \{ voice: voices\[vi\], step: step \};/,
	'the cursor is a voice and a step');
like($drums, qr/function studioDrumsCursorSet\(voice, step\)/, 'one helper paints it');
like($drums, qr/\.addClass\('studio_drums_cursor'\)\.attr\('aria-current', 'true'\)/,
	'the cell is marked for sight and for a screen reader');
like($drums, qr/el\.scrollIntoView\(\{ block: 'nearest', inline: 'nearest' \}\)/,
	'moving the cursor brings the cell into view');
like($drums, qr/function studioDrumsGridMove\(key\)/, 'the moves are one helper');
like($drums, qr/key === 'ArrowLeft'[\s\S]{0,160}studioDrumsCursorSet\(c\.voice, c\.step - 1\)/,
	'Left walks back a step');
like($drums, qr/key === 'ArrowRight'[\s\S]{0,160}studioDrumsCursorSet\(c\.voice, c\.step \+ 1\)/,
	'Right walks on a step');
like($drums, qr/key === 'ArrowUp'[\s\S]{0,200}c\.voices\[Math\.max\(0, c\.index - 1\)\]/,
	'Up changes to the voice above');
like($drums, qr/key === 'ArrowDown'[\s\S]{0,200}c\.voices\[Math\.min\(c\.voices\.length - 1, c\.index \+ 1\)\]/,
	'Down changes to the voice below');

# --- Ctrl+Up/Down is the velocity ------------------------------------------
like($drums, qr/function studioDrumsGridVelocity\(delta\)/, 'the velocity change is one helper');
like($drums, qr/value = Math\.max\(10, Math\.min\(100, value \+ delta\)\);/,
	'it stays inside the ten-to-one-hundred range');
like($drums, qr/if \(delta < 0\) \{ return true; \}\s*\n\s*value = 70;/,
	'a hard press places an empty step at seventy; a soft one does nothing');
like($drums, qr/studioDrumsTrigger\(c\.voice, value, false\);/,
	'the tuned beat is heard');
like($drums, qr/studioDrumsSaver\(\);/,
	'and the chart is saved');

# --- the key handler and its guard -----------------------------------------
like($drums, qr/\$\('#studio_drums'\)\.length\) \{ return; \}/,
	'the arrows need the drums panel');
like($drums, qr/if \(!studioDrums\.gridFocus \|\| studioDrums\.learn \|\| studioDrumsTyping\(\)\) \{ return; \}/,
	'typing and key-learning keep every arrow to themselves');
like($drums, qr/if \(e\.metaKey \|\| e\.altKey \|\| e\.shiftKey\) \{ return; \}/,
	'only a plain or Ctrl arrow is a grid move');
like($drums, qr/studioDrumsGridVelocity\(e\.key === 'ArrowUp' \? 10 : -10\)/,
	'Ctrl+Up raises and Ctrl+Down lowers by ten');
like($drums, qr/if \(handled\) \{ e\.preventDefault\(\); e\.stopPropagation\(\); \}/,
	'a handled arrow does not also scroll or reach another control');
like($drums, qr/studioDrums\.gridFocus = .{0,40}closest\('#studio_drums'\)\.length;/,
	'a press in the drums panel hands the arrows to the grid');
like($drums, qr/studioDrumsCursorSet\(voice, step\);/,
	'clicking a step puts the cursor there');
like($drums, qr/if \(cursor\) \{ studioDrumsCursorSet\(voice, cursor\.step\); \}/,
	'clicking a drum\'s name lands the cursor on that voice');

# --- the cursor is not the scheduler's column ------------------------------
like($style, qr/\.studio_drums_step\.studio_drums_cursor\s*\{[^}]*outline:\s*2px dashed/s,
	'the cursor is a dashed outline, apart from the playing column');
like($style, qr/\.studio_drums_step\.studio_drums_playing\s*\{[^}]*outline:\s*2px solid/s,
	'the sounding column keeps its solid outline');

# --- the help says so ------------------------------------------------------
like($help, qr/the arrow keys walk the step grid/,
	'help names the arrow keys');
like($help, qr/Ctrl with Up or Down makes the beat under the cursor harder or softer/,
	'and the velocity keys');
like($help, qr/a hard press on an empty step places it at 70 first/,
	'and what a first hard press does');

done_testing();
