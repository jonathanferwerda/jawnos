package Manager;

# manager_device: route actions moved out of Manager.pl, one sub per route so a
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

# --- paired devices -----------------------------------------------------------
# A citizen session pairs the browser it runs in: the ticket scan (or the
# password login) is the pairing grant, one public key is stored, and after
# that the device logs itself in with a signed challenge - no ticket to lose,
# no password, any network. The private key never leaves the device.
# POST /manager/device/pair
sub action_37919 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0, error => 'citizen session required' });
		return;
	}
	# A locked screen must not mint a fresh identity: padlock_device_until is
	# keyed by device uuid, so pairing again would hand the page a uuid with no
	# lock row and let it walk straight past a single-screen lock (the exact
	# "I locked it and still have full access" escape). The recovery route is
	# the door for a screen with no usable key.
	if (&padlock_locked_now($c)) {
		$c->render(json => { ok => 0, error => 'locked' });
		return;
	}
	my $name = substr($c->param('name') || 'Device', 0, 60);
	my $person_uuid = $c->session('person_uuid') || &subs::people_owner_ensure();
	my $uuid = &device_store_pubkey($c->param('pubkey'), $name, $c->req->headers->user_agent, $person_uuid);
	unless ($uuid) { $c->render(json => { ok => 0, error => 'no key' }); return; }
	$c->session('device_uuid' => $uuid);
	$c->render(json => { ok => 1, device_uuid => $uuid, name => $name });
}

# POST /manager/device/challenge
sub action_37941 {
	my $c = shift;
	my $device_uuid = $c->param('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	unless ($device) { $c->render(json => { ok => 0 }); return; }
	my $nonce = &subs::random_string_creator(40);
	my $now = &subs::rightNow();
	&subs::db_query('delete from cache where context = ? and uuid like ?', 'device_nonce', $device_uuid . ':%');
	&subs::db_query('insert into cache (uuid, context, app, server_time, timestamp) values (?,?,?,?,?)', $device_uuid . ':' . $nonce, 'device_nonce', '__president', $now, $now);
	$c->render(json => { ok => 1, nonce => $nonce });
}

# POST /manager/device/login
sub action_37952 {
	my $c = shift;
	# A locked screen does not renew itself by logging in a device: that path
	# would switch the session to any paired uuid (including a fresh one) and
	# leave the lock behind. Unlocking is padlock_unlock / biometric_unlock.
	if (&padlock_locked_now($c)) {
		$c->render(json => { ok => 0, error => 'locked' });
		return;
	}
	my $device_uuid = $c->param('device_uuid') || '';
	my $nonce = $c->param('nonce') || '';
	my $signature = $c->param('signature') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	unless ($device && $nonce =~ /^[A-Za-z0-9]{8,64}$/) { $c->render(json => { ok => 0 }); return; }
	my ($db,$database) = &subs::database_grabber();
	unless ($db) { $c->render(json => { ok => 0 }); return; }
	my $stamp = $device_uuid . ':' . $nonce;
	my $now = &subs::rightNow();
	my $seen = &subs::db_query('select server_time from cache where context = ? and uuid = ? limit 1', 'device_nonce', $stamp)->hashes->[0];
	unless ($seen && $seen->{'server_time'} && $seen->{'server_time'} > $now - 120000) { $c->render(json => { ok => 0 }); return; }
	my $msg = join "\n", ('device-login', $device_uuid, $nonce);
	unless (&subs::signature_verify($device->{'pubkey'}, $msg, $signature)) { $c->render(json => { ok => 0 }); return; }
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'device_nonce', $stamp);
	&device_session_mint($c, $device_uuid);
	$c->render(json => { ok => 1, name => $device->{'name'} });
}

# --- app keys ----------------------------------------------------------------
# The private manager is reachable only when the session carries a native app
# key proof. A phone's key is its Android Keystore biometric key; a desktop's is
# a key the desktop app holds and signs with. A browser has neither, so it can
# pair and log in but never become an app session.
# POST /manager/device/app_challenge
sub action_37983 {
	my $c = shift;
	&app_schema_ensure();
	my $device_uuid = $c->param('device_uuid') || $c->session('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	unless ($device) { return $c->render(json => { ok => 0, error => 'not paired' }); }
	my $purpose = ($c->param('purpose') || '') eq 'enroll' ? 'enroll' : 'login';
	my $ip = $c->tx->remote_address || '?';
	my $now = &subs::rightNow();
	my $recent = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'app_challenge', $ip . ':%', $now - 60000)->hash->{'n'} || 0;
	if ($recent >= 30) { return $c->render(json => { ok => 0, error => 'too many' }); }
	&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'app_challenge', app => '__president', server_time => $now, timestamp => $now });
	my $nonce = &subs::random_string_creator(40);
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'app_nonce', $now - 180000);
	&subs::db_insert('cache', { uuid => $purpose . ':' . $device_uuid . ':' . $nonce, context => 'app_nonce', app => '__president', server_time => $now, timestamp => $now });
	$c->render(json => { ok => 1, nonce => $nonce, seconds => 120 });
}

