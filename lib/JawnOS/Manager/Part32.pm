package Manager;

# Manager helpers, part 32 of 37. Moved out of Manager.pl so a
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

sub lorawan_devices {
	my $list = &subs::device_lister(&subs::rightNow(), 'teletype', undef, 'all');
	my @rows = eval { @{$list} };
	my ( @out, %seen );
	foreach my $d (@rows) {
		next unless ref $d eq 'HASH' && $d->{'ip'} && !$seen{ $d->{'ip'} }++;
		my $caps = $d->{'capabilities'} || $d->{'caps'} || '';
		$caps = encode_json($caps) if ref $caps;
		next unless (($d->{'purpose'} || '') eq 'teletype' || $caps =~ /lora/i);
		push @out, {
			name => $d->{'name'} || $d->{'computer_name'} || $d->{'chip_id'} || $d->{'ip'},
			ip => $d->{'ip'},
			chip_id => $d->{'chip_id'},
		};
	}
	return \@out;
}

sub lorawan_secret($c) {
	my $od = &subs::setting_grabber({ app => 'watch', setting => 'operator_door' });
	my $op = eval { decode_json $od } || {};
	my $patience = $op->{'__shutup'}->{'patience'};
	my $suds = eval { &subs::session_suds($c) };
	return 'manager' unless $patience && $suds;
	my $secret = &subs::note_encrypter($patience, $suds);
	$secret =~ s/\s+//g;
	return MIME::Base64::encode_base64($secret, '');
}

sub lorawan_deck_call($path, $form) {
	my $decks = &lorawan_devices();
	return { ok => 0, error => 'No LoRa-capable T-Deck is online.' } unless scalar @{$decks};
	my @results;
	foreach my $d ( @{$decks} ) {
		my $url = 'http://' . $d->{'ip'} . ':' . ($config->{'port'} || 80) . $path;
		my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 60, request_timeout => 65);
		my $tx = eval { $ua->post($url => form => $form) };
		my $res = ( $tx && !$tx->error ) ? eval { decode_json($tx->res->body) } : undef;
		if ( $tx && !$tx->error && $tx->res->is_success && ref $res eq 'HASH' ) {
			push @results, { device => $d->{'name'}, ip => $d->{'ip'}, ok => 1, result => $res };
		}
		else {
			my $why = ( $tx && $tx->error ) ? ( $tx->error->{'message'} || 'no answer' ) : 'no answer';
			push @results, { device => $d->{'name'}, ip => $d->{'ip'}, ok => 0, error => $why };
		}
	}
	my ($good) = grep { $_->{'ok'} } @results;
	return $good if $good;
	return { ok => 0, error => 'No T-Deck answered.', devices => \@results };
}

sub lorawan_push_config($c) {
	my $s = &lorawan_settings();
	return &lorawan_deck_call('/lorawan_config', {
		s => &lorawan_secret($c),
		enabled => $s->{'enabled'},
		band => $s->{'band'},
		subband => $s->{'subband'},
		join_eui => $s->{'join_eui'},
		dev_eui => $s->{'dev_eui'},
		app_key => $s->{'app_key'},
		fport => $s->{'fport'},
		confirmed => $s->{'confirmed'},
	});
}

sub lorawan_send_text($text) {
	my $s = &lorawan_settings();
	return { ok => 0, error => 'LoRaWAN is not enabled.' } unless $s->{'enabled'} eq 'on';
	return { ok => 0, error => 'There is nothing to send.' } unless defined $text && length $text;
	return &lorawan_deck_call('/lorawan_send', {
		s => 'manager',
		message => $text,
		confirmed => $s->{'confirmed'},
	});
}

