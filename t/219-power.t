# tests-for: lib/JawnOS/Domain/Power.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_power.pm lib/JawnOS/Routes/manager_power.pm scripts/jawnos_power.pl templates/apps/power.html.ep public/js/manager/power.js public/js/manager/taskbar_power.js public/icons/power.svg templates/start_menu/start_menu.html.ep templates/manager.html.ep public/css/manager.css lib/JawnOS/Manager/Core1_tables_hooks.pm public/js/manager/windows/01_storage.js public/js/manager/taskbar_edit.js perl/President.pl perl/jobs.pl perl/language.pl perl/help/topics_apps.pl perl/help/topics_features.pl perl/gb/02_labels_and_collectives.pl
# covers:    The Power app: a battery reading and its finish time, the CPU reading,
#            the two source plans, the idempotent source switch, the fixed writer,
#            and the menu/taskbar/help/translation wiring.

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

# A fake machine: one battery, one mains supply and one clock domain. The
# battery reports its own gauge, so the four hours left below come from the
# energy and power files and not from a guessed percentage slope.
make_path(
	"$sys/class/power_supply/BAT0",
	"$sys/class/power_supply/AC",
	"$sys/devices/system/cpu/cpufreq/policy0",
);
write_file("$sys/class/power_supply/BAT0/capacity", "80\n");
write_file("$sys/class/power_supply/BAT0/status", "Discharging\n");
write_file("$sys/class/power_supply/BAT0/energy_now", "40000000\n");
write_file("$sys/class/power_supply/BAT0/energy_full", "50000000\n");
write_file("$sys/class/power_supply/BAT0/power_now", "10000000\n");
write_file("$sys/class/power_supply/BAT0/charge_control_end_threshold", "100\n");
write_file("$sys/class/power_supply/AC/type", "Mains\n");
write_file("$sys/class/power_supply/AC/online", "0\n");
my $policy = "$sys/devices/system/cpu/cpufreq/policy0";
write_file("$policy/scaling_governor", "schedutil\n");
write_file("$policy/scaling_available_governors", "powersave schedutil performance\n");
write_file("$policy/scaling_driver", "amd-pstate-epp\n");
write_file("$policy/scaling_cur_freq", "2000000\n");
write_file("$policy/cpuinfo_min_freq", "400000\n");
write_file("$policy/cpuinfo_max_freq", "4000000\n");
write_file("$policy/scaling_max_freq", "4000000\n");
write_file("$policy/energy_performance_preference", "balance_performance\n");
write_file("$policy/energy_performance_available_preferences", "power balance_power balance_performance performance\n");
write_file("$sys/devices/system/cpu/cpufreq/boost", "1\n");

local $ENV{'JAWNOS_POWER_SYSFS'} = $sys;
local $ENV{'JAWNOS_POWER_CONFIG_FILE'} = "$scratch/config.json";
local $ENV{'JAWNOS_POWER_STATE_FILE'} = "$scratch/state.json";
local $ENV{'JAWNOS_POWER_DRY_RUN'} = 1;

require "$root/lib/JawnOS/Domain/Power.pm";

# The domain reads the machine's kind and the clock through the house helpers.
# This test is about the power arithmetic, so both are fixed and nothing here
# can touch a real battery or a real sysfs file.
no warnings 'redefine';
*subs::device_setter = sub { 'computer' };
*subs::rightNow = sub { 1_790_000_000_000 };

# --- the reading ------------------------------------------------------------
{
	my $status = subs::power_status();
	ok($status->{'ok'}, 'the status is readable');
	is($status->{'source'}, 'battery', 'a discharging pack with no mains is the battery source');
	is($status->{'battery'}{'percentage'}, 80, 'the capacity file is the percentage');
	is($status->{'battery'}{'status'}, 'discharging', 'the status is normalised');
	ok(abs($status->{'battery'}{'discharge_eta'} - 4) < 0.001, 'the gauge gives four hours left');
	is($status->{'cpu'}{'supported'}, 1, 'the clock domain is found');
	is($status->{'cpu'}{'governor'}, 'schedutil', 'the governor is read');
	is($status->{'cpu'}{'cur_mhz'}, 2000, 'the current clock is read in MHz');
	is($status->{'cpu'}{'max_mhz'}, 4000, 'the ceiling is read in MHz');
	is($status->{'cpu'}{'turbo'}, 1, 'turbo is reported on');
	is($status->{'config'}{'battery'}{'plan'}, 'saver', 'the default battery plan is the saver');
	is($status->{'config'}{'battery'}{'limit'}, 70, 'the default battery speed limit is 70%');
	is($status->{'config'}{'ac'}{'plan'}, 'balanced', 'the default mains plan is balanced');
	is($status->{'charge'}{'supported'}, 1, 'the pack reports a charge ceiling');
	is($status->{'charge'}{'end'}, 100, 'at the percentage it currently stops at');
	ok(exists $status->{'manager'}, 'the status names who manages power');
}

