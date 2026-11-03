package Manager;

# manager_misc14: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/time_preview
sub action_45297 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $now = $c->param('timestamp') || &subs::rightNow();
	my $deep = $c->param('deep') ? 1 : 0;
	my $time_machine = $c->param('time_machine');
	my $timeshift = $c->param('timeshift');
	my $anchor = $now;
	if ($time_machine) { $anchor = &time_machine_resolve($time_machine, $anchor); }
	if ($timeshift && $timeshift =~ /[0-9]/) { $anchor = &subs::ago_calc($timeshift, $anchor); }

	my $ago_spec = $c->param('ago') // '';
	my $ago_ms = $anchor;
	my $ago_read = 1;
	if ($ago_spec =~ /\S/) {
		my $read = &time_machine_read($ago_spec, $anchor, $deep);
		if (defined $read) { $ago_ms = $read; }
		else { $ago_read = 0; }
	}

	my $settings = $app ? &subs::settings_grabber({ app => $app }) : {};
	my $is_transaction = $c->param('transaction') ? 1 : 0;
	my $warranty_spec = $c->param('warranty') // '';
	my $warranty_default = 0;
	if ($warranty_spec !~ /\S/) {
		$warranty_spec = $is_transaction ? '-7y' : ($settings->{'warranty'} || '-10y');
		$warranty_default = 1;
	}
	my $warranty_ms = &warranty_resolve($warranty_spec,
		$is_transaction ? $ago_ms : ($ago_ms > $now ? $ago_ms : $now), $deep);

	my $duration_spec = $c->param('duration') // '';
	my $duration_default = 0;
	my $duration_ms;
	if ($duration_spec !~ /\S/ && $is_transaction) {
		$duration_ms = 5000;
		$duration_default = 1;
	}
	elsif ($duration_spec !~ /\S/) {
		$duration_spec = $settings->{'duration'} // '';
		$duration_default = 1;
	}
	$duration_ms = ($duration_spec =~ /\S/) ? &duration_read($duration_spec) : $duration_ms;

	my $schedule_spec = $c->param('schedule') // '';
	my $schedule = { text => &subs::ui('Once') };
	if ($schedule_spec =~ /\S/) {
		my $compact = &subs::schedule_parse($schedule_spec);
		if ($compact->{'once'}) {
			$schedule = { text => &subs::ui('Once') };
		}
		elsif ($deep || !$compact->{'error'}) {
			my $result = &subs::schedule_from_text($schedule_spec, $ago_ms,
				app => $app, default_until => $warranty_ms, max => 3);
			$schedule = &time_preview_schedule($result);
		}
		else {
			$schedule = { text => &subs::ui('Read when saved'), read => 0 };
		}
	}

	my $quantity_spec = $c->param('quantity') // '';
	my $quantity = { text => '', read => 1 };
	if ($quantity_spec =~ /\S/) {
		my ($q, $u) = &subs::quantity_unit_split($quantity_spec, $settings->{'unit'} || 'each', 1);
		if (defined $u && length $u && $gb::measures->{$u}) {
			$quantity = { text => $q . ' ' . $u, quantity => $q, unit => $u, read => 1 };
		}
		else {
			$quantity = { text => &subs::ui('Not a measure') . (length $u ? ': ' . $u : ''), quantity => $q, unit => $u, read => 0 };
		}
	}

	$c->render(json => {
		ago => {
			text => $ago_read
				? &time_preview_date($ago_ms)
				: ($deep ? &subs::ui('Could not read a time') : &subs::ui('Reading the words...')),
			timestamp => $ago_ms,
			read => $ago_read,
		},
		warranty => {
			text => defined $warranty_ms
				? &time_preview_date($warranty_ms)
				: ($deep ? &subs::ui('Could not read a warranty') : &subs::ui('Reading the words...')),
			timestamp => $warranty_ms,
			default => $warranty_default,
			read => (defined $warranty_ms ? 1 : 0),
		},
		duration => {
			text => defined $duration_ms ? &subs::duration_sayer(abs($duration_ms) / 1000) : &subs::ui('none'),
			milliseconds => $duration_ms,
			default => $duration_default,
			read => (defined $duration_ms ? 1 : 0),
		},
		schedule => $schedule,
		quantity => $quantity,
	});
}

