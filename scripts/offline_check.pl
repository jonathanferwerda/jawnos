#!/usr/bin/perl
# offline_check.pl - would the LAN still work if the WAN went away?
#
#   perl scripts/offline_check.pl                 # local analysis, no network
#   perl scripts/offline_check.pl --json          # machine-readable report
#   perl scripts/offline_check.pl --probe         # opt-in: one TCP connect per best route
#
# Read-only. By default it reads this machine's roster and interfaces and makes
# no network calls: no peer is dialled and no name is resolved. `--probe` adds one
# short TCP connect per peer's best route; it is the only thing here that touches
# the network.
#
# The route it reports follows the peer rail's own order
# (lib/JawnOS/Domain/House.pm: peer_literal_addresses / peer_address_rank): a
# same-LAN literal first, then the tailnet (CGNAT), then an off-LAN literal, then
# a name. t/290-offline-check.t pins the ranking to subs::peer_address_rank.
#
# What it cannot see: whether the LAN itself is isolated (guest Wi-Fi/AP
# isolation), a peer that was never in this machine's roster, and power. Those
# are in docs/blackout.md.
#
# Exit 0 = no blocker, 1 = at least one blocker, 2 = usage or database error.

package JawnOS::OfflineCheck;

use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec ();
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use POSIX qw(strftime);
use Socket qw(inet_aton inet_ntoa);

my $PRESENCE_PORT = 45552;
my $DEFAULT_PORT  = 45545;
my $PEER_OFFSET   = 6;

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

