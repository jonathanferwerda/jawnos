package Manager;

# Manager helpers, part 11 of 37. Moved out of Manager.pl so a
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

sub remote_device_connect($rdata) {
	my $manager = $rdata->{'manager'};
	my $filename = $rdata->{'filename'};
	my $timestamp = $rdata->{'timestamp'};
	my $server_time = &subs::rightNow();
	my $ip = $rdata->{'ip'};
	my $vip = $ip;
	my $name = $rdata->{'name'};
	my $browser_tab_id = $rdata->{'browser_tab_id'};
	my $browser_tab = $rdata->{'browser_tab'};
	my $password = $rdata->{'password'};
	my $tunnel = $rdata->{'tunnel'};
	my $nic = $rdata->{'nic'};
	# The relationship to this house. The route that opens the shared house
	# password marks the machine citizen; remote_machine_reauth passes nothing,
	# so a re-auth preserves whatever privilege the row already carries.
	my $privilege = $rdata->{'privilege'};
	# The peer's own entry port. /sesh_check is in the gate's public list, so every
	# listener answers it: the row's `port` (PORT_AHOY) is the door, and there is
	# no hidden dock port to switch to any more.
	my $port = $rdata->{'port'} || $ENV{PORT_AHOY};
	my $signatorial = &subs::signatorial_designer();
	my $tuns = {};
	if ($tunnel eq 'yes') {
		$tuns = &subs::tunnel_port_mapper({ signatorial => $rdata->{'signatorial'} });
		$port = $tuns->{'PORT_AHOY'};
		$manager = 'https://127.0.0.1:' . $port . '/manager';
		$vip = '127.0.0.1';
	}


	my $returner = {};
	$manager =~ s/\/manager$//gi;

	my $bti;
	my $ua = Mojo::UserAgent->new();
	# The login names this machine, so it must sign it: the receiver pins the
	# offered key on first contact and verifies against it ever after.
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
	my $manager_file = &manager_file_maker($name);
	my $login = {
		numerics => $password,
		president => $filename,
		backup => '',
		remote_timestamp => $timestamp // '',
		manager_file => $manager_file,
	};
	my $url = &sesh_login_url($manager, $browser_tab_id, $signatorial, $login);
	my $res = eval { return $ua->insecure(1)->post($url => form => $login)->result };

	$returner->{'body'} = eval { return decode_json $res->body };
	# Adopt the port the peer says it serves on - that is the authority every later
	# call rides, and it is how a row entered on an old LAN port moves to the
	# entry port. A failed answer announces nothing, so the typed port is kept.
	my $announced = $tuns->{'PORT_AHOY'} || $returner->{'body'}->{'port'};
	if (defined $announced && $announced =~ /^\d+$/) {
		$manager = &subs::peer_entry_url($manager, $announced);
		$port = $announced;
	}
	if ($returner->{'body'}->{'fqdn'} && $ip !~ /[a-zA-Z]/ && $returner->{'body'}->{'signatorial'} ne $signatorial) {

		$returner->{'body'}->{'ip_address'} = $ip;
		my $fqdn = $returner->{'body'}->{'fqdn'};
		# A name the resolver cannot answer is not a route: keep the ip we just
		# used instead of shelling out `ping` and filling the log with
		# 'unknown host' on a machine with no VPN.
		my $ping = '';
		if (&subs::peer_host_is_literal($fqdn) || gethostbyname($fqdn)) {
			$ping = `timeout .5 ping -c 1 $fqdn 2>/dev/null`;
		}
		if ($ping =~ /ttl/gi) {
			my @ping = split /\n/, $ping;
			if ($ping[1] =~ /$ip/) {
				$manager =~ s/$ip/$fqdn/gi;

				my $devices = &subs::db_select('devices')->hashes;
				foreach my $d ( @{$devices} ) {
					my $address = eval { return decode_json $d->{'address'} };

					my @neigh = grep { $_->{'ip'} eq $ip } @{$address->{$nic}->{'neigh'}};
					#$neigh[0]->{'ip'} = $fqdn;
					$neigh[0]->{'fqdn'} = $fqdn;
					$neigh[0]->{'purpose'} = $returner->{'body'}->{'device'};
					$neigh[0]->{'ip_address'} = $ip;
					$neigh[0]->{'signatorial'} = $returner->{'body'}->{'signatorial'};
					my $jaddress = encode_json $address;
					&subs::db_update('devices', { address => $jaddress }, { uuid => $d->{'uuid'}} );
				}

				$ip = $fqdn;
			}
		}
	}

	if ($returner->{'body'}->{'authentication'} eq 'approved') {
		$ua = Mojo::UserAgent->new();
		$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
		$url = &sesh_login_url($manager, $browser_tab_id, $signatorial, $login);
		my $double_check = eval { return $ua->insecure(1)->post($url => form => $login)->result };
		$returner->{'body'} = eval { return decode_json $double_check->body } ;

		my $signatorial = &subs::signatorial_designer();
		if ($returner->{'body'}->{'authentication'} eq 'approved') {# && $returner->{'body'}->{'signatorial'} eq &subs::signatorial_designer()) {
			# A peer that answers with our own signatorial is this machine. Filing a
			# remote machine for ourselves is what let the hub try to sync with itself
			# (and its own mirrors then doubled the stored blob every pass), so never
			# record a self row.
			return $returner if ($returner->{'body'}->{'signatorial'} || '') eq $signatorial;
			my $nd = &subs::db_select('remote_machines', undef, { signatorial => $returner->{'body'}->{'signatorial'} })->hashes;
			my $uuid = $nd->[0]->{'uuid'} ? $nd->[0]->{'uuid'} : &subs::random_string_creator(15);

			$bti = $returner->{'body'}->{'browser_tab_id'};
			my $ssh_port = $returner->{'body'}->{'ssh_port'} || $config->{'ssh_port'};
			my $remote_device = $returner->{'body'}->{'device'};
			# Remember the name this machine already has. A phone reports
			# 'localhost' every time, and writing that over a good name made the
			# Music output list (and the Dev panel) call it localhost.
			my $peer_host = &subs::device_hostname_better(
				$returner->{'body'}->{'hostname'},
				($nd->[0] ? $nd->[0]->{'hostname'} : ''),
				$returner->{'body'}->{'fqdn'});

			my $buttons = [
				{ name => 'RD', class => 'neighbour_disconnect', direction => 'disconnect' },
				{ name => 'Upgrade', class => 'remote_upgrade' },
				{ name => 'cxl_up', class => 'remote_upgrade_clear' },
				{ name => '-> Me', class => 'remote_rsync', direction => 'from' },
				{ name => 'Me ->', class => 'remote_rsync', direction => 'to' }
			];
			my $manager_window = $manager;
			$manager_window =~ s{/+$}{};
			$manager_window .= '/manager';
			$returner->{'button'} .= '<button type="button" class="remote_manager_open" uuid="' . &subs::html_text($uuid) . '" manager="' . &subs::html_text($manager_window) . '" hint="' . &subs::html_text(&subs::ui('Open this machine\'s Manager')) . '">' . &subs::lang('common.go') . '</button> ';
			# the peer's self-reported version, so a neighbour that is behind is
			# obvious in the panel instead of a guess.
			$returner->{'button'} .= '<span class="neighbour_version" hint="their version" style="opacity:0.6;">v' . ($returner->{'body'}->{'version'} || '?') . '</span><br>';
			foreach my $b ( @{$buttons} ) {
				$returner->{'button'} .= '<button direction="' . $b->{'direction'} . '" device="' . $remote_device .'"
					home="' . $returner->{'body'}->{'pwd'} . '" signatorial="' . $returner->{'body'}->{'signatorial'} . '"
					hostname="' . &subs::html_text($peer_host) . '" uuid="' . $uuid . '" ssh_port="' . $ssh_port .'" ip="' . $ip . '"
					database="' . $returner->{'body'}->{'database'} .  '" nic="' . $nic . '"
					class="' . $b->{'class'} . '">' . $b->{'name'} . '</button>';
			}
			$returner->{'button'} .= '<span class="remote_machine_specials"><br>' .
				'G: <input type="text" name="gimme" class="gimme_input" uuid="' . $uuid . '" signatorial="' . $returner->{'body'}->{'signatorial'} . '"></span>';
			$returner->{'status'} = 'Connected';

			my $secret = &subs::db_select('security', ['credential'], { level => 1 })->hash->{credential};
			my $double = &subs::decrypter($password,$secret);
			my $opens = &subs::door_row() ? &subs::door_check($password) : (defined $double && secure_compare($password, $double));
			if ($opens) {
				$returner->{'password'} = $secret;
				my $hs = `hostname`;
				chomp $hs;
				$returner->{'hostname'} = $hs;
				my $who = `whoami`;
				chomp $who;
				$returner->{'username'} = $who;
				$returner->{'colour'} = '#' . &subs::random_colour_grabber();
				#$ua->insecure(1)->get($manager . '/manager/say_it?words=' . &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || $hs)->result;

				my $json_buttons = encode_json $buttons;
				my $remote_data = encode_json &subs::remote_machine_data_view($returner->{'body'});
				my $cookie_jar = $ua->cookie_jar;
				my @cookies;
				for my $cookie (@{$cookie_jar->find(Mojo::URL->new($manager))}) {
					push @cookies, {
						name => $cookie->name,
						value => $cookie->value,
						domain => $vip,
						path => '/'
					};
				}

				my $cookies = encode_json \@cookies;

				my $remote_machine = {
					ip => $ip,
					fqdn => $returner->{'body'}->{'fqdn'},
					port => $tuns->{'PORT_AHOY'} || $port,
					ws_port => $tuns->{'PORT_MSG'} || $returner->{'body'}->{'ws_port'},
					dock_port => $tuns->{'PORT_DOCK'} || $returner->{'body'}->{'dock_port'},
					status => 'connected',
					manager => $manager,
					timestamp => $timestamp,
					server_time => $server_time,
					buttons => $returner->{'button'},
					data => $remote_data,
					signatorial => $returner->{'body'}->{'signatorial'},
					cookie => $cookies,
					connection => 'active',
					uuid => $uuid,
					nic => $nic,
					manager_file => $returner->{'body'}->{'manager_file'},
					device => $returner->{'body'}->{'device'},
					hostname => $peer_host,
					version => $returner->{'body'}->{'version'},
					tunnel => $tunnel,
					mirrors => do {
						my $in = $returner->{'body'}->{'mirrors'};
						(ref $in eq 'ARRAY')
							? encode_json [ grep { defined $_ } map { &subs::remote_machine_mirror_row($_) } @{$in} ]
							: undef;
					},
					archive => eval { return encode_json $returner->{'body'}->{'archive'} } || undef,
					archive_dir => $returner->{'body'}->{'archive_dir'}
				};

				# A citizen's own machine carries full trust. A peer enrolled in
				# future passes privilege => 'peer' and its own scope; an insert with
				# no scope starts a peer at visitor, never at trusted.
				if (defined $privilege && $privilege ne '') {
					$remote_machine->{'privilege'} = $privilege;
					$remote_machine->{'grant_scope'} = $rdata->{'grant_scope'} if defined $rdata->{'grant_scope'};
					$remote_machine->{'grant_expires'} = $rdata->{'grant_expires'} if defined $rdata->{'grant_expires'};
					if ($privilege eq 'citizen') {
						$remote_machine->{'grant_scope'} = 'trusted';
						$remote_machine->{'grant_expires'} = '';
					}
				}

				if (scalar @{$nd} > 0 && $nd->[0]->{'uuid'}) {
					&subs::db_update('remote_machines', $remote_machine, { signatorial => $returner->{'body'}->{'signatorial'} });
				}
				else {
					my $fresh_scope = (($remote_machine->{'privilege'} || 'citizen') eq 'citizen') ? 'trusted' : 'visitor';
					$remote_machine->{'privilege'} //= 'citizen';
					$remote_machine->{'grant_scope'} //= $fresh_scope;
					$remote_machine->{'grant_expires'} //= '';
					&subs::db_insert('remote_machines', $remote_machine);
				}
			}
		}
	}
	return $returner;
}

