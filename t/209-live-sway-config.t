# tests-for: desktop/mkosi/mkosi.extra/opt/jawnos/home-skel/.config/sway/config
# covers:    the live image's short Sway session starts the Qt session bar
#           (jawnos-shell), never the legacy bar, and leaves the manager an ordinary
#           tiled window so the bar's exclusive zone is respected. The kiosk
#           bindings and the foot float rule survive, and the file stays the
#           deliberately short live variant of desktop/wayland/sway.conf.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $live = read_file(
	"$root/desktop/mkosi/mkosi.extra/opt/jawnos/home-skel/.config/sway/config");
my $installed = read_file("$root/desktop/wayland/sway.conf");

# --- the bar --------------------------------------------------------------
like($live, qr/^exec \/home\/jawn\/jawnos\/desktop\/jawnos-shell$/m,
	'the live image starts the Qt session bar');
unlike($live, qr/^\s*exec\b.*\bwayb[a]r\b/m,
	'and never execs the legacy bar (it is no longer installed)');
unlike($live, qr/^\s*exec\b.*jawnos-usage\b/m,
	'jawnos-usage is left out: a live session has no manager ticket to record with');
like($installed, qr/^\s*exec\b.*\$jawnos\/desktop\/jawnos-shell/m,
	'the installed session starts the same bar');
like($live, qr/layer-shell panel with a 30px exclusive zone/,
	'the comment says why the bar needs the manager to be tiled');

# --- the manager is an ordinary tiled window ------------------------------
unlike($live, qr/for_window\s+\[app_id="\^\(jawnos\|jawnos-desktop\)\$"\][^\n]*fullscreen/,
	'the live image does not force-fullscreen the manager');
unlike($live, qr/for_window\s+\[app_id="\^\(jawnos\|jawnos-desktop\)\$"\]/,
	'and sets no window rule on the manager at all');
unlike($installed, qr/for_window\s+\[app_id="\^\(jawnos\|jawnos-desktop\)\$"\][^\n]*fullscreen/,
	'the installed session does not force-fullscreen it either');

# --- the kiosk bindings survive -------------------------------------------
like($live, qr/^bindsym \$mod\+Return exec foot$/m, 'foot still opens');
like($live, qr/^bindsym \$mod\+d exec fuzzel$/m, 'fuzzel still opens');
like($live, qr/^bindsym \$mod\+q kill$/m, 'a window still closes');
like($live, qr/^bindsym \$mod\+Shift\+r reload$/m, 'Sway still reloads');
like($live, qr/^bindsym \$mod\+Shift\+d exec \/usr\/local\/bin\/jawnos-display --cycle$/m,
	'display modes still cycle');
like($live, qr/swaynag.*swaymsg exit/, 'there is still a way out of Sway');
like($live, qr/^exec \/usr\/local\/bin\/jawnos-display --once$/m,
	'an unfamiliar monitor still gets a safe mode at start-up');
like($live, qr/^for_window \[app_id="\^foot\$"\] floating enable, resize set 900 600$/m,
	'the terminal still floats');

# --- still the short live variant -----------------------------------------
like($live, qr/^exec \/home\/jawn\/jawnos\/desktop\/wayland\/jawnos-session$/m,
	'the session still comes up first');
like($live, qr/Deliberately shorter than/, 'the file says why it is short');
unlike($live, qr/^\s*exec\b.*\$jawnos\//m,
	'it hardcodes the live path instead of $jawnos (the installed-file variable)');

done_testing();
