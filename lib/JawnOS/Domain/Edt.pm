package subs;

# Edt: extracted from subroutines.pl (package subs). Loaded on
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

our $database;
our $device;
our $gb;
our $log;
our $network_report_memo;
our $network_report_memo_at;

sub edt_button_presser {
	my $data = shift;
	my $remote_address = $data->{'remote_address'};
	my $timestamp = $data->{'timestamp'};
	my $room = $data->{'room'};
	my $watch_settings = $data->{'watch_settings'};
	my $button = $data->{'button'};
	my $edt = $data->{'edt'};
	my $toggler = $data->{'toggle'};
	my $state = $data->{'state'};
	my $chip_id = $data->{'chip_id'};
	my $room_count = $watch_settings->{'__specs'}->{'room_count'};
	my $room_max = $watch_settings->{'__specs'}->{'room_max'};
	my $component = $data->{'component'} || 'button';
	$button = (($room -1 ) * $room_max) + $button unless $edt eq 'microcontroller';
	my $server_time = &subs::rightNow();
	my $measure = $data->{'measure'};
	my $uuid = &subs::random_string_creator(21);
	my $command_id = $data->{'command_id'} || $uuid;
	my ($db,$database) = &subs::database_grabber();
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $b = $watch_settings->{&subs::shorthand_name($component, $syl_count) . $button} || {};
	my $app = $b->{'app'};
	my $movement = $b->{'movement'};
	my $settings = &subs::settings_grabber({ app => $app });
	my $saved_toggle = $settings->{'toggle'};
	my $toggle;
	my $duration = &subs::time_abbrev_translator($settings->{'duration'});
	$log->info('edt press: ' . ($app || '?') . ' ' . $component . ' saved=' . ($saved_toggle // '-') . ' toggler=' . (defined $toggler ? $toggler : '-') . ' movement=' . ($movement // '-')) if $log;

	if (($movement eq 'start' || $movement eq 'record' || $movement eq 'video' || $movement eq 'audio') && ($saved_toggle eq 'on' || $toggler eq 'on' || $saved_toggle == 1)) {
		$movement = 'stop';
		$toggle = 'off';
	}
	my $db_data = {
		app => $app,
		server_time => $server_time,
		timestamp => $timestamp,
		type => $movement,
		toggle => $b->{'toggle'},
		uuid => $uuid,
		duration => $duration,
		warranty => &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time),
		project => $settings->{'t_project'},
		pos => $settings->{'pos'},
		remote_address => $remote_address,
		source_chip_id => $chip_id
	};
	if ($saved_toggle eq 'on') {
		$b->{'toggle'} = 0;
		$toggle = 'off';
	}
	else {
		$b->{'toggle'} = 1;
		$toggle = 'on';
	}

	# A video/audio movement is a record press whose source and machine are
	# chosen in the pin editor. The pin's own kind wins, but only within its
	# family: a stored kind left over from the other movement falls back to the
	# movement's default. The row carries the source and machine so the Alarm
	# loop claims it on the machine that must capture, not on whichever wakes
	# first (Part05 writes them into the row's data, not as columns).
	if ($movement eq 'video' || $movement eq 'audio') {
		my $video = $movement eq 'video' ? 1 : 0;
		my $default_kind = $video ? 'video' : 'audio';
		my $kind = $b->{'media_kind'} || $default_kind;
		$kind = $default_kind
			unless $video ? ($kind =~ /^(?:video|video_front)$/) : ($kind =~ /^(?:audio|system)$/);
		$db_data->{'type'} = 'record';
		$db_data->{'recorder'} = &Manager::record_source_param($kind) || $default_kind;
		$db_data->{'machine'} = $b->{'media_machine'} || &subs::signatorial_designer();
		$db_data->{'camera'} = $kind eq 'video_front' ? 1 : 0 if $kind =~ /^video/;
	}
	elsif ($movement eq 'stop') {
		# A stop names the session it closes; this press has none in hand, and
		# the uuid minted above names no row. Dropping it lets the writer fall
		# back to the oldest open session instead of resolving nothing.
		delete $db_data->{'uuid'};
	}

	my $relay_outcome;
	if ($movement eq 'command' || $movement eq 'kill') {
		if ($settings->{'command'} && $settings->{'kill'}) {

		}
		elsif ($settings->{'command'} && !$settings->{'kill'}) {
			$toggle = $saved_toggle;
			$b->{'toggle'} = $saved_toggle eq 'on' ? 1 : 0;
		}
		# The button can name the machine the command belongs to (a signatorial
		# from the remote machine list); blank means every machine runs its own
		# copy, this one included. A named machine that cannot be reached is
		# handed to the relay queue by destination_relay; only when even that
		# cannot be queued does the press run here instead.
		my $destination = $b->{'destination'} || '';
		my $me = &subs::signatorial_designer();
		my $ran_away = 0;
		if (!$destination) {
			$relay_outcome = &subs::destination_relay({ destination => 'all', app => $app, movement => $movement, timestamp => $server_time, command_id => $command_id });
			$db_data->{'data'} = 'every machine';
			# This machine is one of "every machine": destination_relay never
			# sends the movement back here, so run our own copy below. The press
			# id guard makes that safe when the same tap reached two homebases and
			# each one relays to the other.
		}
		elsif ($destination ne $me) {
			$relay_outcome = &subs::destination_relay({ destination => $destination, app => $app, movement => $movement, timestamp => $server_time, command_id => $command_id });
			if ($relay_outcome->{'sent'}) {
				$ran_away = 1;
				$db_data->{'data'} = $relay_outcome->{'label'};
			}
			elsif ($relay_outcome->{'queued'}) {
				$ran_away = 1;
				$db_data->{'data'} = 'queued for ' . ($relay_outcome->{'label'} || $destination);
			}
		}
		unless ($ran_away) {
			# no destination set, it is this machine, or the named peer could
			# not even be queued: run here. A press that already ran here (the
			# same tap reached a second homebase, which relayed it back) is not
			# run again; this is the same id guard manager_reset uses.
			my $already = $command_id && &subs::command_already_applied($command_id);
			unless ($already) {
				&subs::command_mark_applied($command_id) if $command_id;
				my $resulter = &subs::run_command($app,$settings->{$movement});
				$db_data->{'data'} = &subs::runner_label() unless $db_data->{'data'};
			}
			$relay_outcome ||= { ok => 1, all => 0, sent => 1, expected => 1, queued => 0 };
			# Count this machine in an every-machine press's outcome, so the
			# device's green/red flash reflects the whole house.
			if ($relay_outcome->{'all'}) {
				$relay_outcome->{'sent'} = ($relay_outcome->{'sent'} || 0) + 1;
				$relay_outcome->{'expected'} = ($relay_outcome->{'expected'} || 0) + 1;
				$relay_outcome->{'ok'} = ($relay_outcome->{'sent'} >= $relay_outcome->{'expected'}) ? 1 : 0;
			}
		}

	}
	&subs::setting_setter({ app => $app, setting => 'toggle', value => $toggle, source_chip_id => $chip_id, timestamp => $timestamp });
	$db_data->{'seen'} = 'yes';
	my $c = &subs::controller_builder();
	my $returner;
	if ($measure) {

		$c->param('measure', $b->{'measure'});
		$c->param('value', $measure);

		&Manager::appt_measure_writer($c,{ app => $app, measure => $b->{'measure'}, value => $measure, timestamp => $timestamp, remote_address => $remote_address });
		&Websocket::send('tab', { console => &Websocket::console_command('setMeasure', $app, $b->{'measure'}, $measure)});
		&Websocket::send('tab', { console => &Websocket::console_command('setMeasureText', $app, $b->{'measure'}, $measure)});
	}
	else {
		$returner = {
			app => $app,
			numero => $b->{'numero'},
			shorthand_name => &subs::shorthand_name($b->{'shorthand_name'}),
			movement => $b->{'movement'},
			toggle => $b->{'toggle'},
			button => $button,
			colour => $b->{'colour'},
			rgb => $b->{'rgb'},
		};
		# The device paints the press's outcome from these: red when a named
		# command did not land or an every-machine command missed a machine,
		# green when every machine took it.
		if ($relay_outcome) {
			$returner->{'relay_ok'} = $relay_outcome->{'ok'} ? 1 : 0;
			$returner->{'relay_all'} = $relay_outcome->{'all'} ? 1 : 0;
			$returner->{'relay_sent'} = 0 + ($relay_outcome->{'sent'} || 0);
			$returner->{'relay_expected'} = 0 + ($relay_outcome->{'expected'} || 0);
			$returner->{'relay_queued'} = $relay_outcome->{'queued'} ? 1 : 0;
		}

		my $insert = &Manager::appointment_writer($c,$db_data);
	}
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	# embeddedAuthorizer hands the settings over with __shutup (the patience
	# half of the authorization pair) deliberately blanked, and this write-back
	# used to store that blanked copy: it destroyed the device's patience with
	# the first accepted request, so every later request failed auth and fell
	# into the wigi queue. Put the stored key back before saving the buttons.
	my $stored = eval { decode_json &subs::embedded_operator_door($edt, $chip_id) } || {};
	$watch_settings->{'__shutup'} = $stored->{'__shutup'} if $stored->{'__shutup'};
	my $od = encode_json $watch_settings;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $od, subsetting => $chip_id });
	return $returner;
}

