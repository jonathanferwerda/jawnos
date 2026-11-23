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
use Mojo::JSON qw(decode_json encode_json);
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
local $ENV{'JAWNOS_POWER_RK818_DISABLE'} = 1;
local $ENV{'JAWNOS_POWER_BOOT_ID'} = 'boot-one';
local $ENV{'JAWNOS_POWER_TAKEOVER_FILE'} = "$scratch/takeover.json";

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
	is($status->{'config'}{'manage'}, 1, 'JawnOS manages power by default');
	is($status->{'charge'}{'supported'}, 1, 'the pack reports a charge ceiling');
	is($status->{'charge'}{'end'}, 100, 'at the percentage it currently stops at');
	ok(exists $status->{'manager'}, 'the status names who manages power');
	ok(exists $status->{'takeover'}, 'the status carries the takeover ledger');
}

write_file("$sys/class/power_supply/AC/online", "1\n");
{
	my $status = subs::power_status();
	is($status->{'source'}, 'ac', 'an online mains supply is the mains source');
	is($status->{'battery'}{'ac'}, 1, 'the battery reading carries the cable state');
}
write_file("$sys/class/power_supply/AC/online", "0\n");

# --- a machine with no pack ------------------------------------------------
# A desktop has mains and no battery. It must read as the mains source, or the
# taskbar widget and the app would offer the battery plan it does not have.
{
	my $bare = tempdir(CLEANUP => 1);
	make_path("$bare/class/power_supply/AC");
	write_file("$bare/class/power_supply/AC/type", "Mains\n");
	write_file("$bare/class/power_supply/AC/online", "1\n");
	local $ENV{'JAWNOS_POWER_SYSFS'} = $bare;
	my $status = subs::power_status();
	is($status->{'battery'}{'present'}, 0, 'a machine with no pack has no battery reading');
	is($status->{'source'}, 'ac', 'and it stands on mains rather than a battery it lacks');
	is($status->{'config'}{'ac'}{'plan'}, 'balanced', 'so its plan is the mains plan');
}

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
	is($state->{'boot'}, 'boot-one', 'the applied state records the boot');
}

# --- a live write follows the cable, and keeps the half it is not naming -----
{
	# The taskbar panel sends `live` with one of the pair: a plan press keeps the
	# saved limit, a stepper press keeps the saved plan. On battery each must edit
	# the battery card; on mains the mains card, even if the panel was built
	# before the cable changed.
	my $saved = subs::power_plan_set('live', 'balanced');
	ok($saved->{'ok'}, 'a live source is accepted');
	is($saved->{'config'}{'battery'}{'plan'}, 'balanced', 'on battery it edits the battery card');
	is($saved->{'config'}{'battery'}{'limit'}, 85, 'and keeps the limit it did not name');
	ok($saved->{'applied'}{'dry_run'}, 'it applies at once because that source is live');
	write_file("$sys/class/power_supply/AC/online", "1\n");
	my $mains = subs::power_plan_set('live', 'performance');
	is($mains->{'config'}{'ac'}{'plan'}, 'performance', 'on mains it edits the mains card');
	is($mains->{'config'}{'ac'}{'limit'}, 100, 'keeping the mains limit');
	is($mains->{'config'}{'battery'}{'plan'}, 'balanced', 'the other card is untouched');
	write_file("$sys/class/power_supply/AC/online", "0\n");
	my $capped = subs::power_plan_set('live', undef, 65);
	is($capped->{'config'}{'battery'}{'plan'}, 'balanced', 'a limit-only write keeps the battery plan');
	is($capped->{'config'}{'battery'}{'limit'}, 65, 'and changes the limit');
	ok($capped->{'applied'}{'dry_run'}, 'applying it at once on the live source');
	is($capped->{'config'}{'ac'}{'plan'}, 'performance', 'the other card stays as it was');
	my $bad = subs::power_plan_set('battery', 'turbo');
	is($bad->{'ok'}, 0, 'an explicitly named unknown plan is still refused');
	# The rest of the file expects the battery performance/85 pair and a
	# balanced mains plan.
	subs::power_plan_set('ac', 'balanced', 100);
	subs::power_plan_set('battery', 'performance', 85);
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

	# A reboot resets the kernel's governor even though the applied row lives
	# in the database; a new boot id must take the saved plan back.
	$ENV{'JAWNOS_POWER_BOOT_ID'} = 'boot-two';
	my $reborn = subs::power_plan_tick();
	ok($reborn->{'dry_run'}, 'a new boot applies the saved plan again');
	is($reborn->{'plan'}, 'performance', 'with the saved battery plan');
	is(decode_json(read_file("$scratch/state.json"))->{'boot'}, 'boot-two', 'and records the new boot');
	my $settled = subs::power_plan_tick();
	is($settled->{'skipped'}, 'already applied', 'the same boot is a no-op again');

	# Automatic switching is about the cable, not the kernel's memory: turning
	# it off must not leave the machine in the firmware default after a boot.
	subs::power_auto_set(0);
	$ENV{'JAWNOS_POWER_BOOT_ID'} = 'boot-three';
	my $restored = subs::power_plan_tick();
	ok($restored->{'dry_run'}, 'a boot still takes the plan back with automatic switching off');
	is($restored->{'plan'}, 'performance', 'and it is the saved plan');
	my $quiet = subs::power_plan_tick();
	is($quiet->{'skipped'}, 'auto is off', 'while the cable watch stays off');
	subs::power_auto_set(1);
}

