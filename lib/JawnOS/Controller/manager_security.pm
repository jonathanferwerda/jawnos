package Manager;

# manager_security: route actions moved out of Manager.pl, one sub per route so a
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

use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# GET /manager/security
sub action_37688 {
	my $c = shift;
	# Citizen-only, and the padlock's own unlock check sits on top of it. The
	# hook refuses a lower tier first; this guard keeps the page shut if the
	# hook's table ever changes.
	unless (($c->session('privilege') || '') eq 'citizen') {
		return $c->render(template => 'guest_layouts/denial', layout => undef,
			message => '... access denied.', status => 403);
	}
	# The app opens locked: only a grant minted by a fingerprint - this phone's
	# own reader, or the screen's padlock confirmed on a paired device - draws the
	# contents. Rotating the key and the share actions ask again on top of this.
	my $timestamp = $c->param('timestamp');
	unless (&media_unlock_open($c, 'security')) {
		my $locked = $c->render_to_string(
			template => 'security_locked',
			layout => undef,
			local_key => (&biometric_enrolled_for($c->session('device_uuid') || '') ? 1 : 0),
			reader => (&fingerprint_available() ? 1 : 0),
			device_uuid => ($c->session('device_uuid') || ''),
		);
		$locked = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'security', contents => $locked }, $timestamp) if $c->param('window_maker');
		return $c->render(json => { ok => 1, locked => 1, html => $locked });
	}
	my $contents = &security_initializer($c);

	if ($c->param('window_maker')) {
		$contents->{'html'} = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'security', contents => $contents->{'html'} }, $timestamp);
	}

	$c->render(json => $contents);

}

# POST /manager/security/signatorial/selection
sub action_37811 {
	my $c = shift;
	my $file = $c->param('file');
	$config->{'signatorial'} = $file;
	my $jconfig = encode_json $config;
	write_file('./config.json', $jconfig);
	my $pp = `cat ./config.json | json_pp`;
	write_file('./config.json', $pp);

	my $contents = &security_initializer($c);
	$c->render(json => $contents);
}

# POST /manager/security/neighbour_link_assign
sub action_37823 {
	my $c = shift;
	my $remote_address = $c->param('remote_address');
	my $local_address = $c->param('local_address');
	my $privilege = $c->param('privilege');
	my $name = $c->param('my_name');
	my $credential = $c->param('credential');
	my $data = {
		initiator => $remote_address,
		initiated => $local_address,
		server_time => &subs::rightNow(),
		name => $name,
		status => $privilege,
		uuid => &subs::random_string_creator(252),
		credential => &subs::encrypter(&subs::session_suds($c),$credential)
	};
	&subs::db_insert('neighbour_link', $data);
	$c->render('text' => 'ok');
}

# POST /manager/security/neighbour_link_privilege
sub action_37842 {
	my $c = shift;
	my $privilege = $c->param('privilege');
	my $uuid = $c->param('uuid');
	my $server_time = &subs::rightNow();
	if ($uuid) {
		&subs::db_update('neighbour_link', { status => $privilege, server_time => $server_time }, { uuid => $uuid });
	}
	$c->render(text => &security_initializer($c));
}

# POST /manager/security/device_revoke
sub action_38137 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { html => '<p>citizen only</p>' });
		return;
	}
	unless (&security_action_open($c)) {
		$c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
		return;
	}
	my $uuid = $c->param('uuid');
	&subs::db_delete('paired_devices', { uuid => $uuid }) if $uuid;
	&subs::house_key_share_revoke_device($uuid) if $uuid;
	&subs::db_delete('security', { level => 'padlock_device', uuid => $uuid }) if $uuid;
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'padlock_device_time', $uuid) if $uuid;
	$c->render(json => &security_initializer($c));
}

