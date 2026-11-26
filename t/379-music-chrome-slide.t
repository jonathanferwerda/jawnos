# tests-for: public/css/music.css public/js/music.js templates/apps/video/script.html.ep templates/apps/video/markup.html.ep templates/apps/video/style.html.ep
# covers:    The Music window's theatre chrome slides. #interface leaves the
#            top edge and the player bar leaves the foot instead of fading.
#            One class (music_chrome_hidden) is the state, because a bar moved
#            off its edge is still :visible to jQuery; the bars keep their
#            display so the CSS transform can animate both ways, and the
#            cached shell stores them without the runtime state. The reveal
#            answers a real move or tap only: the bars sliding away change the
#            hover target and the engine raises its own mouseenter at the
#            picture, which used to show them again for ever.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $css = read_file("$root/public/css/music.css");
my $js = read_file("$root/public/js/music.js");
my $video = read_file("$root/templates/apps/video/script.html.ep");
my $style = read_file("$root/templates/apps/video/style.html.ep");
my $markup = read_file("$root/templates/apps/video/markup.html.ep");

# --- the motion: the top bar up, the bottom bar down ------------------------
like($css, qr/#music #interface\.music_chrome_hidden \{[^}]*transform:\s*translateY\(-100%\)/s,
	'the interface leaves the top edge');
like($css, qr/#music \.media_controls\.music_player_bar\.music_chrome_hidden \{[^}]*transform:\s*translateY\(100%\)/s,
	'the player bar leaves the bottom edge');
like($css, qr/#music #interface,\s*#music \.media_controls\.music_player_bar \{\s*transition:\s*transform \.3s ease, opacity \.3s ease;/s,
	'both bars transition the slide');
like($css, qr/#music #interface\.music_chrome_hidden \{[^}]*pointer-events:\s*none/s,
	'an off-screen interface cannot be clicked');
like($css, qr/#music #interface\.music_chrome_hidden \{[^}]*visibility:\s*hidden/s,
	'and leaves the focus order once it is gone');
like($css, qr/#music \.media_controls\.music_player_bar\.music_chrome_hidden \{[^}]*pointer-events:\s*none/s,
	'an off-screen player bar cannot be clicked');
like($css, qr/#music \.media_controls\.music_player_bar\.music_chrome_hidden \{[^}]*visibility:\s*hidden/s,
	'and leaves the focus order once it is gone');
