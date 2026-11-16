package Manager;

# manager_configure5: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/configure/new_database
sub action_19406 {
	my $c = shift;
	my ($db,$database) = &subs::database_grabber();
	&subs::db_query('VACUUM');
	my $timestamp = $c->param('timestamp');
	$c->param('reason' => 'new_database');
	$c->render(text => $database) unless $c->param('credential');
	# A database name is one filesystem component, never a path or a shell word.
	my $president = &subs::path_name($c->param('president') // '');
	my $old_db = $database;
	my $download_location = &subs::home('~/.president');
	my $temp_folder = &subs::home($download_location . '/' . &subs::random_string_creator(10)) . '/';
	require File::Path;
	File::Path::make_path($temp_folder) unless -e "$temp_folder";

	$database = $temp_folder . $president . '.db';
	my $enc_file = $temp_folder . $president . '.enc';
	my $secret = $c->param('credential');
	my $credential = &subs::session_suds($c);
	my $misc_setting_list = &misc_setting_list();
	my $server_time = &subs::rightNow();
	open(my $touch, '>>', $database) or die "touch $database: $!";
	close $touch;
	# sqlite3 creates at 0666 minus the umask; this copy is the whole house.
	chmod 0600, $database;
	my $schema_file = $temp_folder . 'schema.sql';
	# the statistics and sequence tables are internal: replaying their CREATE is
	# a parse error ("object name reserved for internal use: sqlite_sequence"),
	# and SQLite builds them again where they are wanted
	my $schema_dump = 'sqlite3 ' . &subs::shell_quote($old_db) . q{ .schema | grep -vE 'sqlite_stat|sqlite_sequence' > } . &subs::shell_quote($schema_file);
	my $schema_load = 'sqlite3 ' . &subs::shell_quote($database) . ' < ' . &subs::shell_quote($schema_file);
	`$schema_dump`;
	`$schema_load`;
	system('shred', '-u', $schema_file);
	$sql = Mojo::SQLite->new('sqlite:' . $database);
	$db = $sql->db;
	$db->query('PRAGMA cache_size = -200000');
	$db->query('PRAGMA synchronous = NORMAL');
	$db->query('PRAGMA mmap_size=266435456');
	$db->query('PRAGMA temp_store=MEMORY');
	$db->query('PRAGMA busy_timeout = 5000;');
	my $secretive = &subs::encrypter($secret,$secret);
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $timestamp);

	$db->insert('security', { level => 1, database => $database, timestamp => $timestamp, server_time => $server_time, credential => $secretive, uuid => &subs::random_string_creator(30) });
	# the door: the password sealed with itself, apart from the key canary, so a
	# later password change never re-keys this house
	$db->insert('security', { level => 'door', database => $database, timestamp => $timestamp, server_time => $server_time, credential => $secretive, uuid => &subs::random_string_creator(30) });
	foreach my $set ( qw/misc/ ) {
		my $settings = &subs::db_select('settings', undef, { app => $set })->hashes;
		foreach my $s ( @{$settings} ) {
			$db->insert('settings', $s);
		}
	}

	my $data = &qrcode_generator({
		timestamp => $timestamp + 1,
		app => '__president',
		name => 'citizen',
		privilege => 'citizen',
		project => 'personal',
		debriefer => '{}',
		nic => 'lo',
		warranty => '-100y',
		db => $db,
		database => $database
	});
	$db->insert('tickets', $data);

	my $backup_command = 'sqlite3 ' . &subs::shell_quote($database) . ' ' . &subs::shell_quote(".backup '$database.1.db'");
	my $backup = `$backup_command`;
	chmod 0600, $database . '.1.db' if -e $database . '.1.db';
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	my $encrypt = &subs::openssl_file_crypt('e', $encryption_standard, $secret, $database . '.1.db', $enc_file, 0, 1);
	my $appendage = $universal_splitter . &subs::encrypter($secret,$encryption_standard);
	open(my $append_fh, '>>', $enc_file) or die "append $enc_file: $!";
	print $append_fh $appendage;
	close $append_fh;
#	my $devices = &subs::device_lister($timestamp);

#	&subs::backup_now($c);
	system('shred', '-u', $database);
	system('shred', '-u', $database . '.1.db');
	system('shred', '-u', $database . '-shm');
	system('shred', '-u', $database . '-wal');
	my $new_enc_file = &subs::database_dir() . '/' . $president . '.enc';
	rename($enc_file, $new_enc_file) or $log->error("new database: rename $enc_file: $!");
#	`rm -R $temp_folder`;
#	$database = $old_db;
	&subs::say_it('New Database ' . $c->param('president'));
	$c->render(text => $database);
}

