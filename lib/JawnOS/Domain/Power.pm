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

sub power_number {
	my ($path) = @_;
	my $value = &power_read($path);
	return undef unless $value =~ /^-?\d+(?:\.\d+)?$/;
	return $value + 0;
}

sub power_mhz {
	my ($khz) = @_;
	return undef unless defined $khz;
	return int($khz / 1000 + 0.5) / 1000;
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

# Read the battery directly. On a Linux machine this is cheap and exact; on a
# phone sysfs is often denied, so the bridge's battery.status is the fallback.
# The bridge is not asked on a machine that is plainly not a phone: a desktop
# with no pack should not wait five seconds for a bridge that is not there.
sub power_battery_read {
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
		$b{'voltage'} = defined $volt ? $volt / 1_000_000 : undef;
		my $cur = &power_number("$battery/current_now");
		$b{'current'} = defined $cur ? $cur / 1_000_000 : undef;
		my $pow = &power_number("$battery/power_now");
		$b{'power'} = defined $pow ? $pow / 1_000_000 : undef;
		$b{'energy_now'} = &power_number("$battery/energy_now");
		$b{'energy_full'} = &power_number("$battery/energy_full");
		$b{'charge_now'} = &power_number("$battery/charge_now");
		$b{'charge_full'} = &power_number("$battery/charge_full");
		$b{'ac'} = &power_ac_online(\@supply, \%b) ? 1 : 0;
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
	$cpu->{'cur_mhz'} = $n ? int(($cur / $n) / 1000 + 0.5) / 1000 : undef;
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

# The helper is the only writer. A direct run works on a machine whose cpufreq
# files the user owns; a refusal marked needs_sudo is retried through `sudo -n`,
# which the live image is set up to allow without a prompt.
sub power_helper {
	my (@args) = @_;
	my $script = $ENV{'JAWNOS_POWER_HELPER'} || 'scripts/jawnos_power.pl';
	return { ok => 0, error => 'the power helper is missing' } unless -e $script;
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
		ok => $answer->{'ok'} ? 1 : 0,
		error => $answer->{'error'} || '',
		supported => exists $answer->{'supported'} ? ($answer->{'supported'} ? 1 : 0) : 1,
	};
	&power_last_applied_save($state);
	return { %{$answer}, source => $source, plan => $plan, limit => $limit };
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

# The slow loop's turn: when the cable changes, the plan saved for that source
# is applied once. The saved "last applied" row is what makes this idempotent -
# every poll after the first is a no-op, so a 30-second tick cannot rewrite sysfs
# forever.
sub power_plan_tick {
	my $config = &power_config();
	return { ok => 1, skipped => 'auto is off' } unless $config->{'auto'};
	my $battery = &power_battery_read();
	return { ok => 1, skipped => 'no battery' } unless $battery->{'present'};
	my $source = $battery->{'ac'} ? 'ac' : 'battery';
	my $wanted = &power_plans_for_source($config, $source);
	my $last = &power_last_applied();
	return { ok => 1, skipped => 'already applied' }
		if $last->{'ok'} && ($last->{'source'} || '') eq $source
			&& ($last->{'plan'} || '') eq $wanted->{'plan'}
			&& ($last->{'limit'} || 0) == $wanted->{'limit'};
	return &power_apply_plan($source, $wanted->{'plan'}, $wanted->{'limit'});
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
	};
}
