# tests-for: lib/JawnOS/Domain/Clock.pm lib/JawnOS/Domain/Budget2.pm lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_configure.pm templates/configure/me_setting_list.html.ep public/js/manager/configure/03_platform_misc.js
# covers:    The house's time zone is one setting. Configure -> Me offers the
#            zones the machine knows and saves the same `clock_timezone` the
#            taskbar and the handheld read; saving it also sets the operating
#            system's clock. The evaluation agent is told the zone and the time
#            there, adopts it for the SQLite day/hour buckets and every localtime
#            in its gather, and puts the worker's own zone back afterwards.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();

# --- the helpers are reachable through the domain loader --------------------
ok(subs::provides('clock_zone_list'), 'clock_zone_list is mapped');
ok(subs::provides('clock_zone_valid'), 'clock_zone_valid is mapped');
ok(subs::provides('clock_zone_house'), 'clock_zone_house is mapped');
ok(subs::provides('clock_zone_text'), 'clock_zone_text is mapped');
ok(subs::provides('clock_zone_adopt'), 'clock_zone_adopt is mapped');
ok(subs::provides('clock_zone_apply'), 'clock_zone_apply is mapped');

# --- a zone is a name in the tz database, not a path -------------------------
ok(subs::clock_zone_valid('America/New_York'), 'a known zone is valid');
ok(subs::clock_zone_valid('UTC'), 'UTC is valid');
ok(!subs::clock_zone_valid('../../etc/passwd'), 'a traversal is refused');
ok(!subs::clock_zone_valid('Not/AZone'), 'an unknown zone is refused');
ok(!subs::clock_zone_valid(''), 'an empty zone is refused');

my $zones = subs::clock_zone_list();
ok(ref $zones eq 'ARRAY' && scalar @{$zones} > 10, 'the picker has the tz database');
ok((grep { $_ eq 'UTC' } @{$zones}), 'UTC is offered');

# --- a moment is read in the zone asked for, and the worker is put back ------
# The harness pins TZ=UTC; 17:00 UTC is noon in New York, winter and summer.
my $winter = ts(2026, 1, 15, 17, 0, 0);
is(subs::clock_zone_text($winter, 'UTC', '%Y-%m-%d %H:%M %Z'),
	'2026-01-15 17:00 UTC', 'UTC reads as UTC');
is(subs::clock_zone_text($winter, 'America/New_York', '%Y-%m-%d %H:%M %Z'),
	'2026-01-15 12:00 EST', 'winter New York is EST and five hours back');
my $summer = ts(2026, 7, 15, 16, 0, 0);
is(subs::clock_zone_text($summer, 'America/New_York', '%Y-%m-%d %H:%M %Z'),
	'2026-07-15 12:00 EDT', 'summer New York is EDT and four hours back');
is($ENV{'TZ'}, 'UTC', 'formatting another zone restores the worker zone');

# --- adopting a zone is temporary -------------------------------------------
my $restore = subs::clock_zone_adopt('America/Chicago');
is($ENV{'TZ'}, 'America/Chicago', 'adopt makes the house zone current');
$restore->();
is($ENV{'TZ'}, 'UTC', 'the coderef puts the worker zone back');

# The evaluation's daily and hourly buckets come from SQLite's `localtime`
# modifier, so the adopted zone must reach SQLite as well as Perl.
my $restore_sql = subs::clock_zone_adopt('America/New_York');
my $hour = subs::db_query("select strftime('%H', '2026-01-15 17:00:00', 'localtime') as h")->hash->{'h'};
is($hour, '12', 'SQLite localtime follows the adopted zone');
$restore_sql->();

