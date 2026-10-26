#!/usr/bin/perl
#
# jawnos_network.pl - the fixed command set behind the Network app.
#
# Manager.pl calls this with an argument list (never a shell) and encodes the
# result as JSON. Every subcommand validates its own arguments, so a caller
# cannot turn an SSID or an interface name into a command. Read-only commands
# run as the calling user; a mutating command is retried through `sudo -n` when
# the direct attempt fails, which is how the live image's passwordless sudo is
# meant to be used.
#
#   status
#   wifi_scan [interface]
#   wifi_connect <interface> <ssid>      (passphrase on stdin, empty for open)
#   wifi_disconnect <interface>
#   wifi_forget <ssid>
#   radio on|off
#   interface up|down <interface>
#   vpn_status
#   vpn_tailscale up|down
#   vpn_unit start|stop wg|openvpn <name>
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
	emit({ ok => 0, error => clean($message) || 'The network request failed.' });
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

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

sub read_number {
	my ($path) = @_;
	my $text = slurp($path);
	$text =~ s/\s+//g;
	return $text =~ /^\d+$/ ? $text : 0;
}

sub trim {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/^\s+|\s+$//g;
	return $text;
}

# Command output and argv arrive as bytes. Decode valid UTF-8 so an SSID with
# non-ASCII letters is handed back to the browser as those letters, not as a
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

sub valid_interface {
	my ($name) = @_;
	return 0 unless defined $name;
	return $name =~ /\A[A-Za-z0-9_.:-]{1,32}\z/ ? 1 : 0;
}

sub valid_ssid {
	my ($ssid) = @_;
	return 0 unless defined $ssid;
	return 0 if length($ssid) < 1 || length($ssid) > 32;
	return 0 if $ssid =~ /[\x00-\x1f\x7f]/;
	return 1;
}

sub valid_passphrase {
	my ($pass) = @_;
	return 1 unless defined $pass && length $pass;
	return 1 if length($pass) >= 8 && length($pass) <= 63 && $pass !~ /[^\x20-\x7e]/;
	return 1 if $pass =~ /\A[0-9A-Fa-f]{64}\z/;
	return 0;
}

# Read-only calls answer within a few seconds or not at all, so a missing
# daemon cannot make the app's poll pile up. A write (systemctl, tailscale) gets
# longer: WireGuard and tailscaled can take their time to come up.
our $capture_timeout = 45;

# Run one command without a shell. $input, when defined, is written to the
# program's stdin (used by callers that hand this helper a secret). stdout,
# stderr and the exit status come back, with a hard deadline so a wedged daemon
# cannot hold the manager worker.
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
	return ($stdout, $stderr, $status);
}

sub run_read {
	local $capture_timeout = 15;
	my (@command) = @_;
	return capture(undef, @command);
}

# iwd's D-Bus policy differs between distributions: reading is usually allowed
# for a normal user, but where it is not, a passwordless sudo answers the same
# question without changing anything.
sub run_iwctl_read {
	my (@command) = @_;
	my ($stdout, $stderr, $status) = run_read(@command);
	return ($stdout, $stderr, $status) if $status == 0 || $> == 0;
	my ($sudo_stdout, $sudo_stderr, $sudo_status) = run_read('sudo', '-n', @command);
	return ($sudo_stdout, $sudo_stderr, $sudo_status) if $sudo_status == 0;
	return ($stdout, $stderr, $status);
}

# Mutating commands: try directly, then through sudo -n. The live image gives
# the jawn user passwordless sudo, and an installed machine that does not will
# simply report the original answer.
sub run_write {
	local $capture_timeout = 60;
	my ($input, @command) = @_;
	my ($stdout, $stderr, $status) = capture($input, @command);
	return ($stdout, $stderr, $status) if $status == 0;
	return ($stdout, $stderr, $status) if $> == 0;
	my ($sudo_stdout, $sudo_stderr, $sudo_status) = capture($input, 'sudo', '-n', @command);
	return ($sudo_stdout, $sudo_stderr, $sudo_status) if $sudo_status == 0;
	# Prefer the sudo error only when it says something the direct run did not.
	my $direct = clean($stderr) || clean($stdout);
	my $via_sudo = clean($sudo_stderr) || clean($sudo_stdout);
	return ($stdout, ($via_sudo && !$direct ? $sudo_stderr : $stderr), $status);
}

