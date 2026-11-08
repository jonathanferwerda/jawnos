package subs;

# Ble: extracted from subroutines.pl (package subs). Loaded on
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

our %H;
our $device;
our $gb;
our $log;

sub ble_enforce_hosts {
	# Keep every machine on the right side of every link. The bridge daemons now
	# hold several radios at once (v2), so this pass is per device: connect the
	# ones this machine may serve, release the ones it may not, and leave a link
	# the daemon is already chasing alone. A v1 daemon still works - it accepts
	# the first connect and ignores the rest; its status reports one link.
	#   may serve  -> make sure that radio's link is up (connect; a no-op if it is)
	#   may not    -> release that radio and stop chasing it
	return unless &ble_bridge_capable() && &ble_bridge_enabled();
	my $client = &ble_bridge_client() || return;
	my $links = &ble_links();
	my %done;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			next unless $c->{'id'} && $c->{'bluetooth'};
			next if $done{ $c->{'id'} }++;
			my $mac = &ble_link_key($c->{'bluetooth'});
			my $edt = $c->{'purpose'} || 'watch';
			my $link = $links->{$mac};
			if (&ble_may_serve($edt, $c->{'id'})) {
				next if $link && $link->{'connected'};
				# the daemon is already reconnecting this radio; do not issue a
				# second connect every minute and reset its backoff
				next if $link && ($link->{'state'} || '') =~ /^(?:connecting|reconnecting)$/;
				my $now = time();
				next if $gb::ble_connect_at->{$mac} && $now - $gb::ble_connect_at->{$mac} < 60;
				$gb::ble_connect_at->{$mac} = $now;
				my $u = &ble_nus_uuids();
				# Always name the service and characteristics. A bare connect
				# overwrites the daemon's stored target, and the Android bridge keeps
				# only mac+mtu from it: with no uuids saved it can no longer find the
				# watch's characteristics and the link fails forever (this is what
				# made the phone bounce). So never connect without them.
				# A board's role payload is plain JSON; only the watch/deck get the
				# compressed room pushes.
				my $compress = ($edt eq 'microcontroller') ? '0' : '1';
				&subs::subprocessor(sub {
					system($^X, $client, 'connect', $mac,
						'--service', $u->{'service_uuid'},
						'--rx', $u->{'characteristic_uuid_rx'},
						'--tx', $u->{'characteristic_uuid_tx'},
						'--mtu', '512',
						'--compress', $compress);
				}, { name => 'ble host connect' });
			}
			elsif ($link && $link->{'connected'}) {
				&ble_yield($c->{'id'}, $mac);
			}
		}
	}
	# A radio linked right now is present, whatever its last payload said: a
	# watch speaks only on connect and on steps, so its own messages can be hours
	# apart and its sighting would age out of the Embedded list while it sits
	# connected. Refresh every link this machine may serve.
	foreach my $mac ( keys %{$links} ) {
		next unless $links->{$mac} && $links->{$mac}->{'connected'};
		my $linked = &ble_chip_by_mac($mac);
		next unless $linked && $linked->{'id'};
		next unless &ble_may_serve($linked->{'purpose'} || 'watch', $linked->{'id'});
		&ble_device_record({
			chip_id => $linked->{'id'},
			edt => $linked->{'purpose'} || 'watch',
			name => $linked->{'name'},
			mac => $mac
		});
	}
}

