# tests-for: public/css/music.css public/js/music.js templates/apps/video/script.html.ep templates/apps/video/markup.html.ep
# covers:    The Music window's theatre chrome slides. #interface leaves the
#            top edge and the player bar leaves the foot instead of fading.
#            One class (music_chrome_hidden) is the state, because a bar moved
#            off its edge is still :visible to jQuery; the bars keep their
#            display so the CSS transform can animate both ways, and the
#            cached shell stores them without the runtime state.

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

# --- the include asks the state, not the display ----------------------------
like($video, qr/musicChromeShow\(controls\)/, 'a mouse move slides the player bar in');
like($video, qr/musicChromeShow\(music_iface\)/, 'and the interface with it');
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

done_testing();
