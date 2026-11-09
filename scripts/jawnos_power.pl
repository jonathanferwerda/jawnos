#!/usr/bin/perl
#
# jawnos_power.pl - the fixed command set behind the Power app.
#
# The manager calls this with an argument list (never a shell) and encodes the
# answer as JSON. Every subcommand validates its own arguments, so a request
# value cannot become part of a command. The helper is the only code that writes
# /sys; a machine whose cpufreq files are root-owned runs it through `sudo -n`,
# which is how the live image's passwordless sudo is meant to be used.
#
#   status
#   apply <plan> <limit>       plan is auto|saver|balanced|performance
#
# Every answer is a JSON object. A machine with no cpufreq control answers
# { ok => 1, supported => 0, reason => ... } rather than failing: "this machine
# cannot change its CPU speed" is a fact about the machine, not a broken request.

use strict;
use warnings;
use Cwd ();
use JSON::PP ();

my $ROOT = $ENV{'JAWNOS_POWER_SYSFS'} || '/sys';
$ROOT =~ s{/+$}{};
$ROOT = '/' if $ROOT eq '';

my $JSON = JSON::PP->new->utf8(1)->canonical(1);

# What each plan asks the machine to do. The governor list is a preference
# order: the first one this kernel offers wins, so the same plan works on an
# Intel laptop (intel_pstate), an AMD one (amd-pstate) and an ARM handheld.
# `auto` deliberately writes nothing - the kernel, or auto-cpufreq when it is
# installed, stays in charge.
my %PLAN = (
	auto => {
		governors => [],
		epp => '',
		turbo => undef,
	},
	saver => {
		governors => [qw(powersave conservative ondemand schedutil)],
		epp => 'power',
		turbo => 0,
	},
	balanced => {
		governors => [qw(schedutil ondemand powersave performance)],
		epp => 'balance_performance',
		turbo => 1,
	},
	performance => {
		governors => [qw(performance schedutil ondemand powersave)],
		epp => 'performance',
		turbo => 1,
	},
);

sub emit {
	my ($data) = @_;
	print $JSON->encode($data);
	exit 0;
}

sub failure {
	my ($message) = @_;
	emit({ ok => 0, error => clean($message) || 'The power request failed.' });
}

sub clean {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return substr($text, 0, 300);
}

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

