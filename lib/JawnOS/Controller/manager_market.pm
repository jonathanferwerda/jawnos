package Manager;

# manager_market: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/market
sub action_3422 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = &market_maker($c);
	my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'market', contents => $contents }, $timestamp);
	$c->render(json => { window => $window, html => $contents });
}

# POST /manager/market/item_add
sub action_3429 {
	my $c = shift;
	my $text = $c->param('text') || '';
	$text =~ s/^\s+|\s+$//g;
	my $list_name = $c->param('list') || '';
	my $list_key = &market_list_key($list_name);
	my $vendor = &subs::unformat_name($c->param('vendor')) || '';
	return $c->render(json => { error => 'empty' }) unless $text ne '';
	my $list = &market_list();
	my $item = {
		uuid => &subs::random_string_creator(21),
		text => $text,
		kind => &market_item_due($text) ? 'need' : 'want',
		vendor => $vendor,
		list => $list_key,
		timestamp => &subs::rightNow(),
	};
	unshift @{$list}, $item;
	&market_save_list($list);
	&market_lists_touch_vendor($list_key, &subs::format_name($list_name), $vendor) if $list_key && $vendor;
	$c->render(json => { item => $item });
}

# POST /manager/market/item_kind
sub action_3451 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $kind = ($c->param('kind') || '') eq 'need' ? 'need' : 'want';
	my $list = &market_list();
	my $found;
	foreach my $it ( @{$list} ) {
		if (($it->{'uuid'} || '') eq $uuid) { $it->{'kind'} = $kind; $found = 1; }
	}
	&market_save_list($list) if $found;
	$c->render(json => { uuid => $uuid, kind => $kind });
}

# POST /manager/market/item_delete
sub action_3463 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $list = &market_list();
	my @kept = grep { ($_->{'uuid'} || '') ne $uuid } @{$list};
	&market_save_list(\@kept);
	$c->render(json => { uuid => $uuid });
}

# Tick an item off (pick) or drop it in the cart. Checkout turns the cart into
# purchases - each on the item's own app, so a house item app is born here - and
# Cancel just empties the cart back onto the list.
# POST /manager/market/item_flag
sub action_3474 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $is_cart = ($c->param('flag') || '') eq 'cart' ? 1 : 0;
	my $on = $c->param('on') ? 1 : 0;
	my $key = $is_cart ? 'cart' : 'picked';
	my $list = &market_list();
	my $found;
	foreach my $it ( @{$list} ) {
		next unless ($it->{'uuid'} || '') eq $uuid;
		if ($on) { $it->{$key} = 1; } else { delete $it->{$key}; }
		$found = 1;
	}
	&market_save_list($list) if $found;
	$c->render(json => { uuid => $uuid, flag => $key, on => $on });
}

# POST /manager/market/cancel
sub action_3490 {
	my $c = shift;
	my $list = &market_list();
	foreach my $it ( @{$list} ) { delete $it->{'cart'}; }
	&market_save_list($list);
	$c->render(json => { ok => 1 });
}

