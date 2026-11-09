# tests-for: lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part14.pm
# covers:    a stop that carried no length of its own teaches the app's usual duration, whichever writer closed the session - a press through manager_reset or an automatic stop through appointment_writer (a plate, a timer, a weather rule, a relay)

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

# The app's usual duration is learned from the sessions it closes. That lesson
# lived only in manager_reset's live-stop branch, so a session the person never
# pressed stop on - the autostop at a plate, a timer, a relayed stop through
# appointment_writer - closed the row and taught the app nothing. An automatic
# stop is the same measurement as a hand stop, so both writers now use one
# learner.

my $root     = repo_root();
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
my $loader   = read_file("$root/lib/JawnOS/Domain/Loader.pm");
my $part05   = read_file("$root/lib/JawnOS/Manager/Part05.pm");
my $part14   = read_file("$root/lib/JawnOS/Manager/Part14.pm");
my $appt     = read_file("$root/lib/JawnOS/Domain/Appointment.pm");

# --------------------------------------------------------- the shared learner

ok($calendar =~ /sub session_duration_learn\s*\{/, 'the duration learner lives in the domain, not in one writer');
like($loader, qr/JawnOS::Domain::Calendar' for qw\([^)]*\bsession_duration_learn\b/,
	'and the domain loader maps it, so both writers can call it by name');

# A session is measured from its start to the press, so the stored length is
# negative (start - stop); the learner averages magnitudes.
{
	package DurationRows;
	sub new { my ($class, $rows) = @_; bless { rows => $rows }, $class }
	sub hashes { $_[0]->{'rows'} }
}

my @closed = (
	{ duration => -600_000  },   # 10 minutes
	{ duration => -1_800_000 },  # 30 minutes
	{ duration => undef },       # a repair left no length: not a reading
);
my ($sql_seen, $write) = ('', undef);
{
	no warnings 'redefine';
	local *subs::db_query = sub { my ($sql) = @_; $sql_seen = $sql; return DurationRows->new(\@closed); };
	local *subs::setting_setter = sub { $write = $_[0]; return 1; };

	my $average = &subs::session_duration_learn('coffee', -1_200_000);
	is($average, 1_200_000, 'the session being closed joins the average of the closed ones');
	is($write->{'app'},     'coffee',   'the app whose duration is learned');
	is($write->{'setting'}, 'duration', 'the usual-length setting is what changes');
	is($write->{'value'}, &subs::duration_sayer(1200), 'and it is written in the readable form');
	like($sql_seen, qr/type=\? order by server_time DESC LIMIT 40/, 'the average is over the recent stops, newest first');
}

is(&subs::session_duration_learn(undef, -1000), undef, 'an app with no name learns nothing');
is(&subs::session_duration_learn('coffee'), undef, 'a stop with no length learns nothing');

# ------------------------------------------------------------ both writers call it

like($part14, qr/&subs::session_duration_learn\(\$app, \$duration\)/,
	'manager_reset learns through the shared sub');
unlike($part14, qr/\$total_durations/, 'and no longer carries its own copy of the average');

ok($part05 =~ /my \$supplied_duration = \$app->\{'duration'\};/,
	'appointment_writer remembers whether the stop named a length');
my $learn_at = index($part05, '&subs::session_duration_learn($app->{\'app\'}, $app->{\'duration\'})');
my $close_at = index($part05, "db_update('appointments', { stop_timestamp => \$app->{'timestamp'}, stop_seen => 'yes', duration => \$app->{'duration'}");
ok($learn_at >= 0, 'a stop that carried no length of its own teaches the app');
ok($close_at >= 0, 'and the session is still closed');
ok($learn_at < $close_at, 'the learner reads the table before this session is in it, so the average counts it once');
like($part05, qr/!defined \$supplied_duration/, 'a length the caller supplied is an account, not a measurement');
like($part05, qr/<= &subs::stale_action_ms\(\)/, 'a stop replayed long after its press teaches nothing');

# The plate builds a stop with no duration at all, so it is the measured case.
my ($hpdata) = $appt =~ /(my \$hpdata = \{.*?\n\t+};)/s;
ok($hpdata, 'navigation_automation builds its stop row');
unlike($hpdata, qr/\bduration\b/, 'the plate names no length, so the writer measures the session');

done_testing();
