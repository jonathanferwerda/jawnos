# tests-for: lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Clock2.pm perl/Alarm.pl scripts/notifications_dedupe.pl
# covers:    One row for a house-wide notice. The alarm loop and the budget
#            watcher run on every device; each used to render the same start,
#            stop or budget crossing with a fresh random uuid, so the sync
#            stacked every machine's copy in every list. An event-named notice
#            now derives one uuid from the event itself, and the cleanup
#            script collapses the rows written before that.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
sub source { my $text = read_file("$root/$_[0]"); return defined $text ? $text : ''; }

# --- the name of an event ---------------------------------------------------
# A pure derivation: the same event gets the same name on every machine, a
# different event does not, and a caller with no event keeps the random path.
require JawnOS::Domain::Notify;
my $one = subs::notification_event_uuid('appointment|abc|start|100|');
my $same = subs::notification_event_uuid('appointment|abc|start|100|');
my $other = subs::notification_event_uuid('appointment|abc|stop|100|250|');
ok(defined $one && length $one, 'an event seed produces a uuid');
is($one, $same, 'the same event names the same uuid on every machine');
isnt($one, $other, 'a start and a stop name different events');
like($one, qr/^notevent-[0-9a-f]{32}$/, 'the uuid carries the event prefix and a digest');
my $unicode = subs::notification_event_uuid("d\x{00e9}jeuner|accomplished");
like($unicode, qr/^notevent-[0-9a-f]{32}$/, 'a name with any printable character still digests as bytes');
ok(!defined subs::notification_event_uuid(''), 'an empty seed names nothing');
ok(!defined subs::notification_event_uuid(undef), 'so does a missing seed');

# --- the guard in the sender ------------------------------------------------
my $notify = source('lib/JawnOS/Domain/Notify.pm');
like($notify, qr/^sub notification_event_uuid\b/m, 'the event name is its own helper');
like($notify, qr/notification_event_uuid\(\$m->\{'dedupe'\}\)/,
	'the sender derives the uuid from the caller\'s event');
like($notify, qr/select 1 from notifications where uuid = \? limit 1/,
	'and checks whether this machine already holds the row');
