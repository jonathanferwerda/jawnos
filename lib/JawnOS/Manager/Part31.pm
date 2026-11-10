package Manager;

# Manager helpers, part 31 of 37. Moved out of Manager.pl so a
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

sub go_approval_get {
	my ($id) = @_;
	return {} unless defined $id && $id =~ /^[A-Za-z0-9]{8,64}$/;
	my $row = &subs::db_query('select data, server_time from cache where context = ? and uuid = ? and server_time > ? limit 1', 'go_approval', 'goa' . $id, &subs::rightNow() - 120000)->hashes->[0];
	return {} unless $row;
	my $d = eval { decode_json $row->{'data'} } || {};
	$d->{'time'} ||= $row->{'server_time'};
	return $d;
}

sub go_approval_clear {
	my ($id) = @_;
	return unless defined $id && $id =~ /^[A-Za-z0-9]{8,64}$/;
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'go_approval', 'goa' . $id);
}

# Dismiss any device prompt still showing this request (the target is the
# request id, not a screen, so the padlock handler only dismisses and stops).
sub go_dismiss {
	my ($id) = @_;
	&Websocket::send('server', { padlock_open => 1, mode => 'go', target => ($id || ''), timestamp => &subs::rightNow() });
}

# A request that came from this machine itself. The phone/tablet is remote, so
# its signature opens the lock; the locked screen's own key may not.
sub padlock_request_is_local {
	my ($c) = @_;
	my $local = $c->tx->local_address || '';
	my $remote = $c->tx->remote_address || '';
	return 1 if $local eq $remote;
	return 1 if $remote =~ /^(?:127\.|::1$|::ffff:127\.)/;
	# a browser reaching this machine by its LAN name (or through a hairpin)
	# still counts as this machine: the phone is never one of our own addresses
	our $padlock_mine_at = 0;
	our @padlock_mine;
	if (!$padlock_mine_at || time - $padlock_mine_at > 60) {
		# Every address this machine answers on, IPv4 first. hostname(1) -I is not
		# on every distro (this laptop's rejects it), and an empty list made a
		# machine's own browser look remote: the local fingerprint was refused
		# and the host would not refuse its own signature. The platform seam reads
		# ip(8) - or ifconfig - once, and falls back on its own.
		require JawnOS::Platform::Net;
		@padlock_mine = @{ JawnOS::Platform::Net::addresses() };
		$padlock_mine_at = time;
	}
	return 1 if grep { $_ eq $remote } @padlock_mine;
	return 0;
}

# A phone that enrolled its Keystore fingerprint: the lock screen should offer
# that fingerprint even when the page itself cannot see the native bridge (the
# button then explains that the app is needed rather than hiding silently).
sub biometric_enrolled_for {
	my ($device_uuid) = @_;
	return 0 unless $device_uuid;
	my $d = &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0];
	return ($d && $d->{'bio_pubkey'}) ? 1 : 0;
}

sub fingerprint_available {
	return 0 unless -x '/usr/bin/fprintd-verify';
	my $now = time;
	if (!$fingerprint_checked_at || $now - $fingerprint_checked_at > 60) {
		my $user = $ENV{USER} || getpwuid($<) || 'jawn';
		$user =~ s/[^\w.-]//g;
		my $out = `fprintd-list $user 2>/dev/null`;
		$fingerprint_ok = ($out =~ /Fingerprints for user/i && $out !~ /no finger/i) ? 1 : 0;
		$fingerprint_checked_at = $now;
	}
	return $fingerprint_ok || 0;
}