# POST /manager/security/person_assign
sub action_38154 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0, error => 'citizen only' });
		return;
	}
	my $device_uuid = $c->param('device_uuid') // '';
	my $person_uuid = $c->param('person_uuid') // '';
	my ($ok, $why) = &subs::person_assign_check($device_uuid, $person_uuid, $c->session('device_uuid') || '');
	unless ($ok) { $c->render(json => { ok => 0, error => $why }); return; }
	&subs::db_update('paired_devices', { person_uuid => $person_uuid, server_time => &subs::rightNow() }, { uuid => $device_uuid });
	my $sec = &security_initializer($c);
	$c->render(json => { ok => 1, html => $sec->{'html'} });
}

# POST /manager/security/person_create
sub action_38168 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0, error => 'citizen only' });
		return;
	}
	my $name = &subs::unformat_name($c->param('name') // '');
	my $privilege = lc($c->param('privilege') // 'resident');
	$privilege = 'resident' unless $privilege =~ /^(?:citizen|resident|guest)$/;
	unless (length $name) { $c->render(json => { ok => 0, error => 'name' }); return; }
	my $now = &subs::rightNow();
	my $uuid = &subs::random_string_creator(25);
	my $made = &subs::db_insert('people', {
		uuid => $uuid,
		name => $name,
		privilege => $privilege,
		status => 'active',
		created => $now,
		server_time => $now,
	});
	unless ($made) { $c->render(json => { ok => 0 }); return; }
	my $sec = &security_initializer($c);
	$c->render(json => { ok => 1, uuid => $uuid, html => $sec->{'html'} });
}

# POST /manager/security/shares/create
sub action_38192 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0 });
		return;
	}
	unless (&security_action_open($c)) {
		$c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
		return;
	}
	my $suds = &subs::session_suds($c);
	unless ($suds && length $suds) { $c->render(json => { ok => 0 }); return; }
	my ($k, $n) = &subs::shamir_policy();
	my $shares = &subs::shamir_split($suds, $k, $n);
	unless ($shares) { $c->render(json => { ok => 0 }); return; }
	# the policy is public and syncs; the shares are shown once and stored nowhere
	my $now = &subs::rightNow();
	&subs::db_query('delete from settings where app = ? and setting = ?', '__president', 'shamir');
	&subs::db_insert('settings', { app => '__president', setting => 'shamir', device => 'all', value => "$k:$n", timestamp => $now, server_time => $now });
	my @codes = map { &subs::shamir_share_encode_paper($_) } @$shares;
	my $qr = &subs::shamir_qr_save(\@codes, 'paper shares');
	my $sec = &security_initializer($c);
	$c->render(json => { ok => 1, k => $k, n => $n, shares => \@codes, qr => $qr, html => $sec->{'html'} });
}

# POST /manager/security/person_revoke
sub action_38216 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0, error => 'citizen only' });
		return;
	}
	unless (&security_action_open($c)) {
		$c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
		return;
	}
	my $person_uuid = $c->param('person_uuid') // '';
	my ($ok, $why) = &subs::person_revoke_check($person_uuid, $c->session('device_uuid') || '');
	unless ($ok) { $c->render(json => { ok => 0, error => $why }); return; }
	my $result = &subs::person_revoke($person_uuid);
	unless ($result) { $c->render(json => { ok => 0, error => 'not revoked' }); return; }
	my $sec = &security_initializer($c);
	$c->render(json => { ok => 1, revoked => $result, html => $sec->{'html'} });
}

