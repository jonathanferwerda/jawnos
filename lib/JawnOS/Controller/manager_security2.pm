package Manager;

# manager_security2: route actions moved out of Manager.pl, one sub per route so a
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

# A local fingerprint is an alternative to the phone for the screen it is on.
# The request must come from this machine and the session must be approved;
# fprintd prompts the reader, and only the screen named (or the current one) is
# opened. `mode` is the padlock being opened - an app's own padlock names that
# mode so the print also mints that app's unlock token.
#
# fprintd-verify waits for a finger (up to 20 seconds), so it runs in a child
# process: a blocking system() in the request froze the whole manager worker,
# which is what made the UI go quiet while the reader waited.
# POST /manager/security/fingerprint_unlock
sub action_39714 {
	my $c = shift;
	my $ip = $c->tx->remote_address || '?';
	unless (&padlock_request_is_local($c)) {
		$log->info('padlock: local fingerprint refused from ' . $ip . ' (not a local address)');
		return $c->render(json => { ok => 0, error => 'local only' });
	}
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless $c->session('authentication') eq 'approved';
	return $c->render(json => { ok => 0, error => 'no fingerprint' }) unless &fingerprint_available();
	# A Go approval uses the same reader but mints no padlock: the session must
	# be the one that asked, and the print is the second factor for the ticket.
	my $purpose = ($c->param('purpose') || '') eq 'go' ? 'go' : '';
	my $go_request = '';
	my $mode;
	my $target;
	my $device = $c->session('device_uuid') || $c->session('app_device') || '';
	if ($purpose eq 'go') {
		$go_request = $c->param('request_id') || '';
		unless (($c->session('app_device') || '') ne ''
			&& $go_request =~ /^[A-Za-z0-9]{8,64}$/
			&& ($c->session('go_request') || '') eq $go_request
			&& (&go_request_get($go_request))->{'id'}) {
			return $c->render(json => { ok => 0, error => 'no request' });
		}
		$mode = 'go';
		$target = $go_request;
	}
	else {
		$mode = $c->param('mode') || 'locker';
		$mode = 'locker' unless $mode =~ /^(?:locker|gallery|music|folders|security|private)$/;
		$device = &media_unlock_device($c) unless length $device;
		# the reader opens the screen it is attached to: an app padlock names that
		# screen too, so the unlock never becomes a house-wide one
		$target = ($mode ne 'locker') ? $device : '';
		if ($mode ne 'locker' && !length $target) {
			return $c->render(json => { ok => 0, error => 'no device' });
		}
	}
	my $lockfile = '/tmp/jawnos_fingerprint.lock';
	# a worker that died mid-read left the latch behind; it is not a reader that
	# is still busy, and without this the button answered busy forever
	if (-e $lockfile && time - (stat($lockfile))[9] > 30) {
		unlink $lockfile;
		$log->info('padlock: removed a stale fingerprint lock');
	}
	my $fh;
	unless (sysopen($fh, $lockfile, O_CREAT|O_EXCL|O_WRONLY)) {
		$log->info('padlock: local fingerprint busy from ' . $ip);
		return $c->render(json => { ok => 0, error => 'busy' });
	}
	close $fh;
	my $user = $ENV{USER} || $ENV{USERNAME} || eval { getpwuid($<) } || 'jawn';
	$user =~ s/[^\w.-]//g;
	my $token = &subs::random_string_creator(24);
	my $now = &subs::rightNow();
	my %fingerprint = (pending => 1, device => $device, ip => $ip, mode => $mode, target => $target);
	my $source_tab = $c->param('browser_tab_id') || '';
	$source_tab = '' unless $source_tab =~ /^[A-Za-z0-9_-]{1,64}$/;
	$fingerprint{'tab'} = $source_tab;
	$fingerprint{'device_param'} = &media_unlock_device($c);
	$fingerprint{'purpose'} = 'go' if $purpose eq 'go';
	$fingerprint{'request_id'} = $go_request if $purpose eq 'go';
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'padlock_fingerprint', $now - 300000);
	&subs::db_insert('cache', {
		uuid => $token, context => 'padlock_fingerprint', app => '__president',
		data => encode_json(\%fingerprint),
		server_time => $now, timestamp => $now,
	});
	Mojo::IOLoop->subprocess(
		sub {
			my $rc = system('timeout', '20', 'fprintd-verify', $user);
			return (defined $rc ? $rc : -1);
		},
		sub {
			my ($loop, $err, $rc) = @_;
			unlink $lockfile;
			# The subprocess carries the child's $@ as $err. It is an EMPTY
			# string on a clean run, not undef; treating defined-but-empty as
			# a failure is what reported a matching print (rc=0) as refused.
			my $child_error = (defined $err && $err ne '') ? $err : '';
			my $ok = (!$child_error && defined $rc && $rc == 0) ? 1 : 0;
			my $error = $ok ? '' : ($child_error ? 'reader error' : ((defined $rc && $rc == 31744) ? 'timeout' : 'not accepted'));
			my %result = (pending => 0, ok => $ok, error => $error, device => $device, ip => $ip, mode => $mode, target => $target, tab => $source_tab, device_param => &media_unlock_device($c));
			$result{'purpose'} = 'go' if $purpose eq 'go';
			$result{'request_id'} = $go_request if $purpose eq 'go';
			&subs::db_query('update cache set data = ?, server_time = ? where context = ? and uuid = ?',
				encode_json(\%result),
				&subs::rightNow(), 'padlock_fingerprint', $token);
			eval { $log->info('padlock: local fingerprint ' . ($ok ? 'accepted' : 'refused') . ' from ' . $ip . ' rc=' . (defined $rc ? $rc : '?')) };
		}
	);
	$c->render(json => { ok => 0, pending => 1, token => $token });
}