# POST /manager/configure/restore_now
# A database is per device: restoring another machine's copy leaves this one
# wearing the source's identity. Restore only onto the same machine; the
# incident and the repair: docs/AGENTS-records.md.
sub action_19489 {
	my $c = shift;
	my $filename = $c->param('filename') // '';
	my $path = $filename;
	unless (&subs::path_is_within($path, &subs::backups_dir())) {
		$c->render(json => { status => 'fail', error => 'not a backup file' });
		return;
	}
	$c->param('reason' => 'restore_database');
	my ($db) = &subs::database_grabber();
	my $credentials = &subs::db_select('security', ['level','credential'], {  });
	my $creds = $credentials->hashes;
	@{$creds} = grep { $_->{'level'} ne 'padlock' } @{$creds};
	@{$creds} = reverse @{$creds};
	my $disposition->{'status'} = 'fail';
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	foreach my $cred ( @{$creds} ) {
		my $cr = &subs::decrypter(&subs::session_suds($c),$cred->{'credential'});
		if ($path =~ /\.enc\z/i) {
			$filename =~ s/\.enc\z//i;
			my $t_database = &subs::database_path() . '.restoring';
#			my $scrypt = `printf "$cr" | scrypt dec -P $path $t_database`;
			my $tail_command = 'tail ' . &subs::shell_quote($path);
			my $data = `$tail_command`;
			my @split_data = split $universal_splitter, $data;
			$encryption_standard = &subs::backup_standard($cr, $split_data[1]);
			my $scrypt = &subs::openssl_file_crypt('d', $encryption_standard, $cr, $path, $t_database, 0, 1);
			# A database is per device: the backup row names the machine it came
			# from, and restoring another one would leave this machine wearing
			# that identity. A row with no destination predates the check.
			my $here = &subs::database_path();
			my $bak = &subs::db_select('backups', undef, { enc_file => $path })->hashes->[0];
			if ($bak && ($bak->{'destination'} // '') =~ /\S/ && $bak->{'destination'} ne $here) {
				system('shred', '-u', $t_database) if -e $t_database;
				$c->render(json => { status => 'fail', error => 'that backup belongs to another machine' });
				return;
			}
			# Prove the bytes are a database before the live one is destroyed: a
			# size above the floor is not a restore.
			my $check_command = 'sqlite3 ' . &subs::shell_quote($t_database) . ' ' . &subs::shell_quote('pragma integrity_check') . ' 2>&1';
			my $check = `$check_command`;
			unless (defined $check && $check =~ /^\s*ok\s*$/mi) {
				system('shred', '-u', $t_database) if -e $t_database;
				$c->render(json => { status => 'fail', error => 'the snapshot is not a usable database' });
				return;
			}
			if (-s $t_database > 5000) {
				&subs::backup_now($c);
				system('shred', '-u', $database);
				system('shred', '-u', $database . '-shm');
				system('shred', '-u', $database . '-wal');
				rename($t_database, $database) or $log->error("restore: rename $t_database: $!");
				$sql = Mojo::SQLite->new('sqlite:' . $database);
				my $db = $sql->db;

				my $secret = &subs::decrypter($cr,&subs::db_select('security', ['credential'], { level => 1 })->hash->{credential});
				if (secure_compare $cr, $secret) {
					$disposition->{'disposition'} = $database;
					&subs::vault_seed($secret, 1);
					$c->session('suds_id' => &subs::suds_id($secret));
					$c->session('database' => $database);
					$disposition->{'status'} = 'succeed';
					last;
				}
				else {
					$c->session('authentication' => 'rejected');
				}
			}
		}
	}

	$disposition = encode_json $disposition;
	$c->render(text => $disposition);
}

# GET /manager/configure/database_vacuum
sub action_19541 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $html = "You are about to clean up settings from the following orphaned apps<br><br>";

	my @unique_settings = &database_vacuum_bag();

	foreach my $us ( @unique_settings ) {
		$html .= '<input type="checkbox" checked="checked" app="' . $us . '" class="database_vacuum_checkbox">' . &subs::format_name($us) . "<br>";
	}

	$html .= '<img src="/images/decipherable/vacuum.png" id="database_vacuum_confirm" class="medium_thumb">';
	$html = "Your house is clean!" if scalar @unique_settings == 0;
	$c->render(json => { html => $html });
}

