package Manager;

# Manager helpers, part 30 of 37. Moved out of Manager.pl so a
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

sub agent_registry_adopt {
	my $rows = &agent_registry;
	my %known = map { ($_->{'kind'} || '') . "/" . ($_->{'name'} || '') => 1 } @{$rows};
	my $found = 0;
	my $existing = &subs::db_query("select setting from settings where app = '__president' and setting like 'coding_conversation%' and value is not null and value != '' and value != '[]'")->hashes;
	foreach my $s ( @{$existing} ) {
		my $name = $s->{'setting'};
		$name =~ s/^coding_conversation_//;
		next unless length $name;
		next if $known{'coding/' . $name};
		my $turns = &coding_conversation_load($name);
		next unless scalar @{$turns};
		&agent_registry_note('coding', $name, $turns);
		$found++;
	}
	return $found;
}

sub security_initializer($c) {
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $neighbour_link = &subs::db_select('neighbour_link')->hashes;
	my $devices = &subs::db_select('paired_devices', undef, {})->hashes || [];
	# Whether this phone already has a fingerprint: replacing it must pass the
	# enrolled one first (biometric_enroll enforces the same rule server-side).
	my $current_device_uuid = $c->session('device_uuid') || '';
	my $current_device = $current_device_uuid ? &subs::db_select('paired_devices', undef, { uuid => $current_device_uuid, status => 'active' })->hashes->[0] : undef;
	my $biometric_enrolled = ($current_device && $current_device->{'bio_pubkey'}) ? 1 : 0;
	my $recovery = &subs::db_query('select server_time from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'recovery')->hashes->[0];
	my $recovery_stale = &subs::db_query('select server_time from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'recovery_stale')->hashes->[0];
	# Shares held by devices: the newest set, the devices that can take one, and
	# the requests a recovering machine has left open.
	my $share_stale = &subs::db_query('select server_time from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'shamir_stale')->hashes->[0];
	my $share_set_id = &subs::house_key_share_set_current();
	my $share_set = length $share_set_id ? &subs::house_key_share_set_active($share_set_id) : [];
	my ($share_k, $share_n) = &subs::shamir_policy();
	my $share_devices = [ grep { ($_->{'share_pubkey'} || '') ne '' && ($_->{'status'} || '') eq 'active' } @{$devices} ];
	my $share_pending = &subs::house_key_share_requests_open();
	my $share_mine = $current_device_uuid ? &subs::house_key_share_for_device($current_device_uuid, $share_set_id) : [];
	# pending device approvals: old ones go, ones whose key is already on the
	# roster (approved on a peer) are settled, the rest wait with their code
	my $now = &subs::rightNow();
	&subs::db_query('delete from device_requests where status != ? and server_time < ?', 'pending', $now - 86400000);
	# A request is a person's to answer on another machine, and the mesh may only
	# carry it on the next pull. Ten minutes was shorter than the sync itself in
	# one case (the table's key request expired before the phone saw it), so the
	# approval window is an hour.
	&subs::db_query('delete from device_requests where status = ? and server_time < ?', 'pending', $now - 3600000);
	my $requests = &subs::db_select('device_requests', undef, { status => 'pending' })->hashes || [];
	foreach my $r ( @{$requests} ) {
		# An app request carries this device's *existing* pairing key in `pubkey`,
		# so the roster matches it by design. Settling it here would mark it
		# approved without ever attaching app_pubkey, and the row was filtered
		# out before the Approve button could render - the table's key request
		# could never be approved. Only the old pairing request is settled this
		# way; an app request always waits for a person.
		next if (($r->{'kind'} || '') eq 'app' || ($r->{'app_pubkey'} || '') ne '');
		my $paired = &subs::db_select('paired_devices', undef, { pubkey => $r->{'pubkey'}, status => 'active' })->hashes->[0];
		if ($paired) {
			&subs::db_update('device_requests', { status => 'approved', device_uuid => $paired->{'uuid'}, server_time => $now }, { uuid => $r->{'uuid'} });
			$r->{'status'} = 'approved';
		}
	}
	@{$requests} = grep { $_->{'status'} eq 'pending' } @{$requests};
	my $president = &subs::settings_grabber({ app => '__president' });
	if ($c->param('security_view')) {
		$president->{'security_view'} = $c->param('security_view');
	}
	# A lockdown opens on the one view that can end it.
	$president->{'security_view'} = 'padlock' if &subs::lockdown_active();
	$president->{'padlock_contexts'} = eval { return decode_json $president->{'padlock_contexts'} } || [];
	my $contents = $c->render_to_string(
		president => $president,
		template => 'security',
		window_maker => $c->param('window_maker'),
		neighbour_link => $neighbour_link,
		devices => $devices,
		people => &subs::people_list(),
		current_device_uuid => $current_device_uuid,
		biometric_enrolled => $biometric_enrolled,
		passkeys => &webauthn::credentials(),
		webauthn_rp => &webauthn::rp_id(),
		passkey_person => &webauthn_person($c),
		recovery => $recovery,
		recovery_stale => $recovery_stale,
		share_stale => $share_stale,
		share_set_id => $share_set_id,
		share_set => $share_set,
		share_devices => $share_devices,
		share_k => $share_k,
		share_n => $share_n,
		share_pending => $share_pending,
		share_mine => $share_mine,
		requests => $requests,
		config => $config,
		lockdown_active => &subs::lockdown_active(),
		lockdown_apps => [ sort keys %{ &subs::lockdown_enemy_apps() } ]
	);
	my $padlocker = &subs::db_select('security', undef, { level => 'padlock' })->hashes || [];
	if (scalar @{$padlocker} == 0) {
		&subs::db_delete('security', { level => 'padlock_device' });
		&subs::db_query('delete from settings where app = ? and setting = ?', '__president', 'padlock_device_time');
		&subs::db_delete('settings', { app => '__president', setting => 'pl_time' });
		&subs::db_delete('settings', { app => '__president', setting => 'padlock_pulls' });
	}

	return { html => $contents, signatorial => $config->{'signatorial'} };
}

sub device_pubkey_clean($armor) {
	return unless $armor;
	return $armor if $armor =~ /BEGIN PUBLIC KEY/;
	return "-----BEGIN PUBLIC KEY-----\n" . $armor . "\n-----END PUBLIC KEY-----\n" if $armor =~ /^[A-Za-z0-9+\/=\r\n]+$/;
	return;
}

sub device_store_pubkey($armor, $name, $agent, $person_uuid) {
	my $pem = &device_pubkey_clean($armor);
	return unless $pem;
	my $now = &subs::rightNow();
	my $uuid = &subs::random_string_creator(25);
	# The kind is a hint for the Security page: a phone, a browser, or the
	# desktop's WebKit windows. An app key or a biometric added later promotes
	# the row to app/phone.
	my $ua = $agent // '';
	my $kind = ($ua =~ /Android|iPhone|iPad|Mobile/i) ? 'phone'
		: ($ua =~ /AppleWebKit\/605/ && $ua =~ /Linux|X11/) ? 'webview'
		: 'browser';
	my $data = {
		uuid => $uuid,
		name => substr($name || 'Device', 0, 60),
		pubkey => $pem,
		privilege => 'citizen',
		status => 'active',
		timestamp => $now,
		server_time => $now,
		agent => substr($agent // '', 0, 400),
		kind => $kind
	};
	$data->{'person_uuid'} = $person_uuid if defined $person_uuid && length $person_uuid;
	&subs::db_insert('paired_devices', $data);
	return $uuid;
}

sub device_session_mint($c, $device_uuid) {
	my ($db,$database) = &subs::database_grabber();
	return unless $db;
	my $now = &subs::rightNow();
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'login_warranty' }) || '-3h', $now);
	my $person = &subs::person_for_device($device_uuid);
	# A device nobody has claimed is not a citizen: the person is the identity.
	# The owner backfill attaches the devices that predate this rule; a device
	# paired later waits, as guest, until a citizen assigns it.
	my $privilege = &subs::person_privilege($person);
	$c->session('authentication' => 'approved');
	$c->session('database' => $database);
	$c->session('suds_id' => &subs::suds_id(&subs::session_suds($c)));
	$c->session('warranty' => $warranty);
	$c->session('string' => &subs::random_string_creator());
	$c->session('name' => &subs::setting_grabber({ app => 'me', setting => 'name' }));
	$c->session('privilege' => $privilege);
	$c->session('person_uuid' => ($person ? $person->{'uuid'} : undef));
	$c->session('source' => 'device');
	$c->session('device_uuid' => $device_uuid);
	$c->session('server_time' => $now);
	&subs::db_update('paired_devices', { last_seen => $now }, { uuid => $device_uuid }) if $device_uuid;
	return 1;
}

sub app_nonce_take {
	my ($purpose, $device_uuid, $nonce, $ttl) = @_;
	$ttl ||= 120000;
	return 0 unless defined $nonce && $nonce =~ /^[A-Za-z0-9]{8,64}$/;
	my $stamp = $purpose . ':' . $device_uuid . ':' . $nonce;
	my $seen = &subs::db_query('select server_time from cache where context = ? and uuid = ? limit 1', 'app_nonce', $stamp)->hashes->[0];
	return 0 unless $seen && $seen->{'server_time'} && $seen->{'server_time'} > &subs::rightNow() - $ttl;
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'app_nonce', $stamp);
	return 1;
}

