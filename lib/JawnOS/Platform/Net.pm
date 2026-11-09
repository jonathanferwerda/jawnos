package JawnOS::Platform::Net;

# Interface, route and neighbour reads behind one interface. Linux runs
# ifconfig/iproute2 and parses the same shapes the domain code did; macOS and
# Windows get their commands in the P2/P3 landings. A platform that cannot
# answer returns {} or '' rather than dying.
#
# The parsers are exported so fixtures can pin the formats: ifconfig's block
# layout (macOS and Linux spellings), `ip route show 0.0.0.0/0 dev X`, and
# `ip neigh show dev X` (IP [lladdr MAC] STATE).

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
	interfaces interface_names gateway gateway_mac neighbour_lines
	parse_ifconfig parse_route parse_neigh
);

BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
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
	return [] unless $^O eq 'linux';
	my $ip = _tool_path('ip') or return [];
	my $out = _run($ip, 'neigh', 'show', 'dev', $nic);
	return [ grep { /\S/ } split /\n/, $out ];
}

1;