# POST /manager/configure/database_vacuum_confirm
sub action_19574 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $checkboxes = $c->param('checkboxes');
	$checkboxes = eval { return decode_json $checkboxes } || [];
	my $html = "You have cleaned:<br><br>";
	foreach my $us ( @{$checkboxes} ) {
		&subs::db_delete('settings', { app => $us });
		$html .= &subs::format_name($us) . "<br>";
	}

	$html .= '
		';
	$c->render(json => { html => $html });
}

# GET /manager/configure/database_doctor
sub action_19589 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $returner = { tables => [], auuid => &subs::random_string_creator(20) };
	my $tables_command = 'sqlite3 ' . &subs::shell_quote($database) . ' .tables';
	my $tables = `$tables_command`;
	@{$returner->{'tables'}} = split ' ', $tables;


	$returner->{'html'} = '<h2>You are about to perform surgery on ' . $database . '</h2>
		<h4>This process is irreversible, unless you have backups or whatever!</h4>';
	foreach my $table ( @{$returner->{'tables'}} ) {
		my $counter = &subs::db_query('select count(*) from ' . $table);
		my $count = $counter->hash->{'count(*)'};
		$returner->{'count'}->{$table} = $count;
		my $existing = &subs::db_query('select * from ' . $table)->hashes;
		my $delta = ($count - scalar @{$existing});
		my $colour = 'black';
		my $repairable = [];
		if ($delta != 0) {
			$colour = 'red';
			#if ($existing->[-1]->{'app'}) {
				my $repairs = &subs::db_query('select distinct(app) from ' . $table)->hashes;
				if ($table eq 'settings') {
				#	push @{$repairs}, ({ app => 'me' }, { app => 'misc' }, { app => '__president' });
				}
				foreach my $a ( @{$repairs} ) {
					my $ok = &subs::db_select($table, undef, { app => $a->{'app'} })->hashes;
					push @{$repairable}, @{$ok};
			#	}
			}
		}


		$returner->{'html'} .= '<span style="color:' . $colour .';"><b><u style="font-size:20px;"> ' . $table . '</u> Count:</b> ' . $count . ' <b>Shows:</b> ' . scalar @{$existing} . ' <b>Delta:</b> ' . $delta;
		if (scalar @{$repairable} > 0) {
			$returner->{'html'} .= ' <b>Repair: </b>' . scalar @{$repairable};
		}
		$returner->{'html'} .= '</span><br>';
	}
	$returner->{'html'} .= '
		<img src="/images/jbuttons/doctor.png" id="database_doctor_confirm" class="medium_thumb">';
	$c->render(json => $returner);
}