sub padlock_gate_allows {
	my ($path) = @_;
	return 1 if $path =~ m{^/(?:css|js|images|icons|sounds|fonts|public)/};
	return 1 if $path =~ m{^/(?:favicon\.ico|manifest\.json|service_worker\.js|robots\.txt)$};
	return 1 if $path eq '/manager/ws' || $path eq '/manager/health';
	return 1 if $path eq '/manager/health_report';
	return 1 if $path eq '/manager/available';
	# an alarm edit from a linked machine is not a UI action; the route verifies
	# the peer signature, so a locked screen can still receive its schedule
	return 1 if $path eq '/manager/clock/alarm';
	return 1 if $path eq '/manager/address_report';
	return 1 if $path eq '/manager/address_directory';
	return 1 if $path eq '/manager/address_lookup';
	return 1 if $path =~ m{^/(?:manager/)?box_office(?:/|$)};
	# the device rail authenticates itself and must reach the gate's recovery
	return 1 if $path =~ m{^/manager/device(?:/|$)};
	return 1 if $path eq '/manager/security/padlock_phone_show';
	return 1 if $path eq '/manager/security/padlock_challenge';
	return 1 if $path eq '/manager/security/padlock_unlock';
	return 1 if $path eq '/manager/security/padlock_open_peer';
	return 1 if $path eq '/manager/security/padlock_key_show_peer';
	return 1 if $path eq '/manager/security/padlock_state';
	return 1 if $path eq '/manager/security/media_lock';
	return 1 if $path eq '/manager/security/padlock_key';
	return 1 if $path eq '/manager/security/fingerprint_unlock_status';
	return 1 if $path eq '/manager/security/fingerprint_unlock';
	return 1 if $path eq '/manager/security/biometric_challenge';
	return 1 if $path eq '/manager/security/biometric_unlock';
	# the Android dashboard's Update app asks the local jawn to pull the newest
	# APK; it needs no house data and is session-gated inside the route, so a
	# locked screen can still take its own update
	return 1 if $path eq '/manager/app_release_sync';
	# A passkey is a way in, like the paper code: the enrollment page and the
	# sign-in routes answer while the screen is locked.
	return 1 if $path =~ m{^/passkey(?:/|$)};
	return 1 if $path =~ m{^/manager/webauthn/login/(?:begin|finish)$};
	return 0;
}

sub padlock_device_locked {
	my ($device_uuid) = @_;
	return 0 unless $device_uuid;
	return &subs::db_query('select 1 from security where level = ? and uuid = ? limit 1', 'padlock_device', $device_uuid)->hashes->[0] ? 1 : 0;
}

# The screen's own unlock stamp, used only when the whole house is locked: it
# is what lets one screen open without opening every screen.
sub padlock_device_until {
	my ($device_uuid) = @_;
	return 0 unless $device_uuid;
	my $row = &subs::db_query('select value from settings where app = ? and setting = ? and device = ? order by server_time desc limit 1', '__president', 'padlock_device_time', $device_uuid)->hashes->[0];
	return $row ? (&padlock_time_value(undef, $row->{'value'}) || 0) : 0;
}

sub padlock_device_set_time {
	my ($device_uuid, $until) = @_;
	return unless $device_uuid && $until;
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'padlock_device_time', $device_uuid);
	my $now = &subs::rightNow();
	&subs::db_insert('settings', { app => '__president', setting => 'padlock_device_time', device => $device_uuid, value => $until, server_time => $now, timestamp => $now, uuid => &subs::random_string_creator(25) });
}

sub padlock_device_clear_time {
	my ($device_uuid) = @_;
	return unless $device_uuid;
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'padlock_device_time', $device_uuid);
}

# What a target's unlock request is asking about: a manual row always locks;
# a screen timer decides on its own; otherwise the house-wide timer does.
sub padlock_target_locked {
	my ($target, $c) = @_;
	return 0 unless $target;
	return 1 if &padlock_device_locked($target);
	my $until = &padlock_device_until($target);
	return (&subs::rightNow() > $until) ? 1 : 0 if $until;
	return &padlock_global_locked($c);
}

sub padlock_time_value {
	my ($suds, $raw) = @_;
	return 0 unless defined $raw && length $raw;
	return $raw if $raw =~ /^\d{10,}$/;
	$suds = &subs::suds_grabber() unless $suds;
	my $memo_key = &subs::suds_id($suds) . "\x1f" . $raw;
	return $padlock_time_memo{$memo_key} if exists $padlock_time_memo{$memo_key};
	my $value = &subs::decrypter($suds, $raw) || 0;
	%padlock_time_memo = () if keys(%padlock_time_memo) > 512;
	return $padlock_time_memo{$memo_key} = $value;
}

# $state is the truth this request has already established (see
# authentication_passer): { row => the padlock security row, contexts => the
# decoded padlock_contexts }. It saves the duplicate reads without changing
# the answer; callers with nothing prefetched pass nothing.
sub padlock_global_locked {
	my ($c, $state) = @_;
	my $padlock = $state ? $state->{'row'} : &subs::db_query('select * from security where level = ?', 'padlock')->hashes->[0];
	return 0 unless $padlock;
	my $contexts = $state ? $state->{'contexts'} : (eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'padlock_contexts' }) } || []);
	return 0 unless grep { $_ eq 'general' } @{$contexts};
	my $row = &subs::db_query('select value from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'pl_time')->hashes->[0];
	# No stamp means this machine has never been locked since the gate was set;
	# it is not an expired lock. A lock always writes the stamp, so absence is
	# open. (A peer that has not pulled the row yet must not claim the house is
	# locked and hide the phone's Unlock button.)
	return 0 unless $row;
	my $pl = &padlock_time_value(undef, $row->{'value'}) || 0;
	return (&subs::rightNow() > $pl) ? 1 : 0;
}

