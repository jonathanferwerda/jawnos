# tests-for: lib/JawnOS/Controller/js_misc.pm lib/JawnOS/Controller/manager_misc7.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Manager/Part21.pm public/js/manager/websocket/00_console_router.js
# covers:    source=ws is the headless/automation read.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# source=ws is the headless/automation read. The route already skipped its own
# appointmentGrabber broadcast for it, but appt_header_printer still woke every
# other tab with a header. These checks pin the whole silent path, and the two
# chunk routes' cache shapes: an app chunk stays plain on first open, and the
# layout chunk is minified because a canvas view waits on it before its paint.

my $root = repo_root();
my $route = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
my $part21 = read_file("$root/lib/JawnOS/Manager/Part21.pm");
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
my $js_misc = read_file("$root/lib/JawnOS/Controller/js_misc.pm");

like($route, qr/source => \$c->param\('source'\)/,
	'the centre view hands its source to the grabber');
like($route, qr/console_command\('appointmentGrabberIfVisible'/,
	'a hidden tab is sent the visible-only command');
my $router = read_file("$root/public/js/manager/websocket/00_console_router.js");
like($router, qr/appointmentGrabberIfVisible: function \(a\) \{\s*if \(!document\.hidden/,
	'and that command refuses a hidden tab');
like($part21, qr/broadcast => \(\(\$data->\{'source'\} \/\/ ''\) eq 'ws' \? 'no' : 'yes'\)/,
	'the header printer is told whether to broadcast');
like($calendar, qr/unless \(\(\$data->\{'broadcast'\} \/\/ ''\) eq 'no' \|\| \(\$data->\{'source'\} \/\/ ''\) eq 'ws'\)/,
	'a source=ws header does not broadcast');
like($calendar, qr/unless \(\(\$data->\{'broadcast'\}.*?Websocket::send\('tab', \{ type => 'header'/s,
	'the header send sits inside the silent guard');

like($js_misc, qr/my \$sig = 'plain1;'/, 'the chunk cache version can be busted');
my ($app_action) = $js_misc =~ /sub action_7408 \{(.*?)\n\}/s;
ok(defined $app_action, 'the app chunk action is found');
unlike($app_action // '', qr/js_minify\(/, 'a lazy app chunk is not minified on first open');
my ($layout_action) = $js_misc =~ /sub action_7409 \{(.*?)\n\}/s;
ok(defined $layout_action, 'the layout chunk action is found');
like($layout_action // '', qr/\$body = js_minify\(\$raw\);/, 'the layout chunk is minified');
like($js_misc, qr/content_encoding\('gzip'\)/, 'chunks still gzip on the wire');

done_testing();