# The Android runtime has no ifconfig, and `ip addr` cannot bind a netlink socket
# as an app uid (SELinux), so the phone and tablet reported no interfaces at all
# and their devices row carried `{}`. The app answers the same report natively
# (network.interfaces); this maps it to the structure the ifconfig parser below
# produces. A desktop has no bridge, so it keeps parsing ifconfig.
# Order-insensitive identity for an address map. It covers the fields a peer
# needs to reach and label this machine (address, MAC, gateway and the ports),
# so a row written without the port environment is corrected on the next pass.
sub address_signature {
	my ($address) = @_;
	return '' unless ref $address eq 'HASH';
	my @fields = qw(ip mac netmask broadcast gw port ws_port alarm_port arm_port bestow_port coms_port dock_port);
	return join ';', map {
		my $e = $address->{$_};
		$_ . '=' . ( ref $e eq 'HASH'
			? join( ',', map { $_ . ':' . ( $e->{$_} // '' ) } @fields )
			: '' )
	} sort keys %{$address};
}

# The device bridge resizes and re-encodes images natively. A call site keeps
# its magick pipeline as the fallback for a desktop, where there is no bridge;
# the helper answers undef then. This is the first half of the ImageMagick diet:
# once every image call site asks here first, magick can leave the runtime.
sub image_resolution_parts {
	my ($resolution) = @_;
	return () unless defined $resolution && $resolution =~ /^\s*(\d+)\s*x\s*(\d+)\s*$/i;
	return ( $1 + 0, $2 + 0 );
}

# Formats the app's BitmapFactory bridge must not be handed: it cannot decode
# TIFF/TIFF-family or XCF, and for JPEG/HEIC it re-encodes without the EXIF
# orientation, so the picture comes back sideways. The caller's magick fallback
# keeps the pixels upright. The suffix is checked after a sealed `.enc` tail.
sub image_bridge_source_unfit {
	my ($path) = @_;
	return 0 unless defined $path && length $path;
	my $name = $path;
	$name =~ s/\.enc$//i;
	return $name =~ /\.(?:jpe?g|tiff?|xcf|heic|heif)$/i ? 1 : 0;
}

sub image_bridge_resize {
	my ( $path, $width, $height, $out ) = @_;
	return undef unless defined $path && length $path && -e $path;
	return undef unless $width && $height;
	# The app's bridge decodes with BitmapFactory and re-encodes, which drops the
	# EXIF orientation a phone camera records; it cannot decode TIFF or XCF at all.
	# Leave those to the caller's ImageMagick fallback, which applies -auto-orient.
	return undef if &image_bridge_source_unfit($path);
	my $result = eval {
		&subs::device_call('image.resize', {
			path   => $path,
			width  => $width + 0,
			height => $height + 0,
			out    => ( defined $out && length $out ? $out : $path ),
		});
	};
	return $result if ref $result eq 'HASH' && defined $result->{'path'} && length $result->{'path'};
	return undef;
}

sub image_bridge_save {
	my ( $path, $out, $format, $quality ) = @_;
	return undef unless defined $path && length $path && -e $path;
	return undef unless defined $out && length $out;
	my %args = ( path => $path, out => $out, quality => ( $quality || 90 ) + 0 );
	$args{'format'} = $format if defined $format && length $format;
	my $result = eval { &subs::device_call('image.save', \%args) };
	return $result if ref $result eq 'HASH' && defined $result->{'path'} && length $result->{'path'};
	return undef;
}

# The palette's duties are a list of per-file steps - rotate, crop, modulate,
# level, black-threshold, gaussian-blur, sharpen - which the route used to run
# as one `magick <file> -<duty> <value> <file>` per step. The bridge applies the
# same list in one call, so the palette survives on a phone with no magick; a
# desktop gets undef and keeps the command. Steps the bridge does not know are
# reported back in `skipped` rather than failing the whole edit.
sub image_bridge_edit {
	my ( $path, $duties, $out ) = @_;
	return undef unless defined $path && length $path && -e $path;
	return undef unless ref $duties eq 'ARRAY' && scalar @{$duties};
	my @steps;
	foreach my $d ( @{$duties} ) {
		next unless ref $d eq 'HASH';
		my $duty = $d->{'duty'};
		next unless defined $duty && $duty =~ /^[a-z][a-z-]*$/;
		next if $duty eq 'save' || $duty eq 'copy' || $duty eq 'clear';
		push @steps, {
			duty  => $duty,
			value => ( defined $d->{'value'} ? '' . $d->{'value'} : '' ),
		};
	}
	return undef unless @steps;
	my $result = eval {
		&subs::device_call('image.edit', {
			path   => $path,
			out    => ( defined $out && length $out ? $out : $path ),
			duties => \@steps,
		});
	};
	return $result if ref $result eq 'HASH' && defined $result->{'path'} && length $result->{'path'};
	return undef;
}

# A display copy of a picture for a card or an avatar: the bridge fills a square
# from the centre (magick's `-resize NxN^ -gravity center -extent NxN`). A
# desktop answers undef and keeps its command.
sub image_bridge_cover {
	my ( $src, $size, $out, $quality ) = @_;
	return undef unless defined $src && length $src && -e $src;
	return undef unless defined $out && length $out;
	$size = 160 unless defined $size && $size =~ /^\d+$/ && $size > 0;
	my $result = eval {
		&subs::device_call('image.cover', {
			path    => $src,
			out     => $out,
			size    => $size + 0,
			quality => ( defined $quality && $quality =~ /^\d+$/ && $quality ? $quality + 0 : 82 ),
		});
	};
	return $result if ref $result eq 'HASH' && defined $result->{'path'} && length $result->{'path'};
	return undef;
}

# A thumbnail file made by the bridge: the bytes come back as PNG and are
# written where the caller wants them. A desktop gets undef, so it keeps its
# ffmpeg | magick pipeline.
sub image_bridge_thumbnail {
	my ( $src, $max, $out, $at_ms ) = @_;
	return undef unless defined $src && length $src && -e $src;
	return undef unless defined $out && length $out;
	my $bytes = &device_thumbnail($src, $max, $at_ms);
	return undef unless defined $bytes && length $bytes;
	eval { write_file($out, $bytes) };
	return (-e $out && (-s $out) > 0) ? $out : undef;
}

sub image_bridge_identify {
	my ($path) = @_;
	return undef unless defined $path && length $path && -e $path;
	my $result = eval { &subs::device_call('image.identify', { path => $path }) };
	return $result
		if ref $result eq 'HASH'
		&& defined $result->{'width'} && $result->{'width'} =~ /^\d+$/
		&& defined $result->{'height'} && $result->{'height'} =~ /^\d+$/
		&& defined $result->{'kind'} && length $result->{'kind'};
	return undef;
}

sub image_bridge_convert {
	my ( $src, $out, %opt ) = @_;
	return undef unless defined $src && length $src && -e $src;
	return undef unless defined $out && length $out;
	# BitmapFactory cannot read these, so a bridge answer would be an empty or
	# failed conversion. The caller's magick fallback handles them (first page).
	return undef if &image_bridge_source_unfit($src);
	my %args = ( path => $src, out => $out );
	foreach my $key ( qw(format quality max_width max_height) ) {
		$args{$key} = $opt{$key} if defined $opt{$key} && length $opt{$key};
	}
	$args{'auto_orient'} = $opt{'auto_orient'} ? 1 : 0 if defined $opt{'auto_orient'};
	my $result = eval { &subs::device_call('image.convert', \%args) };
	return $result if ref $result eq 'HASH' && defined $result->{'path'} && length $result->{'path'};
	return undef;
}

sub image_bridge_gray {
	my ( $src, $w, $h ) = @_;
	return undef unless defined $src && length $src && -e $src;
	return undef unless defined $w && $w =~ /^\d+$/ && $w > 0;
	return undef unless defined $h && $h =~ /^\d+$/ && $h > 0;
	my $result = eval {
		&subs::device_call('image.gray', {
			path   => $src,
			width  => $w + 0,
			height => $h + 0,
		});
	};
	return undef unless ref $result eq 'HASH';
	my $data = $result->{'data'};
	return undef unless defined $data && length $data;
	require MIME::Base64;
	my $bytes = MIME::Base64::decode_base64($data);
	return (defined $bytes && length $bytes) ? $bytes : undef;
}

sub image_bridge_normalize {
	my ( $src, $out, $max ) = @_;
	return undef unless defined $src && length $src && -e $src;
	return undef unless defined $out && length $out;
	$max = 1024 unless defined $max && $max =~ /^\d+$/ && $max > 0;
	my $result = eval {
		&subs::device_call('image.normalize', {
			path => $src,
			out  => $out,
			max  => $max + 0,
		});
	};
	return $out if ref $result eq 'HASH' && defined $result->{'path'} && length $result->{'path'};
	return undef;
}

sub image_bridge_montage {
	my ($paths) = @_;
	return undef unless ref $paths eq 'ARRAY';
	my @existing = grep { defined $_ && length $_ && -e $_ } @{$paths};
	return undef unless @existing;
	require File::Temp;
	my ($fh, $tmp) = eval {
		File::Temp::tempfile('jawnos-montage-XXXXXX', TMPDIR => 1, UNLINK => 0, SUFFIX => '.png');
	};
	return undef unless $fh && defined $tmp;
	close $fh;
	my $result = eval { &subs::device_call('image.montage', { paths => \@existing, out => $tmp }) };
	my $bytes = ( ref $result eq 'HASH' )
		? eval { read_file($tmp, { binmode => ':raw' }) }
		: undef;
	unlink $tmp;
	return undef unless defined $bytes && length $bytes;
	return $bytes;
}

sub network_report_from_bridge {
	my ($report) = @_;
	return undef
		unless ref $report eq 'HASH'
		&& ref $report->{'interfaces'} eq 'HASH'
		&& %{ $report->{'interfaces'} };
	my $address = {};
	foreach my $nic ( sort keys %{ $report->{'interfaces'} } ) {
		my $i = $report->{'interfaces'}->{$nic};
		next unless ref $i eq 'HASH' && defined $i->{'ip'} && length $i->{'ip'};
		my %entry = (
			nnic        => $nic,
			ip          => $i->{'ip'},
			port        => $ENV{PORT_AHOY},
			ws_port     => $ENV{PORT_MSG},
			alarm_port  => $ENV{PORT_BELL},
			arm_port    => $ENV{PORT_ARM},
			bestow_port => $ENV{PORT_BESTOW},
			coms_port   => $ENV{PORT_COMS},
			dock_port   => $ENV{PORT_DOCK},
			manager     => 'https://' . $i->{'ip'} . ':' . $ENV{PORT_DOCK} . '/manager',
			timestamp   => &subs::rightNow(),
		);
		$entry{'mac'} = $i->{'mac'}
			if defined $i->{'mac'} && length $i->{'mac'};
		$entry{'netmask'} = $i->{'netmask'}
			if defined $i->{'netmask'} && length $i->{'netmask'};
		$entry{'broadcast'} = $i->{'broadcast'}
			if defined $i->{'broadcast'} && length $i->{'broadcast'};
		$entry{'gw'} = $i->{'gw'}
			if defined $i->{'gw'} && length $i->{'gw'};
		$address->{$nic} = \%entry;
	}
	return $address;
}

# net-tools and iproute2 live in /usr/sbin and /sbin, which a normal user's PATH on
# a Debian box does not carry. A bare `ifconfig` there prints "not found", and the
# parser below read that error line as an interface literally named "sh" - so the
# address report came back empty and the presence beacon had no LAN to sit on.
sub system_path_with_sbin {
	my ($path) = @_;
	return '/usr/sbin:/sbin:' . (defined $path && length $path ? $path : '');
}

sub network_interface_reporter {
	my $c = shift;
	# The probes below run through the shell, and the login shell of a service
	# account often has no sbin paths at all.
	local $ENV{'PATH'} = &system_path_with_sbin($ENV{'PATH'});
	# Reading the interfaces shells out to ifconfig/arp for every NIC (about
	# 100ms). Callers ask several times in one pass - a BLE device walk asks once
	# per chip - and nothing changes second to second, so keep the report for a
	# few seconds. Return a copy: callers add ports and other per-call fields.
	my $now = &rightNow();
	if ($network_report_memo && $now - ($network_report_memo_at || 0) < 5000) {
		return { map { $_ => { %{$network_report_memo->{$_}} } } keys %{$network_report_memo} };
	}
	# The app knows the interfaces natively; ask it first. On a desktop there is
	# no bridge and this returns undef, so the ifconfig parse below still runs.
	my $bridge_report = eval {
		&network_report_from_bridge( &subs::device_call('network.interfaces') )
	};
	if ( $bridge_report && %{$bridge_report} ) {
		$network_report_memo = $bridge_report;
		$network_report_memo_at = $now;
		return { map { $_ => { %{$network_report_memo->{$_}} } } keys %{$network_report_memo} };
	}
	my $device = &subs::device_setter();
	require JawnOS::Platform::Net;
	my $address = JawnOS::Platform::Net::interfaces();
	foreach my $nic ( keys %{$address} ) {
		my $entry = $address->{$nic};
		$entry->{'gw'} = JawnOS::Platform::Net::gateway($nic);
		$entry->{'gw_mac'} = JawnOS::Platform::Net::gateway_mac($nic, $entry->{'gw'})
			if $device eq 'computer' && length($entry->{'gw'} || '');
		if ($entry->{'ip'}) {
			$entry->{'port'} = $ENV{PORT_AHOY};
			$entry->{'ws_port'} = $ENV{PORT_MSG};
			$entry->{'alarm_port'} = $ENV{PORT_BELL};
			# The ports an embedded device dials. They used to be derived from
			# `port` (+2, +3, +4), but a peer's row should carry them so a
			# fallback machine can be named exactly even if the offsets move.
			$entry->{'arm_port'} = $ENV{PORT_ARM};
			$entry->{'bestow_port'} = $ENV{PORT_BESTOW};
			$entry->{'coms_port'} = $ENV{PORT_COMS};
			$entry->{'dock_port'} = $ENV{PORT_DOCK};
			$entry->{'manager'} = 'https://' . $entry->{'ip'} . ':' . $ENV{PORT_DOCK} .  '/manager';
			$entry->{'timestamp'} = &subs::rightNow();
		}
	}

	$network_report_memo = $address;
	$network_report_memo_at = $now;
	return $address;
}

sub same_net_test {
	my ($home_ip,$ip,$localhost_override) = @_;
	$localhost_override = '' unless defined $localhost_override;
	my $same_net = 'no';
	my $localhost = '127.0.0.1';
	return $same_net if ($ip eq $localhost || $home_ip eq $localhost) && !$localhost_override;
	if ($ip ne $localhost && $home_ip ne $localhost && $ip ne $localhost_override) {
		my @ip = split /\./, $ip;
		my @home_ip = split /\./, $home_ip;
		my $test = 'no';
		for ( my $i = 0; $i < scalar @home_ip - 1; $i++ ) {
			if ($home_ip[$i] == $ip[$i]) {
				$test = 'yes';
			}
			else { 	$test = 'no'; last; }
		}
		if ($test eq 'yes') { $same_net = 'yes'; }
	}
	return $same_net;
}

# Only a private or link-local network is ours to probe: a public address is not.
sub ip_is_private {
	my $ip = shift || '';
	return 1 if $ip =~ /^10\./;
	return 1 if $ip =~ /^192\.168\./;
	return 1 if $ip =~ /^169\.254\./;
	return 1 if $ip =~ /^172\.(?:1[6-9]|2\d|3[01])\./;
	return 1 if $ip =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;  # carrier-grade NAT
	return 0;
}

# ---- routers on the network ------------------------------------------------
# The gateway is the one device every network has, and the Dev panel should
# name it without a person tagging it. Probe it once (the login page says which
# firmware answers), keep the row when the machine later leaves that network,
# and let the card show the last time it was seen. A router is not a JawnOS
# peer, so it does not belong in remote_machines.
sub router_probe {
	my ($ip) = @_;
	return undef unless $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	return undef unless &ip_is_private($ip);
	my $body = `timeout 4 curl -sk --max-time 4 http://$ip/ 2>/dev/null | head -c 20000`;
	return undef unless $body;
	my $name = '';
	my $firmware = '';
	if ($body =~ /DD-WRT/i) {
		$name = 'DD-WRT';
		$firmware = 'DD-WRT';
	}
	elsif ($body =~ /OpenWrt/i) {
		$name = 'OpenWrt';
		$firmware = 'OpenWrt';
	}
	if ($name eq '' && $body =~ /<title[^>]*>(.*?)<\/title>/is) {
		$name = $1;
		$name =~ s/<[^>]+>//g;
		$name =~ s/\s+/ /g;
		$name =~ s/^\s+|\s+$//g;
	}
	$name = 'Router' if $name eq '';
	return { name => $name, firmware => $firmware, manager => "http://$ip/" };
}

sub router_discover {
	my $now = &rightNow();
	my $last = &cache_get({ app => '__president', context => 'router', subcontext => 'discovery' });
	return if $last && ($last->{'at'} || 0) > $now - 120000;
	&cache_set({ app => '__president', context => 'router', subcontext => 'discovery', warranty => '-2m' }, { at => $now });
	my $report = &network_interface_reporter();
	foreach my $nic ( keys %{$report} ) {
		my $gw = $report->{$nic}->{'gw'} || '';
		next unless $gw =~ /^\d{1,3}(?:\.\d{1,3}){3}$/ && &ip_is_private($gw);
		my $probe = &router_probe($gw) || { name => 'Router', firmware => '', manager => "http://$gw/" };
		my $row = &db_select('routers', undef, { ip => $gw })->hashes->[0];
		my %rec = (
			ip => $gw, nic => $nic, name => $probe->{'name'},
			model => $probe->{'firmware'}, manager => $probe->{'manager'},
			mac => $report->{$nic}->{'gw_mac'} || '', last_seen => $now,
			server_time => $now, ost => $now,
		);
		if ($row) {
			&db_update('routers', \%rec, { uuid => $row->{'uuid'} });
		}
		else {
			$rec{'uuid'} = &random_string_creator(25);
			$rec{'timestamp'} = $now;
			&db_insert('routers', \%rec);
		}
	}
	return 1;
}

# Every router this machine has met, newest sighting first. Keep only one seen
# in the last day, or the gateway of a NIC that is up right now: a laptop that
# roams would otherwise pile up an unnamed row for every network it has left.
# The rows stay in the table, so returning to that network lists it again.
# online is a short window so a router that is simply off the network still
# lists, greyed, with the last time it answered.
sub router_list {
	my $now = &rightNow();
	my $report = &network_interface_reporter();
	my %live_gateway = map { ($report->{$_}->{'gw'} || '') => 1 } keys %{$report};
	my @routers = grep {
		my $seen = $_->{'last_seen'} || 0;
		($seen && $now - $seen < 86400000) || $live_gateway{ $_->{'ip'} || '' }
	} @{ &db_select('routers')->hashes || [] };
	@routers = sort { ($b->{'last_seen'} || 0) <=> ($a->{'last_seen'} || 0) } @routers;
	foreach my $r (@routers) {
		my $seen = $r->{'last_seen'} || 0;
		$r->{'online'} = ($seen && $now - $seen < 900000) ? 1 : 0;
		$r->{'seen_display'} = $seen ? &subs::formatted_time($seen) : '';
		$r->{'name'} ||= 'Router';
	}
	return \@routers;
}

# Resolve mDNS/DNS-SD services of one type on the local network, as a list of
# records. The Avahi/dns-sd choice and the parsable-output parse live in
# JawnOS::Platform::Mdns.
sub mdns_browse {
	my ($type) = @_;
	require JawnOS::Platform::Mdns;
	return JawnOS::Platform::Mdns::browse($type);
}

# The printers the local network advertises, keyed by address and by MAC so a
# scanned device can be recognised either way. _ipp._tcp is the Internet
# Printing service every modern printer answers; _pdl-datastream (port 9100) is
# the fallback for one that only speaks raw.
sub mdns_printers {
	my $records = &mdns_browse('_ipp._tcp');
	$records = &mdns_browse('_pdl-datastream._tcp') unless @{$records};
	my (%by_ip, %by_mac);
	foreach my $r (@{$records}) {
		$by_ip{$r->{'ip'}} ||= $r;
		$by_mac{$r->{'mac'}} ||= $r if $r->{'mac'};
	}
	return { by_ip => \%by_ip, by_mac => \%by_mac };
}

1;
