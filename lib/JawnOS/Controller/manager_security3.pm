package Manager;

# manager_security3: route actions moved out of Manager.pl, one sub per route so a
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

# The peer half of "send the unlock page": the machine that holds the lock hands
# the message to every peer, and each one broadcasts it to its own screens. The
# caller is authenticated by its pinned peer signature, and relay_id lets the
# message walk a multi-hop mesh without looping.
# POST /manager/security/padlock_key_show_peer
sub action_40363 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) {
		$log->info('padlock: key show refused from ' . ($signatorial || '?') . ' at ' . ($c->tx->remote_address || '?'));
		return $c->rendered(403);
	}
	my $mode = $c->param('mode') || 'locker';
	$mode = 'locker' unless $mode =~ /^(?:locker|gallery|music|folders|private|go)$/;
	my $target = $c->param('target') || '';
	$target = '' unless $target =~ /^[A-Za-z0-9]{8,64}$/;
	my $show = $c->param('show') ? 1 : 0;
	my $prompt = $c->param('prompt') ? 1 : 0;
	my $request_id = $c->param('request_id') || '';
	$request_id = '' unless $request_id =~ /^[A-Za-z0-9]{8,64}$/;
	my $device_name = $c->param('device_name') || '';
	$device_name =~ s/[\r\n\t]//g;
	$device_name = substr($device_name, 0, 120);
	my $source_device = $c->param('source_device') || '';
	$source_device = '' unless $source_device =~ /^[A-Za-z0-9]{8,64}$/;
	# the machine that actually holds the lock, not the peer relaying its prompt
	my $source = $c->param('source') || $signatorial;
	$source = '' unless $source =~ /^[A-Za-z0-9]{8,64}$/;
	my $source_hostname = $c->param('source_hostname') || ($rm->{'hostname'} || '');
	$source_hostname =~ s/[\r\n\t]//g;
	$source_hostname = substr($source_hostname, 0, 120);
	# keep the request readable on this machine too: a phone that is asleep
	# when the button is pressed finds it in padlock_state on its next wake
	if ($prompt) {
		$request_id = &padlock_request_store($target, $mode, $source, $request_id || undef, $device_name, $source_device, $source_hostname);
		$log->info('padlock: prompt received from ' . ($source_hostname || $signatorial) . ' for ' . ($target || 'house') . ' id=' . $request_id);
	}
	&Websocket::send('server', { padlock_key_show => 1, prompt => $prompt, request_id => $request_id, device_name => $device_name, source_device => $source_device, source => $source, source_hostname => $source_hostname, house => (($target || '') eq '' ? 1 : 0), mode => $mode, target => $target, show => $show, timestamp => &subs::rightNow() });
	my $relay_id = $c->param('relay_id') || '';
	if ($relay_id) {
		my $self = &subs::signatorial_designer();
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			&remote_relay_request($c, {
				override => 'manual',
				url => '/manager/security/padlock_key_show_peer',
				type => 'post',
				dissemination => 'yes',
				params => {
					signatorial => $self,
					mode => $mode,
					target => $target,
					show => $show,
					prompt => $prompt,
					request_id => $request_id,
					device_name => $device_name,
					source_device => $source_device,
					source_hostname => $source_hostname,
					source => $source,
					house => (($target || '') eq '' ? 1 : 0),
					dissemination => 'yes',
					source_signatorial => $self,
					relay_from => $self,
					relay_id => $relay_id,
				},
			});
		}, { name => 'padlock key show relay onward' });
	}
	$c->render(json => { ok => 1 });
}

# GET /manager/security/padlock_state
sub action_40429 {
	my $c = shift;
	my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes->[0];
	my $locks = &subs::db_select('security', undef, { level => 'padlock_device' })->hashes || [];
	my @targets;
	foreach my $lock ( @{$locks} ) {
		my $d = &subs::db_select('paired_devices', undef, { uuid => $lock->{'uuid'} })->hashes->[0];
		push @targets, { uuid => $lock->{'uuid'}, name => ($d ? $d->{'name'} : 'Unknown device') };
	}
	# A page may carry its device in localStorage even when the session cookie
	# has lost device_uuid (a cookieless webview wake, or a ticket that signed in
	# without one). Accept a parameter only for a paired, active device, and bind
	# it to the session: the gate and every lock route read the session, so the
	# next page load can no longer look like an unidentified screen (which the
	# gate treated as an open house).
	my $session_du = $c->session('device_uuid') || '';
	my $param_du = $c->param('device_uuid') || '';
	my $du = '';
	if ($session_du && $session_du =~ /^[A-Za-z0-9]{8,64}$/
		&& &subs::db_select('paired_devices', undef, { uuid => $session_du, status => 'active' })->hashes->[0]) {
		# An established session keeps its own device: a locked screen must not
		# be able to name an unlocked device and step out of its own lock.
		$du = $session_du;
	}
	elsif ($param_du && $param_du =~ /^[A-Za-z0-9]{8,64}$/
		&& &subs::db_select('paired_devices', undef, { uuid => $param_du, status => 'active' })->hashes->[0]) {
		# A session that lost its device (a cookieless webview wake, or a ticket
		# signed in without one) adopts the page's paired device once.
		$du = $param_du;
		$c->session('device_uuid' => $du);
	}
	# The page's own device is the one that carries the fingerprint (a re-pair,
	# or an app session made before pairing). Adopt it unless doing so would
	# open a locked screen by naming a device that is already open: a locked
	# session may adopt a device that is also locked (adding restriction), but
	# never one with its own open timer.
	if ($param_du && $param_du ne $du && $param_du =~ /^[A-Za-z0-9]{8,64}$/
		&& &subs::db_select('paired_devices', undef, { uuid => $param_du, status => 'active' })->hashes->[0]) {
		my $session_locked = $du ? (&padlock_locked_now($c, $du) ? 1 : 0) : (&padlock_global_locked($c) ? 1 : 0);
		my $param_locked = &padlock_locked_now($c, $param_du) ? 1 : 0;
		if ($param_locked || !$session_locked) {
			$du = $param_du;
			$c->session('device_uuid' => $du);
		}
	}
	my $request = &padlock_request_get();
	$c->render(json => {
		ok => 1,
		has_padlock => ($padlock ? 1 : 0),
		locked => (&padlock_locked_now($c, $du) ? 1 : 0),
		global_locked => (&padlock_global_locked($c) ? 1 : 0),
		gate => &padlock_gate_mode(),
		device => $du,
		device_until => (&padlock_device_until($du) || 0),
		biometric_enrolled => (&biometric_enrolled_for($du) ? 1 : 0),
		targets => \@targets,
		request => $request
	});
}

# GET /manager/security/padlock_key
sub action_40488 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		return $c->render(template => 'guest_layouts/denial', message => 'Sign in before showing the phone key.');
	}
	my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes->[0];
	$c->render(template => 'padlock_key', layout => 'padlock_key', has_padlock => ($padlock ? 1 : 0));
}

# GET /manager/security/padlock_key/frame
sub action_40496 {
	my $c = shift;
	return $c->render(json => { error => 'the camera key is disabled' });
}

# GET /manager/security/padlock_key/active
sub action_40500 {
	my $c = shift;
	return $c->render(json => { watching => 0, disabled => 1 });
}

1;
