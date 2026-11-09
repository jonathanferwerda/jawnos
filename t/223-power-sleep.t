# tests-for: lib/JawnOS/Domain/Power.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_power.pm lib/JawnOS/Routes/manager_power.pm scripts/jawnos_power.pl templates/apps/power.html.ep public/js/manager/power.js perl/help/topics_apps.pl
# covers:    The Power app's sleep and display block: the two timeouts, the
#            lid action shown only on a machine with a lid, the sleep states
#            the machine reports, the logind drop-in bytes, and the fixed
#            settings/sleep helper commands.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::JSON qw(decode_json);
use Symbol qw(gensym);
use RepoSource;

my $root = repo_root();
my $scratch = tempdir(CLEANUP => 1);
my $sys = tempdir(CLEANUP => 1);
my $proc = tempdir(CLEANUP => 1);
my $bin = tempdir(CLEANUP => 1);
my $bin_screen = tempdir(CLEANUP => 1);
my $log = "$scratch/commands.log";

# A fake Linux machine: one battery, one lid, and a kernel that offers suspend,
# hibernate and both hybrids. The PATH holds only a fake systemctl, so the
# screen timer is honestly unsupported until a second PATH adds gsettings.
make_path(
	"$sys/power",
	"$sys/class/power_supply/BAT0",
	"$proc/acpi/button/lid/LID0",
);
write_file("$sys/power/state", "freeze mem disk\n");
write_file("$sys/class/power_supply/BAT0/type", "Battery\n");
write_file("$sys/class/power_supply/BAT0/capacity", "50\n");
write_file("$sys/class/power_supply/BAT0/status", "Discharging\n");
write_file("$proc/acpi/button/lid/LID0/state", "state:      open\n");

sub fake_command {
	my ($dir, $name) = @_;
	my $path = "$dir/$name";
	write_file($path, "#!/bin/sh\nprintf '%s|%s\\n' '$name' \"\$*\" >> '$log'\nexit 0\n");
	chmod 0755, $path;
	return $path;
}
fake_command($bin, 'systemctl');
my $systemctl = fake_command($bin_screen, 'systemctl');
my $gsettings = fake_command($bin_screen, 'gsettings');

local $ENV{'JAWNOS_POWER_SYSFS'} = $sys;
local $ENV{'JAWNOS_POWER_PROC'} = $proc;
local $ENV{'JAWNOS_POWER_CONFIG_FILE'} = "$scratch/config.json";
local $ENV{'JAWNOS_POWER_STATE_FILE'} = "$scratch/state.json";
local $ENV{'JAWNOS_POWER_HELPER'} = "$root/scripts/jawnos_power.pl";
local $ENV{'JAWNOS_POWER_DRY_RUN'} = '';
local $ENV{'JAWNOS_POWER_ETC'} = "$scratch/etc";
local $ENV{'PATH'} = $bin;
local $ENV{'DISPLAY'} = '';
local $ENV{'SUDO_USER'} = '';

require "$root/lib/JawnOS/Domain/Power.pm";

no warnings 'redefine';
*subs::device_setter = sub { 'computer' };
*subs::rightNow = sub { 1_790_000_000_000 };

# --- the saved block and its validation ------------------------------------
{
	my $config = subs::power_config();
	is($config->{'sleep'}{'screen_timeout'}, 0, 'the screen timer defaults to Never');
	is($config->{'sleep'}{'sleep_timeout'}, 0, 'the sleep timer defaults to Never');
	is($config->{'sleep'}{'lid_action'}, 'suspend', 'the lid action defaults to Suspend');
	is($config->{'sleep'}{'sleep_type'}, 'suspend', 'the sleep type defaults to Suspend');

	my $clean = subs::power_config_clean({
		ac => { plan => 'performance', limit => 90 },
		battery => { plan => 'saver', limit => 60 },
		sleep => { screen_timeout => 5, sleep_timeout => 60, lid_action => 'hibernate', sleep_type => 'hibernate' },
	});
	is($clean->{'sleep'}{'screen_timeout'}, 5, 'a valid screen timeout is kept');
	is($clean->{'sleep'}{'sleep_timeout'}, 60, 'a valid sleep timeout is kept');
	is($clean->{'sleep'}{'lid_action'}, 'hibernate', 'a valid lid action is kept');
	is($clean->{'sleep'}{'sleep_type'}, 'hibernate', 'a valid sleep type is kept');
	is($clean->{'ac'}{'plan'}, 'performance', 'the mains plan survives a sleep edit');
	is($clean->{'battery'}{'limit'}, 60, 'the battery limit survives a sleep edit');

	my $bad = subs::power_config_clean({
		sleep => { screen_timeout => 7, sleep_timeout => 3, lid_action => 'explode', sleep_type => 'teleport' },
	});
	is($bad->{'sleep'}{'screen_timeout'}, 0, 'an unknown screen timeout falls back to Never');
	is($bad->{'sleep'}{'sleep_timeout'}, 0, 'an unknown sleep timeout falls back to Never');
	is($bad->{'sleep'}{'lid_action'}, 'suspend', 'an unknown lid action falls back');
	is($bad->{'sleep'}{'sleep_type'}, 'suspend', 'an unknown sleep type falls back');
}