sub ble_adopt_scan {
	# A device that has never been on WiFi cannot be named by mDNS and the tree
	# holds no address for it, so nothing ever connects and it can never introduce
	# itself - a fresh deck is invisible however long it sits on the desk. Find it
	# by radio instead. A JawnOS device carries a "JW" manufacturer-data payload
	# (company 0xFFFF) with its chip id and purpose, so it is recognized even when
	# it advertises a custom service; older firmware is still met by its Nordic
	# UART service uuid. Connect to it and its own state_request records it
	# (ble_message_processor -> ble_device_record), after which the ordinary host
	# rule bridges it - the "plug it in and it is known" path, with no wifi at all.
	# With the multi-link bridge, every unknown JawnOS device in the room is met,
	# not just the first; the daemon's MAX_LINKS cap is the limit.
	return unless &ble_bridge_capable() && &ble_bridge_enabled();
	my $client = &ble_bridge_client() or return;
	my $nus = lc &ble_nus_uuids()->{'service_uuid'};
	# every Bluetooth address we already hold, so only the unknown is chased
	my %known;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		foreach my $c ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
			$known{ &ble_link_key($c->{'bluetooth'}) } = 1 if $c->{'bluetooth'};
		}
	}
	# The command is built, then run: a function call written inside backticks is a
	# literal, not a call, so the shell received the text '&shell_quote(...)' and
	# failed with "syntax error near unexpected token" - the scan never ran on a
	# machine with a Bluetooth bridge, so a fresh board on the desk was never
	# discovered and could not introduce itself.
	my $scan = 'timeout 25 ' . &shell_quote($^X) . ' ' . &shell_quote($client) . ' scan 8 2>/dev/null';
	my $out = `$scan`;
	my @found;
	my %seen;
	foreach my $line (split "\n", $out) {
		my $e = eval { decode_json $line };
		next unless $e && ref $e eq 'HASH' && ($e->{'event'} || '') eq 'scan';
		my $mac = &ble_link_key($e->{'mac'});
		next unless $mac =~ /^(?:[0-9A-F]{2}){6}$/;
		# The device names itself in the scan response: record the sighting now,
		# even before a link exists, and note the radio address it currently uses
		# (a board that was re-flashed may come back on a new address).
		my ($mf_chip, $mf_purpose) = &ble_manufacturer_identity($e->{'manufacturer_data'});
		if ($mf_chip) {
			next if $seen{$mac}++;
			# Only write the sighting when the radio address is new (a re-flashed
			# board may come back on a different one). Otherwise this scan would
			# rewrite every known device's row every 30 seconds and churn the mesh
			# sync for nothing.
			my $recorded = &ble_chip_record($mf_chip);
			my $same_mac = $recorded && $recorded->{'bluetooth'} &&
				&ble_link_key($recorded->{'bluetooth'}) eq $mac;
			&ble_device_record({ chip_id => $mf_chip, edt => $mf_purpose, mac => $mac }) unless $same_mac;
			# Meet it only when this machine may hold its link. A device whose
			# homebase is another machine is left for that homebase (adopting it
			# here would steal the link, which is the tug-of-war the homebase rule
			# exists to prevent).
			my $edt = $mf_purpose || ($recorded && $recorded->{'purpose'}) || 'watch';
			push @found, { mac => $mac, chip_id => $mf_chip, purpose => $edt } if &ble_may_serve($edt, $mf_chip);
			next;
		}
		next if $known{$mac} || $seen{$mac}++;
		next unless grep { lc($_) eq $nus } @{ $e->{'uuids'} || [] };
		push @found, { mac => $mac };
	}
	return unless @found;
	my $now = time();
	my $u = &ble_nus_uuids();
	foreach my $f ( @found ) {
		my $mac = ref $f eq 'HASH' ? $f->{'mac'} : $f;
		# already linked, or we tried it recently and it stayed silent (a device
		# that speaks NUS but is not ours): leave that radio alone
		next if $gb::ble_links->{$mac} && $gb::ble_links->{$mac}->{'connected'};
		next if $gb::ble_adopt_tried->{$mac} && $now - $gb::ble_adopt_tried->{$mac} < 600;
		$gb::ble_adopt_tried->{$mac} = $now;
		$log->info('BLE adopt: a JawnOS device at ' . $mac . ' is not yet known; connecting so it can name itself');
		&subs::subprocessor(sub {
			system($^X, $client, 'connect', $mac,
				'--service', $u->{'service_uuid'},
				'--rx', $u->{'characteristic_uuid_rx'},
				'--tx', $u->{'characteristic_uuid_tx'},
				'--mtu', '512');
		}, { name => 'ble adopt connect' });
	}
}

sub ble_manufacturer_identity {
	# Read the JawnOS manufacturer-data payload from a scan event.
	#
	# Layout (after the 2-byte company id, 0xFFFF):
	#   "JW"  version  flags  purpose  chip_id-as-ASCII
	# purpose: 1 watch, 2 teletype, 3 microcontroller, 4 music, 0 unknown.
	# flags bit0 marks a device that can relay for the mesh.
	# Returns (chip_id, purpose) or () when this is not one of ours.
	my ($mfd) = @_;
	return () unless ref $mfd eq 'HASH';
	my %purpose = (1 => 'watch', 2 => 'teletype', 3 => 'microcontroller', 4 => 'music');
	foreach my $company ( keys %{$mfd} ) {
		my $hex = $mfd->{$company};
		next unless defined $hex;
		$hex =~ s/[^0-9a-fA-F]//g;
		next unless length($hex) >= 12;   # magic+version+flags+purpose + 1 byte chip
		my $raw = pack('H*', substr($hex, 0, length($hex) - (length($hex) % 2)));
		next unless substr($raw, 0, 2) eq 'JW';
		next unless ord(substr($raw, 2, 1)) == 1;
		my $code = ord(substr($raw, 4, 1));
		my $chip = substr($raw, 5);
		$chip =~ s/[^A-Za-z0-9._-]//g;
		next unless length $chip;
		return ($chip, $purpose{$code} || 'watch');
	}
	return ();
}

