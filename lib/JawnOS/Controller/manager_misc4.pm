package Manager;

# manager_misc4: route actions moved out of Manager.pl, one sub per route so a
# route can be read and changed without opening the whole file. The package
# is still Manager, so unqualified calls to its helpers and its package
# state work exactly as they did in the single file.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use strict;
use warnings ;#'uninitialized';
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

# WEBSOCKET /manager/tunnel/ws
sub action_12377 {
	my $c = shift;
	# A peer behind NAT dials out here and names itself with the same
	# signatorial the sibling tunnel routes (request/confirm/close) use. The
	# hub only serves a signatorial it already knows as a remote machine.
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm) {
		$c->rendered(403);
		return;
	}
	# A signatorial is a name, not a secret - it rides in query strings and in the
	# mirror lists peers share - so a rostered name alone is not enough: the peer
	# must also sign the handshake, exactly like every request on the HTTP peer
	# rail. peer_verify pins the key on first contact and refuses a changed key.
	unless (&subs::peer_verify($c, $rm)) {
		$c->rendered(403);
		return;
	}
	$c->rendered(101);
	# The peer's reserved ports live in its tunnels rows: in_port is the port
	# reserved on this hub, out_port the service on the peer. The hub listens on
	# in_port and forwards to the peer's out_port (tunnel.pl hub_session).
	my $tuns = &subs::db_select('tunnels', undef, { signatorial => $signatorial, status => 'active' })->hashes || [];
	my %listen;
	foreach my $t ( @{$tuns} ) {
		next unless $t->{'name'} && $t->{'in_port'};
		$listen{$t->{'name'}} = { source => $t->{'in_port'}, dest => $t->{'out_port'} };
	}
	&Tunnel::hub_session($c->tx, { signatorial => $signatorial, listen => \%listen });
	# The tunnel data plane is up now: enrol (or refresh) the peer immediately
	# rather than waiting for the 5-minute tunnel_checker loop, so a headless hub
	# can remote_upgrade / remote_relay_request it the moment it dials in. Forked
	# so the blocking sesh_check never stalls the websocket loop.
	&subs::subprocessor(sub {
		sleep 1;  # let the peer's peer_session settle before we dial it
		&subs::tunnel_peer_enrol($signatorial);
	}, { name => 'tunnel peer enrol ' . substr($signatorial, 0, 8) });
}

# POST /manager/tunnel/alive
sub action_12416 {
	my $c = shift;
	my $chip_chyea = $c->param('chip_chyea');
	my $signatorial = $c->param('signatorial');
	# This route sits on the gate-exempt peer rail (hooks.pl) so a tunnelled peer
	# whose session has lapsed can still prove its data plane. Exempt is not open:
	# the caller signs the request like every other peer-rail call (the checker
	# posts it on remote_useragent_maker's UA), so authenticate it against the
	# roster row it names - without this, anyone quoting a signatorial could make
	# this hub dial every peer it knows with an attacker's chip_chyea.
	my $self_row = &subs::db_query('select * from remote_machines where signatorial = ?', $signatorial)->hashes->[-1];
	unless ($self_row && &subs::peer_verify($c, $self_row)) {
		$c->rendered(403);
		return;
	}
	my $network = $c->param('network');
	my $interval = $c->param('interval');
	my $remote_address = $c->tx->remote_address;
	my $remote_machines = &subs::remote_machine_lister();
	foreach my $rm ( @{$remote_machines} ) {
		my $data = { signatorial => $rm->{'signatorial'}, rm => $rm };
		if ($signatorial eq $rm->{'signatorial'}) {
			$data->{'chip_chyea'} = $chip_chyea;
			if ($network) {

				my $net = eval { return decode_json $network } || {};
				$net->{'public_address'} = $remote_address;

				$network = encode_json $net;
				$rm->{'network'} = $network;
				$data->{'rm'}->{'network'} = $network;
				my $update = { server_time => &subs::rightNow(), network => $network };
				# Remember the tailnet address while the VPN is up: the live map
				# drops the interface when it goes down, and then the peer has no
				# route off the LAN to be probed.
				my $tailnet = &subs::tailnet_address($rm);
				$update->{'tailnet_ip'} = $tailnet if $tailnet;
				&subs::db_update('remote_machines', $update, { signatorial => $rm->{'signatorial'} });
			}
		}
		$rm = &remote_useragent_maker($data);
	}

	$c->render(json => {
		chip_chyea => $chip_chyea,
		signatorial => $signatorial,
		mirrors => [ grep { defined $_ } map { &subs::remote_machine_mirror_row($_) } @{$remote_machines} ]
	});
}

