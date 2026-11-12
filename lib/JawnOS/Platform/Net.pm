package JawnOS::Platform::Net;

# Interface, route and neighbour reads behind one interface. Linux runs
# ifconfig/iproute2 and parses the same shapes the domain code did; macOS and
# Windows get their commands in the P2/P3 landings. A platform that cannot
# answer returns {} or '' rather than dying.
#
# The parsers are exported so fixtures can pin the formats: ifconfig's block
# layout (macOS and Linux spellings), `ip route show 0.0.0.0/0 dev X`,
# `ip -o addr show` (INET/INET6 ADDRESS/PREFIX), and `ip neigh show dev X`
# (IP [lladdr MAC] STATE).
#
# hostname() answers the kernel's nodename without starting a process, and
# addresses()/neighbours() return the ordered rows a caller compares against.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
	hostname addresses neighbours
	interfaces interface_names gateway gateway_mac neighbour_lines
	parse_ifconfig parse_ip_addr parse_route parse_neigh
	parse_windows_net_json windows_interface_map
	parse_windows_neighbours_json windows_neighbour_lines
);

BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
use Config ();
use JawnOS::Platform ();

# ifconfig, ip and arp live in sbin, which a service account's login PATH often
# does not carry. Prefer the PATH answer, then the usual absolute locations.
sub _tool_path {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	my $path = JawnOS::Platform::tool_path($name);
	return $path if $path;
	foreach my $dir ('/usr/sbin', '/sbin', '/usr/local/sbin') {
		my $candidate = "$dir/$name";
		return $candidate if -f $candidate && -x $candidate;
	}
	return undef;
}

sub _run {
	my (@command) = @_;
	return '' unless @command;
	open(my $fh, '-|', @command) or return '';
	my $out = do { local $/; <$fh> };
	close $fh;
	return defined $out ? $out : '';
}

sub _valid_nic {
	my ($nic) = @_;
	return (defined $nic && $nic =~ /^[A-Za-z0-9_.:-]+$/) ? 1 : 0;
}

# The machine's own name. The kernel's nodename is the value hostname(1)
# prints; POSIX::uname reads it without starting a process, and Sys::Hostname
# is the fallback for a platform that has no POSIX. A name cannot change while
# the process lives, so one read serves every page that asks.
our $hostname_memo;
sub hostname {
	return $hostname_memo if defined $hostname_memo;
	$hostname_memo = '';
	# Windows keeps the computer name in the environment, and Win32 can answer
	# it directly. Neither starts a process; Sys::Hostname's MSWin32 fallback
	# can run `hostname`, which is not a cost a page render can carry.
	if ($^O eq 'MSWin32') {
		my $name = $ENV{'COMPUTERNAME'} // '';
		$name =~ s/^\s+|\s+$//g;
		if (!length $name) {
			$name = eval { require Win32; Win32::GetComputerName() } // '';
			$name =~ s/^\s+|\s+$//g;
		}
		$hostname_memo = $name;
		return $hostname_memo;
	}
	my $name = eval { require POSIX; (POSIX::uname())[1] };
	$hostname_memo = $name if defined $name && length $name;
	if (!length $hostname_memo) {
		my $name = eval { require Sys::Hostname; Sys::Hostname::hostname() };
		$hostname_memo = $name if defined $name && length $name;
	}
	return $hostname_memo;
}

# The interface name a block header names: `eth0: flags=...` on Linux,
# `en0: flags=...` on macOS, and the older `eth0      Link encap:...`.
# Anything that is not an interface block (a shell error, a warning) is skipped.
sub parse_ifconfig {
	my ($text) = @_;
	my $address = {};
	return $address unless defined $text && length $text;
	foreach my $block (split /\n[ \t]*\n/, $text) {
		next unless length $block;
		my @line = split /\n/, $block;
		next unless @line;
		my ($nic) = $line[0] =~ /^([A-Za-z0-9_.:-]+?):?\s/;
		next unless _valid_nic($nic);
		next unless grep { /(?:flags=|Link encap)/ } @line;
		my $entry = { nic => $nic };
		foreach my $one (@line) {
			if ($one =~ /(?:ether|HWaddr)\s+([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})/) {
				$entry->{'mac'} = lc $1;
			}
			if ($one =~ /\binet6\s+(\S+)/) {
				$entry->{'ip6'} = $1;
			}
			elsif ($one =~ /\binet\s+(\S+)/) {
				$entry->{'ip'} = $1;
				$entry->{'netmask'} = $1 if $one =~ /\bnetmask\s+(\S+)/;
				$entry->{'broadcast'} = $1 if $one =~ /\bbroadcast\s+(\S+)/;
			}
		}
		$address->{$nic} = $entry;
	}
	return $address;
}

