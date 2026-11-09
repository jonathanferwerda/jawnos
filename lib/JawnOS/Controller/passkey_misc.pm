package Manager;

# passkey_misc: route actions moved out of Manager.pl, one sub per route so a
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

# GET /passkey
sub action_9089 {
	my $c = shift;
	my $token = $c->param('t') || '';
	my $p = &webauthn::enroll_peek($token);
	my $house = &webauthn::rp_id();
	my $house_url = '';
	$house_url = &webauthn::house_link_base($c) if $p && length $house;
	$c->render(
		template => 'passkey',
		layout => undef,
		token => ($p ? $token : ''),
		valid => ($p ? 1 : 0),
		person_name => ($p ? ($p->{'name'} || '') : ''),
		house => $house,
		port => ($ENV{'PORT_DOCK'} || 3000),
		house_url => $house_url,
	);
}

# POST /passkey/begin
sub action_9107 {
	my $c = shift;
	my $token = $c->param('t') || '';
	my $p = &webauthn::enroll_peek($token);
	return $c->render(json => { ok => 0, error => 'this link has expired' }) unless $p;
	return $c->render(json => { ok => 0, error => 'that person is no longer active' }) unless &subs::person_active($p->{'person_uuid'});
	my $rp = &webauthn::rp_id();
	return $c->render(json => { ok => 0, error => 'set the house domain first' }) unless length $rp;
	my $challenge = &webauthn::challenge_put('enroll', { person_uuid => $p->{'person_uuid'}, token => $token });
	my @exclude = map { { type => 'public-key', id => $_->{'id'}, transports => [ qw(usb nfc ble) ] } }
		grep { ($_->{'person_uuid'} || '') eq $p->{'person_uuid'} } @{ &webauthn::credentials() };
	$c->render(json => {
		ok => 1,
		publicKey => {
			rp => { name => 'JawnOS', id => $rp },
			user => { id => &webauthn::user_handle($p->{'person_uuid'}), name => $p->{'name'}, displayName => $p->{'name'} },
			challenge => $challenge,
			pubKeyCredParams => [ { type => 'public-key', alg => -7 }, { type => 'public-key', alg => -8 } ],
			timeout => 300000,
			attestation => 'none',
			authenticatorSelection => { authenticatorAttachment => 'cross-platform', residentKey => 'preferred', userVerification => 'preferred' },
			excludeCredentials => \@exclude,
		},
	});
}

# POST /passkey/finish
sub action_9132 {
	my $c = shift;
	my $token = $c->param('t') || '';
	my $p = &webauthn::enroll_peek($token);
	return $c->render(json => { ok => 0, error => 'this link has expired' }) unless $p;
	return $c->render(json => { ok => 0, error => 'that person is no longer active' }) unless &subs::person_active($p->{'person_uuid'});
	my $cd = $c->param('client_data') || '';
	my $jd = eval { decode_json(&webauthn::b64u_decode($cd)) } || {};
	my $challenge = $jd->{'challenge'} || '';
	my $payload = &webauthn::challenge_take('enroll', $challenge);
	return $c->render(json => { ok => 0, error => 'the challenge expired - try again' })
		unless $payload && ($payload->{'token'} || '') eq $token && ($payload->{'person_uuid'} || '') eq $p->{'person_uuid'};
	my ($reg, $err) = &webauthn::verify_registration($cd, $c->param('attestation'), $challenge, &webauthn::origin_of($c));
	return $c->render(json => { ok => 0, error => $err }) unless $reg;
	my $transports = $c->param('transports') || '';
	return $c->render(json => { ok => 0, error => 'that was this device\'s own reader or a phone, not a security key - plug in a USB key and try again' })
		if &webauthn::platform_transport_only($transports);
	my $name = $c->param('name') || 'Passkey';
	$name =~ s/^\s+|\s+$//g;
	$name = 'Passkey' unless length $name;
	$name = substr($name, 0, 60);
	my $list = &webauthn::credentials();
	@{$list} = grep { ($_->{'id'} || '') ne $reg->{'id'} } @{$list};
	push @{$list}, {
		id          => $reg->{'id'},
		key         => $reg->{'key'},
		person_uuid => $p->{'person_uuid'},
		person_name => $p->{'name'},
		name        => $name,
		sign_count  => $reg->{'sign_count'},
		aaguid      => $reg->{'aaguid'},
		transports  => $transports,
		created     => &subs::rightNow(),
		last_used   => 0,
	};
	&webauthn::credentials_store($list);
	&webauthn::enroll_take($token);
	$log->info('webauthn: enrolled a passkey for ' . ($p->{'name'} || '?') . ' from a browser link');
	$c->render(json => { ok => 1, person => $p->{'name'} });
}

1;