# POST /manager/neighbour_status
sub action_12483 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $status = $c->param('status');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $remote_machines = &subs::db_query('select * from remote_machines where ip=?', $ip);
	my $re_ma = $remote_machines->hashes;
	my $rm = $re_ma->[-1];

	if ($rm->{'status'} eq 'mirror') {
		$rm->{'status'} = 'off';
	}
	else {
		$rm->{'status'} = 'mirror';
	}
	&subs::db_update('remote_machines', { status => $rm->{'status'} }, { ip => $ip });
	# The panel reads only the toggled state; the rest of the row (including the
	# peer's session cookie and login blob) has no business leaving this machine.
	$c->render(json => { status => $rm->{'status'}, ip => $rm->{'ip'} });
	my $remote_address = $c->tx->remote_address;
	`timeout .5 ping -c 1 $remote_address`;
}

# POST /manager/nfc/read
sub action_12622 {
	my $c = shift;
	my $jmessage = $c->param('message');
	my $serial = $c->param('serial');
	my $last_write = $c->param('last_write');
	my $timestamp = $c->param('timestamp');
	my $benign = $c->param('benign');
	my $response = { status => 'unknown' };
	my $uuid = $c->param('uuid') || &subs::random_string_creator(25);
	$c->param('uuid' => $uuid );
	# A relayed copy is a peer's copy of the tap. It carries the reader's action
	# (nfc_actions, keyed by the message uuid), so it applies the same start or
	# stop the reading machine chose instead of recomputing one from its own,
	# possibly unsynced, toggle state. Non-stop actions write under the tap uuid,
	# so every copy names the same row and the mesh converges on it rather than
	# collecting duplicates.
	my $relayed = ($c->param('relay_id') || ($c->param('remoted') || '') eq 'yes' || ($c->param('dissemination') || '') eq 'yes' || $c->param('source_signatorial')) ? 1 : 0;
	my $relayed_actions = ($relayed && $c->param('nfc_actions')) ? (eval { decode_json $c->param('nfc_actions') } || {}) : {};
	my $actions = {};
	my $msg = eval { return decode_json $jmessage } || [];

	foreach my $message ( @{$msg} ) {
		if (ref $message eq 'HASH' && defined $message->{'crest_code'}) {
			my $result = &people_crest_import_code($c, $message->{'crest_code'});
			$response->{'status'} = $result->{'ok'}
				? ($result->{'construct_app'}
					? ('Crest: ' . ($result->{'construct_name'} || ''))
					: ('Crest imported: ' . ($result->{'crest'}->{'name'} || '')))
				: ('Crest import failed: ' . ($result->{'error'} || 'unknown'));
			if ($result->{'ok'}) {
				$response->{'crest_uuid'} = $result->{'crest'}->{'uuid'} || '';
				$response->{'crest_known'} = $result->{'known'} ? 1 : 0;
				$response->{'construct_app'} = $result->{'construct_app'} if length($result->{'construct_app'} || '');
			}
			next;
		}
		# A tag carries either the full row uuid (older writes) or a short `tag`
		# (the row uuid's first twelve characters). The short form is what a
		# 144-byte NTAG213 can hold; find the row by whichever the tag has.
		my $tag = $message->{'tag'} // '';
		next unless length($tag) || length($message->{'uuid'} // '');
		my $nfcs = length($tag)
			? &subs::db_query('select * from settings where setting=? and value like ? and device=?', 'nfc', '%"uuid":"' . $tag . '%', &subs::device_setter())->hashes->[0]
			: undef;
		$nfcs ||= &subs::db_query('select * from settings where setting=? and value like ? and device=?', 'nfc', '%' . ($message->{'uuid'} // '') . '%', &subs::device_setter())->hashes->[0];
		next unless $nfcs && $nfcs->{'app'};
		my $app = $nfcs->{'app'};
		my $settings = &subs::settings_grabber({ app => $app });

		my $nfc = eval { return decode_json $nfcs->{'value'} } || [];
		my ($n) = length($tag)
			? grep { index($_->{'uuid'} || '', $tag) == 0 } @{$nfc}
			: grep { ($_->{'uuid'} || '') eq ($message->{'uuid'} // '') } @{$nfc};
		next unless $n && $n->{'uuid'};
		# The short tag names the row; the rest of the route and the relay
		# speak the full uuid, so every machine writes one action key.
		$message->{'uuid'} = $n->{'uuid'};
		$n->{'serials'} = [] unless ref $n->{'serials'} eq 'ARRAY';
		if ($n->{'uuid'}) {
			if (defined $last_write && length $last_write && $timestamp - $last_write < 2500) {
				$response->{'status'} = 'writing serial';


				# Serials arrive in different shapes (Chrome's colon-separated
				# hex, the app's plain hex), so store one normalized form.
				my $norm = lc($serial // '');
				$norm =~ s/[^0-9a-f]//g;
				$norm = $serial if $norm eq '' && length($serial // '');
				push @{$n->{'serials'}}, $norm unless !length($norm) || grep { (ref $_ eq 'HASH' ? ($_->{'serial'} // '') : $_) eq $norm } @{$n->{'serials'}};
				$response->{'serials'} = $n->{'serials'};
			} else {
				if (1 == 1 || grep { $_ eq $serial } @{$n->{'serials'}}) {
					my ($type,$target);
					if ($relayed) {
						my $action = $relayed_actions->{$message->{'uuid'}} || {};
						$type = $action->{'type'};
						$target = $action->{'target'};
						# a stop with no named session has nothing to close, and the
						# unnamed fallback could close a different, stale row here
						$type = undef if $type && $type eq 'stop' && !$target;
					}
					else {
						$type = $n->{'control'};
						my $tog = &subs::appt_toggle_checker($app);
						if ($type eq 'start' || $type eq 'record') {
							# The house keeps one tag per app, and the same tag is the stop:
							# a tap while the app's session is open closes it (the stop names
							# that session below, so it never sweeps another app's rows).
							# With nothing open the tap starts as usual.
							if ($tog eq 'on') {
								$type = 'stop';
								$tog = 'off';
							}
							else {
								$tog = 'on';
							}
						}
						elsif ($type eq 'command') {
							if ($tog eq 'on') {
								if ($settings->{'kill'}) {
									$type = 'kill';
									$tog = 'off';
								}
								else {
									$tog = 'off';
									$type = 'stop';
								}
							}
							else {
								$tog = 'on';
							}
						}
						# A stop names the session the header shows (the newest open row),
						# never the tag/message uuid. Every other action uses the tap uuid,
						# which travels with the relay so every machine writes one row.
						$target = ($type eq 'stop') ? &subs::open_session_uuid($nfcs->{'app'}) : $uuid;
					}

					if ($type) {
						$response->{'status'} = $nfcs->{'app'} . ' ' . $type;
						if ($benign ne 'on') {
							$n->{'taps'} += 1;
							$actions->{$message->{'uuid'}} = { type => $type, target => $target } unless $relayed || ($type eq 'stop' && !$target);
							&appointment_writer($c, {
								app => $nfcs->{'app'},
								type => $type,
								timestamp => $timestamp,
								uuid => $target
							});
						}
					}
				}
			}
			my $jn = encode_json $nfc;
			&subs::setting_setter({ app => $nfcs->{'app'}, setting => 'nfc', value => $jn });
		}
	}
	# the actions are known now, so a peer can apply exactly these; a benign read
	# relays an empty map and acts nowhere. The map rides the relay explicitly:
	# $c->param writes a combined copy that remote_relay_request does not read.
	my $relay_actions = $relayed ? $c->param('nfc_actions') : encode_json $actions;
	my $relay_extra = { dissemination => 'yes' };
	$relay_extra->{'nfc_actions'} = $relay_actions if defined $relay_actions;
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		&remote_relay_request($c, $relay_extra);
	}, { name => 'nfc remote relay' });
	$c->render(json => $response);
}

# POST /manager/nfc/write
sub action_12771 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	my $type = $c->param('type');
	my $signatorial = $c->param('signatorial');
	my $nfc = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'nfc' }) } || [];

	my ($n) = grep { ($_->{'uuid'} || '') eq ($uuid // '') } @{$nfc};
	return $c->render(json => { ok => 0, error => 'no such tag' }) unless $n && $n->{'uuid'};

	# The tag holds only its uuid prefix now (a whole settings row no longer
	# fits a 144-byte NTAG213), so there is no serial to stamp here. Record
	# the write for the panel; the row's own settings are left alone.
	$n->{'written'} = &subs::rightNow();
	&subs::setting_setter({ app => $app, setting => 'nfc', value => encode_json $nfc });

	$c->render(json => { ok => 1, tag => substr($n->{'uuid'}, 0, 12), nfc => { uuid => $n->{'uuid'} } });
}

# POST /manager/leave
sub action_12791 {
	my $c = shift;
	# The gate is drawn from the house this request is about to close. leave()
	# takes the database away, so what the template reads from it is read here,
	# while it is still there - the passkey list above all. Reading it after the
	# shred killed the render, and with it the reply, on the live image.
	my $webauthn_available = (scalar @{ &webauthn::credentials() } ? 1 : 0);
	my $left = &leave($c);
	# A failed seal is not a leave: keep the session and the database, and
	# tell the dialog why nothing happened instead of drawing the gate over a
	# house that is still open.
	if (ref $left eq 'HASH' && !$left->{'ok'}) {
		return $c->render(status => 500, json => { ok => 0, error => ($left->{'error'} || 'Could not seal the database; it was kept.') });
	}
	# leave() shredded the live database; the gate lists the sealed copies the
	# seal just wrote, and opening the house again here only made a 0-byte file.
	my $restore_list = &subs::restore_list();
	if ($c->param('restore_list')) {
		my $list = $c->param('restore_list');
		$restore_list = &subs::restore_list($list);
		@{$restore_list} = grep { $_->{'filename'} =~ /enc$/gi } @{$restore_list};
	}

	$c->render(
		template => 'gate',
		layout => 'gate',
		restore_list => $restore_list,
		webauthn_available => $webauthn_available,
		# the gate carries no home path: it is shown before anyone has signed in, and
		# a field prefilled with the person's own directory hands a visitor their name
		start_dir => '',
		config => { 'gate' => {'background_colour' => 'grey' } },
	);
}

# POST /manager/lock_session
sub action_12848 {
	my $c = shift;
	my $scope = $c->param('scope') || '';
	my $posted = $c->param('device_uuid') || '';
	# The page identifies with the uuid in its localStorage, which can be newer
	# than the session's (a re-pair, or another tab's pairing). Locking the
	# session's uuid then targeted a screen the page no longer claimed, and the
	# overlay's target check ignored it - "I locked it and still have access".
	# Adopt the posted, roster-validated device so the lock and the page agree.
	if ($posted && &subs::db_select('paired_devices', undef, { uuid => $posted, status => 'active' })->hashes->[0]) {
		$c->session('device_uuid' => $posted);
	}
	&lock_session($c, 1, $scope);
	# a single-screen lock stays on that screen; only an explicit whole-house
	# lock is handed to the peers
	&remote_relay_request($c) if $scope eq 'all';
	# The screen that pressed the lock shows its own overlay from this reply.
	# The websocket push is the cross-screen path, but on a handheld its unix
	# socket can be owned by another worker, so the send silently went nowhere
	# and the screen that locked stayed open until a reload ("it didn't lock").
	my $target = $scope eq 'all' ? '' : ($c->session('device_uuid') || $posted || '');
	my $html = $c->render_to_string(
		template => 'locked_screen',
		target => $target,
		fingerprint => (&fingerprint_available() && &padlock_request_is_local($c)) ? 1 : 0,
		biometric => &biometric_enrolled_for($c->session('device_uuid') || $target)
	);
	$c->render(json => { ok => 1, target => $target, html => $html });
}

# GET /manager
sub action_13070 {
	my $c = shift;

	# A controller has no desk to lay windows on: its own page is the home, and
	# that is where the panel opens. A redirect rather than a different render,
	# so the launcher keeps one address; it stays on the same origin, so the
	# ticket's session cookie already set here carries the person straight in.
	return $c->redirect_to('/manager/controller') if &subs::device_setter() eq 'controller';

	my ($db,$database,$sql) = &subs::database_grabber();
	my $hostname = &subs::machine_hostname();
	sub jonathan_to_jawn() {
		my $jonathans = `ls images/jonathans`;

		my @jonathans = split "\n";
		my @jawns = [];

		foreach my $jonathan ( @jonathans ) {
			push @jawns, {
				file => $jonathan
			};
		}
	}
	my $advertise_watching = &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' });
	my $pseudonyms = &pseudonym_maker('manager','');


	my $phtml = $c->render_to_string(
		template => 'pseudonyms',
		config => &subs::config_reader(),
		pseudonyms => $pseudonyms,
		device => $device
	);
	my ($website,$header) = &website_preloader($c);

	my $my_name = &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	my $ws_url = &ws_url_for($c, '/manager/ws');
	my $mail_ws_url = &ws_url_for($c, '/mail/ws');
	my $paperboy_url = &ws_url_for($c, '/observer/ws');
	my $padlock = &subs::db_select('security', ['level'], { level => 'padlock' })->hashes;
	my $parking_lot = &parking_lot_grabber($c);
	# a manager page is never a page to keep: Back must ask the house, not a
	# browser cache, whether the screen is still open
	$c->res->headers->cache_control('no-store, max-age=0');

	$c->render(
		pseudonyms => $pseudonyms,
		bar => $phtml,
		layout => 'manager',
		title => &subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' }) || $hostname,
		template => 'manager',
		manager_file => &manager_file_maker($c->session('name')),
		config => &subs::config_reader(),
		website => $website,
		my_name => $my_name,
		'device' => $device,
		signatorial => &subs::signatorial_designer(),
		'ws_url' => $ws_url,
		mail_ws_url => $mail_ws_url,
		paperboy_url => $paperboy_url,
		advertise_watching => $advertise_watching,
		padlock => $padlock,
		header => $header,
		menu => 'running'
	);
}

# GET /manager/window_retriever
sub action_13131 {
	my $c = shift;
	my $ticket_uuid = $c->session('ticket_uuid');
	my $user_agent = $c->param('user_agent');
	my $wsq = &subs::db_query('select distinct(app) as app,* from websockets where ticket_uuid = ? and user_agent = ? order by server_time desc LIMIT 20', $ticket_uuid, $user_agent)->hashes;
	my @actuals = grep { $_->{'browser_tab_id'} eq $c->param('browser_tab_id') } @{$wsq};
	if (scalar @actuals > 0) {
		@{$wsq} = @actuals;
	}
	my $returner = { 'tab' => {}, 'server' => {}, 'music' => {} };
	foreach my $ws ( @{$wsq} ) {
		if ( $ws->{'app'} eq 'tab' && $ws->{'windows'}) {
			$returner->{$ws->{'app'}} = $ws;
		}
	}


	$c->render(json => $returner);
}

# GET /manager/start_menu
sub action_13150 {
	my $c = shift;
	my $start_menu = &start_menu_maker($c);
	$c->render(json => $start_menu);
}

# A press in the app menu says what it opened, and the recent list - the app
# menu's front page - is written from it, so the next open leads with it.
# POST /manager/start_menu/used
sub action_13157 {
	my $c = shift;
	my $recent = &start_menu_used($c->param('used'));
	$c->render(json => { recent => $recent });
}

# The X on a recent item takes the app back off the list, which is only ever
# the cache rewritten without it.
# POST /manager/start_menu/forget
sub action_13164 {
	my $c = shift;
	my $recent = &start_menu_forget($c->param('forget'));
	$c->render(json => { recent => $recent });
}

# GET /manager/start_menu/htop_viewer
sub action_13286 {
	my $c = shift;
	# The card is on screen: keep the house levels loop on its quick cadence.
	&subs::levels_fast_request();
	my $cache = &subs::cache_get({ app => '__president', context => 'htop', subcontext => 'current' });
	# The card is a house-wide levels view: this machine, every peer that
	# answered the last levels pass, and the embedded boards any of them can
	# see. It reads the cached snapshot so a sleeping board cannot hold the menu.
	my $levels = &subs::levels_snapshot();
	my $html = $c->render_to_string(
		template => 'start_menu/htop',
		cache => $cache,
		levels => $levels
	);
	$c->render(json => { html => $html });
}

# GET /manager/qrcode_generator
sub action_13872 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $peer_signatorial = &ticket_peer_signatorial($c);
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $name = &subs::unformat_name($c->param('name') || 'visitor');
	my $privilege = $c->param('privilege') || 'visitor';
	my $project = $c->param('project');
	my $debriefer = $c->param('debriefer');
	my $nic = $c->param('nic');
	my $warranty = $c->param('warranty');

	my $data = &qrcode_generator({
		timestamp => $timestamp,
		app => $app,
		name => $name,
		privilege => $privilege,
		project => $project,
		debriefer => $debriefer,
		nic => $nic,
		warranty => $warranty,
		# a ticket minted by the peer window must not move the desk's default
		keep_warranty => $c->param('keep_warranty'),
		peer_signatorial => $peer_signatorial,
	});
	&subs::db_insert('tickets', $data);
	&subs::setting_setter({ app => 'box_office', setting => 'last_privilege', value => $privilege });
	&subs::setting_setter({ app => 'box_office', setting => 'last_nic', value => $nic });
	&subs::setting_setter({ app => 'box_office', setting => 'last_name', value => $name });
	$c->render(json => $data);
}

# Upgrading a holder is the box office's act too: the chair is the ticket's,
# and the next time the link is opened the session wears the new privilege.
# POST /manager/ticket_privilege
sub action_14367 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $uuid = $c->param('uuid');
	my $privilege = $c->param('privilege');
	unless ($uuid && $gb::chairs->{$privilege}) {
		$c->render(json => { error => 'bad request' });
		return;
	}
	&subs::db_update('tickets', { privilege => $privilege, server_time => &subs::rightNow() }, { uuid => $uuid });
	$c->render(json => { uuid => $uuid, privilege => $privilege });
}

# GET /manager/delete_ticket
sub action_14550 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');

	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::db_delete('tickets', { uuid => $uuid });
	$c->render('json' => { uuid => $uuid });
}

# GET /manager/suspend_ticket
sub action_14563 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::db_query('update tickets set status=? where uuid=?','suspended',$uuid);
	$c->render('json' => { uuid => $uuid });
}

# GET /manager/renew_ticket
sub action_14575 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $warranty = $c->param('warranty');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $tick = &subs::db_query('select * from tickets where uuid=?', $uuid);
	my $ticke = $tick->hashes;
	my $ticket = $ticke->[0];
	$warranty = &subs::ago_calc($warranty,$timestamp);
	my $total_duration = ($warranty - $ticket->{'timestamp'});
	my $new_warranty = ($ticket->{'duration'} + $timestamp);
	&subs::db_update('tickets', { status => 'active', duration => $total_duration, warranty => $warranty }, { uuid => $uuid });

	$c->render('json' => $ticket);
}

# GET /manager/reinstate_ticket
sub action_14595 {
	my $c = shift;
	unless (&ticket_desk_allowed($c)) {
		$c->render(json => { error => 'denied' });
		return;
	}
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $data = { status => 'active' };
	&subs::db_update('tickets', $data, { uuid => $uuid });
	$c->render('json' => $data);
}

# GET /manager/random_word
sub action_14630 {
	my $c = shift;
	my $rw = &random_word_grabber($c->param('times'));
	$c->render( text => $rw );
}

# POST /manager/cache_set
sub action_14686 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $context = $c->param('context');
	my $subcontext = $c->param('subcontext');
	my $data = eval { return decode_json $c->param('data') } || {};

	&subs::cache_set({ app => $app, context => $context, subcontext => $subcontext, timestamp => $timestamp }, $data);
	$c->render('text' => 'ok');
}

# POST /manager/cache_delete
sub action_14697 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $context = $c->param('context');
	my $subcontext = $c->param('subcontext');
	&subs::cache_delete({ app => $app, context => $context, subcontext => $subcontext });
	$c->render('text' => 'deleted');
}

# GET /manager/cache_get
sub action_14706 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $context = $c->param('context');
	my $subcontext = $c->param('subcontext');
	my $cache = &subs::cache_get({ app => $app, context => $context, subcontext => $subcontext });
	$c->render(json => $cache);
}

# POST /manager/power
sub action_20001 {
	my $c = shift;
	# This can stop the machine, so it is a citizen's alone; the hook's tier
	# check is the first lock and this is the second.
	unless (($c->session('privilege') || '') eq 'citizen') {
		return $c->render(status => 403, json => { ok => 0, error => 'citizen only' });
	}
	my $result = &subs::power_action($c->param('action'));
	$c->render(json => $result);
}

1;