# POST /manager/configure/database_doctor_confirm
sub action_19632 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $auuid = $c->param('auuid') || &subs::random_string_creator(20);

	my $returner = { tables => [], count => {} };
	my $html = '<h2>Now repairing ' . $database . '</h2><br><h4></h4><br>';
	&Websocket::send('server', { yellow => $html, uuid => $auuid });
	my $download_location = &subs::home('~/.president');
	my $temp_folder = &subs::home($download_location . '/' . &subs::random_string_creator(10));
	system('mkdir', '-p', $temp_folder) unless -e $temp_folder;
	my $ndatabase = $temp_folder . '/' . &subs::random_string_creator(21) . '.db';
	my $tdatabase = $temp_folder . '/' . &subs::random_string_creator(20) . '.db';
	system('touch', $tdatabase);
	system('touch', $ndatabase);
	my $schema_dump = 'sqlite3 ' . &subs::shell_quote($database) . q{ .schema | grep -vE 'sqlite_stat|sqlite_sequence' > } . &subs::shell_quote("$temp_folder/schema.sql");
	`$schema_dump`;
	my $backup_command = 'sqlite3 ' . &subs::shell_quote($database) . ' ' . &subs::shell_quote(".backup '$tdatabase'");
	my $backup = `$backup_command`;

	my $import_command = 'sqlite3 ' . &subs::shell_quote($ndatabase) . ' < ' . &subs::shell_quote("$temp_folder/schema.sql");
	`$import_command`;
	my $nsql = Mojo::SQLite->new('sqlite:' . $ndatabase);
	my $ndb = $nsql->db;
	my $tsql = Mojo::SQLite->new('sqlite:' . $tdatabase);
	my $tdb = $tsql->db;
	my $tables_command = 'sqlite3 ' . &subs::shell_quote($ndatabase) . ' .tables';
	my $tables = `$tables_command`;
	@{$returner->{'tables'}} = split ' ', $tables;

	foreach my $table ( @{$returner->{'tables'}} ) {
		my $counter = $tdb->query('select count(*) from ' . $table);
		my $count = $counter->hash->{'count(*)'};
		$returner->{'count'}->{$table} = $count;

		my $existing = $tdb->query('select * from ' . $table)->hashes;
		if (scalar @{$existing} != $count) {
			my $html = '<h2>Now repairing ' . $count . ' ' . $table . '</h2><br><h4></h4><br>';
			&Websocket::send('server', { yellow => $html, uuid => $auuid });

			my $repairable = [];
			#if ($existing->[-1]->{'app'}) {
				my $repairs = $tdb->query('select distinct(app) from ' . $table)->hashes;
				foreach my $a ( @{$repairs} ) {
					my $ok = $tdb->select($table, undef, { app => $a->{'app'} })->hashes;
					foreach my $okay ( @{$ok} ) {
						my $check = $tdb->select($table, $okay)->hashes;
						if (scalar @{$check} == 0) {
							eval { $ndb->insert($table, $okay) };
						}
						else {

						}

					}
					push @{$repairable}, @{$ok};
				}
			#}

		}
		else {
			my $html = '<h2>Now inserting ' . $count . ' ' . $table . '</h2><br><h4></h4><br>';
			&Websocket::send('server', { yellow => $html, uuid => $auuid });
			foreach my $i ( @{$tdb->select($table, undef, {})->hashes} ) {
				$ndb->insert($table, $i);
			}
		}
	}
	my $backup_command = 'sqlite3 ' . &subs::shell_quote($ndatabase) . ' ' . &subs::shell_quote(".backup '$database'");
	$backup = `$backup_command`;
	system('shred', '-u', "$temp_folder/schema.sql");
	system('shred', '-u', $tdatabase);
	system('shred', '-u', $ndatabase);
	system('rm', '-R', $temp_folder);
	$c->render(json => $returner);
}

# GET /manager/configure/vacuum_app
sub action_19703 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $refusal = &subs::app_removal_refusal($app);
	if ($refusal) {
		return $c->render(text => '<h1>' . &subs::format_name($app) . '</h1>
		<h4>' . &subs::app_removal_refusal_text($refusal, 'vacuum') . '</h4>');
	}
	my $html = '<h2>' . &subs::ui('You are about to empty') . '</h2><h1>' . &subs::format_name($app) . '</h1>
		<h4>' . &subs::ui('Every record and the files those records name will be deleted. The app keeps its settings, models, options, categories, web sources and tickets. This cannot be undone.') . '</h4>
		<img src="/images/decipherable/vacuum.png" id="vacuum_app_confirm" app="'. $app . '" class="medium_thumb">';

	$c->render(text => $html );
}

# POST /manager/configure/vacuum_app_confirm
sub action_19713 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $refusal = &subs::app_removal_refusal($app);
	# The confirm panel already refused a house app and a Permanent card, but the
	# tick can change between the two presses.
	if ($refusal) {
		return $c->render(text => '<h1>' . &subs::format_name($app) . '</h1>
		<h4>' . &subs::app_removal_refusal_text($refusal, 'vacuum') . '</h4>');
	}
	# Records and the files they name go through the ordinary delete, one
	# tombstone each; the app's configuration stays.
	&vacuum_app_records($app);
	my $html = '<h1>' . &subs::format_name($app) . '</h1>
	<h4>' . &subs::ui('Its records and files are gone. Its settings are kept.') . '</h4>';
	$c->render(text => $html );
}

