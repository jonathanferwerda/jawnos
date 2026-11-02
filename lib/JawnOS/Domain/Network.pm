package subs;

# Network: extracted from subroutines.pl (package subs). Loaded on
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
our $log;
our %m;

# The device rows as the lister shows them, grouped by the network each
# neighbour sits on: one group per subnet, its members (the interfaces that
# reach it, each on a machine), and the devices found there. device_lister has
# already left each address once, so a device is listed under a single network.
sub network_groups {
	my ($devices) = @_;
	return [] unless ref $devices;
	# device_lister hands back a Mojo::Collection (a blessed array), not a plain
	# one, so dereference it rather than testing for 'ARRAY'.
	my @rows = eval { @{$devices} };
	return [] unless @rows;
	my (%groups, @order);
	foreach my $d (@rows) {
		next unless ref $d eq 'HASH';
		$d->{'address'} = eval { return decode_json $d->{'address'} } if $d->{'address'} && !ref $d->{'address'};
		foreach my $nic (keys %{$d->{'address'} || {}}) {
			my $a = $d->{'address'}->{$nic};
			next unless ref $a eq 'HASH';
			my $cidr = &subnet_cidr($a->{'ip'}, $a->{'netmask'}) || ($a->{'ip'} ? $a->{'ip'} : 'unknown');
			unless ($groups{$cidr}) {
				$groups{$cidr} = { cidr => $cidr, members => [] };
				push @order, $cidr;
			}
			push @{$groups{$cidr}->{'members'}}, {
				%{$a},
				uuid => $d->{'uuid'},
				hostname => $d->{'hostname'},
				domain => $d->{'domain'},
				machine_timestamp => $d->{'timestamp'},
				formatted_time => $d->{'formatted_time'},
			};
		}
	}
	# the real networks first, the loopback (this machine, and its tunnels) last
	my @sorted = sort {
		my $al = index($a, '127.') == 0 ? 1 : 0;
		my $bl = index($b, '127.') == 0 ? 1 : 0;
		$al <=> $bl
			|| join('.', map { sprintf '%03d', $_ } split /[.\/]/, $a) cmp join('.', map { sprintf '%03d', $_ } split /[.\/]/, $b);
	} @order;
	return [ map { $groups{$_} } @sorted ];
}

