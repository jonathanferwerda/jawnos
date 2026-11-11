package subs;

# Tunnel: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Crypt::PK::ECC;
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
use Mojo::URL;
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our %H;
our $config;
our $database;
our $device;
our $house_key_password_context;
our $house_key_password_magic;
our %house_key_wrap_alg;
our $house_key_wrap_context;
# --- wrapping the house key to a device ---------------------------------------
# A device never needs the house key in the clear. To hand it one, the server
# mints a throwaway key pair, agrees a secret with the device's public key,
# derives an AES-256 key from the agreement (SHA-256 over both public halves
# and a context, so swapping either half changes the key), and seals the house
# key with AES-GCM. The blob carries the throwaway public half, an IV and the
# tag; the device repeats the agreement with its own private key.
#
# Two curves are accepted, and the blob says which one it is, because the
# devices are not alike: an app key is Ed25519 (signing only - this machine has
# no libsodium to convert it to X25519), while a phone's bio key is P-256 and
# can agree. Ed25519 is refused rather than guessed at, so a caller has to give
# the device a key that can actually do the agreement.
#
# Every wrap is fresh, so nothing is stored: there is no table of wrapped
# copies, and a leaked blob is useless once the throwaway half is gone.
our $house_key_wrap_magic;
our %m;

sub tunnel_checker {
	my $data = shift;
	my $devices = &subs::device_lister(&subs::rightNow(),'list');
	my @seen_signatorials;
	my $batches = [];
	my $device = &subs::device_setter();

	# A headless server has no browser to press Scan, so make sure this machine
	# names itself first: the hub's own device row is where its tunnels become
	# addresses, and without it the block below has nothing to hang them off.
	&subs::ensure_self_device() if $device eq 'server';

	if ($device eq 'server') {
		my $tunnels = &subs::db_select('tunnels', undef, { status => 'active', direction => 'out' })->hashes;
		my $tunnel_duties = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'tunnel_duties' }) } || [];
		my $tunnel_duty_count = scalar @{$tunnel_duties};
		my $ss = `ss -tan`;
		my @ss = split /\n/, $ss;
		my $ss_check = [{}];
		foreach my $s ( @ss ) {
			my @fields = split(/\s+/, $s);
			$s = $fields[3];
		}
		foreach my $tun ( @{$tunnels} ) {
			$tun->{'failures'} = 0 unless $tun->{'failures'};
			if ($tun->{'direction'} eq 'out') {
				my $port = $tun->{'in_port'};
				my @active_port = grep { $_ =~ /:\Q$port/ } @ss;
				if (scalar @active_port > 0) {
					$tun->{'failures'} = 0;
					&subs::db_update('tunnels', { server_time => &subs::rightNow() }, { uuid => $tun->{'uuid'} });
				}
				else {
					if ($tun->{'failures'} >= 3) {
						&subs::db_delete('tunnels', { uuid => $tun->{'uuid'} });
					} else {
						$tun->{'failures'}++;
					}
				}
				&subs::db_update('tunnels', { failures => $tun->{'failures'}, server_time => &subs::rightNow() }, { uuid => $tun->{'uuid'}, signatorial => $tun->{'signatorial'} });
			}
		}
		# A headless hub names a peer only through a roster row, and the tunnel
		# websocket will not even serve a signatorial it cannot already name - so
		# a hub whose roster was wiped (a reseed, a restore) can never name the
		# peers whose tunnels it still holds, and the duty below, which needs the
		# row, deadlocks. Rebuild the row from the tunnel itself: the port is
		# live, and remote_device_connect writes the row - its buttons, the
		# tunnel flag and the hub-side manager included - the moment the peer
		# approves. It runs only for a signatorial with no row at all, so it is a
		# one-time repair after a wipe, never a per-tick call on a healthy hub.
		my %tunnel_enrolled;
		foreach my $tun ( @{$tunnels} ) {
			next unless $tun->{'signatorial'} && !$tunnel_enrolled{$tun->{'signatorial'}};
			next if &subs::db_select('remote_machines', undef, { signatorial => $tun->{'signatorial'} })->hashes->[0];
			$tunnel_enrolled{$tun->{'signatorial'}} = 1;
			my $enrollee = eval { &Manager::remote_device_connect({
				manager => 'https://127.0.0.1:' . ($tun->{'in_port'} || '') . '/manager',
				ip => ($tun->{'host'} || '127.0.0.1'),
				password => &subs::suds_grabber(),
				name => &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
				timestamp => &subs::rightNow(),
				browser_tab_id => &subs::random_string_creator(22),
				browser_tab => &subs::random_string_creator(21),
				signatorial => $tun->{'signatorial'},
				tunnel => 'yes'
			}) };
			if ($enrollee && $enrollee->{'body'} && $enrollee->{'body'}->{'signatorial'}) {
				&subs::log_writer('tunnel enrolled ' . substr($tun->{'signatorial'}, 0, 8) . ' from its active tunnel');
			}
		}
		# and name each tunnelled peer in this hub's own device row, so Configure ->
		# Devices and anything that reads the address map sees a tunnel that came up
		# since the last scan, and remote_upgrade can target it without a scan. This
		# mirrors the scan path in device_lister (one PORT_DOCK row per batch, hung
		# off the loopback NIC that marks this hub), so the two agree on shape. The
		# write is skipped when nothing changed, so a healthy hub does not churn.
		{
			my $hostname = &subs::machine_hostname();
			my $me = &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
			if ($me) {
				my $address = eval { decode_json $me->{'address'} } || {};
				my $before = encode_json $address;
				my $nic;
				foreach my $k (keys %{$address}) { $nic = $k if ($address->{$k}->{'ip'} || '') eq '127.0.0.1'; }
				$nic ||= (grep { $_ eq 'lo' } keys %{$address})[0] || (keys %{$address})[0] || 'lo';
				$address->{$nic}->{'ip'} ||= '127.0.0.1';
				my $neigh = $address->{$nic}->{'neigh'} || [];

				my @seen_batches;
				my %active_signatorial;
				my $dock_tunnels = &subs::db_select('tunnels', undef, { status => 'active' })->hashes;
				foreach my $tun ( @{$dock_tunnels} ) {
					next unless $tun->{'name'} && $tun->{'name'} eq 'PORT_DOCK';
					next unless $tun->{'signatorial'};
					next if grep { $_ eq $tun->{'batch_uuid'} } @seen_batches;
					push @seen_batches, $tun->{'batch_uuid'};
					$active_signatorial{$tun->{'signatorial'}} = 1;
					my ($entry) = grep { ($_->{'signatorial'} || '') eq $tun->{'signatorial'} } @{$neigh};
					my $ip = ($tun->{'host'} || $tun->{'ip'} || $tun->{'domain'} || '127.0.0.1');
					my %vals = (
						ip => $ip,
						domain => $ip,
						PORT_DOCK => $tun->{'in_port'},
						tunnel => 'yes',
						signatorial => $tun->{'signatorial'},
						mac => ($entry && $entry->{'mac'} ? $entry->{'mac'} : &subs::random_string_creator(10)),
						uuid => ($entry && $entry->{'uuid'} ? $entry->{'uuid'} : &subs::random_string_creator(25)),
					);
					if ($entry) { $entry->{$_} = $vals{$_} for keys %vals; }
					else { push @{$neigh}, { %vals }; }
				}
				# a tunnel neighbour whose signatorial no longer has an active tunnel
				# is dropped, so a peer that stops dialling does not linger on the map
				@{$neigh} = grep { !($_->{'tunnel'} && $_->{'tunnel'} eq 'yes') || $active_signatorial{$_->{'signatorial'}} } @{$neigh};

				$address->{$nic}->{'neigh'} = $neigh;
				my $after = encode_json $address;
				&subs::db_update('devices', { address => $after }, { uuid => $me->{'uuid'} }) if ($after ne $before);
			}
		}
		# Enrol each tunnelled peer with no browser behind it: the peer's own /gate
		# gives its name and its jawnos.enc backups, and remote_device_connect files
		# the roster row with its buttons - exactly what pressing Connect does.
		# tunnel_peer_enrol is idempotent: it skips the probe once the row shows its
		# backup and the connect once the roster reads active, so this is quiet when
		# healthy.
		my %enrolled;
		foreach my $tun ( @{$tunnels} ) {
			next unless $tun->{'signatorial'} && $tun->{'name'} && $tun->{'name'} eq 'PORT_AHOY';
			next if $enrolled{ $tun->{'signatorial'} }++;
			&subs::tunnel_peer_enrol($tun->{'signatorial'});
		}
		# A peer whose tunnels are gone is disconnected: mark its roster row so
		# nothing keeps dialling a dead hub-side port (remote_upgrade and the relay
		# target that manager). Only rows reached through 127.0.0.1 are the hub's
		# tunnels; a row with a real host manager may still answer directly, so it is
		# left to the reconnector to judge. The Dev list drops the neighbour on its
		# own (the naming pass above prunes it); this keeps the roster honest too and
		# refreshes the panel live.
		my %has_tunnel;
		$has_tunnel{ $_->{'signatorial'} } = 1 for grep { $_->{'signatorial'} } @{$tunnels};
		foreach my $rm ( @{ &subs::db_select('remote_machines', undef, { tunnel => 'yes' })->hashes } ) {
			next unless $rm->{'signatorial'} && ($rm->{'manager'} || '') =~ m{127\.0\.0\.1};
			next if $has_tunnel{ $rm->{'signatorial'} };
			next unless ($rm->{'connection'} || '') eq 'active';
			&subs::db_update('remote_machines', { connection => 'inactive', server_time => &subs::rightNow() }, { signatorial => $rm->{'signatorial'} });
			&Websocket::send('server', { console => &Websocket::console_command('deviceLister')});
		}
		foreach my $td ( @{$tunnel_duties} ) {
			my $tun = &subs::tunnel_port_mapper({ signatorial => $td->{'signatorial'}  });
			my $rm = &subs::remote_machine_lister({ signatorial => $td->{'signatorial'}, limit => 1 });
			if ($rm->{'signatorial'}) {
				$rm = &subs::remote_useragent_maker({ rm => $rm, signatorial => $td->{'signatorial'} });
				my $rdc = {
					manager => $rm->{'manager'},
					filename => $rm->{'data'}->{'database'},
					timestamp => &subs::rightNow(),
					ip => $rm->{'ip'},
					password => &subs::suds_grabber(),
					name => &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
					browser_tab_id => &subs::random_string_creator(22),
					browser_tab => &subs::random_string_creator(21),
					port => $tun->{'PORT_AHOY'},
					dock_port => $tun->{'PORT_DOCK'},
					signatorial => $rm->{'signatorial'},
					nic => $rm->{'nic'},
					tunnel => $rm->{'tunnel'}
				};
				$rm->{'cookie'} = undef;
				my $returner = &Manager::remote_device_connect($rdc);
			}



			@{$tunnel_duties} = grep { $_->{'uuid'} ne $td->{'uuid'} } @{$tunnel_duties};
		}
		if (scalar @{$tunnel_duties} != $tunnel_duty_count) {
			my $jtd = encode_json $tunnel_duties;
			&subs::setting_setter({ app => '__president', setting => 'tunnel_duties', value => $jtd });
		}
	} else {
		my @server_targets;
		foreach my $d ( reverse @{$devices} ) {
			foreach my $ad ( keys %{$d->{'address'}} ) {
				push @server_targets, grep { $_->{'mac'} && ($_->{'purpose'} || '') eq 'server' && ($_->{'tunnel'} || '') eq 'active' } @{$d->{'address'}->{$ad}->{'neigh'} || []};
			}
		}
		# A hub named by config (tunnel_hub) is not on this LAN: it sits behind a
		# subnet route, so no NIC's neighbour table ever lists it and a scan cannot
		# discover it. Without this, moving the hub is one change per house and the
		# config value alone did nothing (the laptop, 2026-11-02: tunnel_hub set,
		# no tunnel started, sync still pointed at the retired cloud). Name it from
		# the roster row the movement left behind, so the tunnel starts from the
		# same value the peer dials.
		if ($config->{'tunnel_hub'}) {
			my $hub_host = eval { Mojo::URL->new($config->{'tunnel_hub'})->host } || '';
			if ($hub_host && !grep { ($_->{'ip'} || '') eq $hub_host } @server_targets) {
				my $rows = &subs::db_select('remote_machines', undef, { device => 'server' })->hashes;
				my ($row) = grep {
					my $h = eval { Mojo::URL->new($_->{'manager'} || '')->host } || '';
					$h eq $hub_host;
				} @{$rows};
				$row ||= (sort { ($b->{'server_time'} || 0) <=> ($a->{'server_time'} || 0) } @{$rows})[0];
				push @server_targets, {
					ip          => $hub_host,
					signatorial => $row->{'signatorial'},
					domain      => $hub_host,
					mac         => 'hub',
				} if $row && $row->{'signatorial'};
			}
		}
		foreach my $n ( @server_targets ) {
					next if grep { $_ eq $n->{'signatorial'} } @seen_signatorials;
					push @seen_signatorials, $n->{'signatorial'};
					my $tunnels = &subs::db_select('tunnels', undef, { status => 'active', signatorial => $n->{'signatorial'} })->hashes;

					my $active_tunnel = 0;
					my $domain = $n->{'ip'};

					&subs::tunnel_starter({ ip => $n->{'ip'}, signatorial => $n->{'signatorial'}, domain => $n->{'ip'} }) if scalar @{$tunnels} == 0;
					foreach my $tun ( @{$tunnels} ) {


						if ($tun->{'direction'} eq 'in') {
							my $ps = $tun->{'process_id'};
							my $ps_check = ($ps && $ps =~ /^[0-9]+$/) ? `ps -p $ps -o cmd= 2>/dev/null` : '';
							my $holder_alive = ($ps_check =~ /President\.pl|Manager\.pl/) ? 1 : 0;
							next if grep { $tun->{'signatorial'} eq $_ || $tun->{'batch_uuid'} eq $_  } @{$batches};
							push @{$batches}, $tun->{'signatorial'};
							# A tree restart kills the holder but leaves its rows saying active.
							# Without this the checker waits three hollow-session failures (six
							# minutes) before re-requesting, so the tunnels look like they never
							# stick. Re-request on the first pass when the owner is gone.
							if (!$holder_alive) {
								&subs::tunnel_stopper($tun);
								&subs::tunnel_starter($tun);
								push @{$batches}, $tun->{'batch_uuid'};
								next;
							}
							my $signatorial = $tun->{'signatorial'};
							my $rm = &subs::remote_useragent_maker({ signatorial => $signatorial });
							my $url = $rm->{'manager'} . '/manager/tunnel/alive';
							my @batch = grep { $_->{'batch_uuid'} eq $tun->{'batch_uuid'} } @{$tunnels};
							# The POST is only the mirror/network sync now. Liveness is the
							# holder's own websocket heartbeat: peer_session pings the hub and
							# stamps a per-hub freshness file on every pong, so the checker reads
							# the data plane directly instead of round-tripping a chip_chyea
							# through the hub (a path that needed a session, the gate and the hub
							# reaching a NAT'd peer all to line up).
							my $form_data = {
								signatorial => &subs::signatorial_designer(),
								network => encode_json &subs::network_interface_reporter(),
								interval => $data->{'interval'},
								tunnel => encode_json \@batch
							};
							$rm->{'ua'}->inactivity_timeout(23);
							my $res = $rm->{'ua'}->post($url => form => $form_data)->result;
							my $age = &Tunnel::alive_age($rm->{'manager'});
							# Connected only if the hub is really listening for us: a fresh pong that
							# reports zero listeners is a hollow session (the hub lost our tunnels
							# rows and bound nothing), and re-requesting is what repairs it.
							my $ports = &Tunnel::alive_ports($rm->{'manager'});
							my $status = (defined $age && $age < 45000 && (!defined $ports || $ports >= 1)) ? 'connected' : 'unknown';
							if ($res && $res->is_success) {
								my $response = eval { decode_json $res->body } || {};
								if ($response->{'mirrors'}) {
									my @mirrors;
									foreach my $mirror ( @{$response->{'mirrors'}} ) {
										next unless ref $mirror eq 'HASH';
										my $ip = $rm->{'ip'};
										$mirror->{'manager'} =~ s/127\.0\.0\.1/$ip/gi;
										$mirror->{'mirror'} = 'yes';
										if ($mirror->{'network'} && !ref $mirror->{'network'}) {
											$mirror->{'network'} = decode_json $mirror->{'network'};
										}
										push @mirrors, &subs::remote_machine_mirror_row($mirror);
									}

									my $jmirror = encode_json [ grep { defined $_ } @mirrors ];
									&subs::db_update('remote_machines', { mirrors => $jmirror, server_time => &subs::rightNow() }, { signatorial => $rm->{'signatorial'} });
								}
							}
							if ($status ne 'connected') {
								$tun->{'failures'} += 1;
								$tun->{'server_time'} = &subs::rightNow();
								if ($tun->{'failures'} >= 3 || $data->{'duty'} eq 'restart') {
									&subs::tunnel_stopper($tun);
									&subs::tunnel_starter($tun);
								}
							}
							else {
								$active_tunnel = 1;
								$tun->{'failures'} = 0;
							}
							&subs::db_update('tunnels', { failures => $tun->{'failures'}, server_time => &subs::rightNow() }, { batch_uuid => $tun->{'batch_uuid'}, signatorial => $tun->{'signatorial'} });
							push @{$batches}, $tun->{'batch_uuid'};
						}
					}
				}
			}
		&Websocket::send('server', { console => &Websocket::console_command('tunnelLister')});
	}

