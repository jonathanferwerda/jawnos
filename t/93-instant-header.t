# tests-for: lib/JawnOS/Manager/Part14.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part32.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Controller/manager_misc12.pm lib/JawnOS/Controller/manager_ws.pm public/js/manager/manager/06_appointment_distance.js
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
my $generate  = read_file("$root/lib/JawnOS/Domain/Generate.pm");
my $reset     = read_file("$root/lib/JawnOS/Controller/manager_misc5.pm");
my $delete    = read_file("$root/lib/JawnOS/Controller/manager_misc12.pm");
my $manager_ws = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");
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
like($header_sub, qr/&appt_toggle_checker\(\$app\) unless \$data->\{'skip_toggle'\};/,
	'a caller that sets the toggle itself can skip the reconcile');

# --- the header follows the write, before anything else ---------------------

my ($start_branch) = $part14 =~ /(if \(\$type eq 'start' \|\| \$type eq 'record'\) \{.*?\n\s*elsif \(\$type eq 'stop'\) \{)/s;
ok($start_branch, 'the start branch is one block');
my $start_insert = index($start_branch, "db_insert('appointments'");
my $start_header = index($start_branch, 'appt_header_printer');
my $start_toggle = index($start_branch, "setting => 'toggle', value => 'on'");
my $start_models = index($start_branch, 'usual_appointment_maker');
ok($start_insert >= 0 && $start_header > $start_insert,
	'the start header follows the row write');
ok($start_header < $start_toggle && $start_header < $start_models,
	'and precedes the toggle write and the default model/option sessions');
like($start_branch, qr/skip_toggle => \(\$seen eq 'yes' \? 1 : 0\)/,
	'a live start does not repeat the toggle write in the header');

my ($stop_branch) = $part14 =~ /(elsif \(\$type eq 'stop'\) \{.*?\n\s*elsif \(\$type eq 'cancel'\) \{)/s;
ok($stop_branch, 'the stop branch is one block');
my $stop_update = index($stop_branch, "db_update('appointments'");
my $stop_header = index($stop_branch, 'appt_header_printer');
my $stop_toggle = index($stop_branch, "setting => 'toggle', value => 'off'");
ok($stop_update >= 0 && $stop_header > $stop_update,
	'the stop header follows the stop write');
ok($stop_header < $stop_toggle,
	'and precedes the toggle write');
like($stop_branch, qr/skip_toggle => \(\$seen eq 'yes' \? 1 : 0\)/,
	'a live stop does not repeat the toggle write in the header');

# --- a closed child keeps no running header in its own app ------------------

# A stop rewrites the default model/option sessions seeded from the row it
# closes (source_uuid = the stopped uuid). Those children live in their own
# apps, and only the stopped app's header was rendered after the write, so a
# child window stayed on the "running" header it drew before the stop. One
# header per changed child app, rendered after its rows are written.

like($stop_branch, qr/\$child_apps\{ \$so->\{'app'\} \} = 1;[\s\S]*?&subs::source_header_printer\(\[ keys %child_apps \], \$timestamp\);/,
	'the stop renders a header for every child app whose session it closed');

my ($writer_stop) = $part05 =~ /(if \(\$app->\{'type'\} eq 'stop'\) \{.*?\n\t\}\n\s*elsif)/s;
ok($writer_stop, 'appointment_writer keeps its stop branch in one block');
like($writer_stop, qr/\$child_apps\{ \$so->\{'app'\} \} = 1;[\s\S]*?&subs::source_header_printer\(\[ keys %child_apps \], \$timestamp\);/,
	'a relayed stop renders the same child headers');

my ($child_sub) = $calendar =~ /(sub source_header_printer \{.*?\n\}\n)/s;
ok($child_sub, 'the child header printer is one sub');
like($child_sub, qr/next if \$seen\{\$app\}\Q++\E;/,
	'it renders each changed app once, not once per child row');
like($child_sub, qr/&appt_header_printer\(\{ app => \$app, timestamp => \$timestamp \}\);/,
	'and goes through the same header printer, so the push and cache match');

# The desk-session reopen (music socket connect, log_me on) reopens the children
# of the tab's own duty row. It is the same write without a header, so the child
# window stayed on the stopped header it drew before the reopen.
like($manager_ws, qr/my \$sources = &subs::db_select\('appointments', undef, \{ source_uuid => \$appt->\{'uuid'\} \}\)->hashes;[\s\S]*?\$child_apps\{ \$so->\{'app'\} \} = 1;[\s\S]*?&subs::source_header_printer\(\[ keys %child_apps \], \$timestamp\);/,
	'the desk-session reopen renders a header for each child app it reopens');

# --- manager_reset: header now, window in a fork ----------------------------

like($part14, qr/my \$wants_cv = \(\$c->param\('cv'\) \/\/ ''\) eq 'yes' \? 1 : 0;/,
	'manager_reset knows whether the caller reads cv');
like($part14, qr/if \(\$wants_cv\) \{\s*\$cv = &centre_view_grabber\(/,
	'the cv caller gets the window synchronously');
like($part14, qr/else \{\s*my \$fork_app = \$app;\s*my \$fork_header = \$appt_header;[\s\S]*?&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*&centre_view_grabber\([\s\S]*?\}, \{ name => 'centre view' \}\);/,
	'the press forks the centre-view call and keeps the header in the reply');
like($part14, qr/\$returner->\{'header'\} = \$appt_header/,
	'the reply still carries the header the press just changed');

# --- a late default cannot resurrect or orphan a stopped child -------------

like($generate, qr/my \$source_row = &subs::db_select\('appointments', undef, \{ uuid => \$uuid \}\)->hashes->\[0\];\s*return unless \$source_row;/,
	'a default whose parent was deleted writes nothing');
like($generate, qr/\(\$source_row->\{'stop_seen'\} \|\| ''\) eq 'yes'/,
	'a stopped parent starts no child session');
like($generate, qr/\(\$source_row->\{'type'\} \|\| ''\) =~ \/\^\(\?:stop\|cancel\)\$\//,
	'a cancelled or stopped parent starts no child session');
like($part05, qr/my %maker_fields = map \{ \$_ => \$app->\{\$_\} \} grep \{ defined \$app->\{\$_\} \} qw\/data model options unit quantity manufacturer seen\//,
	'the post-maker update carries only the fields the maker produced');
unlike($part05, qr/&subs::db_update\('appointments', \$app, \{ app => \$app->\{'app'\}, uuid => \$app->\{'uuid'\} \}\);/,
	'the post-maker update no longer rewrites type/stop_timestamp over a stop');

# --- appointment_writer and delete_app fork the same call -------------------

like($part05, qr/my \$centre_app = &subs::unformat_name\(\$app->\{'app'\}\);[\s\S]*?&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*&centre_view_grabber\(\{ c => \$c, app => \$centre_app/,
	'appointment_writer forks the window render');
like($part32, qr/&subs::appt_header_printer\(\{ app => \$app, timestamp => &subs::rightNow\(\) \}\);[\s\S]*?&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*&centre_view_grabber\(\{ app => \$app/,
	'delete_app sends the header at once and forks the window render');
like($part32, qr/foreach my \$so \( \@\{ &subs::db_select\('appointments', undef, \{ source_uuid => \$uuid \}\)->hashes \|\| \[\] \} \) \{\s*next if \$so_seen\{\s*\$so->\{'uuid'\} \}\+\+;\s*&delete_app\(\$so->\{'app'\},\$so->\{'uuid'\},\$so->\{'server_time'\},'late source deletion'\);/s,
	'delete_app sweeps for a child that landed during the delete');

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