sub ble_nus_uuids {
	# The Nordic UART service the watch and boards advertise (see jw/jw.ino). A
	# device recorded only over Bluetooth never answered a /device_query with its
	# own constants, so its bridge link is opened with these fixed defaults.
	return {
		service_uuid           => '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
		characteristic_uuid_rx => '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
		characteristic_uuid_tx => '6e400003-b5a3-f393-e0a9-e50e24dcca9e'
	};
}

sub ble_device_record {
	# Remember an embedded device seen over the Bluetooth bridge, so it can be
	# listed in the Embedded app while it is off its access point. The sighting
	# lives in this machine's own `devices` row - the chip_ids blob device_scan
	# already keeps and syncs - so an entry added here outlives the next scan
	# (its oldchips merge keeps it) and reaches the other machines with the row.
	my $data = shift;
	my $chip_id = $data->{'chip_id'} || return;
	my $edt = $data->{'edt'} || 'watch';
	my $now = &subs::rightNow();
	my $hostname = $gb::ble_hostname;
	unless ($hostname) {
		$hostname = `hostname`;
		chomp $hostname;
		$gb::ble_hostname = $hostname;
	}
	my $row;
	foreach my $r ( @{ &subs::db_select('devices')->hashes } ) {
		my $h = $r->{'hostname'} || '';
		$h =~ s/\s+$//;
		if ($h eq $hostname) { $row = $r; last; }
	}
	my $chips = ($row && $row->{'chip_ids'}) ? (eval { decode_json $row->{'chip_ids'} } || []) : [];
	my $found;
	foreach my $c ( @{$chips} ) {
		next unless $c->{'id'} && $c->{'id'} eq $chip_id;
		$found = $c;
		last;
	}
	unless ($found) {
		$found = { id => $chip_id };
		push @{$chips}, $found;
	}
	my $name = $data->{'name'};
	if (!$name && !($found && $found->{'name'})) {
		my $od = &subs::embedded_operator_door($edt, $chip_id);
		my $op_d = eval { decode_json $od } || {};
		$name = $op_d->{'__specs'}->{'name'};
	}
	$found->{'name'} = $name if $name;
	$found->{'purpose'} = $edt;
	$found->{'bluetooth'} = $data->{'mac'} if $data->{'mac'};
	# The board's own state_request carries the address it just got. Keep it on
	# the sighting so the relay can use the LAN route without waiting for a
	# bridge connect; a board off WiFi reports 0.0.0.0, which clears it again.
	if (defined $data->{'ip'}) {
		if ($data->{'ip'} =~ /^\d{1,3}(?:\.\d{1,3}){3}$/ && $data->{'ip'} ne '0.0.0.0') {
			$found->{'ip'} = $data->{'ip'};
		}
		else {
			delete $found->{'ip'};
		}
	}
	# The build the device reports (see Domain::Firmware). A version is a token,
	# not free text: refuse anything that is not shaped like one.
	if (defined $data->{'version'} && $data->{'version'} =~ /^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$/) {
		$found->{'version'} = $data->{'version'};
		$found->{'version_seen'} = $now;
	}
	$found->{'ble'} = 1;
	$found->{'ble_seen'} = $now;
	$found->{'server_time'} = $now;
	my $json = encode_json $chips;
	if ($row) {
		&subs::db_update('devices', { chip_ids => $json }, { hostname => $row->{'hostname'} });
	}
	else {
		# A machine that never ran a scan still has to carry the sighting, or a
		# Bluetooth-only fleet could not be listed at all.
		&subs::db_insert('devices', {
			hostname => $hostname,
			address => '{}',
			chip_ids => $json,
			server_time => $now,
			timestamp => $now,
			uuid => &subs::random_string_creator(25)
		});
	}
	return $found;
}

# --- BLE battery -------------------------------------------------------------
# The bridge can ask a linked board for its pack; the board answers on the same
# NUS link. The reply is cached per chip, and the levels scan merges it with the
# HTTP reading, so a board whose WiFi is asleep still appears. A board linked to
# a phone is relayed by that phone's levels response, the same as any embedded
# board it can see.
sub ble_battery_note {
	my $data = shift || {};
	my $chip = $data->{'chip_id'} || '';
	return unless $chip;
	my $cache = &cache_get({ app => '__president', context => 'levels', subcontext => 'ble' });
	$cache = {} unless ref $cache eq 'HASH';
	$cache->{$chip} = {
		chip_id => $chip,
		edt => $data->{'edt'} || 'watch',
		battery => (defined $data->{'battery'} ? $data->{'battery'} + 0 : undef),
		battery_mv => (defined $data->{'battery_mv'} ? $data->{'battery_mv'} + 0 : undef),
		status => lc($data->{'battery_status'} || ''),
		mac => $data->{'mac'} || '',
		seen => &rightNow(),
	};
	&cache_set({ app => '__president', context => 'levels', subcontext => 'ble', warranty => '-1d' }, $cache);
}