sub lorawan_webhook_text($body) {
	my $text = '';
	if ( ref $body->{'uplink_message'} eq 'HASH' ) {
		my $up = $body->{'uplink_message'};
		if ( ref $up->{'decoded_payload'} eq 'HASH' ) {
			$text = $up->{'decoded_payload'}->{'text'} || $up->{'decoded_payload'}->{'message'} || $up->{'decoded_payload'}->{'msg'} || '';
		}
		if ( !length $text && $up->{'frm_payload'} ) {
			my $bytes = eval { decode_base64($up->{'frm_payload'}) };
			if ( defined $bytes && length $bytes ) {
				my $decoded = eval { decode_json($bytes) };
				if ( ref $decoded eq 'HASH' ) {
					$text = $decoded->{'text'} || $decoded->{'message'} || $decoded->{'msg'} || '';
				}
				else {
					$text = $bytes;
				}
			}
		}
	}
	$text ||= $body->{'text'} || $body->{'message'} || $body->{'msg'} || $body->{'payload'} || '';
	if ( ref $text ) {
		$text = $text->{'text'} || $text->{'message'} || '' if ref $text eq 'HASH';
	}
	$text = "$text";
	$text =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]+//g;
	$text =~ s/^\s+|\s+$//g;
	return $text;
}

sub delete_app($app,$uuid,$server_time,$reason,$silent = 0) {
	# The rows are fetched before the websocket send, not after it: send dials the
	# database, and the kept handle finishes whatever statement was left unfetched
	# on its way past, so a result read after it comes back empty. Fetched late,
	# this sub only ever removed the appointment from the page, never the table.
	my $appts = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes;
	&Websocket::send($app, { console => &Websocket::console_command('removeAppointmentDetail', $app, $uuid)});
	my $status = '';
	if (scalar @{$appts} > 0) {

		# a transaction that paid an invoice left a payment on the invoice's
		# data; deleting the transaction takes the payment back out with it,
		# or the invoice stays paid by a row that no longer exists
		foreach my $app ( @{$appts} ) {
			&invoice_payment_deleter($app->{'uuid'});
		}

		foreach my $app ( @{$appts} ) {
			&subs::db_update('appointments', { status => 'deleting' }, { uuid => $app->{'uuid'}, app => $app->{'app'} });
			$status = $app->{'type'};
			&subs::db_delete('continent', { app => $app->{'app'}, uuid => $app->{'uuid'} });
			&subs::db_query('delete from continent where app = ? and uuid like ?', $app->{'app'}, $app->{'uuid'} . '%' );

			if ($app->{'file'} && $app->{'source'} ne 'music' && $app->{'account'} ne 'gallery' && $app->{'type'} ne 'view' && $app->{'type'} ne 'listen') {
				my $filings = eval { return decode_json $app->{'file'} } || [];
				foreach my $f (@{$filings}) {
					my $filing = $f->{'f'};
					&delete_file({ app => $app->{'app'}, app_uuid => $uuid, file_uuid => $f->{'uuid'}, reason => 'delete_app' });
					if ($f->{'mail_uuid'}) {
						$log->info('got the mail_uuid ' . $f->{'mail_uuid'});

						&subs::db_delete('mailbox', { uuid => $f->{'mail_uuid'} });
						&Websocket::send('tab', { console => &Websocket::console_command('removeMailbox', $f->{'mail_uuid'})});
					#	&subs::deletion_registration({ table => 'mailbox', uuid => $f->{'mail_uuid'}, scope => 'single', server_time => $f->{'server_time'} });
					}
				}
			}
			&subs::db_delete('appointments', { uuid => $app->{'uuid'} });
			# a deleted row takes its warehouse rows with it - the money move, the
			# balance anchor, and the stock and usage it recorded (each is keyed to the
			# source uuid, so nothing else is touched)
			&subs::db_query('delete from warehouse where kind = ? and uuid = ?', 'money', $app->{'uuid'});
			&subs::db_query("delete from warehouse where kind = 'inventory' and app_uuid = ?", $app->{'uuid'});
			&subs::db_query("delete from warehouse where kind = 'stock' and app_uuid = ?", $app->{'uuid'});
			&subs::db_query("delete from warehouse where kind = 'usage' and app_uuid = ?", $app->{'uuid'});
			# A model/option child names its parent in source_uuid; the parent's
			# list is what its details view reads, so the deleted child leaves it.
			&subs::source_model_option_remove($app->{'source_uuid'}, $app->{'app'}, $app->{'uuid'}, $app->{'type'})
				if $app->{'source_uuid'};
		}

		&embedded_app_deleter({ appt_uuid => $uuid });
		my $sources = &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes;
		my %so_seen;
		foreach my $so ( @{$sources} ) {
			next if $so_seen{ $so->{'uuid'} }++;
			&embedded_app_deleter({ appt_uuid => $so->{'uuid'} });
			&delete_app($so->{'app'},$so->{'uuid'},$so->{'server_time'},'source deletion');
		}
		# A default model/option chain may still be writing while this delete runs -
		# it is forked after the press now. Sweep once more for a child that landed
		# between the first read and here, so it goes with its parent.
		foreach my $so ( @{ &subs::db_select('appointments', undef, { source_uuid => $uuid })->hashes || [] } ) {
			next if $so_seen{ $so->{'uuid'} }++;
			&delete_app($so->{'app'},$so->{'uuid'},$so->{'server_time'},'late source deletion');
		}
		&Websocket::send('tab', { console => &Websocket::console_command('removeAppointmentDetail', $app, $uuid)});
		&deletion_registration({ table => 'appointments', app => $app, uuid => $uuid, scope => 'single', server_time => $server_time });
		&subs::vacuum($app) unless $silent;
		&subs::log_writer('deletion ' . $app . ' '  . $reason);

		&budget_runner($app);
		unless ($silent) {
			# The header is the fast half and goes out now, so the deleted row leaves
			# the header at once. The window render is the slow half and is forked so
			# the delete does not wait for a full redraw.
			&subs::appt_header_printer({ app => $app, timestamp => &subs::rightNow() });
			&subs::subprocessor(sub {
				Mojo::IOLoop->reset;
				&centre_view_grabber({ app => $app, timestamp => &subs::rightNow(), cached => 'no' });
			}, { name => 'centre view' });
		}
	}
	return { appts => $appts, status => $status };
}