# POST /manager/device/app_login
sub action_38011 {
	my $c = shift;
	&app_schema_ensure();
	my $device_uuid = $c->param('device_uuid') || $c->session('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	unless ($device) { return $c->render(json => { ok => 0, error => 'not paired' }); }
	my ($pubkey, $kind) = &app_key_for($device);
	return $c->render(json => { ok => 0, error => 'no app key' }) unless $pubkey;
	my $nonce = $c->param('nonce') || '';
	return $c->render(json => { ok => 0, error => 'no challenge' }) unless &app_nonce_take('login', $device_uuid, $nonce);
	my $msg = join("\n", 'app-login', $device_uuid, $nonce);
	unless (&app_signature_ok($pubkey, $kind, $msg, $c->param('signature') || '')) {
		$log->info('app gate: app login refused for ' . ($device->{'name'} || $device_uuid) . ' from ' . ($c->tx->remote_address || '?'));
		return $c->render(json => { ok => 0, error => 'not accepted' });
	}
	my $until = &subs::rightNow() + 43200000;
	$c->session('app' => 1);
	$c->session('app_until' => $until);
	$c->session('app_device' => $device_uuid);
	$log->info('app gate: app login for ' . ($device->{'name'} || $device_uuid) . ' from ' . ($c->tx->remote_address || '?') . ' host=' . ($c->req->url->host || '-'));
	# The app key is the citizen door: a bootstrap session that pairs an app is
	# promoted here, or the citizen-only routes would still read guest.
	# A person is the identity; the device is how they carry it. The session
	# records the person when the device has one, and its privilege is the
	# person's. An unclaimed device is a guest, never a citizen; the owner
	# backfill attaches devices that predate the rule, and a later pairing
	# waits for an assignment.
	my $person = &subs::person_for_device($device_uuid);
	my $privilege = &subs::person_privilege($person);
	$c->session('authentication' => 'approved');
	$c->session('privilege' => $privilege);
	$c->session('person_uuid' => ($person ? $person->{'uuid'} : undef));
	$c->session('bootstrap' => undef);
	$log->info('app gate: app login ' . ($device->{'name'} || $device_uuid) . ' kind=' . $kind . ' until=' . $until
		. ' person=' . ($person ? $person->{'uuid'} . '/' . $privilege : 'unassigned'));
	$c->render(json => { ok => 1, until => $until, kind => $kind, name => $device->{'name'} });
}

# GET /manager/device/app_status
sub action_38048 {
	my $c = shift;
	&app_schema_ensure();
	my $device_uuid = $c->param('device_uuid') || $c->session('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	return $c->render(json => { ok => 0, error => 'not paired' }) unless $device;
	my ($pubkey, $kind) = &app_key_for($device);
	my $pending = &subs::db_select('device_requests', undef, { device_uuid => $device_uuid, kind => 'app', status => 'pending' })->hashes->[0];
	if ($pending && ($pending->{'server_time'} || 0) < &subs::rightNow() - 3600000) {
		# Too old for a person to still be looking at it. Expire it here so the
		# app-required page asks again instead of waiting on a dead request.
		&subs::db_update('device_requests', { status => 'expired', server_time => &subs::rightNow() }, { uuid => $pending->{'uuid'} });
		$pending = undef;
	}
	# The enrollment code is a short string two screens compare. It belongs to
	# the device that asked, so only that device's own session (the one whose
	# device_uuid is the requested one) or a house session may read it; anyone
	# else learns only that a request waits. The app takes its own code from
	# the signed app_request response it makes, never from here.
	my $session_device = $c->session('device_uuid') || '';
	my $bound = (length $session_device && $session_device eq $device_uuid) ? 1 : 0;
	my $house = (($c->session('authentication') || '') eq 'approved'
		&& &subs::privilege_is_house($c->session('privilege'))) ? 1 : 0;
	$c->render(json => {
		ok => 1,
		device => $device_uuid,
		has_app => ($pubkey ? 1 : 0),
		kind => ($kind || ''),
		app_session => (&app_session_ok($c) ? 1 : 0),
		pending => ($pending ? (($bound || $house) ? $pending->{'code'} : 1) : ''),
	});
}

# The installed app can lose the WebKit profile that held its device uuid (a
# cleared cache, a restored profile) while its key is still the one paired with
# the house. The public key is not a secret and the uuid is not a credential -
# app_login still needs a signature - so name the paired device that owns the
# key, and the page can seed its localStorage and sign in again.
# POST /manager/device/app_identify
sub action_38076 {
	my $c = shift;
	my $pubkey = $c->param('app_pubkey') || '';
	return $c->render(json => { ok => 0, error => 'no key' }) unless $pubkey =~ /BEGIN PUBLIC KEY/;
	my $device = &subs::db_select('paired_devices', [ 'uuid', 'name' ], { app_pubkey => $pubkey, status => 'active' })->hash;
	return $c->render(json => { ok => 0, error => 'not paired' }) unless $device && ($device->{'uuid'} || '') ne '';
	$log->info('app identify: paired device ' . $device->{'uuid'});
	$c->render(json => { ok => 1, uuid => $device->{'uuid'}, name => ($device->{'name'} || '') });
}

# A desktop app asks to add its native key to an already-paired device. It is
# approved on a trusted app (the phone), so a browser that can reach this route
# cannot mint an app identity for itself.
# POST /manager/device/app_request
sub action_38088 {
	my $c = shift;
	&app_schema_ensure();
	return $c->render(json => { ok => 0, error => 'not signed in' }) unless $c->session('authentication') eq 'approved';
	my $device_uuid = $c->param('device_uuid') || $c->session('device_uuid') || '';
	my $device = ($device_uuid && &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]);
	return $c->render(json => { ok => 0, error => 'not paired' }) unless $device;
	my ($existing) = &app_key_for($device);
	return $c->render(json => { ok => 1, already => 1 }) if $existing;
	my $nonce = $c->param('nonce') || '';
	return $c->render(json => { ok => 0, error => 'no challenge' }) unless &app_nonce_take('enroll', $device_uuid, $nonce);
	my $pubkey = $c->param('app_pubkey') || '';
	my $kind = ($c->param('app_kind') || 'ed25519') eq 'ec' ? 'ec' : 'ed25519';
	my $ok_key = $kind eq 'ec' ? &subs::ecdsa_public_key_ok($pubkey) : ($pubkey =~ /BEGIN PUBLIC KEY/ ? 1 : 0);
	return $c->render(json => { ok => 0, error => 'bad key' }) unless $ok_key;
	require Digest::SHA;
	my $msg = join("\n", 'app-request', $device_uuid, $nonce, Digest::SHA::sha256_hex($pubkey));
	# The pairing key signs the request when the app still has it. A desktop
	# app whose key lived in an older WebKit profile has the device uuid in
	# localStorage but no private key, so it cannot sign. It may still ASK, but
	# only for the device its own session is bound to - never a uuid the caller
	# picks - and the request still waits for a person to approve it on a
	# trusted app. That approval, not the signature, is the trust boundary.
	my $signed = 0;
	if ($c->param('device_signature')) {
		$signed = 1 if &subs::signature_verify($device->{'pubkey'}, $msg, $c->param('device_signature'));
	}
	unless ($signed) {
		my $session_device = $c->session('device_uuid') || '';
		unless ($session_device && $session_device eq $device_uuid) {
			$log->info('app gate: app request refused unsigned for ' . $device_uuid
				. ' (session device ' . ($session_device || 'none') . ')');
			return $c->render(json => { ok => 0, error => 'not accepted' });
		}
		$log->info('app gate: unsigned app request for ' . $device_uuid . ' (waits for approval)');
	}
	my $name = substr($c->param('name') || 'Desktop app', 0, 60);
	my $now = &subs::rightNow();
	my $code = &subs::device_request_code();
	my $uuid = &subs::random_string_creator(25);
	&subs::db_insert('device_requests', {
		uuid => $uuid, name => $name, pubkey => $device->{'pubkey'}, agent => substr($c->req->headers->user_agent // '', 0, 400),
		code => $code, status => 'pending', device_uuid => $device_uuid, kind => 'app',
		app_pubkey => $pubkey, app_kind => $kind, remote_address => ($c->tx->remote_address || ''),
		timestamp => $now, server_time => $now,
	});
	&device_request_notify($c, $name, $code);
	$c->render(json => { ok => 1, uuid => $uuid, code => $code });
}

# A machine with no key asks the house for its shares. It posts an ephemeral
# X25519 public key; holders re-wrap to it and the server only relays. The key
# itself never reaches the server, and a request that nobody answers expires.
# POST /manager/device/shares/request
sub action_38456 {
	my $c = shift;
	my $pubkey = $c->param('pubkey') // '';
	my $raw = eval { decode_base64($pubkey) };
	unless (defined $raw && length($raw) == 32) { $c->render(json => { ok => 0, error => 'bad key' }); return; }
	my $ip = $c->tx->remote_address;
	my $now = &subs::rightNow();
	&subs::house_key_share_cleanup();
	my $tries = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'share_ask', $ip . ':%', $now - 3600000)->hashes->[0]{'n'} || 0;
	my $waiting = &subs::db_query('select count(*) as n from house_key_share_requests where status = ? and server_time >= ?', 'open', $now - 1800000)->hashes->[0]{'n'} || 0;
	if ($tries >= 10 || $waiting >= 5) { $c->render(json => { ok => 0, error => 'too many' }); return; }
	&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'share_ask', app => '__president', server_time => $now, timestamp => $now });
	my $made = &subs::house_key_share_request_create($pubkey, $c->param('name'));
	unless ($made) { $c->render(json => { ok => 0, error => 'not made' }); return; }
	$c->render(json => {
		ok => 1,
		uuid => $made->{'uuid'},
		code => $made->{'code'},
		need => $made->{'need'},
		have => $made->{'have'},
		enough => ($made->{'have'} >= $made->{'need'} ? 1 : 0),
	});
}