# POST /manager/market/checkout
sub action_3497 {
	my $c = shift;
	my $vendor_default = &subs::unformat_name($c->param('vendor')) || '';
	my $list = &market_list();
	# The cart leaves the list here, but nothing is written to the warehouse: the
	# transaction form opens filled with these lines and its Save records them,
	# so the quantity and the packaging are what the person actually bought.
	my @kept = grep { !$_->{'cart'} } @{$list};
	&market_save_list(\@kept);
	# The money side: one expense transaction on the list's category, handed to
	# the person to check and save. Each line carries record_item, so saving it
	# writes the purchase (and its stock move) with the edited quantity/unit.
	my $category = &market_list_key($c->param('list') || '');
	my (@lines, $total, $account, $vendor);
	foreach my $it ( @{$list} ) {
		next unless $it->{'cart'};
		$category = $it->{'list'} if $category eq '' && ($it->{'list'} || '') ne '';
		$account = $it->{'account'} if !$account && ($it->{'account'} || '') ne '';
		$vendor = $it->{'vendor'} if !$vendor && ($it->{'vendor'} || '') ne '';
		my $qty = ($it->{'quantity'} || 1) + 0;
		my $price = ($it->{'price'} || 0) + 0;
		$total += $price;
		push @lines, {
			uuid => &subs::random_string_creator(12),
			item => &subs::format_name($it->{'text'}),
			quantity => $qty,
			amount => $price,
			tax => 0,
			aux => 0,
			total => $price,
			unit => ($it->{'unit'} || 'each'),
			state => 'delivered',
			record_item => 'on',
		};
	}
	$vendor ||= $vendor_default;
	$category ||= &subs::unformat_name($lines[0]->{'item'}) if scalar @lines;
	$account ||= 'cash';
	my $storage;
	if (scalar @lines) {
		my %mov;
		foreach my $l ( @lines ) {
			$mov{ $l->{'uuid'} } = {
				item => $l->{'item'}, quantity => $l->{'quantity'},
				amount => $l->{'amount'}, tax => $l->{'tax'},
				aux => $l->{'aux'}, total => $l->{'total'},
				unit => $l->{'unit'}, state => $l->{'state'},
				record_item => 'on'
			};
		}
		$mov{'totals'} = { uuid => $lines[0]->{'uuid'}, vendor => $vendor, information => 'none', amount => $total, tax => 0, aux => 0, total => $total };
		$storage = { expense => \%mov };
	}
	$c->render(json => {
		items => scalar @lines,
		transaction => { app => $category, account => $account, vendor => $vendor, total => $total, storage => $storage },
	});
}

# Add a packaging/unit from the form that needs it. The new measure is saved so
# the picker offers it next time, and when the item is known the packaging is
# recorded on the item too (its `each` is what a restock plan counts).
# POST /manager/market/packaging_add
sub action_3600 {
	my $c = shift;
	my $name = $c->param('name') || '';
	$name =~ s/^\s+|\s+$//g;
	return $c->render(json => { error => 'name the packaging' }) unless $name =~ /\S/;
	my $each = ($c->param('each') || '') =~ /[0-9]/ ? 0 + $c->param('each') : 1;
	my $key = &subs::unformat_name($name);
	$key = 'pack' unless length $key;
	my $measures = &measures_all();
	my $uuid;
	my $exists = 0;
	foreach my $k ( keys %{$measures} ) {
		next unless lc($k) eq $key || lc($measures->{$k}->{'name'} || '') eq lc($name);
		$uuid = $measures->{$k}->{'uuid'};
		$key = $k;
		$exists = 1;
		last;
	}
	my $stored = eval { return decode_json &subs::setting_grabber({ app => 'measures', setting => 'measures' }) } || {};
	unless ($exists) {
		$uuid = &subs::random_string_creator(26);
		$stored->{$key} = { %{ $gb::measures->{$key} || {} }, %{ $stored->{$key} || {} }, uuid => $uuid, name => $name };
		&subs::setting_setter({ app => 'measures', setting => 'measures', value => encode_json($stored) });
	}
	elsif (!$uuid) {
		$uuid = &subs::random_string_creator(26);
		$stored->{$key} = { %{ $gb::measures->{$key} || {} }, %{ $stored->{$key} || {} }, uuid => $uuid };
		&subs::setting_setter({ app => 'measures', setting => 'measures', value => encode_json($stored) });
	}
	my $item = &subs::unformat_name($c->param('item'));
	if ($item ne '') {
		my $packaging = eval { return decode_json &subs::setting_grabber({ app => $item, setting => 'packaging' }) } || {};
		$packaging->{$uuid} = { uuid => $uuid, name => $name, quantity => $each };
		&subs::setting_setter({ app => $item, setting => 'packaging', value => encode_json($packaging) });
	}
	$c->render(json => { unit => $key, name => &subs::format_name($name), uuid => $uuid, each => $each });
}

