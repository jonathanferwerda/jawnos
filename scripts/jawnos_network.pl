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
#   public_ip                    name a globally routable address on this machine
#   public_ip_lookup             ask a public echo service for the outward address
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

# iwctl decorates its table output with colour/weight escapes even when stdout
# is a pipe. Strip the control sequences before any parser sees the rows; the
# status JSON used to carry "\u001B[1;90m" as an adapter name. This keeps the
# layout (spaces/newlines) so the column parsers still work.
sub strip_ansi {
	my ($text) = @_;
	return '' unless defined $text;
	$text =~ s/\e\[[0-9;?]*[ -\/]*[@-~]//g;   # CSI ... final byte
	$text =~ s/\e\][^\a]*(?:\a|\e\\)//g;         # OSC ... BEL/ST
	$text =~ s/\e[@-Z\\-_]//g;                # other two-byte escapes
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
sub run_privileged_read {
	my (@command) = @_;
	my ($stdout, $stderr, $status) = run_read(@command);
	if ($status == 0 || $> == 0) {
		return (strip_ansi($stdout), strip_ansi($stderr), $status);
	}
	my ($sudo_stdout, $sudo_stderr, $sudo_status) = run_read('sudo', '-n', @command);
	return (strip_ansi($sudo_stdout), strip_ansi($sudo_stderr), $sudo_status) if $sudo_status == 0;
	return (strip_ansi($stdout), strip_ansi($stderr), $status);
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
		# A restricted /sys (Android, a container without the net class) hides
		# the wireless directory. iw answers the same question for the interface
		# the kernel really has, so try it before calling the link wired.
		if (!$wireless && find_command('iw')) {
			my ($iw_out, $iw_err, $iw_status) = run_read('iw', 'dev', $name, 'info');
			$wireless = 1 if $iw_status == 0 && $iw_out =~ /^\s*type\s+\S+/m;
		}
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
	my ($stdout, $stderr, $status) = run_privileged_read('iwctl', 'adapter', 'list');
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
	my ($stdout, $stderr, $status) = run_privileged_read('iwctl', 'station', $interface, 'show');
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
	my ($stdout, $stderr, $status) = run_privileged_read('iwctl', 'known-networks', 'list');
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

# A Wi-Fi link's strength. iw is the direct answer; /proc/net/wireless is the
# fallback for a machine that has a wireless kernel interface but no iw. Both
# are reduced to the same quality (0-100) and bars (0-4) the widget draws.
sub wifi_signal_fields {
	my ($rssi, $quality) = @_;
	my %signal;
	if (defined $rssi) {
		$signal{'rssi'} = $rssi + 0;
		$quality = ($rssi + 100) * 2;
	}
	return \%signal unless defined $quality;
	$quality = int($quality + 0.5);
	$quality = 0 if $quality < 0;
	$quality = 100 if $quality > 100;
	$signal{'quality'} = $quality;
	$signal{'bars'} = $quality >= 75 ? 4 : ($quality >= 50 ? 3 : ($quality >= 25 ? 2 : ($quality > 0 ? 1 : 0)));
	return \%signal;
}

sub wifi_signal {
	my ($interface) = @_;
	return {} unless valid_interface($interface);
	if (find_command('iw')) {
		my ($stdout, $stderr, $status) = run_read('iw', 'dev', $interface, 'link');
		if ($status == 0 && $stdout =~ /signal:\s*(-?\d+(?:\.\d+)?)\s*dBm/) {
			return wifi_signal_fields($1 + 0, undef);
		}
	}
	my $text = slurp('/proc/net/wireless');
	foreach my $line ( split /\n/, $text ) {
		next unless $line =~ /^\s*\Q$interface\E:\s*\S+\s+(-?\d+(?:\.\d+)?)\.?\s+(-?\d+(?:\.\d+)?)/;
		my ($link, $level) = ($1 + 0, $2 + 0);
		return wifi_signal_fields($level < 0 ? $level : undef, $link * 100 / 70);
	}
	return {};
}

sub wifi_status {
	my ($interfaces) = @_;
	$interfaces = interface_report() unless ref $interfaces eq 'ARRAY';
	my @wireless;
	foreach my $interface ( @{$interfaces} ) {
		next unless $interface->{'wireless'};
		my $station = station_report($interface->{'name'});
		# iwd is the house's Wi-Fi tool, but a NetworkManager desktop has no
		# iwctl. `iw dev <if> link` carries the same SSID and state, so use it
		# when the station report is empty.
		if (!($station->{'connected network'} || '') && find_command('iw')) {
			my ($link_out, $link_err, $link_status) = run_read('iw', 'dev', $interface->{'name'}, 'link');
			if ($link_status == 0) {
				$station->{'connected network'} = $1 if $link_out =~ /^\s*SSID:\s*(.+?)\s*$/m;
				$station->{'state'} = 'connected' if $link_out =~ /Connected to/m;
			}
		}
		my $signal = wifi_signal($interface->{'name'});
		push @wireless, {
			name  => $interface->{'name'},
			state => $station->{'state'} || $interface->{'state'},
			ssid  => $station->{'connected network'} || '',
			mac   => $interface->{'mac'},
			%{$signal},
		};
	}
	my $adapters = adapter_report();
	my $radio_powered = $adapters->{'powered'};
	# NetworkManager has no iwctl adapter list to read the radio from;
	# `nmcli radio wifi` prints enabled/disabled for the same switch.
	if (!find_command('iwctl') && find_command('nmcli')) {
		my ($out, $err, $status) = run_read('nmcli', 'radio', 'wifi');
		$radio_powered = ($status == 0 && $out =~ /\A\s*enabled\s*\z/i) ? 1 : 0;
	}
	return {
		present       => scalar(@wireless) ? 1 : 0,
		iwd           => $adapters->{'present'} ? 1 : 0,
		interfaces    => \@wireless,
		adapters      => $adapters->{'adapters'},
		radio_powered => $radio_powered,
		saved         => saved_networks(),
	};
}

sub wifi_scan {
	my ($interface) = @_;
	$interface = first_wireless() unless valid_interface($interface);
	return { ok => 0, error => 'No wireless interface found.' } unless valid_interface($interface);
	# iwd first: it is the stack this house configures. A machine on NetworkManager
	# (the Table, a laptop) has no iwctl at all, and the old early return answered
	# "No wireless interface found." on a machine with a perfectly good radio - so
	# Scan showed no networks and the name had to be typed by hand.
	return wifi_scan_iwd($interface) if find_command('iwctl');
	return wifi_scan_nmcli($interface) if find_command('nmcli');
	return { ok => 0, error => 'No WiFi tool is installed (iwctl or nmcli).' };
}

sub wifi_scan_iwd {
	my ($interface) = @_;
	run_privileged_read('iwctl', 'station', $interface, 'scan');
	select(undef, undef, undef, 2);
	my ($stdout, $stderr, $status) = run_privileged_read('iwctl', 'station', $interface, 'get-networks');
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

# nmcli writes a run of `:`-separated fields, and a network name can contain a
# colon, which it escapes. Split from the right - signal and security are the
# last two fields - and put the name back together.
sub nmcli_unescape {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\\(.)/$1/g;
	return $text;
}

sub wifi_scan_nmcli {
	my ($interface) = @_;
	my ($stdout, $stderr, $status) = run_privileged_read(
		'nmcli', '--terse', '--escape', 'yes', '--fields', 'SSID,SECURITY,SIGNAL',
		'device', 'wifi', 'list', 'ifname', $interface, '--rescan', 'yes'
	);
	unless ($status == 0) {
		# A rescan can be refused while the radio is busy; the cached list is
		# still worth showing, and is better than no answer at all.
		($stdout, $stderr, $status) = run_privileged_read(
			'nmcli', '--terse', '--escape', 'yes', '--fields', 'SSID,SECURITY,SIGNAL',
			'device', 'wifi', 'list', 'ifname', $interface
		);
	}
	return { ok => 0, error => clean($stderr) || clean($stdout) || 'The scan failed.' } unless $status == 0;
	my %seen;
	my @networks;
	foreach my $line ( split /\n/, $stdout ) {
		next unless length $line;
		my @fields = split /(?<!\\):/, $line;
		next unless @fields >= 3;
		my $signal = pop @fields;
		my $security = pop @fields;
		my $ssid = nmcli_unescape(join(':', @fields));
		next unless valid_ssid($ssid);
		next if $seen{$ssid}++;
		# nmcli spells "no security" as an empty field, `--`, or `none`.
		my $secure = 1;
		$secure = 0 if !defined $security || $security eq '' || $security =~ /^(?:--|none|open)$/i;
		$security = 'open' unless $secure;
		$signal = 0 unless defined $signal && $signal =~ /^\d+$/;
		my $bars = int($signal / 25);
		$bars = 0 if $bars < 0;
		$bars = 4 if $bars > 4;
		push @networks, {
			ssid     => $ssid,
			security => $security,
			secure   => $secure,
			signal   => $signal,
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
	# iwd is the house's Wi-Fi stack. A NetworkManager machine has no iwctl at
	# all, and `nmcli radio wifi on|off` is the same switch there.
	unless (find_command('iwctl')) {
		return { ok => 0, error => 'iwd is not installed.' } unless find_command('nmcli');
		my ($stdout, $stderr, $status) = run_write(undef, 'nmcli', 'radio', 'wifi', $state);
		return { ok => 1, powered => ($state eq 'on' ? 1 : 0) } if $status == 0;
		return { ok => 0, error => clean($stderr) || clean($stdout) || 'Could not change the radio.' };
	}
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
	# The Android app runs its own embedded tailnet (libtailscale) and rewrites
	# <filesDir>/tailnet/status.json atomically. This tree's HOME is
	# <filesDir>/home, so the file is one level up. Only that canonical path
	# counts. When the app owns the tailnet there is no CLI to start, so answer
	# with the app's instruction instead of claiming Tailscale is not installed.
	my $status_file = 0;
	my $tailnet_dir = 0;
	{
		require Cwd;
		my $home = $ENV{'HOME'} || '';
		my $parent = length $home ? Cwd::abs_path($home . '/..') : undef;
		my $dir = defined $parent ? Cwd::abs_path($parent . '/tailnet') : undef;
		my $file = defined $dir ? Cwd::abs_path($dir . '/status.json') : undef;
		if (defined $dir && defined $parent && $dir eq $parent . '/tailnet' && -d $dir) {
			$tailnet_dir = 1;
			$status_file = 1 if defined $file && $file eq $dir . '/status.json' && -f $file && -r _;
		}
	}
	my $path = find_command('tailscale');
	# The app creates <filesDir>/tailnet/ even before its first status write; with
	# no CLI that directory is still the app's tunnel, not a missing package.
	return { ok => 0, error => 'The Android app holds the tailnet: turn on Auto-connect in the dashboard.' }
		if $status_file || ($tailnet_dir && !$path);
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

# An address the world can route to. RFC1918, CGNAT, loopback and the other
# reserved ranges are not public even when the kernel calls their scope global:
# a LAN address reads as scope global, so the address itself is classified here
# rather than trusted from `ip`.
sub address_is_public {
	my ($ip) = @_;
	return 0 unless defined $ip && length $ip;
	if ($ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
		my @octet = split /\./, $ip;
		return 0 if grep { $_ > 255 } @octet;
		return 0 if $octet[0] == 0 || $octet[0] == 10 || $octet[0] == 127;
		return 0 if $octet[0] == 169 && $octet[1] == 254;
		return 0 if $octet[0] == 172 && $octet[1] >= 16 && $octet[1] <= 31;
		return 0 if $octet[0] == 192 && $octet[1] == 168;
		return 0 if $octet[0] == 100 && $octet[1] >= 64 && $octet[1] <= 127;
		return 0 if $octet[0] == 192 && $octet[1] == 0 && $octet[2] == 0;
		return 0 if $octet[0] == 192 && $octet[1] == 0 && $octet[2] == 2;
		return 0 if $octet[0] == 198 && ($octet[1] == 18 || $octet[1] == 19);
		return 0 if $octet[0] == 198 && $octet[1] == 51 && $octet[2] == 100;
		return 0 if $octet[0] == 203 && $octet[1] == 0 && $octet[2] == 113;
		return 0 if $octet[0] >= 224;
		return 1;
	}
	my $lc = lc $ip;
	return 0 if $lc eq '::1' || $lc eq '::';
	return 0 if $lc =~ /^fe[89ab]/;   # link-local fe80::/10
	return 0 if $lc =~ /^f[cd]/;      # unique-local fc00::/7
	return 0 if $lc =~ /^::ffff:/;    # IPv4-mapped
	return $lc =~ /:/ ? 1 : 0;
}

# What this machine can know by itself: a globally routable address on one of
# its interfaces. A machine behind NAT has none, and no local command can see
# the address the router wears - only the router, or something outside, knows
# it - so an empty answer says `behind_nat` instead of guessing.
sub public_ip {
	my ($stdout, $stderr, $status) = run_read('ip', '-j', 'address', 'show');
	my $list = eval { $JSON->decode($stdout) };
	$list = [] unless ref $list eq 'ARRAY';
	my ($v4, $v6);
	foreach my $interface ( @{$list} ) {
		next unless ref $interface eq 'HASH';
		my $name = $interface->{'ifname'} || '';
		foreach my $address ( @{ $interface->{'addr_info'} || [] } ) {
			next unless ref $address eq 'HASH';
			my $local = $address->{'local'} || '';
			next unless address_is_public($local);
			if (($address->{'family'} || '') eq 'inet' && !$v4) {
				$v4 = { ip => $local, family => 'IPv4', interface => $name };
			}
			elsif (($address->{'family'} || '') eq 'inet6' && !$v6) {
				$v6 = { ip => $local, family => 'IPv6', interface => $name };
			}
		}
	}
	my $found = $v4 || $v6;
	return { ok => 1, source => 'local', behind_nat => 1, ip => '', family => '', interface => '' } unless $found;
	return { ok => 1, source => 'local', behind_nat => 0, %{$found} };
}

# The address the world sees when the machine is behind NAT. This is an
# outbound request, so it is never automatic: the panel asks only when a person
# presses Look up, and the caller caches the answer. curl first, wget second,
# and only a string that really is an address is returned, so a captive portal's
# HTML never becomes an "address" on the panel.
sub public_ip_lookup {
	my @services = (
		[ 'curl', '-sS', '--max-time', '5', 'https://api.ipify.org' ],
		[ 'wget', '-qO-', '--timeout=5', 'https://api.ipify.org' ],
	);
	my ($stdout, $stderr, $status);
	my $used = '';
	for my $service ( @services ) {
		(my $bin, my @args) = @{$service};
		($stdout, $stderr, $status) = run_read($bin, @args);
		$used = $bin;
		last if $status == 0 && defined $stdout && length $stdout;
	}
	return { ok => 0, error => 'the public address could not be read' } unless $status == 0;
	my $ip = trim($stdout);
	my $v4 = $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/ ? 1 : 0;
	my $v6 = (!$v4 && $ip =~ /^[0-9A-Fa-f:.]{2,45}$/ && $ip =~ /:/) ? 1 : 0;
	return { ok => 0, error => 'the public address was not an address' } unless $v4 || $v6;
	return { ok => 1, source => 'lookup', ip => $ip, family => ($v4 ? 'IPv4' : 'IPv6'), service => $used };
}

my $command = shift @ARGV;
$command = '' unless defined $command;

if ($command eq '--test-ansi') {
	my $raw = "Adapters \e[1;90mphy0\e[0m\n";
	my $got = strip_ansi($raw);
	print $got;
	exit($got eq "Adapters phy0\n" ? 0 : 1);
}

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
elsif ($command eq 'public_ip') {
	emit(public_ip());
}
elsif ($command eq 'public_ip_lookup') {
	emit(public_ip_lookup());
}
elsif ($command eq 'vpn_unit') {
	my ($action, $kind, $name) = @ARGV;
	emit(vpn_unit($action, $kind, $name));
}
else {
	failure('Unknown network command.');
}