sub interface_report {
	my ($stdout, $stderr, $status) = run_read('ip', '-j', 'address', 'show');
	my $list = eval { $JSON->decode($stdout) };
	$list = [] unless ref $list eq 'ARRAY';
	my @interfaces;
	foreach my $entry ( @{$list} ) {
		next unless ref $entry eq 'HASH';
		my $name = $entry->{'ifname'} || '';
		next unless length $name;
		my $base = '/sys/class/net/' . $name;
		my $state = trim(slurp($base . '/operstate'));
		$state = $entry->{'operstate'} || 'unknown' unless length $state;
		my $mac = trim($entry->{'address'} || slurp($base . '/address'));
		my (@v4, @v6);
		foreach my $address ( @{ $entry->{'addr_info'} || [] } ) {
			next unless ref $address eq 'HASH';
			my $family = $address->{'family'} || '';
			my $record = {
				address => $address->{'local'} || '',
				prefix  => $address->{'prefixlen'} || '',
			};
			push @v4, $record if $family eq 'inet';
			push @v6, $record if $family eq 'inet6';
		}
		my $ifindex = $entry->{'ifindex'} || '';
		my $method = 'none';
		if ($ifindex && -e '/run/systemd/netif/leases/' . $ifindex) {
			$method = 'dhcp';
		}
		elsif (scalar @v4) {
			$method = static_configured($name) ? 'static' : 'unknown';
		}
		my $wireless = (-d $base . '/wireless' || -d $base . '/phy80211') ? 1 : 0;
		push @interfaces, {
			name     => $name,
			state    => $state,
			mac      => $mac,
			ipv4     => \@v4,
			ipv6     => \@v6,
			method   => $method,
			wireless => $wireless,
			rx       => read_number($base . '/statistics/rx_bytes'),
			tx       => read_number($base . '/statistics/tx_bytes'),
		};
	}
	return \@interfaces;
}

sub first_wireless {
	my $interfaces = interface_report();
	foreach my $interface ( @{$interfaces} ) {
		return $interface->{'name'} if $interface->{'wireless'};
	}
	return undef;
}

# iwctl names an adapter phyN; the kernel exposes the same name beside the
# interface, which lets the radio switch work even when `adapter list` is empty.
sub adapter_name {
	my $report = adapter_report();
	my $adapter = $report->{'adapters'}->[0];
	return $adapter->{'name'} if $adapter;
	my $interface = first_wireless();
	return undef unless $interface;
	my $name = trim(slurp('/sys/class/net/' . $interface . '/phy80211/name'));
	return length $name ? $name : undef;
}

# The address method is only called "static" when a systemd-networkd unit really
# carries an Address= line for this interface. A DHCP lease is the networkd
# lease file; anything else stays unknown rather than guessing.
sub static_configured {
	my ($name) = @_;
	foreach my $file ( glob('/etc/systemd/network/*.network') ) {
		my $text = slurp($file);
		my $section = '';
		my ($matches, $has_address) = (0, 0);
		foreach my $line ( split /\n/, $text ) {
			if ($line =~ /^\s*\[([^\]]+)\]/) {
				$section = lc($1);
				next;
			}
			next if $line =~ /^\s*[#;]/;
			if ($section eq 'match' && $line =~ /^\s*Name\s*=\s*(.+)$/) {
				foreach my $pattern ( split /\s+/, $1 ) {
					my $regex = $pattern;
					$regex =~ s/([.+^$(){}\[\]|\\])/\\$1/g;
					$regex =~ s/\*/.*/g;
					$regex =~ s/\?/./g;
					$matches = 1 if $name =~ /^$regex$/;
				}
			}
			if ($section eq 'network' && $line =~ /^\s*Address\s*=/) {
				$has_address = 1;
			}
		}
		return 1 if $matches && $has_address;
	}
	return 0;
}

