package Manager;

# Manager helpers, part 34 of 37. Moved out of Manager.pl so a
# helper can be read and changed without opening 24k lines. The package is
# still Manager, and lib/JawnOS/Manager/Index.pm maps every sub name here to
# this file; Manager.pm loads it on the first call.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;
use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape xml_escape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use POSIX ();
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;
use JawnOS::Platform::Serial ();

use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use Minion;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub embedded_grabber($c,$timestamp) {
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $view = $c->param('view') || ($edt eq 'microcontroller' ? 'pins' : 'gpio');
	# 'pins' is a bare board's own pinout. A watch or teletype is a finished
	# device with no pin table, so the view can only ever answer "I don't know this
	# chip" - and because the client remembers the last view it was given
	# (localStorage 'embedded_view'), picking Pins once on a board left every other
	# device on that dead page, with its buttons one dropdown away. Never honour it
	# for anything that is not a board.
	$view = 'gpio' if $view eq 'pins' && $edt ne 'microcontroller';
	# The panel opens with the device picker blank, and the response then remembers
	# the chip it drew. So a blank has to resolve to a device here, or the panel
	# draws none and its buttons never appear. The neighbour-table branch of
	# device_lister answers it for a device on the LAN; a Bluetooth-only watch is
	# in no neighbour table, so its freshest bridge sighting stands in - the same
	# chip_ids sighting the BLE fallback lists it from.
	if (!$chip_id) {
		my $first = &subs::device_lister($timestamp,$edt,undef,$chip_id);
		$chip_id = $first->{'chip_id'} if ref $first eq 'HASH' && $first->{'chip_id'};
		unless ($chip_id) {
			my ($best, $seen);
			my $window = &subs::ble_presence_window();
			my $now = &subs::rightNow();
			foreach my $d ( @{ &subs::db_select('devices')->hashes } ) {
				next unless $d->{'chip_ids'};
				foreach my $ch ( @{ (eval { decode_json $d->{'chip_ids'} } || []) } ) {
					next unless ref $ch eq 'HASH' && $ch->{'id'};
					next if ($ch->{'purpose'} || '') ne $edt;
					next unless $ch->{'ble'} || $ch->{'bluetooth'};
					next if $seen->{ $ch->{'id'} }++;
					my $when = $ch->{'ble_seen'} || 0;
					next unless $when && $window > $now - $when;
					$best = $ch if !$best || $when > ($best->{'ble_seen'} || 0);
				}
			}
			$chip_id = $best->{'id'} if $best;
		}
	}
	my $embedded = &subs::embedded_device($timestamp,$edt,$chip_id);
	$timestamp = $c->param('timestamp');
	my $tty_enabled = &subs::setting_grabber({ app => $edt, setting => 'enabled' });
	my $pseudonyms = &pseudonym_maker($edt, '');
	my $json_wifi = &subs::setting_grabber({ app => $edt, setting => 'wifi', subsetting => $chip_id }) || '{}';
	my $wifi = decode_json $json_wifi;

	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id } );
	my $op_d = eval { return decode_json $od } || {};
	my $room_count = 	$op_d->{'__specs'}->{'room_count'} || &subs::setting_grabber({'app' => 'me', setting => 'room_count', subsetting => $chip_id }) || $op_d->{'__specs'}->{'room_count'} || 2;
	$op_d->{'__specs'}->{'room_count'} = $room_count;
	my $room_max = 2;
	my $components = $gb::embedded_components;
	my $start_n = 0;
	if ($edt eq 'teletype') {
		$room_max = 8;
		$start_n = 1;
		$components = { 'button' => $gb::embedded_components->{'button'} };
	}
	elsif ($edt eq 'watch') {
		$room_max = 6;
		$start_n = 1;
		$components = { 'button' => $gb::embedded_components->{'button'} };
	}
	else {
		$room_count = 1;
		$op_d->{'__specs'}->{'room_count'} = $room_count;
		$room_max = 28;
	}

	# The Pins view draws the pin map of the board model. A board listed over
	# Bluetooth, or one this machine has not scanned, carries no model on its
	# row (the neighbour table only learns it from /device_query), and the view
	# said "I don't know this chip". Use the model Now Me recorded - Query writes
	# it there too - and, while the house knows one board, that board's map.
	if ($edt eq 'microcontroller' && ref $embedded eq 'HASH') {
		my $known = $gb::microcontrollers || {};
		my $stored = $op_d->{'__specs'}->{'model'} || '';
		my $have = $embedded->{'model'} || '';
		$have =~ s/^\s+|\s+$//g if $have;
		$have = $stored if (!$have || (!$known->{$have} && $known->{$stored}));
		if ($have && !$known->{$have}) {
			my ($match) = grep { lc($_) eq lc($have) } keys %{$known};
			$have = $match if $match;
		}
		unless ($have) {
			my @known = keys %{$known};
			$have = $known[0] if scalar @known == 1;
		}
		$embedded->{'model'} = $have;
	}

	# Which GPIO numbers the operator door actually wires, for the Pins view: it
	# is a board map, so the person needs to see at a glance which pins already
	# do something. The GPIO view names them; this marks the map.
	my $wired_pins = {};
	if ($edt eq 'microcontroller') {
		foreach my $key ( keys %{$op_d} ) {
			next unless $key =~ /(\d+)$/;
			my $entry = $op_d->{$key};
			next unless ref $entry eq 'HASH';
			next unless $entry->{'app'} || $entry->{'component'} || $entry->{'movement'};
			$wired_pins->{$1} = $entry->{'app'} || $entry->{'component'} || 1;
		}
	}

	my $embedded_scope = &subs::setting_grabber({ app => $edt, setting => 'watch_scope', subsetting => $chip_id });
	my $settings;
	# A board's GPIO view is a list of what is wired, not every pin on the
	# board: six component types across 28 pins used to be 170 full setting
	# forms (and a settings read each), which is what made a Pico's panel crawl.
	# An unwired pin is still one press away on the Pins view (embedded_detail),
	# which draws the whole board map and fetches the one form a pin needs.
	my $configured_only = ($edt eq 'microcontroller');
	# Every slot that runs the same app reads the same settings row: a switch,
	# a relay and three buttons on one appointment all share it. Read it once
	# per app instead of once per slot (the old loop asked 170 times).
	my %aset_cache;
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	foreach my $component ( keys %{$components} ) {
		my $syl = &subs::shorthand_name($component, $syl_count);
		for (my $n = $start_n; $n <= $room_count * $room_max; $n++) {
			my $entry = $op_d->{$syl . $n} || {};
			next if $configured_only && !($entry->{'app'} || $entry->{'component'} || $entry->{'movement'});
			my $app = $entry->{'app'} || '';
			my $mov = $entry->{'movement'} || 'command';
			my $aset = $aset_cache{$app} ||= &subs::settings_grabber({ app => $app });
			my $toggle = $aset->{'toggle' } eq 'on' ? 1 : 0;
			my $tog = !$toggle || $toggle eq 'off' ? 1 : 0;
			$aset->{'measures'} = eval { return decode_json $aset->{'app_measures'} } || {};
			$aset->{'seen_measures'} = eval { return decode_json $aset->{'seen_measures'} } || [];
			$settings->{$syl . $n} = {
				app => $app,
				toggle => $tog,
				formatted_name => &subs::format_name($app),
				movement => $mov,
				inverted => $entry->{'inverted'},
				toggle => $toggle,
				settings => $aset,
				direction => $components->{$component}->{'direction'},
				measure => $entry->{'measure'},
				threshold => $entry->{'threshold'},
				named_measure => $entry->{'named_measure'},
				comparison => $entry->{'comparison'},
				name => $entry->{'name'},
				media_kind => $entry->{'media_kind'},
				media_machine => $entry->{'media_machine'}
			};
		}
	}

	my $movements = {};
	foreach my $m ( qw/usual command kill record start toggle measure video audio/ ) {
		$movements->{$m} = {
			formatted_name => &subs::format_name($m),
			mov => $m
		};
	}
	my $chip_ids = [];
	my %chip_seen;
	foreach my $chip ( @{&subs::db_select('devices')->hashes}) {
		$chip->{'chip_ids'} = eval { return decode_json $chip->{'chip_ids'} } || [{}];
		# One option per chip: the same device can be sighted by more than one
		# machine (a watch bridged over Bluetooth is listed by its homebase and,
		# briefly, by whichever machine it was linked to), and the rows all sync.
		foreach my $c ( @{$chip->{'chip_ids'}} ) {
			next unless ref $c eq 'HASH';
			my $id = $c->{'id'};
			next if $id && $chip_seen{$id}++;
			push @{$chip_ids}, $c;
		}
	}

	# The build the device reports, the build this machine would send, and
	# whether the person asked for automatic updates (see Domain::Firmware).
	my $firmware = &subs::firmware_status($edt, $chip_id, $embedded);
	# Which machine the device is paired to, by name: the board's own row names
	# its homebase as ip:port, and a person should not have to remember that
	# 192.168.1.147 is the Table.
	my $homebase = $op_d->{'__specs'}->{'homebase'} || '';
	$homebase =~ s{:\d+$}{};
	my $bridge = {
		ip => $homebase,
		name => ($homebase ne '' ? &subs::machine_name_for_ip($homebase) : ''),
	};
	my $returner = {
		template => 'embedded/embedded',
		embedded => $embedded,
		firmware => $firmware,
		bridge => $bridge,
		window_maker => 'yes',
		settings => $settings,
		movements => $movements,
		room_count => $room_count,
		room_max => $room_max,
		embedded_scope => $embedded_scope,
		tty_enabled => $tty_enabled,
		pseudonyms => $pseudonyms,
		wifi => $wifi,
		operator_door => $op_d,
		device_type => $edt,
		components => $components,
		wired_pins => $wired_pins,
		chip_ids => $chip_ids,
		chip_id => $chip_id,
		edt => $edt,
		start_n => $start_n,
		view => $view
	};
	$returner->{'contents'} = $c->render_to_string(
		%{$returner}
	);
	return $returner;
}

