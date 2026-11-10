# tests-for: lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Resolve.pm lib/JawnOS/Manager/Part28.pm lib/JawnOS/Routes/manager_configure2.pm perl/President.pl perl/help/topics_configure.pl perl/language.pl public/js/manager/configure/07_qa_nightly.js qa/lib/QaSetting.pm templates/
# covers:    Configure -> Plat -> QA now owns the three nightly times and a Run now for each run.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Cwd qw(abs_path);
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use File::Spec;

# Configure -> Plat -> QA now owns the three nightly times and a Run now for each
# run. The rules this file pins:
#
#   - a time is HH:MM between 00:00 and 23:59, and anything else is refused
#     (never silently clamped into a valid-looking hour);
#   - the drop-in the save writes carries the OnCalendar line (and a randomized
#     delay only for the suite), and it is reported per unit;
#   - a refused target - a phone, or a machine that is not the chosen one -
#     changes nothing;
#   - Run now refuses a run that is already going, and a second press inside the
#     cooldown, so a double press cannot start the unit twice;
#   - the panel shows the OnCalendar the timer really holds.
#
# Nothing here touches systemd or the live database: every command goes through
# an injected runner, and every setting through an injected setter/grabber.
my $root = abs_path("$FindBin::Bin/..");
require JawnOS::Domain::Remote;

no warnings 'redefine', 'once';
*subs::machine_name = sub { 'qa-test-host' };
*subs::home = sub {
	my $path = shift // '';
	$path =~ s{^~}{/tmp/qa-home};
	return $path;
};

my $self = 'f' x 24;
my @rows = (
	{ uuid => 'u-lap',   signatorial => 'a' x 24, device => 'computer', hostname => 'laptop' },
	{ uuid => 'u-table', signatorial => 'b' x 24, device => 'server',   hostname => 'table' },
	{ uuid => 'u-phone', signatorial => 'c' x 24, device => 'mobile',   hostname => 'phone' },
	{ uuid => 'u-tab',   signatorial => 'd' x 24, device => 'tablet',   hostname => 'pad' },
	{ uuid => 'u-self',  signatorial => $self,    device => 'computer', hostname => 'me' },
);

# --- time validation ---------------------------------------------------------
is(subs::qa_time_clean('05:00'), '05:00', 'a time reads back as HH:MM');
is(subs::qa_time_clean(' 5:07 '), '05:07', 'a single-digit hour is normalised, not rejected');
is(subs::qa_time_clean('23:59'), '23:59', '23:59 is the last accepted minute');
is(subs::qa_time_clean('00:00'), '00:00', '00:00 is accepted');
is(subs::qa_time_clean('09:05'), '09:05', 'a leading zero in the minute is kept');

foreach my $bad ( '24:00', '23:60', '9:5', '5', 'five', '', ' ', '05:00:00', '-1:00', '05:0a', undef ) {
	is(subs::qa_time_clean($bad), '', 'rejected: ' . (defined $bad ? "'$bad'" : 'undef'));
}

# --- settings round-trip -----------------------------------------------------
my %store;
my $setter = sub { $store{ $_[1] } = $_[0]; };
my $grabber = sub { $store{ $_[0] } };

$store{'qa_night_time'}  = '04:15';
$store{'qa_ux_time'}     = '05:45';
$store{'qa_coding_time'} = 'not a time';
my $times = subs::qa_times_read({ grabber => $grabber });
is_deeply($times, { suite => '04:15', ux => '05:45', coding => '06:00' },
	'a stored time round-trips, and a bad row falls back to the run default');

my $one = subs::qa_time_save('suite', ' 4:07 ', { setter => $setter });
ok($one->{'ok'}, 'one time saves');
is($store{'qa_night_time'}, '04:07', 'the saved value is the normalised time');
is($one->{'setting'}, 'qa_night_time', 'the setting it wrote is named');

my $rejected = subs::qa_time_save('suite', '25:00', { setter => $setter });
ok(!$rejected->{'ok'}, 'an out-of-range hour is refused');
is($store{'qa_night_time'}, '04:07', 'a refused save changes nothing');