sub adapter_report {
	my $report = { present => 0, adapters => [], powered => 0 };
	return $report unless find_command('iwctl');
	$report->{'present'} = 1;
	my ($stdout, $stderr, $status) = run_iwctl_read('iwctl', 'adapter', 'list');
	return $report unless $status == 0;
	my @adapters;
	foreach my $line ( split /\n/, $stdout ) {
		next if $line =~ /^\s*$/;
		next if $line =~ /^\s*-+\s*$/;
		next if $line =~ /^\s*Name\s+Powered/i;
		(my $trimmed = $line) =~ s/^\s+//;
		my @parts = split /\s{2,}/, $trimmed;
		next unless @parts >= 2;
		push @adapters, {
			name    => $parts[0],
			powered => (lc($parts[1]) eq 'on' ? 1 : 0),
		};
	}
	$report->{'adapters'} = \@adapters;
	$report->{'powered'} = (@adapters && $adapters[0]->{'powered'}) ? 1 : 0;
	return $report;
}

sub station_report {
	my ($interface) = @_;
	my %info;
	return \%info unless find_command('iwctl');
	my ($stdout, $stderr, $status) = run_iwctl_read('iwctl', 'station', $interface, 'show');
	return \%info unless $status == 0;
	foreach my $line ( split /\n/, $stdout ) {
		next if $line =~ /^\s*Station:/;
		next unless $line =~ /^\s*([A-Za-z][A-Za-z ]*?)\s{2,}(.*?)\s*$/;
		my ($key, $value) = (lc($1), $2);
		$info{$key} = utf8_text($value);
	}
	return \%info;
}

sub saved_networks {
	return [] unless find_command('iwctl');
	my ($stdout, $stderr, $status) = run_iwctl_read('iwctl', 'known-networks', 'list');
	return [] unless $status == 0;
	my @saved;
	foreach my $line ( split /\n/, $stdout ) {
		next if $line =~ /^\s*$/;
		next if $line =~ /^\s*-+\s*$/;
		next if $line =~ /Known networks/i;
		(my $name = $line) =~ s/^\s+|\s+$//g;
		$name = utf8_text($name);
		push @saved, $name if valid_ssid($name);
	}
	return \@saved;
}

sub wifi_status {
	my ($interfaces) = @_;
	$interfaces = interface_report() unless ref $interfaces eq 'ARRAY';
	my @wireless;
	foreach my $interface ( @{$interfaces} ) {
		next unless $interface->{'wireless'};
		my $station = station_report($interface->{'name'});
		push @wireless, {
			name  => $interface->{'name'},
			state => $station->{'state'} || $interface->{'state'},
			ssid  => $station->{'connected network'} || '',
			mac   => $interface->{'mac'},
		};
	}
	my $adapters = adapter_report();
	return {
		present       => scalar(@wireless) ? 1 : 0,
		iwd           => $adapters->{'present'} ? 1 : 0,
		interfaces    => \@wireless,
		adapters      => $adapters->{'adapters'},
		radio_powered => $adapters->{'powered'},
		saved         => saved_networks(),
	};
}

sub wifi_scan {
	my ($interface) = @_;
	return { ok => 0, error => 'No wireless interface found.' } unless find_command('iwctl');
	$interface = first_wireless() unless valid_interface($interface);
	return { ok => 0, error => 'No wireless interface found.' } unless valid_interface($interface);
	run_iwctl_read('iwctl', 'station', $interface, 'scan');
	select(undef, undef, undef, 2);
	my ($stdout, $stderr, $status) = run_iwctl_read('iwctl', 'station', $interface, 'get-networks');
	return { ok => 0, error => clean($stderr) || clean($stdout) || 'The scan failed.' } unless $status == 0;
	my @networks;
	foreach my $line ( split /\n/, $stdout ) {
		next if $line =~ /^\s*$/;
		next if $line =~ /^\s*-+\s*$/;
		next if $line =~ /^\s*Name\s+Security/i;
		(my $trimmed = $line) =~ s/^\s*>?\s*//;
		$trimmed =~ s/\s+$//;
		my @parts = split /\s{2,}/, $trimmed;
		next unless @parts >= 3;
		my $signal = pop @parts;
		my $security = pop @parts;
		my $ssid = utf8_text(join('  ', @parts));
		next unless valid_ssid($ssid);
		my $bars = () = $signal =~ /\*/g;
		$bars = 4 if $bars > 4;
		push @networks, {
			ssid     => $ssid,
			security => $security,
			secure   => ($security =~ /open/i ? 0 : 1),
			signal   => $bars * 25,
			bars     => $bars,
		};
	}
	@networks = sort { $b->{'signal'} <=> $a->{'signal'} || lc($a->{'ssid'}) cmp lc($b->{'ssid'}) } @networks;
	return { ok => 1, interface => $interface, networks => \@networks };
}

