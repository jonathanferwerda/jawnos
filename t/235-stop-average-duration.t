# tests-for: lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part14.pm scripts/duration_backfill.pl
# covers:    a stop that carried no length of its own teaches the app's usual duration, whichever writer closed the session - a press through manager_reset or an automatic stop through appointment_writer (a plate, a timer, a weather rule, a relay); and the backfill that teaches apps from the stops they already have

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

# ------------------------------------------------------------ the backfill
# The average is also readable without a session being closed, which is what the
# one-off backfill needs.
{
	no warnings 'redefine';
	local *subs::db_query = sub { return DurationRows->new(\@closed); };
	is(&subs::session_duration_average('coffee'), 1_200_000,
		'with nothing being closed the average is of the closed sessions alone');
	is(&subs::session_duration_average('coffee', -600_000), 1_000_000,
		'a length handed in joins the same 40-row average');
	local *subs::db_query = sub { return DurationRows->new([]); };
	is(&subs::session_duration_average('quiet'), undef, 'an app with no closed sessions has no average');
}

# A zero, a lifetime and a clock-skewed row are not lengths to learn from: one
# bad row in the last forty would otherwise carry a lifetime into the average.
{
	no warnings 'redefine';
	my @bad = (
		{ duration => 0 },                    # a start and stop in the same instant
		{ duration => 1_230_000_000_000 },    # ~39 years (a 1970 start)
		{ duration => -600_000 },             # 10 minutes, the only real one
	);
	local *subs::db_query = sub { return DurationRows->new(\@bad); };
	is(&subs::session_duration_average('coffee'), 600_000,
		'a zero and a lifetime-long row are left out of the average');
	local *subs::db_query = sub { return DurationRows->new([]); };
	is(&subs::session_duration_average('coffee', 40 * 86400 * 1000), undef,
		'a stop measured longer than thirty days teaches nothing');
}

my %stops = (
	coffee => [ { duration => -600_000 }, { duration => -1_800_000 } ],
	home   => [],
);
my (@writes, @reads);
{
	no warnings 'redefine';
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		return DurationRows->new([ map { { app => $_ } } qw(coffee home empty) ]) if $sql =~ /select distinct app/;
		return DurationRows->new($stops{$args[0]} || []);
	};
	local *subs::setting_grabber = sub { push @reads, $_[0]->{'app'}; return $_[0]->{'app'} eq 'coffee' ? '10m' : 'old'; };
	local *subs::setting_setter = sub { push @writes, $_[0]; return 1; };

	my $dry = &subs::session_duration_backfill(0);
	is(scalar @writes, 0, 'the dry run writes nothing');
	my %dry = map { $_->{'app'} => $_ } @{$dry};
	ok(!$dry{'home'}, 'an app with no closed sessions is left out');
	is($dry{'coffee'}->{'value'}, &subs::duration_sayer(1200), 'the computed usual length is reported');
	is($dry{'coffee'}->{'was'}, '10m', 'and what the setting held is read back');
	ok($dry{'coffee'}->{'changed'}, 'a different value is marked as a change');

	my $applied = &subs::session_duration_backfill(1);
	is(scalar @writes, 1, 'the apply run writes the apps that have an average');
	is($writes[0]->{'app'},     'coffee',   'for the app the stops name');
	is($writes[0]->{'setting'}, 'duration', 'into the usual-length setting');
	is($writes[0]->{'value'}, &subs::duration_sayer(1200), 'with the value the dry run showed');
}

my $script = read_file("$root/scripts/duration_backfill.pl");
like($script, qr/session_duration_backfill\(\$apply\)/, 'the script runs the shared backfill with its apply flag');
like($script, qr/--apply/, 'and names the write it can make');

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