sub tunnel_port_mapper {
	my $data = shift;
	my $ip = $data->{'ip'} || $data->{'domain'};
	my $direction = $data->{'direction'};
	my $host = $data->{'host'};
	my $signatorial = $data->{'signatorial'};
	my $tuns = {};

	my $tunnels = [];
	if ($signatorial) {
		$tunnels = &subs::db_select('tunnels', undef, { signatorial => $signatorial, status => 'active' })->hashes;
	}
	elsif ($host && $ip) {
		$tunnels = &subs::db_select('tunnels', undef, { host => $host, domain => $ip, status => 'active' })->hashes;
	}
	elsif ($host) {
		$tunnels = &subs::db_select('tunnels', undef, { host => $host, status => 'active' })->hashes;
	}
	else {
		$tunnels = &subs::db_select('tunnels', undef, { domain => $ip, status => 'active' })->hashes;
	}
	@{$tunnels} = grep { $_->{'direction'} eq $direction } @{$tunnels} if $direction;
	foreach my $t ( @{$tunnels} ) {
		$tuns->{$t->{'name'}} = $t->{'in_port'};
		$tuns->{'host'} = $t->{'host'};
		$tuns->{'last_updated'} = $tuns->{'server_time'} if $tuns->{'server_time'} > $tuns->{'last_updated'};
	}


	return $tuns;
}

