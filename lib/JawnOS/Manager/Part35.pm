package Manager;

# Manager helpers, part 35 of 37. Moved out of Manager.pl so a
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
use Mojo::IOLoop::ReadWriteFork;
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
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub now_me($data) {
	my $timestamp = $data->{'timestamp'};
	my $edt = $data->{'edt'};
	my $ip = $data->{'ip'};
	my $chip_id = $data->{'chip_id'};
	my $name = $data->{'name'};
	my $method = $data->{'method'};
	# an explicit homebase: the address a BLE bridge is re-homing the watch to.
	# now_me's own choice trusts the watch's LAN, where two machines share a /24
	# and cannot be told apart, so the bridge names the address instead.
	my $forced_home = $data->{'homebase'};
	my $server_time = time();



	my $watch = &subs::embedded_device($timestamp, $edt, $chip_id);
	# The setting that led here is already saved. A device this machine cannot
	# reach is not an error: it takes its copy on its next state_request, or from
	# its homebase, which is the only machine that may push it anyway.
	unless ($watch->{'chip_id'}) {
		$log->info('Now Me for ' . ($chip_id || '?') . ' skipped: device not listed');
		return 'device not listed';
	}
	# A Bluetooth-only watch belongs to one machine. A different machine must not
	# rotate its homebase and authorization, or re-push the watch onto itself -
	# bluetooth_sender refuses the send anyway, so a Now Me here would only
	# desync the record. The edit that triggered it still saves; the watch gets
	# it from its homebase. Leave the record alone.
	# A Bluetooth-only watch belongs to one machine, and a machine that is not the
	# homebase must not quietly rewrite the pairing. But an EXPLICIT "BT Now Me"
	# (method 'bluetooth', the watch-row action) is the person moving the watch to
	# this machine on purpose, so let that one through - it is how you re-home a
	# watch whose homebase is gone (a phone that died) onto the machine in hand.
	# A device that answers a LAN ping is NOT BLE-only: it has a second road, and
	# every house machine shares the /24, so any of them may re-home it over HTTP.
	# Without this, a WiFi board whose homebase address moved was classed as BLE,
	# the regular Now Me skipped, and BT Now Me forced the radio - which the
	# non-owner had already yielded - so the token never refreshed.
	my $lan_alive = 0;
	if ($watch->{'ip'} && $watch->{'ip'} =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
		my $ping = `timeout .2 ping -c 1 $watch->{'ip'} 2>/dev/null`;
		$lan_alive = 1 if $ping =~ /ttl/i;
	}
	if ($watch->{'ble'} && !$lan_alive && !&subs::ble_owns($edt, $chip_id) && ($method || '') ne 'bluetooth') {
		$log->info('Now Me for ' . ($chip_id || '?') . ' skipped: homebase is ' . ($watch->{'homebase'} || '?'));
		return 'hosted elsewhere';
	}
	my $watch_port = $ENV{PORT_ARM};

	my $ws_port = $ENV{PORT_MSG};
	# The current record may have been written by a House machine of another
	# class; Now Me must read it, or a fallback machine would rewrite it blank.
	my $od = &subs::embedded_operator_door($edt, $chip_id)
		|| &subs::setting_grabber({ app => $edt, setting => 'operator_door', device => $device, subsetting => $chip_id });
	my $op_d = eval { decode_json $od } || {};
	$name = $op_d->{'__specs'}->{'name'} unless $data->{'name'};
	my $address = &subs::network_interface_reporter();
	unless (&subs::same_net_test($watch->{'homebase'},$ip,'127.0.0.1') eq 'yes') {
		foreach my $nic ( keys %{$address} ) {
			if (&subs::same_net_test($address->{$nic}->{'ip'},$ip,'override') eq 'yes') {
				$watch->{'homebase'} = $address->{$nic}->{'ip'};
			}
		}
	}
	$ip = $watch->{'homebase'};# unless $ip;

	$op_d->{'__specs'}->{'room_count'} = $op_d->{'__specs'}->{'room_count'} || &subs::setting_grabber({'app' => 'me', setting => 'room_count'}) || $op_d->{'__specs'}->{'room_count'} || 2;
	$op_d->{'__specs'}->{'homebase'} = ($forced_home || $watch->{'homebase'}) . ':' . $watch_port;
	$op_d->{'__specs'}->{'ip'} = $forced_home || $watch->{'homebase'};
	$op_d->{'__specs'}->{'edt'} = $edt;
	$op_d->{'__specs'}->{'name'} = $name;
	my @t = localtime(time);
	# $offset already carries DST: timelocal() honours the zone's DST rules, so
	# it is -4 h in summer and -5 h in winter here. The old winter branch added
	# 1000*3600 (the milliseconds in an hour) to a seconds epoch -- about 42
	# days, not an hour -- so it never did what it looked like; drop it.
	my $offset = timegm(@t) - timelocal(@t);
	$op_d->{'__specs'}->{'time'} = {
		sec => $t[0],
		min => $t[1],
		hour => $t[2],
		day => $t[3],
		month => $t[4] + 1,
		year => $t[5] + 1900
	};
	my $computer_name = &subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' }) || `hostname`;
	$computer_name =~ s/^\s+|\s+$//g;
	$op_d->{'__specs'}->{'computer'} = &manager_file_maker() || $op_d->{'__specs'}->{'homebase'};
	my $room_count = $op_d->{'__specs'}->{'room_count'};
	if ($edt eq 'watch') {
		$op_d->{'__specs'}->{'room_max'} = 6;
	}
	elsif ($edt eq 'teletype') {
		$op_d->{'__specs'}->{'room_max'} = 8;
	}
	else {
		$op_d->{'__specs'}->{'room_max'} = 1;
	}
	my $room_max = $op_d->{'__specs'}->{'room_max'};
	my $screen_timeout = ($op_d->{'__specs'}->{'screen_timeout'} || 20) * 1000;
	# the authorization rotates on every Now Me, bluetooth included now that the
	# bridge can deliver it; reusing the stored one left the phone and the watch
	# disagreeing whenever the panel ran anywhere else
	#
	# A rotation invalidates the pair the device is still holding, and the push that
	# would hand it the new one can be missed - a link that is down, a bridge that
	# is away, an endpoint that times out. Park the pair being replaced, with its
	# time, so embeddedAuthorizer can keep accepting it for a grace window and a
	# missed push costs a moment instead of locking the device out of /watch (the
	# Gate, and with it an empty room).
	if ($op_d->{'__specs'}->{'authorization'} && $op_d->{'__shutup'}->{'patience'}) {
		$op_d->{'__shutup'}->{'previous'} = {
			patience      => $op_d->{'__shutup'}->{'patience'},
			authorization => $op_d->{'__specs'}->{'authorization'},
			at            => time(),
		};
	}
	my $patience = &subs::random_string_creator(36);
	my $au = &subs::random_string_creator(27);
	my $auth = &subs::note_encrypter($patience, $au );
	my $authorization = `(echo $auth) | base64 -w 0`;
	$op_d->{'__shutup'}->{'patience'} = $patience;
	$op_d->{'__specs'}->{'authorization'} = $authorization;

	# A device that loses its homebase must still have a House to reach, so Now
	# Me carries the other machines on its LAN with the ports it dials. mDNS
	# refreshes this on the device; the list is what makes a board that cannot
	# browse mDNS (and a device whose last Now Me predates the House) recover.
	my $house_nodes = &subs::house_nodes_list($watch->{'homebase'} || $watch->{'ip'});

	my $params = {
		name           => $name,
		ip             => $watch->{ip},
		homebase       => ($forced_home || $watch->{homebase}) . ":$watch_port",
		screen_timeout => $screen_timeout,
		timestamp      => $server_time,
		offset         => $offset,
		authorization  => $authorization,
		room_count     => $room_count,
		browser_tab_id => $data->{browser_tab_id},
		room_max       => $room_max,
		# how the watch should start a voice capture: off / vad / a wake word. The
		# watch defaults to off when it is absent.
		voice_trigger  => $op_d->{'__specs'}->{'voice_trigger'},
		# the frame RMS a wake capture holds above once the voice has stopped: 'auto'
		# follows the watch's own room reading, a number pins it. Absent means auto.
		voice_floor    => $op_d->{'__specs'}->{'voice_floor'},
		# whether the guide associate's answers are spoken on the device as well as
		# shown (the Embedded panel's Audio replies toggle); absent means on
		audio_replies  => $op_d->{'__specs'}->{'audio_replies'},
		# the machine serving this device, by the name a person knows it by (the
		# same name the neighbour list shows); the watch prints it in the status bar
		computer_name  => $computer_name,
		twshomebase    => "$watch->{homebase}:$ENV{PORT_COMS}",
		thomebase      => "$watch->{homebase}:$ENV{PORT_BESTOW}",
		# encoded JSON, so it travels as one query value or one BLE field
		houses         => encode_json($house_nodes),
	};

	my $watch_home = Mojo::URL->new("http://$watch->{ip}:$config->{port}/now_me")
		->query($params)
		->to_string;

	# Bounded: a watch off its LAN has a dead IP, and an unbounded blocking fetch
	# used to sit on the whole request until the connect gave up, which the panel
	# showed as a stalled/red Now Me. A fast local device answers well inside these.
	my $ua = Mojo::UserAgent->new(connect_timeout => 3, inactivity_timeout => 5);
	foreach my $scons ( sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs} ) {
		my $gah = $scons->{'sing'};
		my $pros = &subs::db_query('select * from settings where (setting=? or setting =?) and value=?', 'pos','mab',$gah);
		my $professionals = $pros->hashes;
		$op_d->{'__specs'}->{'chat'}->{$gah} = "";
		$op_d->{'__specs'}->{'chat'}->{$gah} .= $scons->{'def'} . "\n";

		foreach my $pro ( @{$professionals} ) {
			$op_d->{'__specs'}->{'chat'}->{$gah} .= &subs::format_name($pro->{'app'}) . "\n";
		}
	}
	my $contacters = &subs::db_query('select * from tickets where status = ?', 'active' );
	my $contacts = $contacters->hashes;
	$op_d->{'__specs'}->{'chat'}->{'contacts'} = "";
	foreach my $conmen ( @{$contacts} ) {
		$op_d->{'__specs'}->{'chat'}->{'contacts'} .= $conmen->{'name'} . "\n";
	}
	$ip = $watch->{'ip'};
	my $json_op = encode_json $op_d;

	# One millisecond stamp for the local row and the peer copies: the table
	# orders by server_time, and a seconds value here (the now_me clock above is
	# in seconds) sorts below the row it is meant to replace.
	my $row_time = &subs::rightNow();
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $json_op, subsetting => $chip_id, server_time => $row_time });
	# The device probes a fallback House machine with this pair, so every peer
	# on this LAN must hold this rotation now, not on a later sync tick. Done
	# inside the request (a couple of seconds) rather than in a forked relay:
	# the prefork worker's subprocess did not reliably reach the peers.
	my $door_peers = eval { &subs::operator_door_push($edt, $chip_id, $json_op, $row_time, &subs::device_setter()) } || 0;
	$log->info('operator door push: ' . $door_peers . ' peer(s) for ' . $chip_id) if $log;
	# Which link actually carries this Now Me? An explicit 'bluetooth' asks for the
	# bridge; otherwise the watch's own LAN is tried, and a watch that answers is
	# fetched over HTTP. A watch bridged over BLE and off its access point cannot
	# answer that ping, and the push used to be dropped in silence - the Embedded
	# panel then red-dotted and the button never landed. When this machine can
	# drive the bridge and the device carries a bluetooth address, fall through to
	# the very push bt_now_me sends.
	my $link = $method && $method eq 'bluetooth' ? 'bluetooth' : undef;
	unless ($link) {
		$link = 'http' if $lan_alive;
		$link = 'bluetooth' if !$link && &subs::ble_bridge_capable() && $watch->{'mac_addresses'}->{'bluetooth'};
	}
	if ($link && $link eq 'bluetooth') {
		# The bridge client waits for the radio to acknowledge each write, and a
		# watch that has gone to sleep suspends its link without saying so: the wait
		# runs until Android's link supervision timeout. That must never happen in
		# this process - a request here, or the bridge listener's own reader when a
		# re-home lands, would hold the whole manager - and a Now Me is three sends.
		# One child carries the push; the caller only needs to know it went out.
		my ($push_edt, $push_chip) = ($edt, $chip_id);
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			eval {
				&subs::bluetooth_sender({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $push_chip,
					edt => $push_edt,
					message => { type => 'now_me', data => $params }
				});
				# The role follows the params. A watch/deck draws its buttons from the
				# room payload; a board gets the compact form (no chat lists, no
				# pairing patience) so it can be carried as plain JSON and applied
				# without a zlib inflater on the microcontroller.
				if ($push_edt eq 'microcontroller') {
					my $board_payload = &subs::board_config_payload({ edt => $push_edt, chip_id => $push_chip });
					if ($board_payload) {
						&subs::bluetooth_sender({
							intent => 'com.jawn.president.bt.connect',
							chip_id => $push_chip,
							edt => $push_edt,
							message => { type => 'board_config', data => $board_payload }
						});
					}
				}
				else {
					my $room_payload = &subs::watch_room_payload({ edt => $push_edt, chip_id => $push_chip });
					if ($room_payload) {
						&subs::bluetooth_sender({
							intent => 'com.jawn.president.bt.connect',
							chip_id => $push_chip,
							edt => $push_edt,
							message => { type => 'room', data => { room => 1, payload => $room_payload } }
						});
					}
				}
				1;
			};
		}, { name => 'now me push', fork => 1 });
		# say so, rather than fall through to the empty {} the caller then
		# rendered as HASH(0x...) and read as a button that did nothing
		return 'pushed over bluetooth';
	}
	elsif ($link && $link eq 'http') {
		my $res = $ua->insecure(1)->get($watch_home)->result;
		if ($edt eq 'microcontroller') {
			if (eval { $res->result->body }) {
				if (eval { decode_json $res->result->body }) {
					my $rb = decode_json $res->result->body;
					foreach my $info ( keys %{$rb} ) {
						$op_d->{'__specs'}->{$info} = $res->{$info};
					}
				}
			}
			$json_op = encode_json $op_d;
			&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $json_op, subsetting => $chip_id });
		}
		return $res;
	}
	return {};
}