sub device_request_notify($c, $name, $code) {
	my $who = $name || 'A device';
	my (undef,$database) = &subs::database_grabber();
	&notification_sender({ app => 'security', role => 'citizen', title => 'Device Request', message => $who . ' asks to pair (code ' . $code . ')', image => $gb::known_appts->{'security'}->{'icon'} }, $database);
}

sub padlock_gate_mode {
	my $mode = &subs::setting_grabber({ app => '__president', setting => 'padlock_gate' });
	return (defined $mode && $mode eq 'shadow') ? 'shadow' : 'enforce';
}

sub app_access_mode {
	# A machine that cannot enroll an app key may opt itself out: a row named by
	# this machine's signatorial wins over the house-wide 'all' row, so one device
	# being unable to set up its unlock does not open (or close) the rest of the
	# house. Peers read their own signatorial, so this row never becomes their
	# answer.
	#
	# This is asked on every private request, so the two candidate rows are read
	# in one statement. Last row per device wins, exactly as the two
	# setting_grabber calls this replaces did (SQLite returns equal app+setting
	# keys in rowid order, so `order by rowid` is the same answer, made explicit).
	my $sig = &subs::signatorial_designer() || '';
	my $rows = eval {
		&subs::db_query('select device, value from settings where app = ? and setting = ? and device in (?, ?) order by rowid',
			'__president', 'app_access', $sig, 'all')->hashes
	} || [];
	my %mode;
	foreach my $row ( @{$rows} ) {
		next unless defined $row->{'device'};
		$mode{$row->{'device'}} = $row->{'value'};
	}
	if ($sig && defined $mode{$sig} && $mode{$sig} =~ /^(?:off|enforce|shadow)$/) {
		return $mode{$sig};
	}
	# The house-wide policy, shared as device 'all' so every machine and every
	# device class that has no row of its own reads one answer.
	my $house = $mode{'all'};
	return 'off' if defined $house && $house eq 'off';
	return (defined $house && $house eq 'enforce') ? 'enforce' : 'shadow';
}