# The tabs in the house that can take a photo, so a computer can hand a barcode
# scan to a phone. A tab is a live `server` websocket row; its device type comes
# from the browser's user agent and the capability table says whether that type
# has a camera. The caller's own tab is left out (it is the one asking).
# GET /manager/market/cameras
sub action_3694 {
	my $c = shift;
# a peer asks for this machine's own tabs; a person also gets the peers' tabs.
	# The local AJAX helper appends this machine's own signatorial to every request,
	# so the peer flag is what marks a real peer call (a bare signatorial was being
	# mistaken for one and answered 403).
	my $from_peer = ($c->param('peer') || '') eq 'yes';
	if ($from_peer) {
		my $peer_sig = $c->param('signatorial') || '';
		my $rm = ($peer_sig && &subs::db_select('remote_machines', undef, { signatorial => $peer_sig })->hashes->[0]);
		return $c->rendered(403) unless $rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm);
	}
	my $me = $c->param('browser_tab_id') || '';
	my $since = &subs::rightNow() - $ws_live_window;
	my $rows = &subs::db_query("select browser_tab_id, user_agent, room, server_time from websockets where ( app = ? or app like ? ) and type = ? and server_time >= ? order by server_time desc", 'server', 'server@%', 'stayingAlive', $since)->hashes;
	my (%seen, @devices);
	foreach my $r ( @{$rows} ) {
		my $bti = $r->{'browser_tab_id'} || '';
		next unless $bti ne '' && $bti ne $me;
		next if $seen{$bti}++;
		my $type = &market_client_type($r->{'user_agent'});
		next unless scalar @{ $gb::capabilities->{$type}->{'camera'} || [] };
		my $label = ($r->{'room'} && $r->{'room'} ne '') ? &subs::format_name($r->{'room'}) : ($type eq 'mobile' ? 'Phone' : 'Computer');
		push @devices, { browser_tab_id => $bti, label => $label, type => $type, room => ($r->{'room'} || '') };
	}
	$c->render(json => { devices => \@devices }) if $from_peer;
	return if $from_peer;
	# A phone browsing its own jawn is a peer, not a local tab: ask each peer in
	# PARALLEL for the camera tabs it holds, with a short leash so a sleeping peer
	# cannot hold the chooser (sequential calls took long enough that Scan fell
	# back to the typed prompt).
	my @peers = grep { $_->{'manager'} } @{ &subs::db_select('remote_machines')->hashes };
	unless (scalar @peers) { $c->render(json => { devices => \@devices }); return; }
	my @promises;
	my @merged;
	my @peer_notes;
	my @uas;
	foreach my $rm ( @peers ) {
		my $peer = &remote_useragent_maker({ rm => $rm });
		my $ua = $peer->{'ua'};
		unless ($ua) {
			$ua = Mojo::UserAgent->new();
			$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
		}
		$ua = $ua->connect_timeout(2)->inactivity_timeout(4)->request_timeout(6);
		push @uas, $ua;
		my $url = ($peer->{'manager'} || $rm->{'manager'}) . '/manager/market/cameras?peer=yes&signatorial=' . &subs::signatorial_designer();
		my $m = $rm->{'ip'} || $rm->{'hostname'} || 'peer';
		(my $short = $m) =~ s/\.jonathanferwerda\.com$//;
		push @promises, $ua->get_p($url)->then(sub {
			my ($tx) = @_;
			my $keep_agent = $ua;  # the agent must outlive this promise
			my $res = $tx->result;
			unless ($res && $res->is_success) {
				push @peer_notes, { machine => $short, status => ($res ? $res->code : 'none'), error => ($tx->error ? ($tx->error->{'message'} || '') : '') };
				return;
			}
			my $data = eval { decode_json $res->body } || {};
			push @peer_notes, { machine => $short, status => $res->code, devices => scalar @{ $data->{'devices'} || [] } };
			foreach my $d ( @{ $data->{'devices'} || [] } ) {
				next unless ref $d eq 'HASH' && ($d->{'browser_tab_id'} || '') ne '';
				push @merged, { %$d, label => ($d->{'label'} || 'Device') . ' (' . $short . ')', machine => $m };
			}
		})->catch(sub { undef });
	}
	Mojo::Promise->all(@promises)->then(sub {
		push @devices, @merged;
		$c->render(json => { devices => \@devices, peers => \@peer_notes });
	})->catch(sub {
		push @devices, @merged;
		$c->render(json => { devices => \@devices, peers => \@peer_notes });
	});
	$c->render_later;
	&subs::request_busy_release($c);
}