# GET /manager/ago
sub action_45396 {
	my $c = shift;
	my $ago = $c->param('ago');
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	$timestamp = &time_machine_resolve($ago,$timestamp);
	$c->render(text => $timestamp);
}

# POST /manager/assistant
sub action_45403 {
	my $c = shift;
	my $image = $c->param('image');
	my $audio = $c->param('audio');
	my $id = $c->param('id');
	my $title = $c->param('title') || 'Assistant';
	my $uuid = &subs::random_string_creator(45);
	&subs::subprocessor(sub {
		if ($audio) {
	    $audio =~ s/^data:audio\/[a-zA-Z0-9]+;base64,//;

	    $audio =~ s/[^A-Za-z0-9\+\/\=]//g;

			$log->info(Dumper $audio);
			my $raw_wav = decode_base64 $audio;
			use IPC::Open3;
			use Symbol 'gensym';

			 my ($stdin, $stdout, $stderr);
				$stderr = gensym;

				# 1. Resolve your absolute home directory paths first so they pass smoothly into the shell string
				my $whisper_bin   = &subs::home('~/whisper.cpp/build/bin/whisper-cli');
				my $whisper_model = &subs::home('~/whisper.cpp/models/ggml-base.bin');

				my $pipeline_cmd = sprintf(
					'ffmpeg -nostdin -loglevel error -i - -blocksize 4096 -f wav -ar 16000 -ac 1 -acodec pcm_s16le - | %s -m %s --output-txt --file -',
					$whisper_bin,
					$whisper_model
				);

				# 3. Spawn the execution bridge using shell evaluation
				my $pid = open3($stdin, $stdout, $stderr, 'sh', '-c', $pipeline_cmd);

				# 4. Stream your raw decoded payload directly into FFmpeg's standard input
				binmode($stdin);
				print $stdin $raw_wav;
		    $stdin->flush();

				close($stdin);

				# 5. Read the transcription text coming out of stdout
				my $transcription = '';
				my $temp_trans = '';
				while (my $line = <$stdout>) {
				  $transcription .= $line;
					$temp_trans = $transcription;
					$transcription =~ s/^\s+|\s+$//g;
					$transcription =~ s/\n/<br>/gi;
					$transcription =~ s/'/\\'/gi;
					&Websocket::send('tab', {
						console => '$(\'.assistant_content[uuid="' . $uuid . '"]\').html(\'' . $transcription . '\');'
					});
					$transcription = $temp_trans;
				}
				close($stdout);
        my $error_output = '';
        while (my $err_line = <$stderr>) {
            $error_output .= $err_line;
        }
        close($stderr);

        waitpid($pid, 0);

        if ($error_output) {
            $log->error("Pipeline Stderr Logs:\n" . $error_output);
        }

					# Clean up formatting whitespace
					$transcription =~ s/^\s+|\s+$//g;
					$log->info($transcription);
					$transcription =~ s/\n/<br>/gi;
					$transcription =~ s/'/\\'/gi;

					# 6. Return transcription back to your client application
#					return $c->render(json => { text => $transcription });




		} elsif ($image) {
			my $m = {
				system_msg => 'This is an image',
				msg => 'What do you see?',
				images => [ $image ],
				type => 'assistant',
				uuid => $uuid,
				mail_contact => 'assistant'
			};
			my ($response_text,$attachments) = &subs::pen_message($m);
		}
	}, { name => 'Assistant' });

	my $returner = {
		uuid => $uuid,
		id => $id,
		title => $title
	};
	$c->render(json => $returner);
}

# POST /manager/president
sub action_46078 {
	my $c = shift;
	my $command = $c->param('command');
	my $remote_signatorial = $c->param('signatorial');

	my $rm = &subs::db_select('remote_machines', undef, { signatorial => $remote_signatorial })->hashes->[0];
	$log->info('president route: command=' . ($command || '') . ' from=' . ($remote_signatorial || '') . ' ip=' . $c->tx->remote_address) if $log;
	if ($rm && &subs::peer_verify($c, $rm) && $command eq 'restart') {
		&president_restarter();
	}
	$c->render(json => { command => $command, remote_signatorial => $remote_signatorial });
}

