# tests-for: public/js/music.js templates/apps/video/markup.html.ep templates/apps/video/script.html.ep templates/apps/video/style.html.ep
# covers:    In theatre mode or a fullscreen the Music player draws a film's
#            chapters just above the player bar - above the More tools panel
#            while it is open - as 200x120 cards on a translucent band that
#            scrolls sideways when they do not all fit, and a card seeks.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $js = read_file("$root/public/js/music.js");
my $markup = read_file("$root/templates/apps/video/markup.html.ep");
my $style = read_file("$root/templates/apps/video/style.html.ep");
my $script = read_file("$root/templates/apps/video/script.html.ep");

# --- the strip exists only in the music player's own branch -----------------
like($markup, qr!<div id="<%= \$miss %>_chapters" class="music_chapters"></div>!,
	'the music markup carries an empty chapter strip');
unlike($markup, qr!id="<%= \$miss %>_chapters"[^>]*style=!,
	'no inline display on it: a .shown class could not beat one');

# --- it sits above the bar, on a translucent band, and scrolls sideways ------
like($style, qr!\.music_chapters \{[^}]*position:\s*absolute;[^}]*bottom:\s*112px;!,
	'the strip is absolutely placed just above the 110px bar');
like($style, qr!\.music_chapters \{[^}]*overflow-x:\s*auto;!, 'more chapters than fit scroll sideways');
like($style, qr!\.music_chapters \{[^}]*background-color:\s*rgba\(0,0,0,\.45\);!,
	'the band is semi-transparent');
like($style, qr!\.music_chapters\.shown \{ display: flex; \}!, 'music.js shows it by a class');
like($style, qr!\.music_chapters \.music_chapter_tile \{[^}]*width:\s*200px;[^}]*height:\s*120px;!,
	'each chapter card is the size of the seek preview thumb');

# --- the bar's blanket static reset must not flatten the strip --------------
like($style, qr!\*:not\(\.media_tools_panel\)[^\n]*:not\(\.music_chapters\)!,
	'the player bar reset excludes the chapter strip');

# --- the queue entry draws the cards ---------------------------------------
like($js, qr!function musicChaptersRefresh\(\)!, 'music.js has the refresh helper');
like($js, qr!var wanted = musicPictureBig\(\) && \$\('#video'\)\.attr\('type'\) == 'video' && chapters\.length > 0;!,
	'chapters show only for a video with chapters in the theatre or a fullscreen');
like($js, qr!'&chapter=ya' \+ remote!, 'each card asks for its own chapter thumbnail');
like($js, qr!\.attr\('data-artwork', url\)!, 'the artwork collector fills the thumb lazily');
like($js, qr!'&start_time=' \+ encodeURIComponent\(ch\.start_time \|\| 0\)!,
	'the chapter start is URL-escaped');

# --- an open More tools panel pushes the chapters up ------------------------
like($js, qr!if \(panel\.hasClass\('shown'\)\) \{ bottom \+= panel\.outerHeight\(\) \+ 8; \}!,
	'an open tools panel moves the strip above itself');
like($script, qr!musicChaptersPlace\(\);!,
	'the tools toggle asks the strip to move once the panel has a height');
like($script, qr!<% if \(\$source eq 'music'\) \{ %>\s*// the chapter strip[^%]*?musicChaptersPlace\(\);!,
	'and only the music player does so');

# --- entering and leaving the big picture ----------------------------------
my $calls = () = $js =~ /musicChaptersRefresh\(\);/g;
cmp_ok($calls, '>=', 4, 'the theatre, fullscreen, repaint and cache paths all refresh it');
like($js, qr!shell\.find\('\.music_chapters'\)\.removeClass\('shown'\)\.empty\(\)\.removeAttr\('data-sig'\)!,
	'the cached shell stores no stale chapter row');

# --- a reload arms the bar's idle hide --------------------------------------
like($script, qr!function <%= \$miss %>ChromeArm\(\)!, 'the include has an armable idle timer');
like($script, qr!window\.jawnosMusicChromeArm = <%= \$miss %>ChromeArm;!,
	'and hands it to the music player');
like($js, qr!function musicChromeArm\(\)!, 'music.js has the caller');
my $arm = () = $js =~ /musicChromeArm\(\);/g;
cmp_ok($arm, '>=', 2, 'the theatre and fullscreen both arm it');

# --- a card is a seek -------------------------------------------------------
like($js, qr!\$\(document\)\.on\('click', '\.music_chapter_tile'!, 'a card is clickable');
like($js, qr!v\.currentTime = start;!, 'and seeks the picture to that chapter');

# --- the wheel over the row scrolls it, never the film ----------------------
like($script, qr!\.jog_wheel, \.music_chapters'!, 'the player gesture leaves the chapter row alone');
like($js, qr!\$\(document\)\.on\(musicChapterWheel, '\.music_chapters'!, 'music.js owns the wheel over the row');
like($js, qr!this\.scrollLeft \+= dy \* step;!, 'a vertical wheel moves the row sideways');
like($js, qr!if \(Math\.abs\(dx\) >= Math\.abs\(dy\)\) \{ return; \}!, 'a sideways swipe is left to the browser');
like($style, qr!touch-action:\s*pan-x;!, 'a finger pans the row instead of scrubbing');

done_testing();