# Hand a barcode scan to another tab: it opens its camera over the whole screen,
# reads the first code it sees, restores the page and posts it, so the lookup is
# the same one a scan on this machine would do.
# POST /manager/market/scan/remote
sub action_3781 {
	my $c = shift;
	# a peer may relay a scan to one of this machine's tabs (see the cameras route
	# for why the peer flag, not the signatorial alone, marks it)
	my $from_peer = ($c->param('peer') || '') eq 'yes';
	if ($from_peer) {
		my $peer_sig = $c->param('signatorial') || '';
		my $rm = ($peer_sig && &subs::db_select('remote_machines', undef, { signatorial => $peer_sig })->hashes->[0]);
		return $c->rendered(403) unless $rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm);
	}
	my $bti = $c->param('browser_tab_id') || '';
	return $c->render(json => { error => 'no device' }) unless $bti =~ /\S/;
	my %pass = (
		session => ($c->param('session') || ''),
		device_id => ($c->param('device_id') || ''),
		origin_machine => ($c->param('origin_machine') || ''),
		list => ($c->param('list') || ''),
		vendor => ($c->param('vendor') || ''),
		rapid => ($c->param('rapid') || ''),
		origin_tab => ($c->param('origin_tab') || ''),
		origin_name => ($c->param('origin_name') || ''),
		stop => ($c->param('stop') || ''),
	);
	# a person picked a tab on a peer: hand the job to that peer's own manager
	my $machine = $c->param('machine') || '';
	if (!$from_peer && $machine ne '') {
		my $rm = &subs::db_select('remote_machines', undef, { ip => $machine })->hashes->[0]
			|| &subs::db_select('remote_machines', undef, { hostname => $machine })->hashes->[0];
		return $c->render(json => { error => 'no such machine' }) unless $rm;
		my $peer = &remote_useragent_maker({ rm => $rm });
		my $ua = $peer->{'ua'};
		unless ($ua) {
			$ua = Mojo::UserAgent->new();
			$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
		}
		$ua = $ua->connect_timeout(2)->inactivity_timeout(4)->request_timeout(6);
		my $url = ($peer->{'manager'} || $rm->{'manager'}) . '/manager/market/scan/remote?peer=yes&signatorial=' . &subs::signatorial_designer();
		my $res = eval { $ua->post($url => form => { %pass, browser_tab_id => $bti, timestamp => &subs::rightNow() })->result };
		return $c->render(json => $res && $res->is_success ? { ok => 1, machine => $machine } : { ok => 0, error => ($res ? ('the peer answered ' . $res->code) : 'the peer did not answer') });
	}
	my $opts = {
		session => $pass{'session'},
		device_id => $pass{'device_id'},
		origin_machine => $pass{'origin_machine'},
		list => $pass{'list'},
		vendor => $pass{'vendor'},
		rapid => 1,
		origin_tab => $pass{'origin_tab'},
	};
	if ($opts->{'origin_tab'} ne '') {
		my $row = &subs::db_select('websockets', undef, { browser_tab_id => $opts->{'origin_tab'}, app => 'server' })->hashes->[0];
		$opts->{'origin_name'} = $row ? ($row->{'room'} || '') : '';
	}
	&Websocket::send('server', {
		console => ($pass{'stop'} ? &Websocket::console_command('marketPhoneScanStop') : &Websocket::console_command('marketPhoneCamera', $opts)),
		destination => $bti,
		timestamp => $c->param('timestamp') || &subs::rightNow()
	});
	# the page may be paused behind the phone's scan sheet: reach the bridge
	# natively so the sheet comes down even when JS cannot run
	&market_scan_native_stop() if $pass{'stop'};
	$c->render(json => { ok => 1, device => $bti });
}

