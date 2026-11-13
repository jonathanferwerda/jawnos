package subs;

# Power: the Power app's readings and its plan switch.
#
# One battery reading, one CPU reading, and the saved plan for each power source
# (mains and battery). The readings come from sysfs on a Linux machine (the live
# image, the desktop app and the Gou are all this path) and from the Android
# bridge on a phone. Changing the CPU is the one thing that writes: it goes
# through scripts/jawnos_power.pl, a fixed command set, so no request value ever
# reaches a shell and a machine without cpufreq is a fact rather than an error.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use Cwd ();
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json encode_json);

our $power_status_memo;

# The sleep and display choices. Values are stored in minutes; 0 is Never.
# Each is a closed set, so a request value never reaches the helper unchecked.
our @power_screen_timeouts = (0, 1, 2, 5, 10, 15, 30);
our @power_sleep_timeouts = (0, 1, 2, 5, 10, 15, 30, 60);
our %power_lid_action_words = (
	suspend => 'suspend',
	hibernate => 'hibernate',
	hybrid_sleep => 'hybrid-sleep',
	poweroff => 'poweroff',
	ignore => 'ignore',
);
our %power_sleep_type_words = (
	suspend => 'suspend',
	hibernate => 'hibernate',
	hybrid_sleep => 'hybrid-sleep',
	suspend_then_hibernate => 'suspend-then-hibernate',
);

our %power_plan_defaults = (
	auto => { id => 'auto', governors => [], epp => '', turbo => undef },
	saver => { id => 'saver', governors => [qw(powersave conservative ondemand schedutil)], epp => 'power', turbo => 0 },
	balanced => { id => 'balanced', governors => [qw(schedutil ondemand powersave performance)], epp => 'balance_performance', turbo => 1 },
	performance => { id => 'performance', governors => [qw(performance schedutil ondemand powersave)], epp => 'performance', turbo => 1 },
);

sub power_sysfs_root {
	my $root = $ENV{'JAWNOS_POWER_SYSFS'} || '/sys';
	$root =~ s{/+$}{};
	return length $root ? $root : '/';
}

sub power_plan_valid {
	my ($plan) = @_;
	return (defined $plan && $power_plan_defaults{$plan}) ? 1 : 0;
}

sub power_timeout_valid {
	my ($value, $allowed) = @_;
	return 0 unless defined $value && $value =~ /^\d+$/;
	return (grep { $_ == $value } @{$allowed}) ? 1 : 0;
}

sub power_lid_action_valid {
	my ($action) = @_;
	return (defined $action && exists $power_lid_action_words{$action}) ? 1 : 0;
}

sub power_sleep_type_valid {
	my ($type) = @_;
	return (defined $type && exists $power_sleep_type_words{$type}) ? 1 : 0;
}

sub power_limit_clamp {
	my ($limit) = @_;
	$limit = 100 unless defined $limit && $limit =~ /^\d+$/;
	$limit += 0;
	$limit = 25 if $limit < 25;
	$limit = 100 if $limit > 100;
	return $limit;
}

sub power_limit_round {
	my ($limit) = @_;
	$limit = &power_limit_clamp($limit);
	$limit = int(($limit + 2) / 5) * 5;
	return &power_limit_clamp($limit);
}

sub power_read {
	my ($path) = @_;
	my $value = '';
	if (open(my $fh, '<', $path)) {
		$value = <$fh> // '';
		close $fh;
		$value =~ s/\s+$//;
	}
	return $value;
}

# The kernel's per-boot identity. The CPU and sleep settings live in sysfs,
# which the firmware resets at boot, while the "last applied" row lives in the
# database and survives it. Comparing the two tells a stale row - one written
# for a kernel that is gone - from a plan this boot already holds.
sub power_boot_id {
	return $ENV{'JAWNOS_POWER_BOOT_ID'} if defined $ENV{'JAWNOS_POWER_BOOT_ID'};
	return &power_read('/proc/sys/kernel/random/boot_id');
}

sub power_number {
	my ($path) = @_;
	my $value = &power_read($path);
	return undef unless $value =~ /^-?\d+(?:\.\d+)?$/;
	return $value + 0;
}

sub power_mhz {
	my ($khz) = @_;
	return undef unless defined $khz;
	return int($khz / 1000 + 0.5);
}