sub tunnel_peer_connect {
	my ($signatorial, $filename) = @_;
	return unless $signatorial;
	# The hub reaches a tunnelled peer through the hub-side port the tunnel
	# reserved (remote_device_connect rewrites the manager to that 127.0.0.1
	# port); the peer's own address still rides in the tunnel's host, so the
	# roster row keeps a name it can show. This is the "dialled in -> enrolled"
	# step: the data plane is up by the time this is called, so the peer answers
	# and remote_device_connect files (or refreshes) the roster row - the buttons,
	# the tunnel flag and the hub-side manager that remote_upgrade targets.
	#
	# The peer's /sesh_check only authenticates when it is handed a database to
	# open (a backup path, exactly what the Dev panel's Connect button sends), so
	# a filename is required - the caller gets one from the peer's own /gate
	# restore list. Without it the handshake answers unapproved and no row is filed.
	my $tuns = &subs::tunnel_port_mapper({ signatorial => $signatorial });
	my $ip = $tuns->{'host'} || '127.0.0.1';
	unless ($filename) {
		my $row = &subs::remote_machine_lister({ signatorial => $signatorial, limit => 1 });
		my $data = ref $row->{'data'} eq 'HASH' ? $row->{'data'} : (eval { decode_json($row->{'data'} || '{}') } || {});
		$filename = $data->{'database'};
	}
	my $enrollee = eval { &Manager::remote_device_connect({
		manager => 'https://127.0.0.1:' . ($tuns->{'PORT_AHOY'} || $ENV{PORT_AHOY}) . '/manager',
		filename => $filename,
		ip => $ip,
		port => $tuns->{'PORT_AHOY'},
		port_dock => $tuns->{'PORT_DOCK'},
		password => &subs::suds_grabber(),
		name => &subs::setting_grabber({ app => 'me', setting => 'my_name' }),
		timestamp => &subs::rightNow(),
		browser_tab_id => &subs::random_string_creator(22),
		browser_tab => &subs::random_string_creator(21),
		signatorial => $signatorial,
		tunnel => 'yes'
	}) };
	if ($enrollee && $enrollee->{'body'} && $enrollee->{'body'}->{'signatorial'}) {
		&subs::log_writer('tunnel peer connected ' . substr($signatorial, 0, 8));
	}
	return $enrollee;
}