# POST /manager/market/scan/session/start
sub action_4102 {
	my $c = shift;
	my $device = eval { decode_json($c->param('device')) } || {};
	$device = { kind => 'local', label => 'this machine' } unless ref $device eq 'HASH' && (($device->{'kind'} || '') eq 'local' || ($device->{'kind'} || '') eq 'remote');
	my $s = {
		uuid => &subs::random_string_creator(20),
		at => &subs::rightNow(),
		status => 'scanning',
		device => $device,
		devices => [ $device ],
		list => (&market_list_key($c->param('list') || '') || ''),
		vendor => (&subs::unformat_name($c->param('vendor')) || ''),
		items => [],
	};
	if (($device->{'kind'} || '') eq 'local' && &market_camera_available()) {
		my $pid = &market_camera_start();
		if ($pid) {
			# zbarcam fails fast when the camera is busy or absent; do not claim a
			# live view the machine cannot give, so the browser can fall back
			select(undef, undef, undef, 0.4);
			if (&market_camera_alive()) {
				$s->{'camera'} = 1;
				$s->{'camera_offset'} = 0;
			}
			else { &market_camera_stop(); }
		}
	}
	&market_scan_session_save($s);
	&market_scan_device_send($c, $device, $s, 0) if ($device->{'kind'} || '') eq 'remote';
	$c->render(json => { session => &market_scan_session_view($s) });
}

# Add another input to a running run. Each device keeps its own scanner and the
# reads all land in the same session, so the webcam and two phones can scan at
# once; adding one already on the run restarts its scanner instead of doubling it.
# POST /manager/market/scan/session/device/add
sub action_4136 {
	my $c = shift;
	my $device = eval { decode_json($c->param('device')) } || {};
	return $c->render(json => { error => 'no device' }) unless ref $device eq 'HASH' && (($device->{'kind'} || '') eq 'local' || ($device->{'kind'} || '') eq 'remote');
	my $s = &market_scan_session();
	return $c->render(json => { error => 'no session' }) unless ($s->{'uuid'} || '') ne '' && ($s->{'status'} || '') eq 'scanning';
	my $id = &market_scan_device_id($device);
	my @devices = grep { &market_scan_device_id($_) ne $id } &market_scan_session_devices($s);
	push @devices, $device;
	$s->{'devices'} = \@devices;
	$s->{'device'} = $devices[0];
	if (($device->{'kind'} || '') eq 'local') {
		if (&market_camera_available() && !($s->{'camera'} || 0)) {
			my $pid = &market_camera_start();
			if ($pid) {
				select(undef, undef, undef, 0.4);
				if (&market_camera_alive()) { $s->{'camera'} = 1; $s->{'camera_offset'} = 0; }
				else { &market_camera_stop(); }
			}
		}
	}
	else { &market_scan_device_send($c, $device, $s, 0); }
	&market_scan_session_save($s);
	$c->render(json => { session => &market_scan_session_view($s) });
}

# Stop one input and leave the rest of the run scanning.
# POST /manager/market/scan/session/device/remove
sub action_4162 {
	my $c = shift;
	my $id = $c->param('id') || '';
	my $s = &market_scan_session();
	return $c->render(json => { error => 'no session' }) unless ($s->{'uuid'} || '') ne '';
	my @kept;
	my $removed;
	foreach my $d ( &market_scan_session_devices($s) ) {
		if (&market_scan_device_id($d) eq $id) { $removed = $d; next; }
		push @kept, $d;
	}
	return $c->render(json => { error => 'no such device' }) unless $removed;
	&market_scan_device_send($c, $removed, $s, 1) if (($removed->{'kind'} || '') eq 'remote');
	unless (grep { ($_->{'kind'} || '') eq 'local' } @kept) {
		&market_camera_stop() if ($s->{'camera'} || 0);
		delete $s->{'camera'};
	}
	$s->{'devices'} = \@kept;
	$s->{'device'} = $kept[0];
	&market_scan_session_save($s);
	$c->render(json => { session => &market_scan_session_view($s) });
}

