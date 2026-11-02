# tests-for: lib/JawnOS/Manager/Part14.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Controller/manager_misc5.pm public/js/manager/manager/06_appointment_distance.js
# covers:    A start or stop replies at once and leaves the header redraw to the header worker's fork

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A start or stop changes the appointment header. Rendering it (and the window
# around it) inside the route made the press wait for the redraw. The press now
# answers as soon as the row is written: appt_header_printer is told `defer`, it
# hands the render, its push, the alarm walk and the centre view to a header
# worker fork, and the route returns. The caller that really does read
# `response.cv` (the Add press) passes cv=yes and keeps the synchronous render.

my $root   = repo_root();
my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
my $reset  = read_file("$root/lib/JawnOS/Controller/manager_misc5.pm");
my $js     = read_file("$root/public/js/manager/manager/06_appointment_distance.js");

# --- the press defers the redraw ---------------------------------------------

like($part14, qr/my \$defer_header = \(\$c->param\('cv'\) \/\/ ''\) eq 'yes' \? 0 : 1;/,
	'only a caller that asks for cv keeps the render in the reply');
like($part14, qr/unless \(\$defer_header\) \{\s*\$cv = &centre_view_grabber\(/,
	'the centre view is rendered synchronously only for a cv caller');
like($part14, qr/\$returner->\{'cv'\} = \$cv;/,
	'the cv caller still gets the window back');
my @calls = ($part14 =~ /&subs::appt_header_printer\(\{ app => \$app, timestamp => \$timestamp, defer => \$defer_header \}\);/g);
is(scalar @calls, 8, 'every reset branch tells the header printer it may defer');
unlike($part14, qr/&subs::appt_header_printer\(\{ app => \$app, timestamp => \$timestamp \}\);/,
	'no reset branch still renders the header inline');

# --- the header worker is the fork -------------------------------------------

like($calendar, qr/if \(\$data->\{'defer'\} && !\$data->\{'header_only'\}\) \{/,
	'appt_header_printer has a defer path');
like($calendar, qr/if \(\$data->\{'defer'\}[\s\S]*?&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;[\s\S]*?source => 'centre_view_grabber'[\s\S]*?&Manager::centre_view_grabber\([\s\S]*?\}, \{ name => 'header worker' \}\)/,
	'the deferred work is one header worker fork: the render, its push, alarms and centre view');
like($calendar, qr/return wantarray \? \('', undef\) : '';/,
	'the deferred caller gets no HTML back, so the route does not wait');

# --- the reply's time is logged ----------------------------------------------

like($reset, qr/\$log->info\('reset ' \. \(\$c->param\('type'\) \/\/ '\?'\)/,
	'the reset route logs its own time, so a slow press can be seen');

# --- the one caller that reads the window asks for it -----------------------

like($js, qr/type: entry,[^\n]*\bcv: 'yes'/,
	'the Add press asks for the centre view it reads out of response.cv');
like($js, qr/centreViewWriter\(response\.cv\)/,
	'and still consumes that render');

done_testing();