# --- the master switch -----------------------------------------------------
{
	my $off = subs::power_manage_set(0);
	ok($off->{'ok'}, 'JawnOS management can be turned off');
	is($off->{'config'}{'manage'}, 0, 'the setting is stored');
	is(subs::power_plan_tick()->{'skipped'}, 'system managed', 'the tick leaves the machine alone');
	my $stored = subs::power_plan_set('battery', 'performance', 85);
	ok($stored->{'ok'}, 'a plan can still be stored while the system manages');
	ok(!defined $stored->{'applied'}, 'but saving it does not write the plan');
	my $on = subs::power_manage_set(1);
	ok($on->{'ok'}, 'JawnOS management can be turned back on');
	ok($on->{'applied'}{'dry_run'}, 'turning it on applies the saved plan at once');
	ok($on->{'config'}{'manage'}, 'the setting is on again');
	is(subs::power_plan_tick()->{'skipped'}, 'already applied', 'the tick is idempotent again');
}

# --- the daemon probe rides a slower clock than the cable ------------------
{
	local $subs::power_manager_probed_at = time;
	my $probes = 0;
	my $real = \&subs::power_manager;
	*subs::power_manager = sub { $probes++; return { ok => 1, supported => 1, units => [] }; };
	subs::power_plan_tick();
	is($probes, 0, 'a ten-second tick does not run the daemon probe');
	$subs::power_manager_probed_at = time - 61;
	subs::power_plan_tick();
	is($probes, 1, 'the probe runs again on its minute clock');
	*subs::power_manager = $real;
}

# --- the watch re-asserts management ----------------------------------------
{
	local $subs::power_manager_probed_at = 0;
	my $real_manager = \&subs::power_manager;
	*subs::power_manager = sub { return { ok => 1, supported => 1, units => ['auto-cpufreq'] }; };
	my $taken = subs::power_plan_tick();
	ok($taken->{'dry_run'}, 'a daemon that came back makes the tick apply the plan again');
	*subs::power_manager = $real_manager;

	# Auto deliberately leaves a competing daemon alone.
	subs::power_plan_set('battery', 'auto', 85);
	$subs::power_manager_probed_at = 0;
	*subs::power_manager = sub { return { ok => 1, supported => 1, units => ['auto-cpufreq'] }; };
	my $auto_tick = subs::power_plan_tick();
	is($auto_tick->{'skipped'}, 'already applied', 'Auto still leaves the daemon alone');
	*subs::power_manager = $real_manager;
	subs::power_plan_set('battery', 'performance', 85);
}