# The machines remote_machines knows that no neighbour table shows. A peer
# reached over the tailnet, or one on a subnet none of this machine's NICs
# reach, is in remote_machines but in no `devices` neighbour list, so the
# network cards never draw it. Deduplicate by signatorial, or by address when a
# row has none, so the card only adds what the neighbour tables missed.
sub remote_machine_orphans {
	my ($devices) = @_;
	my (%shown_sig, %shown_ip);
	foreach my $d ( eval { @{$devices || []} } ) {
		next unless ref $d eq 'HASH';
		$d->{'address'} = eval { return decode_json $d->{'address'} } if $d->{'address'} && !ref $d->{'address'};
		foreach my $nic ( keys %{$d->{'address'} || {}} ) {
			foreach my $n ( @{$d->{'address'}->{$nic}->{'neigh'} || []} ) {
				next unless ref $n eq 'HASH';
				$shown_sig{ $n->{'signatorial'} } = 1 if $n->{'signatorial'};
				my $ip = $n->{'ip'} || $n->{'ip_address'};
				$shown_ip{$ip} = 1 if $ip;
			}
		}
	}
	my $self = eval { &signatorial_designer() } || '';
	my @rows;
	foreach my $rm ( @{ &db_select('remote_machines')->hashes || [] } ) {
		next unless ref $rm eq 'HASH';
		my $sig = $rm->{'signatorial'} || '';
		next if $self ne '' && $sig eq $self;
		my $ip = $rm->{'ip'} || '';
		if ($sig ne '') { next if $shown_sig{$sig}; }
		else { next if $ip ne '' && $shown_ip{$ip}; }
		# A tunnel stores a loopback manager in the Go button; point it at the
		# peer's own name when one is known, the same rewrite the neighbour rows
		# make.
		my $port = $rm->{'port'} || 45545;
		my $manager = $rm->{'manager'} || '';
		my $peer_manager = '';
		if (($rm->{'fqdn'} || '') ne '') {
			$peer_manager = 'https://' . $rm->{'fqdn'} . ':' . $port . '/manager';
		}
		elsif ($manager !~ m{^https?://(?:127\.0\.0\.1|localhost|\[::1\])(?::|/|$)}) {
			$peer_manager = $manager;
			$peer_manager =~ s{/manager$}{};
			$peer_manager .= '/manager' if $peer_manager ne '';
		}
		my $buttons = $rm->{'buttons'} || '';
		if ($peer_manager ne '') {
			$buttons =~ s{manager="https?://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?/manager"}{manager="$peer_manager"}g;
		}
		# claim the key too, so a duplicate row in remote_machines is not listed twice
		if ($sig ne '') { $shown_sig{$sig} = 1; }
		elsif ($ip ne '') { $shown_ip{$ip} = 1; }
		push @rows, { %{$rm}, manager => ($peer_manager || $manager), buttons => $buttons };
	}
	return \@rows;
}

# --- JawnOS BLE bridge (replaces the am broadcast + Tasker + BLE plugin chain) ---
sub ble_bridge_enabled {
	# On by default now that the phone's Tasker bridge is retired. Set
	# ble_bridge to 0 in config.json to fall back to the old broadcast path.
	return 1 unless $config && defined $config->{'ble_bridge'};
	return $config->{'ble_bridge'} ? 1 : 0;
}

sub ble_bridge_capable {
	# Can this machine drive the wrist/board bridge? It is the mobile hub when
	# config says so (the original rule), or any machine that actually runs the
	# bridge daemon on its own loopback (the Linux/desktop port). The gate used
	# to be `device_setter() eq 'mobile'` alone, which left a desktop with a
	# live daemon unable to answer a watch's room_request or push a toggle.
	return 1 if &subs::device_setter() eq 'mobile';
	return 0 unless &subs::ble_bridge_enabled();
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => 45999, Proto => 'tcp', Timeout => 1);
	return 0 unless $sock;
	close $sock;
	return 1;
}

sub ble_bridge_client {
	# jawn-bt client of the JawnOS BLE bridge daemon (JawnBleService in the
	# JawnOS API app). Prefer the copy that ships with the repo.
	foreach my $c ( "$ENV{HOME}/jawnos/scripts/jawn-bt", "$ENV{HOME}/jawn-bt", './scripts/jawn-bt' ) {
		return $c if -e $c;
	}
	return undef;
}

# ---- multi-link bridge state (protocol v2) --------------------------------
# A desktop or phone bridge can hold several radios at once. Every link event
# names its MAC; keep the same map here so a send, a yield and a sighting can
# name the right radio instead of guessing at "the" link. A v1 daemon still
# works: its status has no links[], so the top-level fields become the one link.
sub ble_link_key {
	my ($mac) = @_;
	return '' unless defined $mac && length $mac;
	$mac = uc $mac;
	$mac =~ s/[^0-9A-F]//g;
	return $mac;
}

sub ble_links {
	$gb::ble_links ||= {};
	return $gb::ble_links;
}