# --- what the machine reports ----------------------------------------------
{
	my $caps = subs::power_sleep_capabilities();
	is($caps->{'lid'}, 1, 'the lid state file makes this a machine with a lid');
	is_deeply($caps->{'types'}, [qw(suspend hibernate hybrid_sleep suspend_then_hibernate)],
		'mem and disk offer every sleep state');
	is($caps->{'systemd'}, 1, 'the fake systemctl is found');
	is($caps->{'screen'}{'supported'}, 0, 'no gsettings or xset is honestly unsupported');
	like($caps->{'screen'}{'reason'}, qr/gsettings|xset/, 'and says why');

	{
		local $ENV{'JAWNOS_POWER_PROC'} = tempdir(CLEANUP => 1);
		is(subs::power_sleep_capabilities()->{'lid'}, 0, 'a machine with no lid state file has no lid');
	}
	{
		local $ENV{'PATH'} = $bin_screen;
		my $screen = subs::power_sleep_capabilities()->{'screen'};
		is($screen->{'supported'}, 1, 'gsettings makes the screen timer supported');
		is($screen->{'method'}, 'gsettings', 'and names the method');
	}

	write_file("$sys/power/state", "freeze mem\n");
	is_deeply([subs::power_supported_sleep_types()], ['suspend'], 'without disk only suspend is offered');
	write_file("$sys/power/state", "disk\n");
	is_deeply([subs::power_supported_sleep_types()], ['hibernate'], 'disk alone offers hibernate');
	write_file("$sys/power/state", "freeze mem disk\n");
	{
		local $ENV{'PATH'} = tempdir(CLEANUP => 1);
		is_deeply([subs::power_supported_sleep_types()], [], 'without systemctl no state is offered');
	}
}

# --- saving refuses what the machine cannot do -----------------------------
{
	local $ENV{'JAWNOS_POWER_DRY_RUN'} = 1;
	my $saved = subs::power_sleep_set({
		screen_timeout => 10,
		sleep_timeout => 15,
		lid_action => 'hibernate',
		sleep_type => 'hibernate',
	});
	ok($saved->{'ok'}, 'a supported block is saved');
	ok($saved->{'applied'}{'dry_run'}, 'the dry run does not write the machine');
	is_deeply($saved->{'applied'}{'command'},
		[$^X, "$root/scripts/jawnos_power.pl", 'settings', 10, 15, 'hibernate', 'hibernate'],
		'the fixed settings command carries the four values');
	my $stored = decode_json(read_file("$scratch/config.json"));
	is($stored->{'sleep'}{'screen_timeout'}, 10, 'the screen timeout is persisted');
	is($stored->{'sleep'}{'sleep_timeout'}, 15, 'the sleep timeout is persisted');
	is($stored->{'sleep'}{'lid_action'}, 'hibernate', 'the lid action is persisted');
	is($stored->{'sleep'}{'sleep_type'}, 'hibernate', 'the sleep type is persisted');
	is($stored->{'battery'}{'plan'}, 'saver', 'the old plan config is still there');

	write_file("$sys/power/state", "freeze mem\n");
	my $refused = subs::power_sleep_set({ sleep_type => 'hibernate' });
	is($refused->{'ok'}, 0, 'a hibernate the machine cannot do is refused');
	is($refused->{'supported'}, 0, 'and is reported unsupported');
	my $bad_value = subs::power_sleep_set({ screen_timeout => 7 });
	is($bad_value->{'ok'}, 0, 'a value outside the whitelist is refused');
	write_file("$sys/power/state", "freeze mem disk\n");

	# No systemctl at all: the screen timer can still save, but the helper is
	# told not to wake logind for a sleep state this machine cannot enter.
	{
		local $ENV{'PATH'} = tempdir(CLEANUP => 1);
		my $no_states = subs::power_sleep_set({ screen_timeout => 5 });
		ok($no_states->{'ok'}, 'a screen-only save works with no sleep states');
		is($no_states->{'sleep_ignored'}, 1, 'the sleep timer is reported ignored');
		is($no_states->{'applied'}{'command'}[4], 0, 'the helper is told the sleep timer is off');
	}

	my $now = subs::power_sleep_now('suspend');
	ok($now->{'dry_run'}, 'Sleep now is a dry run here');
	is_deeply($now->{'command'}, [$^X, "$root/scripts/jawnos_power.pl", 'sleep', 'suspend'],
		'the fixed sleep command carries one word');
	write_file("$sys/power/state", "freeze mem\n");
	my $no_hibernate = subs::power_sleep_now('hibernate');
	is($no_hibernate->{'supported'}, 0, 'Sleep now refuses an unsupported state');
	write_file("$sys/power/state", "freeze mem disk\n");
}