sub tunnel_rail_allowed {
	my ($c) = @_;
	return 1 if $c->session('authentication') eq 'approved';
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	return 1 if $rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm);
	return 0;
}

sub contact_list_row_finder {
	my ($app, $list) = @_;
	my $rows = eval { return decode_json &subs::setting_grabber({ app => $app, setting => $list }) } || [];
	$rows = [ $rows ] if ref $rows eq 'HASH';
	$rows = [] unless ref $rows eq 'ARRAY';
	return $rows;
}

sub lock_session($c, $explicit = 0, $scope = '') {
	$scope ||= '';
	my $now = &subs::rightNow();
	my $device_uuid = $c->session('device_uuid') || '';
	# The screen that is locking, so a device lock closes only its own windows.
	my $browser_tab_id = $c->session('browser_tab_id') || $c->param('browser_tab_id') || '';
	# pl_time is a house-wide stamp, so it is sealed under the house key, not a
	# session's copy: a fresh tab must be able to read the same timer.
	my $suds = &subs::suds_grabber() || &subs::session_suds($c) || $gb::suds;
	my ($db) = &subs::database_grabber();

	# The phone key talks to the server while the padlock is up. Those calls are
	# not a fresh lock: running the lock again would replace the screen under the
	# person's hand and re-expire the session a screen that just turned it had
	# already opened.
	my $path = $c->req->url->path;
	return 0 if ($path eq '/manager/security/padlock_phone_show' ||
		$path eq '/manager/security/padlock_request_cancel' ||
		$path eq '/manager/security/media_lock' ||
		$path eq '/manager/security/padlock_challenge' ||
		$path eq '/manager/security/padlock_unlock' ||
		$path eq '/manager/security/padlock_key_show_peer' ||
		$path eq '/manager/security/padlock_state' ||
		$path eq '/manager/security/fingerprint_unlock' ||
		$path eq '/manager/security/fingerprint_unlock_status' ||
		$path eq '/manager/security/biometric_challenge' ||
		$path eq '/manager/security/biometric_unlock' ||
		$path eq '/manager/security/padlock_key');
	# A passkey is a way in, like the paper code: the enrollment page and the
	# sign-in routes must answer while a screen is locked.
	return 0 if $path =~ m{^/passkey(?:/|$)};
	return 0 if $path =~ m{^/manager/webauthn/login/(?:begin|finish)$};

	# A request that started while the lock screen was up can reach here after
	# another screen has already turned the lock. Re-read the stored time (the
	# request's setting memo may be older than that unlock) and leave it be.
	unless ($explicit) {
		my $fresh_row = &subs::db_query("select value from settings where app = ? and setting = ? order by server_time desc limit 1", '__president', 'pl_time')->hashes->[0];
		# No stamp at all means this machine has never been locked since the gate
		# was set. That is open, not an expired window: starting a lock here is
		# what made a peer with a fresh database show the whole house locked.
		return 0 unless $fresh_row;
		my $fresh = &padlock_time_value($suds, $fresh_row->{'value'}) || 0;
		return 0 if $fresh > $now;
	}

	# An inactivity lock on a screen with no device identity has no target. It
	# used to be treated as a whole-house lock, which re-stamped pl_time on
	# every request, deleted every device's unlock row, and closed the same app
	# windows again and again. The page's own padlock_state adopts its device;
	# until then, leave this request alone.
	return 0 if (!$explicit && !$device_uuid);

	# A single tap locks this device only. A double tap (scope=all) or the
	# inactivity timeout is the whole-house lock. A screen opened after a
	# whole-house lock carries its own timer, so the overlay skips it. (An
	# inactivity lock from a screen with no identity returned above; without
	# that, it re-locked the house, and closed windows, on every request.)
	my $whole_house = (!$explicit || $scope eq 'all' || !$device_uuid) ? 1 : 0;
	my $close_tab = $whole_house ? undef : $browser_tab_id;
	my $overlay_target = '';
	my @unlocked;
	my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
	$activity_timeout = abs &subs::time_abbrev_translator($activity_timeout);
	if ($whole_house) {
		&subs::setting_setter({ app => '__president', setting => 'pl_time', value => $now });
		# a house-wide lock supersedes every screen's own row; a stale row
		# outlives the house stamp and keeps that screen locked forever
		&subs::db_delete('security', { level => 'padlock_device' });
		if ($scope eq 'all') {
			&subs::db_query('delete from settings where app = ? and setting = ?', '__president', 'padlock_device_time');
		}
		else {
			my $open_rows = &subs::db_select('settings', undef, { app => '__president', setting => 'padlock_device_time' })->hashes || [];
			foreach my $r ( @{$open_rows} ) {
				my $d = $r->{'device'} || '';
				next unless $d;
				my $until = eval { &padlock_time_value($suds, $r->{'value'}) } || 0;
				push @unlocked, $d if $until && $until > $now;
			}
		}
	}
	else {
		&subs::setting_setter({ app => '__president', setting => 'pl_time', value => $now + $activity_timeout });
		&subs::db_delete('security', { level => 'padlock_device', uuid => $device_uuid });
		&subs::db_insert('security', { level => 'padlock_device', credential => '', timestamp => $now, server_time => $now, uuid => $device_uuid });
		&padlock_device_clear_time($device_uuid);
		$overlay_target = $device_uuid;
	}
	# A media grant belongs to one screen. A whole-house lock drops every
	# screen's grants on this machine; a single-screen lock drops only its own,
	# so locking here never shuts another screen's or a peer's padlock.
	my @open_media;
	if ($whole_house) {
		my $rows = &subs::db_query('select distinct app from cache where context = ?', 'media_unlock')->hashes || [];
		@open_media = map { $_->{'app'} } @{$rows};
		# a row left by the old house-wide secret still counts as an open one
		foreach my $legacy_app ( @media_unlock_apps ) {
			push @open_media, $legacy_app if &subs::setting_grabber({ app => $legacy_app, setting => 'combo_unlock' });
		}
		&subs::db_query('delete from cache where context = ?', 'media_unlock');
	}
	else {
		my $rows = &subs::db_query('select distinct app from cache where context = ? and device = ?', 'media_unlock', $device_uuid)->hashes || [];
		@open_media = map { $_->{'app'} } @{$rows};
		&media_unlock_clear($device_uuid);
	}
	# the old house-wide secret never stands again; a stale row from before the
	# per-screen grants would otherwise keep a peer's window open
	&subs::db_query('delete from settings where setting = ? and app in (?,?,?)', 'combo_unlock', @media_unlock_apps);
	foreach my $media_app ( @open_media ) {
		next unless grep { $_ eq $media_app } @media_unlock_apps;
		&subs::window_closer($media_app, $close_tab);
	}

	my $player = &subs::cache_get({ app => 'music', context => 'player' });
	if ($player->{'unlocked'} == 1) {
		&subs::cache_delete({ app => 'music', context => 'player' });
		&subs::cache_delete({ app => 'music', context => 'content' });
		&subs::window_closer('music', $close_tab);
	}
	my $websockets = &subs::db_query('select * from websockets','stayingAlive')->hashes;
	my $port = $c->req->url->base->port;

	foreach my $ws ( @{$websockets} ) {
		# A device lock closes only the locking screen's windows; a whole-house
		# lock still closes them everywhere.
		if (!$whole_house && (!$close_tab || ($ws->{'browser_tab_id'} || '') ne $close_tab)) {
			next;
		}
		if ($ws->{'href'} =~ /\Q$port/gi) {
			if (&help_app_hidden($ws->{'app'})) {
				&subs::window_closer($ws->{'app'}, $close_tab);
			}
		}
		elsif (!$ws->{'room'}) {
			&subs::db_delete('websockets', { uuid => $ws->{'uuid'} });
		}
	}

	my $padlock = &subs::db_query('select * from security where level = ?', 'padlock')->hashes;

	if (scalar @{$padlock} > 0 && $now > $c->session('last_padlock') + 5000) {
		my $attempts = &subs::note_decrypter(&subs::session_suds($c), &subs::setting_grabber({ app => '__president', setting => 'padlock_pulls' }));
		my $pl = $c->render_to_string(template => 'locked_screen', target => $overlay_target, fingerprint => (&fingerprint_available() && &padlock_request_is_local($c)) ? 1 : 0, biometric => &biometric_enrolled_for($overlay_target || $c->session('device_uuid')));
		my $colour = &subs::random_colour_grabber();
		my $taunt_size = scalar @gb::taunts;
		my $taunts = $gb::taunts[rand($taunt_size)];
		&Websocket::send('server', { padlock => $pl, taunts => $taunts, attempts => $attempts, colour => $colour, target => $overlay_target, unlocked => \@unlocked });
		# A lock shows itself on the screen that locked. It deliberately does NOT
		# broadcast the unlock page to every other device: doing that on every
		# lock (once per five seconds while a locked screen kept talking) pulled
		# phones and laptops onto a black page, added a history entry, and left
		# their images stale. Another device is asked only when the person presses
		# Unlock on the locked screen, which calls padlock_phone_show.
	#	$c->render(template => 'padlock', mode => 'locker');
	#	my $path = $c->req->url->path;
	#	unless $path eq '/manager/security/padlock_pull'
		$c->session('last_padlock' => $now );
	}

	return 1;
}