like($notify, qr/my \$already = \$event_uuid/, 'the insert asks before it writes');
like($notify, qr/unless \(\$already\) \{/, 'so a second sight writes no second row');
unlike($notify, qr/return undef if \$known/, 'the live card is not suppressed');
like($notify, qr/\$m->\{'uuid'\} \|\|= &subs::random_string_creator\(20\)/,
	'a notice with no event still gets its random uuid');
like($notify, qr/unless \(defined \$m->\{'uuid'\} && length \$m->\{'uuid'\}\)/,
	'a caller that supplies its own uuid keeps it');
# The phone's poster gets the app and its moment, so a tap can open that app's
# own full-screen window rather than the manager desk.
like($notify, qr/app => \$m->\{'app'\},/, 'the phone poster names the app to open');
like($notify, qr/timestamp => \$m->\{'timestamp'\},/, 'and the moment the notice is about');
like($notify, qr/'--es', 'app', \$m->\{'app'\}/, 'the broadcast fallback carries the app too');
like($notify, qr/'--es', 'timestamp', \$m->\{'timestamp'\}/, 'and its moment');

# --- the loader makes it reachable by name ----------------------------------
my $loader = source('lib/JawnOS/Domain/Loader.pm');
like($loader, qr/JawnOS::Domain::Notify' for qw\(notification_sender notification_event_uuid /,
	'the new helper is in the domain loader map');

# --- the house-wide announcers name their events ---------------------------
my $alarm = source('perl/Alarm.pl');
like($alarm, qr/my \$note_event = join '\|', 'appointment', \$a->\{'uuid'\} \|\| '', \$type \|\| '',/,
	'an appointment notice is named by its row, its type and its stamps');
like($alarm, qr/dedupe => \$note_event,/, 'and the sender is given that name');
like($alarm, qr/my \$budget_event = join '\|', 'budget', \$app, \$circumstance,/,
	'a budget crossing is named by app and circumstance');
like($alarm, qr/int\(\$server_time \/ 600000\)/,
	'with a ten-minute window, so the grid slot agrees and the next is new');
like($alarm, qr/dedupe => \$budget_event,/, 'and the sender is given that name');
like($alarm, qr/my \$cart_event = join '\|', 'marketcart', \$seen \|\| 0, int\(\$now \/ 21600000\);/,
	'the cart reminder is named by its shared marker and six-hour window');
like($alarm, qr/dedupe => \$cart_event,/, 'and the sender is given that name');

my $clock2 = source('lib/JawnOS/Domain/Clock2.pm');
like($clock2, qr/dedupe => join\('\|', 'clockalarm', \$alarm->\{'uuid'\} \|\| '', \$fire_at \|\| \$now\)/,
	'an alarm ring is named by the alarm and the fire');
like($clock2, qr/dedupe => join\('\|', 'clocktimer', \$timer->\{'uuid'\} \|\| '', \$timer->\{'ends_at'\} \|\| \$ended\)/,
	'a finished timer is named by the timer and its end');

# --- the cleanup for rows written before the guard --------------------------
require DBI;
require File::Temp;

sub run_cleanup {
	my @args = @_;
	open(my $fh, '-|', $^X, "$root/scripts/notifications_dedupe.pl", @args) or die "spawn: $!";
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return ($out, ($? || 0) >> 8);
}

my $dir = File::Temp->newdir(CLEANUP => 1);
my $copy = "$dir/notifications.db";
my $copy_db = DBI->connect("dbi:SQLite:dbname=$copy", '', '', { RaiseError => 1, PrintError => 0 });
$copy_db->do(q{create table notifications (timestamp varchar(255), message varchar(500), title varchar(255), tag varchar(500), key varchar(500), id int, image varchar(500), uuid varchar(255) unique, server_time varchar(50), ost varchar(25), role varchar(100), app varchar(255))});
my $insert = $copy_db->prepare('insert into notifications (uuid, app, title, message, timestamp, server_time) values (?,?,?,?,?,?)');
my $base = 1_790_000_000_000;
# four device copies of one budget crossing, then the next crossing a day on
for my $i (0 .. 3) {
	$insert->execute("fan$i", 'laydown', 'Laydown', '0/2d/week', $base + $i * 1500, $base + $i * 1500);
}
$insert->execute('fan-later', 'laydown', 'Laydown', '0/2d/week', $base + 86_400_000, $base + 86_400_000);
# three separate receipts over five minutes: not duplicates
for my $i (0 .. 2) {
	$insert->execute("receipt$i", 'market', 'Receipt in Market', 'A receipt from Walmart.', $base + $i * 300_000, $base + $i * 300_000);
}
# a random row beside the shared event name: the shared row is the keeper
$insert->execute('random-stop', 'work', 'Work', 'Work', $base + 1000, $base + 1000);
$insert->execute('notevent-shared', 'work', 'Work', 'Work', $base + 2000, $base + 2000);
is($copy_db->selectrow_array('select count(*) from notifications'), 10, 'the fixture holds every row');

my ($dry, $dry_status) = run_cleanup('--db', $copy);
is($dry_status, 0, 'the dry run exits clean');
like($dry, qr/2 notice group\(s\), 4 duplicate row\(s\) to remove/,
	'it names the two clusters and their four spare rows');
is($copy_db->selectrow_array('select count(*) from notifications'), 10, 'and changes nothing');

my ($applied, $applied_status) = run_cleanup('--db', $copy, '--apply');
is($applied_status, 0, 'the apply exits clean');
like($applied, qr/2 notice group\(s\), 4 duplicate row\(s\) removed/, 'it removes the spare rows');
is($copy_db->selectrow_array('select count(*) from notifications'), 6, 'leaving six rows');
is($copy_db->selectrow_array("select count(*) from notifications where app = 'laydown'"), 2,
	'one row for each real laydown crossing');
is($copy_db->selectrow_array("select count(*) from notifications where app = 'market'"), 3,
	'and the three separate receipts survive');
is($copy_db->selectrow_array("select uuid from notifications where app = 'work'"), 'notevent-shared',
	'the shared event name is the row kept');

done_testing();