# One `ip -o addr show` line per address:
#   2: eth0    inet 10.20.0.10/24 brd 10.20.0.255 scope global dynamic eth0
#   3: wlan0    inet6 2001:db8::5/64 scope global
# Loopback and IPv6 link-local are dropped, the way hostname -I drops them, and
# the IPv4 answers come first so a caller comparing a browser's address does not
# depend on which family the kernel listed first.
sub parse_ip_addr {
	my ($text) = @_;
	my (@v4, @v6);
	return [ @v4, @v6 ] unless defined $text && length $text;
	foreach my $line (split /\n/, $text) {
		next unless $line =~ /^\s*\d+:\s+(\S+?):?\s+(inet6?)\s+([0-9A-Fa-f:.]+)/;
		my ($nic, $family, $address) = ($1, $2, $3);
		next if $nic eq 'lo';
		if ($family eq 'inet6') {
			next if $address eq '::1' || $address =~ /^fe80:/i;
			push @v6, $address;
		}
		else {
			next if $address =~ /^127\./;
			push @v4, $address;
		}
	}
	return [ @v4, @v6 ];
}

# The addresses this machine answers on, IPv4 first. Linux reads the full
# `ip -o addr show` report (an alias or a second address on one NIC is a row a
# caller should see); macOS falls back to the interface map. A platform that
# cannot answer returns [] and a caller's own fallback runs unchanged.
sub addresses {
	my $list;
	if ($^O eq 'linux') {
		my $ip = _tool_path('ip');
		$list = parse_ip_addr(_run($ip, '-o', 'addr', 'show')) if $ip;
	}
	$list = _windows_addresses() if $^O eq 'MSWin32';
	$list = _interface_addresses() unless $list && @{$list};
	my %seen;
	my @out = grep { !$seen{$_}++ } @{$list};
	return \@out;
}

sub _interface_addresses {
	my $address = interfaces();
	my (@v4, @v6);
	foreach my $nic (sort keys %{$address}) {
		next if $nic eq 'lo';
		my $entry = $address->{$nic} || {};
		my $ip = $entry->{'ip'} || '';
		push @v4, $ip if length $ip && $ip !~ /^127\./;
		my $ip6 = $entry->{'ip6'} || '';
		push @v6, $ip6 if length $ip6 && $ip6 =~ /:/ && $ip6 ne '::1' && $ip6 !~ /^fe80:/i;
	}
	return [ @v4, @v6 ];
}

# `ip route show 0.0.0.0/0 dev eth0` -> `default via 10.20.0.1 dev eth0 ...`.
sub parse_route {
	my ($text) = @_;
	return '' unless defined $text && length $text;
	foreach my $line (split /\n/, $text) {
		next unless $line =~ /^\s*default\b/;
		my ($gateway) = $line =~ /\bvia\s+(\S+)/;
		return $gateway if defined $gateway && length $gateway;
	}
	return '';
}

# `10.20.0.5 lladdr aa:bb:cc:dd:ee:ff REACHABLE`, `10.20.0.6 INCOMPLETE`,
# `10.20.0.7 FAILED`. The state word is optional (a typed row has none).
sub parse_neigh {
	my ($text) = @_;
	my @found;
	return \@found unless defined $text && length $text;
	foreach my $line (split /\n/, $text) {
		next unless $line =~ /\S/;
		my ($ip, $mac, $state) = ('', '', '');
		($ip) = $line =~ /^\s*(\S+)/;
		($mac) = $line =~ /\blladdr\s+([0-9a-fA-F:]{17})/;
		my @field = split ' ', $line;
		$state = $field[-1] if @field && $field[-1] =~ /^[A-Z_]+$/;
		push @found, {
			ip => $ip,
			mac => defined $mac ? lc $mac : '',
			state => $state,
			raw => $line,
		};
	}
	return \@found;
}

# The interface map. Values keep the shape the ifconfig parsers produced:
# { nic, mac, ip, netmask, broadcast, ip6 }. A down interface still has an entry
# (the gateway read below runs for it too).
sub interfaces {
	return _windows_interfaces() if $^O eq 'MSWin32';
	my $address = {};
	return $address unless $^O eq 'linux' || $^O eq 'darwin';
	my $ifconfig = _tool_path('ifconfig') or return $address;
	return parse_ifconfig(_run($ifconfig));
}