sub invoice_payment_deleter($uuid) {
	# called when an appointment is deleted: if it was the transaction a
	# payment on an invoice points at, the payment is unwound - removed from
	# the invoice's payments and its amount put back on the balance, and a
	# document marked completed reopens
	my $invoices = &subs::db_query("select * from appointments where type = ? and data like ?", 'invoice', '%' . $uuid . '%')->hashes;
	foreach my $inv ( @{$invoices} ) {
		my $data = eval { return decode_json $inv->{'data'} } || {};
		my $payments = $data->{'payments'} || [];
		my @kept = grep { ($_->{'appt_uuid'} || '') ne $uuid } @{$payments};
		next if scalar @kept == scalar @{$payments};
		my $reversed = 0;
		foreach my $p ( @{$payments} ) {
			$reversed += $p->{'amount'} if ($p->{'appt_uuid'} || '') eq $uuid && defined $p->{'amount'};
		}
		$data->{'payments'} = \@kept;
		$data->{'numbers'}->{'balance'} = ($data->{'numbers'}->{'balance'} || 0) + $reversed;
		my $inv_status = $inv->{'status'};
		$inv_status = 'open' if $inv_status eq 'completed' && $data->{'numbers'}->{'balance'} > 0;
		# encode_json is a list operator: without its own parentheses it eats the
		# rest of the hash, so status and server_time were never sent and the
		# balance was restored without the document reopening.
		&subs::db_update('appointments', { data => encode_json($data), status => $inv_status, server_time => &subs::rightNow() }, { app => $inv->{'app'}, uuid => $inv->{'uuid'} });
		$log->info('payment of ' . $reversed . ' reversed on ' . $inv->{'app'} . ' ' . $inv->{'uuid'} . ' (deleted ' . $uuid . ')');
		&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $inv->{'app'}, $inv->{'uuid'})});
	}
}