sub ble_link_apply_event {
	my ($event) = @_;
	return unless $event && ref $event eq 'HASH';
	my $name = $event->{'event'} || '';
	my $links = &ble_links();
	if ($name eq 'status') {
		my %next;
		foreach my $l ( @{ $event->{'links'} || [] } ) {
			next unless ref $l eq 'HASH';
			my $mac = &ble_link_key($l->{'mac'});
			next unless $mac;
			$next{$mac} = { %{$l}, mac => $mac };
		}
		if (!@{ $event->{'links'} || [] }) {
			my $mac = &ble_link_key($event->{'mac'});
			if ($mac && $event->{'connected'}) {
				$next{$mac} = { mac => $mac, connected => 1, mtu => $event->{'mtu'}, state => 'connected' };
			}
		}
		$gb::ble_links = \%next;
		my $p = &ble_link_key($event->{'mac'});
		$gb::ble_primary_mac = ($p && $next{$p} && $next{$p}->{'connected'}) ? $p : undef;
	}
	elsif ($name eq 'connected') {
		my $mac = &ble_link_key($event->{'mac'}) or return;
		$links->{$mac} = { %{ $links->{$mac} || {} }, %{$event}, mac => $mac, connected => 1, state => 'connected' };
		$links->{$mac}->{'since'} ||= time();
		$gb::ble_primary_mac = $mac;
	}
	elsif ($name eq 'disconnected') {
		my $mac = &ble_link_key($event->{'mac'}) or return;
		if ($links->{$mac}) {
			$links->{$mac}->{'connected'} = 0;
			$links->{$mac}->{'state'} = $event->{'next_retry_ms'} ? 'reconnecting' : 'idle';
		}
	}
	my $primary = $gb::ble_primary_mac;
	unless ($primary && $links->{$primary} && $links->{$primary}->{'connected'}) {
		my @up = sort { ($b->{'since'} || 0) <=> ($a->{'since'} || 0) }
			grep { $_->{'connected'} } values %{$links};
		$gb::ble_primary_mac = @up ? $up[0]->{'mac'} : undef;
	}
	# The old scalar still means "the primary link" for the few callers that
	# have not been taught to name a MAC (and for a v1 daemon).
	$gb::ble_link_mac = $gb::ble_primary_mac;
	return $gb::ble_primary_mac;
}

sub ble_mac_for_chip {
	my ($chip_id) = @_;
	return undef unless $chip_id;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			next unless $c->{'id'} && $c->{'id'} eq $chip_id && $c->{'bluetooth'};
			return $c->{'bluetooth'};
		}
	}
	return undef;
}

# How long a Bluetooth sighting keeps an embedded device listed in the Embedded
# app after its last bridge message. A watch's radio sleeps and re-links on the
# next advert, and even awake it only talks when something changes, so this must
# outlast a quiet spell - not merely a nap. Two hours, so a watch that speaks
# rarely (a connected one says nothing for a long time) stays on the list even
# across a spell where its jawn was down; a device genuinely gone still drops.
sub embedded_operator_door {
	# The operator_door row that carries a device's current Now Me pair. It is
	# written by whichever House machine ran Now Me, with that machine's device
	# class in `device`; a computer and a phone can both serve the same watch, so
	# never filter this lookup by this machine's class - a fallback of a
	# different class would otherwise read an empty record and deny the device.
	# Rows rotate on every Now Me, so the newest is the current pair.
	my ($edt, $chip_id) = @_;
	return undef unless $edt && $chip_id;
	my $row = &subs::db_query(
		'select value from settings where app = ? and setting = ? and subsetting = ? order by server_time desc limit 1',
		$edt, 'operator_door', $chip_id
	)->hashes->[0];
	return $row ? $row->{'value'} : undef;
}