# POST /manager/configure/merge_database
sub action_19724 {
	my $c = shift;

	my $filename = $c->param('filename') // '';
	my $action = $c->param('action');
	unless (&subs::path_is_within($filename, &subs::backups_dir())) {
		$c->render(json => { status => 'fail', error => 'not a backup file' });
		return;
	}
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		my $configuration = {
			file => $filename,
			signatorial => &subs::signatorial_designer(),
			misc_settings => &misc_setting_list()
		};
		my $disposition = &merge_database($c,$configuration);
		my $temporary_file = $disposition->{'temporary_file'};
		#`shred -u $temporary_file` if -e $temporary_file;
		#`shred -u $temporary_file-shm` if -e $temporary_file;
		#`shred -u $temporary_file-wal` if -e $temporary_file;
		$disposition = encode_json $disposition;
	}, { name => 'merge database' });
	my $disposition = { status => 'working' };
	$c->render(json => $disposition);
}

# POST /manager/configure/notification_sound
sub action_24799 {
	my $c = shift;
	# A custom ringtone: the audio an app's notification plays. It lands beside the
	# shipped ones (public/sounds/notifications) so every sound list in Configure
	# picks it up with no further wiring; only audio is accepted, named after the
	# file itself so the list reads well, and never overwriting what is there.
	unless (&authentication_passer($c) eq 'approved') {
		$c->render(json => { ok => 0, error => 'denied' });
		return;
	}
	my $upload = $c->req->upload('sound');
	unless ($upload) {
		$c->render(json => { ok => 0, error => 'no file' });
		return;
	}
	my ($ext) = $upload->filename =~ /\.(mp3|ogg|oga|wav|m4a|aac|opus|flac)$/i;
	unless ($ext) {
		$c->render(json => { ok => 0, error => 'audio files only' });
		return;
	}
	$ext = lc $ext;
	if ($upload->size > 12 * 1024 * 1024) {
		$c->render(json => { ok => 0, error => 'that file is too big' });
		return;
	}
	my $name = $upload->filename;
	$name =~ s/\.[^.]*$//;
	$name = lc $name;
	$name =~ s/[^a-z0-9]+/-/g;
	$name =~ s/^-+|-+$//g;
	$name = 'sound' unless length $name;
	my $dir = 'public/sounds/notifications';
	my $file = "$dir/$name.$ext";
	my $i = 2;
	while (-e $file) { $file = "$dir/$name-" . $i++ . ".$ext"; }
	eval { $upload->move_to($file) };
	unless (-e $file && -s $file > 0) {
		$c->render(json => { ok => 0, error => 'could not save that' });
		return;
	}
	(my $shown = $file) =~ s{.*/}{};
	$shown =~ s/\.[^.]*$//;
	$log->info('notification sound added: ' . $file);
	$c->render(json => { ok => 1, sound => './' . $file, name => &subs::format_name($shown) });
}

# GET /manager/configure/backup_now
sub action_25152 {
	my $c = shift;
	# The sync rail is gate-exempt (hooks.pl) because a peer's session cookie
	# lapses and a gated reply - the Gate page, not JSON - silently stalled the
	# merge. Authorize here instead: the UI's own session, or a peer that signs
	# the request against its roster row, exactly like the rest of the peer rail.
	# A peer must also hold `trusted` scope: a snapshot it names is merged.
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($c->session('authentication') eq 'approved' || ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted'))) {
		$c->rendered(403);
		return;
	}
	unless ($c->param('reason')) {
		$c->param('reason' => 'backup');
	}
	else {
		my $remote_ip = $c->tx->remote_address;
	}
	my $disposition = &subs::backup_now($c);
	$c->render(json => $disposition);
}

# POST /manager/configure/delete_backup
sub action_25173 {
	my $c = shift;

	my $backup = $c->param('filename') // '';
	unless (&subs::path_is_within($backup, &subs::backups_dir())) {
		$c->render(text => 'not a backup file', status => 403);
		return;
	}
	if (-f $backup) {
		system('shred', '-u', $backup);
	}
	$c->render(text => 'backup deleted');
}

# POST /manager/configure/home_plate/save
sub action_25688 {
	my $c = shift;
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $app_uuid = $c->param('uuid');

	my $continent = &subs::db_select('continent', undef, { uuid => $uuid })->hashes->[0];
	my $homeplate = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'home_plate' }) } || {};

	my $data = {
		latitude => $continent->{'latitude'},
		longitude => $continent->{'longitude'},
		accurancy => $continent->{'accuracy'},
		uuid => $uuid
	};
	&subs::db_query('update continent set type=?, server_time=? where type=? and app=?', 'app', &subs::rightNow(), 'home_plate', $app);
	&subs::db_update('continent', { type => 'home_plate', server_time => &subs::rightNow() }, { uuid => $uuid });

	my $jplate = encode_json $data;
	&subs::setting_setter({ app => $app, setting => 'home_plate', value => $jplate });
	$c->render(json => $jplate);
}