sub is_folder_empty {
	my $dirname = shift;
	opendir(my $dh, $dirname);# or die "Not a directory";
	return scalar(grep { $_ ne "." && $_ ne ".." } readdir($dh)) == 0;
}

sub delete_file($data) {
	my $file_uuid = $data->{'file_uuid'};
	return unless $data->{'file_uuid'};
	my $app_uuid = $data->{'app_uuid'};
	my $app = $data->{'app'};

	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];
	my $removed = 0;
	foreach my $file ( grep { $_->{'uuid'} eq $file_uuid } @{$files} ) {
		$removed++;
		my $filing = $file->{'f'};
		my $thumb = $file->{'thumb'};
		my $preview = $file->{'preview'};
		if ($file->{'att'}) {
			my $att_file = &subs::db_select($file->{'att'}, undef, { uuid => $file->{'att_uuid'}, app => $appt->{'app'} })->hashes->[0];

			my $atf = eval { return decode_json $att_file->{'file'} } || [];
			@{$atf} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$atf};

			my $jaf = encode_json $atf;
			&subs::db_update($file->{'att'}, { file => $jaf, server_time => &subs::rightNow() }, { uuid => $att_file->{'uuid'}, app => $att_file->{'app'} });
		}

		if ($file->{'function'} eq 'signatorial') {
			my $signatorials = eval { return decode_json &subs::setting_grabber({ app => 'customs', setting => 'signatorials' }) } || [];
			@{$signatorials} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$signatorials};
			my $jsignatorials = encode_json $signatorials;
			&subs::setting_setter({ app => 'customs', setting => 'signatorials', value => $jsignatorials });
		}
		elsif ($file->{'function'} eq 'receipt') {
			my $receipts = eval { return decode_json &subs::setting_grabber({ app => 'budget', setting => 'receipts' }) } || [];
			@{$receipts} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$receipts};
			my $jreceipts = encode_json $receipts;
			&subs::setting_setter({ app => 'budget', setting => 'receipts', value => $jreceipts });
		}
		elsif ($file->{'function'} eq 'map') {
			my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
			@{$maps} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$maps};
			my $jmaps = encode_json $maps;
			&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
		}
		elsif ($file->{'function'} eq 'diagram') {
			my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'handbook', setting => 'diagrams' }) } || [];
			@{$diagrams} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$diagrams};
			my $jdiagrams = encode_json $diagrams;
			&subs::setting_setter({ app => 'handbook', setting => 'diagrams', value => $jdiagrams });
		}
		elsif ($file->{'function'} eq 'background') {
			my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
			@{$backgrounds} = grep { $_->{'uuid'} ne $file->{'uuid'} } @{$backgrounds};
			my $jbackgrounds = encode_json $backgrounds;
			&subs::setting_setter({ app => 'marker', setting => 'background', value => $jbackgrounds });
		}

		if ($thumb && -e $thumb) {
			&subs::secure_unlink($thumb);
			my @folder = split '/', $thumb;
			pop @folder;
			my $folder = join '/', @folder;
			if (&is_folder_empty($folder)) {
				rmdir( $folder );
			}
		}

		# The preview is a second copy beside the file (TIFF/XCF/HEIC); it must
		# go with it, and the Android runtime has no shred, so secure_unlink.
		&subs::secure_unlink($preview) if $preview && -e $preview;
		if (-e $filing) {
			my $file = $filing;
			&subs::secure_unlink($file);
			my @folder = split '/', $file;
			pop @folder;
			my $folder = join '/', @folder;

			my $thumb_folder = $folder . '/.thumbs';
			if (-e $thumb_folder) {
				if (&is_folder_empty($thumb_folder)) {
					rmdir( $thumb_folder );
				}
			}

			if (&is_folder_empty($folder)) {
				rmdir( $folder );
			}
		}
	}
	# A repeated deletion (a peer echoing the tombstone back, a late click) is a
	# no-op. Without this it wrote a fresh tombstone and a websocket update every
	# time the same uuid arrived, so the durable log grew on every sync pass.
	return unless $removed;
	@{$files} = grep { $_->{'uuid'} ne $file_uuid } @{$files};
	my $jfiles = encode_json $files;
	if (scalar @{$files} == 0 && $data->{'reason'} ne 'delete_app' && grep { $appt->{'type'} eq $_ } qw/image video scan/) {
		&delete_app($app,$app_uuid,$appt->{'server_time'},'file deletion');
	}
	&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jfiles }, { app => $app, uuid => $app_uuid });
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $app_uuid)});
	&deletion_registration({ table => 'appointments', app => $app, uuid => $app_uuid, file_uuid => $file_uuid, scope => 'file', server_time => $appt->{'server_time'} });
}