# --- the takeover ledger ----------------------------------------------------
{
	unlink "$scratch/takeover.json" if -e "$scratch/takeover.json";
	my $real = \&subs::power_helper;
	*subs::power_helper = sub {
		my ($command) = @_;
		return { ok => 1, records => [ { unit => 'power-profiles-daemon', enabled => 1 } ] }
			if $command eq 'takeover';
		return { ok => 1 };
	};
	subs::power_apply_plan('battery', 'performance', 85);
	my $ledger = subs::power_takeover_state();
	is(scalar @{$ledger}, 1, 'a takeover is recorded');
	is($ledger->[0]{'unit'}, 'power-profiles-daemon', 'with the daemon it stopped');
	is($ledger->[0]{'enabled'}, 1, 'and its enabled state');

	# A later takeover must not overwrite the original state of a daemon that
	# is already in the ledger, and adds any new one.
	*subs::power_helper = sub {
		my ($command) = @_;
		return { ok => 1, records => [
			{ unit => 'power-profiles-daemon', enabled => 0 },
			{ unit => 'tlp', enabled => 0 },
		] } if $command eq 'takeover';
		return { ok => 1 };
	};
	subs::power_apply_plan('battery', 'performance', 85);
	$ledger = subs::power_takeover_state();
	is(scalar @{$ledger}, 2, 'a later takeover adds only the new daemon');
	my ($ppd) = grep { $_->{'unit'} eq 'power-profiles-daemon' } @{$ledger};
	is($ppd->{'enabled'}, 1, 'and keeps the state it had before JawnOS touched it');

	# Unchecking asks for the restore and clears the ledger.
	*subs::power_helper = $real;
	subs::power_takeover_state_save([ { unit => 'power-profiles-daemon', enabled => 1 } ]);
	my $off = subs::power_manage_set(0);
	ok($off->{'release'}{'dry_run'}, 'unchecking asks the helper to restore the daemons');
	is(scalar @{subs::power_takeover_state()}, 0, 'and clears the ledger');

	# A failed restore keeps the ledger for the next quit or start.
	subs::power_takeover_state_save([ { unit => 'tlp', enabled => 0 } ]);
	*subs::power_helper = sub { return { ok => 0, error => 'permission' }; };
	my $failed = subs::power_manage_set(0);
	is($failed->{'release'}{'ok'}, 0, 'a failed restore is reported');
	is(scalar @{subs::power_takeover_state()}, 1, 'and the ledger is kept');
	*subs::power_helper = $real;
	subs::power_manage_set(1);
	subs::power_takeover_state_save([]);
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

# --- the ceiling is remembered and put back --------------------------------
# The kernel does not remember the choice: a boot, the firmware or a restored
# competing daemon returns the pack to 100%. JawnOS stores the percentage and
# writes it again, and only writes when the pack has drifted.
{
	my $ceiling = "$sys/class/power_supply/BAT0/charge_control_end_threshold";
	write_file($ceiling, "100\n");
	my $real_helper = \&subs::power_helper;
	no warnings 'redefine';
	*subs::power_helper = sub {
		my ($command, $end) = @_;
		if ($command eq 'charge') {
			write_file($ceiling, "$end\n");
			return { ok => 1, end => $end };
		}
		return { ok => 1 };
	};
	my $saved = subs::power_charge_set('80');
	ok($saved->{'ok'}, 'the chosen ceiling is written');
	is(subs::power_charge_saved(), 80, 'the choice is stored in the config');
	is(subs::power_config()->{'charge'}{'end'}, 80, 'and survives the config cleaner');

	write_file($ceiling, "100\n");
	my $back = subs::power_charge_apply();
	ok($back->{'applied'}, 'a pack reset to 100 is written back');
	is(read_file($ceiling), "80\n", 'the saved ceiling is on the pack again');
	my $settled = subs::power_charge_apply();
	is($settled->{'applied'}, 0, 'a pack already at the ceiling is left alone');

	my $status = subs::power_status();
	is($status->{'charge'}{'saved'}, 80, 'the status reports the choice, not only the reading');
	is(subs::power_config_clean({ charge => { end => 42 } })->{'charge'}{'end'}, 0,
		'a saved ceiling outside the offered range is dropped');
	*subs::power_helper = $real_helper;
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

# --- the takeover ledger and the systemctl restore --------------------------
# Two daemons are running: one enabled and one disabled. The ledger keeps both
# answers, and restore enables the first while only starting the second.
{
	my $bin = "$scratch/bin-power-systemctl";
	make_path($bin);
	my $log = "$scratch/systemctl.log";
	write_file("$bin/systemctl", <<"SH");
#!/bin/sh
echo "\$*" >> "$log"
case "\$*" in
	"is-active --quiet power-profiles-daemon") exit 0 ;;
	"is-active --quiet tlp") exit 0 ;;
	"is-active --quiet auto-cpufreq") exit 3 ;;
	"is-enabled --quiet power-profiles-daemon") exit 0 ;;
	"is-enabled --quiet tlp") exit 1 ;;
	"is-enabled --quiet auto-cpufreq") exit 3 ;;
	"cat --no-pager power-profiles-daemon") exit 0 ;;
	"cat --no-pager tlp") exit 0 ;;
	"cat --no-pager auto-cpufreq") exit 1 ;;
	*) exit 0 ;;