sub start_menu_recent() {
	my $recent = &subs::cache_get({ app => '__president', context => 'start_menu', subcontext => 'recent' });
	return [ ref $recent eq 'ARRAY' ? @{$recent} : () ];
}

sub start_menu_key_clean($key) {
	# Keep the letters of every script: the key names a button in the recent
	# list, and an app called 中文 or Café must not become an empty string.
	$key =~ s/[^\p{L}\p{M}\p{N} _\-]//g;
	$key =~ s/^\s+//; $key =~ s/\s+$//;
	return substr($key, 0, 60);
}

sub start_menu_used($key) {
	$key = &start_menu_key_clean($key);
	return &start_menu_recent() unless length $key;
	my $recent = &start_menu_recent();
	@{$recent} = grep { $_ ne $key } @{$recent};
	unshift @{$recent}, $key;
	pop @{$recent} while scalar @{$recent} > 10;
	&subs::cache_set({ app => '__president', context => 'start_menu', subcontext => 'recent', warranty => '-1y' }, $recent);
	return $recent;
}

sub start_menu_forget($key) {
	$key = &start_menu_key_clean($key);
	return &start_menu_recent() unless length $key;
	my $recent = [ grep { $_ ne $key } @{ &start_menu_recent() } ];
	&subs::cache_set({ app => '__president', context => 'start_menu', subcontext => 'recent', warranty => '-1y' }, $recent);
	return $recent;
}