write_file("$sys/class/power_supply/AC/online", "1\n");
{
	my $status = subs::power_status();
	is($status->{'source'}, 'ac', 'an online mains supply is the mains source');
	is($status->{'battery'}{'ac'}, 1, 'the battery reading carries the cable state');
}
write_file("$sys/class/power_supply/AC/online", "0\n");

# --- saving a plan applies it when its source is the one in use -------------
{
	my $saved = subs::power_plan_set('battery', 'performance', 85);
	ok($saved->{'ok'}, 'the battery plan is saved');
	is($saved->{'config'}{'battery'}{'plan'}, 'performance', 'the saved plan is the new one');
	is($saved->{'config'}{'battery'}{'limit'}, 85, 'the saved limit is the new one');
	ok($saved->{'applied'}{'dry_run'}, 'the current source is applied at once');
	my $state = decode_json(read_file("$scratch/state.json"));
	is($state->{'plan'}, 'performance', 'the applied state records the plan');
	is($state->{'limit'}, 85, 'the applied state records the limit');
}

# --- the source switch is idempotent ---------------------------------------
{
	unlink "$scratch/state.json" if -e "$scratch/state.json";
	my $first = subs::power_plan_tick();
	ok($first->{'dry_run'}, 'the first tick applies the battery plan');
	is($first->{'plan'}, 'performance', 'and it is the saved battery plan');
	my $second = subs::power_plan_tick();
	is($second->{'skipped'}, 'already applied', 'the next tick is a no-op');
	write_file("$sys/class/power_supply/AC/online", "1\n");
	my $third = subs::power_plan_tick();
	ok($third->{'dry_run'}, 'plugging in applies once more');
	is($third->{'source'}, 'ac', 'and it is the mains source');
	is($third->{'plan'}, 'balanced', 'with the saved mains plan');
	write_file("$sys/class/power_supply/AC/online", "0\n");
}

# --- the fixed writer -------------------------------------------------------
# Run the real helper against the fake machine. The files are writable, so no
# sudo is involved and the assertions can read back what the kernel would hold.
sub helper {
	my @args = @_;
	local $ENV{'JAWNOS_POWER_SYSFS'} = $sys;
	local $ENV{'JAWNOS_POWER_DRY_RUN'} = '';
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
	my $saver = helper('apply', 'saver', '60');
	ok($saver->{'ok'}, 'the saver plan is applied');
	is(read_file("$policy/scaling_governor"), "powersave\n", 'the saver picks powersave');
	is(read_file("$policy/energy_performance_preference"), "power\n", 'the saver asks for the power preference');
	is(read_file("$sys/devices/system/cpu/cpufreq/boost"), "0\n", 'the saver turns turbo off');
	is(read_file("$policy/scaling_max_freq"), "2560000\n", '60% of 400 MHz to 4 GHz is 2.56 GHz');
	is($saver->{'max_mhz'}, 2560, 'the answer reports the cap in MHz');

	my $performance = helper('apply', 'performance', '100');
	ok($performance->{'ok'}, 'the performance plan is applied');
	is(read_file("$policy/scaling_governor"), "performance\n", 'the performance plan picks the performance governor');
	is(read_file("$policy/energy_performance_preference"), "performance\n", 'and the performance preference');
	is(read_file("$sys/devices/system/cpu/cpufreq/boost"), "1\n", 'and turbo on');
	is(read_file("$policy/scaling_max_freq"), "4000000\n", 'and the whole clock range');

	write_file("$policy/scaling_governor", "schedutil\n");
	my $auto = helper('apply', 'auto', '100');
	ok($auto->{'ok'}, 'auto is accepted');
	is(read_file("$policy/scaling_governor"), "schedutil\n", 'auto writes nothing');

	my $bad = helper('apply', 'turbo', '100');
	is($bad->{'ok'}, 0, 'an unknown plan is refused');
	is(read_file("$policy/scaling_governor"), "schedutil\n", 'and nothing is written');
}