esac
SH
	chmod 0755, "$bin/systemctl";
	local $ENV{PATH} = "$bin:/bin";
	my $taken = helper('takeover');
	ok($taken->{'ok'}, 'takeover runs against systemctl');
	is_deeply($taken->{'records'}, [
		{ unit => 'power-profiles-daemon', enabled => 1 },
		{ unit => 'tlp', enabled => 0 },
	], 'the ledger records each stopped daemon and its enabled state');
	my $restored = helper('restore', encode_json($taken->{'records'}));
	ok($restored->{'ok'}, 'restore runs against systemctl');
	is_deeply($restored->{'restored'}, [ 'power-profiles-daemon', 'tlp' ], 'both daemons come back');
	my $calls = read_file($log);
	like($calls, qr/^stop power-profiles-daemon$/m, 'takeover stops the daemon');
	like($calls, qr/^stop tlp$/m, 'the disabled one too');
	unlike($calls, qr/disable/, 'the unit is left enabled for the next boot');
	like($calls, qr/^enable --now power-profiles-daemon$/m, 'an enabled daemon is enabled and started');
	like($calls, qr/^start tlp$/m, 'a disabled daemon is only started');
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
	like($routes, qr{/manager/power/manage}, 'the master-switch route exists');

	my $controller = read_file("$root/lib/JawnOS/Controller/manager_power.pm");
	like($controller, qr/^sub action_53010\b/m, 'the window action exists');
	like($controller, qr/^sub action_53011\b/m, 'the status action exists');
	like($controller, qr/&subs::power_plan_set\(/, 'the save action calls the domain');
	like($controller, qr/&subs::power_auto_set\(/, 'the automatic-switch action calls the domain');
	like($controller, qr/&subs::power_apply_current\(/, 'the apply action calls the domain');
	like($controller, qr/&subs::power_charge_set\(/, 'the charge-limit action calls the domain');
	like($controller, qr/^sub action_53018\b/m, 'the master-switch action exists');
	like($controller, qr/&subs::power_manage_set\(/, 'it calls the master switch in the domain');

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
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_manage_set\b/,
		'the master switch is in the domain loader');
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_release_takeover\b/,
		'the takeover release is in the domain loader');
	like($loader, qr/JawnOS::Domain::Power' for qw\([^)]*\bpower_takeover_state\b/,
		'the takeover ledger is in the domain loader');

	my $president = read_file("$root/perl/President.pl");
	my @restores = ($president =~ /&subs::power_release_takeover\(\)/g);
	cmp_ok(scalar @restores, '>=', 3, 'the start, stop and fatal-exit hooks restore the takeover');

	my $tiers = read_file("$root/perl/subroutines.pl");
	like($tiers, qr{/manager/\(\?:configure\|security\|magazine/publish\|packages\|power\)},
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
	like($edit, qr/power: \{ hint: 'Power'/, 'the Power widget is in it');
	like($edit, qr/network: \{ hint: 'Network'/, 'and the network widget');
	like($edit, qr/jawnosTaskbarWidgetMake\(/, 'a widget is built from its order entry');
	like($edit, qr/> \.taskbar_widget/, 'edit mode can drag a widget');

	my $template = read_file("$root/templates/apps/power.html.ep");
	like($template, qr/&subs::power_actions\(\)/, 'the app asks what system power the machine offers');
	like($template, qr/class="power_system_button"/, 'and draws the buttons');
	my $power_js = read_file("$root/public/js/manager/power.js");
	like($power_js, qr{url:\s*'/manager/power'}, 'a system power button posts to the fixed power route');
	like($template, qr/id="power_manage"/, 'the management line carries the master switch');
	like($template, qr/\$manage_capable/, 'the switch is drawn only where JawnOS can manage');
	like($power_js, qr{\$\.post\('/manager/power/manage'}, 'the master switch posts to its own route');
	like($power_js, qr/function powerManage\(/, 'the master switch has its handler');
	my $taskbar_js = read_file("$root/public/js/manager/taskbar_power.js");
	like($taskbar_js, qr/Power is managed by the system/, 'the taskbar panel says when the system manages');
	like($power_js, qr/took over from/, 'the app names the daemon JawnOS took over from');
	like($taskbar_js, qr/took over from/, 'the taskbar panel names it too');
	like($taskbar_js, qr/source:\s*'live'/, 'the panel writes the source the machine is on now');
	like($taskbar_js, qr/data-power-limit-step/, 'the panel carries a CPU speed stepper');
	like($taskbar_js, qr/jawnosT\('CPU speed'\)/, 'its label is the core CPU speed word');
	like($taskbar_js, qr/data: \{ source: 'live', limit: limit \}/, 'a step saves a limit without replacing the plan');
	unlike($taskbar_js, qr/data\.limit = 100/, 'a Performance press no longer forces full speed');
	my $css = read_file("$root/public/css/manager.css");
	like($css, qr/\.taskbar_power_step/, 'the stepper has its own compact buttons');
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

# --- the rk818 is the Gou's real gauge --------------------------------------
# The rk817 node reports a different rail (and called a charging pack
# "Discharging"). The rk818 says plug-in, CC/CV, ~3.99 V and ~0.9 A, which is a
# 75% pack on the resting-voltage table. A fake i2cget supplies those registers;
# the reader is read-only and is what the panel sees on the device.
{
	no warnings 'redefine';
	local *subs::cache_get = sub { {} };
	local *subs::cache_set = sub { };
	my $fake = "$scratch/fake_i2cget";
	write_file($fake, <<'SH');
#!/bin/sh
case "$5" in
	0x21) echo 0x57 ;;
	0xa0) echo 0xb7 ;;
	0xc4) echo 0x0e ;;
	0xc5) echo 0x81 ;;
	0xd5) echo 0x0a ;;
	0xd6) echo 0xde ;;
	0xd7) echo 0x0f ;;
	0xd8) echo 0x42 ;;
	0xbc) echo 0x02 ;;
	0xbd) echo 0x57 ;;
	*) echo 0x00 ;;