sub padlock_locked_now {
	my ($c, $device, $state) = @_;
	my $padlock = $state ? $state->{'row'} : &subs::db_query('select * from security where level = ?', 'padlock')->hashes->[0];
	return 0 unless $padlock;
	my $contexts = $state ? $state->{'contexts'} : (eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'padlock_contexts' }) } || []);
	return 0 unless grep { $_ eq 'general' } @{$contexts};
	$device = $c->session('device_uuid') || '' unless defined $device;
	if ($device) {
		return 1 if &padlock_device_locked($device);
		my $until = &padlock_device_until($device);
		return (&subs::rightNow() > $until) ? 1 : 0 if $until;
	}
	return &padlock_global_locked($c, $state);
}

sub padlock_gate_shadow {
	my ($c) = @_;
	my $path = $c->req->url->path->to_string;
	my $method = $c->req->method || 'GET';
	my $remote = $c->tx->remote_address || '?';
	$log->info("padlock shadow: would deny $method $path from $remote");
}

sub padlock_gate_answer {
	my ($c) = @_;
	my $path = $c->req->url->path->to_string;
	my $xhr = (($c->req->headers->header('X-Requested-With') // '') =~ /XMLHttpRequest/i);
	my $json = (($c->req->headers->accept // '') =~ m{application/json}i);
	if ($xhr || $json || $path =~ /\.json$/) {
		$c->res->code(423);
		$c->render(json => { error => 'locked', locked => 1, gate => &padlock_gate_mode() });
		return;
	}
	my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes->[0];
	$c->res->code(423);
	$c->res->headers->cache_control('no-store, max-age=0');
	$c->render(template => 'locked', layout => 'locked', has_padlock => ($padlock ? 1 : 0), target => ($c->session('device_uuid') || ''), locked_device => ($c->session('device_uuid') || ''), fingerprint => (&fingerprint_available() && &padlock_request_is_local($c)) ? 1 : 0, biometric => &biometric_enrolled_for($c->session('device_uuid') || ''), signatorial => &subs::signatorial_designer());
	return;
}

# One way to open: a paired device's signature, the paper recovery code, and
# the emergency paths all land here. A manual gate locks one device; a target
# names it, an empty target is the house-wide timeout lock. The global timer is
# moved past now either way, so the unlocked screen is not re-locked at once.
# The key material in Security is a second door behind the app: rotating the
# house key, replacing the recovery code, splitting or releasing shares, and
# adding or removing a passkey each ask for the person again. Only a grant
# minted in the last two minutes counts, so browsing the app on one unlock is
# not enough to change how the house can be opened.
sub security_action_open {
	my ($c) = @_;
	return &media_unlock_open($c, 'security', 120000) ? 1 : 0;
}

sub padlock_mark_unlocked {
	my ($c, $mode, $target, $tab_override) = @_;
	$mode ||= 'locker';
	$mode = 'locker' unless $mode =~ /^(?:locker|gallery|music|folders|security|private)$/;
	my $suds = &subs::suds_grabber() || &subs::session_suds($c) || $gb::suds;
	return 0 unless $suds;
	# Opening an app's padlock makes that app one of the lock's contexts. A
	# device whose contexts were only "general" otherwise has no such padlock:
	# it shows no Unlock button, and the token the unlock mints could never
	# validate there (media_unlock_open reads this same list).
	if ($mode ne 'locker') {
		my $contexts = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'padlock_contexts' }) } || [];
		unless (grep { $_ eq $mode } @{$contexts}) {
			push @{$contexts}, $mode;
			&subs::setting_setter({ app => '__president', setting => 'padlock_contexts', value => encode_json $contexts });
		}
	}
	my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
	$activity_timeout = abs &subs::time_abbrev_translator($activity_timeout);
	my $new_timeout = &subs::rightNow() + $activity_timeout;
	$target = $c->session('device_uuid') || '' unless defined $target;
	if ($target) {
		&subs::db_delete('security', { level => 'padlock_device', uuid => $target });
		# a screen opened while the whole house is locked keeps a timer of its
		# own; the other screens stay locked on the house-wide stamp
		if (&padlock_global_locked($c)) {
			&padlock_device_set_time($target, $new_timeout);
		}
		else {
			&padlock_device_clear_time($target);
		}
	}
	else {
		# a whole-house open clears every screen's own lock too: a leftover
		# padlock_device row keeps that screen behind the gate even though the
		# house stamp says open (the "unlock, see the manager, lock again" loop)
		&subs::db_delete('security', { level => 'padlock_device' });
		&subs::db_query('delete from settings where app = ? and setting = ?', '__president', 'padlock_device_time');
		&subs::setting_setter({ app => '__president', setting => 'pl_time', value => $new_timeout });
	}
	$c->session('pl_time' => $new_timeout);
	&subs::setting_setter({ app => '__president', setting => 'padlock_pulls', value => &subs::note_encrypter($suds, 0) });
	if ($mode =~ /^(?:gallery|music|folders|security|private)$/) {
		my $device = $target || &media_unlock_device($c);
		my $request = &padlock_request_for_target($device);
		# the request row names the screen that pressed Unlock; the caller's own
		# tab is only a fallback (a phone confirming another screen carries its
		# own tab, which must not receive that screen's token)
		my $tab = $tab_override || $request->{'tab'} || $c->param('browser_tab_id') || '';
		$tab = '' unless $tab =~ /^[A-Za-z0-9_-]{1,64}$/;
		# Only the machine that holds the screen may mint its app grant. The
		# unlock is relayed to every peer so the screen's own jawn hears it, and
		# each peer used to mint a grant of its own - the app then opened on
		# machines nobody had asked about. A local print or button, or a request
		# this machine wrote for this screen, is the whole test; a peer's relay
		# is never local even when a tunnel makes its address look so.
		my $peer_route = (($c->req->url->path // '') eq '/manager/security/padlock_open_peer') ? 1 : 0;
		my $mine = &media_unlock_device($c);
		# A local reader or button opens the screen it is attached to. A local
		# phone confirming ANOTHER screen is not that screen's host: its own
		# grant would sit in the wrong database, so the relay below mints it.
		my $hosted = (!$peer_route && &padlock_request_is_local($c) && length $mine && $target eq $mine) ? 1 : 0;
		$hosted = 1 if (!$hosted && $request->{'id'}
			&& (($request->{'source'} || '') eq &subs::signatorial_designer()));
		if ($hosted && length $device) {
			my $token = &media_unlock_store($mode, $device, $tab);
			if (length $token) {
				my $js = &Websocket::console_command('mediaUnlock', $mode, $token);
				# one window's message, so another tab of the same screen stays
				# shut and no peer is told to drop a token it never held
				&Websocket::send('server', { console => $js, browser_tab_id => $tab }) if length $tab;
			}
		}
	}
	else {
		&Websocket::send('server', { padlock_open => 1, mode => $mode, target => $target, timestamp => &subs::rightNow() });
		# a targeted open is the phone's message to one screen; the console form
		# would run on every tab, so it is only used for a whole-house open
		&Websocket::send('server', { console => &Websocket::console_command('padlockFrame')}) unless $target;
	}
	# this request has been answered; a device that wakes later must not ask
	# the person to confirm an unlock that already happened
	&padlock_request_clear($target);
	return 1;
}

# --- local biometric unlock ------------------------------------------------
# The phone's Android app keeps an EC P-256 key in the Android Keystore with
# setUserAuthenticationRequired: the OS will not use it until the person passes
# the fingerprint prompt. The house verifies the key's signature, so this is a
# real factor - unlike the JS confirmation the phone-as-key page uses - and it
# is the one signature a local request may present. It opens only the screen it
# is on, never another device and never the whole house.
sub biometric_nonce_take {
	my ($purpose, $device_uuid, $nonce, $ttl) = @_;
	$ttl ||= 60000;
	return 0 unless defined $nonce && $nonce =~ /^[A-Za-z0-9]{8,64}$/;
	my $stamp = $purpose . ':' . $device_uuid . ':' . $nonce;
	my $seen = &subs::db_query('select server_time from cache where context = ? and uuid = ? limit 1', 'padlock_bio_nonce', $stamp)->hashes->[0];
	return 0 unless $seen && $seen->{'server_time'} && $seen->{'server_time'} > &subs::rightNow() - $ttl;
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'padlock_bio_nonce', $stamp);
	return 1;
}

# A payment is confirmed by the current device's enrolled biometric key: the
# phone signs a verify challenge, the same proof used before replacing a
# fingerprint. A device with no key has no biometric to ask for, so the signed-in
# citizen is the fallback there; the panel says which path it will use.
sub biometric_payment_confirmed {
	my ($c) = @_;
	my $device_uuid = $c->session('device_uuid') || '';
	my $device = $device_uuid
		? &subs::db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0]
		: undef;
	# A device with no key of its own asks a fingerprinted device in the house.
	# If the house has none, the signed-in citizen is the fallback.
	unless ($device && $device->{'bio_pubkey'}) {
		my $other = &house_bio_device($device_uuid);
		return { ok => 1, enrolled => 0, no_bio => 1 } unless $other;
		return { ok => 0, enrolled => 0, other => 1, other_name => $other->{'name'} || '' };
	}
	my $nonce = $c->param('bio_nonce') || '';
	my $signature = $c->param('bio_signature') || '';
	return { ok => 0, enrolled => 1, self => 1 } unless length $nonce && length $signature;
	return { ok => 0, enrolled => 1, self => 1 } unless &biometric_nonce_take('verify', $device_uuid, $nonce, 600000);
	my $msg = join("\n", 'padlock-bio-verify', $device_uuid, $nonce);
	return { ok => &subs::ecdsa_verify($device->{'bio_pubkey'}, $msg, $signature) ? 1 : 0, enrolled => 1, self => 1 };
}

sub padlock_time_extender($c) {
#	&subs::subprocessor(sub {
		my $session_timeout = $c->session('pl_time');
		my $server_time = &subs::rightNow();
		my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes;
		my $device = $c->session('device_uuid') || '';
		my $device_until = $device ? &padlock_device_until($device) : 0;
		if ($c->session('authentication') eq 'approved' && scalar @{$padlock} > 0 && (($device_until && $device_until > $server_time) || $session_timeout > $server_time)) {
			my $attempts = &subs::note_decrypter(&subs::session_suds($c), &subs::setting_grabber({ app => '__president', setting => 'padlock_pulls' }));
			if ($attempts < 5) {
				my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
				$activity_timeout = abs &subs::time_abbrev_translator($activity_timeout);
				my $new_time = $server_time + $activity_timeout;
				if ($device_until && $device_until > $server_time) {
					&padlock_device_set_time($device, $new_time);
					$c->session('pl_time' => $new_time);
				}
				else {
					my $padlock_time = &padlock_time_value(&subs::suds_grabber(), &subs::setting_grabber({ app => '__president', setting => 'pl_time' }) );
					if ($padlock_time > $server_time) {
						&subs::setting_setter({ app => '__president', setting => 'pl_time', value => $new_time });
						$c->session('pl_time' => $new_time);
					}
				}
			}
		}
#	}, { name => 'padlock time extender' });
}

# A self-contained page command for a phone-side send: the new bundle's helper
# when it is there, the bridge when the bundle is old but the app is new, and
# the phone's own termux when neither has landed yet - so a message always goes
# out during the hand-over from termux-sms-send.
sub sms_send_command($digits, $message) {
	# A command object, not source: the browser router runs jawnSmsSend (or the
	# bridge/termux fallback) from its table.
	return {
		cmd => 'smsSend',
		args => [ &subs::json_chars($digits), &subs::json_chars($message) ]
	};
}

sub sms_mms_command($digits, $text, $parts, $jawn_uuid) {
	# The browser router calls jawnSmsMms and reports its own outcome through
	# window.__jawnSmsResult (see 00_console_router.js).
	return {
		cmd => 'smsMms',
		args => [
			&subs::json_chars($digits),
			&subs::json_chars($text),
			&subs::json_chars($parts),
			&subs::json_chars($jawn_uuid || '')
		]
	};
}

# This machine's radio. termux-telephony-deviceinfo is the same source the
# Phone app trusts: a phone answers phone_type=gsm/cdma with a ready SIM, a
# wifi-only tablet answers phone_type=none. Which is why a caller that needs a
# radio asks the bridge rather than the platform name.
sub telephony_status() {
	my $state = { telephony => 0, phone_type => 'none', sim_state => '', network_type => '' };
	return $state unless &subs::device_setter() eq 'mobile';
	my $info = &subs::device_call('telephony.deviceinfo') || {};
	my $type = lc($info->{'phone_type'} || 'none');
	my $sim = lc($info->{'sim_state'} || '');
	$state->{'phone_type'} = $type;
	$state->{'sim_state'} = $sim;
	$state->{'network_type'} = $info->{'network_type'} || '';
	$state->{'telephony'} = (($type ne '' && $type ne 'none') && $sim eq 'ready') ? 1 : 0;
	return $state;
}

# A peer's radio, asked before an MMS is handed over: a laptop with a phone and
# a wifi tablet must not send the picture to the tablet and call it a phone.
sub peer_telephony($ru) {
	return undef unless $ru && $ru->{'ua'} && $ru->{'manager'};
	my $tx = eval { $ru->{'ua'}->inactivity_timeout(10)->get($ru->{'manager'} . '/manager/telephony') };
	return undef unless $tx && !$tx->error && $tx->res->is_success;
	my $info = eval { return decode_json $tx->res->body };
	return (ref $info eq 'HASH') ? $info : undef;
}

# The app's FileProvider is rooted at getFilesDir() (/data/user/0/...), while
# subs::home() and TermuxConstants say /data/data/.... Hand the bridge the
# provider's own spelling so getUriForFile finds the file; a path outside that
# root is what made the share() hand-off fail.
sub bridge_path($path) {
	my $data = $ENV{'TERMUX_APP__DATA_DIR'};
	return $path unless $data && $path =~ m{^/data/data/[^/]+/files(?:/|$)};
	$path =~ s{^/data/data/[^/]+/files}{$data/files};
	return $path;
}

# MMS carriers are happiest below about a megabyte; an original photo can be
# several. A copy is shrunk to fit (and auto-oriented), leaving the filed
# original alone. No ImageMagick, or a failure, keeps the original for the
# bridge's own Bitmap compression to handle.
sub mms_part_prepare($path, $mime) {
	return ($path, $mime) unless $path && -e $path;
	return ($path, $mime) unless ($mime || '') =~ m{^image/}i;
	my $size = -s $path || 0;
	return ($path, $mime) if $size <= 0 || $size <= (320 * 1024);
	my $dir = &subs::home('~/.shots/sms_parts');
	`mkdir -p "$dir"` unless -e $dir;
	my $out = $dir . '/' . &subs::random_string_creator(8) . '-mms.jpg';
	my $converted = &subs::image_bridge_convert($path, $out, max_width => 1280, max_height => 960, quality => 82, auto_orient => 1);
	my $rc = defined $converted ? 0 : system('magick', $path, '-auto-orient', '-strip', '-resize', '1280x960>', '-quality', '82', $out);
	return (($rc == 0 && -e $out && (-s $out) > 0) ? ($out, 'image/jpeg') : ($path, $mime));
}

sub sms_message_send($digits,$message) {
	$digits =~ s/\S\d(?=\d{10})//;
	my $via = 'relay';
	if (&subs::device_setter() eq 'mobile') {
		if ( $digits ) {
			# the app's own bridge sends it natively (SmsManager): the page calls
			# window.JawnSms.send, or falls back to termux-sms-send while the app
			# that carries the bridge has not landed. No page open: termux, since
			# there is no WebView to bridge through.
			my $tabs = &subs::db_query("select browser_tab_id from websockets where app = ?", 'tab')->hashes;
			if (scalar @{$tabs} > 0) {
				&Websocket::send('tab', { console => &sms_send_command($digits, $message) });
				$via = 'bridge';
			}
			else {
				# No page open to bridge through, so the tree asks the device itself.
				my $native = &subs::device_call('sms.send', { number => $digits, message => $message });
				$via = $native ? 'bridge' : 'none';
			}
		}
	}
	else {
		&subs::subprocessor(sub {
	    Mojo::IOLoop->reset;

			my $remote_machines = &subs::db_query('select * from remote_machines where connection=? and device=?', 'active', 'mobile')->hashes;
			foreach my $rm ( @{$remote_machines} ) {
				$rm = &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
				my $wire = $message;
				utf8::encode($wire) if utf8::is_utf8($wire);
				my $res = $rm->{'ua'}->post($rm->{'manager'} . '/manager/sms/message?digits=' . $digits . '&message=' . uri_encode($wire));
				if (eval {decode_json $res}) {
					next;
				}
			}
		}, { name => 'sms msg send' });
	}
	return ($digits,$message,$via);
}

# The house encrypts files at rest, renaming them to random .enc paths; an
# attachment carried on a message names its file by uuid, so the current paths
# are read from the filing the upload made, not from the snapshot the page sent.
# Returns (f, thumb, encryption_standard) - f is the current path, possibly .enc.
sub attachment_resolve($att) {
	my $fu = $att->{'uuid'} || '';
	my $f = $att->{'f'} || '';
	return ($f, $att->{'thumb'}, undef) if $f && -e $f;
	return (undef, undef, undef) unless $fu;
	my $row = &subs::db_query('select * from appointments where file like ? limit 1', '%' . $fu . '%')->hashes->[0];
	return (undef, undef, undef) unless $row;
	my $files = eval { return decode_json $row->{'file'} } || [];
	$files = [ $files ] if eval { $files->{'f'} };
	my ($entry) = grep { ($_->{'uuid'} || '') eq $fu } @{$files};
	return (undef, undef, undef) unless $entry;
	return ($entry->{'f'}, $entry->{'thumb'}, $row->{'encryption_standard'});
}

# An attachment's file as plain bytes on disk: encrypted at rest, so a copy is
# decrypted to the house's sms_parts drawer and that path is returned.
sub attachment_plain_path($att) {
	my ($f, undef, $standard) = &attachment_resolve($att);
	return undef unless $f && -e $f;
	return $f unless $f =~ /\.enc$/;
	my $dir = &subs::home('~/.shots/sms_parts');
	`mkdir -p $dir` unless -e $dir;
	my $name = $att->{'name'} || 'part';
	$name =~ s{[^A-Za-z0-9._-]}{_}g;
	my $plain = $dir . '/' . &subs::random_string_creator(8) . '-' . $name;
	$standard ||= &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	my $secret = &subs::suds_grabber();
	&subs::openssl_file_crypt('d', $standard, $secret, $f, $plain, 0, 1);
	return (-e $plain) ? $plain : undef;
}

# The house row a message was filed as before it touched the sms stack wears
# the system's own identity once the phone has filed the same message: the
# system thread keeps the sent copy, and this row IS that message here, so the
# poll, a re-read and every other machine see one message rather than two. The
# system's date also becomes the row's time, so a poll matches it exactly.
sub sms_mms_row_link($mms_id, $mms_date) {
	my %set = (message_id => 'mms:' . $mms_id, server_time => &subs::rightNow());
	$set{'timestamp'} = $mms_date * 1000 if $mms_date && $mms_date =~ /^\d+$/;
	return \%set;
}

# An attachment on the sms road: on the phone the parts are already local files
# the bridge reads; anywhere else they are read, base64'd and relayed to the
# phone's /manager/sms/mms. A phone is found by asking its radio, not by taking
# the first mobile peer (the house may also hold a wifi-only tablet).
sub sms_mms_relay($digits, $text, $attachments, $jawn_uuid) {
	my $parts = [];
	foreach my $att ( @{$attachments || []} ) {
		my $f = &attachment_plain_path($att);
		my $mime = $att->{'mime'} || $att->{'type'} || 'image/jpeg';
		next unless $f;
		($f, $mime) = &mms_part_prepare($f, $mime);
		if (&subs::device_setter() eq 'mobile') {
			push @{$parts}, { path => &bridge_path($f), mime => $mime };
		}
		else {
			next unless -e $f;
			my $size = -s $f;
			next if $size <= 0 || $size > (8 * 1024 * 1024);
			open my $fh, '<', $f or next;
			binmode $fh;
			local $/;
			my $bytes = <$fh>;
			close $fh;
			my ($name) = $f =~ m{([^/]+)$};
			push @{$parts}, { name => $name || 'part', mime => $mime, data => encode_base64($bytes) };
		}
	}
	return { ok => 0, error => 'no parts' } unless scalar @{$parts} > 0;
	if (&subs::device_setter() eq 'mobile') {
		# a wifi tablet can read a picture but has no radio to carry it
		return { ok => 0, error => 'this device has no telephony' } unless &telephony_status()->{'telephony'};
		my $tabs = &subs::db_query("select browser_tab_id from websockets where app = ?", 'tab')->hashes;
		return { ok => 0, error => 'no app page open' } unless scalar @{$tabs} > 0;
		&Websocket::send('tab', { console => &sms_mms_command($digits, $text, $parts, $jawn_uuid) });
		return { ok => 1, via => 'bridge' };
	}
	my $remote_machines = &subs::db_query('select * from remote_machines where connection=? and device=?', 'active', 'mobile')->hashes;
	# confirmed radios first; a peer that will not answer the check stays a
	# candidate rather than silently disabling a working phone on an old build
	my ( @phones, @unknown );
	foreach my $rm ( @{$remote_machines} ) {
		my $ru = eval { &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm }) };
		next unless $ru && $ru->{'ua'} && $ru->{'manager'};
		my $tel = &peer_telephony($ru);
		if ($tel && defined $tel->{'telephony'}) {
			push @phones, [ $rm, $ru ] if $tel->{'telephony'};
		}
		else {
			push @unknown, [ $rm, $ru ];
		}
	}
	my $last = 'no phone reached';
	foreach my $pair ( @phones, @unknown ) {
		my ($rm, $ru) = @{$pair};
		# parentheses matter here: `parts => encode_json $parts, jawn_uuid => ...`
		# hands the uuid to encode_json as another argument, so the relay quietly
		# sent no jawn_uuid and the house row never learned its system id
		my %form = ( digits => $digits, subject => $text, parts => encode_json($parts), jawn_uuid => $jawn_uuid );
		my $tx = eval { $ru->{'ua'}->inactivity_timeout(30)->post($ru->{'manager'} . '/manager/sms/mms', form => \%form) };
		if (!$tx) { $last = 'no answer'; next; }
		if ($tx->error) { $last = $tx->error->{'message'} || 'no answer'; next; }
		my $answer = eval { return decode_json $tx->res->body };
		if ($answer && $answer->{'ok'}) {
			return { ok => 1, via => 'relay', phone => ($rm->{'hostname'} || $rm->{'name'} || $rm->{'ip'}), parts => ($answer->{'parts'} || 0), mms_id => ($answer->{'mms_id'} || 0), mms_date => ($answer->{'mms_date'} || 0), mms_thread => ($answer->{'mms_thread'} || 0) };
		}
		$last = (ref $answer eq 'HASH' && $answer->{'error'}) ? $answer->{'error'} : ('HTTP ' . $tx->res->code);
	}
	return { ok => 0, error => $last };
};