sub deletion_performer($json) {
	my $deletions = eval { return decode_json $json } || [];
	my $returner = [];
	if (scalar @{$deletions} == 0) { return []; }
	foreach my $deletion ( @{$deletions} ) {
		if ($deletion->{'table'} eq 'appointments') {
			if ($deletion->{'scope'} eq 'single') {
				&delete_app($deletion->{'app'},$deletion->{'uuid'},$deletion->{'server_time'},'deletion performer single');
			}
			elsif ( $deletion->{'scope'} eq 'vacuum' ) {
				&subs::vacuum_app($deletion->{'app'});
			}
			elsif ( $deletion->{'scope'} eq 'appointments' ) {
				# A readings-only retirement: the app's records go, its settings
				# stay. The Weather app key also holds the new UI's places, so a
				# vacuum would retire more than the old web readings.
				my $app = $deletion->{'app'};
				if (defined $app && length $app) {
					&subs::db_query('delete from appointments where app = ?', $app);
					&subs::db_query('delete from continent where app = ?', $app);
				}
			}
			elsif ( $deletion->{'scope'} eq 'file' ) {
				my $extra = eval { return decode_json $deletion->{'additional'} } || {};
				my $file_uuid = $deletion->{'file_uuid'} || $extra->{'file_uuid'};
				&delete_file({ app => $deletion->{'app'}, app_uuid => $deletion->{'uuid'}, file_uuid => $file_uuid }) if defined $file_uuid && length $file_uuid;
			}
		}
		elsif (($deletion->{'table'} || '') eq 'settings' && defined(my $setting_key = &subs::settings_deletion_key($deletion))) {
			# A settings row is named by its key, not a uuid. Apply the tombstone
			# only to a row that is not newer than it: a deliberate re-add after
			# the deletion must survive a stale peer's log.
			my ($dapp, $dsetting, $dsubsetting, $ddevice) = split /\x1f/, $setting_key, 4;
			$dsubsetting = undef unless defined $dsubsetting && length $dsubsetting;
			$ddevice = undef unless defined $ddevice && length $ddevice;
			my %where = (app => $dapp, setting => $dsetting);
			$where{'subsetting'} = $dsubsetting if defined $dsubsetting;
			$where{'device'} = $ddevice if defined $ddevice;
			my $tomb_time = &subs::settings_deletion_time($deletion);
			my $held = &subs::db_select('settings', ['server_time'], \%where)->hashes || [];
			my $newer = grep {
				(defined $_->{'server_time'} && $_->{'server_time'} =~ /^\d+$/ ? $_->{'server_time'} + 0 : 0) > $tomb_time
			} @{$held};
			&subs::setting_deleter({
				app => $dapp, setting => $dsetting,
				subsetting => $dsubsetting, device => $ddevice,
				server_time => $tomb_time,
			}) unless $newer;
		}
		else {
			# A settings record that does not name its key is not one this mesh
			# wrote; deleting by a missing uuid would be a broad `uuid IS NULL`.
			next if ($deletion->{'table'} || '') eq 'settings';
			&subs::db_delete($deletion->{'table'}, { uuid => $deletion->{'uuid'} });
		}
		push @{$returner}, $deletion;
	}
	return $returner;
}