# What device_scan does for a neighbour it finds on the LAN, done headlessly for a
# peer the hub holds a tunnel to: ask the peer's own /gate for its name, purpose,
# signatorial and restore list (its jawnos.enc backups), write them onto the
# neighbour row in this machine's own device address, then run the same handshake
# the Dev panel's Connect button does (remote_device_connect) so the roster row
# carries the buttons and hub-side manager. Without a browser nothing else does
# this for a tunnel, so the peer appeared in Dev with no name and no backup to
# restore from.
sub tunnel_peer_enrol {
	my ($signatorial) = @_;
	return unless $signatorial;
	my $tuns = &subs::tunnel_port_mapper({ signatorial => $signatorial });
	my $dock = $tuns->{'PORT_DOCK'};
	return unless $dock;
	my $hostname = &subs::machine_hostname();
	my $me = &subs::db_select('devices', undef, { hostname => $hostname })->hashes->[0];
	return unless $me;
	# the neighbour row for this peer, if the naming pass has made one yet
	my $address = eval { decode_json $me->{'address'} } || {};
	my $entry;
	foreach my $nic ( keys %{$address} ) {
		foreach my $n ( @{$address->{$nic}->{'neigh'} || []} ) {
			if (($n->{'signatorial'} || '') eq $signatorial) { $entry = $n; last; }
		}
		last if $entry;
	}
	my $row = &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0];
	my $need_list = !($entry && $entry->{'restore_list'});
	my $need_connect = !($row && ($row->{'connection'} || '') eq 'active');
	return unless $need_list || $need_connect;
	my $filename;
	my $changed = 0;
	if ($need_list) {
		my $my_name = &subs::setting_grabber({ app => 'me', setting => 'my_name' });
		my $ua = Mojo::UserAgent->new();
		my $url = 'https://127.0.0.1:' . $dock . '/manager/gate?restore_list=' . ($config->{'start_dir'} || '')
			. '&neighbour=' . $hostname . '&my_name=' . $my_name . '&signatorial=' . &subs::signatorial_designer();
		# This is the hub's loopback tunnel port, forwarding to the peer's own
		# PORT_DOCK listener. That listener presents the peer's public wildcard (or
		# the generated local certificate), never the house-CA leaf: the leaf is on
		# the peer listener (main port + 6), which the tunnel does not carry. No CA
		# held here can prove this hop, and the signed gate request is what
		# authenticates the caller, so the lenient rail stays.
		my $res = eval { $ua->insecure(1)->get($url)->result };
		my $body = ($res && $res->is_success) ? eval { decode_json $res->body } : undef;
		if ($body && $body->{'signatorial'} && $entry) {
			$entry->{'name'} = $body->{'name'} if $body->{'name'};
			$entry->{'purpose'} = $body->{'purpose'} if $body->{'purpose'};
			$entry->{'signatorial'} = $body->{'signatorial'};
			$entry->{'restore_list'} = encode_json $body->{'restore_list'} if $body->{'restore_list'};
			&subs::db_update('devices', { address => encode_json $address }, { uuid => $me->{'uuid'} });
			$changed = 1;
		}
		# the backup path the peer's /sesh_check must be handed to open (prefer the
		# current snapshot) - the same file the Dev panel's Connect button sends
		if ($body && ref $body->{'restore_list'} eq 'ARRAY') {
			foreach my $b ( @{ $body->{'restore_list'} } ) {
				if (($b->{'archive'} || '') eq 'current') { $filename = $b->{'filename'}; last; }
			}
			$filename ||= $body->{'restore_list'}->[0]->{'filename'};
		}
	}
	my $enrollee;
	$enrollee = &subs::tunnel_peer_connect($signatorial, $filename) if $need_connect;
	$changed = 1 if $enrollee;
	# let the Dev panel show the peer appear (or its row fill in) live
	&Websocket::send('server', { console => &Websocket::console_command('deviceLister')}) if $changed;
	return $enrollee;
}