# --- the fixed helper ------------------------------------------------------
# Run the real helper. The drop-in goes to a temp ETC; gsettings and systemctl
# are fake scripts that log the argument list, so nothing real is touched.
sub helper {
	my (%want) = @_;
	my @args = @{ $want{'args'} || [] };
	local $ENV{'JAWNOS_POWER_SYSFS'} = $sys;
	local $ENV{'JAWNOS_POWER_DRY_RUN'} = $want{'dry'} ? 1 : '';
	local $ENV{'JAWNOS_POWER_ETC'} = $want{'etc'} || "$scratch/etc";
	local $ENV{'PATH'} = $want{'path'} || $bin;
	local $ENV{'DISPLAY'} = $want{'display'} || '';
	local $ENV{'SUDO_USER'} = $want{'sudo_user'} || '';
	my $script = "$root/scripts/jawnos_power.pl";
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	my $answer = eval { decode_json($stdout) };
	return $answer || { ok => 0, error => 'unreadable helper answer', stdout => $stdout, stderr => $stderr };
}

{
	write_file($log, '');
	my $etc = "$scratch/etc";
	my $settings = helper(path => $bin_screen, etc => $etc,
		args => ['settings', 5, 10, 'hibernate', 'hibernate']);
	ok($settings->{'ok'}, 'the settings are applied');
	my $path = "$etc/systemd/logind.conf.d/jawnos-power.conf";
	ok(-e $path, 'the logind drop-in is created in the logind.conf.d directory');
	is_deeply($settings->{'logind'}{'changed'}, 1, 'the first write changes the drop-in');
	my $bytes = read_file($path);
	like($bytes, qr/^\[Login\]$/m, 'the drop-in has a Login section');
	like($bytes, qr/^HandleLidSwitch=hibernate$/m, 'the lid action is written');
	like($bytes, qr/^HandleLidSwitchExternalPower=hibernate$/m, 'so is the external-power lid action');
	like($bytes, qr/^HandleLidSwitchDocked=ignore$/m, 'a docked lid is ignored');
	like($bytes, qr/^IdleAction=hibernate$/m, 'the idle action follows the sleep type');
	like($bytes, qr/^IdleActionSec=10min$/m, 'the idle timeout is in minutes');
	is($settings->{'screen'}{'supported'}, 1, 'gsettings is reported supported');
	is($settings->{'screen'}{'method'}, 'gsettings', 'and is the method used');
	is_deeply($settings->{'screen'}{'command'},
		[$gsettings, 'set', 'org.gnome.desktop.session', 'idle-delay', 300],
		'the screen delay is five minutes in seconds');
	like(read_file($log), qr/^gsettings\|set org\.gnome\.desktop\.session idle-delay 300$/m,
		'gsettings was actually run');

	my $again = helper(path => $bin_screen, etc => $etc,
		args => ['settings', 5, 10, 'hibernate', 'hibernate']);
	is($again->{'logind'}{'changed'}, 0, 'unchanged values do not rewrite the drop-in');

	my $never = helper(path => $bin_screen, etc => "$scratch/etc_never",
		args => ['settings', 0, 0, 'ignore', 'suspend']);
	my $never_bytes = read_file("$scratch/etc_never/systemd/logind.conf.d/jawnos-power.conf");
	like($never_bytes, qr/^IdleAction=ignore$/m, 'Never writes IdleAction=ignore');
	like($never_bytes, qr/^IdleActionSec=infinity$/m, 'and an infinite idle span');
	like($never_bytes, qr/^HandleLidSwitch=ignore$/m, 'Do nothing is ignore');

	my $no_screen = helper(path => $bin, etc => "$scratch/etc_noscreen",
		args => ['settings', 5, 10, 'suspend', 'suspend']);
	is($no_screen->{'ok'}, 1, 'the drop-in still applies without a screen tool');
	is($no_screen->{'screen'}{'supported'}, 0, 'the screen timer is reported unsupported');

	my $sudo_retry = helper(path => $bin_screen, etc => "$scratch/etc_sudo", sudo_user => 'jawn',
		args => ['settings', 5, 10, 'suspend', 'suspend']);
	is($sudo_retry->{'screen'}{'skipped'}, 1, 'a sudo retry does not touch the user screen again');

	my $bad_screen = helper(etc => "$scratch/etc_bad", args => ['settings', 7, 10, 'suspend', 'suspend']);
	is($bad_screen->{'ok'}, 0, 'an unknown screen timeout is refused by the helper');
	my $bad_lid = helper(etc => "$scratch/etc_bad", args => ['settings', 5, 10, 'explode', 'suspend']);
	is($bad_lid->{'ok'}, 0, 'an unknown lid action is refused by the helper');
}

