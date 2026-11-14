package subs;

# Workers: how many prefork workers each server President starts runs, and the
# range its autoscale supervisor may grow it to. Loaded on demand by
# lib/JawnOS/Domain/Loader.pm.
#
# A pool is one server process, not one HTTP listener: the main server, the
# socket server, the ticket (locker) server, the alarm server, the watch server
# and the two terminal servers each own a pool. Each pool rests at a *minimum*
# and may grow to a *maximum*; the two equal is a fixed pool, and a maximum
# above the minimum is a dynamic one that President's supervisor grows while
# every worker is inside a request and retires again when the pool is quiet
# (perl/President/prefork_autoscale.pl).
#
# The values are per-machine settings, so Configure -> Sys -> Workers can change
# them without editing config.json. They are read when the tree starts, so a
# change lands on the next restart; the range itself is what the running
# supervisor grows and shrinks within. config.json stays the fallback for a
# headless machine: main_workers/main_workers_max keep their old meaning, and
# every pool also reads worker_<pool>_min/worker_<pool>_max.
#
# Nothing here opens the database itself: the callers that have one hand it
# setting_grabber, and a boot that has not opened the database yet simply keeps
# the device default.

use strict;
use warnings;

# 1 worker is the floor: Mojo::Server::Prefork never spawns again at a target of
# zero, so a pool configured for 0 would take its listener and answer nothing.
# 64 is a ceiling for a typo, not a limit anyone should reach on this house.
our $WORKER_MIN = 1;
our $WORKER_MAX = 64;

our @WORKER_POOL_ORDER = qw(main websocket locker alarm watch teletype teletype_ws);

our %WORKER_POOL = (
	main         => { label => 'Main server',          purpose => 'main' },
	websocket    => { label => 'WebSocket server',     purpose => 'websocket' },
	locker       => { label => 'Ticket server',        purpose => 'locker' },
	alarm        => { label => 'Alarm server',         purpose => 'alarm' },
	watch        => { label => 'Watch server',         purpose => 'watch' },
	teletype     => { label => 'Teletype server',      purpose => 'teletype' },
	teletype_ws  => { label => 'Terminal socket server', purpose => 'teletype' },
);

# The resting count and ceiling a pool takes when nothing has overridden it.
# These are the numbers President used to carry inline, kept in one place so the
# panel and the launcher cannot disagree about what "automatic" means. The
# WebSocket, ticket and alarm doors, and the terminal's socket channel, hold
# long-lived connections that a burst cannot shorten, so they rest at one and
# stay there. Main, watch and the teletype shell answer requests, so they may
# grow while every worker is busy.
sub worker_pool_defaults {
	my ($pool, $device) = @_;
	$device = '' unless defined $device;
	if ($pool eq 'main') {
		my $min = $device eq 'controller' ? 2
		        : $device eq 'mobile'     ? 2
		        : $device eq 'server'     ? 4
		        :                           3;
		# A handheld grows by two at most in spirit, but every extra worker is
		# another full copy of the tree: a phone and a controller stay fixed.
		# The watch and teletype pools are dynamic on every device; only the main
		# pool keeps this memory rule because it is the one with several tabs.
		my $max = ($device eq 'mobile' || $device eq 'controller') ? $min : $min + 2;
		return ($min, $max);
	}
	if ($pool eq 'watch') {
		my $min = $device eq 'server' ? 2 : 1;
		return ($min, $min + 2);
	}
	if ($pool eq 'teletype') {
		my $min = $device eq 'mobile' ? 1 : $device eq 'server' ? 3 : 2;
		return ($min, $min + 2);
	}
	return (1, 1);
}

# A count from a form, a config file or a relaxed sync batch. Anything that is
# not a whole number is refused; a real number is held inside the floor and
# ceiling rather than allowed to take a pool to zero.
sub worker_pool_clamp {
	my ($value) = @_;
	return undef unless defined $value;
	$value =~ s/^\s+|\s+$//g;
	return undef unless $value =~ /^\d+$/;
	$value = int($value);
	$value = $WORKER_MIN if $value < $WORKER_MIN;
	$value = $WORKER_MAX if $value > $WORKER_MAX;
	return $value;
}