# The reader is still waiting. The locked page polls this until the child above
# records a result; only an accepted print opens the session's own screen.
# GET /manager/security/fingerprint_unlock_status
sub action_39809 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless $c->session('authentication') eq 'approved';
	my $token = $c->param('token') || '';
	return $c->render(json => { ok => 0, error => 'no challenge' }) unless $token =~ /^[A-Za-z0-9]{8,64}$/;
	my $row = &subs::db_query('select data, server_time from cache where context = ? and uuid = ? limit 1', 'padlock_fingerprint', $token)->hashes->[0];
	unless ($row) { return $c->render(json => { ok => 0, error => 'no result' }); }
	my $d = eval { decode_json $row->{'data'} } || {};
	if ($d->{'pending'}) {
		if (($row->{'server_time'} || 0) < &subs::rightNow() - 30000) {
			&subs::db_query('delete from cache where context = ? and uuid = ?', 'padlock_fingerprint', $token);
			return $c->render(json => { ok => 0, error => 'timeout' });
		}
		return $c->render(json => { ok => 0, pending => 1 });
	}
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'padlock_fingerprint', $token);
	unless ($d->{'ok'}) { return $c->render(json => { ok => 0, error => ($d->{'error'} || 'not accepted') }); }
	# A Go approval confirms the ticket, not a screen: record it and leave the
	# mint to go_status, which is the session that asked.
	if (($d->{'purpose'} || '') eq 'go') {
		my $rid = $d->{'request_id'} || '';
		unless ($rid =~ /^[A-Za-z0-9]{8,64}$/ && ($c->session('go_request') || '') eq $rid) {
			return $c->render(json => { ok => 0, error => 'no request' });
		}
		&go_approval_record($rid, 'fingerprint', ($d->{'device'} || $c->session('device_uuid') || ''), 'this computer');
		&padlock_request_clear($rid);
		&go_dismiss($rid);
		$log->info('go: local fingerprint approved request=' . $rid);
		return $c->render(json => { ok => 1, approved => 1 });
	}
	# the print was accepted: open the screen and padlock it was asked for
	my $device = $c->session('device_uuid') || $d->{'device'} || '';
	my $mode = $d->{'mode'} || 'locker';
	$mode = 'locker' unless $mode =~ /^(?:locker|gallery|music|folders|security|private)$/;
	my $target = $d->{'target'} || $device;
	if ($mode ne 'locker' && !length $target) {
		return $c->render(json => { ok => 0, error => 'no device' });
	}
	# the token belongs to the window that pressed the button, not every tab
	my $tab = $c->param('browser_tab_id') || $d->{'tab'} || '';
	$tab = '' unless $tab =~ /^[A-Za-z0-9_-]{1,64}$/;
	my $opened = &padlock_mark_unlocked($c, $mode, $target, $tab);
	$log->info('padlock: local fingerprint opened ' . ($mode ne 'locker' ? "$mode padlock on " : '') . ($target || 'this screen'));
	my $unlock_token = ($mode ne 'locker' && $opened) ? &media_unlock_token($mode, $target) : '';
	$c->render(json => { ok => ($opened ? 1 : 0), unlocked => ($opened ? 1 : 0), unlock => $unlock_token });
}