# ---------------------------------------------------------------------------
# LoRaWAN: the Chat app's radio mode.
#
# The T-Deck carries an SX1262 and RadioLib's LoRaWANNode; JawnOS keeps the
# network credentials, pushes them to the deck that is on the LAN, and offers a
# webhook a network server (TTN, ChirpStack, Helium) can post uplinks to. The
# message itself is filed on the `lora` contact, the same way sms is filed on a
# number and a ticket on its uuid, so the conversation survives a restart.
# ---------------------------------------------------------------------------
sub lorawan_settings {
	my %s;
	foreach my $k (qw/enabled band subband join_eui dev_eui app_key fport confirmed webhook_token/) {
		my $v = &subs::setting_grabber({ app => 'mail', setting => 'lorawan_' . $k, device => 'all' });
		$s{$k} = defined $v ? $v : '';
	}
	$s{'band'} = 'EU433' unless length $s{'band'};
	$s{'subband'} = 1 unless $s{'subband'} =~ /^\d+$/ && $s{'subband'} >= 1 && $s{'subband'} <= 8;
	$s{'fport'} = 1 unless $s{'fport'} =~ /^\d+$/ && $s{'fport'} >= 1 && $s{'fport'} <= 223;
	$s{'enabled'} = 'off' unless $s{'enabled'} eq 'on';
	$s{'confirmed'} = 'off' unless $s{'confirmed'} eq 'on';
	unless (length $s{'webhook_token'}) {
		$s{'webhook_token'} = &subs::random_string_creator(40);
		&subs::setting_setter({ app => 'mail', setting => 'lorawan_webhook_token', value => $s{'webhook_token'}, device => 'all' });
	}
	return \%s;
}

sub lorawan_public_settings($c) {
	my $s = &lorawan_settings();
	my $webhook = '';
	if ($c) {
		$webhook = eval { $c->url_for('/watch/lorawan')->query(token => $s->{'webhook_token'})->to_abs->to_string } || '';
	}
	return {
		enabled => $s->{'enabled'},
		band => $s->{'band'},
		subband => $s->{'subband'},
		join_eui => $s->{'join_eui'},
		dev_eui => $s->{'dev_eui'},
		fport => $s->{'fport'},
		confirmed => $s->{'confirmed'},
		has_app_key => (length $s->{'app_key'} ? 1 : 0),
		webhook_url => $webhook,
	};
}

1;