sub embedded_device_query($embedded) {
	my $manager = 'http://' . $embedded->{'ip'} . ':' . ($embedded->{'PORT_DOCK'} || $ENV{PORT_BOARD} || 3000) .  '/device_query';
	my $ua = Mojo::UserAgent->new();
	my $res = eval { $ua->insecure(1)->get($manager) };
	if (eval { $res->result->body }) {
		if (eval { decode_json $res->result->body }) {
			my $rb = decode_json $res->result->body;
			my $od = &subs::setting_grabber({ app => $rb->{'purpose'}, setting => 'operator_door', subsetting => $rb->{'chip_id'} } );
			my $op_d = eval { return decode_json $od } || {};
			# /device_query is where a board names its model. Keep it on the Now Me
			# record: the Pins view draws the board map from the model, and a machine
			# that listed the board over Bluetooth (or has not scanned it) has none
			# on the neighbour row - it said "I don't know this chip".
			if ($rb->{'model'} && $rb->{'purpose'} && $rb->{'chip_id'}) {
				$embedded->{'model'} ||= $rb->{'model'};
				$op_d->{'__specs'} ||= {};
				if (($op_d->{'__specs'}->{'model'} || '') ne $rb->{'model'}) {
					$op_d->{'__specs'}->{'model'} = $rb->{'model'};
					&subs::setting_setter({ app => $rb->{'purpose'}, setting => 'operator_door', subsetting => $rb->{'chip_id'}, value => encode_json $op_d });
				}
			}
			if (eval { scalar @{$rb->{'wigi'}} } ) {
				foreach my $w ( @{$rb->{'wigi'}} ) {
					my $room = $w->{'room'};
					my $room_count = $op_d->{'__specs'}->{'room_count'};
					my $room_max = $op_d->{'__specs'}->{'room_max'};
					$w->{'button'} = (($room -1 ) * $room_max) + $w->{'button'};
					my $server_time = &subs::rightNow();
					my $syl_count = 10;
					$syl_count = 1 unless $rb->{'purpose'} eq 'microcontroller';
					my $button = &subs::shorthand_name('button', $syl_count) . $w->{'button'};
					my $b = $op_d->{$button} || {};

					$w->{'movement'} = &subs::format_name($b->{'movement'});
					$w->{'app'} = &subs::format_name($b->{'app'});
					$w->{'data'} = $b;
				}
			}
			if (eval { scalar @{$rb->{'files'}} } ) {
				my $ua = Mojo::UserAgent->new();
				foreach my $a ( @{$rb->{'files'}} ) {
					my $params = {
						file => $a->{'directory'} eq '/' ? '/' . $a->{'name'} : $a->{'directory'} . '/' . $a->{'name'},
						authorization => $op_d->{'__specs'}->{'authorization'}
						};
					my $req = Mojo::URL->new("http://$embedded->{ip}:$config->{port}/get_file")
						->query($params)
						->to_string;

					my $res = $ua->insecure(1)->get($req)->result;
					if ($res->is_success) {
						my $data = $res->body;
						$a->{'data'} = encode_base64 $data;
					}
				}
			}
			# The reply is the freshest thing we know about the device, including
			# which build it is running. Record it before the purpose is formatted.
			&subs::firmware_version_note({
				edt => $rb->{'purpose'},
				chip_id => $rb->{'chip_id'},
				version => $rb->{'version'}
			});
			$rb->{'uptime'} = &subs::duration_sayer($rb->{'uptime'} / 1000);
			$rb->{'purpose'} = &subs::format_name($rb->{'purpose'});
			return $rb;
		}
	}
	return {};
}