sub marker_sessions($app) {
	my $filter = $app || '';
	my @sessions;
	my $q = &subs::db_query('select * from cache where app = ? and context = ? order by server_time desc', 'marker', 'sessions');
	foreach my $row ( @{$q->hashes} ) {
		my $session = eval { return decode_sereal $row->{'data'} } || {};
		next unless $session->{'uuid'};
		next unless $session->{'layers'};
		# the working copy autosaves the board in progress; it is not a session
		next if $session->{'working'};
		my $session_app = $session->{'app'} || 'marker';
		next if ($filter && $session_app ne $filter);
		push @sessions, {
			uuid => $session->{'uuid'},
			name => $session->{'name'},
			app => $session_app,
			layers => scalar @{$session->{'layers'}},
			server_time => $row->{'server_time'},
			thumbnail => $session->{'thumbnail'}
		};
	}
	return \@sessions;
}

sub marker_session_store($session) {
	my $timestamp = &subs::rightNow();
	# One statement, so the autosave arriving twice at once - it fires every few
	# seconds while drawing and again as the page goes away - cannot have both
	# saves delete and then both insert. The second insert met the unique key,
	# the constraint error was printed, and the drawing was quietly left at its
	# older self. The row is found by its subcontext and its uuid is the
	# session, so replacing it lets the newer words win.
	&subs::db_query(
		'insert or replace into cache (uuid,app,context,subcontext,data,timestamp,server_time,warranty,device,ost) values (?,?,?,?,?,?,?,?,?,?)',
		$session->{'uuid'}, 'marker', 'sessions', $session->{'uuid'},
		encode_sereal $session, $timestamp, $timestamp,
		&subs::ago_calc('-5y', $timestamp), '', $timestamp
	);
}

