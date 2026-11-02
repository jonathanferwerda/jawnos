package subs;

# Device: extracted from subroutines.pl (package subs). Loaded on
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

our $config;
our $database;
our $device;
our $gb;
our %m;

sub device_scan {
	my ($timestamp, $load_type, $ip_range) = @_;
	my (undef, $database) = &subs::database_grabber();
	my ($dev,$devices,@domains);
	my $user_agent = $gb::user_agent;
	my $server_time = &subs::rightNow();
	my $my_name = &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	my $signatorial = &subs::signatorial_designer();
	my $chip_ids = [];
	$dev = &subs::db_select('devices');
	$devices = $dev->hashes;
	# A machine in the mesh is a device we know even when it is away right now,
	# so a scan keeps its last sighting rather than pruning it with the rest. The
	# address may be its own name, or any LAN address it last reported.
	my %known_machine_ip;
	foreach my $rm (@{ &subs::db_select('remote_machines')->hashes }) {
		$known_machine_ip{$rm->{'ip'}} = 1 if $rm->{'ip'};
		my $net = eval { decode_json $rm->{'network'} } || {};
		foreach my $rnic (keys %{$net}) {
			my $rip = $net->{$rnic}->{'ip'};
			$known_machine_ip{$rip} = 1 if $rip && $rip !~ /^127\./;
		}
	}
	my $ug    = Data::UUID->new;
	my $uuid = $ug->create_str();
	foreach my $d (@{$devices}) {
		if (scalar @{$devices} > 0) {
			$d->{'address'} = eval { return decode_json $d->{'address'} };
			if ($d->{'domain'} ne '') {
				push @domains, { 'domain' => $d->{'domain'} . ' lladdr ' . 'mac_ave', hostname => $d->{'hostname'} };
			}
		}
	}
	my $hostname = `hostname`;
	my @me_device = grep { $_->{'hostname'} eq $hostname } @{$devices};
	chomp $hostname;
	my $uname = `uname -a`;
	chomp $uname;
	my $username = 'jawn';#`whoami`;
	chomp $username;

	my $name = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || $hostname;
	my $cpuinfo = `cat /proc/cpuinfo`;
	chomp $cpuinfo;
	my $ifc = &subs::device_setter() eq 'server' ? '/usr/sbin/ifconfig' : 'ifconfig 2>/dev/null | grep -v "Permission denied"';
	my @ifconfig = split "\n\n", `$ifc`;
	my @ifconfig_link;
	my @ifconfig_inet;
	my $address = {};
	my $count = {};
	my $home_ip;
	foreach my $if (@ifconfig) {
		my @ifconfig_list = split "\n", $if;

		@ifconfig_inet = grep { $_ =~ /inet/ } @ifconfig_list;

		my $nic = (split ' ', $ifconfig_list[0])[0];
		$nic =~ s/://;
		$address->{$nic}->{'nic'} = $nic;
		my $gw = '$(ip route show 0.0.0.0/0 dev ' . $address->{$nic}->{'nic'} . ' | cut -d\  -f3)';
		$address->{$nic}->{'gw'} = `echo $gw`;
		chomp $address->{$nic}->{'gw'};
		if ($device eq 'computer' || $device eq 'server') {
			my $gw_mac = '/usr/sbin/arp -a ' . $gw . '  | grep ' . $address->{$nic}->{'nic'};
			$gw_mac = `$gw_mac`;
			$address->{$nic}->{'gw_mac'} = (split ' ', $gw_mac)[3] if $gw && $device eq 'computer';
		}
		foreach my $i (@ifconfig_inet) {
			my @inet = split " ", $i;
			if ($i =~ /inet /) {
				$address->{$nic}->{'ip'} = $inet[1];
				$address->{$nic}->{'port'} = $ENV{PORT_AHOY};
				$address->{$nic}->{'ws_port'} = $ENV{PORT_MSG};
				$address->{$nic}->{'alarm_port'} = $ENV{PORT_BELL};
				$address->{$nic}->{'arm_port'} = $ENV{PORT_ARM};
				$address->{$nic}->{'bestow_port'} = $ENV{PORT_BESTOW};
				$address->{$nic}->{'coms_port'} = $ENV{PORT_COMS};
				$address->{$nic}->{'dock_port'} = $ENV{PORT_DOCK};
				$address->{$nic}->{'manager'} = 'https://' . $inet[1] . ':' . $ENV{PORT_DOCK} .  '/manager';
				$address->{$nic}->{'netmask'} = $inet[3];
				$address->{$nic}->{'broadcast'} = $inet[5];

				# A device nobody here has talked to is missing from the ARP cache
				# the read below depends on, so on an explicit scan sweep this
				# network first and let the answers fill it in.
				&subnet_sweep($nic, $address->{$nic}->{'ip'}, $address->{$nic}->{'netmask'}) if $load_type eq 'scan';

				my @neighbours;
				my $neighbour_check = `ip neigh show dev $nic`;
				my @neighbourinos;
				if ($load_type ne 'ping_scan') {
					@neighbourinos = (split "\n", $neighbour_check);
				}
				if ($ip_range) {
					# a host or range typed into the box is honoured even when the
					# neighbour table has entries: the device that pings but sleeps
					# its wifi (an esp32) is exactly the one missing from the table
					my $sip = $ip_range;
					$sip =~ s/[0-9]//gi;
					$home_ip = $address->{$nic}->{'ip'};
					my @home_ip = split '\.', $home_ip;
					my @csv = split ',', $ip_range;
					my @ip = split '\.', $ip_range;
					if (scalar @ip == 4) {
						if (&same_net_test($ip_range,$home_ip)) {
							push @neighbourinos, $ip_range . ' ' . &subs::random_string_creator(5);
						}
					}
					else {
						if (scalar @csv > 1) {
							foreach my $csv (@csv) {
								pop @home_ip;
								push @home_ip, $csv;
								push @neighbourinos, (join '.', @home_ip) . ' ' . &subs::random_string_creator(5);
							}
						}
						elsif ($sip eq '..' ) {
							my @sips = split '\.\.', $ip_range;

							foreach my $csv ( $sips[0] .. $sips[1] ) {
								pop @home_ip;
								push @home_ip, $csv;
								push @neighbourinos, (join '.', @home_ip ). ' ' . &subs::random_string_creator(5);
							}
						}
					}
				}
				foreach my $do ( @domains ) {
					push @neighbourinos, $do->{'domain'} if $do->{'hostname'} eq $hostname;
				}
				# `ip neigh` never lists the loopback interface's own address, and the
				# tunnels this server holds hang off exactly that 127.0.0.1 row below -
				# so on cloud no tunnelled machine ever showed at all. Put the row in:
				# it marks this machine, and every active tunnel becomes one of its
				# neighbours, reached on the hub-side port the tunnel reserved.
				if (&subs::device_setter() eq 'server'
					&& ($address->{$nic}->{'ip'} || '') eq '127.0.0.1'
					&& !grep { (split ' ', $_)[0] eq '127.0.0.1' } @neighbourinos) {
					push @neighbourinos, '127.0.0.1 ' . &subs::random_string_creator(5);
				}
				foreach my $m ( @neighbourinos ) {
					# `ip neigh show dev X` prints only `IP [lladdr MAC] STATE`, and a host
					# the sweep half-resolved reads INCOMPLETE (or FAILED/PROBE): it never
					# answered, so it is no device. Keep the resolved rows and the typed
					# host and self row, which carry no state word at all.
					next if $m =~ /\b(?:FAILED|INCOMPLETE|PROBE)\b/;
					my @l = (split " ", $m);
					# the sweep reports this machine among its own neighbours; the
					# loopback row below is the exception, it marks this machine on
					# purpose (and carries the tunnels)
					next if $l[0] && $l[0] ne '127.0.0.1' && $l[0] eq ($address->{$nic}->{'ip'} || '');
					my $n = {
						ip => $l[0],
						mac => $l[2] || &subs::random_string_creator(10),
						uuid => &subs::random_string_creator(25)
					};
					my $ping_ip = $n->{'ip'};
					# a sleeping esp32 can take a second to answer the first packet
					my $alive = `timeout 1.2 ping -c 1 -W 1 $ping_ip`;
					my $ip_addresses = [ ];
					if ($n->{'ip'} eq '127.0.0.1') {
						push @{$ip_addresses}, $n;
						if (&subs::device_setter() eq 'server') {
							my $tunnels = &subs::db_select('tunnels', undef, { status => 'active' })->hashes;
							my @batches;
							foreach my $tun ( @{$tunnels} ) {
								next unless $tun->{'name'} eq 'PORT_DOCK';
								next if grep { $_ eq $tun->{'batch_uuid'} } @batches;
								push @batches, $tun->{'batch_uuid'};
								push @{$ip_addresses}, {
									# the peer, not this hub: a hub-side row carries the peer's own
									# domain in `host` and this hub's in `domain`, so naming the
									# neighbour by `domain` listed the hub itself, once per
									# tunnelled machine, and every row collapsed together
									ip => ($tun->{'host'} || $tun->{'ip'} || $tun->{'domain'}),
									domain => ($tun->{'host'} || $tun->{'ip'} || $tun->{'domain'}),
									PORT_DOCK => $tun->{'in_port'},
									tunnel => 'yes',
									mac => &subs::random_string_creator(10),
									signatorial => $tun->{'signatorial'},
									uuid => &subs::random_string_creator(25)
								};


							}


						}
					}
					elsif ($n->{'ip'} =~ /127\.0\.0/) { next; }
					else { push @{$ip_addresses}, $n; }
					foreach my $n ( @{$ip_addresses} ) {
						if ( $n->{'ip'} && ($n->{'tunnel'} eq 'yes' || $alive =~ /ttl/gi )) { #&& $n->{'ip'} ne $address->{$nic}->{'ip'}) {
							my $ua = Mojo::UserAgent->new();
							# A neighbour that is not JawnOS (a printer, an appliance the sweep
							# found) must not hold the scan for the full timeout: a LAN answer
							# is milliseconds, so a couple of seconds to connect and a short
							# inactivity window keep a sweep over a busy subnet quick, while a
							# real but busy peer still has room to answer.
							$ua->connect_timeout(2);
							$ua->inactivity_timeout(5);
							my $manager = $n->{'tunnel'} eq 'yes' ? 'https://127.0.0.1:' . ($n->{'PORT_DOCK'} || $ENV{PORT_DOCK}) .  '/manager'
								: 'https://' . $n->{'ip'} . ':' . ($n->{'PORT_DOCK'} || $ENV{PORT_DOCK}) .  '/manager';
							my $res = eval { $ua->insecure(1)->get($manager . '/gate?restore_list=' . $config->{'start_dir'} . '&neighbour=' . $hostname . '&my_name=' . $my_name . '&signatorial=' . $signatorial => {user_agent => $user_agent})->result };
							if (eval { $res->is_success }){
								if (eval { decode_json $res->body }) {
									my $rb = decode_json $res->body;
									$n->{'purpose'} = $rb->{'purpose'};
									$n->{'restore_list'} = encode_json $rb->{'restore_list'};
									$n->{'signatorial'} = $rb->{'signatorial'};
									$n->{'name'} = $rb->{'name'};
								}
								$n->{'manager'} = $manager;
							}
							else {
								my $manager = 'http://' . $n->{'ip'} . ':' . ($n->{'PORT_DOCK'} || $ENV{PORT_DOCK}) .  '/device_query';
								my $res = eval { $ua->insecure(1)->get($manager) };
								if (eval { $res->result->body }) {
									if (eval { decode_json $res->result->body }) {
										my $rb = decode_json $res->result->body;
										$n->{'purpose'} = $rb->{'purpose'};
										$n->{'model'} = $rb->{'model'};
										$n->{'pins'} = $rb->{'pins'} if $rb->{'pins'};
										$n->{'name'} = $rb->{'name'} if $rb->{'name'};
										$n->{'chip_id'} = $rb->{'chip_id'};
										$n->{'mac_addresses'} = $rb->{'mac_addresses'};
										$n->{'mac'} = $rb->{'mac_addresses'}->{'base'};
										$n->{'service_uuid'} = $rb->{'SERVICE_UUID'} if $rb->{'SERVICE_UUID'};
										$n->{'characteristic_uuid_rx'} = $rb->{'CHARACTERISTIC_UUID_RX'} if $rb->{'CHARACTERISTIC_UUID_RX'};
										$n->{'characteristic_uuid_tx'} = $rb->{'CHARACTERISTIC_UUID_TX'} if $rb->{'CHARACTERISTIC_UUID_TX'};
										push @{$chip_ids}, { id => $n->{'chip_id'}, name => $n->{'name'}, purpose => $n->{'purpose'}, server_time => &subs::rightNow() };
									}
								}
								else {
									$n->{'purpose'} = 'hmmm';
								}
							}
						}
						foreach my $d (@{$devices}) {
							foreach my $a (keys %{$d->{'address'}} ) {
								foreach my $g (grep { $_->{'ip'} eq $n->{'ip'} || $_->{'ip_address'} eq $n->{'ip'} } @{$d->{'address'}->{$a}->{'neigh'}} ) {
									$g->{'ip'} =~ /([0-9]+)$/gi;
									my $last_d = $1;
									$n->{'ip'} =~ /([0-9]+)$/gi;
									my $last_n = $1;
									$n->{'fqdn'} = $g->{'fqdn'};
									$n->{'mac'} = $g->{'mac'} || $n->{'mac'};
									$n->{'ip_address'} = $g->{'ip_address'};
									# a device that does not answer the query is marked
									# 'hmmm'; a purpose a person set earlier beats that
									# placeholder, so a printer stays the printer
									if ($g->{'purpose'} && (!$n->{'purpose'} || $n->{'purpose'} eq 'hmmm')) {
										$n->{'purpose'} = $g->{'purpose'};
									}
									if ($g->{'locked'} eq 'yes') {
										$g->{'uuid'} = $n->{'uuid'} unless $g->{'uuid'};
										$n = $g;
									}
								}
							}
						}
						push @neighbours, $n;
					}


				}
				foreach my $n ( @neighbours ) {
					@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $n->{'ip'} } @{$address->{$nic}->{'neigh'}};
					push @{$address->{$nic}->{'neigh'}}, $n;
				}
				# One row per address: the typed host and the neighbour table can name
				# the same device, and the scan rendered it twice (2026-10-09). The
				# richer row wins -- the one the device itself answered.
				my %neigh_seen;
				my @neigh_deduped;
				foreach my $n ( @neighbours ) {
					my $neigh_ip = $n->{'ip'};
					if (my $had = $neigh_seen{$neigh_ip}) {
						foreach my $f ( qw/chip_id purpose name model mac mac_addresses uuid fqdn/ ) {
							$had->{$f} = $n->{$f} if $n->{$f} && !$had->{$f};
						}
						next;
					}
					$neigh_seen{$neigh_ip} = $n;
					push @neigh_deduped, $n;
				}
				@neighbours = @neigh_deduped;
				@{$address->{$nic}->{'neigh'}} = @neighbours;

			}
			if ($i =~ /inet6 /) {
				$address->{$nic}->{'ip6'} = $inet[1];
			}
		}
		@ifconfig_link = grep { $_ =~ /ether/ } @ifconfig_list;
		foreach my $m (@ifconfig_link) {
			my @mac = split " ", $m;
			if ($m =~ /ether/) {
				$address->{$nic}->{'mac'} = $mac[1];
			}
		}
		#here

		foreach my $d (@{$devices}) {
			foreach my $a (keys %{$d->{'address'}} ) {
				if ($d->{'address'}->{$nic}->{'neigh'} && $a eq $nic) {
					foreach my $rd ( @{$d->{'address'}->{$nic}->{'neigh'}} ) {
						# A device we have a reason to keep stays on the list even when this
						# scan did not see it: one the person locked, a machine in the mesh
						# (a remote_machine, or anything that named itself with a signatorial),
						# or one the person gave a real purpose. Everything else is a passing
						# sighting and is pruned.
						my $known = (($rd->{'locked'} || '') eq 'yes')
							|| $rd->{'signatorial'}
							|| $known_machine_ip{$rd->{'ip'}}
							|| ((($rd->{'purpose'} || '') ne '') && $rd->{'purpose'} ne 'hmmm');
						next unless $known;
						if (($rd->{'locked'} || '') eq 'yes') {
							# a locked device: its stored row wins outright
							@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $rd->{'ip'} } @{$address->{$nic}->{'neigh'}};
							push @{$address->{$nic}->{'neigh'}}, $rd;
						}
						elsif (!grep { $_->{'ip'} eq $rd->{'ip'} } @{$address->{$nic}->{'neigh'}}) {
							# a known device that is away just now: keep its last sighting
							push @{$address->{$nic}->{'neigh'}}, $rd;
						}
						push @{$chip_ids}, { id => $rd->{'chip_id'}, name => $rd->{'name'}, purpose => $rd->{'purpose'}, server_time => &subs::rightNow() } if $rd->{'chip_id'};
					}
				}
			}
		}
	}

	# mDNS names what the neighbour read cannot: a JawnOS device on _jawnos._tcp
	# says its purpose, model and abilities, and a printer says it is a printer,
	# so the devices answer for themselves the moment they join the network.
	&mdns_merge_address($address) if $load_type eq 'scan';

	my $json_address = encode_json $address;

	my @my_device = grep { ($_->{'hostname'} && $_->{'hostname'} eq $hostname) } @{$devices};
	my $president = $database;


	# A plain read of $my_device[0]->{...} autovivifies that slot, so an
	# empty match would become a one-element array and send the branch below
	# into an update against a row that is not there (a phone with no self
	# row yet). Keep the read guarded so "no row" stays empty and the insert
	# branch can create it.
	my $oldjchips = @my_device ? $my_device[0]->{'chip_ids'} : undef;
	my $oldchips = eval { return decode_json $oldjchips } || [];
	if (scalar @{$oldchips} > 0) {
		foreach my $ci ( @{$oldchips} ) {
			push @{$chip_ids}, $ci unless grep { $_->{'id'} eq $ci->{'id'} } @{$chip_ids};
		}
	}
	my $jchips = encode_json $chip_ids;
	my $me = {
		timestamp => $timestamp,
		hostname => $hostname,
		uname => $uname,
		address => $json_address,
		protocol => 'https',
		port => $ENV{PORT_AHOY},
		server_time => $server_time,
		president => $president,
		uuid => $uuid,
		chip_ids => $jchips
	};
	if (scalar @my_device == 0 || scalar @{$devices} == 0) {
		&subs::db_insert('devices', $me);
	}
	else {
		&subs::db_update('devices', { chip_ids => $jchips, address => $json_address, timestamp => $timestamp }, { hostname => $hostname });
	}
}

