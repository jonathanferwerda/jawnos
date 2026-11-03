# tests-for: lib/JawnOS/Manager/Part05.pm
# covers:    A default model/option child write stops forking its own centre view; a plain call still does

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# One Start press used to fork a centre-view render (and run the budget and the
# evaluation) for the press itself AND for every default model/option child it
# starts. Each fork re-reads and re-renders the whole app window on a 200-380 MB
# process, so a press with one default model and one default option forked three
# windows. appointment_writer now takes a `quiet_child` key: a caller that knows
# a parent press will draw the window sets it, and the child only writes its row.
# The plain call - the press, and every other caller - is unchanged.

my $root   = repo_root();
my $part05 = read_file("$root/lib/JawnOS/Manager/Part05.pm");

my ($writer) = $part05 =~ /(sub appointment_writer\(\$c,\$app\) \{.*?\n\}\n)/s;
ok($writer, 'appointment_writer is still one sub I can read');

# --- (a) the default path still forks the window and runs the bookkeeping ---

like($writer, qr/my \$centre_app = &subs::unformat_name\(\$app->\{'app'\}\);\s*&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*&centre_view_grabber\(\{ c => \$c, app => \$centre_app, timestamp => &subs::rightNow\(\), cached => 'no' \}\);\s*\}, \{ name => 'centre view' \}\) unless \$quiet_child;/,
	'a plain call still forks the centre view: only a caller that asked for quiet skips it');
like($writer, qr/&budget_runner\(\$app->\{'app'\}\) unless \$quiet_child;/,
	'the budget still runs for a plain call');
like($writer, qr/&subs::evaluation_run_trigger\(\$app->\{'app'\}, \$app\) unless \$quiet_child;/,
	'the evaluation trigger still fires for a plain call');
like($writer, qr/&Websocket::send\('tab', \{ console => 'calculator\(\);' \}\);/,
	'the tab pushes are still there for a plain call');
unlike($writer, qr/QuietChild|quiet_child\s*=>\s*1/,
	'the default is not quiet: the flag is opt-in, never set here');
my $default_guard = () = $writer =~ /unless \$quiet_child/g;
is($default_guard, 3, 'exactly the fork, the budget and the evaluation are guarded - not the writes');

# --- (b) the quiet path skips the fork and the bookkeeping ------------------

like($writer, qr/my \$quiet_child = \$app->\{'quiet_child'\};/,
	'the caller can set quiet_child on the hash it passes');
like($writer, qr/unless \(\$quiet_child\) \{\s*&Websocket::send\('tab', \{ console => 'calculator\(\);' \}\);/,
	'and the three tab pushes sit inside the quiet guard');
my $row_start = index($writer, "if (\$app->{'type'} eq 'usual'");
my $fork_at   = index($writer, "{ name => 'centre view' }");
ok($row_start >= 0 && $fork_at > $row_start,
	'the row is written before the guarded fork, so a quiet child still writes it');
like($writer, qr/&subs::db_insert\('appointments', \$app\);/,
	'and the row write is not behind any quiet guard');
like($writer, qr/&subs::intelligent_automation_toggle\(\{ appt_uuid => \$app->\{'uuid'\}, app => \$app->\{'app'\}, 'state' => 'on'/,
	'a quiet start still turns the hardware on');
like($writer, qr/&subs::appointment_theme_push\(\) if \(\(\$theme_movement \/\/ ''\) =~ \/\^\(\?:start\|stop\|record\)\$\//,
	'and the theme push is unguarded, on the remembered type');
my $quiet_block = $writer;
ok($quiet_block =~ /unless \(\$quiet_child\) \{([\s\S]*?)\n\t\}/, 'the quiet guard is one block');
like($1, qr/appointmentDetailGrabber/, 'the detail push is inside it');
like($1, qr/continent_record/, 'and the continent record push');
unlike(substr($writer, $fork_at), qr/&subs::db_insert|&subs::db_update/,
	'nothing after the guarded fork writes the row: the write does not depend on the window');

# --- (c) the flag key never reaches SQL -----------------------------------

like($writer, qr/my \$quiet_child = \$app->\{'quiet_child'\};\s*delete \$app->\{'quiet_child'\};/,
	'quiet_child is taken off the hash the moment it is read');
my $delete_at = index($writer, "delete \$app->{'quiet_child'}");
my $first_sql = index($writer, "db_insert('appointments', \$app)");
ok($delete_at >= 0 && $first_sql > $delete_at,
	'the delete happens before the first insert, so no row carries the key');
like($writer, qr/my \$source_chip_id = \$app->\{'source_chip_id'\};\s*delete \$app->\{'source_chip_id'\};[\s\S]{0,600}?my \$quiet_child = \$app->\{'quiet_child'\};\s*delete \$app->\{'quiet_child'\};/,
	'and it is read and deleted beside source_chip_id (a comment apart), the same way');

done_testing();