sub start_menu_hidden_apps {
	my (%seen, @apps);
	foreach my $app ( keys %{ $gb::known_appts || {} } ) {
		push @apps, $app unless $seen{$app}++;
	}
	my $rows = eval {
		&subs::db_query("select distinct app from settings where setting in ('visible','pos','mab') and app is not null and app != '' and substr(app,1,2) <> '__'")->hashes;
	} || [];
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} // next;
		push @apps, $app unless $seen{$app}++;
	}
	return grep { &subs::app_hidden_now($_) } @apps;
}

sub start_menu_maker($c) {
	my $returner = {};
	my $menu = $c->param('menu') // '';
	$menu = '' unless $menu =~ /^(?:app|run|up|exp|view)$/;
	# A new install opens on the System page (the water-drop tab), which is the
	# quickest way to see that the house is well. A saved choice always wins:
	# the browser only sends nothing while it has none. Once the welcome tour has
	# been shown the ordinary fallback is the app list.
	my $first_run = &help::welcome_seen() ? 0 : 1;
	$menu = $first_run ? 'view' : 'app' unless length $menu;

	# Opening the System view is what asks the levels loop for quick passes.
	&subs::levels_fast_request() if $menu eq 'view';
	my $html = $c->render_to_string(
		template => 'start_menu/start_menu',
		parking_lot => &parking_lot_grabber($c),
		config => &subs::config_reader(),
		padlock => &subs::db_select('security', ['level'], { level => 'padlock' })->hashes,
		menu => $menu,
		recent => &start_menu_recent(),
		hidden_apps => [ &start_menu_hidden_apps() ]
	);
	# Static files carry no Cache-Control, so browsers cached the icons
	# heuristically and kept showing stale ones. Version the local images
	# so the start menu always pulls the current set.
	my $v = &subs::rightNow();
	my $set = &subs::icon_set();
	if ($set) {
		$html =~ s{src="(/[^"]*\.(?:png|jpe?g|gif))"}{'src="' . &subs::icon_for($1, $set) . '"'}ge;
	}
	$html =~ s/"([^"]*\.(?:png|jpe?g|gif|svg))"/"$1?v=$v"/g;
	$returner = { html => $html, menu => $menu, first_run => $first_run };

	return $returner;
}

