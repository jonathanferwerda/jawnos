package subs;

# Firmware: which image this machine holds for each embedded device, which
# build the device itself reports, and the auto-OTA sweep that pushes one to
# the other. Loaded on demand by lib/JawnOS/Domain/Loader.pm.
#
# The manager cannot ask a board what it is running unless the board says so:
# JAWN_FW_VERSION is compiled in by scripts/fw_version.py and rides the board's
# own state_request and /device_query reply. The image side is the hardwired
# path scripts/stage_firmware.pl writes, plus the .json sidecar it leaves
# beside it (version, sha256, size). A sidecar is what makes "stale" provable:
# without one, a staged image is just bytes of unknown age - which is how the
# Table kept serving v0.1.2224 through two later firmware versions.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';

use Digest::SHA ();
use File::Slurp qw(read_file);
use Mojo::Asset::File;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::Util qw(url_escape);

our $config;

# The paths scripts/stage_firmware.pl stages to, keyed by the purpose the
# Embedded app uses. @targets in that script must name the same destinations.
our %FIRMWARE_TARGET = (
	microcontroller => { name => 'alarmclock', path => 'jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin' },
	teletype        => { name => 'deck',       path => 'jt/build/deck/firmware.bin' },
	watch           => { name => 'watch',      path => 'jw/build/watch/firmware.bin' },
);

sub firmware_board_port() {
	# The firmware's own WebServer port. The manager's `port` happens to match it;
	# PORT_BOARD is what President exports for the boards.
	return $ENV{'PORT_BOARD'} || $config->{'port'} || 3000;
}

sub firmware_house_version() {
	my $version = eval { read_file('./VERSION') } || '';
	$version =~ s/\s+//g;
	$version =~ s/[^0-9A-Za-z._+-]//g;
	return $version;
}

sub firmware_target_for($edt) {
	my $target = $FIRMWARE_TARGET{$edt} or return undef;
	return { %{$target}, edt => $edt };
}

sub firmware_staged($edt) {
	# What this machine would send for a purpose, and whether it is provably the
	# image of the version this checkout is on. `current` is the only thing an
	# OTA may act on: a staged file with no sidecar, a sidecar that does not
	# match the bytes, or a sidecar naming another version is all "stale".
	my $target = firmware_target_for($edt);
	my $staged = {
		edt     => $edt,
		name    => ($target ? $target->{'name'} : ''),
		path    => '',
		version => firmware_house_version(),
		exists  => 0,
		sidecar => 0,
		current => 0,
		reason  => 'no firmware target for ' . (defined $edt ? $edt : ''),
	};
	return $staged unless $target;
	my $path = './' . $target->{'path'};
	$staged->{'path'} = $path;
	unless (-s $path) {
		$staged->{'reason'} = 'no image staged at ' . $target->{'path'} . ' - run perl scripts/stage_firmware.pl';
		return $staged;
	}
	$staged->{'exists'} = 1;
	$staged->{'size'} = -s $path;
	$staged->{'sha256'} = eval { Digest::SHA->new(256)->addfile($path, 'b')->hexdigest } || '';
	my $side = eval { read_file("$path.json") } || '';
	my $meta = $side ? (eval { decode_json $side } || {}) : {};
	unless ($meta->{'sha256'} && $meta->{'version'}) {
		$staged->{'reason'} = 'the staged image has no sidecar - run perl scripts/stage_firmware.pl';
		return $staged;
	}
	$staged->{'sidecar'} = 1;
	$staged->{'staged_version'} = $meta->{'version'};
	$staged->{'staged_at'} = $meta->{'staged_at'} || 0;
	if (($meta->{'sha256'} || '') ne ($staged->{'sha256'} || '')) {
		$staged->{'reason'} = 'the staged image does not match its sidecar - run perl scripts/stage_firmware.pl';
		return $staged;
	}
	if (($meta->{'version'} || '') ne ($staged->{'version'} || '')) {
		$staged->{'reason'} = 'the staged image is v' . $meta->{'version'}
			. ', this checkout is v' . $staged->{'version'} . ' - run perl scripts/stage_firmware.pl';
		return $staged;
	}
	$staged->{'current'} = 1;
	return $staged;
}