sub health_html_escape {
	my $s = defined $_[0] ? $_[0] : '';
	$s =~ s/&/&amp;/g;
	$s =~ s/</&lt;/g;
	$s =~ s/>/&gt;/g;
	$s =~ s/"/&quot;/g;
	return $s;
}

sub health_process_count {
	# The jawnos processes this tree is running, found the way the master finds
	# its own: the process's command line names a jawnos script and its working
	# directory is this tree (so a second tree on the machine is not counted).
	# Read from /proc, the same source the process monitor uses; entries we cannot
	# read (another user) are skipped.
	require Cwd;
	my $root = Cwd::getcwd();
	my $count = 0;
	for my $d ( glob('/proc/[0-9]*') ) {
		my $cwd = readlink("$d/cwd");
		next unless defined $cwd && $cwd eq $root;
		open(my $cf, '<', "$d/cmdline") or next;
		local $/;
		my $cmd = <$cf>;
		close $cf;
		next unless defined $cmd;
		$cmd =~ s/\0/ /g;
		$count++ if $cmd =~ /President\.pl|Manager\.pl|Websocket\.pl|teletype\.pl|watch\.pl|jawn-bt|Music\.pl|Alarm\.pl|pen\.pl/;
	}
	return $count;
}

sub health_report {
	my $hostname = `hostname`; chomp $hostname;
	my ($db, $database, $sql) = &subs::database_grabber();

	# The database and its write-ahead log. A WAL grown to the size of the
	# database is a reader holding a snapshot open - the one number here worth
	# watching.
	my $db_bytes  = ($database && -e $database) ? (-s $database) : 0;
	my $wal_bytes = ($database && -e $database . '-wal') ? (-s $database . '-wal') : 0;

	# The revision is frozen at boot (President.pl), so this is what the running
	# tree actually answers, not what the tree on disk holds now.
	my $revision = &subs::code_revision();

	# Each peer by name, with the version it last reported and its link state.
	my @peers;
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes || [] } ) {
		next unless $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'ip'};
		push @peers, {
			hostname    => $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'ip'} || '',
			device      => $rm->{'device'} || '',
			connection  => $rm->{'connection'} || 'unknown',
			version     => $rm->{'version'} || '',
			server_time => $rm->{'server_time'} || ''
		};
	}

	# uptime, for "how long has this been up". Android denies /proc/uptime.
	my $uptime;
	if (open(my $uf, '<', '/proc/uptime')) {
		my $ul = <$uf>;
		close $uf;
		$uptime = $1 + 0 if $ul && $ul =~ /^([\d.]+)/;
	}

	return {
		ok             => 1,
		version        => &subs::jawn_version(),
		commit         => $revision->{'commit'},
		branch         => $revision->{'branch'},
		dirty          => $revision->{'dirty'} ? 1 : 0,
		fingerprint    => $revision->{'fingerprint'},
		hostname       => $hostname,
		device         => &subs::device_setter(),
		environment    => $config->{'environment'},
		port           => $config->{'port'},
		working_port   => $config->{'working_port'},
		server_time    => &subs::rightNow(),
		uptime         => $uptime,
		schema_version => &subs::setting_grabber({ app => '__president', setting => 'schema_version' }),
		processes      => &health_process_count(),
		battery        => &subs::battery_sample(),
		usage          => &subs::system_usage_sample(),
		embedded       => &subs::embedded_levels_cached(),
		signatorial    => &subs::signatorial_designer(),
		database       => { bytes => $db_bytes, wal_bytes => $wal_bytes },
		peers          => \@peers
	};
}

