package Manager;

# Manager helpers, part 36 of 37. Moved out of Manager.pl so a
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

# A pass that throws used to abort silently: the reconnector's eval swallowed the
# exception and the log showed "a peer announced new rows; running the pass now"
# with no pull after it, which is exactly the shape a tablet that never dials out
# leaves behind. Name each distinct error once per process so a recurring abort
# does not flood the log.
our %sync_pass_error_seen;

sub remote_machine_reconnector($c) {


	&subs::setting_setter({ app => '__president', setting => 'remote_connect_timer', value => &subs::rightNow() });
	my $timestamp = &subs::rightNow();
	my $browser_tab_id = $c->param('browser_tab_id');
	my $browser_tab = $c->param('browser_tab');
	my $ws_auth;
	my $signatorial = &subs::signatorial_designer();
	# one log line per held pull marker, not one per peer per tick
	my %own_busy_seen;
	my $pass_ok = 0;
	eval {
		my $remote_machines = &subs::remote_machine_lister({ });
		# Hub-and-spoke while the server is live: a spoke stops dialling peers it
		# can only reach through the hub, and falls back to the full mesh when the
		# hub's handshake or its tunnel goes stale. The hub itself always walks the
		# whole roster (it is the union), and a peer on our own LAN is still direct.
		my $topology = &sync_topology_get();
		my $hub_sig = &sync_hub_pick($remote_machines, ($device eq 'server') ? 1 : 0);
		my ($hub_row) = $hub_sig ? grep { ($_->{'signatorial'} || '') eq $hub_sig } @{$remote_machines} : ();
		my $hub_ok = ($device eq 'server') ? 1 : &sync_hub_status($hub_row);
		my $hub_mode = ($device ne 'server' && $hub_sig && ($topology eq 'hub' || ($topology eq 'auto' && $hub_ok))) ? 1 : 0;

		# One pull per pass (the marker holds the slot until the forked child
		# claims it), so roster order decides who syncs. Start with the peer
		# whose last confirmed pull is oldest instead of whichever peer the
		# table happened to list first - a busy laptop otherwise takes every pass.
		my %synced_at;
		foreach my $rm ( @{$remote_machines} ) {
			next unless $rm->{'signatorial'};
			my $seen = &subs::db_query('select server_time from backups where reason=? and signatorial=? and recipient=? order by server_time desc limit 1', 'remote_upgraded', $rm->{'signatorial'}, $signatorial)->hashes->[0] || {};
			$synced_at{$rm->{'signatorial'}} = $seen->{'server_time'} || 0;
		}
		$remote_machines = &subs::sync_peer_order($remote_machines, \%synced_at);

		# A peer's stored session cookie lapses unnoticed: the handshake below is
		# signed and gate-exempt, so it keeps answering JSON while every relayed
		# request to a gated route comes back as the Gate page, and the relay quietly
		# does nothing. Every few minutes, once per pass, probe a peer with its stored
		# cookie and log it back in when the cookie no longer authenticates, so the
		# relay and the sync rail ride a fresh session.
		my $auth_probe_due = (&subs::rightNow() - (&subs::setting_grabber({ app => '__president', setting => 'remote_auth_probe_timer' }) || 0)) > 180000;
		my $auth_probe_filed = 0;
		my @accomplished;
		foreach my $rm ( @{$remote_machines} ) {
			# never a turn for ourselves: the 'me' pseudo and any self row that
			# slipped in would otherwise burn the tick (and decode the hub's own
			# giant data blob) before a real peer is reached.
			next if ($rm->{'signatorial'} || '') eq $signatorial;
			next if grep { $_ eq $rm->{'signatorial'} } @accomplished;
			if ($hub_mode) {
				# The hub, and anything we can reach on our own LAN, stay in the pass;
				# a peer whose only path is the hub is left to the hub to pull.
				my $direct = (($rm->{'signatorial'} || '') eq $hub_sig) ? 1 : 0;
				$direct ||= (($rm->{'lan'} || '') eq 'yes') ? 1 : 0;
				$direct ||= &subs::peer_lan_address($rm) ? 1 : 0;
				next unless $direct;
			}
			eval {

				my $ip = $rm->{'ip'};
				my $ping_test;
				my $ping = &remote_machine_online({ rm => $rm, ip => $ip, port => $rm->{'port'}, signatorial => $rm->{'signatorial'} });

				if ($ping == 0) { $ping_test = 'no'; }

				my $auuid = &subs::random_string_creator();
				my $is_tunnel = $rm->{'tunnel'};

				if ($device ne 'server' && !$rm->{'tunnel'} && $ping =~ /127\.0\.0\.1/) {
					$ping = '';
					$rm->{'connection'} = 'inactive';
					$ping_test = 'no';
					if ($ping_test eq 'no' && $rm->{'pseudonyms'}) {
						($ping,$ping_test,$rm) = &remote_pseudonyms($rm);
					}
				}
				elsif ($ping_test eq 'no' && $rm->{'pseudonyms'}) {
					($ping,$ping_test,$rm) = &remote_pseudonyms($rm);
				}

				sub remote_pseudonyms($rm) {
					my $pseu = eval { return decode_json $rm->{'pseudonyms'} } || {};
					# No `my` on $ping/$ping_test here: shadowing them inside the block threw
					# the probe's answer away, so a reachable pseudonym still read as
					# no-answer and the full handshake below never ran on the new network.
					my ($ping,$ping_test);
					if ($pseu->{'ip'}) {
						$ping = &remote_machine_online({ rm => $rm, ip => $pseu->{'ip'}, port => $pseu->{'port'}, signatorial => $rm->{'signatorial'} });

						if ($ping == 0) {
							$ping_test = 'no';
						} else {
							# rebuild the manager in the base form the handshake expects
							# (host:port, no /manager path): the stored pseudonym carries the
							# peer's advertised `.../manager`, which would double up when the
							# handshake appends its own '/manager/remote_auth_test'.
							my $port = $pseu->{'port'} || $rm->{'port'};
							$rm->{'ip'} = $pseu->{'ip'};
							$rm->{'manager'} = 'https://' . $pseu->{'ip'} . ':' . $port;
							$rm->{'port'} = $port;
							$rm->{'ws_port'} = $pseu->{'ws_port'};
						}
					}
					return ($ping, $ping_test, $rm);
				}


				if ($ping == 1) {

					$ip = $rm->{'ip'};
					# Hand the peer the watermark we already hold from it, so its auth
					# route can say (with a count) whether it has anything newer instead
					# of our pulling its window on every tick. The per-table digest is the
					# real signal: it catches a table that moved without a new appointment
					# and an offline peer holding a row nobody else saw.
					my $peer_watermark = &subs::db_query('select server_time from backups where reason=? and signatorial=? and recipient=? order by server_time DESC LIMIT 1', 'remote_upgraded', $rm->{'signatorial'}, $signatorial)->hashes->[0];
					my $my_digest = &subs::sync_digest_map();
					$rm = &remote_useragent_maker({ signatorial => $rm->{'signatorial'}, rm => $rm, auth_test => 'yes', tombstone_cursor => ($rm->{'sync_cursor'} || 0), since => ($peer_watermark->{'server_time'} || 0), digest => $my_digest });
					my $manager = $rm->{'manager'};
					my $port = $rm->{'port'};
					my $port_dock = $rm->{'dock_port'};
					$manager =~ s/:$port/:$port_dock/gi;
					if (!$rm->{'res'}) {
						$ping_test = 'no';
					}
					if (!eval { return decode_json $rm->{'res'}->body }) {
						$ping_test = 'no';
						if ($rm->{'data'}->{'database'}) {
							my $auuid = &subs::random_string_creator();
							my $manager_file = &manager_file_maker($c->session('name'));
							my $html = '<h2>Reconnecting to ' . $ip . '</h2>';
							&Websocket::send('tab', { green => $html, uuid => $auuid });
							my $returner = &remote_machine_reauth($c, $rm, $timestamp, $ip, $browser_tab_id, $browser_tab);
							if ($returner->{'body'}->{'signatorial'}) {
								$ping_test = 'ok';
							}
							else {
								$ping_test = 'no';
							}
						}
						else { $ping_test = 'ok'; }
					}
					else {
						my $rj = eval { return decode_json $rm->{'res'}->body };
						# The handshake answered JSON, but a gate-exempt route answers even to
						# a lapsed cookie, so ask a gated but read-only route with the stored
						# cookie too. HTML back (not the route's JSON) means the session is
						# dead; log in again so the relay stops handing the caller the Gate.
						if ($auth_probe_due && $rm->{'ua'} && $rm->{'data'}->{'database'}) {
							if (!$auth_probe_filed) { &subs::setting_setter({ app => '__president', setting => 'remote_auth_probe_timer', value => &subs::rightNow() }); $auth_probe_filed = 1; }
							my $probe_tx = eval { $rm->{'ua'}->inactivity_timeout(10)->get($rm->{'manager'} . '/manager/configure/tunnel/list' => { Accept => 'application/json, text/html' }) };
							my $probe_body = eval { $probe_tx->res->body } || '';
							&remote_machine_reauth($c, $rm, $timestamp, $ip, $browser_tab_id, $browser_tab) if length $probe_body && $probe_body !~ /^\s*[\{\[]/;
						}
						next if $rj->{'signatorial'} eq $signatorial;
						my $appt = &subs::db_query('select server_time,app from appointments order by server_time DESC LIMIT 1')->hashes->[0];
						if ($rj->{'fqdn'}) {
							my @domain = split '\.', $rj->{'fqdn'};
							my $subdomain = $domain[0];

							if ($rj->{'ws_auth'}) {
								$ws_auth = url_escape $rj->{'ws_auth'};
							}

						}
						$rm->{'port'} = $rj->{'port'};
						$rm->{'ws_port'} = $rj->{'ws_port'};
						$ping_test = 'ok';
						my $backup = &subs::db_query('select * from backups where reason=? and signatorial=? and recipient=? order by server_time DESC LIMIT 1',
							'remote_upgraded',$rj->{'signatorial'},$signatorial)->hashes->[0];
						# The guarded plan: the digest says whether a table's picture differs,
						# and `above` proves whether the difference is a strict forward delta.
						# The plan is handed over from the first pull too: `sync_plan` already
						# skips a table whose picture meets ours and only asks for a full read
						# when the divergence cannot be a forward delta, so a cold peer gets
						# its one full reconciliation now instead of a bounded window that
						# leaves old unique rows behind forever.
						my $seen = &subs::sync_seen_get($rj->{'signatorial'});
						# The band map is what turns a divergent picture into a handful of
						# moved blocks; without it the planner must either skip a small
						# old-row gap or read the table whole.
						my $bands = &subs::sync_bands_peer($rj->{'version'}, $rj->{'bands'});
						my $plan = &subs::sync_plan($my_digest, $rj->{'digest'}, $rj->{'above'} || {}, $seen, $bands);
						my $plan_differs = (ref $plan eq 'HASH' && scalar keys %{$plan}) ? 1 : 0;
						my $plan_pull = $plan_differs ? 1 : 0;
						# Apply the peer's queued deletions and its durable tombstones in
						# one place; a row pull also asks for them (see sync_rows_pull).
						&apply_peer_tombstones($rj, $rj->{'signatorial'});
						# Refresh the live flags on every successful tick: connection/status
						# were only ever set on a full reconnect, so a row could read
						# 'inactive' while the peer was answering every handshake (the hub
						# showed that here). version rides along so "who is behind" is a
						# column, not a guess.
						my $flags = { connection => 'active', status => 'connected', server_time => &subs::rightNow() };
						$flags->{'version'} = $rj->{'version'} if $rj->{'version'};
						&subs::db_update('remote_machines', $flags, { signatorial => $rj->{'signatorial'} });
						if ($rj->{'location'} && &subs::device_setter() ne 'mobile') {
							# Only a machine with no GPS of its own adopts a peer's place. A
							# phone that has its own GPS keeps its own fix; borrowing one
							# here is what let a computer's copy of a place overwrite the
							# real fix (and read as public until the next manual fix).
							my $same_net = &subs::same_net_test($rj->{'you'},$rj->{'me'});
							my $location_source = &subs::remote_machine_lister({ signatorial => $rj->{'location'}->{'signatorial'}, mirrors => 'none', limit => 1 });
							if ($same_net eq 'yes' && $rj->{'same_net'} eq 'yes') {

								if (&remote_machine_online({ rm => $location_source }) == 1) {

									&subs::db_delete('continent', { type => 'temporary', signatorial => $rj->{'signatorial'} });
									my $tlocation = &subs::db_select('continent', undef, { type => 'temporary', signatorial => $signatorial })->hashes->[0];
									$rj->{'location'}->{'type'} = 'temporary';
									$rj->{'location'}->{'uuid'} = &subs::random_string_creator(12);
									$rj->{'location'}->{'app'} = '__president';
									&subs::db_insert('continent', $rj->{'location'});


									if (!$tlocation->{'latitude'}) {
										if (!$rj->{'location'}->{'server_time'} || $rj->{'location'}->{'server_time'} >= &subs::rightNow() - ( 5 * 60 * 1000)) {

											$rj->{'location'}->{'uuid'} = &subs::random_string_creator(22);
											$rj->{'location'}->{'signatorial'} = $signatorial;
											$rj->{'location'}->{'warranty'} = &subs::ago_calc('-5m', &subs::rightNow());
											&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
											&subs::db_insert('continent', $rj->{'location'});
										}
									}
								}
							}
						}
						if ($rj->{'network'}) {
							$rm->{'network'} = encode_json $rj->{'network'};
						}
						if ($device eq 'computer') {
							my $diff = ($rj->{'now'} - &subs::rightNow());
							if (abs $diff > 500 && $rj->{'now'}) {
								my $now = $rj->{'now'} / 1000;
								my $uc = 'sudo date -s @' . $now;
							#	my $update = `$uc`;
							}
						}
						# Pull when the peer's newest appointment sits above the watermark we
						# handed it, or when its `pending` count says it holds anything newer
						# (the peer computes that count from the watermark). A deep (nightly)
						# sync still runs - it reconciles a gap the watermark cannot see.
						my $deep = $c->session('gimme') || $c->param('gimme');
						my $has_new = $rj->{'server_time'} > $backup->{'server_time'};
						# A table picture that differs from the one we last reconciled is a
						# reason to pull even when no appointment moved (settings, a website,
						# an offline row). The plan itself is handed over only once the peer's
						# picture has a baseline; the first pull runs the legacy window.
						$has_new = 1 if $plan_differs;
						# pending can only ADD a pull: a peer on older code computes it with a
						# NULL-unsafe status filter (appointments_since) and can answer zero
						# while plainly holding newer appointments, so its zero must not
						# suppress the pull the timestamp comparison already wants.
						$has_new = 1 if (defined $rj->{'pending'} && ($rj->{'pending'}->{'count'} || 0) > 0);
						# A peer that told us its export was busy gets a short rest; asking
						# every tick only makes both machines spend the export over and over.
						# One pull at a time on this machine too. `remote_upgrade` guards
						# itself, but the reconnector can fork several children before the first
						# has written its marker; they then queue on the peer's single export
						# lock and starve one another (and fill the job list with waiters).
						# The marker is either a real pull's pid or the short-lived claim the
						# caller below writes before it forks (see
						# subs::remote_upgrade_lock_state).
						my $own_up = &subs::remote_upgrade_lock_state();
						my $own_busy = $own_up->{'busy'} ? 1 : 0;
						# Name the hold once per marker: "nothing is pulling" has to be
						# distinguishable from "a pull is running" in the log.
						if (($has_new || $deep) && $own_busy) {
							my $stamp = $own_up->{'value'} . '@' . $own_up->{'server_time'};
							if (!$own_busy_seen{$stamp}++) {
								$log->info('sync hold: this machine owns a pull (' . $own_up->{'value'} . ', ' . int($own_up->{'age'} / 1000) . 's old)');
							}
						}
						if (($has_new || $deep) && !$own_busy && $rj->{'merging'} ne 'running' && !&subs::sync_backoff_active($rj->{'signatorial'})) {
							my $whoami = `whoami`;
							chomp $whoami;
							my $hostname = `hostname`;
							chomp $hostname;
							my $gimme = $deep;
							# A phone or tablet handed a nine-table plan merges all nine in
							# one pass; that is the 30-50s burn under the start menu's gauge.
							# One table per pass keeps a pass inside a tick, and sync_plan
							# re-derives the rest from the digests on the next handshake, so
							# the tables left behind are deferred, not lost. A deep (gimme)
							# repair is deliberately not capped. The puller steps too when
							# the PEER is a phone: the export rides the peer's tunnel and
							# battery, and a six-table pull held a phone's export workers
							# and its tunnel at 100%.
							my $mobile_peer = (($rm->{'data'}->{'device'} || '') eq 'mobile') ? 1 : 0;
							if ($plan_pull && !$gimme && (&subs::device_setter() eq 'mobile' || $mobile_peer)) {
								my $capped = &subs::sync_plan_step($plan, 1);
								my $before = scalar keys %{$plan};
								my $after = scalar keys %{$capped};
								if ($after < $before) {
									$log->info('sync plan stepped: ' . $before . ' -> ' . $after . ' table(s) this pass');
									$plan = $capped;
								}
							}
							my $params = {
								timestamp => $rj->{'now'},
								ip => $rm->{'ip'},
								ssh_port => $rm->{'data'}->{'ssh_port'} || $config->{'ssh_port'},
								database => $rm->{'data'}->{'database'},
								remote_signatorial => $rj->{'signatorial'},
								remote_device => $rm->{'data'}->{'device'},
								peer => ($rm->{'ip'} || $rm->{'hostname'} || $rj->{'fqdn'} || ''),
								# The address that just answered the probe: remote_upgrade
								# re-reads the row and would otherwise call the stored
								# (possibly dead) manager again.
								manager => &subs::peer_live_manager($rm),
								gimme => $gimme,
								sync_version => ($rj->{'sync_version'} || 0),
								default_cut => ($peer_watermark->{'server_time'} || (&subs::rightNow() - (24 * 60 * 60 * 1000))),
								plan => ($plan_pull ? $plan : undef),
								# Remembered after a confirmed, non-windowed pull so the next
								# handshake can skip this exact peer picture.
								remote_digest => (ref $rj->{'digest'} eq 'HASH' ? $rj->{'digest'} : undef)
							};
							if ($ENV{PORT_ENV} eq 'production' && $rj->{'env'} eq 'production') {
								# Claim the marker before the fork, so the next peer in this
								# tick sees a busy owner even if the child has not run yet. The
								# value is a claim, not this worker's pid: run_p forks on the
								# next tick, and a claim whose fork never happens must not
								# look like a live pull for half an hour.
								my $up_marker = 'running:claim';
								&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => $up_marker });
								$params->{'marker'} = $up_marker;
								# Name the decision: a pull that falls back to the snapshot path is
								# the expensive one, and the job note alone does not say which of
								# sync_version/full/gimme sent it there.
								$log->info('sync pull ' . ($rj->{'signatorial'} || '?') . ' version=' . ($rj->{'version'} || '?') . ' sync_version=' . ($rj->{'sync_version'} || 0) . ' deep=' . (defined $deep && length $deep ? $deep : '-') . ' plan=' . (ref $plan eq 'HASH' ? scalar(keys %{$plan}) : 0));
								# A pull/merge over a big table can outlive the prefork
								# heartbeat. Fork it, as the on-demand route does, so this
								# worker keeps answering (and syncing appointments) while
								# the child does the work.
								&subs::subprocessor(sub {
									my $status = &remote_upgrade($c,$params);
									if (($status || '') eq 'busy') {
										&subs::sync_backoff_set($rj->{'signatorial'}, 120);
									}
									elsif (($status || '') eq 'failed') {
										# A peer whose snapshot will not merge must not hold the one
										# pull slot every tick: give it a rest so a healthy peer (the
										# phone that is ahead) gets its turn.
										&subs::sync_backoff_set($rj->{'signatorial'}, 300);
									}
								}, { name => 'remote upgrade', fork => 1 });
							}
						}
						else {
						}
					}
				}
				else {
					my $dev_info = &device_network_updater($rm);
				}
				&Websocket::send('tab', { green => ' ', 'close' => 'yes' });
				if ($ping_test eq 'no') {
					if ($rm->{'connection'} eq 'active') {
						my $appts = &subs::db_select('appointments', undef, { app => &subs::unformat_name($rm->{'hostname'}), type => 'start' })->hashes;
						foreach my $appt ( @{$appts} ) {
							&appointment_writer($c, {
								type => 'stop',
								uuid => $appt->{'uuid'},
								app => $appt->{'app'}
							});
							&subs::appt_header_printer({ app => $appt->{'app'} });
							&Websocket::send('server', { console => 'appointmentDetailGrabber(\'' . $appt->{'app'} . '\',\'' . $appt->{'uuid'} .'\');'});
						}
					}
					$rm->{'connection'} = 'inactive';
				}
				else {
					push @accomplished, $rm->{'signatorial'};
					$rm->{'connection'} = 'active';
				}
				my $tuns = &subs::device_setter() eq 'server' ? &subs::tunnel_port_mapper({ ip => $rm->{'ip'} }) : {};

				my $update = { ws_auth => $ws_auth, network => $rm->{'network'}, ws_port => ($tuns->{'POST_MSG'} || $rm->{'ws_port'}), port => ($tuns->{'PORT_AHOY'} || $rm->{'port'}), connection => $rm->{'connection'} };
				# Keep the tailnet address the row has already proved. Only the live
				# network map carries it, so a report taken with the VPN down would
				# otherwise wipe the only route this peer has off the LAN.
				my $tailnet = $rm->{'tailnet_ip'} || &subs::tailnet_address($rm);
				$update->{'tailnet_ip'} = $tailnet if $tailnet;

				&subs::db_update('remote_machines', $update, { signatorial => $rm->{'signatorial'} });
			}
		}
		$pass_ok = 1;
	};
	if (!$pass_ok) {
		my $err = $@ || 'unknown error';
		$err =~ s/\s+$//;
		if (!$sync_pass_error_seen{$err}++) {
			$log->warn('sync pass aborted: ' . $err);
		}
	}
}