sub firmware_version_note($data) {
	# Remember the build a device says it is running. Kept in the device's own
	# operator_door row so the Embedded panel can show it without a live query,
	# and in the bridge sighting so a Bluetooth-only device carries it too.
	my $edt = $data->{'edt'} || 'watch';
	my $chip_id = $data->{'chip_id'};
	my $version = $data->{'version'};
	return undef unless $chip_id && defined $version;
	$version =~ s/^\s+|\s+$//g;
	# A version is a token, not a payload: it goes into a settings row and onto
	# the panel. Anything else is a device bug and is not stored.
	return undef unless $version =~ /^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$/;
	my $od = &setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = eval { decode_json $od } || {};
	$op_d->{'__specs'} ||= {};
	return $version if (($op_d->{'__specs'}->{'fw_version'} || '') eq $version);
	$op_d->{'__specs'}->{'fw_version'} = $version;
	$op_d->{'__specs'}->{'fw_seen'} = &rightNow();
	&setting_setter({ app => $edt, setting => 'operator_door', subsetting => $chip_id, value => encode_json $op_d });
	return $version;
}

sub firmware_status($edt, $chip_id) {
	# What the panel draws: the build the device reports, the build this machine
	# holds, whether they agree, and whether the person asked for automatic
	# updates.
	my $staged = firmware_staged($edt);
	my $od = $chip_id ? &setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id }) : '';
	my $op_d = eval { decode_json $od } || {};
	my $specs = $op_d->{'__specs'} || {};
	my $device = $specs->{'fw_version'} || '';
	my $latest = $staged->{'version'} || '';
	return {
		target      => $staged->{'name'} || '',
		device      => $device,
		device_seen => $specs->{'fw_seen'} || 0,
		latest      => $latest,
		auto        => ($specs->{'auto_ota'} || 'off'),
		staged      => $staged->{'exists'} ? 1 : 0,
		current     => $staged->{'current'} ? 1 : 0,
		reason      => $staged->{'reason'} || '',
		up_to_date  => ($device ne '' && $latest ne '' && $device eq $latest) ? 1 : 0,
	};
}

sub firmware_chip_specs($edt) {
	# Every device of this purpose this house has configured. The settings row is
	# the fleet list: a board on the LAN never needs a bridge sighting to be
	# here.
	my %chips;
	my $rows = eval { &db_select('settings', undef, { app => $edt, setting => 'operator_door' })->hashes } || [];
	foreach my $row ( @{$rows} ) {
		next unless $row->{'subsetting'};
		$chips{ $row->{'subsetting'} } = 1;
	}
	return [ sort keys %chips ];
}

sub firmware_query_device($edt, $chip_id) {
	# Ask the device what it is running, over the HTTP rail it already serves.
	# A Bluetooth-only device has no address to ask; it reports on its next
	# state_request instead.
	my $dev = &embedded_device(&rightNow(), $edt, $chip_id);
	my $ip = ref $dev eq 'HASH' ? ($dev->{'ip'} || '') : '';
	return undef unless $ip;
	my $url = 'http://' . $ip . ':' . firmware_board_port() . '/device_query';
	my $ua = Mojo::UserAgent->new();
	$ua->inactivity_timeout(8000);
	my $res = eval { $ua->insecure(1)->get($url)->result };
	return undef unless $res && $res->is_success;
	my $reply = eval { decode_json $res->body } || {};
	my $version = $reply->{'version'} || '';
	firmware_version_note({ edt => $edt, chip_id => $chip_id, version => $version }) if $version;
	return $version ne '' ? $version : undef;
}