sub app_public_path {
	my ($path) = @_;
	return 0 unless defined $path;
	return 1 if $path eq '/' || $path eq '/homepage' || $path eq '/index.html';
	return 1 if $path =~ m{^/store(?:/|$)};
	# The launcher's JawnOS row is drawn before any session exists, and it carries
	# only app names and built-in icons. /apps/icon redirects a person's own
	# main image to /file_open, whose own gate still applies.
	return 1 if $path eq '/apps/list';
	return 1 if $path eq '/apps/icon';
	return 1 if $path =~ m{^/(?:css|js|images|icons|sounds|fonts|public|i18n)/};
	return 1 if $path =~ m{^/(?:favicon\.ico|manifest\.json|service_worker\.js|robots\.txt|privacy|mugshot|payment|play|file_open|denial)$};
	# A batch of file_open pictures, authenticated by the route itself the same
	# way /file_open is. Without this the app gate would answer a phone's image
	# burst with the app-required page before any picture was read.
	return 1 if $path eq '/manager/thumbs';
	return 1 if $path =~ m{^/(?:manager/)?box_office(?:/|$)};
	return 1 if $path =~ m{^/public_view(?:/|$)};
	# the public invoice's pay buttons and a provider's webhook/return
	return 1 if $path =~ m{^/pay(?:/|$)};
	return 1 if $path eq '/sesh_check' || $path eq '/gate';
	return 1 if $path eq '/manager/health';
	# A peer pushes its own row here after a scheduled wake; health_allowed is
	# the gate (loopback, an approved session, or a signed peer).
	return 1 if $path eq '/manager/health_report';
	return 1 if $path eq '/manager/available';
	# The Clock's alarm rail: a peer pushes an edit and its confirmation here, and
	# a machine whose shared-alarm row has not caught up yet must still ring. The
	# route verifies the caller's session or its pinned signature itself (the
	# signed request carries the signatorial). This has to sit in the app gate too:
	# a peer answered with the app-required page never reaches that check.
	return 1 if $path eq '/manager/clock/alarm';
	# The address directory rides the same signed peer rail; each handler does its
	# own peer_verify (or accepts a loopback caller).
	return 1 if $path eq '/manager/address_report';
	return 1 if $path eq '/manager/address_directory';
	return 1 if $path eq '/manager/address_lookup';
	return 1 if $path =~ m{^/passkey(?:/|$)};
	return 1 if $path eq '/manager/ws' || $path eq '/manager/tunnel/ws';
	# The padlock is its own small protocol: a locked screen must still be able
	# to ask another device for a print even when its app window has lapsed, and
	# every one of these routes checks its own device key or pairing.
	return 1 if $path =~ m{^/manager/security/(?:padlock_|fingerprint_unlock|biometric_)};
	return 1 if $path =~ m{^/manager/device(?:/|$)};
	return 1 if $path =~ m{^/manager/app_release(?:/|$)};
	return 1 if $path =~ m{^/manager/app_download(?:/|$)};
	# A crest lookup is house to house: the caller presents its own crest and the
	# reply is signed by this house's key, so no session or app key is involved.
	return 1 if $path =~ m{^/crest(?:/|$)};
	# A member machine hands over its crest cosignature on the same peer rail:
	# the route requires and verifies the machine's signature itself.
	return 1 if $path eq '/manager/crest/cosign';
	# The embedded devices authenticate themselves with the rotated Now Me
	# pair; they are not browsers and must keep their rail.
	return 1 if $path =~ m{^/(?:watch|teletype|embedded)(?:/|$)};
	return 0;
}