# POST /manager/configure/home_plate/manual
sub action_25711 {
	my $c = shift;
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $device = $c->param('device');
	my $app = $c->param('app');

	my $home_plate = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'home_plate', device => $device }) } || {};
	$home_plate->{$setting} = $value;

	my $jplate = encode_json $home_plate;
	&subs::setting_setter({ app => $app, device => $device, setting => 'home_plate', value => $jplate });
	$c->render(json => $home_plate);
}

# POST /manager/configure/home_plate/settings
sub action_25725 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $home_plate = eval { return decode_json $c->param('home_plate') } || {};
	# a plate only ever triggers its own app; the owner is the app being configured
	$home_plate->{'self'} = 'on';
	$home_plate->{'app'} = $app;
	my $settings = &subs::settings_grabber({ app => $app, settings => [ 'home_plate', 'home_plate_duties'] });
	my $home_plate_duties = eval { return decode_json $settings->{'home_plate_duties'} } || [];

	if (grep { $_->{'uuid'} eq $home_plate->{'uuid'} } @{$home_plate_duties}) {
		@{$home_plate_duties} = grep { $_->{'uuid'} ne $home_plate->{'uuid'} } @{$home_plate_duties};
	}
	push @{$home_plate_duties}, $home_plate;

	$settings->{'home_plate_duties'} = encode_json $home_plate_duties;
	&subs::setting_setter({ app => $app, setting => 'home_plate_duties', value => $settings->{'home_plate_duties'} });

	$home_plate = eval { return decode_json $settings->{'home_plate'} } || {};
	$settings->{'app_home_plate'} = $home_plate;
	$settings->{'home_plate'} = $home_plate->{'latitude'} . ' ' . $home_plate->{'longitude'};

	my $html = $c->render_to_string(
		template => 'configure/home_plate',
		app => $app,
		settings => $settings
	);

	$c->render(json => { home_plate => $home_plate, html => $html });

}

# POST /manager/configure/home_plate/settings/delete
sub action_25757 {
	my $c = shift;
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');

	my $hpd = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'home_plate_duties' }) } || [];
	@{$hpd} = grep { $_->{'uuid'} ne $uuid } @{$hpd};
	#if (scalar @{$hpd} > 0) {
		my $jhpd = encode_json $hpd;
		&subs::setting_setter({ app => $app, setting => 'home_plate_duties', value => $jhpd });
	#}
	#else { &subs::setting_deleter({ app => $app, setting => 'home_plate_duties' }); }

	$c->render(text => 'ok');
}

# POST /manager/configure/environment/qr
sub action_26620 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $pos = $c->param('pos');
	$pos = '' unless defined $pos;
	# No shell: the payload is the caller's text, so a list-form pipe hands it
	# to qrencode as exactly one argument.
	my $qr = '';
	if (open my $qr_pipe, '-|', 'qrencode', '-o', '-', $pos) {
		local $/;
		$qr = <$qr_pipe> // '';
		close $qr_pipe;
	}
	my $returner = { qr => $qr, app => $app, 'pos' => $pos };
	$c->render(json => $returner);
}

# GET /manager/configure/sms_list_check
sub action_41150 {
	my $c = shift;
	my $returner = &subs::sms_list_check();
	$c->render(text => $returner);
}