# POST /manager/president/restart
sub action_46090 {
	my $c = shift;
	# Name the caller: a restart request is deliberate, and this route used to
	# leave no trace at all, so a tree that rebooted on its own was impossible to
	# attribute (the syncs it interrupted looked like a broken scheduler).
	$log->info('president restart requested from ' . ($c->tx->remote_address || '?')) if $log;
	&president_restarter();
	$c->render(text => 'restarting');
}

# GET /manager/remote_auth_test
sub action_46107 {
	my $c = shift;

	my $ip = $c->tx->remote_address;
	my $home_ip = $c->tx->local_address;
	my $remote_domain = $c->param('domain') || $ip;
	my $chip_chyea = $c->param('chip_chyea');
	my $signatorial = $c->param('signatorial');

	# The peer rail authenticates by signature, not by session: the request must
	# name a known machine and carry that machine's fresh signature (an unsigned
	# call passes only while no key is on file yet, so machines can upgrade
	# without a flag day). The session gate steps aside for this route in
	# hooks.pl, so a peer whose session has lapsed can still handshake - this
	# check is the whole of the route's access control.
	#
	# Try every row for the signatorial, not just the last: repeated discovery
	# can leave a second row behind, and verifying only `[-1]` meant a stale
	# duplicate key rejected a peer whose real row was fine. Rows with a key are
	# tried first; a keyless row is the trust-on-first-contact fallback.
	my $rm_rows = &subs::db_query('select * from remote_machines where signatorial = ?', $signatorial)->hashes;
	my $verified;
	foreach my $cand ( sort { (($b->{'pubkey'} || '') ne '') <=> (($a->{'pubkey'} || '') ne '') } @{$rm_rows} ) {
		if (&subs::peer_verify($c, $cand)) { $verified = $cand; last; }
	}
	unless ($verified) {
		$c->rendered(403);
		return;
	}
	my $rm = [ $verified ];

	if ($chip_chyea) {
		&subs::setting_setter({ app => '__president', setting => 'chip_chyea', subsetting => $signatorial, value => $chip_chyea });
		$c->render(json => { chip_chyea => $chip_chyea });
	}
	elsif ($c->param('auth_test') eq 'yes') {
		my $now = &subs::rightNow();
		my $appt = &subs::db_query('select server_time,app from appointments where (status is null or status != ?) and server_time < ? order by server_time DESC LIMIT 1', 'deleting', $now - 2500)->hashes->[0];
		if (scalar @{$rm} > 0) {
			if ($rm->[-1]->{'signatorial'}) {
				my @domain = split '\.', $config->{'domain'};
				shift @domain;
				my $domain = join '.', @domain;

				my $my_signatorial = &subs::signatorial_designer();

				my @ws_auth = (
					$ip, $my_signatorial
				);
				my $ws_joiner = join $universal_splitter, @ws_auth;
				my $pa = &subs::random_string_creator(25);
				my $ws_auth = &subs::encrypter($pa, $ws_joiner);
				&subs::setting_setter({ app => '__president', setting => 'ws_pa', value => $pa});

				# Age out a dead worker's marker, and check the owner it names: a
				# peer told "merging" forever stops this machine from ever pulling
				# its newer rows. An older value is a bare 'running' (no pid), so
				# trust the age bound for it.
				my $merge_row = &subs::db_query('select value,server_time from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_upgrade')->hashes->[0] || {};
				my ($m_flag, $m_pid) = split /:/, ($merge_row->{'value'} || ''), 2;
				$m_flag ||= '';
				my $m_live = ($m_flag eq 'running' && (!$m_pid || ($m_pid =~ /^\d+$/ && $m_pid > 1 && kill(0, $m_pid)))) ? 1 : 0;
				my $merging = ($m_live && int($merge_row->{'server_time'} || 0) + 600000 > $now) ? 'running' : '';

				# Only a machine with a real GPS advertises its place in the handshake.
				# A computer's own row is borrowed from a phone, and lending that on
				# would let a third machine adopt a copy of a copy.
				my $location;
				if (&subs::navigation_gps_present()) {
					$location = &subs::db_query('select * from continent where signatorial=? and type=? and server_time >= ? order by server_time desc limit 1', $my_signatorial, 'temporary',&subs::rightNow() - (5 * 60 * 1000))->hashes->[0];
				}

				# The caller handed us the watermark it already holds (?since=); this
				# is how many of our appointments sit above it, so the caller can tell
				# whether it is behind (and by how much) without pulling the export,
				# and can check the two machines' pictures against each other.
				my $pending = &subs::appointments_since($c->param('since')) || { count => 0, max_server_time => 0 };
				# A pending device request must also make the hub pull this machine.
				# The table is a leaf and has no new appointment when its app asks for
				# a key, so the digest alone left the request waiting for the next
				# scheduled pass (and it nearly expired first).
				my $dr_pending = &subs::db_query('select count(*) as n from device_requests where status = ? and server_time > ?', 'pending', &subs::rightNow() - 3600000)->hash->{'n'} || 0;
				if ($dr_pending) {
					$pending->{'count'} = ($pending->{'count'} || 0) + $dr_pending;
					$pending->{'device_requests'} = $dr_pending;
				}
				# Everything deleted here above the caller's confirmed cursor; the
				# caller applies these and reports its new cursor on the next request.
				my $reader_cursor = $c->param('tombstone_cursor');
				my $tombstones = &subs::tombstones_since($reader_cursor);

				# The caller's per-table cuts (its newest `server_time` in each
				# table). Answering with our own count/sum/max above each cut is what
				# lets it tell a strict forward delta (it is missing only rows newer
				# than the cut) from a real divergence (an offline device holds a row
				# nobody else saw), which needs a full table rather than a window.
				my $cuts = &subs::sync_map_decode($c->param('cuts'));
				my %above;
				if (scalar keys %{$cuts}) {
					my %allowed = map { $_ => 1 } (@{ &subs::sync_table_list() }, 'settings_durable');
					foreach my $t ( sort keys %{$cuts} ) {
						next unless $allowed{$t};
						my $a = &subs::sync_table_above($t, $cuts->{$t});
						$above{$t} = $a if $a;
					}
				}

				my $json = {
					server_time => $appt->{'server_time'},
					app => $appt->{'app'},
					port => $ENV{PORT_AHOY},
					ws_port => $ENV{PORT_MSG},
					signatorial => $my_signatorial,
					now => $now,
					me => $c->tx->local_address,
					you => $c->tx->remote_address,
					deletions => $rm->[-1]->{'deletions'},
					fqdn => (&subs::public_origin_host() || $config->{'domain'}),
					domain => $domain,
					ws_auth => $ws_auth,
					env => $ENV{PORT_ENV},
					merging => $merging,
					location => $location,
					same_net => &subs::same_net_test($home_ip,$ip),
					network => &subs::network_interface_reporter(),
					revision => &subs::code_revision(),
					version => &subs::jawn_version(),
					sync => &subs::appointment_watermark(),
					tombstones => $tombstones,
					sync_cursor => &subs::tombstone_max(),
					pending => $pending,
					sync_version => 3,
					# This build can answer a per-band map, so a peer that can read one
					# may localise a divergence instead of reading the whole table.
					bands => 1,
					digest => &subs::sync_digest_map(),
					above => \%above,
				};
				$c->render(json => $json);

				my $deletions = eval { return decode_json $rm->[-1]->{'deletions'} } || [];
				@{$deletions} = grep { $_->{'initialization'} + 60000 > &subs::rightNow() } @{$deletions};
				$deletions = eval { return encode_json $deletions };

				&subs::db_update('remote_machines', { deletions => $deletions }, { signatorial => $rm->[-1]->{'signatorial'} }) if eval { decode_json $rm->[-1]->{'deletions'} };

				# Advance this reader's confirmed cursor to what it last reported,
				# then drop any tombstone every machine has now read past.
				if (defined $reader_cursor && $reader_cursor =~ /^[0-9]+$/) {
					&subs::db_query('insert or replace into sync_cursors (signatorial, cursor) values (?, ?)', $rm->[-1]->{'signatorial'}, $reader_cursor);
				}
				&subs::tombstone_purge();


			}
		}
		else {
			$c->render(json => {});
		}
	} else {
		$c->render(json => {});
	}
}