sub power_command_path {
	my ($name) = @_;
	return undef unless defined $name && $name =~ /^[A-Za-z0-9._-]+$/;
	for my $dir (split /:/, ($ENV{'PATH'} // '/usr/bin:/bin')) {
		my $candidate = "$dir/$name";
		return $candidate if -x $candidate;
	}
	return undef;
}

sub power_platform {
	my $cpu = &power_cpu_read();
	return 'linux' if $cpu->{'supported'};
	my $root = &power_sysfs_root();
	return 'linux' if -d "$root/class/power_supply";
	return 'android' if (&subs::device_setter() || '') eq 'mobile';
	return 'unknown';
}

# A lithium pack's resting voltage is a usable second opinion when the fuel
# gauge has not learned its coulomb counter yet. The table is deliberately
# coarse: it is a displayed estimate, marked as one, not a calibration write.
our @POWER_OCV = (
	[4.20, 100], [4.12, 92], [4.05, 83], [4.00, 76], [3.95, 68],
	[3.90, 60], [3.85, 52], [3.80, 44], [3.75, 36], [3.70, 28],
	[3.65, 21], [3.60, 14], [3.50, 7], [3.40, 2], [3.30, 0],
);

sub power_ocv_percent {
	my ($voltage) = @_;
	return undef unless defined $voltage && $voltage > 0;
	return 100 if $voltage >= $POWER_OCV[0][0];
	return 0 if $voltage <= $POWER_OCV[-1][0];
	for my $i (0 .. $#POWER_OCV - 1) {
		my ($vhi, $phi) = @{ $POWER_OCV[$i] };
		my ($vlo, $plo) = @{ $POWER_OCV[$i + 1] };
		next unless $voltage <= $vhi && $voltage >= $vlo;
		return int($plo + ($voltage - $vlo) * ($phi - $plo) / ($vhi - $vlo) + 0.5);
	}
	return 0;
}

# The Gou puts its battery and charger on the rk818 PMIC, not on the rk817
# that also sits on the I2C bus (the rk817's gauge reports a different rail and
# called a charging pack "Discharging"). Mainline has no rk818-battery driver,
# so its registers are read directly, read-only, through i2cget. The percentage
# is the same coarse resting-voltage table, marked as an estimate.
sub power_rk818_byte {
	my ($tool, $bus, $addr, $reg) = @_;
	return undef unless defined $tool && length $tool;
	my $pid = open(my $fh, '-|', $tool, '-y', '-f', $bus, $addr, "0x$reg");
	return undef unless $pid;
	my $line = <$fh> // '';
	close $fh;
	return undef unless $line =~ /0x([0-9a-fA-F]{2})/;
	return hex($1);
}

sub power_rk818_read {
	return undef if $ENV{'JAWNOS_POWER_RK818_DISABLE'};
	my ($bus, $addr) = ('0', '0x1c');
	if (defined $ENV{'JAWNOS_POWER_RK818'} && length $ENV{'JAWNOS_POWER_RK818'}) {
		$bus = $ENV{'JAWNOS_POWER_RK818_BUS'} || $bus;
		$addr = $ENV{'JAWNOS_POWER_RK818_ADDR'} || $addr;
	}
	else {
		# The MFD driver owns the device, and its sysfs name says which PMIC it is.
		my ($dev) = grep { -d } glob('/sys/bus/i2c/devices/*-001c');
		return undef unless $dev;
		my $name = &power_read("$dev/name");
		return undef unless $name =~ /rk818/i;
		($bus) = $dev =~ m{/(\d+)-001c$};
		return undef unless defined $bus;
	}
	my $tool = $ENV{'JAWNOS_POWER_I2CGET'} || &power_command_path('i2cget');
	return undef unless defined $tool && -x $tool;
	my %r;
	for my $reg (qw(21 a0 c4 c5 d5 d6 d7 d8 bc bd)) {
		my $value = &power_rk818_byte($tool, $bus, $addr, $reg);
		return undef unless defined $value;
		$r{$reg} = $value;
	}

	my $vcalib0 = ($r{'d5'} << 8) | $r{'d6'};
	my $vcalib1 = ($r{'d7'} << 8) | $r{'d8'};
	my $k = $vcalib1 > $vcalib0 ? (4200 - 3000) * 1000 / ($vcalib1 - $vcalib0) : 1000;
	my $b = 4200 - ($k * $vcalib1) / 1000;
	my $mv = int(($k * (($r{'c4'} << 8) | $r{'c5'})) / 1000 + $b);
	return undef unless $mv >= 2500 && $mv <= 4600;

	my $raw_current = ($r{'bc'} << 8) | $r{'bd'};
	$raw_current -= 4096 if $raw_current & 0x0800;
	my $amps = $raw_current * 1506 / 1000 / 1000;

	my $state = ($r{'a0'} >> 4) & 0x07;
	my $status = $state == 4 ? 'full'
		: (($state == 1 || $state == 2 || $state == 3) ? 'charging'
		: ($state == 0 ? 'not charging' : 'unknown'));
	my $plug = ($r{'21'} & 0x40) ? 1 : 0;
	my $percentage = &power_ocv_percent($mv / 1000);
	$percentage = 100 if $state == 4;
	my $full = 4_000_000;
	my $now = int($full * $percentage / 100);

	my %b = (
		present => 1,
		source => 'rk818',
		percentage => $percentage,
		percentage_raw => $percentage,
		estimated => 1,
		status => $status,
		voltage => $mv / 1000,
		current => $amps,
		ac => $plug,
		cable => $plug,
		charge_full => $full,
		charge_now => $now,
		health => 'good',
	);
	if ($status eq 'charging' && $amps > 0 && $full > $now) {
		$b{'charge_eta'} = ($full - $now) / ($amps * 1_000_000);
	}
	elsif ($status eq 'discharging' && $amps < 0 && $now > 0) {
		$b{'discharge_eta'} = $now / (abs($amps) * 1_000_000);
	}
	return \%b;
}

# Read the battery directly. On a Linux machine this is cheap and exact; on a
# phone sysfs is often denied, so the bridge's battery.status is the fallback.
# The bridge is not asked on a machine that is plainly not a phone: a desktop
# with no pack should not wait five seconds for a bridge that is not there.
sub power_battery_read {
	my $rk818 = &power_rk818_read();
	return $rk818 if ref $rk818 eq 'HASH';
	my $root = &power_sysfs_root();
	my @supply = grep { -d } glob("$root/class/power_supply/*");
	my ($battery) = grep {
		my $type = lc(&power_read("$_/type"));
		$type eq 'battery' || -e "$_/capacity"
	} @supply;

	if ($battery) {
		my %b = (present => 1, source => 'sysfs');
		$b{'percentage'} = &power_number("$battery/capacity");
		$b{'status'} = lc(&power_read("$battery/status"));
		$b{'health'} = lc(&power_read("$battery/health"));
		$b{'technology'} = &power_read("$battery/technology");
		my $temp = &power_number("$battery/temp");
		$b{'temperature'} = defined $temp ? $temp / 10 : undef;
		my $volt = &power_number("$battery/voltage_now");
		$volt = &power_number("$battery/voltage_avg") unless defined $volt;
		$b{'voltage'} = defined $volt ? $volt / 1_000_000 : undef;
		my $cur = &power_number("$battery/current_now");
		$cur = &power_number("$battery/current_avg") unless defined $cur;
		$b{'current'} = defined $cur ? $cur / 1_000_000 : undef;
		# A gauge that has not learned its full charge reports 0 or 1 while the
		# pack is plainly holding a voltage. Show the resting-voltage estimate
		# instead, and say it is an estimate, so the launcher is not stuck at 0%.
		if (defined $b{'percentage'} && $b{'percentage'} <= 1 && defined $b{'voltage'} && $b{'voltage'} >= 3.30) {
			my $guess = &power_ocv_percent($b{'voltage'});
			if (defined $guess) {
				$b{'percentage_raw'} = $b{'percentage'};
				$b{'percentage'} = $guess;
				$b{'estimated'} = 1;
			}
		}
		my $pow = &power_number("$battery/power_now");
		$b{'power'} = defined $pow ? $pow / 1_000_000 : undef;
		$b{'energy_now'} = &power_number("$battery/energy_now");
		$b{'energy_full'} = &power_number("$battery/energy_full");
		$b{'charge_now'} = &power_number("$battery/charge_now");
		$b{'charge_full'} = &power_number("$battery/charge_full");
		$b{'ac'} = &power_ac_online(\@supply, \%b) ? 1 : 0;
		# A charger can put 5 V on the input while the PMIC's plug-in status
		# stays off (the Gou's cable did exactly that). The cable is worth
		# reporting even when the pack is not charging, so the panel can say
		# "cable connected, not charging" instead of hiding the supply.
		for my $dir (@supply) {
			next if lc(&power_read("$dir/type")) eq 'battery';
			next if &power_read("$dir/online") eq '1';
			my $vin = &power_number("$dir/voltage_avg");
			$vin = &power_number("$dir/voltage_now") unless defined $vin;
			$b{'cable'} = 1 if defined $vin && $vin > 4_500_000;
		}
		# The pack's own gauge is the honest rate: energy over power, or charge
		# over current. Both are kept in the gauge's units so no conversion can
		# drift, and a charging pack's remaining time is the other half.
		my ($now_u, $full_u, $rate_u);
		if (defined $b{'energy_now'} && defined $b{'energy_full'} && $b{'energy_full'} > 0
			&& defined $b{'power'} && $b{'power'} > 0) {
			($now_u, $full_u, $rate_u) = ($b{'energy_now'}, $b{'energy_full'}, $b{'power'} * 1_000_000);
		}
		elsif (defined $b{'charge_now'} && defined $b{'charge_full'} && $b{'charge_full'} > 0
			&& defined $b{'current'} && $b{'current'} != 0) {
			($now_u, $full_u, $rate_u) = ($b{'charge_now'}, $b{'charge_full'}, abs($b{'current'}) * 1_000_000);
		}
		if (defined $now_u && defined $full_u && defined $rate_u && $rate_u > 0) {
			if ($b{'status'} eq 'charging' && $full_u > $now_u) {
				$b{'charge_eta'} = ($full_u - $now_u) / $rate_u;
			}
			elsif ($b{'status'} eq 'discharging' && $now_u > 0) {
				$b{'discharge_eta'} = $now_u / $rate_u;
			}
		}
		return \%b;
	}

	return { present => 0, source => 'none', ac => 0 }
		unless $ENV{'JAWNOS_POWER_SYSFS'} || (&subs::device_setter() || '') eq 'mobile';

	my $sample = eval { &subs::battery_sample() };
	return { present => 0, source => 'none', ac => 0 } unless ref $sample eq 'HASH' && defined $sample->{'percentage'};
	my $plugged = lc($sample->{'plugged'} || '');
	my $status = lc($sample->{'status'} || '');
	return {
		present => 1,
		source => 'bridge',
		percentage => $sample->{'percentage'} + 0,
		status => $status,
		health => $sample->{'health'} || '',
		temperature => $sample->{'temperature'},
		voltage => $sample->{'voltage'},
		current => $sample->{'current'},
		power => $sample->{'power'},
		plugged => $plugged,
		ac => ($plugged ne '' || $status eq 'charging' || $status eq 'full') ? 1 : 0,
		charge_eta => $sample->{'charge_eta'},
		discharge_eta => $sample->{'discharge_eta'},
		capacity_mah => $sample->{'capacity_mah'},
		stale => $sample->{'stale'},
		stale_age => $sample->{'stale_age'},
	};
}

sub power_ac_online {
	my ($supply, $battery) = @_;
	$supply ||= [ grep { -d } glob(&power_sysfs_root() . '/class/power_supply/*') ];
	foreach my $dir ( @{$supply} ) {
		my $type = lc(&power_read("$dir/type"));
		next if $type eq 'battery';
		my $online = &power_read("$dir/online");
		return 1 if $online eq '1';
	}
	my $status = lc($battery->{'status'} || '');
	return 1 if $status eq 'charging' || $status eq 'full';
	return 0;
}

# One clock domain is one policy; older kernels keep the files under cpu0.
sub power_cpu_policies {
	my $root = &power_sysfs_root();
	my @dirs = grep { -d } glob("$root/devices/system/cpu/cpufreq/policy*");
	@dirs = grep { -d } glob("$root/devices/system/cpu/cpu*/cpufreq") unless @dirs;
	my (%seen, @out);
	for my $dir (@dirs) {
		my $real = eval { Cwd::realpath($dir) } || $dir;
		next if $seen{$real}++;
		push @out, $dir;
	}
	return @out;
}

sub power_cpu_read {
	my @policy = &power_cpu_policies();
	my $cpu = {
		supported => (@policy ? 1 : 0),
		policies => scalar(@policy),
		governor => '',
		governors => [],
		epp => '',
		epp_available => [],
		driver => '',
		turbo => undef,
		turbo_control => '',
		cur_mhz => undef,
		min_mhz => undef,
		max_mhz => undef,
		hardware_max_mhz => undef,
	};
	return $cpu unless @policy;
	my $first = $policy[0];
	$cpu->{'governor'} = &power_read("$first/scaling_governor");
	$cpu->{'governors'} = [ grep { length } split /\s+/, &power_read("$first/scaling_available_governors") ];
	$cpu->{'driver'} = &power_read("$first/scaling_driver");
	$cpu->{'epp'} = &power_read("$first/energy_performance_preference");
	$cpu->{'epp_available'} = [ grep { length } split /\s+/, &power_read("$first/energy_performance_available_preferences") ];
	my $root = &power_sysfs_root();
	my $no_turbo = "$root/devices/system/cpu/intel_pstate/no_turbo";
	my $boost = "$root/devices/system/cpu/cpufreq/boost";
	if (-e $no_turbo) {
		$cpu->{'turbo_control'} = 'intel_pstate/no_turbo';
		$cpu->{'turbo'} = &power_read($no_turbo) eq '1' ? 0 : 1;
	}
	elsif (-e $boost) {
		$cpu->{'turbo_control'} = 'cpufreq/boost';
		$cpu->{'turbo'} = &power_read($boost) eq '0' ? 0 : 1;
	}
	my ($cur, $n, $min, $max, $hardware_max);
	for my $dir (@policy) {
		my $khz = &power_number("$dir/scaling_cur_freq");
		if (defined $khz && $khz > 0) { $cur += $khz; $n++; }
		my $policy_min = &power_number("$dir/scaling_min_freq");
		$policy_min = &power_number("$dir/cpuinfo_min_freq") unless defined $policy_min;
		if (defined $policy_min) { $min = $policy_min if !defined $min || $policy_min < $min; }
		my $policy_max = &power_number("$dir/scaling_max_freq");
		$policy_max = &power_number("$dir/cpuinfo_max_freq") unless defined $policy_max;
		if (defined $policy_max) { $max = $policy_max if !defined $max || $policy_max > $max; }
		my $hard = &power_number("$dir/cpuinfo_max_freq");
		if (defined $hard) { $hardware_max = $hard if !defined $hardware_max || $hard > $hardware_max; }
	}
	$cpu->{'cur_mhz'} = $n ? int(($cur / $n) / 1000 + 0.5) : undef;
	$cpu->{'min_mhz'} = &power_mhz($min);
	$cpu->{'max_mhz'} = &power_mhz($max);
	$cpu->{'hardware_max_mhz'} = &power_mhz($hardware_max);
	return $cpu;
}

sub power_plan_options {
	return [ map { {
		id => $_,
		governor => $power_plan_defaults{$_}->{'epp'} ? $power_plan_defaults{$_}->{'governors'}->[0] : '',
		epp => $power_plan_defaults{$_}->{'epp'},
		turbo => $power_plan_defaults{$_}->{'turbo'},
	} } qw(auto saver balanced performance) ];
}

sub power_default_config {
	return {
		auto => 1,
		ac => { plan => 'balanced', limit => 100 },
		battery => { plan => 'saver', limit => 70 },
		sleep => {
			screen_timeout => 0,
			sleep_timeout => 0,
			lid_action => 'suspend',
			sleep_type => 'suspend',
		},
		profiles => {},
	};
}

sub power_config_clean {
	my ($config) = @_;
	my $clean = &power_default_config();
	return $clean unless ref $config eq 'HASH';
	$clean->{'auto'} = $config->{'auto'} ? 1 : 0 if exists $config->{'auto'};
	for my $source (qw(ac battery)) {
		my $entry = $config->{$source};
		next unless ref $entry eq 'HASH';
		$clean->{$source}->{'plan'} = $entry->{'plan'} if &power_plan_valid($entry->{'plan'});
		$clean->{$source}->{'limit'} = &power_limit_round($entry->{'limit'}) if exists $entry->{'limit'};
	}
	my $sleep = $config->{'sleep'};
	if (ref $sleep eq 'HASH') {
		$clean->{'sleep'}->{'screen_timeout'} = $sleep->{'screen_timeout'} + 0
			if exists $sleep->{'screen_timeout'} && &power_timeout_valid($sleep->{'screen_timeout'}, \@power_screen_timeouts);
		$clean->{'sleep'}->{'sleep_timeout'} = $sleep->{'sleep_timeout'} + 0
			if exists $sleep->{'sleep_timeout'} && &power_timeout_valid($sleep->{'sleep_timeout'}, \@power_sleep_timeouts);
		$clean->{'sleep'}->{'lid_action'} = $sleep->{'lid_action'}
			if &power_lid_action_valid($sleep->{'lid_action'});
		$clean->{'sleep'}->{'sleep_type'} = $sleep->{'sleep_type'}
			if &power_sleep_type_valid($sleep->{'sleep_type'});
	}
	# A profile is only present when the person changed it. Each kept block is
	# complete: the fallback fills any key the profile did not name.
	my $profiles = $config->{'profiles'};
	if (ref $profiles eq 'HASH') {
		for my $plan (keys %{$profiles}) {
			next unless &power_plan_valid($plan);
			my $entry = $profiles->{$plan};
			next unless ref $entry eq 'HASH';
			my $block = { %{ $clean->{'sleep'} } };
			$block->{'screen_timeout'} = $entry->{'screen_timeout'} + 0
				if exists $entry->{'screen_timeout'} && &power_timeout_valid($entry->{'screen_timeout'}, \@power_screen_timeouts);
			$block->{'sleep_timeout'} = $entry->{'sleep_timeout'} + 0
				if exists $entry->{'sleep_timeout'} && &power_timeout_valid($entry->{'sleep_timeout'}, \@power_sleep_timeouts);
			$block->{'lid_action'} = $entry->{'lid_action'}
				if &power_lid_action_valid($entry->{'lid_action'});
			$block->{'sleep_type'} = $entry->{'sleep_type'}
				if &power_sleep_type_valid($entry->{'sleep_type'});
			$clean->{'profiles'}{$plan} = $block;
		}
	}
	return $clean;
}

sub power_config {
	my $file = $ENV{'JAWNOS_POWER_CONFIG_FILE'};
	if (defined $file && length $file) {
		my $text = eval { read_file($file) };
		my $stored = $text ? eval { decode_json($text) } : undef;
		return &power_config_clean($stored);
	}
	my $stored = &subs::cache_get({ app => 'power', context => 'config' });
	return &power_config_clean($stored);
}

sub power_config_save {
	my ($config) = @_;
	my $clean = &power_config_clean($config);
	my $file = $ENV{'JAWNOS_POWER_CONFIG_FILE'};
	if (defined $file && length $file) {
		eval { write_file($file, encode_json($clean)) };
		return $clean;
	}
	&subs::cache_set({ app => 'power', context => 'config', warranty => '-1y' }, $clean);
	return $clean;
}

sub power_last_applied {
	my $file = $ENV{'JAWNOS_POWER_STATE_FILE'};
	if (defined $file && length $file) {
		my $text = eval { read_file($file) };
		my $stored = $text ? eval { decode_json($text) } : undef;
		return ref $stored eq 'HASH' ? $stored : {};
	}
	my $stored = &subs::cache_get({ app => 'power', context => 'applied' });
	return ref $stored eq 'HASH' ? $stored : {};
}

sub power_last_applied_save {
	my ($state) = @_;
	my $file = $ENV{'JAWNOS_POWER_STATE_FILE'};
	if (defined $file && length $file) {
		eval { write_file($file, encode_json($state)) };
		return $state;
	}
	&subs::cache_set({ app => 'power', context => 'applied', warranty => '-1y' }, $state);
	return $state;
}

# Whether a lid switch exists. /proc/acpi/button/lid/<device>/state is the
# kernel's own answer; a machine without one has no lid and no row to show.
sub power_lid_present {
	my $proc = $ENV{'JAWNOS_POWER_PROC'} || '/proc';
	$proc =~ s{/+$}{};
	$proc = '/' if $proc eq '';
	my @state = grep { -e } glob("$proc/acpi/button/lid/*/state");
	return @state ? 1 : 0;
}

# The sleep states this machine can enter. /sys/power/state names what the
# kernel offers; systemctl is the door we use, so a machine without it offers
# none. mem or freeze suspend; disk hibernates. Hybrid needs both.
sub power_supported_sleep_types {
	my $root = &power_sysfs_root();
	my %has = map { $_ => 1 } grep { length } split /\s+/, &power_read("$root/power/state");
	return () unless &power_command_path('systemctl');
	my @types;
	push @types, 'suspend' if $has{'mem'} || $has{'freeze'};
	push @types, 'hibernate' if $has{'disk'};
	push @types, 'hybrid_sleep' if $has{'disk'} && ($has{'mem'} || $has{'freeze'});
	push @types, 'suspend_then_hibernate' if $has{'disk'} && ($has{'mem'} || $has{'freeze'});
	return @types;
}

# The screen timer owns an X or GNOME session rather than the kernel. Report
# the method the helper will use, and never claim one when neither exists.
sub power_screen_support {
	return { supported => 1, method => 'gsettings' } if &power_command_path('gsettings');
	return { supported => 1, method => 'xset' } if &power_command_path('xset') && length($ENV{'DISPLAY'} || '');
	return { supported => 0, method => '', reason => 'no gsettings or xset with a display was found' };
}

sub power_sleep_capabilities {
	my @types = &power_supported_sleep_types();
	return {
		lid => &power_lid_present() ? 1 : 0,
		types => \@types,
		screen => &power_screen_support(),
		systemd => &power_command_path('systemctl') ? 1 : 0,
	};
}

# The helper is the only writer. A direct run works on a machine whose cpufreq
# files the user owns; a refusal marked needs_sudo is retried through `sudo -n`,
# which the live image is set up to allow without a prompt.
sub power_helper {
	my (@args) = @_;
	my $script = $ENV{'JAWNOS_POWER_HELPER'} || 'scripts/jawnos_power.pl';
	return { ok => 0, error => 'the power helper is missing' } unless -e $script;
	# A scoped sudoers rule can only name an absolute path; the manager's cwd
	# is the tree root, so the relative default resolves to one.
	$script = Cwd::abs_path($script) || $script;
	my @command = ($^X, $script, @args);
	if ($ENV{'JAWNOS_POWER_DRY_RUN'}) {
		return { ok => 1, dry_run => 1, command => \@command };
	}
	my $answer = &power_helper_run(\@command);
	if (ref $answer eq 'HASH' && !$answer->{'ok'}
		&& (($answer->{'error'} || '') eq 'permission' || $answer->{'needs_sudo'})) {
		my $sudo = &power_command_path('sudo');
		if ($sudo) {
			my $retry = &power_helper_run([$sudo, '-n', @command]);
			$retry->{'sudo'} = 1 if ref $retry eq 'HASH';
			return $retry if ref $retry eq 'HASH';
		}
	}
	return $answer;
}

sub power_helper_run {
	my ($command) = @_;
	my $run = eval {
		&subs::subprocessor_command($command, {
			name => 'power helper',
			stdout => 'capture',
			stderr => 'inherit',
			warranty => '20s',
		});
	};
	return { ok => 0, error => 'the power helper could not start' } unless ref $run eq 'HASH' && $run->{'pid'};
	my $answer = eval { decode_json($run->{'output'} // '') };
	return $answer if ref $answer eq 'HASH';
	return { ok => 0, error => 'the power helper did not return a readable answer' };
}

sub power_plans_for_source {
	my ($config, $source) = @_;
	my $entry = $config->{$source} || {};
	return {
		plan => &power_plan_valid($entry->{'plan'}) ? $entry->{'plan'} : 'balanced',
		limit => &power_limit_round($entry->{'limit'}),
	};
}

sub power_apply_plan {
	my ($source, $plan, $limit) = @_;
	$source = 'battery' unless defined $source && $source eq 'ac';
	$plan = 'auto' unless &power_plan_valid($plan);
	$limit = &power_limit_round($limit);
	my $answer;
	my @policy = &power_cpu_policies();
	my $writable = scalar grep { -w "$_/scaling_governor" } @policy;
	my $mobile = (&subs::device_setter() || '') eq 'mobile';
	if ($mobile && !$writable) {
		# Android exposes no public CPU-governor API, and the app's bridge has
		# no performance-mode method yet. A phone is told the truth instead of
		# being sent a call nothing answers.
		$answer = { ok => 0, supported => 0, error => '', bridge => 1, plan => $plan, limit => $limit };
	}
	else {
		$answer = &power_helper('apply', $plan, $limit);
	}
	my $state = {
		at => &subs::rightNow(),
		source => $source,
		plan => $plan,
		limit => $limit,
		boot => &power_boot_id(),
		ok => $answer->{'ok'} ? 1 : 0,
		error => $answer->{'error'} || '',
		supported => exists $answer->{'supported'} ? ($answer->{'supported'} ? 1 : 0) : 1,
	};
	&power_last_applied_save($state);
	my %result = (%{$answer}, source => $source, plan => $plan, limit => $limit);
	# A real plan also switches that profile's timers and lid rule, and stops
	# the competing daemon. Auto leaves both alone: auto means the machine (or
	# auto-cpufreq) keeps its own schedule, so there is nothing to race. A
	# failed sleep write never changes the plan's own verdict.
	if ($plan ne 'auto') {
		my ($sleep_answer, $ignored) = &power_sleep_write(
			&power_sleep_block(&power_config(), $plan),
		);
		$result{'sleep'} = { %{$sleep_answer}, plan => $plan, sleep_ignored => $ignored };
		$result{'takeover'} = &power_takeover();
	}
	return \%result;
}

sub power_plan_set {
	my ($source, $plan, $limit) = @_;
	return { ok => 0, error => 'unknown source' } unless defined $source && ($source eq 'ac' || $source eq 'battery');
	return { ok => 0, error => 'unknown plan' } unless &power_plan_valid($plan);
	my $config = &power_config();
	$config->{$source} = { plan => $plan, limit => &power_limit_round($limit) };
	$config = &power_config_save($config);
	my $status = &power_status();
	my $applied;
	$applied = &power_apply_plan($source, $plan, $limit)
		if ($status->{'source'} || '') eq $source;
	return { ok => 1, config => $config, applied => $applied };
}

sub power_auto_set {
	my ($on) = @_;
	my $config = &power_config();
	$config->{'auto'} = $on ? 1 : 0;
	$config = &power_config_save($config);
	return { ok => 1, config => $config };
}

sub power_apply_current {
	my $status = &power_status();
	my $source = ($status->{'source'} || '') eq 'ac' ? 'ac' : 'battery';
	my $wanted = &power_plans_for_source(&power_config(), $source);
	return &power_apply_plan($source, $wanted->{'plan'}, $wanted->{'limit'});
}

# The sleep rules a plan runs with: its own block when the person changed it,
# otherwise the top-level block every plan falls back to.
sub power_sleep_block {
	my ($config, $plan) = @_;
	$config = &power_config() unless ref $config eq 'HASH';
	my $profiles = ref $config->{'profiles'} eq 'HASH' ? $config->{'profiles'} : {};
	my $block = $profiles->{$plan};
	$block = $config->{'sleep'} unless ref $block eq 'HASH';
	return { %{ $block || {} } };
}

# One write through the helper, shared by the global block and a profile block.
# A machine with no sleep state cannot honour a sleep timer; write 0 instead of
# asking logind to enter a state this kernel does not offer.
sub power_sleep_write {
	my ($block, $capabilities) = @_;
	$capabilities = &power_sleep_capabilities() unless ref $capabilities eq 'HASH';
	my $types = ref $capabilities->{'types'} eq 'ARRAY' ? $capabilities->{'types'} : [];
	my $effective_sleep = @{$types} ? $block->{'sleep_timeout'} : 0;
	my $answer = &power_helper(
		'settings',
		$block->{'screen_timeout'},
		$effective_sleep,
		$block->{'lid_action'},
		$block->{'sleep_type'},
	);
	return ($answer, $effective_sleep == $block->{'sleep_timeout'} ? 0 : 1);
}

# Save the sleep and display block. Every supplied value is checked before it
# is stored, and a sleep state the machine cannot enter is refused rather than
# saved and reported as applied. With a plan, the block belongs to that profile
# and is written to the machine only when that plan is the one in effect.
sub power_sleep_set {
	my ($params) = @_;
	$params = {} unless ref $params eq 'HASH';
	my $config = &power_config();
	my $plan = defined $params->{'plan'} ? $params->{'plan'} : '';
	my $per_plan = &power_plan_valid($plan);
	my $sleep = $per_plan ? &power_sleep_block($config, $plan) : { %{ $config->{'sleep'} } };
	if (exists $params->{'screen_timeout'}) {
		return { ok => 0, error => 'unknown screen timeout' }
			unless &power_timeout_valid($params->{'screen_timeout'}, \@power_screen_timeouts);
		$sleep->{'screen_timeout'} = $params->{'screen_timeout'} + 0;
	}
	if (exists $params->{'sleep_timeout'}) {
		return { ok => 0, error => 'unknown sleep timeout' }
			unless &power_timeout_valid($params->{'sleep_timeout'}, \@power_sleep_timeouts);
		$sleep->{'sleep_timeout'} = $params->{'sleep_timeout'} + 0;
	}
	if (exists $params->{'lid_action'}) {
		return { ok => 0, error => 'unknown lid action' } unless &power_lid_action_valid($params->{'lid_action'});
		$sleep->{'lid_action'} = $params->{'lid_action'};
	}
	my $capabilities = &power_sleep_capabilities();
	if (exists $params->{'sleep_type'}) {
		my $type = $params->{'sleep_type'};
		return { ok => 0, error => 'unknown sleep type' } unless &power_sleep_type_valid($type);
		return { ok => 0, supported => 0, error => 'this machine cannot ' . $type, capabilities => $capabilities }
			unless grep { $_ eq $type } @{$capabilities->{'types'}};
		$sleep->{'sleep_type'} = $type;
	}
	if ($per_plan) {
		$config->{'profiles'}{$plan} = $sleep;
	}
	else {
		$config->{'sleep'} = $sleep;
	}
	$config = &power_config_save($config);
	# A profile that is not the one the machine is on is only stored: its timers
	# take effect when the plan does.
	my $in_effect = 1;
	if ($per_plan) {
		my $source = (&power_status()->{'source'} || '') eq 'ac' ? 'ac' : 'battery';
		$in_effect = (($config->{$source}{'plan'} || '') eq $plan) ? 1 : 0;
	}
	return {
		ok => 1,
		config => $config,
		capabilities => $capabilities,
		applied => undef,
		sleep_ignored => 0,
	} unless $in_effect;
	my ($answer, $ignored) = &power_sleep_write($sleep, $capabilities);
	return {
		%{$answer},
		ok => $answer->{'ok'} ? 1 : 0,
		config => $config,
		applied => $answer,
		capabilities => $capabilities,
		sleep_ignored => $ignored,
	};
}

sub power_sleep_now {
	my ($type) = @_;
	$type = 'suspend' unless defined $type && length $type;
	return { ok => 0, error => 'unknown sleep type' } unless &power_sleep_type_valid($type);
	my $capabilities = &power_sleep_capabilities();
	return { ok => 0, supported => 0, error => 'this machine cannot ' . $type, capabilities => $capabilities }
		unless grep { $_ eq $type } @{$capabilities->{'types'}};
	return { %{ &power_helper('sleep', $type) }, type => $type };
}

# The slow loop's turn: when the cable changes, the plan saved for that source
# is applied once. The saved "last applied" row is what makes this idempotent -
# every poll after the first is a no-op, so a 30-second tick cannot rewrite sysfs
# forever.
#
# That row survives a reboot, but the kernel's own governor does not, so a row
# from an earlier boot is not evidence that the machine still holds the plan.
# When the boot id changes, take the saved plan back once even with automatic
# switching off: a reboot is not a plan switch. The same-boot dedupe below still
# keeps the minute tick from rewriting sysfs.
sub power_plan_tick {
	my $config = &power_config();
	my $battery = &power_battery_read();
	return { ok => 1, skipped => 'no battery' } unless $battery->{'present'};
	my $source = $battery->{'ac'} ? 'ac' : 'battery';
	my $wanted = &power_plans_for_source($config, $source);
	my $last = &power_last_applied();
	my $boot = &power_boot_id();
	return &power_apply_plan($source, $wanted->{'plan'}, $wanted->{'limit'})
		if length $boot && (($last->{'boot'} // '') ne $boot);
	return { ok => 1, skipped => 'auto is off' } unless $config->{'auto'};
	return { ok => 1, skipped => 'already applied' }
		if $last->{'ok'} && ($last->{'source'} || '') eq $source
			&& ($last->{'plan'} || '') eq $wanted->{'plan'}
			&& ($last->{'limit'} || 0) == $wanted->{'limit'};
	return &power_apply_plan($source, $wanted->{'plan'}, $wanted->{'limit'});
}

# The laptop battery's own charge ceiling. Not every pack exposes one, so a
# machine without charge_control_end_threshold reports unsupported rather than
# offering a control that writes nowhere.
sub power_charge_read {
	my $root = &power_sysfs_root();
	my @supply = grep { -d } glob("$root/class/power_supply/*");
	my ($battery) = grep {
		my $type = lc(&power_read("$_/type"));
		$type eq 'battery' || -e "$_/capacity";
	} @supply;
	return { supported => 0 } unless $battery;
	my $path = "$battery/charge_control_end_threshold";
	return { supported => 0 } unless -e $path;
	my $end = &power_number($path);
	return { supported => 0 } unless defined $end;
	return { supported => 1, end => $end, min => 50, max => 100, path => $path };
}

sub power_charge_set {
	my ($end) = @_;
	return { ok => 0, error => 'the charge limit must be between 50 and 100' }
		unless defined $end && $end =~ /^\d+$/ && $end >= 50 && $end <= 100;
	my $answer = &power_helper('charge', $end);
	return { %{$answer}, charge => &power_charge_read() };
}

# Once JawnOS writes the CPU and the sleep rules, a second daemon re-applying
# its own profile is two writers racing, so a real plan stops
# power-profiles-daemon, tlp and auto-cpufreq. Plan auto leaves them alone:
# auto means they stay in charge.
sub power_takeover {
	return &power_helper('takeover');
}

# Who is writing the CPU and sleep knobs. JawnOS applies a plan for the current
# source; a competing daemon (power-profiles-daemon, TLP or auto-cpufreq) may
# still be running, and Auto deliberately leaves it in charge.
sub power_manager {
	return &power_helper('manager');
}

sub power_status {
	my $battery = &power_battery_read();
	my $config = &power_config();
	my $cpu = &power_cpu_read();
	my $source = $battery->{'ac'} ? 'ac' : 'battery';
	return {
		ok => 1,
		at => &subs::rightNow(),
		platform => &power_platform(),
		machine => &subs::device_setter() || '',
		source => $source,
		ac => $battery->{'ac'} ? 1 : 0,
		battery => $battery,
		cpu => $cpu,
		config => $config,
		plans => &power_plan_options(),
		applied => &power_last_applied(),
		sleep => &power_sleep_capabilities(),
		manager => &power_manager(),
		sleep_plan => &power_plan_valid($config->{$source}{'plan'}) ? $config->{$source}{'plan'} : 'balanced',
		charge => &power_charge_read(),
	};
}