sub wifi_connect {
	my ($interface, $ssid, $passphrase) = @_;
	$ssid = utf8_text($ssid);
	return { ok => 0, error => 'That interface name is not valid.' } unless valid_interface($interface);
	return { ok => 0, error => 'That network name is not valid.' } unless valid_ssid($ssid);
	return { ok => 0, error => 'The passphrase must be 8 to 63 characters, or 64 hexadecimal digits.' }
		unless valid_passphrase($passphrase);
	return { ok => 0, error => 'iwd is not installed.' } unless find_command('iwctl');
	my @command = ('iwctl', '--dont-ask');
	push @command, '--passphrase=' . $passphrase if defined $passphrase && length $passphrase;
	push @command, 'station', $interface, 'connect', $ssid;
	my ($stdout, $stderr, $status) = run_write(undef, @command);
	if ($status != 0) {
		my $message = clean($stderr) || clean($stdout) || ('Could not connect to ' . $ssid . '.');
		return { ok => 0, error => $message };
	}
	my $connected = 0;
	foreach my $attempt ( 1 .. 4 ) {
		select(undef, undef, undef, 1);
		my $station = station_report($interface);
		if ((($station->{'state'} || '') eq 'connected')
			&& (($station->{'connected network'} || '') eq $ssid)) {
			$connected = 1;
			last;
		}
	}
	return { ok => 1, message => 'Connected to ' . $ssid . '.' } if $connected;
	my $message = clean($stderr) || clean($stdout);
	$message = 'Could not connect to ' . $ssid . '.' unless length $message;
	return { ok => 0, error => $message };
}

sub wifi_disconnect {
	my ($interface) = @_;
	return { ok => 0, error => 'That interface name is not valid.' } unless valid_interface($interface);
	return { ok => 0, error => 'iwd is not installed.' } unless find_command('iwctl');
	my ($stdout, $stderr, $status) = run_write(undef, 'iwctl', 'station', $interface, 'disconnect');
	return { ok => 1, message => 'Disconnected.' } if $status == 0;
	return { ok => 0, error => clean($stderr) || clean($stdout) || 'Could not disconnect.' };
}

sub wifi_forget {
	my ($ssid) = @_;
	$ssid = utf8_text($ssid);
	return { ok => 0, error => 'That network name is not valid.' } unless valid_ssid($ssid);
	return { ok => 0, error => 'iwd is not installed.' } unless find_command('iwctl');
	my ($stdout, $stderr, $status) = run_write(undef, 'iwctl', 'known-networks', $ssid, 'forget');
	return { ok => 1, message => 'Forgot ' . $ssid . '.' } if $status == 0;
	return { ok => 0, error => clean($stderr) || clean($stdout) || 'Could not forget that network.' };
}

sub radio_set {
	my ($state) = @_;
	return { ok => 0, error => 'The radio can only be turned on or off.' } unless defined $state && $state =~ /\A(?:on|off)\z/;
	return { ok => 0, error => 'iwd is not installed.' } unless find_command('iwctl');
	my $adapter = adapter_name();
	return { ok => 0, error => 'No wireless adapter found.' } unless $adapter;
	my ($stdout, $stderr, $status) = run_write(undef, 'iwctl', 'adapter', $adapter, 'set-property', 'Powered', $state);
	return { ok => 1, powered => ($state eq 'on' ? 1 : 0) } if $status == 0;
	return { ok => 0, error => clean($stderr) || clean($stdout) || 'Could not change the radio.' };
}

