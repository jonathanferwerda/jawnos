package subs;

# Lan: extracted from subroutines.pl (package subs). Loaded on
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
our $device;
our $gb;
our $lan_beacon;
our $log;
our %m;

# A directed unicast sweep of the /24 around each private NIC. Broadcast is the
# cheap path when it is delivered, but Android drops it for a Termux socket; a
# sweep on boot and on a network change reaches the same peers one by one, and
# their replies come back as unicast. Only a private /24 is swept, and only when
# the address changed or five minutes have passed.
sub lan_presence_sweep {
	my ($json, $nics) = @_;
	return unless $json && ref $nics eq 'ARRAY';
	require Socket;
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(Proto => 'udp') or return;
	foreach my $nic (@{$nics}) {
		my $ip = $nic->{'ip'} || '';
		next unless $ip =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
		my ($a, $b, $c, $d) = ($1, $2, $3, $4);
		foreach my $h ( 1 .. 254 ) {
			next if $h == $d;
			my $target = $a . '.' . $b . '.' . $c . '.' . $h;
			$sock->send($json, 0, Socket::pack_sockaddr_in(&lan_presence_port(), Socket::inet_aton($target)));
			# A /24 burst over Wi-Fi saturates the kernel's unresolved-neighbour queue,
			# and the host we want can be the one that is dropped. Twenty milliseconds
			# between hosts lets ARP drain; a full /24 takes about five seconds, once
			# at boot or when the machine joins a new network.
			select(undef, undef, undef, 0.02);
		}
		select(undef, undef, undef, 0.05);
	}
	close $sock;
}

# Presence and navigation are state, not a stream: one application per source
# address per second is enough. The listener still wakes for each datagram, but
# a peer that speaks quickly - or a burst after a network change - no longer
# turns every one into a JSON decode and a database write.
our %lan_presence_applied_at;
sub lan_presence_due {
	my ($ip, $now, $window) = @_;
	$window = 1 unless defined $window && $window > 0;
	my $last = $lan_presence_applied_at{$ip} || 0;
	return 0 if $last && $now - $last < $window;
	$lan_presence_applied_at{$ip} = $now;
	return 1;
}