sub apply_peer_tombstones {
	my ($rj, $signatorial) = @_;
	return 0 unless ref $rj eq 'HASH';
	&deletion_performer($rj->{'deletions'}) if $rj->{'deletions'};
	return 0 unless ref $rj->{'tombstones'} eq 'ARRAY' && scalar @{$rj->{'tombstones'}};
	my @dels = map { { table => $_->{'tbl'}, app => $_->{'app'}, uuid => $_->{'uuid'}, scope => $_->{'scope'}, server_time => $_->{'server_time'}, additional => $_->{'additional'} } } @{$rj->{'tombstones'}};
	&deletion_performer(encode_json \@dels) if scalar @dels;
	&subs::db_update('remote_machines', { sync_cursor => ($rj->{'sync_cursor'} || 0) }, { signatorial => $signatorial })
		if $signatorial;
	return scalar @dels;
}

sub clothesline_calculator($app) {
#	my $appts = &subs::db_select('appointments', undef, { app => $app })->hashes;
	my $appts = &subs::db_query('select * from appointments where app = ? order by timestamp desc limit 1000', $app)->hashes;
	my $time_plinkos = clone $gb::time_plinkos;

	foreach my $appt ( @{$appts} ) {
		my $time = localtime($appt->{'timestamp'} / 1000);
		for (my $n = 0; $n <= 8; $n++) {
			my $ft = $time->[$n];
			if ($n == 2) {
				if ($ft == 0) {
					$ft = '12am';
				}
				elsif ($ft >= 12) {
					if ($ft == 12) { $ft = 24; }
					$ft = ($ft - 12) . 'pm';
				}
				elsif ($time->[$n] > 0 && $time->[$n] < 13) {
					$ft .= 'am';
				}
			}
			if ($n == 4) { $ft = $time->monname; }
			if ($n == 5) { $ft += 1900; }
			if ($n == 6) { $ft = $time->wdayname; }
			push @{$time_plinkos->[$n]->{'clothes'}}, { formatted => $ft, value => $time->[$n] };
		}
	}
	foreach my $tp ( @{$time_plinkos} ) {
		foreach my $cl ( @{$tp->{'clothes'}} ) {
			my @seen = grep { $_->{'formatted'} eq $cl->{'formatted'} } @{$tp->{'clothes'}};
			if (scalar @seen >= 2) {
				$tp->{'reoccuring'}->{$cl->{'formatted'}} = [] unless $tp->{'reoccuring'}->{$cl->{'formatted'}};
				push @{$tp->{'reoccuring'}->{$cl->{'formatted'}}}, $cl;
			}
		}
	}
	&subs::hang_to_dry();
	return $time_plinkos;
}

sub credential_hints_clean($raw) {
	my @hints;
	if (ref $raw eq 'ARRAY') { @hints = @$raw; }
	elsif (defined $raw && length $raw) {
		my $decoded = eval { decode_json $raw };
		@hints = ref $decoded eq 'ARRAY' ? @$decoded : split /,/, $raw;
	}
	my @out;
	foreach my $h ( @hints ) {
		next unless defined $h;
		$h = lc $h;
		$h =~ s/^\s+|\s+$//g;
		$h = substr($h, 0, 120);
		next unless length $h;
		push @out, $h unless grep { $_ eq $h } @out;
		last if scalar @out >= 30;
	}
	return \@out;
}

sub credential_gate($c) {
	return 'auth' unless ($c->session('authentication') || '') eq 'approved';
	return 'locked' if &padlock_locked_now($c);
	return '';
}

sub credential_payload_read($suds, $row) {
	return {} unless $suds && ref $row eq 'HASH' && defined $row->{'payload'} && length $row->{'payload'};
	my $plain = &subs::note_decrypter($suds, $row->{'payload'});
	return {} unless defined $plain && length $plain;
	my $data = eval { decode_json $plain };
	return ref $data eq 'HASH' ? $data : {};
}

