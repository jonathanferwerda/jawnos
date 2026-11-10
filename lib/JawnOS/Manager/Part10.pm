package Manager;

# Manager helpers, part 10 of 37. Moved out of Manager.pl so a
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

	sub remote_upgrade($c,$params) {
	# The marker is either a forked pull's pid or the short-lived claim its caller
	# wrote before the fork (see subs::remote_upgrade_lock_state). A restart or a
	# crash is the common case here: a bare 'running' left behind by a dead worker
	# used to block every pull for the full ten-minute age bound, and a claim that
	# never produced a child did the same for half an hour. Only a live owner, or
	# a claim inside its two-minute window, blocks now. The caller that has
	# already claimed the marker passes it as `marker`; this child adopts that
	# claim and replaces it with its own pid, so the race window between fork and
	# claim is closed.
	my $adopt = $params->{'marker'} ? 1 : 0;
	my $up_state = &subs::remote_upgrade_lock_state();
	return if (!$adopt && $up_state->{'busy'});
	my $up_value = 'running:' . $$;
	&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => $up_value });
	# Two forked pulls can pass the check above in the same instant; the last
	# writer keeps the marker and the loser walks away instead of running a
	# second export against the same peer.
	my $up_confirm = &subs::remote_upgrade_lock_state();
	return 'busy' if (($up_confirm->{'value'} || '') ne $up_value);
	my $up_guard = Jawn::RemoteUpgradeLock->new($up_value);
	# One job row drives the yellow dot: its ring is the overall percent and its
	# steps are the bars across the top of the panel. The guard below still stops
	# two pulls at once; the job is what makes the wait legible.
	my $job = &subs::sync_job_start({
		direction => 'pull',
		peer => ($params->{'peer'} || $params->{'ip'} || ''),
		phase => 'export',
		# The path is chosen below. A snapshot-flavoured note here made every
		# v3 pull look like it was waiting on an export until it finished, which
		# is exactly the wrong thing to read while watching the mesh.
		note => 'pulling'
	});
	my $sync = Jawn::SyncJob->new($job);
	my $timestamp = $params->{'timestamp'};
	my $ip = $params->{'ip'};
	my $vip = $ip;
	my $port = $params->{'ssh_port'};
	my $hostname = $params->{'hostname'};
	my $database = $params->{'database'};
	my $gimme = $params->{'gimme'};
	# A migration is a full-table pull that *does* advance the watermark: the
	# window is the whole history, but the merge is a real reconciliation.
	my $full = $params->{'full'} ? 1 : 0;
	my $remote_signatorial = $params->{'remote_signatorial'};
	my $remote_device = $params->{'remote_device'};
	my $remote_machine = $params->{'remote_machine'};
	my @database = split '/', ($database || '');
	my @extender = split /\./, ($database[-1] // '');
	if (@extender) {
		$extender[-1] = 'enc';
		$database[-1] = join '.', @extender;
		$database = join '/', @database;
	}

	my $folder = '~/';
	my $connector;
	my $signatorial = &subs::signatorial_designer();
	my $download_location = &subs::home('~/.president');
	my $temp_folder = &subs::home($download_location . '/' . &subs::random_string_creator(10));

	$remote_machine = &remote_useragent_maker({ signatorial => $remote_signatorial });
	# The caller may already have proved a route (the reconnector's probe rewrites
	# the row's manager to whatever answered). remote_useragent_maker re-reads the
	# stored row, which can still name a dead tunnel or a LAN address the peer has
	# left, so keep the proven one. A caller with no probe (the Upgrade route) gets
	# the same resolution here instead of calling the stored address and reporting
	# the peer unreachable.
	if ($params->{'manager'}) {
		$remote_machine->{'manager'} = $params->{'manager'};
		$remote_machine->{'manager_verified'} = 1;
	}
	else {
		my $donor = &subs::remote_machine_lister({ signatorial => $remote_signatorial, limit => 1 });
		if ($donor && &remote_machine_online({ rm => $donor, ip => $donor->{'ip'}, port => $donor->{'port'}, signatorial => $remote_signatorial })) {
			$remote_machine->{'manager'} = $donor->{'manager'};
			$remote_machine->{'ip'} = $donor->{'ip'};
			$remote_machine->{'manager_verified'} = 1;
		}
	}
	# Every route below appends /manager/..., so the address must be a base. A
	# caller that names the panel's own address (scripts/peer_pull.pl, the signed
	# lever) hands over .../manager; dialling it unchanged asked for
	# /manager/manager/configure/backup_now, read the Gate page as the snapshot
	# and failed with "the peer sent no snapshot" in under a second.
	$remote_machine->{'manager'} = &subs::peer_manager_base($remote_machine->{'manager'})
		if $remote_machine->{'manager'};
	# The pull rail proves itself with the signed peer key, not with a session.
	# The cookie stored on the row can be a dead or denial session, and the gate
	# refuses a denial session on EVERY path before the route's peer_verify ever
	# runs - the tablet's pulls answered 403 with the denial picture while its
	# signature was valid (2026-10-31). A pull needs no cookie, so give this UA
	# an empty jar. The class is the one this Mojo actually uses and packs.
	if ($remote_machine->{'ua'}) {
		require Mojo::UserAgent::CookieJar;
		$remote_machine->{'ua'}->cookie_jar(Mojo::UserAgent::CookieJar->new);
	}
	my $auuid = &subs::random_string_creator(10);
	# v3: a normal delta pull is a sequence of encrypted row batches, not a temp
	# SQLite snapshot. A full migration and a windowed deep pull keep the snapshot
	# path, which is what those two were designed for.
	if (($params->{'sync_version'} || 0) >= 3 && !$full && !$gimme) {
		my $status = &sync_rows_pull($c, $params, $sync, $job, $remote_machine, $auuid);
		&Websocket::send('tab', { yellow => 'Complete', 'close' => 'yes', colour => $remote_machine->{'data'}->{'manager_colour'}, state => ($status eq 'done' ? 'done' : 'failed'), progress => 100 });
		return $status;
	}
	# The snapshot path is deliberate for a full migration and a windowed deep
	# pull. Anything else reaching here is a regression and the expensive path:
	# name the reason, in manager.log (the in-app log is a small, racy ring and a
	# forked pull can lose its entry there), since the job note only says
	# 'waiting for a snapshot'.
	my $why_snapshot = 'sync_version=' . ($params->{'sync_version'} || 0) . ' full=' . ($full ? 1 : 0) . ' gimme=' . (defined $gimme && length $gimme ? $gimme : '-') . ' plan=' . (ref $params->{'plan'} eq 'HASH' ? scalar(keys %{$params->{'plan'}}) : 'none') . ' peer=' . ($remote_signatorial || '?');
	if ($subs::logfile) {
		open(my $why_fh, '>>', $subs::logfile);
		print $why_fh &subs::rightNow() . " remote upgrade: snapshot path $why_snapshot\n";
		close $why_fh;
	}
	$log->info('remote upgrade: snapshot path ' . $why_snapshot);
	&subs::log_writer('remote upgrade: snapshot path ' . $why_snapshot);
	if ($remote_machine->{'signatorial'}) {
		&subs::sync_job_step($job, 'export', { label => 'export', state => 'running', note => 'peer is building a snapshot' });
		my $html = '<h2>Running Remote Backup</h2>';
		&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $remote_machine->{'data'}->{'manager_colour'}, progress => -1, state => 'running', job => $job });
		# The same LAN preference the row stream uses: a stored tailnet name can
		# point at an offline node, while the peer advertised a reachable LAN
		# manager. Only the URL host changes.
		my $lan = $remote_machine->{'manager_verified'} ? undef : &subs::peer_lan_address($remote_machine, 1);
		$remote_machine->{'manager'} = $lan->{'manager'}
			if $lan && $lan->{'manager'} && $lan->{'manager'} ne ($remote_machine->{'manager'} || '');
		my $url = $remote_machine->{'manager'} . '/manager/configure/backup_now?reason=remote_update&async=1&timestamp=' . $timestamp . '&signatorial=' . $signatorial;
		# The per-table plan: each table is exported only above the point the
		# caller already holds. A table the plan omits still rides the legacy
		# window, so a peer on this code and one on older code behave alike.
		if (ref $params->{'plan'} eq 'HASH' && scalar keys %{$params->{'plan'}}) {
			$url .= '&cuts=' . Mojo::Util::url_escape(&subs::sync_map_encode($params->{'plan'}));
		}
		if ($full) {
			$gimme = undef;
			$url .= '&full=1';
		}
		if ($gimme && $gimme =~ /[A-Za-z0-9]/gi) {
			$gimme = &subs::ago_calc($gimme, &subs::rightNow());
			$url .= '&gimme=' . $gimme;
		}
		else {
			$gimme = undef;
		}
		my $ua = $remote_machine->{'ua'};

		my $res = eval { return $ua->insecure(1)->inactivity_timeout(180)->request_timeout(300)->get($url)->result };

		if ($res) {

			my $body = eval { return decode_json $res->body } || {};

			# A snapshot can take minutes to build on a slow machine. The peer
			# answers 'building' at once and the work goes on there; wait on its
			# status rather than holding this request open past the inactivity
			# timeout that used to abandon the pull. An older peer ignores async=1
			# and still replies with the finished snapshot.
			if (($body->{'status'} || '') eq 'building') {
				my $snapshot_job = $body->{'job'} || '';
				my $status_url = $remote_machine->{'manager'} . '/manager/configure/backup_status?signatorial=' . $signatorial . '&job=' . Mojo::Util::url_escape($snapshot_job);
				my $waited = 0;
				my $state = 'building';
				my $sbody = {};
				while ($snapshot_job && $waited < 1800) {
					sleep 2;
					$waited += 2;
					# Keep this pull's own lease young: a snapshot can take longer
					# than the ten-minute marker bound, and a second child must not
					# start pulling the same peer under it.
					if (($waited % 60) == 0) {
						&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => 'running:' . $$ });
					}
					my $sres = eval { $ua->inactivity_timeout(20)->request_timeout(30)->get($status_url)->result };
					$sbody = eval { return decode_json $sres->body } || {};
					$state = $sbody->{'status'} || 'unknown';
					if ($state eq 'ready' && ref $sbody->{'result'} eq 'HASH') {
						$body = $sbody->{'result'};
						$body->{'sha256'} = $sbody->{'sha256'} if $sbody->{'sha256'};
						last;
					}
					if ($state eq 'busy' || $state eq 'failed' || $state eq 'unknown') {
						last;
					}
					# Mirror the peer's per-table rows so the receiving screen shows
					# real progress instead of a spinner.
					my ($rc, $rt, $note) = (0, 0, 'peer is building a snapshot');
					foreach my $s ( @{ $sbody->{'steps'} || [] } ) {
						next unless ref $s eq 'HASH' && ($s->{'key'} || '') =~ /^export:/;
						$rc += ($s->{'current'} || 0);
						$rt += ($s->{'total'} || 0);
						if (($s->{'state'} || '') eq 'running') {
							(my $t = $s->{'key'}) =~ s/^export://;
							$note = $t . ' ' . ($s->{'current'} || 0) . '/' . ($s->{'total'} || 0);
						}
					}
					&subs::sync_job_step($job, 'export', { current => $rc, total => $rt, note => $note });
				}
				if ($state eq 'busy') {
					&subs::sync_job_step($job, 'export', { state => 'skipped', note => 'peer was already exporting' });
					$sync->done('skipped', 'peer was already exporting');
					&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
					return 'busy';
				}
				if ($state ne 'ready') {
					my $why = ($state eq 'failed') ? ($sbody->{'error'} || 'the peer failed to build the snapshot') : 'the peer did not finish the snapshot';
					&subs::sync_job_step($job, 'export', { state => 'failed', note => $why });
					$sync->done('failed', $why);
					&Websocket::send('tab', { yellow => '<h2>Export failed</h2>', 'close' => 'yes', colour => $remote_machine->{'data'}->{'manager_colour'}, state => 'failed', progress => 100 });
					&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
					return 'failed';
				}
			}

			if (($body->{'status'} || '') eq 'busy') {
				# A peer already exporting to someone else is not a failure: it is
				# normal contention, and the backoff retries shortly. Keep the dot
				# quiet rather than painting a red cross every two minutes.
				&subs::sync_job_step($job, 'export', { state => 'skipped', note => 'peer was already exporting' });
				$sync->done('skipped', 'peer was already exporting');
				&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
				return 'busy';
			}

			if ($body->{'path'} && $body->{'signatorial'}) {
				&subs::sync_job_step($job, 'export', { state => 'done', current => 1, total => 1 });

				if (1) {
					if ($body->{'remote_update'}) {
						my $html = '<h2>Updating Database</h2>';
						&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $remote_machine->{'data'}->{'manager_colour'}, progress => 1, state => 'running'  });
						&update_database({ commands => $body->{'update_commands'} });
					}
					system('mkdir', '-p', $temp_folder) unless -e $temp_folder;
					my $temporary_file = $temp_folder . '/tmpman_' . &subs::random_string_creator(4) . '.enc';
					# A route the caller proved (or a probe that just answered) is the
					# route to fetch over. Rewriting it to the tunnel loopback defeated
					# that: on a machine that is not the hub, a peer reaches us as a
					# mirror whose `tunnel` flag belongs to the hub, so the download
					# went to 127.0.0.1:<the hub's port> and every windowed deep pull
					# for the phone, tablet and laptop failed with Connection refused
					# (2026-11-05), leaving their old appointment rows unreconciled.
					# `remote_machine_tunnel_processor` already keeps a verified
					# manager; the snapshot download must do the same.
					if (($remote_machine->{'tunnel'} || '') eq 'yes' && !$remote_machine->{'manager_verified'}) {
						my $tun = &subs::tunnel_port_mapper({ signatorial => $remote_signatorial });
						$vip = '127.0.0.1';
						$remote_machine->{'manager'} = 'https://127.0.0.1:' . $tun->{'PORT_AHOY'};
					}
					if ($body->{'raw_data'} && $body->{'size'} < 2000000) {
						write_file($temporary_file, $body->{'raw_data'});
						&subs::sync_job_step($job, 'download', { label => 'download', state => 'done', current => 1, total => 1 });
					}
					else {
						my $html = '<h2>Syncing Remote Backup ' . &subs::data_size($body->{'size'}) . '</h2>';
						&Websocket::send('tab', { yellow => $html, uuid => $auuid, colour => $remote_machine->{'data'}->{'manager_colour'}, progress => 2, state => 'running'  });
						my $dl_total = $body->{'size'} || 0;
						&subs::sync_job_step($job, 'download', { label => 'download', state => 'running', current => 0, total => $dl_total });
						# pull the encrypted archive over http - no ssh, no stored
						# password. The peer serves it through the same tunnel and
						# session as every other manager-to-manager request. Ask for
						# ranges so a dropped tunnel resumes at the byte it reached
						# instead of starting the whole snapshot over.
						my $turl = $remote_machine->{'manager'} . '/manager/backup_serve?signatorial=' . $signatorial . '&file=' . Mojo::Util::url_escape($body->{'archive_path'});
						my $part = $temporary_file . '.part';
						my $want_sha = $body->{'sha256'} || '';
						my $chunk = 4 * 1024 * 1024;
						my $offset = 0;
						$offset = -s $part if (-e $part && (!$dl_total || (-s $part) <= $dl_total));
						my $short_download = 0;
						if (open my $fh, ($offset ? '>>:raw' : '>:raw'), $part) {
							my $fails = 0;
							while (!$dl_total || $offset < $dl_total) {
								my $end = $dl_total ? ($offset + $chunk - 1) : '';
								$end = $dl_total - 1 if $dl_total && $end >= $dl_total;
								my $header = $dl_total ? { Range => "bytes=$offset-$end" } : {};
								my $tx = eval { $remote_machine->{'ua'}->inactivity_timeout(120)->request_timeout(180)->get($turl => $header) };
								my $tres = $tx ? $tx->result : undef;
								if (!$tres || !$tres->is_success) {
									$fails++;
									last if $fails >= 6;
									sleep 1;
									next;
								}
								$fails = 0;
								my $bytes = $tres->body;
								if ($tres->code == 200) {
									# The peer ignored Range: its body is the whole file.
									close $fh;
									write_file($part, $bytes);
									open $fh, '>>:raw', $part;
									$offset = length($bytes);
									last;
								}
								else {
									print $fh $bytes;
									$offset += length($bytes);
								}
								last unless length($bytes);
								&subs::sync_job_step($job, 'download', { current => $offset, total => ($dl_total || $offset) });
								last unless $dl_total;
							}
							close $fh;
						}
						if ((!$dl_total || $offset == $dl_total) && -s $part) {
							rename $part, $temporary_file;
							if ($want_sha) {
								my $got = eval { require Digest::SHA; Digest::SHA->new(256)->addfile($temporary_file)->hexdigest };
								if ($got && $got ne $want_sha) {
									$short_download = 1;
									$log->error('remote download sha mismatch: got=' . $got . ' expected=' . $want_sha) if $log;
									unlink $temporary_file;
								}
							}
						}
						else {
							$short_download = 1;
							$log->error('remote download short: got=' . ($offset || 0) . ' expected=' . $dl_total) if $log;
							unlink $temporary_file if -e $temporary_file;
						}
						&subs::sync_job_step($job, 'download', { state => ($short_download ? 'failed' : 'done'), current => ($dl_total || $offset || 1), total => ($dl_total || $offset || 1), note => ($short_download ? 'short download' : '') });
					}
					if (-e $temporary_file) {
						my $disposition = &merge_database($c,{
							file => $temporary_file,
							signatorial => $body->{'signatorial'},
							misc_settings => $body->{'misc_settings'},
							remote => $remote_machine,
							gimme => $gimme,
							sync_job => $job,
							colour => $remote_machine->{'data'}->{'manager_colour'}
						});
						system('shred', '-u', $temporary_file);
						system('rm', '-R', $temp_folder);
						if (($disposition->{'status'} || '') ne 'succeed') {
							# Do not confirm a merge that did not finish: the peer would mark the
							# snapshot delivered while this machine still lacks it.
							$sync->done('failed', 'merge did not finish');
							&Websocket::send('tab', { yellow => '<h2>Merge failed</h2>', 'close' => 'yes', colour => $remote_machine->{'data'}->{'manager_colour'}, state => 'failed', progress => 100 });
							&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
							return 'failed';
						}
					} else {

						&subs::sync_job_step($job, 'download', { state => 'failed', note => 'the peer did not send the snapshot' });
						$sync->done('failed', 'the peer did not send the snapshot');
						&Websocket::send('tab', { yellow => 'Complete', 'close' => 'yes', colour => $remote_machine->{'data'}->{'manager_colour'}, state => 'failed', progress => 100  });
						&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
						&subs::say_it('ssh fail');
						system('rm', '-R', $temp_folder);
						return 'failed';
					}
					&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
			#		&subs::db_update('remote_machines', { connection => 'inactive' }, { ip => $ip, signatorial => $remote_machine->{'signatorial'}, uuid => $remote_machine->{'uuid'} });


					&subs::sync_job_step($job, 'confirm', { label => 'confirm', state => 'running' });
					my $defunct_backups = &subs::db_query('select * from backups where ost < ? and recipient = ? and signatorial = ? and reason=?', $body->{'server_time'}, $signatorial, $remote_machine->{'signatorial'}, 'remote_upgraded' )->hashes;
					foreach my $defb ( @{$defunct_backups} ) {
						if ($defb->{'enc_file'} && -e $defb->{'enc_file'}) {
							my $delb = $defb->{'enc_file'};
							system('shred', '-u', $delb);
						}
					}
					my $url = $remote_machine->{'manager'} . '/manager/backup/confirm';
					my $form_data = {
						signatorial => &subs::signatorial_designer(),
						# A windowed (gimme/deep) pull is not proof that this machine holds
						# everything before the window, so it must not advance the peer's
						# watermark past that point.
						gimme => ($gimme ? 1 : 0),
						# The server's confirm reads only these two fields. It used to be
						# handed the whole backup_now reply, which carries misc_settings
						# (every setting on the machine) and update_commands and grew past
						# the point a POST survives the trip: the body stalled on the wire
						# and the peer closed the connection before responding. A few KB
						# is all the other side ever reads, so send that.
						backup_confirm => encode_json({
							backup_data => $body->{'backup_data'},
							ld_server_time => $body->{'ld_server_time'},
						})
					};
					#	&subs::tunnel_stopper({ signatorial => $signatorial });
					# A close here used to die out of the subprocessor with only "Premature
					# connection close" and no URL or status to say where it was aimed.
					# Keep the pull's failed state, and say what the peer answered.
					my $res = eval { $remote_machine->{'ua'}->post($url => form => $form_data)->result };
					if (!$res || !$res->is_success) {
						my $why = $@ || '';
						$why =~ s/\s+/ /g;
						my $rbody = ($res && $res->body) ? substr($res->body, 0, 300) : '';
						$rbody =~ s/\s+/ /g;
						eval { $log->error('remote confirm failed: status=' . (($res && $res->code) || 0) . ' err=' . $why . ' url=' . $url . ' bytes=' . length($form_data->{'backup_confirm'} || '') . ' body=' . $rbody) };
					}
					if ($res && $res->is_success) {
						# A gimme/deep pull is a repair window, not a watermark: deleting
						# the old watermark or moving it to the window's end would claim
						# this machine holds everything before a point it never read.
						if (!$gimme) {
							&subs::db_query('delete from backups where ost < ? and recipient = ? and signatorial = ? and reason=?', $body->{'server_time'}, $signatorial, $remote_machine->{'signatorial'}, 'remote_upgraded' );
							# Record the snapshot that actually moved: this row may predate the
							# size fix and still carry this machine's whole database (~180 MB).
							&subs::db_update('backups', { server_time => $body->{'server_time'}, reason => 'remote_upgraded', size => $body->{'size'} }, {
								recipient => $signatorial,
								signatorial => $remote_machine->{'signatorial'},
							});
							# The puller's own watermark is what tells the reconnector it has
							# caught up (and what it hands the peer as `since`). A cold pull
							# has no row to update yet, so create one; without it the peer
							# looked new every tick and pulled the whole database again.
							my $seen = &subs::db_query('select count(*) as c from backups where reason = ? and recipient = ? and signatorial = ?', 'remote_upgraded', $signatorial, $remote_machine->{'signatorial'})->hashes->[0] || {};
							unless ($seen->{'c'}) {
								&subs::db_insert('backups', {
									timestamp => ($body->{'timestamp'} || &subs::rightNow()),
									server_time => $body->{'server_time'},
									reason => 'remote_upgraded',
									recipient => $signatorial,
									signatorial => $remote_machine->{'signatorial'},
									destination => $body->{'database'},
									enc_file => $body->{'archive_path'},
									size => $body->{'size'},
									warranty => &subs::ago_calc('-20m', &subs::rightNow()),
									uuid => &subs::random_string_creator(25)
								});
							}
						}
						&subs::sync_job_step($job, 'confirm', { state => 'done', current => 1, total => 1 });
						$sync->done('done', 'snapshot merged');
						# The peer's picture is reconciled: remember it, so the planner can
						# skip this exact picture instead of full-reading a peer that is
						# merely behind. `full` records whether this table was read whole:
						# a delta-only pull leaves it false, so the next tick does the one
						# full read rather than pretending the old rows are reconciled. A
						# windowed gimme/deep pull records nothing.
						if (!$gimme && ref $params->{'remote_digest'} eq 'HASH') {
							my $prior = &subs::sync_seen_get($remote_machine->{'signatorial'}) || {};
							my $plan = (ref $params->{'plan'} eq 'HASH') ? $params->{'plan'} : {};
							my %seen;
							foreach my $t ( keys %{$params->{'remote_digest'}} ) {
								my $d = $params->{'remote_digest'}->{$t};
								next unless ref $d eq 'HASH';
								my $pk = ($t eq 'settings_durable') ? 'settings' : $t;
								my $cut = $plan->{$pk};
								my $full = (defined $cut && $cut == 0) ? 1 : ((ref $prior->{$t} eq 'HASH' && $prior->{$t}->{'full'}) ? 1 : 0);
								# A whole/banded snapshot is reconciled only when the merge left our
								# table matching the peer's. A short merge must not claim the picture.
								$full = 0 if $full && (defined $cut && $cut == 0) && !&subs::sync_table_complete($t, $d);
								$seen{$t} = { %{$d}, full => $full };
							}
							&subs::sync_seen_set($remote_machine->{'signatorial'}, \%seen);
						}
						&subs::sync_backoff_clear($remote_machine->{'signatorial'});
					}
					else {
						&subs::sync_job_step($job, 'confirm', { state => 'failed', note => 'the peer did not confirm the merge' });
						$sync->done('failed', 'the peer did not confirm the merge');
					}
				}
			}
			else {
				# A reply that is neither a snapshot nor an export status used to fail
				# with only "the peer sent no snapshot" - no code, no url, no body, so
				# a doubled /manager (the Gate page) and a mis-signed request looked
				# identical. Keep the evidence next to the failure.
				my $rbody = ($res && $res->body) ? substr($res->body, 0, 200) : '';
				$rbody =~ s/\s+/ /g;
				eval { $log->error('snapshot reply unusable: code=' . (($res && $res->code) || 0) . ' url=' . $url . ' body=' . $rbody) };
				&subs::sync_job_step($job, 'export', { state => 'failed', note => 'unexpected reply from the peer' });
				$sync->done('failed', 'the peer sent no snapshot');
			}
		}
		else {
			# The export request itself never answered: name the url and the error.
			my $err = $@ ? $@ : 'no reply';
			$err =~ s/\s+/ /g;
			eval { $log->error('snapshot request failed: url=' . $url . ' err=' . substr($err, 0, 200)) };
			$sync->done('failed', 'the peer did not answer');
		}


		&Websocket::send('tab', { yellow => 'Complete', 'close' => 'yes', colour => $remote_machine->{'data'}->{'manager_colour'}, state => ($sync->{'state'} || 'done'), progress => 100  });
	}
	else {
		$sync->done('failed', 'the peer is not reachable');
	}
	&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' });
	return ($sync->{'state'} || 'done');
};