# --- the sleep command -----------------------------------------------------
{
	write_file($log, '');
	my $sleep = helper(path => $bin_screen, args => ['sleep', 'hibernate']);
	ok($sleep->{'ok'}, 'hibernate is sent to systemctl');
	is($sleep->{'word'}, 'hibernate', 'the fixed word is named in the answer');
	is_deeply($sleep->{'command'}, [$systemctl, 'hibernate'], 'the argument list is one fixed word');
	like(read_file($log), qr/^systemctl\|hibernate$/m, 'systemctl was actually run');

	write_file($log, '');
	my $dry = helper(path => $bin_screen, dry => 1, args => ['sleep', 'suspend']);
	ok($dry->{'dry_run'}, 'a dry run reports without sleeping');
	is_deeply($dry->{'command'}, [$systemctl, 'suspend'], 'and carries the command');
	is(read_file($log), '', 'a dry run does not touch systemctl');

	my $bad = helper(path => $bin_screen, args => ['sleep', 'explode']);
	is($bad->{'ok'}, 0, 'an unknown sleep word is refused');
}

# --- the route, controller and loader --------------------------------------
{
	my $routes = read_file("$root/lib/JawnOS/Routes/manager_power.pm");
	like($routes, qr/\[\s*53015\s*,\s*'post'\s*,\s*'\/manager\/power\/sleep'\s*,\s*'action_53015'\s*\]/,
		'the sleep settings route and action are a pair');
	like($routes, qr/\[\s*53016\s*,\s*'post'\s*,\s*'\/manager\/power\/sleep_now'\s*,\s*'action_53016'\s*\]/,
		'the Sleep now route and action are a pair');

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_power.pm");
	like($controller, qr/^sub action_53015\b/m, 'the sleep settings action exists');
	like($controller, qr/^sub action_53016\b/m, 'the Sleep now action exists');
	like($controller, qr/&subs::power_sleep_set\(/, 'the sleep action calls the domain');
	like($controller, qr/&subs::power_sleep_now\(/, 'the Sleep now action calls the domain');

	my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_sleep_set\b/, 'the sleep save is loaded');
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_sleep_now\b/, 'the sleep now is loaded');
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_sleep_capabilities\b/, 'the capability read is loaded');
}

# --- the UI, the help topic and the translations ---------------------------
{
	my $template = read_file("$root/templates/apps/power.html.ep");
	like($template, qr/id="power_screen_timeout"/, 'the screen timeout has its select');
	like($template, qr/id="power_sleep_timeout"/, 'the sleep timeout has its select');
	like($template, qr/id="power_lid_row"/, 'the lid row exists');
	like($template, qr/id="power_lid_action"/, 'the lid action has its select');
	like($template, qr/id="power_sleep_type"/, 'the sleep type has its select');
	like($template, qr/id="power_sleep_now"/, 'the Sleep now button exists');
	like($template, qr/\$sleep_caps->\{'lid'\}/, 'the lid row is conditional on a lid');

	my $js = read_file("$root/public/js/manager/power.js");
	like($js, qr{\$\.post\('/manager/power/sleep'}, 'saving posts to the fixed sleep route');
	like($js, qr{\$\.post\('/manager/power/sleep_now'}, 'Sleep now posts to the fixed route');
	like($js, qr/powerSleepTypes\(/, 'the sleep type list is rebuilt from what the machine supports');
	like($js, qr/sleepCaps\.lid/, 'the lid row follows the capability read');
	like($js, qr/screen\.supported === 0/, 'an unsupported screen timer is never claimed');

	require "$root/perl/help.pl";
	my $topic = $help::topic{'power'};
	ok($topic, 'the help registry still has a Power topic');
	like($topic->{'summary'}, qr/sleep/i, 'the summary names sleep');
	my $body = join(' ', @{ $topic->{'body'} });
	like($body, qr/screen/i, 'the help body explains the screen timer');
	like($body, qr/lid/i, 'the help body explains the lid action');
	like($body, qr/suspend/i, 'the help body names the sleep states');
	my $steps = join(' ', @{ $topic->{'steps'} });
	like($steps, qr/Sleep and display/i, 'the steps walk through the sleep card');

	require "$root/perl/language.pl";
	my %seen;
	for my $lang ( @language::languages ) {
		my $word = language::translate($lang->{'code'}, 'power');
		isnt($word, 'power', $lang->{'code'} . ' still translates the app name');
		$seen{$lang->{'code'}}++;
	}
	is(scalar(keys %seen), 16, 'all sixteen interface languages are present');
}

done_testing();
