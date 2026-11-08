package Manager;

# manager_ws: route actions moved out of Manager.pl, one sub per route so a
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

# WEBSOCKET /manager/ws
sub action_47050 {
	my $c = shift;
	&ws_plain_auth($c);
	my $ug    = Data::UUID->new;
	my $uuid = $ug->create_str();
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = $c->param('app');
	unless ($ws_server->{$app}) {
		$ws_server->{$app} = &ws_server_socket({ app => $app });
	}
	my $remote_address = $c->tx->remote_address;
#	$c->render(template => 'guest_layouts/denial') unless $app eq 'music' || $app eq 'server' || $app eq 'tab';
	my $timestamp = $c->param('timestamp');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $browser_tab = $c->param('browser_tab');
	my $me_settings = &subs::settings_grabber({ app => 'me', settings => [ 'computer_name', 'log_me' ] });
	my $computer_name = &subs::config_reader()->{'name'} || $me_settings->{'computer_name'};
	my $log_me = $me_settings->{'log_me'} || '';
	if ($c->param('browser_tab_id') eq '') {
		$c->render('text' => 'no');
		return;
	}
	my $user_agent = $c->param('user_agent') || $gb::user_agent;

	my $server_time = &subs::rightNow();
	my $hostname = `hostname`;
	chomp($hostname);
	my $connection_id = $c->tx;
	$connection_id = $connection_id->connection;
	my $code_rev = &subs::code_revision();
	# The tree's boot, so the client can tell a restart from a socket that merely
	# flapped. A restart clears every media grant (padlock_seed_default); the pid
	# file is written once by the master at boot, so its pid and mtime change only
	# then. Keyed on both, because a quick restart can reuse a pid.
	my $boot_file = &subs::home('~/.president/pid');
	my $boot_stamp = '';
	if (-e $boot_file) {
		my $boot_pid = eval { read_file($boot_file) } // '';
		$boot_pid =~ s/\s+//g;
		$boot_stamp = ((stat($boot_file))[9] || 0) . '-' . $boot_pid;
	}
	my $init_data = {
		browser_tab_id => $browser_tab_id,
		browser_tab => $browser_tab,
		db => $database,
		'uuid' => $uuid,
		timestamp => $timestamp,
		connected => $timestamp,
		server_time => $server_time,
		type => 'connect',
		app => $app,
		hostname => $hostname,
		connection_id => $connection_id,
		user_agent => $user_agent,
		random_string => &subs::random_string_creator(25),
		# the code this machine is running; the client follows it when it changes -
		# part by part, so it knows whether a stylesheet, a template, a script or
		# the shell moved (see jawnosRevisionArrived in websocket.js). The parts and
		# the version ride the wire only, added just before the send: the websockets
		# row is a session record, not a home for the code's state, and the table
		# has no columns for them (an insert that carries them is refused).
		revision => ($code_rev->{'commit'} || $code_rev->{'fingerprint'}),
		href => $c->param('href'),
		pathname => $c->param('pathname'),
		ticket_uuid => $c->session('ticket_uuid')
	};
	if (($c->param('remote') || '') eq 'yes') {
		my @app = split /\@/, $app;
		my $sapp = $app[0];
		$gb::remote_ws->{$sapp}->{$browser_tab_id} = $c->tx;
	}
	else {

	}
	$gb::ws->{$app}->{$browser_tab_id} = $c->tx;
	$gb::ws->{$app}->{$browser_tab_id}->{'privilege'} = $c->session('privilege');
	$gb::ws->{$app}->{$browser_tab_id}->{'device_uuid'} = $c->session('device_uuid') || '';
	my $tab_check = &subs::db_query('select * from websockets where browser_tab_id = ? and remote_address = ? and app = ?',$browser_tab_id, $remote_address, $app );
	my $existing_websockets = $tab_check->hashes;

	unless (scalar @{$existing_websockets} > 0) {
		my $app = $c->session('app');
		my $app_warranty = &subs::setting_grabber({ app => $app, setting => 'warranty' });
		my $warranty = &subs::ago_calc($app_warranty || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time);
		$init_data->{'warranty'} = $warranty;
		&subs::db_insert('websockets', $init_data);

	}
	else {



	}



	# the wire carries what the row must not: the change-tracking parts and the
	# version the client compares before deciding how to follow an update
	$init_data->{'revision_parts'} = $code_rev->{'parts'};
	$init_data->{'version'} = &subs::jawn_version();
	# the boot rides the wire like the revision: the websockets row is a session
	# record, and an insert that carries a column the table does not have is
	# refused
	$init_data->{'boot'} = $boot_stamp;
	&Websocket::send($app, $init_data);
	if ($c->param('app') eq 'music') {
		if ($log_me eq 'on') {
			my $appts = &subs::db_query('select * from appointments where source_uuid = ? and app = ? order by timestamp desc limit 30', $browser_tab, $computer_name)->hashes;
			my $resolved = 0;
			if (scalar @{$appts} > 0) {
				foreach my $appt ( @{$appts } ) {
					if ($appt->{'type'} eq 'stop') {
						if (($appt->{'timestamp'} - $appt->{'duration'}) > &subs::rightNow() - 120000) {
							$resolved = 1;
							# A reopen is open again: `stop_seen is null` is what stop_target_row and
							# open_session_uuid read, so the stop's 'yes' must go with the type. Left
							# on, the row was a 'start' that no later stop could name - the socket
							# close then matched nothing and the desk session ran on forever.
							&subs::db_update('appointments', { server_time => &subs::rightNow(), type => 'start', stop_seen => undef, stop_timestamp => undef }, { uuid => $appt->{'uuid'}, app => $appt->{'app'} });
							&subs::intelligent_automation_toggle({ appt_uuid => $appt->{'uuid'}, app => $appt->{'app'}, 'state' => 'on', timestamp => $timestamp });
							&subs::appt_header_printer({ app => $appt->{'app'} });
							&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $appt->{'app'}, $appt->{'uuid'})});
							my $sources = &subs::db_select('appointments', undef, { source_uuid => $appt->{'uuid'} })->hashes;
							my %so_seen;
							my %child_apps;
							foreach my $so ( @{$sources} ) {
								next if $so_seen{ $so->{'uuid'} }++;
								push @{$sources}, @{&subs::db_select('appointments', undef, { source_uuid => $so->{'uuid'} })->hashes};
								if ( $so->{'type'} eq 'stop' ) {
									my $dur = $so->{'timestamp'} - $timestamp;
									&subs::db_update('appointments', { stop_seen => undef, stop_timestamp => undef, type => 'start', duration => $dur, server_time => $server_time }, { source_uuid => $so->{'source_uuid'}, uuid => $so->{'uuid'}, app => $so->{'app'} });
									$child_apps{ $so->{'app'} } = 1;
									&budget_runner($so->{'app'});
									&subs::intelligent_automation_toggle({ appt_uuid => $so->{'uuid'}, app => $so->{'app'}, 'state' => 'on', timestamp => $timestamp });
									&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $so->{'app'}, $so->{'uuid'})});
								}
							}
							&subs::source_header_printer([ keys %child_apps ], $timestamp);
						}
					}
					elsif ($appt->{'type'} eq 'start') {
						$resolved = 1;
					}
				}
			}

			if ($resolved == 0) {
				my $jdata = encode_json { duty_time => $gb::duty_time };
				my $data = {
					app => $computer_name,
					type => 'start',
					data => $jdata,
					timestamp => $timestamp,
					source_uuid => $browser_tab
				};
				&appointment_writer($c,$data);
			}
		}
	}
