# tests-for: templates/apps/notifications.html.ep public/js/manager/notifications.js public/js/manager/notifications_toast.js public/js/manager/taskbar_notifications.js public/js/manager/websocket/01_message_handler.js lib/JawnOS/Controller/manager_misc6.pm lib/JawnOS/Routes/manager_misc6.pm lib/JawnOS/Manager/Part33.pm lib/JawnOS/Manager/Part12.pm perl/gb/02_labels_and_collectives.pl templates/start_menu/start_menu.html.ep public/js/manager/keyboard/02_music_and_handlers.js perl/help/topics_apps.pl perl/help/topics_features.pl public/css/manager.css public/icons/notifications.svg
# covers:    The Notifications app (search, app filter, remove all), the in-program
#            notice cards that replaced the browser's Notification, and the
#            taskbar bell that counts what arrived since the list was opened.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
sub source { my $text = read_file("$root/$_[0]"); return defined $text ? $text : ''; }

# --- the app's routes and actions -------------------------------------------
my $routes = source('lib/JawnOS/Routes/manager_misc6.pm');
like($routes, qr/\[\s*22699\s*,\s*'get'\s*,\s*'\/manager\/notifications'\s*,\s*'action_22699'\s*\]/,
	'the Notifications app has its window route');
like($routes, qr/\[\s*25150\s*,\s*'get'\s*,\s*'\/manager\/notifications\/status'\s*,\s*'action_25150'\s*\]/,
	'the widget has a JSON status route');
like($routes, qr{/manager/notifications/search}, 'the existing search route is still there');
like($routes, qr{/manager/notifications/filter}, 'and the app filter');
like($routes, qr{/manager/notifications/remove}, 'and the remove route');

my $controller = source('lib/JawnOS/Controller/manager_misc6.pm');
like($controller, qr/^sub action_22699\b/m, 'the app action exists');
like($controller, qr/&notification_grabber\(\{\}\)/, 'and reads the existing grabber');
like($controller, qr/template => 'apps\/notifications'/, 'through the new app template');
like($controller, qr/^sub action_25150\b/m, 'the status action exists');
like($controller, qr/from notifications order by cast\(timestamp as integer\) desc limit 50/,
	'and returns the newest notices as JSON');

# --- the app template -------------------------------------------------------
my $template = source('templates/apps/notifications.html.ep');
like($template, qr/id="notifications_app"/, 'the app page names its app');
like($template, qr/id="notifications_app_search"/, 'it has a search box');
like($template, qr/id="notifications_app_filter"/, 'an app filter');
like($template, qr/scope="all"/, 'and Remove all');
like($template, qr/notifications->\{'content'\}/, 'the first page is drawn on the server');
like($template, qr/&subs::ui\('Search notifications'\)/, 'its labels are translatable sentences');

# A notification is a float beside the text, so each line next to the picture is
# shortened. The picture must fit in the title's line and that line must clear
# the wrapper's 3px frame, or the message is squeezed into the column beside it.
my ($icon_size) = $template =~ /--notification_icon:\s*(\d+)px/;
my ($line_size) = $template =~ /--notification_line:\s*(\d+)px/;
is($icon_size, 22, 'the row picture is the window-icon size');
cmp_ok(($line_size || 0), '>=', ($icon_size || 0) + 6, 'the title line clears the picture and its 3px frame');
like($template, qr/#notifications_app \.notification b \{[^}]*line-height:\s*var\(--notification_line\)/,
	'the title wears that line height');
like($template, qr/#notifications_app \.notification img\.window_icon,\s*#notifications_app \.notification img\.little_thumb \{[^}]*box-sizing:\s*border-box/s,
	'both kinds of picture share one border-box size');
like($template, qr/#notifications_app \.notification \.hover \{ line-height: 0; \}/,
	'the picture wrapper adds no text line of its own');