sub parking_lot_grabber($c) {
	my $parking_lot = {};
	my $spaces = &subs::db_query('select * from websockets where room is not null')->hashes;

	foreach my $pl ( @{$spaces} ) {
		my $others = &subs::db_select('websockets', undef, { browser_tab_id => $pl->{'browser_tab_id'} })->hashes;
		foreach my $ot ( @{$others} ) {
			if ($ot->{'music_data'}) {
				$pl->{'music_data'} = $ot->{'music_data'};
			}
			elsif ($ot->{'jp_data'}) {
				$pl->{'jp_data'} = $ot->{'jp_data'};
			}
		}
		$parking_lot->{$pl->{'room'}} = $pl;
	}
	return $parking_lot;
}

sub website_preloader($c) {
	my ($website,$header);

	if ($c->param('app')) {
		my $advertise_watching = &subs::setting_grabber({ app => 'me', setting => 'advertise_watching' });
		my $app = $c->param('app');
		$header = &subs::appt_header_printer({ app => $app });
		my $timestamp = $c->param('timestamp') || &subs::rightNow();
		my $appts = &log_reader({ app => $app, view => 'centre_view', timestamp => $timestamp  });
		$website = $c->render_to_string(
			template => 'appointment_wrapper',
			appts => $appts,
			appointments => [ $app ],
			timestamp => $timestamp,
			device => $device,
			from => 'centre_view',
			config => &subs::config_reader(),
			measures => $gb::measures,
			advertise_watching => $advertise_watching,
			header => $header
		);
		$website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $website }, $timestamp);
		$c->stash('website' => $website);
	}
	return ($website,$header);
}

1;