# The embedded devices' one authentication check: a watch, deck or alarmclock
# presents the rotated Now Me pair from its own operator_door row. The pair is
# the same one every route uses (edt + chip_id + authorization), and the token
# is the encrypted secret the device was last handed. This lives here, not in
# watch.pl, because the backup route is registered by Manager.pl and both
# workers must check it the same way.
sub embedded_authorizer {
	my ($c) = @_;
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $watch_settings = eval { return decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
	# Older firmware sent the token in the query; newer firmware can send it in
	# this header so it does not land in access logs or referrers.
	my $rauth = $c->req->headers->header('X-Jawn-Authorization') || $c->param('authorization') || '';
	return undef unless $edt && $rauth;
	my $remote_raw = eval { return decode_base64($rauth) } || '';
	return undef unless length $remote_raw;
	my @pairs = ( [ $watch_settings->{'__shutup'}->{'patience'}, $watch_settings->{'__specs'}->{'authorization'} ] );
	my $prev = $watch_settings->{'__shutup'}->{'previous'};
	if (ref $prev eq 'HASH' && $prev->{'patience'} && $prev->{'authorization'} && (time() - ($prev->{'at'} || 0)) <= 3600) {
		push @pairs, [ $prev->{'patience'}, $prev->{'authorization'} ];
	}
	foreach my $pair ( @pairs ) {
		my ($patience, $auth) = @{$pair};
		next unless $patience && $auth;
		# Never interpolate a request value into a shell; the old
		# `echo $rauth | base64 --decode` let a crafted authorization run a
		# command. MIME::Base64 decodes the same bytes in-process.
		my $author_raw = eval { return decode_base64($auth) } || '';
		next unless length $author_raw;
		my $authorization = &subs::note_decrypter($patience, $author_raw);
		my $remote_auth = &subs::note_decrypter($patience, $remote_raw);
		if ($remote_auth && $authorization && secure_compare $remote_auth, $authorization) {
			$watch_settings->{'__shutup'} = undef;
			return $watch_settings;
		}
	}
	return undef;
}

sub ble_device_specs {
	# A device's __specs from its operator_door (which syncs): the durable id of
	# the machine it was paired to, and the address that machine last handed it.
	# Cached briefly, as it is asked on every send.
	my ($edt, $chip_id) = @_;
	return {} unless $chip_id;
	my $key = ($edt || 'watch') . '|' . $chip_id;
	my $now = time();
	my $c = $gb::ble_specs->{$key};
	return $c->[1] if $c && $now - $c->[0] <= 5;
	my $od = &subs::embedded_operator_door($edt || 'watch', $chip_id);
	my $op_d = eval { decode_json $od } || {};
	my $specs = $op_d->{'__specs'} || {};
	$gb::ble_specs->{$key} = [ $now, $specs ];
	return $specs;
}

sub house_nodes_list {
	# The House machines an embedded device may fall back to: this machine and
	# every peer with a LAN address, each with the manager ports a device dials.
	# It rides in Now Me, so a device holds a usable list even when mDNS does not
	# answer (and on a board that cannot browse mDNS at all).
	#
	# A device only reaches its own LAN, so when a device address is given only
	# machines on that subnet are offered.
	my ($device_ip) = @_;
	my $want_net;
	if ($device_ip && $device_ip =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$/) {
		$want_net = $1;
	}
	my (%seen, @nodes);
	my $add = sub {
		my ($ip, $port, $arm, $coms, $bestow, $name, $computer) = @_;
		return unless $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
		return if $ip =~ /^127\./ || $seen{$ip}++;
		if ($want_net) {
			my $net = $ip;
			$net =~ s/\.\d+$//;
			return unless $net eq $want_net;
		}
		# The offsets are this tree's convention (main +2/+3/+4); they answer
		# for a peer whose stored network row predates the explicit fields.
		$arm ||= ($port ? $port + 2 : undef);
		$bestow ||= ($port ? $port + 3 : undef);
		$coms ||= ($port ? $port + 4 : undef);
		return unless $arm && $arm > 0;
		push @nodes, {
			ip => $ip,
			arm => $arm + 0,
			coms => ($coms || 0) + 0,
			bestow => ($bestow || 0) + 0,
			name => $name || '',
			computer => $computer || '',
		};
	};
	my $config = &subs::config_reader();
	my $local_name = $config->{'name'} || '';
	my $addrs = &subs::network_interface_reporter();
	foreach my $nic ( keys %{$addrs} ) {
		my $a = $addrs->{$nic} || {};
		$add->($a->{'ip'}, $a->{'port'}, $a->{'arm_port'}, $a->{'coms_port'}, $a->{'bestow_port'}, $local_name, &ble_manager_file());
	}
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes } ) {
		my $net = eval { decode_json $rm->{'network'} } || {};
		foreach my $nic ( keys %{$net} ) {
			my $a = $net->{$nic} || {};
			$add->($a->{'ip'}, $a->{'port'}, $a->{'arm_port'}, $a->{'coms_port'}, $a->{'bestow_port'}, $rm->{'manager_file'}, $rm->{'manager_file'});
		}
	}
	return \@nodes;
}