like($css, qr/visibility 0s linear \.3s/, 'the visibility flip waits for the slide out');
like($css, qr/\@media \(prefers-reduced-motion: reduce\) \{\s*#music #interface,\s*#music #interface\.music_chrome_hidden,\s*#music \.media_controls\.music_player_bar,\s*#music \.media_controls\.music_player_bar\.music_chrome_hidden \{ transition: none; \}/s,
	'no motion is asked for with prefers-reduced-motion');

# --- the state helpers ------------------------------------------------------
like($js, qr/function musicChromeShow\(el\)/, 'music.js has a show helper');
like($js, qr/function musicChromeHide\(el\)/, 'and a hide helper');
like($js, qr/el\.addClass\('music_chrome_hidden'\)\.show\(\);/, 'a first reveal starts off the edge');
like($js, qr/musicChromeHide\(\$\('#interface'\)\);/, 'entering the theatre hides the interface by the class');
unlike($js, qr/\$\('#interface'\)\.hide\(\);/, 'it no longer drops the interface out of the layout');
like($js, qr/musicChromeShow\(\$\('#interface'\)\);/, 'leaving the theatre shows the interface by the class');
unlike($js, qr/\$\('#interface'\)\.show\(\);/, 'it no longer restores the interface with display alone');
like($js, qr/musicChromeShow\(\$\('#music \.media_controls\.music_player_bar'\)\);/, 'leaving also restores the player bar');
like($js, qr/shell\.find\('#interface, \.media_controls\.music_player_bar'\)\.removeClass\('music_chrome_hidden'\)/,
	'the cached shell does not keep a runtime-hidden bar');

# The window itself brings the bars back on a move or a tap: the video
# include's own binding can be missing on a restored shell (or removed by a
# second include with the same element id), and a touch has no mousemove.
like($js, qr/\$\(document\)\.on\('mousemove touchstart pointerdown', '#music'/,
	'the window brings its bars back on a real move or tap');
unlike($js, qr/\$\(document\)\.on\('mousemove mouseenter touchstart pointerdown', '#music'/,
	'but not on a mouseenter the sliding bars can raise by themselves');
like($js, qr/musicChromeShow\(\$\('#music \.media_controls\.music_player_bar'\)\);/,
	'including the player bar over the album artwork');
like($css, qr/#music \.media_controls\.music_player_bar \{ z-index: 16; \}/,
	'the bar rides above the picture');

# A narrow bar cannot hold the transport, theatre, shuffle, repeat, tools,
# title and fullscreen once the 380px step enlarges them: the fullscreen button
# wrapped to a third row. The compact step is last so it answers the
# enlargement, and it stops at 560px where the row has room again.
like($style, qr/\@container \(max-width: 559px\)/, 'a narrow player bar has a compact step');
like($style, qr/\@container \(max-width: 559px\) \{.*?\.music_player_bar \.medium_thumb \{ height: 36px; max-width: 42px; \}/s,
	'the transport icons shrink there');
like($style, qr/\@container \(max-width: 559px\) \{.*?\.music_shuffle,.*?\.little_thumb \{ height: 30px; \}/s,
	'and so do the small buttons');
my $compact_at = index($style, '@container (max-width: 559px)');
my $enlarged_at = index($style, '@container (min-width: 380px)');
my $widest_at = index($style, '@container (min-width: 760px)');
ok($compact_at > $enlarged_at && $compact_at > $widest_at,
	'the compact step comes last, so it wins in a small window');

# The visualization is the one native <select> in the player. A fullscreen
# popup can be refused or painted behind the top layer, so in a big picture the
# same control becomes an inline list whose options are ordinary clicks.
like($js, qr/function musicVisualSelectSize\(\)/, 'the visualizer becomes a list in a big picture');
like($js, qr/var want = musicPictureBig\(\) \? sel\.options\.length : 1;/,
	'all choices inline there, the dropdown in the window');
like($video, qr/musicVisualSelectSize\(\)/, 'the tools toggle sizes it as the panel opens');
like($js, qr/toggleClass\('media_visualization_list', want > 1\)/, 'the list class follows the size');
like($style, qr/\.media_visualization\.media_visualization_list \{ width: 150px; height: auto; \}/,
	'the inline list can show its rows') || diag('list rule moved');

# --- the include asks the state, not the display ----------------------------
like($video, qr/musicChromeShow\(controls\)/, 'a mouse move slides the player bar in');
like($video, qr/musicChromeShow\(music_iface\)/, 'and the interface with it');
like($video, qr/vidOn\('mousemove', '#<%=\s*\$id\s*%>/,
	'the include reveals on a real pointer move');
unlike($video, qr/vidOn\('mousemove mouseenter'/,
	'not on the mouseenter the sliding bars raise at the picture');
like($js, qr/\$\('#video'\)\.trigger\('mousemove'\)/,
	'the window init asks for that move too');
like($video, qr/controls\.hasClass\('music_chrome_hidden'\) \|\| !controls\.is\(':visible'\)/,
	'the include asks the class (or a real display hide)');
like($video, qr/musicChromeHide\(\$\('#<%=\s*\$miss\s*%>_controls'\)\)/, 'an idle pointer slides the player bar out');
like($video, qr/musicChromeHide\(\$\('#interface'\)\)/, 'and the interface with it');
like($video, qr/if \(!controls\.is\(':visible'\)\) \{ controls\.fadeIn\(\); \}/,
	'the video app still fades its own bar in');
like($video, qr/\$\('#interface'\)\.fadeOut\('slow'\)/,
	'and the video app still fades the interface');
unlike($markup, qr/class="media_controls[^>]*style="[^"]*opacity:1/,
	'the player bar carries no inline opacity to fight the slide');

# A resting pointer over a bar is still chrome: once it stops, the bars leave
# with the picture, so a room watching from across the screen does not need a
# mouse move to clear them.
like($video, qr/var idle = \(mouse\.lastX == mouse\.x && mouse\.lastY == mouse\.y\);/,
	'the idle test asks whether the pointer moved');
like($video, qr/if \(!idle\) \{ seen = 1; \}/, 'a bar under a resting pointer no longer keeps the chrome');

# Leaving the big picture gives both bars back; the idle timer may have left
# them off the edges.
my ($off) = $js =~ /(function musicFullscreenOff\(\)\s*\{.*?\n\})/s;
ok(defined $off, 'musicFullscreenOff is found');
like($off || '', qr/musicChromeShow\(\$\('#interface'\)\);/, 'leaving full screen shows the interface');
like($off || '', qr/musicChromeShow\(\$\('#music \.media_controls\.music_player_bar'\)\);/, 'and the player bar');
my ($change) = $js =~ /(\$\(document\)\.on\('fullscreenchange webkitfullscreenchange'.*?\n\}\);)/s;
ok(defined $change, 'the fullscreenchange handler is found');
like($change || '', qr/else if \(musicWasFullscreen\)[\s\S]*?musicChromeShow\(\$\('#interface'\)\);/, 'a real leave shows the interface');
like($change || '', qr/else if \(musicWasFullscreen\)[\s\S]*?musicChromeShow\(\$\('#music \.media_controls\.music_player_bar'\)\);/, 'and the player bar');

# The library is hidden in full screen even though a track play can leave an
# inline display:block on it; the inline style would otherwise win.
like($css, qr/#music\.music_fullscreen #music_library \{\s*display: none !important;/s,
	'the library leaves the screen even over an inline display');
like($css, qr/#music:fullscreen #music_library,\s*\n#music:-webkit-full-screen #music_library,\s*\n#music\.music_fullscreen #music_library/s,
	'the three full-screen dresses agree');

# A long title shrinks to fit and ellipsizes at the floor, rather than wrapping
# into the fullscreen button.
like($style, qr/\.music_player_bar #<%= \$id %>_full_title \{[^}]*white-space: nowrap;[^}]*text-overflow: ellipsis;/s,
	'the bar title stays on one line');
like($js, qr/function musicTitleFit\(\)/, 'the bar shrinks a long title to fit');
like($js, qr/node\.scrollWidth > node\.clientWidth/, 'by measuring the text against its room');
like($video, qr/musicTitleSet\(played_title\)/, 'the bar tick uses the fitting setter');

done_testing();