sub ble_battery_poll {
	return unless &ble_bridge_capable() && &ble_bridge_enabled();
	my $links = &ble_links();
	return unless %{$links};
	# Both shapes a sighting can take: the bridge's chip_ids blob, and a
	# neighbour entry that carries the radio address beside its IP.
	my %want;
	foreach my $row ( @{ &db_select('devices')->hashes || [] } ) {
		foreach my $c ( @{ (eval { decode_json($row->{'chip_ids'} || '[]') } || []) } ) {
			next unless $c->{'id'} && $c->{'bluetooth'};
			$want{$c->{'id'}} ||= { id => $c->{'id'}, edt => $c->{'purpose'} || 'watch', mac => $c->{'bluetooth'} };
		}
		my $address = eval { decode_json($row->{'address'} || '{}') } || {};
		foreach my $nic ( keys %{$address} ) {
			foreach my $n ( @{ $address->{$nic}->{'neigh'} || [] } ) {
				my $chip = $n->{'chip_id'} || '';
				my $bt = $n->{'mac_addresses'}->{'bluetooth'} || '';
				next unless $chip && $bt;
				$want{$chip} ||= { id => $chip, edt => $n->{'purpose'} || 'watch', mac => $bt };
			}
		}
	}
	foreach my $w ( values %want ) {
		# Only an already-live link: a poll must never wake or connect a board
		# just to read its battery (or steal it from its homebase).
		my $link = $links->{ &ble_link_key($w->{'mac'}) };
		next unless $link && $link->{'connected'};
		next unless &ble_may_serve($w->{'edt'}, $w->{'id'});
		# A poll is a nudge, never worth holding the loop for: a watch that slept
		# suspends its link, and the client would wait out the supervision timeout.
		&bluetooth_sender_async({
			intent => 'com.jawn.president.bt.connect',
			chip_id => $w->{'id'},
			edt => $w->{'edt'},
			message => { type => 'battery', chip_id => $w->{'id'}, edt => $w->{'edt'} },
		});
	}
}

sub ble_device_from_chip {
	# Build the device row device_lister hands its callers, from a chip the
	# bridge saw. It carries what the Embedded panel and a Now Me need: the
	# Bluetooth address to reach it, the link's fixed service uuids, and this
	# machine as the homebase (the watch has no address of its own off its LAN).
	my ($chip, $load_type) = @_;
	my $addrs = &subs::network_interface_reporter();
	my ($my_ip) = map { $addrs->{$_}->{'ip'} }
		grep { $addrs->{$_}->{'ip'} && $addrs->{$_}->{'ip'} !~ /^127\./ } keys %{$addrs};
	$my_ip ||= '127.0.0.1';
	my $dev = {
		chip_id => $chip->{'id'},
		name => $chip->{'name'},
		purpose => $chip->{'purpose'} || $load_type,
		edt => $chip->{'purpose'} || $load_type,
		ble => 1,
		# A Bluetooth-only device has no address of its own; one that names its
		# LAN address in state_request keeps it here, so the relay can take the
		# HTTP route instead of a bridge connect. Homebase still names this
		# machine, where the bridge lives.
		ip => ($chip->{'ip'} || ''),
		version => ($chip->{'version'} || ''),
		version_seen => ($chip->{'version_seen'} || 0),
		homebase => $my_ip,
		mac => $chip->{'bluetooth'},
		mac_addresses => { bluetooth => $chip->{'bluetooth'} },
		%{ &ble_nus_uuids() }
	};
	return $dev;
}

sub embedded_device {
	# One embedded device, by chip, for a caller that will dereference the answer
	# as a hash. device_lister answers with this machine's whole device list when
	# the chip is not among the devices it can reach *now* - its only sighting is
	# older than the presence window (the bridge was down, or it is another
	# machine's homebase), so the neighbour tables know nothing about it. Now Me
	# and the pin editor dereferenced that list as a hash and died on the spot
	# ("Not a HASH reference"), which the panel showed as a red dot.
	#
	# Fall back to the recorded chip: it still carries the radio address the
	# bridge needs, and ble_device_from_chip builds the same device row the
	# sighting branch would. An empty hash means the chip is not recorded at all;
	# the caller checks for that before using the device.
	my ($timestamp, $edt, $chip_id) = @_;
	my $dev = &device_lister($timestamp, $edt, undef, $chip_id);
	return $dev if ref $dev eq 'HASH';
	if ($chip_id) {
		my $chip = &ble_chip_record($chip_id);
		if ($chip && ref $chip eq 'HASH') {
			my $fallback = &ble_device_from_chip($chip, $edt);
			return $fallback if ref $fallback eq 'HASH';
		}
	}
	return {};
}

