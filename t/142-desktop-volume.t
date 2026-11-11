# tests-for: lib/JawnOS/Domain/Pay2.pm lib/JawnOS/Domain/Clock.pm lib/JawnOS/Domain/Clock2.pm lib/JawnOS/Domain/Clock3.pm lib/JawnOS/Controller/manager_clock.pm templates/apps/clock/body.html.ep templates/apps/clock/machine.html.ep templates/apps/clock/sessions.html.ep public/js/manager/clock/01_alarms_timers.js
# covers:    A computer alarm moves the machine's own output volume and puts it back; a timer carries its own Volume...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use JawnOSTest;

# The phone sets STREAM_ALARM and restores it in the app; a computer has no
# such stream, so the sink itself is moved with pactl, wpctl or amixer. These
# tests use a fake pactl, so they assert the parsing, the restore point and the
# timer's Volume without touching the machine's real sound.
my $tmp = tempdir(CLEANUP => 1);
my $bin = "$tmp/bin";
make_path($bin);
my $log = "$tmp/pactl.log";
my $pactl = "$bin/pactl";
write_file($pactl, <<'SH');
#!/bin/sh
case "$1" in
	info) echo "Server Name: test"; exit 0 ;;
	get-sink-volume) echo "Volume: front-left: 32768 /  40% / -23.88 dB,   front-right: 32768 /  40% / -23.88 dB"; exit 0 ;;
	set-sink-volume) echo "$3" >> "$PACTL_LOG"; exit 0 ;;
esac
exit 1;
SH
chmod 0755, $pactl;

{
	local $ENV{'PATH'} = "$bin:$ENV{'PATH'}";
	local $ENV{'PACTL_LOG'} = $log;
	local $subs::home_dir = $tmp;
	local $subs::clock_volume_backend;

	is(subs::clock_system_volume_get(), 40, 'pactl reports the current 40% sink level');
	write_file($log, '');
	is(subs::clock_system_volume_set(55), 1, 'the sink can be set');
	is(read_file($log), "55%\n", 'pactl received the chosen level');

	write_file($log, '');
	my $alarm = { uuid => 'ring-test', volume => 25 };
	is(subs::clock_alarm_volume_raise($alarm), 1, 'the alarm moves the sink');
	is(read_file($log), "25%\n", 'the sink is at the alarm volume (25%)');
	ok(-e subs::clock_alarm_volume_file('ring-test'), 'the previous level is written down');
	is(subs::clock_alarm_volume_saved('ring-test'), 1, 'the ring knows a restore point exists');

	write_file($log, '');
	is(subs::clock_alarm_stop_sound('ring-test'), 1, 'Dismiss restores even with no player pid');
	is(read_file($log), "40%\n", 'the previous 40% came back');
	ok(!-e subs::clock_alarm_volume_file('ring-test'), 'the restore point is cleared');

	# The sox player must not apply the percentage a second time when the sink
	# already carries it.
	is(subs::clock_alarm_volume_at({ volume => 40, ramp => 0 }, 0, 0), '0.40',
		'without a sink move the player scales to the alarm volume');
	is(subs::clock_alarm_volume_at({ volume => 40, ramp => 0 }, 0, 1), '1.00',
		'with the sink moved the player is full and only the ramp remains');
}

# The launcher's alarm channel multiplies the player's level. With no setting
# row the gain is 1, which is why the assertions above still expect the same
# numbers; these pin the multiplication and the eval-wrapped default.
{
	no warnings 'redefine';
	local *subs::sound_channel_gain = sub { 0.5 };
	is(subs::clock_alarm_volume_at({ volume => 40, ramp => 0 }, 0, 0), '0.20',
		'the alarm channel scales the chime level');
	like(subs::clock_alarm_play_command({ uuid => 'gain-short', volume => 40,
		sound => 'notifications/chime.mp3' }, 0, 0),
		qr/^play -q -v 0\.20 /, 'and the short ring the player runs');
	like(subs::clock_alarm_play_command({ uuid => 'gain-long', volume => 40, ramp => 5,
		sound => 'alarms/find-the-ship-learn-from-it.mp3' }, 0, 0),
		qr/^play -q -v 0\.20 .* fade t 5 repeat 1000 & echo \$! > /,
		'and the long-form track at the same gain');
}
{
	no warnings 'redefine';
	local *subs::sound_channel_gain = sub { die "no database\n" };
	is(subs::clock_alarm_volume_at({ volume => 40, ramp => 0 }, 0, 0), '0.40',
		'a channel that cannot be read keeps today\'s level');
}

# --- the timer's own Volume ---------------------------------------------------
my $timer = subs::clock_normalize_timer({ seconds => 60, volume => 250 });
is($timer->{'volume'}, 100, 'a timer volume is clamped to 100');
$timer = subs::clock_normalize_timer({ seconds => 60 });
is($timer->{'volume'}, 70, 'a timer without one uses the old 70%');

{
	no warnings 'redefine';
	my $sent;
	local *subs::clock_device_broadcast = sub {
		my ($action, %args) = @_;
		$sent = { action => $action, %args };
		return 1;
	};
	subs::clock_device_timer({ uuid => 'timer-test', label => 'Tea', volume => 35,
		ends_at => 1_000, sound => 'notifications/chime.mp3' });
	is($sent->{'volume'}, 35, 'the timer ring carries its own Volume to the phone');
}

# --- the wiring that makes those helpers reach the ring and the creator ------
my $root = root();
my $clock = read_file("$root/lib/JawnOS/Domain/Clock.pm");
my $clock2 = read_file("$root/lib/JawnOS/Domain/Clock2.pm");
my $clock3 = read_file("$root/lib/JawnOS/Domain/Clock3.pm");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_clock.pm");
my $body = read_file("$root/templates/apps/clock/body.html.ep");
my $timer_js = read_file("$root/public/js/manager/clock/01_alarms_timers.js");

like($clock, qr/sound_channel_gain\('alarm'\)/,
	'the alarm player reads the launcher alarm channel');
like($clock2, qr/clock_alarm_volume_raise\(\$alarm\)/,
	'the ringing machine raises the computer sink');
like($clock2, qr/clock_alarm_play_command\(\$alarm, 0, \$system_volume\)/,
	'the sox command knows the sink already carries the level');
like($clock3, qr/push \@actions, \[ 'stop_sound', \$uuid \];/,
	'the guard restores the sink for a chime as well as a long track');
like($controller, qr/volume => \$c->param\('volume'\)/,
	'the timer route stores the creator\'s Volume');
like($body, qr/class="clock_timer_volume"/,
	'the timer creator has a Volume slider');
like($timer_js, qr/volume: volume/,
	'the timer creator sends its Volume');


like($body, qr/data-clock-tab="machine"/, 'the Clock has a time-machine tab');
like($body, qr/data-clock-tab="sessions"/, 'and a sessions tab');
like($controller, qr/accounts => \$accts/, 'the Clock action supplies the time-machine accounts');
like($controller, qr/projects => \$projs/, 'and projects');

done_testing();
