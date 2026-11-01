package Manager;

# Manager helpers, part 33 of 37. Moved out of Manager.pl so a
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

sub measure_currency_conversions($key, $value, $units) {
	my $snap = &subs::crypto_rates_read();
	my $table = $snap->{'rates'} || {};
	my $from = $table->{uc $key};
	my @order = ( &subs::crypto_report_currency(), qw/USD EUR GBP JPY CNY AUD CHF MXN INR BRL/,
		( @{ &subs::crypto_enabled_assets() } ),
		( map { $_->{'code'} } @{ &subs::crypto_fiat_table() } ),
		( map { $_->{'code'} } @{ &subs::crypto_assets() } ) );
	my (@codes, %seen);
	foreach my $c ( @order ) {
		next unless defined $c && length $c;
		my $code = uc $c;
		next if $seen{$code}++;
		push @codes, $code;
	}
	my ($edges, @rows);
	foreach my $to ( @codes ) {
		next if $to eq uc $key;
		my $rate;
		if ( defined $from && $from > 0 && defined $table->{$to} && $table->{$to} > 0 ) {
			$rate = $from / $table->{$to};
		}
		else {
			$edges ||= &measure_conversion_edges($units);
			$rate = &measure_conversion_factor($edges, $key, $to);
		}
		next unless defined $rate && $rate > 0 && $rate < 1e15;
		my $v = $value * $rate;
		push @rows, { unit => $to, name => &measure_unit_name($to, $units->{$to}), value => 0 + $v, text => &measure_value_text($v, $to, 1) };
		last if scalar @rows >= 30;
	}
	return \@rows;
}