# POST /manager/security/shares/key
sub action_38234 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0 });
		return;
	}
	my $device_uuid = $c->session('device_uuid') || '';
	unless ($device_uuid) { $c->render(json => { ok => 0, error => 'no device' }); return; }
	my $raw = eval { decode_base64($c->param('share_pubkey') // '') };
	unless (defined $raw && length($raw) == 32) { $c->render(json => { ok => 0, error => 'bad key' }); return; }
	&subs::db_update('paired_devices', { share_pubkey => encode_base64($raw, ''), server_time => &subs::rightNow() }, { uuid => $device_uuid });
	$c->render(json => { ok => 1 });
}

# Split this house's key and wrap a share to each chosen device. The shares a
# device takes are stored sealed to its own X25519 key; any share left is
# returned once as paper. One wrapped share per person.
# POST /manager/security/shares/wrap
sub action_38250 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0 });
		return;
	}
	unless (&security_action_open($c)) {
		$c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
		return;
	}
	my $suds = &subs::session_suds($c);
	unless ($suds && length $suds) { $c->render(json => { ok => 0 }); return; }
	my @holders;
	my $picked = $c->param('holders') // '';
	if ($picked =~ /\S/) {
		@holders = grep { /\S/ } split /[\s,]+/, $picked;
	}
	else {
		# one device per person among the devices that registered a share key
		my $rows = eval { &subs::db_query("select uuid, person_uuid from paired_devices where status = 'active' and share_pubkey is not null and share_pubkey != '' order by last_seen desc, server_time desc")->hashes } || [];
		my %seen;
		foreach my $d ( @{$rows} ) {
			my $key = ($d->{'person_uuid'} || '') ne '' ? 'p:' . $d->{'person_uuid'} : 'd:' . $d->{'uuid'};
			next if $seen{$key}++;
			push @holders, $d->{'uuid'};
		}
	}
	my $made = &subs::house_key_share_create_set($suds, \@holders);
	unless ($made) { $c->render(json => { ok => 0 }); return; }
	my $qr = (@{ $made->{'paper'} || [] }) ? &subs::shamir_qr_save($made->{'paper'}, 'paper shares') : undef;
	my $sec = &security_initializer($c);
	$c->render(json => {
		ok => 1,
		set_id => $made->{'set_id'},
		k => $made->{'k'},
		n => $made->{'n'},
		assigned => $made->{'assigned'},
		paper => $made->{'paper'},
		qr => $qr,
		skipped => $made->{'skipped'},
		html => $sec->{'html'},
	});
}

# The wrapped shares this device holds. They are useless to any other device.
# POST /manager/security/shares/mine
sub action_38294 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0 });
		return;
	}
	my $device_uuid = $c->session('device_uuid') || '';
	unless ($device_uuid) { $c->render(json => { ok => 0, error => 'no device' }); return; }
	# a request names the set it was made against; a holder may hold shares in
	# several sets, so let the caller name the one it means
	my $set_id = $c->param('set_id') || &subs::house_key_share_set_current();
	my $rows = &subs::house_key_share_for_device($device_uuid, $set_id);
	my ($k, $n) = &subs::shamir_policy();
	$c->render(json => {
		ok => 1,
		set_id => $set_id,
		k => $k,
		n => $n,
		shares => [ map { { set_id => $_->{'set_id'}, share_index => $_->{'share_index'}, wrapped => $_->{'wrapped'} } } @{$rows} ],
	});
}

# A recovering machine is asking. Its public key is public; the holders answer
# with blobs this server cannot open.
# POST /manager/security/shares/requests
sub action_38317 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0 });
		return;
	}
	&subs::house_key_share_cleanup();
	my $rows = &subs::house_key_share_requests_open();
	my $out = [];
	foreach my $r ( @{$rows} ) {
		push @{$out}, {
			uuid => $r->{'uuid'},
			code => $r->{'code'},
			name => $r->{'name'},
			need => $r->{'need'},
			have => $r->{'available'},
			set_id => $r->{'set_id'},
			asker_pubkey => $r->{'asker_pubkey'},
			created => $r->{'created'},
		};
	}
	$c->render(json => { ok => 1, requests => $out });
}

# POST /manager/security/shares/release
sub action_38340 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0, error => 'citizen only' });
		return;
	}
	unless (&security_action_open($c)) {
		$c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
		return;
	}
	my $device_uuid = $c->session('device_uuid') || '';
	my $request_uuid = $c->param('request_uuid') // '';
	my $share_index = $c->param('share_index');
	my $wrapped = $c->param('wrapped') // '';
	my ($ok, $why) = &subs::house_key_share_release_add($request_uuid, $device_uuid, $share_index, $wrapped);
	$c->render(json => { ok => $ok ? 1 : 0, error => $why });
}