# --- Go approvals ----------------------------------------------------------
# The installed app asks for a second factor before the peer ticket is minted.
# go_status polls for the approval and mints the ticket once; go_ask puts the
# request on the padlock prompt rail so a phone/tablet can answer it; go_approve
# verifies the device's signature and hands the approval to the machine that
# made the request (the phone often talks to a different jawn).
# GET /manager/security/go_status
sub action_39861 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless $c->session('authentication') eq 'approved';
	my $id = $c->param('request_id') || '';
	return $c->render(json => { ok => 0, error => 'no request' })
		unless $id =~ /^[A-Za-z0-9]{8,64}$/ && ($c->session('go_request') || '') eq $id;
	my $request = &go_request_get($id);
	unless ($request->{'id'}) { return $c->render(json => { ok => 0, error => 'expired' }); }
	my $approval = &go_approval_get($id);
	unless ($approval->{'approved'}) { return $c->render(json => { ok => 1, pending => 1 }); }
	my $rm = $request->{'peer_uuid'}
		? &subs::remote_machine_lister({ uuid => $request->{'peer_uuid'}, self => 'no', limit => 1 })
		: undef;
	unless (ref $rm eq 'HASH' && $rm->{'manager'}) { return $c->render(json => { ok => 0, error => 'no machine' }); }
	my $ticket = eval { &remote_manager_ticket($c, $rm) } || '';
	unless ($ticket) {
		$log->info('go: ticket mint failed for ' . ($request->{'peer_name'} || $request->{'peer_uuid'} || '?') . ' request=' . $id);
		return $c->render(json => { ok => 0, error => 'ticket' });
	}
	&go_approval_clear($id);
	&go_request_clear($id);
	&padlock_request_clear($id);
	my $manager = $c->session('go_manager') || '';
	$c->session('go_request' => undef);
	$c->session('go_peer_uuid' => undef);
	$c->session('go_manager' => undef);
	$c->session('go_name' => undef);
	# Every machine that relayed the request may still be showing the prompt.
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&remote_relay_request($c, {
			override => 'manual',
			url => '/manager/security/go_clear_peer',
			type => 'get',
			dissemination => 'yes',
			params => { signatorial => &subs::signatorial_designer(), request_id => $id },
		});
	}, { name => 'go approval clear relay' });
	$log->info('go: approved (' . ($approval->{'by'} || '?') . ') and ticket minted for ' . ($request->{'peer_name'} || '?') . ' request=' . $id);
	$c->render(json => {
		ok => 1, approved => 1, ticket_url => $ticket,
		manager => $manager, uuid => ($rm->{'uuid'} || ''), name => ($request->{'peer_name'} || ''),
		device_uuid => ($c->session('app_device') || ''),
	});
}

# POST /manager/security/go_ask
sub action_39906 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless ($c->session('app_device') || '') ne '';
	my $id = $c->param('request_id') || '';
	return $c->render(json => { ok => 0, error => 'no request' })
		unless $id =~ /^[A-Za-z0-9]{8,64}$/ && ($c->session('go_request') || '') eq $id;
	my $request = &go_request_get($id);
	unless ($request->{'id'}) { return $c->render(json => { ok => 0, error => 'expired' }); }
	my $mode = 'go';
	my $device_name = $request->{'peer_name'} || '';
	my $source_device = $request->{'source_device'} || '';
	my $source = $request->{'source'} || &subs::signatorial_designer();
	my $source_hostname = $request->{'source_hostname'} || '';
	&padlock_request_store($id, $mode, $source, $id, $device_name, $source_device, $source_hostname);
	&Websocket::send('server', {
		padlock_key_show => 1, prompt => 1, request_id => $id,
		device_name => $device_name, source_device => $source_device, source => $source,
		source_hostname => $source_hostname, house => 0, mode => $mode, target => $id, show => 0,
		timestamp => &subs::rightNow(),
	});
	&padlock_key_show_relay($c, $mode, $id, 0, 1, $id, $device_name, $source_device, $source_hostname);
	$log->info('go: asked the house to approve ' . ($device_name || '?') . ' request=' . $id);
	$c->render(json => { ok => 1, request_id => $id });
}