#	$c->send({json => $init_data});

	# The beat is the busiest thing an open tab does. Writing the row on every
	# beat turned an idle tab into a steady stream of SQLite writes, so remember
	# what was written and write again only when something changed. The liveness
	# column is refreshed on a slow cadence so a crashed tab still ages out.
	my %ws_written;
	my $ws_write_refresh = 30000;
	my %ws_lockdown_state;
	my %ws_lockdown_swept;
	my ($ws_neighbour_stamp, $ws_neighbour_at) = ('', 0);
	my $ws_neighbour_refresh = 20000;
	$c->on(message => sub ($ws, $msg) {
		my $data = eval { return decode_json $msg };
		# A frame that omits app/type/method used to reach the eq chains below
		# undefined, warning once per comparison - thousands per minute on a busy
		# socket, and a warning flood is what fills the pty and blocks the worker
		# that wrote it. Normalise the three keys once, here.
		$data = {} unless ref $data eq 'HASH';
		$data->{'app'} = '' unless defined $data->{'app'};
		$data->{'type'} = '' unless defined $data->{'type'};
		$data->{'method'} = '' unless defined $data->{'method'};
		my $app = $data->{'app'};
		my $apper = $data->{'app'};
		if ($app =~ /@/gi) {
			my @app = split /\@/, $app;
			$apper = $app[0];
		}
		unless ($ws_server->{$app}) {
			$ws_server->{$app} = &ws_server_socket({ app => $app });
		}
		my $remote_machines;
		if ($data->{'type'} eq 'stayingAlive') {
			my $server_time = &subs::rightNow();
			$timestamp = $data->{'timestamp'};
			my $connection = $ws->tx;
			my $connection_id = $connection->connection;
			my $local_address = $ws->tx->local_address;
			my $remote_address = $ws->tx->remote_address;
			# The controller is the only view that renders neighbours. While it is
			# shut, a beat only has to prove the socket is alive.
			my $controller_visible = (($data->{'controller_visible'} || '') eq 'yes') ? 1 : 0;
			if ($app eq 'music') {
				$data->{'music_data'} = encode_json $data->{'music_data'} if $data->{'music_data'};
			}
			if ($app eq 'server') {
				$data->{'jp_data'} = encode_json $data->{'jp_data'} if $data->{'jp_data'};
			#	my $remote_upgrade = &subs::setting_grabber({ app => '__president', setting => 'remote_upgrade' });
			#	my $remote_connect_timer =  &subs::setting_grabber({ app => '__president', setting => 'remote_connect_timer' });
			#	if ($remote_connect_timer + (60 * 7 * 1000) < $timestamp) {
			#		&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
			#	}
			#	if ($remote_upgrade ne 'running' && $remote_connect_timer + 30000 < $timestamp) {
			#		&remote_machine_reconnector($c);
			#	}
				if ($controller_visible) {
					my $remote_machine_query = &subs::db_query('select buttons,uuid,status,signatorial,ip,data,connection,fqdn from remote_machines' );
					$remote_machines = $remote_machine_query->hashes;
					foreach my $rm ( @{$remote_machines} ) {
						$rm->{'data'} = eval { return decode_json $rm->{'data'} } || {};
					}
				}

			}
			if ($app eq 'tab') {
				if ($data->{'windows'}) {
					my $windows = eval { return decode_json $data->{'windows'} } || [];

					foreach my $w ( keys %{$windows} ) {
						foreach my $set ( qw/scrollTop jopen/ ) {
							# jopen rides its own act frame now. A beat that carries only
							# geometry must not write a null over the panels on disk.
							next unless defined $windows->{$w}->{$set};
							if ($set eq 'jopen') {
								$windows->{$w}->{$set} = encode_json $windows->{$w}->{$set};
							}
							&subs::setting_setter({ app => $windows->{$w}->{'app'}, setting => $set, value => $windows->{$w}->{$set} });
						}
						if ($windows->{$w}->{'headerUpdate'}) {
							my $header = &subs::db_query('select * from cache where app = ? and context = ? and timestamp > ?', $windows->{$w}->{'app'}, 'header', $windows->{$w}->{'headerUpdate'})->hashes;

							foreach my $head ( @{$header} ) {
								my $data = decode_sereal $head->{'data'};
								&Websocket::send($app, { type => 'header', app => $windows->{$w}->{'app'}, timestamp => $head->{'timestamp'}, header => $data->{'header'} });
							}
						}
					}
				}
			}
			# Only touch the heavy columns when the client actually sent them, so a
			# light heartbeat doesn't blank out the last known layout. A beat that
			# changes nothing is not a write: the row is refreshed on a slow
			# cadence only so the liveness window has something to see.
			my $ws_cache = $ws_written{ $data->{'app'} } ||= {};
			my $ws_changed = 0;
			foreach my $field ( qw/href pathname windows music_data jp_data/ ) {
				next unless defined $data->{$field};
				if (!defined $ws_cache->{$field} || $ws_cache->{$field} ne $data->{$field}) {
					$ws_changed = 1;
					last;
				}
			}
			my $ws_due = (!$ws_cache->{'at'} || ($server_time - $ws_cache->{'at'}) >= $ws_write_refresh);
			if ($ws_changed || $ws_due) {
				my $ws_update = {
					timestamp => $timestamp,
					server_time => $server_time,
					type => $data->{'type'},
					connection_id => $connection_id,
					local_address => $local_address,
					remote_address => $remote_address,
					href => $data->{'href'},
					pathname => $data->{'pathname'}
				};
				foreach my $optional ( qw/windows music_data jp_data/ ) {
					$ws_update->{$optional} = $data->{$optional} if defined $data->{$optional};
				}
				my $ws_updated = &subs::db_update('websockets', $ws_update, {
					browser_tab_id => $browser_tab_id,
					app => $data->{'app'}
				});
				# The row can vanish underneath a live socket: stale-row sweeps,
				# warranty expiry while a tab slept, or older builds that deleted
				# too broadly. A heartbeat that matched no row means the controller
				# can no longer see this websocket, so put the row back.
				unless ($ws_updated && $ws_updated->rows) {
					# Same as the connect insert: warranty settings are negative
					# offsets ('-1d' puts the row a day ahead), so alarm_haircut
					# won't cull a freshly healed row.
					my $app_warranty = &subs::setting_grabber({ app => $c->session('app'), setting => 'warranty' });
					my $warranty = &subs::ago_calc($app_warranty || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time);
					&subs::db_insert('websockets', {
						%{$ws_update},
						browser_tab_id => $browser_tab_id,
						browser_tab => $browser_tab,
						db => $database,
						'uuid' => $uuid,
						app => $data->{'app'},
						connected => $init_data->{'connected'} || $timestamp,
						hostname => $hostname,
						user_agent => $user_agent,
						random_string => &subs::random_string_creator(25),
						ticket_uuid => $c->session('ticket_uuid'),
						warranty => $warranty
					});
				}
				foreach my $field ( qw/href pathname windows music_data jp_data/ ) {
					$ws_cache->{$field} = $data->{$field} if defined $data->{$field};
				}
				$ws_cache->{'at'} = $server_time;
			}
			if ($data->{'debriefer'}) {
				if ($c->session('ticket_uuid')) {
					&subs::db_query('update tickets set debriefer = ? where uuid = ?', $data->{'debriefer'}, $c->session('ticket_uuid'));
				}
				if ($c->session('privilege') eq 'citizen') {
					my $hostname = `hostname`;
					chomp($hostname);
					&subs::setting_setter({ app => '__DEBRIEFING__', setting => $hostname, value => $data->{'debriefer'} });
				}
			}
			# A sleeper's answer carries no neighbour payload. Building it (a query,
			# a JSON decode and re-encode per neighbour, template rendering) is work
			# nobody can see while the controller is shut, so the reply is a bare
			# liveness ack. An open controller gets a full payload only when the
			# neighbourhood moved, or on a slow refresh.
			my ($neighbours, $full);
			if ($controller_visible) {
				my $community = &subs::db_query('select * from websockets where ( app = ? or app like ? ) and type = ? and server_time >= ? order by server_time DESC',$app, $app . '@%', 'stayingAlive',$server_time - $ws_live_window);
				$neighbours = $community->hashes;
				my $stamp = join('|', map {
					($_->{'browser_tab_id'} // '') . ':' . ($_->{'server_time'} // '') . ':' . ($_->{'pathname'} // '') .
					':' . length($_->{'windows'} // '') . ':' . length($_->{'music_data'} // '') . ':' . length($_->{'jp_data'} // '')
				} @{$neighbours});
				$full = 1 if ($stamp ne $ws_neighbour_stamp);
				$full = 1 if (($server_time - $ws_neighbour_at) >= $ws_neighbour_refresh);
				if ($full) {
					$ws_neighbour_stamp = $stamp;
					$ws_neighbour_at = $server_time;
					foreach my $n ( @{$neighbours} ) {
						my $neighbourhood = eval { return decode_json $n->{'windows'} } || {};
						$n->{'user_agent'} = &subs::abbreviate_name($n->{'user_agent'});
						foreach my $nw ( keys %{$neighbourhood} ) {
							$neighbourhood->{$nw}->{'formatted_name'} = &subs::format_name($neighbourhood->{$nw}->{'app'});
							$neighbourhood->{$nw}->{'shorthand_name'} = &subs::shorthand_name($neighbourhood->{$nw}->{'formatted_name'});
						}
						$n->{'windows'} = encode_json $neighbourhood;
					}
				}
			}

			my $return_data = {
				browser_tab_id => $browser_tab_id,
				browser_tab => $browser_tab,
				'uuid' => $uuid,
				timestamp => $timestamp,
				app => $data->{'app'},
				from => $hostname,
				connection_id => $connection_id,
				user_agent => $user_agent,
				type => $data->{'type'},
				local_address => $local_address,
				remote_address => $remote_address,
				input => $data->{'input'},
				remote => $full ? $remote_machines : undef
			};
			if ($full) {
				$return_data->{'neighbours'} = $neighbours;
				if (-e './templates/websockets/' . &subs::path_name($app) . '.html.ep') {
					$return_data->{'template'} = $c->render_to_string(
						template => 'websockets/' . &subs::path_name($app),
						ws => $return_data
					);
					if ($app eq 'server') { delete $return_data->{'remote'}; }
				}
			}
			else {
				$return_data->{'slim'} = 1;
			}

			# A start or stop pushes the header once, and a tab that was
			# reconnecting can miss that frame. The beat names the version each
			# open window is wearing; answer any newer header here, so a lost push
			# is corrected within one beat instead of waiting for a reload. The
			# cache is written by appt_header_printer on every header it renders.
			if (($apper || '') eq 'tab' && ref $data->{'headers_at'} eq 'HASH') {
				my (%stale_headers, %stale_times);
				my $checked = 0;
				foreach my $ha ( keys %{ $data->{'headers_at'} } ) {
					last if $checked++ >= 30;
					my $wa = &subs::unformat_name($ha);
					next if $wa eq '';
					my $hrow = &subs::db_query('select timestamp, data from cache where app = ? and context = ? order by server_time desc limit 1', $wa, 'header')->hashes->[0];
					next unless $hrow && $hrow->{'data'};
					my $newer = 0 + ($hrow->{'timestamp'} || 0);
					my $wearing = 0 + ($data->{'headers_at'}->{$ha} || 0);
					next unless $newer > $wearing;
					my $cached = eval { decode_sereal $hrow->{'data'} } || {};
					my $html = (ref $cached eq 'HASH') ? ($cached->{'header'} // '') : '';
					next unless length $html;
					$stale_headers{$wa} = $html;
					$stale_times{$wa} = $newer;
				}
				if (scalar keys %stale_headers) {
					$return_data->{'headers'} = \%stale_headers;
					$return_data->{'header_at'} = \%stale_times;
				}
			}

			&Websocket::send($app,$return_data);

			# The lockdown face is a fact, not a beat. Sending it every 10 s made
			# every open tab eval a console line, append a terminal entry and repaint
			# its clock - per tab, per beat, for a value that hardly ever moves. Send
			# it when it changes for that tab; the sweep is the backstop that closes
			# a window opened before the rule changed, so it runs when the state turns
			# on and then on a slow cadence while it stays on.
			my $lockdown = &subs::lockdown_active() ? 1 : 0;
			# keyed by this connection, not just the tab: a reloaded page has a clean
			# start menu, so the first beat after it must send the state again
			my $lockdown_key = ($browser_tab_id || '') . "\x1f" . ($uuid || '');
			if (!defined $ws_lockdown_state{$lockdown_key} || $ws_lockdown_state{$lockdown_key} != $lockdown) {
				$ws_lockdown_state{$lockdown_key} = $lockdown;
				&Websocket::send('server', { console => &Websocket::console_command('toggleLockdown', ($lockdown ? 1 : 0)), browser_tab_id => $browser_tab_id });
				if ($lockdown) {
					$ws_lockdown_swept{$lockdown_key} = $server_time;
					eval { &subs::lockdown_sweep({ browser_tab_id => $browser_tab_id, force => 1 }) };
				}
			}
			elsif ($lockdown && ($server_time - ($ws_lockdown_swept{$lockdown_key} || 0)) >= 20000) {
				$ws_lockdown_swept{$lockdown_key} = $server_time;
				eval { &subs::lockdown_sweep({ browser_tab_id => $browser_tab_id }) };
			}
			# a worker outlives many connections; keep the per-connection memory bounded
			if (keys %ws_lockdown_state > 200) { %ws_lockdown_state = (); %ws_lockdown_swept = (); }

		}
		elsif (($data->{'type'} || '') eq 'act') {
			# An act panel opening or closing is an event, not a layout. The client
			# sends just the affected window's jopen the moment it changes, so the
			# 10 s beat never has to carry the whole layout to report a panel. Only
			# the named window is written - the old beat wrote one for every window
			# in the page on its way past.
			my $jopen = eval { return decode_json($data->{'jopen'} || '') } || {};
			if (ref $jopen eq 'HASH') {
				foreach my $window_app ( keys %{$jopen} ) {
					next if ref $jopen->{$window_app} ne 'HASH';
					&subs::setting_setter({
						app => $window_app,
						setting => 'jopen',
						value => encode_json({ $window_app => $jopen->{$window_app} })
					});
				}
			}
		}
		elsif (($data->{'type'} || '') eq 'terminal_open' && $app eq 'server') {
			# Every Terminal window names its own pty. A window opened from the
			# session list attaches to the one still running; a new window starts one.
			my $id = &terminal_session_id_clean($data->{'terminal_id'});
			my $existed = ($gb::terminal_sessions->{$id} ? 1 : 0);
			if (!$existed) {
				&terminal_session_start($id, {
					host => $data->{'host'},
					user => $data->{'user'},
					port => $data->{'port'}
				});
			}
			else {
				&terminal_session_status($id);
			}
			&Websocket::send('server', { terminal_id => $id, terminal_opened => ($existed ? 0 : 1) });
		}
		elsif ($data->{'pty'} && $app eq 'server') {
			# Keys arrive as the bytes a terminal should receive (the client
			# encodes arrows, Backspace, Tab, Ctrl+C and the rest). Old clients sent
			# the browser's key name and a handful were mapped here. Anything the
			# browser calls a modifier key is not input at all - it used to be
			# echoed back and printed "Shift" on the screen.
			my $input = $data->{'input'};
			if (!defined $input && defined $data->{'command'} && (($data->{'keyCode'} || 0) == 13)) {
				$input = $data->{'command'} . "\r";
			}
			if (defined $input && length $input) {
				$input = &terminal_input_bytes($input);
				&terminal_session_write($data->{'terminal_id'}, $input) if length $input;
			}
		}
		elsif (($data->{'type'} || '') eq 'terminal_connect' && $app eq 'server') {
			# Switch this window's shell to another machine over ssh. The host, user
			# and port are validated in terminal_shell_clean; no shell is involved
			# in starting it, so the values never reach a command line string.
			&terminal_session_start($data->{'terminal_id'}, {
				host => $data->{'host'},
				user => $data->{'user'},
				port => $data->{'port'}
			});
		}
		elsif (($data->{'type'} || '') eq 'terminal_local' && $app eq 'server') {
			&terminal_session_start($data->{'terminal_id'}, {});
		}
		elsif (($data->{'type'} || '') eq 'terminal_end' && $app eq 'server') {
			&terminal_session_stop($data->{'terminal_id'});
		}
		elsif (($data->{'type'} || '') eq 'terminal_refresh' && $app eq 'server') {
			# A window that has just attached to a running session asks the shell to
			# draw its prompt again. It only does this on a blank screen.
			&terminal_session_write($data->{'terminal_id'}, "\r");
		}
		elsif (($data->{'type'} || '') eq 'terminal_resize' && $app eq 'server') {
			my $rows = int($data->{'rows'} || 0);
			my $cols = int($data->{'cols'} || 0);
			if ($rows > 0 && $rows <= 500 && $cols > 0 && $cols <= 1000) {
				&terminal_session_resize($data->{'terminal_id'}, $rows, $cols);
			}
		}
		elsif (($data->{'type'} || '') eq 'remote_input' && $app eq 'server') {
			# The remote_control panel sends its pointer/key batches over this
			# already-open socket: one frame, no request and no openssl per
			# character. A peer that has no live control socket yet (or fell
			# back after a restart) is served by the signed HTTP route, whose
			# answer goes back to the tab here.
			my $result = remote_input_send({
				uuid => $data->{'remote_uuid'},
				events => $data->{'events'} || [],
				browser_tab_id => $browser_tab_id,
			});
			if ($result && !$result->{'queued'}) {
				&Websocket::send('server', {
					%{$result},
					type => 'remote_input_result',
					destination => $browser_tab_id,
					remote_uuid => $data->{'remote_uuid'},
				});
			}
		}
		elsif ($data->{'type'} eq 'synth' && $app eq 'music') {
			my $freq = $data->{'freq'};
			my $waveform = $data->{'waveform'};
			my $length = $data->{'length'};
      &subs::subprocessor(sub {
		    Mojo::IOLoop->reset;

				`play "|sox -n -p synth $length $waveform $freq " &`;
			}, { name => 'synth ws player' });
		}
		elsif ($data->{'method'} eq 'playerCache') {
			&subs::cache_set({ app => 'music', context => 'player' }, $data);
		}
		elsif ($data->{'method'} eq 'transmitter') {
			$data->{'browser_tab_id'} = $browser_tab_id;
			&subs::music_transmitter($c, $data);
		}
		elsif ($data->{'method'} eq 'textAreaMagic') {
			my $context = &text_area_context($data->{'magic_vars'});
			my ($magic,$token) = &text_area_magic($data->{'text'}, $context, { plain => $data->{'plain'} });
			if ($magic ne $data->{'text'}) {
				$data->{'text'} = $magic;
				$data->{'token'} = $token;
				&Websocket::send('tab', { textAreaMagic => $data });
			}
		}
		elsif (($data->{'type'} || '') eq 'resync') {
			# A socket that comes back after a sleep, a network change or a worker
			# restart has missed every frame pushed while it was gone - above all
			# the appointment header a start or stop sends. The client names the
			# windows it has open; answer with the header each one is wearing now.
			# The header cache is written by every start/stop, so the answer is a
			# row lookup; only an app with no cached header is rendered.
			my $resync_headers = {};
			my @resync_apps = (ref $data->{'apps'} eq 'ARRAY') ? @{ $data->{'apps'} } : ();
			splice(@resync_apps, 30) if scalar(@resync_apps) > 30;
			my %resync_seen;
			foreach my $resync_app ( @resync_apps ) {
				next if ref $resync_app || !defined $resync_app || $resync_app !~ /\S/;
				my $ra = &subs::unformat_name($resync_app);
				next if $ra eq '' || $resync_seen{$ra}++;
				my $cached_header = eval { &subs::cache_get({ app => $ra, context => 'header' }) } || {};
				my $ra_html = (ref $cached_header eq 'HASH') ? ($cached_header->{'header'} // '') : '';
				unless (length $ra_html) {
					$ra_html = eval { &subs::appt_header_printer({ app => $ra, header_only => 1, broadcast => 'no' }) } || '';
				}
				$resync_headers->{$ra} = $ra_html if length $ra_html;
			}
			# The theme is idempotent (its signature filters an unchanged push), and a
			# start or stop is what moves it; a reconnect asks for it too.
			eval { &subs::appointment_theme_push() } if $data->{'theme'};
			&Websocket::send($app, {
				type => 'resync',
				app => $app,
				headers => $resync_headers,
				destination => $browser_tab_id,
				browser_tab_id => $browser_tab_id,
				timestamp => &subs::rightNow()
			});
		}
		else {
			$data->{'not_me'} = 1;
			$data->{'browser_tab_id'} = $browser_tab_id;

			&Websocket::send($app, $data);
		}
	});
	$c->on(finish => sub ($c,$code,$reason) {
		# A resume that rebuilds sockets (a phone waking) can register a new
		# connection for the same tab before this older, silently dead one is
		# noticed to be gone. Only a connection still on duty may clear the tab
		# out and log the stop, or the fresh socket goes deaf.
		my $on_duty = $gb::ws->{$app}->{$browser_tab_id};
		if ($on_duty && $on_duty == $c->tx) {
			# A socket that is gone leaves no row behind unless it was parked in a
			# named room - the parking lot keeps those on purpose. It used to be
			# marked type=closed instead, and with a warranty years out those rows
			# were never culled (about 870 dead rows had piled up).
			&subs::db_query('delete from websockets where app = ? and browser_tab_id = ? and room is null', $app, $browser_tab_id);
			delete $gb::ws->{$app}->{$browser_tab_id};
			if ($app eq 'music') {
				if ($log_me eq 'on') {
					my $appts = &subs::db_query('select * from appointments where source_uuid = ? and app = ? and type = ? order by timestamp desc limit 30', $browser_tab, $computer_name,'start')->hashes;
					foreach my $appt ( @{$appts} ) {
						&appointment_writer($c, {
							type => 'stop',
							uuid => $appt->{'uuid'},
							app => $appt->{'app'}
						});
						&subs::appt_header_printer({ app => $appt->{'app'} });
						&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $appt->{'app'}, $appt->{'uuid'})});
					}
				}
			}
		}
		&websocket_close($app);
		# Tidy stale rows for this tab only. This used to run against a
		# *future* timestamp, so closing any socket deleted every other
		# tab's rows too and the controller list stayed empty until the
		# next reconnect. ago_calc counts backwards: '1d' is yesterday,
		# '-1d' is tomorrow.
		my $stale = &subs::ago_calc('1d', &subs::rightNow());
		&subs::db_query('delete from websockets where room is null and browser_tab_id = ? and server_time < ?', $browser_tab_id, $stale)->hashes;
	});

	# The remote-tab fan-out used to be built here. `unless (1 == 0 && ...)`
	# was always true, the command was never sent, and every socket connect
	# queried the roster and printed undefined ws_port/ws_auth warnings (the
	# log on a phone ran to thousands of lines). A remote tab is started by
	# websocketStart on the client; the dead builder is gone.
}