sub health_allowed {
	my ($c) = @_;
	my $remote = $c->tx->remote_address // '';
	my $local  = $c->tx->local_address // '';
	# a loopback caller: the machine's own CLI and monitor, with no login
	return 1 if $remote eq $local || $remote eq '127.0.0.1' || $remote eq '::1' || $remote =~ /^::ffff:127\.0\.0\.1$/;
	# an approved session, but not a visitor's ticket: this rail writes the
	# levels every monitor reads (health_report) and exposes the backup
	# watermark (available), so a guest browser is not enough. A paired device
	# with no person of its own is the machine's own face and stays.
	my $auth = $c->session('authentication') // '';
	return 1 if $auth eq 'approved' && !&subs::guest_browser_session($c->session('privilege'), $c->session('source'));
	# a signed peer on the roster
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	return 1 if $rm && &subs::peer_verify($c, $rm);
	return 0;
}

sub health_human_bytes {
	my $n = shift || 0;
	my @u = qw(B KB MB GB TB PB);
	while ($n >= 1024 && @u > 1) { $n /= 1024; shift @u; }
	return sprintf('%.1f %s', $n, $u[0]);
}

sub health_human_uptime {
	my $s = shift;
	return 'unknown' unless defined $s;
	$s = int $s;
	my $d = int($s / 86400); $s -= $d * 86400;
	my $h = int($s / 3600);  $s -= $h * 3600;
	my $m = int($s / 60);
	return ($d ? "${d}d " : '') . sprintf('%02d:%02d', $h, $m);
}

