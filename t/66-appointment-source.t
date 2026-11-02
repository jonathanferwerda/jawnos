use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# source=ws is the headless/automation read. The route already skipped its own
# appointmentGrabber broadcast for it, but appt_header_printer still woke every
# other tab with a header. These checks pin the whole silent path, and the chunk
# route's first-open path (no terser on a small app chunk).

my $root = repo_root();
my $route = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
my $part21 = read_file("$root/lib/JawnOS/Manager/Part21.pm");
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
my $js_misc = read_file("$root/lib/JawnOS/Controller/js_misc.pm");

like($route, qr/source => \$c->param\('source'\)/,
	'the centre view hands its source to the grabber');
like($route, qr/if \(!document\.hidden\) \{ appointmentGrabber/,
	'a hidden tab is not made to fetch and render the mirror');
like($part21, qr/broadcast => \(\(\$data->\{'source'\} \/\/ ''\) eq 'ws' \? 'no' : 'yes'\)/,
	'the header printer is told whether to broadcast');
like($calendar, qr/unless \(\(\$data->\{'broadcast'\} \/\/ ''\) eq 'no' \|\| \(\$data->\{'source'\} \/\/ ''\) eq 'ws'\)/,
	'a source=ws header does not broadcast');
like($calendar, qr/unless \(\(\$data->\{'broadcast'\}.*?Websocket::send\('tab', \{ type => 'header'/s,
	'the header send sits inside the silent guard');

like($js_misc, qr/my \$sig = 'plain1;'/, 'the chunk cache version can be busted');
unlike($js_misc, qr/\$body = js_minify\(\$raw\);/, 'a lazy chunk is not minified on first open');
like($js_misc, qr/content_encoding\('gzip'\)/, 'chunks still gzip on the wire');

done_testing();