# The asking machine polls this. The release blobs are sealed to the key it
# minted, so the server's answer is opaque to everyone else.
# GET /manager/device/shares/status
sub action_38481 {
	my $c = shift;
	my $uuid = $c->param('uuid') // '';
	my $req = &subs::house_key_share_request_open($uuid);
	unless ($req) { $c->render(json => { ok => 0, status => 'expired' }); return; }
	my $releases = &subs::house_key_share_releases($uuid);
	$c->render(json => {
		ok => 1,
		status => 'open',
		need => $req->{'need'},
		available => $req->{'available'},
		set_id => $req->{'set_id'},
		have => scalar(@{$releases}),
		releases => [ map { { share_index => $_->{'share_index'}, wrapped => $_->{'wrapped'} } } @{$releases} ],
	});
}

# The gate's recovery door: the paper code unwraps the sealed suds and the
# browser is paired on the spot. Throttled per address, and a stale code (the
# house key changed since it was made) is refused by the canary check.
# POST /manager/device/recover
sub action_38500 {
	my $c = shift;
	my $code = &subs::recovery_code_clean($c->param('code'));
	my $raw_code = $c->param('code') // '';
	# three shares pasted on separate lines (or separated by commas) are a third
	# way in; base64 is case-sensitive, so these are read from the raw field
	my @share_codes = grep { /\S/ } split /[\s,]+/, $raw_code;
	unless (length $code >= 20 || @share_codes) { $c->render(json => { ok => 0, error => 'not accepted' }); return; }
	my $ip = $c->tx->remote_address;
	my $now = &subs::rightNow();
	my $tries = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'recovery_attempt', $ip . ':%', $now - 3600000)->hash->{'n'} || 0;
	if ($tries >= 5) { $c->render(json => { ok => 0, error => 'too many' }); return; }
	&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'recovery_attempt', app => '__president', server_time => $now, timestamp => $now });
	# The paper code or three shares. The password is a login, not a recovery
	# share: it no longer unwraps the house key, so a lost key needs the code or
	# a threshold, never one remembered secret.
	my $suds;
	if (length $code >= 20) {
		my $row = &subs::db_query('select value from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'recovery')->hashes->[0];
		$suds = eval { &subs::note_decrypter($code, $row->{'value'}) } if $row && $row->{'value'};
	}
	if (!(defined $suds && length $suds) && @share_codes) {
		$suds = &subs::shamir_open_shares(\@share_codes);
	}
	$suds =~ s/\s+$// if $suds;
	unless ($suds && &subs::suds_current($suds)) { $c->render(json => { ok => 0, error => 'not accepted' }); return; }
	&subs::vault_seed($suds, 1);
	# this worker must resolve the recovered key at once (the session's suds_id
	# is minted from it), and the duty stamp nudges the other workers to re-read
	# the vault instead of their memoized copy
	$gb::suds = $suds;
	# the paper code is also the way past a padlock: the same recovery that
	# unwraps the house key opens the lock, so a forgotten phone is not a lockout
	if (&subs::db_select('security', undef, { level => 'padlock' })->hashes->[0]) {
		&padlock_mark_unlocked($c, 'locker');
	}
	&subs::setting_setter({ app => '__president', setting => 'remote_duty', value => &subs::rightNow() });
	my $name = substr($c->param('name') || 'Recovered Device', 0, 60);
	my $person_uuid = &subs::people_owner_ensure();
	my $uuid = &device_store_pubkey($c->param('pubkey'), $name, $c->req->headers->user_agent, $person_uuid);
	unless ($uuid) { $c->render(json => { ok => 0, error => 'no key' }); return; }
	&device_session_mint($c, $uuid);
	$c->render(json => { ok => 1, device_uuid => $uuid, name => $name });
}