sub app_session_ok {
	my ($c) = @_;
	# No loopback bypass here: a tunnel proxy can make a remote browser look
	# local. The recovery code or the app key is the way back in.
	if (($c->session('peer') || '') eq '1') {
		my $ssig = $c->session('peer_signatorial') || '';
		# A first-contact or pre-upgrade session carries no proved name; keep its
		# existing access until it logs in again.
		return 1 if $ssig eq '';
		my $rm = &subs::db_query('select * from remote_machines where signatorial = ?', $ssig)->hash;
		# the row is gone: the session is revoked with it
		return 0 unless $rm;
		my $key = $rm->{'uuid'} || $rm->{'signatorial'};
		$c->stash('peer_verified_key' => $key) if $key;
		return &subs::peer_allows($c, $rm, 'visitor') ? 1 : 0;
	}
	my $until = $c->session('app_until') || 0;
	return $until > &subs::rightNow() ? 1 : 0;
}

sub app_peer_ok {
	my ($c) = @_;
	my $sig = $c->req->headers->header('X-Peer-Signature');
	my $offered = $c->req->headers->header('X-Peer-Key');
	return 0 unless $sig && $offered;
	# The offered key names the caller; find the roster row that already pins it
	# and verify against that. Looking the row up by the key (not by a
	# signatorial the caller could quote) means a browser cannot borrow a
	# linked machine's name, and a route's own request need not carry a name.
	my $pub = eval { b64_decode($offered) } || '';
	return 0 unless $pub && index($pub, '-----BEGIN PUBLIC KEY-----') == 0;
	# A key file and a row copied by an older sync can wrap the same PEM
	# differently; compare the key material without whitespace, or a valid
	# peer looks unknown and every signed request is refused.
	my $want = $pub;
	$want =~ s/\s+//g;
	my $rows = eval { &subs::db_select('remote_machines')->hashes } || [];
	my $rm;
	foreach my $row ( @{$rows} ) {
		my $key = $row->{'pubkey'} // '';
		next unless length $key;
		$key =~ s/\s+//g;
		if ($key eq $want) { $rm = $row; last; }
	}
	return 0 unless $rm;
	return &subs::peer_verify($c, $rm) ? 1 : 0;
}