# GET /manager/configure/adopt_app
sub action_41659 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $misc_settings = &misc_setting_list();

	# Every configured location that holds this app's folder, deduped by path.
	my @folders;
	my %seen_folder;
	foreach my $ms ( sort keys %{ $misc_settings->{$device} || {} } ) {
		next unless $ms =~ /^(.+)_location$/;
		my $key = $1;
		my $value = $misc_settings->{$device}->{$ms};
		next unless defined $value && length $value;
		my $folder = &subs::home($value . '/' . &subs::path_name($app));
		next unless -d $folder;
		next if $seen_folder{$folder}++;
		push @folders, { key => $key, name => &subs::format_name($key), path => $folder };
	}

	# One query for the whole app, not one per directory entry. A row's file
	# column is JSON (a hash or a list of them); gather the paths, thumbs,
	# previews and original names so the scan can tell adopted from new.
	my %known_paths;
	my %known_names;
	my $rows = &subs::db_query('select file from appointments where app = ? and file is not null', $app)->hashes;
	foreach my $row ( @{$rows} ) {
		my $decoded = eval { decode_json $row->{'file'} } || [];
		$decoded = [$decoded] if ref $decoded eq 'HASH';
		next unless ref $decoded eq 'ARRAY';
		foreach my $fh ( @{$decoded} ) {
			next unless ref $fh eq 'HASH';
			foreach my $k ( 'f', 'thumb', 'preview' ) {
				$known_paths{$fh->{$k}} = 1 if defined $fh->{$k} && length $fh->{$k};
			}
			$known_names{$fh->{'of'}} = 1 if defined $fh->{'of'} && length $fh->{'of'};
		}
	}

	my $sections = &subs::adopt_scan_candidates(\@folders, \%known_paths, \%known_names);

	my $html = '';
	my $candidates = 0;
	foreach my $section ( @{$sections} ) {
		$html .= '<h3>' . xml_escape($section->{'name'}) . ':</h3> ' . xml_escape($section->{'path'}) . '<br>';
		foreach my $candidate ( @{ $section->{'files'} || [] } ) {
			my $path = $candidate->{'file'};
			my $name = $candidate->{'name'};
			my $type = $candidate->{'type'};
			my $stamp = int(((stat($path))[9] || 0) * 1000);
			my $file_q = &subs::url_escape_utf8($path);
			my $app_q = &subs::url_escape_utf8($app);
			my $file_url = xml_escape('/file_open?file=' . $file_q . '&timestamp=' . $stamp . '&app=' . $app_q);
			my $app_e = xml_escape($app);
			my $name_e = xml_escape($name);
			my $path_e = xml_escape($path);
			$candidates++;
			if ($type eq 'image') {
				$html .= '<img class="gigantic_thumb adopt_file" type="image" app="' . $app_e . '" timestamp="' . $stamp . '" file="' . $path_e . '" adopted="yes" loading="lazy" decoding="async" src="' . $file_url . '" alt="' . $name_e . '">';
			}
			elsif ($type eq 'video') {
				$html .= '<video class="gigantic_thumb adopt_file" type="video" app="' . $app_e . '" timestamp="' . $stamp . '" file="' . $path_e . '" adopted="yes" preload="metadata" title="' . $name_e . '" src="' . $file_url . '"></video>';
			}
			else {
				$html .= '<div class="gigantic_thumb adopt_file" type="' . xml_escape($type) . '" app="' . $app_e . '" timestamp="' . $stamp . '" file="' . $path_e . '" adopted="yes" title="' . $name_e . '"><img src="/images/decipherable/file.png" class="medium_thumb"><span>' . $name_e . '</span></div>';
			}
		}
	}
	if ($candidates) {
		$html .= '<br><br><img src="/images/decipherable/adopt.png" class="medium_thumb" app="' . xml_escape($app) . '" id="adopt_app_confirm" hint="Adopt">';
	}
	else {
		$html .= '<div class="adopt_empty">' . xml_escape(&subs::ui('No files to adopt in this app\'s folders.')) . '</div>';
	}
	$c->render('text' => $html);
}