sub measure_unit_conversions($key, $def, $value, $units) {
	my %type = map { $_ => 1 } @{ $def->{'types'} || [] };
	my @order = qw/mm cm m km in ft mi mL L tsp tbsp cup pint gal oz g mg kg lb C F/;
	my %pref;
	my $i = 0;
	$pref{$_} = $i++ for @order;
	my @targets = grep {
		$_ ne $key && ref $units->{$_} eq 'HASH'
			&& !&currency_unit($_)
			&& grep { $type{$_} } @{ $units->{$_}->{'types'} || [] }
	} keys %{$units};
	@targets = sort { ($pref{$a} // 999) <=> ($pref{$b} // 999) || $a cmp $b } @targets;
	my $edges = &measure_conversion_edges($units);
	my $temp = $type{'temperature'} ? 1 : 0;
	my @rows;
	foreach my $to ( @targets ) {
		my $v;
		if ($temp) { $v = &measure_temperature_convert($key, $to, $value); }
		else {
			my $factor = &measure_conversion_factor($edges, $key, $to);
			$v = $value * $factor if defined $factor;
		}
		next unless defined $v && $v == $v && abs($v) < 1e15;
		push @rows, { unit => $to, name => &measure_unit_name($to, $units->{$to}), value => 0 + $v, text => &measure_value_text($v, $to, 0) };
	}
	return \@rows;
}

sub measure_conversion_rows($unit, $value) {
	my $units = &measures_all();
	my ($key, $def) = &measure_unit_resolve($unit, $units);
	if (!defined $key) {
		# a coin or a fiat code is not in the units registry, but the snapshot
		# knows both
		my $asset = &subs::crypto_asset(uc($unit || ''));
		if ($asset) {
			$key = uc $asset->{'code'};
			$def = { name => $asset->{'name'}, types => [ 'currency' ], symbol => $asset->{'symbol'} || '' };
		}
		else {
			my $fiat = &subs::crypto_fiat(uc($unit || ''));
			if ($fiat) {
				$key = uc $fiat->{'code'};
				$def = { name => $fiat->{'name'}, types => [ 'currency' ] };
			}
		}
	}
	return { ok => 0 } unless defined $key && ref $def eq 'HASH';
	$value = 0 unless defined $value && $value =~ /^-?\d/;
	my $rows = &currency_unit($key)
		? &measure_currency_conversions($key, $value, $units)
		: &measure_unit_conversions($key, $def, $value, $units);
	return { ok => 0, unit => $key } unless scalar @{$rows};
	my $type = '';
	if (&currency_unit($key)) { $type = 'currency'; }
	elsif (ref $def->{'types'} eq 'ARRAY' && scalar @{$def->{'types'}}) { $type = $def->{'types'}->[0]; }
	return {
		ok => 1,
		unit => $key,
		type => $type,
		name => &measure_unit_name($key, $def),
		value => 0 + $value,
		text => &measure_value_text($value, $key, &currency_unit($key)),
		rows => $rows,
	};
}

sub keyboard_maker($c, $remote_pick) {
	my $browser_tab_id = $c->param('browser_tab_id');
	my $remote_machines = $c->param('remote_machines');
	my $remote_control = defined $remote_pick ? $remote_pick : $c->param('remote_control');
	my $toggle = $c->param('toggle');
	my $accts = [];
	my $projs = [];
	my $accounts = &subs::db_query("select * from settings where (setting = ? or setting =?) and value=?",'pos', 'mab', 'account');
	my $acc = $accounts->hashes;
	if ($toggle eq 'delorean') {
		foreach my $a ( reverse @{$acc} ) {
			push @{$accts},$a unless grep { $_->{'app'} eq $a->{'app'}} @{$accts};
			$a->{'formatted_name'} = &subs::format_name($a->{'app'});
		}
		my $projects = &subs::db_query("select * from settings where (setting = ? or setting = ?) and value=?",'pos', 'mab', 'project');
		my $proj = $projects->hashes;

		foreach my $a ( reverse @{$proj} ) {
			push @{$projs},$a unless grep { $_->{'app'} eq $a->{'app'}} @{$projs};
			$a->{'formatted_name'} = &subs::format_name($a->{'app'});
		}
	}

	my ($av_data);
	if ($c->param('avData') && $toggle eq 'walkboy') {
		$av_data = decode_json($c->param('avData'));

		foreach my $av (@{$av_data}) {
			if ($av->{'kind'} eq 'audioinput') {
				$av->{'icon'} = 'microphone';
			}
			elsif ($av->{'kind'} eq 'videoinput') {
				if ($av->{'label'} =~ /front/gi) {
					$av->{'icon'} = 'camera front';
				}
				else {
					$av->{'icon'} = 'camera back';
				}

			}
			elsif ($av->{'kind'} eq 'audiooutput') {
				$av->{'icon'} = 'speaker';
			}
		}
	}
	my $websockets;
	if ($toggle eq 'sessions' || $toggle eq 'controller') {
		my $web_query = &subs::db_query('select * from websockets where browser_tab_id = ?',$browser_tab_id);
		$websockets = $web_query->hashes;
	}
	my $notifications;
	if ($toggle eq 'notifications') {
		$notifications = &notification_grabber({});
	};
	my $config = &subs::config_reader();
	my $remote_connect = $gb::ws;
	my $kb = $c->render_to_string(
		browser_tab_id => $browser_tab_id,
		accounts => $accts,
		projects => $projs,
		template => 'keyboard',
		toggle => $toggle,
		device => $device,
		av_data => $av_data,
		websockets => $websockets,
		notifications => $notifications,
		remote_machines => $remote_machines,
		remote_control => $remote_control,
		config => $config,
		manager_file => &manager_file_maker($c->session('name')),
		pseudonyms => &pseudonym_maker('viewer', ''),
		ws => $gb::ws,
	);
	return $kb;
}

sub manager_file_maker($session_name = '') {
	my ($my_name,$computer_name,$hostname,$hostnamer,$database_name);
	my ($db,$database) = &subs::database_grabber();
	$hostname = `hostname`;
	chomp $hostname;
	$hostnamer = eval { return &subs::db_select('devices', ['name'], { hostname => $hostname } )->hash->{name} };
	$my_name = $session_name || &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	$computer_name = &subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' });
	$database_name = $database;
	$database_name =~ s/^database\///;
	$database_name =~ s/.db$//gi;
	my @database_name = split '/', $database_name;
	$database_name = $database_name[-1];

	return ($my_name || $hostnamer || $hostname) . '@' . $database_name . '.' . ($computer_name || $hostname);

};

sub lock_screen($c) {
	if ($c) {
		my $authentication = $c->session('authentication');
		if (-e $database && $device eq 'mobile') {
		}
	}
}

sub unlock_screen($c) {
	my $authentication = $c->session('authentication');
	if (-e $database && $device eq 'mobile') {
		# The app runs BiometricPrompt (an Activity flow) and answers in
		# termux-fingerprint's shape; a cancellation is an answer, not a reason to
		# ask again.
		my $fingerprint = &subs::device_call('auth.fingerprint', { reason => 'Unlock JawnOS' }) || {};
		if (ref $fingerprint eq 'HASH') {
			if (($fingerprint->{'auth_result'} || '') eq 'AUTH_RESULT_SUCCESS') {
				$c->session('authentication' => 'approved');
			}
			else {
				$c->session('authentication' => 'rejected');
			}
		}
	}
}

sub app_gate_shadow_log {
	my ($c, $path) = @_;
	my $method = $c->req->method || 'GET';
	my $remote = $c->tx->remote_address || '?';
	my $key = $method . "\x1f" . $path . "\x1f" . $remote;
	my $now = &subs::rightNow();
	return if defined $app_gate_shadow_seen{$key} && $now - $app_gate_shadow_seen{$key} < 60000;
	# a long-lived worker must not keep a key for every path a scanner invents
	%app_gate_shadow_seen = () if keys(%app_gate_shadow_seen) > 1024;
	$app_gate_shadow_seen{$key} = $now;
	$log->info('app gate shadow: would deny ' . $method . ' ' . $path . ' from ' . $remote);
}

sub authentication_passer($c) {
	my $server_time = &subs::rightNow();

	# The path is asked for by several checks below (the app gate, the bootstrap
	# door, the padlock gate), so read it once. A public path is answered by
	# app_public_path alone: the gate lets it through whatever the policy says,
	# so the two settings reads behind app_access_mode are skipped for every
	# asset and public page instead of being paid on each of them.
	my $app_path = $c->req->url->path->to_string;
	# A plain loopback WebSocket cannot carry the Secure session cookie; the
	# page-supplied ws_token restores the session before this gate reads it,
	# so the socket passes the same gate the page did.
	if ($app_path =~ m{/(?:mail|manager|observer)/ws\z}) {
		&ws_plain_auth($c);
	}
	my $app_public = &app_public_path($app_path) ? 1 : 0;
	# A live boot belongs to whoever is at the machine: its own loopback (the
	# desktop app's view) is the house, so it opens the manager without a
	# ticket or code. This is the live image only - an installed disk has the
	# flag removed, and a remote caller is never loopback.
	my $live_local = (($config->{'live'} // '') && $c->tx->local_address eq $c->tx->remote_address) ? 1 : 0;
	if ($live_local && ($c->session('authentication') || '') ne 'approved') {
		my ($ldb,$ldatabase) = &subs::database_grabber();
		if ($ldb && $ldatabase) {
			my $lsuds = eval { &subs::suds_grabber() } || '';
			$c->session('authentication' => 'approved');
			$c->session('database' => $ldatabase);
			$c->session('suds_id' => $lsuds ? &subs::suds_id($lsuds) : 'live-local');
			$c->session('warranty' => &subs::forever_warranty());
			$c->session('server_time' => &subs::rightNow());
			$c->session('name' => &subs::setting_grabber({ app => 'me', setting => 'name' }) || 'Me');
			$c->session('privilege' => 'resident');
			$c->session('role' => 'resident');
			$c->session('source' => 'local_ticket');
			$c->session('bootstrap' => undef);
			$c->session('peer' => undef);
		}
	}
	# Ensure the app columns exist before anything asks for them, public path or
	# not. It is a no-op after the first call in a worker.
	&app_schema_ensure();
	my $app_mode = ($app_public || $live_local) ? 'off' : &app_access_mode();

	# The app gate runs before the login gate: a browser must not be handed the
	# manager's login page or any private route at all. The public homepage,
	# store and the embedded devices' own token rail are allowed through.
	# app_session_ok/app_peer_ok are memoised here rather than called twice: a
	# peer session's proof costs a roster read, and the bootstrap door below asks
	# the same two questions.
	my ($app_session, $app_peer);
	if ($app_mode ne 'off') {
		# The Gate is the front door for a person without an app key. A browser
		# that has not signed in must be able to see it, because the passkey is
		# the login that then admits the session (webauthn=1). An approved
		# session with no passkey is still refused, so the app-only rule holds.
		my $gate_only = ($app_path eq '/manager' && (($c->session('authentication') || '') ne 'approved')) ? 1 : 0;
		unless (($app_session = &app_session_ok($c)) || ($app_peer = &app_peer_ok($c)) || $c->session('webauthn') || $gate_only) {
			if ($app_mode eq 'enforce') {
				$c->render(template => 'app_required', layout => undef,
					device_uuid => ($c->session('device_uuid') || ''),
					signatorial => &subs::signatorial_designer());
				return;
			}
			&app_gate_shadow_log($c, $app_path);
		}
	}

	# A password-only login from off the machine is a bootstrap session: it may
	# pair a device, restore a backup or recover, but never open the manager.
	# This holds even when app_access is off, so the password cannot reopen the
	# door the app gate would otherwise leave open.
	if (($c->session('bootstrap') || '') eq '1'
		&& !$app_public
		# A live boot is the machine in someone's hands: its own loopback login
		# (the printed unlock code, or the local ticket route) may open the
		# manager. An installed disk has the live flag removed.
		&& !(($config->{'live'} // '') && $c->tx->local_address eq $c->tx->remote_address)
		&& !($app_session //= &app_session_ok($c))
		&& !($app_peer //= &app_peer_ok($c))) {
		$c->render(template => 'app_required', layout => undef,
			device_uuid => ($c->session('device_uuid') || ''),
			signatorial => &subs::signatorial_designer());
		return;
	}

	my $person_uuid = $c->session('person_uuid') || '';
	my $device_uuid = $c->session('device_uuid') || '';
	# The principal's two roster rows are read once: the fast path needs them to
	# admit the request, and the full pass below would otherwise read the same
	# two rows again to reach the same answer.
	my $principal_active;
	my $padlock_rows;

	my $authentication = $c->session('authentication') || 'revoked';
	if ($c->session('authentication') eq 'denial' || $c->session('reject_count') > 3 || ($c->stash('no') && $c->stash('no') == 1)) {
		my $denial = $c->render(template => 'guest_layouts/denial', message => '... access denied.');
		$c->session('authentication' => 'denied');
		$authentication = 'denial';
		$c->rendered;
		return;
	}
	elsif ($authentication eq 'approved' && $c->session('server_time') > $server_time - 5100
		&& ($principal_active = &subs::session_principal_active($person_uuid, $device_uuid))
		&& !(($padlock_rows = &subs::db_query('select * from security where level = ?', 'padlock')->hashes)->[0])) {
		# The fast path may skip the full auth pass, but never the padlock:
		# every request refreshes session server_time, so a locked screen that
		# kept a request in flight every few seconds returned here forever and
		# was never gated ("I locked it and still have full access").
		$c->session('server_time' => $server_time);
		return $authentication;
	}

	$c->session('server_time' => $server_time);
	my $dob = $c->session('database');
	my $name = $c->param('name');
	my $warranty = $c->session('warranty');

	my $visitor = $c->tx->local_address eq $c->tx->remote_address ? 'Me' : ($c->param('manager_file') || $c->tx->remote_address);
	my $string = $app_path;
	# The Dingaling is for a visitor at the door, not the person at the machine:
	# a local session's own WebSocket and media-lock polls would otherwise ring
	# the house every few minutes. Remote visitors still get the throttled alert
	# below; a request that already carries its tab and session is not news.
	unless ($visitor eq 'Me' || ($c->stash('browser_tab_id') && ($authentication eq 'approved' || $authentication eq 'revoked'))) {
		# Not every retry deserves a Dingaling: a browser reconnecting after a
		# network change hammers this, so alert at most once per visitor per
		# few minutes. The cache row is the throttle stamp (local, unsynced).
		my ($db,$database) = &subs::database_grabber();
		my $now = &subs::rightNow();
		my $seen = $db ? &subs::db_query('select server_time from cache where context=? and uuid=? order by server_time desc limit 1', 'dingaling', $visitor)->hashes->[0] : undef;
		unless ($seen->{'server_time'} && $seen->{'server_time'} > $now - 300000) {
			if ($db) {
				&subs::db_query('delete from cache where context=? and uuid=?', 'dingaling', $visitor);
				&subs::db_query('insert into cache (uuid, context, app, server_time, timestamp) values (?,?,?,?,?)', $visitor, 'dingaling', '__president', $now, $now);
			}
			&notification_sender({ app => 'customs', role => 'citizen', type => 'authentication', title => 'Dingaling', message => $visitor . ' ' . $string, image => "/images/make believe/lock.png" },$dob);
		}
	}
	if (! -e $dob) {
		$authentication = "revoked";
	}
	else {
		my ($db,$database,$sql) = &subs::database_grabber();
		my $current_suds = eval { &subs::suds_grabber() };
		my $suds_id = $c->session('suds_id');
		# A live loopback session has no vault key to compare yet; its desk is
		# local and the encrypted features ask for the code when they need it.
		unless ($live_local || ($current_suds && $suds_id && secure_compare($suds_id, &subs::suds_id($current_suds)))) {
			$authentication = 'revoked';
		}
		# a device/person session lives only while its roster row does: revoking
		# either revokes the cookie at the next check. The fast path above reads
		# the same two rows, so reuse its answer instead of asking again.
		unless (defined $principal_active) {
			$principal_active = &subs::session_principal_active($person_uuid, $device_uuid);
		}
		$authentication = 'revoked' unless $principal_active;
		# benign: the two values are all this needs, and the uuid ensure that
		# settings_grabber would otherwise run is a write check that also flushed
		# the per-request setting memo on every request.
		my $pres_settings = &subs::settings_grabber({ app => '__president', settings => [ 'padlock_contexts', 'pl_time' ], benign => 1 });
		my $padlock_sightings = eval { return decode_json $pres_settings->{'padlock_contexts'} } || [];
		my $padlock = [];
		my $padlock_time = $server_time;
		my $padlock_state;
		if ( grep { $_ eq 'general' } @{$padlock_sightings} ) {
			# the fast path may already have read the row; reuse it when it did
			$padlock = $padlock_rows // &subs::db_query('select * from security where level = ?', 'padlock')->hashes;

			my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
			$activity_timeout = &subs::time_abbrev_translator($activity_timeout);

			# A missing stamp means this machine has never been locked since the
			# gate was set - open, not an expired lock (the same rule
			# padlock_global_locked applies). Treating undef as 0 made every
			# request look expired and started a lock out of nothing.
			my $pl_raw = $pres_settings->{'pl_time'};
			$padlock_time = (defined $pl_raw && length $pl_raw)
				? (&padlock_time_value(undef, $pl_raw) || 0)
				: $server_time;

			# What this request has already learned about the lock. The gate
			# helpers below ask the same questions; handing them this answer
			# keeps them from re-reading the row and re-decoding the contexts.
			$padlock_state = { row => $padlock->[0], contexts => $padlock_sightings };
			$c->stash('pl_time' => $padlock_time);
		}

		my $locked_now = 0;
		if ($c->session('authentication') eq 'approved' && scalar @{$padlock} > 0) {
			# the house-wide inactivity timer: only when the global stamp expired,
			# and not for a screen that was opened after a whole-house lock
			my $did_lock = 0;
			if ($server_time > $padlock_time) {
				my $dev = $device_uuid;
				my $until = $dev ? &padlock_device_until($dev) : 0;
				# An unlocked screen has its own future stamp. A screen that is
				# already locked (no stamp, or a past one) must not run the lock
				# again: the whole-house branch re-stamps pl_time = now, so the
				# very next request saw it expired and closed the same windows
				# again - a table with no fingerprint, sitting on a manager
				# page, did exactly that on every poll. Answer the gate; do not
				# re-lock what is already locked.
				my $already = ($until && $until > $server_time) ? 1 : (&padlock_locked_now($c, $dev, $padlock_state) ? 1 : 0);
				$did_lock = &lock_session($c) unless $already;
			}
			# The request that meets the expired timer is the one that locked:
			# gate it now. lock_session stamps pl_time = now, so re-checking the
			# clock a moment later could still read it as open and render the
			# page, with the lock overlay arriving after it had painted.
			$locked_now = $did_lock ? 1 : &padlock_locked_now($c, $device_uuid, $padlock_state);
			if ($locked_now) {
				my $gate_path = $app_path;
				if (!&padlock_gate_allows($gate_path)) {
					if (&padlock_gate_mode() eq 'enforce') {
						&padlock_gate_answer($c);
						return;
					}
					&padlock_gate_shadow($c);
				}
			}
		}
		if (!$locked_now && $c->session('source') eq 'ticket' && $c->session('authentication') eq 'approved') {
			my $tick = &subs::db_query('select * from tickets where uuid=?', $c->session('ticket_uuid') );
			my $ticket = $tick->hashes->[0];
			$c->stash('debriefer' => $ticket->{'debriefer'});
			if ($c->session('server_time') < $ticket->{'server_time'}) {
				# a legacy ticket may still carry the key; a retired one carries
				# nothing and the machine's vault is the key
				my $suds;
				if ($ticket->{'suds'}) {
					my $secretive = $ticket->{'secret'};
					my $ver = url_unescape `echo "$secretive" | base64 --decode`;
					my $ts = &subs::note_decrypter($ticket->{'password'},$ver);
					my $sj = decode_json $ts;
					$suds = &subs::note_decrypter($sj->{'p'}, $ticket->{'suds'});
					chomp $suds if $suds;
				}
				$suds ||= eval { &subs::suds_grabber() };
				&subs::vault_seed($suds) if $suds;
				$c->session('suds_id' => &subs::suds_id($suds)) if $suds;
				$c->session('server_time' => $server_time);
				$authentication = 'approved';
			}
			if ($ticket->{'warranty'} <= $server_time || $ticket->{'status'} ne 'active') {
				$authentication = 'revoked';
			}
			else {
				$c->session('warranty' => $ticket->{'warranty'});
			}

		}
		elsif ($c->session('warranty') < $server_time) {
			$authentication = 'revoked';
		}
	}
	unless ($authentication eq 'approved') {
		$c->session('authentication' => 'revoked');
		$c->session('bti', $c->stash('browser_tab_id'));
		my $restore_list = [];
		$c->session('database' => undef);
		$c->session('suds_id' => undef);
		unless (-e $database) {
			if ($c->param('restore_list')) {
				my $list = $c->param('restore_list');
				$restore_list = &subs::restore_list($list);
				@{$restore_list} = grep { $_->{'filename'} =~ /enc$/gi } @{$restore_list};
			}
		}
		# An XHR that meets the gate is answered JSON, not the Gate page: a stale
		# session cookie - the cookieless request a webview sends as it wakes - that
		# came back as HTML was parsed as data and froze the viewer (appts became
		# undefined, so the poll threw and the pan threw). A 401 lets the caller see it.
		if (($c->req->headers->header('X-Requested-With') // '') =~ /XMLHttpRequest/i) {
			$c->res->code(401);
			$c->render(json => { error => 'session lapsed', authentication => 'revoked' });
			$c->rendered;
			return;
		}
		if ($c->param('neighbour')) {
			$c->render(json => { name => $name, purpose => $device, 'restore_list' => $restore_list, signatorial => &subs::signatorial_designer() });
		}
		else {
			$c->render(
				template => 'gate',
				layout => 'gate',
				restore_list => $restore_list,
				webauthn_available => (scalar @{ &webauthn::credentials() } ? 1 : 0),
				# no home path on the gate: shown before anyone has signed in
				start_dir => '',
				config => { 'gate' => {'background_colour' => $config->{'gate'}->{'background_colour'} } },
			);
		}
	}
	return $authentication;
}

1;