sub currency_unit($unit) {
	return 0 unless defined $unit && length $unit;
	return 1 if &subs::crypto_asset($unit);
	return 1 if &subs::crypto_fiat($unit);
	my $m = $gb::measures->{$unit} || $gb::measures->{uc $unit} || $gb::measures->{lc $unit};
	return 0 unless $m && ref $m->{'types'} eq 'ARRAY';
	return scalar( grep { $_ eq 'currency' } @{$m->{'types'}} ) ? 1 : 0;
}

sub formula_calculator($formula) {
	my @formula = split / /, $formula;
	my ($evaluation,$uom,$format);
	my $formulas = [];
	if ($formula =~ /[a-zA-Z]/) {
		for (my $n = 0; $n <= scalar @formula; $n++ ) {
			if ($formula[$n] eq 'to') {
				my $pre = $formula[$n - 1];
				my $pre_unit = $pre;
				my $pre_number = $pre;
				$pre_number =~ s/[A-Za-z]//gi;
				$pre_unit =~ s/[0-9.-]//gi;
				# "5 USD to CAD" puts the number one token earlier; the compact
				# "5USD to CAD" is the usual form, but read the spaced one too.
				if ($pre_number eq '' && $n >= 2 && $formula[$n - 2] =~ /^\d/) {
					$pre_number = $formula[$n - 2];
				}

				my $post = $formula[$n + 1];
				my $post_number = $post;
				my $post_unit = $post;

				$post_number =~ s/[A-Za-z]//gi;
				$post_unit =~ s/[0-9.-]//gi;

				my $post_measure = $gb::measures->{$post_unit};
				unless ($post_measure) {
					foreach my $pu ( ( lc $post_unit, uc $post_unit ) ) {
						$post_measure = $gb::measures->{$pu};
						if ($post_measure->{'name'}) { last; }
					}
				}



				# A currency pair is a live rate now (Configure -> Plat -> Crypto
				# refreshes the snapshot every half hour). gb.pl's constants are the
				# offline fallback while no snapshot exists yet.
				if (&currency_unit($pre_unit) && &currency_unit($post_unit)) {
					my $rate = &subs::exchange_rate($pre_unit, $post_unit);
					if (defined $rate) {
						my $n = $pre_number;
						$n = 1 if $n eq '' || $n eq '-' || $n eq '+';
						$evaluation = $n * $rate;
						$uom = $post_unit;
						$format = $post_measure ? ($post_measure->{'format'} || '0.00') : '0.00';
						push @{$formulas}, $n . ' * ' . $rate . $post_unit;
					}
				}
				unless (defined $evaluation) {
				foreach my $for ( @{$gb::measures->{$pre_unit}->{'formulas'}} ) {
					if ($for =~ /\Q$post_unit/gi) {
						$for =~ s/x/\Q$pre_number/gi;
						$for =~ s/\Q$post_unit//gi;
						$for =~ s/\\//gi;

						push @{$formulas}, $for;
						$evaluation = eval  $for;
						last if $post_unit eq $post;
						if ($gb::measures->{$post_unit}->{'format'}) {
							$format = $gb::measures->{$post_unit}->{'format'};
						}
						else {
							$format = '0.000';
						}
						$uom = $post_unit;
					}
				}
				}

#				foreach my $for ( @{$gb::measures->{$post_unit}->{'formulas'}} ) {
#					if ($for =~ /\Q$pre_unit/gi) {
#						$for =~ s/x/\Q$pre_number/gi;
#						$for =~ s/\Q$pre_unit//gi;
#						$for =~ s/\\//gi;
#						push @{$formulas}, $for;
#						$evaluation = eval { $for };
#						if ($gb::measures->{$post_unit}->{'format'}) {
#							$format = $gb::measures->{$post_unit}->{'format'};
#						}
#						else {
#							$format = '0.000';
#						}
#						$uom = $post_unit;
#					}
#				}
			}
		}
	}
	else {
		$evaluation = eval $formula;
	}
	return ($formula,$evaluation,$uom,$format);
}