# POST /manager/market/scan/collect
sub action_4184 {
	my $c = shift;
	my $session = $c->param('session') || '';
	my $origin = $c->param('origin_machine') || '';
	# the phone: hand the code to the peer that started the session
	if ($origin ne '' && ($c->param('peer') || '') ne 'yes') {
		my $rm = &subs::db_select('remote_machines', undef, { signatorial => $origin })->hashes->[0];
		if ($rm) {
			my $peer = &remote_useragent_maker({ rm => $rm });
			my $ua = $peer->{'ua'};
			unless ($ua) {
				$ua = Mojo::UserAgent->new();
				$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
			}
			$ua = $ua->connect_timeout(2)->inactivity_timeout(4)->request_timeout(6);
			my $url = ($peer->{'manager'} || $rm->{'manager'}) . '/manager/market/scan/collect?peer=yes&signatorial=' . &subs::signatorial_designer();
			my $res = eval { $ua->post($url => form => {
				session => $session,
				barcode => ($c->param('barcode') || ''),
				stop => ($c->param('stop') ? 1 : 0),
				device_id => ($c->param('device_id') || ''),
				timestamp => &subs::rightNow()
			})->result };
			my $body = $res ? (eval { decode_json $res->body } || {}) : {};
			return $c->render(json => $body);
		}
	}
	if (($c->param('peer') || '') eq 'yes') {
		my $peer_sig = $c->param('signatorial') || '';
		my $rm = ($peer_sig && &subs::db_select('remote_machines', undef, { signatorial => $peer_sig })->hashes->[0]);
		return $c->rendered(403) unless $rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm);
	}
	my $s = &market_scan_session();
	unless (($s->{'uuid'} || '') ne '' && $s->{'uuid'} eq $session) {
		return $c->render(json => { error => 'no such session' });
	}
	if ($c->param('stop')) {
		my $did = $c->param('device_id') || '';
		if ($did ne '') {
			my @kept = grep { &market_scan_device_id($_) ne $did } &market_scan_session_devices($s);
			if (scalar @kept) {
				$s->{'devices'} = \@kept;
				$s->{'device'} = $kept[0];
				unless (grep { ($_->{'kind'} || '') eq 'local' } @kept) {
					&market_camera_stop() if ($s->{'camera'} || 0);
					delete $s->{'camera'};
				}
				&market_scan_session_save($s);
				return $c->render(json => { ok => 1, stopped => $did, count => scalar @{ $s->{'items'} || [] } });
			}
		}
		&market_camera_stop() if ($s->{'camera'} || 0);
		delete $s->{'camera'};
		$s->{'status'} = 'cancelled';
		$s->{'items'} = [];
		&market_scan_session_save($s);
		return $c->render(json => { ok => 1, cancelled => 1 });
	}
	my $code = $c->param('barcode') || '';
	$code =~ s/\s+//g;
	return $c->render(json => { error => 'no code' }) unless $code =~ /\S/;
	my $it = &market_scan_session_add($s, $code);
	return $c->render(json => { error => 'no code' }) unless $it;
	$c->render(json => { ok => 1, item => { %$it, formatted => &subs::format_name($it->{'item'}) }, count => scalar @{ $s->{'items'} } });
}

# GET /manager/market/scan/session
sub action_4249 {
	my $c = shift;
	my $s = &market_scan_session();
	&market_camera_ingest($s) if ($s->{'camera'} || 0);
	$c->render(json => &market_scan_session_view($s));
}

# POST /manager/market/scan/session/done
sub action_4255 {
	my $c = shift;
	my $s = &market_scan_session();
	return $c->render(json => { error => 'no session' }) unless ($s->{'uuid'} || '') ne '';
	my $list = &market_list();
	my ($added, $linked) = (0, 0);
	foreach my $it ( @{ $s->{'items'} || [] } ) {
		next unless ref $it eq 'HASH';
		my $name = &subs::unformat_name($it->{'item'} || '');
		next unless $name ne '';
		my $init = &subs::setting_initializer($name, &subs::rightNow());
		$name = $init->{'app'} if $init->{'app'};
		my $found;
		foreach my $row ( @{$list} ) {
			next unless lc($row->{'text'} || '') eq lc($name) || &subs::unformat_name($row->{'text'} || '') eq $name;
			$row->{'kind'} = 'need' if &market_item_due($name);
			$found = 1;
			$linked++;
			last;
		}
		next if $found;
		unshift @{$list}, {
			uuid => &subs::random_string_creator(21),
			text => $name,
			barcode => ($it->{'code'} || ''),
			kind => &market_item_due($name) ? 'need' : 'want',
			vendor => ($s->{'vendor'} || ''),
			list => ($s->{'list'} || ''),
			unit => ($it->{'unit'} || ''),
			timestamp => &subs::rightNow(),
		};
		$added++;
	}
	&market_save_list($list);
	&market_lists_touch_vendor($s->{'list'}, &subs::format_name($s->{'list'}), $s->{'vendor'}) if ($s->{'list'} || '') ne '' && ($s->{'vendor'} || '') ne '';
	my $d = $s->{'device'} || {};
	foreach my $d ( &market_scan_session_devices($s) ) {
		&market_scan_device_send($c, $d, $s, 1) if (($d->{'kind'} || '') eq 'remote' || ($d->{'browser_tab_id'} || '') ne '');
	}
	&market_camera_stop() if ($s->{'camera'} || 0);
	delete $s->{'camera'};
	$s->{'status'} = 'done';
	$s->{'items'} = [];
	&market_scan_session_save($s);
	$c->render(json => { added => $added, linked => $linked });
}