# POST /manager/security/recovery/create
sub action_38357 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0 });
		return;
	}
	unless (&security_action_open($c)) {
		$c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
		return;
	}
	my $code = &subs::recovery_code_make();
	my $canon = &subs::recovery_code_clean($code);
	my $suds = &subs::session_suds($c);
	my $sealed = ($suds && length $suds) ? &subs::note_encrypter($canon, $suds) : undef;
	unless ($sealed) { $c->render(json => { ok => 0 }); return; }
	my $now = &subs::rightNow();
	&subs::db_query('delete from settings where app = ? and setting = ?', '__president', 'recovery');
	&subs::db_query('delete from settings where app = ? and setting = ?', '__president', 'recovery_stale');
	&subs::db_insert('settings', { app => '__president', setting => 'recovery', device => 'all', value => $sealed, timestamp => $now, server_time => $now });
	my $sec = &security_initializer($c);
	$c->render(json => { ok => 1, code => $code, html => $sec->{'html'} });
}

# A phone can die. The paper code (or three shares) is the other way past this
# app's lock, and it is the same secret that already opens the house, so a person
# who has lost their only fingerprint is not locked out of rotating the key.
# POST /manager/security/confirm_code
sub action_38382 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') { $c->render(json => { ok => 0, error => 'not signed in' }); return; }
	my $raw_code = $c->param('code') // '';
	my $code = &subs::recovery_code_clean($raw_code);
	my @share_codes = grep { /\S/ } split /[\s,]+/, $raw_code;
	unless (length $code >= 20 || @share_codes) { $c->render(json => { ok => 0, error => 'not accepted' }); return; }
	my $ip = $c->tx->remote_address;
	my $now = &subs::rightNow();
	my $tries = &subs::db_query('select count(*) as n from cache where context = ? and uuid like ? and server_time > ?', 'security_code_attempt', $ip . ':%', $now - 3600000)->hash->{'n'} || 0;
	if ($tries >= 5) { $c->render(json => { ok => 0, error => 'too many' }); return; }
	&subs::db_insert('cache', { uuid => $ip . ':' . &subs::random_string_creator(12), context => 'security_code_attempt', app => '__president', server_time => $now, timestamp => $now });
	my $suds;
	if (length $code >= 20) {
		my $row = &subs::db_query('select value from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'recovery')->hashes->[0];
		$suds = eval { &subs::note_decrypter($code, $row->{'value'}) } if $row && $row->{'value'};
	}
	if (!(defined $suds && length $suds) && @share_codes) { $suds = &subs::shamir_open_shares(\@share_codes); }
	$suds =~ s/\s+$// if $suds;
	unless ($suds && &subs::suds_current($suds)) { $c->render(json => { ok => 0, error => 'not accepted' }); return; }
	# the code is the house's own secret, so it stands in for the print
	my $contexts = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'padlock_contexts' }) } || [];
	unless (grep { $_ eq 'security' } @{$contexts}) {
		push @{$contexts}, 'security';
		&subs::setting_setter({ app => '__president', setting => 'padlock_contexts', value => encode_json $contexts });
	}
	my $device = &media_unlock_device($c);
	my $token = length $device ? &media_unlock_store('security', $device, &media_unlock_tab($c)) : '';
	&subs::db_query('delete from cache where context = ? and uuid like ?', 'security_code_attempt', $ip . ':%');
	$log->info('security: app opened with the paper code from ' . $ip);
	$c->render(json => { ok => ($token ? 1 : 0), unlock => $token });
}

