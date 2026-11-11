# tests-for: lib/JawnOS/Domain/Remote.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Routes/manager_configure2.pm public/js/manager/configure/07_qa_nightly.js templates/configure/qa_panel.html.ep scripts/systemd/jawnos-land-promote.timer perl/help/topics_configure.pl
# covers:    the release schedule - presets and phrases become one OnCalendar
#           line, the drop-in that replaces the shipped schedule, and the
#           save/state path the Plat -> QA card uses

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use Test::More;
use JawnOSTest;

subs::preload(qw(
	release_schedule_default release_schedule_parse release_schedule_read
	release_schedule_dropin_body release_schedule_apply release_schedule_save
	release_schedule_state release_now_local
));

sub parsed { return subs::release_schedule_parse($_[0]) }
sub cal {
	my $p = parsed($_[0]);
	return $p->{'ok'} ? $p->{'oncalendar'} : '';
}

# --- presets and phrases -----------------------------------------------------
is(cal('hourly at 04:15'), '*-*-* *:15:00', 'hourly uses the minute');
is(cal('daily at 04:30'), '*-*-* 04:30:00', 'daily uses the time');
is(cal('weekly at 06:30'), 'Mon *-*-* 06:30:00', 'weekly is Monday');
is(cal('monthly at 04:00'), '*-*-01 04:00:00', 'monthly is the first');
is(cal('monthly on the 15th at 06:30'), '*-*-15 06:30:00', 'monthly can name its day');
is(cal('every friday at 06:30'), 'Fri *-*-* 06:30:00', 'every weekday');
is(cal('every third friday of the month at 06:30'), 'Fri *-*-15..21 06:30:00',
	'the third friday is days 15 to 21');
is(cal('the first monday of the month at 03:00'), 'Mon *-*-1..7 03:00:00',
	'the first monday is days 1 to 7');
is(cal('every 3 days at 03:00'), '*-*-01/3 03:00:00', 'every N days');
is(cal('every 2 hours at 04:15'), '*-*-* 00/2:15:00', 'every N hours');
is(cal('2026-12-25 04:00'), '2026-12-25 04:00:00', 'a fixed date and time');
is(cal('2026-12-25 at 4pm'), '2026-12-25 16:00:00', 'a spoken time on a fixed date');
is(parsed('every third friday of the month')->{'phrase'}, 'every third friday of the month',
	'the phrase is kept for the panel');

my $bad = parsed('2026-12-25');
ok(!$bad->{'ok'}, 'a fixed date without a time is refused');
like($bad->{'error'}, qr/time/, 'and names the missing time');
ok(!parsed('every 2 weeks')->{'ok'}, 'every N weeks is refused');
ok(!parsed('whenever')->{'ok'}, 'nonsense is refused');
ok(!parsed('')->{'ok'}, 'an empty phrase is refused');
like(parsed('whenever')->{'error'}, qr/hourly, daily, weekly, monthly/,
	'the refusal lists what the field understands');

# --- the drop-in -------------------------------------------------------------
# The timer's own OnCalendar is a list; the empty assignment resets it, so the
# shipped weekly line never coexists with the chosen one.
my $body = subs::release_schedule_dropin_body('Fri *-*-15..21 06:30:00');
like($body, qr/^OnCalendar=$/m, 'the drop-in resets the list first');
like($body, qr/^OnCalendar=Fri \*-\*-15\.\.21 06:30:00$/m, 'and then carries the chosen line');
like($body, qr/^\[Timer\]$/m, 'in a Timer section');

# --- apply and save ----------------------------------------------------------
my $dry = subs::release_schedule_apply({ oncalendar => 'Mon *-*-* 04:00:00', dry_run => 1 });
is($dry->{'ok'}, 1, 'a dry run plans');
is($dry->{'rows'}[0]{'state'}, 'planned', 'with a planned row');
is($dry->{'rows'}[0]{'path'}, '/etc/systemd/system/jawnos-land-promote.timer.d/50-jawn-schedule.conf',
	'beside the release timer');

my $stored;
my @cmds;
my $save = subs::release_schedule_save('every third friday of the month at 06:30', {
	setter => sub { $stored = $_[0] },
	runner => sub { push @cmds, [@_]; return (0, ''); },
});
is($stored, 'Fri *-*-15..21 06:30:00', 'the canonical line is what is stored');
is($save->{'state'}, 'retimed', 'the timer is restarted');
is($save->{'retime_ok'}, 1, 'and reported retimed');
like(join("\n", map { join(' ', @$_) } @cmds), qr/systemctl restart jawnos-land-promote\.timer/,
	'with the restart the panel promises');