# POST /manager/market/scan/session/cancel
sub action_4301 {
	my $c = shift;
	my $s = &market_scan_session();
	return $c->render(json => { error => 'no session' }) unless ($s->{'uuid'} || '') ne '';
	foreach my $d ( &market_scan_session_devices($s) ) {
		&market_scan_device_send($c, $d, $s, 1) if (($d->{'kind'} || '') eq 'remote' || ($d->{'browser_tab_id'} || '') ne '');
	}
	&market_camera_stop() if ($s->{'camera'} || 0);
	delete $s->{'camera'};
	$s->{'status'} = 'cancelled';
	$s->{'items'} = [];
	&market_scan_session_save($s);
	$c->render(json => { cancelled => 1 });
}

# A scanned barcode: resolve it (house first, then a public catalogue, then our own
# naming), make sure the house item app exists, and put it on the list.
# POST /manager/market/scan
sub action_4317 {
	my $c = shift;
	my $code = $c->param('barcode') || $c->param('code') || '';
	$code =~ s/\s+//g;
	return $c->render(json => { error => 'no code' }) unless $code =~ /\S/;
	my $map = &market_barcode_resolve($code);
	my $name = $map->{'item'} || $code;
	my $init = &subs::setting_initializer($name, &subs::rightNow());
	$name = $init->{'app'} if $init->{'app'};
	my $list_key = $c->param('list') || '';
	my $vendor = &subs::unformat_name($c->param('vendor')) || '';
	my $list = &market_list();
	my $row = {
		uuid => &subs::random_string_creator(21),
		text => $name,
		barcode => $code,
		kind => &market_item_due($name) ? 'need' : 'want',
		vendor => $vendor,
		list => &market_list_key($list_key),
		timestamp => &subs::rightNow(),
	};
	$row->{'unit'} = $map->{'unit'} if $map->{'unit'};
	unshift @{$list}, $row;
	&market_save_list($list);
	&market_lists_touch_vendor($row->{'list'}, &subs::format_name($list_key), $vendor) if $row->{'list'} && $vendor;
	# a scan handed over from another device tells the tab that asked that it landed
	my $origin = $c->param('origin_tab') || '';
	if ($origin ne '') {
		&Websocket::send('server', {
			destination => $origin,
			console => &Websocket::console_command('marketScanArrived'),
			timestamp => &subs::rightNow()
		});
	}
	$c->render(json => { item => $row, raw => $map->{'raw'}, category => $map->{'category'} });
}

# The warehouse (or anything that knows what needs buying) names an item; Market
# upgrades a matching row to a need.
# POST /manager/market/need
sub action_4355 {
	my $c = shift;
	my $text = $c->param('item') || $c->param('text') || '';
	$c->render(json => { item => $text, upgraded => &market_upgrade_need($text) });
}

# Opening the Market reconciles the list with the warehouse: an item the shelf
# says is short is upgraded to a need. A POST, so a read never writes.
# POST /manager/market/refresh
sub action_4362 {
	my $c = shift;
	&market_sweep_needs();
	my $timestamp = $c->param('timestamp');
	my $contents = &market_maker($c);
	my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'market', contents => $contents }, $timestamp);
	$c->render(json => { window => $window, html => $contents });
}

1;