sub house_advertise_command {
	# The argv that publishes this machine on _jawnos-house._tcp. The embedded
	# devices browse that service when their stored homebase goes quiet; the
	# service carries the ports they dial, because the offsets are not something
	# a device should have to guess from the main port.
	my $avahi = `command -v avahi-publish-service 2>/dev/null`;
	chomp $avahi;
	$avahi ||= '/usr/bin/avahi-publish-service' if -x '/usr/bin/avahi-publish-service';
	return () unless $avahi;
	my $config = &subs::config_reader();
	my $name = $config->{'name'} || 'JawnOS';
	my $hostname = `hostname`;
	chomp $hostname;
	my $purpose = &subs::device_setter();
	my $port = $ENV{PORT_AHOY} || $config->{'working_port'} || 45545;
	my $mesh = '';
	my ($db, $database) = &subs::database_grabber();
	$mesh = $database if $database;
	$mesh =~ s{.*/}{};
	$mesh =~ s/\.db$//i;
	my @txt = (
		'purpose=' . $purpose,
		'name=' . $name,
		'hostname=' . $hostname,
		'version=1',
		'mesh=' . $mesh,
	);
	# The stable identity, so an mDNS browser can match this advertisement to the
	# peer's remote_machines row instead of guessing from a hostname.
	push @txt, 'signatorial=' . &subs::signatorial_designer();
	push @txt, 'arm=' . $ENV{PORT_ARM} if $ENV{PORT_ARM};
	push @txt, 'coms=' . $ENV{PORT_COMS} if $ENV{PORT_COMS};
	push @txt, 'bestow=' . $ENV{PORT_BESTOW} if $ENV{PORT_BESTOW};
	push @txt, 'dock=' . $ENV{PORT_DOCK} if $ENV{PORT_DOCK};
	my $computer = eval { &Manager::manager_file_maker() };
	push @txt, 'computer=' . $computer if $computer;
	# The instance name is what a person sees in an mDNS browser; Avahi adds a
	# #2 itself if two machines share a name.
	return ($avahi, '--no-reverse', '-s', 'JawnOS ' . $name . ' (' . $hostname . ')', '_jawnos-house._tcp', $port, @txt);
}

sub house_advertise_supervise {
	# Keep the publisher up for as long as this tree lives. A nested fork/exec is
	# used rather than a shell background job so the avahi child dies with the
	# supervisor (and the supervisor with President).
	my $ppid = getppid();
	while ( getppid() == $ppid ) {
		my @cmd = &house_advertise_command();
		return unless @cmd;
		my $pid = fork();
		if (!defined $pid) { sleep 10; next; }
		if (!$pid) { exec @cmd; exit 1; }
		local $SIG{TERM} = sub { kill 'TERM', $pid; exit 0; };
		waitpid($pid, 0);
		sleep 15;
	}
}

sub ble_manager_file {
	# This machine's durable id, the same string a device's record names as its
	# "computer". Cached: manager_file_maker reads the database.
	my $now = time();
	return $gb::ble_mf->[1] if $gb::ble_mf && $now - $gb::ble_mf->[0] <= 10;
	my $mf = eval { &Manager::manager_file_maker() } || '';
	$gb::ble_mf = [ $now, $mf ];
	return $mf;
}

