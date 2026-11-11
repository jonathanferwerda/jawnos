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

1;