# The yellow dot's expanded panel: the active sync plus the last few completed
# remote pulls, from this machine's point of view. The active peer name rides in
# the yellow message itself; this route supplies the history. Only confirmed
# pulls (remote_upgraded) are listed - remote_update is the in-flight row.
# GET /manager/sync_history
sub action_46274 {
	my $c = shift;
	my $me = &subs::signatorial_designer();
	my $limit = 8;
	my $rows = &subs::db_query(
		'select recipient, signatorial, server_time, size from backups where reason = ? and (recipient = ? or signatorial = ?) order by cast(server_time as integer) desc limit ?',
		'remote_upgraded', $me, $me, $limit * 3
	)->hashes || [];
	my %label;
	foreach my $rm ( @{ &subs::db_select('remote_machines')->hashes || [] } ) {
		my $name = $rm->{'ip'} || $rm->{'hostname'} || $rm->{'fqdn'} || '';
		$label{$rm->{'signatorial'}} = $name if $name ne '';
	}
	$label{$me} = 'this machine';
	my @recent;
	my %seen;
	foreach my $r ( @{$rows} ) {
		my $recipient = $r->{'recipient'} || '';
		my $signatorial = $r->{'signatorial'} || '';
		# A snapshot's `signatorial` is the machine that served it and its
		# `recipient` is the caller. A row naming us as the server is an
		# outbound serve (the peer pulled from us); one naming us as the
		# recipient is an inbound pull. These were the wrong way round.
		my ($direction, $peer);
		if ($recipient eq $me) { $direction = 'in'; $peer = $signatorial; }
		elsif ($signatorial eq $me) { $direction = 'out'; $peer = $recipient; }
		else { next; }
		my $second = int(($r->{'server_time'} || 0) / 1000);
		next if $seen{$peer . ':' . $second}++;
		push @recent, {
			time => int($r->{'server_time'} || 0),
			direction => $direction,
			peer => $label{$peer} || $peer,
			size => int($r->{'size'} || 0),
		};
		last if scalar @recent >= $limit;
	}
	my $lock = &subs::db_query('select value,server_time from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_backup_lock')->hashes->[0] || {};
	my $upgrade = &subs::db_query('select value,server_time from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_upgrade')->hashes->[0] || {};
	my ($u_flag, $u_pid) = split /:/, ($upgrade->{'value'} || ''), 2;
	$u_flag ||= '';
	my $u_live = ($u_flag eq 'running' && (!$u_pid || ($u_pid =~ /^\d+$/ && $u_pid > 1 && kill(0, $u_pid)))) ? 1 : 0;
	my $now = &subs::rightNow();
	# The job table is the live picture: one row per pull/serve, with the steps
	# (one bar each) that the panel draws across the top.
	my $jobs = &subs::sync_job_list(12);
	my ($active) = grep { ($_->{'state'} || '') eq 'running' } @{$jobs};
	$c->render(json => {
		current => {
			serving => (($lock->{'value'} || '') ne '' && int($lock->{'server_time'} || 0) + 600000 > $now) ? 1 : 0,
			pulling => ($u_live && int($upgrade->{'server_time'} || 0) + 600000 > $now) ? 1 : 0,
			job => $active,
		},
		jobs => $jobs,
		recent => \@recent,
	});
}

# GET /manager/remote_refresh
sub action_47847 {
	my $c = shift;
	my $bti = $c->param('bti');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $timestamp = $c->param('timestamp');
	&Websocket::send('server', { console => 'location.reload()', origin => $browser_tab_id, destination => $bti, timestamp => $timestamp });
}

# GET /manager/ws_close
sub action_48331 {
	my $c = shift;
	my $websocket = &subs::db_select('websockets', undef, { app => $c->param('app'), browser_tab_id => $c->param('browser_tab_id') })->hash;
	unless ($websocket->{'room'}) {
		&subs::db_delete('websockets', { app => $c->param('app'), browser_tab_id => $c->param('browser_tab_id') });
	}
	$c->render('text' => 'ok');
}

1;
