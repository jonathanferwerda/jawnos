# tests-for: public/css/music.css
# covers:    A player switch that is on should read as a lit seat. The
#            subtitles button did; shuffle and repeat did not, because the
#            player bar resets every icon to a transparent background and the
#            bare .shuffle/.repeat class rules could not win that reset. One
#            ID-qualified rule now lights all three the same way.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

my $css = read_file("$FindBin::Bin/../public/css/music.css");

like($css,
	qr/#video_subtitle_toggle\[status=showing\],\s*\n\s*#music_shuffle\[enabled=on\],\s*\n\s*#music_repeat\[enabled=on\]\s*\{[^}]*background-color: lightgreen;/s,
	'one rule lights subtitles, shuffle and repeat the same way');

# The player bar's own rule is `.music_player_bar .music_shuffle { border: none;
# background: transparent; }` (two classes). An ID-qualified attribute selector
# outranks it, which is why the on state can paint at all; a bare
# `.shuffle[enabled=on]` would tie and lose to the later template rule.
like($css, qr/#music_shuffle\[enabled=on\]/,
	'shuffle is ID-qualified, so the bar cannot reset its on background');
like($css, qr/#music_repeat\[enabled=on\]/,
	'repeat is ID-qualified too');

# The click handlers keep the attributes this CSS reads.
my $js = read_file("$FindBin::Bin/../public/js/music.js");
like($js, qr/\.on\('click', '\.music_shuffle'[\s\S]{0,400}\$\(this\)\.attr\('enabled', shuffle\)/,
	'shuffle keeps the enabled attribute the rule reads');
like($js, qr/settingSetter\(\{ app: 'music', setting: 'repeat', value: repeat \}\);\s*\n\s*\$\(this\)\.attr\('enabled', repeat\);/,
	'repeat keeps the enabled attribute the rule reads');

done_testing();