# POST /manager/security/rotate_key
sub action_38414 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0 });
		return;
	}
	unless (&security_action_open($c)) {
		$c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
		return;
	}
	my $result = &subs::rotate_house_key();
	if ($result->{'ok'}) {
		# the sweep re-sealed the database; the sealed files on disk go to the
		# queue, which walks them resumably and re-seals each one in place, and
		# the push hands the new key to every linked machine the same sweep
		eval { &subs::minion_grabber()->enqueue('folders_reseal' => [ { before => $result->{'at'}, budget => 600 } ] => { attempts => 2 }) };
		eval { &subs::minion_grabber()->enqueue('key_push' => [ {} ] => { attempts => 3 }) };
	}
	my $sec = &security_initializer($c);
	$c->render(json => {
		ok => $result->{'ok'} ? 1 : 0,
		summary => { settings => $result->{'settings'}, security => $result->{'security'}, links => $result->{'links'} },
		html => $sec->{'html'}
	});
}

# POST /manager/security/legacy_reseal
sub action_38439 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0 });
		return;
	}
	unless (&security_action_open($c)) {
		$c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
		return;
	}
	my $local = &subs::legacy_reseal();
	my $mesh = &subs::legacy_reseal_mesh();
	$c->render(json => { ok => $local->{'ok'} ? 1 : 0, local => $local, mesh => $mesh });
}

# POST /manager/security/device_request_decide
sub action_38610 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0, html => '<p>citizen only</p>' });
		return;
	}
	my $uuid = $c->param('uuid') || '';
	my $decision = ($c->param('decision') || '') eq 'approve' ? 'approve' : 'deny';
	my $now = &subs::rightNow();
	my $row = ($uuid && &subs::db_select('device_requests', undef, { uuid => $uuid, status => 'pending' })->hashes->[0]);
	if ($row && $row->{'server_time'} > $now - 3600000) {
		# A synced copy may reach an approving machine before the new columns do:
		# the request's own app_pubkey is enough to recognise an app request even
		# when `kind` is still blank there. Without this, the old pairing branch
		# marked it approved and dropped the key.
		my $is_app = ((($row->{'kind'} || '') eq 'app') || (($row->{'app_pubkey'} || '') ne '')) ? 1 : 0;
		if ($is_app && $decision eq 'approve') {
			# An app key joins an existing paired device; it does not mint a new one.
			my $target = $row->{'device_uuid'} || '';
			my $device = ($target && &subs::db_select('paired_devices', undef, { uuid => $target, status => 'active' })->hashes->[0]);
			my $app_pubkey = $row->{'app_pubkey'} || '';
			my $app_kind = ($row->{'app_kind'} || 'ed25519') eq 'ec' ? 'ec' : 'ed25519';
			if ($device && $app_pubkey) {
				&subs::db_update('paired_devices', { app_pubkey => $app_pubkey, app_kind => $app_kind, kind => 'app', server_time => $now }, { uuid => $target });
				&subs::db_update('device_requests', { status => 'approved', device_uuid => $target, server_time => $now }, { uuid => $uuid });
				$log->info('app gate: app key approved for ' . ($device->{'name'} || $target) . ' from ' . ($c->tx->remote_address || '?'));
			}
			else {
				$log->info('app gate: app approval incomplete for ' . ($target || '?')
					. ' (device ' . ($device ? 1 : 0) . ', key ' . length($app_pubkey) . ')');
			}
		}
		elsif ($decision eq 'approve') {
			my $person_uuid = $c->session('person_uuid') || &subs::people_owner_ensure();
			my $device_uuid = &device_store_pubkey($row->{'pubkey'}, $row->{'name'}, $row->{'agent'}, $person_uuid);
			if ($device_uuid) {
				&subs::db_update('device_requests', { status => 'approved', device_uuid => $device_uuid, server_time => $now }, { uuid => $uuid });
			}
		}
		else {
			&subs::db_update('device_requests', { status => 'denied', server_time => $now }, { uuid => $uuid });
		}	}
	my $sec = &security_initializer($c);
	$c->render(json => { ok => 1, html => $sec->{'html'} });
}