sub interface_names {
	my $address = interfaces();
	return [ sort keys %{$address} ];
}

sub gateway {
	my ($nic) = @_;
	return '' unless _valid_nic($nic);
	if ($^O eq 'MSWin32') {
		my $map = _windows_interfaces();
		my $entry = $map->{$nic};
		return (ref $entry eq 'HASH' && defined $entry->{'gw'}) ? $entry->{'gw'} : '';
	}
	if ($^O eq 'linux') {
		my $ip = _tool_path('ip') or return '';
		return parse_route(_run($ip, 'route', 'show', '0.0.0.0/0', 'dev', $nic));
	}
	if ($^O eq 'darwin') {
		my $route = _tool_path('route') or return '';
		my $out = _run($route, '-n', 'get', 'default');
		my ($gateway) = $out =~ /^\s*gateway:\s*(\S+)/m;
		return defined $gateway ? $gateway : '';
	}
	return '';
}

sub gateway_mac {
	my ($nic, $gateway) = @_;
	return '' unless _valid_nic($nic) && defined $gateway && $gateway =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	if ($^O eq 'MSWin32') {
		foreach my $row ( @{ _windows_neigh_rows($nic) } ) {
			return $row->{'mac'} if ($row->{'ip'} || '') eq $gateway && length($row->{'mac'} || '');
		}
		return '';
	}
	if ($^O eq 'linux') {
		my $ip = _tool_path('ip') or return '';
		my $found = parse_neigh(_run($ip, 'neigh', 'show', $gateway, 'dev', $nic));
		foreach my $row (@{$found}) {
			return $row->{'mac'} if $row->{'ip'} eq $gateway && length $row->{'mac'};
		}
		return '';
	}
	if ($^O eq 'darwin') {
		my $arp = _tool_path('arp') or return '';
		my $out = _run($arp, '-n', $gateway);
		my ($mac) = $out =~ /\bat\s+([0-9a-fA-F:]{17})/;
		return defined $mac ? lc $mac : '';
	}
	return '';
}

# The raw `ip neigh show dev X` lines, so the discovery logic can keep its own
# state filtering and synthetic rows. Empty when the platform cannot answer.
sub neighbour_lines {
	my ($nic) = @_;
	return [] unless _valid_nic($nic);
	return [ grep { /\S/ } split /\n/, _read_neigh($nic) ];
}

sub _read_neigh {
	my ($nic) = @_;
	return '' unless _valid_nic($nic);
	if ($^O eq 'MSWin32') {
		return join "\n", @{ windows_neighbour_lines(_windows_neigh_rows($nic)) };
	}
	return '' unless $^O eq 'linux';
	my $ip = _tool_path('ip') or return '';
	return _run($ip, 'neigh', 'show', 'dev', $nic);
}

# The neighbour table for one interface as `{ ip, mac, state }` rows. The state
# word says whether the row resolved (REACHABLE/STALE) or not (INCOMPLETE,
# FAILED); a caller that already ran the read (or a fixture) may pass $text.
sub neighbours {
	my ($nic, $text) = @_;
	my @rows;
	return \@rows unless _valid_nic($nic);
	$text = _read_neigh($nic) unless defined $text;
	foreach my $row (@{ parse_neigh($text) }) {
		push @rows, {
			ip    => $row->{'ip'},
			mac   => $row->{'mac'},
			state => $row->{'state'},
		};
	}
	return \@rows;
}

# --------------------------------------------------------------------------
# Windows
#
# A Windows machine answers the same three questions from the IP Helper API,
# in process: GetAdaptersAddresses() for the adapters, addresses and default
# gateway, and GetIpNetTable() for the ARP/neighbour table. Win32::API is the
# vendored wrapper; the vendored Win32::IPHelper 0.08 is not used because its
# GetAdaptersInfo() access-violates this perl. A PowerShell Get-Net* read is
# the fallback for a box where Win32::API or the DLL call cannot answer - it
# starts a process, so it is cached and never runs in the common case.
#
# The parsers below are pure and exported: the test suite runs on Linux and
# feeds a captured Windows payload through them. The in-process walker builds
# the same adapter hashes, so windows_interface_map() is the one shaper.

my $WINDOWS_TTL           = 5;   # adapters/addresses/gateway, seconds
my $WINDOWS_NEIGHBOUR_TTL = 2;   # the ARP table moves; keep it shorter
my %windows_state;
my %windows_neighbour_state;
our $WINDOWS_ADAPTERS_API;

