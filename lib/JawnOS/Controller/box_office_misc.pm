package Manager;

# box_office_misc: route actions moved out of Manager.pl, one sub per route so a
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

# ANY /box_office/ticket_request
sub action_14132 {
	my $c = shift;
	my $call = $c->param('call');
	my $privilege = $c->param('privilege');
	my $team = $c->param('team');
	my $club = $c->param('club');
	my $community = $c->param('community');
	my $timestamp = $c->param('timestamp');
	if ($call eq 'form') {
		my $content = $c->render_to_string(
			template => 'store/ticket_request',
			error => 0
		);
		$c->render(json => { content => $content });
	}
	elsif ($call eq 'privilege') {
		my $content = $c->render_to_string(
			template => 'store/ticket_request_privilege',
			privilege => $privilege,
			team => $team,
			club => $club,
			community => $community
		);
		$c->render(json => { content => $content });
	}
	elsif ($call eq 'submit') {
		my $data = eval { return decode_json $c->param('data') } || {};
		# GDPR: no request is stored until the person has acknowledged the
		# privacy notice. The acknowledgement travels with the request so the
		# house can show how and when it was given.
		if (($data->{'consent'} // '') ne 'on') {
			my $content = $c->render_to_string(
				template => 'store/ticket_request',
				error => 1
			);
			$c->render(json => { status => 'error', html => $content });
			return;
		}
		my $info = {
			name => &subs::unformat_name($data->{'name'} || ''),
			email => &ticket_contact_clean('email', $data->{'email'}),
			phone => &ticket_contact_clean('phone', $data->{'phone'}),
			description => substr($data->{'description'} || '', 0, 1000),
			privilege => 'guest',
			consent => 1,
			consent_at => &subs::rightNow(),
			team => $data->{'team'},
			club => $data->{'club'},
			community => $data->{'community'}
		};
		# A crest is a claim, not a permission: the code is verified here so an
		# unreadable or tampered one never reaches the desk, and the verified
		# record rides with the request. It does not approve anything.
		my $crest_code = $data->{'crest_code'} || '';
		$crest_code =~ s/^\s+|\s+$//g;
		my $crest_record;
		if (length $crest_code) {
			if (length $crest_code > 4000) {
				my $content = $c->render_to_string(template => 'store/ticket_request', error => 0, crest_error => 1);
				$c->render(json => { status => 'error', html => $content });
				return;
			}
			$crest_record = &subs::crest_code_parse($crest_code);
			unless ($crest_record && &subs::crest_verify_record($crest_record)) {
				$c->render(json => { status => 'error', html => $c->render_to_string(template => 'store/ticket_request', error => 0, crest_error => 1) });
				return;
			}
			my $own_crest = &subs::crest_record_read();
			if (($own_crest->{'uuid'} || '') ne '' && ($crest_record->{'uuid'} || '') eq $own_crest->{'uuid'}) {
				$c->render(json => { status => 'error', html => $c->render_to_string(template => 'store/ticket_request', error => 0, crest_error => 2) });
				return;
			}
			$info->{'crest'} = {
				uuid => $crest_record->{'uuid'} || '',
				name => $crest_record->{'name'} || '',
				fingerprint => $crest_record->{'fingerprint'} || '',
				pubkey => $crest_record->{'pubkey'} || '',
				version => $crest_record->{'version'} || 1,
				issued => $crest_record->{'issued'} || '',
				sig => $crest_record->{'sig'} || '',
			};
		}
		my $browser_tab_id = $c->param('browser_tab_id') || '';
		my $policy = &ticket_policy();
		# the door's rules: a blacklisted identifier and a flood both get the
		# queued answer, so the form never says who is on the list
		if (&ticket_blacklist_match($info) || !&ticket_request_allowed($c)) {
			$log->info('ticket request dropped: ' . $info->{'name'} . ' (' . $c->tx->remote_address . ')');
			$c->render(json => { status => 'pending', html => &ticket_request_pending_html() });
			return;
		}
		my $crest_for_request = $crest_record ? ($crest_record->{'uuid'} || '') : '';
		my $request = {
			uuid => &subs::random_string_creator(35),
			name => $info->{'name'},
			timestamp => $timestamp || &subs::rightNow(),
			server_time => &subs::rightNow(),
			status => 'request',
			privilege => 'guest',
			browser_tab_id => $browser_tab_id,
			ip => $c->tx->remote_address,
			information => encode_json $info,
			crest_uuid => $crest_for_request,
		};
		if ($policy->{'issue_guest_on_request'}) {
			# the house keeps the door open: a guest ticket is minted on the spot
			my $minted = &ticket_request_mint($c, $request, 'guest', $policy->{'guest_warranty'});
			if ($minted) {
				&subs::db_insert('tickets', $minted);
				&subs::db_update('tickets', { crest_uuid => $crest_for_request }, { uuid => $minted->{'uuid'} }) if length $crest_for_request;
				$c->render(json => { status => 'approved', url => $minted->{'url'} });
				return;
			}
		}
		&subs::db_insert('tickets', $request);
		# The crest column is written explicitly: the request row's own identity
		# must carry it even when the insert is handed a hash assembled by an
		# older code path.
		&subs::db_update('tickets', { crest_uuid => $crest_for_request }, { uuid => $request->{'uuid'} }) if length $crest_for_request;
		&ticket_request_notify($c, $request, $info);
		$c->render(json => { status => 'pending', html => &ticket_request_pending_html() });
	}
	elsif ($call eq 'check') {
		# the waiting page asks whether its ticket has been granted: the tab's
		# own id is the claim, and only a fresh ticket answers it
		my $browser_tab_id = $c->param('browser_tab_id') || '';
		my $ticket = $browser_tab_id ? &subs::db_query('select url from tickets where browser_tab_id=? and status=? and server_time > ? order by server_time desc limit 1', $browser_tab_id, 'active', &subs::rightNow() - 1800000)->hashes->[0] : undef;
		if ($ticket->{'url'}) {
			$c->render(json => { status => 'approved', url => $ticket->{'url'} });
		}
		else {
			$c->render(json => { status => 'pending' });
		}
	}
	else {
		$c->render(template => 'guest_layouts/denial');
	}
}

# GET /box_office/:uuid
sub action_14382 {
	my $c = shift;
	my $uuid = $c->stash('uuid');
	my $secret = $c->param('s');
	my $ip = $c->tx->remote_address;
	my $server_time = &subs::rightNow();
	my $timestamp = $c->param('timestamp') || $server_time;
	my ($db,$database) = &subs::database_grabber();

	my $base_host = $c->req->url->base->host;
	my $public_host = &subs::public_origin_host();
	my $local_host = &subs::local_domain();

	if ($base_host ne $config->{'domain'} && $base_host ne $public_host && $base_host ne $local_host && $ip ne $c->tx->local_address) {
		$c->render(template => 'guest_layouts/denial');
		return;
	}

	my $base_url = 'https://' . $base_host . ':' . $ENV{PORT_AHOY};
	unless ($db) {
		$c->redirect_to($base_url . '/manager');
		return;
	}
	my $tick = &subs::db_query('select * from tickets where uuid=?', $uuid);
	my $ticke = $tick->hashes;
	unless (scalar @{$ticke} > 0) {
		$c->redirect_to($base_url . '/manager');
		return;
	}

	my $ticket = $ticke->[0];
	my $access_log = eval { return decode_json $ticket->{'access_log'} } || [];
	my $access = { server_time => $server_time, status => 'denial', ip => $ip };

	my $v = $ticket->{'verification'};
	my $ver = url_unescape `echo "$secret" | base64 --decode`;
	my $verification = &subs::note_decrypter($ticket->{'password'}, $ver) ;
	my $vrai = eval { return decode_json $verification } || {};
	unless ($vrai->{'p'}) {
		$c->redirect_to($base_url . '/manager');
		return;
	}
	# the ticket's token is the credential; a legacy row may still carry a sealed
	# copy of the key, adopted only when this machine has none - otherwise the
	# machine's vault is the key and nothing here touches it
	my $genuine = (!$vrai->{'uuid'} || $vrai->{'uuid'} eq $ticket->{'uuid'}) ? 1 : 0;
	my $suds;
	if ($ticket->{'suds'}) {
		$suds = &subs::note_decrypter($vrai->{'p'}, $ticket->{'suds'});
		chomp $suds if $suds;
		$suds = undef unless $suds && &subs::suds_current($suds);
	}
	$suds ||= eval { &subs::suds_grabber() };

	if (($genuine && $suds) && $ticket->{'privilege'} && $ticket->{'status'} eq 'active') {
		&update_database($c);
		my $d = { app => 'customs', role => 'citizen', title => 'Your Majesty', message => &subs::format_name($ticket->{'privilege'}) . ': ' . &subs::format_name($ticket->{'name'}), image => "/images/make believe/crown.png" };
		unless ($c->req->url->base->port eq 3000) {
			&subs::say_it($ticket->{'name'});
			&notification_sender($d,$database);
		}
		if ($ticket->{'privilege'} eq 'blacklisted') {
			# blacklisted is the deny: the denial page is the whole answer (no
			# redirect after it), and the session itself is marked denial, so these
			# cookies meet that page on every later request - public pages and
			# static assets included - and carry no usable credential
			$c->session('authentication' => 'denial');
			$c->session('privilege' => 'blacklisted');
			$c->session('suds_id' => undef);
			$c->session('database' => undef);
			$c->render(template => 'guest_layouts/denial');
		}
		else {
			$c->session('role' => $ticket->{'privilege'});
			my $warranty = &subs::ago_calc(&subs::setting_grabber({ 'app' => $ticket->{'name'}, setting => 'warranty' }), $timestamp);
			#&subs::db_insert('appointments',{ uuid => &subs::random_string_creator(40), app => $ticket->{'name'}, warranty => $warranty, type => "entry", timestamp => $timestamp, server_time => $server_time });
			$c->session('database' => $database);
			$c->session('authentication' => 'approved');
			&subs::vault_seed($suds);
			$c->session('suds_id' => &subs::suds_id($suds));
			$c->session('server_time' => $server_time);
			$c->session('warranty' => $ticket->{'warranty'});
			$c->session('source' => 'ticket');
			# A ticket minted by a linked machine over the signed peer rail is
			# that peer's vouch for this browser: it may pass the app gate as
			# the peer, so a headless machine needs no local app key. A ticket
			# minted at a box office carries no peer_signatorial and stays local.
			if (($ticket->{'peer_signatorial'} || '') ne '') {
				$c->session('peer' => 1);
				$c->session('peer_signatorial' => $ticket->{'peer_signatorial'});
			}
			else {
				$c->session('peer' => undef);
				$c->session('peer_signatorial' => undef);
			}
			$c->session('ticket_uuid' => $ticket->{'uuid'});
			# the ticket admits a person, not just a link: the first login mints
			# the person and writes it back, so the same ticket keeps them
			my $ticket_person = eval { &subs::person_for_ticket($ticket) };
			$c->session('person_uuid' => ($ticket_person ? $ticket_person->{'uuid'} : undef));
			$c->session('name' => $ticket->{'name'});
			$c->session('privilege' => $ticket->{'privilege'});
			$c->session('project' => $ticket->{'project'});
			$c->session('app' => $ticket->{'app'} );
			$c->session('padlock' => $server_time) if (scalar @{&subs::db_select('security', [ 'level' ], { level => 'padlock' })->hashes} > 0);
			$access->{'status'} = 'approved';


			my $mail_ws_url = &ws_url_for($c, '/mail/ws');
			# the splash always wears the drawing (the hand the denial page shows too)
			my $image = &subs::icon_drawn($gb::known_appts->{$ticket->{'privilege'}}->{'icon'});
			my %js = (
				title => 'Box Office',
				layout => 'gate',
				template => 'guest_layouts/box_office',
				'authentication' => 'approved',
				port => $ENV{PORT_AHOY},
				ws_port => $ENV{PORT_MSG},
				alarm_port => $ENV{PORT_BELL},
				device => $device,
				manager_file => &manager_file_maker($c->session('name')),
				ticket => $ticket,
				image => $image,
				# the redirect screen's mark: the house's own logo, which sinks into
				# its lower loop (the hole) rather than showing a privilege icon
				logo => &subs::setting_grabber({ app => 'me', setting => 'logo' })
			);
			my $msg = encode_json { app => 'server', ticket => $ticket, timestamp => $timestamp };
			if ($ticket->{'privilege'} eq 'citizen') {
				$js{'redirector'} = $base_url . '/manager';
				$js{'debriefer'} = $ticket->{'debriefer'};
				$js{'js'} = encode_json \%js;
				$c->render(%js);
			}
			elsif ($ticket->{'privilege'} eq 'resident') {
				$js{'debriefer'} = $ticket->{'debriefer'};
				$js{'redirector'} = $base_url . '/store?app=' . $ticket->{'app'};
				$js{'js'} = encode_json \%js;
				$c->render(%js);
			}
			elsif ($ticket->{'privilege'} eq 'guest') {
				$js{'redirector'} = $base_url . '/';
			#	$js{'debriefer'} = $deb;
				$js{'js'} = encode_json \%js;
				$c->render(%js);
			}
		}
	}
	else {
		# a blacklisted ticket marks the session even when it is expired or
		# suspended: the secret proves whose browser it is, and a blacklisted one
		# is allowed no public pages afterwards (an expired ticket still is)
		if ($ticket->{'privilege'} && $ticket->{'privilege'} eq 'blacklisted' && $genuine) {
			$c->session('authentication' => 'denial');
			$c->session('privilege' => 'blacklisted');
			$c->session('suds_id' => undef);
			$c->session('database' => undef);
		}
		$c->render(template => 'guest_layouts/denial');
	}
	unless ( grep { $_->{'server_time'} >= $server_time - 5000 } @{$access_log} ) {
		unshift @{$access_log}, $access;
		splice @{$access_log}, 20;
		$ticket->{'access_log'} = encode_json $access_log;
		$ticket->{'server_time'} = &subs::rightNow();
		&subs::db_update('tickets', $ticket, { uuid => $ticket->{'uuid'} });
	}
}

1;
