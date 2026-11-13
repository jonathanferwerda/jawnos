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
#   settings <screen> <sleep> <lid> <type>
#   sleep <type>               type is suspend|hibernate|hybrid_sleep|suspend_then_hibernate
#   charge <end>               end is the battery's charge limit, 50..100
#   takeover                   stop a competing power daemon and disable it
#   restore <json>             put back the daemons a takeover recorded
#   manager                    name the power daemon still running, if any
#
# settings writes one logind drop-in (HandleLidSwitch*, IdleAction*) and sets the
# screen timer through gsettings or xset. sleep runs systemctl with one fixed
# word. Every subcommand validates its own arguments, so a request value cannot
# become part of a command.
#
# Every answer is a JSON object. A machine with no cpufreq control answers
# { ok => 1, supported => 0, reason => ... } rather than failing: "this machine
# cannot change its CPU speed" is a fact about the machine, not a broken request.

use strict;
use warnings;
use Cwd ();
use File::Path ();
use JSON::PP ();

my $ROOT = $ENV{'JAWNOS_POWER_SYSFS'} || '/sys';
$ROOT =~ s{/+$}{};
$ROOT = '/' if $ROOT eq '';

my $ETC = $ENV{'JAWNOS_POWER_ETC'} || '/etc';
$ETC =~ s{/+$}{};
$ETC = '/' if $ETC eq '';

my $DRY = $ENV{'JAWNOS_POWER_DRY_RUN'} ? 1 : 0;

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