# POST /manager/security/go_approve
sub action_39930 {
	my $c = shift;
	my $device_uuid = $c->param('device_uuid') || '';
	my $request_id = $c->param('request_id') || '';
	my $nonce = $c->param('nonce') || '';
	my $signature = $c->param('signature') || '';
	my $kind = ($c->param('kind') || 'pair') eq 'bio' ? 'bio' : 'pair';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	return $c->render(json => { ok => 0, error => 'not paired' }) unless $device;
	return $c->render(json => { ok => 0, error => 'no request' })
		unless $request_id =~ /^[A-Za-z0-9]{8,64}$/ && $nonce =~ /^[A-Za-z0-9]{8,64}$/;
	my $request = &padlock_request_get($request_id);
	unless (($request->{'id'} || '') eq $request_id && ($request->{'mode'} || '') eq 'go') {
		# A phone approving its own Go (or this machine's live page) has no
		# padlock prompt to read: the request it answers is go_request here.
		my $own = &go_request_get($request_id);
		$request = ($own->{'id'} && (($own->{'source'} || '') eq &subs::signatorial_designer())) ? $own : {};
	}
	unless ($request->{'id'}) {
		return $c->render(json => { ok => 0, error => 'no request' });
	}
	my $msg = join("\n", 'go-approve', $device_uuid, $request_id, $nonce);
	my $ok = 0;
	if ($kind eq 'bio') {
		$ok = (&biometric_nonce_take('go', $device_uuid, $nonce)
			&& ($device->{'bio_pubkey'} || '') ne ''
			&& &subs::ecdsa_verify($device->{'bio_pubkey'}, $msg, $signature)) ? 1 : 0;
	}
	else {
		my $seen = &subs::db_query('select server_time from cache where context = ? and uuid = ? limit 1', 'padlock_nonce', $device_uuid . ':' . $nonce)->hashes->[0];
		$ok = (($device->{'pubkey'} || '') ne ''
			&& $seen && $seen->{'server_time'} && $seen->{'server_time'} > &subs::rightNow() - 60000
			&& &subs::signature_verify($device->{'pubkey'}, $msg, $signature)) ? 1 : 0;
		&subs::db_query('delete from cache where context = ? and uuid = ?', 'padlock_nonce', $device_uuid . ':' . $nonce) if $ok;
	}
	unless ($ok) {
		$log->info('go: approval refused for ' . ($device->{'name'} || $device_uuid) . ' request=' . $request_id);
		return $c->render(json => { ok => 0, error => 'not accepted' });
	}
	my $source = $request->{'source'} || '';
	my $self = &subs::signatorial_designer();
	my $name = $device->{'name'} || '';
	if ($source eq $self) {
		&go_approval_record($request_id, $kind, $device_uuid, $name);
	}
	else {
		my $rm = $source ? &subs::db_select('remote_machines', undef, { signatorial => $source })->hashes->[0] : undef;
		unless ($rm && $rm->{'uuid'}) { return $c->render(json => { ok => 0, error => 'source' }); }
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			&remote_relay_request($c, {
				override => 'manual',
				remote_uuid => $rm->{'uuid'},
				url => '/manager/security/go_open_peer',
				type => 'get',
				params => {
					signatorial => &subs::signatorial_designer(),
					request_id => $request_id,
					device_uuid => $device_uuid,
					device_name => $name,
					kind => $kind,
				},
			});
		}, { name => 'go approval relay' });
	}
	&padlock_request_clear($request_id);
	&go_dismiss($request_id);
	$log->info('go: approved by ' . ($name || $device_uuid) . ' request=' . $request_id . ' kind=' . $kind);
	$c->render(json => { ok => 1, approved => 1 });
}

# GET /manager/security/go_open_peer
sub action_40000 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) {
		$log->info('go: peer approval refused from ' . ($signatorial || '?') . ' at ' . ($c->tx->remote_address || '?'));
		return $c->rendered(403);
	}
	my $request_id = $c->param('request_id') || '';
	return $c->rendered(400) unless $request_id =~ /^[A-Za-z0-9]{8,64}$/;
	my $device_uuid = $c->param('device_uuid') || '';
	$device_uuid = '' unless $device_uuid =~ /^[A-Za-z0-9]{8,64}$/;
	my $device_name = $c->param('device_name') || '';
	$device_name =~ s/[\r\n\t]//g;
	$device_name = substr($device_name, 0, 120);
	my $kind = ($c->param('kind') || 'pair') eq 'bio' ? 'bio' : 'pair';
	&go_approval_record($request_id, $kind, $device_uuid, $device_name);
	&padlock_request_clear($request_id);
	&go_dismiss($request_id);
	$log->info('go: approval relayed from ' . ($rm->{'hostname'} || $signatorial) . ' request=' . $request_id . ' by ' . ($device_name || $device_uuid || '?'));
	$c->render(json => { ok => 1 });
}