sub lan_presence_send {
	my @nics = @{ &lan_presence_network() };
	return unless @nics;
	my $now = time();
	my $fingerprint = join '|', map { ($_->{'nic'} // '') . '=' . ($_->{'ip'} // '') . '=' . ($_->{'mac'} // '') } @nics;
	my $swept_at = ($lan_beacon && ($lan_beacon->{'fingerprint'} // '') eq $fingerprint) ? ($lan_beacon->{'swept_at'} || 0) : 0;
	if (!$lan_beacon || ($lan_beacon->{'fingerprint'} // '') ne $fingerprint || $now - ($lan_beacon->{'at'} || 0) > 60) {
		$lan_beacon = { at => $now, fingerprint => $fingerprint, swept_at => $swept_at, json => encode_json(&lan_presence_payload()) };
	}
	if ($now - $swept_at > 600) {
		&lan_presence_sweep($lan_beacon->{'json'}, \@nics);
		$lan_beacon->{'swept_at'} = $now;
	}
	require Socket;
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(Proto => 'udp', Broadcast => 1);
	return unless $sock;
	foreach my $nic (@nics) {
		my $b = $nic->{'broadcast'} || '';
		$b = '255.255.255.255' unless $b =~ /^\d{1,3}(\.\d{1,3}){3}$/;
		my $addr = Socket::pack_sockaddr_in(&lan_presence_port(), Socket::inet_aton($b));
		$sock->send($lan_beacon->{'json'}, 0, $addr);
	}
	# Known peers on this LAN get the same notice by unicast. A phone that drops
	# broadcast still receives unicast, so every machine's row and Dev panel stay
	# current in both directions without waiting for the other side to broadcast.
	foreach my $target ( @{ &lan_presence_targets(\@nics) } ) {
		my $addr = Socket::pack_sockaddr_in(&lan_presence_port(), Socket::inet_aton($target));
		$sock->send($lan_beacon->{'json'}, 0, $addr);
	}
	close $sock;
}

# The known peers that share one of our current subnets, resolved to the
# address and manager port they answered from. The row's ip is tried first,
# then the NICs in its network report (including the `lan` entry the presence
# notices keep fresh). A caller that only needs addresses calls
# lan_presence_targets below.
sub lan_peer_targets {
	my ($nics, $want_device) = @_;
	my @targets;
	my %seen;
	foreach my $rm ( @{ &db_select('remote_machines')->hashes || [] } ) {
		next if (($rm->{'signatorial'} // '') eq &signatorial_designer());
		my @ips;
		push @ips, $rm->{'ip'} if ($rm->{'ip'} // '') =~ /^\d{1,3}(\.\d{1,3}){3}$/;
		my $net = ref $rm->{'network'} eq 'HASH' ? $rm->{'network'} : (eval { decode_json $rm->{'network'} } || {});
		$net = {} unless ref $net eq 'HASH';
		foreach my $k ( keys %{$net} ) {
			next if $k eq 'public_address' || !ref $net->{$k};
			push @ips, $net->{$k}->{'ip'} if ($net->{$k}->{'ip'} // '') =~ /^\d{1,3}(\.\d{1,3}){3}$/;
		}
		my $ip = '';
		foreach my $c ( @ips ) {
			next unless &ip_is_private($c);
			next unless grep { &same_net_test($_->{'ip'}, $c) eq 'yes' } @{$nics};
			$ip = $c;
			last;
		}
		next unless $ip && !$seen{$ip}++;
		my $lan = (ref $net->{'lan'} eq 'HASH') ? $net->{'lan'} : {};
		my $port = $lan->{'port'} || $rm->{'port'} || 45545;
		my $device = $lan->{'device'} || $rm->{'device'} || '';
		next if $want_device && $device ne $want_device;
		push @targets, {
			ip => $ip,
			port => ($port =~ /^\d+$/ ? $port : 45545),
			device => $device,
			signatorial => ($rm->{'signatorial'} // ''),
			server_time => (0 + ($rm->{'server_time'} || 0)),
		};
	}
	return [ sort { $b->{'server_time'} <=> $a->{'server_time'} } @targets ];
}

sub lan_presence_targets {
	my ($nics) = @_;
	return [ map { $_->{'ip'} } @{ &lan_peer_targets($nics) } ];
}

# The physical LANs this machine is on: the interfaces the presence notices use,
# less the tunnel and tailnet adapters. A fix shared over a VPN would claim the
# receiving machine stands where the phone is when all the two share is a route,
# so the handover is limited to a real subnet.
sub lan_physical_network {
	my @nics;
	foreach my $nic ( @{ &lan_presence_network() } ) {
		my $name = $nic->{'nic'} // '';
		next if $name =~ /^(?:tun|tap|wg|tailscale|utun|ppp|zt|nordlynx|proton)/i;
		next if ($nic->{'ip'} // '') =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;
		push @nics, $nic;
	}
	return \@nics;
}

# A handheld that has just taken its own fix hands it to the peers on this LAN,
# so a computer with no GPS of its own can be in the same place now instead of
# on the next mesh sync. Only a mobile sends; the receiving computer records the
# place but never repeats it, so there is no echo. Nothing here starts or stops
# an appointment: the handheld's navigation_automation already logged the visit,
# and a second start for the same place is exactly the duplicate to avoid.
sub navigation_share_fix {
	my $fix = shift || {};
	return unless &subs::device_setter() eq 'mobile';
	# A handheld without a real GPS has no place worth handing on: a network
	# guess would arrive at the computer looking like a fix.
	return unless &subs::navigation_gps_present();
	return unless defined $fix->{'latitude'} && $fix->{'latitude'} =~ /^-?\d+(?:\.\d+)?$/
		&& defined $fix->{'longitude'} && $fix->{'longitude'} =~ /^-?\d+(?:\.\d+)?$/;
	return unless abs($fix->{'latitude'}) <= 90 && abs($fix->{'longitude'}) <= 180;
	return unless defined $fix->{'accuracy'} && $fix->{'accuracy'} =~ /^\d+(?:\.\d+)?$/ && $fix->{'accuracy'} < 200;
	my @nics = @{ &lan_physical_network() };
	return unless @nics;
	# one handover for a burst of callbacks describing the same fix
	my $now = &subs::rightNow();
	our $navigation_share_at;
	return if $navigation_share_at && $now - $navigation_share_at < 3000;
	$navigation_share_at = $now;
	my $msg = {
		type => 'jawnos-nav',
		signatorial => &subs::signatorial_designer(),
		latitude => $fix->{'latitude'},
		longitude => $fix->{'longitude'},
		accuracy => $fix->{'accuracy'},
		timestamp => ($fix->{'timestamp'} || $now),
		ts => int(time()),
		nonce => &subs::random_string_creator(16),
	};
	my $pub = &subs::peer_pubkey();
	$msg->{'pubkey'} = $pub if $pub;
	my $sig = &subs::peer_sign_blob(&subs::lan_presence_canonical($msg));
	$msg->{'sig'} = $sig if $sig;
	my $json = &subs::encode_json($msg);
	require Socket;
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(Proto => 'udp') or return;
	foreach my $target ( @{ &lan_presence_targets(\@nics) } ) {
		my $addr = Socket::pack_sockaddr_in(&lan_presence_port(), Socket::inet_aton($target));
		$sock->send($json, 0, $addr);
	}
	close $sock;
	return 1;
}

# A fix arrived from a handheld on this LAN. Record it as this machine's own
# current position, with the same hold the handheld gives its own fixes, but
# deliberately do not run navigation_automation: the appointment the visit
# belongs to is the handheld's to start, and starting a second one here is the
# duplicate this handover exists to avoid.
sub lan_navigation_accept {
	my ($msg, $peer_ip) = @_;
	return unless ref $msg eq 'HASH';
	return unless ($msg->{'type'} // '') eq 'jawnos-nav';
	return if &subs::device_setter() eq 'mobile';
	my $sig = $msg->{'signatorial'} // '';
	return unless $sig && $sig ne &subs::signatorial_designer();
	my $ts = $msg->{'ts'} // 0;
	return unless $ts =~ /^\d+$/ && abs(time() - $ts) <= 600;
	return unless ($peer_ip // '') =~ /^\d{1,3}(\.\d{1,3}){3}$/;
	my $lat = $msg->{'latitude'} // '';
	my $lon = $msg->{'longitude'} // '';
	return unless $lat =~ /^-?\d+(?:\.\d+)?$/ && $lon =~ /^-?\d+(?:\.\d+)?$/;
	return unless abs($lat) <= 90 && abs($lon) <= 180;
	my $accuracy = $msg->{'accuracy'} // '';
	return unless $accuracy =~ /^\d+(?:\.\d+)?$/ && $accuracy < 200;
	my @nics = @{ &lan_physical_network() };
	return unless @nics;
	my $same = grep { &subs::same_net_test($_->{'ip'}, $peer_ip) eq 'yes' } @nics;
	return unless $same;
	my $rm = &subs::db_select('remote_machines', undef, { signatorial => $sig })->hashes->[0];
	return unless $rm;
	return unless &subs::lan_presence_verify($rm, $msg);
	my $now = &subs::rightNow();
	my $me = &subs::signatorial_designer();
	my $fix_time = ($msg->{'timestamp'} // '') =~ /^\d+$/ ? $msg->{'timestamp'} : $now;
	&subs::db_delete('continent', { type => 'temporary', signatorial => $me });
	&subs::db_insert('continent', {
		uuid => &subs::random_string_creator(31),
		type => 'temporary',
		app => '__president',
		signatorial => $me,
		latitude => $lat,
		longitude => $lon,
		accuracy => sprintf("%.2F", $accuracy),
		timestamp => $fix_time,
		server_time => $now,
		warranty => &subs::navigation_hold_warranty({ timestamp => $fix_time, server_time => $now }),
	});
	&subs::cache_delete({ app => 'travel', context => 'navigation_information', subcontext => $me });
	eval { &Websocket::send('tab', { console => &Websocket::console_command('startMenuRefresh')}) };
	our %navigation_share_seen;
	if (($navigation_share_seen{$sig} || 0) < $now - 300000) {
		$navigation_share_seen{$sig} = $now;
		eval { &subs::log_writer('navigation: borrowed a place from ' . substr($sig, 0, 8) . ' at ' . $peer_ip) };
	}
	return 1;
}

# This machine's own current fix, used when a peer asks for it. A held fix from
# the last navigation run answers at once; when that is stale, ask the GPS with a
# short bound and fall back to the network provider, then to the last held fix.
# Read-only: the asking machine writes the place, and this one's own navigation
# keeps its cadence.
sub local_position {
	return {} unless &subs::device_setter() eq 'mobile';
	my $now = &subs::rightNow();
	my $me = &subs::signatorial_designer();
	# The house asks for the cached place, not a new fix: accept the last fix for
	# two navigation paces plus a little grace, then refuse rather than guess.
	my $hold = (&subs::navigation_interval() * 2 * 1000) + 120000;
	$hold = 5 * 60 * 1000 if $hold < 5 * 60 * 1000;
	$hold = 15 * 60 * 1000 if $hold > 15 * 60 * 1000;
	my $row = &subs::db_query('select * from continent where type = ? and signatorial = ? and latitude is not null and timestamp > ? order by server_time desc limit 1', 'temporary', $me, $now - $hold)->hashes->[0];
	if ($row && $row->{'latitude'} && &subs::navigation_gps_present()) {
		return { latitude => $row->{'latitude'}, longitude => $row->{'longitude'}, accuracy => $row->{'accuracy'}, timestamp => $row->{'timestamp'}, source => 'navigation', cached => 1 };
	}
	# The app's GPS service keeps the latest fix on disk. Answer from it without
	# waking anything, and without the network provider: a Wi-Fi guess is not a
	# place, however plausible its accuracy looks.
	my $loc = &subs::native_location({ max_age_ms => $hold });
	if ($loc) {
		&subs::navigation_gps_confirm('gps');
		return { latitude => $loc->{'latitude'}, longitude => $loc->{'longitude'}, accuracy => sprintf("%.2F", ($loc->{'accuracy'} || 0)), timestamp => $loc->{'time'} || $now, source => 'gps', cached => 1 };
	}
	# A phone whose service has not run yet may still answer one GPS request.
	my $j = &subs::device_call('location.current', { provider => 'gps', timeout_ms => 8000 }) || {};
	if (($j->{'provider'} || '') eq 'gps' && $j->{'latitude'} && ($j->{'elapsedMs'} || 1e9) <= $hold) {
		&subs::navigation_gps_confirm('gps');
		return { latitude => $j->{'latitude'}, longitude => $j->{'longitude'}, accuracy => sprintf("%.2F", ($j->{'accuracy'} || 0)), timestamp => $now, source => 'gps' };
	}
	return {} unless &subs::navigation_gps_present();
	$row = &subs::db_query('select * from continent where type = ? and signatorial = ? and latitude is not null and (warranty is null or warranty = ? or cast(warranty as integer) > cast(? as integer)) order by server_time desc limit 1', 'temporary', $me, '', $now)->hashes->[0];
	return {} unless $row && $row->{'latitude'};
	return { latitude => $row->{'latitude'}, longitude => $row->{'longitude'}, accuracy => $row->{'accuracy'}, timestamp => $row->{'timestamp'}, source => 'navigation', cached => 1 };
}

# The manual navigation button on a computer asks the devices that can actually
# see the sky: a teletype (the T-Deck serves /my_position on the LAN) and then
# any mobile peer on one of this machine's physical subnets. The peer route is
# signed and answers only a verified caller on the same subnet. Returns a fix
# hash, or an empty hash when nothing answers; the caller then falls back to the
# browser's own geolocation.
sub nearby_position {
	my $data = shift || {};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $tdeck = &embedded_location_grabber({ timestamp => $timestamp });
	if ($tdeck->{'latitude'}) {
		return {
			latitude => $tdeck->{'latitude'},
			longitude => $tdeck->{'longitude'},
			accuracy => $tdeck->{'accuracy'},
			timestamp => $timestamp,
			source => 'teletype',
		};
	}
	my @nics = @{ &lan_physical_network() };
	return {} unless @nics;
	my $targets = &lan_peer_targets(\@nics, 'mobile');
	return {} unless scalar @{$targets};
	my $ua = Mojo::UserAgent->new();
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	$ua = $ua->insecure(1)->connect_timeout(1)->inactivity_timeout(4)->request_timeout(7);
	foreach my $target ( @{$targets} ) {
		my $url = 'https://' . $target->{'ip'} . ':' . $target->{'port'} . '/manager/navigation/position?peer=yes&signatorial=' . &signatorial_designer();
		my $res = eval { $ua->get($url)->result };
		next unless $res && $res->is_success;
		my $body = eval { decode_json($res->body) } || {};
		next unless ref $body eq 'HASH' && $body->{'latitude'} && $body->{'longitude'};
		return {
			latitude => $body->{'latitude'},
			longitude => $body->{'longitude'},
			accuracy => $body->{'accuracy'},
			timestamp => $body->{'timestamp'},
			source => ($body->{'source'} || 'peer'),
			signatorial => $target->{'signatorial'},
		};
	}
	return {};
}

# Wait out a quiet spell while keeping the supervisor's lease. A resident loop
# with a two-minute heartbeat (Process.pm's seed map) that blocks longer than
# that is expired and killed - "died without reporting" in manager.log - which is
# what happened to the presence listener on every quiet network.
sub lan_presence_wait {
	my ($seconds) = @_;
	my $until = time() + ($seconds || 0);
	do {
		&subs::subprocessor_heartbeat();
		my $left = $until - time();
		sleep($left > 10 ? 10 : $left) if $left > 0;
	} while (time() < $until);
	&subs::subprocessor_heartbeat();
}

sub lan_presence_listen {
	require Socket;
	require IO::Socket::INET;
	while (1) {
		# A cloud server whose only address is public has no LAN to listen on;
		# do not open the port to the internet.
		my @lan_nics = @{ &lan_presence_network() };
		unless (@lan_nics) {
			&lan_presence_wait(60);
			next;
		}
		my $sock = IO::Socket::INET->new(
			LocalAddr => '0.0.0.0',
			LocalPort => &lan_presence_port(),
			Proto => 'udp',
			ReuseAddr => 1,
			Broadcast => 1,
		);
		unless ($sock) {
			&lan_presence_wait(10);
			next;
		}
				# A packet wakes a process. A peer that speaks ten times a second then
		# costs ten wakeups and ten decodes for state that only needs its newest
		# value. Let the datagrams queue for a second, then drain them and apply
		# one - the newest - per source: presence lands within a second, and the
		# loop wakes once a second instead of once a datagram.
		$sock->blocking(0);
		while (1) {
			sleep 1;
			my %pending;
			while (1) {
				my $data = '';
				my $peer = recv($sock, $data, 4096, 0);
				last unless defined $peer;
				next unless length $data;
				my ($port, $iaddr) = Socket::sockaddr_in($peer);
				my $ip = $iaddr ? Socket::inet_ntoa($iaddr) : '';
				next unless $ip;
				$pending{$ip} = $data;
			}
			foreach my $ip (sort keys %pending) {
				next unless &lan_presence_due($ip, time(), 1);
				&subs::subprocessor_heartbeat();
				my $msg = eval { decode_json($pending{$ip}) };
				next unless ref $msg eq 'HASH';
				if (($msg->{'type'} // '') eq 'jawnos-nav') {
					eval { &lan_navigation_accept($msg, $ip) };
					next;
				}
				eval { &lan_presence_accept($msg, $ip) };
			}
			&subs::subprocessor_heartbeat();
		}
		close $sock;
		&lan_presence_wait(2);
	}
}

sub remote_machine_negotiator {
	my $data = shift;
	$gb::suds = &suds_grabber();
	my $c = &subs::controller_builder();
	$c->session('gimme' => $data->{'gimme'});


	my $remote_connect_timer =  &subs::setting_grabber({ app => '__president', setting => 'remote_connect_timer' }) || 0;
	# A sync that dies mid-run leaves a marker behind. Its state is read in one
	# place (subs::remote_upgrade_lock_state): a live pid keeps the long bound,
	# because a 110k-row merge can outlast the old four-minute reap and clearing
	# it let a second pull start against the same peer; a claim whose fork never
	# ran expires on its own short bound; a dead owner is cleared at once.
	my $up_state = &subs::remote_upgrade_lock_state();
	if ($up_state->{'flag'} eq 'running' && !$up_state->{'busy'}) {
		&subs::log_writer('pull marker released: ' . $up_state->{'value'} . ' (' . int($up_state->{'age'} / 1000) . 's old)');
		&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
		$up_state = &subs::remote_upgrade_lock_state();
	}
	my $bridled = $up_state->{'busy'} ? 1 : 0;
	# A pull job row can outlive the marker that owned it: a forked pull that dies
	# after clearing its marker (or before writing one) leaves a 'running' row that
	# nothing will ever finish, and the sync panel then reads as if a pull were
	# still in flight. When no pull owns the marker, no worker is pulling, so any
	# pull row still running is orphaned. Ten minutes keeps a pull that was just
	# started - and has not written its marker yet - from being cut short.
	if (!$bridled) {
		my $reaped = &subs::sync_jobs_reap(600000, 'pull', 'no pull owned it');
		$log->info('sync jobs reaped: ' . $reaped . ' pull job(s) with no owner') if $reaped;
	}
	if (!$bridled && $remote_connect_timer + 10000 < &subs::rightNow()) {
		&Manager::remote_machine_reconnector($c);
	}
	#&system_monitor({
	#	timeout => 'remote_machine_sync',
	#});
}

# Relay a request with no browser behind it. remote_relay_request reads the
# caller's request - its path, method and params - which a headless machine (the
# cloud, a utility job, a CLI) does not have; build a bare controller and hand it
# a synthesized request instead, so a server with no page can still hand a change
# on to its peers over exactly the rail the browser uses. $data:
#   path        => '/manager/...'           (required)
#   method      => 'post' | 'get'            (default post)
#   params      => { ... }                    (request params)
#   remote_uuid => a single target, else a flood to every reachable peer
#   extra       => extra_params for remote_relay_request (e.g. dissemination)
sub operator_door_push {
	# Hand a device's rotated Now Me row to the other House machines on this LAN.
	# A device that falls back probes them with this pair, so they must hold it
	# now; the durable digest is only a backstop for a machine that was away.
	# Each peer verifies the signed request (`/manager/operator_door`), so no
	# session cookie is needed. Bounded and synchronous: two LAN peers cost a
	# couple of seconds, and Now Me is a deliberate action.
	my ($edt, $chip_id, $value, $server_time, $device) = @_;
	return 0 unless $edt && $chip_id && defined $value && length $value;
	$server_time ||= &subs::rightNow();
	$device ||= &subs::device_setter();
	require Mojo::UserAgent;
	my $n = 0;
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes } ) {
		next unless (($rm->{'connection'} // '') eq 'active');
		next unless $rm->{'pubkey'};
		# only a machine sharing this network can be a LAN fallback
		my $lan = &subs::peer_lan_address($rm, 1);
		next unless $lan && $lan->{'manager'};
		my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 3);
		$ua = $ua->insecure(1);
		$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
		my $res = eval {
			$ua->post($lan->{'manager'} . '/manager/operator_door' => form => {
				signatorial => &subs::signatorial_designer(),
				edt => $edt,
				chip_id => $chip_id,
				device => $device,
				server_time => $server_time,
				value => $value,
			})->result;
		};
		$n++ if $res && $res->is_success;
	}
	return $n;
}

sub relay_headless {
	my ($data) = @_;
	$data ||= {};
	my $path = $data->{'path'} || return;
	my $c = &subs::controller_builder();
	my $req = $c->req;
	$req->url->path($path);
	$req->method(uc($data->{'method'} || 'POST'));
	my $params = { %{ $data->{'params'} || {} } };
	$params->{'remote_uuid'} = $data->{'remote_uuid'} if $data->{'remote_uuid'};
	# Mojo::Message::body_params is a getter here: passing a Mojo::Parameters to
	# it does nothing, so every headless relay POST carried an empty body. Encode
	# the form into the request body so remote_relay_request parses it.
	$req->headers->content_type('application/x-www-form-urlencoded');
	$req->body(Mojo::Parameters->new(%{$params})->to_string);
	return &subs::remote_relay_request($c, $data->{'extra'} || {});
}

# Leave a relay for the utility to drain. The queue is the headless rail: a
# watch press (or any job with no browser) can hand a change on and have it
# retried while the peer it names is away. Returns 1 when the item was queued.
sub remote_relay_queue_push {
	my ($item) = @_;
	return 0 unless ref $item eq 'HASH' && $item->{'path'};
	my $raw = &subs::setting_grabber({ app => '__president', setting => 'remote_relay_queue' });
	my $queue = eval { decode_json $raw } || [];
	$queue = [] unless ref $queue eq 'ARRAY';
	# A runaway producer must not grow the setting without bound.
	return 0 if scalar @{$queue} >= 200;
	my $copy = { %{$item} };
	$copy->{'attempts'} = 0 + ($copy->{'attempts'} || 0);
	$copy->{'expires'} ||= &subs::rightNow() + 30 * 60 * 1000;
	$copy->{'queued_at'} = &subs::rightNow();
	push @{$queue}, $copy;
	&subs::setting_setter({ app => '__president', setting => 'remote_relay_queue', value => encode_json($queue) });
	return 1;
}

# Drain the headless relay queue: a JSON list of relay_headless calls left by a
# job or a CLI with no browser to drive. The queue is cleared first, so a machine
# that has been away does not replay a stale backlog on every tick. A targeted
# item that did not land is put back with its attempt count: a peer that is only
# briefly away is reached when it returns, and one that stays away expires (or
# stops after thirty tries) instead of growing the queue forever. A broadcast is
# never retried - replaying a flood would run the movement everywhere twice.
sub remote_relay_queue_run {
	my $raw = &subs::setting_grabber({ app => '__president', setting => 'remote_relay_queue' });
	my $queue = eval { decode_json $raw } || [];
	return 0 unless ref $queue eq 'ARRAY' && scalar @{$queue};
	&subs::setting_setter({ app => '__president', setting => 'remote_relay_queue', value => '[]' });
	my $now = &subs::rightNow();
	my @keep;
	my $n = 0;
	foreach my $item ( @{$queue} ) {
		next unless ref $item eq 'HASH' && $item->{'path'};
		my $result;
		my $ran = eval { $result = &subs::relay_headless($item); 1 };
		my $delivered = 0;
		if ($ran) {
			if ($item->{'expect_json'}) {
				# /manager/reset answers JSON; an HTML body is the Gate page, so
				# the peer did not take the request.
				$delivered = (defined $result && $result =~ /^\s*\{/) ? 1 : 0;
			}
			else {
				$delivered = 1;
			}
		}
		if ($delivered) { $n++; next; }
		next unless $item->{'remote_uuid'};
		my $attempts = ($item->{'attempts'} || 0) + 1;
		my $expires = $item->{'expires'} || ($now + 30 * 60 * 1000);
		next if $attempts > 30 || $expires <= $now;
		$item->{'attempts'} = $attempts;
		$item->{'expires'} = $expires;
		push @keep, $item;
	}
	&subs::setting_setter({ app => '__president', setting => 'remote_relay_queue', value => encode_json(\@keep) }) if scalar @keep;
	return $n;
}

# The hub websocket endpoint a NAT'd peer dials out to. Preferred source is the
# hub's OWN manager URL from the handshake (e.g. https://thejunderground.com:45545),
# rewritten to wss -- so the peer dials the right host AND port instead of
# guessing from its own domain. config tunnel_hub overrides; the last resort is
# this machine's domain. The peer names itself with its own signatorial.
sub tunnel_hub_url {
	my ($manager, $ws_port) = @_;
	my $sig = &subs::signatorial_designer();
	my $hub;
	if ($config->{'tunnel_hub'}) {
		$hub = $config->{'tunnel_hub'};
	}
	elsif ($manager && $manager =~ m{^https?://}) {
		$hub = $manager;
		$hub =~ s{^http://}{ws://};
		$hub =~ s{^https://}{wss://};
		# the manager URL is only the base (e.g. wss://host:port), so drop a
		# trailing /manager if one is present and always point at the ws route.
		$hub =~ s{/manager/?$}{};
		$hub =~ s{/+$}{};
		# Bind the tunnel listeners on the hub's websocket server, not its main
		# server. The main server runs several prefork workers, and the hub's
		# listener table is per process: a redial could land in a worker that does
		# not know the peer's existing listeners and try to bind ports still held
		# by a sibling (EADDRINUSE). The websocket server runs a single worker, so
		# every session for a peer is retired and rebound in the same process.
		if (defined $ws_port && $ws_port =~ /^[0-9]+$/) {
			if (!($hub =~ s{:([0-9]+)$}{:$ws_port})) {
				$hub .= ':' . $ws_port;
			}
		}
	}
	else {
		$hub = 'wss://' . $config->{'domain'} . ($ws_port && $ws_port =~ /^[0-9]+$/ ? ':' . $ws_port : '');
	}
	# The data plane lives at a path, not at the bare host: a wss://host:port
	# dial with no path asks for `/`, where no websocket route exists, and the
	# holder just retries forever (the tunnels never stick). Normalise the path
	# last, so a config tunnel_hub that already names it is not doubled.
	$hub =~ s{/manager/tunnel/ws$}{};
	$hub =~ s{/+$}{};
	$hub .= '/manager/tunnel/ws';
	return $hub . (index($hub, '?') >= 0 ? '&' : '?') . 'signatorial=' . Mojo::Util::url_escape($sig);
}

# Run the peer half of the wss tunnel: dial the hub's manager and serve its
# `open` frames. $manager is the hub's manager URL from the handshake.
sub tunnel_wss_peer {
	my ($manager, $ws_port) = @_;
	my $sig = &subs::signatorial_designer();
	&Tunnel::peer_session(&subs::tunnel_hub_url($manager, $ws_port), { signatorial => $sig, sign => sub { &subs::peer_sign_request(@_) } });
	# peer_session is async and reconnects itself, so the loop has to run HERE or
	# the forked tunnel holder returns at once and the tunnel dies with it.
	Mojo::IOLoop->start;
}

sub tunnel_starter {
	my $data = shift;
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
	# A fresh batch supersedes any half-built one: a batch whose holder never came
	# up leaves 'connecting' rows that nothing reaps (tunnel_stopper only removes
	# active rows), so drop them here rather than let them pile up across dials.
	&subs::db_delete('tunnels', { signatorial => $signatorial, status => 'connecting' });
	my $rm = &subs::remote_useragent_maker({ signatorial => $signatorial });
	my $domain = $data->{'domain'} || $rm->{'domain'} || $rm->{'ip'};
	my $status = 'active';
	my $batch_uuid = &subs::random_string_creator(25);
	my $ports = {};
	foreach my $p ( @gb::ports ) {
		$ports->{$p} = $ENV{$p};
	}
	my $jports = encode_json $ports;
	my $url = $rm->{'manager'} . '/manager/configure/remote_machine/tunnel/request';
	my $form_data = {
		signatorial => &subs::signatorial_designer(),
		ports => $jports,
		status => $status,
		batch_uuid => $batch_uuid,
		domain => $domain
	};
#	&subs::tunnel_stopper({ signatorial => $signatorial });
	my $res = $rm->{'ua'}->post($url => form => $form_data)->result;

	my $port = $config->{'ssh_port'};
	if ($res->is_success) {
		if (eval { decode_json $res->body }) {
			my $rb = decode_json $res->body;
			# The tunnel data plane is the password-less websocket (tunnel.pl):
			# this device is the peer and dials the hub, which listens on the
			# reserved ports. One websocket carries every channel.
			my @batch_uuids;
			foreach my $r (@gb::ports ) {
				my $uuid = $rb->{$r}->{'reservation_uuid'} || &subs::random_string_creator(26);
				my $tunnel = {
					server_time => &subs::rightNow(),
					device => &subs::device_setter(),
					host => $config->{'domain'},
					timestamp => &subs::rightNow(),
					ip => $ip || $rm->{'ip'},
					domain => $domain,
					in_port => $rb->{$r}->{'source'},
					out_port => $rb->{$r}->{'dest'},
					name => $r,
					warranty => &subs::forever_warranty(),
					status => 'connecting',
					signatorial => $signatorial || $rm->{'signatorial'},
					uuid => $uuid,
					direction => 'in',
					batch_uuid => $batch_uuid
				};
				&subs::db_insert('tunnels', $tunnel);
				push @batch_uuids, $uuid;
				$tunnel->{'ip'} = $config->{'domain'};
				my $url = $rm->{'manager'} . '/manager/configure/remote_machine/tunnel/confirm';
				my $jtunnel = encode_json $tunnel;
				my $form_data = {
					signatorial => &subs::signatorial_designer(),
					tunnel => $jtunnel,
					status => $status,
					uuid => $uuid
				};
				$rm->{'ua'}->post($url => form => $form_data)->result;
			}
			# One holder holds the whole batch: hub_session reads this peer's
			# tunnels rows once, when the websocket arrives, and binds a listener
			# per row, so the peer dials a single connection after every port is
			# reserved and confirmed - one connection, all channels.
			my @uuids = @batch_uuids;
			my $pid;
			&subs::subprocessor(sub {
				$pid = $$;
				&subs::db_update('tunnels', { process_id => $pid, server_time => &subs::rightNow(), status => 'active' }, { uuid => $_ }) for @uuids;
				&subs::tunnel_wss_peer($rm->{'manager'}, $rm->{'ws_port'});
			}, { name => 'tunnel holder wss ' . scalar(@uuids) . ' ports', warranty => 'forever', fork => 1 });


		}
	}
	sleep 1;
	&Websocket::send('server', { console => &Websocket::console_command('tunnelLister')});
}

sub tunnel_stopper {
	my $data = shift;
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
	my $domain = $data->{'domain'};
	my $tunnels = &subs::db_select('tunnels', undef, { signatorial => $signatorial, status => 'active' })->hashes;
	my $rm = &subs::remote_useragent_maker({ signatorial => $signatorial });
	foreach my $tun ( @{$tunnels} ) {
		my $pid = $tun->{'process_id'};
		if ($pid) {
			my $process = `ps -e | grep $pid`;
			chomp $process;
			if ($process) {
				kill('INT', $tun->{'process_id'});
				waitpid($tun->{'process_id'}, 0);
			}
			my $url = $rm->{'manager'} . '/manager/configure/remote_machine/tunnel/close';
			$tun->{'status'} = 'closed';

			my $jtunnel = encode_json $tun;
			my $form_data = {
				signatorial => &subs::signatorial_designer(),
				tunnel => $jtunnel,
				status => $tun->{'status'}
			};
			my $res = $rm->{'ua'}->post($url => form => $form_data)->result;
			&subs::db_delete('tunnels', { uuid => $tun->{'uuid'}, signatorial => $tun->{'signatorial'} });
		} else {

		}
		&subs::db_delete('tunnels', { uuid => $tun->{'uuid'}, signatorial => $tun->{'signatorial'} });
	}
	my $c = &subs::controller_builder();
	my $tl = $c->render_to_string(template => 'configure/tunnel_list');
	&Websocket::send('server', { console => &Websocket::console_command('tunnelLister')});
}

1;