sub _windows_state {
	my $now = time;
	if ($windows_state{'at'} && $now - $windows_state{'at'} <= $WINDOWS_TTL) {
		return $windows_state{'state'};
	}
	my $adapters = _windows_adapters_addresses();
	$adapters = _windows_adapters_powershell() unless @{$adapters};
	my $map = windows_interface_map($adapters);
	my @addresses = _windows_address_rows($adapters);
	my $state = { adapters => $adapters, map => $map, addresses => \@addresses };
	$windows_state{'at'} = $now;
	$windows_state{'state'} = $state;
	return $state;
}

sub _windows_interfaces {
	my $map = _windows_state()->{'map'} || {};
	my %copy;
	foreach my $nic ( keys %{$map} ) {
		my $entry = $map->{$nic};
		my %one = %{$entry};
		$one{'ips'} = [ map { { %{$_} } } @{ $entry->{'ips'} || [] } ];
		$copy{$nic} = \%one;
	}
	return \%copy;
}

sub _windows_addresses {
	my $state = _windows_state();
	return [ @{ $state->{'addresses'} || [] } ];
}

# IPv4 first, then IPv6, loopback and link-local dropped, deduplicated - the
# same shape parse_ip_addr() hands a caller on Linux.
sub _windows_address_rows {
	my ($adapters) = @_;
	my (@v4, @v6, %seen);
	foreach my $adapter ( sort { ($a->{'ifindex'} || 0) <=> ($b->{'ifindex'} || 0) } grep { ref $_ eq 'HASH' } @{$adapters || []} ) {
		foreach my $ip ( @{ $adapter->{'addresses'} || [] } ) {
			next unless ref $ip eq 'HASH';
			my $address = $ip->{'address'} || '';
			next unless length $address;
			if (($ip->{'family'} || 4) == 4) {
				next if $address =~ /^127\./;
				push @v4, $address unless $seen{$address}++;
			}
			else {
				next if $address eq '::1' || $address =~ /^fe80:/i;
				push @v6, $address unless $seen{$address}++;
			}
		}
	}
	return (@v4, @v6);
}

# The one shaper: an adapter hash from either backend becomes the interface
# entry the rest of the house already reads ({ nic, mac, ip, netmask, ... }).
sub windows_interface_map {
	my ($adapters) = @_;
	my %map;
	foreach my $adapter ( sort { ($a->{'ifindex'} || 0) <=> ($b->{'ifindex'} || 0) } grep { ref $_ eq 'HASH' } @{$adapters || []} ) {
		my $nic = defined $adapter->{'ifindex'} && length $adapter->{'ifindex'}
			? $adapter->{'ifindex'}
			: ($adapter->{'name'} || '');
		next unless _valid_nic($nic);
		my @ips = grep { ref $_ eq 'HASH' && length($_->{'address'} || '') } @{ $adapter->{'addresses'} || [] };
		my @v4 = grep { ($_->{'family'} || 4) == 4 } @ips;
		my @v6 = grep { ($_->{'family'} || 6) == 6 } @ips;
		my ($first4) = @v4;
		my $ip = $first4 ? $first4->{'address'} : '';
		my $prefix = $first4 && defined $first4->{'prefix'} && $first4->{'prefix'} =~ /^\d+$/ ? $first4->{'prefix'} + 0 : undef;
		my $netmask = defined $prefix ? _prefix_to_netmask($prefix) : '';
		my $broadcast = ($ip && defined $prefix) ? _broadcast_for($ip, $prefix) : '';
		my $ip6 = '';
		foreach my $six ( @v6 ) {
			next if ($six->{'address'} || '') eq '::1' || ($six->{'address'} || '') =~ /^fe80:/i;
			$ip6 = $six->{'address'};
			last;
		}
		my ($gateway) = map { $_->{'address'} } grep {
			($_->{'family'} || 4) == 4 && length($_->{'address'} || '') && $_->{'address'} ne '0.0.0.0'
		} @{ $adapter->{'gateways'} || [] };
		$map{$nic} = {
			nic          => $nic,
			name         => $adapter->{'name'} || '',
			description  => $adapter->{'description'} || '',
			adapter_name => $adapter->{'adapter_name'} || '',
			mac          => $adapter->{'mac'} || '',
			ip           => $ip,
			netmask      => $netmask,
			prefix       => defined $prefix ? $prefix : '',
			broadcast    => $broadcast,
			ip6          => $ip6,
			ips          => [ map { { family => ($_->{'family'} || 4), address => $_->{'address'}, prefix => $_->{'prefix'} } } @ips ],
			gw           => $gateway || '',
			up           => $adapter->{'up'} ? 1 : 0,
			wireless     => $adapter->{'wireless'} ? 1 : 0,
			method       => $adapter->{'method'} || 'unknown',
			rx           => 0,
			tx           => 0,
		};
	}
	return \%map;
}