# WEBSOCKET /device/ws
# The embedded devices' output bus: relay/led/servo commands from the manager,
# a state snapshot on connect, and presence. A board authenticates with the
# same rotated Now Me pair as /watch and /teletype/ws and holds the socket on
# the websocket worker (the ws_port), whose keep-alive worker is where
# %DEVICE_CONN lives. Inputs (buttons, switches, pots) stay on HTTP; this
# socket carries outputs only.
sub action_719 {
	my $c = shift;
	my $watch_settings = eval { &subs::embedded_authorizer($c) };
	my $chip_id = $c->param('chip_id') || '';
	unless ($watch_settings && length $chip_id) {
		$c->rendered(403);
		return;
	}
	my $edt = $c->param('edt') || '';
	my $name = ($watch_settings->{'__specs'} || {})->{'name'} || $chip_id;
	my $ip = $c->tx ? $c->tx->remote_address : '';
	&subs::device_ws_attach({
		chip_id => $chip_id,
		edt => $edt,
		ip => $ip,
		name => $name,
		ws => $c->tx,
	});
	# Teach the clock on connect, and every two minutes after. The board keeps
	# time with its own crystal between /watch/time calls; a drift of tens of
	# seconds made a switch stamp its session in the past, and this socket is
	# open exactly when it needs the house's time.
	my $tell_time = sub {
		return eval { $c->send(encode_json(&subs::device_ws_time_frame(&subs::rightNow()))); 1 };
	};
	$tell_time->();
	my $clock_timer = Mojo::IOLoop->recurring(120 => sub {
		&subs::device_ws_detach($chip_id) unless $tell_time->();
	});
	# The same picture /watch and the BLE bridge build, so a socket connect and a
	# Now Me cannot disagree.
	$c->send(encode_json(&subs::device_ws_snapshot({ chip_id => $chip_id, edt => $edt })));
	$c->on(message => sub ($ws, $msg) {
		my $m = eval { decode_json $msg } || {};
		my $t = $m->{'t'} || '';
		if ($t eq 'ping') {
			$ws->send(encode_json({ t => 'pong', timestamp => &subs::rightNow() }));
		}
		elsif ($t eq 'ack') {
			&subs::device_ws_ack($chip_id, $m->{'id'});
		}
		elsif ($t eq 'millis') {
			# The board's answer to a time frame: its own millis() and the epoch
			# it now believes. Naming the difference is what makes a drifting
			# board visible instead of mysterious.
			&subs::device_ws_clock_note($chip_id, $m);
		}
	});
	$c->on(finish => sub ($ws, $code, $reason) {
		Mojo::IOLoop->remove($clock_timer) if $clock_timer;
		&subs::device_ws_detach($chip_id, $ws);
		# TODO: no embedded "mark offline" helper exists to call here. Presence
		# is derived from sightings by subs::device_lister
		# (lib/JawnOS/Domain/Device.pm:509) and the BLE presence window
		# (lib/JawnOS/Domain/Ble.pm:657); do not invent a table for this.
	});
	return;
}

1;

# POST /manager/device_ws
# A non-homebase machine relays an output command to the socket this machine
# holds for the board (the board is homed here; the person pressed start on
# another machine). Peer-signed, and the frame is the same one the local path
# sends, so the board cannot tell which road it arrived on.
sub action_47101 {
	my $c = shift;
	unless (&app_peer_ok($c)) {
		$c->res->code(403);
		return $c->render(text => 'no');
	}
	my $chip_id = $c->param('chip_id') || '';
	my $frame = eval { decode_json($c->param('frame') || '') } || {};
	my $sent = &subs::device_ws_send_local($chip_id, $frame);
	$c->render(json => { sent => $sent ? 1 : 0 });
}