sub ws_plain_token {
	my ($c) = @_;
	my $token = $c->stash('ws_plain_token');
	return $token if $token;
	$token = &subs::random_string_creator(32);
	my $session = $c->session || {};
	my %auth = %{$session};
	&subs::cache_set({ app => '__president', context => 'ws_token', subcontext => $token, warranty => '+7d' }, \%auth);
	$c->stash('ws_plain_token' => $token);
	return $token;
}

sub ws_plain_auth {
	my ($c) = @_;
	my $token = $c->param('ws_token');
	return unless defined $token && $token =~ /\A[A-Za-z0-9]{16,64}\z/;
	my $auth = &subs::cache_get({ app => '__president', context => 'ws_token', subcontext => $token });
	return unless ref $auth eq 'HASH' && scalar keys %{$auth};
	$c->session(%{$auth});
	return 1;
}

sub ws_url_for {
	my ($c, $path) = @_;
	my $base = $c->req->url->base;
	my $host = $base->host // '';
	my $plain = $ENV{'PORT_WS_PLAIN'} || 0;
	if ($plain && ($host eq '127.0.0.1' || $host eq 'localhost' || $host eq '::1')) {
		my $shown = ($host eq '::1') ? '[::1]' : $host;
		return 'ws://' . $shown . ':' . $plain . $path . '?ws_token=' . &ws_plain_token($c);
	}
	return 'wss://' . $host . ':' . $ENV{'PORT_MSG'} . $path;
}

