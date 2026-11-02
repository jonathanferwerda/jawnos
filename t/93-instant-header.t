# tests-for: lib/JawnOS/Manager/Part14.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part32.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Controller/manager_misc12.pm public/js/manager/manager/06_appointment_distance.js
# covers:    the header goes out at once; the caller forks the centre-view render after it

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A start or stop changes the appointment header. The old, fast shape was: render
# the header, cache it and push it at once, and let the caller fork the
# centre-view render (the call) in the background. That matters because the press
# may still have to start or stop default models and options after the header.
#
# appt_header_printer is therefore a plain render/cache/push again, with the
# alarm poke inline and no fork of its own. manager_reset, appointment_writer and
# delete_app fork centre_view_grabber after it. The Add press, which reads
# response.cv, keeps the synchronous window.

my $root      = repo_root();
my $calendar  = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
my $part14    = read_file("$root/lib/JawnOS/Manager/Part14.pm");
my $part05    = read_file("$root/lib/JawnOS/Manager/Part05.pm");
my $part32    = read_file("$root/lib/JawnOS/Manager/Part32.pm");
my $reset     = read_file("$root/lib/JawnOS/Controller/manager_misc5.pm");
my $delete    = read_file("$root/lib/JawnOS/Controller/manager_misc12.pm");
my $js        = read_file("$root/public/js/manager/manager/06_appointment_distance.js");

# --- the header is the fast half, with no fork of its own -------------------

my ($header_sub) = $calendar =~ /(sub appt_header_printer \{.*?\n\}\n)/s;
ok($header_sub, 'appt_header_printer is one sub');
unlike($header_sub, qr/subprocessor/,
	'the header render does not fork; the caller forks the window instead');
unlike($header_sub, qr/&(?:Manager::)?centre_view_grabber\s*\(/,
	'the header no longer renders the centre view');
like($header_sub, qr/foreach my \$a \( \@\{ \(\$appts->\{\$app\} \|\| \{\}\)->\{'list'\} \|\| \[\] \} \) \{\s*&appt_alarm_setter\(\$a\);/s,
	'the alarm poke runs inline on the rows the header draws');
like($header_sub, qr/&subs::cache_set\(\{ app => \$app, context => 'header'/,
	'the header is cached');
like($header_sub, qr/Websocket::send\('tab', \{ type => 'header'/,
	'and pushed at once');

# --- manager_reset: header now, window in a fork ----------------------------

like($part14, qr/my \$wants_cv = \(\$c->param\('cv'\) \/\/ ''\) eq 'yes' \? 1 : 0;/,
	'manager_reset knows whether the caller reads cv');
like($part14, qr/if \(\$wants_cv\) \{\s*\$cv = &centre_view_grabber\(/,
	'the cv caller gets the window synchronously');
like($part14, qr/else \{\s*my \$fork_app = \$app;\s*my \$fork_header = \$appt_header;[\s\S]*?&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*&centre_view_grabber\([\s\S]*?\}, \{ name => 'centre view' \}\);/,
	'the press forks the centre-view call and keeps the header in the reply');
like($part14, qr/\$returner->\{'header'\} = \$appt_header/,
	'the reply still carries the header the press just changed');

# --- appointment_writer and delete_app fork the same call -------------------

like($part05, qr/my \$centre_app = &subs::unformat_name\(\$app->\{'app'\}\);[\s\S]*?&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*&centre_view_grabber\(\{ c => \$c, app => \$centre_app/,
	'appointment_writer forks the window render');
like($part32, qr/&subs::appt_header_printer\(\{ app => \$app, timestamp => &subs::rightNow\(\) \}\);[\s\S]*?&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*&centre_view_grabber\(\{ app => \$app/,
	'delete_app sends the header at once and forks the window render');

# --- the manual delete route no longer renders the window itself ------------

my ($delete_action) = $delete =~ /(sub action_41155 \{.*?\n\}\n)/s;
ok($delete_action, 'the manual delete action is one sub');
unlike($delete_action, qr/centre_view_grabber/,
	'the manual delete reply does not render the window');

# --- the reply's time is logged ---------------------------------------------

like($reset, qr/\$log->info\('reset ' \. \(\$c->param\('type'\) \/\/ '\?'\)/,
	'the reset route logs its own time, so a slow press can be seen');

# --- the one caller that reads the window asks for it -----------------------

like($js, qr/type: entry,[^\n]*\bcv: 'yes'/,
	'the Add press asks for the centre view it reads out of response.cv');
like($js, qr/centreViewWriter\(response\.cv\)/,
	'and still consumes that render');

done_testing();