sub trim {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

sub number {
	my ($path) = @_;
	my $value = trim(slurp($path));
	return undef unless $value =~ /^-?\d+(?:\.\d+)?$/;
	return $value + 0;
}

sub mhz {
	my ($khz) = @_;
	return undef unless defined $khz;
	return int($khz / 1000 + 0.5) / 1000;
}

# A policy is one clock domain: policy0 on most kernels, cpu0/cpufreq on older
# ones. Both shapes are read, and a duplicate device is skipped by realpath.
sub policies {
	my @dirs = grep { -d } glob("$ROOT/devices/system/cpu/cpufreq/policy*");
	@dirs = grep { -d } glob("$ROOT/devices/system/cpu/cpu*/cpufreq") unless @dirs;
	my (%seen, @out);
	for my $dir (@dirs) {
		my $real = eval { Cwd::realpath($dir) } || $dir;
		next if $seen{$real}++;
		push @out, $dir;
	}
	return @out;
}

sub cpu_snapshot {
	my @policy = policies();
	my $first = $policy[0];
	my $snapshot = {
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
	return $snapshot unless @policy;
	$snapshot->{'governor'} = trim(slurp("$first/scaling_governor"));
	$snapshot->{'governors'} = [ grep { length } split /\s+/, trim(slurp("$first/scaling_available_governors")) ];
	$snapshot->{'driver'} = trim(slurp("$first/scaling_driver"));
	$snapshot->{'epp'} = trim(slurp("$first/energy_performance_preference"));
	$snapshot->{'epp_available'} = [ grep { length } split /\s+/, trim(slurp("$first/energy_performance_available_preferences")) ];
	my $no_turbo = "$ROOT/devices/system/cpu/intel_pstate/no_turbo";
	my $boost = "$ROOT/devices/system/cpu/cpufreq/boost";
	if (-e $no_turbo) {
		$snapshot->{'turbo_control'} = 'intel_pstate/no_turbo';
		$snapshot->{'turbo'} = (trim(slurp($no_turbo)) eq '1') ? 0 : 1;
	}
	elsif (-e $boost) {
		$snapshot->{'turbo_control'} = 'cpufreq/boost';
		$snapshot->{'turbo'} = (trim(slurp($boost)) eq '0') ? 0 : 1;
	}
	my ($cur, $n, $min, $max, $hardware_max) = (0, 0);
	for my $dir (@policy) {
		my $khz = number("$dir/scaling_cur_freq");
		if (defined $khz && $khz > 0) { $cur += $khz; $n++; }
		my $policy_min = number("$dir/scaling_min_freq");
		$policy_min = number("$dir/cpuinfo_min_freq") unless defined $policy_min;
		if (defined $policy_min) { $min = $policy_min if !defined $min || $policy_min < $min; }
		my $policy_max = number("$dir/scaling_max_freq");
		$policy_max = number("$dir/cpuinfo_max_freq") unless defined $policy_max;
		if (defined $policy_max) { $max = $policy_max if !defined $max || $policy_max > $max; }
		my $hard = number("$dir/cpuinfo_max_freq");
		if (defined $hard) { $hardware_max = $hard if !defined $hardware_max || $hard > $hardware_max; }
	}
	$snapshot->{'cur_mhz'} = $n ? int(($cur / $n) / 1000 + 0.5) / 1000 : undef;
	$snapshot->{'min_mhz'} = mhz($min);
	$snapshot->{'max_mhz'} = mhz($max);
	$snapshot->{'hardware_max_mhz'} = mhz($hardware_max);
	return $snapshot;
}

sub pick_governor {
	my ($want, $available) = @_;
	my %has = map { $_ => 1 } @{$available};
	for my $name (@{$want}) {
		return $name if $has{$name};
	}
	return '';
}

sub epp_supported {
	my ($want, $available) = @_;
	return 0 unless defined $want && length $want;
	my %has = map { $_ => 1 } @{$available};
	return $has{$want} ? 1 : 0;
}

# Turn the plan and the speed limit into the exact set of files to write. This
# is separated from the writes so `apply` can refuse a partly-writable machine
# before it changes half the system.
sub plan_writes {
	my ($plan_name, $limit, $snapshot) = @_;
	my @policy = policies();
	my $plan = $PLAN{$plan_name};
	my @writes;
	my $governor = pick_governor($plan->{'governors'}, $snapshot->{'governors'});
	if (length $governor) {
		for my $dir (@policy) {
			push @writes, { path => "$dir/scaling_governor", value => $governor, kind => 'governor' };
		}
	}
	my $epp = '';
	if ($plan->{'epp'} && epp_supported($plan->{'epp'}, $snapshot->{'epp_available'})) {
		$epp = $plan->{'epp'};
		for my $dir (@policy) {
			next unless -e "$dir/energy_performance_preference";
			push @writes, { path => "$dir/energy_performance_preference", value => $epp, kind => 'epp' };
		}
	}
	my $turbo = '';
	if (defined $plan->{'turbo'} && length $snapshot->{'turbo_control'}) {
		$turbo = $plan->{'turbo'};
		if ($snapshot->{'turbo_control'} eq 'intel_pstate/no_turbo') {
			push @writes, { path => "$ROOT/devices/system/cpu/intel_pstate/no_turbo", value => ($turbo ? '0' : '1'), kind => 'turbo' };
		}
		else {
			push @writes, { path => "$ROOT/devices/system/cpu/cpufreq/boost", value => ($turbo ? '1' : '0'), kind => 'turbo' };
		}
	}
	my $max_khz;
	for my $dir (@policy) {
		my $min = number("$dir/cpuinfo_min_freq");
		$min = number("$dir/scaling_min_freq") unless defined $min;
		my $max = number("$dir/cpuinfo_max_freq");
		$max = number("$dir/scaling_max_freq") unless defined $max;
		next unless defined $min && defined $max && $max > 0;
		my $wanted = $min + int(($max - $min) * $limit / 100);
		$wanted = $max if $limit >= 100 || $wanted > $max;
		$wanted = $min if $wanted < $min;
		push @writes, { path => "$dir/scaling_max_freq", value => $wanted, kind => 'limit' };
		$max_khz = $wanted if !defined $max_khz || $wanted > $max_khz;
	}
	return (\@writes, $governor, $epp, $turbo, $max_khz);
}

sub write_value {
	my ($path, $value) = @_;
	open my $fh, '>', $path or return 0;
	print {$fh} $value . "\n";
	close $fh;
	return 1;
}

sub apply {
	my ($plan_name, $limit) = @_;
	$plan_name = '' unless defined $plan_name;
	$limit = '' unless defined $limit;
	return failure('unknown plan') unless $PLAN{$plan_name};
	return failure('the speed limit must be 25 to 100') unless $limit =~ /^\d+$/ && $limit >= 25 && $limit <= 100;
	$limit += 0;

	my $snapshot = cpu_snapshot();
	return emit({
		ok => 1,
		supported => 0,
		plan => $plan_name,
		limit => $limit,
		reason => 'this machine has no cpufreq control',
	}) unless $snapshot->{'supported'};

	# Auto is the machine's own choice. Writing nothing is the whole point.
	return emit({
		ok => 1,
		supported => 1,
		plan => 'auto',
		limit => $limit,
		governor => $snapshot->{'governor'},
		epp => $snapshot->{'epp'},
		turbo => $snapshot->{'turbo'},
		cur_mhz => $snapshot->{'cur_mhz'},
		min_mhz => $snapshot->{'min_mhz'},
		max_mhz => $snapshot->{'max_mhz'},
		wrote => 0,
	}) if $plan_name eq 'auto';

	my ($writes, $governor, $epp, $turbo, $max_khz) = plan_writes($plan_name, $limit, $snapshot);
	my @unwritable = grep { !-w $_->{'path'} } @{$writes};
	if (@unwritable) {
		return emit({
			ok => 0,
			error => 'permission',
			needs_sudo => 1,
			targets => [ map { $_->{'path'} } @unwritable ],
		});
	}
	my @failed;
	for my $write ( @{$writes} ) {
		push @failed, $write->{'path'} unless write_value($write->{'path'}, $write->{'value'});
	}
	return failure('could not write: ' . join(', ', @failed)) if @failed;

	# Read the result back rather than claiming what was asked for: a governor
	# the kernel refuses (a policy with a fixed clock, a read-only CPU) would
	# otherwise look applied in the answer.
	my $after = cpu_snapshot();
	return emit({
		ok => 1,
		supported => 1,
		plan => $plan_name,
		limit => $limit,
		governor => $after->{'governor'},
		epp => $after->{'epp'},
		turbo => $after->{'turbo'},
		cur_mhz => $after->{'cur_mhz'},
		min_mhz => $after->{'min_mhz'},
		max_mhz => $after->{'max_mhz'},
		wrote => scalar(@{$writes}),
	});
}

sub status {
	my $snapshot = cpu_snapshot();
	emit({
		ok => 1,
		%{$snapshot},
	});
}

my $command = shift @ARGV // 'status';
if ($command eq 'status') {
	status();
}
elsif ($command eq 'apply') {
	apply(shift @ARGV, shift @ARGV);
}
else {
	failure('unknown command');
}