sub system_monitor {
	my $data = shift;
	my $device = &device_setter();
	$data->{'device'} = $device;
	$data->{'timestamp'} = &subs::rightNow();

	&subs::cache_set({ app => '__president', context => $data->{'timeout'} }, $data);
	my $remote_machines = &subs::db_query('select * from remote_machines where connection=?', 'active')->hashes;
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;

		foreach my $rm ( @{$remote_machines} ) {
			$rm = &subs::remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
			my $params;

			foreach my $p ( keys %{$data} ) {
				$params .= $p . '=' . url_escape $data->{$p} . '&';
			}

			my $url = $rm->{'manager'} . '/manager/configure/system_monitor?' . $params;
			my $res = $rm->{'ua'}->post($url)->result;
		}
	}, { name => 'system monitor' });
}

# --- the vault ---------------------------------------------------------------
# The suds at rest, sealed to this machine's own key file (~/.house.key, which
# never rides the database, a backup, or a code sync). One row per machine, so
# a merged database still opens on every machine; a database that leaves this
# machine carries only sealed rows, worthless without the key file.
sub house_key {
	my $path = &home('~/.house.key');
	my $key = '';
	$key = read_file($path) if -e $path;
	$key =~ s/\s+//g if $key;
	unless ($key) {
		# The key comes from the OS, never from rand(). /dev/urandom is Linux's
		# only; Windows has no device path at all, so ask CryptX first (a
		# required module everywhere the app runs) and keep the device read as
		# the fallback. An empty draw must never be written: a keyless vault is
		# worse than no vault, because every sealed row would sit under ''.
		my $raw = '';
		if (eval { require Crypt::PRNG; $raw = Crypt::PRNG::random_bytes(32); 1 }) {
			# got it
		}
		elsif (open my $fh, '<', '/dev/urandom') {
			binmode $fh;
			read($fh, $raw, 32);
			close $fh;
		}
		die "house_key: no source of randomness; cannot build the house key\n"
			unless defined $raw && length $raw;
		$key = encode_base64($raw, '');
		write_file($path, $key . "\n");
		chmod 0600, $path;
	}
	return $key;
}