# --- the charge ceiling -----------------------------------------------------
# The laptop's pack exposes charge_control_end_threshold; the helper writes it
# and refuses a limit outside the range the app offers.
{
	my $ceiling = "$sys/class/power_supply/BAT0/charge_control_end_threshold";
	my $raised = helper('charge', '80');
	ok($raised->{'ok'}, 'the charge limit is written');
	is($raised->{'end'}, 80, 'and reported back');
	is(read_file($ceiling), "80\n", 'the pack now stops at 80%');

	my $low = helper('charge', '45');
	is($low->{'ok'}, 0, 'a limit below 50 is refused');
	is(read_file($ceiling), "80\n", 'and the saved ceiling is untouched');

	my $high = helper('charge', '101');
	is($high->{'ok'}, 0, 'a limit above 100 is refused');
}

# --- who is managing power --------------------------------------------------
# A fake systemctl that reports auto-cpufreq running and the others absent:
# the manager answer must name exactly the daemon that would race JawnOS.
{
	my $bin = "$scratch/bin-systemctl";
	make_path($bin);
	write_file("$bin/systemctl", "#!/bin/sh\ncase \"\$*\" in *auto-cpufreq*) exit 0;; *) exit 3;; esac\n");
	chmod 0755, "$bin/systemctl";
	local $ENV{PATH} = "$bin:/bin";
	my $manager = helper('manager');
	ok($manager->{'ok'}, 'the manager answer is readable');
	is_deeply($manager->{'units'}, ['auto-cpufreq'], 'only the running daemon is named');
}

# --- the route, the controller and the tier ---------------------------------
{
	my $routes = read_file("$root/lib/JawnOS/Routes/manager_power.pm");
	like($routes, qr/\[\s*53010\s*,\s*'get'\s*,\s*'\/manager\/power'\s*,\s*'action_53010'\s*\]/,
		'the app window has its route');
	like($routes, qr/\[\s*53011\s*,\s*'get'\s*,\s*'\/manager\/power_status'\s*,\s*'action_53011'\s*\]/,
		'the status route is outside the citizen prefix');
	like($routes, qr{/manager/power/plan}, 'the save route exists');
	like($routes, qr{/manager/power/auto}, 'the automatic-switch route exists');
	like($routes, qr{/manager/power/apply}, 'the apply route exists');
	like($routes, qr{/manager/power/charge}, 'the charge-limit route exists');

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_power.pm");
	like($controller, qr/^sub action_53010\b/m, 'the window action exists');
	like($controller, qr/^sub action_53011\b/m, 'the status action exists');
	like($controller, qr/&subs::power_plan_set\(/, 'the save action calls the domain');
	like($controller, qr/&subs::power_auto_set\(/, 'the automatic-switch action calls the domain');
	like($controller, qr/&subs::power_apply_current\(/, 'the apply action calls the domain');
	like($controller, qr/&subs::power_charge_set\(/, 'the charge-limit action calls the domain');

	my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_status\b/,
		'every Power helper is in the domain loader');
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_plan_tick\b/,
		'the source switch is in the domain loader');
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_charge_set\b/,
		'the charge writer is in the domain loader');
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_takeover\b/,
		'the daemon takeover is in the domain loader');
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_manager\b/,
		'the manager reading is in the domain loader');

	my $tiers = read_file("$root/perl/subroutines.pl");
	like($tiers, qr{/manager/\(\?:configure\|security\|magazine/publish\|power\)},
		'the citizen tier table names the power prefix');
	require "$root/qa/lib/Probe.pm";
	is(Probe::tier_needed('/manager/power'), 'citizen', 'the app desk is a citizen route');
	is(Probe::tier_needed('/manager/power_status'), 'resident', 'the taskbar reading is a resident route');
}