my %written;
my %three;
my $three_setter = sub { $three{ $_[1] } = $_[0]; };
my $save = subs::qa_times_save(
	{ suite => '03:10', ux => '04:20', coding => '05:30' },
	{ rows => \@rows, self => $self, device_kind => 'computer', chosen => '', setter => $three_setter },
);
ok($save->{'ok'}, 'all three times save on the local fallback');
is($three{'qa_night_time'},  '03:10', 'the suite time is a house setting');
is($three{'qa_ux_time'},     '04:20', 'the UX time is a house setting');
is($three{'qa_coding_time'}, '05:30', 'the coding time is a house setting');

my $bad_three = subs::qa_times_save(
	{ suite => '03:10', ux => '04:20', coding => 'soon' },
	{ rows => \@rows, self => $self, device_kind => 'computer', chosen => '', setter => $three_setter },
);
ok(!$bad_three->{'ok'}, 'one garbage field refuses the whole save');
is_deeply($bad_three->{'fields'}, ['coding'], 'the refused field is named');

# --- eligibility: a phone and a wrong machine cannot retime ------------------
$store{$_} = '' for keys %store;
my $before = { %three };
my $phone_local = subs::qa_times_save(
	{ suite => '03:10', ux => '04:20', coding => '05:30' },
	{ rows => \@rows, self => $self, device_kind => 'mobile', chosen => '', setter => $three_setter },
);
ok(!$phone_local->{'ok'}, 'a phone cannot save times for itself');
like($phone_local->{'error'} || '', qr/computer or server/i, 'the refusal names the eligible kinds');
is_deeply(\%three, $before, 'a refused save wrote nothing');

my $phone_target = subs::qa_times_save(
	{ suite => '03:10', ux => '04:20', coding => '05:30' },
	{ rows => \@rows, self => $self, device_kind => 'computer', chosen => 'c' x 24, signatorial => 'c' x 24, setter => $three_setter },
);
ok(!$phone_target->{'ok'}, 'a phone on the roster cannot be retimed');
is_deeply(\%three, $before, 'and nothing was written for it');

my $wrong_machine = subs::qa_times_save(
	{ suite => '03:10', ux => '04:20', coding => '05:30' },
	{ rows => \@rows, self => $self, device_kind => 'computer', chosen => 'b' x 24, signatorial => 'a' x 24, setter => $three_setter },
);
ok(!$wrong_machine->{'ok'}, 'a machine that is not the chosen one is refused');
is_deeply(\%three, $before, 'a wrong-machine save wrote nothing');

my $here_not_chosen = subs::qa_times_save(
	{ suite => '03:10', ux => '04:20', coding => '05:30' },
	{ rows => \@rows, self => $self, device_kind => 'computer', chosen => 'b' x 24, signatorial => '', setter => $three_setter },
);
ok(!$here_not_chosen->{'ok'}, 'a machine the nightly does not belong to cannot retime itself');
is_deeply(\%three, $before, 'and wrote nothing');

my $chosen_remote = subs::qa_times_save(
	{ suite => '03:10', ux => '04:20', coding => '05:30' },
	{ rows => \@rows, self => $self, device_kind => 'mobile', chosen => 'b' x 24, signatorial => 'b' x 24, setter => $three_setter },
);
ok($chosen_remote->{'ok'}, 'a phone may save times for the chosen server (the server does the work)');
ok(!$chosen_remote->{'local'}, 'the chosen server is a remote target');
is($chosen_remote->{'target'}->{'uuid'}, 'u-table', 'the target row is the one to send the rail command to');

my $off_times = subs::qa_times_save(
	{ suite => '03:10', ux => '04:20', coding => '05:30' },
	{ rows => \@rows, self => $self, device_kind => 'computer', chosen => 'none', setter => $three_setter },
);
ok(!$off_times->{'ok'}, 'times cannot be retimed while the nightly is off');
like($off_times->{'error'} || '', qr/nightly system is off/i, 'the refusal says the nightly is off');
is_deeply(\%three, $before, 'an off save wrote nothing');