sub device_network_updater($rm) {
	my $srms = &subs::db_select('remote_machines', undef, { connection => 'active', device => 'server' })->hashes;
	my $remote_signatorial = $rm->{'signatorial'};
	my $signatorial = &subs::signatorial_designer();
	my $me = &subs::network_interface_reporter();

	my $you = {};
	foreach my $srm ( @{$srms} ) {
		my $mirrors = eval { return decode_json $srm->{'mirrors'} } || [];
		foreach my $mirror ( @{$mirrors} ) {
			if ($mirror->{'network'}) {
				my $network = $mirror->{'network'};

				if ($mirror->{'signatorial'} eq $remote_signatorial) {
					$you = $network;
				}
			}
		}
	}

	foreach my $nic ( keys %{$you} ) {
		next if $nic eq 'public_address';
		foreach my $nicc ( keys %{$me} ) {
			next if $nicc eq 'public_address';
			my $test = &subs::same_net_test($you->{$nic}->{'ip'},$me->{$nicc}->{'ip'});
			if ($test eq 'yes') {
				my $success = 0;
				my $ip = $you->{$nic}->{'ip'};
				$success = &remote_machine_online({ rm => $rm, ip => $you->{$nic}->{'ip'}, port => $you->{$nic}->{'port'}, signatorial => $remote_signatorial });
				if ($success == 1) {
					my $pseu = encode_json $you->{$nic};
					&subs::db_update('remote_machines', { connection => 'active', pseudonyms => $pseu }, { signatorial => $rm->{'signatorial'} });
				}
				elsif ($success == 0 && $rm->{'pseudonyms'}) {
					&subs::db_update('remote_machines', { connection => undef, pseudonyms => undef }, { signatorial => $rm->{'signatorial'} });
				}
			}
		}
	}
}

