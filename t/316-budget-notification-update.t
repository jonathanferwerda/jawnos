# tests-for: lib/JawnOS/Domain/Budget.pm lib/JawnOS/Domain/Notify.pm perl/Alarm.pl templates/configure/app_notification.html.ep templates/apps/notifications.html.ep public/js/manager/notifications.js public/js/manager/notifications_toast.js lib/JawnOS/Controller/manager_misc6.pm
# covers:    A budget notice that only changed its reading rewrites the card it
#            already has; a new appointment or a new period speaks afresh. The
#            two per-app pickers say which statuses and which budget types may
#            announce. The Notifications app's Appointments view reuses the same
#            Configure panel to switch appointments on.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
sub source { my $text = read_file("$root/$_[0]"); return defined $text ? $text : ''; }

# --- the types an app really budgets ---------------------------------------
require JawnOS::Domain::Budget;
is_deeply(subs::budget_notification_types({ budget => '5m 55s/day,2.071/day' }),
	[ 'occurences', 'duration' ],
	'a duration entry and a bare count are the two types the app budgets');
is_deeply(subs::budget_notification_types({ budget => '19869.053steps/1week,180weight' }),
	[ 'steps', 'weight' ],
	'an app measure with a budget is offered by its own name');
is_deeply(subs::budget_notification_types({ budget => '$204/D' }), [ 'total' ],
	'a money target is the total type');
is_deeply(subs::budget_notification_types({ budget => '10quantity/day' }), [ 'quantity' ],
	'a quantity target is the quantity type');
is_deeply(subs::budget_notification_types({ budget => '' }), [],
	'an app with no budget offers no type');

# --- the watcher rewrites instead of announcing again -----------------------
my $alarm = source('perl/Alarm.pl');
like($alarm, qr/sub budget_notification_filter\b/, 'the pickers have one reader');
like($alarm, qr/budget_notification_statuses/, 'the status picker is read by the watcher');
like($alarm, qr/budget_notification_types/, 'the type picker is read by the watcher');
like($alarm, qr/my \$status_changed = \(\$cache_budget->\{'status'\} ne \$budget->\{'status'\}\);/,
	'a status crossing is named');
like($alarm, qr/my \$value_changed = /, 'and so is a reading that moved without one');
like($alarm, qr/my \$budget_event = join '\|', 'budget', \$app, \$circumstance, \$window_start, \$signature;/,
	'the event is named by the period and the appointments behind it');
unlike($alarm, qr/int\(\$server_time \/ 600000\)/,
	'not by a ten-minute grid slot, which made each pass a new notice');
like($alarm, qr/\(\$already \? \(update => 1\) : \(\)\)/,
	'an event already on the list is updated rather than announced again');
like($alarm, qr/if \(\$already \|\| \$status_changed\) \{/,
	'a moved reading with no card yet waits for the crossing');

# --- the sender's update mode -----------------------------------------------
my $notify = source('lib/JawnOS/Domain/Notify.pm');
like($notify, qr/if \(\$m->\{'update'\}\) \{/, 'the sender knows an update');
like($notify, qr/type => 'notification_update'/, 'and tells the screens to replace the row');
like($notify, qr/only_alert_once/, 'the phone updates its own notification without buzzing again');
like($notify, qr/&subs::db_update\('notifications'/, 'the stored row is rewritten, not duplicated');
like($notify, qr/sub notification_appointments\(\)/, 'the app asks for the enabled appointments');
like($notify, qr/app_visibility_value\(\$app\) eq 'private'/, 'private appointments are never offered');

# --- the shared Configure panel and the app view ----------------------------
my $panel = source('templates/configure/app_notification.html.ep');
like($panel, qr/setting="budget_notification_statuses"/, 'the panel carries the status picker');
like($panel, qr/setting="budget_notification_types"/, 'and the type picker');
like($panel, qr/All selected announces every status/, 'and says what all-selected means');
like(source('templates/configure/appointment_list.html.ep'),
	qr/include 'configure\/app_notification', a => \$a, settings => \$appts->\{\$a\}->\{'setting'\}/,
	'Configure draws the same panel');

my $apps = source('templates/apps/notifications.html.ep');
like($apps, qr/data-notifications-view="main"/, 'the Notifications app has a Main view');
like($apps, qr/data-notifications-view="appointments"/, 'and an Appointments view');
like($apps, qr/id="notifications_app_appt_add"/, 'with an input to add an appointment');
like($apps, qr/include 'configure\/app_notification'/, 'and the same panel per enabled appointment');
like($apps, qr/flex: 0 0 auto/, 'rows cannot be squeezed unreadable by a long list');

my $js = source('public/js/manager/notifications.js');
like($js, qr/setting: 'notification'/, 'adding an appointment switches its notification on');
like($js, qr/settingSetter/, 'through the shared setting writer');

like(source('lib/JawnOS/Controller/manager_misc6.pm'),
	qr/notification_appointments\(\)/, 'the app hands the view the enabled appointments');

done_testing();