sub ble_machine_match {
	# A machine's durable id is '<who>@<mesh>.<computer>' (manager_file_maker).
	# The <mesh> segment is the database's base name, so renaming the database
	# (initial -> jawnos) silently retires every stored id: a device's record then
	# names a machine no row holds, ble_owns stops recognizing its own homebase, and
	# ble_homebase_alive treats the phantom as alive forever - so the real homebase
	# yields the device and nobody ever bridges it. Match on the parts that survive
	# a rename (the person and the computer name), so a rename does not strand a
	# device on a machine that is sitting right next to it.
	my ($a, $b) = @_;
	return 0 unless defined $a && defined $b && length $a && length $b;
	return 1 if $a eq $b;
	my ($aw, $amesh) = split /\@/, $a, 2;
	my ($bw, $bmesh) = split /\@/, $b, 2;
	return 0 unless defined $amesh && defined $bmesh;
	$amesh =~ s/^.*\.//;
	$bmesh =~ s/^.*\.//;
	return ($aw eq $bw && $amesh eq $bmesh) ? 1 : 0;
}

sub ble_owns {
	# Is this machine the device's homebase - the machine the person paired it
	# to? A watch is a one-link peripheral, so only the homebase should hold its
	# link. The pairing is recorded by the machine's durable id, not by an address,
	# so it survives that machine changing network - the address form is only a
	# fallback for older records. A device nobody has placed is ours.
	my ($edt, $chip_id) = @_;
	my $specs = &ble_device_specs($edt, $chip_id);
	my $who = $specs->{'computer'};
	if ($who) {
		my $mine = &ble_manager_file();
		return 0 unless $mine;
		# compare past a database rename, or a stale id makes the device look
		# like it belongs to a machine that no longer exists
		return &ble_machine_match($who, $mine) ? 1 : 0;
	}
	my $home = $specs->{'homebase'};
	return 1 unless $home;
	$home =~ s/:\d+$//;
	# Cache this machine's addresses for a moment: this runs on every send, and a
	# toggle fan-out asks once per watch.
	my $now = time();
	unless ($gb::ble_mine_ips && $now - ($gb::ble_mine_ips_at || 0) <= 5) {
		my $addrs = &subs::network_interface_reporter();
		$gb::ble_mine_ips = { map { ($addrs->{$_}->{'ip'} || '') => 1 } keys %{$addrs} };
		$gb::ble_mine_ips_at = $now;
	}
	return $gb::ble_mine_ips->{$home} ? 1 : 0;
}

sub ble_fallback_grace {
	# How long a device's homebase may be off the mesh before another machine
	# takes its watch over. The person wants the watch to stay on the machine it
	# was paired to, so the takeover must outlast a homebase that merely left the
	# LAN - a phone on cellular, a wifi roam, a machine that syncs in bursts. The
	# old ten-minute window grabbed the watch on every blink, which was the
	# tug-of-war the person saw between the phone and the laptop/tablet. Long
	# enough that only a homebase genuinely gone hands it over.
	return 900000;
}

sub ble_fallback_stop_grace {
	# A homebase that stopped on purpose - it marked itself, or the mesh marked it,
	# inactive - is gone now, not merely off the LAN: its jawn is down, so waiting
	# the full grace just strands the watch. A restart flips the row back to active
	# within seconds, so this short wait rides that out without handing the watch
	# over on a blip.
	return 180000;
}

sub ble_homebase_sighting {
	# The device's homebase as the mesh last knew it: the newest of its peer rows
	# (server_time) and whether that row was active. Held as a high-water mark per
	# (homebase, chip): the row flickers - a sync gap briefly serves a stale copy -
	# and a single stale read must not make a live homebase look gone, because that
	# flip is what let a second machine connect and steal the link. Keyed by the
	# homebase id, so a re-home to a fresh machine starts from its own row. undef
	# means no row names the machine, which the caller reads as alive.
	my ($edt, $chip_id) = @_;
	my $who = &ble_device_specs($edt, $chip_id)->{'computer'};
	return undef unless $who;
	my $key = $who . '|' . ($edt || 'watch') . '|' . $chip_id;
	my ($seen, $active);
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes } ) {
		next unless &ble_machine_match($rm->{'manager_file'}, $who);
		my $t = ($rm->{'server_time'} || 0) + 0;
		next unless $t;
		if (!defined $seen || $t > $seen) {
			$seen = $t;
			$active = (($rm->{'connection'} || '') eq 'active') ? 1 : 0;
		}
	}
	return undef unless defined $seen;
	my $c = $gb::ble_hb_seen->{$key};
	$gb::ble_hb_seen->{$key} = [ $seen, $active ] if !$c || $seen > $c->[0];
	return $gb::ble_hb_seen->{$key};
}