my $missing = subs::release_schedule_apply({
	oncalendar => 'Mon *-*-* 04:00:00',
	runner => sub {
		my @cmd = @_;
		return (1, 'Unit jawnos-land-promote.timer not found.') if join(' ', @cmd) =~ /systemctl restart/;
		return (0, '');
	},
});
is($missing->{'rows'}[0]{'state'}, 'not-installed', 'a timer that is not installed is reported as such');

# --- Release Now -------------------------------------------------------------
my $planned = subs::release_now_local({
	runner => sub { return (3, 'inactive'); },
	dry_run => 1,
});
is($planned->{'ok'}, 1, 'a dry run plans the release');
is($planned->{'state'}, 'planned', 'and does not start anything');
is(join(' ', @{$planned->{'command'}}),
	'sudo -n systemctl start --no-block jawnos-land-promote.service',
	'starting the service the timer runs');

my @release_cmds;
my $started = subs::release_now_local({
	now => 1_000,
	runner => sub {
		push @release_cmds, [@_];
		return (3, 'inactive') if join(' ', @_) eq 'systemctl is-active jawnos-land-promote.service';
		return (0, '');
	},
});
is($started->{'ok'}, 1, 'Release Now starts the service');
is($started->{'state'}, 'running', 'and reports it running');
is($started->{'started'}, 1_000, 'with the time it started');
like(join("\n", map { join(' ', @$_) } @release_cmds), qr/systemctl start --no-block jawnos-land-promote\.service/,
	'through the same command the panel promises');

my $busy = subs::release_now_local({ runner => sub { return (0, 'active'); } });
ok(!$busy->{'ok'}, 'a release already running is refused');
is($busy->{'state'}, 'running', 'and named as running');

my $gone = subs::release_now_local({
	runner => sub {
		return (3, 'inactive') if $_[0] eq 'systemctl';
		return (1, 'Unit jawnos-land-promote.service not found.');
	},
});
ok(!$gone->{'ok'}, 'a machine without the service refuses');
is($gone->{'state'}, 'not-installed', 'and says the service is not installed');

# --- what the panel shows ----------------------------------------------------
my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/scripts/systemd");
write_file("$tmp/scripts/systemd/jawnos-land-promote.timer", "[Timer]\nOnCalendar=Mon 04:00:00\n");
my $state = subs::release_schedule_state({
	repo => $tmp,
	grabber => sub { '' },
	runner => sub { return (1, 'not installed'); },
});
is($state->{'oncalendar'}, 'Mon 04:00:00', 'a machine with no timer shows the shipped unit');
is($state->{'source'}, 'unit', 'and names the unit as the source');

my $dropin = "$tmp/50-jawn-schedule.conf";
write_file($dropin, "[Timer]\nOnCalendar=\nOnCalendar=Fri *-*-15..21 06:30:00\n");
my $dropped = subs::release_schedule_state({
	repo => $tmp,
	dropin => $dropin,
	grabber => sub { '' },
	runner => sub { return (1, 'not installed'); },
});
is($dropped->{'oncalendar'}, 'Fri *-*-15..21 06:30:00', 'a drop-in wins over the unit');
is($dropped->{'source'}, 'drop-in', 'and says so');

# --- the control and its text ------------------------------------------------
my $panel = read_file("$FindBin::Bin/../templates/configure/qa_panel.html.ep");
like($panel, qr/id="release_schedule_select"/, 'the panel has the cadence select');
like($panel, qr/id="release_schedule_custom"/, 'and the custom phrase field');
like($panel, qr/id="release_schedule_save"/, 'and the save button');
like($panel, qr/id="release_now"/, 'and a Release Now button');
like($panel, qr/Release Now/, 'whose words say what it does');
like(read_file("$FindBin::Bin/../public/js/manager/configure/07_qa_nightly.js"),
	qr{/manager/configure/release_schedule_save}, 'the script saves it');
like(read_file("$FindBin::Bin/../public/js/manager/configure/07_qa_nightly.js"),
	qr{/manager/configure/release_now}, 'and starts the release');
like(read_file("$FindBin::Bin/../lib/JawnOS/Routes/manager_configure2.pm"),
	qr{/manager/configure/release_schedule_save}, 'the route exists');
like(read_file("$FindBin::Bin/../lib/JawnOS/Routes/manager_configure2.pm"),
	qr{/manager/configure/release_now}, 'the Release Now route exists');
like(read_file("$FindBin::Bin/../lib/JawnOS/Domain/Loader.pm"),
	qr/release_now_local/, 'the loader maps the helper');
my $timer = read_file("$FindBin::Bin/../scripts/systemd/jawnos-land-promote.timer");
like($timer, qr/^OnCalendar=Mon 04:00:00$/m, 'the shipped timer is weekly by default');
unlike($timer, qr/OnUnitActiveSec/, 'and no longer counts a relative week');
like(read_file("$FindBin::Bin/../perl/help/topics_configure.pl"),
	qr/Release schedule, below Nightly schedule/, 'the help topic explains it');

done_testing();