# The ticket is minted on the machine that pressed Go; every machine that
# relayed the prompt drops it here, so the other devices stop asking.
# GET /manager/security/go_clear_peer
sub action_40024 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) {
		return $c->rendered(403);
	}
	my $request_id = $c->param('request_id') || '';
	return $c->rendered(400) unless $request_id =~ /^[A-Za-z0-9]{8,64}$/;
	&padlock_request_clear($request_id);
	&go_dismiss($request_id);
	$c->render(json => { ok => 1 });
}

# POST /manager/security/biometric_challenge
sub action_40080 {
	my $c = shift;
	my $purpose = $c->param('purpose') || 'unlock';
	$purpose = 'unlock' unless $purpose =~ /^(?:enroll|unlock|verify|go|pay)$/;
	my $device_uuid = $c->param('device_uuid') || $c->session('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	unless ($device) { return $c->render(json => { ok => 0, error => 'not paired' }); }
	my $ip = $c->tx->remote_address || '?';
	my $now = &subs::rightNow();
	my $fails = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'padlock_bio_fail', $ip . ':%', $now - 300000)->hash->{'n'} || 0;
	if ($fails >= 5) { return $c->render(json => { ok => 0, error => 'too many' }); }
	my $recent = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'padlock_bio_challenge', $ip . ':%', $now - 60000)->hash->{'n'} || 0;
	if ($recent >= 20) { return $c->render(json => { ok => 0, error => 'too many' }); }
	&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'padlock_bio_challenge', app => '__president', server_time => $now, timestamp => $now });
	my $nonce = &subs::random_string_creator(40);
	&subs::db_query('delete from cache where context = ? and server_time < ? and uuid not like ?', 'padlock_bio_nonce', $now - 120000, 'verify:%');
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'padlock_bio_nonce', $now - 900000);
	&subs::db_insert('cache', { uuid => $purpose . ':' . $device_uuid . ':' . $nonce, context => 'padlock_bio_nonce', app => '__president', server_time => $now, timestamp => $now });
	$c->render(json => { ok => 1, nonce => $nonce, seconds => 60 });
}

# Enrollment is bound to the device's existing Ed25519 key: the page signs the
# new public key with the key it was paired with. The EC key itself is made by
# the Android app only after its own biometric prompt.
# POST /manager/security/biometric_enroll
sub action_40103 {
	my $c = shift;
	return $c->render(json => { ok => 0, error => 'locked' }) if &padlock_locked_now($c);
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless $c->session('authentication') eq 'approved';
	my $device_uuid = $c->param('device_uuid') || $c->session('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	return $c->render(json => { ok => 0, error => 'not paired' }) unless $device;
	my $nonce = $c->param('nonce') || '';
	my $device_sig = $c->param('device_signature') || '';
	my $pubkey = $c->param('pubkey') || '';
	return $c->render(json => { ok => 0, error => 'bad key' }) unless &subs::ecdsa_public_key_ok($pubkey);
	my $ip = $c->tx->remote_address || '?';
	my $now = &subs::rightNow();
	# An enrolled fingerprint is a second factor, so replacing it must present
	# that factor: the old EC key signs a fresh verify challenge. Without this,
	# the device's pairing key alone could swap the fingerprint behind the
	# person's back.
	if ($device->{'bio_pubkey'}) {
		my $bio_nonce = $c->param('bio_nonce') || '';
		my $bio_signature = $c->param('bio_signature') || '';
		my $confirmed = &biometric_nonce_take('verify', $device_uuid, $bio_nonce, 600000)
			&& &subs::ecdsa_verify($device->{'bio_pubkey'}, join("\n", 'padlock-bio-verify', $device_uuid, $bio_nonce), $bio_signature);
		unless ($confirmed) {
			&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'padlock_bio_fail', app => '__president', server_time => $now, timestamp => $now });
			$log->info('padlock: biometric replacement refused for ' . ($device->{'name'} || $device_uuid) . ' from ' . $ip);
			return $c->render(json => { ok => 0, error => 'confirm fingerprint' });
		}
	}
	my $fresh = &biometric_nonce_take('enroll', $device_uuid, $nonce);
	unless ($fresh) { return $c->render(json => { ok => 0, error => 'no challenge' }); }
	require Digest::SHA;
	my $msg = join("\n", 'padlock-bio-enroll', $device_uuid, $nonce, Digest::SHA::sha256_hex($pubkey));
	unless (&subs::signature_verify($device->{'pubkey'}, $msg, $device_sig)) {
		&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'padlock_bio_fail', app => '__president', server_time => $now, timestamp => $now });
		$log->info('padlock: biometric enrollment refused for ' . ($device->{'name'} || $device_uuid) . ' from ' . $ip);
		return $c->render(json => { ok => 0, error => 'not accepted' });
	}
	&subs::db_update('paired_devices', { bio_pubkey => $pubkey, kind => 'phone' }, { uuid => $device_uuid });
	&subs::db_query('delete from cache where context = ? and uuid like ?', 'padlock_bio_fail', $ip . ':%');
	$log->info('padlock: biometric key enrolled for ' . ($device->{'name'} || $device_uuid) . ' from ' . $ip);
	$c->render(json => { ok => 1, device_uuid => $device_uuid });
}