# --- the drop-in -------------------------------------------------------------
my $suite_run = subs::qa_run_lookup('suite');
my $ux_run    = subs::qa_run_lookup('ux');
is(subs::qa_dropin_file($suite_run), '/etc/systemd/system/jawnos-qa.timer.d/50-jawn-schedule.conf',
	'the drop-in sits beside the timer unit');
my $suite_body = subs::qa_dropin_body($suite_run, '3:05');
like($suite_body, qr/^\[Timer\]$/m, 'the drop-in is a timer drop-in');
like($suite_body, qr/^OnCalendar=\*-\*-\* 03:05:00$/m, 'OnCalendar carries the saved time');
like($suite_body, qr/^RandomizedDelaySec=5m$/m, 'the suite keeps a small randomized delay');
my $ux_body = subs::qa_dropin_body($ux_run, '04:20');
like($ux_body, qr/^OnCalendar=\*-\*-\* 04:20:00$/m, 'the UX drop-in carries its time');
unlike($ux_body, qr/RandomizedDelaySec/, 'only the suite gets a randomized delay');
is(subs::qa_dropin_body($suite_run, '99:99'), '', 'no drop-in is written for an invalid time');

# --- retime: dry run, per-unit outcomes, a real failure ----------------------
my $dry = subs::qa_retime_local({ times => { suite => '03:05', ux => '04:20', coding => '05:30' }, dry_run => 1 });
ok($dry->{'ok'}, 'a dry retime answers');
ok($dry->{'dry_run'}, 'a dry retime says so');
is(scalar @{ $dry->{'rows'} || [] }, 3, 'all three units are reported');
is_deeply([ map { $_->{'state'} } @{ $dry->{'rows'} } ], [ 'planned', 'planned', 'planned' ],
	'a dry retime plans each timer and starts nothing');
like(join('', map { $_->{'body'} } @{ $dry->{'rows'} }), qr/OnCalendar=\*-\*-\* 03:05:00/,
	'the planned drop-in carries the time');

my @calls;
my $ok_runner = sub {
	push @calls, [@_];
	my $cmd = join(' ', @_);
	return (0, '') if $cmd =~ /^sudo -n install /;
	return (0, '') if $cmd =~ /^sudo -n systemctl daemon-reload$/;
	return (0, '') if $cmd =~ /^sudo -n systemctl restart jawnos-qa\.timer$/;
	return (0, '') if $cmd =~ /^sudo -n systemctl restart jawnos-qa-coding\.timer$/;
	return (5, 'Unit jawnos-qa-ux.timer not found.');
};
my $real = subs::qa_retime_local({
	times => { suite => '03:05', ux => '04:20', coding => '05:30' },
	runner => $ok_runner,
});
ok($real->{'ok'}, 'a retime with one missing timer is not a failure');
my %by_unit = map { $_->{'unit'} => $_ } @{ $real->{'rows'} };
is($by_unit{'jawnos-qa'}->{'state'}, 'retimed', 'the suite timer is retimed');
is($by_unit{'jawnos-qa-ux'}->{'state'}, 'not-installed', 'a timer that is not installed is named');
is($by_unit{'jawnos-qa-ux'}->{'ok'}, 1, 'an uninstalled timer is not counted as a failure');
like(join("\n", map { join(' ', @{$_}) } @calls), qr/sudo -n systemctl daemon-reload/,
	'systemd is reloaded once the drop-ins are in place');
like(join("\n", map { join(' ', @{$_}) } @calls), qr{/etc/systemd/system/jawnos-qa\.timer\.d/50-jawn-schedule\.conf},
	'the install command writes the drop-in path');