sub app_key_for {
	my ($device) = @_;
	return () unless $device;
	if ($device->{'app_pubkey'}) {
		my $kind = $device->{'app_kind'} || '';
		$kind = 'ec' if !$kind && $device->{'app_pubkey'} !~ /BEGIN PUBLIC KEY/;
		return ($device->{'app_pubkey'}, ($kind eq 'ec' ? 'ec' : 'ed25519'));
	}
	# A phone's already-enrolled Keystore fingerprint is its app key. The
	# private half cannot leave Android Keystore, so it is genuinely app-only.
	return ($device->{'bio_pubkey'}, 'ec') if $device->{'bio_pubkey'};
	return ();
}

sub app_signature_ok {
	my ($pubkey, $kind, $msg, $sig) = @_;
	return 0 unless $pubkey && defined $msg && $sig;
	return $kind eq 'ec'
		? &subs::ecdsa_verify($pubkey, $msg, $sig)
		: &subs::signature_verify($pubkey, $msg, $sig);
}

sub app_schema_ensure {
	return if $app_schema_done;
	$app_schema_done = 1;
	foreach my $spec (
		[ 'paired_devices', 'app_pubkey', 'LONGTEXT' ],
		[ 'paired_devices', 'app_kind', 'VARCHAR(16)' ],
		[ 'paired_devices', 'kind', 'VARCHAR(25)' ],
		[ 'device_requests', 'kind', 'VARCHAR(16)' ],
		[ 'device_requests', 'app_pubkey', 'LONGTEXT' ],
		[ 'device_requests', 'app_kind', 'VARCHAR(16)' ],
	) {
		my ($table, $column, $type) = @{$spec};
		# SQLite prints a "duplicate column name" warning straight to STDERR
		# for an ADD COLUMN that is already satisfied; it is not an exception,
		# so the eval below never saw it and every unlock filled the log. Skip
		# the statement when the column is already there.
		next if &subs::db_query('select 1 from pragma_table_info(?) where name=?', $table, $column)->hashes->[0];
		eval { &subs::db_query("ALTER TABLE $table ADD COLUMN $column $type") };
	}
	# Backfill the rows that predate the column. Idempotent: only blanks move.
	eval { &subs::db_query("update paired_devices set kind = case
		when bio_pubkey is not null and bio_pubkey != '' then 'phone'
		when app_pubkey is not null and app_pubkey != '' then 'app'
		when agent like '%AppleWebKit/605%' then 'webview'
		else 'browser' end
		where kind is null or kind = ''") };
	# Usage is per device: the phone's site-time, the laptop's window-time and a
	# server's headless work are different facts. The table is created here rather
	# than in schema.sql alone so an existing house gains it on the next start.
	eval { &subs::db_query('create table if not exists usage_sessions (
		uuid VARCHAR(255) unique,
		device VARCHAR(255),
		kind VARCHAR(16),
		key_name VARCHAR(500),
		started_at VARCHAR(25),
		ended_at VARCHAR(25),
		idle_ms VARCHAR(25),
		source VARCHAR(25),
		hostname VARCHAR(500),
		title VARCHAR(1000),
		url VARCHAR(2000),
		server_time VARCHAR(25),
		ost VARCHAR(25))') };
	eval { &subs::db_query('create index if not exists usage_sessions_started on usage_sessions(started_at)') };
	# The keyboard's vault. Created here so an existing house gains it on the next
	# start; `server_time` is what puts it on the ordinary sync rail.
	eval { &subs::db_query('create table if not exists credentials (
		uuid VARCHAR(255) unique,
		app VARCHAR(255),
		origin VARCHAR(500),
		kind VARCHAR(25),
		label VARCHAR(255),
		hints LONGTEXT,
		payload LONGTEXT,
		has_user VARCHAR(5),
		has_password VARCHAR(5),
		device VARCHAR(255),
		timestamp VARCHAR(25),
		server_time VARCHAR(25),
		ost VARCHAR(25))') };
	eval { &subs::db_query('create index if not exists idx1_credentials on credentials (app, origin)') };
}

sub padlock_key_show_relay {
	my ($c, $mode, $target, $show, $prompt, $request_id, $device_name, $source_device, $source_hostname) = @_;
	return unless $c;
	my $signatorial = &subs::signatorial_designer();
	my $relay_id = &subs::random_string_creator(30);
	&subs::relay_fresh($relay_id);
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&remote_relay_request($c, {
			override => 'manual',
			url => '/manager/security/padlock_key_show_peer',
			type => 'post',
			dissemination => 'yes',
			params => {
				signatorial => $signatorial,
				mode => $mode,
				target => $target,
				show => ($show ? 1 : 0),
				prompt => ($prompt ? 1 : 0),
				request_id => ($request_id || ''),
				device_name => ($device_name || ''),
				source_device => ($source_device || ''),
				source_hostname => ($source_hostname || ''),
				source => $signatorial,
				house => (($target || '') eq '' ? 1 : 0),
				dissemination => 'yes',
				source_signatorial => $signatorial,
				relay_from => $signatorial,
				relay_id => $relay_id,
			},
		});
	}, { name => 'padlock key show relay' });
}

sub padlock_request_store {
	my ($target, $mode, $source, $id, $device_name, $source_device, $source_hostname, $tab) = @_;
	my $now = &subs::rightNow();
	$id ||= &subs::random_string_creator(24);
	$tab = '' unless defined $tab && $tab =~ /^[A-Za-z0-9_-]{1,64}$/;
	my $data = encode_json({
		id => $id,
		target => $target || '',
		mode => $mode || 'locker',
		source => $source || '',
		device_name => $device_name || '',
		source_device => $source_device || '',
		source_hostname => $source_hostname || '',
		tab => $tab,
		house => (($target || '') eq '' ? 1 : 0),
		time => $now,
	});
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'padlock_request', $now - 600000);
	my $existing = &subs::db_select('cache', undef, { context => 'padlock_request', uuid => $id })->hashes->[0];
	if ($existing) {
		&subs::db_update('cache', { data => $data, server_time => $now, timestamp => $now }, { context => 'padlock_request', uuid => $id });
	}
	else {
		&subs::db_insert('cache', {
			uuid => $id,
			context => 'padlock_request',
			app => '__president',
			data => $data,
			timestamp => $now,
			server_time => $now,
		});
	}
	return $id;
}

sub padlock_request_for_target {
	my ($target) = @_;
	return {} unless defined $target && $target =~ /^[A-Za-z0-9]{8,64}$/;
	my $now = &subs::rightNow();
	my $rows = &subs::db_query('select uuid, data, server_time from cache where context = ? and server_time > ? order by server_time desc', 'padlock_request', $now - 300000)->hashes || [];
	foreach my $row ( @{$rows} ) {
		my $d = eval { decode_json $row->{'data'} } || {};
		next unless (($d->{'target'} || '') eq $target);
		$d->{'id'} ||= $row->{'uuid'};
		return $d;
	}
	return {};
}

sub padlock_request_get {
	my ($id) = @_;
	my $now = &subs::rightNow();
	my $row;
	if (defined $id && $id =~ /^[A-Za-z0-9]{8,64}$/) {
		$row = &subs::db_query('select uuid, data, server_time from cache where context = ? and uuid = ? and server_time > ? limit 1', 'padlock_request', $id, $now - 300000)->hashes->[0];
	}
	else {
		$row = &subs::db_query('select uuid, data, server_time from cache where context = ? and server_time > ? order by server_time desc limit 1', 'padlock_request', $now - 300000)->hashes->[0];
	}
	return {} unless $row;
	my $d = eval { decode_json $row->{'data'} } || {};
	$d->{'id'} ||= $row->{'uuid'};
	$d->{'time'} ||= $row->{'server_time'};
	return $d;
}

sub padlock_request_clear {
	my ($target) = @_;
	return unless defined $target;
	if ($target eq '') {
		my $all = &subs::db_query('select uuid from cache where context = ?', 'padlock_request')->hashes || [];
		&padlock_request_clear_id($_->{'uuid'}) for @{$all};
		return;
	}
	my $rows = &subs::db_query('select uuid, data from cache where context = ?', 'padlock_request')->hashes || [];
	foreach my $r ( @{$rows} ) {
		my $d = eval { decode_json $r->{'data'} } || {};
		&padlock_request_clear_id($r->{'uuid'}) if (($d->{'target'} || '') eq $target);
	}
}

sub padlock_request_clear_id {
	my ($id) = @_;
	return unless defined $id && $id =~ /^[A-Za-z0-9]{8,64}$/;
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'padlock_request', $id);
	&Websocket::send('server', { padlock_key_clear => 1, request_id => $id, timestamp => &subs::rightNow() });
}

