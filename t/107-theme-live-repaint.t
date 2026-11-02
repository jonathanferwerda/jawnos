# tests-for: public/js/universal/05_theme_ink_icon_swap.js
# covers:    A real theme change repaints the desk in place: the icon swap and the start-menu/taskbar chrome follow the new dressing, but no app window is re-opened, so Music keeps playing and Configure keeps its place.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Starting or stopping an appointment whose theme differs from the current one
# pushes a new theme bundle over the websocket. The old path then called
# appWindowOpener on every .wind, which re-fetched each app's route: Music's
# musicInit tore down the player (playback stopped), and Configure re-rendered
# and lost its scroll/section state.
#
# The paint itself is CSS - the body colour, --jawnos-font, the corner, the
# texture, the dark-theme wash and the ink pass - and a window's title bar and
# drawer wear the app's own colour plus --appt-dark, not the theme's. So the
# only server-rendered chrome that needs asking again is the start menu (whose
# markup bakes icon paths and theme colours) and the taskbar. These pins keep
# the repaint live and keep any future change from re-introducing the re-render.

my $js = js_source('public/js/universal/05_theme_ink_icon_swap.js');

# --- no window contents are replaced ----------------------------------------

unlike($js, qr/\$\(\s*['"]\.wind['"]\s*\)\s*\.each\s*\(.*?appWindowOpener/s,
	'the theme refresh does not re-open every .wind');

my ($reload_body) = $js =~ /function\s+jawnosReloadIcons\s*\(\s*\)\s*\{(.*?)\n\}/s;
ok(defined $reload_body && length $reload_body, 'the reload-icons body is found');
unlike($reload_body // '', qr/appWindowOpener|appointmentGrabber/,
	'the reload-icons body re-renders no window, so stateful apps keep their state');

# --- the chrome still follows the theme -------------------------------------

like($js, qr{url:\s*['"]/manager/icons['"]},
	'the icons already on screen are re-mapped through /manager/icons');
like($js, qr/\{[^}]*paths:\s*JSON\.stringify\(paths\),\s*refresh:\s*1\s*\}/,
	'every current icon path is asked for, with the cache refreshed');
like($js, qr/startMenuHtmlFlush\s*\(/,
	'the per-tab start-menu markup cache is flushed');
like($js, qr/startMenuToggle\(\s*\{\s*source:\s*['"]icon_refresh['"]\s*\}\s*\)/,
	'an open start menu is refreshed in place');
like($js, qr/startMenuListify\s*\(/,
	'the start-menu list is rebuilt');
like($js, qr/taskbarDisplayer\s*\(/,
	'the taskbar chips are refreshed');

# --- the theme bundle still filters an unchanged signature ------------------

like($js, qr/function\s+jawnosThemeBundleApply\s*\(/,
	'the websocket theme entry point exists');
like($js, qr/var\s+current\s*=\s*document\.body\.getAttribute\(\s*['"]data-theme-sig['"]\s*\)\s*\|\|\s*['"]{2}/,
	'the bundle reads the signature the body is wearing');
like($js, qr/if\s*\(\s*sig\s*&&\s*sig\s*===\s*current\s*\)\s*\{\s*return;\s*\}/,
	'an unchanged signature is a no-op before any repaint');
like($js, qr/document\.body\.setAttribute\(\s*['"]data-theme-sig['"]\s*,\s*sig\s*\)/,
	'a landed bundle records its signature');

# --- the bundle still drives the live paint and the chrome refresh ----------

like($js, qr/jawnosApplyInk\(\s*bundle\.accent\s*\|\|\s*['"]{2}\s*\)/,
	'the ink pass still repaints the live variables');
like($js, qr/setTimeout\(\s*jawnosReloadIcons\s*,\s*60\s*\)/,
	'a real theme change still asks for the icon/chrome refresh');

done_testing();