esac
SH
	chmod 0755, $fake;
	delete $ENV{'JAWNOS_POWER_RK818_DISABLE'};
	$ENV{'JAWNOS_POWER_RK818'} = '1';
	$ENV{'JAWNOS_POWER_RK818_BUS'} = '0';
	$ENV{'JAWNOS_POWER_RK818_ADDR'} = '0x1c';
	$ENV{'JAWNOS_POWER_I2CGET'} = $fake;
	my $b = subs::power_battery_read();
	is($b->{'source'}, 'rk818', 'the rk818 reading wins over the rk817 node');
	is($b->{'percentage'}, 75, 'the calibrated pack voltage gives 75%');
	is($b->{'status'}, 'charging', 'CC/CV is charging');
	is($b->{'ac'}, 1, 'a plugged rk818 is the mains source');
	is($b->{'cable'}, 1, 'and the cable is reported');
	is($b->{'estimated'}, 1, 'the percentage is marked as an estimate');
	ok(abs($b->{'voltage'} - 3.993) < 0.001, 'the calibrated voltage is 3.993 V');
	ok(abs($b->{'current'} - 0.902094) < 0.00001, 'the current is 0.9 A');
	ok(abs($b->{'charge_eta'} - 1.1085) < 0.01, 'the charge estimate is about 1.1 h');
	delete @ENV{qw(JAWNOS_POWER_RK818 JAWNOS_POWER_RK818_BUS JAWNOS_POWER_RK818_ADDR JAWNOS_POWER_I2CGET)};
	$ENV{'JAWNOS_POWER_RK818_DISABLE'} = 1;
}

# --- the charging gauge holds the last discharge reading ----------------------
# The charger holds the terminal near 4.2 V, which the resting-voltage table
# would read as full on a pack that is nearly empty. The last unplugged reading
# is kept until the PMIC says the pack is full; the raw estimate is still kept.
{
	my %memo;
	no warnings 'redefine';
	local $subs::power_last_discharge_saved_pct = undef;
	local *subs::cache_get = sub {
		my ($p) = @_;
		return { percentage => $memo{'last_discharge'} }
			if ($p->{'context'} || '') eq 'last_discharge' && defined $memo{'last_discharge'};
		return undef;
	};
	local *subs::cache_set = sub {
		my ($p, $d) = @_;
		$memo{ $p->{'context'} } = $d->{'percentage'} if ref $d eq 'HASH' && defined $d->{'percentage'};
	};
	my $charging = {
		source => 'rk818', status => 'charging', ac => 1, percentage => 96,
		percentage_raw => 96, estimated => 1, charge_full => 4_000_000,
		charge_now => 3_840_000, current => 0.9, charge_eta => 0.1,
	};
	$memo{'last_discharge'} = 40;
	my $held = subs::power_battery_charging_hold($charging);
	is($held->{'percentage'}, 40, 'a charging rk818 keeps the last discharge reading');
	is($held->{'percentage_ocv'}, 96, 'the raw voltage estimate is kept');
	is($held->{'percentage_held'}, 1, 'and the reading says it is held');
	is($held->{'charge_now'}, 1_600_000, 'the stored charge follows the held percentage');
	ok(abs($held->{'charge_eta'} - ((4_000_000 - 1_600_000) / (0.9 * 1_000_000))) < 0.001,
		'the charge estimate starts from the held level');
	my $full = { %{$charging}, status => 'full', percentage => 100, percentage_held => 1 };
	is(subs::power_battery_charging_hold($full)->{'percentage'}, 100, 'a full pack reads full');
	my $out = { %{$charging}, status => 'not charging', ac => 0, percentage => 37, percentage_raw => 37 };
	subs::power_battery_charging_hold($out);
	is($memo{'last_discharge'}, 37, 'an unplugged reading is stored for the next charge');
}