# POST /manager/security/biometric_unlock
sub action_40145 {
	my $c = shift;
	my $device_uuid = $c->param('device_uuid') || $c->session('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	return $c->render(json => { ok => 0, error => 'not paired' }) unless $device;
	return $c->render(json => { ok => 0, error => 'no biometric key' }) unless $device->{'bio_pubkey'};
	my $nonce = $c->param('nonce') || '';
	my $signature = $c->param('signature') || '';
	my $mode = $c->param('mode') || 'locker';
	$mode = 'locker' unless $mode =~ /^(?:locker|gallery|music|folders|security|private)$/;
	# The phone may confirm an unlock for ANOTHER screen (the person presses
	# Unlock on the laptop, then touches the phone). The target is bound into the
	# signed message, so a signature made for one screen cannot be replayed for
	# another. An empty target is the phone's own screen.
	my $target = $c->param('target') || '';
	$target = '' unless $target =~ /^[A-Za-z0-9]{8,64}$/;
	# An empty target is the house-wide lock (the locked screen had no device
	# identity), not this phone's own screen. `house` binds that meaning into
	# the signature and keeps the open from being applied to the phone instead.
	my $house = $c->param('house') ? 1 : 0;
	if ($target && !&subs::db_select('paired_devices', undef, { uuid => $target, status => 'active' })->hashes->[0]) {
		return $c->render(json => { ok => 0, error => 'not paired' });
	}
	my $ip = $c->tx->remote_address || '?';
	my $now = &subs::rightNow();
	my $fresh = &biometric_nonce_take('unlock', $device_uuid, $nonce);
	unless ($fresh) { return $c->render(json => { ok => 0, error => 'no challenge' }); }
	my $signed_target = $house ? 'house' : $target;
	my $msg = $signed_target
		? join("\n", 'padlock-bio-unlock', $device_uuid, $signed_target, $nonce)
		: join("\n", 'padlock-bio-unlock', $device_uuid, $nonce);
	unless (&subs::ecdsa_verify($device->{'bio_pubkey'}, $msg, $signature)) {
		&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'padlock_bio_fail', app => '__president', server_time => $now, timestamp => $now });
		$log->info('padlock: biometric signature refused for ' . ($device->{'name'} || $device_uuid) . ' from ' . $ip);
		return $c->render(json => { ok => 0, error => 'not accepted' });
	}
	&subs::db_query('delete from cache where context = ? and uuid like ?', 'padlock_bio_fail', $ip . ':%');
	my $open_target = $house ? '' : ($target || $device_uuid);
	# A whole-house lock keeps the other screens locked on the house-wide stamp.
	my $opened = &padlock_mark_unlocked($c, $mode, $open_target);
	&padlock_request_clear($open_target);
	# the authoritative lock may live on another peer: hand the open over the
	# signed rail, the same way a phone-as-key unlock does
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&remote_relay_request($c, {
			override => 'manual',
			url => '/manager/security/padlock_open_peer',
			type => 'get',
			dissemination => 'yes',
			params => {
				signatorial => &subs::signatorial_designer(),
				target => $open_target,
				mode => $mode,
				house => ($house ? 1 : 0),
			},
		});
	}, { name => 'padlock biometric relay' });
	$log->info('padlock: biometric open by ' . ($device->{'name'} || $device_uuid) . ' from ' . $ip . ' target=' . ($target || 'self'));
	my $unlock_token = ($mode ne 'locker' && $opened) ? &media_unlock_token($mode, $open_target) : '';
	$c->render(json => { ok => ($opened ? 1 : 0), unlocked => ($opened ? 1 : 0), name => $device->{'name'}, target => $open_target, unlock => $unlock_token });
}