# --- the keyboard panel it replaced -----------------------------------------
# The app owns the list now. The bell face stays on the dock, but there is no
# keyboard panel behind it: notifications.js opens the app from that face.
ok(!-e "$root/templates/keyboard.html.ep", 'the keyboard panel template is gone');
my $kbuilder = source('lib/JawnOS/Manager/Part33.pm');
unlike($kbuilder, qr/\$toggle eq 'notifications'/, 'the panel builder no longer reads the notices');
my $keymaker = source('public/js/manager/keyboard/02_music_and_handlers.js');
unlike($keymaker, qr/function keyboardMaker\(/, 'the panel maker is gone with the panels');
unlike($keymaker, qr/#notification_search|notificationScrollLoader|notifications\/scroll/,
	'and the panel handlers and scroll loader are gone');
my $pseudonyms = source('lib/JawnOS/Manager/Part12.pm');
like($pseudonyms, qr/status => 'off', name => "notifications"/,
	'the old keyboard face starts off now the app and widget own the bell');

my $appjs = source('public/js/manager/notifications.js');
like($appjs, qr/function notificationsOpener\(/, 'the app has an opener');
like($appjs, qr{/manager/notifications/search}, 'the search asks the existing endpoint');
like($appjs, qr{/manager/notifications/filter}, 'and the filter');
like($appjs, qr/#notifications_toggle/, 'the start menu icon opens it');
like($appjs, qr/jawnosNotificationsTaskbarMarkSeen/, 'opening the list clears the bell count');

my $core = source('lib/JawnOS/Manager/Core1_tables_hooks.pm');
like($core, qr{notifications\s*=>\s*\[qw\(/js/manager/notifications\.js\)\]}, 'the app is a lazy chunk');
like($core, qr/notifications_toggle => 'notifications'/, 'and its start-menu click is caught in core');

my $known = source('perl/gb/02_labels_and_collectives.pl');
like($known, qr/notifications => \{ icon => ['"]\/images\/decipherable\/bell\.png['"] \}/,
	'Notifications is a known app');
my $menu = source('templates/start_menu/start_menu.html.ep');
like($menu, qr/id="notifications_toggle"/, 'the start menu carries its bell');
like($menu, qr/hint="<%= &subs::ui\('Notifications'\) %>"/, 'with a translatable hint');

# --- the in-program notice cards -------------------------------------------
my $toast = source('public/js/manager/notifications_toast.js');
like($toast, qr/function jawnosNotice\(/, 'the house has its own notice');
like($toast, qr/function jawnosNoticeClose\(/, 'a notice can be closed');
like($toast, qr/jawnos_notice_by_key/, 'a notice with a key is updated in place');
like($toast, qr/appWindowOpener\(app/, 'pressing a notice opens its app');
like($toast, qr/role="status"/, 'the stack is a live region');

my $css = source('public/css/manager.css');
like($css, qr/#jawnos_notices\s*\{/, 'the notice stack has a style');
like($css, qr/\.jawnos_notice\b/, 'and each card');
like($css, qr/\.taskbar_notifications_badge/, 'the bell badge has a style');

# TODO: the window-icon pin was added inside .window_icon's own block
# (public/css/manager.css:1077), so it never matches: an app window icon falls
# back to its thumb class (medium_thumb is 50px) instead of the intended 22px.
# The Notifications app now sizes its own row pictures, but the global pin is
# still dead. Enabling it blindly would also shrink Configure's huge main-image
# preview, so the block needs splitting with that case in mind.
TODO: {
	local $TODO = 'public/css/manager.css:1077: img.window_icon is nested inside .window_icon';
	like($css, qr/\.window_icon \{[^}]*\}\s*(?:\/\*.*?\*\/\s*)?img\.window_icon \{/s,
		'the img.window_icon rule stands outside .window_icon');
}

my $ws = source('public/js/manager/websocket/01_message_handler.js');
like($ws, qr/jawnosNotice\(\{ title: data\['title'\]/, 'a live notification becomes a house card');
unlike($ws, qr/new Notification\(/, 'and the browser notification is gone');

my $configure = source('public/js/manager/configure.js');
unlike($configure, qr/Notification\.requestPermission/, 'no browser permission is asked for any more');

my $sound = source('public/js/manager/taskbar_sound.js');
like($sound, qr/jawnosNotice\(\{/, 'the volume readout uses the house card');
like($sound, qr/key: 'volume'/, 'and updates one card in place');

# --- the taskbar bell -------------------------------------------------------
my $widget = source('public/js/manager/taskbar_notifications.js');
like($widget, qr{/manager/notifications/status}, 'the bell reads the JSON status');
like($widget, qr/jawnos_notifications_seen/, 'the count is kept per browser');
like($widget, qr/function jawnosNotificationsTaskbarUnread/, 'and is the notices newer than the mark');
like($widget, qr/jawnosTaskbarPanelToggle\('taskbar_notifications_panel'/, 'a press opens its panel');
like($widget, qr/data-app', 'notifications'/, 'the panel opens the app');
like($widget, qr/Open Notifications/, 'and says so');
ok(-e "$root/public/icons/notifications.svg", 'the bell icon exists');

# --- help -------------------------------------------------------------------
require "$root/perl/help.pl";
like($help::topic{'notifications'}->{'summary'}, qr/notices/i, 'the topic names the notices');
is($help::topic{'notifications'}->{'app'}, 'notifications', 'and belongs to the app');
like(join(' ', @{ $help::topic{'notifications'}->{'body'} }), qr/search/i, 'the body names the search');
unlike(join(' ', @{ $help::topic{'notifications'}->{'body'} }), qr/keyboard/, 'and no longer points at a keyboard panel');
like(join(' ', @{ $help::topic{'taskbar'}->{'body'} }), qr/Notifications widget/, 'the taskbar topic names the bell');

done_testing();
