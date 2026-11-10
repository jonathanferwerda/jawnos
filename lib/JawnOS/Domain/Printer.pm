package subs;

# Printer: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);
use JawnOS::Platform::Print ();

our $device;
our $log;
our %m;

# What a printer says about its own consumables, read over IPP by the print
# seam. The argv, the six-second bound and the reply parse live there so the
# platform can answer this read on another OS; a printer that is off still
# leaves its row saying why.
sub printer_ink_levels {
	my ($ip) = @_;
	return JawnOS::Platform::Print::ink($ip);
}

# The JawnOS devices the local network advertises on _jawnos._tcp, keyed by
# address, MAC and chip_id so a scanned device is recognised however it is known.
# The firmware puts purpose/model/caps in the TXT records (see jw/jt/alarmclock).
sub mdns_devices {
	# What the fleet advertises on _jawnos._tcp: purpose, model, abilities and the
	# radio address. The responder is the ESP-IDF one, back after a spell without it:
	# its log is off in the firmware and the console lock that log path needs is
	# primed at boot, which were the two halves of the panic it used to cause.
	my $records = &mdns_browse('_jawnos._tcp');
	my (%by_ip, %by_mac, %by_chip);
	foreach my $r (@{$records}) {
		my $f = $r->{'fields'} || {};
		my $dev = {
			ip => $r->{'ip'},
			port => $f->{'port'} || $r->{'port'},
			chip_id => $f->{'chip_id'},
			name => $f->{'name'} || $r->{'name'},
			purpose => $f->{'purpose'},
			model => $f->{'model'} || $r->{'model'},
			mac => ($f->{'mac'} && $f->{'mac'} =~ /^[0-9a-fA-F:]{17}$/) ? lc $f->{'mac'} : $r->{'mac'},
			capabilities => $f->{'caps'},
			hostname => $r->{'hostname'},
		};
		$by_ip{$dev->{'ip'}} ||= $dev;
		$by_mac{$dev->{'mac'}} ||= $dev if $dev->{'mac'};
		$by_chip{$dev->{'chip_id'}} ||= $dev if $dev->{'chip_id'};
	}
	return { by_ip => \%by_ip, by_mac => \%by_mac, by_chip => \%by_chip };
}