sub mail_depublicizer($c) {
	my $me = &manager_file_maker($c->session('name'));
	my $publics = &subs::db_query('select * from mailbox where status=?', 'public');
	my $public = $publics->hashes;
	foreach my $p ( @{$public} ) {
		my $enc_body = &subs::note_encrypter(&subs::session_suds($c), $p->{'body'}, $p->{'timestamp'});
		&subs::db_query('update mailbox set status=?, body =? where uuid =?', 'sent', $enc_body, $p->{'uuid'});

		my %depublicized;
		foreach my $k ( keys %{$gb::social_constructs} ) {
			$depublicized{$k} = $p->{ $gb::social_constructs->{$k}->{'sing'} };
		}
		my $messenger = {
			# the client replaces a message whose uuid is already on screen,
			# so this envelope must wear the row's uuid or it only ever appends
			uuid => $p->{'uuid'},
			msg => $p->{'body'},
			timestamp => $p->{'timestamp'},
			type => 'message',
			mail_contact => $p->{'contact'},
			picker => \%depublicized,
			manager_file => $p->{'manager_file'},
			decrypted => 'yes'
		};
		$p->{'body'} = $p->{'body'};
		$p->{'decrypted'} = 'yes';
		$messenger->{'envelope'} = $c->render_to_string(
			template => 'mail/message',
			'm' => $p,
			'me' => $me
		);
		&mailws_sender($messenger);
	}

}