sub interface_set {
	my ($action, $name) = @_;
	return { ok => 0, error => 'The interface can only be brought up or down.' } unless defined $action && $action =~ /\A(?:up|down)\z/;
	return { ok => 0, error => 'That interface name is not valid.' } unless valid_interface($name);
	my ($stdout, $stderr, $status) = run_write(undef, 'ip', 'link', 'set', 'dev', $name, $action);
	return { ok => 1, message => 'Interface ' . $name . ' is ' . $action . '.' } if $status == 0;
	return { ok => 0, error => clean($stderr) || clean($stdout) || 'Could not change the interface.' };
}

sub unit_active {
	my ($unit) = @_;
	my ($stdout, $stderr, $status) = run_read('systemctl', 'is-active', '--quiet', $unit);
	return $status == 0 ? 1 : 0;
}

sub tailscale_status {
	my $path = find_command('tailscale');
	return { present => 0 } unless $path;
	my ($stdout, $stderr, $status) = run_read($path, 'status', '--json');
	if ($status != 0 && $> != 0) {
		($stdout, $stderr, $status) = run_read('sudo', '-n', $path, 'status', '--json');
	}
	my $data = eval { $JSON->decode($stdout) };
	unless (ref $data eq 'HASH') {
		return { present => 1, running => 0, backend => 'unknown', ip => '' };
	}
	my $self = ref $data->{'Self'} eq 'HASH' ? $data->{'Self'} : {};
	my $peers = ref $data->{'Peer'} eq 'HASH' ? $data->{'Peer'} : {};
	my $ip = ref $self->{'TailscaleIPs'} eq 'ARRAY' ? $self->{'TailscaleIPs'}->[0] : '';
	my $exit;
	if (ref $data->{'ExitNodeStatus'} eq 'HASH' && $data->{'ExitNodeStatus'}->{'ID'}) {
		my $status = $data->{'ExitNodeStatus'};
		my $exit_ip = '';
		if (ref $status->{'TailscaleIPs'} eq 'ARRAY' && @{$status->{'TailscaleIPs'}}) {
			$exit_ip = $status->{'TailscaleIPs'}->[0];
			$exit_ip =~ s{/\d+$}{};
		}
		my $peer;
		if (length $exit_ip) {
			foreach my $candidate ( values %{$peers} ) {
				next unless ref $candidate eq 'HASH' && ref $candidate->{'TailscaleIPs'} eq 'ARRAY';
				if (grep { my $candidate_ip = $_; $candidate_ip =~ s{/\d+$}{}; $candidate_ip eq $exit_ip } @{$candidate->{'TailscaleIPs'}}) {
					$peer = $candidate;
					last;
				}
			}
		}
		$exit = {
			name => (ref $peer eq 'HASH' ? ($peer->{'HostName'} || $peer->{'DNSName'}) : '') || $status->{'ID'},
			ip   => $exit_ip,
		};
	}
	elsif ($self->{'ExitNode'}) {
		$exit = { name => 'exit node', ip => '' };
	}
	my @exit_nodes;
	foreach my $peer ( values %{$peers} ) {
		next unless ref $peer eq 'HASH' && $peer->{'ExitNodeOption'};
		push @exit_nodes, {
			name => $peer->{'HostName'} || $peer->{'DNSName'} || '',
			ip   => (ref $peer->{'TailscaleIPs'} eq 'ARRAY' ? $peer->{'TailscaleIPs'}->[0] : '') || '',
		};
	}
	return {
		present    => 1,
		running    => (($data->{'BackendState'} || '') eq 'Running' ? 1 : 0),
		backend    => $data->{'BackendState'} || 'unknown',
		ip         => $ip,
		exit_node  => $exit,
		exit_nodes => \@exit_nodes,
	};
}