# The Bluetooth devices the bridge has seen, for the Dev panel. A BLE-only device
# off its access point is in no machine's neighbour table, so the network listing
# never shows it; the bridge records each sighting in a machine's `chip_ids`
# (ble_device_record), which device_lister already falls back to for the Embedded
# app. Same source here: one row per chip, the freshest sighting, and only while
# the presence window still holds - so a headless hub (or any machine with no
# browser scan) still lists the fleet's radios.
sub ble_device_listing {
	my $window = &ble_presence_window();
	my $now = &subs::rightNow();
	my %seen;
	foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
		next unless $d->{'chip_ids'};
		my $chips = eval { decode_json $d->{'chip_ids'} } || [];
		foreach my $c ( @{$chips} ) {
			next unless $c->{'id'} && ($c->{'ble'} || $c->{'bluetooth'});
			next unless $window > $now - ($c->{'ble_seen'} || 0);
			my $id = $c->{'id'};
			next if $seen{$id} && ($seen{$id}->{'ble_seen'} || 0) >= ($c->{'ble_seen'} || 0);
			$seen{$id} = { %{$c}, hostname => $d->{'hostname'} };
		}
	}
	my @rows = map {
		my $c = $seen{$_};
		$c->{'seen_display'} = &subs::formatted_time($c->{'ble_seen'}) if $c->{'ble_seen'};
		$c;
	} keys %seen;
	return [ sort { ($a->{'name'} || $a->{'id'}) cmp ($b->{'name'} || $b->{'id'}) } @rows ];
}

sub bluetooth_sender {
	my $data = shift;
	return unless $data->{'intent'} && $data->{'chip_id'} && $data->{'edt'} && &subs::ble_bridge_capable();
	# Only the device's homebase may drive the bridge - or, once the homebase has
	# gone quiet past the grace, a machine taking it over. Another machine
	# connecting would steal the single link (and the person's taps with it). This
	# is also what stops every machine answering a toggle-changed broadcast with
	# its own connect.
	return unless &ble_may_serve($data->{'edt'}, $data->{'chip_id'});
	my $intent = $data->{'intent'};
	my $message = $data->{'message'};
	# Resolve through embedded_device, not the plain listing: a board off its
	# WiFi has a sighting older than the presence window, and device_lister then
	# answers with the whole device array instead of the one device. Its recorded
	# radio address is still the only way to reach it - the connect attempt is
	# the probe, and it is what provisions a board that has no network yet.
	my $embedded = &subs::embedded_device(&subs::rightNow(), $data->{'edt'}, $data->{'chip_id'});
	# The link's service and characteristics: use what the device record carries,
	# but fall back to the Nordic UART uuids the watch and boards advertise, so a
	# connect is never issued without them (a bare one clears the daemon's saved
	# target, and then its link can never be found again).
	my $ble_uuids = &ble_nus_uuids();
	my $service_uuid = $embedded->{'service_uuid'} || $ble_uuids->{'service_uuid'};
	my $characteristic_uuid_rx = $embedded->{'characteristic_uuid_rx'} || $ble_uuids->{'characteristic_uuid_rx'};
	my $characteristic_uuid_tx = $embedded->{'characteristic_uuid_tx'} || $ble_uuids->{'characteristic_uuid_tx'};
	if ($embedded->{'mac_addresses'}->{'bluetooth'}) {
		my $bt_mac = $embedded->{'mac_addresses'}->{'bluetooth'};
		my $name = $embedded->{'name'};
		my $json = encode_json $message;
		my $client = &ble_bridge_client();
		if (&ble_bridge_enabled() && $client) {
			# Ask for this MAC's link, not "the" link. The daemons hold several now;
			# the connect is a no-op when that radio is already up and only that
			# radio is retargeted otherwise. A board's role payload is plain JSON
			# (compress 0); the watch and deck keep the compressed room pushes.
			my $link = $gb::ble_links->{ &ble_link_key($bt_mac) };
			my $compress = (($data->{'edt'} || '') eq 'microcontroller') ? '0' : '1';
			unless ($link && $link->{'connected'}) {
				system($^X, $client, 'connect', $bt_mac, '--service', $service_uuid, '--rx', $characteristic_uuid_rx, '--tx', $characteristic_uuid_tx, '--mtu', '512', '--compress', $compress);
			}
			# The client hands the JSON to the daemon as-is and the daemon writes
			# it to the selected radio. Base64 is only for the old broadcast path;
			# the client used to receive the encoded copy and the watch got a
			# base64 blob it could not parse.
			open(my $bt_fh, '|-', $^X, $client, 'send', '--mac', $bt_mac) or return;
			# The client can now refuse a dead link and exit before it reads this
			# (a watch that has suspended its radio), so a plain print here would
			# die of SIGPIPE and take the process with it.
			{
				local $SIG{'PIPE'} = 'IGNORE';
				print {$bt_fh} $json;
			}
			return close $bt_fh;
		}
		my $b64 = encode_base64 $json;
		my $cmd = "am broadcast --user 0 -a $intent -e mac_address '$bt_mac' -e message '$b64' -e name '$name' -e service_uuid '$service_uuid' -e characteristic_uuid_rx '$characteristic_uuid_rx' -e characteristic_uuid_tx '$characteristic_uuid_tx'";
		return `$cmd`;
	}
}

