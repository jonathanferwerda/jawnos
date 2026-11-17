# tests-for: lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_misc14.pm templates/appointment_wrapper.html.ep public/js/manager/time_preview.js perl/help/topics_features.pl
# covers:    the duration line under an appointment's own field reads the running session's elapsed time - the length a stop would save - instead of the app's usual length; a closed app still reads its usual length, a typed length still wins, and the oldest open session is the one the stop fallback closes

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $now = 1_800_000_000_000;

# ------------------------------------------------------- the running session
&subs::db_insert('settings', {
	app => 'preview_running', setting => 'duration', value => '57m 30s',
	device => 'computer', server_time => $now, uuid => 'preview-running-setting',
});
&subs::db_insert('appointments', {
	app => 'preview_running', uuid => 'preview-running-open', type => 'start',
	timestamp => $now - 600_000, server_time => $now, seen => 'yes',
});
is(&subs::running_session_duration('preview_running', $now), 600_000,
	'a running session reads its elapsed time, not the app usual length');

# a closed app has no running session, so the preview keeps the usual length
&subs::db_insert('appointments', {
	app => 'preview_running_closed', uuid => 'preview-running-closed', type => 'stop',
	timestamp => $now - 7_200_000, stop_timestamp => $now - 3_600_000,
	duration => -3_600_000, stop_seen => 'yes', server_time => $now,
});
ok(!defined &subs::running_session_duration('preview_running_closed', $now),
	'a closed app has no running session');

# two open sessions: the stop fallback closes the oldest, so the line reads it
&subs::db_insert('appointments', {
	app => 'preview_running_two', uuid => 'preview-running-old', type => 'start',
	timestamp => $now - 1_800_000, server_time => $now, seen => 'yes',
});
&subs::db_insert('appointments', {
	app => 'preview_running_two', uuid => 'preview-running-new', type => 'start',
	timestamp => $now - 600_000, server_time => $now, seen => 'yes',
});
is(&subs::running_session_duration('preview_running_two', $now), 1_800_000,
	'the oldest open session is the one a stop would close');

# a record row is a running session too, and a future start is not one yet
&subs::db_insert('appointments', {
	app => 'preview_running_record', uuid => 'preview-running-record', type => 'record',
	timestamp => $now - 120_000, server_time => $now, seen => 'yes',
});
is(&subs::running_session_duration('preview_running_record', $now), 120_000,
	'a record is a running session');
&subs::db_insert('appointments', {
	app => 'preview_running_future', uuid => 'preview-running-future', type => 'start',
	timestamp => $now + 600_000, server_time => $now, seen => 'yes',
});
ok(!defined &subs::running_session_duration('preview_running_future', $now),
	'a start after the press is not a session it could close');
ok(!defined &subs::running_session_duration('preview_running_empty', $now),
	'an app with no rows has no running session');
ok(!defined &subs::running_session_duration('', $now), 'no app, no reading');

# --------------------------------------------------------------- the wiring
my $controller = read_file(root() . '/lib/JawnOS/Controller/manager_misc14.pm');
like($controller, qr/running_session_duration\(\$app/, 'the preview asks for the running session');
like($controller, qr/\$duration_running = 1;/, 'it marks a running reading');
like($controller, qr/ui\('Running'\)/, 'and labels the running length');
like($controller, qr/running\s*=>\s*\$duration_running/, 'the reply carries the running flag');

my $template = read_file(root() . '/templates/appointment_wrapper.html.ep');
like($template, qr/class="main_input_preview duration_preview"/,
	'the line under the duration input is the one painted');
my $js = read_file(root() . '/public/js/manager/time_preview.js');
like($js, qr/put\('\.duration_preview'/, 'the preview writer paints the duration line');
my $help = read_file(root() . '/perl/help/topics_features.pl');
like($help, qr/While a session of that app is running/, 'the appointment topic explains the running line');

done_testing();
