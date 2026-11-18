# tests-for: lib/JawnOS/Manager/Part22.pm public/css/manager.css public/js/manager/windows.js public/js/manager/windows/02_fit.js public/icons/sets/ perl/help/topics_features.pl perl/help/topics_apps.pl t/340-window-fullview.t
# covers:    A window given the whole glass: a title-bar control beside the pin,
#            the title bar put away, a corner button that reveals itself as the
#            way back, the box saved on the way in, a fresh glyph in every set,
#            and help that names all of it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Maximising stops at the taskbar and the dock, which is what most windows want.
# A double-press used to fill the rest of the screen, but the single-click
# maximise always won the race with the double, so the gesture never felt
# reliable. It is now a control beside the pin, on every window: the box is kept
# before the class goes on, the title bar is hidden, and the button that leaves
# waits in the top right corner until the pointer reaches it.

my $root = repo_root();
my $maker = read_file("$root/lib/JawnOS/Manager/Part22.pm");
my $css = read_file("$root/public/css/manager.css");
my $windows = read_file("$root/public/js/manager/windows.js");
my $fit = read_file("$root/public/js/manager/windows/02_fit.js");
my $build = read_file("$root/public/icons/sets/build.js");
my $help_features = read_file("$root/perl/help/topics_features.pl");
my $help_apps = read_file("$root/perl/help/topics_apps.pl");

# --- the control sits beside the pin, in the bar's revealed group -----------
like($maker, qr/my \$navbar_fullview_control = .*?_fullview_button window_action fullview_button/s,
	'every window wears a full-screen control');
like($maker, qr/navbar_agent_control \. \$navbar_place_control \. \$navbar_fullview_control/,
	'full screen sits next to the pin in the revealed group');
like($maker, qr/\$window_control->\('fullview',/, 'the control wears the set\'s full-screen icon');
like($maker, qr/window_fullview_exit fullview_exit_button/, 'the way back is a button of its own');
like($maker, qr/\$window_control->\('fullview_exit',/, 'and wears the set\'s leave-full-screen icon');

# --- the whole glass, and the title bar put away ----------------------------
like($css, qr/\.wind\.window_full_viewport\s*\{[^}]*position:\s*fixed !important/s,
	'the window is fixed to the screen');
like($css, qr/\.wind\.window_full_viewport\s*\{[^}]*inset:\s*0 !important/s,
	'it fills the viewport');
like($css, qr/\.wind\.window_full_viewport\s*\{[^}]*z-index:\s*40000 !important/s,
	'it covers the dock and taskbar');
like($css, qr/#browser:has\(> \.wind\.window_full_viewport/, 'the stacking context the window lives in is raised');
like($css, qr/\.wind\.window_full_viewport > \.top_navbar\s*\{\s*display:\s*none !important/,
	'its title bar is put away');
like($css, qr/\.wind\.window_full_viewport > \.window_contents\s*\{[^}]*height:\s*100% !important/s,
	'its contents take the whole height');
like($css, qr/\.wind\.window_full_viewport > \.window_contents\s*\{[^}]*padding-top:\s*0 !important/s,
	'the tuck under the missing title bar is taken back');
like($css, qr/\.window_fullview_exit\s*\{[^}]*opacity:\s*0/s,
	'the corner button waits invisible');
like($css, qr/\.wind\.window_full_viewport > \.window_fullview_exit\s*\{\s*display:\s*flex/,
	'it is only in the layout while the window fills the screen');
like($css, qr/\.window_fullview_exit:hover,\s*\n\.window_fullview_exit:focus\s*\{\s*opacity:\s*1/,
	'reaching the corner reveals it');

# --- the box is kept, and the class is the state ---------------------------
like($fit, qr/function jawnosWindowFullViewportBox\(win\)/, 'the box is read in one place');
like($fit, qr/win\.data\('window-full-viewport-box', jawnosWindowFullViewportBox\(win\)\)/,
	'entering saves the box the window leaves');
like($fit, qr/win\.addClass\('window_full_viewport'\)/, 'entering is the named class');
like($fit, qr/var box = win\.data\('window-full-viewport-box'\)/, 'leaving reads the saved box back');
like($fit, qr/win\.removeClass\('window_full_viewport'\)\.removeData\('window-full-viewport-box'\)/,
	'leaving clears the state and the saved box');
like($fit, qr/win\.css\(\{ 'position': 'fixed', 'left': box\.left, 'top': box\.top, 'width': box\.width, 'height': box\.height \}\)/,
	'and puts the window back where it was');
like($fit, qr/if \(win\.hasClass\('window_full_viewport'\)\) \{ return; \}/,
	'a viewport fit leaves the full glass alone');
like($fit, qr/var foot = viewH - \(\(typeof windowBottomClearance == 'function'\) \? windowBottomClearance\(\) : 0\)/,
	'the fit stops above the taskbar and dock');
like($fit, qr/if \(!windowPhoneChecker\(\) && winTop \+ win\.height\(\) > foot\)/,
	'and a piled window is clamped too, not only a free one');
like($fit, qr/\$\(document\)\.on\('click', '\.fullview_button'/, 'the title-bar control enters full screen');
like($fit, qr/\$\(document\)\.on\('click', '\.fullview_exit_button'/, 'the corner control leaves it');
like($fit, qr/function windowFullViewportEnter\(win\) \{[\s\S]{0,500}jawnosLauncherShell/, 'a launcher shell cannot enter full screen');
like($css, qr/body\.jawnos_launcher_shell \.fullview_button,[\s\S]{0,400}body\.full_app_mode \.fullview_button[\s\S]{0,200}display: none !important/s,
	'a launcher shell hides the full-screen control');
like($css, qr/body\.jawnos_launcher_shell \.window_fullview_exit/,
	'and the corner way back');

# --- the single-click maximize owns the double no longer -------------------
unlike($windows, qr/studioWindowFullSelector/, 'no window binds a full-screen double-press');
unlike($windows, qr/\$\(document\)\.on\('dblclick', [^;]*window_full_viewport/s,
	'the maximize control carries no full-screen gesture');

# --- a fresh glyph in every set --------------------------------------------
like($build, qr/window_full_viewport: '<path d="M6\.5 17\.5 17\.5 6\.5"/,
	'entering wears a double-headed diagonal arrow');
like($build, qr/window_full_viewport_exit: '<path d="M19\.5 4\.5 14 10"/,
	'leaving wears two diagonal arrows pointing at each other');
like($build, qr/'fullview': 'window_full_viewport'/, 'the icon is named for the button');
like($build, qr/'fullview_exit': 'window_full_viewport_exit'/, 'the way back has its own name');

opendir(my $sets_dh, "$root/public/icons/sets") or die "cannot read the icon sets: $!";
my @sets = sort grep { $_ ne '.' && $_ ne '..' && -d "$root/public/icons/sets/$_" } readdir($sets_dh);
closedir $sets_dh;
is(scalar(@sets), 32, 'the generator ships sixteen styles in a light and a dark cut');
for my $set (@sets) {
	ok(-s "$root/public/icons/sets/$set/fullview.svg", "$set has the full-screen icon");
	ok(-s "$root/public/icons/sets/$set/fullview_exit.svg", "$set has the leave-full-screen icon");
}

# --- and the help says so ---------------------------------------------------
like($help_features, qr/Full screen is the two diagonal arrows/, 'Windows names the full-screen control');
like($help_features, qr/top right corner of the screen/, 'Windows names the corner button');
like($help_apps, qr/full-screen button - behind the app icon/, 'Studio points at the shared control');

done_testing();