sub remote_machine_online($data) {
	my $rm = $data->{'rm'} || &subs::remote_machine_lister({ signatorial => $data->{'signatorial'}, mirror => $data->{'mirror'}, limit => 1 });
	my $ip = (defined $data->{'ip'} && $data->{'ip'} =~ /[0-9a-z]/) ? $data->{'ip'} : $rm->{'ip'};
	my $port = (defined $data->{'port'} && $data->{'port'} =~ /[0-9]/) ? $data->{'port'} : $rm->{'port'};
	# The manager url carries the port, so a peer reached only by its url - a
	# tunnel-only server, or a row that was paired again and came back with no
	# port - is still addressable. Without this fallback a NULL port returned 0
	# before anything was tried, so the handshake that would have filled the port
	# back in never ran (the local sat inactive with a working key and tunnel).
	$port = $1 if ((!$port || $port !~ /[0-9]/) && ($rm->{'manager'} || '') =~ m{:([0-9]{1,5})/?$});
	my $remote_signatorial = (defined $data->{'signatorial'} && $data->{'signatorial'} =~ /[0-9a-zA-Z]/) ? $data->{'signatorial'} : $rm->{'signatorial'};
	# The probe tries the peer's literal addresses (the row's stored LAN ip, the
	# address it advertised, a literal manager host) before any name. A name the
	# resolver cannot answer is skipped instead of pinged - the '*unknown host*'
	# lines were the tailnet names being shelled out on a machine with no VPN -
	# and an unanswered ping no longer ends the candidate: ICMP is only a hint
	# for how long to wait, because a peer can drop echo while its manager
	# answers. The literal LAN address is what makes the pass work on plain wifi.
	my $probe = &subs::peer_presence_probe($rm, {
		ip => $ip,
		port => $port,
		signatorial => $remote_signatorial,
	});
	if ($probe->{'ok'}) {
		# Keep the address that actually answered for the rest of this pass: the
		# handshake that follows uses $rm->{manager}. A literal host also becomes
		# the row's ip, which is what the pull job and the panel report.
		$rm->{'manager'} = $probe->{'manager'};
		$rm->{'ip'} = $probe->{'host'} if defined $probe->{'host'} && &subs::peer_host_is_literal($probe->{'host'});
		$rm->{'port'} = $probe->{'port'} if $probe->{'port'};
		# remote_useragent_maker runs the tunnel processor, which prefers the
		# peer's advertised LAN address whenever it is in our subnet. That
		# address is exactly what may have failed here; the flag keeps the
		# address that answered.
		$rm->{'manager_verified'} = 1;
		return 1;
	}
	if (($rm->{'tunnel'} || '') eq 'yes') {

		# tunnel work here
		foreach my $k ( keys %{$rm} ) {
			$log->info($k . ' ' . $rm->{$k}) if $k =~ /source/;
		}

	}
	return 0;
}