# POST /manager/security/neighbour_link_delete
sub action_38655 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	if ($uuid) {
		&subs::db_delete('neighbour_link', { uuid => $uuid });
	}
	$c->render(text => &security_initializer($c));
}

# POST /manager/security/padlock
sub action_38663 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $combo = $c->param('combo');
	my $pulled = $c->param('pulled');
	my ($j_pulled,$salt,$salty,$saved_pulled);
	my ($db) = &subs::database_grabber();
	my $padlocker = &subs::db_select('security', undef, { level => 'padlock' })->hashes || [];
	my $padlock = $padlocker->[0];
	$pulled = eval { return decode_json $pulled } || [];
	if (scalar @{$padlocker} > 0 && scalar @{$pulled} == 0) {

		$c->render(json => { status => 'failed cuz 0'});
	}
	if (scalar @{$pulled} > 0 && scalar @{$padlocker} > 0) {
		$j_pulled = eval { return encode_json $pulled };
		$salty = join '', @{$pulled};
		$saved_pulled = &subs::note_decrypter($salty . &subs::session_suds($c) . $salty, $padlock->{'credential'});
	}
	if ((scalar @{$padlocker} == 0) || (secure_compare( $j_pulled, $saved_pulled )) ) {
		$combo = eval { return decode_json $combo };
		$salt = join '', @{$combo};
		my $combination = eval { return encode_json $combo };
		$combo = &subs::note_encrypter($salt . &subs::session_suds($c) . $salt,$combination);
		my $activity_timeout = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '2h';
		$activity_timeout = &subs::time_abbrev_translator($activity_timeout);
		$c->session('padlock', $activity_timeout);
		&subs::db_delete('security', { level => 'padlock' });
		&subs::db_insert('security', { level => 'padlock', credential => $combo, timestamp => $timestamp, server_time => &subs::rightNow(), uuid => &subs::random_string_creator(30) });
		$c->render(json => { status => 'saved' });
	}
	else {
		$c->render(json => { status => 'failed cuz different'});
	}
}

# POST /manager/security/padlock/delete
sub action_38698 {
	my $c = shift;
	&subs::db_delete('security', { level => 'padlock' });
	&subs::db_delete('security', { level => 'padlock_device' });
	&subs::db_query('delete from settings where app = ? and setting = ?', '__president', 'padlock_device_time');
	&subs::db_delete('settings', { app => '__president', setting => 'pl_time' });
	&subs::db_delete('settings', { app => '__president', setting => 'padlock_pulls' });
	&Websocket::send('server', { padlock_open => 1, mode => 'locker', target => '', timestamp => &subs::rightNow() });
	$c->render(text => 'ok');
}

# The gate is a row, not a combination any more: the dial and the camera key
# are gone, so there is nothing to set. Enabling it makes the server deny
# everything behind it; the phone's signed challenge (and the paper code) are
# the ways in.
# POST /manager/security/gate/enable
sub action_38712 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		return $c->render(json => { ok => 0, error => 'citizen only' });
	}
	my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes->[0];
	unless ($padlock) {
		my $now = &subs::rightNow();
		&subs::db_insert('security', { level => 'padlock', credential => '', timestamp => $now, server_time => $now, uuid => &subs::random_string_creator(30) });
	}
	my $contexts = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'padlock_contexts' }) } || [];
	unless (scalar @{$contexts}) {
		&subs::setting_setter({ app => '__president', setting => 'padlock_contexts', value => '["general"]' });
	}
	# A fresh gate gets a full inactivity window, so the timer has a baseline
	# and turning it on does not read as an expired lock on the next request.
	my $pl = &subs::db_query('select server_time from settings where app = ? and setting = ? limit 1', '__president', 'pl_time')->hashes->[0];
	unless ($pl) {
		my $window = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
		$window = abs &subs::time_abbrev_translator($window);
		&subs::setting_setter({ app => '__president', setting => 'pl_time', value => &subs::rightNow() + $window });
	}
	# an explicit Turn the gate on/off is the house's choice from now on; the
	# boot-time default only fills a house that has never made one
	&subs::setting_setter({ app => '__president', setting => 'padlock_gate_initialized', value => 'yes' });
	my $sec = &security_initializer($c);
	&Websocket::send('server', { padlock_gate => 1, timestamp => &subs::rightNow() });
	$c->render(json => { ok => 1, html => $sec->{'html'}, has_padlock => 1 });
}