sub report(%opt) {
	my $root = $opt{'root'} || '.';
	my $db = $opt{'db'} || File::Spec->catfile($root, 'database', 'jawnos.db');
	my $config_path = $opt{'config'} || File::Spec->catfile($root, 'config.json');
	my $config = load_config($config_path);
	my $dbh = open_db($db);

	my $nics = defined $opt{'nics'} ? $opt{'nics'} : local_interfaces();
	my $listeners = defined $opt{'listeners'} ? $opt{'listeners'} : listening_ports();
	my $mdns = defined $opt{'mdns'} ? $opt{'mdns'} : mdns_tool();
	my $house_ca = defined $opt{'house_ca'} ? $opt{'house_ca'} : house_ca_path($root);
	my $now = $opt{'now'} || time();
	my $probe = $opt{'probe'} ? 1 : 0;

	my $sync_hub = read_setting($dbh, '__president', 'sync_hub');
	$sync_hub = '' unless defined $sync_hub;
	$sync_hub =~ s/^\s+|\s+$//g;
	my $topology = read_setting($dbh, 'sync', 'topology', 'all');
	$topology = read_setting($dbh, '__president', 'sync_topology')
		unless defined $topology && length $topology;
	$topology = 'auto' unless defined $topology && $topology =~ /^(?:auto|mesh|hub)$/;

	my $rows = $dbh->selectall_arrayref('SELECT * FROM remote_machines', { Slice => {} }) || [];
	my $local_device = $config->{'device'} // '';
	my @peers = map { analyze_peer($_, $nics, $sync_hub, $probe, $local_device) } @{$rows};
	@peers = sort {
		($a->{'is_hub'} ? 1 : 0) <=> ($b->{'is_hub'} ? 1 : 0)
			|| (($a->{'hostname'} // '') cmp ($b->{'hostname'} // ''))
	} @peers;
	$dbh->disconnect;

	my $working_port = $config->{'working_port'} || $DEFAULT_PORT;
	$working_port = $DEFAULT_PORT unless $working_port =~ /^\d+$/;

	my $manager_state = 'unknown';
	my $presence_state = 'unknown';
	if (ref $listeners eq 'HASH') {
		$manager_state = ($listeners->{'tcp'} && $listeners->{'tcp'}{$working_port})
			? 'listening' : 'not listening';
		$presence_state = ($listeners->{'udp'} && $listeners->{'udp'}{$PRESENCE_PORT})
			? 'listening' : 'not listening';
	}

	my @blockers;
	for my $p (@peers) {
		next if $p->{'is_hub'};
		next unless ($p->{'connection'} // '') eq 'active';
		next if $p->{'lan_ready'};
		my $best = $p->{'best'};
		push @blockers, {
			hostname => $p->{'hostname'},
			blocker => 'no same-LAN address; best route is '
				. ($best ? $best->{'scope'} . ' ' . $best->{'host'} : 'a name or nothing'),
		};
	}
	push @blockers, {
		hostname => '(local)',
		blocker => 'presence listener is not bound on UDP ' . $PRESENCE_PORT
			. ' (beacons cannot refresh a moved address)',
	} if $presence_state eq 'not listening';
	push @blockers, {
		hostname => '(local)',
		blocker => 'manager is not listening on TCP ' . $working_port
			. ' (the panel is not reachable on this machine)',
	} if $manager_state eq 'not listening';

	my @notes;
	push @notes, 'no remote_machines rows: pair a peer first, then this has something to check'
		unless @peers;
	push @notes, "sync topology is '$topology' (LAN peers still stay in the pass)"
		if $topology ne 'auto';
	push @notes, 'house CA is missing: the peer listener falls back to the signed rail, not verified TLS'
		unless $house_ca;
	push @notes, 'mDNS tool is missing (embedded discovery is local-only)'
		unless $mdns;
	push @notes, 'loopback_manager is on: the app opens this machine directly'
		if $config->{'loopback_manager'};

	my @lan = grep { ($_->{'kind'} // '') eq 'lan' } @{$nics};
	my @tailnet = grep { ($_->{'kind'} // '') eq 'tailnet' } @{$nics};
	my $lan_peers = grep { $_->{'lan_ready'} } @peers;
	my $wan_only = grep { !$_->{'lan_ready'} } @peers;

	return {
		tool => 'offline_check',
		version => 1,
		generated_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($now)),
		root => $root,
		db => $db,
		config => $config_path,
		machine => {
			name => $config->{'name'} // '',
			device => $config->{'device'} // '',
			domain => $config->{'domain'} // '',
			working_port => $working_port + 0,
			loopback_manager => $config->{'loopback_manager'} ? 1 : 0,
		},
		settings => {
			sync_hub => $sync_hub ? substr($sync_hub, 0, 8) : '',
			topology => $topology,
		},
		local => {
			manager_listener => $manager_state,
			presence_listener => $presence_state,
			house_ca => $house_ca ? 1 : 0,
			house_ca_path => $house_ca,
			mdns => $mdns,
			nics => $nics,
			lan => \@lan,
			tailnet => \@tailnet,
		},
		peers => \@peers,
		verdict => {
			lan_ready => @blockers ? 0 : 1,
			lan_peers => scalar($lan_peers),
			wan_only_peers => scalar($wan_only),
			blockers => \@blockers,
			notes => [ grep { defined $_ && length $_ } @notes ],
			exit_code => @blockers ? 1 : 0,
		},
	};
}

sub analyze_peer($row, $nics, $sync_hub, $probe, $local_device) {
	my $sig = $row->{'signatorial'} // '';
	my $is_hub = ((($row->{'device'} // '') eq 'server')
		|| ($sync_hub ne '' && $sig eq $sync_hub)) ? 1 : 0;
	my $net = decode_hash($row->{'network'});
	my $tunnel = ($row->{'tunnel'} // '') eq 'yes' ? 1 : 0;
	my $port = $row->{'port'};
	$port = $DEFAULT_PORT unless defined $port && $port =~ /^\d+$/ && $port > 0;

	my @candidates = literal_candidates($row, $net, $nics, $port, $local_device);
	my @names = name_candidates($row);
	my $best = $candidates[0];
	my $route = $best ? $best->{'scope'} : (@names ? 'name' : 'none');
	my $lan_ready = ($best && $best->{'rank'} == 0) ? 1 : 0;

	my @warnings;
	push @warnings, 'hub row: needs the WAN' if $is_hub;
	push @warnings, 'tunnel row: the stored manager is the hub loopback' if $tunnel;
	push @warnings, 'tailnet only: needs the WAN' if $route eq 'tailnet';
	push @warnings, 'off-LAN literal only' if $route eq 'off-lan';
	push @warnings, 'public literal only' if $route eq 'public';
	push @warnings, 'name only: needs DNS' if $route eq 'name';
	push @warnings, 'no address in the row' if $route eq 'none';
	push @warnings, 'inactive' if (($row->{'connection'} // '') ne 'active');
	push @warnings, 'no pinned pubkey: the beacon key is learned on first sight'
		unless length($row->{'pubkey'} // '');

	my $answered = '';
	if ($probe && $best) {
		require IO::Socket::INET;
		my $sock = IO::Socket::INET->new(
			PeerAddr => $best->{'host'},
			PeerPort => $best->{'port'},
			Proto => 'tcp',
			Timeout => 1,
		);
		$answered = $sock ? 'answered' : 'no answer';
		close $sock if $sock;
	}

	return {
		hostname => $row->{'hostname'} // '',
		id => substr($sig, 0, 8),
		device => $row->{'device'} // '',
		connection => $row->{'connection'} // '',
		tunnel => $tunnel ? 'yes' : 'no',
		manager => $row->{'manager'} // '',
		fqdn => $row->{'fqdn'} // '',
		is_hub => $is_hub,
		route => $route,
		lan_ready => $lan_ready,
		best => $best,
		peer_port => ($best && $best->{'rank'} != 4) ? peer_port_for($best->{'port'}) : undef,
		candidates => \@candidates,
		names => \@names,
		warnings => \@warnings,
		probe => $probe ? ($answered || 'no route') : 'skipped',
	};
}

# ---------------------------------------------------------------------------
# The route order, matching lib/JawnOS/Domain/House.pm
# ---------------------------------------------------------------------------

sub literal_candidates($row, $net, $nics, $port, $local_device) {
	my @out;
	my %seen;
	my $tunnel = ($row->{'tunnel'} // '') eq 'yes';
	my $add = sub {
		my ($host, $p, $why) = @_;
		return unless defined $host && length $host;
		$host =~ s/^\s+|\s+$//g;
		$host =~ s/^\[|\]$//g;
		return if $host eq '' || $host eq '0.0.0.0' || $host eq '255.255.255.255';
		return unless is_literal($host);
		return if is_loopback($host) && !$tunnel;
		$p = $port unless defined $p && $p =~ /^\d+$/ && $p > 0;
		my $key = $host . ':' . $p;
		return if $seen{$key}++;
		my $rank = address_rank($host, $nics);
		push @out, {
			host => $host,
			port => $p + 0,
			why => $why,
			rank => $rank,
			scope => scope_name($rank),
		};
	};

	$add->($row->{'ip'}, $port, 'ip');
	$add->($row->{'lan_ip'}, $port, 'lan_ip');
	$add->($row->{'vip'}, $port, 'vip');
	my $lan = (($local_device // '') ne 'server') ? advertised_lan($net, $nics) : undef;
	$add->($lan->{'ip'}, $lan->{'port'}, 'advertised lan') if $lan;
	my ($mhost, $mport) = manager_host_port($row);
	$add->($mhost, $mport, 'manager') if defined $mhost;
	# The app only walks a peer's network map when this machine is not the hub
	# (House.pm: peer_literal_addresses). A hub that dialled a home LAN address
	# from the peer's own map would be guessing at a network it is not on.
	if (($local_device // '') ne 'server') {
		for my $nic (sort keys %{$net}) {
			next if $nic eq 'public_address';
			next unless ref $net->{$nic} eq 'HASH';
			$add->($net->{$nic}{'ip'}, $net->{$nic}{'port'}, 'advertised ' . $nic);
		}
	}
	my $pseu = decode_hash($row->{'pseudonyms'});
	$add->($pseu->{'ip'}, $pseu->{'port'}, 'pseudonym') if $pseu->{'ip'};
	$add->(tailnet_address($row, $net), $port, 'tailnet');

	my $i = 0;
	my %at = map { ($_->{'host'} . ':' . $_->{'port'}) => $i++ } @out;
	@out = sort {
		$a->{'rank'} <=> $b->{'rank'}
			|| $at{$a->{'host'} . ':' . $a->{'port'}} <=> $at{$b->{'host'} . ':' . $b->{'port'}}
	} @out;
	return @out;
}

sub name_candidates($row) {
	my @out;
	my $add = sub {
		my ($host, $why) = @_;
		return unless defined $host && length $host;
		return if is_literal($host);
		return if $host =~ /^(?:localhost|::1)$/i;
		push @out, { host => $host, why => $why };
	};
	$add->($row->{'fqdn'}, 'fqdn');
	my ($mhost) = manager_host_port($row);
	$add->($mhost, 'manager name') if defined $mhost;
	return @out;
}

sub advertised_lan($net, $nics) {
	for my $nic (sort keys %{$net}) {
		next if $nic eq 'public_address';
		next unless ref $net->{$nic} eq 'HASH';
		my $ip = $net->{$nic}{'ip'} // '';
		next unless is_literal($ip);
		for my $me (@{$nics}) {
			next unless defined $me->{'ip'} && length $me->{'ip'};
			return { ip => $ip, port => $net->{$nic}{'port'} } if same_net($ip, $me);
		}
	}
	return undef;
}

sub tailnet_address($row, $net) {
	for my $nic (sort keys %{$net}) {
		next unless ref $net->{$nic} eq 'HASH';
		my $ip = $net->{$nic}{'ip'} // '';
		return $ip if is_cgnat($ip);
	}
	my $ip = $row->{'ip'} // '';
	return $ip if is_cgnat($ip);
	return $row->{'tailnet_ip'} // '';
}

# 0 = on a local subnet, 1 = tailnet, 2 = a private literal we are not on,
# 3 = a public literal, 4 = the hub's loopback tunnel. This mirrors the order
# peer_literal_addresses sorts by: LAN first, the tailnet second.
sub address_rank($host, $nics) {
	return 4 if is_loopback($host);
	my $base = base_address_rank($host);
	return 1 if $base == 1;
	return 3 if $base == 2;
	return 0 if on_local_subnet($host, $nics);
	return 2;
}

# The three-way classification in subs::peer_address_rank, kept separately so
# the test can pin it to the real function.
sub base_address_rank($host) {
	return 0 if is_private($host) && !is_cgnat($host);
	return 1 if is_cgnat($host);
	return 2;
}

sub scope_name($rank) {
	return 'lan' if $rank == 0;
	return 'tailnet' if $rank == 1;
	return 'off-lan' if $rank == 2;
	return 'public' if $rank == 3;
	return 'tunnel';
}

sub peer_port_for($port) {
	$port = $DEFAULT_PORT unless defined $port && $port =~ /^\d+$/ && $port > 0;
	my $peer = $port + $PEER_OFFSET;
	$peer -= 2 * $PEER_OFFSET if $peer > 65535;
	return $peer;
}

# ---------------------------------------------------------------------------
# Address helpers
# ---------------------------------------------------------------------------

sub is_literal($host) {
	return 0 unless defined $host && length $host;
	return 1 if $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	return 1 if $host =~ /^[0-9a-fA-F:.]+$/ && $host =~ /:/;
	return 0;
}

sub is_loopback($host) {
	return 0 unless defined $host && length $host;
	return 1 if $host =~ /^127\./;
	return 1 if $host =~ /^(?:localhost|::1)$/i;
	return 0;
}

sub is_cgnat($host) {
	return 0 unless defined $host && length $host;
	return $host =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./ ? 1 : 0;
}

sub is_private($host) {
	return 0 unless defined $host && length $host;
	return 1 if $host =~ /^10\./;
	return 1 if $host =~ /^192\.168\./;
	return 1 if $host =~ /^169\.254\./;
	return 1 if $host =~ /^172\.(?:1[6-9]|2\d|3[01])\./;
	return 1 if is_cgnat($host);
	return 0;
}

sub on_local_subnet($host, $nics) {
	for my $nic (@{$nics || []}) {
		next unless defined $nic->{'ip'} && length $nic->{'ip'};
		return 1 if same_net($host, $nic);
	}
	return 0;
}

sub same_net($host, $nic) {
	my $a = inet_aton($host);
	my $b = inet_aton($nic->{'ip'} // '');
	return 0 unless defined $a && defined $b;
	my $prefix = $nic->{'prefix'};
	$prefix = 32 unless defined $prefix && $prefix =~ /^\d+$/ && $prefix >= 0 && $prefix <= 32;
	my $mask = $prefix == 0 ? 0 : (0xffffffff << (32 - $prefix)) & 0xffffffff;
	return ((unpack('N', $a) & $mask) == (unpack('N', $b) & $mask)) ? 1 : 0;
}

sub cidr($ip, $prefix) {
	my $packed = inet_aton($ip);
	return '' unless defined $packed;
	my $n = unpack('N', $packed);
	my $mask = $prefix == 0 ? 0 : (0xffffffff << (32 - $prefix)) & 0xffffffff;
	return inet_ntoa(pack('N', $n & $mask)) . '/' . $prefix;
}

sub manager_host_port($row) {
	my $manager = $row->{'manager'} // '';
	return () unless $manager =~ m{^https?://(\[[^\]]+\]|[^/:]+)};
	my $host = $1;
	$host =~ s/^\[|\]$//g;
	my ($port) = $manager =~ m{:(\d{1,5})/?$};
	return ($host, $port);
}

# ---------------------------------------------------------------------------
# Reading the machine
# ---------------------------------------------------------------------------

sub load_config($path) {
	return {} unless defined $path && -f $path;
	my $raw = read_file($path);
	return {} unless defined $raw && length $raw;
	my $v = eval { JSON::PP->new->decode($raw) };
	return ref $v eq 'HASH' ? $v : {};
}

sub open_db($path) {
	die "database not found: $path\n" unless defined $path && -f $path;
	require DBI;
	my %attr = (RaiseError => 1, PrintError => 0, AutoCommit => 1, ReadOnly => 1);
	my $dbh = eval { DBI->connect("dbi:SQLite:dbname=$path", '', '', \%attr) };
	if (!$dbh) {
		# A live WAL database can refuse a purely read-only handle when the
		# directory is not writable. Query-only is the guard on this path.
		$attr{'ReadOnly'} = 0;
		$dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '', \%attr);
	}
	$dbh->do('PRAGMA query_only = 1');
	$dbh->sqlite_busy_timeout(2000) if $dbh->can('sqlite_busy_timeout');
	return $dbh;
}

sub read_setting($dbh, $app, $setting, $device = undef) {
	my $sql = 'SELECT value FROM settings WHERE app = ? AND setting = ?';
	my @bind = ($app, $setting);
	if (defined $device && length $device) {
		$sql .= ' AND device = ?';
		push @bind, $device;
	}
	$sql .= ' ORDER BY server_time DESC LIMIT 1';
	my $value = eval { $dbh->selectrow_array($sql, undef, @bind) };
	return defined $value ? $value : undef;
}

# `ip -o -4 addr show` on Linux, `ifconfig` elsewhere. Reads interfaces only;
# it never sends a packet.
sub local_interfaces() {
	my @out = ip_interfaces();
	@out = ifconfig_interfaces() unless @out;
	return \@out;
}

sub ip_interfaces() {
	my $ip = which('ip');
	return () unless $ip;
	open(my $fh, '-|', $ip, '-o', '-4', 'addr', 'show') or return ();
	my @out;
	while (my $line = <$fh>) {
		next unless $line =~ /^\d+:\s+(\S+)\s+inet\s+(\d{1,3}(?:\.\d{1,3}){3})\/(\d{1,2})/;
		my ($nic, $addr, $prefix) = ($1, $2, $3);
		next if $nic eq 'lo' || $addr =~ /^127\./;
		my ($broadcast) = $line =~ /\bbrd\s+(\d{1,3}(?:\.\d{1,3}){3})/;
		push @out, {
			nic => $nic,
			ip => $addr,
			prefix => $prefix + 0,
			network => cidr($addr, $prefix + 0),
			broadcast => $broadcast // '',
			kind => nic_kind($nic, $addr),
		};
	}
	close $fh;
	return @out;
}

sub ifconfig_interfaces() {
	my $ifconfig = which('ifconfig');
	return () unless $ifconfig;
	open(my $fh, '-|', $ifconfig) or return ();
	my @out;
	my $nic = '';
	while (my $line = <$fh>) {
		if ($line =~ /^(\S+):\s/) {
			$nic = $1;
			next;
		}
		next unless $line =~ /^\s+inet\s+(\d{1,3}(?:\.\d{1,3}){3})\s+netmask\s+(\S+)(?:\s+broadcast\s+(\d{1,3}(?:\.\d{1,3}){3}))?/;
		my ($addr, $mask, $broadcast) = ($1, $2, $3);
		next if $nic eq 'lo' || $addr =~ /^127\./;
		my $prefix = netmask_prefix($mask);
		push @out, {
			nic => $nic,
			ip => $addr,
			prefix => $prefix,
			network => cidr($addr, $prefix),
			broadcast => $broadcast // '',
			kind => nic_kind($nic, $addr),
		};
	}
	close $fh;
	return @out;
}

sub netmask_prefix($mask) {
	return $mask + 0 if defined $mask && $mask =~ /^\d+$/ && $mask <= 32;
	my $n = defined $mask && $mask =~ /^0x[0-9a-f]+$/i ? hex($mask) : 0;
	my $bits = 0;
	while ($n) {
		$bits += $n & 1;
		$n >>= 1;
	}
	return $bits;
}

sub nic_kind($nic, $addr) {
	return 'tailnet' if is_cgnat($addr);
	return 'tunnel' if $nic =~ /^(?:tunnel|tun|tap|wg|tailscale|utun|ppp|zt|nordlynx|proton)/i;
	return 'lan' if is_private($addr);
	return 'other';
}

# Listening sockets, from `ss`/`netstat` output. No connection is opened.
sub listening_ports() {
	my %out = (tcp => {}, udp => {});
	my @tool = which('ss') ? ('ss') : (which('netstat') ? ('netstat') : ());
	return undef unless @tool;
	my $found = 0;
	for my $pair (['-ltn', 'tcp'], ['-lun', 'udp']) {
		open(my $fh, '-|', $tool[0], $pair->[0]) or next;
		$found = 1;
		while (my $line = <$fh>) {
			next unless $line =~ /:(\d{1,5})\s/;
			$out{$pair->[1]}{$1} = 1;
		}
		close $fh;
	}
	return $found ? \%out : undef;
}

sub mdns_tool() {
	if ($^O eq 'linux') {
		my $browse = which('avahi-browse');
		my $publish = which('avahi-publish-service');
		return 'avahi' if $browse && $publish;
		return 'avahi (browse only)' if $browse;
		return 'avahi (publish only)' if $publish;
		return '';
	}
	if ($^O eq 'darwin') {
		return which('dns-sd') ? 'dns-sd' : '';
	}
	return '';
}

sub house_ca_path($root) {
	my $path = File::Spec->catfile($root, 'server', 'house-ca.pem');
	return -s $path ? $path : '';
}

sub which($name) {
	return '' unless defined $name && length $name;
	return $name if $name =~ m{/} && -x $name;
	my @dir = split /:/, ($ENV{'PATH'} // '');
	push @dir, '/usr/sbin', '/sbin', '/usr/local/sbin';
	for my $dir (@dir) {
		next unless defined $dir && length $dir;
		my $path = "$dir/$name";
		return $path if -f $path && -x $path;
	}
	return '';
}

sub read_file($path) {
	open(my $fh, '<', $path) or return '';
	local $/;
	my $raw = <$fh>;
	close $fh;
	return defined $raw ? $raw : '';
}

sub decode_hash($raw) {
	return {} unless defined $raw && length $raw;
	my $value = eval { JSON::PP->new->decode($raw) };
	return ref $value eq 'HASH' ? $value : {};
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

sub render_text($r) {
	my $m = $r->{'machine'};
	my $l = $r->{'local'};
	my $o = '';
	$o .= 'offline check - ' . ($m->{'name'} || '(unnamed)')
		. ' (' . ($m->{'device'} || '?') . ') - ' . $r->{'generated_at'} . "\n";
	$o .= '  db:       ' . $r->{'db'} . " (read-only)\n";
	$o .= '  config:   ' . $r->{'config'} . "\n";
	$o .= '  manager:  https://127.0.0.1:' . $m->{'working_port'}
		. ' (' . $l->{'manager_listener'} . ")\n";
	$o .= '  presence: udp/' . $PRESENCE_PORT
		. ' (' . $l->{'presence_listener'} . ")\n";
	$o .= '  house CA: ' . ($l->{'house_ca'} ? $l->{'house_ca_path'} : 'MISSING') . "\n";
	$o .= '  mDNS:     ' . ($l->{'mdns'} || 'none') . "\n";
	my @lan = @{ $l->{'lan'} || [] };
	my @tailnet = @{ $l->{'tailnet'} || [] };
	$o .= '  LAN:      ' . (@lan
		? join(', ', map { $_->{'nic'} . ' ' . $_->{'ip'} . '/' . $_->{'prefix'} } @lan)
		: 'none') . "\n";
	$o .= '  tailnet:  ' . (@tailnet
		? join(', ', map { $_->{'nic'} . ' ' . $_->{'ip'} . '/' . $_->{'prefix'} } @tailnet)
		: 'none') . "\n";
	$o .= "\n";
	$o .= sprintf("%-18s %-9s %-26s %-7s %-9s %s\n",
		'PEER', 'ROUTE', 'ADDRESS', 'TUNNEL', 'STATE', 'NOTE');
	for my $p (@{ $r->{'peers'} || [] }) {
		my $best = $p->{'best'};
		my $names = $p->{'names'} || [];
		my $addr = $best
			? $best->{'host'} . ':' . $best->{'port'}
			: (@{$names} ? $names->[0]->{'host'} . ':name' : '-');
		my $note = @{ $p->{'warnings'} || [] } ? join('; ', @{ $p->{'warnings'} }) : '-';
		$o .= sprintf("%-18s %-9s %-26s %-7s %-9s %s\n",
			substr($p->{'hostname'} || '(unnamed)', 0, 18),
			$p->{'route'},
			substr($addr, 0, 26),
			$p->{'tunnel'},
			$p->{'connection'} || '?',
			$note);
	}
	$o .= "\n";
	my $v = $r->{'verdict'};
	if (@{ $v->{'blockers'} || [] }) {
		$o .= 'verdict: NOT LAN-ready - ' . scalar(@{ $v->{'blockers'} }) . " blocker(s)\n";
		for my $b (@{ $v->{'blockers'} }) {
			$o .= '  - ' . ($b->{'hostname'} || '(unnamed)') . ': ' . $b->{'blocker'} . "\n";
		}
	}
	else {
		$o .= 'verdict: LAN-ready for ' . $v->{'lan_peers'} . ' peer(s)';
		$o .= '; ' . $v->{'wan_only_peers'} . ' peer(s) still need the WAN'
			if $v->{'wan_only_peers'};
		$o .= "\n";
	}
	for my $note (@{ $v->{'notes'} || [] }) {
		$o .= '  note: ' . $note . "\n";
	}
	return $o;
}

sub usage() {
	return <<'USAGE';
offline_check.pl - would the LAN still work if the WAN went away?

  perl scripts/offline_check.pl [--json] [--probe] [--root DIR] [--db FILE] [--config FILE]

Read-only. By default it reads this machine's roster and interfaces and makes no
network calls: no peer is dialled and no name is resolved. --probe adds one short
TCP connect per peer's best route; it is the only thing here that touches the
network.

Exit 0 = no blocker, 1 = at least one blocker, 2 = usage or database error.
USAGE
}

sub main() {
	my %opt = (json => 0, probe => 0, help => 0);
	GetOptions(\%opt, 'root=s', 'db=s', 'config=s', 'json', 'probe', 'help')
		or do { print STDERR usage(); return 2 };
	if ($opt{'help'}) {
		print usage();
		return 0;
	}
	my $root = $opt{'root'}
		? abs_path($opt{'root'})
		: abs_path(File::Spec->catdir(dirname(abs_path($0)), '..'));
	return 2 unless defined $root && -d $root;
	my $db = $opt{'db'} || File::Spec->catfile($root, 'database', 'jawnos.db');
	my $config = $opt{'config'} || File::Spec->catfile($root, 'config.json');
	my $report = eval {
		report(
			root => $root,
			db => $db,
			config => $config,
			probe => $opt{'probe'},
			now => time(),
		);
	};
	if (!$report) {
		my $error = $@ || 'unknown error';
		$error =~ s/\s+$//;
		print STDERR "offline_check: $error\n";
		return 2;
	}
	if ($opt{'json'}) {
		print JSON::PP->new->canonical->pretty->encode($report), "\n";
	}
	else {
		print render_text($report);
	}
	return $report->{'verdict'}{'exit_code'};
}

unless (caller) {
	exit main();
}

1;
