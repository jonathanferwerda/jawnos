#!/usr/bin/perl
#
# jawnos_bluetooth.pl - the fixed command set behind the Network app's
# Bluetooth tab and the taskbar's Bluetooth glyph.
#
# Manager.pl calls this with an argument list (never a shell), so a device
# address can never become a command. Every subcommand validates its own
# arguments, and a mutation only names one of the actions below.
#
#   status
#   scan on|off
#   power on|off
#   pair <mac>
#   connect <mac>
#   disconnect <mac>
#   trust <mac>
#   remove <mac>
#
# Every answer is a JSON object. An operational failure is { ok => 0, error };
# it is not an exit status, so the caller always gets a readable message.

use strict;
use warnings;
use JSON::PP ();
use Encode qw(decode_utf8);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use IO::Select;

my $JSON = JSON::PP->new->utf8(1)->allow_nonref(1);

sub emit {
	my ($data) = @_;
	print $JSON->encode($data);
	exit 0;
}

sub failure {
	my ($message) = @_;
	emit({ ok => 0, error => clean($message) || 'The Bluetooth request failed.' });
}

sub clean {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\e\[[0-9;]*[A-Za-z]//g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	$text = substr($text, 0, 400);
	return $text;
}

sub trim {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/^\s+|\s+$//g;
	return $text;
}

# bluetoothctl output and argv arrive as bytes. Decode valid UTF-8 so a device
# name with non-ASCII letters comes back as those letters, not as a
# double-encoded copy. Any invalid sequence is left exactly as it came.
sub utf8_text {
	my ($text) = @_;
	return '' unless defined $text;
	my $decoded = eval { decode_utf8($text, 1) };
	return defined $decoded ? $decoded : $text;
}

sub find_command {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	for my $dir ( split /:/, ($ENV{'PATH'} || '') ) {
		next unless length $dir;
		my $path = $dir . '/' . $name;
		return $path if -x $path;
	}
	return undef;
}

# The app and the controller both check this before calling us; the helper
# checks it too, so the fixed command set is safe even when it is run by hand.
sub valid_mac {
	my ($mac) = @_;
	return 0 unless defined $mac;
	return $mac =~ /\A[0-9A-Fa-f:]{17}\z/ ? 1 : 0;
}

sub valid_state {
	my ($state) = @_;
	return 0 unless defined $state;
	return $state =~ /\A(?:on|off)\z/ ? 1 : 0;
}

# A read answers within a few seconds or not at all, so a missing or wedged
# daemon cannot make the app's poll pile up. A pair/connect gets longer: the
# daemon may be waiting on the device to accept the link.
our $capture_timeout = 45;

sub capture {
	my ($input, @command) = @_;
	my $err = gensym;
	my ($in, $out);
	my $pid = eval { open3($in, $out, $err, @command) };
	return ('', 'could not run ' . join(' ', @command), 127) unless $pid;
	if (defined $input) {
		print {$in} $input;
	}
	close $in;
	my $select = IO::Select->new($out, $err);
	my ($stdout, $stderr) = ('', '');
	my $deadline = time() + $capture_timeout;
	while ($select->count) {
		my @ready = $select->can_read(1);
		for my $fh (@ready) {
			my $buffer;
			my $read = sysread($fh, $buffer, 65536);
			if (!defined $read || $read == 0) {
				$select->remove($fh);
				next;
			}
			if (fileno($fh) == fileno($out)) {
				$stdout .= $buffer;
			}
			else {
				$stderr .= $buffer;
			}
		}
		if (time() > $deadline) {
			kill 'TERM', $pid;
			last;
		}
	}
	waitpid($pid, 0);
	my $status = $? >> 8;
	return (utf8_text($stdout), utf8_text($stderr), $status);
}

sub run_read {
	local $capture_timeout = 20;
	my (@command) = @_;
	return capture(undef, @command);
}

sub run_write {
	local $capture_timeout = 60;
	my (@command) = @_;
	return capture(undef, @command);
}

sub bluetooth_tool {
	my $tool = find_command('bluetoothctl');
	return $tool if $tool;
	failure('Bluetooth is not available (bluetoothctl was not found).');
	return undef;
}

# `bluetoothctl show` describes the default adapter. No adapter is a normal
# state on a machine without a radio, not a tool failure, so it comes back as
# present => 0 rather than an error.
sub parse_show {
	my ($text) = @_;
	my %adapter = (
		present      => 0,
		powered      => 0,
		discoverable => 0,
		address      => '',
		name         => '',
	);
	if ($text =~ /^\s*Controller\s+([0-9A-Fa-f:]{17})/m) {
		$adapter{'present'} = 1;
		$adapter{'address'} = $1;
	}
	$adapter{'powered'} = 1      if $text =~ /^\s*Powered:\s*yes\b/m;
	$adapter{'discoverable'} = 1 if $text =~ /^\s*Discoverable:\s*yes\b/m;
	if ($text =~ /^\s*Alias:\s*(.+)$/m) {
		$adapter{'name'} = trim($1);
	}
	elsif ($text =~ /^\s*Name:\s*(.+)$/m) {
		$adapter{'name'} = trim($1);
	}
	return \%adapter;
}

# `bluetoothctl devices` is one "Device <address> <name>" line per known
# device. Two lines may name the same address; the first name wins and the
# list keeps its order.
sub parse_devices {
	my ($text) = @_;
	my (@rows, %seen);
	foreach my $line ( split /\n/, $text ) {
		next unless $line =~ /^\s*Device\s+([0-9A-Fa-f:]{17})\s*(.*)$/;
		my ($address, $name) = ($1, trim($2));
		next if $seen{$address}++;
		push @rows, { address => $address, name => $name };
	}
	return @rows;
}

# `bluetoothctl info <address>` carries the state the lists need. A
# missing field means "no", which is how bluetoothctl leaves an unknown or
# stale device.
sub parse_info {
	my ($text) = @_;
	my %device = (paired => 0, connected => 0, trusted => 0, icon => '', name => '');
	$device{'name'} = trim($1)      if $text =~ /^\s*Alias:\s*(.+)$/m;
	$device{'name'} = trim($1)      if !length($device{'name'}) && $text =~ /^\s*Name:\s*(.+)$/m;
	$device{'icon'} = trim($1)      if $text =~ /^\s*Icon:\s*(.+)$/m;
	$device{'paired'} = 1           if $text =~ /^\s*Paired:\s*yes\b/m;
	$device{'connected'} = 1        if $text =~ /^\s*Connected:\s*yes\b/m;
	$device{'trusted'} = 1          if $text =~ /^\s*Trusted:\s*yes\b/m;
	return \%device;
}

sub bluetooth_status {
	my $tool = bluetooth_tool();
	return undef unless $tool;

	my ($show, $show_err, $show_rc) = run_read($tool, 'show');
	my $adapter = parse_show($show);
	if (!$adapter->{'present'} && $show_rc != 0) {
		my $reason = clean($show_err) || clean($show);
		unless ($reason =~ /no default controller|no controller available/i) {
			return { ok => 0, error => $reason || 'bluetoothctl did not answer.' };
		}
	}

	my @connected;
	my @paired;
	my @found;
	return { ok => 1, adapter => $adapter, connected => [], paired => [], found => [] }
		unless $adapter->{'present'};

	my ($devices, $devices_err, $devices_rc) = run_read($tool, 'devices');
	my @known = parse_devices($devices);
	if ($devices_rc != 0 && !@known) {
		my $reason = clean($devices_err) || clean($devices);
		return { ok => 0, error => $reason || 'bluetoothctl did not answer.' } if $reason;
	}

	# A machine may remember a long list; cap the per-device reads so one
	# status request cannot turn into an unbounded run of subprocesses.
	my $limit = 32;
	for my $entry ( @known ) {
		last if @found >= $limit;
		my ($info, $info_err, $info_rc) = run_read($tool, 'info', $entry->{'address'});
		my $detail = $info_rc == 0 ? parse_info($info) : {};
		my %row = (
			name      => length($detail->{'name'}) ? $detail->{'name'} : $entry->{'name'},
			address   => $entry->{'address'},
			paired    => $detail->{'paired'} ? 1 : 0,
			connected => $detail->{'connected'} ? 1 : 0,
			trusted   => $detail->{'trusted'} ? 1 : 0,
		);
		$row{'icon'} = $detail->{'icon'} if defined $detail->{'icon'} && length $detail->{'icon'};
		push @found, \%row;
		push @connected, \%row if $row{'connected'};
		push @paired, \%row if $row{'paired'};
	}

	return {
		ok        => 1,
		adapter   => $adapter,
		connected => \@connected,
		paired    => \@paired,
		found     => \@found,
	};
}

sub scan_set {
	my ($state) = @_;
	return { ok => 0, error => 'Scanning can only be turned on or off.' } unless valid_state($state);
	my $tool = bluetooth_tool();
	return undef unless $tool;
	# `scan on` otherwise stays attached to the daemon; the timeout makes the
	# call a bounded scan, which is what the Scan button means.
	my (@command) = $state eq 'on'
		? ($tool, '--timeout', '8', 'scan', 'on')
		: ($tool, 'scan', 'off');
	local $capture_timeout = 20;
	my ($out, $err, $rc) = capture(undef, @command);
	return { ok => 1, scanning => $state eq 'on' ? 1 : 0, message => ($state eq 'on' ? 'Scanning.' : 'Stopped scanning.') }
		if $rc == 0;
	return { ok => 0, error => clean($err) || clean($out) || 'bluetoothctl did not answer.' };
}

sub power_set {
	my ($state) = @_;
	return { ok => 0, error => 'The adapter can only be turned on or off.' } unless valid_state($state);
	my $tool = bluetooth_tool();
	return undef unless $tool;
	my ($out, $err, $rc) = run_read($tool, 'power', $state);
	return { ok => 1, powered => $state eq 'on' ? 1 : 0 }
		if $rc == 0;
	return { ok => 0, error => clean($err) || clean($out) || 'bluetoothctl did not answer.' };
}

my %ACTION_LABEL = (
	pair       => 'Paired with %s.',
	connect    => 'Connected to %s.',
	disconnect => 'Disconnected from %s.',
	trust      => 'Trusted %s.',
	remove     => 'Forgot %s.',
);

sub device_action {
	my ($action, $mac) = @_;
	return { ok => 0, error => 'The Bluetooth action is not valid.' }
		unless defined $action && length $action && $ACTION_LABEL{$action};
	return { ok => 0, error => 'That device address is not valid.' } unless valid_mac($mac);
	my $tool = bluetooth_tool();
	return undef unless $tool;
	my ($out, $err, $rc) = run_write($tool, $action, $mac);
	return { ok => 1, message => sprintf($ACTION_LABEL{$action}, $mac) } if $rc == 0;
	return { ok => 0, error => clean($err) || clean($out) || 'bluetoothctl did not answer.' };
}

my $command = shift @ARGV;
$command = '' unless defined $command;

if ($command eq 'status') {
	my $answer = bluetooth_status();
	emit($answer) if ref $answer eq 'HASH';
	failure('The Bluetooth status could not be read.');
}
elsif ($command eq 'scan') {
	emit(scan_set(shift @ARGV));
}
elsif ($command eq 'power') {
	emit(power_set(shift @ARGV));
}
elsif ($ACTION_LABEL{$command}) {
	emit(device_action($command, shift @ARGV));
}
else {
	failure('Unknown Bluetooth command.');
}