# POST /manager/security/gate/disable
sub action_38741 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		return $c->render(json => { ok => 0, error => 'citizen only' });
	}
	# Turning the lock off is the dangerous direction, so it asks for the person;
	# turning it on does not, which keeps a lost phone from leaving you unlocked.
	unless (&security_action_open($c)) {
		return $c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
	}
	&subs::db_delete('security', { level => 'padlock' });
	&subs::db_delete('security', { level => 'padlock_device' });
	&subs::db_query('delete from settings where app = ? and setting = ?', '__president', 'padlock_device_time');
	&subs::db_delete('settings', { app => '__president', setting => 'pl_time' });
	&subs::db_delete('settings', { app => '__president', setting => 'padlock_pulls' });
	&subs::setting_setter({ app => '__president', setting => 'padlock_gate_initialized', value => 'yes' });
	&Websocket::send('server', { padlock_open => 1, mode => 'locker', target => '', timestamp => &subs::rightNow() });
	&Websocket::send('server', { padlock_gate => 0, timestamp => &subs::rightNow() });
	my $sec = &security_initializer($c);
	$c->render(json => { ok => 1, html => $sec->{'html'}, has_padlock => 0 });
}

# Lockdown's one way forward: a fresh fingerprint on this device reveals the
# Enemy's running app. It does not lift the lockdown - other apps stay shut and
# the grant lapses on its own - so stopping that appointment is still what ends
# the lockdown.
# POST /manager/security/lockdown_unlock
sub action_38766 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		return $c->render(json => { ok => 0, error => 'citizen only' });
	}
	unless (&subs::lockdown_active()) {
		return $c->render(json => { ok => 0, error => 'there is no lockdown' });
	}
	my $enemies = &subs::lockdown_enemy_apps();
	unless (scalar keys %{$enemies}) {
		return $c->render(json => { ok => 0, error => 'no hidden appointment to reveal' });
	}
	unless (&security_action_open($c)) {
		return $c->render(json => { ok => 0, error => 'confirm with your fingerprint first', need_biometric => 1 });
	}
	# Keyed the same way the visibility rule reads it (subs::device_setter), so
	# app_hidden_now finds the grant without a request's session uuid.
	my $until = &subs::lockdown_reveal_store();
	&Websocket::send('server', { console => &Websocket::console_command('calculator')});
	$c->render(json => { ok => 1, until => $until, apps => [ sort keys %{$enemies} ] });
}

# POST /manager/security/padlock_pull
sub action_38787 {
	my $c = shift;
	$c->render(json => { status => 'fail', error => 'the dial is disabled' });
}

# The camera key is gone: the signed challenge is the only remote unlock.
# Kept so an old tab gets a clear answer instead of a 404.
# POST /manager/security/padlock_watch
sub action_39632 {
	my $c = shift;
	$c->render(json => { ok => 0, error => 'the camera key is disabled' });
}