# --- the house zone: the setting, then Eastern, never the box's UTC ---------
{
	local *subs::misc_setting = sub { 'Europe/Paris' };
	is(subs::clock_zone_house(), 'Europe/Paris', 'the chosen setting wins');
}
{
	local *subs::misc_setting = sub { '' };
	is(subs::clock_zone_house(), 'America/New_York', 'no choice falls to the house default');
}
{
	local *subs::misc_setting = sub { 'local' };
	is(subs::clock_zone_house(), 'America/New_York', 'Local means the house default, not a TZ name');
}
{
	local *subs::misc_setting = sub { 'Not/AZone' };
	is(subs::clock_zone_house(), 'America/New_York', 'an unreadable value falls to the house default');
}

# --- an invalid zone never reaches the operating system ---------------------
my $refused = subs::clock_zone_apply('../../etc/passwd');
ok(ref $refused eq 'HASH' && !$refused->{'ok'}, 'the OS setter refuses a bad zone');
my @elsewhere = grep { $_ ne subs::clock_zone_system() } qw(Europe/Paris America/New_York Asia/Tokyo);
{
	local $ENV{'JAWNOS_TIMEZONE_DRY_RUN'} = 1;
	my $dry = subs::clock_zone_apply($elsewhere[0]);
	ok($dry->{'ok'} && $dry->{'dry_run'}, 'the OS setter answers a dry run without touching the box');
}

# --- Configure -> Me offers the picker and writes the house setting ---------
my $configure = read_file("$root/lib/JawnOS/Controller/manager_configure.pm");
like($configure, qr/timezone => \(&subs::misc_setting\('clock_timezone'\) \/\/ ''\)/, 'the Me panel shows the saved zone (empty means Local)');
like($configure, qr/timezones => &subs::clock_zone_list\(\)/, 'the Me panel offers the zone list');

my $me = read_file("$root/templates/configure/me_setting_list.html.ep");
like($me, qr/class="me_timezone"/, 'the Me panel has a time-zone picker');
like($me, qr/class="me_timezone_note"/, 'the picker has a place to report the OS result');
like($me, qr/\@\{ \$timezones/, 'the picker renders the list');

my $js = read_file("$root/public/js/manager/configure/03_platform_misc.js");
like($js, qr/'\.me_timezone'/, 'the picker saves on change');
like($js, qr/setting: 'clock_timezone'/, 'it writes the same house setting the taskbar reads');
like($js, qr/timezone_os/, 'the page reads the OS result');

# --- saving the setting sets the OS clock, and says when it could not -------
my $name = read_file("$root/lib/JawnOS/Domain/Name.pm");
like($name, qr/clock_zone_apply\(\$value\)/, 'setting_setter applies the zone to the OS');
like($name, qr/timezone_os/, 'the OS result rides back to the caller');
like($name, qr/!\$sync && \(\$setting \/\/ ''\) eq 'clock_timezone'/, 'a peer replay is not a local time-zone pick');

# --- the evaluation agent is told the zone and adopts it for its gather ----
my $budget = read_file("$root/lib/JawnOS/Domain/Budget2.pm");
like($budget, qr/clock_zone_house\(\)/, 'the evaluation reads the house zone');
like($budget, qr/clock_zone_adopt\(\$zone\)/, 'the evaluation adopts it for its buckets');
like($budget, qr/time_zone => \$zone/, 'the briefing carries the zone');
like($budget, qr/now => \$now_text/, 'the briefing carries the time there');
like($budget, qr/The house's time zone is \$zone/, 'the prompt says the zone and the time');
like($budget, qr/previous_at_text/, 'the previous report carries a local stamp');
like($budget, qr/next_run_text/, 'the schedule carries a local next run');
like($budget, qr/\$restore_zone->\(\)/, 'the worker zone is restored after the run');

# --- the help topic covers the template it now names -----------------------
my $help = read_file("$root/perl/help/topics_configure.pl");
like($help, qr/templates\/configure\/me_setting_list\.html\.ep/, 'the Configure topic names the Me panel');
like($help, qr/Time zone sets the one clock/, 'the help explains the time-zone picker');

done_testing();