# A send that must not hold the caller's event loop. bluetooth_sender waits for
# the radio to acknowledge the write; a watch that has gone to sleep suspends its
# link without saying so, and nothing comes back until Android's link supervision
# timeout, tens of seconds later. Run inline that wait is the whole manager
# frozen - the bridge listener's reader, a recurring timer, a request handler -
# and every later message queues behind it, so the freeze repeats. The homebase
# checks are cheap; the client and its wait ride a child instead.
sub bluetooth_sender_async {
	my ($data, $opts) = @_;
	$opts ||= {};
	return 0 unless $data && $data->{'intent'} && $data->{'chip_id'} && $data->{'edt'};
	# Already in a child forked for this work: send inline, so this message keeps
	# its place in that child's run of messages (the words before the audio).
	# A caller that passes `fork` wants no such order: a best-effort reply (a
	# volume_result) must not sit on the BLE listener's read loop for the send
	# timeout, because every tap behind it waits for the same link.
	if ($gb::subprocessed && !$opts->{'fork'}) {
		eval { &bluetooth_sender($data) };
		return 1;
	}
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		eval { &bluetooth_sender($data) };
		$log->error('ble send failed: ' . ($@ =~ s/\s+/ /gr)) if $@ && $log;
	}, { name => 'ble send', fork => 1 });
	return 1;
}

sub ble_push_available {
	# The cheap half of bluetooth_sender's checks, so a caller can choose the
	# bridge (and hand it to bluetooth_sender_async) without running the client on
	# its own event loop just to learn whether the device is ours to serve.
	my ($edt, $chip_id) = @_;
	return 0 unless $edt && $chip_id && &subs::ble_bridge_capable();
	return 0 unless &ble_may_serve($edt, $chip_id);
	# Same resolver as the send itself: a recorded chip stays pushable after its
	# last sighting leaves the presence window, so the WiFi button is not dead
	# until someone happens to run a scan.
	my $embedded = &subs::embedded_device(&subs::rightNow(), $edt, $chip_id);
	return 0 unless ref $embedded eq 'HASH' && $embedded->{'mac_addresses'}->{'bluetooth'};
	return 1;
}

# One bridge connection for a run of messages, for a streamed reply: the daemon
# reads command lines per connection, so a dozen parts ride one client process
# instead of starting one per part (a perl start each time, on a phone, costs
# more than the audio). Returns a filehandle to print message JSON lines to, or
# undef when this machine may not drive the bridge. The caller closes it.
sub bluetooth_stream_open {
	my $data = shift;
	return undef unless $data->{'intent'} && $data->{'chip_id'} && $data->{'edt'} && &subs::ble_bridge_capable();
	# the same homebase-only rule as bluetooth_sender: one link, and it must not
	# be stolen by a machine the watch merely passed by
	return undef unless &ble_may_serve($data->{'edt'}, $data->{'chip_id'});
	my $embedded = &subs::device_lister(&subs::rightNow(), $data->{'edt'}, undef, $data->{'chip_id'});
	my $bt_mac = $embedded->{'mac_addresses'}->{'bluetooth'} or return undef;
	my $ble_uuids = &ble_nus_uuids();
	my $service_uuid = $embedded->{'service_uuid'} || $ble_uuids->{'service_uuid'};
	my $rx = $embedded->{'characteristic_uuid_rx'} || $ble_uuids->{'characteristic_uuid_rx'};
	my $tx = $embedded->{'characteristic_uuid_tx'} || $ble_uuids->{'characteristic_uuid_tx'};
	my $client = &ble_bridge_client() or return undef;
	return undef unless &ble_bridge_enabled() && $client;
	my $link = $gb::ble_links->{ &ble_link_key($bt_mac) };
	unless ($link && $link->{'connected'}) {
		system($^X, $client, 'connect', $bt_mac, '--service', $service_uuid, '--rx', $rx, '--tx', $tx, '--mtu', '512', '--compress', '1');
	}
	my $fh;
	open($fh, '|-', $^X, $client, 'sendloop', '--mac', $bt_mac) or return undef;
	return $fh;
}