# POST /manager/configure/adopt_app_confirm
sub action_41704 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $timestamp = $c->param('timestamp');

	my $files = eval { decode_json($c->param('files') // '') } || [];
	$files = [$files] if ref $files eq 'HASH';
	$files = [] unless ref $files eq 'ARRAY';

	# The folders a selection may live under: <location>/<app> for every configured
	# location, exactly where the listing looked. A file from another app's folder
	# is not adopted by naming it here.
	my $misc_settings = &misc_setting_list();
	my $app_path = &subs::path_name($app);
	my @roots;
	foreach my $ms ( sort keys %{ $misc_settings->{$device} || {} } ) {
		next unless $ms =~ /_location$/;
		my $value = $misc_settings->{$device}->{$ms};
		next unless defined $value && length $value;
		push @roots, &subs::home($value . '/' . $app_path);
	}

	# Only a real, unsealed file inside a configured root is adoptable, and the
	# type comes from the path - never from the client's posted value.
	my @clean;
	my %seen;
	foreach my $entry ( @{$files} ) {
		next unless ref $entry eq 'HASH';
		my $path = $entry->{'file'};
		next unless defined $path && length $path;
		next unless -f $path;
		next if $path =~ /\.enc\z/i;
		next if $seen{$path}++;
		my $within = 0;
		foreach my $root ( @roots ) {
			if (&subs::path_is_within($path, $root)) { $within = 1; last; }
		}
		next unless $within;
		my $type = &subs::adopt_media_type($path) or next;
		push @clean, { file => $path, type => $type };
	}

	unless (scalar @clean) {
		$c->render(json => { ok => 0, error => &subs::ui('Nothing was selected to adopt.') });
		return;
	}

	my $upload_type;
	foreach my $clean ( @clean ) {
		if ($clean->{'type'} eq 'image') { $upload_type = 'image'; last; }
	}
	if (!$upload_type) {
		foreach my $clean ( @clean ) {
			if ($clean->{'type'} eq 'video') { $upload_type = 'video'; last; }
		}
	}
	$upload_type ||= $clean[0]->{'type'};

	my $push_files = [];
	foreach my $clean ( @clean ) {
		my $path = $clean->{'file'};
		my $derived_type = $clean->{'type'};
		my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $path, app => $app, type => $derived_type, is_thumb => 1 });
		my $data = { server_time => &subs::rightNow(), f => $path, uuid => &subs::random_string_creator(8), type => $derived_type, thumb => $destination . $asset };
		$data = &thumbnail_creator($data);
		# A type with no renderable preview (audio, software) keeps the destination
		# the renamer proposed even though nothing wrote it. Drop it so the row does
		# not point at a missing file.
		delete $data->{'thumb'} unless defined $data->{'thumb'} && length $data->{'thumb'} && -e $data->{'thumb'};
		push @{$push_files}, $data;
	}

	# Keep the JSON in one scalar: the list-operator form file => encode_json
	# swallows the timestamp and type keys that follow it.
	my $files_json = encode_json $push_files;
	&appointment_writer($c,{
		app => $app,
		file => $files_json,
		timestamp => $timestamp,
		type => $upload_type
	});
	$c->render(json => { ok => 1 });
	&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => &subs::session_suds($c) });
}

# POST /manager/configure/password_update
sub action_42942 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $server_time = &subs::rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	$c->param('reason' => 'password_update');
	&subs::backup_now($c);
	my $numerics = &password_maker($c);
	if ($numerics eq 'noway') {
		$c->render(json => { result => 'ok' });
		$c->rendered;
		return;
	}
	# a password change re-keys only the door. The house key stays: the vault,
	# the canary and every sealed value are untouched, and the recovery code
	# keeps working. The old credential rows are normalised to the key so
	# note_decrypter's historical tries stay usable.
	my $K = &subs::session_suds($c);
	if ($K && &subs::door_set($numerics)) {
		my $cred_hunt = &subs::db_select('security', ['credential','level','server_time','timestamp'], { });
		my $creds = $cred_hunt->hashes;
		@{$creds} = grep { $_->{'level'} ne 'padlock' && $_->{'level'} ne 'door' && $_->{'level'} ne 1 } @{$creds};
		foreach my $cr ( @{$creds} ) {
			my $credjawntial = &subs::decrypter($K,$cr->{'credential'});
			next unless defined $credjawntial && length $credjawntial;
			my $newjawntial = &subs::encrypter($K,$credjawntial);
			next unless $newjawntial;
			&subs::db_update('security', { credential => $newjawntial }, { timestamp => $cr->{'timestamp'}, server_time => $cr->{'server_time'} });
		}
		$c->session('suds_id' => &subs::suds_id($K));
		&subs::db_delete('security', { level => 'padlock' });
		&subs::db_delete('settings', { app => '__president', setting => 'pl_time' });
		&subs::db_delete('settings', { app => '__president', setting => 'padlock_pulls' });
		$c->render(json => { result => 'ok' });
		&subs::say_it('Password has been updated');
	}
	else {
		&subs::say_it('no dice mister!');
		$c->render(json => { result => 'fail' });
	}
}

# A manual nudge for the bridge's adopt scan. The scan already runs every 30 s;
# this button exists so a device that was just powered on can be met at once.
# It runs off the request (the scan takes several seconds) and the Dev panel
# refreshes after it.
# POST /manager/configure/ble_scan
sub action_43843 {
	my $c = shift;
	&subs::subprocessor(sub { &subs::ble_adopt_scan(); }, { name => 'manual ble adopt scan' });
	$c->render(json => { ok => 1, scanning => 1 });
}

1;