# --- opening the lock with a paired device's signature ---------------------
# The phone/tablet asks for a short-lived nonce, signs
# "padlock-unlock\n<uuid>\n<nonce>" with the key it was paired with, and the
# house verifies it. The nonce is single-use; a request from this machine
# itself is refused, so the locked screen cannot open its own door.
# POST /manager/security/padlock_challenge
sub action_40212 {
	my $c = shift;
	my $device_uuid = $c->param('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	unless ($device) { return $c->render(json => { ok => 0 }); }
	my $ip = $c->tx->remote_address || '?';
	my $now = &subs::rightNow();
	my $fails = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'padlock_fail', $ip . ':%', $now - 300000)->hash->{'n'} || 0;
	if ($fails >= 5) { return $c->render(json => { ok => 0, error => 'too many' }); }
	# A challenge from someone else must not knock the phone's nonce out of the
	# cache, so expired ones are pruned instead of every nonce for the device;
	# the per-address count keeps the cache from being filled.
	my $recent = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'padlock_challenge', $ip . ':%', $now - 60000)->hash->{'n'} || 0;
	if ($recent >= 20) { return $c->render(json => { ok => 0, error => 'too many' }); }
	&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'padlock_challenge', app => '__president', server_time => $now, timestamp => $now });
	my $nonce = &subs::random_string_creator(40);
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'padlock_nonce', $now - 120000);
	&subs::db_insert('cache', { uuid => $device_uuid . ':' . $nonce, context => 'padlock_nonce', app => '__president', server_time => $now, timestamp => $now });
	$c->render(json => { ok => 1, nonce => $nonce, seconds => 60 });
}