sub house_key_wrap_alg {
	my ($device) = @_;
	return undef unless ref $device;
	return $house_key_wrap_alg{ref $device};
}

# house_key_wrap($key, $device_public_key_object) -> base64 blob or undef
sub house_key_wrap {
	my ($K, $device) = @_;
	return undef unless defined $K && length $K;
	my $alg = &house_key_wrap_alg($device);
	return undef unless $alg;
	my $device_pub = eval { $device->export_key_der('public') };
	return undef unless defined $device_pub && length $device_pub;
	my $eph;
	if ($alg == 1) {
		require Crypt::PK::X25519;
		$eph = Crypt::PK::X25519->new();
		$eph->generate_key();
	}
	else {
		$eph = Crypt::PK::ECC->new();
		$eph->generate_key('secp256r1');
	}
	return undef unless $eph;
	my $eph_pub = eval { $eph->export_key_der('public') };
	return undef unless defined $eph_pub && length $eph_pub;
	my $shared = eval { $eph->shared_secret($device) };
	return undef unless defined $shared && length $shared;
	require Crypt::AuthEnc::GCM;
	require Crypt::PRNG;
	my $aes = Digest::SHA::sha256($house_key_wrap_context . "\0" . $shared . "\0" . $eph_pub . "\0" . $device_pub);
	my $iv = Crypt::PRNG::random_bytes(12);
	my ($ct, $tag) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate('AES', $aes, $iv, $house_key_wrap_context, $K);
	return undef unless defined $ct && defined $tag && length $tag == 16;
	my $blob = $house_key_wrap_magic . pack('Cn', $alg, length $eph_pub) . $eph_pub . $iv . $tag . $ct;
	return encode_base64($blob, '');
}