# --- the menu, the taskbar and the lazy-app maps ----------------------------
{
	my $menu = read_file("$root/templates/start_menu/start_menu.html.ep");
	like($menu, qr/id="power_toggle"/, 'the start menu carries the Power icon');
	like($menu, qr/hint="<%= &subs::lang\('power'\) %>"/, 'its hint is a core label');

	my $manager = read_file("$root/templates/manager.html.ep");
	like($manager, qr/id="taskbar_windows"/, 'the taskbar container is still the shell');
	unlike($manager, qr/id="taskbar_power"/, 'the battery widget is built by the widget registry, not fixed in the template');

	my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
	like($core, qr{/js/manager/taskbar_power\.js}, 'the battery poller is in the core bundle');
	like($core, qr{/js/manager/taskbar_network\.js}, 'the network poller is in the core bundle');
	like($core, qr/power\s*=>\s*\[qw\(\/js\/manager\/power\.js\)\]/, 'the app has its lazy chunk');
	like($core, qr/power\s*=>\s*\[qw\(powerOpener\)\]/, 'the opener has its entry stub');
	like($core, qr/power_toggle\s*=>\s*'power'/, 'the first click is replayed to the app');

	my $windows = read_file("$root/public/js/manager/windows/01_storage.js");
	like($windows, qr/i == 'power'/, 'a restored Power window uses its own opener');

	my $edit = read_file("$root/public/js/manager/taskbar_edit.js");
	like($edit, qr/jawnosTaskbarWidgets = \{/, 'the widget registry exists');
	like($edit, qr/power: \{ hint: 'Battery'/, 'the battery widget is in it');
	like($edit, qr/network: \{ hint: 'Network'/, 'and the network widget');
	like($edit, qr/jawnosTaskbarWidgetMake\(/, 'a widget is built from its order entry');
	like($edit, qr/> \.taskbar_widget/, 'edit mode can drag a widget');

	my $template = read_file("$root/templates/apps/power.html.ep");
	like($template, qr/&subs::power_actions\(\)/, 'the app asks what system power the machine offers');
	like($template, qr/class="power_system_button"/, 'and draws the buttons');
	my $power_js = read_file("$root/public/js/manager/power.js");
	like($power_js, qr{url:\s*'/manager/power'}, 'a system power button posts to the fixed power route');
}

# --- a gauge that has not learned its counter -------------------------------
# The Gou's rk817 pack reported capacity=1 and ~56 mAh while the cell held
# 3.94 V, and its charger put 5.01 V on the input while `online` stayed 0. The
# reading keeps the raw gauge value, shows a resting-voltage estimate, and
# reports the cable separately so the panel can say "not charging" honestly.
{
	my $gou = tempdir(CLEANUP => 1);
	make_path("$gou/class/power_supply/rk817-battery", "$gou/class/power_supply/rk817-charger");
	write_file("$gou/class/power_supply/rk817-battery/type", "Battery\n");
	write_file("$gou/class/power_supply/rk817-battery/capacity", "1\n");
	write_file("$gou/class/power_supply/rk817-battery/status", "Not charging\n");
	write_file("$gou/class/power_supply/rk817-battery/voltage_avg", "3940000\n");
	write_file("$gou/class/power_supply/rk817-battery/current_avg", "1366540\n");
	write_file("$gou/class/power_supply/rk817-battery/charge_now", "56000\n");
	write_file("$gou/class/power_supply/rk817-battery/charge_full", "4000000\n");
	write_file("$gou/class/power_supply/rk817-charger/type", "USB\n");
	write_file("$gou/class/power_supply/rk817-charger/online", "0\n");
	write_file("$gou/class/power_supply/rk817-charger/voltage_avg", "5011000\n");
	$ENV{'JAWNOS_POWER_SYSFS'} = $gou;
	my $b = subs::power_battery_read();
	is($b->{'percentage'}, 66, 'the resting voltage replaces a one-percent gauge');
	is($b->{'percentage_raw'}, 1, 'the raw gauge value is kept');
	is($b->{'estimated'}, 1, 'the reading says it is an estimate');
	is($b->{'cable'}, 1, 'a 5 V input is reported as a cable even when online stays off');
	is($b->{'ac'}, 0, 'the cable alone does not pretend the pack is charging');
	ok(abs($b->{'current'} - 1.36654) < 0.00001, 'current_avg is the fallback current');
	is(subs::power_ocv_percent(4.20), 100, 'a full cell is 100%');
	is(subs::power_ocv_percent(3.30), 0, 'an empty cell is 0%');
	is(subs::power_ocv_percent(3.90), 60, 'the middle of the table is read');
	$ENV{'JAWNOS_POWER_SYSFS'} = $sys;
}

# --- the labels and the help topic -----------------------------------------
{
	require "$root/perl/language.pl";
	for my $lang ( @language::languages ) {
		my $word = language::translate($lang->{'code'}, 'power');
		isnt($word, 'power', $lang->{'code'} . ' translates the app name');
	}

	require "$root/perl/help.pl";
	my $topic = $help::topic{'power'};
	ok($topic, 'the help registry has a Power topic');
	is($topic->{app}, 'power', 'the topic names the app');
	is($topic->{category}, 'apps', 'it lives in the app category');
	like($topic->{summary}, qr/battery/i, 'the summary names the battery');

	my $jobs = read_file("$root/perl/jobs.pl");
	like($jobs, qr/name => 'power watch'/, 'the slow loop carries the source switch');
	like($jobs, qr/&subs::power_plan_tick\(\)/, 'and calls the domain helper');
}

done_testing();