# POST /manager/security/padlock_unlock
sub action_40232 {
	my $c = shift;
	my $device_uuid = $c->param('device_uuid') || '';
	my $nonce = $c->param('nonce') || '';
	my $signature = $c->param('signature') || '';
	my $mode = $c->param('mode') || 'locker';
	$mode = 'locker' unless $mode =~ /^(?:locker|gallery|music|folders|private)$/;
	my $target = $c->param('target') || '';
	$target = '' unless $target =~ /^[A-Za-z0-9]{8,64}$/;
	my $house = $c->param('house') ? 1 : 0;
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	unless ($device && $nonce =~ /^[A-Za-z0-9]{8,64}$/) { return $c->render(json => { ok => 0 }); }
	my $ip = $c->tx->remote_address || '?';
	my $now = &subs::rightNow();
	my $stamp = $device_uuid . ':' . $nonce;
	my $seen = &subs::db_query('select server_time from cache where context = ? and uuid = ? limit 1', 'padlock_nonce', $stamp)->hashes->[0];
	unless ($seen && $seen->{'server_time'} && $seen->{'server_time'} > $now - 60000) {
		&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'padlock_fail', app => '__president', server_time => $now, timestamp => $now });
		return $c->render(json => { ok => 0 });
	}
	my $signed_target = $house ? 'house' : $target;
	my $msg = $signed_target
		? join("\n", ('padlock-unlock', $device_uuid, $signed_target, $nonce))
		: join("\n", ('padlock-unlock', $device_uuid, $nonce));
	unless (&subs::signature_verify($device->{'pubkey'}, $msg, $signature)) {
		&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'padlock_fail', app => '__president', server_time => $now, timestamp => $now });
		$log->info('padlock: signature refused for ' . ($device->{'name'} || $device_uuid) . ' from ' . $ip);
		return $c->render(json => { ok => 0 });
	}
	# the phone, not the locked screen: a local signature would let a desktop
	# open its own door. A *handheld* is the exception - its own screen is the
	# one being opened, and the key is the paired device key in its own browser
	# (the desktop cannot reach it). Without this the phone's own "Open the
	# unlock page on this phone" answered error=local while the person was
	# holding the phone, which read as "open it on your phone" from the phone.
	# A local screen may still sign for ANOTHER screen (the unlock page is sent
	# to any device in the house); only its own screen and the whole-house lock
	# are refused.
	if (&padlock_request_is_local($c) && &subs::device_setter() ne 'mobile') {
		my $for_other = ($target && $target ne $device_uuid
			&& &subs::db_select('paired_devices', undef, { uuid => $target, status => 'active' })->hashes->[0]) ? 1 : 0;
		unless ($for_other) {
			$log->info('padlock: local signature refused from ' . $ip);
			return $c->render(json => { ok => 0, error => 'local' });
		}
	}
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'padlock_nonce', $stamp);
	&subs::db_query('delete from cache where context = ? and uuid like ?', 'padlock_fail', $ip . ':%');
	my $open_target = $house ? '' : $target;
	my $locked = $open_target ? &padlock_target_locked($open_target, $c)
		: (&padlock_locked_now($c) || &padlock_global_locked($c));
	# A phone often talks to its own jawn, while the lock is authoritative on the
	# machine that made it. Clearing it here alone leaves that screen locked (the
	# device row never syncs as a deletion). The signature is verified above, so
	# hand the open to the peers over the signed rail; the machine that holds the
	# lock is the one that clears it.
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&remote_relay_request($c, {
			override => 'manual',
			url => '/manager/security/padlock_open_peer',
			type => 'get',
			dissemination => 'yes',
			params => { signatorial => &subs::signatorial_designer(), target => $open_target, mode => $mode, house => ($house ? 1 : 0) },
		});
	}, { name => 'padlock unlock relay' });
	# A media padlock is not the screen timer: the app opens locked while the
	# screen itself is open, so its grant must be minted even then. Clearing the
	# request first would also lose the tab the token belongs to.
	if (!$locked && $mode eq 'locker') {
		&padlock_request_clear($open_target);
		return $c->render(json => { ok => 1, unlocked => 1, already => 1, relayed => ($open_target ? 1 : 0), name => $device->{'name'} });
	}
	my $opened = &padlock_mark_unlocked($c, $mode, $open_target);
	&padlock_request_clear($open_target);
	$log->info('padlock: opened by ' . ($device->{'name'} || $device_uuid) . ' from ' . $ip . ' mode=' . $mode . ($open_target ? ' target=' . $open_target : ' house'));
	$c->render(json => { ok => ($opened ? 1 : 0), unlocked => ($opened ? 1 : 0), name => $device->{'name'}, target => $open_target });
}

# The peer half of an unlock. A phone signs the challenge on whichever jawn it
# is talking to; that machine verifies the paired key and relays the open here,
# so the machine that actually holds the lock clears it. The relay is a signed
# peer request (peer_verify), so the target cannot be altered on the way.
# GET /manager/security/padlock_open_peer
sub action_40314 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) {
		$log->info('padlock: peer unlock refused from ' . ($signatorial || '?') . ' at ' . ($c->tx->remote_address || '?'));
		return $c->rendered(403);
	}
	my $target = $c->param('target') || '';
	$target = '' unless $target =~ /^[A-Za-z0-9]{8,64}$/;
	my $mode = $c->param('mode') || 'locker';
	$mode = 'locker' unless $mode =~ /^(?:locker|gallery|music|folders|security|private)$/;
	my $opened = &padlock_mark_unlocked($c, $mode, $target);
	&padlock_request_clear($target);
	$log->info('padlock: peer unlock from ' . ($rm->{'hostname'} || $signatorial) . ' mode=' . $mode . ($target ? ' target=' . $target : ' house'));
	# A phone may reach the peer that holds the lock only through a machine in
	# between (a phone's roster is small). Carry the open on once, so the
	# machine that actually holds the lock hears it; relay_id stops a loop and
	# the source is not handed its own open back.
	my $relay_id = $c->param('relay_id') || '';
	if ($relay_id) {
		my $self = &subs::signatorial_designer();
		my $origin = $c->param('source_signatorial') || $signatorial;
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			&remote_relay_request($c, {
				override => 'manual',
				url => '/manager/security/padlock_open_peer',
				type => 'get',
				dissemination => 'yes',
				params => {
					signatorial => $self,
					target => $target,
					mode => $mode,
					house => ($target ? 0 : 1),
					dissemination => 'yes',
					source_signatorial => $origin,
					relay_from => $self,
					relay_id => $relay_id,
				},
			});
		}, { name => 'padlock open relay' });
	}
	$c->render(json => { ok => ($opened ? 1 : 0), target => $target });
}

1;