# --- the controller's low-battery guard -------------------------------------
# A controller has no daemon to catch a pack that is about to be cut off. Warn
# once at ten percent and ask for a clean shutdown at five, after a second tick
# confirms it; another machine keeps its own policy.
{
	my (%state, @notes, @actions);
	no warnings 'redefine';
	local *subs::device_setter = sub { 'controller' };
	local *subs::cache_get = sub {
		my ($p) = @_;
		return { %{ $state{ $p->{'context'} } || {} } } if $p->{'context'};
		return undef;
	};
	local *subs::cache_set = sub {
		my ($p, $d) = @_;
		$state{ $p->{'context'} } = { %{ $d || {} } };
	};
	local *subs::notification_sender = sub { push @notes, $_[0]; };
	local *subs::power_action = sub { push @actions, $_[0]; return { ok => 1 }; };

	my $battery = { present => 1, ac => 0, percentage => 9, status => 'discharging' };
	my $first = subs::power_battery_guard($battery);
	is($first->{'warned'}, 1, 'nine percent warns');
	is(scalar @notes, 1, 'one notification is sent');
	like($notes[0]{'message'}, qr/9%/, 'and it names the percentage');
	is(scalar @actions, 0, 'but nothing is shut down yet');

	subs::power_battery_guard($battery);
	is(scalar @notes, 1, 'the warning is not repeated on every tick');

	$battery->{'percentage'} = 4;
	my $low = subs::power_battery_guard($battery);
	is($low->{'shutdown'}, 0, 'four percent waits for a second confirmation');
	is(scalar @actions, 0, 'so the first low tick does not shut down');
	$state{'battery_guard'}{'low_at'} = time - 11;
	my $off = subs::power_battery_guard($battery);
	is($off->{'shutdown'}, 1, 'the confirmed low reading shuts down');
	is_deeply(\@actions, ['shutdown'], 'through the fixed power action');
	is(scalar @notes, 2, 'and the second notice says it is shutting down');

	subs::power_battery_guard($battery);
	is(scalar @actions, 1, 'the shutdown is not repeated');

	local *subs::device_setter = sub { 'computer' };
	is(subs::power_battery_guard($battery)->{'skipped'}, 'not a controller',
		'another machine keeps its own policy');
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
	my $body = join ' ', @{ $topic->{body} || [] };
	like($body, qr/last reading before charging/, 'the help describes the held charging reading');
	like($body, qr/ten percent/, 'the help names the warning threshold');
	like($body, qr/five percent/, 'and the clean-shutdown threshold');

	my $power_src = read_file("$root/lib/JawnOS/Domain/Power.pm");
	like($power_src, qr/sub power_plan_tick \{.*?&power_battery_guard/s,
		'the slow tick runs the guard before the manage switch');
	like(read_file("$root/lib/JawnOS/Domain/Loader.pm"), qr/\bpower_battery_guard\b/,
		'and the guard is reachable by name');

	my $jobs = read_file("$root/perl/jobs.pl");
	like($jobs, qr/name => 'power watch'/, 'the slow loop carries the source switch');
	like($jobs, qr/name => 'power watch'[^\n]*every => 10\b/, 'the cable is watched every ten seconds');
	like($jobs, qr/&subs::power_plan_tick\(\)/, 'and calls the domain helper');
	like($jobs, qr/sub job_slow_loops \{.*?eval \{ &subs::power_plan_tick\(\); \};.*?my \@slow_loops/s,
		'the plan is taken back at once when the slow worker starts');
}

done_testing();