# A new device's ask: it posts its public key before it has any session, and a
# citizen approves it from a device that is already signed in. The short code
# is the same on both screens, so the wrong request is not approved by habit.
# POST /manager/device/request
sub action_38547 {
	my $c = shift;
	my $pem = &device_pubkey_clean($c->param('pubkey'));
	unless ($pem) { $c->render(json => { ok => 0, error => 'no key' }); return; }
	my ($db) = &subs::database_grabber();
	unless ($db) { $c->render(json => { ok => 0, error => 'no database' }); return; }
	my $now = &subs::rightNow();
	&subs::db_query('delete from device_requests where status = ? and server_time < ?', 'pending', $now - 3600000);
	my $open = &subs::db_select('device_requests', undef, { pubkey => $pem, status => 'pending' })->hashes->[0];
	if ($open) { $c->render(json => { ok => 1, uuid => $open->{'uuid'}, code => $open->{'code'} }); return; }
	# the door's throttle: ten asks per address per hour, five waiting at once
	my $ip = $c->tx->remote_address;
	my $tries = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'device_request', $ip . ':%', $now - 3600000)->hash->{'n'} || 0;
	my $waiting = &subs::db_query('select count(*) as n from device_requests where status = ?', 'pending')->hash->{'n'} || 0;
	if ($tries >= 10 || $waiting >= 5) { $c->render(json => { ok => 0, error => 'too many' }); return; }
	&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'device_request', app => '__president', server_time => $now, timestamp => $now });
	my $uuid = &subs::random_string_creator(25);
	my $name = substr($c->param('name') || 'Device', 0, 60);
	my $agent = substr($c->req->headers->user_agent // '', 0, 400);
	my $code = &subs::device_request_code();
	&subs::db_insert('device_requests', {
		uuid => $uuid,
		name => $name,
		pubkey => $pem,
		agent => $agent,
		code => $code,
		status => 'pending',
		remote_address => $ip,
		timestamp => $now,
		server_time => $now
	});
	&device_request_notify($c, $name, $code);
	$c->render(json => { ok => 1, uuid => $uuid, code => $code });
}