sub board_config_payload {
	# The compact role payload a board needs over Bluetooth or USB. It is the
	# room payload without the parts only a watch/deck uses (the chat lists and
	# the pairing patience), so it stays small enough to send uncompressed and
	# carries everything call_the_president() rebuilds: the component map and
	# __specs.internal_jobs. Top-level keys for a microcontroller are the full
	# component names (led0, relay28, switch15, ...).
	my $payload = &watch_room_payload(shift) or return undef;
	delete $payload->{'__shutup'};
	delete $payload->{'__specs'}->{'chat'};
	return $payload;
}

sub watch_room_payload {
	# The same picture watch.pl's /watch route renders, built in-process so the
	# bridge can push it over BLE (the route itself needs an HTTP request).
	my $data = shift;
	my $edt = $data->{'edt'} || 'watch';
	my $chip_id = $data->{'chip_id'};
	my $od = &subs::embedded_operator_door($edt, $chip_id);
	my $watch_settings = eval { decode_json $od } || {};
	return undef unless $watch_settings->{'__specs'};
	foreach my $k ( keys %{$watch_settings} ) {
		next unless $watch_settings->{$k}->{'app'};
		$watch_settings->{$k}->{'toggle'} = &subs::setting_grabber({ app => $watch_settings->{$k}->{'app'}, setting => 'toggle' }) eq 'on' ? 1 : 0;
	}
	$watch_settings = &subs::embedded_internal_jobs($watch_settings);
	# The board refuses a payload that has fewer components than this: a BLE
	# reassembly that loses a part must not replace a full role with a partial one.
	$watch_settings->{'__specs'}->{'component_count'} = scalar(grep { !/^__/ } keys %{$watch_settings});
	return $watch_settings;
}

sub watch_toggle_pusher {
	# A toggle changed somewhere. While the watch is awake and connected this
	# lights its button up right away; a watch that slept through it asks for
	# the whole picture on its next state_request.
	my $data = shift;
	# the capability probe connects to the bridge's loopback; leave it to the
	# worker with the rest of the discovery
	return unless &subs::ble_bridge_enabled();
	my $app = $data->{'app'} || return;
	my $state = ($data->{'value'} || '') eq 'on' ? 'on' : 'off';
	my $exclude_chip = $data->{'exclude_chip'} || '';
	$log->info('toggle push: ' . $app . ' -> ' . $state . ' exclude=' . ($exclude_chip || '-'));
	# The device walk is the expensive half (it reads every sighting and, for a
	# BLE-only device, asks for this machine's address), so it belongs in the
	# worker: the request that changed the toggle must not wait on the bridge.
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		return unless &subs::ble_bridge_capable();
		# A toggle change reaches every embedded device that draws an app button:
		# the watch/deck light their button, and a board applies the app's new
		# state to the relays/LEDs wired to it. The bridge can carry several links
		# now, so this used to stop at the first device; keep one target per
		# (edt, chip). The board goes first: the relay is the hardware the person
		# is watching, and a sleeping watch/deck must not spend its link timeout
		# before the board is even written.
		my @targets;
		my %seen;
		foreach my $edt ( qw/microcontroller watch teletype/ ) {
			my $devices = &subs::device_lister(&subs::rightNow(), $edt, undef, 'all');
			next unless ref $devices eq 'ARRAY';
			foreach my $w ( @{$devices} ) {
				next unless ref $w eq 'HASH' && $w->{'chip_id'};
				# The board that produced the switch/button event already applied
				# it locally; pushing it back is a second flash write and a
				# second relay command for the same hardware.
				next if $exclude_chip && $w->{'chip_id'} eq $exclude_chip;
				# One push per chip, labelled with what the device actually is.
				# The Bluetooth fallback in device_lister answers every sighted chip
				# for every purpose we ask, so keying on the loop's type pushed the
				# same board twice - once as "watch" (a bridge connect) and once as
				# "microcontroller" - for every toggle.
				my $dev_edt = $w->{'edt'} || $w->{'purpose'} || $edt;
				next if $seen{ $w->{'chip_id'} }++;
				# A board holding the device socket already has this state: the direct
				# command or the automation fan-out carried it over that socket. The
				# same toggle over BLE is a second radio transaction on a chip that
				# runs WiFi and BLE together, and a burst of presses is what wedged
				# this board. Keep the BLE push for a board that has no socket.
				next if &subs::device_ws_connected($w->{'chip_id'});
				push @targets, { chip_id => $w->{'chip_id'}, edt => $dev_edt };
			}
		}
		return unless scalar @targets;
		# The board keeps a small manifest of the commands it has already run: the
		# same movement can also arrive as a fast HTTP relay (or a BLE `set`), and a
		# second application clicks the relay again. One id for every target of this
		# movement, plus its time, lets a board drop the copy it already ran.
		my $push_id = &subs::random_string_creator(21);
		my $push_at = &subs::rightNow();
		foreach my $t ( @targets ) {
			$log->info('toggle push send: ' . $t->{'chip_id'} . ' (' . $t->{'edt'} . ') ' . $app . ' -> ' . $state);
			&subs::bluetooth_sender({
				intent => 'com.jawn.president.bt.connect',
				chip_id => $t->{'chip_id'},
				edt => $t->{'edt'},
				message => { type => 'toggle', data => { app => $app, state => $state, uuid => $push_id, timestamp => $push_at } }
			});
		}
	}, { name => 'embedded toggle push', fork => 1 });
}