# This machine's own row in `devices`, created without a browser. The one Scan
# that used to build it runs in Configure -> Dev, so a headless server never had
# a self row - and with no row this hub has no `address` map at all, so the
# tunnels it holds can never be listed as its own neighbours (tunnel_checker
# hangs them off that row; device_scan is otherwise the only writer). Built from
# the same interface report device_scan writes, so the two agree on shape. Cheap
# when the row already exists (one select), so a per-tick caller is fine.
# The self row is written by device_scan, which only runs on a real scan. A
# phone or tablet that never presses Scan therefore kept the address map it
# had (often `{}`) and peers could not learn its LAN address. Every
# device_lister pass refreshes it from the interface report, and only when the
# interface/address signature moved.
sub refresh_self_address {
	my $hostname = `hostname`;
	chomp $hostname;
	return 0 unless length $hostname;
	my $address = &subs::network_interface_reporter();
	return 0 unless $address && scalar keys %{$address};
	my $want = &address_signature($address);
	my $rows = &subs::db_select('devices', undef, { hostname => $hostname })->hashes;
	return 0 unless $rows && scalar @{$rows};
	my $changed = 0;
	foreach my $row (@{$rows}) {
		my $old = eval { decode_json( $row->{'address'} || '{}' ) } || {};
		next if &address_signature($old) eq $want;
		&subs::db_update(
			'devices',
			{
				address     => encode_json $address,
				timestamp   => &subs::rightNow(),
				server_time => &subs::rightNow(),
			},
			{ uuid => $row->{'uuid'} },
		);
		$changed++;
	}
	return $changed;
}