sub text_area_magic($text, $context, $options = undef) {
	$options ||= {};
	my $plain = $options->{'plain'};
	my $self_only = $options->{'self_only'};
	my $terminator = $plain ? ';?' : ';';
	my $token = &subs::random_string_creator(10);
	my $found = 0;
	my @pieces = split /(<[^>]*>)/, $text;
	foreach my $piece ( @pieces ) {
		next if ($piece =~ /^</);
		# the name after a dollar must begin with a letter or an underscore, so
		# $5 and $500 are numbers and are never taken for names; an arrow the
		# browser serialised arrives as -&gt;
		$piece =~ s!
			(
				\$\{[^}&\n]+\}                       # ${vape}
				| \$?[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*   # $vape or vape
			)
			(?:-&gt;|->)([A-Za-z0-9_]+)$terminator
		!
			my ($raw_app,$raw_set,$whole) = ($1,$2,$&);
			my $app = $raw_app;
			$app =~ s/^\$\{//; $app =~ s/\}$//; $app =~ s/^\$//;
			my $value;
			if ($app eq 'self') {
				$value = &text_editor_context_value($context, $raw_set);
			}
			else {
				$value = &subs::setting_grabber({
					app => &subs::unformat_name($app),
					setting => &subs::unformat_name($raw_set)
				}) unless ($self_only);
			}
			unless (defined $value) {
				$whole;
			}
			elsif ($plain) {
				$found++;
				$value;
			}
			else {
				$found++;
				my $shown = xml_escape $value;
				my $said = xml_escape html_unescape $whole;
				'<span class="text_editor_illusion" te_token="' . $token . '" original="' . $said . '" trick="' . $shown . '" displaying="trick">' . $shown . '</span>';
			}
		!gex;
	}
	my $magic = join '', @pieces;
	return ($magic, $found ? $token : undef);
}

sub text_area_context($string) {
	my $context = {};
	foreach my $pair ( split ',', ($string || '') ) {
		my ($key,$value) = split ':', $pair, 2;
		next unless defined $key && length $key;
		$context->{$key} = defined $value ? $value : '';
	}
	return $context;
}

sub text_editor_latest_document($app) {
	return unless $app;
	return &subs::db_query('select * from appointments where app = ? and data like ? order by timestamp desc limit 1', $app, '%"numbers"%')->hashes->[0];
}

sub text_editor_context_value($context, $key) {
	my $lookup = &subs::unformat_name($key);
	my $appt;
	my $named_app;
	if ($context->{'appointment'}) {
		$named_app = &subs::unformat_name($context->{'appointment'});
		$appt = &subs::db_query('select * from appointments where app = ? order by timestamp desc limit 1', $named_app)->hashes->[0];
	}
	elsif ($context->{'document'}) {
		$appt = &subs::db_select('appointments', undef, { uuid => $context->{'document'} })->hashes->[0];
	}
	my $customer;
	if ($context->{'customer'}) {
		$customer = &subs::db_select('settings', undef, { setting => 'uuid', value => $context->{'customer'} })->hashes->[0];
		$appt = &text_editor_latest_document($customer->{'app'}) if ($customer && !$appt);
	}
	my $data = {};
	$data = eval { return decode_json($appt->{'data'}) } || {} if ($appt && $appt->{'data'});
	my $numbers = $data->{'numbers'};
	if ($numbers && defined $numbers->{$lookup}) {
		return $numbers->{$lookup};
	}
	if ($lookup eq 'id' && defined $data->{'id'}) {
		return $data->{'id'};
	}
	# a document is about its customer; an appointment is about itself
	my $about = $named_app || ($appt ? $appt->{'app'} : ($customer ? $customer->{'app'} : undef));
	$about = $customer->{'app'} if (defined $context->{'document'} && $customer);
	return unless $about;
	return &subs::format_name($about) if ($lookup eq 'name');
	if ($context->{'document'} || $context->{'customer'}) {
		my $settings = &subs::settings_grabber({ app => $about });
		return $settings->{$lookup};
	}
	return &subs::setting_grabber({ app => $about, setting => $lookup });
}

sub text_editor_variables($context) {
	my @names;
	if ($context->{'appointment'}) {
		@names = qw/name ago duration quantity schedule warranty notes/;
		my $appt = &subs::db_query('select * from appointments where app = ? order by timestamp desc limit 1', &subs::unformat_name($context->{'appointment'}))->hashes->[0];
		my $data = {};
		$data = eval { return decode_json($appt->{'data'}) } || {} if ($appt && $appt->{'data'});
		if ($data->{'numbers'} || defined $data->{'id'}) {
			push @names, qw/id subtotal discount tax aux total balance/;
		}
	}
	elsif (defined $context->{'document'} || defined $context->{'template'}) {
		@names = qw/name email phone address id subtotal discount tax aux total balance/;
	}
	elsif ($context->{'customer'}) {
		@names = qw/name email phone address/;
		# the numbers of the newest document, when the customer has one
		my $newest = &text_editor_context_value($context, 'total');
		$newest = &text_editor_context_value($context, 'id') unless defined $newest;
		push @names, qw/id subtotal discount tax aux total balance/ if defined $newest;
	}
	else {
		return [];
	}
	my @variables;
	foreach my $name ( @names ) {
		my $value = &text_editor_context_value($context, $name);
		push @variables, {
			name => '$self->' . $name,
			value => (defined $value && length $value) ? $value : undef
		};
	}
	return \@variables;
}

1;