sub go_approvers {
	my ($c, $source_device) = @_;
	my $local = (&fingerprint_available() && &padlock_request_is_local($c)) ? 1 : 0;
	my $self_bio = 0;
	if ($source_device) {
		my $d = &subs::db_select('paired_devices', undef, { uuid => $source_device, status => 'active' })->hashes->[0];
		$self_bio = ($d && ($d->{'bio_pubkey'} || '') ne '') ? 1 : 0;
	}
	my @devices = grep { ($_->{'bio_pubkey'} || '') ne '' && ($_->{'uuid'} || '') ne ($source_device || '') }
		@{ &subs::db_select('paired_devices', undef, { status => 'active' })->hashes || [] };
	return ($local, $self_bio, \@devices);
}

sub go_hostname {
	my $hostname = &subs::machine_name() || '';
	my $host = `hostname`;
	chomp $host;
	$hostname .= ' (' . $host . ')' if $host && $host ne $hostname;
	$hostname =~ s/[\r\n\t]//g;
	return substr($hostname, 0, 120);
}

sub go_request_create {
	my ($c, $rm, $source_device, $manager, $name) = @_;
	my $now = &subs::rightNow();
	my $id = &subs::random_string_creator(24);
	my $peer_name = $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'domain'} || $rm->{'ip'} || 'remote';
	my $data = encode_json({
		id => $id,
		peer_uuid => ($rm->{'uuid'} || ''),
		peer_name => $peer_name,
		source => &subs::signatorial_designer(),
		source_device => ($source_device || ''),
		source_hostname => &go_hostname(),
		time => $now,
	});
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'go_request', $now - 300000);
	my $old = $c->session('go_request') || '';
	if ($old =~ /^[A-Za-z0-9]{8,64}$/) {
		&subs::db_query('delete from cache where context = ? and uuid = ?', 'go_request', 'gor' . $old);
		&subs::db_query('delete from cache where context = ? and uuid = ?', 'go_approval', 'goa' . $old);
		&padlock_request_clear($old);
		&go_dismiss($old);
	}
	# cache.uuid is unique across contexts; the padlock prompt and the request
	# both carry the public id, so only the stored rows take a prefix.
	&subs::db_insert('cache', {
		uuid => ('gor' . $id), context => 'go_request', app => '__president',
		data => $data, timestamp => $now, server_time => $now,
	});
	$c->session('go_request' => $id);
	$c->session('go_peer_uuid' => ($rm->{'uuid'} || ''));
	$c->session('go_manager' => ($manager || ''));
	$c->session('go_name' => ($name || ''));
	return $id;
}