sub ble_homebase_alive {
	# Has the machine the device was paired to been gone long enough to stop
	# waiting for it? Its own peer row is the authority - not a ping of the address
	# it last had, which was wrong the moment that machine left the LAN (a phone on
	# cellular). A sighting counts until it is older than the grace: a deliberate
	# stop waits the short one, a homebase merely off the LAN (still marked active)
	# the long one. A record that names no machine, or names one we hold no
	# sighting for, is assumed alive, so we never usurp a homebase we cannot judge.
	my ($edt, $chip_id) = @_;
	return 1 unless &ble_device_specs($edt, $chip_id)->{'computer'};
	my $seen = &ble_homebase_sighting($edt, $chip_id);
	return 1 unless defined $seen;
	my $grace = $seen->[1] ? &ble_fallback_grace() : &ble_fallback_stop_grace();
	return ((&subs::rightNow() - $seen->[0]) < $grace) ? 1 : 0;
}

sub ble_may_serve {
	# May this machine hold/serve the device's link right now? Its homebase may,
	# always: the watch stays on the machine it was paired to for as long as that
	# machine is on the mesh, which is what the person asked for. Only when the
	# homebase has dropped off the mesh may another machine take the watch over,
	# so a dead phone does not strand it. That machine serves WITHOUT re-homing,
	# so the stored pairing is untouched and the phone reclaims the watch the
	# moment its row comes back.
	my ($edt, $chip_id) = @_;
	return 1 if &ble_owns($edt, $chip_id);
	return 0 if &ble_homebase_alive($edt, $chip_id);
	return 1;
}

sub ble_chip_by_mac {
	# The chip a radio address belongs to, from the sightings every machine
	# keeps; used to name the device the bridge just linked to.
	my ($mac) = @_;
	return undef unless $mac;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			return $c if $c->{'bluetooth'} && &ble_link_key($c->{'bluetooth'}) eq &ble_link_key($mac);
		}
	}
	return undef;
}

sub ble_chip_record {
	# A chip id -> its fleet record (purpose, radio address, name), from any
	# machine's devices row. The relay router needs the purpose to apply the
	# same homebase rule as an ordinary send.
	my ($chip_id) = @_;
	return undef unless $chip_id;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			next unless $c->{'id'} && $c->{'id'} eq $chip_id;
			return { %{$c}, hostname => $d->{'hostname'} };
		}
	}
	return undef;
}