sub worker_pool_config_value {
	my ($config, $key) = @_;
	return undef unless ref $config eq 'HASH';
	my $raw = $config->{$key};
	return undef unless defined $raw;
	$raw =~ s/^\s+|\s+$//g;
	# 0 meant "choose the device's own default" in config.json's main_workers,
	# and it keeps that meaning for every pool's config fallback. Check it
	# before clamping, which would otherwise turn 0 into the one-worker floor.
	return undef if $raw =~ /^\d+$/ && int($raw) == 0;
	return &worker_pool_clamp($raw);
}

# The range one pool is allowed to use on this machine. The database setting
# wins over config.json, which wins over the device default. Reading never
# writes: a machine that has never opened Sys runs on its defaults.
sub worker_pool_limits {
	my ($pool, %opt) = @_;
	return undef unless exists $WORKER_POOL{$pool};
	my $device = defined $opt{'device'} && length $opt{'device'}
		? $opt{'device'}
		: ((eval { &device_setter() }) || 'computer');
	my $config = $opt{'config'};
	$config = eval { &config_reader() } unless ref $config eq 'HASH';
	$config = {} unless ref $config eq 'HASH';
	my ($default_min, $default_max) = &worker_pool_defaults($pool, $device);
	my $stored = sub {
		my ($name) = @_;
		# Call through the loader even when the sub is not defined yet: a lazy
		# domain map would otherwise make a stored range look absent on the
		# boot that reads it first. The eval covers a database that is not open.
		my $value = eval { &setting_grabber({ app => '__president', setting => $name, device => $device }) };
		return &worker_pool_clamp($value);
	};
	my $min = $stored->('worker_' . $pool . '_min');
	my $max = $stored->('worker_' . $pool . '_max');
	if ($pool eq 'main') {
		$min //= &worker_pool_config_value($config, 'main_workers');
		$max //= &worker_pool_config_value($config, 'main_workers_max');
	}
	$min //= &worker_pool_config_value($config, 'worker_' . $pool . '_min');
	$max //= &worker_pool_config_value($config, 'worker_' . $pool . '_max');
	$min = $default_min unless defined $min;
	$max = $default_max unless defined $max;
	$min = $WORKER_MIN if $min < $WORKER_MIN;
	$max = $WORKER_MIN if $max < $WORKER_MIN;
	$max = $min if $max < $min;
	return {
		min         => $min,
		max         => $max,
		default_min => $default_min,
		default_max => $default_max,
		device      => $device,
	};
}

# Every pool, with the range this machine will actually use, in the order the
# panel draws them.
sub worker_pools {
	my (%opt) = @_;
	my @rows;
	foreach my $pool ( @WORKER_POOL_ORDER ) {
		my $limits = &worker_pool_limits($pool, %opt);
		push @rows, {
			key   => $pool,
			label => $WORKER_POOL{$pool}->{'label'},
			%{$limits},
		};
	}
	return \@rows;
}

# Save one side of a range. The side the person touched wins, and the other is
# moved only as far as it must be to keep minimum <= maximum. Both rows are
# written so the panel, a restart and a sync all read the same range.
sub worker_pool_setting_save {
	my (%arg) = @_;
	my $pool = $arg{'pool'} // '';
	return { ok => 0, error => 'unknown worker pool' } unless exists $WORKER_POOL{$pool};
	my $kind = $arg{'kind'} // '';
	return { ok => 0, error => 'unknown worker limit' } unless $kind eq 'min' || $kind eq 'max';
	my $value = &worker_pool_clamp($arg{'value'});
	return { ok => 0, error => 'a worker count is a whole number from 1 to 64' } unless defined $value;
	my $device = defined $arg{'device'} && length $arg{'device'}
		? $arg{'device'}
		: ((eval { &device_setter() }) || 'computer');
	my $limits = &worker_pool_limits($pool, device => $device);
	my ($min, $max) = ($limits->{'min'}, $limits->{'max'});
	if ($kind eq 'min') {
		$min = $value;
		$max = $min if $max < $min;
	}
	else {
		$max = $value;
		$min = $max if $min > $max;
	}
	eval { &setting_setter({ app => '__president', setting => 'worker_' . $pool . '_min', value => $min, device => $device }) };
	eval { &setting_setter({ app => '__president', setting => 'worker_' . $pool . '_max', value => $max, device => $device }) };
	return {
		ok     => 1,
		pool   => $pool,
		kind   => $kind,
		min    => $min,
		max    => $max,
		device => $device,
	};
}

1;