# The person pressed Unlock on a locked screen. This writes a short-lived
# request and asks every paired phone/tablet to confirm it with a fingerprint.
# The route only sends the request; it cannot unlock anything by itself, and a
# device that is already open is never sent away from the page it is on.
# POST /manager/security/padlock_phone_show
sub action_39640 {
	my $c = shift;
	my $mode = $c->param('mode') || 'locker';
	$mode = 'locker' unless $mode =~ /^(?:locker|gallery|music|folders|security|private)$/;
	my $target = $c->param('target') || '';
	$target = '' unless $target =~ /^[A-Za-z0-9]{8,64}$/;
	my $device_name = '';
	if ($target) {
		my $device = &subs::db_select('paired_devices', undef, { uuid => $target, status => 'active' })->hashes->[0];
		$device_name = $device->{'name'} || '' if $device;
	}
	# the screen that pressed the button is not asked to confirm its own request
	my $source_device = $c->param('device_uuid') || $c->session('device_uuid') || '';
	$source_device = '' unless $source_device =~ /^[A-Za-z0-9]{8,64}$/;
	my $source = &subs::signatorial_designer();
	my $source_hostname = &subs::machine_name() || '';
	my $host = `hostname`;
	chomp $host;
	$source_hostname .= ' (' . $host . ')' if $host && $host ne $source_hostname;
	$source_hostname =~ s/[\r\n\t]//g;
	$source_hostname = substr($source_hostname, 0, 120);
	my $source_tab = $c->param('browser_tab_id') || '';
	$source_tab = '' unless $source_tab =~ /^[A-Za-z0-9_-]{1,64}$/;
	my $request_id = &padlock_request_store($target, $mode, $source, undef, $device_name, $source_device, $source_hostname, $source_tab);
	$log->info('padlock: prompt asked for ' . ($target || 'house') . ($device_name ? ' (' . $device_name . ')' : '') . ' by ' . ($source_device || '?') . ' on ' . $source_hostname . ' id=' . $request_id);
	&Websocket::send('server', { padlock_key_show => 1, prompt => 1, request_id => $request_id, device_name => $device_name, source_device => $source_device, source => $source, source_hostname => $source_hostname, house => (($target || '') eq '' ? 1 : 0), mode => $mode, target => $target, show => 1, timestamp => &subs::rightNow() });
	# another machine's screens are part of the house too
	unless (($c->param('remoted') || '') eq 'yes' || ($c->param('dissemination') || '') eq 'yes') {
		&padlock_key_show_relay($c, $mode, $target, 1, 1, $request_id, $device_name, $source_device, $source_hostname);
	}
	$c->render(json => { ok => 1, mode => $mode, target => $target, request_id => $request_id });
}

# "Not now", or a prompt that has gone stale: clear the request and tell every
# screen that showed it, so the print prompt does not linger elsewhere.
# POST /manager/security/padlock_request_cancel
sub action_39674 {
	my $c = shift;
	my $id = $c->param('request_id') || '';
	&padlock_request_clear_id($id);
	$c->render(json => { ok => 1, request_id => $id });
}

# The app window, the screen or the tree is going away: drop this device's
# media grant and tell the window that asked to show its locked view. The delete
# is keyed by device, so another screen - or a peer - keeps what it had.
# POST /manager/security/media_lock
sub action_39683 {
	my $c = shift;
	my $device = &media_unlock_device($c);
	my $app = $c->param('app') || '';
	$app = '' unless $app =~ /^(?:gallery|music|folders|private)$/;
	my $tab = $c->param('browser_tab_id') || '';
	$tab = '' unless $tab =~ /^[A-Za-z0-9_-]{1,64}$/;
	&media_unlock_clear($device, $app) if length $device;
	if ($app eq 'private') {
		# A deliberate Hide, or the five-minute idle timer: clear the grant,
		# close this tab's private windows, and redraw the lists.
		&private_relock($c, $tab, { close_windows => 1 });
	}
	else {
		my @apps = $app ? ($app) : (@media_unlock_apps, 'private');
		foreach my $a ( @apps ) {
			my $cmd = ($a eq 'private') ? &Websocket::console_command('jawnosPrivateRefresh', 0) : &Websocket::console_command('jawnosMediaLockdown', $a);
			&Websocket::send('server', { console => $cmd, browser_tab_id => $tab }) if length $tab;
		}
	}
	$c->render(json => { ok => 1, app => $app, device => $device });
}

1;