sub embedded_pin_grabber($data) {
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $chip_id = $data->{'chip_id'};
	my $form = $data->{'form'};
	my $numero = $data->{'numero'};
	my $pin = $data->{'pin'} || $data->{'numero'};
	my $edt = $data->{'edt'};
	my $device_type = $data->{'edt'};
	my $current_component = $data->{'component'};
	my $embedded = &subs::embedded_device($timestamp,$edt,$chip_id);
	# Keep the identifiers the form needs even when the device itself is not in
	# reach, so the re-rendered controls still post for this chip.
	$embedded->{'chip_id'} ||= $chip_id;
	$embedded->{'edt'} ||= $edt;
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id } );
	my $op_d = eval { return decode_json $od } || {};
	my $returner;
	my $components = $gb::embedded_components;
	# The destination picker (which machine a button's command runs on) draws its
	# options from this list, and embedded.html.ep hands it in on the first render.
	# Without it here the list collapsed to "every machine" the moment any setting
	# was changed - the change looked like it had been thrown away.
	my $destinations = [ grep { $_->{'hostname'} && ($_->{'connection'} || 'active') eq 'active' } @{ &subs::remote_machine_lister({}) || [] } ];
	my $settings;
	my $movements;
	foreach my $m ( qw/usual command kill record start toggle measure video audio/ ) {
		$movements->{$m} = {
			formatted_name => &subs::format_name($m),
			mov => $m
		};
	}
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	foreach my $component ( keys %{$components} ) {
		if ($current_component && $current_component ne $component) {
			next;
		}
		my $syl = &subs::shorthand_name($component, $syl_count);
		my $n = $numero;
		my $app = $op_d->{$syl . $n}->{'app'} || '';
		my $mov = $op_d->{$syl . $n}->{'movement'} || 'command';
		my $aset = &subs::settings_grabber({ app => $app });
		my $toggle = $aset->{'toggle' } eq 'on' ? 1 : 0;
		my $tog = !$toggle || $toggle eq 'off' ? 1 : 0;
		$aset->{'measures'} = eval { return decode_json $aset->{'app_measures'} } || {};
		$aset->{'seen_measures'} = eval { return decode_json $aset->{'seen_measures'} } || [];
		$settings->{$syl . $n} = {
			app => $app,
			toggle => $tog,
			formatted_name => &subs::format_name($app),
			movement => $mov,
			inverted => $op_d->{$syl . $n}->{'inverted'},
			toggle => $toggle,
			settings => $aset,
			direction => $components->{$component}->{'direction'},
			measure => $op_d->{$syl . $n}->{'measure'},
			threshold => $op_d->{$syl . $n}->{'threshold'},
			named_measure => $op_d->{$syl . $n}->{'named_measure'},
			comparison => $op_d->{$syl . $n}->{'comparison'},
			name => $op_d->{$syl . $n}->{'name'},
			media_kind => $op_d->{$syl . $n}->{'media_kind'},
			media_machine => $op_d->{$syl . $n}->{'media_machine'}
		};

		my $c = &subs::controller_builder();
		$returner->{'html'} .= $c->render_to_string(
			template => 'embedded/component',
			n => $numero,
			component => $component,
			settings => $settings,
			components => $components,
			embedded => $embedded,
			movements => $movements,
			device_type => $device_type,
			source => 'grabber',
			pin => $pin,
			destinations => $destinations,
			name => $op_d->{$syl . $n}->{'name'}
		);
	}

	my @embedded_ports;
	if ($device eq 'computer' || $device eq 'server') {
		# Only the CDC boards here, as the ls glob was: the deck's ttyUSB
		# bridge is not a microcontroller panel.
		@embedded_ports = grep { m{/ttyACM} } @{ JawnOS::Platform::Serial::devices() };
	}

	my $chip_ids = [];
	foreach my $chip ( @{&subs::db_select('devices')->hashes}) {
		$chip->{'chip_ids'} = eval { return decode_json $chip->{'chip_ids'} } || [{}];
		push @{$chip_ids}, @{$chip->{'chip_ids'}};
	}

	return $returner || { html => '' };
};