# Fold what mDNS knows into an address map in place: name the JawnOS devices and
# the printers on each network, and add any the neighbour read missed, so a
# device answers what it is the moment it appears. Returns 1 if anything changed.
sub mdns_merge_address {
	my ($address) = @_;
	return 0 unless ref $address eq 'HASH';
	my $devices = &mdns_devices();
	my $printers = &mdns_printers();
	# never list this machine among the devices it found
	my %self_ip = map { $_->{'ip'} => 1 } grep { $_->{'ip'} } values %{$address};
	my $changed = 0;
	foreach my $nic (keys %{$address}) {
		my $nic_ip = $address->{$nic}->{'ip'};
		next unless $nic_ip && $nic_ip !~ /^127\./;
		$address->{$nic}->{'neigh'} ||= [];
		my $neigh = $address->{$nic}->{'neigh'};
		foreach my $n (@{$neigh}) {
			my $d = $devices->{'by_ip'}->{$n->{'ip'}}
				|| ($n->{'mac'} ? $devices->{'by_mac'}->{$n->{'mac'}} : undef)
				|| ($n->{'chip_id'} ? $devices->{'by_chip'}->{$n->{'chip_id'}} : undef);
			my $p = $d ? undef : ($printers->{'by_ip'}->{$n->{'ip'}} || ($n->{'mac'} ? $printers->{'by_mac'}->{$n->{'mac'}} : undef));
			my $src = $d || $p;
			next unless $src;
			if (!$n->{'purpose'} || $n->{'purpose'} eq 'hmmm') {
				my $want = $d ? $src->{'purpose'} : 'printer';
				if ($want) { $n->{'purpose'} = $want; $changed = 1; }
			}
			foreach my $f (qw/name model chip_id capabilities/) {
				next unless $src->{$f} && !$n->{$f};
				$n->{$f} = $src->{$f}; $changed = 1;
			}
			if ($src->{'mac'} && (!$n->{'mac'} || $n->{'mac'} !~ /^[0-9a-f:]{17}$/i)) {
				$n->{'mac'} = $src->{'mac'}; $changed = 1;
			}
			if ($d && $d->{'port'} && !$n->{'PORT_DOCK'}) { $n->{'PORT_DOCK'} = $d->{'port'}; $changed = 1; }
			# a device that named its radio in the TXT: keep the Bluetooth address
			# where the bridge looks for it (bluetooth_sender reads this field)
			if ($d && $d->{'mac'}) {
				my $ma = $n->{'mac_addresses'};
				$ma = eval { decode_json $ma } if $ma && !ref $ma;
				$ma = {} unless ref $ma eq 'HASH';
				if (!$ma->{'bluetooth'}) { $ma->{'bluetooth'} = uc $d->{'mac'}; $n->{'mac_addresses'} = $ma; $changed = 1; }
			}
		}
		foreach my $d (values %{$devices->{'by_ip'}}) {
			next if $self_ip{$d->{'ip'}};
			next unless &same_net_test($d->{'ip'}, $nic_ip) eq 'yes';
			next if grep { $_->{'ip'} eq $d->{'ip'} } @{$neigh};
			push @{$neigh}, {
				ip => $d->{'ip'}, mac => $d->{'mac'} || &subs::random_string_creator(10),
				uuid => &subs::random_string_creator(25), purpose => $d->{'purpose'},
				name => $d->{'name'}, model => $d->{'model'}, chip_id => $d->{'chip_id'},
				capabilities => $d->{'capabilities'}, PORT_DOCK => $d->{'port'},
				mac_addresses => ($d->{'mac'} ? { bluetooth => uc $d->{'mac'} } : undef),
			};
			$changed = 1;
		}
		foreach my $p (values %{$printers->{'by_ip'}}) {
			next if $self_ip{$p->{'ip'}};
			next unless &same_net_test($p->{'ip'}, $nic_ip) eq 'yes';
			next if grep { $_->{'ip'} eq $p->{'ip'} } @{$neigh};
			push @{$neigh}, {
				ip => $p->{'ip'}, mac => $p->{'mac'} || &subs::random_string_creator(10),
				uuid => &subs::random_string_creator(25), purpose => 'printer',
				name => $p->{'name'}, model => $p->{'model'},
			};
			$changed = 1;
		}
	}
	return $changed;
}