sub _prefix_to_netmask {
	my ($prefix) = @_;
	return '' unless defined $prefix && $prefix =~ /^\d+$/ && $prefix >= 0 && $prefix <= 32;
	my $bits = $prefix == 0 ? 0 : ((0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF);
	return join '.', unpack('C4', pack('N', $bits));
}

sub _broadcast_for {
	my ($ip, $prefix) = @_;
	return '' unless defined $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	return '' unless defined $prefix && $prefix =~ /^\d+$/ && $prefix >= 0 && $prefix <= 32;
	my $address = unpack('N', pack('C4', split /\./, $ip));
	my $bits = $prefix == 0 ? 0 : ((0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF);
	my $broadcast = ($address | (~$bits & 0xFFFFFFFF)) & 0xFFFFFFFF;
	return join '.', unpack('C4', pack('N', $broadcast));
}

# ReadMemory does no readability checking; a pointer the API handed us points
# inside the buffer it filled, but a length that runs past the allocation must
# not take the worker down. IsBadReadPtr is the cheap guard.
sub _windows_read_memory {
	my ($pointer, $length) = @_;
	return undef unless $pointer && $length;
	return undef if eval { Win32::API::IsBadReadPtr($pointer, $length) };
	return eval { Win32::API::ReadMemory($pointer, $length) };
}

# In-process: GetAdaptersAddresses into a buffer, then the linked list read
# back with ReadMemory. The offsets below are the 64-bit IP_ADAPTER_ADDRESSES
# layout from the Windows SDK (the x64 runtime the installer ships); a 32-bit
# perl falls through to the PowerShell reader rather than guessing offsets.
sub _windows_adapters_addresses {
	return [] unless $^O eq 'MSWin32';
	return [] unless ($Config::Config{'ptrsize'} || 0) == 8;
	my $function = eval {
		require Win32::API;
		$WINDOWS_ADAPTERS_API ||= Win32::API->new('iphlpapi', 'GetAdaptersAddresses', 'NNNPP', 'N');
	};
	return [] unless $function;
	my $size = 32 * 1024;
	my ($buffer, $return, $needed);
	foreach my $try (1 .. 3) {
		$buffer = "\0" x $size;
		my $size_pointer = pack('L', $size);
		$return = eval { $function->Call(0, 0x008E, 0, $buffer, $size_pointer) };
		return [] if $@;
		$needed = unpack('L', $size_pointer);
		last if $return == 0;
		return [] unless $return == 111 || $return == 122;
		$size = $needed + 4096;
	}
	return [] unless $return == 0 && defined $buffer && length $buffer;

	my @adapters;
	my $node = $buffer;
	my $guard = 0;
	while (defined $node && length($node) >= 320 && $guard++ < 64) {
		my $ifindex = unpack('L', substr($node, 4, 4));
		my $next = unpack('Q', substr($node, 8, 8));
		my $friendly = _windows_utf16_at(unpack('Q', substr($node, 72, 8)));
		my $description = _windows_utf16_at(unpack('Q', substr($node, 64, 8)));
		my $adapter_name = _windows_ansi_at(unpack('Q', substr($node, 16, 8)));
		my $mac_length = unpack('L', substr($node, 88, 4));
		$mac_length = 0 if $mac_length > 8;
		my $mac = $mac_length
			? join(':', map { sprintf '%02x', $_ } unpack('C*', substr($node, 80, $mac_length)))
			: '';
		my $if_type = unpack('L', substr($node, 100, 4));
		my $oper_status = unpack('L', substr($node, 104, 4));
		my $dhcp_server = unpack('Q', substr($node, 232, 8));
		my $addresses = _windows_sockaddr_rows(unpack('Q', substr($node, 24, 8)), 0);
		my $gateways = _windows_sockaddr_rows(unpack('Q', substr($node, 208, 8)), 1);
		my ($first4) = grep { ($_->{'family'} || 0) == 4 } @{$addresses};
		push @adapters, {
			ifindex      => $ifindex,
			name         => $friendly,
			description  => $description,
			adapter_name => $adapter_name,
			mac          => $mac,
			up           => ($oper_status == 1 ? 1 : 0),
			wireless     => ($if_type == 71 ? 1 : 0),
			method       => ($dhcp_server ? 'dhcp' : ($first4 ? 'static' : 'none')),
			addresses    => $addresses,
			gateways     => $gateways,
		};
		last unless $next;
		$node = _windows_read_memory($next, 512);
	}
	return \@adapters;
}

# IP_ADAPTER_UNICAST_ADDRESS / IP_ADAPTER_GATEWAY_ADDRESS: union(8), Next(8),
# Address.lpSockaddr(8), Address.iSockaddrLength(4), ... and the unicast
# OnLinkPrefixLength at 56. The sockaddr's family says INET or INET6.
sub _windows_sockaddr_rows {
	my ($pointer, $is_gateway) = @_;
	my @rows;
	my $guard = 0;
	while ($pointer && $guard++ < 64) {
		my $node = _windows_read_memory($pointer, 64);
		last unless defined $node && length($node) >= 32;
		my $next = unpack('Q', substr($node, 8, 8));
		my $sockaddr = unpack('Q', substr($node, 16, 8));
		my $length = unpack('l', substr($node, 24, 4));
		if ($sockaddr) {
			my $bytes = _windows_read_memory($sockaddr, ($length && $length <= 64) ? $length : 32);
			if (defined $bytes && length($bytes) >= 8) {
				my $family = unpack('S', substr($bytes, 0, 2));
				if ($family == 2) {
					push @rows, {
						family  => 4,
						address => join('.', unpack('C4', substr($bytes, 4, 4))),
						prefix  => $is_gateway ? undef : unpack('C', substr($node, 56, 1)),
					};
				}
				elsif ($family == 23 && length($bytes) >= 24) {
					require Socket;
					push @rows, {
						family  => 6,
						address => Socket::inet_ntop(Socket::AF_INET6(), substr($bytes, 8, 16)),
						prefix  => $is_gateway ? undef : unpack('C', substr($node, 56, 1)),
					};
				}
			}
		}
		$pointer = $next;
	}
	return \@rows;
}

sub _windows_utf16_at {
	my ($pointer) = @_;
	return '' unless $pointer;
	my $bytes = _windows_read_memory($pointer, 512);
	return '' unless defined $bytes && length $bytes;
	require Encode;
	my $text = Encode::decode('UTF-16LE', $bytes);
	$text =~ s/\0.*//s;
	return $text;
}

sub _windows_ansi_at {
	my ($pointer) = @_;
	return '' unless $pointer;
	my $bytes = _windows_read_memory($pointer, 512);
	return '' unless defined $bytes && length $bytes;
	$bytes =~ s/\0.*//s;
	require Encode;
	return Encode::decode('cp1252', $bytes);
}

# Fallback: one PowerShell process, one JSON answer. Used only when Win32::API
# is absent or the IP Helper calls cannot answer (a 32-bit perl, a locked-down
# box); the result is cached with the in-process answer.
sub _windows_adapters_powershell {
	my $script = q{
$ErrorActionPreference = 'SilentlyContinue'
$adapters = @(Get-NetAdapter | Select-Object Name,InterfaceDescription,ifIndex,Status,MacAddress,PhysicalMediaType)
$ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex,IPAddress,PrefixLength,PrefixOrigin)
$ipv6 = @(Get-NetIPAddress -AddressFamily IPv6 | Select-Object InterfaceIndex,IPAddress,PrefixLength,PrefixOrigin)
$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceIndex,NextHop,DestinationPrefix)
@{ adapters=$adapters; ipv4=$ipv4; ipv6=$ipv6; routes=$routes } | ConvertTo-Json -Depth 4 -Compress
};
	my $powershell = JawnOS::Platform::tool_path('powershell') || 'powershell';
	my $out = _run($powershell, '-NoProfile', '-NonInteractive', '-Command', $script);
	return [] unless length $out;
	return parse_windows_net_json($out) || [];
}