sub embedded_app_deleter($data) {
	my $appt_uuid = $data->{'appt_uuid'};
	my $timestamp = &subs::rightNow();
	my $chip_id = $data->{'chip_id'} || 'all';
	my $chips = &subs::device_lister($timestamp, 'microcontroller', undef, $chip_id);
  &subs::subprocessor(sub {
    Mojo::IOLoop->reset;


		foreach my $watch ( @{$chips} ) {
			if ($watch->{'ip'}) {
				my $od = &subs::setting_grabber({ app => 'microcontroller', setting => 'operator_door', subsetting => $watch->{'chip_id'} });
				my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
				my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/delete_job' . '?appt_uuid=' . $appt_uuid . '&authorization=' . $op_d->{'__specs'}->{'authorization'} . '&timestamp=' . $timestamp;

				my $ua = Mojo::UserAgent->new();
				my $ping_ip = $watch->{'ip'};
				my $ping_test = '';
				if (&subs::peer_host_is_literal($ping_ip) && open(my $ping_fh, '-|', 'timeout', '.2', 'ping', '-c', '1', $ping_ip)) {
					local $/;
					$ping_test = <$ping_fh> // '';
					close $ping_fh;
				}
				if ($ping_test =~ /ttl/gi) {
					my $res = $ua->insecure(1)->get($watch_home)->result;
				}
			}
		}
	}, { name => 'embedded app deleter' });
}