sub go_request_get {
	my ($id) = @_;
	return {} unless defined $id && $id =~ /^[A-Za-z0-9]{8,64}$/;
	my $row = &subs::db_query('select uuid, data, server_time from cache where context = ? and uuid = ? and server_time > ? limit 1', 'go_request', 'gor' . $id, &subs::rightNow() - 300000)->hashes->[0];
	return {} unless $row;
	my $d = eval { decode_json $row->{'data'} } || {};
	$d->{'id'} ||= $id;
	$d->{'time'} ||= $row->{'server_time'};
	return $d;
}

sub go_request_clear {
	my ($id) = @_;
	return unless defined $id && $id =~ /^[A-Za-z0-9]{8,64}$/;
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'go_request', 'gor' . $id);
}

sub go_approval_record {
	my ($id, $by, $device_uuid, $name) = @_;
	return unless defined $id && $id =~ /^[A-Za-z0-9]{8,64}$/;
	my $now = &subs::rightNow();
	my $row_uuid = 'goa' . $id;
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'go_approval', $now - 120000);
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'go_approval', $row_uuid);
	&subs::db_insert('cache', {
		uuid => $row_uuid, context => 'go_approval', app => '__president',
		data => encode_json({ approved => 1, by => ($by || ''), device => ($device_uuid || ''), name => ($name || ''), time => $now }),
		timestamp => $now, server_time => $now,
	});
}

1;