# A captured or live Get-NetAdapter/Get-NetIPAddress/Get-NetRoute answer (a
# hash, or its JSON text) becomes the adapter hashes the shaper reads.
sub parse_windows_net_json {
	my ($payload) = @_;
	my $data = $payload;
	if (!ref $data) {
		return undef unless defined $data && length $data;
		$data =~ s/^\xEF\xBB\xBF//;
		require JSON::PP;
		$data = eval { JSON::PP->new->utf8(1)->allow_nonref(1)->decode($data) };
		return undef unless ref $data eq 'HASH';
	}
	my (%addresses, %gateways);
	foreach my $family (qw(ipv4 ipv6)) {
		foreach my $row ( @{ _windows_as_array($data->{$family}) } ) {
			next unless ref $row eq 'HASH';
			my $index = $row->{'InterfaceIndex'};
			next unless defined $index && length $index;
			push @{ $addresses{$index} }, {
				family  => $family eq 'ipv4' ? 4 : 6,
				address => $row->{'IPAddress'} || '',
				prefix  => $row->{'PrefixLength'},
				origin  => $row->{'PrefixOrigin'},
			};
		}
	}
	foreach my $row ( @{ _windows_as_array($data->{'routes'}) } ) {
		next unless ref $row eq 'HASH';
		my $prefix = $row->{'DestinationPrefix'} || '';
		next unless $prefix eq '0.0.0.0/0' || $prefix eq '::/0';
		my $index = $row->{'InterfaceIndex'};
		my $next_hop = $row->{'NextHop'} || '';
		next unless defined $index && length $index;
		next unless length $next_hop && $next_hop ne '0.0.0.0' && $next_hop ne '::';
		push @{ $gateways{$index} }, {
			family  => $next_hop =~ /:/ ? 6 : 4,
			address => $next_hop,
		};
	}
	my @adapters;
	foreach my $row ( @{ _windows_as_array($data->{'adapters'}) } ) {
		next unless ref $row eq 'HASH';
		my $index = defined $row->{'ifIndex'} ? $row->{'ifIndex'} : $row->{'InterfaceIndex'};
		next unless defined $index && length $index;
		my $mac = lc($row->{'MacAddress'} || '');
		$mac =~ s/-/:/g;
		my $description = $row->{'InterfaceDescription'} || '';
		my $media = $row->{'PhysicalMediaType'} || '';
		my @ip = @{ $addresses{$index} || [] };
		my ($first4) = grep { ($_->{'family'} || 0) == 4 } @ip;
		my $method = 'none';
		if ($first4) {
			$method = (defined $first4->{'origin'} && "$first4->{'origin'}" eq '3') ? 'dhcp' : 'static';
		}
		push @adapters, {
			ifindex      => $index,
			name         => $row->{'Name'} || '',
			description  => $description,
			adapter_name => '',
			mac          => $mac,
			up           => (($row->{'Status'} || '') =~ /^up$/i ? 1 : 0),
			wireless     => (($media =~ /802\.11|wireless|wi-?fi/i || $description =~ /wireless|wi-?fi/i || ($row->{'Name'} || '') =~ /wireless|wi-?fi/i) ? 1 : 0),
			method       => $method,
			addresses    => \@ip,
			gateways     => $gateways{$index} || [],
		};
	}
	return \@adapters;
}