# ---- USB flashing -----------------------------------------------------------
# The esp32 boards are plugged into this machine, so the panel cannot flash them
# itself: it asks the manager, which runs the PlatformIO upload and then polls the
# log for esptool's percentage lines.
sub usb_ports_grabber {
	my %by_id;
	foreach my $link ( glob('/dev/serial/by-id/*') ) {
		my $target = readlink($link);
		next unless $target;
		$target =~ s{.*/}{};
		my $label = $link;
		$label =~ s{.*/}{};
		$label =~ s{-if\d+.*$}{};
		$label =~ s{[_-]}{ }g;
		$by_id{'/dev/' . $target} = &subs::format_name($label);
	}
	my @ports;
	foreach my $path ( @{ JawnOS::Platform::Serial::devices() } ) {
		push @ports, {
			path => $path,
			label => $by_id{$path} || $path,
			acm => ($path =~ /ttyACM/) ? 1 : 0
		};
	}
	return \@ports;
}

sub ia_entry_ensure {
	# The wiring map (ia) is the app's view of every placed pin. A movement or
	# measure change used to write its one key into a bare
	# {"movement":"start"} stub when the entry had never been created (or was
	# deleted), and that stub has no component/pin/edt/ip - so the panel showed
	# a switch that drove nothing and the automation pass skipped it. Fill the
	# identity from the board's own operator_door whenever it is missing.
	my ($ia, $chip_id, $numero, $edt, $op_d, $syl, $component) = @_;
	my $entry = $ia->{$chip_id}->{$numero} ||= {};
	my $opd = $op_d->{$syl . $numero} || {};
	if (!$entry->{'component'}) {
		my $comp = $opd->{'component'} || $component;
		$entry->{'component'} = $comp;
		$entry->{'direction'} = $opd->{'direction'} || $gb::embedded_components->{$comp}->{'direction'} || 'input';
		$entry->{'pin'} = $numero;
		$entry->{'edt'} = $edt;
		$entry->{'ip'} = $opd->{'ip'} || $op_d->{'__specs'}->{'ip'} || '';
	}
	return $entry;
}