sub firmware_push($data) {
	# Send one staged image to one device. The two rails the panel already uses:
	# a Pico takes the raw stream on /upload/alarmclock.bin, a deck takes a
	# multipart /update. A watch has no address of its own, so it is updated from
	# the panel's file picker over the bridge instead.
	my $edt = $data->{'edt'} || '';
	my $chip_id = $data->{'chip_id'} || '';
	my $staged = firmware_staged($edt);
	unless ($staged->{'exists'}) {
		return { success => 0, result => $staged->{'reason'} || 'no image staged' };
	}
	unless ($data->{'force'} || $staged->{'current'}) {
		return { success => 0, result => $staged->{'reason'} || 'the staged image is not current' };
	}
	my $ip = $data->{'ip'} || '';
	unless ($ip) {
		my $dev = &embedded_device(&rightNow(), $edt, $chip_id);
		$ip = ref $dev eq 'HASH' ? ($dev->{'ip'} || '') : '';
	}
	unless ($ip) {
		return { success => 0, result => 'no address for ' . $chip_id . ' - update a Bluetooth-only device from the panel file picker' };
	}
	my $od = &setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = eval { decode_json $od } || {};
	my $auth = $op_d->{'__specs'}->{'authorization'} || '';
	unless ($auth) {
		return { success => 0, result => 'no authorization on record - run Now Me first' };
	}
	my $file = $staged->{'path'};
	my $ua = Mojo::UserAgent->new();
	$ua->inactivity_timeout(180000);
	my $res;
	if ($edt eq 'microcontroller') {
		my $total = -s $file;
		my $url = 'http://' . $ip . ':' . firmware_board_port() . '/upload/alarmclock.bin?total_size=' . $total
			. '&authorization=' . url_escape($auth);
		$ua->transactor->add_generator(stream => sub ($transactor, $tx, $path) {
			$tx->req->content->asset(Mojo::Asset::File->new(path => $file));
		});
		$res = $ua->insecure(1)->post($url => { authorization => $auth } => stream => $file)->result;
	}
	else {
		my $image = read_file($file, binmode => ':raw');
		my $boundary = '----jawnos' . int(rand(1000000000));
		my $body =
			"--$boundary\r\n" .
			"Content-Disposition: form-data; name=\"firmware\"; filename=\"firmware.bin\"\r\n" .
			"Content-Type: application/octet-stream\r\n\r\n" .
			$image . "\r\n--$boundary--\r\n";
		$res = $ua->post('http://' . $ip . '/update?authorization=' . url_escape($auth)
			=> { 'Content-Type' => "multipart/form-data; boundary=$boundary", authorization => $auth } => $body)->result;
	}
	my $ok = ($res && $res->is_success) ? 1 : 0;
	return {
		success => $ok,
		code    => ($res ? $res->code : 0),
		result  => $ok ? ($res->body || 'accepted') : ($res && $res->error ? $res->error->{message} : 'no answer'),
		version => $staged->{'version'},
	};
}

sub firmware_auto_ota() {
	# The sweep behind the panel's Auto OTA checkbox. It runs on whichever machine
	# may serve the device (the same homebase rule the Bluetooth bridge uses), so
	# one machine pushes, not every peer at once. An attempt is stamped per
	# device and version, so a board that cannot take the update is not hammered
	# every tick, and a later version is tried immediately.
	my @lines;
	foreach my $edt ( sort keys %FIRMWARE_TARGET ) {
		# The devices that asked for this, and only those. A purpose with no
		# opted-in device is not this sweep's business, and must not chatter in
		# the utility log about an image it was never asked to send.
		my @opted;
		foreach my $chip_id ( @{ firmware_chip_specs($edt) } ) {
			my $od = &setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
			my $op_d = eval { decode_json $od } || {};
			$op_d->{'__specs'} ||= {};
			next unless ($op_d->{'__specs'}->{'auto_ota'} || 'off') eq 'on';
			next unless &ble_may_serve($edt, $chip_id);
			push @opted, [ $chip_id, $op_d ];
		}
		next unless @opted;
		my $staged = firmware_staged($edt);
		unless ($staged->{'current'}) {
			push @lines, $edt . ': ' . ($staged->{'reason'} || 'not staged');
			next;
		}
		my $latest = $staged->{'version'};
		foreach my $pair ( @opted ) {
			my ($chip_id, $op_d) = @{$pair};
			my $specs = $op_d->{'__specs'};
			my $version = $specs->{'fw_version'} || '';
			$version ||= firmware_query_device($edt, $chip_id) || '';
			next if $version ne '' && $version eq $latest;
			my $attempted = $specs->{'fw_attempt_version'} || '';
			my $at = $specs->{'fw_attempt_at'} || 0;
			next if ($attempted ne '' && $attempted eq $latest && $at && &rightNow() - $at < 900);
			my $dev = &embedded_device(&rightNow(), $edt, $chip_id);
			my $ip = ref $dev eq 'HASH' ? ($dev->{'ip'} || '') : '';
			next unless $ip;
			$specs->{'fw_attempt_version'} = $latest;
			$specs->{'fw_attempt_at'} = &rightNow();
			&setting_setter({ app => $edt, setting => 'operator_door', subsetting => $chip_id, value => encode_json $op_d });
			my $result = firmware_push({ edt => $edt, chip_id => $chip_id, ip => $ip });
			push @lines, $edt . ' ' . $chip_id . ': '
				. ($version ne '' ? 'v' . $version . ' -> ' : '')
				. 'v' . $latest . ' ' . ($result->{'success'} ? 'pushed' : 'failed: ' . $result->{'result'});
			&log_writer('firmware auto-ota: ' . $lines[-1]);
		}
	}
	return @lines ? 'firmware: ' . join('; ', @lines) : 'firmware: every auto-OTA device is current';
}

1;