# The asking device polls this. Approval made on another machine shows up here
# as fast as the roster merges - the key itself is the proof, so the status is
# right even before the request row's own copy of the decision arrives.
# POST /manager/device/request_status
sub action_38584 {
	my $c = shift;
	my $uuid = $c->param('uuid') || '';
	my $row = ($uuid && &subs::db_select('device_requests', undef, { uuid => $uuid })->hashes->[0]);
	unless ($row) { $c->render(json => { ok => 0, status => 'unknown' }); return; }
	my $now = &subs::rightNow();
	if ($row->{'status'} eq 'pending') {
		if ($row->{'server_time'} < $now - 600000) {
			&subs::db_update('device_requests', { status => 'expired', server_time => $now }, { uuid => $uuid });
			$c->render(json => { ok => 1, status => 'expired' }); return;
		}
		my $paired = &subs::db_select('paired_devices', undef, { pubkey => $row->{'pubkey'}, status => 'active' })->hashes->[0];
		if ($paired) {
			&subs::db_update('device_requests', { status => 'approved', device_uuid => $paired->{'uuid'}, server_time => $now }, { uuid => $uuid });
			$c->render(json => { ok => 1, status => 'approved', device_uuid => $paired->{'uuid'} }); return;
		}
		$c->render(json => { ok => 1, status => 'pending' }); return;
	}
	$c->render(json => { ok => 1, status => $row->{'status'}, device_uuid => $row->{'device_uuid'} || '' });
}