sub watch_setting_save($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $numero = $c->param('numero');
	my $movement = $c->param('movement');
	my $setting = $c->param('setting');
	my $component = $c->param('component');
	my $syl_count = 10;
	my $chip_id = $c->param('chip_id');
	my $percentage = $c->param('percentage');
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $syl = &subs::shorthand_name($component, $syl_count);
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
	my $app = $op_d->{$syl . $numero}->{app};
	$op_d->{$syl . $numero}->{$setting} = $movement;
	if ($percentage) {
		$op_d->{$syl . $numero}->{$setting . '_percentage'} = $percentage;
	}
	my $json_od = encode_json $op_d;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $json_od, timestamp => $timestamp, subsetting => $chip_id });
	my $jia = &subs::setting_grabber({ app => $app, setting => 'ia' });
	if ($app) {
		my $ia = ($jia && (eval { return decode_json $jia })) ? decode_json $jia : {};
		my $entry = &ia_entry_ensure($ia, $chip_id, $numero, $edt, $op_d, $syl, $component);
		$entry->{$setting} = $movement;
		if ($percentage) {
			$entry->{$setting . '_percentage'} = $percentage;
		}
		$jia = encode_json $ia;
		&subs::setting_setter({ app => $app, setting => 'ia', value => $jia });
	}
	my $returner = &embedded_pin_grabber({
		edt => $edt,
		numero => $numero,
		component => $component,
		chip_id => $chip_id,
		timestamp => $timestamp
	});
	my $res = eval { &now_me({ c => $c, timestamp => $timestamp, edt => $edt, chip_id => $chip_id, browser_tab_id => $c->param('browser_tab_id'), keep_pairing => 1 }) };
	# The setting is saved either way; a push that failed must not take the panel's
	# whole request down with it (a red dot that says nothing).
	$log->error('Now Me after setting: ' . ($@ =~ s/\s+/ /gr)) if $@;
	return $returner;
}

sub send_telephone($app,$msg) {
	my $timestamp = &subs::rightNow();
	foreach my $w ( qw/teletype watch microcontroller/ ) {
		my $chips = &subs::device_lister($timestamp,$w,undef, 'all');
		foreach my $watch ( @{$chips} ) {
			my $od = &subs::setting_grabber({ 'app' => $watch->{'purpose'}, 'setting' => 'operator_door', subsetting => $watch->{'chip_id'}  });
			my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
			if ($watch->{'ip'} && !$watch->{'uuid'}) {
				my $ping_ip = $watch->{'ip'};
				my $ping_test = '';
				if (&subs::peer_host_is_literal($ping_ip) && open(my $ping_fh, '-|', 'timeout', '.2', 'ping', '-c', '1', $ping_ip)) {
					local $/;
					$ping_test = <$ping_fh> // '';
					close $ping_fh;
				}


				if ($ping_test =~ /ttl/gi) {
					my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/send_telephone?app=' . $app . '&msg=' .
					&subs::unformat_name($msg) . '&timestamp=' . $timestamp;
			    &subs::subprocessor(sub {
				    Mojo::IOLoop->reset;

						my $ua = Mojo::UserAgent->new();
						my $res = $ua->insecure(1)->get($watch_home)->result;
					}, { name => 'send telephone' });
				}
				sleep 2;
			}
		}
	}
}

1;