sub ensure_self_device {
	my $hostname = `hostname`;
	chomp $hostname;
	# A blank or loopback hostname is no name to file a machine under (and would
	# make a second, shadow self row on a phone); leave those alone.
	return undef if !$hostname || $hostname eq 'localhost';
	my $existing = &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
	return $existing if $existing;
	my $address = &subs::network_interface_reporter();
	return undef unless $address && scalar keys %{$address};
	my $uname = `uname -a`;
	chomp $uname;
	my (undef, $database) = &subs::database_grabber();
	&subs::db_insert('devices', {
		timestamp => &subs::rightNow(),
		hostname => $hostname,
		uname => $uname,
		address => encode_json $address,
		protocol => 'https',
		port => $ENV{PORT_AHOY},
		server_time => &subs::rightNow(),
		president => $database,
		uuid => &subs::random_string_creator(25),
		chip_ids => '[]',
	});
	&subs::log_writer('self device row created for ' . $hostname);
	return &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
}

sub device_lister {
	my ($timestamp,$load_type,$ip_range,$chip_id) = @_;
	my ($dev,$devices);
	# A plain listing and an explicit Scan both look at the gateway; a typed
	# purpose lookup (printer, watch, ...) has no reason to probe it.
	&router_discover() unless $load_type && $load_type ne 'scan';
	&refresh_self_address();
	my $remote_machines = &subs::db_query('select * from remote_machines')->hashes;
	if ($load_type eq 'scan' || $load_type eq 'ping_scan') {
		&device_scan($timestamp, $load_type, $ip_range);
	}
	$dev = &subs::db_select('devices');
	$devices = $dev->hashes;
	# One row per address across the whole listing: a device can sit in several
	# machines' neighbour tables (and in more than one NIC of one -- the T-Deck
	# showed three times on 2026-10-09, twice on wlo1 and once under lo). The
	# richest entry wins -- the one the device itself answered -- and every
	# other copy is dropped before the tables render. 127.0.0.1 is left alone:
	# it is how each machine marks itself.
	{
		my %best;
		my $richness = sub {
			my ($n, $nic) = @_;
			my $r = 0;
			$r += 4 if $n->{'chip_id'};
			$r += 2 if $n->{'model'} || $n->{'mac_addresses'};
			$r += 2 if ($n->{'purpose'} || '') ne '' && $n->{'purpose'} ne 'hmmm';
			$r += 1 if $n->{'name'} || $n->{'fqdn'};
			$r -= 2 if $nic eq 'lo';
			return $r;
		};
		foreach my $d (@{$devices}) {
			$d->{'address'} = eval { return decode_json $d->{'address'} } if $d->{'address'} && !ref $d->{'address'};
			my @self_ips = map { $d->{'address'}->{$_}->{'ip'} } keys %{$d->{'address'} || {}};
			foreach my $a ( keys %{$d->{'address'} || {}} ) {
				foreach my $n ( @{$d->{'address'}->{$a}->{'neigh'} || []} ) {
					my $ip = $n->{'ip'} || $n->{'ip_address'};
					next unless $ip;
					next if $ip eq '127.0.0.1' || grep { $_ && $_ eq $ip } @self_ips;
					my $r = $richness->($n, $a);
					if (!$best{$ip}) {
						$best{$ip} = [ $r, $n ];
					}
					elsif ($r > $best{$ip}->[0]) {
						foreach my $f ( keys %{$best{$ip}->[1]} ) {
							$n->{$f} = $best{$ip}->[1]->{$f} if !$n->{$f};
						}
						$best{$ip} = [ $r, $n ];
					}
					else {
						foreach my $f ( keys %{$n} ) {
							$best{$ip}->[1]->{$f} = $n->{$f} if !$best{$ip}->[1]->{$f};
						}
					}
				}
			}
		}
		foreach my $d (@{$devices}) {
			foreach my $a ( keys %{$d->{'address'} || {}} ) {
				next unless $d->{'address'}->{$a}->{'neigh'};
				@{$d->{'address'}->{$a}->{'neigh'}} = grep {
					my $ip = $_->{'ip'} || $_->{'ip_address'};
					!$ip || !$best{$ip} || $best{$ip}->[1] eq $_;
				} @{$d->{'address'}->{$a}->{'neigh'}};
			}
		}
	}
	my $all_chips = [];
	foreach my $d (@{$devices}) {
		$d->{'address'} = decode_json $d->{'address'} if $d->{'address'} && !ref $d->{'address'};
		$d->{'formatted_time'} = &subs::formatted_time($d->{'timestamp'});
		foreach my $a ( keys %{$d->{'address'}} ) {
			foreach my $n ( @{$d->{'address'}->{$a}->{'neigh'}} ) {
				if (my @pool = grep { $d->{'address'}->{$_}->{'ip'} eq $n->{'ip'} } keys %{$d->{'address'}} ) {
					$n->{'me'} = 'me';
				}
				if ($load_type eq 'watch' && $n->{'purpose'} eq 'watch') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'microcontroller' && $n->{'purpose'} eq 'microcontroller') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'printer' && $n->{'purpose'} eq 'printer') {
					return $n;
				}
				if ($load_type eq 'teletype' && $n->{'purpose'} eq 'teletype') {
					if ($chip_id) {
						if ($chip_id eq 'all') {
							push @{$all_chips}, $n;
						}
						elsif ($chip_id eq $n->{'chip_id'}) {
							$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
							return $n;
						}
					}
					else {
						$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
						return $n;
					}
				}
				if ($load_type eq 'computer' && $n->{'purpose'} eq 'computer') {
					$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
					return $n;
				}
				if ($load_type eq 'mobile' && $n->{'purpose'} eq 'mobile') {
					$n->{'homebase'} = $d->{'address'}->{$a}->{'ip'};
					return $n;
				}
				if ($gb::remote->{$n->{'ip'}} ) {
					my @rem = grep { $_->{'ip'} eq $n->{'ip'} } @{$remote_machines};
					$n->{'button'} = $rem[0]->{'buttons'};
				}
			}
		}
	}
	# Off its access point, an embedded device bridged over Bluetooth is not in
	# any machine's neighbour table, so the loops above never see it - yet it is
	# still reachable and told us so when it last spoke over the bridge
	# (ble_device_record keeps that sighting in the machine's chip_ids). Fall
	# back to it, but only while the sighting is fresh: a device away longer
	# than the window is treated like any other gone device.
	my %ble_types = map { $_ => 1 } qw/watch teletype microcontroller/;
	if ($ble_types{$load_type} && $chip_id) {
		my $window = &ble_presence_window();
		my $now = &subs::rightNow();
		# One entry per chip, the freshest sighting. The same watch is recorded in
		# every machine's synced `devices` row, so iterating them all listed - and
		# later pushed to - the same radio many times over: a single toggle became a
		# burst of identical sends.
		my %ble_by_id;
		foreach my $d ( @{$devices} ) {
			next unless $d->{'chip_ids'};
			my $chips = eval { decode_json $d->{'chip_ids'} } || [];
			foreach my $c ( @{$chips} ) {
				next unless $c->{'id'} && ($c->{'ble'} || $c->{'bluetooth'});
				next unless $window > $now - ($c->{'ble_seen'} || 0);
				my $id = $c->{'id'};
				$ble_by_id{$id} = $c
					if !$ble_by_id{$id} || ($c->{'ble_seen'} || 0) > ($ble_by_id{$id}->{'ble_seen'} || 0);
			}
		}
		my @ble = values %ble_by_id;
		if ($chip_id eq 'all') {
			push @{$all_chips}, map { &ble_device_from_chip($_, $load_type) } @ble;
		}
		else {
			foreach my $c ( @ble ) {
				next unless $c->{'id'} eq $chip_id;
				return &ble_device_from_chip($c, $load_type);
			}
		}
	}
	if (scalar @{$all_chips} > 0) {
		return $all_chips;
	}
	return $devices;
}

1;