sub ble_rehome_check {
	# A watch that has bridged to a machine that is not its homebase must not be
	# kept there while the homebase is up: it is a one-link peripheral, so holding
	# it steals it from the machine the person paired it to. Yield it. A machine
	# serving as the FALLBACK (the homebase has gone quiet) serves on, but never
	# re-homes - the person wants the watch to come back to the phone, so the
	# stored homebase must stay the phone. Only when this machine IS the homebase
	# is there anything to fix: a watch whose own idea of its homebase has drifted
	# from the record. Re-home it to itself by pushing now_me over the link, which
	# rewrites the watch's homebase, rotates the authorization its tap urls carry,
	# and carries the screen timeout (so an idle watch stops dropping the link).
	my ($edt, $chip_id, $reported) = @_;
	return unless $edt && $chip_id && &subs::ble_bridge_capable();
	unless (&ble_may_serve($edt, $chip_id)) {
		&ble_yield($chip_id);
		return;
	}
	return unless &ble_owns($edt, $chip_id);
	# The watch's *own* homebase, as it reports it: the stored operator_door
	# specs can already name this machine while the watch still points
	# elsewhere (a push that never landed left them out of step), so the compare
	# must trust the watch, not the record.
	my $stored = $reported;
	my $stored_host = $stored;
	$stored_host =~ s/:\d+$// if defined $stored_host;
	# "this machine" cannot be device_lister(): on a shared LAN several machines
	# list the watch as a neighbour and it returns whichever it scans first. So
	# use our own interfaces and take the one on the watch's subnet (the stored
	# homebase names that subnet). The address is handed to now_me explicitly,
	# because now_me's own choice trusts the watch's LAN, where every machine
	# here shares a /24 and cannot be told apart.
	my $addrs = &subs::network_interface_reporter();
	# A board on the house WiFi cannot route to the Tailscale (100.64/10)
	# address, nor to a p2p/tun address in 192.0.0.0/24 that a phone may report
	# (USB tethering, a VPN). Handing one over BLE "works" until the next
	# /watch, which then fails and leaves the board on the radio alone. If this
	# machine has no real LAN address, leave the device's homebase untouched: a
	# stale address it may still reach is better than one it never can.
	my @usable = grep { &subs::lan_address_ok($_) }
		map { $addrs->{$_}->{'ip'} } keys %{$addrs};
	return unless @usable;
	my ($mine_ip) = grep { $stored_host && &subs::same_net_test($_, $stored_host, '127.0.0.1') eq 'yes' } @usable;
	$mine_ip ||= $usable[0];
	return if defined $stored_host && $stored_host eq $mine_ip;
	my $now = &subs::rightNow();
	$gb::ble_rehome_at ||= {};
	return if $gb::ble_rehome_at->{$chip_id} && $now - $gb::ble_rehome_at->{$chip_id} < 60000;
	$gb::ble_rehome_at->{$chip_id} = $now;
	$log->info('BLE re-home ' . $chip_id . ' from ' . ($stored || '?') . ' to ' . $mine_ip . ':' . ($ENV{'PORT_ARM'} || '?'));
	# never let a re-home abort the listener's read loop: a throw here used to
	# take the whole fork (and with it the watch -> jawn path) down
	eval {
		&Manager::now_me({
			edt => $edt,
			chip_id => $chip_id,
			method => 'bluetooth',
			timestamp => $now,
			homebase => $mine_ip,
			ip => $mine_ip
		});
		1;
	} or $log->error('BLE re-home failed: ' . $@);
}

1;