# A browser cannot carry the house key to a peer, and the peer's ticket desk
# will not serve an expired session. Mint a ticket with the stored peer
# session; if that session has lapsed, re-auth with the house key and try
# once more. The URL keeps the peer's path/secret but is pointed at the
# peer's own host and dock port, because qrcode_generator may compute a
# loopback or tunnel-local origin.
sub remote_manager_ticket($c, $rm) {
	return '' unless ref $rm eq 'HASH' && $rm->{'manager'};
	my $timestamp = &subs::rightNow();
	my $mint = sub {
		my $peer = &remote_useragent_maker({ rm => $rm });
		return '' unless $peer->{'ua'};
		my $name = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || 'remote';
		my $host = eval { Mojo::URL->new($rm->{'manager'})->host } || '';
		# The ticket's host is the peer's own domain, not the address this
		# house happened to dial it on. A tailnet address does not match the
		# peer's config domain, and the ticket door refuses a ticket whose
		# host is not the house's own domain.
		my $ticket_host = $rm->{'fqdn'} || $host || '';
		# A remote machine's ticket must never name this house's loopback:
		# a mirror taken through a peer can carry 127.0.0.1 as its fqdn.
		if ($ticket_host =~ /^(?:127\.0\.0\.1|localhost|\[?::1\]?)$/i) {
			my $ip = $rm->{'ip'} || '';
			$ticket_host = $ip if $ip ne '' && $ip !~ /^(?:127\.|localhost|\[?::1\]?)$/i;
		}
		my $url = $peer->{'manager'} . '/manager/qrcode_generator?nic=' . url_escape($ticket_host || 'lo')
			. '&privilege=citizen&keep_warranty=1'
			. '&signatorial=' . url_escape(&subs::signatorial_designer())
			. '&warranty=' . url_escape('-2h') . '&name=' . url_escape($name) . '&timestamp=' . $timestamp;
		# A stored peer session can be stale; the helper retries the same signed
		# request without its cookie before the reauth below spends a round.
		my $res = &subs::peer_ticket_fetch($url, $peer->{'ua'});
		return '' unless $res && $res->is_success;
		my $data = eval { decode_json $res->body } || {};
		my $ticket = $data->{'url'} || '';
		return '' unless $ticket;
		# The ticket door is on the port the peer's manager answers on, not its
		# LAN dock port: a peer published on PORT_AHOY (45545) does not expose
		# 3000, and opening that authority is the blank Go window.
		my $dock = &subs::peer_ticket_port($rm);
		$ticket =~ s{^https?://[^/]+}{https://$ticket_host:$dock} if $ticket_host;
		return $ticket;
	};
	my $ticket = $mint->();
	unless ($ticket) {
		my $reauth = { %{$rm} };
		$reauth->{'data'} = eval { decode_json $rm->{'data'} } || {};
		eval { &remote_machine_reauth($c, $reauth, $timestamp, $rm->{'ip'}, '', '') };
		my $fresh = &subs::remote_machine_lister({ uuid => $rm->{'uuid'}, self => 'no', limit => 1 });
		$rm = $fresh if ref $fresh eq 'HASH';
		$ticket = $mint->();
	}
	return $ticket || '';
}

# The login URL carries only the name and the body digest; the password and the
# identity fields travel in the POST body. The peer signature covers the query,
# so the digest binds the body to it without changing the signature format.
sub sesh_login_url {
	my ($manager, $browser_tab_id, $signatorial, $login) = @_;
	return $manager . '/sesh_check?silence=yes&neighbour=' . $browser_tab_id
		. '&signatorial=' . $signatorial
		. '&body_sha256=' . &sesh_body_digest($login);
}

1;