# house_key_unwrap($blob, $device_private_key_object) -> the key or undef
sub house_key_unwrap {
	my ($blob64, $device) = @_;
	return undef unless defined $blob64 && length $blob64;
	my $alg = &house_key_wrap_alg($device);
	return undef unless $alg;
	my $blob = eval { decode_base64($blob64) };
	return undef unless defined $blob && length $blob;
	my $head = 5 + 1 + 2;
	return undef unless length($blob) > $head + 12 + 16;
	return undef unless substr($blob, 0, 5) eq $house_key_wrap_magic;
	return undef unless unpack('C', substr($blob, 5, 1)) == $alg;
	my $len = unpack('n', substr($blob, 6, 2));
	return undef unless $len >= 32 && length($blob) >= $head + $len + 12 + 16;
	my $off = $head;
	my $eph_pub = substr($blob, $off, $len); $off += $len;
	my $iv = substr($blob, $off, 12); $off += 12;
	my $tag = substr($blob, $off, 16); $off += 16;
	my $ct = substr($blob, $off);
	return undef unless length $ct;
	my $eph;
	if ($alg == 1) {
		require Crypt::PK::X25519;
		$eph = eval { Crypt::PK::X25519->new(\$eph_pub, 'DER') };
	}
	else {
		$eph = eval { Crypt::PK::ECC->new(\$eph_pub, 'DER') };
	}
	return undef unless $eph;
	my $shared = eval { $device->shared_secret($eph) };
	return undef unless defined $shared && length $shared;
	my $device_pub = eval { $device->export_key_der('public') };
	return undef unless defined $device_pub && length $device_pub;
	require Crypt::AuthEnc::GCM;
	my $aes = Digest::SHA::sha256($house_key_wrap_context . "\0" . $shared . "\0" . $eph_pub . "\0" . $device_pub);
	my $K = eval { Crypt::AuthEnc::GCM::gcm_decrypt_verify('AES', $aes, $iv, $house_key_wrap_context, $ct, $tag) };
	return (defined $K && length $K) ? $K : undef;
}

# --- Ed25519 -> X25519 --------------------------------------------------------
# An app device's key is Ed25519: it signs but cannot agree. The birational map
# takes its public half to a Montgomery point, and its private seed becomes a
# scalar the same way libsodium does it (SHA-512, then clamp), so a device can
# wrap and unwrap with the key it already has. Checked against libsodium on four
# random keys: public and private agree byte for byte.
#
# Math::BigInt does the only big-number work and it runs twice per pairing, not
# per request; the private half is a hash and a clamp, so it is cheap.
sub house_key_ed25519_x25519_public {
	my ($ed) = @_;
	return undef unless $ed;
	my $raw = ref $ed ? eval { $ed->export_key_raw('public') } : $ed;
	return undef unless defined $raw && length $raw == 32;
	require Math::BigInt;
	my $p = Math::BigInt->new('57896044618658097711785492504343953926634992332820282019728792003956564819949');
	my $y = Math::BigInt->from_bytes(scalar reverse $raw);
	my $top = Math::BigInt->new(2)->bpow(255);
	$y->bsub($top) if $y->bcmp($top) >= 0;   # the sign bit is not part of y
	return undef unless $y->bcmp($p) < 0;
	my $one = Math::BigInt->bone();
	my $num = $one->copy->badd($y)->bmod($p);
	my $den = $one->copy->bsub($y)->bmod($p);
	return undef if $den->is_zero;
	my $u = $num->copy->bmul($den->copy->bmodinv($p))->bmod($p);
	my $be = $u->to_bytes;
	$be = ("\0" x (32 - length $be)) . $be if length $be < 32;
	return scalar reverse $be;
}