sub measure_unit_resolve($raw, $units) {
	return (undef, undef) unless defined $raw;
	$raw =~ s/^\s+|\s+$//g;
	return (undef, undef) unless length $raw;
	$raw = &subs::crypto_report_currency() if $raw eq '$';
	$units ||= &measures_all();
	foreach my $t ( $raw, uc $raw, lc $raw ) {
		return ($t, $units->{$t}) if ref $units->{$t} eq 'HASH';
	}
	my $low = lc $raw;
	foreach my $k ( keys %{$units} ) {
		my $def = $units->{$k};
		next unless ref $def eq 'HASH';
		foreach my $n ( $def->{'name'}, $def->{'plural'} ) {
			next unless defined $n && length $n;
			return ($k, $def) if lc($n) eq $low;
		}
	}
	return (undef, undef) unless length $low > 3 && $low =~ /s$/;
	return &measure_unit_resolve(substr($low, 0, -1), $units);
}

sub measure_conversion_edges($units) {
	my %edge;
	foreach my $from ( keys %{$units} ) {
		my $fs = $units->{$from}->{'formulas'};
		next unless ref $fs eq 'ARRAY';
		foreach my $f ( @{$fs} ) {
			next unless defined $f;
			next unless $f =~ /^\s*x\s*\*\s*([0-9]*\.?[0-9]+)\s*([A-Za-z\/]+)\s*$/i;
			my ($factor, $target) = ($1 + 0, $2);
			next unless $factor > 0;
			my ($to) = &measure_unit_resolve($target, $units);
			next unless defined $to && length $to;
			$edge{$from}->{$to} = $factor unless defined $edge{$from}->{$to};
		}
	}
	return \%edge;
}

sub measure_conversion_factor($edges, $from, $to) {
	return undef unless defined $from && defined $to;
	return 1 if $from eq $to;
	my %seen = ( $from => 1 );
	my @queue = ( [ $from, 1 ] );
	my $walked = 0;
	while ( scalar @queue && $walked++ < 400 ) {
		my ($u, $factor) = @{ shift @queue };
		my %next;
		foreach my $v ( keys %{ $edges->{$u} || {} } ) { $next{$v} = $edges->{$u}->{$v}; }
		foreach my $v ( keys %{$edges} ) {
			my $back = $edges->{$v}->{$u};
			next unless defined $back && $back > 0;
			$next{$v} = 1 / $back unless defined $next{$v};
		}
		foreach my $v ( keys %next ) {
			next if $seen{$v}++;
			my $f = $factor * $next{$v};
			return $f if $v eq $to;
			push @queue, [ $v, $f ];
		}
	}
	return undef;
}

sub measure_temperature_convert($from, $to, $value) {
	return $value if $from eq $to;
	return $value * 9 / 5 + 32 if $from eq 'C' && $to eq 'F';
	return ($value - 32) * 5 / 9 if $from eq 'F' && $to eq 'C';
	return undef;
}

sub measure_value_text($value, $unit, $currency) {
	my $abs = abs($value);
	my $dec = $abs >= 1 ? 2 : ($abs >= 0.01 ? 4 : 8);
	my $text = sprintf("%.${dec}f", $value);
	if ($currency) {
		if ($dec > 2) { $text =~ s/0+$//; $text =~ s/\.$//; }
	}
	else {
		$text =~ s/0+$// if $text =~ /\.\d/;
		$text =~ s/\.$//;
	}
	return $text . ' ' . $unit;
}

sub measure_unit_name($key, $def) {
	my $asset = &subs::crypto_asset($key);
	return $asset->{'name'} if $asset && $asset->{'name'};
	foreach my $f ( @{ &subs::crypto_fiat_table() } ) {
		return $f->{'name'} if $f->{'code'} eq uc $key;
	}
	my $name = ref $def eq 'HASH' ? ($def->{'name'} || '') : '';
	return length $name ? $name : $key;
}

1;