# The sleep and display choices. The lists mirror the domain's whitelists; the
# helper validates again so a direct run cannot write a value the app would not.
my @SCREEN_MINUTES = (0, 1, 2, 5, 10, 15, 30);
my @SLEEP_MINUTES = (0, 1, 2, 5, 10, 15, 30, 60);
my %LID_WORD = (
	suspend => 'suspend',
	hibernate => 'hibernate',
	hybrid_sleep => 'hybrid-sleep',
	poweroff => 'poweroff',
	ignore => 'ignore',
);
my %SLEEP_WORD = (
	suspend => 'suspend',
	hibernate => 'hibernate',
	hybrid_sleep => 'hybrid-sleep',
	suspend_then_hibernate => 'suspend-then-hibernate',
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
	return int($khz / 1000 + 0.5);
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
	$snapshot->{'cur_mhz'} = $n ? int(($cur / $n) / 1000 + 0.5) : undef;
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

# The pack's own ceiling. Not every battery exposes one, so a machine without
# charge_control_end_threshold says so instead of offering a write that lands
# nowhere.
sub charge_path {
	my @supply = grep { -d } glob("$ROOT/class/power_supply/*");
	my ($battery) = grep {
		my $type = lc(trim(slurp("$_/type")));
		$type eq 'battery' || -e "$_/capacity";
	} @supply;
	return undef unless $battery;
	my $path = "$battery/charge_control_end_threshold";
	return -e $path ? $path : undef;
}

sub charge {
	my ($end) = @_;
	my $path = charge_path();
	return emit({ ok => 0, supported => 0, reason => 'this battery has no charge threshold' }) unless $path;
	return failure('the charge limit must be between 50 and 100')
		unless defined $end && $end =~ /^\d+$/ && $end >= 50 && $end <= 100;
	$end += 0;
	return emit({ ok => 1, dry_run => 1, write => [ { path => $path, value => $end } ] }) if $DRY;
	# The same all-or-nothing preflight as apply: refuse before writing a byte,
	# so a root-owned attribute reports permission instead of a partial write.
	return emit({
		ok => 0,
		error => 'permission',
		needs_sudo => 1,
		targets => [$path],
	}) unless -w $path;
	return failure('could not write ' . $path) unless write_value($path, $end);
	return emit({ ok => 1, end => $end, path => $path });
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

# An absolute executable from PATH. The name is ours, never a request value.
sub command_path {
	my ($name) = @_;
	for my $dir (split /:/, ($ENV{'PATH'} // '/usr/bin:/bin')) {
		next unless length $dir;
		my $candidate = "$dir/$name";
		return $candidate if -x $candidate;
	}
	return undef;
}

# Run an argument list. exec with a list never involves a shell.
sub run_command {
	my (@args) = @_;
	return { ok => 1, command => \@args, dry_run => 1 } if $DRY;
	my $pid = fork();
	return { ok => 0, error => 'could not start ' . $args[0], command => \@args } unless defined $pid;
	if ($pid == 0) {
		exec { $args[0] } @args;
		exit 127;
	}
	waitpid($pid, 0);
	my $status = $? >> 8;
	return { ok => $status == 0 ? 1 : 0, command => \@args, status => $status };
}

# The daemons that re-apply their own power profile. Once JawnOS writes the CPU
# and the sleep rules, a second daemon doing the same is two writers racing, so
# a real plan asks systemd to stop and disable it. Plan `auto` leaves them
# alone: auto means the machine's own choice stays in charge.
my @TAKEOVER_UNITS = qw(power-profiles-daemon tlp auto-cpufreq);

sub takeover {
	my $systemctl = command_path('systemctl');
	return emit({ ok => 1, supported => 0, reason => 'no systemctl' }) unless $systemctl;
	return emit({
		ok => 1,
		dry_run => 1,
		command => [ map { [$systemctl, 'disable', '--now', $_] } @TAKEOVER_UNITS ],
	}) if $DRY;
	my (@stopped, @failed, @records);
	for my $unit (@TAKEOVER_UNITS) {
		my $active = run_command($systemctl, 'is-active', '--quiet', $unit);
		next unless $active->{'ok'};
		# Record what the daemon was before it is stopped: an enabled unit is
		# enabled and started again, a disabled one is only started. The note
		# outlives this run so a crash can still be undone.
		my $enabled = run_command($systemctl, 'is-enabled', '--quiet', $unit)->{'ok'} ? 1 : 0;
		my $run = run_command($systemctl, 'disable', '--now', $unit);
		if ($run->{'ok'}) {
			push @stopped, $unit;
			push @records, { unit => $unit, enabled => $enabled };
		}
		else { push @failed, $unit; }
	}
	# Disabling a unit is a root operation. Ask for the helper's own sudo retry
	# instead of reporting a failure a passwordless sudo could have fixed; the
	# retry skips the units this pass already stopped.
	return emit({
		ok => 0,
		error => 'permission',
		needs_sudo => 1,
		stopped => \@stopped,
		failed => \@failed,
		records => \@records,
	}) if @failed;
	return emit({ ok => 1, stopped => \@stopped, failed => [], records => \@records });
}

# Put back the daemons a takeover recorded. The list is JSON from the manager
# and every unit name is checked again here; an argument list never reaches a
# shell. A unit that is no longer installed is reported as missing, not as a
# failure, so a removed package cannot keep the ledger alive forever.
sub restore {
	my ($text) = @_;
	my $records = eval { JSON::PP::decode_json($text // '') };
	return failure('unreadable restore list') unless ref $records eq 'ARRAY';
	my @clean = grep {
		ref $_ eq 'HASH' && defined $_->{'unit'} && $_->{'unit'} =~ /^[A-Za-z0-9@._-]+$/
	} @{$records};
	return emit({ ok => 1, restored => [], failed => [], missing => [] }) unless @clean;
	my $systemctl = command_path('systemctl');
	return emit({ ok => 1, supported => 0, reason => 'no systemctl' }) unless $systemctl;
	if ($DRY) {
		return emit({
			ok => 1,
			dry_run => 1,
			command => [ map {
				$_->{'enabled'}
					? [$systemctl, 'enable', '--now', $_->{'unit'}]
					: [$systemctl, 'start', $_->{'unit'}]
			} @clean ],
		});
	}
	my (@restored, @failed, @missing);
	for my $record (@clean) {
		my $unit = $record->{'unit'};
		my $exists = run_command($systemctl, 'cat', '--no-pager', $unit);
		if (!$exists->{'ok'}) { push @missing, $unit; next; }
		my @args = $record->{'enabled'}
			? ($systemctl, 'enable', '--now', $unit)
			: ($systemctl, 'start', $unit);
		my $run = run_command(@args);
		if ($run->{'ok'}) { push @restored, $unit; }
		else { push @failed, $unit; }
	}
	return emit({
		ok => 0,
		error => 'permission',
		needs_sudo => 1,
		restored => \@restored,
		failed => \@failed,
		missing => \@missing,
	}) if @failed;
	return emit({ ok => 1, restored => \@restored, failed => [], missing => \@missing });
}

# Which of the competing daemons is still running. The Power app names the
# manager so a person can tell who is governing the machine, instead of
# guessing after a plan change.
sub manager {
	# A dry run reads nothing: run_command's own dry-run shortcut would make
	# every unit look active, which is the opposite of the truth.
	return emit({ ok => 1, supported => 1, units => [], dry_run => 1 }) if $DRY;
	my $systemctl = command_path('systemctl');
	return emit({ ok => 1, supported => 0, units => [] }) unless $systemctl;
	my @active = grep { run_command($systemctl, 'is-active', '--quiet', $_)->{'ok'} } @TAKEOVER_UNITS;
	emit({ ok => 1, supported => 1, units => \@active });
}

# A logind drop-in is one small file. The docked case is always ignore: the
# lid row is about a real lid, not a dock that reports itself closed.
sub logind_text {
	my ($sleep, $lid, $type) = @_;
	my $idle = $sleep > 0 ? $SLEEP_WORD{$type} : 'ignore';
	my $sec = $sleep > 0 ? $sleep . 'min' : 'infinity';
	my $lidword = $LID_WORD{$lid};
	return join('',
		"# Written by JawnOS Power. This file is replaced when the settings change.\n",
		"[Login]\n",
		"HandleLidSwitch=$lidword\n",
		"HandleLidSwitchExternalPower=$lidword\n",
		"HandleLidSwitchDocked=ignore\n",
		"IdleAction=$idle\n",
		"IdleActionSec=$sec\n",
	);
}

sub write_logind {
	my ($sleep, $lid, $type) = @_;
	my $dir = "$ETC/systemd/logind.conf.d";
	my $path = "$dir/jawnos-power.conf";
	my $text = logind_text($sleep, $lid, $type);
	my $changed = (slurp($path) eq $text) ? 0 : 1;
	my $reloaded = 0;
	if ($changed && !$DRY) {
		eval { File::Path::make_path($dir) };
		open my $fh, '>', $path
			or return { ok => 0, error => 'permission', needs_sudo => 1, path => $path };
		print {$fh} $text;
		close $fh;
		# logind reads its drop-ins at start and on reload; without this a
		# changed lid or idle rule would wait for the next reboot.
		my $systemctl = command_path('systemctl');
		if ($systemctl) {
			my $run = run_command($systemctl, 'reload', 'systemd-logind');
			$reloaded = $run->{'ok'} ? 1 : 0;
		}
	}
	return { ok => 1, path => $path, changed => $changed, reloaded => $reloaded, text => $text };
}

# The screen timer is best effort and must never be claimed when neither tool
# exists. gsettings owns a GNOME session; xset owns an X display.
sub apply_screen {
	my ($minutes) = @_;
	my $sec = $minutes * 60;
	my $gsettings = command_path('gsettings');
	if ($gsettings) {
		my $run = run_command($gsettings, 'set', 'org.gnome.desktop.session', 'idle-delay', $sec);
		return {
			supported => 1,
			method => 'gsettings',
			ok => $run->{'ok'} ? 1 : 0,
			command => $run->{'command'},
			($run->{'dry_run'} ? (dry_run => 1) : ()),
			($run->{'ok'} ? () : (error => 'gsettings could not set the screen delay')),
		};
	}
	my $xset = command_path('xset');
	if ($xset && length($ENV{'DISPLAY'} || '')) {
		my (@commands, $ok);
		$ok = 1;
		for my $args ([$xset, 's', $sec, $sec], [$xset, 'dpms', $sec, $sec, $sec]) {
			my $run = run_command(@{$args});
			push @commands, $run->{'command'};
			$ok = 0 unless $run->{'ok'};
		}
		return {
			supported => 1,
			method => 'xset',
			ok => $ok ? 1 : 0,
			commands => \@commands,
			($DRY ? (dry_run => 1) : ()),
			($ok ? () : (error => 'xset could not set the screen timer')),
		};
	}
	return { supported => 0, method => '', reason => 'no gsettings or xset display control was found' };
}

sub settings {
	my ($screen, $sleep, $lid, $type) = @_;
	return failure('unknown screen timeout')
		unless defined $screen && $screen =~ /^\d+$/ && (grep { $_ == $screen } @SCREEN_MINUTES);
	return failure('unknown sleep timeout')
		unless defined $sleep && $sleep =~ /^\d+$/ && (grep { $_ == $sleep } @SLEEP_MINUTES);
	return failure('unknown lid action') unless defined $lid && exists $LID_WORD{$lid};
	return failure('unknown sleep type') unless defined $type && exists $SLEEP_WORD{$type};

	# Sudo retries the whole helper for the root-owned drop-in; the screen timer
	# belongs to the session user and was already set by the first run.
	my $screen_answer = $ENV{'SUDO_USER'}
		? { supported => 1, skipped => 1, reason => 'the screen timer is set in the session, not as root' }
		: apply_screen($screen);
	my $logind = write_logind($sleep, $lid, $type);
	my %answer = (
		logind => $logind,
		screen => $screen_answer,
		sleep => {
			timeout => $sleep + 0,
			lid_action => $lid,
			sleep_type => $type,
		},
	);
	if ($logind->{'ok'}) {
		$answer{'ok'} = 1;
	}
	else {
		$answer{'ok'} = 0;
		$answer{'error'} = $logind->{'error'} || 'the login settings could not be written';
		$answer{'needs_sudo'} = 1 if $logind->{'needs_sudo'};
	}
	emit(\%answer);
}

sub sleep_now {
	my ($type) = @_;
	return failure('unknown sleep type') unless defined $type && exists $SLEEP_WORD{$type};
	my $systemctl = command_path('systemctl');
	return emit({ ok => 1, supported => 0, reason => 'systemctl is not installed' }) unless $systemctl;
	my $word = $SLEEP_WORD{$type};
	my $run = run_command($systemctl, $word);
	return emit({
		ok => 0,
		supported => 1,
		error => 'systemctl ' . $word . ' failed',
		command => $run->{'command'},
		status => $run->{'status'},
	}) unless $run->{'ok'};
	return emit({
		ok => 1,
		supported => 1,
		type => $type,
		word => $word,
		command => $run->{'command'},
		($run->{'dry_run'} ? (dry_run => 1) : ()),
	});
}

my $command = shift @ARGV // 'status';
if ($command eq 'status') {
	status();
}
elsif ($command eq 'apply') {
	apply(shift @ARGV, shift @ARGV);
}
elsif ($command eq 'settings') {
	settings(shift @ARGV, shift @ARGV, shift @ARGV, shift @ARGV);
}
elsif ($command eq 'sleep') {
	sleep_now(shift @ARGV);
}
elsif ($command eq 'charge') {
	charge(shift @ARGV);
}
elsif ($command eq 'takeover') {
	takeover();
}
elsif ($command eq 'restore') {
	restore(shift @ARGV);
}
elsif ($command eq 'manager') {
	manager();
}
else {
	failure('unknown command');
}