sub house_key_ed25519_x25519_private {
	my ($ed) = @_;
	return undef unless $ed;
	my $seed = ref $ed ? eval { $ed->export_key_raw('private') } : $ed;
	return undef unless defined $seed && length $seed == 32;
	my $a = substr(Digest::SHA::sha512($seed), 0, 32);
	substr($a, 0, 1) = chr(ord(substr($a, 0, 1)) & 248);
	substr($a, 31, 1) = chr((ord(substr($a, 31, 1)) & 127) | 64);
	return $a;
}

sub house_key_argon2_salt {
	require Crypt::PRNG;
	return encode_base64(Crypt::PRNG::random_bytes(16), '');
}

# The reference tool, for an OpenSSL without Argon2. The password arrives on
# stdin, never in argv; the salt is public and may ride the command line.
sub house_key_argon2id_cli {
	my ($password, $salt, $t, $m, $p, $len) = @_;
	return undef unless defined $password && length $password;
	return undef unless defined $salt && length $salt >= 8;
	my $on_path = `command -v argon2 2>/dev/null`;
	chomp $on_path;
	return undef unless $on_path;
	# the tool counts memory as 2^N KiB
	my $bits = 0;
	my $size = $m;
	while ($size > 1) { return undef if $size % 2; $size /= 2; $bits++; }
	return undef unless $bits >= 3;
	require IPC::Open2;
	my ($out, $in);
	my $pid = eval { IPC::Open2::open2($out, $in, $on_path, $salt, '-id', '-t', $t, '-m', $bits, '-p', $p, '-l', $len, '-r') };
	return undef unless $pid;
	local $SIG{'PIPE'} = 'IGNORE';
	eval { print $in $password; };
	close $in;
	my $res = do { local $/; <$out> };
	close $out;
	waitpid($pid, 0);
	return undef unless $? == 0 && defined $res && length $res;
	# builds differ: some print the digest as hex with -r, some as raw bytes
	my $hexlen = 2 * $len;
	if ($res =~ /^\s*([0-9a-fA-F]{$hexlen})\s*$/) { return pack('H*', $1); }
	return $res if length $res == $len;
	return undef;
}

# (key, descriptor) - with no descriptor, take the strongest that works here
sub house_key_password_kdf {
	my ($password, $salt, $len, $desc) = @_;
	return (undef, undef) unless defined $password && length $password;
	return (undef, undef) unless defined $salt && length $salt;
	$len = 32 unless $len;
	require Crypt::KeyDerivation;
	my @tries = (defined $desc && length $desc)
		? ($desc)
		: ('argon2id$t=3,m=65536,p=1', 'scrypt$N=32768,r=8,p=1', 'pbkdf2$sha256,600000');
	foreach my $try (@tries) {
		my $key;
		if ($try =~ /^argon2id\$t=(\d+),m=(\d+),p=(\d+)$/) {
			my ($t, $m, $p) = ($1, $2, $3);
			$key = eval { Crypt::KeyDerivation::argon2_pbkdf('argon2id', $password, $salt, $t, $m, $p, $len, '', '') };
			$key = &house_key_argon2id_cli($password, $salt, $t, $m, $p, $len)
				unless defined $key && length $key == $len;
		}
		elsif ($try =~ /^scrypt\$N=(\d+),r=(\d+),p=(\d+)$/) {
			$key = eval { Crypt::KeyDerivation::scrypt_pbkdf($password, $salt, $1, $2, $3, $len) };
		}
		elsif ($try =~ /^pbkdf2\$sha256,(\d+)$/) {
			$key = eval { Crypt::KeyDerivation::pbkdf2($password, $salt, $1, 'SHA256', $len) };
		}
		return ($key, $try) if defined $key && length $key == $len;
	}
	return (undef, undef);
}

sub house_key_password_seal {
	my ($K, $password) = @_;
	return undef unless defined $K && length $K;
	return undef unless defined $password && length $password;
	require Crypt::AuthEnc::GCM;
	require Crypt::PRNG;
	my $salt = &house_key_argon2_salt();
	my ($aes, $desc) = &house_key_password_kdf($password, $salt, 32);
	return undef unless $aes;
	my $iv = Crypt::PRNG::random_bytes(12);
	my ($ct, $tag) = Crypt::AuthEnc::GCM::gcm_encrypt_authenticate('AES', $aes, $iv, $house_key_password_context, $K);
	return undef unless defined $ct && defined $tag && length $tag == 16;
	return encode_base64($house_key_password_magic . pack('C', length $desc) . $desc
		. pack('C', length $salt) . $salt . $iv . $tag . $ct, '');
}

1;