# The light half of a scan, on a timer: fold what mDNS knows into this machine's
# own device row, so a device plugged in is named within seconds without running
# the whole interface scan. Writes only when something changed.
sub device_mdns_sync {
	# The gateway is usually the one appliance that never runs jawn, so it is
	# discovered here rather than by the peer mesh. Throttled inside.
	eval { &router_discover(); };
	my $hostname = &subs::machine_hostname();
	my $row = &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
	return unless $row && $row->{'address'};
	my $address = eval { decode_json $row->{'address'} } || {};
	return unless ref $address eq 'HASH' && %{$address};
	# This machine's own interfaces move with it. Refresh the NIC addresses from
	# the live report before folding mDNS in, so the Dev panel's network cards and
	# its neighbour placement follow a new network without a manual Scan. A blank
	# report is a failed read, not a machine with no interfaces: never wipe the row
	# for it.
	my $current = &network_interface_reporter();
	return unless ref $current eq 'HASH' && %{$current};
	my $net_changed = 0;
	foreach my $nic ( keys %{$current} ) {
		my $old = $address->{$nic} || {};
		my $old_ip = $old->{'ip'} // '';
		my $new_ip = $current->{$nic}->{'ip'} // '';
		foreach my $k ( keys %{$current->{$nic}} ) {
			next if (($old->{$k} // '') eq ($current->{$nic}->{$k} // ''));
			$old->{$k} = $current->{$nic}->{$k};
			$net_changed = 1;
		}
		$address->{$nic} = $old;
		if ($old_ip && $new_ip && $old_ip ne $new_ip && ref $old->{'neigh'} eq 'ARRAY') {
			# A NIC that moved networks cannot still have neighbours on the old
			# subnet; leaving them made the Dev panel show a device at its old
			# address beside the current one.
			my @keep = grep {
				ref $_ eq 'HASH'
				&& ($_->{'ip'} // '') =~ /^\d{1,3}(\.\d{1,3}){3}$/
				&& &same_net_test($new_ip, $_->{'ip'}) eq 'yes'
			} @{$old->{'neigh'}};
			if (scalar @keep != scalar @{$old->{'neigh'}}) {
				$old->{'neigh'} = \@keep;
				$net_changed = 1;
			}
		}
	}
	foreach my $nic ( keys %{$address} ) {
		next if $nic eq 'public_address' || $current->{$nic};
		delete $address->{$nic};
		$net_changed = 1;
	}
	my $mdns_changed = &mdns_merge_address($address);
	return unless $mdns_changed || $net_changed;
	my $now = &rightNow();
	&subs::db_update('devices', { address => encode_json $address, timestamp => $now, server_time => $now }, { hostname => $hostname });
	# A machine that just joined a network repaints an open Dev panel at once; the
	# peer beacons handle their own rows in lan_presence_accept.
	eval { &Websocket::send('server', { console => &Websocket::console_command('deviceLister')}) } if $net_changed;
}

# An address and its netmask as a CIDR: 192.168.2.3 + 255.255.255.0 ->
# 192.168.2.0/24. Returns undef for anything that is not a plain IPv4 address,
# and reads a hex netmask (0xffffff00) the way some ifconfig builds print it.
sub subnet_cidr {
	my ($ip, $netmask) = @_;
	return undef unless defined $ip && $ip =~ /^\d{1,3}(\.\d{1,3}){3}$/;
	my $mask = $netmask;
	if (!defined $mask || $mask !~ /^\d{1,3}(\.\d{1,3}){3}$/) {
		if (defined $mask && $mask =~ /^0x([0-9a-fA-F]{1,8})$/) {
			my $h = ('0' x (8 - length $1)) . $1;
			$mask = join '.', map { hex } ($h =~ /(..)(..)(..)(..)/);
		}
		else {
			$mask = '255.255.255.0';
		}
	}
	my @i = map { $_ + 0 } split /\./, $ip;
	my @m = map { $_ + 0 } split /\./, $mask;
	my (@net, $bits);
	$bits = 0;
	for my $k (0..3) {
		push @net, $i[$k] & $m[$k];
		my $o = $m[$k];
		while ($o) { $bits += ($o & 1); $o >>= 1; }
	}
	return join('.', @net) . '/' . $bits;
}

# `ip neigh` is only the ARP cache: a device this machine has never spoken to -
# a printer, a fresh appliance - is simply absent from it until something pings
# the network once. On an explicit scan, sweep the NIC's own subnet so those
# hosts answer and land in the cache the neighbour read then relies on. The
# sweep keeps its own bound so a slow or filtered network cannot stall a scan.
sub subnet_sweep {
	my ($nic, $ip, $netmask) = @_;
	return if !$ip || $ip !~ /^\d{1,3}(\.\d{1,3}){3}$/;
	return if $ip =~ /^127\./;
	return unless &ip_is_private($ip);
	my $cidr = &subnet_cidr($ip, $netmask);
	return unless $cidr;
	my $nmap = `command -v nmap 2>/dev/null`;
	chomp $nmap;
	# the manager's PATH is not the login shell's, so try the usual homes too
	for my $p (qw(/usr/bin/nmap /usr/local/bin/nmap /bin/nmap /usr/sbin/nmap)) {
		$nmap ||= $p if -x $p;
	}
	if ($nmap) {
		# -sn: host discovery only (ARP on-link), no port scan.
		`timeout 30 $nmap -sn -n -T4 --max-retries 1 $cidr 2>/dev/null`;
		return;
	}
	# No nmap: ping the network (a /24 at most) in parallel so the ARP cache
	# fills. A wider subnet is left to the neighbour table alone.
	my ($prefix) = $cidr =~ m{/(\d+)\z};
	return unless $prefix && $prefix >= 24;
	my ($net) = split m{/}, $cidr;
	my @o = split /\./, $net;
	my @hosts;
	for my $h (1 .. 254) {
		my @hh = @o;
		$hh[3] = $h;
		push @hosts, join('.', @hh);
	}
	open(my $ping, '|-', 'timeout 20 xargs -P 48 -n 1 ping -c 1 -W 1 >/dev/null 2>&1') or return;
	print $ping join("\n", @hosts), "\n";
	close $ping;
}

1;