sub _windows_as_array {
	my ($value) = @_;
	return [] unless defined $value;
	return $value if ref $value eq 'ARRAY';
	return [ $value ] if ref $value eq 'HASH';
	return [];
}

# GetIpNetTable(): MIB_IPNETTABLE = DWORD count + MIB_IPNETROW[count], each row
# 24 bytes: ifIndex, phys length, phys address[8], IPv4 (network order), type.
sub _windows_neigh_rows {
	my ($nic) = @_;
	return [] unless _valid_nic($nic);
	my $now = time;
	if (!$windows_neighbour_state{'at'} || $now - $windows_neighbour_state{'at'} > $WINDOWS_NEIGHBOUR_TTL) {
		$windows_neighbour_state{'rows'} = _windows_neigh_table();
		$windows_neighbour_state{'at'} = $now;
	}
	return [ grep { ($_->{'ifindex'} || '') eq $nic } @{ $windows_neighbour_state{'rows'} || [] } ];
}

sub _windows_neigh_table {
	my $rows = _windows_neigh_table_api();
	return $rows if @{$rows};
	return _windows_neigh_table_powershell();
}

sub _windows_neigh_table_api {
	return [] unless $^O eq 'MSWin32';
	my $function = eval { require Win32::API; Win32::API->new('iphlpapi', 'GetIpNetTable', 'PPN', 'N') };
	return [] unless $function;
	my $size = 32 * 1024;
	my ($buffer, $return, $needed);
	foreach my $try (1 .. 3) {
		$buffer = "\0" x $size;
		my $size_pointer = pack('L', $size);
		$return = eval { $function->Call($buffer, $size_pointer, 1) };
		return [] if $@;
		$needed = unpack('L', $size_pointer);
		last if $return == 0;
		return [] unless $return == 122;
		$size = $needed + 4096;
	}
	return [] unless $return == 0;
	my $count = unpack('L', substr($buffer, 0, 4));
	my @rows;
	foreach my $i (0 .. $count - 1) {
		my $row = substr($buffer, 4 + $i * 24, 24);
		last unless length($row) == 24;
		my $index = unpack('L', substr($row, 0, 4));
		my $length = unpack('L', substr($row, 4, 4));
		next unless $length == 6;
		my $mac = join(':', map { sprintf '%02x', $_ } unpack('C*', substr($row, 8, 6)));
		next if $mac eq '00:00:00:00:00:00' || $mac eq 'ff:ff:ff:ff:ff:ff';
		next if $mac =~ /^01:00:5e:/;
		my $address = unpack('L', substr($row, 16, 4));
		my $ip = join('.', unpack('C4', pack('L', $address)));
		my ($first) = split /\./, $ip;
		next if defined $first && $first =~ /^\d+$/ && $first >= 224 && $first <= 239;
		next if $ip eq '255.255.255.255';
		my $type = unpack('L', substr($row, 20, 4));
		next unless $type == 3 || $type == 4;
		push @rows, {
			ifindex => $index,
			ip      => $ip,
			mac     => $mac,
			state   => $type == 4 ? 'PERMANENT' : 'STALE',
		};
	}
	return \@rows;
}