my $fail_runner = sub {
	my $cmd = join(' ', @_);
	return (1, 'sudo: a password is required') if $cmd =~ /^sudo -n install /;
	return (0, '');
};
my $failed = subs::qa_retime_local({
	times => { suite => '03:05', ux => '04:20', coding => '05:30' },
	runner => $fail_runner,
});
ok(!$failed->{'ok'}, 'a retime that cannot write the drop-in fails');
is($failed->{'rows'}->[0]->{'state'}, 'failed', 'the unit that failed says so');
like($failed->{'rows'}->[0]->{'error'}, qr/password is required/i, 'the error is the one systemctl/sudo gave');

my $reload_runner = sub {
	my $cmd = join(' ', @_);
	return (1, 'daemon-reload failed') if $cmd =~ /daemon-reload/;
	return (0, '');
};
my $reload_failed = subs::qa_retime_local({
	times => { suite => '03:05', ux => '04:20', coding => '05:30' },
	runner => $reload_runner,
});
ok(!$reload_failed->{'ok'}, 'a failed daemon-reload is a failure');
like($reload_failed->{'rows'}->[0]->{'error'}, qr/daemon-reload failed/, 'and it is what the panel is told');

# --- the schedule the timer really holds -------------------------------------
my %calendar = (
	'jawnos-qa.timer'        => '{ OnCalendar=*-*-* 05:00:00 ; next_elapse=Mon 2026-11-02 05:00:00 EST }',
	'jawnos-qa-ux.timer'     => '{ OnCalendar=*-*-* 04:20:00 ; next_elapse=Mon 2026-11-02 04:20:00 EST }',
	'jawnos-qa-coding.timer' => '{ OnCalendar=*-*-* 06:00:00 ; next_elapse=Mon 2026-11-02 06:00:00 EST }',
);
my $sched_runner = sub {
	my $cmd = join(' ', @_);
	if ($cmd =~ /TimersCalendar (\S+\.timer)/) { return (0, $calendar{$1} // '') }
	return (0, "ActiveState=inactive\nSubState=dead\n") if $cmd =~ /ActiveState/;
	return (1, '');
};
my $sched = subs::qa_schedule_local({
	runner => $sched_runner,
	grabber => sub {
		my ($setting) = @_;
		return '05:00' if $setting eq 'qa_night_time' || $setting eq 'qa_ux_time';
		return '06:00';
	},
	state_file => File::Spec->catfile(tempdir(CLEANUP => 1), 'qa_runs.json'),
	repo => '/nonexistent-qa-repo',
});
ok($sched->{'ok'}, 'the schedule answers');
my %srun = map { $_->{'key'} => $_ } @{ $sched->{'runs'} };
is($srun{'suite'}->{'oncalendar'}, '05:00', 'the suite schedule is read from systemd');
is($srun{'suite'}->{'source'}, 'systemd', 'systemd is the source when it answers');
is($srun{'suite'}->{'drift'}, 0, 'a field that matches the timer is not a drift');
is($srun{'ux'}->{'oncalendar'}, '04:20', 'a retimed UX timer is reported');
is($srun{'ux'}->{'drift'}, 1, 'a field that disagrees with the timer is a drift');
is($srun{'ux'}->{'time'}, '05:00', 'the field keeps the saved setting');
is($srun{'coding'}->{'oncalendar'}, '06:00', 'the coding timer is reported too');
is(subs::qa_oncalendar_time('{ OnCalendar=Mon *-*-* 00:00:00 ; next_elapse=x }'), '00:00',
	'a weekday OnCalendar parses to its time');
is(subs::qa_oncalendar_time('nonsense'), '', 'unparseable text is empty, not a guess');

# The fallback when systemd has no answer: the drop-in, then the shipped unit.
my $tmp_unit = File::Spec->catfile(tempdir(CLEANUP => 1), 'jawnos-qa.timer');
open(my $ufh, '>', $tmp_unit) or die $!;
print $ufh "[Timer]\nOnCalendar=*-*-* 07:15:00\nPersistent=true\n";
close $ufh;
is(subs::qa_file_oncalendar($tmp_unit), '07:15', 'a unit file is a readable fallback');
is(subs::qa_file_oncalendar('/nonexistent/qa.timer'), '', 'a missing file is empty, not a crash');

# --- Run now: the double-start guard -----------------------------------------
my $tmp = tempdir(CLEANUP => 1);
my $state_file = File::Spec->catfile($tmp, 'qa_runs.json');
my %mode = (active => 0, start => 0);
my @starts;
my $run_runner = sub {
	my $cmd = join(' ', @_);
	if ($cmd =~ /systemctl is-active (\S+\.service)/) {
		return (0, "active\n") if $mode{'active'};
		return (3, "inactive\n");
	}
	if ($cmd =~ /systemctl start --no-block (\S+\.service)/) {
		push @starts, $1;
		return ($mode{'start'}, $mode{'start'} ? 'start failed' : '');
	}
	return (1, 'unexpected');
};

my $planned = subs::qa_run_now_local('suite', { runner => $run_runner, state_file => $state_file, now => 1_000_000, cooldown => 30, dry_run => 1 });
ok($planned->{'ok'}, 'a dry Run now plans');
is($planned->{'state'}, 'planned', 'a dry Run now starts nothing');
is(scalar @starts, 0, 'and ran no systemctl start');

$mode{'start'} = 0;
my $started = subs::qa_run_now_local('suite', { runner => $run_runner, state_file => $state_file, now => 1_000_000, cooldown => 30 });
ok($started->{'ok'}, 'Run now starts the suite');
is($started->{'state'}, 'running', 'the job state says running');
is_deeply(\@starts, ['jawnos-qa.service'], 'the suite service was started');
ok(-e $state_file, 'the start is recorded for the poll and the cooldown');

my $twice = subs::qa_run_now_local('suite', { runner => $run_runner, state_file => $state_file, now => 1_010_000, cooldown => 30 });
ok(!$twice->{'ok'}, 'a second press inside the cooldown is refused');
is(scalar @starts, 1, 'and starts nothing');

$mode{'active'} = 1;
my $active = subs::qa_run_now_local('suite', { runner => $run_runner, state_file => $state_file, now => 2_000_000, cooldown => 30 });
ok(!$active->{'ok'}, 'a run that is already going is refused');
like($active->{'error'} || '', qr/already running/i, 'the refusal says it is already running');
$mode{'active'} = 0;

my $later = subs::qa_run_now_local('ux', { runner => $run_runner, state_file => $state_file, now => 2_000_000, cooldown => 30 });
ok($later->{'ok'}, 'a different run is not blocked by the suite');

$mode{'start'} = 1;
my $start_failed = subs::qa_run_now_local('coding', { runner => $run_runner, state_file => $state_file, now => 2_100_000, cooldown => 30 });
ok(!$start_failed->{'ok'}, 'a start that systemctl refuses is a failure');
like($start_failed->{'error'} || '', qr/start failed/i, 'the failure carries systemctl\'s answer');

ok(!subs::qa_run_now_local('bogus', { runner => $run_runner })->{'ok'}, 'an unknown run is refused');

# --- the guard the run and the save share ------------------------------------
my $run_here_not_chosen = subs::qa_run_guard('', { rows => \@rows, self => $self, device_kind => 'computer', chosen => 'b' x 24 });
ok(!$run_here_not_chosen->{'ok'}, 'Run now refuses a machine that is not the chosen one');
my $run_phone = subs::qa_run_guard('', { rows => \@rows, self => $self, device_kind => 'mobile', chosen => '' });
ok(!$run_phone->{'ok'}, 'Run now refuses a phone');
my $run_chosen = subs::qa_run_guard('b' x 24, { rows => \@rows, self => $self, device_kind => 'mobile', chosen => 'b' x 24 });
ok($run_chosen->{'ok'} && !$run_chosen->{'target'}->{'local'}, 'Run now accepts the chosen server');
my $run_unknown = subs::qa_run_guard('9' x 24, { rows => \@rows, self => $self, chosen => '9' x 24 });
ok(!$run_unknown->{'ok'}, 'Run now refuses a machine that is not on the roster');
my $run_off = subs::qa_run_guard('', { rows => \@rows, self => $self, device_kind => 'computer', chosen => 'none' });
ok(!$run_off->{'ok'}, 'Run now refuses while the nightly is off');
like($run_off->{'error'} || '', qr/nightly system is off/i, 'the refusal names the off state');

# --- the fenced copy agrees ---------------------------------------------------
require "$root/qa/lib/QaSetting.pm";
foreach my $sample ( '05:00', ' 5:07 ', '23:59', '24:00', '9:5', 'five', '' ) {
	is(QaSetting::clamp_time($sample), subs::qa_time_clean($sample),
		"QaSetting and the app agree on '$sample'");
}
is(QaSetting::night_time_default('qa_night_time'), '05:00', 'the suite default is 05:00');
is(QaSetting::night_time_default('qa_ux_time'), '05:30', 'the UX default is 05:30');
is(QaSetting::night_time_default('qa_coding_time'), '06:00', 'the coding default is 06:00');

my $sqlite3 = `command -v sqlite3 2>/dev/null`;
chomp $sqlite3 if defined $sqlite3;
if ($sqlite3 && length $sqlite3) {
	require DBI;
	my $sandbox = tempdir(CLEANUP => 1);
	my $db = "$sandbox/jawnos.db";
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
	$dbh->do("create table settings (app text, setting text, device text, value text, server_time text)");
	$dbh->do("insert into settings (app, setting, device, value, server_time) values (?,?,?,?,?)",
		undef, '__president', 'qa_night_time', 'all', '02:45', '1000');
	$dbh->do("insert into settings (app, setting, device, value, server_time) values (?,?,?,?,?)",
		undef, '__president', 'qa_ux_time', 'all', 'half past', '1000');
	$dbh->do("insert into settings (app, setting, device, value, server_time) values (?,?,?,?,?)",
		undef, '__president', 'qa_ux_model', 'all', 'deepseek:deepseek-flash', '1000');
	# A per-device row must not take the house choice over, the same order the
	# other QA settings use.
	$dbh->do("insert into settings (app, setting, device, value, server_time) values (?,?,?,?,?)",
		undef, '__president', 'qa_ux_model', 'computer', 'deepseek:deepseek-v4-pro', '2000');
	$dbh->disconnect;
	is(QaSetting::read_night_time($db, 'qa_night_time'), '02:45', 'a stored time reads back from the fenced copy');
	is(QaSetting::read_night_time($db, 'qa_ux_time'), '05:30', 'a garbage row reads as the default');
	is(QaSetting::read_ux_model($db), 'deepseek:deepseek-flash',
		'the UX model reads back from the fenced copy, house row first');
}
else {
	pass('sqlite3 is not installed; the fenced read is skipped');
}

# --- the panel, the script, the routes, the rail -----------------------------
like(read_file("$root/qa/ux/run"), qr/read_ux_model/,
	'the UX runner takes its model from the QA setting when --model is absent');
my $panel = read_file("$root/templates/configure/qa_panel.html.ep");
like($panel, qr/id="qa_suite_time"/, 'the panel carries the suite time field');
like($panel, qr/id="qa_ux_time"/, 'the panel carries the UX time field');
like($panel, qr/id="qa_coding_time"/, 'the panel carries the coding time field');
like($panel, qr/id="qa_schedule_save"/, 'the panel carries the save trigger');
like($panel, qr/data-run="suite"/, 'the panel carries a Run now for the suite');
like($panel, qr/data-run="ux"/, 'the panel carries a Run now for the UX run');
like($panel, qr/data-run="coding"/, 'the panel carries a Run now for the coding night');
like($panel, qr/qa_times_read\(\)/, 'the fields are rendered from the saved times');
like($panel, qr/configure\.qa_schedule/, 'the card title is a core language key');
like($panel, qr/value="none"/, 'the machine picker offers Off');
like($panel, qr/configure\.qa_off/, 'the Off option is a core language key');
my $plat = read_file("$root/templates/configure/plat_setting_list.html.ep");
like($plat, qr/<select[^>]*id="qa_ux_model"/, 'the AI tab carries the UX model dropdown');
like($plat, qr/configure\.qa_ux_model/, 'the model label is a core language key');
like($plat, qr/optgroup/, 'the dropdown groups eligible models by provider');
unlike($panel, qr/id="qa_ux_model"/, 'the QA Nightly tab no longer carries it');
like($panel, qr/50-jawn-schedule\.conf/, 'the panel explains the drop-in');

my $js = read_file("$root/public/js/manager/configure/07_qa_nightly.js");
like($js, qr{/manager/configure/qa_schedule'}, 'the script reads the schedule');
like($js, qr{/manager/configure/qa_schedule_save}, 'the script posts the times');
like($js, qr{/manager/configure/qa_run'}, 'the script posts Run now');
like($js, qr/'#qa_schedule_save'/, 'the save button is wired');
like($js, qr/\.qa_run_now/, 'the Run now buttons are wired');
like($js, qr/qaRunPollStart/, 'the script polls the job state');
like($js, qr/function qaApplyOff/, 'the script knows how to stand the controls down');
like($js, qr/if \(r\.off\)/, 'the script renders the off state');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure2.pm");
like($controller, qr/qa_times_save\(/, 'the save route validates server-side');
like($controller, qr/qa_retime_local\(/, 'the save route retimes locally');
like($controller, qr/verb => 'qa_retime'/, 'a remote target is retimed over the signed rail');
like($controller, qr/qa_run_guard\(/, 'Run now guards the target');
like($controller, qr/qa_run_now_local\(/, 'Run now starts the run locally');
like($controller, qr/verb => 'qa_run_now'/, 'a remote Run now uses the signed rail');
like($controller, qr/qa_schedule_for\(/, 'the schedule route asks the chosen machine');
like($controller, qr/field.*ux_model/s, 'the target route saves the UX model field');

my $routes = read_file("$root/lib/JawnOS/Routes/manager_configure2.pm");
like($routes, qr{'/manager/configure/qa_schedule', 'action_50004'}, 'the schedule route is registered');
like($routes, qr{'/manager/configure/qa_schedule_save', 'action_50005'}, 'the save route is registered');
like($routes, qr{'/manager/configure/qa_run', 'action_50006'}, 'the run route is registered');
my @actions = ( $controller =~ /sub (action_5000[456])/g );
is_deeply(\@actions, [ 'action_50004', 'action_50005', 'action_50006' ], 'each route has its action');

my $rail = read_file("$root/lib/JawnOS/Manager/Part28.pm");
like($rail, qr/qa_retime/, 'the remote-command rail accepts the retime verb');
like($rail, qr/qa_run_now/, 'the remote-command rail accepts the run verb');
like($rail, qr/chosen nightly device/, 'the far end re-checks the house choice');
like($rail, qr/nightly system is off/, 'the far end refuses to install, retime or run while off');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Remote.*qa_retime_local/, 'the loader maps the retime helpers');
like($loader, qr/JawnOS::Domain::Remote.*qa_run_now_local/, 'the loader maps the run helper');
like($loader, qr/JawnOS::Domain::Remote.*qa_ux_model_save/, 'the loader maps the UX model helper');

my $help = read_file("$root/perl/help/topics_configure.pl");
like($help, qr/Nightly schedule/, 'the Configure help topic explains the schedule');
like($help, qr/Run now/, 'and the Run now trigger');
like($help, qr/UX judgement model/, 'and the UX model field');

{
	no warnings 'once';
	require "$root/perl/language.pl";
	my @codes = map { $_->{'code'} } @language::languages;
	is(scalar(@codes), 16, 'all sixteen interface languages are listed');
	foreach my $key (qw(configure.qa_schedule configure.qa_suite_time configure.qa_ux_time
		configure.qa_coding_time configure.qa_save_times configure.qa_run_now configure.qa_effective
		configure.qa_off configure.qa_ux_model)) {
		for my $code (@codes) {
			my $label = language::translate($code, $key);
			ok(defined $label && length $label && $label ne $key, "$code has $key");
		}
	}
}

done_testing();
