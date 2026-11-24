# tests-for: public/js/music.js templates/apps/music/music.html.ep templates/apps/music/audio.html.ep
# covers:    The Audio and Configure drawers stay closeable across a window
#            render: the open sheet lives on the window frame, a fresh render
#            brings another hidden shell with the same id, and every reader
#            (the X, the doors, the loader) must reach the sheet on screen.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $music = read_file("$root/public/js/music.js");
my $template = read_file("$root/templates/apps/music/music.html.ep");
my $audio_tpl = read_file("$root/templates/apps/music/audio.html.ep");

# The drawer floats onto the window's frame (musicConfigFloat) so it can cross
# the whole screen and sit above the title bar. A window re-render replaces
# .window_contents only - the open sheet survives as a child of .wind - while
# the template brings another hidden shell wearing the same id. From then on
# $('#music_audio_panel') was the hidden shell (first in document order), so the
# X hid the wrong sheet and the open drawer could not be closed. Playing a list
# from Folders or the Guide (musicToggle(files)) re-renders the window, which is
# how a track change reached this.

# --- the marker and the one reader -----------------------------------------
like($music, qr/panel\.attr\('music_window', win\.attr\('id'\)\);/,
	'the sheet that moves onto the frame is marked');
like($music, qr/function musicConfigSheet\(id\)\s*\{\s*\n\s*var sheets = \$\('#' \+ id\);\s*\n\s*var marked = sheets\.filter\('\[music_window\]'\);\s*\n\s*return marked\.length \? marked\.first\(\) : sheets\.first\(\);\s*\n\}/,
	'the live sheet is the marked one, with the template shell as the fallback');

# --- the X closes the sheet it belongs to ----------------------------------
like($music, qr/'#music_audio_close', function\(e\) \{\s*\n\s*e\.preventDefault\(\);\s*\n(?:\s*\/\/[^\n]*\n)*\s*\$\(this\)\.closest\('\.music_cfg_drawer'\)\.hide\(\);/,
	'the Audio close button hides its own sheet');
like($music, qr/'#music_configuration_close', function\(e\) \{\s*\n\s*e\.preventDefault\(\);\s*\n(?:\s*\/\/[^\n]*\n)*\s*\$\(this\)\.closest\('\.music_cfg_drawer'\)\.hide\(\);/,
	'the Configure close button hides its own sheet');
unlike($music, qr/\$\('#music_audio_panel'\)\.hide\(\)/,
	'no close path hides the first #music_audio_panel it finds');
unlike($music, qr/\$\('#music_configuration'\)\.hide\(\)/,
	'no close path hides the first #music_configuration it finds');

# --- the doors and the loader open the live sheet --------------------------
like($music, qr/'#music_audio_toggle', function\(\) \{\s*\n\s*var panel = musicConfigSheet\('music_audio_panel'\);/,
	'the Audio door reads the live sheet');
like($music, qr/function musicAudioPanelLoad\(show\) \{\s*\n(?:\s*\/\/[^\n]*\n)*\s*var panel = musicConfigSheet\('music_audio_panel'\);/,
	'the Audio loader fills the live sheet');
like($music, qr/'#music_configuration_toggle', function\(\) \{\s*\n\s*var mc = musicConfigSheet\('music_configuration'\);/,
	'the Configure door reads the live sheet');
like($music, qr/if \(audio_sheet\.length && !audio_sheet\.children\(\)\.length\)/,
	'musicInit checks the live Audio sheet before fetching it');
like($music, qr/var configOpen = musicConfigSheet\('music_configuration'\)\.is\(':visible'\);/,
	'a search reads the Configure sheet that is actually on screen');
like($music, qr/musicConfigSheet\('music_configuration'\)\.replaceWith\(fragment\.find\('#music_configuration'\)\);/,
	'and refreshes that sheet');
like($music, qr/musicConfigShow\(musicConfigSheet\('music_configuration'\)\);/,
	'and re-shows the live one after the render');
like($music, qr/var mc = musicConfigSheet\('music_configuration'\);\s*\n\s*if \(mc\.is\(':visible'\)\) \{ musicConfigFloat\(mc\); \}/,
	'the window setup floats the live Configure sheet');

# --- the template still carries a shell for the cache to replay -------------
like($template, qr/<div id="music_audio_panel" class="music_cfg_drawer" style="display:none;"><\/div>/,
	'the template keeps the Audio shell a cached window replays');
like($template, qr/<div id="music_configuration" class="music_cfg_drawer"/,
	'and the Configure shell');
like($audio_tpl, qr/id="music_audio_close"/, 'the Audio sheet carries its own X');

done_testing();