sub president_restarter() {
	my $trace = do { require Carp; Carp::longmess('president_restarter') };
	$log->info("president_restarter called from:\n" . $trace) if $log;
	# the caller's line names the cause better than anything this sub knows
	my ($where) = ($trace =~ /at (\S+ line \d+)/);
	&subs::restart_request('president_restarter was asked to restart' . (defined $where ? ' from ' . $where : ''));
}

sub remote_machine_reauth($c, $rm, $timestamp, $ip, $browser_tab_id, $browser_tab) {
	my $rdc = {
		# the row's manager can be a leftover loopback from a dead tunnel: log back
		# in on the name the house knows, or the repair itself dials 127.0.0.1
		manager => &subs::peer_live_manager($rm),
		filename => $rm->{'data'}->{'database'},
		timestamp => $timestamp,
		ip => $ip,
		password => &subs::session_suds($c),
		name => $c->session('name'),
		browser_tab_id => $browser_tab_id,
		browser_tab => $browser_tab,
		port => $rm->{'port'},
		signatorial => $rm->{'signatorial'},
		nic => $rm->{'nic'},
		tunnel => $rm->{'tunnel'}
	};
	$rm->{'cookie'} = undef;
	return &remote_device_connect($rdc);
}

sub sync_topology_get {
	my $v = &subs::setting_grabber({ app => 'sync', setting => 'topology', device => 'all' });
	$v = &subs::setting_grabber({ app => 'sync', setting => 'topology' }) unless defined $v && length $v;
	$v = &subs::setting_grabber({ app => '__president', setting => 'sync_topology' }) unless defined $v && length $v;
	$v = 'auto' unless defined $v && $v =~ /^(?:auto|mesh|hub)$/;
	return $v;
}

sub sync_hub_status {
	my ($hub) = @_;
	return 0 unless $hub && $hub->{'signatorial'};
	# `connection` is the reconnector's live verdict - it only reads active after
	# a successful handshake. The row's server_time can be refreshed by the very
	# sync that is stuck (a mirror or a pull carries it), so freshness alone is
	# not proof the address answers. A hub the reconnector marked inactive is not
	# a hub: the caller falls back to the mesh instead of dialling it forever.
	return 0 if (($hub->{'connection'} || '') ne 'active');
	return 0 if (&subs::rightNow() - int($hub->{'server_time'} || 0)) > 6 * 60 * 1000;
	if (($hub->{'tunnel'} || '') eq 'yes') {
		my $age = eval { &Tunnel::alive_age($hub->{'manager'}) };
		my $ports = eval { &Tunnel::alive_ports($hub->{'manager'}) };
		return 0 unless defined $age && $age < 45000 && (!defined $ports || $ports >= 1);
	}
	return 1;
}

sub sync_hub_pick {
	my ($machines, $is_hub) = @_;
	return &subs::signatorial_designer() if $is_hub;
	$machines ||= [];
	my $saved = &subs::setting_grabber({ app => '__president', setting => 'sync_hub' }) || '';
	my ($saved_row) = grep { ($_->{'signatorial'} || '') eq $saved } @{$machines};
	# An explicitly saved hub is kept only while it is a live address (the
	# reconnector's verdict) and recently heard. A saved row that has gone
	# inactive must not pin the whole house to an address nobody answers.
	my $saved_live = $saved_row
		&& (($saved_row->{'connection'} || '') eq 'active')
		&& (&subs::rightNow() - int($saved_row->{'server_time'} || 0)) < 30 * 60 * 1000;
	return $saved if $saved && $saved_live;
	# Only an active server can be chosen as a hub. With none, '' means "walk
	# the mesh": the pass then dials every known peer instead of one dead hub.
	my @servers = grep { ($_->{'device'} || '') eq 'server' && ($_->{'signatorial'} || '') && ($_->{'connection'} || '') eq 'active' } @{$machines};
	return '' unless scalar @servers;
	my ($best) = sort { int($b->{'server_time'} || 0) <=> int($a->{'server_time'} || 0) } @servers;
	return '' unless $best;
	if (($best->{'signatorial'} || '') ne $saved) {
		&subs::setting_setter({ app => '__president', setting => 'sync_hub', value => $best->{'signatorial'} });
	}
	return $best->{'signatorial'} || '';
}

1;