sub vpn_status {
	my @wireguard;
	foreach my $file ( sort glob('/etc/wireguard/*.conf') ) {
		my ($name) = $file =~ m{/([^/]+)\.conf\z};
		next unless defined $name && $name =~ /\A[A-Za-z0-9_=+.-]{1,64}\z/;
		push @wireguard, { name => $name, config => $file, active => unit_active('wg-quick@' . $name . '.service') };
	}
	my @openvpn;
	foreach my $file ( sort glob('/etc/openvpn/client/*.conf') ) {
		my ($name) = $file =~ m{/([^/]+)\.conf\z};
		next unless defined $name && $name =~ /\A[A-Za-z0-9_=+.-]{1,64}\z/;
		push @openvpn, { name => $name, config => $file, active => unit_active('openvpn-client@' . $name . '.service') };
	}
	return {
		tailscale => tailscale_status(),
		wireguard => \@wireguard,
		openvpn   => \@openvpn,
	};
}

sub vpn_tailscale {
	my ($state) = @_;
	return { ok => 0, error => 'Tailscale can only be brought up or down.' } unless defined $state && $state =~ /\A(?:up|down)\z/;
	my $path = find_command('tailscale');
	return { ok => 0, error => 'Tailscale is not installed.' } unless $path;
	my ($stdout, $stderr, $status) = run_write(undef, $path, $state);
	return { ok => 1, message => 'Tailscale is ' . $state . '.' } if $status == 0;
	return { ok => 0, error => clean($stderr) || clean($stdout) || 'Tailscale did not answer.' };
}

sub vpn_unit {
	my ($action, $kind, $name) = @_;
	return { ok => 0, error => 'The VPN action is not valid.' } unless defined $action && $action =~ /\A(?:start|stop)\z/;
	return { ok => 0, error => 'The VPN kind must be wg or openvpn.' } unless defined $kind && $kind =~ /\A(?:wg|openvpn)\z/;
	return { ok => 0, error => 'That configuration name is not valid.' }
		unless defined $name && $name =~ /\A[A-Za-z0-9_=+.-]{1,64}\z/;
	my $config = $kind eq 'wg' ? '/etc/wireguard/' . $name . '.conf' : '/etc/openvpn/client/' . $name . '.conf';
	return { ok => 0, error => 'No such VPN configuration.' } unless -e $config;
	my $unit = $kind eq 'wg' ? 'wg-quick@' . $name . '.service' : 'openvpn-client@' . $name . '.service';
	my ($stdout, $stderr, $status) = run_write(undef, 'systemctl', $action, $unit);
	return { ok => 1, message => $unit . ($action eq 'start' ? ' started.' : ' stopped.') } if $status == 0;
	return { ok => 0, error => clean($stderr) || clean($stdout) || 'systemctl did not answer.' };
}

my $command = shift @ARGV;
$command = '' unless defined $command;

if ($command eq 'status') {
	my $interfaces = interface_report();
	emit({
		ok         => 1,
		interfaces => $interfaces,
		wifi       => wifi_status($interfaces),
		vpn        => vpn_status(),
	});
}
elsif ($command eq 'wifi_scan') {
	emit(wifi_scan(shift @ARGV));
}
elsif ($command eq 'wifi_connect') {
	my ($interface, $ssid) = @ARGV;
	my $passphrase = '';
	unless (-t STDIN) {
		local $/;
		$passphrase = <STDIN>;
		$passphrase = '' unless defined $passphrase;
	}
	$passphrase =~ s/\r?\n\z//;
	emit(wifi_connect($interface, $ssid, $passphrase));
}
elsif ($command eq 'wifi_disconnect') {
	emit(wifi_disconnect(shift @ARGV));
}
elsif ($command eq 'wifi_forget') {
	emit(wifi_forget(shift @ARGV));
}
elsif ($command eq 'radio') {
	emit(radio_set(shift @ARGV));
}
elsif ($command eq 'interface') {
	my ($action, $interface) = @ARGV;
	emit(interface_set($action, $interface));
}
elsif ($command eq 'vpn_status') {
	emit({ ok => 1, vpn => vpn_status() });
}
elsif ($command eq 'vpn_tailscale') {
	emit(vpn_tailscale(shift @ARGV));
}
elsif ($command eq 'vpn_unit') {
	my ($action, $kind, $name) = @ARGV;
	emit(vpn_unit($action, $kind, $name));
}
else {
	failure('Unknown network command.');
}