sub _windows_neigh_table_powershell {
	my $script = q{
$ErrorActionPreference = 'SilentlyContinue'
@(Get-NetNeighbor -AddressFamily IPv4 | Select-Object InterfaceIndex,IPAddress,LinkLayerAddress,State) | ConvertTo-Json -Depth 3 -Compress
};
	my $powershell = JawnOS::Platform::tool_path('powershell') || 'powershell';
	my $out = _run($powershell, '-NoProfile', '-NonInteractive', '-Command', $script);
	return [] unless length $out;
	return parse_windows_neighbours_json($out) || [];
}

sub parse_windows_neighbours_json {
	my ($payload) = @_;
	my $data = $payload;
	if (!ref $data) {
		return [] unless defined $data && length $data;
		$data =~ s/^\xEF\xBB\xBF//;
		require JSON::PP;
		$data = eval { JSON::PP->new->utf8(1)->allow_nonref(1)->decode($data) };
		return [] unless defined $data;
	}
	my %state = (0 => 'FAILED', 1 => 'INCOMPLETE', 2 => 'PROBE', 3 => 'DELAY', 4 => 'STALE', 5 => 'REACHABLE', 6 => 'PERMANENT');
	my @rows;
	foreach my $row ( @{ _windows_as_array($data) } ) {
		next unless ref $row eq 'HASH';
		my $index = $row->{'InterfaceIndex'};
		my $ip = $row->{'IPAddress'} || '';
		next unless defined $index && length $index && length $ip;
		my $mac = lc($row->{'LinkLayerAddress'} || '');
		$mac =~ s/-/:/g;
		my $word = $row->{'State'};
		$word = $state{"$word"} if defined $word && exists $state{"$word"};
		push @rows, { ifindex => $index, ip => $ip, mac => $mac, state => $word || '' };
	}
	return \@rows;
}

# The raw `ip neigh` line shape, so Device.pm's split(' ') keeps working:
#   IP lladdr MAC STATE
# Multicast, broadcast and unresolved rows are not neighbours.
sub windows_neighbour_lines {
	my ($rows) = @_;
	my @lines;
	foreach my $row ( @{$rows || []} ) {
		next unless ref $row eq 'HASH';
		my $ip = $row->{'ip'} || '';
		my $mac = lc($row->{'mac'} || '');
		$mac =~ s/-/:/g;
		next unless length $ip;
		next unless $mac =~ /^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$/;
		next if $mac eq '00:00:00:00:00:00' || $mac eq 'ff:ff:ff:ff:ff:ff';
		next if $mac =~ /^01:00:5e:/;
		my ($first) = split /\./, $ip;
		next if defined $first && $first =~ /^\d+$/ && $first >= 224 && $first <= 239;
		next if $ip eq '255.255.255.255';
		my $state = $row->{'state'} || '';
		push @lines, $ip . ' lladdr ' . $mac . (length $state ? ' ' . $state : '');
	}
	return \@lines;
}

1;