# POST /manager/device/join
# The other way a machine arrives. New writes a token into a board's image while
# the board is still in recovery, and the board's first boot redeems it here.
# The token was minted by an authenticated citizen's press, is single use and
# lives in the machine-local cache, so redeeming it is proof that the press
# happened rather than a public door. The row it writes is the same one a
# citizen makes by accepting a join code, and the grant goes through
# peer_grant_setter so the lease rules stay in one place.
sub action_38590 {
	my $c = shift;
	my $secret = $c->param('secret') || '';
	return $c->render(json => { ok => 0, error => 'no token' }) unless $secret =~ /^[A-Za-z0-9]{16,64}$/;
	my $pubkey = &device_pubkey_clean($c->param('pubkey'));
	return $c->render(json => { ok => 0, error => 'no key' }) unless $pubkey;
	# A row without a signatorial could never be proved on the peer rail, so it is
	# not a machine the house should file. This is checked before the token is
	# spent: a refused request must not use up the board's one chance.
	my $signatorial = $c->param('signatorial') || '';
	return $c->render(json => { ok => 0, error => 'no name for the machine' })
		unless $signatorial =~ /^[0-9a-fA-F]{16,64}$/;
	my $now = &subs::rightNow();
	my $pending = &subs::db_select('cache', undef, { context => 'controller_join', subcontext => $secret })->hash;
	unless ($pending) {
		return $c->render(json => { ok => 0, error => 'that token is not waiting, or it has expired' });
	}
	# One use only: spend the token before anything else can find it.
	&subs::db_delete('cache', { uuid => $pending->{'uuid'} });
	my $wanted = eval { decode_json($pending->{'data'} // '') } || {};
	my $name = substr(($c->param('name') || $wanted->{'name'} || 'Controller'), 0, 60);
	# Where the board is: it names its own address the way a joining machine
	# does; a request that names none is filed by the address it came from.
	my $address = $c->param('address') || '';
	$address = ($c->tx->remote_address || '') unless length $address;
	my $addr = $address;
	$addr =~ s{^https?://}{};
	$addr =~ s{/.*$}{};
	my ($host, $addr_port) = $addr =~ /^(.+?)(?::(\d+))?$/;
	$host = '' unless defined $host;
	my $port = $addr_port || $c->param('port') || '';
	# A joining board is named under the house domain, unless a person already
	# named it: the map is the same Configure -> Plat -> DNS list, written once
	# and synced, so the board reads its own entry back through public_host().
	my $public_name = &subs::house_machine_name($name, $signatorial, 1);
	my $reachable = length $public_name ? $public_name : $host;
	my $known = $signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hash : undef;
	my $uuid = ($known && $known->{'uuid'}) ? $known->{'uuid'} : &subs::random_string_creator(15);
	my $row = {
		uuid => $uuid,
		ip => $host,
		fqdn => (length $public_name ? $public_name : $host),
		port => $port,
		manager => (length $reachable ? 'https://' . $reachable . (length $port ? ':' . $port : '') . '/manager' : ''),
		signatorial => $signatorial,
		pubkey => $pubkey,
		hostname => $name,
		device => substr($c->param('device') || 'controller', 0, 30),
		ost => substr($c->param('ost') || '', 0, 40),
		status => 'connected',
		connection => 'active',
		server_time => $now,
		timestamp => $now,
	};
	if ($known) { &subs::db_update('remote_machines', $row, { uuid => $uuid }); }
	else { &subs::db_insert('remote_machines', $row); }
	# The grant a citizen's own machine carries: this row exists because a
	# citizen pressed New, not because a stranger guessed a code.
	&subs::peer_grant_setter({ uuid => $uuid, scope => 'trusted', privilege => 'citizen', expires => '' });
	# The roster the Controllers page draws is paired_devices, and a board that
	# joined by token is a controller the same way one that confirmed a code is:
	# file it there under the same uuid the machine row carries (that row is what
	# holds the signatorial), so Storage, ROMs and the card choice all resolve.
	my $roster = &subs::db_select('paired_devices', undef, { pubkey => $pubkey })->hash;
	my $roster_row = {
		name => $name,
		kind => 'controller',
		status => 'active',
		pubkey => $pubkey,
		privilege => 'citizen',
		agent => substr($c->param('agent') || 'controller join', 0, 400),
		server_time => $now,
	};
	if ($roster) {
		&subs::db_update('paired_devices', $roster_row, { uuid => $roster->{'uuid'} });
	}
	else {
		$roster_row->{'uuid'} = $uuid;
		$roster_row->{'timestamp'} = $now;
		&subs::db_insert('paired_devices', $roster_row);
	}
	# The leaf is issued after the row exists: the CA signs a name that is now the
	# board's, and only this response carries the certificate and its key. A board
	# says whether it proved the house's leaf; the request is signed with its body,
	# so an on-path relay cannot turn an unverified join into a verified one. Only
	# a verified board is handed a private key.
	my $trusted = ($c->param('tls_verified') // '') eq '1';
	my $tls;
	if (!length $public_name) {
		$tls = { ok => 0, error => 'the house has no public domain' };
	}
	elsif (!$trusted) {
		$tls = { ok => 0, error => 'the board did not verify this connection' };
	}
	else {
		$tls = &_controller_join_certificate($public_name, $host);
	}
	$log->info('controller join: ' . $name . ' uuid ' . $uuid . ' ' . ($host || 'no address')
		. (length $public_name ? ' as ' . $public_name : '')
		. ($tls->{'ok'} ? ' with a house leaf' : ' without a leaf (' . ($tls->{'error'} || 'no CA') . ')'));
	# The board files this machine the same way; handing back the house's own
	# identity saves it a discovery pass before its first sync. The leaf is the
	# board's own certificate: it is never logged, and only this board's response
	# carries it.
	$c->render(json => {
		ok => 1,
		uuid => $uuid,
		public_host => $public_name,
		tls => $tls,
		house => {
			manager => &subs::house_manager_address(eval { $c->req->url->to_abs->to_string } || ''),
			signatorial => &subs::signatorial_designer() || '',
			pubkey => &subs::peer_pubkey() || '',
			name => &subs::machine_name() || '',
		},
	});
}

# The house CA issues the board a leaf for the name it just joined under. The
# leaf covers the public name, the address the board gave, and 127.0.0.1 (the
# kiosk opens the local manager); the first boot installs it as both pairs, so
# the main listener serves the public name and the peer listener serves the same
# leaf, signed by the CA every enrolled machine already trusts. The CA key never
# leaves the house: a machine without it still names the board and says why the
# leaf is missing.
# The leaf a joining board is given. A machine that holds the house CA signs it
# locally; a client (a laptop flashing a board) asks the house over the peer
# rail, so the CA key still never leaves the house. Returns the same
# {ok, host, cert, key} shape either way, or an error explaining why not.
sub _controller_join_certificate {
	my ($fqdn, $address) = @_;
	my $local = &_controller_issue_leaf_here($fqdn, $address);
	return $local if $local->{'ok'};
	return $local unless ($local->{'error'} // '') eq 'the house CA is not on this machine';
	my $remote = &_controller_leaf_from_house($fqdn, $address);
	return $remote if $remote;
	return $local;
}

# Ask the rostered machines for the leaf. Only the one holding the CA key answers
# with a certificate; the rest say they are not it, and a machine that has not
# been updated yet simply does not answer. Server rows are tried first, and the
# list is short because the joining board is waiting on this answer.
sub _controller_leaf_from_house {
	my ($fqdn, $address) = @_;
	my $mine = &subs::signatorial_designer() || '';
	my $rows = eval { &subs::db_select('remote_machines')->hashes } || [];
	my @candidates = grep {
		ref $_ eq 'HASH'
			&& ($_->{'signatorial'} // '') ne $mine
			&& length($_->{'pubkey'} // '')
			&& ($_->{'manager'} // '') =~ m{^https?://}
	} @{$rows};
	@candidates = sort {
		(($b->{'device'} // '') eq 'server' ? 1 : 0) <=> (($a->{'device'} // '') eq 'server' ? 1 : 0)
	} @candidates;
	@candidates = @candidates[0 .. 1] if @candidates > 2;
	return undef unless @candidates;
	require Mojo::UserAgent;
	require Mojo::JSON;
	foreach my $rm ( @candidates ) {
		my $manager = &subs::peer_live_manager($rm) || $rm->{'manager'};
		my ($endpoint, $verified) = &subs::peer_secure_url($rm, $manager);
		my $port = '';
		$port = $1 if ($rm->{'manager'} // '') =~ m{:(\d{1,5})/manager/?$};
		# The public name first: its wildcard is a certificate the machine's
		# system store already trusts, and the route answers a signed request
		# there. The peer listener, whose leaf the house CA signs, is the
		# fallback for a house without public DNS. Both are verified rails;
		# there is no insecure one, because the answer carries a private key.
		my @tries;
		my $public = $rm->{'fqdn'} // '';
		if (length $public && $public =~ /\./ && $public !~ /^(?:localhost|127\.)/i) {
			push @tries, ['https://' . $public . (length $port ? ':' . $port : '') . '/manager', 0];
		}
		push @tries, [$endpoint, 1] if $verified && defined $endpoint && length $endpoint;
		foreach my $try ( @tries ) {
			my ($base, $use_ca) = @{$try};
			my $ua = Mojo::UserAgent->new->connect_timeout(3)->request_timeout(6);
			next if $use_ca && !&subs::peer_tls_verify($ua);
			# The machine's own peer session is the second proof the house gate
			# accepts. A roster key can rotate or a mirror row can be stale, while
			# the session this machine already syncs under still names it; send
			# both, over the verified connection only.
			my $jar = eval { decode_json($rm->{'cookie'} // '') };
			if (ref $jar eq 'ARRAY') {
				require Mojo::Cookie::Response;
				foreach my $c ( @{$jar} ) {
					next unless ref $c eq 'HASH' && defined $c->{'name'};
					$ua->cookie_jar->add(Mojo::Cookie::Response->new(
						name => $c->{'name'}, value => ($c->{'value'} // ''),
						domain => ($c->{'domain'} // ''), path => ($c->{'path'} // '/'),
					));
				}
			}
			$ua->on(start => sub { &subs::peer_sign_request($_[1]->req) });
			my $res = eval {
				$ua->post($base . '/device/leaf' => form => {
					signatorial => $mine,
					name => $fqdn,
					address => ($address // ''),
				})->result;
			};
			next unless $res;
			my $answer = eval { Mojo::JSON::decode_json($res->body // '') } || {};
			next unless ref $answer eq 'HASH' && $answer->{'ok'} && ref $answer->{'tls'} eq 'HASH';
			return $answer->{'tls'} if $answer->{'tls'}->{'ok'};
		}
	}
	return undef;
}

# Issue the leaf on this machine. Only the machine holding the CA key can; the
# join route asks the house when it cannot.
sub _controller_issue_leaf_here {
	my ($fqdn, $address) = @_;
	return { ok => 0, error => 'the house CA script is missing' } unless -f 'scripts/house_ca.pl';
	my $server = eval { &subs::server_dir() } || 'server';
	return { ok => 0, error => 'the house CA is not on this machine' }
		unless -f "$server/house-ca.pem" && -f "$server/house-ca.key";
	my ($label) = split /\./, $fqdn;
	my @args = ('--name', $label, '--dns', $fqdn, '--ip', '127.0.0.1');
	if (defined $address && length $address) {
		if ($address =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) { push @args, '--ip', $address }
		elsif ($address =~ /^[A-Za-z0-9][A-Za-z0-9.-]*$/ && $address =~ /\./ && lc $address ne lc $fqdn) {
			push @args, '--dns', $address;
		}
	}
	require File::Temp;
	require File::Path;
	my $out = File::Temp::tempdir('jawnos-join-leaf-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	push @args, '--out', $out, '--force';
	# house_ca.pl reads the store's server/ directory. Give the child this
	# process's store, so a test sandbox and a packaged install agree.
	my $run = eval {
		&subs::subprocessor_command([$^X, 'scripts/house_ca.pl', 'issue', @args], {
			name => 'house CA leaf', stdout => 'capture', stderr => 'capture',
			warranty => '60s', env => { 'JAWNOS_STORE_DIR' => &subs::store_dir() },
		});
	};
	unless (ref $run eq 'HASH') {
		return { ok => 0, error => 'the house CA could not run' };
	}
	my $cert = &_join_pem("$out/peer-fullchain.pem");
	my $key = &_join_pem("$out/peer-privkey.pem");
	unless (length $cert && length $key) {
		my $why = $run->{'output'} || $run->{'error'} || '';
		$why =~ s/\s+/ /g;
		$why =~ s/^\s+|\s+$//g;
		File::Path::remove_tree($out);
		return { ok => 0, error => (length $why ? substr($why, 0, 300) : 'the house CA did not issue the leaf') };
	}
	File::Path::remove_tree($out);
	return { ok => 1, host => $fqdn, cert => $cert, key => $key };
}

# POST /manager/device/leaf
# A house machine that flashed a board on this house's behalf asks the CA holder
# for the board's leaf. Only a rostered peer on the Trusted rung may ask, and
# only for a name under the house domain; the CA key stays here.
sub action_38591 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $rm = $signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hash : undef;
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm) && &subs::peer_allows($c, $rm, 'trusted')) {
		$c->rendered(403);
		return;
	}
	my $fqdn = lc($c->param('name') || '');
	my $address = $c->param('address') || '';
	my $domain = &subs::house_domain();
	unless (length $domain
		&& $fqdn =~ /^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)\.\Q$domain\E$/) {
		return $c->render(json => { ok => 0, error => 'that name is not under this house domain' });
	}
	my $tls = &_controller_issue_leaf_here($fqdn, $address);
	unless ($tls->{'ok'}) {
		return $c->render(json => { ok => 0, error => ($tls->{'error'} || 'the house CA is not on this machine') });
	}
	$c->render(json => { ok => 1, tls => $tls });
}

sub _join_pem {
	my ($path) = @_;
	return '' unless defined $path && -f $path;
	return '' unless open(my $fh, '<', $path);
	local $/;
	my $body = <$fh> // '';
	close $fh;
	return $body;
}

1;