sub ble_relay_route {
	# Carry one device's message to another device (star-of-stars mesh).
	#
	# A watch on a phone's bridge can reach a board on the desktop's bridge: the
	# machine that heard the relay looks up the target, sends it over its own
	# bridge when it may serve that chip, and otherwise hands the same envelope to
	# every active peer. Only the machine allowed to serve the target sends it, so
	# the broadcast needs no homebase lookup and no reply.
	#
	# Envelope: {type:"relay", to:"<chip>", from:"<chip>", id:"<unique>",
	#            hops:N, message:{...}}
	# Loop protection is the message id plus a small hop budget.
	my ($relay, $opts) = @_;
	$opts ||= {};
	return 0 unless ref $relay eq 'HASH' && ($relay->{'type'} || '') eq 'relay';
	my $to = $relay->{'to'};
	my $inner = $relay->{'message'};
	return 0 unless $to && ref $inner eq 'HASH';
	my $hops = 0 + ($relay->{'hops'} || 0);
	return 0 if $hops > 6;
	my $id = $relay->{'id'} || &random_string_creator(18);
	my $now = time();
	foreach my $seen ( keys %{ $gb::ble_relay_seen || {} } ) {
		delete $gb::ble_relay_seen->{$seen} if $now - $gb::ble_relay_seen->{$seen} > 300;
	}
	return 0 if $gb::ble_relay_seen->{$id};
	$gb::ble_relay_seen->{$id} = $now;
	my $from = $relay->{'from'} || '';
	# addressed back to the sender: a loop, not a delivery
	return 0 if $from && $to eq $from;
	my $chip = &ble_chip_record($to);
	return 0 unless $chip && $chip->{'id'};
	my $edt = $chip->{'purpose'} || 'watch';
	my $envelope = {
		type => 'relay',
		from => $from,
		id => $id,
		hops => $hops + 1,
		message => $inner
	};
	if (&ble_may_serve($edt, $to) && $chip->{'bluetooth'}) {
		$log->info('BLE relay ' . ($from || '?') . ' -> ' . $to . ' (' . $edt . '), hop ' . ($hops + 1));
		&bluetooth_sender_async({
			intent => 'com.jawn.president.bt.connect',
			chip_id => $to,
			edt => $edt,
			message => $envelope
		});
		return 1;
	}
	return 0 if $opts->{'from_mesh'};
	my $me = &signatorial_designer();
	my $payload = encode_json({ %{$envelope}, to => $to });
	my $sent = 0;
	foreach my $rm ( @{ &remote_machine_lister({ connection => 'active' }) || [] } ) {
		next unless ref $rm eq 'HASH';
		my $sig = $rm->{'signatorial'} || '';
		next if !$sig || $sig eq $me;
		next unless $rm->{'ip'};
		my $hop = &subs::remote_useragent_maker({ rm => $rm, signatorial => $sig });
		next unless $hop && $hop->{'ua'} && $hop->{'manager'};
		my $res = eval {
			$hop->{'ua'}->insecure(1)->inactivity_timeout(10)->post(
				$hop->{'manager'} . '/manager/ble/relay' => form => { payload => $payload }
			)->result;
		};
		$sent++ if $res && eval { $res->is_success };
	}
	$log->info('BLE relay ' . ($from || '?') . ' -> ' . $to . ': offered to ' . $sent . ' peer(s)') if $sent;
	return $sent ? 1 : 0;
}

sub ble_yield {
	# Hand a device that calls another machine home back to it: drop that
	# device's link so the homebase's bridge can take it. With several links in
	# one bridge the yield must name the radio - disconnecting the whole bridge
	# would drop a deck or board this machine is allowed to serve. Rate-limited
	# per chip, and run off the read loop so a flapping bridge cannot stall the
	# listener.
	my ($chip_id, $mac) = @_;
	return unless $chip_id;
	$mac ||= &ble_mac_for_chip($chip_id);
	my $now = &subs::rightNow();
	return if $gb::ble_yield_at->{$chip_id} && $now - $gb::ble_yield_at->{$chip_id} < 30000;
	$gb::ble_yield_at->{$chip_id} = $now;
	my $client = &ble_bridge_client();
	return unless $client;
	# If a MAC is named, make sure it really is this chip's radio before
	# releasing it; an unknown address must not take another link down.
	if ($mac) {
		my $linked = &ble_chip_by_mac($mac);
		return if $linked && $linked->{'id'} && $linked->{'id'} ne $chip_id;
	}
	$log->info('BLE yield ' . $chip_id . ($mac ? ' (' . $mac . ')' : '') . ': not its homebase, releasing that link');
	&subs::subprocessor(sub {
		if ($mac) { system($^X, $client, 'disconnect', $mac); }
		else { system($^X, $client, 'disconnect', '--all'); }
	}, { name => 'ble yield' });
}

1;
